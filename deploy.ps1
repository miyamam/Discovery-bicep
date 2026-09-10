#Requires -Version 5.1
<#
.SYNOPSIS
    Microsoft Discovery インフラ デプロイスクリプト (Bicep クイックスタート)

.DESCRIPTION
    参考: https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep

.EXAMPLE
    ./deploy.ps1
    既定値 (swedencentral / discoveryRG) でデプロイ

.EXAMPLE
    ./deploy.ps1 -Location eastus
    リージョンを変更 (対応: eastus/uksouth/swedencentral)

.EXAMPLE
    ./deploy.ps1 -ResourceGroup myDiscoveryRG
    リソースグループ名を変更
#>
[CmdletBinding()]
param(
    [string]$Location       = $(if ($env:LOCATION)        { $env:LOCATION }        else { 'swedencentral' }),
    [string]$ResourceGroup  = $(if ($env:RG)              { $env:RG }              else { 'discoveryRG' }),
    [string]$DeploymentName = $(if ($env:DEPLOYMENT_NAME) { $env:DEPLOYMENT_NAME } else { "discovery-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }),
    [string]$TemplateFile   = $(if ($env:TEMPLATE_FILE)   { $env:TEMPLATE_FILE }   else { 'main.bicep' }),

    # Entra Object IDs to grant "Microsoft Discovery Platform Administrator (Preview)"
    # on the resource group. Required for Discovery Studio (data-plane) access.
    # Defaults to the currently signed-in user so the deployer can immediately
    # create Agents / Projects in Studio after the deployment completes.
    # Override to add more users:
    #   ./deploy.ps1 -WorkspaceAdmins @('<objId1>','<objId2>')
    [string[]]$WorkspaceAdmins = @(),

    [ValidateSet('User','Group','ServicePrincipal')]
    [string]$WorkspaceAdminType = 'User'
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

# サインイン中のユーザーの Object ID を取得 (Discovery Studio 管理者権限付与に使用)
if ($WorkspaceAdmins.Count -eq 0) {
    $currentUserId = az ad signed-in-user show --query id -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $currentUserId) {
        $WorkspaceAdmins = @($currentUserId)
        Write-Host "      Discovery Studio 管理者 (自動): $currentUserId"
    } else {
        Write-Warning 'サインインユーザーの Object ID を取得できませんでした (Service Principal でログイン中?)。Discovery Studio 側の権限は付与されません。'
    }
} else {
    Write-Host "      Discovery Studio 管理者 (${WorkspaceAdminType}): $($WorkspaceAdmins -join ', ')"
}

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
# 2b. Discovery 第1パーティ SP (Discovery control-plane service App) を確認
#     App ID は固定: 92c174ac-8e41-4815-a1b7-d81b19ab03ce
#     テナントに存在しない場合は作成し、Object ID を取得して Bicep に渡す
#     Docs: https://learn.microsoft.com/en-us/azure/microsoft-discovery/how-to-configure-network-security?tabs=azure-cli#verify-the-service-principal
# ------------------------------------------------------------------
Write-Host '[2b/5] Discovery control-plane サービスプリンシパルを確認...'
$discoveryAppId = '92c174ac-8e41-4815-a1b7-d81b19ab03ce'
$discoveryPrincipalId = az ad sp show --id $discoveryAppId --query id -o tsv 2>$null
if (-not $discoveryPrincipalId) {
    Write-Host "      テナントに SP が未作成。作成します..."
    az ad sp create --id $discoveryAppId --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) { throw 'Discovery SP の作成に失敗しました。Application Administrator 権限が必要です。' }
    $discoveryPrincipalId = az ad sp show --id $discoveryAppId --query id -o tsv
}
if (-not $discoveryPrincipalId) { throw 'Discovery SP の Object ID を解決できませんでした。' }
Write-Host "      Discovery SP Object ID: $discoveryPrincipalId"

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

# 配列パラメータは JSON リテラル ["id1","id2"] 形式で渡す (PS 5.1 互換)
# ※ PowerShell → az.exe (Python launcher) はダブルクォートを剥がすため
#   バックスラッシュエスケープ (\") が必要
if ($WorkspaceAdmins.Count -gt 0) {
    $adminsJson = '[' + (($WorkspaceAdmins | ForEach-Object { '\"' + $_ + '\"' }) -join ',') + ']'
} else {
    $adminsJson = '[]'
}

az deployment group validate `
    --resource-group $ResourceGroup `
    --template-file $TemplateFile `
    --parameters location=$Location `
                 discoveryControlPlanePrincipalId=$discoveryPrincipalId `
                 workspaceAdminPrincipalIds=$adminsJson `
                 workspaceAdminPrincipalType=$WorkspaceAdminType `
    --only-show-errors -o none
if ($LASTEXITCODE -ne 0) { throw 'テンプレートの検証に失敗しました。' }
Write-Host '      検証 OK'

# ------------------------------------------------------------------
# 5. デプロイ実行
#    ※ main.bicep には subscription() スコープのモジュールが含まれる
#      (カスタムロール作成 + Discovery SP へのロール割り当て)。
#      実行者は Subscription 上で Owner または User Access Administrator
#      権限を持つ必要があります。
# ------------------------------------------------------------------
Write-Host '[5/5] デプロイ実行 (スパコン作成に20分以上かかる場合があります)...'
az deployment group create `
    --resource-group $ResourceGroup `
    --name $DeploymentName `
    --template-file $TemplateFile `
    --parameters location=$Location `
                 discoveryControlPlanePrincipalId=$discoveryPrincipalId `
                 workspaceAdminPrincipalIds=$adminsJson `
                 workspaceAdminPrincipalType=$WorkspaceAdminType `
    --query "{state:properties.provisioningState, ws:properties.outputs.workspaceId.value}" `
    -o json
if ($LASTEXITCODE -ne 0) { throw 'デプロイに失敗しました。' }

Write-Host '=================================================='
Write-Host ' 完了。各リソースの状態は以下で確認できます:'
Write-Host "   az resource list -g $ResourceGroup --query `"[?contains(type,'Microsoft.Discovery')].{name:name,type:type}`" -o table"
Write-Host '=================================================='
