// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioModels.swift
//  Rivulet
//
//  The Stremio account API (api.strem.io, link.stremio.com) and the addon
//  protocol (manifest, catalog, meta, stream, subtitles), as stremio-core reads
//  them. Addons are written by many people, so every field is decoded leniently:
//  a number where a string belongs, an empty string for a missing URL, or one bad
//  item in a list never fails the whole response.
//

import Foundation

// MARK: - Lenient decoding

/// A string that also accepts a number ("2019" or 2019).
nonisolated struct StremioText: Decodable, Sendable, Hashable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = string }
        else if let int = try? container.decode(Int.self) { value = String(int) }
        else if let double = try? container.decode(Double.self) { value = String(double) }
        else { value = "" }
    }
}

/// Decodes each element on its own and drops the ones that fail.
nonisolated struct StremioLossyList<Element: Decodable & Sendable>: Decodable, Sendable {
    let items: [Element]
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) { items.append(item) }
            else { _ = try? container.decode(StremioSkip.self) }
        }
        self.items = items
    }
}

/// Consumes one element of any shape, so a bad entry can be stepped over.
private nonisolated struct StremioSkip: Decodable {
    init(from decoder: Decoder) throws {}
}

extension KeyedDecodingContainer {
    nonisolated func stremioURL(_ key: Key) -> URL? {
        guard let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil,
              !text.isEmpty, let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        else { return nil }
        return url
    }

    nonisolated func stremioText(_ key: Key) -> String? {
        ((try? decodeIfPresent(StremioText.self, forKey: key)) ?? nil)?.value.nilIfEmpty
    }

    nonisolated func stremioList<T: Decodable & Sendable>(_ key: Key) -> [T] {
        ((try? decodeIfPresent(StremioLossyList<T>.self, forKey: key)) ?? nil)?.items ?? []
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Account API

nonisolated struct StremioAPIError: Decodable, Error, Sendable {
    let message: String
    let code: Int?
}

/// `{"result": …}` or `{"error": {"message", "code"}}`.
nonisolated struct StremioAPIResult<T: Decodable & Sendable>: Decodable, Sendable {
    let result: T?
    let error: StremioAPIError?
}

nonisolated struct StremioUser: Decodable, Sendable {
    let id: String
    let email: String?

    enum CodingKeys: String, CodingKey { case id = "_id", email }
}

nonisolated struct StremioAuthResponse: Decodable, Sendable {
    let authKey: String
    let user: StremioUser
}

nonisolated struct StremioLinkCode: Decodable, Sendable {
    let code: String
    let link: String
    let qrcode: String?
}

nonisolated struct StremioLinkAuthKey: Decodable, Sendable {
    let authKey: String
}

/// One installed addon from `addonCollectionGet`.
nonisolated struct StremioAddon: Decodable, Sendable, Hashable {
    let transportUrl: URL
    let manifest: StremioManifest

    /// The addon's root: its manifest URL without "/manifest.json".
    var baseURL: String {
        let text = transportUrl.absoluteString
        guard let range = text.range(of: "/manifest.json", options: .backwards) else { return text }
        return String(text[..<range.lowerBound])
    }

    enum CodingKeys: String, CodingKey { case transportUrl, manifest }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = container.stremioURL(.transportUrl) else {
            throw DecodingError.dataCorruptedError(forKey: .transportUrl, in: container, debugDescription: "No transport URL")
        }
        transportUrl = url
        manifest = try container.decode(StremioManifest.self, forKey: .manifest)
    }

    static func == (a: StremioAddon, b: StremioAddon) -> Bool { a.transportUrl == b.transportUrl }
    func hash(into hasher: inout Hasher) { hasher.combine(transportUrl) }
}

nonisolated struct StremioAddonCollection: Decodable, Sendable {
    let addons: [StremioAddon]

    enum CodingKeys: String, CodingKey { case addons }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addons = container.stremioList(.addons)
    }
}

// MARK: - Manifest

nonisolated struct StremioManifest: Decodable, Sendable {
    struct Resource: Sendable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
    }

    struct ExtraProp: Decodable, Sendable {
        let name: String
        let isRequired: Bool
        let options: [String]

        enum CodingKeys: String, CodingKey { case name, isRequired, options }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            isRequired = (try? container.decodeIfPresent(Bool.self, forKey: .isRequired)) ?? false
            options = ((try? container.decodeIfPresent([String].self, forKey: .options)) ?? nil) ?? []
        }
        init(name: String, isRequired: Bool) {
            self.name = name
            self.isRequired = isRequired
            self.options = []
        }
    }

    struct Catalog: Decodable, Sendable {
        let id: String
        let type: String
        let name: String?
        let extra: [ExtraProp]

        /// A catalog that can be listed with no extra (not search-only or genre-only).
        var isBrowsable: Bool { !extra.contains { $0.isRequired } }
        var supportsSearch: Bool { extra.contains { $0.name == "search" } }
        var supportsSkip: Bool { extra.contains { $0.name == "skip" } }

        enum CodingKeys: String, CodingKey { case id, type, name, extra, extraRequired, extraSupported }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
            // The current form lists props; the legacy one names them in two string lists.
            let props: [ExtraProp] = container.stremioList(.extra)
            if !props.isEmpty {
                extra = props
            } else {
                let required = ((try? container.decodeIfPresent([String].self, forKey: .extraRequired)) ?? nil) ?? []
                let supported = ((try? container.decodeIfPresent([String].self, forKey: .extraSupported)) ?? nil) ?? []
                extra = Array(Set(supported + required)).map { ExtraProp(name: $0, isRequired: required.contains($0)) }
            }
        }
    }

    let id: String
    let name: String
    let types: [String]
    let idPrefixes: [String]?
    let resources: [Resource]
    let catalogs: [Catalog]

    enum CodingKeys: String, CodingKey { case id, name, types, idPrefixes, resources, catalogs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? id
        types = ((try? container.decodeIfPresent([String].self, forKey: .types)) ?? nil) ?? []
        idPrefixes = (try? container.decodeIfPresent([String].self, forKey: .idPrefixes)) ?? nil
        catalogs = container.stremioList(.catalogs)
        var resources: [Resource] = []
        if var list = try? container.nestedUnkeyedContainer(forKey: .resources) {
            while !list.isAtEnd {
                if let name = try? list.decode(String.self) {
                    resources.append(Resource(name: name, types: nil, idPrefixes: nil))
                } else if let full = try? list.decode(FullResource.self) {
                    resources.append(Resource(name: full.name, types: full.types, idPrefixes: full.idPrefixes))
                } else {
                    _ = try? list.decode(StremioSkip.self)
                }
            }
        }
        self.resources = resources
    }

    private struct FullResource: Decodable, Sendable {
        let name: String
        let types: [String]?
        let idPrefixes: [String]?
    }

    /// Whether the addon answers `resource` for this type and id, as stremio-core decides it:
    /// the resource's own types and prefixes, else the manifest's.
    func supports(_ resource: String, type: String, id: String) -> Bool {
        guard let entry = resources.first(where: { $0.name == resource }) else { return false }
        let types = entry.types ?? self.types
        guard types.contains(type) else { return false }
        guard let prefixes = entry.idPrefixes ?? idPrefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }
}

// MARK: - Catalog and meta

nonisolated struct StremioMetaPreview: Decodable, Sendable {
    let id: String
    let type: String
    let name: String
    let poster: URL?
    let background: URL?
    let logo: URL?
    let description: String?
    let releaseInfo: String?
    let runtime: String?
    let imdbRating: String?
    let genres: [String]
    let posterShape: String?

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description, releaseInfo, runtime, imdbRating, genres, posterShape
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? nil ?? "movie"
        name = container.stremioText(.name) ?? id
        poster = container.stremioURL(.poster)
        background = container.stremioURL(.background)
        logo = container.stremioURL(.logo)
        description = container.stremioText(.description)
        releaseInfo = container.stremioText(.releaseInfo)
        runtime = container.stremioText(.runtime)
        imdbRating = container.stremioText(.imdbRating)
        genres = ((try? container.decodeIfPresent([String].self, forKey: .genres)) ?? nil) ?? []
        posterShape = (try? container.decodeIfPresent(String.self, forKey: .posterShape)) ?? nil
    }

    /// The first year in "2019", "2008–2013" or "2021-".
    var year: Int? { releaseInfo.flatMap { Int($0.prefix(4)) } }

    /// "120 min", "2h 10min", "45m" → seconds.
    var runtimeSeconds: TimeInterval? {
        guard let runtime else { return nil }
        let digits = runtime.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let lower = runtime.lowercased()
        if lower.contains("h"), digits.count >= 2 { return TimeInterval(digits[0] * 3600 + digits[1] * 60) }
        if lower.contains("h"), let hours = digits.first { return TimeInterval(hours * 3600) }
        return digits.first.map { TimeInterval($0 * 60) }
    }
}

nonisolated struct StremioVideo: Decodable, Sendable {
    let id: String
    let title: String
    let released: String?
    let overview: String?
    let thumbnail: URL?
    let season: Int?
    let episode: Int?

    enum CodingKeys: String, CodingKey { case id, title, name, released, overview, description, thumbnail, season, episode, number }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = container.stremioText(.title) ?? container.stremioText(.name) ?? ""
        released = container.stremioText(.released)
        overview = container.stremioText(.overview) ?? container.stremioText(.description)
        thumbnail = container.stremioURL(.thumbnail)
        season = container.stremioText(.season).flatMap { Int($0) }
        episode = (container.stremioText(.episode) ?? container.stremioText(.number)).flatMap { Int($0) }
    }
}

nonisolated struct StremioMeta: Decodable, Sendable {
    let preview: StremioMetaPreview
    let videos: [StremioVideo]
    let cast: [String]
    let directors: [String]
    let writers: [String]
    let defaultVideoID: String?
    let trailerYouTubeID: String?

    enum CodingKeys: String, CodingKey { case videos, cast, director, writer, behaviorHints, trailerStreams, trailers }
    private struct Hints: Decodable, Sendable { let defaultVideoId: String? }
    private struct Trailer: Decodable, Sendable { let ytId: String?; let source: String? }

    init(from decoder: Decoder) throws {
        preview = try StremioMetaPreview(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videos = container.stremioList(.videos)
        cast = ((try? container.decodeIfPresent([String].self, forKey: .cast)) ?? nil) ?? []
        directors = ((try? container.decodeIfPresent([String].self, forKey: .director)) ?? nil) ?? []
        writers = ((try? container.decodeIfPresent([String].self, forKey: .writer)) ?? nil) ?? []
        defaultVideoID = ((try? container.decodeIfPresent(Hints.self, forKey: .behaviorHints)) ?? nil)?.defaultVideoId
        let streams: [Trailer] = container.stremioList(.trailerStreams)
        let legacy: [Trailer] = container.stremioList(.trailers)
        trailerYouTubeID = (streams + legacy).lazy.compactMap { $0.ytId ?? $0.source }.first
    }
}

nonisolated struct StremioCatalogResponse: Decodable, Sendable {
    let metas: [StremioMetaPreview]
    enum CodingKeys: String, CodingKey { case metas }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metas = container.stremioList(.metas)
    }
}

nonisolated struct StremioMetaResponse: Decodable, Sendable {
    let meta: StremioMeta?
}

// MARK: - Streams and subtitles

nonisolated struct StremioSubtitle: Decodable, Sendable {
    let id: String?
    let url: URL
    let lang: String?

    enum CodingKeys: String, CodingKey { case id, url, lang }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = container.stremioURL(.url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "No subtitle URL")
        }
        self.url = url
        id = container.stremioText(.id)
        lang = container.stremioText(.lang)
    }
}

nonisolated struct StremioStream: Decodable, Sendable {
    let url: URL?
    let infoHash: String?
    let name: String?
    /// `description`, or the legacy `title`.
    let description: String?
    let filename: String?
    let videoSize: Int64?
    let bingeGroup: String?
    let requestHeaders: [String: String]
    let subtitles: [StremioSubtitle]

    enum CodingKeys: String, CodingKey { case url, infoHash, name, description, title, behaviorHints, subtitles }
    private struct ProxyHeaders: Decodable, Sendable { let request: [String: String]? }
    private struct Hints: Decodable, Sendable {
        let filename: String?
        let videoSize: Int64?
        let bingeGroup: String?
        let proxyHeaders: ProxyHeaders?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.stremioURL(.url)
        infoHash = container.stremioText(.infoHash)
        name = container.stremioText(.name)
        description = container.stremioText(.description) ?? container.stremioText(.title)
        let hints = (try? container.decodeIfPresent(Hints.self, forKey: .behaviorHints)) ?? nil
        filename = hints?.filename
        videoSize = hints?.videoSize
        bingeGroup = hints?.bingeGroup
        requestHeaders = hints?.proxyHeaders?.request ?? [:]
        subtitles = container.stremioList(.subtitles)
    }
}

nonisolated struct StremioStreamResponse: Decodable, Sendable {
    let streams: [StremioStream]
    enum CodingKeys: String, CodingKey { case streams }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = container.stremioList(.streams)
    }
}

nonisolated struct StremioSubtitlesResponse: Decodable, Sendable {
    let subtitles: [StremioSubtitle]
    enum CodingKeys: String, CodingKey { case subtitles }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subtitles = container.stremioList(.subtitles)
    }
}
