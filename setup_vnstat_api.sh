#!/bin/bash

# Ensure script is executed with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

APP_DIR="/opt/vnstat-api"
SERVICE_NAME="vnstat-api"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

# Function to uninstall everything
uninstall_app() {
    echo "=========================================="
    echo "Uninstalling vnStat API service..."
    echo "=========================================="
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo "Stopping service..."
        systemctl stop $SERVICE_NAME
    fi

    if systemctl is-enabled --quiet $SERVICE_NAME; then
        echo "Disabling service..."
        systemctl disable $SERVICE_NAME
    fi

    if [ -f "$SERVICE_PATH" ]; then
        echo "Removing systemd unit file..."
        rm -f $SERVICE_PATH
        systemctl daemon-reload
    fi

    if [ -d "$APP_DIR" ]; then
        echo "Removing application directory..."
        rm -rf $APP_DIR
    fi

    echo "Uninstallation completed successfully!"
}

# Function to install and setup
install_app() {
    echo "=========================================="
    echo "Installing and Setting up vnStat API..."
    echo "=========================================="

    # Detect Server Public IP
    echo "Detecting server IP address..."
    SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://icanhazip.com || hostname -I | awk '{print $1}')

    # Detect Primary Network Interface
    echo "Detecting default network interface..."
    DEFAULT_IFACE=$(ip route show | grep default | awk '{print $5}' | head -n 1)
    if [ -z "$DEFAULT_IFACE" ]; then
        DEFAULT_IFACE="eth0"
    fi

    # 1. Prompt for API Security Token
    read -sp "Enter a secure Token/Password for API access: " API_TOKEN
    echo ""
    if [ -z "$API_TOKEN" ]; then
        echo "Error: Token cannot be empty!"
        exit 1
    fi

    read -p "Enter server port [Default: 8000]: " PORT
    PORT=${PORT:-8000}

    # 2. Install Dependencies
    echo "Installing required system packages..."
    apt-get update -y
    apt-get install -y python3 python3-pip python3-venv vnstat curl

    # 3. Create Application Directory & Virtual Environment
    echo "Setting up application files..."
    mkdir -p $APP_DIR
    cd $APP_DIR

    python3 -m venv venv
    source venv/bin/activate
    pip install fastapi uvicorn

    # 4. Create Main Application Code
    cat << 'EOF' > $APP_DIR/main.py
import json
import os
import subprocess
from fastapi import FastAPI, HTTPException, status, Query
from fastapi.middleware.cors import CORSMiddleware

API_TOKEN = os.getenv("API_TOKEN", "")

app = FastAPI(title="vnStat Secure URL-Token API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

def verify_token(token: str):
    if not API_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Server API_TOKEN is not configured"
        )
    if token != API_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API Token"
        )

@app.get("/api/traffic")
def get_traffic(token: str = Query(..., description="API Access Token")):
    verify_token(token)
    try:
        result = subprocess.run(
            ["vnstat", "--json"],
            capture_output=True,
            text=True,
            check=True
        )
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"vnstat error: {e.stderr}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/traffic/{interface}")
def get_interface_traffic(interface: str, token: str = Query(..., description="API Access Token")):
    verify_token(token)
    try:
        result = subprocess.run(
            ["vnstat", "-i", interface, "--json"],
            capture_output=True,
            text=True,
            check=True
        )
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"vnstat error: {e.stderr}")
EOF

    # 5. Create Systemd Service
    echo "Creating systemd service..."
    cat << EOF > $SERVICE_PATH
[Unit]
Description=vnStat Secure API Service
After=network.target

[Service]
User=root
WorkingDirectory=$APP_DIR
Environment="API_TOKEN=$API_TOKEN"
ExecStart=$APP_DIR/venv/bin/uvicorn main:app --host 0.0.0.0 --port $PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # 6. Start and Enable Service
    echo "Starting service..."
    systemctl daemon-reload
    systemctl enable --now $SERVICE_NAME

    echo "=========================================="
    echo " Installation Finished Successfully!"
    echo "=========================================="
    echo "Detected IP Address : $SERVER_IP"
    echo "Detected Interface  : $DEFAULT_IFACE"
    echo ""
    echo "Direct Browser URLs (Copy & Paste in Browser):"
    echo "1. All Interfaces :"
    echo "   http://$SERVER_IP:$PORT/api/traffic?token=$API_TOKEN"
    echo ""
    echo "2. Auto Interface ($DEFAULT_IFACE) :"
    echo "   http://$SERVER_IP:$PORT/api/traffic/$DEFAULT_IFACE?token=$API_TOKEN"
    echo "=========================================="
}

# Interactive Menu
clear
echo "=========================================="
echo "         vnStat API Management"
echo "=========================================="
echo "1) Install & Setup Service"
echo "2) Uninstall & Remove Service"
echo "3) Exit"
echo "=========================================="
read -p "Please select an option [1-3]: " CHOICE

case $CHOICE in
    1)
        install_app
        ;;
    2)
        uninstall_app
        ;;
    3)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo "Invalid option. Exiting."
        exit 1
        ;;
esac
