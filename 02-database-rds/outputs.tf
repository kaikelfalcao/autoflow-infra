output "db_endpoint" {
  description = "RDS endpoint (host:port)"
  value       = aws_db_instance.this.endpoint
}

output "db_address" {
  description = "RDS hostname"
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "RDS port"
  value       = aws_db_instance.this.port
}

output "db_master_username" {
  value     = aws_db_instance.this.username
  sensitive = true
}

output "db_master_password" {
  description = "Master password — usado pelo bootstrap script para criar users por serviço"
  value       = random_password.master.result
  sensitive   = true
}

# Credenciais por serviço — consumidas pelos secrets de cada microsserviço
output "service_credentials" {
  description = "Map de serviço → {database, username, password} — armazenado em state criptografado no S3"
  value = {
    for db_name, user_name in var.service_databases :
    db_name => {
      database = db_name
      username = user_name
      password = random_password.service[db_name].result
    }
  }
  sensitive = true
}

# Comando para fazer o bootstrap dos databases e users via psql
output "bootstrap_command" {
  value = "./scripts/init-databases.sh"
}
