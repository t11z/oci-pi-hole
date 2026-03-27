#!/bin/bash
# ============================================================
#  pihole-update.sh
#  Pi-hole container update manager.
#
#  Strategy:
#    • Every 4 hours  → "check": pull latest images.
#                       If a newer image was downloaded, a
#                       flag file is created.
#    • Daily at 03:00 → "apply": if the flag exists, recreate
#                       the containers with the new image and
#                       prune dangling images.
#
#  Usage:
#    pihole-update.sh check
#    pihole-update.sh apply
#
#  Installed to /usr/local/bin/ during cloud-init.
#  Managed by /etc/cron.d/pihole-update.
# ============================================================
set -euo pipefail

COMPOSE_FILE=/opt/pihole/docker-compose.yml
PENDING_FLAG=/var/run/pihole-update-pending
LOG=/var/log/pihole-update.log

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

# ─── check ────────────────────────────────────────────────
# Pull all images declared in docker-compose.yml.
# If any digest changed, set the pending flag so that the
# 03:00 apply run knows to restart containers.
check_for_update() {
    log "Checking for image updates..."

    BEFORE_PIHOLE=$(docker image inspect pihole/pihole:latest \
        --format='{{.Id}}' 2>/dev/null || echo "none")
    BEFORE_COREDNS=$(docker image inspect coredns/coredns:latest \
        --format='{{.Id}}' 2>/dev/null || echo "none")

    docker compose -f "$COMPOSE_FILE" pull --quiet 2>&1 | tee -a "$LOG"

    AFTER_PIHOLE=$(docker image inspect pihole/pihole:latest \
        --format='{{.Id}}' 2>/dev/null || echo "none")
    AFTER_COREDNS=$(docker image inspect coredns/coredns:latest \
        --format='{{.Id}}' 2>/dev/null || echo "none")

    if [ "$BEFORE_PIHOLE" != "$AFTER_PIHOLE" ] || \
       [ "$BEFORE_COREDNS" != "$AFTER_COREDNS" ]; then
        log "New image(s) detected — update pending until 03:00 maintenance window."
        touch "$PENDING_FLAG"
    else
        log "All images are up to date."
    fi
}

# ─── apply ────────────────────────────────────────────────
# Recreate containers (causes a brief DNS outage ~5 s).
# Only runs if the pending flag is set.
apply_update() {
    if [ ! -f "$PENDING_FLAG" ]; then
        log "No pending update — nothing to do."
        return 0
    fi

    log "Applying update (maintenance window 03:00)..."
    docker compose -f "$COMPOSE_FILE" up -d \
        --force-recreate \
        --remove-orphans \
        2>&1 | tee -a "$LOG"

    docker image prune -f 2>&1 | tee -a "$LOG"
    rm -f "$PENDING_FLAG"
    log "Update applied successfully."
}

# ─── dispatch ─────────────────────────────────────────────
case "${1:-}" in
    check) check_for_update ;;
    apply) apply_update ;;
    *)
        echo "Usage: $0 {check|apply}" >&2
        exit 1
        ;;
esac
