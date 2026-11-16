// Temu — a little way to be together.
// Versi pixel kecil dirimu / pet-mu yang hidup di layar Mac orang terdekat (ikon di menu bar + pet di desktop)
// Build: ./scripts/build.sh  (butuh Xcode Command Line Tools)
//
// Berkas:
//   Sprites.swift   gambar pet bawaan & properti (teks → piksel), Skin (16 pose)
//   Pet.swift       panggung desktop: gerak, kejutan, interaksi mouse
//   Lines.swift     celoteh pet
//   Client.swift    akun Temu: hubungkan Mac, ambil pet & sapaan teman
//   Settings.swift  jendela Pengaturan
//   main.swift      ikon menu bar, menu, pembaruan, siklus hidup aplikasi

import Cocoa
import ServiceManagement

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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let stage = Stage()
    let account = Account()
    let updater = Updater()
    let menu = NSMenu()
    lazy var settings = SettingsWindow(app: self)
    private var barKey = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        Prefs.register()
        stage.applyPrefs() // panggung dibuat sebelum nilai bawaan pengaturan terdaftar
        statusItem.autosaveName = "Temu" // posisi ikon diingat
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu // klik kiri maupun kanan membuka menu yang sama

        stage.onFrame = { [weak self] in self?.updateBar() }
        stage.onContextMenu = { [weak self] event, view in
            guard let self else { return }
            self.rebuildMenu()
            NSMenu.popUpContextMenu(self.menu, with: event, for: view)
        }
        account.onChange = { [weak self] in
            self?.refreshRoster()
            self?.settings.reload()
        }
        account.onNudge = { [weak self] from, text in self?.stage.deliverNudge(from: from, text: text) }
        updater.onChange = { [weak self] in self?.settings.reload() }

        refreshRoster()
        account.start()
        updater.start()
        updateBar()
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
    }

    /// Ikon menu bar = pet yang sedang beraksi (diperbarui hanya kalau posenya berubah)
    func updateBar() {
        guard let b = statusItem.button else { return }
        guard let p = stage.barPet else {
            if barKey != "empty" {
                barKey = "empty"
                b.image = Skin.builtin(Prefs.species).barImage(.sleep, flip: false)
                b.toolTip = account.isLinked ? "Belum ada pet yang tampil di Mac. Atur di web Temu." : appDisplayName
            }
            return
        }
        let key = "\(p.id)|\(p.frame.rawValue)|\(p.facing < 0)"
        guard key != barKey else { return }
        barKey = key
        b.image = p.skin.barImage(p.frame, flip: p.facing < 0)
        b.toolTip = stage.describe(p)
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
    @objc func openWeb() {
        if let u = URL(string: account.server + "/pet") { NSWorkspace.shared.open(u) }
    }
    @objc func syncNow() { account.sync(force: true) }
    @objc func openSettings() { settings.show(.general) }

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
