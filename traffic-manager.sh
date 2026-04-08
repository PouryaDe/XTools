#!/bin/bash

# --- Variables ---
DB_PATH="/etc/x-ui/x-ui.db"
SCRIPT_PATH="/root/traffic_check.sh"
SERVICE_PATH="/etc/systemd/system/traffic-check.service"
LOG_FILE="/var/log/traffic_check.log"
LIMIT_THRESHOLD_MB=10

# --- Colors for Professional Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Functions ---

log_message() {
    local TYPE=$1
    local MESSAGE=$2
    case $TYPE in
        "info") echo -e "${CYAN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $MESSAGE" ;;
        "success") echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $MESSAGE" ;;
        "warning") echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $MESSAGE" ;;
        "error") echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $MESSAGE" ;;
    esac
}

show_menu() {
    clear
    echo -e "${CYAN}=======================================${NC}"
    echo -e "${YELLOW}    3x-ui Advanced Traffic Manager${NC}"
    echo -e "${CYAN}=======================================${NC}"
    echo "1) Install/Update Monitoring Service"
    echo "2) Uninstall / Remove All"
    echo "3) View Live Logs (Professional View)"
    echo "4) Check Service Status"
    echo -e "${GREEN}5) List Users Near Limit (<10MB Remaining)${NC}"
    echo "6) Exit"
    echo -e "${CYAN}=======================================${NC}"
}

list_near_limit() {
    echo -e "\n${YELLOW}Checking for users with less than $LIMIT_THRESHOLD_MB MB remaining...${NC}"
    echo "----------------------------------------------------------------------"
    printf "%-20s | %-15s | %-15s\n" "Email/Name" "Total Limit" "Remaining"
    echo "----------------------------------------------------------------------"

    # Query: Convert bytes to MB/GB for readability
    # total > 0 (has limit), enable = 1 (active)
    # Calculation: (total - (up+down)) / 1024 / 1024
    QUERY="SELECT email, 
           printf('%.2f GB', total/1024.0/1024.0/1024.0), 
           printf('%.2f MB', (total - (up+down))/1024.0/1024.0) as remaining 
           FROM client_traffics 
           WHERE enable=1 AND total>0 
           AND (total - (up+down)) > 0 
           AND (total - (up+down)) < ($LIMIT_THRESHOLD_MB * 1024 * 1024);"

    RESULTS=$(sqlite3 -separator '|' "$DB_PATH" "$QUERY" 2>/dev/null)

    if [ -z "$RESULTS" ]; then
        echo -e "${GREEN}No users are near the limit.${NC}"
    else
        while IFS='|' read -r EMAIL TOTAL REMAINING; do
            printf "${CYAN}%-20s${NC} | %-15s | ${RED}%-15s${NC}\n" "$EMAIL" "$TOTAL" "$REMAINING"
        done <<< "$RESULTS"
    fi
    echo "----------------------------------------------------------------------"
    read -p "Press Enter to return..."
}

install_service() {
    log_message "info" "Installing Traffic Controller..."

    cat << 'EOF' > /root/traffic_check.sh
#!/bin/bash
DB="/etc/x-ui/x-ui.db"
LOG="/var/log/traffic_check.log"

while true; do
    # Fetch users who exceeded limit
    EXPIRED_USERS=$(sqlite3 -separator '|' "$DB" "SELECT id, email FROM client_traffics WHERE enable=1 AND total>0 AND (up+down) >= total;" 2>/dev/null)

    if [ -n "$EXPIRED_USERS" ]; then
        RESTART_REQUIRED=false
        while IFS='|' read -r USER_ID USER_EMAIL; do
            [ -z "$USER_ID" ] && continue
            sqlite3 "$DB" "UPDATE client_traffics SET enable=0 WHERE id=$USER_ID;"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ACTION] DISABLED: $USER_EMAIL (ID: $USER_ID)" >> "$LOG"
            RESTART_REQUIRED=true
        done <<< "$EXPIRED_USERS"

        if [ "$RESTART_REQUIRED" = true ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SYSTEM] Xray Restart Triggered" >> "$LOG"
            systemctl restart x-ui
        fi
    fi
    sleep 5
done
EOF

    chmod +x $SCRIPT_PATH
    
    cat << EOF > $SERVICE_PATH
[Unit]
Description=3x-ui Traffic Limit Enforcer
After=network.target x-ui.service

[Service]
ExecStart=/bin/bash $SCRIPT_PATH
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable traffic-check > /dev/null 2>&1
    systemctl restart traffic-check > /dev/null 2>&1
    log_message "success" "Monitoring service is active."
    read -p "Press Enter..."
}

# --- Main Loop ---
while true; do
    show_menu
    read -p "Select option: " choice
    case $choice in
        1) install_service ;;
        2) 
            systemctl stop traffic-check && rm -f $SERVICE_PATH $SCRIPT_PATH
            log_message "warning" "Service uninstalled."
            read -p "Press Enter..." 
            ;;
        3) 
            echo -e "${YELLOW}Reading Live Logs... (Press Ctrl+C to exit)${NC}"
            # Professional log tailing with basic highlighting
            tail -f "$LOG_FILE" | sed \
                -e "s/DISABLED/${RED}DISABLED${NC}/g" \
                -e "s/SYSTEM/${YELLOW}SYSTEM${NC}/g" \
                -e "s/ACTION/${GREEN}ACTION${NC}/g"
            ;;
        4) systemctl status traffic-check ; read -p "Press Enter..." ;;
        5) list_near_limit ;;
        6) exit 0 ;;
        *) log_message "error" "Invalid Option" ; sleep 1 ;;
    esac
done
