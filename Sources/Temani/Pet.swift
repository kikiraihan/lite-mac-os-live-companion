// Temani — panggung: jendela transparan selebar layar tempat pet hidup.
// Semua yang terjadi di sini hanya mainan: menggambar sprite, membaca posisi kursor
// (NSEvent.mouseLocation, tanpa izin apa pun), dan menanggapi klik pada pet itu sendiri.
// Tidak ada akses ke layar, ketikan, berkas, atau aplikasi lain.

import Cocoa

// MARK: - Pengaturan (UserDefaults)

enum Prefs {
    static var showDesktop: Bool { defaults.bool(forKey: "showDesktop") }
    /// Ukuran satu piksel art dalam titik (2 kecil, 3 sedang, 4 besar)
    static var scale: CGFloat { CGFloat(min(5, max(2, defaults.integer(forKey: "petScale")))) }
    /// 0 kalem, 1 biasa, 2 lincah
    static var liveliness: Int { min(2, max(0, defaults.integer(forKey: "liveliness"))) }
    /// 0 di atas semua jendela, 1 hanya di desktop (di belakang jendela)
    static var level: Int { defaults.integer(forKey: "stageLevel") }
    static var bubbles: Bool { defaults.bool(forKey: "bubbles") }
    static var surprises: Bool { defaults.bool(forKey: "surprises") }
    static var followCursor: Bool { defaults.bool(forKey: "followCursor") }
    static var sleepAtNight: Bool { defaults.bool(forKey: "sleepAtNight") }
    static var reminders: Bool { defaults.bool(forKey: "reminders") }
    static var reminderMinutes: Int { max(10, defaults.integer(forKey: "reminderMinutes")) }
    static var species: Species { Species.find(defaults.string(forKey: "species") ?? "oren") }
    static var petName: String {
        let n = (defaults.string(forKey: "petName") ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? species.defaultName : n
    }

    static func register() {
        defaults.register(defaults: [
            "showDesktop": true, "petScale": 3, "liveliness": 1, "stageLevel": 0, "bubbles": true, "surprises": true,
            "followCursor": true, "sleepAtNight": true, "reminders": false, "reminderMinutes": 45, "species": "oren",
        ])
    }
}

let inkColor = NSColor(srgbRed: 0.165, green: 0.129, blue: 0.251, alpha: 1) // #2a2140, warna garis pixel

// MARK: - Aktor

enum Act {
    case idle, walk, run, sit, sleep, jump, dance, wave, love, surprise, dizzy, sneeze, trip, held, fall, seek, chase, eat, away
}

enum Quarry {
    case cursor
    case prop(Prop)
}

final class Bubble {
    let layer = CALayer()
    let text = CATextLayer()
    var until: Double = 0
    var size = CGSize.zero
}

final class Pet {
    let id: String
    var name: String
    var ownerName: String
    var mine: Bool
    var skin: Skin
    let layer = CALayer()

    var x: CGFloat = 0
    var y: CGFloat = 0      // tinggi di atas lantai
    var vy: CGFloat = 0
    var facing: CGFloat = 1
    var act = Act.idle
    var t: Double = 0
    var dur: Double = 1
    var targetX: CGFloat = 0
    var arrive: (() -> Void)?
    var quarry = Quarry.cursor
    var kicks = 0
    var offstage = false    // boleh berjalan keluar layar (pergi mencari hadiah)
    var blinkEvery = Double.random(in: 2.5...5.5)
    var bubble: Bubble?
    var frame = Frame.idle

    init(_ e: RosterEntry) {
        id = e.id; name = e.name; ownerName = e.ownerName; mine = e.mine; skin = e.skin
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.contentsGravity = .resize
    }

    func start(_ a: Act, _ d: Double) {
        act = a
        t = 0
        dur = d
        arrive = nil
    }

    var busy: Bool {
        switch act {
        case .idle, .walk, .sit, .wave, .dance: return false
        default: return true
        }
    }
}

enum PropRole { case food, ball, butterfly, gift, effect }

final class Prop {
    let role: PropRole
    var kind: PropKind
    let layer = CALayer()
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat = 0
    var vy: CGFloat = 0
    var age: Double = 0
    var ttl: Double
    var baseY: CGFloat = 0
    weak var carrier: Pet?
    var landed = false
    var dead = false

    init(_ role: PropRole, _ kind: PropKind, x: CGFloat, y: CGFloat, ttl: Double) {
        self.role = role; self.kind = kind; self.x = x; self.y = y; self.ttl = ttl
        layer.magnificationFilter = .nearest
        layer.contentsGravity = .resize
        layer.contents = Sprites.prop(kind)
    }
}

// MARK: - Jendela

final class StagePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class StageView: NSView {
    weak var stage: Stage?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { stage?.mouseDown(convert(e.locationInWindow, from: nil), clicks: e.clickCount) }
    override func mouseDragged(with e: NSEvent) { stage?.mouseDragged(convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { stage?.mouseUp(convert(e.locationInWindow, from: nil)) }
    override func rightMouseDown(with e: NSEvent) { stage?.onContextMenu?(e, self) }
}

// MARK: - Panggung

final class Stage: NSObject {
    let window: StagePanel
    let view = StageView()
    private(set) var pets: [Pet] = []
    private var props: [Prop] = []
    private var timer: Timer?
    private var last = CACurrentMediaTime()
    private var clock: Double = 0
    private var nextReminder: Double = 0
    private var screen: NSScreen?
    private var press: (pet: Pet?, prop: Prop?, at: CGPoint, moved: Bool)?
    private var pendingNudges: [(String, String)] = []
    private var asleep = false

    /// Klik kanan pada pet → menu aplikasi
    var onContextMenu: ((NSEvent, NSView) -> Void)?
    /// Dipanggil tiap frame supaya ikon menu bar ikut bergerak
    var onFrame: (() -> Void)?

    private var s: CGFloat { Prefs.scale }
    private var cell: CGFloat { CGFloat(cellPixels) * s }
    private var width: CGFloat { window.frame.width }
    private var height: CGFloat { window.frame.height }
    private var floorY: CGFloat {
        guard let sc = screen else { return 0 }
        return sc.visibleFrame.minY - sc.frame.minY
    }

    override init() {
        window = StagePanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        view.stage = self
        view.wantsLayer = true
        window.contentView = view
        screen = NSScreen.main ?? NSScreen.screens.first

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.fit() }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
            self?.restartTimer()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false
            self?.restartTimer()
            self?.greet()
        }
        nextReminder = Double(Prefs.reminderMinutes) * 60
        applyPrefs()
    }

    // MARK: pengaturan & tata letak

    /// Pasang jendela selebar layar tempat pet berada
    private func fit() {
        if let sc = screen, !NSScreen.screens.contains(sc) { screen = nil }
        if screen == nil { screen = NSScreen.main ?? NSScreen.screens.first }
        guard let sc = screen else { return }
        window.setFrame(sc.frame, display: false)
        for p in pets where !p.offstage { p.x = min(max(p.x, cell / 2), width - cell / 2) }
    }

    /// Dipanggil saat pengaturan berubah
    func applyPrefs() {
        window.level = Prefs.level == 1
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
        fit()
        if Prefs.showDesktop {
            window.orderFrontRegardless()
            flushNudges()
        } else {
            window.orderOut(nil)
        }
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard !asleep else { return }
        // tersembunyi: otak pet tetap jalan pelan untuk ikon menu bar
        let fps: Double = Prefs.showDesktop ? 30 : 8
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.25 / fps
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: daftar pet

    func setRoster(_ entries: [RosterEntry]) {
        var keep: [Pet] = []
        for e in entries {
            if let p = pets.first(where: { $0.id == e.id }) {
                p.name = e.name; p.ownerName = e.ownerName; p.mine = e.mine; p.skin = e.skin
                keep.append(p)
            } else {
                let p = Pet(e)
                // pet baru jatuh dari atas layar
                p.x = CGFloat.random(in: cell...max(cell + 1, width - cell))
                p.y = max(200, height - floorY)
                p.start(.fall, 99)
                view.layer?.addSublayer(p.layer)
                keep.append(p)
            }
        }
        for p in pets where !keep.contains(where: { $0 === p }) {
            p.layer.removeFromSuperlayer()
            p.bubble?.layer.removeFromSuperlayer()
        }
        pets = keep
    }

    /// Pet yang tampil di menu bar: pet sendiri dulu, kalau tidak ada pet pertama
    var barPet: Pet? { pets.first(where: { $0.mine }) ?? pets.first }

    func describe(_ p: Pet) -> String {
        switch p.act {
        case .sleep: return "\(p.name) sedang tidur"
        case .eat: return "\(p.name) sedang makan"
        case .dance: return "\(p.name) lagi joget"
        case .away: return "\(p.name) pergi sebentar…"
        case .chase:
            if case .prop(let q) = p.quarry { return q.role == .ball ? "\(p.name) main bola" : "\(p.name) mengejar kupu-kupu" }
            return "\(p.name) mengejar kursor"
        case .dizzy: return "\(p.name) pusing"
        case .sit: return "\(p.name) rebahan"
        case .held: return "\(p.name) sedang diangkat"
        default: return "\(p.name) jalan-jalan"
        }
    }

    // MARK: aksi dari menu

    /// Pindah ke layar tempat kursor berada, lalu semua pet jatuh di dekat kursor
    func summon() {
        let m = NSEvent.mouseLocation
        screen = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? screen
        fit()
        let local = m.x - window.frame.minX
        for (i, p) in pets.enumerated() {
            p.offstage = false
            p.x = min(max(local + CGFloat(i) * cell * 0.8 - CGFloat(pets.count - 1) * cell * 0.4, cell / 2), width - cell / 2)
            p.y = max(160, height - floorY)
            p.vy = 0
            p.start(.fall, 99)
        }
    }

    func feed() {
        guard let p = pets.filter({ $0.act != .held && $0.act != .away }).randomElement() else { return }
        let x = min(max(p.x + CGFloat.random(in: -160...160), cell), width - cell)
        let food = Prop(.food, .fish, x: x, y: height - floorY, ttl: 40)
        add(food)
        if p.act == .sleep { say(p, Lines.wake.randomElement()) }
        p.quarry = .prop(food)
        p.start(.chase, 30)
    }

    func play() {
        guard let p = pets.filter({ $0.act != .held && $0.act != .away }).randomElement() else { return }
        startBall(p)
    }

    func deliverNudge(from: String, text: String) {
        pendingNudges.append((from, text))
        if Prefs.showDesktop { flushNudges() }
    }

    private func flushNudges() {
        guard !pets.isEmpty else { return }
        for (from, text) in pendingNudges {
            guard let p = pets.first(where: { !$0.mine && $0.ownerName == from }) ?? barPet else { continue }
            let msg = text.isEmpty ? "\(from) menyapamu!" : "\(from): \(text)"
            if p.y == 0 { p.vy = 520; p.start(.jump, 2) }
            say(p, msg, seconds: 8, force: true)
            burst(.heart, at: p, count: 3)
        }
        pendingNudges.removeAll()
    }

    private func greet() {
        guard let p = barPet, Prefs.bubbles else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        if p.act == .sleep { p.start(.surprise, 1) }
        say(p, Lines.greeting(hour: hour).randomElement())
    }

    // MARK: balon kata & partikel

    func say(_ p: Pet, _ text: String?, seconds: Double = 3, force: Bool = false) {
        guard let text, force || Prefs.bubbles else { return }
        let b = p.bubble ?? Bubble()
        if p.bubble == nil {
            b.layer.backgroundColor = NSColor.white.cgColor
            b.layer.borderColor = inkColor.cgColor
            b.layer.borderWidth = 2
            b.text.foregroundColor = inkColor.cgColor
            b.text.isWrapped = true
            b.text.alignmentMode = .center
            b.text.contentsScale = window.backingScaleFactor
            b.layer.addSublayer(b.text)
            view.layer?.addSublayer(b.layer)
            p.bubble = b
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let box = (text as NSString).boundingRect(with: NSSize(width: 240, height: 400), options: [.usesLineFragmentOrigin],
                                                  attributes: [.font: font], context: nil)
        b.size = CGSize(width: ceil(box.width) + 18, height: ceil(box.height) + 12)
        b.text.font = font
        b.text.fontSize = 12
        b.text.string = text
        b.text.frame = CGRect(x: 8, y: 5, width: ceil(box.width) + 2, height: ceil(box.height) + 2)
        b.until = clock + seconds
    }

    private func add(_ prop: Prop) {
        props.append(prop)
        view.layer?.addSublayer(prop.layer)
    }

    private func particle(_ kind: PropKind, x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat, ttl: Double = 1.4) {
        guard props.count < 60 else { return }
        let p = Prop(.effect, kind, x: x, y: y, ttl: ttl)
        p.vx = vx
        p.vy = vy
        add(p)
    }

    private func burst(_ kind: PropKind, at p: Pet, count: Int) {
        for _ in 0..<count {
            particle(kind, x: p.x + CGFloat.random(in: -8...8) * s, y: p.y + 18 * s,
                     vx: CGFloat.random(in: -30...30), vy: CGFloat.random(in: 40...80))
        }
    }

    // MARK: memilih kegiatan berikutnya

    private func isNight() -> Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return Prefs.sleepAtNight && (h >= 22 || h < 6)
    }

    private func choose(_ p: Pet) {
        p.offstage = false
        let live = Prefs.liveliness
        let rest = [2.2, 1.0, 0.45][live]      // pengali lama diam
        let spice = [0.4, 1.0, 1.8][live]      // pengali kejutan
        if isNight(), Double.random(in: 0...1) < 0.7 {
            p.start(.sleep, Double.random(in: 60...240))
            return
        }
        var options: [(Double, () -> Void)] = [
            (26, { p.start(.idle, Double.random(in: 2...6) * rest) }),
            (30, { p.facing = Bool.random() ? 1 : -1; p.start(.walk, Double.random(in: 2...7)) }),
            (9, { p.start(.sit, Double.random(in: 5...14) * rest) }),
            (5, { p.start(.sleep, Double.random(in: 15...50) * rest) }),
            (5, { p.vy = 480; p.start(.jump, 2) }),
            (4, { p.start(.dance, Double.random(in: 2.5...5)) }),
            (3, { p.start(.wave, 1.8); self.say(p, Lines.hello.randomElement(), seconds: 1.8) }),
        ]
        if Prefs.followCursor, mouseOnStage() != nil {
            options.append((5, { p.quarry = .cursor; p.start(.chase, Double.random(in: 4...8)) }))
        }
        if Prefs.surprises {
            options.append((2.5 * spice, { p.start(.sneeze, 1.4) }))
            options.append((2 * spice, { p.facing = Bool.random() ? 1 : -1; p.start(.run, Double.random(in: 2.5...4.5)) }))
            options.append((1.5 * spice, { p.facing = Bool.random() ? 1 : -1; p.start(.trip, 2.6) }))
            options.append((1.6 * spice, { self.startButterfly(p) }))
            options.append((1.2 * spice, { self.startBall(p) }))
            options.append((1.2 * spice, { self.startGift(p) }))
        }
        let total = options.reduce(0) { $0 + $1.0 }
        var r = Double.random(in: 0..<total)
        for (w, run) in options {
            if r < w { run(); break }
            r -= w
        }
        if p.act == .idle, Double.random(in: 0...1) < 0.10 * spice {
            let hour = Calendar.current.component(.hour, from: Date())
            say(p, (Bool.random() ? Lines.idle : Lines.greeting(hour: hour)).randomElement())
        }
    }

    private func startButterfly(_ p: Pet) {
        guard !props.contains(where: { $0.role == .butterfly }) else { return p.start(.idle, 1) }
        let fromLeft = Bool.random()
        let b = Prop(.butterfly, .butterflyA, x: fromLeft ? -20 : width + 20, y: cell * 1.3, ttl: 60)
        b.baseY = cell * CGFloat.random(in: 1.1...1.8)
        b.vx = (fromLeft ? 1 : -1) * CGFloat.random(in: 45...75)
        add(b)
        p.quarry = .prop(b)
        p.start(.chase, 40)
        say(p, Lines.butterfly.randomElement(), seconds: 2)
    }

    private func startBall(_ p: Pet) {
        let ball: Prop
        if let old = props.first(where: { $0.role == .ball }) {
            ball = old
            ball.ttl = ball.age + 40
        } else {
            ball = Prop(.ball, .ball, x: min(max(p.x + CGFloat.random(in: -200...200), cell), width - cell), y: height * 0.4, ttl: 40)
            add(ball)
        }
        if p.act == .sleep { say(p, Lines.wake.randomElement()) }
        p.kicks = 0
        p.quarry = .prop(ball)
        p.start(.chase, 25)
        say(p, Lines.ball.randomElement(), seconds: 1.6)
    }

    /// Pergi keluar layar, lalu pulang membawa hadiah kecil
    private func startGift(_ p: Pet) {
        p.offstage = true
        p.start(.seek, 30)
        p.targetX = p.x < width / 2 ? -cell : width + cell
        p.arrive = { [weak self, weak p] in
            guard let self, let p else { return }
            p.start(.away, Double.random(in: 3...7))
            p.arrive = { [weak self, weak p] in
                guard let self, let p else { return }
                let kind = [PropKind.flower, .star, .gift, .heart].randomElement() ?? .flower
                let gift = Prop(.gift, kind, x: p.x, y: 0, ttl: 400)
                gift.carrier = p
                self.add(gift)
                p.start(.seek, 30)
                p.targetX = CGFloat.random(in: self.cell...max(self.cell + 1, self.width - self.cell))
                p.arrive = { [weak self, weak p, weak gift] in
                    guard let self, let p else { return }
                    p.offstage = false
                    if let gift {
                        gift.carrier = nil
                        gift.x = p.x + p.facing * 14 * self.s
                        gift.y = 0
                        gift.ttl = gift.age + 180
                    }
                    self.say(p, Lines.gift.randomElement())
                    p.start(.love, 1.8)
                }
            }
        }
    }

    // MARK: simulasi

    private func mouseOnStage() -> CGPoint? {
        let m = NSEvent.mouseLocation
        guard window.frame.contains(m) else { return nil }
        return CGPoint(x: m.x - window.frame.minX, y: m.y - window.frame.minY)
    }

    private func move(_ p: Pet, _ speed: CGFloat, _ dt: Double) {
        p.x += p.facing * speed * s * CGFloat(dt)
        guard !p.offstage else { return }
        if p.x < cell / 2 { p.x = cell / 2; p.facing = 1 }
        if p.x > width - cell / 2 { p.x = width - cell / 2; p.facing = -1 }
    }

    private func every(_ interval: Double, _ p: Pet, _ dt: Double) -> Bool {
        Int(p.t / interval) != Int((p.t - dt) / interval)
    }

    private func step(_ p: Pet, _ dt: Double) {
        p.t += dt
        let done = p.t >= p.dur
        switch p.act {
        case .idle, .sit, .wave, .love, .surprise:
            if done { choose(p) }
        case .walk:
            move(p, 14, dt)
            if done { choose(p) }
        case .run:
            move(p, 46, dt)
            if every(0.25, p, dt) { particle(.puff, x: p.x - p.facing * 8 * s, y: 2, vx: -p.facing * 20, vy: 14, ttl: 0.6) }
            if done { p.start(.idle, 1.2); say(p, Lines.tired.randomElement(), seconds: 1.6) }
        case .sleep:
            if every(1.5, p, dt) { particle(.z, x: p.x + p.facing * 6 * s, y: 14 * s, vx: p.facing * 8, vy: 22, ttl: 2) }
            if done { p.start(.surprise, 0.8); say(p, Lines.wake.randomElement()) }
        case .jump, .fall:
            p.vy -= 2000 * CGFloat(dt)
            p.y += p.vy * CGFloat(dt)
            if p.y <= 0 {
                let hard = p.act == .fall && p.vy < -1050
                p.y = 0
                p.vy = 0
                if hard {
                    p.start(.dizzy, 2.2)
                    say(p, Lines.drop.randomElement(), seconds: 2)
                    burst(.star, at: p, count: 3)
                } else {
                    p.start(.idle, Double.random(in: 0.5...1.5))
                }
            }
        case .dance:
            p.y = abs(sin(CGFloat(p.t) * 7)) * 3 * s
            if every(0.5, p, dt) {
                p.facing *= -1
                particle(.note, x: p.x + CGFloat.random(in: -10...10) * s, y: 20 * s, vx: CGFloat.random(in: -16...16), vy: 40)
            }
            if done { p.y = 0; choose(p) }
        case .dizzy:
            if done { p.start(.idle, 1) }
        case .sneeze:
            if p.t > 0.7, p.t - dt <= 0.7 {
                say(p, Lines.sneeze.randomElement(), seconds: 1.2)
                particle(.puff, x: p.x + p.facing * 10 * s, y: 10 * s, vx: p.facing * 60, vy: 6, ttl: 0.7)
                p.vy = 180
            }
            if p.t > 0.7 {
                p.vy -= 2000 * CGFloat(dt)
                p.y = max(0, p.y + p.vy * CGFloat(dt))
            }
            if done { p.y = 0; choose(p) }
        case .trip:
            if p.t < 1 { move(p, 40, dt) }
            if p.t >= 1, p.t - dt < 1 {
                say(p, Lines.trip.randomElement(), seconds: 1.4)
                particle(.puff, x: p.x, y: 2, vx: 0, vy: 16, ttl: 0.6)
            }
            if done { choose(p) }
        case .held:
            break
        case .seek:
            let dx = p.targetX - p.x
            if abs(dx) < 6 || done {
                let cb = p.arrive
                p.arrive = nil
                if let cb { cb() } else { choose(p) }
            } else {
                p.facing = dx > 0 ? 1 : -1
                move(p, 30, dt)
            }
        case .away:
            if done {
                let cb = p.arrive
                p.arrive = nil
                if let cb { cb() } else { choose(p) }
            }
        case .eat:
            if done {
                burst(.heart, at: p, count: 2)
                say(p, Lines.eat.randomElement(), seconds: 1.8)
                p.start(.love, 1.2)
            }
        case .chase:
            chase(p, dt, done: done)
        }
    }

    private func chase(_ p: Pet, _ dt: Double, done: Bool) {
        // lompatan kecil saat mengejar tetap pakai gravitasi
        if p.y > 0 || p.vy > 0 {
            p.vy -= 2000 * CGFloat(dt)
            p.y = max(0, p.y + p.vy * CGFloat(dt))
            if p.y == 0 { p.vy = 0 }
        }
        switch p.quarry {
        case .cursor:
            guard let m = mouseOnStage(), !done else { return choose(p) }
            let dx = m.x - p.x
            if abs(dx) < 14 * s {
                if m.y - floorY < cell * 1.5 {
                    burst(.heart, at: p, count: 1)
                    p.start(.wave, 1.6)
                } else {
                    p.start(.idle, 1.5) // kursor terlalu tinggi: menunggu sambil menengadah
                }
            } else {
                p.facing = dx > 0 ? 1 : -1
                move(p, 28, dt)
            }
        case .prop(let q):
            if q.dead || done {
                if q.role == .butterfly { say(p, Lines.lost.randomElement(), seconds: 1.8) }
                return p.start(.idle, 1.2)
            }
            let dx = q.x - p.x
            switch q.role {
            case .butterfly:
                if abs(dx) > 10 * s {
                    p.facing = dx > 0 ? 1 : -1
                    move(p, 26, dt)
                } else if p.y == 0, Double.random(in: 0...1) < dt * 1.5 {
                    p.vy = 520 // melompat mencoba menangkap
                }
            case .ball:
                if abs(dx) > 8 * s {
                    p.facing = dx > 0 ? 1 : -1
                    move(p, 40, dt)
                } else if q.y < 12 * s {
                    q.vx = p.facing * CGFloat.random(in: 240...420)
                    q.vy = CGFloat.random(in: 180...340)
                    q.landed = false
                    p.kicks += 1
                    if p.y == 0 { p.vy = 260 }
                    if p.kicks >= 4 {
                        say(p, Lines.tired.randomElement(), seconds: 1.8)
                        q.ttl = q.age + 12
                        p.start(.sit, 4)
                    }
                }
            case .food:
                if abs(dx) > 8 * s {
                    p.facing = dx > 0 ? 1 : -1
                    move(p, 40, dt)
                } else if q.landed {
                    q.dead = true
                    p.start(.eat, 2.4)
                }
            default:
                p.start(.idle, 1)
            }
        }
    }

    private func frame(_ p: Pet) -> Frame {
        let alt = { (interval: Double) in Int(p.t / interval) % 2 == 0 }
        switch p.act {
        case .idle: return p.t.truncatingRemainder(dividingBy: p.blinkEvery) > p.blinkEvery - 0.15 ? Frame.blink : Frame.idle
        case .walk, .seek: return alt(0.18) ? Frame.walk1 : Frame.walk2
        case .run: return alt(0.09) ? Frame.walk1 : Frame.walk2
        case .sit: return .sit
        case .sleep, .away: return .sleep
        case .jump: return .jump
        case .dance: return alt(0.25) ? Frame.dance1 : Frame.dance2
        case .wave: return alt(0.3) ? Frame.wave : Frame.happy
        case .love: return .love
        case .surprise, .held, .fall: return .surprise
        case .dizzy: return .dizzy
        case .sneeze: return p.t < 0.7 ? Frame.blink : Frame.surprise
        case .trip:
            if p.t < 1 { return alt(0.09) ? Frame.walk1 : Frame.walk2 }
            return p.t < 2 ? Frame.dizzy : Frame.sad
        case .eat: return alt(0.2) ? Frame.eat : Frame.happy
        case .chase:
            if p.y > 0 { return .jump }
            return alt(0.12) ? Frame.walk1 : Frame.walk2
        }
    }

    private func stepProp(_ q: Prop, _ dt: Double) {
        q.age += dt
        if q.age >= q.ttl { q.dead = true }
        switch q.role {
        case .effect:
            q.x += q.vx * CGFloat(dt)
            q.y += q.vy * CGFloat(dt)
        case .butterfly:
            q.x += q.vx * CGFloat(dt)
            q.y = q.baseY + sin(CGFloat(q.age) * 3) * 12 * s
            q.kind = Int(q.age / 0.14) % 2 == 0 ? .butterflyA : .butterflyB
            q.layer.contents = Sprites.prop(q.kind)
            if q.x < -40 || q.x > width + 40 { q.dead = true }
        case .food, .ball:
            q.vy -= 1600 * CGFloat(dt)
            q.x += q.vx * CGFloat(dt)
            q.y += q.vy * CGFloat(dt)
            if q.y <= 0 {
                q.y = 0
                if q.role == .ball, abs(q.vy) > 120 { q.vy = -q.vy * 0.5 } else { q.vy = 0; q.landed = true }
                q.vx *= CGFloat(pow(0.12, dt)) // gesekan lantai
            }
            if q.x < 10 { q.x = 10; q.vx = abs(q.vx) * 0.7 }
            if q.x > width - 10 { q.x = width - 10; q.vx = -abs(q.vx) * 0.7 }
        case .gift:
            if let c = q.carrier { // dibawa di atas kepala
                q.x = c.x
                q.y = c.y + 22 * s
            }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - last)
        last = now
        clock += dt
        guard !pets.isEmpty else {
            onFrame?()
            return
        }

        for p in pets { step(p, dt) }
        for q in props { stepProp(q, dt) }
        for q in props where q.dead { q.layer.removeFromSuperlayer() }
        props.removeAll { $0.dead }

        if Prefs.reminders, clock >= nextReminder, let p = barPet {
            nextReminder = clock + Double(Prefs.reminderMinutes) * 60
            if p.act == .sleep { p.start(.surprise, 1) }
            if p.y == 0, !p.busy { p.vy = 420; p.start(.jump, 2) }
            say(p, Lines.care.randomElement(), seconds: 7, force: true)
        }

        if Prefs.showDesktop { layout() }
        onFrame?()
    }

    private func layout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let f = floorY
        for p in pets {
            let fr = frame(p)
            p.frame = fr
            p.layer.contents = p.skin.image(fr)
            p.layer.bounds = CGRect(x: 0, y: 0, width: cell, height: cell)
            p.layer.position = CGPoint(x: round(p.x), y: round(f + p.y + cell / 2))
            p.layer.setAffineTransform(CGAffineTransform(scaleX: p.facing < 0 ? -1 : 1, y: 1))
            p.layer.isHidden = p.act == .away
            if let b = p.bubble {
                if clock >= b.until || p.act == .away {
                    b.layer.removeFromSuperlayer()
                    p.bubble = nil
                } else {
                    let bx = min(max(p.x - b.size.width / 2, 6), width - b.size.width - 6)
                    let by = min(f + p.y + 25 * s, height - b.size.height - 6)
                    b.layer.frame = CGRect(x: round(bx), y: round(by), width: b.size.width, height: b.size.height)
                }
            }
        }
        for q in props {
            let size = Sprites.size(of: q.kind)
            let k = q.role == .effect ? max(1, s - 1) : s
            let w = CGFloat(size.w) * k, h = CGFloat(size.h) * k
            q.layer.frame = CGRect(x: round(q.x - w / 2), y: round(f + q.y), width: w, height: h)
            if q.role == .effect { q.layer.opacity = Float(min(1, (q.ttl - q.age) * 2)) }
        }
        CATransaction.commit()

        // klik hanya ditangkap kalau kursor tepat di atas pet / benda; selain itu tembus ke aplikasi di bawahnya
        let over = press != nil || (mouseOnStage().map { hit($0) != nil } ?? false)
        if window.ignoresMouseEvents == over { window.ignoresMouseEvents = !over }
    }

    // MARK: mouse

    private func hit(_ pt: CGPoint) -> (Pet?, Prop?)? {
        let f = floorY
        for p in pets.reversed() where p.act != .away {
            if abs(pt.x - p.x) < 12 * s, pt.y > f + p.y, pt.y < f + p.y + 22 * s { return (p, nil) }
        }
        for q in props where q.role == .gift || q.role == .ball {
            if q.carrier == nil, abs(pt.x - q.x) < 8 * s, pt.y > f + q.y - 2, pt.y < f + q.y + 12 * s { return (nil, q) }
        }
        return nil
    }

    func mouseDown(_ pt: CGPoint, clicks: Int) {
        guard let h = hit(pt) else { return }
        press = (h.0, h.1, pt, false)
        if clicks == 2, let p = h.0 { // klik dua kali: lompat + lelucon
            if p.y == 0 { p.vy = 560 }
            p.start(.jump, 2)
            say(p, Lines.jokes.randomElement(), seconds: 5)
            press = nil
        }
    }

    func mouseDragged(_ pt: CGPoint) {
        guard var pr = press, let p = pr.pet else { return }
        if !pr.moved, hypot(pt.x - pr.at.x, pt.y - pr.at.y) > 5 {
            pr.moved = true
            press = pr
            p.offstage = false
            p.start(.held, 999)
            say(p, Lines.held.randomElement(), seconds: 1.6)
        }
        if pr.moved {
            p.x = min(max(pt.x, cell / 2), width - cell / 2)
            p.y = max(0, pt.y - floorY - 10 * s)
            p.vy = 0
        }
    }

    func mouseUp(_ pt: CGPoint) {
        defer { press = nil }
        guard let pr = press else { return }
        if let p = pr.pet {
            if pr.moved {
                p.start(.fall, 99)
            } else if p.act == .sleep {
                p.start(.surprise, 1)
                say(p, Lines.wake.randomElement())
            } else { // dielus
                p.start(.love, 1.5)
                say(p, Lines.pet.randomElement(), seconds: 1.6)
                burst(.heart, at: p, count: 3)
            }
        } else if let q = pr.prop {
            if q.role == .gift {
                q.dead = true
                defaults.set(defaults.integer(forKey: "giftsFound") + 1, forKey: "giftsFound")
                for _ in 0..<5 {
                    particle(.sparkle, x: q.x + CGFloat.random(in: -10...10), y: q.y + 6, vx: CGFloat.random(in: -50...50),
                             vy: CGFloat.random(in: 30...90), ttl: 0.9)
                }
                if let p = pets.min(by: { abs($0.x - q.x) < abs($1.x - q.x) }) { say(p, Lines.thanks.randomElement(), seconds: 2) }
            } else if q.role == .ball { // disentil
                q.vx = (q.x >= pt.x ? 1 : -1) * CGFloat.random(in: 220...380)
                q.vy = CGFloat.random(in: 240...380)
                q.landed = false
                q.ttl = q.age + 30
            }
        }
    }
}
