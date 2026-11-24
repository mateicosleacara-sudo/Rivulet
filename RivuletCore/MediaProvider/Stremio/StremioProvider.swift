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
    /// "Favorites" in the code, Plan to Watch on screen (`StremioPlanStore`).
    let supportsFavorites = true

    let authKey: String
    private let addonStore: StremioAddonStore
    private let binge = StremioBinge()

    /// The picker's pick for the next resolve: played as chosen, never swapped for the series' release.
    func markExplicitPick(_ sourceID: String) { binge.markExplicitPick(sourceID) }
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

    /// The sidebar: the first catalog (Cinemeta's Popular Movies) on its own, and every other
    /// catalog behind one "Catalogs" library, so the sidebar stays short. Home still gets a row
    /// per catalog (`hubs()`, which `ServerDataStore` adds for Stremio).
    func libraries() async throws -> [MediaLibrary] {
        let all = try await catalogLibraries()
        guard let first = Self.leadCatalog(all) else { return [] }
        let catalogs = MediaLibrary(id: Self.catalogsLibraryID, providerID: id,
                                    title: String(localized: "Catalogs"), kind: .mixed)
        return all.count > 1 ? [first, catalogs] : [first]
    }

    nonisolated static let catalogsLibraryID = "stremio~catalogs"

    /// Cinemeta's Popular Movies when it is installed, else the first catalog.
    static func leadCatalog(_ all: [MediaLibrary]) -> MediaLibrary? {
        all.first { $0.id == "com.linvo.cinemeta~movie~top" } ?? all.first
    }

    /// Every catalog that can be listed with no extra, in addon order.
    func catalogLibraries() async throws -> [MediaLibrary] {
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

    /// The catalogs behind "Catalogs": all but the lead one.
    private func folderCatalogs() async throws -> [MediaLibrary] {
        let all = try await catalogLibraries()
        let lead = Self.leadCatalog(all)
        return all.filter { $0.id != lead?.id }
    }

    /// One row per catalog behind "Catalogs", first page each, fetched at once and kept 10 minutes.
    private let hubCache = StremioCache<[MediaHub]>(lifetime: 600)

    private func catalogHubs() async throws -> [MediaHub] {
        let catalogs = try await folderCatalogs()
        let hubs = await hubCache.value(for: "catalogs") { [weak self] in
            guard let self else { return nil }
            let fetched = await withTaskGroup(of: (Int, MediaHub?).self) { group in
                for (index, library) in catalogs.enumerated() {
                    group.addTask {
                        guard let hub = try? await self.recentlyAddedHub(in: library) else { return (index, nil) }
                        return (index, MediaHub(id: "\(library.id).stremioRow", providerID: hub.providerID,
                                                title: hub.title, style: .shelf, items: hub.items))
                    }
                }
                var all: [(Int, MediaHub?)] = []
                for await result in group { all.append(result) }
                return all.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            return fetched.isEmpty ? nil : fetched
        }
        return hubs ?? []
    }

    /// The Catalogs page's rows: Popular Movies, then the rest. Home keeps its own Popular Movies row
    /// (the library's) and gets only the rest from `hubs()`, so it never shows it twice.
    private func catalogsPageHubs() async -> [MediaHub] {
        let rest = (try? await catalogHubs()) ?? []
        guard let lead = Self.leadCatalog((try? await catalogLibraries()) ?? []),
              let hub = try? await recentlyAddedHub(in: lead) else { return rest }
        return [MediaHub(id: "\(lead.id).stremioRow", providerID: hub.providerID, title: hub.title,
                         style: .shelf, items: hub.items)] + rest
    }

    /// A catalog as a tile in the Catalogs grid; opening it lists the catalog.
    private func catalogTile(_ library: MediaLibrary, art: MediaItem?) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: id, itemID: "c~" + library.id), kind: .collection,
            title: library.title, sortTitle: nil, overview: nil, year: nil, runtime: nil,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: art?.artwork.poster, backdrop: art?.artwork.backdrop, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil, libraryID: Self.catalogsLibraryID)
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
        if library.id == Self.catalogsLibraryID {
            guard page.offset == 0 else { return PagedResult(items: [], total: 0, nextPage: nil) }
            // Every catalog, Popular Movies included (it also has its own sidebar entry).
            let catalogs = try await catalogLibraries()
            let hubs = await catalogsPageHubs()
            let tiles = catalogs.map { library in
                catalogTile(library, art: hubs.first { $0.id == "\(library.id).stremioRow" }?.items.first)
            }
            return PagedResult(items: tiles, total: tiles.count, nextPage: nil)
        }
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
        guard library.id != Self.catalogsLibraryID else { return nil }
        let (addon, catalog) = try await catalog(for: library)
        let response: StremioCatalogResponse = try await StremioClient.resource(
            addon, resource: "catalog", type: catalog.type, id: catalog.id)
        let items = response.metas.prefix(30).map { item(from: $0, libraryID: library.id) }
        guard !items.isEmpty else { return nil }
        // "<library>.recentlyAdded" is the id ServerDataStore files a library's Home row under.
        return MediaHub(id: "\(library.id).recentlyAdded", providerID: id, title: library.title, style: .shelf,
                        items: Array(items))
    }

    /// Home's rows beyond the libraries': one per catalog behind "Catalogs".
    func hubs() async throws -> [MediaHub] { try await catalogHubs() }
    /// A library page's rows: every catalog on the Catalogs page, the catalog itself elsewhere.
    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        if library.id == Self.catalogsLibraryID { return await catalogsPageHubs() }
        return try await recentlyAddedHub(in: library).map { [$0] } ?? []
    }
    func recentlyAdded(limit: Int) async throws -> [MediaItem] { [] }

    /// Titles stopped partway, and for a series whose last episode was finished, the next one
    /// (once it has aired and unless its card was dismissed), newest first, one per series.
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        let inProgress = StremioWatchStore.continueWatching(providerID: id)
        let finished = StremioWatchStore.finishedEpisodes(providerID: id).prefix(limit)
        let nextUp = await withTaskGroup(of: MediaItem?.self) { group in
            for (episode, finishedAt) in finished {
                group.addTask { await self.nextUp(after: episode, finishedAt: finishedAt) }
            }
            var all: [MediaItem] = []
            for await item in group { if let item { all.append(item) } }
            return all
        }
        var seriesSeen = Set<String>()
        return (inProgress + nextUp)
            .sorted { ($0.userState.lastViewedAt ?? .distantPast) > ($1.userState.lastViewedAt ?? .distantPast) }
            .filter { item in
                guard item.kind == .episode, let series = item.grandparentRef?.itemID else { return true }
                return seriesSeen.insert(series).inserted
            }
            .prefix(limit)
            .map { $0 }
    }

    private func nextUp(after episode: MediaItem, finishedAt: Date) async -> MediaItem? {
        guard let ref = StremioRef(episode.ref.itemID),
              let meta = try? await self.meta(type: ref.type, id: ref.metaID) else { return nil }
        let episodes = allEpisodesSorted(meta, ref: ref)
        guard let index = episodes.firstIndex(where: { $0.ref == episode.ref }), episodes.indices.contains(index + 1) else {
            return nil
        }
        var next = episodes[index + 1]
        // Not aired yet (or no date to tell): nothing to offer.
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        guard let released = next.releaseDate, released <= today else { return nil }
        // Started, finished or dismissed already: the store decides (in progress shows on its own).
        if StremioWatchStore.entry(for: next.ref) != nil { return nil }
        next.userState = MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: finishedAt)
        return next
    }

    /// Every catalog that takes a search, merged in addon order. A query with spaces is also asked
    /// joined up ("back rooms" finds "Backrooms"), and titles that match the query letter for
    /// letter (ignoring spaces and punctuation) come first; everything else keeps the addons' order.
    func search(_ query: String) async throws -> [MediaItem] {
        let installed = try await self.addons()
        let searches = installed.flatMap { addon in
            addon.manifest.catalogs.filter(\.supportsSearch).map { (addon, $0) }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = trimmed.replacingOccurrences(of: " ", with: "")
        let queries = joined != trimmed && joined.count >= 3 ? [trimmed, joined] : [trimmed]
        var requests: [(Int, Int, (StremioAddon, StremioManifest.Catalog), String)] = []
        for (q, text) in queries.enumerated() {
            for (index, entry) in searches.enumerated() { requests.append((q, index, entry, text)) }
        }
        let results = await withTaskGroup(of: (Int, Int, [StremioMetaPreview]).self) { group in
            for (q, index, entry, text) in requests {
                group.addTask {
                    let response: StremioCatalogResponse? = try? await StremioClient.resource(
                        entry.0, resource: "catalog", type: entry.1.type, id: entry.1.id,
                        extra: [("search", text)], timeout: 12)
                    return (q, index, response?.metas ?? [])
                }
            }
            var all: [(Int, Int, [StremioMetaPreview])] = []
            for await result in group { all.append(result) }
            // The typed query's results first, each in addon order.
            return all.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.flatMap(\.2)
        }
        var seen = Set<String>()
        let unique = results.filter { seen.insert("\($0.type)~\($0.id)").inserted }
        let wanted = Self.searchKey(trimmed)
        let ranked = unique.enumerated().sorted { a, b in
            let (sa, sb) = (Self.matchScore(a.element.name, wanted), Self.matchScore(b.element.name, wanted))
            return sa != sb ? sa < sb : a.offset < b.offset
        }
        return ranked.map { item(from: $0.element, libraryID: nil) }
    }

    /// Letters and digits only, lowercased: "Back Rooms" and "Backrooms" read the same.
    static func searchKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// 0 the same title, 1 starts with the query, 2 anything else (kept in the addons' order).
    static func matchScore(_ title: String, _ wanted: String) -> Int {
        guard !wanted.isEmpty else { return 2 }
        let key = searchKey(title)
        if key == wanted { return 0 }
        if key.hasPrefix(wanted) { return 1 }
        return 2
    }

    // MARK: - Meta, seasons, episodes

    func item(from preview: StremioMetaPreview, libraryID: String?) -> MediaItem {
        let isMovie = preview.type == "movie"
        let ref = StremioRef(kind: isMovie ? .movie : .series, type: preview.type, metaID: preview.id)
        let state = StremioWatchStore.state(for: MediaItemRef(providerID: id, itemID: ref.itemID))
        return MediaItem(
            ref: MediaItemRef(providerID: id, itemID: ref.itemID),
            kind: isMovie ? .movie : .show,
            title: preview.name, sortTitle: nil, overview: preview.description, year: preview.year,
            releaseDate: nil, contentRating: nil, runtime: preview.runtimeSeconds,
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: state.isPlayed, viewOffset: state.viewOffset,
                                      isFavorite: StremioPlanStore.contains(MediaItemRef(providerID: id, itemID: ref.itemID)),
                                      lastViewedAt: state.lastViewedAt),
            artwork: MediaArtwork(poster: StremioImages.poster(preview.poster), backdrop: StremioImages.backdrop(preview.background),
                                  thumbnail: nil, logo: StremioImages.logo(preview.logo)),
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
                userState: StremioWatchStore.state(for: itemRef),
                artwork: MediaArtwork(poster: nil, backdrop: StremioImages.backdrop(video.thumbnail ?? meta.preview.background),
                                      thumbnail: StremioImages.backdrop(video.thumbnail), logo: nil),
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
        if itemRef.itemID.hasPrefix("c~") {
            let libraryID = String(itemRef.itemID.dropFirst(2))
            guard let library = try await catalogLibraries().first(where: { $0.id == libraryID }) else { return [] }
            return try await items(in: library, sort: .titleAsc, page: Page(offset: 0, limit: 100)).items
        }
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
            sources = StremioStreamParser.playable(
                try await streamOptions(type: ref.type, id: ref.streamID, runtime: show.runtime)).map(\.source)
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
            sources = StremioStreamParser.playable(
                try await streamOptions(type: ref.type, id: ref.streamID, runtime: episode.runtime)).map(\.source)
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

    /// The picker's fetch: `onUpdate` gets the list so far each time another addon answers,
    /// in addon order, so streams show as they arrive instead of after the slowest addon.
    /// A list already cached, or a fetch already running for this title (the detail page's), is used as is.
    func streamOptions(type: String, id streamID: String, runtime: TimeInterval?,
                       onUpdate: @escaping @MainActor ([StremioStreamOption]) -> Void) async throws -> [StremioStreamOption] {
        let key = "\(type)~\(streamID)"
        if let ready = await streamCache.existing(for: key) { return ready ?? [] }
        let installed = try await self.addons().filter { $0.manifest.supports("stream", type: type, id: streamID) }
        var byAddon: [Int: [(String, StremioStream)]] = [:]
        await withTaskGroup(of: (Int, [(String, StremioStream)]).self) { group in
            for (index, addon) in installed.enumerated() {
                group.addTask {
                    let response: StremioStreamResponse? = try? await StremioClient.resource(
                        addon, resource: "stream", type: type, id: streamID, timeout: 15)
                    return (index, (response?.streams ?? []).map { (addon.manifest.name, $0) })
                }
            }
            for await (index, streams) in group {
                byAddon[index] = streams
                let sofar = byAddon.keys.sorted().flatMap { byAddon[$0] ?? [] }
                let options = StremioStreamParser.options(from: sofar.map { (addon: $0.0, stream: $0.1) }, runtime: runtime)
                // Cached as it grows, so a stream picked before the last addon answers starts at once.
                if !options.isEmpty { await streamCache.store(options, for: key) }
                await onUpdate(options)
            }
        }
        let all = byAddon.keys.sorted().flatMap { byAddon[$0] ?? [] }
        let options = StremioStreamParser.options(from: all.map { (addon: $0.0, stream: $0.1) }, runtime: runtime)
        if !options.isEmpty { await streamCache.store(options, for: key) }
        return options
    }

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        guard let ref = StremioRef(itemRef.itemID), ref.kind == .movie || ref.kind == .episode else {
            throw MediaProviderError.notPlayable
        }
        let runtime = await watchItem(for: itemRef)?.runtime
        let options = try await streamOptions(type: ref.type, id: ref.streamID, runtime: runtime)
        let explicit = sourceID.map(binge.takeExplicitPick) ?? false
        // A pick made by hand, else the version the detail page asked for, else the recommended
        // stream: the one last played for this title (the same release for the next episode).
        let chosen = (explicit ? sourceID.flatMap { id in options.first { $0.id == id } } : nil)
            ?? sourceID.flatMap { id in options.first { $0.id == id } }
            ?? StremioRecommendation.recommended(options, remembered: StremioStreamMemory.choice(for: ref.metaID))
        guard let option = chosen else { throw MediaProviderError.notPlayable }
        // Remembered as Last Watched only after 3 minutes of it (`StremioProgressReporter`).
        binge.setPlaying(option, metaID: ref.metaID, itemID: itemRef.itemID)

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
        // One deadline for all of them: whatever arrived in 3 s plays, so a slow subtitle addon
        // never holds up the start. (Subtitles inside the file don't come from here.)
        await withTaskGroup(of: [StremioSubtitle]?.self) { group in
            for addon in installed {
                group.addTask {
                    let response: StremioSubtitlesResponse? = try? await StremioClient.resource(
                        addon, resource: "subtitles", type: type, id: streamID, timeout: 3)
                    return response?.subtitles ?? []
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            for await subs in group {
                guard let subs else { group.cancelAll(); break }
                all += subs
            }
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

    // MARK: - Watch state (this Apple TV only, by choice: nothing goes to Stremio or Trakt)

    /// The movie or episode as Continue Watching keeps it, from the meta alone: no stream fetch,
    /// so a slow or failing addon can't leave a saved position without its title.
    func watchItem(for itemRef: MediaItemRef) async -> MediaItem? {
        guard let ref = StremioRef(itemRef.itemID),
              let meta = try? await self.meta(type: ref.type, id: ref.metaID) else { return nil }
        switch ref.kind {
        case .movie: return item(from: meta.preview, libraryID: nil)
        case .episode: return episodes(of: meta, ref: ref, season: nil).first { $0.ref == itemRef }
        case .series, .season: return nil
        }
    }

    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any ProgressReporter {
        let binge = binge
        return StremioProgressReporter(providerID: id, itemRef: itemRef, item: { [weak self] in
            await self?.watchItem(for: itemRef)
        }, rememberStream: {
            guard let (option, metaID) = binge.playing(itemID: itemRef.itemID) else { return }
            StremioStreamMemory.record(option, metaID: metaID)
        })
    }

    func markPlayed(_ itemRef: MediaItemRef) async throws {
        let item = await watchItem(for: itemRef)
        StremioWatchStore.markPlayed(itemRef, item: item, played: true)
    }

    func markUnplayed(_ itemRef: MediaItemRef) async throws {
        StremioWatchStore.markPlayed(itemRef, item: nil, played: false)
    }

    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        let item = await watchItem(for: itemRef)
        StremioWatchStore.save(itemRef, position: position, item: item)
    }

    func removeFromContinueWatching(_ item: MediaItem) async throws {
        StremioWatchStore.removeFromContinueWatching(item.ref)
    }

    func canRemoveFromContinueWatching(_ item: MediaItem) -> Bool { true }

    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {}
    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {}

    /// Plan to Watch, once, under the lead library (the favorites feed asks every movie and show
    /// library, and every Stremio title would otherwise come back once per catalog).
    func favorites(in library: MediaLibrary, limit: Int) async throws -> [MediaItem] {
        guard library.id == Self.leadCatalog((try? await catalogLibraries()) ?? [])?.id else { return [] }
        return Array(StremioPlanStore.items(providerID: id).prefix(limit))
    }

    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        guard favorite else { return StremioPlanStore.set(false, item: nil, ref: ref) }
        guard let parsed = StremioRef(ref.itemID), parsed.kind == .movie || parsed.kind == .series else {
            throw MediaProviderError.notFound
        }
        let meta = try await self.meta(type: parsed.type, id: parsed.metaID)
        var item = self.item(from: meta.preview, libraryID: nil)
        item.userState = MediaUserState(isPlayed: item.userState.isPlayed, viewOffset: item.userState.viewOffset,
                                        isFavorite: true, lastViewedAt: item.userState.lastViewedAt)
        StremioPlanStore.set(true, item: item, ref: ref)
    }

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

    /// A fresh cached value, or a running fetch's result (awaited); nil when neither exists.
    func existing(for key: String) async -> Value?? {
        if let entry = entries[key], Date().timeIntervalSince(entry.at) < lifetime { return .some(entry.value) }
        if let task = inFlight[key] { return .some(await task.value) }
        return nil
    }

    func store(_ value: Value, for key: String) {
        if entries.count > 200 { entries.removeAll() }
        entries[key] = (value, Date())
    }

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

/// The release last played per series (bingeGroup and addon), and picks the user made by hand.
nonisolated final class StremioBinge: @unchecked Sendable {
    struct Last: Sendable {
        let group: String?
        let addon: String
    }

    private let lock = NSLock()
    private var lastBySeries: [String: Last] = [:]
    private var explicitPicks: Set<String> = []

    func markExplicitPick(_ sourceID: String) { lock.withLock { _ = explicitPicks.insert(sourceID) } }

    /// True once for a pick made by hand.
    func takeExplicitPick(_ sourceID: String) -> Bool {
        lock.withLock { explicitPicks.remove(sourceID) != nil }
    }

    func last(for metaID: String) -> Last? { lock.withLock { lastBySeries[metaID] } }

    /// The stream each title is playing, until 3 minutes of it make it Last Watched.
    private var playingByItem: [String: (StremioStreamOption, String)] = [:]

    func setPlaying(_ option: StremioStreamOption, metaID: String, itemID: String) {
        lock.withLock { playingByItem[itemID] = (option, metaID) }
    }

    func playing(itemID: String) -> (StremioStreamOption, String)? { lock.withLock { playingByItem[itemID] } }

    func record(metaID: String, group: String?, addon: String) {
        lock.withLock { lastBySeries[metaID] = Last(group: group, addon: addon) }
    }
}
