#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import RuntimeUIModel

/// Managed, opt-in install of the optional Nemotron diarization engine:
/// the trusted Wavo 0.6.0 executable and the pinned Nemotron 3 GGUF.
///
/// Lifecycle contract (shared with the daemon):
/// - canonical install: `<support>/OptionalModels/nemotron-diarization/{wavo, model.gguf}`
/// - sibling lock file: `<support>/OptionalModels/nemotron-diarization.lock`
/// - only publication and removal hold `flock(LOCK_EX | LOCK_NB)` on the lock
///   file; the daemon holds the same lock while actually invoking the managed
///   executable, so a complete install is never deleted mid-run. Network
///   downloads and verification run WITHOUT the lock.
/// - the lock file is opened once with `open(O_CREAT|O_CLOEXEC|O_NOFOLLOW, 0600)`
///   and never atomically replaced, so app and daemon always share one inode.
/// - downloads and tar extraction happen in a private staging directory;
///   only the expected archive member `wavo` is extracted, with system tar
///   (no shell); permissions are final before publication, and only a fully
///   verified pair is published by one atomic rename.
///
/// Never bundled, never fetched at startup, never touched by dictation flows.
enum NemotronManagedInstall {
    enum InstallError: LocalizedError, Equatable {
        case lockHeld
        case badArchive
        case extractFailed
        case unsignedExecutable
        var errorDescription: String? {
            switch self {
            case .lockHeld: return L("optional.nemotron.error.busy")
            case .badArchive: return L("optional.nemotron.error.archive")
            case .extractFailed: return L("optional.nemotron.error.extract")
            case .unsignedExecutable: return L("optional.nemotron.error.signature")
            }
        }
    }

    static let root = AppPaths.support.appendingPathComponent("OptionalModels", isDirectory: true)
    static var installDirectory: URL { root.appendingPathComponent(NemotronDiarizationSpec.installDirectoryName, isDirectory: true) }
    static var lockFile: URL { root.appendingPathComponent(NemotronDiarizationSpec.lockFileName) }
    static var executable: URL { installDirectory.appendingPathComponent(NemotronDiarizationSpec.executableName) }
    static var model: URL { installDirectory.appendingPathComponent(NemotronDiarizationSpec.modelFileName) }

    /// An install is complete only when both files exist and hash-match the
    /// extracted-binary and model pins. One detached task: no async `&&` chain.
    static func isComplete() async -> Bool {
        // Read-only probe: no directories are created and no lock is taken.

        guard FileManager.default.fileExists(atPath: executable.path),
              FileManager.default.fileExists(atPath: model.path) else { return false }
        return ((try? await verifyPair()) == true)
    }

    private static func verifyPair() async throws -> Bool {
        try await Task.detached(priority: .utility) {
            try Self.fileMatches(executable, bytes: NemotronDiarizationSpec.executableBytes,
                                 sha256: NemotronDiarizationSpec.executableSha256)
                && Self.fileMatches(model, bytes: NemotronDiarizationSpec.modelBytes,
                                    sha256: NemotronDiarizationSpec.modelSha256)
        }.value
    }

    /// Full opt-in install. All network/verification work happens unlocked in a
    /// private staging directory; the lock is taken only around publication.
    static func install(progress: @escaping @Sendable (Double?) -> Void) async throws {
        guard NemotronDiarizationSpec.isPinned else { throw AppFailure(L("optional.error.integrity")) }
        let engine = NemotronDiarizationSpec.engineAsset
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Private staging directory; nothing partial is ever visible at the
        // canonical path, so a crash mid-install leaves the previous state.
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            // 1. engine tarball: download + archive pin verify
            let archive = staging.appendingPathComponent(engine.fileName)
            let downloader = ModelDownload(destination: archive, expectedBytes: engine.bytes) { fraction in
                progress(fraction.map { $0 * 0.15 })
            }
            try await downloader.fetch(engine.url)
            try Task.checkCancellation()
            guard try await verifySHA256(archive, bytes: engine.bytes, sha256: engine.sha256) else {
                throw AppFailure(L("optional.error.integrity"))
            }
            // 2. extract ONLY the expected executable member; no shell, no
            //    arbitrary members, no symlink members, no path traversal.
            let stagedBinary = staging.appendingPathComponent(NemotronDiarizationSpec.executableName)
            try extractSingleExecutable(from: archive, member: NemotronDiarizationSpec.archiveMemberName,
                                        to: stagedBinary)
            // The verified archive is no longer needed; discard it so the
            // published directory contains exactly the two managed files.
            try FileManager.default.removeItem(at: archive)
            try Task.checkCancellation()
            // 3. extracted executable must match the pinned extracted binary,
            //    be a Mach-O file and keep its upstream signature.
            guard try await verifySHA256(stagedBinary, bytes: NemotronDiarizationSpec.executableBytes,
                                         sha256: NemotronDiarizationSpec.executableSha256) else {
                throw AppFailure(L("optional.error.integrity"))
            }
            guard try readMachOMagic(stagedBinary), try verifyCodeSignature(stagedBinary) else {
                throw InstallError.badArchive
            }
            // 4. model GGUF: download + pin verify
            progress(0.2)
            let stagedModel = staging.appendingPathComponent(NemotronDiarizationSpec.modelFileName)
            let modelDownloader = ModelDownload(destination: stagedModel,
                                                expectedBytes: NemotronDiarizationSpec.modelBytes) { fraction in
                progress(fraction.map { 0.2 + $0 * 0.75 })
            }
            try await modelDownloader.fetch(NemotronDiarizationSpec.modelURL)
            try Task.checkCancellation()
            guard try await verifySHA256(stagedModel, bytes: NemotronDiarizationSpec.modelBytes,
                                         sha256: NemotronDiarizationSpec.modelSha256) else {
                throw AppFailure(L("optional.error.integrity"))
            }
            // 5. final permissions BEFORE publication: a published install is
            //    always complete and correctly permissioned.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedBinary.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedModel.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            // 6. final cancellation gate, then publish under the shared lock
            try Task.checkCancellation()
            progress(0.97)
            try publish(from: staging)
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Replace the canonical directory with the staged one in one rename, while
    /// holding the shared flock. The previous install (if any) is swapped aside
    /// first so a failure can restore it; the rename is the atomic publication.
    private static func publish(from staging: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = try ExclusiveLock(path: lockFile.path)
        guard try lock.tryLock() else { throw InstallError.lockHeld }
        defer { lock.unlock() }
        let previous = root.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: installDirectory.path) {
            try FileManager.default.moveItem(at: installDirectory, to: previous)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: installDirectory)
            try? FileManager.default.removeItem(at: previous)
        } catch {
            if FileManager.default.fileExists(atPath: previous.path) {
                try? FileManager.default.moveItem(at: previous, to: installDirectory)
            }
            throw error
        }
    }

    /// Remove the managed install under the shared flock. Refuses while the
    /// daemon holds the lock (LOCK_NB fails) so a running diarization
    /// subprocess keeps its files. Filesystem errors are surfaced, not hidden.
    static func remove() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = try ExclusiveLock(path: lockFile.path)
        guard try lock.tryLock() else { throw InstallError.lockHeld }
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: installDirectory.path) else { return }
        try FileManager.default.removeItem(at: installDirectory)
    }

    /// Minimal tar listing + single-member extraction without a shell:
    /// `tar -tf` to prove the member exists, then `tar -xOf` piped into a
    /// file we create ourselves. -xOf writes only the member's bytes, so
    /// archive symlinks, directories and path traversal cannot materialize.
    private static func extractSingleExecutable(from archive: URL, member: String, to destination: URL) throws {
        guard !member.isEmpty, !member.contains("/"), !member.contains("\\"),
              !member.contains(".."), !member.hasPrefix(".") else { throw InstallError.badArchive }
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        guard FileManager.default.isExecutableFile(atPath: tar.path) else {
            throw InstallError.extractFailed
        }
        let names = try Shell.capture(tar, ["-tzf", archive.path])
            .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard names.contains(member) else { throw InstallError.badArchive }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o700]) else {
            throw InstallError.extractFailed
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let task = Process()
        task.executableURL = tar
        task.arguments = ["-xzOf", archive.path, member]
        task.standardOutput = handle
        task.standardError = Pipe()
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { throw InstallError.extractFailed }
        task.waitUntilExit()
        let extracted = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard task.terminationReason == .exit, task.terminationStatus == 0, extracted > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw InstallError.badArchive
        }
    }

    /// Mach-O magics (both endiannesses, thin and fat) for the extracted file.
    private static func readMachOMagic(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        switch magic {
        case 0xFEEDFACF, 0xFEEDFACE, 0xCFFAEDFE, 0xCEFAEDFE: return true
        default: return false
        }
    }

    /// Upstream ships an adhoc (linker) signature; `--verify --strict` proves
    /// the extracted bytes still satisfy it. Any tampering breaks this check.
    private static func verifyCodeSignature(_ url: URL) throws -> Bool {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        guard FileManager.default.isExecutableFile(atPath: codesign.path) else { return false }
        let task = Process()
        task.executableURL = codesign
        task.arguments = ["--verify", "--strict", url.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationReason == .exit && task.terminationStatus == 0
    }

    private static func fileMatches(_ url: URL, bytes: Int64, sha256 expected: String) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try autoreleasepool { try handle.read(upToCount: 1 << 20) ?? Data() }
            if data.isEmpty { break }
            sha.update(data: data)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }

    static func verifySHA256(_ url: URL, bytes: Int64, sha256 expected: String) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            try fileMatches(url, bytes: bytes, sha256: expected)
        }.value
    }
}

/// flock(2) wrapper: LOCK_EX | LOCK_NB, released on deinit (fd close).
/// The lock file is opened with O_NOFOLLOW|O_CLOEXEC and created exactly once;
/// it is never renamed over, so app and daemon share one stable inode.
/// The daemon holds the identical lock around actual managed invocation.
final class ExclusiveLock {
    private let fd: Int32
    init(path: String) throws {
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    func tryLock() throws -> Bool {
        flock(fd, LOCK_EX | LOCK_NB) == 0
    }
    func unlock() { flock(fd, LOCK_UN) }
    deinit { close(fd) }
}

private enum Shell {
    static func capture(_ executable: URL, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        task.standardInput = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationReason == .exit, task.terminationStatus == 0 else {
            throw NemotronManagedInstall.InstallError.badArchive
        }
        let data = (task.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
#endif
