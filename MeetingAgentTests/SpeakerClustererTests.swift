import XCTest
@testable import deep_state_Meeting_Agent

/// Guards the crash fixed on 2026-06-10: voice-analytics frames containing Inf/NaN
/// (observed with Bluetooth microphones) made the k-means++ distance sum infinite,
/// trapping at runtime in Double.random(in: 0..<Inf) inside kMeansPlusPlusInit.
final class SpeakerClustererTests: XCTestCase {
    private func vector(pitch: Double, voicing: Double = 0.5, jitter: Double = 0.1,
                        shimmer: Double = 0.1, t: Double) -> VoiceFeatureVector {
        VoiceFeatureVector(pitch: pitch, voicing: voicing, jitter: jitter,
                           shimmer: shimmer, timestamp: t, duration: 1)
    }

    func testClusterSurvivesNonFiniteFeatureValues() {
        var vectors: [VoiceFeatureVector] = []
        for i in 0..<6 { vectors.append(vector(pitch: 100 + Double(i), t: Double(i))) }
        for i in 6..<12 { vectors.append(vector(pitch: 220 + Double(i), t: Double(i))) }
        vectors.append(vector(pitch: .infinity, t: 12))
        vectors.append(vector(pitch: .nan, t: 13))

        let assignments = SpeakerClusterer.cluster(vectors)
        XCTAssertEqual(assignments.count, vectors.count)
    }

    func testClusterSeparatesTwoDistinctSpeakers() {
        var vectors: [VoiceFeatureVector] = []
        for i in 0..<8 { vectors.append(vector(pitch: 110, voicing: 0.8, t: Double(i))) }
        for i in 8..<16 { vectors.append(vector(pitch: 240, voicing: 0.4, t: Double(i))) }

        let assignments = SpeakerClusterer.cluster(vectors)
        XCTAssertEqual(assignments.count, vectors.count)
        XCTAssertEqual(Set(assignments).count, 2)
    }
}
