# Senha master (admin DB) — usada apenas para criar os usuários por serviço.
# Senhas de cada serviço são geradas individualmente.
resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "random_password" "service" {
  for_each = var.service_databases

  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+"
  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "aws_db_subnet_group" "this" {
  name        = "${var.project_name}-${var.environment}-db-subnet"
  description = "DB subnet group across private subnets from network stack"
  subnet_ids  = data.terraform_remote_state.network.outputs.private_subnet_ids

  tags = {
    Name = "${var.project_name}-${var.environment}-db-subnet"
  }
}

resource "aws_db_parameter_group" "pg16" {
  name_prefix = "${var.project_name}-${var.environment}-pg16-"
  family      = "postgres16"
  description = "PostgreSQL 16 parameter group"

  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "immediate"
  }
  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }
  # Lab dev: clientes Node-pg conectam sem TLS. Em prod deixe 1 e
  # configure cliente com ssl: { rejectUnauthorized: false }.
  parameter {
    name         = "rds.force_ssl"
    value        = "0"
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier = "${var.project_name}-${var.environment}-postgres"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  # O `db_name` aqui é só o database default (postgres) — os databases
  # de cada serviço serão criados via script de bootstrap (scripts/init-databases.sh)
  username = var.db_master_username
  password = random_password.master.result
  port     = 5432

  multi_az = var.db_multi_az

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [data.terraform_remote_state.network.outputs.rds_security_group_id]
  parameter_group_name   = aws_db_parameter_group.pg16.name

  backup_retention_period = var.db_backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${var.project_name}-${var.environment}-final-snapshot"

  copy_tags_to_snapshot = true
  publicly_accessible   = false

  tags = {
    Name = "${var.project_name}-${var.environment}-postgres"
  }
}
