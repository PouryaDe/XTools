#!/bin/bash

# ==========================================
# SSH Network Manager - IPsec+GRE Optimized
# GitHub Ready Version
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then 
  error "Please run as root"
  exit 1
fi

# ==========================================
# 1. FIX & REPAIR FUNCTION
# ==========================================
fix_services() {
    log "--- Starting Service Repair (Optimized Mode) ---"
    systemctl stop strongswan-swanctl 2>/dev/null
    pkill -9 charon 2>/dev/null
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq strongswan strongswan-swanctl iptables
    CHARON_PATH=$(command -v charon-systemd || echo "/usr/lib/ipsec/charon-systemd")
    cat <<EOF > /etc/systemd/system/strongswan-swanctl.service
[Unit]
Description=strongSwan swanctl daemon
After=network-online.target
[Service]
Type=simple
ExecStart=${CHARON_PATH}
ExecStartPost=-/usr/sbin/swanctl --load-all
Restart=on-abnormal
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now strongswan-swanctl
    sed -i '/dpd_delay/d' /etc/swanctl/conf.d/*.conf 2>/dev/null
    sed -i 's/unique = no/unique = replace/g' /etc/swanctl/conf.d/*.conf 2>/dev/null
    swanctl --load-all 2>/dev/null
    success "Repair Complete. MTU/MSS and Stability patches applied."
}

# ==========================================
# 2. INSTALL TUNNEL FUNCTION
# ==========================================
install_tunnel() {
    echo -e "\n--- Install New Tunnel (Optimized) ---"
    read -p "Role (IRAN/KHAREJ): " ROLE
    read -p "Tunnel ID (Number): " ID
    read -p "Local IP: " LOCAL_IP
    read -p "Remote IP: " REMOTE_IP
    read -p "Pre-Shared Key (PSK): " PSK
    read -p "IP Prefix (default 172.20): " PREFIX
    PREFIX=${PREFIX:-172.20}

    ROLE=$(echo "$ROLE" | tr '[:lower:]' '[:upper:]')
    if [ "$ROLE" == "IRAN" ]; then
        GRE_LOCAL="${PREFIX}.${ID}.1"; GRE_REMOTE="${PREFIX}.${ID}.2"
    else
        GRE_LOCAL="${PREFIX}.${ID}.2"; GRE_REMOTE="${PREFIX}.${ID}.1"
    fi

    cat <<EOF > /etc/swanctl/conf.d/tun${ID}.conf
connections {
    tun${ID} {
        local_addrs = ${LOCAL_IP}
        remote_addrs = ${REMOTE_IP}
        version = 2
        unique = replace
        proposals = aes256-sha256-modp2048
        local { auth = psk; id = ${LOCAL_IP} }
        remote { auth = psk; id = ${REMOTE_IP} }
        children {
            tun${ID} {
                mode = transport
                esp_proposals = aes256-sha256
                start_action = start
                dpd_action = restart
            }
        }
    }
}
secrets {
    ike-tun${ID} {
        id = ${REMOTE_IP}
        secret = "${PSK}"
    }
}
EOF

    cat <<EOF > /usr/local/bin/ipsec-gre-up-${ID}.sh
#!/bin/bash
ip tunnel del gre${ID} 2>/dev/null
ip tunnel add gre${ID} mode gre remote ${REMOTE_IP} local ${LOCAL_IP} ttl 255
ip link set gre${ID} up
ip addr add ${GRE_LOCAL}/30 dev gre${ID}
ip link set gre${ID} mtu 1360
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o gre${ID} -j TCPMSS --set-mss 1320
EOF
    chmod +x /usr/local/bin/ipsec-gre-up-${ID}.sh

    cat <<EOF > /etc/systemd/system/ipsec-gre-${ID}.service
[Unit]
Description=GRE over IPsec Tunnel ${ID}
After=network.target strongswan-swanctl.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ipsec-gre-up-${ID}.sh
ExecStartPost=-/usr/sbin/swanctl --initiate --child tun${ID}
RemainAfterExit=yes
ExecStop=/sbin/ip tunnel del gre${ID}
ExecStopPost=/sbin/iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o gre${ID} -j TCPMSS --set-mss 1320
[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /usr/local/bin/ipsec-keepalive-${ID}.sh
#!/bin/bash
TARGET="${GRE_REMOTE}"
while true; do
  if ! ping -c 8 -W 1 \$TARGET > /dev/null; then
    echo "\$(date): Connection lost. Soft recovery..."
    timeout 10 /usr/sbin/swanctl --initiate --child tun${ID} > /dev/null 2>&1
    sleep 5
    if ! ping -c 4 -W 1 \$TARGET > /dev/null; then
        echo "\$(date): Hard recovery..."
        /usr/sbin/swanctl --terminate --ike tun${ID} > /dev/null 2>&1
        sleep 2
        systemctl restart ipsec-gre-${ID}
    fi
  fi
  sleep 20
done
EOF
    chmod +x /usr/local/bin/ipsec-keepalive-${ID}.sh

    cat <<EOF > /etc/systemd/system/ipsec-keepalive-${ID}.service
[Unit]
Description=Keepalive Tunnel ${ID}
[Service]
ExecStart=/usr/local/bin/ipsec-keepalive-${ID}.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ipsec-gre-${ID} ipsec-keepalive-${ID}
    swanctl --load-all
    success "Tunnel ${ID} installed. Local IP: ${GRE_LOCAL}"
}

# ==========================================
# 3. STATUS FUNCTION
# ==========================================
show_status() {
    echo -e "${YELLOW}--- IPsec SA Status ---${NC}"
    swanctl --list-sas
    echo -e "\n${YELLOW}--- GRE Interfaces Status ---${NC}"
    ip addr show | grep -E "gre[0-9]+"
    echo -e "\n${YELLOW}--- Ping Test (Internal IPs) ---${NC}"
    for gre in $(ip link show | grep -o "gre[0-9]\+"); do
        IP=$(ip addr show $gre | grep -oP '(?<=inet )172\.[0-9.]+' | head -1)
        [ -z "$IP" ] && continue
        LAST_OCTET=$(echo $IP | cut -d. -f4)
        if [ "$LAST_OCTET" == "1" ]; then TARGET="${IP%.*}.2"; else TARGET="${IP%.*}.1"; fi
        ping -c 1 -W 1 $TARGET > /dev/null && echo -e "$gre ($IP) -> $TARGET: ${GREEN}UP${NC}" || echo -e "$gre ($IP) -> $TARGET: ${RED}DOWN${NC}"
    done
}

# ==========================================
# MAIN MENU
# ==========================================
clear
echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}    SSH Network Manager (IPsec+GRE)      ${NC}"
echo -e "${CYAN}==========================================${NC}"
echo "1) Install New Tunnel"
echo "2) Repair/Fix All Services"
echo "3) Show Status"
echo "4) Uninstall a Tunnel"
echo "5) Exit"
read -p "Select option: " OPTION

case $OPTION in
    1) install_tunnel ;;
    2) fix_services ;;
    3) show_status ;;
    4) 
       read -p "Tunnel ID to remove: " ID
       systemctl disable --now ipsec-gre-${ID} ipsec-keepalive-${ID} 2>/dev/null
       rm -f /etc/systemd/system/ipsec-gre-${ID}.service /etc/systemd/system/ipsec-keepalive-${ID}.service
       rm -f /usr/local/bin/ipsec-gre-up-${ID}.sh /usr/local/bin/ipsec-keepalive-${ID}.sh
       rm -f /etc/swanctl/conf.d/tun${ID}.conf
       swanctl --load-all 2>/dev/null
       ip tunnel del gre${ID} 2>/dev/null
       success "Tunnel ${ID} removed."
       ;;
    5) exit 0 ;;
    *) echo "Invalid option" ;;
esac
