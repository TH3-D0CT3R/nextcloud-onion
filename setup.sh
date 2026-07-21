#!/usr/bin/env bash
#
# One-shot bootstrap for the Tor-only Nextcloud stack. Idempotent: safe to
# re-run. Copy this whole folder to a new machine and run ./setup.sh.
#
# Modes (auto-detected, override with --mode):
#   standalone  Run Tor in a local container; prints the onion address when done.
#   whonix      No local Tor (that would be Tor-over-Tor). The stack is exposed
#               on the Workstation's internal interface; the script prints the
#               exact config to add on the Whonix-Gateway. After that, finish
#               with:  ./setup.sh --onion <address>.onion
#
set -euo pipefail
cd "$(dirname "$0")"

MODE=""
ONION=""

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)  MODE="$2"; shift 2 ;;
        --onion) ONION="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage 1 ;;
    esac
done

# ---------------------------------------------------------------- helpers ---

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

rand() { openssl rand -hex 24 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 48; }

# Read/write KEY=VALUE pairs in .env
env_get() { { [ -f .env ] && sed -n "s/^$1=//p" .env | head -n1; } || true; }
env_set() {
    if grep -q "^$1=" .env 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" .env
    else
        echo "$1=$2" >> .env
    fi
}

is_whonix() {
    [ -e /usr/share/anon-ws-base-files/workstation ] ||
    grep -qi whonix /etc/os-release 2>/dev/null
}

compose() {
    if [ "$MODE" = whonix ]; then
        docker compose -f docker-compose.yml -f docker-compose.whonix.yml "$@"
    else
        docker compose --profile standalone-tor "$@"
    fi
}

occ() { compose exec -T -u www-data app php occ "$@"; }

wait_for_install() {
    log "Waiting for Nextcloud to finish installing (first run takes a few minutes)..."
    local i
    for i in $(seq 1 120); do
        if occ status --output=json 2>/dev/null | grep -q '"installed":true'; then
            log "Nextcloud is installed."
            return 0
        fi
        sleep 5
    done
    die "Nextcloud did not come up in time. Check: docker compose logs app"
}

configure_onion() {
    local onion="$1"
    log "Configuring Nextcloud for http://$onion"
    occ config:system:set trusted_domains 1 --value="$onion" > /dev/null
    occ config:system:set overwrite.cli.url --value="http://$onion" > /dev/null
    # Plain HTTP is correct for onions: the Tor circuit already provides
    # end-to-end encryption and authenticates the endpoint.
    occ config:system:set overwriteprotocol --value=http > /dev/null
    occ config:system:set maintenance_window_start --type=integer --value=1 > /dev/null
    env_set NEXTCLOUD_TRUSTED_DOMAINS "$onion"
}

# The suite a click-through "recommended apps" install would give you, plus
# office editing through the built-in CODE server (served via the onion URL,
# no extra container).
RECOMMENDED_APPS="calendar contacts mail notes tasks spreed richdocuments richdocumentscode"

install_apps() {
    local app out
    log "Installing recommended apps (richdocumentscode is a ~400 MB download — slow over Tor)..."
    # On Whonix, Docker container traffic bypasses the transparent Tor proxy.
    # Point Nextcloud explicitly at the Gateway's SOCKS port for the duration.
    if [ "$MODE" = whonix ]; then
        occ config:system:set proxy --value="socks5h://10.152.152.10:9050" > /dev/null
    fi
    for app in $RECOMMENDED_APPS; do
        if occ app:list --output=json 2>/dev/null | grep -q "\"$app\""; then
            occ app:enable "$app" > /dev/null 2>&1 || true
            log "  enabled (bundled): $app"
        elif occ app:enable "$app" > /dev/null 2>&1; then
            log "  enabled: $app"
        elif out="$(occ app:install "$app" 2>&1)"; then
            log "  installed: $app"
        else
            warn "  could not install: $app — re-run ./setup.sh later to retry"
            [ -n "$out" ] && warn "    $out"
        fi
    done
    if [ "$MODE" = whonix ]; then
        occ config:system:delete proxy > /dev/null 2>&1 || true
    fi
}

# In standalone mode the app container has no internet route by design; attach
# it to the external network only for as long as the app store is needed.
install_apps_standalone() {
    local cid
    cid="$(compose ps -q app)"
    docker network connect nextcloud-onion_external "$cid" 2>/dev/null || true
    occ config:system:set has_internet_connection --type=boolean --value=true > /dev/null
    install_apps
    occ config:system:set has_internet_connection --type=boolean --value=false > /dev/null
    docker network disconnect nextcloud-onion_external "$cid" 2>/dev/null || true
}

print_credentials() {
    echo
    log "Admin login:  $(env_get NEXTCLOUD_ADMIN_USER) / $(env_get NEXTCLOUD_ADMIN_PASSWORD)"
    log "Credentials and secrets live in .env — keep it private."
}

# Whonix phase B: called with the onion address generated on the Gateway.
finish_with_onion() {
    local onion="$1"
    echo "$onion" | grep -Eq '^[a-z2-7]{56}\.onion$' || die "'$onion' is not a valid v3 onion address."
    wait_for_install
    configure_onion "$onion"
    install_apps
    echo
    log "Done. Nextcloud is reachable at:  http://$onion"
    print_credentials
}

# -------------------------------------------------------------- preflight ---

command -v docker > /dev/null || die "docker is not installed.
On Whonix/Debian:  sudo apt update && sudo apt install docker.io docker-compose-v2
Then:              sudo usermod -aG docker \$USER  (log out and back in)"
docker compose version > /dev/null 2>&1 || die "docker compose v2 is not available."
docker info > /dev/null 2>&1 || die "Cannot talk to the Docker daemon. Is it running, and are you in the docker group?"

# ------------------------------------------------------------------- mode ---

if [ -z "$MODE" ]; then
    MODE="$(env_get MODE)"
fi
if [ -z "$MODE" ]; then
    if is_whonix; then MODE=whonix; else MODE=standalone; fi
    log "Auto-detected mode: $MODE"
fi
[ "$MODE" = standalone ] || [ "$MODE" = whonix ] || die "--mode must be 'standalone' or 'whonix'"

# -------------------------------------------------------------------- .env ---

if [ ! -f .env ]; then
    log "Generating .env with fresh secrets"
    umask 077
    cat > .env <<EOF
MODE=$MODE
NEXTCLOUD_IMAGE=nextcloud:34-apache
DB_ROOT_PASSWORD=$(rand)
DB_PASSWORD=$(rand)
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=$(rand)
NEXTCLOUD_TRUSTED_DOMAINS=localhost
EOF
else
    env_set MODE "$MODE"
fi

if [ "$MODE" = whonix ] && [ -z "$(env_get WHONIX_BIND_IP)" ]; then
    # The Workstation's only interface leads to the Gateway, so binding its
    # primary IP (or all interfaces) exposes nothing beyond the Tor link.
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    env_set WHONIX_BIND_IP "${ip:-0.0.0.0}"
    log "Binding Nextcloud to ${ip:-0.0.0.0}:8080 for the Gateway (WHONIX_BIND_IP in .env)"
fi

# ------------------------------------------------- whonix phase B: --onion ---

if [ -n "$ONION" ]; then
    finish_with_onion "$ONION"
    exit 0
fi

# If the onion is already saved in .env (e.g. re-running after a network fix),
# skip phase A entirely and go straight to finishing.
if [ "$MODE" = whonix ]; then
    saved_onion="$(env_get NEXTCLOUD_TRUSTED_DOMAINS)"
    if echo "$saved_onion" | grep -Eq '^[a-z2-7]{56}\.onion$'; then
        log "Onion address already configured ($saved_onion) — skipping to app install."
        compose up -d
        finish_with_onion "$saved_onion"
        exit 0
    fi
fi

# ---------------------------------------------------------------- standalone ---

if [ "$MODE" = standalone ]; then
    log "Starting Tor to create the onion identity..."
    compose up -d --build tor

    onion=""
    for i in $(seq 1 24); do
        onion="$(compose exec -T tor cat /var/lib/tor/nextcloud/hostname 2>/dev/null | tr -d '[:space:]')" && [ -n "$onion" ] && break
        sleep 5
    done
    [ -n "$onion" ] || die "Tor did not publish an onion hostname. Check: docker compose --profile standalone-tor logs tor"
    log "Onion address: $onion"

    # Known before install, so the auto-installer trusts it from the start.
    env_set NEXTCLOUD_TRUSTED_DOMAINS "$onion"

    log "Starting the full stack..."
    compose up -d
    wait_for_install
    configure_onion "$onion"
    install_apps_standalone

    echo
    log "Done. Nextcloud is reachable ONLY at:  http://$onion"
    log "Open it in Tor Browser. Nothing is listening on this host's network interfaces."
    print_credentials
    exit 0
fi

# -------------------------------------------------------------- whonix phase A ---

log "Starting the stack (no local Tor on Whonix)..."
compose up -d
wait_for_install

bind_ip="$(env_get WHONIX_BIND_IP)"
echo
log "Nextcloud is running on the Workstation at $bind_ip:8080."
log "Now create the onion service on the Whonix-Gateway:"
cat <<EOF

  1. On the Gateway (Qubes: sys-whonix terminal; VirtualBox: Whonix-Gateway console):

       sudo mkdir -p /usr/local/etc/torrc.d
       sudo tee -a /usr/local/etc/torrc.d/50_user.conf <<'TORRC'
HiddenServiceDir /var/lib/tor/nextcloud
HiddenServicePort 80 $bind_ip:8080
TORRC
       sudo systemctl reload tor@default

  2. Read the generated address on the Gateway:

       sudo cat /var/lib/tor/nextcloud/hostname

  3. Back here on the Workstation, finish with:

       ./setup.sh --onion <that-address>.onion

EOF
warn "Back up /var/lib/tor/nextcloud/ on the Gateway — it IS your onion address."

if [ -t 0 ]; then
    echo
    printf '\033[1;32m==>\033[0m Paste the onion address here once the Gateway is configured (Enter to finish later): '
    read -r answer
    if [ -n "$answer" ]; then
        finish_with_onion "$answer"
    else
        log "Finish later with:  ./setup.sh --onion <address>.onion"
    fi
fi
