// Temu — a little way to be together.
// Versi pixel kecil dirimu / pet-mu yang hidup di layar Mac orang terdekat (ikon di menu bar + pet di desktop)
// Build: ./scripts/build.sh  (butuh Xcode Command Line Tools)
//
// Berkas:
//   Sprites.swift   gambar pet bawaan & properti (teks → piksel), Skin (16 pose)
//   Pet.swift       panggung desktop: gerak, kejutan, interaksi mouse
//   Lines.swift     celoteh pet
//   Client.swift    akun Temu: hubungkan Mac, ambil pet & sapaan teman, pesan + saluran real-time
//   Popover.swift   popover klik kiri ikon menu bar: chat dengan teman + aksi pet (SwiftUI)
//   Settings.swift  jendela Pengaturan
//   main.swift      ikon menu bar, menu, pembaruan, siklus hidup aplikasi

import Cocoa
import ServiceManagement
import SwiftUI

let defaults = UserDefaults.standard
let appDisplayName = "Temu"
let appRepo = "kikiraihan/lite-mac-os-live-companion"
let releasesPage = URL(string: "https://github.com/\(appRepo)/releases/latest")!

// MARK: - Update (GitHub Releases, repo publik)

final class Updater: NSObject {
    let appName = "Temu"
    var lastError: String?
    let menuItem = NSMenuItem(title: "Cek pembaruan…", action: #selector(Updater.checkNow), keyEquivalent: "")
    var latest: (version: String, zip: URL?, page: URL)?
    var timer: Timer?
    var onChange: (() -> Void)?

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// "v1.2.0" lebih baru dari "1.1"?
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
                .map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    var hasUpdate: Bool { latest.map { Updater.isNewer($0.version, than: Updater.current) } ?? false }

    override init() {
        super.init()
        menuItem.target = self
    }

    /// Cek diam-diam saat aplikasi dibuka lalu sehari sekali; kalau ada versi baru, judul menu berubah
    func start() {
        check { [weak self] _ in self?.refreshMenu() }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check { _ in self?.refreshMenu() }
        }
        t.tolerance = 3600 // tidak perlu tepat waktu → hemat energi
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshMenu() {
        menuItem.isEnabled = true
        if let l = latest, hasUpdate { menuItem.title = "Update tersedia: \(l.version)…" }
        else { menuItem.title = "Cek pembaruan…" }
        onChange?()
    }

    /// Ambil info rilis terbaru dari GitHub; done(true) kalau berhasil (dipanggil di main thread)
    func check(_ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(appRepo)/releases/latest") else { return done(false) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var result: (String, URL?, URL)?
            var problem: String? = err?.localizedDescription
            if let data, (resp as? HTTPURLResponse)?.statusCode == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                let assets = obj["assets"] as? [[String: Any]] ?? []
                let zip = assets.first(where: { ($0["name"] as? String) == "\(self.appName).zip" })
                    .flatMap { $0["browser_download_url"] as? String }.flatMap { URL(string: $0) }
                let page = (obj["html_url"] as? String).flatMap { URL(string: $0) } ?? releasesPage
                result = (tag, zip, page)
            } else if problem == nil {
                problem = "Belum ada rilis, atau GitHub sedang tidak bisa dihubungi."
            }
            let found = result, why = problem
            DispatchQueue.main.async {
                if let found {
                    self.latest = (found.0, found.1, found.2)
                    self.lastError = nil
                } else {
                    self.lastError = why
                }
                done(found != nil)
            }
        }.resume()
    }

    @objc func checkNow() {
        menuItem.title = "Mengecek pembaruan…"
        menuItem.isEnabled = false
        check { [weak self] ok in
            guard let self else { return }
            self.refreshMenu()
            let a = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            guard ok, let l = self.latest else {
                a.messageText = "Gagal mengecek pembaruan"
                a.informativeText = self.lastError ?? "Periksa koneksi internet, lalu coba lagi."
                a.runModal()
                return
            }
            guard self.hasUpdate else {
                a.messageText = "\(appDisplayName) sudah versi terbaru"
                a.informativeText = "Versi terpasang: \(Updater.current)"
                a.runModal()
                return
            }
            a.messageText = "\(appDisplayName) \(l.version) tersedia"
            a.informativeText = "Versi terpasang: \(Updater.current).\n\n\(appDisplayName) akan ditutup, diganti versi baru, lalu dibuka lagi. Pengaturan tetap tersimpan."
            a.addButton(withTitle: "Update sekarang")
            a.addButton(withTitle: "Lihat rilis")
            a.addButton(withTitle: "Nanti")
            switch a.runModal() {
            case .alertFirstButtonReturn: self.install(l)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(l.page)
            default: break
            }
        }
    }

    /// Unduh .zip rilis, ekstrak, lalu ganti .app lama setelah aplikasi ini keluar
    func install(_ l: (version: String, zip: URL?, page: URL)) {
        let dest = Bundle.main.bundleURL
        // tanpa file .zip, bukan .app, atau folder tidak bisa ditulis → unduh manual dari halaman rilis
        guard let zip = l.zip, zip.scheme == "https", zip.host == "github.com", dest.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(l.page)
            return
        }
        menuItem.title = "Mengunduh \(l.version)…"
        menuItem.isEnabled = false
        URLSession.shared.downloadTask(with: zip) { tmp, resp, err in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("\(self.appName)-update-\(UUID().uuidString)")
            let zipFile = work.appendingPathComponent("update.zip")
            let newApp = work.appendingPathComponent("\(self.appName).app")
            var problem: String?
            if let tmp {
                do {
                    // file sementara dihapus setelah handler ini selesai → pindahkan sekarang
                    try fm.createDirectory(at: work, withIntermediateDirectories: true)
                    try fm.moveItem(at: tmp, to: zipFile)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code != 200 { throw NSError(domain: "Temu", code: code, userInfo: [NSLocalizedDescriptionKey: "Unduhan gagal (\(code))."]) }
                    let unzip = Process()
                    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    unzip.arguments = ["-x", "-k", zipFile.path, work.path]
                    try unzip.run()
                    unzip.waitUntilExit()
                    // hanya terima .app dengan bundle id yang sama dengan aplikasi ini
                    if unzip.terminationStatus != 0 || Bundle(url: newApp)?.bundleIdentifier != Bundle.main.bundleIdentifier {
                        problem = "File rilis tidak berisi \(self.appName).app yang benar."
                    }
                } catch { problem = error.localizedDescription }
            } else {
                problem = err?.localizedDescription ?? "Unduhan gagal."
            }
            let problemFound = problem
            DispatchQueue.main.async {
                if let why = problemFound { return self.fail(why, l.page) }
                // skrip kecil: tunggu aplikasi ini keluar, tukar .app (lama dicadangkan dulu), lalu buka lagi
                let script = """
                while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
                if mv "$3" "$4"; then
                  if mv "$2" "$3"; then rm -rf "$4"; else mv "$4" "$3"; fi
                fi
                xattr -cr "$3" 2>/dev/null
                open "$3"
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script, "sh", String(getpid()), newApp.path, dest.path,
                               work.appendingPathComponent("old.app").path]
                do { try p.run() } catch { return self.fail(error.localizedDescription, l.page) }
                NSApp.terminate(nil)
            }
        }.resume()
    }

    func fail(_ msg: String, _ page: URL) {
        refreshMenu()
        let a = NSAlert()
        a.messageText = "Update gagal"
        a.informativeText = "\(msg)\n\nHalaman rilis akan dibuka supaya Anda bisa mengunduh manual."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        NSWorkspace.shared.open(page)
    }
}

// MARK: - Aplikasi

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let stage = Stage()
    let account = Account()
    let updater = Updater()
    let menu = NSMenu()
    lazy var settings = SettingsWindow(app: self)
    private var barKey = ""
    private var lastSound = Date.distantPast
    /// Isi popover (chat + aksi pet), dipakai juga oleh ⌘-klik pet teman
    let chat = PopoverModel()
    private var popoverLastClose = Date.distantPast
    /// Selama ada pesan belum dibaca, pet di ikon menu bar sesekali melambai (kalau dinyalakan)
    private var waveTimer: Timer?
    /// Popover obrolan di samping pet: jendela kecil tak terlihat di posisi pet sebagai jangkar popover
    private lazy var petAnchor: NSPanel = {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return w
    }()
    /// Pet yang sedang menunggu di samping popover (diam sampai popover ditutup)
    private weak var waitingPet: Pet?
    /// Posisi kursor & ikon saat tombol ditekan di ikon menu bar — untuk membedakan ⌘-klik dari ⌘-seret
    /// (⌘-seret = macOS memindahkan ikon di menu bar; popover tidak perlu dibuka)
    private var barPress: (point: NSPoint, frame: NSRect)?
    private var barPressMonitor: Any?

    /// Klik kiri ikon menu bar: popover chat. Klik kanan / Control-klik: menu lengkap (native).
    lazy var popover: NSPopover = makePopover(.menuBar)
    /// Posisi obrolan = di samping pet: popover kedua yang hanya berisi obrolan, menempel di pet.
    /// Aksi pet, status & tombol lain tetap di popover menu bar.
    lazy var petPopover: NSPopover = makePopover(.pet)

    private func makePopover(_ place: PopoverView.Place) -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        let host = NSHostingController(rootView: PopoverView(model: chat, place: place))
        host.sizingOptions = .preferredContentSize // tinggi popover mengikuti isi (belum terhubung / chat)
        p.contentViewController = host
        return p
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Prefs.register()
        MainMenu.install(target: self) // pintasan ⌘C / ⌘V / ⌘A / ⌘Z / ⌘, / ⌘Q
        stage.applyPrefs() // panggung dibuat sebelum nilai bawaan pengaturan terdaftar
        statusItem.autosaveName = "Temu" // posisi ikon diingat
        menu.delegate = self
        menu.autoenablesItems = false
        chat.app = self
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusItemClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // hanya event milik aplikasi ini sendiri (jendela ikon menu bar), bukan pemantauan global
        barPressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            if let self, let w = self.statusItem.button?.window, e.window === w {
                self.barPress = (NSEvent.mouseLocation, w.frame)
            }
            return e
        }
        // aplikasi lain jadi aktif (klik di luar popover) → popover ditutup
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.popover.performClose(nil)
            self?.petPopover.performClose(nil)
        }

        stage.onFrame = { [weak self] in self?.updateBar() }
        stage.onContextMenu = { [weak self] event, view in
            guard let self else { return }
            self.rebuildMenu()
            NSMenu.popUpContextMenu(self.menu, with: event, for: view)
        }
        account.onChange = { [weak self] in
            self?.refreshRoster()
            self?.settings.reload()
            self?.chat.refresh()
        }
        account.onNudge = { [weak self] from, text in self?.stage.deliverNudge(from: from, text: text) }
        stage.onChat = { [weak self] p in self?.openChat(p.ownerID) }
        account.isViewing = chat.isViewing
        account.onMessage = { [weak self] id, m in self?.chat.receive(id, m) }
        account.onPresence = { [weak self] in self?.chat.refresh() }
        account.onReceipt = { [weak self] id, delivered, read in self?.chat.receipt(id, delivered: delivered, read: read) }
        account.onReaction = { [weak self] id, r in self?.playReaction(r, friend: id, mine: false) ?? false }
        account.onFileOpened = { [weak self] id, msg in self?.chat.fileOpened(id, message: msg) }
        account.onUnread = { [weak self] from in
            guard let self else { return }
            self.barKey = ""
            self.updateBar()
            self.updateWave()
            if let from {
                self.chat.noteUnread(from: from)
                self.newMessage(from)
            }
            self.chat.refresh()
        }
        updater.onChange = { [weak self] in
            self?.settings.reload()
            self?.chat.refresh()
        }

        refreshRoster()
        let args = CommandLine.arguments
        if args.contains("--demo") { chat.startDemo() } else { account.start() } // --demo: data contoh, tanpa server
        updater.start()
        updateBar()
        // --popover: buka popover saat start (dipakai CI untuk tangkapan layar)
        // --demo-pet: obrolan di samping pet; --demo-pet-menu: popover menu bar saat obrolan ada di samping pet
        if args.contains("--popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if args.contains("--demo-pet") { self?.openChatNearPet() } else { self?.showPopover() }
            }
        }
        // --demo-bubble: balon kata berisi pesan teman (warna teman) untuk tangkapan layar CI
        if args.contains("--demo-bubble") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let p = self.stage.barPet else { return }
                self.stage.say(p, "Nanti malam jadi video call? 💛", seconds: 30, force: true, from: "Kiya")
            }
        }
        // --demo-reaction <nama>: emot dari teman diputar berulang di atas pet untuk tangkapan layar CI (mis. party)
        // --demo-reaction-at <detik>: diputar sekali dan dibekukan di detik itu, supaya tangkapan layarnya pasti
        if let i = args.firstIndex(of: "--demo-reaction"), i + 1 < args.count, let r = Reaction.find(args[i + 1]) {
            let at = args.firstIndex(of: "--demo-reaction-at").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
            // pet dipanggil turun dulu supaya pasti terlihat (tidak sedang pergi mencari hadiah)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.stage.summon() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if let at {
                    self?.stage.react(r, owner: "d", label: "dari Dina", freezeAt: at)
                    return
                }
                self?.playReaction(r, friend: "d", mine: false)
                let t = Timer(timeInterval: 1.4, repeats: true) { [weak self] _ in self?.playReaction(r, friend: "d", mine: false) }
                RunLoop.main.add(t, forMode: .common)
            }
        }
    }

    // MARK: popover

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        // Pengaturan › Pesan › Pintasan buka obrolan (⌥ / ⇧ / ⌃ / ⇧⌘ + klik): tombol yang ditahan harus persis sama
        let mods = (e?.modifierFlags ?? []).intersection([.command, .shift, .option, .control])
        let chatClick = e?.type == .leftMouseUp && Prefs.chatClick.keys.map { mods == $0 } == true
        // ⌘-seret (memindahkan ikon di menu bar) → bukan klik: jangan buka apa pun
        if e?.type == .leftMouseUp, let press = barPress {
            barPress = nil
            let moved = hypot(NSEvent.mouseLocation.x - press.point.x, NSEvent.mouseLocation.y - press.point.y) > 4
            if moved || sender.window.map({ $0.frame.origin != press.frame.origin }) == true { return }
        }
        // ⌃-klik = menu, kecuali ⌃-klik dipilih sebagai pintasan buka obrolan (klik kanan tetap menu)
        if e?.type == .rightMouseUp || (!chatClick && mods.contains(.control)) {
            showMenu()
        } else if popover.isShown {
            if chatClick, chat.chatElsewhere || !chat.expanded { // terbuka tanpa obrolan → buka ulang dengan obrolan
                popover.close()
                popoverClosed(popover)
                showPopover(withChat: true)
            } else {
                popover.performClose(nil)
            }
        } else if Date().timeIntervalSince(popoverLastClose) > 0.3 { // klik yang barusan menutup popover → jangan buka lagi
            // ⌘-klik: obrolan langsung terbuka di popover menu bar (walau Posisi obrolan = di samping pet,
            // atau Sembunyikan obrolan nyala)
            // (sejak 1.7.1: pintasannya bisa dipilih, karena ⌘-klik ditangkap macOS untuk memindahkan ikon)
            showPopover(withChat: chatClick)
        }
    }

    /// Pengaturan › Pesan › Posisi obrolan = di samping pet → pet tempat obrolan menempel (nil = tidak ada yang tampil)
    private func chatPetTarget() -> Pet? {
        let args = CommandLine.arguments // --demo-pet / --demo-pet-menu: tangkapan layar CI
        guard account.isLinked || chat.demo, Prefs.chatNearPet || args.contains("--demo-pet") || args.contains("--demo-pet-menu")
        else { return nil }
        return stage.chatPet(for: chat.selected)
    }

    /// Popover menu bar. Kalau obrolan tinggal di samping pet, isinya baris "Obrolan" (pembuka) + aksi pet + status;
    /// kalau tidak, obrolan lengkap seperti biasa.
    func showPopover(withChat: Bool = false) {
        guard let b = statusItem.button else { return }
        closePetChat()
        let elsewhere = !withChat && chatPetTarget() != nil
        if withChat, chat.linked { chat.reveal() }
        chat.chatElsewhere = elsewhere
        if elsewhere { chat.refresh() } else { chat.opened() }
        if !popover.isShown { popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Obrolan di samping pet (baris "Obrolan" di popover menu bar, ⌘-klik pet teman, "Kirim pesan ke …").
    /// Pet tidak tampil di desktop → obrolan lengkap di menu bar.
    func openChatNearPet() {
        guard let pet = chatPetTarget(), let host = petAnchor.contentView else {
            chat.chatElsewhere = false
            return showPopover()
        }
        if popover.isShown {
            popover.close()
            popoverClosed(popover) // close() tanpa animasi: rapikan sendiri walau notifikasi tutup tidak datang
        }
        if petPopover.isShown, pet !== waitingPet { closePetChat() }
        chat.reveal() // dibuka atas permintaan: obrolan langsung terlihat walau "Sembunyikan obrolan" nyala
        chat.opened()
        if !petPopover.isShown {
            let r = stage.screenRect(of: pet)
            petAnchor.setFrame(r, display: false)
            petAnchor.orderFrontRegardless()
            let onRight = r.midX > (petAnchor.screen ?? NSScreen.main)?.frame.midX ?? 0
            pet.waiting = true
            pet.facing = onRight ? -1 : 1 // menghadap ke popover
            waitingPet = pet
            petPopover.show(relativeTo: host.bounds, of: host, preferredEdge: onRight ? .minX : .maxX)
        }
        NSApp.activate(ignoringOtherApps: true)
        petPopover.contentViewController?.view.window?.makeKey()
    }

    private func closePetChat() {
        guard petPopover.isShown else { return }
        petPopover.close()
        popoverClosed(petPopover)
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
        if petPopover.isShown { petPopover.performClose(nil) }
    }

    /// Panel Buka / Simpan untuk lampiran obrolan sedang terbuka: popover jangan tertutup karena klik di panel itu
    func holdPopovers(_ hold: Bool) {
        for p in [popover, petPopover] where p.isShown || !hold {
            p.behavior = hold ? .applicationDefined : .transient
        }
    }

    func popoverDidClose(_ n: Notification) {
        if let p = n.object as? NSPopover { popoverClosed(p) }
    }

    /// Boleh terpanggil dua kali (notifikasi + penutupan manual)
    private func popoverClosed(_ p: NSPopover) {
        guard !p.isShown else { return } // notifikasi terlambat setelah popover yang sama dibuka lagi → abaikan
        if p === petPopover {
            if !(popover.isShown && !chat.chatElsewhere) { chat.closed() }
            releasePet()
        } else {
            popoverLastClose = Date()
            // obrolan ada di samping pet → popover menu bar tidak memegangnya
            if !chat.chatElsewhere, !petPopover.isShown { chat.closed() }
        }
    }

    /// Pet yang menunggu boleh bergerak lagi; jangkar popover disingkirkan
    private func releasePet() {
        waitingPet?.waiting = false
        waitingPet = nil
        petAnchor.orderOut(nil)
    }

    /// Menu lengkap untuk klik kanan: dipasang sebentar lalu dilepas lagi di menuDidClose
    private func showMenu() {
        closePopover()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ m: NSMenu) {
        if m === menu { statusItem.menu = nil }
    }

    /// Pet yang tampil: dari akun kalau terhubung, kalau tidak pet bawaan pilihan di Pengaturan
    func refreshRoster() {
        if account.isLinked {
            stage.setRoster(account.roster)
        } else {
            let sp = Prefs.species
            stage.setRoster([RosterEntry(id: "local-\(sp.id)", name: Prefs.petName, ownerName: "", mine: true, skin: Skin.builtin(sp))])
        }
        NSApp.applicationIconImage = (stage.barPet?.skin ?? Skin.builtin(Prefs.species)).portrait(.happy, points: 4)
        barKey = ""
        updateBar()
        chat.refresh() // avatar teman = pet-nya yang tampil di Mac
    }

    /// Ikon menu bar = pet yang sedang beraksi (diperbarui hanya kalau posenya berubah)
    /// Ada pesan belum dibaca → titik merah kecil di pojok kanan atas ikon.
    func updateBar() {
        guard let b = statusItem.button else { return }
        let unread = account.unreadTotal
        let note = unread > 0 ? "\n\(unread) pesan baru — klik untuk membaca" : "\nKlik untuk ngobrol, " +
            (Prefs.chatClickLabel.map { "\($0) untuk langsung membuka obrolan, " } ?? "") + "klik kanan untuk menu"
        guard let p = stage.barPet else {
            if barKey != "empty|\(unread)|\(Prefs.unreadBadge)|\(Prefs.chatClickLabel ?? "")" {
                barKey = "empty|\(unread)|\(Prefs.unreadBadge)|\(Prefs.chatClickLabel ?? "")"
                b.image = withBadge(Skin.builtin(Prefs.species).barImage(.sleep, flip: false), unread)
                b.toolTip = (account.isLinked ? "Belum ada pet yang tampil di Mac. Atur di web Temu." : appDisplayName) + note
            }
            return
        }
        let key = "\(p.id)|\(p.frame.rawValue)|\(p.facing < 0)|\(unread)|\(Prefs.unreadBadge)|\(Prefs.chatClickLabel ?? "")"
        guard key != barKey else { return }
        barKey = key
        b.image = withBadge(p.skin.barImage(p.frame, flip: p.facing < 0), unread)
        b.toolTip = stage.describe(p) + note
    }

    /// Tanda pesan belum dibaca di samping pet (tidak menimpa sprite, supaya tetap terlihat pada pet berwarna gelap).
    /// Pengaturan › Pesan › Tanda pesan baru: titik merah / jumlah pesan / tanpa tanda.
    private func withBadge(_ img: NSImage, _ unread: Int) -> NSImage {
        guard unread > 0, Prefs.unreadBadge != 2 else { return img }
        let w = img.size.width, h = img.size.height
        if Prefs.unreadBadge == 1 {
            // pil berangka, rata atas
            let text = NSAttributedString(string: unread > 99 ? "99+" : "\(unread)", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white,
            ])
            let tw = ceil(text.size().width)
            let pill = NSSize(width: max(12, tw + 7), height: 12)
            return NSImage(size: NSSize(width: w + 1 + pill.width, height: h), flipped: false) { _ in
                img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                let r = NSRect(x: w + 1, y: h - pill.height, width: pill.width, height: pill.height)
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: r, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                let ts = text.size()
                text.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
                return true
            }
        }
        // titik merah di kanan atas, di luar sprite
        let d: CGFloat = 8
        return NSImage(size: NSSize(width: w + d - 1, height: h), flipped: false) { _ in
            img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: w - 1, y: h - d, width: d, height: d)).fill()
            return true
        }
    }

    /// Nyalakan / matikan lambaian pet di ikon menu bar sesuai jumlah belum dibaca & pengaturan
    func updateWave() {
        let on = Prefs.unreadWave && account.unreadTotal > 0
        if !on { waveTimer?.invalidate(); waveTimer = nil; return }
        guard waveTimer == nil else { return }
        stage.waveBarPet()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.stage.waveBarPet() }
        t.tolerance = 4
        RunLoop.main.add(t, forMode: .common)
        waveTimer = t
    }

    // MARK: chat

    /// Buka popover dengan obrolan teman ini (⌘-klik pet-nya, atau "Kirim pesan ke …" di menu)
    func openChat(_ friendID: String) {
        guard account.isLinked, !friendID.isEmpty else { return }
        chat.refresh()
        chat.select(friendID)
        chat.reveal() // diminta langsung: obrolan terbuka walau "Sembunyikan obrolan" nyala
        if chatPetTarget() != nil { openChatNearPet() } else { showPopover() }
    }

    /// Emot lewat pet di desktop Mac ini, selalu di atas pet teman itu: emot darinya, atau emot yang baru kukirim
    /// kepadanya (supaya aku ikut melihat yang dia lihat). Pet-nya tidak tampil → di atas pet-ku dengan label nama.
    @discardableResult
    func playReaction(_ r: Reaction, friend: String, mine: Bool) -> Bool {
        let name = chat.friends.first(where: { $0.id == friend })?.name ?? account.friendName(friend)
        return stage.react(r, owner: friend, label: mine ? "untuk \(name)" : "dari \(name)")
    }

    @objc func openChatItem(_ it: NSMenuItem) {
        if let id = it.representedObject as? String { openChat(id) }
    }

    /// Pesan baru yang belum dibaca: bunyi (kalau dinyalakan) + pet pengirim memberi tahu di desktop
    private func newMessage(_ from: String) {
        if Prefs.messageSound, Date().timeIntervalSince(lastSound) > 1.5 {
            lastSound = Date()
            NSSound(named: NSSound.Name(Prefs.messageSoundName))?.play()
        }
        // emot yang sudah diputar di atas pet pengirim sudah memberi tahu; tidak perlu balon "ada pesan"
        if account.takeReacted(from) {
            _ = account.takeIncoming(from)
            return
        }
        let name = account.friendName(from)
        guard Prefs.petMessages == 1, stage.hasPet(from) else {
            _ = account.takeIncoming(from) // tidak dipakai; jangan sampai muncul di kabar berikutnya
            stage.announceMessage(from: from, name: name)
            return
        }
        // "Tampilkan isi pesan": isi dari saluran real-time; kalau datang lewat sync (tanpa isi), ambil pesan terakhirnya
        if let text = account.takeIncoming(from) {
            stage.announceMessage(from: from, name: name, text: text)
            return
        }
        account.loadMessages(from) { [weak self] msgs, _, _ in
            let text = msgs?.last(where: { !$0.mine })?.text
            self?.stage.announceMessage(from: from, name: name, text: text)
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ m: NSMenu) {
        guard m === menu else { return }
        account.sync(force: false) // data terbaru saat menu dibuka (dilewati kalau baru saja diambil)
        rebuildMenu()
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", on: Bool? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        it.isEnabled = action != nil
        if let on { it.state = on ? .on : .off }
        return it
    }

    func rebuildMenu() {
        menu.removeAllItems()
        if stage.pets.isEmpty {
            menu.addItem(item(account.isLinked ? "Belum ada pet yang tampil di Mac" : "Belum ada pet", nil))
        }
        for p in stage.pets.prefix(6) {
            let it = item(stage.describe(p) + (p.mine || p.ownerName.isEmpty ? "" : "  ·  titipan \(p.ownerName)"), nil)
            it.image = p.skin.barImage(.idle, flip: false)
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let has = !stage.pets.isEmpty
        let actions = [item("Beri makan", #selector(AppDelegate.feed)), item("Ajak main bola", #selector(AppDelegate.play)),
                       item("Panggil ke sini", #selector(AppDelegate.summon))]
        for it in actions {
            it.isEnabled = has
            menu.addItem(it)
        }
        menu.addItem(item("Tampil di desktop", #selector(toggleDesktop), on: Prefs.showDesktop))
        menu.addItem(.separator())

        // pesan: yang belum dibaca dulu, lalu teman yang pet-nya tampil di Mac ini
        if account.isLinked {
            var shown = Set<String>()
            for (id, n) in account.unread.sorted(by: { $0.value > $1.value }).prefix(6) {
                let it = item("\(account.friendName(id)) — \(n) pesan baru", #selector(openChatItem(_:)))
                it.representedObject = id
                it.image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "Pesan baru")
                menu.addItem(it)
                shown.insert(id)
            }
            for p in stage.pets where !p.mine && !p.ownerID.isEmpty && !shown.contains(p.ownerID) && shown.count < 6 {
                let it = item("Kirim pesan ke \(p.ownerName)…", #selector(openChatItem(_:)))
                it.representedObject = p.ownerID
                it.toolTip = "Atau ⌘-klik pet \(p.ownerName) di desktop"
                menu.addItem(it)
                shown.insert(p.ownerID)
            }
            if !shown.isEmpty { menu.addItem(.separator()) }
        }

        menu.addItem(item(account.statusText, nil))
        if account.isLinked {
            menu.addItem(item("Atur pet di web…", #selector(openWeb)))
            menu.addItem(item("Segarkan pet", #selector(syncNow)))
        } else if account.linkCode != nil {
            menu.addItem(item("Buka halaman persetujuan lagi…", #selector(openLinkPage)))
            menu.addItem(item("Batalkan", #selector(cancelLink)))
        } else {
            menu.addItem(item("Hubungkan akun…", #selector(linkAccount)))
        }
        menu.addItem(.separator())

        menu.addItem(item("Pengaturan…", #selector(openSettings), key: ","))
        menu.addItem(updater.menuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: aksi

    /// Aksi yang butuh pet terlihat: nyalakan desktop dulu kalau sedang disembunyikan
    private func ensureDesktop() {
        guard !Prefs.showDesktop else { return }
        defaults.set(true, forKey: "showDesktop")
        stage.applyPrefs()
        settings.reload()
    }

    @objc func feed() { ensureDesktop(); stage.feed() }
    @objc func play() { ensureDesktop(); stage.play() }
    @objc func summon() { ensureDesktop(); stage.summon() }
    @objc func toggleDesktop() {
        defaults.set(!Prefs.showDesktop, forKey: "showDesktop")
        stage.applyPrefs()
        settings.reload()
        chat.refresh()
    }
    @objc func linkAccount() { account.beginLink() }
    @objc func cancelLink() {
        account.cancelLink()
        account.sync(force: false)
        settings.reload()
    }
    @objc func openLinkPage() {
        guard let code = account.linkCode, let u = URL(string: account.server + "/hubungkan?code=" + code) else { return }
        NSWorkspace.shared.open(u)
    }
    @objc func unlinkAccount() {
        let a = NSAlert()
        a.messageText = "Putuskan Mac ini dari akun?"
        a.informativeText = "Pet dari akunmu tidak lagi tampil di Mac ini. Pet bawaan pilihanmu di Pengaturan yang akan menemani."
        a.addButton(withTitle: "Putuskan")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        account.unlink()
    }
    @objc func openWeb() { openWebPath("/pet") }
    func openWebPath(_ path: String) {
        closePopover()
        if let u = URL(string: account.server + path) { NSWorkspace.shared.open(u) }
    }
    @objc func syncNow() { account.sync(force: true) }
    @objc func openSettings() {
        closePopover()
        settings.show(.general)
    }
    func checkUpdate() {
        closePopover()
        updater.checkNow()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Gagal mengatur 'Buka saat login'"
            a.informativeText = "Pastikan Temu.app ada di folder Applications.\n\n\(error.localizedDescription)"
            a.runModal()
        }
    }

    /// Hapus Temu dari Mac: login item, pengaturan, token akun, lalu .app dipindahkan ke Tong Sampah
    @objc func uninstall() {
        let a = NSAlert()
        a.messageText = "Uninstall Temu?"
        a.informativeText = "Temu akan dihapus dari 'Buka saat login', pengaturan dan token akunnya di Mac ini dihapus, lalu Temu.app dipindahkan ke Tong Sampah. Akun dan pet-mu di web tidak tersentuh."
        a.alertStyle = .warning
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        try? SMAppService.mainApp.unregister()
        if account.isLinked { account.unlink() }
        account.wipe()
        if let id = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: id)
            defaults.synchronize()
        }
        let appURL = Bundle.main.bundleURL
        if appURL.pathExtension != "app" || (try? FileManager.default.trashItem(at: appURL, resultingItemURL: nil)) == nil {
            // tidak punya izin tulis (mis. dipasang oleh admin lain) → minta pengguna menghapus manual
            let f = NSAlert()
            f.messageText = "Temu.app tidak bisa dipindahkan otomatis"
            f.informativeText = "Pengaturan sudah dihapus. Seret Temu.app ke Tong Sampah secara manual."
            f.runModal()
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // tanpa ikon di Dock
app.run()
