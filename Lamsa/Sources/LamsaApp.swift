import SwiftUI
import AppIntents

@main
struct LamsaApp: App {
    @StateObject private var nfc = NFCService()
    @StateObject private var store = Store()
    @AppStorage("lang") private var lang = "ar"
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(nfc).environmentObject(store)
                .environment(\.layoutDirection, lang == "ar" ? .rightToLeft : .leftToRight)
                .environment(\.locale, Locale(identifier: lang == "ar" ? "ar_SA" : "en_US"))
                .id(lang)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear {
                    nfc.onRead = { store.add($0) }
                    #if DEBUG
                    Demo.apply(nfc: nfc, store: store)
                    #endif
                }
        }
    }
}

/// Direction A "instrument" (shared with Tayyar): near-black surfaces, one accent, monospaced readouts.
/// Accent swapped amber → cyan for Lamsa. Contrast on bg: text 17:1, secondary 5.9:1, cyan 10.2:1, black-on-cyan 10:1.
enum Theme {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.051)        // #0B0B0D
    static let surface = Color(red: 0.090, green: 0.094, blue: 0.106)   // #17181B
    static let surface2 = Color(red: 0.114, green: 0.118, blue: 0.133)  // #1D1E22
    static let stroke = Color(red: 0.149, green: 0.153, blue: 0.169)    // #26272B
    static let accent = Color(red: 0.220, green: 0.776, blue: 0.957)    // #38C6F4
    static let text = Color(red: 0.949, green: 0.937, blue: 0.910)      // #F2EFE8
    static let secondary = Color(red: 0.62, green: 0.615, blue: 0.60)
    static let ok = Color(red: 0.204, green: 0.827, blue: 0.600)
    static let danger = Color(red: 1.0, green: 0.353, blue: 0.353)
    static let warn = Color(red: 1.0, green: 0.690, blue: 0.125)
    static func mono(_ size: CGFloat, _ w: Font.Weight = .medium) -> Font { .system(size: size, weight: w, design: .monospaced) }
    enum R { static let s: CGFloat = 12, m: CGFloat = 16, l: CGFloat = 22 }
}

struct Panel<C: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: C
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.R.m))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.m).stroke(Theme.stroke, lineWidth: 1))
    }
}
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: Theme.R.m))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.surface2.opacity(configuration.isPressed ? 0.6 : 1), in: .rect(cornerRadius: Theme.R.m))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.m).stroke(Theme.stroke, lineWidth: 1))
    }
}

struct RootView: View {
    @AppStorage("tab") private var tab = 0
    @EnvironmentObject var nfc: NFCService
    var body: some View {
        TabView(selection: $tab) {
            ReadView().tabItem { Label(L("tab.read"), systemImage: "wave.3.right") }.tag(0)
            WriteView().tabItem { Label(L("tab.write"), systemImage: "square.and.pencil") }.tag(1)
            ToolsView().tabItem { Label(L("tab.tools"), systemImage: "wrench.and.screwdriver") }.tag(2)
            HistoryView().tabItem { Label(L("tab.history"), systemImage: "clock.arrow.circlepath") }.tag(3)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lamsaScan)) { _ in tab = 0; nfc.start(.read) }
        .alert(L("err.title"), isPresented: Binding(get: { nfc.lastError != nil }, set: { if !$0 { nfc.lastError = nil } })) {
            Button(L("ok"), role: .cancel) {}
        } message: { Text(nfc.lastError ?? "") }
    }
}

extension Notification.Name { static let lamsaScan = Notification.Name("lamsaScan") }

// MARK: - Shortcuts / Siri
struct ScanTagIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan NFC tag"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        try? await Task.sleep(nanoseconds: 600_000_000)
        NotificationCenter.default.post(name: .lamsaScan, object: nil)
        return .result()
    }
}
struct LamsaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanTagIntent(), phrases: ["Scan a tag with \(.applicationName)", "اقرأ بطاقة في \(.applicationName)"], shortTitle: "Scan tag", systemImageName: "wave.3.right")
    }
}

#if DEBUG
/// Simulator-only screenshot fixture (simulator has no NFC).
enum Demo {
    @MainActor static func apply(nfc: NFCService, store: Store) {
        let d = UserDefaults.standard
        guard d.bool(forKey: "demo") else { return }
        let recs = [NDEF.uri("https://moha.dev"), NDEF.wifi(WiFiConfig(ssid: "Home-5G", password: "12345678", auth: .wpa2)), NDEF.text(L("demo.text"))]
        var mem = Data([0x04, 0x85, 0xC8, 0xC9, 0x5A, 0x40, 0x2B, 0x80, 0x3B, 0x48, 0x00, 0x00, 0xE1, 0x10, 0x3E, 0x00])
        mem += NDEF.tlvWrap(NDEF.encode(recs)); mem += Data(repeating: 0, count: max(0, 540 - mem.count))
        let t = TagInfo(tagType: "NTAG215", uid: "04:85:C8:5A:40:2B:80", tech: "NFC-A · ISO 14443-3A", standard: "NFC Forum Type 2", capacity: 504, used: NDEF.encode(recs).count, writable: true, lockable: true, passwordProtected: false, signature: String(repeating: "A1B2", count: 16), records: recs, dump: mem)
        if store.history.isEmpty {
            store.history = [t, TagInfo(date: Date().addingTimeInterval(-3600), tagType: "ISO 15693 (ICODE/ST25)", uid: "E0:04:01:50:8A:11:C2:7F", tech: "NFC-V", standard: "NFC Forum Type 5", capacity: 112, used: 40, writable: true, lockable: true, records: [NDEF.vcard(ContactCard(name: "Mohammed", phone: "+966500000000"))])]
            store.saved = [SavedProfile(name: L("demo.profile"), records: Array(recs.prefix(2)))]
        }
        store.draft = Array(recs.prefix(2))
        if d.bool(forKey: "demoResult") { nfc.lastTag = t }
    }
}
#endif
