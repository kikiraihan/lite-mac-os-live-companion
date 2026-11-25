// Temu — popover menu bar (klik kiri ikon). Isinya langsung chat dengan teman:
//   atas   : deretan teman (avatar = pet-nya), titik merah = pesan belum dibaca,
//            titik kecil di pojok bawah avatar = hijau online / abu-abu offline (Temu terbuka di Mac-nya)
//            / oranye tersendat (Temu-nya terbuka tapi sambungannya ke server bermasalah)
//            / cincin kosong = belum bisa dicek (Mac INI yang tidak tersambung ke server)
//   tengah : obrolan + kolom tulis (fokus otomatis, Return = kirim)
//            pesanku: ✓ terkirim, ✓✓ diterima (sampai di Mac teman), ✓✓ biru dibaca
//            tombol 🙂 membuka panel emoji bawaan (Unicode, font emoji sistem); ⌘C/⌘V/⌘A lewat MainMenu.swift
//            tombol ✨ membuka baki emot lewat pet: klik = langsung terkirim, animasinya muncul di atas pet-ku
//            di layar teman (Reactions.swift). Di obrolan emot tampil besar tanpa balon; klik = putar lagi.
//            tombol 📎 mengirim gambar / file (biasa: ada di server sehari; sekali lihat: hilang setelah dibuka) —
//            Attachments.swift
//   bawah  : aksi pet (makan, bola, panggil, tampil/sembunyi) lalu status akun, web, pengaturan, keluar
// Pengaturan › Pesan › "Sembunyikan obrolan": obrolan tertutup jadi satu baris "Obrolan" sampai diklik (privasi).
// Keterangan panjang hanya di tooltip. Klik kanan ikon tetap membuka menu lengkap (native).
// Warna mengikuti docs/DESIGN.md: Stroberi untuk satu aksi utama, teks di atasnya Tinta.

import AppKit
import SwiftUI

enum Brand {
    static let strawberry = Color(red: 1.0, green: 0.353, blue: 0.478) // #FF5A7A aksi utama, hati
    static let ink = Color(red: 0.165, green: 0.129, blue: 0.251)       // #2A2140 teks di atas stroberi
    static let leaf = Color(red: 0.184, green: 0.620, blue: 0.467)      // #2F9E77 terhubung
    static let lemon = Color(red: 1.0, green: 0.824, blue: 0.235)       // #FFD23C sorotan, menunggu
    static let orange = Color(red: 0.969, green: 0.647, blue: 0.322)    // #F7A552 merek
    static let read = Color(red: 0.067, green: 0.341, blue: 0.788)      // #1157C9 centang "dibaca" (kontras di atas stroberi)
}

/// Status teman seperti yang terlihat dari Mac ini
enum Presence: Equatable {
    /// Temu terbuka & tersambung real-time di Mac-nya
    case online
    /// Temu-nya terbuka, tapi sambungan real-time-nya ke server tersendat (masalah jaringan / server di sisinya)
    case away
    /// Temu tertutup / Mac tidur, atau statusnya disembunyikan
    case offline
    /// Belum bisa dicek: Mac INI belum / tidak tersambung ke server (internet, alamat server, server bermasalah)
    case unknown
}

/// Satu lawan bicara di deretan atas
struct ChatFriend: Identifiable, Equatable {
    let id: String
    let name: String
    let handle: String
    let skin: Skin?
    let unread: Int
    /// Temu sedang terbuka di Mac-nya. false = offline atau belum diketahui (titik tetap tampil, abu-abu)
    var presence: Presence = .unknown
    var online: Bool { presence == .online }

    static func == (a: ChatFriend, b: ChatFriend) -> Bool {
        a.id == b.id && a.name == b.name && a.handle == b.handle && a.unread == b.unread && (a.skin == nil) == (b.skin == nil)
            && a.presence == b.presence
    }
}

// MARK: - Model

final class PopoverModel: ObservableObject {
    weak var app: AppDelegate?

    @Published var selected: String?
    @Published private(set) var friends: [ChatFriend] = []
    @Published private(set) var threads: [String: [ChatMessage]] = [:]
    @Published private(set) var hasMore: [String: Bool] = [:]
    @Published var drafts: [String: String] = [:]
    @Published var error: String?
    @Published private(set) var sending = false
    @Published private(set) var loading = false
    /// Naik setiap status aplikasi berubah (akun, update, desktop) supaya tampilan ikut dibaca ulang
    @Published private(set) var revision = 0
    /// Naik setiap popover dibuka → kolom tulis difokuskan
    @Published private(set) var focusToken = 0
    /// Obrolan tinggal di popover samping pet → popover menu bar hanya menampilkan baris pembuka "Obrolan"
    @Published var chatElsewhere = false
    /// Obrolan terlihat. Kalau "Sembunyikan obrolan" nyala, popover dibuka tertutup sampai baris "Obrolan" diklik.
    @Published private(set) var expanded = true

    /// Mode contoh (--demo): data teman & pesan palsu, tanpa server — untuk tangkapan layar CI
    private(set) var demo = false
    private(set) var visible = false
    private var lastUnreadFrom: String?
    private var refreshTimer: Timer?
    /// Emoji yang baru dipakai (paling baru di depan), disimpan di UserDefaults
    @Published private(set) var recentEmoji: [String] = defaults.stringArray(forKey: "recentEmoji") ?? []
    /// Dibuka lewat aksi yang memang meminta obrolan (⌘-klik pet teman, menu "Kirim pesan ke …") → langsung terbuka
    private var revealNext = false
    /// Jeda kecil antar emot supaya klik beruntun tidak membanjiri layar teman
    private var lastReaction = Date.distantPast
    /// Lampiran sedang diunggah
    @Published private(set) var uploading = false
    /// Gambar lampiran yang sudah diunduh (id pesan → gambar), hanya di memori; sekali lihat tidak pernah masuk sini
    @Published private(set) var images: [Int: NSImage] = [:]
    private var imageData: [Int: Data] = [:]
    /// Lampiran yang sedang diunduh / dibuka
    @Published private(set) var fetching: Set<Int> = []

    // MARK: status yang dibaca tampilan

    var linked: Bool { demo || (app?.account.isLinked ?? false) }
    var handle: String { demo ? "kiki" : (app?.account.userHandle ?? "") }
    var statusText: String { demo ? "Terhubung sebagai @kiki" : (app?.account.statusText ?? "") }
    var statusOK: Bool { demo || statusText.hasPrefix("Terhubung") }
    var liveOK: Bool { demo || (app?.account.liveConnected ?? false) }

    /// Keterangan di bawah obrolan untuk teman yang tidak online. Tiga sebab dibedakan:
    /// teman memang offline, Temu teman tersendat (masalah di sisinya), atau Mac INI yang tidak tersambung.
    func presenceNote(_ f: ChatFriend) -> String? {
        switch f.presence {
        case .online:
            return nil
        case .offline:
            return "\(f.name) sedang offline. Pesanmu tetap sampai saat Temu-nya dibuka lagi."
        case .away:
            return "Temu \(f.name) terbuka, tapi sambungannya ke server sedang tersendat. Pesanmu tetap sampai."
        case .unknown:
            switch app?.account.lastSyncCode {
            case nil:
                return "Sedang menyambung ke server… status \(f.name) belum bisa dicek."
            case 0:
                return "Mac ini tidak tersambung ke server, jadi status \(f.name) belum bisa dicek. " +
                    "Cek internet atau alamat server di Pengaturan › Akun."
            case let code?:
                return "Server Temu sedang bermasalah (\(code)), jadi status \(f.name) belum bisa dicek. Coba lagi sebentar lagi."
            }
        }
    }
    var linkCode: String? { demo ? nil : app?.account.linkCode }
    var updateVersion: String? {
        guard let u = app?.updater, u.hasUpdate else { return nil }
        return u.latest?.version
    }
    var hasPets: Bool { !(app?.stage.pets.isEmpty ?? true) }
    var ownSkin: Skin { app?.stage.barPet?.skin ?? Skin.builtin(Prefs.species) }
    var current: ChatFriend? { friends.first { $0.id == selected } }
    var messages: [ChatMessage] { selected.flatMap { threads[$0] } ?? [] }
    var totalUnread: Int { friends.reduce(0) { $0 + $1.unread } }
    /// --demo-hidden: tangkapan layar CI dengan obrolan tertutup
    var hideChat: Bool { Prefs.hideChat || (demo && CommandLine.arguments.contains("--demo-hidden")) }

    func draft(_ id: String) -> String { drafts[id] ?? "" }

    func usedEmoji(_ e: String) {
        recentEmoji = Array(([e] + recentEmoji.filter { $0 != e }).prefix(9))
        if !demo { defaults.set(recentEmoji, forKey: "recentEmoji") }
    }

    // MARK: siklus

    /// Status aplikasi berubah: susun ulang deretan teman, pertahankan pilihan
    func refresh() {
        guard !demo, let app else {
            revision += 1
            return
        }
        let acc = app.account
        var skins: [String: Skin] = [:]
        for p in app.stage.pets where !p.mine && !p.ownerID.isEmpty && skins[p.ownerID] == nil { skins[p.ownerID] = p.skin }
        // titik status selalu tampil: hijau = online, abu-abu = offline / belum diketahui.
        // Tanpa saluran real-time, status tetap ikut sinkron berkala (paling lama ±1 menit tertinggal).
        // Mac ini tidak tersambung ke server → status teman "belum bisa dicek", bukan offline.
        let presence = { (id: String) -> Presence in
            if !acc.presenceKnown { return .unknown }
            if acc.online.contains(id) { return .online }
            return acc.away.contains(id) ? .away : .offline
        }
        var list: [ChatFriend] = acc.friends.map {
            ChatFriend(id: $0.id, name: $0.name, handle: $0.handle, skin: skins[$0.id], unread: acc.unread[$0.id] ?? 0,
                       presence: presence($0.id))
        }
        // server lama tanpa daftar teman: pakai pemilik pet titipan + pengirim pesan
        var known = Set(list.map(\.id))
        for id in Array(skins.keys) + Array(acc.unread.keys) where !known.contains(id) {
            list.append(ChatFriend(id: id, name: acc.friendName(id), handle: "", skin: skins[id], unread: acc.unread[id] ?? 0,
                                   presence: presence(id)))
            known.insert(id)
        }
        // urutan tetap (tidak melompat saat pesan masuk): yang pet-nya tampil di Mac dulu, lalu nama
        list.sort { a, b in
            if (a.skin != nil) != (b.skin != nil) { return a.skin != nil }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if list != friends { friends = list }
        if selected == nil || !known.contains(selected!) { choose() }
        revision += 1
    }

    /// Pilih lawan bicara yang paling masuk akal: pengirim pesan terbaru, lalu obrolan terakhir, lalu teman pertama
    private func choose() {
        let ids = Set(friends.map(\.id))
        if let f = lastUnreadFrom, ids.contains(f), (app?.account.unread[f] ?? 0) > 0 { return select(f) }
        if let f = friends.first(where: { $0.unread > 0 }) { return select(f.id) }
        if let last = defaults.string(forKey: "lastChat"), ids.contains(last) { return select(last) }
        if let f = friends.first { select(f.id) } else { selected = nil }
    }

    func opened() {
        visible = true
        expanded = !hideChat || revealNext
        revealNext = false
        refresh()
        // ada pesan baru dari teman lain sementara obrolan yang terpilih sudah terbaca → pindah ke pengirimnya
        if let f = lastUnreadFrom, f != selected, (app?.account.unread[f] ?? 0) > 0, current?.unread ?? 0 == 0 { select(f) }
        else if let id = selected { load(id); markRead(id) }
        focusToken += 1
        startRefresh()
    }

    func closed() {
        visible = false
        // revealNext tidak direset di sini: popover bisa ditutup lalu dibuka lagi di posisi pet (openChat → showPopover)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func select(_ id: String) {
        if selected != id {
            selected = id
            error = nil
            if !demo { defaults.set(id, forKey: "lastChat") }
        }
        load(id)
        markRead(id)
        focusToken += 1
    }

    /// Popover berikutnya membuka obrolan walau "Sembunyikan obrolan" nyala
    func reveal() { revealNext = true }

    /// Baris "Obrolan" diklik: tampilkan isi obrolan, baru tandai terbaca
    func expand() {
        expanded = true
        if let id = selected { select(id) }
    }

    /// Tutup lagi obrolan (mis. ada orang lewat) tanpa menutup popover
    func collapse() { expanded = false }

    // obrolan tertutup = belum dilihat: pesan tetap dihitung belum dibaca dan bunyi tetap terdengar
    var isViewing: (String) -> Bool { { [weak self] id in (self?.visible ?? false) && (self?.expanded ?? false) && self?.selected == id } }

    private func markRead(_ id: String) {
        guard !demo, visible, expanded, (app?.account.unread[id] ?? 0) > 0 else { return }
        app?.account.markRead(id)
    }

    // MARK: pesan

    private func merge(_ id: String, _ new: [ChatMessage]) {
        var list = threads[id] ?? []
        var index: [Int: Int] = [:]
        for (i, m) in list.enumerated() { index[m.id] = i }
        var changed = false
        var add: [ChatMessage] = []
        for m in new {
            if let i = index[m.id] {
                // pesan yang sudah ada: status centang hanya boleh naik (data lama tidak menurunkannya)
                if ChatMessage.rank(m.status) > ChatMessage.rank(list[i].status) {
                    list[i].status = m.status
                    changed = true
                }
                // lampiran: "sudah dibuka / sudah dihapus" dari server menggantikan keterangan lama
                if let na = m.attachment, let oa = list[i].attachment, oa.available, !na.available {
                    list[i].attachment = na
                    changed = true
                }
            } else {
                add.append(m)
            }
        }
        guard changed || !add.isEmpty else { return }
        if !add.isEmpty { list = (list + add).sorted { $0.id < $1.id } }
        threads[id] = list
    }

    /// Kabar "receipt": pesanku ke teman ini sampai id tertentu sudah diterima (✓✓) / dibaca (✓✓ biru)
    func receipt(_ friend: String, delivered: Int?, read: Int?) {
        guard var list = threads[friend] else { return } // obrolan belum dimuat: status ikut saat dimuat nanti
        var changed = false
        for i in list.indices where list[i].mine {
            let id = list[i].id
            let want = (read.map { id <= $0 } ?? false) ? "read" : (delivered.map { id <= $0 } ?? false) ? "delivered" : nil
            if let want, ChatMessage.rank(want) > ChatMessage.rank(list[i].status) {
                list[i].status = want
                changed = true
            }
        }
        if changed { threads[friend] = list }
    }

    func load(_ id: String) {
        guard !demo, let acc = app?.account else { return }
        if threads[id] == nil { loading = true }
        acc.loadMessages(id) { [weak self] msgs, more, err in
            guard let self else { return }
            if self.selected == id { self.loading = false }
            if let err { if self.selected == id { self.error = err }; return }
            // berhasil lagi → pesan galat lama (mis. saat Mac baru bangun dan internet belum siap) dihapus
            if self.selected == id { self.error = nil }
            if self.hasMore[id] == nil { self.hasMore[id] = more }
            if self.threads[id] == nil { self.threads[id] = [] }
            self.merge(id, msgs ?? [])
        }
    }

    func loadOlder() {
        guard !demo, let id = selected, let first = threads[id]?.first, let acc = app?.account else { return }
        acc.loadMessages(id, before: first.id) { [weak self] msgs, more, err in
            guard let self else { return }
            if let err { self.error = err; return }
            if self.selected == id { self.error = nil }
            self.hasMore[id] = more
            self.merge(id, msgs ?? [])
        }
    }

    func send() {
        guard let id = selected, !sending else { return }
        let text = draft(id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if demo {
            merge(id, [ChatMessage(id: (threads[id]?.last?.id ?? 0) + 1, text: text, created_at: ISO8601DateFormatter().string(from: Date()), mine: true,
                                   status: "sent")])
            drafts[id] = ""
            return
        }
        guard let acc = app?.account else { return }
        sending = true
        error = nil
        acc.sendMessage(id, text) { [weak self] m, err in
            guard let self else { return }
            self.sending = false
            guard let m else { self.error = err ?? "Pesan gagal terkirim. Coba lagi."; return } // teks tetap di kolom
            if self.draft(id).trimmingCharacters(in: .whitespacesAndNewlines) == text { self.drafts[id] = "" }
            self.merge(id, [m])
            self.focusToken += 1
        }
    }

    /// Emot lewat pet: animasinya langsung diputar di desktop Mac ini (di atas pet teman itu, atau pet-ku dengan label
    /// "untuk …"), lalu dikirim. Kolom tulis tidak tersentuh, jadi kalimat yang sedang diketik tetap aman.
    /// Pengaturan › Pesan › Simpan emot di obrolan: mati (bawaan) = hanya sesaat, tidak masuk riwayat obrolan.
    func sendReaction(_ r: Reaction) {
        guard let id = selected, Date().timeIntervalSince(lastReaction) > 0.35 else { return }
        lastReaction = Date()
        app?.playReaction(r, friend: id, mine: true)
        let keep = Prefs.reactionsInChat
        if demo {
            guard keep else { return }
            merge(id, [ChatMessage(id: (threads[id]?.last?.id ?? 0) + 1, text: r.emoji, created_at: ISO8601DateFormatter().string(from: Date()),
                                   mine: true, status: "sent", reaction: r.rawValue)])
            return
        }
        guard let acc = app?.account else { return }
        error = nil
        acc.sendReaction(id, r, keep: keep) { [weak self] m, delivered, err in
            guard let self else { return }
            if let err { self.error = err; return }
            if let m { self.merge(id, [m]); return }
            if !delivered, self.selected == id {
                let name = self.current?.name ?? "Temanmu"
                self.error = "\(name) sedang tidak tersambung, jadi emotnya tidak sampai. Nyalakan Pengaturan › Pesan › " +
                    "Simpan emot di obrolan supaya emot tetap sampai saat Temu-nya dibuka."
            }
        }
    }

    // MARK: lampiran

    /// 📎 → panel Buka macOS. Hanya file yang dipilih sendiri di panel ini yang dibaca.
    func pickFile(once: Bool) {
        guard let id = selected else { return }
        let name = current?.name ?? "temanmu"
        DispatchQueue.main.async { [weak self] in // tunggu menu 📎 tertutup dulu
            guard let self else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Kirim"
            panel.message = once
                ? "Sekali lihat untuk \(name): hanya bisa dibuka sekali, lalu langsung terhapus dari server. Maksimal 10 MB."
                : "Gambar atau file untuk \(name). Tersimpan di server sehari, lalu terhapus otomatis. Maksimal 10 MB."
            guard let url = self.runPanel(panel) else { return }
            self.sendFile(url, to: id, once: once)
        }
    }

    /// Jalankan panel Buka / Simpan tanpa menutup popover
    private func runPanel(_ panel: NSSavePanel) -> URL? {
        app?.holdPopovers(true)
        NSApp.activate(ignoringOtherApps: true)
        let ok = panel.runModal() == .OK
        app?.holdPopovers(false)
        return ok ? panel.url : nil
    }

    func sendFile(_ url: URL, to id: String, once: Bool) {
        if demo {
            let a = ChatAttachment(kind: "file", name: url.lastPathComponent, mime: "application/octet-stream", size: 1000, once: once,
                                   expires_at: ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400)), available: true)
            merge(id, [ChatMessage(id: (threads[id]?.last?.id ?? 0) + 1, text: "📎 " + a.name, created_at: ISO8601DateFormatter().string(from: Date()),
                                   mine: true, status: "sent", attachment: a)])
            return
        }
        guard let acc = app?.account, !uploading else { return }
        uploading = true
        error = nil
        acc.sendFile(id, url, once: once) { [weak self] m, data, err in
            guard let self else { return }
            self.uploading = false
            guard let m else { self.error = err ?? "File gagal terkirim. Coba lagi."; return }
            // gambarku sendiri langsung tampil tanpa diunduh lagi (sekali lihat: pengirim pun tidak menyimpannya)
            if let data, let a = m.attachment, a.isImage, !a.once, let img = NSImage(data: data) {
                self.images[m.id] = img
                self.imageData[m.id] = data
            }
            self.merge(id, [m])
            self.focusToken += 1
        }
    }

    /// Gambar lampiran tampil di obrolan → unduh sekali, simpan di memori
    func loadImage(_ m: ChatMessage) {
        guard !demo, let friend = selected, let a = m.attachment, a.isImage, !a.once, a.live,
              images[m.id] == nil, !fetching.contains(m.id), let acc = app?.account else { return }
        fetching.insert(m.id)
        acc.downloadFile(friend, message: m.id) { [weak self] data, code, _ in
            guard let self else { return }
            self.fetching.remove(m.id)
            if code == 410 || code == 404 { return self.markGone(friend, m.id, opened: false) }
            guard let data, let img = NSImage(data: data) else { return }
            self.images[m.id] = img
            self.imageData[m.id] = data
        }
    }

    /// Lampiran diklik: gambar → jendela besar; file → panel Simpan; sekali lihat → dibuka sekali lalu terhapus dari server
    func openAttachment(_ m: ChatMessage) {
        guard let friend = selected, let a = m.attachment, a.live else { return }
        if !a.once {
            if a.isImage, let img = images[m.id] { return ImageViewer.show(img, title: a.name, once: false) }
            if a.isImage { return loadImage(m) } // belum terunduh: tampil di obrolan dulu
            return saveAttachment(m)
        }
        guard !m.mine, !fetching.contains(m.id) else { return }
        let name = current?.name ?? "teman"
        if demo { return markGone(friend, m.id, opened: true) }
        guard let acc = app?.account else { return }
        if a.isImage {
            fetching.insert(m.id)
            acc.downloadFile(friend, message: m.id) { [weak self] data, code, err in
                guard let self else { return }
                self.fetching.remove(m.id)
                if code == 200 || code == 410 || code == 404 { self.markGone(friend, m.id, opened: code == 200) }
                guard let data, let img = NSImage(data: data) else {
                    self.error = err ?? "Foto sekali lihat ini tidak bisa dibuka."
                    return
                }
                ImageViewer.show(img, title: "Foto sekali lihat dari \(name)", once: true)
            }
            return
        }
        // file sekali unduh: pilih tempatnya dulu, karena setelah diunduh isinya sudah tidak ada di server
        guard let dest = askSaveLocation(a.name, once: true) else { return }
        fetching.insert(m.id)
        acc.downloadFile(friend, message: m.id) { [weak self] data, code, err in
            guard let self else { return }
            self.fetching.remove(m.id)
            if code == 200 || code == 410 || code == 404 { self.markGone(friend, m.id, opened: code == 200) }
            guard let data else { self.error = err ?? "File ini tidak bisa diunduh."; return }
            self.write(data, to: dest)
        }
    }

    /// Simpan lampiran biasa (gambar / file) ke tempat yang dipilih di panel Simpan
    func saveAttachment(_ m: ChatMessage) {
        guard let friend = selected, let a = m.attachment, a.live, !a.once, !fetching.contains(m.id),
              let dest = askSaveLocation(a.name, once: false) else { return }
        if let data = imageData[m.id] { return write(data, to: dest) }
        guard !demo, let acc = app?.account else { return }
        fetching.insert(m.id)
        acc.downloadFile(friend, message: m.id) { [weak self] data, code, err in
            guard let self else { return }
            self.fetching.remove(m.id)
            if code == 410 || code == 404 { self.markGone(friend, m.id, opened: false) }
            guard let data else { self.error = err ?? "File ini tidak bisa diunduh."; return }
            self.write(data, to: dest)
        }
    }

    private func askSaveLocation(_ name: String, once: Bool) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.prompt = "Simpan"
        if once { panel.message = "File sekali unduh: setelah disimpan, isinya langsung terhapus dari server." }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return runPanel(panel)
    }

    /// Tulis ke tempat pilihan pengguna, lalu tunjukkan di Finder (tidak dibuka otomatis)
    private func write(_ data: Data, to dest: URL) {
        do {
            try data.write(to: dest, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            self.error = "Gagal menyimpan ke \(dest.lastPathComponent). Pilih folder lain, lalu coba lagi."
        }
    }

    /// Isi lampiran sudah tidak ada di server (sekali lihat dibuka, atau lewat sehari)
    private func markGone(_ friend: String, _ id: Int, opened: Bool) {
        guard var list = threads[friend], let i = list.firstIndex(where: { $0.id == id }), var a = list[i].attachment else { return }
        a.available = false
        if opened { a.opened = true }
        list[i].attachment = a
        threads[friend] = list
        images[id] = nil
        imageData[id] = nil
    }

    /// Kabar "file_opened": pesan sekali lihat dengan teman ini sudah dibuka (oleh teman, atau di Mac lain milikku)
    func fileOpened(_ friend: String, message: Int) { markGone(friend, message, opened: true) }

    /// Emot di obrolan diklik → putar lagi animasinya di desktop
    func replay(_ r: Reaction, mine: Bool) {
        guard let id = selected else { return }
        app?.playReaction(r, friend: id, mine: mine)
    }

    /// Pesan dari saluran real-time (masuk, atau terkirim dari Mac lain milik sendiri)
    func receive(_ friend: String, _ m: ChatMessage) {
        if threads[friend] != nil { merge(friend, [m]) }
        if !m.mine, visible, expanded, selected == friend { app?.account.markRead(friend) }
    }

    func noteUnread(from: String) { lastUnreadFrom = from }

    /// Saluran real-time putus → selama popover terbuka, obrolan disegarkan sendiri tiap 15 detik
    private func startRefresh() {
        guard refreshTimer == nil, !demo else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.visible, !(self.app?.account.liveConnected ?? true), let id = self.selected else { return }
            self.load(id)
            self.markRead(id)
            self.app?.account.sync(force: false) // status online teman ikut segar (paling cepat sekali per 45 detik)
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    // MARK: contoh untuk tangkapan layar

    func startDemo() {
        demo = true
        let sp = { (id: String) in Skin.builtin(Species.find(id)) }
        friends = [
            ChatFriend(id: "d", name: "Dina", handle: "dina", skin: sp("kelinci"), unread: 0, presence: .online),
            ChatFriend(id: "r", name: "Raka", handle: "raka", skin: sp("rubah"), unread: 2, presence: .away),
            ChatFriend(id: "s", name: "Sari", handle: "sari", skin: sp("beruang"), unread: 0, presence: .offline),
            ChatFriend(id: "b", name: "Bima", handle: "bima", skin: nil, unread: 0, presence: .offline),
        ]
        let now = Date()
        let iso = { (min: Double) in ISO8601DateFormatter().string(from: now.addingTimeInterval(-min * 60)) }
        threads["d"] = [
            ChatMessage(id: 1, text: "Pagi! Pet-mu barusan nyasar ke pojok layarku 😄", created_at: iso(1500), mine: false),
            ChatMessage(id: 2, text: "Hahaha dia memang suka jalan-jalan", created_at: iso(1490), mine: true, status: "read"),
            ChatMessage(id: 3, text: "Nanti malam jadi video call?", created_at: iso(42), mine: false),
            ChatMessage(id: 4, text: "Jadi dong. Jam 8 ya", created_at: iso(40), mine: true, status: "read"),
            ChatMessage(id: 5, text: "Oke, sampai nanti 💛", created_at: iso(3), mine: false),
            // contoh status centang untuk tangkapan layar: ✓✓ diterima lalu ✓ terkirim
            ChatMessage(id: 6, text: "Aku bawa camilan ya", created_at: iso(2), mine: true, status: "delivered"),
            ChatMessage(id: 7, text: "Sampai jam 8!", created_at: iso(1), mine: true, status: "sent"),
            // contoh emot lewat pet
            ChatMessage(id: 8, text: "❤️", created_at: iso(0.5), mine: false, reaction: "love"),
            // contoh lampiran: file biasa (ada sehari) dan foto sekali lihat
            ChatMessage(id: 9, text: "📎 jadwal-liburan.pdf", created_at: iso(0.4), mine: true, status: "read",
                        attachment: ChatAttachment(kind: "file", name: "jadwal-liburan.pdf", mime: "application/pdf", size: 248_000,
                                                   once: false, expires_at: iso(-1439), available: true)),
            ChatMessage(id: 10, text: "📷 Foto sekali lihat", created_at: iso(0.2), mine: false,
                        attachment: ChatAttachment(kind: "image", name: "foto.jpg", mime: "image/jpeg", size: 812_000,
                                                   once: true, expires_at: iso(-1439), available: true)),
        ]
        threads["r"] = []
        hasMore = ["d": false, "r": false]
        // --demo-empty: obrolan kosong (saran kalimat pembuka) untuk tangkapan layar
        selected = CommandLine.arguments.contains("--demo-empty") ? "r" : "d"
    }
}

// MARK: - Potongan tampilan

/// Avatar teman = pet-nya (pixel, tanpa penghalusan); tanpa pet = huruf awal namanya
struct FriendAvatar: View {
    let friend: ChatFriend
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(friend.skin == nil ? Brand.orange : Color.primary.opacity(0.07))
            if let skin = friend.skin {
                // pet menempati ±baris 14–32 sel 32×32 (kaki di tepi bawah): diperbesar & digeser ke atas
                // supaya badan + wajahnya mengisi lingkaran, bukan kecil di dasar
                Image(nsImage: skin.portrait(.idle, points: 2))
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size * 1.45, height: size * 1.45)
                    .offset(x: size * 0.07, y: -size * 0.31)
            } else {
                Text(String(friend.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.ink)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Titik status di pojok avatar: hijau = online, oranye = tersendat, abu-abu = offline,
/// cincin kosong = belum bisa dicek (Mac ini tidak tersambung ke server)
struct PresenceDot: View {
    let presence: Presence

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().inset(by: 1.5).stroke(Color.gray, lineWidth: presence == .unknown ? 1.5 : 0))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
    }

    private var fill: Color {
        switch presence {
        case .online: return Brand.leaf
        case .away: return Brand.orange
        case .offline: return Color.gray
        case .unknown: return Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// Status pesanku seperti WhatsApp: ✓ terkirim, ✓✓ diterima, ✓✓ biru dibaca
struct ReceiptTicks: View {
    let status: String
    /// false = di luar balon Stroberi (emot di obrolan): abu-abu sistem supaya terbaca di mode gelap
    var onBubble = true

    var body: some View {
        let read = status == "read"
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            if status == "delivered" || read { Image(systemName: "checkmark").offset(x: 4) }
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(read ? Brand.read : (onBubble ? Brand.ink.opacity(0.55) : Color.secondary))
        .frame(width: 14, alignment: .leading)
        .accessibilityLabel(ReceiptTicks.label(status))
    }

    /// Keterangan untuk tooltip (diawali " · " supaya bisa disambung ke jam)
    static func label(_ status: String?) -> String {
        switch status {
        case "read": return " · Dibaca"
        case "delivered": return " · Diterima"
        case "sent": return " · Terkirim"
        default: return ""
        }
    }
}

/// Emoji bawaan: karakter Unicode biasa, digambar dengan font emoji sistem (tanpa paket tambahan)
enum EmojiSet {
    static let groups: [(String, [String])] = [
        ("Wajah", ["😀", "😁", "😂", "🤣", "😊", "😍", "🥰", "😘", "😚", "😋", "😜", "🤪", "😎", "🤗", "🤭", "🤔",
                   "😴", "🥱", "😅", "😇", "🙃", "😏", "😌", "😔", "😢", "😭", "😤", "😡", "🥺", "😳", "😱", "🤯"]),
        ("Hati & tangan", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🤍", "💕", "💖", "💔", "👍", "👎", "👏", "🙌", "🙏", "🤝",
                           "👋", "✌️", "🤞", "👌", "💪", "🫶", "🤙", "👀"]),
        ("Hewan", ["🐱", "🐶", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🐸", "🐧", "🐥", "🐟", "🦋", "🐾"]),
        ("Lainnya", ["☕️", "🍵", "🍜", "🍕", "🍰", "🍫", "🎉", "🎂", "🎁", "✨", "⭐️", "🌙", "☀️", "🌧️", "🌸", "🔥",
                     "💤", "💬", "📍", "🏠", "🚗", "✈️", "⚽️", "🎮"]),
    ]
}

/// Tombol ikon kecil di baris paling bawah; artinya di tooltip
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.10 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Aksi pet: ikon + label pendek, kalimat lengkapnya di tooltip
struct ActionTile: View {
    let symbol: String
    let title: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.strawberry)
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover && enabled ? 0.09 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Satu tombol emoji di panel
struct EmojiKey: View {
    let emoji: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 20))
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.10 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Gambar emot (Fluent Emoji 3D, sama dengan yang melayang di atas pet): diam di bingkai pertama,
/// bergerak selama `playing` (mulai dari awal setiap kali). Tanpa berkas animasinya → emoji sistem.
struct ReactionIcon: View {
    let reaction: Reaction
    var size: CGFloat
    var playing = false
    @State private var start = Date()

    var body: some View {
        Group {
            if let frames = ReactionArt.frames(reaction.emoji) {
                if playing {
                    TimelineView(.animation(minimumInterval: 1 / ReactionArt.fps)) { ctx in
                        let i = Int(max(0, ctx.date.timeIntervalSince(start)) * ReactionArt.fps) % frames.count
                        still(frames[i])
                    }
                } else {
                    still(frames[0])
                }
            } else {
                Text(reaction.emoji).font(.system(size: size * 0.8))
            }
        }
        .frame(width: size, height: size)
        .onChange(of: playing) { on in if on { start = Date() } }
        .onAppear { start = Date() }
    }

    private func still(_ img: CGImage) -> some View {
        Image(decorative: img, scale: 2).resizable().interpolation(.high).frame(width: size, height: size)
    }
}

/// Satu emot di baki: membesar saat disorot, memantul saat diklik, dan salinan kecilnya melayang naik
/// (pratinjau kecil dari animasi yang muncul di layar teman)
struct ReactionKey: View {
    let reaction: Reaction
    @Binding var hovered: Reaction?
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    @State private var puffs: [UUID] = []

    var body: some View {
        Button {
            action()
            pressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
            let id = UUID()
            puffs.append(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { puffs.removeAll { $0 == id } }
        } label: {
            ReactionIcon(reaction: reaction, size: 34, playing: hover) // bergerak saat disorot, seperti di Zoom
                .scaleEffect(pressed ? 0.8 : (hover ? 1.2 : 1))
                .offset(y: hover ? -3 : 0)
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: hover)
                .animation(.spring(response: 0.22, dampingFraction: 0.45), value: pressed)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.08 : 0)).frame(width: 42, height: 42))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            ZStack {
                ForEach(puffs, id: \.self) { _ in ReactionPuff(reaction: reaction) }
            }
            .allowsHitTesting(false)
        }
        .onHover { h in
            hover = h
            if h { hovered = reaction } else if hovered == reaction { hovered = nil }
        }
        .help("\(reaction.title) — langsung terkirim")
        .accessibilityLabel("Kirim emot \(reaction.title)")
    }
}

/// Salinan kecil emot yang melayang naik dari tombolnya sambil membesar, lalu memudar
struct ReactionPuff: View {
    let reaction: Reaction
    @State private var go = false
    @State private var drift = CGFloat.random(in: -14...14)

    var body: some View {
        ReactionIcon(reaction: reaction, size: 28, playing: true)
            .scaleEffect(go ? 1.35 : 0.7)
            .offset(x: go ? drift : 0, y: go ? -72 : -6)
            .animation(.easeOut(duration: 0.9), value: go)
            .opacity(go ? 0 : 1)
            .animation(.easeIn(duration: 0.9), value: go)
            .onAppear { DispatchQueue.main.async { go = true } }
    }
}

/// Emot di obrolan: emoji besar tanpa balon + namanya (dan centang kalau dariku). Klik = putar lagi di atas pet.
/// Emot yang baru datang muncul dengan pantulan kecil.
struct ReactionStamp: View {
    let reaction: Reaction
    let mine: Bool
    let status: String?
    let replay: () -> Void
    @State private var hover = false
    @State private var shown: Bool
    /// Emot yang baru datang bergerak sebentar, lalu diam (bergerak lagi saat disorot)
    @State private var lively: Bool

    init(reaction: Reaction, mine: Bool, status: String?, fresh: Bool, replay: @escaping () -> Void) {
        self.reaction = reaction
        self.mine = mine
        self.status = status
        self.replay = replay
        _shown = State(initialValue: !fresh)
        _lively = State(initialValue: fresh)
    }

    var body: some View {
        Button(action: replay) {
            VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
                ReactionIcon(reaction: reaction, size: 42, playing: hover || lively)
                    .scaleEffect(shown ? (hover ? 1.1 : 1) : 0.3)
                    .rotationEffect(.degrees(hover ? (mine ? -6 : 6) : 0))
                    .animation(.spring(response: 0.38, dampingFraction: 0.5), value: shown)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
                HStack(spacing: 3) {
                    Text(reaction.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    if mine, let status { ReceiptTicks(status: status, onBubble: false) }
                }
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .onAppear {
            if !shown { DispatchQueue.main.async { shown = true } }
            if lively { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { lively = false } }
        }
        .accessibilityLabel("Emot \(reaction.title)" + (mine ? " dariku" : ""))
    }
}

struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(Brand.strawberry))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Popover

struct PopoverView: View {
    /// menuBar = popover ikon menu bar (lengkap); pet = popover di samping pet (hanya obrolan)
    enum Place { case menuBar, pet }

    @ObservedObject var model: PopoverModel
    var place: Place = .menuBar
    @FocusState private var focused: Bool
    @State private var showEmoji = CommandLine.arguments.contains("--demo-emoji") // --demo-emoji: tangkapan layar CI
    @State private var showReactions = CommandLine.arguments.contains("--demo-react") // --demo-react: tangkapan layar CI
    /// Emot yang sedang disorot di baki (namanya tampil di judul baki)
    @State private var hoveredReaction: Reaction?

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = "EEEE, d MMM"
        return f
    }()
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = "HH.mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            if !model.linked {
                notLinked
            } else if place == .menuBar && model.chatElsewhere {
                chatLauncher
            } else if model.friends.isEmpty {
                noFriends
            } else if !model.expanded {
                hiddenChat
            } else {
                // header tetap di posisi yang sama saat obrolan terbuka → satu klik di tempat yang sama untuk menutup
                if model.hideChat {
                    hiddenChat
                    Divider()
                }
                friendStrip
                Divider()
                chat
            }
            // popover di samping pet hanya berisi obrolan; aksi pet & status tetap di popover menu bar
            if place == .menuBar {
                Divider()
                petActions
                Divider()
                footer
            }
        }
        .frame(width: 360)
        .onChange(of: model.focusToken) { _ in
            DispatchQueue.main.async { focused = true }
        }
    }

    // MARK: teman

    private var friendStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.friends) { f in
                    let on = f.id == model.selected
                    Button { model.select(f.id) } label: {
                        VStack(spacing: 3) {
                            FriendAvatar(friend: f)
                                .overlay(Circle().stroke(on ? Brand.strawberry : .clear, lineWidth: 2))
                                .overlay(alignment: .topTrailing) {
                                    if f.unread > 0 {
                                        Text("\(min(f.unread, 99))")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .frame(minWidth: 15, minHeight: 15)
                                            .background(Capsule().fill(Color.red))
                                            .offset(x: 4, y: -2)
                                    }
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    PresenceDot(presence: f.presence).offset(x: 1, y: 1)
                                }
                            Text(f.name)
                                .font(.system(size: 11, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? .primary : .secondary)
                                .lineLimit(1)
                                .frame(width: 54)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(friendHelp(f))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    /// Obrolan tertutup (Pengaturan › Pesan › Sembunyikan obrolan): hanya jumlah pesan baru, tanpa nama atau isi
    /// Saat terbuka baris ini tetap di atas (posisi sama) dan berganti jadi "Sembunyikan ⌃"
    private var hiddenChat: some View {
        let n = model.totalUnread
        let open = model.expanded
        return Button { if open { model.collapse() } else { model.expand() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.strawberry)
                Text("Obrolan")
                    .font(.system(size: 13, weight: .semibold))
                if n > 0 {
                    Text("\(min(n, 99))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Capsule().fill(Color.red))
                }
                Spacer(minLength: 4)
                Text(open ? "Sembunyikan" : "Tampilkan")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12) // panah tidak bergeser saat tulisannya berganti
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Sembunyikan obrolan lagi" :
              (n > 0 ? "\(n) pesan baru. " : "") + "Obrolan disembunyikan supaya tidak terbaca orang lain. Atur di Pengaturan › Pesan.")
    }

    /// Popover menu bar saat Posisi obrolan = di samping pet: satu baris untuk membuka obrolan di sebelah pet
    private var chatLauncher: some View {
        let n = model.totalUnread
        return Button { model.app?.openChatNearPet() } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.strawberry)
                Text("Obrolan")
                    .font(.system(size: 13, weight: .semibold))
                if n > 0 {
                    Text("\(min(n, 99))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Capsule().fill(Color.red))
                }
                Spacer(minLength: 4)
                Text("Buka di samping pet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help((n > 0 ? "\(n) pesan baru. " : "") + "Obrolan muncul di sebelah pet di desktop. Atur di Pengaturan › Pesan › Posisi obrolan.")
    }

    private func friendHelp(_ f: ChatFriend) -> String {
        var s = f.handle.isEmpty ? f.name : "\(f.name) · @\(f.handle)"
        if f.unread > 0 { s += " — \(f.unread) pesan baru" }
        switch f.presence {
        case .online: s += "\nOnline — Temu sedang terbuka di Mac-nya."
        case .away: s += "\nTersendat — Temu-nya terbuka, tapi sambungannya ke server sedang bermasalah. Pesanmu tetap sampai."
        case .offline: s += "\nOffline — pesanmu tetap tersimpan dan terbaca saat Temu-nya dibuka lagi."
        case .unknown: s += "\nBelum bisa dicek — Mac ini sedang tidak tersambung ke server."
        }
        if f.skin == nil { s += "\nPet-nya belum tampil di Mac ini. Minta pet-nya lewat web supaya bisa ⌘-klik di desktop." }
        return s
    }

    // MARK: obrolan

    private var chat: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.messages.isEmpty {
                    emptyThread
                } else {
                    thread
                }
            }
            .frame(height: 300)

            if let err = model.error {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            } else if let f = model.current, let note = model.presenceNote(f) {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }
            if showReactions { reactionTray } else if showEmoji { emojiPanel }
            composer
        }
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // obrolan pendek menempel ke bawah (dekat kolom tulis), seperti aplikasi chat pada umumnya
                LazyVStack(spacing: 4) {
                    if model.hasMore[model.selected ?? ""] == true {
                        Button("Muat pesan sebelumnya") { model.loadOlder() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                            .padding(.bottom, 6)
                    }
                    let msgs = model.messages
                    ForEach(Array(msgs.enumerated()), id: \.element.id) { i, m in
                        if i == 0 || !Calendar.current.isDate(msgs[i - 1].date, inSameDayAs: m.date) {
                            Text(dayLabel(m.date))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 6)
                        }
                        let tail = i == msgs.count - 1 || msgs[i + 1].mine != m.mine
                        Group {
                            if let a = m.attachment {
                                attachmentBubble(m, a, tail: tail)
                            } else if let r = Reaction.find(m.reaction) {
                                reactionStamp(m, r, tail: tail)
                            } else {
                                bubble(m, tail: tail)
                            }
                        }
                        .id(m.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 300, alignment: .bottom)
            }
            .onAppear { scrollDown(proxy, animated: false) }
            .onChange(of: model.messages.last?.id) { _ in scrollDown(proxy, animated: true) }
            .onChange(of: model.selected) { _ in scrollDown(proxy, animated: false) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = model.messages.last?.id else { return }
        DispatchQueue.main.async {
            if animated { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) } }
            else { proxy.scrollTo(last, anchor: .bottom) }
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return "Hari ini" }
        if c.isDateInYesterday(d) { return "Kemarin" }
        return PopoverView.dayFormat.string(from: d)
    }

    private func bubble(_ m: ChatMessage, tail: Bool) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 5) {
            Text(m.text)
                .font(.system(size: 13))
                .foregroundStyle(m.mine ? Brand.ink : Color.primary)
                .textSelection(.enabled)
            if m.mine, let status = m.status { ReceiptTicks(status: status) }
        }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(m.mine ? Brand.strawberry : Color.primary.opacity(0.08))
            )
            .frame(maxWidth: 250, alignment: m.mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: m.mine ? .trailing : .leading)
            .padding(.bottom, tail ? 6 : 0)
            .help(PopoverView.timeFormat.string(from: m.date) + (m.mine ? ReceiptTicks.label(m.status) : ""))
            .contextMenu {
                Button("Salin pesan") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(m.text, forType: .string)
                }
            }
    }

    /// Lampiran di obrolan (Attachments.swift): gambar kecil / kartu file, di sisi pengirimnya
    private func attachmentBubble(_ m: ChatMessage, _ a: ChatAttachment, tail: Bool) -> some View {
        AttachmentBubble(message: m, attachment: a, image: model.images[m.id], busy: model.fetching.contains(m.id),
                         open: { model.openAttachment(m) }, save: { model.saveAttachment(m) })
            .frame(maxWidth: 250, alignment: m.mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: m.mine ? .trailing : .leading)
            .padding(.bottom, tail ? 6 : 0)
            .onAppear { model.loadImage(m) }
            .help(PopoverView.timeFormat.string(from: m.date) + (m.mine ? ReceiptTicks.label(m.status) : "") + "\n" + attachmentHelp(m, a))
    }

    private func attachmentHelp(_ m: ChatMessage, _ a: ChatAttachment) -> String {
        if a.once {
            if m.mine { return "Sekali lihat: hanya \(model.current?.name ?? "temanmu") yang bisa membuka, sekali saja." }
            return a.live ? "Sekali lihat: setelah dibuka, isinya langsung terhapus dari server." : "Sekali lihat"
        }
        if !a.live { return "Lampiran hanya tersimpan sehari di server." }
        return a.isImage ? "Klik untuk melihat lebih besar. Klik kanan › Simpan… untuk menyimpan." : "Klik untuk menyimpan file ini."
    }

    /// Emot lewat pet di obrolan: tanpa balon, di sisi pengirimnya
    private func reactionStamp(_ m: ChatMessage, _ r: Reaction, tail: Bool) -> some View {
        ReactionStamp(reaction: r, mine: m.mine, status: m.status, fresh: Date().timeIntervalSince(m.date) < 10) {
            model.replay(r, mine: m.mine)
        }
        .frame(maxWidth: .infinity, alignment: m.mine ? .trailing : .leading)
        .padding(.bottom, tail ? 6 : 0)
        .help(PopoverView.timeFormat.string(from: m.date) + (m.mine ? ReceiptTicks.label(m.status) : "") +
              "\nKlik untuk memutar lagi animasinya di atas pet")
    }

    /// Obrolan kosong: pet teman menyapa + saran kalimat pembuka (mengisi kolom, tidak langsung terkirim)
    private var emptyThread: some View {
        VStack(spacing: 10) {
            if model.loading {
                ProgressView().controlSize(.small)
            } else if let f = model.current {
                FriendAvatar(friend: f, size: 64)
                Text("Belum ada obrolan dengan \(f.name)")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(["Hai! 👋", "Lagi apa?", "Kangen 💛"], id: \.self) { s in
                        Button(s) {
                            model.drafts[f.id] = s
                            focused = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().stroke(Color.primary.opacity(0.18)))
                        .help("Pakai kalimat ini, lalu tekan Return")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        let id = model.selected ?? ""
        let name = model.current?.name ?? "teman"
        let canSend = !model.draft(id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.sending
        return HStack(spacing: 8) {
            TextField("Pesan untuk \(name)…", text: Binding(get: { model.draft(id) }, set: { model.drafts[id] = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { model.send() }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            if model.uploading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 30)
                    .help("Mengirim lampiran…")
            } else {
                Menu {
                    Button("Gambar atau file…") { model.pickFile(once: false) }
                    Button("Sekali lihat…") { model.pickFile(once: true) }
                } label: {
                    Image(systemName: "paperclip")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 22, height: 30)
                .help("Kirim gambar atau file ke \(name). Tersimpan sehari di server; sekali lihat terhapus setelah dibuka.")
            }
            Button {
                showReactions.toggle()
                if showReactions { showEmoji = false }
                focused = true
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(showReactions ? Brand.strawberry : Color.secondary)
                    .frame(width: 22, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showReactions ? "Tutup emot" : "Emot lewat pet: melayang di atas pet-mu di layar \(name)")
            Button {
                showEmoji.toggle()
                if showEmoji { showReactions = false }
                focused = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 16))
                    .foregroundStyle(showEmoji ? Brand.strawberry : Color.secondary)
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showEmoji ? "Tutup emoji" : "Emoji")
            Button { model.send() } label: {
                Group {
                    if model.sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundStyle(canSend ? Brand.ink : Color.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(canSend ? Brand.strawberry : Color.primary.opacity(0.08)))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Kirim (Return)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: emot lewat pet

    /// Baki emot di atas kolom tulis: satu klik = langsung terkirim; baki tetap terbuka untuk emot berikutnya
    private var reactionTray: some View {
        let name = model.current?.name ?? "teman"
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(hoveredReaction?.title ?? "Emot lewat pet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hoveredReaction == nil ? Color.secondary : Color.primary)
                Spacer(minLength: 4)
                Text("muncul di atas pet-mu di layar \(name)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            HStack(spacing: 0) {
                ForEach(Reaction.allCases) { r in
                    ReactionKey(reaction: r, hovered: $hoveredReaction) { model.sendReaction(r) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(Color.primary.opacity(0.03))
        .zIndex(1) // salinan emot yang melayang naik digambar di atas obrolan
    }

    // MARK: emoji

    /// Panel emoji di atas kolom tulis: klik = sisipkan di posisi kursor, panel tetap terbuka untuk emoji berikutnya
    private var emojiPanel: some View {
        let cols = Array(repeating: GridItem(.fixed(32), spacing: 3), count: 9)
        var groups = EmojiSet.groups
        if !model.recentEmoji.isEmpty { groups.insert(("Baru dipakai", model.recentEmoji), at: 0) }
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(groups, id: \.0) { g in
                        Text(g.0)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                        LazyVGrid(columns: cols, alignment: .leading, spacing: 3) {
                            ForEach(g.1, id: \.self) { e in
                                EmojiKey(emoji: e) { insertEmoji(e) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .frame(height: 150)
            HStack {
                Spacer()
                Button("Semua emoji…") {
                    focused = true
                    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("Buka pemilih Emoji & Simbol bawaan macOS (⌃⌘Spasi)")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
        .background(Color.primary.opacity(0.03))
    }

    /// Sisipkan di posisi kursor kolom tulis (menggantikan teks yang terpilih); kalau kolom tidak aktif, tambahkan di akhir
    private func insertEmoji(_ e: String) {
        let id = model.selected ?? ""
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isFieldEditor {
            tv.insertText(e, replacementRange: tv.selectedRange())
        } else {
            model.drafts[id] = model.draft(id) + e
        }
        model.usedEmoji(e)
        focused = true
    }

    // MARK: layar kosong

    /// Belum terhubung: satu ajakan jelas. Saat menunggu persetujuan, kodenya tampil besar.
    private var notLinked: some View {
        VStack(spacing: 10) {
            Image(nsImage: model.ownSkin.portrait(.wave, points: 3))
                .interpolation(.none)
            if let code = model.linkCode {
                Text("Setujui kode ini di browser")
                    .font(.system(size: 13, weight: .semibold))
                Text(code)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .help("Pastikan kodenya sama dengan yang tampil di browser")
                HStack(spacing: 12) {
                    PrimaryButton(title: "Buka browser lagi") { model.app?.openLinkPage() }
                    Button("Batal") { model.app?.cancelLink() }
                        .buttonStyle(.link)
                }
            } else {
                Text("Ngobrol lewat pet")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("Hubungkan akun Temu untuk mengirim pesan ke teman dan memakai pet buatanmu.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "Hubungkan akun") { model.app?.linkAccount() }
                    .help("Browser terbuka untuk menyetujui Mac ini. Password tidak pernah diketik di aplikasi.")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }

    private var noFriends: some View {
        VStack(spacing: 10) {
            Image(nsImage: model.ownSkin.portrait(.idle, points: 3))
                .interpolation(.none)
            Text("Belum ada teman untuk diajak ngobrol")
                .font(.system(size: 14, weight: .bold, design: .rounded))
            Text("Undang teman dari web. Setelah berteman, kalian bisa saling kirim pesan dari sini.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: "Undang teman") { model.app?.openWebPath("/teman") }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }

    // MARK: aksi pet

    private var petActions: some View {
        let _ = model.revision
        let shown = Prefs.showDesktop
        return HStack(spacing: 6) {
            ActionTile(symbol: "fish.fill", title: "Kasih makan", help: "Lempar ikan, pet akan mengejar dan memakannya", enabled: model.hasPets) {
                model.app?.feed()
            }
            ActionTile(symbol: "soccerball", title: "Main bola", help: "Pet mengejar dan menendang bola", enabled: model.hasPets) {
                model.app?.play()
            }
            ActionTile(symbol: "arrow.down.to.line", title: "Panggil", help: "Semua pet turun di dekat kursor", enabled: model.hasPets) {
                model.app?.summon()
            }
            ActionTile(symbol: shown ? "eye.slash" : "eye", title: shown ? "Sembunyikan" : "Tampilkan",
                       help: shown ? "Sembunyikan pet dari desktop (tetap hidup di ikon menu bar)" : "Tampilkan pet di desktop") {
                model.app?.toggleDesktop()
            }
        }
        .padding(10)
    }

    // MARK: kaki

    private var footer: some View {
        let _ = model.revision
        return HStack(spacing: 2) {
            Button {
                if model.linked { model.app?.syncNow() } else { model.app?.linkAccount() }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(!model.linked ? Color.secondary.opacity(0.5) : (model.statusOK ? Brand.leaf : Brand.lemon))
                        .frame(width: 7, height: 7)
                    Text(model.linked ? (model.handle.isEmpty ? "Terhubung" : "@\(model.handle)") : "Belum terhubung")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(statusHelp)

            if let v = model.updateVersion {
                Button { model.app?.checkUpdate() } label: {
                    Label("Update \(v)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Brand.lemon))
                }
                .buttonStyle(.plain)
                .help("Versi baru Temu tersedia. Klik untuk memasang.")
            }

            Spacer(minLength: 4)
            if model.linked {
                IconButton(symbol: "globe", help: "Atur pet & teman di web Temu") { model.app?.openWeb() }
            }
            IconButton(symbol: "gearshape", help: "Pengaturan (⌘,)") { model.app?.openSettings() }
            IconButton(symbol: "power", help: "Keluar dari Temu") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var statusHelp: String {
        guard model.linked else { return "Klik untuk menghubungkan akun Temu" }
        return model.statusText + (model.liveOK ? "\nPesan sampai seketika." : "\nPesan diperbarui tiap menit.") + "\nKlik untuk menyegarkan pet."
    }
}
