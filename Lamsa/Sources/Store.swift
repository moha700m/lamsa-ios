import Foundation
import SwiftUI

/// In-app language switching on top of the String Catalog (compiled into ar.lproj / en.lproj).
enum Lang {
    static var code: String { UserDefaults.standard.string(forKey: "lang") ?? "ar" }
    static var bundle: Bundle {
        if let p = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: p) { return b }
        return .main
    }
    static var isRTL: Bool { code == "ar" }
}
func L(_ key: String) -> String { Lang.bundle.localizedString(forKey: key, value: nil, table: nil) }

struct SavedProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var date = Date()
    var records: [NDEFRecord]
}

@MainActor
final class Store: ObservableObject {
    @Published var history: [TagInfo] = [] { didSet { save() } }
    @Published var saved: [SavedProfile] = [] { didSet { save() } }
    @Published var draft: [NDEFRecord] = []
    @Published var copied: [NDEFRecord]?

    private let url: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("lamsa.json")
    }()
    private struct Blob: Codable { var history: [TagInfo]; var saved: [SavedProfile] }
    private var loading = false

    init() {
        loading = true
        if let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(Blob.self, from: d) { history = b.history; saved = b.saved }
        loading = false
    }
    private func save() {
        guard !loading, let d = try? JSONEncoder().encode(Blob(history: Array(history.prefix(200)), saved: saved)) else { return }
        try? d.write(to: url, options: .atomic)
    }
    func add(_ t: TagInfo) { history.insert(t, at: 0) }
}

// MARK: - Record presentation
extension NDEFRecord {
    var parsed: ParsedRecord { NDEF.parse(self) }
    var kindTitle: String {
        switch parsed {
        case .text: L("kind.text")
        case .uri(let u):
            u.hasPrefix("tel:") ? L("kind.phone") : u.hasPrefix("sms:") ? L("kind.sms") : u.hasPrefix("mailto:") ? L("kind.email") : u.hasPrefix("geo:") ? L("kind.location") : u.hasPrefix("shortcuts:") ? L("kind.shortcut") : L("kind.url")
        case .wifi: L("kind.wifi")
        case .vcard: L("kind.contact")
        case .androidApp: L("kind.app")
        case .smartPoster: L("kind.poster")
        case .mime, .external, .unknown: L("kind.custom")
        case .empty: L("kind.empty")
        }
    }
    var icon: String {
        switch parsed {
        case .text: "textformat"
        case .uri(let u): u.hasPrefix("tel:") ? "phone" : u.hasPrefix("sms:") ? "message" : u.hasPrefix("mailto:") ? "envelope" : u.hasPrefix("geo:") ? "mappin.and.ellipse" : u.hasPrefix("shortcuts:") ? "square.stack.3d.up" : "link"
        case .wifi: "wifi"
        case .vcard: "person.crop.rectangle"
        case .androidApp: "app.badge"
        case .smartPoster: "rectangle.on.rectangle"
        case .empty: "circle.dashed"
        default: "curlybraces"
        }
    }
    var summary: String {
        switch parsed {
        case .text(let s, let l): l.isEmpty ? s : "\(s)  [\(l)]"
        case .uri(let u): u.removingPercentEncoding ?? u
        case .wifi(let w): "\(w.ssid) · \(w.auth.rawValue.uppercased())"
        case .vcard(let v): v.split(whereSeparator: \.isNewline).first { $0.hasPrefix("FN:") }.map { String($0.dropFirst(3)) } ?? "vCard"
        case .androidApp(let p): p
        case .smartPoster(let r): r.map { "\($0)" }.joined(separator: " · ")
        case .mime(let t, let d): "\(t) · " + (String(data: d, encoding: .utf8) ?? d.hex)
        case .external(let t, let d): "\(t) · " + d.hex
        case .unknown(let tnf, let t, let d): "TNF \(tnf) \(t) · \(d.hex)"
        case .empty: "—"
        }
    }
    var openURL: URL? {
        switch parsed {
        case .uri(let u): URL(string: u)
        default: nil
        }
    }
}
