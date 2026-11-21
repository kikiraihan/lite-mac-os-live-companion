// Temu — akun: menghubungkan Mac ini ke akun Temu dan mengambil pet yang tampil di Mac.
// Aplikasi tidak pernah menyimpan password: token perangkat didapat lewat kode yang disetujui
// di web, lalu disimpan di Keychain. Token itu hanya bisa membaca daftar pet + sapaan teman.
// Sejak chat: token yang sama juga dipakai untuk pesan ke teman (/api/app/messages/…) dan saluran
// real-time WebSocket (/api/app/ws) — tetap hanya /api/app/*.

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
    /// id pemilik pet (untuk chat); kosong di cache lama sebelum ada chat
    let owner_id: String?
}

struct RemoteNudge: Codable {
    let id: Int
    let from_name: String
    let text: String
}

struct RemoteUser: Codable {
    let name: String
    let handle: String
    /// "Sembunyikan status online-ku"; nil di server lama
    let hide_presence: Bool?
}

struct SyncResponse: Codable {
    let user: RemoteUser
    let pets: [RemotePet]
    let nudges: [RemoteNudge]
    let unread: [UnreadEntry]?
    /// semua teman (lawan bicara di popover); kosong di server lama
    let friends: [RemoteFriend]?
    let poll_seconds: Int?
}

struct RemoteFriend: Codable {
    let id: String
    let name: String
    let handle: String
    /// Temu sedang terbuka di minimal satu Mac milik teman ini; nil di server lama
    let online: Bool?
    /// "online" / "away" (Temu terbuka tapi saluran real-time-nya tidak tersambung) / "offline"; nil di server lama
    let presence: String?
}

/// Pesan belum dibaca dari satu teman
struct UnreadEntry: Codable {
    let friend_id: String
    let friend_name: String
    let count: Int
}

/// Satu pesan chat; `mine` = dikirim oleh akun ini (dari Mac mana pun)
struct ChatMessage: Codable {
    let id: Int
    let text: String
    let created_at: String
    let mine: Bool
    /// Hanya pesanku: "sent" ✓, "delivered" ✓✓, "read" ✓✓ biru (nil di server lama / pesan masuk)
    var status: String? = nil
    /// Emot lewat pet ("love", "party", … — Reactions.swift); nil = pesan biasa. `text` berisi emojinya.
    var reaction: String? = nil

    /// Urutan status supaya hanya bisa naik (sent → delivered → read)
    static func rank(_ s: String?) -> Int {
        switch s {
        case "read": return 2
        case "delivered": return 1
        default: return 0
        }
    }

    var date: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: created_at) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: created_at) ?? Date()
    }
}

private struct MessagesResponse: Codable {
    let messages: [ChatMessage]
    let has_more: Bool
}

private struct SentResponse: Codable {
    let message: ChatMessage
}

private struct ErrorResponse: Codable {
    struct Body: Codable { let message: String }
    let error: Body
}

/// Kabar dari saluran real-time (lihat server/internal/app/live.go)
private struct LiveEvent: Codable {
    let type: String
    let friend_id: String?
    let friend_name: String?
    let message: ChatMessage?
    let unread: [UnreadEntry]?
    /// "presence": teman online / offline
    let online: Bool?
    /// "hello": id teman yang sedang online
    let online_friends: [String]?
    /// "receipt": pesanku ke teman ini sampai id ini sudah diterima / dibaca
    let delivered_upto: Int?
    let read_upto: Int?
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
    /// id akun pemilik (kosong untuk pet bawaan); dipakai membuka chat lewat ⌘-klik
    var ownerID = ""
}

// MARK: - Akun

final class Account {
    static let tokenAccount = "device-token"
    static let defaultServer = "https://temu.katili.dev"

    /// Dipanggil di main thread setiap status / daftar pet berubah
    var onChange: (() -> Void)?
    /// Sapaan dari teman (nama, pesan)
    var onNudge: ((String, String) -> Void)?
    /// Pesan chat datang lewat saluran real-time (id teman, pesan) — untuk jendela chat yang terbuka
    var onMessage: ((String, ChatMessage) -> Void)?
    /// Jumlah belum dibaca berubah; argumen = id teman yang baru saja mengirim pesan (bunyi + balon kata), nil = hanya segarkan
    var onUnread: ((String?) -> Void)?
    /// Apakah percakapan dengan teman ini sedang dibaca (jendela chat-nya aktif)
    var isViewing: ((String) -> Bool)?
    /// Status online teman berubah
    var onPresence: (() -> Void)?
    /// Pesanku ke teman sudah diterima / dibaca (id teman, diterima sampai id, dibaca sampai id)
    var onReceipt: ((String, Int?, Int?) -> Void)?
    /// Emot dari teman lewat saluran real-time (id teman, emot) → animasi di atas pet-nya; true = berhasil diputar
    var onReaction: ((String, Reaction) -> Bool)?

    /// Teman yang emotnya baru saja diputar di atas pet: animasinya sudah jadi pemberitahuan, balon kata tidak perlu lagi
    private var reacted: Set<String> = []
    func takeReacted(_ friend: String) -> Bool { reacted.remove(friend) != nil }

    /// Isi pesan masuk terakhir per teman (dari saluran real-time), diambil sekali untuk balon kata pet
    private var lastIncoming: [String: String] = [:]
    func takeIncoming(_ friend: String) -> String? { lastIncoming.removeValue(forKey: friend) }

    /// Pesan belum dibaca per id teman
    private(set) var unread: [String: Int] = [:]
    /// Nama teman yang pernah terlihat (dari pet titipan, kabar pesan, daftar belum dibaca)
    private(set) var friendNames: [String: String] = [:]
    /// Semua teman akun ini (dari sync, disimpan supaya popover langsung terisi saat offline)
    private(set) var friends: [RemoteFriend] = []
    /// id teman yang sedang online (Temu terbuka di Mac-nya); dari sync dan saluran real-time, tidak dari cache
    private(set) var online: Set<String> = []
    /// id teman yang Temu-nya terbuka tapi sambungannya ke server tersendat ("away"); hanya dari sync
    private(set) var away: Set<String> = []
    /// Hasil sync terakhir Mac ini: nil = belum ada, 200 = berhasil, 0 = server tidak terjangkau, selain itu = galat server
    private(set) var lastSyncCode: Int?
    /// Status teman bisa dipercaya: saluran real-time tersambung, atau sync terakhir berhasil.
    /// Kalau tidak, masalahnya di Mac ini / server, bukan teman yang offline.
    var presenceKnown: Bool { liveConnected || lastSyncCode == 200 }
    var unreadTotal: Int { unread.values.reduce(0, +) }
    /// Saluran real-time sedang tersambung (kalau tidak, jendela chat menyegarkan sendiri berkala)
    private(set) var liveConnected = false
    private var liveTask: URLSessionWebSocketTask?
    private var livePing: Timer?
    private var liveRetryTimer: Timer?
    private var liveRetry: TimeInterval = 2

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
    /// Teman selalu melihat akun ini offline (diatur di sini atau di web › Akun; nilai terakhir dari server)
    var hidePresence: Bool { defaults.bool(forKey: "hidePresence") }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }()

    /// Sesi khusus saluran real-time: batas diam lebih panjang dari ping server (25 detik)
    private lazy var liveSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 90
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
            if let raw = defaults.data(forKey: "friends"), let f = try? JSONDecoder().decode([RemoteFriend].self, from: raw) {
                friends = f
                for x in f { friendNames[x.id] = x.name }
            }
            sync(force: true)
            connectLive()
        }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.sync(force: false) }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        syncTimer = t
        // bangun dari tidur: sambungan lama biasanya sudah mati → sambung ulang sekarang
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isLinked else { return }
            self.disconnectLive()
            self.connectLive()
            self.sync(force: true)
        }
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
            self.connectLive()
        }
    }

    /// Putuskan Mac ini dari akun (token dicabut di server dan dihapus dari Keychain)
    func unlink() {
        send(request("/api/app/unlink", method: "POST", body: [:])) { _, _ in }
        forget("Belum terhubung ke akun")
    }

    private func forget(_ status: String) {
        cancelLink()
        disconnectLive()
        unread = [:]
        friendNames = [:]
        friends = []
        online = []
        away = []
        lastSyncCode = nil
        defaults.removeObject(forKey: "friends")
        onUnread?(nil)
        Keychain.delete(Account.tokenAccount)
        defaults.removeObject(forKey: "accountHandle")
        defaults.removeObject(forKey: "hidePresence")
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
                self.lastSyncCode = code == 200 ? 500 : code // 200 tapi isinya tidak terbaca = tetap galat server
                self.onChange?()
                self.onPresence?() // status teman jadi "belum bisa dicek"
                return
            }
            let wasKnown = self.presenceKnown
            self.lastSyncCode = 200
            defaults.set(r.user.handle, forKey: "accountHandle")
            if let h = r.user.hide_presence { defaults.set(h, forKey: "hidePresence") }
            self.statusText = "Terhubung sebagai @\(r.user.handle)"
            if let raw = try? JSONEncoder().encode(r.pets) { defaults.set(raw, forKey: "roster") }
            for p in r.pets where !p.mine { if let o = p.owner_id { self.friendNames[o] = p.owner_name } }
            if let f = r.friends {
                self.friends = f
                for x in f { self.friendNames[x.id] = x.name }
                let away = Set(f.filter { $0.presence == "away" }.map(\.id))
                if away != self.away { self.away = away; self.onPresence?() }
                self.setOnline(Set(f.filter { $0.online == true }.map(\.id)))
                if let raw = try? JSONEncoder().encode(f) { defaults.set(raw, forKey: "friends") }
            }
            if !wasKnown { self.onPresence?() } // status teman kembali bisa dipercaya
            if let u = r.unread { self.applyUnread(u) }
            if !self.liveConnected { self.connectLive() }
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
            return RosterEntry(id: p.id, name: p.name, ownerName: p.owner_name, mine: p.mine, skin: skin, ownerID: p.owner_id ?? "")
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
                skins[p.id].map { RosterEntry(id: p.id, name: p.name, ownerName: p.owner_name, mine: p.mine, skin: $0, ownerID: p.owner_id ?? "") }
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

    // MARK: pesan (chat)

    /// id teman dari server selalu UUID; selain itu tidak dipakai di path
    private func safeID(_ id: String) -> String? {
        id.count == 36 && id.allSatisfy({ $0.isHexDigit || $0 == "-" }) ? id : nil
    }

    private func errorText(_ data: Data?, _ code: Int) -> String {
        if let data, let e = try? JSONDecoder().decode(ErrorResponse.self, from: data) { return e.error.message }
        return code == 0 ? "Server tidak bisa dihubungi. Periksa koneksi internet, lalu coba lagi." : "Gagal (\(code)). Coba lagi sebentar."
    }

    /// 50 pesan terakhir (lama → baru); `before` = id pesan tertua yang sudah ada, untuk halaman sebelumnya
    func loadMessages(_ friend: String, before: Int? = nil, _ done: @escaping ([ChatMessage]?, Bool, String?) -> Void) {
        guard let id = safeID(friend) else { return done(nil, false, "Teman tidak dikenal.") }
        send(request("/api/app/messages/\(id)" + (before.map { "?before=\($0)" } ?? ""))) { [weak self] data, code in
            if code == 401 { self?.sync(force: true) }
            guard code == 200, let data, let r = try? JSONDecoder().decode(MessagesResponse.self, from: data) else {
                return done(nil, false, self?.errorText(data, code))
            }
            done(r.messages, r.has_more, nil)
        }
    }

    func sendMessage(_ friend: String, _ text: String, _ done: @escaping (ChatMessage?, String?) -> Void) {
        postMessage(friend, ["text": text], done)
    }

    /// Emot lewat pet: tersimpan sebagai pesan berisi emojinya, dan diputar di atas pet-ku di Mac teman
    func sendReaction(_ friend: String, _ r: Reaction, _ done: @escaping (ChatMessage?, String?) -> Void) {
        postMessage(friend, ["reaction": r.rawValue], done)
    }

    private func postMessage(_ friend: String, _ body: [String: Any], _ done: @escaping (ChatMessage?, String?) -> Void) {
        guard let id = safeID(friend) else { return done(nil, "Teman tidak dikenal.") }
        send(request("/api/app/messages/\(id)", method: "POST", body: body)) { [weak self] data, code in
            guard code == 201, let data, let r = try? JSONDecoder().decode(SentResponse.self, from: data) else {
                return done(nil, self?.errorText(data, code))
            }
            done(r.message, nil)
        }
    }

    /// Sembunyikan / tampilkan status online akun ini dari teman. `done(nil)` = tersimpan, selain itu pesan galat.
    func setHidePresence(_ hide: Bool, _ done: @escaping (String?) -> Void) {
        send(request("/api/app/presence", method: "PUT", body: ["hidden": hide])) { [weak self] data, code in
            guard code == 200 else { return done(self?.errorText(data, code) ?? "Gagal menyimpan.") }
            defaults.set(hide, forKey: "hidePresence")
            done(nil)
        }
    }

    /// Tandai percakapan sudah dibaca (indikator di menu bar hilang, juga di Mac lain milik akun ini)
    func markRead(_ friend: String) {
        guard let id = safeID(friend) else { return }
        if unread.removeValue(forKey: friend) != nil { onUnread?(nil) }
        send(request("/api/app/messages/\(id)/read", method: "POST", body: [:])) { _, _ in }
    }

    func friendName(_ id: String) -> String { friendNames[id] ?? "Teman" }

    /// Daftar belum dibaca dari server (sync / sambung ulang). Bertambah dibanding sebelumnya = ada pesan baru.
    private func applyUnread(_ list: [UnreadEntry]) {
        var fresh: [String: Int] = [:]
        var newest: String?
        for e in list {
            friendNames[e.friend_id] = e.friend_name
            if isViewing?(e.friend_id) == true { markRead(e.friend_id); continue }
            fresh[e.friend_id] = e.count
            if e.count > (unread[e.friend_id] ?? 0), newest == nil { newest = e.friend_id }
        }
        let changed = fresh != unread
        unread = fresh
        if changed || newest != nil { onUnread?(newest) }
    }

    // MARK: saluran real-time (WebSocket)

    private func connectLive() {
        guard isLinked, liveTask == nil, var r = request("/api/app/ws"), let u = r.url,
              var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return }
        liveRetryTimer?.invalidate()
        liveRetryTimer = nil
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        guard let wsURL = c.url else { return }
        r.url = wsURL
        let task = liveSession.webSocketTask(with: r)
        liveTask = task
        task.resume()
        receive(task)
        let t = Timer(timeInterval: 30, repeats: true) { [weak self, weak task] _ in
            task?.sendPing { err in
                if err != nil { DispatchQueue.main.async { if self?.liveTask === task { self?.liveDropped() } } }
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        livePing = t
    }

    private func disconnectLive() {
        livePing?.invalidate()
        livePing = nil
        liveRetryTimer?.invalidate()
        liveRetryTimer = nil
        liveTask?.cancel(with: .goingAway, reason: nil)
        liveTask = nil
        liveConnected = false
        liveRetry = 2
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.liveTask === task else { return }
                switch result {
                case .success(.string(let s)):
                    self.handleLive(Data(s.utf8))
                    self.receive(task)
                case .success(.data(let d)):
                    self.handleLive(d)
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure:
                    self.liveDropped()
                }
            }
        }
    }

    /// Sambungan putus: coba lagi dengan jeda yang makin panjang (2 detik … 1 menit)
    private func liveDropped() {
        let code = (liveTask?.response as? HTTPURLResponse)?.statusCode ?? 0
        livePing?.invalidate()
        livePing = nil
        liveTask?.cancel()
        liveTask = nil
        liveConnected = false
        onPresence?() // tampilan dibaca ulang; status teman tetap ikut sinkron berkala sampai tersambung lagi
        guard isLinked else { return }
        if code == 401 { return sync(force: true) } // token dicabut → sync yang memutuskan akun
        let wait = liveRetry + Double.random(in: 0...1)
        liveRetry = min(60, liveRetry * 2)
        let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in self?.connectLive() }
        RunLoop.main.add(t, forMode: .common)
        liveRetryTimer = t
    }

    private func handleLive(_ data: Data) {
        guard let ev = try? JSONDecoder().decode(LiveEvent.self, from: data) else { return }
        switch ev.type {
        case "hello":
            liveConnected = true
            liveRetry = 2
            applyUnread(ev.unread ?? [])
            if let o = ev.online_friends { online = Set(o) }
            onPresence?() // status teman kembali bisa dipercaya → titiknya muncul lagi
        case "message":
            guard let friend = ev.friend_id, let m = ev.message else { return }
            if let n = ev.friend_name, !n.isEmpty { friendNames[friend] = n }
            onMessage?(friend, m)
            // emot lewat pet: diputar di atas pet pengirim, juga saat obrolannya sedang dibuka
            let played = !m.mine && (Reaction.find(m.reaction).map { onReaction?(friend, $0) ?? false } ?? false)
            if !m.mine, isViewing?(friend) != true {
                if played { reacted.insert(friend) } else { lastIncoming[friend] = m.text }
                unread[friend, default: 0] += 1
                onUnread?(friend)
            }
        case "read":
            if let friend = ev.friend_id, unread.removeValue(forKey: friend) != nil { onUnread?(nil) }
        case "nudge":
            sync(force: true)
        case "receipt":
            guard let friend = ev.friend_id else { return }
            onReceipt?(friend, ev.delivered_upto, ev.read_upto)
        case "presence":
            guard let friend = ev.friend_id, let on = ev.online else { return }
            var next = online
            if on { next.insert(friend) } else { next.remove(friend) }
            // kabar real-time lebih baru dari sync: "away" baru diketahui lagi di sync berikutnya (≤ 1 menit)
            if away.remove(friend) != nil, next == online { onPresence?() }
            setOnline(next)
        default:
            break
        }
    }

    private func setOnline(_ next: Set<String>) {
        guard next != online else { return }
        online = next
        onPresence?()
    }

    /// Hapus semua data akun di Mac ini (dipakai saat uninstall)
    func wipe() {
        Keychain.delete(Account.tokenAccount)
        try? FileManager.default.removeItem(at: cacheDir.deletingLastPathComponent())
    }
}
