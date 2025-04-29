#!/bin/bash

# ======================================================================
# Modern Docker Installation Script for Ubuntu/Debian
# 
# Features:
# - Supports Ubuntu, Debian, and related distributions
# - Installs latest Docker Engine, CLI, and Docker Compose
# - Configures system for optimal Docker performance
# - Provides detailed logging and error handling
# - Adds current user to docker group for non-root usage
# ======================================================================

# Set strict error handling
set -e          # Exit immediately if a command exits with a non-zero status
set -o pipefail # Return value of a pipeline is the value of the last command
trap 'echo "ERROR at line $LINENO: Command \"$BASH_COMMAND\" failed with exit code $?"' ERR

# Create a log file
LOG_FILE="/tmp/docker_install_$(date +%Y%m%d%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Print colorized output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

section() {
    echo ""
    echo -e "${GREEN}===================== $1 =====================${NC}"
}

# Check if script is running as root
if [ "$EUID" -ne 0 ]; then
    error "Please run as root or with sudo privileges."
    exit 1
fi

# Capture the actual user (when running with sudo)
ACTUAL_USER=${SUDO_USER:-$(whoami)}
if [ "$ACTUAL_USER" = "root" ]; then
    warn "Running as root. Consider using a regular user with sudo privileges instead."
    ACTUAL_USER=$(who am i | awk '{print $1}')
    if [ -z "$ACTUAL_USER" ] || [ "$ACTUAL_USER" = "root" ]; then
        warn "Could not determine non-root user. Docker will only be usable by root."
    fi
fi

# Detect OS distribution
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    VERSION_CODENAME=${VERSION_CODENAME:-$(echo $VERSION_ID | cut -d. -f1)}
    info "Detected distribution: $PRETTY_NAME"
else
    error "Unable to detect OS distribution. This script requires a Debian-based system."
    exit 1
fi

# Check if distribution is supported
case $DISTRO in
    ubuntu|debian|linuxmint|elementary|pop|zorin|kali|parrot|deepin|mx)
        info "Distribution $DISTRO is supported."
        ;;
    *)
        warn "Distribution $DISTRO has not been tested with this script. Proceeding anyway..."
        ;;
esac

section "SYSTEM UPDATE"
info "Updating package index..."
apt update -qq || warn "Package index update encountered issues."
info "Upgrading system packages..."
apt upgrade -y || warn "System upgrade encountered issues, continuing anyway."

section "REMOVING OLD DOCKER VERSIONS"
apt-get remove -y docker docker-engine docker.io containerd runc || true

section "INSTALLING PREREQUISITES"
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common

section "SETTING UP DOCKER REPOSITORY"
# Create directory for apt keyrings if it doesn't exist
install -m 0755 -d /etc/apt/keyrings

# Download Docker's official GPG key
info "Downloading Docker's GPG key..."
curl -fsSL https://download.docker.com/linux/$DISTRO/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add the Docker repository
info "Adding Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$DISTRO $VERSION_CODENAME stable" | \
tee /etc/apt/sources.list.d/docker.list > /dev/null

section "UPDATING PACKAGE INDEX WITH DOCKER REPOSITORY"
apt update -y || error "Failed to update package index with Docker repository."

section "INSTALLING DOCKER ENGINE"
apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Fix broken installations if any
apt --fix-broken install -y || warn "Fix broken installation attempted, check for errors."

section "CONFIGURING DOCKER"
# Create docker daemon.json if it doesn't exist
if [ ! -f /etc/docker/daemon.json ]; then
    info "Creating default Docker daemon configuration..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOL
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  }
}
EOL
fi

section "ENABLING AND STARTING DOCKER SERVICE"
systemctl enable docker
systemctl start docker || error "Failed to start Docker service."

section "CONFIGURING USER PERMISSIONS"
if [ -n "$ACTUAL_USER" ] && [ "$ACTUAL_USER" != "root" ]; then
    info "Adding user $ACTUAL_USER to the docker group..."
    usermod -aG docker "$ACTUAL_USER"
    info "IMPORTANT: $ACTUAL_USER must log out and back in for group changes to apply."
fi

section "VERIFYING DOCKER INSTALLATION"
if docker --version; then
    info "Docker Engine successfully installed."
else
    error "Docker Engine installation verification failed."
fi

if docker compose version; then
    info "Docker Compose successfully installed."
else
    error "Docker Compose installation verification failed."
fi

# Attempt to install Docker credential helper for improved security
section "INSTALLING ADDITIONAL UTILITIES"
if apt-cache search --names-only docker-credential-helper >/dev/null 2>&1; then
    if apt-get install -y docker-credential-helpers 2>/dev/null || apt-get install -y golang-docker-credential-helpers 2>/dev/null; then
        info "Installed Docker credential helpers for secure credential storage."
    else
        warn "Docker credential helpers package could not be installed. Skipping this step."
    fi
else
    warn "Docker credential helpers package not found in repositories. Skipping this step."
fi

section "PERFORMING POST-INSTALLATION TASKS"
# Adjust kernel parameters for better Docker performance
cat > /etc/sysctl.d/99-docker-performance.conf <<EOL
# Increase max map count for Elasticsearch containers
vm.max_map_count = 262144

# Increase the maximum number of open files
fs.file-max = 1000000

# Optimize network settings
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
EOL

sysctl -p /etc/sysctl.d/99-docker-performance.conf || warn "Could not apply sysctl settings. May require a system restart."

# Configure logrotate for Docker logs
if [ -d /etc/logrotate.d ]; then
    cat > /etc/logrotate.d/docker <<EOL
/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    missingok
    delaycompress
    copytruncate
}
EOL
    info "Configured log rotation for Docker container logs."
fi

section "INSTALLATION COMPLETED SUCCESSFULLY"
info "Docker has been successfully installed and configured."
info "Installation log saved to: $LOG_FILE"
echo ""
echo "To verify installation, run as $ACTUAL_USER:"
echo "  docker run hello-world"
echo ""
echo "If you encounter permission errors, try logging out and back in,"
echo "or run 'newgrp docker' to refresh group membership."