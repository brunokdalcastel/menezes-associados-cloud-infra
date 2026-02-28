# ==============================================================================
# modules/automation/variables.tf — Variáveis do Módulo Automation
# ==============================================================================
#
# Variáveis de entrada do módulo de automação. São fornecidas pelo ambiente
# (environments/menezes/main.tf) e incluem tanto configurações do Automation
# Account quanto referências aos recursos criados pelo módulo storage.
# ==============================================================================

# ------------------------------------------------------------------------------
# Identificação do Ambiente
# ------------------------------------------------------------------------------

variable "environment" {
  description = "Nome do ambiente: prod, staging ou dev."
  type        = string

  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "O ambiente deve ser 'prod', 'staging' ou 'dev'."
  }
}

variable "location" {
  description = "Região Azure onde o Automation Account será criado."
  type        = string
  default     = "brazilsouth"
}

# ------------------------------------------------------------------------------
# Resource Group
# ------------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Nome do Resource Group onde o Automation Account será criado (criado pelo módulo storage)."
  type        = string
}

# ------------------------------------------------------------------------------
# Automation Account
# ------------------------------------------------------------------------------

variable "automation_account_name" {
  description = "Nome do Automation Account. Convenção CAF: aa-{workload}-{env}-{region}-{seq}."
  type        = string
}

# ------------------------------------------------------------------------------
# Runbook
# ------------------------------------------------------------------------------

variable "runbook_content" {
  description = <<-EOT
    Conteúdo completo do script PowerShell para o runbook de tiering.
    Carregado via file() no ambiente: file("../../scripts/tiering-runbook.ps1")
  EOT
  type      = string
  sensitive = false # Script não contém credenciais (usa Managed Identity)
}

# ------------------------------------------------------------------------------
# SharePoint — Parâmetros do Runbook
# ------------------------------------------------------------------------------

variable "sharepoint_url" {
  description = "URL do site SharePoint Online. Ex: https://tenant.sharepoint.com/sites/juridico"
  type        = string
}

variable "sharepoint_doc_lib" {
  description = "Nome da biblioteca de documentos SharePoint de onde os arquivos serão movidos."
  type        = string
  default     = "Documentos"
}

# ------------------------------------------------------------------------------
# Storage Account — Referências do Módulo Storage
# ------------------------------------------------------------------------------

variable "storage_account_id" {
  description = "Resource ID do Storage Account (output do módulo storage). Usado no Role Assignment Blob."
  type        = string
}

variable "storage_account_name" {
  description = "Nome do Storage Account. Passado como parâmetro ao runbook para autenticação via contexto."
  type        = string
}

variable "file_share_id" {
  description = <<-EOT
    Resource Manager ID do File Share (output do módulo storage).
    Usado como scope granular no Role Assignment SMB — princípio do menor privilégio.
    Formato: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Storage/
             storageAccounts/{sa}/fileServices/default/shares/{share}
  EOT
  type = string
}

variable "file_share_name" {
  description = "Nome do File Share Azure Files. Passado como parâmetro ao runbook."
  type        = string
}

# ------------------------------------------------------------------------------
# Schedule
# ------------------------------------------------------------------------------

variable "schedule_start_time" {
  description = <<-EOT
    Data e hora de início do schedule mensal (ISO 8601 com timezone).
    Deve ser uma data futura — o dia do mês define o dia recorrente de execução.
    Formato: "2026-04-01T02:00:00+00:00" (02h UTC = 23h BRT do dia anterior)
  EOT
  type    = string
  default = "2026-04-01T02:00:00+00:00"
}

# ------------------------------------------------------------------------------
# Tags
# ------------------------------------------------------------------------------

variable "tags" {
  description = "Mapa de tags aplicadas aos recursos de automação."
  type        = map(string)
  default     = {}
}
