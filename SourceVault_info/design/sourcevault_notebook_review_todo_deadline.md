# SourceVault Notebook Review / Todo / Deadline 連携レビュー

作成日: 2026-05-19  
対象: SourceVault / NBAccess / ClaudeRuntime / ClaudeOrchestrator に、Mathematica notebook の `Deadline`・`NextReview`・Todo 状態を取り込む拡張

---

## 0. 要約

現在の notebook 運用は、SourceVault にとって非常に扱いやすい構造をすでに持っている。

- 先頭付近の `Input` セルに、`<|"Keywords" -> ..., "NextReview" -> DateObject[...], "Deadline" -> DateObject[...], "Status" -> ...|>` 形式のヘッダがある。
- Todo は `TodoItem_1` などの専用スタイルで書かれている。
- Todo の完了状態は、見た目上は radio button / strike-through / 色などで表現されている。
- 本文は `Text` など通常の notebook cell で構成されている。

したがって SourceVault 側では、notebook を単なる raw file として ingest するだけでなく、次の **Notebook management record** を抽出・保存するべきである。

```mathematica
<|
  "NotebookRef" -> ...,
  "Header" -> <|"Keywords" -> ..., "Deadline" -> ..., "NextReview" -> ..., "Status" -> ...|>,
  "Todos" -> {...},
  "ReviewState" -> ...,
  "SummaryArtifact" -> ...,
  "PrivacyProfile" -> ...
|>
```

これにより、

- 「まだ Done になっていない Todo」
- 「今週中にレビューすべき notebook」
- 「Deadline が過ぎている notebook」
- 「更新されたので summary を再生成すべき notebook」
- 「特定 keyword / project に属する notebook 群」

を SourceVault query として扱えるようになる。

---

## 1. 添付 notebook から読み取れる現在形式

添付 notebook `20260516-第14回オンライン語り交流会.nb` は、構造上おおむね次のようになっている。

### 1.1 ヘッダセル

先頭の `Input` / `InitializationCell` に、次のような Association が入っている。

```mathematica
<|
  "Keywords" -> {"みんなのケア情報学会", "オンライン語り交流会"},
  "NextReview" -> DateObject[{2026, 5, 13}],
  "Deadline" -> DateObject[{2026, 5, 13}],
  "Status" -> "Todo"
|>
```

この形式は SourceVault に取り込む metadata として非常に適している。

ただし、このセルをそのまま評価して metadata を取り出すのではなく、**literal association として安全に parse** するべきである。

### 1.2 Todo セル

同 notebook には、次の Todo セルがある。

```text
参加登録
```

セルスタイルは `TodoItem_1` で、セルオプションに

```mathematica
FontVariations -> {"StrikeThrough" -> True}
```

が付いている。したがって、現在の見た目ベースの判定では、この Todo は **Done** とみなせる。

一方で、ヘッダの `"Status" -> "Todo"` はまだ Todo のままである。したがって、この notebook には次の lint が出るべきである。

```text
HeaderStatusTodoButAllTodosDone
DeadlinePastButTodoDoneOrStatusTodo
NextReviewPast
```

### 1.3 日付状態

現在日を 2026-05-19 とすると、

```mathematica
"Deadline"   -> 2026-05-13
"NextReview" -> 2026-05-13
```

はいずれも過去である。

ただし Todo セルは完了扱いなので、ダッシュボード表示では次のように分けるのがよい。

```text
Review overdue: yes
Deadline overdue: yes
Open todos: no
Header/status inconsistency: yes
```

ここが重要で、単に `Status -> "Todo"` だけを見ると「未完了 notebook」と誤判定する。Todo セル状態、ヘッダ Status、Deadline / NextReview を独立に保存し、後で合成判定するべきである。

---

## 2. 追加すべきユースケース

### UC-NB-1: 未完了 Todo の一覧

ユーザー指示例:

```text
まだ done になっていない Todo 項目を一覧してほしい。
```

SourceVault query:

```mathematica
SourceVaultFindNotebooks[
  "TodoStatus" -> "Open",
  "Scope" -> "CurrentProject" | "All"
]
```

期待される動作:

1. notebook index から Todo record を検索する。
2. `TodoStatus -> "Open"` のものだけ返す。
3. 結果には notebook path / title / header keywords / deadline / next review / cell ref を含める。
4. cloud LLM に渡す場合は、Todo 本文が privacy policy を通過したものだけ渡す。

---

### UC-NB-2: 今週中にレビューすべき notebook

ユーザー指示例:

```text
今週中にレビューしないといけないノートブックを出して。
```

SourceVault query:

```mathematica
SourceVaultFindNotebooks[
  "NextReview" -> DateRange[{Today, Today + Quantity[7, "Days"]}],
  "Status" -> Except["Archived"]
]
```

期待される動作:

- `NextReview` が今週中、またはすでに過ぎている notebook を検索する。
- `ReviewReason` として `"DueThisWeek"` / `"Overdue"` を付ける。
- 結果を review dashboard として返す。

---

### UC-NB-3: Deadline が近い / 過ぎている notebook

ユーザー指示例:

```text
締切が過ぎている notebook と、今週締切の notebook を整理して。
```

SourceVault query:

```mathematica
SourceVaultFindNotebooks[
  "Deadline" -> <|"From" -> Today - Quantity[30, "Days"],
                  "To" -> Today + Quantity[7, "Days"]|>,
  "Status" -> Except["Done" | "Archived"]
]
```

注意点:

- `Deadline` は作業締切であり、`NextReview` は見直し予定日である。
- 両者は別 index にする。
- Todo がすべて Done でも header Status が Todo のままなら lint として出す。

---

### UC-NB-4: フォルダ内 notebook の自動概要作成

ユーザー指示例:

```text
このフォルダの各 notebook の概要を作成して。
```

動作:

1. フォルダ内の `.nb` を列挙。
2. 各 notebook を `SourceVaultRegisterNotebook` で登録。
3. ヘッダ、Todo、本文 cell、privacy profile を抽出。
4. privacy level に応じて local LLM / cloud LLM / summary-only projection を選ぶ。
5. `NotebookSummaryArtifact` を SourceVault に保存。
6. SourceVault index に `SummaryStatus -> "Current"` を記録する。

---

### UC-NB-5: notebook 更新時の lazy refresh

ユーザー指示例:

```text
この notebook の概要を見せて。
```

動作:

1. `NotebookRef` から current snapshot を解決。
2. 既存 summary artifact の `DerivedFromSnapshot` / `NotebookSemanticHash` と比較。
3. 変更がなければ既存 summary を返す。
4. 変更があれば、変更 cell / 変更 section だけ再要約する。
5. 新 summary artifact を作り、古い summary を stale にする。

API 案:

```mathematica
SourceVaultNotebookSummary[nbRef,
  "RefreshIfStale" -> True,
  "SummaryLevel" -> "Notebook" | "Section" | "Cell"]
```

---

### UC-NB-6: ClaudeEval からの自然言語検索

ユーザー指示例:

```text
先月作業した notebook のうち、まだ Todo が残っているものを出して。
```

ClaudeEval の処理:

1. 自然言語を SourceVault query plan に変換。
2. SourceVault index を検索。
3. 必要なら notebook summary artifact を取得。
4. raw notebook を読まないで済む場合は summary / metadata だけで回答。
5. 必要な場合のみ NBAccess を通して notebook cell を読む。

---

### UC-NB-7: ClaudeOrchestrator workflow への接続

ユーザー指示例:

```text
今週レビューすべき notebook を見て、必要なものだけ要約を更新し、未完了 Todo を一覧して。
```

Workflow 例:

```text
FindDueNotebooks
  -> RefreshStaleSummaries
  -> ExtractOpenTodos
  -> ReduceDashboard
  -> CommitReviewCell
```

SourceVault は各 transition の入力として、

```mathematica
<|
  "NotebookRefs" -> {...},
  "ContextBundleId" -> ...,
  "Policy" -> "RespectNBAccess"
|>
```

を渡す。ClaudeOrchestrator は workflow plan と実行 trace を SourceVault に保存する。

---

## 3. 必要なデータ構造

### 3.1 NotebookSourceRecord

論理 notebook を表す record。内容 hash ではなく、安定した notebook identity を持つ。

```mathematica
<|
  "Type" -> "NotebookSource",
  "NotebookRef" -> "nb-src-...",
  "LogicalSourceId" -> "notebook:path:...",
  "OriginalPath" -> ".../20260516-第14回オンライン語り交流会.nb",
  "ProjectRoot" -> ...,
  "Title" -> "20260516-第14回オンライン語り交流会",
  "FileMTime" -> DateObject[...],
  "CurrentSnapshotId" -> "snap-sha256-...",
  "TrustLevel" -> "LocalNotebook",
  "Ownership" -> "ExternalOwned" | "VaultOwned",
  "RegisteredAt" -> DateObject[...],
  "LastIndexedAt" -> DateObject[...]
|>
```

重要点:

- `NotebookRef` は path / notebook UUID / project root から安定に作る。
- `SnapshotId` は内容 hash。
- path が変わった場合は recovery candidate を出す。

---

### 3.2 NotebookSnapshotRecord

特定時点の notebook 内容。

```mathematica
<|
  "Type" -> "NotebookSnapshot",
  "SnapshotId" -> "snap-sha256-...",
  "NotebookRef" -> "nb-src-...",
  "RawContentHash" -> "sha256-...",
  "NotebookSemanticHash" -> "sha256-sem-...",
  "HeaderHash" -> "sha256-header-...",
  "TodoHash" -> "sha256-todo-...",
  "CellHashes" -> <|"cell-..." -> "sha256-..."|>,
  "CellCount" -> 123,
  "LifecycleStatus" -> "Current" | "Stale" | "Invalidated",
  "CreatedAt" -> DateObject[...]
|>
```

`NotebookSemanticHash` は、表示・ウィンドウ位置・一部の cache 情報を除外した hash にする。

---

### 3.3 NotebookHeaderRecord

先頭 metadata cell から抽出する record。

```mathematica
<|
  "Type" -> "NotebookHeader",
  "NotebookRef" -> "nb-src-...",
  "SnapshotId" -> "snap-sha256-...",
  "Keywords" -> {"みんなのケア情報学会", "オンライン語り交流会"},
  "Deadline" -> DateObject[{2026, 5, 13}],
  "NextReview" -> DateObject[{2026, 5, 13}],
  "Status" -> "Todo",
  "Owner" -> Missing["NotSpecified"],
  "Project" -> Missing["NotSpecified"],
  "HeaderCellRef" -> "nb-src-.../cell/...",
  "ParseStatus" -> "OK" | "UnsafeExpression" | "MissingHeader"
|>
```

追加推奨キー:

```mathematica
"ReviewCadence" -> Quantity[7, "Days"] | Missing["NotSpecified"]
"Priority" -> "High" | "Normal" | "Low"
"ContextType" -> "Mail" | "Research" | "Grant" | "Meeting" | "CodeReview"
```

---

### 3.4 NotebookTodoRecord

Todo cell ごとの record。

```mathematica
<|
  "Type" -> "NotebookTodo",
  "TodoId" -> "todo-...",
  "NotebookRef" -> "nb-src-...",
  "SnapshotId" -> "snap-sha256-...",
  "CellRef" -> "nb-src-.../cell/...",
  "CellStyle" -> "TodoItem_1",
  "Text" -> "参加登録",
  "Status" -> "Done" | "Open" | "Pass" | "Unknown",
  "StatusSource" -> "TaggingRules" | "CellOption" | "StyleHeuristic",
  "StrikeThrough" -> True,
  "DueDate" -> Missing["Inherited"],
  "NextReview" -> Missing["Inherited"],
  "Depth" -> 1,
  "ParentTodoId" -> Missing["None"],
  "AccessLabel" -> <|...|>,
  "ExtractedAt" -> DateObject[...]
|>
```

Todo の status は、最初は以下の優先順位で判定するのがよい。

```text
1. Cell option / TaggingRules に明示された TodoStatus
2. Checkbox / RadioButtonBox / TemplateBox など UI 状態
3. FontVariations -> {"StrikeThrough" -> True}
4. FontColor / Background など style heuristic
5. Header Status からの推測
```

長期的には 1 を標準にするべきである。表示だけに依存すると style notebook の変更で壊れる。

---

### 3.5 NotebookReviewRecord

`Deadline` / `NextReview` / Todo 状態を合成した review 用 record。

```mathematica
<|
  "Type" -> "NotebookReview",
  "NotebookRef" -> "nb-src-...",
  "SnapshotId" -> "snap-sha256-...",
  "Deadline" -> DateObject[...],
  "NextReview" -> DateObject[...],
  "HeaderStatus" -> "Todo",
  "OpenTodoCount" -> 0,
  "DoneTodoCount" -> 1,
  "PassTodoCount" -> 0,
  "ReviewState" -> "Overdue" | "DueThisWeek" | "Current" | "NoReviewDate",
  "DeadlineState" -> "Overdue" | "DueSoon" | "Future" | "NoDeadline",
  "Lint" -> {
    "HeaderStatusTodoButAllTodosDone",
    "NextReviewPast"
  },
  "ComputedAt" -> DateObject[...]
|>
```

この record を index に載せることで、自然言語検索を LLM に頼らず deterministic に処理できる。

---

### 3.6 NotebookSummaryArtifact

LLM で作った概要。

```mathematica
<|
  "ArtifactType" -> "NotebookSummary",
  "ArtifactId" -> "artifact-summary-...",
  "NotebookRef" -> "nb-src-...",
  "DerivedFromSnapshot" -> "snap-sha256-...",
  "DerivedFromCellHashes" -> <|...|>,
  "SummaryLevel" -> "Notebook" | "Section" | "Cell",
  "SummaryText" -> "...",
  "Header" -> <|...|>,
  "TodoSummary" -> <|
    "OpenTodos" -> {...},
    "DoneTodos" -> {...},
    "Lint" -> {...}
  |>,
  "GeneratedBy" -> <|
    "Tool" -> "ClaudeEval" | "ClaudeOrchestrator",
    "Model" -> ...,
    "PromptHash" -> ...,
    "WorkflowRunId" -> ...
  |>,
  "PrivacyLabel" -> <|...|>,
  "LifecycleStatus" -> "Current" | "Stale" | "NeedsReview" | "Invalidated",
  "GeneratedAt" -> DateObject[...]
|>
```

---

## 4. SourceVault の保存レイアウト案

既存 SourceVault の `raw/`, `meta/`, `parsed/`, `bundles/`, `claims/` に加えて、notebook 用の index を追加する。

```text
sourcevault/
  notebooks/
    sources/
      nb-src-....json
    snapshots/
      snap-sha256-....json
    cells/
      by-notebook/
        nb-src-....jsonl
      by-cell/
        cell-....json
    todos/
      open.jsonl
      done.jsonl
      by-notebook/
        nb-src-....jsonl
    review/
      by-next-review/
        2026/
          05/
            13.jsonl
      by-deadline/
        2026/
          05/
            13.jsonl
      overdue.jsonl
    summaries/
      artifact-summary-....json
    lint/
      notebook-lint.jsonl
```

最初は JSONL で十分だが、件数が増えたら compiled registry を作る。

---

## 5. 追加 API 案

### 5.1 登録・index

```mathematica
SourceVaultRegisterNotebook[nbOrPath_,
  "ProjectRoot" -> Automatic,
  "TrustLevel" -> "LocalNotebook",
  "PrivacyPolicy" -> Automatic]

SourceVaultIndexNotebook[nbOrPath_,
  "UpdateSummary" -> False,
  "ExtractTodos" -> True,
  "ExtractHeader" -> True]

SourceVaultIndexNotebookFolder[dir_,
  "Recursive" -> True,
  "IncludePatterns" -> {"*.nb"},
  "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"},
  "UpdateSummaries" -> "IfStale"]
```

### 5.2 抽出

```mathematica
SourceVaultExtractNotebookHeader[nbOrPath_]

SourceVaultExtractNotebookTodos[nbOrPath_,
  "StatusDetection" -> {"TaggingRules", "CellOption", "StyleHeuristic"}]

SourceVaultExtractNotebookCells[nbOrPath_,
  "CellStyles" -> All,
  "IncludeOutputs" -> False,
  "RespectNBAccess" -> True]
```

### 5.3 検索

```mathematica
SourceVaultFindNotebooks[
  "OpenTodos" -> True]

SourceVaultFindNotebooks[
  "NextReview" -> "ThisWeek"]

SourceVaultFindNotebooks[
  "Deadline" -> "Overdue"]

SourceVaultFindNotebooks[
  "Keywords" -> {"オンライン語り交流会"}]
```

### 5.4 概要・更新

```mathematica
SourceVaultNotebookSummary[nbRef_,
  "RefreshIfStale" -> True,
  "SummaryLevel" -> "Notebook",
  "Sink" -> "LocalOrCloudByNBAccess"]

SourceVaultRefreshNotebookSummaryIfStale[nbRef_]

SourceVaultInvalidateNotebookSummary[artifactId_, reason_]
```

### 5.5 Todo 更新

```mathematica
SourceVaultMarkTodo[todoId_, "Done",
  "UpdateNotebook" -> True,
  "UpdateHeaderStatus" -> Automatic]

SourceVaultMarkTodo[todoId_, "Pass",
  "Reason" -> "..."]
```

`UpdateNotebook -> True` の場合は、NBAccess / ClaudeRuntime の commit approval を必ず通す。

---

## 6. 実装上の改修点

### 6.1 ヘッダ cell の安全 parse

先頭 `Input` セルをそのまま評価しない。次のように `HoldComplete` で構文だけ取り出す。

```mathematica
held = ToExpression[boxData, StandardForm, HoldComplete];

SafeNotebookHeaderQ[held_] := MatchQ[
  held,
  HoldComplete[
    Association[
      ___Rule
    ]
  ]
]
```

ただし、実際には `DateObject[{y,m,d}]`, 文字列、文字列リスト、数値、`Missing[...]` などだけを許す whitelist が必要である。

```mathematica
AllowedHeaderValueQ[expr_] :=
  MatchQ[Unevaluated[expr],
    _String |
    _Integer |
    True | False |
    Missing[_] |
    DateObject[{_Integer, _Integer, _Integer}] |
    {_String ...}
  ]
```

安全性のため、以下はヘッダでは拒否する。

```mathematica
RunProcess[_]
ExternalEvaluate[_]
Get[_]
Needs[_]
Import[_]
Export[_]
NotebookWrite[_]
SetDirectory[_]
URLRead[_]
```

---

### 6.2 Todo cell 抽出

静的 notebook expression から Todo cell を抽出する。

```mathematica
iTodoCellQ[Cell[_, style_String, ___]] :=
  StringStartsQ[style, "TodoItem"];

iCellOptionsAssociation[Cell[___, opts___Rule]] :=
  Association[opts];

iStrikeThroughQ[opts_Association] :=
  TrueQ @ Lookup[
    Association @ Lookup[opts, FontVariations, {}],
    "StrikeThrough",
    False
  ];

iTodoStatusFromOptions[opts_Association] :=
  Which[
    KeyExistsQ[opts, TaggingRules] &&
      AssociationQ[opts[TaggingRules]] &&
      KeyExistsQ[opts[TaggingRules], "TodoStatus"],
        opts[TaggingRules, "TodoStatus"],

    iStrikeThroughQ[opts],
        "Done",

    True,
        "Open"
  ];
```

長期的には、`TodoItem` パレット / style button 側で、見た目の変更と同時に

```mathematica
TaggingRules -> <|"TodoStatus" -> "Done"|>
```

を入れるようにする。

---

### 6.3 Header / Todo 整合性 lint

```mathematica
SourceVaultNotebookLint[record_] := Module[
  {headerStatus, openTodos, doneTodos, deadline, nextReview},
  ...
]
```

lint 例:

```text
MissingHeader
UnsafeHeaderExpression
HeaderDeadlineMalformed
HeaderNextReviewMalformed
HeaderStatusUnknown
HeaderStatusTodoButNoOpenTodos
HeaderStatusDoneButOpenTodosExist
DeadlinePast
NextReviewPast
TodoCellStatusHeuristicOnly
TodoTextContainsSensitiveDataInPublicIndex
```

今回の添付 notebook では、少なくとも次が検出対象になる。

```text
HeaderStatusTodoButNoOpenTodos
NextReviewPast
DeadlinePast
```

---

### 6.4 Summary への取り込み

Notebook summary には、本文要約だけでなく、以下を必ず含める。

```mathematica
<|
  "HeaderSummary" -> <|
    "Keywords" -> ...,
    "Deadline" -> ...,
    "NextReview" -> ...,
    "Status" -> ...
  |>,
  "TodoSummary" -> <|
    "OpenTodos" -> {...},
    "DoneTodos" -> {...},
    "Lint" -> {...}
  |>,
  "BodySummary" -> "...",
  "ReviewRecommendation" -> ...
|>
```

これにより、LLM が生成した自然文 summary を読まなくても、SourceVault の deterministic query で review / todo 検索ができる。

---

### 6.5 Index 更新

`SourceVaultIndexNotebook` は以下の順で更新する。

```text
1. path / NotebookRef を解決
2. file mtime と raw hash を取得
3. 変更なしなら index を返す
4. 変更ありなら NotebookSnapshotRecord 作成
5. Header / Todo / Cell record 抽出
6. ReviewRecord 再計算
7. 古い summary artifact を stale にする
8. 必要なら summary を再生成
9. index files を atomic write
```

atomic write は既存 SourceVault の transactional write 方針に合わせる。

---

## 7. NBAccess / privacy との接続

Notebook todo / review index は便利だが、本文や Todo には個人情報・メールアドレス・未公開研究情報が含まれ得る。したがって、index を二層に分けるべきである。

### 7.1 Public / metadata index

cloud LLM に渡してもよい最小限の情報。

```mathematica
<|
  "NotebookRef" -> ...,
  "Keywords" -> ...,
  "Deadline" -> ...,
  "NextReview" -> ...,
  "HeaderStatus" -> ...,
  "OpenTodoCount" -> ...,
  "ReviewState" -> ...
|>
```

### 7.2 Private / local index

本文、Todo text、cell summary、メール本文、個人名などを含み得る情報。

```mathematica
<|
  "TodoText" -> ...,
  "BodySummary" -> ...,
  "CellText" -> ...,
  "ExtractedEntities" -> ...
|>
```

ClaudeEval / ClaudeOrchestrator が cloud LLM を使う場合は、SourceVaultContextBundle materialization 時に NBAccess で projection を選ぶ。

```mathematica
"Projection" -> "MetadataOnly" | "RedactedSummary" | "FullLocalOnly"
```

---

## 8. ClaudeEval / ClaudeOrchestrator への組み込み

### 8.1 ClaudeEval

ClaudeEval からは、まず SourceVault query を発行する。

```mathematica
ClaudeEval[
  "今週中にレビューしないといけないノートブックを一覧して"
]
```

内部処理案:

```text
Natural language
  -> SourceVault query plan
  -> SourceVaultFindNotebooks
  -> 必要なら SourceVaultNotebookSummary
  -> 回答生成
```

raw notebook を読むのは最後の手段にする。

---

### 8.2 ClaudeOrchestrator

Orchestrator には、notebook review 用 workflow template を追加する。

```mathematica
SourceVaultRegisterWorkflowTemplate[
  "NotebookReviewDashboard",
  <|
    "Transitions" -> {
      "FindDueNotebooks",
      "RefreshStaleSummaries",
      "ExtractOpenTodos",
      "ReduceDashboard",
      "CommitDashboardCell"
    },
    "RequiredCapabilities" -> {
      "SourceVault.QueryNotebookIndex",
      "SourceVault.RefreshNotebookSummary",
      "NBAccess.CommitNotebookCell"
    }
  |>
]
```

各 transition は、任意 Wolfram code ではなく capability ref として実装する。

```mathematica
<|
  "Capability" -> "SourceVault.FindNotebooks",
  "Arguments" -> <|"NextReview" -> "ThisWeek"|>,
  "Sink" -> "PrivateKernel"
|>
```

---

## 9. 既存実装への改修箇所

### SourceVault.wl

追加する public symbols:

```mathematica
SourceVaultRegisterNotebook
SourceVaultIndexNotebook
SourceVaultIndexNotebookFolder
SourceVaultExtractNotebookHeader
SourceVaultExtractNotebookTodos
SourceVaultNotebookSummary
SourceVaultFindNotebooks
SourceVaultRefreshNotebookSummaryIfStale
SourceVaultNotebookLint
SourceVaultMarkTodo
```

追加する storage helper:

```mathematica
iNotebookRefFromPath
iNotebookSnapshotMetaLoad
iNotebookSnapshotMetaSave
iNotebookTodoIndexAppend
iNotebookReviewIndexUpdate
iNotebookSummaryArtifactSave
```

### NBAccess.wl

追加・確認するもの:

```mathematica
NBReadNotebookCells[nbOrPath, AccessLevel -> ...]
NBCellPrivacyLabel[cellRef]
NBNotebookPrivacyProfile[nbOrPath]
NBAuthorizeNotebookIndexRead[...]
NBAuthorizeNotebookCommit[...]
```

特に、closed notebook file の静的 parse と open notebook object の `NotebookGet` の双方に対応する。

### claudecode.wl / ClaudeEval

追加するもの:

```mathematica
ClaudeEvalSourceVaultQueryPlan
ClaudeEvalResolveNotebookRefs
ClaudeEvalNotebookReviewDashboard
```

### ClaudeOrchestrator.wl

追加するもの:

```mathematica
NotebookReviewWorkflowTemplate
SourceVaultQueryTransition
SourceVaultRefreshSummaryTransition
CommitReviewDashboardTransition
```

また、worker prompt に raw notebook を直接入れるのではなく、`ContextBundleId` を経由する。

### documentation.wl / style notebook

TodoItem style の状態を、見た目だけでなく `TaggingRules` にも保存するようにする。

推奨:

```mathematica
TaggingRules -> <|
  "SourceVault" -> <|
    "CellKind" -> "Todo",
    "TodoStatus" -> "Done" | "Open" | "Pass",
    "TodoId" -> Automatic
  |>
|>
```

---

## 10. テスト項目

### T-NB-1: 添付 notebook の header 抽出

期待:

```mathematica
<|
  "Keywords" -> {"みんなのケア情報学会", "オンライン語り交流会"},
  "NextReview" -> DateObject[{2026, 5, 13}],
  "Deadline" -> DateObject[{2026, 5, 13}],
  "Status" -> "Todo"
|>
```

### T-NB-2: Todo 抽出

期待:

```mathematica
{
  <|"Text" -> "参加登録", "Status" -> "Done", "StatusSource" -> "CellOption"|>
}
```

### T-NB-3: Review lint

2026-05-19 時点の期待:

```mathematica
{
  "DeadlinePast",
  "NextReviewPast",
  "HeaderStatusTodoButNoOpenTodos"
}
```

### T-NB-4: Open todo query

期待:

```mathematica
SourceVaultFindNotebooks["OpenTodos" -> True]
```

には、この notebook は入らない。ただし `Status -> "Todo"` のみで検索した場合は入るので、検索 UI では両者を区別して表示する。

### T-NB-5: Review due query

期待:

```mathematica
SourceVaultFindNotebooks["NextReview" -> "Overdue"]
```

には、この notebook が入る。

---

## 11. 優先順位

### P0: すぐ追加すべきもの

1. Header association 抽出。
2. TodoItem cell 抽出。
3. Done 判定の heuristic。
4. `Deadline` / `NextReview` index。
5. `SourceVaultFindNotebooks["OpenTodos" -> True]`。
6. `SourceVaultFindNotebooks["NextReview" -> "ThisWeek" | "Overdue"]`。
7. Header / Todo 整合性 lint。

### P1: 実運用に必要なもの

1. `TaggingRules` ベースの明示 TodoStatus。
2. notebook semantic hash。
3. summary artifact の stale 判定。
4. section / cell 単位の差分 summary 更新。
5. NBAccess privacy profile による route 分岐。

### P2: ClaudeEval / Orchestrator 統合

1. 自然言語を SourceVault notebook query に変換。
2. review dashboard workflow。
3. Todo 更新 workflow。
4. summary refresh workflow。
5. workflow run / prompt trace を SourceVault artifact として保存。

---

## 12. 仕様への追記案

SourceVault 仕様に、次の節を追加するのがよい。

```text
## Notebook Management Extension

SourceVault は Mathematica notebook を first-class source として扱う。
Notebook source からは、raw snapshot に加えて、header metadata, todo cells,
review schedule, deadline, privacy profile, semantic cell hashes を抽出する。

Notebook summary artifact は body summary だけでなく、HeaderSummary,
TodoSummary, ReviewRecord を含まなければならない。

NextReview / Deadline / TodoStatus は deterministic index に登録され、
SourceVaultFindNotebooks により LLM を使わず検索できる。

Notebook が更新された場合、NotebookSemanticHash / HeaderHash / TodoHash /
CellHashes に基づいて summary artifact の stale 判定を行う。
```

---

## 13. 結論

今回の notebook 形式は、SourceVault の notebook 管理機能に自然に乗る。

ただし、以下を明確に分ける必要がある。

```text
Header metadata
Todo task state
Review schedule
Deadline
Body summary
Privacy profile
Workflow / prompt trace
```

特に重要なのは、`Status -> "Todo"` だけで notebook の未完了状態を判断しないことである。今回の例では、ヘッダは Todo だが Todo cell は Done と読める。このような不整合を lint として検出し、review dashboard に出す設計が望ましい。

SourceVault に notebook review index を追加すれば、ClaudeEval から

```text
まだ Done になっていない Todo を出して
今週レビューする notebook を出して
このフォルダの notebook 概要を更新して
```

といった指示を、raw notebook の再読込や全件 LLM 要約に頼らず、deterministic index + 必要時 refresh で扱えるようになる。
