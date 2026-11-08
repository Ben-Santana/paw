import Foundation

/// Relay pairing and message-format checks. No Bluetooth or Keychain access.
///
///     swiftc -module-cache-path /private/tmp/runes-swift-module-cache RunesIOS/Relay/RelayWire.swift \
///       RunesIOS/Protocol/BandProtocol.swift RunesIOS/Protocol/Wire.swift Tools/RelayProtocolTests.swift -o /private/tmp/runes-relay-tests
///     /private/tmp/runes-relay-tests
@main
struct RelayProtocolTests {
    static func main() throws {
        try checkInvitation()
        let pairing = try checkPairing()
        try checkHandshakeAndSession(pairing)
        try checkStaleAfterRelaunch(pairing)
        try checkEvents(pairing)
        try checkLayout(pairing)
        try checkBandMotion()
        print("Relay protocol checks passed: QR, pairing, one-time token, handshake, binary messages, replay, stale sessions, band motion.")
    }

    static func checkInvitation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let offer = RelayWire.MacPairing(macName: "Ben’s MacBook Pro with a very long name that gets clipped", now: now)
        let text = offer.invitation.text
        precondition(text.hasPrefix("RUNESMAC1:") && text.count < 160, "QR text stays short: \(text.count)")
        let parsed = try RelayWire.Invitation.parse(text, now: now)
        precondition(parsed.macKey == offer.invitation.macKey && parsed.token == offer.invitation.token)
        precondition(parsed.macName.utf8.count <= 32 && parsed.service == offer.invitation.service)
        expect(.expiredInvitation) { _ = try RelayWire.Invitation.parse(text, now: now.addingTimeInterval(121)) }
        expect(.invalidInvitation) { _ = try RelayWire.Invitation.parse("RUNESMAC1:AAAA", now: now) }
        expect(.invalidInvitation) { _ = try RelayWire.Invitation.parse(#"{"kind":"runes-ble-prototype-v1"}"#, now: now) }
        // A future major version is reported as an update, not as a bad code.
        var body = Data(base64Encoded: pad(String(text.dropFirst(11))))!
        body[0] = 2
        expect(.unsupportedVersion) { _ = try RelayWire.Invitation.parse("RUNESMAC1:" + body.base64EncodedString(), now: now) }
        // A QR that claims to live far longer than the Mac ever issues is refused.
        let forever = RelayWire.Invitation(macKey: offer.invitation.macKey, token: offer.invitation.token,
                                           expires: now.addingTimeInterval(86_400), macName: "Mac")
        expect(.expiredInvitation) { _ = try RelayWire.Invitation.parse(forever.text, now: now) }
    }

    static func checkPairing() throws -> RelayWire.Pairing {
        var mac = RelayWire.MacPairing(macName: "Studio")
        let phone = RelayWire.PhonePairing(try RelayWire.Invitation.parse(mac.invitation.text))
        let request = try phone.request(phoneName: "Ben’s iPhone")
        precondition(request.count <= RelayWire.maxPacket)

        // Someone who saw only the advertised pairing service, not the QR, cannot pair.
        var stranger = RelayWire.MacPairing(macName: "Studio")
        expect(.authentication) { _ = try stranger.respond(to: request) }

        var tampered = request
        tampered[40] ^= 1
        var check = mac
        expect(.authentication) { _ = try check.respond(to: tampered) }

        let (accept, macSide, phoneName) = try mac.respond(to: request)
        precondition(phoneName == "Ben’s iPhone")
        let (phoneSide, macName) = try phone.accept(accept)
        precondition(macName == "Studio" && phoneSide == macSide, "Both sides derive the same pairing")
        precondition(phoneSide.secret.count == 32)
        precondition(phoneSide.service != mac.invitation.service, "The link service is not the pairing service")
        // The token is one-time: a replayed or second request is refused.
        expect(.tokenUsed) { _ = try mac.respond(to: request) }
        expect(.tokenUsed) { _ = try phone.accept(RelayWire.MacPairing.reject) }
        // A forged accept, for example from a different Mac, is refused.
        var other = RelayWire.MacPairing(macName: "Studio")
        let otherPhone = RelayWire.PhonePairing(other.invitation)
        let otherAccept = try other.respond(to: try otherPhone.request(phoneName: "x")).accept
        expect(.authentication) { _ = try phone.accept(otherAccept) }

        // Each pairing has its own secret and advertised service, so a phone finds only its own Macs.
        var second = RelayWire.MacPairing(macName: "Studio")
        let again = RelayWire.PhonePairing(second.invitation)
        let repaired = try again.accept(try second.respond(to: try again.request(phoneName: "Ben’s iPhone")).accept).pairing
        precondition(repaired.id != phoneSide.id && repaired.secret != phoneSide.secret && repaired.service != phoneSide.service)
        return phoneSide
    }

    static func handshake(_ pairing: RelayWire.Pairing) throws -> (phone: RelayWire.Session, mac: RelayWire.Session) {
        let phoneNonce = RelayWire.random(16)
        let hello = RelayWire.phoneHello(pairing, nonce: phoneNonce)
        let received = try RelayWire.readPhoneHello(hello, pairing)
        let macNonce = RelayWire.random(16)
        let reply = RelayWire.macHello(pairing, phoneNonce: received, macNonce: macNonce)
        guard let confirmed = try RelayWire.readMacHello(reply, pairing, phoneNonce: phoneNonce) else { preconditionFailure("Hello reply ignored") }
        return (RelayWire.Session(pairing, phoneNonce: phoneNonce, macNonce: confirmed, isPhone: true),
                RelayWire.Session(pairing, phoneNonce: received, macNonce: macNonce, isPhone: false))
    }

    static func checkHandshakeAndSession(_ pairing: RelayWire.Pairing) throws {
        let wrong = RelayWire.Pairing(id: pairing.id, secret: RelayWire.random(32))
        expect(.authentication) { _ = try RelayWire.readPhoneHello(RelayWire.phoneHello(wrong, nonce: RelayWire.random(16)), pairing) }
        let nonce = RelayWire.random(16)
        let forged = RelayWire.macHello(wrong, phoneNonce: nonce, macNonce: RelayWire.random(16))
        expect(.authentication) { _ = try RelayWire.readMacHello(forged, pairing, phoneNonce: nonce) }

        var (phone, mac) = try handshake(pairing)
        precondition(phone.tag == mac.tag)
        let demand = try mac.seal(.demand(.motion))
        try check(try RelayWire.Header(demand) == RelayWire.Header(demand) && demand.count == 10 + 1 + 16)
        try check(try phone.open(demand) == .demand(.motion))
        expect(.replay) { _ = try phone.open(demand) }

        for message: RelayWire.Message in [.ready(.gestures), .ready(nil), .lease(seconds: 25, state: .init(app: .background, band: .streaming)),
                                           .pong(7, .init(app: .foreground, band: .connecting)), .bye(.removed)] {
            try check(try mac.open(try phone.seal(message)) == message, "Round trip \(message)")
        }
        try check(try phone.open(try mac.seal(.ping(65535))) == .ping(65535))

        var bad = try phone.seal(.ready(.gestures))
        bad[bad.count - 1] ^= 1
        expect(.authentication) { _ = try mac.open(bad) }
        // A packet sealed in one direction never opens in the same direction.
        var echo = phone
        expect(.authentication) { _ = try echo.open(try phone.seal(.ping(1))) }
        // Reordering is rejected; a gap (a dropped packet) is not.
        let first = try phone.seal(.ping(1)), second = try phone.seal(.ping(2))
        _ = try phone.seal(.ping(3))
        let fourth = try phone.seal(.ping(4))
        try check(try mac.open(second) == .ping(2))
        expect(.replay) { _ = try mac.open(first) }
        try check(try mac.open(fourth) == .ping(4))

        // Unknown kinds and versions are rejected before any decryption.
        expect(.invalidPacket) { _ = try RelayWire.Header(Data([1, 0x7f, 0, 0, 0, 0])) }
        expect(.unsupportedVersion) { _ = try RelayWire.Header(Data([2, 0x10, 0, 0, 0, 0])) }
        expect(.invalidPacket) { _ = try RelayWire.Header(Data([1])) }
        let tag = try RelayWire.readReset(RelayWire.reset(tag: mac.tag))
        precondition(tag == mac.tag)
    }

    /// iOS can deliver Mac notifications from an earlier session right after relaunching the app in the background.
    /// The first control message after relaunch used to fail to decrypt and tear the link down. Now the phone
    /// recognizes and skips everything that does not belong to the session it is starting.
    static func checkStaleAfterRelaunch(_ pairing: RelayWire.Pairing) throws {
        var (_, oldMac) = try handshake(pairing)
        let staleDemand = try oldMac.seal(.demand(.gestures))
        let staleHello = RelayWire.macHello(pairing, phoneNonce: RelayWire.random(16), macNonce: RelayWire.random(16))

        let nonce = RelayWire.random(16)
        try check(try RelayWire.readMacHello(staleHello, pairing, phoneNonce: nonce) == nil, "A reply to an older hello is ignored")
        let received = try RelayWire.readPhoneHello(RelayWire.phoneHello(pairing, nonce: nonce), pairing)
        let macNonce = RelayWire.random(16)
        let reply = RelayWire.macHello(pairing, phoneNonce: received, macNonce: macNonce)
        let confirmed = try RelayWire.readMacHello(reply, pairing, phoneNonce: nonce)!
        var phone = RelayWire.Session(pairing, phoneNonce: nonce, macNonce: confirmed, isPhone: true)
        var mac = RelayWire.Session(pairing, phoneNonce: received, macNonce: macNonce, isPhone: false)
        try check(try RelayWire.Header(staleDemand).tag != phone.tag, "Stale sealed packets carry another session's tag")
        // The first real control message after relaunch decrypts.
        try check(try phone.open(try mac.seal(.demand(.gestures))) == .demand(.gestures))
    }

    static func checkEvents(_ pairing: RelayWire.Pairing) throws {
        var (phone, mac) = try handshake(pairing)
        let now: TimeInterval = 1000
        let tap = RelayWire.Event(kind: .gesture, sequence: 0x1_0000_0005, timestamp: .max - 1, phoneUptime: now - 0.012,
                                  phoneTime: Date(), gesture: [2, 3, 1, 0])
        let packet = try phone.seal(.event(tap), now: now)
        precondition(packet.count == 10 + 18 + 16, "Gesture packet is \(packet.count) bytes")
        guard case .event(let got) = try mac.open(packet) else { preconditionFailure() }
        precondition(got.kind == .gesture && got.sequence == 5 && got.timestamp == .max - 1 && got.gesture! == [2, 3, 1, 0])
        precondition(abs(got.age - 0.012) < 0.0011 && !got.isRelease)

        let release = RelayWire.Event(kind: .gesture, sequence: 6, timestamp: 1, phoneUptime: now - 5, phoneTime: Date(), gesture: [2, 2, 10, 0])
        guard case .event(let late) = try mac.open(try phone.seal(.event(release), now: now)) else { preconditionFailure() }
        precondition(late.isRelease && late.age == 5, "Releases carry their age but are never dropped for it")

        let gyro = RelayWire.Event(kind: .gyro, sequence: 7, timestamp: 2, phoneUptime: now, phoneTime: Date(), values: [-40000, 0.4, 32767])
        guard case .event(let g) = try mac.open(try phone.seal(.event(gyro), now: now)) else { preconditionFailure() }
        precondition(g.values! == [-32768, 0, 32767])
        let orientation = RelayWire.Event(kind: .orientation, sequence: 8, timestamp: 3, phoneUptime: now, phoneTime: Date(), values: [1, -0.5, 0, 0.25])
        guard case .event(let o) = try mac.open(try phone.seal(.event(orientation), now: now)) else { preconditionFailure() }
        precondition(o.values! == [1, -0.5, 0, 0.25])
        let infinite = RelayWire.Event(kind: .orientation, sequence: 9, timestamp: 3, phoneUptime: now, phoneTime: Date(), values: [.infinity, 0, 0, 0])
        expect(.invalidPacket) { _ = try phone.seal(.event(infinite), now: now) }
        let malformed = RelayWire.Event(kind: .gesture, sequence: 9, timestamp: 3, phoneUptime: now, phoneTime: Date(), gesture: [1])
        expect(.invalidPacket) { _ = try phone.seal(.event(malformed), now: now) }

        precondition(RelayWire.Demand.motion.covers(.gestures) && !RelayWire.Demand.gestures.covers(.motion))
        precondition(RelayWire.Demand.idle.covers(.idle) && RelayWire.Demand.gestures.covers(.idle))
        precondition(RelayWire.Demand.union([.gestures, .init(active: true, gyro: true, orientation: false)]) == .init(active: true, gyro: true, orientation: false))
        precondition(RelayWire.Demand.union([]) == .idle)
    }

    static func checkLayout(_ pairing: RelayWire.Pairing) throws {
        let service = pairing.service
        let roles: [RelayWire.Role] = [.control, .inbound, .bond]
        let ids = Set(roles.map { RelayWire.characteristic($0, of: service) })
        precondition(ids.count == 3 && !ids.contains(service))
        let other = RelayWire.Pairing(id: UUID(), secret: RelayWire.random(32)).service
        precondition(ids.isDisjoint(with: roles.map { RelayWire.characteristic($0, of: other) }))
        precondition(RelayWire.characteristic(.control, of: service) == RelayWire.characteristic(.control, of: service))
        precondition(RelayWire.clip("ééé", 5) == "éé")
    }

    static func checkBandMotion() throws {
        let flags = try Fields(BandProtocol.streamFlags(gyro: true, orientation: true))
        let emg = try flags.integer(2), gesture = try flags.integer(3)
        let gyro = try flags.integer(6), orientation = try flags.integer(8)
        precondition(emg == 0 && gesture == 1 && gyro == 1 && orientation == 1)
        precondition(BandProtocol.gyro(Data([0, 128, 0, 0, 255, 127])) == [-32768, 0, 32767])
        let quaternion = try BandProtocol.orientation(Data([0, 0, 128, 63, 0, 0, 0, 191, 0, 0, 0, 0, 0, 0, 128, 62]))
        precondition(quaternion == [1, -0.5, 0, 0.25])
        do { _ = try BandProtocol.orientation(Data([0, 0, 128, 127] + Array(repeating: 0, count: 12))); preconditionFailure("Expected error") } catch {}
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", line: Int = #line) rethrows {
        let passed = try condition()
        precondition(passed, "\(message()) at line \(line)")
    }

    private static func pad(_ text: String) -> String {
        var body = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        return body
    }

    private static func expect(_ failure: RelayWire.Failure, _ operation: () throws -> Void, line: Int = #line) {
        do {
            try operation()
            preconditionFailure("Expected \(failure) at line \(line)")
        } catch let error as RelayWire.Failure {
            precondition(error == failure, "Expected \(failure), got \(error) at line \(line)")
        } catch {
            preconditionFailure("Expected \(failure), got \(error) at line \(line)")
        }
    }
}
