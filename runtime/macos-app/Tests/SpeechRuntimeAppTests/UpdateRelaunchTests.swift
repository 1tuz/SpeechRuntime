#if os(macOS)
import XCTest
@testable import SpeechRuntimeApp

/// Tests for the update relaunch helper.
///
/// The helper must (1) not open the target while the current PID is alive,
/// (2) open the target after the current PID exits, and (3) give up after a
/// bounded wait. `open` is a test sink script so no real application launches.
final class UpdateRelaunchTests: XCTestCase {
    private var fixtureDir: String!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateRelaunchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fixtureDir = dir.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: fixtureDir)
    }

    /// A harmless stand-in for /usr/bin/open: appends the target path to the
    /// log and exits 0. The helper `exec`s it with `-n <target>` (same
    /// argument shape as production), so the target is `$2`. It must be
    /// executable.
    private var openSinkPath: String {
        let sink = fixtureDir + "/open-sink"
        if !FileManager.default.fileExists(atPath: sink) {
            try? """
            #!/bin/sh
            printf '%s\n' "$2" >> "${0%/*}/open.log"
            """.write(toFile: sink, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sink)
        }
        return sink
    }

    private func openLogContents() -> [String] {
        let log = fixtureDir + "/open.log"
        guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private func wait(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// A short-lived child process standing in for the "current app" whose
    /// exit the helper must observe.
    private func spawnCurrentApp() throws -> (process: Process, pid: pid_t) {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        return (sleeper, sleeper.processIdentifier)
    }

    func testOpenHappensOnlyAfterCurrentPIDExits() throws {
        let target = fixtureDir + "/target.app"

        let (app, pid) = try spawnCurrentApp()
        defer { app.terminate() }

        // Shorten the polling so the test runs quickly: poll every 0.05s.
        let result = UpdateRelaunch.scheduleForTesting(
            bundlePath: target, currentPID: pid, openPath: openSinkPath,
            pollSeconds: 0.05, maxWaitSeconds: 30
        )
        XCTAssertEqual(result, .scheduled)

        // While the current app is alive, nothing may be opened.
        wait(seconds: 0.6)
        XCTAssertEqual(openLogContents(), [], "target opened while current app still running")

        // Current app exits; helper must then open the explicit target path.
        app.terminate()
        var opened: [String] = []
        for _ in 0..<100 where opened.isEmpty {
            wait(seconds: 0.1)
            opened = openLogContents()
        }
        XCTAssertEqual(opened, [target], "target not opened after current app exited")
    }

    func testInvalidInputFails() {
        XCTAssertEqual(UpdateRelaunch.scheduleForTesting(bundlePath: "", currentPID: 123, openPath: openSinkPath, pollSeconds: 0.05, maxWaitSeconds: 30), .failed)
        XCTAssertEqual(UpdateRelaunch.scheduleForTesting(bundlePath: "/x", currentPID: 0, openPath: openSinkPath, pollSeconds: 0.05, maxWaitSeconds: 30), .failed)
        XCTAssertEqual(UpdateRelaunch.scheduleForTesting(bundlePath: "/x", currentPID: -1, openPath: openSinkPath, pollSeconds: 0.05, maxWaitSeconds: 30), .failed)
    }

    func testBoundedGiveUpWhenPIDNeverExits() throws {
        let (app, pid) = try spawnCurrentApp()
        defer { app.terminate() }

        let result = UpdateRelaunch.scheduleForTesting(
            bundlePath: fixtureDir + "/target.app", currentPID: pid, openPath: openSinkPath,
            pollSeconds: 0.02, maxWaitSeconds: 0.2
        )
        XCTAssertEqual(result, .scheduled)
        // Give the helper time to hit its bounded limit while the PID lives.
        wait(seconds: 1.0)
        XCTAssertEqual(openLogContents(), [], "target opened despite current app never exiting")
        app.terminate()
    }
}
#endif
