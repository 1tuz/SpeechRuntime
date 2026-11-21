#if os(macOS)
import Foundation
import RuntimeUIModel
/// In-app updater. Checks GitHub releases for a tag newer than the running
/// bundle's version, downloads the DMG, verifies SHA-256, mounts it and
/// replaces the installed `.app` in place. The running UI quits at the last
/// step (the service LaunchAgent keeps running; the new app reconnects).
enum UpdateChecker {
    static let repository = "1tuz/Speech-Runtime"
    /// Opt-in setting: silently check at launch, only notify when a newer
    /// release exists. Manual "Check for updates" works regardless of this.
    static var autoUpdateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    struct Release: Decodable {
        let tag_name: String
        let html_url: String?
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int64?
        }
        let assets: [Asset]
    }

    static func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func isTagNewer(_ tag: String, than current: String) -> Bool {
        UpdateVersioning.isTagNewer(tag, than: current)
    }

    /// Fetches the latest release; nil when offline or the API is unreachable.
    static func latestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppFailure(L("update.error.network"))
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    static func assets(_ release: Release) -> (dmg: URL, sha256: URL)? {
        guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") })?.browser_download_url,
              let sha = release.assets.first(where: { $0.name.hasSuffix(".dmg.sha256") })?.browser_download_url
        else { return nil }
        return (dmg, sha)
    }

    /// Downloads the DMG to a temp file, verifies its checksum, then replaces
    /// the app bundle in the parent directory of the running bundle.
    /// `progress` receives 0..1 while the DMG downloads.
    static func install(from release: Release, progress: @escaping @Sendable (Double?) -> Void) async throws {
        guard let (dmgURL, shaURL) = assets(release) else {
            throw AppFailure(L("update.error.assets"))
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRuntime-update-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: temp) }

        progress(nil)
        let (shaData, _) = try await URLSession.shared.data(from: shaURL)
        let expected = String(data: shaData, encoding: .utf8)?
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)?
            .lowercased() ?? ""
        guard expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw AppFailure(L("update.error.integrity"))
        }

        let delegate = DMGDownload(destination: temp, progress: progress)
        try await delegate.fetch(dmgURL)
        progress(nil)

        let actual = try await sha256(of: temp)
        guard actual == expected else { throw AppFailure(L("update.error.integrity")) }

        let running = Bundle.main.bundleURL
        guard running.pathExtension == "app" else {
            throw AppFailure(L("update.error.install"))
        }
        try await replaceApp(fromDMG: temp, at: running,
                             expectedVersion: String(release.tag_name.drop(while: { $0 == "v" })))
    }

    /// Mounts the DMG read-only, stages the new app next to the old one,
    /// then swaps the old bundle aside and renames the staged bundle into
    /// place. On failure the old bundle is restored untouched.
    static func replaceApp(fromDMG dmg: URL, at target: URL, expectedVersion: String) async throws {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRuntime-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: mount) }
        try await mountDMG(dmg, at: mount)
        defer { try? runDiskImageTool(["detach", mount.path, "-quiet"]) }
        let newApp = mount.appendingPathComponent("Speech Runtime.app")
        guard let info = Bundle(url: newApp)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == "com.speechruntime.app",
              info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw AppFailure(L("update.error.assets"))
        }
        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).staged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try FileManager.default.copyItem(at: newApp, to: staged)
            let aside = target.deletingLastPathComponent()
                .appendingPathComponent(".\(target.lastPathComponent).old-\(UUID().uuidString)")
            var movedOld = false
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: target, to: aside)
                movedOld = true
            }
            do {
                try FileManager.default.moveItem(at: staged, to: target)
                try? FileManager.default.removeItem(at: aside)
            } catch {
                if movedOld { try? FileManager.default.moveItem(at: aside, to: target) }
                throw error
            }
        } catch {
            throw AppFailure(L("update.error.install"))
        }
    }

    private static func mountDMG(_ dmg: URL, at mount: URL) async throws {
        try await Task.detached(priority: .utility) {
            try runDiskImageTool(["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        }.value
    }

    private static func runDiskImageTool(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppFailure(L("update.error.install")) }
    }

    private static func sha256(of file: URL) async throws -> String {
        let task = Task.detached(priority: .utility) { () -> String in
            try Shell.capture("/usr/bin/shasum", ["-a", "256", file.path]).prefix(64).lowercased()
        }
        return try await task.value
    }
}

private enum Shell {
    static func capture(_ path: String, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        let data = (task.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Streaming DMG download: same delegate pattern as ModelStore's ModelDownload.
private final class DMGDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func fetch(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForResource = 1800
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                lock.unlock()
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            self.lock.lock()
            let session = self.session
            self.session = nil
            self.lock.unlock()
            session?.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { progress(nil); return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw AppFailure(L("update.error.network"))
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
#endif
