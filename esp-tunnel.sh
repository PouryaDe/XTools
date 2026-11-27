#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  ESP (IPSEC XFRM) TUNNEL & DIRECT-RETURN MANAGER v1.1.0        ║
# ║  Route-Based XFRM (espN) + IKEv2/strongSwan + Raw ESP (Proto50)║
# ║  Supports XForwarder DSR (SYN-ACK/Direct) & Standalone Relay   ║
# ╚════════════════════════════════════════════════════════════════╝

VERSION="1.1.0"

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

normalize_subnet_prefix() {
    local raw="$1"
    raw=$(echo "$raw" | tr -d '\r\n[:space:]')
    # Strip trailing dot or CIDR/host 4th octet (e.g. 10.250.51. or 10.250.51.0/30 -> 10.250.51)
    raw="${raw%.}"
    if [[ "$raw" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        raw="${BASH_REMATCH[1]}"
    fi
    echo "$raw"
}

get_next_free_tunnel_id() {
    local i=1
    while [ $i -le 255 ]; do
        if [ ! -f "${SYSTEMD_DIR}/esp-tunnel-${i}.service" ] && [ ! -f "${SCRIPTS_DIR}/esp${i}-up.sh" ] && ! ip link show "esp${i}" &>/dev/null; then
            echo "$i"
            return 0
        fi
        i=$(( i + 1 ))
    done
    echo "1"
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
    [[ ! "$tid" =~ ^[0-9]+$ ]] && tid=1
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
    local _ri_prompt="$1" _ri_default="$2" _ri_var="$3"
    local _ri_in=""
    if [ -n "$_ri_default" ]; then
        read -r -p "  ${_ri_prompt} [${_ri_default}]: " _ri_in
        _ri_in="${_ri_in//$'\r'/}"
        printf -v "$_ri_var" "%s" "${_ri_in:-$_ri_default}"
    else
        read -r -p "  ${_ri_prompt}: " _ri_in
        _ri_in="${_ri_in//$'\r'/}"
        printf -v "$_ri_var" "%s" "$_ri_in"
    fi
}

read_ip() {
    local _rip_prompt="$1" _rip_default="$2" _rip_var="$3"
    local _rip_val=""
    while true; do
        read_input "$_rip_prompt" "$_rip_default" _rip_val
        _rip_val=$(echo "$_rip_val" | tr -d '\r\n[:space:]')
        if [ -z "$_rip_val" ]; then
            msg_err "IP address is required."
            continue
        fi
        if validate_ipv4 "$_rip_val"; then
            printf -v "$_rip_var" "%s" "$_rip_val"
            return 0
        else
            msg_err "Invalid IPv4 address format '${_rip_val}'. Try again."
        fi
    done
}

read_port() {
    local _rp_prompt="$1" _rp_default="$2" _rp_var="$3"
    local _rp_val=""
    while true; do
        read_input "$_rp_prompt" "$_rp_default" _rp_val
        _rp_val=$(echo "$_rp_val" | tr -d '\r\n[:space:]')
        if [[ "$_rp_val" =~ ^[0-9]+$ ]] && [ "$_rp_val" -ge 1 ] && [ "$_rp_val" -le 65535 ]; then
            printf -v "$_rp_var" "%s" "$_rp_val"
            return 0
        else
            msg_err "Invalid port number '${_rp_val}'. Must be between 1 and 65535."
        fi
    done
}

read_mtu() {
    local _rmtu_prompt="$1" _rmtu_default="$2" _rmtu_var="$3"
    local _rmtu_val=""
    while true; do
        read_input "$_rmtu_prompt" "$_rmtu_default" _rmtu_val
        _rmtu_val=$(echo "$_rmtu_val" | tr -d '\r\n[:space:]')
        if [[ "$_rmtu_val" =~ ^[0-9]+$ ]] && [ "$_rmtu_val" -ge 1280 ] && [ "$_rmtu_val" -le 1460 ]; then
            printf -v "$_rmtu_var" "%s" "$_rmtu_val"
            return 0
        else
            msg_err "Invalid MTU '${_rmtu_val}'. Recommended range for XFRM/ESP is 1280-1460 (default 1400)."
        fi
    done
}

read_tunnel_id() {
    local _rtid_var="$1"
    local _rtid_def
    _rtid_def=$(get_next_free_tunnel_id)
    local _rtid=""
    while true; do
        read_input "Tunnel ID (1-255, Enter for ${_rtid_def})" "$_rtid_def" _rtid
        _rtid=$(echo "$_rtid" | tr -d '\r\n[:space:]')
        if [ -z "$_rtid" ]; then
            msg_err "Tunnel ID is required! Please enter a number between 1 and 255."
            continue
        fi
        if ! [[ "$_rtid" =~ ^[0-9]+$ ]] || [ "$_rtid" -lt 1 ] || [ "$_rtid" -gt 255 ]; then
            msg_err "Invalid Tunnel ID '${_rtid}'! Must be an integer between 1 and 255."
            continue
        fi

        local tun_dev="esp${_rtid}"
        local svc_file="${SYSTEMD_DIR}/esp-tunnel-${_rtid}.service"
        local up_file="${SCRIPTS_DIR}/esp${_rtid}-up.sh"
        if [ -f "$svc_file" ] || [ -f "$up_file" ] || ip link show "$tun_dev" &>/dev/null; then
            msg_warn "Tunnel ID ${_rtid} (${tun_dev}) already exists on this server!"
            read -p "  Do you want to overwrite and reconfigure it? (y/N): " ow_choice
            if [[ "$ow_choice" =~ ^[Yy]$ ]]; then
                printf -v "$_rtid_var" "%s" "$_rtid"
                return 0
            else
                msg_info "Please choose a different Tunnel ID."
                continue
            fi
        fi

        printf -v "$_rtid_var" "%s" "$_rtid"
        return 0
    done
}

read_interface() {
    local prompt="$1" default="$2" _rif_var="$3"
    local _rif=""
    while true; do
        read_input "$prompt" "$default" _rif
        _rif=$(echo "$_rif" | tr -d '\r\n[:space:]')
        [ -z "$_rif" ] && _rif="$default"
        if [ -z "$_rif" ]; then
            msg_err "Interface name cannot be empty."
            continue
        fi
        if [[ ! "$_rif" =~ ^[a-zA-Z0-9_.:-]+$ ]] || [ "${#_rif}" -gt 15 ]; then
            msg_err "Invalid interface name '${_rif}'. Allowed: alphanumeric, '.', '_', ':', '-' (max 15 chars)."
            continue
        fi
        if ip link show "$_rif" &>/dev/null; then
            printf -v "$_rif_var" "%s" "$_rif"
            return 0
        else
            msg_warn "Interface '${_rif}' does not currently exist on this system!"
            read -p "  Are you sure you want to use interface '${_rif}'? (y/N): " if_confirm
            if [[ "$if_confirm" =~ ^[Yy]$ ]]; then
                printf -v "$_rif_var" "%s" "$_rif"
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
    if ! modprobe xfrm_interface 2>/dev/null; then
        if grep -qw 'ipv6.disable=1' /proc/cmdline 2>/dev/null; then
            msg_err "Kernel boot parameter 'ipv6.disable=1' is active in /proc/cmdline."
            msg_err "The xfrm_interface module depends on xfrm6_tunnel/tunnel6 and fails with EAFNOSUPPORT when IPv6 is disabled at boot."
            msg_warn "Fix: Remove 'ipv6.disable=1' from /etc/default/grub, run 'update-grub', and reboot (use sysctl net.ipv6.conf.all.disable_ipv6=1 instead if needed)."
        else
            msg_err "Failed to load kernel module 'xfrm_interface' (required for XFRM ESP interfaces)."
            msg_warn "Try installing linux-modules-extra-\$(uname -r) or verify kernel CONFIG_XFRM_INTERFACE=m/y."
        fi
        return 1
    fi
    return 0
}

# ─── Kernel & NIC Tuning ──────────────────────────────────────────
persist_sysctl_tuning() {
    # Remove legacy 99-xmanager-tunnel.conf which sorted after 99-xforwarder.conf and downgraded buffers
    rm -f /etc/sysctl.d/99-xmanager-tunnel.conf 2>/dev/null || true

    if [ -f /etc/sysctl.d/99-xforwarder.conf ]; then
        rm -f /etc/sysctl.d/90-xmanager-tunnel.conf 2>/dev/null || true
        sysctl -e --system &>/dev/null || true
        sysctl -e -p /etc/sysctl.d/99-xforwarder.conf &>/dev/null || true
        [ -f /etc/sysctl.d/99-xforwarder-dsr.conf ] && sysctl -e -p /etc/sysctl.d/99-xforwarder-dsr.conf &>/dev/null || true
        return 0
    fi

    cat > /etc/sysctl.d/90-xmanager-tunnel.conf <<'SYSCTL'
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
    sysctl -e -p /etc/sysctl.d/90-xmanager-tunnel.conf &>/dev/null || true
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
    if [ -f /etc/sysctl.d/99-xforwarder.conf ]; then
        msg_ok "Kernel tuning synced with XForwarder (/etc/sysctl.d/99-xforwarder.conf); legacy 99-xmanager-tunnel.conf cleaned."
    else
        msg_ok "Kernel tuning applied and persisted to /etc/sysctl.d/90-xmanager-tunnel.conf"
    fi
}

# ─── PSK Management ───────────────────────────────────────────────
read_or_generate_psk() {
    local _rpsk_role="$1"
    local _rpsk_file="$2"
    local _rpsk_var="$3"
    local _rpsk_gen_var="${4:-}"

    mkdir -p -m 700 "${ESP_CFG_DIR}"

    if [ "$_rpsk_role" = "iran" ]; then
        echo ""
        msg_info "Pre-Shared Key (PSK) options for IKEv2 authentication:"
        echo -e "   ${GREEN}1)${NC} Generate a new 64-hex random PSK automatically (Recommended)"
        echo -e "   ${CYAN}2)${NC} Paste an existing 64-hex PSK from the peer server"
        local _rpsk_choice=""
        read -r -p "  Select [1]: " _rpsk_choice
        _rpsk_choice=$(echo "${_rpsk_choice:-1}" | tr -d '\r\n[:space:]')
        if [ "$_rpsk_choice" = "1" ]; then
            local _new_psk
            _new_psk=$(openssl rand -hex 32)
            umask 077
            printf '%s\n' "$_new_psk" > "$_rpsk_file"
            chmod 600 "$_rpsk_file"
            printf -v "$_rpsk_var" "%s" "$_new_psk"
            [ -n "$_rpsk_gen_var" ] && printf -v "$_rpsk_gen_var" "%s" "1"
            echo ""
            msg_ok "Generated 64-hex PSK (will also be shown at the end):"
            echo -e "  ${YELLOW}${BOLD}${_new_psk}${NC}"
            return 0
        fi
    fi

    local _pasted=""
    while true; do
        read -r -p "  Paste 64-hex PSK from peer server: " _pasted
        _pasted=$(echo "$_pasted" | tr -d '\r\n[:space:]"'\''')
        if [[ "$_pasted" =~ ^[0-9a-fA-F]{64}$ ]]; then
            umask 077
            printf '%s\n' "$_pasted" > "$_rpsk_file"
            chmod 600 "$_rpsk_file"
            printf -v "$_rpsk_var" "%s" "$_pasted"
            [ -n "$_rpsk_gen_var" ] && printf -v "$_rpsk_gen_var" "%s" "0"
            return 0
        else
            msg_err "Invalid PSK (got ${#_pasted} chars; expected exactly 64 hex chars 0-9/a-f)."
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
    local local_ts="0.0.0.0/0" remote_ts="${outside_tun_ip}/32"
    local start_act="start" dpd_act="restart" close_act="start"

    if [ "$role" = "kharej" ]; then
        local_ts="${outside_tun_ip}/32"
        remote_ts="0.0.0.0/0"
        start_act="none"
        dpd_act="clear"
        close_act="none"
    fi

    mkdir -p "${SWANCTL_DIR}"
    umask 077
    cat > "${conf_file}" <<SWAN
# Managed by XManager ESP Tunnel Manager v${VERSION} (ID ${tid})
connections {
    ${conn_name} {
        version = 2
        local_addrs = ${local_real}
        remote_addrs = ${remote_real}
        proposals = aes256-sha256-modp2048
        mobike = no
        encap = no
        unique = replace
        keyingtries = 0
        dpd_delay = 20s
        reauth_time = 0s
        rekey_time = 6h
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
                replay_window = 1024
                rekey_time = 2h
                rand_time = 10m
                life_time = 2h30m
                start_action = ${start_act}
                dpd_action = ${dpd_act}
                close_action = ${close_act}
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
    sleep 0.5
    if ! swanctl --list-sas --ike "\${CONN_NAME}" 2>/dev/null | grep -q "INSTALLED"; then
        swanctl --initiate --child "\${CHILD_NAME}" --timeout 5 >/dev/null 2>&1 || true
    fi
fi

# Immediately reconcile XForwarder DSR Direct policy routes for this interface (even on older XForwarder)
if [ "\${DSR_MODE}" = "xforwarder" ] && command -v python3 >/dev/null 2>&1 && [ -f /run/xforwarder/dsr_direct_routes.json ]; then
    python3 - "\${TUN_IF}" <<'PY' >/dev/null 2>&1 || true
import ipaddress, json, subprocess, sys
iface = sys.argv[1]
with open("/run/xforwarder/dsr_direct_routes.json", "r", encoding="utf-8") as f:
    data = json.load(f)
rules_out = subprocess.run(["ip", "-4", "rule", "show"], capture_output=True, text=True).stdout
for slot in (data.get("slots") or []):
    if str(slot.get("iface") or "").strip() != iface:
        continue
    tid = int(slot["table_id"])
    prio = int(slot["priority"])
    mark_int = int(str(slot["fwmark"]), 0)
    if not (42600 <= tid < 42664 and 12600 <= prio < 12664 and 0x42600001 <= mark_int < 0x42600001 + 64):
        continue
    subprocess.run(["ip", "route", "replace", "default", "dev", iface, "table", str(tid)], check=False)
    for tip in (slot.get("throw_ips") or []):
        ip_s = str(ipaddress.IPv4Address(str(tip).strip()))
        subprocess.run(["ip", "route", "replace", "throw", f"{ip_s}/32", "table", str(tid)], check=False)
    if not any(ln.lstrip().startswith(f"{prio}:") for ln in rules_out.splitlines()):
        subprocess.run(["ip", "rule", "add", "priority", str(prio), "fwmark", f"0x{mark_int:08x}/0xffffffff", "lookup", str(tid)], check=False)
PY
    if [ -f /run/xforwarder/engine.pid ]; then
        kill -USR1 "\$(cat /run/xforwarder/engine.pid 2>/dev/null)" 2>/dev/null || true
    fi
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

# Verify peer over ESP tunnel; on failure use 2-stage recovery (soft SA reset first, interface restart only at 6+ fails)
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

    inst_cnt=0
    if command -v swanctl &>/dev/null; then
        inst_cnt=\$(swanctl --list-sas --ike "esp-tun-\${TUNNEL_ID}" 2>/dev/null | grep -c "INSTALLED" || true)
    fi
    [[ ! "\$inst_cnt" =~ ^[0-9]+$ ]] && inst_cnt=0

    if [ "\$fails" -ge 6 ]; then
        logger -t "\${TAG}" "Stage 2 recovery: restarting esp-tunnel-\${TUNNEL_ID} after \${fails} failed checks"
        systemctl restart "esp-tunnel-\${TUNNEL_ID}" || true
        echo 0 > "\${FAIL_FILE}"
    elif [ "\${ROLE}" = "iran" ] && command -v swanctl &>/dev/null; then
        logger -t "\${TAG}" "Stage 1 recovery (iran): resetting SA for esp-tun-\${TUNNEL_ID} (installed=\${inst_cnt})"
        if [ "\${inst_cnt}" -eq 0 ]; then
            swanctl --load-all >/dev/null 2>&1 || true
            swanctl --initiate --child "esp-tun-\${TUNNEL_ID}-child" --timeout 5 >/dev/null 2>&1 || true
        else
            swanctl --terminate --ike "esp-tun-\${TUNNEL_ID}" --timeout 3 >/dev/null 2>&1 || true
            swanctl --load-all >/dev/null 2>&1 || true
            swanctl --initiate --child "esp-tun-\${TUNNEL_ID}-child" --timeout 5 >/dev/null 2>&1 || true
        fi
    elif command -v swanctl &>/dev/null; then
        # Kharej: clear stale SA without deleting espN netdev (preserves XForwarder table 42600 routes)
        logger -t "\${TAG}" "Stage 1 recovery (kharej): soft-clearing SA for esp-tun-\${TUNNEL_ID} without deleting \${TUN_IF}"
        ip link set dev "\${TUN_IF}" up >/dev/null 2>&1 || true
        sysctl -w "net.ipv4.conf.\${TUN_IF}.rp_filter=0" >/dev/null 2>&1 || true
        swanctl --terminate --ike "esp-tun-\${TUNNEL_ID}" --timeout 3 >/dev/null 2>&1 || true
        swanctl --load-all >/dev/null 2>&1 || true
    else
        systemctl restart "esp-tunnel-\${TUNNEL_ID}" || true
        echo 0 > "\${FAIL_FILE}"
    fi
fi
WD
    chmod 755 "$script_path"
}

write_systemd_units() {
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
    systemctl enable "esp-tunnel-${tid}" "esp-keepalive-${tid}" "esp-watchdog-${tid}.timer" &>/dev/null || true
}

create_systemd_units() {
    local tid="$1" up_script="$2" down_script="$3" wd_script="$4" role_label="$5" remote_tun="$6"
    write_systemd_units "$tid" "$up_script" "$down_script" "$wd_script" "$role_label" "$remote_tun"
    if ! systemctl restart "esp-tunnel-${tid}"; then
        return 1
    fi
    systemctl restart "esp-keepalive-${tid}" || true
    systemctl restart "esp-watchdog-${tid}.timer" || true
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

    if [ -f "${SCRIPTS_DIR}/esp-up.sh" ] || [ -f "${SYSTEMD_DIR}/esp-tunnel-.service" ] || ip link show dev "esp" &>/dev/null; then
        msg_warn "Detected an unnumbered legacy/incomplete ESP tunnel ('esp') on this server."
        local clean_leg=""
        read -r -p "  Remove this unnumbered 'esp' tunnel before creating 'esp1'? (Y/n): " clean_leg
        if [[ ! "$clean_leg" =~ ^[Nn]$ ]]; then
            cleanup_unnumbered_legacy
        fi
    fi

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
    while true; do
        if [ "$role" = "iran" ]; then
            read_ip "Outside (Kharej) server public IPv4" "" remote_real
        else
            read_ip "Iran server public IPv4" "" remote_real
        fi
        if [ "$remote_real" = "$local_real" ]; then
            msg_err "Peer IP (${remote_real}) cannot be the same as this server's local IP!"
            continue
        fi
        break
    done

    local tun_if="esp${tid}"
    local free_sub
    free_sub=$(find_free_tunnel_subnet "10.87" "$tid")
    local custom_sub=""
    while true; do
        read_input "Tunnel /30 subnet prefix (Enter for ${free_sub}, or e.g. 10.250.51)" "$free_sub" custom_sub
        custom_sub=$(normalize_subnet_prefix "$custom_sub")
        if validate_subnet_prefix "$custom_sub"; then
            break
        fi
        msg_err "Invalid /24 prefix '${custom_sub}'. Example: ${free_sub} or 10.250.51"
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
    msg_ok "Subnet: ${custom_sub}.0/30 (Iran: ${custom_sub}.1 | Kharej: ${custom_sub}.2)"

    local tun_mtu=""
    read_mtu "XFRM interface MTU" "1400" tun_mtu

    echo ""
    msg_info "Forwarding integration mode:"
    echo -e "   ${GREEN}1)${NC} Pure ESP interface only — manage forwarding in XForwarder (Recommended)"
    echo -e "      (Use 'nftables_dsr_synack' on Iran and 'nftables_dsr_direct' on Outside)"
    echo -e "   ${CYAN}2)${NC} Standalone Direct-Return DSR rules in nftables (all-in-one without XForwarder)"
    local fmode="" dsr_mode="xforwarder" client_port="1036" backend_port="24443"
    read -r -p "  Select [1]: " fmode
    fmode=$(echo "${fmode:-1}" | tr -d '\r\n[:space:]')
    if [ "$fmode" = "2" ]; then
        dsr_mode="standalone"
        read_port "Public client TCP port on Iran" "1036" client_port
        read_port "Backend VPN TCP port on ${outside_tun_ip}" "24443" backend_port
    fi

    local psk_file="${ESP_CFG_DIR}/esp${tid}.psk"
    local psk_val="" psk_generated="0"
    read_or_generate_psk "$role" "$psk_file" psk_val psk_generated

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
    if ! create_systemd_units "$tid" "$up_script" "$down_script" "$wd_script" "$role_label" "$remote_tun"; then
        echo ""
        msg_err "ESP Tunnel ${tid} (${tun_if}) failed to start! Check: journalctl -xeu esp-tunnel-${tid}.service"
        return 1
    fi

    echo ""
    msg_ok "ESP Tunnel ${tid} (${tun_if}) configured and started!"
    if [ "$role" = "iran" ]; then
        echo ""
        print_double_line
        echo -e " ${YELLOW}${BOLD}Copy these settings to your Kharej server (Step 4):${NC}"
        echo -e "  Tunnel ID     : ${WHITE}${tid}${NC}"
        echo -e "  Subnet Prefix : ${WHITE}${custom_sub}${NC}"
        echo -e "  64-hex PSK    : ${YELLOW}${BOLD}${psk_val}${NC}"
        echo -e "  ${DIM}(Saved at ${psk_file}, chmod 600)${NC}"
        print_double_line
    else
        echo ""
        msg_info "Verifying ESP tunnel to Iran (${remote_tun})..."
        sleep 1
        if swanctl --list-sas --ike "esp-tun-${tid}" 2>/dev/null | grep -q "INSTALLED" && \
           ping -c 2 -W 1 -I "${tun_if}" "${remote_tun}" >/dev/null 2>&1; then
            msg_ok "ESP IPsec SA is INSTALLED and peer ${remote_tun} is reachable over ${tun_if}!"
        else
            msg_warn "Tunnel started; waiting for Iran to initiate or allow UDP 500 + IP Proto 50 (ESP)."
        fi
    fi
    if [ "$dsr_mode" = "xforwarder" ]; then
        echo ""
        msg_info "Next step in XForwarder Web UI:"
        if [ "$role" = "iran" ]; then
            echo -e "  Protocol: ${CYAN}tcp${NC} | Type: ${GREEN}NFTables DSR (SYN-ACK · Iran)${NC} | Target: ${YELLOW}${outside_tun_ip}${NC} | Tunnel Iface: ${CYAN}${tun_if}${NC} | Spoof IP: ${WHITE}${local_real}${NC}"
        else
            echo -e "  Protocol: ${CYAN}tcp${NC} | Type: ${GREEN}NFTables DSR (Direct · Outside)${NC} | Target: ${YELLOW}${outside_tun_ip}${NC} | Ingress Iface: ${CYAN}${tun_if}${NC} | Spoof IP: ${WHITE}${remote_real}${NC}"
        fi
    fi
}

setup_iran()   { setup_role "iran"; }
setup_kharej() { setup_role "kharej"; }

# ─── Management & Inspection ──────────────────────────────────────
cleanup_unnumbered_legacy() {
    systemctl stop "esp-watchdog-.timer" "esp-keepalive-" "esp-tunnel-" &>/dev/null || true
    systemctl disable "esp-watchdog-.timer" "esp-keepalive-" "esp-tunnel-" &>/dev/null || true
    rm -f "${SYSTEMD_DIR}/esp-tunnel-.service" \
          "${SYSTEMD_DIR}/esp-keepalive-.service" \
          "${SYSTEMD_DIR}/esp-watchdog-.service" \
          "${SYSTEMD_DIR}/esp-watchdog-.timer"
    rm -f "${SCRIPTS_DIR}/esp-up.sh" \
          "${SCRIPTS_DIR}/esp-down.sh" \
          "${SCRIPTS_DIR}/esp-watchdog.sh"
    if command -v swanctl &>/dev/null && systemctl is-active --quiet strongswan; then
        swanctl --terminate --ike "esp-tun-" --timeout 2 >/dev/null 2>&1 || true
        swanctl --unload-conn --name "esp-tun-" >/dev/null 2>&1 || true
    fi
    rm -f "${SWANCTL_DIR}/esp-tun-.conf" "${ESP_CFG_DIR}/esp.psk" "${STATE_DIR}/esp."*
    nft delete table ip "esp_dsr_" 2>/dev/null || true
    ip link set dev "esp" down 2>/dev/null || true
    ip link del dev "esp" 2>/dev/null || true
    systemctl daemon-reload
    msg_ok "Cleaned up unnumbered legacy 'esp' tunnel."
}

list_unmanaged_xfrm_ifaces() {
    local dev
    for dev in /sys/class/net/*; do
        [ -e "$dev" ] || continue
        local ifn
        ifn=$(basename "$dev")
        [[ "$ifn" =~ ^esp[0-9]+$ ]] && [ -f "${SCRIPTS_DIR}/${ifn}-up.sh" ] && continue
        local kind=""
        kind=$(ip -j -d link show dev "$ifn" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin)[0].get('linkinfo',{}); print(d.get('info_kind',''))" 2>/dev/null || true)
        if [ "$kind" = "xfrm" ]; then
            local ips
            ips=$(ip -4 -o addr show dev "$ifn" 2>/dev/null | awk '{print $4}' | tr '\n' ' ')
            echo "  ${ifn} [kernel xfrm, unmanaged by numbered ID] | IP: ${ips:-none}"
        fi
    done
}

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
    local has_legacy=0
    [ -f "${SCRIPTS_DIR}/esp-up.sh" ] && has_legacy=1
    local extra_xfrm=""
    extra_xfrm=$(list_unmanaged_xfrm_ifaces)

    if [ ${#ids[@]} -eq 0 ] && [ "$has_legacy" -eq 0 ] && [ -z "$extra_xfrm" ]; then
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
    if [ "$has_legacy" -eq 1 ]; then
        up_f="${SCRIPTS_DIR}/esp-up.sh"
        role=$(extract_up_var "ROLE" "$up_f")
        lt=$(extract_up_var "LOCAL_TUN" "$up_f")
        rt=$(extract_up_var "REMOTE_TUN" "$up_f")
        echo -e "  ${YELLOW}ID legacy (esp)${NC} | Role: ${CYAN}${role}${NC} | ${lt} -> ${rt} | ${YELLOW}(unnumbered - use Delete option with 'legacy' to clean)${NC}"
    fi
    if [ -n "$extra_xfrm" ]; then
        echo ""
        echo -e " ${DIM}Kernel XFRM interfaces:${NC}"
        echo -e "${CYAN}${extra_xfrm}${NC}"
    fi
}

do_dashboard() {
    print_header
    echo -e " ${BOLD}${WHITE}ESP / XFRM Tunnels Dashboard${NC}"
    print_double_line
    local ids
    mapfile -t ids < <(get_all_tunnel_ids)
    local extra_xfrm=""
    extra_xfrm=$(list_unmanaged_xfrm_ifaces)
    if [ ${#ids[@]} -eq 0 ] && [ ! -f "${SCRIPTS_DIR}/esp-up.sh" ] && [ -z "$extra_xfrm" ]; then
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
    if [ -n "$extra_xfrm" ]; then
        echo ""
        echo -e " ${YELLOW}Other kernel XFRM interfaces:${NC}"
        echo -e "${CYAN}${extra_xfrm}${NC}"
    fi
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
    local _stid_var="$1"
    local _stid=""
    list_tunnels
    echo ""
    read_input "Enter Tunnel ID" "" _stid
    _stid=$(echo "$_stid" | tr -d '\r\n[:space:]')
    if [[ ! "$_stid" =~ ^[0-9]+$ ]] || [ ! -f "${SCRIPTS_DIR}/esp${_stid}-up.sh" ]; then
        msg_err "Tunnel ID '${_stid}' not found."
        return 1
    fi
    printf -v "$_stid_var" "%s" "$_stid"
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
    list_tunnels
    echo ""
    local id=""
    read_input "Enter Tunnel ID to delete (or 'legacy' for unnumbered esp)" "" id
    id=$(echo "$id" | tr -d '\r\n[:space:]')
    if [ "$id" = "legacy" ] || [ "$id" = "esp" ]; then
        if [ -f "${SCRIPTS_DIR}/esp-up.sh" ] || ip link show dev "esp" &>/dev/null; then
            local ans=""
            read -r -p "  Delete unnumbered legacy 'esp' tunnel? (y/N): " ans
            [[ ! "$ans" =~ ^[Yy]$ ]] && { msg_warn "Canceled."; return 0; }
            cleanup_unnumbered_legacy
            return 0
        fi
        msg_err "No legacy 'esp' tunnel found."
        return 1
    fi
    if [[ ! "$id" =~ ^[0-9]+$ ]] || [ ! -f "${SCRIPTS_DIR}/esp${id}-up.sh" ]; then
        msg_err "Tunnel ID '${id}' not found."
        return 1
    fi
    local ans=""
    read -r -p "  Permanently delete ESP tunnel esp${id} and its config/PSK? (y/N): " ans
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

upgrade_single_tunnel() {
    local tid="$1"
    local up_f="${SCRIPTS_DIR}/esp${tid}-up.sh"
    local down_f="${SCRIPTS_DIR}/esp${tid}-down.sh"
    local wd_f="${SCRIPTS_DIR}/esp${tid}-watchdog.sh"
    local swan_f="${SWANCTL_DIR}/esp-tun-${tid}.conf"
    local psk_f="${ESP_CFG_DIR}/esp${tid}.psk"

    if [ ! -f "$up_f" ]; then
        msg_warn "Skipping esp${tid}: ${up_f} not found."
        return 1
    fi

    local role tun_if if_wan local_real remote_real local_tun remote_tun
    local tun_mtu if_id reqid dsr_mode client_port backend_port route_table rule_prio route_mark
    role=$(extract_up_var "ROLE" "$up_f")
    tun_if=$(extract_up_var "TUN_IF" "$up_f")
    if_wan=$(extract_up_var "IF_WAN" "$up_f")
    local_real=$(extract_up_var "LOCAL_REAL" "$up_f")
    remote_real=$(extract_up_var "REMOTE_REAL" "$up_f")
    local_tun=$(extract_up_var "LOCAL_TUN" "$up_f")
    remote_tun=$(extract_up_var "REMOTE_TUN" "$up_f")
    tun_mtu=$(extract_up_var "TUN_MTU" "$up_f")
    if_id=$(extract_up_var "IF_ID" "$up_f")
    reqid=$(extract_up_var "REQ_ID" "$up_f")
    dsr_mode=$(extract_up_var "DSR_MODE" "$up_f")
    client_port=$(extract_up_var "CLIENT_PORT" "$up_f")
    backend_port=$(extract_up_var "BACKEND_PORT" "$up_f")
    route_table=$(extract_up_var "ROUTE_TABLE" "$up_f")
    rule_prio=$(extract_up_var "RULE_PRIORITY" "$up_f")
    route_mark=$(extract_up_var "ROUTE_MARK" "$up_f")

    [ -z "$tun_if" ] && tun_if="esp${tid}"
    [ -z "$if_wan" ] && { if_wan=$(detect_default_iface); [ -z "$if_wan" ] && if_wan="eth0"; }
    [ -z "$remote_tun" ] && [ -n "$local_tun" ] && remote_tun=$(derive_remote_tun_from_local "$local_tun")
    [ -z "$tun_mtu" ] && tun_mtu="1400"
    [ -z "$if_id" ] && if_id=$(printf '0x%x' $((0x4250 + tid)))
    [ -z "$reqid" ] && reqid=$((4251000 + tid))
    [ -z "$dsr_mode" ] && dsr_mode="xforwarder"
    [ -z "$client_port" ] && client_port="1036"
    [ -z "$backend_port" ] && backend_port="24443"
    [ -z "$route_table" ] && route_table=$((42500 + tid))
    [ -z "$rule_prio" ] && rule_prio=$((12500 + tid))
    [ -z "$route_mark" ] && route_mark=$(printf '0x%08x' $((0x42510000 + tid)))

    if [ -z "$role" ] || [ -z "$local_real" ] || [ -z "$remote_real" ] || [ -z "$local_tun" ] || [ -z "$remote_tun" ]; then
        msg_err "Skipping esp${tid}: missing core variables in ${up_f}."
        return 1
    fi

    local psk_val=""
    if [ -f "$psk_f" ]; then
        psk_val=$(tr -d '\r\n[:space:]' < "$psk_f" 2>/dev/null || true)
    fi
    if [ -z "$psk_val" ] && [ -f "$swan_f" ]; then
        psk_val=$(grep -E '^[[:space:]]*secret[[:space:]]*=' "$swan_f" 2>/dev/null | head -1 | sed -E 's/^[^=]+=[[:space:]]*(0x)?//; s/[[:space:]]+$//' | tr -d '\r\n"'\''')
        if [[ "$psk_val" =~ ^[0-9a-fA-F]{64}$ ]]; then
            mkdir -p -m 700 "${ESP_CFG_DIR}"
            umask 077
            printf '%s\n' "$psk_val" > "$psk_f"
            chmod 600 "$psk_f"
        fi
    fi
    if [ -z "$psk_val" ]; then
        msg_err "Skipping esp${tid}: PSK not found in ${psk_f} or ${swan_f}."
        return 1
    fi

    local outside_tun_ip="$remote_tun"
    [ "$role" = "kharej" ] && outside_tun_ip="${local_tun%/*}"
    local role_label="Iran"
    [ "$role" = "kharej" ] && role_label="Kharej (Outside)"

    local was_active=0
    if systemctl is-active --quiet "esp-tunnel-${tid}" || ip link show "$tun_if" &>/dev/null; then
        [ ! -f "${STATE_DIR}/${tun_if}.stopped" ] && was_active=1
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

    generate_swanctl_conf "$tid" "$role" "$local_real" "$remote_real" "$outside_tun_ip" "$if_id" "$reqid" "$psk_val"
    generate_esp_up "$up_f"
    generate_esp_down "$down_f"
    generate_watchdog "$wd_f"
    write_systemd_units "$tid" "$up_f" "$down_f" "$wd_f" "$role_label" "$remote_tun"

    if [ "$was_active" -eq 1 ]; then
        rm -f "${STATE_DIR}/${tun_if}.fails" "${STATE_DIR}/${tun_if}.cooldown"
        if ip link show "$tun_if" &>/dev/null; then
            if command -v swanctl &>/dev/null && systemctl is-active --quiet strongswan; then
                # Terminate old IKE_SA first so single up-script run loads new parameters cleanly
                swanctl --terminate --ike "esp-tun-${tid}" --timeout 3 >/dev/null 2>&1 || true
            fi
            # Re-run up-script to reconcile XForwarder routes, reload swanctl config, and initiate once without deleting espN
            if ! bash "$up_f" >/dev/null 2>&1; then
                msg_warn "Warning: re-applying ${up_f} returned non-zero."
            fi
        else
            systemctl restart "esp-tunnel-${tid}" || true
        fi
        systemctl restart "esp-keepalive-${tid}" || true
        systemctl restart "esp-watchdog-${tid}.timer" || true
    fi

    msg_ok "Upgraded esp${tid} (${role}, ${dsr_mode}): replay_window=1024, unique=replace, smart watchdog, XForwarder route sync."
    return 0
}

do_upgrade_tunnels() {
    echo ""
    print_double_line
    echo -e " ${CYAN}${BOLD}Upgrade Existing ESP Tunnels to v${VERSION}${NC}"
    print_line
    msg_info "Preserves all IPs, subnets, ports, and PSKs while applying:"
    echo -e "   - ${GREEN}replay_window = 1024${NC} (fixes XfrmInStateSeqError packet drops)"
    echo -e "   - ${GREEN}unique = replace${NC} + ${GREEN}rekey_time = 2h${NC} + clean single CHILD_SA"
    echo -e "   - ${GREEN}Smart 2-stage watchdog${NC} (avoids deleting espN netdev on Kharej)"
    echo -e "   - ${GREEN}XForwarder DSR Direct sync${NC} (restores table 42600+ routes immediately)"
    echo -e "   - ${GREEN}Sysctl conflict fix${NC} (removes legacy 99-xmanager-tunnel.conf)"
    print_line

    persist_sysctl_tuning
    local def_wan
    def_wan=$(detect_default_iface)
    [ -z "$def_wan" ] && def_wan="eth0"
    apply_live_nic_tuning "$def_wan"
    ensure_charon_no_routes

    local ids
    mapfile -t ids < <(get_all_tunnel_ids)
    if [ ${#ids[@]} -eq 0 ]; then
        msg_warn "No numbered ESP tunnels found to upgrade."
        if [ -f "${SCRIPTS_DIR}/esp-up.sh" ]; then
            msg_warn "Found unnumbered legacy 'esp' tunnel; recreate it with option 3/4 after cleaning."
        fi
        return 0
    fi

    local tid ok_cnt=0 fail_cnt=0
    for tid in "${ids[@]}"; do
        if upgrade_single_tunnel "$tid"; then
            ok_cnt=$(( ok_cnt + 1 ))
        else
            fail_cnt=$(( fail_cnt + 1 ))
        fi
    done

    echo ""
    if [ "$fail_cnt" -eq 0 ]; then
        msg_ok "Upgraded ${ok_cnt} tunnel(s) cleanly! Note: run --upgrade on BOTH Iran and Kharej servers for full effect."
    else
        msg_warn "Upgraded ${ok_cnt} tunnel(s), ${fail_cnt} skipped/failed."
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
        echo -e " ${BOLD}${WHITE}Install, Tuning & Upgrade${NC}"
        echo -e "  ${MAGENTA}16)${NC} Install Prerequisites (strongSwan / nftables)"
        echo -e "  ${GREEN}17)${NC} Optimize Kernel & Network (BBR / fq / rp_filter=0)"
        echo -e "  ${YELLOW}18)${NC} Upgrade / Update Existing Tunnels (Apply Fixes)"
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
            18) do_upgrade_tunnels ;;
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

if [ "${1:-}" = "--upgrade" ] || [ "${1:-}" = "upgrade" ]; then
    do_upgrade_tunnels
    exit 0
fi

main_menu
