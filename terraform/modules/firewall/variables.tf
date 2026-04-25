variable "name" {
  description = "Firewall name."
  type        = string
}

variable "droplet_ids" {
  description = "Droplet IDs (numeric) the firewall is attached to."
  type        = list(number)
}

variable "cf_ipv4" {
  description = "Cloudflare IPv4 ranges allowed inbound on TCP 80/443."
  type        = list(string)
}

variable "cf_ipv6" {
  description = "Cloudflare IPv6 ranges allowed inbound on TCP 80/443."
  type        = list(string)
}
