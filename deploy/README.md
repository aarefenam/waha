# Deploy WAHA — Multi Bisnis di Satu Server

Runbook deploy WAHA (edisi **Core**, dari source repo ini) ke server bersama
`ubuntu@<IP-SERVER>` yang sudah berisi project lain.

## Jawaban singkat: bisa, dan arsitekturmu sudah benar

Ya, WAHA bisa dipakai untuk beberapa nomor WhatsApp dari beberapa bisnis.
Dan dugaanmu tepat: di edisi **Core**, satu container = satu nomor WhatsApp.

Catatan penting hasil pengujian langsung di fork ini: README WAHA menyebut
multi-session dalam satu container sebagai fitur **Plus**
([README.md:101](../README.md#L101)), tetapi pada Core dengan penyimpanan lokal
(SQLite) keduanya ternyata **berfungsi** — beberapa session berjalan bersamaan,
webhook bisa beda per session, dan API key ber-scope (`POST /api/keys` dengan
field `session`) benar-benar menolak akses ke session lain dengan `403`.

Meski begitu, satu container per bisnis tetap pilihan yang disarankan untuk
nomor milik pelanggan: isolasi kegagalan, update bertahap, dan rollback per
pelanggan hanya mungkin kalau prosesnya terpisah.

Untung sisi teknisnya juga lebih baik:

| Aspek | 1 container/nomor | 1 container banyak nomor (Plus) |
| --- | --- | --- |
| Bisnis A crash / logout | bisnis lain aman | bisa menyeret yang lain |
| API key | terpisah otomatis | butuh fitur Plus |
| Webhook & konfigurasi | per bisnis, bebas beda | bercampur |
| Update versi | bisa bertahap, satu-satu | serempak |
| Beban RAM | dijaga limit per container | satu proses besar |

Kekurangannya: tiap bisnis punya base URL + API key sendiri, jadi aplikasimu
harus menyimpan pasangan `(base_url, api_key)` per bisnis. Nama session di
dalam tiap container tetap `default` — tidak perlu diseragamkan lewat API.

## Arsitektur di server

Server ini (`<IP-SERVER>`, Oracle Cloud, Ubuntu 24.04, 2 vCPU / 11.6GB) sudah
berisi **AzuraCast** (radio, memegang port 80/443/2022/8000–8496) dan **app hotel**
(Next.js di port 8080 + PostgreSQL 5433). Tidak ada nginx/caddy di host, jadi
port 80/443 tidak bisa dipakai WAHA. Karena itu jalur publiknya lewat
**Cloudflare Tunnel** — tanpa membuka port apa pun dan tanpa menyentuh AzuraCast.

```
Internet
   │  https://wa-tokobaju.domain.com     https://wa-klinik.domain.com
   ▼
Cloudflare (TLS) ──── tunnel keluar, TIDAK ada port masuk yang dibuka
   ▼
container waha-cloudflared  ── network "waha-net" ──┐
   │  http://waha-tokobaju:3000                     │ http://waha-klinik:3000
   ▼                                                ▼
┌────────────────────────┐  ┌────────────────────────┐   project lain
│ container waha-tokobaju│  │ container waha-klinik  │   (tidak disentuh)
│ session: default       │  │ session: default       │   ┌──────────────┐
│ API key: xxx           │  │ API key: yyy           │   │ azuracast    │
│ mem_limit 1g, cpus 1   │  │ mem_limit 1g, cpus 1   │   │ hotel:8080   │
│ 127.0.0.1:3101 (debug) │  │ 127.0.0.1:3102 (debug) │   │ postgres:5433│
└────────────────────────┘  └────────────────────────┘   └──────────────┘
   volume: ./sessions ./media (terpisah per instance)

/opt/waha/
├── src/                     # clone repo ini (buat build image)
├── docker-compose.yml       # template dipakai semua instance
├── env.instance.example
├── wahactl                  # CLI pengelola instance
├── preflight.sh
├── nginx/
│   ├── waha-vhost.conf.template
│   └── generated/            # hasil `wahactl nginx <slug>`
└── instances/
    ├── tokobaju/{.env, sessions/, media/}
    └── klinik/{.env, sessions/, media/}
```

## Yang menjaga project lain tetap aman

Ini bagian yang paling penting karena server-nya bersama:

1. **Semua di `/opt/waha`** — tidak ada file WAHA yang nyempil di direktori
   project lain.
2. **Port hanya di `127.0.0.1`** (3101, 3102, …). Tidak ada port WAHA yang
   terbuka ke internet langsung. Ini juga menutup celah klasik: port yang
   dipublish Docker **menembus ufw**, jadi kalau di-bind `0.0.0.0` API-mu
   telanjang di internet walaupun firewall-nya aktif.
3. **`mem_limit` + `cpus` per container.** Image WAHA default-nya
   `NODE_OPTIONS=--max-old-space-size=16384` (16GB!,
   [Dockerfile:106](../Dockerfile#L106)). Di server bersama itu resep OOM-killer
   membantai project lain. Compose di sini menimpanya jadi 1GB dan memasang
   batas RAM/CPU keras.
4. **Log dibatasi** (`max-size 50m`, 5 file) supaya disk tidak diam-diam penuh.
5. **Network bawaan per compose project** — tiap instance dapat bridge network
   sendiri, tidak menempel ke network project lain, dan tidak pakai
   `network_mode: host`.
6. **nginx cuma ditambah `server` block baru**, konfigurasi vhost lama tidak
   diubah.
7. **`wahactl prune` sengaja tidak memakai `docker system prune -a` atau
   `docker image prune`** — keduanya menghapus image project lain. Yang
   dibersihkan hanya tag `waha-local:*` versi lama yang tidak dipakai container.
8. **Build image dibatasi resource sungguhan.** `nice`/`ionice` di sisi client
   TIDAK membatasi apa pun karena buildkit berjalan di dalam daemon Docker, jadi
   `wahactl build` memakai builder `docker buildx --driver docker-container`
   dengan `cpu-quota` dan `memory` (default 1 CPU / 4GB). Flavor `nobrowser`
   memotong bagian build paling berat.

## Langkah 0 — preflight (wajib, read-only)

Sebelum menyentuh apa pun, kumpulkan dulu kondisi server:

```bash
scp deploy/preflight.sh ubuntu@<IP-SERVER>:/tmp/
ssh ubuntu@<IP-SERVER> bash /tmp/preflight.sh
```

Output ini menentukan tiga keputusan: reverse proxy apa yang dipakai, port mana
yang bebas, dan berapa nomor WA yang realistis dari RAM yang tersisa.

### Perkiraan kebutuhan RAM per nomor

| Engine | RAM/nomor | Image flavor | Catatan |
| --- | --- | --- | --- |
| `GOWS` | ~200–400 MB | `nobrowser` | **Dipakai di setup ini.** Paling ringan. |
| `NOWEB` | ~300–500 MB | `nobrowser` | Baileys, tanpa browser. |
| `WEBJS` | ~1.2–1.5 GB | `browser` | 1 Chromium per container, fitur terlengkap. |
| `WPP` | ~1.2–1.5 GB | `browser` | Juga berbasis browser. |

Setup ini memakai GOWS/NOWEB untuk semua instance, jadi satu server yang sama
bisa menampung jauh lebih banyak nomor. Engine diset per instance di `.env`,
jadi kalau nanti ada satu bisnis yang butuh fitur khusus WEBJS, cukup instance
itu yang dipindah ke image `browser` — yang lain tidak terpengaruh.

## Langkah 1 — install

Docker harus sudah ada (preflight akan memberi tahu). Kalau belum, install
Docker resmi dulu — jangan `apt install docker.io` kalau server sudah punya
container yang jalan dengan versi tertentu.

Kalau repo bisa diakses dari server:

```bash
ssh ubuntu@<IP-SERVER>
mkdir -p /opt/waha
git clone -b core https://github.com/aarefenam/waha /opt/waha/src
bash /opt/waha/src/deploy/bootstrap.sh
```

Kalau repo-nya privat / tidak bisa di-clone dari server, kirim source dari
laptop (dari root repo ini):

```bash
ssh ubuntu@<IP-SERVER> 'mkdir -p /opt/waha/src'
rsync -az --exclude node_modules --exclude .git --exclude dist \
  --exclude .media --exclude .sessions \
  ./ ubuntu@<IP-SERVER>:/opt/waha/src/
ssh ubuntu@<IP-SERVER> bash /opt/waha/src/deploy/bootstrap.sh
```

`bootstrap.sh` idempotent dan menolak jalan kalau prasyarat kurang. Yang
dilakukan: cek docker/compose (**tidak** meng-install sendiri, supaya versi yang
dipakai project lain tidak berubah), cek sisa disk, bikin `/opt/waha/instances`,
menyalin perkakas, memasang perintah `wahactl`, memvalidasi
`docker-compose.yml` lewat `docker compose config`, dan mengingatkan kalau nginx
belum punya `map $http_upgrade $connection_upgrade`.

## Langkah 2 — build image (sekali saja, dipakai semua bisnis)

Karena semua instance memakai GOWS/NOWEB, build flavor **nobrowser** — Chromium,
fonts, dan xvfb tidak diikutsertakan:

```bash
wahactl build            # -> waha-local:nobrowser (+ tag versi git sha)
```

Jauh lebih ringan daripada image WEBJS: build ~10–15 menit, image ~1GB, dan
tidak membebani server selama build (builder dibatasi 1 CPU). Kalau nanti ada satu
bisnis yang butuh WEBJS/WPP:

```bash
wahactl build browser    # -> waha-local:browser (dengan Chromium)
# lalu di .env instance itu: WAHA_IMAGE=waha-local:browser
#                            WAHA_SHM_SIZE=1gb, WAHA_MEM_LIMIT=3g
#                            hapus baris WAHA_RUN_XVFB=false
```

Setiap build juga menghasilkan tag versi (`waha-local:nobrowser-<sha>`), jadi
rollback tinggal mengganti `WAHA_IMAGE` di `.env` instance yang bermasalah.

Alternatif tanpa build sama sekali: pakai image resmi
(`WAHA_IMAGE=devlikeapro/waha:latest`). Tapi kalau kamu butuh fitur yang kamu
tambahkan sendiri di fork ini (mis. endpoint
`GET /api/sessions/{name}/timelock`), build dari source ini yang benar.

## Langkah 3 — tambah pelanggan/bisnis baru (satu perintah)

Setelah `cf-api.env` terisi, seluruh onboarding jadi satu perintah:

```bash
sudo wahactl add tokobaju
```

Yang dikerjakan otomatis: bikin instance (port + API key + password acak), start
container, tunggu sampai `healthy`, buat subdomain `wa-tokobaju.<domain>` beserta
ingress rule tunnel + record DNS, lalu verifikasi `https://.../ping` dari luar.
Hasil akhirnya dicetak: URL, API key, dan kredensial dashboard.

Menghapus pelanggan yang berhenti: `sudo wahactl rm tokobaju` — container, data
auth, rute tunnel, dan record DNS ikut dibersihkan.

### Cara manual (kalau tidak pakai API token Cloudflare)

```bash
# port, API key, password dashboard/swagger digenerate otomatis
wahactl new tokobaju wa-tokobaju.domain.com

# opsional, kalau ada yang perlu disesuaikan:
nano /opt/waha/instances/tokobaju/.env
#   WHATSAPP_HOOK_URL=https://app-tokobaju.../webhook/waha
#   WHATSAPP_DEFAULT_ENGINE=GOWS (default) | NOWEB
#   WAHA_MEM_LIMIT / WAHA_CPUS sesuai kapasitas server

wahactl up tokobaju
wahactl ls
```

Domain yang diberikan ke `wahactl new` otomatis mengisi `WAHA_DOMAIN` dan
`WAHA_BASE_URL` — `WAHA_BASE_URL` yang salah adalah penyebab paling umum URL
file media tidak bisa dibuka, jadi jangan dilewat.

Lalu ekspos publiknya lewat Cloudflare Tunnel — cukup tambah **Public Hostname**
di dashboard tunnel, tanpa menyentuh server:

| Field | Isi |
| --- | --- |
| Subdomain | `wa-tokobaju` |
| Domain | `domain.com` |
| Service | `HTTP` → `waha-tokobaju:3000` |

`waha-tokobaju` adalah alias container di network `waha-net`, jadi cloudflared
menjangkaunya langsung tanpa port host. Setup awal tunnel (sekali saja) ada di
[cloudflared/docker-compose.yml](cloudflared/docker-compose.yml).

Kalau suatu saat server ini punya nginx sendiri (mis. AzuraCast dipindah), ada
jalur alternatif: `wahactl nginx <slug>` merender vhost lengkap ke
`/opt/waha/nginx/generated/` lalu mencetak perintah pemasangannya. `wahactl`
**tidak** pernah menyentuh `/etc/nginx` sendiri.

Scan QR:

```bash
sudo wahactl qr tokobaju    # simpan qr.png di direktori instance
# ambil ke laptop:
#   scp -i ~/.ssh/<kunci-server>.key \
#     ubuntu@<IP-SERVER>:/opt/waha/instances/tokobaju/qr.png .
# atau buka https://wa-tokobaju.domain.com/dashboard (login dari .env)
sudo wahactl status tokobaju   # tunggu sampai WORKING
```

Catatan server ini: login SSH-nya `ubuntu@<IP-SERVER>` dengan key
`~/.ssh/<kunci-server>.key` (image Oracle Ubuntu memblokir login root),
dan `/opt/waha` milik root — jadi semua perintah `wahactl` dijalankan dengan
`sudo`.

Ulangi untuk bisnis kedua, ketiga, dst. Tiap bisnis dapat port, API key,
password dashboard, webhook, dan volume sendiri.

## Cara aplikasi bisnis memakainya

Tiap bisnis memakai base URL + API key sendiri, session selalu `default`:

```bash
curl -X POST https://wa-tokobaju.domain.com/api/sendText \
  -H 'X-Api-Key: <API_KEY_TOKOBAJU>' \
  -H 'Content-Type: application/json' \
  -d '{"session":"default","chatId":"628123456789@c.us","text":"Halo"}'
```

Di aplikasimu, simpan tabel sederhana:

| business | base_url | api_key |
| --- | --- | --- |
| tokobaju | https://wa-tokobaju.domain.com | … |
| klinik | https://wa-klinik.domain.com | … |

Kalau nanti ingin **satu endpoint** untuk semua bisnis, tinggal taruh router
tipis di aplikasimu (atau satu vhost nginx yang memetakan `/wa/tokobaju/*` ke
port 3101, `/wa/klinik/*` ke 3102) — tanpa mengubah arsitektur container.
Alternatif lain adalah upgrade ke WAHA Plus, yang mendukung banyak session
dalam satu container.

## Operasional

```bash
wahactl help                # daftar semua perintah
wahactl ls                  # semua instance + status session WhatsApp
wahactl logs tokobaju       # log satu instance
wahactl restart tokobaju
wahactl down tokobaju       # stop, data tetap aman
wahactl upgrade             # rebuild image (flavor yang terpakai) + recreate semua
wahactl prune               # hapus tag versi waha-local lama yang tak terpakai
wahactl rm tokobaju         # hapus instance (butuh konfirmasi, harus scan ulang)
```

### Update dari project asli (upstream)

Fork ini tidak pernah ikut berubah sendiri ketika `devlikeapro/waha` merilis
perbaikan. Update berjalan dua tahap, dan keduanya bisa otomatis.

**Tahap 1 — fork disinkronkan di GitHub.**
[`.github/workflows/sync-upstream.yml`](../.github/workflows/sync-upstream.yml)
berjalan tiap hari 02:00 WIB: `core` di-fast-forward dari `upstream/core`, lalu
branch deploy di-merge dari `core`. Kalau gagal (mis. konflik), workflow membuka
issue supaya tidak lewat diam-diam.

Aturan yang menjaganya tetap mulus: **jangan pernah commit ke `core`.** Branch
itu cerminan murni upstream. Semua perkakas dan penyesuaian sendiri hidup di
branch deploy. Tag upstream sengaja tidak ditarik, karena `build.yaml` berjalan
`on: push: tags` dan akan memicu build Docker matrix yang berat.

Dua catatan GitHub: scheduled workflow di fork dinonaktifkan otomatis setelah 60
hari tanpa aktivitas repo (jalankan manual lewat tab Actions untuk
menghidupkannya lagi), dan Actions perlu diaktifkan sekali di tab Actions.

**Tahap 2 — server menarik dan men-deploy.**

```bash
wahactl selfupdate --check   # cuma lapor ada berapa commit baru
wahactl selfupdate           # tarik, build, deploy, verifikasi, rollback bila rusak
```

`selfupdate` sengaja berbeda dari `upgrade`: `upgrade` hanya membangun ulang
image dari source yang sudah ada, sedangkan `selfupdate` menarik commit baru
dulu. Urutannya: catat session yang sedang `WORKING`, `git merge --ff-only`,
build tiap flavor yang dipakai, lalu deploy instance satu per satu. Setiap
instance ditunggu sampai container `healthy`; instance yang tadinya `WORKING`
juga harus kembali `WORKING`. Kalau tidak, image dikembalikan ke tag versi lama
(`waha-local:<flavor>-<sha>`) dan instance itu dijalankan ulang. Instance yang
memang sudah `FAILED` sebelum update tidak dipakai sebagai patokan, supaya
nomor yang belum discan tidak memicu rollback palsu.

Karena rollback bergantung pada tag versi lama, jalankan `wahactl prune` hanya
setelah update terbukti stabil.

Jadwalkan lewat systemd (unit ada di [systemd/](systemd/)):

```bash
sudo install -m 644 /opt/waha/src/deploy/systemd/waha-selfupdate.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now waha-selfupdate.timer
systemctl list-timers waha-selfupdate.timer
```

Default: tiap Minggu 03:00 WIB. Kalau lebih suka diberi tahu dulu dan deploy
sendiri, ubah `ExecStart` di service jadi `wahactl selfupdate --check`.

**Notifikasi WhatsApp (opsional).** `selfupdate` bisa mengabari hasilnya lewat
salah satu instance WAHA milik sendiri. Buat `/opt/waha/notify.env`:

```bash
WAHA_NOTIFY_URL=https://wa-<slug>.<domain>
WAHA_NOTIFY_KEY=<API key instance itu>
WAHA_NOTIFY_CHATID=628xxxxxxxxxx@c.us
```

Tanpa file itu update tetap berjalan, hanya senyap. Pakai instance yang bukan
nomor pelanggan, supaya notifikasi teknis tidak masuk ke chat bisnis.

**Syarat.** `/opt/waha/src` harus berupa clone git, bukan hasil `rsync` —
`selfupdate` menolak jalan kalau bukan repo. Kalau source di server dikirim
lewat rsync, ganti sekali:

```bash
sudo rm -rf /opt/waha/src
sudo git clone -b <branch-deploy> https://github.com/aarefenam/waha /opt/waha/src
```

### Backup

Yang wajib di-backup adalah folder auth session — kalau hilang, semua nomor
harus scan QR ulang:

```bash
tar czf /root/backup-waha-$(date +%F).tar.gz \
  -C /opt/waha instances --exclude='*/media/*'
```

Simpan juga `.env` tiap instance (isinya API key & password) di tempat aman.

### Hal yang perlu dipantau

- RAM server: satu instance WEBJS bisa naik pelan-pelan. `mem_limit` menahannya,
  tapi container-nya bisa di-restart oleh Docker — cek `wahactl ls`.
- Disk: kalau `WHATSAPP_FILES_LIFETIME=0`, folder `media/` tumbuh terus. Set
  mis. `604800` (7 hari) untuk bisnis dengan banyak media.
- Session logout: pantau event `session.status` lewat webhook, jangan mengandalkan
  polling manual.

## Status

Setup ini sudah berjalan di produksi: image dibuild dari source, instance
dijalankan lewat `wahactl`, jalur publik memakai Cloudflare Tunnel, dan
onboarding satu pelanggan cukup `sudo wahactl add <nama>`.

Panduan operasional harian (kirim/terima pesan, format nomor, troubleshooting)
ada di [MANUAL.md](MANUAL.md).

Semua contoh di dokumen ini memakai placeholder `<IP-SERVER>`, `<domain>`, dan
`<API-KEY>`. Nilai aslinya hanya ada di server pada
`/opt/waha/instances/<nama>/.env` dan `/opt/waha/cloudflared/` — jangan pernah
dimasukkan ke repo.
