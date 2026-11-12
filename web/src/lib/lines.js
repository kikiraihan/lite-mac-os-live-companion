// Celoteh pet di web (versi Mac punya daftarnya sendiri di Lines.swift).
export const LINES = {
  idle: ['Hmm…', 'Lagi ngapain?', 'Aku di sini ya.', 'Semangat!', 'Jangan lupa minum.', 'Boleh dielus?', 'Sore yang enak.'],
  pet: ['Hehe!', 'Lagi dong.', 'Geli!', 'Makasih ♥'],
  drop: ['Whoa!', 'Pusing…', 'Pelan-pelan!'],
  wake: ['Hoaam…', 'Eh, aku ketiduran.'],
  hello: ['Halo!', 'Hai hai!', 'Yuk main!'],
}
export const pick = (list) => list[Math.floor(Math.random() * list.length)]
