#if os(macOS)
import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Takes still screenshots at a fixed interval for the duration of a recording,
/// staging them in the temporary directory until `StorageManager` files them into the
/// meeting folder.
///
/// Uses one-shot `SCScreenshotManager` captures rather than an `SCStreamOutput` tap on
/// the recording stream, for two reasons. Screen-mode pause tears the `SCStream` down
/// entirely and resume builds a new one, so a stream-attached tap would need
/// re-establishing on every pause cycle; a one-shot capture holds no stream state and
/// is unaffected. And audio-only recordings have no `SCStream` at all — a one-shot
/// capture is the only mechanism that works in both modes, which is what makes the
/// mid-recording toggle possible.
///
/// Nothing in here is allowed to fail a recording. Every error path reports through
/// `onStatus` and returns; losing the meeting because a JPEG could not be written
/// would be strictly worse than losing the screenshots.
@MainActor
final class ScreenshotCapture {

    /// One staged screenshot, before it is moved into the meeting folder.
    struct CapturedFrame {
        let url: URL
        let index: Int
        /// Offset into the recording with paused time excluded, so it lines up with
        /// the audio and the transcript rather than with wall-clock.
        let elapsed: TimeInterval
        let capturedAt: Date
        let width: Int
        let height: Int
        let byteSize: Int
    }

    // MARK: Tuning

    /// Ceiling on a single session, so a recording left running overnight cannot fill
    /// the disk. At the 15s preset this is over eight hours before dedup.
    static let maxFrames = 2000

    /// Long-edge cap in pixels. Native capture on a 6K display is far more detail than
    /// a downstream reader needs and costs several MB a frame; 2560 keeps UI text
    /// legible at a fraction of the size.
    static let maxPixelDimension = 2560

    static let jpegQuality: Double = 0.72

    private static let stagingDirectoryName = "deepstate_screenshots"

    // MARK: Configuration

    var selectedDisplayID: CGDirectDisplayID?

    /// Non-fatal trouble worth showing the user (permission refused, a failed capture,
    /// the frame cap reached). nil clears the note.
    var onStatus: ((String?) -> Void)?
    var onCountChanged: ((Int) -> Void)?

    // MARK: State

    private(set) var frames: [CapturedFrame] = []
    private(set) var displayName: String?
    private(set) var displayWidth: Int?
    private(set) var displayHeight: Int?

    /// Whether the user has screenshots switched on. Stays true across a pause — the
    /// loop is torn down while paused, but the toggle must still read as ON.
    private(set) var isEnabled = false

    private var captureTask: Task<Void, Never>?
    private var interval: TimeInterval = ScreenshotInterval.default.seconds
    private var lastSavedSignature: FrameSignature?

    // Elapsed clock. Paused spans are accumulated and subtracted so offsets match the
    // audio timeline, which also excludes paused time.
    private var startedAt: Date?
    private var accumulatedPause: TimeInterval = 0
    private var pausedAt: Date?

    private var stagingDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
    }

    /// Recording time so far, frozen while paused.
    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        let reference = pausedAt ?? Date()
        return max(0, reference.timeIntervalSince(startedAt) - accumulatedPause)
    }

    // MARK: Lifecycle

    /// Clears staged frames and resets the clock. Call at the start of every recording,
    /// whether or not screenshots are enabled, so a previous session's frames can never
    /// be filed into this meeting's folder.
    func reset() {
        captureTask?.cancel()
        captureTask = nil
        isEnabled = false
        frames = []
        lastSavedSignature = nil
        startedAt = nil
        accumulatedPause = 0
        pausedAt = nil
        displayName = nil
        displayWidth = nil
        displayHeight = nil

        try? FileManager.default.removeItem(at: stagingDirectory)
        onCountChanged?(0)
        onStatus?(nil)
    }

    /// Starts capturing every `interval` seconds. The first frame is taken immediately
    /// rather than after one interval: a recording shorter than the interval would
    /// otherwise yield nothing, and flipping the toggle mid-recording would appear to
    /// do nothing until the interval elapsed.
    func start(interval: TimeInterval) {
        self.interval = max(1, interval)
        isEnabled = true
        if startedAt == nil { startedAt = Date() }
        pausedAt = nil
        launchLoop()
    }

    /// Suspends capture and stops the elapsed clock. The staged frames are kept.
    func pause() {
        guard isEnabled, pausedAt == nil else { return }
        pausedAt = Date()
        captureTask?.cancel()
        captureTask = nil
    }

    func resume() {
        guard isEnabled, let pausedAt else { return }
        accumulatedPause += Date().timeIntervalSince(pausedAt)
        self.pausedAt = nil
        launchLoop()
    }

    /// Stops capturing and waits for any capture already in flight to finish, so no
    /// write is still running when the caller starts tearing down the recording.
    /// Frames captured so far are deliberately kept — switching screenshots off
    /// mid-recording should not discard what was already taken.
    func stop() async {
        isEnabled = false
        let task = captureTask
        captureTask = nil
        task?.cancel()
        await task?.value
        pausedAt = nil
    }

    private func launchLoop() {
        guard captureTask == nil else { return }
        let seconds = interval
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureOne()
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return  // cancelled
                }
            }
        }
    }

    // MARK: Capture

    private func captureOne() async {
        guard frames.count < Self.maxFrames else {
            onStatus?("Screenshot limit reached (\(Self.maxFrames)) — capture stopped.")
            isEnabled = false
            captureTask?.cancel()
            captureTask = nil
            return
        }

        do {
            let (filter, display) = try await ScreenRecorder.makeContentFilter(displayID: selectedDisplayID)

            let config = SCStreamConfiguration()
            let scale = min(1.0, Double(Self.maxPixelDimension) / Double(max(display.width, display.height)))
            config.width = max(1, Int((Double(display.width) * scale).rounded()))
            config.height = max(1, Int((Double(display.height) * scale).rounded()))

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: config)

            // Record which display these frames came from, for the manifest.
            if displayName == nil {
                displayName = ScreenRecorder.localizedName(for: display.displayID)
                displayWidth = config.width
                displayHeight = config.height
            }

            try save(image)
            onStatus?(nil)
        } catch {
            // A single failed capture is not worth stopping over — the next tick may
            // well succeed (a display woke, a space finished switching).
            print("[ScreenshotCapture] capture failed: \(error)")
            onStatus?("Screenshot failed: \(error.localizedDescription)")
        }
    }

    /// Encodes and writes `image`, unless it is near-identical to the last frame that
    /// was actually saved.
    private func save(_ image: CGImage) throws {
        let signature = FrameSignature.make(from: image)

        // A signature that could not be built means we cannot judge similarity. Keep
        // the frame rather than silently dropping content we can't reason about.
        if let signature,
           !ScreenshotDedup.isDistinct(signature, from: lastSavedSignature) {
            return
        }

        guard let data = jpegData(from: image) else {
            onStatus?("Screenshot could not be encoded.")
            return
        }

        let directory = stagingDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let index = frames.count + 1
        let seconds = elapsed
        // Index and elapsed seconds are both in the name so the sequence survives even
        // if the manifest is lost or the folder is read by something that ignores it.
        let name = String(format: "shot_%04d_%06d.jpg", index, Int(seconds))
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)

        frames.append(CapturedFrame(
            url: url,
            index: index,
            elapsed: seconds,
            capturedAt: Date(),
            width: image.width,
            height: image.height,
            byteSize: data.count
        ))
        lastSavedSignature = signature
        onCountChanged?(frames.count)
    }

    private func jpegData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: Self.jpegQuality])
    }
}
#endif
