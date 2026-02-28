# ==============================================================================
# environments/menezes/main.tf — Entry Point do Ambiente Menezes & Associados
# ==============================================================================
#
# Este arquivo é o ponto de entrada do Terraform para o ambiente de produção.
# Ele define:
#   1. Configuração do backend remoto (state no Azure Storage Account)
#   2. Versão do Terraform e provider azurerm
#   3. Invocação do módulo storage (Resource Group, Azure Files, Blob)
#   4. Invocação do módulo automation (Runbook, Schedule, Role Assignments)
#
# Como executar:
#   cd environments/menezes
#   terraform init
#   terraform plan -var-file=terraform.tfvars
#   terraform apply -var-file=terraform.tfvars
#
# Pré-requisitos:
#   - Storage Account para o backend já criado (ver backend.tf na raiz do repo)
#   - App Registration com Federated Credentials para OIDC (ou az login local)
#   - Módulo PnP.PowerShell instalado no Automation Account pós-deploy
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuração do Terraform — Backend + Versão + Providers
# ------------------------------------------------------------------------------
terraform {
  # Versão mínima do Terraform CLI requerida
  # >= 1.5 habilita: moved blocks, import blocks, check blocks
  required_version = ">= 1.5"

  required_providers {
    # Provider oficial HashiCorp para recursos Azure Resource Manager
    # ~> 3.90: aceita 3.90.x e patches superiores, bloqueia upgrade automático para 4.x
    # Pin de versão é essencial para IaC reproduzível — evita breaking changes
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
  }

  # --------------------------------------------------------------------------
  # Backend Remoto — Azure Storage Account
  #
  # Por que state remoto?
  #   - Colaboração: múltiplos engenheiros acessam o mesmo state
  #   - Locking: Azure Blob Lease previne apply simultâneo (corrupção)
  #   - Durabilidade: state não se perde se o computador local falha
  #   - Auditoria: versioning do Storage Account mantém histórico do state
  #
  # Nota: o bloco backend não aceita variáveis Terraform.
  #   Valores fixos aqui — para ambientes dinâmicos, usar -backend-config flag:
  #   terraform init -backend-config="key=menezes/terraform.tfstate"
  # --------------------------------------------------------------------------
  backend "azurerm" {
    # Resource Group que contém o Storage Account de state
    resource_group_name = "rg-tfstate-shared-brazilsouth-001"

    # Storage Account para armazenar o .tfstate
    # Criado manualmente ANTES do primeiro terraform init (ver backend.tf na raiz)
    storage_account_name = "sttfstatemenezes001"

    # Container onde o state é armazenado
    container_name = "tfstate"

    # Caminho único do arquivo de state — permite múltiplos ambientes no mesmo container
    # Padrão recomendado: {cliente/ambiente}/terraform.tfstate
    key = "menezes/terraform.tfstate"

    # OIDC: o backend usa as mesmas credenciais OIDC do provider
    # Evita a necessidade de chave de acesso do Storage Account
    use_oidc = true
  }
}

# ------------------------------------------------------------------------------
# Provider AzureRM
#
# use_oidc = true: autenticação via Workload Identity Federation (GitHub Actions)
#   Sem client_secret — o GitHub gera tokens JWT de curta duração validados pelo Azure
#
# Para execução local (desenvolvedor):
#   Substitua temporariamente por: az login && unset ARM_USE_OIDC
#   ou execute: az login && terraform plan (o provider detecta as credenciais CLI)
# ------------------------------------------------------------------------------
provider "azurerm" {
  # Obrigatório: habilita todos os recursos do provider
  # Permite customização de comportamento (ex: não deletar Key Vaults com purge protection)
  features {}

  # Autenticação OIDC — lê as seguintes variáveis de ambiente (setadas pelo GitHub Actions):
  #   ARM_CLIENT_ID       → AZURE_CLIENT_ID secret
  #   ARM_TENANT_ID       → AZURE_TENANT_ID secret
  #   ARM_SUBSCRIPTION_ID → AZURE_SUBSCRIPTION_ID secret
  use_oidc = true
}

# ==============================================================================
# MÓDULO: Storage
#
# Provisiona a infraestrutura de armazenamento completa:
#   - Resource Group principal do ambiente
#   - Storage Account (Standard LRS, StorageV2)
#   - Azure File Share (tier Cool, 2 TB) — histórico montado como Z:\
#   - Blob Container (privado) — backup semanal
#   - Lifecycle Policy — blobs de backup → Archive em 1 dia, expiração em 90 dias
# ==============================================================================
module "storage" {
  # Caminho relativo para o módulo — resolve a partir de environments/menezes/
  source = "../../modules/storage"

  # Identificação
  environment = var.environment
  location    = var.location

  # Resource Group
  resource_group_name = var.resource_group_name

  # Storage Account
  storage_account_name = var.storage_account_name

  # Azure Files — Histórico Jurídico
  file_share_name  = var.file_share_name
  file_share_quota = var.file_share_quota

  # Blob — Backup Semanal
  backup_container_name = var.backup_container_name

  # Tags de governança
  tags = var.tags
}

# ==============================================================================
# MÓDULO: Automation
#
# Provisiona a automação de tiering mensal:
#   - Automation Account com System Assigned Managed Identity
#   - Runbook PowerShell (script carregado de scripts/tiering-runbook.ps1)
#   - Schedule mensal (1º dia do mês, 02h UTC)
#   - Job Schedule (vincula runbook + schedule + parâmetros)
#   - Role Assignment SMB no File Share (Storage File Data SMB Share Contributor)
#   - Role Assignment Blob no Storage Account (Storage Blob Data Contributor)
#
# Dependência: o módulo automation usa outputs do módulo storage —
# o Terraform resolve a ordem de criação automaticamente via referências.
# ==============================================================================
module "automation" {
  source = "../../modules/automation"

  # Identificação
  environment = var.environment
  location    = var.location

  # O Automation Account vai para o mesmo Resource Group do Storage
  # (criado pelo módulo storage — referenciado via output)
  resource_group_name = module.storage.resource_group_name

  # Automation Account
  automation_account_name = var.automation_account_name

  # Conteúdo do runbook PowerShell
  # file() lê o arquivo em relação ao diretório de trabalho do Terraform (environments/menezes/)
  # ../../scripts/ → raiz do repositório → scripts/tiering-runbook.ps1
  runbook_content = file("../../scripts/tiering-runbook.ps1")

  # Configuração SharePoint — passada como parâmetro ao runbook em cada execução
  sharepoint_url     = var.sharepoint_url
  sharepoint_doc_lib = var.sharepoint_doc_lib

  # Referências ao Storage Account — outputs do módulo storage
  # Usadas para Role Assignments (autorizações de acesso)
  storage_account_id   = module.storage.storage_account_id
  storage_account_name = module.storage.storage_account_name

  # Resource Manager ID do File Share para Role Assignment com escopo granular
  file_share_id   = module.storage.file_share_resource_manager_id
  file_share_name = module.storage.file_share_name

  # Schedule mensal
  schedule_start_time = var.schedule_start_time

  # Tags
  tags = var.tags
}
