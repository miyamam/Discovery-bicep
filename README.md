# Microsoft Discovery インフラ 導入手順書

Bicep を使って Microsoft Discovery のインフラ一式を Azure にデプロイするための手順書です。
公式クイックスタート（[Bicep を使用してインフラストラクチャをデプロイする](https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep)）をベースに、実際の導入で **詰まりやすいポイントと回避策** をまとめています。

> ⚠️ Microsoft Discovery は **プレビュー** サービスです。API バージョン・対応リージョン・挙動が予告なく変わる可能性があります。

---

## 1. 構成されるリソース

`main.bicep` を 1 回デプロイすると、以下が作成されます。

| カテゴリ     | リソース                               | 役割                                                                             |
| ------------ | -------------------------------------- | -------------------------------------------------------------------------------- |
| ネットワーク | 仮想ネットワーク + 6 サブネット        | スパコン/ワークスペース/エージェント/プライベートエンドポイント用                |
| ID           | ユーザー割り当てマネージド ID (UAMI)   | 各 Discovery リソースの実行 ID                                                   |
| ストレージ   | ストレージアカウント + Blob コンテナー | Discovery の出力保存先                                                           |
| Discovery    | Supercomputer（スパコン）              | 計算基盤（内部で AKS を構築）                                                    |
| Discovery    | Node Pool                              | スパコンのノードプール                                                           |
| Discovery    | Workspace                              | Discovery のワークスペース                                                       |
| Discovery    | Chat Model Deployment                  | チャットモデル（gpt-5.2 など）                                                   |
| Discovery    | Storage Container                      | Discovery 用ストレージ参照                                                       |
| Discovery    | Project                                | ワークスペース配下のプロジェクト                                                 |
| RBAC         | 3 つのロール割り当て                   | UAMI へ Storage Blob Data Contributor / Discovery Platform Contributor / AcrPull |

---

## 2. 前提条件（デプロイ前チェックリスト）

- [ ] **Azure CLI 2.60 以降**（推奨: 最新）
  ```bash
  az version
  ```
- [ ] 対象サブスクリプションに **所有者（Owner）** ロールを持っていること
- [ ] **Microsoft Discovery の利用が承認済み** のサブスクリプションであること
- [ ] デプロイ先が **対応リージョン** であること（後述）
- [ ] 十分な **クォータ**（特に `Standard_D4s_v6` の vCPU）が確保されていること

### 対応リージョン

Microsoft Discovery のリソースは **デフォルトでネットワーク強化（Network Security Perimeter / NSP）** されます。その NSP が対応しているのは以下の **3 リージョンのみ** で、これが実質の対応リージョンになります（[公式: Network security for Microsoft Discovery](https://learn.microsoft.com/azure/microsoft-discovery/concept-network-security#limitations)）。

| リージョン     | リージョン識別子  |
| -------------- | ----------------- |
| East US        | `eastus`        |
| UK South       | `uksouth`       |
| Sweden Central | `swedencentral` |

> ⚠️ **East US 2（`eastus2`）は非対応** です。Storage Discovery（別サービス）では eastus2 が使えますが、本サービス（Microsoft Discovery）とは異なるので混同に注意。

`main.bicep` の `location` 既定値は **`uksouth`** で、`@allowed` リストもこの 3 リージョンに限定済みです。

---

## 3. クイックスタート（最短手順）

```bash
# 1. ログイン & サブスクリプション選択
az login
az account set --subscription "<サブスクリプションID>"

# 2. ワンコマンドデプロイ（プロバイダー登録・RG作成・検証・デプロイを自動実行）
./deploy.sh

# リージョンやRG名を変える場合（対応リージョンは eastus / uksouth / swedencentral）
LOCATION=eastus RG=myDiscoveryRG ./deploy.sh
```

`deploy.sh` は以下を自動でやってくれます。

1. ログイン状態の確認
2. `Microsoft.Discovery` プロバイダー & `DiscoveryEnabled` フィーチャーの登録（登録完了まで待機）
3. リソースグループ作成（べき等）
4. Bicep テンプレートの検証
5. デプロイ実行

---

## 4. 手動デプロイ（スクリプトを使わない場合）

```bash
# テレメトリ起因のクラッシュを避けるおまじない
export AZURE_CORE_COLLECT_TELEMETRY=0

# プロバイダー & フィーチャー登録
az feature register --namespace Microsoft.Discovery --name DiscoveryEnabled
az provider register --namespace Microsoft.Discovery
# 状態が Registered になるまで待つ
az provider show --namespace Microsoft.Discovery --query registrationState -o tsv

# リソースグループ作成
az group create --name discoveryRG --location uksouth

# デプロイ
az deployment group create \
  --resource-group discoveryRG \
  --name discovery-deploy \
  --template-file main.bicep \
  --parameters location=uksouth
```

### デプロイ状況の確認

```bash
# Discovery 系リソースの一覧と状態
az resource list -g discoveryRG \
  --query "[?contains(type,'Microsoft.Discovery')].{name:name,type:type}" -o table

# ワークスペースのプロビジョニング状態
az rest --method get \
  --url "https://management.azure.com/subscriptions/<SUB>/resourceGroups/discoveryRG/providers/Microsoft.Discovery/workspaces/<WS名>?api-version=2026-06-01" \
  --query "properties.provisioningState" -o tsv
```

---

## 5. ⚠️ 詰まりポイントと回避策（実体験ベース）

### 5-1. API バージョンは `2026-06-01` 必須

Discovery リソースは **`2026-06-01`** で動作確認しています。古い API バージョンを混在させると作成に失敗します。`main.bicep` 内の `Microsoft.Discovery/*` は全てこのバージョンに揃えてください。

### 5-2. スパコンの「Succeeded」≠ 完全な準備完了

スパコンの `provisioningState` が `Succeeded` になっても、内部の **AKS クラスター構築にさらに 20 分前後** かかることがあります。ワークスペースを続けてデプロイすると早すぎて失敗するケースがあるため、Bicep では `workspace` に `dependsOn: [nodePool]` を付けて順序を保証しています。

### 5-3. `Cannot access Supercomputer '...'` エラー

ワークスペース作成時に以下が出る場合があります。

```
Cannot access Supercomputer '.../sc-xxxx' or it does not exist
```

切り分けポイント:

- スパコン本体が `Succeeded` で **直接 GET 可能** か確認
- UAMI に **Discovery Platform Contributor** ロールが付与されているか確認
- それでも解消しない場合、**`supercomputerIds` を空 `[]` にするとワークスペース作成だけは通る** → リンク検証側の問題と切り分け可能
- 全要因（権限/ネットワーク/リージョン/プロバイダ登録）がクリーンでも解消しない場合は **プレビューのバックエンド事象** の可能性が高いため、リージョンを変えて再試行 or サポートへエスカレーション

> 💡 ヒント: リソース名は `uniqueString(resourceGroup().id)` から決まるため、**同じ RG を作り直すと同名のリソース** になります。詰まったリソースが残っている状態で再デプロイすると引きずられることがあるので、**RG ごと削除 → 作り直し** でクリーンスタートするのが確実です。

### 5-4. `joinPerimeterRule/action` 権限エラー（ネットワーク強化構成）

ネットワークセキュリティ境界（NSP）を使う構成で、Discovery コントロールプレーンが NSP の受信規則を作成できずに失敗する場合があります。その際は同梱の **`nsp-perimeter-joiner-role.json`** をカスタムロールとして作成し、Discovery のファーストパーティ SP（アプリ ID `92c174ac-8e41-4815-a1b7-d81b19ab03ce`）に割り当てます。

```bash
# カスタムロール作成
az role definition create --role-definition nsp-perimeter-joiner-role.json

# Discovery ファーストパーティ SP に割り当て
SP_OBJ=$(az ad sp show --id 92c174ac-8e41-4815-a1b7-d81b19ab03ce --query id -o tsv)
az role assignment create \
  --assignee-object-id "${SP_OBJ}" \
  --assignee-principal-type ServicePrincipal \
  --role "Discovery NSP Perimeter Joiner FDPO" \
  --scope "/subscriptions/<サブスクリプションID>"
```

### 5-5. `az` コマンドがテレメトリでクラッシュする

一部環境で `az rest` 実行時にテレメトリ収集がクラッシュ要因になります。実行前に必ず:

```bash
export AZURE_CORE_COLLECT_TELEMETRY=0
```

（`deploy.sh` では自動設定済み）

### 5-6. クォータ不足

`Standard_D4s_v6` の vCPU クォータが不足しているとノードプール作成に失敗します。事前に確認・申請してください。

```bash
az vm list-usage --location uksouth \
  --query "[?contains(localName,'D4s_v6')]" -o table
```

---

## 6. クリーンアップ

```bash
# RG ごと削除（中の Discovery リソース・管理用 RG も連動削除）
az group delete --name discoveryRG --yes --no-wait
```

> Discovery のスパコン/ワークスペースは **管理用リソースグループ（`mrg-...`）** を自動生成します。RG 削除でまとめて消えますが、稀に管理用 RG が残る場合は個別に削除してください。

---

## 7. ファイル一覧

| ファイル                           | 説明                                             |
| ---------------------------------- | ------------------------------------------------ |
| `main.bicep`                     | Discovery インフラ一式の Bicep テンプレート      |
| `deploy.sh`                      | プロバイダー登録〜デプロイを自動化するスクリプト |
| `nsp-perimeter-joiner-role.json` | NSP 構成時に使うカスタムロール定義               |
| `README.md`                      | 本手順書                                         |

---

## 8. 参考リンク

- [Microsoft Discovery ドキュメント](https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/)
- [Bicep でインフラをデプロイする（クイックスタート）](https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep)
