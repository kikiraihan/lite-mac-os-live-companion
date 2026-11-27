// Temu — enkripsi ujung ke ujung (E2EE) obrolan, tahap 1 (docs/TECH_DEBT.md, server/internal/app/e2e.go).
// Hanya CryptoKit bawaan macOS, tanpa dependensi.
//   kunci Mac  : X25519 (membuka amplop) + Ed25519 (tanda tangan), dibuat di Mac ini, kunci privatnya hanya di
//                Keychain — tidak pernah dikirim ke server. Server hanya menerima kunci publiknya (PUT /api/app/keys).
//   pesan      : isi (JSON) dienkripsi ChaChaPoly dengan kunci acak; kunci itu dibungkus untuk setiap Mac teman dan
//                setiap Mac milikku (X25519 sementara + HKDF-SHA256 + ChaChaPoly), lalu ditandatangani Mac ini.
//   lampiran   : isi file dienkripsi ChaChaPoly dengan kunci acak; kunci, nama & jenis aslinya ada di dalam isi pesan.
// Kunci Mac teman diingat saat pertama terlihat (TOFU): kalau Mac yang sama tiba-tiba punya kunci lain, pesannya ditolak.
// Pesan lama tetap teks biasa.

import CryptoKit
import Foundation

enum E2E {
    static let version = 1
    private static let keyContext = Data("temu-e2e-v1 key\n".utf8)
    private static let msgContext = "temu-e2e-v1 msg\n"
    private static let wrapInfo = Data("temu-e2e-v1 wrap".utf8)

    /// Amplop pesan seperti yang disimpan server (messages.e2e)
    struct Envelope: Codable {
        let v: Int
        let from_device: String
        let ct: String
        let keys: [String: String]
        let sig: String
    }

    /// Kunci publik satu Mac (dari GET /api/app/keys/{teman})
    struct DeviceKey: Codable {
        let device_id: String
        let agree: String
        let sign: String
        let sig: String
    }

    struct KeySet: Codable {
        /// jumlah Mac yang tertaut (lebih banyak dari `keys` = ada Mac yang belum mendukung E2EE)
        let devices: Int
        let keys: [DeviceKey]
        var complete: Bool { devices > 0 && keys.count >= devices }
    }

    struct Directory: Codable {
        let me: String
        let friend: KeySet
        let mine: KeySet
    }

    /// Isi pesan terenkripsi: teks, atau keterangan lampiran
    struct Payload: Codable {
        var text: String? = nil
        /// lampiran: nama & jenis asli + kunci isi filenya (base64)
        var name: String? = nil
        var mime: String? = nil
        var key: String? = nil
        var size: Int? = nil
    }

    enum Failure: Error { case noKeys, badKey, notForMe, badSignature, corrupt }

    // MARK: kunci Mac ini

    /// Kunci Mac ini; dibuat sekali, disimpan di Keychain
    struct Identity {
        let agree: Curve25519.KeyAgreement.PrivateKey
        let sign: Curve25519.Signing.PrivateKey

        static let agreeAccount = "e2e-agree"
        static let signAccount = "e2e-sign"

        static func loadOrCreate() -> Identity {
            if let a = Keychain.get(agreeAccount).flatMap({ Data(base64Encoded: $0) }),
               let s = Keychain.get(signAccount).flatMap({ Data(base64Encoded: $0) }),
               let agree = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: a),
               let sign = try? Curve25519.Signing.PrivateKey(rawRepresentation: s) {
                return Identity(agree: agree, sign: sign)
            }
            let id = Identity(agree: .init(), sign: .init())
            Keychain.set(agreeAccount, id.agree.rawRepresentation.base64EncodedString())
            Keychain.set(signAccount, id.sign.rawRepresentation.base64EncodedString())
            return id
        }

        static func forget() {
            Keychain.delete(agreeAccount)
            Keychain.delete(signAccount)
        }

        /// Badan PUT /api/app/keys: kunci publik + tanda tangan atas kunci X25519-nya
        func publicBody() -> [String: Any]? {
            let agreePub = agree.publicKey.rawRepresentation
            guard let sig = try? sign.signature(for: E2E.keyContext + agreePub) else { return nil }
            return ["agree": agreePub.base64EncodedString(),
                    "sign": sign.publicKey.rawRepresentation.base64EncodedString(),
                    "sig": sig.base64EncodedString()]
        }
    }

    /// Kunci publik Mac lain, sudah dicek tanda tangannya
    struct Peer {
        let device: String
        let agree: Curve25519.KeyAgreement.PublicKey
        let sign: Curve25519.Signing.PublicKey

        init(_ k: DeviceKey) throws {
            guard let a = Data(base64Encoded: k.agree), let s = Data(base64Encoded: k.sign), let sig = Data(base64Encoded: k.sig),
                  let agree = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: a),
                  let sign = try? Curve25519.Signing.PublicKey(rawRepresentation: s),
                  sign.isValidSignature(sig, for: E2E.keyContext + a) else { throw Failure.badKey }
            device = k.device_id.lowercased()
            self.agree = agree
            self.sign = sign
        }
    }

    // MARK: pesan

    private static func signed(from device: String, keys: [String: String], ct: String) -> Data {
        Data((msgContext + device + "\n" + keys.keys.sorted().joined(separator: ",") + "\n" + ct).utf8)
    }

    private static func raw(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    private static func wrapKey(_ shared: SharedSecret, eph: Data, to recipient: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: eph + recipient, sharedInfo: wrapInfo, outputByteCount: 32)
    }

    /// Enkripsi isi pesan untuk Mac-Mac ini (termasuk Mac ini sendiri)
    static func seal(_ payload: Payload, device: String, identity: Identity, to peers: [Peer]) throws -> Envelope {
        let key = SymmetricKey(size: .bits256)
        let body = try JSONEncoder().encode(payload)
        let ct = try ChaChaPoly.seal(body, using: key).combined.base64EncodedString()
        var keys: [String: String] = [:]
        for p in peers {
            let eph = Curve25519.KeyAgreement.PrivateKey()
            let ephPub = eph.publicKey.rawRepresentation
            let shared = try eph.sharedSecretFromKeyAgreement(with: p.agree)
            let wrapped = try ChaChaPoly.seal(raw(key), using: wrapKey(shared, eph: ephPub, to: p.agree.rawRepresentation)).combined
            keys[p.device] = (ephPub + wrapped).base64EncodedString()
        }
        let device = device.lowercased()
        let sig = try identity.sign.signature(for: signed(from: device, keys: keys, ct: ct))
        return Envelope(v: version, from_device: device, ct: ct, keys: keys, sig: sig.base64EncodedString())
    }

    /// Buka pesan untuk Mac ini. `signer` = kunci tanda tangan Mac pengirim.
    static func open(_ env: Envelope, device: String, identity: Identity, signer: Curve25519.Signing.PublicKey) throws -> Payload {
        guard env.v == version else { throw Failure.corrupt }
        guard let sig = Data(base64Encoded: env.sig),
              signer.isValidSignature(sig, for: signed(from: env.from_device, keys: env.keys, ct: env.ct)) else { throw Failure.badSignature }
        guard let wrapped = env.keys[device.lowercased()].flatMap({ Data(base64Encoded: $0) }), wrapped.count == 32 + 12 + 32 + 16 else {
            throw Failure.notForMe
        }
        let ephPub = Data(wrapped.prefix(32))
        let eph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPub)
        let shared = try identity.agree.sharedSecretFromKeyAgreement(with: eph)
        let mine = identity.agree.publicKey.rawRepresentation
        let keyData = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: Data(wrapped.dropFirst(32))),
                                          using: wrapKey(shared, eph: ephPub, to: mine))
        guard let ct = Data(base64Encoded: env.ct) else { throw Failure.corrupt }
        let body = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: ct), using: SymmetricKey(data: keyData))
        return try JSONDecoder().decode(Payload.self, from: body)
    }

    // MARK: lampiran

    /// Kunci acak baru untuk isi satu file (base64, masuk ke isi pesan)
    static func newKey() -> String { raw(SymmetricKey(size: .bits256)).base64EncodedString() }

    static func sealFile(_ data: Data, key: String) throws -> Data {
        guard let k = Data(base64Encoded: key), k.count == 32 else { throw Failure.corrupt }
        return try ChaChaPoly.seal(data, using: SymmetricKey(data: k)).combined
    }

    static func openFile(_ data: Data, key: String) throws -> Data {
        guard let k = Data(base64Encoded: key), k.count == 32 else { throw Failure.corrupt }
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: SymmetricKey(data: k))
    }

    /// Tambahan ukuran file setelah dienkripsi (nonce + tag)
    static let fileOverhead = 12 + 16

    /// Amplop sebagai objek JSON untuk badan permintaan
    static func json(_ env: Envelope) -> Any? {
        (try? JSONEncoder().encode(env)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
}
