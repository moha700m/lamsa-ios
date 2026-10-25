import SwiftUI
import VisionKit

enum RecordKind: String, CaseIterable, Identifiable {
    case text, url, phone, sms, email, wifi, contact, location, app, shortcut, custom, qr
    var id: String { rawValue }
    var title: String { L("kind." + rawValue) }
    var icon: String {
        switch self {
        case .text: "textformat"; case .url: "link"; case .phone: "phone"; case .sms: "message"; case .email: "envelope"
        case .wifi: "wifi"; case .contact: "person.crop.rectangle"; case .location: "mappin.and.ellipse"; case .app: "app.badge"
        case .shortcut: "square.stack.3d.up"; case .custom: "curlybraces"; case .qr: "qrcode.viewfinder"
        }
    }
}

struct WriteView: View {
    @EnvironmentObject var nfc: NFCService
    @EnvironmentObject var store: Store
    @State private var editing: RecordKind?
    @State private var batch = false
    @State private var usePassword = false
    @State private var password = ""
    @State private var askSave = false
    @State private var saveName = ""
    private let cols = [GridItem(.adaptive(minimum: 96), spacing: 10)]
    var size: Int { NDEF.encode(store.draft).count }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Header(title: L("tab.write"))
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(RecordKind.allCases) { k in
                            Button { editing = k } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: k.icon).font(.title3).foregroundStyle(k == .qr ? Theme.accent : Theme.text)
                                    Text(k.title).font(.caption.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity, minHeight: 72)
                                .background(Theme.surface, in: .rect(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(k == .qr ? Theme.accent.opacity(0.6) : Theme.stroke))
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Text(String(format: L("write.summary"), store.draft.count, size)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                        Spacer()
                        if !store.draft.isEmpty { Button(L("write.clear"), role: .destructive) { store.draft = [] }.font(.footnote) }
                    }
                    if store.draft.isEmpty {
                        Panel { Text(L("write.emptyHint")).foregroundStyle(Theme.secondary) }
                    }
                    ForEach(Array(store.draft.enumerated()), id: \.element.id) { i, r in
                        Panel {
                            HStack {
                                RecordRow(record: r)
                                VStack(spacing: 4) {
                                    Button { if i > 0 { store.draft.swapAt(i, i - 1) } } label: { Image(systemName: "chevron.up").frame(width: 36, height: 30) }.disabled(i == 0).accessibilityLabel(L("a11y.up"))
                                    Button(role: .destructive) { store.draft.remove(at: i) } label: { Image(systemName: "trash").frame(width: 36, height: 30) }.accessibilityLabel(L("a11y.delete"))
                                }.foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    ProgressView(value: Double(min(size, 504)), total: 504).tint(size > 504 ? Theme.danger : Theme.accent)
                    Text(sizeHint).font(.caption).foregroundStyle(Theme.secondary)
                    Panel {
                        VStack(spacing: 10) {
                            Toggle(L("write.batch"), isOn: $batch).tint(Theme.accent)
                            Toggle(L("write.withPassword"), isOn: $usePassword).tint(Theme.accent)
                            if usePassword { SecureField(L("pwd.field"), text: $password).textInputAutocapitalization(.never).font(Theme.mono(15)) }
                        }.foregroundStyle(Theme.text)
                    }
                    Button {
                        nfc.start(.write(store.draft, batch: batch, password: usePassword ? NTAG.password(password) : nil))
                    } label: { Label(batch ? L("write.goBatch") : L("write.go"), systemImage: "wave.3.right") }
                        .buttonStyle(PrimaryButtonStyle(tint: store.draft.isEmpty ? Theme.surface2 : Theme.accent)).disabled(store.draft.isEmpty)
                    if nfc.batchCount > 0 { Text(String(format: L("nfc.batch.next"), nfc.batchCount)).font(.footnote).foregroundStyle(Theme.ok) }
                    Button { askSave = true } label: { Label(L("write.saveProfile"), systemImage: "bookmark") }.buttonStyle(SecondaryButtonStyle()).disabled(store.draft.isEmpty)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $editing) { k in
                NavigationStack { RecordEditor(kind: k) { store.draft.append($0) } }
            }
            .alert(L("write.saveProfile"), isPresented: $askSave) {
                TextField(L("save.name"), text: $saveName)
                Button(L("action.save")) { store.saved.insert(SavedProfile(name: saveName.isEmpty ? L("profile.default") : saveName, records: store.draft), at: 0); saveName = "" }
                Button(L("cancel"), role: .cancel) {}
            }
        }
    }
    var sizeHint: String {
        let s = size
        let t = s <= 137 ? "NTAG213" : s <= 492 ? "NTAG215" : s <= 868 ? "NTAG216" : "> NTAG216"
        return String(format: L("write.fits"), t)
    }
}

struct RecordEditor: View {
    var kind: RecordKind
    var add: (NDEFRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var a = ""; @State private var b = ""; @State private var c = ""
    @State private var auth: WiFiAuth = .wpa2
    @State private var card = ContactCard()
    @State private var lang = Lang.code
    @State private var scanned: String?
    var body: some View {
        Form {
            switch kind {
            case .text:
                Section(L("kind.text")) { TextField(L("field.text"), text: $a, axis: .vertical).lineLimit(3...8); Picker(L("field.lang"), selection: $lang) { Text(verbatim: "العربية").tag("ar"); Text(verbatim: "English").tag("en") } }
            case .url:
                Section(L("kind.url")) { ltr(TextField("https://", text: $a).keyboardType(.URL)) }
            case .phone:
                Section(L("kind.phone")) { ltr(TextField("+9665…", text: $a).keyboardType(.phonePad)) }
            case .sms:
                Section(L("kind.sms")) { ltr(TextField("+9665…", text: $a).keyboardType(.phonePad)); TextField(L("field.message"), text: $b, axis: .vertical) }
            case .email:
                Section(L("kind.email")) { ltr(TextField("name@example.com", text: $a).keyboardType(.emailAddress)); TextField(L("field.subject"), text: $b); TextField(L("field.message"), text: $c, axis: .vertical) }
            case .wifi:
                Section(L("kind.wifi")) {
                    ltr(TextField(L("field.ssid"), text: $a)); ltr(SecureField(L("field.password"), text: $b))
                    Picker(L("field.security"), selection: $auth) { ForEach(WiFiAuth.allCases, id: \.self) { Text(verbatim: $0.rawValue.uppercased()).tag($0) } }
                }
                Section { Text(L("wifi.note")).font(.footnote).foregroundStyle(Theme.secondary) }
            case .contact:
                Section(L("kind.contact")) {
                    TextField(L("field.name"), text: $card.name); ltr(TextField(L("field.phone"), text: $card.phone).keyboardType(.phonePad))
                    ltr(TextField(L("field.email"), text: $card.email).keyboardType(.emailAddress)); TextField(L("field.org"), text: $card.org)
                    TextField(L("field.title"), text: $card.title); ltr(TextField(L("field.website"), text: $card.url).keyboardType(.URL)); TextField(L("field.address"), text: $card.address)
                }
            case .location:
                Section(L("kind.location")) { ltr(TextField(L("field.lat"), text: $a).keyboardType(.numbersAndPunctuation)); ltr(TextField(L("field.lon"), text: $b).keyboardType(.numbersAndPunctuation)) }
            case .app:
                Section(L("kind.app")) { ltr(TextField("https://apps.apple.com/app/id…", text: $a).keyboardType(.URL)); ltr(TextField(L("field.androidPkg"), text: $b)) }
                Section { Text(L("app.note")).font(.footnote).foregroundStyle(Theme.secondary) }
            case .shortcut:
                Section(L("kind.shortcut")) { TextField(L("field.shortcutName"), text: $a) }
                Section { Text(L("shortcut.note")).font(.footnote).foregroundStyle(Theme.secondary) }
            case .custom:
                Section(L("kind.custom")) { ltr(TextField(L("field.mime"), text: $a)); TextField(L("field.payload"), text: $b, axis: .vertical); ltr(TextField(L("field.hex"), text: $c)) }
            case .qr:
                Section {
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        QRScanner { scanned = $0 }.frame(height: 300).listRowInsets(EdgeInsets())
                    } else { Text(L("qr.unavailable")).foregroundStyle(Theme.secondary) }
                }
                if let s = scanned { Section(L("qr.found")) { Text(verbatim: s).font(Theme.mono(13)).textSelection(.enabled) } }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.bg)
        .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button(L("add")) { for r in build() { add(r) }; dismiss() }.disabled(build().isEmpty) }
        }
    }
    func ltr<V: View>(_ v: V) -> some View { v.environment(\.layoutDirection, .leftToRight).multilineTextAlignment(.leading).textInputAutocapitalization(.never).autocorrectionDisabled() }
    func build() -> [NDEFRecord] {
        let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .text: return t.isEmpty ? [] : [NDEF.text(a, lang: lang)]
        case .url: guard !t.isEmpty else { return [] }; return [NDEF.uri(t.contains("://") || t.contains(":") ? t : "https://" + t)]
        case .phone: return t.isEmpty ? [] : [NDEF.phone(t)]
        case .sms: return t.isEmpty ? [] : [NDEF.sms(t, body: b)]
        case .email: return t.isEmpty ? [] : [NDEF.email(t, subject: b, body: c)]
        case .wifi: return t.isEmpty ? [] : [NDEF.wifi(WiFiConfig(ssid: a, password: b, auth: auth))]
        case .contact: return card.name.isEmpty ? [] : [NDEF.vcard(card)]
        case .location: guard let la = Double(t), let lo = Double(b.trimmingCharacters(in: .whitespaces)), abs(la) <= 90, abs(lo) <= 180 else { return [] }; return [NDEF.location(lat: la, lon: lo)]
        case .app:
            var r: [NDEFRecord] = []
            if !t.isEmpty { r.append(NDEF.uri(t)) }
            let p = b.trimmingCharacters(in: .whitespaces); if !p.isEmpty { r.append(NDEF.androidApp(p)) }
            return r
        case .shortcut: return t.isEmpty ? [] : [NDEF.shortcut(t)]
        case .custom:
            guard !t.isEmpty else { return [] }
            let payload = c.isEmpty ? Data(b.utf8) : (Data(hexString: c) ?? Data())
            return [NDEF.mime(t, payload)]
        case .qr:
            guard let s = scanned, !s.isEmpty else { return [] }
            if let w = parseWiFiQR(s) { return [NDEF.wifi(w)] }
            if s.lowercased().hasPrefix("begin:vcard") { return [NDEF.mime("text/vcard", Data(s.utf8))] }
            if let u = URL(string: s), u.scheme != nil { return [NDEF.uri(s)] }
            return [NDEF.text(s, lang: Lang.code)]
        }
    }
    /// WIFI:T:WPA;S:name;P:pass;;
    func parseWiFiQR(_ s: String) -> WiFiConfig? {
        guard s.uppercased().hasPrefix("WIFI:") else { return nil }
        var w = WiFiConfig(ssid: "", password: "", auth: .wpa2)
        for part in s.dropFirst(5).split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1).map(String.init); guard kv.count == 2 else { continue }
            switch kv[0].uppercased() { case "S": w.ssid = kv[1]; case "P": w.password = kv[1]; case "T": w.auth = kv[1].uppercased() == "NOPASS" ? .open : (kv[1].uppercased().contains("SAE") ? .wpa3 : .wpa2); default: break }
        }
        return w.ssid.isEmpty ? nil : w
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var found: (String) -> Void
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let v = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
        v.delegate = context.coordinator; try? v.startScanning(); return v
    }
    func updateUIViewController(_ v: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> C { C(found: found) }
    final class C: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for i in items { if case .barcode(let b) = i, let p = b.payloadStringValue { found(p); UINotificationFeedbackGenerator().notificationOccurred(.success) } }
        }
    }
}
