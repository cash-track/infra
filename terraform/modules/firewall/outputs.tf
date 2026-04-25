output "firewall_id" {
  description = "DigitalOcean firewall ID."
  value       = digitalocean_firewall.cashtrack.id
}
