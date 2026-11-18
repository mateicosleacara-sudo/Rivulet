// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioSession.swift
//  Rivulet
//
//  The signed-in Stremio account. Signing in on a TV is a code approved on
//  another device (link.stremio.com, the same flow Stremio's own TV apps use),
//  or an email and password. The auth key lives in the Keychain under
//  CredentialScope.server; the account (user id and email) in UserDefaults.
//  The addons come from the account each launch, debrid keys and all, so a
//  change made in Stremio shows up here.
//

import Foundation

@MainActor
enum StremioSession {
    struct Account: Codable, Equatable {
        let userID: String
        let email: String?

        var providerID: String { "stremio:\(userID)" }
        var displayName: String { "Stremio" }
    }

    static let accountKey = "stremioAccount"

    /// Set at launch to reload browse state, like `JellyfinSession.onChanged`.
    static var onChanged: (() -> Void)?

    static var account: Account? {
        guard let data = UserDefaults.standard.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    static func storedProvider() -> StremioProvider? {
        guard let account,
              let key = CredentialRegistry.shared.token(for: .server(providerID: account.providerID))
        else { return nil }
        return StremioProvider(userID: account.userID, authKey: key)
    }

    static func signIn(email: String, password: String) async throws {
        let auth = try await StremioClient.login(email: email, password: password)
        try await persist(Account(userID: auth.user.id, email: auth.user.email ?? email), authKey: auth.authKey)
    }

    /// Shows a code (and the page to enter it on) through `showCode`, then waits up to ten
    /// minutes for it to be approved. Cancelling the task ends the wait.
    static func signInWithLink(showCode: (StremioLinkCode) -> Void) async throws {
        let code = try await StremioClient.createLinkCode()
        showCode(code)
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            if let key = try await StremioClient.readLinkCode(code.code) {
                let user = try await StremioClient.user(authKey: key)
                try await persist(Account(userID: user.id, email: user.email), authKey: key)
                return
            }
        }
        throw StremioError.linkExpired
    }

    private static func persist(_ account: Account, authKey: String) async throws {
        // Proves the key works and that the account has addons to show.
        _ = try await StremioClient.addonCollection(authKey: authKey)
        try await CredentialRegistry.shared.setToken(authKey, for: .server(providerID: account.providerID))
        UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: accountKey)
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        MusicProviderRegistry.shared.populateFromCurrentAuth()
        onChanged?()
    }

    /// Forgets the account here. The key is also ended on Stremio's side, without waiting.
    static func signOut() async {
        guard let account else { return }
        let scope = CredentialScope.server(providerID: account.providerID)
        let key = CredentialRegistry.shared.token(for: scope)
        await CredentialRegistry.shared.clearToken(for: scope)
        UserDefaults.standard.removeObject(forKey: accountKey)
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        MusicProviderRegistry.shared.populateFromCurrentAuth()
        onChanged?()
        if let key { Task { await StremioClient.logout(authKey: key) } }
    }

    /// Reloads the addons from the account (installed or removed in Stremio).
    static func refreshAddons() async {
        guard let account,
              let provider = MediaProviderRegistry.shared.provider(for: account.providerID) as? StremioProvider else { return }
        await provider.reloadAddons()
        onChanged?()
    }

    static func failureMessage(for error: Error) -> String {
        switch error {
        case MediaProviderError.unauthorized:
            return String(localized: "Stremio didn't accept that email and password.")
        case StremioError.api(let message):
            return message
        case StremioError.linkExpired:
            return String(localized: "The code expired. Try again for a new one.")
        default:
            return String(localized: "Couldn't reach Stremio. Check the connection and try again.")
        }
    }
}
