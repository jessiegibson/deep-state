import Foundation

/// WhisperKit model variants the app knows how to load.
///
/// Raw values are the model folder names WhisperKit resolves against its Hugging Face
/// repo (and against a bundled folder of the same name, when one is shipped).
///
/// Both call sites used to decide this independently: macOS hardcoded
/// `openai_whisper-small` inline, and iOS called the bare `WhisperKit()`, silently
/// inheriting whatever the package's default happened to be that release. Naming the
/// choice in one place means a WhisperKit update can't move it underneath us, and
/// gives the planned Settings picker something to write to.
enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case tiny    = "openai_whisper-tiny"
    case base    = "openai_whisper-base"
    case small   = "openai_whisper-small"
    case medium  = "openai_whisper-medium"
    case largeV3 = "openai_whisper-large-v3"

    var id: String { rawValue }

    /// Label for the picker.
    var displayName: String {
        switch self {
        case .tiny:    return "Tiny"
        case .base:    return "Base"
        case .small:   return "Small"
        case .medium:  return "Medium"
        case .largeV3: return "Large v3"
        }
    }

    /// Rough working-set size. Shown next to the picker so someone on an 8 GB Mac can
    /// see why Large is a bad idea before they select it and the app starts swapping.
    var approximateMemory: String {
        switch self {
        case .tiny:    return "~150 MB"
        case .base:    return "~300 MB"
        case .small:   return "~1 GB"
        case .medium:  return "~3 GB"
        case .largeV3: return "~6 GB"
        }
    }

    /// The default for this platform, used until the user chooses otherwise.
    ///
    /// macOS gets Small — the accuracy is worth the RAM on a desktop, and it is what
    /// the app already shipped. iOS gets Base: a phone has far less headroom and gets
    /// jetsammed for holding too much, so it is not the place to inherit an unpinned
    /// default.
    static var platformDefault: WhisperModel {
        #if os(macOS)
        return .small
        #else
        return .base
        #endif
    }
}

/// Persisted model choice.
///
/// Reads fall back to `WhisperModel.platformDefault`, so this is already correct with
/// nothing stored; the Settings picker only has to write `selected`.
enum WhisperModelPreference {
    private static let key = "pref_whisper_model"

    static var selected: WhisperModel {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let model = WhisperModel(rawValue: raw) else {
                return .platformDefault
            }
            return model
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
