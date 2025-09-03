#!/bin/bash
# Legacy PLC Deployment System - VirtualBox VM
# Cross-compiles and deploys to minimal VM (matches Pi constraints)

set -e  # Exit on any error

# Configuration - VM specific
VM_HOST="localhost"  # Default for local VM
VM_IP="127.0.0.1"
VM_USER="user"       # Default VM user (adjust as needed)
VM_SSH_PORT="2222"   # Default VirtualBox SSH port forwarding
SERVICE_NAME="legacy-plc"
INSTALL_DIR="/opt/legacy-plc"
LOG_DIR="/var/log/legacy-plc"
WEB_DIR="/var/www/plc-dashboard"

# VM-specific ports (different from Pi to avoid conflicts)
CONTROL_PORT="9901"
MGMT_PORT="8901"
DASHBOARD_PORT="8000"

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
Legacy PLC Deployment Script - VirtualBox VM

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    build       - Build virtual version for VM
    deploy      - Deploy binary and configs to VM
    dashboard   - Deploy web dashboard only
    service     - Install and enable systemd service
    full        - Complete deployment (build + deploy + dashboard + service)
    start       - Start the service on VM
    stop        - Stop the service on VM
    status      - Check service status
    logs        - Show service logs
    uninstall   - Remove service and files
    test        - Test connectivity and basic functionality

Options:
    --host HOST     - VM hostname/IP (default: $VM_HOST)
    --user USER     - SSH username (default: $VM_USER)
    --ssh-port PORT - SSH port (default: $VM_SSH_PORT for VirtualBox)
    --force         - Skip confirmation prompts

VM Port Configuration:
    Control Protocol:  $CONTROL_PORT (vs 9001 on Pi)
    Management API:    $MGMT_PORT (vs 8080 on Pi)  
    Dashboard:         $DASHBOARD_PORT

Examples:
    $0 full                              # Deploy to local VM
    $0 deploy --host 192.168.56.101     # Deploy to bridged VM
    $0 status                            # Check VM service status
    $0 test                              # Test VM functionality

VM Setup Requirements:
    - Minimal Linux VM (512MB RAM, 1 CPU)
    - SSH enabled with key-based auth
    - sudo access for deployment user
    - No build tools required on VM
EOF
}

check_dependencies() {
    echo_info "Checking dependencies for VM deployment..."
    
    # Check if we can build locally (no cross-compilation needed for x86 VM)
    if ! command -v g++ &> /dev/null; then
        echo_error "g++ compiler not found. Install with:"
        echo "  sudo apt install build-essential"
        exit 1
    fi
    
    # Check SSH connectivity to VM
    SSH_CMD="ssh -p $VM_SSH_PORT"
    echo_info "Testing SSH connection to $VM_USER@$VM_HOST:$VM_SSH_PORT..."
    
    # Try passwordless connection first
    if $SSH_CMD -o ConnectTimeout=5 -o BatchMode=yes $VM_USER@$VM_HOST "exit" 2>/dev/null; then
        echo_success "Passwordless SSH connection verified"
    else
        echo_warning "Passwordless SSH not available - testing basic connectivity..."
        
        # Test basic SSH connectivity (may prompt for password)
        if $SSH_CMD -o ConnectTimeout=10 $VM_USER@$VM_HOST "exit" 2>/dev/null; then
            echo_warning "SSH works but requires password authentication"
            echo_info "Consider setting up SSH keys for passwordless deployment:"
            echo "  ssh-copy-id -p $VM_SSH_PORT $VM_USER@$VM_HOST"
            echo_info "Continuing with password-based authentication..."
        else
            echo_error "Cannot connect to VM at $VM_HOST:$VM_SSH_PORT via SSH"
            echo "Setup instructions:"
            echo "  1. Verify VM IP: $VM_HOST"
            echo "  2. Verify SSH port: $VM_SSH_PORT" 
            echo "  3. Verify username: $VM_USER"
            echo "  4. Test manually: ssh -p $VM_SSH_PORT $VM_USER@$VM_HOST"
            exit 1
        fi
    fi
    
    # Check for dashboard file
    if [ ! -f "plc_dashboard.html" ]; then
        echo_warning "Dashboard file not found - dashboard deployment will be skipped"
        echo "Create plc_dashboard.html from the provided HTML code"
    fi
    
    echo_success "Dependencies satisfied for VM deployment"
}

build_for_vm() {
    echo_info "Building virtual version for VM (x86/x64)..."
    
    # Clean and build virtual version
    make clean
    make virtual  # Virtual hardware mode
    
    if [ ! -f "legacy_plc" ]; then
        echo_error "Build failed - binary not found"
        exit 1
    fi
    
    # Verify x86/x64 binary
    file legacy_plc | grep -q -E "(x86|ELF)" || {
        echo_error "Build produced unexpected binary format"
        file legacy_plc
        exit 1
    }
    
    echo_success "Virtual build complete"
}

create_vm_systemd_service() {
    cat << EOF
[Unit]
Description=Legacy PLC Simulator (Virtual Mode)
Documentation=man:legacy_plc(1)
After=network.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=$VM_USER
Group=$VM_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/legacy_plc
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
TimeoutStopSec=20

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$LOG_DIR /tmp

# Resource limits for minimal VM (512MB RAM, 1 CPU)
MemoryMax=64M
CPUQuota=25%

# Virtual mode environment
Environment="PLC_MODE=virtual"
Environment="PLC_CONTROL_PORT=$CONTROL_PORT"
Environment="PLC_MGMT_PORT=$MGMT_PORT"

# Logging configuration
StandardOutput=journal
StandardError=journal
SyslogIdentifier=legacy-plc-vm

[Install]
WantedBy=multi-user.target
EOF
}

create_vm_nginx_config() {
    cat << EOF
server {
    listen $DASHBOARD_PORT default_server;
    server_name _;
    root $WEB_DIR;
    index index.html;
    
    # Disable caching for real-time dashboard
    location / {
        try_files \$uri \$uri/ =404;
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
        return 200 "VM Dashboard OK\\n";
        add_header Content-Type text/plain;
    }
    
    # VM-specific info endpoint
    location /vm-info {
        access_log off;
        return 200 "Virtual Mode: Ports $CONTROL_PORT/$MGMT_PORT/$DASHBOARD_PORT\\n";
        add_header Content-Type text/plain;
    }
}
EOF
}

deploy_to_vm() {
    echo_info "Deploying PLC binary to VM at $VM_HOST:$VM_SSH_PORT..."
    
    SSH_CMD="ssh -p $VM_SSH_PORT"
    SCP_CMD="scp -P $VM_SSH_PORT"
    
    # Test sudo access and provide helpful error message
    echo_info "Testing sudo access on VM..."
    
    # Try a simple sudo command that should work if passwordless sudo is set up
    if $SSH_CMD $VM_USER@$VM_HOST "sudo whoami" 2>/dev/null | grep -q "root"; then
        echo_success "Passwordless sudo verified"
    else
        echo_warning "Testing alternative sudo method..."
        # Try with -n flag (non-interactive)
        if $SSH_CMD $VM_USER@$VM_HOST "sudo -n whoami" 2>/dev/null | grep -q "root"; then
            echo_success "Passwordless sudo verified (non-interactive)"
        else
            echo_error "Sudo access test failed. Debug information:"
            echo "Testing sudo configuration on VM..."
            
            # Show debug information
            $SSH_CMD $VM_USER@$VM_HOST "echo 'Testing sudo with whoami:'; sudo whoami 2>&1; echo 'Exit code: $?'"
            
            echo ""
            echo "If sudo is working manually but failing in the script, try:"
            echo "  1. Check sudoers file: sudo cat /etc/sudoers.d/user"
            echo "  2. Verify syntax: sudo visudo -c"
            echo "  3. Alternative: echo '$VM_USER ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/$VM_USER"
            echo ""
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
            echo_warning "Continuing with potential sudo issues..."
        fi
    fi
    
    # Create directories on VM
    $SSH_CMD $VM_USER@$VM_HOST "sudo mkdir -p $INSTALL_DIR $LOG_DIR"
    $SSH_CMD $VM_USER@$VM_HOST "sudo chown $VM_USER:$VM_USER $INSTALL_DIR $LOG_DIR"
    
    # Copy binary
    echo_info "Copying binary to VM..."
    $SCP_CMD legacy_plc $VM_USER@$VM_HOST:$INSTALL_DIR/
    $SSH_CMD $VM_USER@$VM_HOST "chmod +x $INSTALL_DIR/legacy_plc"
    
    # Copy service file
    echo_info "Installing systemd service..."
    create_vm_systemd_service | $SSH_CMD $VM_USER@$VM_HOST "sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null"
    
    # Copy any config files (if they exist)
    if [ -f "legacy_plc.conf" ]; then
        echo_info "Copying configuration..."
        $SCP_CMD legacy_plc.conf $VM_USER@$VM_HOST:$INSTALL_DIR/
    fi
    
    echo_success "PLC deployment to VM complete"
}

deploy_dashboard() {
    if [ ! -f "plc_dashboard.html" ]; then
        echo_warning "Dashboard file not found - skipping dashboard deployment"
        return 0
    fi
    
    echo_info "Deploying dashboard to VM at $VM_HOST:$VM_SSH_PORT..."
    
    SSH_CMD="ssh -p $VM_SSH_PORT"
    SCP_CMD="scp -P $VM_SSH_PORT"
    
    # Create web directory on VM
    $SSH_CMD $VM_USER@$VM_HOST "sudo mkdir -p $WEB_DIR"
    $SSH_CMD $VM_USER@$VM_HOST "sudo chown $VM_USER:$VM_USER $WEB_DIR"
    
    # Copy dashboard
    $SCP_CMD plc_dashboard.html $VM_USER@$VM_HOST:$WEB_DIR/index.html
    
    # Install and configure nginx on VM
    $SSH_CMD $VM_USER@$VM_HOST << 'REMOTE_SCRIPT'
        # Update package list
        sudo apt update
        
        # Install nginx if not present (minimal installation)
        if ! command -v nginx &> /dev/null; then
            echo "Installing nginx (minimal)..."
            sudo apt install -y nginx-light
        fi
        
        # Remove default nginx site
        sudo rm -f /etc/nginx/sites-enabled/default
REMOTE_SCRIPT
    
    # Send nginx config through SSH
    create_vm_nginx_config | $SSH_CMD $VM_USER@$VM_HOST "sudo tee /etc/nginx/sites-available/plc-dashboard > /dev/null"
    
    # Enable and start nginx
    $SSH_CMD $VM_USER@$VM_HOST << 'REMOTE_SCRIPT'
        # Enable site
        sudo ln -sf /etc/nginx/sites-available/plc-dashboard /etc/nginx/sites-enabled/
        
        # Test nginx config
        if sudo nginx -t; then
            sudo systemctl restart nginx
            sudo systemctl enable nginx
            echo "? Nginx configured and started on VM"
        else
            echo "? Nginx configuration error"
            exit 1
        fi
REMOTE_SCRIPT
    
    echo_success "Dashboard deployed to VM: http://$VM_HOST:$DASHBOARD_PORT"
    echo_info "VM dashboard health check: http://$VM_HOST:$DASHBOARD_PORT/health"
}

install_service() {
    echo_info "Installing and enabling service on VM..."
    
    SSH_CMD="ssh -p $VM_SSH_PORT"
    
    $SSH_CMD $VM_USER@$VM_HOST << 'REMOTE_SCRIPT'
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
    
    echo_success "Service installed and started on VM"
}

check_service_status() {
    echo_info "Checking service status on VM..."
    
    SSH_CMD="ssh -p $VM_SSH_PORT"
    
    $SSH_CMD $VM_USER@$VM_HOST << REMOTE_SCRIPT
        echo "=== VM Service Status ==="
        sudo systemctl status legacy-plc.service --no-pager
        
        echo -e "\n=== Recent Logs ==="
        sudo journalctl -u legacy-plc.service -n 10 --no-pager
        
        echo -e "\n=== Network Status (VM Ports) ==="
        ss -tulnp | grep -E "($CONTROL_PORT|$MGMT_PORT|$DASHBOARD_PORT)" || echo "VM ports not listening"
        
        echo -e "\n=== Process Status ==="
        ps aux | grep legacy_plc | grep -v grep || echo "Process not running"
        
        echo -e "\n=== VM Resource Usage ==="
        free -h | head -2
        echo "CPU: \$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - \$1"%"}')"
        
        echo -e "\n=== Dashboard Status ==="
        if command -v nginx &> /dev/null; then
            sudo systemctl status nginx --no-pager | head -3
            curl -s http://localhost:$DASHBOARD_PORT/health || echo "Dashboard not responding"
        else
            echo "Nginx not installed"
        fi
REMOTE_SCRIPT
}

test_functionality() {
    echo_info "Testing VM PLC functionality..."
    
    # Wait for service to start
    sleep 3
    
    # Test basic connectivity to VM ports
    echo_info "Testing VM network connectivity..."
    if echo "STATUS" | nc -w 5 $VM_HOST $CONTROL_PORT; then
        echo_success "VM control protocol test passed (port $CONTROL_PORT)"
    else
        echo_error "VM control protocol test failed"
        return 1
    fi
    
    # Test various commands
    echo_info "Testing VM protocol commands..."
    
    for cmd in "RI0" "RO0" "RR0" "RR1"; do
        echo -n "Testing $cmd: "
        result=$(echo "$cmd" | nc -w 5 $VM_HOST $CONTROL_PORT)
        if [ $? -eq 0 ]; then
            echo "? Response: $result"
        else
            echo "? Failed"
        fi
    done
    
    # Test management interface
    echo_info "Testing VM management interface..."
    if curl -s "http://$VM_HOST:$MGMT_PORT/" > /dev/null; then
        echo_success "VM management interface responding (port $MGMT_PORT)"
    else
        echo_warning "VM management interface not responding"
    fi
    
    # Test dashboard
    echo_info "Testing VM dashboard..."
    if curl -s "http://$VM_HOST:$DASHBOARD_PORT/health" | grep -q "Dashboard OK"; then
        echo_success "VM dashboard health check passed (port $DASHBOARD_PORT)"
    else
        echo_warning "VM dashboard not responding"
    fi
    
    echo_success "VM functionality test complete"
}

show_logs() {
    echo_info "Showing logs from VM..."
    SSH_CMD="ssh -p $VM_SSH_PORT"
    $SSH_CMD $VM_USER@$VM_HOST "sudo journalctl -u legacy-plc.service -f"
}

uninstall_service() {
    echo_warning "This will remove the legacy PLC service and files from VM"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        SSH_CMD="ssh -p $VM_SSH_PORT"
        $SSH_CMD $VM_USER@$VM_HOST << 'REMOTE_SCRIPT'
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
        echo_success "VM uninstall complete"
    else
        echo_info "VM uninstall cancelled"
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
            VM_HOST="$2"
            VM_IP="$2"
            shift 2
            ;;
        --user)
            VM_USER="$2"
            shift 2
            ;;
        --ssh-port)
            VM_SSH_PORT="$2"
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
        build_for_vm
        ;;
    deploy)
        check_dependencies
        deploy_to_vm
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
        echo_info "Starting full VM deployment to $VM_HOST:$VM_SSH_PORT..."
        check_dependencies
        build_for_vm
        deploy_to_vm
        deploy_dashboard
        install_service
        test_functionality
        echo_success "Full VM deployment complete!"
        echo_info "VM Control:     http://$VM_HOST:$CONTROL_PORT (ASCII protocol)"
        echo_info "VM Management:  http://$VM_HOST:$MGMT_PORT (JSON API)"
        echo_info "VM Dashboard:   http://$VM_HOST:$DASHBOARD_PORT (Web interface)"
        ;;
    start)
        SSH_CMD="ssh -p $VM_SSH_PORT"
        $SSH_CMD $VM_USER@$VM_HOST "sudo systemctl start legacy-plc.service"
        echo_success "VM service started"
        ;;
    stop)
        SSH_CMD="ssh -p $VM_SSH_PORT"
        $SSH_CMD $VM_USER@$VM_HOST "sudo systemctl stop legacy-plc.service"
        echo_success "VM service stopped"
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
