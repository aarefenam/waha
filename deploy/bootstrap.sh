#!/usr/bin/env bash
#
# bootstrap.sh - pasang perkakas WAHA di /opt/waha (Langkah 1 di README).
#
# Idempotent: aman dijalankan berulang. Tidak menginstall apa pun secara
# diam-diam dan tidak menyentuh container/image/vhost project lain.
#
# Cara pakai di server:
#   git clone -b core https://github.com/aarefenam/waha /opt/waha/src
#   bash /opt/waha/src/deploy/bootstrap.sh
#
# Kalau repo tidak bisa di-clone dari server, kirim source dari laptop:
#   rsync -az --exclude node_modules --exclude .git --exclude dist \
#     ./ ubuntu@<IP-SERVER>:/opt/waha/src/
#   ssh ubuntu@<IP-SERVER> bash /opt/waha/src/deploy/bootstrap.sh
set -euo pipefail

WAHA_HOME="${WAHA_HOME:-/opt/waha}"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(dirname "$DEPLOY_DIR")"

GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
BOLD=$'\033[1m'
NC=$'\033[0m'

function info() {
  echo "${GREEN}==>${NC} $*"
}

function warn() {
  echo "${YELLOW}warn:${NC} $*" >&2
}

function die() {
  echo "${RED}error:${NC} $*" >&2
  exit 1
}

info "Source WAHA: ${SRC_DIR}"
[ -f "${SRC_DIR}/Dockerfile" ] || die "Dockerfile tidak ada di ${SRC_DIR} - jalankan script ini dari dalam repo WAHA"

#
# 1. Prasyarat. Sengaja TIDAK auto-install: server ini punya project lain yang
#    jalan, mengganti versi docker/compose diam-diam bisa mematikan mereka.
#
info "Cek prasyarat"
command -v docker >/dev/null || die "docker belum terpasang. Install dulu docker resmi (https://docs.docker.com/engine/install/), lalu jalankan ulang script ini."
docker compose version >/dev/null 2>&1 || die "docker compose v2 tidak tersedia. Install plugin docker-compose-plugin, lalu jalankan ulang."
docker info >/dev/null 2>&1 || die "docker daemon tidak bisa diakses (butuh root / grup docker)."
echo "  docker  : $(docker --version)"
echo "  compose : $(docker compose version --short 2>/dev/null)"

avail_gb="$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}' || true)"
if [ -n "${avail_gb:-}" ] && [ "$avail_gb" -lt 15 ]; then
  warn "disk bebas di / hanya ${avail_gb}GB. Build image butuh ~10-15GB. Bersihkan dulu atau build di disk lain."
fi

#
# 2. Struktur direktori
#
info "Menyiapkan ${WAHA_HOME}"
mkdir -p "${WAHA_HOME}/instances"

if [ "$SRC_DIR" != "${WAHA_HOME}/src" ]; then
  if [ -e "${WAHA_HOME}/src" ] && [ ! -L "${WAHA_HOME}/src" ]; then
    warn "${WAHA_HOME}/src sudah ada dan bukan symlink - dibiarkan apa adanya"
  else
    ln -sfn "$SRC_DIR" "${WAHA_HOME}/src"
    info "symlink ${WAHA_HOME}/src -> ${SRC_DIR}"
  fi
fi

#
# 3. Salin perkakas (backup kalau berbeda)
#
function install_file() {
  local src="$1" dst="$2"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    cp "$dst" "${dst}.bak.$(date +%Y%m%d%H%M%S)"
    warn "$(basename "$dst") berbeda dari versi baru - versi lama disimpan sebagai .bak"
  fi
  cp "$src" "$dst"
}

info "Menyalin perkakas ke ${WAHA_HOME}"
install_file "${DEPLOY_DIR}/docker-compose.yml" "${WAHA_HOME}/docker-compose.yml"
install_file "${DEPLOY_DIR}/env.instance.example" "${WAHA_HOME}/env.instance.example"
install_file "${DEPLOY_DIR}/wahactl" "${WAHA_HOME}/wahactl"
install_file "${DEPLOY_DIR}/preflight.sh" "${WAHA_HOME}/preflight.sh"
install_file "${DEPLOY_DIR}/cf-route.py" "${WAHA_HOME}/cf-route.py"
mkdir -p "${WAHA_HOME}/nginx"
cp -r "${DEPLOY_DIR}/nginx/." "${WAHA_HOME}/nginx/"
chmod +x "${WAHA_HOME}/wahactl" "${WAHA_HOME}/preflight.sh"

# Cloudflare Tunnel: compose disalin, tapi .env (berisi token) tidak pernah
# ditimpa supaya token yang sudah diisi tidak hilang saat bootstrap diulang.
mkdir -p "${WAHA_HOME}/cloudflared"
install_file "${DEPLOY_DIR}/cloudflared/docker-compose.yml" "${WAHA_HOME}/cloudflared/docker-compose.yml"
install_file "${DEPLOY_DIR}/cloudflared/cf-api.env.example" "${WAHA_HOME}/cloudflared/cf-api.env.example"
if [ ! -f "${WAHA_HOME}/cloudflared/.env" ]; then
  printf '%s\n' \
    '# Token dari Cloudflare Zero Trust -> Networks -> Tunnels & Mesh' \
    '# -> pilih tunnel -> Add a connector -> tab Docker -> salin bagian setelah --token' \
    'CLOUDFLARE_TUNNEL_TOKEN=' > "${WAHA_HOME}/cloudflared/.env"
  chmod 600 "${WAHA_HOME}/cloudflared/.env"
  info "template ${WAHA_HOME}/cloudflared/.env dibuat (token masih kosong)"
fi

if [ -e /usr/local/bin/wahactl ] && [ ! -L /usr/local/bin/wahactl ]; then
  warn "/usr/local/bin/wahactl sudah ada dan bukan symlink - dilewati"
else
  ln -sfn "${WAHA_HOME}/wahactl" /usr/local/bin/wahactl
  info "perintah 'wahactl' terpasang"
fi

#
# 4. Validasi compose (pakai instance sementara, langsung dihapus)
#
info "Validasi docker-compose.yml"
validate_dir="$(mktemp -d)"
trap 'rm -rf "$validate_dir"' EXIT
sed -e 's|^WAHA_INSTANCE=.*|WAHA_INSTANCE=validate|' \
  -e 's|^WAHA_PORT=.*|WAHA_PORT=39999|' \
  "${WAHA_HOME}/env.instance.example" > "${validate_dir}/.env"
if docker compose --project-name waha-validate \
  --project-directory "$validate_dir" \
  --file "${WAHA_HOME}/docker-compose.yml" config -q; then
  info "compose valid"
else
  die "docker-compose.yml tidak valid - jangan lanjut sebelum ini beres"
fi

#
# 5. Catatan nginx
#
if command -v nginx >/dev/null; then
  if ! grep -rqs 'connection_upgrade' /etc/nginx/; then
    warn "nginx belum punya 'map \$http_upgrade \$connection_upgrade' di level http{} - WebSocket (/ws) akan gagal. Contohnya ada di komentar ${WAHA_HOME}/nginx/waha-vhost.conf.template."
  fi
else
  warn "nginx tidak terpasang di host. Kalau reverse proxy-nya jalan di container (caddy/traefik/nginx-proxy), arahkan ke 127.0.0.1:<WAHA_PORT> lewat host gateway."
fi

#
# 6. Ringkasan
#
echo
info "Bootstrap selesai. Tidak ada project lain yang disentuh."
echo
echo "${BOLD}Langkah berikutnya:${NC}"
echo "  1. wahactl build              # image nobrowser (GOWS/NOWEB), ~10-15 menit"
echo "  2. wahactl new <nama-bisnis>  # port + API key otomatis"
echo "  3. edit /opt/waha/instances/<nama-bisnis>/.env  (WAHA_BASE_URL, webhook)"
echo "  4. wahactl up <nama-bisnis>"
echo "  5. pasang vhost nginx + certbot, lalu: wahactl qr <nama-bisnis>"
echo
echo "Runbook lengkap: ${SRC_DIR}/deploy/README.md"
