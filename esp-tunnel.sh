#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  ESP (IPSEC XFRM) TUNNEL & DIRECT-RETURN MANAGER v1.0.0        ║
# ║  Route-Based XFRM (espN) + IKEv2/strongSwan + Raw ESP (Proto50)║
# ║  Supports XForwarder DSR (SYN-ACK/Direct) & Standalone Relay   ║
# ╚════════════════════════════════════════════════════════════════╝

VERSION="1.0.0"

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SWANCTL_DIR="/etc/swanctl/conf.d"
STRONGSWAN_DIR="/etc/strongswan.d"
ESP_CFG_DIR="/etc/xmanager-esp"
STATE_DIR="/run/xmanager-esp"

# ─── UI Helpers ───────────────────────────────────────────────────
print_line() { echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }
print_double_line() { echo -e "${CYAN}════════════════════════════════════════════════════${NC}"; }

print_header() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════════╗"
    echo " ║     ESP / XFRM TUNNEL MANAGER v${VERSION}           ║"
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

# ─── Validation Helpers ───────────────────────────────────────────
validate_ipv4() {
    local ip="$1"
    local rx='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    [[ ! "$ip" =~ $rx ]] && return 1
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
    [[ ! "$sub" =~ $rx ]] && return 1
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
    local proto_base="$1"
    local tid="$2"
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

read_mtu() {
    local prompt="$1" default="$2" var_name="$3"
    local val=""
    while true; do
        read_input "$prompt" "$default" val
        val=$(echo "$val" | tr -d '\r\n[:space:]')
        if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1280 ] && [ "$val" -le 1460 ]; then
            printf -v "$var_name" "%s" "$val"
            return 0
        else
            msg_err "Invalid MTU '${val}'. Recommended range for XFRM/ESP is 1280-1460 (default 1400)."
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

        local tun_dev="esp${tid}"
        local svc_file="${SYSTEMD_DIR}/esp-tunnel-${tid}.service"
        local up_file="${SCRIPTS_DIR}/esp${tid}-up.sh"
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
        if [[ ! "$iface" =~ ^[a-zA-Z0-9_.:-]+$ ]] || [ "${#iface}" -gt 15 ]; then
            msg_err "Invalid interface name '${iface}'. Allowed: alphanumeric, '.', '_', ':', '-' (max 15 chars)."
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
        fi
    done
}

# ─── System Detection & Prerequisites ─────────────────────────────
detect_default_iface() {
    ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

detect_iface_ip() {
    local iface="$1"
    ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'
}

check_strongswan_installed() {
    command -v swanctl &>/dev/null && command -v nft &>/dev/null && command -v ip &>/dev/null
}

install_prereqs() {
    echo ""
    msg_info "Installing prerequisites for ESP / XFRM tunnel (strongSwan swanctl, nftables, iproute2)..."
    if ! command -v apt-get &>/dev/null; then
        msg_err "apt-get not found. Please install strongswan-swanctl, charon-systemd, nftables, iproute2, openssl, tcpdump manually."
        return 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || { msg_err "apt-get update failed."; return 1; }
    apt-get install -y -qq --no-install-recommends \
        charon-systemd strongswan-swanctl libstrongswan-standard-plugins \
        python3 iproute2 nftables tcpdump curl openssl ca-certificates || {
        msg_err "Package installation failed."
        return 1
    }
    systemctl enable strongswan &>/dev/null || true
    systemctl start strongswan &>/dev/null || true
    msg_ok "Prerequisites installed and strongswan.service is running."
    swanctl --stats 2>/dev/null | head -n 6 || true
}

ensure_prereqs() {
    if ! check_strongswan_installed; then
        msg_warn "Required tools (swanctl / nft / ip) are missing."
        read -p "  Install prerequisites now? (Y/n): " ans
        if [[ "$ans" =~ ^[Nn]$ ]]; then
            msg_err "Cannot proceed without strongswan-swanctl and nftables."
            return 1
        fi
        install_prereqs || return 1
    fi
    if ! systemctl is-active --quiet strongswan; then
        systemctl start strongswan &>/dev/null || true
    fi
    return 0
}

# ─── Kernel & NIC Tuning ──────────────────────────────────────────
persist_sysctl_tuning() {
    cat > /etc/sysctl.d/99-xmanager-tunnel.conf <<'SYSCTL'
# Managed by XManager ESP Tunnel Manager
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 100000
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
SYSCTL
    sysctl -p /etc/sysctl.d/99-xmanager-tunnel.conf &>/dev/null || true
}

apply_live_nic_tuning() {
    local if_wan="$1"
    modprobe tcp_bbr 2>/dev/null || true
    modprobe xfrm_interface 2>/dev/null || true
    modprobe esp4 2>/dev/null || true
    sysctl -w net.ipv4.ip_forward=1 &>/dev/null || true
    sysctl -w net.ipv4.conf.all.rp_filter=0 &>/dev/null || true
    sysctl -w net.ipv4.conf.default.rp_filter=0 &>/dev/null || true
    local sys_wan="${if_wan//./\/}"
    sysctl -w "net.ipv4.conf.${sys_wan}.rp_filter=0" &>/dev/null || true
    sysctl -w net.core.default_qdisc=fq &>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr &>/dev/null || true
    if command -v tc &>/dev/null && ip link show "${if_wan}" &>/dev/null; then
        tc qdisc replace dev "${if_wan}" root fq flow_limit 1000 2>/dev/null || tc qdisc replace dev "${if_wan}" root fq 2>/dev/null || true
    fi
}

do_optimize_kernel() {
    echo ""
    msg_info "Applying BBR, fq qdisc, rp_filter=0, and XFRM socket tuning..."
    local def_wan
    def_wan=$(detect_default_iface)
    [ -z "$def_wan" ] && def_wan="eth0"
    persist_sysctl_tuning
    apply_live_nic_tuning "$def_wan"
    msg_ok "Kernel tuning applied and persisted to /etc/sysctl.d/99-xmanager-tunnel.conf"
}

# ─── PSK Management ───────────────────────────────────────────────
read_or_generate_psk() {
    local role="$1"
    local psk_file="$2"
    local var_name="$3"

    mkdir -p -m 700 "${ESP_CFG_DIR}"

    if [ "$role" = "iran" ]; then
        echo ""
        msg_info "Pre-Shared Key (PSK) options for IKEv2 authentication:"
        echo -e "   ${GREEN}1)${NC} Generate a new 64-hex random PSK automatically (Recommended)"
        echo -e "   ${CYAN}2)${NC} Paste an existing 64-hex PSK from the peer server"
        local pchoice=""
        read -p "  Select [1]: " pchoice
        pchoice="${pchoice:-1}"
        if [ "$pchoice" = "1" ]; then
            local new_psk
            new_psk=$(openssl rand -hex 32)
            umask 077
            printf '%s\n' "$new_psk" > "$psk_file"
            chmod 600 "$psk_file"
            printf -v "$var_name" "%s" "$new_psk"
            return 0
        fi
    fi

    local pasted=""
    while true; do
        read -s -p "  Paste 64-hex PSK from peer server (input hidden): " pasted
        echo ""
        pasted=$(echo "$pasted" | tr -d '\r\n[:space:]')
        if [[ "$pasted" =~ ^[0-9a-fA-F]{64}$ ]]; then
            umask 077
            printf '%s\n' "$pasted" > "$psk_file"
            chmod 600 "$psk_file"
            printf -v "$var_name" "%s" "$pasted"
            return 0
        else
            msg_err "Invalid PSK format. Expected exactly 64 hexadecimal characters."
        fi
    done
}

# ─── Script & Config Generators ───────────────────────────────────
ensure_charon_no_routes() {
    # Only set global install_routes=no when no unrelated strongSwan configs exist
    local foreign=0 f
    for f in "${SWANCTL_DIR}"/*.conf; do
        [ -e "$f" ] || continue
        case "$(basename "$f")" in
            esp-tun-*.conf) ;;
            *) foreign=1; break ;;
        esac
    done
    if [ "$foreign" -eq 0 ]; then
        mkdir -p "${STRONGSWAN_DIR}"
        cat > "${STRONGSWAN_DIR}/xmanager-esp.conf" <<'CHARON'
# Managed by XManager ESP Tunnel Manager (dedicated XFRM route-based mode)
charon {
    install_routes = no
    plugins {
        kernel-netlink {
            install_routes_xfrmi = no
        }
    }
}
CHARON
        chmod 644 "${STRONGSWAN_DIR}/xmanager-esp.conf"
    else
        msg_warn "Foreign strongSwan configs detected in ${SWANCTL_DIR}; skipping global charon.install_routes override."
    fi
}

generate_swanctl_conf() {
    local tid="$1" role="$2" local_real="$3" remote_real="$4" outside_tun_ip="$5"
    local if_id="$6" reqid="$7" psk="$8"
    local conn_name="esp-tun-${tid}"
    local child_name="esp-tun-${tid}-child"
    local conf_file="${SWANCTL_DIR}/${conn_name}.conf"
    local local_ts="0.0.0.0/0" remote_ts="${outside_tun_ip}/32" start_act="start"

    if [ "$role" = "kharej" ]; then
        local_ts="${outside_tun_ip}/32"
        remote_ts="0.0.0.0/0"
        start_act="none"
    fi

    mkdir -p "${SWANCTL_DIR}"
    umask 077
    cat > "${conf_file}" <<SWAN
# Managed by XManager ESP Tunnel Manager (ID ${tid})
connections {
    ${conn_name} {
        version = 2
        local_addrs = ${local_real}
        remote_addrs = ${remote_real}
        proposals = aes256-sha256-modp2048
        mobike = no
        encap = no
        keyingtries = 0
        dpd_delay = 20s
        reauth_time = 0s
        rekey_time = 4h
        local {
            auth = psk
            id = ${local_real}
        }
        remote {
            auth = psk
            id = ${remote_real}
        }
        children {
            ${child_name} {
                local_ts = ${local_ts}
                remote_ts = ${remote_ts}
                if_id_in = ${if_id}
                if_id_out = ${if_id}
                reqid = ${reqid}
                esp_proposals = aes128gcm16
                rekey_time = 30m
                rand_time = 3m
                life_time = 1h
                start_action = ${start_act}
                dpd_action = restart
                close_action = start
            }
        }
    }
}
secrets {
    ike-${conn_name} {
        id-1 = ${local_real}
        id-2 = ${remote_real}
        secret = 0x${psk}
    }
}
SWAN
    chmod 600 "${conf_file}"
}

generate_esp_up() {
    local script_path="$1"
    local mss=$(( TUN_MTU - 40 ))
    local advmss=$(( TUN_MTU - 40 ))
    local tun_subnet
    tun_subnet=$(echo "${LOCAL_TUN}" | sed -E 's/\.[0-9]+\//.0\//')

    cat > "$script_path" <<UP
#!/bin/bash
set -euo pipefail

# Managed by XManager ESP Tunnel Manager v${VERSION}
TUNNEL_ID="${TUNNEL_ID}"
ROLE="${ROLE}"
TUN_IF="${TUN_IF}"
IF_WAN="${IF_WAN}"
LOCAL_REAL="${LOCAL_REAL}"
REMOTE_REAL="${REMOTE_REAL}"
LOCAL_TUN="${LOCAL_TUN}"
REMOTE_TUN="${REMOTE_TUN}"
TUN_MTU="${TUN_MTU}"
IF_ID="${IF_ID}"
REQ_ID="${REQ_ID}"
DSR_MODE="${DSR_MODE}"
CLIENT_PORT="${CLIENT_PORT}"
BACKEND_PORT="${BACKEND_PORT}"
ROUTE_TABLE="${ROUTE_TABLE}"
RULE_PRIORITY="${RULE_PRIORITY}"
ROUTE_MARK="${ROUTE_MARK}"
CONN_NAME="esp-tun-${TUNNEL_ID}"
CHILD_NAME="esp-tun-${TUNNEL_ID}-child"
NFT_TABLE="esp_dsr_${TUNNEL_ID}"
STATE_DIR="${STATE_DIR}"

mkdir -p -m 700 "\${STATE_DIR}"
rm -f "\${STATE_DIR}/\${TUN_IF}.stopped"

modprobe xfrm_interface 2>/dev/null || true
modprobe esp4 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
SYS_WAN="\${IF_WAN//./\/}"
sysctl -w "net.ipv4.conf.\${SYS_WAN}.rp_filter=0" >/dev/null 2>&1 || true
sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

# Wait for WAN interface at boot
w_cnt=0
while ! ip link show "\${IF_WAN}" >/dev/null 2>&1; do
    w_cnt=\$((w_cnt + 1))
    [ "\$w_cnt" -ge 15 ] && { echo "WAN interface \${IF_WAN} missing" >&2; exit 1; }
    sleep 1
done

# Create or validate dedicated XFRM interface
if ip link show dev "\${TUN_IF}" >/dev/null 2>&1; then
    CURR_KIND=\$(ip -j -d link show dev "\${TUN_IF}" | python3 -c "import sys,json; d=json.load(sys.stdin)[0].get('linkinfo',{}); print(d.get('info_kind',''))" 2>/dev/null || true)
    if [ "\${CURR_KIND}" != "xfrm" ]; then
        echo "Interface \${TUN_IF} exists and is not xfrm (\${CURR_KIND})" >&2
        exit 1
    fi
else
    ip link add dev "\${TUN_IF}" type xfrm dev "\${IF_WAN}" if_id "\${IF_ID}"
fi

ip address replace "\${LOCAL_TUN}" dev "\${TUN_IF}"
ip link set dev "\${TUN_IF}" mtu "\${TUN_MTU}" up
ip route replace "${tun_subnet}" dev "\${TUN_IF}" proto kernel scope link src "\${LOCAL_TUN%/*}" advmss ${advmss} 2>/dev/null || true
sysctl -w "net.ipv4.conf.\${TUN_IF}.rp_filter=0" >/dev/null 2>&1 || true

if command -v tc &>/dev/null; then
    tc qdisc replace dev "\${IF_WAN}" root fq flow_limit 1000 2>/dev/null || tc qdisc replace dev "\${IF_WAN}" root fq 2>/dev/null || true
    tc qdisc replace dev "\${TUN_IF}" root noqueue 2>/dev/null || true
fi

# Ensure strongSwan is running and load this tunnel's connection without interrupting others
if ! systemctl is-active --quiet strongswan; then
    systemctl start strongswan
    sleep 1
fi
swanctl --load-all >/dev/null 2>&1 || true
if [ "\${ROLE}" = "iran" ]; then
    swanctl --initiate --child "\${CHILD_NAME}" --timeout 5 >/dev/null 2>&1 || true
fi

# Optional standalone Direct-Return DSR rules (skip when XForwarder manages forwarding)
if [ "\${DSR_MODE}" = "standalone" ]; then
    if [ "\${ROLE}" = "kharej" ]; then
        ip route replace throw "\${REMOTE_REAL}/32" table "\${ROUTE_TABLE}"
        ip route replace default dev "\${TUN_IF}" table "\${ROUTE_TABLE}"
        if ! ip -4 rule show | grep -qE "^[[:space:]]*\${RULE_PRIORITY}:"; then
            ip rule add priority "\${RULE_PRIORITY}" fwmark "\${ROUTE_MARK}/0xffffffff" lookup "\${ROUTE_TABLE}"
        fi
        nft -f - <<NFT
table ip \${NFT_TABLE}
delete table ip \${NFT_TABLE}
table ip \${NFT_TABLE} {
    chain pre {
        type filter hook prerouting priority -310; policy accept;
        iifname "\${TUN_IF}" ip daddr \${LOCAL_TUN%/*} tcp dport \${BACKEND_PORT} counter notrack
    }
    chain input {
        type filter hook input priority -20; policy accept;
        ip daddr \${LOCAL_TUN%/*} tcp dport \${BACKEND_PORT} iifname != "\${TUN_IF}" counter drop
    }
    chain out_raw {
        type filter hook output priority -310; policy accept;
        ip saddr \${LOCAL_TUN%/*} tcp sport \${BACKEND_PORT} counter notrack
    }
    chain handshake_route {
        type route hook output priority -149; policy accept;
        ip saddr \${LOCAL_TUN%/*} tcp sport \${BACKEND_PORT} tcp flags & syn == syn tcp option maxseg size > ${mss} tcp option maxseg size set ${mss}
        ip saddr \${LOCAL_TUN%/*} tcp sport \${BACKEND_PORT} tcp flags & (syn | ack) == (syn | ack) counter meta mark set \${ROUTE_MARK}
    }
    chain post {
        type filter hook postrouting priority 300; policy accept;
        oifname "\${IF_WAN}" ip saddr \${LOCAL_TUN%/*} tcp sport \${BACKEND_PORT} tcp flags & (syn | ack) != (syn | ack) counter ip saddr set \${REMOTE_REAL} tcp sport set \${CLIENT_PORT}
    }
}
NFT
    else
        nft -f - <<NFT
table ip \${NFT_TABLE}
delete table ip \${NFT_TABLE}
table ip \${NFT_TABLE} {
    chain pre {
        type filter hook prerouting priority -310; policy accept;
        iifname "\${IF_WAN}" ip daddr \${LOCAL_REAL} tcp dport \${CLIENT_PORT} counter notrack ip daddr set \${REMOTE_TUN} tcp dport set \${BACKEND_PORT}
        iifname "\${TUN_IF}" ip saddr \${REMOTE_TUN} tcp sport \${BACKEND_PORT} counter notrack
    }
    chain forward {
        type filter hook forward priority -5; policy accept;
        iifname "\${IF_WAN}" oifname "\${TUN_IF}" ip daddr \${REMOTE_TUN} tcp dport \${BACKEND_PORT} tcp flags & syn == syn tcp option maxseg size > ${mss} tcp option maxseg size set ${mss}
        iifname "\${IF_WAN}" oifname "\${TUN_IF}" ip daddr \${REMOTE_TUN} tcp dport \${BACKEND_PORT} counter accept
        iifname "\${TUN_IF}" oifname "\${IF_WAN}" ip saddr \${REMOTE_TUN} tcp sport \${BACKEND_PORT} tcp flags & (syn | ack) == (syn | ack) counter accept
        iifname "\${TUN_IF}" counter drop
        oifname "\${TUN_IF}" counter drop
    }
    chain post {
        type filter hook postrouting priority 300; policy accept;
        iifname "\${TUN_IF}" oifname "\${IF_WAN}" ip saddr \${REMOTE_TUN} tcp sport \${BACKEND_PORT} tcp flags & (syn | ack) == (syn | ack) counter ip saddr set \${LOCAL_REAL} tcp sport set \${CLIENT_PORT}
    }
}
NFT
    fi
fi

echo "ESP tunnel \${TUN_IF} UP (if_id=\${IF_ID}, dsr=\${DSR_MODE})"
UP
    chmod 755 "$script_path"
}

generate_esp_down() {
    local script_path="$1"
    cat > "$script_path" <<DOWN
#!/bin/bash
# Managed by XManager ESP Tunnel Manager v${VERSION}
TUNNEL_ID="${TUNNEL_ID}"
ROLE="${ROLE}"
TUN_IF="${TUN_IF}"
REMOTE_REAL="${REMOTE_REAL}"
DSR_MODE="${DSR_MODE}"
ROUTE_TABLE="${ROUTE_TABLE}"
RULE_PRIORITY="${RULE_PRIORITY}"
ROUTE_MARK="${ROUTE_MARK}"
CONN_NAME="esp-tun-${TUNNEL_ID}"
NFT_TABLE="esp_dsr_${TUNNEL_ID}"
STATE_DIR="${STATE_DIR}"

mkdir -p -m 700 "\${STATE_DIR}"
touch "\${STATE_DIR}/\${TUN_IF}.stopped"

nft delete table ip "\${NFT_TABLE}" 2>/dev/null || true

if [ "\${DSR_MODE}" = "standalone" ] && [ "\${ROLE}" = "kharej" ]; then
    ip rule del priority "\${RULE_PRIORITY}" fwmark "\${ROUTE_MARK}/0xffffffff" lookup "\${ROUTE_TABLE}" 2>/dev/null || true
    ip route del default dev "\${TUN_IF}" table "\${ROUTE_TABLE}" 2>/dev/null || true
    ip route del throw "\${REMOTE_REAL}/32" table "\${ROUTE_TABLE}" 2>/dev/null || true
fi

if command -v swanctl &>/dev/null && systemctl is-active --quiet strongswan; then
    swanctl --terminate --ike "\${CONN_NAME}" --timeout 3 >/dev/null 2>&1 || true
    swanctl --unload-conn --name "\${CONN_NAME}" >/dev/null 2>&1 || true
fi

ip link set dev "\${TUN_IF}" down 2>/dev/null || true
ip link del dev "\${TUN_IF}" 2>/dev/null || true

echo "ESP tunnel \${TUN_IF} DOWN"
DOWN
    chmod 755 "$script_path"
}

generate_watchdog() {
    local script_path="$1"
    cat > "$script_path" <<WD
#!/bin/bash
# Managed by XManager ESP Tunnel Manager v${VERSION}
TUNNEL_ID="${TUNNEL_ID}"
TUN_IF="${TUN_IF}"
ROLE="${ROLE}"
UP_SCRIPT="${SCRIPTS_DIR}/${TUN_IF}-up.sh"
STATE_DIR="${STATE_DIR}"
FAIL_FILE="\${STATE_DIR}/\${TUN_IF}.fails"
COOLDOWN_FILE="\${STATE_DIR}/\${TUN_IF}.cooldown"
STOP_FILE="\${STATE_DIR}/\${TUN_IF}.stopped"
TAG="wd-\${TUN_IF}"

[ -f "\${STOP_FILE}" ] && exit 0

mkdir -p -m 700 "\${STATE_DIR}"

LOCAL_TUN=\$(grep -E '^LOCAL_TUN=' "\${UP_SCRIPT}" 2>/dev/null | head -1 | sed -E 's/^LOCAL_TUN=//; s/^["'\'']//; s/["'\'']$//')
SUBNET_PREFIX=\$(echo "\${LOCAL_TUN}" | sed -E 's/\.[0-9]+\/[0-9]+\$//')
if [[ "\${LOCAL_TUN}" == *".1/"* ]]; then
    TARGET_IP="\${SUBNET_PREFIX}.2"
else
    TARGET_IP="\${SUBNET_PREFIX}.1"
fi

if ! ip link show "\${TUN_IF}" >/dev/null 2>&1; then
    logger -t "\${TAG}" "Interface \${TUN_IF} missing - restarting esp-tunnel-\${TUNNEL_ID}"
    systemctl restart "esp-tunnel-\${TUNNEL_ID}" || true
    exit 0
fi

# Verify peer over ESP tunnel; on Iran side re-initiate CHILD_SA if ping fails
if ping -c 2 -W 2 -I "\${TUN_IF}" "\${TARGET_IP}" >/dev/null 2>&1; then
    rm -f "\${FAIL_FILE}" "\${COOLDOWN_FILE}"
    exit 0
fi

fails=\$(cat "\${FAIL_FILE}" 2>/dev/null || echo 0)
[[ ! "\$fails" =~ ^[0-9]+$ ]] && fails=0
fails=\$((fails + 1))
echo "\$fails" > "\${FAIL_FILE}"
logger -t "\${TAG}" "Tunnel \${TUN_IF} ping failed (\${fails}/3)"

if [ "\$fails" -ge 3 ]; then
    now=\$(date +%s)
    next_try=\$(cat "\${COOLDOWN_FILE}" 2>/dev/null || echo 0)
    [[ ! "\$next_try" =~ ^[0-9]+$ ]] && next_try=0
    if [ "\$now" -lt "\$next_try" ]; then
        exit 0
    fi
    echo \$((now + 30)) > "\${COOLDOWN_FILE}"
    logger -t "\${TAG}" "Recovering ESP tunnel \${TUN_IF} (esp-tunnel-\${TUNNEL_ID})"
    if [ "\${ROLE}" = "iran" ] && command -v swanctl &>/dev/null; then
        swanctl --initiate --child "esp-tun-\${TUNNEL_ID}-child" --timeout 5 >/dev/null 2>&1 || systemctl restart "esp-tunnel-\${TUNNEL_ID}" || true
    else
        systemctl restart "esp-tunnel-\${TUNNEL_ID}" || true
    fi
    echo 0 > "\${FAIL_FILE}"
fi
WD
    chmod 755 "$script_path"
}

create_systemd_units() {
    local tid="$1" up_script="$2" down_script="$3" wd_script="$4" role_label="$5" remote_tun="$6"
    local svc_tun="${SYSTEMD_DIR}/esp-tunnel-${tid}.service"
    local svc_ka="${SYSTEMD_DIR}/esp-keepalive-${tid}.service"
    local svc_wd="${SYSTEMD_DIR}/esp-watchdog-${tid}.service"
    local tmr_wd="${SYSTEMD_DIR}/esp-watchdog-${tid}.timer"

    cat > "$svc_tun" <<UNIT
[Unit]
Description=ESP XFRM Tunnel ${tid} - ${role_label}
Wants=network-online.target strongswan.service
After=network-online.target strongswan.service

[Service]
Type=oneshot
ExecStart=${up_script}
ExecStop=${down_script}
RemainAfterExit=yes
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

    cat > "$svc_ka" <<UNIT
[Unit]
Description=ESP Tunnel ${tid} Keep-Alive
After=esp-tunnel-${tid}.service
Requires=esp-tunnel-${tid}.service

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do ping -c 1 -W 2 -I esp${tid} ${remote_tun} >/dev/null 2>&1 || true; sleep 5; done'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

    cat > "$svc_wd" <<UNIT
[Unit]
Description=ESP Tunnel ${tid} Watchdog Check
After=esp-tunnel-${tid}.service

[Service]
Type=oneshot
ExecStart=${wd_script}
UNIT

    cat > "$tmr_wd" <<UNIT
[Unit]
Description=ESP Tunnel ${tid} Watchdog Timer

[Timer]
OnBootSec=25s
OnUnitActiveSec=10s
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT

    chmod 644 "$svc_tun" "$svc_ka" "$svc_wd" "$tmr_wd"
    systemctl daemon-reload
    systemctl enable "esp-tunnel-${tid}" "esp-keepalive-${tid}" "esp-watchdog-${tid}.timer" &>/dev/null
    systemctl restart "esp-tunnel-${tid}"
    systemctl restart "esp-keepalive-${tid}"
    systemctl restart "esp-watchdog-${tid}.timer"
}

# ─── Setup Flows ──────────────────────────────────────────────────
setup_role() {
    local role="$1"
    local role_label="Iran"
    [ "$role" = "kharej" ] && role_label="Kharej (Outside)"

    echo ""
    print_double_line
    echo -e " ${CYAN}${BOLD}Setup ESP / XFRM Tunnel — ${role_label} Server${NC}"
    print_double_line

    ensure_prereqs || return 1

    local tid=""
    read_tunnel_id tid

    local def_wan def_ip
    def_wan=$(detect_default_iface)
    [ -z "$def_wan" ] && def_wan="eth0"
    local if_wan=""
    read_interface "Public WAN interface" "$def_wan" if_wan
    def_ip=$(detect_iface_ip "$if_wan")

    local local_real="" remote_real=""
    read_ip "This server public IPv4" "$def_ip" local_real
    if [ "$role" = "iran" ]; then
        read_ip "Outside (Kharej) server public IPv4" "" remote_real
    else
        read_ip "Iran server public IPv4" "" remote_real
    fi

    local tun_if="esp${tid}"
    local free_sub
    free_sub=$(find_free_tunnel_subnet "10.87" "$tid")
    local custom_sub=""
    while true; do
        read_input "Tunnel /30 subnet prefix (e.g. 10.87.${tid} or 10.250.50)" "$free_sub" custom_sub
        custom_sub=$(echo "$custom_sub" | tr -d '\r\n[:space:]')
        if validate_subnet_prefix "$custom_sub"; then
            break
        fi
        msg_err "Invalid /24 prefix '${custom_sub}'. Example: 10.87.${tid}"
    done

    local local_tun remote_tun outside_tun_ip
    if [ "$role" = "iran" ]; then
        local_tun="${custom_sub}.1/30"
        remote_tun="${custom_sub}.2"
        outside_tun_ip="${custom_sub}.2"
    else
        local_tun="${custom_sub}.2/30"
        remote_tun="${custom_sub}.1"
        outside_tun_ip="${custom_sub}.2"
    fi

    local tun_mtu=""
    read_mtu "XFRM interface MTU" "1400" tun_mtu

    echo ""
    msg_info "Forwarding integration mode:"
    echo -e "   ${GREEN}1)${NC} Pure ESP interface only — manage forwarding in XForwarder (Recommended)"
    echo -e "      (Use 'nftables_dsr_synack' on Iran and 'nftables_dsr_direct' on Outside)"
    echo -e "   ${CYAN}2)${NC} Standalone Direct-Return DSR rules in nftables (all-in-one without XForwarder)"
    local fmode="" dsr_mode="xforwarder" client_port="1036" backend_port="24443"
    read -p "  Select [1]: " fmode
    fmode="${fmode:-1}"
    if [ "$fmode" = "2" ]; then
        dsr_mode="standalone"
        read_port "Public client TCP port on Iran" "1036" client_port
        read_port "Backend VPN TCP port on ${outside_tun_ip}" "24443" backend_port
    fi

    local psk_file="${ESP_CFG_DIR}/esp${tid}.psk"
    local psk_val=""
    read_or_generate_psk "$role" "$psk_file" psk_val

    local if_id reqid route_table rule_prio route_mark
    if_id=$(printf '0x%x' $((0x4250 + tid)))
    reqid=$((4251000 + tid))
    route_table=$((42500 + tid))
    rule_prio=$((12500 + tid))
    route_mark=$(printf '0x%08x' $((0x42510000 + tid)))

    echo ""
    print_double_line
    echo -e " ${YELLOW}${BOLD}Review Configuration (Tunnel ID ${tid})${NC}"
    print_line
    echo -e "  Role             : ${WHITE}${role_label}${NC}"
    echo -e "  XFRM Interface   : ${CYAN}${tun_if}${NC} (if_id=${if_id}, reqid=${reqid})"
    echo -e "  WAN Interface    : ${CYAN}${if_wan}${NC}"
    echo -e "  Local Public IP  : ${GREEN}${local_real}${NC}"
    echo -e "  Peer Public IP   : ${GREEN}${remote_real}${NC}"
    echo -e "  Local Tunnel IP  : ${YELLOW}${local_tun}${NC}"
    echo -e "  Peer Tunnel IP   : ${YELLOW}${remote_tun}${NC}"
    echo -e "  MTU              : ${WHITE}${tun_mtu}${NC}"
    echo -e "  Forward Mode     : ${MAGENTA}${dsr_mode}${NC}"
    if [ "$dsr_mode" = "standalone" ]; then
        echo -e "  Client/Backend   : ${CYAN}${client_port} -> ${outside_tun_ip}:${backend_port}${NC} (table ${route_table}, mark ${route_mark})"
    fi
    echo -e "  PSK File         : ${DIM}${psk_file} (0600)${NC}"
    print_double_line

    local confirm=""
    read -p "  Apply configuration and start ESP tunnel? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        msg_warn "Aborted by user."
        return 0
    fi

    TUNNEL_ID="$tid"
    ROLE="$role"
    TUN_IF="$tun_if"
    IF_WAN="$if_wan"
    LOCAL_REAL="$local_real"
    REMOTE_REAL="$remote_real"
    LOCAL_TUN="$local_tun"
    REMOTE_TUN="$remote_tun"
    TUN_MTU="$tun_mtu"
    IF_ID="$if_id"
    REQ_ID="$reqid"
    DSR_MODE="$dsr_mode"
    CLIENT_PORT="$client_port"
    BACKEND_PORT="$backend_port"
    ROUTE_TABLE="$route_table"
    RULE_PRIORITY="$rule_prio"
    ROUTE_MARK="$route_mark"

    local up_script="${SCRIPTS_DIR}/${tun_if}-up.sh"
    local down_script="${SCRIPTS_DIR}/${tun_if}-down.sh"
    local wd_script="${SCRIPTS_DIR}/${tun_if}-watchdog.sh"

    persist_sysctl_tuning
    ensure_charon_no_routes
    generate_swanctl_conf "$tid" "$role" "$local_real" "$remote_real" "$outside_tun_ip" "$if_id" "$reqid" "$psk_val"
    generate_esp_up "$up_script"
    generate_esp_down "$down_script"
    generate_watchdog "$wd_script"
    create_systemd_units "$tid" "$up_script" "$down_script" "$wd_script" "$role_label" "$remote_tun"

    echo ""
    msg_ok "ESP Tunnel ${tid} (${tun_if}) configured and started!"
    if [ "$role" = "iran" ]; then
        echo ""
        msg_info "PSK stored at ${psk_file} (run 'cat ${psk_file}' on Iran when configuring Kharej; keep secret)."
    fi
    if [ "$dsr_mode" = "xforwarder" ]; then
        echo ""
        msg_info "Next step in XForwarder Web UI:"
        if [ "$role" = "iran" ]; then
            echo -e "  Protocol: ${CYAN}tcp${NC} | Type: ${GREEN}nftables_dsr_synack${NC} | Target: ${YELLOW}${outside_tun_ip}${NC} | Tunnel Iface: ${CYAN}${tun_if}${NC} | Spoof IP: ${WHITE}${local_real}${NC}"
        else
            echo -e "  Protocol: ${CYAN}tcp${NC} | Type: ${GREEN}nftables_dsr_direct${NC} | Target: ${YELLOW}${outside_tun_ip}${NC} | Ingress Iface: ${CYAN}${tun_if}${NC} | Spoof IP: ${WHITE}${remote_real}${NC}"
        fi
    fi
}

setup_iran()   { setup_role "iran"; }
setup_kharej() { setup_role "kharej"; }

# ─── Management & Inspection ──────────────────────────────────────
get_all_tunnel_ids() {
    local f tid ids=()
    for f in "${SCRIPTS_DIR}"/esp[0-9]*-up.sh; do
        [ -f "$f" ] || continue
        tid=$(basename "$f" | sed -E 's/^esp([0-9]+)-up\.sh$/\1/')
        [[ "$tid" =~ ^[0-9]+$ ]] && ids+=("$tid")
    done
    if [ ${#ids[@]} -gt 0 ]; then
        printf '%s\n' "${ids[@]}" | sort -n -u
    fi
}

list_tunnels() {
    echo ""
    print_line
    echo -e " ${CYAN}${BOLD}Configured ESP / XFRM Tunnels${NC}"
    print_line
    local ids
    mapfile -t ids < <(get_all_tunnel_ids)
    if [ ${#ids[@]} -eq 0 ]; then
        msg_warn "No ESP tunnels configured yet."
        return 0
    fi
    local tid up_f role lt rt lr rr mode st sa_st
    for tid in "${ids[@]}"; do
        up_f="${SCRIPTS_DIR}/esp${tid}-up.sh"
        role=$(extract_up_var "ROLE" "$up_f")
        lt=$(extract_up_var "LOCAL_TUN" "$up_f")
        rt=$(extract_up_var "REMOTE_TUN" "$up_f")
        lr=$(extract_up_var "LOCAL_REAL" "$up_f")
        rr=$(extract_up_var "REMOTE_REAL" "$up_f")
        mode=$(extract_up_var "DSR_MODE" "$up_f")
        st=$(systemctl is-active "esp-tunnel-${tid}" 2>/dev/null || echo "inactive")
        sa_st="DOWN"
        if command -v swanctl &>/dev/null && swanctl --list-sas --ike "esp-tun-${tid}" 2>/dev/null | grep -q "INSTALLED"; then
            sa_st="INSTALLED"
        fi
        echo -e "  ID ${WHITE}${tid}${NC} (esp${tid}) | Role: ${CYAN}${role}${NC} | ${lr} <-> ${rr} | ${lt} -> ${rt} | Mode: ${mode} | Svc: ${st} | ESP SA: ${sa_st}"
    done
}

do_dashboard() {
    print_header
    echo -e " ${BOLD}${WHITE}ESP / XFRM Tunnels Dashboard${NC}"
    print_double_line
    local ids
    mapfile -t ids < <(get_all_tunnel_ids)
    if [ ${#ids[@]} -eq 0 ]; then
        msg_warn "No ESP tunnels found. Use option 3 (Iran) or 4 (Kharej) to create one."
        return 0
    fi
    local tid up_f lt rt svc_st rx tx sa_info rtt
    for tid in "${ids[@]}"; do
        up_f="${SCRIPTS_DIR}/esp${tid}-up.sh"
        lt=$(extract_up_var "LOCAL_TUN" "$up_f")
        rt=$(extract_up_var "REMOTE_TUN" "$up_f")
        svc_st=$(systemctl is-active "esp-tunnel-${tid}" 2>/dev/null || echo "inactive")
        rx=$(cat "/sys/class/net/esp${tid}/statistics/rx_bytes" 2>/dev/null || echo 0)
        tx=$(cat "/sys/class/net/esp${tid}/statistics/tx_bytes" 2>/dev/null || echo 0)
        sa_info=$(swanctl --list-sas --ike "esp-tun-${tid}" 2>/dev/null | grep -E "ESTABLISHED|INSTALLED|ESP:" | head -n 2 | tr '\n' ' ' || true)
        rtt=$(ping -c 1 -W 1 -I "esp${tid}" "$rt" 2>/dev/null | sed -n 's/.*time=\([0-9.]* ms\).*/\1/p' | head -1)
        [ -z "$rtt" ] && rtt="unreachable"
        echo -e "  ${CYAN}esp${tid}${NC} [${svc_st}] | ${lt} -> ${rt} | Ping: ${YELLOW}${rtt}${NC} | RX: $(format_bytes "$rx") | TX: $(format_bytes "$tx")"
        [ -n "$sa_info" ] && echo -e "    ${DIM}${sa_info}${NC}"
    done
    print_double_line
}

do_health_check() {
    echo ""
    msg_info "Checking health of all ESP tunnels..."
    local ids tid up_f rt
    mapfile -t ids < <(get_all_tunnel_ids)
    [ ${#ids[@]} -eq 0 ] && { msg_warn "No ESP tunnels found."; return 0; }
    for tid in "${ids[@]}"; do
        up_f="${SCRIPTS_DIR}/esp${tid}-up.sh"
        rt=$(extract_up_var "REMOTE_TUN" "$up_f")
        echo -n "  esp${tid} -> ${rt}: "
        if ping -c 3 -i 0.2 -W 1 -I "esp${tid}" "$rt" >/dev/null 2>&1; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
        fi
    done
}

select_tunnel_id() {
    local var_name="$1"
    local tid=""
    list_tunnels
    echo ""
    read_input "Enter Tunnel ID" "" tid
    tid=$(echo "$tid" | tr -d '\r\n[:space:]')
    if [[ ! "$tid" =~ ^[0-9]+$ ]] || [ ! -f "${SCRIPTS_DIR}/esp${tid}-up.sh" ]; then
        msg_err "Tunnel ID '${tid}' not found."
        return 1
    fi
    printf -v "$var_name" "%s" "$tid"
    return 0
}

do_start()   { local id; select_tunnel_id id || return 1; systemctl start "esp-tunnel-${id}" "esp-keepalive-${id}" "esp-watchdog-${id}.timer"; msg_ok "Started esp${id}."; }
do_restart() { local id; select_tunnel_id id || return 1; systemctl restart "esp-tunnel-${id}" "esp-keepalive-${id}" "esp-watchdog-${id}.timer"; msg_ok "Restarted esp${id}."; }
do_stop()    { local id; select_tunnel_id id || return 1; systemctl stop "esp-watchdog-${id}.timer" "esp-keepalive-${id}" "esp-tunnel-${id}"; msg_ok "Stopped esp${id}."; }

do_rekey() {
    local id
    select_tunnel_id id || return 1
    msg_info "Rekeying CHILD_SA esp-tun-${id}-child..."
    swanctl --rekey --child "esp-tun-${id}-child" && msg_ok "Rekey completed." || msg_err "Rekey failed."
    swanctl --list-sas --ike "esp-tun-${id}" 2>/dev/null || true
}

do_status() {
    local id
    select_tunnel_id id || return 1
    echo ""
    systemctl status "esp-tunnel-${id}" --no-pager || true
    echo ""
    ip -d link show dev "esp${id}" 2>/dev/null || true
    ip -4 addr show dev "esp${id}" 2>/dev/null || true
    echo ""
    swanctl --list-sas --ike "esp-tun-${id}" 2>/dev/null || true
    echo ""
    nft list table ip "esp_dsr_${id}" 2>/dev/null || true
}

do_bulk_action() {
    local action="$1"
    local ids tid
    mapfile -t ids < <(get_all_tunnel_ids)
    [ ${#ids[@]} -eq 0 ] && { msg_warn "No ESP tunnels found."; return 0; }
    for tid in "${ids[@]}"; do
        if [ "$action" = "stop" ]; then
            systemctl stop "esp-watchdog-${tid}.timer" "esp-keepalive-${tid}" "esp-tunnel-${tid}" || true
        else
            systemctl "$action" "esp-tunnel-${tid}" "esp-keepalive-${tid}" "esp-watchdog-${tid}.timer" || true
        fi
        msg_ok "${action}: esp${tid}"
    done
}

do_logs() {
    local id
    select_tunnel_id id || return 1
    journalctl -u "esp-tunnel-${id}" -u "esp-watchdog-${id}" -u strongswan -n 40 --no-pager || true
}

do_delete() {
    local id
    select_tunnel_id id || return 1
    local ans=""
    read -p "  Permanently delete ESP tunnel esp${id} and its config/PSK? (y/N): " ans
    [[ ! "$ans" =~ ^[Yy]$ ]] && { msg_warn "Canceled."; return 0; }

    systemctl stop "esp-watchdog-${id}.timer" "esp-keepalive-${id}" "esp-tunnel-${id}" &>/dev/null || true
    systemctl disable "esp-watchdog-${id}.timer" "esp-keepalive-${id}" "esp-tunnel-${id}" &>/dev/null || true

    rm -f "${SYSTEMD_DIR}/esp-tunnel-${id}.service" \
          "${SYSTEMD_DIR}/esp-keepalive-${id}.service" \
          "${SYSTEMD_DIR}/esp-watchdog-${id}.service" \
          "${SYSTEMD_DIR}/esp-watchdog-${id}.timer"
    rm -f "${SCRIPTS_DIR}/esp${id}-up.sh" \
          "${SCRIPTS_DIR}/esp${id}-down.sh" \
          "${SCRIPTS_DIR}/esp${id}-watchdog.sh"
    rm -f "${SWANCTL_DIR}/esp-tun-${id}.conf" "${ESP_CFG_DIR}/esp${id}.psk"
    rm -f "${STATE_DIR}/esp${id}."*

    if [ ! "$(ls -A "${SWANCTL_DIR}" 2>/dev/null)" ]; then
        rm -f "${STRONGSWAN_DIR}/xmanager-esp.conf"
    fi
    systemctl daemon-reload
    msg_ok "Deleted ESP tunnel esp${id} cleanly."
}

# ─── Main Menu ────────────────────────────────────────────────────
main_menu() {
    while true; do
        print_header
        echo -e " ${BOLD}${WHITE}Overview${NC}"
        echo -e "  ${CYAN}1)${NC}  Dashboard"
        echo -e "  ${GREEN}2)${NC}  Health Check (ping all)"
        echo ""
        echo -e " ${BOLD}${WHITE}Setup ESP / XFRM Tunnel${NC}"
        echo -e "  ${GREEN}3)${NC}  Setup Iran Server"
        echo -e "  ${BLUE}4)${NC}  Setup Kharej Server"
        echo ""
        echo -e " ${BOLD}${WHITE}Single Tunnel${NC}"
        echo -e "  ${CYAN}5)${NC}  List Tunnels"
        echo -e "  ${GREEN}6)${NC}  Start a Tunnel"
        echo -e "  ${YELLOW}7)${NC}  Restart a Tunnel"
        echo -e "  ${YELLOW}8)${NC}  Stop a Tunnel"
        echo -e "  ${CYAN}9)${NC}  Tunnel Details & SA Status"
        echo -e "  ${MAGENTA}10)${NC} Rekey CHILD_SA (Rotate ESP SPI)"
        echo ""
        echo -e " ${BOLD}${WHITE}Bulk Operations${NC}"
        echo -e "  ${GREEN}11)${NC} Start All Tunnels"
        echo -e "  ${YELLOW}12)${NC} Restart All Tunnels"
        echo -e "  ${YELLOW}13)${NC} Stop All Tunnels"
        echo ""
        echo -e " ${BOLD}${WHITE}Logs & Danger${NC}"
        echo -e "  ${CYAN}14)${NC} View Logs"
        echo -e "  ${RED}15)${NC} Delete a Tunnel"
        echo ""
        echo -e " ${BOLD}${WHITE}Install & Tuning${NC}"
        echo -e "  ${MAGENTA}16)${NC} Install Prerequisites (strongSwan / nftables)"
        echo -e "  ${GREEN}17)${NC} Optimize Kernel & Network (BBR / fq / rp_filter=0)"
        echo ""
        echo -e "  ${DIM}0)${NC}  Exit"
        echo ""
        local choice=""
        read -p "  Select: " choice || exit 0

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
            10) do_rekey ;;
            11) do_bulk_action "start" ;;
            12) do_bulk_action "restart" ;;
            13) do_bulk_action "stop" ;;
            14) do_logs ;;
            15) do_delete ;;
            16) install_prereqs ;;
            17) do_optimize_kernel ;;
            0)  echo -e "\n ${GREEN}Goodbye!${NC}\n"; exit 0 ;;
            *)  msg_err "Invalid option." ;;
        esac

        echo ""
        read -p "  Press Enter to continue..." || exit 0
    done
}

# ─── Entry Point ──────────────────────────────────────────────────
if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ]; then
    echo "ESP / XFRM Tunnel Manager v${VERSION}"
    exit 0
fi

check_root
main_menu
