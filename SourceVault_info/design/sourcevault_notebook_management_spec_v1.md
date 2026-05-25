# SourceVault Notebook Management 仕様書 v1 (Stage 9 P0 完成版)

**版**: v1.0 (2026-05-19 — Stage 9 P0 動作実証完了)
**前版**: `sourcevault_notebook_review_todo_deadline.md` (レビュー資料)
**実装**: SourceVault.wl `v2026-05-19-stage-9-notebook-management-p0`
**根拠 notebook**: `20260516-第14回オンライン語り交流会.nb`, `result6.nb`, `result7.nb`, `result8.nb`, `result9.nb`, `notebook_import.nb`

---

## 0. 本書の位置づけ

レビュー資料 `sourcevault_notebook_review_todo_deadline.md` の P0 (優先度最高) 範囲を **Stage 9 P0** として実装完了した結果、当初想定と実装が食い違った点 / 拡張した点 / 削除した点を反映した **現状確定仕様** です。

主要変更:
- [Updated §3.4] **Status を 3 値 (Open/Done/Pass) に拡張** — 当初 Todo/Done のみだったが、`Pass` 状態 (スキップ) を追加
- [Updated §6.1-6.2] **Safe Parse の実装手段を全面置換** — パターンマッチを廃止し、Wolfram 標準関数 (`Import[path, "Initialization"]`, `NotebookImport[path, style -> "Cell"]`) を採用
- [New §13] **Wolfram 標準関数優先原則** を追加 (ClaudeDirective rule 102 として永続化)
- [New §14] **罠 #21-#23** を追加 (Wolfram 開発の落とし穴カタログ)

---

## 1. 動機とユースケース

### 1.1 解決したい課題 (変更なし)

Mathematica notebook を作業ノート / 議事録 / Todo リストとして活用しているが、以下の操作が deterministic にできなかった:

- 「今週レビューすべき notebook を出して」 (NextReview ベース)
- 「Deadline を過ぎた未完了 notebook を出して」
- 「Status が Todo のまま放置されている notebook を出して」
- 「未完了 Todo セルが残っている notebook を出して」
- 「Done または Pass と判定された Todo の履歴」 [Updated: Pass 追加]

これらを **LLM 不要・低遅延・再現可能** な deterministic クエリで実現する。

### 1.2 設計の核心 — 3 つの分離 (変更なし)

#### (1) Header.Status と Todo cell 状態の独立保存

```
notebook 先頭 Header:        <|"Status" -> "Todo", ...|>
notebook 内 TodoItem cell:   FontVariations -> {"StrikeThrough" -> True}, 
                              FontColor -> ...
                                                  ↓
                              cell 状態 = Done / Pass
```

Header.Status と Todo cell 状態を **独立に保存** し、不整合を `HeaderStatusTodoButNoOpenTodos` lint として検出する。

#### (2) Deterministic index vs LLM 要約

- **Deterministic** (Stage 9 P0): `FindNotebooks["OpenTodos" -> True]` 等の決定論的クエリ
- **LLM-backed** (Stage 9 Phase 2): `SourceVaultNotebookSummary[nbRef]` で body 要約

P0 では deterministic 側のみ実装。

#### (3) Status 判定の優先順位 [Updated]

```
1. TaggingRules["TodoStatus"] または TaggingRules["SourceVault"]["TodoStatus"]
                                                      → StatusSource: "TaggingRules"
2. FontVariations -> {"StrikeThrough" -> True} + FontColor 緑系  
                                                      → "Done"      StatusSource: "CellOptionGreen"
3. FontVariations -> {"StrikeThrough" -> True} + FontColor 灰系  
                                                      → "Pass"      StatusSource: "CellOptionGray"
4. FontVariations -> {"StrikeThrough" -> True} + その他            
                                                      → "Done"      StatusSource: "CellOption"  (後方互換)
5. それ以外                                            → "Open"      StatusSource: "Default"
```

各 Todo record に `StatusSource` を保存することで判定根拠を追跡可能。

---

## 2. データモデル

### 2.1 NotebookSourceRecord

```mathematica
<|
  "Type" -> "NotebookSource",
  "NotebookRef" -> "nb-src-<hash16>",      (* SHA-256 of absolute path、先頭 16 文字 *)
  "OriginalPath" -> "C:\\...\\file.nb",
  "Title" -> "file",                        (* FileBaseName *)
  "FileMTime" -> "2026-05-19T...",
  "CurrentSnapshotId" -> "snap-sha256-...",
  "RegisteredAt" -> "...",
  "LastIndexedAt" -> "..."
|>
```

### 2.2 NotebookSnapshotRecord

```mathematica
<|
  "Type" -> "NotebookSnapshot",
  "SnapshotId" -> "snap-sha256-<hash>",
  "NotebookRef" -> "nb-src-...",
  "RawContentHash" -> "sha256-...",
  "CellCount" -> _Integer,
  "LifecycleStatus" -> "Current" | "Stale" | "Superseded" | "Invalidated",
  "CreatedAt" -> "..."
|>
```

P0 では `NotebookSemanticHash`/`HeaderHash`/`TodoHash`/`CellHashes` は未実装 (Phase 2)。

### 2.3 NotebookHeaderRecord

```mathematica
<|
  "Type" -> "NotebookHeader",
  "NotebookRef" -> "...",
  "SnapshotId" -> "...",
  "ParseStatus" -> "OK" | "MissingHeader" | "UnsafeExpression",
  "Keywords" -> {_String, ...} | Missing[],
  "Deadline" -> _DateObject | Missing[],
  "NextReview" -> _DateObject | Missing[],
  "Status" -> _String | Missing[],          (* "Todo" / "Done" / 任意の文字列 *)
  "RawHeader" -> _Association,              (* 元の Association、デバッグ用 *)
  "ExtractedAt" -> "..."
|>
```

### 2.4 NotebookTodoRecord [Updated: 3 値 Status]

```mathematica
<|
  "Type" -> "NotebookTodo",
  "TodoId" -> "todo-<nbRef>-<index>",
  "NotebookRef" -> "...",
  "SnapshotId" -> "...",
  "Index" -> _Integer,                      (* notebook 内の出現順 *)
  "CellStyle" -> "TodoItem_1" | "TodoItem_2" | "TodoItem_3",
  "Text" -> _String,                        (* cell の表示テキスト *)
  "Status" -> "Open" | "Done" | "Pass",     (* [Updated] 3 値 *)
  "StatusSource" -> "TaggingRules"          (* TaggingRules による明示判定 *)
                   | "CellOptionGreen"      (* [New] StrikeThrough + 緑 FontColor *)
                   | "CellOptionGray"       (* [New] StrikeThrough + 灰 FontColor *)
                   | "CellOption"           (* StrikeThrough のみ、後方互換 *)
                   | "Default",             (* StrikeThrough なし *)
  "StrikeThrough" -> _Bool,
  "ExtractedAt" -> "..."
|>
```

**Pass 状態の意味論**: Done とは異なる「**スキップ / 該当せず / 対象外**」を示す。例えば「該当するイベントには参加しなかったが、Todo としては closed」のような状態。

[Deprecated 2.4] `Depth`, `ParentTodoId`, `DueDate`, `NextReview` の継承は Phase 2 に延期。

### 2.5 NotebookReviewRecord [Updated: PassTodoCount 追加]

```mathematica
<|
  "Type" -> "NotebookReview",
  "NotebookRef" -> "...",
  "SnapshotId" -> "...",
  "OriginalPath" -> "...",
  "Title" -> "...",
  "Deadline" -> _DateObject | Missing[],
  "NextReview" -> _DateObject | Missing[],
  "ReviewState" -> "Overdue" | "DueThisWeek" | "Current" | "NoReviewDate",
  "DeadlineState" -> "Overdue" | "DueSoon" | "Future" | "NoDeadline",
  "OpenTodoCount" -> _Integer,
  "DoneTodoCount" -> _Integer,
  "PassTodoCount" -> _Integer,              (* [New] *)
  "Lint" -> {_String, ...},
  "ComputedAt" -> "..."
|>
```

### 2.6 NotebookSummaryArtifact (Phase 2 で実装)

- P0 では未実装
- Stage 9 Phase 2 で `Kind: "Notebook"` 特化型の Bundle として実装予定

---

## 3. 物理ストレージレイアウト

```
<PrivateVault>/notebooks/
  sources/
    nb-src-<hash16>.json              # NotebookSourceRecord (path-based ID)
  snapshots/
    snap-sha256-<hash>.json           # NotebookSnapshotRecord
  todos/
    by-notebook/
      nb-src-<...>.jsonl              # 各 notebook の Todo 一覧 (JSONL)
  review/
    overdue.jsonl                     # Overdue review notebook の append-only log
  lint/
    notebook-lint.jsonl               # 全 lint event の append-only log
```

[Deprecated 3] by-month / by-day pivot (`review/by-next-review/YYYY/MM/DD.jsonl`) は P0 では未実装、`overdue.jsonl` の単一 append-only log のみ。

---

## 4. Public API

### 4.1 一覧

```mathematica
SourceVaultRegisterNotebook[path]
SourceVaultIndexNotebook[path, opts]
SourceVaultIndexNotebookFolder[dir, opts]
SourceVaultExtractNotebookHeader[path]
SourceVaultExtractNotebookTodos[path]
SourceVaultFindNotebooks[opts]
SourceVaultNotebookLint[record | path]
```

### 4.2 `SourceVaultExtractNotebookHeader[path]` 

```mathematica
SourceVaultExtractNotebookHeader["C:\\...\\file.nb"]
(* → <|
     "ParseStatus" -> "OK" | "MissingHeader" | "UnsafeExpression",
     "Keywords" -> _List | Missing[],
     "Deadline" -> _DateObject | Missing[],
     "NextReview" -> _DateObject | Missing[],
     "Status" -> _String | Missing[],
     "RawHeader" -> _Association
   |> *)
```

### 4.3 `SourceVaultExtractNotebookTodos[path]` [Updated: 3 値 Status]

```mathematica
SourceVaultExtractNotebookTodos["C:\\...\\file.nb"]
(* → {
     <|"Index" -> 1, "CellStyle" -> "TodoItem_1",
       "Text" -> "参加登録", "Status" -> "Done",
       "StatusSource" -> "CellOptionGreen", "StrikeThrough" -> True|>,
     <|"Index" -> 2, "CellStyle" -> "TodoItem_1",
       "Text" -> "サンプル", "Status" -> "Open",
       "StatusSource" -> "Default", "StrikeThrough" -> False|>,
     <|"Index" -> 3, "CellStyle" -> "TodoItem_2",
       "Text" -> "サンプル2", "Status" -> "Pass",
       "StatusSource" -> "CellOptionGray", "StrikeThrough" -> True|>
   } *)
```

### 4.4 `SourceVaultIndexNotebook[path, opts]` [Updated: PassTodoCount 追加]

```mathematica
Options[SourceVaultIndexNotebook] = {
  "ExtractHeader" -> True,
  "ExtractTodos" -> True,
  "ForceReindex" -> False    (* P0 では未活用、毎回 re-index *)
};

SourceVaultIndexNotebook[path]
(* → <|
     "Status" -> "OK",
     "NotebookRef" -> "nb-src-...",
     "SnapshotId" -> "snap-sha256-...",
     "Path" -> "...",
     "Header" -> <|...|>,
     "TodoCount" -> _Integer,
     "OpenTodoCount" -> _Integer,
     "DoneTodoCount" -> _Integer,
     "PassTodoCount" -> _Integer,         (* [New] *)
     "ReviewState" -> "Overdue" | "DueThisWeek" | "Current" | "NoReviewDate",
     "DeadlineState" -> "Overdue" | "DueSoon" | "Future" | "NoDeadline",
     "Lint" -> {_String, ...},
     "IndexedAt" -> "..."
   |> *)
```

### 4.5 `SourceVaultIndexNotebookFolder[dir, opts]`

```mathematica
Options[SourceVaultIndexNotebookFolder] = {
  "Recursive" -> False,
  "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}
};

SourceVaultIndexNotebookFolder["C:\\path\\to\\notebooks", "Recursive" -> True]
(* → <|
     "Status" -> "OK",
     "TotalFiles" -> _Integer,
     "Processed" -> _Integer,
     "Failed" -> _Integer,
     "Results" -> {<|...|>, ...}
   |> *)
```

### 4.6 `SourceVaultFindNotebooks[opts]`

```mathematica
Options[SourceVaultFindNotebooks] = {
  "OpenTodos" -> Missing[] | True | False,
  "NextReview" -> Missing[] | "Overdue" | "ThisWeek" | "DueSoon" | <|"From" -> _, "To" -> _|>,
  "Deadline" -> Missing[] | "Overdue" | "ThisWeek" | "DueSoon" | <|"From" -> _, "To" -> _|>,
  "Keywords" -> Missing[] | {_String, ...},
  "Status" -> Missing[] | _String
};
```

**重要な区別**:

```mathematica
SourceVaultFindNotebooks["OpenTodos" -> True]    (* 実作業残あり (Open Todo > 0) *)
SourceVaultFindNotebooks["Status" -> "Todo"]     (* Header メタデータ未更新 *)
```

[Updated 4.6] Pass を含む notebook の検索は将来追加: `"AnyPass" -> True` 等は Phase 2 へ。P0 では `OpenTodos -> True/False` のみ。

### 4.7 `SourceVaultNotebookLint[record | path]` [Updated: Pass 対応]

検出される lint (9 種):

```
MissingHeader                            - 先頭セル発見できず
UnsafeHeaderExpression                   - whitelist 違反
HeaderDeadlineMalformed                  - Deadline が DateObject でない
HeaderNextReviewMalformed                - NextReview が DateObject でない
HeaderStatusTodoButNoOpenTodos           - Header Todo だが Open Todo がない
                                          (Done + Pass で全 closed の場合に発生)
HeaderStatusDoneButOpenTodosExist        - Header Done だが Open Todo が残っている
DeadlinePast                             - Deadline 過去
NextReviewPast                           - NextReview 過去
TodoCellStatusHeuristicOnly              - TaggingRules なし、CellOption** だけで判定
                                          (StatusSource が "CellOption(Green|Gray)?" のいずれか)
```

[Updated 4.7] `HeaderStatusTodoButNoOpenTodos` の判定: openCount が 0 でも Done **または** Pass の totalCount が 1 以上ある場合に発生する (Pass 状態が closed として扱われる)。

---

## 5. 実装方針 — Wolfram 標準関数優先 [Updated 全面]

### 5.1 根本原則 [New]

> **ノートブックや Wolfram 式の構造にアクセスする時は、必ず先に Wolfram 標準関数を探す。パターンマッチや手書きパースは最終手段。**

(ClaudeDirective `rules/102-wolfram-stdlib-first.md` として永続化)

### 5.2 Header parse の正規ルート

```mathematica
iNotebookHeaderParseFromInitialization[path_String] :=
  Module[{inits, assoc, parseStatus = "OK"},
    inits = Quiet[Import[path, "Initialization"]];
    If[!ListQ[inits] || inits === {}, Return[Missing["InitImportFailed"]]];
    assoc = First[inits];
    If[!AssociationQ[assoc], Return[Missing["InitNotAssociation"]]];
    
    (* 後付け whitelist 検証 — Import["Initialization"] は評価するため *)
    If[!AllTrue[Values[assoc], iAllowedHeaderValueQ],
      parseStatus = "UnsafeExpression"];
    
    <|"ParseStatus" -> parseStatus,
      "Keywords" -> Lookup[assoc, "Keywords", Missing[]],
      "Deadline" -> Lookup[assoc, "Deadline", Missing[]],
      "NextReview" -> Lookup[assoc, "NextReview", Missing[]],
      "Status" -> Lookup[assoc, "Status", Missing[]],
      "RawHeader" -> assoc|>
  ];
```

**Safety トレードオフ** (v0 spec §6.1 からの変更):

- `Import[path, "Initialization"]` は **InitializationCell の中身を評価** する
- 副作用ある式 (`RunProcess`, `Get`, ...) は実行されてしまう
- しかし返り値の Association を **whitelist で値型検証** することで SourceVault 保存を防御
- 実用性を優先した妥協

#### whitelist 定義

```mathematica
iAllowedHeaderValueQ[expr_] :=
  Or[
    StringQ[expr],
    IntegerQ[expr],
    NumericQ[expr] && Head[expr] === Real,
    expr === True, expr === False,
    MatchQ[expr, Missing[___]],
    MatchQ[expr, DateObject[{_Integer, _Integer, _Integer}, ___]],
    MatchQ[expr, DateObject[{_Integer, _Integer, _Integer, _Integer, _Integer, _?NumericQ}, ___]],
    ListQ[expr] && AllTrue[expr, StringQ[#] || IntegerQ[#] &],
    AssociationQ[expr] && AllTrue[Values[expr], iAllowedHeaderValueQ]  (* 再帰 *)
  ];
```

#### Header parse 第二フォールバック (`iNotebookHeaderParseFromBoxes`)

`Import[path, "Initialization"]` が失敗した場合:

```mathematica
iNotebookHeaderParseFromBoxes[nbExpr_HoldComplete] :=
  Module[{cells, headerCell, boxData, held, assoc, parseStatus = "OK"},
    cells = iFlattenCells[nbExpr];   (* CellGroupData を展開 *)
    headerCell = SelectFirst[cells, iCellIsInitializationInputQ, Missing[]];
    ...
    boxData = First[headerCell];
    (* MakeExpression: box → HoldComplete[expr]、評価せず — 罠 #22 *)
    held = Quiet[MakeExpression[boxData, StandardForm]];
    ...
  ];
```

### 5.3 Todo 抽出の正規ルート

```mathematica
iExtractTodoCellsFromPath[path_String] :=
  Module[{styles, results = {}, idx = 0},
    styles = {"TodoItem_1", "TodoItem_2", "TodoItem_3"};
    Scan[
      Function[style,
        Module[{cells},
          cells = Quiet[NotebookImport[path, style -> "Cell"]];
          If[ListQ[cells],
            Scan[
              Function[c,
                If[SymbolName[Head[c]] === "Cell" && Length[c] >= 2,
                  Module[{args = List @@ c, txt, opts, status},
                    idx = idx + 1;
                    txt = iCellTextExtract[args[[1]]];
                    opts = Association[Cases[Drop[args, 2], _Rule]];
                    status = iTodoStatusFromOptions[opts];
                    AppendTo[results, <|
                      "Index" -> idx,
                      "CellStyle" -> style,
                      "Text" -> txt,
                      "Status" -> status["Status"],
                      "StatusSource" -> status["StatusSource"],
                      "StrikeThrough" -> iStrikeThroughQ[opts]
                    |>]
                  ]
                ]
              ],
              cells
            ]
          ]
        ]
      ],
      styles
    ];
    results
  ];
```

**重要なポイント**:
- `NotebookImport[path, style -> "Cell"]` が Wolfram 標準関数で、`System`Cell[...]` を確実に返す
- パターンマッチは使わない (context 問題回避)
- 全シンボル参照は `SymbolName[Head[c]] === "Cell"` で **context 非依存** の文字列比較

### 5.4 Status 判定の正規実装 [Updated: 3 値]

```mathematica
iTodoStatusFromOptions[opts_Association] :=
  Module[{tagKey, tagging, todoStatus, strike, fc, sv},
    (* 1. TaggingRules 明示 (将来の標準) *)
    tagKey = SelectFirst[Keys[opts],
      SymbolName[#] === "TaggingRules" &, Null];
    tagging = If[tagKey =!= Null, opts[tagKey], Missing[]];
    If[AssociationQ[tagging],
      sv = Lookup[tagging, "SourceVault", Missing[]];
      If[AssociationQ[sv],
        todoStatus = Lookup[sv, "TodoStatus", Missing[]];
        If[StringQ[todoStatus],
          Return[<|"Status" -> todoStatus, "StatusSource" -> "TaggingRules"|>]]];
      todoStatus = Lookup[tagging, "TodoStatus", Missing[]];
      If[StringQ[todoStatus],
        Return[<|"Status" -> todoStatus, "StatusSource" -> "TaggingRules"|>]]];
    
    (* 2. StrikeThrough + FontColor heuristic (3 値判定) *)
    strike = iStrikeThroughQ[opts];
    fc = iCellFontColor[opts];
    
    If[!strike,
      Return[<|"Status" -> "Open", "StatusSource" -> "Default"|>]
    ];
    
    Which[
      iColorIsGrayQ[fc],
        <|"Status" -> "Pass", "StatusSource" -> "CellOptionGray"|>,
      iColorIsGreenQ[fc],
        <|"Status" -> "Done", "StatusSource" -> "CellOptionGreen"|>,
      True,
        <|"Status" -> "Done", "StatusSource" -> "CellOption"|>   (* 後方互換 *)
    ]
  ];
```

#### 色判定 helper

```mathematica
iColorIsGrayQ[fc_] :=
  MatchQ[fc, GrayLevel[_?NumericQ]] ||
  MatchQ[fc, GrayLevel[_?NumericQ, _?NumericQ]] ||
  MatchQ[fc, RGBColor[r_?NumericQ, g_?NumericQ, b_?NumericQ] /;
    Abs[r - g] < 0.05 && Abs[g - b] < 0.05 && Abs[r - b] < 0.05];

iColorIsGreenQ[fc_] :=
  MatchQ[fc, RGBColor[r_?NumericQ, g_?NumericQ, b_?NumericQ] /;
    g > r && g > b && (g - Min[r, b] > 0.1)];

iCellFontColor[opts_Association] :=
  Module[{fcKey},
    fcKey = SelectFirst[Keys[opts], SymbolName[#] === "FontColor" &, Null];
    If[fcKey === Null, Null, opts[fcKey]]
  ];
```

### 5.5 Notebook 読み込みの正規ルート (フォールバック用)

```mathematica
iReadNotebookExpr[path_String] :=
  Module[{nbExpr},
    If[!FileExistsQ[path],
      Return[<|"Status" -> "Failed", "Reason" -> "FileNotFound", "Path" -> path|>]];
    nbExpr = Quiet[Import[path, "Notebook"]];   (* Notebook[{Cell[...], ...}, opts] を返す *)
    If[FailureQ[nbExpr] || !MatchQ[nbExpr, Notebook[_List, ___]],
      Return[<|"Status" -> "Failed", "Reason" -> "NotANotebookFile", "Path" -> path|>]];
    <|"Status" -> "OK", "Expr" -> HoldComplete[nbExpr], "Path" -> path|>
  ];
```

### 5.6 [Deprecated 5.6] 廃止された実装手段

Stage 9 P0 開発初期に試したが、いずれも動作不能となった経路:

| 廃止手法 | 廃止理由 | 罠 # |
|---|---|---|
| `Get[path]` で `.nb` を読む | FE 連携・NotebookObject 化等の特殊挙動 | #21 |
| `Import[path, "Text"]` + `ToExpression[..., InputForm, HoldComplete]` | コメント注釈 (`(*CacheID:...*)`) と `Notebook[...]` 式の混在で不安定 | #21 |
| `ToString[box, StandardForm]` + `ToExpression[str, StandardForm, HoldComplete]` | box の意味を保てない (`MakeExpression` が正規) | #22 |
| Package private context 内で `Cell[_, _String, ___]` の生パターンマッチ | `SourceVault\`Private\`Cell` に別シンボル化される | #23 |

---

## 6. Safe Parse の意味論 [Updated]

### 6.1 元仕様の Safe Parse 原則 (変更なし)

> 先頭セルの中身を **そのまま評価しない**。`RunProcess[_]` / `Get[_]` / `URLRead[_]` 等の危険式を排除する。

### 6.2 実装上のトレードオフ [New]

理想的な実装:

```mathematica
(* 理想: 評価せず box → HoldComplete[expr] *)
held = MakeExpression[boxData, StandardForm];
assoc = ReleaseHold[held];   (* 純粋値のみ ReleaseHold *)
```

実用的な実装 (Stage 9 P0):

```mathematica
(* 実用: Import["Initialization"] が評価するが、値レベルで whitelist *)
inits = Import[path, "Initialization"];
assoc = First[inits];
If[!AllTrue[Values[assoc], iAllowedHeaderValueQ], parseStatus = "UnsafeExpression"];
```

両者の差:

| 側面 | 理想 (`MakeExpression`) | 実用 (`Import["Initialization"]`) |
|---|---|---|
| 評価の有無 | 評価しない | 評価する |
| 副作用の危険 | 完全に排除 | 評価時に発生する可能性 |
| 実装の複雑さ | 中 (Notebook 全体読み込み + cell 走査必要) | 低 (一発呼び出し) |
| Wolfram 標準関数 | `MakeExpression` のみ | `Import` 一発 |
| **P0 採用** | 第二フォールバック | **第一選択** |

**評価される問題への対策**: 副作用のある式が実行されても、whitelist で **値レベルで弾く** ため SourceVault に保存されない。SourceVault のデータ整合性は保てるが、評価そのものは止められない。これは設計上の妥協であり、必要なら Stage 9 Phase 2 で `MakeExpression` 第一選択に切り替え可能。

### 6.3 whitelist で許可される値型

```
String / Integer / Real
True / False
Missing[___]
DateObject[{y,m,d}] または DateObject[{y,m,d,h,m,s}]
文字列のリスト / 整数のリスト
Association (再帰的に上記を満たすもの)
```

### 6.4 拒否される値型 (例)

```
RunProcess[_], Get[_], Import[_], URLRead[_]
NotebookWrite[_], SetDirectory[_]
任意の関数呼び出し
List of arbitrary expressions
```

---

## 7. NotebookImport の活用 [New]

### 7.1 `NotebookImport` とは

Wolfram の標準関数 `NotebookImport[path, style -> "Cell"]` は:
- 特定の cell style の全 cell を **Cell 式そのまま** で返す
- 戻り値は `System`Cell[...]` の List (`{}` も可)
- パターンマッチ不要、context 問題なし
- `.nb` ファイル全体を読まず、必要な cell だけ取り出すので高速

### 7.2 動作例 (`notebook_import.nb` で実演)

```mathematica
NotebookImport[path, "TodoItem_1" -> "Cell"]
(* → {Cell["参加登録", "TodoItem_1",
        FontVariations -> {"StrikeThrough" -> True},
        FontColor -> RGBColor[0.525, 0.745, 0.196],
        Background -> GrayLevel[0.95], 
        ExpressionUUID -> "..."]} *)

NotebookImport[path, "TodoItem_1"]
(* → {"参加登録"} *)   (* テキストだけ *)

NotebookImport[path, "TodoItem_2" -> "Cell"]
(* → {Cell["サンプル2", "TodoItem_2",
        FontVariations -> {"StrikeThrough" -> True},
        FontColor -> GrayLevel[0.75],
        Background -> GrayLevel[0.95], 
        ExpressionUUID -> "..."]} *)

NotebookImport[path, "TodoItem_3" -> "Cell"]
(* → {} *)   (* 該当 cell なし *)
```

### 7.3 SourceVault での使い方

Stage 9 P0 では `TodoItem_1`, `TodoItem_2`, `TodoItem_3` の 3 スタイルを順次試して結合:

```mathematica
styles = {"TodoItem_1", "TodoItem_2", "TodoItem_3"};
allCells = Flatten[
  Map[NotebookImport[path, # -> "Cell"] &, styles]];
```

---

## 8. NBAccess / privacy 連携 (Phase 2 へ延期)

P0 では未実装。Phase 2 で:

- `NBNotebookPrivacyProfile` による route 分岐
- privacy 配慮の高い notebook では `sendDecision` / `persistDecision` (Stage 6d 経由) を要求
- `SourceVaultMarkTodo[todoId, "Done"]` は NBAccess approval 必須

---

## 9. ClaudeEval / Orchestrator 連携 (Phase 3 へ延期)

P0 では未実装。Phase 3 で:

- 自然言語 → SourceVault notebook query 変換
  - 「先月作業した notebook のうち、まだ Todo が残っているもの」
  - 「今週レビューする notebook を出して」
- `NotebookReviewDashboard` workflow template (ClaudeOrchestrator)
- Workflow run / prompt trace を SourceVault artifact として保存

---

## 10. テスト

### 10.1 必須テスト (P0)

| ID | テスト | 期待結果 |
|---|---|---|
| T-NB-1 | `SourceVaultExtractNotebookHeader[path]` | ParseStatus -> "OK", Keywords / Deadline / NextReview / Status / RawHeader 全フィールド |
| T-NB-2 | `SourceVaultExtractNotebookTodos[path]` | Open / Done / Pass の 3 値判定、StatusSource 追跡 |
| T-NB-3 | `SourceVaultIndexNotebook[path]` | TodoCount / OpenTodoCount / DoneTodoCount / **PassTodoCount** / Lint / ReviewState / DeadlineState |
| T-NB-4 | `SourceVaultFindNotebooks["OpenTodos" -> True]` | Open Todo > 0 の notebook のみ |
| T-NB-5 | `SourceVaultNotebookLint[path]` | 9 種 lint のうち該当するもの |

### 10.2 添付 notebook での実証 (`20260516-第14回オンライン語り交流会.nb`)

```
入力構造:
  Header (Input + InitializationCell -> True):
    <|"Keywords" -> {"みんなのケア情報学会", "オンライン語り交流会"},
      "NextReview" -> DateObject[{2026, 5, 13}, "Day"],
      "Deadline" -> DateObject[{2026, 5, 13}, "Day"],
      "Status" -> "Todo"|>
  TodoItem_1: "参加登録"   (StrikeThrough + 緑)  → Done
  TodoItem_1: "サンプル"   (StrikeThrough なし)   → Open
  TodoItem_2: "サンプル2"  (StrikeThrough + 灰)   → Pass

期待出力:
  Header: ParseStatus -> "OK", Status -> "Todo"
  Todos: 3 件 (Open=1, Done=1, Pass=1)
  Lint: {"DeadlinePast", "NextReviewPast", "TodoCellStatusHeuristicOnly"}
  (HeaderStatusTodoButNoOpenTodos は出ない — Open Todo が 1 件残るので)
```

---

## 11. P0 / P1 / P2 段階的実装計画 [Updated]

### P0 (Stage 9 — 本仕様で完成)

実装範囲:
- ✅ Public API 7 個
- ✅ Header / Todo / Snapshot / Lint 抽出
- ✅ 3 値 Status 判定 (Open/Done/Pass) [Updated]
- ✅ deterministic FindNotebooks クエリ
- ✅ `Import["Initialization"]` + `NotebookImport` ベースの実装 [Updated]
- ✅ 7 (→9) 種 lint [Updated]

### P1 (Stage 9 Phase 2)

実装予定:
- TaggingRules 標準化 (`TaggingRules["SourceVault"]["TodoStatus"]`)
  - Notebook 側 stylesheet 改修も含む
  - 完了後は `TodoCellStatusHeuristicOnly` lint がデフォルトで出なくなる
- `NotebookSemanticHash` (表示 / cache / CellChangeTimes 除外)
- `HeaderHash` / `TodoHash` / `CellHashes`
- Section / cell 単位の差分 summary 更新
- NBAccess privacy profile による route 分岐
- `SourceVaultNotebookSummary` (LLM 要約)
- `SourceVaultMarkTodo[todoId, _]` (commit、NBAccess approval 必須)
- File mtime ベースの index skip (`ForceReindex -> False` 活用)
- `FindNotebooks` の re-index lazy 緩和

### P2 (Stage 9 Phase 3)

実装予定:
- ClaudeEval から自然言語 → notebook query 変換
- `NotebookReviewDashboard` workflow template (ClaudeOrchestrator)
- Todo 更新 workflow (commit approval は NBAccess 経由)
- Summary refresh workflow (Stage 6c Bundle と統合)
- Workflow run / prompt trace を SourceVault artifact として保存

---

## 12. Stage 6c / 8 / 6d / 6b との接続

| 既存 Stage | Stage 9 での活用 |
|---|---|
| Stage 6c (Evidence Bundle) | `NotebookSummaryArtifact` は Bundle の `Kind: "Notebook"` 特化形 (Phase 2) |
| Stage 8 (vN diff) | Notebook 更新時の lifecycle event を再利用 |
| Stage 6d (NBAuthorize) | privacy 配慮の高い notebook で sendDecision/persistDecision (Phase 2) |
| Stage 6b (Registry) | Notebook query 結果を compiled registry 化 (Phase 2) |
| Stage 6a (Claim dedup) | Notebook 内容から claim 抽出する場合の dedup (Phase 3) |

特に **Stage 6c Phase 2 (階層集約)** と Stage 9 は強く結びつく:
> **Notebook = 最も自然な階層 Bundle のユースケース** (Notebook → Sections → Cells)

---

## 13. Wolfram 標準関数優先原則 [New]

ClaudeDirective `rules/102-wolfram-stdlib-first.md` として永続化。

### 13.1 推奨関数表 (Notebook 関連)

| 用途 | 推奨関数 |
|---|---|
| Notebook 全体を式として読む | `Import[path, "Notebook"]` |
| InitializationCell の中身を取得 | `Import[path, "Initialization"]` |
| 特定 cell style を式付きで取得 | `NotebookImport[path, style -> "Cell"]` |
| 特定 cell style のテキストだけ取得 | `NotebookImport[path, style]` |
| TaggingRules を取得 | `Import[path, "TaggingRules"]` (Phase 2) |
| Plain text / Markdown 化 | `Import[path, "PlainText"]` / `Import[path, "Markdown"]` |
| Notebook を開かずに編集 | `NotebookOpen[path, Visible -> False]` |

### 13.2 推奨関数表 (Expression 解析)

| 用途 | 推奨関数 |
|---|---|
| Box → expr (評価せず) | `MakeExpression[box, StandardForm]` (`HoldComplete[expr]` 返す) |
| Expr → box | `MakeBoxes[expr, StandardForm]` |
| `.wl` / `.m` のロード | `Get[path]` / `Needs[...]`、`.nb` には **使わない** |

### 13.3 探す順番チェックリスト

新しい Wolfram 機能の実装を始める前:

1. [ ] Wolfram Documentation Center で機能名を検索 (`NotebookImport`, `Import` の format option 等)
2. [ ] 似た用途の既存組み込み関数があるか確認
3. [ ] `tutorial/...` でその領域の概要を読む
4. [ ] それでも見つからない場合に限り、生 expression をパースする実装に進む
5. [ ] パース実装をする場合も、**context 非依存** (`SymbolName[Head[]]`) または `MakeExpression` 経由で書く

---

## 14. 罠カタログ (新規 #21-#23) [New]

`skills/wolfram-syntax-pitfalls/SKILL.md` に永続記録。

### 14.1 罠 #21: `.nb` ファイルを `Get` / `Import["Text"]` でパースしない

**現象**:
- `Get[path.nb]` で `Notebook[...]` 式が返るはずだが、FE 経由で `NotebookObject` 化される / 特殊評価が走る等で期待と違う形になる
- `Import[path, "Text"]` + `ToExpression[content, InputForm, HoldComplete]` はコメント注釈と `Notebook[...]` 式の混在で `ToExpression` の挙動が不安定

**正解**:
```mathematica
nb = Import[path, "Notebook"]                    (* Notebook[...] 式 *)
inits = Import[path, "Initialization"]           (* {<|...|>} *)
todoCells = NotebookImport[path, "Style" -> "Cell"]   (* {Cell[...], ...} *)
```

### 14.2 罠 #22: `ToString[box]` + `ToExpression` ラウンドトリップは破綻する

**現象**: `BoxData[RowBox[{...}]]` を `ToString[..., StandardForm]` で文字列化 → `ToExpression[str, StandardForm, HoldComplete]` で読み戻すと、box の意味を保てず期待と違う形になる。

**正解**: `MakeExpression[box, StandardForm]` を使う。box → `HoldComplete[expr]` の正規変換関数で、評価しない。

```mathematica
held = MakeExpression[BoxData[RowBox[{"<|", ..., "|>"}]], StandardForm]
(* → HoldComplete[<|...|>] *)
```

### 14.3 罠 #23: Package private context で Cell/Notebook 生パターンマッチは別シンボル化

**現象**: `SourceVault.wl` のような package で `Begin["`Private`"]` 内に `Cell[_, _String, ___]` のようなパターンを書くと、`Cell` が `SourceVault`Private`Cell` という新しいシンボルとして作られる。一方 `Import[path, "Notebook"]` の出力は `System`Cell[...]` を含むので両者がマッチしない。

**症状**:
- `Cases[...]` / `SelectFirst[...]` で何も見つからない
- Header parse は `Import["Initialization"]` 経由なら成功するのに、Todo 抽出だけ `{}` を返す

**正解**:
```mathematica
(* OK: SymbolName で文字列名比較 (context 非依存) *)
If[SymbolName[Head[c]] === "Cell" && Length[c] >= 2 && StringQ[c[[2]]], ...]

(* OK: Keys を SymbolName で検索 *)
fcKey = SelectFirst[Keys[opts], SymbolName[#] === "FontColor" &, Null];

(* NG: 生パターン (context 依存) *)
MatchQ[c, Cell[_, _String, ___]]       (* private context で hit しないリスク *)
Lookup[opts, FontColor, Null]          (* private context で別シンボル *)
```

**より根本的な対策**: そもそも `Import[path, "Notebook"]` でファイル全体を読んでパターンマッチするより、`NotebookImport[path, style -> "Cell"]` のような **目的特化型関数** を使う方が安全。

---

## 15. 既知の制約と将来計画

### 15.1 現状の制約

- `Import[path, "Initialization"]` は評価が走る (副作用ある式は実行される) — whitelist で値レベル防御
- `FindNotebooks` は毎回 re-index する (file mtime ベース skip は Phase 2)
- by-date pivot (`review/by-next-review/YYYY/MM/DD.jsonl`) は未実装、`overdue.jsonl` のみ
- `NotebookSemanticHash` 未実装 — content hash のみ
- LLM-backed summary 未実装
- `SourceVaultMarkTodo` (notebook commit) 未実装

### 15.2 設計上の前提

- `TodoItem_1` / `TodoItem_2` / `TodoItem_3` の 3 スタイルが TodoItem として使われる (それ以外は無視)
- `TaggingRules` 標準化前は `StatusSource = "CellOption(Green|Gray)?"` で判定 → `TodoCellStatusHeuristicOnly` lint が出る
- Notebook 内のすべての TodoItem cell は **トップレベルまたは CellGroupData 内** にある (より深いネストは未対応)

### 15.3 Phase 2 で改善する項目

- `TaggingRules["SourceVault"]["TodoStatus"] -> "Done" | "Pass" | "Open"` 形式での明示
  - Notebook 側 stylesheet 改修により、ラジオボタン UI が TaggingRules を更新するように
  - `TodoCellStatusHeuristicOnly` lint がデフォルトで消える
- `MakeExpression` 第一選択化 (副作用ある式を完全に排除)
- File mtime ベースの index skip
- by-month / by-day pivot

---

## 16. 実装ファイル

- **本体**: `SourceVault.wl` (v2026-05-19-stage-9-notebook-management-p0)
- **ClaudeDirective 連携**:
  - `rules/102-wolfram-stdlib-first.md` — Wolfram 標準関数優先原則
  - `skills/notebook-management-extraction/SKILL.md` — Stage 9 P0 設計詳細
  - `skills/wolfram-syntax-pitfalls/SKILL.md` — 罠 #21-#23
- **テスト notebook**: 
  - `20260516-第14回オンライン語り交流会.nb` (Header + 3 Todo cells)
  - `notebook_import.nb` (NotebookImport の動作実証)

---

## 17. v1.0 = Stage 9 P0 完成 — 受け入れ確認

| 項目 | 状況 |
|---|---|
| Public API 7 個 | ✅ 実装完了 |
| Status 3 値判定 (Open/Done/Pass) | ✅ result9.nb で実証 |
| Header parse (Import["Initialization"]) | ✅ result9.nb で実証 |
| Todo 抽出 (NotebookImport) | ✅ result9.nb で実証 |
| 9 種 lint | ✅ 動作確認 |
| FindNotebooks deterministic クエリ | ✅ 実装完了 |
| `rules/102-wolfram-stdlib-first.md` | ✅ ClaudeDirective に追加 |
| 罠 #21-#23 永続記録 | ✅ skill に追加 |
| Memory 反映 | ✅ memory_user_edits に記録 |

---

## 改訂履歴

- **v0** (`sourcevault_notebook_review_todo_deadline.md`): 原レビュー資料、Todo / Done 2 値
- **v1.0** (本書、2026-05-19): Stage 9 P0 実装完成。3 値判定 (Open/Done/Pass)、Wolfram 標準関数優先原則の確立、罠 #21-#23 追加、Import["Initialization"] + NotebookImport ベースの実装
