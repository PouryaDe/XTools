#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Inbound Port Rate Limiter - All-In-One Script
# Optimized and hardened for Ubuntu 20.04/22.04/24.04 and Debian 11/12
# ==============================================================================

set -o pipefail

VERSION="1.1.3"

# ------------------------------------------------------------------------------
# Default Settings (can be modified directly here or via the interactive menu)
# ------------------------------------------------------------------------------
DOWNLOAD_LIMIT="10mbit"       # Client download speed limit (Server egress traffic)
UPLOAD_LIMIT="10mbit"         # Client upload speed limit (Server ingress traffic)
CHECK_INTERVAL=60             # Interval in seconds to check for new inbounds (1 minute)
EXCLUDE_PORTS="22"            # Excluded ports (comma-separated, e.g., 22,2053)
MIN_PORT=10000                # Minimum port threshold (ports below 10000 are completely exempt)
CUSTOM_LIMITS=""              # Custom limits per port (e.g., "443:20mbit:20mbit,8443:5mbit:5mbit")
BURST="64k"                   # Burst buffer size for connection establishment (TSO/GSO compatible)
DB_PATH="${PORT_LIMIT_DB:-/etc/x-ui/x-ui.db}"         # SQLite database path for 3X-UI panel
WAN_INTERFACE=""                                      # Leave empty for automatic WAN interface detection
# ------------------------------------------------------------------------------

CONFIG_FILE="${PORT_LIMIT_CONFIG:-/etc/port-limit.conf}"
SERVICE_NAME="port-limit"
INSTALL_PATH="/usr/local/bin/port-limit"
STATE_FILE="${PORT_LIMIT_STATE:-/run/port-limit.ports}"
IFB_DEVICE="ifb0"

# Standard terminal color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Security & Input Validation Functions
# ------------------------------------------------------------------------------

# Validate rate unit and format to prevent command injection and zero-rate errors
validate_rate() {
    local rate="$1"
    rate=$(echo "$rate" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    rate="${rate//mbps/mbit}"
    rate="${rate//kbps/kbit}"
    rate="${rate//gbps/gbit}"

    # Handle shorthand units: 10m -> 10mbit, 500k -> 500kbit, 1g -> 1gbit
    if [[ "$rate" =~ ^[0-9]+m$ ]]; then rate="${rate%m}mbit"; fi
    if [[ "$rate" =~ ^[0-9]+k$ ]]; then rate="${rate%k}kbit"; fi
    if [[ "$rate" =~ ^[0-9]+g$ ]]; then rate="${rate%g}gbit"; fi

    if [[ "$rate" =~ ^[0-9]+$ ]]; then
        rate="${rate}mbit"
    fi

    # Rate must be positive non-zero number followed by valid unit (kbit, mbit, gbit)
    if [[ ! "$rate" =~ ^[1-9][0-9]*(kbit|mbit|gbit)$ ]]; then
        return 1
    fi
    echo "$rate"
    return 0
}

# Validate and sanitize comma-separated list of ports
validate_ports_list() {
    local list="$1"
    local cleaned=()
    IFS=',' read -ra arr <<< "$list"
    for p in "${arr[@]}"; do
        p=$(echo "$p" | tr -d ' ')
        [[ -z "$p" ]] && continue
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
            cleaned+=("$p")
        fi
    done
    local IFS=','
    if [[ ${#cleaned[@]} -gt 0 ]]; then
        echo "${cleaned[*]}"
    else
        echo ""
    fi
}

# Validate and sanitize custom limits
validate_custom_limits() {
    local list="$1"
    local cleaned=()
    IFS=',' read -ra arr <<< "$list"
    for entry in "${arr[@]}"; do
        entry=$(echo "$entry" | tr -d ' ')
        [[ -z "$entry" ]] && continue
        local cp cd cu
        cp=$(echo "$entry" | cut -d':' -f1)
        cd=$(echo "$entry" | cut -d':' -f2)
        cu=$(echo "$entry" | cut -d':' -f3)
        if [[ "$cp" =~ ^[0-9]+$ ]] && (( cp >= 1 && cp <= 65535 )); then
            local val_cd val_cu
            if val_cd=$(validate_rate "$cd" 2>/dev/null) && val_cu=$(validate_rate "$cu" 2>/dev/null); then
                cleaned+=("$cp:$val_cd:$val_cu")
            fi
        fi
    done
    local IFS=','
    if [[ ${#cleaned[@]} -gt 0 ]]; then
        echo "${cleaned[*]}"
    else
        echo ""
    fi
}

# Safely parse configuration file without using dangerous 'source'
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local val
        val=$(grep -E '^DOWNLOAD_LIMIT=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"'\'' ')
        if [[ -n "$val" ]] && validate_rate "$val" >/dev/null 2>&1; then
            DOWNLOAD_LIMIT="$(validate_rate "$val")"
        fi

        val=$(grep -E '^UPLOAD_LIMIT=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"'\'' ')
        if [[ -n "$val" ]] && validate_rate "$val" >/dev/null 2>&1; then
            UPLOAD_LIMIT="$(validate_rate "$val")"
        fi

        val=$(grep -E '^CHECK_INTERVAL=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"'\'' ')
        [[ -n "$val" && "$val" =~ ^[0-9]+$ && "$val" -ge 1 ]] && CHECK_INTERVAL="$val"

        if grep -q -E '^EXCLUDE_PORTS=' "$CONFIG_FILE"; then
            val=$(grep -E '^EXCLUDE_PORTS=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"'\'' ')
            EXCLUDE_PORTS="$(validate_ports_list "$val")"
        fi

        val=$(grep -E '^MIN_PORT=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"'\'' ')
        [[ -n "$val" && "$val" =~ ^[0-9]+$ && "$val" -ge 1 && "$val" -le 65535 ]] && MIN_PORT="$val"

        if grep -q -E '^CUSTOM_LIMITS=' "$CONFIG_FILE"; then
            val=$(grep -E '^CUSTOM_LIMITS=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"'\'' ')
            CUSTOM_LIMITS=$(validate_custom_limits "$val")
        fi

        val=$(grep -E '^BURST=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"'\'' ')
        [[ -n "$val" && "$val" =~ ^[0-9]+[kKmMgG]?$ ]] && BURST="$val"

        val=$(grep -E '^DB_PATH=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"'\'' ')
        [[ -n "$val" ]] && DB_PATH="$val"

        if grep -q -E '^WAN_INTERFACE=' "$CONFIG_FILE"; then
            WAN_INTERFACE=$(grep -E '^WAN_INTERFACE=' "$CONFIG_FILE" | cut -d'=' -f2- | tr -d '"'\'' ')
        fi
    fi
}

# Initial configuration load
load_config

# ------------------------------------------------------------------------------
# Logging & Helper Functions
# ------------------------------------------------------------------------------
log_info() {
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} ${RED}[ERROR]${NC} $1" >&2
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo / root)."
        exit 1
    fi
}

# Automatically install required packages if missing
ensure_dependencies() {
    local needed=()
    command -v tc >/dev/null 2>&1 || needed+=("iproute2")
    command -v sqlite3 >/dev/null 2>&1 || needed+=("sqlite3")
    command -v modprobe >/dev/null 2>&1 || needed+=("kmod")
    command -v bc >/dev/null 2>&1 || needed+=("bc")

    if [[ ${#needed[@]} -gt 0 ]]; then
        log_info "Installing prerequisite packages (${needed[*]})..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq "${needed[@]}" >/dev/null 2>&1
        log_info "Prerequisite packages installed successfully."
    fi
}

# Automatically detect WAN interface, filtering out virtual adapters (Docker, WireGuard, etc.)
detect_wan_interface() {
    if [[ -n "$WAN_INTERFACE" ]] && ip link show "$WAN_INTERFACE" >/dev/null 2>&1; then
        echo "$WAN_INTERFACE"
        return 0
    fi
    local iface
    # Priority 1: Default IPv4 route
    iface=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    # Priority 2: Outbound route to internet
    if [[ -z "$iface" ]]; then
        iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    fi
    # Priority 3: Active physical links excluding virtual devices
    if [[ -z "$iface" ]]; then
        iface=$(ip -br link | awk '$2=="UP" && $1!="lo" && !($1~/^(ifb|docker|br-|veth|tun|tap|wg)/){print $1; exit}')
    fi
    echo "$iface"
}

# Safely extract active inbounds from 3X-UI SQLite database with busy lock handling
get_active_ports() {
    if [[ ! -f "$DB_PATH" ]]; then
        log_warn "3X-UI database file not found at: $DB_PATH"
        return 1
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        ensure_dependencies
    fi

    # Using standard SQLite PRAGMA busy_timeout=2000 to handle active write transactions
    local raw_ports
    raw_ports=$(sqlite3 -readonly "$DB_PATH" "PRAGMA busy_timeout = 2000; SELECT port FROM inbounds WHERE enable = 1;" 2>/dev/null)
    local sqlite_status=$?

    if [[ $sqlite_status -ne 0 ]]; then
        log_warn "SQLite database is busy or inaccessible (exit code: $sqlite_status). Skipping changes."
        return 2
    fi

    if [[ -z "$raw_ports" ]]; then
        echo ""
        return 0
    fi

    local filtered=()
    IFS=',' read -ra exc_array <<< "$EXCLUDE_PORTS"

    local min_p="${MIN_PORT:-10000}"
    while read -r p; do
        p=$(echo "$p" | tr -d ' \r\n')
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= min_p && p <= 65535 )); then
            local is_exc=0
            for exc in "${exc_array[@]}"; do
                exc=$(echo "$exc" | tr -d ' ')
                if [[ "$p" == "$exc" ]]; then
                    is_exc=1
                    break
                fi
            done
            if [[ $is_exc -eq 0 ]]; then
                filtered+=("$p")
            fi
        fi
    done <<< "$raw_ports"

    printf "%s\n" "${filtered[@]}" | sort -n -u
}

# Get rate limits for a specific port (custom override or default)
get_port_limits() {
    local port="$1"
    local down="$DOWNLOAD_LIMIT"
    local up="$UPLOAD_LIMIT"

    if [[ -n "$CUSTOM_LIMITS" ]]; then
        IFS=',' read -ra c_arr <<< "$CUSTOM_LIMITS"
        for entry in "${c_arr[@]}"; do
            entry=$(echo "$entry" | tr -d ' ')
            local cp cd cu
            cp=$(echo "$entry" | cut -d':' -f1)
            cd=$(echo "$entry" | cut -d':' -f2)
            cu=$(echo "$entry" | cut -d':' -f3)
            if [[ "$cp" == "$port" ]]; then
                local val_cd val_cu
                if val_cd=$(validate_rate "$cd"); then
                    down="$val_cd"
                fi
                if val_cu=$(validate_rate "$cu"); then
                    up="$val_cu"
                fi
                break
            fi
        done
    fi

    local norm_d norm_u
    norm_d=$(validate_rate "$down") || norm_d="10mbit"
    norm_u=$(validate_rate "$up") || norm_u="10mbit"
    echo "$norm_d $norm_u"
}

# Initialize Intermediate Functional Block (IFB) device for Ingress rate limiting
setup_ifb() {
    if ! lsmod | grep -q "^ifb "; then
        modprobe ifb numifbs=1 2>/dev/null || true
    fi
    if ! ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link add name "$IFB_DEVICE" type ifb 2>/dev/null || true
    fi
    ip link set dev "$IFB_DEVICE" up 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Traffic Control (tc) Rule Management
# ------------------------------------------------------------------------------

# Completely remove all tc qdiscs, filters, and classes
clear_rules() {
    local iface
    iface=$(detect_wan_interface)
    log_info "Removing traffic control queues and rate limit rules..."

    if [[ -n "$iface" ]]; then
        tc filter del dev "$iface" parent ffff: 2>/dev/null || true
        tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc del dev "$iface" ingress 2>/dev/null || true
    fi
    if [[ -n "$WAN_INTERFACE" && "$WAN_INTERFACE" != "$iface" ]]; then
        tc filter del dev "$WAN_INTERFACE" parent ffff: 2>/dev/null || true
        tc qdisc del dev "$WAN_INTERFACE" root 2>/dev/null || true
        tc qdisc del dev "$WAN_INTERFACE" ingress 2>/dev/null || true
    fi
    if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
        tc qdisc del dev "$IFB_DEVICE" ingress 2>/dev/null || true
    fi

    rm -f "$STATE_FILE"
    log_info "All traffic control limits have been cleared successfully."
}

# Apply download and upload bandwidth limits for all active inbounds
apply_rules() {
    ensure_dependencies
    load_config

    local iface
    iface=$(detect_wan_interface)

    if [[ -z "$iface" ]]; then
        log_error "Default WAN interface could not be detected!"
        return 1
    fi

    local norm_down norm_up
    norm_down=$(validate_rate "$DOWNLOAD_LIMIT") || norm_down="10mbit"
    norm_up=$(validate_rate "$UPLOAD_LIMIT") || norm_up="10mbit"

    log_info "WAN Interface: ${BOLD}$iface${NC}"
    log_info "Default Speed Limits: Download=${BOLD}$norm_down${NC} | Upload=${BOLD}$norm_up${NC}"

    local ports_output
    ports_output=$(get_active_ports)
    local status_code=$?

    # Prevent accidental rule flush if database read returned error
    if [[ $status_code -ne 0 ]]; then
        log_warn "Failed to read database (code: $status_code), leaving existing rules unchanged."
        return 0
    fi

    local active_ports=()
    if [[ -n "$ports_output" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && active_ports+=("$line")
        done <<< "$ports_output"
    fi

    if [[ ${#active_ports[@]} -eq 0 ]]; then
        log_warn "No active inbound ports found in 3X-UI database."
        clear_rules
        return 0
    fi

    log_info "Active controlled ports (${#active_ports[@]}): ${GREEN}${active_ports[*]}${NC}"

    setup_ifb

    # Reset existing qdiscs
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc del dev "$iface" ingress 2>/dev/null || true
    tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true

    # 1. Egress root qdisc on physical WAN interface (Client Download - traffic leaving server)
    # Class 1:2 is the unthrottled default class for SSH and OS traffic (avoids port collisions)
    tc qdisc add dev "$iface" root handle 1: htb default 2
    tc class add dev "$iface" parent 1: classid 1:1 htb rate 10000mbit ceil 10000mbit
    tc class add dev "$iface" parent 1:1 classid 1:2 htb rate 10000mbit ceil 10000mbit
    tc qdisc add dev "$iface" parent 1:2 handle 2: fq_codel 2>/dev/null || \
    tc qdisc add dev "$iface" parent 1:2 handle 2: sfq perturb 10 2>/dev/null || true

    # 2. Redirect incoming WAN ingress traffic to IFB0 device for Ingress shaping
    tc qdisc add dev "$iface" handle ffff: ingress
    tc filter add dev "$iface" parent ffff: protocol all prio 1 u32 match u32 0 0 action mirred egress redirect dev "$IFB_DEVICE"

    # 3. Ingress root qdisc on IFB0 (Client Upload - traffic entering server)
    tc qdisc add dev "$IFB_DEVICE" root handle 1: htb default 2
    tc class add dev "$IFB_DEVICE" parent 1: classid 1:1 htb rate 10000mbit ceil 10000mbit
    tc class add dev "$IFB_DEVICE" parent 1:1 classid 1:2 htb rate 10000mbit ceil 10000mbit
    tc qdisc add dev "$IFB_DEVICE" parent 1:2 handle 2: fq_codel 2>/dev/null || \
    tc qdisc add dev "$IFB_DEVICE" parent 1:2 handle 2: sfq perturb 10 2>/dev/null || true

    # 4. Create isolated HTB classes and u32 filters per port (minor ID starts at offset 10)
    local idx=1
    for port in "${active_ports[@]}"; do
        local class_minor=$((idx + 10))
        local class_id="1:$class_minor"
        local qdisc_handle="${class_minor}:"

        read -r port_down port_up < <(get_port_limits "$port")

        # --- Egress shaping (Download): match source port (sport = port) ---
        tc class add dev "$iface" parent 1:1 classid "$class_id" htb rate "$port_down" ceil "$port_down" burst "$BURST"
        tc qdisc add dev "$iface" parent "$class_id" handle "$qdisc_handle" fq_codel 2>/dev/null || \
        tc qdisc add dev "$iface" parent "$class_id" handle "$qdisc_handle" sfq perturb 10 2>/dev/null || true

        # IPv4 TCP / UDP
        tc filter add dev "$iface" protocol ip parent 1: prio 1 u32 match ip protocol 6 0xff match ip sport "$port" 0xffff flowid "$class_id"
        tc filter add dev "$iface" protocol ip parent 1: prio 1 u32 match ip protocol 17 0xff match ip sport "$port" 0xffff flowid "$class_id"
        # IPv6 TCP / UDP (matches NextHeader at byte 6, sport at byte 40)
        tc filter add dev "$iface" protocol ipv6 parent 1: prio 2 u32 match u8 6 0xff at 6 match u16 "$port" 0xffff at 40 flowid "$class_id" 2>/dev/null || \
        tc filter add dev "$iface" protocol ipv6 parent 1: prio 2 flower ip_proto tcp src_port "$port" classid "$class_id" 2>/dev/null || true
        tc filter add dev "$iface" protocol ipv6 parent 1: prio 2 u32 match u8 17 0xff at 6 match u16 "$port" 0xffff at 40 flowid "$class_id" 2>/dev/null || \
        tc filter add dev "$iface" protocol ipv6 parent 1: prio 2 flower ip_proto udp src_port "$port" classid "$class_id" 2>/dev/null || true

        # --- Ingress shaping (Upload): match destination port (dport = port) on IFB0 ---
        tc class add dev "$IFB_DEVICE" parent 1:1 classid "$class_id" htb rate "$port_up" ceil "$port_up" burst "$BURST"
        tc qdisc add dev "$IFB_DEVICE" parent "$class_id" handle "$qdisc_handle" fq_codel 2>/dev/null || \
        tc qdisc add dev "$IFB_DEVICE" parent "$class_id" handle "$qdisc_handle" sfq perturb 10 2>/dev/null || true

        # IPv4 TCP / UDP on IFB0
        tc filter add dev "$IFB_DEVICE" protocol ip parent 1: prio 1 u32 match ip protocol 6 0xff match ip dport "$port" 0xffff flowid "$class_id"
        tc filter add dev "$IFB_DEVICE" protocol ip parent 1: prio 1 u32 match ip protocol 17 0xff match ip dport "$port" 0xffff flowid "$class_id"
        # IPv6 TCP / UDP on IFB0 (matches NextHeader at byte 6, dport at byte 42)
        tc filter add dev "$IFB_DEVICE" protocol ipv6 parent 1: prio 2 u32 match u8 6 0xff at 6 match u16 "$port" 0xffff at 42 flowid "$class_id" 2>/dev/null || \
        tc filter add dev "$IFB_DEVICE" protocol ipv6 parent 1: prio 2 flower ip_proto tcp dst_port "$port" classid "$class_id" 2>/dev/null || true
        tc filter add dev "$IFB_DEVICE" protocol ipv6 parent 1: prio 2 u32 match u8 17 0xff at 6 match u16 "$port" 0xffff at 42 flowid "$class_id" 2>/dev/null || \
        tc filter add dev "$IFB_DEVICE" protocol ipv6 parent 1: prio 2 flower ip_proto udp dst_port "$port" classid "$class_id" 2>/dev/null || true

        idx=$((idx + 1))
    done

    printf "%s\n" "${active_ports[@]}" > "$STATE_FILE"
    log_info "${GREEN}Rate limits successfully applied to all active ports.${NC}"
}

# Display system status and real-time bandwidth consumption statistics
show_status() {
    load_config
    local iface
    iface=$(detect_wan_interface)

    echo -e "${BOLD}${CYAN}================================================================${NC}"
    echo -e "${BOLD}${CYAN}  3X-UI Inbound Ports Real-Time Traffic & Rate Limits (v${VERSION})   ${NC}"
    echo -e "${BOLD}${CYAN}================================================================${NC}"

    local s_status="${RED}Inactive${NC}"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        s_status="${GREEN}Active (Running)${NC}"
    fi
    echo -e "Auto-Monitor Service: $s_status"
    echo -e "WAN Interface: ${YELLOW}${iface:-Unknown}${NC}"
    echo -e "Default Limits: Download=${GREEN}$DOWNLOAD_LIMIT${NC} | Upload=${GREEN}$UPLOAD_LIMIT${NC}"
    echo -e "Port Filter: ${YELLOW}>= ${MIN_PORT}${NC} (Ports < ${MIN_PORT} are completely exempt)"
    echo -e "Excluded Ports: ${MAGENTA}${EXCLUDE_PORTS:-None}${NC}"
    echo -e "Check Interval: ${CYAN}${CHECK_INTERVAL}s (1 minute)${NC}"
    echo -e "Panel Database: $DB_PATH"
    echo -e "----------------------------------------------------------------"

    local active_ports=()
    if [[ -f "$STATE_FILE" && -s "$STATE_FILE" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && active_ports+=("$line")
        done < "$STATE_FILE"
    else
        local raw_ports
        raw_ports=$(get_active_ports 2>/dev/null)
        if [[ -n "$raw_ports" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && active_ports+=("$line")
            done <<< "$raw_ports"
        fi
    fi

    if [[ ${#active_ports[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No active ports found in database or limits have not been applied yet.${NC}"
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        return 0
    fi

    printf "%-8s %-12s %-12s %-16s %-16s\n" "Port" "Download" "Upload" "Egress (Sent)" "Ingress (Recv)"
    echo -e "----------------------------------------------------------------"

    local idx=1
    for port in "${active_ports[@]}"; do
        local class_minor=$((idx + 10))
        local class_id="1:$class_minor"
        read -r port_down port_up < <(get_port_limits "$port")

        local down_bytes="0 B"
        local up_bytes="0 B"

        if [[ -n "$iface" ]]; then
            local egress_stat
            egress_stat=$(LC_ALL=C tc -s class show dev "$iface" classid "$class_id" 2>/dev/null | grep -i -o 'Sent [0-9]* bytes' | awk '{print $2}')
            if [[ -n "$egress_stat" ]]; then
                down_bytes=$(numfmt --to=iec-i --suffix=B "$egress_stat" 2>/dev/null || echo "${egress_stat} B")
            fi
        fi

        if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
            local ingress_stat
            ingress_stat=$(LC_ALL=C tc -s class show dev "$IFB_DEVICE" classid "$class_id" 2>/dev/null | grep -i -o 'Sent [0-9]* bytes' | awk '{print $2}')
            if [[ -n "$ingress_stat" ]]; then
                up_bytes=$(numfmt --to=iec-i --suffix=B "$ingress_stat" 2>/dev/null || echo "${ingress_stat} B")
            fi
        fi

        printf "%-8s %-12s %-12s %-16s %-16s\n" "$port" "$port_down" "$port_up" "$down_bytes" "$up_bytes"
        idx=$((idx + 1))
    done
    echo -e "${BOLD}${CYAN}================================================================${NC}"
}

# Generate a fingerprint string of current config parameters to track modifications
get_config_state_string() {
    echo "${DOWNLOAD_LIMIT}|${UPLOAD_LIMIT}|${CHECK_INTERVAL}|${EXCLUDE_PORTS}|${MIN_PORT}|${CUSTOM_LIMITS}|${BURST}|${WAN_INTERFACE}|${DB_PATH}"
}

# Daemon loop to automatically detect database additions/removals and config changes
run_monitor() {
    log_info "3X-UI auto-detector daemon started (interval: ${CHECK_INTERVAL}s)..."
    trap 'log_info "Termination signal received. Exiting monitor daemon."; exit 0' SIGINT SIGTERM

    apply_rules
    local last_ports
    last_ports=$(get_active_ports 2>/dev/null | tr '\n' ' ')
    local last_cfg_state
    last_cfg_state=$(get_config_state_string)

    while true; do
        sleep "$CHECK_INTERVAL"

        load_config
        local current_cfg_state
        current_cfg_state=$(get_config_state_string)

        local current_ports
        current_ports=$(get_active_ports 2>/dev/null | tr '\n' ' ')
        local status_code=$?

        # Skip iteration if database was temporarily busy or unreachable
        if [[ $status_code -ne 0 ]]; then
            continue
        fi

        # Re-apply rules if ports changed or speed parameters were updated
        if [[ "$current_ports" != "$last_ports" || "$current_cfg_state" != "$last_cfg_state" ]]; then
            log_info "Change detected in inbounds or speed configuration!"
            [[ "$current_ports" != "$last_ports" ]] && log_info "Previous ports: [ $last_ports ] -> New ports: [ $current_ports ]"
            [[ "$current_cfg_state" != "$last_cfg_state" ]] && log_info "Speed configuration updated."

            apply_rules
            last_ports="$current_ports"
            last_cfg_state="$current_cfg_state"
        fi
    done
}

# Save settings to configuration file with restricted file permissions
save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    cat << EOF > "$CONFIG_FILE"
DOWNLOAD_LIMIT="$DOWNLOAD_LIMIT"
UPLOAD_LIMIT="$UPLOAD_LIMIT"
CHECK_INTERVAL=$CHECK_INTERVAL
EXCLUDE_PORTS="$EXCLUDE_PORTS"
MIN_PORT=$MIN_PORT
CUSTOM_LIMITS="$CUSTOM_LIMITS"
BURST="$BURST"
DB_PATH="$DB_PATH"
WAN_INTERFACE="$WAN_INTERFACE"
EOF
}

# Quick speed update helper function
set_speed() {
    local down="$1"
    local up="$2"

    local norm_down norm_up
    norm_down=$(validate_rate "$down") || {
        echo -e "${RED}[ERROR] Invalid download rate format (e.g. 10mbit, 10m, or 10).${NC}"
        return 1
    }
    norm_up=$(validate_rate "$up") || {
        echo -e "${RED}[ERROR] Invalid upload rate format (e.g. 10mbit, 10m, or 10).${NC}"
        return 1
    }

    DOWNLOAD_LIMIT="$norm_down"
    UPLOAD_LIMIT="$norm_up"
    save_config
    log_info "Limits updated successfully: Download=$DOWNLOAD_LIMIT | Upload=$UPLOAD_LIMIT"
    apply_rules
}

# ------------------------------------------------------------------------------
# Systemd Service Installation & Uninstallation
# ------------------------------------------------------------------------------
install_service() {
    check_root
    echo -e "${BOLD}${CYAN}Deploying and installing service on system...${NC}"
    ensure_dependencies
    save_config

    modprobe ifb numifbs=1 2>/dev/null || true
    mkdir -p /etc/modules-load.d
    echo "ifb" > /etc/modules-load.d/ifb.conf

    # Resolve physical canonical path of the script
    local real_source
    real_source=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")
    local target_src="$real_source"
    [[ ! -f "$target_src" ]] && target_src="$0"

    if [[ ! -f "$target_src" ]]; then
        log_error "Source script ($target_src) not found! If installed via curl pipe, please download the file to disk first."
        return 1
    fi

    cp -f "$target_src" "${INSTALL_PATH}.tmp"
    chmod 755 "${INSTALL_PATH}.tmp"
    mv -f "${INSTALL_PATH}.tmp" "$INSTALL_PATH"

    cat << EOF > "/etc/systemd/system/${SERVICE_NAME}.service"
[Unit]
Description=3X-UI Inbound Port Rate Limiter & Auto-Detector
After=network.target x-ui.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH} monitor
ExecStop=${INSTALL_PATH} stop
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.service" >/dev/null 2>&1

    echo ""
    echo -e "${BOLD}${GREEN}================================================================${NC}"
    echo -e "${BOLD}${GREEN}  ✓ Script installed and systemd service activated successfully! 🎉${NC}"
    echo -e "${BOLD}${GREEN}================================================================${NC}"
    echo -e "You can now run '${BOLD}${CYAN}port-limit${NC}' from anywhere to access the management menu."
    echo ""
    show_status
}

uninstall_service() {
    check_root
    echo -e "${BOLD}${YELLOW}Removing service, resetting network configurations, and cleaning up files...${NC}"

    # 1. Stop and disable systemd service
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    # 2. Terminate any orphan monitor daemon processes running in background
    pkill -f "port-limit monitor" 2>/dev/null || true

    # 3. Remove systemd service unit and reload daemon
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f "/etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service"
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

    # 4. Remove all tc queues and rate limits
    clear_rules

    # 5. Bring down and delete IFB virtual device
    if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down 2>/dev/null || true
        ip link delete "$IFB_DEVICE" type ifb 2>/dev/null || true
    fi

    # 6. Remove kernel module load configuration and unload module from kernel
    rm -f /etc/modules-load.d/ifb.conf
    modprobe -r ifb 2>/dev/null || rmmod ifb 2>/dev/null || true

    # 7. Clean up any crontab or cron file remnants
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "port-limit" | crontab - 2>/dev/null || true
    fi
    rm -f /etc/cron.d/port-limit /etc/cron.daily/port-limit /etc/cron.hourly/port-limit 2>/dev/null || true

    # 8. Clean up all configuration, state, temporary, and executable files
    rm -f "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
    rm -f "$STATE_FILE" /run/port-limit* 2>/dev/null || true
    rm -f "$INSTALL_PATH" "${INSTALL_PATH}.tmp" 2>/dev/null || true

    echo -e "${BOLD}${GREEN}================================================================${NC}"
    echo -e "${BOLD}${GREEN}  ✓ Port-Limit and all associated components completely uninstalled!${NC}"
    echo -e "${BOLD}${GREEN}================================================================${NC}"
}

# ------------------------------------------------------------------------------
# Terminal User Interface (Interactive Menus & Navigation)
# ------------------------------------------------------------------------------

# Dedicated Submenu for Custom Per-Port Bandwidth Limits
menu_custom_limits() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        echo -e "${BOLD}${GREEN}              Custom Per-Port Speed Limits Menu                 ${NC}"
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        echo -e "Current configured custom limits:"
        if [[ -n "$CUSTOM_LIMITS" ]]; then
            IFS=',' read -ra c_arr <<< "$CUSTOM_LIMITS"
            for entry in "${c_arr[@]}"; do
                entry=$(echo "$entry" | tr -d ' ')
                [[ -z "$entry" ]] && continue
                local cp cd cu
                cp=$(echo "$entry" | cut -d':' -f1)
                cd=$(echo "$entry" | cut -d':' -f2)
                cu=$(echo "$entry" | cut -d':' -f3)
                echo -e "  • Port ${BOLD}${CYAN}$cp${NC} -> Download: ${GREEN}$cd${NC} | Upload: ${GREEN}$cu${NC}"
            done
        else
            echo -e "  ${YELLOW}(No custom limits configured - all inbounds use default limits)${NC}"
        fi
        echo -e "${BOLD}${CYAN}----------------------------------------------------------------${NC}"
        echo -e " ${BOLD}1)${NC} Add or update custom limit for a port"
        echo -e " ${BOLD}2)${NC} Remove custom limit for a specific port"
        echo -e " ${BOLD}3)${NC} Clear all custom limits"
        echo -e " ${BOLD}0)${NC} ${BOLD}${YELLOW}Return to Main Menu${NC}"
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        read -rp "Please select an option [0-3]: " sub_choice

        case "$sub_choice" in
            1)
                echo ""
                echo -e "${CYAN}Enter port details (or '0' / 'b' at any prompt to cancel and return):${NC}"
                read -rp "Target Port (1-65535) [0 to return]: " p_port
                if [[ "$p_port" == "0" || "$p_port" == "b" || "$p_port" == "B" || -z "$p_port" ]]; then
                    echo -e "${YELLOW}Cancelled. Returning to custom limits menu...${NC}"
                    sleep 0.5
                    continue
                fi
                if [[ ! "$p_port" =~ ^[0-9]+$ ]] || (( p_port < 1 || p_port > 65535 )); then
                    echo -e "${RED}[ERROR] Invalid port number.${NC}"
                    sleep 1
                    continue
                fi

                if (( p_port < MIN_PORT )); then
                    echo -e "${RED}[ERROR] Port $p_port is below minimum threshold ($MIN_PORT). Ports under $MIN_PORT are exempt from rate limiting.${NC}"
                    sleep 1.5
                    continue
                fi

                read -rp "Download limit for port $p_port (e.g. 20mbit or 20) [0 to return]: " p_down
                if [[ "$p_down" == "0" || "$p_down" == "b" || "$p_down" == "B" || -z "$p_down" ]]; then
                    echo -e "${YELLOW}Cancelled. Returning to custom limits menu...${NC}"
                    sleep 0.5
                    continue
                fi
                local v_down
                if ! v_down=$(validate_rate "$p_down"); then
                    echo -e "${RED}[ERROR] Invalid download rate format.${NC}"
                    sleep 1
                    continue
                fi

                read -rp "Upload limit for port $p_port (e.g. 20mbit or 20) [0 to return]: " p_up
                if [[ "$p_up" == "0" || "$p_up" == "b" || "$p_up" == "B" || -z "$p_up" ]]; then
                    echo -e "${YELLOW}Cancelled. Returning to custom limits menu...${NC}"
                    sleep 0.5
                    continue
                fi
                local v_up
                if ! v_up=$(validate_rate "$p_up"); then
                    echo -e "${RED}[ERROR] Invalid upload rate format.${NC}"
                    sleep 1
                    continue
                fi

                # Update or add entry to CUSTOM_LIMITS
                local new_list=()
                if [[ -n "$CUSTOM_LIMITS" ]]; then
                    IFS=',' read -ra existing_arr <<< "$CUSTOM_LIMITS"
                    for item in "${existing_arr[@]}"; do
                        item=$(echo "$item" | tr -d ' ')
                        [[ -z "$item" ]] && continue
                        local item_p
                        item_p=$(echo "$item" | cut -d':' -f1)
                        if [[ "$item_p" != "$p_port" ]]; then
                            new_list+=("$item")
                        fi
                    done
                fi
                new_list+=("$p_port:$v_down:$v_up")
                local IFS=','
                CUSTOM_LIMITS="${new_list[*]}"
                save_config
                log_info "Custom limit for port $p_port set to Down: $v_down | Up: $v_up"
                apply_rules
                echo ""
                read -rp "Press Enter [or enter 0] to continue..."
                ;;
            2)
                echo ""
                if [[ -z "$CUSTOM_LIMITS" ]]; then
                    echo -e "${YELLOW}No custom limits are currently set.${NC}"
                    sleep 1
                    continue
                fi
                read -rp "Enter port number to remove [0 to return]: " p_port
                if [[ "$p_port" == "0" || "$p_port" == "b" || "$p_port" == "B" || -z "$p_port" ]]; then
                    echo -e "${YELLOW}Cancelled. Returning to custom limits menu...${NC}"
                    sleep 0.5
                    continue
                fi
                local new_list=()
                local found=0
                IFS=',' read -ra existing_arr <<< "$CUSTOM_LIMITS"
                for item in "${existing_arr[@]}"; do
                    item=$(echo "$item" | tr -d ' ')
                    [[ -z "$item" ]] && continue
                    local item_p
                    item_p=$(echo "$item" | cut -d':' -f1)
                    if [[ "$item_p" == "$p_port" ]]; then
                        found=1
                    else
                        new_list+=("$item")
                    fi
                done
                if [[ $found -eq 1 ]]; then
                    local IFS=','
                    CUSTOM_LIMITS="${new_list[*]}"
                    save_config
                    log_info "Custom limit for port $p_port removed."
                    apply_rules
                else
                    echo -e "${YELLOW}Port $p_port was not found in custom limits.${NC}"
                fi
                echo ""
                read -rp "Press Enter [or enter 0] to continue..."
                ;;
            3)
                echo ""
                echo -e "${BOLD}${YELLOW}Are you sure you want to clear ALL custom per-port limits?${NC}"
                echo -e " ${BOLD}1)${NC} Confirm and clear all"
                echo -e " ${BOLD}0)${NC} ${YELLOW}Cancel and return${NC}"
                read -rp "Please select an option [0-1]: " clr_cust
                if [[ "$clr_cust" == "1" ]]; then
                    CUSTOM_LIMITS=""
                    save_config
                    log_info "All custom limits cleared."
                    apply_rules
                    echo ""
                    read -rp "Press Enter [or enter 0] to continue..."
                else
                    echo -e "${YELLOW}Cancelled.${NC}"
                    sleep 0.5
                fi
                ;;
            0|b|B|q|Q)
                return 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# Dedicated Submenu for Port Filtering & Exclusions
menu_port_filter() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        echo -e "${BOLD}${GREEN}               Configure Port Filtering & Exclusions            ${NC}"
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        echo -e " Minimum Controlled Port : ${YELLOW}>= ${MIN_PORT}${NC} ${GREEN}(All ports < ${MIN_PORT} are completely exempt)${NC}"
        echo -e " Excluded Ports List     : ${MAGENTA}${EXCLUDE_PORTS:-None}${NC}"
        echo -e "${BOLD}${CYAN}----------------------------------------------------------------${NC}"
        echo -e " ${BOLD}1)${NC} Change minimum port threshold (Current: >= ${MIN_PORT})"
        echo -e " ${BOLD}2)${NC} Configure excluded ports list (e.g. 22,2053)"
        echo -e " ${BOLD}0)${NC} ${BOLD}${YELLOW}Return to Main Menu${NC}"
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        read -rp "Please select an option [0-2]: " pf_choice

        case "$pf_choice" in
            1)
                echo ""
                echo -e "Current minimum port threshold: ${YELLOW}>= ${MIN_PORT}${NC}"
                echo -e "${CYAN}(Inbound ports below this number will never have rate limits applied)${NC}"
                read -rp "Enter new minimum port (1-65535) [0 to cancel]: " inp_min
                if [[ "$inp_min" == "0" || "$inp_min" == "b" || "$inp_min" == "B" || -z "$inp_min" ]]; then
                    echo -e "${YELLOW}Cancelled.${NC}"
                    sleep 0.5
                    continue
                fi
                if [[ "$inp_min" =~ ^[0-9]+$ ]] && (( inp_min >= 1 && inp_min <= 65535 )); then
                    MIN_PORT="$inp_min"
                    save_config
                    log_info "Minimum port threshold set to: >= $MIN_PORT"
                    apply_rules
                else
                    echo -e "${RED}[ERROR] Invalid port number. Must be between 1 and 65535.${NC}"
                fi
                echo ""
                read -rp "Press Enter [or enter 0] to continue..."
                ;;
            2)
                echo ""
                echo -e "Current excluded ports: ${MAGENTA}${EXCLUDE_PORTS:-None}${NC}"
                echo -e "${YELLOW}(Enter '0' or 'b' to cancel and return, or 'none' to clear)${NC}\n"
                read -rp "New excluded ports (comma-separated, e.g. 22,2053) [0 to return]: " inp_exc
                if [[ "$inp_exc" == "0" || "$inp_exc" == "b" || "$inp_exc" == "B" || -z "$inp_exc" ]]; then
                    echo -e "${YELLOW}Cancelled.${NC}"
                    sleep 0.5
                    continue
                fi
                if [[ "$inp_exc" == "none" || "$inp_exc" == "NONE" || "$inp_exc" == "clear" ]]; then
                    EXCLUDE_PORTS=""
                else
                    local valid_exc
                    valid_exc=$(validate_ports_list "$inp_exc")
                    EXCLUDE_PORTS="$valid_exc"
                fi
                save_config
                log_info "Excluded ports saved: ${EXCLUDE_PORTS:-None}"
                apply_rules
                echo ""
                read -rp "Press Enter [or enter 0] to continue..."
                ;;
            0|b|B|q|Q)
                return 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

show_menu() {
    while true; do
        clear
        local s_status="${RED}Inactive${NC}"
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            s_status="${GREEN}Active (Running)${NC}"
        fi

        echo -e "${BOLD}${CYAN}================================================================${NC}"
        echo -e "${BOLD}${GREEN}   3X-UI Inbound Port Rate Limiter - PortLimit (v${VERSION})     ${NC}"
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        echo -e " Auto-Monitor Service : $s_status"
        echo -e " Default Speed Limits : Down: ${GREEN}$DOWNLOAD_LIMIT${NC} | Up: ${GREEN}$UPLOAD_LIMIT${NC}"
        echo -e " Port Filtering       : >= ${MIN_PORT} (Ports < ${MIN_PORT} are completely exempt)"
        echo -e " Excluded Ports       : ${MAGENTA}${EXCLUDE_PORTS:-None}${NC}"
        echo -e " Check Interval       : ${CYAN}${CHECK_INTERVAL}s (1 minute)${NC}"
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        echo -e " ${BOLD}1)${NC} ${CYAN}Show current status & traffic stats (Status)${NC}"
        echo -e " ${BOLD}2)${NC} ${YELLOW}Change default download & upload speed limits${NC}"
        echo -e " ${BOLD}3)${NC} ${MAGENTA}Configure port filtering & exclusions (Min Port: >= ${MIN_PORT})${NC}"
        echo -e " ${BOLD}4)${NC} ${BLUE}Configure custom per-port speed limits (Custom Limits)${NC}"
        echo -e " ${BOLD}5)${NC} ${GREEN}Apply / reload traffic control rules now (Apply / Reload)${NC}"
        echo -e " ${BOLD}6)${NC} ${YELLOW}Install & enable background service (Install Service)${NC}"
        echo -e " ${BOLD}7)${NC} ${RED}Clear all rate limits / unthrottle traffic (Clear Limits)${NC}"
        echo -e " ${BOLD}8)${NC} ${CYAN}View live monitor daemon logs (Live Logs)${NC}"
        echo -e " ${BOLD}9)${NC} ${RED}Uninstall port-limit completely (Uninstall)${NC}"
        echo -e " ${BOLD}0)${NC} Exit"
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        read -rp "Please select an option [0-9]: " choice

        case "$choice" in
            1)
                echo ""
                show_status
                echo ""
                read -rp "Press Enter [or enter 0] to return to main menu..."
                ;;
            2)
                echo ""
                echo -e "${BOLD}${CYAN}================================================================${NC}"
                echo -e "${BOLD}${GREEN}        Change Default Download & Upload Speed Limits           ${NC}"
                echo -e "${BOLD}${CYAN}================================================================${NC}"
                echo -e "Current limits: Download = ${GREEN}$DOWNLOAD_LIMIT${NC} | Upload = ${GREEN}$UPLOAD_LIMIT${NC}"
                echo -e "${YELLOW}(Enter '0' or 'b' at any prompt to cancel and return to main menu)${NC}\n"
                read -rp "New download speed (e.g. 10mbit, 20m, or 10) [0 to return]: " inp_down
                if [[ "$inp_down" == "0" || "$inp_down" == "b" || "$inp_down" == "B" || -z "$inp_down" ]]; then
                    echo -e "${YELLOW}Cancelled. Returning to main menu...${NC}"
                    sleep 0.5
                    continue
                fi
                read -rp "New upload speed (e.g. 10mbit, 20m, or 10) [0 to return]: " inp_up
                if [[ "$inp_up" == "0" || "$inp_up" == "b" || "$inp_up" == "B" || -z "$inp_up" ]]; then
                    echo -e "${YELLOW}Cancelled. Returning to main menu...${NC}"
                    sleep 0.5
                    continue
                fi
                set_speed "$inp_down" "$inp_up"
                echo ""
                read -rp "Press Enter [or enter 0] to return to main menu..."
                ;;
            3)
                menu_port_filter
                ;;
            4)
                menu_custom_limits
                ;;
            5)
                echo ""
                apply_rules
                echo ""
                read -rp "Press Enter [or enter 0] to return to main menu..."
                ;;
            6)
                echo ""
                echo -e "${BOLD}${CYAN}================================================================${NC}"
                echo -e "${BOLD}${GREEN}            Install & Enable Background Service                 ${NC}"
                echo -e "${BOLD}${CYAN}================================================================${NC}"
                echo -e "This will configure kernel modules, install 'port-limit' to system PATH,"
                echo -e "and enable 'port-limit.service' under systemd to monitor inbounds automatically."
                echo ""
                echo -e " ${BOLD}1)${NC} Confirm and Install Service"
                echo -e " ${BOLD}0)${NC} ${YELLOW}Return to Main Menu${NC}"
                echo -e "${BOLD}${CYAN}================================================================${NC}"
                read -rp "Please select an option [0-1]: " svc_choice
                case "$svc_choice" in
                    1)
                        echo ""
                        install_service
                        echo ""
                        read -rp "Press Enter [or enter 0] to return to main menu..."
                        ;;
                    *)
                        echo -e "${YELLOW}Cancelled. Returning to main menu...${NC}"
                        sleep 0.5
                        ;;
                esac
                ;;
            7)
                echo ""
                echo -e "${BOLD}${YELLOW}================================================================${NC}"
                echo -e "${BOLD}${YELLOW}                Clear All Traffic Rate Limits                   ${NC}"
                echo -e "${BOLD}${YELLOW}================================================================${NC}"
                echo -e "This will remove all 'tc' traffic queues and unthrottle all traffic."
                echo ""
                echo -e " ${BOLD}1)${NC} Confirm and Clear All Limits"
                echo -e " ${BOLD}0)${NC} ${YELLOW}Return to Main Menu${NC}"
                echo -e "${BOLD}${YELLOW}================================================================${NC}"
                read -rp "Please select an option [0-1]: " clr_choice
                case "$clr_choice" in
                    1)
                        echo ""
                        clear_rules
                        echo ""
                        read -rp "Press Enter [or enter 0] to return to main menu..."
                        ;;
                    *)
                        echo -e "${YELLOW}Cancelled. Returning to main menu...${NC}"
                        sleep 0.5
                        ;;
                esac
                ;;
            8)
                echo ""
                echo -e "${YELLOW}Displaying live daemon logs (Press Ctrl+C to exit)...${NC}"
                trap ':' SIGINT
                journalctl -u "$SERVICE_NAME" -f -n 50 2>/dev/null || true
                trap - SIGINT
                echo ""
                read -rp "Press Enter [or enter 0] to return to main menu..."
                ;;
            9)
                echo ""
                echo -e "${BOLD}${RED}================================================================${NC}"
                echo -e "${BOLD}${RED}                Uninstall Port-Limit Completely                 ${NC}"
                echo -e "${BOLD}${RED}================================================================${NC}"
                echo -e "This will stop the service, remove all traffic control rules,"
                echo -e "delete configuration files, and remove the port-limit executable."
                echo ""
                echo -e " ${BOLD}1)${NC} Confirm Complete Uninstallation"
                echo -e " ${BOLD}0)${NC} ${YELLOW}Return to Main Menu${NC}"
                echo -e "${BOLD}${RED}================================================================${NC}"
                read -rp "Please select an option [0-1]: " uninst_choice
                case "$uninst_choice" in
                    1)
                        echo ""
                        uninstall_service
                        exit 0
                        ;;
                    *)
                        echo -e "${YELLOW}Cancelled. Returning to main menu...${NC}"
                        sleep 0.5
                        ;;
                esac
                ;;
            0|q|Q|exit)
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Entrypoint & Argument Handling
# ------------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Exclude help and version commands from root check
    case "${1:-}" in
        help|--help|-h)
            echo "Port-Limit Management Tool v$VERSION"
            echo "Usage:"
            echo "  port-limit                    Open interactive management menu"
            echo "  port-limit status             Show port status and real-time traffic stats"
            echo "  port-limit apply              Apply or refresh traffic limits"
            echo "  port-limit stop               Clear all rate limits and unthrottle traffic"
            echo "  port-limit restart            Restart traffic control queues"
            echo "  port-limit install            Install and enable systemd background service"
            echo "  port-limit uninstall          Completely uninstall script and service"
            echo "  port-limit set-speed <D> <U>  Quickly update default speeds (e.g. port-limit set-speed 10mbit 10mbit)"
            echo "  port-limit monitor            Run background port monitoring daemon (used by systemd)"
            echo "  port-limit version            Display version information"
            exit 0
            ;;
        version|--version|-v)
            echo "Port-Limit version $VERSION"
            exit 0
            ;;
    esac

    # Other commands require root privileges
    check_root

    case "${1:-}" in
        start|apply)
            apply_rules
            ;;
        stop|clear)
            clear_rules
            ;;
        restart)
            clear_rules
            apply_rules
            ;;
        status)
            show_status
            ;;
        monitor)
            run_monitor
            ;;
        install)
            install_service
            ;;
        uninstall)
            uninstall_service
            ;;
        set-speed)
            set_speed "${2:-}" "${3:-}"
            ;;
        menu|"")
            show_menu
            ;;
        *)
            log_error "Unknown command: ${1:-}. Run 'port-limit help' for usage instructions."
            exit 1
            ;;
    esac
fi
