#if os(macOS)
import Foundation
import AppKit
import UniformTypeIdentifiers

/// Imports external audio/video files (transcribe + save) and retranscribes existing
/// recordings. Extracted from `MeetingManager`. Progress/status flow back through
/// callbacks so the coordinator keeps the published properties its views bind to.
///
/// Audio transforms are injected so this type doesn't own the transcription/recording
/// engines: `transcribe` (WhisperTranscriber), `extractAudio` (video→audio), and
/// `convertToM4A` (AudioRecorder).
@MainActor
final class FileImportService {
    private let storage = StorageManager.shared

    // Injected audio transforms
    var transcribe: ((URL) async -> String)?
    var extractAudio: ((URL) async throws -> URL?)?
    var convertToM4A: ((URL) async throws -> URL)?

    // UI callbacks
    var onImportingChanged: ((Bool) -> Void)?
    var onImportProgress: ((String) -> Void)?
    var onRetranscribingChanged: ((Bool) -> Void)?
    var onRetranscribeProgress: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onLibraryChanged: (() -> Void)?

    // MARK: - Import External Files

    func importFiles() async {
        guard storage.rootURL != nil else {
            onStatus?("Select a save folder first")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = "Select audio or video files to import and transcribe"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let urls = panel.urls
        onImportingChanged?(true)
        onImportProgress?("")

        for (index, url) in urls.enumerated() {
            await importSingleFile(fileURL: url, index: index, total: urls.count)
        }

        onImportingChanged?(false)
        onImportProgress?("")
        onLibraryChanged?()
        onStatus?("Imported \(urls.count) file\(urls.count == 1 ? "" : "s")")
    }

    private func importSingleFile(fileURL: URL, index: Int, total: Int) async {
        let filename = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        onImportProgress?("Processing \(filename) (\(index + 1)/\(total))...")

        _ = fileURL.startAccessingSecurityScopedResource()
        defer { fileURL.stopAccessingSecurityScopedResource() }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory

        do {
            // Copy to temp to avoid sandbox issues
            let tempCopy = tempDir.appendingPathComponent("import_\(UUID().uuidString).\(ext)")
            try? fm.removeItem(at: tempCopy)
            try fm.copyItem(at: fileURL, to: tempCopy)
            defer { try? fm.removeItem(at: tempCopy) }

            let videoExtensions = ["mov", "mp4", "m4v"]
            let isVideo = videoExtensions.contains(ext)

            var audioURL: URL
            var videoURL: URL? = nil

            if isVideo {
                onImportProgress?("Extracting audio from \(filename) (\(index + 1)/\(total))...")
                guard let extracted = try await extractAudio?(tempCopy) ?? nil else {
                    print("❌ Failed to extract audio from \(filename)")
                    return
                }
                audioURL = extracted
                videoURL = tempCopy
            } else if ext == "m4a" {
                audioURL = tempCopy
            } else {
                onImportProgress?("Converting \(filename) (\(index + 1)/\(total))...")
                guard let converted = try await convertToM4A?(tempCopy) else { return }
                audioURL = converted
            }
            defer {
                if audioURL != tempCopy { try? fm.removeItem(at: audioURL) }
            }

            onImportProgress?("Transcribing \(filename) (\(index + 1)/\(total))...")
            let transcript = await transcribe?(audioURL) ?? ""

            // Get file creation date for the folder timestamp
            let resourceValues = try? fileURL.resourceValues(forKeys: [.creationDateKey])
            let fileDate = resourceValues?.creationDate ?? Date()

            onImportProgress?("Saving \(filename) (\(index + 1)/\(total))...")
            saveImportedFile(transcript: transcript, title: filename, audioURL: audioURL, videoURL: videoURL, date: fileDate)

        } catch {
            print("❌ Import error for \(filename): \(error.localizedDescription)")
        }
    }

    private func saveImportedFile(transcript: String, title: String, audioURL: URL, videoURL: URL? = nil, date: Date) {
        _ = try? storage.withScopedAccess {
            try self.storage.saveMeeting(
                transcript: transcript,
                title: title,
                notes: "",
                audioURL: audioURL,
                videoURL: videoURL
            )
        }
    }

    // MARK: - Retranscribe Existing Recordings

    func retranscribe(record: MeetingRecord) async {
        guard record.hasAudio else {
            onStatus?("No audio file to retranscribe")
            return
        }

        onRetranscribingChanged?(true)
        onRetranscribeProgress?("Retranscribing \(record.displayTitle)...")

        guard storage.rootURL != nil else {
            onRetranscribingChanged?(false)
            return
        }

        let audioURL = record.folderURL.appendingPathComponent("audio.m4a")

        let exists = storage.withScopedAccess {
            FileManager.default.fileExists(atPath: audioURL.path)
        }
        guard exists == true else {
            onStatus?("Audio file not found")
            onRetranscribingChanged?(false)
            return
        }

        let newTranscript = await transcribe?(audioURL) ?? ""

        // Update transcript.md preserving title and notes
        _ = storage.withScopedAccess {
            let transcriptURL = record.folderURL.appendingPathComponent("transcript.md")
            if let existingContent = try? String(contentsOf: transcriptURL, encoding: .utf8) {
                let updated = self.replaceTranscriptSection(in: existingContent, with: newTranscript)
                try? updated.write(to: transcriptURL, atomically: true, encoding: .utf8)
            } else {
                try? ("## Transcript\n\n\(newTranscript)").write(to: transcriptURL, atomically: true, encoding: .utf8)
            }
        }

        onRetranscribingChanged?(false)
        onRetranscribeProgress?("")
        onLibraryChanged?()
        onStatus?("Retranscription complete")
    }

    func retranscribeBatch(records: [MeetingRecord]) async {
        onRetranscribingChanged?(true)
        for (i, record) in records.enumerated() {
            onRetranscribeProgress?("Retranscribing \(i + 1) of \(records.count): \(record.displayTitle)...")
            await retranscribe(record: record)
        }
        onRetranscribingChanged?(false)
        onRetranscribeProgress?("")
        onStatus?("Batch retranscription complete (\(records.count) files)")
    }

    private func replaceTranscriptSection(in existingContent: String, with newTranscript: String) -> String {
        let separator = "\n\n---\n\n"
        let sections = existingContent.components(separatedBy: separator)

        // Find the section that starts with "## Transcript"
        var headerSections: [String] = []
        for section in sections {
            if section.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## Transcript") {
                break
            }
            headerSections.append(section)
        }

        if headerSections.isEmpty {
            return "## Transcript\n\n\(newTranscript)"
        }

        return headerSections.joined(separator: separator) + separator + "## Transcript\n\n\(newTranscript)"
    }
}
#endif
