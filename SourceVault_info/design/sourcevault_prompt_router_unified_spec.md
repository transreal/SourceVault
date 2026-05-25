# SourceVault Prompt Router / Prompt Capture / Workflow Promotion 統合実装仕様書

Version: v11 — ClaudeEval expression proposal contract / PromptRouter execution separation 更新版  
対象: `SourceVault.wl`, `SourceVault_promptrouter.wl`, `claudecode.wl`, `ClaudeRuntime.wl`, `ClaudeOrchestrator.wl`, `ClaudeOrchestrator_workflow.wl`, `NBAccess.wl`, `Claude Directives/rules`, `Claude Directives/skills`, ClaudeEval パレット

この文書は実装前の統合仕様である。既存の SourceVault / NBAccess / claudecode / ClaudeRuntime / ClaudeOrchestrator / ClaudeDirective の責務分担をできるだけ維持し、どうしても必要な部分だけを `SourceVault_promptrouter.wl` として追加する。

---

## 0. 目的

`ClaudeEval["日常的な定型プロンプト"]` を、毎回重量級 LLM に再解釈させるのではなく、SourceVault に保存された notebook cache、PromptRoute、WorkflowRoute、PromptRun、workflow template を用いて、可能な限り deterministic な関数呼び出し、既存 route、または登録済み Petri-net workflow として再実行する。

具体的には、次のような要求を扱う。

```mathematica
ClaudeEval["3日間のスケジュールを"]
ClaudeEval["7日間のスケジュールのうちTodoが残っているものを"]
ClaudeEval["これから三日間にレビューしないといけない$onWorkのファイルは？"]
ClaudeEval["レビューしないといけないファイルのリストを"]
```

期待される動作は以下である。

1. まったく同じ prompt が過去に成功 route として保存されていれば、原則としてその route を使う。
2. 期間、Todo 有無、NextReview/Deadline などの option 変更だけで済むものは、LLM を呼ばず deterministic parameter extraction で処理する。
3. route 選択や parameter extraction に LLM が必要でも、単純な場合は既存定義上の軽量級 model intent を使う。
4. 複雑な場合のみ、既存の重量級 ClaudeEval / ClaudeOrchestrator 経路へ fallback する。
5. 複雑な定型処理は、Petri-net workflow template として SourceVault に保存し、再利用可能にする。
6. 複数候補がある場合は、ClaudeRuntime の Approval / Choice flow に渡してユーザーに選択させる。
7. 秘密セルまたは private/local model 実行に由来する prompt / workflow は、privacy level を継承し、cloud LLM に自動送信しない。

---

## 1. 現状の問題

現在の `ClaudeEval` 入口には自然言語 dispatch があり、`"予定"`, `"スケジュール"` などを検出すると `SourceVaultUpcomingSchedule` を呼ぶ方向性がある。この方向性は正しい。

しかし現状では、次の問題がある。

- `"7日間のスケジュールのうちTodoが残っているものを"` の `Todoが残っている` が `OpenTodoCount > 0` として抽出されない。
- `"レビューしないといけないファイル"` が notebook cache の `NextReview` ではなく、GitHub repository file のような別タスクへ流れることがある。
- `Deadline`, `NextReview`, `OpenTodoCount`, `Status`, `Scope` の使い分けが route 層に明示されていない。
- うまくいった prompt を後から保存し、PromptRoute / WorkflowRoute として再利用する仕組みがない。
- route 選択のための LLM 呼び出し自体が privacy-sensitive であることが明文化されていない。
- private/local model が 1 種類しかない環境で、軽量級・中量級・重量級の抽象要求をどう代替するかが未定義である。
- PromptRouter 実装が `ClaudeEval` に評価済みの `Association` / `Grid` / 独自整形表を直接返すと、`ClaudeRuntime` が提案式の head を検査してから実行するという `ClaudeEval` の基本契約を破る。

---

## 2. 設計原則

### 2.1 既存枠組みを優先する

本仕様では、以下の既存枠組みを使う。

| 既存枠組み | 今回の使い方 |
|---|---|
| SourceVault Stage 6b compiled registry | 低頻度更新の宣言的データである `PromptRoute`, `WorkflowRoute`, `PromptExample`, `WorkflowTemplate metadata`, search index の保存先に使う。`PromptRun` はここに保存しない |
| SourceVault append-only JSONL store | 高頻度・時系列の `PromptRun`, route use event, capture event の保存先に使う。`claims.jsonl` / `source-events.jsonl` と同じ append-only store pattern に従う |
| SourceVault Stage 9 notebook management | `Deadline`, `NextReview`, `OpenTodoCount`, `Summary`, `Privacy` の deterministic query に使う |
| `SourceVaultFindNotebooks` | notebook cache の低レベル deterministic query として使う |
| `SourceVaultUpcomingSchedule` | 予定一覧の既存 API として option 拡張して使う |
| `NBAccess` privacy model | 秘密セル、セル参照、privacy propagation、credential handling に使う |
| `claudecode.wl` の `$ClaudeEvalHook` / `$ClaudeEvalNaturalDispatch` | `ClaudeEval` 入口の既存 hook / switch として使う |
| `ClaudeRuntime` | `NeedsApproval`, proposal validation, Approval / Choice UI に使う |
| `ClaudeOrchestrator` / workflow package | 複雑な定型処理を Petri-net workflow として実行する |
| SourceVault model registry / `SourceVaultResolve` / `ClaudeResolveModel` | 軽量級・中量級・重量級 LLM の解決に使う。ただし既存 resolver の入力契約を検証し、不足があれば model resolver の小拡張を先行する |
| ClaudeDirective rules / skills | 実装者・Claude Code への規範として使う。runtime route memory としては使わない。データストア安全規約・PathRef 権限分離・LLM 指示分離はここに従う |

以下は新設しない。

- `SourceVault` と別系統の prompt memory database
- claudecode 側に増殖する ad hoc な日本語判定表
- `$LightweightLLM`, `$HeavyweightLLM` のような独自 global 変数
- ClaudeDirective rules / skills を runtime prompt router の実データとして読む仕組み
- registry 中の文字列を `ToExpression` で直接実行する仕組み

### 2.2 PromptRoute は「会話ログ」ではない

SourceVault に保存するのは、ClaudeEval の全会話ログではない。保存するのは、再利用・再実行・検証に必要な構造化情報である。

- prompt fingerprint
- normalized prompt
- route decision
- extracted parameters
- dependency snapshot ids
- workflow version
- model resolution record
- privacy metadata

raw prompt は既定では保存しない。ただしユーザーが「今実行したプロンプトを保存して」等と明示した場合、または palette button で保存した場合には、private registry に保存できる。

### 2.3 Route selection も privacy-sensitive とする

秘密 prompt を「どの route に一致するか」判定するために cloud LLM へ送ることも、情報漏洩になり得る。したがって、route selection の LLM 呼び出しも NBAccess / SourceVault privacy gate の対象にする。

---

## 3. 追加ファイルとロード設計

### 3.1 新規ファイル

PromptRouter 関連コードは新規ファイルとして分離する。

```text
SourceVault_promptrouter.wl
```

このファイルは独立パッケージではなく、`SourceVault`` context の extension とする。

`SourceVault_promptrouter.wl` に置く主な定義:

- `SourceVaultPromptRouterStatus`
- `SourceVaultPromptRouterAvailableQ`
- `SourceVaultPromptRouterActiveQ`
- `SourceVaultResolvePromptRoute`
- `SourceVaultExecutePromptRoute`
- `SourceVaultRouteExplain`
- `SourceVaultRegisterPromptRoute`
- `SourceVaultListPromptRoutes`
- `SourceVaultGetPromptRoute`
- `SourceVaultRecordPromptRouteUse`
- `SourceVaultPromptRunRecord`
- `SourceVaultPromptRunHistory`
- `SourceVaultCaptureLastPromptRun`
- `SourceVaultCaptureSelectedClaudeEvalCell`
- `SourceVaultPromotePromptRun`
- `SourceVaultReviewQueue`
- `SourceVaultReprocessPlan`
- `SourceVaultReprocess`
- deterministic extractor 群
- function route allowlist dispatcher
- workflow route availability checker

`SourceVault.wl` 本体に残すもの:

- Stage 6b registry の低レベル API
- Stage 9 notebook cache API
- `SourceVaultUpcomingSchedule` の option 拡張
- `SourceVault_promptrouter.wl` の自動ロード bootstrap
- 必要最小限の usage 宣言

### 3.2 SourceVault.wl からの自動ロード

`SourceVault.wl` がロードされたとき、同じディレクトリに `SourceVault_promptrouter.wl` があれば自動ロードする。

推奨 bootstrap:

```mathematica
SourceVault`Private`iSVLoadPromptRouterExtension[] := Module[{base, path},
  base = Quiet @ Check[DirectoryName[$InputFileName], $Failed];
  If[!StringQ[base], Return[$Failed]];
  path = FileNameJoin[{base, "SourceVault_promptrouter.wl"}];
  If[!FileExistsQ[path], Return[Missing["NotFound", path]]];
  Quiet @ Check[Get[path], $Failed]
];

If[!TrueQ[SourceVault`Private`$iSVDisablePromptRouterAutoLoad],
  SourceVault`Private`iSVLoadPromptRouterExtension[]
];
```

実装条件:

- `Needs["ClaudeRuntime`"]` や `Needs["ClaudeOrchestrator`"]` を自動実行しない。
- `SourceVault_promptrouter.wl` は ClaudeRuntime / ClaudeOrchestrator が未ロードでもロード成功する。
- Orchestrator / Runtime の availability は実行時に判定する。
- 自動ロード失敗は SourceVault 本体ロード失敗にしない。診断情報として保持する。
- 複数回 `Get` されても壊れない idempotent 実装にする。

---

## 4. ロード状態ごとの動作

PromptRouter は、SourceVault の基本機能を ClaudeOrchestrator に依存させない。一方で、`ClaudeEval` から PromptRoute / WorkflowRoute に自動 dispatch する恩恵は、原則として ClaudeOrchestrator がロード済みの場合に有効にする。

| 状態 | SourceVault manual API | ClaudeEval 自動 PromptRoute | WorkflowRoute 実行 | Approval / Choice | 備考 |
|---|---:|---:|---:|---:|---|
| claudecode のみ | 不可または未ロード | 無効 | 不可 | 不可 | 従来 ClaudeEval 経路 |
| claudecode + SourceVault | 可 | 既定無効 | 不可 | 不可 | `SourceVaultUpcomingSchedule[]` 等は手動で動く |
| claudecode + SourceVault + ClaudeRuntime | 可 | 既定無効 | 不可 | 一部可 | proposal / approval は使えるが workflow template 実行は不可 |
| claudecode + SourceVault + ClaudeRuntime + ClaudeOrchestrator | 可 | 有効 | 可 | 可 | PromptRoute / WorkflowRoute の主要恩恵を有効化 |

理由:

- FunctionRoute だけを Orchestrator なしで有効化すると、単一関数 route と workflow route の境界が環境により変わる。
- 複数候補選択、workflow execution、provenance 記録、Petri-net workflow 化を同じ経路に揃える。
- claudecode 単体利用を壊さない。

ただし、手動 API としての以下は Orchestrator 不在でも動く。

```mathematica
SourceVaultUpcomingSchedule[]
SourceVaultFindNotebooks[]
SourceVaultResolvePromptRoute[prompt, "DryRun" -> True]
SourceVaultProposePromptRoute[prompt, "DryRun" -> True]
SourceVaultPromptRouterStatus[]
```

---

## 5. ClaudeEval 入口の実行経路

### 5.1 全体経路

```text
ClaudeEval[prompt]
  ↓
claudecode existing hook / natural dispatch
  ↓ optional weak call, only if SourceVault PromptRouter is available and active
SourceVaultProposePromptRoute[prompt, opts]
  ↓
SourceVaultResolvePromptRoute[prompt, opts]
  ├─ Exact fingerprint match
  ├─ Deterministic pattern + parameter extraction
  ├─ Private-aware lightweight router LLM
  ├─ WorkflowRoute candidate selection
  ├─ NeedsChoice / NeedsApproval
  └─ NotFound / NeedHeavyLLM
  ↓
FunctionRoute         → allowlisted SourceVault function call expression
WorkflowRoute         → ClaudeOrchestrator workflow execution expression or WorkflowRoute proposal
NeedsChoice           → ClaudeRuntime Approval / Choice UI
NeedsPrivateModel     → user-facing diagnostic / approval
NeedHeavyLLM/NotFound → existing ClaudeEval fallback
```


### 5.2 ClaudeEval の基本契約: 値ではなく Mathematica 式を提案する

`ClaudeEval` は、原則として「ユーザーに見せる最終値」を直接返す関数ではなく、ユーザーの要求を満たす **Mathematica 式を提案し、その式を ClaudeRuntime / NBAccess policy が検査してから実行する** 機構である。

したがって、PromptRouter を `ClaudeEval` に接続する場合も、次を厳守する。

```text
自然言語 prompt
  ↓
PromptRouter による route / parameter / workflow 解決
  ↓
未評価の Mathematica proposal expression を構築
  ↓
ClaudeRuntime の head-based validation / privacy gate / approval
  ↓
許可された式を評価
  ↓
評価結果として Grid / Dataset / TextCell / Notebook output が表示される
```

禁止事項:

- `ClaudeEval` 経由で `<|"Type" -> "PromptRouteExecution", "Decision" -> ..., "Result" -> ...|>` のような内部診断 `Association` をそのまま返してはならない。
- `ClaudeEval` 経由で PromptRouter が route を即時実行し、評価済み `Grid` / `Dataset` / 独自整形表を返してはならない。
- PromptRouter 独自の簡易表、たとえば `iSVPRFormatScheduleGrid` のようなものを `ClaudeEval` の最終出力用として作ってはならない。表示は既存 callable、または allowlist 済み formatter の評価結果に委ねる。
- `SourceVaultExecutePromptRoute` の診断結果を `iClaudeEvalTryPromptRouter` がそのまま返してはならない。

`ClaudeEval` 入口で PromptRouter が成功した場合に返すべきものは、次のいずれかである。

1. `HoldComplete[expr]` または既存 `ClaudeRuntime` が受け取れる proposal expression wrapper。
2. `NeedsChoice` / `NeedsApproval` / `NeedsPrivateModel` など、既存 Runtime UI に渡す decision expression。
3. `NotDispatched`。この場合だけ従来 `ClaudeEval` 経路へ fallback する。

`SourceVaultResolvePromptRoute` は route decision とともに proposal expression を返せるが、それは diagnostic association 内の `"ProposedExpression"` フィールドとして保持する。`ClaudeEval` bridge は diagnostic association そのものではなく `"ProposedExpression"` だけを Runtime に渡す。

### 5.3 PromptRouter API の二層化: propose と execute を分ける

PromptRouter には、用途の異なる二つの API 層を置く。

```mathematica
SourceVaultProposePromptRoute[prompt_String, opts:OptionsPattern[]]
SourceVaultExecutePromptRoute[prompt_String, opts:OptionsPattern[]]
```

`SourceVaultProposePromptRoute` は `ClaudeEval` 接続用であり、未評価の式を返す。

```mathematica
<|
  "Type" -> "PromptRouteProposal",
  "Status" -> "Proposed",
  "Decision" -> <|...|>,
  "RouteSignature" -> <|...|>,
  "ProposedExpression" -> HoldComplete[
    SourceVaultUpcomingSchedule[
      "Scope" -> $onWork,
      "Period" -> Quantity[3, "Days"],
      "Refresh" -> "Never",
      "FallbackToCloud" -> "Deny"
    ]
  ],
  "ValidationHints" -> <|
    "ExpectedHeads" -> {SourceVaultUpcomingSchedule},
    "SideEffectClass" -> "ReadOnly"
  |>
|>
```

`SourceVaultExecutePromptRoute` は manual API / tests / diagnostics 用であり、route を実行して診断 association を返してよい。ただし `ClaudeEval` の通常経路はこれを直接呼んではならない。互換期間中に `SourceVaultExecutePromptRoute` を使う場合でも、`"Caller" -> "ClaudeEval"` では内部的に `SourceVaultProposePromptRoute` 相当へ迂回し、評価済み結果を返さない。

推奨される `claudecode.wl` 側の weak call は次である。

```mathematica
If[Length[Names["SourceVault`SourceVaultProposePromptRoute"]] > 0,
  Quiet @ Check[
    iClaudeRuntimeSubmitProposal @
      Symbol["SourceVault`SourceVaultProposePromptRoute"][task, opts],
    $iClaudeEvalNotDispatched
  ],
  $iClaudeEvalNotDispatched
]
```

既存互換のため `SourceVaultExecutePromptRoute` しか存在しない場合だけ legacy path として試してよいが、戻り値が `PromptRouteExecution` であれば `ClaudeEval` へそのまま返さず `NotDispatched` 扱いにする。

### 5.4 TabularQuery / schedule route の式生成方針

スケジュールや notebook cache の表形式 query も、PromptRouter が評価済み表を作るのではなく、既存 SourceVault callable を呼ぶ式として表現する。

#### 5.4.1 単純 schedule query

```mathematica
ClaudeEval["今日から3日間のスケジュールを"]
```

に対する PromptRouter の proposal は、概念的には次の式である。

```mathematica
HoldComplete[
  SourceVaultUpcomingSchedule[
    "Scope" -> $onWork,
    "Period" -> Quantity[3, "Days"],
    "Refresh" -> "Never",
    "FallbackToCloud" -> "Deny"
  ]
]
```

評価結果として、`SourceVaultUpcomingSchedule` 既存の装飾付き Grid、Title link、tooltip、date styling が表示される。PromptRouter 側でこれを再実装しない。

#### 5.4.2 絞り込み付き schedule query

`Todo が残っている`, `NextReview が3日以内`, `Deadline が今週` など、表に対する絞り込みが必要な場合も、最終的には allowlist 済み callable の式として表現する。

初期実装の推奨は、`SourceVaultUpcomingSchedule` に `"FilterSpec"` option を追加し、構造化述語を literal association として渡す方式である。

```mathematica
HoldComplete[
  SourceVaultUpcomingSchedule[
    "Scope" -> $onWork,
    "Period" -> Quantity[7, "Days"],
    "Refresh" -> "Never",
    "FallbackToCloud" -> "Deny",
    "FilterSpec" -> <|
      "Kind" -> "And",
      "Clauses" -> {
        <|"Field" -> "OpenTodoCount", "Op" -> "Greater", "Value" -> 0|>
      }
    |>
  ]
]
```

この方式では、`Select` や `Function` が式表面に出ないため、Runtime validation は `SourceVaultUpcomingSchedule` の head と literal option value を検査すればよい。`SourceVaultUpcomingSchedule` 内部で record list に対して閉じた文法の predicate を適用し、既存の Grid formatting 経路へ戻す。

代替として、`Select` を表面に出す必要がある場合は、必ず allowlist 済み formatter で包む。

```mathematica
HoldComplete[
  SourceVaultFormatScheduleRecords[
    Select[
      SourceVaultUpcomingSchedule[
        "Scope" -> $onWork,
        "Period" -> Quantity[7, "Days"],
        "OutputFormat" -> "Records",
        "Refresh" -> "Never",
        "FallbackToCloud" -> "Deny"
      ],
      SourceVaultTabularPredicate[
        "schedule",
        <|"Kind" -> "Field", "Field" -> "OpenTodoCount", "Op" -> "Greater", "Value" -> 0|>
      ]
    ]
  ]
]
```

この代替案を採る場合、`Select`, `SourceVaultFormatScheduleRecords`, `SourceVaultTabularPredicate`, `SourceVaultUpcomingSchedule` は callable allowlist / Runtime validation の対象にする。`Function[...]` で任意 predicate body を生成してはならない。

#### 5.4.3 述語表現の安全性

`TabularQuery` が生成してよい predicate は、閉じた DSL に限定する。

許可:

- `Association` literal
- `List` literal
- `String`, `Integer`, `Real`, `True`, `False`, `Missing[...]`
- `Kind -> "And" | "Or" | "Not" | "Field"`
- `Op -> "Equal" | "NotEqual" | "Greater" | "GreaterEqual" | "Less" | "LessEqual" | "Contains" | "DateWithin" | "NonEmpty"`
- field name は schema allowlist にあるもののみ

禁止:

- `Function`, `PureFunction`, `Slot`, `RuleDelayed`
- `ToExpression`, `Import`, `URLRead`, `RunProcess`, `ExternalEvaluate`
- arithmetic expression such as `1 + 1` in predicate value
- string concatenation such as `"x" <> "y"`
- arbitrary symbol reference

#### 5.4.4 PromptRouteExecution は内部診断である

`PromptRouteExecution` / `PromptRouteProposal` / `RouteDecision` は SourceVault diagnostics、PromptRun 記録、テスト、`SourceVaultRouteExplain` のための内部構造である。ユーザーが `SourceVaultExecutePromptRoute[...]` を手動で呼んだ場合は表示してよいが、`ClaudeEval[...]` の通常出力として露出させてはならない。

`ClaudeEval` の通常出力は、Runtime が許可した proposed expression の評価結果である。


### 5.5 claudecode 側の optional weak call

`claudecode.wl` は SourceVault に hard dependency を持たせない。既存方針に合わせて、`Names` / `Symbol` による optional weak call のみ許可する。

```mathematica
If[Length[Names["SourceVault`SourceVaultExecutePromptRoute"]] > 0,
  Quiet @ Check[
    Symbol["SourceVault`SourceVaultExecutePromptRoute"][task, opts],
    $iClaudeEvalNotDispatched
  ],
  $iClaudeEvalNotDispatched
]
```

`SourceVaultExecutePromptRoute` が `$iClaudeEvalNotDispatched` 相当、`<|"Status" -> "NotDispatched"|>`、または `$Failed` を返した場合、従来の ClaudeEval 経路へ fallback する。

### 5.6 既存 natural dispatch からの移行方針

現行 `claudecode.wl` には `$ClaudeEvalNaturalDispatch`, `iClaudeEvalNaturalMatch`, `iClaudeEvalExtractPeriod`, `iClaudeEvalExtractScope` 等による schedule / summary 系の ad hoc dispatch が存在する。PromptRouter はこの後継であり、同じ判定表を claudecode 側と SourceVault 側の二箇所に残してはならない。

推奨移行方針:

```text
$ClaudeEvalPromptRouterDispatch = True かつ SourceVaultPromptRouterActiveQ["ClaudeEval"]
  → iClaudeEvalNaturalMatch をバイパスし、SourceVaultExecutePromptRoute を先に試す
  → NotDispatched の場合だけ、互換目的で従来 natural dispatch へ fallback

PromptRouter unavailable または $ClaudeEvalPromptRouterDispatch = False
  → 従来どおり $ClaudeEvalNaturalDispatch に従う
```

flag の関係:

| flag | 役割 | 既定 |
|---|---|---|
| `$ClaudeEvalPromptRouterDispatch` | SourceVault PromptRouter を ClaudeEval 入口で使うか | `Automatic`。Orchestrator までロード済みなら True 相当 |
| `$ClaudeEvalNaturalDispatch` | 旧 natural dispatch を使うか | 既存値を維持。ただし PromptRouter active 時は legacy fallback のみ |
| `$ClaudeEvalPromptRouterPreemptsNatural` | PromptRouter が旧 natural dispatch より前に走るか | `True` |

旧 natural dispatch の schedule / refresh_summary pattern は、実装の最終形では PromptRouter の seed `PromptRoute` へ吸収する。移行期間中だけ legacy fallback として残す。

禁止事項:

- claudecode 側に新しい日本語判定表を追加し続けること。
- SourceVault 側と claudecode 側で `PeriodDays`, `Scope`, `OpenTodos`, `DateField` の抽出ロジックを二重管理すること。
- PromptRouter active 時に旧 natural dispatch が先に実行され、PromptRouter の `OpenTodos` / `NextReview` extraction を迂回すること。

---

## 6. Deterministic notebook query API の拡張

### 6.1 `SourceVaultUpcomingSchedule` の拡張

既存の `SourceVaultUpcomingSchedule` に、最小限以下の option を追加する。

既存実装では `Options[SourceVaultUpcomingSchedule]` が同一ファイル内で明示定義されているため、実装時は `Options[f] = Join[Options[f], ...]` で後置き拡張するのではなく、**元の option 定義リストへ直接 3 項目を追加する**。これにより option 重複、ロード順依存、複数回 `Get` 時の重複 append を避ける。

```mathematica
Options[SourceVaultUpcomingSchedule] = {
  "Scope" -> Automatic,
  "Period" -> Quantity[7, "Days"],
  "IncludeOverdue" -> True,
  "Recursive" -> True,
  "Refresh" -> "IfStale",
  "FallbackToCloud" -> "Ask",
  "StatusFilter" -> {"Todo"},
  "UseCache" -> True,

  (* PromptRouter / notebook management extension *)
  "OpenTodos" -> Missing[],        (* True | False | Missing[] *)
  "DateField" -> "Both",          (* "Both" | "Deadline" | "NextReview" *)
  "OutputFormat" -> "Dataset"     (* "Dataset" | "Rows" | "Records" *)
};
```

意味:

- `"OpenTodos" -> True`: `OpenTodoCount > 0` の notebook のみ。
- `"OpenTodos" -> False`: 未完了 Todo がない notebook のみ。
- `"OpenTodos" -> Missing[]`: Todo 条件なし。
- `"DateField" -> "Deadline"`: Deadline のみを見る。
- `"DateField" -> "NextReview"`: NextReview のみを見る。
- `"DateField" -> "Both"`: Deadline または NextReview を見る。

注意点:

- 既存の `"StatusFilter" -> {"Todo"}` は header の `Status` に関する filter であり、未完了 Todo セルの有無とは別である。
- `"Todoが残っている"`, `"未完了Todo"` は `"OpenTodos" -> True` に対応させる。

### 6.2 ReviewQueue / OpenTodoList intent の扱い

**初期実装では、実在しない public callable を allowlist に登録してはならない。**

現状の `SourceVault.wl` には以下が実在する。

```text
SourceVaultUpcomingSchedule
SourceVaultFindNotebooks
```

一方、以下は現状の `SourceVault.wl` には存在しない。

```text
SourceVaultReviewQueue
SourceVaultOpenTodoList
```

したがって Order 3 の FunctionRoute dispatcher / callable allowlist には、初期実装では実在する callable だけを登録する。`SourceVaultReviewQueue` / `SourceVaultOpenTodoList` は、実装されるまで `FunctionId` として登録しない。

レビュー対象や open todo list は、初期実装では **semantic intent** として扱い、実行直前の adapter で `SourceVaultFindNotebooks` の実 option へ変換する。

例:

```mathematica
(* レビュー対象 notebook *)
SourceVaultFindNotebooks[
  "NextReview" -> "DueSoon",
  "OpenTodos" -> Missing[]
]

(* 未完了 Todo がある notebook *)
SourceVaultFindNotebooks[
  "OpenTodos" -> True
]

(* レビュー対象かつ未完了 Todo がある notebook *)
SourceVaultFindNotebooks[
  "NextReview" -> "DueSoon",
  "OpenTodos" -> True
]
```

`"DueSoon"` / `"ThisWeek"` / `"Overdue"` の選択は、PromptRouter の canonical parameter から adapter が決める。厳密な `{from,to}` 期間指定が必要な場合は、現状の `SourceVaultFindNotebooks` がその範囲指定を実装しているかを Order 0 audit で確認し、未実装なら route candidate を `NeedsImplementation` または `NeedsChoice` に落とす。

将来、薄い convenience wrapper として `SourceVaultReviewQueue` や `SourceVaultOpenTodoList` を追加してもよい。ただし、その場合も以下を守る。

- wrapper 実装が存在するまでは allowlist に `Symbol` を置かない。
- placeholder を compiled registry や callable allowlist に入れない。
- 追加後は `SourceVaultCallableAllowlistRegistry[]` に実在 symbol として登録し、既存の `ReviewQueue` / `OpenTodoList` intent の adapter target を wrapper へ移してよい。
- PromptRoute / PromptRun の canonical intent は維持し、過去の route signature を壊さない。

この節は、古い例に出てくる `SourceVaultReviewQueue` / `SourceVaultOpenTodoList` への直接 route 記述を上書きする normative な修正である。

---

## 7. PromptRoute / WorkflowRoute registry

### 7.1 PromptRoute schema

`PromptRoute` / `WorkflowRoute` は Stage 6b compiled registry の topic として保存する。これらは低頻度更新の宣言的データであり、`SourceVaultCompileRegistry[topic, entries, opts]` の「entries 全体を一括書き込みする」性質と相性がよい。

一方、`PromptRun` は実行履歴であり、append-only が本質である。`PromptRun` を compiled registry topic に入れてはならない。`PromptRun` は §9 の JSONL store に保存する。

推奨 topic:

```text
prompt-route-registry
workflow-route-registry
prompt-route-index
workflow-route-index
```

例:

```mathematica
<|
  "Type" -> "PromptRoute",
  "RouteId" -> "route-sourcevault-upcoming-schedule-v1",
  "RouteVersion" -> 1,
  "SchemaVersion" -> 1,

  "Matcher" -> <|
    "Kind" -> "DeterministicPattern",
    "PromptFingerprints" -> {"sha256:..."},
    "KeywordsAny" -> {"スケジュール", "予定", "schedule"},
    "ParameterRules" -> {
      <|"Pattern" -> "([0-9]+)日間", "Parameter" -> "PeriodDays"|>,
      <|"Keywords" -> {"Todoが残っている", "未完了"},
        "Parameter" -> "OpenTodos", "Value" -> True|>
    }
  |>,

  "Target" -> <|
    "Kind" -> "Function",
    "FunctionSymbol" -> "SourceVaultUpcomingSchedule",
    "FunctionId" -> "SourceVaultUpcomingSchedule",
    "SideEffectClass" -> "ReadOnly"
  |>,

  "ParameterSchema" -> <|
    "PeriodDays" -> <|"Type" -> "Integer", "Default" -> 7|>,
    "OpenTodos" -> <|"Type" -> "TriState", "Default" -> Missing[]|>,
    "DateField" -> <|"Type" -> "Enum", "Values" -> {"Both", "Deadline", "NextReview"}, "Default" -> "Both"|>
  |>,

  "Privacy" -> <|
    "PrivacyLevel" -> 0.0,
    "AllowedTrustDomains" -> Automatic,
    "CloudFallback" -> "Ask"
  |>,

  "ModelPolicy" -> <|
    "RouterLLM" -> "None",
    "FallbackIntent" -> "router",
    "WeightClass" -> "Light"
  |>
|>
```

### 7.2 WorkflowRoute schema

複雑な定型処理は `WorkflowRoute` として保存する。

例:

```mathematica
<|
  "Type" -> "WorkflowRoute",
  "RouteId" -> "workflow-review-queue-with-open-todos-v1",
  "RouteVersion" -> 1,
  "SchemaVersion" -> 1,

  "Matcher" -> <|
    "KeywordsAny" -> {"レビュー", "NextReview", "Todo", "未完了"},
    "Examples" -> {
      "今週レビューしないといけない未完了Todo付きノートブックを出して"
    }
  |>,

  "Target" -> <|
    "Kind" -> "WorkflowTemplate",
    "WorkflowTemplateId" -> "wf-template-review-queue-v1",
    "RequiredRuntime" -> "ClaudeRuntime",
    "RequiredOrchestrator" -> "ClaudeOrchestrator"
  |>,

  "Privacy" -> <|
    "PrivacyLevel" -> 0.0,
    "AllowedTrustDomains" -> Automatic,
    "CloudFallback" -> "Ask"
  |>
|>
```

### 7.3 Callable allowlist registry

FunctionRoute は文字列から任意 symbol を実行してはならない。`FunctionId` を allowlist に照合して dispatch する。

この allowlist は、§23 の Workflow `HandlerRef` allowlist と意味的に別管理にしてはならない。ただし、**物理的に 1 つの `.wl` テーブルへ集約してはならない**。SourceVault 側が ClaudeOrchestrator の生シンボルを code-resident table に書くと rule 11 の依存方向に反し、ClaudeOrchestrator 未ロード時の自動ロード要件とも衝突する。

したがって、真実源は **所有者ごとの code-resident allowlist** とし、PromptRouter からはそれらを合成した **単一の論理ビュー** として扱う。

```text
SourceVault-owned callable allowlist
  SourceVault が所有する関数だけを登録する。
  SourceVault_promptrouter.wl / SourceVault 本体側の .wl 定数テーブル。

ClaudeOrchestrator-owned handler allowlist
  BuiltInMergeResults など ClaudeOrchestrator Workflow engine が所有する handler だけを登録する。
  ClaudeOrchestrator_workflow.wl または ClaudeOrchestrator_promptworkflow.wl 側の .wl 定数テーブル。

PromptRouter callable view
  実行時に SourceVault-owned allowlist を基礎にし、ClaudeOrchestrator がロード済みなら
  Orchestrator-owned allowlist API を weak call で問い合わせて合成する。
```

**保存形態:** いずれの allowlist も compiled registry(JSON) ではない。値に Wolfram Language の生シンボルを含むため、`compiled/public/*.json` や `compiled/private/*.json` へ保存してはならない。`FunctionId -> Symbol` / `HandlerRef -> Symbol` の対応、`UseAsFunctionRoute` / `UseAsHandlerRef`、`SideEffectClass`、必要 capability などのメタデータは、各所有者パッケージの `.wl` 定数テーブルを真実源にする。

この意味でここでの `registry` は「SourceVault compiled registry」ではなく、「コード内 allowlist registry の論理ビュー」である。PromptRoute / WorkflowRoute registry には `FunctionId` / `HandlerRef` 文字列だけを保存し、実行時に allowlist view で実シンボルへ解決する。

推奨 API:

```mathematica
SourceVaultCallableAllowlistRegistry[]
```

SourceVault が所有する callable だけを返す。

```mathematica
ClaudeWorkflowHandlerAllowlist[]
```

ClaudeOrchestrator が所有する Workflow handler だけを返す。SourceVault はこの symbol を直接参照しない。`NameQ` / `ToExpression[..., InputForm, HoldComplete]` など既存の weak-call 方針に従い、ClaudeOrchestrator がロード済みで、かつ API が利用可能な場合だけ呼び出す。

```mathematica
SourceVaultCallableAllowlistView[]
```

SourceVault-owned allowlist と、ロード済み package が提供する allowlist を合成した論理ビューを返す。PromptRouter / FunctionRoute dispatcher / HandlerRef resolver はこの view を参照する。

SourceVault-owned 初期 registry は、**現状の `SourceVault.wl` に実在する callable だけ**を含める。

```mathematica
<|
  "SourceVaultUpcomingSchedule" -> <|
    "Symbol" -> SourceVaultUpcomingSchedule,
    "UseAsFunctionRoute" -> True,
    "UseAsHandlerRef" -> True,
    "SideEffectClass" -> "ReadOnly"
  |>,
  "SourceVaultFindNotebooks" -> <|
    "Symbol" -> SourceVaultFindNotebooks,
    "UseAsFunctionRoute" -> True,
    "UseAsHandlerRef" -> True,
    "SideEffectClass" -> "ReadOnly"
  |>
|>
```

`SourceVaultReviewQueue` / `SourceVaultOpenTodoList` は、現状の `SourceVault.wl` に定義が無い限り、この registry に入れない。レビュー queue / open todo list は `FunctionId` ではなく `IntentId` として扱い、adapter が `SourceVaultFindNotebooks` の実 option へ変換する。

`"BuiltInMergeResults"` など ClaudeOrchestrator Workflow builtin handler は、この SourceVault-owned registry には置かない。これらは Orchestrator-owned handler allowlist に属する。

Orchestrator-owned handler allowlist 例:

```mathematica
<|
  "BuiltInMergeResults" -> <|
    "Symbol" -> BuiltInMergeResults,
    "UseAsFunctionRoute" -> False,
    "UseAsHandlerRef" -> True,
    "SideEffectClass" -> "ReadOnly",
    "OwnerPackage" -> "ClaudeOrchestrator"
  |>
|>
```

Side effect class:

- `ReadOnly`: 自動実行可。
- `WriteNotebook`: ClaudeRuntime approval 必須。
- `ExternalWrite`: approval 必須。GitHub 等は該当 API の availability も確認する。
- `NetworkRead`: privacy / policy に従う。

allowlist 更新時は、所有者 package 側の単体テストと、`SourceVaultCallableAllowlistView[]` の統合テストを走らせる。SourceVault 側が Orchestrator の生シンボルを保持する状態、または Orchestrator 側 callable を SourceVault 側 table に重複登録する状態を禁止する.

---

## 8. Prompt matching と parameter extraction

### 8.1 Matching order

```text
1. Exact fingerprint match
2. Deterministic FunctionRoute / parameter extraction
3. Lexical / capability index search
4. Existing WorkflowRoute candidate selection
5. Deterministic complex prompt detector
6. Lightweight router LLM, privacy constraints applied
7. NeedsChoice / NeedsApproval
8. Heavy ClaudeEval fallback
```

deterministic complex prompt detector は router LLM より前に置く。これにより、秘密 prompt を LLM に渡す前に workflow 候補であることをローカルに判定でき、cost と privacy risk を減らせる。

### 8.2 deterministic extraction examples

| Prompt fragment | Extracted parameter |
|---|---|
| `3日間`, `三日間`, `3 days` | `"PeriodDays" -> 3` |
| `7日間`, `一週間` | `"PeriodDays" -> 7` |
| `今週` | `"DateRangeKind" -> "CalendarWeek"` または `"PeriodDays" -> 7` の候補。曖昧なら `NeedsChoice` |
| `Todoが残っている`, `未完了`, `open todo` | `"OpenTodos" -> True` |
| `レビュー`, `NextReview`, `レビューしないといけない` | `"IntentId" -> "ReviewQueue"`, `"DateField" -> "NextReview"`; 初期実装では adapter が `SourceVaultFindNotebooks["NextReview" -> ...]` へ変換 |
| `締切`, `Deadline`, `期限` | `"DateField" -> "Deadline"` |
| `$onWork` | `"ScopeRef" -> <|"Kind" -> "RootSymbol", "Name" -> "$onWork"|>` |

日本語数詞は初期実装では小さい範囲だけでよい。

```text
一, 二, 三, 四, 五, 六, 七, 八, 九, 十
```

### 8.2.1 canonical parameter normal form

registry、PromptRun、PromptRoute search index、RouteSignature に保存する parameter は、Wolfram Language 実行値ではなく JSON 化しやすい正規形に統一する。

| 概念 | 保存時の canonical key / value | 関数呼び出し直前の変換 |
|---|---|---|
| 期間 N 日 | `"PeriodDays" -> n_Integer` | `"Period" -> Quantity[n, "Days"]` |
| calendar week | `"DateRangeKind" -> "CalendarWeek"`, 必要なら `"DateRange" -> {date1, date2}` | `"DateRange"` または `"Period"` へ変換 |
| Todo 未完了条件 | `"OpenTodos" -> True | False | Missing[]` | 同名 option へ渡す |
| 日付フィールド | `"DateField" -> "Both" | "Deadline" | "NextReview"` | 同名 option へ渡す |
| scope | `"ScopeRef" -> <|"Kind" -> "RootSymbol", "Name" -> "$onWork"|>` など | NBAccess / SourceVault の安全 resolver を通した後で `"Scope"` へ渡す |

`PeriodDays` と `"Period" -> Quantity[...]` を registry 内で混在させてはならない。Quantity は実行直前の adapter layer で生成する。

`ScopeRef` は identity であり authority ではない。`ScopeRef` が `$onWork` として解決できても、notebook read / write / cloud-send 権限は NBAccess authorization を必ず通す。

### 8.3 Ambiguous cases

例:

```mathematica
ClaudeEval["今週のタスクを出して"]
```

候補:

1. `UpcomingSchedule`: Deadline / NextReview が今週の notebook
2. `ReviewQueue`: NextReview が今週の notebook
3. `OpenTodoList`: 未完了 Todo がある notebook

この場合は勝手に 1 つに決めず、次を返す。

```mathematica
<|
  "Status" -> "NeedsChoice",
  "Choices" -> {...},
  "Prompt" -> prompt,
  "Reason" -> "MultiplePromptRoutesMatched"
|>
```

ClaudeRuntime が利用可能なら Approval / Choice UI に渡す。利用不可なら候補一覧を返し、従来 ClaudeEval fallback してよい。

---

## 9. PromptRun と prompt 保存方針

### 9.0 PromptRun 保存先の分離

`PromptRun` は Stage 6b compiled registry に保存しない。`PromptRun` は `claims.jsonl` / `source-events.jsonl` と同じ append-only JSONL store として扱う。

推奨保存先:

```text
<PrivateVault>/promptrouter/runs/prompt-runs.jsonl
<PrivateVault>/promptrouter/runs/by-date/YYYY-MM-DD.jsonl      optional shard
<PrivateVault>/promptrouter/events/route-events.jsonl          optional route/capture events
```

保存方針:

- `PromptRun` は実行履歴なので append-only とする。
- compiled registry へは `PromptRoute`, `WorkflowRoute`, `PromptExample`, search index だけを置く。
- `PromptRun` の raw prompt は既定で保存しない。保存する場合も private store に限定する。
- JSONL append / read は SourceVault の既存 JSONL pattern に従い、`iSanitizeForJSON`、`ReadByteArray` + `ByteArrayToString`、atomic append/write を使う。
- `SourceVaultResetStore` の通常削除対象には `promptrouter/runs` を含めない。これは作業記録であり、明示 option `"IncludePromptRuns" -> True` と二重確認がある場合だけ削除候補にする。

### 9.1 通常実行時

通常の `ClaudeEval[prompt]` 実行では raw prompt は永続保存しない。保存してよいのは hash / fingerprint / route decision / parameters / dependency metadata である。

既定:

```mathematica
"StorePrompt" -> "HashOnly"
```

選択肢:

```mathematica
"StorePrompt" -> "HashOnly" | "PrivateRaw" | "Off"
```

### 9.2 PromptRun schema

```mathematica
<|
  "Type" -> "PromptRun",
  "RunId" -> "prun-...",
  "Timestamp" -> "...",
  "PromptHash" -> "sha256:...",
  "PromptFingerprint" -> "...",
  "RawPromptStored" -> False,
  "PromptStorageClass" -> "HashOnly",

  "Route" -> <|
    "RouteId" -> "route-sourcevault-upcoming-schedule-v1",
    "RouteVersion" -> 1,
    "Decision" -> "DeterministicMatch" | "ExactMatch" | "LLMRouter" | "WorkflowRoute" | "Fallback"
  |>,

  "Parameters" -> <|
    "PeriodDays" -> 7,
    "OpenTodos" -> True,
    "DateField" -> "Both"
  |>,

  "Dependencies" -> <|
    "SourceSnapshots" -> {...},
    "RegistryVersions" -> {...},
    "WorkflowTemplate" -> Missing[]
  |>,

  "ModelResolution" -> <|
    "Requested" -> <||>,
    "Resolved" -> <||>,
    "FallbackKind" -> Missing[],
    "CloudFallbackUsed" -> False
  |>,

  "Privacy" -> <|
    "PrivacyLevel" -> 0.0,
    "PrivacyOrigin" -> {},
    "AllowedTrustDomains" -> Automatic,
    "CloudFallback" -> "Ask"
  |>,

  "Result" -> <|
    "Kind" -> "FunctionResult" | "WorkflowResult" | "LLMResult",
    "BundleId" -> Missing[],
    "CacheKey" -> "..."
  |>
|>
```

---

## 10. 成功した prompt / workflow の保存と昇格

### 10.1 ユーザー指示による保存

以下のような `ClaudeEval` / `ContinueEval` 入力は、保存命令として扱う。

```text
今実行したプロンプトを保存して
最後のプロンプトを保存して
このワークフローを保存して
さっきのClaudeEvalを再利用可能にして
この処理をPromptRouteに登録して
```

この保存命令そのものを保存するのではなく、同じ notebook/session における直前の成功した ClaudeEval / ContinueEval 実行を対象にする。

必要 API:

```mathematica
SourceVaultCaptureLastPromptRun[opts]
SourceVaultPromotePromptRun[runId, opts]
```

### 10.2 パレット操作による保存

ClaudeEval を実行した Input cell を選択し、palette のボタンから保存できるようにする。

推奨ボタン:

- `Save Last ClaudeEval Prompt`
- `Save Selected ClaudeEval Cell as PromptRoute`
- `Save Selected ClaudeEval Cell as WorkflowRoute Draft`

実装 API:

```mathematica
SourceVaultCaptureSelectedClaudeEvalCell[opts]
```

要件:

- セル参照は NBAccess 経由で行う。
- SourceVault registry に `CellObject` を直接保存しない。
- 保存するのは notebook identity、cell index / cell id / ExpressionUUID 等の安全な参照 metadata と prompt fingerprint である。
- 秘密セルの場合は privacy level を継承する。

### 10.3 昇格の分類

成功実行を保存するとき、以下に分類する。

| 実行結果 | 保存先 |
|---|---|
| 既存 route に一致 | `PromptExample` として既存 route に追加 |
| deterministic function call | `PromptRouteDraft` または `PromptRoute` |
| ClaudeOrchestrator trace あり | `WorkflowRouteDraft` |
| LLM one-shot answer のみ | `PromptRun` + `NeedsReview`; すぐ route 化しない |
| side effect あり | `NeedsApproval` 付き draft |

初期実装では、自動昇格は conservative にする。

```text
ReadOnly deterministic route only → PromptRoute に自動昇格可
Workflow trace あり → WorkflowRouteDraft まで
LLM answer only → NeedsReview
```

### 10.4 registry 変更 API の書き込み安全規約

`SourceVaultRegisterPromptRoute`, `SourceVaultPromotePromptRun`, `SourceVaultReprocess` は store 書き込みを伴うため、ClaudeDirective rule 103 のデータストア書き込み安全規約に従う。

- registry / route / workflow を変更する公開 API は `"DryRun" -> True` を既定にする。
- `DryRun -> True` では、変更予定の topic、件数、差分、追加・置換・無効化される `RouteId` を返し、書き込まない。
- 実変更は `"DryRun" -> False` と、必要に応じて `"Confirm" -> True` が明示された場合だけ行う。
- compiled registry の書き換えは `path.tmp` へ書き出し、JSON 検証後に `RenameFile` する atomic write とする。Windows では既存 path を安全に退避または削除してから rename する既存 pattern に合わせる。
- JSON/JSONL 書き込みは必ず `iSanitizeForJSON` を通す。
- JSON/JSONL 読み込みは `ReadByteArray` + `ByteArrayToString` + `StringSplit` 経路を使う。
- 早期 return を含む実装では `Return[expr, Module]` が内側 `Module` だけを抜ける罠を避ける。ストア書き込み対象の選別では、内側 Module 内に関数全体を抜けるつもりの `Return[..., Module]` を置かない。
- 削除より非破壊 mark を優先する。`PromptRoute` / `WorkflowRoute` を廃止する場合も、物理削除ではなく `"LifecycleStatus" -> "Superseded" | "Disabled"` を既定にする。
- 書き込み API の戻り値には `WrittenCount`, `SkippedCount`, `ByAction`, `Topic`, `Channel`, `Path` などの集計を含める。

`SourceVaultPromptRunRecord` の JSONL append は非破壊の履歴追加であるため通常の capture 時に `DryRun -> False` を既定にしてよい。ただし raw prompt を保存する場合、または registry 昇格を伴う場合は、上記の dry-run / confirmation policy に従う。

---

## 11. Privacy propagation と private routing

### 11.1 保存 record に必須の privacy metadata

以下の record には必ず privacy metadata を付ける。

- `PromptRun`
- `PromptExample`
- `PromptRouteDraft`
- `PromptRoute`
- `WorkflowRouteDraft`
- `WorkflowRoute`
- `WorkflowTemplate`
- `WorkflowRun`
- `EvidenceBundle`

最小 metadata:

```mathematica
<|
  "PrivacyLevel" -> 0.0 | 0.75 | 1.0 | _Real,
  "PrivacyOrigin" -> {...},
  "AllowedTrustDomains" -> Automatic | {"Local", "Private", "Cloud"},
  "CloudFallback" -> "Deny" | "NeedsApproval" | "Allow",
  "RawPromptStored" -> False | True,
  "PromptStorageClass" -> "HashOnly" | "PrivateRaw" | "PublicExample"
|>
```

### 11.2 PrivacyLevel 決定規則

保存時の privacy level は次で決める。

```mathematica
PromptRunPrivacyLevel = Max[
  PromptCellPrivacyLevel,
  PromptTextPrivacyLevel,
  NotebookDependencyPrivacyLevel,
  ModelExecutionPrivacyFloor,
  ResultPrivacyLevel,
  UserSpecifiedPrivacyLevel
]
```

意味:

- `PromptCellPrivacyLevel`: NBAccess が返す ClaudeEval cell の privacy level。既存体系では通常 `0.0`, secret/private は `0.75`, highly confidential は `1.0` を基本値とする。
- `PromptTextPrivacyLevel`: prompt 文字列の privacy 判定。初期実装では cell privacy と同じでよい。
- `NotebookDependencyPrivacyLevel`: 参照した notebook cells / files / snapshots の最大 privacy level。
- `ModelExecutionPrivacyFloor`: private/local model で実行した場合、少なくとも cloud 禁止境界以上。既存体系では原則 `0.75` を使い、`0.5` は判定閾値としてのみ扱う。
- `ResultPrivacyLevel`: 出力結果の privacy level。
- `UserSpecifiedPrivacyLevel`: palette や option で指定された値。

### 11.3 秘密セル由来

ClaudeEval cell が秘密セルの場合、保存 record は少なくとも以下を持つ。

```mathematica
"PrivacyLevel" -> Max[inferred, 0.75]
"PrivacyOrigin" -> Append[..., "SecretCell"]
"AllowedTrustDomains" -> {"Local", "Private"}
"CloudFallback" -> "Deny"
"RawPromptStored" -> False
"PromptStorageClass" -> "HashOnly"
```

raw prompt 保存は、ユーザーが明示した場合のみ private registry / private bundle に限定して許可する。

### 11.4 private/local model 実行由来

ClaudeEval 実行時に model が private / local / protected model として解決された場合、保存 record は少なくとも以下を持つ。

```mathematica
"PrivacyLevel" -> Max[inferred, 0.75]
"PrivacyOrigin" -> Append[..., "PrivateModelExecution"]
"AllowedTrustDomains" -> {"Local", "Private"}
"CloudFallback" -> "Deny"
```

### 11.5 route matching への適用

`PromptPrivacyLevel >= 0.5` の場合:

```text
1. Exact fingerprint match は可
2. Deterministic pattern match は可
3. private/local lightweight router LLM のみ可
4. private/local router がなければ NeedsPrivateRouterModel / NeedsApproval
5. cloud lightweight router LLM への自動送信は禁止
```

本仕様で `0.5` は **cloud 送信禁止境界の比較閾値** であり、必ずしも保存 record に新しい privacy 値 `0.5` を導入することを意味しない。既存 SourceVault / NBAccess 体系で secret/private を `0.75` として扱っている場合、secret cell / private model 由来の record は `0.75` 以上へ昇格する。

`ScopeRef` / `PathRef` / symbolic path は identity であり authority ではない。PromptRouter は `$onWork` などの scope を解決して候補 source を得ても、そのこと自体を read / write / cloud-send 権限の根拠にしてはならない。notebook query、cell read、file read、LLM 送信は常に NBAccess の authorization を通す。

---

## 12. Model resolution / fallback

### 12.1 Route / workflow は model 名を直接持たない

`PromptRoute`, `WorkflowRoute`, `WorkflowTemplate` は、原則として具体的 model 名を持たない。代わりに以下を持つ。

```mathematica
<|
  "ModelIntent" -> "router" | "parameterize" | "summary" | "extract" | "code" | "workflow" | "heavyReasoning",
  "WeightClass" -> "Light" | "Medium" | "Heavy" | Automatic,
  "PrivacyLevel" -> 0.0,
  "AllowedTrustDomains" -> {"Cloud", "Private", "Local"},
  "CloudFallback" -> "Allow" | "Deny" | "Ask",
  "RequiredCapabilities" -> {"TextIn", "TextOut"},
  "DegradationPolicy" -> "Flexible" | "AskOnDowngrade" | "Strict"
|>
```

実際の model は既存 resolver に委譲する。

```mathematica
SourceVaultResolve[
  "Model",
  <|
    "Intent" -> intent,
    "WeightClass" -> weightClass,
    "PrivacyLevel" -> privacy,
    "AllowedTrustDomains" -> allowed,
    "CloudFallback" -> cloudFallback,
    "RequiredCapabilities" -> caps,
    "DegradationPolicy" -> policy
  |>
]
```

または、既存の `ClaudeResolveModel` wrapper がある場合は同等の constraints を渡す。

### 12.1.1 resolver 入力契約の実装前確認

現行 SourceVault model registry は、検出した local/private model の `Class` / `Intent` が `Unknown` / `Null` になる場合がある。したがって Phase E の privacy-aware router LLM 実装前に、以下を確認し、不足していれば resolver 側を小拡張する。

必須確認項目:

1. `SourceVaultResolve["Model", query]` が `Intent`, `WeightClass`, `PrivacyLevel`, `AllowedTrustDomains`, `CloudFallback`, `RequiredCapabilities`, `DegradationPolicy` を受け取れるか。
2. 受け取れない場合、PromptRouter 側で直接 model table を走査せず、`SourceVaultResolveModelForPromptRouter[query]` のような薄い wrapper を SourceVault 側に追加するか、既存 `SourceVaultResolve` を後方互換で拡張する。
3. local/private model の `Class` / `Intent` が Unknown の場合は、`Provider`, endpoint kind, capability probe, user override registry から分類する pre-classification step を通す。
4. 分類不能な model は、秘密 prompt の cloud fallback 理由に使ってはならない。`NeedsModelClassification` または `NeedsPrivateModel` を返す。
5. 代替 model を使った場合は `PromptRun` / `WorkflowRun` に requested/resolved/fallback reason を記録する。

この確認が終わるまでは、LLM router を使う Phase E を開始しない。Phase B/C の deterministic route / PromptRun JSONL は resolver 拡張なしで実装してよい。

### 12.2 TrustDomain と WeightClass

TrustDomain:

```text
Cloud    外部クラウド LLM
Private  ユーザーまたは組織管理下の private endpoint
Local    同一マシンまたは LAN 内の local LLM
```

WeightClass:

```text
Light    route selection、分類、短い抽出
Medium   要約、構造化抽出、軽いコード生成
Heavy    複雑な推論、仕様策定、コード改修、workflow 合成
```

WeightClass は絶対サイズではなく、既存 model registry 上の運用区分である。

### 12.3 private/local model が不足する場合の代替

private/local 環境では、Light / Medium / Heavy が揃っているとは仮定しない。1 種類しかない場合もある。

原則:

1. 同一 TrustDomain 内で代替する。
2. Light 要求は Medium / Heavy に自動昇格可。
3. Medium 要求は Heavy に自動昇格可。
4. Heavy 要求を Medium / Light に落とす場合は `DegradationPolicy` に従う。
5. `PrivacyLevel >= 0.5` では、該当 private/local model がなくても cloud へ自動 fallback しない。

Fallback order example:

```text
Request: Local/Private + Light
  1. Local Light
  2. Private Light
  3. Local Medium
  4. Private Medium
  5. Local Heavy
  6. Private Heavy
  7. NeedsModel / NeedsApproval
```

```text
Request: Local/Private + Heavy
  1. Local Heavy
  2. Private Heavy
  3. Local Medium if DegradationPolicy != Strict
  4. Private Medium if DegradationPolicy != Strict
  5. NeedsModel / NeedsApproval
```

代替実行した場合は必ず PromptRun / WorkflowRun に記録する。

```mathematica
<|
  "Requested" -> <|"TrustDomain" -> "Private", "WeightClass" -> "Light"|>,
  "Resolved" -> <|"TrustDomain" -> "Private", "WeightClass" -> "Heavy", "Model" -> "..."|>,
  "FallbackKind" -> "SameDomainHeavierSubstitute",
  "CloudFallbackUsed" -> False
|>
```

### 12.4 Cloud fallback

```text
PrivacyLevel >= 0.5
  CloudFallback -> Deny が既定。cloud fallback しない。

PrivacyLevel < 0.5 かつ CloudFallback -> Allow
  cloud の同等または上位 model へ fallback 可。

PrivacyLevel < 0.5 かつ CloudFallback -> Ask
  ClaudeRuntime Approval / Choice flow へ渡す。
```

---

## 13. WorkflowRoute と Petri-net workflow

### 13.1 WorkflowRoute にする条件

以下のような処理は PromptRoute 単一関数ではなく WorkflowRoute にする。

- 複数 SourceVault query を組み合わせる。
- notebook summary stale check / refresh を含む。
- LLM extraction / summarization を含む。
- ユーザー承認や選択を挟む。
- GitHub issue 作成、notebook 書き換えなど side effect を含む。
- 将来、再処理・resume・trace analysis の対象にしたい。

### 13.2 Workflow execution

WorkflowRoute は ClaudeOrchestrator がロード済みの場合のみ実行する。

```text
ClaudeOrchestrator available
  → WorkflowTemplate を instantiate して ClaudeRunWorkflow

ClaudeOrchestrator unavailable
  → NeedsOrchestrator / NotDispatched
```

### 13.3 transition ごとの privacy / model resolution

Workflow 全体で一度だけ model を決めてはいけない。LLM transition ごとに privacy level を再計算する。

```mathematica
TransitionPrivacyLevel = Max[
  WorkflowRoutePrivacyLevel,
  TokenPrivacyLevel,
  InputArtifactPrivacyLevel,
  SourceSnapshotPrivacyLevel,
  PromptPrivacyLevel
]
```

そのうえで model resolver に渡す。

```mathematica
SourceVaultResolve[
  "Model",
  <|
    "Intent" -> transitionIntent,
    "WeightClass" -> transitionWeightClass,
    "PrivacyLevel" -> TransitionPrivacyLevel,
    "AllowedTrustDomains" -> allowed,
    "CloudFallback" -> cloudFallback,
    "RequiredCapabilities" -> caps,
    "DegradationPolicy" -> policy
  |>
]
```

---

## 14. SourceVault versioning と reprocessing

### 14.1 既存 lifecycle に載せる

PromptRouter 用に新しい versioning system は作らない。既存の SourceVault mechanism に載せる。

利用する既存概念:

- `SourceId`
- `SnapshotId`
- `LifecycleStatus`
- `SourceVaultRefreshSnapshot`
- `SourceVaultMarkSnapshotStale`
- `SourceVaultBundleCreate`
- `SourceVaultBundleStatus`
- `SourceVaultSourceEventAppend`
- compiled registry version

追加 record が持つ version metadata:

```text
PromptRoute:
  RouteId, RouteVersion, SchemaVersion, MatcherVersion, CompiledRegistryVersion

WorkflowRoute:
  RouteId, RouteVersion, WorkflowTemplateId, WorkflowVersion, RequiredRuntimeVersion, RequiredOrchestratorVersion

PromptRun:
  RouteId + RouteVersion, WorkflowTemplateId + WorkflowVersion,
  SourceSnapshotIds, RegistryVersion, ModelResolution
```

### 14.2 外部データ更新時の stale / reprocess flow

```text
SourceVaultSyncPlan[]
  ↓
外部 source / notebook / URL / registry の鮮度確認
  ↓
SourceVaultSync[]
  ↓
変更があれば新 SnapshotId を作成
  ↓
SourceVaultRefreshSnapshot[oldSnap, newSnap, reason]
  ↓
source-events.jsonl に VersionedUpdate を記録
  ↓
旧 snapshot に依存する Bundle / PromptRun / WorkflowRun を stale 扱い
  ↓
SourceVaultReprocessPlan[] が再処理候補を作る
  ↓
安全なものだけ自動再実行、曖昧・重い・副作用ありは承認待ち
```

### 14.3 自動再処理 policy

即時自動再処理を既定にしない。stale marking + reprocess queue を基本にする。

| 処理種別 | 方針 |
|---|---|
| deterministic read-only route | 次回 ClaudeEval / query 時に自動再計算可 |
| summary / extraction | on-demand refresh。LLM / privacy / model availability に従う |
| WorkflowRoute | ClaudeOrchestrator ロード済みの場合のみ候補化。副作用あり・複数候補は approval |
| cloud LLM が必要な再処理 | privacy / `CloudFallback` に従い approval または deny |

必要 API:

```mathematica
SourceVaultReprocessPlan[opts]
SourceVaultReprocess[plan, opts]                              (* "DryRun" -> True 既定 *)
```

---

## 15. ClaudeDirective rules / skills との切り分け

ClaudeDirective の rules / skills は runtime prompt memory ではない。

使い方:

```text
ClaudeDirective rules / skills
  → 実装者・Claude Code への規範、作業手順、禁止事項

SourceVault registry / event / bundle
  → 実行時の記憶、依存関係、再処理対象、PromptRoute / WorkflowRoute
```

rules に書くべき内容:

- ClaudeEval の raw prompt を無条件に永続化してはならない。
- PromptRoute / WorkflowRoute は SourceVault compiled registry に保存する。
- 軽量級 / 中量級 / 重量級 LLM は既存 resolver に従う。
- 秘密セルまたは private model 実行由来の route / workflow は `PrivacyLevel >= 0.5` とする。
- `PrivacyLevel >= 0.5` では cloud LLM へ自動 fallback しない。
- `SourceVault_promptrouter.wl` は `Needs["ClaudeOrchestrator`"]` を呼ばない。
- FunctionRoute は allowlist dispatcher で実行し、`ToExpression` しない。
- ClaudeOrchestrator 未ロード時に WorkflowRoute を実行しない。

skills に書くべき内容:

- PromptRoute 追加時の schema checklist
- WorkflowRoute 追加時の Petri-net template checklist
- privacy metadata review checklist
- model resolution / fallback review checklist
- acceptance test の実行手順

---

## 16. Public API 案

### 16.1 Router status

```mathematica
SourceVaultPromptRouterStatus[]
SourceVaultPromptRouterAvailableQ[]
SourceVaultPromptRouterActiveQ[caller_:Automatic]
```

### 16.2 Route resolution / execution

```mathematica
SourceVaultResolvePromptRoute[prompt_String, opts:OptionsPattern[]]
SourceVaultProposePromptRoute[prompt_String, opts:OptionsPattern[]]   (* ClaudeEval 接続用。未評価 proposal expression を返す *)
SourceVaultExecutePromptRoute[prompt_String, opts:OptionsPattern[]]   (* manual/tests 用。ClaudeEval 通常経路では直接使わない *)
SourceVaultRouteExplain[prompt_String, opts:OptionsPattern[]]
```

重要 options:

```mathematica
"DryRun" -> False                 (* resolve / execute の preview 用。通常実行は False *)
"AllowLLMRouter" -> Automatic
"AllowWorkflow" -> Automatic
"PrivacyLevel" -> Automatic
"StorePrompt" -> "HashOnly"
"FallbackToClaudeEval" -> True
"Caller" -> "ClaudeEval" | "Manual" | Automatic
```

`SourceVaultProposePromptRoute` の `DryRun -> False` は「実行」ではなく「proposal を通常生成する」ことを意味する。`SourceVaultExecutePromptRoute` の `DryRun -> False` は manual/tests 用の route 実行を意味する。`ClaudeEval` 通常経路では `SourceVaultExecutePromptRoute` を直接使わない。registry 書き換え API の `DryRun` とは既定が異なる。registry 書き換え API は §10.4 に従い `DryRun -> True` を既定にする。

### 16.3 Registry

```mathematica
SourceVaultRegisterPromptRoute[route_Association, opts]      (* "DryRun" -> True 既定 *)
SourceVaultListPromptRoutes[opts]
SourceVaultGetPromptRoute[routeId_String, opts]
SourceVaultRecordPromptRouteUse[routeId_String, prompt_String, decision_Association, opts]
```

### 16.4 Prompt capture / promotion

```mathematica
SourceVaultPromptRunRecord[prompt_String, routeDecision_Association, result_, opts]
SourceVaultPromptRunHistory[opts]
SourceVaultCaptureLastPromptRun[opts]
SourceVaultCaptureSelectedClaudeEvalCell[opts]
SourceVaultPromotePromptRun[runId_String, opts]               (* "DryRun" -> True 既定 *)
```

### 16.5 Notebook query wrappers

```mathematica
SourceVaultUpcomingSchedule[opts]
SourceVaultReviewQueue[opts]
SourceVaultFindNotebooks[opts]
```

### 16.6 Reprocessing

```mathematica
SourceVaultReprocessPlan[opts]
SourceVaultReprocess[plan_, opts]
```

---


### 16.7 Petri-net workflow proposal / draft API

`ClaudeOrchestrator` がロード済みの場合のみ、複雑 prompt を Petri-net workflow draft に変換する API を利用できる。`SourceVault_promptrouter.wl` はこれらを直接定義しない。存在確認は `NameQ` / `ValueQ` による weak call とし、`Needs["ClaudeOrchestrator`"]` は呼ばない。

```mathematica
ClaudeProposeWorkflowNetFromPrompt[prompt_String, opts:OptionsPattern[]]
```

自然言語 prompt から WorkflowNet proposal を作る。LLM proposal、feedback retry、静的診断の収集までを担当する。実行や registry 登録は行わない。

```mathematica
ClaudeParseWorkflowNetCode[code_String, opts:OptionsPattern[]]
```

LLM 生成コードを安全な形式で WorkflowNet Association または declarative workflow spec に変換する。生コード全体を `ToExpression` してはならない。sandbox parser の詳細は §23.5.2 に従う。

```mathematica
ClaudeValidateWorkflowNetProposal[proposal_Association, opts:OptionsPattern[]]
```

proposal / parsed net / diagnostics を検証し、`"Accepted" | "NeedsRepair" | "Rejected"` を返す。rule 00 と workflow 専用 forbidden list は単一の merged registry として扱う。

```mathematica
ClaudeCreateWorkflowRouteDraft[prompt_String, proposal_Association, opts:OptionsPattern[]]
```

WorkflowRouteDraft を作成し、workflow code artifact と registry metadata を SourceVault に保存する。既定では `NeedsApproval` とし、自動登録・自動実行しない。

```mathematica
SourceVaultPromptRouteSaveDraft[draft_Association, opts:OptionsPattern[]]
```

PromptRouter 側から WorkflowRouteDraft / PromptRouteDraft を保存する共通入口。書き込み安全規約 §10.4 / §24.2 に従う。

```mathematica
ClaudeRunWorkflowRoute[routeId_String, params_Association, opts:OptionsPattern[]]
```

承認済み WorkflowRoute を実行する。新規生成直後の draft を承認なしに実行する API ではない。


### 16.11 ClaudeEval expression contract tests

PromptRouter を `ClaudeEval` に接続する実装では、次を必須テストにする。

```mathematica
VerificationTest[
  MatchQ[
    SourceVaultProposePromptRoute["今日から3日間のスケジュールを"]["ProposedExpression"],
    HoldComplete[_SourceVaultUpcomingSchedule]
  ],
  True
]
```

```mathematica
VerificationTest[
  FreeQ[
    iClaudeEvalTryPromptRouter["今日から3日間のスケジュールを"],
    _Association?(KeyExistsQ[#, "Type"] && #Type === "PromptRouteExecution" &)
  ],
  True
]
```

```mathematica
VerificationTest[
  ! StringContainsQ[
    ToString[SourceVaultProposePromptRoute["7日間のスケジュールのうちTodoが残っているものを"]["ProposedExpression"], InputForm],
    "iSVPRFormatScheduleGrid"
  ],
  True
]
```

絞り込み付き schedule route は、`SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]` または `SourceVaultFormatScheduleRecords[Select[...]]` のどちらかの形式に正規化されていることを検証する。どちらの場合も、Runtime が検査できない評価済み `Grid` / `Dataset` / `Association` を `ClaudeEval` 入口へ返してはならない。


## 17. Acceptance tests

### 17.1 Deterministic parameter extraction

```mathematica
SourceVaultResolvePromptRoute["3日間のスケジュールを", "DryRun" -> True]
```

期待:

```mathematica
<|"Status" -> "Matched", "Target" -> "SourceVaultUpcomingSchedule", "Parameters" -> <|"PeriodDays" -> 3|>|>
```

```mathematica
SourceVaultResolvePromptRoute["7日間のスケジュールのうちTodoが残っているものを", "DryRun" -> True]
```

期待:

```mathematica
"OpenTodos" -> True
"PeriodDays" -> 7
```

```mathematica
SourceVaultResolvePromptRoute["これから三日間にレビューしないといけない$onWorkのファイルは？", "DryRun" -> True]
```

期待:

```mathematica
"Target" -> "SourceVaultReviewQueue"
"DateField" -> "NextReview"
"PeriodDays" -> 3
"Scope" -> "$onWork" または安全に解決された $onWork path
```

### 17.2 ClaudeEval fallback

- SourceVault 未ロード時、従来 ClaudeEval が壊れない。
- SourceVault ロード済み、Orchestrator 未ロード時、manual API は動くが ClaudeEval 自動 route は既定無効。
- Orchestrator ロード済み時、ClaudeEval から PromptRoute が有効化される。

### 17.3 Prompt capture

```mathematica
ClaudeEval["7日間のスケジュールのうちTodoが残っているものを"]
ClaudeEval["今実行したプロンプトを保存して"]
```

期待:

- 保存命令ではなく直前の成功 run が対象になる。
- `PromptRun` が作成される。
- deterministic route なら `PromptRouteDraft` または `PromptRoute` に昇格可能。

### 17.4 Palette capture

- ClaudeEval input cell を選択して保存 button を押す。
- NBAccess 経由でセル内容を取得する。
- `CellObject` を registry に保存しない。
- secret cell の privacy が反映される。

### 17.5 Privacy

秘密セル由来:

```mathematica
"PrivacyLevel" >= 0.5
"AllowedTrustDomains" -> {"Local", "Private"}
"CloudFallback" -> "Deny"
```

private/local model 実行由来も同様。

`PrivacyLevel >= 0.5` の prompt で deterministic match が失敗し、private/local router LLM がない場合:

```mathematica
"Status" -> "NeedsPrivateRouterModel" | "NeedsApproval"
```

cloud router LLM に自動送信してはならない。

### 17.6 Model fallback

private model が 1 種類だけの場合:

- `Light` router request に対して同一 TrustDomain の available model を代替利用できる。
- 代替 record が `PromptRun` に残る。
- `PrivacyLevel >= 0.5` では cloud fallback しない。

### 17.7 WorkflowRoute

- Orchestrator 未ロード時は `NeedsOrchestrator` または `NotDispatched`。
- Orchestrator ロード済み時は workflow template を instantiate できる。
- 複数候補時は `NeedsChoice`。
- side effect transition は Approval 必須。

---


### 17.8 ClaudeTestKit を用いた決定的テスト方針

LLM を伴う PromptRouter / WorkflowRoute / workflow proposal のテストは、原則として `ClaudeTestKit` を使って決定的にする。

- `CreateMockProvider` で router LLM / workflow proposal LLM の応答を固定する。
- `AssertEventSequence` で `ExactMatch` / `WorkflowProposed` / `WorkflowParsed` / `StaticValidated` / `DraftSaved` / `NeedsApproval` などのイベント列を検証する。
- `AssertNoSecretLeak` で秘密セル由来 prompt / workflow が cloud provider や public trace に流れないことを検証する。
- `AssertValidationDenied` で forbidden call を含む proposal が `Rejected` または `NeedsRepair` になることを検証する。
- `NormalizeClaudeTrace` で `RunId` / `DraftId` / `CreatedAt` / `Timestamp` などの揺れる値を除去し、golden comparison を行う。

テスト対象が LLM 生成を含む場合でも、生成物の自然言語的品質はテストしない。テストするのは、固定 mock 応答に対する pipeline の決定的挙動である。

### 17.9 Workflow / Petri 固有 assert の追加

ClaudeTestKit には現時点で workflow 固有の assert が不足しているため、以下を追加する。

```mathematica
AssertWorkflowNetWellFormed[net_]
AssertWorkflowForbiddenCallsDetected[diagnostics_]
AssertWorkflowRouteDraftStatus[draft_, expected_]
AssertNoToExpressionSideEffect[parseResult_, beforeState_, afterState_]
AssertWorkflowDraftStored[draftId_, opts___]
```

これらは ClaudeTestKit 側に置き、`SourceVault_promptrouter.wl` / `ClaudeOrchestrator_promptworkflow.wl` 本体は `Needs["ClaudeTestKit`"]` しない。

### 17.10 ClaudeTestKit の外で行うテスト

以下は provider / adapter mock だけでは不十分なので、別ハーネスで実施する。

1. sandbox parser safety test
   - `RunProcess`, `Import`, `URLRead`, `ExternalEvaluate`, file write, `SystemCredential`, notebook mutation を含む固定コード文字列を parser に渡す。
   - 副作用が一切起きず、`Rejected` / `NeedsRepair` が返ることを確認する。
2. registry / PromptRun store safety test
   - temporary PrivateVault root を使い、`DryRun -> True` 既定、atomic write、JSON sanitization、append-only JSONL を検証する。
3. reset policy test
   - `SourceVaultResetStore` が PromptRun history を通常削除対象に含めないことを検証する。

テストコードは `*_test.wl` または `tests/` 配下に分離し、パッケージ本体へ ClaudeTestKit 依存を持ち込まない。テスト fixture は Private 変数への直接代入ではなく、公開 API 経由で作成する。

## 18. 実装フェーズ案

### Phase A: SourceVault_promptrouter.wl skeleton

- ファイル追加
- 自動ロード bootstrap
- status API
- Orchestrator / Runtime availability 判定
- no-op / dry-run resolve

### Phase A1: legacy natural dispatch migration

- `$ClaudeEvalPromptRouterDispatch` / `$ClaudeEvalPromptRouterPreemptsNatural` の導入
- PromptRouter active 時に `iClaudeEvalNaturalMatch` を先に走らせない
- 旧 schedule / refresh_summary natural patterns を seed PromptRoute に移す
- legacy fallback としてのみ `$ClaudeEvalNaturalDispatch` を残す

### Phase B: deterministic route

- prompt normalization / fingerprint
- Japanese date period extraction
- `OpenTodos`, `DateField`, `Scope` extraction
- `SourceVaultUpcomingSchedule` option 拡張
- `SourceVaultReviewQueue` 追加
- FunctionRoute allowlist dispatcher

### Phase C: PromptRun recording

- append-only JSONL store `<PrivateVault>/promptrouter/runs/prompt-runs.jsonl`
- `PromptRun` schema
- hash-only default storage
- dependency / model / privacy metadata
- route use history

### Phase D: Prompt capture / palette

- `SourceVaultCaptureLastPromptRun`
- `SourceVaultCaptureSelectedClaudeEvalCell`
- `SourceVaultPromotePromptRun`
- palette button integration
- NBAccess 経由セル参照

### Phase E0: model resolver contract check

- `SourceVaultResolve["Model", ...]` の入力契約確認
- Unknown/Null Class / Intent の local/private model 分類 step
- 不足する場合は resolver wrapper または後方互換拡張を先行

### Phase E: privacy-aware router LLM

- `PromptPrivacyLevel` 推定
- private/local lightweight router LLM のみ利用する policy
- model resolution fallback record
- `NeedsPrivateRouterModel` / `NeedsApproval`

### Phase F: WorkflowRoute integration

- WorkflowRoute registry
- Orchestrator availability gate
- WorkflowTemplate instantiate
- transition-level privacy / model resolution
- Choice / Approval flow

### Phase G: reprocessing

- stale PromptRun / Bundle detection
- `SourceVaultReprocessPlan`
- deterministic read-only auto recompute
- LLM / workflow reprocess approval

---


### 18.1 統合実装順序

個別の Phase A〜J / W1〜W5 は、実装順序としては次の一つの系列に統合する。

| Order | Phase | 内容 | 依存 |
|---:|---|---|---|
| 0 | Baseline audit | `SourceVault`, `claudecode`, `ClaudeRuntime`, `ClaudeOrchestrator_workflow`, `ClaudeOrchestrator_observability`, `petri_from_prompt.wl` の現状 API と重複を棚卸し。成果物は audit メモ、該当 `petri-*` skill への追記、本 spec §23.4 の取り込み表更新 | なし |
| 1 | PromptRun store split | PromptRun を append-only JSONL store に分離。PromptRoute / WorkflowRoute は compiled registry に限定 | §24.1 |
| 2 | Legacy natural dispatch migration | PromptRouter active 時は旧 `iClaudeEvalNaturalMatch` を先に走らせない。旧 natural dispatch は seed PromptRoute へ吸収 | §5.3 |
| 3 | Deterministic FunctionRoute | `UpcomingSchedule`, `ReviewQueue`, canonical parameter extraction, RouteSignature | §6〜§8 |
| 4 | Search index | exact / deterministic / lexical / capability index | §21 |
| 5 | Prompt capture / promotion | 「最後のプロンプトを保存して」および palette capture | §10 |
| 6 | Privacy / model resolver | privacy propagation, private/local model fallback, resolver contract check | §11〜§12 |
| 7 | Promptworkflow sandbox redesign | `petri_from_prompt.wl` の parse 部分を抽出ではなく再設計。safe parser / rule 00 統合 / workflow-specific validation / sandbox parser safety tests を同時に実装 | §23.5, §17.9, Test W7 |
| 8 | Workflow proposal API | `ClaudeProposeWorkflowNetFromPrompt` と feedback retry を正式 API 化 | §23.4〜§23.6 |
| 9 | WorkflowRouteDraft storage | workflow code artifact store、draft metadata、NeedsApproval flow | §23.7, §23.10 |
| 10 | ClaudeEval workflow integration | 既存 route 優先、complex prompt で draft 作成、承認後に登録・実行 | §23.6〜§23.8 |
| 11 | Reprocessing | stale workflow route / code artifact / source snapshot の再処理計画 | §14 |
| 12 | Docs / compatibility | `docs/examples/petri_from_prompt.wl` と `example.md` を compatibility wrapper / 新 API 前提へ更新 | §23.16 |
| 13 | Integrated test hardening | ClaudeTestKit mock tests、parser safety harness、store safety harness の横断的 hardening。各 phase 固有の受け入れテストをここへ後ろ倒ししない | §17.8〜§17.10, §23.15 |

Phase F は「既存 WorkflowRoute の実行統合」を指す。新規 workflow 生成・parse・draft 化は Phase 7〜10 に分離し、Phase F の軽い拡張として扱わない。

各 phase の受け入れテストはその phase 内で用意する。Order 13 は統合 hardening 専用であり、Order 7 の sandbox parser の副作用ゼロ検証や Order 3 の deterministic extraction テストを後ろ倒しする置き場ではない。特に `AssertNoToExpressionSideEffect` / `AssertWorkflowNetWellFormed` / Test W7 は Order 7 の完了条件に含める。

Order 0 の audit は実装前の作業メモで終わらせない。`ClaudeOrchestrator_observability.wl` と `petri_from_prompt.wl` の API 差分表、重複削除方針、不足 helper の所属先を、該当 `petri-*` skill と本 spec §23.4 へ反映してから Order 7 以降に進む。

## 19. 実装時の禁止事項

- `SourceVault_promptrouter.wl` から `Needs["ClaudeOrchestrator`"]` を自動実行しない。
- `claudecode.wl` に SourceVault hard dependency を追加しない。
- registry 内の function symbol 文字列を `ToExpression` で直接実行しない。
- ClaudeEval raw prompt を無条件に保存しない。
- secret/private prompt の route selection に cloud LLM を自動使用しない。
- private/local model が見つからない場合に cloud へ自動 fallback しない。
- `CellObject` を SourceVault registry に永続保存しない。
- ClaudeDirective rules / skills を runtime route memory として使わない。

---

## 20. 最終方針

この仕様の中心は、`ClaudeEval` を「毎回 LLM に考えさせる入口」から、「SourceVault に保存された routable knowledge / workflow をまず探索し、必要な場合だけ LLM を呼ぶ入口」へ変えることである。

ただし、そのために新しい巨大な基盤を作るのではなく、以下に落とし込む。

```text
日常 prompt の記憶      → SourceVault compiled registry の PromptRoute / PromptExample
成功実行の記録          → append-only JSONL の PromptRun / EvidenceBundle
複雑な再利用処理        → ClaudeOrchestrator WorkflowRoute / Petri-net template
秘密情報の制御          → NBAccess privacy metadata + SourceVault privacy propagation
model 選択              → 既存 SourceVaultResolve / ClaudeResolveModel / model registry
曖昧候補・副作用承認    → ClaudeRuntime Approval / Choice flow
実装規範                → ClaudeDirective rules / skills
```

この構造により、日常的な prompt は高速・安全に再利用でき、複雑な prompt は workflow 化され、秘密セルや private model 由来の workflow は適切な privacy level と model constraint を保ったまま実行される。


---

## 21. 登録 PromptRoute / WorkflowRoute が増えた場合の検索機構

### 21.1 追加方針

登録 prompt / route / workflow が増えてきた場合、`SourceVaultResolvePromptRoute[prompt]` は registry 全体を毎回線形 scan してはならない。PromptRoute / WorkflowRoute / PromptExample は、SourceVault Stage 6b compiled registry に保存したまま、ロード時または registry 更新時に **PromptRoute search index** を構築して検索する。

この検索 index は新しい独立 DB ではなく、既存 compiled registry の派生物とする。

```text
SourceVault registry
  PromptRoute
  WorkflowRoute
  PromptExample
  WorkflowTemplate metadata
    ↓ compile / rebuild
SourceVault PromptRoute search index
  exact fingerprint index
  lexical / keyword inverted index
  parameter hint index
  capability / workflow index
  optional local semantic index
```

### 21.2 保存場所

index は既存の compiled registry layout に合わせて保存する。

例:

```text
compiled/public/prompt-route-index.json
compiled/private/prompt-route-index.json
compiled/public/workflow-route-index.json
compiled/private/workflow-route-index.json
```

または既存実装の compiled registry path convention に従う。

index record には以下を持たせる。

```mathematica
<|
  "Type" -> "PromptRouteIndex",
  "IndexVersion" -> 1,
  "GeneratedAt" -> "...",
  "GeneratedFromRegistryVersion" -> "...",
  "PrivacyPartition" -> "Public" | "Private",
  "ContainsRawPrompt" -> False,
  "NormalizerVersion" -> 1,
  "Entries" -> <| ... |>
|>
```

原則として index に raw prompt は保存しない。保存するのは normalized token、fingerprint、tag、route id、workflow id、parameter hints である。raw prompt を保存する必要がある場合は private registry の `PromptExample` 側にのみ保存し、index 側には入れない。

### 21.3 検索階層

`SourceVaultResolvePromptRoute[prompt]` は次の順に候補を絞る。

```text
1. exact fingerprint lookup
2. deterministic parameterized lookup
3. lexical / keyword inverted index search
4. capability / workflow index search
5. optional semantic similarity search
6. privacy-aware lightweight router LLM
7. heavyweight fallback
```

#### 1. exact fingerprint lookup

完全一致再利用のため、normalized prompt の hash を使う。

```mathematica
PromptHash = Hash[SourceVaultNormalizePrompt[prompt], "SHA256"]
```

`PromptHash -> {RouteId, ExampleId, LastGoodRunId}` の index があれば、LLM を呼ばずに候補を返す。

#### 2. deterministic parameterized lookup

`"3日間のスケジュールを"` と `"7日間のスケジュールのうちTodoが残っているものを"` のように、同じ route で option だけ変わる prompt は、fingerprint 一致ではなく parameter extraction で解決する。

抽出対象例:

| 表現 | 抽出 parameter |
|---|---|
| `3日間`, `三日間`, `今週`, `来週` | `PeriodDays`, `DateRange` |
| `Todoが残っている`, `未完了`, `doneでない` | `OpenTodos -> True` |
| `レビュー`, `見直し` | `DateField -> "NextReview"` または `RouteKind -> ReviewQueue` |
| `締切`, `期限`, `Deadline` | `DateField -> "Deadline"` |
| `$onWork`, `onWork` | `Scope -> "$onWork"` |

#### 3. lexical / keyword inverted index search

PromptRoute / PromptExample の normalized token から inverted index を作る。

例:

```mathematica
<|
  "スケジュール" -> {"route-upcoming-schedule-v1"},
  "予定" -> {"route-upcoming-schedule-v1"},
  "todo" -> {"route-upcoming-schedule-v1", "route-open-todos-v1"},
  "レビュー" -> {"route-review-queue-v1"},
  "nextreview" -> {"route-review-queue-v1"}
|>
```

日本語では形態素解析に依存しすぎず、まずは以下の軽量 normalizer で十分とする。

- Unicode normalization
- 全角英数・半角英数の正規化
- 大文字小文字の正規化
- 数字・漢数字の正規化
- `NextRebiew` のような既知 typo の正規化
- `Todo`, `TODO`, `todo`, `未完了`, `doneでない` の同義語 map
- `レビュー`, `見直し`, `review` の同義語 map

#### 4. capability / workflow index search

WorkflowRoute は自然言語 keyword だけでなく、workflow の能力からも検索する。

WorkflowRoute index には以下を入れる。

```mathematica
<|
  "WorkflowRouteId" -> "workflow-review-notebooks-v1",
  "Capabilities" -> {
    "FindNotebooks",
    "FilterByNextReview",
    "FilterByOpenTodos",
    "SummarizeNotebook",
    "RankReviewQueue"
  },
  "InputSchema" -> <|"Prompt" -> "String", "Scope" -> "String"|>,
  "OutputSchema" -> <|"Kind" -> "ReviewQueue"|>,
  "SideEffectClass" -> "ReadOnly",
  "RequiredPackages" -> {"SourceVault", "ClaudeRuntime", "ClaudeOrchestrator"},
  "RequiredModelIntents" -> {"router", "summary"},
  "PrivacyFloor" -> 0.5
|>
```

これにより、`"レビューしないといけないファイルのリスト"` のような prompt が、単なる GitHub file 処理ではなく、`NextReview` と `OpenTodoCount` を扱う notebook review workflow に結びつく。

#### 5. optional semantic similarity search

登録数が増え、keyword だけでは不十分になった場合のみ、semantic index を導入する。

ただし privacy 制約は厳格にする。

- public prompt / public route の embedding は cloud embedding を許可してもよい。
- private prompt / private route の embedding は local/private embedding model のみ許可する。
- private prompt を cloud embedding API に送らない。
- local embedding model が無い場合、semantic search は省略し、deterministic / lexical / router LLM に fallback する。

semantic index は必須機能ではなく、Phase 後半の optimization とする。

### 21.4 候補 ranking

検索結果は単に最初の候補を返さず、score と理由を持つ candidate list にする。

```mathematica
<|
  "Decision" -> "Candidates",
  "Candidates" -> {
    <|
      "RouteId" -> "route-sourcevault-upcoming-schedule-v1",
      "Kind" -> "FunctionRoute",
      "Score" -> 0.91,
      "Reasons" -> {
        "keyword:スケジュール",
        "parameter:PeriodDays=7",
        "parameter:OpenTodos=True"
      },
      "Parameters" -> <|"PeriodDays" -> 7, "OpenTodos" -> True|>,
      "PrivacyLevel" -> 0.5
    |>,
    <|
      "RouteId" -> "workflow-review-notebooks-v1",
      "Kind" -> "WorkflowRoute",
      "Score" -> 0.76,
      "Reasons" -> {"keyword:レビュー", "capability:FilterByNextReview"}
    |>
  }
|>
```

ranking では以下を考慮する。

| 要素 | 意味 |
|---|---|
| exact fingerprint | 最優先。成功済み prompt の完全一致 |
| parameter coverage | 期間、Todo、Scope などの抽出が schema と合うか |
| keyword overlap | normalized keyword / synonym の一致 |
| capability match | workflow の能力が prompt と合うか |
| side-effect compatibility | read-only prompt に side-effect workflow を出さない |
| privacy compatibility | prompt / route / source の privacy 制約に合うか |
| package availability | Runtime / Orchestrator / model が利用可能か |
| historical success | 過去の successful PromptRun があるか |
| recency | 最近保存・成功した route を弱く優先 |

ただし historical success / recency は補助的に使い、明示的な parameter mismatch を上書きしてはならない。

### 21.5 自動決定と承認

検索結果は confidence に応じて処理する。

```text
exact match + route version current
  → auto execute

single high-confidence deterministic match
  → auto execute

multiple close candidates
  → ClaudeRuntime Choice / Approval

candidate requires private/local model but unavailable
  → NeedsPrivateModel / NeedsApproval

candidate requires ClaudeOrchestrator but unloaded
  → NeedsOrchestrator / fallback

low confidence
  → privacy-aware lightweight router LLM

still unresolved
  → existing heavy ClaudeEval fallback
```

候補が複数ある場合、ユーザーには route 名だけでなく「なぜ候補になったか」を表示する。

例:

```text
候補 1: SourceVaultUpcomingSchedule
理由: 「スケジュール」「7日間」「Todoが残っている」に一致
実行内容: notebook cache から Deadline/NextReview が7日以内で OpenTodoCount>0 のものを列挙

候補 2: SourceVaultReviewQueue
理由: 「レビュー」に一致
実行内容: NextReview が近い notebook を優先度順に列挙
```

### 21.6 privacy partition と検索時の情報漏洩防止

PromptRoute search index は privacy partition を持つ。

```text
public index
private index
```

検索自体は local deterministic 処理なので、public prompt から private index を検索しても直ちに cloud 漏洩にはならない。ただし private route metadata が表示・外部送信される可能性があるため、以下の規則にする。

1. `SourceVaultResolvePromptRoute` は、候補の `PrivacyLevel` を必ず返す。
2. private route が候補に含まれる場合、decision 全体の `PrivacyLevel` を `Max[prompt, route]` に昇格する。
3. private candidate list を cloud router LLM に送らない。
4. private route の `Title`, `Description`, `Examples` が秘密情報を含む可能性があるため、public UI 表示用には `PublicLabel` / `SafeDescription` を使う。
5. private route を自動実行した結果は、source dependencies の privacy level を継承する。

したがって、個人 notebook cache を読む `SourceVaultUpcomingSchedule` や `SourceVaultReviewQueue` は、prompt 文字列が公開可能に見えても、実行結果の privacy は notebook source 側から昇格する。

### 21.7 API 追加案

検索機構のため、以下の API を `SourceVault_promptrouter.wl` に追加する。

```mathematica
SourceVaultNormalizePrompt[prompt_String, opts___Rule]
```

prompt を正規化する。fingerprint / keyword extraction / parameter extraction の共通入口。

```mathematica
SourceVaultPromptFingerprint[prompt_String, opts___Rule]
```

normalized prompt から hash を作る。

```mathematica
SourceVaultBuildPromptRouteIndex[opts___Rule]
```

PromptRoute / WorkflowRoute / PromptExample registry から search index を構築する。

```mathematica
SourceVaultPromptRouteIndexStatus[opts___Rule]
```

index の version、staleness、entry count、privacy partition を返す。

```mathematica
SourceVaultSearchPromptRoutes[prompt_String, opts___Rule]
```

index を使って候補 route list を返す。実行はしない。

```mathematica
SourceVaultExplainPromptRouteMatch[prompt_String, routeId_String, opts___Rule]
```

指定 prompt が route に一致した理由を返す。

```mathematica
SourceVaultInvalidatePromptRouteIndex[reason_:Automatic]
```

registry 更新時に index を stale として mark する。

既存 API との関係:

```mathematica
SourceVaultResolvePromptRoute[prompt_String, opts___Rule]
```

は内部で `SourceVaultSearchPromptRoutes` を呼び、candidate ranking、privacy check、approval decision を加える。

### 21.8 index 更新方針

PromptRoute / WorkflowRoute / PromptExample が追加・変更された場合、以下のいずれかで index を更新する。

初期実装では simple rebuild でよい。

```text
registry update
  ↓
SourceVaultInvalidatePromptRouteIndex[]
  ↓
次回 SourceVaultSearchPromptRoutes 時に lazy rebuild
```

登録数が増えて rebuild が重くなった場合のみ incremental update に進む。

```text
PromptRoute added
  ↓
追加 route の normalized fields を計算
  ↓
exact index / inverted index / capability index に差分追加
  ↓
IndexVersion を更新
```

### 21.9 PromptExample の扱い

登録 prompt が増えたとき、すべてを新規 PromptRoute にしてはならない。既存 route と同じ function/workflow/parameter schema で処理できる prompt は、既存 route の `PromptExample` として追加する。

例:

```text
"3日間のスケジュールを"
"これから3日の予定"
"三日以内にレビューするもの"
"7日間のスケジュールのうちTodoが残っているものを"
```

これらは多くの場合、同じ `SourceVaultUpcomingSchedule` / `SourceVaultReviewQueue` route に対する PromptExample と parameter variation である。

Route 増殖を避けるため、保存時には以下を確認する。

```text
1. exact same prompt already exists?
2. same normalized fingerprint already exists?
3. same target function + same parameter schema の route がある?
4. same workflow template + compatible input schema の route がある?
5. なければ PromptRouteDraft / WorkflowRouteDraft を作る
```

### 21.10 実装フェーズへの追加

既存 Phase A〜G に加えて、以下を追加する。

#### Phase H: PromptRoute search index

- `SourceVaultNormalizePrompt`
- `SourceVaultPromptFingerprint`
- exact fingerprint index
- lexical / synonym inverted index
- `SourceVaultSearchPromptRoutes`
- `SourceVaultExplainPromptRouteMatch`
- `SourceVaultPromptRouteIndexStatus`
- lazy rebuild / stale marking

#### Phase I: Workflow capability index

- WorkflowRoute capability metadata
- `RequiredPackages`, `RequiredModelIntents`, `PrivacyFloor`
- function route と workflow route の unified ranking
- Orchestrator availability を ranking に反映

#### Phase J: optional semantic index

- local/private embedding support
- public/private partition
- semantic candidate retrieval
- semantic search が使えない環境で deterministic search に安全 fallback

### 21.11 Acceptance tests 追加

```mathematica
VerificationTest[
  SourceVaultSearchPromptRoutes["7日間のスケジュールのうちTodoが残っているものを"]["Candidates"][[1, "RouteId"]],
  "route-sourcevault-upcoming-schedule-v1"
]
```

```mathematica
VerificationTest[
  SourceVaultResolvePromptRoute["レビューしないといけないファイルのリストを"]["Candidates"][[1, "RouteKind"]],
  "ReviewQueue" | "WorkflowRoute"
]
```

```mathematica
VerificationTest[
  SourceVaultPromptRouteIndexStatus[]["StaleQ"],
  False
]
```

```mathematica
VerificationTest[
  SourceVaultSearchPromptRoutes["最後のプロンプトを保存して"]["Candidates"],
  {},
  SameTest -> (FreeQ[#1, "save-last-prompt-command-route"] &)
]
```

最後の test は、保存命令そのものを通常 route として誤って登録・実行しないことを確認する。

### 21.12 結論

登録 prompt が増えた場合の検索は、LLM に全件を読ませるのではなく、SourceVault compiled registry から派生した search index で行う。最初は exact fingerprint + deterministic extraction + lexical inverted index で十分であり、semantic search は必要になってから local/private 対応を前提に追加する。

この方針により、登録 prompt が増えても、`ClaudeEval` は以下の順序を保てる。

```text
高速 exact match
  → deterministic parameter match
  → indexed candidate search
  → privacy-aware lightweight router LLM
  → WorkflowRoute / Approval
  → heavyweight fallback
```

また、private prompt / private workflow が増えても、search candidate や route metadata が cloud LLM に流れないように、privacy partition と candidate-level privacy propagation を search index の段階から適用する。

---

## 22. 基本実行・完全一致・言い回し違いの同一判定

この節では、登録済み PromptRoute / WorkflowRoute が存在する場合に、`ClaudeEval[prompt]` がどのように実行されるかを明確化する。特に、以下を仕様として固定する。

- prompt text の完全一致だけを同一性判定に使わない。
- 最終的な同一性は `RouteSignature`、すなわち「どの route を、どの canonical parameter で、どの scope / privacy 条件で実行するか」で判定する。
- 外部データ・notebook cache・compiled registry が current であれば、SourceVault 内の current snapshot / cache を使って実行する。
- stale / missing が検出された場合は、必要な cache / snapshot を更新してから実行する。ただし、LLM、外部 write、workflow 実行、privacy-sensitive な処理は approval / policy に従う。

### 22.1 二種類の cache を区別する

PromptRouter では、少なくとも以下の二種類の cache を区別する。

| 種類 | 目的 | key | 代表的な内容 |
|---|---|---|---|
| PromptRoute cache | prompt から route / parameter への解決を高速化する | `PromptFingerprint`, `NormalizedPrompt`, search index | `RouteId`, `CanonicalParameters`, `MatchKind`, `Confidence` |
| Result cache | 同じ route call の結果を再利用する | `RouteSignature`, dependency snapshot ids, registry version | function result, workflow result, EvidenceBundle |

重要なのは、**prompt が一致したから結果をそのまま返す** のではない、という点である。prompt が一致した場合でも、依存している notebook index / external source / workflow template / compiled registry の鮮度を確認してから、再利用または再実行を決める。

### 22.2 基本実行フロー

登録済み route が見つかった場合の基本フローは以下である。

```text
ClaudeEval[prompt]
  ↓
SourceVaultResolvePromptRoute[prompt]
  ↓
RouteId + CanonicalParameters + Scope + Privacy を決定
  ↓
RouteSignature を生成
  ↓
SourceVaultRouteDependencies[RouteSignature] を確認
  ↓
依存 snapshot / index / registry が current
  ├─ Result cache が使える場合: cached result を返す
  └─ Result cache がない、または動的 query の場合: current snapshot 上で関数 / workflow を実行
  ↓
stale / missing がある場合
  ├─ deterministic read-only refresh で更新可能: SourceVaultSync / Refresh 後に実行
  ├─ LLM refresh が必要: policy に従い local/private/light/heavy を解決、必要なら approval
  ├─ workflow refresh が必要: ClaudeOrchestrator がロード済みなら workflow 候補へ
  └─ approval / model / orchestrator が不足: NeedsApproval / NeedsModel / NeedsOrchestrator
```

したがって、ユーザーの理解としては次でよい。

```text
対応する関数呼び出しまたは workflow が見つかる
  ↓
外部データ・notebook cache が更新不要ならそのまま実行して終了
  ↓
更新が必要なら、許可された範囲で cache / snapshot を更新してから実行
```

ただし、仕様上は「更新が必要なら常に即時更新」ではなく、更新の種類ごとに安全側に分岐する。

### 22.3 freshness policy

| 更新対象 | 自動更新可否 | 例 | 備考 |
|---|---:|---|---|
| local notebook index | 原則可 | `Deadline`, `NextReview`, `OpenTodoCount` の再走査 | NBAccess privacy policy に従う |
| compiled registry index | 原則可 | PromptRoute search index の再構築 | side-effect は SourceVault 内部に限定 |
| deterministic local derived cache | 原則可 | schedule table, review queue table | read-only route なら自動再計算可 |
| LLM summary / extraction | 原則 on-demand / approval | notebook 要約、claim extraction | private / cloud policy と model resolver に従う |
| external network read | policy 依存 | GitHub, arXiv, URL refresh | credentials / privacy / network policy を確認 |
| external write | approval 必須 | GitHub issue 作成、commit | PromptRoute の自動実行では行わない |
| workflow execution | Orchestrator が必要 | Petri-net workflow | 複数候補・副作用ありは Choice / Approval |

### 22.4 完全一致の場合

完全一致では、raw prompt 文字列ではなく、正規化済み prompt の fingerprint を使う。

```text
raw prompt
  ↓ SourceVaultNormalizePrompt
normalized prompt
  ↓ SourceVaultPromptFingerprint
PromptFingerprint
  ↓ exact fingerprint index
RouteId + CanonicalParameters
```

初期実装での正規化は、少なくとも以下を含む。

- 前後空白、連続空白の正規化
- 全角数字 / 半角数字の正規化
- 句読点、疑問符、改行の軽微な正規化
- 日本語数詞の小範囲正規化: `一`, `二`, `三`, ..., `十`
- `三日間`, `3日間`, `3 日間` の統一
- `一週間`, `7日間`, `7 日間` の統一。ただし `今週` は calendar week と rolling 7 days の曖昧性があるため、文脈依存で扱う。

例:

```text
3日間のスケジュールを
三日間のスケジュールを
3 日間の予定を
```

これらは、正規化後に同一または近い fingerprint / deterministic route candidate へ落ちるべきである。

### 22.5 言い回しが少し違うが内容が同じ場合

prompt text が完全一致しない場合は、RouteSignature の一致を試みる。

`RouteSignature` は以下から構成される。

```mathematica
<|
  "RouteId" -> routeId,
  "RouteVersion" -> routeVersion,
  "TargetKind" -> "Function" | "Workflow",
  "FunctionId" -> "SourceVaultUpcomingSchedule" | Missing[],
  "WorkflowTemplateId" -> Missing[] | "wf-template-...",
  "CanonicalParameters" -> params,
  "Scope" -> scope,
  "PrivacyClass" -> privacyClass,
  "SideEffectClass" -> sideEffectClass
|>
```

同一性判定の基本規則:

1. `RouteId` が同じである。
2. `CanonicalParameters` が同じである。
3. `Scope` が同じ、または `Automatic` が同じ解釈に解決される。
4. `PrivacyClass` が安全側に矛盾しない。秘密由来 route を public route と同一視して cloud に送ってはならない。
5. `SideEffectClass` が同じである。read-only と write route を同一視してはならない。

### 22.6 例1: スケジュール + 未完了 Todo

以下の prompt は、表現は異なるが同じ RouteSignature に解決されるべきである。

```text
7日間のスケジュールのうちTodoが残っているものを
今後一週間で未完了Todoがある予定を出して
一週間以内の予定で、まだTodoが終わっていないものを出して
open todo がある今後 7 days の schedule を出して
```

期待される canonical intent:

```mathematica
<|
  "Intent" -> "UpcomingSchedule",
  "PeriodDays" -> 7,
  "OpenTodos" -> True,
  "DateField" -> "Both",
  "Scope" -> Automatic
|>
```

期待される canonical call:

```mathematica
SourceVaultUpcomingSchedule[
  "Period" -> Quantity[7, "Days"],
  "OpenTodos" -> True,
  "DateField" -> "Both",
  "Scope" -> Automatic,
  "Refresh" -> "IfStale"
]
```

この場合、初回は lexical / deterministic parameter extraction により解決し、成功後に PromptExample として route に追加してよい。次回以降は exact fingerprint または RouteSignature candidate として、LLM なしで解決される。

### 22.7 例2: NextReview / review queue

以下の prompt は、`SourceVaultReviewQueue` または同等の WorkflowRoute に解決されるべきである。

```text
これから三日間にレビューしないといけない$onWorkのファイルは？
今後3日で見直す必要がある $onWork のノートブックを出して
三日以内の NextReview 対象を $onWork から出して
$onWork のレビュー期限が近いファイルを三日分
```

期待される canonical intent:

```mathematica
<|
  "Intent" -> "ReviewQueue",
  "PeriodDays" -> 3,
  "DateField" -> "NextReview",
  "ScopeRef" -> <|"Kind" -> "RootSymbol", "Name" -> "$onWork"|>,
  "IncludeOverdue" -> True,
  "OpenTodos" -> Missing[]
|>
```

期待される canonical call:

```mathematica
SourceVaultReviewQueue[
  "Period" -> Quantity[3, "Days"],
  "DateField" -> "NextReview",
  "ScopeRef" -> <|"Kind" -> "RootSymbol", "Name" -> "$onWork"|>,
  "IncludeOverdue" -> True,
  "OpenTodos" -> Missing[],
  "Refresh" -> "IfStale"
]
```

注意:

- `レビューしないといけない` は GitHub repository file の経過日数ではなく、notebook cache の `NextReview` を第一候補にする。
- `$onWork` は任意の Wolfram Language 式として評価してはならない。SourceVault / NBAccess の安全な scope resolver に登録されている場合だけ解決する。
- `NextRebiew` のような typo が既存 cache field に存在する場合は、移行層で `NextReview` に正規化する。ただし仕様上の正式名は `NextReview` とする。

### 22.8 例3: Deadline と NextReview の違い

以下は同じではない。

```text
今週締切のファイルを出して
今週レビューしないといけないファイルを出して
```

前者:

```mathematica
SourceVaultUpcomingSchedule[
  "Period" -> Quantity[7, "Days"],
  "DateField" -> "Deadline"
]
```

後者:

```mathematica
SourceVaultReviewQueue[
  "Period" -> Quantity[7, "Days"],
  "DateField" -> "NextReview"
]
```

`締切`, `Deadline`, `期限` は `DateField -> "Deadline"` を優先する。`レビュー`, `見直し`, `NextReview` は `DateField -> "NextReview"` を優先する。

### 22.9 例4: 曖昧な prompt は NeedsChoice

以下は一意に決めない。

```text
今週のタスクを出して
今週やるべきことを出して
作業が必要なファイルを出して
```

候補:

```mathematica
{
  <|"Label" -> "今週 Deadline の notebook", "RouteId" -> "route-upcoming-deadline-v1"|>,
  <|"Label" -> "今週 NextReview の notebook", "RouteId" -> "route-review-queue-v1"|>,
  <|"Label" -> "未完了 Todo がある notebook", "RouteId" -> "route-open-todos-v1"|>,
  <|"Label" -> "今週の schedule entry", "RouteId" -> "route-upcoming-schedule-v1"|>
}
```

期待される返り値:

```mathematica
<|
  "Status" -> "NeedsChoice",
  "Reason" -> "MultipleRouteSignaturesMatched",
  "Choices" -> choices,
  "DefaultChoice" -> Missing[],
  "PromptPrivacyLevel" -> promptPrivacy
|>
```

ClaudeRuntime がロード済みなら Approval / Choice UI に渡す。ClaudeRuntime がない場合は候補リストを返し、従来 ClaudeEval fallback へ進むか、ユーザーに明示的な prompt の再入力を促す。

### 22.10 例5: function route と workflow route の選択

以下のような単純 query は FunctionRoute を優先する。

```text
7日間のスケジュールのうちTodoが残っているものを
```

優先 route:

```text
FunctionRoute: SourceVaultUpcomingSchedule
```

一方、以下のように複数段階の処理を含む prompt は WorkflowRoute 候補にする。

```text
今週レビューしないといけないファイルを重要度順に並べ、未完了Todoを要約し、今日処理すべき順番を提案して
```

候補:

```text
WorkflowRoute: wf-template-review-queue-prioritize-v1
```

WorkflowRoute は ClaudeOrchestrator がロード済みの場合のみ自動実行候補にする。ClaudeOrchestrator が未ロードの場合は、`NeedsOrchestrator` または FunctionRoute への degraded fallback とする。

### 22.11 同一 prompt の再利用と似た prompt の学習

ある prompt が成功した場合、ユーザーが明示的に保存を指示したときだけ、PromptExample / PromptRouteDraft / WorkflowRouteDraft に昇格できる。

例:

```mathematica
ClaudeEval["今後一週間で未完了Todoがある予定を出して"]
ClaudeEval["今実行したプロンプトを保存して"]
```

この場合、保存命令そのものではなく、直前の成功 run を保存対象にする。

保存される PromptExample の例:

```mathematica
<|
  "Type" -> "PromptExample",
  "ExampleId" -> "pex-...",
  "RouteId" -> "route-sourcevault-upcoming-schedule-v1",
  "PromptFingerprint" -> "sha256:...",
  "NormalizedPrompt" -> "今後 7 日間で 未完了 Todo がある 予定 を出して",
  "RawPromptStored" -> False,
  "ExtractedParameters" -> <|
    "PeriodDays" -> 7,
    "OpenTodos" -> True,
    "DateField" -> "Both"
  |>,
  "RouteSignatureHash" -> "sha256:...",
  "Privacy" -> <|
    "PrivacyLevel" -> inheritedPrivacy,
    "PrivacyOrigin" -> {"PromptRun"}
  |>
|>
```

秘密セル由来、または private/local model 実行由来の場合は、PromptExample / RouteSignature / WorkflowRouteDraft の privacy level を `0.5` 以上に昇格する。

### 22.12 LLM router を使う場合の条件

言い回しが異なる prompt に対して、最初から LLM に意味判定させてはならない。以下の deterministic / indexed 段階で一意に決まらない場合に限って router LLM を使う。

```text
1. exact fingerprint match
2. deterministic parameter extraction
3. lexical / synonym inverted index
4. workflow capability index
5. optional local semantic index
6. privacy-aware lightweight router LLM
7. heavyweight fallback
```

router LLM に渡してよい情報は、privacy policy に従って制限する。

- `PromptPrivacyLevel >= 0.5` の場合、cloud router LLM を使ってはならない。
- private route / private workflow の candidate metadata を cloud router LLM に渡してはならない。
- private/local model の該当 weight class が存在しない場合は、同一 trust domain 内の代替 model を使う。代替もなければ `NeedsPrivateModel` / `NeedsApproval` を返す。

### 22.13 Result cache の再利用条件

Result cache を返してよい条件:

1. `RouteSignatureHash` が一致する。
2. 依存する `SourceSnapshotId` / notebook cache version / compiled registry version が current である。
3. `RouteVersion` / `WorkflowVersion` が一致する、または互換 version として宣言されている。
4. `PrivacyClass` が現在の request に対して安全側に矛盾しない。
5. Result cache の TTL / freshness policy を満たす。

Result cache を返してはならない条件:

- notebook cache が stale。
- `NextReview`, `Deadline`, `OpenTodoCount` の基礎 snapshot が更新済み。
- WorkflowTemplate が更新され、過去結果との互換性が不明。
- 過去結果が cloud LLM 由来で、現在 prompt が private-only と判定された。
- side-effect を含む workflow の過去結果を、再実行したかのように返す場合。

### 22.14 仕様上の不変条件

PromptRouter は以下を満たさなければならない。

1. Prompt text が完全一致しても、依存データが stale なら stale result を無条件に返してはならない。
2. Prompt text が異なっても、同一 RouteSignature が deterministic に得られる場合は、LLM を呼ばず同じ route call として実行してよい。
3. `Deadline` と `NextReview` は明確に区別する。
4. `StatusFilter -> {"Todo"}` と `OpenTodoCount > 0` は別概念として扱う。
5. scope resolver で安全に解決できない `$onWork` 等の記号を `ToExpression` してはならない。
6. private prompt / private route / secret-derived workflow を cloud router LLM に渡してはならない。
7. 複数の RouteSignature 候補が同程度に成立する場合は、勝手に一つを選ばず `NeedsChoice` にする。
8. function route と workflow route の両方が候補になる場合、単純 read-only query は function route を優先し、複数段階・判断・要約・副作用を含むものは workflow route を候補にする。

### 22.15 acceptance tests 追加

```mathematica
VerificationTest[
  SourceVaultResolvePromptRoute[
    "7日間のスケジュールのうちTodoが残っているものを"
  ]["RouteSignature", "CanonicalParameters", "OpenTodos"],
  True
]
```

```mathematica
VerificationTest[
  SourceVaultResolvePromptRoute[
    "今後一週間で未完了Todoがある予定を出して"
  ]["RouteSignatureHash"],
  SourceVaultResolvePromptRoute[
    "7日間のスケジュールのうちTodoが残っているものを"
  ]["RouteSignatureHash"]
]
```

```mathematica
VerificationTest[
  SourceVaultResolvePromptRoute[
    "これから三日間にレビューしないといけない$onWorkのファイルは？"
  ]["RouteSignature", "CanonicalParameters", "DateField"],
  "NextReview"
]
```

```mathematica
VerificationTest[
  SourceVaultResolvePromptRoute[
    "今週のタスクを出して"
  ]["Status"],
  "NeedsChoice"
]
```

```mathematica
VerificationTest[
  SourceVaultExecutePromptRoute[
    "7日間のスケジュールのうちTodoが残っているものを",
    "DryRun" -> True
  ]["ExecutionPlan", "FreshnessPolicy"],
  "CheckDependenciesBeforeResultCache"
]
```

### 22.16 結論

PromptRouter の基本動作は、prompt text の一致ではなく、`RouteSignature` の一致を中心に設計する。完全一致は高速経路として扱うが、依存データの freshness check は必ず行う。言い回しが違うだけの prompt は、deterministic parameter extraction、synonym index、workflow capability index、必要に応じて privacy-aware router LLM により、同一 canonical route call へ解決する。

これにより、登録 prompt が増えても、日常的な定型 prompt は次のように処理できる。

```text
同じ prompt
  → exact fingerprint
  → freshness check
  → cached result または current snapshot 上で実行

言い回し違いだが同じ内容
  → canonical parameters 抽出
  → RouteSignature 一致
  → freshness check
  → 同じ関数 / workflow を実行

曖昧な prompt
  → 複数 RouteSignature 候補
  → NeedsChoice / Approval

未知・複雑な prompt
  → privacy-aware lightweight router LLM
  → 必要なら WorkflowRoute / heavyweight fallback
```

---

## 23. 複雑プロンプトからの Petri-net Workflow 作成と PromptRouter の整合

### 23.1 問題設定

`ClaudeEval` には、単一の SourceVault query や既存 FunctionRoute だけでは処理できない複雑 prompt が入力される。

例:

```mathematica
ClaudeEval["今週レビューすべき notebook を抽出し、未完了 Todo を読み、優先度順に並べ、必要なら GitHub issue 化する準備までして"]
```

この種の処理は、毎回 heavyweight LLM に丸投げするのではなく、可能なら `WorkflowRoute` として Petri-net workflow template に昇格し、SourceVault に保存して再利用する。ただし、現時点の `petri_from_prompt.wl` は実験用ファイルであり、正式な `ClaudeOrchestrator` API としてそのまま取り込んではならない。

本節の目的は、PromptRouter 導入と、`ClaudeEval` から直接 Petri-net workflow draft を作成・承認・実行する経路を矛盾なく統合することである。

### 23.2 現状ファイルの位置付け

`petri_from_prompt.wl` v0.10.0 は、自然言語 goal から WorkflowNet code を生成し、parse し、実行・診断するための実験用サンプル兼ライブラリである。正式統合時は、**丸ごと package 本体へ移植しない**。

現状の機能分類は次の通り。

| 分類 | `petri_from_prompt.wl` 側の代表要素 | 正式統合方針 |
|---|---|---|
| Prompt guide / skill 読み込み | `$petriNetGuide`, `iReadSkillBody`, `AddProviderSupportToPetriPrompt`, `AddANDMergeGuideToPetriPrompt`, `AddRetryGuideToPetriPrompt` | 既存 `petri-*` ClaudeDirective skill 群へ追記。runtime data にはしない |
| Proposal | `proposePetriNet`, `proposePetriNetWithProvider`, `reviewPetriProposal`, `iProposeOnce`, `iProposeMulti`, `iBuildFeedback`, `iIsProposalBad` | `ClaudeOrchestrator_promptworkflow.wl` の `ClaudeProposeWorkflowNetFromPrompt` へ再設計して移す |
| Static textual checks | `iExtractCodeBlock`, `iFindBuilderName`, `iCheckForbiddenAPIs`, `iCheckSharedInputPlaces`, `iCheckDuplicatedTransitions`, `iCheckRetryGuards`, `iCheckPayloadAccess`, `iCheckWorkerHandlerIssues` | textual check は補助診断として残す。ただし safety の根拠にはしない。rule 00 と統合した validator へ移す |
| Parse / evaluation | `parsePetriCode`, `iEvalLastWorkflowNetExpr` | **そのまま移植禁止**。`ToExpression` 全体評価を廃止し、sandbox parser と whitelist evaluator として再設計 |
| One-shot run | `runPetriFromPrompt`, `safeRunPetriFromPrompt`, `summarizePromptPetri` | compatibility wrapper または docs example に限定。`ClaudeEval` 経路では直接使わない |
| Workflow result helpers | `getWorkflowResults`, `getFinalTokens`, `getWorkflowReport`, `inspectAllTokens`, `diagnoseFailure` など | 必要最小限のみ `ClaudeOrchestrator_workflow.wl` または docs helper へ。PromptRouter core には入れない |
| Observability 既存重複 | `plotPetriNet`, `plotExecutionTrace`, `traceList` など | workflow/observability 側の既存 API と差分確認。重複は削除または wrapper 化 |
| Dynamic validation / diagnostics | `validateWorkflowOutput`, `extractReviewsFromWorkflow`, `showHandlerTrace`, `diagnoseHandlerOutputs`, `checkLLMResponse`, `iIsLLMErrorResponse` | observability / validation に不足する分だけ追加候補 |

重要な修正点: `withLLMLogging`, `showLLMCallLog`, `instrumentNetForObservation`, `plotPetriNetDetail`, `checkPetriNetVertices`, `traceTransitions` は既に `ClaudeOrchestrator_observability.wl` v0.2.1 側に存在する。したがって、「petri_from_prompt から observability へ移す」のではなく、**petri_from_prompt 側の重複定義・古い呼び出しを observability 版へ一本化し、不足分だけ追加する**。

### 23.3 ファイル分担とロード独立性

#### SourceVault 側

`SourceVault_promptrouter.wl` は以下のみ担当する。

- prompt matching
- RouteSignature resolution
- freshness check
- PromptRun recording
- WorkflowRoute / WorkflowRouteDraft metadata の保存
- privacy / model constraints の伝播
- ClaudeRuntime / ClaudeOrchestrator への weak dispatch

`SourceVault_promptrouter.wl` は `ClaudeOrchestrator` の workflow proposal / parser を定義しない。

#### ClaudeOrchestrator 側

新設候補:

```text
ClaudeOrchestrator_promptworkflow.wl
```

役割:

- prompt から WorkflowNet proposal を生成する
- proposal retry / feedback loop を管理する
- generated workflow code を安全に parse / validate する
- WorkflowRouteDraft 作成に必要な metadata を返す

ロード方針:

```text
ClaudeOrchestrator.wl
  → ClaudeOrchestrator_workflow.wl をロード
  → ClaudeOrchestrator_promptworkflow.wl をロード可能
  → ClaudeOrchestrator_observability.wl は optional 依存
```

`promptworkflow` は workflow engine に依存するため `ClaudeOrchestrator` ロード時に読み込んでよい。一方、observability は optional とし、未ロードでも proposal / parse / static validation は失敗してはならない。未ロードの場合は diagnostics に `"Observability" -> "Unavailable"` を記録するだけにする。

### 23.4 `petri_from_prompt.wl` の取り込み方針

#### 23.4.1 Proposal / feedback retry は Orchestrator 層へ

`iProposeOnce`, `iProposeMulti`, `iBuildFeedback`, `iIsProposalBad` 相当の機能は、`ClaudeProposeWorkflowNetFromPrompt` に内包する。

これは **proposal 段階の feedback retry** であり、workflow 実行時の retry / snapshot / restore とは別レイヤである。

```mathematica
ClaudeProposeWorkflowNetFromPrompt[
  prompt_String,
  "MaxProposalAttempts" -> 3,
  "ProviderPolicy" -> Automatic,
  "FeedbackMode" -> "StaticDiagnostics",
  opts___
]
```

戻り値例:

```mathematica
<|
  "Status" -> "Proposed" | "NeedsRepair" | "Rejected",
  "Prompt" -> promptFingerprint,
  "Attempts" -> 2,
  "AttemptTrace" -> {...},
  "Code" -> codeRefOrString,
  "BuilderName" -> "buildReviewWorkflow",
  "Diagnostics" -> <|
    "TextualChecks" -> <|...|>,
    "Rule00" -> <|...|>,
    "WorkflowStatic" -> <|...|>
  |>,
  "ModelResolution" -> <|...|>,
  "PrivacyLevel" -> inherited
|>
```

#### 23.4.2 Observability は既存版へ一本化

`ClaudeOrchestrator_observability.wl` に既に存在する API は再実装しない。

既存 API:

```mathematica
withLLMLogging
showLLMCallLog
instrumentNetForObservation
plotPetriNetDetail
checkPetriNetVertices
traceTransitions
```

正式統合時には、`petri_from_prompt.wl` 側の重複実装または類似実装を削除し、必要なら compatibility wrapper を置く。

不足候補:

```mathematica
showHandlerTrace
diagnoseHandlerOutputs
validateWorkflowOutput
extractReviewsFromWorkflow
checkLLMResponse
iIsLLMErrorResponse
```

これらは、observability / validation へ追加するか、workflow result helper として別ファイル化する。PromptRouter core には入れない。

#### 23.4.3 ClaudeDirective rules / skills

新規 skill ファイルを増やす前に、既存の `petri-*` skill 群へ追記する。

既存候補:

```text
petri-multi-provider-generation
petri-retry-patterns
petri-template-and-validation
petri-and-xor-merge
workflow-equivalence-testing
runtime-orchestrator-boundary
```

新規 skill は、既存 skill に収まらない独立主題がある場合のみ作成する。

### 23.5 Sandbox parser / validation の再設計

#### 23.5.1 現行 `parsePetriCode` は正式統合不可

現行の `parsePetriCode` / fallback `iEvalLastWorkflowNetExpr` は、少なくとも以下の理由で正式統合してはならない。

- `ToExpression[code, InputForm]` で生成コード全体を評価する
- fallback 経路でもコード全体を評価する
- builder 呼び出しも `ToExpression[builder <> "[]"]` で行う
- 防御が主に文字列マッチに依存している

このため Phase W1 は「proposal/parse 部分の抽出」ではなく、**sandbox parser の再設計** と位置付ける。

#### 23.5.2 Safe parser の要求仕様

`ClaudeParseWorkflowNetCode` は、生コード全体を評価せず、次の段階で処理する。

```text
1. code block extraction
2. held syntax parse
3. rule 00 + workflow forbidden registry による静的検査
4. WorkflowNet declarative form の抽出
5. whitelist evaluator による限定的構築
6. WorkflowNet well-formedness validation
```

禁止事項:

```mathematica
ToExpression[code, InputForm]
ToExpression[builder <> "[]"]
ReleaseHold[heldRawCode]
Get / Import / URLRead / URLExecute / RunProcess / ExternalEvaluate
Put / Export / DeleteFile / RenameFile / CopyFile
SystemCredential / ClaudeAttach / notebook mutation / NBEvaluatePreviousCell bypass
```

許容される初期形式は次のどちらかに限定する。

```mathematica
buildName[] := WorkflowNet[<| ... declarative spec ... |>]
```

または、

```mathematica
WorkflowNet[<| ... declarative spec ... |>]
```

ただし、`Handler -> Function[...]` のような任意 Wolfram code を含む workflow は初期実装では原則拒否する。正式な再利用 workflow は、handler 本体を LLM 生成コードとして評価するのではなく、次のいずれかにする。

```mathematica
"HandlerRef" -> "SourceVaultReviewQueue"
"HandlerRef" -> "BuiltInMergeResults"
"HandlerTemplate" -> <|"TemplateId" -> "map-review-items-v1", ...|>
```

`HandlerRef` の許可判定は §7.3 の `SourceVaultCallableAllowlistView[]` を使う。Workflow 専用 allowlist を SourceVault 側へ複製してはならない。SourceVault-owned callable は SourceVault 側 allowlist、ClaudeOrchestrator builtin handler は Orchestrator-owned allowlist に登録し、実行時の論理ビューで合成する。`UseAsHandlerRef -> True` かつ side effect / privacy policy を満たす callable だけを handler として利用できる。

初期実装で **生成・parse・実行可能** とする workflow の範囲は、以下に限定する。

```text
- SourceVault 既存関数、ClaudeOrchestrator builtin handler、または allowlist 登録済み HandlerRef の合成で表現できる workflow
- HandlerTemplate が既存 template と parameter だけで展開できる workflow
- Transition の logic が declarative spec と canonical parameters で表現できる workflow
```

現在の `petri_from_prompt.wl` の LLM guide や `example.md` の π 近似例のように、`Handler -> Function[binding, Module[{...}, ...]]` で任意 handler 本体を書く workflow は、初期の `ClaudeEval` 自動 workflow 生成経路では受け付けない。これらは compatibility / developer example としては残せるが、再利用 workflow として登録するには HandlerRef / HandlerTemplate へ書き換える必要がある。

この線引きにより、レビュー計画のような複雑 prompt でも、初期実装では `SourceVaultReviewQueue`、`SourceVaultFindNotebooks`、builtin merge/sort/report handler の合成で表現できる範囲だけを workflow 化する。独自 Wolfram logic が必要な workflow は future phase または developer-unsafe 扱いにする。

任意 handler code を評価する互換モードをどうしても残す場合は、以下をすべて満たす developer-only mode とする。

```mathematica
"EvaluateGeneratedHandlers" -> "DeveloperUnsafe"
"RequiresApproval" -> True
"CloudFallback" -> "Deny"
"PrivacyLevel" >= 0.75
```

通常の `ClaudeEval` 経路ではこの mode を使わない。

#### 23.5.3 rule 00 との統合

workflow 生成コードの評価・parse は rule 00 の管轄に入る。

したがって、workflow 専用 forbidden list と rule 00 の `$iAutoEvalProhibitedPatterns` は別管理にしない。単一の merged registry を定義する。

```mathematica
ClaudeWorkflowForbiddenPatternRegistry[]
```

この registry は少なくとも以下を含む。

- rule 00 の AutoEvaluate 禁止パターン
- `ClaudeAttach`
- `SystemCredential`
- 保護定数・保護 global への代入
- notebook mutation
- file / network / process / external evaluation
- cloud send boundary を迂回する LLM call

`ClaudeParseWorkflowNetCode` は `NBEvaluatePreviousCell` のガードをバイパスする経路であってはならない。セル由来 code を扱う場合は、NBAccess の authorization と rule 00 checker を必ず経由する。

#### 23.5.4 Sandbox 実装方式の推奨

第一候補は「構文抽出 + whitelist evaluator」である。

```text
MakeExpression[code, StandardForm] under HoldComplete
  ↓
allowed AST pattern のみ抽出
  ↓
WorkflowNet declarative spec を Association として構築
  ↓
allowed heads / allowed keys / allowed HandlerRef のみ評価
```

builder 定義形式 `buildName[] := WorkflowNet[spec]` は、`buildName[]` を呼び出して評価してはならない。`SetDelayed[buildName[], WorkflowNet[spec]]` の AST から右辺の `WorkflowNet[spec]`、さらに `spec` を直接抽出する。直接形式 `WorkflowNet[spec]` も同じ extractor に通す。builder 名は provenance / draft metadata として保存してよいが、parser の安全性は builder 呼び出し評価に依存させない。

Declarative spec 内の値は、初期実装では次だけを許可する。

```text
- Integer / Real / True / False / Null などの JSON 化可能な literal
- String literal
- 許可済み enum string
- allowlist 登録済み HandlerRef / HandlerTemplate id
- List
- Association
- 必要最小限の whitelisted symbol reference: Infinity, Automatic, Missing[...] など、事前に明示したもの
```

以下は拒否する。

```mathematica
"Capacity" -> 1 + 1
"Name" -> "x" <> "y"
"HandlerRef" -> ToString[expr]
"Places" -> Join[a, b]
AnyHead[...]
```

つまり、算術式、文字列結合、任意関数適用、symbol の runtime lookup は whitelist evaluator では評価しない。必要な値は proposal 側で literal / enum / canonical parameter として出力させる。

専用 context + `Block` による危険 symbol の `$Failed` 退避は補助策として使ってよいが、それだけを安全性の根拠にしてはならない。

### 23.6 Complex prompt 判定

既存 PromptRoute / WorkflowRoute が見つからない場合でも、すぐに workflow 生成へ進まない。

workflow draft 生成に進む条件は次のいずれかである。

1. deterministic complex detector が成立する
   - 複数の動詞・副タスクがある
   - 抽出・要約・比較・並べ替え・承認・外部連携などが組み合わさっている
   - 「まず/次に/最後に」「A して B して C」「必要なら」などの制御語がある
2. privacy-aware lightweight router LLM が `"RouteKind" -> "WorkflowCandidate"` を返す
3. ユーザーが明示的に「ワークフロー化して」「手順として保存して」「Petri net にして」と指示する

判定が曖昧な場合は workflow を自動生成せず、`NeedsChoice` または `NeedsApproval` にする。

```mathematica
<|
  "Decision" -> "NeedsChoice",
  "Reason" -> "PotentialWorkflowButAmbiguous",
  "Choices" -> {
    <|"Kind" -> "HeavyLLMFallback"|>,
    <|"Kind" -> "CreateWorkflowDraft"|>,
    <|"Kind" -> "AskClarifyingQuestion"|>
  }
|>
```

### 23.7 ClaudeEval からの処理フロー

```text
ClaudeEval[prompt]
  ↓
SourceVaultPromptRouter
  ↓
1. exact PromptRoute match
2. deterministic FunctionRoute extraction
3. lexical / capability index search
4. existing WorkflowRoute match
5. deterministic complex prompt detector
6. privacy-aware router LLM if still needed and allowed
7. ClaudeProposeWorkflowNetFromPrompt
8. ClaudeParseWorkflowNetCode
9. static validation
10. WorkflowRouteDraft save
11. ClaudeRuntime NeedsApproval / Choice
12. approval 後に register / optional execute
```

deterministic complex detector は router LLM より前に置く。これは、秘密 prompt を LLM に渡す前に workflow 候補性をローカル判定し、LLM 呼び出しの cost と privacy risk を下げるためである。deterministic detector だけで一意の FunctionRoute / WorkflowRoute を選ぶのではなく、「単一関数では不足しそうか」「workflow draft 作成候補に進むべきか」を判断する。

既存 FunctionRoute / WorkflowRoute が一意に見つかる場合は、新規 workflow を生成しない。

`ClaudeEval` が「作成して実行して」と要求していても、新規生成 workflow の場合は、既定では draft 作成後に `NeedsApproval` で止める。承認後に登録・実行する。

例外的に自動実行を許す場合は、以下の条件をすべて満たす必要がある。

```mathematica
"AutoRunWorkflowDraft" -> True
"WorkflowRisk" -> "ReadOnlyLocalDeterministic"
"GeneratedCodeMode" -> "DeclarativeOnly"
"RequiresApproval" -> False  (* policy が明示的に許す場合のみ *)
```

初期実装ではこの例外を実装しなくてよい。

### 23.8 WorkflowRouteDraft / WorkflowRoute / code artifact

#### WorkflowRouteDraft

```mathematica
<|
  "Type" -> "WorkflowRouteDraft",
  "DraftId" -> "wfdraft-...",
  "Status" -> "Proposed" | "Parsed" | "StaticValidated" |
              "DraftSaved" | "NeedsApproval" | "Approved" |
              "Registered" | "Rejected" | "NeedsRepair",
  "PromptFingerprint" -> "sha256:...",
  "RouteSignature" -> <|...|>,
  "WorkflowTemplateId" -> "wf-template-...",
  "WorkflowVersion" -> 1,
  "CodeHash" -> "sha256:...",
  "CodeStorage" -> <|
    "Kind" -> "PrivateArtifactRef",
    "ArtifactPath" -> "promptrouter/artifacts/wf-code/sha256-....wl"
  |>,
  "ParsedNetSummary" -> <|
    "PlaceCount" -> 7,
    "TransitionCount" -> 6,
    "HandlerMode" -> "DeclarativeOnly"
  |>,
  "Validation" -> <|...|>,
  "ProposalTrace" -> <|...|>,
  "PrivacyLevel" -> 0.75,
  "AllowedModelClasses" -> {"Local", "Private"},
  "RequiresApproval" -> True
|>
```

#### WorkflowRoute

承認後のみ compiled registry に入る。

```mathematica
<|
  "Type" -> "WorkflowRoute",
  "RouteId" -> "workflow-route-...",
  "RouteVersion" -> 1,
  "WorkflowTemplateId" -> "wf-template-...",
  "CodeHash" -> "sha256:...",
  "CodeStorage" -> <|"Kind" -> "PrivateArtifactRef", ...|>,
  "Matcher" -> <|...|>,
  "ParameterSchema" -> <|...|>,
  "PrivacyLevel" -> inherited,
  "ExecutionPolicy" -> <|
    "RequiresApproval" -> True,
    "CloudFallback" -> "Deny" | "AllowByPolicy"
  |>
|>
```

#### Code artifact store

registry には code 本体を保存しない。保存するのは `CodeHash` と `CodeStorage` の参照のみである。

物理保存先:

```text
<PrivateVault>/promptrouter/artifacts/wf-code/sha256-<hash>.wl
<PrivateVault>/promptrouter/artifacts/wf-code/sha256-<hash>.metadata.json
```

公開可能な workflow であっても、初期実装では private artifact store を既定にする。public 化は明示承認後に別 route version として扱う。

### 23.9 PromptRouter と workflow generation の競合回避規則

1. 既存 FunctionRoute が一意に match したら FunctionRoute を使う。
2. 既存 WorkflowRoute が一意に match したら WorkflowRoute を使う。
3. FunctionRoute と WorkflowRoute が同点の場合は `NeedsChoice`。
4. 既存 route がない場合のみ complex detector を走らせる。
5. complex と判定されても、ClaudeOrchestrator が未ロードなら `NeedsOrchestrator`。
6. workflow draft 作成後は `NeedsApproval`。自動 registry 昇格しない。
7. 承認後に WorkflowRoute registry へ登録し、必要なら実行する。

### 23.10 Privacy / model routing

秘密セル由来、private/local model 実行由来、または private SourceVault source 由来の workflow draft は、`PrivacyLevel >= 0.75` として保存する。

workflow proposal 用 LLM、router LLM、repair LLM、execution transition LLM のすべてで、同じ privacy constraint を使う。

```mathematica
SourceVaultResolve[
  "Model",
  <|
    "Intent" -> "workflow-proposal" | "workflow-repair" | "workflow-transition",
    "WeightClass" -> "Light" | "Medium" | "Heavy",
    "PrivacyLevel" -> effectivePrivacy,
    "CloudFallback" -> If[effectivePrivacy >= 0.75, "Deny", "AllowByPolicy"]
  |>
]
```

private/local に対応 class の model がない場合は、同一 TrustDomain 内で heavier / available model に代替してよい。ただし cloud へ自動 fallback してはならない。

### 23.11 SourceVault への保存と再処理

WorkflowRouteDraft / WorkflowRoute は、次の依存を記録する。

```text
PromptFingerprint
RouteSignature
WorkflowTemplateId / WorkflowVersion
CodeHash / CodeStorage
SourceSnapshotIds
ModelResolution
ValidationVersion
ForbiddenRegistryVersion
ParserVersion
```

外部データ更新時の再処理では、workflow code artifact そのものを自動再生成しない。依存 source が stale になった場合は、`SourceVaultReprocessPlan` に次の候補を出す。

```text
- existing WorkflowRoute を current snapshots で再実行
- summary / extraction artifact を refresh
- workflow proposal を再生成候補にする
- approval が必要な re-generation として止める
```

### 23.12 直接実行 API と ClaudeEval の違い

`ClaudeProposeWorkflowNetFromPrompt` は直接 API として使えるが、これは proposal API であって `ClaudeEval` の自動 workflow 実行と同義ではない。

```mathematica
proposal = ClaudeProposeWorkflowNetFromPrompt[goal]
parsed = ClaudeParseWorkflowNetCode[proposal["Code"]]
draft = ClaudeCreateWorkflowRouteDraft[goal, proposal]
```

`ClaudeEval` 経由では、PromptRouter が既存 route 検索・privacy gate・approval gate を前段に置く。

### 23.13 例

#### 例 1: 既存 FunctionRoute で済む場合

```mathematica
ClaudeEval["7日間のスケジュールのうちTodoが残っているものを"]
```

これは `SourceVaultUpcomingSchedule` に解決できるため、新規 workflow を生成しない。

#### 例 2: 既存 WorkflowRoute がある場合

```mathematica
ClaudeEval["今週レビューすべきノートブックを優先度順にまとめて"]
```

既存 `WorkflowRoute` があれば、それを freshness check 後に実行する。

#### 例 3: 既存 route がなく workflow draft が必要な場合

```mathematica
ClaudeEval["今週レビューすべき notebook を抽出し、未完了 Todo を読み、重要度順に並べ、レビュー計画を作って"]
```

処理:

```text
No exact route
No deterministic FunctionRoute
No existing WorkflowRoute
complex detector -> WorkflowCandidate
ClaudeProposeWorkflowNetFromPrompt
ClaudeParseWorkflowNetCode
Static validation
WorkflowRouteDraft saved
NeedsApproval
```

#### 例 4: ClaudeOrchestrator 未ロードの場合

```mathematica
<|
  "Decision" -> "NeedsOrchestrator",
  "Reason" -> "Workflow generation requires ClaudeOrchestrator_promptworkflow.wl",
  "Fallback" -> "HeavyLLMAnswerOnly" | "AskToLoadOrchestrator"
|>
```

SourceVault の基本 query API は Orchestrator なしで動作するが、workflow draft 生成の恩恵は Orchestrator ロード時のみ利用できる。

### 23.14 API 統合

§16 の Public API は、本節の workflow proposal / draft API を含む単一リストとして扱う。

追加 API:

```mathematica
ClaudeProposeWorkflowNetFromPrompt
ClaudeParseWorkflowNetCode
ClaudeValidateWorkflowNetProposal
ClaudeCreateWorkflowRouteDraft
SourceVaultPromptRouteSaveDraft
ClaudeRunWorkflowRoute
```

`proposePetriNet`, `reviewPetriProposal`, `parsePetriCode` は正式 API ではなく、compatibility wrapper として扱う。

### 23.15 Acceptance tests

Workflow generation tests は ClaudeTestKit を前提に決定的にする。

#### Test W1: 既存 FunctionRoute 優先

固定 prompt が FunctionRoute に解決される場合、`WorkflowProposed` event が発生しないことを `AssertEventSequence` / event absence で検証する。

#### Test W2: 既存 WorkflowRoute 優先

既存 WorkflowRoute がある場合、新規 draft を作らず既存 route を実行候補にする。

#### Test W3: 複雑 prompt から draft 作成

`CreateMockProvider` で固定 builder code を返す。検証対象は以下に限定する。

```text
complex detected
WorkflowProposed
WorkflowParsed
StaticValidated
DraftSaved
NeedsApproval
```

LLM 生成内容の品質は検証しない。

#### Test W4: Orchestrator 未ロード

PromptRouter は `NeedsOrchestrator` を返し、`Needs["ClaudeOrchestrator`"]` を勝手に呼ばない。

#### Test W5: 秘密セル由来 workflow

`AssertNoSecretLeak` で、秘密文字列が cloud provider call、public trace、public registry に出ないことを検証する。

#### Test W6: generated code safety

forbidden call を含む mock code を返し、`AssertValidationDenied` で `Rejected` / `NeedsRepair` を検証する。

#### Test W7: sandbox parser side-effect safety

ClaudeTestKit scenario とは別ハーネスで、悪意ある code string を parser に直接渡し、file/network/process/notebook 副作用がゼロであることを検証する。

#### Test W8: workflow artifact storage

WorkflowRoute registry には `CodeHash` / `CodeStorage` だけが入り、code 本体は `<PrivateVault>/promptrouter/artifacts/wf-code/` に保存されることを検証する。

### 23.16 docs/examples/petri_from_prompt.wl の処遇

正式統合後、`docs/examples/petri_from_prompt.wl` は即時削除しない。

方針:

1. 1 compatibility cycle は wrapper として残す。
2. 冒頭に deprecated notice を出す。
3. 内部実装は新 API へ委譲する。
4. `example.md` は、`Get[...petri_from_prompt.wl]` を前提にする形から、`ClaudeOrchestrator.wl` ロード後に新 API を使う形へ更新する。
5. 旧 `proposePetriNet` / `parsePetriCode` の説明は「互換 API」として別節に移す。

### 23.17 禁止事項

- `petri_from_prompt.wl` をそのまま `SourceVault_promptrouter.wl` へ移植してはならない。
- `SourceVault_promptrouter.wl` が workflow proposal / parser を直接持ってはならない。
- generated Wolfram code 全体を `ToExpression` してはならない。
- rule 00 と workflow forbidden list を別々の真実源として運用してはならない。
- observability に既にある API を petri_from_prompt 由来で重複再定義してはならない。
- 新規 workflow draft を承認なしで registry 昇格してはならない。
- 新規 workflow draft を承認なしで自動実行してはならない。
- private workflow proposal を cloud router / cloud proposal LLM に送ってはならない。
- package 本体に `Needs["ClaudeTestKit`"]` を入れてはならない。

### 23.18 結論

複雑 prompt から Petri-net workflow を生成する機構は、PromptRouter の一部として実装するのではなく、ClaudeOrchestrator 側の `promptworkflow` 層として再設計する。

PromptRouter は既存 route 検索・privacy gate・freshness check・draft 保存・approval 接続を担当し、workflow 生成・safe parse・validation は ClaudeOrchestrator が担当する。

特に `parsePetriCode` 相当部分は、現行実装の抽出ではなく sandbox parser として再設計する必要がある。ここを曖昧にしたまま `ClaudeEval` へ直結してはならない。

## 24. 実装前レビュー反映事項 — v5 で固定する設計判断

この節は、以前の draft に対する実装前レビューを反映した normative な変更点である。本文中に同じ内容がある場合、この節の方針を優先する。

### 24.1 PromptRoute / WorkflowRoute と PromptRun の保存先分離

`PromptRoute` / `WorkflowRoute` / `PromptExample` / search index は compiled registry に保存する。一方、`PromptRun` は append-only JSONL store に保存する。

理由:

- `SourceVaultCompileRegistry[topic, entries, opts]` は entries 全体を一括書き込みする API である。
- `PromptRun` は日々の実行履歴であり、claims / source-events と同じ append-only event log 性質を持つ。
- `PromptRun` を compiled registry topic に置くと、高頻度 append と低頻度 declarative registry 更新が混ざり、atomic write・差分レビュー・reset policy が歪む。

確定方針:

```text
compiled/public/prompt-route-registry.json       PromptRoute
compiled/private/prompt-route-registry.json      private PromptRoute / override
compiled/public/workflow-route-registry.json     WorkflowRoute
compiled/private/workflow-route-registry.json    private WorkflowRoute / override
compiled/*/prompt-route-index.json               派生 search index

promptrouter/runs/prompt-runs.jsonl              PromptRun append-only history
promptrouter/events/route-events.jsonl           optional route/capture event log
```

上記に **Callable allowlist** は含めない。Callable allowlist は所有者 package ごとの `.wl` 内 code-resident constant table であり、compiled registry(JSON) や append-only JSONL store には保存しない。SourceVault-owned callable は `SourceVaultCallableAllowlistRegistry[]`、ClaudeOrchestrator-owned handler は `ClaudeWorkflowHandlerAllowlist[]` のように各 package が自分の callable だけを公開し、PromptRouter は `SourceVaultCallableAllowlistView[]` で論理的に合成する。compiled registry 側に保存するのは、`FunctionId` / `HandlerRef` など JSON 化可能な識別子だけである。

`prompt-run-history` を compiled registry topic として作らない。

### 24.2 データストア書き込み安全規約の適用

以下は store 書き込み API であり、rule 103 に従う。

- `SourceVaultRegisterPromptRoute`
- `SourceVaultPromotePromptRun`
- `SourceVaultReprocess`
- PromptRoute / WorkflowRoute / PromptExample / search index を書き換える内部 API

必須事項:

- registry 変更 API は `"DryRun" -> True` 既定。
- 実変更には `"DryRun" -> False` と必要に応じて `"Confirm" -> True`。
- atomic write: `path.tmp` → JSON 検証 → `RenameFile`。
- JSON/JSONL 書き込み前に `iSanitizeForJSON`。
- JSON/JSONL 読み込みは `ReadByteArray` + `ByteArrayToString`。
- `Return[expr, Module]` のスコープ罠を避ける。
- 物理削除より `LifecycleStatus` mark を優先。
- `SourceVaultResetStore` の通常削除対象に PromptRun history を含めない。

### 24.3 既存 natural dispatch との移行

PromptRouter active 時は、旧 `iClaudeEvalNaturalMatch` を先に実行しない。

```text
PromptRouter active
  → SourceVaultExecutePromptRoute を先に試す
  → NotDispatched の場合のみ legacy natural dispatch

PromptRouter unavailable
  → 従来 $ClaudeEvalNaturalDispatch に従う
```

旧 natural dispatch の schedule / refresh_summary ルールは seed PromptRoute に移し、claudecode 側の判定表は移行期間の fallback とする。二重 dispatch を恒久化しない。

### 24.4 parameter canonical form

保存形式は以下に統一する。

```mathematica
<|
  "PeriodDays" -> 7,
  "OpenTodos" -> True,
  "DateField" -> "Both",
  "ScopeRef" -> <|"Kind" -> "RootSymbol", "Name" -> "$onWork"|>
|>
```

`"Period" -> Quantity[...]` は関数呼び出し直前にだけ作る。registry / PromptRun / RouteSignature / search index に `Quantity` を保存しない。

### 24.5 model resolver contract

Phase E 着手前に、既存 `SourceVaultResolve` / `ClaudeResolveModel` が以下を扱えるか検証する。

```mathematica
<|
  "Intent" -> "router" | "summary" | "workflow" | ...,
  "WeightClass" -> "Light" | "Medium" | "Heavy",
  "PrivacyLevel" -> privacy,
  "AllowedTrustDomains" -> {"Local", "Private"},
  "CloudFallback" -> "Deny" | "Ask" | "Allow",
  "RequiredCapabilities" -> {...},
  "DegradationPolicy" -> "Flexible" | "AskOnDowngrade" | "Strict"
|>
```

不足する場合は PromptRouter 内に別 resolver を作らず、SourceVault model resolver を後方互換で拡張するか薄い wrapper を SourceVault 側に追加する。

### 24.6 privacy threshold と既存値

`>= 0.5` は cloud 送信禁止境界の比較式である。保存値として新しい `0.5` を導入する必要はない。既存体系が `0.0 / 0.75 / 1.0` を使う場合、秘密セル・private/local model 実行由来の route / run / workflow は `0.75` 以上へ昇格する。

### 24.7 PathRef は権限ではない

`$onWork` / `ScopeRef` / `PathRef` は同一性の参照であり、read / write / cloud-send 権限ではない。PromptRouter は scope を解決した後も、notebook query、file read、cell read、LLM 送信の各段階で NBAccess authorization を通す。

### 24.8 UpcomingSchedule option 追加方法

`SourceVaultUpcomingSchedule` の `OpenTodos`, `DateField`, `OutputFormat` は後方互換の option 追加である。ただし実装時は既存 `Options[SourceVaultUpcomingSchedule]` 定義リストへ直接追加し、`Join[Options[f], ...]` で二重追加しない。


### 24.9 Petri-net 統合レビュー反映事項

v6 では、§23 を実ファイルの現状に合わせて再設計した。

- observability に既に存在する API は「移す」のではなく一本化する。
- `petri_from_prompt.wl` に無い `withLLMLogging` / `showLLMCallLog` 等を取り込み表から除外し、既存 observability API として扱う。
- `parsePetriCode` の `ToExpression` 全体評価方式は正式統合不可とし、sandbox parser の再設計を Phase 7 に置く。
- rule 00 と workflow forbidden list は単一 registry に統合する。
- workflow generated code 本体は compiled registry に置かず、private artifact store に保存する。
- promptworkflow と observability のロード独立性を明確化する。
- complex prompt 判定基準を deterministic detector / lightweight router LLM / 明示指示に分ける。
- proposal 段階の feedback retry と workflow 実行時 retry を分離する。
- 新規 skill 乱立ではなく既存 `petri-*` skill 群への追記を既定にする。
- §16 / §17 / §18 と §23 の API・テスト・フェーズを統合した。
- `docs/examples/petri_from_prompt.wl` は compatibility wrapper とし、`example.md` は新 API 前提に更新する。


---

## 25. v10 実装時訂正: 現行 SourceVault callable との整合

### 25.1 原則

PromptRouter の callable allowlist は、実装時点で `SourceVault.wl` に実在する public callable のみを含める。存在しない symbol を allowlist に入れて dispatcher の候補にしてはならない。

この原則は、古い例に残る `SourceVaultReviewQueue` / `SourceVaultOpenTodoList` への直接 route 記述より優先する。

### 25.2 現行 callable mapping

現行 `SourceVault.wl` で Order 3 の初期 FunctionRoute に使ってよい callable は次である。

| FunctionId | 実 symbol | 初期用途 | 主な adapter 変換 |
|---|---|---|---|
| `SourceVaultUpcomingSchedule` | `SourceVaultUpcomingSchedule` | 期間内の Deadline / NextReview を schedule として表示 | `PeriodDays -> "Period" -> Quantity[n,"Days"]`; scope / refresh / cache option を渡す |
| `SourceVaultFindNotebooks` | `SourceVaultFindNotebooks` | notebook 条件検索、review queue、open todo list の初期代替 | `OpenTodos -> "OpenTodos"`; `DateField -> "NextReview"` は `"NextReview" -> "DueSoon"/"ThisWeek"/"Overdue"` へ変換 |

初期実装で使ってはならない callable は次である。

| 名前 | 扱い |
|---|---|
| `SourceVaultReviewQueue` | 未実装。`FunctionId` にしない。`ReviewQueue` semantic intent として扱い、`SourceVaultFindNotebooks` adapter へ落とす。 |
| `SourceVaultOpenTodoList` | 未実装。`FunctionId` にしない。`OpenTodoList` semantic intent として扱い、`SourceVaultFindNotebooks["OpenTodos" -> True]` へ落とす。 |

### 25.3 ReviewQueue intent の canonical route

PromptRouter 内部では、レビュー系 prompt を callable 名ではなく intent として記録する。

```mathematica
<|
  "IntentId" -> "ReviewQueue",
  "CanonicalParameters" -> <|
    "PeriodDays" -> 3,
    "DateField" -> "NextReview",
    "OpenTodos" -> Missing[],
    "IncludeOverdue" -> True,
    "ScopeRef" -> <|"Kind" -> "RootSymbol", "Name" -> "$onWork"|>
  |>,
  "InitialAdapter" -> <|
    "FunctionId" -> "SourceVaultFindNotebooks",
    "Options" -> <|
      "NextReview" -> "DueSoon",
      "OpenTodos" -> Missing[]
    |>
  |>
|>
```

`PeriodDays` と `IncludeOverdue` を `SourceVaultFindNotebooks` の `"NextReview"` option へどう落とすかは adapter policy として定義する。現行 implementation が `"DueSoon"` / `"ThisWeek"` / `"Overdue"` だけを受ける場合、厳密な 3 日範囲は `NeedsImplementation` または `ApproximateRoute` として PromptRun に記録する。曖昧な近似を silently 実行してはならない。

### 25.4 OpenTodoList intent の canonical route

```mathematica
<|
  "IntentId" -> "OpenTodoList",
  "CanonicalParameters" -> <|
    "OpenTodos" -> True,
    "ScopeRef" -> Automatic
  |>,
  "InitialAdapter" -> <|
    "FunctionId" -> "SourceVaultFindNotebooks",
    "Options" -> <|"OpenTodos" -> True|>
  |>
|>
```

### 25.5 将来 wrapper を追加する場合

将来 `SourceVaultReviewQueue` / `SourceVaultOpenTodoList` を追加する場合は、次の順に実施する。

1. `SourceVault.wl` に wrapper 本体と `Options[...]` を実装する。
2. 単体テストで実在 callable として確認する。
3. `SourceVaultCallableAllowlistRegistry[]` に `FunctionId -> Symbol` を追加する。
4. `ReviewQueue` / `OpenTodoList` intent の adapter target を新 wrapper へ切り替える。
5. 既存 PromptRun / PromptRoute の canonical intent は変更しない。

`UseAsFunctionRoute -> False` の placeholder を allowlist に置く方式は採用しない。存在しない symbol を registry に入れると dispatch failure と診断の混乱を招くためである。

### 25.6 Order 3 の受け入れ条件

Order 3 の `SourceVaultCallableAllowlistRegistry[]` は、少なくとも以下を検査する。

```mathematica
KeyExistsQ[SourceVaultCallableAllowlistRegistry[], "SourceVaultUpcomingSchedule"]
KeyExistsQ[SourceVaultCallableAllowlistRegistry[], "SourceVaultFindNotebooks"]
!KeyExistsQ[SourceVaultCallableAllowlistRegistry[], "SourceVaultReviewQueue"]
!KeyExistsQ[SourceVaultCallableAllowlistRegistry[], "SourceVaultOpenTodoList"]
```

さらに、各 entry の `"Symbol"` が実在し、`Options[symbol]` が adapter contract と整合することを audit test で確認する。
