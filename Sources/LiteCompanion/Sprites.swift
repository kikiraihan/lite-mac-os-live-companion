// LiteCompanion — pixel art pet & properti. Semua sprite ditulis sebagai teks (1 karakter = 1 piksel),
// jadi tidak ada file gambar dan installer satu-file tetap bisa membawa semuanya.
// Pratinjau tanpa Mac: python3 scripts/preview-sprites.py  → docs/sprites.png
//
// Catatan untuk pengubah gambar: skrip pratinjau membaca blok `static let nama = """ … """` di file ini,
// jadi pertahankan format itu (satu baris = satu baris piksel, tanpa spasi).

import Cocoa

// MARK: - Gambar (teks)

/// Karakter badan pet:
/// `.` transparan · `o` garis · `b` badan · `l` perut · `p` pipi / dalam telinga · `e` mata · `w` putih
/// `T` garis ekor · `t` isi ekor (dihapus untuk jenis tanpa ekor) · `r` merah (mata hati)
enum Art {
    /// Badan berdiri, menghadap kanan (ekor di kiri). Kaki ditempel dari `feet…` di bawahnya.
    static let body = """
    ....................
    ....................
    ....................
    ....................
    ......oooooooo......
    ....oobbbbbbbboo....
    ...obbbbbbbbbbbbo...
    ...obbbbbbbbbbbbo...
    ...obbbbbbbbbbbbo...
    ...obbbbbbbbbbbbo...
    .T.obbbbbbbbbbbbo...
    TtT.obbbbbbbbbbo....
    TttToblllllllbbo....
    .Tttobllllllllbo....
    ..TTobllllllllbo....
    ....obbbbbbbbbbo....
    """

    static let feetStand = """
    ....obbo....obbo....
    .....oo......oo.....
    """

    static let feetWalkA = """
    ...obbo......obbo...
    ....oo........oo....
    """

    static let feetWalkB = """
    .....obbo..obbo.....
    ......oo....oo......
    """

    /// Rebahan (tidur / duduk santai)
    static let loaf = """
    ....................
    ....................
    ....................
    ....................
    ....................
    ....................
    ....................
    ......oooooooo......
    ....oobbbbbbbboo....
    ...obbbbbbbbbbbbo...
    ...obbbbbbbbbbbbo...
    ...obbbbbbbbbbbbo...
    .T.obbbbbbbbbbbbo...
    TtTobbbbbbbbbbbbbo..
    TttTbbbbbbbbbbbbbbo.
    .TttTbbbbbbbbbbbbbo.
    ..TTtbbbbbbbbbbbbbo.
    ...ooooooooooooooo..
    """

    // Wajah: 3 baris × 14 kolom, ditempel mulai baris ke-4 dari puncak kepala, kolom 3
    static let faceNormal = """
    bbbbbbebbbbebb
    bbbbbbebbbbebb
    bbbbpbbboobpbb
    """
    static let faceBlink = """
    bbbbbbbbbbbbbb
    bbbbbeebbbeebb
    bbbbpbbboobpbb
    """
    static let faceHappy = """
    bbbbbbebbbbebb
    bbbbbebebbebeb
    bbbbpbbopobpbb
    """
    static let faceSurprise = """
    bbbbbeebbbeebb
    bbbbbeebbbeebb
    bbbbpbbbobbpbb
    """
    static let faceDizzy = """
    bbbbbebebbebeb
    bbbbbbebbbbebb
    bbbbbebebbebeb
    """
    static let faceSleep = """
    bbbbbbbbbbbbbb
    bbbbbeebbbeebb
    bbbbpbbbobbpbb
    """
    static let faceSad = """
    bbbbbebbbbbebb
    bbbbbbeebbbeeb
    bbbbbbbooobbbb
    """
    static let faceLove = """
    bbbbrbrbbrbrbb
    bbbbbrbbbbrbbb
    bbbbpbbopobpbb
    """
    static let faceMunch = """
    bbbbbbebbbbebb
    bbbbbbebbbbebb
    bbbbpbbbbbbpbb
    """

    // Telinga: baris terakhir menimpa baris puncak kepala
    static let earsCat = """
    .....o......o.......
    ....obo....obo......
    ....opbo..obpo......
    """
    static let earsBunny = """
    .....oo....oo.......
    ....obbo..obbo......
    ....obpo..obpo......
    ....obpo..obpo......
    ....obbo..obbo......
    """
    static let earsBear = """
    ....ooo....ooo......
    ...obbbo..obbbo.....
    ...obpbooooobpbo....
    """

    /// Jenis pet, satu baris: id|judul|nama default|telinga|ekor(1/0)|warna o b l p e (hex)
    static let species = """
    oren|Kucing Oren|Mochi|cat|1|462828 f7a552 ffeacd ff8c96 2d1a1e
    hitam|Kucing Hitam|Kopi|cat|1|120e16 3e3a4a 605a6e e67896 fad746
    kelinci|Kelinci|Bubu|bunny|0|5a4650 fcf8f4 ffffff ffaab9 3c283c
    beruang|Beruang|Gembul|bear|0|3c2418 aa6e46 e1b98c f08c82 23140f
    rubah|Rubah|Sore|cat|1|502418 eb6e32 fff5eb fff5eb 28180f
    """

    // MARK: properti (warna dari `propColors`)

    static let propHeart = """
    .rr.rr.
    rwrrrrr
    rrrrrrr
    .rrrrr.
    ..rrr..
    ...r...
    """
    static let propStar = """
    ...y...
    ..yyy..
    yyyyyyy
    .yyyyy.
    .yy.yy.
    .y...y.
    """
    static let propFlower = """
    .pp.pp.
    pppyppp
    .pyyyp.
    pppyppp
    .pp.pp.
    ...g...
    .g.g...
    ..gg.g.
    ...gg..
    ...g...
    """
    static let propButterflyA = """
    vv.k.vv
    vvvkvvv
    .vvkvv.
    vv.k.vv
    """
    static let propButterflyB = """
    ..vkv..
    ..vkv..
    ..vkv..
    ...k...
    """
    static let propBall = """
    .kkkk.
    krrwrk
    krrrrk
    kwwwwk
    kbbbbk
    .kkkk.
    """
    static let propFish = """
    ..cccc..c
    .cccccccc
    ckcccccc.
    .cccccccc
    ..cccc..c
    """
    static let propNote = """
    ..kk.
    ..k.k
    ..k..
    ..k..
    kkk..
    kkk..
    """
    static let propSparkle = """
    ..y..
    ..y..
    yywyy
    ..y..
    ..y..
    """
    static let propDrop = """
    .c.
    ccc
    cwc
    .c.
    """
    static let propZ = """
    BBBB
    ..B.
    .B..
    BBBB
    """
    static let propPuff = """
    .ss..
    swwss
    .swww
    ..ss.
    """
    static let propGift = """
    .r...r.
    ..r.r..
    yyyryyy
    yyyryyy
    rrrrrrr
    yyyryyy
    yyyryyy
    """
    static let propBang = """
    rr
    rr
    rr
    ..
    rr
    """

    /// Warna properti: karakter → hex
    static let propColors = """
    r e6465a
    y ffd23c
    w ffffff
    k 2d2830
    b 4678e6
    B 5a64b4
    c 6ec8f0
    g 50b464
    p ff96be
    v b478ff
    s c8c8d2
    """
}

// MARK: - Warna & jenis pet

struct RGB { let r: UInt8, g: UInt8, b: UInt8 }

func rgb(hex: Substring) -> RGB {
    let v = UInt32(hex, radix: 16) ?? 0
    return RGB(r: UInt8((v >> 16) & 0xff), g: UInt8((v >> 8) & 0xff), b: UInt8(v & 0xff))
}

extension RGB {
    var color: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
}

struct Species {
    let id: String
    let title: String
    let defaultName: String
    let ears: String
    let tail: Bool
    let colors: [Character: RGB]

    init?(line: Substring) {
        let f = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count == 6 else { return nil }
        let hex = f[5].split(separator: " ")
        guard hex.count == 5 else { return nil }
        id = f[0]; title = f[1]; defaultName = f[2]; ears = f[3]; tail = f[4] == "1"
        var c: [Character: RGB] = [:]
        for (k, h) in zip(["o", "b", "l", "p", "e"] as [Character], hex) { c[k] = rgb(hex: h) }
        c["w"] = RGB(r: 255, g: 255, b: 255)
        c["r"] = RGB(r: 230, g: 60, b: 80)
        c["T"] = c["o"]
        c["t"] = c["b"]
        colors = c
    }

    static let all: [Species] = Art.species.split(separator: "\n").compactMap { Species(line: $0) }
    static func find(_ id: String) -> Species { all.first { $0.id == id } ?? all[0] }
}

enum Pose: String { case stand, walkA, walkB, loaf }

enum Face: String, CaseIterable {
    case normal, blink, happy, surprise, dizzy, sleep, sad, love, munch

    var art: String {
        switch self {
        case .normal: return Art.faceNormal
        case .blink: return Art.faceBlink
        case .happy: return Art.faceHappy
        case .surprise: return Art.faceSurprise
        case .dizzy: return Art.faceDizzy
        case .sleep: return Art.faceSleep
        case .sad: return Art.faceSad
        case .love: return Art.faceLove
        case .munch: return Art.faceMunch
        }
    }
}

enum PropKind: String {
    case heart, star, flower, butterflyA, butterflyB, ball, fish, note, sparkle, drop, z, puff, gift, bang

    var art: String {
        switch self {
        case .heart: return Art.propHeart
        case .star: return Art.propStar
        case .flower: return Art.propFlower
        case .butterflyA: return Art.propButterflyA
        case .butterflyB: return Art.propButterflyB
        case .ball: return Art.propBall
        case .fish: return Art.propFish
        case .note: return Art.propNote
        case .sparkle: return Art.propSparkle
        case .drop: return Art.propDrop
        case .z: return Art.propZ
        case .puff: return Art.propPuff
        case .gift: return Art.propGift
        case .bang: return Art.propBang
        }
    }
}

// MARK: - Pembuat gambar

/// Ukuran kanvas pet dalam piksel
let petPixels = (w: 20, h: 18)

enum Sprites {
    private static var cache: [String: CGImage] = [:]
    private static let propPalette: [Character: RGB] = {
        var m: [Character: RGB] = [:]
        for line in Art.propColors.split(separator: "\n") {
            let p = line.split(separator: " ")
            if p.count == 2, let k = p[0].first { m[k] = rgb(hex: p[1]) }
        }
        return m
    }()

    static func grid(_ s: String) -> [[Character]] {
        let rows = s.split(separator: "\n").map { Array($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        let w = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: ".", count: w - $0.count) } // samakan lebar baris
    }

    /// Susun badan + kaki + telinga + wajah untuk satu jenis pet
    static func compose(_ pose: Pose, _ face: Face, _ sp: Species) -> [[Character]] {
        var g: [[Character]]
        switch pose {
        case .loaf: g = grid(Art.loaf)
        case .stand: g = grid(Art.body) + grid(Art.feetStand)
        case .walkA: g = grid(Art.body) + grid(Art.feetWalkA)
        case .walkB: g = grid(Art.body) + grid(Art.feetWalkB)
        }
        let top = g.firstIndex { $0.contains("o") } ?? 4
        let ears: String = sp.ears == "bunny" ? Art.earsBunny : sp.ears == "bear" ? Art.earsBear : Art.earsCat
        let e = grid(ears)
        for (i, row) in e.enumerated() {
            let y = top - e.count + 1 + i
            guard y >= 0, y < g.count else { continue }
            for (x, c) in row.enumerated() where c != "." && x < g[y].count {
                if c == "o" && g[y][x] == "b" { continue }
                g[y][x] = c
            }
        }
        for (i, row) in grid(face.art).enumerated() {
            let y = top + 4 + i
            guard y < g.count else { continue }
            for (x, c) in row.enumerated() where x + 3 < g[y].count {
                if g[y][x + 3] != "o" && g[y][x + 3] != "." { g[y][x + 3] = c }
            }
        }
        if !sp.tail { g = g.map { $0.map { $0 == "T" || $0 == "t" ? "." : $0 } } }
        return g
    }

    /// Grid → CGImage; `scale` = ukuran satu piksel art dalam piksel layar (tanpa interpolasi)
    static func image(_ g: [[Character]], _ colors: [Character: RGB], flip: Bool = false, scale: Int = 1) -> CGImage? {
        let gh = g.count, gw = g.first?.count ?? 0
        guard gw > 0, gh > 0 else { return nil }
        let s = max(1, scale)
        let w = gw * s, h = gh * s
        var data = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<gh {
            for x in 0..<g[y].count {
                guard g[y][x] != ".", let c = colors[g[y][x]] else { continue }
                let px = flip ? gw - 1 - x : x
                for dy in 0..<s {
                    for dx in 0..<s {
                        let i = ((y * s + dy) * w + px * s + dx) * 4
                        data[i] = c.r; data[i + 1] = c.g; data[i + 2] = c.b; data[i + 3] = 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func pet(_ pose: Pose, _ face: Face, _ sp: Species, flip: Bool, scale: Int = 1) -> CGImage? {
        let key = "pet|\(sp.id)|\(pose.rawValue)|\(face.rawValue)|\(flip)|\(scale)"
        if let c = cache[key] { return c }
        let img = image(compose(pose, face, sp), sp.colors, flip: flip, scale: scale)
        cache[key] = img
        return img
    }

    static func prop(_ kind: PropKind, flip: Bool = false, scale: Int = 1) -> CGImage? {
        let key = "prop|\(kind.rawValue)|\(flip)|\(scale)"
        if let c = cache[key] { return c }
        let img = image(grid(kind.art), propPalette, flip: flip, scale: scale)
        cache[key] = img
        return img
    }

    /// Ukuran properti dalam piksel art
    static func size(of kind: PropKind) -> (w: Int, h: Int) {
        let g = grid(kind.art)
        return (g.first?.count ?? 0, g.count)
    }

    /// Gambar pet untuk NSImage (menu bar, kartu, ikon aplikasi): `points` = ukuran satu piksel art dalam titik
    static func petImage(_ pose: Pose, _ face: Face, _ sp: Species, flip: Bool = false, points: CGFloat = 1) -> NSImage {
        let backing = Int(ceil(points * 2)) // cukup tajam untuk layar Retina
        let size = NSSize(width: CGFloat(petPixels.w) * points, height: CGFloat(petPixels.h) * points)
        guard let cg = pet(pose, face, sp, flip: flip, scale: backing) else { return NSImage(size: size) }
        return NSImage(cgImage: cg, size: size)
    }
}
