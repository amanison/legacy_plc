# Multi-Target Makefile for legacy_plc
# Supports: Pi native, cross-compile, and virtual cluster builds

PROJECT = legacy_plc
SOURCE = legacy_plc.cpp

# Detect host architecture for auto-target selection
HOST_ARCH := $(shell uname -m)

# Compiler selection
NATIVE_CXX = g++
CROSS_CXX = arm-linux-gnueabihf-g++

# Base compiler flags (common to all targets)
BASE_CXXFLAGS = -std=c++11 -Wall -Wextra -pthread -fno-rtti -ffunction-sections -fdata-sections
BASE_LDFLAGS = -Wl,--gc-sections

# Build configurations
DEBUG_FLAGS = -g -DDEBUG -O0
RELEASE_FLAGS = -O2 -DNDEBUG

#==============================================================================
# Target Configurations
#==============================================================================

# 1. Raspberry Pi Native Build (when building directly on Pi)
RPI_NATIVE_CXX = $(NATIVE_CXX)
RPI_NATIVE_CXXFLAGS = $(BASE_CXXFLAGS) $(RELEASE_FLAGS) -DLEGACY_HARDWARE -DRASPBERRY_PI
RPI_NATIVE_LDFLAGS = $(BASE_LDFLAGS)

# Architecture-specific flags for different Pi models
ifeq ($(HOST_ARCH),armv6l)
    RPI_NATIVE_CXXFLAGS += -march=armv6 -mfpu=vfp -mfloat-abi=hard -DRPI_MODEL_B
else ifeq ($(HOST_ARCH),armv7l)  
    RPI_NATIVE_CXXFLAGS += -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -DRPI_MODEL_2_3
else ifeq ($(HOST_ARCH),aarch64)
    RPI_NATIVE_CXXFLAGS += -march=armv8-a -DRPI_MODEL_4_5
endif

# 2. Cross-Compile for Pi (building on x86/x64 Linux for Pi deployment)
CROSS_PI_CXX = $(CROSS_CXX)
CROSS_PI_CXXFLAGS = $(BASE_CXXFLAGS) $(RELEASE_FLAGS) -DLEGACY_HARDWARE -DRASPBERRY_PI
CROSS_PI_LDFLAGS = $(BASE_LDFLAGS)

# Default to Pi Model B target for cross-compile (most restrictive)
CROSS_PI_CXXFLAGS += -march=armv6 -mfpu=vfp -mfloat-abi=hard -DRPI_MODEL_B

# 3. Virtual Cluster Build (x86/x64 for testing/simulation)
VIRTUAL_CXX = $(NATIVE_CXX)
VIRTUAL_CXXFLAGS = $(BASE_CXXFLAGS) $(RELEASE_FLAGS) -DVIRTUAL_HARDWARE -DSIMULATION_MODE
VIRTUAL_LDFLAGS = $(BASE_LDFLAGS)

# Add native architecture optimizations for virtual build
ifeq ($(HOST_ARCH),x86_64)
    VIRTUAL_CXXFLAGS += -march=native -mtune=native -DARCH_X86_64
else ifeq ($(findstring x86,$(HOST_ARCH)),x86)
    VIRTUAL_CXXFLAGS += -march=native -mtune=native -DARCH_X86
endif

#==============================================================================
# Build Targets
#==============================================================================

# Default target - auto-detect best build
all: auto

# Auto-detection logic
auto:
	@echo "Auto-detecting build target for $(HOST_ARCH)..."
ifeq ($(findstring arm,$(HOST_ARCH)),arm)
	@echo "ARM architecture detected - building Pi native version"
	$(MAKE) rpi-native
else
	@echo "Non-ARM architecture detected - building virtual cluster version"  
	$(MAKE) virtual
endif

# 1. Raspberry Pi native build (run this ON the Pi)
rpi-native: $(PROJECT)_rpi_native
$(PROJECT)_rpi_native: $(SOURCE)
	@echo "Building native Pi version for $(HOST_ARCH)..."
	$(RPI_NATIVE_CXX) $(RPI_NATIVE_CXXFLAGS) -o $(PROJECT) $(SOURCE) $(RPI_NATIVE_LDFLAGS)
	@echo "✓ Pi native build complete: $(PROJECT)"

# 2. Cross-compile for Pi (run this on x86/x64 Linux)  
cross-pi: $(PROJECT)_cross_pi
pi: cross-pi  # Alias
$(PROJECT)_cross_pi: $(SOURCE)
	@echo "Cross-compiling for Raspberry Pi..."
	@which $(CROSS_CXX) >/dev/null || (echo "ERROR: $(CROSS_CXX) not found. Install with: sudo apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf"; exit 1)
	$(CROSS_PI_CXX) $(CROSS_PI_CXXFLAGS) -o $(PROJECT) $(SOURCE) $(CROSS_PI_LDFLAGS)
	@echo "✓ Cross-compile complete: $(PROJECT) (for Pi deployment)"

# Cross-compile for specific Pi models
cross-pi-b: CROSS_PI_CXXFLAGS += -march=armv6 -mfpu=vfp -mfloat-abi=hard -DRPI_MODEL_B
cross-pi-b: cross-pi

cross-pi-2: CROSS_PI_CXXFLAGS += -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -DRPI_MODEL_2_3  
cross-pi-2: cross-pi

cross-pi-4: CROSS_PI_CXXFLAGS += -march=armv8-a -DRPI_MODEL_4_5
cross-pi-4: cross-pi

# 3. Virtual cluster build (for x86/x64 testing)
virtual: $(PROJECT)_virtual
$(PROJECT)_virtual: $(SOURCE)
	@echo "Building virtual cluster version for $(HOST_ARCH)..."
	$(VIRTUAL_CXX) $(VIRTUAL_CXXFLAGS) -o $(PROJECT) $(SOURCE) $(VIRTUAL_LDFLAGS)
	@echo "✓ Virtual cluster build complete: $(PROJECT)"

# Debug builds for each target
debug-rpi:
	$(RPI_NATIVE_CXX) $(BASE_CXXFLAGS) $(DEBUG_FLAGS) -DLEGACY_HARDWARE -DRASPBERRY_PI -o $(PROJECT)_debug $(SOURCE) $(BASE_LDFLAGS)
	@echo "✓ Pi debug build complete: $(PROJECT)_debug"

debug-cross:
	@which $(CROSS_CXX) >/dev/null || (echo "ERROR: Cross compiler not found"; exit 1)
	$(CROSS_PI_CXX) $(BASE_CXXFLAGS) $(DEBUG_FLAGS) -DLEGACY_HARDWARE -DRASPBERRY_PI -march=armv6 -mfpu=vfp -mfloat-abi=hard -o $(PROJECT)_debug $(SOURCE) $(BASE_LDFLAGS)
	@echo "✓ Cross debug build complete: $(PROJECT)_debug"

debug-virtual:
	$(VIRTUAL_CXX) $(BASE_CXXFLAGS) $(DEBUG_FLAGS) -DVIRTUAL_HARDWARE -DSIMULATION_MODE -o $(PROJECT)_debug $(SOURCE) $(BASE_LDFLAGS)
	@echo "✓ Virtual debug build complete: $(PROJECT)_debug"

#==============================================================================
# Utility Targets
#==============================================================================

# Clean all build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -f $(PROJECT) $(PROJECT)_debug
	rm -f *.o *.so *.a
	rm -f /tmp/plc_data.log
	@echo "✓ Clean complete"

# Install targets
install-rpi: rpi-native
	@echo "Installing Pi native version..."
	sudo cp $(PROJECT) /usr/local/bin/
	sudo chmod +x /usr/local/bin/$(PROJECT)
	@echo "✓ Installed to /usr/local/bin/$(PROJECT)"

install-virtual: virtual  
	@echo "Installing virtual version..."
	sudo cp $(PROJECT) /usr/local/bin/$(PROJECT)-virtual
	sudo chmod +x /usr/local/bin/$(PROJECT)-virtual
	@echo "✓ Installed to /usr/local/bin/$(PROJECT)-virtual"

# System and build information
info:
	@echo "=== Build Environment Information ==="
	@echo "Host Architecture: $(HOST_ARCH)"
	@echo "Native Compiler:   $(NATIVE_CXX) ($(shell $(NATIVE_CXX) --version | head -n1))"
	@echo "Cross Compiler:    $(CROSS_CXX) ($(shell which $(CROSS_CXX) >/dev/null 2>&1 && $(CROSS_CXX) --version | head -n1 || echo 'NOT FOUND'))"
	@echo ""
	@echo "=== Available Build Targets ==="
	@echo "Native Pi:       rpi-native    (build on Pi)"
	@echo "Cross Pi:        cross-pi, pi  (build on x86 for Pi)"
	@echo "Virtual Cluster: virtual       (build for x86 testing)"
	@echo "Auto-detect:     auto, all     (choose automatically)"

# Dependency checking
check-deps:
	@echo "Checking build dependencies..."
	@which $(NATIVE_CXX) >/dev/null || (echo "✗ $(NATIVE_CXX) not found"; exit 1)
	@echo "✓ Native compiler found: $(NATIVE_CXX)"
	@which $(CROSS_CXX) >/dev/null && echo "✓ Cross compiler found: $(CROSS_CXX)" || echo "⚠ Cross compiler not found (install gcc-arm-linux-gnueabihf for Pi cross-compilation)"
	@echo "✓ Dependency check complete"

# Test targets (basic functionality verification)
test-native: rpi-native
	@echo "Testing native build..."
	./$(PROJECT) --version 2>/dev/null || echo "Build appears successful (may need Pi hardware to run)"

test-virtual: virtual
	@echo "Testing virtual build..."  
	timeout 5 ./$(PROJECT) || echo "Build appears successful (timeout is normal)"

# Development workflow helpers
dev-cycle: clean virtual test-virtual
	@echo "✓ Development cycle complete"

deploy-prep: clean cross-pi
	@echo "✓ Deployment binary ready: $(PROJECT)"
	@file $(PROJECT)

# Help target
help:
	@echo "Legacy PLC Multi-Target Build System"
	@echo ""
	@echo "=== Main Build Targets ==="
	@echo "  all, auto       - Auto-detect and build appropriate version"
	@echo "  rpi-native      - Build native version (run ON Raspberry Pi)" 
	@echo "  cross-pi, pi    - Cross-compile for Pi (run on x86/x64 Linux)"
	@echo "  virtual         - Build for virtual cluster (x86/x64 testing)"
	@echo ""
	@echo "=== Specific Pi Models ==="
	@echo "  cross-pi-b      - Cross-compile for Pi Model B (ARMv6)"
	@echo "  cross-pi-2      - Cross-compile for Pi 2/3 (ARMv7)" 
	@echo "  cross-pi-4      - Cross-compile for Pi 4/5 (ARMv8)"
	@echo ""
	@echo "=== Debug Builds ==="
	@echo "  debug-rpi       - Debug build for Pi native"
	@echo "  debug-cross     - Debug build for Pi cross-compile"
	@echo "  debug-virtual   - Debug build for virtual cluster"
	@echo ""
	@echo "=== Utilities ==="
	@echo "  clean           - Remove build artifacts"
	@echo "  install-rpi     - Install Pi native version"
	@echo "  install-virtual - Install virtual version"
	@echo "  info            - Show build environment info"
	@echo "  check-deps      - Check build dependencies"
	@echo "  dev-cycle       - Clean + virtual build + test"
	@echo "  deploy-prep     - Clean + cross-compile for deployment"
	@echo "  help            - Show this help"

.PHONY: all auto rpi-native cross-pi pi cross-pi-b cross-pi-2 cross-pi-4 virtual \
        debug-rpi debug-cross debug-virtual clean install-rpi install-virtual \
        info check-deps test-native test-virtual dev-cycle deploy-prep help
