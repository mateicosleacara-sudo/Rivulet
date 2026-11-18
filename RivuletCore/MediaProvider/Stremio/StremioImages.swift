// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioImages.swift
//  Rivulet
//
//  Addons hand out their smallest artwork: Cinemeta's metahub URLs name a size
//  ("/poster/small/"), TMDB's a width ("/t/p/w342/"). On a 4K screen those are
//  blurry, so each is asked for at a size that suits where it is drawn.
//

import Foundation

nonisolated enum StremioImages {
    static func poster(_ url: URL?) -> URL? { resized(url, metahub: "large", tmdb: "w780") }
    static func backdrop(_ url: URL?) -> URL? { resized(url, metahub: "large", tmdb: "original") }
    static func logo(_ url: URL?) -> URL? { resized(url, metahub: "large", tmdb: "original") }

    private static func resized(_ url: URL?, metahub: String, tmdb: String) -> URL? {
        guard let url else { return nil }
        var text = url.absoluteString
        if text.contains("metahub.space/") {
            for size in ["/small/", "/medium/"] {
                text = text.replacingOccurrences(of: size, with: "/\(metahub)/")
            }
        } else if text.contains("image.tmdb.org/t/p/"),
                  let range = text.range(of: #"/t/p/(w\d+|original)/"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "/t/p/\(tmdb)/")
        }
        return URL(string: text) ?? url
    }
}
