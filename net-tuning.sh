#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  Network Tuning Manager — Iran Server                         ║
# ║  GRE / FOU Tunnel Optimization & MSS Clamping                 ║
# ╚════════════════════════════════════════════════════════════════╝

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Constants ────────────────────────────────────────────────────
TUNING_SCRIPT="/usr/local/bin/net-tuning-apply.sh"
REVERT_SCRIPT="/usr/local/bin/net-tuning-revert.sh"
SERVICE_NAME="network-tuning"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NFT_TABLE="net_tuning"
SYSCTL_FILE="/etc/sysctl.d/99-net-tuning.conf"

# ─── UI Helpers ───────────────────────────────────────────────────
print_line()        { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }
print_double_line() { echo -e "${CYAN}════════════════════════════════════════════════════${NC}"; }
msg_info()  { echo -e " ${BLUE}[INFO]${NC} $1"; }
msg_ok()    { echo -e " ${GREEN}[OK]${NC}  $1"; }
msg_warn()  { echo -e " ${YELLOW}[WARN]${NC} $1"; }
msg_err()   { echo -e " ${RED}[ERR]${NC}  $1"; }

print_header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════════╗"
    echo " ║     Network Tuning Manager — Iran Server       ║"
    echo " ║   GRE / FOU Tunnel & MSS Clamping Optimizer   ║"
    echo " ╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ─── Root Check ───────────────────────────────────────────────────
check_root() {
    if [ "$EUID" -ne 0 ]; then
        msg_err "This script must be run as root."
        exit 1
    fi
}

# ─── Detect WAN Interface ─────────────────────────────────────────
detect_wan() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ip -o link show up 2>/dev/null \
            | awk -F': ' '{print $2}' | sed 's/@.*//' \
            | grep -v -E '^(lo|gre.*|tun.*|tap.*|docker.*|veth.*|erspan.*)$' \
            | head -1)
    fi
    [ -z "$iface" ] && iface="ens33"
    echo "$iface"
}

# ─── Current Status ───────────────────────────────────────────────
show_status() {
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  TUNING STATUS${NC}"
    print_double_line
    echo ""

    local svc_st svc_col svc_en wan tso_val qlen fwd gre_list

    svc_st=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "inactive")
    svc_en=$(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || echo "disabled")
    if [ "$svc_st" = "active" ]; then svc_col="${GREEN}"; else svc_col="${RED}"; fi
    echo -e "  ${MAGENTA}Systemd Service:${NC}  ${svc_col}${BOLD}${svc_st}${NC}  (${svc_en})"

    wan=$(detect_wan)
    echo -e "  ${MAGENTA}WAN Interface:${NC}    ${BOLD}${wan}${NC}"

    echo -n "  ${MAGENTA}MSS Clamping:${NC}     "
    if nft list table ip "${NFT_TABLE}" &>/dev/null 2>&1; then
        echo -e "${GREEN}${BOLD}ACTIVE${NC}  (table: ${NFT_TABLE})"
    else
        echo -e "${RED}${BOLD}NOT ACTIVE${NC}"
    fi

    echo -n "  ${MAGENTA}TSO Offload:${NC}      "
    tso_val=$(ethtool -k "${wan}" 2>/dev/null | awk '/tcp-segmentation-offload/ {print $2; exit}')
    if [ "$tso_val" = "off" ]; then
        echo -e "${GREEN}${BOLD}DISABLED${NC}  (optimal for tunnels)"
    else
        echo -e "${YELLOW}${BOLD}ENABLED${NC}  (may cause fragmentation with GRE)"
    fi

    qlen=$(ip link show "${wan}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="qlen") print $(i+1)}')
    echo -e "  ${MAGENTA}TX Queue Len:${NC}     ${BOLD}${qlen:-unknown}${NC}"

    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    if [ "$fwd" = "1" ]; then
        echo -e "  ${MAGENTA}IP Forward:${NC}       ${GREEN}${BOLD}ON${NC}"
    else
        echo -e "  ${MAGENTA}IP Forward:${NC}       ${RED}${BOLD}OFF${NC}"
    fi

    gre_list=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' \
        | grep '^gre[1-9]' | sed 's/@.*//' | tr '\n' ' ')
    echo -e "  ${MAGENTA}GRE Interfaces:${NC}   ${BOLD}${gre_list:-none}${NC}"

    if [ -f "$SYSCTL_FILE" ]; then
        echo -e "  ${MAGENTA}Sysctl File:${NC}      ${GREEN}${BOLD}EXISTS${NC}  (${SYSCTL_FILE})"
    else
        echo -e "  ${MAGENTA}Sysctl File:${NC}      ${RED}${BOLD}NOT FOUND${NC}"
    fi

    echo ""
    print_double_line
    echo ""
}

# ─── Generate Apply Script ────────────────────────────────────────
generate_apply_script() {
    local wan="$1"
    cat > "${TUNING_SCRIPT}" << APPLYEOF
#!/usr/bin/env bash
set -eu
IF_WAN="${wan}"
NFT_TABLE="${NFT_TABLE}"

echo "[net-tuning] Applying optimizations for GRE/FOU on \${IF_WAN}..."

# 1. IP Forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.accept_redirects=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.send_redirects=0 >/dev/null 2>&1 || true

# 2. Disable hardware offloads on WAN (only TSO/GSO/GRO — NOT rx/tx checksums)
ethtool -K "\${IF_WAN}" tso off gso off gro off 2>/dev/null || true
echo "[net-tuning] Offloads (tso/gso/gro) disabled on \${IF_WAN}"

# 3. TX queue length
ip link set dev "\${IF_WAN}" txqueuelen 10000
echo "[net-tuning] txqueuelen=10000 on \${IF_WAN}"

# 4. Disable offloads on all active GRE interfaces
for gre_if in \$(ip -o link show 2>/dev/null | awk -F': ' '{print \$2}' | grep '^gre[1-9]' | sed 's/@.*//'); do
    ethtool -K "\${gre_if}" tso off gso off gro off 2>/dev/null || true
    echo "[net-tuning] Offloads disabled on \${gre_if}"
done

# 5. MSS Clamping via nftables — fixes TCP black-hole through GRE/FOU
#    Equivalent of: iptables -A FORWARD ... -j TCPMSS --clamp-mss-to-pmtu
nft list table ip \${NFT_TABLE} &>/dev/null && nft delete table ip \${NFT_TABLE} 2>/dev/null || true
nft add table ip \${NFT_TABLE}
nft add chain ip \${NFT_TABLE} forward '{ type filter hook forward priority 0 ; policy accept ; }'
nft add rule  ip \${NFT_TABLE} forward tcp flags syn tcp option maxseg size set rt mtu
echo "[net-tuning] MSS clamping active via nftables (table: \${NFT_TABLE})"

echo "[net-tuning] All optimizations applied successfully."
APPLYEOF
    chmod 750 "${TUNING_SCRIPT}"
}

# ─── Generate Revert Script ───────────────────────────────────────
generate_revert_script() {
    local wan="$1"
    cat > "${REVERT_SCRIPT}" << REVERTEOF
#!/usr/bin/env bash
IF_WAN="${wan}"
NFT_TABLE="${NFT_TABLE}"

echo "[net-tuning] Reverting to kernel defaults on \${IF_WAN}..."

# Restore hardware offloads
ethtool -K "\${IF_WAN}" tso on gso on gro on 2>/dev/null || true
echo "[net-tuning] Offloads restored on \${IF_WAN}"

# Restore TX queue to kernel default
ip link set dev "\${IF_WAN}" txqueuelen 1000 2>/dev/null || true
echo "[net-tuning] txqueuelen=1000 on \${IF_WAN}"

# Remove MSS clamping nftables table
nft delete table ip \${NFT_TABLE} 2>/dev/null || true
echo "[net-tuning] MSS clamping table removed"

echo "[net-tuning] Reverted to defaults."
REVERTEOF
    chmod 750 "${REVERT_SCRIPT}"
}

# ─── Generate Systemd Service ─────────────────────────────────────
generate_service() {
    cat > "${SERVICE_FILE}" << SVCEOF
[Unit]
Description=Network Optimization for GRE/FOU Tunnel (Iran Server)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${TUNING_SCRIPT}
ExecStop=${REVERT_SCRIPT}
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
    chmod 644 "${SERVICE_FILE}"
}

# ─── Persist sysctl settings ─────────────────────────────────────
generate_sysctl() {
    cat > "${SYSCTL_FILE}" << SYSCTLEOF
# Network Tuning for GRE/FOU Tunnel — managed by net-tuning.sh
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
SYSCTLEOF
    sysctl -p "${SYSCTL_FILE}" >/dev/null 2>&1 || true
    msg_ok "Sysctl settings saved → ${SYSCTL_FILE}"
}

# ─── Apply ────────────────────────────────────────────────────────
do_apply() {
    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Apply & Install Network Tuning${NC}"
    print_double_line
    echo ""

    local wan
    wan=$(detect_wan)
    msg_info "Auto-detected WAN interface: ${BOLD}${wan}${NC}"
    read -p "  Press Enter to use '${wan}', or type interface name to override: " override
    override="${override//$'\r'/}"
    [ -n "$override" ] && wan="$override"

    if ! ip link show "${wan}" &>/dev/null; then
        msg_err "Interface '${wan}' not found. Aborting."
        return 1
    fi

    echo ""
    msg_info "Generating scripts..."
    generate_apply_script "${wan}"
    msg_ok "Apply script  → ${TUNING_SCRIPT}"
    generate_revert_script "${wan}"
    msg_ok "Revert script → ${REVERT_SCRIPT}"

    msg_info "Generating systemd service..."
    generate_service
    msg_ok "Service file  → ${SERVICE_FILE}"

    msg_info "Persisting sysctl settings..."
    generate_sysctl

    msg_info "Applying settings immediately..."
    bash "${TUNING_SCRIPT}"
    echo ""

    msg_info "Enabling service for boot persistence..."
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" &>/dev/null
    systemctl start "${SERVICE_NAME}" &>/dev/null || true
    msg_ok "Service enabled — will run automatically on every reboot."

    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Done! Tuning Applied & Persisted.${NC}"
    print_double_line
    echo ""
    echo -e "  ${DIM}To verify:   systemctl status ${SERVICE_NAME}${NC}"
    echo -e "  ${DIM}To undo:     select option 6 from this menu${NC}"
    echo ""
}

# ─── Revert ───────────────────────────────────────────────────────
do_revert() {
    echo ""
    echo -e " ${RED}${BOLD}  This will revert all tuning and remove the systemd service.${NC}"
    read -p "  Continue? (y/N): " confirm
    confirm="${confirm//$'\r'/}"
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled."; return; }

    echo ""
    msg_info "Stopping and disabling service..."
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

    if [ -f "${REVERT_SCRIPT}" ]; then
        msg_info "Running revert script..."
        bash "${REVERT_SCRIPT}" || true
    else
        msg_warn "Revert script missing — reverting manually..."
        local wan
        wan=$(detect_wan)
        ethtool -K "${wan}" tso on gso on gro on 2>/dev/null || true
        ip link set dev "${wan}" txqueuelen 1000 2>/dev/null || true
        nft delete table ip "${NFT_TABLE}" 2>/dev/null || true
    fi

    msg_info "Removing files..."
    rm -f "${SERVICE_FILE}" "${TUNING_SCRIPT}" "${REVERT_SCRIPT}" "${SYSCTL_FILE}"
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    echo ""
    msg_ok "All tuning reverted. System restored to defaults."
    echo ""
}

# ─── Dry Run Preview ──────────────────────────────────────────────
do_dryrun() {
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  DRY RUN — What will be applied:${NC}"
    print_double_line
    echo ""

    local wan
    wan=$(detect_wan)
    echo -e "  ${MAGENTA}WAN Interface:${NC}  ${BOLD}${wan}${NC} (auto-detected)"
    echo ""
    echo -e "  ${GREEN}[1]${NC} ethtool -K ${wan} tso off gso off gro off"
    echo -e "      ${DIM}→ Disables offloads that corrupt tunneled frames — safe${NC}"
    echo ""
    echo -e "  ${GREEN}[2]${NC} ip link set dev ${wan} txqueuelen 10000"
    echo -e "      ${DIM}→ Larger TX queue reduces burst packet loss${NC}"
    echo ""
    echo -e "  ${GREEN}[3]${NC} nft add table ip ${NFT_TABLE}"
    echo -e "      ${GREEN}   ${NC} nft add rule ... forward tcp flags syn tcp option maxseg size set rt mtu"
    echo -e "      ${DIM}→ MSS clamp to PMTU — prevents TCP black-hole through GRE${NC}"
    echo ""
    echo -e "  ${GREEN}[4]${NC} For each active gre* interface: ethtool -K grex tso off gso off gro off"

    local gre_list
    gre_list=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' \
        | grep '^gre[1-9]' | sed 's/@.*//' | tr '\n' ' ')
    if [ -n "$gre_list" ]; then
        echo -e "      ${DIM}→ Will apply to: ${gre_list}${NC}"
    else
        echo -e "      ${DIM}→ No GRE interfaces active now (applied dynamically at boot)${NC}"
    fi
    echo ""
    echo -e "  ${GREEN}[5]${NC} sysctl: ip_forward=1, rp_filter=0, no_redirects → ${SYSCTL_FILE}"
    echo -e "  ${GREEN}[6]${NC} systemd: ${SERVICE_NAME}.service (enabled, runs on every boot)"
    echo ""
    print_double_line
    echo ""
}

# ─── Restart Service ──────────────────────────────────────────────
do_restart() {
    echo ""
    if ! [ -f "${SERVICE_FILE}" ]; then
        msg_err "Service not installed. Use option 1 to install first."
        return
    fi
    msg_info "Restarting ${SERVICE_NAME}..."
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}"
    local st
    st=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "failed")
    if [ "$st" = "active" ]; then
        msg_ok "Service restarted successfully."
    else
        msg_err "Service failed. Run: journalctl -u ${SERVICE_NAME} -n 30 --no-pager"
    fi
    echo ""
}

# ─── View Logs ────────────────────────────────────────────────────
do_logs() {
    echo ""
    echo -e " ${CYAN}${BOLD}Service Logs (${SERVICE_NAME}):${NC}"
    print_line
    journalctl -u "${SERVICE_NAME}" -n 50 --no-pager 2>/dev/null || echo "No logs found."
    echo ""
}

# ─── Main Menu ────────────────────────────────────────────────────
main_menu() {
    while true; do
        print_header
        show_status

        echo -e " ${BOLD}${WHITE}Actions${NC}"
        echo -e "  ${GREEN}1)${NC}  Apply & Install  ${DIM}(optimize NIC, MSS clamping, persist on boot)${NC}"
        echo -e "  ${CYAN}2)${NC}  Show Status"
        echo -e "  ${BLUE}3)${NC}  Dry Run Preview  ${DIM}(show what will change — no actual changes)${NC}"
        echo -e "  ${YELLOW}4)${NC}  Restart Service  ${DIM}(re-apply tuning without reinstalling)${NC}"
        echo -e "  ${CYAN}5)${NC}  View Logs"
        echo -e "  ${RED}6)${NC}  Revert & Remove  ${DIM}(undo all changes, remove service & files)${NC}"
        echo ""
        echo -e "  ${DIM}0)${NC}  Exit"
        echo ""
        read -p "  Select: " choice
        choice="${choice//$'\r'/}"

        case $choice in
            1) do_apply ;;
            2) show_status ;;
            3) do_dryrun ;;
            4) do_restart ;;
            5) do_logs ;;
            6) do_revert ;;
            0) echo -e "\n ${GREEN}Goodbye!${NC}\n"; exit 0 ;;
            *) msg_err "Invalid option." ;;
        esac

        echo ""
        read -p "  Press Enter to continue..."
    done
}

# ─── Entry Point ──────────────────────────────────────────────────
check_root
main_menu
