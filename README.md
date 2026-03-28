# Pi-hole on OCI Ampere — Free Tier

> Encrypted, ad-free DNS for your home network, running 24/7 on Oracle Cloud's **always-free** Ampere (ARM) instance — fully automated with Terraform.

```
  Your Home                       OCI Free Tier (Ampere A1)
  ──────────                       ──────────────────────────────────────────────
                                  ┌─────────────────────────────────────────────┐
  Laptop / Phone                  │  Ubuntu 24.04                               │
  ┌──────────┐   DoT :853 (TLS)  │  ┌─────────────────┐   ┌─────────────────┐ │
  │  Client  │ ────────────────► │  │  CoreDNS (DoT)  │──►│    Pi-hole      │ │
  └──────────┘                   │  │   port 853      │   │   port 53       │ │
                                  │  └─────────────────┘   └────────┬────────┘ │
  Router                         │                                   │          │
  ┌──────────┐   DNS  :53        │                          DoT upstream        │
  │ DNS cfg  │ ────────────────► │  ◄────────────────────  tls://1.1.1.1       │
  └──────────┘                   │                          tls://1.0.0.1       │
                                  │                                              │
  Admin Browser                  │  ┌──────────────────────────────────────┐   │
  ┌──────────┐   HTTP :80/443    │  │  firewalld                           │   │
  │ Web UI   │ ────────────────► │  │  • port 53    → open to all          │   │
  └──────────┘                   │  │  • port 22    ┐                      │   │
                                  │  │  • port 853   ├─ home-ips ipset only │   │
  home.example.com                │  │  • port 80/443┘  (updated every 60s) │   │
  ┌──────────┐   resolved every  │  └──────────────────────────────────────┘   │
  │ DynDNS   │   60 seconds ───► │                                              │
  └──────────┘                   └─────────────────────────────────────────────┘
```

## Features

| Feature | Details |
|---|---|
| **Cloud** | Oracle Cloud Infrastructure — Always Free Tier |
| **Instance** | `VM.Standard.A1.Flex` · Ampere ARM64 · 2 vCPU · 12 GiB RAM |
| **OS** | Ubuntu 24.04 LTS |
| **DNS** | Pi-hole latest (Docker) |
| **Upstream** | DNS-over-TLS to Cloudflare / Google / Quad9 |
| **DoT server** | CoreDNS on port 853 — clients connect with encrypted DNS |
| **Auto-update** | Image checked every 4 h · applied nightly at **03:00** |
| **Dynamic firewall** | SSH + DoT + Web UI restricted to your DynDNS hostname · updated every **60 s** |
| **IaC** | Terraform · single `terraform apply` |

---

## Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| Terraform | 1.3 | [developer.hashicorp.com](https://developer.hashicorp.com/terraform/install) |
| OCI CLI | 3.x | `pip install oci-cli` or [docs.oracle.com](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) |
| OCI Account | Free Tier | [signup.cloud.oracle.com](https://signup.cloud.oracle.com) |

You also need:
- An **OCI API signing key** (`~/.oci/oci_api_key.pem` + fingerprint)
- An **SSH key pair** (e.g., `ssh-keygen -t ed25519`)
- A **DynDNS hostname** that points to your home IP (e.g., [DuckDNS](https://www.duckdns.org))

---

## Quick Start

### 1. Clone & configure

```bash
git clone https://github.com/t11z/oci-pi-hole.git
cd oci-pi-hole

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values (see Configuration section)
$EDITOR terraform.tfvars
```

### 2. Initialize Terraform

```bash
terraform init
```

### 3. Preview the plan

```bash
terraform plan
```

### 4. Deploy

```bash
terraform apply
```

Terraform will print the public IP and all relevant URLs when done. The instance takes **3–5 minutes** to fully configure itself via cloud-init.

### 5. Monitor cloud-init progress

```bash
# SSH in (your DynDNS hostname must resolve first)
ssh ubuntu@<public-ip>

# Watch setup log
sudo tail -f /var/log/pihole-cloud-init.log
```

### 6. Configure your devices

| Protocol | Address |
|---|---|
| Plain DNS | `<public-ip>:53` |
| DNS-over-TLS | `<public-ip>:853` |
| Web admin | `http://<public-ip>/admin` |

---

## Configuration Reference

All variables are defined in `variables.tf`. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in your values.

### OCI Authentication

```hcl
tenancy_ocid     = "ocid1.tenancy.oc1..aaa..."
user_ocid        = "ocid1.user.oc1..aaa..."
fingerprint      = "aa:bb:cc:..."
private_key_path = "~/.oci/oci_api_key.pem"
region           = "eu-frankfurt-1"
compartment_ocid = "ocid1.compartment.oc1..aaa..."
```

> **Tip:** Run `oci setup config` to generate the API key and populate these values automatically.

### Instance sizing

```hcl
instance_ocpus          = 2     # Free Tier total: 4 OCPUs
instance_memory_in_gbs  = 12    # Free Tier total: 24 GiB
boot_volume_size_in_gbs = 50    # Free Tier total: 200 GiB block storage
```

### Ubuntu image

The provider searches for the latest Ubuntu 24.04 image for the `VM.Standard.A1.Flex` shape automatically. If your region doesn't have it or you want a specific version, override it:

```hcl
image_ocid = "ocid1.image.oc1.eu-frankfurt-1.aaa..."
```

Find OCIDs via CLI:
```bash
oci compute image list \
  --compartment-id <compartment_ocid> \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" \
  --shape VM.Standard.A1.Flex \
  --query "data[0].id" --raw-output
```

### Pi-hole

```hcl
pihole_password      = "change-me-please"
timezone             = "Europe/Berlin"
pihole_dns_upstream1 = "tls://1.1.1.1"   # Cloudflare DoT
pihole_dns_upstream2 = "tls://1.0.0.1"   # Cloudflare DoT (secondary)
```

Popular upstream options:

| Provider | DoT primary | DoT secondary |
|---|---|---|
| Cloudflare | `tls://1.1.1.1` | `tls://1.0.0.1` |
| Google | `tls://8.8.8.8` | `tls://8.8.4.4` |
| Quad9 | `tls://9.9.9.9` | `tls://149.112.112.112` |

### Dynamic Firewall

```hcl
allowed_dynamic_hostname = "myhome.duckdns.org"
```

Every 60 seconds the instance resolves this hostname. If the IP changed, the `home-ips` firewalld ipset is updated and the following ports become accessible only from that IP:

- **22/tcp** — SSH
- **853/tcp** — DNS-over-TLS
- **80/tcp** — Pi-hole Web UI (HTTP)
- **443/tcp** — Pi-hole Web UI (HTTPS)

Port **53** (plain DNS) remains open to everyone so devices on other networks can still use the resolver.

---

## Architecture Deep Dive

### DNS-over-TLS (DoT) Stack

```
Client (port 853, TLS)
  │
  ▼
CoreDNS container          ← handles TLS termination
  │  /opt/pihole/certs/cert.pem  (self-signed, 10 years)
  │  /opt/pihole/certs/key.pem
  ▼
Pi-hole container (port 53, plaintext, Docker network only)
  │
  ▼
Upstream resolver (tls://1.1.1.1:853)  ← Pi-hole FTL uses DoT upstream
```

A **self-signed certificate** is generated during provisioning. To use a trusted certificate (e.g., Let's Encrypt), see [Using a trusted TLS certificate](#using-a-trusted-tls-certificate).

### Auto-update Logic

```
Every 4 hours (cron)
  └─ pihole-update.sh check
       ├─ docker compose pull (all images)
       └─ if new digest → touch /var/run/pihole-update-pending

Daily at 03:00 (cron)
  └─ pihole-update.sh apply
       ├─ if /var/run/pihole-update-pending exists:
       │    docker compose up -d --force-recreate
       │    docker image prune -f
       │    rm pending-flag
       └─ else: no-op (log entry only)
```

Brief DNS outage (~5 seconds) during the 03:00 restart. Pi-hole data (block lists, query log, settings) is persisted in named Docker volumes.

### Dynamic Firewall

```
systemd timer (every 60 s)
  └─ dynamic-firewall.service
       └─ dynamic-firewall.sh
            ├─ dig +short $ALLOWED_DYNAMIC_HOSTNAME A
            ├─ compare with /var/run/dynamic-firewall.state
            └─ if changed:
                 firewall-cmd --ipset=home-ips --remove-entry OLD_IP
                 firewall-cmd --ipset=home-ips --add-entry   NEW_IP
                 firewall-cmd --permanent ...  (survives reboots)
                 echo NEW_IP > state-file
```

---

## Maintenance

### View logs

```bash
# Cloud-init setup (one-time)
sudo cat /var/log/pihole-cloud-init.log

# Auto-update activity
sudo tail -f /var/log/pihole-update.log

# Dynamic firewall changes
sudo tail -f /var/log/dynamic-firewall.log

# Pi-hole FTL log
docker exec pihole tail -f /var/log/pihole/pihole.log
```

### Pi-hole CLI

```bash
# Status
docker exec pihole pihole status

# Update blocklists
docker exec pihole pihole updateGravity

# Temporarily disable for 5 minutes
docker exec pihole pihole disable 5m
```

### Trigger an immediate update

```bash
sudo /usr/local/bin/pihole-update.sh check
sudo /usr/local/bin/pihole-update.sh apply
```

### Manually update the firewall

```bash
sudo /usr/local/bin/dynamic-firewall.sh
# Check current ipset contents:
sudo firewall-cmd --ipset=home-ips --get-entries
```

### Using a trusted TLS certificate

Replace the self-signed certificate with a Let's Encrypt cert using [certbot](https://certbot.eff.org/):

```bash
# On the instance (requires a domain pointing to the public IP)
sudo apt-get install -y certbot

sudo certbot certonly --standalone \
    -d your.domain.example \
    --pre-hook  "docker stop coredns-dot" \
    --post-hook "docker start coredns-dot"

sudo cp /etc/letsencrypt/live/your.domain.example/fullchain.pem /opt/pihole/certs/cert.pem
sudo cp /etc/letsencrypt/live/your.domain.example/privkey.pem   /opt/pihole/certs/key.pem
sudo chmod 640 /opt/pihole/certs/*.pem

docker restart coredns-dot
```

Add a cron entry to renew and copy automatically:
```bash
# /etc/cron.d/certbot-pihole
0 0 * * 0 root certbot renew --quiet && \
    cp /etc/letsencrypt/live/your.domain/fullchain.pem /opt/pihole/certs/cert.pem && \
    cp /etc/letsencrypt/live/your.domain/privkey.pem /opt/pihole/certs/key.pem && \
    docker restart coredns-dot
```

### Destroy infrastructure

```bash
terraform destroy
```

> **Warning:** This permanently deletes the instance and all volumes including Pi-hole settings and query history.

---

## Security Notes

- **OCI Security List** opens ports broadly at the network layer; fine-grained access control is handled by **firewalld** on the instance.
- **SSH and DoT** are restricted to a single dynamic IP — brute-force exposure is minimal.
- **Pi-hole web UI** is not publicly accessible; it is also restricted to the dynamic IP.
- The **self-signed DoT certificate** prevents passive eavesdropping but does not authenticate the server to clients. Use a proper CA-signed cert for production.
- Pi-hole container runs with `cap_add: NET_ADMIN` (required for DHCP and certain DNS modes).
- The `.env` file at `/opt/pihole/.env` contains the Pi-hole password in plaintext — it is `chmod 600` and readable only by root.
- **Terraform state** (`terraform.tfstate`) contains sensitive values. Store it remotely (OCI Object Storage backend) and never commit it to version control.

---

## File Structure

```
oci-pi-hole/
├── main.tf                    # VCN, subnet, security list, instance
├── variables.tf               # All input variables
├── outputs.tf                 # Public IP, URLs, SSH command
├── terraform.tfvars.example   # Template — copy to terraform.tfvars
├── cloud-init/
│   └── user_data.tpl          # Full provisioning script (Terraform template)
└── scripts/                   # Reference copies of scripts installed on instance
    ├── pihole-update.sh       # Installed to /usr/local/bin/
    └── dynamic-firewall.sh    # Installed to /usr/local/bin/
```

---

## Free Tier Limits

| Resource | Free Tier limit | This deployment |
|---|---|---|
| A1 OCPUs | 4 total | 2 |
| A1 Memory | 24 GiB total | 12 GiB |
| Block storage | 200 GiB total | 50 GiB boot volume |
| Public IPs | 2 | 1 |
| VCNs | 2 | 1 |
| Outbound data | 10 TB/month | Typically < 1 GB |

If you already have other A1 instances, adjust `instance_ocpus` and `instance_memory_in_gbs` so the total stays within the free tier limits.

---

## License

MIT — see [LICENSE](LICENSE).
