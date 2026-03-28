terraform {
  required_version = ">= 1.3"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# ─── Data Sources ─────────────────────────────────────────

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  ad_name = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
}

# Ubuntu 24.04 image – auto-detected unless overridden via var.image_ocid
data "oci_core_images" "ubuntu" {
  count = var.image_ocid == "" ? 1 : 0

  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
}

locals {
  instance_image_id = var.image_ocid != "" ? var.image_ocid : try(data.oci_core_images.ubuntu[0].images[0].id, null)
}

# ─── VCN ──────────────────────────────────────────────────

resource "oci_core_vcn" "pihole" {
  compartment_id = var.compartment_ocid
  cidr_block     = var.vcn_cidr
  display_name   = "pihole-vcn"
  dns_label      = "piholevcn"
}

resource "oci_core_internet_gateway" "pihole" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.pihole.id
  display_name   = "pihole-igw"
  enabled        = true
}

resource "oci_core_route_table" "pihole" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.pihole.id
  display_name   = "pihole-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.pihole.id
  }
}

# ─── Security List ────────────────────────────────────────
# OCI is the outer perimeter; fine-grained dynamic-IP rules
# are handled by firewalld on the instance itself.

resource "oci_core_security_list" "pihole" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.pihole.id
  display_name   = "pihole-sl"

  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
    description = "Allow all outbound traffic"
  }

  # SSH – further restricted to ALLOWED_DYNAMIC_HOSTNAME by firewalld
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    stateless   = false
    description = "SSH (OS firewall restricts to dynamic hostname)"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # DNS over TCP
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    stateless   = false
    description = "DNS/TCP – open to all clients"
    tcp_options {
      min = 53
      max = 53
    }
  }

  # DNS over UDP
  ingress_security_rules {
    protocol    = "17"
    source      = "0.0.0.0/0"
    stateless   = false
    description = "DNS/UDP – open to all clients"
    udp_options {
      min = 53
      max = 53
    }
  }

  # DoT – further restricted to ALLOWED_DYNAMIC_HOSTNAME by firewalld
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    stateless   = false
    description = "DNS-over-TLS (OS firewall restricts to dynamic hostname)"
    tcp_options {
      min = 853
      max = 853
    }
  }

  # Pi-hole Web UI – further restricted by firewalld
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    stateless   = false
    description = "Pi-hole Web UI HTTP (OS firewall restricts to dynamic hostname)"
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    stateless   = false
    description = "Pi-hole Web UI HTTPS (OS firewall restricts to dynamic hostname)"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # ICMP ping/traceroute
  ingress_security_rules {
    protocol    = "1"
    source      = "0.0.0.0/0"
    stateless   = false
    description = "ICMP echo"
    icmp_options {
      type = 8
      code = 0
    }
  }
}

# ─── Subnet ───────────────────────────────────────────────

resource "oci_core_subnet" "pihole" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.pihole.id
  cidr_block        = var.subnet_cidr
  display_name      = "pihole-subnet"
  dns_label         = "piholesubnet"
  route_table_id    = oci_core_route_table.pihole.id
  security_list_ids = [oci_core_security_list.pihole.id]
}

# ─── Compute Instance ─────────────────────────────────────

resource "oci_core_instance" "pihole" {
  compartment_id      = var.compartment_ocid
  availability_domain = local.ad_name
  display_name        = "pihole"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = local.instance_image_id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.pihole.id
    display_name     = "pihole-vnic"
    assign_public_ip = true
    hostname_label   = "pihole"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/cloud-init/user_data.tpl", {
      pihole_password          = var.pihole_password
      pihole_timezone          = var.timezone
      allowed_dynamic_hostname = var.allowed_dynamic_hostname
      pihole_dns_upstream1      = var.pihole_dns_upstream1
      pihole_dns_upstream2      = var.pihole_dns_upstream2
      pihole_dns_tls_servername = var.pihole_dns_tls_servername
    }))
  }

  lifecycle {
    precondition {
      condition     = local.instance_image_id != null
      error_message = "No Ubuntu 24.04 image found for shape VM.Standard.A1.Flex in this region/compartment. Set var.image_ocid explicitly."
    }
  }

  timeouts {
    create = "30m"
  }
}
