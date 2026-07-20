#!/usr/bin/env bash
#
# Installer for Whonix-Workstation (KVM) users: installs Docker if needed,
# then hands off to setup.sh. Run it from a clone of this repo:
#
#     git clone <repo-url> && cd <repo> && ./install.sh
#
# Use --force to run on a non-Whonix machine.
#
set -euo pipefail
cd "$(dirname "$0")"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

FORCE=no
[ "${1:-}" = --force ] && FORCE=yes

is_whonix() {
    [ -e /usr/share/anon-ws-base-files/workstation ] ||
    grep -qi whonix /etc/os-release 2>/dev/null
}

if ! is_whonix && [ "$FORCE" != yes ]; then
    die "This does not look like a Whonix-Workstation.
This installer is meant to run inside the Workstation VM (all its traffic is
routed through the Whonix-Gateway). Use ./install.sh --force to run anyway,
or just run ./setup.sh directly on a normal machine."
fi

# ------------------------------------------------------------------ docker ---

have_docker() { command -v docker > /dev/null && docker compose version > /dev/null 2>&1; }

if have_docker; then
    log "Docker with compose v2 is already installed."
else
    log "Installing Docker (packages come through the torified apt — this can take a while)..."
    sudo apt-get update
    if apt-cache show docker-compose-v2 > /dev/null 2>&1; then
        sudo apt-get install -y docker.io docker-compose-v2
    else
        # Older Debian base without compose v2: use Docker's official repo.
        log "docker-compose-v2 not in the distro; adding Docker's official apt repository..."
        sudo apt-get install -y ca-certificates curl
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
            sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
    sudo systemctl enable --now docker
    have_docker || die "Docker installation did not succeed. Check the apt output above."
fi

# ------------------------------------------------------------- docker group ---

if id -nG "$USER" | grep -qw docker; then
    GROUP_OK=yes
else
    log "Adding $USER to the docker group..."
    sudo usermod -aG docker "$USER"
    GROUP_OK=no
fi

# ------------------------------------------------------------------- setup ---

if [ "${GROUP_OK}" = yes ] && docker info > /dev/null 2>&1; then
    exec ./setup.sh
else
    # Group membership isn't active in this shell yet; sg avoids a re-login.
    log "Starting setup via 'sg docker' (group change is not active in this shell yet)..."
    exec sg docker -c './setup.sh'
fi
