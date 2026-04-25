output "volume_id" {
  description = "Block volume ID."
  value       = digitalocean_volume.data.id
}

output "volume_name" {
  description = "Block volume name (matches input; exposed for downstream modules)."
  value       = digitalocean_volume.data.name
}
