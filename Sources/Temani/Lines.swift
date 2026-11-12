// Temani — celoteh pet (balon kata). Semua teks ada di sini supaya mudah ditambah.

import Foundation

enum Lines {
    static let idle = [
        "Hmm…", "Lagi ngapain?", "Aku di sini ya.", "Semangat!", "Boleh dielus?", "Layarmu luas juga.",
        "Aku jaga pojok sini.", "Tadi ada kursor lewat.", "Kerjaannya masih banyak?", "Pelan-pelan saja.",
        "Kamu hebat hari ini.", "Dock-nya enak buat duduk.", "Aku lagi mikirin ikan.", "Eh, itu apa?",
    ]
    static let morning = ["Selamat pagi!", "Pagi! Sudah sarapan?", "Hari baru, ayo mulai."]
    static let noon = ["Sudah makan siang?", "Siang-siang enaknya rebahan."]
    static let evening = ["Sore yang enak.", "Sebentar lagi selesai, kan?"]
    static let night = ["Sudah malam, lho.", "Jangan begadang terus.", "Aku ngantuk…"]
    static let care = [
        "Minum air dulu, yuk.", "Coba lihat jauh 20 detik.", "Bahunya dilemaskan dulu.", "Berdiri sebentar, regangkan badan.",
        "Tarik napas… buang pelan-pelan.", "Sudah lama duduk, jalan sebentar yuk.", "Kedipkan mata beberapa kali.",
    ]
    static let pet = ["Hehe!", "Lagi dong.", "Geli!", "Makasih ♥", "Enak…", "Aku suka kamu."]
    static let wake = ["Hoaam…", "Eh, aku ketiduran.", "Hm? Sudah pagi?"]
    static let drop = ["Whoa!", "Pusing…", "Pelan-pelan dong!", "Dunia berputar…"]
    static let held = ["Eh eh eh!", "Mau dibawa ke mana?", "Tinggi banget!"]
    static let sneeze = ["Hatchi!", "Hatsyii!"]
    static let trip = ["Aduh!", "Kesandung piksel."]
    static let gift = ["Buat kamu!", "Aku nemu ini.", "Ini, hadiah."]
    static let thanks = ["Sama-sama!", "Hehe, suka?"]
    static let eat = ["Nyam nyam.", "Enak!", "Makasih makanannya."]
    static let ball = ["Bola!", "Oper sini!", "Gol!"]
    static let tired = ["Capek… istirahat dulu.", "Fiuh."]
    static let butterfly = ["Kupu-kupu!", "Tunggu aku!"]
    static let lost = ["Yaah, terbang…", "Lain kali kutangkap."]
    static let hello = ["Halo!", "Hai hai!", "Aku datang!"]
    static let jokes = [
        "Kenapa komputer kedinginan? Jendelanya kebuka.", "Aku bukan bug. Aku fitur.", "Ctrl+Z dulu kalau salah.",
        "Rapat lagi? Aku ikut dari sini saja.", "Kopi keberapa hari ini?", "Simpan dulu, baru main sama aku.",
        "Aku tidak memakan RAM. Cuma ikan.", "Tab-nya banyak banget, ya.",
    ]

    static func greeting(hour: Int) -> [String] {
        switch hour {
        case 4..<11: return morning
        case 11..<15: return noon
        case 15..<19: return evening
        default: return night
        }
    }
}
