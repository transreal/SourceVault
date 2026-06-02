# api_promptrouter.md

SourceVault` コンテキストの拡張パッケージ。独立パッケージではなく `SourceVault.wl` のブートストラップから `Get[]` でロードされる。`ClaudeRuntime` / `ClaudeOrchestrator` には hard-depend せず、公開シンボル名のみで実行時に可用性を検出する（rule 11）。これらが不在でもロードは成功し、ロードは冪等。

PromptRouter はプロンプトをルート（FunctionRoute / IntentRoute / TabularQuery / WorkflowRoute）へ解決・実行・記録する。PromptRun は実行履歴で append-only JSONL（`<PrivateVault>/promptrouter/runs/prompt-runs.jsonl`）に保存され、コンパイル済みレジストリには書かれない。PromptRoute は永続レジストリ（prompt-route-registry）に保存される。

## バージョン / ステータス

### $SourceVaultPromptRouterVersion
型: String
PromptRouter 拡張のバージョン文字列。

### SourceVaultPromptRouterStatus[] → Association
拡張の状態を返す。バージョン、実装フェーズ、claudecode / SourceVault / ClaudeRuntime / ClaudeOrchestrator の可用性、自動 ClaudeEval ディスパッチが有効かを含む。

### SourceVaultPromptRouterAvailableQ[] → True|False
拡張が SourceVault` コンテキストにロード済みなら True。ClaudeRuntime / ClaudeOrchestrator の存在は含意しない。

### SourceVaultPromptRouterActiveQ[caller] → True|False
指定 caller のリクエストを PromptRouter が処理すべきなら True。
caller: "Manual" | "ClaudeEval" | Automatic（既定 Automatic、"ClaudeEval" として扱う）。Manual API はロード済みなら常に有効。自動 ClaudeEval ディスパッチは ClaudeOrchestrator もロード済みのときのみ有効。

## ルート解決 / 実行 / 説明

### SourceVaultResolvePromptRoute[prompt, opts]
プロンプトを実行せずルート決定 Association に解決する（dry-run）。決定 Status と Decision を含む。決定的マッチに失敗すると Order 4 の字句検索（KeywordsAny の転置インデックス + シノニムマップ）にフォールバックし、Decision は単一高スコアなら "LexicalMatch"、複数候補なら "LexicalCandidates"。
→ Association
Options: "DryRun" -> False, "AllowLLMRouter" -> Automatic, "AllowWorkflow" -> Automatic, "PrivacyLevel" -> Automatic, "StorePrompt" -> "HashOnly", "FallbackToClaudeEval" -> True, "Caller" -> Automatic

### SourceVaultExecutePromptRoute[prompt, opts]
ルートを解決・実行する: resolve → adapter → allowlist チェック → dispatch（ReadOnly callable のみ）→ PromptRun 記録。手動 / テスト / 診断用 API で評価を行う。
→ Association（ディスパッチ不可時 <|"Status" -> "NotDispatched", ...|>）
Options: SourceVaultResolvePromptRoute と同じ

### SourceVaultRouteExplain[prompt, opts] → String|Association
プロンプトがどう routing されるかの人間可読な説明を返す。

### SourceVaultProposePromptRoute[prompt_String, opts]
ClaudeEval 向け API（spec v11 5.3）。schedule プロンプトを UNEVALUATED な提案式 `HoldComplete[SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]]` に解決し、それを "ProposedExpression" に格納した PromptRouteProposal Association を返す。式は決して評価しない。非 schedule プロンプトは Status NotDispatched。
→ Association
プロンプトの日付スパン（「今日+3日」「今月」）は Period オプションに、その他の絞り込み（「未完了 todo」「今週締切」）は FilterSpec リテラル Association（spec 5.4.3 の閉じた DSL: Kind And/Or/Not/Field, whitelisted Op, スキーマフィールド名のみ）になる。

## PromptRun 履歴

### SourceVaultPromptRunRecord[prompt, routeDecision, result, opts]
PromptRun レコードを append-only JSONL ストアに追記する。生プロンプトは既定で保存されず hash のみ。
→ <|"Status" -> "OK"|"DryRun"|"Skipped"|"Failed", "RunId" -> ..., "Record" -> ...|>
Options: "StorePrompt" -> "HashOnly" ("PrivateRaw"|"Off" も可), "PrivacyLevel" -> 0.0, "PrivacyOrigin" -> {}, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "Dependencies" -> <||>, "ModelResolution" -> <||>, "DryRun" -> False

### SourceVaultPromptRunHistory[opts] → List
PromptRun レコードを新しい順で返す。
Options: "MaxResults" -> Automatic, "RouteId" -> Automatic, "Decision" -> Automatic, "Since" -> Automatic (ISO date-time 文字列、Timestamp >= Since を残す)

### SourceVaultCaptureLastPromptRun[opts]
履歴中の最新 PromptRun を返す。
→ <|"Status" -> "OK", "PromptRun" -> ...|>（履歴空なら Status "NoPromptRun"）
Options: なし

### SourceVaultPromotePromptRun[runId_String, opts]
記録済み PromptRun を分類（spec 10.3）し、決定的ルートヒットなら run の fingerprint と raw 例でそのルートの Matcher を強化する。分類: 決定的マッチ → "PromptExample"（昇格対象）、Orchestrator trace → "WorkflowRouteDraft"（分類のみ）、LLM 一発/ルート無し → "NeedsReview"。昇格書き込みは Order 5a レジストリ API 経由で DryRun が既定。
→ Association
Options: "DryRun" -> True (rule 103), "Confirm" -> False, "Channel" -> "public"

## Callable allowlist

### SourceVaultCallableAllowlistRegistry[] → Association
SourceVault 所有の callable allowlist。FunctionId をキーに、raw Symbol / UseAsFunctionRoute / UseAsHandlerRef / SideEffectClass / OwnerPackage を持つ。生 Symbol を含むため JSON レジストリには絶対書かない。登録済み: SourceVaultUpcomingSchedule (ReadOnly), SourceVaultFindNotebooks (ReadOnly), SourceVaultNewNotebook (SafeCreate)。ReviewQueue / OpenTodoList は登録せず semantic IntentId として扱う（adapter は SourceVaultFindNotebooks を target）。引数を取ると Status Failed。

### SourceVaultCallableAllowlistView[] → Association
SourceVault 所有 allowlist と、ClaudeOrchestrator ロード時はその handler allowlist（weak call で取得）をマージした論理ビュー。FunctionRoute dispatch と HandlerRef 解決が参照。キー衝突時は SourceVault 所有エントリが優先。

## PromptRoute レジストリ（読み書き）

### SourceVaultRegisterPromptRoute[route_Association, opts]
PromptRoute をコンパイル済み prompt-route-registry に追加 / 置換する。DryRun -> True（既定、rule 103）は計画した topic / RouteId / action を報告し書き込まない。DryRun -> False は atomic write（encode → verify → tmp → rename）。
→ WrittenCount / SkippedCount / ByAction / Topic / Channel / Path 集計の Association
Options: "DryRun" -> True, "Channel" -> "public"（他オプションはチャネル / topic 解決）

### SourceVaultListPromptRoutes[opts] → List
チャネルの PromptRoute を返す。
Options: "Channel" -> "public", "IncludeSeed" -> True（レジストリに無い RouteId のみ組み込み seed ルートを追記）

### SourceVaultGetPromptRoute[routeId_String, opts] → Association
指定 RouteId の PromptRoute を返す。無ければ Status "NotFound"。
Options: "Channel" -> "public"

## プライバシー / モデル解決

### SourceVaultResolvePromptPrivacy[components_Association, opts]
プロンプトのプライバシー寄与を単一 PrivacyLevel（全コンポーネントの Max、spec 11.2）に統合し、AllowedTrustDomains / CloudFallback / CloudRouterAllowed メタデータを付与する。SecretCell または PrivateModelExecution が True なら level を最低 0.75 に引き上げ、AllowedTrustDomains を {"Local","Private"} に、CloudFallback を "Deny" に制限する。
→ Association ("Type" -> "PromptPrivacyResolution", "PrivacyLevel", "PrivacyOrigin", "AllowedTrustDomains", "CloudFallback", "RawPromptStored", "PromptStorageClass", "CloudRouterAllowed", "RouterVersion")
Options: なし
コンポーネントキー: "PromptCellPrivacyLevel", "PromptTextPrivacyLevel", "NotebookDependencyPrivacyLevel", "ModelExecutionPrivacyFloor", "ResultPrivacyLevel", "UserSpecifiedPrivacyLevel"（数値、欠落は 0.0）, "SecretCell" -> False, "PrivateModelExecution" -> False

### SourceVaultPromptPrivacyAllowsCloudRouter[level] → True|False
PrivacyLevel が 0.5 の cloud-send 境界未満のときのみ True（spec 11.5）。引数は数値 level または privacy-resolution Association。非数値入力は unsafe 扱いで False。

### SourceVaultResolveModelForPromptRouter[query_Association, opts]
モデルリゾルバ契約層（spec 12）。query を ModelIntent / WeightClass / PrivacyLevel / AllowedTrustDomains / CloudFallback / RequiredCapabilities / DegradationPolicy 契約に正規化し、ホストリゾルバ `SourceVault`SourceVaultResolve["Model", query]`（存在時のみ weak-call）へ委譲する。リゾルバ不在 / 結果が空・分類不能なら "NeedsModelClassification"。PrivacyLevel >= 0.5 で Local/Private 確認できないモデルは cloud fallback せず "NeedsPrivateModel"。
→ Association（Requested / Resolved / FallbackKind / CloudFallbackUsed 形状を反映）
Options: なし
query は String の "ModelIntent" 必須（無いと Status Failed / MissingModelIntent）。既定値: "ModelIntent" -> "router", "WeightClass" -> Automatic, "PrivacyLevel" -> 0.0, "AllowedTrustDomains" -> Automatic, "CloudFallback" -> "Ask", "RequiredCapabilities" -> {"TextIn","TextOut"}, "DegradationPolicy" -> "Flexible"

### SourceVaultClassifyProviderTrustDomain[label] → String|Missing
provider / route ラベルを TrustDomain にマップ（spec 12.2）。"chatgptcodex"/"ChatGPTCodexCLI"/"ClaudeCodeCLI"/"CloudLLM"/"anthropic"/"openai" → "Cloud"、"LocalOnly"/"local" → "Local"、"PrivateLLM"/"private" → "Private"。曖昧 / 未知ラベルは `Missing["UnclassifiedTrustDomain"]`（ホストリゾルバが TrustDomain を明示する必要あり）。ChatGPT Codex は cloud-backed CLI（sandbox はローカルだが推論はクラウド）。

## 再処理プラン

### SourceVaultPromptReprocessPlan[opts]
PromptRoute レジストリを走査し stale ルート（SchemaVersion / CompiledRegistryVersion 不一致、または StaleRouteIds に指名されたもの）を検出し read-only な再処理プランを返す（spec 14.2/14.3）。実際の再処理はしない。分類: ReadOnly FunctionRoute → "AutoRecomputable"、Intent / TabularQuery ルート → "OnDemandRefresh"、WorkflowRoute → "NeedsApproval"。
→ Association
Options: "StaleRouteIds" -> {}, "Channel" -> "public"

## 保存プロンプト（UI scope）

### SaveLastPrompt[memo_String, opts]
直近の成功した ClaudeEval / ContinueEval プロンプト実行を名前付き PromptRoute として保存し、後で検索・再実行できるようにする。memo は自由テキストのメモで route の Memo フィールドに格納されプロンプト表に表示される。プライバシーは SourceVaultResolvePromptPrivacy で追跡。生プロンプト / 関数は既定で平文保存（PrivacyLevel と CloudFallback は route に記録）。
→ Association
Options: "Channel" -> Automatic ("public"|"private"|"local"、プライバシーから解決), "Encrypt" -> False (at-rest 暗号化は未実装、True 渡しは Status NotImplemented を返す), "DryRun" -> False, "RouteId" -> Automatic

### SourceVaultSearchPromptRoutes[query_String, opts] → List
prompt 例または memo に query を部分一致で含む保存済み PromptRoute を返す（SourceVaultFindNotebooks Keywords と同様）。query "" は全件マッチ。何も実行しない。
Options: "CreatedAt" -> <|"From"->_,"To"->_|>（定義日でフィルタ）, "UpdatedAt" -> <|"From"->_,"To"->_|>（最終更新日でフィルタ、notebook query API と同じ date-range 形式）, "Channel" -> All|"public"|"private"|"local", "IncludeSeed" -> True

### SourceVaultFormatPromptRouteList[routes_List, opts]
保存済み PromptRoute を Grid（列: Prompt, Memo, Target, CreatedAt, UpdatedAt, Privacy）で描画する。各行に 3 つのアクションボタン: Preview（dry-run、実行せず何が走るか表示）, Run（今すぐ route 実行）, ToInput（保存された関数呼び出し式を新規 Input セルに書き込む）。SourceVaultFormatNotebookList をミラー。プロンプトで要求された prompt-route リストの既定表示形式。
→ Grid

## 関連パッケージ
[SourceVault](https://github.com/transreal/SourceVault) のコンテキスト拡張。実行時に [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime) / [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator) / [claudecode](https://github.com/transreal/claudecode) の可用性を検出するが依存はしない。