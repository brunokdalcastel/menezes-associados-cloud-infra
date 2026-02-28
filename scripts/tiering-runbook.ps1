<#
.SYNOPSIS
    Tiering Mensal de Arquivos — SharePoint Online para Azure Files Cool.

.DESCRIPTION
    Este runbook é executado automaticamente no 1º dia de cada mês pelo Azure Automation.
    Identifica arquivos no SharePoint sem modificação há mais de 24 meses e os move
    para o Azure Files (Z:\), liberando espaço no SharePoint e reduzindo custos.

    Fluxo de execução:
      1. Autenticação no Azure via Managed Identity (sem credenciais armazenadas)
      2. Criação do contexto de storage para o Azure Files
      3. Conexão ao SharePoint Online via PnP PowerShell com Managed Identity
      4. Busca de arquivos inativos via CAML Query (LastModified < data de corte)
      5. Para cada arquivo candidato:
         a. Download do SharePoint para arquivo temporário local
         b. Criação de diretórios no Azure Files (preserva estrutura de pastas)
         c. Upload do arquivo para o Azure Files
         d. Remoção do original do SharePoint (movido para lixeira de 93 dias)
         e. Log da operação com nome, tamanho e destino
      6. Relatório final com totais de arquivos movidos, erros e volume

.PARAMETER SharePointUrl
    URL completa do site SharePoint Online.
    Exemplo: "https://menezesassociados.sharepoint.com/sites/juridico"

.PARAMETER SharePointDocLib
    Nome da biblioteca de documentos SharePoint. Padrão: "Documentos"

.PARAMETER StorageAccount
    Nome do Storage Account Azure que contém o File Share de destino.

.PARAMETER FileShareName
    Nome do File Share dentro do Storage Account. Montado como Z:\ nos desktops.

.PARAMETER InactiveDays
    Número de dias sem modificação para considerar o arquivo candidato ao tiering.
    Padrão: 730 dias (aproximadamente 24 meses).

.NOTES
    Pré-requisitos no Automation Account:
      Módulos necessários (instalar via Gallery no portal Azure):
        - PnP.PowerShell (para conectar ao SharePoint)
        - Az.Storage    (pré-instalado no Azure Automation)
        - Az.Accounts   (pré-instalado no Azure Automation)

    Permissões necessárias para a Managed Identity:
      Azure Files:
        Role: Storage File Data SMB Share Contributor
        Escopo: File Share específico (atribuído pelo Terraform)

      SharePoint (configuração manual pós-deploy):
        az rest --method POST \
          --url "https://graph.microsoft.com/v1.0/servicePrincipals/{principalId}/appRoleAssignments" \
          --body '{"principalId":"{principalId}","resourceId":"{graphAppId}","appRoleId":"{Sites.ReadWrite.All.id}"}'

    Versão: 1.0.0
    Projeto: Menezes & Associados — Portfólio de Infraestrutura Azure
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SharePointUrl,

    [Parameter(Mandatory = $false)]
    [string]$SharePointDocLib = "Documentos",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StorageAccount,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$FileShareName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 3650)]
    [int]$InactiveDays = 730
)

# ==============================================================================
# CONFIGURAÇÃO INICIAL
# ==============================================================================

# Stop on first error — não continua após exceções não tratadas
$ErrorActionPreference = "Stop"

# Data de corte: arquivos modificados antes desta data são candidatos ao tiering
$CutoffDate = (Get-Date).AddDays(-$InactiveDays)

# Contadores para o relatório final
$Script:TotalMoved    = 0
$Script:TotalSkipped  = 0
$Script:TotalErrors   = 0
$Script:TotalSizeBytes = [long]0

# Formato de timestamp para os logs
$TimestampFormat = "yyyy-MM-dd HH:mm:ss"

# Função auxiliar para log estruturado
function Write-Log {
    param(
        [string]$Level,    # INFO, WARN, ERROR, SUCCESS
        [string]$Message
    )
    $Timestamp = Get-Date -Format $TimestampFormat
    Write-Output "[$Timestamp] [$Level] $Message"
}

Write-Output "======================================================================"
Write-Output "  TIERING MENSAL — Menezes & Associados"
Write-Output "  Início   : $(Get-Date -Format $TimestampFormat) UTC"
Write-Output "  Corte    : arquivos sem modificação desde $(Get-Date $CutoffDate -Format 'yyyy-MM-dd')"
Write-Output "  SharePoint: $SharePointUrl / $SharePointDocLib"
Write-Output "  Destino  : $StorageAccount / $FileShareName"
Write-Output "======================================================================"

# ==============================================================================
# ETAPA 1: AUTENTICAÇÃO NO AZURE VIA MANAGED IDENTITY
# ==============================================================================

Write-Log "INFO" "Etapa 1/4 — Autenticando no Azure via Managed Identity..."

try {
    # Connect-AzAccount -Identity utiliza a System Assigned Managed Identity
    # do Automation Account, sem necessidade de credenciais armazenadas.
    # O Azure injeta um token OAuth2 automaticamente via IMDS (Instance Metadata Service).
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

    $CurrentAccount = Get-AzContext
    Write-Log "INFO" "Autenticado como: $($CurrentAccount.Account.Id)"
    Write-Log "INFO" "Subscription: $($CurrentAccount.Subscription.Name)"
}
catch {
    Write-Log "ERROR" "Falha na autenticação Azure: $_"
    throw "Não foi possível autenticar via Managed Identity. Verifique se a identidade está habilitada no Automation Account."
}

# ==============================================================================
# ETAPA 2: CRIAR CONTEXTO DE STORAGE (AZURE FILES)
# ==============================================================================

Write-Log "INFO" "Etapa 2/4 — Criando contexto de acesso ao Azure Files..."

try {
    # New-AzStorageContext com -UseConnectedAccount usa o token RBAC do Connect-AzAccount
    # em vez da chave de acesso do Storage Account — mais seguro e sem rotação de secret
    $StorageContext = New-AzStorageContext `
        -StorageAccountName $StorageAccount `
        -UseConnectedAccount `
        -ErrorAction Stop

    # Valida a conexão listando o File Share
    $ShareExists = Get-AzStorageShare -Name $FileShareName -Context $StorageContext -ErrorAction SilentlyContinue
    if (-not $ShareExists) {
        throw "File Share '$FileShareName' não encontrado na conta '$StorageAccount'."
    }

    Write-Log "INFO" "Contexto criado. File Share '$FileShareName' acessível."
}
catch {
    Write-Log "ERROR" "Falha ao conectar ao Azure Files: $_"
    throw
}

# ==============================================================================
# ETAPA 3: CONEXÃO AO SHAREPOINT ONLINE VIA PnP POWERSHELL
# ==============================================================================

Write-Log "INFO" "Etapa 3/4 — Conectando ao SharePoint Online via PnP..."

try {
    # Connect-PnPOnline com -ManagedIdentity usa a mesma Managed Identity do Az context.
    # Pré-requisito: a Managed Identity deve ter permissão Sites.ReadWrite.All no Graph API.
    # Configuração via CLI (executar uma única vez):
    #   $GraphSP = Get-AzADServicePrincipal -DisplayName "Microsoft Graph"
    #   $RoleId = ($GraphSP.AppRole | Where-Object { $_.Value -eq "Sites.ReadWrite.All" }).Id
    #   New-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId <PrincipalId> `
    #     -ResourceId $GraphSP.Id -AppRoleId $RoleId
    Connect-PnPOnline -Url $SharePointUrl -ManagedIdentity -ErrorAction Stop

    Write-Log "INFO" "Conectado ao SharePoint: $SharePointUrl"
}
catch {
    Write-Log "ERROR" "Falha ao conectar ao SharePoint: $_"
    Write-Log "ERROR" "Verifique se o módulo PnP.PowerShell está instalado e se a Managed Identity tem permissão Sites.ReadWrite.All."
    throw
}

# ==============================================================================
# ETAPA 4: BUSCAR ARQUIVOS CANDIDATOS AO TIERING
# ==============================================================================

Write-Log "INFO" "Etapa 4/4 — Buscando arquivos candidatos ao tiering..."

try {
    # CAML Query para buscar arquivos com LastModified antes da data de corte.
    # Scope="RecursiveAll" garante que subpastas também sejam varridas.
    # ViewFields limita os campos retornados — mais eficiente que retornar tudo.
    $CamlQuery = @"
<View Scope="RecursiveAll">
    <Query>
        <Where>
            <And>
                <Lt>
                    <FieldRef Name='Modified'/>
                    <Value Type='DateTime'>$(Get-Date $CutoffDate -Format 'yyyy-MM-ddTHH:mm:ssZ')</Value>
                </Lt>
                <Eq>
                    <FieldRef Name='FSObjType'/>
                    <Value Type='Integer'>0</Value>
                </Eq>
            </And>
        </Where>
    </Query>
    <ViewFields>
        <FieldRef Name='FileLeafRef'/>
        <FieldRef Name='FileRef'/>
        <FieldRef Name='Modified'/>
        <FieldRef Name='File_x0020_Size'/>
        <FieldRef Name='FileDirRef'/>
    </ViewFields>
    <RowLimit>5000</RowLimit>
</View>
"@

    # Executa a query — retorna ListItems com metadados dos arquivos
    $Items = Get-PnPListItem -List $SharePointDocLib -Query $CamlQuery -ErrorAction Stop

    # FSObjType = 0 significa arquivo (1 = pasta) — filtro de segurança adicional
    $Files = $Items | Where-Object { $_["FSObjType"] -eq 0 }

    Write-Log "INFO" "Arquivos encontrados para tiering: $($Files.Count)"

    if ($Files.Count -eq 0) {
        Write-Log "INFO" "Nenhum arquivo elegível neste mês. Encerrando."
    }
}
catch {
    Write-Log "ERROR" "Falha ao buscar arquivos no SharePoint: $_"
    throw
}

# ==============================================================================
# PROCESSAMENTO: MOVER CADA ARQUIVO DO SHAREPOINT PARA O AZURE FILES
# ==============================================================================

if ($Files.Count -gt 0) {

    Write-Output ""
    Write-Output "──────────────────────────────────────────────────────────────────"
    Write-Log "INFO" "Iniciando processamento de $($Files.Count) arquivo(s)..."
    Write-Output "──────────────────────────────────────────────────────────────────"

    foreach ($File in $Files) {

        # Extrai metadados do item atual
        $FileName      = $File["FileLeafRef"]
        $FileRef       = $File["FileRef"]          # Caminho relativo: /sites/juridico/Documentos/pasta/arq.docx
        $FileModified  = $File["Modified"]
        $FileSizeBytes = [long]($File["File_x0020_Size"] ?? 0)
        $FileDirRef    = $File["FileDirRef"]

        # Converte o caminho SharePoint para caminho relativo no Azure Files.
        # Remove o prefixo do site e da biblioteca para preservar apenas a estrutura de pastas interna.
        # Ex: /sites/juridico/Documentos/2020/Contratos/arquivo.docx → 2020/Contratos/arquivo.docx
        $SiteRelativePath = $FileRef -replace "^.+/$SharePointDocLib/?", ""
        $AzureFilePath    = $SiteRelativePath.TrimStart("/")

        # Diretório de destino no Azure Files (sem o nome do arquivo)
        $AzureDirectory = [System.IO.Path]::GetDirectoryName($AzureFilePath) -replace "\\", "/"

        Write-Output ""
        Write-Log "INFO" "→ Arquivo    : $FileName"
        Write-Log "INFO" "  Origem     : $FileRef"
        Write-Log "INFO" "  Destino    : $FileShareName/$AzureFilePath"
        Write-Log "INFO" "  Modificado : $FileModified"
        Write-Log "INFO" "  Tamanho    : $([math]::Round($FileSizeBytes / 1MB, 2)) MB"

        $TempFilePath = $null

        try {
            # ------------------------------------------------------------------
            # PASSO A: DOWNLOAD do arquivo do SharePoint para arquivo temporário
            # ------------------------------------------------------------------

            # Cria arquivo temporário com a extensão correta do arquivo original
            $TempDir      = [System.IO.Path]::GetTempPath()
            $TempFilePath = Join-Path $TempDir ([System.IO.Path]::GetRandomFileName() + [System.IO.Path]::GetExtension($FileName))

            # Get-PnPFile com -AsFile baixa o arquivo para o sistema de arquivos local
            Get-PnPFile `
                -Url $FileRef `
                -Path $TempDir `
                -Filename ([System.IO.Path]::GetFileName($TempFilePath)) `
                -AsFile `
                -Force `
                -ErrorAction Stop | Out-Null

            Write-Log "INFO" "  ✓ Download concluído"

            # ------------------------------------------------------------------
            # PASSO B: CRIAR DIRETÓRIOS no Azure Files (preserva estrutura)
            # ------------------------------------------------------------------

            if (-not [string]::IsNullOrWhiteSpace($AzureDirectory)) {
                # O Azure Files não cria diretórios automaticamente — é necessário
                # criar cada nível da hierarquia individualmente
                $DirectoryParts = $AzureDirectory -split "/"
                $CurrentPath    = ""

                foreach ($Part in $DirectoryParts) {
                    if ([string]::IsNullOrWhiteSpace($Part)) { continue }

                    $CurrentPath = if ($CurrentPath) { "$CurrentPath/$Part" } else { $Part }

                    # Verifica se o diretório já existe antes de tentar criar
                    $DirExists = Get-AzStorageFile `
                        -Context $StorageContext `
                        -ShareName $FileShareName `
                        -Path $CurrentPath `
                        -ErrorAction SilentlyContinue

                    if (-not $DirExists) {
                        New-AzStorageDirectory `
                            -Context $StorageContext `
                            -ShareName $FileShareName `
                            -Path $CurrentPath `
                            -ErrorAction Stop | Out-Null
                    }
                }
            }

            Write-Log "INFO" "  ✓ Estrutura de diretórios verificada/criada"

            # ------------------------------------------------------------------
            # PASSO C: UPLOAD do arquivo para o Azure Files
            # ------------------------------------------------------------------

            Set-AzStorageFileContent `
                -Context $StorageContext `
                -ShareName $FileShareName `
                -Source $TempFilePath `
                -Path $AzureFilePath `
                -Force `
                -ErrorAction Stop | Out-Null

            Write-Log "INFO" "  ✓ Upload concluído"

            # ------------------------------------------------------------------
            # PASSO D: DELETE do arquivo original no SharePoint
            # EXECUTADO SOMENTE após upload bem-sucedido (garante integridade)
            # -Recycle move para lixeira (93 dias para recuperação) ao invés de deleção permanente
            # ------------------------------------------------------------------

            Remove-PnPFile -SiteRelativeUrl $FileRef -Recycle -Force -ErrorAction Stop

            Write-Log "INFO" "  ✓ Arquivo removido do SharePoint (lixeira disponível por 93 dias)"

            # ------------------------------------------------------------------
            # PASSO E: CONTABILIZAÇÃO
            # ------------------------------------------------------------------

            $Script:TotalMoved     += 1
            $Script:TotalSizeBytes += $FileSizeBytes

            Write-Log "INFO" "  ✅ SUCESSO"
        }
        catch {
            # Em caso de erro em um arquivo, registra e continua com os próximos.
            # O runbook não para — garante que o máximo de arquivos seja processado.
            $Script:TotalErrors += 1
            Write-Log "WARN" "  ❌ ERRO ao processar '$FileName': $_"
            Write-Log "WARN" "     O arquivo permanece no SharePoint sem alterações."
        }
        finally {
            # Sempre limpa o arquivo temporário, independente de sucesso ou falha
            if ($TempFilePath -and (Test-Path $TempFilePath)) {
                Remove-Item $TempFilePath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ==============================================================================
# DESCONECTAR DO SHAREPOINT
# ==============================================================================

try {
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
    Write-Log "INFO" "Desconectado do SharePoint."
}
catch {
    # Falha ao desconectar não é crítica — apenas registra
    Write-Log "WARN" "Aviso ao desconectar do SharePoint: $_"
}

# ==============================================================================
# RELATÓRIO FINAL
# ==============================================================================

$TotalSizeGB = [math]::Round($Script:TotalSizeBytes / 1GB, 3)

Write-Output ""
Write-Output "======================================================================"
Write-Output "  RELATÓRIO DE EXECUÇÃO — TIERING MENSAL"
Write-Output "  Término: $(Get-Date -Format $TimestampFormat) UTC"
Write-Output "  ──────────────────────────────────────────────────────────────────"
Write-Output "  Arquivos movidos  : $($Script:TotalMoved)"
Write-Output "  Erros             : $($Script:TotalErrors)"
Write-Output "  Volume transferido: $TotalSizeGB GB"
Write-Output "======================================================================"

# Retorna erro se algum arquivo falhou — o Azure Automation registra como job com falha
# e pode disparar alertas configurados no Automation Account
if ($Script:TotalErrors -gt 0) {
    throw "Runbook finalizado com $($Script:TotalErrors) erro(s). Verifique os logs de job acima para detalhes. Arquivos com erro permanecem no SharePoint."
}

Write-Log "INFO" "Runbook finalizado com sucesso."
