#!/bin/bash
# ============================================================
#  dynamic-firewall.sh
#  Updates the firewalld ipset "home-ips" whenever the IP
#  address of ALLOWED_DYNAMIC_HOSTNAME changes.
#
#  Ports protected by the home-ips ipset (home-access zone):
#    22/tcp   – SSH
#    853/tcp  – DNS-over-TLS (CoreDNS DoT proxy)
#    80/tcp   – Pi-hole Web UI (HTTP)
#    443/tcp  – Pi-hole Web UI (HTTPS)
#
#  Runs every 60 seconds via:
#    /etc/systemd/system/dynamic-firewall.{service,timer}
#
#  Environment variable ALLOWED_DYNAMIC_HOSTNAME is loaded
#  from /etc/pihole/environment by the systemd service unit.
#
#  Installed to /usr/local/bin/ during cloud-init.
# ============================================================
set -euo pipefail

STATE_FILE=/var/run/dynamic-firewall.state
LOG=/var/log/dynamic-firewall.log
IPSET=home-ips

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# ─── Validate environment ─────────────────────────────────
if [ -z "${ALLOWED_DYNAMIC_HOSTNAME:-}" ]; then
    log "ERROR: ALLOWED_DYNAMIC_HOSTNAME is not set. Check /etc/pihole/environment."
    exit 1
fi

# ─── Resolve current IP ───────────────────────────────────
NEW_IP=$(dig +short "$ALLOWED_DYNAMIC_HOSTNAME" A \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | head -1 \
    || true)

if [ -z "$NEW_IP" ]; then
    log "WARNING: Could not resolve '$ALLOWED_DYNAMIC_HOSTNAME' — keeping current rules."
    exit 0
fi

# ─── Compare with last known IP ───────────────────────────
OLD_IP=$(cat "$STATE_FILE" 2>/dev/null || echo "")

if [ "$NEW_IP" = "$OLD_IP" ]; then
    exit 0   # Nothing changed — silent fast exit (runs every minute)
fi

log "IP change detected for $ALLOWED_DYNAMIC_HOSTNAME: '${OLD_IP:-<none>}' → '$NEW_IP'"

# ─── Update ipset (runtime + permanent) ───────────────────
# Runtime change takes effect immediately without firewall-cmd --reload.
# Permanent change survives firewalld restarts/reboots.

if [ -n "$OLD_IP" ]; then
    firewall-cmd --ipset="$IPSET" --remove-entry="$OLD_IP" 2>/dev/null || true
    firewall-cmd --permanent --ipset="$IPSET" --remove-entry="$OLD_IP" 2>/dev/null || true
fi

firewall-cmd --ipset="$IPSET" --add-entry="$NEW_IP"
firewall-cmd --permanent --ipset="$IPSET" --add-entry="$NEW_IP"

# ─── Persist new state ────────────────────────────────────
echo "$NEW_IP" > "$STATE_FILE"
log "Firewall updated: $ALLOWED_DYNAMIC_HOSTNAME → $NEW_IP (previous: ${OLD_IP:-<none>})"
