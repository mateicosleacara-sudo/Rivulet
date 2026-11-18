// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  ExternalStreamProvider.swift
//  Rivulet
//
//  Plays a stream another app handed over (`ExternalStreamLink`) with no server
//  behind it. It is a `MediaProvider` only so the stream takes the provider play
//  path (`UniversalPlayerViewModel(providerPlayback:)` -> the aether route), the
//  same direct play Jellyfin and Emby use, so Dolby Vision FEL, Height Speakers
//  and lossless audio apply unchanged. It is never registered: it has no
//  libraries, Home rows or search, and nothing outside the player sees it.
//  Watch progress is kept on this device (`ExternalStreamResumeStore`).
//

import CryptoKit
import Foundation

final class ExternalStreamProvider: MediaProvider, @unchecked Sendable {
    nonisolated static let providerID = "stream:external"

    nonisolated let id = ExternalStreamProvider.providerID
    /// Not read on the play path, and the provider is never registered; an existing kind
    /// keeps a "stream" server type out of every list that walks `MediaProviderKind.allCases`.
    nonisolated let kind: MediaProviderKind = .jellyfin
    nonisolated let displayName = "Stream"
    let connectionState: ConnectionState = .connected
    let supportsWatchlist = false

    let link: ExternalStreamLink
    /// The stream after redirects, and what the response said about it.
    let resolved: ExternalStreamResolver.Resolved
    let resumeKey: String

    init(link: ExternalStreamLink, resolved: ExternalStreamResolver.Resolved) {
        self.link = link
        self.resolved = resolved
        self.resumeKey = ExternalStreamResumeStore.key(for: link.resumeIdentity)
    }

    // MARK: - The one item

    var item: MediaItem {
        let saved = ExternalStreamResumeStore.position(for: resumeKey)
        return MediaItem(
            ref: MediaItemRef(providerID: id, itemID: resumeKey),
            kind: .movie,
            title: link.displayTitle,
            sortTitle: nil, overview: nil, year: nil,
            runtime: saved?.duration,
            parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: saved?.position ?? 0,
                                      isFavorite: false, lastViewedAt: saved?.updated),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }

    var source: MediaSource {
        let fileName = link.filename ?? resolved.fileName ?? resolved.url.lastPathComponent.removingPercentEncoding
        let ext = (fileName as NSString?)?.pathExtension.lowercased()
        return MediaSource(
            id: "external",
            container: ext?.isEmpty == false ? ext : nil,
            duration: 0,
            bitrate: nil,
            fileSize: resolved.contentLength,
            fileName: fileName,
            videoResolution: nil,
            videoTracks: [],
            audioTracks: [],
            subtitleTracks: link.subtitleURLs.enumerated().map { index, url in
                let ext = url.pathExtension.lowercased()
                return SubtitleTrack(
                    id: "external-sub-\(index)", index: index,
                    codec: ["srt", "ass", "ssa", "vtt", "sub"].contains(ext) ? ext : "srt",
                    language: nil, title: link.subtitleURLs.count > 1 ? "Subtitle \(index + 1)" : "Subtitle",
                    extendedTitle: nil, isDefault: false, isForced: false, isHearingImpaired: false,
                    isEmbedded: false, externalURL: url, isSelected: false)
            },
            streamKind: .directPlay,
            streamURL: resolved.url
        )
    }

    var detail: MediaItemDetail {
        MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
                        chapters: [], mediaSources: [source], trailerURL: nil, contentRating: nil,
                        nextEpisode: nil, collections: [])
    }

    var stream: StreamInfo {
        StreamInfo(source: source, playSessionID: nil, trackInfoAvailable: false)
    }

    /// What the player takes. Built here rather than through `prepare`, whose Auto quality
    /// probe would download part of the file just to measure the line.
    var playback: ProviderPlayback {
        ProviderPlayback(provider: self, item: item, detail: detail, stream: stream, extras: PlaybackExtras())
    }

    // MARK: - Playback

    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail { detail }

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        stream
    }

    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any ProgressReporter {
        ExternalStreamProgressReporter(key: resumeKey, title: link.displayTitle)
    }

    func markPlayed(_ itemRef: MediaItemRef) async throws { ExternalStreamResumeStore.clear(resumeKey) }
    func markUnplayed(_ itemRef: MediaItemRef) async throws { ExternalStreamResumeStore.clear(resumeKey) }
    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        ExternalStreamResumeStore.save(resumeKey, position: position, duration: nil, title: link.displayTitle)
    }

    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {}
    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {}

    // MARK: - No library

    func libraries() async throws -> [MediaLibrary] { [] }
    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        PagedResult(items: [], total: 0, nextPage: nil)
    }
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] { [] }
    func search(_ query: String) async throws -> [MediaItem] { [] }
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        RelatedContent(items: [], collection: nil)
    }
    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func recentlyAdded(limit: Int) async throws -> [MediaItem] { [] }
    func hubs() async throws -> [MediaHub] { [] }
    func hubs(in library: MediaLibrary) async throws -> [MediaHub] { [] }
    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool { false }
    func addToWatchlist(_ ref: MediaItemRef) async throws {}
    func removeFromWatchlist(_ ref: MediaItemRef) async throws {}
}

/// Saves the position the player reports. `PlaybackTimeline` decides when: start, every
/// 10 s, pause and stop.
nonisolated struct ExternalStreamProgressReporter: ProgressReporter {
    let key: String
    let title: String

    func start(position: TimeInterval) async throws { save(position) }
    func progress(position: TimeInterval) async { save(position) }
    func paused(at position: TimeInterval) async { save(position) }
    func stopped(at position: TimeInterval) async { save(position) }

    private func save(_ position: TimeInterval) {
        ExternalStreamResumeStore.save(key, position: position, duration: nil, title: title)
    }
}

/// Resume points for handed-over streams, on this device only. Keyed by a hash of the
/// title's identity (`ExternalStreamLink.resumeIdentity`): the stream URL carries the
/// debrid key, so it is never stored as a key.
nonisolated enum ExternalStreamResumeStore {
    struct Entry: Codable, Sendable {
        var position: TimeInterval
        var duration: TimeInterval?
        var title: String
        var updated: Date
    }

    static let defaultsKey = "externalStreamResume"
    private static let maxEntries = 300
    /// Guards every read-modify-write of the one defaults entry.
    nonisolated(unsafe) private static let lock = NSLock()

    static func key(for identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func position(for key: String) -> Entry? {
        lock.withLock { load()[key] }
    }

    /// A resume point worth offering: past the 2% floor and short of the 90% ceiling
    /// when the length is known, else past the first 30 seconds.
    static func resumePoint(for key: String) -> TimeInterval? {
        guard let entry = position(for: key) else { return nil }
        if let duration = entry.duration, duration > 0 {
            return WatchProgressPolicy.hasResumePoint(offsetSeconds: entry.position, runtimeSeconds: duration)
                ? entry.position : nil
        }
        return entry.position >= 30 ? entry.position : nil
    }

    static func save(_ key: String, position: TimeInterval, duration: TimeInterval?, title: String) {
        guard position.isFinite, position >= 0 else { return }
        lock.withLock {
            var all = load()
            let known = duration.flatMap { $0 > 0 ? $0 : nil } ?? all[key]?.duration
            all[key] = Entry(position: position, duration: known, title: title, updated: Date())
            if all.count > maxEntries {
                for stale in all.sorted(by: { $0.value.updated < $1.value.updated }).prefix(all.count - maxEntries) {
                    all[stale.key] = nil
                }
            }
            store(all)
        }
    }

    static func clear(_ key: String) {
        lock.withLock {
            var all = load()
            all[key] = nil
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

/// Follows the stream's redirects once before playback, so the engine opens the file
/// itself (a Stremio addon's resolve link answers 302 to the debrid host), and reads
/// the size and name the file host sends.
nonisolated enum ExternalStreamResolver {
    struct Resolved: Sendable {
        let url: URL
        let contentLength: Int64?
        let fileName: String?
        let statusCode: Int?
    }

    static func resolve(_ url: URL, timeout: TimeInterval = 20) async -> Resolved {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        // One byte: enough for the headers, without pulling the file.
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else {
                return Resolved(url: response.url ?? url, contentLength: nil, fileName: nil, statusCode: nil)
            }
            return Resolved(url: http.url ?? url, contentLength: totalLength(http),
                            fileName: fileName(http), statusCode: http.statusCode)
        } catch {
            // Let the engine try the link as given; it reports its own failure.
            return Resolved(url: url, contentLength: nil, fileName: nil, statusCode: nil)
        }
    }

    private static func totalLength(_ response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            return total
        }
        guard response.statusCode == 200 else { return nil }
        return response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
    }

    private static func fileName(_ response: HTTPURLResponse) -> String? {
        guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
              let range = disposition.range(of: "filename=") else { return nil }
        let name = disposition[range.upperBound...]
            .split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return name?.isEmpty == false ? name?.removingPercentEncoding ?? name : nil
    }
}
