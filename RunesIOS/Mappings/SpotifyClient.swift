import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Spotify Web API over OAuth (authorization code with PKCE, no client secret).
/// Tokens are kept separately for each configured Spotify app.
/// Playback control needs Spotify Premium and an open Spotify app on some device.
@MainActor
final class SpotifyClient: ObservableObject {
    static let shared = SpotifyClient()

    @Published private(set) var isConnected: Bool
    @Published private(set) var accountName: String?
    @Published private(set) var accessIssue: String?
    @Published private(set) var connectionCheckPassed = false

    private struct Tokens: Codable { var access: String; var refresh: String; var expires: Date; var name: String? }
    private var tokens: Tokens? { didSet { isConnected = tokens != nil; accountName = tokens?.name } }
    private let configuration: SpotifyConfiguration?
    private let keychain: SpotifyKeychain?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    private var authSession: ASWebAuthenticationSession?
    private var signInGeneration = UUID()
    private let presenter = Presenter()

    private init() {
        let configuration = try? SpotifyConfiguration(override: Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID"))
        self.configuration = configuration
        let keychain = configuration.map { SpotifyKeychain(account: $0.keychainAccount) }
        self.keychain = keychain
        let saved = keychain?.load().flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
        tokens = saved; isConnected = saved != nil; accountName = saved?.name
        if configuration == nil { accessIssue = SpotifyConfiguration.Failure.invalidClientID.localizedDescription }
    }

    // MARK: Sign in

    func connect() async throws {
        guard let configuration else { throw SpotifyConfiguration.Failure.invalidClientID }
        signInGeneration = UUID()
        let generation = signInGeneration
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(16)
        SpotifyDiagnosticLog.record(authorization: .init(.started))
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let auth = ASWebAuthenticationSession(url: configuration.authorizationURL(challenge: challenge, state: state),
                                                callback: .customScheme(SpotifyConfiguration.callbackScheme)) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? SpotifyError.message("Sign-in was cancelled.")) }
            }
            auth.presentationContextProvider = presenter
            auth.prefersEphemeralWebBrowserSession = false
            authSession = auth
            auth.start()
        }
        guard generation == signInGeneration else { throw CancellationError() }
        authSession = nil
        let code: String
        do {
            code = try configuration.authorizationCode(from: callback, state: state)
        } catch let error as SpotifyConfiguration.Failure {
            switch error {
            case .invalidCallback(let reason): SpotifyDiagnosticLog.record(authorization: .init(rejection: reason))
            case .authorizationDenied: SpotifyDiagnosticLog.record(authorization: .init(.authorizationDenied))
            case .invalidClientID: break
            }
            throw error
        }
        SpotifyDiagnosticLog.record(authorization: .init(.callbackAccepted))
        SpotifyDiagnosticLog.record(authorization: .init(.tokenExchangeStarted))
        let fresh = try await tokenRequest(configuration.tokenFields(code: code, verifier: verifier), previousRefresh: nil)
        guard generation == signInGeneration else { throw CancellationError() }
        // Keep the authorized tokens even if the app's user allowlist is not ready yet.
        // OAuth success alone must not be presented as verified Web API access.
        store(fresh)
        await checkConnection()
    }

    func disconnect() {
        signInGeneration = UUID()
        authSession?.cancel(); authSession = nil
        keychain?.delete(); tokens = nil; accessIssue = nil; connectionCheckPassed = false
    }

    /// A read-only API check, usable with an existing saved sign-in after its app access changes.
    func checkConnection() async {
        guard configuration != nil else { accessIssue = SpotifyConfiguration.Failure.invalidClientID.localizedDescription; return }
        guard isConnected else { return }
        let generation = signInGeneration
        connectionCheckPassed = false
        do {
            let token = try await accessToken()
            guard generation == signInGeneration else { return }
            let result = try await send("GET", "https://api.spotify.com/v1/me", token: token)
            guard generation == signInGeneration else { return }
            try check(result, endpoint: "/v1/me")
            if var saved = tokens,
               let me = try JSONSerialization.jsonObject(with: result.0) as? [String: Any] {
                saved.name = (me["display_name"] as? String) ?? (me["id"] as? String)
                store(saved)
            }
            connectionCheckPassed = true; accessIssue = nil
        } catch {
            guard generation == signInGeneration else { return }
            accessIssue = error.localizedDescription
        }
    }

    private func store(_ new: Tokens) {
        tokens = new
        if let data = try? JSONEncoder().encode(new) { keychain?.save(data) }
    }

    private func tokenRequest(_ fields: [String: String], previousRefresh: String?) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents(); form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            SpotifyDiagnosticLog.record(authorization: .init(transportFailure: .init(error)))
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        SpotifyDiagnosticLog.record(method: "POST", endpoint: "/api/token", status: status,
                                    failure: SpotifyHTTPFailure(data: data, status: status, endpoint: "/api/token"))
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw SpotifyError.message("Spotify sign-in failed. Reconnect in the action’s settings.")
        }
        let expiresIn = json["expires_in"] as? Double ?? 3600
        guard let refresh = (json["refresh_token"] as? String) ?? previousRefresh else { throw SpotifyError.message("Spotify didn’t return a refresh token.") }
        return Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(expiresIn - 60), name: tokens?.name)
    }

    private func accessToken() async throws -> String {
        guard let configuration else { throw SpotifyConfiguration.Failure.invalidClientID }
        guard let current = tokens else { throw SpotifyError.message("Connect Spotify in the action’s settings.") }
        if current.expires > Date() { return current.access }
        let generation = signInGeneration
        do {
            let fresh = try await tokenRequest(configuration.refreshFields(token: current.refresh),
                                               previousRefresh: current.refresh)
            guard generation == signInGeneration else { throw CancellationError() }
            store(fresh)
            return fresh.access
        } catch {
            guard generation == signInGeneration else { throw CancellationError() }
            throw SpotifyError.message("Spotify sign-in expired. Reconnect in the action’s settings.")
        }
    }

    // MARK: Commands

    private static let player = "https://api.spotify.com/v1/me/player"

    func perform(_ command: SpotifyCommand) async throws {
        let generation = signInGeneration
        do {
            try await performCommand(command)
            if generation == signInGeneration { accessIssue = nil }
        } catch {
            if generation == signInGeneration { accessIssue = error.localizedDescription }
            throw error
        }
    }

    private func performCommand(_ command: SpotifyCommand) async throws {
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
            guard let device = try await playback(token)?["device"] as? [String: Any],
                  device["supports_volume"] as? Bool != false,
                  device["is_restricted"] as? Bool != true,
                  let volume = device["volume_percent"] as? Int else {
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
            let result = try await send("PUT", "https://api.spotify.com/v1/me/library?uris=\(encoded)", token: token)
            if result.1 == 404 || result.1 == 405 {
                // Older endpoint, for apps that still use it.
                try check(try await send("PUT", "https://api.spotify.com/v1/me/tracks?ids=\(id)", token: token), endpoint: "/v1/me/tracks")
            } else {
                // Authentication/access failures must keep their original reason, not be masked by a fallback.
                try check(result, endpoint: "/v1/me/library")
            }
        }
    }

    /// Resumes; with no active device, wakes the first available one.
    private func play(_ token: String) async throws {
        do { try await call("PUT", "/play", token) } catch SpotifyError.noDevice {
            let (data, status) = try await send("GET", Self.player + "/devices", token: token)
            try check((data, status), endpoint: "/v1/me/player/devices")
            let devices = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["devices"] as? [[String: Any]] ?? []
            guard let id = devices.first?["id"] as? String else { throw SpotifyError.noDevice }
            let body = try JSONSerialization.data(withJSONObject: ["device_ids": [id], "play": true])
            try check(try await send("PUT", Self.player, token: token, body: body), endpoint: "/v1/me/player")
        }
    }

    private func playback(_ token: String) async throws -> [String: Any]? {
        let (data, status) = try await send("GET", Self.player, token: token)
        if status == 204 { return nil }
        try check((data, status), endpoint: "/v1/me/player")
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func call(_ method: String, _ path: String, _ token: String) async throws {
        try check(try await send(method, Self.player + path, token: token), endpoint: "/v1/me/player" + path)
    }

    private func check(_ result: (Data, Int), endpoint: String) throws {
        let (data, status) = result
        guard let failure = SpotifyHTTPFailure(data: data, status: status, endpoint: endpoint) else { return }
        if failure.category == .noDevice { throw SpotifyError.noDevice }
        throw failure
    }

    private func send(_ method: String, _ url: String, token: String, body: Data? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        else if method != "GET" { request.setValue("0", forHTTPHeaderField: "Content-Length") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        SpotifyDiagnosticLog.record(method: method, endpoint: url, status: status,
                                    failure: SpotifyHTTPFailure(data: data, status: status, endpoint: url))
        return (data, status)
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
    let account: String
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: "com.runes.ios.spotify.v1",
                                      kSecAttrAccount as String: account] }
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
