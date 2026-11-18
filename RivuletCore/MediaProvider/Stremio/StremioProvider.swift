// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioProvider.swift
//  Rivulet
//
//  The Stremio account as a server: the addons installed in it supply everything.
//  Each browsable catalog is a library (and its first page a Home row), meta is
//  the detail page with its seasons and episodes, and every addon's http(s)
//  streams are the title's versions. Playback takes the provider route
//  (direct play on the aether route), so Dolby Vision FEL, Height Speakers and
//  lossless audio work as they do for any server.
//
//  Item ids carry what each request needs: "m~<type>~<metaId>" (a movie),
//  "s~<type>~<metaId>" (a series), "z~<type>~<metaId>~<season>" and
//  "e~<type>~<metaId>~<videoId>". "~" because "|" separates Home row ids.
//

import Foundation

/// What an item id says.
nonisolated struct StremioRef: Hashable, Sendable {
    enum Kind: String, Sendable { case movie = "m", series = "s", season = "z", episode = "e" }
    let kind: Kind
    let type: String
    let metaID: String
    /// The season number (season) or the video id (episode).
    let detail: String?

    var itemID: String {
        ([kind.rawValue, type, metaID] + (detail.map { [$0] } ?? [])).joined(separator: "~")
    }

    init(kind: Kind, type: String, metaID: String, detail: String? = nil) {
        self.kind = kind
        self.type = type
        self.metaID = metaID
        self.detail = detail
    }

    init?(_ itemID: String) {
        let parts = itemID.split(separator: "~", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let kind = Kind(rawValue: parts[0]) else { return nil }
        self.kind = kind
        self.type = parts[1]
        self.metaID = parts[2]
        self.detail = parts.count == 4 ? parts[3] : nil
        if (kind == .season || kind == .episode) && detail == nil { return nil }
    }

    /// The id streams and subtitles are asked for: the video for an episode, else the meta.
    var streamID: String { kind == .episode ? (detail ?? metaID) : metaID }
}

final class StremioProvider: MediaProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind = .stremio
    nonisolated let displayName = "Stremio"
    let connectionState: ConnectionState = .connected
    let supportsWatchlist = false

    let authKey: String
    private let addonStore: StremioAddonStore
    private let metaCache = StremioCache<StremioMeta>(lifetime: 1800)
    private let streamCache = StremioCache<[StremioStreamOption]>(lifetime: 600)

    init(userID: String, authKey: String) {
        self.id = "stremio:\(userID)"
        self.authKey = authKey
        self.addonStore = StremioAddonStore(authKey: authKey)
    }

    /// Settings > Servers > Stremio > Refresh: addons changed in Stremio.
    func reloadAddons() async { await addonStore.reload() }
    func addons() async throws -> [StremioAddon] { try await addonStore.addons() }

    // MARK: - Libraries and Home rows

    func libraries() async throws -> [MediaLibrary] {
        let installed = try await self.addons()
        var seen = Set<String>()
        return installed.flatMap { addon in
            addon.manifest.catalogs.filter(\.isBrowsable).compactMap { catalog -> MediaLibrary? in
                let libraryID = [addon.manifest.id, catalog.type, catalog.id].joined(separator: "~")
                guard seen.insert(libraryID).inserted else { return nil }
                return MediaLibrary(id: libraryID, providerID: id, title: Self.libraryTitle(catalog, addon: addon),
                                    kind: Self.libraryKind(catalog.type))
            }
        }
    }

    static func libraryTitle(_ catalog: StremioManifest.Catalog, addon: StremioAddon) -> String {
        let type = catalog.type == "movie" ? String(localized: "Movies")
            : catalog.type == "series" ? String(localized: "Series") : catalog.type.capitalized
        let name = catalog.name ?? addon.manifest.name
        return name.localizedCaseInsensitiveContains(type) ? name : "\(name) \(type)"
    }

    static func libraryKind(_ type: String) -> MediaLibrary.LibraryKind {
        switch type {
        case "movie": .movies
        case "series", "anime", "tv": .shows
        default: .mixed
        }
    }

    private func catalog(for library: MediaLibrary) async throws -> (StremioAddon, StremioManifest.Catalog) {
        let parts = library.id.split(separator: "~", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw MediaProviderError.notFound }
        for addon in try await addons() where addon.manifest.id == parts[0] {
            if let catalog = addon.manifest.catalogs.first(where: { $0.type == parts[1] && $0.id == parts[2] }) {
                return (addon, catalog)
            }
        }
        throw MediaProviderError.notFound
    }

    /// Fills the page even when the addon's own pages are shorter (Cinemeta's are 50 or 100),
    /// asking with skip = what it has handed out so far.
    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        let (addon, catalog) = try await catalog(for: library)
        var collected: [MediaItem] = []
        var skip = page.offset
        var exhausted = false
        while collected.count < page.limit {
            if skip > 0 && !catalog.supportsSkip { exhausted = true; break }
            let extra: [(String, String)] = skip > 0 ? [("skip", String(skip))] : []
            let response: StremioCatalogResponse = try await StremioClient.resource(
                addon, resource: "catalog", type: catalog.type, id: catalog.id, extra: extra)
            if response.metas.isEmpty { exhausted = true; break }
            collected += response.metas.map { item(from: $0, libraryID: library.id) }
            skip += response.metas.count
        }
        let more = !exhausted
        return PagedResult(items: collected, total: page.offset + collected.count + (more ? page.limit : 0),
                           nextPage: more ? Page(offset: page.offset + collected.count, limit: page.limit) : nil)
    }

    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        let (addon, catalog) = try await catalog(for: library)
        let response: StremioCatalogResponse = try await StremioClient.resource(
            addon, resource: "catalog", type: catalog.type, id: catalog.id)
        let items = response.metas.prefix(30).map { item(from: $0, libraryID: library.id) }
        guard !items.isEmpty else { return nil }
        return MediaHub(id: "\(library.id).catalog", providerID: id, title: library.title, style: .shelf, items: Array(items))
    }

    func hubs() async throws -> [MediaHub] { [] }
    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        try await recentlyAddedHub(in: library).map { [$0] } ?? []
    }
    func recentlyAdded(limit: Int) async throws -> [MediaItem] { [] }

    /// Stremio's Continue Watching (the account library) merged with this device's record;
    /// a title in both shows once, at whichever position is newer.
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        await StremioLibrary.refresh(authKey: authKey, force: true)
        let entries = StremioLibrary.entries.filter(\.isInContinueWatching)
            .sorted { ($0.lastWatched ?? .distantPast) > ($1.lastWatched ?? .distantPast) }
            .prefix(limit)
        let fromLibrary = await withTaskGroup(of: (Int, MediaItem?).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask { (index, await self.continueItem(for: entry)) }
            }
            var all: [(Int, MediaItem?)] = []
            for await result in group { all.append(result) }
            return all.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
        let local = StremioWatchStore.continueWatching(providerID: id)
        var merged: [String: MediaItem] = [:]
        for item in fromLibrary + local {
            let key = StremioRef(item.ref.itemID)?.metaID ?? item.ref.itemID
            if let existing = merged[key],
               (existing.userState.lastViewedAt ?? .distantPast) >= (item.userState.lastViewedAt ?? .distantPast) { continue }
            merged[key] = item
        }
        return Array(merged.values
            .sorted { ($0.userState.lastViewedAt ?? .distantPast) > ($1.userState.lastViewedAt ?? .distantPast) }
            .prefix(limit))
    }

    /// The library entry as the item to resume: the episode it was on, or the movie.
    private func continueItem(for entry: StremioLibraryEntry) async -> MediaItem? {
        guard let meta = try? await self.meta(type: entry.type, id: entry.id) else { return nil }
        let isMovie = entry.type == "movie"
        let ref = StremioRef(kind: isMovie ? .movie : .series, type: entry.type, metaID: entry.id)
        var item: MediaItem
        if isMovie {
            item = self.item(from: meta.preview, libraryID: nil)
        } else if let videoID = entry.videoID,
                  let episode = episodes(of: meta, ref: ref, season: nil).first(where: {
                      StremioRef($0.ref.itemID)?.detail == videoID }) {
            item = episode
        } else {
            return nil
        }
        item.userState = MediaUserState(isPlayed: false, viewOffset: entry.timeOffset, isFavorite: false,
                                        lastViewedAt: entry.lastWatched)
        return item
    }

    /// The newer of this device's record and the Stremio library for one movie or episode.
    func userState(for itemRef: MediaItemRef) -> MediaUserState {
        let local = StremioWatchStore.state(for: itemRef)
        guard let ref = StremioRef(itemRef.itemID), let entry = StremioLibrary.entry(for: ref.metaID) else { return local }
        let videoID = ref.kind == .episode ? ref.detail : ref.metaID
        let isThisVideo = ref.kind == .movie || entry.videoID == videoID
        guard isThisVideo, (entry.lastWatched ?? .distantPast) > (local.lastViewedAt ?? .distantPast) else { return local }
        if ref.kind == .movie, entry.isWatched, entry.timeOffset == 0 {
            return MediaUserState(isPlayed: true, viewOffset: 0, isFavorite: false, lastViewedAt: entry.lastWatched)
        }
        guard entry.timeOffset > 0 else { return local }
        return MediaUserState(isPlayed: false, viewOffset: entry.timeOffset, isFavorite: false, lastViewedAt: entry.lastWatched)
    }

    /// Every catalog that takes a search, merged in addon order.
    func search(_ query: String) async throws -> [MediaItem] {
        let installed = try await self.addons()
        let searches = installed.flatMap { addon in
            addon.manifest.catalogs.filter(\.supportsSearch).map { (addon, $0) }
        }
        let results = await withTaskGroup(of: (Int, [StremioMetaPreview]).self) { group in
            for (index, entry) in searches.enumerated() {
                group.addTask {
                    let response: StremioCatalogResponse? = try? await StremioClient.resource(
                        entry.0, resource: "catalog", type: entry.1.type, id: entry.1.id,
                        extra: [("search", query)], timeout: 12)
                    return (index, response?.metas ?? [])
                }
            }
            var all: [(Int, [StremioMetaPreview])] = []
            for await result in group { all.append(result) }
            return all.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var seen = Set<String>()
        return results.filter { seen.insert("\($0.type)~\($0.id)").inserted }.map { item(from: $0, libraryID: nil) }
    }

    // MARK: - Meta, seasons, episodes

    func item(from preview: StremioMetaPreview, libraryID: String?) -> MediaItem {
        let isMovie = preview.type == "movie"
        let ref = StremioRef(kind: isMovie ? .movie : .series, type: preview.type, metaID: preview.id)
        let state = userState(for: MediaItemRef(providerID: id, itemID: ref.itemID))
        return MediaItem(
            ref: MediaItemRef(providerID: id, itemID: ref.itemID),
            kind: isMovie ? .movie : .show,
            title: preview.name, sortTitle: nil, overview: preview.description, year: preview.year,
            releaseDate: nil, contentRating: nil, runtime: preview.runtimeSeconds,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: state,
            artwork: MediaArtwork(poster: preview.poster, backdrop: preview.background, thumbnail: nil, logo: preview.logo),
            parentArtwork: nil, grandparentArtwork: nil,
            genres: preview.genres.isEmpty ? nil : preview.genres,
            externalIDs: preview.id.hasPrefix("tt") ? ["imdb": preview.id] : nil,
            libraryID: libraryID)
    }

    /// The first addon that has meta for this type and id answers, in collection order (Cinemeta first).
    func meta(type: String, id metaID: String) async throws -> StremioMeta {
        let installed = try await self.addons()
        let meta = await metaCache.value(for: "\(type)~\(metaID)") {
            for addon in installed where addon.manifest.supports("meta", type: type, id: metaID) {
                if let response: StremioMetaResponse = try? await StremioClient.resource(
                    addon, resource: "meta", type: type, id: metaID), let meta = response.meta {
                    return meta
                }
            }
            return nil
        }
        guard let meta else { throw MediaProviderError.notFound }
        return meta
    }

    private func showRef(_ ref: StremioRef) -> MediaItemRef {
        MediaItemRef(providerID: id, itemID: StremioRef(kind: .series, type: ref.type, metaID: ref.metaID).itemID)
    }

    private func seasonNumbers(_ meta: StremioMeta) -> [Int] {
        let numbers = Set(meta.videos.map { $0.season ?? 1 })
        // Specials (season 0) after the numbered seasons, as the Apple TV app lists them.
        return numbers.filter { $0 > 0 }.sorted() + (numbers.contains(0) ? [0] : [])
    }

    private func episodes(of meta: StremioMeta, ref: StremioRef, season: Int?) -> [MediaItem] {
        let show = item(from: meta.preview, libraryID: nil)
        let videos = meta.videos.enumerated().filter { season == nil || ($0.element.season ?? 1) == season }
        return videos.map { index, video in
            let seasonNumber = video.season ?? 1
            let episodeRef = StremioRef(kind: .episode, type: ref.type, metaID: ref.metaID, detail: video.id)
            let seasonRef = StremioRef(kind: .season, type: ref.type, metaID: ref.metaID, detail: String(seasonNumber))
            let itemRef = MediaItemRef(providerID: id, itemID: episodeRef.itemID)
            return MediaItem(
                ref: itemRef, kind: .episode,
                title: video.title.isEmpty ? String(localized: "Episode \(video.episode ?? index + 1)") : video.title,
                sortTitle: nil, overview: video.overview, year: video.released.flatMap { Int($0.prefix(4)) },
                releaseDate: video.released.map { String($0.prefix(10)) }, contentRating: nil,
                runtime: meta.preview.runtimeSeconds,
                parentRef: MediaItemRef(providerID: id, itemID: seasonRef.itemID),
                grandparentRef: showRef(ref),
                seriesTitle: meta.preview.name,
                episodeNumber: video.episode ?? index + 1, seasonNumber: seasonNumber, childProgress: nil,
                userState: userState(for: itemRef),
                artwork: MediaArtwork(poster: nil, backdrop: video.thumbnail ?? meta.preview.background,
                                      thumbnail: video.thumbnail, logo: nil),
                parentArtwork: show.artwork, grandparentArtwork: show.artwork,
                externalIDs: show.externalIDs)
        }
    }

    private func seasons(of meta: StremioMeta, ref: StremioRef) -> [MediaItem] {
        let show = item(from: meta.preview, libraryID: nil)
        return seasonNumbers(meta).map { number in
            let seasonRef = StremioRef(kind: .season, type: ref.type, metaID: ref.metaID, detail: String(number))
            let episodes = self.episodes(of: meta, ref: ref, season: number)
            let played = episodes.filter(\.userState.isPlayed).count
            return MediaItem(
                ref: MediaItemRef(providerID: id, itemID: seasonRef.itemID), kind: .season,
                title: number == 0 ? String(localized: "Specials") : String(localized: "Season \(number)"),
                sortTitle: nil, overview: nil, year: nil, runtime: nil,
                parentRef: showRef(ref), grandparentRef: nil, seriesTitle: meta.preview.name,
                episodeNumber: nil, seasonNumber: number,
                childProgress: ChildProgress(played: played, total: episodes.count),
                userState: MediaUserState(isPlayed: played == episodes.count && !episodes.isEmpty, viewOffset: 0,
                                          isFavorite: false, lastViewedAt: nil),
                artwork: show.artwork, parentArtwork: show.artwork, grandparentArtwork: nil)
        }
    }

    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] {
        guard let ref = StremioRef(itemRef.itemID) else { return [] }
        switch ref.kind {
        case .series:
            return seasons(of: try await self.meta(type: ref.type, id: ref.metaID), ref: ref)
        case .season:
            let meta = try await self.meta(type: ref.type, id: ref.metaID)
            return episodes(of: meta, ref: ref, season: ref.detail.flatMap { Int($0) })
        case .movie, .episode:
            return []
        }
    }

    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] {
        guard let ref = StremioRef(showRef.itemID) else { return [] }
        let meta = try await self.meta(type: ref.type, id: ref.metaID)
        let all = episodes(of: meta, ref: ref, season: nil)
        return all.filter { ($0.seasonNumber ?? 1) > 0 } + all.filter { $0.seasonNumber == 0 }
    }

    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        RelatedContent(items: [], collection: nil)
    }

    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        guard let ref = StremioRef(itemRef.itemID) else { throw MediaProviderError.notFound }
        let meta = try await self.meta(type: ref.type, id: ref.metaID)
        let show = self.item(from: meta.preview, libraryID: nil)
        let item: MediaItem
        var sources: [MediaSource] = []
        var nextEpisode: MediaItem?
        switch ref.kind {
        case .movie:
            item = show
            sources = try await streamOptions(type: ref.type, id: ref.streamID, runtime: show.runtime).map(\.source)
        case .series:
            item = show
            nextEpisode = StremioWatchStore.nextEpisode(in: allEpisodesSorted(meta, ref: ref))
        case .season:
            let number = ref.detail.flatMap { Int($0) }
            item = seasons(of: meta, ref: ref).first { $0.seasonNumber == number } ?? show
        case .episode:
            guard let episode = episodes(of: meta, ref: ref, season: nil).first(where: { $0.ref == itemRef }) else {
                throw MediaProviderError.notFound
            }
            item = episode
            sources = try await streamOptions(type: ref.type, id: ref.streamID, runtime: episode.runtime).map(\.source)
        }
        var detail = MediaItemDetail(
            item: item, tagline: nil, genres: meta.preview.genres, studios: [],
            cast: meta.cast.map { MediaPerson(id: "cast:\($0)", name: $0, role: nil, imageURL: nil) },
            directors: meta.directors.map { MediaPerson(id: "director:\($0)", name: $0, role: nil, imageURL: nil) },
            writers: meta.writers.map { MediaPerson(id: "writer:\($0)", name: $0, role: nil, imageURL: nil) },
            chapters: [], mediaSources: sources,
            trailerURL: meta.trailerYouTubeID.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") },
            contentRating: nil, nextEpisode: nextEpisode, collections: [])
        if let rating = meta.preview.imdbRating.flatMap(Double.init), let imdb = MediaRating(rating, source: .imdb) {
            detail.ratings = [imdb]
        }
        if meta.preview.id.hasPrefix("tt") { detail.externalIDs = ["imdb": meta.preview.id] }
        return detail
    }

    private func allEpisodesSorted(_ meta: StremioMeta, ref: StremioRef) -> [MediaItem] {
        episodes(of: meta, ref: ref, season: nil)
            .filter { ($0.seasonNumber ?? 1) > 0 }
            .sorted { ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0) }
    }

    // MARK: - Streams

    /// Every stream addon for this type and id, asked at once; each gets 15 s. Callers asking
    /// for the same title at the same time (detail page, carousel, Play) share one fetch.
    func streamOptions(type: String, id streamID: String, runtime: TimeInterval?) async throws -> [StremioStreamOption] {
        let installed = try await self.addons().filter { $0.manifest.supports("stream", type: type, id: streamID) }
        let options = await streamCache.value(for: "\(type)~\(streamID)") {
            let fetched = await withTaskGroup(of: (Int, [(String, StremioStream)]).self) { group in
                for (index, addon) in installed.enumerated() {
                    group.addTask {
                        let response: StremioStreamResponse? = try? await StremioClient.resource(
                            addon, resource: "stream", type: type, id: streamID, timeout: 15)
                        return (index, (response?.streams ?? []).map { (addon.manifest.name, $0) })
                    }
                }
                var all: [(Int, [(String, StremioStream)])] = []
                for await result in group { all.append(result) }
                return all.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
            let options = StremioStreamParser.options(from: fetched.map { (addon: $0.0, stream: $0.1) }, runtime: runtime)
            return options.isEmpty ? nil : options
        }
        return options ?? []
    }

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        guard let ref = StremioRef(itemRef.itemID), ref.kind == .movie || ref.kind == .episode else {
            throw MediaProviderError.notPlayable
        }
        let detailItem = try await fullDetail(for: itemRef).item
        let options = try await streamOptions(type: ref.type, id: ref.streamID, runtime: detailItem.runtime)
        let chosen = sourceID.flatMap { id in options.first { $0.id == id } }
            ?? VersionRanking.choose(.best, from: options.map(\.source)).flatMap { best in options.first { $0.id == best.id } }
        guard let option = chosen else { throw MediaProviderError.notPlayable }

        async let resolved = ExternalStreamResolver.resolve(option.url)
        async let subtitles = subtitleTracks(type: ref.type, id: ref.streamID, stream: option.stream)
        let (resolvedStream, subs) = await (resolved, subtitles)
        if let status = resolvedStream.statusCode, status >= 400 { throw MediaProviderError.unreachable }

        let base = option.source
        let source = MediaSource(
            id: base.id, container: base.container, duration: base.duration, bitrate: base.bitrate,
            fileSize: base.fileSize ?? resolvedStream.contentLength, fileName: base.fileName ?? resolvedStream.fileName,
            versionName: base.versionName, videoResolution: base.videoResolution,
            videoTracks: base.videoTracks, audioTracks: base.audioTracks, subtitleTracks: subs,
            streamKind: .directPlay, streamURL: resolvedStream.url)
        var info = StreamInfo(source: source, playSessionID: nil, trackInfoAvailable: false)
        info.headers = option.stream.requestHeaders
        return info
    }

    /// The stream's own subtitles and the subtitle addons' (OpenSubtitles), in the subtitle
    /// language from Settings and English, two of each at most.
    private func subtitleTracks(type: String, id streamID: String, stream: StremioStream) async -> [SubtitleTrack] {
        let installed = (try? await self.addons().filter { $0.manifest.supports("subtitles", type: type, id: streamID) }) ?? []
        var all = stream.subtitles
        await withTaskGroup(of: [StremioSubtitle].self) { group in
            for addon in installed {
                group.addTask {
                    let response: StremioSubtitlesResponse? = try? await StremioClient.resource(
                        addon, resource: "subtitles", type: type, id: streamID, timeout: 8)
                    return response?.subtitles ?? []
                }
            }
            for await subs in group { all += subs }
        }
        let wanted = [TrackLanguage.normalize(TrackIntentStore.subtitleLanguage), TrackLanguage.english]
        var perLanguage: [String: Int] = [:]
        var tracks: [SubtitleTrack] = []
        for subtitle in all {
            let language = TrackLanguage.normalize(subtitle.lang)
            guard wanted.contains(language), perLanguage[language, default: 0] < 2 else { continue }
            perLanguage[language, default: 0] += 1
            let ext = subtitle.url.pathExtension.lowercased()
            tracks.append(SubtitleTrack(
                id: "stremio-sub-\(tracks.count)", index: tracks.count,
                codec: ["srt", "ass", "ssa", "vtt"].contains(ext) ? ext : "srt",
                language: language, title: Locale.current.localizedString(forLanguageCode: language) ?? language,
                extendedTitle: nil, isDefault: false, isForced: false, isHearingImpaired: false,
                isEmbedded: false, externalURL: subtitle.url, isSelected: false))
        }
        return tracks
    }

    // MARK: - Watch state (this device's record, mirrored to the Stremio library)

    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any ProgressReporter {
        StremioProgressReporter(providerID: id, itemRef: itemRef, item: { [weak self] in
            try? await self?.fullDetail(for: itemRef).item
        }, sync: { [weak self] item, position, force in
            await self?.syncLibrary(itemRef, item: item, position: position, force: force)
        })
    }

    /// One position to the Stremio library: at most every 30 s while playing, always on pause and stop.
    func syncLibrary(_ itemRef: MediaItemRef, item: MediaItem?, position: TimeInterval, force: Bool) async {
        guard let ref = StremioRef(itemRef.itemID), ref.kind == .movie || ref.kind == .episode,
              StremioLibrary.shouldWrite(ref.metaID, force: force) else { return }
        await StremioLibrary.refresh(authKey: authKey)
        await StremioLibrary.record(StremioLibrary.Progress(
            metaID: ref.metaID, type: ref.type,
            name: item?.seriesTitle ?? item?.title ?? ref.metaID,
            poster: item?.grandparentArtwork?.poster ?? item?.artwork.poster,
            videoID: ref.streamID, position: position, duration: item?.runtime), authKey: authKey)
    }

    private func setLibraryWatched(_ itemRef: MediaItemRef, item: MediaItem?, watched: Bool) async {
        guard let ref = StremioRef(itemRef.itemID), ref.kind == .movie || ref.kind == .episode else { return }
        await StremioLibrary.refresh(authKey: authKey)
        await StremioLibrary.setWatched(metaID: ref.metaID, type: ref.type,
                                        name: item?.seriesTitle ?? item?.title ?? ref.metaID,
                                        poster: item?.grandparentArtwork?.poster ?? item?.artwork.poster,
                                        videoID: ref.streamID, watched: watched, authKey: authKey)
    }

    func markPlayed(_ itemRef: MediaItemRef) async throws {
        let item = try? await fullDetail(for: itemRef).item
        StremioWatchStore.markPlayed(itemRef, item: item, played: true)
        await setLibraryWatched(itemRef, item: item, watched: true)
    }

    func markUnplayed(_ itemRef: MediaItemRef) async throws {
        StremioWatchStore.markPlayed(itemRef, item: nil, played: false)
        await setLibraryWatched(itemRef, item: nil, watched: false)
    }

    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        let item = try? await fullDetail(for: itemRef).item
        StremioWatchStore.save(itemRef, position: position, item: item)
        await syncLibrary(itemRef, item: item, position: position, force: true)
    }

    func removeFromContinueWatching(_ item: MediaItem) async throws {
        StremioWatchStore.removeFromContinueWatching(item.ref)
        if let ref = StremioRef(item.ref.itemID) {
            await StremioLibrary.refresh(authKey: authKey)
            await StremioLibrary.dismiss(metaID: ref.metaID, authKey: authKey)
        }
    }

    func canRemoveFromContinueWatching(_ item: MediaItem) -> Bool { true }

    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {}
    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {}

    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool { false }
    func addToWatchlist(_ ref: MediaItemRef) async throws {}
    func removeFromWatchlist(_ ref: MediaItemRef) async throws {}
}

/// The addon collection, fetched once and kept for the session.
actor StremioAddonStore {
    private let authKey: String
    private var cached: [StremioAddon]?
    private var loading: Task<[StremioAddon], Error>?

    init(authKey: String) { self.authKey = authKey }

    func addons() async throws -> [StremioAddon] {
        if let cached { return cached }
        if let loading { return try await loading.value }
        let key = authKey
        let task = Task { try await StremioClient.addonCollection(authKey: key) }
        loading = task
        defer { loading = nil }
        let addons = try await task.value
        cached = addons
        return addons
    }

    func reload() {
        cached = nil
        loading = nil
    }
}

/// A small time-limited cache that also shares a fetch in flight. A fetch that finds
/// nothing is not kept, so the next ask tries again.
actor StremioCache<Value: Sendable> {
    private let lifetime: TimeInterval
    private var entries: [String: (value: Value, at: Date)] = [:]
    private var inFlight: [String: Task<Value?, Never>] = [:]

    init(lifetime: TimeInterval) { self.lifetime = lifetime }

    func value(for key: String, fetch: @escaping @Sendable () async -> Value?) async -> Value? {
        if let entry = entries[key], Date().timeIntervalSince(entry.at) < lifetime { return entry.value }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await fetch() }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        if let value {
            if entries.count > 200 { entries.removeAll() }
            entries[key] = (value, Date())
        }
        return value
    }
}
