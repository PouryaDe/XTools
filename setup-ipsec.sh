#!/bin/bash

# ==========================================
# Colors
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/var/log/ipsec-swanctl-batch.log"
SWANCTL_DIR="/etc/swanctl"
CONF_D_DIR="$SWANCTL_DIR/conf.d"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

get_public_ip() {
    local ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    echo "${ip:-Unknown}"
}

# ==========================================
# Install Dependencies
# ==========================================
install_dependencies() {
    echo -e "${CYAN}[1/6] Checking StrongSwan installation...${NC}"

    if ! systemctl list-unit-files | grep -q strongswan-swanctl.service; then
        echo -e "${YELLOW}[1/6] Installing StrongSwan packages...${NC}"
        apt-get update -qq
        apt-get install -y -qq strongswan strongswan-pki libstrongswan-extra-plugins strongswan-swanctl charon-systemd
        echo -e "${GREEN}[1/6] StrongSwan installed.${NC}"
    else
        echo -e "${GREEN}[1/6] StrongSwan already installed.${NC}"
    fi

    if [ ! -f /lib/systemd/system/strongswan-swanctl.service ] && [ ! -f /etc/systemd/system/strongswan-swanctl.service ]; then
        echo -e "${YELLOW}[2/6] Creating missing service file...${NC}"
        cat > /etc/systemd/system/strongswan-swanctl.service <<EOF
[Unit]
Description=strongSwan IPsec IKEv2 daemon (charon-systemd)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/sbin/charon-systemd
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    echo -e "${CYAN}[3/6] Loading kernel modules...${NC}"
    mkdir -p "$CONF_D_DIR"
    modprobe af_key ip_gre 2>/dev/null
    echo -e "${GREEN}[3/6] Kernel modules loaded.${NC}"

    echo -e "${CYAN}[4/6] Disabling legacy StrongSwan services...${NC}"
    systemctl stop strongswan strongswan-starter 2>/dev/null || true
    systemctl disable strongswan strongswan-starter 2>/dev/null || true
    echo -e "${GREEN}[4/6] Legacy services disabled.${NC}"

    echo -e "${CYAN}[5/6] Starting strongswan-swanctl service...${NC}"
    systemctl enable strongswan-swanctl 2>/dev/null
    systemctl restart strongswan-swanctl 2>/dev/null
    sleep 1
    echo -e "${GREEN}[5/6] Service started.${NC}"
}

configure_firewall() {
    echo -e "${CYAN}[6/6] Configuring firewall & MSS Clamping...${NC}"
    # Open IPsec Ports
    iptables -I INPUT -p udp --dport 500 -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null
    iptables -I INPUT -p 47 -j ACCEPT 2>/dev/null # GRE
    iptables -I INPUT -p esp -j ACCEPT 2>/dev/null # ESP
    
    # --- MSS CLAMPING (The Fix for slow web browsing) ---
    # This prevents fragmentation issues over the tunnel
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    
    echo -e "${GREEN}[6/6] Firewall and MSS Clamping configured.${NC}"
}

setup_swanctl_config() {
    local id=$1; local local_ip=$2; local remote_ip=$3; local psk=$4
    cat > "$CONF_D_DIR/tun${id}.conf" <<EOF
connections {
    tun${id} {
        local_addrs = $local_ip
        remote_addrs = $remote_ip
        version = 2
        proposals = aes256-sha256-modp2048,aes128-sha1-modp1024
        local { auth = psk; id = $local_ip }
        remote { auth = psk; id = $remote_ip }
        children {
            tun${id} {
                mode = transport
                esp_proposals = aes256-sha256,aes128-sha1
                start_action = trap
                dpd_action = restart
                dpd_delay = 30s
            }
        }
    }
}
secrets {
    ike-tun${id} {
        id = $remote_ip
        secret = "$psk"
    }
}
EOF
    swanctl --load-all
}

setup_gre_interface() {
    local id=$1; local local_ip=$2; local remote_ip=$3; local tun_local=$4; local tun_remote=$5
    cat > "/usr/local/bin/ipsec-gre-up-${id}.sh" <<EOF
#!/bin/bash
ip tunnel del gre${id} 2>/dev/null || true
ip tunnel add gre${id} mode gre remote $remote_ip local $local_ip ttl 255
ip link set gre${id} mtu 1400
ip link set gre${id} up
ip addr add $tun_local/30 dev gre${id}
EOF
    chmod +x "/usr/local/bin/ipsec-gre-up-${id}.sh"

    cat > "/etc/systemd/system/ipsec-gre-${id}.service" <<EOF
[Unit]
Description=GRE over IPsec Tunnel ${id}
After=strongswan-swanctl.service network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ipsec-gre-up-${id}.sh
ExecStartPost=-/usr/sbin/swanctl --initiate --child tun${id}
RemainAfterExit=yes
ExecStop=/sbin/ip tunnel del gre${id}
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "ipsec-gre-${id}"
    systemctl restart "ipsec-gre-${id}"
}

setup_keepalive() {
    local id=$1; local target=$2
    cat > "/usr/local/bin/ipsec-keepalive-${id}.sh" <<EOF
#!/bin/bash
while true; do
    if ! ping -c 4 -W 2 $target > /dev/null; then
        swanctl --initiate --child tun$id
        systemctl restart ipsec-gre-$id
        sleep 5
    fi
    sleep 5
done
EOF
    chmod +x "/usr/local/bin/ipsec-keepalive-${id}.sh"
    cat > "/etc/systemd/system/ipsec-keepalive-${id}.service" <<EOF
[Unit]
Description=Keepalive for IPsec Tunnel ${id}
After=ipsec-gre-${id}.service
[Service]
ExecStart=/usr/local/bin/ipsec-keepalive-${id}.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "ipsec-keepalive-${id}"
    systemctl restart "ipsec-keepalive-${id}"
}

batch_install() {
    echo -e "${BLUE}--- Batch Install IPsec+GRE Tunnels ---${NC}"
    echo "1) IRAN Server (Initiator/Hub)"
    echo "2) KHAREJ Server (Responder/Spoke)"
    read -p "Select Role: " role_opt
    read -p "Enter Starting Tunnel ID [1-99]: " START_TUN_ID
    [[ ! "$START_TUN_ID" =~ ^[0-9]+$ ]] && START_TUN_ID=1

    local available_ips=($(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1))
    echo "Available Local IPs: ${available_ips[*]}"
    read -p "Enter Remote Server Public IPs (space separated): " -a REMOTE_IPS_INPUT
    
    read -p "Enter IPsec PSK (Leave empty for random): " PSK
    if [ -z "$PSK" ]; then
        PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
        echo -e "Generated PSK: ${YELLOW}$PSK${NC}"
    fi

    install_dependencies
    configure_firewall

    local loop_count=${#REMOTE_IPS_INPUT[@]}
    for (( i=0; i<loop_count; i++ )); do
        CURRENT_ID=$((START_TUN_ID + i))
        CURRENT_LOCAL_IP=${available_ips[0]} # Defaulting to first IP for simplicity in batch
        CURRENT_REMOTE_IP=${REMOTE_IPS_INPUT[$i]}
        
        g_loc="172.20.${CURRENT_ID}.1"; g_rem="172.20.${CURRENT_ID}.2"
        if [ "$role_opt" == "2" ]; then tmp=$g_loc; g_loc=$g_rem; g_rem=$tmp; fi

        echo -e "\n${BLUE}Setting up Tunnel #$CURRENT_ID...${NC}"
        setup_swanctl_config "$CURRENT_ID" "$CURRENT_LOCAL_IP" "$CURRENT_REMOTE_IP" "$PSK"
        setup_gre_interface "$CURRENT_ID" "$CURRENT_LOCAL_IP" "$CURRENT_REMOTE_IP" "$g_loc" "$g_rem"
        setup_keepalive "$CURRENT_ID" "$g_rem"
    done
    read -p "Done. Press Enter..."
}

uninstall_menu() {
    read -p "Enter Tunnel ID to uninstall (or 'all'): " TUN_ID
    if [ "$TUN_ID" == "all" ]; then
        systemctl stop ipsec-gre-* ipsec-keepalive-* 2>/dev/null
        rm -f /etc/systemd/system/ipsec-gre-* /etc/systemd/system/ipsec-keepalive-*
        rm -f /usr/local/bin/ipsec-gre-up-* /usr/local/bin/ipsec-keepalive-*
        rm -f "$CONF_D_DIR/tun*.conf"
        swanctl --terminate --ike "*" 2>/dev/null
        echo "All tunnels removed."
    else
        systemctl stop "ipsec-gre-$TUN_ID" "ipsec-keepalive-$TUN_ID" 2>/dev/null
        rm -f "/etc/systemd/system/ipsec-gre-$TUN_ID.service" "$CONF_D_DIR/tun$TUN_ID.conf"
        echo "Tunnel $TUN_ID removed."
    fi
    systemctl daemon-reload
}

while true; do
    clear
    echo -e "${GREEN}   Swanctl IPsec BATCH Manager (With MSS Clamping)   ${NC}"
    echo "1) Batch Install"
    echo "2) Uninstall"
    echo "0) Exit"
    read -p "Select: " opt
    case $opt in
        1) batch_install ;;
        2) uninstall_menu ;;
        0) exit 0 ;;
    esac
done
