#!/usr/bin/env bash
# ==============================================================================
# 3X-UI Inbound Port Rate Limiter - All-In-One Script
# Optimized and hardened for Ubuntu 20.04/22.04/24.04 and Debian 11/12
# ==============================================================================

set -o pipefail

VERSION="1.2.0"

# ------------------------------------------------------------------------------
# Default Settings (can be modified directly here or via the interactive menu)
# ------------------------------------------------------------------------------
DOWNLOAD_LIMIT="16mbit"       # Client download speed limit (Server egress traffic)
UPLOAD_LIMIT="16mbit"         # Client upload speed limit (Server ingress traffic)
CHECK_INTERVAL=600             # Interval in seconds to check for new inbounds (1 minute)
EXCLUDE_PORTS="22"            # Excluded ports (comma-separated, e.g., 22,2053)
MIN_PORT=10000                # Minimum port threshold (ports below 10000 are completely exempt)
CUSTOM_LIMITS=""              # Custom limits per port (e.g., "443:20mbit:20mbit,8443:5mbit:5mbit")
BURST="128k"                  # Burst buffer size for connection establishment (TSO/GSO 64KB+ compatible)
# [FIX-S8] Sanitize environment overrides: enforce valid absolute paths without traversal
if [[ -n "${PORT_LIMIT_DB:-}" && "${PORT_LIMIT_DB}" =~ ^/[a-zA-Z0-9_./-]+$ && ! "${PORT_LIMIT_DB}" =~ \.\. ]]; then
    DB_PATH="$PORT_LIMIT_DB"
else
    DB_PATH="/etc/x-ui/x-ui.db"
fi
WAN_INTERFACE=""                                      # Leave empty for automatic WAN interface detection
# ------------------------------------------------------------------------------

if [[ -n "${PORT_LIMIT_CONFIG:-}" && "${PORT_LIMIT_CONFIG}" =~ ^/[a-zA-Z0-9_./-]+$ && ! "${PORT_LIMIT_CONFIG}" =~ \.\. ]]; then
    CONFIG_FILE="$PORT_LIMIT_CONFIG"
else
    CONFIG_FILE="/etc/port-limit.conf"
fi
SERVICE_NAME="port-limit"
INSTALL_PATH="/usr/local/bin/port-limit"

if [[ -n "${PORT_LIMIT_STATE:-}" && "${PORT_LIMIT_STATE}" =~ ^/[a-zA-Z0-9_./-]+$ && ! "${PORT_LIMIT_STATE}" =~ \.\. ]]; then
    STATE_FILE="$PORT_LIMIT_STATE"
else
    STATE_FILE="/run/port-limit.ports"
fi
IFB_DEVICE="ifb0"

# Runtime state (not user-configurable)
DEPS_VERIFIED=0
CACHED_WAN_IFACE=""
CACHED_WAN_TIME=0

# Standard terminal color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Security & Input Validation Functions
# ------------------------------------------------------------------------------

# Validate rate unit and format to prevent command injection and zero-rate errors (Zero-fork pure bash)
validate_rate() {
    local rate="$1"
    rate="${rate,,}"
    rate="${rate// /}"
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

# Validate and sanitize comma-separated list of ports (Zero-fork pure bash)
validate_ports_list() {
    local list="$1"
    local cleaned=()
    IFS=',' read -ra arr <<< "$list"
    for p in "${arr[@]}"; do
        p="${p// /}"
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

# Validate and sanitize custom limits (Zero-fork pure bash)
validate_custom_limits() {
    local list="$1"
    local cleaned=()
    IFS=',' read -ra arr <<< "$list"
    for entry in "${arr[@]}"; do
        entry="${entry// /}"
        [[ -z "$entry" ]] && continue
        local cp cd cu
        IFS=':' read -r cp cd cu <<< "$entry"
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

# Safely parse configuration file without spawning external grep/cut/tr subshells (Zero-fork pure bash)
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local line key val
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            # Strip comments and surrounding spaces
            key="${key%%#*}"
            key="${key// /}"
            [[ -z "$key" ]] && continue
            val="${val%%#*}"
            val="${val//\"/}"
            val="${val//\'/}"
            val="${val#"${val%%[! ]*}"}"
            val="${val%"${val##*[! ]}"}"

            case "$key" in
                DOWNLOAD_LIMIT)
                    local v; if v=$(validate_rate "$val" 2>/dev/null); then DOWNLOAD_LIMIT="$v"; fi ;;
                UPLOAD_LIMIT)
                    local v; if v=$(validate_rate "$val" 2>/dev/null); then UPLOAD_LIMIT="$v"; fi ;;
                CHECK_INTERVAL)
                    # [FIX-L7] Cap interval to max 86400s (1 day) to prevent near-infinite accidental values
                    [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= 86400 )) && CHECK_INTERVAL="$val" ;;
                EXCLUDE_PORTS)
                    EXCLUDE_PORTS="$(validate_ports_list "$val")" ;;
                MIN_PORT)
                    # [FIX-L5] Allow 0 to mean "no minimum threshold" (apply limits to all ports)
                    [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 0 && val <= 65535 )) && MIN_PORT="$val" ;;
                CUSTOM_LIMITS)
                    CUSTOM_LIMITS=$(validate_custom_limits "$val") ;;
                BURST)
                    # [FIX-L8] Reject zero-burst values that cause silent tc failures
                    [[ "$val" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] && BURST="$val" ;;
                DB_PATH)
                    # [FIX-S5] Only accept absolute paths; reject shell metacharacters
                    if [[ "$val" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then DB_PATH="$val"; fi ;;
                WAN_INTERFACE)
                    # [FIX-S6] Validate interface name against allowed character set (max 15 chars)
                    if [[ "$val" =~ ^[a-zA-Z0-9_@.-]{1,15}$ ]]; then WAN_INTERFACE="$val"; fi ;;
            esac
        done < "$CONFIG_FILE"
    fi
}

# Initial configuration load
load_config

# ------------------------------------------------------------------------------
# Logging & Helper Functions
# ------------------------------------------------------------------------------
# [FIX-S9] Sanitize log messages to prevent ANSI escape injection / log forging
log_info() {
    local msg="$1"
    msg="${msg//$'\r'/}"
    printf '%b[INFO]%b %s\n' "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}" "${NC}" "$msg" >&2
}

log_warn() {
    local msg="$1"
    msg="${msg//$'\r'/}"
    printf '%b[WARN]%b %s\n' "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}" "${NC}" "$msg" >&2
}

log_error() {
    local msg="$1"
    msg="${msg//$'\r'/}"
    printf '%b[ERROR]%b %s\n' "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}" "${NC}" "$msg" >&2
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo / root)."
        exit 1
    fi
}

# Detect containerized environments (Docker, LXC, OpenVZ, Podman, Containerd)
is_container() {
    if [[ -f /.dockerenv || -f /run/.containerenv ]]; then
        return 0
    fi
    if [[ -r /proc/1/environ ]] && grep -qaE 'container=(lxc|docker|podman|containerd)' /proc/1/environ 2>/dev/null; then
        return 0
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 1 systemd-detect-virt --container >/dev/null 2>&1 && return 0
        else
            systemd-detect-virt --container >/dev/null 2>&1 && return 0
        fi
    fi
    if [[ -r /proc/1/cgroup ]] && grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    return 1
}

# Safely load kernel module with container check, duplicate check, and 2-second timeout protection
safe_modprobe() {
    local mod="$1"
    [[ -z "$mod" ]] && return 0
    # Inside containers, kernel modules cannot and must not be loaded directly
    if is_container; then
        return 0
    fi
    # If already loaded in /proc/modules, skip to avoid redundant fork/modprobe
    if grep -q "^${mod//-/_} " /proc/modules 2>/dev/null; then
        return 0
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 1s 2 modprobe -q "$mod" 2>/dev/null || true
    fi
}

# Safely unload kernel module with container check and 2-second timeout protection
safe_modprobe_r() {
    local mod="$1"
    [[ -z "$mod" ]] && return 0
    if is_container; then
        return 0
    fi
    if ! grep -q "^${mod//-/_} " /proc/modules 2>/dev/null; then
        return 0
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 1s 2 modprobe -q -r "$mod" 2>/dev/null || true
    fi
}

# Kernel modules: Linux kernel autoloads sch_htb and cls_u32 automatically via netlink on demand.
# Proactive manual modprobe loops cause hangs on virtualized / cloud kernels and are bypassed.
ensure_kernel_modules() {
    return 0
}

# Automatically install required packages if missing (cached check)
ensure_dependencies() {
    if [[ $DEPS_VERIFIED -eq 1 ]]; then
        return 0
    fi
    local needed=()
    command -v tc >/dev/null 2>&1 || needed+=("iproute2")
    command -v sqlite3 >/dev/null 2>&1 || needed+=("sqlite3")

    if [[ ${#needed[@]} -gt 0 ]]; then
        log_info "Installing prerequisite packages (${needed[*]})..."
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        if command -v apt-get >/dev/null 2>&1; then
            if command -v timeout >/dev/null 2>&1; then
                timeout 15 apt-get update -qq >/dev/null 2>&1 || true
                timeout 30 apt-get install -y -qq -o DPkg::Lock::Timeout=10 "${needed[@]}" >/dev/null 2>&1 || true
            else
                apt-get update -qq >/dev/null 2>&1 || true
                apt-get install -y -qq -o DPkg::Lock::Timeout=10 "${needed[@]}" >/dev/null 2>&1 || true
            fi
        fi
        log_info "Prerequisite packages checked."
    fi

    # Only mark verified if critical binaries actually exist
    if command -v tc >/dev/null 2>&1 && command -v sqlite3 >/dev/null 2>&1; then
        DEPS_VERIFIED=1
    else
        log_warn "Some required tools (tc or sqlite3) could not be verified."
    fi
}

# Automatically detect WAN interface, with in-memory caching to avoid repeated ip/awk calls
detect_wan_interface() {
    if [[ -n "$WAN_INTERFACE" ]] && ip link show "$WAN_INTERFACE" >/dev/null 2>&1; then
        echo "$WAN_INTERFACE"
        return 0
    fi

    # [FIX-L4] Cache WAN interface with 300s TTL; re-evaluate routing when cache expires or link drops
    local now
    now=$(date +%s 2>/dev/null || echo 0)
    if [[ -n "$CACHED_WAN_IFACE" && $((now - CACHED_WAN_TIME)) -ge 0 && $((now - CACHED_WAN_TIME)) -lt 300 ]] && ip link show "$CACHED_WAN_IFACE" >/dev/null 2>&1; then
        echo "$CACHED_WAN_IFACE"
        return 0
    fi

    local iface
    # Priority 1: Default IPv4 route
    iface=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    # Priority 1b: Default IPv6 route if IPv4 default route absent
    if [[ -z "$iface" ]]; then
        iface=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    fi
    # Priority 2: Active physical links excluding virtual devices (local, instantaneous)
    if [[ -z "$iface" ]]; then
        iface=$(ip -br link 2>/dev/null | awk '$2=="UP" && $1!="lo" && !($1~/^(ifb|docker|br-|veth|tun|tap|wg)/){print $1; exit}')
    fi
    # Priority 3: Outbound route with strict 1s timeout
    if [[ -z "$iface" ]]; then
        if command -v timeout >/dev/null 2>&1; then
            iface=$(timeout 1 ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
        fi
    fi
    CACHED_WAN_IFACE="$iface"
    CACHED_WAN_TIME="$now"
    echo "$iface"
}

# Safely extract active inbounds from 3X-UI SQLite database with busy lock handling and C-level port filtering
get_active_ports() {
    if [[ ! -f "$DB_PATH" ]]; then
        log_warn "3X-UI database file not found at: $DB_PATH"
        return 1
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        ensure_dependencies
    fi

    local min_p="${MIN_PORT:-10000}"
    [[ "$min_p" =~ ^[0-9]+$ ]] || min_p=10000
    # Filter, deduplicate, and sort by port directly in SQLite query to minimize data and CPU overhead
    local raw_ports
    raw_ports=$(sqlite3 -readonly "$DB_PATH" "PRAGMA busy_timeout = 2000; SELECT DISTINCT port FROM inbounds WHERE enable = 1 AND port >= $min_p AND port <= 65535 ORDER BY port ASC;" 2>/dev/null)
    local sqlite_status=$?

    if [[ $sqlite_status -ne 0 ]]; then
        log_warn "SQLite database is busy or inaccessible (exit code: $sqlite_status). Skipping changes."
        return 2
    fi

    if [[ -z "$raw_ports" ]]; then
        echo ""
        return 0
    fi

    declare -A exc_map=()
    if [[ -n "$EXCLUDE_PORTS" ]]; then
        local exc_array
        IFS=',' read -ra exc_array <<< "$EXCLUDE_PORTS"
        for exc in "${exc_array[@]}"; do
            exc="${exc// /}"
            [[ -n "$exc" ]] && exc_map["$exc"]=1
        done
    fi

    local filtered=()
    while read -r p; do
        p="${p//[[:space:]]/}"
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= min_p && p <= 65535 )); then
            if [[ -z "${exc_map[$p]:-}" ]]; then
                filtered+=("$p")
            fi
        fi
    done <<< "$raw_ports"

    if [[ ${#filtered[@]} -gt 0 ]]; then
        printf "%s\n" "${filtered[@]}"
    fi
}

# [FIX-ST1] Centralized parser for CUSTOM_LIMITS into global associative arrays.
# Declares and populates globals: custom_down_map, custom_up_map
# Eliminates identical inline parsing blocks duplicated across apply_rules, show_status, and get_port_limits.
_load_custom_limits_maps() {
    declare -g -A custom_down_map custom_up_map
    custom_down_map=()
    custom_up_map=()
    [[ -z "$CUSTOM_LIMITS" ]] && return 0
    local c_arr entry cp cd cu val_cd val_cu
    IFS=',' read -ra c_arr <<< "$CUSTOM_LIMITS"
    for entry in "${c_arr[@]}"; do
        entry="${entry// /}"
        [[ -z "$entry" ]] && continue
        IFS=':' read -r cp cd cu <<< "$entry"
        [[ -z "$cp" ]] && continue
        val_cd=$(validate_rate "$cd" 2>/dev/null) && custom_down_map["$cp"]="$val_cd"
        val_cu=$(validate_rate "$cu" 2>/dev/null) && custom_up_map["$cp"]="$val_cu"
    done
}

# Get rate limits for a specific port (custom override or default, zero-fork pure bash)
get_port_limits() {
    local port="$1"
    _load_custom_limits_maps
    local down="${custom_down_map[$port]:-$DOWNLOAD_LIMIT}"
    local up="${custom_up_map[$port]:-$UPLOAD_LIMIT}"

    local norm_d norm_u
    norm_d=$(validate_rate "$down") || norm_d="10mbit"
    norm_u=$(validate_rate "$up") || norm_u="10mbit"
    echo "$norm_d $norm_u"
}

# (IFB virtual device approach removed — direct ingress policing used instead)

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
    if [[ -d "/sys/class/net/$IFB_DEVICE" ]] || ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
        tc qdisc del dev "$IFB_DEVICE" ingress 2>/dev/null || true
        ip link set dev "$IFB_DEVICE" down 2>/dev/null || true
        ip link delete "$IFB_DEVICE" type ifb 2>/dev/null || true
        safe_modprobe_r ifb
    fi

    rm -f "$STATE_FILE"
    log_info "All traffic control limits have been cleared successfully."
}

# Internal implementation of rule application (called exclusively with lock held)
_apply_rules_locked() {
    log_info "Detecting active network interface..."
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
    log_info "Querying active inbounds from 3X-UI database..."

    local raw_ports
    raw_ports=$(get_active_ports 2>/dev/null)
    local get_ports_status=$?
    if [[ $get_ports_status -ne 0 ]]; then
        log_warn "Database is currently busy or unreachable (exit code: $get_ports_status). Preserving existing tc rules."
        return 0
    fi

    local active_ports=()
    if [[ -n "$raw_ports" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && active_ports+=("$line")
        done <<< "$raw_ports"
    fi

    if [[ ${#active_ports[@]} -eq 0 ]]; then
        local total_inbounds
        total_inbounds=$(sqlite3 -readonly "$DB_PATH" "PRAGMA busy_timeout = 2000; SELECT count(*) FROM inbounds WHERE enable = 1;" 2>/dev/null || echo 0)
        if (( total_inbounds > 0 )); then
            # [FIX-L1] Inbounds exist but are ALL below MIN_PORT — preserve existing tc rules.
            # Clearing rules here would briefly expose traffic during config changes.
            log_warn "Found $total_inbounds active inbound(s) in 3X-UI database, but ALL of them have port < ${MIN_PORT:-10000}."
            log_warn "Ports below ${MIN_PORT:-10000} are completely exempt from rate limits by your setting."
            log_warn "If your test port is < ${MIN_PORT:-10000}, change the Min Port filter in Menu Option 3 (or enter 0 to include all ports)."
            log_warn "Existing tc rules preserved — no changes made."
            return 0
        else
            log_warn "No active inbound ports found in 3X-UI database matching criteria (>= ${MIN_PORT:-10000})."
            clear_rules
            return 0
        fi
    fi

    log_info "Active controlled ports (${#active_ports[@]}): ${GREEN}${active_ports[*]}${NC}"

    # Cleanly remove any residual IFB device to eliminate /proc/net/dev traffic multiplication
    if [[ -d "/sys/class/net/$IFB_DEVICE" ]] || ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
        tc qdisc del dev "$IFB_DEVICE" ingress 2>/dev/null || true
        ip link set dev "$IFB_DEVICE" down 2>/dev/null || true
        ip link delete "$IFB_DEVICE" type ifb 2>/dev/null || true
        safe_modprobe_r ifb
    fi

    # Reset existing root and ingress qdiscs on physical WAN interface cleanly
    tc filter del dev "$iface" parent ffff: 2>/dev/null || true
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc del dev "$iface" ingress 2>/dev/null || true

    # 1. Egress root qdisc on physical WAN interface (Client Download - traffic leaving server)
    # Default class 1:999 handles unclassified/system traffic (SSH, web, non-limited ports) at line rate (10 Gbps)
    if ! tc qdisc replace dev "$iface" root handle 1: htb default 999 2>/dev/null; then
        safe_modprobe sch_htb
        if ! tc qdisc replace dev "$iface" root handle 1: htb default 999 2>/dev/null; then
            log_error "Failed to create root HTB queue on WAN interface '$iface'!"
            log_error "Kernel module 'sch_htb' is missing or not supported on this kernel."
            log_error "To install on Ubuntu/Debian, run: sudo apt-get install -y linux-modules-extra-\$(uname -r)"
            return 1
        fi
    fi

    # Default class 1:999 attached directly to root 1: (unthrottled default for system traffic)
    tc class replace dev "$iface" parent 1: classid 1:999 htb rate 10000mbit ceil 10000mbit 2>/dev/null || \
    tc class add dev "$iface" parent 1: classid 1:999 htb rate 10000mbit ceil 10000mbit 2>/dev/null || true

    # Probe leaf qdisc support once on class 1:999
    local leaf_qdisc="fq_codel"
    if ! tc qdisc replace dev "$iface" parent 1:999 handle 999: fq_codel 2>/dev/null; then
        tc qdisc replace dev "$iface" parent 1:999 handle 999: sfq perturb 10 2>/dev/null || true
        leaf_qdisc="sfq perturb 10"
    fi

    # 2. Ingress root qdisc directly on physical WAN interface (Client Upload - traffic entering server)
    # Uses direct kernel Ingress Policing (zero virtual devices, zero /proc/net/dev duplication, zero kernel retransmissions)
    tc qdisc replace dev "$iface" handle ffff: ingress 2>/dev/null || \
    tc qdisc add dev "$iface" handle ffff: ingress 2>/dev/null || true
    tc filter del dev "$iface" parent ffff: 2>/dev/null || true

    # [FIX-ST1] Use shared helper to parse custom limits (eliminates code duplication)
    _load_custom_limits_maps

    # 3. Generate batch rules in memory for high-performance atomic execution
    local burst_val="${BURST:-128k}"
    local batch_rules=""
    local idx=1
    for port in "${active_ports[@]}"; do
        local class_minor=$((idx + 10))
        local class_id="1:$class_minor"
        local qdisc_handle="${class_minor}:"

        local port_down="${custom_down_map[$port]:-$norm_down}"
        local port_up="${custom_up_map[$port]:-$norm_up}"

        # --- Egress shaping (Download): attached directly to parent 1: (no token borrowing, strictly capped) ---
        batch_rules+="class add dev $iface parent 1: classid $class_id htb rate $port_down ceil $port_down burst $burst_val cburst $burst_val"$'\n'
        batch_rules+="qdisc add dev $iface parent $class_id handle $qdisc_handle $leaf_qdisc"$'\n'
        # Match IPv4 TCP & UDP via sport
        batch_rules+="filter add dev $iface protocol ip parent 1: prio 1 u32 match ip sport $port 0xffff flowid $class_id"$'\n'
        # Match IPv6 TCP & UDP via sport (offset 40)
        batch_rules+="filter add dev $iface protocol ipv6 parent 1: prio 2 u32 match u16 $port 0xffff at 40 flowid $class_id"$'\n'

        # --- Ingress direct policing (Upload): per-port hardware line-rate rate limiting ---
        # Match IPv4 TCP & UDP via dport on ingress
        batch_rules+="filter add dev $iface parent ffff: protocol ip prio $idx u32 match ip dport $port 0xffff police rate $port_up burst $burst_val drop flowid :1"$'\n'
        # Match IPv6 TCP & UDP via dport on ingress (offset 42)
        batch_rules+="filter add dev $iface parent ffff: protocol ipv6 prio $((idx + 5000)) u32 match u16 $port 0xffff at 42 police rate $port_up burst $burst_val drop flowid :1"$'\n'

        idx=$((idx + 1))
    done

    # [FIX-S4] Directory already created atomically by flock section above
    # [FIX-S3] Remove predictable PID-based fallback name — fail explicitly if mktemp fails
    local batch_file
    batch_file=$(mktemp /run/port-limit/batch.XXXXXX 2>/dev/null || mktemp /tmp/port_limit_batch.XXXXXX 2>/dev/null)
    if [[ -z "$batch_file" ]]; then
        log_error "Failed to create a secure temporary file for tc batch rules. Aborting."
        return 1
    fi
    printf "%s\n" "$batch_rules" > "$batch_file"

    local batch_err
    if ! batch_err=$(tc -force -batch "$batch_file" 2>&1); then
        log_warn "tc batch mode failed — falling back to sequential execution:"
        log_warn "$batch_err"
        # [FIX-S2] Use array expansion to handle arguments safely instead of unquoted $cmd
        local tc_args
        while IFS= read -r cmd; do
            if [[ -n "$cmd" ]]; then
                read -ra tc_args <<< "$cmd"
                tc "${tc_args[@]}" 2>/dev/null || true
            fi
        done < "$batch_file"
    fi
    rm -f "$batch_file"

    printf "%s\n" "${active_ports[@]}" > "$STATE_FILE"
    log_info "${GREEN}Rate limits successfully applied to all active ports.${NC}"
}

# Apply download and upload bandwidth limits for all active inbounds (lock-protected)
apply_rules() {
    log_info "Applying traffic control rate limits..."
    ensure_dependencies
    load_config

    # [FIX-L2] Acquire exclusive non-blocking lock to prevent concurrent rule application
    local lock_file="/run/port-limit/apply.lock"
    mkdir -p /run/port-limit 2>/dev/null || lock_file="/tmp/port_limit_apply.lock"
    touch "$lock_file" 2>/dev/null || true

    local lock_held=0
    if [[ -f "$lock_file" ]] && exec 9>>"$lock_file" 2>/dev/null; then
        if command -v flock >/dev/null 2>&1; then
            if ! flock -n 9 2>/dev/null; then
                log_warn "Another apply_rules instance is already running. Skipping to avoid tc race condition."
                exec 9>&- 2>/dev/null || true
                return 0
            fi
            lock_held=1
        fi
    fi

    local ret=0
    _apply_rules_locked || ret=$?

    # Always release lock and close file descriptor 9
    if [[ $lock_held -eq 1 ]] && command -v flock >/dev/null 2>&1; then
        flock -u 9 2>/dev/null || true
    fi
    exec 9>&- 2>/dev/null || true
    return $ret
}

# Format byte counts into human-readable units using pure Bash integer math (zero forks)
format_bytes() {
    local b="${1:-0}"
    if [[ ! "$b" =~ ^[0-9]+$ ]] || [[ "$b" -eq 0 ]]; then
        echo "0 B"
        return
    fi
    if (( b < 1024 )); then
        echo "${b} B"
    elif (( b < 1048576 )); then
        local kib=$(( b * 10 / 1024 ))
        echo "$(( kib / 10 )).$(( kib % 10 )) KiB"
    elif (( b < 1073741824 )); then
        local mib=$(( b * 10 / 1048576 ))
        echo "$(( mib / 10 )).$(( mib % 10 )) MiB"
    elif (( b < 1099511627776 )); then
        local gib=$(( b * 10 / 1073741824 ))
        echo "$(( gib / 10 )).$(( gib % 10 )) GiB"
    else
        # [FIX-L6] Avoid 64-bit signed overflow: divide before multiply to stay within bash integer range
        local tib=$(( (b / 1099511627776) * 10 + (b % 1099511627776) * 10 / 1099511627776 ))
        echo "$(( tib / 10 )).$(( tib % 10 )) TiB"
    fi
}

# Display system status and real-time bandwidth consumption statistics
show_status() {
    load_config
    local iface
    iface=$(detect_wan_interface)

    local s_status="${RED}● Inactive${NC}"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        s_status="${GREEN}● Active (Running)${NC}"
    fi

    local _interval_label
    if (( CHECK_INTERVAL >= 3600 )); then
        _interval_label="$(( CHECK_INTERVAL / 3600 ))h"
    elif (( CHECK_INTERVAL >= 60 )); then
        _interval_label="$(( CHECK_INTERVAL / 60 ))m"
    else
        _interval_label="${CHECK_INTERVAL}s"
    fi

    echo -e "${CYAN}╭───────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│${NC}   ${BOLD}${WHITE}📊 3X-UI Inbound Ports Real-Time Traffic & Rate Limits (v${VERSION})${NC}   ${CYAN}│${NC}"
    echo -e "${CYAN}╰───────────────────────────────────────────────────────────────────╯${NC}"
    echo -e " ${BOLD}${WHITE}System Overview${NC}"
    echo -e "   ${CYAN}●${NC} Service Status : $s_status"
    echo -e "   ${CYAN}●${NC} WAN Interface  : ${YELLOW}${iface:-Unknown}${NC}"
    echo -e "   ${CYAN}●${NC} Default Limits : ↓ ${GREEN}$DOWNLOAD_LIMIT${NC} (Download) │ ↑ ${GREEN}$UPLOAD_LIMIT${NC} (Upload)"
    echo -e "   ${CYAN}●${NC} Port Filter    : ${YELLOW}>= ${MIN_PORT}${NC} ${GRAY}(Ports < ${MIN_PORT} are exempt)${NC}"
    echo -e "   ${CYAN}●${NC} Excluded Ports : ${MAGENTA}${EXCLUDE_PORTS:-None}${NC}"
    echo -e "   ${CYAN}●${NC} Check Interval : ${CYAN}${CHECK_INTERVAL}s (${_interval_label})${NC}"
    echo -e "   ${CYAN}●${NC} Panel Database : ${GRAY}$DB_PATH${NC}"
    echo ""

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
        echo -e "  ${YELLOW}ℹ No active inbound ports found or limits have not been applied yet.${NC}\n"
        return 0
    fi

    echo -e "${CYAN}┌──────────┬──────────────┬──────────────┬──────────────────┬──────────────────┐${NC}"
    printf "${CYAN}│${NC} ${BOLD}%-8s${NC} ${CYAN}│${NC} ${BOLD}%-12s${NC} ${CYAN}│${NC} ${BOLD}%-12s${NC} ${CYAN}│${NC} ${BOLD}%-16s${NC} ${CYAN}│${NC} ${BOLD}%-16s${NC} ${CYAN}│${NC}\n" "Port" "Download" "Upload" "Egress (Sent)" "Ingress (Recv)"
    echo -e "${CYAN}├──────────┼──────────────┼──────────────┼──────────────────┼──────────────────┤${NC}"

    # [FIX-ST1] Use shared helper to parse custom limits (eliminates code duplication)
    _load_custom_limits_maps

    # Batch query traffic statistics once (replaces hundreds of per-port forks)
    declare -A egress_bytes ingress_bytes
    local cur_cls=""

    if [[ -n "$iface" ]]; then
        local raw_egress
        raw_egress=$(LC_ALL=C tc -s class show dev "$iface" 2>/dev/null)
        while IFS= read -r line; do
            if [[ "$line" =~ class[[:space:]]+[^[:space:]]+[[:space:]]+([0-9]+:[0-9]+) ]]; then
                cur_cls="${BASH_REMATCH[1]}"
            elif [[ -n "$cur_cls" && "$line" =~ Sent[[:space:]]+([0-9]+)[[:space:]]+bytes ]]; then
                egress_bytes["$cur_cls"]="${BASH_REMATCH[1]}"
                cur_cls=""
            fi
        done <<< "$raw_egress"
        local raw_ingress
        raw_ingress=$(LC_ALL=C tc -s filter show dev "$iface" parent ffff: 2>/dev/null)
        local cur_prio=""
        while IFS= read -r line; do
            if [[ "$line" =~ (pref|prio)[[:space:]]+([0-9]+) ]]; then
                cur_prio="${BASH_REMATCH[2]}"
            elif [[ -n "$cur_prio" && "$line" =~ Sent[[:space:]]+([0-9]+)[[:space:]]+bytes ]]; then
                local prev="${ingress_bytes[$cur_prio]:-0}"
                ingress_bytes["$cur_prio"]=$(( prev + BASH_REMATCH[1] ))
                cur_prio=""
            fi
        done <<< "$raw_ingress"
    fi

    if [[ -d "/sys/class/net/$IFB_DEVICE" ]]; then
        local raw_ifb
        raw_ifb=$(LC_ALL=C tc -s class show dev "$IFB_DEVICE" 2>/dev/null)
        cur_cls=""
        while IFS= read -r line; do
            if [[ "$line" =~ class[[:space:]]+[^[:space:]]+[[:space:]]+([0-9]+:[0-9]+) ]]; then
                cur_cls="${BASH_REMATCH[1]}"
            elif [[ -n "$cur_cls" && "$line" =~ Sent[[:space:]]+([0-9]+)[[:space:]]+bytes ]]; then
                ingress_bytes["$cur_cls"]="${BASH_REMATCH[1]}"
                cur_cls=""
            fi
        done <<< "$raw_ifb"
    fi

    local norm_d norm_u
    norm_d=$(validate_rate "$DOWNLOAD_LIMIT") || norm_d="10mbit"
    norm_u=$(validate_rate "$UPLOAD_LIMIT") || norm_u="10mbit"

    local idx=1
    for port in "${active_ports[@]}"; do
        local class_minor=$((idx + 10))
        local class_id="1:$class_minor"

        local port_down="${custom_down_map[$port]:-$norm_d}"
        local port_up="${custom_up_map[$port]:-$norm_u}"

        local down_bytes
        down_bytes=$(format_bytes "${egress_bytes[$class_id]:-0}")
        # [FIX-L3] Removed dead $class_id lookup: ingress_bytes is keyed by prio (integer), not class_id string
        local up_count=$(( ${ingress_bytes[$idx]:-0} + ${ingress_bytes[$((idx + 5000))]:-0} ))
        local up_bytes
        up_bytes=$(format_bytes "$up_count")

        printf "${CYAN}│${NC} ${CYAN}%-8s${NC} ${CYAN}│${NC} ${GREEN}%-12s${NC} ${CYAN}│${NC} ${GREEN}%-12s${NC} ${CYAN}│${NC} %-16s ${CYAN}│${NC} %-16s ${CYAN}│${NC}\n" "$port" "$port_down" "$port_up" "$down_bytes" "$up_bytes"
        idx=$((idx + 1))
    done
    echo -e "${CYAN}└──────────┴──────────────┴──────────────┴──────────────────┴──────────────────┘${NC}"
}

# Generate a fingerprint string of current config parameters to track modifications
get_config_state_string() {
    echo "${DOWNLOAD_LIMIT}|${UPLOAD_LIMIT}|${CHECK_INTERVAL}|${EXCLUDE_PORTS}|${MIN_PORT}|${CUSTOM_LIMITS}|${BURST}|${WAN_INTERFACE}|${DB_PATH}"
}

# Daemon loop to automatically detect database additions/removals and config changes
run_monitor() {
    log_info "3X-UI auto-detector daemon started (interval: ${CHECK_INTERVAL}s)..."
    # [FIX-ST6] Write PID for targeted termination in uninstall — avoids broad pkill -f pattern
    install -d -m 700 /run/port-limit 2>/dev/null || true
    echo $$ > /run/port-limit/daemon.pid 2>/dev/null || true
    trap 'rm -f /run/port-limit/daemon.pid 2>/dev/null; log_info "Termination signal received. Exiting monitor daemon."; exit 0' SIGINT SIGTERM

    apply_rules
    local raw_p
    raw_p=$(get_active_ports 2>/dev/null)
    local last_ports="${raw_p//$'\n'/ }"
    local last_cfg_state
    last_cfg_state=$(get_config_state_string)

    while true; do
        sleep "$CHECK_INTERVAL"

        load_config
        local current_cfg_state
        current_cfg_state=$(get_config_state_string)

        raw_p=$(get_active_ports 2>/dev/null)
        local status_code=$?

        # Skip iteration if database was temporarily busy or unreachable
        if [[ $status_code -ne 0 ]]; then
            continue
        fi

        local current_ports="${raw_p//$'\n'/ }"

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

# Save settings to configuration file with restricted file permissions atomically
save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    local tmp_conf="${CONFIG_FILE}.tmp.$$"
    cat << EOF > "$tmp_conf"
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
    chmod 600 "$tmp_conf" 2>/dev/null || true
    mv -f "$tmp_conf" "$CONFIG_FILE" 2>/dev/null || cat "$tmp_conf" > "$CONFIG_FILE"
    rm -f "$tmp_conf" 2>/dev/null || true
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

    if ! is_container; then
        mkdir -p /etc/modules-load.d
        # Load only modules required for HTB egress + direct ingress policing
        cat <<'EOF' > /etc/modules-load.d/port-limit-tc.conf
sch_htb
cls_u32
sch_fq_codel
EOF
    fi
    # Remove any old IFB-related config left from previous versions
    rm -f /etc/modprobe.d/port-limit-ifb.conf 2>/dev/null || true

    # Resolve physical canonical path of the script
    local real_source
    real_source=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")
    local target_src="$real_source"
    [[ ! -f "$target_src" ]] && target_src="$0"

    # If executed via pipe or process substitution (/dev/fd/*)
    if [[ "$target_src" =~ ^/dev/fd/ || "$target_src" =~ ^/proc/ || ! -f "$target_src" ]]; then
        if [[ -f "$INSTALL_PATH" && -s "$INSTALL_PATH" ]]; then
            log_info "Using existing binary installation at: $INSTALL_PATH"
            target_src="$INSTALL_PATH"
        else
            echo -e "\n${YELLOW}[ATTENTION] The script was executed directly from memory via pipe (bash <(curl ...)).${NC}"
            echo -e "${YELLOW}A permanent file on disk is required for the systemd service (${INSTALL_PATH}).${NC}\n"
            read -rp "Please enter the download URL to save to disk [or press Enter to cancel]: " dl_url
            if [[ -n "$dl_url" ]] && command -v curl >/dev/null 2>&1; then
                # Validate URL starts with https:// for security
                if [[ ! "$dl_url" =~ ^https:// ]]; then
                    log_error "URL must start with https:// for security. Aborting."
                    return 1
                fi
                log_info "Downloading script from $dl_url to $INSTALL_PATH..."
                if curl -fsSL "$dl_url" -o "${INSTALL_PATH}.tmp" && [[ -s "${INSTALL_PATH}.tmp" ]]; then
                    # [FIX-S7] Verify downloaded file integrity and bash syntax before replacing binary
                    local first_line
                    first_line=$(head -n 1 "${INSTALL_PATH}.tmp" 2>/dev/null || true)
                    if [[ ! "$first_line" =~ ^#!(/usr)?/bin/(env[[:space:]]+)?bash ]]; then
                        log_error "Downloaded file does not have a valid bash shebang. Installation aborted."
                        rm -f "${INSTALL_PATH}.tmp"
                        return 1
                    fi
                    if ! bash -n "${INSTALL_PATH}.tmp" 2>/dev/null; then
                        log_error "Downloaded script failed bash syntax verification (bash -n). Installation aborted."
                        rm -f "${INSTALL_PATH}.tmp"
                        return 1
                    fi
                    chmod 755 "${INSTALL_PATH}.tmp"
                    mv -f "${INSTALL_PATH}.tmp" "$INSTALL_PATH"
                    target_src="$INSTALL_PATH"
                    log_info "Script successfully verified and saved to $INSTALL_PATH."
                else
                    log_error "Failed to download script from $dl_url."
                    rm -f "${INSTALL_PATH}.tmp"
                    return 1
                fi
            else
                log_error "Source script ($target_src) cannot be installed from a memory pipe."
                echo -e "${CYAN}Please download the script to your server first, for example:${NC}"
                echo -e "  ${BOLD}curl -sSL <YOUR_RAW_URL> -o port_limit.sh && chmod +x port_limit.sh && sudo ./port_limit.sh${NC}\n"
                return 1
            fi
        fi
    fi

    if [[ "$target_src" != "$INSTALL_PATH" ]]; then
        cp -f "$target_src" "${INSTALL_PATH}.tmp"
        chmod 755 "${INSTALL_PATH}.tmp"
        mv -f "${INSTALL_PATH}.tmp" "$INSTALL_PATH"
    fi

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
    echo -e "${GREEN}╭───────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${GREEN}│${NC}  ${BOLD}${WHITE}✓ Script installed and systemd service activated successfully! 🎉${NC}  ${GREEN}│${NC}"
    echo -e "${GREEN}╰───────────────────────────────────────────────────────────────────╯${NC}"
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

    # 2. [FIX-ST6] Terminate daemon via PID file to avoid accidentally killing unrelated processes
    if [[ -f /run/port-limit/daemon.pid ]]; then
        local _dpid
        _dpid=$(cat /run/port-limit/daemon.pid 2>/dev/null)
        if [[ "$_dpid" =~ ^[0-9]+$ ]]; then
            kill "$_dpid" 2>/dev/null || true
        fi
        rm -f /run/port-limit/daemon.pid 2>/dev/null || true
    fi
    # Fallback: exact-name match only (much safer than pkill -f pattern)
    pkill -x "port-limit" 2>/dev/null || true

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
    rm -f /etc/modules-load.d/ifb.conf /etc/modules-load.d/port-limit-tc.conf /etc/modprobe.d/port-limit-ifb.conf 2>/dev/null || true
    safe_modprobe_r ifb || rmmod ifb 2>/dev/null || true

    # 7. Clean up any crontab or cron file remnants
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "port-limit" | crontab - 2>/dev/null || true
    fi
    rm -f /etc/cron.d/port-limit /etc/cron.daily/port-limit /etc/cron.hourly/port-limit 2>/dev/null || true

    # 8. Clean up all configuration, state, temporary, and executable files
    rm -f "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
    rm -f "$STATE_FILE" /run/port-limit* 2>/dev/null || true
    rm -f "$INSTALL_PATH" "${INSTALL_PATH}.tmp" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}╭───────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${GREEN}│${NC}  ${BOLD}${WHITE}✓ Port-Limit and all associated components completely uninstalled!${NC} ${GREEN}│${NC}"
    echo -e "${GREEN}╰───────────────────────────────────────────────────────────────────╯${NC}"
}

# ------------------------------------------------------------------------------
# Terminal User Interface (Interactive Menus & Navigation)
# ------------------------------------------------------------------------------

# Dedicated Submenu for Custom Per-Port Bandwidth Limits
menu_custom_limits() {
    while true; do
        clear
        echo -e "${CYAN}╭───────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "${CYAN}│${NC}          ${BOLD}${WHITE}⚡ Custom Per-Port Speed Limits Management ⚡${NC}             ${CYAN}│${NC}"
        echo -e "${CYAN}╰───────────────────────────────────────────────────────────────────╯${NC}"
        echo -e " ${BOLD}${WHITE}Configured Custom Limits${NC}"
        if [[ -n "$CUSTOM_LIMITS" ]]; then
            IFS=',' read -ra c_arr <<< "$CUSTOM_LIMITS"
            for entry in "${c_arr[@]}"; do
                entry="${entry// /}"
                [[ -z "$entry" ]] && continue
                local cp cd cu _rest
                IFS=':' read -r cp cd cu _rest <<< "$entry"
                echo -e "   ${CYAN}•${NC} Port ${BOLD}${CYAN}$cp${NC} ➔ Down: ${GREEN}$cd${NC} │ Up: ${GREEN}$cu${NC}"
            done
        else
            echo -e "   ${GRAY}(No custom limits configured - all inbounds use default limits)${NC}"
        fi
        echo ""
        echo -e " ${BOLD}${BLUE}Actions${NC}"
        echo -e "   ${BOLD}${GREEN}[1]${NC} Add or update custom speed limit for a port"
        echo -e "   ${BOLD}${YELLOW}[2]${NC} Remove custom limit for a specific port"
        echo -e "   ${BOLD}${RED}[3]${NC} Clear all custom limits"
        echo -e "   ${BOLD}[0]${NC} Back to Main Menu"
        echo -e "${CYAN}─────────────────────────────────────────────────────────────────────${NC}"
        echo -ne "${CYAN}❯ ${WHITE}Select an option ${GRAY}[0-3]${WHITE}: ${GREEN}"
        read -r sub_choice
        echo -ne "${NC}"

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
                        item="${item// /}"
                        [[ -z "$item" ]] && continue
                        local item_p="${item%%:*}"
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
                echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to continue...${NC}"
                read -r _
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
                    item="${item// /}"
                    [[ -z "$item" ]] && continue
                    local item_p="${item%%:*}"
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
                echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to continue...${NC}"
                read -r _
                ;;
            3)
                echo ""
                echo -e "${YELLOW}╭───────────────────────────────────────────────────────────────────╮${NC}"
                echo -e "${YELLOW}│${NC}   ${BOLD}${YELLOW}⚠️  Are you sure you want to clear ALL custom per-port limits?   │${NC}"
                echo -e "${YELLOW}╰───────────────────────────────────────────────────────────────────╯${NC}"
                echo -e "   ${BOLD}${RED}[1]${NC} Confirm and clear all"
                echo -e "   ${BOLD}[0]${NC} Cancel and return"
                echo -e "${YELLOW}─────────────────────────────────────────────────────────────────────${NC}"
                echo -ne "${YELLOW}❯ ${WHITE}Select an option ${GRAY}[0-1]${WHITE}: ${GREEN}"
                read -r clr_cust
                echo -ne "${NC}"
                if [[ "$clr_cust" == "1" ]]; then
                    CUSTOM_LIMITS=""
                    save_config
                    log_info "All custom limits cleared."
                    apply_rules
                    echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to continue...${NC}"
                    read -r _
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
        echo -e "${CYAN}╭───────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "${CYAN}│${NC}            ${BOLD}${WHITE}🛡️  Configure Port Filtering & Exclusions 🛡️             ${CYAN}│${NC}"
        echo -e "${CYAN}╰───────────────────────────────────────────────────────────────────╯${NC}"
        echo -e " ${BOLD}${WHITE}Filter Rules${NC}"
        echo -e "   ${CYAN}●${NC} Minimum Controlled Port : ${YELLOW}>= ${MIN_PORT}${NC} ${GRAY}(Ports < ${MIN_PORT} are exempt)${NC}"
        echo -e "   ${CYAN}●${NC} Excluded Ports List     : ${MAGENTA}${EXCLUDE_PORTS:-None}${NC}"
        echo ""
        echo -e " ${BOLD}${BLUE}Configuration Actions${NC}"
        echo -e "   ${BOLD}${GREEN}[1]${NC} Change minimum port threshold ${GRAY}(Current: >= ${MIN_PORT})${NC}"
        echo -e "   ${BOLD}${YELLOW}[2]${NC} Configure excluded ports list ${GRAY}(e.g. 22,2053)${NC}"
        echo -e "   ${BOLD}[0]${NC} Back to Main Menu"
        echo -e "${CYAN}─────────────────────────────────────────────────────────────────────${NC}"
        echo -ne "${CYAN}❯ ${WHITE}Select an option ${GRAY}[0-2]${WHITE}: ${GREEN}"
        read -r pf_choice
        echo -ne "${NC}"

        case "$pf_choice" in
            1)
                echo ""
                echo -e "Current minimum port threshold: ${YELLOW}>= ${MIN_PORT}${NC}"
                echo -e "${GRAY}(Inbound ports below this number will never have rate limits applied)${NC}"
                echo -e "${GRAY}(Enter 0 to apply rate limits to ALL ports with no minimum threshold)${NC}"
                read -rp "Enter new minimum port (0-65535) ['b' to cancel]: " inp_min
                if [[ "$inp_min" == "b" || "$inp_min" == "B" || -z "$inp_min" ]]; then
                    echo -e "${YELLOW}Cancelled.${NC}"
                    sleep 0.5
                    continue
                fi
                if [[ "$inp_min" =~ ^[0-9]+$ ]] && (( inp_min >= 0 && inp_min <= 65535 )); then
                    MIN_PORT="$inp_min"
                    save_config
                    log_info "Minimum port threshold set to: >= $MIN_PORT"
                    apply_rules
                else
                    echo -e "${RED}[ERROR] Invalid port number. Must be between 0 and 65535.${NC}"
                fi
                echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to continue...${NC}"
                read -r _
                ;;
            2)
                echo ""
                echo -e "Current excluded ports: ${MAGENTA}${EXCLUDE_PORTS:-None}${NC}"
                echo -e "${GRAY}(Enter '0' or 'b' to cancel and return, or 'none' to clear)${NC}\n"
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
                echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to continue...${NC}"
                read -r _
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
        local s_status="${RED}● Inactive${NC}"
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            s_status="${GREEN}● Active (Running)${NC}"
        fi

        local _ci_label
        if (( CHECK_INTERVAL >= 3600 )); then _ci_label="$(( CHECK_INTERVAL / 3600 ))h"
        elif (( CHECK_INTERVAL >= 60 )); then  _ci_label="$(( CHECK_INTERVAL / 60 ))m"
        else                                    _ci_label="${CHECK_INTERVAL}s"
        fi

        echo -e "${CYAN}╭───────────────────────────────────────────────────────────────────╮${NC}"
        echo -e "${CYAN}│${NC}     ${BOLD}${WHITE}⚡ 3X-UI Inbound Port Rate Limiter — PortLimit (v${VERSION}) ⚡${NC}     ${CYAN}│${NC}"
        echo -e "${CYAN}╰───────────────────────────────────────────────────────────────────╯${NC}"
        echo -e " ${BOLD}${WHITE}System Overview${NC}"
        echo -e "   ${CYAN}●${NC} Service State : $s_status"
        echo -e "   ${CYAN}●${NC} Default Limits: ↓ ${GREEN}$DOWNLOAD_LIMIT${NC} (Down) │ ↑ ${GREEN}$UPLOAD_LIMIT${NC} (Up)"
        echo -e "   ${CYAN}●${NC} Port Filter   : ${YELLOW}>= ${MIN_PORT}${NC} ${GRAY}(Ports < ${MIN_PORT} exempt)${NC}"
        echo -e "   ${CYAN}●${NC} Excluded Ports: ${MAGENTA}${EXCLUDE_PORTS:-None}${NC}"
        echo -e "   ${CYAN}●${NC} Sync Interval : ${CYAN}${CHECK_INTERVAL}s (${_ci_label})${NC}"
        echo ""
        echo -e " ${BOLD}${BLUE}📊 Traffic & Inbound Control${NC}"
        echo -e "   ${BOLD}${GREEN}[1]${NC} View traffic stats & real-time usage ${GRAY}(Status)${NC}"
        echo -e "   ${BOLD}${GREEN}[2]${NC} Change default download & upload speed limits"
        echo -e "   ${BOLD}${GREEN}[3]${NC} Configure port filtering & exclusions ${GRAY}(Min: >= ${MIN_PORT})${NC}"
        echo -e "   ${BOLD}${GREEN}[4]${NC} Configure custom per-port speed limits ${GRAY}(Custom Limits)${NC}"
        echo -e "   ${BOLD}${GREEN}[5]${NC} Apply & reload traffic control rules now"
        echo ""
        echo -e " ${BOLD}${YELLOW}⚙️  Service & System Management${NC}"
        echo -e "   ${BOLD}${YELLOW}[6]${NC} Install & enable background service ${GRAY}(Systemd)${NC}"
        echo -e "   ${BOLD}${RED}[7]${NC} Clear all rate limits / unthrottle traffic ${GRAY}(Flush tc)${NC}"
        echo -e "   ${BOLD}${CYAN}[8]${NC} View live monitor daemon logs ${GRAY}(Journalctl)${NC}"
        echo -e "   ${BOLD}${RED}[9]${NC} Uninstall port-limit completely"
        echo ""
        echo -e " ${BOLD}${GRAY}🚪 Navigation${NC}"
        echo -e "   ${BOLD}[0]${NC} Exit"
        echo -e "${CYAN}─────────────────────────────────────────────────────────────────────${NC}"
        echo -ne "${CYAN}❯ ${WHITE}Please select an option ${GRAY}[0-9]${WHITE}: ${GREEN}"
        read -r choice
        echo -ne "${NC}"

        case "$choice" in
            1)
                echo ""
                show_status
                echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to return to main menu...${NC}"
                read -r _
                ;;
            2)
                echo ""
                echo -e "${CYAN}╭───────────────────────────────────────────────────────────────────╮${NC}"
                echo -e "${CYAN}│${NC}       ${BOLD}${WHITE}⚡ Change Default Download & Upload Speed Limits ⚡${NC}          ${CYAN}│${NC}"
                echo -e "${CYAN}╰───────────────────────────────────────────────────────────────────╯${NC}"
                echo -e "  Current limits: Download = ${GREEN}$DOWNLOAD_LIMIT${NC} │ Upload = ${GREEN}$UPLOAD_LIMIT${NC}"
                echo -e "  ${GRAY}(Enter '0' or 'b' at any prompt to cancel and return)${NC}\n"
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
                echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to return to main menu...${NC}"
                read -r _
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
                echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to return to main menu...${NC}"
                read -r _
                ;;
            6)
                echo ""
                echo -e "${CYAN}╭───────────────────────────────────────────────────────────────────╮${NC}"
                echo -e "${CYAN}│${NC}             ${BOLD}${WHITE}🚀 Install & Enable Background Service 🚀${NC}             ${CYAN}│${NC}"
                echo -e "${CYAN}╰───────────────────────────────────────────────────────────────────╯${NC}"
                echo -e " This will configure kernel modules, install 'port-limit' to system PATH,"
                echo -e " and enable 'port-limit.service' under systemd to monitor inbounds 24/7.\n"
                echo -e "   ${BOLD}${GREEN}[1]${NC} Confirm and Install Service"
                echo -e "   ${BOLD}[0]${NC} Return to Main Menu"
                echo -e "${CYAN}─────────────────────────────────────────────────────────────────────${NC}"
                echo -ne "${CYAN}❯ ${WHITE}Select an option ${GRAY}[0-1]${WHITE}: ${GREEN}"
                read -r svc_choice
                echo -ne "${NC}"
                case "$svc_choice" in
                    1)
                        echo ""
                        install_service
                        echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to return to main menu...${NC}"
                        read -r _
                        ;;
                    *)
                        echo -e "${YELLOW}Cancelled. Returning to main menu...${NC}"
                        sleep 0.5
                        ;;
                esac
                ;;
            7)
                echo ""
                echo -e "${YELLOW}╭───────────────────────────────────────────────────────────────────╮${NC}"
                echo -e "${YELLOW}│${NC}                 ${BOLD}${YELLOW}⚠️  Clear All Traffic Rate Limits ⚠️${NC}                ${YELLOW}│${NC}"
                echo -e "${YELLOW}╰───────────────────────────────────────────────────────────────────╯${NC}"
                echo -e " This will remove all traffic control queues and unthrottle all traffic.\n"
                echo -e "   ${BOLD}${RED}[1]${NC} Confirm and Clear All Limits"
                echo -e "   ${BOLD}[0]${NC} Cancel and Return"
                echo -e "${YELLOW}─────────────────────────────────────────────────────────────────────${NC}"
                echo -ne "${YELLOW}❯ ${WHITE}Select an option ${GRAY}[0-1]${WHITE}: ${RED}"
                read -r clr_choice
                echo -ne "${NC}"
                case "$clr_choice" in
                    1)
                        echo ""
                        clear_rules
                        echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to return to main menu...${NC}"
                        read -r _
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
                echo -e "\n${GRAY}Press ${BOLD}[Enter]${NC}${GRAY} to return to main menu...${NC}"
                read -r _
                ;;
            9)
                echo ""
                echo -e "${RED}╭───────────────────────────────────────────────────────────────────╮${NC}"
                echo -e "${RED}│${NC}                 ${BOLD}${RED}🚨 Uninstall Port-Limit Completely 🚨${NC}              ${RED}│${NC}"
                echo -e "${RED}╰───────────────────────────────────────────────────────────────────╯${NC}"
                echo -e " This will stop the service, remove all traffic control rules, delete"
                echo -e " configuration files, and remove the port-limit executable.\n"
                echo -e "   ${BOLD}${RED}[1]${NC} Confirm Complete Uninstallation"
                echo -e "   ${BOLD}[0]${NC} Cancel and Return"
                echo -e "${RED}─────────────────────────────────────────────────────────────────────${NC}"
                echo -ne "${RED}❯ ${WHITE}Select an option ${GRAY}[0-1]${WHITE}: ${RED}"
                read -r uninst_choice
                echo -ne "${NC}"
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
