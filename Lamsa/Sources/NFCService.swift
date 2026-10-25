import Foundation
import CoreNFC
import SwiftUI

struct TagInfo: Codable, Hashable, Identifiable {
    var id = UUID()
    var date = Date()
    var tagType: String
    var uid: String
    var tech: String
    var standard: String
    var capacity: Int
    var used: Int
    var writable: Bool
    var lockable: Bool
    var passwordProtected: Bool?
    var signature: String?
    var records: [NDEFRecord]
    var dump: Data?
}

enum NFCOp {
    case read
    case write([NDEFRecord], batch: Bool, password: Data?)
    case erase, format, lock
    case dump(password: Data?)
    case setPassword(Data), removePassword(Data)
}

@MainActor
final class NFCService: NSObject, ObservableObject {
    @Published var lastTag: TagInfo?
    @Published var lastError: String?
    @Published var lastMessage: String?
    @Published var batchCount = 0
    @Published var busy = false
    var onRead: ((TagInfo) -> Void)?

    private var session: NFCTagReaderSession?
    private var op: NFCOp = .read

    static var available: Bool { NFCTagReaderSession.readingAvailable }

    func start(_ op: NFCOp) {
        lastError = nil; lastMessage = nil
        guard NFCService.available else { lastError = L("err.unavailable"); return }
        self.op = op; batchCount = 0
        session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693, .iso18092], delegate: self, queue: nil)
        session?.alertMessage = prompt(op)
        session?.begin(); busy = true
    }

    private func prompt(_ op: NFCOp) -> String {
        switch op {
        case .read: L("nfc.prompt.read")
        case .write(_, let b, _): b ? L("nfc.prompt.batch") : L("nfc.prompt.write")
        case .erase, .format: L("nfc.prompt.erase")
        case .lock: L("nfc.prompt.lock")
        case .dump: L("nfc.prompt.dump")
        case .setPassword, .removePassword: L("nfc.prompt.password")
        }
    }
}

extension NFCService: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}
    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let code = (error as? NFCReaderError)?.code
        Task { @MainActor in
            self.busy = false
            if code != .readerSessionInvalidationErrorUserCanceled && code != .readerSessionInvalidationErrorFirstNDEFTagRead && self.lastMessage == nil && self.batchCount == 0 {
                self.lastError = error.localizedDescription
            }
        }
    }
    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        if tags.count > 1 { session.alertMessage = L("nfc.many"); session.restartPolling(); return }
        Task { @MainActor in await self.handle(session, tag) }
    }

    private func handle(_ session: NFCTagReaderSession, _ tag: NFCTag) async {
        do {
            try await session.connect(to: tag)
            var info = describe(tag)
            let ndef = ndefTag(tag)
            var mifare: NFCMiFareTag? = nil
            if case .miFare(let m) = tag, m.mifareFamily == .ultralight { mifare = m }
            var variant: NTAG.Variant?
            if let m = mifare, let v = try? await m.sendMiFareCommand(commandPacket: Data([0x60])) { variant = NTAG.variant(fromVersion: v); if let n = variant?.name { info.tagType = n } }

            switch op {
            case .read:
                try await fillNDEF(&info, ndef)
                if let m = mifare {
                    if let s = try? await m.sendMiFareCommand(commandPacket: Data([0x3C, 0x00])), s.count >= 32 { info.signature = s.hex }
                    if let v = variant, let cfg = v.cfgPage, let r = try? await m.sendMiFareCommand(commandPacket: Data([0x30, UInt8(cfg)])), r.count >= 4 { info.passwordProtected = r[r.startIndex + 3] < UInt8(v.totalPages) }
                }
                finish(session, info, L("nfc.done.read"))
            case .dump(let pwd):
                guard let m = mifare else { throw Msg(L("err.dumpType")) }
                if let p = pwd { _ = try await m.sendMiFareCommand(commandPacket: Data([0x1B]) + p) }
                let pages = variant?.totalPages ?? 16
                var mem = Data()
                var page = 0
                while page < pages { let r = try await m.sendMiFareCommand(commandPacket: Data([0x30, UInt8(page)])); mem.append(r.prefix(min(16, (pages - page) * 4))); page += 4 }
                info.dump = mem
                try? await fillNDEF(&info, ndef)
                finish(session, info, L("nfc.done.dump"))
            case .write(let recs, let batch, let pwd):
                if let p = pwd, let m = mifare { _ = try await m.sendMiFareCommand(commandPacket: Data([0x1B]) + p) }
                guard let t = ndef else { throw Msg(L("err.noNdef")) }
                let (st, cap) = try await t.queryNDEFStatus()
                guard st == .readWrite else { throw Msg(st == .readOnly ? L("err.readOnly") : L("err.noNdef")) }
                let size = NDEF.encode(recs).count
                guard size <= cap else { throw Msg(String(format: L("err.tooBig"), size, cap)) }
                try await t.writeNDEF(NFCNDEFMessage(records: recs.map(\.nfcPayload)))
                if batch {
                    batchCount += 1
                    session.alertMessage = String(format: L("nfc.batch.next"), batchCount)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    session.restartPolling(); return
                }
                info.records = recs; info.used = size; info.capacity = cap
                finish(session, info, L("nfc.done.write"))
            case .erase, .format:
                if case .format = op, let m = mifare {
                    _ = try await m.sendMiFareCommand(commandPacket: Data([0xA2, 0x04, 0x03, 0x00, 0xFE, 0x00]))
                } else {
                    guard let t = ndef else { throw Msg(L("err.noNdef")) }
                    try await t.writeNDEF(NFCNDEFMessage(records: [NFCNDEFPayload(format: .empty, type: Data(), identifier: Data(), payload: Data())]))
                }
                info.records = []
                finish(session, info, L("nfc.done.erase"))
            case .lock:
                guard let t = ndef else { throw Msg(L("err.noNdef")) }
                try await t.writeLock()
                info.writable = false
                finish(session, info, L("nfc.done.lock"))
            case .setPassword(let p), .removePassword(let p):
                guard let m = mifare, let v = variant, let cfg = v.cfgPage else { throw Msg(L("err.pwdType")) }
                let isSet: Bool = { if case .setPassword = op { return true }; return false }()
                if isSet {
                    _ = try await m.sendMiFareCommand(commandPacket: Data([0xA2, UInt8(cfg + 2)]) + p)
                    _ = try await m.sendMiFareCommand(commandPacket: Data([0xA2, UInt8(cfg + 3), 0x00, 0x00, 0x00, 0x00]))
                } else {
                    _ = try await m.sendMiFareCommand(commandPacket: Data([0x1B]) + p)
                }
                let r = try await m.sendMiFareCommand(commandPacket: Data([0x30, UInt8(cfg)]))
                _ = try await m.sendMiFareCommand(commandPacket: Data([0xA2, UInt8(cfg)]) + NTAG.cfg0(r, auth0: isSet ? 0x04 : 0xFF))
                info.passwordProtected = isSet
                finish(session, info, isSet ? L("nfc.done.pwdSet") : L("nfc.done.pwdRemoved"))
            }
        } catch {
            let m = (error as? Msg)?.text ?? error.localizedDescription
            lastError = m
            session.invalidate(errorMessage: m)
        }
    }

    private func finish(_ s: NFCTagReaderSession, _ info: TagInfo, _ msg: String) {
        lastTag = info; lastMessage = msg; onRead?(info)
        s.alertMessage = msg; s.invalidate()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func fillNDEF(_ info: inout TagInfo, _ t: NFCNDEFTag?) async throws {
        guard let t else { return }
        let (st, cap) = try await t.queryNDEFStatus()
        info.capacity = cap; info.writable = st == .readWrite; info.lockable = st == .readWrite
        if st != .notSupported, let msg = try? await t.readNDEF() {
            info.records = msg.records.map { NDEFRecord(tnf: UInt8($0.typeNameFormat.rawValue), type: $0.type, identifier: $0.identifier, payload: $0.payload) }
            info.used = NDEF.encode(info.records).count
        }
    }

    private func ndefTag(_ t: NFCTag) -> NFCNDEFTag? {
        switch t { case .miFare(let x): x; case .iso7816(let x): x; case .feliCa(let x): x; case .iso15693(let x): x; @unknown default: nil }
    }

    private func describe(_ t: NFCTag) -> TagInfo {
        var i = TagInfo(tagType: "", uid: "", tech: "", standard: "", capacity: 0, used: 0, writable: false, lockable: false, records: [])
        switch t {
        case .miFare(let m):
            i.uid = m.identifier.hexColon; i.tech = "NFC-A · ISO 14443-3A"
            switch m.mifareFamily {
            case .ultralight: i.tagType = "MIFARE Ultralight / NTAG"; i.standard = "NFC Forum Type 2"
            case .plus: i.tagType = "MIFARE Plus"; i.standard = "ISO 14443-4"
            case .desfire: i.tagType = "MIFARE DESFire"; i.standard = "NFC Forum Type 4"
            default: i.tagType = "MIFARE"; i.standard = "ISO 14443"
            }
        case .iso7816(let x): i.uid = x.identifier.hexColon; i.tagType = "ISO 7816"; i.tech = "ISO 14443-4 · AID " + x.initialSelectedAID; i.standard = "NFC Forum Type 4"
        case .feliCa(let f): i.uid = f.currentIDm.hexColon; i.tagType = "FeliCa"; i.tech = "NFC-F · System " + f.currentSystemCode.hex; i.standard = "NFC Forum Type 3"
        case .iso15693(let v): i.uid = Data(v.identifier.reversed()).hexColon; i.tagType = "ISO 15693 (ICODE/ST25)"; i.tech = String(format: "NFC-V · IC mfr %d", v.icManufacturerCode); i.standard = "NFC Forum Type 5"
        @unknown default: i.tagType = "?"
        }
        return i
    }
}

struct Msg: Error { let text: String; init(_ t: String) { text = t } }

extension NDEFRecord {
    var nfcPayload: NFCNDEFPayload { NFCNDEFPayload(format: NFCTypeNameFormat(rawValue: tnf) ?? .unknown, type: type, identifier: identifier, payload: payload) }
}
