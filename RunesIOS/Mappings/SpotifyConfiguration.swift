import Foundation

enum SpotifyCallbackRejection: String, Codable, CaseIterable {
    case malformedURL = "malformed_url"
    case redirectScheme = "redirect_scheme"
    case redirectHost = "redirect_host"
    case redirectPath = "redirect_path"
    case redirectTrailingSlash = "redirect_trailing_slash"
    case redirectFragment = "redirect_fragment"
    case redirectEmptyFragment = "redirect_empty_fragment"
    case redirectFormat = "redirect_format"
    case missingState = "missing_state"
    case duplicateState = "duplicate_state"
    case mismatchedState = "mismatched_state"
    case missingCode = "missing_code"
    case duplicateCode = "duplicate_code"
    case emptyCode = "empty_code"
}

struct SpotifyConfiguration {
    static let sharedClientID = "d845d22c3a5e4a4caf16a2456f23b0c8"
    static let redirectURI = "runes-spotify://callback"
    static let callbackScheme = "runes-spotify"
    private static let scopes = "user-read-playback-state user-modify-playback-state user-library-modify"
    let clientID: String

    enum Failure: LocalizedError {
        case invalidClientID, invalidCallback(SpotifyCallbackRejection), authorizationDenied
        var errorDescription: String? {
            switch self {
            case .invalidClientID: "Spotify app configuration is invalid. Check the Client ID used to build Runes."
            case .invalidCallback: "Spotify sign-in response didn’t match. Try again."
            case .authorizationDenied: "Spotify sign-in was not approved. Try again."
            }
        }
    }

    init(override value: Any? = nil) throws {
        guard let value else { clientID = Self.sharedClientID; return }
        guard let text = value as? String else { throw Failure.invalidClientID }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty || id == "$(SPOTIFY_CLIENT_ID)" { clientID = Self.sharedClientID; return }
        guard id.utf8.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            throw Failure.invalidClientID
        }
        clientID = id
    }

    var keychainAccount: String { clientID == Self.sharedClientID ? "tokens" : "tokens.\(clientID)" }

    func authorizationURL(challenge: String, state: String) -> URL {
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        return url.url!
    }

    func tokenFields(code: String, verifier: String) -> [String: String] {
        ["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
         "client_id": clientID, "code_verifier": verifier]
    }

    func refreshFields(token: String) -> [String: String] {
        ["grant_type": "refresh_token", "refresh_token": token, "client_id": clientID]
    }

    func authorizationCode(from callback: URL, state: String) throws -> String {
        guard var url = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw Failure.invalidCallback(.malformedURL) }
        let items = url.queryItems ?? []
        url.query = nil
        let expected = URLComponents(string: Self.redirectURI)!
        guard url.scheme == expected.scheme else { throw Failure.invalidCallback(.redirectScheme) }
        guard url.host == expected.host else { throw Failure.invalidCallback(.redirectHost) }
        if expected.percentEncodedPath.isEmpty, url.percentEncodedPath == "/" { url.percentEncodedPath = "" }
        guard url.path == expected.path else {
            throw Failure.invalidCallback(url.path == "/" ? .redirectTrailingSlash : .redirectPath)
        }
        if let fragment = url.fragment { throw Failure.invalidCallback(fragment.isEmpty ? .redirectEmptyFragment : .redirectFragment) }
        guard url.string == Self.redirectURI else { throw Failure.invalidCallback(.redirectFormat) }
        let states = items.filter { $0.name == "state" }
        guard !states.isEmpty else { throw Failure.invalidCallback(.missingState) }
        guard states.count == 1 else { throw Failure.invalidCallback(.duplicateState) }
        guard states[0].value == state else { throw Failure.invalidCallback(.mismatchedState) }
        guard !items.contains(where: { $0.name == "error" }) else { throw Failure.authorizationDenied }
        let codes = items.filter { $0.name == "code" }
        guard !codes.isEmpty else { throw Failure.invalidCallback(.missingCode) }
        guard codes.count == 1 else { throw Failure.invalidCallback(.duplicateCode) }
        guard let code = codes[0].value, !code.isEmpty else { throw Failure.invalidCallback(.emptyCode) }
        return code
    }
}
