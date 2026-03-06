#!/bin/bash
# install.sh - Install dispatcher agent, dispatcher CLI, or API server
# Must be run as root. Role must be specified explicitly.
#
# Usage:
#   ./install.sh --agent        Install the agent (on remote hosts)
#   ./install.sh --dispatcher   Install the dispatcher CLI (on control host)
#   ./install.sh --api          Install the API server (on control host, after --dispatcher)
#   ./install.sh --uninstall    Remove installed files (preserves config/certs)
#   ./install.sh --run-tests    Run test suite from the source directory
#
# Supported platforms: Debian/Ubuntu (apt), Alpine Linux (apk)

set -euo pipefail

# --- configuration ---

AGENT_USER="dispatcher-agent"
AGENT_GROUP="dispatcher-agent"
DISPATCHER_GROUP="dispatcher"

BIN_DIR="/usr/local/bin"
LIB_DIR="/usr/local/lib/dispatcher"
AGENT_CONF_DIR="/etc/dispatcher-agent"
DISPATCHER_CONF_DIR="/etc/dispatcher"
SCRIPTS_DIR="/opt/dispatcher-scripts"
PAIRING_DIR="/var/lib/dispatcher/pairing"
AGENTS_DIR="/var/lib/dispatcher/agents"
LOCKS_DIR="/var/lib/dispatcher/locks"
SYSTEMD_DIR="/etc/systemd/system"
AGENT_SERVICE="dispatcher-agent.service"
API_SERVICE="dispatcher-api.service"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- helpers ---

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (or via sudo)."
}

# Resolve the directory containing this script, following symlinks
script_dir() {
    local src="${BASH_SOURCE[0]}"
    while [[ -L "$src" ]]; do
        local dir
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

SOURCE_DIR="$(script_dir)"

# --- platform detection ---

PKG_MGR=""
PKG_INSTALL_CMD=""

detect_platform() {
    if command -v apk &>/dev/null; then
        PKG_MGR="apk"
        PKG_INSTALL_CMD="apk add"
        info "Platform: Alpine Linux (apk)"
    elif command -v apt &>/dev/null; then
        PKG_MGR="apt"
        PKG_INSTALL_CMD="apt install"
        info "Platform: Debian/Ubuntu (apt)"
    else
        die "Unsupported platform. Supported: Debian/Ubuntu (apt), Alpine Linux (apk).
     For RPM-based systems, install dependencies manually and copy files directly.
     See DEVELOPER.md for file locations."
    fi
}

# --- user/group creation (platform-aware) ---

create_system_group() {
    local group="$1"

    if getent group "$group" &>/dev/null; then
        info "Group '$group' already exists."
        return
    fi

    info "Creating system group '$group'..."
    if [[ "$PKG_MGR" == "apk" ]]; then
        addgroup -S "$group"
    else
        groupadd --system "$group"
    fi
}

create_system_user() {
    local user="$1"
    local group="$2"
    local comment="$3"

    if id "$user" &>/dev/null; then
        info "User '$user' already exists."
        return
    fi

    info "Creating system user '$user'..."
    if [[ "$PKG_MGR" == "apk" ]]; then
        adduser -S -H -s /sbin/nologin -G "$group" -g "$comment" "$user"
    else
        useradd --system --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "$comment" \
            "$user"
    fi
}

# --- init system detection ---

HAS_SYSTEMD=false

detect_init() {
    if command -v systemctl &>/dev/null; then
        HAS_SYSTEMD=true
    else
        warn "systemctl not found - service files will not be installed."
        warn "Start services manually once configured:"
        warn "  dispatcher-agent serve"
        warn "  dispatcher-api"
    fi
}

install_service_unit() {
    local unit="$1"
    if [[ "$HAS_SYSTEMD" == true ]]; then
        info "Installing systemd unit $unit..."
        install -m 644 "$SOURCE_DIR/etc/$unit" "$SYSTEMD_DIR/$unit"
        systemctl daemon-reload
    fi
}

# --- dependency check ---

# Perl module => package name maps, per platform per role.
# Core modules (always present in perl/perl-base) are listed for completeness
# so missing package suggestions are accurate if something is genuinely absent.

check_perl_modules() {
    local role="$1"

    # Debian module => package
    declare -A DEB_AGENT_DEPS=(
        ["IO::Socket::SSL"]="libio-socket-ssl-perl"
        ["JSON"]="libjson-perl"
        ["File::Temp"]="perl"
        ["Sys::Syslog"]="perl"
        ["Getopt::Long"]="perl"
        ["Sys::Hostname"]="perl"
        ["POSIX"]="perl"
    )
    declare -A DEB_DISPATCHER_DEPS=(
        ["LWP::UserAgent"]="libwww-perl"
        ["IO::Socket::SSL"]="libio-socket-ssl-perl"
        ["JSON"]="libjson-perl"
        ["File::Temp"]="perl"
        ["Sys::Syslog"]="perl"
        ["Getopt::Long"]="perl"
        ["Sys::Hostname"]="perl"
        ["Time::HiRes"]="perl"
        ["Time::Piece"]="perl"
        ["IO::Select"]="perl"
        ["POSIX"]="perl"
        ["Fcntl"]="perl"
        ["File::Path"]="perl"
        ["File::Basename"]="perl"
        ["IPC::Open2"]="perl"
    )

    # Alpine module => package
    declare -A APK_AGENT_DEPS=(
        ["IO::Socket::SSL"]="perl-io-socket-ssl"
        ["JSON"]="perl-json"
        ["File::Temp"]="perl"
        ["Sys::Syslog"]="perl"
        ["Getopt::Long"]="perl"
        ["Sys::Hostname"]="perl"
        ["POSIX"]="perl"
    )
    declare -A APK_DISPATCHER_DEPS=(
        ["LWP::UserAgent"]="perl-libwww"
        ["IO::Socket::SSL"]="perl-io-socket-ssl"
        ["JSON"]="perl-json"
        ["File::Temp"]="perl"
        ["Sys::Syslog"]="perl"
        ["Getopt::Long"]="perl"
        ["Sys::Hostname"]="perl"
        ["Time::HiRes"]="perl"
        ["Time::Piece"]="perl"
        ["IO::Select"]="perl"
        ["POSIX"]="perl"
        ["Fcntl"]="perl"
        ["File::Path"]="perl"
        ["File::Basename"]="perl"
        ["IPC::Open2"]="perl"
    )

    info "Checking Perl module dependencies for role: $role"

    # Select the right map
    local map_name
    if [[ "$PKG_MGR" == "apk" ]]; then
        [[ "$role" == "agent" ]] && map_name="APK_AGENT_DEPS" || map_name="APK_DISPATCHER_DEPS"
    else
        [[ "$role" == "agent" ]] && map_name="DEB_AGENT_DEPS" || map_name="DEB_DISPATCHER_DEPS"
    fi

    local -n DEP_MAP="$map_name"

    local missing_mods=()
    declare -A missing_pkgs

    for mod in "${!DEP_MAP[@]}"; do
        if ! perl -e "use $mod" 2>/dev/null; then
            missing_mods+=("$mod")
            missing_pkgs["${DEP_MAP[$mod]}"]=1
        fi
    done

    if [[ ${#missing_mods[@]} -eq 0 ]]; then
        info "All Perl module dependencies satisfied."
        return 0
    fi

    echo ""
    error "Missing Perl modules:"
    for mod in $(printf '%s\n' "${missing_mods[@]}" | sort); do
        printf "    %-30s  (%s)\n" "$mod" "${DEP_MAP[$mod]}"
    done
    echo ""
    error "Install the missing packages and re-run this installer:"
    echo ""
    echo "    sudo $PKG_INSTALL_CMD ${!missing_pkgs[*]}"
    echo ""
    exit 1
}

check_openssl() {
    if ! command -v openssl &>/dev/null; then
        echo ""
        error "openssl not found. Install with:"
        echo ""
        echo "    sudo $PKG_INSTALL_CMD openssl"
        echo ""
        exit 1
    fi
    info "openssl: $(openssl version)"
}

# --- shared step ---

install_lib() {
    info "Installing Perl library to $LIB_DIR..."
    mkdir -p "$LIB_DIR"
    cp -r "$SOURCE_DIR/lib/." "$LIB_DIR/"
    find "$LIB_DIR" -name '*.pm' -exec chmod 644 {} \;
    find "$LIB_DIR" -type d   -exec chmod 755 {} \;
}

# --- test runner ---

run_tests() {
    info "Running test suite..."
    cd "$SOURCE_DIR"

    if command -v prove &>/dev/null; then
        prove -Ilib t/ && info "All tests passed." || die "Test suite failed."
    else
        # prove is in perl-utils on Alpine; fall back to running files directly
        local failed=0
        for t in t/*.t; do
            perl -Ilib "$t" || failed=1
        done
        [[ $failed -eq 0 ]] && info "All tests passed." || die "Test suite failed."
    fi
}

# --- agent installation ---

install_agent() {
    info "Installing dispatcher-agent..."

    create_system_group "$AGENT_GROUP"
    create_system_user "$AGENT_USER" "$AGENT_GROUP" "Dispatcher agent service user"

    install -m 755 "$SOURCE_DIR/bin/dispatcher-agent" "$BIN_DIR/dispatcher-agent"
    sed -i "s|use lib \"\$Bin/../lib\";|use lib \"$LIB_DIR\";|" \
        "$BIN_DIR/dispatcher-agent"

    # Config directory - readable by agent group, not world
    mkdir -p "$AGENT_CONF_DIR"
    chmod 750 "$AGENT_CONF_DIR"
    chown root:"$AGENT_GROUP" "$AGENT_CONF_DIR"

    if [[ ! -f "$AGENT_CONF_DIR/agent.conf" ]]; then
        install -m 640 "$SOURCE_DIR/etc/agent.conf.example" \
            "$AGENT_CONF_DIR/agent.conf"
        chown root:"$AGENT_GROUP" "$AGENT_CONF_DIR/agent.conf"
        warn "Agent config written to $AGENT_CONF_DIR/agent.conf - review before use."
    else
        info "Agent config already exists, not overwriting."
    fi

    if [[ ! -f "$AGENT_CONF_DIR/scripts.conf" ]]; then
        install -m 640 "$SOURCE_DIR/etc/scripts.conf.example" \
            "$AGENT_CONF_DIR/scripts.conf"
        chown root:"$AGENT_GROUP" "$AGENT_CONF_DIR/scripts.conf"
        warn "Empty allowlist written to $AGENT_CONF_DIR/scripts.conf - add scripts before starting."
    else
        info "Script allowlist already exists, not overwriting."
    fi

    # Scripts directory - root owns, agent group can read/execute
    if [[ ! -d "$SCRIPTS_DIR" ]]; then
        mkdir -p "$SCRIPTS_DIR"
        chmod 750 "$SCRIPTS_DIR"
        chown root:"$AGENT_GROUP" "$SCRIPTS_DIR"
        info "Script directory created: $SCRIPTS_DIR"
    else
        info "Script directory already exists: $SCRIPTS_DIR"
    fi

    install_service_unit "$AGENT_SERVICE"

    info "dispatcher-agent installed at $BIN_DIR/dispatcher-agent"
}

# --- dispatcher installation ---

install_dispatcher() {
    info "Installing dispatcher CLI..."

    create_system_group "$DISPATCHER_GROUP"

    install -m 755 "$SOURCE_DIR/bin/dispatcher" "$BIN_DIR/dispatcher"
    sed -i "s|use lib \"\$Bin/../lib\";|use lib \"$LIB_DIR\";|" \
        "$BIN_DIR/dispatcher"

    # Config directory
    mkdir -p "$DISPATCHER_CONF_DIR"
    chmod 750 "$DISPATCHER_CONF_DIR"
    chown root:"$DISPATCHER_GROUP" "$DISPATCHER_CONF_DIR"

    # Pairing queue
    mkdir -p "$PAIRING_DIR"
    chown root:"$DISPATCHER_GROUP" "$PAIRING_DIR"
    chmod 770 "$PAIRING_DIR"

    # Agent registry - written by approve, read by list-agents and API
    mkdir -p "$AGENTS_DIR"
    chown root:"$DISPATCHER_GROUP" "$AGENTS_DIR"
    chmod 770 "$AGENTS_DIR"

    # Lock files - written during dispatch
    mkdir -p "$LOCKS_DIR"
    chown root:"$DISPATCHER_GROUP" "$LOCKS_DIR"
    chmod 770 "$LOCKS_DIR"

    # Dispatcher config
    if [[ ! -f "$DISPATCHER_CONF_DIR/dispatcher.conf" ]]; then
        install -m 640 "$SOURCE_DIR/etc/dispatcher.conf.example" \
            "$DISPATCHER_CONF_DIR/dispatcher.conf"
        chown root:"$DISPATCHER_GROUP" "$DISPATCHER_CONF_DIR/dispatcher.conf"
        warn "Dispatcher config written to $DISPATCHER_CONF_DIR/dispatcher.conf - review before use."
    else
        info "Dispatcher config already exists, not overwriting."
    fi

    # Auth hook - install example only if not already present
    if [[ ! -f "$DISPATCHER_CONF_DIR/auth-hook" ]]; then
        install -m 755 "$SOURCE_DIR/etc/auth-hook.example" \
            "$DISPATCHER_CONF_DIR/auth-hook"
        info "Auth hook installed at $DISPATCHER_CONF_DIR/auth-hook (always-authorise default)."
    else
        info "Auth hook already exists, not overwriting."
    fi

    info "dispatcher installed at $BIN_DIR/dispatcher"
}

# --- api installation ---

install_api() {
    info "Installing dispatcher-api..."

    install -m 755 "$SOURCE_DIR/bin/dispatcher-api" "$BIN_DIR/dispatcher-api"
    sed -i "s|use lib \"\$Bin/../lib\";|use lib \"$LIB_DIR\";|" \
        "$BIN_DIR/dispatcher-api"

    install_service_unit "$API_SERVICE"

    info "dispatcher-api installed at $BIN_DIR/dispatcher-api"
}

# --- uninstall ---

uninstall() {
    info "Uninstalling dispatcher..."

    if [[ "$HAS_SYSTEMD" == true ]]; then
        if systemctl is-active --quiet "$AGENT_SERVICE" 2>/dev/null; then
            info "Stopping $AGENT_SERVICE..."
            systemctl stop "$AGENT_SERVICE"
        fi
        if systemctl is-enabled --quiet "$AGENT_SERVICE" 2>/dev/null; then
            info "Disabling $AGENT_SERVICE..."
            systemctl disable "$AGENT_SERVICE"
        fi
    fi

    local files=(
        "$BIN_DIR/dispatcher-agent"
        "$BIN_DIR/dispatcher"
        "$BIN_DIR/dispatcher-api"
    )

    if [[ "$HAS_SYSTEMD" == true ]]; then
        files+=(
            "$SYSTEMD_DIR/$AGENT_SERVICE"
            "$SYSTEMD_DIR/$API_SERVICE"
        )
    fi

    # Remove lock files (transient, not config)
    if [[ -d "$LOCKS_DIR" ]]; then
        rm -rf "$LOCKS_DIR"
        info "Removed $LOCKS_DIR"
    fi

    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            info "Removed $f"
        fi
    done

    if [[ -d "$LIB_DIR" ]]; then
        rm -rf "$LIB_DIR"
        info "Removed $LIB_DIR"
    fi

    if [[ "$HAS_SYSTEMD" == true ]]; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    echo ""
    warn "The following were NOT removed (may contain keys, certs, or data):"
    warn "  $AGENT_CONF_DIR"
    warn "  $DISPATCHER_CONF_DIR"
    warn "  $PAIRING_DIR"
    warn "  $AGENTS_DIR"
    warn "  $SCRIPTS_DIR"
    warn ""
    warn "To remove completely:"
    warn "  sudo rm -rf $AGENT_CONF_DIR $DISPATCHER_CONF_DIR"
    warn "  sudo rm -rf /var/lib/dispatcher $SCRIPTS_DIR"
    if [[ "$PKG_MGR" == "apk" ]]; then
        warn "  sudo deluser $AGENT_USER"
        warn "  sudo delgroup $DISPATCHER_GROUP"
    else
        warn "  sudo userdel $AGENT_USER"
        warn "  sudo groupdel $DISPATCHER_GROUP"
    fi

    info "Uninstall complete."
}

# --- next steps ---

print_next_steps_agent() {
    local svc_note=""
    if [[ "$HAS_SYSTEMD" == true ]]; then
        svc_note="  5. Enable and start:
       sudo systemctl enable $AGENT_SERVICE
       sudo systemctl start  $AGENT_SERVICE"
    else
        svc_note="  5. Start the agent:
       dispatcher-agent serve"
    fi

    echo ""
    echo "================================================================"
    echo " dispatcher-agent installed"
    echo "================================================================"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Edit the script allowlist:"
    echo "       sudo \$EDITOR $AGENT_CONF_DIR/scripts.conf"
    echo ""
    echo "  2. Place scripts in $SCRIPTS_DIR:"
    echo "       sudo cp your-script.sh $SCRIPTS_DIR/"
    echo "       sudo chmod 750 $SCRIPTS_DIR/your-script.sh"
    echo "       sudo chown root:$AGENT_GROUP $SCRIPTS_DIR/your-script.sh"
    echo ""
    echo "  3. Request pairing (while dispatcher host is in pairing-mode):"
    echo "       sudo dispatcher-agent request-pairing --dispatcher <dispatcher-host>"
    echo ""
    echo "  4. Once approved, verify:"
    echo "       sudo dispatcher-agent pairing-status"
    echo "       sudo dispatcher-agent ping-self"
    echo ""
    echo -e "$svc_note"
    echo ""
    echo "================================================================"
}

print_next_steps_dispatcher() {
    echo ""
    echo "================================================================"
    echo " dispatcher installed"
    echo "================================================================"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Initialise the CA (first time only):"
    echo "       sudo dispatcher setup-ca"
    echo ""
    echo "  2. Generate the dispatcher's own certificate:"
    echo "       sudo dispatcher setup-dispatcher"
    echo ""
    echo "  3. Add yourself to the dispatcher group for CLI access without sudo:"
    echo "       sudo usermod -aG $DISPATCHER_GROUP \$USER"
    echo "       # log out and back in for the group to take effect"
    echo ""
    echo "  4. Accept pairing requests from agents:"
    echo "       sudo dispatcher pairing-mode"
    echo ""
    echo "  5. Run a script on a paired host:"
    echo "       dispatcher run <host> <script>"
    echo "       dispatcher ping <host>"
    echo ""
    echo "================================================================"
}

print_next_steps_api() {
    local svc_note=""
    if [[ "$HAS_SYSTEMD" == true ]]; then
        svc_note="  1. Enable and start the API service:
       sudo systemctl enable $API_SERVICE
       sudo systemctl start  $API_SERVICE"
    else
        svc_note="  1. Start the API server:
       dispatcher-api"
    fi

    echo ""
    echo "================================================================"
    echo " dispatcher-api installed"
    echo "================================================================"
    echo ""
    echo "Next steps:"
    echo ""
    echo -e "$svc_note"
    echo ""
    echo "  2. Verify it is running:"
    echo "       curl -s http://localhost:7445/health | python3 -m json.tool"
    echo ""
    echo "  3. Test ping and discovery:"
    echo "       curl -s -X POST http://localhost:7445/ping \\"
    echo "         -H 'Content-Type: application/json' \\"
    echo "         -d '{\"hosts\":[\"<agent-host>\"]}' | python3 -m json.tool"
    echo ""
    echo "       curl -s http://localhost:7445/discovery | python3 -m json.tool"
    echo ""
    echo "  Note: To enable TLS, set api_cert and api_key in dispatcher.conf"
    echo "        and restart the service."
    echo ""
    echo "================================================================"
}

# --- argument parsing ---

ROLE=""
DO_UNINSTALL=false
DO_RUN_TESTS=false

for arg in "$@"; do
    case "$arg" in
        --agent)      ROLE="agent" ;;
        --dispatcher) ROLE="dispatcher" ;;
        --api)        ROLE="api" ;;
        --uninstall)  DO_UNINSTALL=true ;;
        --run-tests)  DO_RUN_TESTS=true ;;
        --help|-h)
            echo "Usage: $0 --agent | --dispatcher | --api | --uninstall [--run-tests]"
            echo ""
            echo "  --agent        Install the agent service (on remote hosts)"
            echo "  --dispatcher   Install the dispatcher CLI (on control host)"
            echo "  --api          Install the API server (on control host, after --dispatcher)"
            echo "  --uninstall    Remove installed files (config, certs, and agent registry preserved)"
            echo "  --run-tests    Run test suite from source directory after installation"
            echo ""
            echo "Supported platforms: Debian/Ubuntu (apt), Alpine Linux (apk)"
            exit 0
            ;;
        *)
            die "Unknown argument: $arg. Use --help for usage."
            ;;
    esac
done

# --- main ---

check_root
detect_platform
detect_init

if [[ "$DO_UNINSTALL" == true ]]; then
    uninstall
    exit 0
fi

# Allow --run-tests without a role (runs tests from source dir only)
if [[ "$DO_RUN_TESTS" == true && -z "$ROLE" ]]; then
    run_tests
    exit 0
fi

[[ -n "$ROLE" ]] || die "Role must be specified. Use --agent, --dispatcher, or --api. See --help."

check_openssl
check_perl_modules "$ROLE"
install_lib

case "$ROLE" in
    agent)
        install_agent
        print_next_steps_agent
        ;;
    dispatcher)
        install_dispatcher
        print_next_steps_dispatcher
        ;;
    api)
        # API requires the dispatcher role to already be installed
        if [[ ! -f "$DISPATCHER_CONF_DIR/dispatcher.conf" ]]; then
            die "--api requires --dispatcher to be installed first."
        fi
        install_api
        print_next_steps_api
        ;;
esac

if [[ "$DO_RUN_TESTS" == true ]]; then
    run_tests
fi
