# ============================================================
#  variables.tf — Pi-hole on OCI Ampere Free Tier
# ============================================================

# ─── OCI Authentication ───────────────────────────────────

variable "tenancy_ocid" {
  description = "OCID of your OCI tenancy"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the OCI user used for API calls"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the API signing key"
  type        = string
}

variable "private_key_path" {
  description = "Local path to the OCI API private key (PEM)"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "OCI region identifier (e.g. eu-frankfurt-1)"
  type        = string
  default     = "eu-frankfurt-1"
}

variable "compartment_ocid" {
  description = "OCID of the compartment where resources are created"
  type        = string
}

# ─── Availability ─────────────────────────────────────────

variable "availability_domain_index" {
  description = "0-based index of the availability domain to use"
  type        = number
  default     = 0
}

# ─── Instance ─────────────────────────────────────────────

variable "instance_ocpus" {
  description = "Number of OCPUs for the Ampere instance (Free Tier: up to 4 across all A1 instances)"
  type        = number
  default     = 2
}

variable "instance_memory_in_gbs" {
  description = "RAM in GiB (Free Tier: up to 24 GiB across all A1 instances)"
  type        = number
  default     = 12
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GiB (Free Tier: 200 GiB total block storage)"
  type        = number
  default     = 50
}

variable "image_ocid" {
  description = <<-EOT
    Explicit Ubuntu 24.04 image OCID. Leave empty to auto-detect.
    Find available OCIDs via:
    oci compute image list --compartment-id <ocid> --operating-system "Canonical Ubuntu" --shape VM.Standard.A1.Flex
  EOT
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key (content, not path) placed in authorized_keys on the instance"
  type        = string
}

# ─── Networking ───────────────────────────────────────────

variable "vcn_cidr" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

# ─── Pi-hole ──────────────────────────────────────────────

variable "pihole_password" {
  description = "Password for the Pi-hole web admin interface"
  type        = string
  sensitive   = true
}

variable "timezone" {
  description = "Timezone for the instance and Pi-hole container (e.g. Europe/Berlin)"
  type        = string
  default     = "Europe/Berlin"
}

variable "pihole_dns_upstream1" {
  description = <<-EOT
    Primary upstream DNS resolver. Use 'tls://ip' for DNS-over-TLS.
    Examples: tls://1.1.1.1  |  tls://8.8.8.8  |  1.1.1.1
  EOT
  type        = string
  default     = "tls://1.1.1.1"
}

variable "pihole_dns_upstream2" {
  description = "Secondary upstream DNS resolver (same format as pihole_dns_upstream1)"
  type        = string
  default     = "tls://1.0.0.1"
}

# ─── Dynamic Firewall ─────────────────────────────────────

variable "allowed_dynamic_hostname" {
  description = <<-EOT
    Dynamic DNS hostname (e.g. myhome.duckdns.org) that is resolved every
    60 seconds. Firewall rules for SSH (22) and DoT (853) are updated
    automatically whenever the resolved IP changes.
  EOT
  type        = string
}
