#!/bin/bash
# Legacy PLC Deployment System
# Deploys legacy_plc to pi-legacy (Pi2) and configures autostart

set -e  # Exit on any error

# Configuration
PI_HOST="pi-legacy"
PI_IP="192.168.10.15"
PI_USER="pi"  # Default Pi user
SERVICE_NAME="legacy-plc"
INSTALL_DIR="/opt/legacy-plc"
LOG_DIR="/var/log/legacy-plc"

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
Legacy PLC Deployment Script

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    build       - Cross-compile for Pi2 target
    deploy      - Deploy binary and configs to pi-legacy
    service     - Install and enable systemd service
    full        - Complete deployment (build + deploy + service)
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
    $0 full                          # Complete deployment
    $0 deploy --host 192.168.10.15  # Deploy to specific IP
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

# Resource limits
MemoryMax=128M
CPUQuota=50%

# Network settings for control VLAN
Environment="PLC_CONTROL_VLAN=192.168.10.15"
Environment="PLC_MGMT_VLAN=192.168.99.15"

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=legacy-plc

[Install]
WantedBy=multi-user.target
EOF
}

deploy_to_pi() {
    echo_info "Deploying to $PI_HOST..."
    
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
    
    echo_success "Deployment complete"
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
        ss -tulnp | grep 9001 || echo "Port 9001 not listening"
        
        echo -e "\n=== Process Status ==="
        ps aux | grep legacy_plc | grep -v grep || echo "Process not running"
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
        build|deploy|service|full|start|stop|status|logs|uninstall|test)
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
    service)
        check_dependencies
        install_service
        ;;
    full)
        echo_info "Starting full deployment to $PI_HOST..."
        check_dependencies
        build_for_pi
        deploy_to_pi
        install_service
        test_functionality
        echo_success "Full deployment complete!"
        echo_info "Service is now running and will autostart on boot"
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