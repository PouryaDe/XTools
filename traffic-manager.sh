#!/bin/bash

# ============================================================
#  3x-ui Advanced Traffic Manager
#  Version: 2.0 – Production Ready
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
CHECK_INTERVAL=5        # seconds between DB checks
DB_TIMEOUT_MS=5000      # ms sqlite3 waits if DB is locked

# --- Colors for Professional Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# FUNCTIONS – Main Script
# ============================================================

log_message() {
    local TYPE="$1"
    local MESSAGE="$2"
    local TIMESTAMP
    TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
    case "$TYPE" in
        info)    echo -e "${CYAN}[INFO]${NC}    ${TIMESTAMP} - ${MESSAGE}" ;;
        success) echo -e "${GREEN}[SUCCESS]${NC} ${TIMESTAMP} - ${MESSAGE}" ;;
        warning) echo -e "${YELLOW}[WARNING]${NC} ${TIMESTAMP} - ${MESSAGE}" ;;
        error)   echo -e "${RED}[ERROR]${NC}   ${TIMESTAMP} - ${MESSAGE}" ;;
    esac
}

check_db() {
    if [[ ! -f "$DB_PATH" ]]; then
        log_message "error" "Database not found: $DB_PATH"
        log_message "error" "Make sure x-ui is installed and has been started at least once."
        return 1
    fi
    if [[ ! -r "$DB_PATH" ]]; then
        log_message "error" "Database is not readable: $DB_PATH (check permissions)"
        return 1
    fi
    return 0
}

show_menu() {
    clear
    echo -e "${CYAN}${BOLD}=======================================${NC}"
    echo -e "${YELLOW}${BOLD}    3x-ui Advanced Traffic Manager${NC}"
    echo -e "${CYAN}=======================================${NC}"
    echo -e " ${BOLD}1)${NC} Install / Update Monitoring Service"
    echo -e " ${BOLD}2)${NC} Uninstall / Remove All"
    echo -e " ${BOLD}3)${NC} View Live Logs  (Ctrl+C to exit)"
    echo -e " ${BOLD}4)${NC} Check Service Status"
    echo -e " ${GREEN}${BOLD}5)${NC} List Users Near Limit (<${LIMIT_THRESHOLD_MB}MB Remaining)"
    echo -e " ${BOLD}6)${NC} Exit"
    echo -e "${CYAN}=======================================${NC}"
}

# --- Option 5: List users near limit ---
list_near_limit() {
    echo -e "\n${YELLOW}Checking users with less than ${LIMIT_THRESHOLD_MB} MB remaining...${NC}"

    check_db || { read -p "Press Enter to return..."; return; }

    echo "----------------------------------------------------------------------"
    printf "%-30s | %-15s | %-15s\n" "Email / Name" "Total Limit" "Remaining"
    echo "----------------------------------------------------------------------"

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

    local RESULTS
    RESULTS=$(sqlite3 -separator '|' ".timeout ${DB_TIMEOUT_MS}" "$DB_PATH" "$QUERY" 2>&1)
    local EXIT_CODE=$?

    if [[ $EXIT_CODE -ne 0 ]]; then
        log_message "error" "sqlite3 query failed: $RESULTS"
        read -p "Press Enter to return..."
        return
    fi

    if [[ -z "$RESULTS" ]]; then
        echo -e "${GREEN}No users are near the limit.${NC}"
    else
        while IFS='|' read -r EMAIL TOTAL REMAINING; do
            printf "${CYAN}%-30s${NC} | %-15s | ${RED}%-15s${NC}\n" \
                   "$EMAIL" "$TOTAL" "$REMAINING"
        done <<< "$RESULTS"
    fi

    echo "----------------------------------------------------------------------"
    read -p "Press Enter to return..."
}

# --- Option 1: Install / Update ---
install_service() {
    log_message "info" "Installing Traffic Controller..."

    check_db || { read -p "Press Enter to return..."; return; }

    # ── Write the monitoring script ──────────────────────────────────
    cat << 'INNER_EOF' > "$SCRIPT_PATH"
#!/bin/bash
# ============================================================
#  traffic_check.sh – Automated Traffic Enforcer
#  Managed by: traffic-manager.sh (DO NOT EDIT MANUALLY)
# ============================================================

DB="/etc/x-ui/x-ui.db"
LOG="/var/log/traffic_check.log"
DB_TIMEOUT_MS=5000
CHECK_INTERVAL=5

# ---- Helper: timestamped log --------------------------------
ts_log() {
    local LEVEL="$1"
    local MSG="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${LEVEL}] ${MSG}" >> "$LOG"
}

# ---- Helper: safe sqlite3 with timeout ----------------------
run_sqlite() {
    local SQL="$1"
    sqlite3 \
        -cmd ".timeout ${DB_TIMEOUT_MS}" \
        "$DB" \
        "$SQL" 2>&1
}

ts_log "SYSTEM" "Traffic enforcer started (PID=$$)"

while true; do

    # ---- 1. Log every DB read with timestamp ------------------
    ts_log "DB_READ" "Scanning client_traffics for exceeded limits..."

    # ---- 2. Verify DB is accessible ---------------------------
    if [[ ! -f "$DB" ]]; then
        ts_log "ERROR" "Database not found: $DB — skipping cycle"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # ---- 3. Use a single transaction: SELECT + UPDATE ---------
    #  IMPORTANT: dot-commands like .timeout ONLY work via stdin (heredoc),
    #  NOT when SQL is passed as a command-line argument to sqlite3.
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
        ts_log "ERROR" "Transaction failed (exit=$TX_STATUS): $CHANGES_RAW"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # changes() returns number of rows updated
    CHANGES=$(echo "$CHANGES_RAW" | tail -n1 | tr -d '[:space:]')

    if [[ "$CHANGES" =~ ^[0-9]+$ ]] && [[ "$CHANGES" -gt 0 ]]; then

        ts_log "DB_READ" "Rows disabled in this cycle: $CHANGES"

        # ---- 4. Fetch details of newly-disabled users for the log --
        DISABLED_LIST=$(run_sqlite \
            "SELECT id, email FROM client_traffics
              WHERE enable=0
                AND total > 0
                AND (up + down) >= total
              LIMIT 50;")

        if [[ $? -eq 0 && -n "$DISABLED_LIST" ]]; then
            while IFS='|' read -r UID UEMAIL; do
                [[ -z "$UID" ]] && continue
                # Validate that UID is purely numeric (prevent log injection)
                if ! [[ "$UID" =~ ^[0-9]+$ ]]; then
                    ts_log "WARNING" "Skipped suspicious UID value: $UID"
                    continue
                fi
                ts_log "ACTION" "DISABLED user: ${UEMAIL} (ID=${UID})"
            done <<< "$DISABLED_LIST"
        fi

        # ---- 5. Restart x-ui and log the result ----------------
        ts_log "SYSTEM" "Triggering xray restart (${CHANGES} user(s) disabled)..."

        systemctl restart x-ui 2>&1
        RESTART_STATUS=$?

        if [[ $RESTART_STATUS -eq 0 ]]; then
            ts_log "SYSTEM" "xray restart: SUCCESS (exit=0)"
        else
            ts_log "ERROR" "xray restart FAILED (exit=${RESTART_STATUS}) — users were disabled but xray is still running with their old config"
        fi

    else
        ts_log "DB_READ" "No users exceeded limit in this cycle."
    fi

    sleep "$CHECK_INTERVAL"

done
INNER_EOF

    chmod +x "$SCRIPT_PATH"
    log_message "success" "Monitor script written to: $SCRIPT_PATH"

    # ── Write the systemd service ─────────────────────────────────────
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

    log_message "success" "Systemd service written to: $SERVICE_PATH"

    # ── Write logrotate config (10 MB, keep 7 rotations) ─────────────
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

    log_message "success" "Logrotate config written to: $LOGROTATE_PATH"

    # ── Enable and start ─────────────────────────────────────────────
    systemctl daemon-reload
    systemctl enable traffic-check > /dev/null 2>&1
    systemctl restart traffic-check > /dev/null 2>&1

    if systemctl is-active --quiet traffic-check; then
        log_message "success" "Service traffic-check is ACTIVE and running."
    else
        log_message "error" "Service failed to start. Check: journalctl -u traffic-check -n 30"
    fi

    read -p "Press Enter to return..."
}

# --- Option 2: Uninstall ---
uninstall_service() {
    log_message "warning" "Uninstalling traffic-check service..."

    systemctl stop traffic-check    2>/dev/null
    systemctl disable traffic-check 2>/dev/null
    rm -f "$SERVICE_PATH" "$SCRIPT_PATH" "$LOGROTATE_PATH"
    systemctl daemon-reload

    log_message "success" "Service fully removed."
    log_message "info"    "Log file kept at: $LOG_FILE (remove manually if needed)"
    read -p "Press Enter to return..."
}

# --- Option 3: Live logs with correct color highlighting ---
view_logs() {
    if [[ ! -f "$LOG_FILE" ]]; then
        log_message "warning" "Log file not found yet: $LOG_FILE"
        log_message "info"    "The service may not have written any logs yet."
        read -p "Press Enter to return..."
        return
    fi

    echo -e "${YELLOW}Reading Live Logs... (Press Ctrl+C to exit)${NC}\n"

    # Use double-quotes so shell expands color variables before passing to sed
    tail -f "$LOG_FILE" | sed \
        -e "s/\[ACTION\]/[${GREEN}ACTION${NC}]/g" \
        -e "s/DISABLED/${RED}DISABLED${NC}/g" \
        -e "s/\[SYSTEM\]/[${YELLOW}SYSTEM${NC}]/g" \
        -e "s/\[ERROR\]/[${RED}ERROR${NC}]/g" \
        -e "s/\[WARNING\]/[${YELLOW}WARNING${NC}]/g" \
        -e "s/\[DB_READ\]/[${CYAN}DB_READ${NC}]/g" \
        -e "s/SUCCESS/${GREEN}SUCCESS${NC}/g"
}

# ============================================================
# MAIN LOOP
# ============================================================
while true; do
    show_menu
    read -rp "Select option: " choice
    case "$choice" in
        1) install_service ;;
        2) uninstall_service ;;
        3) view_logs ;;
        4) systemctl status traffic-check ; read -p "Press Enter..." ;;
        5) list_near_limit ;;
        6) log_message "info" "Exiting. Goodbye." ; exit 0 ;;
        *) log_message "error" "Invalid option: '$choice'" ; sleep 1 ;;
    esac
done
