terraform {
  required_providers {
    template = {
      source = "hashicorp/template"
      version = "~> 2.2.0"
    }
  }

  # backend "s3" {
  #   bucket         = "my-terraform-state-bucket"
  #   key            = "global/s3/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region
}
provider "template" {
  version = "~> 2.2.0"
}
