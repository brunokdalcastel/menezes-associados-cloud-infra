# ==============================================================================
# environments/menezes/variables.tf — Variáveis do Ambiente Menezes & Associados
# ==============================================================================
#
# Declara todas as variáveis de entrada para o ambiente de produção.
# Os valores são fornecidos via terraform.tfvars (não versionado, está no .gitignore)
# ou via variáveis de ambiente no CI/CD com prefixo TF_VAR_:
#   export TF_VAR_sharepoint_url="https://tenant.sharepoint.com/sites/juridico"
#
# Regra: values sensíveis (URLs, IDs) → terraform.tfvars local ou secrets CI/CD
#        Defaults públicos e não-sensíveis → podem ficar aqui
# ==============================================================================

# ------------------------------------------------------------------------------
# Gerais
# ------------------------------------------------------------------------------

variable "environment" {
  description = "Identificador do ambiente. Usado em tags e nomenclatura de recursos."
  type        = string
  default     = "prod"
}

variable "location" {
  description = "Região Azure para provisionamento dos recursos. Brazil South para compliance com LGPD."
  type        = string
  default     = "brazilsouth"
}

variable "tags" {
  description = <<-EOT
    Tags aplicadas a todos os recursos para governança, custo e rastreabilidade.
    Recomendadas para showback (quem usa o quê) e compliance:
      environment  → identifica o ciclo de vida do recurso
      project      → permite filtrar custos por projeto no Cost Management
      managed_by   → indica que não deve ser modificado manualmente
      cost_center  → centro de custo para showback/chargeback
      owner        → responsável técnico pelo recurso
  EOT
  type = map(string)
  default = {
    environment = "prod"
    project     = "menezes-associados"
    managed_by  = "terraform"
    cost_center = "juridico"
    owner       = "ti@menezesassociados.com.br"
  }
}

# ------------------------------------------------------------------------------
# Resource Group & Storage Account
# ------------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Nome do Resource Group principal. CAF: rg-{workload}-{env}-{region}-{seq}."
  type        = string
  default     = "rg-menezes-prod-brazilsouth-001"
}

variable "storage_account_name" {
  description = "Nome do Storage Account (globalmente único, 3-24 chars, lowercase/números)."
  type        = string
  default     = "stmenezesprod001"
}

# ------------------------------------------------------------------------------
# Azure Files — Histórico Jurídico
# ------------------------------------------------------------------------------

variable "file_share_name" {
  description = "Nome do File Share Azure Files montado como Z:\\ nos desktops do escritório."
  type        = string
  default     = "historico-juridico"
}

variable "file_share_quota" {
  description = "Quota máxima do File Share em GB. Atual: 1.6TB, provisionado: 2TB com margem."
  type        = number
  default     = 2048
}

# ------------------------------------------------------------------------------
# Blob Storage — Backup Semanal
# ------------------------------------------------------------------------------

variable "backup_container_name" {
  description = "Nome do Blob Container para backups semanais. Acesso privado, tier Archive via lifecycle."
  type        = string
  default     = "backup-semanal"
}

# ------------------------------------------------------------------------------
# Azure Automation
# ------------------------------------------------------------------------------

variable "automation_account_name" {
  description = "Nome do Automation Account. CAF: aa-{workload}-{env}-{region}-{seq}."
  type        = string
  default     = "aa-menezes-prod-brazilsouth-001"
}

variable "sharepoint_url" {
  description = <<-EOT
    URL completa do site SharePoint Online do escritório.
    Exemplo: "https://menezesassociados.sharepoint.com/sites/juridico"
    Obrigatório: sem default — deve ser fornecido via terraform.tfvars ou TF_VAR_sharepoint_url.
  EOT
  type = string
}

variable "sharepoint_doc_lib" {
  description = "Nome da biblioteca de documentos SharePoint de onde os arquivos inativos serão movidos."
  type        = string
  default     = "Documentos"
}

variable "schedule_start_time" {
  description = <<-EOT
    Data/hora de início do schedule mensal (ISO 8601 com offset UTC).
    Deve ser uma data futura. O dia do mês define o dia de execução recorrente.
    Padrão: 1º de abril de 2026 às 02h UTC (23h BRT do dia 31/03).
  EOT
  type    = string
  default = "2026-04-01T02:00:00+00:00"
}
