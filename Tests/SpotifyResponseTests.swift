// Offline checks: no Spotify calls, credentials, Keychain access or app preferences.
// swiftc RunesIOS/Mappings/SpotifyConfiguration.swift RunesIOS/Mappings/SpotifyResponse.swift Tests/SpotifyResponseTests.swift -o /private/tmp/runes-spotify-response-tests && /private/tmp/runes-spotify-response-tests
import Foundation

@main
struct SpotifyResponseTests {
    static func failure(_ body: String, status: Int = 403, endpoint: String = "/v1/me/player/pause") -> SpotifyHTTPFailure {
        SpotifyHTTPFailure(data: Data(body.utf8), status: status, endpoint: endpoint)!
    }

    static func main() throws {
        precondition(SpotifyHTTPFailure(data: Data(), status: 204, endpoint: "/v1/me/player/pause") == nil)

        // A development-mode rejection may be plain text, which the original parser discarded.
        let access = failure("User not registered in the Developer Dashboard", endpoint: "/v1/me")
        precondition(access.category == .appAccess)
        precondition(access.localizedDescription.contains("app owner"))
        let possibleAccess = failure("Check settings on developer.spotify.com/dashboard, the user may not be registered.")
        precondition(possibleAccess.category == .possibleAppAccess)
        precondition(possibleAccess.localizedDescription.contains("may be"))
        precondition(!possibleAccess.localizedDescription.contains("has not allowed"))
        precondition(failure("Device not registered").category == .forbidden)
        precondition(failure("Application not registered").category == .forbidden)

        let premium = failure(#"{"error":{"status":403,"message":"Player command failed","reason":"PREMIUM_REQUIRED"}}"#)
        precondition(premium.category == .premium && premium.reason == "PREMIUM_REQUIRED")
        let developerLink = #"{"error":{"reason":"PREMIUM_REQUIRED","message":"Premium account required. See developer.spotify.com for details."}}"#
        precondition(failure(developerLink).category == .premium)
        precondition(failure(developerLink, status: 401).category == .unauthorized)
        precondition(failure(developerLink, status: 429).category == .rateLimited)
        for (reason, expected) in [("INSUFFICIENT_SCOPE", SpotifyHTTPFailure.Category.scope), ("RESTRICTION_VIOLATED", .restricted), ("DEVICE_NOT_CONTROLLABLE", .restricted), ("VOLUME_CONTROL_DISALLOW", .restricted)] {
            precondition(failure("{\"error\":{\"reason\":\"\(reason)\",\"message\":\"Premium account required. See developer.spotify.com.\"}}").category == expected)
        }
        let owner = failure(#"{"error":{"message":"An active Premium subscription is required for the owner of the app."}}"#)
        precondition(owner.category == .ownerPremium)
        precondition(failure("The app owner must have an active Premium subscription.").category == .ownerPremium)
        for message in ["See developer.spotify.com for Premium information.", "The app owner does not need Premium.", "No Premium subscription is required for the owner of the app."] {
            precondition(failure(message).category == .forbidden)
        }
        let scopes = failure(#"{"error":{"message":"Insufficient client scope"}}"#)
        precondition(scopes.category == .scope)
        let restricted = failure(#"{"error":{"message":"Player command failed","reason":"RESTRICTION_VIOLATED"}}"#)
        precondition(restricted.category == .restricted)

        // Don't relabel every403 as a Premium/allowlist problem or every404 as a missing player.
        let unknown = failure("Forbidden")
        precondition(unknown.category == .forbidden)
        precondition(unknown.localizedDescription.contains("Check connection"))
        let profileForbidden = failure("Forbidden", endpoint: "/v1/me")
        precondition(profileForbidden.localizedDescription.contains("allowed users"))
        precondition(failure("", status: 404).category == .noDevice)
        precondition(failure("", status: 404, endpoint: "/v1/me/library").category == .other)
        precondition(failure("", status: 401).category == .unauthorized)
        precondition(failure("", status: 429).category == .rateLimited)

        // Raw response data never enters errors or diagnostics; even unknown fields are discarded.
        let privateFixture = "fixture-private-value-not-a-real-token"
        let malformed = failure("{invalid \(privateFixture)}")
        let hostileReason = failure("{\"error\":{\"reason\":\"\(privateFixture)\",\"message\":\"\(privateFixture)\"}}")
        precondition(!malformed.localizedDescription.contains(privateFixture))
        precondition(!hostileReason.localizedDescription.contains(privateFixture))
        precondition(hostileReason.reason == nil)
        let record = SpotifyDiagnosticRecord(method: "PUT", endpoint: "https://api.spotify.com/v1/me/library?uris=\(privateFixture)#\(privateFixture)", status: 403, failure: hostileReason)
        let encoded = String(data: try JSONEncoder().encode(record), encoding: .utf8)!
        precondition(record.endpoint == "/v1/me/library")
        precondition(!encoded.contains(privateFixture))
        precondition(!encoded.contains("https:") && !encoded.contains("?"))
        let unknownPath = SpotifyDiagnosticRecord(method: privateFixture, endpoint: "/v1/users/\(privateFixture)", status: 403, failure: unknown)
        precondition(unknownPath.endpoint == "other" && unknownPath.method == "OTHER")
        precondition(SpotifyDiagnosticRecord(method: "GET", endpoint: "/v1/me", status: 200, failure: nil).category == "success")

        let httpFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        precondition(Set(httpFields.keys) == ["date", "method", "endpoint", "status", "category"])
        let authRecords = SpotifyAuthorizationRecord.Event.allCases.map { SpotifyAuthorizationRecord($0) }
            + SpotifyCallbackRejection.allCases.map { SpotifyAuthorizationRecord(rejection: $0) }
            + SpotifyAuthorizationRecord.TransportFailure.allCases.map { SpotifyAuthorizationRecord(transportFailure: $0) }
        for auth in authRecords {
            let data = try JSONEncoder().encode(auth)
            let fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            precondition(Set(fields.keys).isSubset(of: ["date", "event", "reason"]))
            let text = String(data: data, encoding: .utf8)!
            precondition(!text.contains(privateFixture) && !text.contains("client_id") && !text.contains("callback?"))
        }
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                                 userInfo: [NSLocalizedDescriptionKey: privateFixture, NSURLErrorFailingURLErrorKey: URL(string: "https://example.invalid/?code=\(privateFixture)")!])
        let transport = SpotifyAuthorizationRecord.TransportFailure(underlying)
        precondition(transport == .timeout)
        let transportText = String(data: try JSONEncoder().encode(SpotifyAuthorizationRecord(transportFailure: transport)), encoding: .utf8)!
        precondition(!transportText.contains(privateFixture) && !transportText.contains("example.invalid"))
        precondition(SpotifyAuthorizationRecord.TransportFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) == .offline)
        precondition(SpotifyAuthorizationRecord.TransportFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)) == .cancelled)
        precondition(SpotifyAuthorizationRecord.TransportFailure(NSError(domain: privateFixture, code: NSURLErrorTimedOut)) == .other)

        let configuration = try SpotifyConfiguration()
        let callback = URL(string: "runes-spotify://callback?code=\(privateFixture)&state=\(privateFixture)")!
        do { _ = try configuration.authorizationCode(from: callback, state: "expected"); preconditionFailure("Invalid state accepted") }
        catch SpotifyConfiguration.Failure.invalidCallback(let reason) {
            let text = String(data: try JSONEncoder().encode(SpotifyAuthorizationRecord(rejection: reason)), encoding: .utf8)!
            precondition(text.contains("mismatched_state") && !text.contains(privateFixture))
            precondition(!SpotifyConfiguration.Failure.invalidCallback(reason).localizedDescription.contains(privateFixture))
        }
        print("Spotify response checks passed: HTTP compatibility, honest failures, fixed authorization reasons and private-data redaction.")
    }
}
