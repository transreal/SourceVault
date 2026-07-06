# SourceVault PromptRouter API リファレンス (api_promptrouter.md)

## 概要
SourceVault_promptrouter.wl は独立パッケージではなく、`SourceVault`` コンテキストの拡張である。SourceVault.wl ブートストラップが `Get[]` でロードする（spec 3.2）。`Needs["ClaudeRuntime`"]` / `Needs["ClaudeOrchestrator`"]` は呼ばず、可用性は公開シンボル名の実行時検出のみで判定する（rule 11）。ClaudeRuntime / ClaudeOrchestrator が不在でもロード成功し、`Get[]` の再実行は冪等（公開シンボルを再定義するが機能フラグはユーザ設定を保持）。ソースは `\:XXXX` リテラルを用いた全 ASCII（rule 30 / trap #11）。

このパッケージは「Prompt Router / Prompt Capture / Workflow Promotion」統一仕様 v9〜v11 を実装する。中核は次の 3 系統である。
- ルート解決/実行: プロンプトを決定的 FunctionRoute（許可リスト callable）または語彙検索・LLM で解決し、UNEVALUATED な提案式を返す。ClaudeEval には評価済みの結果ではなく評価前の Mathematica 式を渡す（spec 5.2）。
- PromptRun 履歴: 実行履歴を `<PrivateVault>/promptrouter/runs/prompt-runs.jsonl` に append-only JSONL で追記。コンパイル済みレジストリには書かない（spec 9.0 / 24.1）。生プロンプトは既定で保存せずハッシュのみ。
- 保存プロンプト（Order 9）: ClaudeEval の各実行を版付き PromptRoute として自動キャプチャし、検索・再実行・主版自動実行を提供する。

プライバシー規約: PrivacyLevel は全寄与成分の Max（spec 11.2）。SecretCell / PrivateModelExecution は 0.75 以上へ引き上げる（spec 11.3/11.4）。0.5 がクラウド送信境界で、これ以上では決定的マッチとローカル/プライベートルータのみ許可される（spec 11.5）。

再実行安全性: `EnvironmentIndependent` なルートのみ自動実行可。`ContextBound` は HeavyLLM 扱いで LLM が新コンテキストで再解決する。凍結式の解放は必ず `SourceVaultRunPrimaryRoute` のゲートを通り、ClaudeEval が保存式を直接解放することはない。

関連パッケージ: [SourceVault](https://github.com/transreal/SourceVault), [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime), [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator), [NBAccess](https://github.com/transreal/NBAccess), [claudecode](https://github.com/transreal/claudecode)。

## バージョン・機能フラグ変数

### $SourceVaultPromptRouterVersion
型: String
PromptRouter 拡張のバージョン文字列。

### $SourceVaultPromptAutoSave
型: Boolean, 初期値: True
ClaudeEval が実行した各ノートブックプロンプトを `SourceVaultAutoSaveLastPrompt` 経由で新しい保存 PromptRoute 版として自動保存するか。False で自動キャプチャ無効。再ロードで保持。

### $SourceVaultPromptSavedProposalActive
型: Boolean, 初期値: True
ClaudeEval が LLM 呼び出し前に保存プロンプトの正規化完全一致を探して提案するか。False で ClaudeEval エントリの保存プロンプト提案を無効化。再ロードで保持。

### $SourceVaultPromptBypassOnce
型: 正規化プロンプトキー | Missing["None"], 初期値: Missing["None"]
ワンショットのバイパスキー。`SourceVaultProposeSavedPromptRoute` が正規化形の一致を見ると消費（Missing にリセット）して提案を辞退し、ClaudeEval が旧来 LLM パスへ落ちる。「LLM に再度きく」ボタンが設定する。

### $SourceVaultContextPlannerEnabled
型: Boolean, 初期値: True
True で SourceVault が `ClaudeCode`$ClaudeEvalContextPlanner` にコンテキストプランナを登録し、`SourceVaultClassifyPromptContextDependency` でプロンプトごとに ClaudeEval の ContextPlan を精緻化する。False でプランナを no-op 化（基底パッケージが既定プランへフォールバック）。再ロード不要。

### $SourceVaultContextPlannerTrimSelfContained
型: Boolean, 初期値: False
True で自己完結（マーカ無し）プロンプトをノートブックコンテキスト無し（Notebook "None"）まで削る。軽量モデルが自明プロンプトで直前セルを模倣するのを防ぐ代償に、未マークのノートブック依存プロンプトを飢餓させうる。既定 False（保守的）。履歴はこのフラグでは削らない。

### $SourceVaultPromptPanelMaxRows
型: Integer | Infinity, 初期値: 30
`SourceVaultPromptRoutePanel` が既定（無検索）状態で描画する保存プロンプト行の上限。キーワード検索は全一致を表示し「全件」ボタンは上限無視で全表示。Infinity で常に全行。再ロードで保持。

## ステータス・可用性 API

### SourceVaultPromptRouterStatus[] → Association
拡張のバージョン、実装フェーズ、claudecode / SourceVault / ClaudeRuntime / ClaudeOrchestrator の可用性、自動 ClaudeEval ディスパッチが現在有効かを記述する Association を返す。

### SourceVaultPromptRouterAvailableQ[] → True|False
PromptRouter 拡張自体が `SourceVault`` コンテキストにロード済みなら True。ClaudeRuntime / ClaudeOrchestrator の存在は含意しない。

### SourceVaultPromptRouterActiveQ[caller] → True|False
指定 caller の要求を PromptRouter が処理すべきなら True。caller: `"Manual"` | `"ClaudeEval"` | Automatic（既定 Automatic は `"ClaudeEval"` 扱い、claudecode 弱呼び出しが安全になる）。Manual API は拡張ロード時に常時有効。自動 ClaudeEval ディスパッチは ClaudeOrchestrator もロード時のみ有効（spec 4）。

## ルート解決・実行 API

### SourceVaultResolvePromptRoute[prompt, opts]
プロンプトをルート決定 Association に解決するが実行はしない。PromptRoute（コンパイル済みレジストリ + 組込シード）をロードし、Matcher の KeywordsAny 集合でマッチして正準パラメータを付す。決定的マッチが無ければ語彙検索へフォールバック（Decision `LexicalMatch` / `LexicalCandidates`）。
→ Association（Status / Decision ほか）
Options: "DryRun" -> False, "AllowLLMRouter" -> Automatic, "AllowWorkflow" -> Automatic, "PrivacyLevel" -> Automatic, "StorePrompt" -> "HashOnly", "FallbackToClaudeEval" -> True, "Caller" -> Automatic

### SourceVaultExecutePromptRoute[prompt, opts]
プロンプトルートを解決して実行する（解決 → アダプタ → 許可リスト検査 → ディスパッチ（ReadOnly callable のみ）→ PromptRun 記録）。手動/テスト/診断 API で評価してよい。ディスパッチ不能時は `<|"Status" -> "NotDispatched", ...|>` を返し、ClaudeEval 弱呼び出しパスが既存 ClaudeEval ルートへフォールバックする。
→ Association
Options: SourceVaultResolvePromptRoute と同じ

### SourceVaultRouteExplain[prompt, opts] → String|Association
プロンプトがどうルーティングされるかの人間可読な説明を返す。ルータの現在ステータスを反映する。

### SourceVaultProposePromptRoute[prompt_String, opts]
ClaudeEval 向けの PromptRouter API（spec v11 5.3）。スケジュールプロンプトを UNEVALUATED な提案式 `HoldComplete[SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]]` に解決し、それを `"ProposedExpression"` に載せた PromptRouteProposal Association を返す。式は評価しない。ClaudeEval ブリッジはこのフィールドのみを Runtime に渡し head ベース検証を行う。プロンプトの日付幅は Period に、その他の絞込は FilterSpec 閉 DSL（spec 5.4.3: Kind And/Or/Not/Field, whitelist Op, スキーマフィールド名のみ、Function/Slot/任意コード不可）になる。非スケジュールプロンプトは Status `NotDispatched`。
→ PromptRouteProposal Association

## PromptRun 履歴 API

### SourceVaultPromptRunRecord[prompt, routeDecision, result, opts]
PromptRun レコードを append-only JSONL ストア `<PrivateVault>/promptrouter/runs/prompt-runs.jsonl` に追記する。PromptRun は実行履歴でありレジストリエントリではない（claims.jsonl / source-events.jsonl と同様。spec 9.0/24.1）。生プロンプトは既定で保存せずハッシュのみ。
→ `<|"Status" -> "OK"|"DryRun"|"Skipped"|"Failed", "RunId" -> ..., "Record" -> ...|>`
Options: "StorePrompt" -> "HashOnly"（"PrivateRaw"|"Off" も可）, "PrivacyLevel" -> 0.0, "PrivacyOrigin" -> {}, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "Dependencies" -> <||>, "ModelResolution" -> <||>, "DryRun" -> False

### SourceVaultPromptRunHistory[opts] → List
append-only ストアから PromptRun レコードを新しい順で返す。
Options: "MaxResults" -> Automatic, "RouteId" -> Automatic, "Decision" -> Automatic, "Since" -> Automatic（ISO 日時文字列。Timestamp >= Since を保持）

### SourceVaultCaptureLastPromptRun[opts]
append-only 履歴から最新 PromptRun を `<|"Status" -> "OK", "PromptRun" -> ...|>` で返す。履歴が空なら Status `NoPromptRun`。
→ Association
Options: なし

### SourceVaultPromotePromptRun[runId_String, opts]
記録済み PromptRun を分類し（spec 10.3）、決定的ルートヒットならそのルートの Matcher を run の fingerprint と生例で強化する。DryRun -> True（既定, rule 103）はプランのみ報告。ワークフロートレースと LLM-only run は分類のみで自動昇格しない。
→ Association
Options: "DryRun" -> True, "Confirm" -> False, "Channel" -> "public"

## 許可リスト API

### SourceVaultCallableAllowlistRegistry[] → Association
SourceVault 所有の callable 許可リスト。FunctionId をキーに、生 Symbol、UseAsFunctionRoute / UseAsHandlerRef フラグ、SideEffectClass、OwnerPackage を保持するコード常駐定数表。生 Symbol を含むためコンパイル済み JSON レジストリには書かない（spec 7.3）。SourceVault.wl に実在する callable のみ登録（SourceVaultUpcomingSchedule, SourceVaultFindNotebooks 等）。SourceVaultReviewQueue / SourceVaultOpenTodoList は登録せず、意味的 IntentId として扱う。

### SourceVaultCallableAllowlistView[] → Association
SourceVault 所有許可リストと、ClaudeOrchestrator ロード時は弱呼び出しで得た Orchestrator 所有ハンドラ許可リストを統合した論理ビュー。FunctionRoute ディスパッチと HandlerRef 解決が参照する。キー衝突時は SourceVault 所有エントリが優先。

## PromptRoute レジストリ書込 API

### SourceVaultRegisterPromptRoute[route_Association, opts]
PromptRoute をコンパイル済み prompt-route-registry に追加/置換する。書込はアトミック（encode → verify → tmp → rename）。
→ Association（WrittenCount / SkippedCount / ByAction / Topic / Channel / Path 集計）
Options: "DryRun" -> True（既定, rule 103。計画された topic / RouteId / action を報告し書込まない）, "Channel" -> "public" ほか

### SourceVaultListPromptRoutes[opts] → List
チャネルの PromptRoute を返す。IncludeSeed -> True（既定）ならレジストリに無い RouteId について組込シードルートを追加する。
Options: "Channel" -> "public", "IncludeSeed" -> True

### SourceVaultGetPromptRoute[routeId_String, opts] → Association
指定 RouteId の PromptRoute を返す。無ければ Status `NotFound` の Association。
Options: "Channel" -> "public", "IncludeSeed" -> True

### SourceVaultDeletePromptRoute[routeId_String, opts]
保存 PromptRoute をチャネルレジストリからアトミック書換で削除する。データストア安全規則により既定で非破壊。
→ Association（Status/RouteId/Channel/Removed/WasPrimary）
Options: "DryRun" -> True（既定、プランのみ報告）, "Confirm" -> True（実削除は DryRun -> False かつ Confirm -> True が必須）, "Channel" -> Automatic

### SourceVaultUpdatePromptRouteMemo[routeId_String, memo_String] → Association
保存 PromptRoute の Memo を設定（アトミックチャネル書換）し UpdatedAt を更新する。暗号化ルートでも Memo は平文（表示ラベル）。`SourceVaultFormatPromptRouteList` の編集可能 Memo セルが使う。
→ Status/RouteId/Channel/Memo

## プライバシー・モデル解決 API

### SourceVaultResolvePromptPrivacy[components_Association, opts] → Association
プロンプトのプライバシー寄与を単一 PrivacyLevel（全成分の Max, spec 11.2）に統合し、AllowedTrustDomains / CloudFallback / CloudRouterAllowed メタデータを付す。SecretCell または PrivateModelExecution 成分はレベルを 0.75 以上へ引き上げる（spec 11.3/11.4）。成分キー: PromptCellPrivacyLevel, PromptTextPrivacyLevel, NotebookDependencyPrivacyLevel, ModelExecutionPrivacyFloor, ResultPrivacyLevel, UserSpecifiedPrivacyLevel。
Options: なし

### SourceVaultPromptPrivacyAllowsCloudRouter[level] → True|False
PrivacyLevel（または privacy 解決 Association）が 0.5 のクラウド送信境界未満のときのみ True（spec 11.5）。非数値入力は unsafe 扱いで False。

### SourceVaultResolveModelForPromptRouter[query_Association, opts]
モデル解決契約層（spec 12）。query を full contract（ModelIntent / WeightClass / PrivacyLevel / AllowedTrustDomains / CloudFallback / RequiredCapabilities / DegradationPolicy）に正規化し、ホストリゾルバ `SourceVault`SourceVaultResolve["Model", query]` を実在時のみ弱呼び出しする。リゾルバ不在か結果分類不能なら `NeedsModelClassification` を返す。PrivacyLevel >= 0.5 で未確認（非 Local/Private）モデルはクラウドフォールバックせず `NeedsPrivateModel` を返す。結果は PromptRun ModelResolution 形（Requested / Resolved / FallbackKind / CloudFallbackUsed）。
→ Association

### SourceVaultClassifyProviderTrustDomain[label] → TrustDomain
プロバイダ/ルートラベルを TrustDomain にマップする（spec 12.2）。"chatgptcodex" / "ChatGPTCodexCLI" / "ClaudeCodeCLI" / "CloudLLM" は "Cloud"、"LocalOnly" は "Local"、"PrivateLLM" は "Private"。曖昧/未知（LocalOpenAICompatible, ExternalAPI 等）は `Missing["UnclassifiedTrustDomain"]` を返し、ホストリゾルバに TrustDomain 明示を要求する。ChatGPT Codex はクラウド裏付け CLI（サンドボックスはローカルだが推論はクラウド）。

## 再処理プラン API

### SourceVaultPromptReprocessPlan[opts]
PromptRoute レジストリを走査して stale ルート（SchemaVersion / CompiledRegistryVersion 不一致、または StaleRouteIds オプションで名指しされたもの）を検出し、読み取り専用の再処理プランを返す（spec 14.2/14.3）。ReadOnly FunctionRoute は `AutoRecomputable`、Intent ルートは `OnDemandRefresh`、WorkflowRoute は `NeedsApproval` に分類。プランを作るだけで再処理はしない。
→ Association
Options: "StaleRouteIds" -> {} ほか

## 保存プロンプト（Order 9）API

### SaveLastPrompt[memo_String]
直近の成功した ClaudeEval / ContinueEval 実行を名前付き PromptRoute として保存し、後で検索・再実行できるようにする。memo はプロンプト表に表示される自由記述ノート（Memo フィールド）。プライバシーは `SourceVaultResolvePromptPrivacy` で追跡し、PrivacyLevel と CloudFallback をルートに記録する。
→ Association
Options: "Channel" -> Automatic（"public"|"private"|"local"、privacy から解決）, "Encrypt" -> False（True で生プロンプトと TargetExprString を `SourceVaultEncryptedPut`（encrypt-then-MAC, 鍵は NBAccess）で暗号化し EncryptedPayload としてルートに埋込。Examples を空にし PromptStorageClass を "Encrypted" に。Memo は平文表示ラベルとして保持。SourceVault 暗号化モジュールのロードと `SourceVaultInitializeEncryption[]` 実行が必要）, "DryRun" -> False, "RouteId" -> Automatic
暗号化ルートの平文復元には `SourceVaultDecryptPromptRoute[route]` を使う。

### AddPromptMemo[memo_String]
直近の ClaudeEval / ContinueEval プロンプトに自由記述メモを付す。各実行は既に `SourceVaultAutoSaveLastPrompt` で版付き保存されているため、最新保存版の Memo を `SourceVaultUpdatePromptRouteMemo` で IN PLACE 更新する（SaveLastPrompt のように冗長な新版を作らない）。保存版が未存在（自動保存が意図的にスキップする HeavyLLM 一発回答等）なら SaveLastPrompt にフォールバックする。
→ `<|"Status"->..., "RouteId"->..., "Memo"->..., "Action"->"MemoUpdated"|"MemoSavedNewVersion"|>`
Options: "PromptText" -> Automatic, "RouteId" -> Automatic

### SourceVaultAutoSaveLastPrompt[prompt_String, opts]
prompt の直近成功実行を新しい保存 PromptRoute 版として保存する（既存版を上書きしない）。ClaudeEval が自動で呼ぶ既定オンのキャプチャパス（手動・メモ付き対応物は SaveLastPrompt）。同一（正規化）プロンプトの版は PromptGroupId を共有する。TargetExprString がグループ最新版と重複する版はスキップ。`$SourceVaultPromptAutoSave` でゲート。
→ SaveLastPrompt の結果、または `<|"Status"->"Skipped"|>`
Options: "Memo" -> "" に加え SaveLastPrompt のオプション

### SourceVaultDecryptPromptRoute[route_Association]
暗号化 PromptRoute（SaveLastPrompt の Encrypt -> True で作成）の EncryptedPayload を復号する。復号前に MAC を検証し、失敗時は平文を返さない。
→ `<|"Status"->"Ok", "Plaintext"->...|>` またはエラー Association

### SourceVaultSearchPromptRoutes[query_String, opts] → List
プロンプト例または memo に query を部分文字列として含む保存 PromptRoute を返す（部分一致）。query "" は全一致。実行はしない。
Options: "CreatedAt" -> <|"From"->_,"To"->_|>（定義日で絞込）, "UpdatedAt" -> <|"From"->_,"To"->_|>（最終更新日で絞込）, "Channel" -> All|"public"|"private"|"local", "IncludeSeed" -> True

### SourceVaultMatchSavedPromptVersions[prompt_String, opts] → List
正規化プロンプトが prompt に完全一致する保存 PromptRoute を全チャネル横断で返す（PromptHash と同じ正規化）。主版優先→新しい順にソート。一致無しは {}。
Options: "Channel" -> All, "IncludeSeed" -> False

### SourceVaultFormatPromptRouteList[routes_List, opts] → Grid
保存 PromptRoute を Grid で描画する（列: Prompt, Memo, Target, CreatedAt, UpdatedAt, Privacy）。各行に 3 ボタン: Preview（dry-run、実行せず実行内容表示）, Run（今すぐ実行）, ToInput（保存関数呼び出し式を新 Input セルに書込）。プロンプトで要求されたプロンプトルート一覧の既定表示形式。`SourceVaultFormatNotebookList` を踏襲。

### SourceVaultReplayRoute[route_Association, opts]
保存 PromptRoute を再実行クラスに応じ再構成し、評価用の式文字列を返す。Replayable は TargetExprString をそのまま返す。LightLLM は "NewPrompt" 無しなら元の TargetExprString を復元し、新プロンプト文を与えると軽量 LLM で各パラメータスロットの新 InputForm 値を抽出し ParameterTemplate を埋めた式文字列を返す。HeavyLLM または式未記録ルートは `ClaudeEval[...]` 形式の式を返す。
→ `<|"Status", "ReplayClass", "ExprString", "SlotValues"|>`
Options: "NewPrompt" -> Automatic, "ExtractModel" -> Automatic（Automatic は SourceVault 既定モデル）

### SourceVaultPrimaryPromptRoute[prompt_String] → Association|Missing
prompt のグループの主版保存 PromptRoute を返す。無ければ `Missing["NoPrimary"]`。ルートは "Primary" フィールドが True のとき主版（`SourceVaultSetPrimaryPromptRoute` で設定）。

### SourceVaultSetPrimaryPromptRoute[routeId_String, opts]
ルートを PromptGroupId 内の主版に指定し、兄弟版（全チャネル）の Primary をクリアする。可逆メタデータトグルなので DryRun は既定 False。
→ Status/RouteId/Channel/ClearedSiblings
Options: "AutoExecute" -> True|False（ClaudeEval が確認ダイアログ無しで凍結式を解放・評価してよいか。ReplaySafety "EnvironmentIndependent" のルートでのみ尊重される）

### SourceVaultRunPrimaryRoute[groupId_String, opts]
主版の凍結式のためのゲート付き実行器。ルートの TargetExprString を評価せずにパースし、(a) head が ReadOnly/SafeCreate な SourceVault callable（Set/SetDelayed/AppendTo/ClaudeAttach/SystemCredential および未分類 head は拒否、AutoEvaluate 禁止規則を遵守）かつ (b) ReplaySafety が "EnvironmentIndependent" のときのみ評価する。それ以外は通知を返し評価しない。ClaudeEval はこれに `HoldComplete[SourceVaultRunPrimaryRoute[..]]` 提案経由でのみ到達し、保存式を直接解放することはない。
→ Association

### SourceVaultPromptVersionsUI[normKey_String, prompt_String, opts]
プロンプトグループの保存版を（`SourceVaultFormatPromptRouteList` 経由で）ヘッダと「LLM に再度きく」ボタン付きで描画する。ボタンは保存提案を一度バイパスし ClaudeEval を LLM 経由で再実行する。保存版はあるが自動実行主版が未設定のとき、ClaudeEval が LLM 呼び出しの代わりにこれを表示する。
→ UI 式

### SourceVaultProposeSavedPromptRoute[prompt_String, opts]
ClaudeEval エントリの保存プロンプト提案器（LLM 呼び出し前に claudecode から弱呼び出し）。"ProposedExpression" が `HoldComplete[SourceVaultRunPrimaryRoute[groupId]]`（AutoExecute 付き EnvironmentIndependent 主版が存在時）または `HoldComplete[SourceVaultPromptVersionsUI[..]]`（保存版存在時）の PromptRouteProposal を返す。機能オフ・ワンショットバイパスキー一致・一致保存版無しのとき Status `NotDispatched`。
→ PromptRouteProposal Association

## 分類 API

### SourceVaultClassifyPromptReplaySafety[prompt_String, exprString_, contextBinding_] → Association
生成済み式を凍結定数として再実行して安全かを分類する。プロンプトの式がキャプチャ済みノートブックコンテキストを字義的に埋め込む、セッション一時シンボル（%/Out/In/SelectedCells/NotebookRead/...）を参照する、または指示語（「上のセル」等）を使うとき ContextBound。
→ `<|"ReplaySafety" -> "EnvironmentIndependent"|"ContextBound"|"Unknown", "ContextBinding" -> <|...|>|>`
EnvironmentIndependent ルートのみ自動実行可。ContextBound は ReplayClass HeavyLLM に強制（LLM が新コンテキストで再解決）。

### SourceVaultClassifyPromptContextDependency[prompt_String] → Association
LLM 不要・プロンプトのみの事前フィルタ。式生成前に新プロンプトが必要とするコンテキストを推論する（生成済み式を見る ClassifyPromptReplaySafety と異なる）。iSVPRDeicticQ と指示語パターン表を共有し、ノートブック参照と会話履歴参照を混同しない。
→ `<|"DependencyKinds" -> {...}, "RequiredContext" -> <|"Notebook" -> <|"Mode" -> "None"|"PreviousCellGroup"|"Tail"|"Full"|>, "SelectedCells" -> True|False, "History" -> <|"Mode" -> "None"|"Recent"|>|>, "Confidence" -> "High"|"Low", "Reasons" -> {...}|>`
RequiredContext は必要最小（下限）で、プランナが要求/既定プランと合成する。何も検出されなければ下限は空（DependencyKinds `{"SelfContained"}`, Confidence "Low"）で自明プロンプトは最小コンテキストになる。

## UI パネル API

### SourceVaultPromptRoutePanel[opts]
保存 PromptRoute を一覧し、キーワード/memo 検索、チャネルフィルタ、各ルート管理（Preview / Run / ToInput / Primary / Memo / 削除）を `SourceVaultFormatPromptRouteList` 経由で行う UI パネルを返す。`SourceVaultWorkflowPanel` の保存プロンプト版（手動リフレッシュ、FE フリーズ安全）。既定（無検索）では先頭 $SourceVaultPromptPanelMaxRows 行のみ描画し長いライブラリを高速に開く。キーワード検索は全一致、「全件」ボタンは上限無視の全表示。
→ UI パネル式
Options: "Channel" -> All|"public"|"private"|"local"（初期チャネルフィルタ）, "MaxRows" -> Automatic|_Integer|Infinity（既定表示の行上限。Automatic は $SourceVaultPromptPanelMaxRows を使用）