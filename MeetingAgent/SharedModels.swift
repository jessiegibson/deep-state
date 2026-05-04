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

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy  h:mm a"
        return formatter.string(from: date)
    }
}
