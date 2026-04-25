variable "region" {
  description = "DigitalOcean region slug for the Reserved IP (must match the droplet region)."
  type        = string
}

variable "droplet_id" {
  description = "Droplet ID to receive the Reserved IP assignment."
  type        = number
}
