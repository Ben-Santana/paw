import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Spotify Web API over OAuth (authorization code with PKCE, no client secret).
/// The person registers their own Spotify app and pastes its client ID; tokens live in the Keychain.
/// Playback control needs Spotify Premium and an open Spotify app on some device.
@MainActor
final class SpotifyClient: ObservableObject {
    static let shared = SpotifyClient()

    static let redirectURI = "runes-spotify://callback"
    private static let scopes = "user-read-playback-state user-modify-playback-state user-library-modify"
    /// The Runes Spotify app. A PKCE client ID is public, not a secret.
    static let clientID = "d845d22c3a5e4a4caf16a2456f23b0c8"

    @Published private(set) var isConnected: Bool
    @Published private(set) var accountName: String?

    private struct Tokens: Codable { var access: String; var refresh: String; var expires: Date; var name: String? }
    private var tokens: Tokens? { didSet { isConnected = tokens != nil; accountName = tokens?.name } }
    private let keychain = SpotifyKeychain()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    private var authSession: ASWebAuthenticationSession?
    private let presenter = Presenter()

    private init() {
        let saved = keychain.load().flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
        tokens = saved; isConnected = saved != nil; accountName = saved?.name
    }

    // MARK: Sign in

    func connect() async throws {
        let id = Self.clientID
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: id), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let auth = ASWebAuthenticationSession(url: components.url!, callback: .customScheme("runes-spotify")) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? SpotifyError.message("Sign-in was cancelled.")) }
            }
            auth.presentationContextProvider = presenter
            auth.prefersEphemeralWebBrowserSession = false
            authSession = auth
            auth.start()
        }
        authSession = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw SpotifyError.message("Sign-in response didn’t match. Try again.") }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw SpotifyError.message("Spotify said: \(items.first { $0.name == "error" }?.value ?? "no code returned").")
        }
        var fresh = try await tokenRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                                            "client_id": id, "code_verifier": verifier], previousRefresh: nil)
        if let (data, _) = try? await send("GET", "https://api.spotify.com/v1/me", token: fresh.access),
           let me = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            fresh.name = (me["display_name"] as? String) ?? (me["id"] as? String)
        }
        store(fresh)
    }

    func disconnect() { keychain.delete(); tokens = nil }

    private func store(_ new: Tokens) {
        tokens = new
        if let data = try? JSONEncoder().encode(new) { keychain.save(data) }
    }

    private func tokenRequest(_ fields: [String: String], previousRefresh: String?) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents(); form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw SpotifyError.message("Spotify sign-in failed. Reconnect in the action’s settings.")
        }
        let expiresIn = json["expires_in"] as? Double ?? 3600
        guard let refresh = (json["refresh_token"] as? String) ?? previousRefresh else { throw SpotifyError.message("Spotify didn’t return a refresh token.") }
        return Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(expiresIn - 60), name: tokens?.name)
    }

    private func accessToken() async throws -> String {
        guard let current = tokens else { throw SpotifyError.message("Connect Spotify in the action’s settings.") }
        if current.expires > Date() { return current.access }
        do {
            let fresh = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": current.refresh, "client_id": Self.clientID],
                                               previousRefresh: current.refresh)
            store(fresh)
            return fresh.access
        } catch {
            throw SpotifyError.message("Spotify sign-in expired. Reconnect in the action’s settings.")
        }
    }

    // MARK: Commands

    private static let player = "https://api.spotify.com/v1/me/player"

    func perform(_ command: SpotifyCommand) async throws {
        let token = try await accessToken()
        switch command {
        case .play: try await play(token)
        case .pause: try await call("PUT", "/pause", token)
        case .next: try await call("POST", "/next", token)
        case .previous: try await call("POST", "/previous", token)
        case .playPause:
            let state = try await playback(token)
            if state?["is_playing"] as? Bool == true { try await call("PUT", "/pause", token) } else { try await play(token) }
        case .volumeUp, .volumeDown:
            guard let device = try await playback(token)?["device"] as? [String: Any], let volume = device["volume_percent"] as? Int else {
                throw SpotifyError.message("This Spotify device doesn’t allow volume control.")
            }
            let next = max(0, min(100, volume + (command == .volumeUp ? 10 : -10)))
            try await call("PUT", "/volume?volume_percent=\(next)", token)
        case .seekForward, .seekBack:
            guard let state = try await playback(token), let progress = state["progress_ms"] as? Int else { throw SpotifyError.noDevice }
            let duration = (state["item"] as? [String: Any])?["duration_ms"] as? Int ?? .max
            let target = max(0, min(duration - 1000, progress + (command == .seekForward ? 15_000 : -15_000)))
            try await call("PUT", "/seek?position_ms=\(target)", token)
        case .toggleShuffle:
            guard let state = try await playback(token) else { throw SpotifyError.noDevice }
            try await call("PUT", "/shuffle?state=\(!(state["shuffle_state"] as? Bool ?? false))", token)
        case .cycleRepeat:
            guard let state = try await playback(token) else { throw SpotifyError.noDevice }
            let next = ["off": "context", "context": "track", "track": "off"][state["repeat_state"] as? String ?? "off"] ?? "off"
            try await call("PUT", "/repeat?state=\(next)", token)
        case .saveTrack:
            guard let item = try await playback(token)?["item"] as? [String: Any], let uri = item["uri"] as? String, let id = item["id"] as? String else {
                throw SpotifyError.message("Nothing is playing to like.")
            }
            let encoded = uri.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? uri
            let (_, status) = try await send("PUT", "https://api.spotify.com/v1/me/library?uris=\(encoded)", token: token)
            if !(200..<300).contains(status) {
                // Older endpoint, for apps that still use it.
                try check(try await send("PUT", "https://api.spotify.com/v1/me/tracks?ids=\(id)", token: token))
            }
        }
    }

    /// Resumes; with no active device, wakes the first available one.
    private func play(_ token: String) async throws {
        do { try await call("PUT", "/play", token) } catch SpotifyError.noDevice {
            let (data, _) = try await send("GET", Self.player + "/devices", token: token)
            let devices = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["devices"] as? [[String: Any]] ?? []
            guard let id = devices.first?["id"] as? String else { throw SpotifyError.noDevice }
            let body = try JSONSerialization.data(withJSONObject: ["device_ids": [id], "play": true])
            try check(try await send("PUT", Self.player, token: token, body: body))
        }
    }

    private func playback(_ token: String) async throws -> [String: Any]? {
        let (data, status) = try await send("GET", Self.player, token: token)
        if status == 204 { return nil }
        try check((data, status))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func call(_ method: String, _ path: String, _ token: String) async throws {
        try check(try await send(method, Self.player + path, token: token))
    }

    private func check(_ result: (Data, Int)) throws {
        let (data, status) = result
        if (200..<300).contains(status) { return }
        let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let reason = error?["reason"] as? String
        if status == 404 || reason == "NO_ACTIVE_DEVICE" { throw SpotifyError.noDevice }
        if reason == "PREMIUM_REQUIRED" { throw SpotifyError.message("Spotify playback control needs Premium.") }
        if status == 401 { throw SpotifyError.message("Spotify sign-in expired. Reconnect in the action’s settings.") }
        if status == 429 { throw SpotifyError.message("Spotify is rate limiting. Try again shortly.") }
        throw SpotifyError.message(error?["message"] as? String ?? "Spotify returned \(status).")
    }

    private func send(_ method: String, _ url: String, token: String, body: Data? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        else if method != "GET" { request.setValue("0", forHTTPHeaderField: "Content-Length") }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return Data(buffer).base64URL
    }

    private final class Presenter: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor(windowScene: scenes.first!)
            }
        }
    }
}

enum SpotifyError: Error, LocalizedError {
    case noDevice, message(String)
    var errorDescription: String? {
        switch self {
        case .noDevice: "No Spotify device is active. Open Spotify on a phone, computer or speaker."
        case .message(let text): text
        }
    }
}

/// Spotify tokens, readable after first unlock so actions work on a locked phone.
private struct SpotifyKeychain {
    private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: "com.runes.ios.spotify.v1",
                                        kSecAttrAccount as String: "tokens"]
    func load() -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }
    func save(_ data: Data) {
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }
    func delete() { SecItemDelete(query as CFDictionary) }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
