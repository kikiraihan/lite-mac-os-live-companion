// Temu — popover menu bar (klik kiri ikon). Isinya langsung chat dengan teman:
//   atas   : deretan teman (avatar = pet-nya), titik merah = pesan belum dibaca
//   tengah : obrolan + kolom tulis (fokus otomatis, Return = kirim)
//            tombol 🙂 membuka panel emoji bawaan (Unicode, font emoji sistem); ⌘C/⌘V/⌘A lewat MainMenu.swift
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
}

/// Satu lawan bicara di deretan atas
struct ChatFriend: Identifiable, Equatable {
    let id: String
    let name: String
    let handle: String
    let skin: Skin?
    let unread: Int

    static func == (a: ChatFriend, b: ChatFriend) -> Bool {
        a.id == b.id && a.name == b.name && a.handle == b.handle && a.unread == b.unread && (a.skin == nil) == (b.skin == nil)
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

    // MARK: status yang dibaca tampilan

    var linked: Bool { demo || (app?.account.isLinked ?? false) }
    var handle: String { demo ? "kiki" : (app?.account.userHandle ?? "") }
    var statusText: String { demo ? "Terhubung sebagai @kiki" : (app?.account.statusText ?? "") }
    var statusOK: Bool { demo || statusText.hasPrefix("Terhubung") }
    var liveOK: Bool { demo || (app?.account.liveConnected ?? false) }
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
        var list: [ChatFriend] = acc.friends.map {
            ChatFriend(id: $0.id, name: $0.name, handle: $0.handle, skin: skins[$0.id], unread: acc.unread[$0.id] ?? 0)
        }
        // server lama tanpa daftar teman: pakai pemilik pet titipan + pengirim pesan
        var known = Set(list.map(\.id))
        for id in Array(skins.keys) + Array(acc.unread.keys) where !known.contains(id) {
            list.append(ChatFriend(id: id, name: acc.friendName(id), handle: "", skin: skins[id], unread: acc.unread[id] ?? 0))
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
        revealNext = false
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
        let known = Set(list.map(\.id))
        let add = new.filter { !known.contains($0.id) }
        guard !add.isEmpty else { return }
        list = (list + add).sorted { $0.id < $1.id }
        threads[id] = list
    }

    func load(_ id: String) {
        guard !demo, let acc = app?.account else { return }
        if threads[id] == nil { loading = true }
        acc.loadMessages(id) { [weak self] msgs, more, err in
            guard let self else { return }
            if self.selected == id { self.loading = false }
            if let err { if self.selected == id { self.error = err }; return }
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
            self.hasMore[id] = more
            self.merge(id, msgs ?? [])
        }
    }

    func send() {
        guard let id = selected, !sending else { return }
        let text = draft(id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if demo {
            merge(id, [ChatMessage(id: (threads[id]?.last?.id ?? 0) + 1, text: text, created_at: ISO8601DateFormatter().string(from: Date()), mine: true)])
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
            ChatFriend(id: "d", name: "Dina", handle: "dina", skin: sp("kelinci"), unread: 0),
            ChatFriend(id: "r", name: "Raka", handle: "raka", skin: sp("rubah"), unread: 2),
            ChatFriend(id: "s", name: "Sari", handle: "sari", skin: sp("beruang"), unread: 0),
            ChatFriend(id: "b", name: "Bima", handle: "bima", skin: nil, unread: 0),
        ]
        let now = Date()
        let iso = { (min: Double) in ISO8601DateFormatter().string(from: now.addingTimeInterval(-min * 60)) }
        threads["d"] = [
            ChatMessage(id: 1, text: "Pagi! Pet-mu barusan nyasar ke pojok layarku 😄", created_at: iso(1500), mine: false),
            ChatMessage(id: 2, text: "Hahaha dia memang suka jalan-jalan", created_at: iso(1490), mine: true),
            ChatMessage(id: 3, text: "Nanti malam jadi video call?", created_at: iso(42), mine: false),
            ChatMessage(id: 4, text: "Jadi dong. Jam 8 ya", created_at: iso(40), mine: true),
            ChatMessage(id: 5, text: "Oke, sampai nanti 💛", created_at: iso(3), mine: false),
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
    @ObservedObject var model: PopoverModel
    @FocusState private var focused: Bool
    @State private var showEmoji = CommandLine.arguments.contains("--demo-emoji") // --demo-emoji: tangkapan layar CI

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
            } else if model.friends.isEmpty {
                noFriends
            } else if !model.expanded {
                hiddenChat
            } else {
                friendStrip
                Divider()
                chat
            }
            Divider()
            petActions
            Divider()
            footer
        }
        .frame(width: 360)
        .onChange(of: model.focusToken) { _ in
            DispatchQueue.main.async { focused = true }
        }
    }

    // MARK: teman

    private var friendStrip: some View {
        HStack(spacing: 0) {
            friendList
            if model.hideChat {
                IconButton(symbol: "chevron.up", help: "Sembunyikan obrolan") { model.collapse() }
                    .padding(.trailing, 8)
            }
        }
    }

    private var friendList: some View {
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
    private var hiddenChat: some View {
        let n = model.totalUnread
        return Button { model.expand() } label: {
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
                Text("Tampilkan")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help((n > 0 ? "\(n) pesan baru. " : "") + "Obrolan disembunyikan supaya tidak terbaca orang lain. Atur di Pengaturan › Pesan.")
    }

    private func friendHelp(_ f: ChatFriend) -> String {
        var s = f.handle.isEmpty ? f.name : "\(f.name) · @\(f.handle)"
        if f.unread > 0 { s += " — \(f.unread) pesan baru" }
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
            }
            if showEmoji { emojiPanel }
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
                        bubble(m, tail: i == msgs.count - 1 || msgs[i + 1].mine != m.mine)
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
        Text(m.text)
            .font(.system(size: 13))
            .foregroundStyle(m.mine ? Brand.ink : Color.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(m.mine ? Brand.strawberry : Color.primary.opacity(0.08))
            )
            .frame(maxWidth: 250, alignment: m.mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: m.mine ? .trailing : .leading)
            .padding(.bottom, tail ? 6 : 0)
            .help(PopoverView.timeFormat.string(from: m.date))
            .contextMenu {
                Button("Salin pesan") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(m.text, forType: .string)
                }
            }
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
            Button { showEmoji.toggle(); focused = true } label: {
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
