// Temu — menu utama tersembunyi.
// Aplikasi menu bar (.accessory) tidak menampilkan menu utama, tapi tanpa menu Edit pintasan standar
// (⌘C, ⌘V, ⌘X, ⌘A, ⌘Z) tidak sampai ke kolom tulis chat / kolom di Pengaturan. Menu ini hanya
// meneruskan pintasan lewat responder chain. Clipboard hanya dibaca saat pengguna sendiri menekan ⌘V / ⌃V
// (Tempel), untuk ditempel ke kolom yang aktif atau dikirim sebagai lampiran obrolan.
// macOS otomatis menambahkan "Emoji & Simbol" (⌃⌘Spasi) ke menu bernama Edit.

import Cocoa

enum MainMenu {
    static func install(target app: AppDelegate) {
        let main = NSMenu()

        // menu aplikasi: ⌘, pengaturan, ⌘Q keluar
        let appMenu = NSMenu(title: appDisplayName)
        let settings = NSMenuItem(title: "Pengaturan…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        settings.target = app
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Keluar dari \(appDisplayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        add(appMenu, to: main)

        // menu Edit: target nil → dikirim ke kolom yang sedang aktif (responder chain)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Urungkan", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Ulangi", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Potong", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Salin", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        // ⌘V lewat AppDelegate: di kolom tulis obrolan, gambar / file di clipboard jadi lampiran; selain itu tempel biasa
        let paste = NSMenuItem(title: "Tempel", action: #selector(AppDelegate.pasteInChat(_:)), keyEquivalent: "v")
        paste.target = app
        edit.addItem(paste)
        // ⌃V juga, untuk yang terbiasa dengan Windows
        let ctrlPaste = NSMenuItem(title: "Tempel", action: #selector(AppDelegate.pasteInChat(_:)), keyEquivalent: "v")
        ctrlPaste.keyEquivalentModifierMask = [.control]
        ctrlPaste.target = app
        ctrlPaste.isHidden = true
        ctrlPaste.allowsKeyEquivalentWhenHidden = true
        edit.addItem(ctrlPaste)
        let plain = NSMenuItem(title: "Tempel sebagai teks biasa", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(plain)
        edit.addItem(NSMenuItem(title: "Hapus", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        edit.addItem(NSMenuItem(title: "Pilih semua", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        add(edit, to: main)

        NSApp.mainMenu = main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
