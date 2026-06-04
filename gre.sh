#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  GRE TUNNEL SETUP (Optimized)                                ║
# ║  Iran & Kharej Setup Script (Multi-Tunnel Support)            ║
# ╚════════════════════════════════════════════════════════════════╝

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

# ─── Helpers ──────────────────────────────────────────────────────
print_line() { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }
print_double_line() { echo -e "${CYAN}════════════════════════════════════════════════════${NC}"; }

print_header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════════╗"
    echo " ║       GRE TUNNEL SETUP (Optimized)            ║"
    echo " ╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

msg_info() { echo -e " ${BLUE}[INFO]${NC} $1"; }
msg_ok()   { echo -e " ${GREEN}[OK]${NC} $1"; }
msg_warn() { echo -e " ${YELLOW}[WARN]${NC} $1"; }
msg_err()  { echo -e " ${RED}[ERR]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        msg_err "This script must be run as root."
        exit 1
    fi
}

# ─── Auto-Detect ──────────────────────────────────────────────────
detect_interface() {
    local iface=""
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    [ -z "$iface" ] && iface=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1)
    [ -z "$iface" ] && iface="eth0"
    echo "$iface"
}

detect_public_ip() {
    local ip="" iface
    iface=$(detect_interface)
    [ -n "$iface" ] && ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip=$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[0-9.]+' | grep -v '^127\.' | head -1)
    echo "$ip"
}

read_input() {
    local prompt="$1" default="$2" var_name="$3"
    local input_val
    if [ -n "$default" ]; then
        read -p "  ${prompt} [${default}]: " input_val
        printf -v "$var_name" "%s" "${input_val:-$default}"
    else
        read -p "  ${prompt}: " input_val
        printf -v "$var_name" "%s" "$input_val"
    fi
}

# ─── Install Prerequisites ───────────────────────────────────────
install_prereqs() {
    echo ""
    msg_info "Checking prerequisites..."
    local need_install=0

    if ! command -v nft &>/dev/null; then
        msg_warn "nftables not found."
        need_install=1
    fi

    if ! modprobe ip_gre 2>/dev/null; then
        msg_warn "ip_gre kernel module not available."
    else
        msg_ok "ip_gre module loaded."
    fi

    if [ $need_install -eq 1 ]; then
        msg_info "Installing nftables..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq nftables iproute2
        elif command -v yum &>/dev/null; then
            yum install -y -q nftables iproute
        elif command -v dnf &>/dev/null; then
            dnf install -y -q nftables iproute
        else
            msg_err "Cannot detect package manager. Install nftables manually."
            return 1
        fi
    fi
    msg_ok "All prerequisites ready."
}

# ─── Generate GRE-UP Script ──────────────────────────────────────
generate_gre_up() {
    local script_path="$1"
    cat > "${script_path}" << GREEOF
#!/usr/bin/env bash
set -e

IF_WAN="${IF_WAN}"
TUN_IF="${TUN_IF}"

LOCAL_REAL="${LOCAL_REAL}"
REMOTE_REAL="${REMOTE_REAL}"

LOCAL_SPOOF="${LOCAL_SPOOF}"
REMOTE_SPOOF="${REMOTE_SPOOF}"

LOCAL_TUN="${LOCAL_TUN}"
GRE_KEY="${GRE_KEY}"
FOU_ENABLE="${FOU_ENABLE}"
FOU_PORT="${FOU_PORT}"

NFT_TABLE="fw_${TUNNEL_ID}"

# ── Security: rp_filter on all + required interfaces ──
# NOTE: Linux uses max(conf.all, conf.iface), so conf.all MUST also be 0
sysctl -w net.ipv4.conf.all.rp_filter=0     >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
for iface in \${IF_WAN}; do
    sysctl -w net.ipv4.conf.\${iface}.rp_filter=0 >/dev/null 2>&1 || true
done

# ── Security: Network hardening ──
sysctl -w net.ipv4.ip_forward=1                              >/dev/null
sysctl -w net.ipv4.conf.all.accept_redirects=0               >/dev/null
sysctl -w net.ipv4.conf.all.send_redirects=0                 >/dev/null
sysctl -w net.ipv4.conf.all.accept_source_route=0            >/dev/null
sysctl -w net.ipv4.conf.default.accept_redirects=0           >/dev/null
sysctl -w net.ipv4.conf.default.send_redirects=0             >/dev/null
sysctl -w net.ipv4.conf.default.accept_source_route=0        >/dev/null
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1             >/dev/null
sysctl -w net.ipv4.icmp_ignore_bogus_error_responses=1       >/dev/null
sysctl -w net.ipv4.tcp_syncookies=1                          >/dev/null

# ── Performance: TCP (BBR + buffers) ──
modprobe tcp_bbr 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr  >/dev/null 2>&1 || true
sysctl -w net.core.default_qdisc=fq            >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_mtu_probing=1           >/dev/null
sysctl -w net.ipv4.tcp_mem="1048576 2097152 4194304" >/dev/null
sysctl -w net.ipv4.udp_mem="65536 131072 262144"   >/dev/null
sysctl -w net.core.rmem_default=1048576        >/dev/null
sysctl -w net.core.wmem_default=1048576        >/dev/null
sysctl -w net.core.rmem_max=67108864           >/dev/null
sysctl -w net.core.wmem_max=67108864           >/dev/null
sysctl -w net.core.optmem_max=25165824         >/dev/null
sysctl -w net.ipv4.tcp_rmem="8192 1048576 67108864" >/dev/null
sysctl -w net.ipv4.tcp_wmem="8192 1048576 67108864" >/dev/null
sysctl -w net.ipv4.udp_rmem_min=16384          >/dev/null
sysctl -w net.ipv4.udp_wmem_min=16384          >/dev/null
sysctl -w net.ipv4.tcp_adv_win_scale=1         >/dev/null
sysctl -w net.ipv4.tcp_fastopen=3              >/dev/null
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null
sysctl -w net.ipv4.tcp_notsent_lowat=16384     >/dev/null
sysctl -w net.ipv4.ipfrag_high_thresh=67108864 >/dev/null
sysctl -w net.ipv4.ipfrag_low_thresh=33554432  >/dev/null
sysctl -w net.ipv4.ipfrag_time=60              >/dev/null
sysctl -w net.core.netdev_max_backlog=250000   >/dev/null
sysctl -w net.core.netdev_budget=600           >/dev/null
sysctl -w net.core.netdev_budget_usecs=8000    >/dev/null

# ── Performance: Max connections & bandwidth ──
modprobe nf_conntrack 2>/dev/null || true
sysctl -w fs.file-max=2097152                          >/dev/null
sysctl -w fs.nr_open=2097152                           >/dev/null
sysctl -w net.core.somaxconn=250000                    >/dev/null
sysctl -w net.ipv4.tcp_max_syn_backlog=250000          >/dev/null
sysctl -w net.ipv4.ip_local_port_range="1024 65535"    >/dev/null
sysctl -w net.ipv4.tcp_tw_reuse=1                      >/dev/null
sysctl -w net.ipv4.tcp_fin_timeout=15                  >/dev/null
sysctl -w net.ipv4.tcp_keepalive_time=300              >/dev/null
sysctl -w net.ipv4.tcp_keepalive_intvl=15              >/dev/null
sysctl -w net.ipv4.tcp_keepalive_probes=5              >/dev/null
sysctl -w net.ipv4.tcp_max_tw_buckets=2000000          >/dev/null
sysctl -w net.ipv4.tcp_window_scaling=1                >/dev/null
sysctl -w net.ipv4.tcp_sack=1                          >/dev/null
sysctl -w net.ipv4.tcp_no_metrics_save=1               >/dev/null
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1               >/dev/null
sysctl -w net.netfilter.nf_conntrack_max=2097152       >/dev/null 2>&1 || true
echo 524288 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
ulimit -n 1048576 2>/dev/null || true

# ── GRE Tunnel ──
modprobe ip_gre || true

ip tunnel del \${TUN_IF} 2>/dev/null || true
ip link del \${TUN_IF}   2>/dev/null || true

if [ "\${FOU_ENABLE}" = "yes" ]; then
    modprobe fou 2>/dev/null || true
    ip fou add port \${FOU_PORT} ipproto 47 2>/dev/null || true
    ip link add name \${TUN_IF} type gre local \${LOCAL_REAL} remote \${REMOTE_REAL} ttl 64 key \${GRE_KEY} encap fou encap-sport auto encap-dport \${FOU_PORT}
    MTU=1392
    MSS=1352
else
    ip link add name \${TUN_IF} type gre local \${LOCAL_REAL} remote \${REMOTE_REAL} ttl 64 key \${GRE_KEY}
    MTU=1400
    MSS=1360
fi

ip addr add \${LOCAL_TUN} dev \${TUN_IF}
ip link set \${TUN_IF} mtu \${MTU}
ip link set \${TUN_IF} txqueuelen 10000
ip link set \${TUN_IF} up

# Keepalive: detect dead peer (every 10s, 3 retries)
ip tunnel change \${TUN_IF} keepalive 10 3 2>/dev/null || true

# Disable IPv6 on tunnel (prevent leaks)
sysctl -w net.ipv6.conf.\${TUN_IF}.disable_ipv6=1 >/dev/null 2>&1 || true
# Scoped rp_filter for tunnel interface
sysctl -w net.ipv4.conf.\${TUN_IF}.rp_filter=0    >/dev/null 2>&1 || true

# ── Qdisc: Fair Queue ──
tc qdisc replace dev \${IF_WAN} root fq 2>/dev/null || true
tc qdisc replace dev \${TUN_IF} root fq 2>/dev/null || true

# ── RPS & RFS: distribute across cores ──
CORES=\$(nproc 2>/dev/null || echo 1)
if [ "\${CORES}" -gt 1 ]; then
    RPS_MASK=\$(printf '%x' \$(( (1 << CORES) - 1 )))
    for q in /sys/class/net/\${IF_WAN}/queues/rx-*/rps_cpus; do
        [ -f "\${q}" ] && echo \${RPS_MASK} > "\${q}" 2>/dev/null || true
    done
    for q in /sys/class/net/\${IF_WAN}/queues/rx-*/rps_flow_cnt; do
        [ -f "\${q}" ] && echo 32768 > "\${q}" 2>/dev/null || true
    done
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
fi

# ── nftables ──
nft delete table ip \${NFT_TABLE} 2>/dev/null || true
nft add table ip \${NFT_TABLE}

# Note: Invalid GRE packets are dropped naturally by the kernel GRE stack if IP/keys don't match.
# Do not add global drop rules on input hook here to avoid breaking multiple tunnels.

# Spoof chains
nft add chain ip \${NFT_TABLE} prerouting  '{ type filter hook prerouting  priority -300 ; }'
nft add chain ip \${NFT_TABLE} postrouting '{ type filter hook postrouting priority  300 ; }'

if [ "\${FOU_ENABLE}" = "yes" ]; then
    # Inbound FOU: match UDP dport
    nft add rule ip \${NFT_TABLE} prerouting  iif "\${IF_WAN}" ip saddr \${REMOTE_SPOOF} udp dport \${FOU_PORT} ip saddr set \${REMOTE_REAL} notrack
    # Outbound FOU: match UDP dport
    nft add rule ip \${NFT_TABLE} postrouting oif "\${IF_WAN}" ip daddr \${REMOTE_REAL}  udp dport \${FOU_PORT} ip saddr set \${LOCAL_SPOOF} notrack
else
    # Inbound RAW: match Protocol 47
    nft add rule ip \${NFT_TABLE} prerouting  iif "\${IF_WAN}" ip protocol gre ip saddr \${REMOTE_SPOOF} ip saddr set \${REMOTE_REAL} notrack
    # Outbound RAW: match Protocol 47
    nft add rule ip \${NFT_TABLE} postrouting oif "\${IF_WAN}" ip protocol gre ip daddr \${REMOTE_REAL}  ip saddr set \${LOCAL_SPOOF} notrack
fi

# MSS Clamping (prevent fragmentation for TCP through tunnel)
nft add chain ip \${NFT_TABLE} fwd_mss '{ type filter hook forward priority 0 ; }'
nft add rule  ip \${NFT_TABLE} fwd_mss oif "\${TUN_IF}" tcp flags syn tcp option maxseg size set \${MSS}
nft add rule  ip \${NFT_TABLE} fwd_mss iif "\${TUN_IF}" tcp flags syn tcp option maxseg size set \${MSS}

echo "GRE tunnel \${TUN_IF} UP (table: \${NFT_TABLE})"
GREEOF
    chmod +x "${script_path}"
}

# ─── Generate GRE-DOWN Script ────────────────────────────────────
generate_gre_down() {
    local script_path="$1"
    cat > "${script_path}" << GREEOF
#!/usr/bin/env bash
set -e
TUN_IF="${TUN_IF}"
NFT_TABLE="fw_${TUNNEL_ID}"
FOU_ENABLE="${FOU_ENABLE}"
FOU_PORT="${FOU_PORT}"

ip tunnel del \${TUN_IF} 2>/dev/null || true
ip link del \${TUN_IF}   2>/dev/null || true
nft delete table ip \${NFT_TABLE} 2>/dev/null || true

if [ "\${FOU_ENABLE}" = "yes" ]; then
    # We do NOT delete the FOU port here because other tunnels might be sharing it.
    # The FOU listening port has near-zero overhead.
    true
fi
echo "GRE tunnel \${TUN_IF} DOWN (table: \${NFT_TABLE})"
GREEOF
    chmod +x "${script_path}"
}

# ─── Generate Watchdog Script ─────────────────────────────────────
generate_watchdog() {
    local script_path="$1"
    cat > "${script_path}" << WDEOF
#!/usr/bin/env bash
TUN_IF="${TUN_IF}"
REMOTE_TUN="${REMOTE_TUN}"
SERVICE="gre-tunnel-${TUNNEL_ID}"
MAX_FAIL=3
FAIL_FILE="/tmp/.wd_\${TUN_IF}"
LOG_TAG="wd-\${TUN_IF}"

# Skip if service is disabled
systemctl is-enabled "\${SERVICE}" &>/dev/null || exit 0

# Check interface exists
if ! ip link show \${TUN_IF} &>/dev/null; then
    logger -t "\${LOG_TAG}" "Interface \${TUN_IF} missing - restarting \${SERVICE}"
    systemctl restart "\${SERVICE}"
    exit 0
fi

# Ping remote tunnel endpoint
if ping -c 3 -i 1 -W 2 -I \${TUN_IF} \${REMOTE_TUN} &>/dev/null; then
    echo 0 > "\${FAIL_FILE}" 2>/dev/null
    exit 0
fi

# Track consecutive failures
FAILS=\$(cat "\${FAIL_FILE}" 2>/dev/null || echo 0)
FAILS=\$((FAILS + 1))
echo "\${FAILS}" > "\${FAIL_FILE}"

if [ "\${FAILS}" -ge "\${MAX_FAIL}" ]; then
    logger -t "\${LOG_TAG}" "Tunnel \${TUN_IF} DOWN after \${FAILS} failures - restarting \${SERVICE}"
    systemctl restart "\${SERVICE}"
    echo 0 > "\${FAIL_FILE}"
else
    logger -t "\${LOG_TAG}" "Tunnel \${TUN_IF} ping failed (\${FAILS}/\${MAX_FAIL})"
fi
WDEOF
    chmod +x "${script_path}"
}

# ─── Create Watchdog Timer ────────────────────────────────────────
create_watchdog_timer() {
    local tunnel_id="$1" wd_script="$2"
    local svc="gre-watchdog-${tunnel_id}"

    cat > "${SYSTEMD_DIR}/${svc}.service" << EOF
[Unit]
Description=GRE Tunnel ${tunnel_id} Watchdog Check

[Service]
Type=oneshot
ExecStart=${wd_script}
EOF

    cat > "${SYSTEMD_DIR}/${svc}.timer" << EOF
[Unit]
Description=GRE Tunnel ${tunnel_id} Watchdog Timer

[Timer]
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=5

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable "${svc}.timer" &>/dev/null
    systemctl start "${svc}.timer"
}

# ─── Create Systemd Service ──────────────────────────────────────
create_gre_service() {
    local service_name="$1" up_script="$2" down_script="$3" description="$4"
    local service_path="${SYSTEMD_DIR}/${service_name}.service"

    cat > "${service_path}" << EOF
[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${up_script}
ExecStop=${down_script}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}" &>/dev/null
    systemctl start "${service_name}"
}

# ─── Review Box ───────────────────────────────────────────────────
show_gre_review() {
    local role="$1"
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  REVIEW YOUR GRE SETTINGS${NC}"
    print_double_line
    echo ""
    echo -e "  ${MAGENTA}Tunnel ID:${NC}       ${WHITE}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "  ${MAGENTA}Role:${NC}            ${WHITE}${BOLD}${role}${NC}"
    echo -e "  ${MAGENTA}Interface:${NC}       ${WHITE}${BOLD}${IF_WAN}${NC}  ${DIM}(auto-detected)${NC}"
    echo -e "  ${MAGENTA}Tunnel Dev:${NC}      ${WHITE}${BOLD}${TUN_IF}${NC}"
    echo -e "  ${MAGENTA}GRE Key:${NC}         ${WHITE}${BOLD}${GRE_KEY}${NC}  ${DIM}(must match both sides)${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Real IPs (GRE Endpoints):${NC}"
    echo -e "    Local:   ${GREEN}${BOLD}${LOCAL_REAL}${NC}"
    echo -e "    Remote:  ${BLUE}${BOLD}${REMOTE_REAL}${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Spoof IPs (nftables):${NC}"
    echo -e "    Local Spoof:   ${MAGENTA}${BOLD}${LOCAL_SPOOF}${NC}"
    echo -e "    Remote Spoof:  ${MAGENTA}${BOLD}${REMOTE_SPOOF}${NC}"
    echo ""
    local show_mtu="1400"
    [ "$FOU_ENABLE" = "yes" ] && show_mtu="1392"
    print_line
    echo -e "  ${CYAN}Tunnel Network:${NC}"
    echo -e "    Local TUN:  ${GREEN}${BOLD}${LOCAL_TUN}${NC}  ${DIM}(MTU: ${show_mtu})${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Optimizations:${NC}"
    if [ "$FOU_ENABLE" = "yes" ]; then
        echo -e "    ${GREEN}✓${NC} FOU Stealth Mode (UDP Port ${FOU_PORT})"
    fi
    echo -e "    ${GREEN}✓${NC} BBR congestion control"
    echo -e "    ${GREEN}✓${NC} MSS Clamping (dynamic)"
    echo -e "    ${GREEN}✓${NC} GRE Firewall (whitelist)"
    echo -e "    ${GREEN}✓${NC} Keepalive (10s × 3)"
    echo -e "    ${GREEN}✓${NC} Fair Queue (fq)"
    echo ""
    echo -e "  ${CYAN}nftables Table:${NC} ${WHITE}fw_${TUNNEL_ID}${NC}"
    echo ""
    print_double_line
    echo ""
}

# ─── Setup Iran ───────────────────────────────────────────────────
setup_iran() {
    print_header
    echo -e " ${GREEN}${BOLD}>>> Setup Iran Server${NC}"
    echo ""
    print_line

    IF_WAN=$(detect_interface)
    local AUTO_IP=$(detect_public_ip)

    echo -e "\n ${MAGENTA}${BOLD}[1/3] Tunnel Identity${NC}"
    read_input "Tunnel ID (e.g. 10, 20, 30)" "" TUNNEL_ID
    [ -z "$TUNNEL_ID" ] && { msg_err "Tunnel ID required!"; return; }
    if ! [[ "$TUNNEL_ID" =~ ^[0-9]+$ ]] || [ "$TUNNEL_ID" -lt 1 ] || [ "$TUNNEL_ID" -gt 255 ]; then
        msg_err "Tunnel ID must be a number between 1 and 255!"; return
    fi
    TUN_IF="gre${TUNNEL_ID}"
    GRE_KEY="${TUNNEL_ID}"

    echo -e "\n ${MAGENTA}${BOLD}[2/3] Network${NC}"
    msg_info "Interface auto-detected: ${BOLD}${IF_WAN}${NC}"
    read_input "Change interface? (Enter to keep)" "${IF_WAN}" IF_WAN
    [ -n "$AUTO_IP" ] && msg_info "Public IP auto-detected: ${BOLD}${AUTO_IP}${NC}"

    read_input "This server's REAL IP" "${AUTO_IP}" LOCAL_REAL
    [ -z "$LOCAL_REAL" ] && { msg_err "Local real IP required!"; return; }
    read_input "Remote server's REAL IP (Kharej)" "" REMOTE_REAL
    [ -z "$REMOTE_REAL" ] && { msg_err "Remote real IP required!"; return; }

    echo -e "\n ${MAGENTA}${BOLD}[3/3] Spoof IPs${NC}"
    msg_info "These are fake IPs used by nftables to disguise GRE traffic."
    read_input "Local Spoof IP (fake source for outbound)" "" LOCAL_SPOOF
    [ -z "$LOCAL_SPOOF" ] && { msg_err "Local spoof IP required!"; return; }
    read_input "Remote Spoof IP (fake source from remote)" "" REMOTE_SPOOF
    [ -z "$REMOTE_SPOOF" ] && { msg_err "Remote spoof IP required!"; return; }

    LOCAL_TUN="10.88.${TUNNEL_ID}.1/30"
    REMOTE_TUN="10.88.${TUNNEL_ID}.2"

    echo -e "\n ${MAGENTA}${BOLD}[4/5] GRE Key${NC}"
    msg_info "GRE Key must be identical on both sides."
    read_input "GRE Key" "${TUNNEL_ID}" GRE_KEY

    echo -e "\n ${MAGENTA}${BOLD}[5/5] Stealth Mode (FOU)${NC}"
    msg_info "Encapsulates GRE in UDP to evade DPI detection."
    read_input "Enable FOU Stealth Mode? (y/n)" "y" FOU_ENABLE
    if [[ "$FOU_ENABLE" =~ ^[Yy] ]]; then
        FOU_ENABLE="yes"
        read_input "FOU UDP Port" "443" FOU_PORT
    else
        FOU_ENABLE="no"
        FOU_PORT=""
    fi

    show_gre_review "Iran"

    read -p "  Proceed? (Y/n): " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { msg_warn "Cancelled."; return; }

    echo ""
    local up_script="${SCRIPTS_DIR}/gre${TUNNEL_ID}-up.sh"
    local down_script="${SCRIPTS_DIR}/gre${TUNNEL_ID}-down.sh"
    local service_name="gre-tunnel-${TUNNEL_ID}"

    generate_gre_up "${up_script}"
    msg_ok "Up script: ${up_script}"

    generate_gre_down "${down_script}"
    msg_ok "Down script: ${down_script}"

    create_gre_service "${service_name}" "${up_script}" "${down_script}" "GRE Tunnel ${TUNNEL_ID} - Iran"
    msg_ok "Service created and started: ${service_name}"

    local wd_script="${SCRIPTS_DIR}/gre${TUNNEL_ID}-watchdog.sh"
    generate_watchdog "${wd_script}"
    create_watchdog_timer "${TUNNEL_ID}" "${wd_script}"
    msg_ok "Watchdog timer started (every 30s)"

    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Iran GRE Tunnel ${TUNNEL_ID} Setup Complete!${NC}"
    print_double_line
    echo ""
    echo -e "  ${YELLOW}${BOLD}For Kharej setup, use:${NC}"
    echo -e "    Tunnel ID:    ${CYAN}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "    GRE Key:      ${CYAN}${BOLD}${GRE_KEY}${NC}  (must match!)"
    echo -e "    Remote IP:    ${CYAN}${BOLD}${LOCAL_REAL}${NC}"
    echo -e "    Spoof Local:  ${CYAN}${BOLD}${REMOTE_SPOOF}${NC}  (swap!)"
    echo -e "    Spoof Remote: ${CYAN}${BOLD}${LOCAL_SPOOF}${NC}  (swap!)"
    echo ""
    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

# ─── Setup Kharej ─────────────────────────────────────────────────
setup_kharej() {
    print_header
    echo -e " ${GREEN}${BOLD}>>> Setup Kharej Server${NC}"
    echo ""
    print_line

    IF_WAN=$(detect_interface)
    local AUTO_IP=$(detect_public_ip)

    echo -e "\n ${MAGENTA}${BOLD}[1/3] Tunnel Identity${NC}"
    read_input "Tunnel ID (must match Iran, e.g. 10, 20)" "" TUNNEL_ID
    [ -z "$TUNNEL_ID" ] && { msg_err "Tunnel ID required!"; return; }
    if ! [[ "$TUNNEL_ID" =~ ^[0-9]+$ ]] || [ "$TUNNEL_ID" -lt 1 ] || [ "$TUNNEL_ID" -gt 255 ]; then
        msg_err "Tunnel ID must be a number between 1 and 255!"; return
    fi
    TUN_IF="gre${TUNNEL_ID}"
    GRE_KEY="${TUNNEL_ID}"

    echo -e "\n ${MAGENTA}${BOLD}[2/3] Network${NC}"
    msg_info "Interface auto-detected: ${BOLD}${IF_WAN}${NC}"
    read_input "Change interface? (Enter to keep)" "${IF_WAN}" IF_WAN
    [ -n "$AUTO_IP" ] && msg_info "Public IP auto-detected: ${BOLD}${AUTO_IP}${NC}"

    read_input "This server's REAL IP" "${AUTO_IP}" LOCAL_REAL
    [ -z "$LOCAL_REAL" ] && { msg_err "Local real IP required!"; return; }
    read_input "Remote server's REAL IP (Iran)" "" REMOTE_REAL
    [ -z "$REMOTE_REAL" ] && { msg_err "Remote real IP required!"; return; }

    echo -e "\n ${MAGENTA}${BOLD}[3/3] Spoof IPs${NC}"
    msg_info "These should be SWAPPED from Iran side."
    read_input "Local Spoof IP (Iran's Remote Spoof)" "" LOCAL_SPOOF
    [ -z "$LOCAL_SPOOF" ] && { msg_err "Local spoof IP required!"; return; }
    read_input "Remote Spoof IP (Iran's Local Spoof)" "" REMOTE_SPOOF
    [ -z "$REMOTE_SPOOF" ] && { msg_err "Remote spoof IP required!"; return; }

    LOCAL_TUN="10.88.${TUNNEL_ID}.2/30"
    REMOTE_TUN="10.88.${TUNNEL_ID}.1"

    echo -e "\n ${MAGENTA}${BOLD}[4/5] GRE Key${NC}"
    msg_info "GRE Key must match the Iran side."
    read_input "GRE Key" "${TUNNEL_ID}" GRE_KEY

    echo -e "\n ${MAGENTA}${BOLD}[5/5] Stealth Mode (FOU)${NC}"
    msg_info "Encapsulates GRE in UDP to evade DPI detection."
    read_input "Enable FOU Stealth Mode? (y/n)" "y" FOU_ENABLE
    if [[ "$FOU_ENABLE" =~ ^[Yy] ]]; then
        FOU_ENABLE="yes"
        read_input "FOU UDP Port" "443" FOU_PORT
    else
        FOU_ENABLE="no"
        FOU_PORT=""
    fi

    show_gre_review "Kharej"

    read -p "  Proceed? (Y/n): " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { msg_warn "Cancelled."; return; }

    echo ""
    local up_script="${SCRIPTS_DIR}/gre${TUNNEL_ID}-up.sh"
    local down_script="${SCRIPTS_DIR}/gre${TUNNEL_ID}-down.sh"
    local service_name="gre-tunnel-${TUNNEL_ID}"

    generate_gre_up "${up_script}"
    msg_ok "Up script: ${up_script}"

    generate_gre_down "${down_script}"
    msg_ok "Down script: ${down_script}"

    create_gre_service "${service_name}" "${up_script}" "${down_script}" "GRE Tunnel ${TUNNEL_ID} - Kharej"
    msg_ok "Service created and started: ${service_name}"

    local wd_script="${SCRIPTS_DIR}/gre${TUNNEL_ID}-watchdog.sh"
    generate_watchdog "${wd_script}"
    create_watchdog_timer "${TUNNEL_ID}" "${wd_script}"
    msg_ok "Watchdog timer started (every 30s)"

    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Kharej GRE Tunnel ${TUNNEL_ID} Setup Complete!${NC}"
    print_double_line
    echo ""
    echo -e " ${CYAN}Test connectivity:${NC}"
    echo -e "    ping -c 3 10.88.${TUNNEL_ID}.1"
    echo ""
    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

# ─── Watchdog Status ──────────────────────────────────────────────
do_watchdog_status() {
    echo ""
    echo -e " ${CYAN}${BOLD}Watchdog Timers:${NC}"
    print_line

    local found=0
    for timer in $(systemctl list-timers --all --no-legend 2>/dev/null | grep "gre-watchdog-" | awk '{print $NF}'); do
        found=1
        local tname="${timer%.timer}"
        local tid="${tname#gre-watchdog-}"
        local status=$(systemctl is-active "${tname}.timer" 2>/dev/null)
        local fails=$(cat /tmp/.wd_gre${tid} 2>/dev/null || echo 0)
        local last=$(systemctl show "${tname}.timer" --property=LastTriggerUSec --value 2>/dev/null)

        if [ "$status" = "active" ]; then
            echo -e "  ${GREEN}●${NC} ${BOLD}gre${tid}${NC}  ${GREEN}[active]${NC}  fails: ${fails}/3  last: ${last:-never}"
        else
            echo -e "  ${RED}●${NC} ${BOLD}gre${tid}${NC}  ${RED}[${status}]${NC}  fails: ${fails}/3"
        fi
    done

    [ $found -eq 0 ] && msg_warn "No watchdog timers found."
    echo ""
    echo -e " ${DIM}Watchdog checks every 30s, restarts after 3 consecutive failures.${NC}"
    echo ""
}

# ─── Dashboard ────────────────────────────────────────────────────
do_dashboard() {
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  SYSTEM DASHBOARD${NC}"
    print_double_line

    # System info
    local cpu=$(grep 'cpu ' /proc/stat | awk '{u=$2+$4; t=$2+$4+$5; printf "%.1f%%", u/t*100}')
    local mem=$(free -m 2>/dev/null | awk '/Mem:/ {printf "%dMB / %dMB (%.0f%%)", $3, $2, $3/$2*100}')
    local load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    local up=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*//');

    echo ""
    echo -e "  ${MAGENTA}CPU:${NC}     ${BOLD}${cpu}${NC}"
    echo -e "  ${MAGENTA}Memory:${NC}  ${BOLD}${mem}${NC}"
    echo -e "  ${MAGENTA}Load:${NC}    ${BOLD}${load}${NC}"
    echo -e "  ${MAGENTA}Uptime:${NC}  ${BOLD}${up}${NC}"
    echo ""
    print_line

    # Tunnel summary
    local total=0 active=0 down=0
    for svc in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "gre-tunnel-" | awk '{print $1}'); do
        local name="${svc%.service}"
        ((total++))
        [ "$(systemctl is-active "${name}" 2>/dev/null)" = "active" ] && ((active++)) || ((down++))
    done

    echo -e "  ${CYAN}Tunnels:${NC}  Total: ${BOLD}${total}${NC}  ${GREEN}Active: ${active}${NC}  ${RED}Down: ${down}${NC}"
    echo ""

    # Per-tunnel details
    if [ $total -gt 0 ]; then
        printf "  ${DIM}%-4s %-8s %-7s %-16s %-16s %-10s %-10s${NC}\n" "ID" "Role" "Status" "Remote Real" "Tunnel IP" "Traffic" "Watchdog"
        print_line
        for svc in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "gre-tunnel-" | awk '{print $1}'); do
            local name="${svc%.service}"
            local tid="${name#gre-tunnel-}"
            local st=$(systemctl is-active "${name}" 2>/dev/null)
            local tun_if="gre${tid}"

            # Parse script for IPs
            local remote="" tun_ip="" role="?"
            local script="${SCRIPTS_DIR}/gre${tid}-up.sh"
            if [ -f "$script" ]; then
                remote=$(grep '^REMOTE_REAL=' "$script" 2>/dev/null | cut -d'"' -f2)
                tun_ip=$(grep '^LOCAL_TUN=' "$script" 2>/dev/null | cut -d'"' -f2)
                [[ "$tun_ip" == *".1/"* ]] && role="Iran" || role="Kharej"
            fi

            # Traffic
            local rx=$(cat /sys/class/net/${tun_if}/statistics/rx_bytes 2>/dev/null || echo 0)
            local tx=$(cat /sys/class/net/${tun_if}/statistics/tx_bytes 2>/dev/null || echo 0)
            local traffic="$(( (rx+tx) / 1048576 ))MB"

            # Watchdog
            local wd_st=$(systemctl is-active "gre-watchdog-${tid}.timer" 2>/dev/null)
            local fails=$(cat /tmp/.wd_gre${tid} 2>/dev/null || echo 0)
            local wd_info="${wd_st}"
            [ "$fails" -gt 0 ] 2>/dev/null && wd_info="${wd_info}(${fails})"

            # Color
            local st_col="${RED}" wd_col="${DIM}"
            [ "$st" = "active" ] && st_col="${GREEN}"
            [ "$wd_st" = "active" ] && wd_col="${GREEN}"

            printf "  %-4s %-8s ${st_col}%-7s${NC} %-16s %-16s %-10s ${wd_col}%-10s${NC}\n" \
                "$tid" "$role" "$st" "${remote:-?}" "${tun_ip:-?}" "$traffic" "$wd_info"
        done
    fi
    echo ""
}

# ─── Health Check ─────────────────────────────────────────────────
do_health_check() {
    echo ""
    echo -e " ${CYAN}${BOLD}Health Check - Pinging all tunnels...${NC}"
    print_line

    local all_ok=1
    for svc in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "gre-tunnel-" | awk '{print $1}'); do
        local name="${svc%.service}"
        local tid="${name#gre-tunnel-}"
        local tun_if="gre${tid}"
        local script="${SCRIPTS_DIR}/gre${tid}-up.sh"

        # Determine remote tunnel IP
        local tun_ip=""
        if [ -f "$script" ]; then
            local local_tun=$(grep '^LOCAL_TUN=' "$script" 2>/dev/null | cut -d'"' -f2)
            if [[ "$local_tun" == *".1/"* ]]; then
                tun_ip="10.88.${tid}.2"
            else
                tun_ip="10.88.${tid}.1"
            fi
        fi

        if [ -z "$tun_ip" ]; then
            echo -e "  ${YELLOW}●${NC} gre${tid}  ${YELLOW}[skip - no config]${NC}"
            continue
        fi

        if ! ip link show "${tun_if}" &>/dev/null; then
            echo -e "  ${RED}●${NC} gre${tid}  ${RED}[interface missing]${NC}"
            all_ok=0
            continue
        fi

        if ping -c 2 -W 3 -I "${tun_if}" "${tun_ip}" &>/dev/null; then
            local rtt=$(ping -c 1 -W 3 -I "${tun_if}" "${tun_ip}" 2>/dev/null | grep 'time=' | sed 's/.*time=//' | sed 's/ .*//')
            echo -e "  ${GREEN}●${NC} gre${tid} → ${tun_ip}  ${GREEN}[OK]${NC}  ${DIM}${rtt}${NC}"
        else
            echo -e "  ${RED}●${NC} gre${tid} → ${tun_ip}  ${RED}[FAIL]${NC}"
            all_ok=0
        fi
    done

    echo ""
    [ $all_ok -eq 1 ] && msg_ok "All tunnels healthy!" || msg_warn "Some tunnels have issues."
    echo ""
}

# ─── Bulk Operations ─────────────────────────────────────────────
do_restart_all() {
    echo ""
    read -p "  Restart ALL tunnels? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled."; return; }
    for svc in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "gre-tunnel-" | awk '{print $1}'); do
        local name="${svc%.service}"
        systemctl restart "${name}" 2>/dev/null
        msg_ok "${name} restarted."
    done
}

do_stop_all() {
    echo ""
    read -p "  Stop ALL tunnels? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled."; return; }
    for svc in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "gre-tunnel-" | awk '{print $1}'); do
        local name="${svc%.service}"
        systemctl stop "${name}" 2>/dev/null
        msg_ok "${name} stopped."
    done
}

do_start_all() {
    echo ""
    for svc in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "gre-tunnel-" | awk '{print $1}'); do
        local name="${svc%.service}"
        systemctl start "${name}" 2>/dev/null
        msg_ok "${name} started."
    done
}

# ─── Management ───────────────────────────────────────────────────
list_tunnels() {
    echo ""
    echo -e " ${CYAN}${BOLD}Active GRE Tunnels:${NC}"
    print_line

    local found=0 i=1
    TUNNEL_LIST=()

    for svc in $(systemctl list-units --type=service --all --no-legend | grep "gre-tunnel-" | awk '{print $1}'); do
        found=1
        local name="${svc%.service}"
        local tid="${name#gre-tunnel-}"
        local status=$(systemctl is-active "${name}" 2>/dev/null)
        TUNNEL_LIST+=("${name}")

        local remote="" role="?"
        local script="${SCRIPTS_DIR}/gre${tid}-up.sh"
        [ -f "$script" ] && {
            remote=$(grep '^REMOTE_REAL=' "$script" 2>/dev/null | cut -d'"' -f2)
            local lt=$(grep '^LOCAL_TUN=' "$script" 2>/dev/null | cut -d'"' -f2)
            [[ "$lt" == *".1/"* ]] && role="IR" || role="KH"
        }

        if [ "$status" = "active" ]; then
            echo -e "  ${GREEN}●${NC} ${BOLD}${i})${NC} ${name}  ${GREEN}[active]${NC}  ${DIM}${role} → ${remote:-?}${NC}"
        else
            echo -e "  ${RED}●${NC} ${BOLD}${i})${NC} ${name}  ${RED}[${status}]${NC}  ${DIM}${role} → ${remote:-?}${NC}"
        fi
        ((i++))
    done

    [ $found -eq 0 ] && { msg_warn "No GRE tunnels found."; return 1; }
    echo ""
    return 0
}

pick_tunnel() {
    list_tunnels || return 1
    read -p "  Enter number or service name: " pick

    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#TUNNEL_LIST[@]}" ]; then
        SELECTED_TUNNEL="${TUNNEL_LIST[$((pick-1))]}"
    else
        SELECTED_TUNNEL="$pick"
    fi

    if ! systemctl list-units --type=service --all --no-legend | grep -q "${SELECTED_TUNNEL}"; then
        msg_err "Service '${SELECTED_TUNNEL}' not found."
        return 1
    fi
    return 0
}

do_restart() { pick_tunnel || return; systemctl restart "${SELECTED_TUNNEL}"; msg_ok "${SELECTED_TUNNEL} restarted."; }
do_stop()    { pick_tunnel || return; systemctl stop "${SELECTED_TUNNEL}"; msg_ok "${SELECTED_TUNNEL} stopped."; }
do_start()   { pick_tunnel || return; systemctl start "${SELECTED_TUNNEL}"; systemctl enable "${SELECTED_TUNNEL}" &>/dev/null; msg_ok "${SELECTED_TUNNEL} started."; }

do_logs() {
    pick_tunnel || return
    echo ""
    journalctl -u "${SELECTED_TUNNEL}" -n 50 --no-pager
}

do_live_logs() {
    pick_tunnel || return
    msg_info "Live logs for ${SELECTED_TUNNEL} (Ctrl+C to exit):"
    journalctl -u "${SELECTED_TUNNEL}" -f
}

do_status() {
    pick_tunnel || return
    local tid="${SELECTED_TUNNEL#gre-tunnel-}"
    local tun_if="gre${tid}"
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  TUNNEL ${tid} DETAILS${NC}"
    print_double_line

    # Parse config
    local script="${SCRIPTS_DIR}/gre${tid}-up.sh"
    if [ -f "$script" ]; then
        echo ""
        local lr=$(grep '^LOCAL_REAL=' "$script" | cut -d'"' -f2)
        local rr=$(grep '^REMOTE_REAL=' "$script" | cut -d'"' -f2)
        local ls=$(grep '^LOCAL_SPOOF=' "$script" | cut -d'"' -f2)
        local rs=$(grep '^REMOTE_SPOOF=' "$script" | cut -d'"' -f2)
        local lt=$(grep '^LOCAL_TUN=' "$script" | cut -d'"' -f2)
        local gk=$(grep '^GRE_KEY=' "$script" | cut -d'"' -f2)
        local role="Kharej"; [[ "$lt" == *".1/"* ]] && role="Iran"

        echo -e "  ${MAGENTA}Role:${NC}          ${BOLD}${role}${NC}"
        echo -e "  ${MAGENTA}GRE Key:${NC}       ${BOLD}${gk}${NC}"
        echo -e "  ${MAGENTA}Local Real:${NC}    ${GREEN}${lr}${NC}"
        echo -e "  ${MAGENTA}Remote Real:${NC}   ${BLUE}${rr}${NC}"
        echo -e "  ${MAGENTA}Local Spoof:${NC}   ${DIM}${ls}${NC}"
        echo -e "  ${MAGENTA}Remote Spoof:${NC}  ${DIM}${rs}${NC}"
        echo -e "  ${MAGENTA}Tunnel IP:${NC}     ${GREEN}${lt}${NC}"
    fi

    echo ""
    print_line
    echo -e "  ${CYAN}Service:${NC}"
    systemctl is-active "${SELECTED_TUNNEL}" 2>/dev/null | \
        sed "s/active/${GREEN}active${NC}/" | sed "s/inactive/${RED}inactive${NC}/" | \
        while read l; do echo -e "    $l"; done

    # Traffic
    if ip link show "${tun_if}" &>/dev/null; then
        local rx=$(cat /sys/class/net/${tun_if}/statistics/rx_bytes 2>/dev/null || echo 0)
        local tx=$(cat /sys/class/net/${tun_if}/statistics/tx_bytes 2>/dev/null || echo 0)
        echo ""
        print_line
        echo -e "  ${CYAN}Traffic:${NC}"
        echo -e "    RX: ${GREEN}$(( rx / 1048576 )) MB${NC}  TX: ${BLUE}$(( tx / 1048576 )) MB${NC}"
    fi

    # Watchdog
    echo ""
    print_line
    local wd_st=$(systemctl is-active "gre-watchdog-${tid}.timer" 2>/dev/null)
    local fails=$(cat /tmp/.wd_gre${tid} 2>/dev/null || echo 0)
    echo -e "  ${CYAN}Watchdog:${NC}  ${wd_st}  fails: ${fails}/3"

    # nftables
    echo ""
    print_line
    echo -e "  ${CYAN}nftables (fw_${tid}):${NC}"
    nft list table ip "fw_${tid}" 2>/dev/null | head -20 || msg_warn "  Table not found."
    echo ""
}

do_delete() {
    pick_tunnel || return
    echo ""
    echo -e " ${RED}${BOLD}This will permanently delete ${SELECTED_TUNNEL} and its scripts.${NC}"
    read -p "  Type 'DELETE' to confirm: " confirm
    if [ "$confirm" = "DELETE" ]; then
        local tid="${SELECTED_TUNNEL#gre-tunnel-}"
        systemctl stop "${SELECTED_TUNNEL}" 2>/dev/null
        systemctl disable "${SELECTED_TUNNEL}" 2>/dev/null
        systemctl stop "gre-watchdog-${tid}.timer" 2>/dev/null
        systemctl disable "gre-watchdog-${tid}.timer" 2>/dev/null
        rm -f "${SYSTEMD_DIR}/${SELECTED_TUNNEL}.service"
        rm -f "${SYSTEMD_DIR}/gre-watchdog-${tid}.service"
        rm -f "${SYSTEMD_DIR}/gre-watchdog-${tid}.timer"
        rm -f "${SCRIPTS_DIR}/gre${tid}-up.sh"
        rm -f "${SCRIPTS_DIR}/gre${tid}-down.sh"
        rm -f "${SCRIPTS_DIR}/gre${tid}-watchdog.sh"
        rm -f "/tmp/.wd_gre${tid}"
        systemctl daemon-reload
        msg_ok "${SELECTED_TUNNEL}, watchdog, and scripts deleted."
    else
        msg_warn "Cancelled."
    fi
}

do_view_scripts() {
    pick_tunnel || return
    local tid="${SELECTED_TUNNEL#gre-tunnel-}"
    local up="${SCRIPTS_DIR}/gre${tid}-up.sh"
    local down="${SCRIPTS_DIR}/gre${tid}-down.sh"
    echo ""
    if [ -f "$up" ]; then
        echo -e " ${CYAN}${BOLD}Up Script:${NC} ${up}"
        print_line
        cat "$up"
        echo ""
    fi
    if [ -f "$down" ]; then
        echo -e " ${CYAN}${BOLD}Down Script:${NC} ${down}"
        print_line
        cat "$down"
    fi
}

# ─── Main Menu ────────────────────────────────────────────────────
main_menu() {
    while true; do
        print_header
        echo -e " ${BOLD}${WHITE}Overview${NC}"
        echo -e "  ${CYAN}1)${NC}  Dashboard"
        echo -e "  ${GREEN}2)${NC}  Health Check (ping all)"
        echo ""
        echo -e " ${BOLD}${WHITE}Setup${NC}"
        echo -e "  ${GREEN}3)${NC}  Setup Iran Server"
        echo -e "  ${BLUE}4)${NC}  Setup Kharej Server"
        echo ""
        echo -e " ${BOLD}${WHITE}Single Tunnel${NC}"
        echo -e "  ${CYAN}5)${NC}  List Tunnels"
        echo -e "  ${GREEN}6)${NC}  Start a Tunnel"
        echo -e "  ${YELLOW}7)${NC}  Restart a Tunnel"
        echo -e "  ${YELLOW}8)${NC}  Stop a Tunnel"
        echo -e "  ${CYAN}9)${NC}  Tunnel Details"
        echo ""
        echo -e " ${BOLD}${WHITE}Bulk Operations${NC}"
        echo -e "  ${GREEN}10)${NC} Start All Tunnels"
        echo -e "  ${YELLOW}11)${NC} Restart All Tunnels"
        echo -e "  ${YELLOW}12)${NC} Stop All Tunnels"
        echo ""
        echo -e " ${BOLD}${WHITE}Info & Logs${NC}"
        echo -e "  ${CYAN}13)${NC} View Logs"
        echo -e "  ${CYAN}14)${NC} Live Logs"
        echo -e "  ${BLUE}15)${NC} View Scripts"
        echo -e "  ${GREEN}16)${NC} Watchdog Status"
        echo ""
        echo -e " ${BOLD}${WHITE}Danger${NC}"
        echo -e "  ${RED}17)${NC} Delete a Tunnel"
        echo ""
        echo -e " ${BOLD}${WHITE}Install${NC}"
        echo -e "  ${MAGENTA}18)${NC} Install Prerequisites"
        echo ""
        echo -e "  ${DIM}0)${NC}  Exit"
        echo ""
        read -p "  Select: " choice

        case $choice in
            1)  do_dashboard ;;
            2)  do_health_check ;;
            3)  setup_iran ;;
            4)  setup_kharej ;;
            5)  list_tunnels ;;
            6)  do_start ;;
            7)  do_restart ;;
            8)  do_stop ;;
            9)  do_status ;;
            10) do_start_all ;;
            11) do_restart_all ;;
            12) do_stop_all ;;
            13) do_logs ;;
            14) do_live_logs ;;
            15) do_view_scripts ;;
            16) do_watchdog_status ;;
            17) do_delete ;;
            18) install_prereqs ;;
            0)  echo -e "\n ${GREEN}Goodbye!${NC}\n"; exit 0 ;;
            *)  msg_err "Invalid option." ;;
        esac

        echo ""
        read -p "  Press Enter to continue..."
    done
}

# ─── Entry Point ──────────────────────────────────────────────────
check_root
main_menu

