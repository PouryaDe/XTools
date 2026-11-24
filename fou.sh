#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  GRE OVER FOU TUNNEL MANAGER v2.3.0                            ║
# ║  Hardened Multi-Tunnel Setup (Foo-over-UDP + Atomic nftables)  ║
# ╚════════════════════════════════════════════════════════════════╝

VERSION="2.3.0"

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
STATE_DIR="/run/xmanager-gre"

# ─── UI Helpers ───────────────────────────────────────────────────
print_line() { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }
print_double_line() { echo -e "${CYAN}════════════════════════════════════════════════════${NC}"; }

print_header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════════╗"
    echo " ║      GRE OVER FOU TUNNEL MANAGER v${VERSION}        ║"
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

format_bytes() {
    local bytes="${1:-0}"
    [[ ! "$bytes" =~ ^[0-9]+$ ]] && bytes=0
    if [ "$bytes" -ge 1073741824 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2f GB", b/1073741824}'
    elif [ "$bytes" -ge 1048576 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1f MB", b/1048576}'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.1f KB", b/1024}'
    else
        echo "${bytes} B"
    fi
}

extract_up_var() {
    local key="$1" file="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | head -1 | sed -E "s/^${key}=//; s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//" | tr -d '\r'
}

derive_remote_tun_from_local() {
    local lt="$1"
    local subnet_prefix
    subnet_prefix=$(echo "$lt" | sed -E 's/\.[0-9]+\/[0-9]+$//')
    if [[ "$subnet_prefix" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]; then
        if [[ "$lt" == *".1/"* ]]; then
            echo "${subnet_prefix}.2"
        else
            echo "${subnet_prefix}.1"
        fi
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

validate_subnet_prefix() {
    local sub="$1"
    local rx='^([0-9]{1,3}\.){2}[0-9]{1,3}$'
    if [[ ! "$sub" =~ $rx ]]; then
        return 1
    fi
    local IFS='.'
    local -a octets=($sub)
    for octet in "${octets[@]}"; do
        if (( 10#$octet < 0 || 10#$octet > 255 )); then
            return 1
        fi
    done
    return 0
}

is_tunnel_subnet_in_use() {
    local s="$1"
    local exclude_if="${2:-${TUN_IF:-}}"
    if ip -o -4 addr show 2>/dev/null | awk -v iface="${exclude_if}" '$2 != iface' | grep -Fq "inet ${s}."; then
        return 0
    fi
    if [ -n "$exclude_if" ]; then
        if ip -4 route show 2>/dev/null | grep -vE "dev ${exclude_if}([[:space:]]|$)" | grep -Fq "${s}."; then
            return 0
        fi
    else
        if ip -4 route show 2>/dev/null | grep -Fq "${s}."; then
            return 0
        fi
    fi
    local sc
    for sc in "${SCRIPTS_DIR}"/*-up.sh; do
        [ -f "$sc" ] || continue
        [ -n "$exclude_if" ] && [ "$sc" = "${SCRIPTS_DIR}/${exclude_if}-up.sh" ] && continue
        if grep -Fq "LOCAL_TUN=\"${s}." "$sc" 2>/dev/null || grep -Fq "LOCAL_TUN='${s}." "$sc" 2>/dev/null || grep -Fq "LOCAL_TUN=${s}." "$sc" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

find_free_tunnel_subnet() {
    local proto_base="$1"  # e.g. 10.80
    local tid="$2"         # e.g. 1
    local cand="${proto_base}.${tid}"
    local oct2
    oct2=$(echo "$proto_base" | cut -d. -f2)

    if ! is_tunnel_subnet_in_use "$cand" "${TUN_IF:-}"; then
        echo "$cand"
        return 0
    fi

    local i=1
    while [ $i -le 254 ]; do
        cand="${proto_base}.${i}"
        if ! is_tunnel_subnet_in_use "$cand" "${TUN_IF:-}"; then
            echo "$cand"
            return 0
        fi
        i=$(( i + 1 ))
    done
    echo "10.$(( oct2 + 10 )).${tid}"
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

read_tunnel_id() {
    local var_name="$1"
    local tid=""
    while true; do
        read_input "Tunnel ID (number between 1 and 255)" "" tid
        tid=$(echo "$tid" | tr -d '\r\n[:space:]')
        if [ -z "$tid" ]; then
            msg_err "Tunnel ID is required! Please enter a number between 1 and 255."
            continue
        fi
        if ! [[ "$tid" =~ ^[0-9]+$ ]] || [ "$tid" -lt 1 ] || [ "$tid" -gt 255 ]; then
            msg_err "Invalid Tunnel ID '${tid}'! Must be an integer between 1 and 255."
            continue
        fi

        local tun_dev="gre${tid}"
        local svc_file="${SYSTEMD_DIR}/gre-tunnel-${tid}.service"
        local up_file="${SCRIPTS_DIR}/gre${tid}-up.sh"
        if [ -f "$svc_file" ] || [ -f "$up_file" ] || ip link show "$tun_dev" &>/dev/null; then
            msg_warn "Tunnel ID ${tid} (${tun_dev}) already exists on this server!"
            read -p "  Do you want to overwrite and reconfigure it? (y/N): " ow_choice
            if [[ "$ow_choice" =~ ^[Yy]$ ]]; then
                printf -v "$var_name" "%s" "$tid"
                return 0
            else
                msg_info "Please choose a different Tunnel ID."
                continue
            fi
        fi

        printf -v "$var_name" "%s" "$tid"
        return 0
    done
}

read_interface() {
    local prompt="$1" default="$2" var_name="$3"
    local iface=""
    while true; do
        read_input "$prompt" "$default" iface
        iface=$(echo "$iface" | tr -d '\r\n[:space:]')
        [ -z "$iface" ] && iface="$default"
        if [ -z "$iface" ]; then
            msg_err "Interface name cannot be empty."
            continue
        fi
        if [[ ! "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]] || [ "${#iface}" -gt 20 ]; then
            msg_err "Invalid interface name '${iface}'. Allowed characters: alphanumeric, '.', '_', ':', '-' (max 20 chars)."
            continue
        fi
        if ip link show "$iface" &>/dev/null; then
            printf -v "$var_name" "%s" "$iface"
            return 0
        else
            msg_warn "Interface '${iface}' does not currently exist on this system!"
            read -p "  Are you sure you want to use interface '${iface}'? (y/N): " if_confirm
            if [[ "$if_confirm" =~ ^[Yy]$ ]]; then
                printf -v "$var_name" "%s" "$iface"
                return 0
            fi
            msg_info "Please enter a valid network interface name."
        fi
    done
}

get_default_fou_port() {
    local tid="$1"
    local target_proto="$2" # 47 for GRE, 4 for IPIP
    local my_script="${SCRIPTS_DIR}/gre${tid}-up.sh"
    local my_prev_port=""
    [ -f "$my_script" ] && my_prev_port=$(extract_up_var "FOU_PORT" "$my_script")

    is_fou_port_in_use() {
        local p="$1"

        # Always reject UDP ports bound by a user-space process (e.g. Xray, OpenVPN, WireGuard)
        if ss -Hulnp 2>/dev/null | awk -v port="$p" '$4 ~ ":" port "$" && /users:\(/ {found=1} END{exit !found}'; then
            return 0
        fi

        # Check kernel FOU table (both ipproto and gue modes)
        local efp
        efp=$(ip fou show 2>/dev/null | awk -v port="$p" '$2 == port {if ($3=="gue") print "gue"; else print $4}' | head -1)
        if [ -n "$efp" ]; then
            if [ -n "$my_prev_port" ] && [ "$p" = "$my_prev_port" ] && [ "$efp" = "$target_proto" ]; then
                :
            else
                return 0
            fi
        fi

        # Check other tunnel up-scripts across all protocols
        local s
        for s in "${SCRIPTS_DIR}"/*-up.sh; do
            [ -f "$s" ] || continue
            [ "$s" = "$my_script" ] && continue
            if grep -Eq "^(FOU_PORT|AWG_PORT|XDP_PORT|GENEVE_PORT|VXLAN_PORT)=[\"']?${p}[\"']?$" "$s" 2>/dev/null; then
                return 0
            fi
        done

        # Reject any other active kernel UDP listener unless it belongs to this tunnel's previous port
        if [ "$p" != "$my_prev_port" ] && ss -Hulnp 2>/dev/null | awk -v port="$p" '$4 ~ ":" port "$" {found=1} END{exit !found}'; then
            return 0
        fi
        return 1
    }

    local cand=""
    if [ -n "$my_prev_port" ] && ! is_fou_port_in_use "$my_prev_port"; then
        cand="$my_prev_port"
    else
        # Standard UDP service ports avoid ISP/Anti-DDoS rate-limiting on WireGuard ports (51820-51850)
        local preferred_ports=(4500 8443 1194 500 3478 2083 2096 2053 2087 443)
        local pp
        for pp in "${preferred_ports[@]}"; do
            if ! is_fou_port_in_use "$pp"; then
                cand="$pp"
                break
            fi
        done
    fi

    if [ -z "$cand" ]; then
        cand=$(( 10000 + tid ))
        local loops=0
        while is_fou_port_in_use "$cand"; do
            cand=$(( cand + 1 ))
            [ "$cand" -gt 65535 ] && cand=10000
            loops=$(( loops + 1 ))
            [ "$loops" -gt 1000 ] && break
        done
    fi
    echo "$cand"
}

read_fou_port() {
    local prompt="$1" default="$2" target_proto="$3" var_name="$4"
    local val=""
    while true; do
        read_input "$prompt" "$default" val
        val=$(echo "$val" | tr -d '\r\n[:space:]')
        if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ] || [ "$val" -gt 65535 ]; then
            msg_err "Invalid port number '${val}'. Must be between 1 and 65535."
            continue
        fi

        # Reject ports bound by an active user-space UDP service
        if ss -Hulnp 2>/dev/null | awk -v port="$val" '$4 ~ ":" port "$" && /users:\(/ {found=1} END{exit !found}'; then
            msg_err "UDP port ${val} is already bound by an active user-space service on this server!"
            msg_err "Please choose an unused UDP port (e.g., 4500, 8443, 1194)."
            continue
        fi

        # Check kernel FOU table for protocol conflict (including GUE)
        local existing_fou_proto
        existing_fou_proto=$(ip fou show 2>/dev/null | awk -v p="$val" '$2 == p {if ($3=="gue") print "gue"; else print $4}' | head -1)
        if [ -n "$existing_fou_proto" ] && [ "$existing_fou_proto" != "$target_proto" ]; then
            local p_curr="ipproto ${existing_fou_proto}" p_req="Unknown"
            [ "$existing_fou_proto" = "4" ] && p_curr="IPIP (ipproto 4)"
            [ "$existing_fou_proto" = "47" ] && p_curr="GRE (ipproto 47)"
            [ "$existing_fou_proto" = "gue" ] && p_curr="GUE (Generic UDP Encapsulation)"
            [ "$target_proto" = "4" ] && p_req="IPIP (ipproto 4)"
            [ "$target_proto" = "47" ] && p_req="GRE (ipproto 47)"
            msg_err "Port ${val} is already registered in Linux kernel FOU for ${p_curr}!"
            msg_err "A single UDP port cannot handle both ${p_curr} and ${p_req} simultaneously."
            msg_err "Please choose a different port (e.g., 4500, 8443, 1194)."
            continue
        fi

        # Check existing tunnel up-scripts for conflicting protocol or non-FOU UDP port usage
        local conflict_script="" conflict_reason="" s
        for s in "${SCRIPTS_DIR}"/*-up.sh; do
            [ -f "$s" ] || continue
            [ -n "${TUN_IF:-}" ] && [ "$s" = "${SCRIPTS_DIR}/${TUN_IF}-up.sh" ] && continue
            if grep -Eq "^FOU_PORT=[\"']?${val}[\"']?$" "$s" 2>/dev/null; then
                if [ "$target_proto" = "47" ] && grep -qE 'ipproto 4([^0-9]|$)' "$s" 2>/dev/null; then
                    conflict_script="$s"
                    conflict_reason="IPIP over FOU"
                    break
                elif [ "$target_proto" = "4" ] && grep -qE 'ipproto 47([^0-9]|$)' "$s" 2>/dev/null; then
                    conflict_script="$s"
                    conflict_reason="GRE over FOU"
                    break
                fi
            elif grep -Eq "^(AWG_PORT|XDP_PORT|GENEVE_PORT|VXLAN_PORT)=[\"']?${val}[\"']?$" "$s" 2>/dev/null; then
                conflict_script="$s"
                conflict_reason="another tunnel protocol"
                break
            fi
        done
        if [ -n "$conflict_script" ]; then
            msg_err "Port ${val} is configured in '${conflict_script}' (${conflict_reason})!"
            msg_err "Please select an independent port to prevent tunnel failure."
            continue
        fi

        if [ "$val" -ge 51820 ] && [ "$val" -le 51850 ]; then
            msg_warn "Port ${val} is in the WireGuard range (51820-51850), which some ISPs/Anti-DDoS rate-limit. Standard UDP ports (4500, 8443, 1194, 443) are recommended."
        fi

        printf -v "$var_name" "%s" "$val"
        return 0
    done
}

read_gre_key() {
    local prompt="$1" default="$2" var_name="$3"
    local val=""
    while true; do
        read_input "$prompt" "$default" val
        val=$(echo "$val" | tr -d '\r\n[:space:]')
        if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 0 ] && [ "$val" -le 4294967295 ] 2>/dev/null; then
            printf -v "$var_name" "%s" "$val"
            return 0
        else
            msg_err "Invalid GRE key '${val}'. Must be a number between 0 and 4294967295."
        fi
    done
}

read_mtu() {
    local prompt="$1" default="$2" var_name="$3"
    local val=""
    while true; do
        read_input "$prompt" "$default" val
        val=$(echo "$val" | tr -d '\r\n[:space:]')
        [ -z "$val" ] && val="$default"
        if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1280 ] && [ "$val" -le 1464 ]; then
            printf -v "$var_name" "%s" "$val"
            return 0
        else
            msg_err "Invalid MTU '${val}'. Must be an integer between 1280 and 1464."
        fi
    done
}

# ─── Auto-Detect ──────────────────────────────────────────────────
detect_interface() {
    local iface=""
    iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [ -z "$iface" ]; then
        iface=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v -E '^(lo|gre.*|ipip.*|awg.*|ftcp.*|gnv.*|vxlan.*|xdptun.*|mpbond.*|tun.*|tap.*|docker.*|veth.*|erspan.*)$' | head -1)
    fi
    [ -z "$iface" ] && iface="eth0"
    echo "$iface"
}

detect_public_ip() {
    local ip="" iface="${1:-}"
    [ -z "$iface" ] && iface=$(detect_interface)
    if [ -n "$iface" ]; then
        ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
    fi
    if [ -z "$ip" ] || [[ "$ip" =~ ^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]]; then
        local ext_ip
        ext_ip=$(curl -s4 --connect-timeout 2 --max-time 4 https://api.ipify.org 2>/dev/null || curl -s4 --connect-timeout 2 --max-time 4 https://ifconfig.me 2>/dev/null || true)
        if validate_ipv4 "$ext_ip"; then
            ip="$ext_ip"
        fi
    fi
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

# ─── Prerequisites & Kernel Persistence ───────────────────────────
write_modules_load_conf() {
    mkdir -p /etc/modules-load.d
    cat > /etc/modules-load.d/99-xmanager-gre.conf << 'EOF'
# XManager GRE over FOU required kernel modules
ip_gre
fou
tcp_bbr
nf_conntrack
EOF
}

check_prereqs_ready() {
    local missing=0
    local cmd mod
    for cmd in nft ip ethtool ping; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_warn "Required command '${cmd}' not found."
            missing=1
        fi
    done
    for mod in ip_gre fou; do
        if ! modprobe "$mod" 2>/dev/null; then
            msg_warn "Kernel module '${mod}' could not be loaded."
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        read -p "  Install missing prerequisites now? (Y/n): " inst_choice
        if [[ ! "$inst_choice" =~ ^[Nn]$ ]]; then
            install_prereqs || return 1
        fi
    fi
    return 0
}

install_prereqs() {
    echo ""
    msg_info "Checking prerequisites..."
    local need_install=0

    for cmd in nft ethtool ping curl; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_warn "Required command '${cmd}' not found."
            need_install=1
        fi
    done

    if [ $need_install -eq 1 ]; then
        msg_info "Installing missing dependencies..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq nftables iproute2 iputils-ping ethtool curl procps
        elif command -v yum &>/dev/null; then
            yum install -y -q nftables iproute iputils ethtool curl procps-ng
        elif command -v dnf &>/dev/null; then
            dnf install -y -q nftables iproute iputils ethtool curl procps-ng
        else
            msg_err "Cannot detect package manager. Please install nftables, iproute2, ethtool, and iputils-ping manually."
            return 1
        fi
    fi

    for mod in ip_gre fou tcp_bbr nf_conntrack; do
        if ! modprobe "$mod" 2>/dev/null; then
            msg_warn "Kernel module '${mod}' not loaded or unavailable."
        else
            msg_ok "Kernel module '${mod}' ready."
        fi
    done

    write_modules_load_conf
    msg_ok "Persistent modules config written: /etc/modules-load.d/99-xmanager-gre.conf"
    msg_ok "All prerequisites verified."
}

persist_sysctl_tuning() {
    write_modules_load_conf

    local mem_kb mem_mb MAX_BUF CT_MAX CT_HASH
    mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 4194304)
    [[ ! "$mem_kb" =~ ^[0-9]+$ ]] && mem_kb=4194304
    mem_mb=$(( mem_kb / 1024 ))

    if [ "$mem_mb" -le 2048 ]; then
        MAX_BUF=16777216
        CT_MAX=524288
        CT_HASH=131072
    else
        MAX_BUF=33554432
        CT_MAX=2097152
        CT_HASH=524288
    fi

    cat > /etc/sysctl.d/99-xmanager-tunnel.conf << EOF
# XManager High-Speed Kernel & Network Tuning (RAM-scaled: ${mem_mb}MB)
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

# High-Performance Buffer Sizes (RAM-aware)
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = ${MAX_BUF}
net.core.wmem_max = ${MAX_BUF}
net.core.optmem_max = 2097152
net.ipv4.tcp_rmem = 4096 87380 ${MAX_BUF}
net.ipv4.tcp_wmem = 4096 65536 ${MAX_BUF}
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
net.core.netdev_budget = 1200
net.core.netdev_budget_usecs = 8000
net.core.dev_weight = 128

# Connection Scalability & Limits
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 100000
net.ipv4.tcp_max_syn_backlog = 100000
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_udp_timeout = 15
net.netfilter.nf_conntrack_udp_timeout_stream = 45
EOF

    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true
    sysctl -p /etc/sysctl.d/99-xmanager-tunnel.conf >/dev/null 2>&1 || true
    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        echo "${CT_HASH}" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    fi
}

# ─── Generate FOU-UP Script ──────────────────────────────────────
generate_gre_up() {
    local script_path="$1"
    local tun_mtu="${TUN_MTU:-1392}"

    cat > "${script_path}" << GREHDR
#!/usr/bin/env bash
set -euo pipefail

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
TUN_MTU="${tun_mtu}"

NFT_TABLE="fw_gre_${TUNNEL_ID}"
LEGACY_NFT_TABLE="fw_${TUNNEL_ID}"
STATE_DIR="${STATE_DIR}"
GREHDR

    cat >> "${script_path}" << 'GREBODY'
# Clear any intentional-stop marker when starting up
mkdir -p -m 700 "${STATE_DIR}"
rm -f "${STATE_DIR}/${TUN_IF}.stopped"

# Load required kernel modules and apply persistent sysctl tuning
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
modprobe ip_gre 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-xmanager-tunnel.conf >/dev/null 2>&1 || true

# Disable rp_filter on WAN (converts dots to slashes for VLAN sub-interfaces)
SYSCTL_WAN="${IF_WAN//./\/}"
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w "net.ipv4.conf.${SYSCTL_WAN}.rp_filter=0" >/dev/null 2>&1 || true

# Wait up to 10s for WAN interface to appear during boot
wait_cnt=0
while ! ip link show "${IF_WAN}" >/dev/null 2>&1; do
    wait_cnt=$((wait_cnt + 1))
    if [ "$wait_cnt" -ge 10 ]; then
        echo "ERROR: WAN interface '${IF_WAN}' not found after 10s!" >&2
        exit 1
    fi
    sleep 1
done

# Clean up any leftover tunnel interface
ip link set dev "${TUN_IF}" down 2>/dev/null || true
ip tunnel del "${TUN_IF}" 2>/dev/null || true
ip link del "${TUN_IF}" 2>/dev/null || true

# Create GRE tunnel (with Foo-over-UDP encapsulation and UDP checksum enabled)
if [ "${FOU_ENABLE}" = "yes" ]; then
    modprobe fou 2>/dev/null || true
    EXISTING_PROTO=$(ip fou show 2>/dev/null | awk -v p="${FOU_PORT}" '$2 == p {if ($3=="gue") print "gue"; else print $4}' | head -1 || true)
    if [ -n "${EXISTING_PROTO}" ] && [ "${EXISTING_PROTO}" != "47" ]; then
        echo "ERROR: FOU port ${FOU_PORT} is already bound to ${EXISTING_PROTO}! Cannot bind GRE (ipproto 47)." >&2
        exit 1
    fi
    if [ -z "${EXISTING_PROTO}" ]; then
        ip fou add port "${FOU_PORT}" ipproto 47
    fi
    ip link add name "${TUN_IF}" type gre local "${LOCAL_REAL}" remote "${REMOTE_REAL}" ttl 64 key "${GRE_KEY}" encap fou encap-csum encap-sport auto encap-dport "${FOU_PORT}"
    MTU="${TUN_MTU:-1392}"
    MSS=$(( MTU - 40 ))
else
    ip link add name "${TUN_IF}" type gre local "${LOCAL_REAL}" remote "${REMOTE_REAL}" ttl 64 key "${GRE_KEY}"
    MTU="${TUN_MTU:-1400}"
    MSS=$(( MTU - 40 ))
fi

# Configure tunnel interface parameters BEFORE bringing link UP (prevents IPv6 RS / rp_filter race)
sysctl -w "net.ipv6.conf.${TUN_IF}.disable_ipv6=1" >/dev/null 2>&1 || true
sysctl -w "net.ipv4.conf.${TUN_IF}.rp_filter=0" >/dev/null 2>&1 || true
ip addr replace "${LOCAL_TUN}" dev "${TUN_IF}" 2>/dev/null || ip addr add "${LOCAL_TUN}" dev "${TUN_IF}"
ip link set "${TUN_IF}" mtu "${MTU}"
ip link set "${TUN_IF}" txqueuelen 10000
ethtool -K "${TUN_IF}" tso off gso off gro off 2>/dev/null || true
ip link set "${TUN_IF}" up

# Route advmss tuning forces locally originated TCP sockets to clamp MSS automatically
TUN_SUBNET=$(echo "${LOCAL_TUN}" | sed -E 's/\.[0-9]+\//.0\//')
LOCAL_IP_ONLY=$(echo "${LOCAL_TUN}" | cut -d/ -f1)
ip route replace "${TUN_SUBNET}" dev "${TUN_IF}" proto kernel scope link src "${LOCAL_IP_ONLY}" advmss "${MSS}" 2>/dev/null || true

# Non-disruptive WAN ring buffer tuning (only increase if current < target; avoids link reset on restart)
RING_INFO=$(ethtool -g "${IF_WAN}" 2>/dev/null || true)
if [ -n "${RING_INFO}" ]; then
    read -r MAX_RX MAX_TX CUR_RX CUR_TX < <(echo "${RING_INFO}" | awk '
        /^Pre-set maximums:/ { sec="max"; next }
        /^Current hardware settings:/ { sec="cur"; next }
        /^RX:[[:space:]]+/ { if (sec=="max") mr=$2; else if (sec=="cur") cr=$2 }
        /^TX:[[:space:]]+/ { if (sec=="max") mt=$2; else if (sec=="cur") ct=$2 }
        END { printf "%s %s %s %s\n", (mr==""?"n/a":mr), (mt==""?"n/a":mt), (cr==""?"n/a":cr), (ct==""?"n/a":ct) }
    ')
    RING_ARGS=()
    if [[ "${MAX_RX}" =~ ^[0-9]+$ ]] && [[ "${CUR_RX}" =~ ^[0-9]+$ ]]; then
        TGT_RX=4096; [ "${MAX_RX}" -lt "${TGT_RX}" ] && TGT_RX="${MAX_RX}"
        [ "${TGT_RX}" -gt 0 ] && [ "${CUR_RX}" -lt "${TGT_RX}" ] && RING_ARGS+=(rx "${TGT_RX}")
    fi
    if [[ "${MAX_TX}" =~ ^[0-9]+$ ]] && [[ "${CUR_TX}" =~ ^[0-9]+$ ]]; then
        TGT_TX=4096; [ "${MAX_TX}" -lt "${TGT_TX}" ] && TGT_TX="${MAX_TX}"
        [ "${TGT_TX}" -gt 0 ] && [ "${CUR_TX}" -lt "${TGT_TX}" ] && RING_ARGS+=(tx "${TGT_TX}")
    fi
    if [ ${#RING_ARGS[@]} -gt 0 ]; then
        ethtool -G "${IF_WAN}" "${RING_ARGS[@]}" 2>/dev/null || true
    fi
fi
ip link set dev "${IF_WAN}" txqueuelen 10000 2>/dev/null || true

# Keep WAN GRO/GSO/TSO enabled for high-PPS forwarding efficiency; disable UDP tunnel segmentation only
ethtool -K "${IF_WAN}" tso on gso on gro on 2>/dev/null || true
ethtool -K "${IF_WAN}" tx-udp_tnl-segmentation off tx-udp_tnl-csum-segmentation off 2>/dev/null || true

# Qdisc: Fair Queue with elevated flow_limit to prevent burst tail drops
tc qdisc replace dev "${IF_WAN}" root fq flow_limit 1000 2>/dev/null || tc qdisc replace dev "${IF_WAN}" root fq 2>/dev/null || true
tc qdisc replace dev "${TUN_IF}" root fq flow_limit 1000 2>/dev/null || tc qdisc replace dev "${TUN_IF}" root fq 2>/dev/null || true

# Smart RPS & RFS: distribute packets across CPU cores only when RX queues < cores (preserve hardware RSS)
CORES=$(nproc 2>/dev/null || echo 1)
RX_QUEUES=$({ find "/sys/class/net/${IF_WAN}/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null || true; } | wc -l | tr -d '[:space:]')
[[ ! "${RX_QUEUES}" =~ ^[0-9]+$ ]] && RX_QUEUES=0
if [ "${CORES}" -gt 1 ] && [ "${RX_QUEUES}" -gt 0 ] && [ "${RX_QUEUES}" -lt "${CORES}" ]; then
    if [ "${CORES}" -ge 32 ]; then
        RPS_MASK="ffffffff"
    else
        RPS_MASK=$(printf '%x' $(( (1 << CORES) - 1 )))
    fi
    FLOW_PER_Q=$(( 32768 / RX_QUEUES ))
    [ "${FLOW_PER_Q}" -lt 2048 ] && FLOW_PER_Q=2048
    for q in /sys/class/net/${IF_WAN}/queues/rx-*/rps_cpus; do
        [ -f "${q}" ] && echo "${RPS_MASK}" > "${q}" 2>/dev/null || true
    done
    for q in /sys/class/net/${IF_WAN}/queues/rx-*/rps_flow_cnt; do
        [ -f "${q}" ] && echo "${FLOW_PER_Q}" > "${q}" 2>/dev/null || true
    done
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
fi

# Surgically remove legacy fw_${ID} table if it belongs to this tunnel
if nft list table ip "${LEGACY_NFT_TABLE}" 2>/dev/null | grep -qE "\"?${TUN_IF}\"?|fwd_mss"; then
    nft delete table ip "${LEGACY_NFT_TABLE}" 2>/dev/null || true
fi

# Determine whether stateless IP spoofing is enabled
DO_SPOOF=0
if [ -n "${LOCAL_SPOOF}" ] && [ -n "${REMOTE_SPOOF}" ] && { [ "${LOCAL_SPOOF}" != "${LOCAL_REAL}" ] || [ "${REMOTE_SPOOF}" != "${REMOTE_REAL}" ]; }; then
    DO_SPOOF=1
fi

# Apply atomic nftables ruleset (zero leak window + proper output/prerouting notrack + bidirectional MSS clamping)
{
    echo "table ip ${NFT_TABLE}"
    echo "delete table ip ${NFT_TABLE}"
    echo "table ip ${NFT_TABLE} {"
    echo "    chain prerouting {"
    echo "        type filter hook prerouting priority -300; policy accept;"
    if [ "${FOU_ENABLE}" = "yes" ]; then
        if [ "${DO_SPOOF}" -eq 1 ]; then
            echo "        iifname \"${IF_WAN}\" ip saddr ${REMOTE_SPOOF} ip daddr ${LOCAL_REAL} udp dport ${FOU_PORT} ip saddr set ${REMOTE_REAL} notrack"
        else
            echo "        iifname \"${IF_WAN}\" ip saddr ${REMOTE_REAL} ip daddr ${LOCAL_REAL} udp dport ${FOU_PORT} notrack"
        fi
    else
        if [ "${DO_SPOOF}" -eq 1 ]; then
            echo "        iifname \"${IF_WAN}\" ip protocol gre ip saddr ${REMOTE_SPOOF} ip daddr ${LOCAL_REAL} ip saddr set ${REMOTE_REAL} notrack"
        else
            echo "        iifname \"${IF_WAN}\" ip protocol gre ip saddr ${REMOTE_REAL} ip daddr ${LOCAL_REAL} notrack"
        fi
    fi
    echo "    }"
    echo "    chain output {"
    echo "        type filter hook output priority -300; policy accept;"
    if [ "${FOU_ENABLE}" = "yes" ]; then
        echo "        oifname \"${IF_WAN}\" ip saddr ${LOCAL_REAL} ip daddr ${REMOTE_REAL} udp dport ${FOU_PORT} notrack"
        echo "        oifname \"${IF_WAN}\" ip saddr ${LOCAL_REAL} ip daddr ${REMOTE_REAL} udp sport ${FOU_PORT} notrack"
    else
        echo "        oifname \"${IF_WAN}\" ip protocol gre ip saddr ${LOCAL_REAL} ip daddr ${REMOTE_REAL} notrack"
    fi
    echo "    }"
    if [ "${DO_SPOOF}" -eq 1 ]; then
        echo "    chain postrouting {"
        echo "        type filter hook postrouting priority 300; policy accept;"
        if [ "${FOU_ENABLE}" = "yes" ]; then
            echo "        oifname \"${IF_WAN}\" ip saddr ${LOCAL_REAL} ip daddr ${REMOTE_REAL} udp dport ${FOU_PORT} ip saddr set ${LOCAL_SPOOF}"
        else
            echo "        oifname \"${IF_WAN}\" ip protocol gre ip saddr ${LOCAL_REAL} ip daddr ${REMOTE_REAL} ip saddr set ${LOCAL_SPOOF}"
        fi
        echo "    }"
    fi
    echo "    chain fwd_mss {"
    echo "        type filter hook forward priority -150; policy accept;"
    echo "        oifname \"${TUN_IF}\" tcp flags & (syn | rst) == syn tcp option maxseg size > ${MSS} tcp option maxseg size set ${MSS}"
    echo "        iifname \"${TUN_IF}\" tcp flags & (syn | rst) == syn tcp option maxseg size > ${MSS} tcp option maxseg size set ${MSS}"
    echo "    }"
    echo "    chain out_mss {"
    echo "        type filter hook output priority -150; policy accept;"
    echo "        oifname \"${TUN_IF}\" tcp flags & (syn | rst) == syn tcp option maxseg size > ${MSS} tcp option maxseg size set ${MSS}"
    echo "    }"
    echo "}"
} | nft -f -

echo "GRE tunnel ${TUN_IF} UP (table: ${NFT_TABLE}, mtu: ${MTU}, mss: ${MSS})"
GREBODY
    chmod 750 "${script_path}"
}

# ─── Generate FOU-DOWN Script ────────────────────────────────────
generate_gre_down() {
    local script_path="$1"
    cat > "${script_path}" << GREHDR
#!/usr/bin/env bash
TUN_IF="${TUN_IF}"
NFT_TABLE="fw_gre_${TUNNEL_ID}"
LEGACY_NFT_TABLE="fw_${TUNNEL_ID}"
FOU_PORT="${FOU_PORT}"
STATE_DIR="${STATE_DIR}"
GREHDR

    cat >> "${script_path}" << 'GREBODY'
ip link set dev "${TUN_IF}" down 2>/dev/null || true
ip tunnel del "${TUN_IF}" 2>/dev/null || true
ip link del "${TUN_IF}" 2>/dev/null || true

nft delete table ip "${NFT_TABLE}" 2>/dev/null || true
if nft list table ip "${LEGACY_NFT_TABLE}" 2>/dev/null | grep -qE "\"?${TUN_IF}\"?|fwd_mss"; then
    nft delete table ip "${LEGACY_NFT_TABLE}" 2>/dev/null || true
fi

# Free FOU socket ONLY if no other up-script uses this FOU_PORT
if [ -n "${FOU_PORT}" ]; then
    other_using=0
    for s in /usr/local/bin/*-up.sh; do
        [ -f "$s" ] || continue
        [ "$s" = "/usr/local/bin/${TUN_IF}-up.sh" ] && continue
        if grep -Eq "^FOU_PORT=[\"']?${FOU_PORT}[\"']?$" "$s" 2>/dev/null; then
            other_using=1
            break
        fi
    done
    if [ "$other_using" -eq 0 ]; then
        ip fou del port "${FOU_PORT}" 2>/dev/null || true
    fi
fi

echo "GRE tunnel ${TUN_IF} DOWN (table: ${NFT_TABLE})"
GREBODY
    chmod 750 "${script_path}"
}

# ─── Generate Watchdog Script ─────────────────────────────────────
generate_watchdog() {
    local script_path="$1"
    cat > "${script_path}" << WDHDR
#!/usr/bin/env bash
TUN_IF="${TUN_IF}"
REMOTE_TUN="${REMOTE_TUN}"
SERVICE="gre-tunnel-${TUNNEL_ID}"
KA_SERVICE="gre-keepalive-${TUNNEL_ID}"
NFT_TABLE="fw_gre_${TUNNEL_ID}"
FOU_ENABLE="${FOU_ENABLE:-yes}"
FOU_PORT="${FOU_PORT:-}"
STATE_DIR="${STATE_DIR}"
MAX_FAIL=3
WDHDR

    cat >> "${script_path}" << 'WDBODY'
mkdir -p -m 700 "${STATE_DIR}"

if command -v flock >/dev/null 2>&1; then
    exec 9>"${STATE_DIR}/${TUN_IF}.lock"
    if ! flock -n 9; then
        exit 0
    fi
fi

FAIL_FILE="${STATE_DIR}/${TUN_IF}.fails"
RESTART_COUNT_FILE="${STATE_DIR}/${TUN_IF}.restarts"
LAST_RESTART_FILE="${STATE_DIR}/${TUN_IF}.last_restart"
TIER1_COUNT_FILE="${STATE_DIR}/${TUN_IF}.t1_restarts"
TIER1_LAST_FILE="${STATE_DIR}/${TUN_IF}.t1_last"
STOP_MARKER="${STATE_DIR}/${TUN_IF}.stopped"
LOG_TAG="wd-${TUN_IF}"

# Auto-detect REMOTE_TUN safely if missing
if [ -z "${REMOTE_TUN}" ]; then
    UP_SCRIPT="/usr/local/bin/${TUN_IF}-up.sh"
    if [ -f "${UP_SCRIPT}" ]; then
        LT=$(grep '^LOCAL_TUN=' "${UP_SCRIPT}" 2>/dev/null | head -1 | cut -d'"' -f2)
        SUBNET_PREFIX=$(echo "${LT}" | sed -E 's/\.[0-9]+\/[0-9]+$//')
        if [[ "${SUBNET_PREFIX}" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]; then
            if [[ "${LT}" == *".1/"* ]]; then
                REMOTE_TUN="${SUBNET_PREFIX}.2"
            else
                REMOTE_TUN="${SUBNET_PREFIX}.1"
            fi
        fi
    fi
fi

# Skip if disabled or intentionally stopped
if ! systemctl is-enabled "${SERVICE}" &>/dev/null || [ -f "${STOP_MARKER}" ]; then
    exit 0
fi

restart_stack() {
    local reason="$1"
    logger -t "${LOG_TAG}" "${reason} - restarting ${SERVICE}" 2>/dev/null || true
    systemctl restart "${SERVICE}" 2>/dev/null || true
    if systemctl list-unit-files "${KA_SERVICE}.service" --no-legend 2>/dev/null | grep -q "${KA_SERVICE}"; then
        systemctl restart "${KA_SERVICE}" 2>/dev/null || true
    fi
}

tier1_heal() {
    local reason="$1"
    local t1_cnt t1_last now elapsed
    t1_cnt=$(cat "${TIER1_COUNT_FILE}" 2>/dev/null | tr -d '[:space:]')
    [[ ! "${t1_cnt}" =~ ^[0-9]+$ ]] && t1_cnt=0
    t1_last=$(cat "${TIER1_LAST_FILE}" 2>/dev/null | tr -d '[:space:]')
    [[ ! "${t1_last}" =~ ^[0-9]+$ ]] && t1_last=0
    now=$(date +%s)
    elapsed=$((now - t1_last))

    # Allow first 2 local recoveries immediately; throttle repeated failures to 60s to prevent crash-loop spam
    if [ "${t1_cnt}" -ge 2 ] && [ "${elapsed}" -lt 60 ]; then
        local rem=$((60 - elapsed))
        logger -t "${LOG_TAG}" "${reason}; Tier-1 recovery throttled (${rem}s remaining)" 2>/dev/null || true
        exit 0
    fi

    restart_stack "${reason}"
    echo "${now}" > "${TIER1_LAST_FILE}" 2>/dev/null || true
    echo $((t1_cnt + 1)) > "${TIER1_COUNT_FILE}" 2>/dev/null || true
    echo 0 > "${FAIL_FILE}" 2>/dev/null || true
    exit 0
}

# Tier 1: Immediate local kernel & service integrity self-heal
if systemctl is-failed "${SERVICE}" &>/dev/null; then
    tier1_heal "Service ${SERVICE} is in failed state"
fi

if ! systemctl is-active "${SERVICE}" &>/dev/null; then
    exit 0
fi

if ! ip link show "${TUN_IF}" &>/dev/null; then
    tier1_heal "Interface ${TUN_IF} missing"
fi

if ! ip -o link show "${TUN_IF}" 2>/dev/null | grep -qE "<([^>]*,)?UP([,>])"; then
    tier1_heal "Interface ${TUN_IF} is DOWN"
fi

if ! ip -4 addr show dev "${TUN_IF}" 2>/dev/null | grep -q "inet "; then
    tier1_heal "Interface ${TUN_IF} has no IPv4 address"
fi

if [ "${FOU_ENABLE}" = "yes" ] && [ -n "${FOU_PORT}" ]; then
    if ! ip fou show 2>/dev/null | awk -v p="${FOU_PORT}" '$2 == p && $3 == "ipproto" && $4 == "47" {ok=1} END{exit !ok}'; then
        tier1_heal "FOU listener on UDP port ${FOU_PORT} (ipproto 47) missing"
    fi
fi

if ! nft list table ip "${NFT_TABLE}" &>/dev/null; then
    tier1_heal "nftables table ${NFT_TABLE} missing (possible ruleset flush)"
fi

# Tier 2: Remote endpoint connectivity check with exponential backoff cooldown
if [ -n "${REMOTE_TUN}" ]; then
    if ping -c 3 -W 2 -i 0.5 -I "${TUN_IF}" "${REMOTE_TUN}" &>/dev/null; then
        echo 0 > "${FAIL_FILE}" 2>/dev/null || true
        echo 0 > "${RESTART_COUNT_FILE}" 2>/dev/null || true
        echo 0 > "${TIER1_COUNT_FILE}" 2>/dev/null || true
        rm -f "${LAST_RESTART_FILE}" "${TIER1_LAST_FILE}" 2>/dev/null || true
        exit 0
    fi
else
    exit 0
fi

FAILS=$(cat "${FAIL_FILE}" 2>/dev/null | tr -d '[:space:]')
[[ ! "${FAILS}" =~ ^[0-9]+$ ]] && FAILS=0
FAILS=$((FAILS + 1))
echo "${FAILS}" > "${FAIL_FILE}" 2>/dev/null || true

if [ "${FAILS}" -ge "${MAX_FAIL}" ]; then
    RESTARTS=$(cat "${RESTART_COUNT_FILE}" 2>/dev/null | tr -d '[:space:]')
    [[ ! "${RESTARTS}" =~ ^[0-9]+$ ]] && RESTARTS=0
    LAST_TS=$(cat "${LAST_RESTART_FILE}" 2>/dev/null | tr -d '[:space:]')
    [[ ! "${LAST_TS}" =~ ^[0-9]+$ ]] && LAST_TS=0

    COOLDOWN=0
    if [ "${RESTARTS}" -eq 1 ]; then
        COOLDOWN=60
    elif [ "${RESTARTS}" -eq 2 ]; then
        COOLDOWN=120
    elif [ "${RESTARTS}" -ge 3 ]; then
        COOLDOWN=300
    fi

    NOW=$(date +%s)
    ELAPSED=$((NOW - LAST_TS))

    if [ "${ELAPSED}" -ge "${COOLDOWN}" ]; then
        restart_stack "Tunnel ${TUN_IF} unreachable after ${FAILS} checks (backoff level ${RESTARTS})"
        echo "${NOW}" > "${LAST_RESTART_FILE}" 2>/dev/null || true
        echo $((RESTARTS + 1)) > "${RESTART_COUNT_FILE}" 2>/dev/null || true
        echo 0 > "${FAIL_FILE}" 2>/dev/null || true
    else
        REM=$((COOLDOWN - ELAPSED))
        logger -t "${LOG_TAG}" "Tunnel ${TUN_IF} unreachable (${FAILS}/${MAX_FAIL}); restart in cooldown (${REM}s remaining)" 2>/dev/null || true
    fi
else
    logger -t "${LOG_TAG}" "Tunnel ${TUN_IF} ping failed (${FAILS}/${MAX_FAIL})" 2>/dev/null || true
fi
WDBODY
    chmod 750 "${script_path}"
}

# ─── Create Systemd Units ─────────────────────────────────────────
create_watchdog_timer() {
    local tunnel_id="$1" wd_script="$2" auto_start="${3:-yes}"
    local svc="gre-watchdog-${tunnel_id}"

    cat > "${SYSTEMD_DIR}/${svc}.service" << EOF
[Unit]
Description=GRE Tunnel ${tunnel_id} Watchdog Check
After=network.target gre-tunnel-${tunnel_id}.service

[Service]
Type=oneshot
ExecStart=${wd_script}
StandardOutput=journal
StandardError=journal
EOF

    cat > "${SYSTEMD_DIR}/${svc}.timer" << EOF
[Unit]
Description=GRE Tunnel ${tunnel_id} Watchdog Timer

[Timer]
OnBootSec=30
OnUnitInactiveSec=10
AccuracySec=1

[Install]
WantedBy=timers.target
EOF

    chmod 644 "${SYSTEMD_DIR}/${svc}.service" "${SYSTEMD_DIR}/${svc}.timer"
    if [ "$auto_start" = "yes" ]; then
        systemctl daemon-reload
        systemctl enable "${svc}.timer" &>/dev/null || true
        systemctl restart "${svc}.timer" &>/dev/null || true
    fi
}

create_gre_service() {
    local tunnel_id="$1" service_name="$2" up_script="$3" down_script="$4" description="$5" auto_start="${6:-yes}"
    local service_path="${SYSTEMD_DIR}/${service_name}.service"

    cat > "${service_path}" << EOF
[Unit]
Description=${description}
After=network-online.target nftables.service
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
    if [ "$auto_start" = "yes" ]; then
        systemctl daemon-reload
        systemctl enable "${service_name}" &>/dev/null || true
        if ! systemctl restart "${service_name}" 2>/dev/null || ! systemctl is-active --quiet "${service_name}"; then
            msg_err "Failed to start service '${service_name}'!"
            journalctl -u "${service_name}" -n 10 --no-pager 2>/dev/null || true
            return 1
        fi
    fi
    return 0
}

create_keepalive_service() {
    local tunnel_id="$1" remote_tun_ip="$2" auto_start="${3:-yes}"
    local service_name="gre-keepalive-${tunnel_id}"
    local service_path="${SYSTEMD_DIR}/${service_name}.service"
    local sleep_offset=$(( tunnel_id % 5 ))

    cat > "${service_path}" << EOF
[Unit]
Description=GRE Tunnel ${tunnel_id} Keep-Alive
After=gre-tunnel-${tunnel_id}.service
Requires=gre-tunnel-${tunnel_id}.service
PartOf=gre-tunnel-${tunnel_id}.service

[Service]
Type=simple
ExecStart=/bin/bash -c 'sleep ${sleep_offset}; while true; do ping -c 12 -i 5 -W 2 -I gre${tunnel_id} ${remote_tun_ip} >/dev/null 2>&1 || sleep 5; done'
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${service_path}"
    if [ "$auto_start" = "yes" ]; then
        systemctl daemon-reload
        systemctl enable "${service_name}" &>/dev/null || true
        systemctl restart "${service_name}" &>/dev/null || true
    fi
}

# ─── Review Box ───────────────────────────────────────────────────
show_gre_review() {
    local role="$1"
    local show_mtu="${TUN_MTU:-1392}"
    local show_mss=$(( show_mtu - 40 ))
    local if_note="(auto-detected)"
    [ "${IF_WAN_MANUAL:-0}" -eq 1 ] && if_note="(manual)"

    local spoof_status="${YELLOW}Disabled${NC} ${DIM}(Real IPs + output/prerouting notrack)${NC}"
    if [ "${LOCAL_SPOOF}" != "${LOCAL_REAL}" ] || [ "${REMOTE_SPOOF}" != "${REMOTE_REAL}" ]; then
        spoof_status="${GREEN}Enabled${NC} ${DIM}(Stateless Spoofing + notrack)${NC}"
    fi

    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  REVIEW YOUR GRE OVER FOU SETTINGS${NC}"
    print_double_line
    echo ""
    echo -e "  ${MAGENTA}Tunnel ID:${NC}       ${WHITE}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "  ${MAGENTA}Role:${NC}            ${WHITE}${BOLD}${role}${NC}"
    echo -e "  ${MAGENTA}Interface:${NC}       ${WHITE}${BOLD}${IF_WAN}${NC}  ${DIM}${if_note}${NC}"
    echo -e "  ${MAGENTA}Tunnel Dev:${NC}      ${WHITE}${BOLD}${TUN_IF}${NC}"
    echo -e "  ${MAGENTA}GRE Key:${NC}         ${WHITE}${BOLD}${GRE_KEY}${NC}  ${DIM}(must match both sides)${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Real IPs (FOU Endpoints):${NC}"
    echo -e "    Local:   ${GREEN}${BOLD}${LOCAL_REAL}${NC}"
    echo -e "    Remote:  ${BLUE}${BOLD}${REMOTE_REAL}${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Spoof IPs (nftables):${NC} ${spoof_status}"
    echo -e "    Local Spoof:   ${MAGENTA}${BOLD}${LOCAL_SPOOF}${NC}"
    echo -e "    Remote Spoof:  ${MAGENTA}${BOLD}${REMOTE_SPOOF}${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Tunnel Network:${NC}"
    echo -e "    Local TUN:  ${GREEN}${BOLD}${LOCAL_TUN}${NC}  ${DIM}(MTU: ${show_mtu}, MSS: ${show_mss})${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}Optimizations & Hardening (v${VERSION}):${NC}"
    echo -e "    ${GREEN}✓${NC} FOU Encapsulation (UDP Port ${FOU_PORT}, encap-csum Enabled)"
    echo -e "    ${GREEN}✓${NC} Atomic nftables (prerouting -300 & output -300 notrack)"
    echo -e "    ${GREEN}✓${NC} Bidirectional SYN/SYN-ACK MSS Clamping (max ${show_mss})"
    echo -e "    ${GREEN}✓${NC} BBR Congestion Control + FQ Qdisc (flow_limit 1000)"
    echo -e "    ${GREEN}✓${NC} Non-disruptive NIC Ring Buffer & TSO/GSO/GRO/UDP-TNL Protection"
    echo -e "    ${GREEN}✓${NC} RAM-Scaled Persistent Sysctl + Boot Modules (/etc/modules-load.d)"
    echo -e "    ${GREEN}✓${NC} Two-Tier Self-Healing Watchdog (with Backoff Cooldown)"
    echo ""
    echo -e "  ${CYAN}nftables Table:${NC} ${WHITE}fw_gre_${TUNNEL_ID}${NC}"
    echo ""
    print_double_line
    echo ""
}

# ─── Unified Tunnel Setup (DRY implementation) ────────────────────
setup_fou_server() {
    local role="$1" # "Iran" or "Kharej"
    print_header
    echo -e " ${GREEN}${BOLD}>>> Setup ${role} Server (GRE over FOU)${NC}"
    echo ""
    print_line

    check_prereqs_ready || return 1

    local AUTO_IF
    AUTO_IF=$(detect_interface)
    IF_WAN="${AUTO_IF}"
    IF_WAN_MANUAL=0

    echo -e "\n ${MAGENTA}${BOLD}[1/4] Tunnel Identity${NC}"
    read_tunnel_id TUNNEL_ID
    TUN_IF="gre${TUNNEL_ID}"

    local existing_up="${SCRIPTS_DIR}/${TUN_IF}-up.sh"
    local existing_down="${SCRIPTS_DIR}/${TUN_IF}-down.sh"
    local service_name="gre-tunnel-${TUNNEL_ID}"
    local is_overwrite=0
    if [ -f "$existing_up" ] || [ -f "$existing_down" ] || [ -f "${SYSTEMD_DIR}/${service_name}.service" ] || ip link show "$TUN_IF" &>/dev/null; then
        is_overwrite=1
    fi

    echo -e "\n ${MAGENTA}${BOLD}[2/4] Network Interfaces & Endpoints${NC}"
    msg_info "Interface auto-detected: ${BOLD}${IF_WAN}${NC}"
    read_interface "Change interface? (Enter to keep)" "${IF_WAN}" IF_WAN
    [ "$IF_WAN" != "$AUTO_IF" ] && IF_WAN_MANUAL=1

    local AUTO_IP
    AUTO_IP=$(detect_public_ip "${IF_WAN}")
    [ -n "$AUTO_IP" ] && msg_info "Public IP auto-detected: ${BOLD}${AUTO_IP}${NC}"

    read_ip "This server's REAL IP" "${AUTO_IP}" LOCAL_REAL
    if ! ip -4 addr show dev "${IF_WAN}" 2>/dev/null | grep -Fq "inet ${LOCAL_REAL}/"; then
        msg_warn "IP ${LOCAL_REAL} is not directly configured on ${IF_WAN} (behind NAT?)."
        msg_warn "Ensure UDP FOU port is forwarded cleanly to this host's local IP."
    fi

    local remote_label="Remote server's REAL IP (Kharej)"
    [ "$role" = "Kharej" ] && remote_label="Remote server's REAL IP (Iran)"
    read_ip "$remote_label" "" REMOTE_REAL

    while [ "$LOCAL_REAL" = "$REMOTE_REAL" ]; do
        msg_err "Remote IP cannot be identical to Local IP (${LOCAL_REAL})! Please enter the remote server IP."
        read_ip "$remote_label" "" REMOTE_REAL
    done

    echo -e "\n ${MAGENTA}${BOLD}[3/4] Tunnel Subnet & Spoof IPs${NC}"
    local existing_sub=""
    if [ -f "$existing_up" ]; then
        local lt pref
        lt=$(extract_up_var "LOCAL_TUN" "$existing_up")
        pref=$(echo "$lt" | sed -E 's/\.[0-9]+\/[0-9]+$//')
        if validate_subnet_prefix "$pref"; then
            existing_sub="$pref"
        fi
    fi
    local def_subnet="${existing_sub}"
    [ -z "$def_subnet" ] && def_subnet=$(find_free_tunnel_subnet "10.80" "${TUNNEL_ID}")

    local val_sub=""
    while true; do
        read_input "Tunnel Subnet (/30 base)" "${def_subnet}" val_sub
        val_sub=$(echo "$val_sub" | tr -d '\r\n[:space:]')
        [ -z "$val_sub" ] && val_sub="${def_subnet}"
        if validate_subnet_prefix "$val_sub"; then
            if is_tunnel_subnet_in_use "$val_sub" "${TUN_IF}"; then
                msg_warn "Subnet ${val_sub}.0/30 appears to be in use by another interface or tunnel!"
                read -p "  Use subnet ${val_sub}.0/30 anyway? (y/N): " sub_ow
                [[ ! "$sub_ow" =~ ^[Yy]$ ]] && continue
            fi
            TUN_SUBNET="$val_sub"
            break
        else
            msg_err "Invalid subnet format '${val_sub}'. Expected format: X.X.X (e.g. 10.80.1)"
        fi
    done

    if [ "$role" = "Iran" ]; then
        LOCAL_TUN="${TUN_SUBNET}.1/30"
        REMOTE_TUN="${TUN_SUBNET}.2"
    else
        LOCAL_TUN="${TUN_SUBNET}.2/30"
        REMOTE_TUN="${TUN_SUBNET}.1"
    fi

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

    echo -e "\n ${MAGENTA}${BOLD}[4/4] GRE Key, MTU & FOU UDP Port${NC}"
    msg_info "GRE Key and MTU should match on both sides."
    local def_key="${TUNNEL_ID}"
    local def_mtu="1392"
    if [ -f "$existing_up" ]; then
        local pk pm
        pk=$(extract_up_var "GRE_KEY" "$existing_up")
        pm=$(extract_up_var "TUN_MTU" "$existing_up")
        [[ "$pk" =~ ^[0-9]+$ ]] && def_key="$pk"
        [[ "$pm" =~ ^[0-9]+$ ]] && [ "$pm" -ge 1280 ] && [ "$pm" -le 1464 ] && def_mtu="$pm"
    fi
    read_gre_key "GRE Key" "${def_key}" GRE_KEY
    read_mtu "Tunnel MTU (1280-1464)" "${def_mtu}" TUN_MTU

    local def_fou_port
    def_fou_port=$(get_default_fou_port "${TUNNEL_ID}" "47")
    read_fou_port "FOU UDP Port" "${def_fou_port}" "47" FOU_PORT
    FOU_ENABLE="yes"

    show_gre_review "${role}"

    read -p "  Proceed with installation? (Y/n): " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { msg_warn "Cancelled."; return 0; }

    echo ""
    local up_script="${SCRIPTS_DIR}/${TUN_IF}-up.sh"
    local down_script="${SCRIPTS_DIR}/${TUN_IF}-down.sh"

    # Tear down existing tunnel completely before overwriting so old FOU port and nft table are released cleanly
    if [ "$is_overwrite" -eq 1 ]; then
        msg_info "Stopping existing Tunnel ${TUNNEL_ID} before reconfiguring..."
        stop_tunnel_services "${TUNNEL_ID}"
        if [ -f "$down_script" ]; then
            bash "$down_script" 2>/dev/null || true
        fi
    fi

    persist_sysctl_tuning
    msg_ok "Persistent network tuning applied: /etc/sysctl.d/99-xmanager-tunnel.conf"

    generate_gre_up "${up_script}"
    msg_ok "Up script created: ${up_script}"

    generate_gre_down "${down_script}"
    msg_ok "Down script created: ${down_script}"

    if ! create_gre_service "${TUNNEL_ID}" "${service_name}" "${up_script}" "${down_script}" "GRE Tunnel ${TUNNEL_ID} - ${role}" "yes"; then
        msg_err "Tunnel ${TUNNEL_ID} setup aborted because systemd service failed to start."
        return 1
    fi
    msg_ok "Tunnel service started: ${service_name}"

    create_keepalive_service "${TUNNEL_ID}" "${REMOTE_TUN}" "yes"
    msg_ok "Keep-alive service started: gre-keepalive-${TUNNEL_ID}"

    local wd_script="${SCRIPTS_DIR}/${TUN_IF}-watchdog.sh"
    generate_watchdog "${wd_script}"
    create_watchdog_timer "${TUNNEL_ID}" "${wd_script}" "yes"
    msg_ok "Watchdog timer started (every 10s)"

    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  ${role} GRE-FOU Tunnel ${TUNNEL_ID} Setup Complete!${NC}"
    print_double_line
    echo ""

    if [ "$role" = "Iran" ]; then
        echo -e "  ${YELLOW}${BOLD}Settings to use for the Kharej side:${NC}"
        echo -e "    Tunnel ID:     ${CYAN}${BOLD}${TUNNEL_ID}${NC}"
        echo -e "    Tunnel Subnet: ${CYAN}${BOLD}${TUN_SUBNET}${NC}  (must match!)"
        echo -e "    GRE Key:       ${CYAN}${BOLD}${GRE_KEY}${NC}  (must match!)"
        echo -e "    Tunnel MTU:    ${CYAN}${BOLD}${TUN_MTU}${NC}  (must match!)"
        echo -e "    Remote IP:     ${CYAN}${BOLD}${LOCAL_REAL}${NC}"
        echo -e "    FOU UDP Port:  ${CYAN}${BOLD}${FOU_PORT}${NC}"
        echo -e "    Spoof Local:   ${CYAN}${BOLD}${REMOTE_SPOOF}${NC}  (swap!)"
        echo -e "    Spoof Remote:  ${CYAN}${BOLD}${LOCAL_SPOOF}${NC}  (swap!)"
    else
        echo -e " ${CYAN}Test connectivity:${NC}"
        echo -e "    ping -c 3 -I ${TUN_IF} ${REMOTE_TUN}"
    fi
    echo ""
    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

setup_iran()   { setup_fou_server "Iran"; }
setup_kharej() { setup_fou_server "Kharej"; }

# ─── Tunnel Discovery Helper ──────────────────────────────────────
get_all_tunnel_ids() {
    local ids=()
    # 1. From systemd unit files on disk
    for f in "${SYSTEMD_DIR}"/gre-tunnel-*.service; do
        [ -f "$f" ] || continue
        local b id
        b=$(basename "$f")
        id="${b#gre-tunnel-}"
        id="${id%.service}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    # 2. From systemctl unit files & active units
    for u in $(systemctl list-unit-files "gre-tunnel-*.service" --no-legend 2>/dev/null | awk '{print $1}'); do
        local id="${u#gre-tunnel-}"
        id="${id%.service}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done
    for u in $(systemctl list-units --type=service --all "gre-tunnel-*" --no-legend 2>/dev/null | awk '{print $1}'); do
        local id="${u#gre-tunnel-}"
        id="${id%.service}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    # 3. From scripts in SCRIPTS_DIR
    for f in "${SCRIPTS_DIR}"/gre*-up.sh; do
        [ -f "$f" ] || continue
        local b id
        b=$(basename "$f")
        id="${b#gre}"
        id="${id%-up.sh}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    # 4. From active kernel interfaces (gre1, gre10, etc., excluding gre0)
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep '^gre[1-9]' | sed 's/@.*//'); do
        local id="${iface#gre}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    # 5. From GRE-scoped nftables tables (fw_gre_10, etc.)
    for tbl in $(nft list tables 2>/dev/null | awk '$2 == "ip" && $3 ~ /^fw_gre_[0-9]+$/ {print $3}'); do
        local id="${tbl#fw_gre_}"
        [[ "$id" =~ ^[0-9]+$ ]] && ids+=("$id")
    done

    if [ ${#ids[@]} -gt 0 ]; then
        printf '%s\n' "${ids[@]}" | sort -n -u
    fi
}

# ─── Unified Service Control Helpers ──────────────────────────────
start_tunnel_services() {
    local tid="$1"
    local name="gre-tunnel-${tid}"
    local tun_if="gre${tid}"

    mkdir -p -m 700 "${STATE_DIR}"
    rm -f "${STATE_DIR}/${tun_if}.stopped"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "${name}" 2>/dev/null || true
    if ! systemctl start "${name}" 2>/dev/null || ! systemctl is-active --quiet "${name}"; then
        msg_err "Failed to start ${name}!"
        journalctl -u "${name}" -n 8 --no-pager 2>/dev/null || true
        return 1
    fi
    if [ -f "${SYSTEMD_DIR}/gre-keepalive-${tid}.service" ]; then
        systemctl enable "gre-keepalive-${tid}" 2>/dev/null || true
        systemctl start "gre-keepalive-${tid}" 2>/dev/null || true
    fi
    if [ -f "${SYSTEMD_DIR}/gre-watchdog-${tid}.timer" ]; then
        systemctl enable "gre-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl start "gre-watchdog-${tid}.timer" 2>/dev/null || true
    fi
    return 0
}

stop_tunnel_services() {
    local tid="$1"
    local name="gre-tunnel-${tid}"
    local tun_if="gre${tid}"

    mkdir -p -m 700 "${STATE_DIR}"
    touch "${STATE_DIR}/${tun_if}.stopped"
    systemctl stop "gre-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl stop "gre-watchdog-${tid}.service" 2>/dev/null || true
    systemctl stop "gre-keepalive-${tid}" 2>/dev/null || true
    systemctl stop "${name}" 2>/dev/null || true
}

restart_tunnel_services() {
    local tid="$1"
    local name="gre-tunnel-${tid}"
    local tun_if="gre${tid}"

    mkdir -p -m 700 "${STATE_DIR}"
    rm -f "${STATE_DIR}/${tun_if}.stopped"
    echo 0 > "${STATE_DIR}/${tun_if}.fails" 2>/dev/null || true
    echo 0 > "${STATE_DIR}/${tun_if}.restarts" 2>/dev/null || true
    echo 0 > "${STATE_DIR}/${tun_if}.t1_restarts" 2>/dev/null || true
    rm -f "${STATE_DIR}/${tun_if}.last_restart" "${STATE_DIR}/${tun_if}.t1_last" 2>/dev/null || true

    if ! systemctl restart "${name}" 2>/dev/null || ! systemctl is-active --quiet "${name}"; then
        msg_err "Failed to restart ${name}!"
        journalctl -u "${name}" -n 8 --no-pager 2>/dev/null || true
        return 1
    fi
    if [ -f "${SYSTEMD_DIR}/gre-keepalive-${tid}.service" ]; then
        systemctl restart "gre-keepalive-${tid}" 2>/dev/null || true
    fi
    if [ -f "${SYSTEMD_DIR}/gre-watchdog-${tid}.timer" ]; then
        systemctl restart "gre-watchdog-${tid}.timer" 2>/dev/null || true
    fi
    return 0
}

# ─── Watchdog Helpers & Management ────────────────────────────────
ensure_watchdog_exists() {
    local tid="$1"
    local up_script="${SCRIPTS_DIR}/gre${tid}-up.sh"
    local wd_script="${SCRIPTS_DIR}/gre${tid}-watchdog.sh"

    local remote_tun="" fou_en="yes" fou_pt=""
    if [ -f "$up_script" ]; then
        local lt
        lt=$(extract_up_var "LOCAL_TUN" "$up_script")
        remote_tun=$(derive_remote_tun_from_local "$lt")
        fou_en=$(extract_up_var "FOU_ENABLE" "$up_script")
        fou_pt=$(extract_up_var "FOU_PORT" "$up_script")
        [ -z "$fou_en" ] && fou_en="yes"
    fi
    [ -z "$remote_tun" ] && remote_tun="10.80.${tid}.2"

    # Save and restore globals so this function has no side-effects on caller context
    local _saved_tid="${TUNNEL_ID:-}" _saved_tif="${TUN_IF:-}" _saved_rt="${REMOTE_TUN:-}"
    local _saved_fe="${FOU_ENABLE:-}" _saved_fp="${FOU_PORT:-}"
    TUNNEL_ID="${tid}"
    TUN_IF="gre${tid}"
    REMOTE_TUN="${remote_tun}"
    FOU_ENABLE="${fou_en}"
    FOU_PORT="${fou_pt}"

    generate_watchdog "${wd_script}"
    create_watchdog_timer "${tid}" "${wd_script}" "yes"

    TUNNEL_ID="${_saved_tid}"
    TUN_IF="${_saved_tif}"
    REMOTE_TUN="${_saved_rt}"
    FOU_ENABLE="${_saved_fe}"
    FOU_PORT="${_saved_fp}"
}

do_watchdog_status() {
    echo ""
    echo -e " ${CYAN}${BOLD}Watchdog Timers & Status:${NC}"
    print_line

    local found=0
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        found=1
        local tname="gre-watchdog-${tid}"
        local tun_if="gre${tid}"
        local svc="gre-tunnel-${tid}"

        local timer_file="${SYSTEMD_DIR}/${tname}.timer"
        local script_file="${SCRIPTS_DIR}/gre${tid}-watchdog.sh"

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

        local fails restarts
        fails=$(cat "${STATE_DIR}/${tun_if}.fails" 2>/dev/null || cat "/tmp/.wd_${tun_if}" 2>/dev/null || echo 0)
        restarts=$(cat "${STATE_DIR}/${tun_if}.restarts" 2>/dev/null || echo 0)
        [[ ! "$fails" =~ ^[0-9]+$ ]] && fails=0
        [[ ! "$restarts" =~ ^[0-9]+$ ]] && restarts=0

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

        local backoff_info=""
        [[ "$restarts" =~ ^[0-9]+$ ]] && [ "$restarts" -gt 0 ] && backoff_info="  Backoff: lvl ${restarts}"

        echo -e "  ${timer_col}●${NC} ${BOLD}gre${tid}${NC}  Timer: ${timer_col}[${timer_status}]${NC}  Tunnel: ${tun_col}[${tun_st}]${NC}  Fails: ${fails}/3${backoff_info}  ${DIM}${next_info}${NC}${script_warn}"
    done

    [ $found -eq 0 ] && msg_warn "No GRE/FOU tunnels found."
    echo ""
    echo -e " ${DIM}Watchdog checks local integrity immediately and uses exponential backoff (60s/120s/300s) for remote outages.${NC}"
    echo ""
}

do_watchdog_start() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    ensure_watchdog_exists "${tid}"
    systemctl daemon-reload
    systemctl enable "gre-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl start "gre-watchdog-${tid}.timer" 2>/dev/null || true
    msg_ok "Watchdog timer for gre${tid} started and enabled (every 10s)."
}

do_watchdog_stop() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    systemctl stop "gre-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl disable "gre-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl stop "gre-watchdog-${tid}.service" 2>/dev/null || true
    msg_ok "Watchdog timer for gre${tid} stopped and disabled."
}

do_watchdog_restart() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    ensure_watchdog_exists "${tid}"
    systemctl daemon-reload
    systemctl restart "gre-watchdog-${tid}.timer" 2>/dev/null || true
    msg_ok "Watchdog timer for gre${tid} restarted."
}

do_watchdog_start_all() {
    echo ""
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    [ ${#all_ids[@]} -eq 0 ] && { msg_warn "No tunnels found."; return; }
    for tid in "${all_ids[@]}"; do
        ensure_watchdog_exists "${tid}"
        systemctl enable "gre-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl start "gre-watchdog-${tid}.timer" 2>/dev/null || true
        msg_ok "Watchdog gre${tid} started."
    done
    systemctl daemon-reload
    msg_ok "All watchdog timers started."
}

do_watchdog_stop_all() {
    echo ""
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    [ ${#all_ids[@]} -eq 0 ] && { msg_warn "No tunnels found."; return; }
    for tid in "${all_ids[@]}"; do
        systemctl stop "gre-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl disable "gre-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl stop "gre-watchdog-${tid}.service" 2>/dev/null || true
        msg_ok "Watchdog gre${tid} stopped."
    done
    msg_ok "All watchdog timers stopped."
}

do_watchdog_test() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local tun_if="gre${tid}"
    local svc="gre-tunnel-${tid}"
    local up_script="${SCRIPTS_DIR}/${tun_if}-up.sh"

    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  WATCHDOG DIAGNOSTIC TEST - Tunnel ${tid} (${tun_if})${NC}"
    print_double_line
    echo ""

    # 1. Check service
    echo -n "  1. Tunnel service (${svc}): "
    if systemctl is-active "${svc}" &>/dev/null; then
        echo -e "${GREEN}active${NC}"
    elif systemctl is-failed "${svc}" &>/dev/null; then
        echo -e "${RED}failed${NC}"
    else
        echo -e "${YELLOW}inactive${NC}"
    fi

    # 2. Check interface
    echo -n "  2. Network interface (${tun_if}): "
    if ip link show "${tun_if}" &>/dev/null; then
        if ip -o link show "${tun_if}" 2>/dev/null | grep -qE "<([^>]*,)?UP([,>])"; then
            echo -e "${GREEN}EXISTS (UP)${NC}"
        else
            echo -e "${YELLOW}EXISTS (DOWN)${NC}"
        fi
    else
        echo -e "${RED}MISSING${NC}"
    fi

    # 3. Check FOU & nftables
    local fou_port="" fou_en="yes"
    if [ -f "$up_script" ]; then
        fou_port=$(extract_up_var "FOU_PORT" "$up_script")
        fou_en=$(extract_up_var "FOU_ENABLE" "$up_script")
        [ -z "$fou_en" ] && fou_en="yes"
    fi
    if [ "$fou_en" = "yes" ] && [ -n "$fou_port" ]; then
        echo -n "  3. FOU UDP listener (port ${fou_port}): "
        if ip fou show 2>/dev/null | awk -v p="${fou_port}" '$2 == p && $3 == "ipproto" && $4 == "47" {ok=1} END{exit !ok}'; then
            echo -e "${GREEN}ACTIVE (ipproto 47)${NC}"
        else
            echo -e "${RED}MISSING${NC}"
        fi
    fi

    echo -n "  4. nftables table (fw_gre_${tid}): "
    if nft list table ip "fw_gre_${tid}" &>/dev/null; then
        echo -e "${GREEN}LOADED${NC}"
    elif nft list table ip "fw_${tid}" &>/dev/null; then
        echo -e "${YELLOW}LEGACY (fw_${tid}) - consider Option 19 upgrade${NC}"
    else
        echo -e "${RED}MISSING${NC}"
    fi

    # 5. Remote IP
    local remote_tun=""
    if [ -f "$up_script" ]; then
        local lt
        lt=$(extract_up_var "LOCAL_TUN" "$up_script")
        remote_tun=$(derive_remote_tun_from_local "$lt")
    fi
    echo -e "  5. Remote Tunnel IP: ${CYAN}${remote_tun:-unknown}${NC}"

    # 6. Ping test
    if [ -n "$remote_tun" ] && ip link show "${tun_if}" &>/dev/null; then
        echo -e "  6. Executing ping: ping -c 3 -W 2 -I ${tun_if} ${remote_tun}"
        if ping -c 3 -W 2 -I "${tun_if}" "${remote_tun}"; then
            echo -e "     ${GREEN}✓ Ping SUCCESSFUL! Tunnel connection is healthy.${NC}"
        else
            echo -e "     ${RED}✗ Ping FAILED! Watchdog would increment failure counter.${NC}"
        fi
    else
        echo -e "     ${YELLOW}Cannot ping (interface missing or IP unknown).${NC}"
    fi

    local fails restarts
    fails=$(cat "${STATE_DIR}/${tun_if}.fails" 2>/dev/null || cat "/tmp/.wd_${tun_if}" 2>/dev/null || echo 0)
    restarts=$(cat "${STATE_DIR}/${tun_if}.restarts" 2>/dev/null || echo 0)
    [[ ! "$fails" =~ ^[0-9]+$ ]] && fails=0
    [[ ! "$restarts" =~ ^[0-9]+$ ]] && restarts=0
    echo ""
    echo -e "  Current failure counter: ${BOLD}${fails} / 3${NC}  (backoff restarts: ${restarts})"

    local timer_st
    timer_st=$(systemctl is-active "gre-watchdog-${tid}.timer" 2>/dev/null || echo "inactive")
    echo -e "  Timer status: ${BOLD}${timer_st}${NC}"
    echo ""
    print_double_line
}

do_watchdog_logs() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local tun_if="gre${tid}"

    echo ""
    echo -e " ${CYAN}${BOLD}Watchdog Service Logs (gre-watchdog-${tid}):${NC}"
    print_line
    journalctl -u "gre-watchdog-${tid}.service" -n 25 --no-pager 2>/dev/null || echo "No service logs found."
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
        systemctl enable "gre-watchdog-${tid}.timer" 2>/dev/null || true
        systemctl restart "gre-watchdog-${tid}.timer" 2>/dev/null || true
        msg_ok "Watchdog gre${tid} re-configured and restarted."
    done
    systemctl daemon-reload
    msg_ok "All watchdog scripts and timers updated and active!"
}

# ─── Watchdog Submenu ─────────────────────────────────────────────
watchdog_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}${BOLD}"
        echo " ╔════════════════════════════════════════════════╗"
        echo " ║             WATCHDOG MANAGEMENT                ║"
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
    echo -e " ${WHITE}${BOLD}  SYSTEM DASHBOARD (GRE-FOU v${VERSION})${NC}"
    print_double_line

    # Instantaneous CPU computation (100ms sample)
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
    local mem load up
    mem=$(free -m 2>/dev/null | awk '/Mem:/ {printf "%dMB / %dMB (%.0f%%)", $3, $2, $3/$2*100}')
    load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    up=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*//')

    echo ""
    echo -e "  ${MAGENTA}CPU:${NC}     ${BOLD}${cpu:-N/A}${NC}"
    echo -e "  ${MAGENTA}Memory:${NC}  ${BOLD}${mem:-N/A}${NC}"
    echo -e "  ${MAGENTA}Load:${NC}    ${BOLD}${load:-N/A}${NC}"
    echo -e "  ${MAGENTA}Uptime:${NC}  ${BOLD}${up:-N/A}${NC}"
    echo ""
    print_line

    # Tunnel summary
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    local total=0 active=0 down=0
    for tid in "${all_ids[@]}"; do
        local name="gre-tunnel-${tid}"
        ((total++))
        [ "$(systemctl is-active "${name}" 2>/dev/null)" = "active" ] && ((active++)) || ((down++))
    done

    echo -e "  ${CYAN}Tunnels:${NC}  Total: ${BOLD}${total}${NC}  ${GREEN}Active: ${active}${NC}  ${RED}Down: ${down}${NC}"
    echo ""

    if [ $total -gt 0 ]; then
        printf "  ${DIM}%-4s %-7s %-8s %-16s %-16s %-6s %-10s %-11s %-10s${NC}\n" "ID" "Role" "Status" "Remote Real" "Tunnel IP" "Port" "Traffic" "Watchdog" "Keepalive"
        print_line
        for tid in "${all_ids[@]}"; do
            local name="gre-tunnel-${tid}"
            local st
            st=$(systemctl is-active "${name}" 2>/dev/null || echo "inactive")
            local tun_if="gre${tid}"

            local remote="" tun_ip="" fou_pt="" role="?"
            local script="${SCRIPTS_DIR}/${tun_if}-up.sh"
            if [ -f "$script" ]; then
                remote=$(extract_up_var "REMOTE_REAL" "$script")
                tun_ip=$(extract_up_var "LOCAL_TUN" "$script")
                fou_pt=$(extract_up_var "FOU_PORT" "$script")
                [[ "$tun_ip" == *".1/"* ]] && role="Iran" || role="Kharej"
            fi

            local rx tx traffic
            rx=$(cat "/sys/class/net/${tun_if}/statistics/rx_bytes" 2>/dev/null || echo 0)
            tx=$(cat "/sys/class/net/${tun_if}/statistics/tx_bytes" 2>/dev/null || echo 0)
            traffic=$(format_bytes $(( rx + tx )))

            local wd_st fails wd_info
            wd_st=$(systemctl is-active "gre-watchdog-${tid}.timer" 2>/dev/null || echo "inactive")
            fails=$(cat "${STATE_DIR}/${tun_if}.fails" 2>/dev/null || cat "/tmp/.wd_${tun_if}" 2>/dev/null || echo 0)
            [[ ! "$fails" =~ ^[0-9]+$ ]] && fails=0
            wd_info="${wd_st}"
            [ "$fails" -gt 0 ] && wd_info="${wd_info}(${fails})"

            local ka_st
            ka_st=$(systemctl is-active "gre-keepalive-${tid}.service" 2>/dev/null || echo "inactive")

            local st_col="${RED}" wd_col="${DIM}" ka_col="${DIM}"
            [ "$st" = "active" ] && st_col="${GREEN}"
            [ "$wd_st" = "active" ] && wd_col="${GREEN}"
            [ "$ka_st" = "active" ] && ka_col="${GREEN}"

            printf "  %-4s %-7s ${st_col}%-8s${NC} %-16s %-16s %-6s %-10s ${wd_col}%-11s${NC} ${ka_col}%-10s${NC}\n" \
                "$tid" "$role" "$st" "${remote:-?}" "${tun_ip:-?}" "${fou_pt:-?}" "$traffic" "$wd_info" "$ka_st"
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
    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        local tun_if="gre${tid}"
        local script="${SCRIPTS_DIR}/${tun_if}-up.sh"

        local tun_ip=""
        if [ -f "$script" ]; then
            local local_tun
            local_tun=$(extract_up_var "LOCAL_TUN" "$script")
            tun_ip=$(derive_remote_tun_from_local "$local_tun")
        fi

        if [ -z "$tun_ip" ]; then
            echo -e "  ${YELLOW}●${NC} ${tun_if}  ${YELLOW}[skip - invalid or missing config]${NC}"
            continue
        fi

        if ! ip link show "${tun_if}" &>/dev/null; then
            echo -e "  ${RED}●${NC} ${tun_if}  ${RED}[interface missing]${NC}"
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
            echo -e "  ${GREEN}●${NC} ${tun_if} → ${tun_ip}  ${GREEN}[OK]${NC}  ${DIM}${rtt}${NC}"
        else
            echo -e "  ${RED}●${NC} ${tun_if} → ${tun_ip}  ${RED}[FAIL]${NC}"
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
        if restart_tunnel_services "${tid}"; then
            msg_ok "Tunnel ${tid}, keep-alive, and watchdog restarted."
        fi
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
        if start_tunnel_services "${tid}"; then
            msg_ok "Tunnel ${tid}, keep-alive, and watchdog started."
        fi
    done
}

# ─── Management ───────────────────────────────────────────────────
list_tunnels() {
    echo ""
    echo -e " ${CYAN}${BOLD}Detected GRE-FOU Tunnels:${NC}"
    print_line

    local found=0 i=1
    TUNNEL_LIST=()
    TUNNEL_ID_LIST=()

    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    for tid in "${all_ids[@]}"; do
        found=1
        local name="gre-tunnel-${tid}"
        local tun_if="gre${tid}"
        local status
        status=$(systemctl is-active "${name}" 2>/dev/null || echo "inactive")
        TUNNEL_LIST+=("${name}")
        TUNNEL_ID_LIST+=("${tid}")

        local remote="" role="?"
        local script="${SCRIPTS_DIR}/${tun_if}-up.sh"
        if [ -f "$script" ]; then
            remote=$(extract_up_var "REMOTE_REAL" "$script")
            local lt
            lt=$(extract_up_var "LOCAL_TUN" "$script")
            [[ "$lt" == *".1/"* ]] && role="IR" || role="KH"
        fi

        local if_info="dev missing"
        if ip link show "${tun_if}" &>/dev/null; then
            if ip -o link show "${tun_if}" 2>/dev/null | grep -qE "<([^>]*,)?UP([,>])"; then
                if_info="dev ${tun_if} UP"
            else
                if_info="dev ${tun_if} DOWN"
            fi
        fi

        if [ "$status" = "active" ]; then
            echo -e "  ${GREEN}●${NC} ${BOLD}${i})${NC} ${name}  ${GREEN}[active]${NC}  ${DIM}(${if_info}, ${role} → ${remote:-?})${NC}"
        else
            echo -e "  ${RED}●${NC} ${BOLD}${i})${NC} ${name}  ${RED}[${status}]${NC}  ${DIM}(${if_info}, ${role} → ${remote:-?})${NC}"
        fi
        ((i++))
    done

    [ $found -eq 0 ] && { msg_warn "No GRE/FOU tunnels found."; return 1; }
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
    elif [[ "$pick" =~ ^gre([0-9]+)$ ]] && printf '%s\n' "${TUNNEL_ID_LIST[@]}" | grep -qx "${BASH_REMATCH[1]}"; then
        SELECTED_TID="${BASH_REMATCH[1]}"
    elif [[ "$pick" =~ ^gre-tunnel-([0-9]+)(\.service)?$ ]] && printf '%s\n' "${TUNNEL_ID_LIST[@]}" | grep -qx "${BASH_REMATCH[1]}"; then
        SELECTED_TID="${BASH_REMATCH[1]}"
    fi

    if [ -z "$SELECTED_TID" ]; then
        msg_err "Tunnel '${pick}' not found in detected tunnels."
        return 1
    fi

    SELECTED_TUNNEL="gre-tunnel-${SELECTED_TID}"
    return 0
}

do_restart() {
    pick_tunnel || return
    if restart_tunnel_services "${SELECTED_TID}"; then
        msg_ok "${SELECTED_TUNNEL}, keep-alive, and watchdog restarted."
    fi
}

do_stop() {
    pick_tunnel || return
    stop_tunnel_services "${SELECTED_TID}"
    msg_ok "${SELECTED_TUNNEL} stopped."
}

do_start() {
    pick_tunnel || return
    if start_tunnel_services "${SELECTED_TID}"; then
        msg_ok "${SELECTED_TUNNEL} started."
    fi
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
    local tun_if="gre${tid}"
    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  TUNNEL ${tid} DETAILS${NC}"
    print_double_line

    local script="${SCRIPTS_DIR}/${tun_if}-up.sh"
    local fp=""
    if [ -f "$script" ]; then
        echo ""
        local lr rr ls rs lt gk mtu_val mss_val
        lr=$(extract_up_var "LOCAL_REAL" "$script")
        rr=$(extract_up_var "REMOTE_REAL" "$script")
        ls=$(extract_up_var "LOCAL_SPOOF" "$script")
        rs=$(extract_up_var "REMOTE_SPOOF" "$script")
        lt=$(extract_up_var "LOCAL_TUN" "$script")
        gk=$(extract_up_var "GRE_KEY" "$script")
        fp=$(extract_up_var "FOU_PORT" "$script")
        mtu_val=$(extract_up_var "TUN_MTU" "$script")
        [ -z "$mtu_val" ] && mtu_val=$(grep -E '^[[:space:]]*MTU=' "$script" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d "\"'\r")
        local role="Kharej"; [[ "$lt" == *".1/"* ]] && role="Iran"

        local csum_mode="${YELLOW}noencap-csum (WARN: 0-checksum)${NC}"
        if grep -q 'encap-csum' "$script" 2>/dev/null; then
            csum_mode="${GREEN}encap-csum (OK)${NC}"
        fi

        local mss_disp=""
        if [[ "$mtu_val" =~ ^[0-9]+$ ]]; then
            mss_val=$(( mtu_val - 40 ))
            mss_disp=" (MSS: ${mss_val})"
        fi

        echo -e "  ${MAGENTA}Role:${NC}          ${BOLD}${role}${NC}"
        echo -e "  ${MAGENTA}GRE Key:${NC}       ${BOLD}${gk}${NC}"
        echo -e "  ${MAGENTA}FOU Port:${NC}      ${BOLD}${fp:-N/A}${NC}"
        echo -e "  ${MAGENTA}FOU Checksum:${NC}  ${csum_mode}"
        echo -e "  ${MAGENTA}MTU / MSS:${NC}     ${BOLD}${mtu_val:-1392}${NC}${mss_disp}"
        echo -e "  ${MAGENTA}Local Real:${NC}    ${GREEN}${lr}${NC}"
        echo -e "  ${MAGENTA}Remote Real:${NC}   ${BLUE}${rr}${NC}"
        echo -e "  ${MAGENTA}Local Spoof:${NC}   ${DIM}${ls}${NC}"
        echo -e "  ${MAGENTA}Remote Spoof:${NC}  ${DIM}${rs}${NC}"
        echo -e "  ${MAGENTA}Tunnel IP:${NC}     ${GREEN}${lt}${NC}"
    fi

    echo ""
    print_line
    local tun_st ka_st tun_col="${RED}" ka_col="${RED}"
    tun_st=$(systemctl is-active "${SELECTED_TUNNEL}" 2>/dev/null || true)
    [ -z "$tun_st" ] && tun_st="inactive"
    [ "$tun_st" = "active" ] && tun_col="${GREEN}"
    [ "$tun_st" = "activating" ] && tun_col="${YELLOW}"

    ka_st=$(systemctl is-active "gre-keepalive-${tid}.service" 2>/dev/null || true)
    [ -z "$ka_st" ] && ka_st="inactive"
    [ "$ka_st" = "active" ] && ka_col="${GREEN}"

    echo -e "  ${CYAN}Service:${NC}           ${tun_col}${tun_st}${NC}"
    echo -e "  ${CYAN}Keepalive Service:${NC} ${ka_col}${ka_st}${NC}"

    if ip link show "${tun_if}" &>/dev/null; then
        local rx tx rxd txd
        rx=$(cat "/sys/class/net/${tun_if}/statistics/rx_bytes" 2>/dev/null || echo 0)
        tx=$(cat "/sys/class/net/${tun_if}/statistics/tx_bytes" 2>/dev/null || echo 0)
        rxd=$(cat "/sys/class/net/${tun_if}/statistics/rx_dropped" 2>/dev/null || echo 0)
        txd=$(cat "/sys/class/net/${tun_if}/statistics/tx_dropped" 2>/dev/null || echo 0)
        echo ""
        print_line
        echo -e "  ${CYAN}Traffic & Drops:${NC}"
        echo -e "    RX: ${GREEN}$(format_bytes "$rx")${NC} (dropped: ${rxd})  |  TX: ${BLUE}$(format_bytes "$tx")${NC} (dropped: ${txd})"
        echo -e "  ${CYAN}Link Info:${NC}"
        ip -d link show "${tun_if}" 2>/dev/null | head -4 | sed 's/^/    /'
    fi

    if [ -n "$fp" ]; then
        echo ""
        print_line
        echo -e "  ${CYAN}Kernel FOU Listener (port ${fp}):${NC}"
        local fou_line
        fou_line=$(ip fou show 2>/dev/null | awk -v p="$fp" '$2 == p {print}')
        [ -n "$fou_line" ] && echo -e "    ${GREEN}${fou_line}${NC}" || msg_warn "  FOU port ${fp} is not registered in kernel."
    fi

    echo ""
    print_line
    local wd_st fails restarts
    wd_st=$(systemctl is-active "gre-watchdog-${tid}.timer" 2>/dev/null || echo "inactive")
    fails=$(cat "${STATE_DIR}/${tun_if}.fails" 2>/dev/null || cat "/tmp/.wd_${tun_if}" 2>/dev/null || echo 0)
    restarts=$(cat "${STATE_DIR}/${tun_if}.restarts" 2>/dev/null || echo 0)
    [[ ! "$fails" =~ ^[0-9]+$ ]] && fails=0
    [[ ! "$restarts" =~ ^[0-9]+$ ]] && restarts=0
    echo -e "  ${CYAN}Watchdog:${NC}  ${wd_st}  fails: ${fails}/3  backoff restarts: ${restarts}"

    echo ""
    print_line
    if nft list table ip "fw_gre_${tid}" &>/dev/null; then
        echo -e "  ${CYAN}nftables (fw_gre_${tid}):${NC}"
        nft list table ip "fw_gre_${tid}" 2>/dev/null | head -35
    elif nft list table ip "fw_${tid}" &>/dev/null; then
        echo -e "  ${YELLOW}nftables (legacy fw_${tid}):${NC}"
        nft list table ip "fw_${tid}" 2>/dev/null | head -35
    else
        echo -e "  ${CYAN}nftables (fw_gre_${tid}):${NC}"
        msg_warn "  Table not found."
    fi
    echo ""
}

do_delete() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local tun_if="gre${tid}"
    local svc_name="gre-tunnel-${tid}"
    local up_script="${SCRIPTS_DIR}/${tun_if}-up.sh"
    local down_script="${SCRIPTS_DIR}/${tun_if}-down.sh"
    local wd_script="${SCRIPTS_DIR}/${tun_if}-watchdog.sh"

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
        fou_port=$(extract_up_var "FOU_PORT" "$up_script")
    fi
    if [ -z "$fou_port" ] && [ -f "$down_script" ]; then
        fou_port=$(extract_up_var "FOU_PORT" "$down_script")
    fi

    # 2. Stop and disable watchdog FIRST so it cannot resurrect the tunnel
    systemctl stop "gre-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl disable "gre-watchdog-${tid}.timer" 2>/dev/null || true
    systemctl stop "gre-watchdog-${tid}.service" 2>/dev/null || true
    systemctl disable "gre-watchdog-${tid}.service" 2>/dev/null || true
    pkill -9 -f "${tun_if}-watchdog\.sh([[:space:]]|$)" 2>/dev/null || true

    # 3. Stop and disable keepalive service & kill only this tunnel's orphaned ping processes
    systemctl stop "gre-keepalive-${tid}.service" 2>/dev/null || true
    systemctl disable "gre-keepalive-${tid}.service" 2>/dev/null || true
    pkill -9 -f "ping.*-I ${tun_if}([[:space:]]|$)" 2>/dev/null || true

    # 4. Stop and disable main tunnel service
    systemctl stop "${svc_name}.service" 2>/dev/null || true
    systemctl disable "${svc_name}.service" 2>/dev/null || true

    # 5. Execute down script directly
    if [ -f "$down_script" ]; then
        bash "$down_script" 2>/dev/null || true
    fi

    # 6. Direct kernel & interface cleanup (failsafe)
    ip link set dev "${tun_if}" down 2>/dev/null || true
    ip tunnel del "${tun_if}" 2>/dev/null || true
    ip link del "${tun_if}" 2>/dev/null || true

    # 7. nftables cleanup (new table and surgical legacy cleanup)
    nft delete table ip "fw_gre_${tid}" 2>/dev/null || true
    if nft list table ip "fw_${tid}" 2>/dev/null | grep -qE "\"?${tun_if}\"?|fwd_mss"; then
        nft delete table ip "fw_${tid}" 2>/dev/null || true
    fi

    # 8. Clean up FOU UDP port if no other tunnel is using it
    if [ -n "$fou_port" ]; then
        local other_using=0 s
        for s in "${SCRIPTS_DIR}"/*-up.sh; do
            [ -f "$s" ] || continue
            [ "$s" = "$up_script" ] && continue
            if grep -Eq "^FOU_PORT=[\"']?${fou_port}[\"']?$" "$s" 2>/dev/null; then
                other_using=1
                break
            fi
        done
        if [ $other_using -eq 0 ]; then
            ip fou del port "${fou_port}" 2>/dev/null || true
        fi
    fi

    # 9. Remove all systemd unit files and symlinks
    rm -f "${SYSTEMD_DIR}/${svc_name}.service"
    rm -f "${SYSTEMD_DIR}/gre-keepalive-${tid}.service"
    rm -f "${SYSTEMD_DIR}/gre-watchdog-${tid}.service"
    rm -f "${SYSTEMD_DIR}/gre-watchdog-${tid}.timer"
    rm -f "${SYSTEMD_DIR}/multi-user.target.wants/${svc_name}.service"
    rm -f "${SYSTEMD_DIR}/multi-user.target.wants/gre-keepalive-${tid}.service"
    rm -f "${SYSTEMD_DIR}/timers.target.wants/gre-watchdog-${tid}.timer"

    # 10. Remove scripts and tracking/state files
    rm -f "$up_script"
    rm -f "$down_script"
    rm -f "$wd_script"
    rm -f "${STATE_DIR}/${tun_if}.fails" "${STATE_DIR}/${tun_if}.restarts" "${STATE_DIR}/${tun_if}.last_restart" "${STATE_DIR}/${tun_if}.t1_restarts" "${STATE_DIR}/${tun_if}.t1_last" "${STATE_DIR}/${tun_if}.stopped" "${STATE_DIR}/${tun_if}.lock"
    rm -f "/tmp/.wd_${tun_if}"

    # 11. Reload systemd daemon and reset failed units
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    msg_ok "Tunnel ${tid} (${tun_if}) and ALL its components were completely removed!"
}

do_view_scripts() {
    pick_tunnel || return
    local tid="${SELECTED_TID}"
    local up="${SCRIPTS_DIR}/gre${tid}-up.sh"
    local down="${SCRIPTS_DIR}/gre${tid}-down.sh"
    local wd="${SCRIPTS_DIR}/gre${tid}-watchdog.sh"
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

apply_live_gre_nftables() {
    local tid="$1" tun_if="$2" if_wan="$3" lr="$4" rr="$5" ls="$6" rs="$7" fe="$8" fp="$9" mss="${10}"
    local nft_table="fw_gre_${tid}"
    local legacy_table="fw_${tid}"
    local do_spoof=0
    if [ -n "$ls" ] && [ -n "$rs" ] && { [ "$ls" != "$lr" ] || [ "$rs" != "$rr" ]; }; then
        do_spoof=1
    fi

    if nft list table ip "${legacy_table}" 2>/dev/null | grep -qE "\"?${tun_if}\"?|fwd_mss"; then
        nft delete table ip "${legacy_table}" 2>/dev/null || true
    fi

    {
        echo "table ip ${nft_table}"
        echo "delete table ip ${nft_table}"
        echo "table ip ${nft_table} {"
        echo "    chain prerouting {"
        echo "        type filter hook prerouting priority -300; policy accept;"
        if [ "$fe" = "yes" ]; then
            if [ "$do_spoof" -eq 1 ]; then
                echo "        iifname \"${if_wan}\" ip saddr ${rs} ip daddr ${lr} udp dport ${fp} ip saddr set ${rr} notrack"
            else
                echo "        iifname \"${if_wan}\" ip saddr ${rr} ip daddr ${lr} udp dport ${fp} notrack"
            fi
        else
            if [ "$do_spoof" -eq 1 ]; then
                echo "        iifname \"${if_wan}\" ip protocol gre ip saddr ${rs} ip daddr ${lr} ip saddr set ${rr} notrack"
            else
                echo "        iifname \"${if_wan}\" ip protocol gre ip saddr ${rr} ip daddr ${lr} notrack"
            fi
        fi
        echo "    }"
        echo "    chain output {"
        echo "        type filter hook output priority -300; policy accept;"
        if [ "$fe" = "yes" ]; then
            echo "        oifname \"${if_wan}\" ip saddr ${lr} ip daddr ${rr} udp dport ${fp} notrack"
            echo "        oifname \"${if_wan}\" ip saddr ${lr} ip daddr ${rr} udp sport ${fp} notrack"
        else
            echo "        oifname \"${if_wan}\" ip protocol gre ip saddr ${lr} ip daddr ${rr} notrack"
        fi
        echo "    }"
        if [ "$do_spoof" -eq 1 ]; then
            echo "    chain postrouting {"
            echo "        type filter hook postrouting priority 300; policy accept;"
            if [ "$fe" = "yes" ]; then
                echo "        oifname \"${if_wan}\" ip saddr ${lr} ip daddr ${rr} udp dport ${fp} ip saddr set ${ls}"
            else
                echo "        oifname \"${if_wan}\" ip protocol gre ip saddr ${lr} ip daddr ${rr} ip saddr set ${ls}"
            fi
            echo "    }"
        fi
        echo "    chain fwd_mss {"
        echo "        type filter hook forward priority -150; policy accept;"
        echo "        oifname \"${tun_if}\" tcp flags & (syn | rst) == syn tcp option maxseg size > ${mss} tcp option maxseg size set ${mss}"
        echo "        iifname \"${tun_if}\" tcp flags & (syn | rst) == syn tcp option maxseg size > ${mss} tcp option maxseg size set ${mss}"
        echo "    }"
        echo "    chain out_mss {"
        echo "        type filter hook output priority -150; policy accept;"
        echo "        oifname \"${tun_if}\" tcp flags & (syn | rst) == syn tcp option maxseg size > ${mss} tcp option maxseg size set ${mss}"
        echo "    }"
        echo "}"
    } | nft -f -
}

_sync_existing_tunnels() {
    local mode="${1:-upgrade}" # upgrade | optimize
    echo ""
    if [ "$mode" = "optimize" ]; then
        echo -e " ${CYAN}${BOLD}Optimize Existing GRE-FOU Tunnels & Kernel Stack (Live + Persistent):${NC}"
        echo -e " ${DIM}(Restores prerouting/output notrack, flushes stale FOU conntrack, enables WAN GRO/GSO/TSO, fq flow_limit 1000, netdev_budget 1200 / dev_weight 128)${NC}"
    else
        echo -e " ${CYAN}${BOLD}Upgrade Existing GRE-FOU Tunnels to v${VERSION}:${NC}"
        echo -e " ${DIM}(encap-csum, atomic nftables + output/prerouting notrack, SYN/SYN-ACK MSS, fq flow_limit 1000, backoff watchdog)${NC}"
    fi
    print_line

    local all_ids; mapfile -t all_ids < <(get_all_tunnel_ids)
    [ ${#all_ids[@]} -eq 0 ] && { msg_warn "No GRE/FOU tunnels found."; return; }

    local backup_dir="${SCRIPTS_DIR}/.gre-backup-$(date +%Y%m%d-%H%M%S)"
    local backup_created=0
    local processed_ids=()
    local restart_needed_ids=()
    local throttled_port_tunnels=()

    # Save caller globals cleanly
    local _s_tid="${TUNNEL_ID:-}" _s_tif="${TUN_IF:-}" _s_ifw="${IF_WAN:-}"
    local _s_lr="${LOCAL_REAL:-}" _s_rr="${REMOTE_REAL:-}"
    local _s_ls="${LOCAL_SPOOF:-}" _s_rs="${REMOTE_SPOOF:-}"
    local _s_lt="${LOCAL_TUN:-}" _s_rt="${REMOTE_TUN:-}"
    local _s_gk="${GRE_KEY:-}" _s_fe="${FOU_ENABLE:-}" _s_fp="${FOU_PORT:-}"
    local _s_mtu="${TUN_MTU:-}"

    local tid
    for tid in "${all_ids[@]}"; do
        local tun_if="gre${tid}"
        local up_script="${SCRIPTS_DIR}/${tun_if}-up.sh"
        local down_script="${SCRIPTS_DIR}/${tun_if}-down.sh"
        local wd_script="${SCRIPTS_DIR}/${tun_if}-watchdog.sh"

        if [ ! -f "$up_script" ]; then
            msg_warn "Skipping Tunnel ${tid}: ${up_script} not found."
            continue
        fi

        local u_ifw u_lr u_rr u_ls u_rs u_lt u_gk u_fe u_fp u_mtu u_rt u_role had_csum=1
        u_ifw=$(extract_up_var "IF_WAN" "$up_script")
        u_lr=$(extract_up_var "LOCAL_REAL" "$up_script")
        u_rr=$(extract_up_var "REMOTE_REAL" "$up_script")
        u_ls=$(extract_up_var "LOCAL_SPOOF" "$up_script")
        u_rs=$(extract_up_var "REMOTE_SPOOF" "$up_script")
        u_lt=$(extract_up_var "LOCAL_TUN" "$up_script")
        u_gk=$(extract_up_var "GRE_KEY" "$up_script")
        u_fe=$(extract_up_var "FOU_ENABLE" "$up_script")
        u_fp=$(extract_up_var "FOU_PORT" "$up_script")
        u_mtu=$(extract_up_var "TUN_MTU" "$up_script")
        [ -z "$u_mtu" ] && u_mtu=$(grep -E '^[[:space:]]*MTU=' "$up_script" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d "\"'\r")

        [ -z "$u_fe" ] && u_fe="yes"
        [ -z "$u_ls" ] && u_ls="$u_lr"
        [ -z "$u_rs" ] && u_rs="$u_rr"
        [ -z "$u_gk" ] && u_gk="$tid"
        if [ -z "$u_mtu" ] || ! [[ "$u_mtu" =~ ^[0-9]+$ ]]; then
            [ "$u_fe" = "yes" ] && u_mtu="1392" || u_mtu="1400"
        fi
        if [ "$u_fe" = "yes" ] && ! grep -q 'encap-csum' "$up_script" 2>/dev/null; then
            had_csum=0
        fi

        u_rt=$(derive_remote_tun_from_local "$u_lt")

        if [[ ! "$u_ifw" =~ ^[a-zA-Z0-9_.:-]+$ ]] || [ "${#u_ifw}" -gt 20 ] || ! validate_ipv4 "$u_lr" || ! validate_ipv4 "$u_rr" || ! validate_ipv4 "$u_ls" || ! validate_ipv4 "$u_rs" || [ -z "$u_rt" ] || ! [[ "$u_gk" =~ ^[0-9]+$ ]]; then
            msg_warn "Skipping Tunnel ${tid}: invalid or incomplete parameters in ${up_script}."
            continue
        fi
        if [ "$u_fe" = "yes" ] && { ! [[ "$u_fp" =~ ^[0-9]+$ ]] || [ "$u_fp" -lt 1 ] || [ "$u_fp" -gt 65535 ]; }; then
            msg_warn "Skipping Tunnel ${tid}: invalid or missing FOU_PORT in ${up_script}."
            continue
        fi
        if [ "$u_mtu" -lt 1280 ] || [ "$u_mtu" -gt 1464 ]; then
            [ "$u_fe" = "yes" ] && u_mtu="1392" || u_mtu="1400"
        fi

        if [ "$backup_created" -eq 0 ]; then
            mkdir -p "$backup_dir"
            backup_created=1
        fi
        cp -p "$up_script" "$backup_dir/" 2>/dev/null || true
        [ -f "$down_script" ] && cp -p "$down_script" "$backup_dir/" 2>/dev/null || true
        [ -f "$wd_script" ] && cp -p "$wd_script" "$backup_dir/" 2>/dev/null || true

        [[ "$u_lt" == *".1/"* ]] && u_role="Iran" || u_role="Kharej"

        TUNNEL_ID="$tid"
        TUN_IF="$tun_if"
        IF_WAN="$u_ifw"
        LOCAL_REAL="$u_lr"
        REMOTE_REAL="$u_rr"
        LOCAL_SPOOF="$u_ls"
        REMOTE_SPOOF="$u_rs"
        LOCAL_TUN="$u_lt"
        REMOTE_TUN="$u_rt"
        GRE_KEY="$u_gk"
        FOU_ENABLE="$u_fe"
        FOU_PORT="$u_fp"
        TUN_MTU="$u_mtu"

        generate_gre_up "$up_script"
        generate_gre_down "$down_script"
        generate_watchdog "$wd_script"

        create_gre_service "$tid" "gre-tunnel-${tid}" "$up_script" "$down_script" "GRE Tunnel ${tid} - ${u_role}" "no"
        create_keepalive_service "$tid" "$u_rt" "no"
        create_watchdog_timer "$tid" "$wd_script" "no"

        if [ "$mode" = "optimize" ]; then
            # Apply live zero-downtime optimizations on active interfaces and firewall
            ethtool -K "${u_ifw}" tso on gso on gro on 2>/dev/null || true
            ethtool -K "${u_ifw}" tx-udp_tnl-segmentation off tx-udp_tnl-csum-segmentation off 2>/dev/null || true
            tc qdisc replace dev "${u_ifw}" root fq flow_limit 1000 2>/dev/null || true
            if ip link show "${tun_if}" &>/dev/null; then
                tc qdisc replace dev "${tun_if}" root fq flow_limit 1000 2>/dev/null || true
            fi
            if apply_live_gre_nftables "$tid" "$tun_if" "$u_ifw" "$u_lr" "$u_rr" "$u_ls" "$u_rs" "$u_fe" "$u_fp" "$(( u_mtu - 40 ))"; then
                if [ "$u_fe" = "yes" ] && command -v conntrack &>/dev/null; then
                    conntrack -D -p udp --dport "${u_fp}" >/dev/null 2>&1 || true
                fi
                msg_ok "Optimized Tunnel ${tid} (${tun_if}, ${u_role}, FOU ${u_fp:-none}, live notrack + offloads + qdisc applied)."
            else
                msg_warn "Updated scripts for Tunnel ${tid}, but live nftables reload failed."
            fi
            [ "$had_csum" -eq 0 ] && restart_needed_ids+=("$tid")
        else
            msg_ok "Upgraded Tunnel ${tid} (${tun_if}, ${u_role}, FOU port ${u_fp:-none}, MTU ${u_mtu})."
            restart_needed_ids+=("$tid")
        fi

        processed_ids+=("$tid")

        if [ "$u_fe" = "yes" ] && [[ "$u_fp" =~ ^[0-9]+$ ]] && [ "$u_fp" -ge 51820 ] && [ "$u_fp" -le 51850 ]; then
            throttled_port_tunnels+=("gre${tid}:port=${u_fp}")
        fi
    done

    # Restore caller globals
    TUNNEL_ID="${_s_tid}"; TUN_IF="${_s_tif}"; IF_WAN="${_s_ifw}"
    LOCAL_REAL="${_s_lr}"; REMOTE_REAL="${_s_rr}"
    LOCAL_SPOOF="${_s_ls}"; REMOTE_SPOOF="${_s_rs}"
    LOCAL_TUN="${_s_lt}"; REMOTE_TUN="${_s_rt}"
    GRE_KEY="${_s_gk}"; FOU_ENABLE="${_s_fe}"; FOU_PORT="${_s_fp}"
    TUN_MTU="${_s_mtu}"

    persist_sysctl_tuning
    systemctl daemon-reload
    msg_ok "Updated /etc/sysctl.d/99-xmanager-tunnel.conf & /etc/modules-load.d/99-xmanager-gre.conf"
    [ "$backup_created" -eq 1 ] && msg_info "Backups saved in: ${backup_dir}"

    if [ ${#throttled_port_tunnels[@]} -gt 0 ]; then
        echo ""
        msg_warn "The following tunnels still use WireGuard-range UDP ports (51820-51850), which some ISPs throttle:"
        msg_warn "  ${throttled_port_tunnels[*]}"
        msg_warn "Ports were preserved automatically; consider reconfiguring both sides to 4500/8443/1194 if you experience loss."
    fi

    if [ ${#restart_needed_ids[@]} -gt 0 ]; then
        echo ""
        if [ "$mode" = "optimize" ]; then
            msg_info "Live sysctl/qdisc/offload/notrack optimizations are active immediately."
            read -p "  Restart tunnels missing encap-csum (${restart_needed_ids[*]}) now? (y/N): " rst_choice
        else
            read -p "  Restart upgraded tunnels now to apply changes? (y/N): " rst_choice
        fi
        if [[ "$rst_choice" =~ ^[Yy]$ ]]; then
            for tid in "${restart_needed_ids[@]}"; do
                if restart_tunnel_services "$tid"; then
                    msg_ok "Tunnel ${tid} restarted cleanly."
                fi
            done
        else
            msg_warn "Remember to restart tunnels missing encap-csum on BOTH Iran and Kharej servers for encap-csum to take effect."
        fi
    elif [ "$mode" = "optimize" ] && [ ${#processed_ids[@]} -gt 0 ]; then
        msg_ok "All live optimizations applied with ZERO tunnel downtime!"
    fi
    echo ""
}

do_upgrade_tunnels() {
    _sync_existing_tunnels "upgrade"
}

do_optimize_tunnels() {
    _sync_existing_tunnels "optimize"
}

# ─── Main Menu ────────────────────────────────────────────────────
main_menu() {
    while true; do
        print_header
        echo -e " ${BOLD}${WHITE}Overview${NC}"
        echo -e "  ${CYAN}1)${NC}  Dashboard"
        echo -e "  ${GREEN}2)${NC}  Health Check (ping all)"
        echo ""
        echo -e " ${BOLD}${WHITE}Setup FOU${NC}"
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
        echo -e " ${BOLD}${WHITE}Install & Maintenance${NC}"
        echo -e "  ${MAGENTA}18)${NC} Install Prerequisites"
        echo -e "  ${GREEN}19)${NC} Upgrade Existing Tunnels (v${VERSION}: encap-csum, notrack, MSS, Watchdog)"
        echo -e "  ${CYAN}20)${NC} Optimize Existing Tunnels & Kernel (Low CPU, GRO/GSO/TSO, Notrack, Conntrack)"
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
            19) do_upgrade_tunnels ;;
            20) do_optimize_tunnels ;;
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
