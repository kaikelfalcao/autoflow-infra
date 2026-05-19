terraform {
  backend "s3" {
    bucket  = "autoflow-tfstate"
    key     = "database-rds/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
