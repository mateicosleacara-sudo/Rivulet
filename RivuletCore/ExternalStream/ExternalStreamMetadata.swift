// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  ExternalStreamMetadata.swift
//  Rivulet
//
//  What a stream sent by another app is. Infuse's link format carries only the URL,
//  so the title comes from the file name (the link's, the file host's, or a path
//  component that ends in a video extension), parsed as a release name and matched
//  on Cinemeta, Stremio's own public catalog: name, poster, backdrop, logo, and the
//  episode's name for a series. The IMDb id it returns is also what the resume point
//  is keyed on, since a debrid link is new on every send.
//

import Foundation

/// Everything the player shows for the stream, and the key its resume point lives under.
nonisolated struct ExternalStreamInfo: Sendable {
    var title: String
    var kind: MediaKind = .movie
    var seriesTitle: String?
    var season: Int?
    var episode: Int?
    var year: Int?
    var overview: String?
    var poster: URL?
    var backdrop: URL?
    var logo: URL?
    var imdbID: String?
    var fileName: String?
    /// The stream's identity across sends (`ExternalStreamResumeStore.key(for:)`).
    var identity: String
}

nonisolated enum ExternalStreamMetadata {

    /// The file's name, from the most to the least trustworthy place.
    static func fileName(link: ExternalStreamLink, resolved: ExternalStreamResolver.Resolved) -> String? {
        if let name = link.filename, !name.isEmpty { return name }
        if let name = resolved.fileName, !name.isEmpty { return name }
        for url in [resolved.url, link.streamURL] {
            for component in url.pathComponents.reversed() {
                let name = component.removingPercentEncoding ?? component
                if ExternalStreamLink.strippingVideoExtension(name) != name { return name }
            }
        }
        return nil
    }

    /// Builds the info, asking Cinemeta for at most `timeout` seconds. Without a match it
    /// keeps the parsed release name, and without a file name a plain "Stream".
    static func info(link: ExternalStreamLink, resolved: ExternalStreamResolver.Resolved,
                     timeout: TimeInterval = 6) async -> ExternalStreamInfo {
        let file = fileName(link: link, resolved: resolved)
        let parsed = file.flatMap(ReleaseName.init)
        var info = ExternalStreamInfo(
            title: parsed?.title ?? file.map(ExternalStreamLink.strippingVideoExtension) ?? String(localized: "Stream"),
            kind: parsed?.episode != nil ? .episode : .movie,
            seriesTitle: parsed?.episode != nil ? parsed?.title : nil,
            season: parsed?.season, episode: parsed?.episode, year: parsed?.year,
            fileName: file,
            identity: file.map { "name:" + $0.lowercased() } ?? link.resumeIdentity)
        if let parsed, parsed.episode != nil, let season = parsed.season, let episode = parsed.episode {
            info.title = String(localized: "S\(season), E\(episode)")
        }
        guard let parsed else { return info }
        guard let meta = await withTimeout(timeout, { await Cinemeta.match(parsed) }) else { return info }

        info.imdbID = meta.id
        info.poster = meta.poster.flatMap(URL.init(string:)).map(Cinemeta.larger)
        info.backdrop = meta.background.flatMap(URL.init(string:))
        info.logo = meta.logo.flatMap(URL.init(string:))
        info.year = meta.year ?? info.year
        if let season = parsed.season, let episode = parsed.episode {
            info.seriesTitle = meta.name
            let video = meta.videos?.first { $0.season == season && $0.episode == episode }
            if let name = video?.name ?? video?.title, !name.isEmpty { info.title = name }
            info.overview = video?.overview ?? video?.description ?? meta.description
            info.identity = "imdb:\(meta.id):\(season):\(episode)"
        } else {
            info.title = meta.name
            info.overview = meta.description
            info.identity = "imdb:\(meta.id)"
        }
        return info
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                                 _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// A scene or P2P release name: "The.Movie.2019.2160p.UHD.BluRay.REMUX..." or
/// "Show.Name.S01E02.1080p.WEB-DL...".
nonisolated struct ReleaseName: Equatable, Sendable {
    let title: String
    let year: Int?
    let season: Int?
    let episode: Int?

    private static let stopWords: Set<String> = [
        "2160p", "1080p", "1080i", "720p", "576p", "480p", "4k", "uhd", "hd", "fhd", "bluray", "blu-ray", "bdremux",
        "remux", "bdrip", "brrip", "web-dl", "webdl", "webrip", "web", "hdtv", "dvdrip", "hdr", "hdr10", "hdr10+",
        "dv", "dovi", "x264", "x265", "h264", "h265", "h.264", "h.265", "hevc", "avc", "proper", "repack", "extended",
        "unrated", "imax", "complete", "multi", "truehd", "atmos", "dts", "dts-hd", "ddp", "dd5.1", "aac", "10bit",
        "remastered", "criterion", "directors", "uncut", "limited", "internal",
    ]

    init?(_ raw: String) {
        var name = ExternalStreamLink.strippingVideoExtension(raw)
        // A leading "[Group]" tag.
        while name.hasPrefix("["), let close = name.firstIndex(of: "]") {
            name = String(name[name.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        let spaced = name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        let tokens = spaced.split(whereSeparator: { $0 == " " }).map(String.init)
        var titleTokens: [String] = []
        var year: Int?, season: Int?, episode: Int?
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}-"))
            let lower = bare.lowercased()
            if let (s, e) = Self.seasonEpisode(lower) {
                season = s; episode = e; break
            }
            if let s = Self.seasonOnly(lower) {
                season = s; break
            }
            if let y = Self.year(bare), i > 0 {
                // "Blade Runner 2049 2017": the last year in a run is the release's.
                if i + 1 < tokens.count,
                   let next = Self.year(tokens[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}-"))) {
                    titleTokens.append(bare)
                    year = next
                } else {
                    year = y
                }
                break
            }
            if Self.stopWords.contains(lower) || (lower.hasSuffix("p") && Int(lower.dropLast()) != nil) { break }
            titleTokens.append(token)
            i += 1
        }
        let title = titleTokens.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -([{"))
        guard !title.isEmpty else { return nil }
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
    }

    private static func year(_ text: String) -> Int? {
        guard text.count == 4, let value = Int(text), (1900...2099).contains(value) else { return nil }
        return value
    }

    /// "s01e02", "s1e2", "s01e02e03", "1x02".
    private static func seasonEpisode(_ text: String) -> (Int, Int)? {
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = nil
        if scanner.scanString("s") != nil, let s = scanner.scanInt(), scanner.scanString("e") != nil,
           let e = scanner.scanInt() {
            return (s, e)
        }
        let parts = text.split(separator: "x")
        if parts.count == 2, parts[0].count <= 2, parts[1].count >= 2, parts[1].count <= 3,
           let s = Int(parts[0]), let e = Int(parts[1]) {
            return (s, e)
        }
        return nil
    }

    /// A season pack's "s01".
    private static func seasonOnly(_ text: String) -> Int? {
        guard text.count >= 2, text.count <= 3, text.hasPrefix("s"), let s = Int(text.dropFirst()) else { return nil }
        return s
    }
}

/// Stremio's public catalog (v3-cinemeta.strem.io): no key, and the same data Stremio shows.
nonisolated enum Cinemeta {
    static let base = URL(string: "https://v3-cinemeta.strem.io")!

    struct Meta: Decodable, Sendable {
        let id: String
        let name: String
        let poster: String?
        let background: String?
        let logo: String?
        let description: String?
        let releaseInfo: String?
        let videos: [Video]?

        var year: Int? { releaseInfo.flatMap { Int($0.prefix(4)) } }
    }

    struct Video: Decodable, Sendable {
        let season: Int?
        let episode: Int?
        let name: String?
        let title: String?
        let overview: String?
        let description: String?
    }

    private struct Catalog: Decodable { let metas: [Meta]? }
    private struct MetaResponse: Decodable { let meta: Meta? }

    /// The best catalog hit for the release (year within one, else the first), with its full meta.
    static func match(_ release: ReleaseName) async -> Meta? {
        let type = release.season != nil ? "series" : "movie"
        guard let query = release.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "catalog/\(type)/top/search=\(query).json", relativeTo: base),
              let catalog: Catalog = await fetch(url),
              let metas = catalog.metas, !metas.isEmpty else { return nil }
        let pick = release.year.flatMap { year in metas.first { meta in meta.year.map { abs($0 - year) <= 1 } ?? false } }
            ?? metas.first!
        guard let metaURL = URL(string: "meta/\(type)/\(pick.id).json", relativeTo: base),
              let full: MetaResponse = await fetch(metaURL), let meta = full.meta else { return pick }
        return meta
    }

    /// metahub's "small" poster is 154 px wide; "medium" suits the info card.
    static func larger(_ url: URL) -> URL {
        URL(string: url.absoluteString.replacingOccurrences(of: "/poster/small/", with: "/poster/medium/")) ?? url
    }

    private static func fetch<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
