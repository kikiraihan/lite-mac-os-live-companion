// Temu — lampiran di obrolan: gambar & file (server/internal/app/attachments.go).
//   📎 di kolom tulis → panel Buka macOS (hanya file yang dipilih sendiri dibaca) → pratinjau (SendPreview.swift):
//                  gambar bisa dipotong / diputar, tombol "1" = sekali lihat; sama dengan lampiran yang ditempel (⌘V)
//   biasa        : tersimpan di server paling lama sehari, lalu terhapus otomatis. Gambar tampil di obrolan
//                  (klik = jendela besar), file disimpan lewat panel Simpan. Isi tidak pernah dibuka otomatis.
//   sekali lihat : seperti WhatsApp — hanya penerima, hanya sekali; isinya terhapus dari server begitu dibuka.
//                  Foto tampil di jendela yang tidak ikut tertangkap tangkapan / rekaman layar dan tidak disimpan
//                  ke disk; file langsung ditulis ke tempat yang dipilih di panel Simpan.

import AppKit
import SwiftUI

extension ChatAttachment {
    /// Judul kartu di obrolan
    var title: String {
        switch (once, isImage) {
        case (true, true): return "Foto sekali lihat"
        case (true, false): return "File sekali unduh"
        case (false, true): return "Foto"
        default: return name
        }
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }

    /// "pukul 14.05" / "besok pukul 09.30"
    var untilText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateFormat = "HH.mm"
        return (Calendar.current.isDateInToday(expires) ? "" : "besok ") + "pukul " + f.string(from: expires)
    }

    /// Keterangan di bawah judul; `mine` = aku pengirimnya
    func detail(mine: Bool) -> String {
        if once {
            if opened == true { return "Sudah dibuka, sudah dihapus dari server" }
            if !live { return mine ? "Tidak dibuka sampai sehari, sudah dihapus" : "Sudah lewat sehari, sudah dihapus" }
            return mine ? "Belum dibuka · hilang setelah dibuka" : (isImage ? "Klik untuk melihat · hanya sekali" : "\(name) · \(sizeText)")
        }
        if !live { return "Sudah lewat sehari, sudah dihapus dari server" }
        return "\(sizeText) · ada sampai \(untilText)"
    }

    var symbol: String {
        if once { return opened == true ? "checkmark.circle" : (live ? "1.circle" : "clock") }
        if !live { return "clock" }
        return isImage ? "photo" : "doc"
    }
}

/// Satu lampiran di obrolan: gambar kecil (kalau sudah diunduh) atau kartu ikon + nama + keterangan
struct AttachmentBubble: View {
    let message: ChatMessage
    let attachment: ChatAttachment
    let image: NSImage?
    let busy: Bool
    let open: () -> Void
    let save: () -> Void

    /// Bisa diklik: lampiran biasa yang masih ada, atau sekali lihat milik teman yang belum dibuka
    private var clickable: Bool { attachment.live && !(attachment.once && message.mine) }

    var body: some View {
        Button {
            if clickable && !busy { open() }
        } label: {
            if let image, attachment.isImage, !attachment.once, attachment.live {
                thumbnail(image)
            } else {
                card
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if attachment.live && !attachment.once {
                if attachment.isImage { Button("Lihat") { open() } }
                Button("Simpan…") { save() }
            }
        }
    }

    private func thumbnail(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 220, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if message.mine, let status = message.status {
                    ReceiptTicks(status: status)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Brand.strawberry))
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
    }

    private var card: some View {
        let mine = message.mine
        let fg: Color = mine ? Brand.ink : Color.primary
        return HStack(spacing: 9) {
            ZStack {
                Circle().fill(mine ? Brand.ink.opacity(0.12) : Color.primary.opacity(0.08))
                if busy {
                    ProgressView().controlSize(.small)
                } else if attachment.symbol == "1.circle" {
                    OnceIcon(size: 18) // sama dengan tombol "1" di pratinjau (SendPreview.swift)
                } else {
                    Image(systemName: attachment.symbol)
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.detail(mine: mine))
                    .font(.system(size: 11))
                    .opacity(0.7)
                    .lineLimit(2)
            }
            if mine, let status = message.status { ReceiptTicks(status: status) }
        }
        .foregroundStyle(fg)
        .opacity(attachment.live || attachment.opened == true ? 1 : 0.6)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(mine ? Brand.strawberry : Color.primary.opacity(0.08))
        )
        .contentShape(Rectangle())
    }
}

/// Jendela foto ukuran besar. Sekali lihat: tidak bisa disalin, tidak ikut tangkapan / rekaman layar,
/// dan fotonya hanya ada di memori sampai jendela ditutup.
enum ImageViewer {
    private static var windows: [NSWindow] = []

    static func show(_ image: NSImage, title: String, once: Bool) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var size = image.size
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        let scale = min(1, screen.width * 0.8 / max(size.width, 1), screen.height * 0.8 / max(size.height, 1))
        let content = NSSize(width: max(240, size.width * scale), height: max(180, size.height * scale))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        let v = NSImageView()
        v.image = image
        v.imageScaling = .scaleProportionallyUpOrDown
        v.isEditable = false
        v.allowsCutCopyPaste = !once
        w.contentView = v
        if once { w.sharingType = .none } // jendela ini tidak ikut tertangkap tangkapan / rekaman layar
        w.center()
        windows.append(w)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            windows.removeAll { $0 === w }
            v.image = nil
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
