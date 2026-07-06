# SourceVault_contracts API リファレンス

## 概要
SourceVault の Function Contract / Init-DAG 基盤。関数の「契約 (FunctionContract)」を外付け宣言として registry に登録し、(1) 冪等な初期化 DAG の実行、(2) LLM 提案コード呼び出し式の実行前検証・正規化・修復を提供する。仕様書 `sourcevault_function_contract_wiring_spec_v0_3.md` に対応。

設計原則:
- W1: 契約は外付け宣言。既存関数の挙動を変えない。契約なし関数は素通し (fail-open)。
- W2: 冪等は切替式。直接呼びの既定は `"Force"`、DAG 経由は `"Ensure"`。
- W10: registry に評価可能コード (Hold 式) を置かない。述語・関数は symbol 名文字列 (ref) で持ち、解決は本ファイルの実行層だけが行う。

非衝突方針: private helper は `SourceVault`ContractsPrivate`` 文脈に置き、`SourceVault`Private`` と隔離する。全 public シンボルは `SourceVault`` 文脈。

FunctionContract の主なフィールド (Association):
- `"Symbol"` (String, 必須), `"Package"` (String, 必須), `"Kind"` (必須: `"Function"|"Init"|"Adapter"|"CellInterface"`)
- `"Requires"` (init symbol 名の String リスト), `"Reads"`/`"Writes"` (String リスト), `"Supersedes"` (deprecated alias の String リスト), `"CapabilityTags"` (String リスト)
- `"Inputs"`/`"Outputs"` (Port Association リスト: `"Name"`,`"PortType"` 必須), `"CallForms"` (呼び出し形の Association リスト: `"ExpressionHead"` 必須, `"Arguments"`), `"OptionContracts"` (option 契約 Association リスト: `"Name"` 必須)
- Kind=`"Init"` の必須: `"InitializedQRef"` (述語 symbol 名 String), `"Provides"` (String リスト)。任意: `"EnsureFunction"`,`"ForceFunction"`
- `"UnknownOptionPolicy"` (既定 `"Reject"`)

CallForms の `"Arguments"` 要素: `"Name"`, `"Kind"` (`"Positional"|"OptionalPositional"|"OptionsPattern"`), `"WLType"`, `"Required"`, `"MapsToPort"`。OptionContracts 要素: `"Name"`, `"Default"`, `"AllowedValues"` (明示リストのときのみリテラル値検査), `"Aliases"`/`"DeprecatedAliases"`。

## 共通 Failure schema

### SourceVaultContractFailure[tag, detail] → Failure
契約系の標準 Failure を作る。tag は `"UnknownOption"|"UnknownSymbol"|"ArgumentCount"|"OptionValueType"|"DeprecatedAlias"|"InitCycle"|"InitFailed"|"InvalidContract"` 等。detail は Association で `"Symbol"`/`"Detail"`/`"RepairHints"`/`"SuggestedReplacement"` を持てる。

## FunctionContract registry

### SourceVaultRegisterFunctionContract[contract, opts]
contract を検証して registry に登録する。`"Supersedes"` から deprecated alias→canonical 索引を構築する。
→ `<|"Status"->"OK", "Symbol"->_|>` または検証失敗時 Failure[`"InvalidContract"`]
Options: "CheckSymbolExists" -> False (Symbol 実在検査。standalone テストでは False)

### SourceVaultUnregisterFunctionContract[symbol] → `<|"Status"->"OK","Symbol"->_|>`
契約を registry から外す (テスト/差替用)。alias 索引からも該当を除去。

### SourceVaultFunctionContract[symbol] → Association | Missing["NoContract", symbol]
登録済み契約 (Association) を返す。

### SourceVaultFunctionContracts[] → {contract...}
登録済み契約の一覧を返す。

### SourceVaultFunctionContracts[pkg] → {contract...}
`"Package"` が pkg のものに絞る。

### SourceVaultValidateFunctionContract[contract, opts]
契約 schema を検証する純関数。Kind=`"Init"` は `"InitializedQRef"`/`"Provides"` 必須。任意フィールドの型検査を行う。
→ `<|"Status"->"OK"|"Failed", "Failures"->{Failure...}|>`
Options: "CheckSymbolExists" -> False (True で Context+Symbol の実在を Names で検査)

### SourceVaultContractAliasIndex[] → Association
deprecated alias → canonical symbol の索引。契約の `"Supersedes"` から登録時に構築される。

## 冪等初期化プロトコル

### SourceVaultInitPlan[symbol] → Association | Failure
symbol の実行に必要な Init 契約を Requires 閉包の DFS post-order (トポロジカル順) で返す (dry-run)。
→ `<|"Status"->"OK", "Order"->{initSymbol...}, "Missing"->{契約未登録の Requires...}|>`。循環依存は Failure[`"InitCycle"`, `<|"Path"->...|>`]

### SourceVaultInitPlan[syms] → Association | Failure
symbol リスト版。各 plan の Order/Missing を重複なくマージ。いずれかが Failure なら最初の Failure を返す。

### SourceVaultEnsureInitialized[symbol] → Association | Failure
symbol の Requires DAG をトポロジカル順に冪等実行する。各 Init は `"InitializedQRef"` 述語が True なら副作用ゼロで skip、未初期化なら 1 回だけ実行。`"InitMode"` option を持つ関数には `"Ensure"` を渡す (それ以外は無引数呼び)。何回呼んでも安全。失敗した Init に依存する後続は実行せず `Failed(DependencyFailed)` に積む (fail-fast)。
→ `<|"Status"->"OK"|"Failed", "Executed"->{sym...}, "Skipped"->{<|"Symbol","Reason"|>...}, "Failed"->{<|"Symbol","Reason","Failure"|>...}|>`
Skipped の Reason: `"AlreadyInitialized"|"InProgress"|"NoInitContract"`。

### $SourceVaultInitInProgress
型: Association, 初期値: `<||>`
実行中 Init の in-progress marker。同一 kernel 内の再入 (Dynamic/scheduled task 等) で同じ Init が二重実行されないよう保護する (reentry guard)。

## 呼び出し式の検証・正規化・修復

入力式は `HoldComplete[f[args...]]` / `Hold[...]` / 式文字列のいずれか。いずれも評価されない。文字列は SyntaxQ 検査後 ToExpression[.., InputForm, HoldComplete] で held 化する。

### SourceVaultValidateCallExpression[input, opts]
提案式を実行前に決定的検証する純関数 (評価しない)。検査: head 契約有無 / deprecated symbol alias / 引数個数 (CallForms の Positional 必須数≤実引数≤最大数) / option 実在 (OptionContracts) / option 値 (AllowedValues がリストでリテラル値のときのみ)。deprecated alias/unknown option は RepairHints・SuggestedReplacement を付す。unknown option は `"UnknownOptionPolicy"` (契約既定 `"Reject"`) のとき失敗。
→ `<|"Status"->"OK"|"Failed", "Symbol"->_, "Coverage"->"Contract"|"NoContract", "Failures"->{Failure...}|>`
Options: "UnknownSymbolPolicy" -> "Pass" (契約外関数は素通し) | "Reject", "RequireClaudeEvalForm" -> False (True で CallForms を UseForClaudeEval のものに限定)

### SourceVaultNormalizeCallExpression[input] → Association
alias→canonical の決定的書き換えのみ行う。対象: deprecated symbol alias (Supersedes) の head 置換、option alias の正準化 (トップレベルのみ)。意味を変える修復はしない。
→ `<|"Status"->"OK", "Expression"->HoldComplete[...], "Rewrites"->{<|"Action","From","To"|>...}|>`

### SourceVaultRepairCallExpression[input, opts]
Normalize + RepairHints の適用を行う。unknown option → 最近傍 allowed option (EditDistance) の置換は既定 SuggestOnly (提案のみ)。
→ `<|"Status", "Expression", "Applied"->{rewrites...}, "Remaining"->{Failure...}|>`
Options: "ApplySuggestions" -> False (True で unknown option の最近傍提案を自動置換し再検証), "UnknownSymbolPolicy" -> "Pass"

### SourceVaultExplainCallContract[symbol] → String | Missing["NoContract", symbol]
契約 (Signature/Options/Requires/Supersedes/DoNotUseWhen) を人間・LLM 可読な文字列に整形する。Options 節は「これが唯一の有効オプション」と明示し、default/allowed/alias を併記する。

### SourceVaultCallContractValidatorHook[input] → Association
ClaudeRuntime の提案検証 hook 実体。提案式全体を深くスキャン (Module/CompoundExpression 内も対象) し、契約登録済み head (deprecated alias 含む) の呼び出しをすべて `SourceVaultValidateCallExpression["UnknownSymbolPolicy"->"Pass"]` で検証する。契約外関数は素通し (fail-open)。違反時は LLM 向け修復指示 `"RepairText"` を返す。
→ `<|"Status"->"OK"|"Failed", "Checked"->n, "FailureTags"->{...}, "Failures"->{...}, "RepairText"->_|>`
ClaudeRuntime`$ClaudeCallContractValidator へロード時に弱結合登録される (両側 handshake、既存の別 validator は上書きしない)。

## 契約 audit

### SourceVaultAuditFunctionContracts[] → Association
`SourceVaultAuditFunctionContracts[All]` と同じ。

### SourceVaultAuditFunctionContracts[pkgOrAll]
registry と実装の乖離を検査する。pkgOrAll は `All` または Package 名 String。検査: Symbol 実在 / `Options[sym]` と OptionContracts の双方向差分 (ContractOnly=存在しない option を主張, ImplementationOnly=契約が取りこぼし) / Requires の全 init が Kind=`"Init"` 契約として登録済み / Init 契約の `"InitializedQRef"`・`"EnsureFunction"`・`"ForceFunction"` ref の解決可能性 (rename drift 検出)。
→ `<|"Status"->"OK"|"Failed", "Checked"->n, "OKCount"->n, "FailedCount"->n, "PerSymbol"-><|sym-><|"AuditStatus","Failures"|>|>|>`

## 登録済み pilot 契約
`SourceVault.wl` (シンボル `SourceVaultInitialize`) がロード済みのときのみ、ロード末尾で自動登録される。standalone テスト環境では登録しない。以下は登録される契約 (ContractVersion=2)。

SourceVaultInitialize — Kind=`"Init"`, Provides `{"$SourceVaultRoots"}`, InitializedQRef `"SourceVault`Private`iSVRootsReadyQ"`。Options: Roots -> Automatic, Force -> False ({True,False}), InitMode -> "Force" ({"Force","Ensure"})。UnknownOptionPolicy=Reject。

SourceVaultLookup[topic_String, key_, opts] — Kind=`"Function"`, Requires `{"SourceVaultInitialize"}`, RecommendedEntrypoint。Options: Channel -> "public" ({"public","private"}), AllowSeed -> True ({True,False})。UnknownOptionPolicy=Reject。

SourceVaultFindNotebooks[opts] — Kind=`"Function"`, Requires `{"SourceVaultInitialize"}`, RecommendedEntrypoint, CostClass Kernel。Options: OpenTodos, NextReview, Deadline, Keywords, Title, Status, Scope, ForceReindex -> False ({True,False}), Format -> False ({True,False})。UnknownOptionPolicy=Reject。

SourceVaultUpcomingSchedule[opts] — Kind=`"Function"`, Requires `{"SourceVaultInitialize"}`, RecommendedEntrypoint, CostClass Kernel。期日ベースのスケジュール表示が目的なら FindNotebooks の代わりに使う。Options: Scope -> Automatic, Period -> Quantity[7,"Days"], IncludeOverdue -> True ({True,False}), Recursive -> True ({True,False}), Refresh -> "Never" ({"Never","IfStale","Force"}), FallbackToCloud -> "Ask" ({"Ask","Allow","Deny"}), StatusFilter -> {"Todo"}, UseCache -> True ({True,False}), OpenTodos -> Missing[], DateField -> "Both" ({"Both","Deadline","NextReview"}), FilterSpec -> Missing[], OutputFormat -> "Dataset" ({"Dataset","Rows","Records"})。UnknownOptionPolicy=Reject。

SourceVaultResolve[kind_String, query_Association, opts] — Kind=`"Function"`, Requires `{"SourceVaultInitialize"}`, RecommendedEntrypoint。用途に合うモデル等を解決する。Options: Channel -> "public" ({"public","private"}), AllowSeed -> True ({True,False}), Topic -> Automatic。UnknownOptionPolicy=Reject。

## 使用例
新規契約の登録と検証:
```
SourceVaultRegisterFunctionContract[<|
  "Symbol"->"MyInit", "Package"->"MyPkg", "Kind"->"Init",
  "InitializedQRef"->"MyPkg`readyQ", "Provides"->{"$MyState"}|>]
SourceVaultEnsureInitialized["MyFunc"]  (* MyFunc の Requires DAG を冪等実行 *)
```
LLM 提案式の検証 (評価しない):
```
SourceVaultValidateCallExpression[
  HoldComplete[SourceVaultLookup["models", "gpt", Channel->"public"]]]
(* option 名/値/引数個数を実行前チェック *)
```

関連パッケージ: [SourceVault](https://github.com/transreal/SourceVault), [SourceVault_core](https://github.com/transreal/SourceVault_core), [SourceVault_wiring](https://github.com/transreal/SourceVault_wiring), [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime)