// Render teaser.html → web/public/videos/temu-teaser.mp4 (1920×1080, 30 fps, dengan lagu dari music.py).
// Pakai: node video/src/render.js   (butuh Playwright + Chromium dan ffmpeg)
// Setiap frame diambil dengan window.seek(t), jadi hasilnya deterministik.
//
// Versi portrait + lagu:  node video/src/render.js portrait
//   teaser-portrait.html → web/public/videos/temu-teaser-portrait.mp4 (1080×1920, 30 fps, AAC stereo).
//   Lagu dibuat oleh music.py (butuh python3 + numpy), sama untuk kedua versi.
const { chromium } = require('playwright');
const { spawn, execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PORTRAIT = process.argv.includes('portrait');
const FPS = 30;
const W = PORTRAIT ? 1080 : 1920, H = PORTRAIT ? 1920 : 1080;
const SRC = path.join(__dirname, PORTRAIT ? 'teaser-portrait.html' : 'teaser.html');
const OUT = path.join(__dirname, '..', '..', 'web', 'public', 'videos', PORTRAIT ? 'temu-teaser-portrait.mp4' : 'temu-teaser.mp4');
// lagu yang sama untuk landscape dan portrait (linimasa kedua versi sama)
const MUSIC = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'temu-')), 'music.wav');

(async () => {
  if (MUSIC) execFileSync('python3', [path.join(__dirname, 'music.py'), MUSIC], { stdio: 'inherit' });
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  await page.goto('file://' + SRC + '?render');
  await page.evaluate(() => document.fonts.ready);
  await page.waitForLoadState('networkidle');
  const duration = await page.evaluate(() => window.DURATION);
  const frames = Math.round(duration * FPS);

  const ff = spawn('ffmpeg', [
    '-y', '-loglevel', 'error',
    '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'mjpeg', '-i', '-',
    ...(MUSIC ? ['-i', MUSIC, '-map', '0:v', '-map', '1:a', '-c:a', 'aac', '-b:a', '192k', '-shortest'] : []),
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '23', '-pix_fmt', 'yuv420p',
    '-movflags', '+faststart', OUT,
  ], { stdio: ['pipe', 'inherit', 'inherit'] });

  for (let i = 0; i < frames; i++) {
    await page.evaluate((t) => window.seek(t), i / FPS);
    const buf = await page.screenshot({ type: 'jpeg', quality: 95 });
    if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once('drain', r));
    if (i % 60 === 0) process.stdout.write(`frame ${i}/${frames}\n`);
  }
  ff.stdin.end();
  await new Promise((r) => ff.on('close', r));
  await browser.close();
  console.log('selesai →', OUT);
})();
