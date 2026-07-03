# SourceVault Function Contract / Init-DAG / Wiring 仕様 v0.3

- Status: **Draft（r2 反映済み・freeze 候補）**
- Date: 2026-07-02
- 前版: `..._spec_v0_2.md` / レビュー: `..._spec_v0_1_review.md`（r1・改訂版含む）, `..._spec_v0_2_review.md`（r2）
- 対象: `SourceVault*.wl`（contract registry / call validation / wiring / MCP adapter 拡張）, `claudecode.wl`（NB 境界・WorkflowInputBlock / Binding helper UI・push hook 消費側）, `ClaudeRuntime.wl`（proposal validation 接続）, `ClaudeUpdateDocumentation`（契約セクション生成＋audit report）
- 前提: `sourcevault_directive_api_retrieval_spec_v0_3.md`（以下 **v0.3**。Inc0 freeze 済み）の follow-on。v0.3 と矛盾する変更は行わない。
- 関連: `sourcevault_universal_mcp_access_spec_v2`（AccessProfile / PromptDeliveryProfile / OutputPrivacyEstimate / URI namespace 方針）, `sourcevault_search_foundation_implementation_spec_v1`（KeywordBM25V1）, `sourcevault_prompt_router_unified_spec`（propose/execute 分離）, rule 11

> **v0.1 → v0.2 の要点（r1 全面反映）**: (1) **CallForms / OptionContracts** を契約に追加し、`SourceVaultValidateCallExpression` 系で**幻の option・誤引数順を実行前に決定的拒否**（§4.1, §6.1）。(2) **関数選定の規約**を具体化——selection metadata（CapabilityTags/NegativeExamples/AbstractionLevel 等）＋`SourceVaultSelectFunctionsForTask`（rejected reason 付き）（§4.1, §6.2）。(3) **PortBindingRef** で NotebookCell/PromptRun/Variable/File/Literal を snapshot/live・identity・privacy 付き typed handle 化（§4.5）。(4) **Value 入力も privacy label**（ValueEnvelope、0 扱い廃止）（§4.4, §6.6）。(5) Class を **ObjectKind/DomainKind/MediaKind** に分離し v2 の URI namespace 方針と整合（§4.3）。(6) InitContract の **`Hold` 排除→述語 symbol ref 化**＋reentry guard（§4.2, §5.3）。(7) adapter を深さ 1 固定から **cost/lossiness 付き探索（一意 path 要求）**へ（§6.3）。(8) **propose / validate / execute 三層分離**、ClaudeEval は execute を呼ばない（§6.7）。(9) **契約 audit CI**（registry vs 実装）（§8.4, §10）。(10) **入力確定と起動シーケンス**——正本は notebook 上の **WorkflowInputBlock**（typed 入力フォームセル）、dialog/palette は補助 UI に格下げ。**ワークフロー起動自体も式提案**（`SourceVaultRunWorkflow[...]` を未評価式として提案し、通常のセル評価＝既存検査経路で実行。隠れた実行入口を作らない）（§7.4）。(11) **共通 Failure schema＋RepairHints**（§4.8）。

> **v0.2 → v0.3 の要点（r2 反映）**: (1) **`ExecuteWiringPlan` と `RunWorkflow` の責務分離**——Execute は AwaitingInput を返すだけで notebook を触らない、挿入は notebook-facing wrapper の RunWorkflow（§6.7, §7.4.1）。(2) **InputDraft / InputBundle の語彙分離**——未検証セル内容は InputDraft、検証 green 後にのみ InputBundle（不変 snapshot）を作る（§7.4.2）。(3) **WorkflowInputBlock の block-level metadata**（lifecycle / PlanHash / CellUUIDs / LastInputBundleURI）（§7.4.2）。(4) **起動式再評価の idempotency**——未提出 block は増殖させず既存を返す、schema 変更時は Superseded（§7.4.1、G-ui-3/4）。(5) **InputBundle の subtype 必須化**（`BundleKind->"WorkflowInput"` 等、EvidenceBundle と混同させない）（§7.4.2、Q11 解決）。(6) **`SourceVaultRunWorkflow` / `SubmitWorkflowInput` 自身を pilot 契約対象に明示**（§7.4.1, §10 F2）。(7) 用語整理（Binding UI → WorkflowInputBlock / Binding helper UI）。詳細は末尾「変更履歴」。

---

## 0. 一行で

api.md を「読む文書」から「**型付き API コンパイラ層**」へ拡張する。各公開関数に（呼び出し形 / option 契約 / 初期化依存 / 内部状態 / 入出力ポート / 選定メタデータ）を機械可読な **FunctionContract** として付与し、ClaudeEval の提案式を**実行前に決定的検証・修復**し、**typed binding（URI envelope / ValueEnvelope / PortBindingRef）**による接続層（決定的優先＋LLM 残余のみ）で関数列を propose→validate→execute の三層で合成し、MCP からモデル能力別粒度で ranked 検索可能にする。初期化は冪等プロトコル（`"InitMode"`＋依存 DAG）で何回でも安全に。

---

## 1. 背景・動機

### 1.1 直接に効かせたい失敗（r1 §0）

1. ClaudeEval / LM Studio 系モデルが最適でない関数（低レベル関数・未実装 wrapper・旧 alias）を選ぶ。
2. **存在しない option** や誤った引数順で式が失敗する。
3. Workflow 構成時に notebook cell・履歴・変数名・ファイル指定の**同一性と privacy が崩れる**（live か snapshot か不明、変数名がセッション依存）。
4. プロンプト履歴のパラメータ置換 UI が文字列置換に近く、**型付きデータ接続として検証できない**。

### 1.2 要望 → 本仕様の対応表

| # | 要望 | 対応箇所 |
|---|---|---|
| 1 | 初期化の冪等実行（既定＝本来の初期化、冪等へ切替可） | §5 |
| 2 | 初期化依存関係の記述 | §4.1 `Requires` / §5.3 |
| 3 | 参照渡しは URI を強制 | §4.3 / §6.3 / §9 |
| 4 | 内部状態・入力・出力の記述 | §4.1 |
| 5 | 関数間データ接続の補助関数 | §6.3–6.4 |
| 6 | NB セル入出力の初段・最終段更新 | §7 |
| 7 | MCP 検索 DB 更新 | §8.1–8.2 |
| 8 | 関連・類似 API の ranked 候補 | §6.2 / §8.2 |
| 9 | 決定的 WL モード＋LLM 動的モード | §6.4 / §6.5 |
| 10 | モデル粒度別提供（Opus vs qwen3.6-27b） | §8.3 |
| r1 | 幻 option の実行前拒否 / typed binding / 選定規約 / audit / Binding UI | §6.1 / §4.5 / §6.2 / §8.4 / §7.4 |

### 1.3 現状の欠落（v0.1 調査＋r1）

- api.md は Options/Returns を散文で持つが、**引数形・option 実在性・値域・戻り値 variant を機械検証できない**。`iPackageDocsContext`（claudecode.wl:18182 付近）は全文 Import→24K truncate。
- 初期化関数は概ね事実上冪等だが規約がなく、`iEnsureDefaultSession`（claudecode.wl:4547）は非冪等、`iEnsureCUDAExtension` は失敗時例外。
- URI 基盤（`SourceVaultResolveArtifactContent` core.wl:1045、`SourceVaultParseURI/BuildURI/CanonicalURI/ResolveURI` mcp.wl:50–69）は完成。欠けているのは**任意の値・セル・変数・ファイルを typed handle として関数間で受け渡す正準経路**。
- プロンプト入力 Association（`OriginalTask`/`Hint`、claudecode.wl:30461）は task 文字列抽出にしか機能していない。

---

## 2. 設計原則（不変条件）

- **W1 契約は外付け宣言**: FunctionContract は既存関数のシグネチャ・実行時挙動を変えない。契約なし関数は従来通り呼べる（opt-in・段階導入）。
- **W2 冪等は切替式・既定は現状維持**: 直接呼び出しの既定は `"InitMode"->"Force"`（本来の初期化）。`"Ensure"` はオプション指定または wiring/DAG 経由のみ（§4.2 の `DefaultInitModeForWiring`）。
- **W3 参照渡しの正準形は typed handle**: sv:// URI envelope（§4.3）を基本とし、値・セル・変数・ファイルは PortBindingRef（§4.5）/ ValueEnvelope（§4.4）で identity・snapshot 方針・privacy を保持する。強制は wiring/validation 層で効かせ、レガシー直呼びを壊さない。
- **W4 決定的優先・LLM は残余のみ**: 関数選定・式検証・束縛は決定的規則を先に適用し、LLM は決定的に解けなかった残余のみを schema 制約付きで埋める（validate-then-accept）。LLM は決定規則を上書きできない。
- **W5 privacy は接続時に事前計算・値も例外にしない**: PrivacyEstimate は URI envelope と ValueEnvelope **両方**の Max（§6.6）。release gate は egress 時に必ず再評価（declassify しない）。
- **W6 検索基盤は v0.3 を拡張**: 新規の索引・URI 体系を作らない。
- **W7 層境界（rule 11）**: claudecode/ClaudeRuntime は SourceVault を直接参照せず hook 越し（§6.1, §7.3）。
- **W8 契約 drift は freshness＋audit で扱う**: api.md との乖離は `StaleContract`（warning＋ranking penalty）。**registry と実装の乖離は audit（§8.4）で fail**（doc は可用性優先、契約 DB の正しさは CI 優先）。
- **W9 propose / execute 分離・起動も式提案**: wiring は「未評価 proposal の生成」と「検証」と「実行」を分離する。ClaudeEval 接続は propose/validate 経路のみを使い、実行は既存の Runtime/NBAccess 検査・承認経路に委ねる（§6.7）。**ワークフローの起動シーケンスも同じ**——起動式（`SourceVaultRunWorkflow[...]` 等）自体を提案対象の未評価式とし、評価は通常の notebook 評価で行う。SourceVault 側に式提案経路を迂回する実行入口を作らない（§7.4）。
- **W10 契約 registry は評価可能コードを持たない**: registry・MCP view に `Hold` 式や実行可能 code を置かない。述語・関数は symbol 名 ref で参照し、解決は実行層だけが行う（§4.2）。

---

## 3. スコープ

| 区分 | 内容 |
|---|---|
| **In** | (a) FunctionContract / InitContract schema（CallForms・OptionContracts・selection metadata 込み）と registry。(b) call expression の validate / normalize / repair。(c) 冪等初期化＋依存 DAG＋reentry guard。(d) 関数選定（`SelectFunctionsForTask`）。(e) typed binding（URI/Value/PortBindingRef）・port adapter・wiring planner（propose/validate/execute）。(f) NB 境界＋WorkflowInputBlock（起動シーケンス・入力確定の正本）＋Binding helper UI。(g) `packageapi` chunk 拡張・`view=contract`・related candidates・モデル粒度 profile・増分スキャン・契約 audit。 |
| **Out（別件）** | v0.3 Inc1–Inc5 本体（依存）。安全 rules 同梱。ClaudeOrchestrator workflow DSL 変更（WiringPlan→Workflow 変換は将来仕様、Q6）。既存全関数への契約一斉付与（pilot から漸進）。ClaudeRuntime の承認 UI 自体の変更（既存経路を使う）。 |

---

## 4. データモデル

### 4.1 FunctionContract schema

registry が正、api.md は描画。1 公開シンボル = 1 契約。

```wl
<|
  "ObjectClass" -> "SourceVaultFunctionContract",
  "ContractVersion" -> 2,
  "Symbol" -> "SourceVaultMailView", "Package" -> "SourceVault", "AuxName" -> "maildb",
  "Uri" -> "sv://packageapi/<opaqueId>",          (* v0.3 §7.2 stable URI と同一 *)
  "Kind" -> "Function" | "Init" | "Adapter" | "CellInterface",

  (* --- 呼び出し契約（新・P0）: WL 式を構成・検証するための正本 --- *)
  "CallForms" -> {
    <|"FormId" -> "main",
      "ExpressionHead" -> "SourceVaultMailView",
      "Arguments" -> {
        <|"Name" -> "query", "Kind" -> "Positional",          (* Positional |
             OptionalPositional | OptionsPattern *)
          "WLType" -> "String", "Required" -> True,
          "MapsToPort" -> "query"|>,                          (* Inputs ポートとの対応 *)
        <|"Name" -> "opts", "Kind" -> "OptionsPattern", "Required" -> False|>
      },
      "Recommended" -> True, "UseForClaudeEval" -> True|>
      (* UseForClaudeEval->False の form は提案禁止（内部呼び出し専用） *)
  },
  "OptionContracts" -> {
    <|"Name" -> "Period", "Default" -> 7,
      "ValueType" -> "Integer" | "Quantity[_,\"Days\"]",       (* 型パターン文字列の Alternatives *)
      "AllowedValues" -> Automatic,                             (* enum のときは明示リスト *)
      "Aliases" -> {"PeriodDays"}, "DeprecatedAliases" -> {}|>,
    <|"Name" -> "OpenTodos", "Default" -> Missing[],
      "ValueType" -> "Boolean" | "Missing",
      "AllowedValues" -> {True, False, Missing[]}|>
  },
  "UnknownOptionPolicy" -> "Reject",                (* 既定 Reject。"WarnPass" は移行期のみ *)
  "ReturnVariants" -> {"Association" | "Dataset" | "Grid" | "SideEffectOnly", ...},

  (* --- 選定メタデータ（新・P0）: 「使うべき関数」を決める正本 --- *)
  "RecommendedEntrypoint" -> True | False,
  "AbstractionLevel" -> "UserFacing" | "Adapter" | "Internal",
      (* Internal は選定候補から既定除外（明示指定時のみ） *)
  "CapabilityTags" -> {"mail.view", "schedule.review"},
  "IntentExamples" -> {"今日のメールを一覧して", "受信メールのスレッドを見たい"},
  "NegativeExamples" -> {
    <|"Task" -> "メール本文を全文検索", "Reason" -> "検索は SourceVaultMailStructSearchThreads"|> },
  "CanonicalFor" -> {"MailView"}, "Supersedes" -> {"showMails"},
  "UseInsteadOf" -> {"SourceVaultMailSnapshotFromMaildb" -> "表示が目的の場合"},
  "DoNotUseWhen" -> {"raw maildb record の変換が目的"},

  (* --- 初期化依存 --- *)
  "Requires" -> {"SourceVaultInitialize", "SourceVaultMailEnsureIndex"},

  (* --- 内部状態（宣言のみ） --- *)
  "Reads"  -> {"$SourceVaultRoots", "$SourceVaultMailIndexCache"},
  "Writes" -> {"$SourceVaultMailIndexCache"},

  (* --- 入出力ポート（§4.3 taxonomy） --- *)
  "Inputs" -> {
    <|"Name" -> "query", "PortType" -> "Value", "WLType" -> "String", "Required" -> True|>,
    <|"Name" -> "source", "PortType" -> "URI", "DomainKind" -> "Mail",
      "Required" -> False, "PrivacyFloor" -> 0.5|> },
  "Outputs" -> {
    <|"Name" -> "result", "PortType" -> "URI", "ObjectKind" -> "Artifact",
      "DomainKind" -> "Mail", "MediaKind" -> "Text"|> },

  "Effects" -> {"NotebookWrite"} | {},   (* NotebookWrite/FileWrite/Network/LLMCall/None *)
  "Idempotent" -> True | False,
  "CostClass" -> "Cheap" | "Kernel" | "LLM" | "Network",
  "SourceRefId" -> _, "ContractSourceHash" -> _
|>
```

- `Inputs`/`Outputs` は **port-level 契約**（wiring 用）、`CallForms` は **WL 式構成契約**（式生成・検証用）として分離。`MapsToPort` が両者を決定的に結ぶので、束縛が済めば式生成は機械的。
- 登録 API（v0.1 から継続）: `SourceVaultRegisterFunctionContract` / `SourceVaultFunctionContract[sym]` / `SourceVaultFunctionContracts[pkg]` / `SourceVaultValidateFunctionContract`。
- 置き場: pkg 別 contracts ファイル（例 `SourceVault_contracts.wl`）。コードと同 repo で versioning（source 扱い）。

### 4.2 InitContract（`Kind->"Init"`・**ref 化、W10**）

```wl
<|
  ..., "Kind" -> "Init",
  "Provides" -> {"$SourceVaultRoots"},
  "InitializedQRef" -> "SourceVault`Private`iRootsReadyQ",
      (* 副作用なし述語の symbol 名（文字列）。Hold 式は registry に置かない。
         解決・評価は SourceVaultEnsureInitialized だけが行う *)
  "EnsureFunction" -> "SourceVaultInitialize",     (* 通常は Symbol 自身 *)
  "ForceFunction"  -> "SourceVaultInitialize",
  "DefaultInitModeForDirectCall" -> "Force",       (* W2: 直接呼びの既定 *)
  "DefaultInitModeForWiring"     -> "Ensure",      (* wiring/DAG 経由の既定 *)
  "InitCost" -> "Cheap" | "Slow",
  "ReinitSafe" -> True | False
|>
```

- MCP `view=contract`（§8.1）には ref **名だけ**を出す。評価可能な式は一切投影しない。
- rename drift は audit（§8.4）が `Names` 照合で検出する。

### 4.3 URI envelope と Class taxonomy（**v2 整合・P1**）

URI envelope 正準形（実データが返す形を契約化。v0.1 から継続）:

```wl
<|"Status" -> "OK", "URI" -> "sv://artifact/artifact-5927f776-36c",
  "ObjectKind" -> "Artifact",            (* Artifact | Object | Chunk | Record — URI namespace 系 *)
  "DomainKind" -> "Mail",                (* Mail | Notebook | Eagle | PackageAPI | ... — sidecar 系 *)
  "MediaKind" -> "Image",                (* Text | Image | Video | Dataset | Binary *)
  "PrivacyLevel" -> 0., "Marked" -> False|>
```

- 必須: `Status`/`URI`/`PrivacyLevel`。`ObjectKind` は URI namespace から機械導出、`DomainKind`/`MediaKind` は sidecar metadata 由来。
- **旧 `Class` キーは廃止**（v0.1 §4.1 の `Class->"mail"` は `DomainKind->"Mail"` に読み替え）。universal MCP access v2 の「URI namespace は identity 用、mail/pdf/notebook は sidecar」方針に整合。**Composable 判定（§6.4, §8.2）は DomainKind と MediaKind を使い、URI namespace から domain を推論しない。**
- 素の `"sv://..."` 文字列は境界で envelope へ昇格（PrivacyLevel 欠落は既定 0.85 = `$SourceVaultDefaultObjectPrivacyLevel`、fail-closed）。本文は含めない。resolve は gate 越し。

### 4.4 ValueEnvelope（**新・P0: Value 入力の privacy**）

値渡し（`PortType->"Value"`）も privacy label を持つ:

```wl
<|"PortType" -> "Value",
  "Value" -> heldOrJSONSafeValue,        (* 巨大値は束縛時に URI へ coercion 推奨 *)
  "WLType" -> "String",
  "PrivacyLevel" -> 0.75,
  "Source" -> "UserTyped" | "NotebookCell" | "VariableSnapshot" | "FileContent" | "StepOutput",
  "ContentHash" -> "sha256-..."|>
```

Source 別の PrivacyLevel 既定:

| Source | 既定 |
|---|---|
| `UserTyped` | task 文字列と同じ扱い（プロンプト既出前提。`PromptPrivacyMax` に合流） |
| `NotebookCell` | NBAccess のセル判定（Confidential 等）を継承 |
| `VariableSnapshot` / `FileContent` | snapshot 作成時の判定。判定不能なら 0.85（fail-closed） |
| `StepOutput` | 生成元 step の PrivacyEstimate を継承 |

裸の値（envelope なし）を受けた境界は `Source->"UserTyped"` 相当で包む。**無条件 0 扱いは廃止**（v0.1 §6.4 を置換）。

### 4.5 PortBindingRef（**新・P0: typed handle**）

TaskSpec の入力・Binding UI・wiring 束縛に入る値の正規形。「何を渡したか」を identity / snapshot 方針 / privacy 付きで確定する:

```wl
<|"ObjectClass" -> "SourceVaultPortBindingRef",
  "BindingKind" -> "URI" | "NotebookCellRef" | "PromptRunRef" |
                   "VariableRef" | "FileRef" | "LiteralValue",
  "URI" -> "sv://artifact/..." | Missing[],       (* snapshot 済みなら必須 *)
  "SnapshotPolicy" -> "SnapshotNow" | "LiveAtExecution" | "PinnedSnapshot",
  "Identity" -> <|...BindingKind 別（下表）...|>,
  "Preview" -> <|"Text" -> "...", "Redacted" -> True|False|>,
  "PrivacyLevel" -> _Real,
  "Provenance" -> <|"NotebookRef" -> _, "CellUUID" -> _, "RunId" -> _|>|>
```

| BindingKind | Identity | 既定 SnapshotPolicy / 意味 |
|---|---|---|
| `URI` | canonical sv:// URI | そのまま（envelope へ正規化） |
| `NotebookCellRef` | notebook ref + cell UUID + cell content hash | **`SnapshotNow`**。セル内容＋履歴 metadata を artifact 化 |
| `PromptRunRef` | PromptRun / ClaudeEval / WorkflowRun の immutable run id | immutable（snapshot 不要） |
| `VariableRef` | kernel/session id + symbol 名 | **`SnapshotNow`（値を snapshot artifact 化）**。名前の遅延解決（`LiveAtExecution`）は**明示時のみ**——変数名は session と時刻に依存し危険。trace の正は常に「その時点の値 snapshot URI」 |
| `FileRef` | path identity（＋任意で content hash） | 既定は **path identity のみ**。本文が要るときは別途 `SnapshotNow` で artifact 化し release gate を通す（`ReferenceOnly` / `CopyToArtifact` / `HashOnly` を UI で選択、§7.4） |
| `LiteralValue` | content hash | ValueEnvelope（§4.4）として保持。小さくても privacy label を持つ |

### 4.6 api.md への契約表記（v0.3 §4.4 chunk grammar の追加キー）

`ClaudeUpdateDocumentation` は registry から規約キーを描画（人間可読＋chunker が機械抽出）:

```markdown
### SourceVaultMailView[query, opts]
...usage...
→ Association (URI envelope, Mail/Text)
CallForm: SourceVaultMailView[query_String, OptionsPattern[]]
Options: Period (Integer|Quantity, 既定 7, alias: PeriodDays), OpenTodos (Boolean|Missing)
Requires: SourceVaultInitialize, SourceVaultMailEnsureIndex
Reads: $SourceVaultRoots | Writes: $SourceVaultMailIndexCache
Inputs: query:Value(String, required), source:URI(Mail, optional, PL≥0.5)
Outputs: result:URI(Artifact, Mail/Text)
Entrypoint: UserFacing (recommended) | Supersedes: showMails
```

- 正は registry。乖離は `StaleContract`（W8）。契約キーなし chunk は従来通り（W1）。

### 4.7 TaskSpec（入力リスト → 出力リストの抽象）

```wl
<|"ObjectClass" -> "SourceVaultTaskSpec",
  "Task" -> "受信メールを要約して画像付きでノートブックへ",
  "Inputs" -> { PortBindingRef .. },                (* §4.5。生値は境界で正規化 *)
  "Outputs" -> { <|"Name"->_, "PortType"->_, "DomainKind"->_, "MediaKind"->_|> .. },
  "Steps" -> {"SourceVaultMailView", ...} | Automatic,   (* Automatic の選定規約は §6.2 *)
  "WiringMode" -> "Deterministic" | "LLM" | "Hybrid"|>   (* 既定 Hybrid *)
```

既存プロンプト入力 Association（`OriginalTask`/`Hint`）は degenerate case として吸収（`Inputs` 未宣言＝従来挙動）。

### 4.8 共通 Failure schema（**新・P2**）

契約系の失敗はすべてこの形（LLM repair / UI 表示の安定契約）:

```wl
Failure[tag_String,   (* "UnknownOption" | "UnknownSymbol" | "ArgumentCount" |
                         "OptionValueType" | "DeprecatedAlias" | "InitCycle" |
                         "InitFailed" | "UnresolvedBinding" | "AmbiguousAdapterPath" |
                         "PrivacyGateDenied" | "ForbiddenHead" | ... *)
  <|"Symbol" -> "SourceVaultUpcomingSchedule",
    "Detail" -> <|"Option" -> "ForceRefresh", "AllowedOptions" -> {...}|>,
    "RepairHints" -> {                            (* machine-readable。LLM/Repair 用 *)
      <|"Action" -> "ReplaceOption", "From" -> "ForceRefresh", "To" -> "Refresh",
        "Confidence" -> "High"|> },
    "SuggestedReplacement" -> "Refresh"|>]
```

- `Status` キーを返す API は `"OK" | "AlreadyInitialized" | "Incomplete" | "Failed"` に固定し、`"Failed"` 時は `"Failures" -> {上記 Failure ..}` を必ず同梱。

---

## 5. 冪等初期化プロトコル

### 5.1 `"InitMode"` オプション規約

```wl
Options[SourceVaultInitialize] = {..., "InitMode" -> "Force"};
(* "Force"  : 本来の初期化を常に実行（現行挙動。直接呼びの既定） *)
(* "Ensure" : InitializedQRef 述語が True なら副作用ゼロで
              <|"Status"->"AlreadyInitialized",...|> を返す *)
```

- 直接呼びの既定は `"Force"`（要望どおり）。wiring / DAG 解決（§5.3）は契約の `DefaultInitModeForWiring`（既定 `"Ensure"`）を使う。
- **Scaffolded テンプレート（§8.3）には必ず `SourceVaultEnsureInitialized[...]` を前置きし、生の `Init[..., "InitMode"->"Force"]` を出さない**（小型モデルの再初期化事故防止。golden G-tier-1）。
- 返り値は Association（§4.8 準拠）。例外は投げない（throw 型は Failure 化して包む）。

### 5.2 既存初期化関数の適合方針

| 現状 | 例 | 対応 |
|---|---|---|
| 事実上冪等 | `SourceVaultInitialize`/`iEnsureRoots`/`iEnsureClaudeWorkingDirectory`/`iEnsureCellEpilog`/`iEnsureSharedPollingTask`/`iEnsureParallelKernelsForRuntime` | InitContract 登録＋`InitializedQRef` 述語切り出しのみ |
| **非冪等** | `iEnsureDefaultSession`（claudecode.wl:4547） | `"Ensure"` で「アクティブセッション再利用」。新規作成は `"Force"` のみ |
| 失敗時例外 | `iEnsureCUDAExtension`（claudecode.wl:16404） | Failure 包み＋`ReinitSafe` 明記 |
| 読み取り専用 | `iLoadPaletteSettings` | Init 契約対象外（Reads 宣言のみ） |

### 5.3 依存 DAG 解決＋reentry guard（**強化・P1**）

```wl
SourceVaultEnsureInitialized[symbolOrContract, opts]
(* 1. Requires を推移的に収集（循環は Failure["InitCycle", <|"Path"->...|>]） *)
(* 2. トポロジカル順に各 Init を DefaultInitModeForWiring（既定 Ensure）で実行 *)
(* 3. 返り値: <|"Status", "Executed"->{...}, "Skipped"->{...}, "Failed"->{...}|>、fail-fast *)

SourceVaultInitPlan[symbol]   (* dry-run: 実行順リストのみ *)
```

- **reentry guard**: `Provides` キー単位の in-progress marker（`$SourceVaultInitInProgress`）。同一 kernel 内の再入（Dynamic / scheduled task / poll-tick からの重複呼び出し）で同じ Init が同時二重実行されない。marker が立っている間の後続 `"Ensure"` は「実行中」として skip し `"Skipped"` に積む。background/scheduled task・parallel kernel を考慮し「ロック不要」前提（v0.1）を撤回。kernel 跨ぎの排他は各 Init の実装責務（既存の transaction 排他を使う）で、本層は少なくとも**同一 kernel 内で二重 session / 二重 scheduled task を作らない**ことを保証（golden G-init-1）。

---

## 6. 選定・検証・接続（Wiring）

パイプライン全体: **選定（§6.2）→ 束縛（§6.3–6.5）→ 式生成 → 検証（§6.1）→ propose（§6.7）**。実行は承認経路の先にのみある。

### 6.1 Call expression validation / normalization / repair（**新・P0**）

```wl
SourceVaultValidateCallExpression[heldExpr, opts]
(* <|"Status"->"OK"|"Failed", "Failures"->{§4.8 Failure..}|>。判定項目:
   - head が契約登録済みか（未登録は opts "UnknownSymbolPolicy" 既定 "Pass"=契約外関数は素通し、
     "Reject"=契約必須モード）
   - 使用 CallForm が UseForClaudeEval->True か
   - 引数個数・Kind（Positional/OptionalPositional）・WLType 適合
   - option 名が OptionContracts に実在するか（UnknownOptionPolicy 既定 Reject）
   - option 値が ValueType / AllowedValues に適合するか
   - deprecated symbol/option alias の検出（RepairHints 付き）
   - forbidden head / unsafe expression の混入（既存の NBAccess/Runtime 検査と重複可。二重は許容） *)

SourceVaultNormalizeCallExpression[heldExpr, opts]
(* alias→canonical の決定的書き換えのみ（symbol alias, option alias）。
   書き換えは trace に記録。意味を変える修復はしない *)

SourceVaultRepairCallExpression[heldExpr, opts]
(* Normalize + RepairHints の適用（unknown option→最近傍 allowed option の提案は
   "SuggestOnly" 既定。自動置換は opts で opt-in）。残余 Failures を返す *)

SourceVaultExplainCallContract[symbol]
(* CallForms/OptionContracts/Requires を人間・LLM 可読に整形（tier 対応 §8.3） *)
```

- **配置**: 実装は SourceVault 側。ClaudeRuntime の proposal validation 前段に hook `$ClaudeCallContractValidator`（ClaudeRuntime 所有、`None` 既定、SourceVault がロード時登録、rule 11 / v0.3 §5.5 と同型）で差し込む。**ClaudeEval が提案したすべての式は、実行前にこの検証を通る**（unknown option は実行前に §4.8 の `UnknownOption` Failure で拒否され、候補 option が返る。golden G-call-1）。
- 検証は純関数（副作用・評価なし。`Hold` のまま構文解析）。

### 6.2 関数選定: `SourceVaultSelectFunctionsForTask`（**新・P0**）

`TaskSpec["Steps"]->Automatic` の規約。LLM に自由生成させる前に、決定的・retrieval 由来の候補を固定する:

```wl
SourceVaultSelectFunctionsForTask[taskSpec, opts]
(* -> <|"Candidates" -> { <|"Symbol"->_, "Score"->_, "Reasons"->{...}|> .. },   (* ranked *)
        "Rejected"   -> { <|"Symbol"->_, "Reason"->_|> .. },                     (* 負の情報 *)
        "Clarifications" -> {...}|> *)                                            (* 要確認事項 *)
```

scoring（決定的・優先順固定）:

1. **候補生成**: KeywordBM25V1（task × IntentExamples/usage/CapabilityTags）＋related expansion（§8.2）＋TaskSpec の Inputs/Outputs と契約ポートの適合（DomainKind/MediaKind）。
2. **boost**: `RecommendedEntrypoint->True`・`AbstractionLevel->"UserFacing"`・CapabilityTags 完全一致・ポート適合。
3. **penalty / 除外**: `AbstractionLevel->"Internal"` は**既定除外**（opts 明示時のみ候補入り）。`Supersedes` 該当（旧 alias）は canonical へ差し替えて rejected に旧名を理由付きで残す。`NegativeExamples` に task が一致したら rejected（Reason はそのまま提示——**モデルには「使うな＋理由」が効く**）。`DoNotUseWhen` 一致も同様。
4. **閾値**: score 閾値未満は候補 0 件を許す（v0.3 §8.2 と同思想。無関係関数を無理に選ばない→ Clarifications へ）。
5. **LLM の役割**: LLM に渡すのは Candidates＋Rejected（理由込み）のみで、**リスト外の symbol を選ばせない**（schema 制約: enum 選択）。（v0.1 Q5 をこれで解決）

### 6.3 URI coercion / Port adapter（**cost 探索化・P1**）

```wl
SourceVaultCoerceToURI[value|bindingRef, opts]     (* deposit→URI envelope。冪等 *)
SourceVaultCoerceFromURI[envelope, targetWLType, opts]   (* gate 越し resolve *)
SourceVaultRegisterPortAdapter[fromPortSpec, toPortSpec, f, meta]
(* meta: <|"Cost"->1, "Lossy"->False, "PrivacyEffect"->"Preserve"|"Floor"->x|> *)
```

adapter 探索は深さ 1 固定（v0.1）を撤回し、**cost 付き経路探索**にする:

```wl
"AdapterPolicy" -> <|"MaxDepth" -> 2, "MaxCost" -> 3,
  "AllowLossy" -> False, "RequireUniquePath" -> True|>   (* 既定値。数値は Q2 *)
```

- `NotebookCellRef → URI(artifact) → Value(Text)` のような 2 段の自然変換を許容。
- **経路が複数見つかったら `Unresolved`**（`AmbiguousAdapterPath` Failure、候補 path 提示）。lossy 変換は既定禁止。
- 組み込み adapter 初期セット: Value↔URI(artifact)、NotebookCellRef→URI、FileRef→URI(content snapshot)、URI→NotebookCell rendering、envelope 正規化。各 adapter は Cost/Lossy/PrivacyEffect を宣言。

### 6.4 決定的 port binding

`SourceVaultProposeWiringPlan`（§6.7）内の束縛規則（**優先順固定・上から**）:

1. **ポート名完全一致**（TaskSpec 入力名 = 契約 Input 名）
2. **DomainKind 一致**（URI/BindingRef の DomainKind = ポート宣言）
3. **MediaKind 一致**
4. **WLType 一意一致**（Value ポートで候補が型的に 1 つのみ）
5. **adapter 経路（§6.3 policy 内・一意 path）挿入で 1–4 が成立**

- 一意に決まらないポートは推測せず `Unresolved`（候補付き）。Required 入力が Unresolved で `"WiringMode"->"Deterministic"` なら `Status->"Incomplete"`。
- WiringPlan schema（v0.1 §6.2）は継続。`Bindings.From` に PortBindingRef を許容、`"FilledBy"->"Deterministic"|"LLM"|"User"` を各 binding に記録。

### 6.5 LLM wiring モード（Hybrid の残余埋め）

- 入力: `Unresolved` エントリ＋候補の契約要約（§8.3 tier 適用）。候補提示は **URI/BindingRef の identity と DomainKind/Preview（Redacted 可）のみ、データ本文は渡さない**。
- 出力: 固定 JSON schema（binding 列挙のみ・候補からの選択のみ）。
- **validate-then-accept**: §6.4 の型/Kind 検証を通った binding だけ採用。不合格は破棄して Unresolved のまま。`"FilledBy"->"LLM"` を記録（observability は v0.3 §5.7 の 3 段、cloud prompt に出さない）。

### 6.6 privacy 事前見積

- `PrivacyEstimate` = 束縛された **URI envelope＋ValueEnvelope＋PortBindingRef 全部**の PrivacyLevel の Max、＋契約 `PrivacyFloor` の下限伝搬。
- `SourceVaultEstimateOutputPrivacy`（mcp.wl:169）の入力形式（`PromptPrivacyMax` 等）へ変換して再利用（v2 spec の ObservedInputRisk と接続）。
- 見積りは advisory。egress の NBAuthorize / release gate が最終判定（W5）。

### 6.7 propose / validate / execute 三層（**新・P1、v0.1 §6.5 を置換**）

```wl
SourceVaultProposeWiringPlan[taskSpec, opts]
(* 選定＋束縛＋各 step の未評価 call expression 生成。純データ。実行しない *)

SourceVaultValidateWiringPlan[plan, opts]
(* 各 step 式に §6.1 validation、束縛の型/privacy 検査、InitPlan の解決可能性。
   -> <|"Status"->"OK"|"Incomplete"|"Failed", "Failures"->{...}|> *)

SourceVaultWiringPlanExpression[plan]
(* plan 全体を 1 つの未評価 WL 式（EnsureInitialized 前置き＋step 列）に整形。
   ClaudeEval / Runtime の提案式としてそのまま流せる形 *)

SourceVaultExecuteWiringPlan[plan, opts]
(* 直接実行は manual / tests / 承認済み workflow 用の実行層。
   required input 未充足時の既定は "OnMissingInput"->"Return"：実行せず
   <|"Status"->"AwaitingInput", "InputBlockSpec"->...|> を返すだけで、
   notebook には一切触らない（service kernel / test / batch で安全）。
   各 step: EnsureInitialized → 束縛（coercion/adapter）→ 実行 → 出力を URI envelope 化。
   Effects に NotebookWrite/FileWrite/Network/LLMCall を含む step は既存承認ゲートを経由。
   途中失敗は Failure＋そこまでの StepResults（URI で残る） *)
```

責務分離（r2 P0-1）: **Execute は notebook 挿入の副作用を持たない**。`AwaitingInput` を受けて `WorkflowInputBlock` を挿入するのは notebook-facing wrapper の `SourceVaultRunWorkflow`（§7.4.1、`"OnMissingInput"->"InsertWorkflowInputBlock"` 既定）だけ。挿入できない環境（headless 等）では `RunWorkflow` も `InputBlockSpec` を返すへ degrade する。

- **ClaudeEval 接続は Execute を呼ばない**。`Propose→Validate→WiringPlanExpression` で未評価式を返し、実行は既存の Runtime/NBAccess 検査・承認経路に委ねる（W9。PromptRouter 統合仕様の propose/execute 分離と整合）。
- 出力正規化: 契約 `Outputs` が URI なのに生値を返すレガシー実装は実行層が `SourceVaultCoerceToURI` で包む（W3 の強制点）。

---

## 7. ノートブック境界（初段・最終段・Binding UI）

### 7.1 初段: `SourceVaultCellInput`

```wl
SourceVaultCellInput[nb, opts]   (* 選択セル/指定セル群 → PortBindingRef 列 *)
```

- 返すのは **`NotebookCellRef`**（§4.5）: cell UUID＋content hash＋履歴 ref（`NBHistoryCreate` 系 tag）＋NBAccess 由来 PrivacyLevel。既定 `SnapshotNow` でセル内容を artifact 化し URI を持つ。
- 「直前の ClaudeEval 入出力」「過去の run」は `PromptRunRef` として同関数の opts で取得可能に。
- 既存 `iNormalizePrompt`（claudecode.wl:6904）は内側に残す。claudecode は hook `$ClaudeCellInputProvider` 越し（W7）。

### 7.2 最終段: `SourceVaultCellOutput`

- URI envelope を MediaKind 別に NB へ書き出し（Text→`iWriteQueryResponse` claudecode.wl:7531、Image→画像セル、他→要約＋URI リンクセル）。
- 書き出し前に NBAuthorize / release gate（最終判定）。書き出しは参照イベント `Rendered` として rollup に記録。

### 7.3 claudecode 側 hook

`$ClaudeCellInputProvider` / `$ClaudeCellOutputProvider` / `$ClaudeCallContractValidator`（§6.1）/ `$ClaudeBindingDialogProvider`（§7.4）。いずれも claudecode/ClaudeRuntime 所有・`None` 既定・SourceVault ロード時登録・未登録なら従来経路（rule 11、v0.3 §5.5 と同型の契約）。

### 7.4 入力確定と起動シーケンス: WorkflowInputBlock（**正本**）＋補助 Binding UI（**新・P1、r1 改訂反映**）

プロンプト履歴の「パラメータ置換ダイアログ」を文字列置換から typed binding へ置き換える。**正本は modal dialog ではなく、InputNotebook 上に挿入される `WorkflowInputBlock`（型付き入力フォームセル群）**。dialog / palette は候補選択・URI 挿入の補助 UI に格下げする。

#### 7.4.1 起動シーケンス（**式提案に統一**）

ワークフローの起動は専用 UI 経路を作らず、**式提案→通常のセル評価**に一本化する（W9）:

1. ClaudeEval / ユーザーは起動式を**未評価のまま**セルに置く（提案）:
   ```wl
   SourceVaultRunWorkflow["paper-summary"]          (* 保存済み plan/workflow を名前で *)
   SourceVaultRunWorkflow[plan_Association]          (* WiringPlan 直接 *)
   ```
   `SourceVaultRunWorkflow` 自体が FunctionContract 付きの UserFacing 関数であり、提案式として §6.1 検証を通る。**`SourceVaultRunWorkflow` と `SourceVaultSubmitWorkflowInput` は pilot 契約対象（§10 F2）に含める**（r2 P1-3）。最低限: `RecommendedEntrypoint->True`, `AbstractionLevel->"UserFacing"`, `Effects->{"NotebookWrite","WorkflowRun"}`, CallForm は `workflow:Positional(String|Association, required)＋OptionsPattern`, Outputs は `result:URI(optional)` と `awaitingInput:Value(Association, optional)` の 2 variant。`SubmitWorkflowInput` は `InputBlockId` 文字列だけでなく WorkflowInputBlock の URI / record も受けられる契約にする。
2. ユーザーがセルを評価 → required input が充足なら §6.7 の実行系へ（Effects 承認ゲート込み）。
3. **required input 未充足なら実行せず**、`RunWorkflow`（notebook-facing wrapper。§6.7 責務分離）が `WorkflowInputBlock` を notebook に挿入し `<|"Status"->"AwaitingInput", "InputBlockId"->...|>` を返す。
   **再評価 idempotency（r2 P1-1）**: 同一 notebook・同一 `PlanHash`・同一 unresolved input schema の**未提出 block が既にあれば新規 block は作らず**、既存 block へフォーカスして既存 `InputBlockId` を返す（G-ui-3）。plan の入力 schema が変わっていた場合は旧 block を `Status->"Superseded"` にして新 block を挿入する（G-ui-4）。
4. ユーザーはブロックを**通常のセル編集**で埋める（見て・編集して・保存して・再実行する、notebook らしい操作）。
5. ブロック内の実行ボタンまたは `SourceVaultSubmitWorkflowInput["wib-..."]` の評価で再開。**ボタンも登録済み式の評価であって隠れ実行ではない**（式提案経路を迂回する実行入口を作らない）。
6. 再開時: Collect（→ InputDraft）→ Validate → **validation green の後にのみ InputBundle として URI 化** → WorkflowRun に紐づけ → 実行（§7.4.2）。

#### 7.4.2 WorkflowInputBlock（typed 入力セル）と InputDraft / InputBundle

> **実装時変更（2026-07-02・ユーザー決定）**: 複数の入力セルをフォームとして編集させる方式は Mathematica の式中心の直観に反するため、**入力の正本を「連想引数つき Submit テンプレート式 1 セル」に変更**した。挿入されるのは header（port 説明）＋ `SourceVaultSubmitWorkflowInput["wib-…", <|"port" -> "", …|>]` の記入済みテンプレート 1 セルのみで、ユーザーは連想の `""` を値（生値 / "sv://…" / PortBindingRef）に書き換えて評価する。利点: 標準的な WL イディオム・入力が In[] 履歴に残る・headless でも同一経路。cell-level metadata（WorkflowInputCell）方式は後方互換の fallback として維持（連想に無い port はセルから collect）。以下の cell-level schema はその fallback の仕様として残る。

入力ブロックは表示フォームではなく typed artifact。metadata は **cell-level と block-level の二層**（r2 P0-3）:

**cell-level**（各入力セルの `TaggingRules`）:

```wl
<|"SourceVault" -> <|
  "ObjectClass" -> "WorkflowInputCell",
  "InputBlockId" -> "wib-...",
  "PortName" -> "Question", "ExpectedType" -> "String",
  "BindingKind" -> "LiteralValue",                  (* §4.5 の 6 kinds *)
  "SnapshotPolicy" -> "SnapshotNow"|>|>
```

**block-level**（notebook `TaggingRules` または block 先頭の metadata cell。**セル群が 1 つの入力ブロックであることを機械的に復元できる**のが要件）:

```wl
<|"ObjectClass" -> "WorkflowInputBlock",
  "InputBlockId" -> "wib-...", "WorkflowId" -> "...",
  "PlanHash" -> "sha256-...", "InputSchemaHash" -> "sha256-...",
  "Status" -> "Draft" | "Submitted" | "Superseded" | "Invalid",
  "CellUUIDs" -> {...},
  "LastInputBundleURI" -> Missing[] | "sv://bundle/...",
  "CreatedAt" -> _, "UpdatedAt" -> _|>
```

`PlanHash`/`InputSchemaHash` が §7.4.1 の idempotency（重複挿入防止・Superseded 判定）の鍵。

**語彙の分離（r2 P0-2）**: 未検証のセル内容は **InputDraft**、検証 green 後にのみ作られる不変 snapshot が **InputBundle**。

```wl
SourceVaultInsertWorkflowInputBlock[nb, plan]      (* Unresolved/required port 分のセル群＋block metadata を挿入 *)
SourceVaultCollectWorkflowInput[nb, inputBlockId]  (* セル群 → InputDraft（PortBindingRef 列。NBAccess 経由） *)
SourceVaultValidateWorkflowInput[inputDraft, plan] (* §6.4 型/Kind 検証＋privacy 見積 → validation report。永続化しない *)
SourceVaultCreateInputBundle[inputDraft, plan]     (* validation green の後だけ sv://bundle/... を作る *)
SourceVaultSubmitWorkflowInput[inputBlockIdOrRef]  (* Collect → Validate → CreateInputBundle → Resume。
                                                      InputBlockId 文字列 / WorkflowInputBlock URI・record を受理 *)
```

- **InputBundle**: 検証済み・不変 snapshot。既存 `bundle` namespace を再利用し `sv://bundle/<opaqueId>`（新 URI namespace は増やさない——W6/v2 整合、Q11 解決）。**subtype sidecar を必須**とし、EvidenceBundle 等と混同させない（r2 P1-2）:

  ```wl
  <|"ObjectClass" -> "SourceVaultInputBundle",
    "BundleKind" -> "WorkflowInput",               (* 必須 subtype *)
    "DomainKind" -> "WorkflowInput",
    "TargetWorkflowId" -> "...", "PlanHash" -> "...",
    "InputBlockId" -> "wib-...", "InputPorts" -> {...}|>
  ```

  WorkflowRun に URI で紐づくため、**再実行・監査・入力差し替えが URI 単位**でできる。生成後は block metadata の `LastInputBundleURI` と `Status->"Submitted"` を更新。
- 入力セルの PrivacyLevel は §4.4/§4.5 の規約どおり（cell 由来は NBAccess 判定継承）。

#### 7.4.3 補助 Binding UI（dialog / palette）

`SourceVaultBindingResolutionDialog[plan|taskSpec, nb, opts]` は候補選択・URI 挿入の補助に限定。必須機能:

- Unresolved port ごとに候補を **PortBindingRef として型・Preview（Redacted 可）・PrivacyLevel・snapshot/live** 付きで表示。
- `SnapshotNow` / `LiveAtExecution` / `PinnedSnapshot` の選択。**変数**は現在値 preview＋content hash を表示し**既定で snapshot artifact 化**。**ファイル**は `ReferenceOnly` / `CopyToArtifact` / `HashOnly` を選択。
- 確定のたびに `SourceVaultValidateWiringPlan` を再実行し、残る未解決・不正 option を即時表示（G-ui-1）。選択結果は WorkflowInputBlock のセルへ書き戻す（正本は常に notebook 側）。
- ユーザー確定 binding は `"FilledBy"->"User"`（LLM 充填より優先）。
- UI 実装は claudecode パレット側（hook 越し）。SourceVault は候補列挙・検証・セル読み書き（NBAccess 経由）の関数を提供する。

---

## 8. MCP 検索 DB の更新

### 8.1 `view=contract`

- `packageapi` chunk に契約フィールドを追加: `callForms, optionContracts, unknownOptionPolicy, requires, reads, writes, inputs, outputs, effects, idempotent, costClass, abstractionLevel, capabilityTags, supersedes, contractVersion`。
- `sourcevault_get uri view=contract` → 契約 Association（本文なし・PrivacyLevel 0・grant 不要）。**`InitializedQRef` 等は symbol 名文字列のみ**（W10。評価可能式は出さない）。
- `view=summary|body|source` は v0.3 のまま。

### 8.2 Related candidates（ranked 候補リスト）

`sourcevault_search kinds:["packageapi"] expand:"related"`（v0.1 継続）。Relation に選定メタデータ由来を追加:

```wl
"Relation" -> "Composable"          (* Output の DomainKind/MediaKind が相手 Input に適合（契約から決定的） *)
            | "AliasCanonical"      (* Supersedes / deprecatedAlias → 正準 *)
            | "UseInsteadOf"        (* 契約の UseInsteadOf 宣言（理由文字列同梱） *)
            | "SameCapability"      (* CapabilityTags 共有 *)
            | "SameSection" | "RequiresNeighbor" | "SimilarUsage"
```

- 並び: 固定重み Composable > AliasCanonical > UseInsteadOf > SameCapability > SameSection > RequiresNeighbor > SimilarUsage、各×スコア。
- ranking 全体への追加 signal: `RecommendedEntrypoint`/`AbstractionLevel->"UserFacing"` boost、`Internal` penalty、`NegativeExamples` 一致は結果に `"Discouraged"->reason` を付けて返す（隠さず負の情報として提示）。
- push（v0.3 §5.4）は不変。related expansion は pull 専用。

### 8.3 モデル粒度 profile（DocGranularityProfile）

PromptDeliveryProfile（mcp.wl:137）解決に `DocGranularity` を追加:

| tier | 対象例 | chunk 描画内容 |
|---|---|---|
| `"Expert"` | Fable/Opus/Sonnet | signature＋usage 要約＋**OptionContracts 表（allowed 一覧）** |
| `"Guided"` | 中位（Haiku/大型ローカル） | ＋実行例 1＋Requires 一覧＋ReturnVariants |
| `"Scaffolded"` | qwen3.6-27b 等 | ＋**コピペ可能テンプレート**（`SourceVaultEnsureInitialized[...]` 前置き必須・§5.1）＋**allowed options のみを明示列挙**（それ以外の option は存在しない旨を一文で）＋deprecated alias→正準の対応＋Outputs の具体形＋よくある誤り列 |

- **全 tier で「OptionContracts にある option だけを描画」**（幻 option の供給源を断つ。golden G-tier-1: Scaffolded テンプレートに allowed options 以外が出ない）。
- 実装: chunk store に `ExamplesByTier`。tier 解決は `ClientProfile`（v0.3 §5.5）から、解決順は AccessProfile と同じ exact→wildcard→default。未知モデルは `"Scaffolded"`（安全側）。push top-k は tier で減衰（Expert 6 / Guided 4 / Scaffolded 2、数値 Q2）。
- 将来（F7・任意）: MCPCall＋ObjectSignals から (modelId, symbol) 別エラー率を集計し自動 tier 昇格。v0.2 では手動表のみ。

### 8.4 インクリメンタルスキャン＋契約 audit（**強化・P1**）

増分再チャンク（per-file `SourceMTimeToken`＋`ContractSourceHash`、pkg 単位 atomic replace）は v0.1 継続。これに **registry vs 実装の audit** を追加する:

```wl
SourceVaultAuditFunctionContracts[pkg | All, opts]
(* 検査項目（すべて §4.8 Failure 形で報告）:
   - Symbol が Names[] に実在
   - Options[Symbol] と OptionContracts の差分（実装にあって契約にない/逆）
   - CallForms の必須引数個数が DownValues パターンと整合
   - Requires の全 init symbol が Kind->"Init" 契約として存在
   - InitializedQRef / EnsureFunction の symbol 実在（rename drift 検出）
   - RecommendedEntrypoint->True の関数に Scaffolded テンプレートが存在
   - DeprecatedAliases/Supersedes が related ranking で canonical へ誘導される
   - 全 example / テンプレート式が SourceVaultValidateCallExpression を通る *)
```

- 実行タイミング: (a) 索引 build 時（失敗は build report に記録、`StaleContract` 付与）、(b) `ClaudeUpdateDocumentation` の docs build report に audit 結果を同梱、(c) 手動/CI。
- **audit Fail の扱い**: doc 配信は止めない（W8 可用性優先）が、当該 symbol は ranking penalty＋`view=contract` に `"AuditStatus"->"Failed"` を明示。契約 DB が実装と乖離したまま「正」を装うことを防ぐ。

---

## 9. セキュリティ / privacy

- 契約・chunk・related 情報は PrivacyLevel 0 の doc（v0.3 §9 準拠）。契約の `PrivacyFloor` は下限伝搬として wiring 見積りに入る。
- URI envelope / PortBindingRef は本文を持たない。resolve は常に release gate 越し（v2 spec の既存 gate）。
- **Value も privacy 対象**（§4.4）。literal・変数値・ファイル内容を 0 扱いしない。VariableRef の正は「値 snapshot URI」（名前 live 解決は明示時のみ、§4.5）。
- LLM（選定 §6.2 / wiring §6.5）に渡すのは契約要約＋identity/Preview のみ。**データ本文・実パス・評価可能式は渡さない**（W10）。LLM 出力は schema＋型検証通過分のみ採用。
- ClaudeEval 経路は propose/validate のみ（W9）。Effects 付き step の実行は既存承認ゲート。NB 書き出しは NBAuthorize が最終 gate。
- observability は v0.3 §5.7 の 3 段（WiringPlan の実パス・スコア・FilledBy 詳細は local log / developer trace）。

---

## 10. 段階実装計画

前提: v0.3 の Inc1（chunker/索引）・Inc3（view/projection）が先行または並走。**F1–F4 は v0.3 に依存しない**（先行着手可）。

| Inc | 内容 | 受け入れ（wolframscript + NB 検証） |
|---|---|---|
| **F0** | schema freeze: FunctionContract（CallForms/OptionContracts/selection metadata）/InitContract（ref 化）/URI envelope taxonomy/ValueEnvelope/PortBindingRef/TaskSpec/WiringPlan/Failure schema＋束縛規則＋tier 表 | 本仕様 r2 収束（golden 期待値込み） |
| **F1** | 冪等初期化: `"InitMode"`＋`InitializedQRef` registry＋`EnsureInitialized`/`InitPlan`＋reentry guard。適合: §5.2 表 | Ensure×2 で 2 回目 `AlreadyInitialized`・状態不変。Force は現行一致。循環→`InitCycle`。**G-init-1**: 再入で session/scheduled task が二重作成されない |
| **F2** | 契約 registry＋pilot 契約 ~20 本（**`SourceVaultRunWorkflow`/`SubmitWorkflowInput` 自身を含む**・r2 P1-3）＋**`SourceVaultValidateCallExpression`/Normalize/Repair/Explain**＋**`SourceVaultAuditFunctionContracts`** | audit 全 green（Options[sym] 差分ゼロ）。**G-call-1**: 幻 option→`UnknownOption` 拒否＋候補。**G-call-2/3**: deprecated symbol/option alias→canonical へ normalize＋trace |
| **F3** | typed binding: URI coercion＋ValueEnvelope＋PortBindingRef＋adapter cost 探索（§6.3） | round-trip・PrivacyLevel 保存・gate 拒否形。**G-bind-1/2/3**（セル=UUID+hash+privacy / 変数=既定 snapshot URI / ファイル=identity と content 区別）。**G-privacy-1**: literal private text が estimate に伝播。複数 adapter path→`AmbiguousAdapterPath` |
| **F4** | 関数選定（§6.2）＋決定的 wiring＋propose/validate 三層（§6.7）＋NB 境界（§7.1–7.3）＋ClaudeRuntime hook 接続（§6.1 validator） | golden: mail 要約 2-step が Deterministic で propose→validate green、ClaudeEval には未評価式のみ返る。**G-select-1**: user-facing API が top・低レベルは下位/rejected（理由付き）。negative: 曖昧束縛は `Unresolved` |
| **F5** | LLM wiring（§6.5）＋**WorkflowInputBlock 起動シーケンス＋補助 Binding UI**（§7.4） | Unresolved のみ LLM 充填・不正 binding 破棄（negative golden）。qwen 系で schema 出力が通る。**G-ui-1**: 補助 UI 解決→validate green。**G-ui-2**: required 未充足で起動式評価→実行されず InputBlock 挿入、Submit 後 validate green＋InputBundle URI が WorkflowRun に紐づく。**G-ui-3/4**: 再評価 idempotency（増殖なし / Superseded） |
| **F6** | MCP: 契約フィールド索引＋`view=contract`＋related（§8.2 拡張 Relation）＋tier 描画（§8.3）＋増分スキャン＋audit 連携（§8.4） | `view=contract` 一致（ref は名前のみ）。related: `showMails`→`SourceVaultMailView` AliasCanonical top。**G-tier-1**: Scaffolded に EnsureInitialized 前置き＋allowed options のみ。drift→`StaleContract`、audit fail→`AuditStatus` 明示 |
| **F7**（任意） | エラー率フィードバックで tier 自動昇格 | (modelId,symbol) 集計ローカル保存・閾値超で Scaffolded 化 |

### 10.1 Golden（抜粋・F0 で数値確定）

v0.1 分（mail 2-step 合成 / 曖昧束縛 negative / Ensure 副作用ゼロ / related / tier 描画差）に加え、r1 §13 を全採用:

| ID | テスト | 期待 |
|---|---|---|
| G-call-1 | 存在しない option を含む提案式 | 実行前に `UnknownOption` 拒否・AllowedOptions と SuggestedReplacement を返す |
| G-call-2 | deprecated alias 関数（`showMails`） | canonical symbol へ normalize |
| G-call-3 | option alias（`PeriodDays`） | canonical option へ normalize・trace 記録 |
| G-select-1 | 「Todo が残っている予定」 | user-facing schedule API が top、低レベル extractor は下位/rejected（理由付き） |
| G-bind-1 | 選択セルを入力 | cell UUID＋snapshot hash＋privacy を持つ `NotebookCellRef` |
| G-bind-2 | 変数 `x` を入力 | 既定で値 snapshot URI。名前 live 解決は明示時のみ |
| G-bind-3 | file path を入力 | path identity と content snapshot が区別される |
| G-privacy-1 | literal private text 入力 | ValueEnvelope の privacy が出力 estimate に伝播 |
| G-ui-1 | unresolved port を補助 UI で解決 | 解決後 plan が deterministic validation green（結果は notebook セルへ書き戻る） |
| G-ui-2 | required input 未充足で `SourceVaultRunWorkflow` を評価 | 実行されず `AwaitingInput`＋WorkflowInputBlock 挿入。Submit 後 validate green・InputBundle URI が WorkflowRun に紐づく |
| G-ui-3 | required 未充足の同一起動式を 2 回評価 | InputBlock は 1 個だけ。2 回目は既存 `InputBlockId` を返す |
| G-ui-4 | plan の入力 schema 変更後に再評価 | 旧 block は `Superseded`、新 block を挿入 |
| G-init-1 | Ensure 同時再入 | scheduled task / session が二重作成されない |
| G-tier-1 | LM Studio Scaffolded | テンプレートに `EnsureInitialized` 前置き＋allowed options のみ |

---

## 11. 未解決論点（r2 レビュー対象）

- **Q1 契約の正の置き場**: pkg 別 contracts ファイル（現案）vs in-source 注釈。→ 起草者推奨: contracts ファイル（決定的パース・rule 03 整合）。r1 で異論なし、r2 で確定したい。
- **Q2 数値**: pilot 契約本数（~20?）、tier 別 push k（6/4/2?）、Scaffolded テンプレート最大 chars、AdapterPolicy 既定（MaxDepth 2 / MaxCost 3?）、選定 score 閾値。
- **Q3 URI/binding 強制の厳格度**: v0.2 は「validation/wiring 層で強制、直呼びは素通し」。契約付き関数の直呼びにも警告する実行時フックは将来。
- **Q4 Reads/Writes の検証**: 宣言のみ（v0.2）。テストモードでの実測トラップは audit の将来拡張。
- **Q7 tier 初期割当表**: provider/modelId 具体列挙（LM Studio は `/api/v0/models` の何を鍵に）。
- **Q8（新）ValueType 記法**: OptionContracts の `ValueType` を文字列パターンにするか `Hold` なし WL パターン式にするか。MCP 投影（W10）と `MatchQ` 検証の両立が条件。→ 起草者案: 制限付き文字列 DSL（`"Integer|Quantity[_,\"Days\"]"`）＋SourceVault 側で安全にパース。
- **Q9（新）契約外関数の混在**: WiringPlan の step に契約なし関数を許すか。→ 起草者案: 許す（`"UnknownSymbolPolicy"->"Pass"`）が、plan の `Coverage` に契約カバー率を明示し、Scaffolded tier では契約付き関数のみ提案。
- ~~Q10 Binding UI の実装形態~~ → §7.4 で解決（正本＝notebook 上の WorkflowInputBlock、dialog/palette は補助。起動シーケンスは式提案に統一）。
- ~~Q11 InputBundle の namespace~~ → r2 で解決: 既存 `bundle` 再利用は妥当と判定。ただし **`BundleKind->"WorkflowInput"` 等の subtype sidecar を必須**とし EvidenceBundle と混同させない（§7.4.2）。
- ~~Q5 Steps 選定の LLM 契約~~ → §6.2 で解決（候補リスト内 enum 選択のみ）。
- **Q6 ClaudeOrchestrator との関係**: WiringPlan→Workflow 変換は別仕様（runtime-orchestrator-boundary 準拠）。据え置き。

---

## 12. Freeze 前チェックリスト

- [x] `CallForms` / `OptionContracts` / `RecommendedEntrypoint` が FunctionContract にある（§4.1）
- [x] `SourceVaultValidateCallExpression` が unknown option を実行前拒否（§6.1、G-call-1）
- [x] `Options[symbol]` と契約の差分 audit（§8.4）
- [x] `Steps->Automatic` の selection scoring 定義（§6.2）
- [x] NotebookCell / PromptRun / Variable / File の binding kind 定義（§4.5）
- [x] Value 入力の privacy label（§4.4）
- [x] `SourceVaultCellInput` が cell UUID / content hash / history ref を返す（§7.1）
- [x] 入力 UI を typed binding editor として仕様化——正本は WorkflowInputBlock、dialog は補助（§7.4）
- [x] required input 未充足時に WorkflowInputBlock を InputNotebook へ挿入する実行フロー（§7.4.1、G-ui-2）
- [x] WorkflowInputBlock から InputBundle URI を生成し WorkflowRun と結びつける（§7.4.2）
- [x] ClaudeEval 接続は propose / validate 経路・**起動シーケンスも式提案に統一**（§6.7、§7.4.1、W9）
- [x] `ExecuteWiringPlan` は既定で notebook 挿入しない——挿入は `RunWorkflow` wrapper（§6.7、r2）
- [x] `InputDraft` / `InputBundle` の語彙分離（未検証 vs 検証済み不変 snapshot）（§7.4.2、r2）
- [x] WorkflowInputBlock の block-level metadata schema（lifecycle/PlanHash/CellUUIDs）（§7.4.2、r2）
- [x] 同一起動式の再評価で未提出 block が増殖しない・schema 変更で `Superseded`（§7.4.1、G-ui-3/4、r2）
- [x] `SourceVaultRunWorkflow`/`SubmitWorkflowInput` 自身が pilot 契約対象（§7.4.1、§10 F2、r2）
- [x] InputBundle は `sv://bundle/...` でも `BundleKind->"WorkflowInput"` subtype 必須（§7.4.2、r2）
- [x] Scaffolded テンプレートが allowed options のみ（§8.3、G-tier-1）
- [x] registry / MCP view に評価可能コードを置かない（§4.2、W10）
- [ ] Q2/Q7/Q8 の数値・記法確定 — r2
- [ ] golden 期待値の数値確定（§10.1） — r2

---

## 変更履歴（v0.1 → v0.2、r1 対応表）

| review | 対応 |
|---|---|
| P0 CallForms/OptionContract | §4.1 CallForms/OptionContracts/UnknownOptionPolicy/ReturnVariants、§4.6 描画キー、§8.1 投影 |
| P0 ValidateCallExpression 系 | §6.1 新設（Validate/Normalize/Repair/Explain＋`$ClaudeCallContractValidator` hook）、G-call-1/2/3 |
| P0 typed handle | §4.5 PortBindingRef（6 kinds＋SnapshotPolicy＋Identity 表）、§7.1 CellInput を Ref 返却に、G-bind-1/2/3 |
| P0 関数選定規約 | §4.1 selection metadata、§6.2 SelectFunctionsForTask（rejected reason・enum 選択・閾値 0 件許容）、Q5 解決 |
| P0 Value privacy | §4.4 ValueEnvelope（Source 別既定）、§6.6 Max に合算、W5 改訂、G-privacy-1 |
| P0 契約 audit CI | §8.4 SourceVaultAuditFunctionContracts（8 項目）＋build report 同梱＋AuditStatus、W8 改訂 |
| P1 Class taxonomy | §4.3 ObjectKind/DomainKind/MediaKind 分離、Class 廃止、Composable は DomainKind/MediaKind 基準 |
| P1 InitContract ref 化 | §4.2 InitializedQRef 等の symbol 名 ref、W10 新設、§5.3 reentry guard、G-init-1 |
| P1 adapter cost 探索 | §6.3 AdapterPolicy（MaxDepth/MaxCost/AllowLossy/RequireUniquePath）、複数 path→Unresolved |
| P1 propose/execute 分離 | §6.7 三層＋WiringPlanExpression、W9 新設、ClaudeEval は execute 不可 |
| P1 Binding UI（r1 改訂: WorkflowInputBlock） | §7.4 全面改訂——正本＝notebook 上の WorkflowInputBlock（TaggingRules typed セル・Insert/Collect/Validate/Submit API・InputBundle URI 化）、dialog は補助に格下げ、**起動シーケンスは式提案に統一（ユーザー決定・W9 拡張）**、G-ui-1/G-ui-2、Q10 解決・Q11 新設 |
| P2 Failure schema | §4.8 共通形＋RepairHints、全 API の Status enum 固定 |
| §13 Golden 追加 | §10.1 に 11 件全採用、各 Inc の受け入れへ配置 |

---

## 変更履歴（v0.2 → v0.3、r2 対応表）

| review | 対応 |
|---|---|
| P0-1 Execute/RunWorkflow 責務 | §6.7: Execute は `"OnMissingInput"->"Return"` 既定で notebook 不可触・`InputBlockSpec` 返却のみ。挿入は RunWorkflow wrapper（`"OnMissingInput"->"InsertWorkflowInputBlock"`、headless では spec 返却へ degrade） |
| P0-2 InputDraft/InputBundle 分離 | §7.4.2: Collect→InputDraft、Validate は report のみ（永続化しない）、`SourceVaultCreateInputBundle` は green 後のみ。Submit = Collect→Validate→CreateInputBundle→Resume |
| P0-3 block-level metadata | §7.4.2: cell-level（`WorkflowInputCell`）と block-level（`WorkflowInputBlock`: PlanHash/InputSchemaHash/Status lifecycle/CellUUIDs/LastInputBundleURI）の二層化 |
| P1-1 再評価 idempotency | §7.4.1 step 3: 未提出同一 block は再利用・schema 変更で Superseded。G-ui-3/G-ui-4 追加 |
| P1-2 bundle subtype | §7.4.2: `BundleKind->"WorkflowInput"` 必須 sidecar（TargetWorkflowId/PlanHash/InputBlockId/InputPorts 込み）。Q11 解決 |
| P1-3 RunWorkflow 自身の契約 | §7.4.1 step 1: 最低限契約を明示（Effects/CallForm/Outputs 2 variant）、SubmitWorkflowInput は URI/record も受理。§10 F2 pilot 対象に明記 |
| P2 用語整理 | ヘッダ対象・§3 Scope の「Binding UI」→「WorkflowInputBlock / Binding helper UI」 |
