// Temu — jendela chat dengan teman. Dibuka dengan ⌘-klik pet teman di desktop, atau dari menu Temu.
// Pesan masuk real-time lewat saluran WebSocket di Client.swift; kirim lewat HTTP (/api/app/messages/…).
// Gaya mengikuti HIG: kontrol bawaan sistem, satu kolom teks + tombol "Kirim".

import Cocoa

/// Gelembung pesan; warnanya ikut tema terang / gelap dan warna aksen sistem
final class ChatBubbleView: NSView {
    let mine: Bool
    init(mine: Bool) {
        self.mine = mine
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("tidak dipakai") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (mine ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor).cgColor
        layer?.cornerRadius = 12
    }
}

final class ChatWindow: NSObject, NSWindowDelegate {
    let friendID: String
    unowned let app: AppDelegate
    private let window: NSWindow
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let list = Form.stack([], spacing: 8)
    private let field = NSTextField()
    private lazy var sendButton = Form.button("Kirim", self, #selector(send))
    private lazy var olderButton = Form.button("Muat pesan sebelumnya", self, #selector(loadOlder))
    private let status = Form.note("", width: 320)
    private let titleLabel = Form.label("", size: 13, weight: .semibold)
    private let portrait = NSImageView()
    private var messages: [ChatMessage] = []
    private var hasMore = false
    private var loading = false
    private var sending = false
    private var refreshTimer: Timer?
    var onClose: (() -> Void)?

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = "HH.mm"
        return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = "d MMM, HH.mm"
        return f
    }()

    init(app: AppDelegate, friendID: String) {
        self.app = app
        self.friendID = friendID
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 360)
        window.delegate = self
        build()
        window.center()
        window.setFrameAutosaveName("TemuChat")
    }

    /// Jendela ini sedang dibaca (aktif di depan) → pesan baru langsung dianggap terbaca
    var isViewing: Bool { NSApp.isActive && window.isVisible && window.isKeyWindow && !window.isMiniaturized }

    func show() {
        refreshHeader()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        reload()
        app.account.markRead(friendID)
        startRefresh()
    }

    func close() { window.close() }

    // MARK: tata letak

    private func build() {
        let content = NSView()
        window.contentView = content

        portrait.imageScaling = .scaleNone
        portrait.widthAnchor.constraint(equalToConstant: 32).isActive = true
        portrait.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let header = Form.stack([portrait, Form.stack([titleLabel,
            Form.note("Pesan sampai langsung ke Mac-nya.", width: 280)], spacing: 1)], vertical: false, spacing: 10)

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        list.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)

        field.placeholderString = "Tulis pesan…"
        field.target = self
        field.action = #selector(send) // Enter = kirim
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        sendButton.keyEquivalent = "\r"
        let bottom = Form.stack([field, sendButton], vertical: false, spacing: 8)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let sep1 = NSBox(), sep2 = NSBox()
        sep1.boxType = .separator
        sep2.boxType = .separator
        for v in [header, sep1, scroll, sep2, bottom, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            sep1.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            sep1.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep1.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep1.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sep2.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            sep2.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep2.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
            doc.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 12),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            list.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor, constant: -12),
        ])
        // tinggi dokumen = isi pesan (tapi minimal setinggi area gulir)
        let hug = doc.heightAnchor.constraint(equalTo: list.heightAnchor, constant: 24)
        hug.priority = .defaultLow
        hug.isActive = true
    }

    private func refreshHeader() {
        let name = app.account.friendName(friendID)
        window.title = "Pesan · \(name)"
        titleLabel.stringValue = name
        if let p = app.stage.pets.first(where: { !$0.mine && $0.ownerID == friendID }) {
            portrait.image = p.skin.portrait(.happy, points: 1)
            portrait.isHidden = false
        } else {
            portrait.isHidden = true
        }
    }

    private func row(_ m: ChatMessage) -> NSView {
        let text = NSTextField(wrappingLabelWithString: m.text)
        text.font = .systemFont(ofSize: 13)
        text.textColor = m.mine ? .white : .labelColor
        text.preferredMaxLayoutWidth = 240
        text.isSelectable = true
        text.translatesAutoresizingMaskIntoConstraints = false
        let bubble = ChatBubbleView(mine: m.mine)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(text)
        let d = m.date
        let time = Form.note(Calendar.current.isDateInToday(d) ? ChatWindow.timeFormat.string(from: d) : ChatWindow.dayFormat.string(from: d))
        let col = Form.stack([bubble, time], spacing: 2)
        col.alignment = m.mine ? .trailing : .leading
        col.translatesAutoresizingMaskIntoConstraints = false
        let r = NSView()
        r.addSubview(col)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -6),
            text.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            col.topAnchor.constraint(equalTo: r.topAnchor),
            col.bottomAnchor.constraint(equalTo: r.bottomAnchor),
            m.mine ? col.trailingAnchor.constraint(equalTo: r.trailingAnchor) : col.leadingAnchor.constraint(equalTo: r.leadingAnchor),
            m.mine ? col.leadingAnchor.constraint(greaterThanOrEqualTo: r.leadingAnchor, constant: 40)
                   : col.trailingAnchor.constraint(lessThanOrEqualTo: r.trailingAnchor, constant: -40),
        ])
        return r
    }

    /// Susun ulang daftar pesan; `stickBottom` = gulir ke pesan terbaru
    private func render(stickBottom: Bool) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if hasMore { list.addArrangedSubview(olderButton) }
        if messages.isEmpty, !loading {
            list.addArrangedSubview(Form.note("Belum ada pesan. Sapa \(app.account.friendName(friendID)) duluan, yuk.", width: 320))
        }
        for m in messages {
            let r = row(m)
            list.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        guard stickBottom else { return }
        doc.layoutSubtreeIfNeeded()
        let y = max(0, doc.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Tambah pesan tanpa dobel (pesan sendiri datang dua kali: balasan kirim + kabar real-time)
    private func merge(_ new: [ChatMessage]) -> Bool {
        let known = Set(messages.map(\.id))
        let add = new.filter { !known.contains($0.id) }
        guard !add.isEmpty else { return false }
        messages = (messages + add).sorted { $0.id < $1.id }
        return true
    }

    // MARK: data

    private func reload() {
        guard !loading else { return }
        loading = true
        app.account.loadMessages(friendID) { [weak self] msgs, more, err in
            guard let self else { return }
            self.loading = false
            if let err {
                self.status.stringValue = err
                return
            }
            self.status.stringValue = ""
            if self.messages.isEmpty { self.hasMore = more }
            let changed = self.merge(msgs ?? [])
            self.refreshHeader()
            if changed || self.messages.isEmpty { self.render(stickBottom: true) }
        }
    }

    @objc private func loadOlder() {
        guard !loading, let first = messages.first else { return }
        loading = true
        olderButton.isEnabled = false
        app.account.loadMessages(friendID, before: first.id) { [weak self] msgs, more, err in
            guard let self else { return }
            self.loading = false
            self.olderButton.isEnabled = true
            if let err { self.status.stringValue = err; return }
            self.hasMore = more
            _ = self.merge(msgs ?? [])
            self.render(stickBottom: false)
        }
    }

    /// Pesan masuk dari saluran real-time
    func receive(_ m: ChatMessage) {
        guard merge([m]) else { return }
        render(stickBottom: true)
        if !m.mine, isViewing { app.account.markRead(friendID) }
    }

    @objc private func send() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        sendButton.isEnabled = false
        status.stringValue = "Mengirim…"
        app.account.sendMessage(friendID, text) { [weak self] m, err in
            guard let self else { return }
            self.sending = false
            self.sendButton.isEnabled = true
            guard let m else {
                self.status.stringValue = err ?? "Pesan gagal terkirim. Coba lagi."
                return // teks tetap di kolom supaya bisa dikirim ulang
            }
            self.status.stringValue = ""
            if self.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.field.stringValue = "" }
            if self.merge([m]) { self.render(stickBottom: true) }
            self.window.makeFirstResponder(self.field)
        }
    }

    /// Saluran real-time putus (mis. nginx belum mendukung WebSocket) → segarkan sendiri tiap 15 detik selama jendela terbuka
    private func startRefresh() {
        guard refreshTimer == nil else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, !self.app.account.liveConnected, self.window.isVisible else { return }
            self.reload()
            if self.isViewing { self.app.account.markRead(self.friendID) }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ n: Notification) {
        if app.account.unread[friendID] != nil { app.account.markRead(friendID) }
    }

    func windowWillClose(_ n: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        onClose?()
    }
}
