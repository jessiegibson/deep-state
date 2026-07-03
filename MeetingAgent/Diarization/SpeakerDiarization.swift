import Foundation
import Speech
import Accelerate

// MARK: - Data Models

struct VoiceFeatureVector {
    let pitch: Double       // fundamental frequency
    let voicing: Double     // voiced phoneme ratio
    let jitter: Double      // pitch variation
    let shimmer: Double     // amplitude variation
    let timestamp: TimeInterval
    let duration: TimeInterval

    func distance(to other: VoiceFeatureVector) -> Double {
        // Normalized Euclidean distance across all 4 features
        let dp = (pitch - other.pitch) * (pitch - other.pitch)
        let dv = (voicing - other.voicing) * (voicing - other.voicing)
        let dj = (jitter - other.jitter) * (jitter - other.jitter)
        let ds = (shimmer - other.shimmer) * (shimmer - other.shimmer)
        return sqrt(dp + dv + dj + ds)
    }
}

struct SpeakerSegment: Identifiable {
    let id: UUID
    var clusterID: Int          // assigned by k-means, 0-based
    var speakerName: String?    // nil until user labels
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let features: VoiceFeatureVector

    var duration: TimeInterval { endTime - startTime }
    var displayName: String { speakerName ?? "Speaker \(clusterID + 1)" }
}

struct SpeakerVoicePrint: Codable {
    let name: String
    let meanPitch: Double
    let meanVoicing: Double
    let meanJitter: Double
    let meanShimmer: Double
    var sampleCount: Int

    func distance(to features: VoiceFeatureVector) -> Double {
        let dp = (meanPitch - features.pitch) * (meanPitch - features.pitch)
        let dv = (meanVoicing - features.voicing) * (meanVoicing - features.voicing)
        let dj = (meanJitter - features.jitter) * (meanJitter - features.jitter)
        let ds = (meanShimmer - features.shimmer) * (meanShimmer - features.shimmer)
        return sqrt(dp + dv + dj + ds)
    }

    /// Weighted update: blend this voice print with new segment data
    func updated(with features: VoiceFeatureVector) -> SpeakerVoicePrint {
        let n = Double(sampleCount)
        let w = 1.0 / (n + 1.0)
        return SpeakerVoicePrint(
            name: name,
            meanPitch: meanPitch * (n / (n + 1)) + features.pitch * w,
            meanVoicing: meanVoicing * (n / (n + 1)) + features.voicing * w,
            meanJitter: meanJitter * (n / (n + 1)) + features.jitter * w,
            meanShimmer: meanShimmer * (n / (n + 1)) + features.shimmer * w,
            sampleCount: sampleCount + 1
        )
    }
}

// MARK: - Voice Analytics Collector

/// Collects SFVoiceAnalytics data from live SFSpeechRecognizer results.
///
/// Uses `SFSpeechRecognitionMetadata.voiceAnalytics` (non-deprecated, macOS 11.3+),
/// which provides frame-level analytics for the entire result. We map those frames
/// back to individual transcription segments using timestamp proportions, giving us
/// per-segment feature vectors without touching the deprecated segment-level API.
///
/// `speechRecognitionMetadata` is only populated on final results, which is fine —
/// we only cluster after recording stops, not in real time.
final class VoiceAnalyticsCollector {
    private(set) var vectors: [VoiceFeatureVector] = []

    func ingest(result: SFSpeechRecognitionResult) {
        // Only process final results — metadata is nil on partial results
        guard let metadata = result.speechRecognitionMetadata,
              let analytics = metadata.voiceAnalytics else { return }

        let segments = result.bestTranscription.segments
        guard let lastSegment = segments.last else { return }

        let totalDuration = lastSegment.timestamp + lastSegment.duration
        guard totalDuration > 0 else { return }

        let pitchFrames   = analytics.pitch.acousticFeatureValuePerFrame
        let voicingFrames = analytics.voicing.acousticFeatureValuePerFrame
        let jitterFrames  = analytics.jitter.acousticFeatureValuePerFrame
        let shimmerFrames = analytics.shimmer.acousticFeatureValuePerFrame
        let frameCount    = Double(pitchFrames.count)
        guard frameCount > 0 else { return }

        // Replace any earlier partial-result vectors for this utterance with
        // the accurate final-result data
        vectors.removeAll()

        for segment in segments {
            let startFrac = segment.timestamp / totalDuration
            let endFrac   = min((segment.timestamp + segment.duration) / totalDuration, 1.0)
            let startIdx  = Int(startFrac * frameCount)
            let endIdx    = min(Int(endFrac * frameCount), pitchFrames.count - 1)
            guard startIdx < endIdx else { continue }

            let range = startIdx...endIdx
            let vector = VoiceFeatureVector(
                pitch:    pitchFrames[range].mean(),
                voicing:  voicingFrames[range].mean(),
                jitter:   jitterFrames[range].mean(),
                shimmer:  shimmerFrames[range].mean(),
                timestamp: segment.timestamp,
                duration:  segment.duration
            )
            // Analytics frames can contain Inf/NaN (seen with Bluetooth mics);
            // a single non-finite feature makes k-means++ trap on
            // Double.random(in: 0..<Inf). Drop such vectors at the source.
            guard vector.pitch.isFinite, vector.voicing.isFinite,
                  vector.jitter.isFinite, vector.shimmer.isFinite else { continue }
            if vector.pitch > 0 || vector.voicing > 0 {
                vectors.append(vector)
            }
        }
    }

    func reset() { vectors = [] }
}

// MARK: - K-Means Speaker Clustering

struct SpeakerClusterer {

    /// Cluster feature vectors into k groups. Returns cluster assignment per vector.
    /// Automatically estimates k (2–4) if not specified.
    static func cluster(_ vectors: [VoiceFeatureVector], maxSpeakers: Int = 4) -> [Int] {
        guard vectors.count >= 2 else { return Array(repeating: 0, count: vectors.count) }

        // Estimate best k using elbow method on inertia
        let bestK = estimateK(vectors: vectors, maxK: min(maxSpeakers, vectors.count))
        return kMeans(vectors: vectors, k: bestK)
    }

    private static func estimateK(vectors: [VoiceFeatureVector], maxK: Int) -> Int {
        guard maxK > 1 else { return 1 }
        var inertias: [Double] = []
        for k in 1...maxK {
            let assignments = kMeans(vectors: vectors, k: k)
            inertias.append(inertia(vectors: vectors, assignments: assignments, k: k))
        }
        // Find elbow: largest drop in inertia improvement
        if inertias.count < 2 { return 1 }
        var bestK = 1
        var maxDrop = 0.0
        for i in 1..<inertias.count {
            let drop = inertias[i - 1] - inertias[i]
            let relDrop = inertias[i - 1] > 0 ? drop / inertias[i - 1] : 0
            // Only increase k if the improvement is meaningful (>15%)
            if relDrop > 0.15 && relDrop > maxDrop {
                maxDrop = relDrop
                bestK = i + 1
            }
        }
        return bestK
    }

    private static func kMeans(vectors: [VoiceFeatureVector], k: Int, iterations: Int = 30) -> [Int] {
        guard k > 0, !vectors.isEmpty else { return [] }
        guard k < vectors.count else { return Array(0..<vectors.count) }

        // Initialize centroids using k-means++ for better convergence
        var centroids = kMeansPlusPlusInit(vectors: vectors, k: k)
        var assignments = Array(repeating: 0, count: vectors.count)

        for _ in 0..<iterations {
            // Assignment step
            var changed = false
            for (i, v) in vectors.enumerated() {
                let nearest = centroids.enumerated().min(by: { v.distance(to: $0.element) < v.distance(to: $1.element) })?.offset ?? 0
                if assignments[i] != nearest { changed = true }
                assignments[i] = nearest
            }
            if !changed { break }

            // Update step: recompute centroids as mean of assigned vectors
            centroids = (0..<k).map { cluster in
                let members = zip(vectors, assignments).filter { $0.1 == cluster }.map { $0.0 }
                guard !members.isEmpty else { return centroids[cluster] }
                return meanVector(members)
            }
        }
        return assignments
    }

    private static func kMeansPlusPlusInit(vectors: [VoiceFeatureVector], k: Int) -> [VoiceFeatureVector] {
        var centroids: [VoiceFeatureVector] = [vectors.randomElement()!]
        while centroids.count < k {
            let distances = vectors.map { v -> Double in
                let d = centroids.map { v.distance(to: $0) }.min() ?? 0
                return d.isFinite ? d : 0
            }
            let total = distances.reduce(0, +)
            guard total > 0, total.isFinite else { centroids.append(vectors.randomElement()!); continue }
            var r = Double.random(in: 0..<total)
            for (i, d) in distances.enumerated() {
                r -= d
                if r <= 0 { centroids.append(vectors[i]); break }
            }
        }
        return centroids
    }

    private static func meanVector(_ vectors: [VoiceFeatureVector]) -> VoiceFeatureVector {
        let n = Double(vectors.count)
        return VoiceFeatureVector(
            pitch: vectors.map(\.pitch).reduce(0, +) / n,
            voicing: vectors.map(\.voicing).reduce(0, +) / n,
            jitter: vectors.map(\.jitter).reduce(0, +) / n,
            shimmer: vectors.map(\.shimmer).reduce(0, +) / n,
            timestamp: vectors.map(\.timestamp).reduce(0, +) / n,
            duration: vectors.map(\.duration).reduce(0, +) / n
        )
    }

    private static func inertia(vectors: [VoiceFeatureVector], assignments: [Int], k: Int) -> Double {
        var total = 0.0
        for cluster in 0..<k {
            let members = zip(vectors, assignments).filter { $0.1 == cluster }.map { $0.0 }
            guard !members.isEmpty else { continue }
            let centroid = meanVector(members)
            total += members.map { $0.distance(to: centroid) * $0.distance(to: centroid) }.reduce(0, +)
        }
        return total
    }
}

// MARK: - Segment Builder

/// Converts collected VoiceFeatureVectors + transcription segments → labeled SpeakerSegments
struct SpeakerSegmentBuilder {

    static func build(
        from vectors: [VoiceFeatureVector],
        transcriptionSegments: [SFTranscriptionSegment],
        maxSpeakers: Int = 4
    ) -> [SpeakerSegment] {
        guard !vectors.isEmpty else { return [] }

        let assignments = SpeakerClusterer.cluster(vectors, maxSpeakers: maxSpeakers)

        // Match each vector to its cluster and build text snippets
        var result: [SpeakerSegment] = []
        for (i, vector) in vectors.enumerated() {
            let clusterID = assignments[i]
            // Find transcription segments whose timestamps overlap this vector
            let text = transcriptionSegments
                .filter { seg in
                    let end = seg.timestamp + seg.duration
                    return seg.timestamp < vector.timestamp + vector.duration && end > vector.timestamp
                }
                .map(\.substring)
                .joined(separator: " ")

            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            result.append(SpeakerSegment(
                id: UUID(),
                clusterID: clusterID,
                speakerName: nil,
                startTime: vector.timestamp,
                endTime: vector.timestamp + vector.duration,
                text: text,
                features: vector
            ))
        }

        // Merge consecutive segments with the same cluster
        return mergeConsecutive(result)
    }

    private static func mergeConsecutive(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
        guard !segments.isEmpty else { return [] }
        var merged: [SpeakerSegment] = []
        var current = segments[0]

        for next in segments.dropFirst() {
            if next.clusterID == current.clusterID && next.startTime - current.endTime < 2.0 {
                // Extend current segment
                current = SpeakerSegment(
                    id: current.id,
                    clusterID: current.clusterID,
                    speakerName: current.speakerName,
                    startTime: current.startTime,
                    endTime: next.endTime,
                    text: current.text + " " + next.text,
                    features: current.features
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }
}

// MARK: - Voice Print Store

final class VoicePrintStore {
    static let shared = VoicePrintStore()
    private let key = "voice_prints_v1"

    private(set) var prints: [SpeakerVoicePrint] = []

    private init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SpeakerVoicePrint].self, from: data) else { return }
        prints = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(prints) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Match a feature vector against known voice prints. Returns best match if confident.
    func match(_ features: VoiceFeatureVector, threshold: Double = 0.3) -> SpeakerVoicePrint? {
        prints.min(by: { $0.distance(to: features) < $1.distance(to: features) }).flatMap { best in
            best.distance(to: features) < threshold ? best : nil
        }
    }

    func upsert(name: String, features: VoiceFeatureVector) {
        if let idx = prints.firstIndex(where: { $0.name == name }) {
            prints[idx] = prints[idx].updated(with: features)
        } else {
            prints.append(SpeakerVoicePrint(
                name: name,
                meanPitch: features.pitch,
                meanVoicing: features.voicing,
                meanJitter: features.jitter,
                meanShimmer: features.shimmer,
                sampleCount: 1
            ))
        }
        save()
    }

    func delete(name: String) {
        prints.removeAll { $0.name == name }
        save()
    }

    var knownNames: [String] { prints.map(\.name).sorted() }
}

// MARK: - Helpers

private extension Collection where Element == Double {
    func mean() -> Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
