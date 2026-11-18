// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioStreams.swift
//  Rivulet
//
//  An addon stream as a version in the version picker. Addons describe a stream
//  only in free text ("Torrentio\n4k DV" over "Movie.2160p.REMUX…\n💾 61.2 GB"),
//  so resolution, range, codec, audio and size are read from that text, which is
//  what the picker's badges and `VersionRanking` (resolution, range, bitrate) use.
//  Only streams with an http(s) URL play here: a torrent (infoHash only) needs a
//  torrent engine. A debrid link not cached yet is hidden while any cached one
//  exists in the detail page's versions, since it cannot start playing; the stream
//  picker lists everything, as Stremio does.
//

import CryptoKit
import Foundation

nonisolated struct StremioStreamOption: Sendable {
    let id: String
    let stream: StremioStream
    let url: URL
    let addonName: String
    let source: MediaSource
    let isUncached: Bool
}

nonisolated enum StremioStreamParser {

    static func options(from streams: [(addon: String, stream: StremioStream)], runtime: TimeInterval?) -> [StremioStreamOption] {
        var seen = Set<String>()
        let all: [StremioStreamOption] = streams.compactMap { addon, stream in
            guard let url = stream.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return nil
            }
            let id = streamID(url)
            guard seen.insert(id).inserted else { return nil }
            let text = [stream.name, stream.description, stream.filename].compactMap { $0 }.joined(separator: "\n")
            return StremioStreamOption(id: id, stream: stream, url: url, addonName: addon,
                                       source: source(id: id, stream: stream, url: url, text: text, runtime: runtime),
                                       isUncached: isUncached(text))
        }
        return all
    }

    /// The detail page's versions: the cached links when there are any (an uncached one can't start).
    static func playable(_ options: [StremioStreamOption]) -> [StremioStreamOption] {
        let cached = options.filter { !$0.isUncached }
        return cached.isEmpty ? options : cached
    }

    /// Stable across fetches, so a version picked on the detail page is the one that plays.
    static func streamID(_ url: URL) -> String {
        "s" + SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Debrid addons mark a link their service has not cached: Torrentio "[RD download]",
    /// Comet/MediaFusion/AIOStreams "⬇️" or "⏳", others "uncached".
    static func isUncached(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains(" download]") || lower.contains("uncached") || text.contains("⏳") || text.contains("⬇️")
    }

    static func source(id: String, stream: StremioStream, url: URL, text: String, runtime: TimeInterval?) -> MediaSource {
        let lower = " " + text.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        let tokens = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "-" && $0 != "." })
            .map(String.init))

        var resolution: (label: String, height: Int)?
        if tokens.contains("2160p") || tokens.contains("4k") || tokens.contains("uhd") {
            resolution = ("4k", 2160)
        } else if tokens.contains("1080p") || tokens.contains("1080i") {
            resolution = ("1080", 1080)
        } else if tokens.contains("720p") {
            resolution = ("720", 720)
        } else if tokens.contains("576p") {
            resolution = ("576", 576)
        } else if tokens.contains("480p") || tokens.contains("sd") {
            resolution = ("480", 480)
        }

        let range: VideoTrack.VideoRange
        let hasDV = !tokens.isDisjoint(with: ["dv", "dovi"]) || lower.contains("dolby vision") || lower.contains("dolbyvision")
        let hasHDR10Plus = lower.contains("hdr10+") || lower.contains("hdr10plus")
        if hasDV { range = .dolbyVision(profile: lower.contains("fel") || lower.contains("p7") ? 7 : 8) }
        else if hasHDR10Plus { range = .hdr10Plus }
        else if tokens.contains("hdr") || tokens.contains("hdr10") { range = .hdr10 }
        else if tokens.contains("hlg") { range = .hlg }
        else { range = .sdr }

        var codec = ""
        if tokens.contains("av1") {
            codec = "av1"
        } else if !tokens.isDisjoint(with: ["hevc", "x265", "h265", "h.265"]) {
            codec = "hevc"
        } else if !tokens.isDisjoint(with: ["x264", "h264", "h.264", "avc"]) {
            codec = "h264"
        }

        let video = VideoTrack(id: "\(id)-v", codec: codec, profile: nil, level: nil, width: nil,
                               height: resolution?.height, frameRate: nil, bitrate: nil, videoRange: range,
                               isDefault: true, scanType: nil, hasHDR10Plus: hasDV && hasHDR10Plus)
        let size = stream.videoSize ?? parseSize(text)
        let bitrate = size.flatMap { bytes in runtime.flatMap { $0 > 0 ? Int(Double(bytes) * 8 / $0) : nil } }
        let fileName = stream.filename ?? fileNameLine(text)
        let ext = fileName.map { ($0 as NSString).pathExtension.lowercased() }

        return MediaSource(
            id: id,
            container: ext?.isEmpty == false ? ext : nil,
            duration: runtime ?? 0,
            bitrate: bitrate,
            fileSize: size,
            fileName: fileName,
            versionName: versionName(stream: stream, fileName: fileName),
            videoResolution: resolution?.label,
            videoTracks: [video],
            audioTracks: audio(tokens: tokens, lower: lower, id: id).map { [$0] } ?? [],
            subtitleTracks: [],
            streamKind: .directPlay,
            streamURL: url
        )
    }

    private static func audio(tokens: Set<String>, lower: String, id: String) -> AudioTrack? {
        let atmos = tokens.contains("atmos")
        var codec: String?
        var profile: String?
        if tokens.contains("truehd") { codec = "truehd" }
        else if lower.contains("dts:x") || tokens.contains("dtsx") || tokens.contains("dts-x") { codec = "dts"; profile = "x" }
        else if lower.contains("dts-hd") || lower.contains("dts hd") || tokens.contains("dts-hdma") { codec = "dts"; profile = "ma" }
        else if tokens.contains("dts") { codec = "dts" }
        else if tokens.contains("ddp") || tokens.contains("dd+") || tokens.contains("eac3") || tokens.contains("e-ac3")
                    || tokens.contains("ddp5.1") || tokens.contains("ddp7.1") { codec = "eac3" }
        else if tokens.contains("ac3") || tokens.contains("dd") || tokens.contains("dd5.1") { codec = "ac3" }
        else if tokens.contains("flac") { codec = "flac" }
        else if tokens.contains("aac") { codec = "aac" }
        else if tokens.contains("opus") { codec = "opus" }
        guard let codec else { return nil }
        if atmos { profile = (profile.map { $0 + " " } ?? "") + "atmos" }
        var channels: Int?
        if lower.contains("7.1") { channels = 8 } else if lower.contains("5.1") { channels = 6 } else if lower.contains("2.0") { channels = 2 }
        return AudioTrack(id: "\(id)-a", index: 1, codec: codec, profile: profile, channels: channels, channelLayout: nil,
                          language: nil, title: nil, extendedTitle: nil, bitrate: nil, samplingRate: nil,
                          isDefault: true, isForced: false, isSelected: true)
    }

    /// "💾 61.2 GB", "61.2GB", "850 MB".
    static func parseSize(_ text: String) -> Int64? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|GiB|MiB)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let number = Double(text[numberRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let unit = text[unitRange].uppercased()
        let factor: Double = unit.hasPrefix("T") ? 1_099_511_627_776 : unit.hasPrefix("G") ? 1_073_741_824 : 1_048_576
        return Int64(number * factor)
    }

    /// The line naming the file: the first that ends in a video extension.
    private static func fileNameLine(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let candidate = trimmed.split(separator: " ").last.map(String.init) ?? trimmed
            for value in [trimmed, candidate] where ExternalStreamLink.strippingVideoExtension(value) != value {
                return value.replacingOccurrences(of: "📄 ", with: "")
            }
        }
        return nil
    }

    /// "Torrentio 4k DV · Movie.2019.2160p.REMUX…": the addon's own label and the release.
    private static func versionName(stream: StremioStream, fileName: String?) -> String {
        let label = (stream.name ?? "").split(separator: "\n").joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let release = fileName.map(ExternalStreamLink.strippingVideoExtension)
            ?? stream.description?.split(separator: "\n").first.map(String.init)
        var name = [label.isEmpty ? nil : label, release].compactMap { $0 }.joined(separator: " · ")
        if name.count > 90 { name = String(name.prefix(88)) + "…" }
        return name.isEmpty ? "Stream" : name
    }
}
