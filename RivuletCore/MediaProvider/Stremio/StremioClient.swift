// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//
//  StremioClient.swift
//  Rivulet
//
//  Requests to the Stremio account API and to addons, built the way stremio-core
//  builds them: POST https://api.strem.io/api/<method> with a JSON body carrying
//  "type"; GET https://link.stremio.com/api/v2/<create|read>; addon resources at
//  <base>/<resource>/<type>/<id>[/<extra>].json with each part encoded as a URI
//  component. The auth key and an addon's URL (which carries the debrid key) are
//  never logged.
//

import Foundation

enum StremioError: Error, Equatable {
    case api(String)
    case badResponse
    case linkExpired
}

nonisolated enum StremioClient {
    static let apiBase = URL(string: "https://api.strem.io/api/")!
    static let linkBase = URL(string: "https://link.stremio.com/api/v2/")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // MARK: - Account

    static func login(email: String, password: String) async throws -> StremioAuthResponse {
        try await call("login", ["type": "Login", "email": email, "password": password, "facebook": false])
    }

    static func logout(authKey: String) async {
        let _: StremioAnyResult? = try? await call("logout", ["type": "Logout", "authKey": authKey])
    }

    static func user(authKey: String) async throws -> StremioUser {
        try await call("getUser", ["type": "GetUser", "authKey": authKey])
    }

    static func addonCollection(authKey: String) async throws -> [StremioAddon] {
        let collection: StremioAddonCollection = try await call(
            "addonCollectionGet", ["type": "AddonCollectionGet", "authKey": authKey, "update": true])
        return collection.addons
    }

    /// The TV sign-in: a code the user approves at stremio.com/link (or by its QR code).
    static func createLinkCode() async throws -> StremioLinkCode {
        try await link("create", query: [URLQueryItem(name: "type", value: "Create")])
    }

    /// The auth key once the code has been approved; nil while it is still waiting (whatever
    /// shape the waiting answer takes). Only an expired or unknown code ends the wait.
    static func readLinkCode(_ code: String) async throws -> String? {
        do {
            let key: StremioLinkAuthKey = try await link(
                "read", query: [URLQueryItem(name: "type", value: "Read"), URLQueryItem(name: "code", value: code)])
            return key.authKey.isEmpty ? nil : key.authKey
        } catch StremioError.api(let message) {
            let lower = message.lowercased()
            if lower.contains("expired") || lower.contains("not found") || lower.contains("invalid") {
                throw StremioError.linkExpired
            }
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func call<T: Decodable & Sendable>(_ method: String, _ body: [String: Any]) async throws -> T {
        var request = URLRequest(url: apiBase.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decodeResult(request)
    }

    private static func link<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: linkBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        return try await decodeResult(URLRequest(url: components.url!))
    }

    private static func decodeResult<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StremioError.badResponse }
        guard let wrapped = try? JSONDecoder().decode(StremioAPIResult<T>.self, from: data) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw MediaProviderError.unauthorized }
            throw StremioError.badResponse
        }
        if let result = wrapped.result { return result }
        if let error = wrapped.error {
            // stremio-core's "session does not exist" and wrong-password codes.
            if error.code == 1 || error.code == 2 || error.message.lowercased().contains("session") {
                throw MediaProviderError.unauthorized
            }
            throw StremioError.api(error.message)
        }
        throw StremioError.badResponse
    }

    // MARK: - Addons

    /// stremio-core's URI_COMPONENT_ENCODE_SET: everything but A-Z a-z 0-9 - _ . ! ~ * ' ( ).
    private static let uriComponent = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    static func encode(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: uriComponent) ?? part
    }

    static func resourceURL(_ addon: StremioAddon, resource: String, type: String, id: String,
                            extra: [(String, String)] = []) -> URL? {
        var path = "/\(encode(resource))/\(encode(type))/\(encode(id))"
        if !extra.isEmpty {
            path += "/" + extra.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        return URL(string: addon.baseURL + path + ".json")
    }

    static func resource<T: Decodable & Sendable>(_ addon: StremioAddon, resource: String, type: String, id: String,
                                                    extra: [(String, String)] = [],
                                                    timeout: TimeInterval = 20) async throws -> T {
        guard let url = resourceURL(addon, resource: resource, type: type, id: id, extra: extra) else {
            throw StremioError.badResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StremioError.badResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// A result whose content is not needed (logout).
nonisolated struct StremioAnyResult: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}
