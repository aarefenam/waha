#!/usr/bin/env bash
#
# preflight.sh - inspeksi server SEBELUM deploy WAHA.
#
# READ-ONLY: script ini tidak mengubah apa pun. Tujuannya memastikan
# deploy WAHA tidak bentrok dengan project lain yang sudah jalan.
#
# Cara pakai:
#   scp deploy/preflight.sh root@SERVER:/tmp/ && ssh root@SERVER bash /tmp/preflight.sh
set -uo pipefail

function section() {
  echo
  echo "############################################################"
  echo "# $*"
  echo "############################################################"
}

section 'SISTEM'
hostname
uname -a
cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION)='

section 'RAM & SWAP (menentukan berapa nomor WA yang aman)'
free -h
echo "--- 5 proses pemakai RAM terbesar ---"
ps -eo pmem,pcpu,rss,comm --sort=-rss | head -6

section 'CPU'
nproc
grep -m1 'model name' /proc/cpuinfo 2>/dev/null
uptime

section 'DISK (build image WAHA butuh ~10-15GB bebas)'
df -h /
df -h /var/lib/docker 2>/dev/null
echo "--- pemakaian docker ---"
docker system df 2>/dev/null || echo 'docker tidak tersedia'

section 'DOCKER'
docker --version 2>/dev/null || echo 'DOCKER BELUM TERPASANG'
docker compose version 2>/dev/null || echo 'DOCKER COMPOSE V2 BELUM ADA'

section 'CONTAINER YANG SUDAH JALAN (jangan diganggu)'
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null

section 'DOCKER NETWORK & VOLUME (punya project lain)'
docker network ls 2>/dev/null
docker volume ls 2>/dev/null | head -30

section 'PORT YANG SUDAH DIPAKAI (WAHA akan pakai 3101+)'
ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null

section 'REVERSE PROXY'
for svc in nginx caddy traefik apache2 haproxy; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "AKTIF: $svc"
  fi
done
docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null |
  grep -Ei 'nginx|caddy|traefik|proxy' || true
echo "--- vhost nginx yang ada ---"
ls -1 /etc/nginx/sites-enabled/ 2>/dev/null
ls -1 /etc/nginx/conf.d/ 2>/dev/null
echo "--- map \$connection_upgrade sudah ada? (dibutuhkan untuk WebSocket) ---"
grep -rls 'connection_upgrade' /etc/nginx/ 2>/dev/null | head -5

section 'FIREWALL'
ufw status verbose 2>/dev/null || iptables -L INPUT -n 2>/dev/null | head -20

section 'SERTIFIKAT / DOMAIN'
certbot certificates 2>/dev/null | grep -E 'Certificate Name|Domains|Expiry' || echo 'certbot tidak ada'

section 'DIREKTORI /opt (rencana: /opt/waha)'
ls -la /opt 2>/dev/null

section 'RINGKASAN'
mem_total_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
mem_avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
echo "RAM total: ${mem_total_mb}MB, tersedia sekarang: ${mem_avail_mb}MB"
echo "Perkiraan kapasitas nomor WA dari RAM yang tersedia:"
echo "  engine WEBJS  (~1500MB/nomor): $((mem_avail_mb / 1500)) nomor"
echo "  engine NOWEB  (~400MB/nomor) : $((mem_avail_mb / 400)) nomor"
echo "  engine GOWS   (~300MB/nomor) : $((mem_avail_mb / 300)) nomor"
echo
echo "Selesai. Tidak ada perubahan yang dilakukan di server ini."
