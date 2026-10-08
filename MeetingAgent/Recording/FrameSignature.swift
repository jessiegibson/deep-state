import Foundation
import CoreGraphics

/// A tiny grayscale fingerprint of a captured frame, used to decide whether a new
/// screenshot is worth keeping.
///
/// A slide held on screen for ten minutes would otherwise produce one near-identical
/// JPEG per interval — bulk that costs disk and, more importantly, makes a downstream
/// agent read two hundred images to learn one thing. Downscaling to 16×16 grayscale
/// throws away exactly the detail that changes between two shots of the same screen
/// (cursor position, a blinking caret, antialiasing) while preserving layout, so a
/// real change — a scroll, a new slide, a window switch — still reads as different.
struct FrameSignature: Equatable {
    /// 16×16 = 256 samples. Small enough that comparison is free, large enough that a
    /// paragraph-sized change still moves the mean.
    static let dimension = 16

    let samples: [UInt8]

    init(samples: [UInt8]) {
        self.samples = samples
    }

    /// Downscales `image` to a `dimension`×`dimension` grayscale buffer.
    /// Returns nil if the context can't be created or the draw fails.
    static func make(from image: CGImage) -> FrameSignature? {
        let side = dimension
        let count = side * side

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        defer {
            buffer.deinitialize(count: count)
            buffer.deallocate()
        }

        guard let context = CGContext(
            data: buffer,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Low interpolation is the point, not a compromise: averaging hard is what
        // makes cosmetic differences vanish.
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        return FrameSignature(samples: Array(UnsafeBufferPointer(start: buffer, count: count)))
    }

    /// Mean absolute difference per sample, on the 0...255 scale of the samples
    /// themselves. Signatures of different sizes are treated as maximally different
    /// rather than compared elementwise against a shorter array.
    func meanAbsoluteDifference(from other: FrameSignature) -> Double {
        guard samples.count == other.samples.count, !samples.isEmpty else {
            return .greatestFiniteMagnitude
        }

        var total = 0
        for (lhs, rhs) in zip(samples, other.samples) {
            total += abs(Int(lhs) - Int(rhs))
        }
        return Double(total) / Double(samples.count)
    }
}

enum ScreenshotDedup {
    /// Chosen so cursor movement and text-caret blink read as "same" while a scroll,
    /// a slide change or a window switch reads as "different". Raising it drops more
    /// frames; lowering it keeps more.
    static let defaultThreshold: Double = 3.0

    /// Whether `candidate` is different enough from the last frame that was actually
    /// **saved** to be worth saving too.
    ///
    /// Comparing against the last *saved* frame rather than the last *captured* one is
    /// deliberate: against the last captured frame, a slow drift — a page scrolling a
    /// few pixels per interval — would stay under the threshold on every single
    /// comparison and nothing after the first frame would ever be written, even as the
    /// screen changed completely.
    ///
    /// A nil `lastSaved` is the first frame of a session, which is always kept.
    static func isDistinct(_ candidate: FrameSignature,
                           from lastSaved: FrameSignature?,
                           threshold: Double = defaultThreshold) -> Bool {
        guard let lastSaved else { return true }
        return candidate.meanAbsoluteDifference(from: lastSaved) > threshold
    }
}
