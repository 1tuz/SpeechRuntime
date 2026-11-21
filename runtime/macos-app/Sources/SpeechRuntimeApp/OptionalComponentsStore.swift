#if os(macOS)
import Combine
import CryptoKit
import Foundation
import RuntimeUIModel

/// Download manager for *optional weight files*, not a pretend inference backend.
/// The current daemon does not load these; a future driver must opt in explicitly.
/// The Nemotron diarization entry is a managed two-asset install (executable +
/// GGUF) with its own flock lifecycle; see NemotronManagedInstall.
@MainActor
final class OptionalComponentsStore: ObservableObject {
    enum Status: Equatable {
        case checking, absent, downloading(Double), installed, failed(String), unavailable
        /// Removal failed but the files are still on disk: keep the removal
        /// control (retry) visible with the surfaced error message.
        case removalFailed(String)
    }

    @Published private(set) var statuses: [OptionalComponent: Status] = [:]
    private var downloads: [OptionalComponent: Task<Void, Never>] = [:]
    private let directory = AppPaths.support.appendingPathComponent("OptionalModels", isDirectory: true)

    init() {
        for component in OptionalComponent.allCases {
            statuses[component] = (component.asset == nil && component != .nemotronDiarization) ? .unavailable : .checking
        }
        Task { await scan() }
    }

    func status(_ component: OptionalComponent) -> Status { statuses[component] ?? .checking }

    func scan() async {
        for component in OptionalComponent.allCases {
            guard downloads[component] == nil else { continue }
            if component == .nemotronDiarization {
                // The canonical managed paths decide, never a file name alone:
                // both files must exist and hash-match the pins.
                statuses[component] = await NemotronManagedInstall.isComplete() ? .installed : .absent
                continue
            }
            guard let asset = component.asset else { continue }
            let file = destination(component, asset: asset)
            guard FileManager.default.fileExists(atPath: file.path) else {
                statuses[component] = .absent
                continue
            }
            do {
                // Existing files are not trusted by their name or length alone.
                let matches = try await verify(file, asset: asset)
                if downloads[component] == nil { statuses[component] = matches ? .installed : .failed(L("optional.error.integrity")) }
            } catch {
                if downloads[component] == nil { statuses[component] = .failed(error.localizedDescription) }
            }
        }
    }

    func install(_ component: OptionalComponent) {
        guard downloads[component] == nil else { return }
        if case .installed = status(component) { return }
        if component == .nemotronDiarization {
            guard NemotronDiarizationSpec.isPinned else {
                statuses[component] = .failed(L("optional.error.integrity"))
                return
            }
            statuses[component] = .downloading(0)
            downloads[component] = Task { [weak self] in
                guard let self else { return }
                do {
                    try await NemotronManagedInstall.install { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, case .downloading = self.status(component) else { return }
                            self.statuses[component] = .downloading(min(1, max(0, fraction ?? 0)))
                        }
                    }
                    statuses[component] = .installed
                } catch {
                    // Lock contention with the daemon means "try later", not broken.
                    statuses[component] = Task.isCancelled ? .absent : .failed(error.localizedDescription)
                }
                downloads[component] = nil
            }
            return
        }
        guard let asset = component.asset, asset.isValid else { return }
        statuses[component] = .downloading(0)
        downloads[component] = Task { [weak self] in
            guard let self else { return }
            let target = destination(component, asset: asset)
            let temp = directory.appendingPathComponent(".\(component.id)-\(UUID().uuidString).download")
            defer {
                try? FileManager.default.removeItem(at: temp)
                downloads[component] = nil
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let downloader = ModelDownload(destination: temp, expectedBytes: asset.bytes) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.status(component) else { return }
                        self.statuses[component] = .downloading(min(1, max(0, fraction ?? 0)))
                    }
                }
                try await downloader.fetch(asset.url)
                try Task.checkCancellation()
                guard try await verify(temp, asset: asset) else {
                    throw AppFailure(L("optional.error.integrity"))
                }
                try Task.checkCancellation()
                // Only replace this optional asset, never other files or the main ASR model.
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: temp, to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                statuses[component] = .installed
            } catch {
                statuses[component] = Task.isCancelled ? .absent : .failed(error.localizedDescription)
            }
        }
    }

    func cancel(_ component: OptionalComponent) {
        downloads[component]?.cancel()
    }

    /// Removal is confined to this component's known locations. Nemotron removal
    /// holds the shared flock, so it never deletes files under a running daemon.
    /// Other optional assets have no live inference consumers in this patch.
    func remove(_ component: OptionalComponent) {
        guard downloads[component] == nil else { return }
        if component == .nemotronDiarization {
            // A failed removal keeps the files on disk: the error is surfaced
            // and the row stays on the retry-removal path, never a bogus
            // "install again" toggle. Success clears to .absent.
            do {
                try NemotronManagedInstall.remove()
                statuses[component] = .absent
            } catch {
                let filesRemain = FileManager.default.fileExists(atPath: NemotronManagedInstall.executable.path)
                statuses[component] = filesRemain
                    ? .removalFailed(error.localizedDescription)
                    : .failed(error.localizedDescription)
            }
            return
        }

        guard let asset = component.asset else { return }
        do {
            let file = destination(component, asset: asset)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            statuses[component] = .absent
        } catch { statuses[component] = .failed(error.localizedDescription) }
    }

    private func destination(_ component: OptionalComponent, asset: OptionalAssetSpec) -> URL {
        directory.appendingPathComponent(component.id + "-" + asset.fileName)
    }

    private func verify(_ url: URL, asset: OptionalAssetSpec) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attrs[.size] as? NSNumber)?.int64Value == asset.bytes else { return false }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var sha = SHA256()
            while true {
                try Task.checkCancellation()
                let data = try file.read(upToCount: 256 * 1024) ?? Data()
                if data.isEmpty { break }
                sha.update(data: data)
            }
            let actual = sha.finalize().map { String(format: "%02x", $0) }.joined()
            return actual == asset.sha256
        }.value
    }
}
#endif
