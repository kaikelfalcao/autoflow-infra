# Remote state armazenado em S3.
# O bucket é criado pelo script de bootstrap (scripts/bootstrap.sh).
# Nome derivado do account ID para ser único e reproduzível.

terraform {
  backend "s3" {
    bucket  = "autoflow-tfstate"     # sobrescrever via -backend-config se necessário
    key     = "network-eks/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
