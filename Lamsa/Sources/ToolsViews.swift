import SwiftUI

struct ToolsView: View {
    @EnvironmentObject var nfc: NFCService
    @EnvironmentObject var store: Store
    @State private var confirmErase = false
    @State private var confirmFormat = false
    @State private var lockSheet = false
    @State private var pwdMode: PwdMode?
    @State private var dumpPwd = false
    @State private var copyStep = 0
    @State private var showDump: TagInfo?
    enum PwdMode: String, Identifiable { case set, remove, dump; var id: String { rawValue } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Header(title: L("tab.tools"))
                    section(L("tools.section.tag"))
                    tool("doc.on.doc", L("tools.copy"), copyStep == 1 ? L("tools.copy.step2") : L("tools.copy.desc")) {
                        if copyStep == 1, let r = store.copied { nfc.start(.write(r, batch: false, password: nil)); copyStep = 0 }
                        else { copyStep = 0; nfc.start(.read); awaitingCopy = true }
                    }
                    tool("memorychip", L("tools.dump"), L("tools.dump.desc")) { awaitingDump = true; nfc.start(.dump(password: nil)) }
                    tool("square.stack", L("tools.batch"), L("tools.batch.desc")) { UserDefaults.standard.set(1, forKey: "tab") }
                    section(L("tools.section.protect"))
                    tool("key", L("tools.pwdSet"), L("tools.pwdSet.desc")) { pwdMode = .set }
                    tool("key.slash", L("tools.pwdRemove"), L("tools.pwdRemove.desc")) { pwdMode = .remove }
                    tool("lock", L("tools.lock"), L("tools.lock.desc"), danger: true) { lockSheet = true }
                    section(L("tools.section.reset"))
                    tool("eraser", L("tools.erase"), L("tools.erase.desc")) { confirmErase = true }
                    tool("arrow.counterclockwise", L("tools.format"), L("tools.format.desc")) { confirmFormat = true }
                    Text(L("tools.note")).font(.caption).foregroundStyle(Theme.secondary).padding(.top, 6)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: nfc.lastTag) { _, t in
                guard let t else { return }
                if awaitingCopy { awaitingCopy = false; store.copied = t.records; copyStep = t.records.isEmpty ? 0 : 1 }
                if awaitingDump, t.dump != nil { awaitingDump = false; showDump = t }
            }
            .sheet(item: $showDump) { t in NavigationStack { DumpView(data: t.dump ?? Data(), name: t.tagType) } }
            .confirmationDialog(L("tools.erase"), isPresented: $confirmErase, titleVisibility: .visible) {
                Button(L("tools.erase"), role: .destructive) { nfc.start(.erase) }
            } message: { Text(L("tools.erase.confirm")) }
            .confirmationDialog(L("tools.format"), isPresented: $confirmFormat, titleVisibility: .visible) {
                Button(L("tools.format"), role: .destructive) { nfc.start(.format) }
            } message: { Text(L("tools.format.confirm")) }
            .sheet(isPresented: $lockSheet) { LockConfirm { nfc.start(.lock) }.presentationDetents([.medium, .large]) }
            .sheet(item: $pwdMode) { m in PasswordSheet(mode: m) { p in
                switch m { case .set: nfc.start(.setPassword(p)); case .remove: nfc.start(.removePassword(p)); case .dump: nfc.start(.dump(password: p)) }
            }.presentationDetents([.medium]) }
        }
    }
    @State private var awaitingCopy = false
    @State private var awaitingDump = false
    func section(_ t: String) -> some View { Text(t).font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary).padding(.top, 8) }
    func tool(_ icon: String, _ title: String, _ desc: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Panel {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.title3).foregroundStyle(danger ? Theme.danger : Theme.accent).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline).foregroundStyle(danger ? Theme.danger : Theme.text)
                        Text(desc).font(.footnote).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }.buttonStyle(.plain)
    }
}

/// Strong confirmation: user must type the confirm word before locking (irreversible).
struct LockConfirm: View {
    var lock: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var understood = false
    var word: String { L("lock.word") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L("lock.title"), systemImage: "exclamationmark.triangle.fill").font(.title2.bold()).foregroundStyle(Theme.danger)
            Text(L("lock.body")).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Toggle(L("lock.understand"), isOn: $understood).tint(Theme.danger).foregroundStyle(Theme.text)
            Text(String(format: L("lock.type"), word)).font(.footnote).foregroundStyle(Theme.secondary)
            TextField(word, text: $typed).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.surface, in: .rect(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
            Button { dismiss(); lock() } label: { Text(L("lock.go")) }
                .buttonStyle(PrimaryButtonStyle(tint: ok ? Theme.danger : Theme.surface2)).disabled(!ok)
            Button(L("cancel")) { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(22).frame(maxHeight: .infinity, alignment: .top).background(Theme.bg)
    }
    var ok: Bool { understood && typed.trimmingCharacters(in: .whitespaces).lowercased() == word.lowercased() }
}

struct PasswordSheet: View {
    var mode: ToolsView.PwdMode
    var go: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pwd = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .set ? L("tools.pwdSet") : L("tools.pwdRemove")).font(.title2.bold()).foregroundStyle(Theme.text)
            Text(L("pwd.help")).font(.footnote).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(L("pwd.field"), text: $pwd).font(Theme.mono(17)).textInputAutocapitalization(.never).autocorrectionDisabled()
                .environment(\.layoutDirection, .leftToRight)
                .padding(12).background(Theme.surface, in: .rect(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
            if mode == .set { Text(L("pwd.warn")).font(.footnote).foregroundStyle(Theme.warn) }
            Button { if let p = NTAG.password(pwd) { dismiss(); go(p) } } label: { Text(L("continue")) }
                .buttonStyle(PrimaryButtonStyle(tint: NTAG.password(pwd) == nil ? Theme.surface2 : Theme.accent)).disabled(NTAG.password(pwd) == nil)
        }
        .padding(22).frame(maxHeight: .infinity, alignment: .top).background(Theme.bg)
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nfc: NFCService
    @State private var seg = 0
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Header(title: L("tab.history"))
                    Picker("", selection: $seg) { Text(L("history.scans")).tag(0); Text(L("history.saved")).tag(1) }.pickerStyle(.segmented)
                    if seg == 0 {
                        if store.history.isEmpty { Panel { Text(L("history.empty")).foregroundStyle(Theme.secondary) } }
                        ForEach(store.history) { t in
                            NavigationLink(value: t) {
                                Panel {
                                    HStack(spacing: 12) {
                                        Image(systemName: "wave.3.right").foregroundStyle(Theme.accent).frame(width: 28)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(verbatim: t.tagType).font(.headline).foregroundStyle(Theme.text)
                                            Text(verbatim: t.uid).font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                                            Text(t.date.formatted(.dateTime.locale(Locale(identifier: Lang.code)).day().month().hour().minute()) + " · " + String(format: L("read.records"), t.records.count))
                                                .font(.caption).foregroundStyle(Theme.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button(L("a11y.delete"), systemImage: "trash", role: .destructive) { store.history.removeAll { $0.id == t.id } } }
                        }
                        if !store.history.isEmpty { Button(L("history.clear"), role: .destructive) { store.history = [] }.font(.footnote).frame(maxWidth: .infinity) }
                    } else {
                        if store.saved.isEmpty { Panel { Text(L("saved.empty")).foregroundStyle(Theme.secondary) } }
                        ForEach(store.saved) { p in
                            Panel {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(verbatim: p.name).font(.headline).foregroundStyle(Theme.text)
                                        Spacer()
                                        Text(String(format: L("read.records"), p.records.count)).font(.caption).foregroundStyle(Theme.secondary)
                                    }
                                    ForEach(p.records) { RecordRow(record: $0) }
                                    HStack(spacing: 10) {
                                        Button { nfc.start(.write(p.records, batch: false, password: nil)) } label: { Label(L("write.go"), systemImage: "wave.3.right") }.buttonStyle(PrimaryButtonStyle())
                                        Button { store.draft = p.records; UserDefaults.standard.set(1, forKey: "tab") } label: { Label(L("action.edit"), systemImage: "square.and.pencil") }.buttonStyle(SecondaryButtonStyle())
                                    }
                                }
                            }
                            .contextMenu { Button(L("a11y.delete"), systemImage: "trash", role: .destructive) { store.saved.removeAll { $0.id == p.id } } }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: TagInfo.self) { TagResultView(info: $0) }
            .onAppear {
                #if DEBUG
                if let s = UserDefaults.standard.string(forKey: "demoSeg"), let i = Int(s) { seg = i }
                #endif
            }
        }
    }
}
