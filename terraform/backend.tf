terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "cash-track-tfstate"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
