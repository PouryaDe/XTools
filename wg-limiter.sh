#!/bin/bash

# ==========================================
# CRITICAL: Define PATH for Cron Environment
# ==========================================
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Ensure root privileges before proceeding
if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31m[-] Error: Please run as root.\e[0m"
    exit 1
fi

# ==========================================
# Configuration Variables
# ==========================================
INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
IFB_DEV="ifb0"
PORT_MIN=10000
PORT_MAX=50000

CONFIG_FILE="/etc/wg_shaper_config"
LOG_FILE="/var/log/wg_shaper.log"
SCRIPT_PATH=$(readlink -f "$0")

CRON_CMD="* * * * * $SCRIPT_PATH sync >> $LOG_FILE 2>&1"

# ==========================================
# UI Colors
# ==========================================
C_CYAN='\e[36m'
C_GREEN='\e[32m'
C_YELLOW='\e[33m'
C_RED='\e[31m'
C_MAGENTA='\e[35m'
C_RESET='\e[0m'

# ==========================================
# Core Functions
# ==========================================

clean_existing_rules() {
    # Delete root and ingress qdiscs safely
    tc qdisc del dev "$INTERFACE" root >/dev/null 2>&1
    tc qdisc del dev "$INTERFACE" ingress >/dev/null 2>&1
    if ip link show "$IFB_DEV" >/dev/null 2>&1; then
        tc qdisc del dev "$IFB_DEV" root >/dev/null 2>&1
        ip link set dev "$IFB_DEV" down >/dev/null 2>&1
    fi
}

get_active_udp_ports() {
    ss -ulnH | awk '{print $4}' | awk -F":" '{print $NF}' | grep -E '^[0-9]+$' | awk -v min="$PORT_MIN" -v max="$PORT_MAX" '$1 >= min && $1 <= max' | sort -n -u
}

get_shaped_ports() {
    if tc class show dev "$INTERFACE" 2>/dev/null | grep -q "htb"; then
        tc class show dev "$INTERFACE" | grep -oP 'class htb 1:\K[0-9a-f]+' | grep -v '9999' | while read hex; do
            printf "%d\n" "0x$hex"
        done | sort -n -u
    fi
}

apply_port_rules() {
    local PORT=$1
    local DL_LIMIT=$2
    local UL_LIMIT=$3
    local HEX_PORT=$(printf "%x" "$PORT")
    
    # Egress (Download)
    tc class add dev "$INTERFACE" parent 1: classid 1:"$HEX_PORT" htb rate "$DL_LIMIT" ceil "$DL_LIMIT" 2>>"$LOG_FILE"
    tc qdisc add dev "$INTERFACE" parent 1:"$HEX_PORT" handle "$HEX_PORT": fq_codel limit 1024 2>>"$LOG_FILE"
    tc filter add dev "$INTERFACE" protocol ip parent 1: prio 1 flower ip_proto udp src_port "$PORT" flowid 1:"$HEX_PORT" 2>>"$LOG_FILE"
    tc filter add dev "$INTERFACE" protocol ipv6 parent 1: prio 2 flower ip_proto udp src_port "$PORT" flowid 1:"$HEX_PORT" 2>>"$LOG_FILE"

    # Ingress (Upload)
    tc class add dev "$IFB_DEV" parent 1: classid 1:"$HEX_PORT" htb rate "$UL_LIMIT" ceil "$UL_LIMIT" 2>>"$LOG_FILE"
    tc qdisc add dev "$IFB_DEV" parent 1:"$HEX_PORT" handle "$HEX_PORT": fq_codel limit 1024 2>>"$LOG_FILE"
    tc filter add dev "$IFB_DEV" protocol ip parent 1: prio 1 flower ip_proto udp dst_port "$PORT" flowid 1:"$HEX_PORT" 2>>"$LOG_FILE"
    tc filter add dev "$IFB_DEV" protocol ipv6 parent 1: prio 2 flower ip_proto udp dst_port "$PORT" flowid 1:"$HEX_PORT" 2>>"$LOG_FILE"
}

# ==========================================
# Main Actions
# ==========================================

sync_limits() {
    if [ ! -f "$CONFIG_FILE" ]; then
        exit 0
    fi
    
    # Load configuration
    source "$CONFIG_FILE"
    
    # Override INTERFACE from config if it exists to preserve correctness in cron
    if [ ! -z "$CONF_INTERFACE" ]; then
        INTERFACE="$CONF_INTERFACE"
    fi
    
    if [ -z "$INTERFACE" ]; then
        echo "[$(date)] ERROR: Network interface could not be detected." >> "$LOG_FILE"
        exit 1
    fi

    # Check if root qdisc actually exists, if not, try to recover it
    if ! tc qdisc show dev "$INTERFACE" | grep -q "htb"; then
        echo "[$(date)] WARNING: Root Qdisc missing on $INTERFACE. Re-initializing..." >> "$LOG_FILE"
        tc qdisc add dev "$INTERFACE" root handle 1: htb default 9999 2>>"$LOG_FILE"
        tc qdisc add dev "$IFB_DEV" root handle 1: htb default 9999 2>>"$LOG_FILE"
    fi

    ACTIVE_PORTS=$(get_active_udp_ports)
    SHAPED_PORTS=$(get_shaped_ports)
    
    for PORT in $ACTIVE_PORTS; do
        if ! echo "$SHAPED_PORTS" | grep -qw "$PORT"; then
            echo "[$(date)] Auto-Sync: Applying limits to newly detected port -> $PORT" >> "$LOG_FILE"
            apply_port_rules "$PORT" "$CONF_DL" "$CONF_UL"
        fi
    done
}

enable_limit() {
    clear
    echo -e "${C_CYAN}====================================================${C_RESET}"
    echo -e "${C_CYAN}         Apply Dedicated Limits (Per Port)          ${C_RESET}"
    echo -e "${C_CYAN}====================================================${C_RESET}"
    
    read -p "$(echo -e ${C_YELLOW}"[?] Enter DOWNLOAD limit per port (Mbit) [e.g., 20]: "${C_RESET})" DL_INPUT
    if ! [[ "$DL_INPUT" =~ ^[0-9]+$ ]]; then echo -e "${C_RED}[-] Invalid input.${C_RESET}"; sleep 2; return 1; fi

    read -p "$(echo -e ${C_YELLOW}"[?] Enter UPLOAD limit per port (Mbit) [e.g., 20]: "${C_RESET})" UL_INPUT
    if ! [[ "$UL_INPUT" =~ ^[0-9]+$ ]]; then echo -e "${C_RED}[-] Invalid input.${C_RESET}"; sleep 2; return 1; fi

    DL_LIMIT="${DL_INPUT}mbit"
    UL_LIMIT="${UL_INPUT}mbit"

    # Save config for cron job (including the dynamic interface name)
    echo "CONF_INTERFACE=\"$INTERFACE\"" > "$CONFIG_FILE"
    echo "CONF_DL=\"$DL_LIMIT\"" >> "$CONFIG_FILE"
    echo "CONF_UL=\"$UL_LIMIT\"" >> "$CONFIG_FILE"

    echo -e "${C_MAGENTA}[*] Initializing network tree...${C_RESET}"
    clean_existing_rules
    ethtool -K "$INTERFACE" tso off gso off gro off >/dev/null 2>&1
    
    # Load IFB module and wait for initialization
    modprobe ifb numifbs=1 >/dev/null 2>&1
    sleep 1 
    ip link set dev "$IFB_DEV" up >/dev/null 2>&1

    # Setup Root Qdiscs
    tc qdisc add dev "$INTERFACE" root handle 1: htb default 9999 2>>"$LOG_FILE"
    tc qdisc add dev "$IFB_DEV" root handle 1: htb default 9999 2>>"$LOG_FILE"
    tc qdisc add dev "$INTERFACE" handle ffff: ingress 2>>"$LOG_FILE"
    tc filter add dev "$INTERFACE" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev "$IFB_DEV" 2>>"$LOG_FILE"

    echo "[$(date)] Service Started. Limits set to DL: $DL_LIMIT, UL: $UL_LIMIT" > "$LOG_FILE"

    sync_limits
    
    (crontab -l 2>/dev/null | grep -v -F "$SCRIPT_PATH sync"; echo "$CRON_CMD") | crontab -

    echo -e "${C_GREEN}[+] Limits applied and Auto-Sync Cron Job is active!${C_RESET}"
    read -p "Press Enter to return to main menu..." temp
}

disable_limit() {
    clear
    echo -e "${C_CYAN}====================================================${C_RESET}"
    echo -e "${C_CYAN}             Completely Remove Limits               ${C_RESET}"
    echo -e "${C_CYAN}====================================================${C_RESET}"
    
    echo -e "${C_MAGENTA}[*] Removing auto-sync Cron Job...${C_RESET}"
    crontab -l 2>/dev/null | grep -v -F "$SCRIPT_PATH sync" | crontab -
    rm -f "$CONFIG_FILE"
    echo "[$(date)] Service Stopped and Limits Removed." >> "$LOG_FILE"

    echo -e "${C_MAGENTA}[*] Removing all TC rules and restoring hardware offloading...${C_RESET}"
    clean_existing_rules
    ethtool -K "$INTERFACE" tso on gso on gro on >/dev/null 2>&1
    
    echo -e "${C_GREEN}[+] Done. The system is completely clean!${C_RESET}"
    read -p "Press Enter to return..." temp
}

show_status() {
    clear
    echo -e "${C_CYAN}====================================================${C_RESET}"
    echo -e "${C_CYAN}               System Traffic Status                ${C_RESET}"
    echo -e "${C_CYAN}====================================================${C_RESET}"
    
    echo -e "${C_YELLOW}Network Interface:${C_RESET} $INTERFACE"
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${C_YELLOW}Configured Limits:${C_RESET} DL: $CONF_DL / UL: $CONF_UL"
    fi

    if crontab -l 2>/dev/null | grep -q -F "$SCRIPT_PATH sync"; then
        echo -e "${C_YELLOW}Auto-Sync Cron:${C_RESET}    ${C_GREEN}ACTIVE (Every 1 Min)${C_RESET}"
    else
        echo -e "${C_YELLOW}Auto-Sync Cron:${C_RESET}    ${C_RED}INACTIVE${C_RESET}"
    fi

    echo -e "${C_CYAN}----------------------------------------------------${C_RESET}"

    ACTIVE_PORTS_RAW=$(get_active_udp_ports)
    SHAPED_PORTS_RAW=$(get_shaped_ports)
    
    ACTIVE_COUNT=$(echo "$ACTIVE_PORTS_RAW" | wc -w)
    SHAPED_COUNT=$(echo "$SHAPED_PORTS_RAW" | wc -w)
    
    if [ -z "$ACTIVE_PORTS_RAW" ]; then ACTIVE_COUNT=0; fi
    if [ -z "$SHAPED_PORTS_RAW" ]; then SHAPED_COUNT=0; fi

    echo -e "${C_YELLOW}Total Listening UDP Ports:${C_RESET} $ACTIVE_COUNT"
    echo -e "${C_YELLOW}Total Shaped (Limited) Ports:${C_RESET} $SHAPED_COUNT"
    echo -e "${C_CYAN}----------------------------------------------------${C_RESET}"

    if [ "$SHAPED_COUNT" -gt 0 ]; then
        echo -e "${C_MAGENTA}List of Shaped Ports:${C_RESET}"
        echo "$SHAPED_PORTS_RAW" | tr '\n' ' ' | fold -w 60 -s | awk '{print "  "$0}'
    else
        echo -e "${C_RED}No ports are currently shaped.${C_RESET}"
    fi
    
    echo -e "${C_CYAN}----------------------------------------------------${C_RESET}"
    if [ -f "$LOG_FILE" ]; then
        echo -e "${C_MAGENTA}Recent Sync Logs (Last 5 events):${C_RESET}"
        tail -n 5 "$LOG_FILE" | awk '{print "  "$0}'
    fi

    echo -e "${C_CYAN}====================================================${C_RESET}"
    read -p "Press Enter to return..." temp
}

# ==========================================
# CLI Argument Handler for Cron
# ==========================================
if [ "$1" == "sync" ]; then
    sync_limits
    exit 0
fi

# ==========================================
# Main Interactive Menu
# ==========================================
while true; do
    clear
    echo -e "${C_GREEN}"
    echo "  __       ______    ____  _                        "
    echo "  \ \       / / ___|  / ___|| |__   __ _ _ __   ___  "
    echo "   \ \ /\ / / |  _    \___ \| '_ \ / _\` | '_ \ / _ \ "
    echo "    \ V  V /| |_| |   ___) | | | | (_| | |_) |  __/ "
    echo "     \_/\_/  \____|  |____/|_| |_|\__,_| .__/ \___| "
    echo "                                       |_|          "
    echo -e "${C_RESET}"
    echo -e "${C_CYAN}========= Dynamic Per-Port Traffic Shaping =========${C_RESET}"
    echo -e "  1) ${C_GREEN}Apply & Auto-Sync Limits${C_RESET} (Active & Future Ports)"
    echo -e "  2) ${C_RED}Disable Limits${C_RESET} (Stop Cron & Wipe All Rules)"
    echo -e "  3) ${C_YELLOW}Status & Reports${C_RESET} (View Sync Status & Ports)"
    echo -e "  4) Exit"
    echo -e "${C_CYAN}====================================================${C_RESET}"
    read -p "Select an option [1-4]: " choice

    case "$choice" in
        1) enable_limit ;;
        2) disable_limit ;;
        3) show_status ;;
        4) clear; exit 0 ;;
        *) echo -e "${C_RED}[-] Invalid option.${C_RESET}"; sleep 1 ;;
    esac
done
