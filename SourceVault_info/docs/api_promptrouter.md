# api_promptrouter — SourceVault PromptRouter API リファレンス

SourceVault` コンテキスト拡張。独立パッケージではなく `SourceVault.wl` の bootstrap から `Get[]` でロードされる。`Needs["ClaudeRuntime`"]` / `Needs["ClaudeOrchestrator`"]` は呼ばず、可用性は実行時に公開シンボル名から検出する。ロードは冪等。関連: [SourceVault](https://github.com/transreal/SourceVault), [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime), [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)。

PromptRoute は決定論的に prompt をコール可能関数へ振り分けるレジストリエントリ。PromptRun は実行履歴で、append-only JSONL（`<PrivateVault>/promptrouter/runs/prompt-runs.jsonl`）に保存されコンパイル済みレジストリには書かれない。

## ステータス / 可用性

### $SourceVaultPromptRouterVersion
型: String
PromptRouter 拡張のバージョン文字列。

### SourceVaultPromptRouterStatus[] → Association
拡張のバージョン・実装フェーズ、claudecode / SourceVault / ClaudeRuntime / ClaudeOrchestrator の可用性、自動 ClaudeEval ディスパッチが現在アクティブかを記述した Association を返す。

### SourceVaultPromptRouterAvailableQ[] → True|False
拡張自体が SourceVault` コンテキストにロード済みなら True。ClaudeRuntime / ClaudeOrchestrator の存在は含意しない。

### SourceVaultPromptRouterActiveQ[caller] → True|False
指定 caller のリクエストを PromptRouter が処理すべきなら True。caller は `"Manual"` | `"ClaudeEval"` | `Automatic`（既定 Automatic、`"ClaudeEval"` 扱い）。Manual API は拡張ロード時は常にアクティブ。自動 ClaudeEval ディスパッチは ClaudeOrchestrator もロード済みのときのみアクティブ。

## ルート解決 / 実行

### SourceVaultResolvePromptRoute[prompt, opts]
prompt をルート判定 Association へ解決（実行はしない）。決定論的 FunctionRoute マッチ、見つからなければ字句検索フォールバックを行う。
→ Association（Status / Decision / 抽出された正準パラメータ等）
Options: "DryRun" -> False, "AllowLLMRouter" -> Automatic, "AllowWorkflow" -> Automatic, "PrivacyLevel" -> Automatic, "StorePrompt" -> "HashOnly", "FallbackToClaudeEval" -> True, "Caller" -> Automatic

### SourceVaultExecutePromptRoute[prompt, opts]
ルートを解決し実行（resolve → adapter → allowlist チェック → ReadOnly コール可能のみディスパッチ → PromptRun 記録）。manual / test / diagnostics API で評価してよい。
→ Association（ディスパッチ不可時 `<|"Status" -> "NotDispatched", ...|>` で ClaudeEval にフォールバック）
Options: SourceVaultResolvePromptRoute と同一

### SourceVaultRouteExplain[prompt, opts] → String|Association
prompt がどう振り分けられるかの人間可読な説明を返す。

### SourceVaultProposePromptRoute[prompt_String, opts]
ClaudeEval 向け API。schedule prompt を未評価の提案式 `HoldComplete[SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]]` に解決し、それを `"ProposedExpression"` に持つ PromptRouteProposal Association を返す。式は決して評価しない。schedule 以外の prompt は Status NotDispatched。
→ Association（"ProposedExpression" フィールドを持つ）
prompt の日付範囲（「今日から3日」「今月」）は Period オプションに、その他の絞り込み（「未完了 todo」「今週の締切」）は FilterSpec リテラル Association（spec 5.4.3 の閉じた DSL: Kind And/Or/Not/Field、ホワイトリスト Op、スキーマフィールド名のみ）になる。

## PromptRun 履歴 / 記録

### SourceVaultPromptRunRecord[prompt, routeDecision, result, opts]
PromptRun レコードを append-only JSONL ストアに追記する。生の prompt テキストは既定で保存せずハッシュのみ保持。
→ `<|"Status" -> "OK"|"DryRun"|"Skipped"|"Failed", "RunId" -> ..., "Record" -> ...|>`
Options: "StorePrompt" -> "HashOnly" ("PrivateRaw" | "Off" も可), "PrivacyLevel" -> 0.0, "PrivacyOrigin" -> {}, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "Dependencies" -> <||>, "ModelResolution" -> <||>, "DryRun" -> False

### SourceVaultPromptRunHistory[opts] → List
append-only ストアから PromptRun レコードのリストを新しい順で返す。
Options: "MaxResults" -> Automatic, "RouteId" -> Automatic, "Decision" -> Automatic, "Since" -> Automatic (ISO 日時文字列; Timestamp >= Since を保持)

### SourceVaultCaptureLastPromptRun[opts]
履歴から最新の PromptRun を返す。
→ `<|"Status" -> "OK", "PromptRun" -> ...|>` または履歴が空なら Status NoPromptRun
Options: なし

### SourceVaultPromotePromptRun[runId_String, opts]
記録済み PromptRun を分類（spec 10.3）し、決定論的ルートヒットの場合のみそのルートの Matcher を run の fingerprint と生例で強化する。WorkflowRouteDraft / NeedsReview は分類のみで自動昇格しない。
→ Association（Status / Classification / Reason 等）
Options: "DryRun" -> True (既定, rule 103), "Confirm" -> False, "Channel" -> "public"

## レジストリ書き込み / 読み出し

### SourceVaultRegisterPromptRoute[route_Association, opts]
PromptRoute を compiled prompt-route-registry に追加/置換。DryRun -> False で atomic write（encode → verify → tmp → rename）。
→ Association（WrittenCount / SkippedCount / ByAction / Topic / Channel / Path 集計）
Options: "DryRun" -> True (既定, rule 103, 計画のみ報告し書き込まない), "Channel" -> "public"

### SourceVaultListPromptRoutes[opts] → List
channel の PromptRoute を返す。IncludeSeed -> True ならレジストリに未登録の RouteId について組み込み seed ルートを追加する。
Options: "IncludeSeed" -> True, "Channel" -> "public"

### SourceVaultGetPromptRoute[routeId_String, opts] → Association
指定 RouteId の PromptRoute を返す。無ければ Status NotFound の Association。
Options: "Channel" -> "public", "IncludeSeed" -> True

## コール可能 allowlist

### SourceVaultCallableAllowlistRegistry[] → Association
SourceVault 所有のコール可能 allowlist。FunctionId をキーに raw Symbol / UseAsFunctionRoute / UseAsHandlerRef / SideEffectClass / OwnerPackage を保持。SourceVault.wl に実在するコール可能のみ登録（現状 SourceVaultUpcomingSchedule, SourceVaultFindNotebooks）。raw シンボルを含むため JSON レジストリには書かれない。引数を渡すと Status Failed。

### SourceVaultCallableAllowlistView[] → Association
SourceVault 所有 allowlist と、ClaudeOrchestrator ロード時はその handler allowlist（弱呼び出し）をマージした論理ビュー。FunctionRoute ディスパッチと HandlerRef 解決が参照する。キー衝突時は SourceVault 所有エントリが優先。引数を渡すと Status Failed。

## プライバシー / 信頼ドメイン / モデル解決

### SourceVaultResolvePromptPrivacy[components_Association, opts]
prompt のプライバシー寄与を単一 PrivacyLevel（全コンポーネントの Max, spec 11.2）に統合し AllowedTrustDomains / CloudFallback / CloudRouterAllowed メタを付与する。SecretCell または PrivateModelExecution コンポーネントはレベルを最低 0.75 に引き上げ、AllowedTrustDomains を {"Local","Private"} に、CloudFallback を "Deny" に制限。
→ Association（"PrivacyLevel" / "PrivacyOrigin" / "AllowedTrustDomains" / "CloudFallback" / "CloudRouterAllowed" 等）
Options: なし
components の数値キー: "PromptCellPrivacyLevel", "PromptTextPrivacyLevel", "NotebookDependencyPrivacyLevel", "ModelExecutionPrivacyFloor", "ResultPrivacyLevel", "UserSpecifiedPrivacyLevel"（欠損は 0.0）、bool キー: "SecretCell", "PrivateModelExecution"

### SourceVaultPromptPrivacyAllowsCloudRouter[level] → True|False
PrivacyLevel が 0.5 のクラウド送信境界未満のときのみ True（spec 11.5）。引数はレベル数値または privacy-resolution Association。非数値入力は unsafe 扱いで False。

### SourceVaultResolveModelForPromptRouter[query_Association, opts]
モデルリゾルバ契約層（spec 12）。query を完全な ModelIntent / WeightClass / PrivacyLevel / AllowedTrustDomains / CloudFallback / RequiredCapabilities / DegradationPolicy 契約に正規化し、ホストリゾルバ `SourceVault`SourceVaultResolve["Model", query]` を弱呼び出しする。リゾルバ不在または結果が分類不能なら NeedsModelClassification を返す。PrivacyLevel >= 0.5 で未確認（非 Local/Private）モデルはクラウドフォールバックせず NeedsPrivateModel を返す。
→ Association（Status / Requested / Resolved / FallbackKind / CloudFallbackUsed 等）。String ModelIntent 欠如時は Status Failed (MissingModelIntent)
Options: なし
query 既定: "ModelIntent" -> "router", "WeightClass" -> Automatic, "PrivacyLevel" -> 0.0, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "RequiredCapabilities" -> {"TextIn","TextOut"}, "DegradationPolicy" -> "Flexible"

### SourceVaultClassifyProviderTrustDomain[label] → String|Missing
プロバイダ/ルートラベルを TrustDomain にマッピング（spec 12.2）。"chatgptcodex" / "ChatGPTCodexCLI" / "ClaudeCodeCLI" / "CloudLLM" / "anthropic" / "openai" → "Cloud"; "LocalOnly" / "local" → "Local"; "PrivateLLM" / "private" → "Private"。曖昧/未知（LocalOpenAICompatible, ExternalAPI 等）は `Missing["UnclassifiedTrustDomain"]`。ChatGPT Codex はクラウドバックの CLI（sandbox はローカルだが推論はクラウド）。

## 再処理計画

### SourceVaultPromptReprocessPlan[opts]
PromptRoute レジストリを走査し stale ルート（SchemaVersion / CompiledRegistryVersion 不一致、または StaleRouteIds オプション指定）を読み取り専用の再処理計画として返す。再処理は決して行わない。
→ Association（stale ルートと分類: ReadOnly FunctionRoute → "AutoRecomputable", Intent/TabularQuery → "OnDemandRefresh", WorkflowRoute → "NeedsApproval"）
Options: "StaleRouteIds" -> {}, "Channel" -> "public"

## プロンプト保存 / 検索 / 表示 (Phase D UI)

### SaveLastPrompt[memo_String, opts]
直近の成功した ClaudeEval / ContinueEval prompt run を名前付き PromptRoute として保存し、後で検索・再実行可能にする。memo は自由記述のメモで route の Memo フィールドに保存されテーブルに表示される。プライバシーは SourceVaultResolvePromptPrivacy で追跡。生 prompt/function は既定で平文保存だが PrivacyLevel と CloudFallback は route に記録される。
→ Association（Status / RouteId 等）
Options: "Channel" -> Automatic ("public"|"private"|"local", privacy から解決), "Encrypt" -> False (at-rest 暗号化は未実装; True は Status NotImplemented を返す), "DryRun" -> False, "RouteId" -> Automatic

### SourceVaultSearchPromptRoutes[query_String, opts] → List
prompt 例または memo に query を部分文字列として含む保存済み PromptRoute を返す（SourceVaultFindNotebooks Keywords と同様の部分一致）。query "" は全件マッチ。実行はしない。
Options: "CreatedAt" -> <|"From"->_,"To"->_|> (定義日でフィルタ), "UpdatedAt" -> <|"From"->_,"To"->_|> (最終更新日でフィルタ), "Channel" -> All ("public"|"private"|"local"), "IncludeSeed" -> True

### SourceVaultFormatPromptRouteList[routes_List, opts] → Grid
保存済み PromptRoute を Grid（列: Prompt, Memo, Target, CreatedAt, UpdatedAt, Privacy）として描画。各行に 3 ボタン: Preview（dry-run, 実行せず内容表示）、Run（即実行）、ToInput（保存済み関数呼び出し式を新規 Input セルに書き込む）。SourceVaultFormatNotebookList をミラー。prompt で要求された prompt-route リストの既定表示形式。
例: SourceVaultFormatPromptRouteList[SourceVaultSearchPromptRoutes["schedule"]]