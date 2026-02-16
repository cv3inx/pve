#!/bin/bash
#
# LXC Config Watcher Installer
# Auto-configure LXC containers for nested virtualization with instant reboot detection
#
# Usage:
#   curl -sSL https://your-server.com/install-lxc-watcher.sh | bash
#   or
#   wget -qO- https://your-server.com/install-lxc-watcher.sh | bash
#   or
#   bash install-lxc-watcher.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}  LXC Config Watcher Installer${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   echo "Please run with: sudo bash $0"
   exit 1
fi

# Step 1: Cleanup existing installation
echo -e "${YELLOW}[1/6] Checking for existing installation...${NC}"
if systemctl is-active --quiet lxc-config-watcher.service 2>/dev/null; then
    echo "  → Stopping existing service..."
    systemctl stop lxc-config-watcher.service 2>/dev/null || true
fi

if systemctl is-enabled --quiet lxc-config-watcher.service 2>/dev/null; then
    echo "  → Disabling existing service..."
    systemctl disable lxc-config-watcher.service 2>/dev/null || true
fi

if [[ -f /etc/systemd/system/lxc-config-watcher.service ]] || [[ -f /usr/local/bin/lxc-config-watcher.sh ]]; then
    echo "  → Removing old files..."
    rm -f /etc/systemd/system/lxc-config-watcher.service
    rm -f /usr/local/bin/lxc-config-watcher.sh
    rm -f /tmp/lxc-watcher-processing_*
    systemctl daemon-reload
    echo -e "${GREEN}  ✓ Cleaned up old installation${NC}"
else
    echo "  → No previous installation found"
fi

# Step 2: Install dependencies
echo ""
echo -e "${YELLOW}[2/6] Installing dependencies...${NC}"
if ! command -v inotifywait &> /dev/null; then
    echo "  → Installing inotify-tools..."
    apt-get update -qq
    apt-get install -y inotify-tools
    echo -e "${GREEN}  ✓ inotify-tools installed${NC}"
else
    echo -e "${GREEN}  ✓ inotify-tools already installed${NC}"
fi

# Step 3: Create main watcher script
echo ""
echo -e "${YELLOW}[3/6] Creating watcher script...${NC}"

cat > /usr/local/bin/lxc-config-watcher.sh << 'EOFSCRIPT'
#!/bin/bash
LXC_DIR="/var/lib/lxc"
PROXMOX_CONF_DIR="/etc/pve/lxc"
LOG_FILE="/var/log/lxc-config-watcher.log"
PROCESSING_FLAG="/tmp/lxc-watcher-processing"

log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO) prefix="[INFO] " ;;
        SUCCESS) prefix="[✓] " ;;
        SKIP) prefix="[SKIP] " ;;
        ERROR) prefix="[✗] " ;;
        START) prefix="[▶] " ;;
        REBOOT) prefix="[⟳] " ;;
        SHUTDOWN) prefix="[⏹] " ;;
        NEWCT) prefix="[+] " ;;
        UPDATE) prefix="[↑] " ;;
        *) prefix="[INFO] " ;;
    esac
    echo "${timestamp} ${prefix}${message}" >> "$LOG_FILE"
    echo "${timestamp} ${prefix}${message}"
}

is_processing() {
    local ct_id="$1"
    [[ -f "${PROCESSING_FLAG}_${ct_id}" ]]
}

set_processing() {
    local ct_id="$1"
    touch "${PROCESSING_FLAG}_${ct_id}"
}

clear_processing() {
    local ct_id="$1"
    rm -f "${PROCESSING_FLAG}_${ct_id}"
}

get_container_state() {
    local ct_id="$1"
    lxc-info -n "$ct_id" 2>/dev/null | grep "State:" | awk '{print $2}'
}

is_container_running() {
    local ct_id="$1"
    [[ "$(get_container_state "$ct_id")" == "RUNNING" ]]
}

is_autostart_enabled() {
    local ct_id="$1"
    local pve_conf="${PROXMOX_CONF_DIR}/${ct_id}.conf"
    
    [[ ! -f "$pve_conf" ]] && return 1
    
    if grep -q "^onboot:\s*1" "$pve_conf"; then
        return 0
    else
        return 1
    fi
}

ensure_config() {
    local ct_id="$1"
    local config_file="$LXC_DIR/$ct_id/config"
    
    [[ ! -f "$config_file" ]] && return 1
    
    if ! grep -q "^lxc.apparmor.profile=unconfined" "$config_file"; then
        [[ ! -f "${config_file}.bak.original" ]] && cp "$config_file" "${config_file}.bak.original"
        
        grep -v "apparmor" "$config_file" > "${config_file}.tmp"
        echo "" >> "${config_file}.tmp"
        echo "# Auto-configured for nested containers - $(date '+%Y-%m-%d %H:%M:%S')" >> "${config_file}.tmp"
        echo "lxc.apparmor.profile=unconfined" >> "${config_file}.tmp"
        mv "${config_file}.tmp" "$config_file"
        
        return 0
    fi
    return 1
}

start_container() {
    local ct_id="$1"
    local reason="$2"
    
    if is_processing "$ct_id"; then
        return 0
    fi
    
    set_processing "$ct_id"
    
    if ensure_config "$ct_id"; then
        log_message "SUCCESS" "Config fixed for CT $ct_id"
    fi
    
    if is_container_running "$ct_id"; then
        log_message "SKIP" "CT $ct_id already running"
    else
        log_message "START" "Starting CT $ct_id ($reason)..."
        if lxc-start -n "$ct_id" 2>/dev/null; then
            log_message "SUCCESS" "CT $ct_id started"
        else
            log_message "ERROR" "Failed to start CT $ct_id"
        fi
    fi
    
    sleep 1
    clear_processing "$ct_id"
}

configure_container() {
    local ct_id="$1"
    local config_file="$LXC_DIR/$ct_id/config"
    
    [[ ! -f "$config_file" ]] && return 1
    
    if is_processing "$ct_id"; then
        return 0
    fi
    
    set_processing "$ct_id"
    
    if grep -q "^lxc.apparmor.profile=unconfined" "$config_file"; then
        log_message "SKIP" "CT $ct_id already configured"
        clear_processing "$ct_id"
        return 0
    fi
    
    log_message "INFO" "Configuring CT $ct_id..."
    
    local was_running=false
    if is_container_running "$ct_id"; then
        was_running=true
        log_message "INFO" "Stopping CT $ct_id for configuration..."
        lxc-stop -n "$ct_id" -t 30 2>/dev/null
        sleep 1
    fi
    
    [[ ! -f "${config_file}.bak.original" ]] && cp "$config_file" "${config_file}.bak.original"
    
    grep -v "apparmor" "$config_file" > "${config_file}.tmp"
    echo "" >> "${config_file}.tmp"
    echo "# Auto-configured for nested containers - $(date '+%Y-%m-%d %H:%M:%S')" >> "${config_file}.tmp"
    echo "lxc.apparmor.profile=unconfined" >> "${config_file}.tmp"
    mv "${config_file}.tmp" "$config_file"
    
    log_message "SUCCESS" "CT $ct_id configured"
    
    if $was_running || is_autostart_enabled "$ct_id"; then
        sleep 1
        clear_processing "$ct_id"
        start_container "$ct_id" "after config"
    else
        log_message "INFO" "CT $ct_id auto-start disabled, leaving stopped"
        clear_processing "$ct_id"
    fi
}

handle_container_event() {
    local ct_id="$1"
    local event_type="$2"
    
    if is_processing "$ct_id"; then
        return 0
    fi
    
    local current_state=$(get_container_state "$ct_id")
    
    case "$event_type" in
        "new")
            log_message "NEWCT" "New CT $ct_id detected"
            configure_container "$ct_id"
            ;;
            
        "config_change")
            log_message "INFO" "Config change detected for CT $ct_id"
            
            if [[ "$current_state" == "STOPPED" ]] && is_autostart_enabled "$ct_id"; then
                log_message "REBOOT" "Reboot detected for CT $ct_id (onboot=1, state=stopped)"
                start_container "$ct_id" "reboot"
            else
                configure_container "$ct_id"
            fi
            ;;
            
        "state_change")
            if [[ "$current_state" == "STOPPED" ]] && is_autostart_enabled "$ct_id"; then
                sleep 1
                local new_state=$(get_container_state "$ct_id")
                
                if [[ "$new_state" == "STOPPED" ]]; then
                    log_message "REBOOT" "Instant reboot detected for CT $ct_id (onboot=1)"
                    start_container "$ct_id" "reboot"
                fi
            elif [[ "$current_state" == "STOPPED" ]]; then
                log_message "SHUTDOWN" "CT $ct_id shutdown (onboot=0, respecting user intent)"
            fi
            ;;
    esac
}

monitor_proxmox_configs() {
    if [[ -d "$PROXMOX_CONF_DIR" ]]; then
        inotifywait -m -e create,modify,close_write "$PROXMOX_CONF_DIR" --format '%f %e' 2>/dev/null | while read filename event; do
            if [[ "$filename" =~ ^([0-9]+)\.conf$ ]]; then
                local ct_id="${BASH_REMATCH[1]}"
                
                if [[ "$event" =~ CREATE ]]; then
                    sleep 2
                    handle_container_event "$ct_id" "new"
                elif [[ "$event" =~ MODIFY|CLOSE_WRITE ]]; then
                    handle_container_event "$ct_id" "config_change"
                fi
            fi
        done
    fi
}

monitor_lxc_configs() {
    inotifywait -m -r -e close_write,moved_to "$LXC_DIR" --exclude '(\.tmp$|\.bak\.)' --format '%w%f' 2>/dev/null | while read filepath; do
        if [[ "$filepath" == */config ]] && [[ ! "$filepath" =~ \.bak\. ]]; then
            local ct_id=$(basename $(dirname "$filepath"))
            sleep 0.5
            log_message "INFO" "LXC config change: CT $ct_id"
            configure_container "$ct_id"
        fi
    done
}

monitor_container_states() {
    local -A last_state
    
    while true; do
        for ct_dir in "$LXC_DIR"/*/; do
            if [[ -d "$ct_dir" ]]; then
                local ct_id=$(basename "$ct_dir")
                local current_state=$(get_container_state "$ct_id")
                
                if [[ "${last_state[$ct_id]}" != "$current_state" ]]; then
                    if [[ "${last_state[$ct_id]}" == "RUNNING" ]] && [[ "$current_state" == "STOPPED" ]]; then
                        handle_container_event "$ct_id" "state_change"
                    fi
                    last_state[$ct_id]="$current_state"
                fi
            fi
        done
        sleep 2
    done
}

rm -f ${PROCESSING_FLAG}_* 2>/dev/null

log_message "UPDATE" "========================================="
log_message "UPDATE" "LXC Config Watcher Started (Instant Mode)"
log_message "INFO" "Version: $(date '+%Y.%m.%d-%H%M')"
log_message "INFO" "Monitoring: $LXC_DIR"
log_message "INFO" "Proxmox configs: $PROXMOX_CONF_DIR"
log_message "INFO" "Detection: INSTANT (onboot-based)"
log_message "UPDATE" "========================================="

log_message "INFO" "Scanning existing containers..."
container_count=0
configured_count=0
started_count=0

for ct_dir in "$LXC_DIR"/*/; do
    if [[ -d "$ct_dir" ]]; then
        ct_id=$(basename "$ct_dir")
        config_file="${ct_dir}config"
        
        if [[ -f "$config_file" ]]; then
            ((container_count++))
            
            if ! grep -q "^lxc.apparmor.profile=unconfined" "$config_file"; then
                configure_container "$ct_id"
                ((configured_count++))
            else
                log_message "SKIP" "CT $ct_id already configured"
            fi
            
            current_state=$(get_container_state "$ct_id")
            if [[ "$current_state" == "STOPPED" ]] && is_autostart_enabled "$ct_id"; then
                log_message "INFO" "CT $ct_id has onboot=1 but stopped, starting..."
                start_container "$ct_id" "onboot enabled"
                ((started_count++))
            fi
        fi
    fi
done

log_message "INFO" "Scan complete: $container_count total, $configured_count configured, $started_count started"
log_message "INFO" "Starting instant detection monitors..."

if [[ -d "$PROXMOX_CONF_DIR" ]]; then
    monitor_proxmox_configs &
    PROXMOX_MONITOR_PID=$!
    log_message "INFO" "Proxmox config monitor started (PID: $PROXMOX_MONITOR_PID)"
fi

monitor_lxc_configs &
LXC_MONITOR_PID=$!

monitor_container_states &
STATE_MONITOR_PID=$!

log_message "INFO" "All monitors active - instant detection ready!"

wait $PROXMOX_MONITOR_PID $LXC_MONITOR_PID $STATE_MONITOR_PID
EOFSCRIPT

chmod +x /usr/local/bin/lxc-config-watcher.sh
echo -e "${GREEN}  ✓ Watcher script created${NC}"

# Step 4: Create systemd service
echo ""
echo -e "${YELLOW}[4/6] Creating systemd service...${NC}"

cat > /etc/systemd/system/lxc-config-watcher.service << 'EOFSERVICE'
[Unit]
Description=LXC Config Watcher - Instant Detection Mode
Documentation=man:lxc(7)
After=network.target pve-cluster.service

[Service]
Type=simple
ExecStart=/usr/local/bin/lxc-config-watcher.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=lxc-watcher
KillMode=mixed
TimeoutStopSec=30

ExecStopPost=/bin/bash -c 'rm -f /tmp/lxc-watcher-processing_* 2>/dev/null'

[Install]
WantedBy=multi-user.target
EOFSERVICE

echo -e "${GREEN}  ✓ Systemd service created${NC}"

# Step 5: Enable and start service
echo ""
echo -e "${YELLOW}[5/6] Enabling and starting service...${NC}"

systemctl daemon-reload
systemctl enable lxc-config-watcher.service
systemctl start lxc-config-watcher.service

echo -e "${GREEN}  ✓ Service enabled and started${NC}"

# Step 6: Verify installation
echo ""
echo -e "${YELLOW}[6/6] Verifying installation...${NC}"

sleep 2

if systemctl is-active --quiet lxc-config-watcher.service; then
    echo -e "${GREEN}  ✓ Service is running${NC}"
    SERVICE_STATUS="active"
else
    echo -e "${RED}  ✗ Service failed to start${NC}"
    echo "  Check logs: journalctl -u lxc-config-watcher.service -xe"
    SERVICE_STATUS="failed"
fi

# Final summary
echo ""
echo -e "${BLUE}=========================================${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
echo -e "Service Status: ${GREEN}${SERVICE_STATUS}${NC}"
echo ""
echo -e "${YELLOW}Features:${NC}"
echo "  [⚡] INSTANT reboot detection (no delay!)"
echo "  [+] Auto-detect new containers"
echo "  [✓] Auto-start based on onboot setting"
echo "  [⏹] Respect shutdown (onboot=0)"
echo "  [⟳] Smart reboot handling (onboot=1)"
echo ""
echo -e "${YELLOW}Usage:${NC}"
echo "  View logs:     tail -f /var/log/lxc-config-watcher.log"
echo "  Service logs:  journalctl -u lxc-config-watcher.service -f"
echo "  Status:        systemctl status lxc-config-watcher.service"
echo "  Restart:       systemctl restart lxc-config-watcher.service"
echo "  Stop:          systemctl stop lxc-config-watcher.service"
echo ""
echo -e "${YELLOW}Test it:${NC}"
echo "  • Create new CT with onboot=1 → auto-configures & starts"
echo "  • Reboot CT from Proxmox → instant restart (no delay!)"
echo "  • Shutdown CT → stays stopped (respects your intent)"
echo ""
echo -e "${YELLOW}Update:${NC}"
echo "  Just run this installer again to update!"
echo ""
echo -e "${GREEN}Happy containerizing! 🚀${NC}"
echo ""
