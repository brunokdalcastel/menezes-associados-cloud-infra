# ==============================================================================
# modules/automation/outputs.tf — Outputs do Módulo Automation
# ==============================================================================
#
# Expõe os atributos mais relevantes do Automation Account e seus recursos
# para uso pelo ambiente e para consulta pós-deploy (terraform output).
# ==============================================================================

# ------------------------------------------------------------------------------
# Automation Account
# ------------------------------------------------------------------------------

output "automation_account_id" {
  description = "Resource ID do Automation Account."
  value       = azurerm_automation_account.main.id
}

output "automation_account_name" {
  description = "Nome do Automation Account."
  value       = azurerm_automation_account.main.name
}

# ------------------------------------------------------------------------------
# Managed Identity
#
# Expor o Principal ID é importante para:
#   - Confirmar qual identidade recebeu os Role Assignments
#   - Configurar permissões adicionais futuras (ex: Graph API para SharePoint)
#   - Debugging de problemas de autorização
# ------------------------------------------------------------------------------

output "managed_identity_principal_id" {
  description = <<-EOT
    Principal ID da System Assigned Managed Identity do Automation Account.
    Use este ID para configurar permissões adicionais no SharePoint (Graph API):
      az ad app permission add --id <principal_id> --api <graph_app_id> --api-permissions Sites.ReadWrite.All=Role
  EOT
  value       = azurerm_automation_account.main.identity[0].principal_id
}

output "managed_identity_tenant_id" {
  description = "Tenant ID da Managed Identity (mesmo tenant do Automation Account)."
  value       = azurerm_automation_account.main.identity[0].tenant_id
}

# ------------------------------------------------------------------------------
# Runbook e Schedule
# ------------------------------------------------------------------------------

output "runbook_name" {
  description = "Nome do Runbook de tiering mensal."
  value       = azurerm_automation_runbook.tiering.name
}

output "runbook_id" {
  description = "Resource ID do Runbook."
  value       = azurerm_automation_runbook.tiering.id
}

output "schedule_name" {
  description = "Nome do Schedule configurado para execução mensal."
  value       = azurerm_automation_schedule.mensal.name
}

output "schedule_start_time" {
  description = "Data/hora de início do schedule (UTC). O recurso azurerm_automation_schedule não exporta next_run — use start_time como referência do horário configurado."
  value       = azurerm_automation_schedule.mensal.start_time
}
