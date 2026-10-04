#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  IPIP OVER FOU TUNNEL SETUP (Optimized for Electron App Model) ║
# ║  Iran & Kharej Multi-Tunnel with Stateless IP Spoofing        ║
# ║  Zero GRE Signature • Minimal Overhead • Kernel-Level Speed   ║
# ╚════════════════════════════════════════════════════════════════╝

VERSION="2.2.0"

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

# ─── UI Helpers ───────────────────────────────────────────────────
print_line() { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }
print_double_line() { echo -e "${CYAN}════════════════════════════════════════════════════${NC}"; }

print_header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════════╗"
    echo " ║     IPIP OVER FOU HIGH-SPEED TUNNEL (K-Space)  ║"
    echo " ║                  v${VERSION}                        ║"
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

# ─── Auto-Detect ──────────────────────────────────────────────────
detect_interface() {
    local iface=""
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v -E '^(lo|gre.*|ipip.*|tun.*|tap.*|docker.*|veth.*|erspan.*)$' | head -1)
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

# ─── Install Prerequisites ───────────────────────────────────────
install_prereqs() {
    echo ""
    msg_info "Checking prerequisites for IPIP over FOU..."
    local need_install=0

    for cmd in nft ethtool ping curl fuser; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_warn "Required command '${cmd}' not found."
            need_install=1
        fi
    done

    for mod in ipip tunnel4 fou tcp_bbr nf_conntrack; do
        if ! modprobe "$mod" 2>/dev/null; then
            msg_warn "Kernel module '${mod}' not loaded or unavailable."
        else
            msg_ok "Kernel module '${mod}' ready."
        fi
    done

    if [ $need_install -eq 1 ]; then
        msg_info "Installing missing packages..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq nftables iproute2 iputils-ping ethtool curl procps psmisc
        elif command -v yum &>/dev/null; then
            yum install -y -q nftables iproute iputils ethtool curl procps-ng psmisc
        elif command -v dnf &>/dev/null; then
            dnf install -y -q nftables iproute iputils ethtool curl procps-ng psmisc
        else
            msg_err "Cannot detect package manager. Please install nftables, iproute2, ethtool, psmisc, and iputils-ping manually."
            return 1
        fi
    fi
    msg_ok "All prerequisites verified."
}

# ─── Persist System Tuning across Reboots ─────────────────────────
persist_sysctl_tuning() {
    cat > /etc/sysctl.d/99-xmanager-tunnel.conf << 'EOF'
# XManager High-Speed Kernel & Network Tuning
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1

# TCP BBR & Queue Discipline
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1

# High-Performance Buffer Sizes
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.optmem_max = 2097152
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_autocorking = 0
net.ipv4.ipfrag_high_thresh = 16777216
net.ipv4.ipfrag_low_thresh = 8388608
net.ipv4.ipfrag_time = 30
net.core.netdev_max_backlog = 100000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# Connection Scalability & Limits
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 100000
net.ipv4.tcp_max_syn_backlog = 100000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.netfilter.nf_conntrack_max = 2097152
EOF
    sysctl -p /etc/sysctl.d/99-xmanager-tunnel.conf >/dev/null 2>&1 || true
}

# ─── Generate IPIP-UP Script ─────────────────────────────────────
generate_ipip_up() {
    local script_path="$1"
    cat > "${script_path}" << IPIPEOF
#!/usr/bin/env bash
set -eu

IF_WAN="${IF_WAN}"
TUN_IF="${TUN_IF}"

LOCAL_REAL="${LOCAL_REAL}"
REMOTE_REAL="${REMOTE_REAL}"

LOCAL_SPOOF="${LOCAL_SPOOF}"
REMOTE_SPOOF="${REMOTE_SPOOF}"

LOCAL_TUN="${LOCAL_TUN}"
FOU_ENABLE="${FOU_ENABLE}"
FOU_PORT="${FOU_PORT}"

NFT_TABLE="fw_ipip_${TUNNEL_ID}"

# ── Reload persistent sysctl config ──
sysctl -p /etc/sysctl.d/99-xmanager-tunnel.conf >/dev/null 2>&1 || true

# ── Security: Disable rp_filter across all interfaces (Prevent Spoofed Packet Drops) ──
sysctl -w net.ipv4.conf.all.rp_filter=0     >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
for iface in \${IF_WAN}; do
    sysctl -w net.ipv4.conf.\${iface}.rp_filter=0 >/dev/null 2>&1 || true
done
for dev in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [ -f "\$dev" ] && echo 0 > "\$dev" 2>/dev/null || true
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

# ── Performance: TCP (BBR + Adaptive low-latency buffers) ──
modprobe tcp_bbr 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr  >/dev/null 2>&1 || true
sysctl -w net.core.default_qdisc=fq            >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_mtu_probing=1           >/dev/null 2>&1 || true

# Adaptive buffer sizes: prevents bufferbloat & RAM exhaustion under heavy concurrent connections
sysctl -w net.core.rmem_default=262144         >/dev/null 2>&1 || true
sysctl -w net.core.wmem_default=262144         >/dev/null 2>&1 || true
sysctl -w net.core.rmem_max=16777216           >/dev/null 2>&1 || true
sysctl -w net.core.wmem_max=16777216           >/dev/null 2>&1 || true
sysctl -w net.core.optmem_max=2097152          >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" >/dev/null 2>&1 || true
sysctl -w net.ipv4.udp_rmem_min=16384          >/dev/null 2>&1 || true
sysctl -w net.ipv4.udp_wmem_min=16384          >/dev/null 2>&1 || true

sysctl -w net.ipv4.tcp_adv_win_scale=1         >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_fastopen=3              >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_notsent_lowat=16384     >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_autocorking=0           >/dev/null 2>&1 || true
sysctl -w net.ipv4.ipfrag_high_thresh=16777216 >/dev/null 2>&1 || true
sysctl -w net.ipv4.ipfrag_low_thresh=8388608   >/dev/null 2>&1 || true
sysctl -w net.ipv4.ipfrag_time=30              >/dev/null 2>&1 || true
sysctl -w net.core.netdev_max_backlog=100000   >/dev/null 2>&1 || true
sysctl -w net.core.netdev_budget=600           >/dev/null 2>&1 || true
sysctl -w net.core.netdev_budget_usecs=8000    >/dev/null 2>&1 || true

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
sysctl -w net.ipv4.tcp_keepalive_intvl=10              >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_keepalive_probes=3              >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_max_tw_buckets=2000000          >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_window_scaling=1                >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_sack=1                          >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_no_metrics_save=1               >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1               >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_max=2097152       >/dev/null 2>&1 || true
[ -d /sys/module/nf_conntrack/parameters ] && echo 524288 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
ulimit -n 1048576 2>/dev/null || true

# ── IPIP Tunnel Setup ──
modprobe ipip 2>/dev/null || true
modprobe tunnel4 2>/dev/null || true

ip link set dev \${TUN_IF} down 2>/dev/null || true
ip tunnel del \${TUN_IF} 2>/dev/null || true
ip link del \${TUN_IF}   2>/dev/null || true

if [ "\${FOU_ENABLE}" = "yes" ]; then
    modprobe fou 2>/dev/null || true
    # Free any lingering socket on FOU port before binding
    fuser -k -9 -n udp \${FOU_PORT} 2>/dev/null || true
    ip fou del port \${FOU_PORT} 2>/dev/null || true
    # Add FOU receiver socket for ipproto 4 (IPv4 in IPv4 RFC 2003)
    ip fou add port \${FOU_PORT} ipproto 4 2>/dev/null || true
    # Create IPIP interface encapsulated into FOU UDP (Zero GRE Header)
    ip link add name \${TUN_IF} type ipip local \${LOCAL_REAL} remote \${REMOTE_REAL} ttl 64 encap fou encap-sport auto encap-dport \${FOU_PORT}
    MTU=1400
    MSS=1360
else
    # Plain direct IPIP (Protocol 4)
    ip link add name \${TUN_IF} type ipip local \${LOCAL_REAL} remote \${REMOTE_REAL} ttl 64
    MTU=1420
    MSS=1380
fi

ip addr replace \${LOCAL_TUN} dev \${TUN_IF} 2>/dev/null || ip addr add \${LOCAL_TUN} dev \${TUN_IF}
ip link set \${TUN_IF} mtu \${MTU}
ip link set \${TUN_IF} txqueuelen 10000
ip link set \${TUN_IF} up
ip link set dev \${IF_WAN} txqueuelen 10000 2>/dev/null || true

# Disable hardware offloads on WAN and tunnel to prevent corrupted frames and softirq spikes
ethtool -K \${IF_WAN} tso off gso off gro off 2>/dev/null || true
ethtool -K \${TUN_IF} tso off gso off gro off 2>/dev/null || true

# Route advmss tuning: forces local sockets to clamp MSS automatically
TUN_SUBNET=\$(echo \${LOCAL_TUN} | sed -E 's/\.[0-9]+\//.0\//')
LOCAL_IP_ONLY=\$(echo \${LOCAL_TUN} | cut -d/ -f1)
ip route replace \${TUN_SUBNET} dev \${TUN_IF} proto kernel scope link src \${LOCAL_IP_ONLY} advmss \${MSS} 2>/dev/null || true

# Disable IPv6 on tunnel (prevent leaks)
sysctl -w net.ipv6.conf.\${TUN_IF}.disable_ipv6=1 >/dev/null 2>&1 || true
# Scoped rp_filter for tunnel interface
sysctl -w net.ipv4.conf.\${TUN_IF}.rp_filter=0    >/dev/null 2>&1 || true

# ── Qdisc: Fair Queue ──
tc qdisc add dev \${IF_WAN} root fq 2>/dev/null || true
tc qdisc replace dev \${TUN_IF} root fq 2>/dev/null || true

# ── RPS & RFS: distribute across cores ──
CORES=\$(nproc 2>/dev/null || echo 1)
if [ "\${CORES}" -gt 1 ]; then
    if [ "\${CORES}" -gt 32 ]; then
        RPS_MASK="ffffffff"
    else
        RPS_MASK=\$(printf '%x' \$(( (1 << CORES) - 1 )))
    fi
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

# Check if IP spoofing is enabled and needed
DO_SPOOF=0
if [ -n "\${LOCAL_SPOOF}" ] && [ -n "\${REMOTE_SPOOF}" ] && { [ "\${LOCAL_SPOOF}" != "\${LOCAL_REAL}" ] || [ "\${REMOTE_SPOOF}" != "\${REMOTE_REAL}" ]; }; then
    DO_SPOOF=1
fi

if [ "\$DO_SPOOF" -eq 1 ]; then
    nft add chain ip \${NFT_TABLE} prerouting  '{ type filter hook prerouting  priority -300 ; }'
    nft add chain ip \${NFT_TABLE} postrouting '{ type filter hook postrouting priority  300 ; }'

    if [ "\${FOU_ENABLE}" = "yes" ]; then
        nft add rule ip \${NFT_TABLE} prerouting  iif "\${IF_WAN}" ip saddr \${REMOTE_SPOOF} ip daddr \${LOCAL_REAL} udp dport \${FOU_PORT} ip saddr set \${REMOTE_REAL} notrack
        nft add rule ip \${NFT_TABLE} postrouting oif "\${IF_WAN}" ip saddr \${LOCAL_REAL} ip daddr \${REMOTE_REAL} udp dport \${FOU_PORT} ip saddr set \${LOCAL_SPOOF} notrack
    else
        nft add rule ip \${NFT_TABLE} prerouting  iif "\${IF_WAN}" ip protocol ipip ip saddr \${REMOTE_SPOOF} ip daddr \${LOCAL_REAL} ip saddr set \${REMOTE_REAL} notrack
        nft add rule ip \${NFT_TABLE} postrouting oif "\${IF_WAN}" ip protocol ipip ip saddr \${LOCAL_REAL} ip daddr \${REMOTE_REAL} ip saddr set \${LOCAL_SPOOF} notrack
    fi
fi

# MSS Clamping
nft add chain ip \${NFT_TABLE} fwd_mss '{ type filter hook forward priority 0 ; }'
nft add rule  ip \${NFT_TABLE} fwd_mss oif "\${TUN_IF}" tcp flags syn tcp option maxseg size set \${MSS}
nft add rule  ip \${NFT_TABLE} fwd_mss iif "\${TUN_IF}" tcp flags syn tcp option maxseg size set \${MSS}

nft add chain ip \${NFT_TABLE} out_mss '{ type filter hook output priority 0 ; }'
nft add rule  ip \${NFT_TABLE} out_mss oif "\${TUN_IF}" tcp flags syn tcp option maxseg size set \${MSS}

echo "IPIP tunnel \${TUN_IF} UP (table: \${NFT_TABLE})"
IPIPEOF
    chmod 750 "${script_path}"
}

# ─── Generate IPIP-DOWN Script ───────────────────────────────────
generate_ipip_down() {
    local script_path="$1"
    cat > "${script_path}" << IPIPEOF
#!/usr/bin/env bash
TUN_IF="${TUN_IF}"
NFT_TABLE="fw_ipip_${TUNNEL_ID}"
FOU_PORT="${FOU_PORT}"

ip link set dev \${TUN_IF} down 2>/dev/null || true
ip tunnel del \${TUN_IF} 2>/dev/null || true
ip link del \${TUN_IF}   2>/dev/null || true
nft delete table ip \${NFT_TABLE} 2>/dev/null || true
# Free the FOU UDP socket in the kernel on graceful stop
fuser -k -9 -n udp \${FOU_PORT} 2>/dev/null || true
[ -n "\${FOU_PORT}" ] && ip fou del port \${FOU_PORT} 2>/dev/null || true

echo "IPIP tunnel \${TUN_IF} DOWN (table: \${NFT_TABLE})"
IPIPEOF
    chmod 750 "${script_path}"
}

# ─── Generate Watchdog Script ─────────────────────────────────────
generate_watchdog() {
    local script_path="$1"
    cat > "${script_path}" << WDEOF
#!/usr/bin/env bash
TUN_IF="${TUN_IF}"
REMOTE_TUN="${REMOTE_TUN}"
SERVICE="ipip-tunnel-${TUNNEL_ID}"
MAX_FAIL=3
FAIL_FILE="/tmp/.wd_\${TUN_IF}"
LOG_TAG="wd-\${TUN_IF}"

# Auto-detect REMOTE_TUN if missing
if [ -z "\${REMOTE_TUN}" ]; then
    UP_SCRIPT="/usr/local/bin/ipip${TUNNEL_ID}-up.sh"
    if [ -f "\$UP_SCRIPT" ]; then
        LT=\$(grep '^LOCAL_TUN=' "\$UP_SCRIPT" 2>/dev/null | cut -d'"' -f2)
        if [[ "\$LT" == *".1/"* ]]; then
            REMOTE_TUN="10.88.${TUNNEL_ID}.2"
        else
            REMOTE_TUN="10.88.${TUNNEL_ID}.1"
        fi
    fi
fi

# Skip if service is not active (was stopped intentionally or during deletion) or disabled
if ! systemctl is-active "\${SERVICE}" &>/dev/null; then
    exit 0
fi
if ! systemctl is-enabled "\${SERVICE}" &>/dev/null; then
    exit 0
fi

# Check interface exists
if ! ip link show \${TUN_IF} &>/dev/null; then
    logger -t "\${LOG_TAG}" "Interface \${TUN_IF} missing - restarting \${SERVICE}" 2>/dev/null || true
    systemctl restart "\${SERVICE}" 2>/dev/null || true
    systemctl restart "ipip-keepalive-${TUNNEL_ID}" 2>/dev/null || true
    exit 0
fi

# Ping remote tunnel endpoint
if [ -n "\${REMOTE_TUN}" ]; then
    if ping -c 2 -W 2 -I \${TUN_IF} \${REMOTE_TUN} &>/dev/null; then
        echo 0 > "\${FAIL_FILE}" 2>/dev/null
        exit 0
    fi
fi

# Track consecutive failures safely
FAILS=\$(cat "\${FAIL_FILE}" 2>/dev/null | tr -d '[:space:]')
[[ ! "\${FAILS}" =~ ^[0-9]+$ ]] && FAILS=0
FAILS=\$((FAILS + 1))
echo "\${FAILS}" > "\${FAIL_FILE}" 2>/dev/null

if [ "\${FAILS}" -ge "\${MAX_FAIL}" ]; then
    logger -t "\${LOG_TAG}" "Tunnel \${TUN_IF} DOWN after \${FAILS} failures - restarting \${SERVICE}" 2>/dev/null || true
    systemctl restart "\${SERVICE}" 2>/dev/null || true
    systemctl restart "ipip-keepalive-${TUNNEL_ID}" 2>/dev/null || true
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
    local svc="ipip-watchdog-${tunnel_id}"

    cat > "${SYSTEMD_DIR}/${svc}.service" << EOF
[Unit]
Description=IPIP Tunnel ${tunnel_id} Watchdog Check
After=network.target ipip-tunnel-${tunnel_id}.service

[Service]
Type=oneshot
ExecStart=${wd_script}
StandardOutput=journal
StandardError=journal
EOF

    cat > "${SYSTEMD_DIR}/${svc}.timer" << EOF
[Unit]
Description=IPIP Tunnel ${tunnel_id} Watchdog Timer

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

create_ipip_service() {
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
    local tunnel_id="$1" remote_tun_ip="$2"
    local service_name="ipip-keepalive-${tunnel_id}"
    local service_path="${SYSTEMD_DIR}/${service_name}.service"
    local sleep_offset=$(( tunnel_id % 5 ))

    cat > "${service_path}" << EOF
[Unit]
Description=IPIP Tunnel ${tunnel_id} Keep-Alive
After=ipip-tunnel-${tunnel_id}.service
Requires=ipip-tunnel-${tunnel_id}.service
PartOf=ipip-tunnel-${tunnel_id}.service

[Service]
Type=simple
ExecStart=/bin/bash -c 'sleep ${sleep_offset}; while true; do ping -c 1 -W 2 -I ipip${tunnel_id} ${remote_tun_ip} >/dev/null 2>&1; sleep 5; done'
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
show_ipip_review() {
    local role="$1"
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  REVIEW YOUR IPIP OVER FOU SETTINGS${NC}"
    print_double_line
    echo ""
    echo -e "  ${MAGENTA}Tunnel ID:${NC}       ${WHITE}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "  ${MAGENTA}Role:${NC}            ${WHITE}${BOLD}${role}${NC}"
    echo -e "  ${MAGENTA}Interface:${NC}       ${WHITE}${BOLD}${IF_WAN}${NC}  ${DIM}(auto-detected)${NC}"
    echo -e "  ${MAGENTA}Tunnel Dev:${NC}      ${WHITE}${BOLD}${TUN_IF}${NC}"
    echo -e "  ${MAGENTA}Encapsulation:${NC}   ${WHITE}${BOLD}IPIP over FOU (No GRE Header)${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Real IPs (FOU Endpoints):${NC}"
    echo -e "    Local:   ${GREEN}${BOLD}${LOCAL_REAL}${NC}"
    echo -e "    Remote:  ${BLUE}${BOLD}${REMOTE_REAL}${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Spoof IPs (nftables):${NC}"
    echo -e "    Local Spoof:   ${MAGENTA}${BOLD}${LOCAL_SPOOF}${NC}"
    echo -e "    Remote Spoof:  ${MAGENTA}${BOLD}${REMOTE_SPOOF}${NC}"
    echo ""
    local show_mtu="1400"
    print_line
    echo -e "  ${CYAN}Tunnel Network:${NC}"
    echo -e "    Local TUN:  ${GREEN}${BOLD}${LOCAL_TUN}${NC}  ${DIM}(MTU: ${show_mtu}, MSS: 1360)${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Optimizations & Anti-DPI Features:${NC}"
    echo -e "    ${GREEN}✓${NC} Zero-GRE Signature (Pure IPv4-in-UDP ipproto 4)"
    echo -e "    ${GREEN}✓${NC} FOU Stealth Mode (UDP Port ${FOU_PORT})"
    echo -e "    ${GREEN}✓${NC} BBR Congestion Control + FQ Qdisc"
    echo -e "    ${GREEN}✓${NC} Adaptive Low-Latency Buffers (No Bufferbloat)"
    echo -e "    ${GREEN}✓${NC} MSS Clamping (Forward & Output Hooks: ${show_mtu}-40)"
    echo -e "    ${GREEN}✓${NC} Route advmss Tuning (Zero Packet Fragmentation for Nginx/Xray)"
    echo -e "    ${GREEN}✓${NC} WAN & Tunnel TSO/GSO/GRO Offload Protection (Zero Throttling on ens33/eth0)"
    echo -e "    ${GREEN}✓${NC} Persistent Kernel Tuning on Boot (/etc/sysctl.d/99-xmanager-tunnel.conf)"
    echo -e "    ${GREEN}✓${NC} Continuous Keep-Alive & Active Watchdog (every 10s)"
    echo ""
    echo -e "  ${CYAN}nftables Table:${NC} ${WHITE}fw_ipip_${TUNNEL_ID}${NC}"
    echo ""
    print_double_line
    echo ""
}

# ─── Unified Tunnel Setup ─────────────────────────────────────────
setup_ipip_server() {
    local role="$1" # "Iran" or "Kharej"
    print_header
    echo -e " ${GREEN}${BOLD}>>> Setup ${role} Server (IPIP over FOU)${NC}"
    echo ""
    print_line

    IF_WAN=$(detect_interface)
    local AUTO_IP
    AUTO_IP=$(detect_public_ip)

    echo -e "\n ${MAGENTA}${BOLD}[1/4] Tunnel Identity${NC}"
    read_input "Tunnel ID (number between 1 and 255)" "" TUNNEL_ID
    if ! [[ "$TUNNEL_ID" =~ ^[0-9]+$ ]] || [ "$TUNNEL_ID" -lt 1 ] || [ "$TUNNEL_ID" -gt 255 ]; then
        msg_err "Tunnel ID must be a number between 1 and 255!"
        return 1
    fi
    TUN_IF="ipip${TUNNEL_ID}"

    # Collision warning
    if [ -f "${SYSTEMD_DIR}/ipip-tunnel-${TUNNEL_ID}.service" ] || ip link show "${TUN_IF}" &>/dev/null; then
        msg_warn "Tunnel ID ${TUNNEL_ID} already exists!"
        read -p "  Do you want to overwrite and reconfigure it? (y/N): " ow_choice
        [[ ! "$ow_choice" =~ ^[Yy]$ ]] && { msg_warn "Cancelled."; return 0; }
        stop_tunnel_services "${TUNNEL_ID}"
    fi

    echo -e "\n ${MAGENTA}${BOLD}[2/4] Network Interfaces & Endpoints${NC}"
    msg_info "Interface auto-detected: ${BOLD}${IF_WAN}${NC}"
    read_input "Change interface? (Enter to keep)" "${IF_WAN}" IF_WAN
    if ! ip link show "${IF_WAN}" &>/dev/null; then
        msg_warn "Interface '${IF_WAN}' does not currently exist on this system! Please verify."
    fi
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

    if [ "$LOCAL_SPOOF" = "$REMOTE_SPOOF" ] && [ "$LOCAL_SPOOF" != "$LOCAL_REAL" ]; then
        msg_warn "Local Spoof IP and Remote Spoof IP are identical! Traffic loop may occur."
    fi

    if [ "$role" = "Iran" ]; then
        LOCAL_TUN="10.88.${TUNNEL_ID}.1/30"
        REMOTE_TUN="10.88.${TUNNEL_ID}.2"
    else
        LOCAL_TUN="10.88.${TUNNEL_ID}.2/30"
        REMOTE_TUN="10.88.${TUNNEL_ID}.1"
    fi

    echo -e "\n ${MAGENTA}${BOLD}[4/4] FOU UDP Port${NC}"
    read_port "FOU UDP Port" "51820" FOU_PORT
    FOU_ENABLE="yes"

    show_ipip_review "${role}"

    read -p "  Proceed with installation? (Y/n): " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { msg_warn "Cancelled."; return 0; }

    # Pre-clean any lingering FOU ports, virtual devices or processes for this TUNNEL_ID
    stop_tunnel_services "${TUNNEL_ID}"
    ip link set dev "${TUN_IF}" down 2>/dev/null || true
    ip tunnel del "${TUN_IF}" 2>/dev/null || true
    ip link del "${TUN_IF}" 2>/dev/null || true
    fuser -k -9 -n udp "${FOU_PORT}" 2>/dev/null || true
    ip fou del port "${FOU_PORT}" 2>/dev/null || true

    echo ""
    local up_script="${SCRIPTS_DIR}/ipip${TUNNEL_ID}-up.sh"
    local down_script="${SCRIPTS_DIR}/ipip${TUNNEL_ID}-down.sh"
    local service_name="ipip-tunnel-${TUNNEL_ID}"

    persist_sysctl_tuning
    msg_ok "Persistent network tuning applied: /etc/sysctl.d/99-xmanager-tunnel.conf"

    generate_ipip_up "${up_script}"
    msg_ok "Up script created: ${up_script}"

    generate_ipip_down "${down_script}"
    msg_ok "Down script created: ${down_script}"

    create_ipip_service "${TUNNEL_ID}" "${service_name}" "${up_script}" "${down_script}" "IPIP Tunnel ${TUNNEL_ID} - ${role}"
    msg_ok "Tunnel service started: ${service_name}"

    create_keepalive_service "${TUNNEL_ID}" "${REMOTE_TUN}"
    msg_ok "Keep-alive service started: ipip-keepalive-${TUNNEL_ID}"

    local wd_script="${SCRIPTS_DIR}/ipip${TUNNEL_ID}-watchdog.sh"
    generate_watchdog "${wd_script}"
    create_watchdog_timer "${TUNNEL_ID}" "${wd_script}"
    msg_ok "Watchdog timer started (every 10s)"

    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  ${role} IPIP Tunnel ${TUNNEL_ID} Setup Complete!${NC}"
    print_double_line
    echo ""

    if [ "$role" = "Iran" ]; then
        echo -e "  ${YELLOW}${BOLD}Settings to use for the Kharej side:${NC}"
        echo -e "    Tunnel ID:    ${CYAN}${BOLD}${TUNNEL_ID}${NC}"
        echo -e "    Remote IP:    ${CYAN}${BOLD}${LOCAL_REAL}${NC}"
        echo -e "    FOU UDP Port: ${CYAN}${BOLD}${FOU_PORT}${NC}"
        echo -e "    Spoof Local:  ${CYAN}${BOLD}${REMOTE_SPOOF}${NC}  (swapped)"
        echo -e "    Spoof Remote: ${CYAN}${BOLD}${LOCAL_SPOOF}${NC}  (swapped)"
    else
        echo -e " ${CYAN}Test connectivity:${NC}"
        echo -e "    ping -c 3 10.88.${TUNNEL_ID}.1"
    fi
    echo ""
    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

setup_iran()   { setup_ipip_server "Iran"; }
setup_kharej() { setup_ipip_server "Kharej"; }

# ─── Tunnel Discovery Helper ──────────────────────────────────────
get_all_tunnel_ids() {
    local ids=()
    # 1. From systemd unit files on disk
    for f in "${SYSTEMD_DIR}"/ipip-tunnel-*.service; do
        [ -f "$f" ] || continue
        local b
        b=$(basename "$f")
        local id="${b#ipip-tunnel-}"
        id="${id%.service}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    # 2. From systemctl unit files & active units
    for u in $(systemctl list-unit-files "ipip-tunnel-*.service" --no-legend 2>/dev/null | awk '{print $1}'); do
        local id="${u#ipip-tunnel-}"
        id="${id%.service}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done
    for u in $(systemctl list-units --type=service --all "ipip-tunnel-*" --no-legend 2>/dev/null | awk '{print $1}'); do
        local id="${u#ipip-tunnel-}"
        id="${id%.service}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    # 3. From scripts in SCRIPTS_DIR
    for f in "${SCRIPTS_DIR}"/ipip*-up.sh; do
        [ -f "$f" ] || continue
        local b
        b=$(basename "$f")
        local id="${b#ipip}"
        id="${id%-up.sh}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    # 4. From active kernel interfaces (ipip1, ipip10, etc.)
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep '^ipip[1-9]' | sed 's/@.*//'); do
        local id="${iface#ipip}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    # 5. From nftables tables (fw_ipip_10, etc.)
    for tbl in $(nft list tables 2>/dev/null | grep 'fw_ipip_' | awk '{print $NF}'); do
        local id="${tbl#fw_ipip_}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    if [ ${#ids[@]} -gt 0 ]; then
        printf '%s\n' "${ids[@]}" | sort -n -u
    fi
}

# ─── Unified Service Control Helpers ──────────────────────────────
start_tunnel_services() {
    local tid="$1"
    local name="ipip-tunnel-${tid}"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "${name}" 2>/dev/null || true
    systemctl start "${name}" 2>/dev/null || true
    if [ -f "${SYSTEMD_DIR}/ipip-keepalive-${tid}.service" ]; then
        systemctl enable "ipip-keepalive-${tid}" 2>/dev/null || true
        systemctl start "ipip-keepalive-${tid}" 2>/dev/null || true
    fi
    if [ -f "${SYSTEMD_DIR}/ipip-watchdog-${tid}.timer" ]; then
        systemctl enable "ipip-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl start "ipip-watchdog-${tid}.timer" 2>/dev/null || true
    fi
}

stop_tunnel_services() {
    local tid="$1"
    local name="ipip-tunnel-${tid}"
    systemctl stop "ipip-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl stop "ipip-watchdog-${tid}.service" 2>/dev/null || true
    systemctl stop "ipip-keepalive-${tid}" 2>/dev/null || true
    systemctl stop "${name}" 2>/dev/null || true
}

restart_tunnel_services() {
    local tid="$1"
    local name="ipip-tunnel-${tid}"
    systemctl restart "${name}" 2>/dev/null || true
    if [ -f "${SYSTEMD_DIR}/ipip-keepalive-${tid}.service" ]; then
        systemctl restart "ipip-keepalive-${tid}" 2>/dev/null || true
    fi
    if [ -f "${SYSTEMD_DIR}/ipip-watchdog-${tid}.timer" ]; then
        systemctl restart "ipip-watchdog-${tid}.timer" 2>/dev/null || true
    fi
}

# ─── Watchdog Helpers & Management ────────────────────────────────
ensure_watchdog_exists() {
    local tid="$1"
    local up_script="${SCRIPTS_DIR}/ipip${tid}-up.sh"
    local wd_script="${SCRIPTS_DIR}/ipip${tid}-watchdog.sh"

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
    TUN_IF="ipip${tid}"
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
    echo -e " ${CYAN}${BOLD}Watchdog Timers & Status (IPIP):${NC}"
    print_line

    local found=0
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        found=1
        local tname="ipip-watchdog-${tid}"
        local tun_if="ipip${tid}"
        local svc="ipip-tunnel-${tid}"

        local timer_file="${SYSTEMD_DIR}/${tname}.timer"
        local script_file="${SCRIPTS_DIR}/ipip${tid}-watchdog.sh"

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

        echo -e "  ${timer_col}●${NC} ${BOLD}ipip${tid}${NC}  Timer: ${timer_col}[${timer_status}]${NC}  Tunnel: ${tun_col}[${tun_st}]${NC}  Fails: ${fails}/3  ${DIM}${next_info}${NC}${script_warn}"
    done

    [ $found -eq 0 ] && msg_warn "No IPIP/FOU tunnels found."
    echo ""
    echo -e " ${DIM}Watchdog checks every 10s, restarts tunnel and keepalive after 3 consecutive failures.${NC}"
    echo ""
}

do_watchdog_start() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    ensure_watchdog_exists "${tid}"
    systemctl daemon-reload
    systemctl enable "ipip-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl start "ipip-watchdog-${tid}.timer" 2>/dev/null || true
    msg_ok "Watchdog timer for ipip${tid} started and enabled (every 10s)."
}

do_watchdog_stop() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    systemctl stop "ipip-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl disable "ipip-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl stop "ipip-watchdog-${tid}.service" 2>/dev/null || true
    msg_ok "Watchdog timer for ipip${tid} stopped and disabled."
}

do_watchdog_restart() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    ensure_watchdog_exists "${tid}"
    systemctl daemon-reload
    systemctl restart "ipip-watchdog-${tid}.timer" 2>/dev/null || true
    msg_ok "Watchdog timer for ipip${tid} restarted."
}

do_watchdog_start_all() {
    echo ""
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    [ ${#all_ids[@]} -eq 0 ] && { msg_warn "No tunnels found."; return; }
    for tid in "${all_ids[@]}"; do
        ensure_watchdog_exists "${tid}"
        systemctl enable "ipip-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl start "ipip-watchdog-${tid}.timer" 2>/dev/null || true
        msg_ok "Watchdog ipip${tid} started."
    done
    systemctl daemon-reload
    msg_ok "All watchdog timers started."
}

do_watchdog_stop_all() {
    echo ""
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    [ ${#all_ids[@]} -eq 0 ] && { msg_warn "No tunnels found."; return; }
    for tid in "${all_ids[@]}"; do
        systemctl stop "ipip-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl disable "ipip-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl stop "ipip-watchdog-${tid}.service" 2>/dev/null || true
        msg_ok "Watchdog ipip${tid} stopped."
    done
    msg_ok "All watchdog timers stopped."
}

do_watchdog_test() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local tun_if="ipip${tid}"
    local svc="ipip-tunnel-${tid}"

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

    local up_script="${SCRIPTS_DIR}/ipip${tid}-up.sh"
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
            echo -e "     ${GREEN}✓ Ping SUCCESSFUL! Tunnel connection is healthy.${NC}"
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
    timer_st=$(systemctl is-active "ipip-watchdog-${tid}.timer" 2>/dev/null || echo "inactive")
    echo -e "  Timer status: ${BOLD}${timer_st}${NC}"
    echo ""
    print_double_line
}

do_watchdog_logs() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local tun_if="ipip${tid}"

    echo ""
    echo -e " ${CYAN}${BOLD}Watchdog Service Logs (ipip-watchdog-${tid}):${NC}"
    print_line
    journalctl -u "ipip-watchdog-${tid}.service" -n 25 --no-pager 2>/dev/null || echo "No service logs found."
    echo ""
    echo -e " ${CYAN}${BOLD}Syslog Watchdog Restarts / Alerts (wd-${tun_if}):${NC}"
    print_line
    journalctl -t "wd-${tun_if}" -n 25 --no-pager 2>/dev/null || grep "wd-${tun_if}" /var/log/syslog 2>/dev/null | tail -25 || echo "No syslog events found."
    echo ""
}

do_watchdog_repair_all() {
    echo ""
    msg_info "Reinstalling and fixing Watchdog timers for all tunnels..."
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    [ ${#all_ids[@]} -eq 0 ] && { msg_warn "No tunnels found."; return; }
    for tid in "${all_ids[@]}"; do
        ensure_watchdog_exists "${tid}"
        systemctl enable "ipip-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl restart "ipip-watchdog-${tid}.timer" 2>/dev/null || true
        msg_ok "Watchdog ipip${tid} re-configured and restarted."
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
        echo " ║         IPIP WATCHDOG MANAGEMENT               ║"
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
    echo -e " ${WHITE}${BOLD}  SYSTEM DASHBOARD (IPIP over FOU)${NC}"
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
        local name="ipip-tunnel-${tid}"
        ((total++))
        [ "$(systemctl is-active "${name}" 2>/dev/null)" = "active" ] && ((active++)) || ((down++))
    done

    echo -e "  ${CYAN}Tunnels:${NC}  Total: ${BOLD}${total}${NC}  ${GREEN}Active: ${active}${NC}  ${RED}Down: ${down}${NC}"
    echo ""

    if [ $total -gt 0 ]; then
        printf "  ${DIM}%-4s %-8s %-7s %-16s %-16s %-10s %-10s %-10s${NC}\n" "ID" "Role" "Status" "Remote Real" "Tunnel IP" "Traffic" "Watchdog" "Keepalive"
        print_line
        for tid in "${all_ids[@]}"; do
            local name="ipip-tunnel-${tid}"
            local st
            st=$(systemctl is-active "${name}" 2>/dev/null || echo "inactive")
            local tun_if="ipip${tid}"

            local remote="" tun_ip="" role="?"
            local script="${SCRIPTS_DIR}/ipip${tid}-up.sh"
            if [ -f "$script" ]; then
                remote=$(grep '^REMOTE_REAL=' "$script" 2>/dev/null | cut -d'"' -f2)
                tun_ip=$(grep '^LOCAL_TUN=' "$script" 2>/dev/null | cut -d'"' -f2)
                [[ "$tun_ip" == *".1/"* ]] && role="Iran" || role="Kharej"
            fi

            local rx
            rx=$(cat "/sys/class/net/${tun_if}/statistics/rx_bytes" 2>/dev/null || echo 0)
            local tx
            tx=$(cat "/sys/class/net/${tun_if}/statistics/tx_bytes" 2>/dev/null || echo 0)
            local traffic="$(( (rx+tx) / 1048576 ))MB"

            local wd_st
            wd_st=$(systemctl is-active "ipip-watchdog-${tid}.timer" 2>/dev/null || echo "inactive")
            local fails
            fails=$(cat "/tmp/.wd_ipip${tid}" 2>/dev/null || echo 0)
            local wd_info="${wd_st}"
            [ "$fails" -gt 0 ] 2>/dev/null && wd_info="${wd_info}(${fails})"

            local ka_st
            ka_st=$(systemctl is-active "ipip-keepalive-${tid}.service" 2>/dev/null || echo "inactive")

            local st_col="${RED}" wd_col="${DIM}" ka_col="${DIM}"
            [ "$st" = "active" ] && st_col="${GREEN}"
            [ "$wd_st" = "active" ] && wd_col="${GREEN}"
            [ "$ka_st" = "active" ] && ka_col="${GREEN}"

            printf "  %-4s %-8s ${st_col}%-7s${NC} %-16s %-16s %-10s ${wd_col}%-10s${NC} ${ka_col}%-10s${NC}\n" \
                "$tid" "$role" "$st" "${remote:-?}" "${tun_ip:-?}" "$traffic" "$wd_info" "$ka_st"
        done
    fi
    echo ""
}

# ─── Health Check ─────────────────────────────────────────────────
do_health_check() {
    echo ""
    echo -e " ${CYAN}${BOLD}Health Check - Pinging all IPIP tunnels...${NC}"
    print_line

    local all_ok=1
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        local tun_if="ipip${tid}"
        local script="${SCRIPTS_DIR}/ipip${tid}-up.sh"

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
            echo -e "  ${YELLOW}●${NC} ipip${tid}  ${YELLOW}[skip - no config]${NC}"
            continue
        fi

        if ! ip link show "${tun_if}" &>/dev/null; then
            echo -e "  ${RED}●${NC} ipip${tid}  ${RED}[interface missing]${NC}"
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
            echo -e "  ${GREEN}●${NC} ipip${tid} → ${tun_ip}  ${GREEN}[OK]${NC}  ${DIM}${rtt}${NC}"
        else
            echo -e "  ${RED}●${NC} ipip${tid} → ${tun_ip}  ${RED}[FAIL]${NC}"
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
    echo -e " ${CYAN}${BOLD}Detected IPIP Tunnels:${NC}"
    print_line

    local found=0 i=1
    TUNNEL_LIST=()
    TUNNEL_ID_LIST=()

    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        found=1
        local name="ipip-tunnel-${tid}"
        local tun_if="ipip${tid}"
        local status
        status=$(systemctl is-active "${name}" 2>/dev/null || echo "inactive")
        TUNNEL_LIST+=("${name}")
        TUNNEL_ID_LIST+=("${tid}")

        local remote="" role="?"
        local script="${SCRIPTS_DIR}/ipip${tid}-up.sh"
        if [ -f "$script" ]; then
            remote=$(grep '^REMOTE_REAL=' "$script" 2>/dev/null | cut -d'"' -f2)
            local lt
            lt=$(grep '^LOCAL_TUN=' "$script" 2>/dev/null | cut -d'"' -f2)
            [[ "$lt" == *".1/"* ]] && role="IR" || role="KH"
        fi

        local if_info="dev missing"
        if ip link show "${tun_if}" &>/dev/null; then
            if_info="dev ${tun_if} UP"
        fi

        if [ "$status" = "active" ]; then
            echo -e "  ${GREEN}●${NC} ${BOLD}${i})${NC} ${name}  ${GREEN}[active]${NC}  ${DIM}(${if_info}, ${role} → ${remote:-?})${NC}"
        else
            echo -e "  ${RED}●${NC} ${BOLD}${i})${NC} ${name}  ${RED}[${status}]${NC}  ${DIM}(${if_info}, ${role} → ${remote:-?})${NC}"
        fi
        ((i++))
    done

    [ $found -eq 0 ] && { msg_warn "No IPIP/FOU tunnels found."; return 1; }
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
    elif [[ "$pick" =~ ^ipip([0-9]+)$ ]] && printf '%s\n' "${TUNNEL_ID_LIST[@]}" | grep -qx "${BASH_REMATCH[1]}"; then
        SELECTED_TID="${BASH_REMATCH[1]}"
    elif [[ "$pick" =~ ^ipip-tunnel-([0-9]+)(\.service)?$ ]] && printf '%s\n' "${TUNNEL_ID_LIST[@]}" | grep -qx "${BASH_REMATCH[1]}"; then
        SELECTED_TID="${BASH_REMATCH[1]}"
    fi

    if [ -z "$SELECTED_TID" ]; then
        msg_err "Tunnel '${pick}' not found in detected tunnels."
        return 1
    fi

    SELECTED_TUNNEL="ipip-tunnel-${SELECTED_TID}"
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
    local tun_if="ipip${tid}"
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  TUNNEL ${tid} DETAILS (IPIP)${NC}"
    print_double_line

    local script="${SCRIPTS_DIR}/ipip${tid}-up.sh"
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
        fp=$(grep '^FOU_PORT=' "$script" 2>/dev/null | cut -d'"' -f2)
        local role="Kharej"; [[ "$lt" == *".1/"* ]] && role="Iran"

        echo -e "  ${MAGENTA}Role:${NC}          ${BOLD}${role}${NC}"
        echo -e "  ${MAGENTA}Encapsulation:${NC} ${BOLD}IPIP over FOU (ipproto 4)${NC}"
        echo -e "  ${MAGENTA}FOU Port:${NC}      ${BOLD}${fp:-N/A}${NC}"
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
        while read -r l; do echo -e "    $l"; done

    local ka_st
    ka_st=$(systemctl is-active "ipip-keepalive-${tid}.service" 2>/dev/null || echo "inactive")
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
    wd_st=$(systemctl is-active "ipip-watchdog-${tid}.timer" 2>/dev/null || echo "inactive")
    local fails
    fails=$(cat "/tmp/.wd_ipip${tid}" 2>/dev/null || echo 0)
    echo -e "  ${CYAN}Watchdog:${NC}  ${wd_st}  fails: ${fails}/3"

    echo ""
    print_line
    echo -e "  ${CYAN}nftables (fw_ipip_${tid}):${NC}"
    nft list table ip "fw_ipip_${tid}" 2>/dev/null | head -20 || msg_warn "  Table not found."
    echo ""
}

do_delete() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local tun_if="ipip${tid}"
    local svc_name="ipip-tunnel-${tid}"
    local up_script="${SCRIPTS_DIR}/ipip${tid}-up.sh"
    local down_script="${SCRIPTS_DIR}/ipip${tid}-down.sh"
    local wd_script="${SCRIPTS_DIR}/ipip${tid}-watchdog.sh"

    echo ""
    echo -e " ${RED}${BOLD}This will permanently delete Tunnel ${tid} (${tun_if}) and ALL its components.${NC}"
    echo -e "  ${GREEN}1)${NC} Yes, delete Tunnel ${tid} (y)"
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

    # 1. Detect FOU port before deleting scripts
    local fou_port=""
    if [ -f "$up_script" ]; then
        fou_port=$(grep '^FOU_PORT=' "$up_script" 2>/dev/null | cut -d'"' -f2)
    fi
    if [ -z "$fou_port" ] && [ -f "$down_script" ]; then
        fou_port=$(grep '^FOU_PORT=' "$down_script" 2>/dev/null | cut -d'"' -f2)
    fi

    # 2. Stop and disable watchdog FIRST so it cannot resurrect the tunnel!
    systemctl stop "ipip-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl disable "ipip-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl stop "ipip-watchdog-${tid}.service" 2>/dev/null || true
    systemctl disable "ipip-watchdog-${tid}.service" 2>/dev/null || true
    pkill -9 -f "ipip${tid}-watchdog.sh" 2>/dev/null || true

    # 3. Stop and disable keepalive service & kill any orphaned ping loops
    systemctl stop "ipip-keepalive-${tid}.service" 2>/dev/null || true
    systemctl disable "ipip-keepalive-${tid}.service" 2>/dev/null || true
    pkill -9 -f "ping.*-I ${tun_if}" 2>/dev/null || true

    # 4. Stop and disable main tunnel service
    systemctl stop "${svc_name}.service" 2>/dev/null || true
    systemctl disable "${svc_name}.service" 2>/dev/null || true

    # 5. Execute down script directly
    if [ -f "$down_script" ]; then
        bash "$down_script" 2>/dev/null || true
    fi

    # 6. Direct kernel & interface cleanup
    ip link set dev "${tun_if}" down 2>/dev/null || true
    ip tunnel del "${tun_if}" 2>/dev/null || true
    ip link del "${tun_if}" 2>/dev/null || true

    # 7. nftables cleanup
    nft delete table ip "fw_ipip_${tid}" 2>/dev/null || true

    # 8. Clean up FOU UDP port if no other tunnel is using it
    if [ -n "$fou_port" ]; then
        local other_using=0
        for s in "${SCRIPTS_DIR}"/ipip*-up.sh; do
            [ -f "$s" ] || continue
            [ "$s" = "$up_script" ] && continue
            if grep -q "FOU_PORT=\"${fou_port}\"" "$s" 2>/dev/null; then
                other_using=1
                break
            fi
        done
        if [ $other_using -eq 0 ]; then
            fuser -k -9 -n udp "${fou_port}" 2>/dev/null || true
            ip fou del port "${fou_port}" 2>/dev/null || true
        fi
    fi

    # 9. Remove all systemd unit files and symlinks
    rm -f "${SYSTEMD_DIR}/${svc_name}.service"
    rm -f "${SYSTEMD_DIR}/ipip-keepalive-${tid}.service"
    rm -f "${SYSTEMD_DIR}/ipip-watchdog-${tid}.service"
    rm -f "${SYSTEMD_DIR}/ipip-watchdog-${tid}.timer"
    rm -f "${SYSTEMD_DIR}/multi-user.target.wants/${svc_name}.service"
    rm -f "${SYSTEMD_DIR}/multi-user.target.wants/ipip-keepalive-${tid}.service"
    rm -f "${SYSTEMD_DIR}/timers.target.wants/ipip-watchdog-${tid}.timer"

    # 10. Remove scripts and tracking files
    rm -f "$up_script"
    rm -f "$down_script"
    rm -f "$wd_script"
    rm -f "/tmp/.wd_${tun_if}"

    # 11. Reload systemd daemon and reset failed units
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    msg_ok "Tunnel ${tid} (${tun_if}) and ALL its components were completely removed!"
}

do_view_scripts() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local up="${SCRIPTS_DIR}/ipip${tid}-up.sh"
    local down="${SCRIPTS_DIR}/ipip${tid}-down.sh"
    local wd="${SCRIPTS_DIR}/ipip${tid}-watchdog.sh"
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
        echo -e " ${BOLD}${WHITE}Setup IPIP over FOU${NC}"
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
        echo ""
        echo -e " ${BOLD}${WHITE}Watchdog${NC}"
        echo -e "  ${MAGENTA}16)${NC} Watchdog Management (Status/Start/Stop/Logs/Test)"
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
if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
    echo "IPIP over FOU Tunnel v${VERSION}"
    exit 0
fi

check_root
main_menu
