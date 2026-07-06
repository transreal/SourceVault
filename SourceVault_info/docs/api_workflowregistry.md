# SourceVault_workflowregistry API Reference

パッケージ: `SourceVault`` (context; `SourceVault.wl` から自動ロード)
依存: なし（`Global\`$packageDirectory` を基点にディレクトリ解決）。非同期実行のみ `ClaudeOrchestrator\`Workflow\`` エンジンと `ClaudeRuntime_externalrunner.wl` を遅延ロードで利用。

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

## 非同期実行 (FE を止めずに launch を走らせる)

生成ワークフローの launch を FRONT END をブロックせずに走らせる薄い配線。新しい非同期基盤は作らず、既存の External executor（`ClaudeRuntime` externalrunner + `ClaudeOrchestrator\`Workflow\`ClaudeSubmitExternalHeldExprJob`）に子カーネル評価として投げる。安全性のため完了時はノートへ summary のみ書き（single committer）、本体（View 等）は `output.wxf` に保存し `SourceVaultRunWorkflowResult` で明示取得する。

### SourceVaultRunWorkflowAsync[slug, form:"run"] → Association
外部 executor を稼働（冪等）させ、子カーネルで `SourceVaultRunWorkflowChild[slug, form, $Language]` を held 式として投入する。即座に返る（FE 非ブロック）。base SourceVault はエンジンは載せるが外部ランナーは載せないため、未定義なら先に `ClaudeRuntime_externalrunner.wl` を `Get` してから activate する。`$Language` は FE から引き継ぐ。投入成功時は内部レジストリに登録し、`ClaudeProcessList` 等に実行中ワークフローとして出す。
→ 投入結果 Association（`"Status" -> "Submitted"`, `"JobID"`, `"JobDir"`, `"WorkflowId"` 等）。基盤ロード失敗時は `<|"Status" -> "RuntimeUnavailable", "Message" -> ...|>`。
完了時、呼出元ノートに評価可能な結果取得 Input セル（`SourceVaultRunWorkflowResult["job-..."]`）が書き込まれる。
例: `SourceVault`SourceVaultRunWorkflowAsync["spec-review", "run"]`

### SourceVaultRunWorkflowChild[slug, form:"run", lang:Automatic] → expr
子カーネル本体。`BootstrapFiles` で SourceVault.wl をロード済みの外部プロセスで評価される。`$Language` を lang で上書きし、ワークフローをロードして `WorkflowInfo[]["Launch"]` の起動関数を form で呼ぶ。戻り値（View 等）は最終アクションが `output.wxf` に保存する。通常は直接呼ばず `SourceVaultRunWorkflowAsync` 経由。ロード/起動失敗時は `<|"Status" -> "LoadFailed" | "NoLaunch", ...|>`。

### SourceVaultRunWorkflowAsyncJobs[] → List
実行中（`output.wxf` 未生成・起動失敗でない）の async ジョブ一覧を返す。プロセス一覧 UI が読む。各要素は登録情報に `"JobID"` と `"Elapsed"`（経過秒）を加えた Association。呼び出し時に死亡/消滅ジョブを prune する。

### SourceVaultRunWorkflowResult[arg] → expr | Missing
async ジョブの結果本体（`output.wxf` 内 `"Result"`、無ければ全体）を取得する。多相:
- `SourceVaultRunWorkflowResult[jobDirOrId_String]`: 既存ディレクトリなら JobDir として、レジストリにある JobID ならそこから、`"job-"` 始まりなら durable job root（`ClaudeExternalJobRoot/<jobId>`）から解決（セッション跨ぎ/prune 後も完了通知セルが効く）。
- `SourceVaultRunWorkflowResult[submit_Association]`: `SourceVaultRunWorkflowAsync` の返り値（`"JobDir"` を含む）から取得。
- `SourceVaultRunWorkflowResult[]`: 最後に投入したジョブの結果（パレット「▶ 実行」後の既定取得）。
→ 結果 expr、または `Missing["NotReady", jobDir]`（未完了）/ `Missing["Unreadable", f]` / `Missing["NoJobDir"]` / `Missing["NoRecentJob"]` / `Missing["BadArgument"]`。

## ワークフロー側の規約 (WorkflowInfo)

収納される各ワークフローは、自身の context に `WorkflowInfo[] → Association` を公開する規約とする。キー: `Slug` / `Name` / `Version` / `Context` / `Launch`（起動関数名の文字列） / `Routes`（プロンプトルート定義）。レジストリ／PromptRouter はこれを読んでルート登録・起動関数の解決を行う。非同期実行 `SourceVaultRunWorkflowChild` は `Launch` の起動関数名を解決して呼ぶため、`Launch` は必須。

## 例

```mathematica
SourceVault`SourceVaultWorkflows[]
(* → {<|"Slug" -> "spec-review", "Context" -> "SourceVaultWorkflow`SpecReview`",
        "Loaded" -> False, ...|>} *)

SourceVault`SourceVaultLoadWorkflow["spec-review"]
(* → <|"Status" -> "Loaded", "Context" -> "SourceVaultWorkflow`SpecReview`", ...|> *)

SourceVaultWorkflow`SpecReview`WorkflowInfo[]
SourceVaultWorkflow`SpecReview`RunSpecReview["proj", "MaxRounds" -> 3]

(* 非同期: FE を止めずに走らせ、完了後に結果を取得 *)
sub = SourceVault`SourceVaultRunWorkflowAsync["spec-review", "run"];
SourceVault`SourceVaultRunWorkflowAsyncJobs[]        (* 実行中ジョブ + 経過秒 *)
SourceVault`SourceVaultRunWorkflowResult[sub]        (* 完了後: 結果本体 *)
SourceVault`SourceVaultRunWorkflowResult[]           (* 最後のジョブの結果 *)
```

実行例の全体は [`examples/workflow_spec_review_example.md`](examples/workflow_spec_review_example.md) を参照。