import Foundation

/// Optional model *assets*. A downloaded weight file is not an implemented inference feature.
/// Keep this manifest independent of SwiftUI so it can be validated on Linux and in tests.
public enum OptionalComponent: String, CaseIterable, Hashable, Identifiable, Sendable {
    case smartTurn = "smart-turn"
    case weSpeaker = "we-speaker"
    case localVQE = "local-vqe"
    case lsEEND = "ls-eend"
    case forcedAlignment = "forced-alignment"
    case nemotronDiarization = "nemotron-diarization"

    public var id: String { rawValue }
    public var titleKey: String { "optional.\(rawValue).title" }
    public var detailKey: String { "optional.\(rawValue).detail" }
    public var sizeKey: String { "optional.\(rawValue).size" }
    public var icon: String {
        switch self {
        case .smartTurn: "brain.head.profile"
        case .weSpeaker: "person.2.wave.2"
        case .localVQE: "waveform.path"
        case .lsEEND: "person.3.sequence"
        case .forcedAlignment: "text.word.spacing"
        case .nemotronDiarization: "person.2"
        }
    }

    /// Single-file weight assets only. `nemotronDiarization` is a managed
    /// two-asset install (Wavo binary + GGUF) handled by its own spec below.
    public var asset: OptionalAssetSpec? {
        switch self {
        case .smartTurn:
            return OptionalAssetSpec(
                fileName: "smart-turn-v3.2-cpu.onnx", bytes: 8_679_182,
                sha256: "2bb026316b14a660486a75b1733cd3fbab8c2fd0314dc9af7be49f8cca967e4f",
                urlString: "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/main/smart-turn-v3.2-cpu.onnx")
        case .weSpeaker:
            return OptionalAssetSpec(
                fileName: "voxceleb_resnet34_LM.onnx", bytes: 26_530_309,
                sha256: "7bb2f06e9df17cdf1ef14ee8a15ab08ed28e8d0ef5054ee135741560df2ec068",
                urlString: "https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM/resolve/main/voxceleb_resnet34_LM.onnx")
        case .localVQE, .lsEEND, .forcedAlignment:
            // Multi-asset CoreML packages and aligner need a validated, versioned driver.
            // Do NOT expose an install button until inference + lifecycle support exists.
            return nil
        case .nemotronDiarization:
            return nil
        }
    }
}

/// Managed install of the optional post-transcription diarization engine:
/// the trusted Wavo 0.6.0 CLI plus the pinned Nemotron 3 GGUF weights.
/// The daemon consumes both directly as local files; it never fetches them.
public enum NemotronDiarizationSpec {
    /// Canonical installed layout:
    /// `<support>/OptionalModels/nemotron-diarization/{wavo, model.gguf}`
    /// with sibling `nemotron-diarization.lock` for the install/lock lifecycle.
    /// The extracted Mach-O executable is pinned by exact content (verified
    /// after tar extraction and again at every scan): 14,691,368 bytes.
    public static let executableBytes: Int64 = 14_691_368
    public static let componentId = OptionalComponent.nemotronDiarization.id
    public static let installDirectoryName = "nemotron-diarization"
    public static let lockFileName = "nemotron-diarization.lock"
    public static let executableName = "wavo"
    public static let modelFileName = "model.gguf"
    /// Extracted executable pinned by exact content hash.
    public static let executableSha256 = "f640230c8983791c16c2bd38ac42caaf9c516bc46fff45e955cc37d3256b3652"

    /// Upstream release tarball pinned by exact size and SHA-256.
    public static let engineAsset = OptionalAssetSpec(
        fileName: "wavo-v0.6.0-aarch64-apple-darwin.tar.gz",
        bytes: 17_422_551,
        sha256: "73bef04a24a7984a047146e01855429881c3dd1c70b11391f46cccdd69b9457a",
        urlString: "https://github.com/vladkens/wavo/releases/download/v0.6.0/wavo-v0.6.0-aarch64-apple-darwin.tar.gz")

    /// Trusted upstream revision pinned by exact commit, never a moving tag.
    public static let modelRepository = "mudler/Nemotron-3-Diarization-GGUF"
    public static let modelRevision = "4ff894d7390caf5833f7d5520494847a7b377797"
    public static let modelFile = "nemotron-3-diarization-q8_0.gguf"
    public static let modelBytes: Int64 = 108_674_112
    public static let modelSha256 = "5fc242eae535d7b4ab59fd019b6fff2731b9772508b235cec89f44b1b1cc66d9"
    public static var modelURL: URL {
        URL(string: "https://huggingface.co/\(modelRepository)/resolve/\(modelRevision)/\(modelFile)")!
    }

    /// Exact member the trusted archive must contain at its root. Only this
    /// executable is extracted; archive symlinks and other members are ignored.
    public static let archiveMemberName = "wavo"

    /// Combined byte count shown in the UI before install.
    public static var totalBytes: Int64 { engineAsset.bytes + modelBytes }

    public static var isPinned: Bool {
        engineAsset.isValidTarball
            && executableBytes > 0
            && executableSha256.count == 64
            && modelRevision.count == 40
            && modelSha256.count == 64
            && modelBytes > 0
            && modelURL.host == "huggingface.co"
            && modelURL.path.contains("/resolve/\(modelRevision)/")
            && !modelURL.path.contains("/resolve/main/")
    }
}

public struct OptionalAssetSpec: Sendable {
    public let fileName: String
    public let bytes: Int64
    public let sha256: String
    public let urlString: String

    public var url: URL { URL(string: urlString)! }
    public var isValid: Bool {
        bytes > 0 && sha256.count == 64 && sha256.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        } && url.scheme == "https" && url.host == "huggingface.co" && !fileName.contains("/")
    }
    /// GitHub release tarballs use the same size+sha256 pinning but a different host.
    public var isValidTarball: Bool {
        bytes > 0 && sha256.count == 64 && sha256.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        } && url.scheme == "https" && url.host == "github.com" && !fileName.contains("/")
    }
}
