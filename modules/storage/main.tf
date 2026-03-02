# ==============================================================================
# modules/storage/main.tf — Módulo de Armazenamento (Azure Files + Blob)
# ==============================================================================
#
# Este módulo provisiona toda a camada de armazenamento do projeto:
#
#   1. Resource Group — container lógico de todos os recursos do escritório
#   2. Storage Account — base compartilhada para Files e Blob
#   3. Azure File Share (tier Cool) — histórico jurídico montado como Z:\
#   4. Blob Container (acesso privado) — destino do backup semanal automatizado
#   5. Lifecycle Management Policy — move backups para Archive e expira em 90 dias
#
# Decisões técnicas:
#   - Standard LRS: cost-eficiente para escritório pequeno sem requisito de HA geo.
#     Para produção com maior criticidade, considerar ZRS (zone-redundant).
#   - Cool file share: ~60% mais barato que Hot para dados acessados < 1x/mês.
#   - Archive blob: menor custo de armazenamento no Azure (~90% vs Hot),
#     com trade-off de latência de reidratação (até 15 horas).
#   - Soft delete habilitado em blobs (30d) e file shares (14d): proteção contra
#     exclusão acidental — requisito crítico para escritório que já perdeu processos
#     por corrupção de arquivo.
# ==============================================================================

# ------------------------------------------------------------------------------
# Resource Group
#
# Container lógico que agrupa todos os recursos do escritório Menezes.
# Naming convention CAF: rg-{workload}-{env}-{region}-{seq}
# Exemplo: rg-menezes-prod-brazilsouth-001
# ------------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Storage Account
#
# Serve como base para o Azure Files (histórico) e Blob (backup).
# Um único Storage Account atende os dois casos de uso neste projeto
# para simplificar o gerenciamento e reduzir custos fixos.
#
# Configurações de segurança aplicadas (baseline):
#   - TLS 1.2 mínimo: versões anteriores são deprecated e inseguras
#   - HTTPS only: bloqueia tráfego sem criptografia
#   - Blob public access desabilitado: Zero Trust — nada público por padrão
#   - Soft delete: proteção contra exclusão acidental (crítico para escritório)
# ------------------------------------------------------------------------------
resource "azurerm_storage_account" "main" {
  name                = var.storage_account_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  # StorageV2 é o tipo moderno que suporta todos os serviços:
  # Blob, Files (com tier Cool), Queue, Table, Data Lake Gen2
  account_kind = "StorageV2"

  # Standard = HDD magnético (suficiente para documentos jurídicos)
  # Premium seria necessário apenas para bancos de dados ou VMs
  account_tier = "Standard"

  # LRS: 3 cópias síncronas na mesma zona/datacenter
  # Adequado para o budget de R$ 800/mês — ZRS adicionaria ~25% de custo
  account_replication_type = "LRS"

  # Segurança: apenas TLS 1.2+ aceito (TLS 1.0 e 1.1 são vulneráveis)
  min_tls_version = "TLS1_2"

  # Bloqueia qualquer requisição HTTP sem criptografia
  https_traffic_only_enabled = true

  # Desabilita acesso anônimo a qualquer blob do account
  # Zero Trust: autenticação obrigatória para toda operação
  allow_nested_items_to_be_public = false

  # Configurações do serviço Blob
  blob_properties {
    # Versioning: mantém versões anteriores de blobs modificados
    # Permite recuperar o estado anterior de um arquivo corrompido
    versioning_enabled = true

    # Soft delete para blobs: arquivos "deletados" ficam recuperáveis por 30 dias
    # Crítico para o escritório — histórico de perda de processo por arquivo corrompido
    delete_retention_policy {
      days = 30
    }

    # Soft delete para containers: protege contra exclusão acidental do container inteiro
    container_delete_retention_policy {
      days = 30
    }
  }

  # Configurações do serviço Azure Files
  share_properties {
    # Soft delete para file shares: 14 dias para recuperar shares deletadas
    retention_policy {
      days = 14
    }
  }

  # --------------------------------------------------------------------------
  # Network Rules — Restrição de Acesso por Rede (Defesa em Profundidade)
  #
  # default_action = "Deny": bloqueia qualquer IP não explicitamente permitido.
  # bypass "AzureServices": permite que serviços Azure (Automation Account via
  #   Managed Identity, Azure Monitor, Azure Backup) acessem o storage sem
  #   precisar estar na lista de IPs.
  # ip_rules: CIDRs públicos autorizados (ex: IP do escritório para montagem SMB).
  #   Deixar vazio (default) permite apenas Azure Services.
  # --------------------------------------------------------------------------
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = var.allowed_ip_ranges
  }


  tags = var.tags
}

# ------------------------------------------------------------------------------
# Azure File Share — Histórico Jurídico (Z:\)
#
# Montado como unidade de rede nos computadores do escritório via protocolo SMB 3.0.
# Armazena os 1.6 TB de processos e documentos históricos inativos.
#
# Por que Azure Files ao invés de SharePoint para o histórico?
#   - Familiaridade: usuários já conhecem a unidade Z:\ — zero treinamento
#   - SMB nativo: mesmo protocolo de um servidor de arquivos Windows
#   - Sem limitação de tamanho de arquivo (SharePoint tem limite de 250GB/arquivo)
#   - Tier Cool: custo adequado para dados acessados raramente
#
# Pré-requisito para montagem no Windows:
#   A porta 445 (SMB) deve estar liberada na rede local do escritório.
#   Alternativa: Azure VPN Gateway para acesso seguro sem abrir porta pública.
# ------------------------------------------------------------------------------
resource "azurerm_storage_share" "historico" {
  name                 = var.file_share_name
  storage_account_name = azurerm_storage_account.main.name

  # Quota máxima em GB — 2048 GB = 2 TB
  # Espaço atual: 1.6 TB + margem de ~20% para crescimento anual
  quota = var.file_share_quota

  # Tier Cool: ~60% mais barato que Hot para dados acessados < 1x por mês
  # Adequado para histórico jurídico — processos encerrados raramente consultados
  # Hot seria recomendado apenas para documentos em uso ativo (SharePoint já cobre isso)
  access_tier = "Cool"

  # Metadados para identificação no portal e scripts
  metadata = {
    purpose     = "historico-juridico"
    mount_point = "Z:"
    tier        = "cool"
  }
}

# ------------------------------------------------------------------------------
# Blob Container — Backup Semanal
#
# Destino dos backups automatizados do SharePoint e Azure Files.
# Acesso exclusivamente via Managed Identity do Automation Account (RBAC).
# Sem chave de acesso exposta — autenticação via token Entra ID.
#
# O tier Archive é aplicado automaticamente via Lifecycle Policy (abaixo),
# não diretamente no container (Blob não tem tier no container, apenas no blob).
# ------------------------------------------------------------------------------
resource "azurerm_storage_container" "backup" {
  name                 = var.backup_container_name
  storage_account_name = azurerm_storage_account.main.name

  # Private: nenhum acesso anônimo — qualquer operação requer autenticação
  # Blob seria acesso de leitura anônimo (inaceitável para dados jurídicos)
  container_access_type = "private"
}

# ------------------------------------------------------------------------------
# Lifecycle Management Policy — Backup para Archive + Expiração em 90 dias
#
# Automação de custo: sem intervenção manual, os blobs de backup são
# movidos automaticamente para o tier mais barato e expirados após 90 dias.
#
# Fluxo do ciclo de vida:
#   Dia 0: blob criado pelo runbook de backup → tier Hot (padrão do account)
#   Dia 1: lifecycle move para Archive → ~90% de economia vs Hot
#   Dia 90: blob expirado e deletado automaticamente
#
# Custo aproximado Archive (Brazil South):
#   1 TB/mês ≈ R$ 5,50 (vs R$ 110 no Hot tier)
# ------------------------------------------------------------------------------
resource "azurerm_storage_management_policy" "backup_lifecycle" {
  storage_account_id = azurerm_storage_account.main.id

  rule {
    name    = "backup-archive-and-expiry"
    enabled = true

    # Filtro: aplica apenas a blobs do tipo blockBlob no container de backup
    # prefix_match com nome do container garante que outros blobs não sejam afetados
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["${var.backup_container_name}/"]
    }

    actions {
      base_blob {
        # Move para Archive 1 dia após a última modificação
        # Archive: custo de storage mínimo, latência de acesso de horas (aceitável para DR)
        tier_to_archive_after_days_since_modification_greater_than = 1

        # Exclui o blob 90 dias após a última modificação
        # Política de retenção de backup: 90 dias conforme requisito do cliente
        delete_after_days_since_modification_greater_than = 90
      }

      # Aplica expiração também às versões anteriores dos blobs
      # (versioning está habilitado no Storage Account)
      version {
        delete_after_days_since_creation = 90
      }
    }
  }
}
