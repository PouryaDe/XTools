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

    # Create the worker script that runs in the background
    cat << 'EOF' > /root/traffic_check.sh
#!/bin/bash
# Configuration
DB="/etc/x-ui/x-ui.db"
LOG="/var/log/traffic_check.log"

while true; do
    # 1. Find users who reached the limit (with 1KB buffer as requested)
    # total > 0 ensures we only target limited accounts
    # (up + down) >= (total - 1024) is the trigger logic
    EXPIRED_USERS=$(sqlite3 "$DB" "SELECT id, email FROM client_traffics WHERE enable=1 AND total>0 AND (up+down) >= (total - 1024);" 2>/dev/null)

    if [ -z "$EXPIRED_USERS" ]; then
        # No users found, wait and continue
        sleep 10
        continue
    fi

    # 2. Process users and disable them
    RESTART_NEEDED=false
    while read -r line; do
        [ -z "$line" ] && continue
        
        USER_ID=$(echo "$line" | cut -d'|' -f1)
        USER_EMAIL=$(echo "$line" | cut -d'|' -f2)

        # Update database to disable the user
        sqlite3 "$DB" "UPDATE client_traffics SET enable=0 WHERE id=$USER_ID;"
        
        # Log the event
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DISABLED: $USER_EMAIL (ID: $USER_ID)" >> "$LOG"
        RESTART_NEEDED=true
    done <<< "$EXPIRED_USERS"

    # 3. Restart Xray core only once after processing all users
    if [ "$RESTART_NEEDED" = true ]; then
        x-ui restart > /dev/null 2>&1
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SYSTEM: Xray Core Restarted" >> "$LOG"
    fi

    # Wait for 10 seconds before the next check to save CPU resources
    sleep 10
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
ExecStart=/bin/bash $SCRIPT_PATH
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and start the service
    systemctl daemon-reload
    systemctl enable traffic-check > /dev/null 2>&1
    systemctl restart traffic-check > /dev/null 2>&1
    
    echo "SUCCESS: Service is now running."
    read -p "Press Enter to return to menu..."
}

uninstall_service() {
    echo "Uninstalling and cleaning up..."
    systemctl stop traffic-check > /dev/null 2>&1
    systemctl disable traffic-check > /dev/null 2>&1
    rm -f $SERVICE_PATH $SCRIPT_PATH $LOG_FILE
    systemctl daemon-reload
    echo "SUCCESS: Everything has been removed."
    read -p "Press Enter to return to menu..."
}

# --- Main Loop ---
while true; do
    show_menu
    read -p "Select an option [1-5]: " choice
    case $choice in
        1) install_service ;;
        2) uninstall_service ;;
        3) 
            echo "Checking logs..."
            # Fix: Added better error handling and pauses for log viewing
            if [ ! -f "$LOG_FILE" ]; then
                echo "---------------------------------------"
                echo "ERROR: Log file does not exist yet."
                echo "Please install the service first (Option 1)."
                echo "---------------------------------------"
                read -p "Press Enter to return to menu..."
            elif [ ! -s "$LOG_FILE" ]; then
                echo "---------------------------------------"
                echo "NOTICE: Log file is empty."
                echo "The service is running but no traffic limits reached yet."
                echo "---------------------------------------"
                read -p "Press Enter to return to menu..."
            else
                echo "Showing logs (Press Ctrl+C to stop):"
                echo "---------------------------------------"
                tail -f "$LOG_FILE"
            fi
            ;;
        4) 
            clear
            systemctl status traffic-check
            echo "---------------------------------------"
            read -p "Press Enter to return to menu..."
            ;;
        5) exit 0 ;;
        *) 
            echo "Invalid option."
            sleep 1
            ;;
    esac
done
