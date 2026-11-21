import Foundation
import XCTest
@testable import RuntimeUIModel

final class RuntimeUIModelTests: XCTestCase {
    func testCPUFirstSampleAndRestartAreUnknown() {
        var rate = CPURate()
        XCTAssertNil(rate.sample(identity: "1/a", time: 0, totalNanos: 0))
        XCTAssertEqual(rate.sample(identity: "1/a", time: 2, totalNanos: 1_000_000_000), 50)
        XCTAssertNil(rate.sample(identity: "2/a", time: 3, totalNanos: 100))
        XCTAssertNil(rate.sample(identity: "2/b", time: 4, totalNanos: 100))
    }
    func testCPUMayExceedOneCore() {
        var rate = CPURate()
        _ = rate.sample(identity: "1", time: 1, totalNanos: 0)
        XCTAssertEqual(rate.sample(identity: "1", time: 2, totalNanos: 2_000_000_000), 200)
        XCTAssertNil(rate.sample(identity: "1", time: 2, totalNanos: 3_000_000_000))
    }
    func testIncompleteHealthDoesNotInventReadyState() throws {
        let snapshot = try JSONDecoder().decode(RuntimeSnapshot.self, from: Data("{\"ok\":true}".utf8))
        XCTAssertFalse(snapshot.hasWorker)
        XCTAssertFalse(snapshot.modelLoaded)
        XCTAssertNil(snapshot.memory)
    }
    func testHealthContract() throws {
        let data = Data("""
        {"ok":true,"streams":2,"memory":{"pid":7,"resident_bytes":3000},
         "worker":{"pid":8,"models":[{"model":"parakeet-ultra","loaded":true,"inflight":1}],
                   "memory":{"neural_bytes":700000000}}}
        """.utf8)
        let snapshot = try JSONDecoder().decode(RuntimeSnapshot.self, from: data)
        XCTAssertTrue(snapshot.hasWorker)
        XCTAssertTrue(snapshot.modelLoaded)
        XCTAssertTrue(snapshot.processing)
        XCTAssertEqual(snapshot.worker?.memory?.neural, 700_000_000)
        XCTAssertEqual(snapshot.streams, 2)
    }
    func testAgentRunsOnlyBundledExecutablesAndKeepsPathsWithSpaces() throws {
        let plist = RuntimeFiles.agentPlist(binary: "/Applications/Speech Runtime.app/Contents/MacOS/speech-runtime",
            worker: "/Applications/Speech Runtime.app/Contents/MacOS/sr-worker", config: "/tmp/config", token: "/tmp/token", label: "test")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let roundtrip = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        let args = try XCTUnwrap(roundtrip["ProgramArguments"] as? [String])
        XCTAssertEqual(args.count, 9)
        XCTAssertTrue(args[0].contains("Speech Runtime.app"))
        XCTAssertNil(roundtrip["UserName"])
        XCTAssertEqual((roundtrip["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
    }
    func testDefaultContainsOnlyParakeetAndNoLanguageHint() {
        let config = RuntimeFiles.modelConfig(path: "/test/model.gguf")
        let models = config["models"] as? [String: [String: Any]]
        XCTAssertEqual(models?.count, 1)
        XCTAssertEqual(models?[ModelSpec.id]?["backend"] as? String, "ane")
        XCTAssertNil(models?[ModelSpec.id]?["language"])
    }
    func testModelRevisionIsPinned() {
        XCTAssertEqual(ModelSpec.revision.count, 40)
        XCTAssertTrue(ModelSpec.fileURL.absoluteString.contains(ModelSpec.revision))
        XCTAssertFalse(ModelSpec.fileURL.absoluteString.contains("/main/"))
    }
}

final class SetupWizardTests: XCTestCase {
    func testStepOrderWalksAllSixSteps() {
        var state = SetupWizardState()
        XCTAssertEqual(state.step, .welcome)
        XCTAssertEqual(state.stepNumber, 1)
        XCTAssertEqual(state.totalSteps, 6)
        XCTAssertTrue(state.isFirst)
        for expected in [SetupWizardState.Step.login, .idle, .capabilities, .optionalModels, .ready] {
            state.next()
            XCTAssertEqual(state.step, expected)
        }
        XCTAssertTrue(state.isLast)
        state.next()  // last step: next is a no-op
        XCTAssertEqual(state.step, .ready)
    }
    func testBackWalksReverseAndStopsAtFirst() {
        var state = SetupWizardState(step: .ready)
        state.back()
        XCTAssertEqual(state.step, .optionalModels)
        state.back()
        XCTAssertEqual(state.step, .capabilities)
        state.back(); state.back(); state.back()
        XCTAssertEqual(state.step, .welcome)
        state.back()  // first step: back is a no-op
        XCTAssertEqual(state.step, .welcome)
        XCTAssertFalse(state.isLast)
    }
    func testNemotronDiarizationIsManagedNotPlainAsset() {
        // The managed component must NOT offer a plain single-file asset:
        // it installs executable + model through its own pinned spec.
        XCTAssertEqual(OptionalComponent.nemotronDiarization.rawValue, "nemotron-diarization")
        XCTAssertNil(OptionalComponent.nemotronDiarization.asset)
        XCTAssertTrue(NemotronDiarizationSpec.isPinned)
    }
    func testNemotronSpecPinsTrustedSources() {
        // Engine: exact upstream Wavo v0.6.0 Apple Silicon release tarball.
        XCTAssertEqual(NemotronDiarizationSpec.engineAsset.fileName, "wavo-v0.6.0-aarch64-apple-darwin.tar.gz")
        XCTAssertEqual(NemotronDiarizationSpec.engineAsset.bytes, 17_422_551)
        XCTAssertEqual(NemotronDiarizationSpec.engineAsset.sha256,
                       "73bef04a24a7984a047146e01855429881c3dd1c70b11391f46cccdd69b9457a")
        XCTAssertTrue(NemotronDiarizationSpec.engineAsset.url.absoluteString
            .hasPrefix("https://github.com/vladkens/wavo/releases/download/v0.6.0/"))
        XCTAssertTrue(NemotronDiarizationSpec.engineAsset.isValidTarball)
        // Extracted executable: pinned by content, not by archive member name.
        XCTAssertEqual(NemotronDiarizationSpec.executableBytes, 14_691_368)
        XCTAssertEqual(NemotronDiarizationSpec.executableSha256,
                       "f640230c8983791c16c2bd38ac42caaf9c516bc46fff45e955cc37d3256b3652")
        XCTAssertEqual(NemotronDiarizationSpec.archiveMemberName, "wavo")
        // Model: exact revision of the official GGUF conversion, never /main/.
        XCTAssertEqual(NemotronDiarizationSpec.modelRepository, "mudler/Nemotron-3-Diarization-GGUF")
        XCTAssertEqual(NemotronDiarizationSpec.modelRevision, "4ff894d7390caf5833f7d5520494847a7b377797")
        XCTAssertEqual(NemotronDiarizationSpec.modelFile, "nemotron-3-diarization-q8_0.gguf")
        XCTAssertEqual(NemotronDiarizationSpec.modelBytes, 108_674_112)
        XCTAssertEqual(NemotronDiarizationSpec.modelSha256,
                       "5fc242eae535d7b4ab59fd019b6fff2731b9772508b235cec89f44b1b1cc66d9")
        XCTAssertTrue(NemotronDiarizationSpec.modelURL.absoluteString
            .contains("/resolve/\(NemotronDiarizationSpec.modelRevision)/"))
        XCTAssertFalse(NemotronDiarizationSpec.modelURL.absoluteString.contains("/resolve/main/"))
        // Canonical managed layout.
        XCTAssertEqual(NemotronDiarizationSpec.installDirectoryName, "nemotron-diarization")
        XCTAssertEqual(NemotronDiarizationSpec.lockFileName, "nemotron-diarization.lock")
        XCTAssertEqual(NemotronDiarizationSpec.executableName, "wavo")
        XCTAssertEqual(NemotronDiarizationSpec.modelFileName, "model.gguf")
        XCTAssertEqual(NemotronDiarizationSpec.totalBytes, 17_422_551 + 108_674_112)
    }
    func testOptionalComponentCountIsSixWithNemotronLast() {
        XCTAssertEqual(OptionalComponent.allCases.count, 6)
        XCTAssertEqual(OptionalComponent.allCases.last, .nemotronDiarization)
    }
    func testOptionalAssetsHavePinnedIntegrityMetadata() {
        for component in [OptionalComponent.smartTurn, .weSpeaker] {
            guard let asset = component.asset else { XCTFail("missing asset \(component)"); continue }
            XCTAssertTrue(asset.isValid)
            XCTAssertEqual(asset.sha256.count, 64)
        }
        XCTAssertEqual(OptionalComponent.smartTurn.asset?.bytes, 8_679_182)
        XCTAssertEqual(OptionalComponent.weSpeaker.asset?.bytes, 26_530_309)
        XCTAssertNil(OptionalComponent.localVQE.asset)
        XCTAssertNil(OptionalComponent.lsEEND.asset)
        XCTAssertNil(OptionalComponent.forcedAlignment.asset)
    }
    func testWizardDefaultsMatchExistingPreferences() {
        let state = SetupWizardState()
        XCTAssertEqual(state.idleMinutes, 15)
        XCTAssertEqual(state.language, .system)
    }
    func testCapabilitiesAreFixedPrototypeFacts() {
        XCTAssertTrue(RuntimeCapabilities.streaming)
        XCTAssertFalse(RuntimeCapabilities.interim)
        XCTAssertTrue(RuntimeCapabilities.timestamps)
        XCTAssertFalse(RuntimeCapabilities.diarization)
    }
}

final class AppLanguageTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        super.tearDown()
    }
    func testMissingKeyMeansSystem() {
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.storedValue(), .system)
        XCTAssertEqual(AppLanguage(rawValue: "system"), .system)
    }
    func testExplicitValuesRoundTrip() {
        UserDefaults.standard.set("ru", forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.storedValue(), .ru)
        UserDefaults.standard.set("en", forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.storedValue(), .en)
        // Unknown stored value falls back to system, never crashes.
        UserDefaults.standard.set("fr", forKey: "appLanguage")
        XCTAssertEqual(AppLanguage.storedValue(), .system)
    }
    func testLprojSelectionForExplicitChoices() {
        XCTAssertEqual(AppLanguage.en.lprojName(preferredLanguages: ["ru"]), "en")
        XCTAssertEqual(AppLanguage.ru.lprojName(preferredLanguages: ["en"]), "ru")
    }
    func testSystemFollowsPreferredLanguages() {
        XCTAssertEqual(AppLanguage.system.lprojName(preferredLanguages: ["ru-RU", "en-US"]), "ru")
        XCTAssertEqual(AppLanguage.system.lprojName(preferredLanguages: ["en-US", "ru"]), "en")
        XCTAssertEqual(AppLanguage.system.lprojName(preferredLanguages: ["de-DE"]), "en")
        XCTAssertEqual(AppLanguage.system.lprojName(preferredLanguages: []), "en")
    }
    func testStorePersistsRawValue() {
        AppLanguage.ru.store()
        XCTAssertEqual(UserDefaults.standard.string(forKey: "appLanguage"), "ru")
    }
}

// MARK: - Language bundle resolution (regression: switching language did nothing)

final class LanguageBundleResolutionTests: XCTestCase {
    func testLprojDirectoryIsLoadableAndDiffersFromContainer() throws {
        // The bug: Bundle(path:) was given the .strings FILE path (not a bundle),
        // returned nil, and L() silently fell back to the container bundle, which
        // follows the process-wide AppleLanguages lookup — the in-app switch had
        // no effect. The correct target is the .lproj directory.
        let container = Bundle(for: LanguageBundleResolutionTests.self)
        // The strings live in the app target's resource bundle; locate it
        // next to the test bundle (same build products directory).
        let testBundle = Bundle(for: LanguageBundleResolutionTests.self)
        let productsURL = testBundle.bundleURL.deletingLastPathComponent()
        let appResourceURL = productsURL
            .appendingPathComponent("SpeechRuntimeMenu_SpeechRuntimeApp.bundle")
        let moduleBundle = Bundle(url: appResourceURL) ?? testBundle
        let enPath = moduleBundle.path(forResource: "Localizable", ofType: "strings",
                                       inDirectory: nil, forLocalization: "en")
        let ruPath = moduleBundle.path(forResource: "Localizable", ofType: "strings",
                                       inDirectory: nil, forLocalization: "ru")
        // In test context the module may be flattened; guard rather than skip so
        // a packaging change that drops .lproj dirs fails loudly.
        guard let enStrings = enPath, let ruStrings = ruPath else {
            XCTFail("module bundle has no en/ru .lproj Localizable.strings; localization packaging is broken")
            return
        }
        let enLproj = (enStrings as NSString).deletingLastPathComponent
        let ruLproj = (ruStrings as NSString).deletingLastPathComponent
        let en = try XCTUnwrap(Bundle(path: enLproj), "en.lproj directory must be loadable as a bundle")
        let ru = try XCTUnwrap(Bundle(path: ruLproj), "ru.lproj directory must be loadable as a bundle")
        XCTAssertNotEqual(
            en.localizedString(forKey: "power.on", value: "?", table: nil),
            ru.localizedString(forKey: "power.on", value: "?", table: nil),
            "en and ru bundles must return different strings; otherwise switching is invisible"
        )
        _ = container
    }
}

// MARK: - Update version comparison

final class UpdateVersionTests: XCTestCase {
    func testNewerTagIsDetected() {
        XCTAssertTrue(UpdateVersioning.isTagNewer("v0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateVersioning.isTagNewer("v0.2.1", than: "0.2.0"))
        XCTAssertTrue(UpdateVersioning.isTagNewer("v1.0", than: "0.9.9"))
    }
    func testSameOrOlderTagIsNotNewer() {
        XCTAssertFalse(UpdateVersioning.isTagNewer("v0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateVersioning.isTagNewer("v0.1.9", than: "0.2.0"))
        XCTAssertTrue(UpdateVersioning.isTagNewer("v0.2.10", than: "0.2.9"))
    }
    func testGarbageTagsAreNotNewer() {
        XCTAssertFalse(UpdateVersioning.isTagNewer("latest", than: "0.2.0"))
        XCTAssertFalse(UpdateVersioning.isTagNewer("", than: "0.2.0"))
    }
}
