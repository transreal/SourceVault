# SourceVault_workflowregistry API Reference

パッケージ: `SourceVault`` (context; `SourceVault.wl` から自動ロード)
依存: なし（`Global\`$packageDirectory` を基点にディレクトリ解決）。非同期実行のみ `ClaudeOrchestrator\`Workflow\`` エンジンと `ClaudeRuntime_externalrunner.wl` を遅延ロードで利用。読み込み検査 (LoadVerify) は `SourceVault_integrity.wl` が載っていれば利用する。機密ジョブの封印は `SourceVault_crypto.wl` と NBAccess の `$NBCredentialBackend` を利用する。

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

## 読み込み検査 (LoadVerify)

仕様実装で生成・変更したワークフローの `.wl` は「モデルが書き得る群」なので、所有者が受け入れる（基準に入れる）まで `SourceVaultLoadWorkflow` は `"LoadDenied"` を返す。判定は内部の `iSVWFLoadVerify[main]`（`SourceVaultIntegrityLoadVerify[main, "Workflow"]` を呼ぶ）で、`SourceVaultLoadWorkflow` と `SourceVaultRunWorkflowAsync` の投入前確認が共有する。
- 戻り値は `<|"Decision" -> "Allow"|"Warn"|"Deny", "Reason" -> ..., ...|>`。
- 照合が例外・Failure で終わったら `"Reason" -> "VerifyError"`。`$SourceVaultIntegrityLoadVerifyEnforce`（既定 True）なら `"Deny"`、そうでなければ `"Warn"`。
- integrity 未ロードは `"Reason" -> "IntegrityAbsent"`。強制あり かつ `$SourceVaultIntegrityBaselineAsAuthorization === False`（厳格）のときだけ `"Deny"`、他は `"Allow"`。
- `"Deny"` のとき `LoadDenied` 結果に日本語の `"Message"`（理由コード・判定 PC 名を添える）/ `"Next"`（次の手段）/ `"NextExpression"`（評価できる式の文字列、無ければ `None`）が付く。
- 理由コードと次の手段の式（所有者の操作は `SourceVaultIntegrityOwnerAction` で包まれ、評価すると ticket の窓が出る）:
  - `"UnauthorizedInstructionLoad"` / `"UnrecordedInstructionChange"`: `SourceVaultIntegrityAcceptBaseline["Instructions", "Paths" -> {本体と同フォルダ直下の .wl}, "Note" -> ...]`
  - `"AuthorizationMissing"`: `SourceVaultIntegrityAuthorizeInstruction[main, "Workflow"]`（認可は来歴の取り込み後に効くので数分かかる）
  - `"Quarantined*"` / `"UnknownDerived*"` / 他の未知コード: `SourceVaultIntegrityFindingsView[]`
  - `"NotCommitted*"` / `"IndexUnavailable*"` / `"Unreadable"` / `"VerifyError"` / `"IntegrityAbsent"`: 式なし（待って再実行 / 再ロード）
  - `"BaselineMissing"`: `SourceVaultIntegrityOwnerAction[SourceVaultIntegrityInitializeInstructions[]]`
- `LoadDenied` 結果は `<|"Status" -> "LoadDenied", "Message", "Next", "NextExpression", "Slug", "Context", "Path", "LoadVerify" -> <|"Decision", "Reason", "Group", "Class", "BlobId", "Baseline"|>|>`。
- 内部: `iSVWFDenialCells[d]` が説明の Text セルと式の Input セル（評価しない, CellTags `"SourceVaultWorkflowLoadDenied"`）を作り、`iSVWFWriteDenialCells[d]` が NBAccess 経由でボタンのあるセルの直後（番号不明ならノート末尾）へ書く。FE / NBAccess が無ければ `"NoNotebook"`、成功は `"Written"`。

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
slug の実フォルダ（root / testing / production を横断解決）にあるワークフロー本体 `.wl` をオンデマンドで `Get` し、`<|"Status", "Slug", "Context", "Path", "LoadVerify"|>` を返す。冪等で、既にロード済み（context が `$Packages` にある）なら検査も `Get` もせず `"AlreadyLoaded"` を返す（フォルダが stage 間で移動しても透過）。`Get` の直前に読み込み検査（上記）を行い、`"Deny"` なら読み込まず `"LoadDenied"` を返す。ワークフロー本体は依存（`ClaudeOrchestrator\`Workflow\`` / `SourceVault\``）を自己ブートストラップする。`$CharacterEncoding` は `"UTF-8"` に固定してロードする。成否は message の有無でなく context が実際に登録されたかで判定する。

- `"Status"`: `"Loaded"` | `"AlreadyLoaded"` | `"NotFound"`（フォルダ無し） | `"NoMainFile"`（`.wl` 無し） | `"LoadDenied"`（読み込み検査で停止） | `"LoadFailed"`（context が登録されない）
- `"LoadVerify"`: `"Loaded"`/`"LoadFailed"` 時は `KeyTake[lv, {"Decision", "Reason", "Group", "Class"}]`（検査結果が Association でなければ `Null`）

## 非同期実行 (FE を止めずに launch を走らせる)

生成ワークフローの launch を FRONT END をブロックせずに走らせる薄い配線。新しい非同期基盤は作らず、既存の External executor（[ClaudeRuntime_externalrunner](https://github.com/transreal/ClaudeRuntime_externalrunner) + `ClaudeOrchestrator\`Workflow\`ClaudeSubmitExternalHeldExprJob`）に子カーネル評価として投げる。安全性のため完了時はノートへ summary のみ書き（single committer）、本体（View 等）は `output.wxf` に保存し `SourceVaultRunWorkflowResult` で明示取得する。

### SourceVaultRunWorkflowAsync[slug, form:"run", opts]
外部 executor を稼働（冪等）させ、子カーネルで `SourceVaultRunWorkflowChild[slug, form, $Language]` を held 式として投入する。即座に返る（FE 非ブロック）。base SourceVault はエンジンは載せるが外部ランナーは載せないため、未定義なら先に `ClaudeRuntime_externalrunner.wl` を `Get` してから `ClaudeActivateExternalExecutor[]` で activate する。`$Language` は FE から引き継ぐ。
→ Association。
Options: "LoadPrecheck" -> True (投入前にこの PC で読み込み検査を行う。止まるならジョブも席も使わず `LoadDenied` を返し、ボタンのセル直後に理由と式を書く。別 PC への配車 (autotrigger) は False で呼び、子の `LoadFailed`+`Message` で知らせる), "Confidential" -> True (結果を機密ジョブ `"ConfidentialHandling" -> "EncryptedBundle"` として `output.wxf` を封印する。False なら `"ReferenceOnly"` = 平文), "ResultLimit" -> 64*1024^2 (結果サイズ上限バイト。正の整数以外は `Automatic`)
処理順と戻り値:
- 投入前: `"LoadPrecheck"` が True なら `iSVWFLoadPrecheck[slug]`。`"Status" -> "LoadDenied"` なら `Append[pre, "Notebook" -> "Written"|"NoNotebook"|"WriteFailed"]` を返す。`NotFound`/`NoMainFile` は投入を止めず子の結果で知らせる。
- 基盤ロード失敗: `<|"Status" -> "RuntimeUnavailable", "Message" -> ...|>`。
- 機密の準備不足（`"Confidential" -> True` のとき）: `<|"Status" -> "ConfidentialUnavailable", "Message", "Next", "NextExpression", "Slug", "Reason", "Notebook"|>`。`NextExpression` は `SourceVaultRunWorkflowAsync[slug, form, "Confidential" -> False]` の文字列。準備不足の条件: `SourceVaultSealPayload`/`SourceVaultUnsealPayload` 未定義（SourceVault_crypto.wl 未ロード）、`NBAccess\`$NBCredentialBackend` 未設定、または `"SystemCredential"` 以外。
- 投入成功: `ClaudeSubmitExternalHeldExprJob` の返り値（`"Status" -> "Submitted"`, `"JobID"`, `"JobDir"`, `"WorkflowId"` 等）をそのまま返し、内部レジストリに登録（`ClaudeProcessList` 等に実行中として出る）。
- 投入失敗（席無し等）: 元の Association（Association でなければ `<|"Status" -> "Failed", "Result" -> sub|>`）に `"Message"`（理由コード添え）/ `"Next"` / `"NextExpression" -> None` / `"Slug"` / `"Notebook"` を付けて返す。
`ClaudeSubmitExternalHeldExprJob` へ渡す内部オプション: `"BootstrapFiles" -> {<root>/SourceVault.wl}`, `"NotifyNotebook" -> InputNotebook[]`（取得不可なら `None`）, `"ResultRetriever" -> "SourceVault`SourceVaultRunWorkflowResult"`, `"SeatPriority" -> 90`, `"ConfidentialHandling" -> "EncryptedBundle"|"ReferenceOnly"`, `"ResultLimit" -> rl`。ユーザー操作起点（FE 対話の代理実行）として優先度 90 で投入するため、FE+常駐で空きが Reserve 分のみのトポロジーでも恒久 `NoSeat` にならない。
完了時、呼出元ノートに評価可能な結果取得 Input セル（`SourceVaultRunWorkflowResult["job-..."]`）が書き込まれる。
例: `SourceVault`SourceVaultRunWorkflowAsync["spec-review", "run"]`
例: `SourceVault`SourceVaultRunWorkflowAsync["spec-review", "run", "Confidential" -> False]`（暗号化なし・平文で結果を残す）

### SourceVaultRunWorkflowChild[slug, form:"run", lang:Automatic] → expr
子カーネル本体。`BootstrapFiles` で SourceVault.wl をロード済みの外部プロセスで評価される。`lang` が文字列または文字列リストなら `$Language` を上書き（`Automatic` 等ならそのまま）し、ワークフローをロードして `WorkflowInfo[]["Launch"]` の起動関数を form で呼ぶ。戻り値（View 等）は最終アクションが `output.wxf` に保存する。通常は直接呼ばず `SourceVaultRunWorkflowAsync` 経由。
- ロード失敗: `<|"Status" -> "LoadFailed", "Message", "Slug", "NextExpression", "LoadResult"|>`。`"Message"` は日本語の説明（`LoadDenied` は `Message`+`Next` を連結し式は `"NextExpression"` と案内、`NotFound`/`NoMainFile`/`LoadFailed` は各専用文）、`"NextExpression"` は `LoadResult` のそれ（無ければ `None`）。別の PC で実行したときもその PC の判定が届く。
- `Launch` 未定義時: `<|"Status" -> "NoLaunch", "Slug", "Context"|>`。

### SourceVaultRunWorkflowAsyncJobs[] → List
実行中（`output.wxf` 未生成・起動失敗でない）の async ジョブ一覧を返す。プロセス一覧 UI が読む。各要素は登録情報（`"Slug"`, `"Form"`, `"JobDir"`, `"WorkflowId"`, `"SubmittedAt"`）に `"JobID"` と `"Elapsed"`（経過秒）を加えた Association。呼び出し時に死亡/消滅ジョブを prune する（死亡判定は `status.json` を第一根拠とし、`"Failed"`/`"Expired"` なら死亡、`"Running"` なら生存、`status.json` 未生成でも投入から 120 秒以内は誤判定を避け生存扱いとする。`pid.json` の PID は生存判定に使わない）。完了ジョブ（`output.wxf` あり）はレジストリに残るが本一覧には含まれない。

### SourceVaultRunWorkflowResult[arg] → expr | Missing | Failure
async ジョブの結果本体（`output.wxf` 内 `"Result"`、無ければ全体）を取得する。多相:
- `SourceVaultRunWorkflowResult[jobDirOrId_String]`: 既存ディレクトリなら JobDir として、レジストリにある JobID ならそこから、`"job-"` 始まりなら durable job root（`ClaudeExternalJobRoot/<jobId>`）から解決（セッション跨ぎ/prune 後も完了通知セルが効く）。
- `SourceVaultRunWorkflowResult[submit_Association]`: `SourceVaultRunWorkflowAsync` の返り値（`"JobDir"` を含む）から取得。
- `SourceVaultRunWorkflowResult[]`: 最後に投入したジョブの結果（パレット「▶ 実行」後の既定取得）。
- `SourceVaultRunWorkflowResult["View"]`: 最後のジョブの表示用。結果が Association で `"View"` キーを持てばその値、無ければ結果そのまま（行の一覧などの大きな値を FE に出さない）。
- `SourceVaultRunWorkflowResult[arg, "View"]`: `arg`（JobID・JobDir・投入の返り値の String/Association）のジョブについて同様に View を返す。
→ 結果 expr、または `Missing["NotReady", jobDir]`（未完了）/ `Missing["Unreadable", f]` / `Missing["BadJobDir"]` / `Missing["NoJobDir"]` / `Missing["NoRecentJob"]` / `Missing["BadArgument"]`。
機密ジョブの `output.wxf` は封印 record で、`SourceVaultEncryptedRecordQ` が真なら `SourceVaultUnsealPayload` でこの PC の鍵により復号する（平文には戻さない）。復号失敗（改ざん・別 PC の鍵で封印）は `Failure["ResultDecryptFailed", <|"MessageTemplate", "MessageParameters", "Path", "Detail"|>]`。

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
SourceVault`SourceVaultRunWorkflowResult["View"]     (* 最後のジョブの View のみ *)
```

実行例の全体は [`examples/workflow_spec_review_example.md`](examples/workflow_spec_review_example.md) を参照。