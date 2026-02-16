apt-get update && apt-get install -y inotify-tools && cat > /usr/local/bin/lxc-config-watcher.sh << 'EOFSCRIPT'
#!/bin/bash
LXC_DIR="/var/lib/lxc"
LOG_FILE="/var/log/lxc-config-watcher.log"
PROCESSING_FLAG="/tmp/lxc-watcher-processing"
STATE_CACHE="/tmp/lxc-state-cache"

log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO) prefix="[INFO] " ;;
        SUCCESS) prefix="[✓] " ;;
        SKIP) prefix="[SKIP] " ;;
        ERROR) prefix="[✗] " ;;
        RESTART) prefix="[↻] " ;;
        START) prefix="[▶] " ;;
        REBOOT) prefix="[⟳] " ;;
        *) prefix="[INFO] " ;;
    esac
    echo "${timestamp} ${prefix}${message}" >> "$LOG_FILE"
    echo "${timestamp} ${prefix}${message}"
}

is_processing() {
    local config_file="$1"
    [[ -f "${PROCESSING_FLAG}_$(basename $(dirname "$config_file"))" ]]
}

set_processing() {
    local config_file="$1"
    touch "${PROCESSING_FLAG}_$(basename $(dirname "$config_file"))"
}

clear_processing() {
    local config_file="$1"
    rm -f "${PROCESSING_FLAG}_$(basename $(dirname "$config_file"))"
}

get_container_state() {
    local ct_id="$1"
    lxc-info -n "$ct_id" 2>/dev/null | grep "State:" | awk '{print $2}'
}

is_container_running() {
    local ct_id="$1"
    [[ "$(get_container_state "$ct_id")" == "RUNNING" ]]
}

get_cached_state() {
    local ct_id="$1"
    [[ -f "${STATE_CACHE}_${ct_id}" ]] && cat "${STATE_CACHE}_${ct_id}" || echo "UNKNOWN"
}

set_cached_state() {
    local ct_id="$1"
    local state="$2"
    echo "$state" > "${STATE_CACHE}_${ct_id}"
}

ensure_config() {
    local ct_id="$1"
    local config_file="$LXC_DIR/$ct_id/config"
    
    [[ ! -f "$config_file" ]] && return 1
    
    if ! grep -q "^lxc.apparmor.profile=unconfined" "$config_file"; then
        log_message "INFO" "Fixing config for CT $ct_id..."
        
        # Create backup if doesn't exist
        [[ ! -f "${config_file}.bak.original" ]] && cp "$config_file" "${config_file}.bak.original"
        
        # Fix config
        grep -v "apparmor" "$config_file" > "${config_file}.tmp"
        echo "" >> "${config_file}.tmp"
        echo "# Auto-configured for nested containers - $(date '+%Y-%m-%d %H:%M:%S')" >> "${config_file}.tmp"
        echo "lxc.apparmor.profile=unconfined" >> "${config_file}.tmp"
        mv "${config_file}.tmp" "$config_file"
        
        log_message "SUCCESS" "Config fixed for CT $ct_id"
        return 0
    fi
    return 1
}

start_container() {
    local ct_id="$1"
    local reason="$2"
    
    # Ensure config is correct before starting
    ensure_config "$ct_id"
    
    if is_container_running "$ct_id"; then
        log_message "RESTART" "Restarting CT $ct_id ($reason)..."
        lxc-stop -n "$ct_id" -t 30 2>/dev/null
        sleep 2
        if lxc-start -n "$ct_id" 2>/dev/null; then
            log_message "SUCCESS" "CT $ct_id restarted"
            set_cached_state "$ct_id" "RUNNING"
        else
            log_message "ERROR" "Failed to restart CT $ct_id"
        fi
    else
        log_message "START" "Starting CT $ct_id ($reason)..."
        if lxc-start -n "$ct_id" 2>/dev/null; then
            log_message "SUCCESS" "CT $ct_id started"
            set_cached_state "$ct_id" "RUNNING"
        else
            log_message "ERROR" "Failed to start CT $ct_id"
        fi
    fi
}

configure_container() {
    local config_file="$1"
    local ct_id=$(basename $(dirname "$config_file"))
    
    [[ ! -f "$config_file" ]] && return 1
    
    if is_processing "$config_file"; then
        return 0
    fi
    
    if grep -q "^lxc.apparmor.profile=unconfined" "$config_file"; then
        log_message "SKIP" "CT $ct_id already configured"
        return 0
    fi
    
    set_processing "$config_file"
    
    log_message "INFO" "Configuring CT $ct_id..."
    
    local was_running=false
    is_container_running "$ct_id" && was_running=true
    
    if $was_running; then
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
    
    log_message "SUCCESS" "CT $ct_id configured successfully"
    
    sleep 1
    start_container "$ct_id" "after config"
    
    sleep 2
    clear_processing "$config_file"
}

monitor_container_states() {
    while true; do
        for ct_dir in "$LXC_DIR"/*/; do
            if [[ -d "$ct_dir" ]]; then
                local ct_id=$(basename "$ct_dir")
                local current_state=$(get_container_state "$ct_id")
                local cached_state=$(get_cached_state "$ct_id")
                
                # Detect state changes
                if [[ "$current_state" != "$cached_state" ]] && [[ "$current_state" != "UNKNOWN" ]]; then
                    
                    # Detect reboot attempt (was RUNNING, now STOPPED, will try to start)
                    if [[ "$cached_state" == "RUNNING" ]] && [[ "$current_state" == "STOPPED" ]]; then
                        log_message "REBOOT" "Detected reboot signal for CT $ct_id (Proxmox command)"
                        sleep 2  # Wait for Proxmox to finish its operations
                        
                        # Check if Proxmox is trying to start it
                        local new_state=$(get_container_state "$ct_id")
                        if [[ "$new_state" == "STOPPED" ]]; then
                            # Proxmox reboot detected, auto-start with correct config
                            start_container "$ct_id" "Proxmox reboot"
                        fi
                    fi
                    
                    # Detect manual stop -> start attempts
                    if [[ "$cached_state" == "STOPPED" ]] && [[ "$current_state" == "RUNNING" ]]; then
                        log_message "INFO" "CT $ct_id started externally"
                    fi
                    
                    set_cached_state "$ct_id" "$current_state"
                fi
            fi
        done
        sleep 3  # Check every 3 seconds
    done
}

# Cleanup old flags on start
rm -f ${PROCESSING_FLAG}_* ${STATE_CACHE}_* 2>/dev/null

log_message "INFO" "========================================="
log_message "INFO" "LXC Config Watcher Started"
log_message "INFO" "Monitoring: $LXC_DIR"
log_message "INFO" "Auto-start: ENABLED"
log_message "INFO" "Reboot detection: ENABLED"
log_message "INFO" "========================================="

# Initial scan and state caching
log_message "INFO" "Scanning existing containers..."
container_count=0
configured_count=0
for ct_dir in "$LXC_DIR"/*/; do
    if [[ -d "$ct_dir" ]]; then
        config_file="${ct_dir}config"
        ct_id=$(basename "$ct_dir")
        if [[ -f "$config_file" ]]; then
            ((container_count++))
            configure_container "$config_file" && ((configured_count++))
            
            # Cache initial state
            current_state=$(get_container_state "$ct_id")
            set_cached_state "$ct_id" "$current_state"
        fi
    fi
done
log_message "INFO" "Scan complete: $container_count containers found, $configured_count configured"

# Start state monitor in background
log_message "INFO" "Starting state monitor for reboot detection..."
monitor_container_states &
STATE_MONITOR_PID=$!

log_message "INFO" "Now monitoring for new/modified containers and reboot signals..."

# Watch for config changes
inotifywait -m -r -e close_write,moved_to "$LXC_DIR" --exclude '(\.tmp$|\.bak\.)' --format '%w%f' 2>/dev/null | while read filepath; do
    if [[ "$filepath" == */config ]] && [[ ! "$filepath" =~ \.bak\. ]]; then
        sleep 0.5
        log_message "INFO" "Detected config change: $filepath"
        configure_container "$filepath"
    fi
done

# Cleanup on exit
kill $STATE_MONITOR_PID 2>/dev/null
EOFSCRIPT
chmod +x /usr/local/bin/lxc-config-watcher.sh && cat > /etc/systemd/system/lxc-config-watcher.service << 'EOFSERVICE'
[Unit]
Description=LXC Config Watcher - Auto-configure and handle Proxmox reboots
Documentation=man:lxc(7)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/lxc-config-watcher.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=lxc-watcher
KillMode=mixed
TimeoutStopSec=30

# Cleanup on stop
ExecStopPost=/bin/bash -c 'rm -f /tmp/lxc-watcher-processing_* /tmp/lxc-state-cache_* 2>/dev/null'

[Install]
WantedBy=multi-user.target
EOFSERVICE
systemctl daemon-reload && systemctl restart lxc-config-watcher.service && systemctl enable lxc-config-watcher.service && echo -e "\n✓ Installation complete with Proxmox reboot detection!\n\nFeatures:\n  - Auto-configure new containers\n  - Auto-start after configuration\n  - Detect Proxmox reboot commands\n  - Auto-restart with correct config\n\nView logs:\n  tail -f /var/log/lxc-config-watcher.log\n  journalctl -u lxc-config-watcher.service -f\n\nStatus:\n  systemctl status lxc-config-watcher.service"
