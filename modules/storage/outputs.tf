# ==============================================================================
# modules/storage/outputs.tf — Outputs do Módulo Storage
# ==============================================================================
#
# Os outputs expõem atributos dos recursos criados para que:
#   1. O ambiente (environments/menezes/main.tf) possa passá-los ao módulo automation
#   2. O usuário possa consultá-los após o apply (terraform output)
#   3. Outros módulos futuros possam referenciar sem acessar o state diretamente
#
# Por que não usar data sources para referenciar esses recursos?
#   Outputs de módulo são mais explícitos, rastreáveis e não criam dependências
#   implícitas no state. Boa prática em composição de módulos Terraform.
# ==============================================================================

# ------------------------------------------------------------------------------
# Resource Group
# ------------------------------------------------------------------------------

output "resource_group_name" {
  description = "Nome do Resource Group criado pelo módulo."
  value       = azurerm_resource_group.main.name
}

output "resource_group_id" {
  description = "Resource ID completo do Resource Group. Útil para escopos de Policy e RBAC."
  value       = azurerm_resource_group.main.id
}

output "resource_group_location" {
  description = "Região onde o Resource Group foi criado."
  value       = azurerm_resource_group.main.location
}

# ------------------------------------------------------------------------------
# Storage Account
# ------------------------------------------------------------------------------

output "storage_account_id" {
  description = "Resource ID do Storage Account. Usado para Role Assignments e diagnósticos."
  value       = azurerm_storage_account.main.id
}

output "storage_account_name" {
  description = "Nome do Storage Account. Passado ao módulo automation como parâmetro do runbook."
  value       = azurerm_storage_account.main.name
}

output "storage_account_primary_file_endpoint" {
  description = "Endpoint do serviço Azure Files. Formato: https://{account}.file.core.windows.net/"
  value       = azurerm_storage_account.main.primary_file_endpoint
}

output "storage_account_primary_blob_endpoint" {
  description = "Endpoint do serviço Blob Storage. Formato: https://{account}.blob.core.windows.net/"
  value       = azurerm_storage_account.main.primary_blob_endpoint
}

# ------------------------------------------------------------------------------
# Azure File Share
# ------------------------------------------------------------------------------

output "file_share_name" {
  description = "Nome do File Share criado. Passado ao módulo automation como parâmetro do runbook."
  value       = azurerm_storage_share.historico.name
}

output "file_share_url" {
  description = "URL de acesso ao File Share via HTTPS."
  value       = azurerm_storage_share.historico.url
}

output "file_share_resource_manager_id" {
  description = <<-EOT
    Resource Manager ID do File Share no formato ARM.
    Usado como scope granular no Role Assignment do módulo automation:
    /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{sa}/fileServices/default/shares/{share}
  EOT
  value       = azurerm_storage_share.historico.resource_manager_id
}

# ------------------------------------------------------------------------------
# Blob Container (Backup)
# ------------------------------------------------------------------------------

output "backup_container_name" {
  description = "Nome do Blob Container de backup configurado com acesso privado."
  value       = azurerm_storage_container.backup.name
}

output "backup_container_id" {
  description = "Resource ID do Blob Container de backup."
  value       = azurerm_storage_container.backup.id
}
