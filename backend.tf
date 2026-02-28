# ==============================================================================
# backend.tf — Template de Configuração do Backend Remoto (Terraform State)
# ==============================================================================
#
# ESTRUTURA:
#   Este arquivo é um template de referência posicionado na raiz do repositório.
#   O Terraform é executado a partir de environments/menezes/, que contém o
#   backend configurado em seu próprio bloco terraform {}.
#
# POR QUE BACKEND REMOTO?
#   O state local (terraform.tfstate) não é adequado para ambientes reais:
#   - Risco de perda (arquivo local deletado ou corrompido)
#   - Impossibilidade de colaboração em time
#   - Sem locking (dois applies simultâneos corrompem o state)
#
#   Azure Storage Account resolve todos esses problemas:
#   - Durável: LRS/ZRS com redundância automática
#   - Locking nativo via Azure Blob Lease
#   - RBAC para controle de acesso ao state
#   - Versioning para rollback de state
#
# SETUP MANUAL DO BACKEND (executar uma única vez, antes do primeiro deploy):
#
#   # 1. Criar Resource Group para o state
#   az group create \
#     --name rg-tfstate-shared-brazilsouth-001 \
#     --location brazilsouth
#
#   # 2. Criar Storage Account globalmente único
#   az storage account create \
#     --name sttfstatemenezes001 \
#     --resource-group rg-tfstate-shared-brazilsouth-001 \
#     --location brazilsouth \
#     --sku Standard_LRS \
#     --kind StorageV2 \
#     --min-tls-version TLS1_2 \
#     --allow-blob-public-access false
#
#   # 3. Criar container para o state
#   az storage container create \
#     --name tfstate \
#     --account-name sttfstatemenezes001
#
#   # 4. Atribuir permissão ao Service Principal / Managed Identity do CI/CD
#   az role assignment create \
#     --role "Storage Blob Data Contributor" \
#     --assignee <client-id-do-app-registration> \
#     --scope /subscriptions/<sub-id>/resourceGroups/rg-tfstate-shared-brazilsouth-001/...
#
# REFERÊNCIA:
#   https://developer.hashicorp.com/terraform/language/settings/backends/azurerm
# ==============================================================================

# Configuração de referência — o backend real está em environments/menezes/main.tf
#
# terraform {
#   backend "azurerm" {
#     # Resource Group que contém o Storage Account do state
#     resource_group_name = "rg-tfstate-shared-brazilsouth-001"
#
#     # Storage Account globalmente único (3-24 chars, somente lowercase e números)
#     storage_account_name = "sttfstatemenezes001"
#
#     # Container dentro do Storage Account
#     container_name = "tfstate"
#
#     # Caminho único para o state deste ambiente
#     # Permite múltiplos ambientes no mesmo container com keys diferentes
#     key = "menezes/terraform.tfstate"
#
#     # Autenticação via OIDC — sem client_secret armazenado em variável ou CI/CD
#     # Requer Federated Credentials configuradas no App Registration
#     use_oidc = true
#   }
# }
