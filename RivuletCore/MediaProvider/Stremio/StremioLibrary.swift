// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioLibrary.swift
//  Rivulet
//
//  The account's library on api.strem.io (datastoreGet / datastorePut, collection
//  "libraryItem"): what Stremio's own apps show as Continue Watching and watched.
//  Reads feed Continue Watching and resume points; playback writes back the way
//  stremio-core's player does, so a title stopped here resumes in Stremio and the
//  other way round:
//  - state times are milliseconds; `timeOffset` the position, `duration` the length;
//  - a new video resets `timeWatched` into `overallTimeWatched`;
//  - past 70% of `duration` watched, `flaggedWatched` = 1 and `timesWatched` += 1;
//  - a title never added to the library is written `removed` + `temp`, which is how
//    Stremio keeps it in Continue Watching without adding it to the Library.
//  Items are edited as raw JSON so fields Rivulet does not model (the `watched`
//  bitfield, notification flags) go back unchanged.
//

import Foundation

nonisolated struct StremioLibraryEntry: Sendable {
    let id: String
    let type: String
    let name: String
    let poster: URL?
    let removed: Bool
    let temp: Bool
    let timeOffset: TimeInterval
    let duration: TimeInterval
    let videoID: String?
    let lastWatched: Date?
    let timesWatched: Int

    var isInContinueWatching: Bool { type != "other" && (!removed || temp) && timeOffset > 0 }
    var isWatched: Bool { timesWatched > 0 }
}

nonisolated enum StremioLibrary {
    static let collection = "libraryItem"

    // MARK: - Snapshot (read synchronously when items are built)

    nonisolated(unsafe) private static var snapshot: [String: StremioLibraryEntry] = [:]
    nonisolated(unsafe) private static var raw: [String: [String: Any]] = [:]
    nonisolated(unsafe) private static var loadedAt: Date?
    private static let lock = NSLock()

    static func entry(for metaID: String) -> StremioLibraryEntry? {
        lock.withLock { snapshot[metaID] }
    }

    static var entries: [StremioLibraryEntry] {
        lock.withLock { Array(snapshot.values) }
    }

    /// Fetches the whole library at most once a minute (`force` ignores that).
    static func refresh(authKey: String, force: Bool = false) async {
        if !force, let last = lock.withLock({ loadedAt }), Date().timeIntervalSince(last) < 60 { return }
        guard let items = try? await get(authKey: authKey) else { return }
        var entries: [String: StremioLibraryEntry] = [:]
        var raws: [String: [String: Any]] = [:]
        for item in items {
            guard let entry = parse(item) else { continue }
            entries[entry.id] = entry
            raws[entry.id] = item
        }
        lock.withLock {
            snapshot = entries
            raw = raws
            loadedAt = Date()
        }
    }

    // MARK: - Writes

    nonisolated(unsafe) private static var lastWrite: [String: Date] = [:]

    /// Pause, stop and start always write; plain progress at most every 30 s per title.
    static func shouldWrite(_ metaID: String, force: Bool) -> Bool {
        lock.withLock {
            if !force, let last = lastWrite[metaID], Date().timeIntervalSince(last) < 30 { return false }
            lastWrite[metaID] = Date()
            return true
        }
    }

    struct Progress: Sendable {
        let metaID: String
        let type: String
        let name: String
        let poster: URL?
        /// The episode's video id; the meta id for a movie.
        let videoID: String
        let position: TimeInterval
        let duration: TimeInterval?
    }

    /// One playback report, applied as stremio-core's player applies `TimeChanged`.
    static func record(_ progress: Progress, authKey: String) async {
        let now = Date()
        let item = lock.withLock { () -> [String: Any] in
            var item = raw[progress.metaID] ?? newItem(progress, now: now)
            var state = item["state"] as? [String: Any] ?? [:]
            let offset = milliseconds(progress.position)
            let previousOffset = number(state["timeOffset"])
            if (state["video_id"] as? String) != progress.videoID {
                state["video_id"] = progress.videoID
                state["overallTimeWatched"] = number(state["overallTimeWatched"]) + number(state["timeWatched"])
                state["timeWatched"] = 0
                state["flaggedWatched"] = 0
            } else {
                let watched = max(0, offset - previousOffset)
                state["timeWatched"] = number(state["timeWatched"]) + watched
                state["overallTimeWatched"] = number(state["overallTimeWatched"]) + watched
            }
            state["timeOffset"] = offset
            if let duration = progress.duration, duration > 0 { state["duration"] = milliseconds(duration) }
            state["lastWatched"] = iso(now)
            let duration = number(state["duration"])
            if number(state["flaggedWatched"]) == 0, duration > 0, Double(number(state["timeWatched"])) > Double(duration) * 0.7 {
                state["flaggedWatched"] = 1
                state["timesWatched"] = number(state["timesWatched"]) + 1
            }
            item["state"] = state
            if (item["temp"] as? Bool) == true, number(state["timesWatched"]) == 0 { item["removed"] = true }
            if (item["removed"] as? Bool) == true { item["temp"] = true }
            item["_mtime"] = iso(now)
            store(item)
            return item
        }
        try? await put([item], authKey: authKey)
    }

    /// Watched: counted once and out of Continue Watching. Unwatched: just out of it.
    static func setWatched(metaID: String, type: String, name: String, poster: URL?, videoID: String,
                           watched: Bool, authKey: String) async {
        let now = Date()
        let item = lock.withLock { () -> [String: Any] in
            let progress = Progress(metaID: metaID, type: type, name: name, poster: poster, videoID: videoID,
                                    position: 0, duration: nil)
            var item = raw[metaID] ?? newItem(progress, now: now)
            var state = item["state"] as? [String: Any] ?? [:]
            state["timeOffset"] = 0
            state["video_id"] = videoID
            state["lastWatched"] = iso(now)
            if watched {
                state["timesWatched"] = max(1, number(state["timesWatched"]) + 1)
                state["flaggedWatched"] = 1
            } else if type == "movie" {
                state["timesWatched"] = 0
                state["flaggedWatched"] = 0
            }
            item["state"] = state
            item["_mtime"] = iso(now)
            store(item)
            return item
        }
        try? await put([item], authKey: authKey)
    }

    /// Takes a title off Continue Watching, as Stremio's "Dismiss" does: the position goes to 0.
    static func dismiss(metaID: String, authKey: String) async {
        let item = lock.withLock { () -> [String: Any]? in
            guard var item = raw[metaID] else { return nil }
            var state = item["state"] as? [String: Any] ?? [:]
            state["timeOffset"] = 0
            item["state"] = state
            item["_mtime"] = iso(Date())
            store(item)
            return item
        }
        guard let item else { return }
        try? await put([item], authKey: authKey)
    }

    // MARK: - Datastore

    private static func get(authKey: String) async throws -> [[String: Any]] {
        let body: [String: Any] = ["authKey": authKey, "collection": collection, "ids": [String](), "all": true]
        let result = try await datastore("datastoreGet", body)
        return result as? [[String: Any]] ?? []
    }

    private static func put(_ items: [[String: Any]], authKey: String) async throws {
        let body: [String: Any] = ["authKey": authKey, "collection": collection, "changes": items]
        _ = try await datastore("datastorePut", body)
    }

    private static func datastore(_ method: String, _ body: [String: Any]) async throws -> Any? {
        var request = URLRequest(url: StremioClient.apiBase.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StremioError.badResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw StremioError.api(error["message"] as? String ?? "datastore")
        }
        return object["result"]
    }

    // MARK: - Helpers

    /// Called with the lock held.
    private static func store(_ item: [String: Any]) {
        guard let id = item["_id"] as? String else { return }
        raw[id] = item
        if let entry = parse(item) { snapshot[id] = entry }
    }

    private static func newItem(_ progress: Progress, now: Date) -> [String: Any] {
        [
            "_id": progress.metaID,
            "name": progress.name,
            "type": progress.type,
            "poster": progress.poster?.absoluteString ?? "",
            "posterShape": "poster",
            "removed": true,
            "temp": true,
            "_ctime": iso(now),
            "_mtime": iso(now),
            "state": [
                "lastWatched": iso(now),
                "timeWatched": 0,
                "timeOffset": 0,
                "overallTimeWatched": 0,
                "timesWatched": 0,
                "flaggedWatched": 0,
                "duration": 0,
                "video_id": progress.videoID,
                "watched": "",
                "noNotif": false,
            ] as [String: Any],
            "behaviorHints": [
                "defaultVideoId": progress.type == "movie" ? (progress.metaID as Any) : (NSNull() as Any),
                "featuredVideoId": NSNull(),
                "hasScheduledVideos": false,
            ] as [String: Any],
        ]
    }

    private static func parse(_ item: [String: Any]) -> StremioLibraryEntry? {
        guard let id = item["_id"] as? String, let type = item["type"] as? String else { return nil }
        let state = item["state"] as? [String: Any] ?? [:]
        return StremioLibraryEntry(
            id: id, type: type, name: item["name"] as? String ?? id,
            poster: (item["poster"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
            removed: item["removed"] as? Bool ?? false, temp: item["temp"] as? Bool ?? false,
            timeOffset: TimeInterval(number(state["timeOffset"])) / 1000,
            duration: TimeInterval(number(state["duration"])) / 1000,
            videoID: (state["video_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            lastWatched: (state["lastWatched"] as? String).flatMap(date),
            timesWatched: number(state["timesWatched"]))
    }

    private static func number(_ value: Any?) -> Int {
        switch value {
        case let int as Int: int
        case let double as Double: Int(double)
        case let number as NSNumber: number.intValue
        case let string as String: Int(string) ?? 0
        default: 0
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        seconds.isFinite ? max(0, Int((seconds * 1000).rounded())) : 0
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
