import SwiftUI
import UniformTypeIdentifiers

struct Header: View {
    var title: String
    @AppStorage("lang") private var lang = "ar"
    var body: some View {
        HStack {
            Text(title).font(.largeTitle.bold()).foregroundStyle(Theme.text)
            Spacer()
            Button { lang = lang == "ar" ? "en" : "ar" } label: {
                Text(lang == "ar" ? "EN" : "ع").font(Theme.mono(15, .bold)).foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44).background(Theme.surface, in: .circle).overlay(Circle().stroke(Theme.stroke))
            }
            .accessibilityLabel(L("a11y.language"))
        }
    }
}

struct ReadView: View {
    @EnvironmentObject var nfc: NFCService
    @EnvironmentObject var store: Store
    @State private var showResult: TagInfo?
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Header(title: L("app.name"))
                    Button { nfc.start(.read) } label: {
                        ZStack {
                            Circle().fill(Theme.surface).overlay(Circle().stroke(Theme.stroke))
                            Circle().stroke(Theme.accent.opacity(0.35), lineWidth: 2).scaleEffect(pulse ? 1.0 : 0.82).opacity(pulse ? 0 : 1)
                            Circle().fill(Theme.accent).padding(44)
                            Image(systemName: "wave.3.right").font(.system(size: 54, weight: .semibold)).foregroundStyle(.black)
                        }
                        .frame(maxWidth: 260).aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("read.start"))
                    .padding(.top, 8)
                    VStack(spacing: 6) {
                        Text(L("read.hint")).font(.title3.bold()).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                        Text(verbatim: "NDEF · ISO 14443 · ISO 15693 · FeliCa").font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                    }
                    if let t = nfc.lastTag {
                        Button { showResult = t } label: {
                            Panel {
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.seal").foregroundStyle(Theme.ok).font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L("read.last")).font(.caption).foregroundStyle(Theme.secondary)
                                        Text(verbatim: t.tagType).font(.headline).foregroundStyle(Theme.text)
                                        Text(verbatim: t.uid).font(Theme.mono(12)).foregroundStyle(Theme.secondary).environment(\.layoutDirection, .leftToRight)
                                    }
                                    Spacer()
                                    Image(systemName: Lang.isRTL ? "chevron.left" : "chevron.right").foregroundStyle(Theme.secondary)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    if !NFCService.available {
                        Text(L("err.unavailable")).font(.footnote).foregroundStyle(Theme.warn).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $showResult) { TagResultView(info: $0) }
            .onChange(of: nfc.lastTag) { _, t in if let t, showResult == nil { showResult = t } }
            .onAppear {
                if !reduceMotion { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true } }
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "demoResult") { showResult = nfc.lastTag }
                #endif
            }
        }
    }
}

struct InfoRow: View {
    var key: String; var value: String; var mono = true
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).font(.subheadline).foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value).font(mono ? Theme.mono(13) : .subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }
}

struct RecordRow: View {
    var record: NDEFRecord
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.kindTitle).font(.headline).foregroundStyle(Theme.text)
                Text(verbatim: record.summary).font(Theme.mono(12)).foregroundStyle(Theme.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TagResultView: View {
    var info: TagInfo
    @EnvironmentObject var nfc: NFCService
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL
    @State private var saveName = ""
    @State private var askSave = false
    @State private var showDump = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Panel {
                    VStack(spacing: 0) {
                        InfoRow(key: L("info.type"), value: info.tagType)
                        Divider().overlay(Theme.stroke)
                        InfoRow(key: L("info.uid"), value: info.uid)
                        Divider().overlay(Theme.stroke)
                        InfoRow(key: L("info.tech"), value: info.tech)
                        Divider().overlay(Theme.stroke)
                        InfoRow(key: L("info.standard"), value: info.standard)
                        Divider().overlay(Theme.stroke)
                        InfoRow(key: L("info.size"), value: "\(info.used) / \(info.capacity) B")
                        Divider().overlay(Theme.stroke)
                        InfoRow(key: L("info.writable"), value: info.writable ? L("yes") : L("no"), mono: false)
                        if let p = info.passwordProtected {
                            Divider().overlay(Theme.stroke)
                            InfoRow(key: L("info.password"), value: p ? L("yes") : L("no"), mono: false)
                        }
                        if let s = info.signature {
                            Divider().overlay(Theme.stroke)
                            InfoRow(key: L("info.signature"), value: String(s.prefix(16)) + "…")
                        }
                    }
                }
                if info.capacity > 0 {
                    ProgressView(value: Double(min(info.used, info.capacity)), total: Double(info.capacity)).tint(Theme.accent)
                        .accessibilityLabel(L("info.size"))
                }
                Text(String(format: L("read.records"), info.records.count)).font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                if info.records.isEmpty { Panel { Text(L("read.empty")).foregroundStyle(Theme.secondary) } }
                ForEach(info.records) { r in
                    Panel {
                        RecordRow(record: r)
                    }
                    .contextMenu {
                        Button(L("action.copyText"), systemImage: "doc.on.doc") { UIPasteboard.general.string = r.summary }
                        if let u = r.openURL { Button(L("action.open"), systemImage: "arrow.up.forward.app") { openURL(u) } }
                    }
                    .onTapGesture { if let u = r.openURL { openURL(u) } }
                }
                if !info.records.isEmpty {
                    Button { nfc.start(.write(info.records, batch: false, password: nil)) } label: { Label(L("action.copyTag"), systemImage: "doc.on.doc") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                HStack(spacing: 10) {
                    Button { askSave = true } label: { Label(L("action.save"), systemImage: "bookmark") }.buttonStyle(SecondaryButtonStyle()).disabled(info.records.isEmpty)
                    Button { store.draft = info.records; UserDefaults.standard.set(1, forKey: "tab") } label: { Label(L("action.edit"), systemImage: "square.and.pencil") }.buttonStyle(SecondaryButtonStyle()).disabled(info.records.isEmpty)
                    ShareLink(item: shareText) { Label(L("action.share"), systemImage: "square.and.arrow.up") }.buttonStyle(SecondaryButtonStyle())
                }
                if info.dump != nil {
                    Button { showDump = true } label: { Label(L("tools.dump"), systemImage: "memorychip") }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle(L("read.result"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDump) { if let d = info.dump { NavigationStack { DumpView(data: d, name: info.tagType) } } }
        .alert(L("action.save"), isPresented: $askSave) {
            TextField(L("save.name"), text: $saveName)
            Button(L("action.save")) { store.saved.insert(SavedProfile(name: saveName.isEmpty ? info.tagType : saveName, records: info.records), at: 0); saveName = "" }
            Button(L("cancel"), role: .cancel) {}
        }
    }
    var shareText: String {
        var s = "\(info.tagType)\nUID: \(info.uid)\n\(info.tech)\n\(info.used)/\(info.capacity) B\n"
        for r in info.records { s += "• \(r.kindTitle): \(r.summary)\n" }
        return s
    }
}

struct DumpView: View {
    var data: Data; var name: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(verbatim: data.pageDump()).font(Theme.mono(13)).foregroundStyle(Theme.text).textSelection(.enabled)
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.layoutDirection, .leftToRight)
        .background(Theme.bg)
        .navigationTitle(L("tools.dump")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("done")) { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ShareLink(L("export.bin"), item: file("bin", data))
                    ShareLink(L("export.hex"), item: file("hex", Data(data.hex.utf8)))
                    ShareLink(L("export.txt"), item: file("txt", Data(data.pageDump().utf8)))
                } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel(L("action.share"))
            }
        }
    }
    func file(_ ext: String, _ d: Data) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "_"))-dump.\(ext)")
        try? d.write(to: u); return u
    }
}
