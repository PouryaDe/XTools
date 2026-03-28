#!/bin/bash

# --- Variables ---
DB_PATH="/etc/x-ui/x-ui.db"
SCRIPT_PATH="/root/traffic_check.sh"
SERVICE_PATH="/etc/systemd/system/traffic-check.service"

# --- Functions ---

# Function to install the service
install_service() {
    echo "Installing Traffic Controller..."

    # Create the monitoring worker script
    cat << 'EOF' > $SCRIPT_PATH
#!/bin/bash
DB="/etc/x-ui/x-ui.db"
while true; do
    # Find users who reached the limit (up + down >= total - 1KB)
    IDS=$(sqlite3 "$DB" "SELECT id FROM client_traffics WHERE enable=1 AND total>0 AND (up+down)>=(total-1024);")
    
    if [ -n "$IDS" ]; then
        for ID in $IDS; do
            # Disable the client
            sqlite3 "$DB" "UPDATE client_traffics SET enable=0 WHERE id=$ID;"
            echo "[$(date)] Disabled Client ID: $ID"
        done
        # Restart Xray to apply changes
        x-ui restart-xray > /dev/null 2>&1
    fi
    sleep 10
done
EOF

    chmod +x $SCRIPT_PATH

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

    # Reload and Start
    systemctl daemon-reload
    systemctl enable traffic-check
    systemctl start traffic-check
    
    echo "---------------------------------------"
    echo "SUCCESS: Service installed and started."
    echo "---------------------------------------"
}

# Function to uninstall everything
uninstall_service() {
    echo "Uninstalling and removing all files..."

    systemctl stop traffic-check
    systemctl disable traffic-check
    rm -f $SERVICE_PATH
    rm -f $SCRIPT_PATH
    systemctl daemon-reload

    echo "---------------------------------------"
    echo "SUCCESS: All files and services removed."
    echo "---------------------------------------"
}

# --- UI / Menu ---
clear
echo "======================================="
echo "   3x-ui Traffic Limit Manager"
echo "======================================="
echo "1) Install Service"
echo "2) Uninstall / Remove All"
echo "3) Check Status"
echo "4) Exit"
read -p "Select an option [1-4]: " choice

case $choice in
    1) install_service ;;
    2) uninstall_service ;;
    3) systemctl status traffic-check ;;
    4) exit 0 ;;
    *) echo "Invalid option." ;;
esac
