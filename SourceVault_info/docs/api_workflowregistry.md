# SourceVault_workflowregistry API Reference

パッケージ: `SourceVault`` (context; `SourceVault.wl` から自動ロード)
依存: なし（`Global\`$packageDirectory` を基点にディレクトリ解決）

## 概要

`SourceVault_workflows/<slug>/` 配下に収納されたコード化ワークフローを **オンデマンドでロード**するレジストリ。ワークフローは普段ロードされず、PromptRouter のルートやパレットから必要時にだけ読み込まれる。

各ワークフローは独立した context `SourceVaultWorkflow\`<CanonicalSlug>\`` に分離され、private は通常の `Begin["\`Private\`"]` で隔離されるため、同一セッションに複数を同時ロードしてもシンボルが衝突しない。slug の一意性はディスク上のフォルダ名で担保される。利用形態・収納規約の詳細は user_manual の「SourceVault ワークフロー」節を参照。

## stage (テスト中 / 運用中) の分離

仕様実装で生成されたワークフローは、試行錯誤版と実運用版が混在しないよう **2 つの予約サブフォルダ**に分けて格納する:

```
SourceVault_workflows/
  spec-review/                 ← システムワークフロー (ルート据え置き・分類対象外, stage="system")
  spec-impl/                   ← システムワークフロー
  testing/<slug>/              ← テスト中
  production/<slug>/           ← 運用中
```

- 新規生成は必ず `testing` に入る。テスト OK で `production` へ昇格＝フォルダ移動。
- slug は root / testing / production を通じて **グローバルに一意**（`"testing"` と `"production"` は予約名で slug にできない）。
- stage の真実源は **フォルダ位置**。`SourceVaultLoadWorkflow` / `SourceVaultWorkflowFolder` は 3 か所を横断解決するので、移動しても呼び出し側は透過。
- stage の取得・切替・束ねオブジェクト・横断検索・一覧 UI は `SourceVault_workflowcatalog.wl`（[api_workflowcatalog.md](api_workflowcatalog.md)）が提供する。

## 公開関数

### SourceVaultWorkflowDirectory[] → String
コード化ワークフローの収納ルート `<packageRoot>/SourceVault_workflows` を返す。packageRoot は `Global\`$packageDirectory` を優先し、無ければロード時に捕捉した自身のディレクトリへフォールバックする。

### $SourceVaultWorkflowStages → {"testing", "production"}
生成ワークフローを分けて格納する予約サブフォルダ名。これらの名前は slug に使えない。

### SourceVaultWorkflowStageDirectory[stage] → String
stage（`"testing"` | `"production"`）の収納ディレクトリ `<root>/<stage>` を返す。

### SourceVaultWorkflowFolder[slug] → String | Missing
slug の実フォルダパスを root（system）/ testing / production を横断して解決して返す（見つからなければ `Missing["NotFound"]`）。stage を跨いだ参照はこの関数経由にすること。

### SourceVaultWorkflowContext[slug] → String
slug を CamelCase 正規化したワークフロー context 文字列 `"SourceVaultWorkflow\`<CanonicalSlug>\`"` を返す。例: `"spec-review"` → `"SourceVaultWorkflow\`SpecReview\`"`（非英数字で分割し各語頭を大文字化して連結）。

### SourceVaultWorkflows[] → List
`SourceVault_workflows/` 配下の収納済みワークフロー一覧を返す。各要素は `<|"Slug", "Stage", "Path", "MainFile", "Context", "Loaded"|>`。`Stage` は `"system"`（ルート直下）/ `"testing"` / `"production"`。`MainFile` は `<slug>/` 直下の `.wl`（`_info` サブディレクトリは除外、深さ 1 で探索）。`Loaded` は context が `$Packages` にあるか。

### SourceVaultLoadWorkflow[slug] → Association
slug の実フォルダ（root / testing / production を横断解決）にあるワークフロー本体 `.wl` をオンデマンドで `Get` し、`<|"Status", "Slug", "Context", "Path"|>` を返す。冪等で、既にロード済み（context が `$Packages` にある）なら `Get` せず `"AlreadyLoaded"` を返す（フォルダが stage 間で移動しても透過）。ワークフロー本体は依存（`ClaudeOrchestrator\`Workflow\`` / `SourceVault\``）を自己ブートストラップする。`$CharacterEncoding` は `"UTF-8"` に固定してロードする。

- `"Status"`: `"Loaded"` | `"AlreadyLoaded"` | `"NotFound"`（フォルダ無し） | `"NoMainFile"`（`.wl` 無し） | `"LoadFailed"`（`Get` 失敗）

## ワークフロー側の規約 (WorkflowInfo)

収納される各ワークフローは、自身の context に `WorkflowInfo[] → Association` を公開する規約とする。キー: `Slug` / `Name` / `Version` / `Context` / `Launch`（起動関数名の文字列） / `Routes`（プロンプトルート定義）。レジストリ／PromptRouter はこれを読んでルート登録・起動関数の解決を行う。

## 例

```mathematica
SourceVault`SourceVaultWorkflows[]
(* → {<|"Slug" -> "spec-review", "Context" -> "SourceVaultWorkflow`SpecReview`",
        "Loaded" -> False, ...|>} *)

SourceVault`SourceVaultLoadWorkflow["spec-review"]
(* → <|"Status" -> "Loaded", "Context" -> "SourceVaultWorkflow`SpecReview`", ...|> *)

SourceVaultWorkflow`SpecReview`WorkflowInfo[]
SourceVaultWorkflow`SpecReview`RunSpecReview["proj", "MaxRounds" -> 3]
```

実行例の全体は [`examples/workflow_spec_review_example.md`](examples/workflow_spec_review_example.md) を参照。