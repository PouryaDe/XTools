#!/bin/bash

# --- Variables ---
DB_PATH="/etc/x-ui/x-ui.db"
SCRIPT_PATH="/root/traffic_check.sh"
SERVICE_PATH="/etc/systemd/system/traffic-check.service"
LOG_FILE="/var/log/traffic_check.log"

# --- Functions ---

show_menu() {
    clear
    echo "======================================="
    echo "    3x-ui Traffic Limit Manager"
    echo "======================================="
    echo "1) Install/Update Service"
    echo "2) Uninstall / Remove All"
    echo "3) View Live Logs"
    echo "4) Check Service Status"
    echo "5) Exit"
    echo "======================================="
}

install_service() {
    echo "Installing Traffic Controller..."

    # Create the worker script
    cat << 'EOF' > /root/traffic_check.sh
#!/bin/bash
# Configuration
DB="/etc/x-ui/x-ui.db"
LOG="/var/log/traffic_check.log"

while true; do
    # 1. Fetch expired users using a specific separator and timeout to prevent DB locks
    # Query logic: enable=1 AND limit reached
    QUERY="SELECT id, email FROM client_traffics WHERE enable=1 AND total>0 AND (up+down) >= total;"
    EXPIRED_USERS=$(sqlite3 -batch -init /dev/null "$DB" "$QUERY" 2>/dev/null)

    if [ -n "$EXPIRED_USERS" ]; then
        RESTART_REQUIRED=false
        
        # 2. Process each user found
        while IFS='|' read -r USER_ID USER_EMAIL; do
            if [ -z "$USER_ID" ]; then continue; fi

            # Disable user in the database
            sqlite3 "$DB" "UPDATE client_traffics SET enable=0 WHERE id=$USER_ID;"
            
            # Log the action
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ACTION: Disabled $USER_EMAIL (ID: $USER_ID)" >> "$LOG"
            RESTART_REQUIRED=true
        done <<< "$EXPIRED_USERS"

        # 3. Critical Fix: Execute restart using systemctl directly
        if [ "$RESTART_REQUIRED" = true ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] SYSTEM: Executing Xray Restart..." >> "$LOG"
            
            # Kill any stuck xray process and restart the service
            systemctl restart x-ui
            
            # Verify if restart was successful
            if [ $? -eq 0 ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] SYSTEM: Xray Service Restarted Successfully" >> "$LOG"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to restart Xray service" >> "$LOG"
            fi
        fi
    fi

    # Check interval
    sleep 5
done
EOF

    chmod +x $SCRIPT_PATH
    touch $LOG_FILE

    # Create the Systemd service unit
    cat << EOF > $SERVICE_PATH
[Unit]
Description=3x-ui Traffic Limit Enforcer
After=network.target x-ui.service

[Service]
Type=simple
ExecStart=/bin/bash $SCRIPT_PATH
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable traffic-check > /dev/null 2>&1
    systemctl restart traffic-check > /dev/null 2>&1
    
    echo "SUCCESS: Service is active and monitoring."
    read -p "Press Enter to return to menu..."
}

uninstall_service() {
    echo "Uninstalling..."
    systemctl stop traffic-check > /dev/null 2>&1
    systemctl disable traffic-check > /dev/null 2>&1
    rm -f $SERVICE_PATH $SCRIPT_PATH $LOG_FILE
    systemctl daemon-reload
    echo "SUCCESS: Cleanup complete."
    read -p "Press Enter to return to menu..."
}

# --- Main Loop ---
while true; do
    show_menu
    read -p "Select [1-5]: " choice
    case $choice in
        1) install_service ;;
        2) uninstall_service ;;
        3) tail -f "$LOG_FILE" ;;
        4) systemctl status traffic-check ; read -p "Press Enter..." ;;
        5) exit 0 ;;
        *) echo "Invalid option." ; sleep 1 ;;
    esac
done
