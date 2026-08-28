import XCTest
@testable import Deep_State_Meeting_Agent_MacOS

/// Covers the `screenshots.json` wire format. This file is the contract other agents
/// read, so the shape matters as much as the values: snake_case keys, ISO-8601 dates,
/// a schema version, and tolerance for fields a future writer might add.
final class ScreenshotManifestTests: XCTestCase {

    private let startedAt = Date(timeIntervalSince1970: 1_774_000_000)

    private func sampleManifest() -> ScreenshotManifest {
        ScreenshotManifest(
            meeting: .init(
                title: "Q3 Planning",
                folderName: "2026-08-18 14-30-00",
                startedAt: startedAt,
                durationSeconds: 1832.4
            ),
            capture: .init(
                source: .liveInterval,
                intervalSeconds: 30,
                recordingMode: "audioOnly",
                displayName: "Built-in Retina Display",
                displayWidth: 3024,
                displayHeight: 1964,
                deduplicated: true,
                dedupeThreshold: 3.0
            ),
            screenshots: [
                .init(file: "screenshots/shot_0001_000000.jpg", index: 1, elapsedSeconds: 0,
                      capturedAt: startedAt, width: 3024, height: 1964, byteSize: 284_117),
                .init(file: "screenshots/shot_0002_000030.jpg", index: 2, elapsedSeconds: 30,
                      capturedAt: startedAt.addingTimeInterval(30), width: 3024, height: 1964, byteSize: 291_004)
            ]
        )
    }

    private func encodedJSON(_ manifest: ScreenshotManifest) throws -> String {
        String(data: try ScreenshotManifest.encoder().encode(manifest), encoding: .utf8) ?? ""
    }

    func testRoundTripPreservesEveryField() throws {
        let original = sampleManifest()
        let data = try ScreenshotManifest.encoder().encode(original)
        let decoded = try ScreenshotManifest.decoder().decode(ScreenshotManifest.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testKeysAreSnakeCase() throws {
        let json = try encodedJSON(sampleManifest())
        XCTAssertTrue(json.contains("\"schema_version\""))
        XCTAssertTrue(json.contains("\"elapsed_seconds\""))
        XCTAssertTrue(json.contains("\"captured_at\""))
        XCTAssertTrue(json.contains("\"byte_size\""))
        XCTAssertTrue(json.contains("\"folder_name\""))
        XCTAssertTrue(json.contains("\"interval_seconds\""))
        XCTAssertTrue(json.contains("\"recording_mode\""))
        // camelCase must not leak through alongside them
        XCTAssertFalse(json.contains("\"elapsedSeconds\""))
        XCTAssertFalse(json.contains("\"schemaVersion\""))
    }

    func testSchemaVersionIsWritten() throws {
        let data = try ScreenshotManifest.encoder().encode(sampleManifest())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["schema_version"] as? Int, ScreenshotManifest.currentSchemaVersion)
    }

    /// The enum raw values are part of the contract — a consumer branches on them.
    func testSourceEncodesAsSnakeCaseRawValue() throws {
        var manifest = sampleManifest()
        XCTAssertTrue(try encodedJSON(manifest).contains("\"live_interval\""))

        manifest.capture.source = .videoExtraction
        XCTAssertTrue(try encodedJSON(manifest).contains("\"video_extraction\""))
    }

    func testDatesAreISO8601() throws {
        let json = try encodedJSON(sampleManifest())
        let expected = ISO8601DateFormatter().string(from: startedAt)
        XCTAssertTrue(json.contains(expected), "expected ISO-8601 timestamp \(expected) in:\n\(json)")
    }

    /// Other agents may write or extend this file. An unrecognised field must be
    /// ignored, not thrown on, or a newer writer breaks every older reader.
    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {
          "schema_version": 1,
          "future_top_level_field": {"anything": [1, 2, 3]},
          "meeting": {"folder_name": "2026-08-18 14-30-00",
                      "started_at": "2026-08-18T14:30:00Z",
                      "unexpected": "ignored"},
          "capture": {"source": "live_interval", "interval_seconds": 30,
                      "recording_mode": "audioOnly", "deduplicated": false},
          "screenshots": []
        }
        """
        let decoded = try ScreenshotManifest.decoder()
            .decode(ScreenshotManifest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.meeting.folderName, "2026-08-18 14-30-00")
        XCTAssertEqual(decoded.capture.source, .liveInterval)
        XCTAssertTrue(decoded.screenshots.isEmpty)
    }

    /// A hand-edited or third-party file without a version should load as v1 rather
    /// than failing outright.
    func testMissingSchemaVersionDefaultsToCurrent() throws {
        let json = """
        {
          "meeting": {"folder_name": "f", "started_at": "2026-08-18T14:30:00Z"},
          "capture": {"source": "video_extraction", "interval_seconds": 60,
                      "recording_mode": "screenAndAudio", "deduplicated": true},
          "screenshots": []
        }
        """
        let decoded = try ScreenshotManifest.decoder()
            .decode(ScreenshotManifest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.schemaVersion, ScreenshotManifest.currentSchemaVersion)
    }

    func testOptionalDisplayFieldsSurviveBeingAbsent() throws {
        var manifest = sampleManifest()
        manifest.capture.displayName = nil
        manifest.capture.displayWidth = nil
        manifest.capture.displayHeight = nil
        manifest.meeting.title = nil
        manifest.meeting.durationSeconds = nil

        let data = try ScreenshotManifest.encoder().encode(manifest)
        let decoded = try ScreenshotManifest.decoder().decode(ScreenshotManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertNil(decoded.capture.displayName)
        XCTAssertNil(decoded.meeting.title)
    }
}

// MARK: - ScreenshotInterval

final class ScreenshotIntervalTests: XCTestCase {

    func testLabelsAndSeconds() {
        XCTAssertEqual(ScreenshotInterval.fifteenSeconds.label, "15s")
        XCTAssertEqual(ScreenshotInterval.thirtySeconds.label, "30s")
        XCTAssertEqual(ScreenshotInterval.sixtySeconds.label, "60s")
        XCTAssertEqual(ScreenshotInterval.fiveMinutes.label, "5m")

        XCTAssertEqual(ScreenshotInterval.fifteenSeconds.seconds, 15)
        XCTAssertEqual(ScreenshotInterval.fiveMinutes.seconds, 300)
    }

    /// `UserDefaults.double(forKey:)` returns 0 for an unset key. A zero interval would
    /// spin the capture loop, so it must resolve to the default instead.
    func testUnsetPreferenceResolvesToDefault() {
        XCTAssertEqual(ScreenshotInterval.resolve(storedValue: 0), .thirtySeconds)
        XCTAssertEqual(ScreenshotInterval.resolve(storedValue: 0), ScreenshotInterval.default)
    }

    /// A value written by a build with a different preset list must not crash or
    /// produce an invalid interval.
    func testUnknownStoredValueResolvesToDefault() {
        XCTAssertEqual(ScreenshotInterval.resolve(storedValue: 7), .thirtySeconds)
        XCTAssertEqual(ScreenshotInterval.resolve(storedValue: -30), .thirtySeconds)
    }

    func testKnownStoredValuesRoundTrip() {
        for interval in ScreenshotInterval.allCases {
            XCTAssertEqual(ScreenshotInterval.resolve(storedValue: interval.rawValue), interval)
        }
    }

    func testAllCasesAreOrderedShortestFirst() {
        let seconds = ScreenshotInterval.allCases.map(\.seconds)
        XCTAssertEqual(seconds, seconds.sorted(), "picker order should read shortest to longest")
    }
}
