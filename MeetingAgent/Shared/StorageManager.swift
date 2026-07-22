import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// Shared storage abstraction for saving/loading meetings to iCloud or local folders.
/// Both macOS and iOS targets use this singleton.
@MainActor
class StorageManager: ObservableObject {

    static let shared = StorageManager()

    // MARK: - Published State

    @Published var storageMode: StorageMode {
        didSet { UserDefaults.standard.set(storageMode.rawValue, forKey: Keys.storageMode); resolveRootURL() }
    }
    @Published var iCloudSubfolder: String {
        didSet { UserDefaults.standard.set(iCloudSubfolder, forKey: Keys.iCloudSubfolder); resolveRootURL() }
    }
    @Published var rootURL: URL?
    @Published var iCloudAvailable: Bool = false

    #if os(macOS)
    /// Security-scoped bookmark URL for local folder (macOS only).
    @Published var localBookmarkURL: URL?
    #endif

    // MARK: - Types

    enum StorageMode: String {
        case local
        case iCloud
    }

    // MARK: - Constants

    private enum Keys {
        static let storageMode = "storage_mode"
        static let iCloudSubfolder = "icloud_subfolder"
        static let folderBookmark = "folder_bookmark"
    }

    static let iCloudContainerID = "iCloud.soloai.MeetingAgent"

    // MARK: - Init

    private init() {
        let savedMode = UserDefaults.standard.string(forKey: Keys.storageMode) ?? StorageMode.iCloud.rawValue
        self.storageMode = StorageMode(rawValue: savedMode) ?? .iCloud
        self.iCloudSubfolder = UserDefaults.standard.string(forKey: Keys.iCloudSubfolder) ?? "MeetingAgent"

        #if os(macOS)
        loadLocalBookmark()
        #endif

        checkiCloudAvailability()
        resolveRootURL()
    }

    // MARK: - iCloud

    func checkiCloudAvailability() {
        iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil
    }

    /// Returns the iCloud container Documents/<subfolder> URL, creating it if needed.
    func iCloudRootURL() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: Self.iCloudContainerID) else {
            return nil
        }
        let url = container
            .appendingPathComponent("Documents")
            .appendingPathComponent(iCloudSubfolder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Resolves the current rootURL based on storageMode.
    func resolveRootURL() {
        switch storageMode {
        case .iCloud:
            rootURL = iCloudRootURL()
            #if os(iOS)
            // Fallback to local Documents on iOS if iCloud unavailable
            if rootURL == nil {
                rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("MeetingAgent")
                try? FileManager.default.createDirectory(at: rootURL!, withIntermediateDirectories: true)
            }
            #endif
        case .local:
            #if os(macOS)
            rootURL = localBookmarkURL
            #else
            rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MeetingAgent")
            try? FileManager.default.createDirectory(at: rootURL!, withIntermediateDirectories: true)
            #endif
        }
    }

    // MARK: - macOS Bookmark Logic

    #if os(macOS)
    func selectLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            saveLocalBookmark(url: url)
            if storageMode == .local {
                resolveRootURL()
            }
        }
    }

    func saveLocalBookmark(url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Keys.folderBookmark)
            localBookmarkURL = url
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }

    private func loadLocalBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Keys.folderBookmark) else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale { saveLocalBookmark(url: url) }
            localBookmarkURL = url
        } catch {
            print("Failed to load bookmark: \(error)")
        }
    }

    /// Wraps a block with security-scoped resource access (only needed for local mode on macOS).
    func withScopedAccess<T>(_ body: () throws -> T) rethrows -> T? {
        guard storageMode == .local, let url = localBookmarkURL else {
            return try body()
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body()
    }
    #endif

    // MARK: - Save Meeting

    /// Creates a timestamped meeting folder and saves transcript + media files.
    /// Returns the meeting folder URL on success.
    @discardableResult
    func saveMeeting(
        transcript: String,
        title: String,
        notes: String,
        audioURL: URL? = nil,
        videoURL: URL? = nil
    ) throws -> URL {
        guard let root = rootURL else {
            throw StorageError.noSaveLocation
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())

        let meetingFolder = root.appendingPathComponent(timestamp)
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        // Build transcript.md
        let titleTrimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesTrimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let displayDate = displayFormatter.string(from: Date())

        var sections: [String] = []
        sections.append(titleTrimmed.isEmpty ? displayDate : "# \(titleTrimmed)\n\(displayDate)")
        if !notesTrimmed.isEmpty {
            sections.append("## Meeting Notes\n\n\(notesTrimmed)")
        }
        let finalText = sections.joined(separator: "\n\n---\n\n") + "\n\n---\n\n## Transcript\n\n\(transcript)"
        try finalText.write(to: meetingFolder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)

        // Copy audio. The WAV-fallback path (M4A conversion failure) hands us a .wav —
        // keep the real extension so players and retranscribe can open the file.
        if let audioURL = audioURL, FileManager.default.fileExists(atPath: audioURL.path) {
            let ext = audioURL.pathExtension.lowercased() == "wav" ? "wav" : "m4a"
            try FileManager.default.copyItem(at: audioURL, to: meetingFolder.appendingPathComponent("audio.\(ext)"))
        }

        // Copy video
        if let videoURL = videoURL, FileManager.default.fileExists(atPath: videoURL.path) {
            try FileManager.default.copyItem(at: videoURL, to: meetingFolder.appendingPathComponent("video.mov"))
        }

        return meetingFolder
    }

    // MARK: - Load Library

    func loadMeetingLibrary() -> [MeetingRecord] {
        guard let root = rootURL else { return [] }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH-mm-ss"

        return contents
            .filter { url in
                var isDir = ObjCBool(false)
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue && dateFormatter.date(from: url.lastPathComponent) != nil
            }
            .compactMap { parseMeetingRecord(from: $0, dateFormatter: dateFormatter) }
            .sorted { $0.date > $1.date }
    }

    private func parseMeetingRecord(from folderURL: URL, dateFormatter: DateFormatter) -> MeetingRecord? {
        guard let date = dateFormatter.date(from: folderURL.lastPathComponent) else { return nil }
        let fm = FileManager.default
        let hasAudio = fm.fileExists(atPath: folderURL.appendingPathComponent("audio.m4a").path)
            || fm.fileExists(atPath: folderURL.appendingPathComponent("audio.wav").path)
        let hasVideo = fm.fileExists(atPath: folderURL.appendingPathComponent("video.mov").path)

        let transcriptURL = folderURL.appendingPathComponent("transcript.md")
        var title: String? = nil
        var content: String? = nil
        if let text = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            content = text
            if let firstLine = text.components(separatedBy: "\n").first, firstLine.hasPrefix("# ") {
                title = String(firstLine.dropFirst(2))
            }
        }

        return MeetingRecord(
            folderURL: folderURL,
            folderName: folderURL.lastPathComponent,
            title: title,
            date: date,
            hasAudio: hasAudio,
            hasVideo: hasVideo,
            transcriptContent: content
        )
    }

    // MARK: - Errors

    enum StorageError: LocalizedError {
        case noSaveLocation
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noSaveLocation: return "No save location selected"
            case .permissionDenied: return "Permission denied to access folder"
            }
        }
    }
}
