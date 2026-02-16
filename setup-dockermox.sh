#!/bin/bash
#
# ============================================================
#  Dockermox All-in-One Setup Script
#  Automates: Container → Network → LXC Patching → Auto LXC
#  Cukup 1x jalankan, semua langsung jalan!
# ============================================================

set -e

# ── Warna output ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Konfigurasi default ─────────────────────────────────────
CONTAINER_NAME="proxmoxve"
HOSTNAME="pve"
PORT="8006"
NETWORK_NAME="eth2"

# ── Helper functions ─────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[  OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[FAIL]${NC} $1"; }
step()    { echo -e "\n${BOLD}${CYAN}═══ STEP $1: $2 ═══${NC}"; }

# ── Banner ───────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║       🐳 Dockermox All-in-One Setup 🐳          ║"
echo "║     Proxmox VE in Docker + LXC Support          ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ══════════════════════════════════════════════════════════════
# STEP 1: Pre-checks
# ══════════════════════════════════════════════════════════════
step "1/7" "Pre-checks"

# Check Docker
if ! command -v docker &> /dev/null; then
    error "Docker is not installed! Please install Docker first."
    exit 1
fi
success "Docker found: $(docker --version)"

# Check /dev/fuse
if [ ! -e /dev/fuse ]; then
    error "/dev/fuse not found!"
    echo -e "  ${YELLOW}→ Aktifkan modul fuse di kernel:${NC}"
    echo -e "    ${BOLD}modprobe fuse${NC}"
    exit 1
fi
success "/dev/fuse is available"

# Check if container already exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    warn "Container '${CONTAINER_NAME}' already exists!"
    read -p "  Hapus dan buat ulang? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Menghapus container lama..."
        docker rm -f "${CONTAINER_NAME}" &> /dev/null || true
    else
        info "Menggunakan container yang sudah ada."
        SKIP_CREATE=true
    fi
fi

# ══════════════════════════════════════════════════════════════
# STEP 2: Auto-detect subnet dari host
# ══════════════════════════════════════════════════════════════
step "2/7" "Auto-detect subnet"

# Cari default interface (interface yang punya default route)
DEFAULT_IFACE=$(ip route | grep '^default' | head -1 | awk '{print $5}')
if [ -z "$DEFAULT_IFACE" ]; then
    warn "Tidak bisa detect default interface, menggunakan fallback."
    DEFAULT_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
fi

if [ -n "$DEFAULT_IFACE" ]; then
    # Ambil IP dan CIDR dari interface default
    HOST_IP=$(ip -4 addr show "$DEFAULT_IFACE" | grep -oP 'inet \K[\d.]+' | head -1)
    HOST_CIDR=$(ip -4 addr show "$DEFAULT_IFACE" | grep -oP 'inet \K[\d.]+/\d+' | head -1)
    HOST_MASK=$(echo "$HOST_CIDR" | cut -d'/' -f2)

    if [ -n "$HOST_IP" ] && [ -n "$HOST_MASK" ]; then
        # Hitung network address dari host IP
        IFS='.' read -r o1 o2 o3 o4 <<< "$HOST_IP"

        # Hitung subnet mask bits
        if [ "$HOST_MASK" -le 8 ]; then
            SUBNET="${o1}.0.0.0/${HOST_MASK}"
        elif [ "$HOST_MASK" -le 16 ]; then
            SUBNET="${o1}.${o2}.0.0/${HOST_MASK}"
        elif [ "$HOST_MASK" -le 24 ]; then
            SUBNET="${o1}.${o2}.${o3}.0/${HOST_MASK}"
        else
            SUBNET="${o1}.${o2}.${o3}.0/24"
        fi

        success "Host interface : ${DEFAULT_IFACE}"
        success "Host IP        : ${HOST_IP}"
        success "Detected subnet: ${SUBNET}"
    else
        SUBNET="192.168.2.0/24"
        warn "Tidak bisa detect IP, menggunakan default: ${SUBNET}"
    fi
else
    SUBNET="192.168.2.0/24"
    warn "Tidak bisa detect interface, menggunakan default: ${SUBNET}"
fi

echo ""
info "Subnet yang akan digunakan: ${BOLD}${SUBNET}${NC}"
read -p "  Tekan Enter untuk lanjut, atau ketik subnet manual (contoh: 10.0.0.0/24): " CUSTOM_SUBNET
if [ -n "$CUSTOM_SUBNET" ]; then
    SUBNET="$CUSTOM_SUBNET"
    info "Menggunakan subnet custom: ${SUBNET}"
fi

# ══════════════════════════════════════════════════════════════
# STEP 3: Detect architecture & run container
# ══════════════════════════════════════════════════════════════
step "3/7" "Menjalankan container Proxmox VE"

if [ "${SKIP_CREATE}" != "true" ]; then
    ARCH=$(uname -m)
    if [ "$ARCH" == "aarch64" ] || [ "$ARCH" == "arm64" ]; then
        IMAGE="rtedpro/proxmox:8.4.1-arm64"
        info "Arsitektur ARM64 terdeteksi"
    else
        IMAGE="rtedpro/proxmox:8.4.x"
        info "Arsitektur x86_64 terdeteksi"
    fi

    info "Pulling image ${IMAGE}..."
    docker pull "${IMAGE}"

    info "Starting container ${CONTAINER_NAME}..."
    docker run -itd \
        --name "${CONTAINER_NAME}" \
        --hostname "${HOSTNAME}" \
        -p "${PORT}:8006" \
        --privileged \
        "${IMAGE}"

    success "Container '${CONTAINER_NAME}' berhasil dijalankan!"
else
    # Pastikan container berjalan
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        info "Starting existing container..."
        docker start "${CONTAINER_NAME}"
    fi
    success "Container '${CONTAINER_NAME}' sudah berjalan."
fi

# ══════════════════════════════════════════════════════════════
# STEP 4: Tunggu container siap
# ══════════════════════════════════════════════════════════════
step "4/7" "Menunggu container siap"

info "Menunggu systemd di dalam container aktif..."
MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if docker exec "${CONTAINER_NAME}" systemctl is-system-running &> /dev/null; then
        STATUS=$(docker exec "${CONTAINER_NAME}" systemctl is-system-running 2>/dev/null || true)
        if [ "$STATUS" == "running" ] || [ "$STATUS" == "degraded" ]; then
            break
        fi
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    echo -ne "\r  Menunggu... ${WAITED}s / ${MAX_WAIT}s"
done
echo ""

if [ $WAITED -ge $MAX_WAIT ]; then
    warn "Container belum fully ready, tapi tetap melanjutkan setup..."
else
    success "Container siap! (${WAITED}s)"
fi

# ══════════════════════════════════════════════════════════════
# STEP 5: Setup vmbr0 networking
# ══════════════════════════════════════════════════════════════
step "5/7" "Setup networking (vmbr0)"

# Create docker network if not exists
if docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    warn "Docker network '${NETWORK_NAME}' sudah ada, skip pembuatan."
else
    info "Membuat docker network '${NETWORK_NAME}' (subnet: ${SUBNET})..."
    docker network create \
        --driver bridge \
        --subnet="${SUBNET}" \
        "${NETWORK_NAME}"
    success "Network '${NETWORK_NAME}' berhasil dibuat."
fi

# Connect network to container
if docker network inspect "${NETWORK_NAME}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -q "${CONTAINER_NAME}"; then
    warn "Container sudah terhubung ke network '${NETWORK_NAME}', skip."
else
    info "Menghubungkan container ke network '${NETWORK_NAME}'..."
    docker network connect "${NETWORK_NAME}" "${CONTAINER_NAME}"
    success "Container berhasil terhubung ke network."
fi

# Configure interfaces inside container
info "Mengkonfigurasi network interfaces di dalam container..."
docker exec "${CONTAINER_NAME}" bash -c '
    for i in $(ip -o link show | awk -F": " "{print \$2}" | grep -v lo | sed "s/@.*//"); do
        if ! grep -q "iface $i" /etc/network/interfaces 2>/dev/null; then
            echo -e "auto $i\niface $i inet manual\n" >> /etc/network/interfaces
        fi
    done
'
success "Network interfaces dikonfigurasi."

# ══════════════════════════════════════════════════════════════
# STEP 6: Patch LXCFS untuk support LXC
# ══════════════════════════════════════════════════════════════
step "6/7" "Patch LXCFS untuk LXC support"

info "Patching lxcfs.service (comment ConditionVirtualization)..."
docker exec "${CONTAINER_NAME}" bash -c '
    LXCFS_SERVICE="/lib/systemd/system/lxcfs.service"
    if [ -f "$LXCFS_SERVICE" ]; then
        if grep -q "^ConditionVirtualization" "$LXCFS_SERVICE"; then
            sed -i "s/^ConditionVirtualization/#ConditionVirtualization/" "$LXCFS_SERVICE"
            echo "  ConditionVirtualization berhasil di-comment."
        else
            echo "  ConditionVirtualization sudah di-comment, skip."
        fi
        systemctl daemon-reload
        systemctl restart lxcfs
        echo "  lxcfs service berhasil di-restart."
    else
        echo "  WARN: lxcfs.service tidak ditemukan, skip."
    fi
'
success "LXCFS berhasil di-patch!"

# ══════════════════════════════════════════════════════════════
# STEP 7: Install LXC Auto-Watcher (background daemon)
# ══════════════════════════════════════════════════════════════
step "7/7" "Install LXC Auto-Watcher"

info "Membuat LXC auto-watcher daemon di dalam container..."

# Buat script watcher
docker exec "${CONTAINER_NAME}" bash -c 'cat > /usr/local/bin/lxc-auto-watcher << '\''WATCHER'\''
#!/bin/bash
# ──────────────────────────────────────────────────────
# LXC Auto-Watcher Daemon
# Otomatis detect LXC baru, fix apparmor, dan start.
# Berjalan sebagai background service.
# ──────────────────────────────────────────────────────

LOG="/var/log/lxc-auto-watcher.log"
MARKER_DIR="/var/lib/lxc/.autowatcher"
SCAN_INTERVAL=5  # detik

mkdir -p "$MARKER_DIR"

log() {
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG"
}

setup_container() {
    local CTID="$1"
    local CONFIG="/var/lib/lxc/${CTID}/config"

    if [ ! -f "$CONFIG" ]; then
        return
    fi

    log "══ Detected new LXC: CT $CTID ══"

    # Remove semua baris apparmor yang ada
    log "  [1/3] Removing apparmor lines from config..."
    sed -i "/apparmor/d" "$CONFIG"

    # Tambah unconfined profile
    log "  [2/3] Adding lxc.apparmor.profile=unconfined..."
    echo "lxc.apparmor.profile=unconfined" >> "$CONFIG"

    # Start container
    log "  [3/3] Starting LXC container $CTID..."
    if lxc-start -n "$CTID" 2>>"$LOG"; then
        log "  ✓ CT $CTID berhasil di-start!"
    else
        log "  ✗ CT $CTID gagal start. Cek log: $LOG"
    fi

    # Tandai sudah di-setup
    touch "${MARKER_DIR}/${CTID}.done"
}

log "════════════════════════════════════════"
log "LXC Auto-Watcher started!"
log "Scanning setiap ${SCAN_INTERVAL}s untuk LXC baru..."
log "════════════════════════════════════════"

while true; do
    # Scan semua directory di /var/lib/lxc/
    if [ -d "/var/lib/lxc" ]; then
        for ct_dir in /var/lib/lxc/*/; do
            [ -d "$ct_dir" ] || continue

            CTID=$(basename "$ct_dir")

            # Skip directory khusus dan marker dir
            [[ "$CTID" == ".autowatcher" ]] && continue
            [[ "$CTID" == "lxc-monitord" ]] && continue
            [[ "$CTID" == "*" ]] && continue

            # Skip jika sudah pernah di-setup
            [ -f "${MARKER_DIR}/${CTID}.done" ] && continue

            # Skip jika belum ada config (masih proses create)
            [ -f "${ct_dir}/config" ] || continue

            # Cek apakah sudah ada apparmor unconfined
            if grep -q "^lxc.apparmor.profile=unconfined" "${ct_dir}/config" 2>/dev/null; then
                # Sudah benar, tandai saja
                touch "${MARKER_DIR}/${CTID}.done"
                continue
            fi

            # Container baru ditemukan! Setup otomatis
            setup_container "$CTID"
        done
    fi

    sleep "$SCAN_INTERVAL"
done
WATCHER'

docker exec "${CONTAINER_NAME}" chmod +x /usr/local/bin/lxc-auto-watcher

# Buat systemd service untuk auto-watcher
docker exec "${CONTAINER_NAME}" bash -c 'cat > /etc/systemd/system/lxc-auto-watcher.service << '\''SERVICE'\''
[Unit]
Description=LXC Auto-Watcher - Auto detect and setup new LXC containers
After=lxcfs.service pvedaemon.service

[Service]
Type=simple
ExecStart=/usr/local/bin/lxc-auto-watcher
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE'

# Enable dan start service
docker exec "${CONTAINER_NAME}" systemctl daemon-reload
docker exec "${CONTAINER_NAME}" systemctl enable lxc-auto-watcher.service
docker exec "${CONTAINER_NAME}" systemctl start lxc-auto-watcher.service

success "LXC Auto-Watcher service berhasil diinstall dan berjalan!"
info "Watcher akan otomatis scan LXC baru setiap 5 detik."
info "Log watcher: /var/log/lxc-auto-watcher.log"

# Buat juga helper manual (tetap berguna)
docker exec "${CONTAINER_NAME}" bash -c 'cat > /usr/local/bin/lxc-setup << '\''SCRIPT'\''
#!/bin/bash
# ──────────────────────────────────────────────
# LXC Container Manual Setup & Start
# Usage: lxc-setup <CT_ID>
# Untuk setup manual jika tidak mau menunggu auto-watcher
# ──────────────────────────────────────────────

if [ -z "$1" ]; then
    echo "Usage: lxc-setup <CT_ID>"
    echo "Example: lxc-setup 100"
    echo ""
    echo "NOTE: Auto-watcher sudah berjalan di background!"
    echo "      Container baru akan otomatis di-setup."
    echo "      Gunakan script ini hanya jika ingin manual."
    exit 1
fi

CTID="$1"
CONFIG="/var/lib/lxc/${CTID}/config"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Config file tidak ditemukan: $CONFIG"
    echo "Pastikan container CT $CTID sudah dibuat di Proxmox UI."
    exit 1
fi

echo "═══ Setting up LXC container $CTID ═══"

# Remove apparmor lines
echo "[1/3] Menghapus baris apparmor dari config..."
sed -i "/apparmor/d" "$CONFIG"

# Add unconfined profile
echo "[2/3] Menambahkan lxc.apparmor.profile=unconfined..."
if ! grep -q "lxc.apparmor.profile=unconfined" "$CONFIG"; then
    echo "lxc.apparmor.profile=unconfined" >> "$CONFIG"
fi

# Start container
echo "[3/3] Starting LXC container $CTID..."
lxc-start -n "$CTID"

if [ $? -eq 0 ]; then
    # Mark as done for auto-watcher
    mkdir -p /var/lib/lxc/.autowatcher
    touch "/var/lib/lxc/.autowatcher/${CTID}.done"
    echo ""
    echo "✓ Container $CTID berhasil di-start!"
    echo "  Akses via: pct enter $CTID"
else
    echo ""
    echo "✗ Gagal start container $CTID."
    echo "  Coba jalankan manual: lxc-start -n $CTID"
fi
SCRIPT'

docker exec "${CONTAINER_NAME}" chmod +x /usr/local/bin/lxc-setup

# ══════════════════════════════════════════════════════════════
# SELESAI!
# ══════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║          ✅ SETUP SELESAI!                       ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}📌 Informasi Login Proxmox VE:${NC}"
echo -e "   URL      : ${CYAN}https://localhost:${PORT}${NC}"
echo -e "   Username : ${BOLD}root${NC}"
echo -e "   Password : ${BOLD}root${NC}"
echo ""
echo -e "${BOLD}📌 Subnet yang digunakan:${NC} ${CYAN}${SUBNET}${NC}"
echo ""
echo -e "${BOLD}📌 Langkah selanjutnya (vmbr0 bridge - sekali saja):${NC}"
echo -e "   ${YELLOW}1. Buka Proxmox UI → Node → Network${NC}"
echo -e "   ${YELLOW}2. Buat Linux Bridge baru (vmbr0)${NC}"
echo -e "   ${YELLOW}3. Bridge port: eth1${NC}"
echo -e "   ${YELLOW}4. Apply Configuration${NC}"
echo -e "   ${YELLOW}5. Jika perlu, restart container:${NC}"
echo -e "      ${BOLD}docker restart ${CONTAINER_NAME}${NC}"
echo ""
echo -e "${BOLD}📌 LXC - Fully Automatic! 🤖${NC}"
echo -e "   ${GREEN}Auto-watcher sudah aktif di background.${NC}"
echo -e "   ${GREEN}Tinggal buat LXC container di Proxmox UI,${NC}"
echo -e "   ${GREEN}otomatis akan di-setup dan di-start!${NC}"
echo ""
echo -e "   ${YELLOW}Cek status watcher:${NC}"
echo -e "      ${BOLD}docker exec ${CONTAINER_NAME} systemctl status lxc-auto-watcher${NC}"
echo -e "   ${YELLOW}Lihat log watcher:${NC}"
echo -e "      ${BOLD}docker exec ${CONTAINER_NAME} cat /var/log/lxc-auto-watcher.log${NC}"
echo -e "   ${YELLOW}Manual setup (optional):${NC}"
echo -e "      ${BOLD}docker exec ${CONTAINER_NAME} lxc-setup <CT_ID>${NC}"
echo ""
echo -e "${CYAN}Selamat menggunakan Dockermox! 🐳${NC}"
