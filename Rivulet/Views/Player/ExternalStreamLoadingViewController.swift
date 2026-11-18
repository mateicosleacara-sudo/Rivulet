// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  ExternalStreamLoadingViewController.swift
//  Rivulet
//
//  Covers the screen the moment another app (Stremio) hands over a stream, while
//  its redirects and title are looked up, so Home's placeholder never shows in
//  between. The player presents on top of it; it leaves with the player.
//

import UIKit

@MainActor
final class ExternalStreamLoadingViewController: UIViewController {

    private let backdrop = UIImageView()
    private let scrim = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        backdrop.alpha = 0
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)

        // The Home hero's scrim: constant black, so the title reads on any image.
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        scrim.frame = view.bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrim)

        spinner.color = .white
        spinner.startAnimating()

        titleLabel.font = .systemFont(ofSize: 48, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.alpha = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, spinner])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 40
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 160),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -160),
        ])
    }

    /// The title and backdrop, once the lookup has them.
    func show(title: String, backdrop image: UIImage?) {
        loadViewIfNeeded()
        titleLabel.text = title
        backdrop.image = image
        UIView.animate(withDuration: 0.4) {
            self.titleLabel.alpha = 1
            if image != nil { self.backdrop.alpha = 1 }
        }
    }

    /// Menu while loading gives up on the stream.
    var onCancel: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presentedViewController == nil else { return super.pressesBegan(presses, with: event) }
        if presses.contains(where: { $0.type == .menu }) {
            onCancel?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
