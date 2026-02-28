# ==============================================================================
# providers.tf — Template de Configuração dos Providers Terraform
# ==============================================================================
#
# ESTRUTURA:
#   Este arquivo é um template de referência posicionado na raiz do repositório.
#   A configuração real de providers está em environments/menezes/main.tf,
#   que é o diretório de trabalho do Terraform para este projeto.
#
# PROVIDERS UTILIZADOS:
#   - hashicorp/azurerm ~> 3.90
#     Provider oficial para todos os recursos Azure (ARM, Storage, Automation, etc.)
#     Documentação: https://registry.terraform.io/providers/hashicorp/azurerm/latest
#
# AUTENTICAÇÃO NO CI/CD (OIDC — recomendado):
#   O provider azurerm suporta Workload Identity Federation via OIDC.
#   Ao configurar use_oidc = true, as seguintes variáveis de ambiente
#   ou secrets do GitHub Actions são necessárias:
#
#   | Variável de Ambiente   | GitHub Secret          | Descrição                    |
#   |------------------------|------------------------|------------------------------|
#   | ARM_CLIENT_ID          | AZURE_CLIENT_ID        | Client ID do App Registration|
#   | ARM_TENANT_ID          | AZURE_TENANT_ID        | Tenant ID do Entra ID        |
#   | ARM_SUBSCRIPTION_ID    | AZURE_SUBSCRIPTION_ID  | Subscription ID de destino   |
#
#   NÃO é necessário ARM_CLIENT_SECRET — essa é a vantagem do OIDC.
#
# AUTENTICAÇÃO LOCAL (desenvolvimento):
#   Para executar terraform plan/apply localmente:
#     az login
#     az account set --subscription <subscription-id>
#     export ARM_USE_OIDC=false  # usa credenciais do az login
#
# REFERÊNCIA:
#   https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc
# ==============================================================================

# Configuração de referência — a configuração real está em environments/menezes/main.tf
#
# terraform {
#   # Versão mínima do Terraform CLI requerida
#   # ~> 1.5: garante compatibilidade com features utilizadas (moved blocks, check blocks)
#   required_version = ">= 1.5"
#
#   required_providers {
#     # Provider AzureRM — gerencia todos os recursos Azure Resource Manager
#     # ~> 3.90: aceita 3.90.x e versões patch superiores, mas não 4.x
#     # Pin de versão é importante para estabilidade em IaC
#     azurerm = {
#       source  = "hashicorp/azurerm"
#       version = "~> 3.90"
#     }
#   }
# }
#
# provider "azurerm" {
#   # features {} é obrigatório mesmo sem configurações específicas
#   # Permite customizar comportamento de recursos (ex: key_vault, resource_group)
#   features {}
#
#   # Autenticação via OIDC (Workload Identity Federation)
#   # Elimina a necessidade de client_secret — mais seguro para CI/CD
#   use_oidc = true
# }
