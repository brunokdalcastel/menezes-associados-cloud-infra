# ☁️ Menezes & Associados — Cloud Infrastructure

> **Simulação de projeto real** | Migração de infraestrutura on-premises para Microsoft 365 + Azure para escritório de advocacia com 12 usuários.

---

## 📋 Contexto

Escritório de advocacia operando com servidor físico legado, arquivos compartilhados via pen drive e e-mail pessoal, sem backup estruturado e sem controle de acesso. Este projeto simula o trabalho de um Cloud Engineer freelancer contratado para modernizar a infraestrutura com foco em **segurança**, **rastreabilidade de acesso** e **custo controlado**.

**Requisitos do cliente:**
- Controle de quem acessa cada arquivo
- Backup confiável (já perderam processo por arquivo corrompido)
- Solução acessível — budget de R$ 800/mês
- Zero dependência técnica para operação do dia a dia

---

## 🏗️ Arquitetura

<img src="docs/menezes-arquitetura_4.png" alt="Arquitetura" width="827"/>

### Decisões técnicas

| Problema | Solução | Justificativa |
|---|---|---|
| Sem identidade centralizada | Microsoft Entra ID + MFA | Cloud-native, sem necessidade de AD on-prem |
| Arquivos ativos sem controle | SharePoint Online | Auditoria nativa, versionamento, acesso por browser |
| 1.6TB de arquivos históricos | Azure Files Cool (Z:\) | Acesso SMB familiar para usuários, sem treinamento |
| Tiering manual insustentável | Azure Automation + PowerShell | Runbook mensal move arquivos inativos automaticamente |
| Sem backup estruturado | Azure Blob Archive | Backup semanal, retenção 90 dias, custo mínimo |
| E-mail pessoal para trabalho | Exchange Online | Migração do domínio existente, zero impacto para usuários |

---

## 🗂️ Estrutura do Repositório

```
menezes-associados-cloud-infra/
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml      # CI: plan automático em Pull Requests
│       └── terraform-apply.yml     # CD: apply automático após merge na main
├── docs/
│   └── menezes-arquitetura_4.png  # Diagrama de arquitetura
├── modules/
│   ├── storage/                    # Resource Group, Storage Account, Azure Files, Blob + Lifecycle
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── automation/                 # Automation Account, Runbook, Schedule, Role Assignments
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── environments/
│   └── menezes/
│       ├── main.tf                 # Entry point: backend + provider + module calls
│       ├── variables.tf
│       └── terraform.tfvars.example
├── scripts/
│   └── tiering-runbook.ps1        # PowerShell — tiering automático mensal via Managed Identity
├── backend.tf                     # Template de referência — configuração real em environments/menezes/
├── providers.tf                   # Template de referência — configuração real em environments/menezes/
├── .gitignore
└── README.md
```

---

## 🔧 Stack Técnica

**Microsoft 365 Business Basic**
- Microsoft Entra ID — identidade + MFA + Conditional Access
- SharePoint Online — arquivos ativos (400GB)
- Microsoft Teams — comunicação interna
- Exchange Online — e-mail corporativo

**Microsoft Azure**
- Azure Files (tier Cool) — arquivos históricos 1.6TB, montado como `Z:\`
- Azure Automation + Runbook PowerShell — tiering automático mensal
- Azure Blob Storage (tier Archive) — backup semanal, retenção 90 dias

**IaC & Automação**
- Terraform — provisionamento de recursos Azure
- GitHub Actions — pipeline de CI/CD (plan no PR, apply no merge)
- PowerShell — runbook de tiering

---

## 🚀 Como usar

### Pré-requisitos

- Terraform >= 1.5
- Azure CLI autenticado (`az login`)
- Subscription Azure ativa
- Licenças M365 Business Basic provisionadas

### Deploy

```bash
# 1. Clone o repositório
git clone https://github.com/brunokdalcastel/menezes-associados-cloud-infra
cd menezes-associados-cloud-infra

# 2. Crie o Storage Account para armazenar o state do Terraform (executar uma única vez)
# Este Storage Account NÃO é o de dados do escritório — é exclusivo para o tfstate
az group create --name rg-tfstate-shared-brazilsouth-001 --location brazilsouth
az storage account create --name sttfstatemenezes001 --resource-group rg-tfstate-shared-brazilsouth-001 --location brazilsouth --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false
az storage container create --name tfstate --account-name sttfstatemenezes001

# 3. Configure as variáveis
cp environments/menezes/terraform.tfvars.example environments/menezes/terraform.tfvars
# Edite o terraform.tfvars com seus valores reais — atenção para:
#   - sharepoint_url: URL do seu tenant SharePoint
#   - allowed_ip_ranges: adicione o IP público da sua máquina/escritório (obrigatório
#     para acessar o Storage Account via SMB ou portal — ex: ["SEU_IP_PUBLICO/32"])
#     Descubra seu IP público: curl ifconfig.me
#   - schedule_start_time: deve ser sempre uma data FUTURA (mínimo 5 minutos à frente)
#     Formato: "YYYY-MM-DDT02:00:00+00:00" com o 1º dia de um mês futuro

# 4. Inicialize e aplique
cd environments/menezes
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars

# 5. Pós-deploy: instale o módulo PnP.PowerShell no Automation Account
# O runbook de tiering depende deste módulo — sem ele, o job falha na execução
# Portal Azure → Automation Account → Módulos → Procurar na Galeria → "PnP.PowerShell"
# Aguarde a instalação concluir (status: Available) antes da primeira execução agendada
```

> **Aviso sobre `schedule_start_time`:** O Azure exige que o horário de início do schedule seja **sempre futuro**. A data de exemplo no `terraform.tfvars.example` pode estar expirada — atualize para o 1º dia do próximo mês antes de aplicar.

> **Aviso sobre `allowed_ip_ranges`:** O Storage Account é criado com `default_action = "Deny"`. Se você não incluir seu IP público em `allowed_ip_ranges`, **não conseguirá acessar o Storage** via portal, CLI ou montagem SMB. O Automation Account acessa normalmente via Managed Identity (`bypass = ["AzureServices"]`).

### Configuração do CI/CD (GitHub Actions + OIDC)

O pipeline usa **Workload Identity Federation (OIDC)** — sem client secrets armazenados. Para ativar o CI/CD no seu fork:

**1. Crie um App Registration no Entra ID**
```bash
az ad app create --display-name "sp-terraform-menezes-github"
# Anote o Application (client) ID gerado
```

**2. Atribua permissão Contributor na Subscription**
```bash
az role assignment create \
  --role "Contributor" \
  --assignee <APPLICATION_CLIENT_ID> \
  --scope /subscriptions/<SUBSCRIPTION_ID>

# Permissão adicional para criar Role Assignments (necessária para os módulos)
az role assignment create \
  --role "User Access Administrator" \
  --assignee <APPLICATION_CLIENT_ID> \
  --scope /subscriptions/<SUBSCRIPTION_ID>
```

**3. Crie duas Federated Credentials** (uma para PRs, outra para merge na main)

No portal: **Entra ID → App Registrations → seu app → Certificates & secrets → Federated credentials**

| Nome | Issuer | Subject |
|------|--------|---------|
| `github-pr` | `https://token.actions.githubusercontent.com` | `repo:SEU_USER/menezes-associados-cloud-infra:pull_request` |
| `github-main` | `https://token.actions.githubusercontent.com` | `repo:SEU_USER/menezes-associados-cloud-infra:ref:refs/heads/main` |

**4. Configure os Secrets no repositório GitHub**

Settings → Secrets and variables → Actions → New repository secret:

| Secret | Valor |
|--------|-------|
| `AZURE_CLIENT_ID` | Application (client) ID do App Registration |
| `AZURE_TENANT_ID` | Tenant ID do Entra ID |
| `AZURE_SUBSCRIPTION_ID` | ID da Azure Subscription |

**5. Crie o GitHub Environment "production"**

Settings → Environments → New environment → nome: `production`
(Opcional: adicione Required Reviewers para exigir aprovação manual antes do apply)

---

## 📐 Fluxo de Dados

```
Advogado faz login
    └── Entra ID valida identidade + MFA
        ├── Acessa SharePoint (arquivos ativos)
        ├── Acessa Teams (comunicação)
        └── Acessa Exchange (e-mail)

Azure Automation (mensal)
    └── Verifica arquivos no SharePoint sem acesso > 24 meses
        └── Move automaticamente → Azure Files Cool (Z:\)

Backup semanal
    ├── SharePoint → Azure Blob Archive
    └── Azure Files → Azure Blob Archive
        └── Retenção: 90 dias
```

---

## 📌 Escopo IaC (Terraform)

O Terraform gerencia exclusivamente os recursos **Microsoft Azure**. A configuração do Microsoft 365 (Entra ID, SharePoint, Teams, Exchange) é realizada via **M365 Admin Center** e documentada como runbook operacional — essa é uma decisão intencional, pois recursos M365 têm ciclo de vida independente da infraestrutura Azure.

| Recurso | Gerenciado por |
|---|---|
| Resource Group | Terraform |
| Storage Account | Terraform |
| Azure File Share (tier Cool) | Terraform |
| Blob Container (acesso private) | Terraform |
| Lifecycle Management Policy | Terraform |
| Automation Account + Managed Identity | Terraform |
| Runbook PowerShell | Terraform + `scripts/tiering-runbook.ps1` |
| Schedule + Job Schedule | Terraform |
| Role Assignments (RBAC) | Terraform |
| GitHub Actions Workflows | `.github/workflows/` |
| Entra ID / M365 | Manual — M365 Admin Center |

---

## 👤 Autor

**Bruno Castel**

> Este projeto é uma simulação para fins de portfólio e aprendizado. Dados e nomes de clientes são fictícios.
