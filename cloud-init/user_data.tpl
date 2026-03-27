#!/bin/bash
# ============================================================
#  cloud-init user_data — Pi-hole on OCI Rocky Linux 9
#  Rendered by Terraform templatefile(); all $${...} below
#  that are NOT Terraform variables use $${...} escaping.
# ============================================================
set -euo pipefail

# ─── Terraform-injected configuration ─────────────────────
PIHOLE_PASSWORD='${pihole_password}'
PIHOLE_TZ='${pihole_timezone}'
ALLOWED_DYNAMIC_HOSTNAME='${allowed_dynamic_hostname}'
PIHOLE_DNS_UPSTREAM1='${pihole_dns_upstream1}'
PIHOLE_DNS_UPSTREAM2='${pihole_dns_upstream2}'

# ─── Logging ──────────────────────────────────────────────
LOG=/var/log/pihole-cloud-init.log
exec > >(tee -a "$LOG") 2>&1
echo "========================================================"
echo " Pi-hole cloud-init started: $(date)"
echo "========================================================"

# ─── 1. System update & base packages ─────────────────────
echo "[1/9] System update..."
dnf update -y --quiet
dnf install -y --quiet \
    curl wget git bind-utils jq openssl \
    firewalld python3-firewall

systemctl enable --now firewalld

# ─── 2. Install Docker from Docker's official RHEL repo ───
echo "[2/9] Installing Docker..."
dnf config-manager \
    --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
dnf install -y --quiet \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# Add opc user to docker group
usermod -aG docker opc

# ─── 3. Configure firewalld ───────────────────────────────
echo "[3/9] Configuring firewalld..."

# Default public zone: only plain DNS is open to everyone
firewall-cmd --permanent --zone=public --remove-service=dhcpv6-client 2>/dev/null || true
firewall-cmd --permanent --zone=public --remove-service=ssh 2>/dev/null || true
firewall-cmd --permanent --zone=public --add-port=53/tcp
firewall-cmd --permanent --zone=public --add-port=53/udp

# Create ipset for the dynamic home IP
firewall-cmd --permanent --new-ipset=home-ips --type=hash:ip 2>/dev/null || true

# Create home-access zone: SSH, DoT, Web UI – only for home-ips
firewall-cmd --permanent --new-zone=home-access 2>/dev/null || true
firewall-cmd --permanent --zone=home-access --add-source=ipset:home-ips
firewall-cmd --permanent --zone=home-access --add-port=22/tcp
firewall-cmd --permanent --zone=home-access --add-port=853/tcp
firewall-cmd --permanent --zone=home-access --add-port=80/tcp
firewall-cmd --permanent --zone=home-access --add-port=443/tcp

firewall-cmd --reload

# ─── 4. Resolve initial home IP and seed the ipset ────────
echo "[4/9] Seeding initial firewall rule for $ALLOWED_DYNAMIC_HOSTNAME..."
INITIAL_IP=$(dig +short "$ALLOWED_DYNAMIC_HOSTNAME" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
if [ -n "$INITIAL_IP" ]; then
    firewall-cmd --ipset=home-ips --add-entry="$INITIAL_IP"
    firewall-cmd --permanent --ipset=home-ips --add-entry="$INITIAL_IP"
    echo "$INITIAL_IP" > /var/run/dynamic-firewall.state
    echo "  → Initial IP: $INITIAL_IP"
else
    echo "  → WARNING: Could not resolve $ALLOWED_DYNAMIC_HOSTNAME — firewall not seeded."
fi

# ─── 5. Create Pi-hole directory structure ────────────────
echo "[5/9] Preparing Pi-hole directories..."
mkdir -p /opt/pihole/certs /opt/pihole/coredns

# Generate self-signed TLS certificate for DoT
openssl req -x509 -newkey rsa:4096 \
    -keyout /opt/pihole/certs/key.pem \
    -out    /opt/pihole/certs/cert.pem \
    -days 3650 -nodes \
    -subj "/CN=pihole-dot/O=Pi-hole/C=DE" \
    2>/dev/null
chmod 640 /opt/pihole/certs/key.pem /opt/pihole/certs/cert.pem

# ─── 6. Write config files ────────────────────────────────
echo "[6/9] Writing configuration files..."

# .env – secrets for docker compose
cat > /opt/pihole/.env << ENV_EOF
PIHOLE_PASSWORD=$PIHOLE_PASSWORD
PIHOLE_TZ=$PIHOLE_TZ
PIHOLE_DNS_UPSTREAM1=$PIHOLE_DNS_UPSTREAM1
PIHOLE_DNS_UPSTREAM2=$PIHOLE_DNS_UPSTREAM2
ENV_EOF
chmod 600 /opt/pihole/.env

# CoreDNS Corefile – accepts DoT on :853, forwards to Pi-hole
cat > /opt/pihole/coredns/Corefile << 'COREFILE_EOF'
tls://.:853 {
    tls /etc/coredns/certs/cert.pem /etc/coredns/certs/key.pem
    forward . pihole:53 {
        prefer_udp
    }
    log
    errors
    health :8081
}
COREFILE_EOF

# docker-compose.yml
# Note: $${VAR} here becomes $${VAR} in the file → docker compose expands from .env
cat > /opt/pihole/docker-compose.yml << 'COMPOSE_EOF'
# Pi-hole + CoreDNS DoT proxy
# Managed by Terraform / cloud-init — edit with care.
services:

  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    hostname: pihole
    restart: unless-stopped
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80/tcp"
      - "443:443/tcp"
    environment:
      TZ: "$${PIHOLE_TZ}"
      FTLCONF_webserver_api_password: "$${PIHOLE_PASSWORD}"
      FTLCONF_dns_upstreams: "$${PIHOLE_DNS_UPSTREAM1};$${PIHOLE_DNS_UPSTREAM2}"
      FTLCONF_dns_dnssec: "true"
      FTLCONF_dns_listeningMode: "all"
      FTLCONF_dns_blocking_enabled: "true"
    volumes:
      - pihole_data:/etc/pihole
      - dnsmasq_data:/etc/dnsmasq.d
    cap_add:
      - NET_ADMIN
    networks:
      - pihole_net

  coredns-dot:
    image: coredns/coredns:latest
    container_name: coredns-dot
    restart: unless-stopped
    command: -conf /etc/coredns/Corefile
    ports:
      - "853:853/tcp"
    volumes:
      - /opt/pihole/coredns:/etc/coredns:ro
      - /opt/pihole/certs:/etc/coredns/certs:ro
    depends_on:
      - pihole
    networks:
      - pihole_net

networks:
  pihole_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24

volumes:
  pihole_data:
  dnsmasq_data:
COMPOSE_EOF

# ─── 7. Write operational scripts ─────────────────────────
echo "[7/9] Installing operational scripts..."

# ── pihole-update.sh ──────────────────────────────────────
cat > /usr/local/bin/pihole-update.sh << 'SCRIPT_EOF'
#!/bin/bash
# Pi-hole container update manager.
# Usage:
#   pihole-update.sh check   – pull latest images; set pending flag if newer
#   pihole-update.sh apply   – apply pending update (called at 03:00 by cron)

set -euo pipefail

COMPOSE_FILE=/opt/pihole/docker-compose.yml
PENDING_FLAG=/var/run/pihole-update-pending
LOG=/var/log/pihole-update.log

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

check_for_update() {
    log "Checking for Pi-hole image updates..."
    BEFORE=$(docker image inspect pihole/pihole:latest --format='{{.Id}}' 2>/dev/null || echo "none")
    docker compose -f "$COMPOSE_FILE" pull --quiet 2>&1 | tee -a "$LOG"
    AFTER=$(docker image inspect pihole/pihole:latest --format='{{.Id}}' 2>/dev/null || echo "none")

    if [ "$BEFORE" != "$AFTER" ]; then
        log "New Pi-hole image detected — update pending until 03:00."
        touch "$PENDING_FLAG"
    else
        log "Images are up to date."
    fi
}

apply_update() {
    if [ ! -f "$PENDING_FLAG" ]; then
        log "No pending update."
        return 0
    fi
    log "Applying pending update..."
    docker compose -f "$COMPOSE_FILE" up -d --force-recreate --remove-orphans 2>&1 | tee -a "$LOG"
    docker image prune -f 2>&1 | tee -a "$LOG"
    rm -f "$PENDING_FLAG"
    log "Update applied successfully."
}

case "$${1:-}" in
    check) check_for_update ;;
    apply) apply_update ;;
    *)
        echo "Usage: $0 {check|apply}"
        exit 1
        ;;
esac
SCRIPT_EOF
chmod +x /usr/local/bin/pihole-update.sh

# ── dynamic-firewall.sh ────────────────────────────────────
cat > /usr/local/bin/dynamic-firewall.sh << 'SCRIPT_EOF'
#!/bin/bash
# Resolves ALLOWED_DYNAMIC_HOSTNAME every invocation.
# If the IP changed, the firewalld ipset 'home-ips' is updated
# so that SSH (22), DoT (853) and the web UI (80/443)
# are always accessible from the correct IP.
#
# Called every 60 s by the systemd timer dynamic-firewall.timer.

set -euo pipefail

STATE_FILE=/var/run/dynamic-firewall.state
LOG=/var/log/dynamic-firewall.log
IPSET=home-ips

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if [ -z "$${ALLOWED_DYNAMIC_HOSTNAME:-}" ]; then
    log "ERROR: ALLOWED_DYNAMIC_HOSTNAME is not set."
    exit 1
fi

NEW_IP=$(dig +short "$ALLOWED_DYNAMIC_HOSTNAME" A \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | head -1 || true)

if [ -z "$NEW_IP" ]; then
    log "WARNING: Could not resolve $ALLOWED_DYNAMIC_HOSTNAME — keeping current rules."
    exit 0
fi

OLD_IP=$(cat "$STATE_FILE" 2>/dev/null || echo "")

if [ "$NEW_IP" = "$OLD_IP" ]; then
    exit 0   # No change — fast exit, runs every minute
fi

log "IP changed: $${OLD_IP:-<none>} → $NEW_IP"

# Remove old entry (runtime + permanent)
if [ -n "$OLD_IP" ]; then
    firewall-cmd --ipset="$IPSET" --remove-entry="$OLD_IP" 2>/dev/null || true
    firewall-cmd --permanent --ipset="$IPSET" --remove-entry="$OLD_IP" 2>/dev/null || true
fi

# Add new entry (runtime + permanent)
firewall-cmd --ipset="$IPSET" --add-entry="$NEW_IP"
firewall-cmd --permanent --ipset="$IPSET" --add-entry="$NEW_IP"

echo "$NEW_IP" > "$STATE_FILE"
log "Firewall updated for $ALLOWED_DYNAMIC_HOSTNAME → $NEW_IP"
SCRIPT_EOF
chmod +x /usr/local/bin/dynamic-firewall.sh

# ─── 8. Systemd units ─────────────────────────────────────
echo "[8/9] Installing systemd units..."

# Environment file for dynamic firewall service
mkdir -p /etc/pihole
cat > /etc/pihole/environment << ENV_EOF
ALLOWED_DYNAMIC_HOSTNAME=$ALLOWED_DYNAMIC_HOSTNAME
ENV_EOF
chmod 600 /etc/pihole/environment

# dynamic-firewall.service
cat > /etc/systemd/system/dynamic-firewall.service << 'SVC_EOF'
[Unit]
Description=Dynamic Firewall – update home-ips ipset on hostname change
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/pihole/environment
ExecStart=/usr/local/bin/dynamic-firewall.sh
StandardOutput=journal
StandardError=journal
SVC_EOF

# dynamic-firewall.timer – every 60 seconds
cat > /etc/systemd/system/dynamic-firewall.timer << 'TMR_EOF'
[Unit]
Description=Run dynamic-firewall.service every 60 seconds
After=network-online.target

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
TMR_EOF

systemctl daemon-reload
systemctl enable --now dynamic-firewall.timer

# Cron jobs for Pi-hole auto-update
# Check every 4 hours; apply the pending update nightly at 03:00
cat > /etc/cron.d/pihole-update << 'CRON_EOF'
# Pi-hole update management
# Check for new images every 4 hours
0 */4 * * * root /usr/local/bin/pihole-update.sh check >> /var/log/pihole-update.log 2>&1
# Apply pending updates at 03:00 (maintenance window)
0 3 * * * root /usr/local/bin/pihole-update.sh apply >> /var/log/pihole-update.log 2>&1
CRON_EOF
chmod 644 /etc/cron.d/pihole-update

# ─── 9. Start containers ──────────────────────────────────
echo "[9/9] Starting Pi-hole and CoreDNS..."
cd /opt/pihole
docker compose up -d

# Wait for Pi-hole to become healthy
echo "Waiting for Pi-hole to be ready..."
for i in $(seq 1 30); do
    if docker exec pihole pihole status 2>/dev/null | grep -q "FTL is listening"; then
        echo "Pi-hole is ready!"
        break
    fi
    sleep 5
done

echo "========================================================"
echo " Setup complete: $(date)"
echo " Pi-hole admin : http://$(curl -s ifconfig.me)/admin"
echo " DoT server    : $(curl -s ifconfig.me):853"
echo "========================================================"
