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
    echo "   3x-ui Traffic Limit Manager"
    echo "======================================="
    echo "1) Install Service"
    echo "2) Uninstall / Remove All"
    echo "3) View Live Logs"
    echo "4) Check Service Status"
    echo "5) Exit"
    echo "======================================="
}

install_service() {
    echo "Installing Traffic Controller..."

    # Create the worker script
    cat << 'EOF' > $SCRIPT_PATH
#!/bin/bash
DB="/etc/x-ui/x-ui.db"
LOG="/var/log/traffic_check.log"
while true; do
    IDS=$(sqlite3 "$DB" "SELECT id, email FROM client_traffics WHERE enable=1 AND total>0 AND (up+down)>=(total-1024);")
    if [ -n "$IDS" ]; then
        echo "$IDS" | while read -r line; do
            ID=$(echo $line | cut -d'|' -f1)
            EMAIL=$(echo $line | cut -d'|' -f2)
            sqlite3 "$DB" "UPDATE client_traffics SET enable=0 WHERE id=$ID;"
            echo "[$(date)] DISABLED: $EMAIL (ID: $ID)" >> $LOG
        done
        x-ui restart-xray > /dev/null 2>&1
        echo "[$(date)] Xray Core Restarted" >> $LOG
    fi
    sleep 10
done
EOF

    chmod +x $SCRIPT_PATH
    
    # Create initial log entry
    echo "=======================================" > $LOG_FILE
    echo "[$(date)] Service Installed Successfully" >> $LOG_FILE
    echo "Monitoring Started..." >> $LOG_FILE
    echo "=======================================" >> $LOG_FILE

    # Create the Systemd service
    cat << EOF > $SERVICE_PATH
[Unit]
Description=3x-ui Traffic Limit Enforcer
After=x-ui.service

[Service]
ExecStart=/bin/bash $SCRIPT_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable traffic-check > /dev/null 2>&1
    systemctl start traffic-check > /dev/null 2>&1
    
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
            if [ ! -f "$LOG_FILE" ]; then
                echo "---------------------------------------"
                echo "ERROR: Log file does not exist."
                echo "Please install the service first (Option 1)."
                echo "---------------------------------------"
                read -p "Press Enter to return to menu..."
            elif [ ! -s "$LOG_FILE" ]; then
                echo "---------------------------------------"
                echo "NOTICE: Log file is empty."
                echo "The service hasn't recorded any events yet."
                echo "---------------------------------------"
                read -p "Press Enter to return to menu..."
            else
                echo "Showing logs (Press Ctrl+C to stop and return to menu):"
                echo "---------------------------------------"
                # tail -f will keep the screen open until Ctrl+C is pressed
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
