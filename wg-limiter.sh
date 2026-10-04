#!/usr/bin/env bash
# ==============================================================================
# XManager - WireGuard Dynamic Bandwidth Limiter for 3x-ui (NFTables L4 Meter)
# ==============================================================================
# Description:
#   High-performance, kernel-space bandwidth limiter for WireGuard inbounds
#   running in 3x-ui / Xray. Implements stateful per-port token bucket meters
#   in NFTables without user-space overhead or packet inspection latency.
#
# Author: XManager Project
# License: MIT
# Note: 100% English only in all code, comments, strings, menus, and logs.
# ==============================================================================

set -e

# --- Configuration & Paths ---
CONF_DIR="/etc/wg-limiter"
CONF_FILE="${CONF_DIR}/wg-limiter.conf"
LOG_FILE="/var/log/wg-limiter.log"
INSTALL_BIN="/usr/local/bin/wg-limiter"
SYSTEMD_SERVICE="/etc/systemd/system/wg-limiter.service"
SYSTEMD_SYNC_SERVICE="/etc/systemd/system/wg-limiter-sync.service"
SYSTEMD_SYNC_TIMER="/etc/systemd/system/wg-limiter-sync.timer"

TABLE_NAME="wg_limiter"
TABLE_FAMILY="inet"
SET_NAME="wg_ports"

# --- ANSI Color Palette ---
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Messaging Helpers ---
msg_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
msg_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
msg_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Logging Helper with Auto-Rotation ---
log_event() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Truncate if log exceeds 5000 lines (keep last 2000 lines)
    if [ -f "$LOG_FILE" ]; then
        local line_count
        line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$line_count" -gt 5000 ]; then
            tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

# --- Root Privilege Check ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        msg_err "This script must be executed as root."
        exit 1
    fi
}

# --- Auto Detect WAN Network Interface ---
detect_wan_interface() {
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+')
    if [ -z "$iface" ]; then
        iface=$(ip -brief link show | awk '$2=="UP" && $1!="lo" && $1!~/@/ {print $1; exit}')
    fi
    echo "${iface:-ens161}"
}

# --- Auto Detect 3x-ui SQLite Database Location ---
detect_db_path() {
    local candidates=(
        "/etc/x-ui/x-ui.db"
        "/usr/local/x-ui/bin/x-ui.db"
        "/etc/x-ui-english/x-ui.db"
    )
    for path in "${candidates[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return
        fi
    done
    echo "/etc/x-ui/x-ui.db"
}

# --- Load Configuration ---
load_config() {
    mkdir -p "$CONF_DIR"
    if [ -f "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    else
        WAN_IF=$(detect_wan_interface)
        DB_PATH=$(detect_db_path)
        DL_MBIT=16
        UL_MBIT=16
        BURST_KB=256
        SYNC_INTERVAL=10
        save_config
    fi
}

# --- Save Configuration ---
save_config() {
    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" <<EOF
# WireGuard Bandwidth Limiter Configuration
WAN_IF="${WAN_IF}"
DB_PATH="${DB_PATH}"
DL_MBIT=${DL_MBIT}
UL_MBIT=${UL_MBIT}
BURST_KB=${BURST_KB}
SYNC_INTERVAL=${SYNC_INTERVAL}
EOF
}

# --- Ensure Required Dependencies ---
ensure_dependencies() {
    local needed=()
    command -v nft >/dev/null 2>&1 || needed+=("nftables")
    command -v sqlite3 >/dev/null 2>&1 || needed+=("sqlite3")
    command -v ip >/dev/null 2>&1 || needed+=("iproute2")

    if [ ${#needed[@]} -gt 0 ]; then
        msg_info "Installing required packages: ${needed[*]}..."
        apt-get update -qq
        apt-get install -y -qq "${needed[@]}"
        msg_ok "Required packages installed successfully."
    fi
}

# --- Check If Limiter Table Is Active in NFTables ---
is_limiter_active() {
    if nft list table ${TABLE_FAMILY} ${TABLE_NAME} >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# --- Query Active WireGuard Ports From 3x-ui DB ---
get_active_db_ports() {
    if [ ! -f "$DB_PATH" ]; then
        echo ""
        return
    fi

    local raw_ports=""
    # First attempt: timeout mode to wait if locked
    raw_ports=$(sqlite3 -cmd ".timeout 5000" "$DB_PATH" "SELECT port FROM inbounds WHERE protocol='wireguard' AND enable=1;" 2>/dev/null || true)

    # Fallback attempt: immutable mode
    if [ -z "$raw_ports" ]; then
        raw_ports=$(sqlite3 "file:${DB_PATH}?immutable=1" "SELECT port FROM inbounds WHERE protocol='wireguard' AND enable=1;" 2>/dev/null || true)
    fi

    # Strict port validation: digits only, range 1 - 65535
    echo "$raw_ports" | tr -d '\r' | grep -E '^[0-9]+$' | awk '$1>=1 && $1<=65535' | sort -u
}

# --- Get Ports Currently Active In NFTables Set ---
get_active_nft_ports() {
    if ! is_limiter_active; then
        echo ""
        return
    fi

    nft list set ${TABLE_FAMILY} ${TABLE_NAME} ${SET_NAME} 2>/dev/null | \
        sed -n '/elements = {/,/}/p' | \
        grep -oE '\b[0-9]{1,5}\b' | \
        awk '$1>=1 && $1<=65535' | \
        sort -u || true
}

# --- Initialize or Rebuild NFTables Rules ---
apply_nft_rules() {
    load_config

    # Validate numeric parameters
    if [[ ! "$DL_MBIT" =~ ^[0-9]+$ ]] || [ "$DL_MBIT" -le 0 ]; then
        DL_MBIT=16
    fi
    if [[ ! "$UL_MBIT" =~ ^[0-9]+$ ]] || [ "$UL_MBIT" -le 0 ]; then
        UL_MBIT=16
    fi
    if [[ ! "$BURST_KB" =~ ^[0-9]+$ ]] || [ "$BURST_KB" -le 0 ]; then
        BURST_KB=256
    fi

    local dl_rate_kb=$(( DL_MBIT * 1000 / 8 ))
    local ul_rate_kb=$(( UL_MBIT * 1000 / 8 ))

    # 1. Ensure table and set exist
    nft add table ${TABLE_FAMILY} ${TABLE_NAME} 2>/dev/null || true
    nft add set ${TABLE_FAMILY} ${TABLE_NAME} ${SET_NAME} '{ type inet_service; flags interval; }' 2>/dev/null || true

    # 2. Upload filter chain (Client -> Server: client upload)
    nft add chain ${TABLE_FAMILY} ${TABLE_NAME} wg_upload '{ type filter hook prerouting priority filter; policy accept; }' 2>/dev/null || true
    nft flush chain ${TABLE_FAMILY} ${TABLE_NAME} wg_upload 2>/dev/null || true
    nft add rule ${TABLE_FAMILY} ${TABLE_NAME} wg_upload iifname "${WAN_IF}" udp dport @${SET_NAME} meter wg_ul_meter size 65535 "{ udp dport limit rate over ${ul_rate_kb} kbytes/second burst ${BURST_KB} kbytes }" drop

    # 3. Download filter chain (Server -> Client: client download)
    nft add chain ${TABLE_FAMILY} ${TABLE_NAME} wg_download '{ type filter hook postrouting priority filter; policy accept; }' 2>/dev/null || true
    nft flush chain ${TABLE_FAMILY} ${TABLE_NAME} wg_download 2>/dev/null || true
    nft add rule ${TABLE_FAMILY} ${TABLE_NAME} wg_download oifname "${WAN_IF}" udp sport @${SET_NAME} meter wg_dl_meter size 65535 "{ udp sport limit rate over ${dl_rate_kb} kbytes/second burst ${BURST_KB} kbytes }" drop
}

# --- Sync Ports Between 3x-ui DB and NFTables Set ---
sync_ports() {
    load_config

    # Self-healing: restore table and rules if missing
    if ! is_limiter_active; then
        log_event "WARN" "NFTables table ${TABLE_NAME} was missing. Rebuilding ruleset..."
        apply_nft_rules
    fi

    local db_ports
    db_ports=$(get_active_db_ports)

    # Safety check: if DB query returns nothing, do NOT wipe active ports
    if [ -z "$db_ports" ]; then
        log_event "WARN" "Database query returned no active ports. Skipping port flush for safety."
        return 0
    fi

    local nft_ports
    nft_ports=$(get_active_nft_ports)

    # Compute added and removed ports using awk (immune to sort order discrepancies)
    local added_ports
    local removed_ports
    added_ports=$(awk 'NR==FNR{nft[$1];next} !($1 in nft)' <(echo "$nft_ports") <(echo "$db_ports"))
    removed_ports=$(awk 'NR==FNR{db[$1];next} !($1 in db)' <(echo "$db_ports") <(echo "$nft_ports"))

    local add_count=0
    local del_count=0

    # Batch add new ports
    if [ -n "$added_ports" ]; then
        local add_csv
        add_csv=$(echo "$added_ports" | tr '\n' ',' | sed 's/,$//')
        if [ -n "$add_csv" ]; then
            nft add element ${TABLE_FAMILY} ${TABLE_NAME} ${SET_NAME} "{ $add_csv }" 2>/dev/null || true
            add_count=$(echo "$added_ports" | wc -l)
            log_event "INFO" "Added ${add_count} new port(s) to limiter: ${add_csv}"
        fi
    fi

    # Batch remove deleted ports
    if [ -n "$removed_ports" ]; then
        local del_csv
        del_csv=$(echo "$removed_ports" | tr '\n' ',' | sed 's/,$//')
        if [ -n "$del_csv" ]; then
            nft delete element ${TABLE_FAMILY} ${TABLE_NAME} ${SET_NAME} "{ $del_csv }" 2>/dev/null || true
            del_count=$(echo "$removed_ports" | wc -l)
            log_event "INFO" "Removed ${del_count} port(s) from limiter: ${del_csv}"
        fi
    fi

    local total_active
    total_active=$(get_active_nft_ports | wc -l)

    if [ "$add_count" -eq 0 ] && [ "$del_count" -eq 0 ]; then
        log_event "OK" "Health check passed. All ${total_active} active WireGuard ports are synchronized."
    else
        log_event "OK" "Sync completed. Now actively shaping ${total_active} WireGuard ports."
    fi
}

# --- Install Systemd Service & Timer Units ---
install_systemd_units() {
    load_config

    # Canonical script source path (safely handle pipes and subshells)
    local script_src=""
    if [ -n "${BASH_SOURCE[0]}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_src=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
    elif [ -n "$0" ] && [ -f "$0" ]; then
        script_src=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    fi

    if [ -n "$script_src" ] && [ -f "$script_src" ]; then
        if [ "$script_src" != "$INSTALL_BIN" ]; then
            cp -f "$script_src" "$INSTALL_BIN" 2>/dev/null || true
            chmod +x "$INSTALL_BIN" 2>/dev/null || true
        fi
    elif [ ! -f "$INSTALL_BIN" ]; then
        # Search fallback locations if executed via pipe or stdin
        local candidates=(
            "/root/wg-limiter.sh"
            "./Scripts/wg-limiter.sh"
            "./wg-limiter.sh"
        )
        for candidate in "${candidates[@]}"; do
            if [ -f "$candidate" ]; then
                cp -f "$candidate" "$INSTALL_BIN" 2>/dev/null || true
                chmod +x "$INSTALL_BIN" 2>/dev/null || true
                break
            fi
        done
    fi

    # 1. Main Service (runs at boot to restore rules)
    cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=WireGuard Bandwidth Limiter for 3x-ui (NFTables)
After=network.target nftables.service x-ui.service
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_BIN} boot-init
ExecReload=${INSTALL_BIN} sync
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # 2. Sync Service (runs periodically)
    cat > "$SYSTEMD_SYNC_SERVICE" <<EOF
[Unit]
Description=Sync WireGuard Ports with 3x-ui Database and Verify Health
After=network.target

[Service]
Type=oneshot
ExecStart=${INSTALL_BIN} sync
StandardOutput=journal
StandardError=journal
EOF

    # 3. Sync Timer (triggers sync service every X minutes)
    cat > "$SYSTEMD_SYNC_TIMER" <<EOF
[Unit]
Description=Periodic Timer for WireGuard Limiter Sync (${SYNC_INTERVAL}m)

[Timer]
OnBootSec=1min
OnUnitActiveSec=${SYNC_INTERVAL}min
Unit=wg-limiter-sync.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable wg-limiter.service >/dev/null 2>&1 || true
    systemctl enable --now wg-limiter-sync.timer >/dev/null 2>&1 || true
}

# --- Enable Limiter Action ---
action_enable() {
    echo ""
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}${GREEN}   Enable & Deploy WireGuard Bandwidth Limiter       ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo ""

    ensure_dependencies
    load_config

    echo -e "${BOLD}Detected WAN Network Interface:${NC} ${YELLOW}${WAN_IF}${NC}"
    read -rp "Press Enter to confirm, or type custom interface name: " user_if
    if [ -n "$user_if" ]; then
        WAN_IF="$user_if"
    fi

    echo ""
    echo -e "${BOLD}Configure Default Bandwidth Ceilings:${NC}"
    read -rp "Download limit in Mbit/s [Default: ${DL_MBIT}]: " user_dl
    if [ -n "$user_dl" ] && [[ "$user_dl" =~ ^[0-9]+$ ]] && [ "$user_dl" -gt 0 ]; then
        DL_MBIT="$user_dl"
    fi

    read -rp "Upload limit in Mbit/s [Default: ${UL_MBIT}]: " user_ul
    if [ -n "$user_ul" ] && [[ "$user_ul" =~ ^[0-9]+$ ]] && [ "$user_ul" -gt 0 ]; then
        UL_MBIT="$user_ul"
    fi

    save_config

    msg_info "Creating isolated NFTables table (inet ${TABLE_NAME})..."
    apply_nft_rules

    msg_info "Performing initial WireGuard ports synchronization..."
    sync_ports

    msg_info "Configuring and activating Systemd service and timer..."
    install_systemd_units

    local count
    count=$(get_active_nft_ports | wc -l)

    echo ""
    msg_ok "WireGuard Bandwidth Limiter deployed and activated successfully!"
    echo -e "  - Download Limit:   ${BOLD}${GREEN}${DL_MBIT} Mbit/s${NC} per user/port"
    echo -e "  - Upload Limit:     ${BOLD}${GREEN}${UL_MBIT} Mbit/s${NC} per user/port"
    echo -e "  - Active Ports:     ${BOLD}${CYAN}${count}${NC} WireGuard ports actively monitored"
    echo -e "  - Auto-Sync Timer:  ${BOLD}Every ${SYNC_INTERVAL} minutes${NC}"
    echo -e "  - Log File:         ${BOLD}${LOG_FILE}${NC}"
    echo ""
}

# --- Change Speed Limits Action ---
action_change_limits() {
    load_config
    echo ""
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}${YELLOW}         Change Download & Upload Speed Limits       ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "Current Download Limit: ${BOLD}${GREEN}${DL_MBIT} Mbit/s${NC}"
    echo -e "Current Upload Limit:   ${BOLD}${GREEN}${UL_MBIT} Mbit/s${NC}"
    echo ""

    read -rp "Enter new Download limit in Mbit/s [Current: ${DL_MBIT}]: " new_dl
    if [ -n "$new_dl" ]; then
        if [[ ! "$new_dl" =~ ^[0-9]+$ ]] || [ "$new_dl" -le 0 ]; then
            msg_err "Invalid download limit value."
            return 1
        fi
        DL_MBIT="$new_dl"
    fi

    read -rp "Enter new Upload limit in Mbit/s [Current: ${UL_MBIT}]: " new_ul
    if [ -n "$new_ul" ]; then
        if [[ ! "$new_ul" =~ ^[0-9]+$ ]] || [ "$new_ul" -le 0 ]; then
            msg_err "Invalid upload limit value."
            return 1
        fi
        UL_MBIT="$new_ul"
    fi

    save_config
    apply_nft_rules
    log_event "UPDATE" "Speed limits updated to DL: ${DL_MBIT} Mbit/s, UL: ${UL_MBIT} Mbit/s"

    echo ""
    msg_ok "Bandwidth limits updated successfully!"
    echo -e "  - New Download Limit: ${BOLD}${GREEN}${DL_MBIT} Mbit/s${NC}"
    echo -e "  - New Upload Limit:   ${BOLD}${GREEN}${UL_MBIT} Mbit/s${NC}"
    echo ""
}

# --- Disable / Remove Limiter Action ---
action_disable() {
    echo ""
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}${RED}       Disable & Remove All Speed Limits             ${NC}"
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${YELLOW}Are you sure you want to disable and remove all bandwidth limits?${NC}"
    read -rp "Type 'y' to confirm removal [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "Operation cancelled."
        return 0
    fi

    msg_info "Stopping and disabling systemd timer and service..."
    systemctl disable --now wg-limiter-sync.timer >/dev/null 2>&1 || true
    systemctl disable --now wg-limiter.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_SYNC_SERVICE" "$SYSTEMD_SYNC_TIMER"
    systemctl daemon-reload

    msg_info "Removing isolated table ${TABLE_NAME} from NFTables..."
    nft delete table ${TABLE_FAMILY} ${TABLE_NAME} 2>/dev/null || true

    log_event "SHUTDOWN" "Limiter disabled and table ${TABLE_NAME} removed."
    echo ""
    msg_ok "Bandwidth limiter disabled and NFTables table removed cleanly."
    msg_info "Note: All other server firewall rules and tables remain completely intact."
    echo ""
}

# --- View Status Action ---
action_status() {
    load_config
    echo ""
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${BOLD}${CYAN}            Live Bandwidth Limiter Status            ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    if is_limiter_active; then
        echo -e "Kernel Status:          ${BOLD}${GREEN}[Active] Active${NC}"
    else
        echo -e "Kernel Status:          ${BOLD}${RED}[Inactive] Inactive${NC}"
    fi

    local timer_status
    if systemctl is-active wg-limiter-sync.timer >/dev/null 2>&1; then
        timer_status="${GREEN}Active (Every ${SYNC_INTERVAL}m)${NC}"
    else
        timer_status="${RED}Inactive${NC}"
    fi

    local active_ports
    active_ports=$(get_active_nft_ports)
    local port_count=0
    if [ -n "$active_ports" ]; then
        port_count=$(echo "$active_ports" | wc -l)
    fi

    echo -e "Network Interface:      ${YELLOW}${WAN_IF}${NC}"
    echo -e "Download Limit:         ${BOLD}${GREEN}${DL_MBIT} Mbit/s${NC} per user"
    echo -e "Upload Limit:           ${BOLD}${GREEN}${UL_MBIT} Mbit/s${NC} per user"
    echo -e "Traffic Burst Buffer:   ${BOLD}${BURST_KB} KB${NC}"
    echo -e "Auto-Sync Timer:        ${BOLD}${timer_status}${NC}"
    echo -e "Actively Shaped Ports:  ${BOLD}${MAGENTA}${port_count}${NC} WireGuard inbounds"
    echo ""

    if [ "$port_count" -gt 0 ]; then
        echo -e "${BOLD}Sample Monitored Ports:${NC}"
        echo "$active_ports" | head -n 15 | tr '\n' ' '
        if [ "$port_count" -gt 15 ]; then
            echo -e "\n${CYAN}... and $(( port_count - 15 )) more ports${NC}"
        else
            echo ""
        fi
    fi
    echo ""
}

# --- View Logs Action ---
action_logs() {
    while true; do
        echo ""
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "${BOLD}${BLUE}               System Logs Management                ${NC}"
        echo -e "${CYAN}=====================================================${NC}"
        echo -e "1) View last 40 log entries"
        echo -e "2) Follow logs in real-time (Live Tail)"
        echo -e "3) Clear log file"
        echo -e "0) Back to main menu"
        echo ""
        read -rp "Select an option [0-3]: " log_choice
        case "$log_choice" in
            1)
                echo ""
                echo -e "${YELLOW}--- Last entries from ${LOG_FILE} ---${NC}"
                if [ -f "$LOG_FILE" ]; then
                    tail -n 40 "$LOG_FILE"
                else
                    msg_warn "Log file does not exist yet."
                fi
                echo ""
                ;;
            2)
                echo ""
                msg_info "Monitoring logs live. Press Ctrl+C to stop..."
                if [ -f "$LOG_FILE" ]; then
                    tail -f "$LOG_FILE"
                else
                    msg_warn "Log file does not exist yet."
                fi
                ;;
            3)
                if [ -f "$LOG_FILE" ]; then
                    truncate -s 0 "$LOG_FILE"
                    msg_ok "Log file cleared."
                fi
                ;;
            0)
                break
                ;;
            *)
                msg_err "Invalid selection."
                ;;
        esac
    done
}

# --- Non-Interactive CLI Dispatcher ---
cli_dispatch() {
    case "$1" in
        boot-init)
            ensure_dependencies
            load_config
            apply_nft_rules
            sync_ports
            log_event "BOOT" "Initialized limiter ruleset and synced ports on boot."
            ;;
        install|enable)
            ensure_dependencies
            load_config
            apply_nft_rules
            sync_ports
            install_systemd_units
            msg_ok "Limiter installed and systemd units activated."
            ;;
        sync)
            sync_ports
            ;;
        status)
            action_status
            ;;
        disable|uninstall)
            action_disable
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# --- Interactive Main Menu ---
main_menu() {
    while true; do
        load_config
        local is_act="${RED}Inactive [Inactive]${NC}"
        if is_limiter_active; then
            is_act="${GREEN}Active [Active]${NC}"
        fi

        local p_cnt=0
        if is_limiter_active; then
            p_cnt=$(get_active_nft_ports | wc -l)
        fi

        echo ""
        echo -e "${CYAN}+======================================================+${NC}"
        echo -e "${CYAN}|${NC}   ${BOLD}WireGuard Bandwidth Limiter for 3x-ui (NFTables)${NC}   ${CYAN}|${NC}"
        echo -e "${CYAN}+======================================================+${NC}"
        echo -e " Status: ${is_act} | Active Ports: ${BOLD}${CYAN}${p_cnt}${NC} | DL/UL Limit: ${BOLD}${GREEN}${DL_MBIT}/${UL_MBIT} Mbit${NC}"
        echo -e "${CYAN}------------------------------------------------------${NC}"
        echo -e " ${BOLD}1)${NC} Enable & Deploy Bandwidth Limiter"
        echo -e " ${BOLD}2)${NC} Change Download & Upload Speed Limits"
        echo -e " ${BOLD}3)${NC} Force Sync Ports with Panel Database Now"
        echo -e " ${BOLD}4)${NC} View Current Status & Monitored Ports"
        echo -e " ${BOLD}5)${NC} View & Monitor System Logs"
        echo -e " ${BOLD}6)${NC} ${RED}Disable & Remove All Speed Limits${NC}"
        echo -e " ${BOLD}0)${NC} Exit"
        echo -e "${CYAN}------------------------------------------------------${NC}"
        read -rp "Please select an option [0-6]: " choice

        case "$choice" in
            1) action_enable ;;
            2) action_change_limits ;;
            3)
                msg_info "Synchronizing ports manually..."
                sync_ports
                msg_ok "Ports synchronized successfully."
                ;;
            4) action_status ;;
            5) action_logs ;;
            6) action_disable ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                msg_err "Invalid selection. Please try again."
                ;;
        esac
    done
}

# --- Script Entrypoint ---
check_root

if [ $# -gt 0 ]; then
    if cli_dispatch "$1"; then
        exit 0
    fi
fi

main_menu
