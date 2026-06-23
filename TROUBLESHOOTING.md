# Microsoft Discovery デプロイ ハマりポイントまとめ

Bicep で Microsoft Discovery 基盤を `uksouth` / `discoveryRG` にデプロイしたときに踏んだ罠と解決策のメモ。

## 環境メモ

| 項目 | 値 |
|---|---|
| Subscription | `<YOUR_SUBSCRIPTION_ID>` |
| Tenant | `<YOUR_TENANT_ID>`（例: 法人テナント） |
| Resource Group | `discoveryRG` |
| Region | `uksouth`（許可: eastus / swedencentral / uksouth） |
| RP / API | `Microsoft.Discovery` / `2026-06-01`（Preview） |
| リソース接尾辞 | `lbcjdf3gsd3f6` |

---

## ① moboBroker は直接削除できない

- **症状:** `microsoft.resources/moboBrokers` を消そうとすると `UnauthorizedMoboBrokerResourceModification` エラー。
- **原因:** moboBroker は **MOBO（Managed On-Behalf-Of）** リソースで、Discovery RP が所有・管理している。ユーザーが直接消せない。
- **解決:** 親の **supercomputer（または workspace）を削除するとカスケードで消える**。個別削除は不可。RG ごと消すのが手っ取り早い。

---

## ② V2 project は chatModelDeployment が Succeeded になってから作る必要がある

- **症状:** 初回デプロイで project 作成が失敗。
  ```
  Cannot create a V2 project: no ChatModelDeployment in Succeeded state found in
  workspace 'ws-lbcjdf3gsd3f6'. Create a ChatModelDeployment and ensure it reaches
  Succeeded state before creating a project.
  ```
- **原因:** project リソースが workspace と storageContainer にしか依存しておらず、ARM が chatModelDeployment の完了を待たずに**並列で project を作りにいった**（レースコンディション）。
- **解決:** project リソースに **明示的な `dependsOn` を追加**して順序を強制。
  ```bicep
  resource project 'Microsoft.Discovery/workspaces/projects@2026-06-01' = {
    parent: workspace
    name: projectName
    location: location
    dependsOn: [
      chatModelDeployment   // ← これが重要！Succeeded を待ってから作る
    ]
    properties: {
      storageContainerIds: [
        discoveryStorageContainer.id
      ]
    }
  }
  ```

---

## ③ Discovery Studio はテナント単位でフィルタする（← 一番ハマった）

- **症状:** ARM 上では workspace も project も全部 `Succeeded` なのに、**Discovery Studio の一覧が空っぽ**（「No projects created yet」→ Workspaces 一覧まで空）。
- **原因:** Studio のログインセッションが**別テナントを見ていた**。Studio はログイン中のテナント＆アクセス可能なサブスクで一覧をフィルタするため、ARM に実体があってもテナントが違うと表示されない。
- **解決:** **Studio 右上のアバターからテナントを切り替える**（リソースを作成した正しいテナントを選ぶ）。切り替えた瞬間に workspace / project が一覧に出てきた。

### Studio 画面でのテナント確認手順

1. Studio（VS Code ベース UI）の**右上のアカウントアバター**をクリック。
2. 表示されるメニューで、**今ログインしているアカウントとテナント（ディレクトリ）**を確認する。
   - 期待値: リソースを作成したアカウント / テナント（`az account show` で確認できる `tenantId`）。
3. 違うテナントが選ばれていたら、**テナント切り替え（Switch directory / Switch tenant）**で正しいテナントを選ぶ。
4. 切り替え後に **Workspaces 一覧で「Refresh」**を押すと、ARM 上の workspace / project が表示される。
5. それでも出ない場合は、az CLI 側のテナントと突き合わせて一致しているか確認:
   ```bash
   az account show --query "{user:user.name, tenantId:tenantId}" -o json
   ```
   ここで出る `tenantId` と Studio のテナントが一致していることが条件。

- **小ワザ:** workspace の ARM プロパティに **Studio 直リンク**が入っているので、一覧で迷子になったらこれを直接開けばOK。
  ```
  workspaceUiUri: https://studio.discovery.microsoft.com/workspaces/ws-lbcjdf3gsd3f6
  ```

---

## その他メモ

- **BCP081 警告:** Bicep に Discovery の型定義が無いため出るが**無害**（Preview RP のため）。
- **`az feature register --name DiscoveryEnabled`:** `FeatureRegistrationUnsupported` エラーが出るが `|| true` で抑制してOK。プロバイダは既に Registered 済み。
- **Azure CLI クラッシュ対策:** コマンド前に `export AZURE_CORE_COLLECT_TELEMETRY=0` を付ける。
- **Preview RP の確認:** Discovery は Preview なので `az rest` で直接 RP API を叩くのが確実。デプロイの spinner を眺めるより `az rest` の status 確認のほうが情報量が多い。
- **Discovery Studio の中身:** VS Code（VS Code for the Web 系）ベースの UI。

---

## デプロイ済みリソース一覧

| リソース | 名前 | 状態 |
|---|---|---|
| supercomputer | `sc-lbcjdf3gsd3f6` | ✅ Succeeded |
| nodePool | `nodepool1` | ✅ Succeeded |
| workspace | `ws-lbcjdf3gsd3f6` | ✅ Succeeded |
| chatModelDeployment | `gpt-5-2`（gpt-5.2 / OpenAI） | ✅ Succeeded |
| storageContainer | `stc-lbcjdf3gsd3f6` | ✅ Succeeded |
| project | `prj-lbcjdf3gsd3f6` | ✅ Succeeded |
