#!/bin/bash
# ============================================================================
# PROXMOX VE DOCKER - ULTIMATE AUTO DEPLOY SCRIPT
# ============================================================================
# Features:
# - Custom version support via argument
# - Auto network configuration (vmbr0)
# - Silent install with progress bar
# - Beautiful UI with colors and animations
# - Complete LXC support
# - Auto-watch service
# ============================================================================

VERSION="2.0"
SCRIPT_NAME="proxmox-deploy.sh"

# Default configuration
CONTAINER_NAME="proxmoxve"
HOSTNAME="pve"
PORT="8006"
DEFAULT_VERSION="9.1.4"
IMAGE_BASE="rtedpro/proxmox"

# Parse version from argument
PROXMOX_VERSION="${1:-$DEFAULT_VERSION}"
IMAGE="${IMAGE_BASE}:${PROXMOX_VERSION}"

# Colors and styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Symbols
CHECK="${GREEN}✓${NC}"
CROSS="${RED}✗${NC}"
ARROW="${CYAN}➜${NC}"
WARN="${YELLOW}⚠${NC}"
INFO="${BLUE}ℹ${NC}"
ROCKET="${MAGENTA}🚀${NC}"
GEAR="${CYAN}⚙${NC}"
PACKAGE="${YELLOW}📦${NC}"
NETWORK="${BLUE}🌐${NC}"
SHIELD="${GREEN}🛡${NC}"

# Progress tracking
TOTAL_STEPS=13
CURRENT_STEP=0

# Log file
LOG_FILE="/tmp/proxmox-deploy-$(date +%Y%m%d-%H%M%S).log"

# ============================================================================
# UI FUNCTIONS
# ============================================================================

clear_line() {
    echo -ne "\033[2K\r"
}

print_banner() {
    clear
    echo -e "${BOLD}${GREEN}[ PROXMOX DOCKER ]${NC}"
    echo -e "${DIM}v2.0 | Auto Setup Configuration${NC}"
    echo ""
}

print_info_box() {
    local title="$1"
    local content="$2"

    echo -e "${BOLD}${BLUE}────────────────────────────${NC}"
    echo -e "${BOLD}${WHITE} $title ${NC}"
    echo -e "${BOLD}${BLUE}────────────────────────────${NC}"
    echo -e "$content"
    echo -e "${BOLD}${BLUE}────────────────────────────${NC}"
    echo ""
}

progress_bar() {
    local current=$1
    local total=$2
    local message="$3"
    
    # Hitung persentase
    local percent=$((current * 100 / total))
    # Skala 25 kotak supaya tidak kepanjangan di layar HP/Terminal kecil
    local filled=$((percent / 4))
    local empty=$((25 - filled))
    
    # Gunakan looping atau printf dengan default value untuk cegah error 0
    local bar_filled=$(printf "%${filled}s" | tr ' ' '█')
    local bar_empty=$(printf "%${empty}s" | tr ' ' '░')
    
    # Cetak ke satu baris (\r untuk return ke awal baris tanpa clear layar terus-menerus)
    printf "\r${BOLD}${CYAN}[%-s%-s] %d%%${NC} %s" "$bar_filled" "$bar_empty" "$percent" "$message"
}


step_start() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local message="$1"
    echo "" >> "$LOG_FILE"
    echo "=== STEP $CURRENT_STEP: $message ===" >> "$LOG_FILE"
    progress_bar $CURRENT_STEP $TOTAL_STEPS "$message"
}

step_success() {
    local message="$1"
    clear_line
    echo -e "${CHECK} ${GREEN}${message}${NC}"
}

step_error() {
    local message="$1"
    clear_line
    echo -e "${CROSS} ${RED}${message}${NC}"
}

step_info() {
    local message="$1"
    echo -e "${DIM}  ${INFO} ${message}${NC}"
}

spinner() {
    local pid=$1
    local message="$2"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(((i + 1) % 10))
        clear_line
        echo -ne "${CYAN}${spin:$i:1}${NC} ${message}"
        sleep 0.1
    done
    clear_line
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

fix_inotify_limits() {
    step_start "Checking inotify limits"
    
    local current_events=$(sysctl -n fs.inotify.max_queued_events 2>/dev/null || echo 0)
    local current_instances=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
    local current_watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)
    
    local required_value=1048576
    local needs_fix=0
    
    if [ "$current_events" -lt "$required_value" ] || \
       [ "$current_instances" -lt "$required_value" ] || \
       [ "$current_watches" -lt "$required_value" ]; then
        needs_fix=1
    fi
    
    if [ $needs_fix -eq 1 ]; then
        echo ""
        echo -e "${WARN} ${YELLOW}Inotify limits too low (systemd requirement)${NC}"
        echo -e "${INFO} Current values:"
        echo -e "  ${DIM}max_queued_events  : ${current_events}${NC}"
        echo -e "  ${DIM}max_user_instances : ${current_instances}${NC}"
        echo -e "  ${DIM}max_user_watches   : ${current_watches}${NC}"
        echo ""
        echo -e "${INFO} ${BOLD}Fixing inotify limits...${NC}"
        
        # Try to fix automatically
        if [ "$EUID" -eq 0 ]; then
            # Running as root, can fix directly
            sysctl -w fs.inotify.max_queued_events=$required_value &>/dev/null
            sysctl -w fs.inotify.max_user_instances=$required_value &>/dev/null
            sysctl -w fs.inotify.max_user_watches=$required_value &>/dev/null
            
            # Make permanent
            if ! grep -q "fs.inotify.max_queued_events" /etc/sysctl.conf 2>/dev/null; then
                cat >> /etc/sysctl.conf << EOF

# Inotify limits for Proxmox/systemd containers
fs.inotify.max_queued_events=$required_value
fs.inotify.max_user_instances=$required_value
fs.inotify.max_user_watches=$required_value
EOF
            fi
            
            sysctl -p &>/dev/null
            step_success "Inotify limits fixed automatically"
        else
            # Not root, need sudo
            echo -e "${INFO} Root access required to fix inotify limits"
            echo ""
            
            if command -v sudo &>/dev/null; then
                echo -e "${ARROW} Attempting to fix with sudo..."
                
                sudo sysctl -w fs.inotify.max_queued_events=$required_value
                sudo sysctl -w fs.inotify.max_user_instances=$required_value
                sudo sysctl -w fs.inotify.max_user_watches=$required_value
                
                # Make permanent
                if ! sudo grep -q "fs.inotify.max_queued_events" /etc/sysctl.conf 2>/dev/null; then
                    echo "" | sudo tee -a /etc/sysctl.conf >/dev/null
                    echo "# Inotify limits for Proxmox/systemd containers" | sudo tee -a /etc/sysctl.conf >/dev/null
                    echo "fs.inotify.max_queued_events=$required_value" | sudo tee -a /etc/sysctl.conf >/dev/null
                    echo "fs.inotify.max_user_instances=$required_value" | sudo tee -a /etc/sysctl.conf >/dev/null
                    echo "fs.inotify.max_user_watches=$required_value" | sudo tee -a /etc/sysctl.conf >/dev/null
                fi
                
                sudo sysctl -p &>/dev/null
                
                if [ $? -eq 0 ]; then
                    step_success "Inotify limits fixed with sudo"
                else
                    step_error "Failed to fix inotify limits"
                    echo ""
                    echo -e "${INFO} Please run manually:"
                    echo -e "${DIM}  sudo sysctl -w fs.inotify.max_queued_events=$required_value${NC}"
                    echo -e "${DIM}  sudo sysctl -w fs.inotify.max_user_instances=$required_value${NC}"
                    echo -e "${DIM}  sudo sysctl -w fs.inotify.max_user_watches=$required_value${NC}"
                    exit 1
                fi
            else
                step_error "sudo not available and not running as root"
                echo ""
                echo -e "${INFO} Please run as root or install sudo, then run:"
                echo -e "${DIM}  sysctl -w fs.inotify.max_queued_events=$required_value${NC}"
                echo -e "${DIM}  sysctl -w fs.inotify.max_user_instances=$required_value${NC}"
                echo -e "${DIM}  sysctl -w fs.inotify.max_user_watches=$required_value${NC}"
                exit 1
            fi
        fi
        
        step_info "New values: $required_value (persistent)"
    else
        step_success "Inotify limits OK"
        step_info "Values: $current_events / $current_instances / $current_watches"
    fi
}

check_requirements() {
    step_start "Checking requirements"
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        step_error "Docker not installed"
        echo -e "${CROSS} Please install Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    # Check Docker daemon
    if ! docker ps &> /dev/null; then
        step_error "Docker daemon not running"
        exit 1
    fi
    
    # Check port availability
    if netstat -tuln 2>/dev/null | grep -q ":${PORT} " || ss -tuln 2>/dev/null | grep -q ":${PORT} "; then
        step_error "Port ${PORT} already in use"
        exit 1
    fi
    
    step_success "Requirements check passed"
    step_info "Docker version: $(docker --version | cut -d' ' -f3 | tr -d ',')"
    step_info "Port ${PORT} available"
}

check_existing_container() {
    step_start "Checking existing container"
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo ""
        echo -e "${WARN} ${YELLOW}Container '${CONTAINER_NAME}' already exists${NC}"
        echo ""
        read -p "  Remove and recreate? [y/N]: " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker stop ${CONTAINER_NAME} &>/dev/null
            docker rm ${CONTAINER_NAME} &>/dev/null
            step_success "Removed existing container"
        else
            step_error "Deployment cancelled"
            exit 1
        fi
    else
        step_success "No container conflict"
    fi
}

# ============================================================================
# DEPLOYMENT FUNCTIONS
# ============================================================================

deploy_container() {
    step_start "Deploying Proxmox VE ${PROXMOX_VERSION}"
    
    {
        docker run -itd \
            --name ${CONTAINER_NAME} \
            --hostname ${HOSTNAME} \
            -p ${PORT}:8006 \
            --privileged \
            --cap-add=NET_ADMIN \
            --cap-add=SYS_ADMIN \
            --device=/dev/net/tun \
            ${IMAGE} &>> "$LOG_FILE"
    } &
    
    spinner $! "Pulling image and creating container..."
    wait $!
    
    if [ $? -eq 0 ]; then
        step_success "Container deployed successfully"
        step_info "Image: ${IMAGE}"
        step_info "Name: ${CONTAINER_NAME}"
    else
        step_error "Failed to deploy container"
        echo -e "${INFO} Check log: ${LOG_FILE}"
        exit 1
    fi
    
    # Wait for container to be ready
    sleep 3
}

configure_network() {
    step_start "Configuring network (vmbr0)"
    
    docker exec ${CONTAINER_NAME} bash -c '
        # Create network bridge vmbr0
        cat > /etc/network/interfaces.d/vmbr0 << EOF
auto vmbr0
iface vmbr0 inet static
    address 10.10.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE
EOF

        # Restart networking
        systemctl restart networking 2>/dev/null || ifup vmbr0 2>/dev/null
        
        # Enable IP forwarding permanently
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
        
        # Configure NAT
        iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE 2>/dev/null
        
        # Install iptables-persistent to save rules
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1 > /dev/null
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        apt-get install -y -qq iptables-persistent 2>&1 > /dev/null
        
        echo "✓ Network configured"
    ' &>> "$LOG_FILE"
    
    step_success "Network bridge vmbr0 configured"
    step_info "Bridge IP: 10.10.10.1/24"
    step_info "NAT enabled for LXC containers"
}

disable_subscription() {
    step_start "Disabling subscription notice"
    
    docker exec ${CONTAINER_NAME} bash -c '
        # Backup and patch proxmoxlib.js
        if [ -f /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ]; then
            cp /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js \
               /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.bak
            
            sed -i.bak "s/data.status !== '\''Active'\''/false/g" \
                /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
        fi
        
        # Alternative path for different versions
        if [ -f /usr/share/pve-manager/js/pvemanagerlib.js ]; then
            sed -i.bak "s/data.status !== '\''Active'\''/false/g" \
                /usr/share/pve-manager/js/pvemanagerlib.js 2>/dev/null
        fi
        
        echo "✓ Subscription disabled"
    ' &>> "$LOG_FILE"
    
    step_success "Subscription notice disabled"
}

update_system() {
    step_start "Updating system packages"
    
    docker exec ${CONTAINER_NAME} bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1 > /dev/null
        apt-get upgrade -y -qq 2>&1 > /dev/null
        echo "✓ System updated"
    ' &>> "$LOG_FILE"
    
    step_success "System packages updated"
}

install_dependencies() {
    step_start "Installing dependencies"
    
    docker exec ${CONTAINER_NAME} bash -c '
        export DEBIAN_FRONTEND=noninteractive
        
        # Essential packages
        apt-get install -y -qq \
            curl wget vim nano net-tools iputils-ping dnsutils \
            htop rsync gnupg ca-certificates software-properties-common \
            bridge-utils vlan ifupdown2 2>&1 > /dev/null
        
        # LXC packages
        apt-get install -y -qq \
            lxc lxcfs lxc-templates debootstrap 2>&1 > /dev/null
        
        # Network tools
        apt-get install -y -qq \
            iptables iptables-persistent iproute2 \
            tcpdump nmap netcat-openbsd 2>&1 > /dev/null
        
        echo "✓ Dependencies installed"
    ' &>> "$LOG_FILE"
    
    step_success "Dependencies installed"
    step_info "LXC, networking, and essential tools ready"
}

setup_lxc_support() {
    step_start "Configuring LXC support"
    
    docker exec ${CONTAINER_NAME} bash -c '
        # Patch LXCFS
        if [ -f /lib/systemd/system/lxcfs.service ]; then
            cp /lib/systemd/system/lxcfs.service /lib/systemd/system/lxcfs.service.bak
            sed -i "s/^ConditionVirtualization/#ConditionVirtualization/" /lib/systemd/system/lxcfs.service
            systemctl daemon-reload
            systemctl restart lxcfs
        fi
        
        # Load kernel modules
        modprobe loop 2>/dev/null || true
        modprobe nf_nat 2>/dev/null || true
        modprobe ip_tables 2>/dev/null || true
        modprobe iptable_nat 2>/dev/null || true
        modprobe overlay 2>/dev/null || true
        
        # Auto-load modules
        cat > /etc/modules-load.d/lxc.conf << EOF
loop
nf_nat
ip_tables
iptable_nat
overlay
EOF
        
        # Configure LXC default config
        mkdir -p /etc/lxc
        cat > /etc/lxc/default.conf << EOF
lxc.net.0.type = veth
lxc.net.0.link = vmbr0
lxc.net.0.flags = up
lxc.apparmor.profile = unconfined
EOF
        
        echo "✓ LXC support configured"
    ' &>> "$LOG_FILE"
    
    step_success "LXC support configured"
    step_info "LXCFS patched and running"
    step_info "Kernel modules loaded"
}

install_lxc_manager() {
    step_start "Installing LXC auto-manager"
    
    docker exec ${CONTAINER_NAME} bash -c 'cat > /usr/local/bin/lxc-manager.sh << '\''EOFSCRIPT'\''
#!/bin/bash
VERSION="2.0"
RED='\''\033[0;31m'\''
GREEN='\''\033[0;32m'\''
YELLOW='\''\033[1;33m'\''
BLUE='\''\033[0;34m'\''
NC='\''\033[0m'\''

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

setup_lxc() {
    local CTID=$1
    if [ -z "$CTID" ]; then
        print_error "CTID tidak diberikan"
        echo "Usage: lxc-manager.sh setup <CTID>"
        exit 1
    fi
    
    local CONFIG_FILE="/var/lib/lxc/${CTID}/config"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Config file tidak ditemukan: $CONFIG_FILE"
        exit 1
    fi
    
    print_info "Setting up container ${CTID}..."
    
    [ ! -f "${CONFIG_FILE}.bak" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    sed -i '\''/apparmor/d'\'' "$CONFIG_FILE"
    
    if ! grep -q "lxc.apparmor.profile=unconfined" "$CONFIG_FILE"; then
        echo "lxc.apparmor.profile=unconfined" >> "$CONFIG_FILE"
    fi
    
    # Ensure network is configured
    if ! grep -q "lxc.net.0.type" "$CONFIG_FILE"; then
        cat >> "$CONFIG_FILE" << EOF

# Network configuration
lxc.net.0.type = veth
lxc.net.0.link = vmbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 00:16:3e:$(openssl rand -hex 3 | sed '\''s/\(..\)/\1:/g; s/:$//'\'' 2>/dev/null || echo "aa:bb:cc")
EOF
    fi
    
    print_info "Starting container ${CTID}..."
    lxc-start -n "$CTID" 2>/dev/null
    
    sleep 2
    
    if lxc-info -n "$CTID" 2>/dev/null | grep -q "RUNNING"; then
        print_success "Container ${CTID} berhasil distart"
        
        # Show IP if available
        local IP=$(lxc-info -n "$CTID" -iH 2>/dev/null | head -1)
        [ -n "$IP" ] && print_info "IP Address: $IP"
    else
        print_error "Container ${CTID} gagal start"
        print_info "Coba: lxc-start -n ${CTID} -F"
    fi
}

auto_watch() {
    local LXC_DIR="/var/lib/lxc"
    local WATCH_FILE="/tmp/lxc-watch-state"
    
    [ ! -f "$WATCH_FILE" ] && touch "$WATCH_FILE"
    
    print_info "Auto-watch mode started"
    print_info "Monitoring for new LXC containers..."
    echo ""
    
    while true; do
        for CTID_DIR in "$LXC_DIR"/*; do
            if [ -d "$CTID_DIR" ]; then
                local CTID=$(basename "$CTID_DIR")
                local CONFIG_FILE="${CTID_DIR}/config"
                
                if [ -f "$CONFIG_FILE" ] && ! grep -q "^${CTID}$" "$WATCH_FILE"; then
                    echo ""
                    print_success "🔍 Detected new LXC: ${CTID}"
                    
                    [ ! -f "${CONFIG_FILE}.bak" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
                    
                    sed -i '\''/apparmor/d'\'' "$CONFIG_FILE"
                    if ! grep -q "lxc.apparmor.profile=unconfined" "$CONFIG_FILE"; then
                        echo "lxc.apparmor.profile=unconfined" >> "$CONFIG_FILE"
                    fi
                    
                    # Add network if missing
                    if ! grep -q "lxc.net.0.type" "$CONFIG_FILE"; then
                        cat >> "$CONFIG_FILE" << EOF

lxc.net.0.type = veth
lxc.net.0.link = vmbr0
lxc.net.0.flags = up
EOF
                    fi
                    
                    print_info "Config updated, starting container..."
                    sleep 2
                    
                    lxc-start -n "$CTID" 2>/dev/null
                    
                    sleep 2
                    
                    if lxc-info -n "$CTID" 2>/dev/null | grep -q "RUNNING"; then
                        print_success "✓ Container ${CTID} started successfully"
                        local IP=$(lxc-info -n "$CTID" -iH 2>/dev/null | head -1)
                        [ -n "$IP" ] && print_info "IP Address: $IP"
                    fi
                    
                    echo "$CTID" >> "$WATCH_FILE"
                    echo ""
                fi
            fi
        done
        sleep 5
    done
}

setup_all_lxc() {
    local LXC_DIR="/var/lib/lxc"
    
    print_info "Setting up all LXC containers..."
    echo ""
    
    local count=0
    for CTID_DIR in "$LXC_DIR"/*; do
        if [ -d "$CTID_DIR" ]; then
            local CTID=$(basename "$CTID_DIR")
            local CONFIG_FILE="${CTID_DIR}/config"
            
            if [ -f "$CONFIG_FILE" ]; then
                count=$((count + 1))
                print_info "Processing: ${CTID}"
                
                [ ! -f "${CONFIG_FILE}.bak" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
                
                sed -i '\''/apparmor/d'\'' "$CONFIG_FILE"
                if ! grep -q "lxc.apparmor.profile=unconfined" "$CONFIG_FILE"; then
                    echo "lxc.apparmor.profile=unconfined" >> "$CONFIG_FILE"
                fi
                
                lxc-start -n "$CTID" 2>/dev/null
                
                if lxc-info -n "$CTID" 2>/dev/null | grep -q "RUNNING"; then
                    print_success "Started: ${CTID}"
                fi
            fi
        fi
    done
    
    echo ""
    if [ $count -eq 0 ]; then
        print_warning "No LXC containers found"
    else
        print_success "Processed $count container(s)"
    fi
}

status_check() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}LXC Container Status${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    lxc-ls -f
    echo ""
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Services Status${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo -n "LXCFS: "
    systemctl is-active lxcfs >/dev/null && print_success "Running" || print_error "Stopped"
    
    echo -n "Auto-watch: "
    systemctl is-active lxc-autowatch >/dev/null && print_success "Running" || print_error "Stopped"
}

case "${1:-}" in
    setup) setup_lxc "$2" ;;
    setup-all) setup_all_lxc ;;
    watch) auto_watch ;;
    status) status_check ;;
    *) 
        echo "LXC Manager v${VERSION}"
        echo ""
        echo "Usage: $0 {setup|setup-all|watch|status} [CTID]"
        echo ""
        echo "Commands:"
        echo "  setup <CTID>  - Setup specific LXC container"
        echo "  setup-all     - Setup all LXC containers"
        echo "  watch         - Auto-watch mode (detect new LXC)"
        echo "  status        - Show status of all containers"
        exit 1
        ;;
esac
EOFSCRIPT
chmod +x /usr/local/bin/lxc-manager.sh
' &>> "$LOG_FILE"
    
    # Create systemd services
    docker exec ${CONTAINER_NAME} bash -c 'cat > /etc/systemd/system/lxc-autostart.service << '\''EOF'\''
[Unit]
Description=Auto Setup and Start LXC Containers on Boot
After=lxcfs.service networking.service
Requires=lxcfs.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lxc-manager.sh setup-all
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/lxc-autowatch.service << '\''EOF'\''
[Unit]
Description=Auto Detect and Setup New LXC Containers
After=lxcfs.service networking.service
Requires=lxcfs.service

[Service]
Type=simple
ExecStart=/usr/local/bin/lxc-manager.sh watch
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable lxc-autostart.service lxc-autowatch.service
systemctl start lxc-autowatch.service
' &>> "$LOG_FILE"
    
    step_success "LXC auto-manager installed"
    step_info "Auto-watch service started"
}

configure_pve_storage() {
    step_start "Configuring Proxmox storage"
    
    docker exec ${CONTAINER_NAME} bash -c '
        # Create storage directories
        mkdir -p /var/lib/vz/{template,images,dump}
        mkdir -p /var/lib/pve
        
        # Set permissions
        chmod 755 /var/lib/vz
        
        echo "✓ Storage configured"
    ' &>> "$LOG_FILE"
    
    step_success "Proxmox storage configured"
}


finalize_setup() {
    step_start "Finalizing setup"

    docker exec "${CONTAINER_NAME}" bash -c "
        set -e

        # Clean up package cache quietly
        apt-get autoremove -y -qq >/dev/null 2>&1 || true
        apt-get clean >/dev/null 2>&1 || true

        # Restart services only if systemctl exists
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart pveproxy 2>/dev/null || true
            systemctl restart pvedaemon 2>/dev/null || true
        fi

        # Add interfaces only if not already present
        for i in \$(ip -o link show | awk -F': ' '{print \$2}' | grep -v lo | sed 's/@.*//'); do
            grep -q \"iface \$i inet\" /etc/network/interfaces || echo -e \"auto \$i\niface \$i inet manual\n\" >> /etc/network/interfaces
        done

        echo \"✓ Setup finalized\"
    " >> \"$LOG_FILE\" 2>&1

    step_success "Setup finalized"
}

# ============================================================================
# FINAL STATUS
# ============================================================================

show_final_status() {

    echo ""
    echo ""
    docker restart proxmoxve
    
    # Get host IP
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$HOST_IP" ] && HOST_IP="localhost"
    
    print_banner
    
    echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║                   DEPLOYMENT SUCCESSFUL! 🎉                       ║${NC}"
    echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Access Information
    print_info_box "🌐 WEB ACCESS" "$(cat <<EOF
URL (Primary) : https://${HOST_IP}:${PORT}
URL (Local)   : https://localhost:${PORT}
Username      : root
Password      : root

${YELLOW}Note: Accept the SSL warning in your browser${NC}
EOF
)"
    
    # Configuration Summary
    print_info_box "⚙️  CONFIGURATION" "$(cat <<EOF
Proxmox Version : ${PROXMOX_VERSION}
Container Name  : ${CONTAINER_NAME}
Hostname        : ${HOSTNAME}
Network Bridge  : vmbr0 (10.10.10.1/24)
NAT Enabled     : Yes (for LXC internet access)
LXC Auto-watch  : Active
EOF
)"
    
    # Features Enabled
    print_info_box "✅ FEATURES ENABLED" "$(cat <<EOF
${CHECK} Subscription notice disabled
${CHECK} System updated & upgraded
${CHECK} Network bridge vmbr0 configured
${CHECK} NAT/Masquerading enabled
${CHECK} LXC support fully configured
${CHECK} Auto-detect new LXC containers
${CHECK} Auto-setup & auto-start LXC
${CHECK} All dependencies installed
EOF
)"
    
    # LXC Information
    print_info_box "🐳 LXC USAGE" "$(cat <<EOF
Creating LXC:
  1. Open Proxmox Web UI
  2. Click 'Create CT'
  3. Choose template & resources
  4. Network: Bridge=vmbr0, Use DHCP
  5. Done! Auto-watch will handle the rest

Manual Commands (if needed):
  Setup LXC    : docker exec ${CONTAINER_NAME} lxc-manager.sh setup <ID>
  Setup All    : docker exec ${CONTAINER_NAME} lxc-manager.sh setup-all
  Check Status : docker exec ${CONTAINER_NAME} lxc-manager.sh status
EOF
)"
    
    # Useful Commands
    print_info_box "📋 USEFUL COMMANDS" "$(cat <<EOF
Container Shell  : docker exec -it ${CONTAINER_NAME} bash
View Logs        : docker logs ${CONTAINER_NAME}
Watch Auto-detect: docker exec ${CONTAINER_NAME} journalctl -u lxc-autowatch -f
Stop Container   : docker stop ${CONTAINER_NAME}
Start Container  : docker start ${CONTAINER_NAME}
Restart Container: docker restart ${CONTAINER_NAME}
EOF
)"
    
    echo -e "${DIM}Deployment log saved to: ${LOG_FILE}${NC}"
    echo ""
    echo -e "${BOLD}${CYAN}Happy Proxmoxing! 🚀${NC}"
    echo ""
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Initial banner
    print_banner
    
    echo -e "${INFO} ${BOLD}Deployment Configuration${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Container    : ${CYAN}${CONTAINER_NAME}${NC}"
    echo -e "  Hostname     : ${CYAN}${HOSTNAME}${NC}"
    echo -e "  Port         : ${CYAN}${PORT}${NC}"
    echo -e "  Version      : ${CYAN}${PROXMOX_VERSION}${NC}"
    echo -e "  Image        : ${CYAN}${IMAGE}${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    read -p "  Continue with deployment? [Y/n]: " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n $REPLY ]]; then
        echo -e "${CROSS} Deployment cancelled"
        exit 0
    fi
    
    echo ""
    echo -e "${INFO} ${BOLD}Starting deployment...${NC}"
    echo ""
    
    # Execute deployment steps
    fix_inotify_limits
    check_requirements
    check_existing_container
    deploy_container
    configure_network
    disable_subscription
    update_system
    install_dependencies
    setup_lxc_support
    install_lxc_manager
    configure_pve_storage
    finalize_setup
    
    # Progress complete
    progress_bar $TOTAL_STEPS $TOTAL_STEPS "Deployment complete!"
    echo ""
    
    # Show final status
    sleep 1
    show_final_status
}

# ============================================================================
# SCRIPT START
# ============================================================================

# Check if running with proper permissions
if [ "$EUID" -eq 0 ]; then 
    echo -e "${WARN} ${YELLOW}Warning: Running as root is not required${NC}"
    echo -e "${INFO} Script will use your current Docker permissions"
    echo ""
fi

# Show usage if --help
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    cat << EOF
${BOLD}Proxmox VE Docker Deployment Script${NC}

${BOLD}USAGE:${NC}
  $0 [VERSION]

${BOLD}ARGUMENTS:${NC}
  VERSION    Proxmox version to deploy (default: ${DEFAULT_VERSION})

${BOLD}EXAMPLES:${NC}
  $0              Deploy Proxmox ${DEFAULT_VERSION}
  $0 9.1.4        Deploy Proxmox 9.1.4
  $0 8.4.1        Deploy Proxmox 8.4.1

${BOLD}FEATURES:${NC}
  ${CHECK} Custom version support
  ${CHECK} Auto network configuration (vmbr0)
  ${CHECK} Silent install with progress bar
  ${CHECK} Complete LXC support
  ${CHECK} Auto-detect & auto-start LXC
  ${CHECK} Beautiful UI

${BOLD}REQUIREMENTS:${NC}
  - Docker installed and running
  - Port ${PORT} available
  - Privileged container support

EOF
    exit 0
fi

# Run main
main

exit 0
