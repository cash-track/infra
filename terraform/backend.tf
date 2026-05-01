terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "cash-track-tfstate"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.68.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.23.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}
