import Foundation

// MARK: - MeetingRecord
// Shared between macOS and iOS targets.

struct MeetingRecord: Identifiable {
    let id = UUID()
    let folderURL: URL
    let folderName: String
    let title: String?
    let date: Date
    let hasAudio: Bool
    let hasVideo: Bool
    let transcriptContent: String?

    var displayTitle: String { title ?? folderName }

    /// Resolves the actual audio file on disk (m4a is the normal path; wav is the
    /// fallback used when the on-device m4a conversion fails — see StorageManager).
    var audioURL: URL? {
        guard hasAudio else { return nil }
        let m4a = folderURL.appendingPathComponent("audio.m4a")
        if FileManager.default.fileExists(atPath: m4a.path) { return m4a }
        let wav = folderURL.appendingPathComponent("audio.wav")
        if FileManager.default.fileExists(atPath: wav.path) { return wav }
        return nil
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy  h:mm a"
        return formatter.string(from: date)
    }
}
