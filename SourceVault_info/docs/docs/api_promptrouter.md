# SourceVault_promptrouter API Reference

SourceVault` コンテキスト拡張。SourceVault.wl の bootstrap から `Get[]` でロードされる独立パッケージではない。ClaudeRuntime / ClaudeOrchestrator が不在でもロード可能。ロードは冪等（repeated `Get[]` で再定義される）。

## バージョン・ステータス

### $SourceVaultPromptRouterVersion
型: String
PromptRouter 拡張のバージョン文字列。

### SourceVaultPromptRouterStatus[] → Association
拡張のバージョン・実装フェーズ・claudecode / SourceVault / ClaudeRuntime / ClaudeOrchestrator の可否・ClaudeEval 自動ディスパッチの活性状態を返す。

### SourceVaultPromptRouterAvailableQ[] → True|False
PromptRouter 拡張が SourceVault` コンテキストにロード済みのとき True を返す。ClaudeRuntime / ClaudeOrchestrator の存在は意味しない。

### SourceVaultPromptRouterActiveQ[caller] → True|False
指定された呼び出し元からのリクエストを PromptRouter が処理すべき場合 True を返す。
caller: `"Manual"` | `"ClaudeEval"` | `Automatic`（デフォルト `Automatic`、`"ClaudeEval"` 扱い）。
Manual API は拡張がロードされていれば常に有効。ClaudeEval 自動ディスパッチは ClaudeOrchestrator もロード済みのときのみ有効。

## ルート解決・実行

### SourceVaultResolvePromptRoute[prompt, opts]
プロンプトをルート決定 Association に解決する（実行しない）。
→ Association `<|"Status"->_, "Decision"->_, ...|>`
Options: `"DryRun"->False`, `"AllowLLMRouter"->Automatic`, `"AllowWorkflow"->Automatic`, `"PrivacyLevel"->Automatic`, `"StorePrompt"->"HashOnly"`, `"FallbackToClaudeEval"->True`, `"Caller"->Automatic`

### SourceVaultExecutePromptRoute[prompt, opts]
プロンプトルートを解決して実行する。
→ Association `<|"Status"->_, ...|>`（Status `"NotDispatched"` のとき ClaudeEval 弱呼び出しパスがレガシールートにフォールバック）
Options: SourceVaultResolvePromptRoute と同じ。

### SourceVaultRouteExplain[prompt, opts]
プロンプトがどのようにルーティングされるかの人間可読な説明を返す。ルート解決未実装を報告し現在のルータステータスを添える。
→ String | Association

### SourceVaultProposePromptRoute[prompt_String, opts]
ClaudeEval 向け PromptRouter API（spec v11 5.3）。スケジュールプロンプトを未評価のプロポーザル式 `HoldComplete[SourceVaultUpcomingSchedule[..., "FilterSpec"-><|...|>]]` に解決し、`"ProposedExpression"` フィールドに格納した PromptRouteProposal Association を返す。式を評価しない。スケジュール以外のプロンプトは Status `NotDispatched`。
→ Association

## PromptRun 履歴ストア

PromptRun は実行履歴。`<PrivateVault>/promptrouter/runs/prompt-runs.jsonl` に追記専用 JSONL で保存（claims.jsonl と同パターン）。コンパイル済みレジストリには書き込まない。

### SourceVaultPromptRunRecord[prompt, routeDecision, result, opts]
PromptRun レコードを追記専用 JSONL ストアに追記する。生プロンプトはデフォルトで保存しない（ハッシュのみ）。
→ Association `<|"Status"->"OK"|"DryRun"|"Skipped"|"Failed", "RunId"->_, "Record"->_|>`
Options: `"StorePrompt"->"HashOnly"` (`"PrivateRaw"` | `"Off"`), `"PrivacyLevel"->0.0`, `"PrivacyOrigin"->{}`, `"AllowedTrustDomains"->Automatic`, `"CloudFallback"->"Ask"`, `"Dependencies"-><||>`, `"ModelResolution"-><||>`, `"DryRun"->False`

### SourceVaultPromptRunHistory[opts]
追記専用ストアから PromptRun レコードを新しい順で返す。
→ List
Options: `"MaxResults"->Automatic`, `"RouteId"->Automatic`, `"Decision"->Automatic`, `"Since"->Automatic`（ISO 日時文字列; Timestamp >= Since のレコードのみ）

### SourceVaultCaptureLastPromptRun[opts]
追記専用履歴から最新の PromptRun を `<|"Status"->"OK", "PromptRun"->_|>` で返す。履歴が空なら Status `NoPromptRun`。
→ Association

### SourceVaultPromotePromptRun[runId_String, opts]
記録済み PromptRun を分類し（spec 10.3）、決定論的ルートヒットの場合はそのルートの Matcher にフィンガープリント・例を追加して強化する。ワークフロートレース・LLM のみの実行は分類するが自動プロモートしない。
→ Association
Options: `"DryRun"->True`, `"Confirm"->False`, `"Channel"->"public"`

## ルートレジストリ

### SourceVaultCallableAllowlistRegistry[] → Association
SourceVault 所有の呼び出し可能許可リスト。FunctionId をキーとし、生シンボル・UseAsFunctionRoute / UseAsHandlerRef フラグ・SideEffectClass を保持する。SourceVault.wl に実在する呼び出し可能体のみ登録（`SourceVaultUpcomingSchedule`, `SourceVaultFindNotebooks`, `SourceVaultNewNotebook`）。SourceVaultReviewQueue / SourceVaultOpenTodoList はセマンティック IntentId として処理。

### SourceVaultCallableAllowlistView[] → Association
SourceVault 所有の許可リストと、ClaudeOrchestrator がロードされている場合は Orchestrator 所有ハンドラ許可リスト（弱呼び出しで照会）のマージ論理ビューを返す。FunctionRoute ディスパッチと HandlerRef 解決はこのビューを参照。SourceVault 所有エントリがキー衝突時に優先。

### SourceVaultRegisterPromptRoute[route_Association, opts]
PromptRoute をコンパイル済みプロンプトルートレジストリに追加または置換する。デフォルトは DryRun（rule 103）。DryRun -> False はアトミック書き込み（encode → verify → tmp → rename）。
→ Association（WrittenCount / SkippedCount / ByAction / Topic / Channel / Path）
Options: `"DryRun"->True`

### SourceVaultListPromptRoutes[opts]
チャンネルの PromptRoute 一覧を返す。
→ List
Options: `"IncludeSeed"->True`（レジストリに存在しない RouteId に対してビルトインシードルートを追加）、`"Channel"->Automatic`

### SourceVaultGetPromptRoute[routeId_String, opts]
指定 RouteId の PromptRoute を返す。見つからなければ Status `NotFound` の Association。
→ Association

### SourceVaultPromptReprocessPlan[opts]
PromptRoute レジストリをスキャンして古くなったルート（SchemaVersion / CompiledRegistryVersion 不一致、または StaleRouteIds で指名されたルート）を検出し読み取り専用の再処理プランを返す（spec 14.2/14.3）。何も再処理しない。
各古いルートのポリシー: ReadOnly FunctionRoute → `"AutoRecomputable"`, Intent → `"OnDemandRefresh"`, WorkflowRoute → `"NeedsApproval"`。
→ Association
Options: `"StaleRouteIds"->{}`, `"Channel"->Automatic`

## プロンプトキャプチャ・保存

### SaveLastPrompt[memo_String, opts]
最新の成功した ClaudeEval / ContinueEval 実行を名前付き PromptRoute として保存する。memo はルートの Memo フィールドに格納される自由記述のメモ。
→ Association
Options: `"Channel"->Automatic`（`"public"` | `"private"` | `"local"`）, `"Encrypt"->False`（`True` のとき EncryptedPayload に暗号化保存; 暗号化モジュール未実装のため現在 Status `NotImplemented`）, `"DryRun"->False`, `"RouteId"->Automatic`

### SourceVaultDecryptPromptRoute[route_Association]
`SaveLastPrompt` で `Encrypt->True` により作成された暗号化 PromptRoute の EncryptedPayload を復号する。MAC 検証後に復号。
→ `<|"Status"->"Ok", "Plaintext"->_|>` またはエラー Association

### SourceVaultAutoSaveLastPrompt[prompt_String, opts]
ClaudeEval による自動キャプチャパス。同一（正規化）プロンプトの最新バージョンと TargetExprString が重複する場合はスキップ。`$SourceVaultPromptAutoSave` でゲートされる。同一プロンプトのバージョンは PromptGroupId を共有する。
→ SaveLastPrompt の結果、または `<|"Status"->"Skipped"|>`
Options: `"Memo"->""`、SaveLastPrompt のオプションも有効

### SourceVaultSearchPromptRoutes[query_String, opts]
プロンプト例または Memo に query を部分一致で含む保存済み PromptRoute を返す。`query=""` は全件マッチ。
→ List（Association のリスト。実行しない）
Options: `"CreatedAt"-><|"From"->_,"To"->_|>`, `"UpdatedAt"-><|"From"->_,"To"->_|>`, `"Channel"->All`（`"public"` | `"private"` | `"local"`）, `"IncludeSeed"->True`

### SourceVaultMatchSavedPromptVersions[prompt_String, opts]
prompt の正規化形式に完全一致する保存済み PromptRoute を全チャンネルから返す（プライマリ優先・新しい順）。一致なければ `{}`。
→ List
Options: `"Channel"->All`, `"IncludeSeed"->False`

### SourceVaultPrimaryPromptRoute[prompt_String]
prompt グループのプライマリ保存 PromptRoute を返す。なければ `Missing["NoPrimary"]`。
→ Association | Missing

### SourceVaultSetPrimaryPromptRoute[routeId_String, opts]
ルートを PromptGroupId 内でプライマリとしてマークし、他チャンネルの兄弟ルートの Primary をクリアする。`AutoExecute->True` は ReplaySafety `"EnvironmentIndependent"` のルートのみ有効。
→ Association（Status / RouteId / Channel / ClearedSiblings）
Options: `"AutoExecute"->True|False`, `"DryRun"->False`

### SourceVaultDeletePromptRoute[routeId_String, opts]
保存済み PromptRoute をチャンネルレジストリから削除する（アトミック書き直し）。デフォルトは DryRun（非破壊）。
→ Association（Status / RouteId / Channel / Removed / WasPrimary）
Options: `"DryRun"->True`, `"Confirm"->False`

### SourceVaultUpdatePromptRouteMemo[routeId_String, memo_String]
保存済み PromptRoute の Memo フィールドを更新し UpdatedAt を更新する（アトミックチャンネル書き直し）。暗号化ルートでも Memo はプレーンテキストで保存される。
→ Association（Status / RouteId / Channel / Memo）

### SourceVaultRunPrimaryRoute[groupId_String, opts]
プライマリルートの凍結式のゲート付き実行体。TargetExprString を評価せずにパースし、ヘッドが ReadOnly/SafeCreate SourceVault 呼び出し可能体 かつ ReplaySafety `"EnvironmentIndependent"` のときのみ評価する。Set / SetDelayed / AppendTo / ClaudeAttach / SystemCredential および未分類ヘッドは拒否する。ClaudeEval からは `HoldComplete[SourceVaultRunPrimaryRoute[..]]` プロポーザルを通じてのみ到達する。
→ Association

### SourceVaultPromptVersionsUI[normKey_String, prompt_String, opts]
プロンプトグループの保存済みバージョンを `SourceVaultFormatPromptRouteList` で描画し、ヘッダーと「LLM に再度聞く」ボタンを追加した UI を返す。「LLM に再度聞く」ボタンは一度だけバイパスして ClaudeEval を LLM パスで再実行する。
→ Wolfram Frontend 表示オブジェクト

### SourceVaultProposeSavedPromptRoute[prompt_String, opts]
ClaudeEval エントリの保存プロンプト提案体（claudecode から LLM 呼び出し前に弱呼び出し）。
- EnvironmentIndependent + AutoExecute のプライマリが存在: `HoldComplete[SourceVaultRunPrimaryRoute[groupId]]`
- 保存バージョンが存在: `HoldComplete[SourceVaultPromptVersionsUI[..]]`
- 機能オフ・ワンショットバイパスキー一致・バージョンなし: Status `NotDispatched`
→ PromptRouteProposal Association

### SourceVaultClassifyPromptReplaySafety[prompt_String, exprString_, contextBinding_]
生成式が凍結定数として安全にリプレイできるかを分類する。
→ `<|"ReplaySafety"->"EnvironmentIndependent"|"ContextBound"|"Unknown", "ContextBinding"-><|...|>|>`
`ContextBound`: 式にキャプチャされたノートブックコンテキストが埋め込まれている、セッション一時的シンボル（%/Out/In/SelectedCells/NotebookRead 等）を参照する、またはプロンプトに指示語（「上のセル」等）が含まれる場合。ContextBound ルートは自動実行不可、ReplayClass は HeavyLLM に強制される。

### SourceVaultReplayRoute[route_Association, opts]
保存済み PromptRoute をリプレイクラスに応じて再構成し、評価用式文字列を返す。
- `Replayable`: TargetExprString をそのまま返す
- `LightLLM`: NewPrompt なしなら元の TargetExprString を復元; NewPrompt を与えると軽量 LLM で各パラメータスロットの新 InputForm 値を抽出し ParameterTemplate を埋めた式文字列を返す
- `HeavyLLM` または式未記録ルート: `ClaudeEval[...]` 形式の式を返す
→ `<|"Status"->_, "ReplayClass"->_, "ExprString"->_, "SlotValues"->_|>`
Options: `"NewPrompt"->Automatic`, `"ExtractModel"->Automatic`

## プライバシー・モデル解決

### SourceVaultResolvePromptPrivacy[components_Association, opts]
プロンプトのプライバシー貢献を単一の PrivacyLevel（各コンポーネントの Max、spec 11.2）および AllowedTrustDomains / CloudFallback / CloudRouterAllowed メタデータに集約する。SecretCell または PrivateModelExecution コンポーネントはレベルを最低 0.75 に引き上げる（spec 11.3/11.4）。
→ Association
コンポーネントキー: `"PromptCellPrivacyLevel"`, `"PromptTextPrivacyLevel"`, `"NotebookDependencyPrivacyLevel"`, `"ModelExecutionPrivacyFloor"`, `"ResultPrivacyLevel"`, `"UserSpecifiedPrivacyLevel"`, `"SecretCell"`, `"PrivateModelExecution"`

### SourceVaultPromptPrivacyAllowsCloudRouter[level]
PrivacyLevel が 0.5 未満のときのみ True を返す（spec 11.5 クラウド送信境界）。非数値入力は安全でないとみなし False。
→ True | False

### SourceVaultResolveModelForPromptRouter[query_Association, opts]
モデルリゾルバのコントラクトレイヤー（spec 12）。クエリを完全コントラクト（ModelIntent / WeightClass / PrivacyLevel / AllowedTrustDomains / CloudFallback / RequiredCapabilities / DegradationPolicy）に正規化し、ホストリゾルバを弱呼び出しする。リゾルバが不在または結果が未分類の場合 `NeedsModelClassification`。PrivacyLevel >= 0.5 で Local/Private と確認できないモデルは `NeedsPrivateModel`。
→ Association（Requested / Resolved / FallbackKind / CloudFallbackUsed）

### SourceVaultClassifyProviderTrustDomain[label] → "Cloud"|"Private"|"Local"|Missing
プロバイダまたはルートラベルを TrustDomain に分類する（spec 12.2）。
- `"Cloud"`: `"chatgptcodex"`, `"ChatGPTCodexCLI"`, `"ClaudeCodeCLI"`, `"CloudLLM"`, `"anthropic"`, `"openai"` 等
- `"Private"`: `"PrivateLLM"` 等
- `"Local"`: `"LocalOnly"` 等
- `Missing["UnclassifiedTrustDomain"]`: LocalOpenAICompatible / ExternalAPI 等の曖昧なラベル（ホストリゾルバが TrustDomain を明示すること）

## UI・表示

### SourceVaultFormatPromptRouteList[routes_List, opts]
保存済み PromptRoute を Grid（列: Prompt / Memo / Target / CreatedAt / UpdatedAt / Privacy）と行ごとの3アクションボタン（Preview: ドライラン、Run: 即時実行、ToInput: Input セルに式を書き込み）で描画する。プロンプトルートリストのデフォルト表示形式。
→ Wolfram Frontend 表示オブジェクト

## 設定変数

### $SourceVaultPromptAutoSave
型: True|False, 初期値: True
ClaudeEval が実行したノートブックプロンプトを `SourceVaultAutoSaveLastPrompt` で自動保存するかどうかを制御する。False で自動キャプチャ無効。Get[] の再実行でリセットされない。

### $SourceVaultPromptSavedProposalActive
型: True|False, 初期値: True
ClaudeEval が LLM 呼び出し前に保存済みプロンプトを参照して完全一致を提案するかどうかを制御する。False で保存プロンプト提案無効。Get[] の再実行でリセットされない。

### $SourceVaultPromptBypassOnce
型: String | Missing, 初期値: Missing["None"]
ワンショット正規化プロンプトキー。`SourceVaultProposeSavedPromptRoute` がこのキーに一致するプロンプトを検出すると、キーを消費（Missing にリセット）して提案を辞退し ClaudeEval をレガシー LLM パスに通す。保存プロンプトリストの「LLM に再度聞く」ボタンがこれをセットする。