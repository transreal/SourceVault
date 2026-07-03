# SourceVault_contracts API リファレンス

パッケージ: `SourceVault`` (コンテキスト: `SourceVault`ContractsPrivate`` に実装)
ロード: `SourceVault.wl` が自動ロード (aux)。standalone `Get["SourceVault_contracts.wl"]` も可 (pilot 契約の登録は本体ロード時のみ)。
仕様書: `sourcevault_function_contract_wiring_spec_v0_3.md`
役割: api.md を「読む文書」から「型付き API コンパイラ層」へ。関数ごとの機械可読契約 (FunctionContract: 呼び出し形 / option 契約 / 初期化依存 / 内部状態 / 入出力ポート / 選定メタデータ) の registry と、それを使う冪等初期化・式検証・監査。

## 契約 registry

### SourceVaultRegisterFunctionContract[contract, opts]
FunctionContract (Association) を検証して registry に登録する。`"Supersedes"` の alias は deprecated alias 索引へ自動登録。
→ Association `<|"Status"->"OK", "Symbol"->...|>` | Failure["InvalidContract"]
Options: `"CheckSymbolExists"` -> False (True で Symbol 実在検査)

主要フィールド: `Symbol`/`Package`/`Kind`("Function"|"Init"|"Adapter"|"CellInterface")、`CallForms` (引数形。`Arguments` の `Kind`: Positional|OptionalPositional|OptionsPattern、`MapsToPort` で Inputs ポートと対応)、`OptionContracts` (`Name`/`Default`/`AllowedValues`/`Aliases`/`DeprecatedAliases`)、`UnknownOptionPolicy`("Reject" 既定)、`Requires` (Init 依存)、`Reads`/`Writes` (内部状態宣言)、`Inputs`/`Outputs` (ポート: `PortType` "Value"|"URI"|"NotebookCell"、`DomainKind`/`MediaKind`/`WLType`/`PrivacyFloor`)、選定メタデータ (`RecommendedEntrypoint`/`AbstractionLevel`/`CapabilityTags`/`IntentExamples`/`NegativeExamples`/`Supersedes`/`UseInsteadOf`/`DoNotUseWhen`)、`Effects`/`Idempotent`/`CostClass`。

### SourceVaultFunctionContract[symbol]
登録済み契約を返す。無ければ `Missing["NoContract", symbol]`。
→ Association | Missing

### SourceVaultFunctionContracts[]
### SourceVaultFunctionContracts[pkg]
登録済み契約の一覧 (pkg で絞り込み可)。
→ List

### SourceVaultValidateFunctionContract[contract, opts]
契約 schema の検証 (純関数)。Kind->"Init" は `InitializedQRef`/`Provides` 必須。
→ Association `<|"Status"->"OK"|"Failed", "Failures"->{Failure...}|>`
Options: `"CheckSymbolExists"` -> False

### SourceVaultUnregisterFunctionContract[symbol]
契約を registry から外す (テスト / 差し替え用)。
→ Association

### SourceVaultContractAliasIndex[]
deprecated alias -> 正準 symbol の索引 (契約の `Supersedes` から構築)。
→ Association

### SourceVaultContractFailure[tag, detail]
契約系の標準 Failure を作る。tag: "UnknownOption" | "UnknownSymbol" | "ArgumentCount" | "OptionValueType" | "DeprecatedAlias" | "InitCycle" | "InitFailed" | "InvalidContract" | "OptionsMismatch" 等。detail は `"Symbol"`/`"Detail"`/`"SuggestedReplacement"`/`"RepairHints"` (machine-readable な修復指示) を持てる。
→ Failure

## 冪等初期化 (InitContract / 依存 DAG)

Init 契約 (Kind->"Init") の追加フィールド: `Provides` (確立する状態キー)、`InitializedQRef` (副作用なし述語の **symbol 名文字列**。registry に評価可能式は置かない)、`EnsureFunction`/`ForceFunction`、`DefaultInitModeForDirectCall`("Force")、`DefaultInitModeForWiring`("Ensure")、`InitCost`/`ReinitSafe`。
Init 関数側の規約: オプション `"InitMode"` -> "Force" (既定、本来の初期化=現行挙動) | "Ensure" (初期化済みなら副作用ゼロで `<|"Status"->"AlreadyInitialized"|>`)。例: `SourceVaultInitialize`。

### SourceVaultEnsureInitialized[symbol]
symbol の `Requires` DAG をトポロジカル順に冪等実行する。各 Init は述語が True なら skip、未初期化なら 1 回だけ実行。**何回呼んでも安全**。reentry guard (`$SourceVaultInitInProgress`) で同一 kernel 内の再入二重実行を防止。失敗した Init に依存する後続は `DependencyFailed` (fail-fast)。
→ Association `<|"Status", "Executed", "Skipped", "Failed"|>`

### SourceVaultInitPlan[symbol]
実行せず初期化順序だけ返す (dry-run)。循環依存は `Failure["InitCycle"]`。
→ Association `<|"Status", "Order", "Missing"|>` | Failure

### $SourceVaultInitInProgress
型: Association
実行中 Init の in-progress marker (reentry guard)。

## 呼び出し式の検証 / 正規化 / 修復 (実行前ゲート)

### SourceVaultValidateCallExpression[heldExpr, opts]
提案式を実行前に決定的検証する (純関数・評価しない)。heldExpr: `HoldComplete[f[...]]` / `Hold[...]` / 式文字列。検査: head 契約有無 / deprecated alias / 引数個数 (CallForms) / option 実在 (**幻 option を拒否**、EditDistance 最近傍を `SuggestedReplacement` で提案) / option 値 (AllowedValues、リテラルのみ)。契約外関数は既定素通し。
→ Association `<|"Status"->"OK"|"Failed", "Symbol", "Coverage"->"Contract"|"NoContract", "Failures"|>`
Options: `"UnknownSymbolPolicy"` -> "Pass" | "Reject", `"RequireClaudeEvalForm"` -> False

### SourceVaultNormalizeCallExpression[heldExpr]
alias -> 正準の決定的書き換えのみ (deprecated symbol の head 置換 + option alias。トップレベル option のみ、値の中は不可触)。書き換えは `"Rewrites"` に記録。
→ Association `<|"Status", "Expression"->HoldComplete[...], "Rewrites"|>`

### SourceVaultRepairCallExpression[heldExpr, opts]
Normalize + 未知 option の最近傍提案の適用。既定は SuggestOnly (式は不変)。
→ Association `<|"Status", "Expression", "Applied", "Remaining"|>`
Options: `"ApplySuggestions"` -> False (True で自動置換して再検証)

### SourceVaultExplainCallContract[symbol]
契約を人間・LLM 可読な文字列に整形 (Signature / Options 一覧「これ以外の option は無い」/ Requires の EnsureInitialized 前置き案内 / Supersedes)。
→ String | Missing["NoContract"]

## 監査

### SourceVaultAuditFunctionContracts[pkg | All]
registry と実装の乖離を検査する: Symbol 実在 / `Options[sym]` と OptionContracts の双方向差分 / Requires の Init 契約登録 / Init ref の解決可能性 (rename drift)。
→ Association `<|"Status", "Checked", "OKCount", "FailedCount", "PerSymbol"|>`

## ClaudeRuntime hook (提案式の実行前契約検証)

### SourceVaultCallContractValidatorHook[heldExpr]
ClaudeRuntime `$ClaudeCallContractValidator` の実体。提案式全体を**深くスキャン**し (Module/CompoundExpression 内も対象)、契約登録済み head の呼び出しをすべて検証。違反時は LLM 向け修復指示 `RepairText` を返し、Runtime 側で Decision="RepairNeeded" の修復ターンになる。fail-open (契約外・解釈不能は素通し)。ロード時に両側 handshake で自動配線 (rule 11)。
→ Association `<|"Status"->"OK"|"Failed", "Checked", "RepairText", "Failures", "FailureTags"|>`
