# api_promptrouter.md — SourceVault_promptrouter API リファレンス

SourceVault` コンテキストの拡張パッケージ。独立パッケージではなく、SourceVault.wl ブートストラップが Get[] で読み込む。ClaudeRuntime / ClaudeOrchestrator を Needs しない。これらが不在でもロードでき、可用性は公開シンボル名から実行時に弱検出する。再 Get[] は冪等。全公開シンボルは SourceVault` 文脈に属する。

## バージョン・状態

### $SourceVaultPromptRouterVersion
型: String
PromptRouter 拡張のバージョン文字列。

### SourceVaultPromptRouterStatus[] → Association
拡張の状態を返す。version、実装フェーズ、claudecode / SourceVault / ClaudeRuntime / ClaudeOrchestrator の可用性、自動 ClaudeEval ディスパッチが現在有効かを含む。

### SourceVaultPromptRouterAvailableQ[] → True|False
拡張自体が SourceVault` 文脈にロード済みなら True。ClaudeRuntime / ClaudeOrchestrator の存在は含意しない。

### SourceVaultPromptRouterActiveQ[caller] → True|False
指定 caller のリクエストを PromptRouter が処理すべきなら True。caller: "Manual" | "ClaudeEval" | Automatic（既定 Automatic、"ClaudeEval" 扱い）。Manual API は拡張ロード時は常に有効。自動 ClaudeEval ディスパッチは ClaudeOrchestrator もロード済みのときのみ有効。

## ルート解決・実行

### SourceVaultResolvePromptRoute[prompt, opts]
プロンプトを実行せずルート決定 Association に解決する。決定論的マッチ（Matcher KeywordsAny）→ 字句検索フォールバックの順。
→ Association（Status, Decision, ... を含む）
Options: "DryRun" -> False, "AllowLLMRouter" -> Automatic, "AllowWorkflow" -> Automatic, "PrivacyLevel" -> Automatic, "StorePrompt" -> "HashOnly", "FallbackToClaudeEval" -> True, "Caller" -> Automatic

### SourceVaultExecutePromptRoute[prompt, opts]
ルートを解決し実行する。resolve → adapter → allowlist 検査 → ディスパッチ（ReadOnly callable のみ）→ PromptRun 記録。手動／テスト／診断用 API で評価を行ってよい。
→ Association（Status 等。未ディスパッチ時は "NotDispatched" で ClaudeEval にフォールバック）
Options: SourceVaultResolvePromptRoute と同じ

### SourceVaultRouteExplain[prompt, opts] → String
プロンプトがどうルーティングされるかの人間可読な説明を返す。
Options: SourceVaultResolvePromptRoute と同じ

### SourceVaultProposePromptRoute[prompt_String, opts]
ClaudeEval 向け API（spec v11 5.3）。スケジュールプロンプトを未評価の提案式 HoldComplete[SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]] に解決し、それを "ProposedExpression" に持つ PromptRouteProposal Association を返す。式は決して評価しない。非スケジュールプロンプトは Status "NotDispatched"。
→ Association
例: SourceVaultProposePromptRoute["今日から3日間の予定"]

## PromptRun 履歴（追記専用 JSONL）

PromptRun は実行履歴であり、レジストリエントリではない。<PrivateVault>/promptrouter/runs/prompt-runs.jsonl に claims.jsonl 同様の追記専用で保存。コンパイル済みレジストリには書かない。生プロンプトは既定で保存せずハッシュのみ。

### SourceVaultPromptRunRecord[prompt, routeDecision, result, opts]
PromptRun レコードを追記する。
→ <|"Status" -> "OK"|"DryRun"|"Skipped"|"Failed", "RunId" -> ..., "Record" -> ...|>
Options: "StorePrompt" -> "HashOnly" ("PrivateRaw"|"Off" 可), "PrivacyLevel" -> 0.0, "PrivacyOrigin" -> {}, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "Dependencies" -> <||>, "ModelResolution" -> <||>, "DryRun" -> False

### SourceVaultPromptRunHistory[opts] → List
PromptRun レコードのリストを新しい順で返す。
Options: "MaxResults" -> Automatic, "RouteId" -> Automatic, "Decision" -> Automatic, "Since" -> Automatic (ISO 日時文字列。Timestamp >= Since を保持)

### SourceVaultCaptureLastPromptRun[opts]
履歴の最新 PromptRun を返す。空なら Status "NoPromptRun"。
→ <|"Status" -> "OK", "PromptRun" -> ...|>

### SourceVaultPromotePromptRun[runId_String, opts]
記録済み PromptRun を分類（spec 10.3）し、決定論ルートヒット時にそのルートの Matcher を run の指紋・生例で強化する。WorkflowTrace / LLM 単発は分類のみで自動昇格しない。書込は Order 5a レジストリ API 経由。
→ Association
Options: "DryRun" -> True (既定、rule 103), "Confirm" -> False, "Channel" -> "public"

## Callable allowlist

### SourceVaultCallableAllowlistRegistry[] → Association
SourceVault 所有の callable allowlist。FunctionId をキーに、生 Symbol、UseAsFunctionRoute / UseAsHandlerRef フラグ、SideEffectClass を保持。SourceVault.wl に実在する callable のみ登録（SourceVaultUpcomingSchedule, SourceVaultFindNotebooks は "ReadOnly"; SourceVaultNewNotebook は "SafeCreate"）。生 Symbol を含むため JSON レジストリに書いてはならない。引数を取らない。

### SourceVaultCallableAllowlistView[] → Association
SourceVault 所有 allowlist と、ClaudeOrchestrator ロード時はその handler allowlist（弱呼出）を統合した論理ビュー。FunctionRoute ディスパッチと HandlerRef 解決が参照する。キー衝突時は SourceVault 所有エントリが優先。

## PromptRoute レジストリ書込・読込

### SourceVaultRegisterPromptRoute[route_Association, opts]
コンパイル済み prompt-route-registry に PromptRoute を追加／置換する。DryRun -> False は原子的書込（encode, verify, tmp, rename）。
→ WrittenCount / SkippedCount / ByAction / Topic / Channel / Path 集計の Association
Options: "DryRun" -> True (既定、rule 103。計画する Topic/RouteId/action を報告し書込まない), "Channel" -> "public" 等

### SourceVaultListPromptRoutes[opts] → List
チャネルの PromptRoute を返す。
Options: "IncludeSeed" -> True (既定。レジストリに無い RouteId に組込みシードルートを追加), "Channel"

### SourceVaultGetPromptRoute[routeId_String, opts] → Association
指定 RouteId の PromptRoute を返す。無ければ Status "NotFound"。

## プライバシー・モデル解決

### SourceVaultResolvePromptPrivacy[components_Association, opts]
プロンプトのプライバシー寄与を単一 PrivacyLevel（全成分の Max、spec 11.2）に統合し、AllowedTrustDomains / CloudFallback / CloudRouterAllowed メタを付す。SecretCell または PrivateModelExecution 成分は level を最低 0.75 に引上げ、AllowedTrustDomains を {"Local","Private"}、CloudFallback を "Deny" にする。level >= 0.5 が cloud-send 境界。
→ <|"Type" -> "PromptPrivacyResolution", "PrivacyLevel", "PrivacyOrigin", "AllowedTrustDomains", "CloudFallback", "RawPromptStored" -> False, "PromptStorageClass" -> "HashOnly", "CloudRouterAllowed", ...|>
成分キー: "PromptCellPrivacyLevel", "PromptTextPrivacyLevel", "NotebookDependencyPrivacyLevel", "ModelExecutionPrivacyFloor", "ResultPrivacyLevel", "UserSpecifiedPrivacyLevel"（数値、欠落は 0.0）, "SecretCell", "PrivateModelExecution"（真偽）

### SourceVaultPromptPrivacyAllowsCloudRouter[level] → True|False
PrivacyLevel が 0.5 境界未満のときのみ True。引数は数値、またはプライバシー解決 Association も可。非数値入力は危険側 False。

### SourceVaultResolveModelForPromptRouter[query_Association, opts]
モデルリゾルバ契約層（spec 12）。query を full contract（ModelIntent / WeightClass / PrivacyLevel / AllowedTrustDomains / CloudFallback / RequiredCapabilities / DegradationPolicy）に正規化し、ホストリゾルバ SourceVault`SourceVaultResolve["Model", query] を実在時のみ弱呼出する。リゾルバ不在／分類不能なら "NeedsModelClassification"。PrivacyLevel >= 0.5 で Local/Private を確認できないモデルは cloud フォールバックせず "NeedsPrivateModel"。query には String の ModelIntent が必須（無ければ Status "Failed", Reason "MissingModelIntent"）。
→ Association（Requested / Resolved / FallbackKind / CloudFallbackUsed 形状）
正規化既定: ModelIntent -> "router", WeightClass -> Automatic, PrivacyLevel -> 0.0, AllowedTrustDomains -> Automatic, CloudFallback -> "Ask", RequiredCapabilities -> {"TextIn","TextOut"}, DegradationPolicy -> "Flexible"

### SourceVaultClassifyProviderTrustDomain[label] → String|Missing
プロバイダ／ルートラベルを TrustDomain にマップ（spec 12.2）。"chatgptcodex"/"ChatGPTCodexCLI"/"ClaudeCodeCLI"/"CloudLLM" 等 → "Cloud"; "LocalOnly"/"local" → "Local"; "PrivateLLM"/"private" → "Private"。曖昧・不明（LocalOpenAICompatible, ExternalAPI 等）は Missing["UnclassifiedTrustDomain"]。ChatGPT Codex はサンドボックスはローカルだが推論はクラウドのため "Cloud"。

## 再処理計画

### SourceVaultPromptReprocessPlan[opts] → Association
PromptRoute レジストリを走査し陳腐化ルート（SchemaVersion / CompiledRegistryVersion 不一致、または StaleRouteIds オプションで指名）を読取専用の再処理計画にする。何も再処理しない。各陳腐ルートを spec 14.3 で分類: ReadOnly FunctionRoute -> "AutoRecomputable"、Intent / TabularQuery -> "OnDemandRefresh"、Workflow / WorkflowTemplate -> "NeedsApproval"。
Options: "StaleRouteIds" -> {...}

## 保存・検索・暗号化・再実行（Phase D, UI scope）

### SaveLastPrompt[memo_String, opts]
直近の成功 ClaudeEval / ContinueEval 実行を名前付き PromptRoute として保存し、後で検索・再実行可能にする。memo は自由テキスト注記で route の Memo に保存しプロンプト表に表示。プライバシーは SourceVaultResolvePromptPrivacy で追跡。Encrypt -> False では生プロンプト／関数は平文保存だが PrivacyLevel と CloudFallback は記録。Encrypt -> True では生プロンプトと TargetExprString を SourceVaultEncryptedPut で encrypt-then-MAC 暗号化し EncryptedPayload として route に埋込み、Examples を空に、PromptStorageClass を "Encrypted" に（Memo は表示ラベルとして平文保持）。暗号化には SourceVault 暗号モジュールのロードと SourceVaultInitializeEncryption[] 実行が必要。復号は SourceVaultDecryptPromptRoute[route]。
→ Association
Options: "Channel" -> Automatic ("public"|"private"|"local"、プライバシーから解決), "Encrypt" -> False, "DryRun" -> False, "RouteId" -> Automatic
注: 現行ソースでは Encrypt -> True はマスター鍵基盤未実装のため Status "NotImplemented" を返す場合がある（平文を黙って保存しない）。

### SourceVaultDecryptPromptRoute[route_Association]
暗号化 PromptRoute（SaveLastPrompt Encrypt -> True 作成）の EncryptedPayload を復号する。復号前に MAC を検証し、失敗時は平文を返さない。
→ <|"Status" -> "Ok", "Plaintext" -> ...|> またはエラー Association

### SourceVaultSearchPromptRoutes[query_String, opts] → List
プロンプト例または memo に query を部分一致で含む保存済み PromptRoute を返す（SourceVaultFindNotebooks Keywords と同様の部分一致）。query "" は全件。何も実行しない。
→ route Association のリスト
Options: "CreatedAt" -> <|"From"->_,"To"->_|>, "UpdatedAt" -> <|"From"->_,"To"->_|> (定義／最終更新日でフィルタ、ノートブッククエリ API と同じ日付範囲形式), "Channel" -> All|"public"|"private"|"local", "IncludeSeed" -> True

### SourceVaultFormatPromptRouteList[routes_List, opts] → Grid
保存済み PromptRoute を Grid 描画する（列: Prompt, Memo, Target, CreatedAt, UpdatedAt, Privacy）。各行に 3 ボタン: Preview（dry-run、実行せず内容表示）、Run（即実行）、ToInput（保存済み関数呼出式を新規 Input セルに書込）。プロンプトでルートリストを求められた際の既定表示形式。

### SourceVaultReplayRoute[route_Association, opts]
保存済み PromptRoute を再実行クラスに応じて再構成し、評価用の式文字列を返す。Replayable は TargetExprString をそのまま返す。LightLLM は "NewPrompt" 無しなら元の TargetExprString を復元し、新プロンプトを与えると軽量 LLM で各パラメータスロットの新 InputForm 値を抽出し ParameterTemplate を埋めた式文字列を返す。HeavyLLM または式未記録ルートは ClaudeEval[...] 形式の式を返す。
→ <|"Status", "ReplayClass", "ExprString", "SlotValues"|>
Options: "NewPrompt" -> Automatic, "ExtractModel" -> Automatic (SourceVault 既定モデル)

## 関連パッケージ

SourceVault: https://github.com/transreal/SourceVault
ClaudeRuntime: https://github.com/transreal/ClaudeRuntime
ClaudeOrchestrator: https://github.com/transreal/ClaudeOrchestrator
NBAccess: https://github.com/transreal/NBAccess
SourceVault_crypto: https://github.com/transreal/SourceVault_crypto