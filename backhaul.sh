#!/bin/bash

# ╔════════════════════════════════════════════════════════════════╗
# ║  BACKHAUL TUNNEL SETUP - TUN/IPX Mode v2.0                   ║
# ║  Iran (Server) & Kharej (Client) Setup Script                ║
# ╚════════════════════════════════════════════════════════════════╝

SCRIPT_VERSION="2.0"

# ─── Colors ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────
CORE_DIR="/root/backhaul-core"
BINARY_PATH="${CORE_DIR}/backhaul_premium"
SYSTEMD_DIR="/etc/systemd/system"

# ─── Default PSK (fixed across all tunnels, can be overridden) ───
DEFAULT_PSK="pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4="

# ─── Helpers ──────────────────────────────────────────────────────

print_line() {
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
}

print_double_line() {
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
}

print_header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo " ╔════════════════════════════════════════════════╗"
    echo " ║     BACKHAUL TUNNEL SETUP - TUN/IPX v2.0       ║"
    echo " ╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
    if [ -f "${BINARY_PATH}" ] && [ -x "${BINARY_PATH}" ]; then
        echo -e "  ${DIM}Binary Status:${NC} ${GREEN}●${NC} ${GREEN}Installed${NC} ${DIM}(${BINARY_PATH})${NC}"
    else
        echo -e "  ${DIM}Binary Status:${NC} ${RED}●${NC} ${YELLOW}Not Found${NC} ${DIM}(Use option 19 to download)${NC}"
    fi
    echo ""
}

msg_info() {
    echo -e " ${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e " ${GREEN}[OK]${NC} $1"
}

msg_warn() {
    echo -e " ${YELLOW}[WARN]${NC} $1"
}

msg_err() {
    echo -e " ${RED}[ERR]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        msg_err "This script must be run as root."
        exit 1
    fi
}

check_binary() {
    if [ ! -f "${BINARY_PATH}" ]; then
        return 1
    fi
    if [ ! -x "${BINARY_PATH}" ]; then
        chmod +x "${BINARY_PATH}"
    fi
    return 0
}

# ─── Download Binary ───────────────────────────────────────────

download_binary() {
    echo ""
    echo -e " ${GREEN}${BOLD}>>> Download Backhaul Premium Binary${NC}"
    print_line
    echo ""
    echo -e "  ${WHITE}1)${NC} Download from ${BLUE}GitHub Mirror${NC}  ${DIM}(github.com/alireza-2030 — direct binary)${NC}"
    echo -e "  ${DIM}0)${NC} Cancel"
    echo ""
    read -p "  Select (1 or 0): " mirror_choice

    mkdir -p "${CORE_DIR}"

    case $mirror_choice in
        1)
            # GitHub mirror — direct binary
            local url="https://raw.githubusercontent.com/alireza-2030/backhaul-manager/main/backhaul-final/dist/backhaul_premium"
            msg_info "Downloading: ${url}"
            echo ""
            if curl -L --max-time 60 --progress-bar -o "${BINARY_PATH}" "${url}"; then
                local fsize=$(stat -c%s "${BINARY_PATH}" 2>/dev/null || stat -f%z "${BINARY_PATH}" 2>/dev/null)
                if [ "${fsize:-0}" -gt 1000000 ]; then
                    chmod +x "${BINARY_PATH}"
                    msg_ok "Binary installed: ${BINARY_PATH}"
                else
                    msg_err "Downloaded file is too small, download may have failed."
                    rm -f "${BINARY_PATH}" 2>/dev/null
                fi
            else
                msg_err "Download failed."
            fi
            ;;
        0) return ;;
        *) msg_err "Invalid option."; return ;;
    esac
}

# ─── Auto-Detect Network Interface ───────────────────────────────

detect_interface() {
    # Try to find the default route interface
    local iface=""
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)

    if [ -z "$iface" ]; then
        # Fallback: first non-lo interface that is UP
        iface=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1)
    fi

    if [ -z "$iface" ]; then
        iface="eth0"
    fi

    echo "$iface"
}

# ─── Auto-Detect Public IP ────────────────────────────────────────

detect_public_ip() {
    local ip=""
    local iface
    iface=$(detect_interface)

    # Try to get IP from the default interface
    if [ -n "$iface" ]; then
        ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    fi

    # Fallback: hostname -I
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    # Fallback: any non-lo IP
    if [ -z "$ip" ]; then
        ip=$(ip -4 addr show 2>/dev/null | grep -oP 'inet \K[0-9.]+' | grep -v '^127\.' | head -1)
    fi

    echo "$ip"
}

# ─── IP Validation Helper ────────────────────────────────────────

is_valid_ipv4() {
    local ip="$1"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ ! $ip =~ $regex ]]; then
        return 1
    fi
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    if [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ]; then
        return 0
    fi
    return 1
}

# ─── Duplicate Tunnel ID Checker ─────────────────────────────────

get_tunnel_conflict() {
    local tid="$1"
    # Check existing TOML configs in CORE_DIR
    if [ -d "${CORE_DIR}" ]; then
        for cfg in "${CORE_DIR}"/*.toml; do
            [ -f "$cfg" ] || continue
            # Check local_addr / remote_addr for 10.10.<tid>.
            if grep -qE "10\.10\.${tid}\.[0-9]+" "$cfg" 2>/dev/null; then
                basename "$cfg"
                return 0
            fi
            # Check tun name
            if grep -qE "name\s*=\s*\"(backhaul|back)${tid}\"" "$cfg" 2>/dev/null; then
                basename "$cfg"
                return 0
            fi
        done
    fi

    # Check systemd services
    local default_hp=$((1000 + 10#$tid))
    if [ -f "${SYSTEMD_DIR}/backhaul-iran${default_hp}.service" ]; then
        echo "backhaul-iran${default_hp}.service"
        return 0
    elif [ -f "${SYSTEMD_DIR}/backhaul-kharej${default_hp}.service" ]; then
        echo "backhaul-kharej${default_hp}.service"
        return 0
    fi

    return 0
}

# ─── Input Helpers ────────────────────────────────────────────────

read_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"

    if [ -n "$default" ]; then
        read -p "  ${prompt} [${default}]: " input_val
        printf -v "$var_name" "%s" "${input_val:-$default}"
    else
        read -p "  ${prompt}: " input_val
        printf -v "$var_name" "%s" "${input_val}"
    fi
}

# ─── Review Box ───────────────────────────────────────────────────

show_review_box() {
    local mode="$1"  # iran or kharej

    echo ""
    print_double_line
    echo -e " ${WHITE}${BOLD}  REVIEW YOUR SETTINGS${NC}"
    print_double_line
    echo ""
    echo -e "  ${MAGENTA}Tunnel ID:${NC}       ${WHITE}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "  ${MAGENTA}Tunnel Name:${NC}     ${WHITE}${BOLD}${TUN_NAME}${NC}"
    echo -e "  ${MAGENTA}Health Port:${NC}     ${WHITE}${BOLD}${HEALTH_PORT}${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}TUN Network:${NC}"
    if [ "$mode" = "iran" ]; then
        echo -e "    Local  (Iran):   ${GREEN}${BOLD}10.10.${TUNNEL_ID}.1/24${NC}"
        echo -e "    Remote (Kharej): ${BLUE}${BOLD}10.10.${TUNNEL_ID}.2/24${NC}"
    else
        echo -e "    Local  (Kharej): ${GREEN}${BOLD}10.10.${TUNNEL_ID}.2/24${NC}"
        echo -e "    Remote (Iran):   ${BLUE}${BOLD}10.10.${TUNNEL_ID}.1/24${NC}"
    fi
    echo -e "    MTU:             ${WHITE}${MTU}${NC}"
    echo ""
    print_line
    echo -e "  ${CYAN}IPX Network:${NC}"
    echo -e "    Listen IP:       ${GREEN}${BOLD}${LISTEN_IP}${NC}"
    echo -e "    Dest IP:         ${BLUE}${BOLD}${DST_IP}${NC}"
    echo -e "    Profile:         ${YELLOW}${BOLD}${PROFILE}${NC}"
    echo -e "    Interface:       ${WHITE}${BOLD}${INTERFACE}${NC}  ${DIM}(auto-detected)${NC}"
    echo -e "    Mode:            ${YELLOW}${BOLD}$([ \"$mode\" = \"iran\" ] && echo 'server' || echo 'client')${NC}"
    if [ "$PROFILE" = "udp" ] || [ "$PROFILE" = "tcp" ] || [ "$PROFILE" = "icmp" ]; then
        if [ -n "$SPOOF_SRC_IP" ] || [ -n "$SPOOF_DST_IP" ]; then
            echo ""
            print_line
            echo -e "  ${CYAN}Spoof:${NC}"
            [ -n "$SPOOF_SRC_IP" ] && echo -e "    Spoof Src IP:    ${MAGENTA}${BOLD}${SPOOF_SRC_IP}${NC}"
            [ -n "$SPOOF_DST_IP" ] && echo -e "    Spoof Dst IP:    ${MAGENTA}${BOLD}${SPOOF_DST_IP}${NC}"
        fi
    fi
    echo ""
    print_line
    echo -e "  ${CYAN}Security:${NC}"
    echo -e "    Encryption:      ${WHITE}${ENCRYPTION}${NC}"
    if [ "$ENCRYPTION" = "true" ]; then
        echo -e "    Algorithm:       ${WHITE}${ALGORITHM}${NC}"
        echo -e "    PSK:             ${YELLOW}${BOLD}${PSK}${NC}"
        echo -e "    KDF Iterations:  ${WHITE}${KDF_ITERATIONS}${NC}"
    fi
    echo ""
    print_line
    echo -e "  ${CYAN}Transport & Tuning:${NC}"
    echo -e "    Heartbeat:       ${WHITE}${HEARTBEAT_INTERVAL}s interval / ${HEARTBEAT_TIMEOUT}s timeout${NC}"
    echo -e "    Tuning Profile:  ${YELLOW}${BOLD}${TUNING_PROFILE}${NC}"
    echo -e "    Workers:         ${WHITE}${WORKERS}${NC}"
    echo -e "    Channel Size:    ${WHITE}60000${NC}"
    echo -e "    Batch Size:      ${WHITE}4096${NC}"
    echo -e "    Log Level:       ${WHITE}${LOG_LEVEL}${NC}"
    echo ""
    print_double_line
    echo ""
}

# ─── Config Generators ───────────────────────────────────────────

generate_iran_config() {
    local config_file="$1"
    cat > "${config_file}" << EOF
[transport]
type = "tun"
heartbeat_interval = ${HEARTBEAT_INTERVAL}
heartbeat_timeout = ${HEARTBEAT_TIMEOUT}

[tun]
encapsulation = "ipx"
name = "${TUN_NAME}"
local_addr = "${LOCAL_TUN_ADDR}"
remote_addr = "${REMOTE_TUN_ADDR}"
health_port = ${HEALTH_PORT}
mtu = ${MTU}

[ipx]
mode = "server"
profile = "${PROFILE}"
listen_ip = "${LISTEN_IP}"
dst_ip = "${DST_IP}"
${SPOOF_BLOCK}interface = "${INTERFACE}"

[security]
enable_encryption = ${ENCRYPTION}
algorithm = "${ALGORITHM}"
psk = "${PSK}"
kdf_iterations = ${KDF_ITERATIONS}

[tuning]
auto_tuning = true
tuning_profile = "${TUNING_PROFILE}"
workers = ${WORKERS}
channel_size = 60000
so_sndbuf = 0
batch_size = 4096

[logging]
log_level = "${LOG_LEVEL}"

[ports]
forwarder = "backhaul"
mapping = [
]
EOF
}

generate_kharej_config() {
    local config_file="$1"
    cat > "${config_file}" << EOF
[transport]
type = "tun"
heartbeat_interval = ${HEARTBEAT_INTERVAL}
heartbeat_timeout = ${HEARTBEAT_TIMEOUT}

[tun]
encapsulation = "ipx"
name = "${TUN_NAME}"
local_addr = "${LOCAL_TUN_ADDR}"
remote_addr = "${REMOTE_TUN_ADDR}"
health_port = ${HEALTH_PORT}
mtu = ${MTU}

[ipx]
mode = "client"
profile = "${PROFILE}"
listen_ip = "${LISTEN_IP}"
dst_ip = "${DST_IP}"
${SPOOF_BLOCK}interface = "${INTERFACE}"

[security]
enable_encryption = ${ENCRYPTION}
algorithm = "${ALGORITHM}"
psk = "${PSK}"
kdf_iterations = ${KDF_ITERATIONS}

[tuning]
auto_tuning = true
tuning_profile = "${TUNING_PROFILE}"
workers = ${WORKERS}
channel_size = 60000
so_sndbuf = 0
batch_size = 4096

[logging]
log_level = "${LOG_LEVEL}"
EOF
}

create_systemd_service() {
    local service_name="$1"
    local config_file="$2"
    local description="$3"
    local service_path="${SYSTEMD_DIR}/${service_name}.service"

    cat > "${service_path}" << EOF
[Unit]
Description=Backhaul Premium Tunnel - Optimized v${SCRIPT_VERSION} (${description})
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CORE_DIR}
ExecStart=${BINARY_PATH} -c ${config_file}

# Reliability and survival mechanism
Restart=always
RestartSec=3

# Kernel and OS performance tuning for high load
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

# Logging configuration
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}" &>/dev/null
    systemctl start "${service_name}"
}

# ─── Setup Functions ─────────────────────────────────────────────

ensure_setup_prerequisites() {
    # Check binary
    if [ ! -f "${BINARY_PATH}" ]; then
        msg_warn "Backhaul binary not found at ${BINARY_PATH}."
        read -p "  Would you like to download it now? (Y/n): " dl_confirm
        if [[ ! "$dl_confirm" =~ ^[Nn]$ ]]; then
            download_binary
            if [ ! -f "${BINARY_PATH}" ]; then
                msg_err "Binary is required to continue setup."
                return 1
            fi
        else
            msg_err "Cannot proceed without Backhaul binary."
            return 1
        fi
    fi

    # Enable IPv4 forwarding for TUN mode if not already active
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 &>/dev/null
        if [ -f /etc/sysctl.conf ] && ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
            echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf 2>/dev/null
        fi
        msg_ok "Kernel IP forwarding enabled."
    fi

    return 0
}

setup_iran() {
    print_header
    echo -e " ${GREEN}${BOLD}>>> Setup Iran Server (IPX Server Mode)${NC}"
    echo ""
    print_line

    ensure_setup_prerequisites || return

    # Auto-detect interface
    INTERFACE=$(detect_interface)

    # Auto-detect public IP for listen_ip default
    local AUTO_IP
    AUTO_IP=$(detect_public_ip)

    # ── Step 1: Tunnel Identity ──
    echo -e "\n ${MAGENTA}${BOLD}[1/5] Tunnel Identity${NC}"
    while true; do
        read_input "Tunnel ID (e.g. 10, 12, 50)" "" TUNNEL_ID
        if [[ "$TUNNEL_ID" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$TUNNEL_ID" ]; then
            msg_err "Tunnel ID cannot be empty!"
        elif ! [[ "$TUNNEL_ID" =~ ^[0-9]+$ ]] || [ "$TUNNEL_ID" -le 0 ] || [ "$TUNNEL_ID" -gt 254 ]; then
            msg_err "Tunnel ID must be a number between 1 and 254."
        else
            local conflict
            conflict=$(get_tunnel_conflict "$TUNNEL_ID")
            if [ -n "$conflict" ]; then
                msg_err "Tunnel ID '${TUNNEL_ID}' is already in use by '${conflict}'! Please choose a different ID."
            else
                break
            fi
        fi
    done
    read_input "Tunnel name" "backhaul${TUNNEL_ID}" TUN_NAME

    local default_health_port="1001"
    if [[ "$TUNNEL_ID" =~ ^[0-9]+$ ]]; then
        default_health_port=$((1000 + 10#$TUNNEL_ID))
    fi
    while true; do
        read_input "Health port" "${default_health_port}" HEALTH_PORT
        if [[ "$HEALTH_PORT" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$HEALTH_PORT" ] || ! [[ "$HEALTH_PORT" =~ ^[0-9]+$ ]] || [ "$HEALTH_PORT" -le 0 ] || [ "$HEALTH_PORT" -gt 65535 ]; then
            msg_err "Health port must be a valid port number (1-65535)."
        elif [ -f "${CORE_DIR}/iran${HEALTH_PORT}.toml" ] || [ -f "${CORE_DIR}/kharej${HEALTH_PORT}.toml" ]; then
            msg_err "Health port ${HEALTH_PORT} is already in use by an existing config! Please choose a different port."
        else
            break
        fi
    done
    read_input "MTU" "1320" MTU

    # Auto-generate TUN addresses from ID
    LOCAL_TUN_ADDR="10.10.${TUNNEL_ID}.1/24"
    REMOTE_TUN_ADDR="10.10.${TUNNEL_ID}.2/24"

    # ── Step 2: IPX Network ──
    echo -e "\n ${MAGENTA}${BOLD}[2/5] IPX Network${NC}"
    msg_info "Interface auto-detected: ${BOLD}${INTERFACE}${NC}"
    read_input "Change interface? (press Enter to keep)" "${INTERFACE}" INTERFACE
    if [ -n "$AUTO_IP" ]; then
        msg_info "Public IP auto-detected: ${BOLD}${AUTO_IP}${NC}"
    fi
    while true; do
        read_input "Listen IP (this server's public IP)" "${AUTO_IP}" LISTEN_IP
        if [[ "$LISTEN_IP" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$LISTEN_IP" ]; then
            msg_err "Listen IP cannot be empty!"
        elif ! is_valid_ipv4 "$LISTEN_IP"; then
            msg_err "Invalid IP format '${LISTEN_IP}'. Please enter a valid IPv4 address."
        else
            break
        fi
    done

    while true; do
        read_input "Destination IP (Kharej public IP)" "" DST_IP
        if [[ "$DST_IP" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$DST_IP" ]; then
            msg_err "Destination IP cannot be empty!"
        elif ! is_valid_ipv4 "$DST_IP"; then
            msg_err "Invalid IP format '${DST_IP}'. Please enter a valid IPv4 address (e.g. 185.129.116.237)."
        else
            break
        fi
    done

    # ── Step 3: Profile (BIP or Spoof Protocols) ──
    echo -e "\n ${MAGENTA}${BOLD}[3/5] IPX Profile${NC}"
    echo -e "  ${WHITE}1)${NC} bip"
    echo -e "  ${WHITE}2)${NC} udp"
    echo -e "  ${WHITE}3)${NC} tcp  ${DIM}(default)${NC}"
    echo -e "  ${WHITE}4)${NC} icmp"
    read_input "Select profile (1, 2, 3 or 4)" "3" PROFILE_CHOICE
    if [ "$PROFILE_CHOICE" = "2" ] || [ "$PROFILE_CHOICE" = "3" ] || [ "$PROFILE_CHOICE" = "4" ]; then
        if [ "$PROFILE_CHOICE" = "2" ]; then
            PROFILE="udp"
        elif [ "$PROFILE_CHOICE" = "3" ]; then
            PROFILE="tcp"
        else
            PROFILE="icmp"
        fi
        read_input "Spoof Source IP (optional, Enter to skip)" "" SPOOF_SRC_IP
        read_input "Spoof Destination IP (optional, Enter to skip)" "" SPOOF_DST_IP

        local _src_line=""
        local _dst_line=""
        [ -n "$SPOOF_SRC_IP" ] && printf -v _src_line 'spoof_src_ip = "%s"\n' "${SPOOF_SRC_IP}"
        [ -n "$SPOOF_DST_IP" ] && printf -v _dst_line 'spoof_dst_ip = "%s"\n' "${SPOOF_DST_IP}"
        SPOOF_BLOCK="${_src_line}${_dst_line}"
    else
        PROFILE="bip"
        SPOOF_SRC_IP=""
        SPOOF_DST_IP=""
        SPOOF_BLOCK=""
    fi

    # ── Step 4: Security ──
    echo -e "\n ${MAGENTA}${BOLD}[4/5] Security${NC}"
    read_input "Enable encryption (true/false)" "false" ENCRYPTION
    if [[ "$ENCRYPTION" =~ ^([Tt]|true|TRUE|1|[Yy]|yes|YES)$ ]]; then
        ENCRYPTION="true"
        read_input "Algorithm" "aes-256-gcm" ALGORITHM
        echo -e "  ${DIM}Default PSK: ${DEFAULT_PSK}${NC}"
        read_input "PSK (Enter to use default)" "${DEFAULT_PSK}" PSK
        read_input "KDF iterations" "100000" KDF_ITERATIONS
    else
        ENCRYPTION="false"
        ALGORITHM="aes-256-gcm"
        PSK="${DEFAULT_PSK}"
        KDF_ITERATIONS="100000"
    fi

    # ── Step 5: Transport & Tuning ──
    echo -e "\n ${MAGENTA}${BOLD}[5/5] Transport & Tuning${NC}"
    HEARTBEAT_INTERVAL="10"
    HEARTBEAT_TIMEOUT="25"

    local default_workers
    default_workers=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    if [ -z "$default_workers" ] || [ "$default_workers" -lt 1 ]; then
        default_workers=1
    fi
    read_input "Workers count" "${default_workers}" WORKERS
    if [ -z "$WORKERS" ] || ! [[ "$WORKERS" =~ ^[0-9]+$ ]]; then
        WORKERS="${default_workers}"
    fi

    echo -e "  Tuning Profile:"
    echo -e "    ${WHITE}1)${NC} balanced"
    echo -e "    ${WHITE}2)${NC} fast  ${DIM}(default)${NC}"
    read_input "Select tuning profile (1 or 2)" "2" TUNING_CHOICE
    if [ "$TUNING_CHOICE" = "1" ]; then
        TUNING_PROFILE="balanced"
    else
        TUNING_PROFILE="fast"
    fi
    LOG_LEVEL="info"

    # ── Review ──
    show_review_box "iran"

    read -p "  Proceed with setup? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        msg_warn "Setup cancelled."
        return
    fi

    # ── Generate ──
    echo ""
    mkdir -p "${CORE_DIR}"

    local config_file="${CORE_DIR}/iran${HEALTH_PORT}.toml"
    local service_name="backhaul-iran${HEALTH_PORT}"

    generate_iran_config "${config_file}"
    msg_ok "Config saved: ${config_file}"

    create_systemd_service "${service_name}" "${config_file}" "Backhaul Iran - ${TUN_NAME}"
    msg_ok "Service created and started: ${service_name}"

    # ── Final Summary ──
    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Iran Server Setup Complete!${NC}"
    print_double_line
    echo ""
    echo -e "  Config:    ${BLUE}${config_file}${NC}"
    echo -e "  Service:   ${BLUE}${service_name}.service${NC}"
    echo ""
    echo -e " ${YELLOW}${BOLD}  For Kharej setup, use:${NC}"
    echo -e "    Tunnel ID:  ${CYAN}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "    Dest IP:    ${CYAN}${BOLD}${LISTEN_IP}${NC}"
    if [ "$ENCRYPTION" = "true" ]; then
        echo -e "    PSK:        ${CYAN}${BOLD}${PSK}${NC}"
    fi
    echo ""

    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

setup_kharej() {
    print_header
    echo -e " ${GREEN}${BOLD}>>> Setup Kharej Client (IPX Client Mode)${NC}"
    echo ""
    print_line

    ensure_setup_prerequisites || return

    # Auto-detect interface
    INTERFACE=$(detect_interface)

    # Auto-detect public IP for listen_ip default
    local AUTO_IP
    AUTO_IP=$(detect_public_ip)

    # ── Step 1: Tunnel Identity ──
    echo -e "\n ${MAGENTA}${BOLD}[1/5] Tunnel Identity${NC}"
    while true; do
        read_input "Tunnel ID (must match Iran, e.g. 10, 12, 50)" "" TUNNEL_ID
        if [[ "$TUNNEL_ID" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$TUNNEL_ID" ]; then
            msg_err "Tunnel ID cannot be empty!"
        elif ! [[ "$TUNNEL_ID" =~ ^[0-9]+$ ]] || [ "$TUNNEL_ID" -le 0 ] || [ "$TUNNEL_ID" -gt 254 ]; then
            msg_err "Tunnel ID must be a number between 1 and 254."
        else
            local conflict
            conflict=$(get_tunnel_conflict "$TUNNEL_ID")
            if [ -n "$conflict" ]; then
                msg_err "Tunnel ID '${TUNNEL_ID}' is already in use by '${conflict}'! Please choose a different ID."
            else
                break
            fi
        fi
    done
    read_input "Tunnel name" "back${TUNNEL_ID}" TUN_NAME

    local default_health_port="1001"
    if [[ "$TUNNEL_ID" =~ ^[0-9]+$ ]]; then
        default_health_port=$((1000 + 10#$TUNNEL_ID))
    fi
    while true; do
        read_input "Health port" "${default_health_port}" HEALTH_PORT
        if [[ "$HEALTH_PORT" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$HEALTH_PORT" ] || ! [[ "$HEALTH_PORT" =~ ^[0-9]+$ ]] || [ "$HEALTH_PORT" -le 0 ] || [ "$HEALTH_PORT" -gt 65535 ]; then
            msg_err "Health port must be a valid port number (1-65535)."
        elif [ -f "${CORE_DIR}/iran${HEALTH_PORT}.toml" ] || [ -f "${CORE_DIR}/kharej${HEALTH_PORT}.toml" ]; then
            msg_err "Health port ${HEALTH_PORT} is already in use by an existing config! Please choose a different port."
        else
            break
        fi
    done
    read_input "MTU" "1320" MTU

    # Auto-generate TUN addresses from ID (reversed for kharej)
    LOCAL_TUN_ADDR="10.10.${TUNNEL_ID}.2/24"
    REMOTE_TUN_ADDR="10.10.${TUNNEL_ID}.1/24"

    # ── Step 2: IPX Network ──
    echo -e "\n ${MAGENTA}${BOLD}[2/5] IPX Network${NC}"
    msg_info "Interface auto-detected: ${BOLD}${INTERFACE}${NC}"
    read_input "Change interface? (press Enter to keep)" "${INTERFACE}" INTERFACE
    if [ -n "$AUTO_IP" ]; then
        msg_info "Public IP auto-detected: ${BOLD}${AUTO_IP}${NC}"
    fi
    while true; do
        read_input "Listen IP (this server's public IP)" "${AUTO_IP}" LISTEN_IP
        if [[ "$LISTEN_IP" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$LISTEN_IP" ]; then
            msg_err "Listen IP cannot be empty!"
        elif ! is_valid_ipv4 "$LISTEN_IP"; then
            msg_err "Invalid IP format '${LISTEN_IP}'. Please enter a valid IPv4 address."
        else
            break
        fi
    done

    while true; do
        read_input "Destination IP (Iran public IP)" "" DST_IP
        if [[ "$DST_IP" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$DST_IP" ]; then
            msg_err "Destination IP cannot be empty!"
        elif ! is_valid_ipv4 "$DST_IP"; then
            msg_err "Invalid IP format '${DST_IP}'. Please enter a valid IPv4 address (e.g. 79.127.126.29)."
        else
            break
        fi
    done

    # ── Step 3: Profile (BIP or Spoof Protocols) ──
    echo -e "\n ${MAGENTA}${BOLD}[3/5] IPX Profile${NC}"
    echo -e "  ${WHITE}1)${NC} bip"
    echo -e "  ${WHITE}2)${NC} udp"
    echo -e "  ${WHITE}3)${NC} tcp  ${DIM}(default)${NC}"
    echo -e "  ${WHITE}4)${NC} icmp"
    read_input "Select profile (1, 2, 3 or 4)" "3" PROFILE_CHOICE
    if [ "$PROFILE_CHOICE" = "2" ] || [ "$PROFILE_CHOICE" = "3" ] || [ "$PROFILE_CHOICE" = "4" ]; then
        if [ "$PROFILE_CHOICE" = "2" ]; then
            PROFILE="udp"
        elif [ "$PROFILE_CHOICE" = "3" ]; then
            PROFILE="tcp"
        else
            PROFILE="icmp"
        fi
        msg_info "Note: In Kharej, spoof src/dst are SWAPPED vs Iran side."
        read_input "Spoof Source IP (Iran's spoof_dst_ip, optional)" "" SPOOF_SRC_IP
        read_input "Spoof Destination IP (Iran's spoof_src_ip, optional)" "" SPOOF_DST_IP

        local _src_line=""
        local _dst_line=""
        [ -n "$SPOOF_SRC_IP" ] && printf -v _src_line 'spoof_src_ip = "%s"\n' "${SPOOF_SRC_IP}"
        [ -n "$SPOOF_DST_IP" ] && printf -v _dst_line 'spoof_dst_ip = "%s"\n' "${SPOOF_DST_IP}"
        SPOOF_BLOCK="${_src_line}${_dst_line}"
    else
        PROFILE="bip"
        SPOOF_SRC_IP=""
        SPOOF_DST_IP=""
        SPOOF_BLOCK=""
    fi

    # ── Step 4: Security ──
    echo -e "\n ${MAGENTA}${BOLD}[4/5] Security${NC}"
    read_input "Enable encryption (true/false)" "false" ENCRYPTION
    if [[ "$ENCRYPTION" =~ ^([Tt]|true|TRUE|1|[Yy]|yes|YES)$ ]]; then
        ENCRYPTION="true"
        read_input "Algorithm" "aes-256-gcm" ALGORITHM
        echo -e "  ${DIM}Default PSK: ${DEFAULT_PSK}${NC}"
        read_input "PSK (Enter to use default, must match Iran)" "${DEFAULT_PSK}" PSK
        read_input "KDF iterations" "100000" KDF_ITERATIONS
    else
        ENCRYPTION="false"
        ALGORITHM="aes-256-gcm"
        PSK="${DEFAULT_PSK}"
        KDF_ITERATIONS="100000"
    fi

    # ── Step 5: Transport & Tuning ──
    echo -e "\n ${MAGENTA}${BOLD}[5/5] Transport & Tuning${NC}"
    HEARTBEAT_INTERVAL="10"
    HEARTBEAT_TIMEOUT="25"

    local default_workers
    default_workers=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    if [ -z "$default_workers" ] || [ "$default_workers" -lt 1 ]; then
        default_workers=1
    fi
    read_input "Workers count" "${default_workers}" WORKERS
    if [ -z "$WORKERS" ] || ! [[ "$WORKERS" =~ ^[0-9]+$ ]]; then
        WORKERS="${default_workers}"
    fi

    echo -e "  Tuning Profile:"
    echo -e "    ${WHITE}1)${NC} balanced"
    echo -e "    ${WHITE}2)${NC} fast  ${DIM}(default)${NC}"
    read_input "Select tuning profile (1 or 2)" "2" TUNING_CHOICE
    if [ "$TUNING_CHOICE" = "1" ]; then
        TUNING_PROFILE="balanced"
    else
        TUNING_PROFILE="fast"
    fi
    LOG_LEVEL="info"

    # ── Review ──
    show_review_box "kharej"

    read -p "  Proceed with setup? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        msg_warn "Setup cancelled."
        return
    fi

    # ── Generate ──
    echo ""
    mkdir -p "${CORE_DIR}"

    local config_file="${CORE_DIR}/kharej${HEALTH_PORT}.toml"
    local service_name="backhaul-kharej${HEALTH_PORT}"

    generate_kharej_config "${config_file}"
    msg_ok "Config saved: ${config_file}"

    create_systemd_service "${service_name}" "${config_file}" "Backhaul Kharej - ${TUN_NAME}"
    msg_ok "Service created and started: ${service_name}"

    # ── Final Summary ──
    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Kharej Client Setup Complete!${NC}"
    print_double_line
    echo ""
    echo -e "  Config:    ${BLUE}${config_file}${NC}"
    echo -e "  Service:   ${BLUE}${service_name}.service${NC}"
    echo ""

    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

fast_setup_iran() {
    print_header
    echo -e " ${GREEN}${BOLD}>>> Fast Setup Iran Server (IPX Server Mode)${NC}"
    echo ""
    print_line

    ensure_setup_prerequisites || return

    # Auto-detect interface
    INTERFACE=$(detect_interface)

    # Auto-detect public IP for listen_ip default
    local AUTO_IP
    AUTO_IP=$(detect_public_ip)

    echo -e "\n ${CYAN}${BOLD}[Fast Setup] Only 3 inputs required:${NC}\n"

    # 1. Tunnel ID
    while true; do
        read_input "Tunnel ID (e.g. 10, 12, 50)" "" TUNNEL_ID
        if [[ "$TUNNEL_ID" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$TUNNEL_ID" ]; then
            msg_err "Tunnel ID cannot be empty!"
        elif ! [[ "$TUNNEL_ID" =~ ^[0-9]+$ ]] || [ "$TUNNEL_ID" -le 0 ] || [ "$TUNNEL_ID" -gt 254 ]; then
            msg_err "Tunnel ID must be a number between 1 and 254."
        else
            local conflict
            conflict=$(get_tunnel_conflict "$TUNNEL_ID")
            if [ -n "$conflict" ]; then
                msg_err "Tunnel ID '${TUNNEL_ID}' is already in use by '${conflict}'! Please choose a different ID."
            else
                break
            fi
        fi
    done

    # Automated values based on Tunnel ID
    TUN_NAME="backhaul${TUNNEL_ID}"
    HEALTH_PORT=$((1000 + 10#$TUNNEL_ID))
    MTU="1320"

    LOCAL_TUN_ADDR="10.10.${TUNNEL_ID}.1/24"
    REMOTE_TUN_ADDR="10.10.${TUNNEL_ID}.2/24"

    # 2. Listen IP
    if [ -n "$AUTO_IP" ]; then
        msg_info "Public IP auto-detected: ${BOLD}${AUTO_IP}${NC}"
    fi
    while true; do
        read_input "Listen IP (this server's public IP)" "${AUTO_IP}" LISTEN_IP
        if [[ "$LISTEN_IP" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$LISTEN_IP" ]; then
            msg_err "Listen IP cannot be empty!"
        elif ! is_valid_ipv4 "$LISTEN_IP"; then
            msg_err "Invalid IP format '${LISTEN_IP}'. Please enter a valid IPv4 address."
        else
            break
        fi
    done

    # 3. Destination IP
    while true; do
        read_input "Destination IP (Kharej public IP)" "" DST_IP
        if [[ "$DST_IP" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$DST_IP" ]; then
            msg_err "Destination IP cannot be empty!"
        elif ! is_valid_ipv4 "$DST_IP"; then
            msg_err "Invalid IP format '${DST_IP}'. Please enter a valid IPv4 address (e.g. 185.129.116.237)."
        else
            break
        fi
    done

    # Automated IPX Profile & Security & Tuning
    PROFILE="tcp"
    SPOOF_SRC_IP=""
    SPOOF_DST_IP=""
    SPOOF_BLOCK=""

    ENCRYPTION="false"
    ALGORITHM="aes-256-gcm"
    PSK="${DEFAULT_PSK}"
    KDF_ITERATIONS="100000"

    HEARTBEAT_INTERVAL="10"
    HEARTBEAT_TIMEOUT="25"

    local default_workers
    default_workers=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    if [ -z "$default_workers" ] || [ "$default_workers" -lt 1 ]; then
        default_workers=1
    fi
    WORKERS="${default_workers}"

    TUNING_PROFILE="fast"
    LOG_LEVEL="info"

    # Review
    show_review_box "iran"

    read -p "  Proceed with setup? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        msg_warn "Setup cancelled."
        return
    fi

    # Generate
    echo ""
    mkdir -p "${CORE_DIR}"

    local config_file="${CORE_DIR}/iran${HEALTH_PORT}.toml"
    local service_name="backhaul-iran${HEALTH_PORT}"

    generate_iran_config "${config_file}"
    msg_ok "Config saved: ${config_file}"

    create_systemd_service "${service_name}" "${config_file}" "Backhaul Iran - ${TUN_NAME}"
    msg_ok "Service created and started: ${service_name}"

    # Final Summary
    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Iran Server Fast Setup Complete!${NC}"
    print_double_line
    echo ""
    echo -e "  Config:    ${BLUE}${config_file}${NC}"
    echo -e "  Service:   ${BLUE}${service_name}.service${NC}"
    echo ""
    echo -e " ${YELLOW}${BOLD}  For Kharej setup, use:${NC}"
    echo -e "    Tunnel ID:  ${CYAN}${BOLD}${TUNNEL_ID}${NC}"
    echo -e "    Dest IP:    ${CYAN}${BOLD}${LISTEN_IP}${NC}"
    echo ""

    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

fast_setup_kharej() {
    print_header
    echo -e " ${GREEN}${BOLD}>>> Fast Setup Kharej Client (IPX Client Mode)${NC}"
    echo ""
    print_line

    ensure_setup_prerequisites || return

    # Auto-detect interface
    INTERFACE=$(detect_interface)

    # Auto-detect public IP for listen_ip default
    local AUTO_IP
    AUTO_IP=$(detect_public_ip)

    echo -e "\n ${CYAN}${BOLD}[Fast Setup] Only 3 inputs required:${NC}\n"

    # 1. Tunnel ID
    while true; do
        read_input "Tunnel ID (must match Iran, e.g. 10, 12, 50)" "" TUNNEL_ID
        if [[ "$TUNNEL_ID" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$TUNNEL_ID" ]; then
            msg_err "Tunnel ID cannot be empty!"
        elif ! [[ "$TUNNEL_ID" =~ ^[0-9]+$ ]] || [ "$TUNNEL_ID" -le 0 ] || [ "$TUNNEL_ID" -gt 254 ]; then
            msg_err "Tunnel ID must be a number between 1 and 254."
        else
            local conflict
            conflict=$(get_tunnel_conflict "$TUNNEL_ID")
            if [ -n "$conflict" ]; then
                msg_err "Tunnel ID '${TUNNEL_ID}' is already in use by '${conflict}'! Please choose a different ID."
            else
                break
            fi
        fi
    done

    # Automated values based on Tunnel ID
    TUN_NAME="back${TUNNEL_ID}"
    HEALTH_PORT=$((1000 + 10#$TUNNEL_ID))
    MTU="1320"

    LOCAL_TUN_ADDR="10.10.${TUNNEL_ID}.2/24"
    REMOTE_TUN_ADDR="10.10.${TUNNEL_ID}.1/24"

    # 2. Listen IP
    if [ -n "$AUTO_IP" ]; then
        msg_info "Public IP auto-detected: ${BOLD}${AUTO_IP}${NC}"
    fi
    while true; do
        read_input "Listen IP (this server's public IP)" "${AUTO_IP}" LISTEN_IP
        if [[ "$LISTEN_IP" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$LISTEN_IP" ]; then
            msg_err "Listen IP cannot be empty!"
        elif ! is_valid_ipv4 "$LISTEN_IP"; then
            msg_err "Invalid IP format '${LISTEN_IP}'. Please enter a valid IPv4 address."
        else
            break
        fi
    done

    # 3. Destination IP
    while true; do
        read_input "Destination IP (Iran public IP)" "" DST_IP
        if [[ "$DST_IP" =~ ^(q|quit|cancel)$ ]]; then
            msg_warn "Setup cancelled."
            return
        fi
        if [ -z "$DST_IP" ]; then
            msg_err "Destination IP cannot be empty!"
        elif ! is_valid_ipv4 "$DST_IP"; then
            msg_err "Invalid IP format '${DST_IP}'. Please enter a valid IPv4 address (e.g. 5.160.10.20)."
        else
            break
        fi
    done

    # Automated IPX Profile & Security & Tuning
    PROFILE="tcp"
    SPOOF_SRC_IP=""
    SPOOF_DST_IP=""
    SPOOF_BLOCK=""

    ENCRYPTION="false"
    ALGORITHM="aes-256-gcm"
    PSK="${DEFAULT_PSK}"
    KDF_ITERATIONS="100000"

    HEARTBEAT_INTERVAL="10"
    HEARTBEAT_TIMEOUT="25"

    local default_workers
    default_workers=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    if [ -z "$default_workers" ] || [ "$default_workers" -lt 1 ]; then
        default_workers=1
    fi
    WORKERS="${default_workers}"

    TUNING_PROFILE="fast"
    LOG_LEVEL="info"

    # Review
    show_review_box "kharej"

    read -p "  Proceed with setup? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        msg_warn "Setup cancelled."
        return
    fi

    # Generate
    echo ""
    mkdir -p "${CORE_DIR}"

    local config_file="${CORE_DIR}/kharej${HEALTH_PORT}.toml"
    local service_name="backhaul-kharej${HEALTH_PORT}"

    generate_kharej_config "${config_file}"
    msg_ok "Config saved: ${config_file}"

    create_systemd_service "${service_name}" "${config_file}" "Backhaul Kharej - ${TUN_NAME}"
    msg_ok "Service created and started: ${service_name}"

    # Final Summary
    echo ""
    print_double_line
    echo -e " ${GREEN}${BOLD}  Kharej Client Fast Setup Complete!${NC}"
    print_double_line
    echo ""
    echo -e "  Config:    ${BLUE}${config_file}${NC}"
    echo -e "  Service:   ${BLUE}${service_name}.service${NC}"
    echo ""

    echo -e " ${CYAN}Service status:${NC}"
    systemctl status "${service_name}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

# ─── Management Helpers ───────────────────────────────────────────

list_tunnels() {
    echo ""
    echo -e " ${CYAN}${BOLD}Backhaul Tunnels:${NC}"
    print_line

    local found=0
    local i=1
    TUNNEL_LIST=()

    local all_svcs=()
    for sfile in "${SYSTEMD_DIR}"/backhaul-*.service; do
        [ -f "$sfile" ] || continue
        local bname=$(basename "$sfile" .service)
        [ "$bname" = "backhaul-watchdog" ] && continue
        all_svcs+=("$bname")
    done

    for svc in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "backhaul-" | awk '{print $1}'); do
        local bname="${svc%.service}"
        [ "$bname" = "backhaul-watchdog" ] && continue
        all_svcs+=("$bname")
    done

    local unique_svcs
    unique_svcs=$(printf "%s\n" "${all_svcs[@]}" 2>/dev/null | sort -u)

    while IFS= read -r name; do
        [ -z "$name" ] && continue
        found=1
        local status
        status=$(systemctl is-active "${name}" 2>/dev/null || echo "inactive")
        TUNNEL_LIST+=("${name}")

        if [ "$status" = "active" ]; then
            echo -e "  ${GREEN}●${NC} ${BOLD}${i})${NC} ${name}  ${GREEN}[active]${NC}"
        else
            echo -e "  ${RED}●${NC} ${BOLD}${i})${NC} ${name}  ${RED}[${status}]${NC}"
        fi
        ((i++))
    done <<< "$unique_svcs"

    if [ $found -eq 0 ]; then
        msg_warn "No backhaul tunnels found."
        return 1
    fi
    echo ""
    return 0
}

# Show tunnel list and let user pick one by number or name
pick_tunnel() {
    list_tunnels || return 1

    read -p "  Enter number or service name: " pick

    # If it's a number, resolve from list
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#TUNNEL_LIST[@]}" ]; then
        SELECTED_TUNNEL="${TUNNEL_LIST[$((pick-1))]}"
    else
        SELECTED_TUNNEL="$pick"
    fi

    if [ -z "${SELECTED_TUNNEL}" ]; then
        msg_err "Invalid selection."
        return 1
    fi

    # Validate existence as service file or systemd unit
    if ! systemctl list-unit-files "${SELECTED_TUNNEL}.service" &>/dev/null && [ ! -f "${SYSTEMD_DIR}/${SELECTED_TUNNEL}.service" ]; then
        msg_err "Service '${SELECTED_TUNNEL}' not found."
        return 1
    fi

    return 0
}

do_restart() {
    pick_tunnel || return
    systemctl restart "${SELECTED_TUNNEL}"
    msg_ok "${SELECTED_TUNNEL} restarted."
}

do_stop() {
    pick_tunnel || return
    systemctl stop "${SELECTED_TUNNEL}"
    msg_ok "${SELECTED_TUNNEL} stopped."
}

do_start() {
    pick_tunnel || return
    systemctl start "${SELECTED_TUNNEL}"
    systemctl enable "${SELECTED_TUNNEL}" &>/dev/null
    msg_ok "${SELECTED_TUNNEL} started & enabled."
}

do_disable() {
    pick_tunnel || return
    systemctl stop "${SELECTED_TUNNEL}" 2>/dev/null
    systemctl disable "${SELECTED_TUNNEL}" 2>/dev/null
    msg_ok "${SELECTED_TUNNEL} stopped & disabled. Config files kept."
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

do_view_config() {
    pick_tunnel || return

    # Target the config file directly based on the tunnel name
    local cfg="${CORE_DIR}/${SELECTED_TUNNEL#backhaul-}.toml"

    if [ -f "$cfg" ]; then
        echo ""
        print_line
        cat "$cfg"
        print_line
    else
        msg_err "Config file not found at ${cfg}."
    fi
}

do_edit_config() {
    pick_tunnel || return

    # Target the config file directly based on the tunnel name
    local cfg="${CORE_DIR}/${SELECTED_TUNNEL#backhaul-}.toml"

    if [ -f "$cfg" ]; then
        nano "$cfg"
        msg_ok "Configuration updated. You may need to restart the tunnel service to apply changes."
    else
        msg_err "Config file not found at ${cfg}."
    fi
}

do_delete() {
    pick_tunnel || return
    if [ -z "${SELECTED_TUNNEL}" ]; then
        msg_err "No tunnel selected."
        return 1
    fi
    echo ""
    echo -e " ${RED}${BOLD}This will permanently delete ${SELECTED_TUNNEL} and its config.${NC}"
    echo -e "  ${WHITE}1)${NC} Yes, delete"
    echo -e "  ${WHITE}2)${NC} Cancel"
    read -p "  Confirm (1 or 2): " confirm
    if [ "$confirm" = "1" ]; then
        systemctl stop "${SELECTED_TUNNEL}" 2>/dev/null
        systemctl disable "${SELECTED_TUNNEL}" 2>/dev/null

        # Target the config file directly based on the tunnel name
        # e.g., 'backhaul-iran1234' -> 'iran1234.toml'
        local cfg="${CORE_DIR}/${SELECTED_TUNNEL#backhaul-}.toml"

        rm -f "${SYSTEMD_DIR}/${SELECTED_TUNNEL}.service"
        if [ -f "$cfg" ]; then
            rm -f "$cfg"
            msg_ok "${SELECTED_TUNNEL} and its config (${cfg}) deleted."
        else
            msg_ok "${SELECTED_TUNNEL} deleted. (Config file not found or already removed)"
        fi

        systemctl daemon-reload

    else
        msg_warn "Cancelled."
    fi
}

# ─── Watchdog (Kharej Only) ────────────────────────────────────────

WATCHDOG_SCRIPT="/usr/local/bin/backhaul-watchdog.sh"
WATCHDOG_SERVICE="backhaul-watchdog"
WATCHDOG_SERVICE_FILE="${SYSTEMD_DIR}/${WATCHDOG_SERVICE}.service"
WATCHDOG_LOG="/var/log/backhaul-watchdog.log"

# Scan kharej configs and build "IP|SERVICE" targets
build_watchdog_targets() {
    local targets=()

    for toml_file in "${CORE_DIR}"/kharej*.toml; do
        [ -f "$toml_file" ] || continue

        local filename=$(basename "$toml_file")
        local svc_name="backhaul-${filename%.toml}"

        # Extract remote_addr from [tun] section
        local remote_addr=""
        local in_tun=0
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            [[ -z "$line" || "$line" == \#* ]] && continue

            if [[ "$line" == "[tun]" ]]; then
                in_tun=1
                continue
            elif [[ "$line" == \[* ]]; then
                in_tun=0
                continue
            fi

            if [ $in_tun -eq 1 ]; then
                if echo "$line" | grep -q '^remote_addr'; then
                    remote_addr=$(echo "$line" | cut -d'=' -f2 | tr -d ' "'\'' ' | cut -d'/' -f1)
                fi
            fi
        done < "$toml_file"

        if [ -n "$remote_addr" ]; then
            targets+=("${remote_addr}|${svc_name}")
        fi
    done

    echo "${targets[@]}"
}

deploy_watchdog() {
    echo ""
    echo -e " ${GREEN}${BOLD}>>> Deploy Watchdog (Kharej Only)${NC}"
    print_line

    # Build targets
    local raw_targets
    raw_targets=$(build_watchdog_targets)

    if [ -z "$raw_targets" ]; then
        msg_err "No kharej tunnel configs found in ${CORE_DIR}/"
        msg_warn "Watchdog only works on Kharej (client) side."
        return
    fi

    # Format for TARGETS array in script
    local targets_formatted=""
    for t in $raw_targets; do
        targets_formatted="${targets_formatted} \"${t}\""
    done

    echo ""
    msg_info "Detected targets:"
    for t in $raw_targets; do
        local ip="${t%%|*}"
        local svc="${t#*|}"
        echo -e "    ${GREEN}●${NC} ${BOLD}${svc}${NC}  →  ping ${CYAN}${ip}${NC}"
    done
    echo ""

    # Generate watchdog script (exactly matching backhaul-manager-app)
    cat > "${WATCHDOG_SCRIPT}" << 'WATCHDOG_HEADER'
#!/bin/bash
# Backhaul Watchdog
# Generated by Backhaul Setup Script

WATCHDOG_HEADER

    cat >> "${WATCHDOG_SCRIPT}" << EOF
TARGETS=(${targets_formatted})
LOG_FILE="${WATCHDOG_LOG}"
mkdir -p \$(dirname \$LOG_FILE)

echo "[\$(date)] Watchdog started with \${#TARGETS[@]} targets." >> \$LOG_FILE

while true; do
  for item in "\${TARGETS[@]}"; do
    IP="\${item%%|*}"
    SVC="\${item#*|}"

    # Logic: 6 Pings. If 3 or more fail, RESTART.
    # We allow 2 seconds per ping.
    # Total 6. If Received <= 3 (means 3,4,5,6 failed), then Restart.

    LOSS_COUNT=0
    for i in {1..6}; do
        if ! ping -c 1 -W 2 "\$IP" > /dev/null 2>&1; then
            ((LOSS_COUNT++))
        fi
    done

    # Threshold: If 3 or more failed
    if [ "\$LOSS_COUNT" -ge 3 ]; then
       echo "[\$(date)] FAIL: \$IP had \$LOSS_COUNT/6 packet loss. Restarting \$SVC..." >> \$LOG_FILE
       systemctl restart "\$SVC"
       sleep 5
    fi
  done

  # Run every 60 seconds (1 minute)
  sleep 60
done
EOF

    chmod +x "${WATCHDOG_SCRIPT}"
    msg_ok "Watchdog script created: ${WATCHDOG_SCRIPT}"

    # Create systemd service
    cat > "${WATCHDOG_SERVICE_FILE}" << EOF
[Unit]
Description=Backhaul Connectivity Watchdog
After=network.target

[Service]
Type=simple
ExecStart=${WATCHDOG_SCRIPT}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${WATCHDOG_SERVICE}" &>/dev/null
    msg_ok "Watchdog service deployed and started."

    echo ""
    echo -e " ${CYAN}Watchdog status:${NC}"
    systemctl status "${WATCHDOG_SERVICE}" --no-pager -l 2>/dev/null | head -5
    echo ""
}

remove_watchdog() {
    echo ""
    if [ ! -f "${WATCHDOG_SERVICE_FILE}" ]; then
        msg_warn "Watchdog is not installed."
        return
    fi

    echo -e " ${RED}${BOLD}Are you sure you want to remove Watchdog?${NC}"
    echo -e "  ${WHITE}1)${NC} Yes, remove"
    echo -e "  ${WHITE}2)${NC} Cancel"
    read -p "  Confirm (1 or 2): " confirm
    if [ "$confirm" = "1" ]; then
        systemctl stop "${WATCHDOG_SERVICE}" 2>/dev/null
        systemctl disable "${WATCHDOG_SERVICE}" 2>/dev/null
        rm -f "${WATCHDOG_SERVICE_FILE}"
        rm -f "${WATCHDOG_SCRIPT}"
        systemctl daemon-reload
        msg_ok "Watchdog removed."
    else
        msg_warn "Cancelled."
    fi
}

watchdog_status() {
    echo ""
    if [ ! -f "${WATCHDOG_SERVICE_FILE}" ]; then
        msg_warn "Watchdog is not installed."
        return
    fi

    echo -e " ${CYAN}${BOLD}Watchdog Status:${NC}"
    systemctl status "${WATCHDOG_SERVICE}" --no-pager -l 2>/dev/null | head -10
    echo ""
    echo -e " ${CYAN}Last 20 Watchdog Logs:${NC}"
    if [ -f "${WATCHDOG_LOG}" ]; then
        tail -20 "${WATCHDOG_LOG}"
    else
        msg_info "No watchdog log file yet."
    fi
}

scan_and_sync_configs() {
    echo ""
    echo -e " ${GREEN}${BOLD}>>> Scan & Sync Services for TOML configs${NC}"
    print_line

    if [ ! -d "${CORE_DIR}" ]; then
        msg_err "Core directory not found: ${CORE_DIR}"
        return
    fi

    local found=0
    local total=0
    for toml_file in "${CORE_DIR}"/*.toml; do
        [ -f "$toml_file" ] || continue
        ((total++))

        local filename=$(basename "$toml_file")
        local svc_name="backhaul-${filename%.toml}"
        local svc_path="${SYSTEMD_DIR}/${svc_name}.service"

        if [ ! -f "$svc_path" ]; then
            found=1
            msg_info "Missing service for ${filename}. Creating..."

            local desc_mode="Tunnel"
            if [[ "$filename" == iran* ]]; then desc_mode="Iran"; fi
            if [[ "$filename" == kharej* ]]; then desc_mode="Kharej"; fi

            create_systemd_service "${svc_name}" "${toml_file}" "Backhaul ${desc_mode} - ${filename%.toml}"
            msg_ok "Service created and started: ${svc_name}"
        fi
    done

    if [ $total -eq 0 ]; then
        msg_warn "No TOML configuration files found in ${CORE_DIR}."
    elif [ $found -eq 0 ]; then
        msg_ok "All TOML configs (${total} found) already have corresponding services."
    else
        echo ""
        msg_ok "Sync completed."
        echo -e " ${CYAN}Use option 5 to list all tunnels and check their status.${NC}"
    fi
}

# ─── Main Menu ────────────────────────────────────────────────────

main_menu() {
    while true; do
        print_header
        echo -e " ${BOLD}${WHITE}Setup${NC}"
        echo -e "  ${GREEN}1)${NC} Setup Iran Server (IPX Server)"
        echo -e "  ${BLUE}2)${NC} Setup Kharej Client (IPX Client)"
        echo ""
        echo -e " ${BOLD}${WHITE}Fast Setup${NC}"
        echo -e "  ${GREEN}3)${NC} Fast Setup Iran Server"
        echo -e "  ${BLUE}4)${NC} Fast Setup Kharej Client"
        echo ""
        echo -e " ${BOLD}${WHITE}Tunnels${NC}"
        echo -e "  ${CYAN}5)${NC} List All Tunnels"
        echo -e "  ${GREEN}6)${NC} Start a Tunnel"
        echo -e "  ${YELLOW}7)${NC} Restart a Tunnel"
        echo -e "  ${YELLOW}8)${NC} Stop a Tunnel"
        echo -e "  ${MAGENTA}9)${NC} Stop & Disable (keep files)"
        echo -e "  ${BLUE}10)${NC} Scan Configs & Auto-Create Services"
        echo ""
        echo -e " ${BOLD}${WHITE}Info & Logs${NC}"
        echo -e "  ${CYAN}11)${NC} View Last 50 Logs"
        echo -e "  ${CYAN}12)${NC} View Live Logs"
        echo -e "  ${BLUE}13)${NC} View Config"
        echo -e "  ${YELLOW}14)${NC} Edit Config (nano)"
        echo ""
        echo -e " ${BOLD}${WHITE}Watchdog (Kharej)${NC}"
        echo -e "  ${GREEN}15)${NC} Deploy Watchdog"
        echo -e "  ${CYAN}16)${NC} Watchdog Status & Logs"
        echo -e "  ${RED}17)${NC} Remove Watchdog"
        echo ""
        echo -e " ${BOLD}${WHITE}Danger${NC}"
        echo -e "  ${RED}18)${NC} Delete a Tunnel"
        echo ""
        echo -e " ${BOLD}${WHITE}Install${NC}"
        echo -e "  ${MAGENTA}19)${NC} Download Backhaul Binary"
        echo ""
        echo -e "  ${DIM}0)${NC} Exit"
        echo ""
        read -p "  Select: " choice

        case $choice in
            1)  setup_iran ;;
            2)  setup_kharej ;;
            3)  fast_setup_iran ;;
            4)  fast_setup_kharej ;;
            5)  list_tunnels ;;
            6)  do_start ;;
            7)  do_restart ;;
            8)  do_stop ;;
            9)  do_disable ;;
            10) scan_and_sync_configs ;;
            11) do_logs ;;
            12) do_live_logs ;;
            13) do_view_config ;;
            14) do_edit_config ;;
            15) deploy_watchdog ;;
            16) watchdog_status ;;
            17) remove_watchdog ;;
            18) do_delete ;;
            19) download_binary ;;
            0)
                echo -e "\n ${GREEN}Goodbye!${NC}\n"
                exit 0
                ;;
            *)
                msg_err "Invalid option."
                ;;
        esac

        echo ""
        read -p "  Press Enter to continue..."
    done
}

# ─── Entry Point ──────────────────────────────────────────────────

check_root
check_binary
main_menu
