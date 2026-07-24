#Requires -Version 5.1
<#
.SYNOPSIS
    Microsoft Discovery インフラ デプロイスクリプト (Bicep クイックスタート)

.DESCRIPTION
    参考: https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep

.EXAMPLE
    ./deploy.ps1
    既定値 (uksouth / discoveryRG) でデプロイ

.EXAMPLE
    ./deploy.ps1 -Location eastus
    リージョンを変更 (対応: eastus/uksouth/swedencentral)

.EXAMPLE
    ./deploy.ps1 -ResourceGroup myDiscoveryRG
    リソースグループ名を変更
#>
[CmdletBinding()]
param(
    [string]$Location       = $(if ($env:LOCATION)        { $env:LOCATION }        else { 'uksouth' }),
    [string]$ResourceGroup  = $(if ($env:RG)              { $env:RG }              else { 'discoveryRG' }),
    [string]$DeploymentName = $(if ($env:DEPLOYMENT_NAME) { $env:DEPLOYMENT_NAME } else { "discovery-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }),
    [string]$TemplateFile   = $(if ($env:TEMPLATE_FILE)   { $env:TEMPLATE_FILE }   else { 'main.bicep' })
)

$ErrorActionPreference = 'Stop'

# az CLI のテレメトリ収集を無効化 (環境によってはクラッシュ回避のため必須)
$env:AZURE_CORE_COLLECT_TELEMETRY = '0'

Write-Host '=================================================='
Write-Host ' Microsoft Discovery デプロイ'
Write-Host "   リージョン        : $Location"
Write-Host "   リソースグループ  : $ResourceGroup"
Write-Host "   デプロイ名        : $DeploymentName"
Write-Host "   テンプレート      : $TemplateFile"
Write-Host '=================================================='

# ------------------------------------------------------------------
# 1. ログイン確認
# ------------------------------------------------------------------
Write-Host '[1/5] ログイン状態を確認...'
$subId   = az account show --query id   -o tsv
if ($LASTEXITCODE -ne 0) { throw 'az account show に失敗しました。az login を実行してください。' }
$subName = az account show --query name -o tsv
Write-Host "      サブスクリプション: $subName ($subId)"

# ------------------------------------------------------------------
# 2. リソースプロバイダー & フィーチャー登録
#    ※ Discovery はプレビューのため、登録が完了していないと
#      "Cannot access Supercomputer" 等のエラーになり得る
# ------------------------------------------------------------------
Write-Host '[2/5] Microsoft.Discovery プロバイダーを登録...'
az feature register --namespace Microsoft.Discovery --name DiscoveryEnabled --only-show-errors *> $null
az provider register --namespace Microsoft.Discovery --only-show-errors *> $null
if ($LASTEXITCODE -ne 0) { throw 'プロバイダー登録に失敗しました。' }

# 登録完了まで待機 (最大5分)
for ($i = 1; $i -le 30; $i++) {
    $state = az provider show --namespace Microsoft.Discovery --query registrationState -o tsv
    if ($state -eq 'Registered') {
        Write-Host "      プロバイダー登録済み: $state"
        break
    }
    Write-Host "      登録待機中 ($state)... $i/30"
    Start-Sleep -Seconds 10
}

# ------------------------------------------------------------------
# 3. リソースグループ作成 (べき等)
# ------------------------------------------------------------------
Write-Host '[3/5] リソースグループを作成...'
az group create --name $ResourceGroup --location $Location --only-show-errors -o none
if ($LASTEXITCODE -ne 0) { throw "リソースグループの作成に失敗しました: $ResourceGroup" }
Write-Host "      OK: $ResourceGroup ($Location)"

# ------------------------------------------------------------------
# 4. Bicep テンプレートの検証
# ------------------------------------------------------------------
Write-Host '[4/5] テンプレートを検証 (what-if 省略, validate のみ)...'
az deployment group validate `
    --resource-group $ResourceGroup `
    --template-file $TemplateFile `
    --parameters location=$Location `
    --only-show-errors -o none
if ($LASTEXITCODE -ne 0) { throw 'テンプレートの検証に失敗しました。' }
Write-Host '      検証 OK'

# ------------------------------------------------------------------
# 5. デプロイ実行
# ------------------------------------------------------------------
Write-Host '[5/5] デプロイ実行 (スパコン作成に20分以上かかる場合があります)...'
az deployment group create `
    --resource-group $ResourceGroup `
    --name $DeploymentName `
    --template-file $TemplateFile `
    --parameters location=$Location `
    --query "{state:properties.provisioningState, ws:properties.outputs.workspaceId.value}" `
    -o json
if ($LASTEXITCODE -ne 0) { throw 'デプロイに失敗しました。' }

Write-Host '=================================================='
Write-Host ' 完了。各リソースの状態は以下で確認できます:'
Write-Host "   az resource list -g $ResourceGroup --query `"[?contains(type,'Microsoft.Discovery')].{name:name,type:type}`" -o table"
Write-Host '=================================================='
