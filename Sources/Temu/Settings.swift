// Temu — jendela Pengaturan (tab Umum, Pet, Akun, Tentang)
// Gaya mengikuti jendela Pengaturan LiteCalendar: kartu ala System Settings, satu baris = judul + keterangan + satu kontrol.

import Cocoa
import ServiceManagement

// MARK: - Potongan formulir

/// Kartu berlatar gaya System Settings; warnanya ikut tema terang / gelap
final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("tidak dipakai") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
    }
}

/// Potongan tata letak formulir: setiap baris = judul + keterangan di kiri, satu kontrol di kanan.
/// Pilihan nyala / mati selalu NSSwitch, pilihan banyak = pop-up, aksi = tombol berlabel kata kerja.
enum Form {
    static func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        return l
    }

    static func note(_ s: String, width: CGFloat = 340) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = width
        return l
    }

    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 8) -> NSStackView {
        let v = NSStackView(views: views)
        v.orientation = vertical ? .vertical : .horizontal
        v.alignment = vertical ? .leading : .centerY
        v.spacing = spacing
        return v
    }

    static func row(_ title: String, _ detail: String?, _ control: NSView?) -> NSView {
        row(label(title, weight: .medium), detail, control)
    }

    static func row(_ head: NSView, _ detail: String?, _ control: NSView?) -> NSView {
        var texts: [NSView] = [head]
        if let detail { texts.append(note(detail, width: control == nil ? 500 : 340)) }
        let left = stack(texts, spacing: 3)
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let r = stack([left], vertical: false, spacing: 16)
        if let control {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            r.addArrangedSubview(control)
        }
        return r
    }

    static func section(_ title: String, _ rows: [NSView]) -> NSView {
        let card = CardView()
        let inner = stack([], spacing: 10)
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let sep = NSBox()
                sep.boxType = .separator
                inner.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
            }
            inner.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        let out = stack([label(title, weight: .semibold), card], spacing: 6)
        card.widthAnchor.constraint(equalTo: out.widthAnchor).isActive = true
        return out
    }

    static func toggle(_ target: AnyObject, _ action: Selector) -> NSSwitch {
        let s = NSSwitch()
        s.target = target
        s.action = action
        return s
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }

    /// Pop-up pilihan; tag tiap item = nilai yang disimpan
    static func popup(_ choices: [(String, Int)], _ target: AnyObject, _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        for (title, tag) in choices {
            p.addItem(withTitle: title)
            p.lastItem?.tag = tag
        }
        p.target = target
        p.action = action
        return p
    }
}

/// View dokumen untuk scroll view: koordinat dari atas, jadi isi mulai di atas (bukan menempel ke bawah)
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Halaman berukuran tetap berisi bagian-bagian formulir dari atas ke bawah
/// (isinya bisa di-scroll bila lebih tinggi dari jendela)
final class FormPage: NSViewController {
    private let scroll = NSScrollView()
    private let doc = FlippedView()

    override func loadView() {
        let v = NSView(frame: NSRect(origin: .zero, size: SettingsWindow.size))
        for c in [v.widthAnchor.constraint(equalToConstant: SettingsWindow.size.width),
                  v.heightAnchor.constraint(equalToConstant: SettingsWindow.size.height)] {
            c.priority = .defaultLow
            c.isActive = true
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        v.addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        view = v
        preferredContentSize = SettingsWindow.size
    }

    func set(_ sections: [NSView]) {
        _ = view // pastikan loadView sudah jalan
        // isi dokumen diganti; posisi scroll tetap (scroll view tidak dibuat ulang)
        doc.subviews.forEach { $0.removeFromSuperview() }
        let content = Form.stack([], spacing: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: doc.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -20),
        ])
        for s in sections {
            content.addArrangedSubview(s)
            s.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }
}

// MARK: - Jendela Pengaturan

final class SettingsWindow: NSObject, NSTextFieldDelegate {
    enum Tab: Int { case general, pet, account, about }
    static let size = NSSize(width: 600, height: 540)

    unowned let app: AppDelegate
    private var window: NSWindow?
    private let tabs = NSTabViewController()
    private let general = FormPage()
    private let petPage = FormPage()
    private let accountPage = FormPage()
    private let about = FormPage()
    private var signatures: [String] = ["", "", ""] // Pet, Akun, Tentang
    private var pending = false

    // kontrol tab Umum (dibuat sekali, statusnya diperbarui di tempat supaya animasi NSSwitch tidak terputus)
    private lazy var desktopSwitch = Form.toggle(self, #selector(boolChanged(_:)))
    private lazy var sizePopup = Form.popup([("Kecil", 2), ("Sedang", 3), ("Besar", 4), ("Jumbo", 5)], self, #selector(intChanged(_:)))
    private lazy var livelyPopup = Form.popup([("Kalem", 0), ("Biasa", 1), ("Lincah", 2)], self, #selector(intChanged(_:)))
    private lazy var levelPopup = Form.popup([("Di atas semua jendela", 0), ("Hanya di desktop", 1)], self, #selector(intChanged(_:)))
    private lazy var bubbleSwitch = Form.toggle(self, #selector(boolChanged(_:)))
    private lazy var surpriseSwitch = Form.toggle(self, #selector(boolChanged(_:)))
    private lazy var cursorSwitch = Form.toggle(self, #selector(boolChanged(_:)))
    private lazy var nightSwitch = Form.toggle(self, #selector(boolChanged(_:)))
    private lazy var remindSwitch = Form.toggle(self, #selector(boolChanged(_:)))
    private lazy var remindPopup = Form.popup([("Tiap 20 menit", 20), ("Tiap 30 menit", 30), ("Tiap 45 menit", 45), ("Tiap 1 jam", 60),
                                               ("Tiap 2 jam", 120)], self, #selector(intChanged(_:)))
    private lazy var loginSwitch = Form.toggle(self, #selector(loginChanged(_:)))

    /// kontrol → kunci UserDefaults
    private lazy var keys: [(NSControl, String)] = [
        (desktopSwitch, "showDesktop"), (sizePopup, "petScale"), (livelyPopup, "liveliness"), (levelPopup, "stageLevel"),
        (bubbleSwitch, "bubbles"), (surpriseSwitch, "surprises"), (cursorSwitch, "followCursor"), (nightSwitch, "sleepAtNight"),
        (remindSwitch, "reminders"), (remindPopup, "reminderMinutes"),
    ]

    // tab Pet & Akun
    private lazy var speciesPopup = Form.popup(Species.all.enumerated().map { ($0.element.title, $0.offset) }, self, #selector(speciesChanged(_:)))
    private lazy var nameField: NSTextField = {
        let f = NSTextField(string: "")
        f.delegate = self
        f.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return f
    }()
    private lazy var serverField: NSTextField = {
        let f = NSTextField(string: "")
        f.delegate = self
        f.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return f
    }()

    init(app: AppDelegate) {
        self.app = app
        super.init()
    }

    func show(_ tab: Tab = .general) {
        if window == nil { build() }
        rebuild()
        tabs.selectedTabViewItemIndex = tab.rawValue
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Status aplikasi berubah → perbarui isi jendela (digabung, dijalankan setelah aksi yang sedang berjalan selesai)
    func reload() {
        guard window != nil, !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.rebuild()
        }
    }

    private func build() {
        tabs.tabStyle = .toolbar
        let pages: [(NSViewController, String, String)] = [(general, "Umum", "gearshape"), (petPage, "Pet", "pawprint"),
                                                           (accountPage, "Akun", "person.crop.circle"), (about, "Tentang", "info.circle")]
        for (vc, title, icon) in pages {
            vc.title = title
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.title = "Pengaturan \(appDisplayName)"
        w.isReleasedWhenClosed = false
        w.setContentSize(SettingsWindow.size)
        w.center()
        window = w

        general.set([
            Form.section("Desktop", [
                Form.row("Tampil di desktop", "Pet berjalan di tepi bawah layar. Kalau dimatikan, pet hanya hidup di ikon menu bar.", desktopSwitch),
                Form.row("Ukuran", nil, sizePopup),
                Form.row("Tempat bermain", "\"Hanya di desktop\" = di belakang jendela aplikasi, terlihat saat desktop kosong.", levelPopup),
            ]),
            Form.section("Perilaku", [
                Form.row("Sifat", "Kalem lebih sering diam dan rebahan; lincah lebih sering berlari dan membuat kejutan.", livelyPopup),
                Form.row("Kejutan", "Bersin, tersandung, mengejar kupu-kupu, main bola, pulang membawa hadiah.", surpriseSwitch),
                Form.row("Balon kata", "Pet sesekali berceloteh. Sapaan dari teman tetap tampil walau ini dimatikan.", bubbleSwitch),
                Form.row("Mendekati kursor", "Sesekali pet menghampiri kursor. Hanya posisi kursor yang dibaca, bukan klik atau ketikan.", cursorSwitch),
                Form.row("Tidur di malam hari", "Antara pukul 22.00 dan 06.00 pet lebih sering tidur.", nightSwitch),
            ]),
            Form.section("Pengingat lembut", [
                Form.row("Ingatkan istirahat", "Pet mengingatkan minum air, meregangkan badan, dan mengistirahatkan mata.", remindSwitch),
                Form.row("Seberapa sering", nil, remindPopup),
            ]),
            Form.section("Sistem", [
                Form.row("Buka saat login", "\(appDisplayName) otomatis berjalan setiap Mac dinyalakan.", loginSwitch),
            ]),
        ])
    }

    private func rebuild() {
        guard window != nil else { return }
        for (control, key) in keys {
            if let sw = control as? NSSwitch { sw.state = defaults.bool(forKey: key) ? .on : .off }
            if let pop = control as? NSPopUpButton { pop.selectItem(withTag: defaults.integer(forKey: key)) }
        }
        sizePopup.isEnabled = Prefs.showDesktop
        levelPopup.isEnabled = Prefs.showDesktop
        remindPopup.isEnabled = Prefs.reminders
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off

        // Pet, Akun & Tentang dibangun ulang hanya kalau isinya berubah
        let acc = app.account
        let sigs = [
            "\(acc.isLinked)|\(Prefs.species.id)|" + app.stage.pets.map { $0.id + $0.name }.joined(separator: ","),
            "\(acc.isLinked)|\(acc.statusText)|\(acc.linkCode ?? "")|\(acc.server)",
            "\(app.updater.hasUpdate)|\(app.updater.latest?.version ?? "")",
        ]
        if sigs[0] != signatures[0] { petPage.set(petSections()) }
        if sigs[1] != signatures[1] { accountPage.set(accountSections()) }
        if sigs[2] != signatures[2] { about.set(aboutSections()) }
        signatures = sigs
    }

    private func portrait(_ skin: Skin, _ frame: Frame = .idle) -> NSImageView {
        let v = NSImageView(image: skin.portrait(frame, points: 2))
        v.imageScaling = .scaleNone
        v.widthAnchor.constraint(equalToConstant: 64).isActive = true
        v.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return v
    }

    private func petSections() -> [NSView] {
        if app.account.isLinked {
            let rows: [NSView] = app.stage.pets.map { p in
                let head = Form.stack([portrait(p.skin), Form.stack([
                    Form.label(p.name, weight: .medium),
                    Form.note(p.mine ? "Pet-mu" : "Titipan dari \(p.ownerName)", width: 300),
                ], spacing: 2)], vertical: false, spacing: 10)
                return Form.row(head, nil, nil)
            }
            let manage = Form.row("Atur pet", "Membuat pet, menggambar ulang, dan memilih yang tampil di Mac dilakukan di web.",
                                  Form.button("Buka web Temu", app, #selector(AppDelegate.openWeb)))
            if rows.isEmpty {
                return [Form.section("Pet di Mac ini", [
                    Form.row("Belum ada pet yang tampil", "Nyalakan \"Tampil di Mac\" pada pet-mu di web.", nil), manage,
                ])]
            }
            return [Form.section("Pet di Mac ini", rows), Form.section("Kelola", [manage])]
        }
        speciesPopup.selectItem(withTag: Species.all.firstIndex(where: { $0.id == Prefs.species.id }) ?? 0)
        nameField.stringValue = defaults.string(forKey: "petName") ?? ""
        nameField.placeholderString = Prefs.species.defaultName
        let preview = Form.stack([portrait(Skin.builtin(Prefs.species), .happy), Form.stack([
            Form.label(Prefs.petName, size: 15, weight: .semibold),
            Form.note("Pet bawaan. Hubungkan akun untuk memakai pet buatanmu sendiri dan pet titipan teman.", width: 380),
        ], spacing: 2)], vertical: false, spacing: 12)
        return [
            preview,
            Form.section("Pet bawaan", [
                Form.row("Jenis", nil, speciesPopup),
                Form.row("Nama", "Kosongkan untuk memakai nama bawaannya.", nameField),
            ]),
            Form.section("Pet buatan sendiri", [
                Form.row("Hubungkan akun", "Gambar pet sendiri, buat dari foto, atau minta pet teman lewat web Temu.",
                         Form.button("Hubungkan akun…", app, #selector(AppDelegate.linkAccount))),
            ]),
        ]
    }

    private func accountSections() -> [NSView] {
        let acc = app.account
        let line = Form.label(acc.statusText)
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var rows: [NSView] = [line]
        if acc.isLinked {
            rows.append(Form.row("Web Temu", "Kelola pet, teman, dan Mac yang terhubung.",
                                 Form.button("Buka di browser", app, #selector(AppDelegate.openWeb))))
            rows.append(Form.row("Segarkan", "Pet diperbarui otomatis tiap menit.", Form.button("Segarkan sekarang", app, #selector(AppDelegate.syncNow))))
            rows.append(Form.row("Putuskan akun", "Token dihapus dari Keychain Mac ini dan dicabut di server.",
                                 Form.button("Putuskan…", app, #selector(AppDelegate.unlinkAccount))))
        } else if let code = acc.linkCode {
            let big = Form.label(code, size: 22, weight: .semibold)
            big.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
            rows.append(Form.row(big, "Pastikan kode ini sama dengan yang tampil di browser, lalu setujui di sana.",
                                 Form.button("Buka halaman lagi", app, #selector(AppDelegate.openLinkPage))))
            rows.append(Form.row("Batalkan", nil, Form.button("Batal", app, #selector(AppDelegate.cancelLink))))
        } else {
            rows.append(Form.row("Hubungkan akun", "Browser terbuka untuk menyetujui Mac ini. Password tidak pernah diketik di aplikasi.",
                                 Form.button("Hubungkan akun…", app, #selector(AppDelegate.linkAccount))))
        }
        serverField.stringValue = defaults.string(forKey: "server") ?? ""
        serverField.placeholderString = Account.defaultServer
        serverField.isEnabled = !acc.isLinked && acc.linkCode == nil
        return [
            Form.section("Akun", rows),
            Form.section("Server", [
                Form.row("Alamat server", "Hanya diubah kalau Anda menjalankan server Temu sendiri. Putuskan akun dulu untuk mengubahnya.", serverField),
            ]),
        ]
    }

    private func aboutSections() -> [NSView] {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let head = Form.stack([icon, Form.stack([Form.label(appDisplayName, size: 15, weight: .semibold),
                                                 Form.note("Versi \(Updater.current) · A little way to be together.")],
                                                spacing: 2)],
                              vertical: false, spacing: 12)
        let up = app.updater
        let uninstall = Form.button("Uninstall…", app, #selector(AppDelegate.uninstall))
        uninstall.hasDestructiveAction = true
        return [
            head,
            Form.section("Pembaruan", [
                Form.row("Pembaruan", up.hasUpdate ? "Versi \(up.latest?.version ?? "") tersedia." :
                         "Dicek otomatis sehari sekali lewat GitHub Releases.",
                         Form.button(up.hasUpdate ? "Update…" : "Cek pembaruan…", up, #selector(Updater.checkNow))),
            ]),
            Form.section("Hanya mainan", [
                Form.row("Yang dilakukan \(appDisplayName)", "Menggambar pet di layar, membaca posisi kursor, dan (kalau akun terhubung) mengambil " +
                         "gambar pet serta sapaan teman dari server Temu.", nil),
                Form.row("Yang tidak dilakukan", "Tidak membaca layar, ketikan, berkas, atau aplikasi lain. Tidak meminta izin Aksesibilitas, " +
                         "Perekaman Layar, atau akses lain. Kode sumbernya terbuka.",
                         Form.button("Lihat kode", self, #selector(openSource))),
            ]),
            Form.section("Hapus \(appDisplayName)", [
                Form.row("Uninstall \(appDisplayName)", "Hapus dari 'Buka saat login', hapus pengaturan & token akun, " +
                         "lalu pindahkan aplikasinya ke Tong Sampah.", uninstall),
            ]),
        ]
    }

    // MARK: aksi

    private func key(for control: NSControl) -> String? { keys.first(where: { $0.0 === control })?.1 }

    @objc func boolChanged(_ s: NSSwitch) {
        guard let k = key(for: s) else { return }
        defaults.set(s.state == .on, forKey: k)
        app.stage.applyPrefs()
        reload()
    }
    @objc func intChanged(_ p: NSPopUpButton) {
        guard let k = key(for: p) else { return }
        defaults.set(p.selectedTag(), forKey: k)
        app.stage.applyPrefs()
        reload()
    }
    @objc func loginChanged(_ s: NSSwitch) {
        app.toggleLogin()
        reload()
    }
    @objc func speciesChanged(_ p: NSPopUpButton) {
        let i = p.selectedTag()
        guard i >= 0, i < Species.all.count else { return }
        defaults.set(Species.all[i].id, forKey: "species")
        app.refreshRoster()
        reload()
    }
    @objc func openSource() {
        if let u = URL(string: "https://github.com/\(appRepo)") { NSWorkspace.shared.open(u) }
    }

    /// Nama pet / alamat server disimpan saat selesai diketik
    func controlTextDidEndEditing(_ n: Notification) {
        guard let f = n.object as? NSTextField else { return }
        if f === nameField {
            defaults.set(String(f.stringValue.prefix(24)), forKey: "petName")
            signatures[0] = ""
            app.refreshRoster()
        } else if f === serverField {
            app.account.server = f.stringValue
        }
        reload()
    }
}
