#if os(macOS)
import XCTest
@testable import SpeechRuntimeApp

/// Regression tests for the in-app updater install path, using a real
/// scratch DMG built with `hdiutil` (schema matches the published release
/// image: `-plist` output is a dictionary with a `system-entities` array).
final class UpdateInstallTests: XCTestCase {
    private static var fixtureRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-update-tests-\(UUID().uuidString)")
    }
    private var root: URL!

    override func setUp() {
        root = Self.fixtureRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Plist-shaped exactly like real `hdiutil attach -plist` output for the
    /// published v0.4.2 DMG (dictionary root, `system-entities` array,
    /// `mount-point` only on the leaf APFS entry).
    private func scratchDMG() throws -> URL {
        let stage = root.appendingPathComponent("stage")
        let app = stage.appendingPathComponent("Speech Runtime.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "0.4.3-new".write(to: app.appendingPathComponent("Contents/MacOS/SpeechRuntimeApp"), atomically: true, encoding: .utf8)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.speechruntime.app",
            "CFBundleShortVersionString": "0.4.3",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let dmg = root.appendingPathComponent("update.dmg")
        let out = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["create", "-quiet", "-volname", "Speech Runtime",
                          "-srcfolder", stage.path, "-format", "UDZO", "-ov", dmg.path]
        task.standardOutput = out
        task.standardError = out
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "UpdateInstallTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "scratch DMG create failed: \(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")"])
        }
        return dmg
    }

    private func installedApp(named: String = "Speech Runtime.app") throws -> URL {
        let app = root.appendingPathComponent(named)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "old".write(to: app.appendingPathComponent("Contents/MacOS/SpeechRuntimeApp"), atomically: true, encoding: .utf8)
        return app
    }

    /// v0.4.2 regression: `hdiutil attach -plist` returns a dictionary with a
    /// `system-entities` array; the old array-root cast failed to find the
    /// mount point. Mounting the real-format scratch DMG through the
    /// production code path must produce a mount point containing the app.
    func testReplaceAppMountsRealDMGPlistSchema() async throws {
        let dmg = try scratchDMG()
        let old = try installedApp(named: "Renamed Speech Runtime.app")
        try await UpdateChecker.replaceApp(fromDMG: dmg, at: old, expectedVersion: "0.4.3")
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("Contents/MacOS/SpeechRuntimeApp"), encoding: .utf8), "0.4.3-new")
        // No stale rollback artifacts left behind.
        for entry in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            XCTAssertFalse(entry.contains(".old"), "stale rollback artifact: \(entry)")
        }
    }

    /// A DMG whose payload is not a valid app bundle must fail the install
    /// and leave the old app byte-identical.
    func testBadSourceLeavesOldAppUntouched() async throws {
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try "junk".write(to: stage.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let dmg = root.appendingPathComponent("update.dmg")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["create", "-quiet", "-volname", "Speech Runtime",
                          "-srcfolder", stage.path, "-format", "UDZO", "-ov", dmg.path]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)

        let old = try installedApp()
        let oldData = try FileManager.default.contentsOfDirectory(
            at: old.appendingPathComponent("Contents/MacOS"), includingPropertiesForKeys: nil)
        do {
            try await UpdateChecker.replaceApp(fromDMG: dmg, at: old, expectedVersion: "0.4.3")
            XCTFail("install must fail for a DMG without a valid app bundle")
        } catch {
            // expected
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: old.appendingPathComponent("Contents/MacOS"), includingPropertiesForKeys: nil), oldData)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("Contents/MacOS/SpeechRuntimeApp"), encoding: .utf8), "old")
    }
}
#endif
