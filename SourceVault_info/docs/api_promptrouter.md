# SourceVault_promptrouter API リファレンス

SourceVault` 拡張パッケージ。PromptRouter（プロンプト→ルート解決・実行・履歴・登録・プライバシ伝播）機能を提供する。SourceVault.wl の bootstrap から Get[] で読み込まれ、独立パッケージではない。ClaudeRuntime / ClaudeOrchestrator への hard-depend なし（弱呼び出しのみ）。

関連: [SourceVault](https://github.com/transreal/SourceVault), [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime), [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator), [NBAccess](https://github.com/transreal/NBAccess)

## 変数

### $SourceVaultPromptRouterVersion
型: String
PromptRouter 拡張のバージョン文字列。

## ステータス / 可用性

### SourceVaultPromptRouterStatus[] → Association
拡張のバージョン・実装フェーズ・claudecode / SourceVault / ClaudeRuntime / ClaudeOrchestrator の可用性、ClaudeEval 自動 dispatch の有効状態を返す。

### SourceVaultPromptRouterAvailableQ[] → Bool
PromptRouter 拡張自体が SourceVault` context に読み込まれていれば True。ClaudeRuntime/ClaudeOrchestrator の有無は問わない。

### SourceVaultPromptRouterActiveQ[caller] → Bool
caller からの要求を PromptRouter が処理すべきか。caller: "Manual" | "ClaudeEval" | Automatic（Automatic は "ClaudeEval" 扱い）。Manual API は常時有効。Automatic ClaudeEval dispatch は ClaudeOrchestrator が読み込まれているときのみ有効。

## ルート解決 / 実行

### SourceVaultResolvePromptRoute[prompt, opts]
prompt を実行せずにルート決定 Association に解決する（dry-run）。
→ Association（Status / Decision / RouteId / Target / Parameters / Privacy 等）
Options:
- "DryRun" -> False
- "AllowLLMRouter" -> Automatic
- "AllowWorkflow" -> Automatic
- "PrivacyLevel" -> Automatic
- "StorePrompt" -> "HashOnly" ("HashOnly" | "PrivateRaw" | "Off")
- "FallbackToClaudeEval" -> True
- "Caller" -> Automatic

### SourceVaultExecutePromptRoute[prompt, opts]
ルート解決→adapter→allowlist チェック→ReadOnly callable のみ dispatch→PromptRun 記録。未 dispatch のときは `<|"Status" -> "NotDispatched", ...|>` を返し、ClaudeEval weak-call は legacy ルートにフォールバック。
→ Association
Options: SourceVaultResolvePromptRoute と同じ

### SourceVaultRouteExplain[prompt, opts] → String | Association
prompt がどう routing されるかの人間可読な説明を返す。

### SourceVaultProposePromptRoute[prompt_String, opts]
ClaudeEval 向け PromptRouter API（spec v11 5.3）。schedule プロンプトを未評価の proposal 式 `HoldComplete[SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]]` に解決し、PromptRouteProposal Association（"ProposedExpression" キー）として返す。式は評価しない。非 schedule プロンプトでは Status "NotDispatched"。
→ Association

## PromptRun 履歴（append-only JSONL）

### SourceVaultPromptRunRecord[prompt, routeDecision, result, opts]
PromptRun を `<PrivateVault>/promptrouter/runs/prompt-runs.jsonl` に追記する。registry には書き込まない。raw prompt はデフォルト未保存（hash のみ）。
→ `<|"Status" -> "OK"|"DryRun"|"Skipped"|"Failed", "RunId" -> _, "Record" -> _|>`
Options:
- "StorePrompt" -> "HashOnly" ("PrivateRaw" | "Off" も可)
- "PrivacyLevel" -> 0.0
- "PrivacyOrigin" -> {}
- "AllowedTrustDomains" -> Automatic
- "CloudFallback" -> "Ask"
- "Dependencies" -> <||>
- "ModelResolution" -> <||>
- "DryRun" -> False

### SourceVaultPromptRunHistory[opts] → List[Association]
PromptRun 履歴を newest-first で返す。
Options:
- "MaxResults" -> Automatic
- "RouteId" -> Automatic
- "Decision" -> Automatic
- "Since" -> Automatic（ISO 日時文字列、Timestamp >= Since を残す）

### SourceVaultCaptureLastPromptRun[opts] → Association
最新の PromptRun を `<|"Status" -> "OK", "PromptRun" -> _|>` で返す。履歴空のときは Status "NoPromptRun"。

### SourceVaultPromotePromptRun[runId_String, opts]
PromptRun を分類（spec 10.3）し、deterministic ヒットならその route の Matcher に fingerprint と raw 例を強化追加する。workflow trace / LLM-only run は分類のみで auto-promote しない。
→ Association（Status / Classification 等）
Options:
- "DryRun" -> True（rule 103 デフォルト）
- "Confirm" -> False
- "Channel" -> "public"

## Callable Allowlist

### SourceVaultCallableAllowlistRegistry[] → Association
SourceVault 所有の callable allowlist。FunctionId をキーに、raw Symbol / UseAsFunctionRoute / UseAsHandlerRef / SideEffectClass / OwnerPackage を保持。現在 `SourceVaultUpcomingSchedule` と `SourceVaultFindNotebooks` のみ登録。

### SourceVaultCallableAllowlistView[] → Association
SourceVault 所有 allowlist と、ClaudeOrchestrator が読み込まれていればその handler allowlist を弱呼び出しで取得しマージしたビュー。SourceVault 所有エントリがキー衝突時に優先。FunctionRoute dispatch / HandlerRef 解決の参照元。

## PromptRoute 登録 / 取得

### SourceVaultRegisterPromptRoute[route_Association, opts]
PromptRoute を compiled prompt-route-registry に追加または置換。atomic write（encode→verify→tmp→rename, Windows-safe）。
→ Association（WrittenCount / SkippedCount / ByAction / Topic / Channel / Path）
Options:
- "DryRun" -> True（rule 103 デフォルト、計画のみ報告）
- "Confirm" -> False
- "Channel" -> "public"

### SourceVaultListPromptRoutes[opts] → List[Association]
channel の PromptRoute 群を返す。
Options:
- "Channel" -> "public"
- "IncludeSeed" -> True（registry に無い RouteId について built-in seed を追加）

### SourceVaultGetPromptRoute[routeId_String, opts] → Association
RouteId の PromptRoute を返す。無ければ Status "NotFound"。

### SourceVaultSearchPromptRoutes[query_String, opts] → List[Association]
保存済み PromptRoute のうち prompt 例 / memo に query を部分一致で含むものを返す。query "" は全件。
Options:
- "CreatedAt" -> <|"From" -> _, "To" -> _|>
- "UpdatedAt" -> <|"From" -> _, "To" -> _|>
- "Channel" -> All | "public" | "private" | "local"
- "IncludeSeed" -> True

例: `SourceVaultSearchPromptRoutes["schedule", "Channel" -> "private", "UpdatedAt" -> <|"From" -> "2026-01-01"|>]`

### SourceVaultFormatPromptRouteList[routes_List, opts] → Grid
保存済み PromptRoute を Grid（列: Prompt, Memo, Target, CreatedAt, UpdatedAt, Privacy）で描画。各行に Preview（dry-run 表示）/ Run（即実行）/ ToInput（保存済み式を新 Input cell に書き出し）の 3 ボタン。

## Prompt 保存

### SaveLastPrompt[memo_String, opts]
直近成功した ClaudeEval / ContinueEval prompt run を名前付き PromptRoute として保存する。memo は自由テキスト注記。privacy は SourceVaultResolvePromptPrivacy で追跡。raw prompt / function はデフォルトで平文保存（PrivacyLevel と CloudFallback は記録）。
→ Association
Options:
- "Channel" -> Automatic（privacy から resolve、"public" | "private" | "local"）
- "Encrypt" -> False（True 指定時は Status "NotImplemented"。at-rest 暗号化は未実装）
- "DryRun" -> False
- "RouteId" -> Automatic

## プライバシ伝播

### SourceVaultResolvePromptPrivacy[components_Association, opts]
prompt の privacy 寄与（cell / prompt text / 依存 notebook / model 実行 floor / result / user override）を Max 合成し PrivacyLevel と関連メタデータを返す（spec 11.2）。SecretCell または PrivateModelExecution が True なら level を 0.75 以上に引き上げ、AllowedTrustDomains を {"Local", "Private"} に制限、CloudFallback を "Deny" に設定（spec 11.3 / 11.4）。
→ `<|"Type" -> "PromptPrivacyResolution", "PrivacyLevel" -> _, "PrivacyOrigin" -> _, "AllowedTrustDomains" -> _, "CloudFallback" -> _, "RawPromptStored" -> False, "PromptStorageClass" -> "HashOnly", "CloudRouterAllowed" -> _, "RouterVersion" -> _|>`

入力 components キー: "PromptCellPrivacyLevel", "PromptTextPrivacyLevel", "NotebookDependencyPrivacyLevel", "ModelExecutionPrivacyFloor", "ResultPrivacyLevel", "UserSpecifiedPrivacyLevel"（数値、Max 合成）、"SecretCell" (Bool)、"PrivateModelExecution" (Bool)。

### SourceVaultPromptPrivacyAllowsCloudRouter[level] → Bool
PrivacyLevel が 0.5 未満（cloud-send 境界、spec 11.5）のときのみ True。引数は数値または privacy-resolution Association。非数値入力は False。

### SourceVaultClassifyProviderTrustDomain[label_String]
provider / route ラベルを TrustDomain にマップ（spec 12.2）。
→ "Cloud" | "Local" | "Private" | Missing["UnclassifiedTrustDomain"]

マッピング:
- "Cloud": "chatgptcodex" / "codex" / "chatgptcodexcli" / "chatgpt codex" / "cloudllm" / "claudecodecli" / "claude code cli" / "claudecode" / "anthropic" / "openai"
- "Local": "localonly" / "local only" / "local" / "localonlyllm"
- "Private": "privatellm" / "private llm" / "private"
- 他（"LocalOpenAICompatible" / "ExternalAPI" など）: Missing["UnclassifiedTrustDomain"]

## Model 解決

### SourceVaultResolveModelForPromptRouter[query_Association, opts]
model resolver の contract 層（spec 12）。query を full contract に normalise し、host の `SourceVault\`SourceVaultResolve["Model", nq]` を弱呼び出しする。resolver 不在 / 結果分類不能なら Status "NeedsModelClassification" を返す。PrivacyLevel >= 0.5 で Local/Private と確認できないモデルは cloud fallback せず Status "NeedsPrivateModel" を返す（spec 12.4）。
→ Association（Status / Requested / Resolved / FallbackKind / CloudFallbackUsed / RouterVersion）

入力 query キー（normaliser がデフォルト補完）:
- "ModelIntent" (String, 必須。例 "router")
- "WeightClass" -> Automatic
- "PrivacyLevel" -> 0.0
- "AllowedTrustDomains" -> Automatic
- "CloudFallback" -> "Ask"
- "RequiredCapabilities" -> {"TextIn", "TextOut"}
- "DegradationPolicy" -> "Flexible"

ModelIntent が String でなければ Status "Failed", Reason "MissingModelIntent"。

## Reprocess Plan

### SourceVaultPromptReprocessPlan[opts] → Association
PromptRoute registry を走査し、stale な route（SchemaVersion / CompiledRegistryVersion 不一致、または StaleRouteIds 指定）の read-only 再処理計画を返す（spec 14.2 / 14.3）。何も再処理しない（計画のみ）。

分類ポリシ（spec 14.3）:
- FunctionRoute かつ ReadOnly callable → "AutoRecomputable"
- Intent ルート → "OnDemandRefresh"
- TabularQuery → "OnDemandRefresh"
- WorkflowRoute / WorkflowTemplate → "NeedsApproval"
- 不明 / 不正 → "NeedsApproval"

Options:
- "StaleRouteIds" -> {}（明示的に stale 扱いする RouteId 群）
- "Channel" -> "public"

## ルート決定 Association の主要キー（参考）

- "Status": "OK" | "NotDispatched" | "NotFound" | "Failed"
- "Decision": "DeterministicMatch" | "LexicalMatch" | "LexicalCandidates" | "NotImplemented" 等
- "RouteId": String
- "Target": `<|"Kind" -> "Function"|"Intent"|"TabularQuery"|"Workflow"|..., "FunctionId" -> _, "IntentId" -> _, "AdapterFunctionId" -> _|>`
- "Parameters": Association（canonical parameters; PeriodDays / ScopeRef / OpenTodos / DateField 等）
- "Privacy": Association（PrivacyLevel / AllowedTrustDomains / CloudFallback）
- "ApproximateRoute": Bool（ReviewQueue で PeriodDays 指定時 True）

## Adapter 変換規則（参考）

Function target: canonical params → 実 Options
- SourceVaultUpcomingSchedule: PeriodDays(Integer>0) → "Period" -> Quantity[n,"Days"]、ScopeRef.Name → "Scope"
- SourceVaultFindNotebooks: OpenTodos=True → "OpenTodos"->True、DateField="Deadline" → "Deadline"->"DueSoon"、DateField="NextReview" → "NextReview"->"DueSoon"

Intent target (spec 25.3 / 25.4):
- "ReviewQueue" → SourceVaultFindNotebooks, Options `<|"NextReview"->"DueSoon"|>`（OpenTodos=True で追加、PeriodDays 指定で ApproximateRoute=True）
- "OpenTodoList" → SourceVaultFindNotebooks, Options `<|"OpenTodos"->True|>`

## 注意

- raw prompt は本層では一切保存しない（hash のみ）。raw 保存は明示的別 opt。
- 書き込み API は DryRun -> True がデフォルト（rule 103）。
- compiled registry 書き込みは encode → verify → tmp → rename の atomic 操作（UTF-8 一貫）。
- ClaudeRuntime / ClaudeOrchestrator 不在環境でも読み込み・動作する（弱呼び出しのみ）。