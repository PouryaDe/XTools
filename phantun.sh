#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  FAKETCP / PHANTUN TUNNEL (Anti-UDP Throttling Engine)        ║
# ║  Iran & Kharej Multi-Tunnel with Stateless IP Spoofing        ║
# ║  Converts UDP into High-Speed Fake TCP • Bypasses QoS/Limits   ║
# ╚════════════════════════════════════════════════════════════════╝

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
BIN_CLIENT="/usr/local/bin/phantun_client"
BIN_SERVER="/usr/local/bin/phantun_server"

# ─── UI Helpers ───────────────────────────────────────────────────
print_line() { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }
print_double_line() { echo -e "${CYAN}════════════════════════════════════════════════════${NC}"; }

print_header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════════╗"
    echo " ║     FAKETCP / PHANTUN HIGH-SPEED TUNNEL       ║"
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

# ─── Input & Network Validation Helpers ───────────────────────────
validate_ipv4() {
    local ip="$1"
    local rx='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ ! "$ip" =~ $rx ]]; then
        return 1
    fi
    local IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        if (( 10#$octet < 0 || 10#$octet > 255 )); then
            return 1
        fi
    done
    return 0
}

read_input() {
    local prompt="$1" default="$2" var_name="$3"
    local input_val
    if [ -n "$default" ]; then
        read -p "  ${prompt} [${default}]: " input_val
        input_val="${input_val//$'\r'/}"
        printf -v "$var_name" "%s" "${input_val:-$default}"
    else
        read -p "  ${prompt}: " input_val
        input_val="${input_val//$'\r'/}"
        printf -v "$var_name" "%s" "$input_val"
    fi
}

read_ip() {
    local prompt="$1" default="$2" var_name="$3"
    local val=""
    while true; do
        read_input "$prompt" "$default" val
        val=$(echo "$val" | tr -d '\r\n[:space:]')
        if [ -z "$val" ]; then
            msg_err "IP address is required."
            continue
        fi
        if validate_ipv4 "$val"; then
            printf -v "$var_name" "%s" "$val"
            return 0
        else
            msg_err "Invalid IPv4 address format '${val}'. Try again."
        fi
    done
}

read_port() {
    local prompt="$1" default="$2" var_name="$3"
    local val=""
    while true; do
        read_input "$prompt" "$default" val
        val=$(echo "$val" | tr -d '\r\n[:space:]')
        if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 65535 ]; then
            printf -v "$var_name" "%s" "$val"
            return 0
        else
            msg_err "Invalid port number '${val}'. Must be between 1 and 65535."
        fi
    done
}

detect_interface() {
    local iface=""
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v -E '^(lo|gre.*|ipip.*|gnv.*|vxlan.*|awg.*|xdp.*|ftcp.*|tun.*|tap.*|docker.*|veth.*)$' | head -1)
    fi
    [ -z "$iface" ] && iface="eth0"
    echo "$iface"
}

detect_public_ip() {
    local ip="" iface
    iface=$(detect_interface)
    if [ -n "$iface" ]; then
        ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
    fi
    if [ -z "$ip" ] || [[ "$ip" =~ ^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]]; then
        local ext_ip
        ext_ip=$(curl -s4 --connect-timeout 2 https://api.ipify.org 2>/dev/null || curl -s4 --connect-timeout 2 https://ifconfig.me 2>/dev/null || true)
        if validate_ipv4 "$ext_ip"; then
            ip="$ext_ip"
        fi
    fi
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

# ─── Install Prerequisites & Phantun Binaries ─────────────────────
install_prereqs() {
    echo ""
    msg_info "Checking prerequisites and Phantun Rust binaries..."
    local need_install=0

    for cmd in nft ethtool ping curl tar; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_warn "Required command '${cmd}' not found."
            need_install=1
        fi
    done

    for mod in ipip fou tcp_bbr nf_conntrack; do
        modprobe "$mod" 2>/dev/null || true
    done

    if [ $need_install -eq 1 ]; then
        msg_info "Installing missing dependencies..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq nftables iproute2 iputils-ping ethtool curl tar procps
        elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
            dnf install -y -q nftables iproute iputils ethtool curl tar procps-ng
        fi
    fi

    # Check and download Phantun pre-compiled binaries if missing
    if [ ! -x "${BIN_CLIENT}" ] || [ ! -x "${BIN_SERVER}" ]; then
        msg_info "Downloading high-speed Phantun FakeTCP binaries from GitHub..."
        local arch="x86_64"
        local uname_m; uname_m=$(uname -m)
        [ "$uname_m" = "aarch64" ] && arch="aarch64"

        local tmp_dir; tmp_dir=$(mktemp -d)
        local phantun_ver="v0.8.1"
        local download_url="https://github.com/dndx/phantun/releases/download/${phantun_ver}/phantun_${arch}-unknown-linux-musl.zip"

        msg_info "Fetching ${download_url}..."
        if curl -fsSL --connect-timeout 10 -m 60 "${download_url}" -o "${tmp_dir}/phantun.zip"; then
            if command -v unzip &>/dev/null; then
                unzip -q -o "${tmp_dir}/phantun.zip" -d "${tmp_dir}/"
            elif command -v python3 &>/dev/null; then
                python3 -m zipfile -e "${tmp_dir}/phantun.zip" "${tmp_dir}/" 2>/dev/null || true
            else
                apt-get update -qq && apt-get install -y -qq unzip 2>/dev/null || true
                unzip -q -o "${tmp_dir}/phantun.zip" -d "${tmp_dir}/" 2>/dev/null || true
            fi

            # Support both naming conventions in archive
            local srv_bin; srv_bin=$(find "${tmp_dir}" -type f -name "*phantun*server*" | head -1)
            local cli_bin; cli_bin=$(find "${tmp_dir}" -type f -name "*phantun*client*" | head -1)

            if [ -n "$srv_bin" ] && [ -n "$cli_bin" ]; then
                cp -f "$srv_bin" "${BIN_SERVER}"
                cp -f "$cli_bin" "${BIN_CLIENT}"
                chmod 755 "${BIN_SERVER}" "${BIN_CLIENT}"
                msg_ok "Phantun binaries successfully installed to ${SCRIPTS_DIR}!"
            else
                msg_err "Could not find server/client binaries inside downloaded archive."
            fi
        else
            msg_warn "Direct download failed. Checking if cargo is available to build..."
            if command -v cargo &>/dev/null; then
                msg_info "Compiling phantun via cargo..."
                cargo install phantun --root /usr/local
            else
                msg_err "Could not download Phantun binary. Please verify server internet access or upload phantun_client / phantun_server to /usr/local/bin manually."
                rm -rf "${tmp_dir}"
                return 1
            fi
        fi
        rm -rf "${tmp_dir}"
    fi

    msg_ok "All FakeTCP prerequisites verified."
}

# ─── Generate Phantun Service & Scripts ───────────────────────────
generate_phantun_up() {
    local script_path="$1" role="$2"
    cat > "${script_path}" << PHANEOF
#!/usr/bin/env bash
set -eu

ROLE="${role}"
IF_WAN="${IF_WAN}"
TUN_IF="${TUN_IF}"

LOCAL_REAL="${LOCAL_REAL}"
REMOTE_REAL="${REMOTE_REAL}"

LOCAL_SPOOF="${LOCAL_SPOOF}"
REMOTE_SPOOF="${REMOTE_SPOOF}"

LOCAL_TUN="${LOCAL_TUN}"
FAKE_PORT="${FAKE_PORT}"
LOOP_UDP_PORT="${LOOP_UDP_PORT}"

NFT_TABLE="fw_ftcp_${TUNNEL_ID}"
BIN_CLIENT="${BIN_CLIENT}"
BIN_SERVER="${BIN_SERVER}"
PID_FILE="/tmp/.phantun_${TUNNEL_ID}.pid"

# ── Security: rp_filter on all + required interfaces ──
sysctl -w net.ipv4.conf.all.rp_filter=0     >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
for iface in \${IF_WAN}; do
    sysctl -w net.ipv4.conf.\${iface}.rp_filter=0 >/dev/null 2>&1 || true
done

# ── Security: Network hardening ──
sysctl -w net.ipv4.ip_forward=1                              >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.accept_redirects=0               >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.send_redirects=0                 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.accept_source_route=0            >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.accept_redirects=0           >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.send_redirects=0             >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.accept_source_route=0        >/dev/null 2>&1 || true
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1             >/dev/null 2>&1 || true
sysctl -w net.ipv4.icmp_ignore_bogus_error_responses=1       >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_syncookies=1                          >/dev/null 2>&1 || true

# ── Performance: TCP BBR & Sockets ──
modprobe tcp_bbr 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr  >/dev/null 2>&1 || true
sysctl -w net.core.default_qdisc=fq            >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_mtu_probing=1           >/dev/null 2>&1 || true

sysctl -w net.core.rmem_default=262144         >/dev/null 2>&1 || true
sysctl -w net.core.wmem_default=262144         >/dev/null 2>&1 || true
sysctl -w net.core.rmem_max=16777216           >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=16777216           >/dev/null 2>&1 || true
sysctl -w net.core.optmem_max=2097152          >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" >/dev/null 2>&1 || true
sysctl -w net.ipv4.udp_rmem_min=8192           >/dev/null 2>&1 || true
sysctl -w net.ipv4.udp_wmem_min=8192           >/dev/null 2>&1 || true

# ── Performance: Max connections & bandwidth ──
modprobe nf_conntrack 2>/dev/null || true
sysctl -w fs.file-max=2097152                          >/dev/null 2>&1 || true
sysctl -w fs.nr_open=2097152                           >/dev/null 2>&1 || true
sysctl -w net.core.somaxconn=100000                    >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_max_syn_backlog=100000          >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_local_port_range="1024 65535"    >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_tw_reuse=1                      >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_fin_timeout=15                  >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_keepalive_time=120              >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_max=2097152       >/dev/null 2>&1 || true
ulimit -n 1048576 2>/dev/null || true

# ── Stop any old Phantun instance for this tunnel ──
if [ -f "\$PID_FILE" ]; then
    kill -9 \$(cat "\$PID_FILE" 2>/dev/null) 2>/dev/null || true
    rm -f "\$PID_FILE"
fi

# ── Launch Phantun Binary ──
if [ "\$ROLE" = "Iran" ]; then
    # Client: listens locally for UDP from tunnel, encapsulates into Fake TCP to Remote
    "\$BIN_CLIENT" --local "127.0.0.1:\${LOOP_UDP_PORT}" --remote "\${REMOTE_REAL}:\${FAKE_PORT}" &
    echo \$! > "\$PID_FILE"
else
    # Server: listens on public Fake TCP port, decapsulates and sends UDP to local loop
    "\$BIN_SERVER" --local "0.0.0.0:\${FAKE_PORT}" --remote "127.0.0.1:\${LOOP_UDP_PORT}" &
    echo \$! > "\$PID_FILE"
fi

# ── Setup Kernel Virtual Tunnel Interface (IPIP over Local FOU) ──
modprobe ipip 2>/dev/null || true
modprobe fou 2>/dev/null || true

ip link set dev \${TUN_IF} down 2>/dev/null || true
ip tunnel del \${TUN_IF} 2>/dev/null || true
ip link del \${TUN_IF}   2>/dev/null || true

ip fou add port \${LOOP_UDP_PORT} ipproto 4 2>/dev/null || true
ip link add name \${TUN_IF} type ipip local 127.0.0.1 remote 127.0.0.1 ttl 64 encap fou encap-sport auto encap-dport \${LOOP_UDP_PORT}

MTU=1380
MSS=1340

ip addr replace \${LOCAL_TUN} dev \${TUN_IF} 2>/dev/null || ip addr add \${LOCAL_TUN} dev \${TUN_IF}
ip link set \${TUN_IF} mtu \${MTU}
ip link set \${TUN_IF} txqueuelen 10000
ip link set \${TUN_IF} up

# Disable hardware offload on tunnel to prevent softirq CPU spikes
ethtool -K \${TUN_IF} tso off gso off gro off 2>/dev/null || true

# Route advmss tuning: forces local sockets to clamp MSS automatically
TUN_SUBNET=\$(echo \${LOCAL_TUN} | sed -E 's/\.[0-9]+\//.0\//')
LOCAL_IP_ONLY=\$(echo \${LOCAL_TUN} | cut -d/ -f1)
ip route replace \${TUN_SUBNET} dev \${TUN_IF} proto kernel scope link src \${LOCAL_IP_ONLY} advmss \${MSS} 2>/dev/null || true

# ── nftables: Anti-RST Drop & IP Spoofing ──
nft delete table ip \${NFT_TABLE} 2>/dev/null || true
nft add table ip \${NFT_TABLE}

# Critical: Drop FakeTCP incoming on kernel stack so Linux kernel does not reply with TCP RST!
nft add chain ip \${NFT_TABLE} input '{ type filter hook input priority -100 ; }'
nft add rule  ip \${NFT_TABLE} input iif "\${IF_WAN}" tcp dport \${FAKE_PORT} drop

DO_SPOOF=0
if [ -n "\${LOCAL_SPOOF}" ] && [ -n "\${REMOTE_SPOOF}" ] && { [ "\${LOCAL_SPOOF}" != "\${LOCAL_REAL}" ] || [ "\${REMOTE_SPOOF}" != "\${REMOTE_REAL}" ]; }; then
    DO_SPOOF=1
fi

if [ "\$DO_SPOOF" -eq 1 ]; then
    nft add chain ip \${NFT_TABLE} prerouting  '{ type filter hook prerouting  priority -300 ; }'
    nft add chain ip \${NFT_TABLE} postrouting '{ type filter hook postrouting priority  300 ; }'

    nft add rule ip \${NFT_TABLE} prerouting  iif "\${IF_WAN}" ip saddr \${REMOTE_SPOOF} ip daddr \${LOCAL_REAL} tcp dport \${FAKE_PORT} ip saddr set \${REMOTE_REAL} notrack
    nft add rule ip \${NFT_TABLE} postrouting oif "\${IF_WAN}" ip saddr \${LOCAL_REAL} ip daddr \${REMOTE_REAL} tcp dport \${FAKE_PORT} ip saddr set \${LOCAL_SPOOF} notrack
fi

# MSS Clamping
nft add chain ip \${NFT_TABLE} fwd_mss '{ type filter hook forward priority 0 ; }'
nft add rule  ip \${NFT_TABLE} fwd_mss oif "\${TUN_IF}" tcp flags syn tcp option maxseg size set \${MSS}
nft add rule  ip \${NFT_TABLE} fwd_mss iif "\${TUN_IF}" tcp flags syn tcp option maxseg size set \${MSS}

nft add chain ip \${NFT_TABLE} out_mss '{ type filter hook output priority 0 ; }'
nft add rule  ip \${NFT_TABLE} out_mss oif "\${TUN_IF}" tcp flags syn tcp option maxseg size set \${MSS}

echo "FakeTCP tunnel \${TUN_IF} UP (\${ROLE} Phantun daemon started on port \${FAKE_PORT})"
PHANEOF
    chmod 750 "${script_path}"
}

# ─── Generate Phantun DOWN Script ────────────────────────────────
generate_phantun_down() {
    local script_path="$1"
    cat > "${script_path}" << PHANEOF
#!/usr/bin/env bash
TUN_IF="${TUN_IF}"
LOOP_UDP_PORT="${LOOP_UDP_PORT}"
NFT_TABLE="fw_ftcp_${TUNNEL_ID}"
PID_FILE="/tmp/.phantun_${TUNNEL_ID}.pid"

# Kill Phantun Daemon
if [ -f "\$PID_FILE" ]; then
    kill -9 \$(cat "\$PID_FILE" 2>/dev/null) 2>/dev/null || true
    rm -f "\$PID_FILE"
fi
pkill -9 -f "phantun.*${LOOP_UDP_PORT}" 2>/dev/null || true

ip link set dev \${TUN_IF} down 2>/dev/null || true
ip tunnel del \${TUN_IF} 2>/dev/null || true
ip link del \${TUN_IF}   2>/dev/null || true
nft delete table ip \${NFT_TABLE} 2>/dev/null || true
[ -n "\${LOOP_UDP_PORT}" ] && ip fou del port \${LOOP_UDP_PORT} 2>/dev/null || true

echo "FakeTCP tunnel \${TUN_IF} DOWN"
PHANEOF
    chmod 750 "${script_path}"
}

# ─── Generate Watchdog Script ─────────────────────────────────────
generate_watchdog() {
    local script_path="$1"
    cat > "${script_path}" << WDEOF
#!/usr/bin/env bash
TUN_IF="${TUN_IF}"
REMOTE_TUN="${REMOTE_TUN}"
SERVICE="phantun-tunnel-${TUNNEL_ID}"
MAX_FAIL=3
FAIL_FILE="/tmp/.wd_\${TUN_IF}"
LOG_TAG="wd-\${TUN_IF}"
PID_FILE="/tmp/.phantun_${TUNNEL_ID}.pid"

# Auto-detect REMOTE_TUN if missing
if [ -z "\${REMOTE_TUN}" ]; then
    UP_SCRIPT="/usr/local/bin/ftcp${TUNNEL_ID}-up.sh"
    if [ -f "\$UP_SCRIPT" ]; then
        LT=\$(grep '^LOCAL_TUN=' "\$UP_SCRIPT" 2>/dev/null | cut -d'"' -f2)
        if [[ "\$LT" == *".1/"* ]]; then
            REMOTE_TUN="10.88.${TUNNEL_ID}.2"
        else
            REMOTE_TUN="10.88.${TUNNEL_ID}.1"
        fi
    fi
fi

if ! systemctl is-active "\${SERVICE}" &>/dev/null; then
    exit 0
fi
if ! systemctl is-enabled "\${SERVICE}" &>/dev/null; then
    exit 0
fi

# Check interface and phantun process
if ! ip link show \${TUN_IF} &>/dev/null || [ ! -f "\$PID_FILE" ] || ! kill -0 \$(cat "\$PID_FILE" 2>/dev/null) 2>/dev/null; then
    logger -t "\${LOG_TAG}" "Interface or daemon missing - restarting \${SERVICE}" 2>/dev/null || true
    systemctl restart "\${SERVICE}" 2>/dev/null || true
    systemctl restart "phantun-keepalive-${TUNNEL_ID}" 2>/dev/null || true
    exit 0
fi

if [ -n "\${REMOTE_TUN}" ]; then
    if ping -c 2 -W 2 -I \${TUN_IF} \${REMOTE_TUN} &>/dev/null; then
        echo 0 > "\${FAIL_FILE}" 2>/dev/null
        exit 0
    fi
fi

FAILS=\$(cat "\${FAIL_FILE}" 2>/dev/null | tr -d '[:space:]')
[[ ! "\${FAILS}" =~ ^[0-9]+$ ]] && FAILS=0
FAILS=\$((FAILS + 1))
echo "\${FAILS}" > "\${FAIL_FILE}" 2>/dev/null

if [ "\${FAILS}" -ge "\${MAX_FAIL}" ]; then
    logger -t "\${LOG_TAG}" "Tunnel \${TUN_IF} DOWN after \${FAILS} failures - restarting \${SERVICE}" 2>/dev/null || true
    systemctl restart "\${SERVICE}" 2>/dev/null || true
    systemctl restart "phantun-keepalive-${TUNNEL_ID}" 2>/dev/null || true
    echo 0 > "\${FAIL_FILE}" 2>/dev/null
else
    logger -t "\${LOG_TAG}" "Tunnel \${TUN_IF} ping failed (\${FAILS}/\${MAX_FAIL})" 2>/dev/null || true
fi
WDEOF
    chmod 750 "${script_path}"
}

# ─── Create Systemd Units ─────────────────────────────────────────
create_watchdog_timer() {
    local tunnel_id="$1" wd_script="$2"
    local svc="phantun-watchdog-${tunnel_id}"

    cat > "${SYSTEMD_DIR}/${svc}.service" << EOF
[Unit]
Description=FakeTCP Tunnel ${tunnel_id} Watchdog Check
After=network.target phantun-tunnel-${tunnel_id}.service

[Service]
Type=oneshot
ExecStart=${wd_script}
StandardOutput=journal
StandardError=journal
EOF

    cat > "${SYSTEMD_DIR}/${svc}.timer" << EOF
[Unit]
Description=FakeTCP Tunnel ${tunnel_id} Watchdog Timer

[Timer]
OnBootSec=15
OnUnitActiveSec=10
OnUnitInactiveSec=10
AccuracySec=1

[Install]
WantedBy=timers.target
EOF

    chmod 644 "${SYSTEMD_DIR}/${svc}.service" "${SYSTEMD_DIR}/${svc}.timer"
    systemctl daemon-reload
    systemctl enable "${svc}.timer" &>/dev/null || true
    systemctl start "${svc}.timer" &>/dev/null || true
}

create_phantun_service() {
    local tunnel_id="$1" service_name="$2" up_script="$3" down_script="$4" description="$5"
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
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${service_path}"
    systemctl daemon-reload
    systemctl enable "${service_name}" &>/dev/null || true
    systemctl start "${service_name}" &>/dev/null || true
}

create_keepalive_service() {
    local tunnel_id="$1" tun_if="$2" remote_tun_ip="$3"
    local service_name="phantun-keepalive-${tunnel_id}"
    local service_path="${SYSTEMD_DIR}/${service_name}.service"
    local sleep_offset=$(( tunnel_id % 5 ))

    cat > "${service_path}" << EOF
[Unit]
Description=FakeTCP Tunnel ${tunnel_id} Keep-Alive
After=phantun-tunnel-${tunnel_id}.service
Requires=phantun-tunnel-${tunnel_id}.service
PartOf=phantun-tunnel-${tunnel_id}.service

[Service]
Type=simple
ExecStart=/bin/bash -c 'sleep ${sleep_offset}; while true; do ping -c 1 -W 2 -I ${tun_if} ${remote_tun_ip} >/dev/null 2>&1; sleep 5; done'
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${service_path}"
    systemctl daemon-reload
    systemctl enable "${service_name}" &>/dev/null || true
    systemctl start "${service_name}" &>/dev/null || true
}

# ─── Review Box ───────────────────────────────────────────────────
show_phantun_review() {
    local role="$1"
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  REVIEW YOUR FAKETCP / PHANTUN SETTINGS${NC}"
    print_double_line
    echo ""
    echo -e "  ${MAGENTA}Tunnel ID:${NC}       ${WHITE}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "  ${MAGENTA}Role:${NC}            ${WHITE}${BOLD}${role}${NC}"
    echo -e "  ${MAGENTA}Interface:${NC}       ${WHITE}${BOLD}${IF_WAN}${NC}  ${DIM}(auto-detected)${NC}"
    echo -e "  ${MAGENTA}Tunnel Dev:${NC}      ${WHITE}${BOLD}${TUN_IF}${NC}"
    echo -e "  ${MAGENTA}Fake TCP Port:${NC}   ${WHITE}${BOLD}${FAKE_PORT}${NC}  ${DIM}(TCP on WAN)${NC}"
    echo -e "  ${MAGENTA}Internal UDP:${NC}    ${WHITE}${BOLD}${LOOP_UDP_PORT}${NC}  ${DIM}(127.0.0.1 bridge)${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Real IPs (Endpoints):${NC}"
    echo -e "    Local:   ${GREEN}${BOLD}${LOCAL_REAL}${NC}"
    echo -e "    Remote:  ${BLUE}${BOLD}${REMOTE_REAL}${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Spoof IPs (nftables notrack):${NC}"
    echo -e "    Local Spoof:   ${MAGENTA}${BOLD}${LOCAL_SPOOF}${NC}"
    echo -e "    Remote Spoof:  ${MAGENTA}${BOLD}${REMOTE_SPOOF}${NC}"
    echo ""
    local show_mtu="1380"
    print_line
    echo -e "  ${CYAN}Tunnel Network:${NC}"
    echo -e "    Local TUN:  ${GREEN}${BOLD}${LOCAL_TUN}${NC}  ${DIM}(MTU: ${show_mtu}, MSS: 1340)${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Anti-QoS & Anti-DPI Features:${NC}"
    echo -e "    ${GREEN}✓${NC} Complete UDP-to-FakeTCP Masking (Bypasses UDP rate-limiting)"
    echo -e "    ${GREEN}✓${NC} Anti-RST Kernel Protection (NFTables input drop)"
    echo -e "    ${GREEN}✓${NC} Tokio Async Multi-Threaded Engine (Ultra-low CPU usage)"
    echo -e "    ${GREEN}✓${NC} BBR Congestion Control + FQ Qdisc"
    echo -e "    ${GREEN}✓${NC} Continuous Keep-Alive & Active Watchdog (every 10s)"
    echo ""
    echo -e "  ${CYAN}nftables Table:${NC} ${WHITE}fw_ftcp_${TUNNEL_ID}${NC}"
    echo ""
    print_double_line
    echo ""
}

# ─── Unified Tunnel Setup ─────────────────────────────────────────
setup_phantun_server() {
    local role="$1" # "Iran" or "Kharej"
    print_header
    echo -e " ${GREEN}${BOLD}>>> Setup ${role} Server (FakeTCP / Phantun)${NC}"
    echo ""
    print_line

    install_prereqs || return 1

    IF_WAN=$(detect_interface)
    local AUTO_IP
    AUTO_IP=$(detect_public_ip)

    echo -e "\n ${MAGENTA}${BOLD}[1/4] Tunnel Identity${NC}"
    read_input "Tunnel ID (number between 1 and 255)" "" TUNNEL_ID
    if ! [[ "$TUNNEL_ID" =~ ^[0-9]+$ ]] || [ "$TUNNEL_ID" -lt 1 ] || [ "$TUNNEL_ID" -gt 255 ]; then
        msg_err "Tunnel ID must be a number between 1 and 255!"
        return 1
    fi
    TUN_IF="ftcp${TUNNEL_ID}"
    LOOP_UDP_PORT=$(( 50000 + TUNNEL_ID ))

    # Collision warning
    if [ -f "${SYSTEMD_DIR}/phantun-tunnel-${TUNNEL_ID}.service" ] || ip link show "${TUN_IF}" &>/dev/null; then
        msg_warn "Tunnel ID ${TUNNEL_ID} already exists!"
        read -p "  Do you want to overwrite and reconfigure it? (y/N): " ow_choice
        [[ ! "$ow_choice" =~ ^[Yy]$ ]] && { msg_warn "Cancelled."; return 0; }
        stop_tunnel_services "${TUNNEL_ID}"
    fi

    echo -e "\n ${MAGENTA}${BOLD}[2/4] Network Interfaces & Endpoints${NC}"
    msg_info "Interface auto-detected: ${BOLD}${IF_WAN}${NC}"
    read_input "Change interface? (Enter to keep)" "${IF_WAN}" IF_WAN
    [ -n "$AUTO_IP" ] && msg_info "Public IP auto-detected: ${BOLD}${AUTO_IP}${NC}"

    read_ip "This server's REAL IP" "${AUTO_IP}" LOCAL_REAL
    local remote_label="Remote server's REAL IP (Kharej)"
    [ "$role" = "Kharej" ] && remote_label="Remote server's REAL IP (Iran)"
    read_ip "$remote_label" "" REMOTE_REAL

    while [ "$LOCAL_REAL" = "$REMOTE_REAL" ]; do
        msg_err "Remote IP cannot be identical to Local IP (${LOCAL_REAL})! Please enter the remote server IP."
        read_ip "$remote_label" "" REMOTE_REAL
    done

    echo -e "\n ${MAGENTA}${BOLD}[3/4] Spoof IPs (Optional)${NC}"
    if [ "$role" = "Iran" ]; then
        msg_info "Enter fake/intranet IPs if disguising traffic, or press Enter to use Real IPs."
        read_ip "Local Spoof IP" "${LOCAL_REAL}" LOCAL_SPOOF
        read_ip "Remote Spoof IP" "${REMOTE_REAL}" REMOTE_SPOOF
    else
        msg_info "These should be SWAPPED from the Iran side (or Enter to keep Real IPs)."
        read_ip "Local Spoof IP (Iran's Remote Spoof)" "${LOCAL_REAL}" LOCAL_SPOOF
        read_ip "Remote Spoof IP (Iran's Local Spoof)" "${REMOTE_REAL}" REMOTE_SPOOF
    fi

    if [ "$role" = "Iran" ]; then
        LOCAL_TUN="10.88.${TUNNEL_ID}.1/30"
        REMOTE_TUN="10.88.${TUNNEL_ID}.2"
    else
        LOCAL_TUN="10.88.${TUNNEL_ID}.2/30"
        REMOTE_TUN="10.88.${TUNNEL_ID}.1"
    fi

    echo -e "\n ${MAGENTA}${BOLD}[4/4] Fake TCP Port on WAN${NC}"
    msg_info "This is the TCP port seen by the ISP/firewall (e.g. 443, 8443, 2083)."
    read_port "Fake TCP Port" "443" FAKE_PORT

    show_phantun_review "${role}"

    read -p "  Proceed with installation? (Y/n): " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { msg_warn "Cancelled."; return 0; }

    echo ""
    local up_script="${SCRIPTS_DIR}/ftcp${TUNNEL_ID}-up.sh"
    local down_script="${SCRIPTS_DIR}/ftcp${TUNNEL_ID}-down.sh"
    local service_name="phantun-tunnel-${TUNNEL_ID}"

    generate_phantun_up "${up_script}" "${role}"
    msg_ok "Up script created: ${up_script}"

    generate_phantun_down "${down_script}"
    msg_ok "Down script created: ${down_script}"

    create_phantun_service "${TUNNEL_ID}" "${service_name}" "${up_script}" "${down_script}" "FakeTCP Tunnel ${TUNNEL_ID} - ${role}"
    msg_ok "Tunnel service started: ${service_name}"

    create_keepalive_service "${TUNNEL_ID}" "${TUN_IF}" "${REMOTE_TUN}"
    msg_ok "Keep-alive service started: phantun-keepalive-${TUNNEL_ID}"

    local wd_script="${SCRIPTS_DIR}/ftcp${TUNNEL_ID}-watchdog.sh"
    generate_watchdog "${wd_script}"
    create_watchdog_timer "${TUNNEL_ID}" "${wd_script}"
    msg_ok "Watchdog timer started (every 10s)"

    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  ${role} FakeTCP Tunnel ${TUNNEL_ID} Setup Complete!${NC}"
    print_double_line
    echo ""

    if [ "$role" = "Iran" ]; then
        echo -e "  ${YELLOW}${BOLD}Settings to use for the Kharej side:${NC}"
        echo -e "    Tunnel ID:     ${CYAN}${BOLD}${TUNNEL_ID}${NC}"
        echo -e "    Remote IP:     ${CYAN}${BOLD}${LOCAL_REAL}${NC}"
        echo -e "    Fake TCP Port: ${CYAN}${BOLD}${FAKE_PORT}${NC}"
        echo -e "    Spoof Local:   ${CYAN}${BOLD}${REMOTE_SPOOF}${NC}  (swapped)"
        echo -e "    Spoof Remote:  ${CYAN}${BOLD}${LOCAL_SPOOF}${NC}  (swapped)"
    else
        echo -e " ${CYAN}Test connectivity:${NC}"
        echo -e "    ping -c 3 10.88.${TUNNEL_ID}.1"
    fi
    echo ""
    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

setup_iran()   { setup_phantun_server "Iran"; }
setup_kharej() { setup_phantun_server "Kharej"; }

# ─── Tunnel Discovery Helper ──────────────────────────────────────
get_all_tunnel_ids() {
    local ids=()
    for f in "${SYSTEMD_DIR}"/phantun-tunnel-*.service; do
        [ -f "$f" ] || continue
        local b
        b=$(basename "$f")
        local id="${b#phantun-tunnel-}"
        id="${id%.service}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    for u in $(systemctl list-unit-files "phantun-tunnel-*.service" --no-legend 2>/dev/null | awk '{print $1}'); do
        local id="${u#phantun-tunnel-}"
        id="${id%.service}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done
    for u in $(systemctl list-units --type=service --all "phantun-tunnel-*" --no-legend 2>/dev/null | awk '{print $1}'); do
        local id="${u#phantun-tunnel-}"
        id="${id%.service}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    for f in "${SCRIPTS_DIR}"/ftcp*-up.sh; do
        [ -f "$f" ] || continue
        local b
        b=$(basename "$f")
        local id="${b#ftcp}"
        id="${id%-up.sh}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^ftcp[1-9]' | sed 's/@.*//'); do
        local id="${iface#ftcp}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    for tbl in $(nft list tables 2>/dev/null | grep 'fw_ftcp_' | awk '{print $NF}'); do
        local id="${tbl#fw_ftcp_}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    if [ ${#ids[@]} -gt 0 ]; then
        printf '%s\n' "${ids[@]}" | sort -n -u
    fi
}

# ─── Unified Service Control Helpers ──────────────────────────────
start_tunnel_services() {
    local tid="$1"
    local name="phantun-tunnel-${tid}"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "${name}" 2>/dev/null || true
    systemctl start "${name}" 2>/dev/null || true
    if [ -f "${SYSTEMD_DIR}/phantun-keepalive-${tid}.service" ]; then
        systemctl enable "phantun-keepalive-${tid}" 2>/dev/null || true
        systemctl start "phantun-keepalive-${tid}" 2>/dev/null || true
    fi
    if [ -f "${SYSTEMD_DIR}/phantun-watchdog-${tid}.timer" ]; then
        systemctl enable "phantun-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl start "phantun-watchdog-${tid}.timer" 2>/dev/null || true
    fi
}

stop_tunnel_services() {
    local tid="$1"
    local name="phantun-tunnel-${tid}"
    systemctl stop "phantun-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl stop "phantun-watchdog-${tid}.service" 2>/dev/null || true
    systemctl stop "phantun-keepalive-${tid}" 2>/dev/null || true
    systemctl stop "${name}" 2>/dev/null || true
}

restart_tunnel_services() {
    local tid="$1"
    local name="phantun-tunnel-${tid}"
    systemctl restart "${name}" 2>/dev/null || true
    if [ -f "${SYSTEMD_DIR}/phantun-keepalive-${tid}.service" ]; then
        systemctl restart "phantun-keepalive-${tid}" 2>/dev/null || true
    fi
    if [ -f "${SYSTEMD_DIR}/phantun-watchdog-${tid}.timer" ]; then
        systemctl restart "phantun-watchdog-${tid}.timer" 2>/dev/null || true
    fi
}

# ─── Watchdog Helpers & Management ────────────────────────────────
ensure_watchdog_exists() {
    local tid="$1"
    local up_script="${SCRIPTS_DIR}/ftcp${tid}-up.sh"
    local wd_script="${SCRIPTS_DIR}/ftcp${tid}-watchdog.sh"

    local remote_tun=""
    if [ -f "$up_script" ]; then
        local lt
        lt=$(grep '^LOCAL_TUN=' "$up_script" 2>/dev/null | cut -d'"' -f2)
        if [[ "$lt" == *".1/"* ]]; then
            remote_tun="10.88.${tid}.2"
        else
            remote_tun="10.88.${tid}.1"
        fi
    fi
    [ -z "$remote_tun" ] && remote_tun="10.88.${tid}.2"

    local _saved_tid="${TUNNEL_ID:-}" _saved_tif="${TUN_IF:-}" _saved_rt="${REMOTE_TUN:-}"
    TUN_IF="ftcp${tid}"
    REMOTE_TUN="${remote_tun}"
    TUNNEL_ID="${tid}"

    generate_watchdog "${wd_script}"
    create_watchdog_timer "${tid}" "${wd_script}"

    TUNNEL_ID="${_saved_tid}"
    TUN_IF="${_saved_tif}"
    REMOTE_TUN="${_saved_rt}"
}

do_watchdog_status() {
    echo ""
    echo -e " ${CYAN}${BOLD}Watchdog Timers & Status (FakeTCP):${NC}"
    print_line

    local found=0
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        found=1
        local tname="phantun-watchdog-${tid}"
        local tun_if="ftcp${tid}"
        local svc="phantun-tunnel-${tid}"

        local timer_file="${SYSTEMD_DIR}/${tname}.timer"
        local script_file="${SCRIPTS_DIR}/ftcp${tid}-watchdog.sh"

        local timer_status="not installed"
        local timer_col="${RED}"

        if [ -f "$timer_file" ]; then
            if systemctl is-active "${tname}.timer" &>/dev/null; then
                timer_status="active"
                timer_col="${GREEN}"
            else
                timer_status="inactive"
                timer_col="${YELLOW}"
            fi
        fi

        local fails
        fails=$(cat "/tmp/.wd_${tun_if}" 2>/dev/null || echo 0)

        local next_info=""
        if [ "$timer_status" = "active" ]; then
            local left_str
            left_str=$(systemctl list-timers "${tname}.timer" --no-legend 2>/dev/null | awk '{print $3, $4}')
            [ -n "$left_str" ] && next_info="(next check in ${left_str})"
        fi

        local script_warn=""
        [ ! -x "$script_file" ] && script_warn=" ${RED}[script missing]${NC}"

        local tun_st
        tun_st=$(systemctl is-active "${svc}" 2>/dev/null || echo "inactive")
        local tun_col="${RED}"
        [ "$tun_st" = "active" ] && tun_col="${GREEN}"

        echo -e "  ${timer_col}●${NC} ${BOLD}ftcp${tid}${NC}  Timer: ${timer_col}[${timer_status}]${NC}  Tunnel: ${tun_col}[${tun_st}]${NC}  Fails: ${fails}/3  ${DIM}${next_info}${NC}${script_warn}"
    done

    [ $found -eq 0 ] && msg_warn "No FakeTCP tunnels found."
    echo ""
}

do_watchdog_start() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    ensure_watchdog_exists "${tid}"
    systemctl daemon-reload
    systemctl enable "phantun-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl start "phantun-watchdog-${tid}.timer" 2>/dev/null || true
    msg_ok "Watchdog timer for ftcp${tid} started and enabled (every 10s)."
}

do_watchdog_stop() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    systemctl stop "phantun-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl disable "phantun-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl stop "phantun-watchdog-${tid}.service" 2>/dev/null || true
    msg_ok "Watchdog timer for ftcp${tid} stopped and disabled."
}

do_watchdog_restart() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    ensure_watchdog_exists "${tid}"
    systemctl daemon-reload
    systemctl restart "phantun-watchdog-${tid}.timer" 2>/dev/null || true
    msg_ok "Watchdog timer for ftcp${tid} restarted."
}

do_watchdog_start_all() {
    echo ""
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    [ ${#all_ids[@]} -eq 0 ] && { msg_warn "No tunnels found."; return; }
    for tid in "${all_ids[@]}"; do
        ensure_watchdog_exists "${tid}"
        systemctl enable "phantun-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl start "phantun-watchdog-${tid}.timer" 2>/dev/null || true
        msg_ok "Watchdog ftcp${tid} started."
    done
    systemctl daemon-reload
    msg_ok "All watchdog timers started."
}

do_watchdog_stop_all() {
    echo ""
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    [ ${#all_ids[@]} -eq 0 ] && { msg_warn "No tunnels found."; return; }
    for tid in "${all_ids[@]}"; do
        systemctl stop "phantun-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl disable "phantun-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl stop "phantun-watchdog-${tid}.service" 2>/dev/null || true
        msg_ok "Watchdog ftcp${tid} stopped."
    done
    msg_ok "All watchdog timers stopped."
}

do_watchdog_test() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local tun_if="ftcp${tid}"
    local svc="phantun-tunnel-${tid}"

    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  WATCHDOG DIAGNOSTIC TEST - Tunnel ${tid} (${tun_if})${NC}"
    print_double_line
    echo ""

    echo -n "  1. Tunnel service (${svc}): "
    if systemctl is-active "${svc}" &>/dev/null; then
        echo -e "${GREEN}active${NC}"
    else
        echo -e "${RED}inactive${NC}"
    fi

    echo -n "  2. Network interface (${tun_if}): "
    if ip link show "${tun_if}" &>/dev/null; then
        echo -e "${GREEN}EXISTS (UP)${NC}"
    else
        echo -e "${RED}MISSING${NC}"
    fi

    local up_script="${SCRIPTS_DIR}/ftcp${tid}-up.sh"
    local remote_tun=""
    if [ -f "$up_script" ]; then
        local lt
        lt=$(grep '^LOCAL_TUN=' "$up_script" 2>/dev/null | cut -d'"' -f2)
        [[ "$lt" == *".1/"* ]] && remote_tun="10.88.${tid}.2" || remote_tun="10.88.${tid}.1"
    fi
    echo -e "  3. Remote Tunnel IP: ${CYAN}${remote_tun:-unknown}${NC}"

    if [ -n "$remote_tun" ] && ip link show "${tun_if}" &>/dev/null; then
        echo -e "  4. Executing ping: ping -c 3 -W 2 -I ${tun_if} ${remote_tun}"
        if ping -c 3 -W 2 -I "${tun_if}" "${remote_tun}"; then
            echo -e "     ${GREEN}✓ Ping SUCCESSFUL! FakeTCP connection is healthy.${NC}"
        else
            echo -e "     ${RED}✗ Ping FAILED! Watchdog would increment failure counter.${NC}"
        fi
    else
        echo -e "     ${YELLOW}Cannot ping (interface missing or IP unknown).${NC}"
    fi

    local fails
    fails=$(cat "/tmp/.wd_${tun_if}" 2>/dev/null || echo 0)
    echo ""
    echo -e "  Current failure counter: ${BOLD}${fails} / 3${NC}"

    local timer_st
    timer_st=$(systemctl is-active "phantun-watchdog-${tid}.timer" 2>/dev/null || echo "inactive")
    echo -e "  Timer status: ${BOLD}${timer_st}${NC}"
    echo ""
    print_double_line
}

do_watchdog_logs() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local tun_if="ftcp${tid}"

    echo ""
    echo -e " ${CYAN}${BOLD}Watchdog Service Logs (phantun-watchdog-${tid}):${NC}"
    print_line
    journalctl -u "phantun-watchdog-${tid}.service" -n 25 --no-pager 2>/dev/null || echo "No service logs found."
    echo ""
    echo -e " ${CYAN}${BOLD}Syslog Watchdog Restarts / Alerts (wd-${tun_if}):${NC}"
    print_line
    journalctl -t "wd-${tun_if}" -n 25 --no-pager 2>/dev/null || grep "wd-${tun_if}" /var/log/syslog 2>/dev/null | tail -25 || echo "No syslog events found."
    echo ""
}

do_watchdog_repair_all() {
    echo ""
    msg_info "Reinstalling and fixing Watchdog timers for all FakeTCP tunnels..."
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    [ ${#all_ids[@]} -eq 0 ] && { msg_warn "No tunnels found."; return; }
    for tid in "${all_ids[@]}"; do
        ensure_watchdog_exists "${tid}"
        systemctl enable "phantun-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl restart "phantun-watchdog-${tid}.timer" 2>/dev/null || true
        msg_ok "Watchdog ftcp${tid} re-configured and restarted."
    done
    systemctl daemon-reload
    msg_ok "All watchdog scripts and timers updated and active!"
}

watchdog_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}${BOLD}"
        echo " ╔════════════════════════════════════════════════╗"
        echo " ║       FAKETCP WATCHDOG MANAGEMENT              ║"
        echo " ╚════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e " ${BOLD}${WHITE}Status & Diagnostics${NC}"
        echo -e "  ${CYAN}1)${NC}  Watchdog Status (Overview of all timers)"
        echo -e "  ${GREEN}2)${NC}  Test Watchdog Check (Manual execution & ping)"
        echo -e "  ${BLUE}3)${NC}  View Watchdog Logs"
        echo ""
        echo -e " ${BOLD}${WHITE}Single Tunnel Operations${NC}"
        echo -e "  ${GREEN}4)${NC}  Start / Enable Watchdog"
        echo -e "  ${YELLOW}5)${NC}  Restart Watchdog"
        echo -e "  ${RED}6)${NC}  Stop / Disable Watchdog"
        echo ""
        echo -e " ${BOLD}${WHITE}Bulk Operations${NC}"
        echo -e "  ${GREEN}7)${NC}  Start ALL Watchdogs"
        echo -e "  ${YELLOW}8)${NC}  Restart / Repair ALL Watchdogs"
        echo -e "  ${RED}9)${NC}  Stop ALL Watchdogs"
        echo ""
        echo -e "  ${DIM}0)${NC}  Back to Main Menu"
        echo ""
        read -p "  Select: " wd_choice

        case $wd_choice in
            1) do_watchdog_status ;;
            2) do_watchdog_test ;;
            3) do_watchdog_logs ;;
            4) do_watchdog_start ;;
            5) do_watchdog_restart ;;
            6) do_watchdog_stop ;;
            7) do_watchdog_start_all ;;
            8) do_watchdog_repair_all ;;
            9) do_watchdog_stop_all ;;
            0) return ;;
            *) msg_err "Invalid option." ;;
        esac

        echo ""
        read -p "  Press Enter to continue..."
    done
}

# ─── Dashboard ────────────────────────────────────────────────────
do_dashboard() {
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  SYSTEM DASHBOARD (FakeTCP / Phantun)${NC}"
    print_double_line

    local cpu="0%"
    if [ -r /proc/stat ]; then
        local u1 n1 s1 i1 w1 x1 y1 z1
        local u2 n2 s2 i2 w2 x2 y2 z2
        read -r _ u1 n1 s1 i1 w1 x1 y1 z1 _ < /proc/stat
        sleep 0.1
        read -r _ u2 n2 s2 i2 w2 x2 y2 z2 _ < /proc/stat
        local idle1=$(( i1 + w1 ))
        local idle2=$(( i2 + w2 ))
        local total1=$(( u1 + n1 + s1 + i1 + w1 + x1 + y1 + z1 ))
        local total2=$(( u2 + n2 + s2 + i2 + w2 + x2 + y2 + z2 ))
        local diff_idle=$(( idle2 - idle1 ))
        local diff_total=$(( total2 - total1 ))
        if [ "$diff_total" -gt 0 ]; then
            cpu="$(( (diff_total - diff_idle) * 100 / diff_total ))%"
        fi
    fi
    local mem
    mem=$(free -m 2>/dev/null | awk '/Mem:/ {printf "%dMB / %dMB (%.0f%%)", $3, $2, $3/$2*100}')
    local load
    load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    local up
    up=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*//')

    echo ""
    echo -e "  ${MAGENTA}CPU:${NC}     ${BOLD}${cpu:-N/A}${NC}"
    echo -e "  ${MAGENTA}Memory:${NC}  ${BOLD}${mem:-N/A}${NC}"
    echo -e "  ${MAGENTA}Load:${NC}    ${BOLD}${load:-N/A}${NC}"
    echo -e "  ${MAGENTA}Uptime:${NC}  ${BOLD}${up:-N/A}${NC}"
    echo ""
    print_line

    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    local total=0 active=0 down=0
    for tid in "${all_ids[@]}"; do
        local name="phantun-tunnel-${tid}"
        ((total++))
        [ "$(systemctl is-active "${name}" 2>/dev/null)" = "active" ] && ((active++)) || ((down++))
    done

    echo -e "  ${CYAN}Tunnels:${NC}  Total: ${BOLD}${total}${NC}  ${GREEN}Active: ${active}${NC}  ${RED}Down: ${down}${NC}"
    echo ""

    if [ $total -gt 0 ]; then
        printf "  ${DIM}%-4s %-8s %-7s %-16s %-16s %-10s %-10s %-10s${NC}\n" "ID" "Role" "Status" "Remote Real" "Tunnel IP" "Traffic" "Watchdog" "Keepalive"
        print_line
        for tid in "${all_ids[@]}"; do
            local name="phantun-tunnel-${tid}"
            local st
            st=$(systemctl is-active "${name}" 2>/dev/null || echo "inactive")
            local tun_if="ftcp${tid}"

            local remote="" tun_ip="" role="?"
            local script="${SCRIPTS_DIR}/ftcp${tid}-up.sh"
            if [ -f "$script" ]; then
                remote=$(grep '^REMOTE_REAL=' "$script" 2>/dev/null | cut -d'"' -f2)
                tun_ip=$(grep '^LOCAL_TUN=' "$script" 2>/dev/null | cut -d'"' -f2)
                role=$(grep '^ROLE=' "$script" 2>/dev/null | cut -d'"' -f2)
            fi

            local rx
            rx=$(cat "/sys/class/net/${tun_if}/statistics/rx_bytes" 2>/dev/null || echo 0)
            local tx
            tx=$(cat "/sys/class/net/${tun_if}/statistics/tx_bytes" 2>/dev/null || echo 0)
            local traffic="$(( (rx+tx) / 1048576 ))MB"

            local wd_st
            wd_st=$(systemctl is-active "phantun-watchdog-${tid}.timer" 2>/dev/null || echo "inactive")
            local fails
            fails=$(cat "/tmp/.wd_${tun_if}" 2>/dev/null || echo 0)
            local wd_info="${wd_st}"
            [ "$fails" -gt 0 ] 2>/dev/null && wd_info="${wd_info}(${fails})"

            local ka_st
            ka_st=$(systemctl is-active "phantun-keepalive-${tid}.service" 2>/dev/null || echo "inactive")

            local st_col="${RED}" wd_col="${DIM}" ka_col="${DIM}"
            [ "$st" = "active" ] && st_col="${GREEN}"
            [ "$wd_st" = "active" ] && wd_col="${GREEN}"
            [ "$ka_st" = "active" ] && ka_col="${GREEN}"

            printf "  %-4s %-8s ${st_col}%-7s${NC} %-16s %-16s %-10s ${wd_col}%-10s${NC} ${ka_col}%-10s${NC}\n" \
                "$tid" "${role:-?}" "$st" "${remote:-?}" "${tun_ip:-?}" "$traffic" "$wd_info" "$ka_st"
        done
    fi
    echo ""
}

# ─── Health Check ─────────────────────────────────────────────────
do_health_check() {
    echo ""
    echo -e " ${CYAN}${BOLD}Health Check - Pinging all FakeTCP tunnels...${NC}"
    print_line

    local all_ok=1
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        local tun_if="ftcp${tid}"
        local script="${SCRIPTS_DIR}/ftcp${tid}-up.sh"

        local tun_ip=""
        if [ -f "$script" ]; then
            local local_tun
            local_tun=$(grep '^LOCAL_TUN=' "$script" 2>/dev/null | cut -d'"' -f2)
            if [[ "$local_tun" == *".1/"* ]]; then
                tun_ip="10.88.${tid}.2"
            else
                tun_ip="10.88.${tid}.1"
            fi
        fi

        if [ -z "$tun_ip" ]; then
            echo -e "  ${YELLOW}●${NC} ftcp${tid}  ${YELLOW}[skip - no config]${NC}"
            continue
        fi

        if ! ip link show "${tun_if}" &>/dev/null; then
            echo -e "  ${RED}●${NC} ftcp${tid}  ${RED}[interface missing]${NC}"
            all_ok=0
            continue
        fi

        local ping_out ping_rc
        ping_out=$(ping -c 2 -W 2 -I "${tun_if}" "${tun_ip}" 2>&1)
        ping_rc=$?
        if [ $ping_rc -eq 0 ]; then
            local rtt
            rtt=$(echo "$ping_out" | awk -F'/' '/rtt|round-trip/ {print $5 " ms"}')
            [ -z "$rtt" ] && rtt=$(echo "$ping_out" | grep 'time=' | head -1 | sed -E 's/.*time=([^ ]+).*/\1 ms/')
            echo -e "  ${GREEN}●${NC} ftcp${tid} → ${tun_ip}  ${GREEN}[OK]${NC}  ${DIM}${rtt}${NC}"
        else
            echo -e "  ${RED}●${NC} ftcp${tid} → ${tun_ip}  ${RED}[FAIL]${NC}"
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
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        restart_tunnel_services "${tid}"
        msg_ok "Tunnel ${tid}, keep-alive, and watchdog restarted."
    done
}

do_stop_all() {
    echo ""
    read -p "  Stop ALL tunnels? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { msg_warn "Cancelled."; return; }
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        stop_tunnel_services "${tid}"
        msg_ok "Tunnel ${tid} and all its services stopped."
    done
}

do_start_all() {
    echo ""
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        start_tunnel_services "${tid}"
        msg_ok "Tunnel ${tid}, keep-alive, and watchdog started."
    done
}

# ─── Management ───────────────────────────────────────────────────
list_tunnels() {
    echo ""
    echo -e " ${CYAN}${BOLD}Detected FakeTCP Tunnels:${NC}"
    print_line

    local found=0 i=1
    TUNNEL_LIST=()
    TUNNEL_ID_LIST=()

    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        found=1
        local name="phantun-tunnel-${tid}"
        local tun_if="ftcp${tid}"
        local status
        status=$(systemctl is-active "${name}" 2>/dev/null || echo "inactive")
        TUNNEL_LIST+=("${name}")
        TUNNEL_ID_LIST+=("${tid}")

        local remote="" role="?" fake_port=""
        local script="${SCRIPTS_DIR}/ftcp${tid}-up.sh"
        if [ -f "$script" ]; then
            remote=$(grep '^REMOTE_REAL=' "$script" 2>/dev/null | cut -d'"' -f2)
            role=$(grep '^ROLE=' "$script" 2>/dev/null | cut -d'"' -f2)
            fake_port=$(grep '^FAKE_PORT=' "$script" 2>/dev/null | cut -d'"' -f2)
        fi

        local if_info="dev missing"
        if ip link show "${tun_if}" &>/dev/null; then
            if_info="dev ${tun_if} UP"
        fi

        if [ "$status" = "active" ]; then
            echo -e "  ${GREEN}●${NC} ${BOLD}${i})${NC} ${name}  ${GREEN}[active]${NC}  ${DIM}(${role}, TCP:${fake_port}, ${if_info} → ${remote:-?})${NC}"
        else
            echo -e "  ${RED}●${NC} ${BOLD}${i})${NC} ${name}  ${RED}[${status}]${NC}  ${DIM}(${role}, TCP:${fake_port}, ${if_info} → ${remote:-?})${NC}"
        fi
        ((i++))
    done

    [ $found -eq 0 ] && { msg_warn "No FakeTCP tunnels found."; return 1; }
    echo ""
    return 0
}

pick_tunnel() {
    list_tunnels || return 1
    read -p "  Enter number, Tunnel ID (e.g. 10), or service name: " pick
    [ -z "$pick" ] && { msg_err "Input cannot be empty."; return 1; }

    SELECTED_TID=""
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#TUNNEL_ID_LIST[@]}" ]; then
        SELECTED_TID="${TUNNEL_ID_LIST[$((pick-1))]}"
    elif printf '%s\n' "${TUNNEL_ID_LIST[@]}" | grep -qx "${pick}"; then
        SELECTED_TID="${pick}"
    elif [[ "$pick" =~ ^ftcp([0-9]+)$ ]] && printf '%s\n' "${TUNNEL_ID_LIST[@]}" | grep -qx "${BASH_REMATCH[1]}"; then
        SELECTED_TID="${BASH_REMATCH[1]}"
    elif [[ "$pick" =~ ^phantun-tunnel-([0-9]+)(\.service)?$ ]] && printf '%s\n' "${TUNNEL_ID_LIST[@]}" | grep -qx "${BASH_REMATCH[1]}"; then
        SELECTED_TID="${BASH_REMATCH[1]}"
    fi

    if [ -z "$SELECTED_TID" ]; then
        msg_err "Tunnel '${pick}' not found in detected tunnels."
        return 1
    fi

    SELECTED_TUNNEL="phantun-tunnel-${SELECTED_TID}"
    return 0
}

do_restart() {
    pick_tunnel || return
    restart_tunnel_services "${SELECTED_TID}"
    msg_ok "${SELECTED_TUNNEL}, keep-alive, and watchdog restarted."
}

do_stop() {
    pick_tunnel || return
    stop_tunnel_services "${SELECTED_TID}"
    msg_ok "${SELECTED_TUNNEL} stopped."
}

do_start() {
    pick_tunnel || return
    start_tunnel_services "${SELECTED_TID}"
    msg_ok "${SELECTED_TUNNEL} started."
}

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
    local tid="${SELECTED_TID}"
    local tun_if="ftcp${tid}"
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  TUNNEL ${tid} DETAILS (FakeTCP / Phantun)${NC}"
    print_double_line

    local script="${SCRIPTS_DIR}/ftcp${tid}-up.sh"
    if [ -f "$script" ]; then
        echo ""
        local lr
        lr=$(grep '^LOCAL_REAL=' "$script" 2>/dev/null | cut -d'"' -f2)
        local rr
        rr=$(grep '^REMOTE_REAL=' "$script" 2>/dev/null | cut -d'"' -f2)
        local ls
        ls=$(grep '^LOCAL_SPOOF=' "$script" 2>/dev/null | cut -d'"' -f2)
        local rs
        rs=$(grep '^REMOTE_SPOOF=' "$script" 2>/dev/null | cut -d'"' -f2)
        local lt
        lt=$(grep '^LOCAL_TUN=' "$script" 2>/dev/null | cut -d'"' -f2)
        local fp
        fp=$(grep '^FAKE_PORT=' "$script" 2>/dev/null | cut -d'"' -f2)
        local role
        role=$(grep '^ROLE=' "$script" 2>/dev/null | cut -d'"' -f2)

        echo -e "  ${MAGENTA}Role:${NC}          ${BOLD}${role}${NC}"
        echo -e "  ${MAGENTA}Fake TCP Port:${NC} ${BOLD}${fp:-N/A}${NC}"
        echo -e "  ${MAGENTA}Local Real:${NC}    ${GREEN}${lr}${NC}"
        echo -e "  ${MAGENTA}Remote Real:${NC}   ${BLUE}${rr}${NC}"
        echo -e "  ${MAGENTA}Local Spoof:${NC}   ${DIM}${ls}${NC}"
        echo -e "  ${MAGENTA}Remote Spoof:${NC}  ${DIM}${rs}${NC}"
        echo -e "  ${MAGENTA}Tunnel IP:${NC}     ${GREEN}${lt}${NC}"
    fi

    echo ""
    print_line
    echo -e "  ${CYAN}Phantun Daemon Process:${NC}"
    local pid_file="/tmp/.phantun_${tid}.pid"
    if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
        echo -e "    PID: ${GREEN}$(cat "$pid_file")${NC}  (running)"
    else
        echo -e "    ${RED}Process not running!${NC}"
    fi

    echo ""
    print_line
    echo -e "  ${CYAN}Service:${NC}"
    systemctl is-active "${SELECTED_TUNNEL}" 2>/dev/null | \
        sed "s/active/${GREEN}active${NC}/" | sed "s/inactive/${RED}inactive${NC}/" | \
        while read -r l; do echo -e "    $l"; done

    local ka_st
    ka_st=$(systemctl is-active "phantun-keepalive-${tid}.service" 2>/dev/null || echo "inactive")
    echo -e "  ${CYAN}Keepalive Service:${NC} ${ka_st}"

    if ip link show "${tun_if}" &>/dev/null; then
        local rx
        rx=$(cat "/sys/class/net/${tun_if}/statistics/rx_bytes" 2>/dev/null || echo 0)
        local tx
        tx=$(cat "/sys/class/net/${tun_if}/statistics/tx_bytes" 2>/dev/null || echo 0)
        echo ""
        print_line
        echo -e "  ${CYAN}Traffic:${NC}"
        echo -e "    RX: ${GREEN}$(( rx / 1048576 )) MB${NC}  TX: ${BLUE}$(( tx / 1048576 )) MB${NC}"
    fi

    echo ""
    print_line
    local wd_st
    wd_st=$(systemctl is-active "phantun-watchdog-${tid}.timer" 2>/dev/null || echo "inactive")
    local fails
    fails=$(cat "/tmp/.wd_${tun_if}" 2>/dev/null || echo 0)
    echo -e "  ${CYAN}Watchdog:${NC}  ${wd_st}  fails: ${fails}/3"

    echo ""
    print_line
    echo -e "  ${CYAN}nftables (fw_ftcp_${tid}):${NC}"
    nft list table ip "fw_ftcp_${tid}" 2>/dev/null | head -20 || msg_warn "  Table not found."
    echo ""
}

do_delete() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local tun_if="ftcp${tid}"
    local svc_name="phantun-tunnel-${tid}"
    local up_script="${SCRIPTS_DIR}/ftcp${tid}-up.sh"
    local down_script="${SCRIPTS_DIR}/ftcp${tid}-down.sh"
    local wd_script="${SCRIPTS_DIR}/ftcp${tid}-watchdog.sh"

    echo ""
    echo -e " ${RED}${BOLD}This will permanently delete FakeTCP Tunnel ${tid} (${tun_if}) and ALL components.${NC}"
    echo -e "  ${GREEN}1)${NC} Yes, delete FakeTCP Tunnel ${tid} (y)"
    echo -e "  ${RED}2)${NC} Cancel (n)"
    echo ""
    read -p "  Confirm deletion [1/y to delete, 2/n to cancel]: " confirm
    case "$confirm" in
        1|[yY]|[yY][eE][sS]|DELETE|delete)
            ;;
        *)
            msg_warn "Cancelled."
            return
            ;;
    esac

    msg_info "Completely deleting Tunnel ${tid} (${tun_if})..."

    # 1. Stop watchdog
    systemctl stop "phantun-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl disable "phantun-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl stop "phantun-watchdog-${tid}.service" 2>/dev/null || true
    systemctl disable "phantun-watchdog-${tid}.service" 2>/dev/null || true
    pkill -9 -f "ftcp${tid}-watchdog.sh" 2>/dev/null || true

    # 2. Stop keepalive
    systemctl stop "phantun-keepalive-${tid}.service" 2>/dev/null || true
    systemctl disable "phantun-keepalive-${tid}.service" 2>/dev/null || true
    pkill -9 -f "ping.*-I ${tun_if}" 2>/dev/null || true

    # 3. Stop main tunnel
    systemctl stop "${svc_name}.service" 2>/dev/null || true
    systemctl disable "${svc_name}.service" 2>/dev/null || true

    # 4. Run down script
    if [ -f "$down_script" ]; then
        bash "$down_script" 2>/dev/null || true
    fi

    # 5. Direct cleanup
    ip link set dev "${tun_if}" down 2>/dev/null || true
    ip tunnel del "${tun_if}" 2>/dev/null || true
    ip link del "${tun_if}" 2>/dev/null || true
    nft delete table ip "fw_ftcp_${tid}" 2>/dev/null || true

    # 6. Remove files
    rm -f "${SYSTEMD_DIR}/${svc_name}.service"
    rm -f "${SYSTEMD_DIR}/phantun-keepalive-${tid}.service"
    rm -f "${SYSTEMD_DIR}/phantun-watchdog-${tid}.service"
    rm -f "${SYSTEMD_DIR}/phantun-watchdog-${tid}.timer"
    rm -f "${SYSTEMD_DIR}/multi-user.target.wants/${svc_name}.service"
    rm -f "${SYSTEMD_DIR}/multi-user.target.wants/phantun-keepalive-${tid}.service"
    rm -f "${SYSTEMD_DIR}/timers.target.wants/phantun-watchdog-${tid}.timer"

    rm -f "$up_script"
    rm -f "$down_script"
    rm -f "$wd_script"
    rm -f "/tmp/.wd_${tun_if}"
    rm -f "/tmp/.phantun_${tid}.pid"

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    msg_ok "FakeTCP Tunnel ${tid} (${tun_if}) and ALL its components were completely removed!"
}

do_view_scripts() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local up="${SCRIPTS_DIR}/ftcp${tid}-up.sh"
    local down="${SCRIPTS_DIR}/ftcp${tid}-down.sh"
    local wd="${SCRIPTS_DIR}/ftcp${tid}-watchdog.sh"
    local found_any=0
    echo ""
    if [ -f "$up" ]; then
        found_any=1
        echo -e " ${CYAN}${BOLD}Up Script:${NC} ${up}"
        print_line
        cat "$up"
        echo ""
    fi
    if [ -f "$down" ]; then
        found_any=1
        echo -e " ${CYAN}${BOLD}Down Script:${NC} ${down}"
        print_line
        cat "$down"
        echo ""
    fi
    if [ -f "$wd" ]; then
        found_any=1
        echo -e " ${CYAN}${BOLD}Watchdog Script:${NC} ${wd}"
        print_line
        cat "$wd"
        echo ""
    fi
    if [ $found_any -eq 0 ]; then
        msg_warn "No scripts found for Tunnel ${tid}."
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
        echo -e " ${BOLD}${WHITE}Setup FakeTCP / Phantun Tunnel${NC}"
        echo -e "  ${GREEN}3)${NC}  Setup Iran Client"
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
        echo ""
        echo -e " ${BOLD}${WHITE}Watchdog${NC}"
        echo -e "  ${MAGENTA}16)${NC} Watchdog Management (Status/Start/Stop/Logs/Test)"
        echo ""
        echo -e " ${BOLD}${WHITE}Danger${NC}"
        echo -e "  ${RED}17)${NC} Delete a Tunnel"
        echo ""
        echo -e " ${BOLD}${WHITE}Install${NC}"
        echo -e "  ${MAGENTA}18)${NC} Install Phantun Rust Binaries & Dependencies"
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
            16|wd|watchdog) watchdog_menu ;;
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
