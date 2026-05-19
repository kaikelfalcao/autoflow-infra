variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "autoflow"
}

variable "environment" {
  type    = string
  default = "dev"
}

# RDS
variable "db_engine_version" {
  type    = string
  default = "16.6"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_max_allocated_storage" {
  type    = number
  default = 50
}

variable "db_master_username" {
  description = "Master user para administração — cada microsserviço terá seu próprio user com escopo limitado"
  type        = string
  default     = "postgres"
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_backup_retention_period" {
  type    = number
  default = 1
}

variable "db_deletion_protection" {
  type    = bool
  default = false
}

variable "db_skip_final_snapshot" {
  type    = bool
  default = true
}

# Lista dos databases que serão criados via init SQL.
# Cada um terá um usuário próprio com permissão APENAS no seu database.
variable "service_databases" {
  description = "Lista (database_name → service_user) — um por microsserviço Postgres"
  type        = map(string)
  default = {
    identity = "identity_user"
    order    = "order_user"
    saga     = "saga_user"
    payment  = "payment_user"
  }
}
