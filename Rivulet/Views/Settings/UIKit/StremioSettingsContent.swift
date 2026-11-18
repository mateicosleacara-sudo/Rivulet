// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioSettingsContent.swift
//  Rivulet
//
//  Settings > Servers > Stremio. Signed out: sign in with a code approved on a
//  phone (Stremio's TV flow, the easy way), or an email and password. Signed
//  in: the account, its addons, Refresh Addons and Sign Out.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

extension SettingsContent {

    static var stremio: [SettingsRowItem] {
        if let account = StremioSession.account {
            return [
                SettingsRowItem(id: "stremioAccountInfo", title: "Account",
                                kind: .info(value: { account.email ?? "Stremio" })),
                SettingsRowItem(id: "stremioRefresh", title: "Refresh Addons",
                                kind: .action(destructive: false, handler: { vc in
                    let page = vc as? SettingsPageViewController
                    Task { @MainActor [weak page] in
                        await StremioSession.refreshAddons()
                        for await loading in ServerDataStore.shared.$isLoading.values where !loading { break }
                        page?.reloadRows()
                    }
                    page?.reloadRows()
                }), isBusy: { ServerDataStore.shared.isLoading }),
                SettingsRowItem(id: "stremioSignOut", title: "Sign Out",
                                kind: .action(destructive: true, handler: { vc in
                    Task { @MainActor in
                        await StremioSession.signOut()
                        addSourceDraft = AddSourceDraft()
                        (vc as? SettingsPageViewController)?.reloadRows()
                    }
                }))
            ]
        }

        guard let draft = addSourceDraft else { return [] }
        return [
            SettingsRowItem(id: "stremioLinkSignIn", title: "Sign In with a Code",
                            kind: .action(destructive: false, handler: { vc in
                                signInStremioWithCode(draft, on: vc)
                            }))
        ] + stremioSteps(draft).map(\.row) + [
            SettingsRowItem(id: "stremioSignIn",
                            title: draft.status == .checking ? "Signing In…" : "Sign In with Email",
                            kind: .action(destructive: false, handler: { vc in
                                signInStremio(draft, on: vc)
                            }))
        ]
    }

    static func stremioSteps(_ draft: AddSourceDraft) -> [EntryStep] {
        [
            EntryStep(id: "stremioEmail", title: "Email",
                      message: "The email of your Stremio account. Accounts made with Google or Facebook have no password: use Sign In with a Code.",
                      placeholder: "Required", keyboard: .emailAddress, contentType: .username,
                      value: { draft.username }, set: { draft.username = $0; draft.status = .idle }),
            EntryStep(id: "stremioPassword", title: "Password",
                      message: "The password of your Stremio account.",
                      placeholder: "Required", keyboard: .asciiCapable, contentType: .password, isSecure: true,
                      value: { draft.password }, set: { draft.password = $0; draft.status = .idle })
        ]
    }

    private static func signInStremio(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        let email = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !draft.password.isEmpty else {
            fail(draft, page: page, title: String(localized: "Couldn't Sign In"),
                 message: String(localized: "Enter your Stremio email and password, or use Sign In with a Code."))
            return
        }
        draft.status = .checking
        page?.reloadRows()
        Task { @MainActor in
            do {
                try await StremioSession.signIn(email: email, password: draft.password)
                finish(page, draft: draft)
            } catch {
                fail(draft, page: page, title: String(localized: "Couldn't Sign In"),
                     message: StremioSession.failureMessage(for: error))
            }
        }
    }

    /// Shows the code while the session waits for it; leaving the screen cancels the sign-in.
    private static func signInStremioWithCode(_ draft: AddSourceDraft, on vc: UIViewController) {
        guard draft.status != .checking else { return }
        let page = vc as? SettingsPageViewController
        draft.status = .checking
        page?.reloadRows()

        let attempt = StremioLinkAttempt()
        attempt.task = Task { @MainActor in
            var codeScreen: StremioLinkCodeViewController?
            do {
                try await StremioSession.signInWithLink { code in
                    let screen = StremioLinkCodeViewController(code: code) { attempt.task?.cancel() }
                    codeScreen = screen
                    vc.present(screen, animated: true)
                }
                codeScreen?.dismiss(animated: true)
                finish(page, draft: draft)
            } catch where isCancellationError(error) {
                draft.status = .idle
                page?.reloadRows()
            } catch {
                codeScreen?.dismiss(animated: true)
                fail(draft, page: page, title: String(localized: "Couldn't Sign In"),
                     message: StremioSession.failureMessage(for: error))
            }
        }
    }

    @MainActor private final class StremioLinkAttempt {
        var task: Task<Void, Never>?
    }
}

/// The code to approve on a phone or computer: large, with the address and a QR code of it.
@MainActor
final class StremioLinkCodeViewController: UIViewController {
    private let code: StremioLinkCode
    private let onCancel: () -> Void

    init(code: StremioLinkCode, onCancel: @escaping () -> Void) {
        self.code = code
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.85)

        let title = UILabel()
        title.text = String(localized: "Sign In to Stremio")
        title.font = .systemFont(ofSize: 48, weight: .bold)
        title.textColor = .white

        let codeLabel = UILabel()
        codeLabel.text = code.code
        codeLabel.font = .monospacedSystemFont(ofSize: 96, weight: .heavy)
        codeLabel.textColor = .white

        let address = URL(string: code.link)?.host.map { $0 + (URL(string: code.link)?.path ?? "") } ?? code.link
        let message = UILabel()
        message.text = String(localized: "Scan the code with your phone, or go to \(address) and enter the code above. Sign in to Stremio there and approve.")
        message.font = .systemFont(ofSize: 30)
        message.textColor = UIColor.white.withAlphaComponent(0.8)
        message.numberOfLines = 0
        message.textAlignment = .center

        let qr = UIImageView(image: Self.qrImage(for: code.link))
        qr.contentMode = .scaleAspectFit
        qr.layer.magnificationFilter = .nearest
        qr.backgroundColor = .white
        qr.layer.cornerRadius = 16
        qr.clipsToBounds = true

        let waiting = UIActivityIndicatorView(style: .large)
        waiting.color = .white
        waiting.startAnimating()

        let cancel = UIButton(configuration: .glass())
        cancel.configuration?.title = String(localized: "Cancel")
        cancel.addAction(UIAction { [weak self] _ in
            self?.onCancel()
            self?.dismiss(animated: true)
        }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [title, codeLabel, qr, message, waiting, cancel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 36
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 1100),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 1100),
            qr.widthAnchor.constraint(equalToConstant: 320),
            qr.heightAnchor.constraint(equalToConstant: 320),
        ])
    }

    /// Menu cancels the sign-in.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onCancel()
            dismiss(animated: true)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    private static func qrImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
