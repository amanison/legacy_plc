#include <iostream>
#include <string>
#include <vector>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <cstring>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <cmath>        // Added for sin() function

#ifdef VIRTUAL_HARDWARE
#include <sys/stat.h>
#include <unistd.h>
#endif

// Legacy PLC Simulator - mimics early 2000s industrial controller
class LegacyPLC {
private:
    // System configuration - typical of 2004-era PLCs
    static const int CYCLE_TIME_MS = 100;  // 100ms scan cycle (10 Hz)
    static const int MAX_INPUTS = 16;
    static const int MAX_OUTPUTS = 16;
    static const int MAX_REGISTERS = 256;
    static const int TCP_PORT = 9001;  // Legacy control protocol port
    static const int MGMT_PORT = 8080; // Management HTTP interface port
    
    // PLC State
    struct SystemState {
        bool running;
        uint32_t cycle_count;
        uint16_t inputs[MAX_INPUTS];
        uint16_t outputs[MAX_OUTPUTS]; 
        uint16_t registers[MAX_REGISTERS];
        uint8_t error_codes;
        std::string last_error;
        
        SystemState() : running(false), cycle_count(0), error_codes(0) {
            memset(inputs, 0, sizeof(inputs));
            memset(outputs, 0, sizeof(outputs));
            memset(registers, 0, sizeof(registers));
        }
    } state;
    
    // Network - Multi-protocol support
    int server_socket;      // Control protocol (legacy ASCII)
    int mgmt_socket;        // Management protocol (HTTP/JSON)
    struct sockaddr_in server_addr;
    struct sockaddr_in mgmt_addr;
    
    // Timing
    std::chrono::steady_clock::time_point last_cycle;
    
    // Legacy data logging (ASCII format typical of early PLCs)
    std::ofstream log_file;
    
public:
    LegacyPLC() : server_socket(-1), mgmt_socket(-1) {
        initialize_system();
    }
    
    ~LegacyPLC() {
        shutdown_system();
    }
    
    void initialize_system() {
#ifdef VIRTUAL_HARDWARE
        std::cout << "=== LEGACY PLC SIMULATOR v2.1 (VIRTUAL) ===" << std::endl;
        std::cout << "Running in virtual cluster mode" << std::endl;
        std::cout << "Hardware simulation: ENABLED" << std::endl;
#elif defined(RASPBERRY_PI)
        std::cout << "=== LEGACY PLC SIMULATOR v2.1 (RASPBERRY PI) ===" << std::endl;
        #ifdef RPI_MODEL_B
        std::cout << "Target: Raspberry Pi Model B" << std::endl;
        #elif defined(RPI_MODEL_2_3)
        std::cout << "Target: Raspberry Pi 2/3" << std::endl;
        #elif defined(RPI_MODEL_4_5)
        std::cout << "Target: Raspberry Pi 4/5" << std::endl;
        #endif
#else
        std::cout << "=== LEGACY PLC SIMULATOR v2.1 ===" << std::endl;
#endif
        
        std::cout << "Compatible with: Modicon, Allen-Bradley, Siemens" << std::endl;
        std::cout << "Protocol: ASCII/TCP (Pre-OPC UA)" << std::endl;
        std::cout << "Scan Rate: " << CYCLE_TIME_MS << "ms" << std::endl;
        
        // Initialize network
        setup_network();
        
        // Initialize data logging with environment-specific path
#ifdef VIRTUAL_HARDWARE
        std::string log_path = "/tmp/plc_data_virtual.log";
        system("mkdir -p /tmp");
#else
        std::string log_path = "/tmp/plc_data.log";
#endif
        
        log_file.open(log_path, std::ios::app);
        if (log_file.is_open()) {
            log_file << "# PLC Data Log - Started " << get_timestamp();
#ifdef VIRTUAL_HARDWARE
            log_file << " (Virtual Mode)";
#endif
            log_file << std::endl;
            log_file << "# Format: TIMESTAMP,CYCLE,I0-I15,O0-O15,ERR" << std::endl;
        }
        
        // Load "ladder logic" simulation
        load_control_program();
        
        state.running = true;
        last_cycle = std::chrono::steady_clock::now();
        
        std::cout << "System initialized. Starting scan cycle..." << std::endl;
    }
    
    void setup_network() {
        std::cout << "Setting up multi-protocol industrial network..." << std::endl;
        
        // Setup control protocol (legacy ASCII)
        setup_control_protocol();
        
        // Setup management protocol (HTTP/JSON)
        setup_management_protocol();
        
        std::cout << "? Multi-protocol binding complete" << std::endl;
    }
    
    void setup_control_protocol() {
        server_socket = socket(AF_INET, SOCK_STREAM, 0);
        if (server_socket < 0) {
            std::cerr << "Failed to create control socket" << std::endl;
            return;
        }
        
        // Make socket non-blocking for legacy-style polling
        int flags = fcntl(server_socket, F_GETFL, 0);
        fcntl(server_socket, F_SETFL, flags | O_NONBLOCK);
        
        // Reuse address
        int opt = 1;
        setsockopt(server_socket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        
        server_addr.sin_family = AF_INET;
        
#ifdef VIRTUAL_HARDWARE
        // Virtual mode - different port to avoid conflicts
        server_addr.sin_addr.s_addr = INADDR_ANY;
        server_addr.sin_port = htons(9901);
        std::cout << "? Control Protocol: 0.0.0.0:9901 (virtual - legacy ASCII)" << std::endl;
#else
        // Physical Pi - system-level binding (let infrastructure control access)
        server_addr.sin_addr.s_addr = INADDR_ANY;  // Bind to all interfaces
        server_addr.sin_port = htons(TCP_PORT);    // Port 9001
        std::cout << "? Control Protocol: 0.0.0.0:9001 (legacy ASCII - system-level binding)" << std::endl;
        std::cout << "  Network access controlled by VLAN configuration" << std::endl;
#endif
        
        if (bind(server_socket, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
            std::cerr << "Failed to bind control socket" << std::endl;
            return;
        }
        
        listen(server_socket, 1);  // Only one connection (typical of legacy)
    }
    
    void setup_management_protocol() {
        mgmt_socket = socket(AF_INET, SOCK_STREAM, 0);
        if (mgmt_socket < 0) {
            std::cerr << "Failed to create management socket" << std::endl;
            return;
        }
        
        // Make socket non-blocking
        int flags = fcntl(mgmt_socket, F_GETFL, 0);
        fcntl(mgmt_socket, F_SETFL, flags | O_NONBLOCK);
        
        // Reuse address
        int opt = 1;
        setsockopt(mgmt_socket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        
        mgmt_addr.sin_family = AF_INET;
        mgmt_addr.sin_addr.s_addr = INADDR_ANY;  // System-level binding
        
#ifdef VIRTUAL_HARDWARE
        mgmt_addr.sin_port = htons(8901);  // Different port for virtual
        std::cout << "? Management Interface: 0.0.0.0:8901 (virtual - HTTP/JSON)" << std::endl;
#else
        mgmt_addr.sin_port = htons(MGMT_PORT);  // Port 8080
        std::cout << "? Management Interface: 0.0.0.0:8080 (HTTP/JSON status)" << std::endl;
        std::cout << "  Accessible via management VLAN for monitoring/configuration" << std::endl;
#endif
        
        if (bind(mgmt_socket, (struct sockaddr*)&mgmt_addr, sizeof(mgmt_addr)) < 0) {
            std::cerr << "Failed to bind management socket" << std::endl;
            close(mgmt_socket);
            mgmt_socket = -1;
            return;
        }
        
        listen(mgmt_socket, 3);  // Allow more concurrent management connections
    }
    
    void load_control_program() {
        // Simulate loading "ladder logic" - typical startup sequence
        std::cout << "Loading control program..." << std::endl;
        usleep(500000); // 500ms load time
        
        // Initialize some default register values (typical configuration)
        state.registers[0] = 100;   // Setpoint temperature
        state.registers[1] = 50;    // Alarm threshold
        state.registers[2] = 1000;  // Timer preset
        state.registers[10] = 0x1234; // Device ID
        
        std::cout << "Program loaded. Memory usage: 2KB/64KB" << std::endl;
    }
    
    void run_scan_cycle() {
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_cycle);
        
        if (elapsed.count() >= CYCLE_TIME_MS) {
            // Input scan phase
            scan_inputs();
            
            // Program execution phase
            execute_control_logic();
            
            // Output update phase  
            update_outputs();
            
            // Communication phase (legacy style - poll for connections)
            handle_network_communication();
            
            // Data logging phase
            log_cycle_data();
            
            state.cycle_count++;
            last_cycle = now;
            
            // Status display (every 50 cycles = ~5 seconds)
            if (state.cycle_count % 50 == 0) {
                display_status();
            }
        }
    }
    
    void scan_inputs() {
        // Simulate input scanning with enhanced virtual behavior
        
#ifdef VIRTUAL_HARDWARE
        // More realistic simulation for virtual cluster testing
        static double temp_simulation = 750.0;
        static double pressure_simulation = 500.0;
        static uint32_t cycle_input_period = 200;  // Fixed: use uint32_t to match cycle_count type
        
        // Temperature with more complex behavior in virtual mode
        temp_simulation += (std::sin(state.cycle_count * 0.1) * 2) + ((rand() % 20) - 10) * 0.1;
        if (temp_simulation < 600) temp_simulation = 600;
        if (temp_simulation > 900) temp_simulation = 900;
        state.inputs[0] = static_cast<uint16_t>(temp_simulation);
        
        // Pressure with virtual drift
        pressure_simulation += (rand() % 6) - 3; // Random walk
        if (pressure_simulation < 400) pressure_simulation = 400;
        if (pressure_simulation > 600) pressure_simulation = 600;
        state.inputs[3] = static_cast<uint16_t>(pressure_simulation);
        
        // Cycle input with configurable period in virtual mode  
        state.inputs[1] = (state.cycle_count % cycle_input_period < cycle_input_period / 2) ? 1 : 0;
        
        // Always-on input (run enable) - can be controlled via external file in virtual mode
        state.inputs[2] = 1; // Default enabled
        
        // Check for virtual control file
        struct stat buffer;
        if (stat("/tmp/plc_stop", &buffer) == 0) {
            state.inputs[2] = 0; // Stop if file exists
        }
        
#else
        // Original simulation for hardware builds
        state.inputs[0] = 750 + (rand() % 100); // Temperature sensor (raw ADC)
        state.inputs[1] = (state.cycle_count % 200 < 100) ? 1 : 0; // Cycle input
        state.inputs[2] = 1; // Always-on input (run enable)
        
        // Simulate pressure sensor with drift
        static int pressure_base = 500;
        pressure_base += (rand() % 3) - 1; // Random walk
        state.inputs[3] = pressure_base;
#endif
    }
    
    void execute_control_logic() {
        // Simulate ladder logic execution - very simple control program
        // This mimics early 2000s PLC programming style
        
        // Rung 1: Run enable logic
        bool run_enable = (state.inputs[2] == 1);
        
        // Rung 2: Temperature control
        if (run_enable && state.inputs[0] < state.registers[0]) {
            state.outputs[0] = 1; // Heater on
        } else {
            state.outputs[0] = 0; // Heater off
        }
        
        // Rung 3: High temperature alarm
        if (state.inputs[0] > state.registers[1]) {
            state.outputs[1] = 1; // Alarm on
            state.error_codes |= 0x01; // Set alarm bit
        } else {
            state.outputs[1] = 0;
            state.error_codes &= ~0x01; // Clear alarm bit
        }
        
        // Rung 4: Cycle counter output
        state.registers[20] = state.cycle_count & 0xFFFF;
        
        // Rung 5: Status LED (heartbeat)
        state.outputs[15] = (state.cycle_count % 10 < 5) ? 1 : 0;
    }
    
    void update_outputs() {
        // In real PLC, this would update physical outputs
        // Here we just ensure internal consistency
        
        // Update some computed registers
        state.registers[100] = state.inputs[0];  // Copy temperature to register
        state.registers[101] = state.outputs[0]; // Copy heater status
    }
    
    void handle_network_communication() {
        // Handle control protocol connections (legacy ASCII)
        handle_control_connections();
        
        // Handle management protocol connections (HTTP/JSON)
        handle_management_connections();
    }
    
    void handle_control_connections() {
        // Legacy-style control protocol communication handling
        int client_socket = accept(server_socket, nullptr, nullptr);
        if (client_socket > 0) {
            char buffer[256];
            ssize_t bytes = recv(client_socket, buffer, sizeof(buffer)-1, MSG_DONTWAIT);
            
            if (bytes > 0) {
                buffer[bytes] = '\0';
                std::string response = process_legacy_command(std::string(buffer));
                send(client_socket, response.c_str(), response.length(), 0);
            }
            
            close(client_socket);
        }
    }
    
    void handle_management_connections() {
        if (mgmt_socket < 0) return;
        
        int client_socket = accept(mgmt_socket, nullptr, nullptr);
        if (client_socket > 0) {
            char buffer[1024];
            ssize_t bytes = recv(client_socket, buffer, sizeof(buffer)-1, MSG_DONTWAIT);
            
            if (bytes > 0) {
                buffer[bytes] = '\0';
                std::string response = process_http_request(std::string(buffer));
                send(client_socket, response.c_str(), response.length(), 0);
            }
            
            close(client_socket);
        }
    }
    
    std::string process_legacy_command(const std::string& command) {
        // Process simple ASCII protocol commands (typical of early 2000s)
        std::stringstream response;
        
        if (command.substr(0, 2) == "RI") {
            // Read Input - format: RI<address>
            int addr = std::stoi(command.substr(2));
            if (addr >= 0 && addr < MAX_INPUTS) {
                response << std::setfill('0') << std::setw(4) << state.inputs[addr];
            } else {
                response << "ERR1"; // Invalid address
            }
        }
        else if (command.substr(0, 2) == "RO") {
            // Read Output - format: RO<address>
            int addr = std::stoi(command.substr(2));
            if (addr >= 0 && addr < MAX_OUTPUTS) {
                response << std::setfill('0') << std::setw(4) << state.outputs[addr];
            } else {
                response << "ERR1";
            }
        }
        else if (command.substr(0, 2) == "RR") {
            // Read Register - format: RR<address>
            int addr = std::stoi(command.substr(2));
            if (addr >= 0 && addr < MAX_REGISTERS) {
                response << std::setfill('0') << std::setw(4) << state.registers[addr];
            } else {
                response << "ERR1";
            }
        }
        else if (command.substr(0, 6) == "STATUS") {
            // Status request - return fixed-width status string
            response << "RUN," << std::setfill('0') << std::setw(8) << state.cycle_count 
                    << "," << std::setw(2) << std::hex << (int)state.error_codes
                    << "," << get_timestamp();
        }
        else {
            response << "ERR0"; // Unknown command
        }
        
        response << "\r\n"; // Legacy line ending
        return response.str();
    }
    
    std::string process_http_request(const std::string& /*request*/) {
        std::stringstream response;
        
        // Simple HTTP response for management interface
        response << "HTTP/1.1 200 OK\r\n";
        response << "Content-Type: application/json\r\n";
        response << "Access-Control-Allow-Origin: *\r\n";
        response << "Cache-Control: no-cache\r\n";
        response << "Connection: close\r\n";
        response << "\r\n";
        
        // JSON status response for management network
        response << "{\n";
        response << "  \"device_info\": {\n";
        response << "    \"name\": \"Legacy PLC Simulator\",\n";
        response << "    \"version\": \"2.1\",\n";
        response << "    \"model\": \"Schneider/Modicon TSX Premium (circa 2004)\",\n";
#ifdef VIRTUAL_HARDWARE
        response << "    \"mode\": \"Virtual Hardware Simulation\",\n";
#else
        response << "    \"mode\": \"Physical Raspberry Pi\",\n";
        response << "    \"hardware\": \"Pi B v2 - 512MB RAM\",\n";
#endif
        response << "    \"uptime_cycles\": " << state.cycle_count << "\n";
        response << "  },\n";
        response << "  \"operational_status\": {\n";
        response << "    \"status\": \"" << (state.running ? "RUNNING" : "STOPPED") << "\",\n";
        response << "    \"scan_rate_ms\": " << CYCLE_TIME_MS << ",\n";
        response << "    \"error_codes\": \"0x" << std::hex << (int)state.error_codes << std::dec << "\",\n";
        response << "    \"last_error\": \"" << state.last_error << "\"\n";
        response << "  },\n";
        response << "  \"process_data\": {\n";
        response << "    \"inputs\": {\n";
        response << "      \"temperature_raw\": " << state.inputs[0] << ",\n";
        response << "      \"cycle_input\": " << state.inputs[1] << ",\n";
        response << "      \"run_enable\": " << state.inputs[2] << ",\n";
        response << "      \"pressure_raw\": " << state.inputs[3] << "\n";
        response << "    },\n";
        response << "    \"outputs\": {\n";
        response << "      \"heater_command\": " << state.outputs[0] << ",\n";
        response << "      \"high_temp_alarm\": " << state.outputs[1] << ",\n";
        response << "      \"heartbeat_led\": " << state.outputs[15] << "\n";
        response << "    },\n";
        response << "    \"registers\": {\n";
        response << "      \"temperature_setpoint\": " << state.registers[0] << ",\n";
        response << "      \"alarm_threshold\": " << state.registers[1] << ",\n";
        response << "      \"current_temperature\": " << state.registers[100] << ",\n";
        response << "      \"heater_status\": " << state.registers[101] << "\n";
        response << "    }\n";
        response << "  },\n";
        response << "  \"network_interfaces\": {\n";
        response << "    \"control_protocol\": {\n";
        response << "      \"endpoint\": \"*:9001\",\n";
        response << "      \"protocol\": \"Legacy ASCII\",\n";
        response << "      \"purpose\": \"Real-time control communications\",\n";
#ifdef VIRTUAL_HARDWARE
        response << "      \"vlan\": \"Virtual (No VLAN)\"\n";
#else
        response << "      \"vlan\": \"10 (Control Network)\"\n";
#endif
        response << "    },\n";
        response << "    \"management_protocol\": {\n";
#ifdef VIRTUAL_HARDWARE
        response << "      \"endpoint\": \"*:8901\",\n";
#else
        response << "      \"endpoint\": \"*:8080\",\n";
#endif
        response << "      \"protocol\": \"HTTP/JSON\",\n";
        response << "      \"purpose\": \"Status monitoring and configuration\",\n";
#ifdef VIRTUAL_HARDWARE
        response << "      \"vlan\": \"Virtual (No VLAN)\"\n";
#else
        response << "      \"vlan\": \"99 (Management Network)\"\n";
#endif
        response << "    }\n";
        response << "  },\n";
        response << "  \"system_resources\": {\n";
        response << "    \"memory_usage\": \"2KB/64KB\",\n";
#ifdef RASPBERRY_PI
        response << "    \"cpu_architecture\": \"ARMv6 (Pi Model B)\",\n";
        response << "    \"memory_limit\": \"64MB (systemd)\"\n";
#else
        response << "    \"cpu_architecture\": \"x86_64 (Virtual)\",\n";
        response << "    \"memory_limit\": \"Unlimited\"\n";
#endif
        response << "  },\n";
        response << "  \"timestamp\": \"" << get_timestamp() << "\"\n";
        response << "}\n";
        
        return response.str();
    }
    
    void log_cycle_data() {
        // Log data in CSV format every 10 cycles (1 second)
        if (log_file.is_open() && state.cycle_count % 10 == 0) {
            log_file << get_timestamp() << "," << state.cycle_count;
            
            // Log first 4 inputs
            for (int i = 0; i < 4; i++) {
                log_file << "," << state.inputs[i];
            }
            
            // Log first 4 outputs  
            for (int i = 0; i < 4; i++) {
                log_file << "," << state.outputs[i];
            }
            
            log_file << "," << std::hex << (int)state.error_codes << std::endl;
        }
    }
    
    void display_status() {
        std::cout << "[" << get_timestamp() << "] "
                  << "Cycle: " << state.cycle_count
                  << " | Temp: " << state.inputs[0] 
                  << " | Heater: " << (state.outputs[0] ? "ON" : "OFF")
                  << " | Errors: 0x" << std::hex << (int)state.error_codes << std::dec
                  << std::endl;
    }
    
    std::string get_timestamp() {
        auto now = std::chrono::system_clock::now();
        auto time_t = std::chrono::system_clock::to_time_t(now);
        std::stringstream ss;
        ss << std::put_time(std::localtime(&time_t), "%Y-%m-%d %H:%M:%S");
        return ss.str();
    }
    
    void shutdown_system() {
        std::cout << "Shutting down PLC..." << std::endl;
        state.running = false;
        
        if (server_socket >= 0) {
            close(server_socket);
        }
        
        if (mgmt_socket >= 0) {
            close(mgmt_socket);
        }
        
        if (log_file.is_open()) {
            log_file << "# PLC Shutdown - " << get_timestamp() << std::endl;
            log_file.close();
        }
        
        std::cout << "Total cycles executed: " << state.cycle_count << std::endl;
    }
    
    bool is_running() const { return state.running; }
};

// Main program
int main(int argc, char* argv[]) {
    // Handle command line arguments
    if (argc > 1) {
        if (strcmp(argv[1], "--version") == 0) {
            std::cout << "Legacy PLC Simulator v2.1" << std::endl;
#ifdef VIRTUAL_HARDWARE
            std::cout << "Build: Virtual Hardware" << std::endl;
#elif defined(RASPBERRY_PI)
            std::cout << "Build: Raspberry Pi Hardware" << std::endl;
#else
            std::cout << "Build: Generic Hardware" << std::endl;
#endif
            return 0;
        }
        else if (strcmp(argv[1], "--help") == 0) {
            std::cout << "Legacy PLC Simulator" << std::endl;
            std::cout << "Usage: " << argv[0] << " [options]" << std::endl;
            std::cout << "Options:" << std::endl;
            std::cout << "  --version    Show version information" << std::endl;
            std::cout << "  --help       Show this help" << std::endl;
            std::cout << std::endl;
            std::cout << "Network Interfaces:" << std::endl;
#ifdef VIRTUAL_HARDWARE
            std::cout << "  Control Protocol:    0.0.0.0:9901 (Legacy ASCII)" << std::endl;
            std::cout << "  Management Protocol: 0.0.0.0:8901 (HTTP/JSON)" << std::endl;
#else
            std::cout << "  Control Protocol:    0.0.0.0:9001 (Legacy ASCII)" << std::endl;
            std::cout << "  Management Protocol: 0.0.0.0:8080 (HTTP/JSON)" << std::endl;
#endif
            return 0;
        }
    }
    
#ifdef VIRTUAL_HARDWARE
    std::cout << "Starting Legacy PLC Simulator in Virtual Cluster Mode" << std::endl;
    std::cout << "Simulating: Schneider/Modicon TSX Premium (circa 2004)" << std::endl;
    std::cout << "Virtual Hardware: No GPIO dependencies" << std::endl;
#else
    std::cout << "Starting Legacy PLC Simulator on Raspberry Pi Model B" << std::endl;
    std::cout << "Simulating: Schneider/Modicon TSX Premium (circa 2004)" << std::endl;
#endif
    
    LegacyPLC plc;
    
    // Main execution loop
    while (plc.is_running()) {
        plc.run_scan_cycle();
        usleep(1000); // Small sleep to prevent 100% CPU usage
    }
    
    return 0;
}
