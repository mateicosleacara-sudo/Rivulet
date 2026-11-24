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
    /// The stream Play would start (`StremioRecommendation`), shown first as Recommended.
    var recommend: (([StremioStreamOption]) -> StremioStreamOption?)?
    /// Quick start: the screen reads "Finding the best stream…" instead of showing the list,
    /// until the flow starts the recommended stream or the user asks for the list.
    private(set) var isQuickStart = false
    private var recommendedOption: StremioStreamOption?

    /// The filter row above the streams, remembered across titles.
    enum Filter: String, CaseIterable {
        case cached, uhd, dolbyVision, remux, atmos
        var title: String {
            switch self {
            case .cached: String(localized: "Cached")
            case .uhd: String(localized: "4K")
            case .dolbyVision: String(localized: "Dolby Vision")
            case .remux: String(localized: "Remux")
            case .atmos: String(localized: "Atmos")
            }
        }
        func matches(_ option: StremioStreamOption) -> Bool {
            switch self {
            case .cached: !option.isUncached
            case .uhd: StremioRecommendation.is4K(option)
            case .dolbyVision: StremioRecommendation.isDolbyVision(option)
            case .remux: StremioRecommendation.isRemux(option)
            case .atmos: StremioRecommendation.isAtmos(option)
            }
        }
    }
    private static let filtersKey = "stremioPickerFilters"
    private var activeFilters: Set<Filter> = Set(
        (UserDefaults.standard.stringArray(forKey: StremioStreamPickerViewController.filtersKey) ?? []).compactMap { Filter(rawValue: $0) })
    private let filterStack = UIStackView()
    private var filterButtons: [Filter: UIButton] = [:]
    private let emptyFilterLabel = UILabel()
    private let chooseButton = UIButton(configuration: .glass())

    private var options: [StremioStreamOption] = []
    /// The left list: addons in `addonPriority` order, then All.
    private var addons: [(name: String, count: Int, isAll: Bool)] = []
    private var selectedAddon: String?          // nil is All
    /// Until the user picks an addon, the list follows the top one as addons arrive.
    private var userChoseAddon = false
    private var isStarting = false
    private var preselectedID: String?
    private var shownStreamIDs: [String] = []
    private let moreLabel = UILabel()

    /// Comet, Torrentio and SELection first, in that order; any other addon after them in its
    /// Stremio order. Matched by name, so "Comet | ElfHosted | RD" counts as Comet.
    static func addonPriority(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("comet") { return 0 }
        if lower.contains("torrentio") { return 1 }
        if lower.contains("selection") { return 2 }
        return 3
    }

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
            // Heights are measured exactly (`heightForRowAt`): estimated multi-line rows overlapped on focus.
            table.estimatedRowHeight = 0
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
        chooseButton.configuration?.title = String(localized: "Choose Stream")
        chooseButton.isHidden = true
        chooseButton.addAction(UIAction { [weak self] _ in self?.showList() }, for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [chooseButton, cancelButton])
        buttons.spacing = 30
        statusStack.addArrangedSubview(buttons)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusStack)

        moreLabel.text = String(localized: "Loading more addons…")
        moreLabel.font = .systemFont(ofSize: 22, weight: .medium)
        moreLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        moreLabel.isHidden = true
        filterStack.axis = .horizontal
        filterStack.spacing = 20
        filterStack.translatesAutoresizingMaskIntoConstraints = false
        for filter in Filter.allCases {
            let button = UIButton(configuration: .glass())
            button.addAction(UIAction { [weak self] _ in self?.toggle(filter) }, for: .primaryActionTriggered)
            filterButtons[filter] = button
            filterStack.addArrangedSubview(button)
        }
        renderFilters()
        view.addSubview(filterStack)
        emptyFilterLabel.text = String(localized: "No streams match these filters.")
        emptyFilterLabel.font = .systemFont(ofSize: 28, weight: .medium)
        emptyFilterLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        emptyFilterLabel.isHidden = true
        emptyFilterLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyFilterLabel)

        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, moreLabel])
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

            filterStack.topAnchor.constraint(equalTo: addonTable.topAnchor, constant: 6),
            filterStack.leadingAnchor.constraint(equalTo: streamTable.leadingAnchor, constant: 8),
            streamTable.topAnchor.constraint(equalTo: filterStack.bottomAnchor, constant: 14),
            emptyFilterLabel.topAnchor.constraint(equalTo: streamTable.topAnchor, constant: 30),
            emptyFilterLabel.leadingAnchor.constraint(equalTo: streamTable.leadingAnchor, constant: 16),
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

    /// The addons' answers so far. Called again as each addon answers (`isLoading` until the last);
    /// `preselect` is the version the detail page picked.
    func setOptions(_ options: [StremioStreamOption], preselect: String?, isLoading: Bool = false) {
        loadViewIfNeeded()
        let wasEmpty = self.options.isEmpty
        // Priority order, each addon's own stream order kept within it.
        self.options = options.enumerated()
            .sorted { (Self.addonPriority($0.element.addonName), $0.offset) < (Self.addonPriority($1.element.addonName), $1.offset) }
            .map(\.element)
        preselectedID = preselect
        var counts: [String: Int] = [:]
        var order: [String] = []
        for option in self.options {
            if counts[option.addonName] == nil { order.append(option.addonName) }
            counts[option.addonName, default: 0] += 1
        }
        let rows = order.map { (name: $0, count: counts[$0] ?? 0, isAll: false) }
            + [(name: String(localized: "All"), count: self.options.count, isAll: true)]
        if !userChoseAddon {
            let preselected = preselect.flatMap { id in self.options.first { $0.id == id }?.addonName }
            selectedAddon = preselected ?? order.first
        }
        if rows.map(\.name) != addons.map(\.name) || rows.map(\.count) != addons.map(\.count) {
            addons = rows
            addonTable.reloadData()
        }
        recommendedOption = recommend?(self.options)
        // Only when what is shown changed, so focus in the list doesn't jump as other addons answer.
        let ids = (shownRecommended.map { ["r" + $0.id] } ?? []) + visibleOptions.map(\.id)
        if ids != shownStreamIDs {
            shownStreamIDs = ids
            streamTable.reloadData()
        }
        moreLabel.isHidden = !isLoading || self.options.isEmpty
        updateEmptyFilterLabel()
        if isQuickStart {
            // The flow starts the recommended stream; the list stays behind the status until asked for.
        } else if self.options.isEmpty {
            if isLoading {
                showStatus(String(localized: "Finding streams…"), spinning: true)
            } else {
                showStatus(String(localized: "No streams found. Your addons have nothing playable for this title yet."), spinning: false)
            }
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        } else if wasEmpty {
            hideStatus()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    /// Play without choosing: a status screen with Choose Stream and Cancel while the flow
    /// waits for the recommended stream.
    func beginQuickStart() {
        loadViewIfNeeded()
        isQuickStart = true
        showStatus(String(localized: "Finding the best stream…"), spinning: true)
        chooseButton.isHidden = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// The recommended stream, once the addons have answered (nil while there is none).
    var recommendation: StremioStreamOption? { recommendedOption }

    /// Quick start found nothing it could start: the list (or its empty message) comes up.
    func showList() {
        guard isQuickStart, !isStarting else { return }
        isQuickStart = false
        chooseButton.isHidden = true
        if options.isEmpty {
            showStatus(moreLabel.isHidden ? String(localized: "No streams found. Your addons have nothing playable for this title yet.")
                       : String(localized: "Finding streams…"), spinning: !moreLabel.isHidden)
        } else {
            hideStatus()
        }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// The picked stream is starting: hold every press until the player is up.
    func showStarting() {
        isQuickStart = false
        chooseButton.isHidden = true
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
        let inAddon = selectedAddon.map { addon in options.filter { $0.addonName == addon } } ?? options
        return inAddon.filter { option in activeFilters.allSatisfy { $0.matches(option) } }
    }

    /// The Recommended card, shown above the list while it passes the filters.
    private var shownRecommended: StremioStreamOption? {
        guard let recommendedOption, activeFilters.allSatisfy({ $0.matches(recommendedOption) }) else { return nil }
        return recommendedOption
    }

    private func toggle(_ filter: Filter) {
        if activeFilters.contains(filter) { activeFilters.remove(filter) } else { activeFilters.insert(filter) }
        UserDefaults.standard.set(activeFilters.map(\.rawValue), forKey: Self.filtersKey)
        renderFilters()
        shownStreamIDs = (shownRecommended.map { ["r" + $0.id] } ?? []) + visibleOptions.map(\.id)
        streamTable.reloadData()
        updateEmptyFilterLabel()
    }

    private func renderFilters() {
        for (filter, button) in filterButtons {
            let on = activeFilters.contains(filter)
            button.configuration?.title = filter.title
            button.configuration?.image = UIImage(systemName: on ? "checkmark.circle.fill" : "circle")
            button.configuration?.imagePadding = 10
        }
    }

    private func updateEmptyFilterLabel() {
        emptyFilterLabel.isHidden = streamTable.isHidden || options.isEmpty
            || !(visibleOptions.isEmpty && shownRecommended == nil)
    }

    private func showStatus(_ text: String, spinning: Bool) {
        statusLabel.text = text
        spinning ? statusSpinner.startAnimating() : statusSpinner.stopAnimating()
        statusStack.isHidden = false
        // Something to focus while loading, so Menu and Select reach this screen.
        cancelButton.isHidden = isStarting
        // A list under the status would still take focus (and the geometric focus test needs it hidden).
        let listHidden = spinning || options.isEmpty || isQuickStart
        addonTable.isHidden = listHidden
        streamTable.isHidden = listHidden
        filterStack.isHidden = listHidden
        updateEmptyFilterLabel()
    }

    private func hideStatus() {
        statusStack.isHidden = true
        cancelButton.isHidden = true
        statusSpinner.stopAnimating()
        addonTable.isHidden = false
        streamTable.isHidden = false
        filterStack.isHidden = false
        updateEmptyFilterLabel()
    }

    /// A move from one row to another is the user browsing: from then on the list stays on what
    /// they are looking at, whichever addon answers next. The first focus (placed by the picker)
    /// doesn't count, so until then the list still follows the top addon as it arrives.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard let previous = context.previouslyFocusedView, let next = context.nextFocusedView else { return }
        let inLists = { (view: UIView) in view.isDescendant(of: self.streamTable) || view.isDescendant(of: self.addonTable) }
        if inLists(previous), inLists(next) { userChoseAddon = true }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if streamTable.isHidden { return isQuickStart ? [chooseButton] : [cancelButton] }
        return [streamTable]
    }

    private var laidOutWidth: CGFloat = 0

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Row heights depend on the list's width, known only now.
        guard streamTable.bounds.width != laidOutWidth else { return }
        laidOutWidth = streamTable.bounds.width
        streamTable.reloadData()
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

    func numberOfSections(in tableView: UITableView) -> Int { tableView === addonTable ? 1 : 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView === addonTable { return addons.count }
        return section == 0 ? (shownRecommended == nil ? 0 : 1) : visibleOptions.count
    }

    private func streamOption(at indexPath: IndexPath) -> StremioStreamOption {
        indexPath.section == 0 ? (shownRecommended ?? visibleOptions[indexPath.row]) : visibleOptions[indexPath.row]
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView === addonTable {
            let cell = tableView.dequeueReusableCell(withIdentifier: StremioAddonCell.id, for: indexPath) as! StremioAddonCell
            let addon = addons[indexPath.row]
            let isSelected = addon.isAll ? selectedAddon == nil : selectedAddon == addon.name
            cell.configure(name: addon.name, count: addon.count, isSelected: isSelected)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: StremioStreamCell.id, for: indexPath) as! StremioStreamCell
        cell.configure(streamOption(at: indexPath), recommended: indexPath.section == 0)
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if tableView === addonTable { return 100 }
        return StremioStreamCell.height(for: streamOption(at: indexPath), width: tableView.bounds.width,
                                        recommended: indexPath.section == 0)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !isStarting else { return }
        if tableView === addonTable {
            userChoseAddon = true
            selectedAddon = addons[indexPath.row].isAll ? nil : addons[indexPath.row].name
            addonTable.reloadData()
            shownStreamIDs = (shownRecommended.map { ["r" + $0.id] } ?? []) + visibleOptions.map(\.id)
            streamTable.reloadData()
            updateEmptyFilterLabel()
            streamTable.setContentOffset(CGPoint(x: 0, y: -streamTable.contentInset.top), animated: false)
            return
        }
        onSelect?(streamOption(at: indexPath))
    }

    func indexPathForPreferredFocusedView(in tableView: UITableView) -> IndexPath? {
        guard tableView === streamTable else { return nil }
        if let id = preselectedID, let row = visibleOptions.firstIndex(where: { $0.id == id }) {
            return IndexPath(row: row, section: 1)
        }
        if shownRecommended != nil { return IndexPath(row: 0, section: 0) }
        return visibleOptions.isEmpty ? nil : IndexPath(row: 0, section: 1)
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
            // The card, not the row: a scaled row drew over its neighbours.
            platter.transform = isFocused ? CGAffineTransform(scaleX: 1.015, y: 1.015) : .identity
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

    static let nameFont = UIFont.systemFont(ofSize: 26, weight: .bold)
    static let descriptionFont = UIFont.systemFont(ofSize: 24, weight: .regular)
    static let nameWidth: CGFloat = 250
    /// Row inset 8 + card padding 26 on each side, and 28 between the two columns.
    static let horizontalChrome: CGFloat = 8 * 2 + 26 * 2 + 28
    /// Card padding 22 top and bottom, plus 6 of row inset each way.
    static let verticalChrome: CGFloat = 22 * 2 + 6 * 2

    static func nameText(_ option: StremioStreamOption, recommended: Bool = false) -> String {
        let name = option.stream.name ?? option.addonName
        return recommended ? "★ " + String(localized: "Recommended") + "\n" + name : name
    }
    static func descriptionText(_ option: StremioStreamOption) -> String {
        option.stream.description ?? option.stream.filename ?? option.source.fileName ?? ""
    }

    /// The row's exact height for this list width: the taller of its two columns.
    static func height(for option: StremioStreamOption, width: CGFloat, recommended: Bool = false) -> CGFloat {
        let descriptionWidth = max(200, width - horizontalChrome - nameWidth)
        func measure(_ text: String, _ font: UIFont, _ width: CGFloat) -> CGFloat {
            ceil((text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil).height)
        }
        let columns = max(measure(nameText(option, recommended: recommended), nameFont, nameWidth),
                          measure(descriptionText(option), descriptionFont, descriptionWidth))
        return max(100, columns + verticalChrome + 4)
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        nameLabel.font = Self.nameFont
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 0
        descriptionLabel.font = Self.descriptionFont
        descriptionLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        descriptionLabel.numberOfLines = 0
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        platter.addSubview(nameLabel)
        platter.addSubview(descriptionLabel)
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: platter.topAnchor, constant: 22),
            nameLabel.leadingAnchor.constraint(equalTo: platter.leadingAnchor, constant: 26),
            nameLabel.widthAnchor.constraint(equalToConstant: Self.nameWidth),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: platter.bottomAnchor, constant: -22),
            descriptionLabel.topAnchor.constraint(equalTo: platter.topAnchor, constant: 22),
            descriptionLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 28),
            descriptionLabel.trailingAnchor.constraint(equalTo: platter.trailingAnchor, constant: -26),
            descriptionLabel.bottomAnchor.constraint(lessThanOrEqualTo: platter.bottomAnchor, constant: -22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The addon's own words: its label on the left, its description (file, size, quality) on the right.
    func configure(_ option: StremioStreamOption, recommended: Bool = false) {
        nameLabel.text = Self.nameText(option, recommended: recommended)
        nameLabel.textColor = recommended ? UIColor(red: 1, green: 0.82, blue: 0.35, alpha: 1) : .white
        descriptionLabel.text = Self.descriptionText(option)
        contentView.alpha = option.isUncached ? 0.55 : 1
    }
}
