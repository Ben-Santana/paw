import Foundation

/// Interprets Spotify's JSON and plain-text errors without retaining response bodies.
/// In development mode OAuth can succeed for a user whose API calls are still forbidden.
struct SpotifyHTTPFailure: Error, LocalizedError {
    enum Category: String, Codable {
        case noDevice = "no_active_device"
        case premium = "premium_required"
        case ownerPremium = "app_owner_premium_required"
        case appAccess = "app_user_not_allowed"
        case possibleAppAccess = "app_user_access_unconfirmed"
        case scope = "insufficient_scope"
        case restricted = "playback_restricted"
        case unauthorized, rateLimited = "rate_limited", forbidden, other
    }

    let status: Int
    let endpoint: String
    let category: Category
    /// Only known, fixed protocol values may enter diagnostics.
    let reason: String?

    init?(data: Data, status: Int, endpoint: String) {
        guard !(200..<300).contains(status) else { return nil }
        self.status = status
        self.endpoint = SpotifyDiagnosticRecord.safeEndpoint(endpoint)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let rawReason = error?["reason"] as? String
        let message = (error?["message"] as? String) ?? (object?["error_description"] as? String)
            ?? (String(data: data.prefix(8192), encoding: .utf8) ?? "")
        let lower = message.lowercased()
        let allowedReasons: Set<String> = ["NO_ACTIVE_DEVICE", "PREMIUM_REQUIRED", "RESTRICTION_VIOLATED", "DEVICE_NOT_CONTROLLABLE", "VOLUME_CONTROL_DISALLOW", "INSUFFICIENT_SCOPE", "QUOTA_EXCEEDED"]
        reason = rawReason.flatMap { allowedReasons.contains($0) ? $0 : nil }

        if status == 401 { category = .unauthorized }
        else if status == 429 { category = .rateLimited }
        else if rawReason == "NO_ACTIVE_DEVICE" || (status == 404 && self.endpoint.hasPrefix("/v1/me/player")) { category = .noDevice }
        else if rawReason == "PREMIUM_REQUIRED" { category = .premium }
        else if rawReason == "INSUFFICIENT_SCOPE" { category = .scope }
        else if ["RESTRICTION_VIOLATED", "DEVICE_NOT_CONTROLLABLE", "VOLUME_CONTROL_DISALLOW"].contains(rawReason ?? "") { category = .restricted }
        else if ["an active premium subscription is required for the owner of the app.", "the app owner must have an active premium subscription."].contains(lower.trimmingCharacters(in: .whitespacesAndNewlines)) { category = .ownerPremium }
        else if lower.contains("premium required") || lower.contains("premium account required") { category = .premium }
        else if lower.contains("user may not be registered") || lower.contains("account may not be registered") { category = .possibleAppAccess }
        else if ["user not registered", "user is not registered", "account not registered", "account is not registered", "user not allowlisted", "user is not allowlisted", "user not whitelisted", "user is not whitelisted"].contains(where: lower.contains) { category = .appAccess }
        else if lower.contains("insufficient") && lower.contains("scope") { category = .scope }
        else if lower.contains("restriction violated") { category = .restricted }
        else if status == 403 { category = .forbidden }
        else { category = .other }
    }

    var errorDescription: String? {
        switch category {
        case .noDevice: "No Spotify device is active. Open Spotify and start playback."
        case .premium: "Spotify playback control needs Premium."
        case .ownerPremium: "Spotify requires the owner of this Runes connection to have Premium. Ask the app owner to check their Spotify developer account."
        case .appAccess: "Spotify has not allowed your account to use this Runes connection. Ask the app owner to add your Spotify account in their Spotify Developer Dashboard."
        case .possibleAppAccess: "Spotify suggests your account may be missing from this app’s allowed users. Ask the app owner to check your Spotify account in their Developer Dashboard."
        case .scope: "Spotify has not granted the permissions this action needs. Disconnect and reconnect Spotify."
        case .restricted: "Spotify does not allow this action on the current playback device. Try another action or device."
        case .unauthorized: "Spotify sign-in expired. Reconnect in the action’s settings."
        case .rateLimited: "Spotify is rate limiting. Try again shortly."
        case .forbidden:
            endpoint == "/v1/me"
                ? "Spotify denied account access (403). Ask the app owner to check the app’s allowed users and Premium requirement."
                : "Spotify denied this action (403). Use Check connection in the Spotify action’s settings to check account access."
        case .other: "Spotify returned \(status). Try again shortly."
        }
    }
}

/// Deliberately contains no tokens, headers, account/device IDs, query values or content.
struct SpotifyDiagnosticRecord: Codable {
    let date: Date
    let method: String
    let endpoint: String
    let status: Int
    let category: String
    let reason: String?

    init(method: String, endpoint: String, status: Int, failure: SpotifyHTTPFailure?, date: Date = Date()) {
        self.date = date
        self.method = ["GET", "PUT", "POST", "DELETE"].contains(method) ? method : "OTHER"
        self.endpoint = Self.safeEndpoint(endpoint)
        self.status = status
        category = failure?.category.rawValue ?? "success"
        reason = failure?.reason
    }

    static func safeEndpoint(_ value: String) -> String {
        let path = URLComponents(string: value)?.path ?? ""
        let known: Set<String> = ["/api/token", "/v1/me", "/v1/me/player", "/v1/me/player/devices", "/v1/me/player/play", "/v1/me/player/pause", "/v1/me/player/next", "/v1/me/player/previous", "/v1/me/player/volume", "/v1/me/player/seek", "/v1/me/player/shuffle", "/v1/me/player/repeat", "/v1/me/library", "/v1/me/tracks"]
        return known.contains(path) ? path : "other"
    }
}

struct SpotifyAuthorizationRecord: Encodable {
    enum Event: String, Encodable, CaseIterable {
        case started = "authorization_started"
        case callbackAccepted = "callback_accepted"
        case callbackRejected = "callback_rejected"
        case authorizationDenied = "authorization_denied"
        case tokenExchangeStarted = "token_exchange_started"
        case tokenTransportFailed = "token_transport_failed"
    }
    enum TransportFailure: String, CaseIterable {
        case timeout, offline, cancelled, other
        init(_ error: Error) {
            let error = error as NSError
            guard error.domain == NSURLErrorDomain else { self = .other; return }
            switch error.code {
            case NSURLErrorTimedOut: self = .timeout
            case NSURLErrorNotConnectedToInternet: self = .offline
            case NSURLErrorCancelled: self = .cancelled
            default: self = .other
            }
        }
    }
    let date: Date
    let event: Event
    private let reason: String?

    init(_ event: Event, date: Date = Date()) { self.date = date; self.event = event; reason = nil }
    init(rejection: SpotifyCallbackRejection, date: Date = Date()) {
        self.date = date; event = .callbackRejected; reason = rejection.rawValue
    }
    init(transportFailure: TransportFailure, date: Date = Date()) {
        self.date = date; event = .tokenTransportFailed; reason = transportFailure.rawValue
    }
}

/// Separate from the band journal because Spotify runs on the main actor, not its session thread.
/// Two 64 KiB segments, excluded from backups; diagnostics must never stop a command.
@MainActor
enum SpotifyDiagnosticLog {
    static func record(method: String, endpoint: String, status: Int, failure: SpotifyHTTPFailure?) {
        write(SpotifyDiagnosticRecord(method: method, endpoint: endpoint, status: status, failure: failure))
    }
    static func record(authorization: SpotifyAuthorizationRecord) { write(authorization) }

    private static func write(_ record: some Encodable) {
        do {
            let manager = FileManager.default
            var directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("SpotifyDiagnostics", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let current = directory.appendingPathComponent("current.jsonl")
            let previous = directory.appendingPathComponent("previous.jsonl")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(record)
            data.append(10)
            let size = (try? manager.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > 64 * 1024 {
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                if manager.fileExists(atPath: current.path) { try manager.moveItem(at: current, to: previous) }
            }
            if !manager.fileExists(atPath: current.path) {
                var attributes: [FileAttributeKey: Any] = [:]
                #if os(iOS)
                attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
                #endif
                guard manager.createFile(atPath: current.path, contents: nil, attributes: attributes) else { return }
            }
            let handle = try FileHandle(forWritingTo: current); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } catch { /* No response content or credentials are logged even when logging fails. */ }
    }
}
