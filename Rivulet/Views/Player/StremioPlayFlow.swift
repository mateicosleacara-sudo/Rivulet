// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioPlayFlow.swift
//  Rivulet
//
//  Play on a Stremio title starts the recommended stream (`StremioRecommendation`: the
//  one last played for the title, else the best cached link) behind a short "Finding the
//  best stream…" screen with Choose Stream and Cancel. Holding Play opens the picker
//  instead (`choosePickerOnce`): the streams fill it as the addons answer, and the pick
//  starts the player on top of it. Closing the player closes the picker too; a stream
//  that fails to start leaves the list up to pick another.
//

import UIKit

@MainActor
enum StremioPlayFlow {

    /// Set by a held Play just before it plays: the next Play opens the stream list.
    static var choosePickerOnce = false
    /// How long quick start waits for slow addons once a cached stream is in hand.
    private static let quickStartGrace: Duration = .seconds(4)

    static func play(_ item: MediaItem, provider: StremioProvider, fromBeginning: Bool, sourceID: String?,
                     explicitStartOffset: TimeInterval?, configure: ((UniversalPlayerViewModel) -> Void)?,
                     from presenter: UIViewController, onDismiss: (() -> Void)?,
                     onFailedToStart: (() -> Void)?) {
        let choose = choosePickerOnce
        choosePickerOnce = false
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
        if !choose { picker.beginQuickStart() }
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
                picker.showList()
                picker.setOptions([], preselect: nil)
                return
            }
            let remembered = StremioStreamMemory.choice(for: ref.metaID)
            picker.recommend = { StremioRecommendation.recommended($0, remembered: remembered) }
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

            // Quick start: once every addon has answered, or a little after the first cached stream
            // when the remembered one isn't among them yet, start the recommendation.
            let grace = GraceBox()
            let startRecommended: @MainActor () -> Void = { [weak picker] in
                grace.task?.cancel()
                guard let picker, picker.isQuickStart else { return }
                guard let option = picker.recommendation else { picker.showList(); return }
                picker.onSelect?(option)
            }

            // After onSelect is set: a stream can be picked before the slowest addon has answered.
            // Each addon's streams show as soon as it answers; the slowest no longer holds up the rest.
            let options = (try? await provider.streamOptions(
                type: ref.type, id: ref.streamID, runtime: target.runtime,
                onUpdate: { [weak picker] sofar in
                    guard let picker else { return }
                    picker.setOptions(sofar, preselect: sourceID, isLoading: true)
                    guard picker.isQuickStart, let best = picker.recommendation, !best.isUncached else { return }
                    if let remembered, best.id == remembered.streamID {
                        startRecommended()  // the stream played last time: nothing better is coming
                    } else if grace.task == nil {
                        grace.task = Task { @MainActor in
                            try? await Task.sleep(for: quickStartGrace)
                            if !Task.isCancelled { startRecommended() }
                        }
                    }
                })) ?? []
            picker.setOptions(options, preselect: sourceID, isLoading: false)
            startRecommended()
        }
    }

    /// "S1, E2 · Episode Name" for an episode.
    private static func episodeLine(_ item: MediaItem) -> String? {
        guard item.kind == .episode, let season = item.seasonNumber, let episode = item.episodeNumber else { return nil }
        let numbers = String(localized: "S\(season), E\(episode)")
        return item.title.isEmpty ? numbers : "\(numbers) · \(item.title)"
    }
}

/// Quick start's pending grace timer, shared by the update callback and the final answer.
@MainActor
private final class GraceBox {
    var task: Task<Void, Never>?
}
