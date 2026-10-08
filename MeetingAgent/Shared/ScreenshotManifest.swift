import Foundation

// MARK: - ScreenshotInterval

/// How often screenshots are taken during a recording.
///
/// The raw value is the interval in seconds and is what gets persisted, so the
/// preset list can grow without a migration — an unrecognised stored value simply
/// falls back to the default rather than producing an invalid interval.
enum ScreenshotInterval: Double, CaseIterable, Identifiable {
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case sixtySeconds = 60
    case fiveMinutes = 300

    static let `default`: ScreenshotInterval = .thirtySeconds
    static let preferenceKey = "pref_screenshot_interval"

    var id: Double { rawValue }
    var seconds: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .fifteenSeconds: return "15s"
        case .thirtySeconds:  return "30s"
        case .sixtySeconds:   return "60s"
        case .fiveMinutes:    return "5m"
        }
    }

    /// Reads the stored preference. `UserDefaults.double(forKey:)` returns 0 for an
    /// unset key, and 0 is not a valid interval — it would spin the capture loop — so
    /// anything unrecognised resolves to the default.
    static func loadPreference(from defaults: UserDefaults = .standard) -> ScreenshotInterval {
        resolve(storedValue: defaults.double(forKey: preferenceKey))
    }

    /// The preference-resolution rule on its own, so it can be tested without touching
    /// the real user defaults.
    static func resolve(storedValue: Double) -> ScreenshotInterval {
        ScreenshotInterval(rawValue: storedValue) ?? .default
    }

    func savePreference(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

// MARK: - ScreenshotManifest

/// The machine-readable index of a meeting's screenshots, written as
/// `screenshots.json` next to `transcript.md`.
///
/// This is the agent-facing contract for the visual half of a recording: a consumer
/// should be able to answer "what was on screen 12 minutes in" by reading this file
/// alone, without decoding a MOV or parsing filenames. Filenames still encode index
/// and elapsed seconds as a fallback, but the manifest is the source of truth.
///
/// Wire format is snake_case with ISO-8601 dates — see `encoder()` / `decoder()`.
/// Additive changes (new optional fields) keep `schemaVersion`; anything that would
/// break an existing reader must bump it.
struct ScreenshotManifest: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var meeting: MeetingInfo
    var capture: CaptureInfo
    var screenshots: [Entry]

    init(schemaVersion: Int = ScreenshotManifest.currentSchemaVersion,
         meeting: MeetingInfo,
         capture: CaptureInfo,
         screenshots: [Entry]) {
        self.schemaVersion = schemaVersion
        self.meeting = meeting
        self.capture = capture
        self.screenshots = screenshots
    }

    // MARK: Nested types

    struct MeetingInfo: Codable, Equatable {
        var title: String?
        /// The meeting folder's name. Only `StorageManager` knows the timestamp it
        /// picks at save time, so this is stamped there rather than at capture time.
        var folderName: String
        var startedAt: Date
        var durationSeconds: Double?

        init(title: String? = nil,
             folderName: String = "",
             startedAt: Date,
             durationSeconds: Double? = nil) {
            self.title = title
            self.folderName = folderName
            self.startedAt = startedAt
            self.durationSeconds = durationSeconds
        }
    }

    struct CaptureInfo: Codable, Equatable {
        /// How the frames were obtained. Consumers care: live frames are wall-clock
        /// accurate, extracted frames are only as accurate as the video's timebase.
        enum Source: String, Codable {
            case liveInterval = "live_interval"
            case videoExtraction = "video_extraction"
        }

        var source: Source
        var intervalSeconds: Double
        /// "audioOnly" or "screenAndAudio" — `RecordingMode` itself is macOS-only, so
        /// this stays a plain string to keep the manifest portable.
        var recordingMode: String
        var displayName: String?
        var displayWidth: Int?
        var displayHeight: Int?
        /// True when near-identical consecutive frames were dropped. A consumer
        /// counting frames to estimate time-on-screen needs to know this happened.
        var deduplicated: Bool
        var dedupeThreshold: Double?
    }

    struct Entry: Codable, Equatable {
        /// Path relative to the meeting folder, e.g. "screenshots/shot_0001_000000.jpg".
        var file: String
        var index: Int
        /// Offset into the recording, with paused time excluded — so it lines up with
        /// the audio and the transcript rather than with wall-clock.
        var elapsedSeconds: Double
        var capturedAt: Date
        var width: Int
        var height: Int
        var byteSize: Int
    }

    // MARK: Coding

    /// A manifest missing `schema_version` is treated as version 1 rather than a
    /// decode failure — hand-edited and third-party-written files should still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? ScreenshotManifest.currentSchemaVersion
        self.meeting = try container.decode(MeetingInfo.self, forKey: .meeting)
        self.capture = try container.decode(CaptureInfo.self, forKey: .capture)
        self.screenshots = try container.decodeIfPresent([Entry].self, forKey: .screenshots) ?? []
    }

    /// The single definition of the wire format. Both the writer and the tests go
    /// through these, so the two cannot drift.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
