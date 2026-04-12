#!/bin/bash

# ============================================================
#  3x-ui Advanced Traffic Manager
#  Version: 3.0 – Production Ready
# ============================================================

# --- Guard: Must run as root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root. Use: sudo bash $0"
    exit 1
fi

# --- Variables ---
DB_PATH="/etc/x-ui/x-ui.db"
SCRIPT_PATH="/root/traffic_check.sh"
SERVICE_PATH="/etc/systemd/system/traffic-check.service"
LOGROTATE_PATH="/etc/logrotate.d/traffic-check"
LOG_FILE="/var/log/traffic_check.log"
LIMIT_THRESHOLD_MB=10
CHECK_INTERVAL=5
DB_TIMEOUT_MS=5000

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# HELPER FUNCTIONS
# ============================================================

log_message() {
    local TYPE="$1"
    local MESSAGE="$2"
    local TIMESTAMP
    TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
    case "$TYPE" in
        info)    echo -e "  ${CYAN}●${NC} ${DIM}${TIMESTAMP}${NC}  ${MESSAGE}" ;;
        success) echo -e "  ${GREEN}✔${NC} ${DIM}${TIMESTAMP}${NC}  ${GREEN}${MESSAGE}${NC}" ;;
        warning) echo -e "  ${YELLOW}⚠${NC} ${DIM}${TIMESTAMP}${NC}  ${YELLOW}${MESSAGE}${NC}" ;;
        error)   echo -e "  ${RED}✖${NC} ${DIM}${TIMESTAMP}${NC}  ${RED}${MESSAGE}${NC}" ;;
    esac
}

check_db() {
    if [[ ! -f "$DB_PATH" ]]; then
        log_message "error" "Database not found: $DB_PATH"
        log_message "error" "Make sure x-ui is installed and started at least once."
        return 1
    fi
    if [[ ! -r "$DB_PATH" ]]; then
        log_message "error" "Database is not readable: $DB_PATH (check permissions)"
        return 1
    fi
    return 0
}

# Safe sqlite3 query – uses -cmd so .timeout works correctly
# Usage: safe_sqlite "$DB_PATH" "$SQL"
safe_sqlite() {
    local DB="$1"
    local SQL="$2"
    sqlite3 -cmd ".timeout ${DB_TIMEOUT_MS}" -separator '|' "$DB" "$SQL" 2>&1
}

press_enter() {
    echo ""
    read -rp "  $(echo -e "${DIM}Press Enter to return to menu...${NC}")" _
}

divider() {
    echo -e "${DIM}  ──────────────────────────────────────────────────────────────${NC}"
}

# ============================================================
# MENU
# ============================================================

get_service_badge() {
    if systemctl is-active --quiet traffic-check 2>/dev/null; then
        echo -e "${GREEN}${BOLD}● ACTIVE${NC}"
    else
        echo -e "${RED}${BOLD}● STOPPED${NC}"
    fi
}

show_menu() {
    clear
    local SVC_BADGE
    SVC_BADGE=$(get_service_badge)

    echo ""
    echo -e "  ${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}   ${WHITE}${BOLD}3x-ui  Advanced Traffic Manager${NC}         ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}   ${DIM}v3.0 – Production Ready${NC}                  ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}╠══════════════════════════════════════════════╣${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}   Service Status: ${SVC_BADGE}                    ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}╠══════════════════════════════════════════════╣${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}                                              ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}   ${GREEN}${BOLD}[1]${NC} Install / Update Monitoring Service   ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}   ${RED}${BOLD}[2]${NC} Uninstall / Remove All                ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}   ${YELLOW}${BOLD}[3]${NC} View Live Logs  (Ctrl+C to exit)      ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}   ${BLUE}${BOLD}[4]${NC} Check Service Status                  ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}   ${MAGENTA}${BOLD}[5]${NC} List Users Near Limit (<${LIMIT_THRESHOLD_MB}MB)         ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}   ${DIM}[6] Exit${NC}                                  ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}║${NC}                                              ${CYAN}${BOLD}║${NC}"
    echo -e "  ${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "  ${WHITE}${BOLD}›${NC} Select option: "
}

# ============================================================
# OPTION 5 – List users near limit
# ============================================================

list_near_limit() {
    clear
    echo ""
    echo -e "  ${MAGENTA}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${MAGENTA}${BOLD}║${NC}   ${WHITE}${BOLD}Users Near Traffic Limit${NC}                  ${MAGENTA}${BOLD}║${NC}"
    echo -e "  ${MAGENTA}${BOLD}║${NC}   ${DIM}Threshold: < ${LIMIT_THRESHOLD_MB} MB remaining${NC}               ${MAGENTA}${BOLD}║${NC}"
    echo -e "  ${MAGENTA}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    check_db || { press_enter; return; }

    local QUERY
    QUERY="SELECT email,
               printf('%.2f GB', CAST(total AS REAL)/1024/1024/1024),
               printf('%.2f MB', CAST(total - (up+down) AS REAL)/1024/1024)
           FROM client_traffics
           WHERE enable=1
             AND total > 0
             AND (total - (up+down)) > 0
             AND (total - (up+down)) < (${LIMIT_THRESHOLD_MB} * 1024 * 1024)
           ORDER BY (total - (up+down)) ASC;"

    # FIX: use -cmd flag (NOT as positional arg) so .timeout works correctly
    local RESULTS
    RESULTS=$(sqlite3 -cmd ".timeout ${DB_TIMEOUT_MS}" -separator '|' "$DB_PATH" "$QUERY" 2>&1)
    local EXIT_CODE=$?

    if [[ $EXIT_CODE -ne 0 ]]; then
        log_message "error" "sqlite3 query failed: $RESULTS"
        press_enter
        return
    fi

    divider
    printf "  ${BOLD}%-32s${NC} ${DIM}|${NC} ${BOLD}%-12s${NC} ${DIM}|${NC} ${BOLD}%-12s${NC}\n" \
           "Email / Username" "Total Limit" "Remaining"
    divider

    if [[ -z "$RESULTS" ]]; then
        echo ""
        echo -e "  ${GREEN}${BOLD}✔  No users are near the limit right now.${NC}"
        echo ""
    else
        local COUNT=0
        while IFS='|' read -r EMAIL TOTAL REMAINING; do
            COUNT=$((COUNT + 1))
            printf "  ${CYAN}%-32s${NC} ${DIM}|${NC} %-12s ${DIM}|${NC} ${RED}${BOLD}%-12s${NC}\n" \
                   "$EMAIL" "$TOTAL" "$REMAINING"
        done <<< "$RESULTS"
        echo ""
        echo -e "  ${YELLOW}⚠  Total: ${BOLD}${COUNT}${NC}${YELLOW} user(s) near the limit.${NC}"
    fi

    divider
    press_enter
}

# ============================================================
# OPTION 1 – Install / Update
# ============================================================

install_service() {
    clear
    echo ""
    echo -e "  ${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}${BOLD}║${NC}   ${WHITE}${BOLD}Installing Monitoring Service${NC}             ${GREEN}${BOLD}║${NC}"
    echo -e "  ${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    check_db || { press_enter; return; }

    log_message "info" "Writing monitor script → $SCRIPT_PATH"

    # ── Write the monitoring script ──────────────────────────────
    cat << 'INNER_EOF' > "$SCRIPT_PATH"
#!/bin/bash
# ============================================================
#  traffic_check.sh  –  Automated Traffic Enforcer
#  Managed by traffic-manager.sh  (DO NOT EDIT MANUALLY)
# ============================================================

DB="/etc/x-ui/x-ui.db"
LOG="/var/log/traffic_check.log"
DB_TIMEOUT_MS=5000
CHECK_INTERVAL=5

# ---- Timestamped log ----------------------------------------
ts_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${1}] ${2}" >> "$LOG"
}

# ---- Safe sqlite3: -cmd so .timeout dot-command works -------
run_sqlite() {
    sqlite3 -cmd ".timeout ${DB_TIMEOUT_MS}" -separator '|' "$DB" "$1" 2>&1
}

ts_log "SYSTEM" "Traffic enforcer started (PID=$$, interval=${CHECK_INTERVAL}s)"

while true; do

    # ---- 1. Log every DB read cycle --------------------------
    ts_log "DB_READ" "Scanning client_traffics for exceeded limits..."

    # ---- 2. Verify DB is accessible --------------------------
    if [[ ! -f "$DB" ]]; then
        ts_log "ERROR" "Database not found: $DB — skipping cycle"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # ---- 3. Transaction: UPDATE + changes() in one pass ------
    #  heredoc → stdin → dot-commands (.timeout) work correctly
    CHANGES_RAW=$(sqlite3 "$DB" << SQLEOF 2>&1
.timeout ${DB_TIMEOUT_MS}
BEGIN IMMEDIATE;
UPDATE client_traffics
   SET enable = 0
 WHERE enable = 1
   AND total > 0
   AND (up + down) >= total;
SELECT changes();
COMMIT;
SQLEOF
)
    TX_STATUS=$?

    if [[ $TX_STATUS -ne 0 ]]; then
        ts_log "ERROR" "Transaction failed (exit=${TX_STATUS}): ${CHANGES_RAW}"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # Last line of output is the changes() count
    CHANGES=$(echo "$CHANGES_RAW" | tail -n1 | tr -d '[:space:]')

    if [[ "$CHANGES" =~ ^[0-9]+$ ]] && [[ "$CHANGES" -gt 0 ]]; then

        ts_log "DB_READ" "Rows disabled in this cycle: ${CHANGES}"

        # ---- 4. Log details of newly-disabled users ----------
        DISABLED_LIST=$(run_sqlite \
            "SELECT id, email FROM client_traffics
              WHERE enable=0 AND total>0 AND (up+down)>=total LIMIT 50;")

        if [[ -n "$DISABLED_LIST" ]]; then
            while IFS='|' read -r UID UEMAIL; do
                [[ -z "$UID" ]] && continue
                if ! [[ "$UID" =~ ^[0-9]+$ ]]; then
                    ts_log "WARNING" "Skipped suspicious UID: ${UID}"
                    continue
                fi
                ts_log "ACTION" "DISABLED: ${UEMAIL} (ID=${UID})"
            done <<< "$DISABLED_LIST"
        fi

        # ---- 5. Restart x-ui – capture exit code properly ---
        ts_log "SYSTEM" "Triggering xray restart (${CHANGES} user(s) disabled)..."

        systemctl restart x-ui 2>&1
        RESTART_STATUS=$?

        if [[ $RESTART_STATUS -eq 0 ]]; then
            ts_log "SYSTEM" "xray restart: SUCCESS (exit=0)"
        else
            ts_log "ERROR"  "xray restart FAILED (exit=${RESTART_STATUS}) — xray may still serve disabled users"
        fi

    else
        ts_log "DB_READ" "No users exceeded limit. (cycle OK)"
    fi

    sleep "$CHECK_INTERVAL"

done
INNER_EOF

    chmod +x "$SCRIPT_PATH"
    log_message "success" "Monitor script written: $SCRIPT_PATH"

    # ── Write systemd service ─────────────────────────────────
    cat << EOF > "$SERVICE_PATH"
[Unit]
Description=3x-ui Traffic Limit Enforcer
After=network.target x-ui.service
Requires=x-ui.service

[Service]
ExecStart=/bin/bash $SCRIPT_PATH
Restart=always
RestartSec=5s
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    log_message "success" "Systemd service written: $SERVICE_PATH"

    # ── Write logrotate (10 MB, keep 7 rotations) ─────────────
    cat << EOF > "$LOGROTATE_PATH"
$LOG_FILE {
    size 10M
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y%m%d-%H%M%S
}
EOF
    log_message "success" "Logrotate config written: $LOGROTATE_PATH (10 MB / 7 rotations)"

    # ── Enable and start ──────────────────────────────────────
    log_message "info" "Enabling and starting service..."
    systemctl daemon-reload
    systemctl enable traffic-check > /dev/null 2>&1
    systemctl restart traffic-check > /dev/null 2>&1

    sleep 1
    if systemctl is-active --quiet traffic-check; then
        log_message "success" "Service traffic-check is ACTIVE and running."
    else
        log_message "error" "Service failed to start. Run: journalctl -u traffic-check -n 30"
    fi

    press_enter
}

# ============================================================
# OPTION 2 – Uninstall
# ============================================================

uninstall_service() {
    clear
    echo ""
    echo -e "  ${RED}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${RED}${BOLD}║${NC}   ${WHITE}${BOLD}Uninstall Monitoring Service${NC}              ${RED}${BOLD}║${NC}"
    echo -e "  ${RED}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    echo -ne "  ${YELLOW}⚠  Are you sure you want to remove everything? [y/N]: ${NC}"
    read -r CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_message "info" "Uninstall cancelled."
        press_enter
        return
    fi

    echo ""
    log_message "info" "Stopping service..."
    systemctl stop    traffic-check 2>/dev/null
    log_message "info" "Disabling service..."
    systemctl disable traffic-check 2>/dev/null

    log_message "info" "Removing files..."
    rm -f "$SERVICE_PATH" "$SCRIPT_PATH" "$LOGROTATE_PATH"

    log_message "info" "Reloading systemd daemon..."
    systemctl daemon-reload

    log_message "success" "Service fully removed."
    log_message "info"    "Log file kept at: $LOG_FILE (remove manually if needed)"
    press_enter
}

# ============================================================
# OPTION 3 – Live logs
# ============================================================

view_logs() {
    clear
    echo ""
    echo -e "  ${YELLOW}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${YELLOW}${BOLD}║${NC}   ${WHITE}${BOLD}Live Log Viewer${NC}                           ${YELLOW}${BOLD}║${NC}"
    echo -e "  ${YELLOW}${BOLD}║${NC}   ${DIM}Press Ctrl+C to return to menu${NC}            ${YELLOW}${BOLD}║${NC}"
    echo -e "  ${YELLOW}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ ! -f "$LOG_FILE" ]]; then
        log_message "warning" "Log file not found: $LOG_FILE"
        log_message "info"    "The service may not have run yet."
        press_enter
        return
    fi

    # Double-quoted sed so $COLOR vars expand correctly
    tail -f "$LOG_FILE" | sed \
        -e "s/\[ACTION\]/[${GREEN}ACTION${NC}]/g" \
        -e "s/DISABLED/${RED}${BOLD}DISABLED${NC}/g" \
        -e "s/\[SYSTEM\]/[${YELLOW}SYSTEM${NC}]/g" \
        -e "s/\[ERROR\]/[${RED}ERROR${NC}]/g" \
        -e "s/\[WARNING\]/[${YELLOW}WARNING${NC}]/g" \
        -e "s/\[DB_READ\]/[${CYAN}DB_READ${NC}]/g" \
        -e "s/SUCCESS/${GREEN}${BOLD}SUCCESS${NC}/g" \
        -e "s/FAILED/${RED}${BOLD}FAILED${NC}/g"
}

# ============================================================
# OPTION 4 – Service Status
# ============================================================

check_status() {
    clear
    echo ""
    echo -e "  ${BLUE}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${BLUE}${BOLD}║${NC}   ${WHITE}${BOLD}Service Status${NC}                            ${BLUE}${BOLD}║${NC}"
    echo -e "  ${BLUE}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    systemctl status traffic-check --no-pager -l
    echo ""
    press_enter
}

# ============================================================
# MAIN LOOP
# ============================================================
while true; do
    show_menu
    read -r choice
    case "$choice" in
        1) install_service ;;
        2) uninstall_service ;;
        3) view_logs ;;
        4) check_status ;;
        5) list_near_limit ;;
        6)
            echo ""
            log_message "info" "Exiting. Goodbye."
            echo ""
            exit 0
            ;;
        *) 
            echo ""
            log_message "error" "Invalid option: '${choice}'"
            sleep 1
            ;;
    esac
done
