#!/bin/bash
# ============================================================================
# PROXMOX VE DOCKER - AUTO DEPLOY SCRIPT
# ============================================================================
# Quick deploy Proxmox VE in Docker with full LXC support
# Usage: ./proxmox-deploy.sh [version]
# ============================================================================

set -e

VERSION="2.0"
CONTAINER_NAME="proxmoxve"
HOSTNAME="pve"
PORT="8006"
DEFAULT_VERSION="9.1.4"
IMAGE_BASE="rtedpro/proxmox"

PROXMOX_VERSION="${1:-$DEFAULT_VERSION}"
IMAGE="${IMAGE_BASE}:${PROXMOX_VERSION}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Progress
TOTAL_STEPS=13
CURRENT_STEP=0
LOG_FILE="/tmp/proxmox-deploy-$(date +%Y%m%d-%H%M%S).log"

# ============================================================================
# UI FUNCTIONS
# ============================================================================

clear_line() { echo -ne "\033[2K\r"; }

print_header() {
    clear
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}  PROXMOX VE DOCKER DEPLOYMENT${NC}"
    echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

progress_bar() {
    local current=$1 total=$2 message="$3"
    local percent=$((current * 100 / total))
    local filled=$((percent / 4)) empty=$((25 - filled))
    local bar_filled=$(printf "%${filled}s" | tr ' ' '█')
    local bar_empty=$(printf "%${empty}s" | tr ' ' '░')
    printf "\r${BOLD}[%-s%-s] %3d%%${NC} %s" "$bar_filled" "$bar_empty" "$percent" "$message"
}

step_start() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo "=== STEP $CURRENT_STEP: $1 ===" >> "$LOG_FILE"
    progress_bar $CURRENT_STEP $TOTAL_STEPS "$1"
}

step_done() { clear_line; echo -e "${GREEN}✓${NC} ${1}"; }
step_info() { echo -e "${DIM}  ├─ ${1}${NC}"; }
step_error() { clear_line; echo -e "${RED}✗${NC} ${1}"; }

spinner() {
    local pid=$1 message="$2"
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
# SYSTEM CHECK
# ============================================================================

fix_inotify_limits() {
    step_start "Checking system limits"
    
    local current_events=$(sysctl -n fs.inotify.max_queued_events 2>/dev/null || echo 0)
    local required_value=1048576
    
    if [ "$current_events" -lt "$required_value" ]; then
        if [ "$EUID" -eq 0 ]; then
            sysctl -w fs.inotify.max_queued_events=$required_value &>/dev/null
            sysctl -w fs.inotify.max_user_instances=$required_value &>/dev/null
            sysctl -w fs.inotify.max_user_watches=$required_value &>/dev/null
            
            if ! grep -q "fs.inotify.max_queued_events" /etc/sysctl.conf 2>/dev/null; then
                cat >> /etc/sysctl.conf << EOF

# Inotify limits for Proxmox/systemd
fs.inotify.max_queued_events=$required_value
fs.inotify.max_user_instances=$required_value
fs.inotify.max_user_watches=$required_value
EOF
            fi
            sysctl -p &>/dev/null
        else
            sudo sysctl -w fs.inotify.max_queued_events=$required_value &>/dev/null
            sudo sysctl -w fs.inotify.max_user_instances=$required_value &>/dev/null
            sudo sysctl -w fs.inotify.max_user_watches=$required_value &>/dev/null
            
            if ! sudo grep -q "fs.inotify.max_queued_events" /etc/sysctl.conf 2>/dev/null; then
                echo "" | sudo tee -a /etc/sysctl.conf >/dev/null
                echo "# Inotify limits for Proxmox/systemd" | sudo tee -a /etc/sysctl.conf >/dev/null
                echo "fs.inotify.max_queued_events=$required_value" | sudo tee -a /etc/sysctl.conf >/dev/null
                echo "fs.inotify.max_user_instances=$required_value" | sudo tee -a /etc/sysctl.conf >/dev/null
                echo "fs.inotify.max_user_watches=$required_value" | sudo tee -a /etc/sysctl.conf >/dev/null
            fi
            sudo sysctl -p &>/dev/null
        fi
    fi
    
    step_done "System limits configured"
}

check_requirements() {
    step_start "Checking requirements"
    
    if ! command -v docker &> /dev/null; then
        step_error "Docker not found"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        step_error "Docker daemon not running"
        exit 1
    fi
    
    if netstat -tuln 2>/dev/null | grep -q ":${PORT} " || ss -tuln 2>/dev/null | grep -q ":${PORT} "; then
        step_error "Port ${PORT} already in use"
        exit 1
    fi
    
    step_done "Requirements check passed"
    step_info "Docker version: $(docker --version | cut -d' ' -f3 | tr -d ',')"
}

check_existing_container() {
    step_start "Checking existing container"
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo ""
        echo -e "${YELLOW}⚠${NC} Container '${CONTAINER_NAME}' already exists"
        echo ""
        read -p "  Remove and recreate? [y/N]: " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker stop ${CONTAINER_NAME} &>/dev/null
            docker rm ${CONTAINER_NAME} &>/dev/null
            step_done "Removed existing container"
        else
            step_error "Deployment cancelled"
            exit 1
        fi
    else
        step_done "No container conflict"
    fi
}

# ============================================================================
# DEPLOYMENT
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
            -v /var/lib/docker/volumes/pve:/var/lib/pve \
            -v /var/lib/docker/volumes/vz:/var/lib/vz \
            ${IMAGE} &>> "$LOG_FILE"
    } &
    
    spinner $! "Pulling image and creating container..."
    wait $!
    
    if [ $? -eq 0 ]; then
        step_done "Container deployed"
        step_info "Image: ${IMAGE}"
    else
        step_error "Failed to deploy"
        exit 1
    fi
    
    sleep 3
}

configure_network() {
    step_start "Configuring network bridge"
    
    docker exec ${CONTAINER_NAME} bash -c '
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

        systemctl restart networking 2>/dev/null || ifup vmbr0 2>/dev/null
        
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
        
        iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE 2>/dev/null
        
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1 > /dev/null
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        apt-get install -y -qq iptables-persistent 2>&1 > /dev/null
    ' &>> "$LOG_FILE"
    
    step_done "Network bridge configured (vmbr0)"
    step_info "Bridge IP: 10.10.10.1/24"
    step_info "NAT enabled"
}

disable_subscription() {
    step_start "Disabling subscription notice"
    
    docker exec ${CONTAINER_NAME} bash -c '
        if [ -f /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js ]; then
            cp /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js \
               /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js.bak
            
            sed -i.bak "s/data.status !== '\''Active'\''/false/g" \
                /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
        fi
        
        if [ -f /usr/share/pve-manager/js/pvemanagerlib.js ]; then
            sed -i.bak "s/data.status !== '\''Active'\''/false/g" \
                /usr/share/pve-manager/js/pvemanagerlib.js 2>/dev/null
        fi
    ' &>> "$LOG_FILE"
    
    step_done "Subscription notice disabled"
}

update_system() {
    step_start "Updating system packages"
    
    docker exec ${CONTAINER_NAME} bash -c '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1 > /dev/null
        apt-get upgrade -y -qq 2>&1 > /dev/null
    ' &>> "$LOG_FILE"
    
    step_done "System updated"
}

install_dependencies() {
    step_start "Installing dependencies"
    
    docker exec ${CONTAINER_NAME} bash -c '
        export DEBIAN_FRONTEND=noninteractive
        
        apt-get install -y -qq \
            curl wget vim nano whiptail net-tools iputils-ping dnsutils \
            htop rsync gnupg ca-certificates software-properties-common \
            bridge-utils vlan ifupdown2 2>&1 > /dev/null
        
        apt-get install -y -qq \
            lxc lxcfs lxc-templates debootstrap 2>&1 > /dev/null
        
        apt-get install -y -qq \
            iptables iptables-persistent iproute2 \
            tcpdump nmap netcat-openbsd 2>&1 > /dev/null
    ' &>> "$LOG_FILE"
    
    step_done "Dependencies installed"
    step_info "LXC, networking, and tools ready"
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
        
        # LXC default config
        mkdir -p /etc/lxc
        cat > /etc/lxc/default.conf << EOF
lxc.net.0.type = veth
lxc.net.0.link = vmbr0
lxc.net.0.flags = up
lxc.apparmor.profile = unconfined
EOF
    ' &>> "$LOG_FILE"
    
    step_done "LXC support configured"
    step_info "LXCFS patched and running"
    step_info "Kernel modules loaded"
}

install_lxc_manager() {
    step_start "Installing LXC manager"
    
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
        print_error "CTID required"
        echo "Usage: lxc-manager.sh setup <CTID>"
        exit 1
    fi
    
    local CONFIG_FILE="/var/lib/lxc/${CTID}/config"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Config not found: $CONFIG_FILE"
        exit 1
    fi
    
    print_info "Setting up container ${CTID}..."
    
    [ ! -f "${CONFIG_FILE}.bak" ] && cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    sed -i '\''/apparmor/d'\'' "$CONFIG_FILE"
    
    if ! grep -q "lxc.apparmor.profile=unconfined" "$CONFIG_FILE"; then
        echo "lxc.apparmor.profile=unconfined" >> "$CONFIG_FILE"
    fi
    
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
        print_success "Container ${CTID} started"
        local IP=$(lxc-info -n "$CTID" -iH 2>/dev/null | head -1)
        [ -n "$IP" ] && print_info "IP Address: $IP"
    else
        print_error "Container ${CTID} failed to start"
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
                    
                    if ! grep -q "lxc.net.0.type" "$CONFIG_FILE"; then
                        cat >> "$CONFIG_FILE" << EOF

lxc.net.0.type = veth
lxc.net.0.link = vmbr0
lxc.net.0.flags = up
EOF
                    fi
                    
                    print_info "Config updated, starting..."
                    sleep 2
                    
                    lxc-start -n "$CTID" 2>/dev/null
                    sleep 2
                    
                    if lxc-info -n "$CTID" 2>/dev/null | grep -q "RUNNING"; then
                        print_success "✓ Container ${CTID} started"
                        local IP=$(lxc-info -n "$CTID" -iH 2>/dev/null | head -1)
                        [ -n "$IP" ] && print_info "IP: $IP"
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
        echo "  setup <CTID>  - Setup specific LXC"
        echo "  setup-all     - Setup all LXC"
        echo "  watch         - Auto-watch mode"
        echo "  status        - Show status"
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
systemctl enable lxc-autostart.service lxc-autowatch.service >/dev/null 2>&1
systemctl start lxc-autowatch.service >/dev/null 2>&1
' &>> "$LOG_FILE"
    
    step_done "LXC manager installed"
    step_info "Auto-watch service started"
}

configure_pve_storage() {
    step_start "Configuring Proxmox storage"
    
    docker exec ${CONTAINER_NAME} bash -c '
        mkdir -p /var/lib/vz/{template,images,dump}
        mkdir -p /var/lib/pve
        chmod 755 /var/lib/vz
    ' &>> "$LOG_FILE"
    
    step_done "Proxmox storage configured"
}

finalize_setup() {
    step_start "Finalizing setup"
    
    docker exec ${CONTAINER_NAME} bash -c '
        apt-get autoremove -y -qq >/dev/null 2>&1 || true
        apt-get clean >/dev/null 2>&1 || true
        
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart pveproxy 2>/dev/null || true
            systemctl restart pvedaemon 2>/dev/null || true
        fi
        
        for i in $(ip -o link show | awk -F": " "{print \$2}" | grep -v lo | sed "s/@.*//"); do
            grep -q "iface $i inet" /etc/network/interfaces || echo -e "auto $i\niface $i inet manual\n" >> /etc/network/interfaces
        done
    ' &>> "$LOG_FILE"
    
    step_done "Setup finalized"
}

# ============================================================================
# FINAL STATUS
# ============================================================================

show_final_status() {
    echo ""
    docker restart ${CONTAINER_NAME} >/dev/null 2>&1
    
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$HOST_IP" ] && HOST_IP="localhost"
    
    print_header
    
    echo -e "${BOLD}${GREEN}✓ DEPLOYMENT SUCCESSFUL${NC}"
    echo ""
    
    echo -e "${BOLD}WEB ACCESS${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  URL      : ${CYAN}https://${HOST_IP}:${PORT}${NC}"
    echo -e "  Username : ${CYAN}root${NC}"
    echo -e "  Password : ${CYAN}root${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -e "${BOLD}CONFIGURATION${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Version        : ${CYAN}${PROXMOX_VERSION}${NC}"
    echo -e "  Container      : ${CYAN}${CONTAINER_NAME}${NC}"
    echo -e "  Network Bridge : ${CYAN}vmbr0 (10.10.10.1/24)${NC}"
    echo -e "  NAT Enabled    : ${GREEN}Yes${NC}"
    echo -e "  LXC Auto-watch : ${GREEN}Active${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -e "${BOLD}LXC USAGE${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  1. Open Web UI → Create CT"
    echo -e "  2. Network: Bridge=vmbr0, Use DHCP"
    echo -e "  3. Auto-watch will configure automatically"
    echo ""
    echo -e "  Manual commands:"
    echo -e "  ${DIM}docker exec ${CONTAINER_NAME} lxc-manager.sh setup <ID>${NC}"
    echo -e "  ${DIM}docker exec ${CONTAINER_NAME} lxc-manager.sh status${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -e "${BOLD}USEFUL COMMANDS${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Shell    : ${CYAN}docker exec -it ${CONTAINER_NAME} bash${NC}"
    echo -e "  Logs     : ${CYAN}docker logs ${CONTAINER_NAME}${NC}"
    echo -e "  Restart  : ${CYAN}docker restart ${CONTAINER_NAME}${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -e "${DIM}Log: ${LOG_FILE}${NC}"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    print_header
    
    echo -e "${BOLD}DEPLOYMENT INFO${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Container : ${CYAN}${CONTAINER_NAME}${NC}"
    echo -e "  Version   : ${CYAN}${PROXMOX_VERSION}${NC}"
    echo -e "  Port      : ${CYAN}${PORT}${NC}"
    echo -e "  Image     : ${CYAN}${IMAGE}${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    read -p "Continue? [Y/n]: " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n $REPLY ]]; then
        echo -e "${RED}✗${NC} Cancelled"
        exit 0
    fi
    
    echo ""
    
    # Execute deployment
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
    
    progress_bar $TOTAL_STEPS $TOTAL_STEPS "Complete!"
    echo ""
    
    sleep 1
    show_final_status
}

# ============================================================================
# HELP
# ============================================================================

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    cat << EOF
${BOLD}Proxmox VE Docker Deployment Script${NC}

${BOLD}USAGE:${NC}
  $0 [VERSION]

${BOLD}EXAMPLES:${NC}
  $0              # Deploy Proxmox ${DEFAULT_VERSION}
  $0 9.1.4        # Deploy specific version

${BOLD}FEATURES:${NC}
  • Custom version support
  • Auto network configuration (vmbr0)
  • Complete LXC support with auto-watch
  • LXCFS patching for nested containers
  • Kernel modules auto-loading
  • NAT/Masquerading for internet access
  • iptables-persistent for rules persistence
  • Subscription notice disabled

${BOLD}REQUIREMENTS:${NC}
  • Docker installed and running
  • Port ${PORT} available
  • Root/sudo access for inotify limits

${BOLD}LXC FEATURES:${NC}
  • Auto-detect new LXC containers
  • Auto-configure networking
  • Auto-start containers
  • Full nested container support

EOF
    exit 0
fi

# Run
main
exit 0
