provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "02-database-rds"
    }
  }
}

data "aws_caller_identity" "current" {}

# Lê o tfstate do stack 01 para obter VPC, subnets e SG do RDS
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "autoflow-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "network-eks/terraform.tfstate"
    region = var.region
  }
}
