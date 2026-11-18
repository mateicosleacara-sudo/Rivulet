// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  ExternalStreamLink.swift
//  Rivulet
//
//  A stream another app hands over in Infuse's x-callback-url format, so an app
//  that offers "Infuse" as its external player (Stremio) can play in Rivulet:
//
//      infuse://x-callback-url/play?url=<percent-encoded stream URL>
//      rivulet://x-callback-url/play?url=...
//
//  Optional: filename, sub / subtitle (repeatable), x-success, x-error.
//  `rivulet://play?ratingKey=` and `rivulet://detail` stay `RivuletLink`'s.
//

import Foundation

nonisolated struct ExternalStreamLink: Equatable, Sendable {
    static let schemes: Set<String> = ["infuse", "rivulet"]

    let streamURL: URL
    let filename: String?
    let subtitleURLs: [URL]
    let successURL: URL?
    let errorURL: URL?

    /// True for any link in the x-callback-url family, playable or not: these are what the
    /// debug view records, so a link Rivulet could not read can still be inspected.
    static func isCandidate(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return false }
        let host = url.host?.lowercased()
        return scheme == "infuse" || host == "x-callback-url"
    }

    init?(url: URL) {
        guard Self.isCandidate(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // x-callback-url/play, and the bare play form a few senders use (infuse://play?url=).
        let host = url.host?.lowercased() ?? ""
        let path = components.path.lowercased()
        let isPlay = (host == "x-callback-url" && (path == "/play" || path == "/play/" || path.isEmpty))
            || host == "play"
        guard isPlay else { return nil }

        let items = components.queryItems ?? []
        func values(_ names: String...) -> [String] {
            items.filter { names.contains($0.name.lowercased()) }.compactMap(\.value).filter { !$0.isEmpty }
        }
        guard let rawStream = values("url").first, let stream = Self.httpURL(rawStream) else { return nil }
        streamURL = stream
        filename = values("filename", "name", "title").first.map(Self.decodedOnce)
        subtitleURLs = values("sub", "subtitle", "subtitles", "sub_url").compactMap(Self.httpURL)
        successURL = values("x-success").first.flatMap { URL(string: Self.decodedOnce($0)) }
        errorURL = values("x-error").first.flatMap { URL(string: Self.decodedOnce($0)) }
    }

    /// An http(s) URL from a query value. URLComponents has already decoded the value once;
    /// a sender that encoded twice leaves "https%3A%2F%2F…", which takes one more pass.
    static func httpURL(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = decodedOnce(text)
        }
        guard let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func decodedOnce(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// The title shown in the player: the sender's file name, else the URL's last path
    /// component, without a video file extension.
    var displayTitle: String {
        let candidates = [filename, streamURL.lastPathComponent.removingPercentEncoding, streamURL.host]
        let name = candidates.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "/" } ?? "Stream"
        return Self.strippingVideoExtension(name)
    }

    static func strippingVideoExtension(_ name: String) -> String {
        let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "webm", "wmv", "mpg", "mpeg", "flv"]
        let ext = (name as NSString).pathExtension.lowercased()
        guard videoExtensions.contains(ext) else { return name }
        return (name as NSString).deletingPathExtension
    }

    /// What identifies the title across sends, for the resume point. A debrid link can
    /// change between sends while the file name stays; without one, the URL minus its query.
    var resumeIdentity: String {
        if let filename, !filename.isEmpty { return "name:" + filename.lowercased() }
        var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return "url:" + (components?.string ?? streamURL.absoluteString)
    }
}
