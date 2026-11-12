// Temu — akun: menghubungkan Mac ini ke akun Temu dan mengambil pet yang tampil di Mac.
// Aplikasi tidak pernah menyimpan password: token perangkat didapat lewat kode yang disetujui
// di web, lalu disimpan di Keychain. Token itu hanya bisa membaca daftar pet + sapaan teman.

import Cocoa
import Security

// MARK: - Keychain

enum Keychain {
    static let service = "id.local.temu"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Data dari server

struct RemotePet: Codable {
    let id: String
    let name: String
    let sheet_ver: Int
    let owner_name: String
    let mine: Bool
    let sheet_url: String
}

struct RemoteNudge: Codable {
    let id: Int
    let from_name: String
    let text: String
}

struct RemoteUser: Codable {
    let name: String
    let handle: String
}

struct SyncResponse: Codable {
    let user: RemoteUser
    let pets: [RemotePet]
    let nudges: [RemoteNudge]
    let poll_seconds: Int?
}

private struct LinkStart: Codable {
    let code: String
    let poll_token: String
    let url: String
}

private struct LinkPoll: Codable {
    let status: String
    let token: String?
    let user: RemoteUser?
}

/// Seekor pet yang siap tampil: data + gambarnya
struct RosterEntry {
    let id: String
    let name: String
    let ownerName: String
    let mine: Bool
    let skin: Skin
}

// MARK: - Akun

final class Account {
    static let tokenAccount = "device-token"
    static let defaultServer = "https://temu.katili.dev"

    /// Dipanggil di main thread setiap status / daftar pet berubah
    var onChange: (() -> Void)?
    /// Sapaan dari teman (nama, pesan)
    var onNudge: ((String, String) -> Void)?

    private(set) var roster: [RosterEntry] = []
    private(set) var statusText = "Belum terhubung ke akun"
    private(set) var linkCode: String?       // kode yang sedang menunggu persetujuan di web
    private var pollToken: String?
    private var linkTimer: Timer?
    private var linkDeadline = Date.distantPast
    private var syncTimer: Timer?
    private var lastSync = Date.distantPast
    private var syncing = false

    var server: String {
        get {
            let s = (defaults.string(forKey: "server") ?? "").trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? Account.defaultServer : s
        }
        set {
            var s = newValue.trimmingCharacters(in: .whitespaces)
            while s.hasSuffix("/") { s.removeLast() }
            defaults.set(s, forKey: "server")
        }
    }

    private var token: String? { Keychain.get(Account.tokenAccount) }
    var isLinked: Bool { token != nil }
    var userHandle: String { defaults.string(forKey: "accountHandle") ?? "" }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }()

    private var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Temu/sheets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: permintaan

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, auth: Bool = true) -> URLRequest? {
        guard let url = URL(string: server + path), let scheme = url.scheme,
              scheme == "https" || (scheme == "http" && (url.host == "localhost" || url.host == "127.0.0.1")) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let body {
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth, let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return r
    }

    /// Jalankan permintaan; hasil dikembalikan di main thread: (data, status HTTP; 0 = tidak tersambung)
    private func send(_ r: URLRequest?, _ done: @escaping (Data?, Int) -> Void) {
        guard let r else { return done(nil, 0) }
        session.dataTask(with: r) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { done(data, code) }
        }.resume()
    }

    // MARK: mulai

    func start() {
        if isLinked {
            statusText = userHandle.isEmpty ? "Terhubung" : "Terhubung sebagai @\(userHandle)"
            loadCachedRoster()
            sync(force: true)
        }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.sync(force: false) }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        syncTimer = t
    }

    // MARK: menghubungkan (kode disetujui di web)

    func beginLink() {
        cancelLink()
        let name = Host.current().localizedName ?? "Mac"
        statusText = "Meminta kode…"
        onChange?()
        send(request("/api/app/link/start", method: "POST", body: ["device_name": name], auth: false)) { [weak self] data, code in
            guard let self else { return }
            guard code == 201, let data, let start = try? JSONDecoder().decode(LinkStart.self, from: data) else {
                self.statusText = code == 0 ? "Server tidak bisa dihubungi" : "Gagal meminta kode (\(code))"
                self.onChange?()
                return
            }
            self.linkCode = start.code
            self.pollToken = start.poll_token
            self.linkDeadline = Date().addingTimeInterval(600)
            self.statusText = "Setujui kode \(start.code) di browser"
            self.onChange?()
            // hanya buka alamat di server yang sama dengan yang diatur pengguna
            if let u = URL(string: start.url), u.host == URL(string: self.server)?.host { NSWorkspace.shared.open(u) }
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.pollLink() }
            RunLoop.main.add(t, forMode: .common)
            self.linkTimer = t
        }
    }

    func cancelLink() {
        linkTimer?.invalidate()
        linkTimer = nil
        linkCode = nil
        pollToken = nil
    }

    private func pollLink() {
        guard let pollToken else { return }
        if Date() > linkDeadline {
            cancelLink()
            statusText = "Kode kedaluwarsa. Coba hubungkan lagi."
            onChange?()
            return
        }
        send(request("/api/app/link/poll", method: "POST", body: ["poll_token": pollToken], auth: false)) { [weak self] data, code in
            guard let self, self.pollToken == pollToken else { return }
            if code == 410 {
                self.cancelLink()
                self.statusText = "Kode kedaluwarsa. Coba hubungkan lagi."
                self.onChange?()
                return
            }
            guard code == 200, let data, let r = try? JSONDecoder().decode(LinkPoll.self, from: data),
                  r.status == "approved", let token = r.token else { return }
            self.cancelLink()
            Keychain.set(Account.tokenAccount, token)
            defaults.set(r.user?.handle ?? "", forKey: "accountHandle")
            self.statusText = "Terhubung sebagai @\(r.user?.handle ?? "")"
            self.onChange?()
            self.sync(force: true)
        }
    }

    /// Putuskan Mac ini dari akun (token dicabut di server dan dihapus dari Keychain)
    func unlink() {
        send(request("/api/app/unlink", method: "POST", body: [:])) { _, _ in }
        forget("Belum terhubung ke akun")
    }

    private func forget(_ status: String) {
        cancelLink()
        Keychain.delete(Account.tokenAccount)
        defaults.removeObject(forKey: "accountHandle")
        defaults.removeObject(forKey: "roster")
        roster = []
        statusText = status
        onChange?()
    }

    // MARK: sinkron

    /// Ambil daftar pet & sapaan. Tanpa `force`, paling cepat sekali per 45 detik.
    func sync(force: Bool) {
        guard isLinked, !syncing, force || Date().timeIntervalSince(lastSync) > 45 else { return }
        syncing = true
        lastSync = Date()
        send(request("/api/app/sync")) { [weak self] data, code in
            guard let self else { return }
            self.syncing = false
            if code == 401 { // token dicabut dari web
                self.forget("Mac ini sudah diputuskan dari akun")
                return
            }
            guard code == 200, let data, let r = try? JSONDecoder().decode(SyncResponse.self, from: data) else {
                self.statusText = code == 0 ? "Offline — memakai pet tersimpan" : "Server bermasalah (\(code))"
                self.onChange?()
                return
            }
            defaults.set(r.user.handle, forKey: "accountHandle")
            self.statusText = "Terhubung sebagai @\(r.user.handle)"
            if let raw = try? JSONEncoder().encode(r.pets) { defaults.set(raw, forKey: "roster") }
            self.buildRoster(r.pets) {
                for n in r.nudges { self.onNudge?(n.from_name, n.text) }
            }
        }
    }

    private func sheetFile(_ p: RemotePet) -> URL { cacheDir.appendingPathComponent("\(p.id)-\(p.sheet_ver).png") }

    /// Daftar pet terakhir + sheet dari cache, supaya pet langsung muncul saat aplikasi dibuka (juga saat offline)
    private func loadCachedRoster() {
        guard let raw = defaults.data(forKey: "roster"), let pets = try? JSONDecoder().decode([RemotePet].self, from: raw) else { return }
        roster = pets.compactMap { p in
            guard let d = try? Data(contentsOf: sheetFile(p)), let skin = Skin(png: d) else { return nil }
            return RosterEntry(id: p.id, name: p.name, ownerName: p.owner_name, mine: p.mine, skin: skin)
        }
        onChange?()
    }

    /// Unduh sheet yang belum ada di cache, lalu susun daftar pet
    private func buildRoster(_ pets: [RemotePet], then: @escaping () -> Void) {
        var skins: [String: Skin] = [:]
        let group = DispatchGroup()
        for p in pets {
            let file = sheetFile(p)
            if let d = try? Data(contentsOf: file), let skin = Skin(png: d) {
                skins[p.id] = skin
                continue
            }
            // sheet_url dari server hanya dipakai sebagai path di server yang sama
            guard p.sheet_url.hasPrefix("/api/app/pets/") else { continue }
            group.enter()
            send(request(p.sheet_url)) { data, code in
                if code == 200, let data, data.count < 512 * 1024, let skin = Skin(png: data) {
                    try? data.write(to: file, options: .atomic)
                    skins[p.id] = skin
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.roster = pets.compactMap { p in
                skins[p.id].map { RosterEntry(id: p.id, name: p.name, ownerName: p.owner_name, mine: p.mine, skin: $0) }
            }
            self.pruneCache(keep: Set(pets.map { self.sheetFile($0).lastPathComponent }))
            self.onChange?()
            then()
        }
    }

    private func pruneCache(keep: Set<String>) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: cacheDir.path)) ?? [] where !keep.contains(f) {
            try? fm.removeItem(at: cacheDir.appendingPathComponent(f))
        }
    }

    /// Hapus semua data akun di Mac ini (dipakai saat uninstall)
    func wipe() {
        Keychain.delete(Account.tokenAccount)
        try? FileManager.default.removeItem(at: cacheDir.deletingLastPathComponent())
    }
}
