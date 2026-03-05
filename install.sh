#!/bin/bash
# install.sh - Install dispatcher agent or dispatcher CLI
# Must be run as root. Role must be specified explicitly.
#
# Usage:
#   ./install.sh --agent        Install the agent (on remote hosts)
#   ./install.sh --dispatcher   Install the dispatcher CLI (on control host)
#   ./install.sh --uninstall    Remove installed files (preserves config/certs)

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
    [[ $EUID -eq 0 ]] || die "This script must be run as root."
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

# --- dependency check ---

# Each role has its own module => debian-package map.
# Core perl modules (perl-base) are listed for completeness but will always
# be present on any Debian system - they are included so the output is
# accurate if something is genuinely missing.

check_perl_modules() {
    local role="$1"

    declare -A AGENT_DEPS=(
        ["IO::Socket::SSL"]="libio-socket-ssl-perl"
        ["JSON"]="libjson-perl"
        ["File::Temp"]="perl-base"
        ["Sys::Syslog"]="perl-base"
        ["Getopt::Long"]="perl-base"
        ["Sys::Hostname"]="perl-base"
        ["POSIX"]="perl-base"
    )

    declare -A DISPATCHER_DEPS=(
        ["LWP::UserAgent"]="libwww-perl"
        ["IO::Socket::SSL"]="libio-socket-ssl-perl"
        ["JSON"]="libjson-perl"
        ["File::Temp"]="perl-base"
        ["Sys::Syslog"]="perl-base"
        ["Getopt::Long"]="perl-base"
        ["Sys::Hostname"]="perl-base"
        ["Time::HiRes"]="perl-base"
        ["POSIX"]="perl-base"
        ["Fcntl"]="perl-base"
        ["File::Path"]="perl-base"
        ["File::Basename"]="perl-base"
        ["IPC::Open2"]="perl-base"
    )

    info "Checking Perl module dependencies for role: $role"

    local -n DEP_MAP
    if [[ "$role" == "agent" ]]; then
        DEP_MAP=AGENT_DEPS
    else
        DEP_MAP=DISPATCHER_DEPS
    fi

    local missing_mods=()
    declare -A missing_pkgs   # associative to deduplicate package names

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
    error "Install the missing Debian packages and re-run this installer:"
    echo ""
    echo "    apt-get install ${!missing_pkgs[*]}"
    echo ""
    exit 1
}

check_openssl() {
    command -v openssl >/dev/null 2>&1 \
        || die "openssl not found. Install with: apt-get install openssl"
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

# --- agent installation ---

install_agent() {
    info "Installing dispatcher-agent..."

    if ! id "$AGENT_USER" &>/dev/null; then
        info "Creating system user '$AGENT_USER'..."
        useradd \
            --system \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "Dispatcher agent service user" \
            "$AGENT_USER"
    else
        info "User '$AGENT_USER' already exists."
    fi

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

    install_systemd_unit

    info "dispatcher-agent installed at $BIN_DIR/dispatcher-agent"
}

install_systemd_unit() {
    info "Installing systemd unit $AGENT_SERVICE..."
    install -m 644 "$SOURCE_DIR/etc/$AGENT_SERVICE" "$SYSTEMD_DIR/$AGENT_SERVICE"
    systemctl daemon-reload
    info "Unit installed. Enable and start manually when ready."
}

# --- dispatcher installation ---

install_dispatcher() {
    info "Installing dispatcher CLI..."

    # Create dispatcher group for non-root CLI access
    if ! getent group "$DISPATCHER_GROUP" &>/dev/null; then
        info "Creating group '$DISPATCHER_GROUP'..."
        groupadd --system "$DISPATCHER_GROUP"
    else
        info "Group '$DISPATCHER_GROUP' already exists."
    fi

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

    install -m 644 "$SOURCE_DIR/etc/$API_SERVICE" "$SYSTEMD_DIR/$API_SERVICE"
    systemctl daemon-reload
    info "API service unit installed."
    info "dispatcher-api installed at $BIN_DIR/dispatcher-api"
}

# --- uninstall ---

uninstall() {
    info "Uninstalling dispatcher..."

    if systemctl is-active --quiet "$AGENT_SERVICE" 2>/dev/null; then
        info "Stopping $AGENT_SERVICE..."
        systemctl stop "$AGENT_SERVICE"
    fi
    if systemctl is-enabled --quiet "$AGENT_SERVICE" 2>/dev/null; then
        info "Disabling $AGENT_SERVICE..."
        systemctl disable "$AGENT_SERVICE"
    fi

    local files=(
        "$SYSTEMD_DIR/$AGENT_SERVICE"
        "$BIN_DIR/dispatcher-agent"
        "$BIN_DIR/dispatcher"
        "$BIN_DIR/dispatcher-api"
        "$SYSTEMD_DIR/$API_SERVICE"
    )

    # Remove lock files (safe - they are transient, not config)
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

    systemctl daemon-reload 2>/dev/null || true

    echo ""
    warn "The following were NOT removed (may contain keys, certs, or data):"
    warn "  $AGENT_CONF_DIR"
    warn "  $DISPATCHER_CONF_DIR"
    warn "  $PAIRING_DIR"
    warn "  $AGENTS_DIR"
    warn "  $SCRIPTS_DIR"
    warn ""
    warn "User '$AGENT_USER' was NOT removed.  Remove with: userdel $AGENT_USER"
    warn "Group '$DISPATCHER_GROUP' was NOT removed. Remove with: groupdel $DISPATCHER_GROUP"

    info "Uninstall complete."
}

# --- next steps ---

print_next_steps_agent() {
    echo ""
    echo "================================================================"
    echo " dispatcher-agent installed"
    echo "================================================================"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Edit the script allowlist:"
    echo "       \$EDITOR $AGENT_CONF_DIR/scripts.conf"
    echo ""
    echo "  2. Place scripts in $SCRIPTS_DIR:"
    echo "       cp your-script.sh $SCRIPTS_DIR/"
    echo "       chmod 750 $SCRIPTS_DIR/your-script.sh"
    echo "       chown root:$AGENT_GROUP $SCRIPTS_DIR/your-script.sh"
    echo ""
    echo "  3. Request pairing (while dispatcher host is in pairing-mode):"
    echo "       dispatcher-agent request-pairing --dispatcher <dispatcher-host>"
    echo ""
    echo "  4. Once approved, verify:"
    echo "       dispatcher-agent pairing-status"
    echo "       dispatcher-agent ping-self"
    echo ""
    echo "  5. Enable and start:"
    echo "       systemctl enable $AGENT_SERVICE"
    echo "       systemctl start  $AGENT_SERVICE"
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
    echo "       dispatcher setup-ca"
    echo ""
    echo "  2. Generate the dispatcher's own certificate:"
    echo "       cd $DISPATCHER_CONF_DIR"
    echo "       openssl genrsa -out dispatcher.key 4096"
    echo "       openssl req -new -key dispatcher.key -out dispatcher.csr -subj '/CN=dispatcher'"
    echo "       openssl x509 -req -in dispatcher.csr -CA ca.crt -CAkey ca.key \\"
    echo "         -CAcreateserial -out dispatcher.crt -days 825"
    echo "       chmod 600 dispatcher.key"
    echo "       rm dispatcher.csr"
    echo ""
    echo "  3. Accept pairing requests from agents:"
    echo "       dispatcher pairing-mode"
    echo ""
    echo "  4. In another terminal, list and approve as requests arrive:"
    echo "       dispatcher list-requests"
    echo "       dispatcher approve <reqid>"
    echo ""
    echo "  5. Run a script on a paired host:"
    echo "       dispatcher run <host> <script>"
    echo "       dispatcher ping <host>"
    echo ""
    echo "================================================================"
}

print_next_steps_api() {
    echo ""
    echo "================================================================"
    echo " dispatcher-api installed"
    echo "================================================================"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Enable and start the API service:"
    echo "       sudo systemctl enable $API_SERVICE"
    echo "       sudo systemctl start  $API_SERVICE"
    echo ""
    echo "  2. Verify it is running:"
    echo "       curl -s http://localhost:7445/health | python3 -m json.tool"
    echo ""
    echo "  3. Test ping and discovery:"
    echo "       curl -s -X POST http://localhost:7445/ping \"
    echo "         -H 'Content-Type: application/json' \"
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

for arg in "$@"; do
    case "$arg" in
        --agent)      ROLE="agent" ;;
        --dispatcher) ROLE="dispatcher" ;;
        --api)        ROLE="api" ;;
        --uninstall)  DO_UNINSTALL=true ;;
        --help|-h)
            echo "Usage: $0 --agent | --dispatcher | --uninstall"
            echo ""
            echo "  --agent        Install the agent service (on remote hosts)"
            echo "  --dispatcher   Install the dispatcher CLI (on control host)"
            echo "  --uninstall    Remove installed files (config, certs, and agent registry preserved)"
            exit 0
            ;;
        *)
            die "Unknown argument: $arg. Use --help for usage."
            ;;
    esac
done

# --- main ---

check_root

if [[ "$DO_UNINSTALL" == true ]]; then
    uninstall
    exit 0
fi

[[ -n "$ROLE" ]] || die "Role must be specified. Use --agent or --dispatcher. See --help."

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
        install_lib
        install_api
        print_next_steps_api
        ;;
esac
