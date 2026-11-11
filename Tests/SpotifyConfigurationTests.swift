// swiftc RunesIOS/Mappings/SpotifyConfiguration.swift Tests/SpotifyConfigurationTests.swift -o /private/tmp/runes-spotify-config-tests
import Foundation

@main
struct SpotifyConfigurationTests {
    static func rejected(_ value: Any) {
        do { _ = try SpotifyConfiguration(override: value); preconditionFailure("Invalid configuration accepted") }
        catch SpotifyConfiguration.Failure.invalidClientID {}
        catch { preconditionFailure("Unexpected configuration error") }
    }

    static func main() throws {
        let shared = try SpotifyConfiguration()
        for value: Any? in [nil, "", " \n", "$(SPOTIFY_CLIENT_ID)", SpotifyConfiguration.sharedClientID] {
            let configuration = try SpotifyConfiguration(override: value)
            precondition(configuration.clientID == shared.clientID && configuration.keychainAccount == "tokens")
        }
        for value: Any in [42, "short", String(repeating: "a", count: 31), String(repeating: "a", count: 33),
                           String(repeating: "g", count: 32), String(repeating: "é", count: 16),
                           "$(OTHER_SETTING)", String(repeating: "0", count: 16) + " " + String(repeating: "1", count: 15)] {
            rejected(value)
        }
        let personal = try SpotifyConfiguration(override: "  " + String(repeating: "a", count: 32) + "\n")
        let another = try SpotifyConfiguration(override: String(repeating: "b", count: 32))
        let uppercase = try SpotifyConfiguration(override: String(repeating: "C", count: 32))
        precondition(Set([shared.keychainAccount, personal.keychainAccount, another.keychainAccount]).count == 3)
        let restored = try SpotifyConfiguration()
        precondition(restored.keychainAccount == shared.keychainAccount)

        for configuration in [shared, personal, another, uppercase] {
            let url = configuration.authorizationURL(challenge: "synthetic-challenge", state: "synthetic-state")
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let fields = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
            let exchange = configuration.tokenFields(code: "synthetic-code", verifier: "synthetic-verifier")
            let refresh = configuration.refreshFields(token: "synthetic-refresh")
            precondition(components.scheme == "https" && components.host == "accounts.spotify.com" && components.path == "/authorize")
            precondition(fields["client_id"] == configuration.clientID && exchange["client_id"] == configuration.clientID && refresh["client_id"] == configuration.clientID)
            precondition(fields["redirect_uri"] == SpotifyConfiguration.redirectURI && exchange["redirect_uri"] == SpotifyConfiguration.redirectURI)
            precondition(fields["response_type"] == "code" && fields["code_challenge_method"] == "S256")
            precondition(fields["code_challenge"] == "synthetic-challenge" && fields["state"] == "synthetic-state")
            precondition(Set(fields["scope"]!.split(separator: " ")) == ["user-read-playback-state", "user-modify-playback-state", "user-library-modify"])
            precondition(exchange["grant_type"] == "authorization_code" && exchange["code_verifier"] == "synthetic-verifier")
            precondition(refresh["grant_type"] == "refresh_token" && refresh["refresh_token"] == "synthetic-refresh")
            precondition(fields["client_secret"] == nil && exchange["client_secret"] == nil && refresh["client_secret"] == nil)
        }
        let callback = URL(string: "runes-spotify://callback?state=synthetic-state&code=synthetic-code")!
        let code = try personal.authorizationCode(from: callback, state: "synthetic-state")
        precondition(code == "synthetic-code")
        for value in ["runes-spotify://callback?code=synthetic-code&state=synthetic%2Dstate",
                      "runes-spotify://callback?state=synthetic-state&code=synthetic-code&extra=ignored",
                      "runes-spotify://callback/?state=synthetic-state&code=synthetic-code",
                      "runes-spotify://callback/?code=synthetic-code&state=synthetic%2Dstate"] {
            let code = try personal.authorizationCode(from: URL(string: value)!, state: "synthetic-state")
            precondition(code == "synthetic-code")
            precondition(personal.tokenFields(code: code, verifier: "synthetic-verifier")["redirect_uri"] == "runes-spotify://callback")
        }
        let encodedState = URL(string: "runes-spotify://callback?state=synthetic%2Dstate%5Fvalue&code=synthetic%2Bcode%2Fvalue%3D")!
        let decodedCode = try personal.authorizationCode(from: encodedState, state: "synthetic-state_value")
        precondition(decodedCode == "synthetic+code/value=")
        let rejectedCallbacks: [(String, SpotifyCallbackRejection)] = [
            ("other://callback?state=synthetic-state&code=synthetic-code", .redirectScheme),
            ("RUNES-SPOTIFY://callback?state=synthetic-state&code=synthetic-code", .redirectScheme),
            ("runes-spotify://other?state=synthetic-state&code=synthetic-code", .redirectHost),
            ("runes-spotify://CALLBACK?state=synthetic-state&code=synthetic-code", .redirectHost),
            ("runes-spotify://callback/path?state=synthetic-state&code=synthetic-code", .redirectPath),
            ("runes-spotify://callback//?state=synthetic-state&code=synthetic-code", .redirectPath),
            ("runes-spotify://callback/%2F?state=synthetic-state&code=synthetic-code", .redirectPath),
            ("runes-spotify://callback/%2e?state=synthetic-state&code=synthetic-code", .redirectPath),
            ("runes-spotify://callback%2F?state=synthetic-state&code=synthetic-code", .redirectHost),
            ("runes-spotify://callback?state=synthetic-state&code=synthetic-code#fragment", .redirectFragment),
            ("runes-spotify://callback?state=synthetic-state&code=synthetic-code#", .redirectEmptyFragment),
            ("runes-spotify://user@callback?state=synthetic-state&code=synthetic-code", .redirectFormat),
            ("runes-spotify://callback:123?state=synthetic-state&code=synthetic-code", .redirectFormat),
            ("runes-spotify://callback?code=synthetic-code", .missingState),
            ("runes-spotify://callback?state=synthetic-state&state=synthetic-state&code=synthetic-code", .duplicateState),
            ("runes-spotify://callback?state=wrong&code=synthetic-code", .mismatchedState),
            ("runes-spotify://callback?state&code=synthetic-code", .mismatchedState),
            ("runes-spotify://callback?state=synthetic-state", .missingCode),
            ("runes-spotify://callback?state=synthetic-state&code=one&code=two", .duplicateCode),
            ("runes-spotify://callback?state=synthetic-state&code=", .emptyCode),
            ("runes-spotify://callback?state=synthetic-state&code", .emptyCode),
            ("runes-spotify://callback?state=wrong&error=access_denied", .mismatchedState)
        ]
        for (value, expected) in rejectedCallbacks {
            for variant in Set([value, value.replacingOccurrences(of: "callback?", with: "callback/?")
                .replacingOccurrences(of: "callback:123?", with: "callback:123/?")]) {
                do { _ = try personal.authorizationCode(from: URL(string: variant)!, state: "synthetic-state"); preconditionFailure("Invalid callback accepted") }
                catch SpotifyConfiguration.Failure.invalidCallback(let reason) { precondition(reason == expected) }
            }
        }
        precondition(Set(rejectedCallbacks.map { $0.1 }) == Set(SpotifyCallbackRejection.allCases.filter { ![.malformedURL, .redirectTrailingSlash].contains($0) }))
        for path in ["", "/"] {
            do {
                _ = try personal.authorizationCode(from: URL(string: "runes-spotify://callback\(path)?state=synthetic-state&error=access_denied")!, state: "synthetic-state")
                preconditionFailure("Denied authorization accepted")
            } catch SpotifyConfiguration.Failure.authorizationDenied {}
        }
        print("Spotify configuration checks passed: literal root callback accepted, canonical exchange URI retained, encoded paths and invalid state/code rejected.")
    }
}
