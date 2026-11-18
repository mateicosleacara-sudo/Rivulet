// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  ExternalStreamHandler.swift
//  Rivulet
//
//  Plays a stream another app sends in Infuse's format (`ExternalStreamLink`),
//  e.g. Stremio with Infuse picked as its external player. Reached from the
//  scene's `.onOpenURL` through `DeepLinkHandler`, on a cold launch and while
//  running alike. A link that arrives before the app can present (launch, the
//  profile gate) is held and played once it can.
//

import Combine
import UIKit

@MainActor
final class ExternalStreamHandler {
    static let shared = ExternalStreamHandler()

    /// Settings > About > Show Received Links: each link is shown before it plays.
    static let debugKey = "externalStreamDebug"
    static let lastURLKey = "externalStreamLastURL"
    static let lastDateKey = "externalStreamLastDate"

    private var held: (url: URL, link: ExternalStreamLink?)?
    private var waiter: Task<Void, Never>?

    private init() {}

    static var isDebugEnabled: Bool { UserDefaults.standard.bool(forKey: debugKey) }
    static var lastReceived: (url: String, date: Date?)? {
        guard let url = UserDefaults.standard.string(forKey: lastURLKey) else { return nil }
        return (url, UserDefaults.standard.object(forKey: lastDateKey) as? Date)
    }

    // MARK: - Entry

    /// True when the URL is one of ours (the Infuse family), handled or not.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard ExternalStreamLink.isCandidate(url) else { return false }
        // Kept for Settings > About > Last Received Link, whatever its shape. Local only: it
        // carries the addon's debrid key, so it never goes to the log or diagnostics.
        UserDefaults.standard.set(url.absoluteString, forKey: Self.lastURLKey)
        UserDefaults.standard.set(Date(), forKey: Self.lastDateKey)
        let link = ExternalStreamLink(url: url)
        DiagLog.notice(.deepLink, "External stream link received, readable=\(link != nil)")
        held = (url, link)
        deliverHeld()
        return true
    }

    /// Called again when the shell passes the profile gate.
    func deliverHeld() {
        guard held != nil else { return }
        if let root = Self.readyRoot() {
            let (url, link) = held!
            held = nil
            waiter?.cancel()
            waiter = nil
            start(url: url, link: link, from: root)
            return
        }
        // Cold launch: the window and shell come up a moment after the URL arrives.
        guard waiter == nil else { return }
        waiter = Task { [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if Self.readyRoot() != nil {
                    self.waiter = nil
                    self.deliverHeld()
                    return
                }
            }
            self?.waiter = nil
        }
    }

    /// The window's root once content may be shown: past the profile gate, or with no Plex
    /// account (no gate; the setup screen or another server's shell is up).
    private static func readyRoot() -> UIViewController? {
        let gateOpen = DeepLinkHandler.shared.isShellReady || !PlexAuthManager.shared.hasCredentials
        guard gateOpen,
              let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive })
                  as? UIWindowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              let root = window.rootViewController, root.view.window != nil else { return nil }
        return root
    }

    // MARK: - Play

    private func start(url: URL, link: ExternalStreamLink?, from root: UIViewController) {
        guard let link else {
            // Not a play link Rivulet can read: say so, and show what arrived.
            presentNotice(title: String(localized: "Couldn't Read Link"),
                          message: Self.describe(url: url, link: nil), from: root)
            return
        }
        guard Self.isDebugEnabled else { return replaceStackAndPlay(link, from: root) }
        let popup = ConfirmationPopupViewController(
            title: String(localized: "Received Link"),
            message: Self.describe(url: url, link: link),
            confirmTitle: String(localized: "Play"),
            width: 1500,
            onConfirm: { [weak self] in self?.replaceStackAndPlay(link, from: root) })
        root.topmostPresented.present(popup, animated: true)
    }

    /// Whatever is on screen (a player, a detail page) gives way, as Infuse replaces
    /// what it was playing.
    private func replaceStackAndPlay(_ link: ExternalStreamLink, from root: UIViewController) {
        guard root.presentedViewController != nil else { return prepare(link, from: root) }
        root.dismiss(animated: false) { [weak self] in self?.prepare(link, from: root) }
    }

    private func prepare(_ link: ExternalStreamLink, from root: UIViewController) {
        guard ProviderPlayer.claimStart() else { return }
        // Up at once, so nothing behind it (Home's placeholder) shows while the stream is looked up.
        let cover = ExternalStreamLoadingViewController()
        final class Cancel { var cancelled = false }
        let cancel = Cancel()
        cover.onCancel = { [weak cover] in
            cancel.cancelled = true
            if let cover { Self.close(cover) }
        }
        root.topmostPresented.present(cover, animated: false)
        Task { @MainActor in
            defer { ProviderPlayer.finishStart() }
            let resolved = await ExternalStreamResolver.resolve(link.streamURL)
            let info = await ExternalStreamMetadata.info(link: link, resolved: resolved)
            guard !cancel.cancelled else { return }
            let provider = ExternalStreamProvider(link: link, resolved: resolved, info: info)
            DiagLog.notice(.deepLink, "External stream: matched=\(info.imdbID != nil) kind=\(info.kind.rawValue)")
            if let status = resolved.statusCode, status >= 400 {
                DiagLog.error(.deepLink, "External stream answered HTTP \(status)")
                presentNotice(title: String(localized: "Couldn't Play"),
                              message: String(localized: "The stream answered with error \(status). The link may have expired: try picking the stream again."),
                              from: cover, onDone: { Self.close(cover) })
                Self.open(link.errorURL)
                return
            }
            // The loading screen's backdrop and the Now Playing poster, as a server item has them.
            async let art = Self.image(info.backdrop, full: true)
            async let poster = Self.image(info.poster, full: false)
            let (backdrop, thumb) = await (art, poster)
            guard !cancel.cancelled else { return }
            cover.show(title: info.seriesTitle ?? info.title, backdrop: backdrop)

            let play: (TimeInterval?) -> Void = { [weak self] offset in
                let viewModel = UniversalPlayerViewModel(providerPlayback: provider.playback, startOffset: offset,
                                                         loadingArtImage: backdrop, loadingThumbImage: thumb)
                self?.present(viewModel, provider: provider, over: cover)
            }
            guard let resume = ExternalStreamResumeStore.resumePoint(for: provider.resumeKey) else { return play(nil) }
            let alert = UIAlertController(title: provider.displayTitle, message: nil, preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(
                title: String(localized: "Resume from \(PlexMetadata.formatResumeTime(Int(resume * 1000)))"),
                style: .default) { _ in play(resume) })
            alert.addAction(UIAlertAction(title: String(localized: "Start from Beginning"), style: .default) { _ in
                play(nil)
            })
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in Self.close(cover) })
            cover.present(alert, animated: true)
        }
    }

    private static func image(_ url: URL?, full: Bool) async -> UIImage? {
        guard let url else { return nil }
        if full { return await ImageCacheManager.shared.imageFullSize(for: url) }
        return await ImageCacheManager.shared.image(for: url)
    }

    /// Takes the cover down with anything still above it.
    private static func close(_ cover: UIViewController) {
        guard let presenter = cover.presentingViewController else { return }
        presenter.dismiss(animated: true)
    }

    private func present(_ viewModel: UniversalPlayerViewModel, provider: ExternalStreamProvider,
                         over cover: ExternalStreamLoadingViewController) {
        let link = provider.link
        let key = provider.resumeKey
        final class Flag { var played = false }
        let flag = Flag()
        let watch = viewModel.$playbackState.sink { state in
            if state == .playing { flag.played = true }
        }
        PlayerPresenter.present(viewModel: viewModel, from: cover) { [weak viewModel] in
            watch.cancel()
            // The length is known only once playing; keep it so the resume prompt can tell
            // a finished title (past 90%) from one stopped partway.
            if let viewModel, viewModel.duration > 0 {
                let ended = viewModel.playbackState == .ended
                    || viewModel.currentTime >= viewModel.duration * WatchProgressPolicy.completionThreshold
                if ended {
                    ExternalStreamResumeStore.clear(key)
                } else if viewModel.currentTime > 0 {
                    ExternalStreamResumeStore.save(key, position: viewModel.currentTime,
                                                   duration: viewModel.duration, title: provider.displayTitle)
                }
            }
            Self.close(cover)
            Self.open(flag.played ? link.successURL : (link.errorURL ?? link.successURL))
        }
    }

    // MARK: - Helpers

    private static func open(_ url: URL?) {
        guard let url else { return }
        UIApplication.shared.open(url)
    }

    private func presentNotice(title: String, message: String, from root: UIViewController,
                               onDone: @escaping () -> Void = {}) {
        let popup = ConfirmationPopupViewController(title: title, message: message,
                                                    confirmTitle: String(localized: "OK"), cancelTitle: nil,
                                                    width: 1500, onConfirm: onDone, onCancel: onDone)
        root.topmostPresented.present(popup, animated: true)
    }

    /// The raw link and what Rivulet read from it, for the debug popup.
    static func describe(url: URL, link: ExternalStreamLink?) -> String {
        var lines = [url.absoluteString]
        if let link {
            lines.append("")
            lines.append("Stream: \(link.streamURL.absoluteString)")
            if let filename = link.filename { lines.append("File name: \(filename)") }
            for sub in link.subtitleURLs { lines.append("Subtitle: \(sub.absoluteString)") }
            if let success = link.successURL { lines.append("x-success: \(success.absoluteString)") }
            if let error = link.errorURL { lines.append("x-error: \(error.absoluteString)") }
        } else {
            lines.append("")
            lines.append("No play url found in this link.")
        }
        return lines.joined(separator: "\n")
    }

    /// Settings > About > Last Received Link.
    static func presentLastReceived(from presenter: UIViewController) {
        guard let last = lastReceived, let url = URL(string: last.url) else { return }
        let when = last.date.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? ""
        let popup = ConfirmationPopupViewController(
            title: when.isEmpty ? String(localized: "Last Received Link") : String(localized: "Last Received Link, \(when)"),
            message: describe(url: url, link: ExternalStreamLink(url: url)),
            confirmTitle: String(localized: "OK"), cancelTitle: nil, width: 1500, onConfirm: {})
        presenter.topmostPresented.present(popup, animated: true)
    }
}
