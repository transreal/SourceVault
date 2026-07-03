# SourceVault_wiring API リファレンス

パッケージ: `SourceVault`` (コンテキスト: `SourceVault`WiringPrivate`` に実装)
ロード: `SourceVault.wl` が自動ロード (aux、contracts の後)。
仕様書: `sourcevault_function_contract_wiring_spec_v0_3.md`
役割: typed binding (URI/Value envelope・PortBindingRef) と関数合成層。関数選定 → 決定的束縛 (曖昧は推測しない) → LLM は残余のみ → propose/validate/execute 三層。NB 初段・最終段と WorkflowInputBlock 起動シーケンス (起動も式評価に一本化)。

## URI envelope / ValueEnvelope (typed handle)

URI envelope 正準形: `<|"Status"->"OK", "URI"->"sv://artifact/...", "ObjectKind", "DomainKind", "MediaKind", "PrivacyLevel", "Marked"|>`。本文は持たない (中身は resolve で取得)。

### SourceVaultURIEnvelopeQ[x] → True|False
### SourceVaultNormalizeURIEnvelope[x]
envelope / `"sv://..."` 文字列を正準 envelope に正規化。PrivacyLevel 欠落は 0.85 (fail-closed)。
→ Association | Failure["InvalidURIEnvelope"]

### SourceVaultMakeValueEnvelope[value, opts]
値を privacy label 付き ValueEnvelope に包む (Value 入力を 0 扱いしない)。
→ Association `<|"PortType"->"Value", "Value", "WLType", "PrivacyLevel", "Source", "ContentHash"|>`
Options: `"Source"` -> "UserTyped" (PL 既定 0.) | "NotebookCell" | "VariableSnapshot" | "FileContent" | "StepOutput" (以上 PL 既定 0.85), `"PrivacyLevel"` -> Automatic | 数値

### SourceVaultValueEnvelopeQ[x] → True|False

## PortBindingRef (セル / 変数 / ファイル / URI の同一性つき束縛)

正規形: `<|"ObjectClass"->"SourceVaultPortBindingRef", "BindingKind", "URI", "SnapshotPolicy", "Identity", "Preview", "PrivacyLevel", "Provenance"|>`。

### SourceVaultPortBindingRefQ[x] → True|False

### SourceVaultBindingFromURI[uriOrEnvelope]
BindingKind->"URI" (PinnedSnapshot)。
→ Association | Failure

### SourceVaultBindingFromValue[value, opts]
BindingKind->"LiteralValue" (ValueEnvelope 内包、Preview 付き)。
→ Association
Options: SourceVaultMakeValueEnvelope と同じ

### SourceVaultBindingFromVariable[symbolName, opts]
変数から。**既定 SnapshotNow: その時点の値を snapshot artifact 化し URI が正** (変数名は kernel session 依存で危険)。名前の遅延解決は `"SnapshotPolicy"->"LiveAtExecution"` 明示時のみ (URI なし)。
→ Association | Failure["UnresolvedBinding"]
Options: `"SnapshotPolicy"` -> "SnapshotNow", `"PrivacyLevel"` -> Automatic (0.85)

### SourceVaultBindingFromFile[path, opts]
ファイルから。素のファイル名は NotebookDirectory 基準で解決。
→ Association | Failure["UnresolvedBinding"]
Options: `"Mode"` -> "ReferenceOnly" (既定、path identity のみ・URI なし) | "HashOnly" (+content hash) | "CopyToArtifact" (内容を blob 化し `sv://hash/sha256/...`), `"PrivacyLevel"` -> Automatic (0.85)

## URI coercion / port adapter

### SourceVaultCoerceToURI[x, opts]
値 / ValueEnvelope / PortBindingRef / URI を URI envelope へ。生値は ArtifactType "WiringValue" の DerivedArtifact として deposit。envelope/URI には冪等。
→ URI envelope | Failure
Options: `"Source"` -> "UserTyped", `"PrivacyLevel"` -> Automatic

### SourceVaultCoerceFromURI[envelopeOrUri, opts]
URI を解決して値を返す。**ToExpression 解釈は自前 deposit (WiringValue) のみ**、他 artifact は Text のまま (コード実行防止)。
→ Association `<|"Status", "Value"|"Text"|"Bytes", "MediaKind", "PrivacyLevel"|>` | Failure
Options: `"Interpret"` -> Automatic | False

### SourceVaultRegisterPortAdapter[from, to, f, meta]
port adapter 登録。from/to は PortType ラベル ("Value"/"URI"/"FileRef"/"VariableRef" 等)。meta: `<|"Cost"->1, "Lossy"->False|>`。組み込み 5 本 (Value/VariableRef/FileRef/LiteralValue -> URI、URI -> Value)。
→ Association

### SourceVaultPortAdapters[] → List

### SourceVaultFindAdapterPath[from, to, opts]
cost 付き経路探索。**経路が複数なら Failure["AmbiguousAdapterPath"] (推測しない)**、無ければ Failure["NoAdapterPath"]。
→ Association `<|"Status", "Path", "Cost"|>` | Failure
Options: `"AdapterPolicy"` -> `<|"MaxDepth"->2, "MaxCost"->3, "AllowLossy"->False, "RequireUniquePath"->True|>`

### SourceVaultApplyAdapterPath[pathResult, input]
経路を順に適用。
→ 変換結果

## privacy / confidential 伝搬

### SourceVaultBindingPrivacyMax[bindings]
envelope/ValueEnvelope/PortBindingRef リストの PrivacyLevel の Max (判定不能は 0.85 fail-closed)。
→ Real

### SourceVaultConfidentialContextQ[nb]
現在の評価文脈の confidential 判定表: ①評価セルが機密 (NBCellPrivacyLevel > 0.5) -> True (必ず伝搬) ②非機密セル + notebook CloudPublishable=True -> False ③CloudPublishable=False -> True (セル問わず伝搬) ④どちらも未設定 -> False。CloudPublishable は live TaggingRules 優先 -> ファイル宣言 fallback。
→ True|False

### $SourceVaultConfidentialPrivacyLevel
型: Real, 既定 1.0
confidential 伝搬時に deposit へ適用する PrivacyLevel 下限。True のとき、ワークフローが SourceVault へ格納する全出力 (step 出力 WiringValue / InputBundle / blob) は PL >= この値 + `IngestProvenance.ConfidentialDependent->True` の秘密依存データになる。

## 関数選定 / wiring planner (propose - validate - execute)

### SourceVaultSelectFunctionsForTask[task, opts]
task (文字列 | TaskSpec) に適合する契約付き関数を決定的に選定 (lexical scoring: シンボル名 / CapabilityTags / IntentExamples bigram + RecommendedEntrypoint/UserFacing boost)。Internal は既定除外。NegativeExamples/DoNotUseWhen 一致は **Rejected (理由付き)**。閾値未満は候補 0 件を許す。LLM に渡す場合は Candidates 内 enum 選択のみ。
→ Association `<|"Candidates", "Rejected", "Clarifications"|>`
Options: `"IncludeInternal"` -> False, `"MinScore"` -> 1.

### SourceVaultProposeWiringPlan[taskSpec, opts]
TaskSpec `<|"Task", "Inputs"->{PortBindingRef(+"Name")..}, "Steps"->{symbol..}|Automatic, "WiringMode"->"Hybrid"(既定)|"Deterministic"|>` から WiringPlan (純データ・未実行) を作る。束縛は決定的 5 規則 (①ポート名一致 ②DomainKind ③MediaKind ④WLType 一意 ⑤adapter 一意経路) を優先順適用、**曖昧 (複数候補) は Unresolved に積む**。Hybrid では Ambiguous 残余のみ LLM が候補 enum から選択 (validate-then-accept、本文は LLM に渡さない)。PrivacyEstimate は使用 binding の Max + PrivacyFloor。
→ WiringPlan `<|"Status"->"OK"|"Incomplete", "Steps", "Unresolved", "PrivacyEstimate", "Mode", "Warnings"|>`

### SourceVaultValidateWiringPlan[plan]
各 step の生成式を SourceVaultValidateCallExpression に通し、InitPlan 解決可能性も検査。
→ Association `<|"Status"->"OK"|"Incomplete"|"Failed", "Failures"|>`

### SourceVaultWiringPlanExpression[plan]
plan 全体を未評価 WL 式 (EnsureInitialized 前置き + step 列) に整形。ClaudeEval / Runtime の提案式に使う (実行入口を作らない)。
→ Association `<|"Code"->String, "HeldExpr"->HoldComplete[...]|>`

### SourceVaultExecuteWiringPlan[plan, opts]
manual / tests / 承認済み workflow 用の実行層。required 未充足は実行せず `<|"Status"->"AwaitingInput", "InputBlockSpec"|>` を返すだけで **notebook には触らない**。各 step: EnsureInitialized -> 束縛値解決 -> 実行 -> 契約が URI 宣言の生値出力は自動で URI envelope 化。Effects (NotebookWrite/FileWrite/Network/LLMCall) step は既定拒否。
→ Association `<|"Status", "StepResults", "Result"|>` | Failure
Options: `"OnMissingInput"` -> "Return", `"AllowEffects"` -> False

### $SourceVaultWiringLLM
型: None | Function (prompt_String -> response_String)
LLM wiring エンジン。None なら ClaudeQuerySync を PrivacyLevel 1.0 (ローカルモデル強制) で弱結合利用。

### SourceVaultFillUnresolvedWithLLM[plan]
Ambiguous 残余の LLM 充填 (ProposeWiringPlan Hybrid が自動適用)。候補外選択・不正 JSON は破棄して Warnings に記録。
→ WiringPlan

## NB 境界 (初段 / 最終段)

### SourceVaultCellInput[nb, opts]
選択セル (無ければ**評価セルの直前のセル**) を NotebookCellRef の PortBindingRef 列に。SnapshotNow でセル本文を artifact 化、cell UUID + content hash + notebook ref を Identity に。PL 既定 0.85。claudecode hook `$ClaudeCellInputProvider` に自動配線。
→ List | Failure["NoFrontEnd"|"NoCellsSelected"]
Options: `"Cells"` -> Automatic, `"PrivacyLevel"` -> Automatic

### SourceVaultCellOutput[x, nb, opts]
URI envelope / ExecuteWiringPlan 結果 / 生値を MediaKind 別に NB へ書き出す (Text は ClaudeWriteResponse 優先、Image は画像セル、他は要約+URI)。hook `$ClaudeCellOutputProvider` に自動配線。
→ Association `<|"Status", "Written"|>`

## workflow 起動シーケンス (WorkflowInputBlock)

### SourceVaultRegisterWiringWorkflow[name, taskSpec]
名前付き workflow を登録。**registry はカーネルセッション内 (in-memory)** — 再起動後は再登録が必要。
→ Association

### SourceVaultRunWorkflow[nameOrSpecOrPlan, opts]
notebook-facing 起動関数 (起動式自体が式提案の対象)。propose -> validate -> 充足なら実行。未充足なら WorkflowInputBlock (header + **連想引数つき Submit テンプレート式 1 セル**) を挿入し `<|"Status"->"AwaitingInput", "InputBlockId"|>`。再評価 idempotency: 同一 schema の未提出 (Draft) block は再利用 (`"Reused"->True`)、schema 変更で旧 block は Superseded。**Submitted 済み block は再利用しない** (新規挿入)。confidential 判定 (SourceVaultConfidentialContextQ) が True なら全 deposit を秘密依存化し結果に `"Confidential"->True`。
→ Association | Failure["UnknownWorkflow" (Registered 一覧 + Hint 同梱)]
Options: `"OnMissingInput"` -> "InsertWorkflowInputBlock" | "Return", `"AllowEffects"` -> True, `"Notebook"` -> Automatic, `"Confidential"` -> Automatic | True | False

### SourceVaultSubmitWorkflowInput[inputBlockId, inputs]
入力を連想 `<|"port" -> value, ...|>` で与えて再開 (Collect -> Validate -> **検証 green 後にのみ InputBundle 化** -> 実行)。value は生値 / `"sv://..."` / PortBindingRef、`""` と Missing は未記入。連想なし呼びは旧式の入力セル記入方式 (後方互換)。成功時 block を Submitted にし結果に `"InputBundle"->URI`。
→ Association | Failure
Options: `"Notebook"` -> Automatic, `"AllowEffects"` -> True, `"Confidential"` -> Automatic

### SourceVaultCollectWorkflowInput[nb, inputBlockId]
block のセル群 -> InputDraft (未検証、永続化しない)。
→ Association | Failure

### SourceVaultValidateWorkflowInput[inputDraft, plan]
draft を元 TaskSpec に注入して決定的に再 propose + 検証。green なら `"ResolvedPlan"` を含む。
→ Association

### SourceVaultCreateInputBundle[inputDraft, plan]
検証済み draft を不変 InputBundle として deposit。**`BundleKind->"WorkflowInput"` subtype 必須** (EvidenceBundle と混同させない)。PL は draft bindings の Max (confidential 文脈では floor 適用)。
→ URI envelope (+`"InputBundleRecord"`) | Failure
