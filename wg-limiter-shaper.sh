#!/bin/bash

# ==========================================
# ZERO-CPU HASHLIMIT TRAFFIC SHAPER
# Architecture:
# 1. Abandons heavy TC (Traffic Control) trees which cause high CPU ksoftirqd spikes.
# 2. Uses O(1) Kernel Netfilter Hashlimit module.
# 3. No background Cron jobs or state files required.
# 4. Automatically tracks and limits active ports on the fly.
# ==========================================

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31m[-] Error: Please run as root.\e[0m"
    exit 1
fi

# ==========================================
# Configuration
# ==========================================
PORT_MIN=10000
PORT_MAX=50000

CONFIG_FILE="/etc/wg_hashlimit_config"

# UI Colors
C_CYAN='\e[36m'
C_GREEN='\e[32m'
C_YELLOW='\e[33m'
C_RED='\e[31m'
C_MAGENTA='\e[35m'
C_RESET='\e[0m'

# ==========================================
# Core Functions
# ==========================================

clean_old_system() {
    # 1. Remove old TC rules if any exist
    INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    tc qdisc del dev "$INTERFACE" root >/dev/null 2>&1
    tc qdisc del dev "$INTERFACE" ingress >/dev/null 2>&1
    if ip link show ifb0 >/dev/null 2>&1; then
        tc qdisc del dev ifb0 root >/dev/null 2>&1
        ip link set dev ifb0 down >/dev/null 2>&1
    fi
    
    # 2. Remove old cron jobs
    crontab -l 2>/dev/null | grep -v "wg_shaper" | grep -v "wg-limiter" | grep -v "sync" | crontab -
    
    # 3. Clean hashlimit iptables chains
    for CMD in iptables ip6tables; do
        $CMD -D INPUT -j WG_LIMIT_IN >/dev/null 2>&1
        $CMD -D OUTPUT -j WG_LIMIT_OUT >/dev/null 2>&1
        $CMD -F WG_LIMIT_IN >/dev/null 2>&1
        $CMD -X WG_LIMIT_IN >/dev/null 2>&1
        $CMD -F WG_LIMIT_OUT >/dev/null 2>&1
        $CMD -X WG_LIMIT_OUT >/dev/null 2>&1
    done
    
    rm -f /etc/wg_shaper_config
    rm -f /etc/wg_shaper_state
}

apply_limits() {
    clear
    echo -e "${C_CYAN}====================================================${C_RESET}"
    echo -e "${C_CYAN}    Apply Zero-CPU Hashlimit (Iptables Engine)      ${C_RESET}"
    echo -e "${C_CYAN}====================================================${C_RESET}"
    
    read -p "$(echo -e ${C_YELLOW}"[?] Enter DOWNLOAD limit per port (Mbit) [e.g., 15]: "${C_RESET})" DL_INPUT
    if ! [[ "$DL_INPUT" =~ ^[0-9]+$ ]]; then echo -e "${C_RED}[-] Invalid input.${C_RESET}"; sleep 2; return 1; fi

    read -p "$(echo -e ${C_YELLOW}"[?] Enter UPLOAD limit per port (Mbit) [e.g., 15]: "${C_RESET})" UL_INPUT
    if ! [[ "$UL_INPUT" =~ ^[0-9]+$ ]]; then echo -e "${C_RED}[-] Invalid input.${C_RESET}"; sleep 2; return 1; fi

    # Convert Mbit to KB/s (1 Mbit = 125 KB/s)
    DL_KB=$((DL_INPUT * 125))
    UL_KB=$((UL_INPUT * 125))
    
    # Burst buffer to allow smooth TCP ramp-up (1.5 seconds worth of data)
    DL_BURST=$((DL_KB * 3 / 2))
    UL_BURST=$((UL_KB * 3 / 2))

    echo -e "${C_MAGENTA}[*] Cleaning previous configurations...${C_RESET}"
    clean_old_system

    echo -e "${C_MAGENTA}[*] Injecting Kernel Netfilter Rules...${C_RESET}"
    
    # Apply to both IPv4 and IPv6
    for CMD in iptables ip6tables; do
        $CMD -N WG_LIMIT_IN
        $CMD -N WG_LIMIT_OUT
        
        $CMD -I INPUT -j WG_LIMIT_IN
        $CMD -I OUTPUT -j WG_LIMIT_OUT
        
        # Client Download = Server OUTPUT (Matching Source Port)
        $CMD -A WG_LIMIT_OUT -p udp --sport $PORT_MIN:$PORT_MAX -m hashlimit \
            --hashlimit-above ${DL_KB}kb/s --hashlimit-burst ${DL_BURST}kb \
            --hashlimit-mode srcport --hashlimit-name wg_dl \
            --hashlimit-htable-size 8192 --hashlimit-htable-max 32768 --hashlimit-htable-expire 60000 \
            -j DROP

        # Client Upload = Server INPUT (Matching Destination Port)
        $CMD -A WG_LIMIT_IN -p udp --dport $PORT_MIN:$PORT_MAX -m hashlimit \
            --hashlimit-above ${UL_KB}kb/s --hashlimit-burst ${UL_BURST}kb \
            --hashlimit-mode dstport --hashlimit-name wg_ul \
            --hashlimit-htable-size 8192 --hashlimit-htable-max 32768 --hashlimit-htable-expire 60000 \
            -j DROP
    done

    # Save config for status page
    echo "DL_MBIT=$DL_INPUT" > "$CONFIG_FILE"
    echo "UL_MBIT=$UL_INPUT" >> "$CONFIG_FILE"

    echo -e "${C_GREEN}[+] Ultra-Lightweight Limits applied successfully!${C_RESET}"
    read -p "Press Enter to return..." temp
}

disable_limits() {
    clear
    echo -e "${C_CYAN}====================================================${C_RESET}"
    echo -e "${C_CYAN}             Remove All Network Limits              ${C_RESET}"
    echo -e "${C_CYAN}====================================================${C_RESET}"
    
    echo -e "${C_MAGENTA}[*] Purging all Iptables hashlimit rules...${C_RESET}"
    clean_old_system
    rm -f "$CONFIG_FILE"
    
    echo -e "${C_GREEN}[+] Done. The system is completely clean!${C_RESET}"
    read -p "Press Enter to return..." temp
}

show_status() {
    clear
    echo -e "${C_CYAN}====================================================${C_RESET}"
    echo -e "${C_CYAN}               Hashlimit Engine Status              ${C_RESET}"
    echo -e "${C_CYAN}====================================================${C_RESET}"
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo -e "${C_YELLOW}Configured Limits:${C_RESET} DL: ${DL_MBIT}Mbit / UL: ${UL_MBIT}Mbit (Per Port)"
        echo -e "${C_YELLOW}Engine Type:${C_RESET}       ${C_GREEN}Kernel O(1) Hashlimit (Zero-CPU)${C_RESET}"
        echo -e "${C_CYAN}----------------------------------------------------${C_RESET}"
        
        echo -e "${C_MAGENTA}[ Active Download Drop Counter (Client DL) ]${C_RESET}"
        iptables -L WG_LIMIT_OUT -v -n | grep "DROP" | awk '{print "Packets Dropped: "$1", Bytes Shaped: "$2}'
        
        echo -e "${C_MAGENTA}[ Active Upload Drop Counter (Client UL) ]${C_RESET}"
        iptables -L WG_LIMIT_IN -v -n | grep "DROP" | awk '{print "Packets Dropped: "$1", Bytes Shaped: "$2}'
    else
        echo -e "${C_RED}No limits are currently applied.${C_RESET}"
    fi

    echo -e "${C_CYAN}====================================================${C_RESET}"
    read -p "Press Enter to return..." temp
}

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
    echo -e "${C_CYAN}========= Zero-CPU Kernel Traffic Shaping ==========${C_RESET}"
    echo -e "  1) ${C_GREEN}Apply Limits${C_RESET} (Hashlimit Engine)"
    echo -e "  2) ${C_RED}Disable Limits${C_RESET} (Restore All)"
    echo -e "  3) ${C_YELLOW}Status & Reports${C_RESET} (View Dropped Bytes)"
    echo -e "  4) Exit"
    echo -e "${C_CYAN}====================================================${C_RESET}"
    read -p "Select an option [1-4]: " choice

    case "$choice" in
        1) apply_limits ;;
        2) disable_limits ;;
        3) show_status ;;
        4) clear; exit 0 ;;
        *) echo -e "${C_RED}[-] Invalid option.${C_RESET}"; sleep 1 ;;
    esac
done
