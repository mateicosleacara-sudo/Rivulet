// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioStreamPickerViewController.swift
//  Rivulet
//
//  Stremio's stream list, on screen the moment Play is pressed: the addons on the
//  left (All, Torrentio, Comet…), each stream on the right with the addon's own
//  label and description as it wrote them (file name, size, DV/HDR, audio). It
//  covers the screen while streams load and while the picked one starts, so
//  nothing behind it can be pressed in the meantime. Menu backs out.
//

import UIKit

@MainActor
final class StremioStreamPickerViewController: UIViewController {

    var onSelect: ((StremioStreamOption) -> Void)?
    var onCancel: (() -> Void)?

    private var options: [StremioStreamOption] = []
    private var addons: [(name: String, count: Int)] = []
    private var selectedAddon: String?          // nil is All
    private var isStarting = false
    private var preselectedID: String?

    private let backdrop = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let addonTable = UITableView(frame: .zero, style: .plain)
    private let streamTable = UITableView(frame: .zero, style: .plain)
    private let statusStack = UIStackView()
    private let statusSpinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let cancelButton = UIButton(configuration: .glass())

    init(title: String, subtitle: String?, backdropURL: URL?) {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
        titleLabel.text = title
        subtitleLabel.text = subtitle
        if let backdropURL {
            Task { [weak self] in
                let image = await ImageCacheManager.shared.imageFullSize(for: backdropURL)
                self?.backdrop.image = image
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)
        let dim = UIView(frame: view.bounds)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(dim)

        titleLabel.font = .systemFont(ofSize: 46, weight: .bold)
        titleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 28, weight: .medium)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.isHidden = subtitleLabel.text?.isEmpty ?? true

        for table in [addonTable, streamTable] {
            table.backgroundColor = .clear
            table.rowHeight = UITableView.automaticDimension
            table.estimatedRowHeight = 120
            table.remembersLastFocusedIndexPath = true
            table.dataSource = self
            table.delegate = self
            table.translatesAutoresizingMaskIntoConstraints = false
            table.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 60, right: 0)
            view.addSubview(table)
        }
        addonTable.register(StremioAddonCell.self, forCellReuseIdentifier: StremioAddonCell.id)
        streamTable.register(StremioStreamCell.self, forCellReuseIdentifier: StremioStreamCell.id)

        statusSpinner.color = .white
        statusLabel.font = .systemFont(ofSize: 30, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 24
        statusStack.addArrangedSubview(statusSpinner)
        statusStack.addArrangedSubview(statusLabel)
        cancelButton.configuration?.title = String(localized: "Cancel")
        cancelButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.isStarting else { return }
            self.onCancel?()
        }, for: .primaryActionTriggered)
        statusStack.setCustomSpacing(40, after: statusLabel)
        statusStack.addArrangedSubview(cancelButton)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusStack)

        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        header.axis = .vertical
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 70),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 90),
            header.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -90),

            addonTable.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 36),
            addonTable.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 70),
            addonTable.widthAnchor.constraint(equalToConstant: 430),
            addonTable.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            streamTable.topAnchor.constraint(equalTo: addonTable.topAnchor),
            streamTable.leadingAnchor.constraint(equalTo: addonTable.trailingAnchor, constant: 40),
            streamTable.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -70),
            streamTable.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 1000),
        ])
        showStatus(String(localized: "Finding streams…"), spinning: true)
    }

    // MARK: - State

    func setTitle(_ title: String, subtitle: String?) {
        loadViewIfNeeded()
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
    }

    /// The addons' answers, in their order. `preselect` is the version the detail page picked.
    func setOptions(_ options: [StremioStreamOption], preselect: String?) {
        loadViewIfNeeded()
        self.options = options
        preselectedID = preselect
        var counts: [String: Int] = [:]
        var order: [String] = []
        for option in options {
            if counts[option.addonName] == nil { order.append(option.addonName) }
            counts[option.addonName, default: 0] += 1
        }
        addons = [(String(localized: "All"), options.count)] + order.map { ($0, counts[$0] ?? 0) }
        addonTable.reloadData()
        streamTable.reloadData()
        if options.isEmpty {
            showStatus(String(localized: "No streams found. Your addons have nothing playable for this title yet."), spinning: false)
        } else {
            hideStatus()
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// The picked stream is starting: hold every press until the player is up.
    func showStarting() {
        isStarting = true
        showStatus(String(localized: "Starting…"), spinning: true)
        setNeedsFocusUpdate()
    }

    /// The picked stream did not start; the list comes back to pick another.
    func showFailure(_ message: String) {
        isStarting = false
        hideStatus()
        let popup = ConfirmationPopupViewController(title: String(localized: "Couldn't Play"), message: message,
                                                    confirmTitle: String(localized: "OK"), cancelTitle: nil, onConfirm: {})
        present(popup, animated: true)
    }

    private var visibleOptions: [StremioStreamOption] {
        guard let selectedAddon else { return options }
        return options.filter { $0.addonName == selectedAddon }
    }

    private func showStatus(_ text: String, spinning: Bool) {
        statusLabel.text = text
        spinning ? statusSpinner.startAnimating() : statusSpinner.stopAnimating()
        statusStack.isHidden = false
        // Something to focus while loading, so Menu and Select reach this screen.
        cancelButton.isHidden = isStarting
        // A list under the status would still take focus (and the geometric focus test needs it hidden).
        addonTable.isHidden = spinning || options.isEmpty
        streamTable.isHidden = spinning || options.isEmpty
    }

    private func hideStatus() {
        statusStack.isHidden = true
        cancelButton.isHidden = true
        statusSpinner.stopAnimating()
        addonTable.isHidden = false
        streamTable.isHidden = false
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        streamTable.isHidden ? [cancelButton] : [streamTable]
    }

    // MARK: - Menu

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presentedViewController == nil else { return super.pressesBegan(presses, with: event) }
        if isStarting { return }
        if presses.contains(where: { $0.type == .menu }) {
            onCancel?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

extension StremioStreamPickerViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableView === addonTable ? addons.count : visibleOptions.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView === addonTable {
            let cell = tableView.dequeueReusableCell(withIdentifier: StremioAddonCell.id, for: indexPath) as! StremioAddonCell
            let addon = addons[indexPath.row]
            let isSelected = indexPath.row == 0 ? selectedAddon == nil : selectedAddon == addon.name
            cell.configure(name: addon.name, count: addon.count, isSelected: isSelected)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: StremioStreamCell.id, for: indexPath) as! StremioStreamCell
        cell.configure(visibleOptions[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !isStarting else { return }
        if tableView === addonTable {
            selectedAddon = indexPath.row == 0 ? nil : addons[indexPath.row].name
            addonTable.reloadData()
            streamTable.reloadData()
            streamTable.setContentOffset(CGPoint(x: 0, y: -streamTable.contentInset.top), animated: false)
            return
        }
        onSelect?(visibleOptions[indexPath.row])
    }

    func indexPathForPreferredFocusedView(in tableView: UITableView) -> IndexPath? {
        guard tableView === streamTable, !visibleOptions.isEmpty else { return nil }
        let row = preselectedID.flatMap { id in visibleOptions.firstIndex { $0.id == id } } ?? 0
        return IndexPath(row: row, section: 0)
    }
}

// MARK: - Cells

/// The glass row the Settings lists use: dim at rest, brighter and slightly larger in focus.
@MainActor
private class StremioGlassCell: UITableViewCell {
    let platter = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        focusStyle = .custom
        selectionStyle = .none
        platter.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        platter.layer.cornerRadius = 18
        platter.layer.cornerCurve = .continuous
        platter.layer.borderWidth = 1
        platter.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        platter.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(platter)
        NSLayoutConstraint.activate([
            platter.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            platter.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            platter.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            platter.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { [self] in
            platter.backgroundColor = UIColor.white.withAlphaComponent(isFocused ? 0.22 : 0.08)
            platter.layer.borderColor = UIColor.white.withAlphaComponent(isFocused ? 0.3 : 0.08).cgColor
            transform = isFocused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }
    }
}

@MainActor
private final class StremioAddonCell: StremioGlassCell {
    static let id = "addon"
    private let nameLabel = UILabel()
    private let countLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        nameLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 2
        countLabel.font = .systemFont(ofSize: 24, weight: .medium)
        countLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [nameLabel, countLabel])
        row.spacing = 16
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        platter.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: platter.topAnchor, constant: 20),
            row.bottomAnchor.constraint(equalTo: platter.bottomAnchor, constant: -20),
            row.leadingAnchor.constraint(equalTo: platter.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: platter.trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, count: Int, isSelected: Bool) {
        nameLabel.text = name
        countLabel.text = "\(count)"
        platter.layer.borderColor = UIColor.white.withAlphaComponent(isSelected ? 0.6 : 0.08).cgColor
        nameLabel.textColor = isSelected ? .white : UIColor.white.withAlphaComponent(0.75)
    }
}

@MainActor
private final class StremioStreamCell: StremioGlassCell {
    static let id = "stream"
    private let nameLabel = UILabel()
    private let descriptionLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        nameLabel.font = .systemFont(ofSize: 26, weight: .bold)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 0
        descriptionLabel.font = .systemFont(ofSize: 24, weight: .regular)
        descriptionLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        descriptionLabel.numberOfLines = 0
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        platter.addSubview(nameLabel)
        platter.addSubview(descriptionLabel)
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: platter.topAnchor, constant: 22),
            nameLabel.leadingAnchor.constraint(equalTo: platter.leadingAnchor, constant: 26),
            nameLabel.widthAnchor.constraint(equalToConstant: 250),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: platter.bottomAnchor, constant: -22),
            descriptionLabel.topAnchor.constraint(equalTo: platter.topAnchor, constant: 22),
            descriptionLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 28),
            descriptionLabel.trailingAnchor.constraint(equalTo: platter.trailingAnchor, constant: -26),
            descriptionLabel.bottomAnchor.constraint(equalTo: platter.bottomAnchor, constant: -22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The addon's own words: its label on the left, its description (file, size, quality) on the right.
    func configure(_ option: StremioStreamOption) {
        nameLabel.text = option.stream.name ?? option.addonName
        descriptionLabel.text = option.stream.description ?? option.stream.filename ?? option.source.fileName ?? ""
        contentView.alpha = option.isUncached ? 0.55 : 1
    }
}
