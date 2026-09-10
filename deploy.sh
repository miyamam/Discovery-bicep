#!/usr/bin/env bash
#
# Microsoft Discovery インフラ デプロイスクリプト (Bicep クイックスタート)
# 参考: https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep
#
# 使い方:
#   ./deploy.sh                  # 既定値 (swedencentral / discoveryRG) でデプロイ
#   LOCATION=eastus ./deploy.sh  # リージョンを変更 (対応: eastus/uksouth/swedencentral)
#   RG=myDiscoveryRG ./deploy.sh # リソースグループ名を変更
#
set -euo pipefail

# ------------------------------------------------------------------
# 0. 設定 (環境変数で上書き可能)
# ------------------------------------------------------------------
LOCATION="${LOCATION:-swedencentral}"
RG="${RG:-discoveryRG}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-discovery-$(date +%Y%m%d-%H%M%S)}"
TEMPLATE_FILE="${TEMPLATE_FILE:-main.bicep}"

# az CLI のテレメトリ収集を無効化 (環境によってはクラッシュ回避のため必須)
export AZURE_CORE_COLLECT_TELEMETRY=0

echo "=================================================="
echo " Microsoft Discovery デプロイ"
echo "   リージョン        : ${LOCATION}"
echo "   リソースグループ  : ${RG}"
echo "   デプロイ名        : ${DEPLOYMENT_NAME}"
echo "   テンプレート      : ${TEMPLATE_FILE}"
echo "=================================================="

# ------------------------------------------------------------------
# 1. ログイン確認
# ------------------------------------------------------------------
echo "[1/5] ログイン状態を確認..."
SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
echo "      サブスクリプション: ${SUB_NAME} (${SUB_ID})"

# ------------------------------------------------------------------
# 2. リソースプロバイダー & フィーチャー登録
#    ※ Discovery はプレビューのため、登録が完了していないと
#      "Cannot access Supercomputer" 等のエラーになり得る
# ------------------------------------------------------------------
echo "[2/5] Microsoft.Discovery プロバイダーを登録..."
az feature register --namespace Microsoft.Discovery --name DiscoveryEnabled --only-show-errors >/dev/null || true
az provider register --namespace Microsoft.Discovery --only-show-errors >/dev/null

# 登録完了まで待機 (最大5分)
for i in $(seq 1 30); do
  STATE=$(az provider show --namespace Microsoft.Discovery --query registrationState -o tsv)
  if [ "${STATE}" = "Registered" ]; then
    echo "      プロバイダー登録済み: ${STATE}"
    break
  fi
  echo "      登録待機中 (${STATE})... ${i}/30"
  sleep 10
done

# ------------------------------------------------------------------
# 3. リソースグループ作成 (べき等)
# ------------------------------------------------------------------
echo "[3/5] リソースグループを作成..."
az group create --name "${RG}" --location "${LOCATION}" --only-show-errors -o none
echo "      OK: ${RG} (${LOCATION})"

# ------------------------------------------------------------------
# 4. Bicep テンプレートの検証
# ------------------------------------------------------------------
echo "[4/5] テンプレートを検証 (what-if 省略, validate のみ)..."
az deployment group validate \
  --resource-group "${RG}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters location="${LOCATION}" \
  --only-show-errors -o none
echo "      検証 OK"

# ------------------------------------------------------------------
# 5. デプロイ実行
# ------------------------------------------------------------------
echo "[5/5] デプロイ実行 (スパコン作成に20分以上かかる場合があります)..."
az deployment group create \
  --resource-group "${RG}" \
  --name "${DEPLOYMENT_NAME}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters location="${LOCATION}" \
  --query "{state:properties.provisioningState, ws:properties.outputs.workspaceId.value}" \
  -o json

echo "=================================================="
echo " 完了。各リソースの状態は以下で確認できます:"
echo "   az resource list -g ${RG} --query \"[?contains(type,'Microsoft.Discovery')].{name:name,type:type}\" -o table"
echo "=================================================="
