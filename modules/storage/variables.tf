# ==============================================================================
# modules/storage/variables.tf — Variáveis do Módulo Storage
# ==============================================================================
#
# Todas as variáveis de entrada que o módulo de storage aceita.
# São fornecidas pelo ambiente (environments/menezes/main.tf) no momento
# da invocação do módulo.
#
# Boas práticas seguidas aqui:
#   - description em todas as variáveis (documentação viva)
#   - type explícito (evita coerções inesperadas)
#   - validation blocks para capturar erros cedo
#   - default apenas onde faz sentido ter um valor padrão seguro
# ==============================================================================

# ------------------------------------------------------------------------------
# Identificação do Ambiente
# ------------------------------------------------------------------------------

variable "environment" {
  description = "Nome do ambiente: prod, staging ou dev. Usado em tags e nomenclatura."
  type        = string

  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "O ambiente deve ser 'prod', 'staging' ou 'dev'."
  }
}

variable "location" {
  description = "Região Azure onde os recursos serão provisionados. Ex: brazilsouth, eastus2."
  type        = string
  default     = "brazilsouth"
}

# ------------------------------------------------------------------------------
# Resource Group
# ------------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Nome do Resource Group a ser criado. Convenção CAF: rg-{workload}-{env}-{region}-{seq}."
  type        = string
}

# ------------------------------------------------------------------------------
# Storage Account
# ------------------------------------------------------------------------------

variable "storage_account_name" {
  description = <<-EOT
    Nome do Storage Account. Deve ser globalmente único no Azure.
    Restrições: 3-24 caracteres, somente letras minúsculas e números (sem hífens).
    Convenção CAF: st{workload}{env}{seq} → ex: stmenezesprod001
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage Account name deve ter entre 3-24 caracteres, somente letras minúsculas e números (sem hífens ou underscores)."
  }
}

# ------------------------------------------------------------------------------
# Azure Files — File Share (Histórico Jurídico)
# ------------------------------------------------------------------------------

variable "file_share_name" {
  description = "Nome do File Share para os arquivos históricos do escritório (montado como Z:\\)."
  type        = string
  default     = "historico-juridico"
}

variable "file_share_quota" {
  description = "Quota máxima do File Share em GB. Mínimo: 1. Máximo: 102400 (100 TB)."
  type        = number
  default     = 2048 # 2 TB — margem para crescimento a partir dos 1.6 TB atuais

  validation {
    condition     = var.file_share_quota >= 1 && var.file_share_quota <= 102400
    error_message = "A quota do File Share deve estar entre 1 GB e 102400 GB (100 TB)."
  }
}

# ------------------------------------------------------------------------------
# Blob Storage — Container de Backup
# ------------------------------------------------------------------------------

variable "backup_container_name" {
  description = "Nome do Blob Container que receberá os backups semanais. Acesso: private."
  type        = string
  default     = "backup-semanal"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.backup_container_name))
    error_message = "Container name deve ter 3-63 caracteres, iniciar e terminar com letra/número, somente minúsculas, números e hífens."
  }
}

# ------------------------------------------------------------------------------
# Tags (Governança e FinOps)
# ------------------------------------------------------------------------------

variable "tags" {
  description = <<-EOT
    Mapa de tags aplicadas a todos os recursos criados pelo módulo.
    Tags recomendadas para governança:
      environment  = "prod"
      project      = "menezes-associados"
      managed_by   = "terraform"
      cost_center  = "juridico"
      owner        = "email@dominio.com.br"
  EOT
  type        = map(string)
  default     = {}
}
