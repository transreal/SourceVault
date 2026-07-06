## 概要

`SourceVault_wiring` は typed binding / URI coercion / port adapter 層を提供する。仕様書 `sourcevault_function_contract_wiring_spec_v0_3.md` の §4.3〜§7.4 に対応する。ロードは `Block[{$CharacterEncoding -> "UTF-8"}, Get["SourceVault_wiring.wl"]]`。

設計原則:
- W3: 参照渡しの正準形は typed handle。本文は envelope に持たない。
- W5: privacy は Max 伝搬で事前見積し、egress gate は別層で必ず再評価する。
- VariableRef の正は「その時点の値 snapshot URI」。名前の live 解決は明示時のみ。
- FileRef の既定は path identity のみ。本文は `"Mode"->"CopyToArtifact"` 明示時のみ読む。
- `SourceVaultCoerceFromURI` の `ToExpression` 解釈は自前 deposit (`ArtifactType->"WiringValue"`) のみ。他 artifact は Text のまま返しコード実行を防止する。

非衝突方針: private helper は `SourceVault\`WiringPrivate\`` 文脈に置く。

## URI envelope (§4.3)

### SourceVaultURIEnvelopeQ[x] → True|False
x が URI envelope (`Status`/`URI`/`PrivacyLevel` 必須) か判定する。

### SourceVaultNormalizeURIEnvelope[x] → Association|Failure
URI envelope または `"sv://..."` 文字列を正準 envelope に正規化する。`PrivacyLevel` 欠落は既定 0.85 (fail-closed)。本文は含めない。解釈不能は `Failure["InvalidURIEnvelope", ...]`。

## ValueEnvelope (§4.4)

### SourceVaultValueEnvelopeQ[x] → True|False
x が ValueEnvelope (`PortType->"Value"` + `PrivacyLevel`) か判定する。

### SourceVaultMakeValueEnvelope[value, opts]
値を privacy label 付き ValueEnvelope に包む。
→ Association (`PortType->"Value"`, `Value`, `WLType`, `PrivacyLevel`, `Source`, `ContentHash`)
Options: "Source" -> "UserTyped" (既定) | "VariableSnapshot" | "FileContent" | "StepOutput" | "NotebookCell", "PrivacyLevel" -> Automatic (Source 別既定: UserTyped=0.0、他は 0.85 fail-closed)

## PortBindingRef (§4.5)

### SourceVaultPortBindingRefQ[x] → True|False
x が PortBindingRef (`ObjectClass->"SourceVaultPortBindingRef"`) か判定する。

### SourceVaultBindingFromURI[uriOrEnvelope] → PortBindingRef|Failure
URI/envelope から `BindingKind->"URI"` の PortBindingRef を作る (`SnapshotPolicy->"PinnedSnapshot"`)。

### SourceVaultBindingFromValue[value, opts]
literal 値から `BindingKind->"LiteralValue"` の PortBindingRef を作る (ValueEnvelope を内包)。
→ PortBindingRef
Options: SourceVaultMakeValueEnvelope と同じ ("Source", "PrivacyLevel")

### SourceVaultBindingFromVariable[symbolName, opts]
変数から PortBindingRef を作る。既定 `"SnapshotNow"` は現在値を snapshot artifact 化し URI を正とする (変数名は kernel session と時刻に依存し危険なため)。シンボル未解決は `Failure["UnresolvedBinding", ...]`。
→ PortBindingRef|Failure
Options: "SnapshotPolicy" -> "SnapshotNow" (既定、値を deposit し URI 付与) | "LiveAtExecution" (明示時のみ、名前の遅延解決・URI なし), "PrivacyLevel" -> Automatic (=0.85 fail-closed)

### SourceVaultBindingFromFile[path, opts]
ファイルから PortBindingRef を作る。ファイル名のみの指定は `NotebookDirectory[]` 基準で解決する。存在しなければ `Failure["UnresolvedBinding", ...]`。
→ PortBindingRef|Failure
Options: "Mode" -> "ReferenceOnly" (既定、path identity のみ・本文は読まない) | "HashOnly" (+content hash) | "CopyToArtifact" (内容を snapshot artifact 化し URI 付与)、"PrivacyLevel" -> Automatic (=0.85、CopyToArtifact/HashOnly 時の内容 privacy)

## 型変換 / Coercion (§6.3)

### SourceVaultCoerceToURI[x, opts]
値/ValueEnvelope/PortBindingRef/URI を URI envelope へ正規化する。生値・ValueEnvelope は `ArtifactType->"WiringValue"` の DerivedArtifact として deposit (InputForm text) される。既に URI/envelope なら正規化のみ (冪等)。PortBindingRef が URI を持たず deposit 不能な場合は `Failure["UnresolvedBinding", ...]`。
→ URI envelope | Failure
Options: "Source" -> "UserTyped", "PrivacyLevel" -> Automatic

### SourceVaultCoerceFromURI[envelopeOrUri, opts]
URI を解決して値を返す。自前 deposit (`ArtifactType->"WiringValue"`) のみ `ToExpression` で WL 値に解釈し、それ以外の artifact は Text のまま返す (コード実行防止)。resolve 未対応/失敗は `Failure["ResolveUnavailable"|"ResolveFailed", ...]`。
→ `<|"Status"->"OK", "Value"|"Text"->_, "Bytes"->_(Text時のみ), "MediaKind"->_, "PrivacyLevel"->_|>` | Failure
Options: "Interpret" -> Automatic (既定、WiringValue のみ解釈) | False (常に Text)

例: `SourceVaultCoerceFromURI["sv://artifact/123", "Interpret" -> False]["Text"]`

## Port Adapter レジストリ (§6.3)

### SourceVaultRegisterPortAdapter[from, to, f, meta] → `<|"Status"->"OK", "Edge"->"from->to"|>`
from->to の port adapter を登録する。from/to は PortType ラベル文字列 (`"Value"`/`"URI"`/`"FileRef"`/`"VariableRef"` 等)。meta は `<|"Cost"->1, "Lossy"->False|>` (既定)。f は 1 引数関数。組み込み adapter として `Value<->URI`, `VariableRef->URI` (Cost 1), `FileRef->URI` (Cost 2), `LiteralValue->URI` (Cost 1) が既定登録済み。

### SourceVaultPortAdapters[] → {Association...}
登録済み adapter 一覧を返す。

### SourceVaultFindAdapterPath[from, to, opts]
adapter 経路を cost 付きで探索する (深さ・cost 上限、ノード再訪なし)。一意経路は Status OK、複数候補は `Failure["AmbiguousAdapterPath", ...]` (候補列挙)、無ければ `Failure["NoAdapterPath", ...]`。同一 from/to は空経路・Cost 0 の OK。
→ `<|"Status"->"OK", "Path"->{edge...}, "Cost"->n|>` | Failure
Options: "AdapterPolicy" -> Automatic (既定 `<|"MaxDepth"->2, "MaxCost"->3, "AllowLossy"->False, "RequireUniquePath"->True|>`)

### SourceVaultApplyAdapterPath[pathResult, input] → Any|Failure
FindAdapterPath の経路を順に適用する。

## Privacy Max 伝搬 (§6.6 binding 部分)

### SourceVaultBindingPrivacyMax[bindings] → Real
envelope/ValueEnvelope/PortBindingRef のリストから `PrivacyLevel` の Max を返す (Max 伝搬)。判定不能要素は 0.85 (fail-closed)。空リストは 0.。

## 関数選定 (§6.2)

### SourceVaultSelectFunctionsForTask[task, opts]
task (文字列または TaskSpec) に適合する契約付き関数を決定的に選定する。v1 の scoring は lexical (シンボル名一致/CapabilityTags/IntentExamples の文字 bigram 重なり) + RecommendedEntrypoint/UserFacing boost。`AbstractionLevel->"Internal"` は既定除外。`NegativeExamples`/`DoNotUseWhen` 一致は Rejected (理由付き=負の情報)。閾値未満は候補 0 件を許す。契約が未ロードなら `Failure["ContractsUnavailable", ...]`。
→ `<|"Candidates"->{<|"Symbol","Score","Reasons"|>...}, "Rejected"->{<|"Symbol","Reason"|>...}, "Clarifications"->{...}|>` | Failure
Options: "IncludeInternal" -> False, "MinScore" -> 1.

LLM に渡す場合は Candidates 内からの enum 選択のみに限定する (W4)。

## Wiring Planner (§6.4 / §6.7)

### SourceVaultProposeWiringPlan[taskSpec, opts] → WiringPlan
TaskSpec から WiringPlan (純データ・未実行) を作る。
taskSpec: `<|"Task"->_, "Inputs"->{PortBindingRef(+"Name")..}, "Steps"->{symbol..}|Automatic, "WiringMode"->"Hybrid"(既定)|"Deterministic"|>`
束縛は決定的規則を優先順に適用する (§6.4): ①ポート名一致 ②DomainKind ③MediaKind ④WLType 一意 ⑤adapter 一意経路。曖昧 (複数候補) は推測せず Unresolved に積む。`Steps->Automatic` は `SourceVaultSelectFunctionsForTask` の最上位候補を使う。`"WiringMode"->"Hybrid"` (既定) は Unresolved (Ambiguous) が残る場合 `SourceVaultFillUnresolvedWithLLM` を自動適用する。契約未ロードは `Failure["ContractsUnavailable", ...]`。
戻り値 WiringPlan: `<|"Status"->"OK"|"Incomplete", "Task", "TaskSpec", "Steps", "Unresolved", "PrivacyEstimate"-><|"PrivacyLevel","Confidence"|>, "Mode", "Warnings"|>`

### SourceVaultValidateWiringPlan[plan] → `<|"Status"->"OK"|"Incomplete"|"Failed", "Failures"->{...}|>`
WiringPlan を検証する: 各 step の生成式が `SourceVaultValidateCallExpression` を通るか、`SourceVaultInitPlan` が解決可能か、Unresolved が無いか。

### SourceVaultWiringPlanExpression[plan] → `<|"Code"->_String, "HeldExpr"->HoldComplete[...]|>`
plan 全体を未評価 WL 式に整形する。`EnsureInitialized` 前置き + step 列。ClaudeEval / Runtime の提案式としてそのまま流せる。

## LLM Wiring (§6.5, Hybrid の残余埋め)

### $SourceVaultWiringLLM
型: `None | (String -> String)`, 初期値: `None`
LLM wiring のエンジン (`prompt_String -> response_String`)。None (既定) のときは `ClaudeCode\`ClaudeQuerySync` を `PrivacyLevel->1.0` (ローカルモデル) で弱結合利用する。テストでは mock 関数を設定する。

### SourceVaultFillUnresolvedWithLLM[plan, opts] → WiringPlan
WiringPlan の Unresolved (Ambiguous のみ) を LLM で埋める。LLM には候補の identity (`From`/`Kind`/`DomainKind`/`Preview`、Redacted は除外) のみを渡し、データ本文は渡さない。出力は固定 JSON schema (候補 `From` からの enum 選択のみ)。validate-then-accept: 候補外の選択・不正 JSON は破棄して Unresolved のまま (`Warnings` に記録)。採用 binding は `FilledBy->"LLM"`。エンジン未設定時は Unresolved が残る場合のみ `Warnings` に `"LLMEngineUnavailable"` を追加して plan をそのまま返す。`SourceVaultProposeWiringPlan` は TaskSpec `"WiringMode"->"Hybrid"` (既定) でこれを自動適用する (`"Deterministic"` 指定で無効)。

## Confidential 伝搬

### $SourceVaultConfidentialPrivacyLevel
型: Real, 初期値: 1.0
confidential 伝搬時に deposit へ適用する `PrivacyLevel` 下限 (`NBMarkCellConfidential` の既定と同じ、クラウド禁止)。

### SourceVaultConfidentialContextQ[nb] → True|False
現在の評価文脈が confidential か判定する。判定表 (優先順):
1. 評価セルが confidential (`NBCellPrivacyLevel` > 0.5) → True (必ず伝搬)
2. 非機密セル かつ notebook が `CloudPublishable->True` → False
3. notebook が `CloudPublishable->False` (クラウド公開不可) → True (セルに関わらず伝搬)
4. どちらも未設定 → False

`RunWorkflow` / `SubmitWorkflowInput` が `"Confidential"->Automatic` のとき使う。True のとき、ワークフローが SourceVault に格納する全出力 (step 出力の WiringValue / InputBundle) は `PrivacyLevel >= $SourceVaultConfidentialPrivacyLevel` の秘密依存データ (`Provenance` の `ConfidentialDependent->True`) として保存される。CloudPublishable の判定は live TaggingRules (`{TaggingRules, "SourceVault", "CloudPublishable"}`) を優先し、無ければファイル宣言 (`NBAccess\`NBGetCloudPublishable`) へ fallback する。

## Workflow 起動シーケンス (§7.4)

### SourceVaultRegisterWiringWorkflow[name, taskSpec] → Association
名前付き workflow (TaskSpec) を登録する。`SourceVaultRunWorkflow[name]` で起動できる。

### SourceVaultRunWorkflow[nameOrSpecOrPlan, opts]
notebook-facing の起動関数 (§7.4.1)。起動式自体が式提案の対象 (W9: 隠れ実行入口を作らない)。propose -> validate -> 実行の順で処理する。required input 未充足なら実行せず `WorkflowInputBlock` を notebook に挿入して `<|"Status"->"AwaitingInput", "InputBlockId"->...|>` を返す (FE 不在時は `InputBlockSpec` 返却に degrade)。再評価 idempotency: 同一 `PlanHash` の未提出 block があれば再利用し、schema 変更時は旧 block を Superseded にする。
→ `<|"Status"->"AwaitingInput"|..., ...|>`
Options: "OnMissingInput" -> "InsertWorkflowInputBlock" (既定) | "Return", "AllowEffects" -> True (既定、ユーザーが起動式を明示評価するため既定許可), "Notebook" -> Automatic

### SourceVaultCollectWorkflowInput[nb, inputBlockId] → InputDraft
`WorkflowInputBlock` のセル群を読み InputDraft (未検証の PortBindingRef 列) を返す。永続化しない。

### SourceVaultValidateWorkflowInput[inputDraft, plan] → `<|..., "ResolvedPlan"->_|>`
draft を plan に適用して再 propose し検証 report を返す。green でも永続化しない。

### SourceVaultCreateInputBundle[inputDraft, plan] → URI envelope (+"InputBundleRecord")
検証 green の draft を不変 InputBundle として deposit する。`BundleKind->"WorkflowInput"` subtype 必須 (EvidenceBundle と混同させない)。

### SourceVaultSubmitWorkflowInput[inputBlockId, `<|port -> value, ...|>`]
入力を連想で与えて Validate -> CreateInputBundle -> 実行の再開シーケンスを行う (§7.4.1 step 5-6)。挿入ブロックのテンプレート式の `""` を値に書き換えて評価するだけでよい (単一セル・WL の直観に合う形)。value は生値 / `"sv://..."` 文字列 / PortBindingRef。`""` と Missing は未記入扱い。検証 NG なら実行せず `Failures` を返す。成功時は block を Submitted にし InputBundle URI を紐づける。
`SourceVaultSubmitWorkflowInput[inputBlockId]` (連想なし) は旧式の入力セル記入方式 (後方互換)。

## NB 境界 (§7.1 / §7.2)

### SourceVaultCellInput[nb, opts]
選択セル (または `"Cells"->{CellObject..}`) を NotebookCellRef の PortBindingRef 列にする (§7.1 初段)。選択が無ければ評価セルの直前のセルを既定入力とする (上のセルを入力に、下で評価する自然な操作)。既定 SnapshotNow: セル本文を artifact 化し、cell UUID + content hash + notebook ref を Identity に持つ。PrivacyLevel 既定 0.85 (fail-closed、セルを 0 にしない)。FE 不在は `Failure["NoFrontEnd", ...]`。
→ `{PortBindingRef...}` | Failure

### SourceVaultCellOutput[x, nb, opts]
URI envelope / `ExecuteWiringPlan` 結果 / 生値を MediaKind 別にノートブックへ書き出す (§7.2 最終段)。Text は `ClaudeWriteResponse` (markdown 対応、弱結合) か `NBWriteText`、Image は画像セル、他は要約+URI リンク。ロード時に claudecode hook `$ClaudeCellInput`/`OutputProvider` へ弱結合登録される (§7.3)。
→ `<|"Status", "Written"|>`

### SourceVaultExecuteWiringPlan[plan, opts]
manual / tests / 承認済み workflow 用の実行層 (§6.7)。required input 未充足時の既定は `"OnMissingInput"->"Return"`: 実行せず `<|"Status"->"AwaitingInput", "InputBlockSpec"->...|>` を返し notebook には触らない (責務分離)。各 step: `EnsureInitialized` -> 束縛解決 -> 実行 -> 出力を契約に従い URI envelope 化。Effects (`NotebookWrite`/`FileWrite`/`Network`/`LLMCall`) を持つ step は既定拒否 (`"AllowEffects"->True` で許可、未許可は `Failure["EffectsApprovalRequired", ...]`)。契約未ロードの step は `Failure["UnresolvedBinding", ...]`。途中失敗は Failure + そこまでの `StepResults`。ClaudeEval 経路はこれを呼ばず `SourceVaultWiringPlanExpression` を使う (W9)。
→ `<|"Status"->"AwaitingInput"|"OK", ...|>` | Failure
Options: "OnMissingInput" -> "Return" (既定), "AllowEffects" -> False (既定)