import XCTest
import CoreGraphics
@testable import Deep_State_Meeting_Agent_MacOS

/// Covers the near-identical-frame suppression that keeps a slide held for ten minutes
/// from producing one JPEG per interval.
final class FrameSignatureTests: XCTestCase {

    private let sampleCount = FrameSignature.dimension * FrameSignature.dimension

    private func uniform(_ value: UInt8) -> FrameSignature {
        FrameSignature(samples: Array(repeating: value, count: sampleCount))
    }

    /// A uniform frame with `changed` samples bumped by `delta`.
    private func uniform(_ value: UInt8, changing changed: Int, by delta: Int) -> FrameSignature {
        var samples = Array(repeating: value, count: sampleCount)
        for i in 0..<min(changed, sampleCount) {
            samples[i] = UInt8(clamping: Int(value) + delta)
        }
        return FrameSignature(samples: samples)
    }

    // MARK: meanAbsoluteDifference

    func testIdenticalSignaturesHaveZeroDifference() {
        XCTAssertEqual(uniform(128).meanAbsoluteDifference(from: uniform(128)), 0, accuracy: 0.0001)
    }

    func testDifferenceIsTheMeanOverAllSamples() {
        // Half the samples differ by 8 -> mean absolute difference of 4.
        let a = uniform(100)
        let b = uniform(100, changing: sampleCount / 2, by: 8)
        XCTAssertEqual(a.meanAbsoluteDifference(from: b), 4, accuracy: 0.0001)
    }

    func testDifferenceIsSymmetric() {
        let a = uniform(40)
        let b = uniform(40, changing: 30, by: 60)
        XCTAssertEqual(a.meanAbsoluteDifference(from: b),
                       b.meanAbsoluteDifference(from: a),
                       accuracy: 0.0001)
    }

    func testFullyInvertedFrameIsMaximallyDifferent() {
        XCTAssertEqual(uniform(0).meanAbsoluteDifference(from: uniform(255)), 255, accuracy: 0.0001)
    }

    /// Mismatched sizes are treated as maximally different rather than compared against
    /// a shorter array — a truncated signature must never read as "same".
    func testMismatchedSizesAreMaximallyDifferent() {
        let short = FrameSignature(samples: [1, 2, 3])
        XCTAssertEqual(uniform(1).meanAbsoluteDifference(from: short), .greatestFiniteMagnitude)
    }

    func testEmptySignatureIsMaximallyDifferent() {
        let empty = FrameSignature(samples: [])
        XCTAssertEqual(empty.meanAbsoluteDifference(from: empty), .greatestFiniteMagnitude)
    }

    // MARK: isDistinct

    /// The first frame of a session has nothing to compare against and is always kept.
    func testFirstFrameIsAlwaysDistinct() {
        XCTAssertTrue(ScreenshotDedup.isDistinct(uniform(10), from: nil))
    }

    func testIdenticalFrameIsNotDistinct() {
        XCTAssertFalse(ScreenshotDedup.isDistinct(uniform(128), from: uniform(128)))
    }

    /// A cursor moving, or a caret blinking, changes a handful of samples slightly.
    func testCosmeticChangeIsNotDistinct() {
        let previous = uniform(128)
        let candidate = uniform(128, changing: 4, by: 40)   // mean diff = 160/256 ≈ 0.625
        XCTAssertFalse(ScreenshotDedup.isDistinct(candidate, from: previous))
    }

    /// A new slide or a scroll changes most of the frame.
    func testSubstantialChangeIsDistinct() {
        XCTAssertTrue(ScreenshotDedup.isDistinct(uniform(200), from: uniform(20)))
    }

    func testThresholdBoundaryIsExclusive() {
        let previous = uniform(0)
        // Every sample differs by exactly 3 -> mean difference of exactly 3.0.
        let candidate = uniform(0, changing: sampleCount, by: 3)
        XCTAssertEqual(candidate.meanAbsoluteDifference(from: previous), 3.0, accuracy: 0.0001)
        XCTAssertFalse(ScreenshotDedup.isDistinct(candidate, from: previous, threshold: 3.0),
                       "a difference exactly at the threshold should not count as distinct")
        XCTAssertTrue(ScreenshotDedup.isDistinct(candidate, from: previous, threshold: 2.9))
    }

    func testCustomThresholdIsHonoured() {
        let previous = uniform(100)
        let candidate = uniform(100, changing: sampleCount, by: 10)  // mean diff = 10
        XCTAssertTrue(ScreenshotDedup.isDistinct(candidate, from: previous, threshold: 5))
        XCTAssertFalse(ScreenshotDedup.isDistinct(candidate, from: previous, threshold: 20))
    }

    // MARK: make(from:)

    /// Builds a solid-colour CGImage so the downscale path runs on real image data.
    private func solidImage(gray: UInt8, side: Int = 64) -> CGImage? {
        let count = side * side
        var pixels = [UInt8](repeating: gray, count: count)
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    func testMakeProducesExpectedSampleCount() throws {
        let image = try XCTUnwrap(solidImage(gray: 90))
        let signature = try XCTUnwrap(FrameSignature.make(from: image))
        XCTAssertEqual(signature.samples.count, sampleCount)
    }

    func testMakeOnSolidImagesReflectsBrightness() throws {
        let dark = try XCTUnwrap(FrameSignature.make(from: try XCTUnwrap(solidImage(gray: 10))))
        let light = try XCTUnwrap(FrameSignature.make(from: try XCTUnwrap(solidImage(gray: 240))))

        XCTAssertFalse(ScreenshotDedup.isDistinct(dark, from: dark))
        XCTAssertTrue(ScreenshotDedup.isDistinct(light, from: dark))
    }
}
