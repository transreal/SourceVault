# SourceVault_promptrouter API リファレンス

SourceVault` コンテキストの PromptRouter 拡張。SourceVault.wl のブートストラップから Get[] で読み込まれる。ClaudeRuntime / ClaudeOrchestrator への hard-depend はなく、Names ベースの弱呼び出しで連携する。プロンプトを解決・実行し、PromptRun 履歴を append-only JSONL に蓄積、プライバシ伝播・モデル解決・経路登録・再処理計画・スケジュール提案を提供する。

## 変数

### $SourceVaultPromptRouterVersion
型: String
PromptRouter 拡張のバージョン文字列。

## ステータス / 可用性

### SourceVaultPromptRouterStatus[]
→ Association
バージョン、フェーズ、claudecode / SourceVault / ClaudeRuntime / ClaudeOrchestrator の可用性、ClaudeEval 自動ディスパッチの有効性を返す。

### SourceVaultPromptRouterAvailableQ[]
→ Boolean
拡張が SourceVault` コンテキストに読み込まれていれば True。ClaudeRuntime / ClaudeOrchestrator の存在は含意しない。

### SourceVaultPromptRouterActiveQ[caller]
→ Boolean
caller は "Manual" | "ClaudeEval" | Automatic(既定、"ClaudeEval" 扱い)。Manual API は拡張ロード時から常に有効。Automatic ClaudeEval ディスパッチは ClaudeOrchestrator も読み込まれている場合のみ True。

## ルート解決 / 実行

### SourceVaultResolvePromptRoute[prompt, opts]
プロンプトを解決し決定 Association を返す(実行はしない)。決定論的マッチ → 字句インデックス検索フォールバック。
→ Association(Status, Decision, RouteId, Score, Reasons, Params, ...)
Options: "DryRun" -> False, "AllowLLMRouter" -> Automatic, "AllowWorkflow" -> Automatic, "PrivacyLevel" -> Automatic, "StorePrompt" -> "HashOnly", "FallbackToClaudeEval" -> True, "Caller" -> Automatic

### SourceVaultExecutePromptRoute[prompt, opts]
解決して FunctionRoute / Intent をアダプタ経由でディスパッチする。ReadOnly callable のみ実行。Status NotDispatched の場合 ClaudeEval 既存経路へフォールバック。
→ Association
Options: SourceVaultResolvePromptRoute と同じ

### SourceVaultRouteExplain[prompt, opts]
→ String
プロンプトがどのように経路解決されるかの可読説明。

### SourceVaultProposePromptRoute[prompt_String, opts]
ClaudeEval 向け API(spec v11 5.3)。スケジュール系プロンプトを未評価の提案式に解決する。式は評価されず "ProposedExpression" フィールドに HoldComplete[SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]] として格納される。非スケジュールは Status NotDispatched。
→ Association(PromptRouteProposal, ProposedExpression, ...)
例: SourceVaultProposePromptRoute["今週のスケジュール"]

## PromptRun 履歴

### SourceVaultPromptRunRecord[prompt_String, routeDecision_Association, result, opts]
PromptRun 1 件を <PrivateVault>/promptrouter/runs/prompt-runs.jsonl に追記する。レジストリではなく履歴。生プロンプトは既定で保存せずハッシュのみ。
→ Association(Status -> "OK"|"DryRun"|"Skipped"|"Failed", RunId, Record)
Options: "StorePrompt" -> "HashOnly" ("PrivateRaw"|"Off" も可), "PrivacyLevel" -> 0.0, "PrivacyOrigin" -> {}, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "Dependencies" -> <||>, "ModelResolution" -> <||>, "DryRun" -> False

### SourceVaultPromptRunHistory[opts]
PromptRun レコードを新しい順で返す。
→ List of Association
Options: "MaxResults" -> Automatic, "RouteId" -> Automatic, "Decision" -> Automatic, "Since" -> Automatic (ISO 日時文字列、Timestamp >= Since のみ)

### SourceVaultCaptureLastPromptRun[opts]
最新の PromptRun を取得する。空なら Status NoPromptRun。
→ <|"Status" -> "OK", "PromptRun" -> ...|>
Options: なし

### SourceVaultPromotePromptRun[runId_String, opts]
記録済 PromptRun を分類し(spec 10.3)、決定論的経路ヒット(DeterministicMatch / LexicalMatch)に対してのみ Matcher にフィンガープリント・生例を追加して強化する。Workflow トレースおよび LLM-only run は分類のみで自動昇格はされない。
→ Association(Status, Classification, ...)
Options: "DryRun" -> True (既定、rule 103), "Confirm" -> False, "Channel" -> "public"

## Callable Allowlist

### SourceVaultCallableAllowlistRegistry[]
→ Association(FunctionId -> entry)
SourceVault 所有の callable allowlist。SourceVaultUpcomingSchedule と SourceVaultFindNotebooks のみ登録。各エントリは FunctionId / Symbol / UseAsFunctionRoute / UseAsHandlerRef / SideEffectClass / OwnerPackage を持つ。ReviewQueue / OpenTodoList は IntentId として扱い登録しない。

### SourceVaultCallableAllowlistView[]
→ Association
SourceVault 所有 + (ClaudeOrchestrator が読み込まれていれば弱呼び出しで取得した)Orchestrator 所有ハンドラ allowlist のマージ論理ビュー。FunctionRoute ディスパッチと HandlerRef 解決はこのビューを参照。キー衝突時は SourceVault 所有が優先。

## PromptRoute レジストリ

### SourceVaultRegisterPromptRoute[route_Association, opts]
PromptRoute を compiled prompt-route-registry に追加/置換する。原子的書き込み(encode → verify → tmp → rename)。
→ Association(WrittenCount, SkippedCount, ByAction, Topic, Channel, Path)
Options: "DryRun" -> True (既定、rule 103), "Confirm" -> False, "Channel" -> "public"

### SourceVaultListPromptRoutes[opts]
チャネルの PromptRoute 一覧を返す。
→ List of Association
Options: "Channel" -> "public", "IncludeSeed" -> True (未登録 RouteId について seed を補完)

### SourceVaultGetPromptRoute[routeId_String, opts]
→ Association(PromptRoute、または Status NotFound)
Options: "Channel" -> "public"

## プライバシ

### SourceVaultResolvePromptPrivacy[components_Association, opts]
プロンプトのプライバシ寄与を合成し、PrivacyLevel(全成分の Max、spec 11.2)および AllowedTrustDomains / CloudFallback / CloudRouterAllowed を返す。SecretCell または PrivateModelExecution が真なら PrivacyLevel を 0.75 以上に引き上げる(spec 11.3 / 11.4)。
→ <|"Type" -> "PromptPrivacyResolution", "PrivacyLevel" -> ..., "PrivacyOrigin" -> ..., "AllowedTrustDomains" -> ..., "CloudFallback" -> ..., "RawPromptStored" -> False, "PromptStorageClass" -> "HashOnly", "CloudRouterAllowed" -> ..., "RouterVersion" -> ...|>
Options: なし
components キー: "PromptCellPrivacyLevel", "PromptTextPrivacyLevel", "NotebookDependencyPrivacyLevel", "ModelExecutionPrivacyFloor", "ResultPrivacyLevel", "UserSpecifiedPrivacyLevel", "SecretCell", "PrivateModelExecution"

### SourceVaultPromptPrivacyAllowsCloudRouter[level | resolutionAssoc]
→ Boolean
PrivacyLevel が 0.5 未満(cloud-send boundary、spec 11.5)のときのみ True。数値でない入力は False。

## モデル解決

### SourceVaultResolveModelForPromptRouter[query_Association, opts]
spec 12 のモデル解決契約レイヤ。query を ModelIntent / WeightClass / PrivacyLevel / AllowedTrustDomains / CloudFallback / RequiredCapabilities / DegradationPolicy の完全契約に正規化し、SourceVault`SourceVaultResolve["Model", q] を弱呼び出しする。リゾルバ不在/結果が空/分類不能 → NeedsModelClassification。PrivacyLevel >= 0.5 で Local/Private が確認できないモデル → NeedsPrivateModel。
→ Association(Status, Requested, Resolved, FallbackKind, CloudFallbackUsed, RouterVersion)
Options: なし
query 必須キー: "ModelIntent" (String)
query 任意キー: "WeightClass" (既定 Automatic), "PrivacyLevel" (既定 0.0), "AllowedTrustDomains" (既定 Automatic), "CloudFallback" (既定 "Ask"), "RequiredCapabilities" (既定 {"TextIn","TextOut"}), "DegradationPolicy" (既定 "Flexible")

## 再処理計画

### SourceVaultPromptReprocessPlan[opts]
PromptRoute レジストリを走査し、SchemaVersion / CompiledRegistryVersion 不一致または StaleRouteIds 指定の経路を stale と判定し、読み取り専用の再処理計画を返す(spec 14.2 / 14.3)。ReadOnly FunctionRoute → "AutoRecomputable"、Intent / TabularQuery → "OnDemandRefresh"、Workflow → "NeedsApproval"。実際の再処理は行わない。
→ Association(Items, ByPolicy, Channel, ...)
Options: "Channel" -> "public", "StaleRouteIds" -> {}

## TrustDomain 分類

### SourceVaultClassifyProviderTrustDomain[label_String]
→ String | Missing
プロバイダ/ルートラベルを TrustDomain(spec 12.2)にマップする。"chatgptcodex" / "chatgpt codex" / "chatgptcodexcli" / "claudecodecli" / "cloudllm" / "anthropic" / "openai" → "Cloud"、"privatellm" / "private" → "Private"、"localonly" / "local" → "Local"、不明 → Missing["UnclassifiedTrustDomain"]。ChatGPT Codex はファイルシステムサンドボックスはローカルだが LLM 推論はクラウドのため Cloud 扱い。

## 経路スキーマ(参考)

PromptRoute Association の主なキー:
- "Type" -> "PromptRoute"
- "RouteId" -> String
- "RouteVersion" -> Integer
- "SchemaVersion" -> Integer (現行 1)
- "CompiledRegistryVersion" -> Integer (現行 1)
- "Matcher" -> <|"Kind" -> "DeterministicPattern", "KeywordsAny" -> {String...}|>
- "Target" -> <|"Kind" -> "Function" | "Intent" | "TabularQuery" | "WorkflowTemplate" | "Workflow", "FunctionId" | "IntentId" | "DataSource", "AdapterFunctionId" (Intent 時)|>
- "Privacy" -> <|"PrivacyLevel" -> Real, "PrivacyOrigin" -> List, "AllowedTrustDomains" -> ..., "CloudFallback" -> ..., "RawPromptStored" -> False, "PromptStorageClass" -> "HashOnly"|>
- "Source" -> "SeedBuiltIn" | ...

組込 seed RouteId: "seed-sourcevault-upcoming-schedule-v1", "seed-intent-reviewqueue-v1", "seed-intent-opentodolist-v1"。

スケジュール FilterSpec DSL(spec 5.4.3、閉じた文法): Kind は And / Or / Not / Field。フィールド名は schedule スキーマの allowlist のみ: Deadline (Date), NextReview (Date), OpenTodoCount (Integer), DoneTodoCount (Integer), PassTodoCount (Integer), Status (String), Title (String), Keywords (StringList)。Function / Slot / 任意コードは不可。

関連リポジトリ: [SourceVault](https://github.com/transreal/SourceVault), [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator), [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime), [claudecode](https://github.com/transreal/claudecode), [NBAccess](https://github.com/transreal/NBAccess)