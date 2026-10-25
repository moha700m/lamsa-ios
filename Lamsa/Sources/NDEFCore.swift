import Foundation

/// Pure NDEF model + codec (no CoreNFC) so it is unit-testable on any platform.
struct NDEFRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var tnf: UInt8
    var type: Data
    var identifier: Data = Data()
    var payload: Data

    enum CodingKeys: String, CodingKey { case tnf, type, identifier, payload }
    static func == (a: NDEFRecord, b: NDEFRecord) -> Bool { a.tnf == b.tnf && a.type == b.type && a.identifier == b.identifier && a.payload == b.payload }
    func hash(into h: inout Hasher) { h.combine(tnf); h.combine(type); h.combine(payload) }

    static let tnfEmpty: UInt8 = 0, tnfWellKnown: UInt8 = 1, tnfMedia: UInt8 = 2, tnfAbsoluteURI: UInt8 = 3, tnfExternal: UInt8 = 4, tnfUnknown: UInt8 = 5

    var typeString: String { String(decoding: type, as: UTF8.self) }
}

enum WiFiAuth: String, Codable, CaseIterable { case open, wpa2, wpa3, wpaWpa2
    var code: UInt16 { switch self { case .open: 0x0001; case .wpa2: 0x0020; case .wpa3: 0x0040; case .wpaWpa2: 0x0022 } }
    static func from(_ c: UInt16) -> WiFiAuth { allCases.first { $0.code == c } ?? (c & 0x0020 != 0 ? .wpa2 : .open) }
}

struct WiFiConfig: Equatable { var ssid: String; var password: String; var auth: WiFiAuth }
struct ContactCard: Equatable { var name = ""; var phone = ""; var email = ""; var org = ""; var title = ""; var url = ""; var address = "" }

/// Decoded meaning of a record, used for display and tests.
enum ParsedRecord: Equatable {
    case text(String, lang: String)
    case uri(String)
    case wifi(WiFiConfig)
    case vcard(String)
    case androidApp(String)
    case mime(String, Data)
    case smartPoster([ParsedRecord])
    case external(String, Data)
    case empty
    case unknown(tnf: UInt8, type: String, payload: Data)
}

enum NDEFError: Error, Equatable { case truncated, chunkedUnsupported, badTLV }

enum NDEF {
    // MARK: URI prefixes (NFC Forum URI RTD 1.0)
    static let uriPrefixes = ["", "http://www.", "https://www.", "http://", "https://", "tel:", "mailto:", "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://", "sftp://", "smb://", "nfs://", "ftp://", "dav://", "news:", "telnet://", "imap:", "rtsp://", "urn:", "pop:", "sip:", "sips:", "tftp:", "btspp://", "btl2cap://", "btgoep://", "tcpobex://", "irdaobex://", "file://", "urn:epc:id:", "urn:epc:tag:", "urn:epc:pat:", "urn:epc:raw:", "urn:epc:", "urn:nfc:"]

    // MARK: Builders
    static func text(_ s: String, lang: String = "ar") -> NDEFRecord {
        let l = Data(lang.utf8)
        var p = Data([UInt8(l.count & 0x3F)]); p.append(l); p.append(Data(s.utf8))
        return NDEFRecord(tnf: NDEFRecord.tnfWellKnown, type: Data("T".utf8), payload: p)
    }
    static func uri(_ s: String) -> NDEFRecord {
        var best = 0
        for (i, p) in uriPrefixes.enumerated() where i > 0 && s.hasPrefix(p) && p.count > uriPrefixes[best].count { best = i }
        var p = Data([UInt8(best)]); p.append(Data(s.dropFirst(uriPrefixes[best].count).utf8))
        return NDEFRecord(tnf: NDEFRecord.tnfWellKnown, type: Data("U".utf8), payload: p)
    }
    static func phone(_ n: String) -> NDEFRecord { uri("tel:" + n.filter { "+0123456789".contains($0) }) }
    static func sms(_ n: String, body: String) -> NDEFRecord {
        var s = "sms:" + n.filter { "+0123456789".contains($0) }
        if !body.isEmpty { s += "?body=" + enc(body) }
        return uri(s)
    }
    static func email(_ to: String, subject: String, body: String) -> NDEFRecord {
        var q: [String] = []
        if !subject.isEmpty { q.append("subject=" + enc(subject)) }
        if !body.isEmpty { q.append("body=" + enc(body)) }
        return uri("mailto:" + to + (q.isEmpty ? "" : "?" + q.joined(separator: "&")))
    }
    static func location(lat: Double, lon: Double) -> NDEFRecord { uri(String(format: "geo:%.6f,%.6f", lat, lon)) }
    static func shortcut(_ name: String) -> NDEFRecord { uri("shortcuts://run-shortcut?name=" + enc(name)) }
    static func androidApp(_ pkg: String) -> NDEFRecord { NDEFRecord(tnf: NDEFRecord.tnfExternal, type: Data("android.com:pkg".utf8), payload: Data(pkg.utf8)) }
    static func mime(_ type: String, _ payload: Data) -> NDEFRecord { NDEFRecord(tnf: NDEFRecord.tnfMedia, type: Data(type.utf8), payload: payload) }
    static func vcard(_ c: ContactCard) -> NDEFRecord {
        var v = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:\(c.name)\r\nN:\(c.name);;;;\r\n"
        if !c.org.isEmpty { v += "ORG:\(c.org)\r\n" }
        if !c.title.isEmpty { v += "TITLE:\(c.title)\r\n" }
        if !c.phone.isEmpty { v += "TEL;TYPE=CELL:\(c.phone)\r\n" }
        if !c.email.isEmpty { v += "EMAIL:\(c.email)\r\n" }
        if !c.url.isEmpty { v += "URL:\(c.url)\r\n" }
        if !c.address.isEmpty { v += "ADR:;;\(c.address);;;;\r\n" }
        v += "END:VCARD\r\n"
        return mime("text/vcard", Data(v.utf8))
    }
    static func wifi(_ w: WiFiConfig) -> NDEFRecord {
        func tlv(_ t: UInt16, _ v: Data) -> Data { var d = Data([UInt8(t >> 8), UInt8(t & 0xFF), UInt8(v.count >> 8), UInt8(v.count & 0xFF)]); d.append(v); return d }
        func u16(_ x: UInt16) -> Data { Data([UInt8(x >> 8), UInt8(x & 0xFF)]) }
        var cred = tlv(0x1026, Data([1]))
        cred += tlv(0x1045, Data(w.ssid.utf8))
        cred += tlv(0x1003, u16(w.auth.code))
        cred += tlv(0x100F, u16(w.auth == .open ? 0x0001 : 0x0008))
        cred += tlv(0x1027, Data(w.password.utf8))
        cred += tlv(0x1020, Data(repeating: 0xFF, count: 6))
        return mime("application/vnd.wfa.wsc", tlv(0x100E, cred))
    }
    private static func enc(_ s: String) -> String {
        var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "&=?+")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }

    // MARK: Parsing
    static func parse(_ r: NDEFRecord) -> ParsedRecord {
        let p = r.payload
        switch r.tnf {
        case NDEFRecord.tnfEmpty: return .empty
        case NDEFRecord.tnfWellKnown:
            switch r.typeString {
            case "T":
                guard let st = p.first else { return .text("", lang: "") }
                let ll = Int(st & 0x3F); guard p.count >= 1 + ll else { return .text("", lang: "") }
                let lang = String(decoding: p.subdata(in: 1..<(1 + ll)), as: UTF8.self)
                let body = p.subdata(in: (1 + ll)..<p.count)
                let s = (st & 0x80) != 0 ? (String(data: body, encoding: .utf16BigEndian) ?? String(data: body, encoding: .utf16) ?? "") : String(decoding: body, as: UTF8.self)
                return .text(s, lang: lang)
            case "U":
                guard let c = p.first else { return .uri("") }
                let pre = Int(c) < uriPrefixes.count ? uriPrefixes[Int(c)] : ""
                return .uri(pre + String(decoding: p.dropFirst(), as: UTF8.self))
            case "Sp":
                return .smartPoster(((try? decode(p)) ?? []).map(parse))
            default: return .unknown(tnf: r.tnf, type: r.typeString, payload: p)
            }
        case NDEFRecord.tnfMedia:
            let t = r.typeString.lowercased()
            if t == "application/vnd.wfa.wsc", let w = parseWiFi(p) { return .wifi(w) }
            if t == "text/vcard" || t == "text/x-vcard" { return .vcard(String(decoding: p, as: UTF8.self)) }
            return .mime(r.typeString, p)
        case NDEFRecord.tnfAbsoluteURI: return .uri(r.typeString)
        case NDEFRecord.tnfExternal:
            if r.typeString == "android.com:pkg" { return .androidApp(String(decoding: p, as: UTF8.self)) }
            return .external(r.typeString, p)
        default: return .unknown(tnf: r.tnf, type: r.typeString, payload: p)
        }
    }

    static func parseWiFi(_ d: Data) -> WiFiConfig? {
        func tlvs(_ d: Data) -> [(UInt16, Data)] {
            var out: [(UInt16, Data)] = []; var i = d.startIndex
            while i + 4 <= d.endIndex {
                let t = UInt16(d[i]) << 8 | UInt16(d[i + 1]); let l = Int(d[i + 2]) << 8 | Int(d[i + 3])
                guard i + 4 + l <= d.endIndex else { break }
                out.append((t, d.subdata(in: (i + 4)..<(i + 4 + l)))); i += 4 + l
            }
            return out
        }
        guard let cred = tlvs(d).first(where: { $0.0 == 0x100E })?.1 else { return nil }
        var w = WiFiConfig(ssid: "", password: "", auth: .open)
        for (t, v) in tlvs(cred) {
            switch t {
            case 0x1045: w.ssid = String(decoding: v, as: UTF8.self)
            case 0x1027: w.password = String(decoding: v, as: UTF8.self)
            case 0x1003 where v.count == 2: w.auth = WiFiAuth.from(UInt16(v[v.startIndex]) << 8 | UInt16(v[v.startIndex + 1]))
            default: break
            }
        }
        return w
    }

    // MARK: Binary message codec (NFC Forum NDEF 1.0)
    static func encode(_ records: [NDEFRecord]) -> Data {
        var out = Data()
        for (i, r) in records.enumerated() {
            let sr = r.payload.count < 256, il = !r.identifier.isEmpty
            var h: UInt8 = r.tnf & 0x07
            if i == 0 { h |= 0x80 }
            if i == records.count - 1 { h |= 0x40 }
            if sr { h |= 0x10 }
            if il { h |= 0x08 }
            out.append(h); out.append(UInt8(r.type.count))
            if sr { out.append(UInt8(r.payload.count)) } else { let n = UInt32(r.payload.count); out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]) }
            if il { out.append(UInt8(r.identifier.count)) }
            out.append(r.type); out.append(r.identifier); out.append(r.payload)
        }
        return out
    }

    static func decode(_ data: Data) throws -> [NDEFRecord] {
        let d = [UInt8](data); var i = 0; var out: [NDEFRecord] = []
        func need(_ n: Int) throws { if i + n > d.count { throw NDEFError.truncated } }
        while i < d.count {
            try need(2); let h = d[i]; let tl = Int(d[i + 1]); i += 2
            if h & 0x20 != 0 { throw NDEFError.chunkedUnsupported }
            var pl: Int
            if h & 0x10 != 0 { try need(1); pl = Int(d[i]); i += 1 } else { try need(4); pl = Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3]); i += 4 }
            var idl = 0
            if h & 0x08 != 0 { try need(1); idl = Int(d[i]); i += 1 }
            try need(tl + idl + pl)
            let type = Data(d[i..<(i + tl)]); i += tl
            let ident = Data(d[i..<(i + idl)]); i += idl
            let pay = Data(d[i..<(i + pl)]); i += pl
            out.append(NDEFRecord(tnf: h & 0x07, type: type, identifier: ident, payload: pay))
            if h & 0x40 != 0 { break }
        }
        return out
    }

    /// Wraps an NDEF message into a Type 2 TLV (03 len ... FE).
    static func tlvWrap(_ msg: Data) -> Data {
        var d = Data([0x03])
        if msg.count < 0xFF { d.append(UInt8(msg.count)) } else { d.append(contentsOf: [0xFF, UInt8(msg.count >> 8), UInt8(msg.count & 0xFF)]) }
        d.append(msg); d.append(0xFE); return d
    }
    /// Finds the NDEF message TLV inside Type 2 user memory.
    static func tlvExtract(_ mem: Data) throws -> Data {
        let d = [UInt8](mem); var i = 0
        while i < d.count {
            let t = d[i]; i += 1
            if t == 0x00 { continue }
            if t == 0xFE { break }
            guard i < d.count else { throw NDEFError.badTLV }
            var l = Int(d[i]); i += 1
            if l == 0xFF { guard i + 2 <= d.count else { throw NDEFError.badTLV }; l = Int(d[i]) << 8 | Int(d[i + 1]); i += 2 }
            guard i + l <= d.count else { throw NDEFError.badTLV }
            if t == 0x03 { return Data(d[i..<(i + l)]) }
            i += l
        }
        throw NDEFError.badTLV
    }
}

// MARK: NTAG / Ultralight helpers
enum NTAG {
    struct Variant: Equatable { let name: String; let totalPages: Int; let cfgPage: Int?; let userBytes: Int }
    /// Decode GET_VERSION (0x60) response.
    static func variant(fromVersion v: Data) -> Variant? {
        let b = [UInt8](v); guard b.count >= 8 else { return nil }
        switch (b[2], b[6]) {
        case (0x04, 0x0F): return Variant(name: "NTAG213", totalPages: 45, cfgPage: 0x29, userBytes: 144)
        case (0x04, 0x11): return Variant(name: "NTAG215", totalPages: 135, cfgPage: 0x83, userBytes: 504)
        case (0x04, 0x13): return Variant(name: "NTAG216", totalPages: 231, cfgPage: 0xE3, userBytes: 888)
        case (0x04, 0x0B): return Variant(name: "NTAG210", totalPages: 20, cfgPage: 0x10, userBytes: 48)
        case (0x04, 0x0E): return Variant(name: "NTAG212", totalPages: 41, cfgPage: 0x25, userBytes: 128)
        case (0x03, 0x0B): return Variant(name: "MIFARE Ultralight EV1 (MF0UL11)", totalPages: 20, cfgPage: 0x10, userBytes: 48)
        case (0x03, 0x0E): return Variant(name: "MIFARE Ultralight EV1 (MF0UL21)", totalPages: 41, cfgPage: 0x25, userBytes: 128)
        default: return nil
        }
    }
    static func password(_ s: String) -> Data? {
        let hex = s.replacingOccurrences(of: " ", with: "")
        if hex.count == 8, let d = Data(hexString: hex) { return d }
        let u = Data(s.utf8); return u.count == 4 ? u : nil
    }
    /// CFG0 with AUTH0 changed (byte 3).
    static func cfg0(_ page: Data, auth0: UInt8) -> Data { var p = Data(page.prefix(4)); if p.count == 4 { p[p.startIndex + 3] = auth0 }; return p }
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined() }
    var hexColon: String { map { String(format: "%02X", $0) }.joined(separator: ":") }
    init?(hexString: String) {
        let s = hexString.filter { !$0.isWhitespace && $0 != ":" }
        guard s.count % 2 == 0 else { return nil }
        var d = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); guard let b = UInt8(s[i..<j], radix: 16) else { return nil }; d.append(b); i = j }
        self = d
    }
    /// Classic hex dump: page index, 4 bytes, ASCII.
    func pageDump() -> String {
        stride(from: 0, to: count, by: 4).map { o in
            let chunk = self[(startIndex + o)..<Swift.min(startIndex + o + 4, endIndex)]
            let a = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            return String(format: "%03d  ", o / 4) + chunk.map { String(format: "%02X", $0) }.joined(separator: " ") + "  " + a
        }.joined(separator: "\n")
    }
}
