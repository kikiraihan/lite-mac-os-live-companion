// Temu — pratinjau sebelum mengirim lampiran yang ditempel (⌘V / ⌃V di kolom tulis obrolan, Popover.swift),
// juga gambar yang dipilih lewat tombol 📎.
//   satu gambar  : tampil besar; bisa dipotong (seret untuk membuat kotak, seret pojoknya untuk mengubah ukuran,
//                  seret isinya untuk menggeser) dan diputar 90°. Tanpa diubah → file aslinya yang terkirim.
//   file lain    : daftar nama file yang akan dikirim.
//   tombol "1"   : sekali lihat, seperti WhatsApp — transparan = mati, putih = menyala.
// Gambar hanya ada di memori selama jendela ini terbuka; tidak ada yang ditulis ke disk.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum SendPreview {
    struct Result {
        let items: [PopoverModel.Upload]
        let once: Bool
    }

    /// Jendela modal; nil = batal. `once` = tombol "1" sudah menyala (📎 › Sekali lihat…).
    /// `demo` hanya untuk tangkapan layar CI (--demo-preview-crop): mulai dalam mode potong dengan sekali lihat menyala.
    static func run(_ items: [PopoverModel.Upload], to name: String, once: Bool = false, demo: Bool = false) -> Result? {
        let image = items.count == 1 ? loadImage(items[0]) : nil
        let state = PreviewState(items: items, image: image, cropping: demo && image != nil)
        state.once = once || demo
        var size = NSSize(width: 460, height: 360)
        if let image {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let scale = min(1, 720 / max(w, 1), 520 / max(h, 1))
            size = NSSize(width: max(460, w * scale + 32), height: max(320, h * scale + 32) + PreviewView.barHeight)
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Kirim ke \(name)"
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua) // latar gelap seperti penampil foto, supaya gambarnya menonjol
        w.contentMinSize = NSSize(width: 420, height: 300)
        w.contentView = NSHostingView(rootView: PreviewView(state: state, friend: name) { result in
            state.result = result
            NSApp.stopModal()
        })
        w.center()
        let closer = Closer()
        w.delegate = closer
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: w)
        w.orderOut(nil)
        w.contentView = nil
        _ = closer
        return state.result
    }

    /// Tombol tutup jendela = batal
    private final class Closer: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            if NSApp.modalWindow === notification.object as? NSWindow { NSApp.stopModal() }
        }
    }

    /// File gambar yang bisa dipratinjau (📎 → gambar lewat pratinjau, file lain langsung terkirim)
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Satu gambar (dari clipboard atau file gambar yang disalin di Finder), sudah diputar sesuai EXIF
    private static func loadImage(_ item: PopoverModel.Upload) -> CGImage? {
        let src: CGImageSource?
        switch item {
        case .data(let data, _): src = CGImageSourceCreateWithData(data as CFData, nil)
        case .file(let url):
            guard let t = UTType(filenameExtension: url.pathExtension), t.conforms(to: .image) else { return nil }
            src = CGImageSourceCreateWithURL(url as CFURL, nil)
        }
        guard let src, let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Isi jendela pratinjau
final class PreviewState: ObservableObject {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    let items: [PopoverModel.Upload]
    let original: CGImage?
    /// Gambar setelah diputar
    @Published var image: CGImage?
    /// Kotak potongan, 0…1 terhadap `image`, titik asal kiri atas
    @Published var crop = PreviewState.full
    @Published var cropping: Bool
    @Published var once = false
    private(set) var turns = 0
    var result: SendPreview.Result?

    init(items: [PopoverModel.Upload], image: CGImage?, cropping: Bool) {
        self.items = items
        original = image
        self.image = image
        self.cropping = cropping
        if cropping { crop = CGRect(x: 0.12, y: 0.1, width: 0.7, height: 0.75) }
    }

    var edited: Bool { turns % 4 != 0 || crop != PreviewState.full }

    /// Putar 90° berlawanan arah jarum jam; kotak potongan ikut berputar
    func rotateLeft() {
        guard let img = image else { return }
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: img.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: CGFloat(h), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return }
        image = out
        turns += 1
        let c = crop
        crop = CGRect(x: c.minY, y: 1 - c.maxX, width: c.height, height: c.width)
    }

    func reset() {
        image = original
        turns = 0
        crop = PreviewState.full
        cropping = false
    }

    /// Kotak potongan dalam piksel `image`
    func pixelCrop(_ img: CGImage) -> CGRect {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        return CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Gambar yang tampil saat tidak sedang memotong (= yang akan terkirim)
    var shown: CGImage? {
        guard let img = image else { return nil }
        if crop == PreviewState.full { return img }
        return img.cropping(to: pixelCrop(img)) ?? img
    }

    /// Yang dikirim: file asli kalau tidak diubah, kalau diubah hasil potongan (JPEG untuk foto, selain itu PNG)
    func output() -> [PopoverModel.Upload] {
        guard edited, let img = shown, let item = items.first else { return items }
        let base = (item.name as NSString).deletingPathExtension
        let ext = (item.name as NSString).pathExtension.lowercased()
        let photo = ["jpg", "jpeg", "heic", "heif"].contains(ext)
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = photo ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                               : rep.representation(using: .png, properties: [:]) else { return items }
        return [.data(data, name: base + (photo ? ".jpg" : ".png"))]
    }
}

struct PreviewView: View {
    static let barHeight: CGFloat = 58

    @ObservedObject var state: PreviewState
    let friend: String
    let finish: (SendPreview.Result?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.92)
                if let img = state.image {
                    if state.cropping {
                        CropCanvas(image: img, crop: $state.crop).padding(16)
                    } else if let shown = state.shown {
                        Image(decorative: shown, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .padding(16)
                    }
                } else {
                    fileList
                }
            }
            bar
        }
        .frame(minWidth: 420, minHeight: 300)
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(state.items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isFile ? "doc" : "photo")
                            .font(.system(size: 18))
                            .frame(width: 28)
                        Text(item.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .foregroundStyle(.white)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            if state.image != nil {
                if state.cropping {
                    Button("Selesai") { state.cropping = false }
                        .help("Pakai potongan ini")
                } else {
                    iconButton("crop", help: "Potong gambar") {
                        state.cropping = true
                    }
                }
                iconButton("rotate.left", help: "Putar 90° ke kiri") { state.rotateLeft() }
                if state.edited {
                    iconButton("arrow.uturn.backward", help: "Kembalikan ke gambar asli") { state.reset() }
                }
            }
            Spacer(minLength: 8)
            Text(state.once ? "Sekali lihat: hilang setelah dibuka \(friend)" : "Tersimpan di server sehari")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.tail)
            OnceToggle(on: $state.once)
            Button("Batal") { finish(nil) }
                .keyboardShortcut(.cancelAction)
            Button {
                state.cropping = false
                finish(SendPreview.Result(items: state.output(), once: state.once))
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Brand.strawberry))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .help(state.once ? "Kirim sekali lihat (Return)" : "Kirim (Return)")
            .accessibilityLabel(state.once ? "Kirim sekali lihat" : "Kirim")
        }
        .padding(.horizontal, 14)
        .frame(height: PreviewView.barHeight)
        .background(Color.black)
    }

    private func iconButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Tombol "1" sekali lihat, seperti WhatsApp: transparan = mati, putih = menyala
struct OnceToggle: View {
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            ZStack {
                Circle().fill(on ? Color.white : Color.white.opacity(0.08))
                Circle().strokeBorder(Color.white.opacity(on ? 0 : 0.55), lineWidth: 1.5)
                Text("1")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? Brand.ink : Color.white.opacity(0.75))
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
        .help(on ? "Sekali lihat menyala: hanya bisa dibuka sekali, lalu terhapus dari server. Klik untuk mematikan."
                 : "Sekali lihat: klik supaya hanya bisa dibuka sekali")
        .accessibilityLabel("Sekali lihat")
        .accessibilityValue(on ? "Menyala" : "Mati")
    }
}

/// Gambar penuh + kotak potongan. Seret di luar kotak = kotak baru, seret pojok = ubah ukuran, seret isi = geser.
struct CropCanvas: View {
    let image: CGImage
    @Binding var crop: CGRect

    private enum Mode { case new(CGPoint), move(CGRect), corner(Int, CGRect) }
    @State private var mode: Mode?

    private static let minSide: CGFloat = 0.04

    var body: some View {
        GeometryReader { geo in
            let fit = fitRect(geo.size)
            let r = CGRect(x: fit.minX + crop.minX * fit.width, y: fit.minY + crop.minY * fit.height,
                           width: crop.width * fit.width, height: crop.height * fit.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                Path { p in
                    p.addRect(fit)
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { p in // garis sepertiga
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                Path { $0.addRect(r) }.stroke(Color.white, lineWidth: 1.5)
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .position(corners(r)[i])
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(fit, r))
        }
        .help("Seret untuk memotong · seret pojok untuk mengubah ukuran · seret isinya untuk menggeser")
    }

    private func fitRect(_ size: CGSize) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let s = min(size.width / max(w, 1), size.height / max(h, 1))
        let fw = w * s, fh = h * s
        return CGRect(x: (size.width - fw) / 2, y: (size.height - fh) / 2, width: fw, height: fh)
    }

    /// kiri atas, kanan atas, kanan bawah, kiri bawah
    private func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    private func drag(_ fit: CGRect, _ r: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                guard fit.width > 0, fit.height > 0 else { return }
                let norm = { (p: CGPoint) in
                    CGPoint(x: min(max((p.x - fit.minX) / fit.width, 0), 1), y: min(max((p.y - fit.minY) / fit.height, 0), 1))
                }
                if mode == nil {
                    let s = v.startLocation
                    if let i = corners(r).firstIndex(where: { hypot($0.x - s.x, $0.y - s.y) <= 14 }) {
                        mode = .corner(i, crop)
                    } else if r.contains(s), crop != PreviewState.full {
                        mode = .move(crop)
                    } else {
                        mode = .new(norm(s))
                    }
                }
                let p = norm(v.location)
                switch mode {
                case .new(let a):
                    let n = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
                    if n.width >= Self.minSide, n.height >= Self.minSide { crop = n }
                case .move(let c):
                    let dx = v.translation.width / fit.width, dy = v.translation.height / fit.height
                    crop = CGRect(x: min(max(c.minX + dx, 0), 1 - c.width), y: min(max(c.minY + dy, 0), 1 - c.height),
                                  width: c.width, height: c.height)
                case .corner(let i, let c):
                    // pojok di seberangnya tetap di tempat
                    let fixed = CGPoint(x: i == 0 || i == 3 ? c.maxX : c.minX, y: i < 2 ? c.maxY : c.minY)
                    let n = CGRect(x: min(fixed.x, p.x), y: min(fixed.y, p.y), width: abs(p.x - fixed.x), height: abs(p.y - fixed.y))
                    if n.width >= Self.minSide, n.height >= Self.minSide { crop = n }
                case nil: break
                }
            }
            .onEnded { _ in mode = nil }
    }
}

extension PopoverModel.Upload {
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}
