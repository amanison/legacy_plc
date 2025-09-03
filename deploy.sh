#!/bin/bash
# Legacy PLC Deployment System - Raspberry Pi
# Deploys legacy_plc to pi-legacy (Pi2) and configures autostart with dashboard

set -e  # Exit on any error

# Configuration
PI_HOST="pi-legacy"
PI_IP="192.168.10.15"
PI_USER="pi"  # Default Pi user
SERVICE_NAME="legacy-plc"
INSTALL_DIR="/opt/legacy-plc"
LOG_DIR="/var/log/legacy-plc"
WEB_DIR="/var/www/plc-dashboard"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
echo_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
echo_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Legacy PLC Deployment Script - Raspberry Pi

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    build       - Cross-compile for Pi2 target
    deploy      - Deploy binary and configs to pi-legacy
    dashboard   - Deploy web dashboard only
    service     - Install and enable systemd service
    full        - Complete deployment (build + deploy + dashboard + service)
    start       - Start the service on pi-legacy
    stop        - Stop the service on pi-legacy
    status      - Check service status
    logs        - Show service logs
    uninstall   - Remove service and files
    test        - Test connectivity and basic functionality

Options:
    --host HOST     - Target hostname/IP (default: $PI_HOST)
    --user USER     - SSH username (default: $PI_USER)
    --force         - Skip confirmation prompts

Examples:
    $0 full                          # Complete deployment with dashboard
    $0 deploy --host 192.168.10.15  # Deploy to specific IP
    $0 dashboard                     # Deploy/update dashboard only
    $0 status                        # Check if service is running
    $0 logs                          # View recent logs
EOF
}

check_dependencies() {
    echo_info "Checking dependencies..."
    
    # Check cross-compiler
    if ! command -v arm-linux-gnueabihf-g++ &> /dev/null; then
        echo_error "Cross-compiler not found. Install with:"
        echo "  sudo apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf"
        exit 1
    fi
    
    # Check SSH connectivity
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes $PI_USER@$PI_HOST "exit" 2>/dev/null; then
        echo_error "Cannot connect to $PI_HOST via SSH"
        echo "Ensure SSH keys are configured or password-less login is set up"
        exit 1
    fi
    
    # Check for dashboard file
    if [ ! -f "plc_dashboard.html" ]; then
        echo_warning "Dashboard file not found - dashboard deployment will be skipped"
        echo "Create plc_dashboard.html from the provided HTML code"
    fi
    
    echo_success "Dependencies satisfied"
}

build_for_pi() {
    echo_info "Cross-compiling for Pi2 (ARMv7)..."
    
    # Clean and build
    make clean
    make cross-pi-2  # Pi2 optimized build
    
    if [ ! -f "legacy_plc" ]; then
        echo_error "Build failed - binary not found"
        exit 1
    fi
    
    # Verify ARM binary
    file legacy_plc | grep -q "ARM" || {
        echo_error "Build produced non-ARM binary"
        exit 1
    }
    
    echo_success "Cross-compilation complete"
}

create_systemd_service() {
    cat << 'EOF'
[Unit]
Description=Legacy PLC Simulator
Documentation=man:legacy_plc(1)
After=network.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=pi
Group=pi
WorkingDirectory=/opt/legacy-plc
ExecStart=/opt/legacy-plc/legacy_plc
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
TimeoutStopSec=20

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/legacy-plc /tmp

# Resource limits for Pi2
MemoryMax=128M
CPUQuota=50%

# Network settings for cluster integration
Environment="PLC_CONTROL_VLAN=192.168.10.15"
Environment="PLC_MGMT_VLAN=192.168.99.15"
Environment="PLC_NODE_TYPE=legacy"

# Logging configuration
StandardOutput=journal
StandardError=journal
SyslogIdentifier=legacy-plc

[Install]
WantedBy=multi-user.target
EOF
}

create_nginx_config() {
    cat << 'EOF'
server {
    listen 8000 default_server;
    server_name _;
    root /var/www/plc-dashboard;
    index index.html;
    
    # Disable caching for real-time dashboard
    location / {
        try_files $uri $uri/ =404;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }
    
    # CORS headers for API access
    location ~* \.(html|js|css)$ {
        add_header Access-Control-Allow-Origin "*";
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS";
        add_header Access-Control-Allow-Headers "Origin, Content-Type, Accept";
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "Dashboard OK\n";
        add_header Content-Type text/plain;
    }
}
EOF
}

deploy_to_pi() {
    echo_info "Deploying PLC binary to $PI_HOST..."
    
    # Create directories on Pi
    ssh $PI_USER@$PI_HOST "sudo mkdir -p $INSTALL_DIR $LOG_DIR"
    ssh $PI_USER@$PI_HOST "sudo chown $PI_USER:$PI_USER $INSTALL_DIR $LOG_DIR"
    
    # Copy binary
    echo_info "Copying binary..."
    scp legacy_plc $PI_USER@$PI_HOST:$INSTALL_DIR/
    ssh $PI_USER@$PI_HOST "chmod +x $INSTALL_DIR/legacy_plc"
    
    # Copy service file
    echo_info "Installing systemd service..."
    create_systemd_service | ssh $PI_USER@$PI_HOST "sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null"
    
    # Copy any config files (if they exist)
    if [ -f "legacy_plc.conf" ]; then
        echo_info "Copying configuration..."
        scp legacy_plc.conf $PI_USER@$PI_HOST:$INSTALL_DIR/
    fi
    
    echo_success "PLC deployment complete"
}

deploy_dashboard() {
    if [ ! -f "plc_dashboard.html" ]; then
        echo_warning "Dashboard file not found - skipping dashboard deployment"
        return 0
    fi
    
    echo_info "Deploying dashboard to $PI_HOST..."
    
    # Create web directory on Pi
    ssh $PI_USER@$PI_HOST "sudo mkdir -p $WEB_DIR"
    ssh $PI_USER@$PI_HOST "sudo chown $PI_USER:$PI_USER $WEB_DIR"
    
    # Copy dashboard
    scp plc_dashboard.html $PI_USER@$PI_HOST:$WEB_DIR/index.html
    
    # Install and configure nginx
    ssh $PI_USER@$PI_HOST << 'REMOTE_SCRIPT'
        # Update package list
        sudo apt update
        
        # Install nginx if not present
        if ! command -v nginx &> /dev/null; then
            echo "Installing nginx..."
            sudo apt install -y nginx
        fi
        
        # Remove default nginx site
        sudo rm -f /etc/nginx/sites-enabled/default
        
        # Install our nginx config
        sudo tee /etc/nginx/sites-available/plc-dashboard > /dev/null
REMOTE_SCRIPT
    
    # Send nginx config through SSH
    create_nginx_config | ssh $PI_USER@$PI_HOST "sudo tee -a /etc/nginx/sites-available/plc-dashboard > /dev/null"
    
    # Enable and start nginx
    ssh $PI_USER@$PI_HOST << 'REMOTE_SCRIPT'
        # Enable site
        sudo ln -sf /etc/nginx/sites-available/plc-dashboard /etc/nginx/sites-enabled/
        
        # Test nginx config
        if sudo nginx -t; then
            sudo systemctl restart nginx
            sudo systemctl enable nginx
            echo "? Nginx configured and started"
        else
            echo "? Nginx configuration error"
            exit 1
        fi
REMOTE_SCRIPT
    
    echo_success "Dashboard deployed to http://$PI_HOST:8000"
    echo_info "Dashboard health check: http://$PI_HOST:8000/health"
}

install_service() {
    echo_info "Installing and enabling service on $PI_HOST..."
    
    ssh $PI_USER@$PI_HOST << 'REMOTE_SCRIPT'
        # Reload systemd
        sudo systemctl daemon-reload
        
        # Enable service for autostart
        sudo systemctl enable legacy-plc.service
        
        # Start service
        sudo systemctl start legacy-plc.service
        
        # Check status
        sleep 2
        sudo systemctl status legacy-plc.service --no-pager
REMOTE_SCRIPT
    
    echo_success "Service installed and started"
}

check_service_status() {
    echo_info "Checking service status on $PI_HOST..."
    
    ssh $PI_USER@$PI_HOST << 'REMOTE_SCRIPT'
        echo "=== Service Status ==="
        sudo systemctl status legacy-plc.service --no-pager
        
        echo -e "\n=== Recent Logs ==="
        sudo journalctl -u legacy-plc.service -n 10 --no-pager
        
        echo -e "\n=== Network Status ==="
        ss -tulnp | grep -E "(9001|8000)" || echo "PLC/Dashboard ports not listening"
        
        echo -e "\n=== Process Status ==="
        ps aux | grep legacy_plc | grep -v grep || echo "Process not running"
        
        echo -e "\n=== Dashboard Status ==="
        if command -v nginx &> /dev/null; then
            sudo systemctl status nginx --no-pager | head -3
            curl -s http://localhost:8000/health || echo "Dashboard not responding"
        else
            echo "Nginx not installed"
        fi
REMOTE_SCRIPT
}

test_functionality() {
    echo_info "Testing PLC functionality..."
    
    # Wait for service to start
    sleep 3
    
    # Test basic connectivity
    echo_info "Testing network connectivity..."
    if echo "STATUS" | nc -w 5 $PI_IP 9001; then
        echo_success "Network protocol test passed"
    else
        echo_error "Network protocol test failed"
        return 1
    fi
    
    # Test various commands
    echo_info "Testing protocol commands..."
    
    for cmd in "RI0" "RO0" "RR0" "RR1"; do
        echo -n "Testing $cmd: "
        result=$(echo "$cmd" | nc -w 5 $PI_IP 9001)
        if [ $? -eq 0 ]; then
            echo "✓ Response: $result"
        else
            echo "✗ Failed"
        fi
    done
    
    # Test management interface
    echo_info "Testing management interface..."
    if curl -s "http://$PI_IP:8080/" > /dev/null; then
        echo_success "Management interface responding"
    else
        echo_warning "Management interface not responding"
    fi
    
    # Test dashboard
    echo_info "Testing dashboard..."
    if curl -s "http://$PI_IP:8000/health" | grep -q "Dashboard OK"; then
        echo_success "Dashboard health check passed"
    else
        echo_warning "Dashboard not responding"
    fi
    
    echo_success "Functionality test complete"
}

show_logs() {
    echo_info "Showing logs from $PI_HOST..."
    ssh $PI_USER@$PI_HOST "sudo journalctl -u legacy-plc.service -f"
}

uninstall_service() {
    echo_warning "This will remove the legacy PLC service and files from $PI_HOST"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ssh $PI_USER@$PI_HOST << 'REMOTE_SCRIPT'
            # Stop and disable service
            sudo systemctl stop legacy-plc.service
            sudo systemctl disable legacy-plc.service
            
            # Remove service file
            sudo rm -f /etc/systemd/system/legacy-plc.service
            sudo systemctl daemon-reload
            
            # Remove installation directory
            sudo rm -rf /opt/legacy-plc
            sudo rm -rf /var/log/legacy-plc
            
            # Remove dashboard
            sudo rm -rf /var/www/plc-dashboard
            sudo rm -f /etc/nginx/sites-available/plc-dashboard
            sudo rm -f /etc/nginx/sites-enabled/plc-dashboard
            
            # Restart nginx if it's running
            if systemctl is-active --quiet nginx; then
                sudo systemctl restart nginx
            fi
REMOTE_SCRIPT
        echo_success "Uninstall complete"
    else
        echo_info "Uninstall cancelled"
    fi
}

# Parse command line arguments
COMMAND=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        build|deploy|dashboard|service|full|start|stop|status|logs|uninstall|test)
            COMMAND="$1"
            shift
            ;;
        --host)
            PI_HOST="$2"
            PI_IP="$2"
            shift 2
            ;;
        --user)
            PI_USER="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main execution
case "$COMMAND" in
    build)
        build_for_pi
        ;;
    deploy)
        check_dependencies
        deploy_to_pi
        ;;
    dashboard)
        check_dependencies
        deploy_dashboard
        ;;
    service)
        check_dependencies
        install_service
        ;;
    full)
        echo_info "Starting full deployment to $PI_HOST..."
        check_dependencies
        build_for_pi
        deploy_to_pi
        deploy_dashboard
        install_service
        test_functionality
        echo_success "Full deployment complete!"
        echo_info "PLC Control:    http://$PI_HOST:9001 (ASCII protocol)"
        echo_info "PLC Management: http://$PI_HOST:8080 (JSON API)"
        echo_info "Dashboard:      http://$PI_HOST:8000 (Web interface)"
        echo_info "Dashboard API:  http://$PI_HOST:8000/api/ (CORS-friendly proxy)"
        echo ""
        echo_info "Service will auto-start on boot"
        echo_info "View logs with: ./deploy.sh logs"
        ;;
    start)
        ssh $PI_USER@$PI_HOST "sudo systemctl start legacy-plc.service"
        echo_success "Service started"
        ;;
    stop)
        ssh $PI_USER@$PI_HOST "sudo systemctl stop legacy-plc.service"
        echo_success "Service stopped"
        ;;
    status)
        check_service_status
        ;;
    logs)
        show_logs
        ;;
    test)
        test_functionality
        ;;
    uninstall)
        uninstall_service
        ;;
    "")
        echo_error "No command specified"
        usage
        exit 1
        ;;
    *)
        echo_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac