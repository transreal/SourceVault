# SourceVault_promptrouter API リファレンス

パッケージ: `SourceVault`` (拡張モジュール)
GitHub: https://github.com/transreal/SourceVault_promptrouter
SourceVault.wlのGet[]ブートストラップから読み込まれる。単独パッケージではなくSourceVault`コンテキストの拡張。ClaudeRuntime/ClaudeOrchestrator不在でも読み込み可能。読み込みは冪等。

## ステータス・可用性

### $SourceVaultPromptRouterVersion
型: String
このextensionのバージョン文字列。

### SourceVaultPromptRouterStatus[] → Association
PromptRouter extensionの状態を返す。キー: Version, Phase, claudecode/SourceVault/ClaudeRuntime/ClaudeOrchestrator可用性, ClaudeEval自動ディスパッチの有効状態。

### SourceVaultPromptRouterAvailableQ[] → True|False
PromptRouter extensionがSourceVault`コンテキストに読み込まれているときTrueを返す。ClaudeRuntime/ClaudeOrchestratorの存在は含意しない。

### SourceVaultPromptRouterActiveQ[caller] → True|False
callerからのリクエストをPromptRouterが処理すべきときTrueを返す。caller: "Manual"|"ClaudeEval"|Automatic (デフォルトAutomatic、"ClaudeEval"として扱われる)。Manual APIはextension読み込み済みなら常にアクティブ。ClaudeEval自動ディスパッチはClaudeOrchestratorが読み込まれているときのみアクティブ。

## ルート解決・実行

### SourceVaultResolvePromptRoute[prompt, opts]
プロンプトをルート決定Associationに解決する（実行しない）。Phase A: 常にStatus "NotFound", Decision "NotImplemented"を返す骨格実装。Phase B以降で決定論的・LLMバック解決を実装予定。
→ Association
Options: "DryRun" -> False, "AllowLLMRouter" -> Automatic, "AllowWorkflow" -> Automatic, "PrivacyLevel" -> Automatic, "StorePrompt" -> "HashOnly", "FallbackToClaudeEval" -> True, "Caller" -> Automatic

### SourceVaultExecutePromptRoute[prompt, opts]
プロンプトルートを解決して実行する。Phase A: 常に<|"Status"->"NotDispatched",...|>を返すのでClaudeEval弱呼び出しパスが既存ルートにフォールバックする。
→ Association
Options: "DryRun" -> False, "AllowLLMRouter" -> Automatic, "AllowWorkflow" -> Automatic, "PrivacyLevel" -> Automatic, "StorePrompt" -> "HashOnly", "FallbackToClaudeEval" -> True, "Caller" -> Automatic

### SourceVaultRouteExplain[prompt, opts]
プロンプトがどのようにルーティングされるかの人間可読な説明を返す。Phase A: 骨格実装。現在のルーターステータスをエコーする。
→ Association

### SourceVaultProposePromptRoute[prompt_String, opts]
ClaudeEval向けPromptRouter API (spec v11 5.3)。スケジュールプロンプトをUNEVALUATEDな提案式に解決する。戻り値の"ProposedExpression"フィールドにHoldComplete[SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]]を格納。式は評価しない。ClaudeEvalブリッジはそのフィールドのみをRuntimeに渡す。スケジュール以外のプロンプトはStatus NotDispatched。
→ PromptRouteProposal Association
Options: opts

例: SourceVaultProposePromptRoute["今週のスケジュールを見せて"] → <|"Status"->"Dispatched", "ProposedExpression"->HoldComplete[SourceVaultUpcomingSchedule["Period"->Quantity[7,"Days"],...]], ...|>

## PromptRunログ（追記専用JSOuLストア）

### SourceVaultPromptRunRecord[prompt, routeDecision, result, opts]
PromptRunレコードを<PrivateVault>/promptrouter/runs/prompt-runs.jsonlに追記する。実行履歴であり、コンパイル済みレジストリには書かない(spec 9.0, 24.1)。デフォルトでは生プロンプトは保存せずハッシュのみ。
→ <|"Status"->"OK"|"DryRun"|"Skipped"|"Failed", "RunId"->_, "Record"->_|>
Options: "StorePrompt" -> "HashOnly" ("PrivateRaw"|"Off"も可), "PrivacyLevel" -> 0.0, "PrivacyOrigin" -> {}, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "Dependencies" -> <||>, "ModelResolution" -> <||>, "DryRun" -> False

### SourceVaultPromptRunHistory[opts]
追記専用ストアからPromptRunレコードのリストを返す（新着順）。
→ List
Options: "MaxResults" -> Automatic, "RouteId" -> Automatic, "Decision" -> Automatic, "Since" -> Automatic (ISO日時文字列; Timestamp >= Sinceのレコードのみ保持)

### SourceVaultCaptureLastPromptRun[opts]
追記専用履歴から最新のPromptRunを返す。履歴が空の場合はStatus "NoPromptRun"。
→ <|"Status"->"OK","PromptRun"->_|> または <|"Status"->"NoPromptRun",...|>

## PromptRouteレジストリ

### SourceVaultCallableAllowlistRegistry[] → Association
SourceVault所有の呼び出し許可リスト。キー: FunctionId。値: Symbol, UseAsFunctionRoute/UseAsHandlerRefフラグ, SideEffectClass。SourceVault.wlに実在するcallableのみ登録: SourceVaultUpcomingSchedule (ReadOnly), SourceVaultFindNotebooks (ReadOnly), SourceVaultNewNotebook (SafeCreate)。SourceVaultReviewQueue/SourceVaultOpenTodoListはIntentIdとして扱うため未登録(spec 7.3/25)。

### SourceVaultCallableAllowlistView[] → Association
SourceVault所有許可リストとClaudeOrchestrator所有ハンドラー許可リストのマージビューを返す。FunctionRouteディスパッチとHandlerRef解決はこのビューを参照。キー衝突時はSourceVault所有エントリが優先。

### SourceVaultRegisterPromptRoute[route_Association, opts]
PromptRouteをコンパイル済みprompt-route-registryに追加または置換する。DryRun -> True(デフォルト、rule 103)は計画(Topic/RouteId/アクション)を報告するだけで書き込まない。DryRun -> Falseは原子書き込み(encode→verify→tmp→rename)。
→ <|"WrittenCount"->_, "SkippedCount"->_, "ByAction"->_, "Topic"->_, "Channel"->_, "Path"->_|>
Options: "DryRun" -> True

### SourceVaultListPromptRoutes[opts]
チャンネルのPromptRouteリストを返す。
→ List
Options: "IncludeSeed" -> True (Trueのとき、レジストリにないRouteIdについてビルトインシードルートを追加)

### SourceVaultGetPromptRoute[routeId_String, opts]
指定RouteIdのPromptRouteを返す。見つからない場合はStatus NotFoundのAssociationを返す。
→ Association

### SourceVaultDeletePromptRoute[routeId_String, opts]
保存済みPromptRouteをチャンネルレジストリから削除する(原子書き換え)。非破壊的デフォルト: DryRun -> True(デフォルト)は計画のみ報告。実際の削除はDryRun -> FalseかつConfirm -> Trueが必要。
→ <|"Status"->_, "RouteId"->_, "Channel"->_, "Removed"->_, "WasPrimary"->_|>
Options: "DryRun" -> True, "Confirm" -> False

## PromptRun促進・キャプチャ

### SourceVaultPromotePromptRun[runId_String, opts]
記録済みPromptRunを分類し(spec 10.3)、決定論的ルートヒットの場合そのルートのMatcherを実行のフィンガープリントと生例で強化する。DryRun -> True(デフォルト)は計画を報告のみ。WorkflowトレースとLLMオンリー実行は分類のみで自動促進しない。
→ Association
Options: "DryRun" -> True, "Confirm" -> False, "Channel" -> "public"

## プライバシー

### SourceVaultResolvePromptPrivacy[components_Association, opts]
プロンプトのプライバシー寄与を結合してPrivacyLevel(各コンポーネントのMax、spec 11.2)とAllowedTrustDomains/CloudFallback/CloudRouterAllowedメタデータを返す。SecretCellまたはPrivateModelExecutionコンポーネントでlevel >= 0.75に引き上げ(spec 11.3/11.4)。
→ Association
コンポーネントキー(全て数値0.0～1.0): "PromptCellPrivacyLevel", "PromptTextPrivacyLevel", "NotebookDependencyPrivacyLevel", "ModelExecutionPrivacyFloor", "ResultPrivacyLevel", "UserSpecifiedPrivacyLevel"。ブール特殊キー: "SecretCell", "PrivateModelExecution"

### SourceVaultPromptPrivacyAllowsCloudRouter[level] → True|False
PrivacyLevelが0.5(クラウド送信境界)未満のときのみTrueを返す(spec 11.5)。Associationも受け付ける。非数値入力はFalse。

## モデル解決

### SourceVaultResolveModelForPromptRouter[query_Association, opts]
モデルリゾルバーcontract層(spec 12)。クエリをModelIntent/WeightClass/PrivacyLevel/AllowedTrustDomains/CloudFallback/RequiredCapabilities/DegradationPolicyの完全contractに正規化し、SourceVaultResolve["Model", query]を弱呼び出し。リゾルバー不在または結果が未分類ならNeedsModelClassification。PrivacyLevel >= 0.5でLocal/Private未確認モデルはNeedsPrivateModel(クラウドフォールバック不可、spec 12.4)。
→ Association (Requested/Resolved/FallbackKind/CloudFallbackUsed)
Options: opts

### SourceVaultClassifyProviderTrustDomain[label] → "Cloud"|"Local"|"Private"|Missing["UnclassifiedTrustDomain"]
プロバイダー/ルートラベルをTrustDomainにマップする(spec 12.2)。"chatgptcodex"/"ChatGPTCodexCLI"/"ClaudeCodeCLI"/"CloudLLM"/"anthropic"/"openai" -> "Cloud"; "LocalOnly" -> "Local"; "PrivateLLM" -> "Private"。曖昧または不明なラベル(LocalOpenAICompatible, ExternalAPI等)はMissing["UnclassifiedTrustDomain"]でホストリゾルバーがTrustDomainを明示する必要がある。ChatGPT CodexはクラウドバックCLI(ファイルシステムはローカルだがLLM推論はクラウド)。

## 再処理計画

### SourceVaultPromptReprocessPlan[opts]
PromptRouteレジストリをスキャンして陳腐化ルートの再処理計画を返す(spec 14.2/14.3)。読み取り専用。再処理は実行しない。陳腐化判定: SchemaVersion不一致、CompiledRegistryVersion不一致、またはStaleRouteIdsに直接指定。分類ポリシー: FunctionRoute(ReadOnly callable) -> "AutoRecomputable", Intentルート -> "OnDemandRefresh", WorkflowRoute -> "NeedsApproval"。
→ Association (計画のみ、キュー)
Options: "StaleRouteIds" -> {} (直接指定する陳腐化RouteIdのリスト)

## プロンプト保存・検索・UI

### SaveLastPrompt[memo_String, opts]
最新の成功したClaudeEval/ContinueEvalプロンプト実行を名前付きPromptRouteとして保存する。memoはRouteのMemoフィールドに格納される自由記述メモ。Encrypt -> Trueは現在未実装(マスターキー基盤未整備): Status NotImplementedを返す(生プロンプトをサイレントに平文保存しない)。Encrypt -> Falseは生プロンプト/関数を平文保存し、PrivacyLevelとCloudFallbackをルートに記録。SourceVaultDecryptPromptRoute[route]で将来の暗号化ルートを復元。
→ Association
Options: "Channel" -> Automatic ("public"|"private"|"local"; プライバシーから解決), "Encrypt" -> False, "DryRun" -> False, "RouteId" -> Automatic

### AddPromptMemo[memo_String, opts]
最新のClaudeEval/ContinueEvalプロンプトに自由記述メモを付与する。SourceVaultAutoSaveLastPromptで自動保存された最新バージョンのMemoをインプレース更新する(SourceVaultUpdatePromptRouteMemo経由、新バージョンを作らない)。保存バージョンが存在しない場合はSaveLastPromptにフォールバック。
→ <|"Status"->_, "RouteId"->_, "Memo"->_, "Action"->"MemoUpdated"|"MemoSavedNewVersion"|>
Options: "PromptText" -> Automatic, "RouteId" -> Automatic

### SourceVaultDecryptPromptRoute[route_Association]
暗号化PromptRouteのEncryptedPayloadを復号する(SaveLastPrompt Encrypt->Trueで作成)。復号前にMACを検証。失敗時はplaintextを返さない。
→ <|"Status"->"Ok","Plaintext"->_|> またはエラーAssociation

### SourceVaultSearchPromptRoutes[query_String, opts]
保存済みPromptRouteのうちプロンプト例またはmemoにqueryを部分一致するものを返す。query ""は全件マッチ。実行しない。
→ List (routeのAssociationのリスト)
Options: "CreatedAt" -> <|"From"->_,"To"->_|>, "UpdatedAt" -> <|"From"->_,"To"->_|>, "Channel" -> All|"public"|"private"|"local", "IncludeSeed" -> True

### SourceVaultFormatPromptRouteList[routes_List, opts]
保存済みPromptRouteをGridでレンダリングする。列: Prompt, Memo, Target, CreatedAt, UpdatedAt, Privacy。各行にPreview(ドライラン)/Run(実行)/ToInput(Input cellに式を書き込み)ボタン。SourceVaultFormatNotebookListに準ずる。プロンプトルートリストのデフォルト表示形式。
→ Grid

### SourceVaultReplayRoute[route_Association, opts]
保存済みPromptRouteを再実行クラスに応じて再構成し、評価用の式文字列を返す。Replayable: TargetExprStringをそのまま返す。LightLLM: 新プロンプトなしは元のTargetExprStringを復元、新プロンプト文字列を与えると軽量LLM("ExtractModel" -> AutomaticはSourceVault既定モデル)で各パラメータスロットの新InputForm値を抽出してParameterTemplateを埋めた式文字列を返す。HeavyLLMまたは式が記録されていないルートはClaudeEval[...]形式の式を返す。
→ <|"Status"->_, "ReplayClass"->_, "ExprString"->_, "SlotValues"->_|>
Options: "NewPrompt" -> Automatic, "ExtractModel" -> Automatic

### SourceVaultPromptRoutePanel[opts]
保存済みPromptRouteのUIパネルを返す。キーワード/memoで検索、チャンネルフィルタ、各ルートのPreview/Run/ToInput/Primary/Memo/削除管理(SourceVaultFormatPromptRouteList経由)。SourceVaultWorkflowPanelに準ずる(手動リフレッシュ、FEフリーズセーフ)。
→ Dynamic UI Panel
Options: "Channel" -> All|"public"|"private"|"local" (初期チャンネルフィルタ)

## 自動保存・バージョン管理

### $SourceVaultPromptAutoSave
型: True|False, 初期値: True
ClaudeEvalが実行するnotebookプロンプトをSourceVaultAutoSaveLastPromptで新バージョンとして自動保存するかどうかを制御する。Falseで自動キャプチャを無効化。

### $SourceVaultPromptSavedProposalActive
型: True|False, 初期値: True
ClaudeEvalがLLM呼び出し前に保存済みプロンプトの完全一致(正規化)を参照して提案するかどうかを制御する。FalseでClaudeEvalエントリの保存済みプロンプト提案を無効化。

### $SourceVaultPromptBypassOnce
型: String|Missing["None"], 初期値: Missing["None"]
ワンショット正規化プロンプトキー。SourceVaultProposeSavedPromptRouteがこれにマッチするプロンプトを検出するとキーを消費(Missing["None"]にリセット)して提案を拒否し、ClaudeEvalがLLMパスにフォールスルーする。保存済みプロンプトリストの「LLMに再度聞く」ボタンがセットする。

### $SourceVaultContextPlannerEnabled
型: True|False, 初期値: True
Trueのとき、SourceVaultがClaudeCode`$ClaudeEvalContextPlannerにコンテキストプランナーを登録する。プランナーはSourceVaultClassifyPromptContextDependencyを使って各プロンプトのContextPlanを絞り込む。FalseでプランナーをNo-opにする(ベースパッケージがデフォルトプランにフォールバック)。リロード不要。

### $SourceVaultContextPlannerTrimSelfContained
型: True|False, 初期値: False
Trueのとき、プランナーはSELF-CONTAINED(マーカーなし)プロンプトのnotebookコンテキストをNoneにトリムする(デフォルトのbounded Tailではなく)。軽量モデルが些細なプロンプトで前のセルを模倣するのを防ぐが、マーカーなしのnotebook依存プロンプトが文脈を失うリスクがある。保守的なデフォルトFalse。

### SourceVaultAutoSaveLastPrompt[prompt_String, opts]
最新の成功したClaudeEval/ContinueEval実行を新しい保存済みPromptRouteバージョンとして保存する(既存バージョンを上書きしない)。ClaudeEvalが自動的に呼び出すデフォルトオンキャプチャパス。同一(正規化)プロンプトのバージョンはPromptGroupIdを共有する。TargetExprStringがグループの最新バージョンと重複する場合はスキップ。$SourceVaultPromptAutoSaveでゲート制御。
→ SaveLastPromptの結果 または <|"Status"->"Skipped"|>
Options: "Memo" -> "", SaveLastPromptの全オプション

### SourceVaultMatchSavedPromptVersions[prompt_String, opts]
正規化プロンプトが完全一致する保存済みPromptRouteを全チャンネルから返す(PromptHash正規化と同じ正規化を使用)。primaryを先頭に、その後新着順。マッチなしは{}。
→ List
Options: "Channel" -> All, "IncludeSeed" -> False

### SourceVaultPrimaryPromptRoute[prompt_String]
プロンプトグループのプライマリ保存済みPromptRouteを返す。"Primary"フィールドがTrueのルートがプライマリ(SourceVaultSetPrimaryPromptRouteでセット)。
→ Association|Missing["NoPrimary"]

### SourceVaultSetPrimaryPromptRoute[routeId_String, opts]
ルートをPromptGroupId内のプライマリバージョンとしてマークし、兄弟ルートのPrimaryをクリアする(チャンネル横断)。AutoExecute -> TrueのときClaudeEvalは確認ダイアログなしにルートの凍結式をリリース評価できる(ReplaySafety "EnvironmentIndependent"のルートのみ有効)。可逆なメタデータトグルのためDryRunデフォルトFalse。
→ <|"Status"->_, "RouteId"->_, "Channel"->_, "ClearedSiblings"->_|>
Options: "AutoExecute" -> False

### SourceVaultRunPrimaryRoute[groupId_String, opts]
プライマリルートの凍結式のゲート付きエグゼキュータ。TargetExprStringを評価なしにパースし、(a)headがReadOnly/SafeCreate SourceVault callableで(b)ReplaySafety "EnvironmentIndependent"のときのみ評価する。Set/SetDelayed/AppendTo/ClaudeAttach/SystemCredentialおよび未分類headは拒否。ClaudeEvalはHoldComplete[SourceVaultRunPrimaryRoute[..]]提案経由でのみ到達する(ClaudeEvalが保存式を直接リリースすることはない)。
→ Association

### SourceVaultPromptVersionsUI[normKey_String, prompt_String, opts]
プロンプトグループの保存済みバージョン(SourceVaultFormatPromptRouteList経由)をヘッダーと「LLMに再度聞く」ボタン付きでレンダリングする。保存済みバージョンが存在するが自動実行プライマリが未設定のときClaudeEvalがLLMの代わりにこれを表示する。
→ Dynamic UI

### SourceVaultProposeSavedPromptRoute[prompt_String, opts]
ClaudeEvalエントリの保存済みプロンプト提案器(claudecodeからLLM呼び出し前に弱呼び出し)。"ProposedExpression"として、AutoExecuteありEnvironmentIndependentプライマリのときHoldComplete[SourceVaultRunPrimaryRoute[groupId]]、保存バージョンがあるときHoldComplete[SourceVaultPromptVersionsUI[..]]を返す。機能がオフ・ワンショットバイパスキーマッチ・保存バージョン不一致のときStatus NotDispatched。
→ PromptRouteProposal Association

### SourceVaultUpdatePromptRouteMemo[routeId_String, memo_String]
保存済みPromptRouteのMemoフィールドを設定し(チャンネル原子書き換え)、UpdatedAtを更新する。暗号化ルートでもMemoはプレーンテキストで保存される(表示ラベルのため)。SourceVaultFormatPromptRouteListの編集可能Memoセルが使用する。
→ <|"Status"->_, "RouteId"->_, "Channel"->_, "Memo"->_|>

## コンテキスト依存分類

### SourceVaultClassifyPromptReplaySafety[prompt_String, exprString_, contextBinding_]
生成済み式を凍結定数として再生可能かどうかを分類する。ContextBound条件: 式にキャプチャされたnotebookコンテキストが直接埋め込まれている、セッション過渡シンボル(%/Out/In/SelectedCells/NotebookRead/...)を参照、またはプロンプトに指示詞("cell above"等)を含む。EnvironmentIndependentルートのみ自動実行可能。ContextBoundルートはReplayClass HeavyLLMに強制。
→ <|"ReplaySafety"->"EnvironmentIndependent"|"ContextBound"|"Unknown", "ContextBinding"-><|...|>|>

### SourceVaultClassifyPromptContextDependency[prompt_String]
LLMフリー・プロンプトのみの事前フィルタ。新プロンプトが式生成前に必要とするコンテキストを推論する(SourceVaultClassifyPromptReplaySafetyとは異なり生成済み式を対象としない)。iSVPRDeicticQと指示詞パターンテーブルを共有。notebookの参照と会話履歴の参照を混同しない。何も検出されない場合はfloor空(DependencyKinds {"SelfContained"}, Confidence "Low")。RequiredContextは必要な最低限(floor)。コンテキストプランナーがこれとリクエスト/デフォルトプランを組み合わせる。
→ <|"DependencyKinds"->{...}, "RequiredContext"-><|"Notebook"-><|"Mode"->"None"|"PreviousCellGroup"|"Tail"|"Full"|>, "SelectedCells"->True|False, "History"-><|"Mode"->"None"|"Recent"|>|>, "Confidence"->"High"|"Low", "Reasons"->{...}|>