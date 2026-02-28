# ==============================================================================
# modules/automation/main.tf — Módulo de Automação (Tiering Mensal)
# ==============================================================================
#
# Este módulo provisiona toda a camada de automação do projeto:
#
#   1. Automation Account — container dos recursos de automação, com
#      System Assigned Managed Identity (sem credenciais para gerenciar)
#   2. Runbook PowerShell — script que move arquivos inativos do SharePoint
#      para o Azure Files (tiering mensal)
#   3. Schedule — execução automática no 1º dia de cada mês às 02h UTC
#   4. Job Schedule — vincula o runbook ao schedule com parâmetros de execução
#   5. Role Assignment (SMB) — permissão de leitura/escrita no File Share
#   6. Role Assignment (Blob) — permissão de escrita no container de backup
#
# Por que Azure Automation ao invés de Azure Functions ou Logic Apps?
#   - PowerShell nativo: os scripts existentes do escritório funcionam sem refactor
#   - Managed Identity integrada: sem configuração adicional de autenticação
#   - Schedule com granularidade mensal: ideal para o caso de uso
#   - Custo: primeiros 500 minutos/mês de job time são gratuitos (Basic tier)
#   - Long-running: suporta jobs de até 3 horas (Functions Consumption tem 10 min)
# ==============================================================================

# ------------------------------------------------------------------------------
# Automation Account
#
# Container principal para runbooks, schedules e assets de automação.
# O SKU Basic é adequado para workloads de automação simples.
#
# System Assigned Managed Identity:
#   - Criada automaticamente pelo Azure, vinculada ao ciclo de vida do recurso
#   - Principal ID disponível em: azurerm_automation_account.main.identity[0].principal_id
#   - Recebe Role Assignments para acessar Storage Account e File Share
#   - Sem senha, sem certificado, sem rotação manual — gerenciado pelo Azure
# ------------------------------------------------------------------------------
resource "azurerm_automation_account" "main" {
  name                = var.automation_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  # Basic: suporta runbooks PowerShell/Python, schedules, webhooks e Managed Identity
  # Free tier tem limite de 500 minutos/mês — insuficiente para produção
  sku_name = "Basic"

  # System Assigned: identidade gerenciada pelo Azure, atrelada a este recurso
  # User Assigned seria preferível para compartilhar identity entre múltiplos recursos,
  # mas System Assigned é suficiente e mais simples para este caso de uso único
  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Runbook PowerShell — Tiering Mensal de Arquivos
#
# O runbook contém o script de tiering que:
#   1. Autentica no Azure via Managed Identity (Connect-AzAccount -Identity)
#   2. Conecta ao SharePoint via PnP PowerShell (Connect-PnPOnline -ManagedIdentity)
#   3. Busca arquivos não acessados em mais de 24 meses (CAML Query)
#   4. Move cada arquivo para o Azure Files preservando estrutura de pastas
#   5. Remove o original do SharePoint (move para lixeira por 93 dias)
#   6. Loga cada operação e gera relatório ao final
#
# Pré-requisito:
#   O módulo PnP.PowerShell deve ser instalado no Automation Account manualmente
#   ou via azurerm_automation_module (não incluído aqui para simplificar o escopo).
#   Instrução: Automation Account → Modules → Browse Gallery → PnP.PowerShell
#
# runbook_type = "PowerShell": usa PowerShell 5.1 no Sandbox do Azure
#   Para PowerShell 7.x: usar "PowerShell72" com Hybrid Worker configurado
# ------------------------------------------------------------------------------
resource "azurerm_automation_runbook" "tiering" {
  name                    = "runbook-tiering-mensal"
  resource_group_name     = var.resource_group_name
  location                = var.location
  automation_account_name = azurerm_automation_account.main.name

  # PowerShell 5.1 no sandbox gerenciado do Azure Automation
  runbook_type = "PowerShell"

  # Log de progresso: registra checkpoints no histórico do job (útil para debug)
  log_progress = true

  # Log verbose: muito detalhado — habilitar apenas durante troubleshooting
  # Em produção, aumenta custo de armazenamento de logs desnecessariamente
  log_verbose = false

  description = "Tiering mensal: identifica arquivos sem modificação há mais de 24 meses no SharePoint e move para Azure Files Cool (Z:\\)"

  # Conteúdo do script PowerShell carregado do arquivo em scripts/tiering-runbook.ps1
  # O file() é resolvido em relação ao diretório de trabalho do Terraform
  # (environments/menezes/), portanto o caminho relativo aponta para a raiz do repo
  content = var.runbook_content

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Automation Schedule — Execução no 1º Dia de Cada Mês
#
# Configura o agendamento mensal para o runbook de tiering.
# Horário: 02h UTC = 23h BRT (horário de Brasília, dia anterior)
# Escolha de horário fora do expediente: minimiza impacto nos usuários
# e reduz concorrência com outras operações no SharePoint.
#
# Importante: o dia do mês é determinado pelo start_time.
#   start_time = "2026-04-01T02:00:00+00:00" → executa todo dia 1º às 02h UTC
# ------------------------------------------------------------------------------
resource "azurerm_automation_schedule" "mensal" {
  name                    = "schedule-tiering-primeiro-do-mes"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.main.name

  # Month: executa mensalmente
  # Alternativas: OneTime, Hour, Day, Week
  frequency = "Month"

  # Interval 1 = a cada 1 mês
  # Para Month, o Azure Automation não suporta interval > 1
  interval = 1

  # Data/hora de início — deve ser futura (validada pelo provider)
  # O dia do mês nesta data define o dia recorrente de execução
  start_time = var.schedule_start_time

  # UTC para consistência com logs do Azure e timestamps dos arquivos
  timezone = "UTC"

  description = "Executa runbook de tiering no 1º dia de cada mês às 02:00 UTC (23:00 BRT)"
}

# ------------------------------------------------------------------------------
# Job Schedule — Vincula o Runbook ao Schedule com Parâmetros
#
# O azurerm_automation_job_schedule é o recurso que conecta:
#   - Um runbook específico
#   - A um schedule específico
#   - Com parâmetros de execução (passados ao bloco param() do script)
#
# Nota: os nomes dos parâmetros são case-insensitive no Azure Automation,
# mas devem corresponder aos parâmetros declarados no script PowerShell.
# ------------------------------------------------------------------------------
resource "azurerm_automation_job_schedule" "tiering_mensal" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.main.name
  runbook_name            = azurerm_automation_runbook.tiering.name
  schedule_name           = azurerm_automation_schedule.mensal.name

  # Parâmetros passados ao runbook em cada execução agendada
  # Correspondem ao bloco param() declarado no início do script PowerShell
  parameters = {
    SharePointUrl    = var.sharepoint_url
    SharePointDocLib = var.sharepoint_doc_lib
    StorageAccount   = var.storage_account_name
    FileShareName    = var.file_share_name
    InactiveDays     = "730" # 24 meses ≈ 730 dias — parâmetros são sempre strings
  }
}

# ------------------------------------------------------------------------------
# Role Assignment — Storage File Data SMB Share Contributor
#
# Concede ao Automation Account permissão para ler e escrever no File Share
# via protocolo SMB — necessário para que o runbook faça upload dos arquivos.
#
# Princípio do menor privilégio (Least Privilege):
#   - Escopo: apenas o File Share específico (não o Storage Account inteiro)
#   - Role: Storage File Data SMB Share Contributor (não Storage Account Contributor)
#   - O Automation Account NÃO pode gerenciar o Storage Account (control plane)
#
# Built-in role "Storage File Data SMB Share Contributor":
#   Permite: leitura, gravação, deleção e criação de arquivos/diretórios via SMB
#   Não permite: listar/gerenciar o Storage Account, acessar Blobs ou Queues
# ------------------------------------------------------------------------------
resource "azurerm_role_assignment" "automation_fileshare" {
  # Escopo granular: apenas este File Share específico
  # O resource_manager_id do file share tem formato ARM completo
  scope = var.file_share_id

  role_definition_name = "Storage File Data SMB Share Contributor"

  # Principal ID da System Assigned Identity do Automation Account
  # Disponível apenas após a criação do Automation Account (dependência implícita)
  principal_id = azurerm_automation_account.main.identity[0].principal_id
}

# ------------------------------------------------------------------------------
# Role Assignment — Storage Blob Data Contributor
#
# Concede ao Automation Account permissão para escrever no container de backup.
# Usado pelo runbook de backup semanal (não o de tiering — mas a Managed Identity
# é compartilhada e centraliza as permissões de storage).
#
# Escopo: Storage Account (nível mais amplo que o necessário para um container,
# mas o provider não suporta scope por container para este role built-in).
# Em produção com dados sensíveis, avaliar custom role com escopo granular.
# ------------------------------------------------------------------------------
resource "azurerm_role_assignment" "automation_blob" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}
