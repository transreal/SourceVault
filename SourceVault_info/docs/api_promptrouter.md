# SourceVault_promptrouter API リファレンス

SourceVault` コンテキストの拡張。独立パッケージではなく `SourceVault.wl` ブートストラップから `Get[]` で読み込まれる。[ClaudeRuntime](https://github.com/transreal/ClaudeRuntime) / [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) に hard-depend せず、公開シンボル名の実行時検出のみで連携する。読み込みは冪等。プロンプトをルートに解決・実行し、PromptRun 履歴記録・ルート登録・プライバシー伝播・モデル解決契約・再処理計画を提供する。

## バージョン・状態

### $SourceVaultPromptRouterVersion
型: String
PromptRouter 拡張のバージョン文字列。

### SourceVaultPromptRouterStatus[] → Association
拡張の状態を返す。version、実装フェーズ、claudecode / SourceVault / ClaudeRuntime / ClaudeOrchestrator の可用性、自動 ClaudeEval ディスパッチが現在有効かを含む。

### SourceVaultPromptRouterAvailableQ[] → Bool
拡張自体が SourceVault` コンテキストに読み込まれていれば True。ClaudeRuntime/ClaudeOrchestrator の存在は意味しない。

### SourceVaultPromptRouterActiveQ[caller] → Bool
指定 caller のリクエストを PromptRouter が処理すべきなら True。caller: "Manual" | "ClaudeEval" | Automatic（既定 Automatic、"ClaudeEval" として扱う）。Manual API は拡張読み込み時に常に有効。自動 ClaudeEval ディスパッチは ClaudeOrchestrator も読み込まれている時のみ有効。

## ルート解決・実行

### SourceVaultResolvePromptRoute[prompt, opts]
プロンプトを実行せずルート決定 Association に解決する。決定論的 FunctionRoute マッチ → 失敗時に語彙検索（KeywordsAny の転置インデックス）にフォールバック。
→ Association（Status / Decision / 正規パラメータ等）
Options: "DryRun" -> False, "AllowLLMRouter" -> Automatic, "AllowWorkflow" -> Automatic, "PrivacyLevel" -> Automatic, "StorePrompt" -> "HashOnly", "FallbackToClaudeEval" -> True, "Caller" -> Automatic

### SourceVaultExecutePromptRoute[prompt, opts]
ルートを解決・実行する。resolve → adapter → allowlist チェック → ディスパッチ（ReadOnly callable のみ）→ PromptRun 記録。手動/テスト/診断用 API で評価してよい。フォールバック時は `<|"Status" -> "NotDispatched", ...|>` を返し既存 ClaudeEval ルートに委譲。
→ Association
Options: SourceVaultResolvePromptRoute と同じ

### SourceVaultRouteExplain[prompt, opts] → Association/String
プロンプトがどうルーティングされるかの人間可読な説明を返す。
Options: SourceVaultResolvePromptRoute と同じ

### SourceVaultProposePromptRoute[prompt_String, opts]
ClaudeEval 向け API（spec v11 5.3）。スケジュールプロンプトを未評価の提案式 `HoldComplete[SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]]` に解決し、それを "ProposedExpression" に格納した PromptRouteProposal Association を返す。式は評価しない。ClaudeEval ブリッジはこのフィールドのみを Runtime に渡し head ベースの検証を行う。非スケジュールプロンプトは Status NotDispatched。
→ Association
日付範囲は Period オプションに、その他の絞り込みは FilterSpec リテラル Association（spec 5.4.3 の閉じた DSL: Kind And/Or/Not/Field、whitelist Op、スキーマフィールド名のみ）に変換される。

## PromptRun 履歴（追記専用 JSONL）

PromptRun は実行履歴であり registry エントリではない。`<PrivateVault>/promptrouter/runs/prompt-runs.jsonl` に追記され、コンパイル済み registry には書かれない。

### SourceVaultPromptRunRecord[prompt, routeDecision, result, opts]
PromptRun レコードを追記専用 JSONL ストアに追加する。生プロンプトは既定で保存せずハッシュのみ保持。
→ `<|"Status" -> "OK"|"DryRun"|"Skipped"|"Failed", "RunId" -> ..., "Record" -> ...|>`
Options: "StorePrompt" -> "HashOnly" (他に "PrivateRaw" | "Off"), "PrivacyLevel" -> 0.0, "PrivacyOrigin" -> {}, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "Dependencies" -> <||>, "ModelResolution" -> <||>, "DryRun" -> False

### SourceVaultPromptRunHistory[opts] → List
追記専用ストアから PromptRun レコードのリストを新しい順で返す。
Options: "MaxResults" -> Automatic, "RouteId" -> Automatic, "Decision" -> Automatic, "Since" -> Automatic (ISO date-time 文字列。Timestamp >= Since を保持)

### SourceVaultCaptureLastPromptRun[opts]
履歴中で最新の PromptRun を返す。空なら Status NoPromptRun。
→ `<|"Status" -> "OK", "PromptRun" -> ...|>`
Options: なし

### SourceVaultPromotePromptRun[runId_String, opts]
記録済み PromptRun を分類（spec 10.3）し、決定論的ルートヒットの場合のみそのルートの Matcher を run の fingerprint と生例で強化する。WorkflowTrace / LLM-only run は分類のみで自動昇格しない。
→ Association（分類結果・登録結果）
Options: "DryRun" -> True (既定、rule 103), "Confirm" -> False, "Channel" -> "public"

## Callable allowlist

### SourceVaultCallableAllowlistRegistry[] → Association
SourceVault 所有の callable allowlist。FunctionId をキーに、生 Symbol・UseAsFunctionRoute / UseAsHandlerRef フラグ・SideEffectClass を保持。SourceVault.wl に実在する callable のみ登録（SourceVaultUpcomingSchedule, SourceVaultFindNotebooks, SourceVaultNewNotebook）。生 Symbol を含むため JSON registry に書いてはならない。引数なし。

### SourceVaultCallableAllowlistView[] → Association
SourceVault 所有 allowlist と、ClaudeOrchestrator 読み込み時はその handler allowlist（weak call で取得）をマージした論理ビュー。FunctionRoute ディスパッチと HandlerRef 解決がこれを参照。キー衝突時は SourceVault 所有エントリが優先。

## PromptRoute registry 書き込み

### SourceVaultRegisterPromptRoute[route_Association, opts]
PromptRoute をコンパイル済み prompt-route-registry に追加/置換する。DryRun -> True（既定、rule 103）は計画した topic / RouteId / action を報告し書き込まない。DryRun -> False はアトミック書き込み（encode → verify → tmp → rename）を行う。
→ Association（WrittenCount / SkippedCount / ByAction / Topic / Channel / Path）

### SourceVaultListPromptRoutes[opts] → List
チャンネルの PromptRoute を返す。IncludeSeed -> True（既定）で registry に無い RouteId について組み込み seed ルートを追加。
Options: "IncludeSeed" -> True, "Channel"（channel 指定）

### SourceVaultGetPromptRoute[routeId_String, opts] → Association
指定 RouteId の PromptRoute を返す。無ければ Status NotFound。

## プライバシー伝播

### SourceVaultResolvePromptPrivacy[components_Association, opts]
プロンプトのプライバシー寄与を単一 PrivacyLevel（全コンポーネントの Max、spec 11.2）に合成し、AllowedTrustDomains / CloudFallback / CloudRouterAllowed メタデータを付加する。SecretCell または PrivateModelExecution コンポーネントはレベルを最低 0.75 に引き上げ、AllowedTrustDomains を {"Local","Private"} に制限、CloudFallback を "Deny" に。
→ Association（Type "PromptPrivacyResolution", PrivacyLevel, PrivacyOrigin, AllowedTrustDomains, CloudFallback, RawPromptStored, PromptStorageClass, CloudRouterAllowed, RouterVersion）
components の数値キー: "PromptCellPrivacyLevel", "PromptTextPrivacyLevel", "NotebookDependencyPrivacyLevel", "ModelExecutionPrivacyFloor", "ResultPrivacyLevel", "UserSpecifiedPrivacyLevel"（欠落は 0.0）。真偽キー: "SecretCell", "PrivateModelExecution"。
Options: なし

### SourceVaultPromptPrivacyAllowsCloudRouter[level] → Bool
PrivacyLevel が 0.5 のクラウド送信境界未満の時のみ True（spec 11.5）。プライバシー解決 Association も引数に取れる。非数値入力は unsafe 扱いで False。

## モデル解決契約

### SourceVaultResolveModelForPromptRouter[query_Association, opts]
モデル解決契約層（spec 12）。query を完全契約（ModelIntent / WeightClass / PrivacyLevel / AllowedTrustDomains / CloudFallback / RequiredCapabilities / DegradationPolicy）に正規化し、`SourceVault`SourceVaultResolve["Model", query]`（実在時のみ weak-call）に委譲する。resolver 不在または分類不能なら NeedsModelClassification。PrivacyLevel >= 0.5 で Local/Private 確認できないモデルはクラウドフォールバックせず NeedsPrivateModel を返す。query には String の ModelIntent が必須（無ければ Status Failed / MissingModelIntent）。
→ Association（Status, Requested, Resolved, FallbackKind, CloudFallbackUsed 等）
Options: なし

### SourceVaultClassifyProviderTrustDomain[label] → String/Missing
provider/route ラベルを TrustDomain にマップする（spec 12.2）。"chatgptcodex" / "ChatGPTCodexCLI" / "ClaudeCodeCLI" / "CloudLLM" / "anthropic" / "openai" → "Cloud"、"LocalOnly" / "local" → "Local"、"PrivateLLM" / "private" → "Private"。曖昧/未知（LocalOpenAICompatible, ExternalAPI 等）は `Missing["UnclassifiedTrustDomain"]`。host resolver の明示 TrustDomain が常に優先。ChatGPT Codex は cloud-backed CLI（sandbox はローカルだが推論はクラウド）。

## 再処理計画

### SourceVaultPromptReprocessPlan[opts] → Association
PromptRoute registry を走査し stale なルート（SchemaVersion / CompiledRegistryVersion 不一致、または StaleRouteIds で名指し）を読み取り専用の再処理計画に分類する。ReadOnly FunctionRoute は "AutoRecomputable"、Intent / TabularQuery ルートは "OnDemandRefresh"、WorkflowRoute は "NeedsApproval"。計画を作るだけで再処理は行わない。
Options: "StaleRouteIds"（直接 stale 指定する RouteId リスト）, "Channel"

## プロンプト保存・検索・表示（Phase D / UI）

### SaveLastPrompt[memo_String, opts]
直近の成功した ClaudeEval / ContinueEval プロンプト実行を名前付き PromptRoute として保存し、後で検索・再実行可能にする。memo は自由記述メモ（route の Memo フィールドに格納、プロンプト表に表示）。生プロンプト/関数は既定でプレーンテキスト保存（秘匿不要なことが多いため）だが PrivacyLevel と CloudFallback は route に記録。
→ Association
Options: "Channel" -> Automatic ("public"|"private"|"local"、Automatic はプライバシーから解決), "Encrypt" -> False (at-rest 暗号化は未実装。True 渡しは Status NotImplemented を返す), "DryRun" -> False, "RouteId" -> Automatic

### SourceVaultSearchPromptRoutes[query_String, opts] → List
保存済み PromptRoute のうち prompt 例または memo が query を部分文字列として含むものを返す（部分一致、query "" は全件）。何も実行しない。
Options: "CreatedAt" -> <|"From"->_,"To"->_|> (定義日で絞り込み), "UpdatedAt" -> <|"From"->_,"To"->_|> (最終更新日で絞り込み), "Channel" -> All|"public"|"private"|"local", "IncludeSeed" -> True

### SourceVaultFormatPromptRouteList[routes_List, opts] → Grid
保存済み PromptRoute を Grid で描画する（列: Prompt, Memo, Target, CreatedAt, UpdatedAt, Privacy）。各行に 3 ボタン: Preview（dry-run、実行せず実行内容を表示）、Run（今すぐ実行）、ToInput（保存された関数呼び出し式を新規 Input セルに書き込む）。プロンプトでリクエストされたプロンプトルートリストの既定表示形式。
Options: 表示関連