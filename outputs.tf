output "instance_public_ip" {
  description = "Public IP address of the Pi-hole instance"
  value       = oci_core_instance.pihole.public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the Pi-hole instance"
  value       = oci_core_instance.pihole.private_ip
}

output "instance_ocid" {
  description = "OCID of the compute instance"
  value       = oci_core_instance.pihole.id
}

output "pihole_admin_url" {
  description = "Pi-hole web admin URL"
  value       = "http://${oci_core_instance.pihole.public_ip}/admin"
}

output "dns_server" {
  description = "DNS server address for client configuration"
  value       = oci_core_instance.pihole.public_ip
}

output "dot_server" {
  description = "DNS-over-TLS server address (use in clients as 'tls://<ip>')"
  value       = "${oci_core_instance.pihole.public_ip}:853"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh opc@${oci_core_instance.pihole.public_ip}"
}
