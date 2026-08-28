#if os(macOS)
import Foundation
import AppKit
import AVFoundation
import CoreMedia

/// Pulls still frames out of an already-saved recording's `video.mov`.
///
/// The Library counterpart to live capture: it covers meetings recorded before
/// screenshots existed, and screen recordings where live capture was left off. Frames
/// land in the same `screenshots/` folder and are described by the same
/// `screenshots.json`, so a consumer cannot tell — and does not need to care — which
/// path produced them beyond the manifest's `source` field.
///
/// Shaped after `FileImportService`: callbacks out, writes through
/// `StorageManager`'s scoped access, and `onLibraryChanged` at the end.
@MainActor
final class VideoFrameExtractor {

    var onProgress: ((String) -> Void)?
    var onExtractingChanged: ((Bool) -> Void)?
    var onStatus: ((AppStatus) -> Void)?
    var onLibraryChanged: (() -> Void)?

    /// Extracts frames from `record`'s video at `interval`.
    ///
    /// Refuses when the folder already holds screenshots. Extraction would otherwise
    /// have to either merge with frames it knows nothing about or delete them, and
    /// silently discarding a live capture is not a reasonable reading of "extract
    /// frames".
    @discardableResult
    func extract(from record: MeetingRecord,
                 interval: ScreenshotInterval,
                 storage: StorageManager) async -> Int {

        guard !record.hasScreenshots else {
            onStatus?(.success("\(record.displayTitle) already has \(record.screenshotCount) screenshots"))
            return 0
        }

        let videoURL = record.folderURL.appendingPathComponent("video.mov")

        onExtractingChanged?(true)
        onProgress?("Extracting frames from \(record.displayTitle)…")
        defer {
            onExtractingChanged?(false)
            onProgress?("")
        }

        // nil  -> the security-scoped bookmark refused to open
        // -1    -> no video file in the folder (an audio-only recording)
        // 0     -> a video, but nothing could be extracted from it
        // No explicit closure signature: an `() -> Int` annotation would declare a
        // non-async closure type and fail to match the async parameter.
        let written: Int? = await storage.withScopedAccessAsync {
            guard FileManager.default.fileExists(atPath: videoURL.path) else { return -1 }
            return await self.extractFrames(from: videoURL,
                                            into: record,
                                            interval: interval)
        }

        switch written {
        case .none:
            onStatus?(.failure(.saveLocationDenied))
            return 0
        case .some(-1):
            onStatus?(.failure(.noRecordingFound))
            return 0
        case .some(0):
            onStatus?(.failure(.saveFailed("No frames could be extracted")))
            return 0
        case .some(let count):
            onStatus?(.success("Extracted \(count) screenshots from \(record.displayTitle)"))
            onLibraryChanged?()
            return count
        }
    }

    // MARK: - Extraction

    private func extractFrames(from videoURL: URL,
                               into record: MeetingRecord,
                               interval: ScreenshotInterval) async -> Int {
        let asset = AVURLAsset(url: videoURL)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Frames must land where they are asked for: a tolerant generator will happily
        // return the same keyframe for several requested times, which reads downstream
        // as "the screen did not change" when in fact it was never sampled.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: ScreenshotCapture.maxPixelDimension,
                                       height: ScreenshotCapture.maxPixelDimension)

        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            return 0
        }

        let destination = record.screenshotsFolderURL
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            print("[VideoFrameExtractor] could not create screenshots folder: \(error)")
            return 0
        }

        var entries: [ScreenshotManifest.Entry] = []
        var lastSavedSignature: FrameSignature?
        var elapsed: Double = 0
        let step = interval.seconds
        let total = duration.seconds

        while elapsed <= total, entries.count < ScreenshotCapture.maxFrames {
            let time = CMTime(seconds: elapsed, preferredTimescale: 600)

            guard let image = try? await generator.image(at: time).image else {
                // A single unreadable time is not fatal — keep walking the asset.
                elapsed += step
                continue
            }

            let signature = FrameSignature.make(from: image)
            // An unbuildable signature means similarity cannot be judged; keep the
            // frame rather than dropping content we cannot reason about.
            if let signature, !ScreenshotDedup.isDistinct(signature, from: lastSavedSignature) {
                elapsed += step
                continue
            }

            guard let data = NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg,
                                properties: [.compressionFactor: ScreenshotCapture.jpegQuality]) else {
                elapsed += step
                continue
            }

            let index = entries.count + 1
            let name = String(format: "shot_%04d_%06d.jpg", index, Int(elapsed))
            do {
                try data.write(to: destination.appendingPathComponent(name), options: .atomic)
            } catch {
                print("[VideoFrameExtractor] could not write \(name): \(error)")
                elapsed += step
                continue
            }

            entries.append(ScreenshotManifest.Entry(
                file: "screenshots/\(name)",
                index: index,
                elapsedSeconds: elapsed,
                // Frames come from a recording that already happened, so the wall-clock
                // time of a frame is the meeting's start plus its offset — not now.
                capturedAt: record.date.addingTimeInterval(elapsed),
                width: image.width,
                height: image.height,
                byteSize: data.count
            ))
            lastSavedSignature = signature

            onProgress?("Extracting frames… \(entries.count) captured")
            elapsed += step
        }

        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: destination)
            return 0
        }

        writeManifest(entries: entries, record: record, interval: interval, duration: total)
        return entries.count
    }

    private func writeManifest(entries: [ScreenshotManifest.Entry],
                               record: MeetingRecord,
                               interval: ScreenshotInterval,
                               duration: Double) {
        let manifest = ScreenshotManifest(
            meeting: .init(
                title: record.title,
                folderName: record.folderName,
                startedAt: record.date,
                durationSeconds: duration
            ),
            capture: .init(
                source: .videoExtraction,
                intervalSeconds: interval.seconds,
                recordingMode: "screenAndAudio",
                displayName: nil,
                displayWidth: entries.first?.width,
                displayHeight: entries.first?.height,
                deduplicated: true,
                dedupeThreshold: ScreenshotDedup.defaultThreshold
            ),
            screenshots: entries
        )

        do {
            let data = try ScreenshotManifest.encoder().encode(manifest)
            try data.write(to: record.screenshotManifestURL, options: .atomic)
        } catch {
            print("[VideoFrameExtractor] screenshots.json could not be written: \(error)")
        }
    }
}
#endif
