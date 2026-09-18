# SourceVault_privacy API Reference

パッケージ: `SourceVault`` (BeginPackage["SourceVault`"])
ロード順: SourceVault.wl → **SourceVault_privacy.wl** → NBAccess_crypto.wl → SourceVault_crypto.wl → SourceVault_identity.wl → SourceVault_maildb.wl → …

privacy 伝達の正準層。「入力変数や内部でインポートしたデータの PrivacyLevel 最大値を、確実に出力へ伝える」ための機構・宣言・監査・適合テストをまとめる。依存方向は SourceVault → NBAccess (弱結合)。NBAccess/claudecode 未ロードでも透かしと監査は動き、セルマークだけ no-op になる。

## なぜ要るのか (2026-07-21)

`SourceVaultMailSearchIndexView` を別名 (ユーザー定義シンボル `その他のメール`) から呼ぶと、入力セルだけ赤くなり **出力セルが機密マークされない** 事象が出た。原因は privacy が「値」でなく「セル」に付き、伝達経路が **入力セルのテキスト正規表現** に依存していたこと。旧 3 層はいずれも間接 1 枚で破れていた。

| 旧層 | 破れ方 |
|---|---|
| `ClaudeCode`Confidential[]` | 評価セルは同期マークだが、出力セルは 4.5 秒ポーリング 1 本。落ちると無言で終わる |
| `SourceVaultMarkConfidentialViewCells` | 入力セルのテキストを正規表現照合。別名・変数・Map・ClaudeEval では原理的に一致しない |
| NBAccess 機密生成ヘッド表 | 登録が任意。索引系 (`SourceVaultMailSearchIndex(View)`) が丸ごと未登録だった |

本層は **評価スコープの透かし (watermark)** で伝達する。テキストを一切見ないので、別名でも Map でも必ず伝わる。

## 設計原則

- **P1** 私的データを読む関数は必ず `SourceVaultNotePrivacy` / `SourceVaultNotePrivacyOf` を通る。以降のセルマークは透かし由来。
- **P2** Max 伝搬・非降下・fail-closed。判定不能は `$SourceVaultPrivacyDefaultLevel` (0.85)。レベルは上げるだけで下げない。
- **P3** View 系 (UI オブジェクトを返す) だけ返り値に赤枠 + PL バッジを焼き込む。Core 系 (生データを返す) は値の形を変えない。
- **P4** 遵守は機械チェックする (静的監査 + 動的適合テスト)。
- **P5** 新規 public 関数はレビュー済み一覧に載っていなければ監査 FAIL (fail-closed)。

## 1. 評価スコープ透かし (runtime)

### SourceVaultNotePrivacy[pl] → Real
現在の評価に PrivacyLevel を記録する (Max 伝搬)。FE があり `pl >= $SourceVaultPrivacyMarkThreshold` なら評価セルを同期で機密マークし、出力セルを **CellObject 同一性ベース**の遅延マーカーへ登録する (index 依存なし)。加えて `$SourceVaultPrivacyCellEpilog` が True なら評価セルに `CellEpilog :> SourceVaultMarkEvaluationPrivacyCells[]` を armed し、評価完了直後にも flush する (ScheduledTask が走らない環境の保険)。非数値/引数なしは fail-closed で `$SourceVaultPrivacyDefaultLevel` 扱い。
NBAccess がロードされていれば同じ pl を `NBAccess`NBNoteEvaluationPrivacy` にも渡す (2026-09-18)。LLM が提案したコードは `NBExecuteHeldExpr` 内で評価され、結果を LLM に返すか (スキーマのみにするか) は NBAccess の透かし `EvaluationPrivacy` で決まるため、ここで合流しないと PL の高い View / record がクラウド LLM に渡る。
→ clip 後の pl

### SourceVaultNotePrivacyOf[data] → Real
data (Association / 行リスト / snapshot 群) から PrivacyLevel を収集して最大値を記録する。`"PrivacyLevel"` キー → `"Derived"` → `"PrivacyLevel"` の順に見る。数値が取れない要素は fail-closed で 0.85 扱い。空リストは 0.0。
→ 記録した最大 PL

### SourceVaultEvaluationPrivacy[] → Real
現在の評価スコープの透かしを読み出す。

### SourceVaultResetEvaluationPrivacy[] → 0.
透かしを 0.0 にリセットする (テスト用)。

### SourceVaultWithPrivacyScope[expr]  (HoldFirst) → Association
透かしを Block して expr を評価する。
→ `<|"Value" -> 結果, "Privacy" -> スコープ内の最大 PL|>` 。外側の透かしは Max で更新される。適合テストの計測はこれで行う。

### SourceVaultMarkEvaluationPrivacyCells[nb] / SourceVaultMarkEvaluationPrivacyCells[] → List
透かし由来の未処理マークを流し込む backstop。入力セルのテキストは一切見ない。引数なし形は現在の pending 全体を対象にする。`SourceVaultMarkConfidentialViewCells` の先頭・`NBMakeContextPacket` フック・評価セルの `CellEpilog` (`$SourceVaultPrivacyCellEpilog`) から呼ばれる。
→ マークしたセルの記述リスト

### SourceVaultPendingPrivacyMarks[] → List
未処理の出力セルマーク要求一覧 (診断用)。0 なら遅延マーカーは全部処理済み。

### 遅延マーカーの挙動
評価中は出力セルがまだ存在しないので、`SourceVaultNotePrivacy` は要求を積んで `SessionSubmit[ScheduledTask[..., {0.4}]]` の one-shot を予約し、未処理が残る間だけ自分で次の一発を予約する (タスクが積み上がらない)。加えて評価セルの `CellEpilog` から FE が評価完了直後に一度 flush する (ScheduledTask がセッション状態次第で走らないケースの保険。2026-09-11 実機報告で追加)。

- 鍵は **CellObject**。index ではないのでセル挿入でずれない。
- 評価セルの直後から `Output`/`Print`/`Message` を連続でマークし、**それ以外のスタイルが現れたら打ち切る** (無関係なセルを巻き込まない)。
- PL は**上げるだけ**。既存 PL 以上なら何もしない (旧 `ClaudeCode`Confidential` の遅延マークが先に勝った場合も二重マークしない)。
- 出力セルが現れないまま `$svPPendingTTL` (20 秒) 経過した要求は破棄する (末尾 `;` の抑制評価で無限ポーリングしないため)。
- パレット型ノートブック (`WindowFrame -> "Palette"`) はマーク対象から除外する。パレットのボタン経由で機密 View を開くと `EvaluationNotebook[]` がパレット自身に解決され、パレット全体が赤背景になる不具合 (2026-09-01 実機報告) の回避。機密表示自体は `SourceVaultPrivate` の赤枠バッジが必ず伴うので、セルマークだけ抑止しても機密性は失われない。

### 変数
- `$SourceVaultPrivacyMarkThreshold` = 0.5 (これ以上でセルマーク)
- `$SourceVaultPrivacyDefaultLevel` = 0.85 (fail-closed 既定)
- `$SourceVaultPrivacyViewBadge` = True (False でバッジのみ無効化。透かしは常に有効)
- `$SourceVaultPrivacyCellEpilog` = True (評価セルの `CellEpilog` から評価完了直後に flush する保険機構を有効化。同一セルへの `SetOptions` は 1 回だけ)

## 2. 正準 exit

### SourceVaultPrivateResult[expr, pl] / SourceVaultPrivateResult[expr] → 任意
**Core 系** (生データを返す関数) の正準 exit。pl を記録しセルをマークして expr をそのまま返す。値の形は変えない。pl 省略時は `$SourceVaultPrivacyDefaultLevel`。

### SourceVaultPrivateView[expr, pl] / SourceVaultPrivateView[expr] → 任意 | SourceVaultPrivate[...]
**View 系** (UI オブジェクトを返す関数) の正準 exit。pl >= 閾値なら `SourceVaultPrivate[expr, pl]` で包む (冪等。既に `SourceVaultPrivate` でラップ済みならそのまま)。pl 省略時は `$SourceVaultPrivacyDefaultLevel`。`$SourceVaultPrivacyViewBadge -> False` ならバッジなしで expr をそのまま返す (透かしは記録される)。
⚠️ **Core 系に使わないこと。** `Dataset[SourceVaultMailSearchSummary[...]]` のような下流が壊れる (実際に一度壊した)。

### SourceVaultPrivate[expr, pl]
privacy ラベル付き表示ラッパ。`Format` 定義で赤枠 + 「機密 / Confidential PrivacyLevel x.xx」バッジとして表示されるが、**値の構造は `SourceVaultPrivate[payload, pl]` のまま残る**ので決定的に剥がせる。セルマークが race で落ちても機密であることが必ず視認できる二重防御。

### SourceVaultPrivacyUnwrap[x] → 任意
ラッパを剥がして中身を返す (ラッパでなければそのまま)。View の構造を検査するテスト・下流コードは必ずこれを通すこと。

### SourceVaultPrivacyLevelOf[x] → Real | Missing
ラッパの PL を返す (無ければ `Missing["NoPrivacyLabel"]`)。

## 3. 宣言レジストリ

### SourceVaultDeclarePrivacySource[name, spec] → Association
私的データの**一次ストア (読み出し口)** を宣言する。
spec: `<|"Level" -> 0.85, "Readers" -> {"シンボル名"...}, "Description" -> _|>`
既定で `mail` / `notebook` / `eagle` / `oops` / `llmlog` の 5 つを宣言済み。派生関数は呼び出しグラフで自動的に到達判定されるので、増えても書き足す必要はない。

### SourceVaultRegisterPrivacyContract[symbolName, spec] / SourceVaultRegisterPrivacyContract[symbolName, class] → Association | Failure
関数の privacy 契約を登録する。第 2 引数を文字列 (Class 名) で渡す簡易形は `<|"Class" -> class|>` と同義。
spec: `<|"Class" -> "Private"|"Public"|"Internal", "Exit" -> "View"|"Result"|"Head"|"None", "Level" -> Automatic|数値, "Sources" -> {...}, "NoDataFlow" -> 理由, "Module" -> _, "Note" -> _|>`
Class が不正 (Private/Public/Internal 以外) なら `Failure["InvalidPrivacyClass", ...]` を返す。Exit 省略時は Class Private なら "Result"、それ以外は "None"。

- `"Private"` … 私的データが出力に載る。正準 exit を通す義務がある。
- `"Public"` / `"Internal"` … 載らない。私的ストアへ到達する場合は **`"NoDataFlow"` に理由が必須** (理由なしは監査 FAIL = fail-closed)。

登録は自モジュール内で行うこと。手本: `SourceVault_maildb.wl` の `iSVMDRegisterPrivacyContracts`。まだ自前登録を持たないモジュール分は `SourceVault_privacy.wl` §7b の横断表にある。

### SourceVaultPrivacyContract[sym] → Association | Missing
登録済み privacy 契約を返す。無ければ `Missing["NoPrivacyContract", sym]`。

### SourceVaultPrivacyContracts[] → Association
登録済み privacy 契約表 (symbolName -> 契約) 全体。

### SourceVaultPrivacySources[] → Association
宣言済みの私的ストア表全体。

### SourceVaultDeclareModulePrivacy[file, spec] → Association
モジュール単位の既定を宣言する。spec: `<|"DefaultClass" -> "Internal", "Sources" -> {...}, "Note" -> _|>`。個別契約が無い symbol はこの既定が適用される。

### SourceVaultModulePrivacyDeclarations[] → Association
モジュール宣言表全体。

## 4. 監査

### SourceVaultPrivacyAudit[opts]
privacy 形式の遵守を検査する。
→ `<|"Status" -> "OK"|"Failed", "Mode", "UndeclaredLeak", "Unreviewed", "MissingExit", "Counts"|>`
Options: "Mode" -> "Runtime" (ロード済み SourceVault シンボルの呼び出しグラフを `DownValues/SubValues/OwnValues` から作り、私的ストアに到達する public 関数が `Class -> "Private"` を宣言しているかを検査する。未宣言は `"UndeclaredLeak"` reason `"Undeclared"`。Public/Internal 宣言済みで `"NoDataFlow"` 理由が無い場合は reason `"DeclaredAs<Class>WithoutNoDataFlowReason"`), "Mode" -> "Source" (.wl の `::usage` を数え、レビュー済み一覧に無い public シンボルを `"Unreviewed"` として報告する。headless / コミットゲート用), "Files" -> Automatic (Source モードのみ使用、パス明示リストも可), "Directory" -> Automatic, "MaxDepth" -> 8 (Runtime モードの BFS 深さ上限)

### SourceVaultPrivacyCallGraph[] → Association
SourceVault` 系シンボルの参照グラフ (完全名 -> 参照シンボル完全名リスト) を作る。
⚠️ 罠: `SourceVault`` が `$ContextPath` に載っていると `Names["SourceVault`*"]` は**短縮名**を返す。グラフの節点は必ず完全名へ正規化すること (しないと BFS が 1 歩も進まず監査が常に OK になる)。

### SourceVaultPrivacyReachesSource[symbolName] → Association
1 関数がどの私的ストアに到達するかを返す。
→ `<|"Symbol" -> symbolName, "Sources" -> {到達したストア名...}|>`

### SourceVaultPrivacyReviewedSymbols[] → Association
レビュー済み public シンボル一覧 (`SourceVault_info/privacy/privacy_reviewed.m`, `<|file -> {name..}|>`) の読み出し。ファイル未存在時は `<||>`。

### SourceVaultPrivacyWriteReview[opts]
現在のソースの public シンボル一覧をレビュー済みファイルへ書き出す。**新規シンボルを privacy 宣言したうえで**実行すること。
→ `<|"Status" -> "Written", "Path", "Files", "Symbols"|>` (書き込み失敗時は `Failure["PrivacyReviewWriteFailed", ...]`)
Options: "Directory" -> Automatic (ソースディレクトリ自動検出), "Path" -> Automatic (既定 `SourceVault_info/privacy/privacy_reviewed.m`)

## 5. 動的適合テスト

### SourceVaultRegisterPrivacyProbe[symbolName, probe] → Association
probe: `<|"Setup" -> Function[level, _], "Call" -> Function[setupResult, _], "Teardown" -> _ (省略可), "Levels" -> {0.0, 1.0} (省略可)|>`
Setup は「PL = level の合成データを見えるようにする」責務、Call は対象関数を呼ぶ責務。probe はパッケージではなく `test codes/SourceVault_privacy_conformance_test.wls` に置く。

### SourceVaultPrivacyProbes[] → Association
登録済み probe 表全体 (symbolName -> probe)。

### SourceVaultPrivacyConformanceTest[symbolName] → Association
登録 probe を使って PL 伝達を実測する。FE 不要 (透かしを観測する)。probe 未登録なら `"Status" -> "Skipped"`。
- 高 PL 入力 (>= 閾値) → 観測 PL >= 入力 PL であること (**伝達**)
- 低 PL 入力 (< 閾値) → 観測 PL < 閾値であること (**過剰マーク防止**)
→ `<|"Status" -> "Pass"|"Fail"|"Skipped", "Symbol", "Cases"|>`

### SourceVaultPrivacyConformanceTest[All] → Association
登録済み全 probe を実行する。
→ `<|"Status" -> "Pass"|"Fail", "Results" -> {各 symbol の結果...}, "Counts" -> <|"Total", "Pass", "Fail", "Skipped"|>|>`

## 6. コミットゲート (新関数の必須手順)

```
wolframscript -file "test codes/SourceVault_privacy_gate.wls"
wolframscript -file "test codes/SourceVault_privacy_test.wls"
wolframscript -file "test codes/SourceVault_privacy_conformance_test.wls"
```

新しい public 関数を足すと gate が `Unreviewed` で落ちる。手順:

1. 自モジュールの登録関数に `SourceVaultRegisterPrivacyContract` を足して Class を宣言。
2. `"Private"` なら実装を正準 exit に通し、probe を conformance test に追加。
   `"Public"`/`"Internal"` で私的ストアに到達するなら `"NoDataFlow" -> 理由` を書く。
3. `SourceVaultPrivacyWriteReview[]` でレビュー済み一覧を更新。
4. gate 再実行で PASS を確認。

## 初回監査 (2026-07-21) の結果

`SourceVaultPrivacyAudit["Mode" -> "Runtime"]` が、私的ストアに到達するのに未宣言だった public 関数を **41 件** 検出した。分類の内訳:

- **Private / View** (6): RoutineAgendaView, RoutineGanttView, RoutineLoadView, MailThreadPanel, MailRowActions, MailSessionSuggestView
- **Private / Result** (9): RoutineAgendaData, MailAgendaItems, MailForNotebook, FindTodos, ExtractAllMail, MailToGenericRecord, MailRecordsForStructuring, RunPrimaryRoute, ExecutePromptRoute
- **Private / Head** (7): MailAgendaOpen, MailThreadWindow, MailReplyDraft, MailOpenReplyNotebook, MailOpenAttachment, MCPCallTool, MCPDispatch
- **Internal + NoDataFlow** (19): 取込み/派生生成パイプライン (件数と状態だけ返す)、機密マーク機構自身、ルーティング提案層

同時に、索引 sidecar 経路 (`SourceVaultMailSearchIndex` / `SourceVaultMailSearchIndexView` / `MailIndexGet` / `MailThreadNotebook` / `MailShowBody`) が機密ヘッド表から丸ごと抜けていたのを追加した。

## 2026-09-01 の追補監査

Source モード監査で `mailbrowse` / `crosslink` / `oopsseed` の public 関数群 (§7b) が、それぞれ mail/oops ストアおよび provider 経由のサマリーに到達するのに契約未登録だったため追加。同時に `eagle`/`llmlog` ストアの `Readers` に実在しないシンボル名 (幽霊名) が登録されており、runtime 監査がこれら 2 ストアへの到達を検出できていなかったのを実名へ修正した結果、新たに 69 件 + `SourceVaultEagleIngestInfo` の到達が判明し分類・登録した (§7b 末尾)。自前登録へ移行した関数は §7b から削除してよい。

## 2026-09-11 の実機報告 (flush backstop)

出力セルが赤くならない (入力セルだけ赤い) 実機報告があり、原因は2つ判明した。(1) `iPRegisterPending` の未登録判定が誤って `{0}` (= `{_Integer}` に一致) を既定値にしており、初回登録が失敗して要求が一度も積まれないケースがあった。(2) `SessionSubmit[ScheduledTask[...]]` による遅延 flush が FE/セッション状態次第で走らないことがあった。前者は判定ロジック修正、後者は `$SourceVaultPrivacyCellEpilog` (既定 True) による評価セル `CellEpilog` 経由の確実な flush を追加して対処した。

## 2026-09-18 の追補 (NBAccess 評価スコープ透かしへの合流)

`SourceVaultNotePrivacy` は自分のスコープを更新した直後に、NBAccess がロードされていれば `NBAccess`NBNoteEvaluationPrivacy[lv]` へ同じ PL を橋渡しする (`NBAccess`DownValues` の存在チェックで未ロード時は no-op)。動機: `NBExecuteHeldExpr` 内で LLM 提案コードが評価された際、結果を LLM (クラウド含む) にそのまま返すかスキーマのみに丸めるかは NBAccess 側の透かし `"EvaluationPrivacy"` だけで決まる。SourceVault 側の読み取りがここに合流しないと、PL 0.85 の View / record が `ToString` のまま LLM に渡ってしまう。NBAccess は SourceVault 非依存の設計を保つため、合流はデータ層である SourceVault_privacy 側から一方向に押し込む。