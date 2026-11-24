// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioWatchStore.swift
//  Rivulet
//
//  Watch state for Stremio titles kept on this device: resume points, watched
//  marks, Continue Watching and the next episode of a show. Deliberately local:
//  nothing is written to the Stremio library or to Trakt.
//

import Foundation

nonisolated enum StremioWatchStore {
    struct Entry: Codable, Sendable {
        var position: TimeInterval
        var played: Bool
        var updated: Date
        var hidden: Bool = false
        /// The item as it was played, for Continue Watching (episodes keep their show's art).
        var item: MediaItem?
    }

    static let defaultsKey = "stremioWatchState"
    nonisolated(unsafe) private static let lock = NSLock()
    private static let maxEntries = 2000

    private static func key(_ ref: MediaItemRef) -> String { "\(ref.providerID)|\(ref.itemID)" }

    static func entry(for ref: MediaItemRef) -> Entry? {
        lock.withLock { load()[key(ref)] }
    }

    static func state(for ref: MediaItemRef) -> MediaUserState {
        guard let entry = entry(for: ref) else {
            return MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil)
        }
        return MediaUserState(isPlayed: entry.played, viewOffset: entry.played ? 0 : entry.position,
                              isFavorite: false, lastViewedAt: entry.updated)
    }

    static func save(_ ref: MediaItemRef, position: TimeInterval, item: MediaItem?) {
        guard position.isFinite, position >= 0 else { return }
        update(ref) { entry in
            entry.position = position
            entry.updated = Date()
            entry.hidden = false
            if let item { entry.item = item }
            // Past the policy's ceiling the title counts as watched, as on every server.
            if let runtime = item?.runtime ?? entry.item?.runtime, runtime > 0,
               position / runtime >= WatchProgressPolicy.completionThreshold {
                entry.played = true
                entry.position = 0
            } else if position > 0 {
                entry.played = false
            }
        }
    }

    static func markPlayed(_ ref: MediaItemRef, item: MediaItem?, played: Bool) {
        update(ref) { entry in
            entry.played = played
            entry.position = 0
            entry.updated = Date()
            if let item { entry.item = item }
        }
    }

    static func removeFromContinueWatching(_ ref: MediaItemRef) {
        update(ref) { $0.hidden = true }
    }

    /// Titles stopped partway, newest first.
    static func continueWatching(providerID: String) -> [MediaItem] {
        let all = lock.withLock { load() }
        return all.values
            .filter { !$0.played && !$0.hidden && $0.item?.ref.providerID == providerID }
            .filter { WatchProgressPolicy.hasResumePoint(offsetSeconds: $0.position, runtimeSeconds: $0.item?.runtime) }
            .sorted { $0.updated > $1.updated }
            .compactMap { entry in
                guard var item = entry.item else { return nil }
                item.userState = MediaUserState(isPlayed: false, viewOffset: entry.position, isFavorite: false,
                                                lastViewedAt: entry.updated)
                return item
            }
    }

    /// Per series, the episode last finished, when finishing it is the latest thing done in that
    /// series (newest first). Continue Watching offers the episode after it.
    static func finishedEpisodes(providerID: String) -> [(item: MediaItem, finished: Date)] {
        let all = lock.withLock { load() }
        var latest: [String: Entry] = [:]
        for entry in all.values where entry.played || entry.position > 0 {
            guard let item = entry.item, item.ref.providerID == providerID, item.kind == .episode,
                  let series = item.grandparentRef?.itemID else { continue }
            if let current = latest[series], current.updated >= entry.updated { continue }
            latest[series] = entry
        }
        return latest.values
            .filter(\.played)
            .sorted { $0.updated > $1.updated }
            .compactMap { entry in entry.item.map { (item: $0, finished: entry.updated) } }
    }

    /// What Play on a show means: the episode last stopped partway, else the one after the last
    /// finished, else nil (the first unplayed, which `EpisodePicker` falls back to).
    static func nextEpisode(in episodes: [MediaItem]) -> MediaItem? {
        let all = lock.withLock { load() }
        // Only real viewing counts: a dismissed Continue Watching card leaves a hidden, unwatched record.
        let watched = episodes.enumerated().compactMap { index, episode in
            all[key(episode.ref)].flatMap { $0.played || $0.position > 0 ? (index, $0) : nil }
        }
        guard let (index, last) = watched.max(by: { $0.1.updated < $1.1.updated }) else { return nil }
        if !last.played, last.position > 0 { return episodes[index] }
        return episodes.indices.contains(index + 1) ? episodes[index + 1] : nil
    }

    private static func update(_ ref: MediaItemRef, _ change: (inout Entry) -> Void) {
        lock.withLock {
            var all = load()
            var entry = all[key(ref)] ?? Entry(position: 0, played: false, updated: Date())
            change(&entry)
            all[key(ref)] = entry
            if all.count > maxEntries {
                for stale in all.sorted(by: { $0.value.updated < $1.value.updated }).prefix(all.count - maxEntries) {
                    all[stale.key] = nil
                }
            }
            store(all)
        }
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func store(_ all: [String: Entry]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: defaultsKey)
    }
}

/// Saves the position the player reports (`PlaybackTimeline`: start, every 10 s, pause, stop),
/// and once 3 minutes of the stream have played, remembers it as the title's Last Watched, so a
/// stream stopped early because it played badly is not offered or restarted again.
nonisolated final class StremioProgressReporter: ProgressReporter, @unchecked Sendable {
    static let rememberAfter: TimeInterval = 180

    let providerID: String
    let itemRef: MediaItemRef
    let item: @Sendable () async -> MediaItem?
    private let rememberStream: @Sendable () -> Void
    private let lock = NSLock()
    private var lastPosition: TimeInterval?
    private var watched: TimeInterval = 0
    private var remembered = false

    init(providerID: String, itemRef: MediaItemRef, item: @escaping @Sendable () async -> MediaItem?,
         rememberStream: @escaping @Sendable () -> Void) {
        self.providerID = providerID
        self.itemRef = itemRef
        self.item = item
        self.rememberStream = rememberStream
    }

    func start(position: TimeInterval) async throws {
        lock.withLock { lastPosition = position }
        await save(position)
    }
    func progress(position: TimeInterval) async { count(position); await save(position) }
    func paused(at position: TimeInterval) async { count(position); await save(position) }
    func stopped(at position: TimeInterval) async { count(position); await save(position) }

    /// Playing time only: a seek (a jump of more than 30 s between reports) adds nothing.
    private func count(_ position: TimeInterval) {
        let remember: Bool = lock.withLock {
            if let last = lastPosition, position > last, position - last <= 30 { watched += position - last }
            lastPosition = position
            guard !remembered, watched >= Self.rememberAfter else { return false }
            remembered = true
            return true
        }
        if remember { rememberStream() }
    }

    private func save(_ position: TimeInterval) async {
        StremioWatchStore.save(itemRef, position: position, item: await item())
    }
}

/// Plan to Watch: movies and shows saved on this device, newest first. It is what the app's
/// favorites surfaces (the sidebar tab, the detail page's button, the tile menu) read for Stremio.
nonisolated enum StremioPlanStore {
    struct Entry: Codable, Sendable {
        var item: MediaItem
        var added: Date
    }

    static let defaultsKey = "stremioPlanToWatch"
    nonisolated(unsafe) private static let lock = NSLock()

    static func contains(_ ref: MediaItemRef) -> Bool {
        lock.withLock { load()[ref.itemID] != nil }
    }

    static func items(providerID: String) -> [MediaItem] {
        lock.withLock { load() }.values
            .filter { $0.item.ref.providerID == providerID }
            .sorted { $0.added > $1.added }
            .map { entry in
                var item = entry.item
                let watched = StremioWatchStore.state(for: item.ref)
                item.userState = MediaUserState(isPlayed: watched.isPlayed, viewOffset: watched.viewOffset,
                                                isFavorite: true, lastViewedAt: watched.lastViewedAt)
                return item
            }
    }

    static func set(_ planned: Bool, item: MediaItem?, ref: MediaItemRef) {
        lock.withLock {
            var all = load()
            if planned, let item {
                all[ref.itemID] = Entry(item: item, added: all[ref.itemID]?.added ?? Date())
            } else if !planned {
                all[ref.itemID] = nil
            }
            UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: defaultsKey)
        }
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}

/// The stream last played per title (a movie, or a whole show), kept on this device, so Play
/// starts the same one again and the next episode starts the same release.
nonisolated enum StremioStreamMemory {
    struct Choice: Codable, Sendable {
        var streamID: String
        var fileName: String?
        var bingeGroup: String?
        var addon: String
        var updated: Date
    }

    static let defaultsKey = "stremioStreamMemory"
    nonisolated(unsafe) private static let lock = NSLock()
    private static let maxEntries = 1000

    static func choice(for metaID: String) -> Choice? {
        lock.withLock { load()[metaID] }
    }

    static func record(_ option: StremioStreamOption, metaID: String) {
        lock.withLock {
            var all = load()
            all[metaID] = Choice(streamID: option.id, fileName: option.source.fileName,
                                 bingeGroup: option.stream.bingeGroup, addon: option.addonName, updated: Date())
            if all.count > maxEntries {
                for stale in all.sorted(by: { $0.value.updated < $1.value.updated }).prefix(all.count - maxEntries) {
                    all[stale.key] = nil
                }
            }
            UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: defaultsKey)
        }
    }

    private static func load() -> [String: Choice] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Choice].self, from: data)) ?? [:]
    }
}
