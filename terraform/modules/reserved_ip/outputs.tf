output "ip_address" {
  description = "The Reserved IPv4 address."
  value       = digitalocean_reserved_ip.main.ip_address
}
