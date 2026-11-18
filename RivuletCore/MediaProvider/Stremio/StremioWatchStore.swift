// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioWatchStore.swift
//  Rivulet
//
//  Watch state for Stremio titles kept on this device: resume points, watched
//  marks, Continue Watching and the next episode of a show. It is the local
//  record the Stremio library and Trakt sync build on.
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

    /// What Play on a show means: the episode last stopped partway, else the one after the last
    /// finished, else nil (the first unplayed, which `EpisodePicker` falls back to).
    static func nextEpisode(in episodes: [MediaItem]) -> MediaItem? {
        let all = lock.withLock { load() }
        let watched = episodes.enumerated().compactMap { index, episode in
            all[key(episode.ref)].map { (index, $0) }
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

/// Saves the position the player reports (`PlaybackTimeline`: start, every 10 s, pause, stop)
/// here and in the Stremio library.
nonisolated struct StremioProgressReporter: ProgressReporter {
    let providerID: String
    let itemRef: MediaItemRef
    let item: @Sendable () async -> MediaItem?
    /// item, position, force (pause and stop always write; progress at most every 30 s).
    let sync: @Sendable (MediaItem?, TimeInterval, Bool) async -> Void

    func start(position: TimeInterval) async throws { await save(position, force: true) }
    func progress(position: TimeInterval) async { await save(position, force: false) }
    func paused(at position: TimeInterval) async { await save(position, force: true) }
    func stopped(at position: TimeInterval) async { await save(position, force: true) }

    private func save(_ position: TimeInterval, force: Bool) async {
        let item = await item()
        StremioWatchStore.save(itemRef, position: position, item: item)
        await sync(item, position, force)
    }
}
