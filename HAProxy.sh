#!/usr/bin/env bash
#
# HAProxy IPv4 -> IPv6 Forwarder
#
# Runs on the relay server: users connect to this server's IPv4 address and
# their TCP and UDP traffic is forwarded, without any tunnel, to an IPv6
# address on the foreign server.
#
#   TCP  HAProxy: kernel splice, reload without dropping connections and
#        optional PROXY protocol v2 so the foreign server sees real user IPs.
#   UDP  A dedicated nginx stream instance (service haproxy-forwarder-udp),
#        separate from any nginx web server on this machine.
#
# Rules are stored in /etc/haproxy/forwarder.rules and both configurations are
# rebuilt from them on every change. A systemd timer (haproxy-forwarder-heal)
# checks everything after boot and every minute, and repairs it from the rules.
#
# Run without arguments for the interactive menu, or see: HAProxy.sh --help
#

set -Eeuo pipefail

readonly SCRIPT_VERSION="3.2.0"
readonly MARKER="# Managed by haproxy-forwarder"
readonly LEGACY_MARKER="# HAProxy IPv4 -> IPv6 Forwarder"

CONFIG="${CONFIG:-/etc/haproxy/haproxy.cfg}"
RULES_FILE="${RULES_FILE:-/etc/haproxy/forwarder.rules}"
BACKUP_DIR="${BACKUP_DIR:-/etc/haproxy/backups}"
UDP_SERVICE="haproxy-forwarder-udp"
UDP_CONFIG="${UDP_CONFIG:-/etc/haproxy/forwarder-udp.conf}"
UDP_UNIT="/etc/systemd/system/$UDP_SERVICE.service"
NGINX_STREAM_MODULE="/usr/lib/nginx/modules/ngx_stream_module.so"
NGINX_OWNED_FLAG="/etc/haproxy/.forwarder-installed-nginx"
SYSCTL_FILE="/etc/sysctl.d/99-haproxy-forwarder.conf"
MODULES_FILE="/etc/modules-load.d/haproxy-forwarder.conf"
SYSTEMD_OVERRIDE="/etc/systemd/system/haproxy.service.d/99-forwarder.conf"
HAPROXY_DROPIN="/etc/systemd/system/haproxy.service.d/10-forwarder-boot.conf"
INSTALL_PATH="/usr/local/sbin/haproxy-forwarder"
HEAL_UNIT="haproxy-forwarder-heal"
HEAL_SERVICE_FILE="/etc/systemd/system/$HEAL_UNIT.service"
HEAL_TIMER_FILE="/etc/systemd/system/$HEAL_UNIT.timer"
NFT_TABLE="haproxy_fwd"
LOCK_FILE="/run/haproxy-forwarder.lock"
BACKUP_KEEP=10
NOFILE_LIMIT=1048576
HEALTH_CHECK="check inter 10s fall 3 rise 2"
# Idle time after which a UDP session is dropped (60s prevents conntrack & socket exhaustion)
UDP_TIMEOUT="${UDP_TIMEOUT:-60s}"

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# Runtime state
ASSUME_YES=0
ARG_IPV6=""
ARG_PORTS=""
ARG_PROTO=""
ARG_PROXY=0
ARG_CHECK=0
ARG_PPA=0
ARG_PURGE=0
ARG_INTERVAL=2
ARG_POSITIONAL=()
# Set for the unattended repair run: never prompts, installs or rotates backups.
HEAL_MODE=0
OS_ID=""
OS_NAME=""
TMP_FILES=()
APT_UPDATED=0
POLICY_RC_ADDED=0
LAST_CFG_BACKUP=""
LAST_RULES_BACKUP=""
LAST_UDP_BACKUP=""
HAD_RULES_FILE=0
HAD_UDP_CONFIG=0
ANS_IPV6=""
ANS_PROTO=""

# Rules: parallel arrays, one entry per listening port.
# R_OPTS is a comma list of: tcp, udp, proxy, check ("-" for none; a rule
# without tcp/udp is TCP only, as written by older versions).
R_LISTEN=()
R_IP=()
R_DPORT=()
R_OPTS=()

# Ports parsed from user input
NEW_L=()
NEW_D=()

# --------------------------------------------------
# Output helpers
# --------------------------------------------------

info()    { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
success() { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$*"; }
warning() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
error()   { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()     { error "$*"; exit 1; }

section() {
    printf '\n%s------------------------------------------%s\n' "$BOLD" "$NC"
    printf '%s %s%s\n' "$BOLD" "$1" "$NC"
    printf '%s------------------------------------------%s\n\n' "$BOLD" "$NC"
}

cleanup() {
    local f
    for f in "${TMP_FILES[@]}"; do
        rm -f -- "$f"
    done
    if (( POLICY_RC_ADDED )); then
        rm -f /usr/sbin/policy-rc.d
    fi
}

on_error() {
    error "Unexpected failure (exit $1) at line $2: $3"
}

set_traps() {
    trap cleanup EXIT
    trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
}

usage() {
    cat <<EOF
HAProxy IPv4 -> IPv6 Forwarder v$SCRIPT_VERSION (TCP + UDP)

Usage:
  sudo bash $0                      Interactive menu
  sudo bash $0 add [options]        Add or update forwarding rules
  sudo bash $0 remove PORT[,PORT]   Remove rules ('all' removes every rule)
  sudo bash $0 list                 List rules
  sudo bash $0 status               Services, tuning, connections and traffic totals
  sudo bash $0 monitor [-n SEC]     Live traffic per port (refresh every SEC, q to quit)
  sudo bash $0 optimize             Network performance tuning (BBR, buffers, limits)
  sudo bash $0 apply                Rebuild configs from saved rules and reload
  sudo bash $0 heal                 Check everything and repair it (runs every minute)
  sudo bash $0 uninstall [--purge]  Remove all rules and stop the forwarder

After the first run the script is also installed as: haproxy-forwarder

Options for 'add':
  -i, --ipv6 ADDR    Destination IPv6 address (the foreign server)
  -p, --ports LIST   "443,80,2020", "1000-1010", or "4040=443,1000-1005=2000-2005"
  -P, --proto P      both (default), tcp or udp
      --proxy        TCP: send PROXY protocol v2 so the foreign server sees real
                     user IPs (its inbound must have PROXY protocol enabled)
      --check        TCP: enable health checks (not useful with one destination)
      --ppa          Ubuntu only: install HAProxy 3.0 LTS from ppa:vbernat/haproxy-3.0
  -y, --yes          Do not ask for confirmation

Examples:
  sudo bash $0 add -i 2a01:4f8:c010:3a38::1 -p 443,8443 -y
  sudo bash $0 add -i 2a01:4f8:c010:3a38::1 -p 443 --proto tcp --proxy -y
  sudo bash $0 remove 8443
EOF
}

# --------------------------------------------------
# Prompt helpers (read from the terminal so "curl | bash" works too)
# --------------------------------------------------

read_tty() {  # read_tty VAR "prompt"
    local __reply=""
    if ! IFS= read -r -p "$2" __reply </dev/tty; then
        echo >&2
        die "Input is required but no terminal is available (use command-line options with --yes)."
    fi
    printf -v "$1" '%s' "$__reply"
}

is_yes() {
    [[ "$1" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

# For actions the user asked for: --yes answers "yes".
confirm() {  # confirm "question" [Y|N]
    local def="${2:-Y}" hint="[Y/n]" ans
    if (( ASSUME_YES )); then
        return 0
    fi
    if [[ "$def" == N ]]; then
        hint="[y/N]"
    fi
    read_tty ans "$1 $hint: "
    is_yes "${ans:-$def}"
}

# For optional extras: --yes takes the default answer.
ask_yn() {  # ask_yn "question" [Y|N]
    local def="${2:-N}" hint="[y/N]" ans
    if [[ "$def" == Y ]]; then
        hint="[Y/n]"
    fi
    if (( ASSUME_YES )); then
        if [[ "$def" == Y ]]; then return 0; else return 1; fi
    fi
    read_tty ans "$1 $hint: "
    is_yes "${ans:-$def}"
}

# --------------------------------------------------
# Validation
# --------------------------------------------------

# Prints the port as a plain decimal number. "080" would otherwise be
# treated as octal by bash arithmetic.
normalize_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    p=$((10#$p))
    (( p >= 1 && p <= 65535 )) || return 1
    printf '%s' "$p"
}

# Prints the address in canonical (compressed, lowercase) form.
normalize_ipv6() {
    local ip="$1"
    ip="${ip//[[:space:]]/}"
    ip="${ip#[}"
    ip="${ip%]}"
    [[ -n "$ip" && "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1

    # python3 exits 0 (valid) or 3 (invalid); anything else means python
    # itself is unusable, so fall back to the bash check.
    local canon rc=0
    canon=$(python3 -c '
import ipaddress, sys
try:
    print(ipaddress.IPv6Address(sys.argv[1]).compressed)
except ValueError:
    sys.exit(3)
' "$ip" 2>/dev/null) || rc=$?

    if (( rc == 0 )) && [[ -n "$canon" ]]; then
        ip="$canon"
    elif (( rc == 3 )); then
        return 1
    else
        ipv6_syntax_ok "$ip" || return 1
        ip="${ip,,}"
    fi

    [[ "$ip" != "::" ]] || return 1
    printf '%s' "$ip"
}

# Pure-bash IPv6 syntax check, used when python3 is not installed.
# Embedded IPv4 notation (::ffff:1.2.3.4) is not accepted here.
ipv6_syntax_ok() {
    local ip="$1" head tail part g groups=0 double=0
    local -a parts

    [[ "$ip" != *.* && "$ip" != *:::* ]] || return 1

    if [[ "$ip" == *::* ]]; then
        head="${ip%%::*}"
        tail="${ip#*::}"
        [[ "$tail" != *::* ]] || return 1
        double=1
    else
        head="$ip"
        tail=""
    fi

    for part in "$head" "$tail"; do
        [[ -n "$part" ]] || continue
        [[ "$part" != :* && "$part" != *: ]] || return 1
        IFS=: read -ra parts <<<"$part"
        for g in "${parts[@]}"; do
            [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            groups=$((groups + 1))
        done
    done

    if (( double )); then
        (( groups <= 7 ))
    else
        (( groups == 8 ))
    fi
}

normalize_proto() {
    case "${1,,}" in
        both|all|tcp+udp|tcp,udp|udp+tcp) printf 'both' ;;
        tcp) printf 'tcp' ;;
        udp) printf 'udp' ;;
        *) return 1 ;;
    esac
}

in_array() {
    local needle="$1" e
    shift
    for e in "$@"; do
        if [[ "$e" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# Fills NEW_L / NEW_D from "443,80", "1000-1005", or "4040=443,1000-1005=2000-2005".
parse_port_list() {
    local input="${1//[[:space:]]/}" item l d nl nd
    local -a items
    NEW_L=()
    NEW_D=()

    if [[ -z "$input" ]]; then
        error "Port list cannot be empty."
        return 1
    fi

    IFS=',' read -ra items <<<"$input"
    for item in "${items[@]}"; do
        [[ -n "$item" ]] || continue
        if [[ "$item" == *=* ]]; then
            l="${item%%=*}"
            d="${item#*=}"
        else
            l="$item"
            d="$item"
        fi

        # Check for port range syntax: 1000-1010 or 1000-1010=2000-2010
        if [[ "$l" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
            local l_start="${BASH_REMATCH[1]}" l_end="${BASH_REMATCH[2]}"
            local d_start d_end
            if [[ "$d" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
                d_start="${BASH_REMATCH[1]}"
                d_end="${BASH_REMATCH[2]}"
            elif [[ "$l" == "$d" ]]; then
                d_start="$l_start"
                d_end="$l_end"
            else
                error "Destination port must also be a range matching '$l': '$d'"
                return 1
            fi

            l_start=$((10#$l_start)); l_end=$((10#$l_end))
            d_start=$((10#$d_start)); d_end=$((10#$d_end))

            if (( l_start < 1 || l_start > 65535 || l_end < 1 || l_end > 65535 || l_start > l_end )); then
                error "Invalid listening port range: $l"
                return 1
            fi
            if (( d_start < 1 || d_start > 65535 || d_end < 1 || d_end > 65535 || d_start > d_end )); then
                error "Invalid destination port range: $d"
                return 1
            fi
            if (( (l_end - l_start) != (d_end - d_start) )); then
                error "Port range size mismatch ($(( l_end - l_start + 1 )) vs $(( d_end - d_start + 1 ))): $item"
                return 1
            fi
            if (( (l_end - l_start) > 500 )); then
                error "Port range exceeds maximum allowed span of 500 ports: $item"
                return 1
            fi

            local curr_l curr_d offset=0
            for (( curr_l = l_start; curr_l <= l_end; curr_l++ )); do
                curr_d=$(( d_start + offset ))
                offset=$(( offset + 1 ))
                if in_array "$curr_l" "${NEW_L[@]}"; then
                    error "Listening port $curr_l appears more than once."
                    return 1
                fi
                NEW_L+=("$curr_l")
                NEW_D+=("$curr_d")
            done
            continue
        fi

        if ! nl=$(normalize_port "$l"); then
            error "Invalid listening port: '$l' (must be 1-65535)."
            return 1
        fi
        if ! nd=$(normalize_port "$d"); then
            error "Invalid destination port: '$d' (must be 1-65535)."
            return 1
        fi
        if in_array "$nl" "${NEW_L[@]}"; then
            error "Listening port $nl appears more than once."
            return 1
        fi
        NEW_L+=("$nl")
        NEW_D+=("$nd")
    done

    if (( ${#NEW_L[@]} == 0 )); then
        error "Port list cannot be empty."
        return 1
    fi
}

# --------------------------------------------------
# System helpers
# --------------------------------------------------

preflight() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (e.g. sudo bash $0)."
    [[ -r /etc/os-release ]] || die "Unable to detect the operating system."

    local os_like
    OS_ID=$(. /etc/os-release && echo "${ID:-}")
    os_like=$(. /etc/os-release && echo "${ID_LIKE:-}")
    OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")

    case " $OS_ID $os_like " in
        *" debian "*|*" ubuntu "*) ;;
        *) die "Only Debian/Ubuntu based systems are supported (detected: $OS_NAME)." ;;
    esac

    command -v systemctl >/dev/null 2>&1 || die "systemd is required."
    command -v ss >/dev/null 2>&1 || die "'ss' is required: apt-get install iproute2"

    mkdir -p "$(dirname "$RULES_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        # The periodic repair simply skips a round while a user is working.
        if (( HEAL_MODE )); then
            exit 0
        fi
        local locker_pid=""
        if command -v fuser >/dev/null 2>&1; then
            locker_pid=$(fuser "$LOCK_FILE" 2>/dev/null | tr -s ' ' '\n' | grep -v '^$' | head -n 1)
        elif command -v lsof >/dev/null 2>&1; then
            locker_pid=$(lsof -t "$LOCK_FILE" 2>/dev/null | head -n 1)
        fi
        if [[ -n "$locker_pid" ]]; then
            die "Another instance of this script is already running (PID: $locker_pid). Stop it with: kill -9 $locker_pid"
        fi
        die "Another instance of this script is already running. You can release it with: fuser -k $LOCK_FILE"
    fi
}

# Keeps a copy at a fixed path for the repair timer and as a command.
# Replaced atomically so a copy that is running keeps reading the old file.
install_self() {
    local src="${BASH_SOURCE[0]:-}"
    [[ -n "$src" && -f "$src" && -r "$src" ]] || return 0
    if [[ "$(readlink -f "$src")" == "$INSTALL_PATH" ]]; then
        return 0
    fi
    if [[ ! -f "$INSTALL_PATH" ]] || ! cmp -s "$src" "$INSTALL_PATH"; then
        install -m 755 "$src" "$INSTALL_PATH.tmp.$$"
        mv -f "$INSTALL_PATH.tmp.$$" "$INSTALL_PATH"
    fi
}

write_if_changed() {  # write_if_changed FILE CONTENT; succeeds if the file changed
    if [[ -f "$1" && "$(cat "$1")" == "$2" ]]; then
        return 1
    fi
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" >"$1"
}

# Makes the forwarder come back by itself after a reboot or any failure:
# HAProxy keeps retrying instead of giving up after a few fast failures,
# and a timer checks everything after boot and every minute.
ensure_boot_units() {
    local changed=0 content
    content=$(cat <<EOF
$MARKER
[Unit]
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=3
EOF
)
    if write_if_changed "$HAPROXY_DROPIN" "$content"; then
        changed=1
    fi

    if [[ ! -x "$INSTALL_PATH" ]]; then
        warning "Automatic repair needs the script saved as a file (not run through a pipe)."
    else
        content=$(cat <<EOF
$MARKER
[Unit]
Description=Check and repair the IPv4 -> IPv6 forwarder
After=network-online.target haproxy.service $UDP_SERVICE.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH heal
EOF
)
        if write_if_changed "$HEAL_SERVICE_FILE" "$content"; then
            changed=1
        fi
        content=$(cat <<EOF
$MARKER
[Unit]
Description=Check the IPv4 -> IPv6 forwarder after boot and every minute

[Timer]
OnBootSec=20s
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
)
        if write_if_changed "$HEAL_TIMER_FILE" "$content"; then
            changed=1
        fi
    fi

    if (( changed )); then
        svc daemon-reload
    fi
    if [[ -f "$HEAL_TIMER_FILE" ]] && ! svc is-active --quiet "$HEAL_UNIT.timer"; then
        svc enable --now "$HEAL_UNIT.timer" >/dev/null 2>&1 \
            || warning "Could not enable $HEAL_UNIT.timer."
    fi
}

# --------------------------------------------------
# Traffic counters (nftables, count only: never accepts or drops anything)
# --------------------------------------------------

ensure_nft() {
    if command -v nft >/dev/null 2>&1; then
        return 0
    fi
    if (( HEAL_MODE )); then
        return 1
    fi
    info "Installing nftables (used only to count traffic per port)..."
    apt_update_once
    # nftables.service is never enabled: its default config flushes all rules.
    apt_install nftables >/dev/null || return 1
    command -v nft >/dev/null 2>&1
}

# Rebuilds the per-port byte counters for the current rules. "in" is traffic
# from users to this server, "out" is traffic from this server to users.
update_counters() {
    local i p o nl=$'\n' counters="" in_rules="" out_rules="" proto
    if ! ensure_nft; then
        warning "nft is not available: per-port traffic rates are disabled."
        return 0
    fi

    if (( ${#R_LISTEN[@]} == 0 )); then
        nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
        return 0
    fi

    for i in $(sorted_indices); do
        p="${R_LISTEN[$i]}"
        o="${R_OPTS[$i]}"
        for proto in tcp udp; do
            if [[ "$proto" == tcp ]] && ! rule_has_tcp "$o"; then continue; fi
            if [[ "$proto" == udp ]] && ! rule_has_udp "$o"; then continue; fi
            counters+="    counter ${proto:0:1}${p}i { }${nl}    counter ${proto:0:1}${p}o { }${nl}"
            in_rules+="        $proto dport $p counter name ${proto:0:1}${p}i${nl}"
            out_rules+="        $proto sport $p counter name ${proto:0:1}${p}o${nl}"
        done
    done

    if ! nft -f - <<EOF
table inet $NFT_TABLE
delete table inet $NFT_TABLE
table inet $NFT_TABLE {
$counters
    chain input {
        type filter hook input priority -10; policy accept;
$in_rules    }
    chain output {
        type filter hook output priority -10; policy accept;
$out_rules    }
}
EOF
    then
        warning "Could not create the traffic counters (nft); rates will not be shown."
    fi
}

counters_present() {
    command -v nft >/dev/null 2>&1 && nft list table inet "$NFT_TABLE" >/dev/null 2>&1
}

# Prints "<counter> <bytes>" for every counter, e.g. "t8443o 123456".
read_counters() {
    nft list table inet "$NFT_TABLE" 2>/dev/null \
        | awk '$1 == "counter" && $3 == "{" { name = $2 }
               name != "" && /bytes/ { for (i = 1; i < NF; i++) if ($i == "bytes") print name, $(i + 1); name = "" }'
}

fmt_rate() {  # fmt_rate BYTES SECONDS -> bits per second
    awk -v b="$1" -v t="$2" 'BEGIN {
        r = (t > 0 && b > 0) ? b * 8 / t : 0
        if (r >= 1e9) printf "%.2f Gbps", r / 1e9
        else if (r >= 1e6) printf "%.2f Mbps", r / 1e6
        else if (r >= 1e3) printf "%.1f Kbps", r / 1e3
        else printf "%d bps", r
    }'
}

fmt_bytes() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1099511627776) printf "%.2f TB", b / 1099511627776
        else if (b >= 1073741824) printf "%.2f GB", b / 1073741824
        else if (b >= 1048576) printf "%.1f MB", b / 1048576
        else if (b >= 1024) printf "%.1f KB", b / 1024
        else printf "%d B", b
    }'
}

# systemctl without the lock descriptor, so a service started from here
# can never hold the lock after this script exits.
svc() {
    systemctl "$@" 9>&-
}

apt_update_once() {
    if (( APT_UPDATED )); then
        return 0
    fi
    info "Updating package lists..."
    apt-get update -q || die "apt-get update failed."
    APT_UPDATED=1
}

# Keeps existing config files: haproxy.cfg may already be ours.
apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

ensure_haproxy() {
    if command -v haproxy >/dev/null 2>&1; then
        return 0
    fi

    if (( HEAL_MODE )); then
        die "HAProxy is not installed; run the script once to reinstall it."
    fi
    warning "HAProxy (TCP forwarding) is not installed."
    confirm "Install HAProxy now?" Y || die "HAProxy is required for TCP forwarding."
    apt_update_once

    local use_ppa=0
    if [[ "$OS_ID" == ubuntu ]]; then
        if (( ARG_PPA )); then
            use_ppa=1
        elif ask_yn "Install HAProxy 3.0 LTS from the official PPA (newer and faster than the Ubuntu package)?" N; then
            use_ppa=1
        fi
    fi

    if (( use_ppa )); then
        info "Adding ppa:vbernat/haproxy-3.0..."
        if apt_install --no-install-recommends software-properties-common \
            && add-apt-repository -y ppa:vbernat/haproxy-3.0 \
            && apt-get update -q; then
            success "PPA added."
        else
            warning "Could not add the PPA; installing the distribution package instead."
        fi
    fi

    info "Installing HAProxy..."
    apt_install haproxy || die "Failed to install HAProxy."
    command -v haproxy >/dev/null 2>&1 || die "HAProxy installation failed."
    success "Installed: $(haproxy -v 2>/dev/null | sed -n 1p)"
}

nginx_has_stream() {
    local v
    command -v nginx >/dev/null 2>&1 || return 1
    if [[ -f "$NGINX_STREAM_MODULE" ]]; then
        return 0
    fi
    v=$(nginx -V 2>&1 || true)
    v="${v//$'\n'/ }"
    [[ " $v " == *" --with-stream "* ]]
}

# Installs nginx with the stream module for UDP forwarding. The stock nginx
# service is kept from starting: it would take port 80 and is not needed.
ensure_udp_engine() {
    if ! nginx_has_stream; then
        if (( HEAL_MODE )); then
            die "nginx (stream module) is not installed; run the script once to reinstall it."
        fi
        warning "UDP forwarding needs nginx with the stream module."
        confirm "Install it now?" Y || die "nginx (stream module) is required for UDP forwarding."

        local had_nginx=0 rc=0
        if command -v nginx >/dev/null 2>&1; then
            had_nginx=1
        fi
        apt_update_once
        if [[ ! -e /usr/sbin/policy-rc.d ]]; then
            printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
            chmod 755 /usr/sbin/policy-rc.d
            POLICY_RC_ADDED=1
        fi
        info "Installing nginx stream module..."
        apt_install nginx libnginx-mod-stream || rc=$?
        if (( POLICY_RC_ADDED )); then
            rm -f /usr/sbin/policy-rc.d
            POLICY_RC_ADDED=0
        fi
        (( rc == 0 )) || die "Failed to install nginx."

        if (( ! had_nginx )); then
            svc disable --now nginx >/dev/null 2>&1 || true
            touch "$NGINX_OWNED_FLAG"
        fi
        nginx_has_stream || die "The nginx stream module is not available."
        success "Installed: $(nginx -v 2>&1 | sed -n 1p) (stream module)"
    fi
    write_udp_unit
}

write_udp_unit() {
    local nginx_bin content
    nginx_bin=$(command -v nginx)
    content=$(cat <<EOF
$MARKER
[Unit]
Description=UDP port forwarder (nginx stream) for haproxy-forwarder
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=$nginx_bin -t -q -c $UDP_CONFIG
ExecStart=$nginx_bin -c $UDP_CONFIG
ExecReload=$nginx_bin -t -q -c $UDP_CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
KillSignal=SIGQUIT
KillMode=mixed
TimeoutStopSec=5
Restart=always
RestartSec=2
LimitNOFILE=$NOFILE_LIMIT

[Install]
WantedBy=multi-user.target
EOF
)
    if [[ ! -f "$UDP_UNIT" || "$(cat "$UDP_UNIT")" != "$content" ]]; then
        printf '%s\n' "$content" >"$UDP_UNIT"
        svc daemon-reload
    fi
}

service_state() {
    svc is-active "$1" 2>/dev/null || true
}

ss_proto_flag() {
    if [[ "$1" == udp ]]; then printf 'u'; else printf 't'; fi
}

port_is_listening() {  # port_is_listening tcp|udp PORT
    local f
    f=$(ss_proto_flag "$1")
    [[ -n "$(ss "-ln$f" "sport = :$2" 2>/dev/null | tail -n +2)" ]]
}

# Names of the processes bound to a port, comma separated.
port_owner() {  # port_owner tcp|udp PORT
    local f
    f=$(ss_proto_flag "$1")
    ss "-ln${f}p" "sport = :$2" 2>/dev/null | tail -n +2 \
        | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | sort -u | paste -sd, - || true
}

tcp_conn_count() {  # established user connections on a listening port
    ss -tn state established "( sport = :$1 )" 2>/dev/null | tail -n +2 | wc -l
}

udp_session_count() {  # UDP sessions open towards a destination
    ss -un state established "dst [$1]:$2" 2>/dev/null | tail -n +2 | wc -l
}

tcp_reachable() {  # tcp_reachable IP PORT
    local ip="$1" port="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import socket, sys
ip, port = sys.argv[1], int(sys.argv[2])
family = socket.AF_INET6 if ":" in ip else socket.AF_INET
s = socket.socket(family, socket.SOCK_STREAM)
s.settimeout(3.0)
try:
    res = s.connect_ex((ip, port))
    s.close()
    sys.exit(0 if res == 0 else 1)
except Exception:
    sys.exit(1)
' "$ip" "$port" 2>/dev/null
    elif command -v nc >/dev/null 2>&1; then
        nc -z -w 3 "$ip" "$port" 2>/dev/null
    else
        timeout 4 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$ip" "$port" 2>/dev/null
    fi
}

ufw_active() {
    local status
    command -v ufw >/dev/null 2>&1 || return 1
    status=$(ufw status 2>/dev/null || true)
    [[ "$status" == *"Status: active"* ]]
}

ufw_allow() {  # ufw_allow PORT/PROTO
    if ufw allow "$1" >/dev/null 2>&1; then
        info "ufw: allowed $1"
    else
        warning "ufw: could not allow $1"
    fi
}

open_firewall() {  # open_firewall PROTO PORT...
    local proto="$1" p
    shift
    ufw_active || return 0
    for p in "$@"; do
        if [[ "$proto" != udp ]]; then ufw_allow "$p/tcp"; fi
        if [[ "$proto" != tcp ]]; then ufw_allow "$p/udp"; fi
    done
}

# --------------------------------------------------
# Dynamic Hardware & Resource Profiling
# --------------------------------------------------

SYS_MEM_KB=0
SYS_MEM_MB=0
SYS_CORES=1
DYN_MAXCONN=25000
DYN_RMEM_DEF=262144
DYN_WMEM_DEF=262144
DYN_RMEM_MAX=67108864
DYN_WMEM_MAX=67108864
DYN_CONNTRACK_MAX=262144
DYN_SOMAXCONN=65535
DYN_PIPE_SIZE=262144
DYN_BUF_SIZE=65536

# Detects server hardware (RAM in MB, CPU cores) and calculates optimal
# dynamic limits for maxconn, socket buffers, sysctl parameters, and timeouts.
detect_system_profile() {
    local mem_kb
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)
    SYS_MEM_KB="${mem_kb:-1048576}"
    SYS_MEM_MB=$((SYS_MEM_KB / 1024))
    SYS_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    if (( SYS_CORES < 1 )); then SYS_CORES=1; fi

    # Dynamically scale network limits and buffers based on available RAM
    if (( SYS_MEM_MB < 1200 )); then
        # Tier 1: Small VPS (<= 1 GB RAM)
        DYN_MAXCONN=15000
        DYN_RMEM_DEF=131072       # 128 KB
        DYN_WMEM_DEF=131072       # 128 KB
        DYN_RMEM_MAX=33554432     # 32 MB
        DYN_WMEM_MAX=33554432     # 32 MB
        DYN_CONNTRACK_MAX=131072
        DYN_SOMAXCONN=32768
        DYN_PIPE_SIZE=131072      # 128 KB splice pipe
        DYN_BUF_SIZE=32768        # 32 KB HAProxy buffer
    elif (( SYS_MEM_MB < 2500 )); then
        # Tier 2: Medium VPS (1 GB - 2 GB RAM)
        DYN_MAXCONN=35000
        DYN_RMEM_DEF=262144       # 256 KB
        DYN_WMEM_DEF=262144       # 256 KB
        DYN_RMEM_MAX=33554432     # 32 MB
        DYN_WMEM_MAX=33554432     # 32 MB
        DYN_CONNTRACK_MAX=262144
        DYN_SOMAXCONN=65535
        DYN_PIPE_SIZE=262144      # 256 KB splice pipe
        DYN_BUF_SIZE=65536        # 64 KB HAProxy buffer
    elif (( SYS_MEM_MB < 4500 )); then
        # Tier 3: Large VPS (2 GB - 4 GB RAM)
        DYN_MAXCONN=75000
        DYN_RMEM_DEF=262144       # 256 KB
        DYN_WMEM_DEF=262144       # 256 KB
        DYN_RMEM_MAX=67108864     # 64 MB
        DYN_WMEM_MAX=67108864     # 64 MB
        DYN_CONNTRACK_MAX=524288
        DYN_SOMAXCONN=65535
        DYN_PIPE_SIZE=262144      # 256 KB splice pipe
        DYN_BUF_SIZE=65536        # 64 KB HAProxy buffer
    else
        # Tier 4: High-End VPS / Dedicated (> 4 GB RAM)
        DYN_MAXCONN=150000
        DYN_RMEM_DEF=262144       # 256 KB
        DYN_WMEM_DEF=262144       # 256 KB
        DYN_RMEM_MAX=67108864     # 64 MB
        DYN_WMEM_MAX=67108864     # 64 MB
        DYN_CONNTRACK_MAX=1048576
        DYN_SOMAXCONN=65535
        DYN_PIPE_SIZE=262144      # 256 KB splice pipe
        DYN_BUF_SIZE=65536        # 64 KB HAProxy buffer
    fi
}

compute_maxconn() {
    detect_system_profile
    printf '%s' "$DYN_MAXCONN"
}

# --------------------------------------------------
# Rules storage
# --------------------------------------------------

has_opt() {  # has_opt "tcp,udp,proxy" proxy
    [[ ",$1," == *",$2,"* ]]
}

opt_add() {  # opt_add OPTS NAME
    if [[ -z "$1" || "$1" == - ]]; then
        printf '%s' "$2"
    else
        printf '%s,%s' "$1" "$2"
    fi
}

rule_has_tcp() {
    has_opt "$1" tcp || ! has_opt "$1" udp
}

rule_has_udp() {
    has_opt "$1" udp
}

proto_label() {
    if rule_has_tcp "$1" && rule_has_udp "$1"; then
        printf 'tcp+udp'
    elif rule_has_udp "$1"; then
        printf 'udp'
    else
        printf 'tcp'
    fi
}

proto_opts() {  # both|tcp|udp -> option tokens
    case "$1" in
        both) printf 'tcp,udp' ;;
        *) printf '%s' "$1" ;;
    esac
}

extra_opts() {  # options other than the protocol, for display
    local o out=""
    local -a arr
    IFS=',' read -ra arr <<<"$1"
    for o in "${arr[@]}"; do
        case "$o" in
            tcp|udp|-|"") ;;
            *) out+="${out:+,}$o" ;;
        esac
    done
    printf '%s' "$out"
}

count_rules() {  # count_rules tcp|udp
    local i n=0
    for i in "${!R_OPTS[@]}"; do
        if [[ "$1" == tcp ]] && rule_has_tcp "${R_OPTS[$i]}"; then
            n=$((n + 1))
        elif [[ "$1" == udp ]] && rule_has_udp "${R_OPTS[$i]}"; then
            n=$((n + 1))
        fi
    done
    printf '%s' "$n"
}

find_rule() {  # prints the index of the rule listening on $1
    local i
    for i in "${!R_LISTEN[@]}"; do
        if [[ "${R_LISTEN[$i]}" == "$1" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

set_rule() {  # set_rule LISTEN IP DPORT OPTS
    local idx
    if idx=$(find_rule "$1"); then
        R_IP[idx]="$2"
        R_DPORT[idx]="$3"
        R_OPTS[idx]="$4"
    else
        R_LISTEN+=("$1")
        R_IP+=("$2")
        R_DPORT+=("$3")
        R_OPTS+=("$4")
    fi
}

delete_rule() {
    local idx
    idx=$(find_rule "$1") || return 1
    unset "R_LISTEN[$idx]" "R_IP[$idx]" "R_DPORT[$idx]" "R_OPTS[$idx]"
    R_LISTEN=("${R_LISTEN[@]}")
    R_IP=("${R_IP[@]}")
    R_DPORT=("${R_DPORT[@]}")
    R_OPTS=("${R_OPTS[@]}")
}

sorted_indices() {
    local i
    for i in "${!R_LISTEN[@]}"; do
        printf '%s %s\n' "${R_LISTEN[$i]}" "$i"
    done | sort -n | awk '{print $2}'
}

load_rules() {
    R_LISTEN=()
    R_IP=()
    R_DPORT=()
    R_OPTS=()
    [[ -f "$RULES_FILE" ]] || return 0

    local l ip d o rest nl nd
    while read -r l ip d o rest || [[ -n "${l:-}" ]]; do
        if [[ -z "${l:-}" || "$l" == \#* ]]; then
            continue
        fi
        if nl=$(normalize_port "$l") && nd=$(normalize_port "${d:-}") \
            && [[ "${ip:-}" == *:* && "${ip:-}" =~ ^[0-9a-fA-F:.]+$ ]]; then
            set_rule "$nl" "$ip" "$nd" "${o:--}"
        else
            warning "Ignoring invalid line in $RULES_FILE: $l ${ip:-} ${d:-}"
        fi
    done <"$RULES_FILE"
}

save_rules() {
    local tmp i
    tmp=$(mktemp "${RULES_FILE}.XXXXXX")
    {
        echo "$MARKER"
        echo "# <listen_port> <destination_ipv6> <destination_port> <options: tcp,udp,proxy,check>"
        for i in $(sorted_indices); do
            printf '%s %s %s %s\n' "${R_LISTEN[$i]}" "${R_IP[$i]}" "${R_DPORT[$i]}" "${R_OPTS[$i]:--}"
        done
    } >"$tmp"
    chmod 640 "$tmp"
    mv -f "$tmp" "$RULES_FILE"
}

# Rebuilds the rules file from a haproxy.cfg written by this script, either
# by v1 (single file, no rules file) or when the rules file was deleted.
import_rules_from_config() {
    [[ ! -f "$RULES_FILE" && -f "$CONFIG" ]] || return 0
    grep -qF -e "$MARKER" -e "$LEGACY_MARKER" "$CONFIG" || return 0

    local legacy=1 line opts
    local re='^[[:space:]]*server[[:space:]]+(server|fwd)_([0-9]+)[[:space:]]+\[([0-9A-Fa-f:.]+)\]:([0-9]+)(.*)$'
    if grep -qF "$MARKER" "$CONFIG"; then
        legacy=0
    fi

    R_LISTEN=()
    R_IP=()
    R_DPORT=()
    R_OPTS=()
    while IFS= read -r line; do
        [[ "$line" =~ $re ]] || continue
        opts="tcp"
        if [[ "${BASH_REMATCH[5]}" == *send-proxy* ]]; then
            opts=$(opt_add "$opts" proxy)
        fi
        # v1 put "check" on every server; it is dropped on purpose.
        if (( ! legacy )) && [[ "${BASH_REMATCH[5]}" == *" check"* ]]; then
            opts=$(opt_add "$opts" check)
        fi
        set_rule "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "$opts"
    done <"$CONFIG"

    if (( ${#R_LISTEN[@]} )); then
        save_rules
        success "Imported ${#R_LISTEN[@]} existing TCP rule(s) from $CONFIG."
        if (( legacy )); then
            warning "Run 'apply' (menu option 6) to rebuild the config with the optimized settings."
        fi
    fi
}

# --------------------------------------------------
# Configuration generation
# --------------------------------------------------

generate_config() {  # generate_config FILE USE_SPLICE  (HAProxy, TCP rules)
    local out="$1" use_splice="$2" i server bind_spec
    detect_system_profile

    {
        cat <<EOF
$MARKER
# HAProxy TCP forwarder (IPv4 -> IPv6), generated by HAProxy.sh v$SCRIPT_VERSION
# Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')
#
# Do not edit by hand: this file is rebuilt from $RULES_FILE
# whenever rules change. Use the script to add or remove rules.

global
    log /dev/log local0 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    # Dynamically sized from system RAM (${SYS_MEM_MB} MB) and CPU (${SYS_CORES} cores)
    maxconn $DYN_MAXCONN
    tune.pipesize $DYN_PIPE_SIZE
    tune.bufsize $DYN_BUF_SIZE

defaults
    # Per-connection traffic logs are emitted at 'info' and are dropped by the
    # 'notice' level above; errors and server state changes are still logged.
    log     global
    mode    tcp
    option  dontlognull
    # TCP keepalive on both sides: dead peers are detected and NAT/conntrack
    # entries stay alive while user connections are idle.
    option  clitcpka
    option  srvtcpka
EOF
        if (( use_splice )); then
            cat <<'EOF'
    # Zero-copy forwarding inside the kernel (Linux splice).
    option  splice-auto
EOF
        fi
        cat <<EOF
    maxconn $DYN_MAXCONN
    retries 3
    timeout connect    5s
    # Long idle timeouts: user connections (Xray, WebSocket, SSH, ...) pass
    # through here and may stay quiet for minutes; they must not be cut.
    timeout client     1h
    timeout server     1h
    timeout client-fin 30s
    timeout server-fin 30s

EOF
        for i in $(sorted_indices); do
            rule_has_tcp "${R_OPTS[$i]}" || continue
            server="server fwd_${R_LISTEN[$i]} [${R_IP[$i]}]:${R_DPORT[$i]}"
            if has_opt "${R_OPTS[$i]}" proxy; then
                server+=" send-proxy-v2"
            fi
            if has_opt "${R_OPTS[$i]}" check; then
                server+=" $HEALTH_CHECK"
            fi
            printf 'listen fwd_%s\n    bind *:%s\n    %s\n\n' "${R_LISTEN[$i]}" "${R_LISTEN[$i]}" "$server"
        done
    } >"$out"
}

generate_udp_config() {  # generate_udp_config FILE  (nginx stream, UDP rules)
    local out="$1" i
    {
        echo "$MARKER"
        echo "# UDP forwarder (IPv4 -> IPv6), generated by HAProxy.sh v$SCRIPT_VERSION"
        echo "# Do not edit by hand: rebuilt from $RULES_FILE whenever rules change."
        echo
        if [[ -f "$NGINX_STREAM_MODULE" ]]; then
            echo "load_module $NGINX_STREAM_MODULE;"
            echo
        fi
        cat <<EOF
user www-data;
worker_processes auto;
worker_rlimit_nofile $NOFILE_LIMIT;
# Old workers finish quickly after a reload instead of holding sessions.
worker_shutdown_timeout 30s;
pid /run/$UDP_SERVICE.pid;
daemon off;
error_log stderr warn;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

stream {
    # Idle timeout after which inactive UDP sessions are freed
    proxy_timeout $UDP_TIMEOUT;
    proxy_buffer_size 64k;
EOF
        for i in $(sorted_indices); do
            rule_has_udp "${R_OPTS[$i]}" || continue
            # reuseport: one socket per worker, the kernel spreads users over all CPUs.
            printf '\n    server {\n        listen %s udp reuseport;\n        proxy_pass [%s]:%s;\n    }\n' \
                "${R_LISTEN[$i]}" "${R_IP[$i]}" "${R_DPORT[$i]}"
        done
        echo "}"
    } >"$out"
}

validate_config() {
    local out
    if out=$(haproxy -c -f "$1" 2>&1); then
        return 0
    fi
    printf '%s\n' "$out" >&2
    return 1
}

validate_udp_config() {
    local out
    if out=$(nginx -t -q -c "$1" 2>&1); then
        return 0
    fi
    printf '%s\n' "$out" >&2
    return 1
}

# Builds a valid HAProxy config into FILE, dropping splice if this build
# does not support it.
build_config() {
    local out="$1"
    generate_config "$out" 1
    if haproxy -c -f "$out" >/dev/null 2>&1; then
        return 0
    fi
    generate_config "$out" 0
    if validate_config "$out"; then
        warning "This HAProxy build does not support splice; zero-copy forwarding disabled."
        return 0
    fi
    return 1
}

install_file() {  # install_file SRC DEST (atomic, root:haproxy 640)
    local group=root
    if getent group haproxy >/dev/null 2>&1; then
        group=haproxy
    fi
    install -m 640 -o root -g "$group" "$1" "$2.tmp.$$"
    mv -f "$2.tmp.$$" "$2"
}

# --------------------------------------------------
# Applying changes
# --------------------------------------------------

rotate_backups() {
    local prefix
    for prefix in haproxy.cfg forwarder.rules forwarder-udp.conf; do
        # Names end in a timestamp, so a reverse name sort is newest first.
        ls -1d "$BACKUP_DIR/$prefix".* 2>/dev/null | sort -r \
            | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -f -- || true
    done
}

backup_current() {
    local ts base n=1
    base=$(date '+%Y%m%d-%H%M%S')
    ts="$base"
    mkdir -p "$BACKUP_DIR"
    chmod 750 "$BACKUP_DIR"
    # Two changes within the same second must not overwrite each other.
    while [[ -e "$BACKUP_DIR/haproxy.cfg.$ts" || -e "$BACKUP_DIR/forwarder.rules.$ts" \
        || -e "$BACKUP_DIR/forwarder-udp.conf.$ts" ]]; do
        n=$((n + 1))
        ts="$base-$n"
    done

    LAST_CFG_BACKUP=""
    LAST_RULES_BACKUP=""
    LAST_UDP_BACKUP=""
    HAD_RULES_FILE=0
    HAD_UDP_CONFIG=0

    if [[ -f "$CONFIG" ]]; then
        LAST_CFG_BACKUP="$BACKUP_DIR/haproxy.cfg.$ts"
        cp -a "$CONFIG" "$LAST_CFG_BACKUP"
    fi
    if [[ -f "$RULES_FILE" ]]; then
        HAD_RULES_FILE=1
        LAST_RULES_BACKUP="$BACKUP_DIR/forwarder.rules.$ts"
        cp -a "$RULES_FILE" "$LAST_RULES_BACKUP"
    fi
    if [[ -f "$UDP_CONFIG" ]]; then
        HAD_UDP_CONFIG=1
        LAST_UDP_BACKUP="$BACKUP_DIR/forwarder-udp.conf.$ts"
        cp -a "$UDP_CONFIG" "$LAST_UDP_BACKUP"
    fi

    rotate_backups
    info "Backup saved: $BACKUP_DIR (*.$ts)"
}

# Reload keeps established connections; restart only if not running.
reload_or_start() {  # reload_or_start UNIT
    if svc is-active --quiet "$1"; then
        info "Reloading $1 (existing connections are kept)..."
        if svc reload "$1"; then
            return 0
        fi
        warning "Reload of $1 failed, trying a full restart..."
    else
        info "Starting $1..."
    fi
    svc restart "$1"
}

activate_service() {  # activate_service UNIT RULE_COUNT
    if (( $2 == 0 )); then
        svc stop "$1" >/dev/null 2>&1 || true
        svc disable "$1" >/dev/null 2>&1 || true
        return 0
    fi
    svc enable "$1" >/dev/null 2>&1 || true
    reload_or_start "$1"
}

verify_running() {  # verify_running [quiet]
    local i p o n_tcp n_udp quiet="${1:-0}" m
    local -a missing=()
    n_tcp=$(count_rules tcp)
    n_udp=$(count_rules udp)
    for _ in 1 2 3 4 5 6; do
        missing=()
        if (( n_tcp )) && ! svc is-active --quiet haproxy; then
            missing+=("haproxy.service")
        fi
        if (( n_udp )) && ! svc is-active --quiet "$UDP_SERVICE"; then
            missing+=("$UDP_SERVICE.service")
        fi
        for i in "${!R_LISTEN[@]}"; do
            p="${R_LISTEN[$i]}"
            o="${R_OPTS[$i]}"
            if rule_has_tcp "$o" && ! port_is_listening tcp "$p"; then
                missing+=("$p/tcp")
            fi
            if rule_has_udp "$o" && ! port_is_listening udp "$p"; then
                missing+=("$p/udp")
            fi
        done
        if (( ${#missing[@]} == 0 )); then
            return 0
        fi
        sleep 1
    done
    if (( ! quiet )); then
        error "Not running or not listening: ${missing[*]}"
        for m in "${missing[@]}"; do
            local proto="${m#*/}" prt="${m%/*}"
            if [[ "$proto" == tcp || "$proto" == udp ]]; then
                local o
                o=$(port_owner "$proto" "$prt")
                if [[ -n "$o" ]]; then
                    error "Port $m is currently occupied by: $o"
                fi
            fi
        done
    fi
    return 1
}

rollback() {
    warning "Rolling back to the previous configuration..."

    if [[ -n "$LAST_RULES_BACKUP" && -f "$LAST_RULES_BACKUP" ]]; then
        cp -a "$LAST_RULES_BACKUP" "$RULES_FILE"
    elif (( ! HAD_RULES_FILE )); then
        rm -f "$RULES_FILE"
    fi
    if [[ -n "$LAST_CFG_BACKUP" && -f "$LAST_CFG_BACKUP" ]]; then
        install_file "$LAST_CFG_BACKUP" "$CONFIG"
    fi
    if [[ -n "$LAST_UDP_BACKUP" && -f "$LAST_UDP_BACKUP" ]]; then
        install_file "$LAST_UDP_BACKUP" "$UDP_CONFIG"
    elif (( ! HAD_UDP_CONFIG )); then
        rm -f "$UDP_CONFIG"
    fi
    load_rules

    local n_tcp n_udp ok=1
    n_tcp=$(count_rules tcp)
    n_udp=$(count_rules udp)
    if (( n_tcp )); then
        svc restart haproxy || ok=0
    else
        svc stop haproxy >/dev/null 2>&1 || true
    fi
    if (( n_udp )); then
        svc restart "$UDP_SERVICE" || ok=0
    else
        svc stop "$UDP_SERVICE" >/dev/null 2>&1 || true
    fi

    if (( ok )) && verify_running; then
        success "Previous configuration restored and running."
    else
        error "Previous configuration restored, but the services are not healthy."
        error "Check: journalctl -u haproxy -u $UDP_SERVICE -n 50 --no-pager"
    fi
}

# Writes the in-memory rules to disk and activates them; rolls back and
# exits if the services do not come up.
apply_rules() {
    local tmp_tcp tmp_udp n_tcp n_udp
    n_tcp=$(count_rules tcp)
    n_udp=$(count_rules udp)
    tmp_tcp=$(mktemp)
    tmp_udp=$(mktemp)
    TMP_FILES+=("$tmp_tcp" "$tmp_udp")

    if (( n_tcp )); then
        ensure_haproxy
    fi
    if (( n_udp )); then
        ensure_udp_engine
    fi

    info "Validating the new configuration..."
    if (( n_tcp )); then
        build_config "$tmp_tcp" || die "HAProxy rejected the generated configuration. Nothing was changed."
    else
        generate_config "$tmp_tcp" 0
    fi
    generate_udp_config "$tmp_udp"
    if (( n_udp )); then
        validate_udp_config "$tmp_udp" || die "nginx rejected the generated UDP configuration. Nothing was changed."
    fi
    success "Configuration is valid ($n_tcp TCP, $n_udp UDP)."

    # A repair rewrites the same rules, so there is nothing new to back up and
    # a failing repair every minute must not push out the useful backups.
    if (( ! HEAL_MODE )); then
        backup_current
        save_rules
    fi
    if command -v haproxy >/dev/null 2>&1; then
        install_file "$tmp_tcp" "$CONFIG"
    fi
    if (( n_udp )) || [[ -f "$UDP_CONFIG" ]]; then
        install_file "$tmp_udp" "$UDP_CONFIG"
    fi

    # Clears systemd's "start request repeated too quickly" state, if any.
    svc reset-failed haproxy "$UDP_SERVICE" >/dev/null 2>&1 || true
    activate_service haproxy "$n_tcp"
    activate_service "$UDP_SERVICE" "$n_udp"

    if verify_running 1; then
        update_counters
        ensure_boot_units
        if (( n_tcp + n_udp == 0 )); then
            info "No forwarding rules left: services stopped and disabled."
        else
            success "Forwarding is active with the new configuration."
        fi
        return 0
    fi

    # If reload left any ports unlistened (e.g. old worker socket drain lock), try a clean restart before giving up
    if (( n_tcp > 0 || n_udp > 0 )); then
        warning "Reload did not bind all ports cleanly. Attempting a full restart..."
        if (( n_tcp > 0 )); then svc restart haproxy; fi
        if (( n_udp > 0 )); then svc restart "$UDP_SERVICE"; fi
        if verify_running 0; then
            update_counters
            ensure_boot_units
            success "Forwarding is active with the new configuration after full restart."
            return 0
        fi
    else
        verify_running 0 || true
    fi

    error "The forwarder did not come up correctly with the new configuration."
    journalctl -u haproxy -u "$UDP_SERVICE" --no-pager -n 25 2>/dev/null || svc status haproxy "$UDP_SERVICE" --no-pager -l -n 10 2>/dev/null || true
    if (( HEAL_MODE )); then
        die "Repair failed; the next check will try again."
    fi
    rollback
    exit 1
}

# Compares two generated configs, ignoring the "Generated:" timestamp line.
same_config() {
    [[ -f "$2" ]] || return 1
    cmp -s <(grep -v '^# Generated:' "$1") <(grep -v '^# Generated:' "$2")
}

# Runs from the timer after boot and every minute: if the configs no longer
# match the rules, a service is down or a port is not listening, everything
# is rebuilt from the rules and restarted. Quiet when all is well.
cmd_heal() {
    load_rules
    local n_tcp n_udp tmp i p o reason=""
    n_tcp=$(count_rules tcp)
    n_udp=$(count_rules udp)
    if (( n_tcp + n_udp == 0 )); then
        return 0
    fi
    tmp=$(mktemp)
    TMP_FILES+=("$tmp")

    if (( n_tcp )) && command -v haproxy >/dev/null 2>&1; then
        generate_config "$tmp" 1
        if ! same_config "$tmp" "$CONFIG"; then
            generate_config "$tmp" 0
            if ! same_config "$tmp" "$CONFIG"; then
                reason+="haproxy.cfg was changed; "
            fi
        fi
    fi
    if (( n_tcp )) && ! svc is-active --quiet haproxy; then
        reason+="haproxy is not running; "
    fi
    if (( n_udp )); then
        generate_udp_config "$tmp"
        if ! same_config "$tmp" "$UDP_CONFIG"; then
            reason+="UDP config was changed; "
        fi
        if ! svc is-active --quiet "$UDP_SERVICE"; then
            reason+="$UDP_SERVICE is not running; "
        fi
    fi
    for i in "${!R_LISTEN[@]}"; do
        p="${R_LISTEN[$i]}"
        o="${R_OPTS[$i]}"
        if rule_has_tcp "$o" && ! port_is_listening tcp "$p"; then
            reason+="$p/tcp not listening; "
        fi
        if rule_has_udp "$o" && ! port_is_listening udp "$p"; then
            reason+="$p/udp not listening; "
        fi
    done

    if [[ -z "$reason" ]]; then
        # Counters live in the kernel and are gone after a reboot.
        if command -v nft >/dev/null 2>&1 && ! counters_present; then
            update_counters
        fi
        return 0
    fi

    warning "Repairing: ${reason%; }"
    apply_rules
    success "Repaired: ${reason%; }"
}

# Asks before replacing a haproxy.cfg that this script did not create.
check_foreign_config() {
    [[ -f "$CONFIG" ]] || return 0
    if grep -qF -e "$MARKER" -e "$LEGACY_MARKER" "$CONFIG"; then
        return 0
    fi
    if grep -Eq '^[[:space:]]*(frontend|backend|listen)[[:space:]]' "$CONFIG"; then
        warning "$CONFIG contains a HAProxy setup that was not created by this script."
        warning "It will be replaced (a backup is kept in $BACKUP_DIR)."
        confirm "Continue?" N || return 1
    fi
    return 0
}

# Fails if a requested port is taken by another program. Our own HAProxy
# (TCP) and our UDP forwarder on ports it already serves are fine.
check_ports_free() {  # check_ports_free both|tcp|udp
    local p owner idx rc=0
    for p in "${NEW_L[@]}"; do
        if [[ "$1" != udp ]]; then
            owner=$(port_owner tcp "$p")
            if [[ -n "$owner" && "$owner" != haproxy ]]; then
                error "TCP port $p is already in use by: $owner"
                rc=1
            fi
        fi
        if [[ "$1" != tcp ]]; then
            owner=$(port_owner udp "$p")
            if [[ -n "$owner" ]] \
                && ! { [[ "$owner" == nginx ]] && idx=$(find_rule "$p") && rule_has_udp "${R_OPTS[$idx]}"; }; then
                error "UDP port $p is already in use by: $owner"
                rc=1
            fi
        fi
    done
    return "$rc"
}

# --------------------------------------------------
# Display
# --------------------------------------------------

list_rules() {
    if (( ${#R_LISTEN[@]} == 0 )); then
        info "No forwarding rules configured."
        return 0
    fi
    local n=1 i
    printf '\n  %-4s %-8s %-8s    %-46s %s\n' "#" "Listen" "Proto" "Destination" "Options"
    for i in $(sorted_indices); do
        printf '  %-4s %-8s %-8s -> %-46s %s\n' "$n" ":${R_LISTEN[$i]}" \
            "$(proto_label "${R_OPTS[$i]}")" "[${R_IP[$i]}]:${R_DPORT[$i]}" \
            "$(extra_opts "${R_OPTS[$i]}")"
        n=$((n + 1))
    done
    echo
}

print_port_help() {
    cat <<'EOF'
Same port on both sides:
  443,8443,2020        ->  :443 -> [IPv6]:443, :8443 -> [IPv6]:8443, ...
  1000-1005            ->  :1000-:1005 -> [IPv6]:1000-:1005

Different destination port (listen=destination):
  4040=443,2020=2023   ->  :4040 -> [IPv6]:443, :2020 -> [IPv6]:2023
  1000-1005=2000-2005  ->  :1000-:1005 -> [IPv6]:2000-:2005

EOF
}

# --------------------------------------------------
# Commands
# --------------------------------------------------

ask_ipv6() {  # sets ANS_IPV6
    local input def=""
    if (( ${#R_IP[@]} )); then
        def="${R_IP[-1]}"
    fi
    echo "IPv6 address of the foreign server, e.g. 2a01:4f8:c010:3a38::1"
    echo
    while true; do
        if [[ -n "$def" ]]; then
            read_tty input "Destination IPv6 [$def]: "
            input="${input:-$def}"
        else
            read_tty input "Destination IPv6: "
        fi
        if ANS_IPV6=$(normalize_ipv6 "$input"); then
            return 0
        fi
        error "'$input' is not a valid IPv6 address."
    done
}

ask_proto() {  # sets ANS_PROTO
    local c
    if (( ASSUME_YES )); then
        ANS_PROTO=both
        return 0
    fi
    cat <<'EOF'
  1) TCP + UDP   (recommended: every client and protocol works)
  2) TCP only
  3) UDP only

EOF
    while true; do
        read_tty c "Select protocol [1]: "
        case "${c:-1}" in
            1) ANS_PROTO=both; return 0 ;;
            2) ANS_PROTO=tcp; return 0 ;;
            3) ANS_PROTO=udp; return 0 ;;
            *) error "Choose 1, 2 or 3." ;;
        esac
    done
}

cmd_add() {
    if ! check_foreign_config; then
        warning "Cancelled."
        return 0
    fi
    load_rules

    local ip proto opts input i l d idx line

    section "Foreign Server (IPv6)"
    if [[ -n "$ARG_IPV6" ]]; then
        ip=$(normalize_ipv6 "$ARG_IPV6") || die "Invalid IPv6 address: $ARG_IPV6"
    else
        ask_ipv6
        ip="$ANS_IPV6"
    fi
    info "Destination: [$ip]"

    if ! ip -6 route get "$ip" >/dev/null 2>&1; then
        warning "This server has no IPv6 route to [$ip]."
        warning "Forwarding cannot work until IPv6 is configured on this server."
        if ! confirm "Continue anyway?" N; then
            warning "Cancelled."
            return 0
        fi
    fi

    section "Protocol"
    if [[ -n "$ARG_PROTO" ]]; then
        proto="$ARG_PROTO"
    else
        ask_proto
        proto="$ANS_PROTO"
    fi
    opts=$(proto_opts "$proto")
    info "Protocol: $(proto_label "$opts")"

    section "Ports"
    if [[ -n "$ARG_PORTS" ]]; then
        parse_port_list "$ARG_PORTS" || exit 1
        check_ports_free "$proto" || exit 1
    else
        print_port_help
        while true; do
            read_tty input "Enter port list: "
            if parse_port_list "$input" && check_ports_free "$proto"; then
                break
            fi
        done
    fi

    if [[ "$proto" != udp ]]; then
        if (( ARG_PROXY )); then
            opts=$(opt_add "$opts" proxy)
        elif (( ! ASSUME_YES )); then
            # A wrong answer here silently breaks every client, so it takes
            # an explicit "proxy" instead of a plain yes.
            echo
            warning "PROXY protocol lets the foreign server see each user's real IP, but ONLY"
            warning "works if the foreign inbound has PROXY protocol enabled (Xray: acceptProxyProtocol)."
            warning "If it is not enabled there, ALL clients will fail to connect."
            read_tty input "Type 'proxy' to enable it, or press Enter to skip (recommended): "
            if [[ "${input,,}" == proxy ]]; then
                opts=$(opt_add "$opts" proxy)
            fi
        fi
        if (( ARG_CHECK )); then
            opts=$(opt_add "$opts" check)
        fi

        info "Testing TCP connectivity to the foreign server..."
        for d in $(printf '%s\n' "${NEW_D[@]}" | sort -un); do
            if tcp_reachable "$ip" "$d"; then
                success "[$ip]:$d/tcp accepts connections."
            else
                warning "[$ip]:$d/tcp did not accept a connection (service down or firewalled?)."
            fi
        done
    fi

    section "Configuration Summary"
    for i in "${!NEW_L[@]}"; do
        l="${NEW_L[$i]}"
        d="${NEW_D[$i]}"
        line="  :$l $(proto_label "$opts") -> [$ip]:$d"
        if idx=$(find_rule "$l"); then
            line+="   (replaces $(proto_label "${R_OPTS[$idx]}") -> [${R_IP[$idx]}]:${R_DPORT[$idx]})"
        fi
        echo "$line"
    done
    if [[ -n "$(extra_opts "$opts")" ]]; then
        echo "  Options: $(extra_opts "$opts")"
    fi
    echo

    if ! confirm "Apply this configuration?" Y; then
        warning "Cancelled."
        return 0
    fi

    for i in "${!NEW_L[@]}"; do
        set_rule "${NEW_L[$i]}" "$ip" "${NEW_D[$i]}" "$opts"
    done
    apply_rules
    open_firewall "$proto" "${NEW_L[@]}"

    section "Active Forwarding Rules"
    list_rules

    if [[ ! -f "$SYSCTL_FILE" ]] \
        && ask_yn "Apply network performance tuning now (BBR, buffers, file limits)?" Y; then
        cmd_optimize
    fi
}

cmd_remove() {
    load_rules
    if (( ${#R_LISTEN[@]} == 0 )); then
        info "No forwarding rules configured."
        return 0
    fi

    local input p np
    local -a parts targets=()

    if (( ${#ARG_POSITIONAL[@]} )); then
        input="${ARG_POSITIONAL[*]}"
    else
        list_rules
        read_tty input "Listening port(s) to remove (comma separated, or 'all'): "
    fi
    input="${input//[[:space:]]/,}"

    if [[ "${input,,}" == all ]]; then
        targets=("${R_LISTEN[@]}")
    else
        IFS=',' read -ra parts <<<"$input"
        for p in "${parts[@]}"; do
            [[ -n "$p" ]] || continue
            if np=$(normalize_port "$p") && find_rule "$np" >/dev/null; then
                if ! in_array "$np" "${targets[@]}"; then
                    targets+=("$np")
                fi
            else
                warning "No rule for port '$p'."
            fi
        done
    fi

    if (( ${#targets[@]} == 0 )); then
        info "Nothing to remove."
        return 0
    fi
    if ! confirm "Remove forwarding for port(s) ${targets[*]}?" Y; then
        warning "Cancelled."
        return 0
    fi

    for p in "${targets[@]}"; do
        delete_rule "$p"
    done
    apply_rules
    success "Removed: ${targets[*]}"
    if ufw_active; then
        info "ufw rules were left in place; close a port with: ufw delete allow PORT/tcp (or /udp)"
    fi
    list_rules
}

cmd_apply() {
    load_rules
    if (( ${#R_LISTEN[@]} == 0 )); then
        warning "No rules to apply."
        return 0
    fi
    apply_rules
    list_rules
}

cmd_status() {
    load_rules
    section "Status"

    local version cc qdisc pid nofile="-" i p o mark tcp_n udp_n
    if command -v haproxy >/dev/null 2>&1; then
        version=$(haproxy -v 2>/dev/null | sed -n 1p)
    else
        version="not installed"
    fi
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
    pid=$(svc show -p MainPID --value haproxy 2>/dev/null || echo 0)
    if [[ "${pid:-0}" != 0 && -r "/proc/$pid/limits" ]]; then
        nofile=$(awk '/^Max open files/ {print $4}' "/proc/$pid/limits")
    fi

    detect_system_profile
    printf '  %-20s %s\n' "HAProxy (TCP):" "$version"
    printf '  %-20s %s\n' "TCP service:" "$(service_state haproxy)"
    printf '  %-20s %s\n' "UDP service:" "$(service_state "$UDP_SERVICE")"
    printf '  %-20s %s MB RAM / %s Core(s) (Maxconn: %s)\n' "System Resources:" "$SYS_MEM_MB" "$SYS_CORES" "$DYN_MAXCONN"
    printf '  %-20s %s / %s\n' "Congestion control:" "$cc" "$qdisc"
    printf '  %-20s %s\n' "Open files limit:" "$nofile"
    if [[ -f "$SYSCTL_FILE" ]]; then
        printf '  %-20s %s\n' "Network tuning:" "applied"
    else
        printf '  %-20s %s\n' "Network tuning:" "not applied (run: optimize)"
    fi
    if svc is-active --quiet "$HEAL_UNIT.timer"; then
        printf '  %-20s %s\n' "Auto-repair:" "on (after boot and every minute)"
    else
        printf '  %-20s %s\n' "Auto-repair:" "off (run: apply)"
    fi
    local repairs
    repairs=$(journalctl -u "$HEAL_UNIT" --no-pager -o short-iso -n 300 2>/dev/null \
        | grep -E 'Repair|ERROR' | tail -n 3 || true)
    if [[ -n "$repairs" ]]; then
        printf '  %-20s\n' "Recent repairs:"
        printf '%s\n' "$repairs" | sed 's/^/    /'
    fi

    if (( ${#R_LISTEN[@]} == 0 )); then
        echo
        info "No forwarding rules configured."
        return 0
    fi

    local -A bytes=()
    local name val down up
    if counters_present; then
        while read -r name val; do
            bytes[$name]="$val"
        done < <(read_counters)
    fi

    printf '\n  %-8s %-8s    %-42s %-6s %-6s %-6s %-11s %s\n' \
        "Listen" "Proto" "Destination" "State" "TCP" "UDP" "To users" "From users"
    for i in $(sorted_indices); do
        p="${R_LISTEN[$i]}"
        o="${R_OPTS[$i]}"
        mark="${GREEN}ok${NC}    "
        if { rule_has_tcp "$o" && ! port_is_listening tcp "$p"; } \
            || { rule_has_udp "$o" && ! port_is_listening udp "$p"; }; then
            mark="${RED}down${NC}  "
        fi
        tcp_n="-"
        udp_n="-"
        if rule_has_tcp "$o"; then tcp_n=$(tcp_conn_count "$p"); fi
        if rule_has_udp "$o"; then udp_n=$(udp_session_count "${R_IP[$i]}" "${R_DPORT[$i]}"); fi
        down=$(( ${bytes[t${p}o]:-0} + ${bytes[u${p}o]:-0} ))
        up=$(( ${bytes[t${p}i]:-0} + ${bytes[u${p}i]:-0} ))
        printf '  %-8s %-8s -> %-42s %s %-6s %-6s %-11s %s\n' ":$p" "$(proto_label "$o")" \
            "[${R_IP[$i]}]:${R_DPORT[$i]}" "$mark" "$tcp_n" "$udp_n" \
            "$(fmt_bytes "$down")" "$(fmt_bytes "$up")"
    done
    echo
    echo "  TCP/UDP: open user connections / UDP sessions. Traffic totals count since boot"
    echo "  or the last rule change. Live speeds: monitor"
    echo
}

# Network interface carrying the default route, for the server-wide rates.
default_iface() {
    ip -o route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

iface_bytes() {  # prints "<rx> <tx>" for an interface
    awk -v dev="$1:" '$1 == dev { print $2, $10 }' /proc/net/dev 2>/dev/null
}

now_seconds() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        printf '%s' "${EPOCHREALTIME/,/.}"
    else
        date +%s.%N
    fi
}

# Live view: per-port speeds to and from users, connections, totals and the
# server-wide interface speed, refreshed every ARG_INTERVAL seconds.
cmd_monitor() {
    load_rules
    if (( ${#R_LISTEN[@]} == 0 )); then
        info "No forwarding rules configured."
        return 0
    fi
    if ! counters_present; then
        update_counters
    fi
    if ! counters_present; then
        die "Traffic counters are not available (nftables)."
    fi

    local interval="$ARG_INTERVAL" stop=0 key rc t_prev t_now dt name val i p o
    local iface rx_prev=0 tx_prev=0 rx=0 tx=0 tcp_n udp_n down up tot_down tot_up
    local -A prev=() cur=()
    iface=$(default_iface)

    trap 'stop=1' INT
    while read -r name val; do prev[$name]="$val"; done < <(read_counters)
    if [[ -n "$iface" ]]; then read -r rx_prev tx_prev < <(iface_bytes "$iface"); fi
    t_prev=$(now_seconds)
    printf '\033[?25l\033[H\033[2J  Measuring traffic for %ss...\n' "$interval"

    while (( ! stop )); do
        rc=0
        read -rsn1 -t "$interval" key </dev/tty 2>/dev/null || rc=$?
        if (( rc == 1 )); then
            sleep "$interval"        # no terminal: just keep refreshing
        elif (( rc == 0 )) && [[ "${key,,}" == q ]]; then
            break
        fi
        (( stop )) && break

        t_now=$(now_seconds)
        dt=$(awk -v a="$t_now" -v b="$t_prev" 'BEGIN { printf "%.3f", a - b }')
        cur=()
        while read -r name val; do cur[$name]="$val"; done < <(read_counters)
        if [[ -n "$iface" ]]; then read -r rx tx < <(iface_bytes "$iface"); fi

        printf '\033[H\033[2J'
        printf '%s IPv4 -> IPv6 Forwarder - live traffic%s   %s   (every %ss, q or Ctrl+C to exit)\n\n' \
            "$BOLD" "$NC" "$(date '+%H:%M:%S')" "$interval"
        printf '  TCP: %s   UDP: %s   Load: %s\n' "$(state_label haproxy)" \
            "$(state_label "$UDP_SERVICE")" "$(cut -d' ' -f1-3 /proc/loadavg)"
        if [[ -n "$iface" ]]; then
            printf '  Interface %s:  in %s   out %s\n' "$iface" \
                "$(fmt_rate $(( rx - rx_prev )) "$dt")" "$(fmt_rate $(( tx - tx_prev )) "$dt")"
        fi

        printf '\n  %-8s %-8s %-6s %-6s %-14s %-14s %-11s %s\n' \
            "Listen" "Proto" "TCP" "UDP" "To users" "From users" "Total to" "Total from"
        tot_down=0
        tot_up=0
        for i in $(sorted_indices); do
            p="${R_LISTEN[$i]}"
            o="${R_OPTS[$i]}"
            tcp_n="-"
            udp_n="-"
            if rule_has_tcp "$o"; then tcp_n=$(tcp_conn_count "$p"); fi
            if rule_has_udp "$o"; then udp_n=$(udp_session_count "${R_IP[$i]}" "${R_DPORT[$i]}"); fi
            down=$(( ${cur[t${p}o]:-0} + ${cur[u${p}o]:-0} - ${prev[t${p}o]:-0} - ${prev[u${p}o]:-0} ))
            up=$(( ${cur[t${p}i]:-0} + ${cur[u${p}i]:-0} - ${prev[t${p}i]:-0} - ${prev[u${p}i]:-0} ))
            tot_down=$(( tot_down + down ))
            tot_up=$(( tot_up + up ))
            printf '  %-8s %-8s %-6s %-6s %-14s %-14s %-11s %s\n' ":$p" "$(proto_label "$o")" \
                "$tcp_n" "$udp_n" "$(fmt_rate "$down" "$dt")" "$(fmt_rate "$up" "$dt")" \
                "$(fmt_bytes $(( ${cur[t${p}o]:-0} + ${cur[u${p}o]:-0} )))" \
                "$(fmt_bytes $(( ${cur[t${p}i]:-0} + ${cur[u${p}i]:-0} )))"
        done
        printf '  %-8s %-8s %-6s %-6s %s%-14s %-14s%s\n' "All" "" "" "" "$BOLD" \
            "$(fmt_rate "$tot_down" "$dt")" "$(fmt_rate "$tot_up" "$dt")" "$NC"

        for name in "${!cur[@]}"; do prev[$name]="${cur[$name]}"; done
        rx_prev="$rx"
        tx_prev="$tx"
        t_prev="$t_now"
    done

    printf '\033[?25h\n'
    trap - INT
}

cmd_optimize() {
    section "Network Performance Tuning"
    detect_system_profile

    info "Detected resources: ${SYS_MEM_MB} MB RAM | ${SYS_CORES} CPU core(s)"
    info "Dynamic profile: maxconn=${DYN_MAXCONN}, buffer default=${DYN_RMEM_DEF}B, max=${DYN_RMEM_MAX}B"

    local avail bbr=0 cur out
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if [[ " $avail " != *" bbr "* ]]; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    fi
    if [[ " $avail " == *" bbr "* ]]; then
        bbr=1
        if modinfo tcp_bbr >/dev/null 2>&1; then
            echo tcp_bbr >"$MODULES_FILE"
        fi
    else
        warning "BBR is not available on this kernel (common in OpenVZ/LXC containers); skipping it."
    fi

    {
        echo "$MARKER"
        echo "# Dynamic network tuning for IPv4 -> IPv6 forwarder. Delete this file and reboot to revert."
        echo "# Generated for ${SYS_MEM_MB} MB RAM, ${SYS_CORES} CPU core(s)"
        echo
        if (( bbr )); then
            echo "# BBR congestion control: much better throughput on lossy long-distance links."
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
            echo
        fi
        cat <<EOF
# Connection backlog dynamically sized for $SYS_MEM_MB MB RAM
net.core.somaxconn = $DYN_SOMAXCONN
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = $DYN_SOMAXCONN

# Outgoing connections to the foreign server (full ephemeral range)
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Faster handshakes, PMTU black hole mitigation for IPv6, no slow start after idle
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_slow_start_after_idle = 0

# Detect dead peers on idle connections within ~5 minutes
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Dynamic socket buffers: safe defaults prevent OOM while max allows high bandwidth
net.core.rmem_default = $DYN_RMEM_DEF
net.core.wmem_default = $DYN_WMEM_DEF
net.core.rmem_max = $DYN_RMEM_MAX
net.core.wmem_max = $DYN_WMEM_MAX
net.ipv4.tcp_rmem = 4096 $DYN_RMEM_DEF $DYN_RMEM_MAX
net.ipv4.tcp_wmem = 4096 $DYN_WMEM_DEF $DYN_WMEM_MAX
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF
        cur=$(sysctl -n fs.file-max 2>/dev/null || echo 0)
        if (( ${cur:-0} < 2097152 )); then
            echo
            echo "fs.file-max = 2097152"
        fi
        cur=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)
        if [[ -n "$cur" ]]; then
            echo
            echo "# Connection tracking table dynamically scaled"
            if (( cur < DYN_CONNTRACK_MAX )); then
                echo "net.netfilter.nf_conntrack_max = $DYN_CONNTRACK_MAX"
            fi
            echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"
            echo "net.netfilter.nf_conntrack_udp_timeout_stream = 60"
        fi
    } >"$SYSCTL_FILE"

    if out=$(sysctl -p "$SYSCTL_FILE" 2>&1 >/dev/null); then
        success "Kernel settings applied ($SYSCTL_FILE)."
    else
        warning "Some kernel settings could not be applied (normal inside containers):"
        printf '%s\n' "$out" | sed 's/^/  /' >&2
    fi

    mkdir -p "$(dirname "$SYSTEMD_OVERRIDE")"
    printf '%s\n[Service]\nLimitNOFILE=%s\n' "$MARKER" "$NOFILE_LIMIT" >"$SYSTEMD_OVERRIDE"
    svc daemon-reload
    success "HAProxy open files limit set to $NOFILE_LIMIT (the UDP service has it built in)."

    if svc is-active --quiet haproxy; then
        if confirm "Restart HAProxy now so the new limit takes effect? (open TCP connections drop once)" Y; then
            svc restart haproxy
            success "HAProxy restarted."
        else
            info "The new limit takes effect on the next HAProxy restart."
        fi
    fi

    info "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    if (( bbr )); then
        info "A reboot is recommended so the 'fq' queue discipline is used on every interface."
    fi
}

cmd_uninstall() {
    section "Uninstall"
    if ! confirm "Remove all forwarding rules and stop the forwarder (TCP and UDP)?" N; then
        info "Cancelled."
        return 0
    fi

    local tmp
    if [[ -f "$CONFIG" || -f "$RULES_FILE" || -f "$UDP_CONFIG" ]]; then
        backup_current
    fi
    svc disable --now "$HEAL_UNIT.timer" >/dev/null 2>&1 || true
    svc stop haproxy "$UDP_SERVICE" >/dev/null 2>&1 || true
    svc disable haproxy "$UDP_SERVICE" >/dev/null 2>&1 || true
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
    fi

    # An empty managed config, so the rules are not re-imported from it later.
    if command -v haproxy >/dev/null 2>&1; then
        R_LISTEN=()
        R_IP=()
        R_DPORT=()
        R_OPTS=()
        tmp=$(mktemp)
        TMP_FILES+=("$tmp")
        generate_config "$tmp" 0
        install_file "$tmp" "$CONFIG"
    fi
    rm -f "$RULES_FILE" "$UDP_CONFIG" "$UDP_UNIT" "$HEAL_SERVICE_FILE" "$HEAL_TIMER_FILE" \
        "$HAPROXY_DROPIN" "$INSTALL_PATH"
    svc daemon-reload || true
    success "Forwarding rules removed and services stopped (backups kept in $BACKUP_DIR)."

    if (( ARG_PURGE )) || ask_yn "Also remove the network tuning (sysctl, BBR module, file limit)?" N; then
        rm -f "$SYSCTL_FILE" "$MODULES_FILE" "$SYSTEMD_OVERRIDE"
        svc daemon-reload || true
        success "Tuning files removed (kernel values return to defaults after a reboot)."
    fi
    if (( ARG_PURGE )) || ask_yn "Also uninstall the packages installed by this script (HAProxy, nginx)?" N; then
        local -a pkgs=(haproxy)
        if [[ -f "$NGINX_OWNED_FLAG" ]]; then
            pkgs+=(nginx libnginx-mod-stream)
        fi
        DEBIAN_FRONTEND=noninteractive apt-get remove -y -q "${pkgs[@]}" || die "Failed to remove packages."
        rm -f "$NGINX_OWNED_FLAG"
        success "Removed: ${pkgs[*]}"
    fi
}

# Runs a command in a subshell with errexit active, so a failure returns to
# the menu instead of ending the script.
run_action() {
    trap - ERR
    set +e
    (
        set_traps
        set -e
        "$@"
    )
    set -e
    trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
}

state_label() {
    local s
    s=$(service_state "$1")
    if [[ "$s" == active ]]; then
        printf '%s%s%s' "$GREEN" "$s" "$NC"
    else
        printf '%s%s%s' "$RED" "${s:-unknown}" "$NC"
    fi
}

menu() {
    local choice
    while true; do
        load_rules
        section "IPv4 -> IPv6 Forwarder v$SCRIPT_VERSION"
        printf '  TCP: %s    UDP: %s    Rules: %s\n\n' \
            "$(state_label haproxy)" "$(state_label "$UDP_SERVICE")" "${#R_LISTEN[@]}"
        cat <<'EOF'
  1) Add / update forwarding rules
  2) List rules
  3) Remove rules
  4) Status (services, connections, traffic totals)
  5) Live traffic monitor
  6) Network performance tuning (BBR, buffers, limits)
  7) Rebuild configs and reload
  8) Uninstall
  0) Exit

EOF
        read_tty choice "Select an option: "
        case "$choice" in
            1) run_action cmd_add ;;
            2) list_rules ;;
            3) run_action cmd_remove ;;
            4) run_action cmd_status ;;
            5) run_action cmd_monitor ;;
            6) run_action cmd_optimize ;;
            7) run_action cmd_apply ;;
            8) run_action cmd_uninstall ;;
            0|q|Q) exit 0 ;;
            *) error "Invalid option: $choice" ;;
        esac
    done
}

parse_flags() {
    while (( $# )); do
        case "$1" in
            -i|--ipv6|--ip)
                [[ $# -ge 2 ]] || die "$1 requires a value."
                ARG_IPV6="$2"
                shift 2
                ;;
            --ipv6=*|--ip=*) ARG_IPV6="${1#*=}"; shift ;;
            -p|--ports)
                [[ $# -ge 2 ]] || die "$1 requires a value."
                ARG_PORTS="$2"
                shift 2
                ;;
            --ports=*) ARG_PORTS="${1#*=}"; shift ;;
            -P|--proto)
                [[ $# -ge 2 ]] || die "$1 requires a value."
                ARG_PROTO=$(normalize_proto "$2") || die "Invalid protocol: $2 (use both, tcp or udp)"
                shift 2
                ;;
            --proto=*)
                ARG_PROTO=$(normalize_proto "${1#*=}") || die "Invalid protocol: ${1#*=} (use both, tcp or udp)"
                shift
                ;;
            -n|--interval)
                [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]?$ ]] || die "$1 requires a number of seconds (1-99)."
                ARG_INTERVAL="$2"
                shift 2
                ;;
            --proxy) ARG_PROXY=1; shift ;;
            --check) ARG_CHECK=1; shift ;;
            --ppa) ARG_PPA=1; shift ;;
            --purge) ARG_PURGE=1; shift ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            -h|--help) usage; exit 0 ;;
            -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
            -*) die "Unknown option: $1 (see --help)" ;;
            *) ARG_POSITIONAL+=("$1"); shift ;;
        esac
    done
}

main() {
    local cmd="menu"
    if (( $# )) && [[ "$1" != -* ]]; then
        cmd="$1"
        shift
    fi
    if [[ "$cmd" == help ]]; then
        usage
        return 0
    fi

    parse_flags "$@"
    if [[ "$cmd" == menu && ( -n "$ARG_IPV6" || -n "$ARG_PORTS" ) ]]; then
        cmd=add
    fi

    if [[ "$cmd" == heal ]]; then
        HEAL_MODE=1
        ASSUME_YES=1
    fi

    set_traps
    preflight
    detect_system_profile
    import_rules_from_config
    if (( ! HEAL_MODE )); then
        install_self
        # Servers set up with an older version get auto-repair on any run.
        if [[ -f "$RULES_FILE" && "$cmd" != uninstall ]]; then
            ensure_boot_units
        fi
    fi

    case "$cmd" in
        menu) menu ;;
        add) cmd_add ;;
        remove|rm|delete) cmd_remove ;;
        list|ls) load_rules; list_rules ;;
        status) cmd_status ;;
        monitor|top|watch) cmd_monitor ;;
        optimize|tune) cmd_optimize ;;
        apply|reload) cmd_apply ;;
        heal) cmd_heal ;;
        uninstall) cmd_uninstall ;;
        *) usage; die "Unknown command: $cmd" ;;
    esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
