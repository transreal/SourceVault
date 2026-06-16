# SourceVault_promptrouter API リファレンス

パッケージ: `SourceVault_promptrouter` ([GitHub](https://github.com/transreal/SourceVault_promptrouter))
コンテキスト: `SourceVault`` (独立パッケージではなく [SourceVault](https://github.com/transreal/SourceVault) 拡張)
ロード方法: SourceVault.wl の bootstrap が `Get[]` で自動ロード。`Needs["SourceVault_promptrouter`"]` は使わない。
依存: [SourceVault](https://github.com/transreal/SourceVault) (必須), [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime) / [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) (オプション、公開シンボル名から存在検出のみ)
冪等性: `Get[]` 再実行でクリーン再定義される。

## アーキテクチャ注意事項

- `Needs["ClaudeRuntime`"]` / `Needs["ClaudeOrchestrator`"]` を呼ばない。存在検出は公開シンボル名のみ。
- ClaudeRuntime / ClaudeOrchestrator 不在でもロード可能。
- write API は rule 103 により DryRun -> True がデフォルト(明示的に DryRun -> False を渡さなければ書き込まない)。
- 追記専用 JSONL ストア (<PrivateVault>/promptrouter/runs/) はコンパイル済みレジストリとは別。
- ClaudeEval への返り値は評価済み結果ではなく未評価式 HoldComplete[...] でなければならない(spec 5.2)。

## 設定変数

### $SourceVaultPromptRouterVersion
型: String
PromptRouter 拡張のバージョン文字列。

### $SourceVaultPromptAutoSave
型: Boolean, 初期値: True
True のとき ClaudeEval 実行プロンプトを毎回 SourceVaultAutoSaveLastPrompt で自動保存する。再ロード時に値を保持する(ClearAll 対象外)。

### $SourceVaultPromptSavedProposalActive
型: Boolean, 初期値: True
True のとき ClaudeEval は LLM 呼び出し前に保存済みプロンプトを照合して提案する。再ロード時に値を保持する。

### $SourceVaultPromptBypassOnce
型: String | Missing["None"], 初期値: Missing["None"]
ワンショット正規化キー。SourceVaultProposeSavedPromptRoute がこのキーに一致するプロンプトを検出するとキーをリセットして提案をスキップし ClaudeEval を LLM パスにフォールスルーさせる。「LLM に再度聞く」ボタンがこれをセットする。

### $SourceVaultContextPlannerEnabled
型: Boolean, 初期値: True
True のとき ClaudeCode`$ClaudeEvalContextPlanner に SourceVaultClassifyPromptContextDependency を使うプランナーを登録する。False で no-op (ベースパッケージのデフォルトプランにフォールバック)。再ロード時に値を保持する。

### $SourceVaultContextPlannerTrimSelfContained
型: Boolean, 初期値: False
True のとき SELF-CONTAINED (マーカーなし) プロンプトのノートブックコンテキストを Notebook "None" に切り詰める。軽量モデルが前セルを模倣するのを防ぐが、マーカーなしのノートブック依存プロンプトを飢餓させるリスクがある。再ロード時に値を保持する。

## ステータス / 可用性 API

### SourceVaultPromptRouterStatus[] → Association
PromptRouter 拡張の状態を返す。キー: Version, Phase, claudecode 利用可否, SourceVault 利用可否, ClaudeRuntime 利用可否, ClaudeOrchestrator 利用可否, ClaudeEval 自動ディスパッチがアクティブか。

### SourceVaultPromptRouterAvailableQ[] → True | False
拡張が `SourceVault`` コンテキストにロードされているとき True を返す。ClaudeRuntime / ClaudeOrchestrator の存在は意味しない。

### SourceVaultPromptRouterActiveQ[caller] → True | False
PromptRouter が指定 caller のリクエストを処理すべきとき True を返す。caller: "Manual" | "ClaudeEval" | Automatic (省略時 Automatic、"ClaudeEval" として扱う)。Manual は拡張ロード時に常にアクティブ。自動 ClaudeEval ディスパッチは ClaudeOrchestrator がロード済みのときのみアクティブ。

## ルーティング解決 / 実行 API

### SourceVaultResolvePromptRoute[prompt, opts]
プロンプトをルート決定 Association に解決する(実行しない)。決定論的マッチ → FunctionRoute、キーワードマッチ → LexicalMatch、未一致 → NotFound。
→ Association: Status, Decision, Route, Parameters 等
Options: "DryRun" -> False, "AllowLLMRouter" -> Automatic, "AllowWorkflow" -> Automatic, "PrivacyLevel" -> Automatic, "StorePrompt" -> "HashOnly", "FallbackToClaudeEval" -> True, "Caller" -> Automatic

### SourceVaultExecutePromptRoute[prompt, opts]
プロンプトルートを解決して実行する。NotDispatched のとき ClaudeEval の従来ルートにフォールバックする。
→ Association: Status, Decision, Result 等
Options: SourceVaultResolvePromptRoute と同じ

### SourceVaultRouteExplain[prompt, opts] → String
プロンプトがどのようにルーティングされるかの説明を返す。現在の RouterStatus をエコーする。

### SourceVaultProposePromptRoute[prompt_String, opts]
ClaudeEval 向け PromptRouter API (spec v11 5.3)。スケジュールプロンプトを未評価の提案式に解決して返す。式は評価しない。非スケジュールプロンプトは Status NotDispatched を返す。
→ PromptRouteProposal Association ("ProposedExpression" フィールドに HoldComplete[SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]] を持つ)

例: `SourceVaultProposePromptRoute["今後3日の予定を見せて"]` → ProposedExpression: `HoldComplete[SourceVaultUpcomingSchedule["Period" -> Quantity[3,"Days"], "FallbackToCloud" -> "Deny"]]`

## PromptRun 履歴 API

### SourceVaultPromptRunRecord[prompt, routeDecision, result, opts]
PromptRun レコードを追記専用 JSONL ストア (<PrivateVault>/promptrouter/runs/prompt-runs.jsonl) に追記する。実行履歴であり、コンパイル済みレジストリには書かない。デフォルトではプロンプト生テキストを保存せずハッシュのみ保持する。
→ <|"Status" -> "OK" | "DryRun" | "Skipped" | "Failed", "RunId" -> ..., "Record" -> ...|>
Options: "StorePrompt" -> "HashOnly" ("PrivateRaw" | "Off" も可), "PrivacyLevel" -> 0.0, "PrivacyOrigin" -> {}, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "Dependencies" -> <||>, "ModelResolution" -> <||>, "DryRun" -> False

### SourceVaultPromptRunHistory[opts]
追記専用ストアから PromptRun レコードのリストを新しい順で返す。
→ List of Association
Options: "MaxResults" -> Automatic, "RouteId" -> Automatic, "Decision" -> Automatic, "Since" -> Automatic (ISO 日時文字列; Timestamp >= Since のレコードのみ)

### SourceVaultCaptureLastPromptRun[opts]
追記専用履歴から最新の PromptRun を返す。履歴が空のとき Status NoPromptRun を返す。
→ <|"Status" -> "OK", "PromptRun" -> ...|> | <|"Status" -> "NoPromptRun", ...|>

### SourceVaultPromotePromptRun[runId_String, opts]
記録済み PromptRun を分類し (spec 10.3)、決定論的ルートヒットの場合はそのルートの Matcher をフィンガープリントと生例で強化する。WorkflowRoute トレースと LLM オンリー実行は分類のみで自動昇格しない。
→ Association: Status, Classification, RouteId 等
Options: "DryRun" -> True (デフォルト、rule 103), "Confirm" -> False, "Channel" -> "public"

## レジストリ管理 API

### SourceVaultRegisterPromptRoute[route_Association, opts]
コンパイル済みプロンプトルートレジストリにルートを追加または置換する。DryRun -> True (デフォルト) は計画を報告するだけで書き込まない。DryRun -> False は atomic 書き込み (encode → verify → tmp → rename) を実行する。
→ Association: WrittenCount, SkippedCount, ByAction, Topic, Channel, Path
Options: "DryRun" -> True

### SourceVaultListPromptRoutes[opts]
チャンネルの PromptRoute リストを返す。
→ List of Association
Options: "IncludeSeed" -> True (True のときレジストリにない RouteId の組み込みシードルートを追加), "Channel" -> Automatic

### SourceVaultGetPromptRoute[routeId_String, opts]
指定 RouteId の PromptRoute を返す。見つからない場合は Status NotFound の Association を返す。
→ Association

### SourceVaultCallableAllowlistRegistry[] → Association
SourceVault 所有の callable allowlist を返す。キー: FunctionId。値: Symbol, UseAsFunctionRoute/UseAsHandlerRef フラグ, SideEffectClass, OwnerPackage。SourceVault.wl に実在する関数のみ登録 (SourceVaultUpcomingSchedule [ReadOnly], SourceVaultFindNotebooks [ReadOnly], SourceVaultNewNotebook [SafeCreate] 等)。SourceVaultReviewQueue / SourceVaultOpenTodoList は IntentId として扱うため未登録。

### SourceVaultCallableAllowlistView[] → Association
SourceVault 所有 allowlist と (ClaudeOrchestrator ロード時は) Orchestrator 所有ハンドラ allowlist のマージビューを返す。FunctionRoute ディスパッチと HandlerRef 解決はこのビューを参照する。キー衝突時は SourceVault 所有エントリが優先。

### SourceVaultPromptReprocessPlan[opts]
PromptRoute レジストリをスキャンして陳腐化ルート (スキーマ/レジストリバージョン不一致、または StaleRouteIds で指定) の再処理計画を返す (読み取り専用)。実際の再処理は行わない。ポリシー: FunctionRoute (ReadOnly callable) → "AutoRecomputable", Intent → "OnDemandRefresh", WorkflowRoute → "NeedsApproval"。
→ Association: StalePolicies リスト
Options: "StaleRouteIds" -> {}

## プロンプトキャプチャ / バージョン管理 API

### SaveLastPrompt[memo_String]
直近の成功した ClaudeEval / ContinueEval プロンプト実行を名前付き PromptRoute として保存する。memo は Memo フィールドに格納されるフリーテキスト (プロンプトテーブルに表示)。Encrypt -> True 指定時は SourceVaultEncryptedPut (encrypt-then-MAC) で生プロンプトと TargetExprString を暗号化して EncryptedPayload に埋め込む (暗号化モジュールと SourceVaultInitializeEncryption[] が必要; 未実装時は Status NotImplemented)。復号は SourceVaultDecryptPromptRoute[route] で行う。
→ Association: Status, RouteId 等
Options: "Channel" -> Automatic ("public" | "private" | "local"、Automatic はプライバシーから解決), "Encrypt" -> False, "DryRun" -> False, "RouteId" -> Automatic

### SourceVaultAutoSaveLastPrompt[prompt_String, opts]
直近の ClaudeEval/ContinueEval 実行を NEW バージョンとして保存する (既存バージョンを上書きしない)。同一正規化プロンプトのバージョンは PromptGroupId を共有。最新バージョンと TargetExprString が重複する場合はスキップ。$SourceVaultPromptAutoSave でゲート制御。ClaudeEval が自動呼び出しするキャプチャパス (手動・メモ付きの対応関数は SaveLastPrompt)。
→ SaveLastPrompt の結果 | <|"Status" -> "Skipped"|>
Options: "Memo" -> "", SaveLastPrompt の各オプション

### SourceVaultMatchSavedPromptVersions[prompt_String, opts]
prompt の正規化形式が完全一致する保存済み PromptRoute を全チャンネルから返す (プライマリ優先→新しい順)。一致なしのとき {}。
→ List of Association
Options: "Channel" -> All, "IncludeSeed" -> False

### SourceVaultPrimaryPromptRoute[prompt_String] → Association | Missing["NoPrimary"]
prompt のグループのプライマリ保存ルートを返す。"Primary" フィールドが True のルート。なければ Missing["NoPrimary"]。

### SourceVaultSetPrimaryPromptRoute[routeId_String, opts]
PromptGroupId 内でルートをプライマリとしてマークし、同グループ内の他ルートの Primary をクリアする (全チャンネル横断)。AutoExecute -> True は EnvironmentIndependent ルートのみ有効。可逆なメタデータ変更なので DryRun デフォルト False。
→ Association: Status, RouteId, Channel, ClearedSiblings
Options: "AutoExecute" -> True | False, "DryRun" -> False

### SourceVaultDeletePromptRoute[routeId_String, opts]
チャンネルレジストリから保存済み PromptRoute を削除する (atomic 書き換え)。非破壊的デフォルト: DryRun -> True は計画のみ報告。実削除には "Confirm" -> True かつ DryRun -> False が必要。
→ Association: Status, RouteId, Channel, Removed, WasPrimary
Options: "DryRun" -> True, "Confirm" -> False

### SourceVaultRunPrimaryRoute[groupId_String, opts]
プライマリルートの凍結式のゲート付き実行。TargetExprString を評価せずにパースし、head が ReadOnly/SafeCreate SourceVault callable かつ ReplaySafety が "EnvironmentIndependent" の場合のみ評価する。Set/SetDelayed/AppendTo/ClaudeAttach/SystemCredential および未分類 head は拒否して評価しない。ClaudeEval は HoldComplete[SourceVaultRunPrimaryRoute[..]] 提案経由でのみアクセスする (ClaudeEval が保存式を直接解放しない)。
→ Association: Status, Result 等

### SourceVaultProposeSavedPromptRoute[prompt_String, opts]
ClaudeEval エントリの保存済みプロンプト提案器 (claudecode から LLM 呼び出し前に weak-call される)。
- EnvironmentIndependent プライマリ + AutoExecute 有効 → HoldComplete[SourceVaultRunPrimaryRoute[groupId]] を ProposedExpression に持つ PromptRouteProposal を返す
- 保存バージョンが存在するが AutoExecute なし → HoldComplete[SourceVaultPromptVersionsUI[..]] を返す
- 機能オフ ($SourceVaultPromptSavedProposalActive = False)、$SourceVaultPromptBypassOnce 一致、一致なし → Status NotDispatched
→ PromptRouteProposal Association

### SourceVaultUpdatePromptRouteMemo[routeId_String, memo_String]
保存済み PromptRoute の Memo フィールドを更新して UpdatedAt をバンプする (atomic チャンネル書き換え)。暗号化ルートでも Memo は平文で保存 (表示ラベルのため)。
→ Association: Status, RouteId, Channel, Memo

### SourceVaultDecryptPromptRoute[route_Association]
Encrypt -> True で SaveLastPrompt が作成した EncryptedPayload を復号する。復号前に MAC を検証し、失敗時は平文を返さない。
→ <|"Status" -> "Ok", "Plaintext" -> ...|> | エラー Association

## ルート再実行 / UI API

### SourceVaultReplayRoute[route_Association, opts]
保存済み PromptRoute を ReplayClass に応じて再構成し、評価用の式文字列を返す。Replayable: TargetExprString をそのまま返す。LightLLM: "NewPrompt" なしなら元の TargetExprString を復元、新プロンプト文字列指定時は軽量 LLM で各パラメータスロットの新 InputForm 値を抽出し ParameterTemplate を埋めた式文字列を返す。HeavyLLM / 式未記録ルート: ClaudeEval[...] 形式の式を返す。
→ <|"Status" -> ..., "ReplayClass" -> ..., "ExprString" -> ..., "SlotValues" -> ...|>
Options: "NewPrompt" -> Automatic, "ExtractModel" -> Automatic (Automatic は SourceVault デフォルトモデル)

### SourceVaultPromptVersionsUI[normKey_String, prompt_String, opts]
プロンプトグループの保存バージョン (SourceVaultFormatPromptRouteList 経由) をヘッダーと「LLM に再度聞く」ボタン付きで描画する。「再度聞く」ボタンは $SourceVaultPromptBypassOnce をセットして提案を一度バイパスし ClaudeEval を LLM 経由で再実行する。自動実行プライマリが未設定のとき ClaudeEval が LLM の代わりにこれを表示する。
→ Dynamic UI オブジェクト

### SourceVaultFormatPromptRouteList[routes_List, opts]
保存済み PromptRoute を Grid としてレンダリングする。列: Prompt, Memo, Target, CreatedAt, UpdatedAt, Privacy。各行にアクションボタン: Preview (ドライラン)・Run (即時実行)・ToInput (Input セルに式を書き込む)。プロンプトルートリスト表示のデフォルト形式。
→ Grid

### SourceVaultSearchPromptRoutes[query_String, opts]
query を部分文字列として例プロンプトまたは Memo に含む保存済み PromptRoute を返す。query "" は全件一致。
→ List of Association
Options: "CreatedAt" -> <|"From" -> _, "To" -> _|>, "UpdatedAt" -> <|"From" -> _, "To" -> _|>, "Channel" -> All | "public" | "private" | "local", "IncludeSeed" -> True

## プライバシー / モデル解決 API

### SourceVaultResolvePromptPrivacy[components_Association, opts]
プロンプトの各プライバシー寄与の Max を 1 つの PrivacyLevel とし AllowedTrustDomains / CloudFallback / CloudRouterAllowed メタデータを統合する。SecretCell または PrivateModelExecution は PrivacyLevel を 0.75 以上に引き上げ AllowedTrustDomains を Local/Private に制限し CloudFallback を Deny にする。
→ Association: PrivacyLevel, AllowedTrustDomains, CloudFallback, CloudRouterAllowed
components の有効キー: "PromptCellPrivacyLevel", "PromptTextPrivacyLevel", "NotebookDependencyPrivacyLevel", "ModelExecutionPrivacyFloor", "ResultPrivacyLevel", "UserSpecifiedPrivacyLevel" (各 0.0–1.0 の数値), "SecretCell" -> Boolean, "PrivateModelExecution" -> Boolean

### SourceVaultPromptPrivacyAllowsCloudRouter[level] → True | False
PrivacyLevel が 0.5 未満 (クラウド送信境界) のときのみ True を返す。Association を渡したときは PrivacyLevel フィールドを使う。非数値入力は安全でないとみなし False を返す。

### SourceVaultResolveModelForPromptRouter[query_Association, opts]
モデルリゾルバコントラクト層 (spec 12)。クエリを正規化してホストリゾルバを weak-call する。リゾルバ不在または結果が未分類の場合は NeedsModelClassification を返す。PrivacyLevel >= 0.5 で Local/Private 確認できないモデルは NeedsPrivateModel を返す (クラウドフォールバックを使わない)。
→ Association: Requested, Resolved, FallbackKind, CloudFallbackUsed
query の有効キー (デフォルト値): "ModelIntent" -> "router", "WeightClass" -> Automatic, "PrivacyLevel" -> 0.0, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "RequiredCapabilities" -> {"TextIn","TextOut"}, "DegradationPolicy" -> "Flexible"

### SourceVaultClassifyProviderTrustDomain[label] → "Cloud" | "Local" | "Private" | Missing["UnclassifiedTrustDomain"]
プロバイダ/ルートラベルを TrustDomain にマップする (spec 12.2)。"chatgptcodex" / "ChatGPTCodexCLI" / "ClaudeCodeCLI" / "CloudLLM" / "anthropic" / "openai" → "Cloud"; "LocalOnly" → "Local"; "PrivateLLM" → "Private"。曖昧または未知のラベル (LocalOpenAICompatible, ExternalAPI 等) は Missing["UnclassifiedTrustDomain"] を返し、ホストリゾルバが TrustDomain を明示的に宣言する必要がある。ChatGPT Codex はファイルシステムサンドボックスはローカルだが LLM 推論はクラウドのため Cloud に分類される。

## 安全性分類 API

### SourceVaultClassifyPromptReplaySafety[prompt_String, exprString_, contextBinding_]
生成済み式が凍結定数として再実行可能かを分類する。ContextBound 判定条件: 式がノートブックコンテキストを埋め込む / %/Out/In/SelectedCells/NotebookRead 等のセッション遷移シンボルを参照 / プロンプトが指示詞 (「上のセル」「選択中」等) を使う。EnvironmentIndependent ルートのみ auto-execute 可能。ContextBound は ReplayClass HeavyLLM に強制される。
→ <|"ReplaySafety" -> "EnvironmentIndependent" | "ContextBound" | "Unknown", "ContextBinding" -> <|...|>|>

### SourceVaultClassifyPromptContextDependency[prompt_String]
LLM なし・プロンプトのみの事前フィルタ。式生成前に新規プロンプトが必要とするコンテキストを推論する (SourceVaultClassifyPromptReplaySafety は生成済み式を分類する点と異なる)。指示詞パターンテーブルは iSVPRDeicticQ と共有。ノートブック参照と会話履歴参照を混同しない。何も検出されない場合は DependencyKinds {"SelfContained"} (floor 空) を返す。RequiredContext は最低限の floor であり、コンテキストプランナーがこれと要求/デフォルトプランを組み合わせる。
→ Association:
  "DependencyKinds" -> {...}
  "RequiredContext" -> <|"Notebook" -> <|"Mode" -> "None" | "PreviousCellGroup" | "Tail" | "Full"|>, "SelectedCells" -> True | False, "History" -> <|"Mode" -> "None" | "Recent"|>|>
  "Confidence" -> "High" | "Low"
  "Reasons" -> {...}