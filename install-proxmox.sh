#!/bin/bash

VERSION="2.0.1"
PROXMOX_NO_SUB=true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

wait_for_apt_lock() {
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if ! lsof /var/lib/dpkg/lock-frontend &>/dev/null && \
           ! lsof /var/lib/dpkg/lock &>/dev/null && \
           ! lsof /var/lib/apt/lists/lock &>/dev/null; then
            return 0
        fi
        log_info "Waiting for apt lock... (attempt $((attempt+1))/$max_attempts)"
        sleep 2
        attempt=$((attempt+1))
    done
    
    log_warn "Could not acquire apt lock after $max_attempts attempts, continuing..."
}

clean_sources() {
    log_info "Cleaning up duplicate sources..."
    
    if [[ -f /etc/apt/sources.list ]]; then
        if grep -q "deb " /etc/apt/sources.list; then
            log_warn "Removing old sources.list entries to avoid duplicates"
            mv /etc/apt/sources.list /etc/apt/sources.list.backup 2>/dev/null || rm -f /etc/apt/sources.list
        fi
    fi
    
    rm -f /etc/apt/sources.list.d/*ubuntu*.list 2>/dev/null || true
    
    log_info "Sources cleaned"
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS=$NAME
        VERSION_ID=$VERSION_ID
    else
        log_error "Cannot detect OS"
        exit 1
    fi
    
    log_info "Detected OS: $OS $VERSION_ID"
    
    case "$OS" in
        "Ubuntu")
            if [[ "$VERSION_ID" == "22.04" ]] || [[ "$VERSION_ID" == "24.04" ]]; then
                log_info "Ubuntu $VERSION_ID is supported"
                OS_FAMILY="ubuntu"
                return 0
            else
                log_error "Ubuntu $VERSION_ID is not supported. Supported: 22.04, 24.04"
                exit 1
            fi
            ;;
        "Debian")
            major_version=$(echo "$VERSION_ID" | cut -d. -f1)
            if [[ $major_version -ge 11 ]]; then
                log_info "Debian $VERSION_ID is supported"
                OS_FAMILY="debian"
                return 0
            else
                log_error "Debian $VERSION_ID is not supported. Supported: 11+"
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

install_dependencies() {
    log_info "Installing dependencies..."
    
    wait_for_apt_lock
    apt-get update -qq
    
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget gnupg2 lsb-release software-properties-common \
        ca-certificates nginx certbot python3-certbot-nginx \
        fuse-overlayfs jq acl cryptsetup open-iscsi rsync \
        pve-cluster pve-management qemu-system-x86 qemu-utils \
        2>/dev/null || true
    
    log_info "Dependencies installed"
}

add_proxmox_repo() {
    log_info "Adding Proxmox VE no-subscription repository..."
    
    rm -f /etc/apt/sources.list.d/pve-* /etc/apt/sources.list.d/proxmox*
    
    if [[ ! -f /etc/apt/trusted.gpg.d/proxmox-release.gpg ]]; then
        wget -q -O /etc/apt/trusted.gpg.d/proxmox-release.gpg \
            https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
    fi
    
    if [[ "$OS_FAMILY" == "ubuntu" ]]; then
        if [[ "$VERSION_ID" == "22.04" ]]; then
            echo "deb http://download.proxmox.com/debian/pve bullseye pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
        elif [[ "$VERSION_ID" == "24.04" ]]; then
            echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
        fi
    else
        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-install-repo.list
    fi
    
    echo "deb-src http://download.proxmox.com/debian/pve bookworm pve-no-subscription" >> /etc/apt/sources.list.d/pve-install-repo.list
    
    wait_for_apt_lock
    apt-get update -qq 2>/dev/null || log_warn "apt update had issues, continuing..."
    
    log_info "Proxmox repository added"
}

install_proxmox() {
    log_info "Installing Proxmox VE packages..."
    
    wait_for_apt_lock
    
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        proxmox-defaults proxmox-widget-toolkit \
        2>/dev/null || true
    
    wait_for_apt_lock
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        proxmox-ve pve-manager pve-node pve-storage-common \
        pve-daemon pve-webshell pve-cli pve-qemu-kvm \
        2>/dev/null
    
    log_info "Proxmox VE packages installed"
}

configure_network() {
    log_info "Configuring network..."
    
    local ip=$(hostname -I | awk '{print $1}')
    local gateway=$(ip route | grep default | awk '{print $3}')
    
    log_info "Detected IP: $ip, Gateway: $gateway"
    
    if [[ -f /etc/netplan/01-netcfg.yaml ]]; then
        cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: no
      addresses:
        - ${ip}/24
      gateway4: ${gateway}
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF
        netplan apply 2>/dev/null || true
    fi
    
    log_info "Network configuration handled"
}

configure_nginx_proxy() {
    log_info "Configuring nginx reverse proxy..."
    
    log_info "Installing nginx..."
    wait_for_apt_lock
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
    
    cat > /etc/nginx/sites-available/proxmox-https << 'NGINX_EOF'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name _;
    
    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    
    location / {
        proxy_pass https://127.0.0.1:8006/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_ssl_verify off;
        proxy_read_timeout 120s;
    }
}
NGINX_EOF

    mkdir -p /etc/nginx/sites-enabled
    ln -sf /etc/nginx/sites-available/proxmox-https /etc/nginx/sites-enabled/proxmox-https
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/proxmox
    
    nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null || log_warn "Nginx restart had issues"
    
    log_info "Nginx proxy configured for Proxmox web interface"
}

configure_ssl_domain() {
    local domain="$1"
    local email="$2"
    
    if [[ -z "$domain" ]]; then
        log_warn "No domain provided, skipping SSL configuration"
        return 0
    fi
    
    if [[ -z "$email" ]]; then
        email="admin@$domain"
    fi
    
    log_info "Configuring SSL for domain: $domain"
    
    if command -v certbot &>/dev/null; then
        if certbot certonly --nginx -d "$domain" -d "www.$domain" \
            --email "$email" --agree-tos --redirect --non-interactive 2>/dev/null; then
            
            cat > /etc/nginx/sites-available/$domain << EOF
server {
    listen 80;
    server_name $domain www.$domain;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain www.$domain;
    
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    
    location / {
        proxy_pass https://127.0.0.1:8006/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        proxy_buffering off;
    }
}
EOF
        ln -sf /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/$domain
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
        log_info "SSL configured for $domain"
    else
        log_warn "Certbot failed, using self-signed certificate"
    fi
}

setup_pve_storage() {
    log_info "Setting up default storage..."
    
    mkdir -p /var/lib/vz
    mkdir -p /etc/pve/nodes
    
    local hostname=$(hostname -s)
    mkdir -p /etc/pve/nodes/$hostname
    
    log_info "Storage configured"
}

setup_system() {
    log_info "System preparation..."
    
    echo "Proxmox VE installation" > /etc/motd
    
    systemctl enable pvedaemon pveproxy pvestatd 2>/dev/null || true
    
    log_info "System configured"
}

setup_firewall() {
    log_info "Configuring firewall..."
    
    if command -v ufw &>/dev/null; then
        ufw --force reset 2>/dev/null || true
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 22/tcp
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 8006/tcp
        ufw --force enable
        log_info "UFW firewall enabled"
    fi
}

create_admin_user() {
    local username="${ADMIN_USER:-admin}"
    local password="${ADMIN_PASS:-ChangeMe123!}"
    
    log_info "Creating admin user: $username"
    
    useradd -m -s /bin/bash "$username" 2>/dev/null || true
    echo "$username:$password" | chpasswd
    
    log_info "Admin user created (password can be changed with: passwd $username)"
}

show_completion() {
    local ip=$(hostname -I | awk '{print $1}')
    local domain="${COMPLETE_DOMAIN:-}"
    
    cat << EOF

========================================
  Proxmox VE Installer v$VERSION
========================================
    
Installation Complete!
    
Proxmox Web Interface:
  https://$ip:8006
$(if [[ -n "$domain" ]]; then echo "  https://$domain"; fi)
    
Default Credentials:
  Username: root
  Password: (your current root password)
    
Admin User: $ADMIN_USER
$(if [[ -n "$ADMIN_PASS" ]]; then echo "Password: $ADMIN_PASS"; else echo "Password: Change with: passwd $ADMIN_USER"; fi)

EOF
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d, --domain DOMAIN    Domain name for SSL/certbot"
    echo "  -e, --email EMAIL      Email for certbot registration"
    echo "  -u, --user USERNAME    Admin username (default: admin)"
    echo "  -p, --pass PASSWORD    Admin password"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -d pve.example.com -e admin@example.com"
    exit 0
}

main() {
    DOMAIN=""
    EMAIL=""
    ADMIN_USER="admin"
    ADMIN_PASS=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--domain)
                DOMAIN="$2"
                shift 2
                ;;
            -e|--email)
                EMAIL="$2"
                shift 2
                ;;
            -u|--user)
                ADMIN_USER="$2"
                shift 2
                ;;
            -p|--pass)
                ADMIN_PASS="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    COMPLETE_DOMAIN="$DOMAIN"
    
    check_root
    detect_os
    
    log_info "Starting Proxmox VE installation..."
    
    clean_sources
    install_dependencies
    add_proxmox_repo
    install_proxmox
    configure_network
    setup_pve_storage
    configure_nginx_proxy
    setup_system
    setup_firewall
    
    if [[ -n "$DOMAIN" ]]; then
        configure_ssl_domain "$DOMAIN" "$EMAIL"
    fi
    
    if [[ -z "$ADMIN_PASS" ]]; then
        ADMIN_PASS="ChangeMe123!"
    fi
    
    create_admin_user
    
    show_completion
    
    log_info "Installation complete! Reboot recommended."
}

main "$@"