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

    cat << EOF > $SCRIPT_PATH
#!/bin/bash
DB="/etc/x-ui/x-ui.db"
LOG="$LOG_FILE"
echo "[\$(date)] Monitoring Service Started" >> \$LOG
while true; do
    IDS=\$(sqlite3 "\$DB" "SELECT id, email FROM client_traffics WHERE enable=1 AND total>0 AND (up+down)>=(total-1024);")
    if [ -n "\$IDS" ]; then
        echo "\$IDS" | while read -r line; do
            ID=\$(echo \$line | cut -d'|' -f1)
            EMAIL=\$(echo \$line | cut -d'|' -f2)
            sqlite3 "\$DB" "UPDATE client_traffics SET enable=0 WHERE id=\$ID;"
            echo "[\$(date)] DISABLED: \$EMAIL (ID: \$ID)" >> \$LOG
        done
        x-ui restart-xray > /dev/null 2>&1
        echo "[\$(date)] Xray Core Restarted" >> \$LOG
    fi
    sleep 10
done
EOF

    chmod +x $SCRIPT_PATH
    touch $LOG_FILE

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
    
    echo "SUCCESS: Service installed and started."
    read -p "Press Enter to return to menu..."
}

uninstall_service() {
    echo "Uninstalling..."
    systemctl stop traffic-check > /dev/null 2>&1
    systemctl disable traffic-check > /dev/null 2>&1
    rm -f $SERVICE_PATH $SCRIPT_PATH $LOG_FILE
    systemctl daemon-reload
    echo "SUCCESS: All files and logs removed."
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
            if [ ! -s "$LOG_FILE" ]; then
                echo "NOTICE: Log file is empty or does not exist yet."
            else
                echo "Showing logs (Press Ctrl+C to stop):"
                tail -f -n 20 "$LOG_FILE"
            fi
            read -p "Press Enter to return to menu..."
            ;;
        4) 
            systemctl status traffic-check
            read -p "Press Enter to return to menu..."
            ;;
        5) exit 0 ;;
        *) echo "Invalid option."; sleep 1 ;;
    esac
done
