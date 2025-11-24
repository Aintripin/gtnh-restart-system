#!/bin/bash

# GTNH Server Complete Setup Installer - Self-Contained Version
# Sets up systemd services, monitoring scripts, and restart automation
# Usage: sudo ./setup.sh [OPTIONS]
#
# This is a fully self-contained installer - copy this single file to any
# fresh GTNH server and run it. No external dependencies needed.

set -e  # Exit on error

# Version
VERSION="1.0.1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}!${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}===${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Detect the actual user (not root when using sudo)
get_real_user() {
    if [ -n "$SUDO_USER" ]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    local missing_packages=()
    
    # Check systemd
    if ! command -v systemctl &> /dev/null; then
        log_error "systemd not found. This script requires systemd."
        exit 1
    fi
    log_info "systemd available"
    
    # Check screen
    if ! command -v screen &> /dev/null; then
        log_warn "screen not installed"
        missing_packages+=("screen")
    else
        log_info "screen installed"
    fi
    
    # Check bc
    if ! command -v bc &> /dev/null; then
        log_warn "bc not installed (needed for TPS calculations)"
        missing_packages+=("bc")
    else
        log_info "bc installed"
    fi
    
    # Check bash version
    if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
        log_error "Bash version 4.0 or higher required (you have ${BASH_VERSION})"
        exit 1
    fi
    log_info "bash version ${BASH_VERSION}"
    
    # Install missing packages if any
    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo ""
        log_warn "Missing packages: ${missing_packages[*]}"
        echo ""
        echo "  bc (basic calculator) - Required for floating-point TPS calculations"
        echo "  screen - Required for managing the server process"
        echo ""
        
        # Detect package manager
        if command -v apt-get &> /dev/null; then
            echo "  Install command: sudo apt-get install ${missing_packages[*]}"
        elif command -v yum &> /dev/null; then
            echo "  Install command: sudo yum install ${missing_packages[*]}"
        elif command -v pacman &> /dev/null; then
            echo "  Install command: sudo pacman -S ${missing_packages[*]}"
        fi
        
        echo ""
        read -p "Install missing packages now? [Y/n] " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y "${missing_packages[@]}"
            elif command -v yum &> /dev/null; then
                yum install -y "${missing_packages[@]}"
            elif command -v pacman &> /dev/null; then
                pacman -S --noconfirm "${missing_packages[@]}"
            else
                log_error "Could not determine package manager. Please install manually."
                exit 1
            fi
            log_info "Packages installed"
        else
            log_error "Required packages not installed. Cannot continue."
            exit 1
        fi
    fi
}

# Detect server directory and files
detect_server_directory() {
    log_step "Detecting server directory..."
    
    # Get current directory
    SERVER_DIR=$(pwd)
    REAL_USER=$(get_real_user)
    
    echo "Current directory: $SERVER_DIR"
    echo "Detected user: $REAL_USER"
    echo ""
    
    read -p "Is this your GTNH server directory? [Y/n] " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo ""
        read -r -p "Enter server directory path: " SERVER_DIR
        SERVER_DIR="${SERVER_DIR/#\~/$HOME}"  # Expand ~
        
        if [ ! -d "$SERVER_DIR" ]; then
            log_error "Directory does not exist: $SERVER_DIR"
            exit 1
        fi
    fi
    
    # Validate server directory
    if [ ! -f "$SERVER_DIR/lwjgl3ify-forgePatches.jar" ]; then
        log_error "This doesn't appear to be a GTNH server directory (lwjgl3ify-forgePatches.jar not found)"
        exit 1
    fi
    
    log_info "Directory exists"
    log_info "Detected Minecraft server files"
    
    SCRIPT_DIR="$SERVER_DIR/minecraft_scripts"
}

# Detect or create start script
detect_start_script() {
    log_step "Checking for server start script..."
    
    START_SCRIPT=""
    
    # Check for optimized script first
    if [ -f "$SERVER_DIR/startserver.sh" ]; then
        START_SCRIPT="startserver.sh"
        log_info "Found existing startserver.sh"
        echo "  → Using your existing server start script"
        echo "  → RAM configuration skipped (already set in existing script)"
        return
    fi
    
    # Check for default GTNH script
    if [ -f "$SERVER_DIR/startserver-java9.sh" ]; then
        log_warn "Found default GTNH script: startserver-java9.sh"
        echo ""
        echo "  This script uses basic JVM arguments:"
        echo "    - 6GB RAM"
        echo "    - Basic G1GC settings"
        echo "    - Auto-restart loop"
        echo ""
        echo "  We can create an optimized startserver.sh with:"
        echo "    - Configurable RAM (default 24GB)"
        echo "    - Advanced G1GC tuning"
        echo "    - No auto-restart loop (systemd handles this)"
        echo ""
        
        read -p "Create optimized startserver.sh? [Y/n] " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            create_optimized_start_script
            START_SCRIPT="startserver.sh"
        else
            START_SCRIPT="startserver-java9.sh"
            log_info "Using startserver-java9.sh"
        fi
        return
    fi
    
    # No script found
    log_error "No server start script found"
    log_error "Expected startserver-java9.sh or startserver.sh in $SERVER_DIR"
    exit 1
}

# Generate service name from folder name
generate_service_name() {
    log_step "Generating service name..."
    
    # Extract folder name from SERVER_DIR
    local folder_name
    folder_name=$(basename "$SERVER_DIR")
    
    # Sanitize name: lowercase, replace special chars with dash, remove consecutive dashes
    folder_name=$(echo "$folder_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
    
    # Generate service names (use hyphens for systemd convention)
    SERVICE_NAME="gtnh-${folder_name}"
    MONITORS_SERVICE_NAME="${SERVICE_NAME}-monitors"
    
    # Generate screen name (use underscores for better pattern matching)
    SCREEN_SESSION_NAME="gtnh_$(echo "$folder_name" | tr '-' '_')"
    
    echo "Generated service name: ${SERVICE_NAME}"
    echo "Folder: $folder_name"
    
    # Check for conflicts
    check_service_conflict
}

# Check for service name conflicts
check_service_conflict() {
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    
    # Service doesn't exist - all good
    if [ ! -f "$service_file" ]; then
        log_info "Service name: ${SERVICE_NAME}.service"
        return 0
    fi
    
    # Service exists - check if it points to same path
    local existing_path
    existing_path=$(grep "WorkingDirectory=" "$service_file" | cut -d'=' -f2)
    
    if [ "$existing_path" = "$SERVER_DIR" ]; then
        # Same server - updating/reinstalling
        log_info "Service '${SERVICE_NAME}.service' already points to this server"
        log_info "Will update existing installation"
        return 0
    fi
    
    # Conflict detected - different path
    echo ""
    log_warn "Service name conflict detected!"
    echo ""
    echo "  Service '${SERVICE_NAME}.service' already exists"
    echo "  Existing service manages: $existing_path"
    echo "  Current installation:     $SERVER_DIR"
    echo ""
    echo "Options:"
    echo "  1) Overwrite - Switch systemd to manage THIS server"
    echo "     (Old server at $existing_path will need manual restart)"
    echo "  2) Custom name - Enter a different service name"
    echo "  3) Cancel installation"
    echo ""
    
    while true; do
        read -p "Choice [1/2/3]: " -n 1 -r
        echo ""
        
        case $REPLY in
            1)
                log_info "Will overwrite existing service"
                return 0
                ;;
            2)
                echo ""
                read -r -p "Enter custom service name (e.g., 'gtnh-prod'): " custom_name
                # Validate custom name
                if [[ "$custom_name" =~ ^[a-z0-9-]+$ ]]; then
                    SERVICE_NAME="$custom_name"
                    MONITORS_SERVICE_NAME="${SERVICE_NAME}-monitors"
                    SCREEN_SESSION_NAME="${SERVICE_NAME}"
                    log_info "Using custom name: ${SERVICE_NAME}.service"
                    # Check again with new name (recursive)
                    check_service_conflict
                    return $?
                else
                    log_error "Invalid name. Use only lowercase letters, numbers, and dashes."
                    continue
                fi
                ;;
            3)
                log_warn "Installation cancelled"
                exit 0
                ;;
            *)
                echo "Invalid choice. Please enter 1, 2, or 3."
                ;;
        esac
    done
}

# Create optimized start script
create_optimized_start_script() {
    echo ""
    echo "RAM Configuration:"
    read -r -p "  Minimum RAM (GB) [18]: " MIN_RAM
    MIN_RAM=${MIN_RAM:-18}
    read -r -p "  Maximum RAM (GB) [24]: " MAX_RAM
    MAX_RAM=${MAX_RAM:-24}
    
    # Create startserver.sh from embedded template
    cat > "$SERVER_DIR/startserver.sh" << 'STARTSERVER_EOF'
#!/bin/bash

# GTNH Server Startup Script with Optimized JVM Arguments
# Created by GTNH Setup Installer
# Memory: MIN_RAM_PLACEHOLDER G min, MAX_RAM_PLACEHOLDER G max, 2GB Metaspace

java -XmsMIN_RAM_PLACEHOLDERG -XmxMAX_RAM_PLACEHOLDERG \
  -XX:MetaspaceSize=1G -XX:MaxMetaspaceSize=2G \
  -Dfml.readTimeout=180 \
  @java9args.txt \
  -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \
  -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch \
  -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M \
  -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 \
  -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 \
  -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 \
  -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 \
  -jar lwjgl3ify-forgePatches.jar nogui
STARTSERVER_EOF
    
    # Replace placeholders
    sed -i "s/MIN_RAM_PLACEHOLDER/$MIN_RAM/g" "$SERVER_DIR/startserver.sh"
    sed -i "s/MAX_RAM_PLACEHOLDER/$MAX_RAM/g" "$SERVER_DIR/startserver.sh"
    
    chmod +x "$SERVER_DIR/startserver.sh"
    chown "$REAL_USER:$REAL_USER" "$SERVER_DIR/startserver.sh"
    
    log_info "Created startserver.sh (${MIN_RAM}GB-${MAX_RAM}GB RAM)"
}

# Get configuration from user
get_configuration() {
    log_step "Monitoring Configuration"
    
    echo ""
    echo "Default settings:"
    echo "  - Vote threshold: 60% of players"
    echo "  - TPS threshold: 19.0 (restart if lower)"
    echo "  - Vote cooldown: 10 minutes"
    echo "  - TPS auto-restart cooldown: 1 hour"
    echo "  - Log level: INFO"
    echo ""
    
    read -p "Use default settings? [Y/n] " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        # Use defaults
        VOTE_THRESHOLD=60
        TPS_THRESHOLD=19.0
        VOTE_CHECK_INTERVAL=10
        TPS_CHECK_INTERVAL=60
        VOTE_COOLDOWN=600
        TPS_COOLDOWN=3600
        LOG_LEVEL="INFO"
        log_info "Using default settings"
    else
        # Custom configuration
        echo ""
        read -r -p "Vote threshold (%): [60] " VOTE_THRESHOLD
        VOTE_THRESHOLD=${VOTE_THRESHOLD:-60}
        
        read -r -p "TPS threshold: [19.0] " TPS_THRESHOLD
        TPS_THRESHOLD=${TPS_THRESHOLD:-19.0}
        
        read -r -p "Vote check interval (seconds): [10] " VOTE_CHECK_INTERVAL
        VOTE_CHECK_INTERVAL=${VOTE_CHECK_INTERVAL:-10}
        
        read -r -p "TPS check interval (seconds): [60] " TPS_CHECK_INTERVAL
        TPS_CHECK_INTERVAL=${TPS_CHECK_INTERVAL:-60}
        
        read -r -p "Vote cooldown (seconds): [600] " VOTE_COOLDOWN
        VOTE_COOLDOWN=${VOTE_COOLDOWN:-600}
        
        read -r -p "TPS cooldown (seconds): [3600] " TPS_COOLDOWN
        TPS_COOLDOWN=${TPS_COOLDOWN:-3600}
        
        read -r -p "Log level (DEBUG/INFO/WARN/ERROR): [INFO] " LOG_LEVEL
        LOG_LEVEL=${LOG_LEVEL:-INFO}
        
        log_info "Custom settings configured"
    fi
}

# Create directory structure
create_directories() {
    log_step "Creating directory structure..."
    
    mkdir -p "$SCRIPT_DIR"/{lib,logs,restart_state,backups}
    chown -R "$REAL_USER:$REAL_USER" "$SCRIPT_DIR"
    
    log_info "$SCRIPT_DIR/lib/"
    log_info "$SCRIPT_DIR/logs/"
    log_info "$SCRIPT_DIR/restart_state/"
    log_info "$SCRIPT_DIR/backups/"
}

# Create backup
create_backup() {
    local backup_dir
    backup_dir="$SCRIPT_DIR/backups/backup_$(date +%Y%m%d_%H%M%S)"
    
    mkdir -p "$backup_dir"
    
    # Backup existing files
    [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && cp "/etc/systemd/system/${SERVICE_NAME}.service" "$backup_dir/"
    [ -f "/etc/systemd/system/${MONITORS_SERVICE_NAME}.service" ] && cp "/etc/systemd/system/${MONITORS_SERVICE_NAME}.service" "$backup_dir/"
    [ -f "/etc/sudoers.d/gtnh-restart" ] && cp "/etc/sudoers.d/gtnh-restart" "$backup_dir/"
    
    # Backup old scripts if they exist
    if [ -d "$SCRIPT_DIR/lib" ]; then
        cp -r "$SCRIPT_DIR/lib" "$backup_dir/" 2>/dev/null || true
    fi
    
    log_info "Backup created: $backup_dir"
}

# Deploy all monitoring scripts from embedded content
deploy_monitoring_scripts() {
    log_step "Deploying monitoring scripts..."
    
    # Create lib/common_functions.sh
    cat > "$SCRIPT_DIR/lib/common_functions.sh" << 'COMMON_FUNCTIONS_EOF'
#!/bin/bash

# Common Functions Module
# Shared utilities used across all monitoring modules

# ============= CONFIGURATION =============
SERVER_DIR="SERVER_DIR_PLACEHOLDER"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$SCRIPT_DIR/restart_state"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/master_monitor.log"
SCREEN_NAME="SCREEN_NAME_PLACEHOLDER"
SERVICE_NAME="SERVICE_NAME_PLACEHOLDER"

# Logging Settings
# LOG_LEVEL options:
#   DEBUG - Show all messages (verbose, includes TPS readings)
#   INFO  - Normal operation (vote events, TPS cycles, restarts)
#   WARN  - Warnings only (cooldowns, failures)
#   ERROR - Errors only
LOG_LEVEL=${LOG_LEVEL:-"LOG_LEVEL_PLACEHOLDER"}  # Default to INFO for cleaner logs

# Export all configuration variables
export SERVER_DIR SCRIPT_DIR STATE_DIR LOG_DIR LOG_FILE SCREEN_NAME LOG_LEVEL
export VOTE_PERCENTAGE MIN_VOTES_ABSOLUTE VOTE_DURATION MIN_VOTE_INTERVAL CHECK_VOTE_INTERVAL
export TPS_THRESHOLD TPS_CHECK_CYCLE_INTERVAL TPS_CHECKS_PER_CYCLE TPS_CHECK_DELAY
export TPS_REQUIRED_BAD_CHECKS TPS_RESTART_COOLDOWN GLOBAL_RESTART_COOLDOWN

# Vote Settings
VOTE_PERCENTAGE=VOTE_THRESHOLD_PLACEHOLDER
MIN_VOTES_ABSOLUTE=1
VOTE_DURATION=300           # Votes expire after 5 minutes
MIN_VOTE_INTERVAL=VOTE_COOLDOWN_PLACEHOLDER       # Vote restart cooldown
CHECK_VOTE_INTERVAL=VOTE_CHECK_INTERVAL_PLACEHOLDER      # Check votes every N seconds

# TPS Settings
TPS_THRESHOLD=TPS_THRESHOLD_PLACEHOLDER                  # TPS below this triggers restart
TPS_CHECK_CYCLE_INTERVAL=TPS_CHECK_INTERVAL_PLACEHOLDER         # Wait N seconds between check cycles
TPS_CHECKS_PER_CYCLE=7              # Check 7 times per cycle
TPS_CHECK_DELAY=1                   # 1s between checks in cycle
TPS_REQUIRED_BAD_CHECKS=5           # Need 5/7 bad checks to trigger restart
TPS_RESTART_COOLDOWN=TPS_COOLDOWN_PLACEHOLDER           # Cooldown between TPS restarts

# Global Settings
GLOBAL_RESTART_COOLDOWN=VOTE_COOLDOWN_PLACEHOLDER         # Minimum between any restart

# ============= UTILITY FUNCTIONS =============

# Log message to file with timestamp
# Usage: log_message "message" [level]
# Levels: DEBUG, INFO, WARN, ERROR (default: INFO)
log_message() {
    local message="$1"
    local level="${2:-INFO}"
    
    # Skip DEBUG messages if LOG_LEVEL is INFO or higher
    if [ "$level" = "DEBUG" ] && [ "$LOG_LEVEL" != "DEBUG" ]; then
        return
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
}

# Get current Unix timestamp
get_timestamp() {
    date +%s
}

# Send command to server via screen
send_server_command() {
    local command="$1"
    if ! screen -list | grep -q "\.$SCREEN_NAME"; then
        log_message "ERROR: Screen session '$SCREEN_NAME' not found"
        return 1
    fi
    screen -S "$SCREEN_NAME" -p 0 -X stuff "${command}^M"
    return 0
}

# Send colored say message to server
send_server_message() {
    local message="$1"
    send_server_command "say ${message}"
}

# Check if enough time has passed since last restart
# Usage: can_restart [optional_cooldown_seconds]
can_restart() {
    local period_override="$1"
    local cooldown_file="$STATE_DIR/last_any_restart"
    local cooldown_period=${period_override:-$GLOBAL_RESTART_COOLDOWN}
    
    if [ ! -f "$cooldown_file" ]; then
        return 0
    fi
    
    local last_restart
    last_restart=$(cat "$cooldown_file")
    local current_time
    current_time=$(get_timestamp)
    local time_since=$((current_time - last_restart))
    
    if [ "$time_since" -lt "$cooldown_period" ]; then
        local remaining=$((cooldown_period - time_since))
        local minutes=$((remaining / 60))
        local seconds=$((remaining % 60))
        log_message "Restart blocked by cooldown. ${minutes}m ${seconds}s remaining (required: ${cooldown_period}s)"
        return 1
    fi
    
    return 0
}

# Get remaining cooldown time in seconds
get_cooldown_remaining() {
    local period_override="$1"
    local cooldown_file="$STATE_DIR/last_any_restart"
    local cooldown_period=${period_override:-$GLOBAL_RESTART_COOLDOWN}
    
    if [ ! -f "$cooldown_file" ]; then
        echo "0"
        return
    fi
    
    local last_restart
    last_restart=$(cat "$cooldown_file")
    local current_time
    current_time=$(get_timestamp)
    local time_since=$((current_time - last_restart))
    local remaining=$((cooldown_period - time_since))
    
    if [ "$remaining" -le 0 ]; then
        echo "0"
    else
        echo "$remaining"
    fi
}

# Format seconds as human-readable time
format_time_remaining() {
    local seconds=$1
    local minutes=$((seconds / 60))
    local remaining_seconds=$((seconds % 60))
    
    if [ "$minutes" -gt 0 ]; then
        echo "${minutes}m ${remaining_seconds}s"
    else
        echo "${seconds}s"
    fi
}

# Mark that a restart has occurred
mark_restart() {
    local restart_type="$1"
    local timestamp=$(get_timestamp)
    
    echo "$timestamp" > "$STATE_DIR/last_any_restart"
    
    if [ "$restart_type" = "vote" ]; then
        echo "$timestamp" > "$STATE_DIR/last_vote_restart"
        log_message "Marked vote restart at $timestamp"
    elif [ "$restart_type" = "tps" ]; then
        echo "$timestamp" > "$STATE_DIR/last_tps_restart"
        log_message "Marked TPS restart at $timestamp"
    fi
}

# Initialize directories and files
initialize_system() {
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
    fi
    
    log_message "=== Monitoring system initialized ===" "INFO"
    log_message "Config: Vote ${VOTE_PERCENTAGE}%, TPS threshold ${TPS_THRESHOLD}" "INFO"
    log_message "Paths: SERVER_DIR=$SERVER_DIR" "INFO"
    log_message "       STATE_DIR=$STATE_DIR" "INFO"
    log_message "       LOG_DIR=$LOG_DIR" "INFO"
}

# Check if server is ready
is_server_ready() {
    if ! screen -list | grep -q "\.$SCREEN_NAME"; then
        return 1
    fi
    
    if ! tail -n 200 "$SERVER_DIR/logs/latest.log" 2>/dev/null | grep -q "Done"; then
        return 1
    fi
    
    return 0
}

# Wait for server to be ready
wait_for_server() {
    log_message "Waiting for server to be ready..." "INFO"
    
    for i in {1..120}; do
        if is_server_ready; then
            log_message "Server is ready (attempt $i/120)" "INFO"
            return 0
        fi
        sleep 2
    done
    
    log_message "WARNING: Server not detected as ready after 240 seconds, proceeding anyway" "INFO"
    return 1
}

# Export functions so they can be used by modules
export -f log_message
export -f get_timestamp
export -f send_server_command
export -f send_server_message
export -f can_restart
export -f get_cooldown_remaining
export -f format_time_remaining
export -f mark_restart
export -f initialize_system
export -f is_server_ready
export -f wait_for_server
COMMON_FUNCTIONS_EOF
    
    # Replace placeholders in common_functions.sh
    sed -i "s|SERVER_DIR_PLACEHOLDER|$SERVER_DIR|g" "$SCRIPT_DIR/lib/common_functions.sh"
    sed -i "s/VOTE_THRESHOLD_PLACEHOLDER/$VOTE_THRESHOLD/g" "$SCRIPT_DIR/lib/common_functions.sh"
    sed -i "s/TPS_THRESHOLD_PLACEHOLDER/$TPS_THRESHOLD/g" "$SCRIPT_DIR/lib/common_functions.sh"
    sed -i "s/VOTE_CHECK_INTERVAL_PLACEHOLDER/$VOTE_CHECK_INTERVAL/g" "$SCRIPT_DIR/lib/common_functions.sh"
    sed -i "s/TPS_CHECK_INTERVAL_PLACEHOLDER/$TPS_CHECK_INTERVAL/g" "$SCRIPT_DIR/lib/common_functions.sh"
    sed -i "s/VOTE_COOLDOWN_PLACEHOLDER/$VOTE_COOLDOWN/g" "$SCRIPT_DIR/lib/common_functions.sh"
    sed -i "s/TPS_COOLDOWN_PLACEHOLDER/$TPS_COOLDOWN/g" "$SCRIPT_DIR/lib/common_functions.sh"
    sed -i "s/LOG_LEVEL_PLACEHOLDER/$LOG_LEVEL/g" "$SCRIPT_DIR/lib/common_functions.sh"
    sed -i "s/SCREEN_NAME_PLACEHOLDER/$SCREEN_SESSION_NAME/g" "$SCRIPT_DIR/lib/common_functions.sh"
    sed -i "s/SERVICE_NAME_PLACEHOLDER/$SERVICE_NAME/g" "$SCRIPT_DIR/lib/common_functions.sh"
    
    log_info "lib/common_functions.sh"
    
    # Create lib/restart_functions.sh
    cat > "$SCRIPT_DIR/lib/restart_functions.sh" << 'RESTART_FUNCTIONS_EOF'
#!/bin/bash

# Restart Functions Module
# Handles countdown sequences and restart coordination

# Source common functions (if not already sourced)
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SCRIPT_DIR/lib/common_functions.sh"
fi

# ============= RESTART FUNCTIONS =============

# Vote-based restart with 30-second countdown
do_vote_restart() {
    log_message "=== INITIATING VOTE-BASED RESTART ==="
    
    # 30-second countdown
    send_server_message "§c§l30 seconds...§r"
    sleep 10
    send_server_message "§c§l20 seconds...§r"
    sleep 10
    send_server_message "§c§l10 seconds...§r"
    sleep 5
    send_server_message "§c§l5...§r"
    sleep 1
    send_server_message "§c§l4...§r"
    sleep 1
    send_server_message "§c§l3...§r"
    sleep 1
    send_server_message "§c§l2...§r"
    sleep 1
    send_server_message "§c§l1...§r"
    sleep 1
    
    mark_restart "vote"
    trigger_systemd_restart "vote"
}

# TPS-based restart with 3-minute countdown
do_tps_restart() {
    local current_tps="$1"
    
    log_message "=== INITIATING TPS-BASED RESTART (TPS: $current_tps) ==="
    
    # Check global cooldown with TPS-specific period
    if ! can_restart "$TPS_RESTART_COOLDOWN"; then
        local remaining
        remaining=$(get_cooldown_remaining "$TPS_RESTART_COOLDOWN")
        local time_msg
        time_msg=$(format_time_remaining "$remaining")
        
        log_message "TPS restart blocked by cooldown (${remaining}s remaining)"
        send_server_message "§c§l[AUTO-RESTART]§r Blocked - wait ${time_msg} since last restart"
        return 1
    fi
    
    # 3-minute countdown
    send_server_message "§c§l[AUTO-RESTART]§r TPS critically low (${current_tps}). Auto-restart in §e§l3 minutes§r"
    sleep 120
    
    send_server_message "§c§l[AUTO-RESTART]§r Restarting in §e§l1 minute§r"
    sleep 30
    
    send_server_message "§c§l[AUTO-RESTART]§r §e§l30 seconds§r..."
    sleep 10
    
    send_server_message "§c§l[AUTO-RESTART]§r §e§l20 seconds§r..."
    sleep 10
    
    send_server_message "§c§l[AUTO-RESTART]§r §e§l10 seconds§r..."
    sleep 5
    
    send_server_message "§c§l5...§r"
    sleep 1
    send_server_message "§c§l4...§r"
    sleep 1
    send_server_message "§c§l3...§r"
    sleep 1
    send_server_message "§c§l2...§r"
    sleep 1
    send_server_message "§c§l1...§r"
    sleep 1
    
    mark_restart "tps"
    trigger_systemd_restart "tps"
}

# Trigger systemd restart
trigger_systemd_restart() {
    local restart_type="$1"
    
    log_message "Triggering systemd restart (type: $restart_type)..."
    
    if sudo systemctl restart ${SERVICE_NAME}.service 2>&1 | tee -a "$LOG_FILE"; then
        log_message "=== RESTART TRIGGERED SUCCESSFULLY ==="
    else
        log_message "ERROR: Failed to trigger restart! Check sudo permissions."
        return 1
    fi
    
    log_message "Server should be back up in ~60 seconds"
    exit 0
}

# Export functions
export -f do_vote_restart
export -f do_tps_restart
export -f trigger_systemd_restart
RESTART_FUNCTIONS_EOF
    
    log_info "lib/restart_functions.sh"
    
    # Create lib/vote_functions.sh
    cat > "$SCRIPT_DIR/lib/vote_functions.sh" << 'VOTE_FUNCTIONS_EOF'
#!/bin/bash

# Vote Functions Module
# Handles player vote-based restart monitoring

# Source common functions (if not already sourced)
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SCRIPT_DIR/lib/common_functions.sh"
fi

# Vote state files
VOTE_FILE="$STATE_DIR/current_votes"
ACKNOWLEDGED_FILE="$STATE_DIR/acknowledged_voters"
LAST_VOTE_RESTART_FILE="$STATE_DIR/last_vote_restart"

# ============= VOTE FUNCTIONS =============

# Get online player count
get_online_players() {
    send_server_command "list"
    sleep 2
    
    local count=$(tail -n 20 "$SERVER_DIR/logs/latest.log" | grep -oP 'There are \K[0-9]+(?=/[0-9]+ players online)' | tail -1)
    if [ -z "$count" ]; then
        count=$(tail -n 20 "$SERVER_DIR/logs/latest.log" | grep -oP 'There are \K[0-9]+' | tail -1)
    fi
    
    log_message "Player count: ${count:-0}" "DEBUG"
    echo "${count:-0}"
}

# Calculate votes needed based on online players
calculate_votes_needed() {
    local online=$1
    if [ "$online" -eq 0 ]; then
        echo "$MIN_VOTES_ABSOLUTE"
        return
    fi
    local needed
    needed=$(awk -v online="$online" -v pct="$VOTE_PERCENTAGE" 'BEGIN {printf "%.0f", (online * pct / 100) + 0.5}')
    if [ "$needed" -lt "$MIN_VOTES_ABSOLUTE" ]; then
        needed=$MIN_VOTES_ABSOLUTE
    fi
    echo "$needed"
}

# Check if vote restart cooldown allows restart
can_vote_restart() {
    if [ ! -f "$LAST_VOTE_RESTART_FILE" ]; then
        return 0
    fi
    LAST_VOTE_RESTART=$(cat "$LAST_VOTE_RESTART_FILE")
    CURRENT_TIME=$(get_timestamp)
    TIME_SINCE_RESTART=$((CURRENT_TIME - LAST_VOTE_RESTART))
    if [ $TIME_SINCE_RESTART -ge $MIN_VOTE_INTERVAL ]; then
        return 0
    else
        REMAINING=$((MIN_VOTE_INTERVAL - TIME_SINCE_RESTART))
        log_message "Vote restart on cooldown. ${REMAINING}s remaining."
        return 1
    fi
}

# Initialize vote tracking (called once at startup)
initialize_vote_tracking() {
    LAST_LINE_FILE="$STATE_DIR/last_vote_line"
    
    if [ ! -f "$LAST_LINE_FILE" ]; then
        CURRENT_LINES=$(wc -l < "$SERVER_DIR/logs/latest.log" 2>/dev/null || echo "0")
        echo "$CURRENT_LINES" > "$LAST_LINE_FILE"
        log_message "Vote tracking initialized - will process votes from line $CURRENT_LINES onwards"
    fi
}

# Process votes from server log
process_votes() {
    LAST_LINE_FILE="$STATE_DIR/last_vote_line"
    if [ -f "$LAST_LINE_FILE" ]; then
        LAST_LINE=$(cat "$LAST_LINE_FILE")
    else
        LAST_LINE=0
    fi
    
    TOTAL_LINES=$(wc -l < "$SERVER_DIR/logs/latest.log")
    
    if [ "$TOTAL_LINES" -lt "$LAST_LINE" ]; then
        log_message "Log file rotated, resetting"
        LAST_LINE=0
    fi
    
    if [ "$TOTAL_LINES" -le "$LAST_LINE" ]; then
        return
    fi
    
    NEW_LINE_COUNT=$((TOTAL_LINES - LAST_LINE))
    RECENT_LOGS=$(tail -n "$NEW_LINE_COUNT" "$SERVER_DIR/logs/latest.log")
    echo "$TOTAL_LINES" > "$LAST_LINE_FILE"
    
    NEW_VOTES=$(echo "$RECENT_LOGS" | grep -E '\[Server thread/INFO\]: <[^>]+> !(vote ?restart|restart)' | grep -oP '<\K[^>]+' | sort -u)
    
    if [ -z "$NEW_VOTES" ]; then
        return
    fi
    
    log_message "Vote command detected, processing..." "INFO"
    
    ONLINE_PLAYERS=$(get_online_players)
    VOTES_NEEDED=$(calculate_votes_needed "$ONLINE_PLAYERS")
    
    if [ -f "$VOTE_FILE" ]; then
        CURRENT_VOTES=$(cat "$VOTE_FILE")
        VOTE_AGE=$(($(get_timestamp) - $(stat -c %Y "$VOTE_FILE")))
        if [ $VOTE_AGE -gt $VOTE_DURATION ]; then
            log_message "Votes expired after ${VOTE_DURATION}s, resetting" "INFO"
            rm "$VOTE_FILE" "$ACKNOWLEDGED_FILE" 2>/dev/null
            CURRENT_VOTES=""
        fi
    else
        CURRENT_VOTES=""
    fi
    
    if [ -f "$ACKNOWLEDGED_FILE" ]; then
        ACKNOWLEDGED=$(cat "$ACKNOWLEDGED_FILE")
    else
        ACKNOWLEDGED=""
    fi
    
    UNACKNOWLEDGED_VOTERS=""
    while IFS= read -r voter; do
        if [ -n "$voter" ] && ! echo "$ACKNOWLEDGED" | grep -q "^${voter}$"; then
            UNACKNOWLEDGED_VOTERS="${UNACKNOWLEDGED_VOTERS}${voter}"$'\n'
        fi
    done <<< "$NEW_VOTES"
    
    UNACKNOWLEDGED_VOTERS=$(echo "$UNACKNOWLEDGED_VOTERS" | grep -v '^$')
    
    ALL_VOTES=$(echo -e "${CURRENT_VOTES}\n${NEW_VOTES}" | sort -u | grep -v '^$')
    echo "$ALL_VOTES" > "$VOTE_FILE"
    
    VOTE_COUNT=$(echo "$ALL_VOTES" | wc -l)
    
    if [ -n "$UNACKNOWLEDGED_VOTERS" ]; then
        log_message "New votes from: $(echo "$UNACKNOWLEDGED_VOTERS" | tr '\n' ',' | sed 's/,$//')" "INFO"
        log_message "Vote count: ${VOTE_COUNT}/${VOTES_NEEDED} (${ONLINE_PLAYERS} players online)" "INFO"
        send_server_message "§3§l[VOTE]§r Restart votes: §e§l${VOTE_COUNT}/${VOTES_NEEDED}§r needed (${VOTE_PERCENTAGE}% of ${ONLINE_PLAYERS} players). Type §a!restart§r to vote"
        echo -e "${ACKNOWLEDGED}\n${UNACKNOWLEDGED_VOTERS}" | sort -u | grep -v '^$' > "$ACKNOWLEDGED_FILE"
    else
        log_message "Duplicate votes detected, ignoring" "DEBUG"
    fi
    
    if [ "$VOTE_COUNT" -ge "$VOTES_NEEDED" ]; then
        if ! can_vote_restart; then
            log_message "Vote restart on cooldown" "WARN"
            rm "$VOTE_FILE" "$ACKNOWLEDGED_FILE" 2>/dev/null
            return
        fi
        
        if ! can_restart; then
            local remaining
            remaining=$(get_cooldown_remaining)
            local time_msg
            time_msg=$(format_time_remaining "$remaining")
            
            log_message "Vote blocked by global cooldown (${remaining}s remaining)" "WARN"
            send_server_message "§c§l[VOTE]§r Restart blocked - wait ${time_msg} (server restarted recently)"
            
            rm "$VOTE_FILE" "$ACKNOWLEDGED_FILE" 2>/dev/null
            return
        fi
        
        log_message "Vote threshold reached! (${VOTE_COUNT}/${VOTES_NEEDED})" "INFO"
        send_server_message "§a§l[VOTE]§r Vote passed (§e${VOTE_COUNT}/${VOTES_NEEDED}§r)! §c§lServer restarting...§r"
        
        rm "$VOTE_FILE" "$ACKNOWLEDGED_FILE" 2>/dev/null
        
        source "$SCRIPT_DIR/lib/restart_functions.sh"
        do_vote_restart
        
        rm "$LAST_LINE_FILE" 2>/dev/null
    fi
}

# Export functions
export -f get_online_players
export -f calculate_votes_needed
export -f can_vote_restart
export -f initialize_vote_tracking
export -f process_votes
VOTE_FUNCTIONS_EOF
    
    log_info "lib/vote_functions.sh"
    
    # Create lib/tps_functions.sh
    cat > "$SCRIPT_DIR/lib/tps_functions.sh" << 'TPS_FUNCTIONS_EOF'
#!/bin/bash

# TPS Functions Module
# Handles automatic TPS monitoring and low-TPS restart detection

# Source common functions (if not already sourced)
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "$SCRIPT_DIR/lib/common_functions.sh"
fi

# TPS state files
LAST_TPS_RESTART_FILE="$STATE_DIR/last_tps_restart"
TPS_STATE_FILE="$STATE_DIR/tps_check_state"

# ============= TPS FUNCTIONS =============

# Get current TPS from server
get_current_tps() {
    local forge_tps="20.0"
    
    send_server_command "forge tps"
    sleep 2
    
    local forge_readings
    forge_readings=$(tail -n 50 "$SERVER_DIR/logs/latest.log" | grep "Mean TPS:" | grep -oP 'Mean TPS:\s*\K[0-9]+\.?[0-9]*')
    
    if [ -n "$forge_readings" ]; then
        forge_tps=$(echo "$forge_readings" | sort -n | head -1)
        local dim_count
        dim_count=$(echo "$forge_readings" | wc -l)
        log_message "Forge TPS: $dim_count dimensions checked, lowest: $forge_tps" "DEBUG"
    else
        log_message "Could not parse /forge tps output" "WARN"
    fi
    
    log_message "Current TPS: $forge_tps" "INFO"
    echo "$forge_tps"
}

# Check if TPS is below threshold
is_tps_low() {
    local tps="$1"
    local threshold="$TPS_THRESHOLD"
    
    local is_low=$(awk -v tps="$tps" -v threshold="$threshold" 'BEGIN {print (tps < threshold) ? "1" : "0"}')
    
    return $((1 - is_low))
}

# Run a complete TPS check cycle (7 checks over 7 seconds)
run_tps_check_cycle() {
    log_message "Starting TPS check cycle (${TPS_CHECKS_PER_CYCLE} checks)..." "DEBUG"
    
    local bad_check_count=0
    local tps_readings=""
    
    for i in $(seq 1 "$TPS_CHECKS_PER_CYCLE"); do
        local tps
        tps=$(get_current_tps)
        tps_readings="${tps_readings}${tps} "
        
        if is_tps_low "$tps"; then
            ((bad_check_count++))
            log_message "  Check $i/$TPS_CHECKS_PER_CYCLE: TPS=$tps [LOW]" "DEBUG"
        else
            log_message "  Check $i/$TPS_CHECKS_PER_CYCLE: TPS=$tps [OK]" "DEBUG"
        fi
        
        if [ $i -lt $TPS_CHECKS_PER_CYCLE ]; then
            sleep $TPS_CHECK_DELAY
        fi
    done
    
    log_message "TPS check cycle complete: $bad_check_count/$TPS_CHECKS_PER_CYCLE checks below threshold" "INFO"
    log_message "  Readings: $tps_readings" "DEBUG"
    
    if [ $bad_check_count -ge $TPS_REQUIRED_BAD_CHECKS ]; then
        log_message "TPS critically low! ($bad_check_count/$TPS_CHECKS_PER_CYCLE checks failed)" "WARN"
        
        local avg_tps=$(echo "$tps_readings" | awk '{sum=0; for(i=1;i<=NF;i++) sum+=$i; print sum/NF}')
        
        if can_restart "$TPS_RESTART_COOLDOWN"; then
            source "$SCRIPT_DIR/lib/restart_functions.sh"
            do_tps_restart "$avg_tps"
        else
            log_message "TPS restart needed but blocked by cooldown (need 1 hour since last restart)" "WARN"
            
            local remaining
            remaining=$(get_cooldown_remaining "$TPS_RESTART_COOLDOWN")
            local time_msg
            time_msg=$(format_time_remaining "$remaining")
            
            send_server_message "§e[NOTICE]§r TPS is critically low but server was restarted recently. Auto-restart available in ${time_msg}."
        fi
    else
        log_message "TPS acceptable ($bad_check_count/$TPS_CHECKS_PER_CYCLE checks failed, need $TPS_REQUIRED_BAD_CHECKS)" "INFO"
    fi
}

# Check if it's time to run another TPS cycle
should_run_tps_cycle() {
    local last_cycle_file="$STATE_DIR/last_tps_cycle"
    
    if [ ! -f "$last_cycle_file" ]; then
        echo "0" > "$last_cycle_file"
        return 0
    fi
    
    local last_cycle=$(cat "$last_cycle_file")
    local current_time=$(get_timestamp)
    local time_since=$((current_time - last_cycle))
    
    if [ $time_since -ge $TPS_CHECK_CYCLE_INTERVAL ]; then
        return 0
    else
        return 1
    fi
}

# Mark that we've completed a TPS cycle
mark_tps_cycle_complete() {
    local last_cycle_file="$STATE_DIR/last_tps_cycle"
    get_timestamp > "$last_cycle_file"
}

# Initialize TPS monitoring (called once at startup)
initialize_tps_monitoring() {
    local last_cycle_file="$STATE_DIR/last_tps_cycle"
    
    if [ ! -f "$last_cycle_file" ]; then
        get_timestamp > "$last_cycle_file"
        log_message "TPS monitoring initialized - first cycle in ${TPS_CHECK_CYCLE_INTERVAL}s"
    else
        log_message "TPS monitoring resumed from previous state"
    fi
}

# Export functions
export -f get_current_tps
export -f is_tps_low
export -f run_tps_check_cycle
export -f should_run_tps_cycle
export -f mark_tps_cycle_complete
export -f initialize_tps_monitoring
TPS_FUNCTIONS_EOF
    
    log_info "lib/tps_functions.sh"
    
    # Create gtnh_master_monitor.sh
    cat > "$SCRIPT_DIR/gtnh_master_monitor.sh" << 'MASTER_MONITOR_EOF'
#!/bin/bash

# shellcheck source=lib/common_functions.sh
# shellcheck source=lib/restart_functions.sh
# shellcheck source=lib/vote_functions.sh
# shellcheck source=lib/tps_functions.sh

# GTNH Master Monitor Script
# Orchestrates vote monitoring and TPS monitoring in a unified system

# ============= INITIALIZATION =============

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all modules
source "$SCRIPT_DIR/lib/common_functions.sh"
source "$SCRIPT_DIR/lib/restart_functions.sh"
source "$SCRIPT_DIR/lib/vote_functions.sh"
source "$SCRIPT_DIR/lib/tps_functions.sh"

# Initialize system
initialize_system

# ============= STARTUP =============

log_message "=== GTNH Master Monitor Starting ===" "INFO"
log_message "Modules loaded: common, restart, vote, tps" "INFO"
log_message "Vote: ${VOTE_PERCENTAGE}% threshold, check every ${CHECK_VOTE_INTERVAL}s" "INFO"
log_message "TPS: ${TPS_THRESHOLD} threshold, cycle every ${TPS_CHECK_CYCLE_INTERVAL}s (${TPS_CHECKS_PER_CYCLE} checks)" "INFO"
log_message "Global restart cooldown: ${GLOBAL_RESTART_COOLDOWN}s ($(($GLOBAL_RESTART_COOLDOWN / 60))m)" "INFO"

# Wait for server to be ready
wait_for_server

# Initialize monitoring subsystems
initialize_vote_tracking
initialize_tps_monitoring

log_message "=== All systems ready, starting monitoring loop ===" "INFO"

# ============= MAIN MONITORING LOOP =============

# Timing trackers
LAST_VOTE_CHECK=$(get_timestamp)
LAST_TPS_CYCLE=$(get_timestamp)

while true; do
    if ! screen -list | grep -q "\.$SCREEN_NAME"; then
        sleep "$CHECK_VOTE_INTERVAL"
        continue
    fi
    
    CURRENT_TIME=$(get_timestamp)
    
    # ===== VOTE MONITORING =====
    if [ $((CURRENT_TIME - LAST_VOTE_CHECK)) -ge $CHECK_VOTE_INTERVAL ]; then
        process_votes
        LAST_VOTE_CHECK=$CURRENT_TIME
    fi
    
    # ===== TPS MONITORING =====
    if [ $((CURRENT_TIME - LAST_TPS_CYCLE)) -ge "$TPS_CHECK_CYCLE_INTERVAL" ]; then
        log_message "TPS cycle timer triggered (${TPS_CHECK_CYCLE_INTERVAL}s interval)" "DEBUG"
        run_tps_check_cycle
        mark_tps_cycle_complete
        LAST_TPS_CYCLE=$(get_timestamp)
    fi
    
    sleep 1
done
MASTER_MONITOR_EOF
    
    log_info "gtnh_master_monitor.sh"
    
    # Create start_monitors.sh
    cat > "$SCRIPT_DIR/start_monitors.sh" << 'START_MONITORS_EOF'
#!/bin/bash

# Master script to start all monitoring scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Stop any existing instances of monitor scripts
pkill -f gtnh_vote_monitor.sh 2>/dev/null
pkill -f gtnh_master_monitor.sh 2>/dev/null
sleep 1

# Start the master monitor script (vote + TPS)
# Use exec to replace this process with the monitor
exec ./gtnh_master_monitor.sh
START_MONITORS_EOF
    
    log_info "start_monitors.sh"
    
    # Set permissions
    chmod +x "$SCRIPT_DIR"/*.sh
    chmod +x "$SCRIPT_DIR"/lib/*.sh
    chown -R "$REAL_USER:$REAL_USER" "$SCRIPT_DIR"
    
    log_info "All scripts deployed and permissions set"
}

# Generate systemd service files
generate_services() {
    log_step "Generating systemd service files..."
    
    # Generate ${SERVICE_NAME}.service
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SERVICE_EOF
[Unit]
Description=GTNH Minecraft Server
After=network.target

[Service]
Type=forking
User=$REAL_USER
WorkingDirectory=$SERVER_DIR
ExecStart=/usr/bin/screen -dmS ${SCREEN_SESSION_NAME} /bin/bash $SERVER_DIR/$START_SCRIPT
ExecStop=/usr/bin/screen -p 0 -S ${SCREEN_SESSION_NAME} -X eval 'stuff "stop\\015"'
ExecStop=/bin/sleep 30
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    
    log_info "Created /etc/systemd/system/${SERVICE_NAME}.service"
    
    # Generate ${MONITORS_SERVICE_NAME}.service
    cat > "/etc/systemd/system/${MONITORS_SERVICE_NAME}.service" << MONITORS_SERVICE_EOF
[Unit]
Description=GTNH Vote and TPS Monitoring System
After=network.target ${SERVICE_NAME}.service
Requires=${SERVICE_NAME}.service

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$SCRIPT_DIR
ExecStart=/bin/bash $SCRIPT_DIR/start_monitors.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
MONITORS_SERVICE_EOF
    
    log_info "Created /etc/systemd/system/${MONITORS_SERVICE_NAME}.service"
}

# Configure sudoers
configure_sudoers() {
    log_step "Configuring sudoers for passwordless restarts..."
    
    local sudoers_file="/etc/sudoers.d/gtnh-restart"
    
    cat > "$sudoers_file" << SUDOERS_EOF
# GTNH Server - Allow passwordless systemd restarts
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ${SERVICE_NAME}.service
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ${MONITORS_SERVICE_NAME}.service
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start ${SERVICE_NAME}.service
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop ${SERVICE_NAME}.service
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl status ${SERVICE_NAME}.service
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start ${MONITORS_SERVICE_NAME}.service
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop ${MONITORS_SERVICE_NAME}.service
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl status ${MONITORS_SERVICE_NAME}.service
SUDOERS_EOF
    
    chmod 0440 "$sudoers_file"
    
    # Validate sudoers syntax
    if visudo -c -f "$sudoers_file" &> /dev/null; then
        log_info "Created $sudoers_file"
        log_info "User '$REAL_USER' can now restart services without password"
    else
        log_error "Sudoers syntax error!"
        rm "$sudoers_file"
        exit 1
    fi
}

# Generate documentation
generate_documentation() {
    log_step "Generating documentation..."
    
    local docs_dir="$SCRIPT_DIR/docs"
    mkdir -p "$docs_dir"
    
    # Get current configuration values
    local install_date
    install_date=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 1. Generate .service_info
    cat > "$SCRIPT_DIR/.service_info" << 'SERVICE_INFO_EOF'
# Auto-generated by setup.sh
# Machine-readable service metadata
SERVER_SERVICE=${SERVICE_NAME}.service
MONITORS_SERVICE=${MONITORS_SERVICE_NAME}.service
SCREEN_SESSION=${SCREEN_NAME}
SERVER_DIR=${SERVER_DIR}
USER=${REAL_USER}
INSTALL_DATE=${install_date}
SERVICE_INFO_EOF
    
    # Substitute variables in .service_info
    sed -i "s|\${SERVICE_NAME}|${SERVICE_NAME}|g" "$SCRIPT_DIR/.service_info"
    sed -i "s|\${MONITORS_SERVICE_NAME}|${MONITORS_SERVICE_NAME}|g" "$SCRIPT_DIR/.service_info"
    sed -i "s|\${SCREEN_NAME}|${SCREEN_NAME}|g" "$SCRIPT_DIR/.service_info"
    sed -i "s|\${SERVER_DIR}|${SERVER_DIR}|g" "$SCRIPT_DIR/.service_info"
    sed -i "s|\${REAL_USER}|${REAL_USER}|g" "$SCRIPT_DIR/.service_info"
    sed -i "s|\${install_date}|${install_date}|g" "$SCRIPT_DIR/.service_info"
    
    chmod 644 "$SCRIPT_DIR/.service_info"
    
    # 2. Generate main README.md
    cat > "$SCRIPT_DIR/README.md" << 'README_EOF'
# GTNH Server Monitoring System

**Installation Date:** ${install_date}  
**Server Directory:** `${SERVER_DIR}`

---

## Overview

This monitoring system provides automated server management for your GTNH (GregTech: New Horizons) Minecraft server, including:

- **Player Vote Restarts:** Players can vote for restarts using `!restart` in chat
- **Automatic TPS Monitoring:** Auto-restart when server performance degrades
- **Systemd Integration:** Managed services with auto-start on boot
- **Cooldown Management:** Prevents restart spam with configurable cooldowns

---

## Service Information

**Your service names** (see `docs/QUICK_REFERENCE.md` for command cheatsheet):

| Component | Service Name |
|-----------|-------------|
| **Main Server** | `${SERVICE_NAME}.service` |
| **Monitoring** | `${MONITORS_SERVICE_NAME}.service` |
| **Screen Session** | `${SCREEN_NAME}` |

---

## Quick Commands

### Service Management

```bash
# Start server
sudo systemctl start ${SERVICE_NAME}.service

# Stop server
sudo systemctl stop ${SERVICE_NAME}.service

# Restart server
sudo systemctl restart ${SERVICE_NAME}.service

# Check server status
sudo systemctl status ${SERVICE_NAME}.service

# Restart monitoring
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service

# Check monitoring status
sudo systemctl status ${MONITORS_SERVICE_NAME}.service
```

### Access Server Console

```bash
# Attach to screen session
screen -r ${SCREEN_NAME}

# Detach from screen (while inside):
# Press Ctrl+A, then D
```

### View Logs

```bash
# Monitoring logs (live)
tail -f ${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log

# Server logs (live)
tail -f ${SERVER_DIR}/logs/latest.log

# Journalctl logs
journalctl -u ${SERVICE_NAME}.service -f
journalctl -u ${MONITORS_SERVICE_NAME}.service -f
```

---

## Vote Restart System

### How It Works

1. Players type `!restart` in Minecraft chat
2. System tracks unique player votes
3. When **${VOTE_PERCENTAGE}%** of online players vote, restart triggers
4. 30-second countdown begins
5. Server restarts automatically

### Cooldown

- **Manual vote restarts:** Once every **10 minutes**
- If on cooldown, players see remaining time in chat

### Example

```
[VOTE] KneeGrow voted for restart (1/2 needed, 50% of 2 players)
[VOTE] PlayerTwo voted for restart (2/2 needed, 100% of 2 players)
[VOTE] Vote passed (2/2)! Server restarting...
§c§l[RESTART] §r§eServer restarting in §c30§e seconds...
```

---

## Automatic TPS Restart System

### How It Works

1. Every **60 seconds**, system runs a TPS check cycle
2. Checks TPS **7 times** (3 seconds apart)
3. If **5 out of 7 checks** show TPS < **${TPS_THRESHOLD}**, restart triggers
4. 3-minute countdown begins (3m → 1m → 30s → 20s → 10s → 5-4-3-2-1)
5. Server restarts automatically

### Cooldown

- **Automatic TPS restarts:** Once every **1 hour**
- If on cooldown, message appears in server logs only (not chat)
- Manual vote restarts reset this cooldown

### Priority

- **Vote restarts take priority** over TPS restarts
- If both want to run, vote restart executes

---

## Configuration

See `docs/CONFIGURATION.md` for detailed configuration guide.

**Quick Settings:**

- Edit: `${SERVER_DIR}/minecraft_scripts/lib/common_functions.sh`
- Key variables:
  - `VOTE_PERCENTAGE` - Vote threshold (default: 60%)
  - `TPS_THRESHOLD` - TPS restart threshold (default: 19.0)
  - `GLOBAL_RESTART_COOLDOWN` - Manual restart cooldown (default: 600s = 10 min)
  - `TPS_RESTART_COOLDOWN` - Auto restart cooldown (default: 3600s = 1 hour)
  - `LOG_LEVEL` - Verbosity: DEBUG/INFO/WARN/ERROR (default: INFO)

**After changing settings:**

```bash
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
```

---

## File Locations

| Type | Path |
|------|------|
| **Scripts** | `${SERVER_DIR}/minecraft_scripts/` |
| **Configuration** | `${SERVER_DIR}/minecraft_scripts/lib/common_functions.sh` |
| **Monitoring Logs** | `${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log` |
| **Server Logs** | `${SERVER_DIR}/logs/latest.log` |
| **State Files** | `${SERVER_DIR}/minecraft_scripts/restart_state/` |
| **Systemd Services** | `/etc/systemd/system/${SERVICE_NAME}*.service` |
| **Sudoers Config** | `/etc/sudoers.d/gtnh-restart` |

---

## Troubleshooting

See `docs/TROUBLESHOOTING.md` for detailed troubleshooting guide.

**Common Issues:**

- **Server won't start:** Check screen session, logs, EULA acceptance
- **Votes not registering:** Check cooldown, player count, logs
- **TPS monitor not working:** Check `/forge tps` command, set LOG_LEVEL=DEBUG
- **Permission denied:** Check sudoers configuration

---

## Documentation

- **Quick Reference:** `docs/QUICK_REFERENCE.md` - Command cheat sheet
- **Configuration:** `docs/CONFIGURATION.md` - How to adjust settings
- **Troubleshooting:** `docs/TROUBLESHOOTING.md` - Common issues & solutions
- **Architecture:** `docs/ARCHITECTURE.md` - System design & internals

---

## Version

**Setup Script Version:** 1.0.0  
**Install Date:** ${install_date}

For questions or issues, check the documentation in the `docs/` directory.
README_EOF

    # Substitute variables in README.md
    sed -i "s|\${install_date}|${install_date}|g" "$SCRIPT_DIR/README.md"
    sed -i "s|\${SERVER_DIR}|${SERVER_DIR}|g" "$SCRIPT_DIR/README.md"
    sed -i "s|\${SERVICE_NAME}|${SERVICE_NAME}|g" "$SCRIPT_DIR/README.md"
    sed -i "s|\${MONITORS_SERVICE_NAME}|${MONITORS_SERVICE_NAME}|g" "$SCRIPT_DIR/README.md"
    sed -i "s|\${SCREEN_NAME}|${SCREEN_NAME}|g" "$SCRIPT_DIR/README.md"
    sed -i "s|\${VOTE_PERCENTAGE}|${VOTE_PERCENTAGE}|g" "$SCRIPT_DIR/README.md"
    sed -i "s|\${TPS_THRESHOLD}|${TPS_THRESHOLD}|g" "$SCRIPT_DIR/README.md"
    
    chmod 644 "$SCRIPT_DIR/README.md"
    
    # 3. Generate QUICK_REFERENCE.md
    cat > "$docs_dir/QUICK_REFERENCE.md" << 'QUICKREF_EOF'
# Quick Reference

**Your Service Names:**
- **Main Server:** `${SERVICE_NAME}.service`
- **Monitoring:** `${MONITORS_SERVICE_NAME}.service`
- **Screen Session:** `${SCREEN_NAME}`

---

## Command Cheat Sheet

### Service Management

```bash
# Start/Stop/Restart Server
sudo systemctl start ${SERVICE_NAME}.service
sudo systemctl stop ${SERVICE_NAME}.service
sudo systemctl restart ${SERVICE_NAME}.service
sudo systemctl status ${SERVICE_NAME}.service

# Start/Stop/Restart Monitoring
sudo systemctl start ${MONITORS_SERVICE_NAME}.service
sudo systemctl stop ${MONITORS_SERVICE_NAME}.service
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
sudo systemctl status ${MONITORS_SERVICE_NAME}.service

# Enable/Disable Auto-Start on Boot
sudo systemctl enable ${SERVICE_NAME}.service
sudo systemctl disable ${SERVICE_NAME}.service
sudo systemctl enable ${MONITORS_SERVICE_NAME}.service
sudo systemctl disable ${MONITORS_SERVICE_NAME}.service
```

### Screen Session

```bash
# Attach to server console
screen -r ${SCREEN_NAME}

# Detach from screen (while inside)
# Press: Ctrl+A, then D

# List all screen sessions
screen -ls

# Kill stuck screen session (if needed)
screen -S ${SCREEN_NAME} -X quit
```

### Logs

```bash
# Monitoring logs (live tail)
tail -f ${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log

# Monitoring logs (last 50 lines)
tail -50 ${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log

# Server logs (live tail)
tail -f ${SERVER_DIR}/logs/latest.log

# Server logs (last 100 lines)
tail -100 ${SERVER_DIR}/logs/latest.log

# Systemd journal (live)
journalctl -u ${SERVICE_NAME}.service -f
journalctl -u ${MONITORS_SERVICE_NAME}.service -f

# Systemd journal (last 50 lines)
journalctl -u ${SERVICE_NAME}.service -n 50
journalctl -u ${MONITORS_SERVICE_NAME}.service -n 50
```

---

## Current Configuration

**Vote Restart:**
- Threshold: **${VOTE_PERCENTAGE}%** of online players
- Cooldown: **10 minutes** between manual restarts
- Command: Players type `!restart` in chat

**TPS Auto-Restart:**
- Threshold: TPS < **${TPS_THRESHOLD}**
- Check frequency: Every **60 seconds** (7 checks per cycle)
- Trigger: **5 out of 7** checks must be low
- Cooldown: **1 hour** between automatic restarts

**Logging:**
- Level: **INFO** (DEBUG/INFO/WARN/ERROR)
- Location: `${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log`

---

## File Paths

```bash
# Configuration
${SERVER_DIR}/minecraft_scripts/lib/common_functions.sh

# Monitoring Scripts
${SERVER_DIR}/minecraft_scripts/gtnh_master_monitor.sh
${SERVER_DIR}/minecraft_scripts/start_monitors.sh
${SERVER_DIR}/minecraft_scripts/lib/vote_functions.sh
${SERVER_DIR}/minecraft_scripts/lib/tps_functions.sh
${SERVER_DIR}/minecraft_scripts/lib/restart_functions.sh

# Logs
${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log
${SERVER_DIR}/logs/latest.log

# State Files (cooldowns, vote tracking)
${SERVER_DIR}/minecraft_scripts/restart_state/last_any_restart
${SERVER_DIR}/minecraft_scripts/restart_state/last_vote_restart
${SERVER_DIR}/minecraft_scripts/restart_state/last_tps_restart
${SERVER_DIR}/minecraft_scripts/restart_state/current_votes.txt
${SERVER_DIR}/minecraft_scripts/restart_state/acknowledged_players.txt
${SERVER_DIR}/minecraft_scripts/restart_state/last_line.txt

# Systemd Services
/etc/systemd/system/${SERVICE_NAME}.service
/etc/systemd/system/${MONITORS_SERVICE_NAME}.service

# Sudoers
/etc/sudoers.d/gtnh-restart

# Documentation
${SERVER_DIR}/minecraft_scripts/README.md
${SERVER_DIR}/minecraft_scripts/.service_info
${SERVER_DIR}/minecraft_scripts/docs/QUICK_REFERENCE.md (this file)
${SERVER_DIR}/minecraft_scripts/docs/CONFIGURATION.md
${SERVER_DIR}/minecraft_scripts/docs/TROUBLESHOOTING.md
${SERVER_DIR}/minecraft_scripts/docs/ARCHITECTURE.md
```

---

## Manual Operations

### Manually Reset Cooldowns

```bash
# Reset all cooldowns
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_*_restart

# Reset only vote cooldown
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_vote_restart

# Reset only TPS cooldown
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_tps_restart

# Then restart monitoring
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
```

### Clear Pending Votes

```bash
# Clear all votes
rm ${SERVER_DIR}/minecraft_scripts/restart_state/current_votes.txt
rm ${SERVER_DIR}/minecraft_scripts/restart_state/acknowledged_players.txt
```

### Check Cooldown Status

```bash
# View last restart timestamps
ls -lh ${SERVER_DIR}/minecraft_scripts/restart_state/last_*_restart
cat ${SERVER_DIR}/minecraft_scripts/restart_state/last_any_restart
cat ${SERVER_DIR}/minecraft_scripts/restart_state/last_vote_restart
cat ${SERVER_DIR}/minecraft_scripts/restart_state/last_tps_restart
```

---

## In-Game Commands

Players can use these commands in Minecraft chat:

```
!restart    - Vote for server restart
/forge tps  - Check server TPS (ops only)
```

---

For detailed configuration and troubleshooting, see:
- `../README.md` - Main documentation
- `CONFIGURATION.md` - How to adjust settings
- `TROUBLESHOOTING.md` - Common issues & solutions
- `ARCHITECTURE.md` - System design & internals
QUICKREF_EOF

    # Substitute variables
    sed -i "s|\${SERVICE_NAME}|${SERVICE_NAME}|g" "$docs_dir/QUICK_REFERENCE.md"
    sed -i "s|\${MONITORS_SERVICE_NAME}|${MONITORS_SERVICE_NAME}|g" "$docs_dir/QUICK_REFERENCE.md"
    sed -i "s|\${SCREEN_NAME}|${SCREEN_NAME}|g" "$docs_dir/QUICK_REFERENCE.md"
    sed -i "s|\${SERVER_DIR}|${SERVER_DIR}|g" "$docs_dir/QUICK_REFERENCE.md"
    sed -i "s|\${VOTE_PERCENTAGE}|${VOTE_PERCENTAGE}|g" "$docs_dir/QUICK_REFERENCE.md"
    sed -i "s|\${TPS_THRESHOLD}|${TPS_THRESHOLD}|g" "$docs_dir/QUICK_REFERENCE.md"
    
    chmod 644 "$docs_dir/QUICK_REFERENCE.md"
    
    log_info "Generated README.md and QUICK_REFERENCE.md"
    
    # 4. Generate CONFIGURATION.md
    cat > "$docs_dir/CONFIGURATION.md" << 'CONFIG_EOF'
# Configuration Guide

All configuration is centralized in:

```bash
${SERVER_DIR}/minecraft_scripts/lib/common_functions.sh
```

**After making any changes, restart the monitoring service:**

```bash
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
```

---

## Configurable Variables

### Vote Restart Settings

```bash
# Vote threshold (percentage of online players required)
VOTE_PERCENTAGE=60

# Minimum time between vote-initiated restarts (seconds)
MIN_VOTE_INTERVAL=600  # 10 minutes

# How often to check for new votes (seconds)
CHECK_VOTE_INTERVAL=10  # Check every 10 seconds
```

**Example:** With `VOTE_PERCENTAGE=60` and 5 players online, 3 players (60%) must vote.

---

### TPS Auto-Restart Settings

```bash
# TPS threshold for triggering restart
TPS_THRESHOLD=19.0

# How often to run TPS check cycles (seconds)
TPS_CHECK_CYCLE_INTERVAL=60  # Check every 60 seconds

# Number of checks per cycle
TPS_REQUIRED_BAD_CHECKS=7

# How many bad checks trigger restart
TPS_BAD_THRESHOLD=5  # 5 out of 7 checks

# Cooldown between automatic TPS restarts (seconds)
TPS_RESTART_COOLDOWN=3600  # 1 hour
```

**Example:** Every minute, check TPS 7 times. If 5/7 checks show TPS < 19.0, restart (if not on cooldown).

---

### Global Cooldown Settings

```bash
# Minimum time between ANY restarts (manual or auto)
GLOBAL_RESTART_COOLDOWN=600  # 10 minutes
```

**How Cooldowns Work:**

1. **Global Cooldown (10 min):** Prevents ANY restart within 10 minutes of the last restart
2. **Vote Cooldown (10 min):** Prevents vote-based restarts within 10 minutes
3. **TPS Cooldown (1 hour):** Prevents TPS-based restarts within 1 hour

When a manual vote restart happens:
- Global cooldown resets to 10 minutes
- Vote cooldown resets to 10 minutes  
- TPS cooldown resets to 1 hour

This means after a vote restart, players can vote again in 10 minutes, but TPS auto-restart won't happen for 1 hour.

---

### Logging Settings

```bash
# Log level: DEBUG, INFO, WARN, ERROR
LOG_LEVEL="INFO"
```

**Log Levels:**
- `DEBUG` - Very verbose (shows TPS readings, vote checks, every operation)
- `INFO` - Normal verbosity (shows important events, countdowns)
- `WARN` - Warnings only (cooldown blocks, parsing errors)
- `ERROR` - Errors only (critical failures)

**Recommendation:**
- Use `INFO` for normal operation
- Use `DEBUG` when troubleshooting TPS detection or vote issues
- Use `WARN` or `ERROR` for production with minimal logging

---

### Server Paths

```bash
# Server directory
SERVER_DIR="${SERVER_DIR}"

# Screen session name
SCREEN_NAME="${SCREEN_NAME}"

# Systemd service name (for restart commands)
SERVICE_NAME="${SERVICE_NAME}"
```

**Note:** These are set during installation and should match your systemd services.

---

## How to Change Settings

### Example 1: Change Vote Threshold to 75%

1. Edit the file:
   ```bash
   nano ${SERVER_DIR}/minecraft_scripts/lib/common_functions.sh
   ```

2. Find and change:
   ```bash
   VOTE_PERCENTAGE=60
   ```
   to:
   ```bash
   VOTE_PERCENTAGE=75
   ```

3. Save and exit (`Ctrl+X`, then `Y`, then `Enter`)

4. Restart monitoring:
   ```bash
   sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
   ```

---

### Example 2: Make TPS Restart More Sensitive

To restart at TPS < 18.0 instead of 19.0:

1. Edit:
   ```bash
   nano ${SERVER_DIR}/minecraft_scripts/lib/common_functions.sh
   ```

2. Change:
   ```bash
   TPS_THRESHOLD=19.0
   ```
   to:
   ```bash
   TPS_THRESHOLD=18.0
   ```

3. Restart monitoring:
   ```bash
   sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
   ```

---

### Example 3: Enable Debug Logging

For troubleshooting TPS detection issues:

1. Edit:
   ```bash
   nano ${SERVER_DIR}/minecraft_scripts/lib/common_functions.sh
   ```

2. Change:
   ```bash
   LOG_LEVEL="INFO"
   ```
   to:
   ```bash
   LOG_LEVEL="DEBUG"
   ```

3. Restart monitoring:
   ```bash
   sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
   ```

4. Watch detailed logs:
   ```bash
   tail -f ${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log
   ```

**Remember to change back to `INFO` once debugging is done to reduce log spam.**

---

### Example 4: Reduce TPS Restart Cooldown to 30 Minutes

1. Edit:
   ```bash
   nano ${SERVER_DIR}/minecraft_scripts/lib/common_functions.sh
   ```

2. Change:
   ```bash
   TPS_RESTART_COOLDOWN=3600  # 1 hour
   ```
   to:
   ```bash
   TPS_RESTART_COOLDOWN=1800  # 30 minutes
   ```

3. Restart monitoring:
   ```bash
   sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
   ```

---

## Manual Cooldown Reset

If you need to bypass cooldowns (e.g., after fixing a server issue):

```bash
# Reset all cooldowns
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_*_restart

# Or reset individually:
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_vote_restart  # Vote cooldown
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_tps_restart   # TPS cooldown
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_any_restart   # Global cooldown

# Then restart monitoring
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
```

---

## State Files

The system tracks state in:

```bash
${SERVER_DIR}/minecraft_scripts/restart_state/
```

**Files:**
- `last_any_restart` - Timestamp of last restart (any type)
- `last_vote_restart` - Timestamp of last vote restart
- `last_tps_restart` - Timestamp of last TPS restart
- `current_votes.txt` - Current player votes
- `acknowledged_players.txt` - Players who have been notified
- `last_line.txt` - Last processed log line (for vote detection)

**These files are managed automatically.** Only delete them if you need to reset cooldowns or clear votes.

---

## Advanced: Countdown Customization

Countdown timings are in:

```bash
${SERVER_DIR}/minecraft_scripts/lib/restart_functions.sh
```

**Vote Restart Countdown:** 30 seconds (announcements at 30, 20, 10, 5, 4, 3, 2, 1)

**TPS Restart Countdown:** 3 minutes (announcements at 180, 60, 30, 20, 10, 5, 4, 3, 2, 1)

Edit the `do_vote_restart()` and `do_tps_restart()` functions to customize countdown intervals.

---

For more information, see:
- `../README.md` - Main documentation
- `QUICK_REFERENCE.md` - Command cheat sheet
- `TROUBLESHOOTING.md` - Common issues
- `ARCHITECTURE.md` - System design
CONFIG_EOF

    # Substitute variables
    sed -i "s|\${SERVER_DIR}|${SERVER_DIR}|g" "$docs_dir/CONFIGURATION.md"
    sed -i "s|\${MONITORS_SERVICE_NAME}|${MONITORS_SERVICE_NAME}|g" "$docs_dir/CONFIGURATION.md"
    sed -i "s|\${SCREEN_NAME}|${SCREEN_NAME}|g" "$docs_dir/CONFIGURATION.md"
    sed -i "s|\${SERVICE_NAME}|${SERVICE_NAME}|g" "$docs_dir/CONFIGURATION.md"
    
    chmod 644 "$docs_dir/CONFIGURATION.md"
    
    # 5. Generate TROUBLESHOOTING.md
    cat > "$docs_dir/TROUBLESHOOTING.md" << 'TROUBLE_EOF'
# Troubleshooting Guide

This guide covers common issues and their solutions.

---

## Server Won't Start

### Check if systemd service is running

```bash
sudo systemctl status ${SERVICE_NAME}.service
```

**If inactive:**
```bash
sudo systemctl start ${SERVICE_NAME}.service
```

### Check if screen session exists

```bash
screen -ls
```

**If no session named `${SCREEN_NAME}`:**
- The server may have crashed during startup
- Check server logs for errors

### Check server logs

```bash
tail -50 ${SERVER_DIR}/logs/latest.log
```

**Common issues:**
- `EULA not accepted` → Edit `${SERVER_DIR}/eula.txt` and set `eula=true`
- `Port already in use` → Another server is running on port 25565
- `OutOfMemoryError` → Increase RAM in `${SERVER_DIR}/startserver.sh`

### Check if Java is available

```bash
java -version
```

**If not found:**
```bash
sudo apt update && sudo apt install openjdk-17-jre
```

---

## Monitoring Service Won't Start

### Check monitoring service status

```bash
sudo systemctl status ${MONITORS_SERVICE_NAME}.service
```

### Check monitoring logs

```bash
tail -50 ${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log
```

### Restart monitoring

```bash
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
```

### Verify scripts exist and are executable

```bash
ls -lh ${SERVER_DIR}/minecraft_scripts/gtnh_master_monitor.sh
ls -lh ${SERVER_DIR}/minecraft_scripts/start_monitors.sh
```

**If not executable:**
```bash
chmod +x ${SERVER_DIR}/minecraft_scripts/*.sh
chmod +x ${SERVER_DIR}/minecraft_scripts/lib/*.sh
```

---

## Votes Not Registering

### Check if monitoring is running

```bash
sudo systemctl status ${MONITORS_SERVICE_NAME}.service
```

### Check monitoring logs for vote detection

```bash
tail -f ${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log
```

Type `!restart` in-game and watch the logs. You should see:
```
Vote command detected, processing...
New votes from: PlayerName
Vote count: X/Y
```

### Common Issues

**1. Vote on cooldown**

If you see `Vote restart on cooldown`, wait for the cooldown to expire (10 minutes after last vote restart).

Check remaining cooldown:
```bash
# View last restart time
cat ${SERVER_DIR}/minecraft_scripts/restart_state/last_vote_restart

# Current time (Unix timestamp)
date +%s

# Calculate difference
```

**Manually reset cooldown:**
```bash
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_vote_restart
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
```

**2. Global restart cooldown**

If you see `Vote blocked by global cooldown`, any restart (vote or TPS) happened recently.

**Manually reset:**
```bash
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_any_restart
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
```

**3. Not enough players voted**

Example: 2 players online, vote threshold is 60%, so 1.2 → rounds to 2 players needed.

Check current votes:
```bash
cat ${SERVER_DIR}/minecraft_scripts/restart_state/current_votes.txt
```

**4. Monitoring script not running**

```bash
sudo systemctl start ${MONITORS_SERVICE_NAME}.service
```

---

## TPS Monitor Not Detecting Low TPS

### Verify `/forge tps` command works

1. Attach to server console:
   ```bash
   screen -r ${SCREEN_NAME}
   ```

2. Run command:
   ```
   /forge tps
   ```

3. You should see output like:
   ```
   Dim 0 : Mean tick time: 5.234 ms. Mean TPS: 19.105
   Dim -1 : Mean tick time: 0.012 ms. Mean TPS: 20.000
   Overall : Mean tick time: 6.789 ms. Mean TPS: 18.234
   ```

4. Detach: `Ctrl+A`, then `D`

### Enable debug logging

1. Edit config:
   ```bash
   nano ${SERVER_DIR}/minecraft_scripts/lib/common_functions.sh
   ```

2. Change to:
   ```bash
   LOG_LEVEL="DEBUG"
   ```

3. Restart monitoring:
   ```bash
   sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
   ```

4. Watch logs:
   ```bash
   tail -f ${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log
   ```

You should see:
```
[DEBUG] Forge TPS: X dimensions checked, lowest: 19.123
[INFO] Current TPS: 19.123
[INFO] Check 1/7: TPS=19.123 [OK]
```

### Common Issues

**1. "Could not parse /forge tps output"**

The TPS monitor sends `/forge tps` to the server and parses the output from logs.

**Check:**
- Is Forge installed? (GTNH uses Forge)
- Does `/forge tps` work when run manually?
- Check server logs: `tail -50 ${SERVER_DIR}/logs/latest.log | grep "Mean TPS"`

**2. TPS shows 20.0 but server is laggy**

- The monitor checks TPS every 60 seconds in 7-check cycles
- Lag spikes between checks may not be detected
- Consider reducing `TPS_CHECK_CYCLE_INTERVAL` (see `CONFIGURATION.md`)

**3. TPS restart on cooldown**

Auto TPS restarts have a 1-hour cooldown. Check logs:
```
TPS restart blocked by cooldown (XXXs remaining)
```

**Manually reset:**
```bash
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_tps_restart
rm ${SERVER_DIR}/minecraft_scripts/restart_state/last_any_restart
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service
```

---

## "Restart Blocked" Messages Spamming Chat

This happens when votes reach threshold but are blocked by cooldown.

**Fixed in current version:** The system now clears votes before announcing, preventing spam.

**If still occurring:**
1. Check you're running the latest scripts
2. Manually clear votes:
   ```bash
   rm ${SERVER_DIR}/minecraft_scripts/restart_state/current_votes.txt
   rm ${SERVER_DIR}/minecraft_scripts/restart_state/acknowledged_players.txt
   ```

---

## Permission Denied Errors

### When restarting services

**Error:** `sudo: no tty present and no askpass program specified`

**Cause:** Sudoers not configured for passwordless restarts.

**Fix:**
```bash
# Check sudoers file exists
ls -l /etc/sudoers.d/gtnh-restart

# If missing, recreate:
sudo ${SERVER_DIR}/minecraft_scripts/setup.sh
# (Run installer again, it will detect existing setup)
```

### When accessing screen session

**Error:** `Cannot open your terminal '/dev/pts/X'`

**Fix:**
```bash
# Make your terminal accessible
script /dev/null
screen -r ${SCREEN_NAME}
```

---

## Multiple Servers Conflict

If running multiple GTNH servers, services may conflict.

**Check service names:**
```bash
systemctl list-units | grep gtnh
```

Each server should have unique service names:
- `gtnh-server1.service`
- `gtnh-server2.service`
- `gtnh-server1-monitors.service`
- `gtnh-server2-monitors.service`

**If conflicting:**
1. Stop all services
2. Re-run `setup.sh` in each server directory
3. Installer will generate unique names based on folder name

---

## Screen Session Not Found

```bash
screen -ls
```

**If `${SCREEN_NAME}` is not listed:**

1. Check if server service is running:
   ```bash
   sudo systemctl status ${SERVICE_NAME}.service
   ```

2. If inactive, start it:
   ```bash
   sudo systemctl start ${SERVICE_NAME}.service
   ```

3. If active but no screen session:
   - Server may have crashed
   - Check logs: `tail -50 ${SERVER_DIR}/logs/latest.log`

---

## Logs Not Updating

### Monitoring logs not updating

```bash
# Check if monitoring is running
sudo systemctl status ${MONITORS_SERVICE_NAME}.service

# Restart monitoring
sudo systemctl restart ${MONITORS_SERVICE_NAME}.service

# Watch logs
tail -f ${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log
```

### Server logs not updating

```bash
# Check if server is running
sudo systemctl status ${SERVICE_NAME}.service

# Check screen session
screen -ls

# Attach to console
screen -r ${SCREEN_NAME}
```

---

## Emergency: Server Stuck / Won't Respond

### Forcefully stop server

```bash
# Try graceful stop first
sudo systemctl stop ${SERVICE_NAME}.service

# If that doesn't work after 30 seconds, kill screen session
screen -S ${SCREEN_NAME} -X quit

# If still running, find and kill Java process
ps aux | grep java
sudo kill -9 <PID>
```

### Restart server

```bash
sudo systemctl start ${SERVICE_NAME}.service
```

---

## Check Overall System Health

```bash
# Check all services
sudo systemctl status ${SERVICE_NAME}.service
sudo systemctl status ${MONITORS_SERVICE_NAME}.service

# Check logs
tail -50 ${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log
tail -50 ${SERVER_DIR}/logs/latest.log

# Check screen session
screen -ls

# Check cooldown status
ls -lh ${SERVER_DIR}/minecraft_scripts/restart_state/
```

---

## Getting Help

If you're still stuck:

1. **Gather information:**
   ```bash
   # Service status
   sudo systemctl status ${SERVICE_NAME}.service
   sudo systemctl status ${MONITORS_SERVICE_NAME}.service
   
   # Recent logs
   tail -100 ${SERVER_DIR}/minecraft_scripts/logs/master_monitor.log > ~/debug_monitor.log
   tail -100 ${SERVER_DIR}/logs/latest.log > ~/debug_server.log
   
   # Configuration
   cat ${SERVER_DIR}/minecraft_scripts/lib/common_functions.sh > ~/debug_config.txt
   ```

2. **Review documentation:**
   - `../README.md` - Main documentation
   - `CONFIGURATION.md` - Configuration options
   - `ARCHITECTURE.md` - How the system works

3. **Check state files:**
   ```bash
   ls -lh ${SERVER_DIR}/minecraft_scripts/restart_state/
   ```

For more information, see the other documentation files in `${SERVER_DIR}/minecraft_scripts/docs/`.
TROUBLE_EOF

    # Substitute variables
    sed -i "s|\${SERVICE_NAME}|${SERVICE_NAME}|g" "$docs_dir/TROUBLESHOOTING.md"
    sed -i "s|\${MONITORS_SERVICE_NAME}|${MONITORS_SERVICE_NAME}|g" "$docs_dir/TROUBLESHOOTING.md"
    sed -i "s|\${SCREEN_NAME}|${SCREEN_NAME}|g" "$docs_dir/TROUBLESHOOTING.md"
    sed -i "s|\${SERVER_DIR}|${SERVER_DIR}|g" "$docs_dir/TROUBLESHOOTING.md"
    
    chmod 644 "$docs_dir/TROUBLESHOOTING.md"
    
    # 6. Generate ARCHITECTURE.md
    cat > "$docs_dir/ARCHITECTURE.md" << 'ARCH_EOF'
# System Architecture

This document explains how the GTNH monitoring system works internally.

---

## Overview

The monitoring system consists of:

1. **Systemd Services** - Manage server and monitoring processes
2. **Screen Session** - Runs Minecraft server in detachable console
3. **Monitoring Scripts** - Modular bash scripts for vote and TPS monitoring
4. **State Files** - Track cooldowns and votes
5. **Log Parsing** - Detect player votes and TPS values

---

## Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│  Systemd: ${SERVICE_NAME}.service                         │
│  ├─ Starts screen session: ${SCREEN_NAME}                │
│  ├─ Runs: startserver.sh                                │
│  └─ Minecraft Server (Java process)                     │
└─────────────────────────────────────────────────────────┘
                      ↕ (monitors logs)
┌─────────────────────────────────────────────────────────┐
│  Systemd: ${MONITORS_SERVICE_NAME}.service                │
│  └─ start_monitors.sh                                   │
│     └─ gtnh_master_monitor.sh (main loop)               │
│        ├─ lib/common_functions.sh (config & utils)      │
│        ├─ lib/vote_functions.sh (vote detection)        │
│        ├─ lib/tps_functions.sh (TPS monitoring)         │
│        └─ lib/restart_functions.sh (countdown & restart)│
└─────────────────────────────────────────────────────────┘
                      ↕ (triggers restart)
┌─────────────────────────────────────────────────────────┐
│  systemctl restart ${SERVICE_NAME}.service                │
│  (via sudoers: passwordless restart)                    │
└─────────────────────────────────────────────────────────┘
```

---

## Module Breakdown

### 1. gtnh_master_monitor.sh

**Purpose:** Main orchestrator, runs monitoring loop

**Logic:**
```bash
while true; do
    # Every 10 seconds: Check for vote commands
    check_for_votes()
    
    # Every 60 seconds: Run TPS check cycle (7 checks)
    if (60 seconds elapsed); then
        run_tps_check_cycle()
    fi
    
    sleep 10
done
```

**Responsibilities:**
- Source all library modules
- Run main monitoring loop
- Call vote and TPS checking functions
- Coordinate timing (10s vote checks, 60s TPS cycles)

---

### 2. lib/common_functions.sh

**Purpose:** Centralized configuration and utility functions

**Key Variables:**
- `VOTE_PERCENTAGE` - Vote threshold (default: 60%)
- `TPS_THRESHOLD` - TPS restart threshold (default: 19.0)
- `GLOBAL_RESTART_COOLDOWN` - Global cooldown (default: 600s = 10 min)
- `TPS_RESTART_COOLDOWN` - TPS cooldown (default: 3600s = 1 hour)
- `MIN_VOTE_INTERVAL` - Vote cooldown (default: 600s = 10 min)
- `LOG_LEVEL` - Verbosity: DEBUG/INFO/WARN/ERROR

**Key Functions:**
- `log_message()` - Timestamped logging with level filtering
- `send_server_command()` - Send command to Minecraft via screen
- `send_server_message()` - Send message to all players
- `get_timestamp()` - Get current Unix timestamp
- `can_restart()` - Check if restart is allowed (cooldown check)
- `get_cooldown_remaining()` - Get remaining cooldown time
- `format_time_remaining()` - Format seconds as "Xm Ys"

---

### 3. lib/vote_functions.sh

**Purpose:** Detect and process player vote commands

**Flow:**

```
1. check_for_votes()
   ↓
2. Parse server log for "!restart" commands
   ↓
3. Extract player names from log lines
   ↓
4. Track unique voters (avoid duplicates)
   ↓
5. Count votes, calculate threshold (X% of online players)
   ↓
6. Check if threshold reached
   ↓
7. Check vote cooldown (10 min since last vote restart)
   ↓
8. Check global cooldown (10 min since ANY restart)
   ↓
9. If all checks pass → do_vote_restart()
   ↓
10. Otherwise → send cooldown message to players
```

**Key Functions:**
- `check_for_votes()` - Main vote detection loop
- `can_vote_restart()` - Check vote-specific cooldown

**State Files:**
- `current_votes.txt` - List of players who voted
- `acknowledged_players.txt` - Players who've been notified
- `last_line.txt` - Last processed log line (avoid re-processing)
- `last_vote_restart` - Timestamp of last vote restart
- `last_any_restart` - Timestamp of last restart (any type)

---

### 4. lib/tps_functions.sh

**Purpose:** Monitor server TPS and trigger automatic restarts

**Flow:**

```
1. run_tps_check_cycle()  (triggered every 60 seconds)
   ↓
2. Loop 7 times (3 seconds apart):
   ├─ Send "/forge tps" command to server
   ├─ Parse log for "Mean TPS: X.XXX" from all dimensions
   ├─ Find lowest TPS across all dimensions
   └─ Compare to TPS_THRESHOLD (19.0)
   ↓
3. If 5+ out of 7 checks show low TPS:
   ↓
4. Check TPS cooldown (1 hour since last TPS restart)
   ↓
5. Check global cooldown (10 min since ANY restart)
   ↓
6. If all checks pass → do_tps_restart()
   ↓
7. Otherwise → log cooldown block (not announced in chat)
```

**Key Functions:**
- `run_tps_check_cycle()` - Run 7 TPS checks
- `get_current_tps()` - Send `/forge tps` and parse output
- `can_tps_restart()` - Check TPS-specific cooldown

**TPS Parsing:**
```bash
# Send command
screen -p 0 -S ${SCREEN_NAME} -X stuff "forge tps\015"

# Wait for output
sleep 2

# Parse log
tail -n 50 server.log | grep "Mean TPS:" | grep -oP 'Mean TPS:\s*\K[0-9]+\.?[0-9]*'

# Find lowest TPS
sort -n | head -1
```

**State Files:**
- `last_tps_restart` - Timestamp of last TPS restart
- `last_any_restart` - Timestamp of last restart (any type)

---

### 5. lib/restart_functions.sh

**Purpose:** Execute restart countdowns and trigger systemd restart

**Functions:**

**do_vote_restart():**
```
1. Check can_restart() (global cooldown)
   ↓
2. Announce: "Server restarting in 30 seconds..."
   ↓
3. Countdown: 30, 20, 10, 5, 4, 3, 2, 1
   ↓
4. Mark restart timestamp (vote)
   ↓
5. Trigger: sudo systemctl restart ${SERVICE_NAME}.service
```

**do_tps_restart():**
```
1. Check can_restart(TPS_RESTART_COOLDOWN) (1 hour cooldown)
   ↓
2. Announce: "[AUTO-RESTART] Low TPS detected! Restarting in 3 minutes..."
   ↓
3. Countdown: 180 (3m), 60 (1m), 30, 20, 10, 5, 4, 3, 2, 1
   ↓
4. Mark restart timestamp (tps)
   ↓
5. Trigger: sudo systemctl restart ${SERVICE_NAME}.service
```

**Key Functions:**
- `do_vote_restart()` - 30-second countdown, systemd restart
- `do_tps_restart()` - 3-minute countdown, systemd restart
- `trigger_systemd_restart()` - Execute systemd restart command

---

## Cooldown System

### Three Types of Cooldowns

1. **Global Cooldown (10 minutes):**
   - Prevents ANY restart within 10 minutes of last restart
   - File: `restart_state/last_any_restart`
   - Checked by: `can_restart()`

2. **Vote Cooldown (10 minutes):**
   - Prevents vote-based restarts within 10 minutes
   - File: `restart_state/last_vote_restart`
   - Checked by: `can_vote_restart()`

3. **TPS Cooldown (1 hour):**
   - Prevents TPS-based restarts within 1 hour
   - File: `restart_state/last_tps_restart`
   - Checked by: `can_restart(TPS_RESTART_COOLDOWN)`

### Cooldown Logic

```bash
can_restart() {
    local period_override="$1"
    local cooldown_period=${period_override:-$GLOBAL_RESTART_COOLDOWN}
    
    # Read last restart timestamp
    last_restart=$(cat restart_state/last_any_restart)
    current_time=$(date +%s)
    elapsed=$((current_time - last_restart))
    
    # Check if enough time has passed
    if [ $elapsed -ge $cooldown_period ]; then
        return 0  # Can restart
    else
        return 1  # On cooldown
    fi
}
```

### When Restarts Reset Cooldowns

**Vote Restart:**
- Resets `last_any_restart` → 10 min global cooldown
- Resets `last_vote_restart` → 10 min vote cooldown
- Resets TPS cooldown to 1 hour (via global reset)

**TPS Restart:**
- Resets `last_any_restart` → 10 min global cooldown
- Resets `last_tps_restart` → 1 hour TPS cooldown
- Players can still vote after 10 min (vote cooldown not affected)

---

## Priority System

**Vote Restarts > TPS Restarts**

If both want to restart simultaneously:
1. Vote restart executes immediately (if not on cooldown)
2. TPS restart waits for next cycle

**Implementation:**
- Vote and TPS checks run independently
- Both check global cooldown before restarting
- Whichever triggers first sets `last_any_restart`, blocking the other

---

## Log Parsing

### Vote Detection

**Target:** Server chat log (`logs/latest.log`)

**Pattern:**
```
[HH:MM:SS] [Server thread/INFO]: <PlayerName> !restart
```

**Logic:**
```bash
# Get new log lines since last check
tail -n +${LAST_LINE} logs/latest.log

# Find "!restart" commands
grep "!restart"

# Extract player names
grep -oP '<\K[^>]+(?=>.*!restart)'

# Store unique voters
echo "PlayerName" >> current_votes.txt
sort -u current_votes.txt -o current_votes.txt
```

### TPS Detection

**Target:** Server log (`logs/latest.log`)

**Command:** `/forge tps` sent via screen

**Output Example:**
```
[HH:MM:SS] [Server thread/INFO]: Dim 0 : Mean tick time: 8.234 ms. Mean TPS: 18.123
[HH:MM:SS] [Server thread/INFO]: Dim -1 : Mean tick time: 0.012 ms. Mean TPS: 20.000
[HH:MM:SS] [Server thread/INFO]: Overall : Mean tick time: 9.456 ms. Mean TPS: 17.890
```

**Logic:**
```bash
# Send command
screen -p 0 -S gtnh-server -X stuff "forge tps\015"

# Wait for output
sleep 2

# Parse all dimension TPS values
tail -n 50 logs/latest.log | grep "Mean TPS:" | grep -oP 'Mean TPS:\s*\K[0-9]+\.?[0-9]*'

# Find lowest TPS (worst-performing dimension)
sort -n | head -1
```

---

## Systemd Integration

### Server Service: ${SERVICE_NAME}.service

```ini
[Unit]
Description=GTNH Minecraft Server
After=network.target

[Service]
Type=forking
User=${REAL_USER}
WorkingDirectory=${SERVER_DIR}

# Start server in screen session
ExecStart=/usr/bin/screen -dmS ${SCREEN_NAME} ${SERVER_DIR}/startserver.sh

# Stop server gracefully
ExecStop=/usr/bin/screen -p 0 -S ${SCREEN_NAME} -X eval 'stuff "stop\\015"'
ExecStop=/bin/sleep 30

# Restart policy
Restart=on-failure
RestartSec=60s

[Install]
WantedBy=multi-user.target
```

**Key Points:**
- `Type=forking` - Screen detaches, service continues
- `ExecStop` sends `stop` command, waits 30s for graceful shutdown
- `Restart=on-failure` - Auto-restart if server crashes

### Monitoring Service: ${MONITORS_SERVICE_NAME}.service

```ini
[Unit]
Description=GTNH Server Monitoring (Vote & TPS Restarts)
After=${SERVICE_NAME}.service
Requires=${SERVICE_NAME}.service

[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${SERVER_DIR}/minecraft_scripts

ExecStart=${SERVER_DIR}/minecraft_scripts/start_monitors.sh

# Restart policy
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
```

**Key Points:**
- `After` - Starts after server service
- `Requires` - Stops if server service stops
- `Restart=always` - Auto-restart if monitoring crashes
- Runs `start_monitors.sh` → `gtnh_master_monitor.sh`

---

## State File System

**Location:** `${SERVER_DIR}/minecraft_scripts/restart_state/`

| File | Purpose | Format |
|------|---------|--------|
| `last_any_restart` | Timestamp of last restart (any type) | Unix timestamp |
| `last_vote_restart` | Timestamp of last vote restart | Unix timestamp |
| `last_tps_restart` | Timestamp of last TPS restart | Unix timestamp |
| `current_votes.txt` | Players who voted | One player name per line |
| `acknowledged_players.txt` | Players notified about their vote | One player name per line |
| `last_line.txt` | Last processed log line number | Integer |

**Lifecycle:**

**Restart Timestamps:**
- Created/updated when restart occurs
- Read to check cooldowns
- Deleted to manually reset cooldowns

**Vote Files:**
- Created when first vote detected
- Updated as more players vote
- Deleted when vote restart executes or is blocked

**last_line.txt:**
- Tracks position in server log
- Prevents re-processing old votes
- Deleted when log file rotates

---

## Sudoers Configuration

**File:** `/etc/sudoers.d/gtnh-restart`

**Content:**
```bash
${REAL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ${SERVICE_NAME}.service
${REAL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ${MONITORS_SERVICE_NAME}.service
${REAL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop ${SERVICE_NAME}.service
${REAL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop ${MONITORS_SERVICE_NAME}.service
${REAL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl start ${SERVICE_NAME}.service
${REAL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl start ${MONITORS_SERVICE_NAME}.service
${REAL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl status ${SERVICE_NAME}.service
${REAL_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl status ${MONITORS_SERVICE_NAME}.service
```

**Purpose:**
- Allows monitoring scripts to restart server without password
- Monitoring runs as regular user (${REAL_USER})
- `systemctl restart` requires root, but sudoers grants exception

**Security:**
- Only specific systemctl commands allowed
- Only for specific services
- Only for specific user

---

## Data Flow Examples

### Example 1: Vote Restart

```
1. Player types "!restart" in-game
   ↓
2. Minecraft server logs: "<PlayerName> !restart"
   ↓
3. gtnh_master_monitor.sh (every 10s)
   └─ check_for_votes() (vote_functions.sh)
      ├─ Parse log for "!restart"
      ├─ Extract "PlayerName"
      ├─ Add to current_votes.txt (if new)
      └─ Count votes: 2/3 players (67%)
   ↓
4. Threshold reached (60% needed, 67% achieved)
   ↓
5. Check can_vote_restart()
   └─ last_vote_restart: 700 seconds ago (> 600s) ✓
   ↓
6. Check can_restart()
   └─ last_any_restart: 650 seconds ago (> 600s) ✓
   ↓
7. do_vote_restart() (restart_functions.sh)
   ├─ Announce: "Vote passed! Server restarting..."
   ├─ Countdown: 30, 20, 10, 5, 4, 3, 2, 1
   ├─ mark_restart("vote")
   │  ├─ Write timestamp to last_vote_restart
   │  └─ Write timestamp to last_any_restart
   └─ sudo systemctl restart ${SERVICE_NAME}.service
   ↓
8. Systemd restarts server service
   ├─ Send "stop" to screen session
   ├─ Wait 30s for graceful shutdown
   ├─ Kill service if still running
   └─ Start service (run startserver.sh in new screen)
   ↓
9. Server back online
```

### Example 2: TPS Restart

```
1. gtnh_master_monitor.sh (every 60s)
   └─ run_tps_check_cycle() (tps_functions.sh)
   ↓
2. Loop 7 times (3s apart):
   ├─ Send "/forge tps" to screen
   ├─ Parse log for "Mean TPS: X.XXX"
   ├─ Find lowest TPS: 18.2
   └─ Compare to threshold (19.0): FAIL
   ↓
3. Results: 6/7 checks failed (> 5 needed)
   ↓
4. Check can_restart(TPS_RESTART_COOLDOWN)
   └─ last_any_restart: 4000 seconds ago (> 3600s) ✓
   ↓
5. do_tps_restart() (restart_functions.sh)
   ├─ Announce: "[AUTO-RESTART] Low TPS detected! Restarting in 3 minutes..."
   ├─ Countdown: 180, 60, 30, 20, 10, 5, 4, 3, 2, 1
   ├─ mark_restart("tps")
   │  ├─ Write timestamp to last_tps_restart
   │  └─ Write timestamp to last_any_restart
   └─ sudo systemctl restart ${SERVICE_NAME}.service
   ↓
6. Systemd restarts server (same as vote restart)
   ↓
7. Server back online
   ↓
8. TPS cooldown active for 1 hour
```

---

## Performance & Resource Usage

**Monitoring Script:**
- CPU: Negligible (~0.1% on modern CPU)
- RAM: ~10 MB (bash + minor state files)
- Disk I/O: Minimal (log parsing, state file writes)

**Checking Frequency:**
- Vote checks: Every 10 seconds (lightweight log grep)
- TPS checks: Every 60 seconds (7 TPS queries per cycle)

**Optimization:**
- Log parsing uses `tail -n +X` (only read new lines)
- State files are tiny (< 1 KB each)
- No database required (file-based state)

---

## Future Extensibility

**Adding New Restart Triggers:**

1. Create new function library: `lib/new_trigger_functions.sh`
2. Add check function: `check_new_trigger()`
3. Add restart function: `do_new_trigger_restart()`
4. Source in `gtnh_master_monitor.sh`
5. Call in main loop
6. Add cooldown file: `last_new_trigger_restart`

**Example: Restart on crash detection**

```bash
# lib/crash_functions.sh
check_for_crashes() {
    if grep -q "FATAL ERROR" "$SERVER_DIR/logs/latest.log"; then
        do_crash_restart
    fi
}

do_crash_restart() {
    send_server_message "[AUTO-RESTART] Server crash detected! Restarting..."
    sleep 5
    mark_restart "crash"
    trigger_systemd_restart "crash"
}
```

---

## Security Considerations

**Sudoers:**
- Limited to specific commands (systemctl restart/stop/start/status)
- Limited to specific services (${SERVICE_NAME}*)
- Limited to specific user (${REAL_USER})
- Syntax validated during installation

**Screen Session:**
- Runs as regular user (not root)
- Session name prevents conflicts
- Accessible only to server owner

**Log Parsing:**
- No code execution from logs (only grep/awk)
- Player names sanitized (no special chars executed)

**State Files:**
- Stored in server directory (user-owned)
- No sensitive data (only timestamps, player names)

---

For more information, see:
- `../README.md` - Main documentation
- `QUICK_REFERENCE.md` - Command cheat sheet
- `CONFIGURATION.md` - How to configure
- `TROUBLESHOOTING.md` - Common issues
ARCH_EOF

    # Substitute variables
    sed -i "s|\${SERVICE_NAME}|${SERVICE_NAME}|g" "$docs_dir/ARCHITECTURE.md"
    sed -i "s|\${MONITORS_SERVICE_NAME}|${MONITORS_SERVICE_NAME}|g" "$docs_dir/ARCHITECTURE.md"
    sed -i "s|\${SCREEN_NAME}|${SCREEN_NAME}|g" "$docs_dir/ARCHITECTURE.md"
    sed -i "s|\${SERVER_DIR}|${SERVER_DIR}|g" "$docs_dir/ARCHITECTURE.md"
    sed -i "s|\${REAL_USER}|${REAL_USER}|g" "$docs_dir/ARCHITECTURE.md"
    
    chmod 644 "$docs_dir/ARCHITECTURE.md"
    
    log_info "Generated all documentation files"
    log_info "  • README.md"
    log_info "  • .service_info"
    log_info "  • docs/QUICK_REFERENCE.md"
    log_info "  • docs/CONFIGURATION.md"
    log_info "  • docs/TROUBLESHOOTING.md"
    log_info "  • docs/ARCHITECTURE.md"
}

# Enable and start services
enable_services() {
    log_step "Enabling services..."
    
    systemctl daemon-reload
    log_info "Reloaded systemd daemon"
    
    read -p "Enable ${SERVICE_NAME}.service to start on boot? [Y/n] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        systemctl enable ${SERVICE_NAME}.service
        log_info "${SERVICE_NAME}.service enabled"
    fi
    
    read -p "Enable ${MONITORS_SERVICE_NAME}.service to start on boot? [Y/n] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        systemctl enable ${MONITORS_SERVICE_NAME}.service
        log_info "${MONITORS_SERVICE_NAME}.service enabled"
    fi
}

# Start services
start_services() {
    log_step "Starting services..."
    
    # Check if server is already running
    if screen -list | grep -q "\.$SCREEN_SESSION_NAME"; then
        log_warn "Server is already running in screen"
        
        read -p "Start monitoring now? [Y/n] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            systemctl start ${MONITORS_SERVICE_NAME}.service
            sleep 2
            if systemctl is-active --quiet ${MONITORS_SERVICE_NAME}.service; then
                log_info "${MONITORS_SERVICE_NAME}.service started"
            else
                log_error "Failed to start ${MONITORS_SERVICE_NAME}.service"
                systemctl status ${MONITORS_SERVICE_NAME}.service --no-pager
            fi
        fi
    else
        log_info "Server is not currently running"
        
        read -p "Start server now? [Y/n] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            systemctl start ${SERVICE_NAME}.service
            log_info "Starting ${SERVICE_NAME}.service..."
            log_info "Waiting for server to initialize (this may take a few minutes)..."
            sleep 10
            
            systemctl start ${MONITORS_SERVICE_NAME}.service
            sleep 2
            if systemctl is-active --quiet ${MONITORS_SERVICE_NAME}.service; then
                log_info "${MONITORS_SERVICE_NAME}.service started"
            fi
        fi
    fi
}

# Validate installation
validate_installation() {
    log_step "Validating installation..."
    
    local errors=0
    
    # Check service files
    if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        log_info "${SERVICE_NAME}.service exists"
    else
        log_error "${SERVICE_NAME}.service not found"
        ((errors++))
    fi
    
    if [ -f "/etc/systemd/system/${MONITORS_SERVICE_NAME}.service" ]; then
        log_info "${MONITORS_SERVICE_NAME}.service exists"
    else
        log_error "${MONITORS_SERVICE_NAME}.service not found"
        ((errors++))
    fi
    
    # Check scripts
    if [ -x "$SCRIPT_DIR/gtnh_master_monitor.sh" ]; then
        log_info "gtnh_master_monitor.sh is executable"
    else
        log_error "gtnh_master_monitor.sh not executable"
        ((errors++))
    fi
    
    # Check log directory
    if [ -w "$SCRIPT_DIR/logs" ]; then
        log_info "Log directory is writable"
    else
        log_error "Log directory is not writable"
        ((errors++))
    fi
    
    # Check sudoers
    if [ -f "/etc/sudoers.d/gtnh-restart" ]; then
        log_info "Sudoers configuration exists"
    else
        log_error "Sudoers configuration missing"
        ((errors++))
    fi
    
    if [ $errors -eq 0 ]; then
        log_info "All validation checks passed!"
        return 0
    else
        log_error "Validation failed with $errors error(s)"
        return 1
    fi
}

# Print success summary
print_summary() {
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║   GTNH Server Setup Complete!                          ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
    echo "Server Location: $SERVER_DIR"
    echo ""
    echo "Service Names:"
    echo "  • Main Server:  ${SERVICE_NAME}.service"
    echo "  • Monitoring:   ${MONITORS_SERVICE_NAME}.service"
    echo "  • Screen:       ${SCREEN_SESSION_NAME}"
    echo ""
    echo "Service Commands:"
    echo "  • Main Server:  sudo systemctl status ${SERVICE_NAME}.service"
    echo "  • Monitoring:   sudo systemctl status ${MONITORS_SERVICE_NAME}.service"
    echo ""
    echo "Logs:"
    echo "  • Server:       screen -r ${SCREEN_SESSION_NAME}"
    echo "  • Monitoring:   tail -f $SCRIPT_DIR/logs/master_monitor.log"
    echo ""
    echo "Management:"
    echo "  • Start:        sudo systemctl start ${SERVICE_NAME}.service"
    echo "  • Stop:         sudo systemctl stop ${SERVICE_NAME}.service"
    echo "  • Restart:      sudo systemctl restart ${SERVICE_NAME}.service"
    echo ""
    echo "Configuration:"
    echo "  • Settings:     $SCRIPT_DIR/lib/common_functions.sh"
    echo "  • Log level:    $LOG_LEVEL"
    echo ""
    echo "Documentation:"
    echo "  • Main guide:   $SCRIPT_DIR/README.md"
    echo "  • Quick ref:    $SCRIPT_DIR/docs/QUICK_REFERENCE.md"
    echo "  • Config guide: $SCRIPT_DIR/docs/CONFIGURATION.md"
    echo "  • Troubleshoot: $SCRIPT_DIR/docs/TROUBLESHOOTING.md"
    echo "  • Architecture: $SCRIPT_DIR/docs/ARCHITECTURE.md"
    echo ""
    echo "Vote Restart:"
    echo "  • Players type !restart in chat"
    echo "  • ${VOTE_THRESHOLD}% of online players must vote"
    echo "  • $((VOTE_COOLDOWN/60)) minute cooldown between manual restarts"
    echo ""
    echo "Auto TPS Restart:"
    echo "  • Monitors every $TPS_CHECK_INTERVAL seconds"
    echo "  • Restarts if TPS < $TPS_THRESHOLD for 5/7 checks"
    echo "  • $((TPS_COOLDOWN/60)) minute cooldown between auto restarts"
    echo ""
    echo "Next Steps:"
    echo "  1. Test vote restart: have 2 players type !restart"
    echo "  2. Monitor logs: tail -f $SCRIPT_DIR/logs/master_monitor.log"
    echo "  3. Adjust settings in: $SCRIPT_DIR/lib/common_functions.sh"
    echo "  4. Restart monitoring: sudo systemctl restart ${MONITORS_SERVICE_NAME}.service"
    echo ""
}

# Main installation function
main_install() {
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║   GTNH Server Complete Setup Installer v${VERSION}     ║"
    echo "║   Self-Contained Portable Version                      ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
    
    check_root
    check_prerequisites
    detect_server_directory
    detect_start_script
    generate_service_name
    get_configuration
    
    echo ""
    log_warn "Ready to install. This will:"
    echo "  • Create systemd services"
    echo "  • Deploy monitoring scripts"
    echo "  • Configure sudoers"
    echo "  • Enable auto-restart on low TPS"
    echo ""
    read -p "Continue with installation? [Y/n] " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log_warn "Installation cancelled"
        exit 0
    fi
    
    create_backup
    create_directories
    deploy_monitoring_scripts
    generate_services
    configure_sudoers
    enable_services
    
    if validate_installation; then
        generate_documentation
        start_services
        print_summary
    else
        log_error "Installation validation failed!"
        exit 1
    fi
}

# Run main installation
main_install
