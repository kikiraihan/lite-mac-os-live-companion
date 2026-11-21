// Temu — emot lewat pet. Dikirim dari baki emot di obrolan (Popover.swift, tombol ✨), sampai di Mac teman sebagai
// pesan berisi emojinya (server: messages.go, `reactions`), lalu animasinya diputar tepat di atas pet pengirim:
// emoji muncul memantul di atas kepala pet, bergoyang, naik, dan memudar — seperti reaksi di rapat video.
// Pet pengirim tidak tampil di Mac itu → animasi di atas pet sendiri dengan label "dari Dina".
//
// Emojinya sendiri ikut bergerak (hati berdetak, jempol memompa, tangan bertepuk): animasi Microsoft Fluent Emoji
// (lisensi MIT, Resources/Reactions, dibuat oleh scripts/fluent-reactions.py) diputar bingkai demi bingkai.
// Emoji tanpa animasi Fluent (✨, ❗) memakai emoji sistem yang diam.
//
// Semuanya Core Animation (animasi berjalan di render server, halus di 60/120 Hz walau otak pet hanya 30 fps).
// Lapisan satu emot dikelompokkan dalam satu CALayer yang ikut posisi x pet (Stage.layout) dan dibuang setelah selesai.
// "Kurangi gerakan" (Aksesibilitas macOS) dihormati: hanya emoji yang muncul dan memudar, tanpa konfeti / kembang api.
// Hanya menggambar di panggung milik Temu sendiri; tidak membaca apa pun dari layar.

import AppKit
import ImageIO
import QuartzCore

/// Emot lewat pet (urutan = urutan di baki). Nama sama dengan `reactions` di server/internal/app/messages.go.
enum Reaction: String, CaseIterable, Identifiable {
    case clap, like, love, haha, wow, party, fireworks

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .love: return "❤️"
        case .like: return "👍"
        case .haha: return "😂"
        case .clap: return "👏"
        case .wow: return "😮"
        case .party: return "🎉"
        case .fireworks: return "🥳"
        }
    }

    var title: String {
        switch self {
        case .love: return "Sayang"
        case .like: return "Mantap"
        case .haha: return "Ngakak"
        case .clap: return "Tepuk tangan"
        case .wow: return "Wah!"
        case .party: return "Perayaan"
        case .fireworks: return "Hore!"
        }
    }

    /// nil = bukan emot (pesan biasa) atau emot baru yang belum dikenal aplikasi versi ini
    static func find(_ raw: String?) -> Reaction? { raw.flatMap(Reaction.init(rawValue:)) }
}

/// Warna dari docs/DESIGN.md (sama dengan `Brand` di Popover.swift)
private enum Palette {
    static let strawberry = CGColor(srgbRed: 1.0, green: 0.353, blue: 0.478, alpha: 1)
    static let lemon = CGColor(srgbRed: 1.0, green: 0.824, blue: 0.235, alpha: 1)
    static let leaf = CGColor(srgbRed: 0.184, green: 0.620, blue: 0.467, alpha: 1)
    static let orange = CGColor(srgbRed: 0.969, green: 0.647, blue: 0.322, alpha: 1)
    static let blue = CGColor(srgbRed: 0.067, green: 0.341, blue: 0.788, alpha: 1)
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let confetti = [strawberry, lemon, leaf, orange, blue, white]
}

/// Gambar emot: animasi Fluent Emoji kalau ada, kalau tidak emoji sistem (Apple Color Emoji) yang diam
enum ReactionArt {
    private static var cache: [String: CGImage] = [:]
    private static let side: CGFloat = 80

    /// Emoji yang punya animasi Fluent Emoji: berkas di Resources/Reactions & jumlah bingkainya
    /// (sama dengan hasil scripts/fluent-reactions.py; lembar 8 kolom, tiap bingkai 128×128, 24 fps)
    private static let animated: [String: (file: String, frames: Int)] = [
        "👏": ("clap", 28), "👍": ("like", 51), "❤️": ("love", 73), "💖": ("love2", 40), "😂": ("haha", 48),
        "😮": ("wow", 73), "🎉": ("party", 61), "🥳": ("yay", 73),
    ]
    static let fps: Double = 24
    private static var sheets: [String: [CGImage]] = [:]

    /// Bingkai animasi emoji ini; nil = tidak punya animasi (atau berkasnya tidak ada) → pakai emoji(_:)
    static func frames(_ e: String) -> [CGImage]? {
        guard let a = animated[e] else { return nil }
        if let f = sheets[a.file] { return f }
        guard let url = Bundle.main.url(forResource: a.file, withExtension: "png", subdirectory: "Reactions"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // lembar berpalet → RGBA sekali saja, supaya Core Animation tidak mengonversi tiap bingkai
        ctx.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
        guard let sheet = ctx.makeImage() else { return nil }
        let side = 128, cols = 8
        let out = (0..<a.frames).compactMap { i in
            sheet.cropping(to: CGRect(x: (i % cols) * side, y: (i / cols) * side, width: side, height: side))
        }
        guard out.count == a.frames else { return nil }
        sheets[a.file] = out
        return out
    }

    static func emoji(_ e: String) -> CGImage? {
        if let c = cache[e] { return c }
        let px = Int(side * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        let font = NSFont(name: "Apple Color Emoji", size: side * 0.78) ?? NSFont.systemFont(ofSize: side * 0.78)
        let s = NSAttributedString(string: e, attributes: [.font: font])
        let b = s.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(at: NSPoint(x: (side - b.width) / 2, y: (side - b.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        let img = ctx.makeImage()
        cache[e] = img
        return img
    }
}

/// Satu pertunjukan emot. Titik (0, 0) lapisan = tepat di atas kepala pet; y ke atas.
final class ReactionShow {
    let layer = CALayer()
    weak var pet: Pet?
    /// Lama pertunjukan (detik), diketahui setelah start()
    private(set) var length: Double = 0
    /// Label nama (mis. "dari Dina") di bawah emot → isi emot digeser naik sebanyak ini
    let lift: CGFloat

    private let reaction: Reaction
    private let label: String?
    private let scale: CGFloat
    private let calm: Bool
    private var t0: CFTimeInterval = 0

    private static let easeOut = CAMediaTimingFunction(name: .easeOut)
    private static let easeIn = CAMediaTimingFunction(name: .easeIn)
    private static let linear = CAMediaTimingFunction(name: .linear)

    /// `size` = ukuran relatif terhadap ukuran pet (Pengaturan › Ukuran); `calm` = Kurangi gerakan
    init(_ r: Reaction, label: String?, scale: CGFloat, size: CGFloat, calm: Bool) {
        reaction = r
        self.label = label
        self.scale = scale
        self.calm = calm
        lift = label == nil ? 0 : 16
        layer.bounds = .zero
        layer.masksToBounds = false
        layer.setAffineTransform(CGAffineTransform(scaleX: size, y: size))
    }

    /// Bangun lapisan & animasinya. Lapisan harus sudah ada di pohon lapisan (Stage.react).
    func start() {
        t0 = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.02
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let label { tag(label) }
        if calm {
            gentle()
        } else {
            switch reaction {
            case .love: love()
            case .like: like()
            case .haha: haha()
            case .clap: clap()
            case .wow: wow()
            case .party: party()
            case .fireworks: fireworks()
            }
        }
        CATransaction.commit()
    }

    /// Bekukan pertunjukan di detik `t` (hanya untuk tangkapan layar CI: --demo-reaction-at)
    func freeze(at t: Double) {
        layer.speed = 0
        layer.timeOffset = t0 + t
    }

    // MARK: koreografi

    /// Kurangi gerakan: emoji muncul pelan, naik sedikit, memudar
    private func gentle() {
        let c = CGPoint(x: 0, y: 44)
        let l = sprite(reaction.emoji, 52)
        l.position = c
        play(l, [kf("opacity", [0, 1, 1, 0], [0, 0.15, 0.8, 1]),
                 kf("position", [NSValue(point: c), NSValue(point: CGPoint(x: c.x, y: c.y + 14))])], delay: 0, dur: 2.2)
    }

    /// ❤️ hati besar berdetak + cahaya merah muda, lalu hati-hati kecil (berdetak & berkilau) beterbangan
    private func love() {
        let c = CGPoint(x: 0, y: 48)
        flash(at: c, color: Palette.strawberry, size: 130, peak: 0.5, delay: 0.05, dur: 1.1)
        for i in 0..<12 {
            floater(i % 2 == 0 ? "❤️" : "💖", size: .random(in: 20...34),
                    from: CGPoint(x: CGFloat.random(in: -22...22), y: CGFloat.random(in: 30...46)), rise: .random(in: 160...250),
                    sway: .random(in: 10...24), delay: 0.2 + Double(i) * 0.09 + .random(in: 0...0.06), dur: .random(in: 2.1...2.9))
        }
        hero("❤️", size: 66, at: c, dur: 3.0, hold: 0.5, rise: 120,
             scale: tl(3.0, [(0, 0.1), (0.2, 1.22), (0.34, 0.95), (0.46, 1.0)]))
    }

    /// 👍 jempol memompa dua kali, gelombang kuning + kilau memancar, dua jempol kecil menyusul
    private func like() {
        let c = CGPoint(x: 0, y: 46)
        ring(at: c, color: Palette.lemon, radius: 52, width: 3, delay: 0.12, dur: 0.6)
        radial("✨", at: c, count: 6, distance: 54, size: 15, delay: 0.14, dur: 0.8)
        for (i, d) in [0.55, 0.85, 1.15].enumerated() {
            floater("👍", size: .random(in: 24...30), from: CGPoint(x: i % 2 == 0 ? -16 : 16, y: 38), rise: .random(in: 170...210),
                    sway: 12, delay: d, dur: 2.2)
        }
        hero("👍", size: 66, at: c, dur: 2.9, hold: 0.52, rise: 110,
             scale: tl(2.9, [(0, 0), (0.2, 1.22), (0.33, 0.94), (0.45, 1.0)]),
             rot: tl(2.9, [(0, -0.45), (0.22, 0.12), (0.36, 0)]))
    }

    /// 😂 wajah tertawa terguncang-guncang, disusul tawa kecil yang melompat-lompat naik
    private func haha() {
        let c = CGPoint(x: 0, y: 46)
        for i in 0..<7 {
            floater("😂", size: .random(in: 22...34), from: CGPoint(x: CGFloat.random(in: -24...24), y: CGFloat.random(in: 34...44)),
                    rise: .random(in: 150...230), sway: .random(in: 8...16), delay: 0.25 + Double(i) * 0.13, dur: .random(in: 2.2...2.7),
                    wobble: 0.1, jiggle: 0.12)
        }
        let dur = 2.9
        hero("😂", size: 66, at: c, dur: dur, hold: 0.52, rise: 115,
             scale: tl(dur, [(0, 0), (0.2, 1.2), (0.32, 0.94), (0.44, 1.0)]),
             rot: (series(48) { t in
                 let s = t * dur
                 return s < 1.2 ? 0.12 * sin(2 * .pi * 5 * s) * (1 - s / 1.2) : 0
             }, nil))
    }

    /// 👏 tangan bertepuk (animasinya sendiri), gelombang & kilau kecil, lalu tepuk tangan kecil ikut naik
    private func clap() {
        let c = CGPoint(x: 0, y: 46)
        ring(at: c, color: Palette.lemon, radius: 44, width: 2.5, delay: 0.16, dur: 0.5)
        radial("✨", at: c, count: 5, distance: 50, size: 13, delay: 0.2, dur: 0.75)
        for i in 0..<5 {
            floater("👏", size: .random(in: 22...30), from: CGPoint(x: CGFloat.random(in: -22...22), y: 38), rise: .random(in: 150...220),
                    sway: 10, delay: 0.45 + Double(i) * 0.18, dur: 2.2)
        }
        let dur = 2.9
        hero("👏", size: 66, at: c, dur: dur, hold: 0.52, rise: 110,
             scale: tl(dur, [(0, 0), (0.18, 1.2), (0.3, 0.94), (0.42, 1.0)]))
    }

    /// 😮 kaget: wajah membesar mendadak dengan garis-garis kejut ala komik
    private func wow() {
        let c = CGPoint(x: 0, y: 48)
        burstLines(at: c, count: 12, inner: 34, outer: 60, color: Palette.lemon, delay: 0.1)
        for (i, x) in [-34.0, 34.0].enumerated() {
            floater("❗", size: 20, from: CGPoint(x: x, y: 62), rise: 60, sway: 4, delay: 0.16 + Double(i) * 0.08, dur: 1.2, wobble: 0.25)
        }
        for i in 0..<3 {
            floater("😮", size: .random(in: 22...28), from: CGPoint(x: CGFloat.random(in: -18...18), y: 40), rise: .random(in: 150...200),
                    sway: 10, delay: 0.7 + Double(i) * 0.2, dur: 2.0)
        }
        let dur = 2.6
        hero("😮", size: 68, at: c, dur: dur, hold: 0.55, rise: 110,
             scale: tl(dur, [(0, 0), (0.14, 1.45), (0.28, 0.9), (0.4, 1.06), (0.5, 1.0)]))
    }

    /// 🎉 terompet kertas meletus: dua semburan konfeti warna-warni yang melayang turun berkibar
    private func party() {
        let at = CGPoint(x: -16, y: 34)
        let dur = 2.4
        let popper = sprite("🎉", 62)
        popper.position = at
        let s = tl(dur, [(0, 0), (0.18, 1.1), (0.26, 1.0), (0.32, 1.0), (0.38, 1.28), (0.5, 0.95), (0.6, 1.0), (1.9, 1.0), (2.4, 0.6)])
        let r = tl(dur, [(0, 0), (0.32, 0), (0.38, -0.16), (0.5, 0.06), (0.6, 0)])
        play(popper, [kf("transform.scale", s.0, s.1), kf("transform.rotation.z", r.0, r.1),
                      kf("opacity", [0, 1, 1, 0], [0, 0.05, 0.78, 1])], delay: 0, dur: dur)
        let mouth = CGPoint(x: -2, y: 50)
        confetti(from: mouth, angle: 64, spread: 30, count: 44, delay: 0.38)
        confetti(from: mouth, angle: 100, spread: 46, count: 26, delay: 0.56)
        floater("🥳", size: 30, from: CGPoint(x: 18, y: 40), rise: 150, sway: 10, delay: 0.6, dur: 2.3)
    }

    /// 🥳 hore: wajah berpesta di atas pet, empat roket meluncur lalu pecah jadi kembang api berkilau
    private func fireworks() {
        hero("🥳", size: 64, at: CGPoint(x: 0, y: 46), dur: 3.0, hold: 0.6, rise: 90,
             scale: tl(3.0, [(0, 0), (0.2, 1.2), (0.32, 0.95), (0.44, 1.0)]))
        shell(to: CGPoint(x: -56, y: 190), color: Palette.strawberry, inner: Palette.lemon, delay: 0)
        shell(to: CGPoint(x: 52, y: 228), color: Palette.lemon, inner: Palette.white, delay: 0.42)
        shell(to: CGPoint(x: -6, y: 262), color: Palette.leaf, inner: Palette.lemon, delay: 0.84)
        shell(to: CGPoint(x: 30, y: 172), color: Palette.orange, inner: Palette.white, delay: 1.22)
    }

    // MARK: bahan

    /// Label kecil bergaya balon kata pet: "dari Dina" / "untuk Dina"
    private func tag(_ text: String) {
        let str = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                                 .foregroundColor: inkColor])
        let sz = str.size()
        let box = CALayer()
        box.bounds = CGRect(x: 0, y: 0, width: ceil(sz.width) + 16, height: ceil(sz.height) + 6)
        box.backgroundColor = Palette.white
        box.borderColor = inkColor.cgColor
        box.borderWidth = 2
        box.opacity = 0
        let t = CATextLayer()
        t.string = str
        t.contentsScale = scale
        t.alignmentMode = .center
        t.frame = CGRect(x: 8, y: 3, width: ceil(sz.width), height: ceil(sz.height))
        box.addSublayer(t)
        layer.addSublayer(box)
        let a = CGPoint(x: 0, y: -lift + 4), b = CGPoint(x: 0, y: -lift + 12), c = CGPoint(x: 0, y: -lift + 18)
        play(box, [kf("opacity", [0, 1, 1, 0], [0, 0.08, 0.85, 1]),
                   kf("position", [NSValue(point: a), NSValue(point: b), NSValue(point: b), NSValue(point: c)], [0, 0.1, 0.85, 1])],
             delay: 0, dur: 2.8)
    }

    /// Lapisan satu emoji. Emoji dengan animasi Fluent ikut bergerak terus selama terlihat; `phase` = mulai dari
    /// bingkai acak (emoji kecil yang banyak tidak bergerak serempak).
    private func sprite(_ e: String, _ size: CGFloat, shadow: Bool = true, phase: Bool = false) -> CALayer {
        let l = CALayer()
        if let frames = ReactionArt.frames(e) {
            l.contents = frames[0]
            let a = CAKeyframeAnimation(keyPath: "contents")
            a.values = frames
            a.calculationMode = .discrete
            a.duration = Double(frames.count) / ReactionArt.fps
            a.repeatCount = .infinity
            a.beginTime = t0
            if phase { a.timeOffset = .random(in: 0..<a.duration) }
            l.add(a, forKey: "frames")
        } else {
            l.contents = ReactionArt.emoji(e)
        }
        l.contentsGravity = .resizeAspect
        l.minificationFilter = .trilinear
        l.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        l.opacity = 0
        if shadow { // bayangan tipis supaya tetap terbaca di atas wallpaper apa pun
            l.shadowColor = CGColor(gray: 0, alpha: 1)
            l.shadowOpacity = 0.2
            l.shadowRadius = 3
            l.shadowOffset = CGSize(width: 0, height: -1)
        }
        layer.addSublayer(l)
        return l
    }

    /// Emoji utama: muncul memantul di atas kepala pet, bertahan sebentar (`hold` = bagian dari `dur`), lalu naik sambil memudar
    private func hero(_ e: String, size: CGFloat, at c: CGPoint, dur: Double, hold: Double, rise: CGFloat,
                      scale: ([Any], [Double]?), rot: ([Any], [Double]?)? = nil) {
        let l = sprite(e, size)
        l.position = c
        let end = CGPoint(x: c.x + CGFloat.random(in: -10...10), y: c.y + rise)
        var anims: [CAAnimation] = [
            kf("position", [NSValue(point: c), NSValue(point: c), NSValue(point: end)], [0, hold, 1],
               ease: [ReactionShow.linear, ReactionShow.easeIn]),
            kf("transform.scale", scale.0, scale.1),
            kf("opacity", [0, 1, 1, 0], [0, 0.05, max(0.7, hold + 0.12), 1]),
        ]
        if let rot { anims.append(kf("transform.rotation.z", rot.0, rot.1)) }
        play(l, anims, delay: 0, dur: dur)
    }

    /// Emoji kecil melayang naik sambil bergoyang ke kiri-kanan (miring mengikuti arahnya), lalu memudar.
    /// `jiggle` = guncangan cepat tambahan (untuk tawa).
    private func floater(_ e: String, size: CGFloat, from: CGPoint, rise: CGFloat, sway: CGFloat, delay: Double, dur: Double,
                         wobble: Double = 0.16, jiggle: Double = 0) {
        let l = sprite(e, size, shadow: false, phase: true)
        l.position = from
        let phase = Double.random(in: 0...(2 * .pi))
        let freq = Double.random(in: 0.7...1.1)
        let drift = CGFloat.random(in: -0.4...0.4) * sway
        let pos = samples(30) { t in
            let grow = CGFloat(min(1, t * 2.5)) // goyangan membesar setelah lepas dari kepala pet
            let x = from.x + drift * CGFloat(t) + sway * grow * CGFloat(sin(2 * .pi * freq * t * dur + phase))
            let y = from.y + rise * CGFloat(0.4 * t + 0.6 * (1 - pow(1 - t, 2)))
            return CGPoint(x: x, y: y)
        }
        let rot = series(30) { t in -wobble * cos(2 * .pi * freq * t * dur + phase) + jiggle * sin(2 * .pi * 7 * t * dur) }
        play(l, [kf("position", pos), kf("transform.rotation.z", rot),
                 kf("transform.scale", [0.2, 1.18, 0.95, 1.0, 0.82], [0, 0.1, 0.17, 0.26, 1]),
                 kf("opacity", [0, 1, 1, 0], [0, 0.08, 0.62, 1])], delay: delay, dur: dur)
    }

    /// Emoji kecil memancar keluar dari titik `c` ke segala arah lalu mengecil hilang (kilau)
    private func radial(_ e: String, at c: CGPoint, count: Int, distance: CGFloat, size: CGFloat, delay: Double, dur: Double) {
        let start = CGFloat.random(in: 0...(2 * .pi))
        for i in 0..<count {
            let a = start + CGFloat(i) / CGFloat(count) * 2 * .pi
            let d = distance * CGFloat.random(in: 0.85...1.1)
            let l = sprite(e, size, shadow: false)
            l.position = c
            let to = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
            play(l, [kf("position", [NSValue(point: c), NSValue(point: to)], ease: [ReactionShow.easeOut]),
                     kf("transform.scale", [0.2, 1.1, 0], [0, 0.35, 1]),
                     kf("transform.rotation.z", [0, Double.random(in: -1.4...1.4)]),
                     kf("opacity", [0, 1, 1, 0], [0, 0.15, 0.6, 1])], delay: delay, dur: dur)
        }
    }

    /// Gelombang lingkaran yang membesar lalu hilang
    private func ring(at c: CGPoint, color: CGColor, radius: CGFloat, width: CGFloat, delay: Double, dur: Double) {
        let l = CAShapeLayer()
        l.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius), transform: nil)
        l.fillColor = nil
        l.strokeColor = color
        l.lineWidth = width
        l.position = c
        l.opacity = 0
        layer.addSublayer(l)
        play(l, [kf("transform.scale", [0.2, 1.0], ease: [ReactionShow.easeOut]), kf("opacity", [0, 1, 0], [0, 0.12, 1]),
                 kf("lineWidth", [width, 0.5])], delay: delay, dur: dur)
    }

    /// Cahaya bulat lembut (pusat putih → warna → bening)
    private func flash(at c: CGPoint, color: CGColor, size: CGFloat, peak: Double, delay: Double, dur: Double) {
        let g = CAGradientLayer()
        g.type = .radial
        g.colors = [color.copy(alpha: 0.9) ?? color, color.copy(alpha: 0.45) ?? color, color.copy(alpha: 0) ?? color]
        g.locations = [0, 0.35, 1]
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        g.position = c
        g.opacity = 0
        layer.addSublayer(g)
        play(g, [kf("transform.scale", [0.2, 1.1], ease: [ReactionShow.easeOut]), kf("opacity", [0, peak, 0], [0, 0.2, 1])],
             delay: delay, dur: dur)
    }

    /// Garis-garis kejut yang melesat keluar dari wajah lalu habis (ujung belakang menyusul ujung depan)
    private func burstLines(at c: CGPoint, count: Int, inner: CGFloat, outer: CGFloat, color: CGColor, delay: Double) {
        for i in 0..<count {
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi + 0.2
            let long = i % 2 == 0
            let r = long ? outer : outer * 0.82
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cos(a) * inner, y: sin(a) * inner))
            path.addLine(to: CGPoint(x: cos(a) * r, y: sin(a) * r))
            let l = CAShapeLayer()
            l.path = path
            l.strokeColor = color
            l.fillColor = nil
            l.lineWidth = long ? 3.5 : 2.5
            l.lineCap = .round
            l.position = c
            l.strokeEnd = 0
            l.shadowColor = inkColor.cgColor // garis tipis gelap supaya kuningnya terlihat di wallpaper terang
            l.shadowOpacity = 0.35
            l.shadowRadius = 1
            l.shadowOffset = .zero
            layer.addSublayer(l)
            play(l, [kf("strokeEnd", [0, 1, 1], [0, 0.45, 1]), kf("strokeStart", [0, 0, 1], [0, 0.4, 1])], delay: delay, dur: 0.5)
        }
    }

    /// Konfeti: kertas warna-warni ditembakkan ke arah `angle` (derajat, 90 = lurus ke atas), melambat oleh udara,
    /// lalu turun pelan sambil berkibar (dibalik bolak-balik) dan berputar
    private func confetti(from o: CGPoint, angle: Double, spread: Double, count: Int, delay: Double) {
        for i in 0..<count {
            let kind = i % 3
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: kind == 0 ? 5 : kind == 1 ? 3 : 6, height: kind == 0 ? 9 : kind == 1 ? 12 : 6)
            l.cornerRadius = kind == 2 ? 3 : 1
            l.backgroundColor = Palette.confetti[i % Palette.confetti.count]
            l.position = o
            l.opacity = 0
            layer.addSublayer(l)

            let a = (angle + .random(in: -spread...spread)) * .pi / 180
            var vx = cos(a) * .random(in: 380...640)
            var vy = sin(a) * .random(in: 380...640)
            var x = Double(o.x), y = Double(o.y), fall = 0.0
            let dur = Double.random(in: 2.2...2.9)
            let n = 40
            let dt = dur / Double(n)
            let phase = Double.random(in: 0...(2 * .pi))
            let swayFreq = Double.random(in: 1.2...2.2)
            var pts: [Any] = []
            for _ in 0...n {
                // setelah mulai jatuh, kertas bergoyang ke kiri-kanan makin lebar
                let sway = 16 * min(1, fall / 0.6) * sin(2 * .pi * swayFreq * fall + phase)
                pts.append(NSValue(point: CGPoint(x: x + sway, y: y)))
                let drag = vy > 0 ? 1.6 : 4.6 // naik: hambatan kecil; turun: kertas melayang pelan
                vx += -vx * 1.6 * dt
                vy += (-420 - vy * drag) * dt
                x += vx * dt
                y += vy * dt
                if vy < 0 { fall += dt }
            }
            let flips = Double.random(in: 2.5...5.5)
            let flip = series(40) { t in cos(2 * .pi * flips * t * dur + phase) }
            let spin = Double.random(in: 3...9) * (Bool.random() ? 1 : -1)
            let r0 = Double.random(in: 0...(2 * .pi))
            play(l, [kf("position", pts), kf("transform.scale.y", flip), kf("transform.rotation.z", [r0, r0 + spin]),
                     kf("opacity", [0, 1, 1, 0], [0, 0.03, 0.72, 1])], delay: delay, dur: dur)
        }
    }

    /// Satu roket kembang api: titik terang berekor meluncur ke `target`, lalu kilatan + dua lingkar percikan
    private func shell(to target: CGPoint, color: CGColor, inner: CGColor, delay: Double) {
        let from = CGPoint(x: target.x * 0.25, y: 24)
        let up = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.35, 1)
        let flight = 0.62
        for k in 0..<6 { // k = 0 kepala roket, sisanya ekor yang makin kecil & pudar
            let d = dot(k == 0 ? 5 : 4 - CGFloat(k) * 0.45, color: k == 0 ? Palette.white : color, glow: k == 0 ? color : nil)
            d.position = from
            let peak = k == 0 ? 1 : 0.6 - Double(k) * 0.09
            play(d, [kf("position", [NSValue(point: from), NSValue(point: target)], ease: [up]),
                     kf("opacity", [0, peak, peak, 0], [0, 0.1, 0.85, 1])], delay: delay + Double(k) * 0.03, dur: flight)
        }
        let boom = delay + flight
        flash(at: target, color: color, size: 96, peak: 0.85, delay: boom, dur: 0.45)
        sparks(at: target, color: color, count: 24, radius: .random(in: 62...78), size: 4.5, delay: boom, dur: 1.5)
        sparks(at: target, color: inner, count: 12, radius: 34, size: 3.5, delay: boom + 0.04, dur: 1.15)
    }

    /// Percikan: melesat keluar melingkar, melambat, sedikit turun oleh gravitasi, berkelip, lalu padam
    private func sparks(at c: CGPoint, color: CGColor, count: Int, radius: CGFloat, size: CGFloat, delay: Double, dur: Double) {
        for i in 0..<count {
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi + .random(in: -0.12...0.12)
            let r = radius * .random(in: 0.85...1.1)
            let l = dot(size, color: color, glow: color)
            l.position = c
            let pos = samples(24) { t in
                let k = CGFloat(1 - pow(1 - t, 3))
                return CGPoint(x: c.x + cos(a) * r * k, y: c.y + sin(a) * r * k - 34 * CGFloat(t * t))
            }
            play(l, [kf("position", pos),
                     kf("opacity", [0, 1, 1, 0.9, 0.3, 0.9, 0.15, 0.6, 0], [0, 0.02, 0.4, 0.55, 0.62, 0.7, 0.78, 0.86, 1]),
                     kf("transform.scale", [1.3, 1, 0.4])], delay: delay, dur: dur * .random(in: 0.9...1.1))
        }
    }

    private func dot(_ d: CGFloat, color: CGColor, glow: CGColor?) -> CALayer {
        let l = CALayer()
        l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        l.cornerRadius = d / 2
        l.backgroundColor = color
        if let glow {
            l.shadowColor = glow
            l.shadowOpacity = 1
            l.shadowRadius = 3.5
            l.shadowOffset = .zero
            l.shadowPath = CGPath(ellipseIn: l.bounds, transform: nil)
        }
        l.opacity = 0
        layer.addSublayer(l)
        return l
    }

    // MARK: alat animasi

    private func kf(_ path: String, _ values: [Any], _ times: [Double]? = nil, ease: [CAMediaTimingFunction]? = nil) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: path)
        a.values = values
        if let times { a.keyTimes = times.map { NSNumber(value: $0) } }
        if let ease { a.timingFunctions = ease }
        return a
    }

    /// Jalankan animasi pada `l` mulai `delay` detik dari awal pertunjukan selama `dur` detik.
    /// Sebelum mulai, lapisan memakai nilai pertama (tak terlihat); setelah selesai tetap di nilai terakhir.
    private func play(_ l: CALayer, _ anims: [CAAnimation], delay: Double, dur: Double) {
        for a in anims { a.duration = dur }
        let g = CAAnimationGroup()
        g.animations = anims
        g.duration = dur
        g.beginTime = t0 + delay
        g.fillMode = .both
        g.isRemovedOnCompletion = false
        l.add(g, forKey: "temu.reaction")
        length = max(length, delay + dur)
    }

    /// Titik-titik `f(t)` untuk t = 0…1, berjarak waktu sama
    private func samples(_ n: Int, _ f: (Double) -> CGPoint) -> [Any] {
        (0...n).map { NSValue(point: f(Double($0) / Double(n))) }
    }

    private func series(_ n: Int, _ f: (Double) -> Double) -> [Any] {
        (0...n).map { NSNumber(value: f(Double($0) / Double(n))) }
    }

    /// Nilai pada detik tertentu → (nilai, keyTimes 0…1). Nilai terakhir ditahan sampai akhir `dur`.
    private func tl(_ dur: Double, _ pts: [(Double, Double)]) -> ([Any], [Double]?) {
        var p = pts
        if let last = p.last, last.0 < dur { p.append((dur, last.1)) }
        return (p.map { NSNumber(value: $0.1) }, p.map { min(1, max(0, $0.0 / dur)) })
    }
}
