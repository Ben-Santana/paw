import Foundation
import CryptoKit

struct MetaLoginRequest: Identifiable, Sendable { let id = UUID(); let url: URL; let nativeToken: String }
struct MetaSession: Sendable { let accessToken: String }

final class MetaService: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let frl = "FRL|388177446008673|083800dd7efbbd42eab18c9886d79c18"
    private static let ar = "AR|306760944872162|a919421a55a8ea18080ab2f10f57f1be"
    private static let hw = "HW|1312539125771114|98588f106d5d542adbf590619ca071fe"
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    // Initialized and used from the MainActor-owned enrollment task only.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func close() { session.invalidateAndCancel() }
    private func lsd() -> [String: String] {
        let text = "S0." + (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
        return ["lsd": text, "jazoest": "2" + String(text.utf8.reduce(0) { $0 + Int($1) })]
    }
    private func text(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else { throw BandError.authentication("Meta response omitted \(key).") }; return value
    }
    private func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))! }
    private func post(_ url: String, _ fields: [String: String], headers: [String: String] = [:], multipart: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if multipart {
            let boundary = "Runes-" + UUID().uuidString
            let body = fields.sorted { $0.key < $1.key }.map { "--\(boundary)\r\nContent-Disposition: form-data; name=\"\($0.key)\"\r\n\r\n\($0.value)\r\n" }.joined() + "--\(boundary)--\r\n"
            request.httpBody = Data(body.utf8); request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        } else {
            request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw BandError.authentication("Meta authentication service rejected the request (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1 << 20 else { throw BandError.authentication("Meta response exceeded the size limit.") }; data.append(byte)
            }
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["error"] == nil else { throw BandError.authentication("Meta returned an invalid or rejected response.") }
            return result
        } catch is CancellationError { throw BandError.cancelled }
        catch let error as BandError { throw error }
        catch { throw BandError.authentication("Meta authentication service is unavailable or returned invalid data.") }
    }
    func prepareLogin() async throws -> MetaLoginRequest {
        let result = try await post("https://meta.graph.meta.com/webview_tokens_query", ["access_token": Self.frl].merging(lsd()) { _, b in b }, headers: ["Origin": "https://auth.meta.com"], multipart: true)
        let native = try text(result, "native_sso_token"), etoken = try text(result, "native_sso_etoken")
        var url = URLComponents(string: "https://auth.meta.com/")!
        url.queryItems = [URLQueryItem(name: "native_app_id", value: "388177446008673"), URLQueryItem(name: "source_app_id", value: "388177446008673"), URLQueryItem(name: "native_sso_etoken", value: etoken)]
        return MetaLoginRequest(url: url.url!, nativeToken: native)
    }
    func finishLogin(_ callback: URL, request: MetaLoginRequest) async throws -> MetaSession {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false), ["fb-viewapp", "oculus"].contains(components.scheme ?? ""), components.host == "frl_login", ["", "/"].contains(components.path), components.user == nil, components.password == nil, components.port == nil else { throw BandError.authentication("Invalid Meta login callback destination.") }
        let items = components.queryItems ?? [], tokens = items.filter { $0.name == "token" }, blobs = items.filter { $0.name == "blob" }
        let expected = SHA256.hash(data: Data(request.nativeToken.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        guard tokens.count == 1, blobs.count == 1, let token = tokens[0].value, let blob = blobs[0].value, !blob.isEmpty, BandCrypto.equal(Data(token.utf8), Data(expected.utf8)) else { throw BandError.authentication("Meta callback does not match this sign-in.") }
        let decrypted = try await post("https://meta.graph.meta.com/webview_blobs_decrypt", ["blob": blob, "request_token": request.nativeToken, "access_token": Self.frl].merging(lsd()) { _, b in b }, headers: ["Origin": "https://auth.meta.com"], multipart: true)
        let frlToken = try text(decrypted, "access_token")
        let result = try await post("https://ar-genai.graph.meta.com/login", ["frl_access_token": frlToken, "logging_session_id": UUID().uuidString, "format": "json", "device_id": UUID().uuidString, "generate_session_cookies": "1", "generate_analytics_claim": "1", "method": "POST"], headers: ["Authorization": "OAuth " + Self.ar])
        guard result["user_id"] is String || result["user_id"] is NSNumber else { throw BandError.authentication("Meta did not return a user identity.") }
        return MetaSession(accessToken: try text(result, "access_token"))
    }
    func complete(_ step: OwnershipStep, session: MetaSession) async throws -> PairCompletion {
        var fields = ["access_token": Self.hw, "user_access_token": session.accessToken, "user_token_universe": "ar", "pair_protocol_version": "3", "method": "post"]
        let endpoint: String, receiptField: String
        switch step {
        case .claim(let certificate, let serial, let secondary, let nonce, let appPoint):
            endpoint = "pair_request"; receiptField = "pending_ownership_receipt"
            fields["device_cert"] = certificate.base64EncodedString(); fields["serial_number"] = serial
            let additional = ["device_nonce": nonce.base64EncodedString(), "app_pubkey": appPoint.base64EncodedString(), "secondary_cert": secondary.base64EncodedString()]
            fields["additional_data"] = String(data: try JSONSerialization.data(withJSONObject: additional, options: [.sortedKeys]), encoding: .utf8)!
        case .pair(let receipt, let signature):
            endpoint = "pair"; receiptField = "final_ownership_receipt"
            fields["device_pending_ownership_receipt"] = receipt; fields["device_pending_ownership_receipt_signature"] = signature.base64EncodedString()
        default: throw BandError.authentication("Invalid enrollment HTTP step.")
        }
        let result = try await post("https://graph.facebook-hardware.com/" + endpoint, fields)
        let receipt = try text(result, receiptField)
        guard let signature = Data(base64Encoded: try text(result, "receipt_signature")), !signature.isEmpty else { throw BandError.authentication("Invalid ownership signature encoding.") }
        var point = try bandPoint(result)
        if point == nil, let object = try? JSONSerialization.jsonObject(with: Data(receipt.utf8)) as? [String: Any] { point = try bandPoint(object) }
        return PairCompletion(signature: signature, receipt: receipt, bandPoint: point)
    }
    private func bandPoint(_ result: [String: Any]) throws -> Data? {
        guard let additional = result["additional_data"] as? [String: Any], let value = additional["device_ec_public_key"] else { return nil }
        guard let text = value as? String, let point = Data(base64Encoded: text), point.count == 64 else { throw BandError.authentication("Invalid band public-key encoding.") }; return point
    }
}
