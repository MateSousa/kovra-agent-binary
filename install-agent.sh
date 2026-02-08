#!/bin/sh
# Kovra IDP Agent Install Script
# Downloads and installs the IDP agent as a systemd service for bare-metal Kubernetes provisioning.
#
# Required environment variables:
#   REGISTRATION_TOKEN  - One-time registration token from the IDP
#   IDP_ENDPOINT        - URL of the IDP backend (e.g. https://api.kovra.io)
#   NODE_ROLE           - Node role: control_plane, worker_cpu, or worker_gpu
#   INSTALL_MODE        - Installation mode: provision or import
#
# Optional environment variables:
#   AGENT_DOWNLOAD_URL  - Override agent binary download URL
#   AGENT_VERSION       - Agent version to download (default: latest)
#   CONTROL_PLANE_ENDPOINT - API server endpoint for worker nodes to join

set -eu

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info()  { printf "${GREEN}[INFO]${NC} %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

AGENT_BIN="/usr/local/bin/idp-agent"
SERVICE_NAME="idp-agent"
ENV_FILE="/etc/idp-agent/agent.env"

# Validate required environment variables
check_required_vars() {
    missing=""
    [ -z "${REGISTRATION_TOKEN:-}" ] && missing="$missing REGISTRATION_TOKEN"
    [ -z "${IDP_ENDPOINT:-}" ] && missing="$missing IDP_ENDPOINT"
    [ -z "${NODE_ROLE:-}" ] && missing="$missing NODE_ROLE"
    [ -z "${INSTALL_MODE:-}" ] && missing="$missing INSTALL_MODE"

    if [ -n "$missing" ]; then
        log_error "Missing required environment variables:$missing"
        exit 1
    fi

    # Validate NODE_ROLE
    case "$NODE_ROLE" in
        control_plane|worker_cpu|worker_gpu) ;;
        *) log_error "Invalid NODE_ROLE: $NODE_ROLE (must be control_plane, worker_cpu, or worker_gpu)"; exit 1 ;;
    esac

    # Validate INSTALL_MODE
    case "$INSTALL_MODE" in
        provision|import) ;;
        *) log_error "Invalid INSTALL_MODE: $INSTALL_MODE (must be provision or import)"; exit 1 ;;
    esac
}

# Check system requirements
check_system() {
    # Must run as root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

    # Check OS
    if [ ! -f /etc/os-release ]; then
        log_error "Cannot detect OS - /etc/os-release not found"
        exit 1
    fi

    . /etc/os-release
    case "$ID" in
        ubuntu)
            case "$VERSION_ID" in
                22.04|24.04) log_info "Detected Ubuntu $VERSION_ID" ;;
                *) log_warn "Ubuntu $VERSION_ID not officially supported (tested on 22.04/24.04)" ;;
            esac
            ;;
        debian)
            log_info "Detected Debian $VERSION_ID"
            ;;
        *)
            log_warn "OS '$ID' not officially supported (tested on Ubuntu 22.04/24.04, Debian 12)"
            ;;
    esac

    # Check architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) log_error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    log_info "Architecture: $ARCH"
}

# Download agent binary
download_agent() {
    AGENT_VERSION="${AGENT_VERSION:-v0.1.0}"
    AGENT_DOWNLOAD_URL="${AGENT_DOWNLOAD_URL:-https://github.com/MateSousa/kovra-agent-binary/releases/download/${AGENT_VERSION}/idp-agent-linux-${ARCH}}"

    log_info "Downloading agent from: $AGENT_DOWNLOAD_URL"

    if command -v curl >/dev/null 2>&1; then
        curl -sfL -o "$AGENT_BIN" "$AGENT_DOWNLOAD_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$AGENT_BIN" "$AGENT_DOWNLOAD_URL"
    else
        log_error "Neither curl nor wget found. Install one and retry."
        exit 1
    fi

    chmod +x "$AGENT_BIN"
    log_info "Agent binary installed at $AGENT_BIN"
}

# Create environment file with agent configuration
create_env_file() {
    mkdir -p "$(dirname "$ENV_FILE")"

    cat > "$ENV_FILE" <<EOF
REGISTRATION_TOKEN=${REGISTRATION_TOKEN}
IDP_ENDPOINT=${IDP_ENDPOINT}
NODE_ROLE=${NODE_ROLE}
INSTALL_MODE=${INSTALL_MODE}
EOF

    # Add optional vars if set
    [ -n "${CONTROL_PLANE_ENDPOINT:-}" ] && echo "CONTROL_PLANE_ENDPOINT=${CONTROL_PLANE_ENDPOINT}" >> "$ENV_FILE"

    chmod 600 "$ENV_FILE"
    log_info "Environment file created at $ENV_FILE"
}

# Install systemd service
install_service() {
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Kovra IDP Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${AGENT_BIN}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "Systemd service installed: ${SERVICE_NAME}"
}

# Start the agent service
start_service() {
    systemctl enable "${SERVICE_NAME}"
    systemctl start "${SERVICE_NAME}"
    log_info "Agent service started and enabled on boot"
    log_info ""
    log_info "Useful commands:"
    log_info "  journalctl -u ${SERVICE_NAME} -f    # Follow logs"
    log_info "  systemctl status ${SERVICE_NAME}     # Check status"
    log_info "  systemctl restart ${SERVICE_NAME}    # Restart agent"
    log_info "  systemctl stop ${SERVICE_NAME}       # Stop agent"
}

main() {
    log_info "Kovra IDP Agent Installer"
    log_info "========================="

    check_required_vars
    check_system
    download_agent
    create_env_file
    install_service
    start_service
}

main
