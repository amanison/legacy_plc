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

// Legacy PLC Simulator - mimics early 2000s industrial controller
class LegacyPLC {
private:
    // System configuration - typical of 2004-era PLCs
    static const int CYCLE_TIME_MS = 100;  // 100ms scan cycle (10 Hz)
    static const int MAX_INPUTS = 16;
    static const int MAX_OUTPUTS = 16;
    static const int MAX_REGISTERS = 256;
    static const int TCP_PORT = 9001;  // Non-standard port (pre-OPC UA)
    
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
    
    // Network
    int server_socket;
    struct sockaddr_in server_addr;
    
    // Timing
    std::chrono::steady_clock::time_point last_cycle;
    
    // Legacy data logging (ASCII format typical of early PLCs)
    std::ofstream log_file;
    
public:
    LegacyPLC() : server_socket(-1) {
        initialize_system();
    }
    
    ~LegacyPLC() {
        shutdown_system();
    }
    
    void initialize_system() {
        std::cout << "=== LEGACY PLC SIMULATOR v2.1 ===" << std::endl;
        std::cout << "Compatible with: Modicon, Allen-Bradley, Siemens" << std::endl;
        std::cout << "Protocol: ASCII/TCP (Pre-OPC UA)" << std::endl;
        std::cout << "Scan Rate: " << CYCLE_TIME_MS << "ms" << std::endl;
        
        // Initialize network
        setup_network();
        
        // Initialize data logging 
        log_file.open("/tmp/plc_data.log", std::ios::app);
        if (log_file.is_open()) {
            log_file << "# PLC Data Log - Started " << get_timestamp() << std::endl;
            log_file << "# Format: TIMESTAMP,CYCLE,I0-I15,O0-O15,ERR" << std::endl;
        }
        
        // Load "ladder logic" simulation
        load_control_program();
        
        state.running = true;
        last_cycle = std::chrono::steady_clock::now();
        
        std::cout << "System initialized. Starting scan cycle..." << std::endl;
    }
    
    void setup_network() {
        server_socket = socket(AF_INET, SOCK_STREAM, 0);
        if (server_socket < 0) {
            std::cerr << "Failed to create socket" << std::endl;
            return;
        }
        
        // Make socket non-blocking for legacy-style polling
        int flags = fcntl(server_socket, F_GETFL, 0);
        fcntl(server_socket, F_SETFL, flags | O_NONBLOCK);
        
        // Reuse address
        int opt = 1;
        setsockopt(server_socket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        
        server_addr.sin_family = AF_INET;
        server_addr.sin_addr.s_addr = INADDR_ANY;
        server_addr.sin_port = htons(TCP_PORT);
        
        if (bind(server_socket, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
            std::cerr << "Failed to bind socket" << std::endl;
            return;
        }
        
        listen(server_socket, 1);  // Only one connection (typical of legacy)
        std::cout << "TCP Server listening on port " << TCP_PORT << std::endl;
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
        // Simulate input scanning - typical legacy PLC behavior
        // In real system, this would read from I/O modules
        
        // Simulate some varying inputs (temperature sensor, etc.)
        state.inputs[0] = 750 + (rand() % 100); // Temperature sensor (raw ADC)
        state.inputs[1] = (state.cycle_count % 200 < 100) ? 1 : 0; // Cycle input
        state.inputs[2] = 1; // Always-on input (run enable)
        
        // Simulate pressure sensor with drift
        static int pressure_base = 500;
        pressure_base += (rand() % 3) - 1; // Random walk
        state.inputs[3] = pressure_base;
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
        // Legacy-style communication handling - very simple protocol
        
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
        
        if (log_file.is_open()) {
            log_file << "# PLC Shutdown - " << get_timestamp() << std::endl;
            log_file.close();
        }
        
        std::cout << "Total cycles executed: " << state.cycle_count << std::endl;
    }
    
    bool is_running() const { return state.running; }
};

// Main program
int main() {
    std::cout << "Starting Legacy PLC Simulator on Raspberry Pi Model B" << std::endl;
    std::cout << "Simulating: Schneider/Modicon TSX Premium (circa 2004)" << std::endl;
    
    LegacyPLC plc;
    
    // Main execution loop
    while (plc.is_running()) {
        plc.run_scan_cycle();
        usleep(1000); // Small sleep to prevent 100% CPU usage
    }
    
    return 0;
}
