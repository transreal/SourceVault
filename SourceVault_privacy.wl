(* ::Package:: *)

(* ============================================================
   SourceVault_privacy.wl -- privacy 伝達の正準層 (watermark / 宣言 / 監査 / 適合テスト)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_privacy.wl"]]

   背景 (2026-07-21):
     SourceVaultMailSearchIndexView の出力セルが機密マークされない事象の調査で、
     privacy が「値」ではなく「セル」に付き、伝達経路が「入力セルのテキスト正規表現」に
     依存していることが判明した。別名 (例: ユーザー定義の `その他のメール`)・変数・Map・
     ClaudeEval など間接が一枚挟まると必ず落ちる。

     旧来の 3 層:
       (1) ClaudeCode`Confidential[] -> 評価セルは同期マーク、出力セルは 4.5 秒
           ポーリング 1 本 (落ちると無言で終わる)
       (2) SourceVaultMarkConfidentialViewCells -> 入力セルのテキスト正規表現
           (別名では原理的に一致しない)
       (3) NBAccess の機密生成ヘッド表 -> 登録は maildb の 13 個 + Cerezo 1 個のみ

   本モジュールの方針:
     P1 伝達はテキストではなく「評価スコープの透かし (watermark)」で行う。
        私的データを読む関数は必ず SourceVaultNotePrivacy を通る。以降の
        セルマークは透かし由来なので、別名・変数・Map を挟んでも必ず伝わる。
     P2 Max 伝搬・fail-closed。判定不能は $SourceVaultPrivacyDefaultLevel (0.85)。
        レベルは上げるだけで、下げない (non-decreasing)。
     P3 View 系 (UI オブジェクトを返す関数) は返り値自体に赤枠 + PL バッジを焼き込む。
        セルマークが race で落ちても視認できる二重防御。Core 系 (生データを返す
        関数) は値を変えず透かしのみ (下流計算を壊さない)。
     P4 「形式を守っているか」は機械チェックする:
          - 静的: 呼び出しグラフで私的ストアに到達する public 関数が
            privacy 宣言 Class->"Private" を持つか (SourceVaultPrivacyAudit)
          - 動的: 合成データの PL を入れて出力側の観測 PL >= 入力 PL か
            (SourceVaultPrivacyConformanceTest)
     P5 新規 public 関数は必ずレビュー済み一覧に載っていなければならない
        (fail-closed)。載っていなければ監査 FAIL -> コミット拒否。

   依存方向: SourceVault -> NBAccess (弱結合)。NBAccess/claudecode 未ロードでも
   透かしと監査は動く (セルマークだけ no-op になる)。

   非衝突方針: private helper は SourceVault`PrivacyPrivate` 文脈。
   ============================================================ *)

BeginPackage["SourceVault`"]

(* ---- 1. 評価スコープ透かし (runtime) ---- *)
SourceVaultNotePrivacy::usage =
  "SourceVaultNotePrivacy[pl] は現在の評価に PrivacyLevel pl を記録する (Max 伝搬)。\n" <>
  "私的データを読む関数は必ずこれを通ること。戻り値は clip 後の pl。\n" <>
  "FE があり pl >= $SourceVaultPrivacyMarkThreshold なら、評価セルを即座に機密マークし、\n" <>
  "出力セルは CellObject 同一性ベースの遅延マーカーに登録する (index 依存なし)。";

SourceVaultNotePrivacyOf::usage =
  "SourceVaultNotePrivacyOf[data] は data (Association / リスト / snapshot 群) から\n" <>
  "PrivacyLevel を収集して最大値を SourceVaultNotePrivacy へ渡す。\n" <>
  "\"PrivacyLevel\" キー、\"Derived\" -> \"PrivacyLevel\"、URI envelope の PrivacyLevel を見る。\n" <>
  "1 件でも数値が取れない要素があれば fail-closed で $SourceVaultPrivacyDefaultLevel 扱い。\n" <>
  "空リストは 0.0 (何も読んでいない)。戻り値は記録した最大 PL。";

SourceVaultEvaluationPrivacy::usage =
  "SourceVaultEvaluationPrivacy[] は現在の評価スコープで記録された PrivacyLevel の最大値を返す。";

SourceVaultResetEvaluationPrivacy::usage =
  "SourceVaultResetEvaluationPrivacy[] は評価スコープの透かしを 0.0 に戻す (テスト用)。";

SourceVaultWithPrivacyScope::usage =
  "SourceVaultWithPrivacyScope[expr] は透かしを Block して expr を評価し、\n" <>
  "<|\"Value\" -> 結果, \"Privacy\" -> スコープ内の最大 PL|> を返す (HoldFirst)。\n" <>
  "適合テストと入れ子呼び出しの計測に使う。外側の透かしは Max で更新される。";

SourceVaultPrivateResult::usage =
  "SourceVaultPrivateResult[expr, pl] は Core 系 (生データを返す関数) の正準 exit。\n" <>
  "pl を記録しセルをマークしたうえで expr をそのまま返す (値の形は変えない)。";

SourceVaultPrivateView::usage =
  "SourceVaultPrivateView[expr, pl] は View 系 (UI オブジェクトを返す関数) の正準 exit。\n" <>
  "pl を記録しセルをマークし、pl >= 閾値なら SourceVaultPrivate[expr, pl] で包んで返す\n" <>
  "(赤枠 + PL バッジ表示)。データを返す Core 系には使わないこと (返り値の形が変わるため。\n" <>
  "Core 系は SourceVaultPrivateResult)。\n" <>
  "$SourceVaultPrivacyViewBadge = False でバッジのみ無効化できる (透かしは常に有効)。";

SourceVaultPrivate::usage =
  "SourceVaultPrivate[expr, pl] は privacy ラベル付きの表示ラッパ。値の隣に PL を持ち、\n" <>
  "赤枠 + \"機密 / Confidential PrivacyLevel x.xx\" バッジとして表示される。\n" <>
  "中身は SourceVaultPrivacyUnwrap で取り出せる。セルマークが race で落ちても\n" <>
  "機密であることが必ず視認できる二重防御。";

SourceVaultPrivacyUnwrap::usage =
  "SourceVaultPrivacyUnwrap[x] は SourceVaultPrivate ラッパを剥がして中身を返す\n" <>
  "(ラッパでなければそのまま返す)。構造を検査するテスト/下流コード用。";

SourceVaultPrivacyLevelOf::usage =
  "SourceVaultPrivacyLevelOf[x] は SourceVaultPrivate ラッパの PL を返す (無ければ Missing)。";

SourceVaultMarkEvaluationPrivacyCells::usage =
  "SourceVaultMarkEvaluationPrivacyCells[nb] は透かし由来の未処理マークを流し込む backstop。\n" <>
  "入力セルのテキストは一切見ない。NBMakeContextPacket フック等から呼ぶ。\n" <>
  "戻り値はマークしたセルの記述リスト。";

SourceVaultPendingPrivacyMarks::usage =
  "SourceVaultPendingPrivacyMarks[] は未処理の出力セルマーク要求一覧を返す (診断用)。";

$SourceVaultPrivacyMarkThreshold::usage =
  "$SourceVaultPrivacyMarkThreshold はセル機密マークの閾値 (既定 0.5、以上でマーク)。";

$SourceVaultPrivacyDefaultLevel::usage =
  "$SourceVaultPrivacyDefaultLevel は PL 判定不能時の fail-closed 既定値 (0.85)。";

$SourceVaultPrivacyViewBadge::usage =
  "$SourceVaultPrivacyViewBadge が True (既定) のとき View 系の返り値に赤枠 + PL バッジを焼き込む。";

(* ---- 2. 宣言レジストリ ---- *)
SourceVaultDeclarePrivacySource::usage =
  "SourceVaultDeclarePrivacySource[name, spec] は私的データの一次ストア (読み出し口) を宣言する。\n" <>
  "spec: <|\"Level\" -> 0.85, \"Readers\" -> {\"シンボル名\"...}, \"Description\" -> _|>。\n" <>
  "Readers に挙げた関数へ (呼び出しグラフ上で) 到達する public 関数は\n" <>
  "Class -> \"Private\" の privacy 契約を持たねばならない (SourceVaultPrivacyAudit)。";

SourceVaultPrivacySources::usage =
  "SourceVaultPrivacySources[] は宣言済みの私的ストア表を返す。";

SourceVaultRegisterPrivacyContract::usage =
  "SourceVaultRegisterPrivacyContract[symbolName, spec] は関数の privacy 契約を登録する。\n" <>
  "spec: <|\"Class\" -> \"Private\"|\"Public\"|\"Internal\",\n" <>
  "        \"Level\" -> Automatic|数値 (Private の宣言上限。Automatic はデータ由来),\n" <>
  "        \"Exit\" -> \"View\"|\"Result\"|\"Head\"|\"None\",\n" <>
  "        \"Sources\" -> {私的ストア名...}, \"Note\" -> _|>。\n" <>
  "Class の意味: Private = 私的データを出力に載せる / Public = 載せない (公開値のみ) /\n" <>
  "Internal = 非 user-facing の内部関数。";

SourceVaultPrivacyContract::usage =
  "SourceVaultPrivacyContract[symbolName] は登録済み privacy 契約を返す。無ければ Missing。";

SourceVaultPrivacyContracts::usage =
  "SourceVaultPrivacyContracts[] は登録済み privacy 契約表を返す。";

SourceVaultDeclareModulePrivacy::usage =
  "SourceVaultDeclareModulePrivacy[file, spec] はモジュール単位の既定を宣言する。\n" <>
  "spec: <|\"DefaultClass\" -> \"Internal\", \"Sources\" -> {...}, \"Note\" -> _|>。\n" <>
  "個別契約が無い symbol はこの既定が適用される。";

SourceVaultModulePrivacyDeclarations::usage =
  "SourceVaultModulePrivacyDeclarations[] はモジュール宣言表を返す。";

(* ---- 3. 監査 ---- *)
SourceVaultPrivacyAudit::usage =
  "SourceVaultPrivacyAudit[opts] は privacy 形式の遵守を検査する。\n" <>
  "\"Mode\" -> \"Runtime\" (既定): ロード済み SourceVault シンボルの呼び出しグラフを作り、\n" <>
  "  私的ストアに到達する public 関数が Class->\"Private\" を宣言しているかを検査する\n" <>
  "  (未宣言 = \"UndeclaredLeak\")。\n" <>
  "\"Mode\" -> \"Source\": .wl ソースの ::usage を数えて、レビュー済み一覧に無い\n" <>
  "  新規 public シンボルを \"Unreviewed\" として報告する (headless / コミットゲート用)。\n" <>
  "\"Files\" -> Automatic | {パス...}、\"Directory\" -> Automatic。\n" <>
  "戻り値 <|\"Status\" -> \"OK\"|\"Failed\", \"Mode\", \"UndeclaredLeak\", \"Unreviewed\",\n" <>
  "        \"MissingExit\", \"Counts\"|>。";

SourceVaultPrivacyCallGraph::usage =
  "SourceVaultPrivacyCallGraph[] は SourceVault` 系シンボルの参照グラフ\n" <>
  "<|シンボル名 -> {参照しているシンボル名...}|> を DownValues/SubValues/OwnValues から作る。";

SourceVaultPrivacyReachesSource::usage =
  "SourceVaultPrivacyReachesSource[symbolName] は symbolName が呼び出しグラフ上で\n" <>
  "どの私的ストアに到達するかを返す (到達経路つき)。";

SourceVaultPrivacyReviewedSymbols::usage =
  "SourceVaultPrivacyReviewedSymbols[] はレビュー済み public シンボル一覧 (<|file -> {name..}|>) を返す。";

SourceVaultPrivacyWriteReview::usage =
  "SourceVaultPrivacyWriteReview[opts] は現在のソースの public シンボル一覧を\n" <>
  "レビュー済みファイルへ書き出す。新規シンボルを privacy 宣言したうえで実行すること。\n" <>
  "\"Directory\" -> Automatic、\"Path\" -> Automatic。";

(* ---- 4. 適合テスト ---- *)
SourceVaultRegisterPrivacyProbe::usage =
  "SourceVaultRegisterPrivacyProbe[symbolName, probe] は動的適合テスト用の probe を登録する。\n" <>
  "probe: <|\"Setup\" -> Function[level, _], \"Call\" -> Function[setupResult, _],\n" <>
  "         \"Teardown\" -> Function[setupResult, _] (省略可),\n" <>
  "         \"Levels\" -> {0.0, 1.0} (省略可)|>。\n" <>
  "Setup は「PL = level の合成データを見えるようにする」責務、Call は対象関数を呼ぶ責務。";

SourceVaultPrivacyProbes::usage =
  "SourceVaultPrivacyProbes[] は登録済み probe 表を返す。";

SourceVaultPrivacyConformanceTest::usage =
  "SourceVaultPrivacyConformanceTest[symbolName] は登録 probe を使って\n" <>
  "「入力/インポートデータの最大 PL が出力に伝わるか」を実測する。\n" <>
  "高 PL (>= 閾値) の入力では観測 PL >= 入力 PL であること、\n" <>
  "低 PL (< 閾値) の入力では観測 PL < 閾値であること (過剰マーク防止) を検査する。\n" <>
  "SourceVaultPrivacyConformanceTest[All] は登録済み全 probe を実行する。\n" <>
  "戻り値 <|\"Status\", \"Symbol\", \"Cases\" -> {...}|>。";

Begin["`PrivacyPrivate`"]

(* ============================================================
   0. 定数・低レベルユーティリティ
   ============================================================ *)

If[! NumberQ[SourceVault`$SourceVaultPrivacyMarkThreshold],
  SourceVault`$SourceVaultPrivacyMarkThreshold = 0.5];
If[! NumberQ[SourceVault`$SourceVaultPrivacyDefaultLevel],
  SourceVault`$SourceVaultPrivacyDefaultLevel = 0.85];
If[! BooleanQ[SourceVault`$SourceVaultPrivacyViewBadge],
  SourceVault`$SourceVaultPrivacyViewBadge = True];

(* 罠: iPClip[x_] の後に iPClip[_] を書くと同一パターンとみなされ定義が置き換わる
   (常に既定値 0.85 を返すようになる)。非数値の fail-closed は 1 定義の中で処理する。 *)
iPClip[x_] :=
  If[NumericQ[x], N[Clip[x, {0., 1.}]], SourceVault`$SourceVaultPrivacyDefaultLevel];

iPThreshold[] := N[SourceVault`$SourceVaultPrivacyMarkThreshold];

(* FE 有無。headless では常に False (透かしと監査だけが動く)。 *)
iPFrontEndQ[] := TrueQ[$Notebooks] && ($FrontEnd =!= Null);

iPEvalNotebook[] :=
  If[iPFrontEndQ[], Quiet @ Check[EvaluationNotebook[], $Failed], $Failed];
iPEvalCell[] :=
  If[iPFrontEndQ[], Quiet @ Check[EvaluationCell[], $Failed], $Failed];

(* ============================================================
   1. 評価スコープ透かし
   ------------------------------------------------------------
   $svPMax は「今の評価セル」に紐づく累積最大値。CellProlog に依存せず、
   評価セル (CellObject) が変わったら遅延リセットする。headless では
   $svPScopeKey が Null のまま単調累積するので、テストは
   SourceVaultWithPrivacyScope / ResetEvaluationPrivacy で明示的に区切る。
   ============================================================ *)

If[! NumberQ[$svPMax], $svPMax = 0.];
If[! ValueQ[$svPScopeKey], $svPScopeKey = Null];

(* 現在の評価スコープ鍵: FE があれば評価セル、無ければ $Line (セル相当) *)
iPScopeKey[] :=
  With[{c = iPEvalCell[]},
    If[MatchQ[c, _CellObject], c, Null]];

iPSyncScope[] :=
  Module[{k = iPScopeKey[]},
    If[k =!= Null && k =!= $svPScopeKey,
      $svPScopeKey = k; $svPMax = 0.];
    k];

SourceVault`SourceVaultEvaluationPrivacy[] := N[$svPMax];

SourceVault`SourceVaultResetEvaluationPrivacy[] := ($svPMax = 0.; $svPScopeKey = Null; 0.);

SetAttributes[SourceVault`SourceVaultWithPrivacyScope, HoldFirst];
SourceVault`SourceVaultWithPrivacyScope[expr_] :=
  Module[{val, inner},
    inner = Block[{$svPMax = 0., $svPScopeKey = $svPScopeKey},
      val = expr;
      N[$svPMax]];
    (* 外側スコープへは Max で伝搬 (P2: 非降下) *)
    $svPMax = Max[N[$svPMax], inner];
    <|"Value" -> val, "Privacy" -> inner|>];

SourceVault`SourceVaultNotePrivacy[pl_] :=
  Module[{lv = iPClip[pl], cell, nb},
    iPSyncScope[];
    $svPMax = Max[N[$svPMax], lv];
    If[lv >= iPThreshold[],
      cell = iPEvalCell[]; nb = iPEvalNotebook[];
      If[MatchQ[cell, _CellObject] && MatchQ[nb, _NotebookObject],
        (* 入力セルは同期でマーク (確実に効く) *)
        Quiet @ Check[iPMarkCellObject[nb, cell, lv], Null];
        (* 出力セルは CellObject 同一性ベースの遅延マーカーへ登録 *)
        Quiet @ Check[iPRegisterPending[nb, cell, lv], Null];
        Quiet @ Check[iPScheduleFlush[], Null]]];
    lv];
SourceVault`SourceVaultNotePrivacy[___] :=
  SourceVault`SourceVaultNotePrivacy[SourceVault`$SourceVaultPrivacyDefaultLevel];

(* ---- データから PL を収集 (fail-closed) ---- *)

(* 1 要素の PL: 明示キー -> Derived -> URI envelope の順。数値が無ければ既定 (0.85)。 *)
iPLevelOfElement[x_] :=
  Which[
    NumericQ[x], iPClip[x],
    AssociationQ[x],
      Module[{p},
        p = Lookup[x, "PrivacyLevel", Missing[]];
        If[! NumericQ[p],
          p = Lookup[Replace[Lookup[x, "Derived", <||>],
                Except[_Association] -> <||>], "PrivacyLevel", Missing[]]];
        If[NumericQ[p], iPClip[p], SourceVault`$SourceVaultPrivacyDefaultLevel]],
    True, SourceVault`$SourceVaultPrivacyDefaultLevel];

iPMaxLevelOf[data_] :=
  Which[
    data === {} || data === <||>, 0.,
    ListQ[data], If[data === {}, 0., Max[iPLevelOfElement /@ data]],
    AssociationQ[data] && KeyExistsQ[data, "PrivacyLevel"], iPLevelOfElement[data],
    AssociationQ[data] && KeyExistsQ[data, "Derived"], iPLevelOfElement[data],
    AssociationQ[data], If[Length[data] === 0, 0., Max[iPLevelOfElement /@ Values[data]]],
    True, SourceVault`$SourceVaultPrivacyDefaultLevel];

SourceVault`SourceVaultNotePrivacyOf[data_] :=
  SourceVault`SourceVaultNotePrivacy[iPMaxLevelOf[data]];

(* ============================================================
   2. セルマーク (CellObject 同一性ベース)
   ------------------------------------------------------------
   旧 iDeferOutputMark は「入力セル index + 1」を 4.5 秒ポーリングしていた。
   index はセル挿入で簡単にずれ、1 本落ちると無言で終わる。ここでは
   - CellObject を鍵にして index ずれの影響を受けない
   - 入力セルに続く Output/Print/Message を「次の入力セルまで」全部マークする
   - 監視窓を広げ、backstop (NBMakeContextPacket フック) からも flush できる
   - PL は上げるだけ (non-decreasing)
   ============================================================ *)

If[! ListQ[$svPPending], $svPPending = {}];
If[! BooleanQ[$svPFlushScheduled], $svPFlushScheduled = False];

(* CellObject -> Cells[nb] 上の index。見つからなければ 0。 *)
iPCellIndex[nb_NotebookObject, cell_CellObject] :=
  Module[{cells = Quiet @ Check[Cells[nb], $Failed], pos},
    If[! ListQ[cells], Return[0]];
    pos = FirstPosition[cells, cell, {0}, {1}];
    If[MatchQ[pos, {_Integer}], First[pos], 0]];
iPCellIndex[___] := 0;

(* セルの現在 PL (タグ由来)。取れなければ 0。 *)
iPCellCurrentLevel[nb_NotebookObject, idx_Integer] :=
  If[Length[DownValues[NBAccess`NBCellPrivacyLevel]] === 0, 0.,
    With[{v = Quiet @ Check[NBAccess`NBCellPrivacyLevel[nb, idx], 0.]},
      If[NumericQ[v], N[v], 0.]]];
iPCellCurrentLevel[___] := 0.;

(* 単一セルを PL でマーク。既存 PL 以下なら何もしない (非降下)。 *)
iPMarkCellIndex[nb_NotebookObject, idx_Integer, lv_?NumericQ] :=
  Module[{cur},
    If[idx < 1, Return[False]];
    If[Length[DownValues[NBAccess`NBMarkCellConfidential]] === 0, Return[False]];
    cur = iPCellCurrentLevel[nb, idx];
    If[cur >= lv, Return[False]];
    Quiet @ Check[NBAccess`NBMarkCellConfidential[nb, idx, lv], Null];
    True];
iPMarkCellIndex[___] := False;

iPMarkCellObject[nb_NotebookObject, cell_CellObject, lv_?NumericQ] :=
  Module[{idx},
    Quiet @ Check[NBAccess`NBInvalidateCellsCache[nb], Null];
    idx = iPCellIndex[nb, cell];
    iPMarkCellIndex[nb, idx, lv]];
iPMarkCellObject[___] := False;

iPRegisterPending[nb_NotebookObject, cell_CellObject, lv_?NumericQ] :=
  Module[{hit},
    hit = FirstPosition[$svPPending, e_Association /; Lookup[e, "Cell", Null] === cell,
      {0}, {1}];
    If[MatchQ[hit, {_Integer}],
      With[{i = First[hit]},
        $svPPending[[i, "Level"]] = Max[$svPPending[[i, "Level"]], lv]],
      AppendTo[$svPPending,
        <|"Notebook" -> nb, "Cell" -> cell, "Level" -> lv,
          "At" -> AbsoluteTime[], "Marked" -> 0|>]];
    Length[$svPPending]];
iPRegisterPending[___] := 0;

SourceVault`SourceVaultPendingPrivacyMarks[] := $svPPending;

(* 入力セルに属する出力セル群 (次の Input/Code/ClaudeInput セルの手前まで) をマークする。
   マークできた出力セル数を返す。 *)
iPFlushEntry[entry_Association] :=
  Module[{nb, cell, lv, idx, n, marked = 0, style},
    nb = Lookup[entry, "Notebook", Null];
    cell = Lookup[entry, "Cell", Null];
    lv = Lookup[entry, "Level", SourceVault`$SourceVaultPrivacyDefaultLevel];
    If[! MatchQ[nb, _NotebookObject] || ! MatchQ[cell, _CellObject], Return[0]];
    Quiet @ Check[NBAccess`NBInvalidateCellsCache[nb], Null];
    idx = iPCellIndex[nb, cell];
    If[idx < 1, Return[0]];
    (* 入力セル自身も念のため (同期マークが落ちていた場合の保険) *)
    iPMarkCellIndex[nb, idx, lv];
    n = Quiet @ Check[NBAccess`NBCellCount[nb], 0];
    If[! IntegerQ[n], Return[0]];
    (* 評価セルの出力は必ず直後に連続する。Output/Print/Message 以外が現れたら
       そこで打ち切る (無関係なセルを巻き込んで機密化しないため)。 *)
    Do[
      style = Quiet @ Check[NBAccess`NBCellStyle[nb, i], ""];
      If[MemberQ[{"Output", "Print", "Message", "MSG"}, style],
        If[iPMarkCellIndex[nb, i, lv], marked++],
        Break[]],
      {i, idx + 1, n}];
    marked];
iPFlushEntry[_] := 0;

(* 出力セルを待つ上限秒数。出力は通常 1 秒以内に現れる。抑制評価 (末尾 ;) では
   永遠に現れないので、この秒数で諦めて破棄する (無限ポーリング防止)。 *)
If[! NumberQ[$svPPendingTTL], $svPPendingTTL = 20.];

(* 未処理要求を流す。期限切れの要求は破棄する。 *)
iPFlushPending[] :=
  Module[{now = AbsoluteTime[], results = {}, keep = {}},
    If[$svPPending === {}, Return[{}]];
    Scan[
      Function[e,
        Module[{m = Quiet @ Check[iPFlushEntry[e], 0]},
          If[IntegerQ[m] && m > 0,
            AppendTo[results,
              <|"Cell" -> Lookup[e, "Cell", Null], "Level" -> Lookup[e, "Level", 0.],
                "MarkedOutputs" -> m|>]];
          (* 出力セルがまだ無い / 途中なら監視を続ける。期限切れは破棄 *)
          If[(IntegerQ[m] && m === 0) && (now - Lookup[e, "At", now] < $svPPendingTTL),
            AppendTo[keep, e]]]],
      $svPPending];
    $svPPending = keep;
    results];

(* flush の定期実行。タスクの積み上がりを避けるため 1 本だけ走らせ、
   未処理が残っている限り自分で次の一発を予約する (maildb と同じ one-shot
   ScheduledTask[expr, {t}] イディオム。{t, n} 形式は「t 秒後と n 秒後」の意味に
   なってしまうので使わない)。 *)
iPScheduleFlush[] :=
  If[! iPFrontEndQ[] || TrueQ[$svPFlushScheduled], Null,
    $svPFlushScheduled = True;
    Quiet @ Check[
      SessionSubmit[ScheduledTask[iPFlushTick[], {0.4}]],
      $svPFlushScheduled = False]];

iPFlushTick[] :=
  Quiet @ Check[
    (iPFlushPending[];
     If[$svPPending === {},
       $svPFlushScheduled = False,
       Quiet @ Check[
         SessionSubmit[ScheduledTask[iPFlushTick[], {0.4}]],
         $svPFlushScheduled = False]]),
    $svPFlushScheduled = False];

SourceVault`SourceVaultMarkEvaluationPrivacyCells[nb_NotebookObject] := iPFlushPending[];
SourceVault`SourceVaultMarkEvaluationPrivacyCells[] := iPFlushPending[];

(* ============================================================
   3. 正準 exit
   ============================================================ *)

SourceVault`SourceVaultPrivateResult[expr_, pl_] :=
  (SourceVault`SourceVaultNotePrivacy[pl]; expr);
SourceVault`SourceVaultPrivateResult[expr_] :=
  SourceVault`SourceVaultPrivateResult[expr, SourceVault`$SourceVaultPrivacyDefaultLevel];

iPBadge[expr_, lv_?NumericQ] :=
  Framed[
    Column[{
      Row[{
        Style["\[WarningSign] ", FontColor -> RGBColor[0.75, 0.1, 0.1], FontSize -> 13],
        Style["\:6a5f\:5bc6 / Confidential  PrivacyLevel " <>
            ToString[NumberForm[N[lv], {3, 2}]],
          FontColor -> RGBColor[0.75, 0.1, 0.1], FontSize -> 11,
          FontWeight -> Bold, FontFamily -> "Segoe UI"]}],
      expr}, Spacings -> 0.6],
    Background -> RGBColor[1, 0.94, 0.94],
    FrameStyle -> RGBColor[0.75, 0.1, 0.1],
    FrameMargins -> 8, RoundingRadius -> 4];

(* 表示ラッパ。Format 定義なので値の構造は SourceVaultPrivate[payload, pl] のまま残り、
   Unwrap で決定的に剥がせる (生の Framed で包むと剥がし方が場当たりになる)。 *)
Format[SourceVault`SourceVaultPrivate[e_, pl_]] := iPBadge[e, pl];

SourceVault`SourceVaultPrivacyUnwrap[SourceVault`SourceVaultPrivate[e_, _]] := e;
SourceVault`SourceVaultPrivacyUnwrap[x_] := x;

SourceVault`SourceVaultPrivacyLevelOf[SourceVault`SourceVaultPrivate[_, pl_]] := pl;
SourceVault`SourceVaultPrivacyLevelOf[_] := Missing["NoPrivacyLabel"];

SourceVault`SourceVaultPrivateView[expr_, pl_] :=
  Module[{lv = iPClip[pl]},
    SourceVault`SourceVaultNotePrivacy[lv];
    Which[
      lv < iPThreshold[], expr,
      ! TrueQ[SourceVault`$SourceVaultPrivacyViewBadge], expr,
      (* 二重包みしない (冪等) *)
      MatchQ[expr, SourceVault`SourceVaultPrivate[_, _]], expr,
      True, SourceVault`SourceVaultPrivate[expr, lv]]];
SourceVault`SourceVaultPrivateView[expr_] :=
  SourceVault`SourceVaultPrivateView[expr, SourceVault`$SourceVaultPrivacyDefaultLevel];

(* ============================================================
   4. 宣言レジストリ
   ============================================================ *)

If[! AssociationQ[$svPSources], $svPSources = <||>];
If[! AssociationQ[$svPContracts], $svPContracts = <||>];
If[! AssociationQ[$svPModules], $svPModules = <||>];

$svPClasses = {"Private", "Public", "Internal"};
$svPExits = {"View", "Result", "Head", "None"};

SourceVault`SourceVaultDeclarePrivacySource[name_String, spec_Association] :=
  ($svPSources[name] = <|
     "Name" -> name,
     "Level" -> iPClip[Lookup[spec, "Level", SourceVault`$SourceVaultPrivacyDefaultLevel]],
     "Readers" -> Select[Replace[Lookup[spec, "Readers", {}], Except[_List] -> {}], StringQ],
     "Description" -> Lookup[spec, "Description", ""]|>;
   $svPSources[name]);

SourceVault`SourceVaultPrivacySources[] := $svPSources;

SourceVault`SourceVaultRegisterPrivacyContract[sym_String, spec_Association] :=
  Module[{class, exit},
    class = Lookup[spec, "Class", "Internal"];
    If[! MemberQ[$svPClasses, class],
      Return[Failure["InvalidPrivacyClass",
        <|"MessageTemplate" -> "Class must be one of Private/Public/Internal.",
          "Symbol" -> sym, "Class" -> class|>]]];
    exit = Lookup[spec, "Exit", If[class === "Private", "Result", "None"]];
    If[! MemberQ[$svPExits, exit], exit = "None"];
    (* Public/Internal と宣言しながら私的ストアへ到達する関数は、なぜ出力に
       データが載らないのかを "NoDataFlow" に理由で書かねばならない (fail-closed。
       理由なしは監査 FAIL)。 *)
    $svPContracts[sym] = <|
      "Symbol" -> sym, "Class" -> class, "Exit" -> exit,
      "Level" -> Lookup[spec, "Level", Automatic],
      "Sources" -> Select[Replace[Lookup[spec, "Sources", {}], Except[_List] -> {}], StringQ],
      "Module" -> Lookup[spec, "Module", Missing["NotSet"]],
      "NoDataFlow" -> Lookup[spec, "NoDataFlow", Missing["NotSet"]],
      "Note" -> Lookup[spec, "Note", ""]|>;
    $svPContracts[sym]];

SourceVault`SourceVaultRegisterPrivacyContract[sym_String, class_String] :=
  SourceVault`SourceVaultRegisterPrivacyContract[sym, <|"Class" -> class|>];

SourceVault`SourceVaultPrivacyContract[sym_String] :=
  Lookup[$svPContracts, sym, Missing["NoPrivacyContract", sym]];

SourceVault`SourceVaultPrivacyContracts[] := $svPContracts;

SourceVault`SourceVaultDeclareModulePrivacy[file_String, spec_Association] :=
  ($svPModules[file] = <|
     "Module" -> file,
     "DefaultClass" -> Lookup[spec, "DefaultClass", "Internal"],
     "Sources" -> Select[Replace[Lookup[spec, "Sources", {}], Except[_List] -> {}], StringQ],
     "Note" -> Lookup[spec, "Note", ""]|>;
   $svPModules[file]);

SourceVault`SourceVaultModulePrivacyDeclarations[] := $svPModules;

(* ============================================================
   5. 呼び出しグラフと静的監査 (Runtime mode)
   ============================================================ *)

$svPContexts = {"SourceVault`", "SourceVault`Private`",
  "SourceVault`ContractsPrivate`", "SourceVault`WiringPrivate`",
  "SourceVault`PrivacyPrivate`"};

(* SourceVault` 系の全シンボル名 (public + Private/PrivacyPrivate 等の下位文脈)。
   罠: SourceVault` が $ContextPath に載っていると Names["SourceVault`*"] は
   短縮名 (文脈なし) を返す。iPRefsOf が返すのは完全名なので、そのままだと
   グラフの節点名が食い違い BFS が 1 歩も進まない (監査が常に OK になる)。
   ここで文脈を付け直して完全名に正規化する。 *)
iPAllSourceVaultSymbols[] :=
  DeleteDuplicates @ Flatten @ Map[
    Function[ctx,
      (ctx <> Last[StringSplit[#, "`"]]) & /@ Names[ctx <> "*"]],
    $svPContexts];

iPShortName[full_String] := Last[StringSplit[full, "`"]];

(* 1 シンボルが参照する SourceVault 系シンボルの短縮名リスト。
   NBAccess.wl:6906 と同じ Cases イディオム (Unevaluated で名前だけ取る)。 *)
(* 罠: DownValues/SubValues/OwnValues は HoldAll。ローカル変数を渡すと
   そのローカル変数自身の定義 (=空) を見てしまう。With で実シンボルを
   本体へ字句的に注入すること。 *)
iPRefsOf[full_String] :=
  Quiet @ Check[
    With[{sym = Symbol[full]},
      DeleteDuplicates @ Cases[
        {DownValues[sym], SubValues[sym], OwnValues[sym]},
        s_Symbol /; StringStartsQ[Context[Unevaluated[s]], "SourceVault`"] :>
          Context[Unevaluated[s]] <> SymbolName[Unevaluated[s]],
        {0, Infinity}, Heads -> True]],
    {}];

SourceVault`SourceVaultPrivacyCallGraph[] :=
  Module[{syms},
    syms = iPAllSourceVaultSymbols[];
    Association[Function[s, s -> iPRefsOf[s]] /@ syms]];

(* 私的ストアの Readers (短縮名) -> full 名の集合 *)
iPSourceReaderFullNames[graph_Association] :=
  Module[{short, all = Keys[graph]},
    short = DeleteDuplicates @ Flatten[Lookup[#, "Readers", {}] & /@ Values[$svPSources]];
    Association @ Map[
      Function[nm,
        nm -> Select[all, iPShortName[#] === nm &]],
      short]];

(* full 名 -> ストア名 の逆引き (readerMap から 1 回だけ作る) *)
iPReaderIndex[readerMap_Association] :=
  Association @ Flatten[
    Function[nm, (# -> nm) & /@ Lookup[readerMap, nm, {}]] /@ Keys[readerMap]];

(* full 名 -> 到達可能な私的ストア名の集合 (BFS、深さ制限つき) *)
iPReachSources[graph_Association, readerOf_Association, start_String, maxDepth_Integer] :=
  Module[{seen = <|start -> True|>, frontier = {start}, hits = {}, d = 0, next},
    While[frontier =!= {} && d < maxDepth,
      next = {};
      Scan[
        Function[f,
          Scan[
            Function[r,
              If[KeyExistsQ[readerOf, r], AppendTo[hits, readerOf[r]]];
              If[! KeyExistsQ[seen, r], seen[r] = True; AppendTo[next, r]]],
            Lookup[graph, f, {}]]],
        frontier];
      frontier = next; d++];
    DeleteDuplicates[hits]];

SourceVault`SourceVaultPrivacyReachesSource[sym_String] :=
  Module[{graph = SourceVault`SourceVaultPrivacyCallGraph[], readerOf, full},
    readerOf = iPReaderIndex[iPSourceReaderFullNames[graph]];
    full = If[StringContainsQ[sym, "`"], sym, "SourceVault`" <> sym];
    <|"Symbol" -> sym,
      "Sources" -> iPReachSources[graph, readerOf, full, 8]|>];

(* public シンボル = SourceVault` 直下かつ ::usage を持つ (= 明示 export)。
   罠: MessageName は HoldFirst なので MessageName[Symbol[full], "usage"] は
   Symbol::usage を見てしまう。ToExpression で名前から直接評価する。 *)
iPPublicSymbolQ[full_String] :=
  StringStartsQ[full, "SourceVault`"] &&
  ! StringContainsQ[StringDrop[full, StringLength["SourceVault`"]], "`"] &&
  Quiet @ Check[
    With[{m = ToExpression[full <> "::usage"]},
      StringQ[m] && StringLength[m] > 0],
    False];

iPEffectiveClass[shortName_String] :=
  Module[{c = Lookup[$svPContracts, shortName, Missing[]]},
    If[AssociationQ[c], Lookup[c, "Class", "Internal"], Missing["Undeclared"]]];

Options[SourceVault`SourceVaultPrivacyAudit] = {
  "Mode" -> "Runtime", "Files" -> Automatic, "Directory" -> Automatic,
  "MaxDepth" -> 8};

SourceVault`SourceVaultPrivacyAudit[opts : OptionsPattern[]] :=
  Switch[OptionValue["Mode"],
    "Source", iPAuditSource[opts],
    _, iPAuditRuntime[opts]];

iPAuditRuntime[opts : OptionsPattern[SourceVault`SourceVaultPrivacyAudit]] :=
  Module[{graph, readerOf, publics, leaks = {}, missingExit = {}, undeclared = {},
      maxDepth = OptionValue[SourceVault`SourceVaultPrivacyAudit, {opts}, "MaxDepth"]},
    graph = SourceVault`SourceVaultPrivacyCallGraph[];
    readerOf = iPReaderIndex[iPSourceReaderFullNames[graph]];
    publics = Select[Keys[graph], iPPublicSymbolQ];
    Scan[
      Function[full,
        Module[{short = iPShortName[full], reach, class},
          reach = iPReachSources[graph, readerOf, full, maxDepth];
          class = iPEffectiveClass[short];
          Which[
            reach === {}, Null,
            MissingQ[class],
              AppendTo[leaks,
                <|"Symbol" -> short, "Sources" -> reach, "Reason" -> "Undeclared"|>],
            class =!= "Private" &&
              ! StringQ[Lookup[Lookup[$svPContracts, short, <||>], "NoDataFlow", Missing[]]],
              AppendTo[leaks,
                <|"Symbol" -> short, "Sources" -> reach,
                  "Reason" -> "DeclaredAs" <> class <> "WithoutNoDataFlowReason"|>],
            class =!= "Private",   (* 理由付きの明示例外 *)
              Null,
            True,
              If[Lookup[Lookup[$svPContracts, short, <||>], "Exit", "None"] === "None",
                AppendTo[missingExit,
                  <|"Symbol" -> short, "Sources" -> reach|>]]];
          If[MissingQ[class] && reach === {}, AppendTo[undeclared, short]]]],
      publics];
    <|"Status" -> If[leaks === {}, "OK", "Failed"],
      "Mode" -> "Runtime",
      "UndeclaredLeak" -> leaks,
      "MissingExit" -> missingExit,
      "Unreviewed" -> {},
      "Counts" -> <|"Public" -> Length[publics], "Declared" -> Length[$svPContracts],
        "Sources" -> Length[$svPSources], "UndeclaredNoLeak" -> Length[undeclared]|>|>];

(* ---- Source mode: headless / コミットゲート用 ---- *)

iPSourceDirectory[dirOpt_] :=
  Which[
    StringQ[dirOpt] && DirectoryQ[dirOpt], dirOpt,
    True,
      With[{d = Quiet @ Check[DirectoryName[$svPThisFile], ""]},
        If[StringQ[d] && DirectoryQ[d], d, Directory[]]]];

iPSourceFiles[dir_String] :=
  Sort @ Select[FileNames["SourceVault*.wl", dir], ! StringContainsQ[#, "_info"] &];

(* ファイル内の export シンボル名 (Sym::usage の宣言)。
   行頭だけでなく `"...";Sym::usage` のような同一行連結も拾う。 *)
iPExportedSymbolsOfFile[path_String] :=
  Quiet @ Check[
    Module[{text},
      text = Import[path, "Text", CharacterEncoding -> "UTF-8"];
      If[! StringQ[text], Return[{}, Module]];
      Sort @ DeleteDuplicates @ Map[
        (* 前後の ";"/空白を落とし "::usage" を切り離して名前だけにする *)
        StringTrim[StringDrop[#, -StringLength["::usage"]], RegularExpression["^[;\\s]+"]] &,
        StringCases[text,
          RegularExpression["(?m)(?:^|;)[ \\t]*[A-Za-z$][A-Za-z0-9$]*::usage"]]]],
    {}];

iPReviewPath[dir_String, pathOpt_] :=
  If[StringQ[pathOpt], pathOpt,
    FileNameJoin[{dir, "SourceVault_info", "privacy", "privacy_reviewed.m"}]];

SourceVault`SourceVaultPrivacyReviewedSymbols[] :=
  Module[{dir = iPSourceDirectory[Automatic], p},
    p = iPReviewPath[dir, Automatic];
    If[! FileExistsQ[p], Return[<||>]];
    With[{r = Quiet @ Check[Get[p], <||>]},
      If[AssociationQ[r], r, <||>]]];

iPAuditSource[opts : OptionsPattern[SourceVault`SourceVaultPrivacyAudit]] :=
  Module[{dir, files, reviewed, unreviewed = {}, total = 0},
    dir = iPSourceDirectory[
      OptionValue[SourceVault`SourceVaultPrivacyAudit, {opts}, "Directory"]];
    files = With[{f = OptionValue[SourceVault`SourceVaultPrivacyAudit, {opts}, "Files"]},
      If[ListQ[f], f, iPSourceFiles[dir]]];
    reviewed = SourceVault`SourceVaultPrivacyReviewedSymbols[];
    Scan[
      Function[path,
        Module[{base = FileNameTake[path], syms, known},
          syms = iPExportedSymbolsOfFile[path];
          total += Length[syms];
          known = Replace[Lookup[reviewed, base, {}], Except[_List] -> {}];
          With[{news = Complement[syms, known]},
            If[news =!= {},
              AppendTo[unreviewed, <|"Module" -> base, "Symbols" -> news|>]]]]],
      files];
    <|"Status" -> If[unreviewed === {}, "OK", "Failed"],
      "Mode" -> "Source",
      "UndeclaredLeak" -> {},
      "MissingExit" -> {},
      "Unreviewed" -> unreviewed,
      "Counts" -> <|"Files" -> Length[files], "Exported" -> total,
        "Reviewed" -> Total[Length /@ Values[reviewed]]|>|>];

Options[SourceVault`SourceVaultPrivacyWriteReview] = {
  "Directory" -> Automatic, "Path" -> Automatic};

SourceVault`SourceVaultPrivacyWriteReview[opts : OptionsPattern[]] :=
  Module[{dir, files, p, data},
    dir = iPSourceDirectory[OptionValue["Directory"]];
    files = iPSourceFiles[dir];
    p = iPReviewPath[dir, OptionValue["Path"]];
    If[! DirectoryQ[DirectoryName[p]],
      Quiet @ CreateDirectory[DirectoryName[p], CreateIntermediateDirectories -> True]];
    data = Association @ Map[
      Function[path, FileNameTake[path] -> iPExportedSymbolsOfFile[path]], files];
    Quiet @ Check[Put[data, p], Return[Failure["PrivacyReviewWriteFailed", <|"Path" -> p|>]]];
    <|"Status" -> "Written", "Path" -> p,
      "Files" -> Length[data], "Symbols" -> Total[Length /@ Values[data]]|>];

(* ============================================================
   6. 動的適合テスト
   ------------------------------------------------------------
   「入力変数や内部でインポートするデータの PL 最大値が出力に伝わるか」を
   合成データで実測する。FE 不要 (透かしを観測する)。
   ============================================================ *)

If[! AssociationQ[$svPProbes], $svPProbes = <||>];

SourceVault`SourceVaultRegisterPrivacyProbe[sym_String, probe_Association] :=
  ($svPProbes[sym] = probe; probe);

SourceVault`SourceVaultPrivacyProbes[] := $svPProbes;

iPRunProbeCase[sym_String, probe_Association, level_?NumericQ] :=
  Module[{setup, call, teardown, ctx, res, observed, expected, ok, err = Missing[]},
    setup = Lookup[probe, "Setup", Function[l, l]];
    call = Lookup[probe, "Call", Function[c, Null]];
    teardown = Lookup[probe, "Teardown", Function[c, Null]];
    ctx = Quiet @ Check[setup[level], $Failed];
    If[ctx === $Failed,
      Return[<|"Level" -> level, "Status" -> "Error", "Reason" -> "SetupFailed"|>]];
    res = Quiet @ Check[
      SourceVault`SourceVaultWithPrivacyScope[call[ctx]],
      $Failed];
    Quiet @ Check[teardown[ctx], Null];
    If[! AssociationQ[res],
      Return[<|"Level" -> level, "Status" -> "Error", "Reason" -> "CallFailed"|>]];
    observed = Lookup[res, "Privacy", 0.];
    (* 判定:
       高 PL 入力 (>= 閾値) -> 観測 PL >= 入力 PL であること (伝達)
       低 PL 入力 (< 閾値)  -> 観測 PL < 閾値であること (過剰マーク防止) *)
    If[level >= iPThreshold[],
      expected = ">= " <> ToString[N[level]];
      ok = TrueQ[observed >= level - 1.*^-9],
      expected = "< " <> ToString[iPThreshold[]];
      ok = TrueQ[observed < iPThreshold[]]];
    <|"Level" -> N[level], "Observed" -> N[observed], "Expected" -> expected,
      "Status" -> If[ok, "Pass", "Fail"]|>];

SourceVault`SourceVaultPrivacyConformanceTest[sym_String] :=
  Module[{probe, levels, cases},
    probe = Lookup[$svPProbes, sym, Missing[]];
    If[! AssociationQ[probe],
      Return[<|"Status" -> "Skipped", "Symbol" -> sym, "Reason" -> "NoProbe",
        "Cases" -> {}|>]];
    levels = Replace[Lookup[probe, "Levels", {0.0, 1.0}], Except[_List] -> {0.0, 1.0}];
    cases = iPRunProbeCase[sym, probe, #] & /@ Select[levels, NumericQ];
    <|"Status" -> If[AllTrue[cases, Lookup[#, "Status", "Fail"] === "Pass" &],
        "Pass", "Fail"],
      "Symbol" -> sym, "Cases" -> cases|>];

SourceVault`SourceVaultPrivacyConformanceTest[All] :=
  Module[{results},
    results = SourceVault`SourceVaultPrivacyConformanceTest /@ Keys[$svPProbes];
    <|"Status" -> If[AllTrue[results, MemberQ[{"Pass", "Skipped"}, Lookup[#, "Status", "Fail"]] &],
        "Pass", "Fail"],
      "Results" -> results,
      "Counts" -> <|"Total" -> Length[results],
        "Pass" -> Count[results, r_ /; Lookup[r, "Status", ""] === "Pass"],
        "Fail" -> Count[results, r_ /; Lookup[r, "Status", ""] === "Fail"],
        "Skipped" -> Count[results, r_ /; Lookup[r, "Status", ""] === "Skipped"]|>|>];

(* ============================================================
   7. 既定の宣言 (私的ストア)
   ------------------------------------------------------------
   ここは「一次ストアの読み出し口」だけを列挙する。派生関数は呼び出しグラフで
   自動的に到達判定されるので、増えても書き足す必要はない。
   ============================================================ *)

SourceVault`SourceVaultDeclarePrivacySource["mail", <|
  "Level" -> 0.85,
  "Description" -> "\:30e1\:30fc\:30eb snapshot / \:7d22\:5f15 sidecar (\:672c\:6587\:30fb\:4ef6\:540d\:30fb\:5dee\:51fa\:4eba\:30fb\:8981\:7d04)",
  "Readers" -> {
    "SourceVaultSearchMailSnapshots", "SourceVaultMailSnapshotGet",
    "SourceVaultMailSnapshotList", "SourceVaultMailSearchIndex",
    "SourceVaultMailIndexGet", "SourceVaultMailGetBody",
    "SourceVaultMailSnapshotDecryptBody", "SourceVaultMailAttachments",
    "SourceVaultMailDerivedPending", "SourceVaultMailAgendaItems"}|>];

SourceVault`SourceVaultDeclarePrivacySource["notebook", <|
  "Level" -> 0.85,
  "Description" -> "\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:672c\:4f53\:306e\:751f\:30bb\:30eb\:5185\:5bb9 (CloudPublishable \:672a\:5ba3\:8a00\:3092\:542b\:3080)",
  "Readers" -> {"SourceVaultFindTodos"}|>];

SourceVault`SourceVaultDeclarePrivacySource["eagle", <|
  "Level" -> 0.85,
  "Description" -> "Eagle \:30e9\:30a4\:30d6\:30e9\:30ea\:306e item \:30e1\:30bf/\:6ce8\:91c8",
  "Readers" -> {"SourceVaultEagleSearchItems", "SourceVaultEagleItemGet"}|>];

SourceVault`SourceVaultDeclarePrivacySource["oops", <|
  "Level" -> 0.85,
  "Description" -> "OOPS \:30b9\:30ec\:30c3\:30c9 (\:500b\:4eba\:30e1\:30e2/\:5b66\:5185\:60c5\:5831)",
  "Readers" -> {"SourceVaultOopsSearchThreads", "SourceVaultOopsThread"}|>];

SourceVault`SourceVaultDeclarePrivacySource["llmlog", <|
  "Level" -> 0.85,
  "Description" -> "LLM \:5b9f\:884c\:30ed\:30b0 digest (\:30d7\:30ed\:30f3\:30d7\:30c8\:672c\:6587\:3092\:542b\:307f\:3046\:308b)",
  "Readers" -> {"SourceVaultLLMLogSearch", "SourceVaultLLMLogGet"}|>];

(* ============================================================
   7b. 既定の関数宣言 (横断表)
   ------------------------------------------------------------
   規約: 新しいモジュールは「自分のモジュール内で」自分の関数を登録すること
   (SourceVault_maildb.wl の iSVMDRegisterPrivacyContracts が手本)。
   ここに置くのは、まだ自前登録を持たない既存モジュール分の暫定表。
   自前登録に移した関数はここから削除してよい (登録は冪等・後勝ち)。

   2026-07-21 の初回監査 (SourceVaultPrivacyAudit["Mode"->"Runtime"]) が
   検出した「私的ストアへ到達するのに未宣言だった public 関数」41 件を分類した。

   Class -> "Private"          : 私的データが出力に載る。正準 exit を通す義務あり。
   Class -> "Internal"/"Public": 載らない。理由を "NoDataFlow" に必ず書く
                                 (書かないと監査 FAIL = fail-closed)。
   ============================================================ *)

iPDeclareMany[class_String, exitOrReason_String, entries_List] :=
  Scan[
    Function[e,
      SourceVault`SourceVaultRegisterPrivacyContract[First[e],
        Join[
          <|"Class" -> class, "Module" -> Last[e]|>,
          If[class === "Private",
            <|"Exit" -> exitOrReason|>,
            <|"NoDataFlow" -> exitOrReason|>]]]],
    entries];

(* ---- Private: 表示オブジェクトを返す (バッジ付き exit を通すべきもの) ---- *)
iPDeclareMany["Private", "View", {
  {"SourceVaultRoutineAgendaView", "SourceVault_routineplan.wl"},
  {"SourceVaultRoutineGanttView", "SourceVault_routineplan.wl"},
  {"SourceVaultRoutineLoadView", "SourceVault_routineplan.wl"},
  {"SourceVaultMailThreadPanel", "SourceVault_maildb.wl"},
  {"SourceVaultMailRowActions", "SourceVault_maildb.wl"},
  {"SourceVaultMailSessionSuggestView", "SourceVault_mailsuggest.wl"}}];

(* ---- Private: 生データ/連想を返す (透かしのみ。値の形は変えない) ---- *)
iPDeclareMany["Private", "Result", {
  {"SourceVaultRoutineAgendaData", "SourceVault_routineplan.wl"},
  {"SourceVaultMailAgendaItems", "SourceVault_mailagenda.wl"},
  {"SourceVaultMailForNotebook", "SourceVault_mailagenda.wl"},
  {"SourceVaultFindTodos", "SourceVault.wl"},
  {"SourceVaultExtractAllMail", "SourceVault_maildb.wl"},
  {"SourceVaultMailToGenericRecord", "SourceVault_mailstructure.wl"},
  {"SourceVaultMailRecordsForStructuring", "SourceVault_mailstructure.wl"},
  {"SourceVaultRunPrimaryRoute", "SourceVault_promptrouter.wl"},
  {"SourceVaultExecutePromptRoute", "SourceVault_promptrouter.wl"}}];

(* ---- Private: ノートブック/ウィンドウを開く (egress は開いた先の NB 側) ---- *)
iPDeclareMany["Private", "Head", {
  {"SourceVaultMailAgendaOpen", "SourceVault_mailagenda.wl"},
  {"SourceVaultMailThreadWindow", "SourceVault_maildb.wl"},
  {"SourceVaultMailReplyDraft", "SourceVault_maildb.wl"},
  {"SourceVaultMailOpenReplyNotebook", "SourceVault_maildb.wl"},
  {"SourceVaultMailOpenAttachment", "SourceVault_maildb.wl"},
  (* MCP は別 egress。承認/scope gate は universal MCP access 層が持つが、
     privacy 分類としては「私的データを外へ出す」= Private が正しい。 *)
  {"SourceVaultMCPCallTool", "SourceVault_mcp.wl"},
  {"SourceVaultMCPDispatch", "SourceVault_mcp.wl"}}];

(* ---- Internal: 取込み/派生生成パイプライン。返すのは件数と状態のみ ---- *)
iPDeclareMany["Internal",
  "\:53d6\:8fbc\:307f/\:6d3e\:751f\:751f\:6210\:30d1\:30a4\:30d7\:30e9\:30a4\:30f3\:3002\:672c\:6587\:3092\:8aad\:3080\:304c\:8fd4\:308a\:5024\:306f <|Status, Count|> \:7b49\:306e\:96c6\:8a08\:306e\:307f\:3002", {
  {"SourceVaultMailFetchNew", "SourceVault_maildb.wl"},
  {"SourceVaultBackfillMailBodies", "SourceVault_maildb.wl"},
  {"SourceVaultMailAddSummaries", "SourceVault_maildb.wl"},
  {"SourceVaultInferMailDerivedBatch", "SourceVault_maildb.wl"},
  {"SourceVaultMailRecomputePriorities", "SourceVault_maildb.wl"},
  {"SourceVaultMailStructEnsureIndex", "SourceVault_mailstructure.wl"},
  {"SourceVaultIdentityBackfillFromMail", "SourceVault_identity.wl"},
  {"SourceVaultLearnMailDeliveryBaselines", "SourceVault_mining.wl"},
  {"SourceVaultMiningAuthorshipFetchHook", "SourceVault_mining.wl"},
  {"SourceVaultMiningWireProductionHooks", "SourceVault_mining.wl"},
  {"SourceVaultAutoTriggerDispatchJobs", "SourceVault_autotrigger.wl"}}];

(* ---- Internal: 機密マーク機構そのもの (メタデータしか返さない) ---- *)
iPDeclareMany["Internal",
  "\:6a5f\:5bc6\:30de\:30fc\:30af\:6a5f\:69cb\:81ea\:8eab\:3002\:5224\:5b9a\:306e\:305f\:3081 probe \:3092\:547c\:3076\:304c\:3001\:8fd4\:3059\:306e\:306f\:30bb\:30eb\:756a\:53f7\:3068 PL \:306e\:307f\:3002", {
  {"SourceVaultMarkConfidentialViewCells", "SourceVault_maildb.wl"},
  {"SourceVaultMailMarkViewCells", "SourceVault_maildb.wl"},
  {"SourceVaultMailEnableAutoConfidential", "SourceVault_maildb.wl"}}];

(* ---- Internal: ルーティング提案層 (候補式/表を返すだけで本文は返さない) ---- *)
iPDeclareMany["Internal",
  "\:63d0\:6848\:30fb\:8a31\:53ef\:8868\:5c64\:3002\:5230\:9054\:53ef\:80fd\:306a\:306e\:306f allowlist \:7d4c\:7531\:3067\:3001\:8fd4\:308a\:5024\:306f\:5019\:88dc\:5f0f\:3068\:95a2\:6570\:540d\:306e\:307f\:3002", {
  {"SourceVaultProposePromptRoute", "SourceVault_promptrouter.wl"},
  {"SourceVaultProposeSavedPromptRoute", "SourceVault_promptrouter.wl"},
  {"SourceVaultPromptReprocessPlan", "SourceVault_promptrouter.wl"},
  {"SourceVaultCallableAllowlistRegistry", "SourceVault_promptrouter.wl"},
  {"SourceVaultCallableAllowlistView", "SourceVault_promptrouter.wl"}}];

(* ============================================================
   8. ロード時: 自己参照パス記憶
   ============================================================ *)

If[! StringQ[$svPThisFile],
  $svPThisFile = Quiet @ Check[$InputFileName, ""]];

End[];
EndPackage[];
