// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioPlayFlow.swift
//  Rivulet
//
//  Play on a Stremio title: the stream picker goes up at once (so there is no dead
//  time to press other things in), the streams fill it as the addons answer, and
//  the pick starts the player on top of it. Closing the player closes the picker
//  too; a stream that fails to start leaves the list up to pick another.
//

import UIKit

@MainActor
enum StremioPlayFlow {

    static func play(_ item: MediaItem, provider: StremioProvider, fromBeginning: Bool, sourceID: String?,
                     explicitStartOffset: TimeInterval?, configure: ((UniversalPlayerViewModel) -> Void)?,
                     from presenter: UIViewController, onDismiss: (() -> Void)?,
                     onFailedToStart: (() -> Void)?) {
        let picker = StremioStreamPickerViewController(
            title: item.seriesTitle ?? item.title, subtitle: episodeLine(item),
            backdropURL: item.grandparentArtwork?.backdrop ?? item.artwork.backdrop ?? item.artwork.poster)
        let close: (UIViewController) -> Void = { picker in
            if let presenting = picker.presentingViewController { presenting.dismiss(animated: true) }
        }
        picker.onCancel = { [weak picker] in
            if let picker { close(picker) }
            onFailedToStart?()
        }
        presenter.topmostPresented.present(picker, animated: true)

        Task { @MainActor in
            var target = item
            var startOffset = explicitStartOffset
            if item.kind == .show || item.kind == .season {
                target = await EpisodePicker.resolvePlayTarget(for: item, provider: provider) ?? item
                startOffset = nil  // an offset names a time in one title, not in a show
                picker.setTitle(target.seriesTitle ?? target.title, subtitle: episodeLine(target))
            }
            guard let ref = StremioRef(target.ref.itemID), ref.kind == .movie || ref.kind == .episode else {
                picker.setOptions([], preselect: nil)
                return
            }
            let playTarget = target
            let playOffset = startOffset

            picker.onSelect = { [weak picker] option in
                guard let picker else { return }
                picker.showStarting()
                provider.markExplicitPick(option.id)
                Task { @MainActor in
                    do {
                        let playback = try await ProviderPlayback.prepare(
                            item: playTarget, provider: provider, version: .source(option.id),
                            fromBeginning: fromBeginning, explicitStartOffset: playOffset, awaitingExtras: false)
                        let (art, thumb) = await HeroBackdropResolver.shared.playerLoadingImages(
                            for: playTarget.heroBackdropRequest())
                        let viewModel = UniversalPlayerViewModel(
                            providerPlayback: playback,
                            startOffset: playOffset ?? ProviderPlayer.startOffset(
                                detailOffset: playback.detail.item.userState.viewOffset, fromBeginning: fromBeginning),
                            loadingArtImage: art, loadingThumbImage: thumb, preferredMediaID: option.id)
                        configure?(viewModel)
                        PlayerPresenter.present(viewModel: viewModel, from: picker) { [weak picker] in
                            if let picker { close(picker) }
                            onDismiss?()
                        }
                    } catch {
                        picker.showFailure(ProviderPlayer.errorMessage(for: error))
                    }
                }
            }

            // After onSelect is set: a stream can be picked before the slowest addon has answered.
            // Each addon's streams show as soon as it answers; the slowest no longer holds up the rest.
            let options = (try? await provider.streamOptions(
                type: ref.type, id: ref.streamID, runtime: target.runtime,
                onUpdate: { [weak picker] sofar in picker?.setOptions(sofar, preselect: sourceID, isLoading: true) })) ?? []
            picker.setOptions(options, preselect: sourceID, isLoading: false)
        }
    }

    /// "S1, E2 · Episode Name" for an episode.
    private static func episodeLine(_ item: MediaItem) -> String? {
        guard item.kind == .episode, let season = item.seasonNumber, let episode = item.episodeNumber else { return nil }
        let numbers = String(localized: "S\(season), E\(episode)")
        return item.title.isEmpty ? numbers : "\(numbers) · \(item.title)"
    }
}
