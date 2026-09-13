#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Inbound Port Rate Limiter - All-In-One Script
# Optimized and hardened for Ubuntu 20.04/22.04/24.04 and Debian 11/12
# ==============================================================================

set -o pipefail

# ------------------------------------------------------------------------------
# Default Settings (can be modified directly here or via the interactive menu)
# ------------------------------------------------------------------------------
DOWNLOAD_LIMIT="10mbit"       # Client download speed limit (Server egress traffic)
UPLOAD_LIMIT="10mbit"         # Client upload speed limit (Server ingress traffic)
CHECK_INTERVAL=10             # Interval in seconds to check for new inbounds
EXCLUDE_PORTS="22"            # Excluded ports (comma-separated, e.g., 22,2053)
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

    while read -r p; do
        p=$(echo "$p" | tr -d ' \r\n')
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
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
        tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc del dev "$iface" ingress 2>/dev/null || true
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
    echo -e "${BOLD}${CYAN}       3X-UI Inbound Ports Real-Time Traffic & Rate Limits      ${NC}"
    echo -e "${BOLD}${CYAN}================================================================${NC}"

    local s_status="${RED}Inactive${NC}"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        s_status="${GREEN}Active (Running)${NC}"
    fi
    echo -e "Auto-Monitor Service: $s_status"
    echo -e "WAN Interface: ${YELLOW}${iface:-Unknown}${NC}"
    echo -e "Default Limits: Download=${GREEN}$DOWNLOAD_LIMIT${NC} | Upload=${GREEN}$UPLOAD_LIMIT${NC}"
    echo -e "Excluded Ports: ${MAGENTA}${EXCLUDE_PORTS:-None}${NC}"
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
    echo "${DOWNLOAD_LIMIT}|${UPLOAD_LIMIT}|${EXCLUDE_PORTS}|${CUSTOM_LIMITS}|${BURST}|${WAN_INTERFACE}|${DB_PATH}"
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
    echo -e "${BOLD}${YELLOW}Removing service and resetting network configurations...${NC}"

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload

    clear_rules

    rm -f /etc/modules-load.d/ifb.conf
    rm -f "$CONFIG_FILE"
    rm -f "$STATE_FILE"
    rm -f "$INSTALL_PATH"

    if ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link set dev "$IFB_DEVICE" down 2>/dev/null || true
        ip link delete "$IFB_DEVICE" type ifb 2>/dev/null || true
    fi

    echo -e "${BOLD}${GREEN}✓ Script and service uninstalled completely.${NC}"
}

# ------------------------------------------------------------------------------
# Terminal User Interface (Interactive Menu)
# ------------------------------------------------------------------------------
show_menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        echo -e "${BOLD}${GREEN}    3X-UI Inbound Port Rate Limiter (Port-Limit All-in-One)     ${NC}"
        echo -e "${BOLD}${CYAN}================================================================${NC}"
        echo -e " ${BOLD}1)${NC} ${CYAN}Show current status & traffic stats (Status)${NC}"
        echo -e " ${BOLD}2)${NC} ${YELLOW}Change default download & upload speed limits${NC}"
        echo -e " ${BOLD}3)${NC} ${MAGENTA}Configure excluded ports (Exclude Ports)${NC}"
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
                read -rp "Press Enter to return to menu..."
                ;;
            2)
                echo ""
                echo -e "Current limits: Download = ${GREEN}$DOWNLOAD_LIMIT${NC} | Upload = ${GREEN}$UPLOAD_LIMIT${NC}"
                read -rp "New download speed (e.g. 10mbit or 10): " inp_down
                read -rp "New upload speed (e.g. 10mbit or 10): " inp_up
                if [[ -n "$inp_down" && -n "$inp_up" ]]; then
                    set_speed "$inp_down" "$inp_up"
                fi
                echo ""
                read -rp "Press Enter to return to menu..."
                ;;
            3)
                echo ""
                echo -e "Current excluded ports: ${MAGENTA}$EXCLUDE_PORTS${NC}"
                read -rp "New excluded ports (comma-separated, e.g. 22,2053): " inp_exc
                local valid_exc
                valid_exc=$(validate_ports_list "$inp_exc")
                EXCLUDE_PORTS="$valid_exc"
                save_config
                log_info "Excluded ports saved: $EXCLUDE_PORTS"
                apply_rules
                echo ""
                read -rp "Press Enter to return to menu..."
                ;;
            4)
                echo ""
                echo -e "Current custom limits: ${BLUE}${CUSTOM_LIMITS:-None}${NC}"
                echo "Format: PORT:DOWN:UP (e.g. 443:20mbit:20mbit,8443:5mbit:5mbit)"
                read -rp "Enter custom limits (leave empty to clear): " inp_cust
                local valid_cust
                valid_cust=$(validate_custom_limits "$inp_cust")
                if [[ -n "$inp_cust" && -z "$valid_cust" ]]; then
                    echo -e "${RED}[ERROR] Invalid format entered!${NC}"
                else
                    CUSTOM_LIMITS="$valid_cust"
                    save_config
                    log_info "Custom port limits saved."
                    apply_rules
                fi
                echo ""
                read -rp "Press Enter to return to menu..."
                ;;
            5)
                echo ""
                apply_rules
                echo ""
                read -rp "Press Enter to return to menu..."
                ;;
            6)
                echo ""
                install_service
                echo ""
                read -rp "Press Enter to return to menu..."
                ;;
            7)
                echo ""
                clear_rules
                echo ""
                read -rp "Press Enter to return to menu..."
                ;;
            8)
                echo ""
                echo -e "${YELLOW}Displaying live daemon logs (Press Ctrl+C to exit)...${NC}"
                trap ':' SIGINT
                journalctl -u "$SERVICE_NAME" -f -n 50 2>/dev/null || true
                trap - SIGINT
                echo ""
                read -rp "Press Enter to return to menu..."
                ;;
            9)
                echo ""
                read -rp "Are you sure you want to completely uninstall port-limit? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_service
                    exit 0
                fi
                ;;
            0)
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
    # Exclude help command from root check
    case "${1:-}" in
        help|--help|-h)
            echo "Port-Limit Management Tool Usage:"
            echo "  port-limit                    Open interactive management menu"
            echo "  port-limit status             Show port status and real-time traffic stats"
            echo "  port-limit apply              Apply or refresh traffic limits"
            echo "  port-limit stop               Clear all rate limits and unthrottle traffic"
            echo "  port-limit restart            Restart traffic control queues"
            echo "  port-limit install            Install and enable systemd background service"
            echo "  port-limit uninstall          Completely uninstall script and service"
            echo "  port-limit set-speed <D> <U>  Quickly update default speeds (e.g. port-limit set-speed 10mbit 10mbit)"
            echo "  port-limit monitor            Run background port monitoring daemon (used by systemd)"
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
