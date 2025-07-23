# Makefile for Legacy PLC Simulator
# Optimized for Raspberry Pi Model B (ARMv6, 512MB RAM)

CXX = g++
CXXFLAGS = -std=c++11 -O2 -Wall -Wextra -pthread
TARGET = legacy_plc
SOURCES = legacy_plc.cpp

# Pi Model B specific optimizations
CXXFLAGS += -march=armv6 -mfpu=vfp -mfloat-abi=hard
CXXFLAGS += -DLEGACY_HARDWARE

# Memory constraints for 512MB system
CXXFLAGS += -fno-rtti -ffunction-sections -fdata-sections
LDFLAGS = -Wl,--gc-sections

# Debug build option
DEBUG ?= 0
ifeq ($(DEBUG), 1)
    CXXFLAGS += -g -DDEBUG
    CXXFLAGS := $(filter-out -O2,$(CXXFLAGS))
else
    CXXFLAGS += -DNDEBUG
endif

.PHONY: all clean install service status logs

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "Legacy PLC built successfully for Pi Model B"
	@ls -lh $(TARGET)

clean:
	rm -f $(TARGET) *.o
	@echo "Cleaned build artifacts"

# Install as systemd service
install: $(TARGET)
	sudo cp $(TARGET) /usr/local/bin/
	sudo cp legacy-plc.service /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable legacy-plc
	@echo "Legacy PLC installed as system service"

# Service management targets
service:
	sudo systemctl start legacy-plc
	@echo "Legacy PLC service started"

stop:
	sudo systemctl stop legacy-plc
	@echo "Legacy PLC service stopped"

status:
	sudo systemctl status legacy-plc

logs:
	sudo journalctl -u legacy-plc -f

# Create systemd service file
service-file:
	@echo "[Unit]" > legacy-plc.service
	@echo "Description=Legacy PLC Simulator" >> legacy-plc.service
	@echo "After=network.target" >> legacy-plc.service
	@echo "" >> legacy-plc.service
	@echo "[Service]" >> legacy-plc.service
	@echo "Type=simple" >> legacy-plc.service
	@echo "User=pi" >> legacy-plc.service
	@echo "ExecStart=/usr/local/bin/legacy_plc" >> legacy-plc.service
	@echo "Restart=always" >> legacy-plc.service
	@echo "RestartSec=10" >> legacy-plc.service
	@echo "" >> legacy-plc.service
	@echo "[Install]" >> legacy-plc.service
	@echo "WantedBy=multi-user.target" >> legacy-plc.service
	@echo "Systemd service file created"

# Network test client
test-client:
	@echo "Testing legacy PLC communication..."
	@echo -e "STATUS\nRI0\nRR0" | nc localhost 9001 || echo "PLC not responding"

# Monitor resources (important for Pi Model B)
monitor:
	@echo "=== System Resources ==="
	@echo "Memory usage:"
	@free -h
	@echo ""
	@echo "CPU temperature:"
	@cat /sys/class/thermal/thermal_zone0/temp | awk '{print $$1/1000"°C"}'
	@echo ""
	@echo "PLC process:"
	@ps aux | grep legacy_plc | grep -v grep || echo "PLC not running"

# Development helpers
dev: DEBUG=1
dev: clean $(TARGET)
	@echo "Debug build complete - use gdb for debugging"

valgrind: dev
	valgrind --leak-check=full --show-leak-kinds=all ./$(TARGET)

help:
	@echo "Legacy PLC Simulator - Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all         - Build the PLC simulator"
	@echo "  clean       - Remove build artifacts"
	@echo "  install     - Install as systemd service"
	@echo "  service     - Start the PLC service"
	@echo "  stop        - Stop the PLC service"
	@echo "  status      - Show service status"
	@echo "  logs        - Show live service logs"
	@echo "  test-client - Test PLC communication"
	@echo "  monitor     - Show system resources"
	@echo "  dev         - Build debug version"
	@echo ""
	@echo "Environment:"
	@echo "  DEBUG=1     - Enable debug build"
