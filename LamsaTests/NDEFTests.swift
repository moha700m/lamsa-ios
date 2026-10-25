import XCTest
@testable import Lamsa

final class NDEFTests: XCTestCase {
    func testTextEncodingLayout() {
        let r = NDEF.text("مرحبا", lang: "ar")
        XCTAssertEqual(r.tnf, 1); XCTAssertEqual(r.type, Data("T".utf8))
        XCTAssertEqual(r.payload.first, 2) // UTF-8, lang length 2
        XCTAssertEqual(r.payload.subdata(in: 1..<3), Data("ar".utf8))
        XCTAssertEqual(NDEF.parse(r), .text("مرحبا", lang: "ar"))
    }
    func testTextUTF16Parse() {
        var p = Data([0x80 | 2]); p += Data("en".utf8); p += "Hi".data(using: .utf16BigEndian)!
        XCTAssertEqual(NDEF.parse(NDEFRecord(tnf: 1, type: Data("T".utf8), payload: p)), .text("Hi", lang: "en"))
    }
    func testURIPrefixCompression() {
        XCTAssertEqual(NDEF.uri("https://www.apple.com").payload.first, 0x02)
        XCTAssertEqual(NDEF.uri("https://moha.dev").payload.first, 0x04)
        XCTAssertEqual(NDEF.uri("tel:+966500000000").payload.first, 0x05)
        XCTAssertEqual(NDEF.uri("geo:1,2").payload.first, 0x00)
        for u in ["https://www.apple.com/x?y=1", "mailto:a@b.co", "urn:nfc:sn:1", "custom://x"] { XCTAssertEqual(NDEF.parse(NDEF.uri(u)), .uri(u)) }
    }
    func testPhoneSmsEmailLocationShortcut() {
        XCTAssertEqual(NDEF.parse(NDEF.phone("+966 50 000 0000")), .uri("tel:+966500000000"))
        XCTAssertEqual(NDEF.parse(NDEF.sms("0500", body: "hi you")), .uri("sms:0500?body=hi%20you"))
        XCTAssertEqual(NDEF.parse(NDEF.email("a@b.co", subject: "S&T", body: "")), .uri("mailto:a@b.co?subject=S%26T"))
        XCTAssertEqual(NDEF.parse(NDEF.location(lat: 24.7136, lon: 46.6753)), .uri("geo:24.713600,46.675300"))
        XCTAssertEqual(NDEF.parse(NDEF.shortcut("Home")), .uri("shortcuts://run-shortcut?name=Home"))
    }
    func testWiFiRoundTrip() {
        let w = WiFiConfig(ssid: "بيت-5G", password: "pa$$word", auth: .wpa2)
        let r = NDEF.wifi(w)
        XCTAssertEqual(r.tnf, 2); XCTAssertEqual(r.typeString, "application/vnd.wfa.wsc")
        XCTAssertEqual(Array(r.payload.prefix(2)), [0x10, 0x0E])
        XCTAssertEqual(NDEF.parse(r), .wifi(w))
        XCTAssertEqual(NDEF.parseWiFi(NDEF.wifi(WiFiConfig(ssid: "o", password: "", auth: .open)).payload)?.auth, .open)
    }
    func testVCardAndApp() {
        let r = NDEF.vcard(ContactCard(name: "محمد", phone: "+966", email: "m@x.sa"))
        guard case .vcard(let v) = NDEF.parse(r) else { return XCTFail() }
        XCTAssertTrue(v.contains("FN:محمد")); XCTAssertTrue(v.hasPrefix("BEGIN:VCARD")); XCTAssertTrue(v.contains("EMAIL:m@x.sa"))
        XCTAssertEqual(NDEF.parse(NDEF.androidApp("com.x.y")), .androidApp("com.x.y"))
        XCTAssertEqual(NDEF.parse(NDEF.mime("application/json", Data("{}".utf8))), .mime("application/json", Data("{}".utf8)))
    }
    func testMessageEncodeDecodeMultiple() throws {
        let recs = [NDEF.uri("https://moha.dev"), NDEF.text("x"), NDEF.wifi(WiFiConfig(ssid: "a", password: "b", auth: .wpa3))]
        let bin = NDEF.encode(recs)
        XCTAssertEqual(bin[0] & 0x80, 0x80); XCTAssertEqual(bin[0] & 0x10, 0x10) // MB + SR on first
        XCTAssertEqual(try NDEF.decode(bin), recs)
    }
    func testKnownBytes() throws {
        // D1 01 08 55 04 6D 6F 68 61 2E 64 65 76 = single short URI "https://moha.dev"
        let bin = Data([0xD1, 0x01, 0x0C, 0x55, 0x04] + Array("moha.dev/a/b".utf8))
        let r = try NDEF.decode(bin)
        XCTAssertEqual(r.count, 1); XCTAssertEqual(NDEF.parse(r[0]), .uri("https://moha.dev/a/b"))
        XCTAssertEqual(NDEF.encode(r), bin)
    }
    func testLongRecordAndIdentifier() throws {
        var r = NDEF.mime("application/octet-stream", Data(repeating: 7, count: 300)); r.identifier = Data("id1".utf8)
        let bin = NDEF.encode([r])
        XCTAssertEqual(bin[0] & 0x10, 0); XCTAssertEqual(bin[0] & 0x08, 0x08)
        XCTAssertEqual(try NDEF.decode(bin), [r])
    }
    func testTruncatedThrows() {
        XCTAssertThrowsError(try NDEF.decode(Data([0xD1, 0x01, 0x10, 0x55, 0x04])))
    }
    func testTLVWrapExtract() throws {
        let msg = NDEF.encode([NDEF.text("hello")])
        let mem = Data([0x01, 0x03, 0xA0, 0x0C, 0x34]) + NDEF.tlvWrap(msg) + Data(repeating: 0, count: 10)
        XCTAssertEqual(try NDEF.tlvExtract(mem), msg)
        let big = Data(repeating: 1, count: 300)
        XCTAssertEqual(try NDEF.tlvExtract(NDEF.tlvWrap(big)), big)
    }
    func testNTAGHelpers() {
        XCTAssertEqual(NTAG.variant(fromVersion: Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x11, 0x03]))?.name, "NTAG215")
        XCTAssertEqual(NTAG.variant(fromVersion: Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03]))?.cfgPage, 0x29)
        XCTAssertEqual(NTAG.password("1234"), Data("1234".utf8))
        XCTAssertEqual(NTAG.password("FFFFFFFF"), Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertNil(NTAG.password("12"))
        XCTAssertEqual(NTAG.cfg0(Data([0x04, 0x00, 0x00, 0xFF, 1, 2, 3, 4]), auth0: 0x04), Data([0x04, 0x00, 0x00, 0x04]))
        XCTAssertEqual(Data([0x04, 0xAB]).hexColon, "04:AB")
        XCTAssertEqual(Data(hexString: "04:ab ff"), Data([0x04, 0xAB, 0xFF]))
        XCTAssertTrue(Data([0x41, 0x42, 0x00, 0x01, 0x43]).pageDump().hasPrefix("000  41 42 00 01  AB.."))
    }
    func testRecordCodableRoundTrip() throws {
        let recs = [NDEF.text("a"), NDEF.uri("https://x.y")]
        XCTAssertEqual(try JSONDecoder().decode([NDEFRecord].self, from: JSONEncoder().encode(recs)), recs)
    }
}
