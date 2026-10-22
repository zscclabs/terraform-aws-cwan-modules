terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Single provider: regional resources set `region` per resource (AWS provider v6+).
provider "aws" {
  region  = var.home_region
  profile = var.aws_profile
}
