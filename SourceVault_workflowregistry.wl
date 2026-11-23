(* ::Package:: *)

(* ============================================================
   SourceVault_workflowregistry.wl -- on-demand loader / registry for
   codified SourceVault workflows under SourceVault_workflows/<slug>/.

   This file is encoded in UTF-8.
   Load: SourceVault.wl の auto-load から Get される (mcp の後)。

   ワークフローは普段ロードされず、プロンプトルート／パレット等から
   必要時に SourceVaultLoadWorkflow[slug] でオンデマンドロードする。
   各ワークフローは context SourceVaultWorkflow`<CanonicalSlug>` に分離され、
   private は通常の Begin["`Private`"] で隔離される (同一セッションに複数を
   同時ロードしてもシンボルが衝突しない)。slug の一意性はディスク上の
   フォルダ名で担保される。

   ---- stage (テスト中 / 運用中) フォルダ分離 ----
   生成 (spec-impl) されたワークフローは試行錯誤版と実運用版が混在しないよう
   2 つの予約サブフォルダに分けて格納する:
     SourceVault_workflows/testing/<slug>/      (テスト中)
     SourceVault_workflows/production/<slug>/   (運用中)
   slug は root / testing / production を通じてグローバルに一意 ("testing" と
   "production" は予約名で slug にできない)。ルート直下のフォルダ (spec-review,
   spec-impl) は「システムワークフロー」(stage="system") としてそのまま残し、
   testing/production の分類対象にしない。stage の真実源はフォルダ位置である。

   公開関数:
     SourceVaultWorkflowDirectory[]       -- <packageRoot>/SourceVault_workflows
     SourceVaultWorkflowStageDirectory[s] -- <root>/testing | <root>/production
     SourceVaultWorkflowContext[slug]     -- "SourceVaultWorkflow`<CanonicalSlug>`"
     SourceVaultWorkflowFolder[slug]      -- slug の実フォルダ (root/testing/production を横断解決)
     SourceVaultWorkflows[]               -- 収納済みワークフロー一覧 (assoc list, "Stage" 付き)
     SourceVaultLoadWorkflow[slug]        -- 当該ワークフロー本体 .wl をオンデマンド Get
   公開シンボル:
     $SourceVaultWorkflowStages           -- {"testing", "production"}
   ============================================================ *)

BeginPackage["SourceVault`"]

SourceVaultWorkflowDirectory::usage =
  "SourceVaultWorkflowDirectory[] はコード化ワークフローの収納ルート \
(<packageRoot>/SourceVault_workflows) を返す。";

$SourceVaultWorkflowStages::usage =
  "$SourceVaultWorkflowStages は生成ワークフローを分けて格納する予約サブフォルダ名 \
{\"testing\", \"production\", \"archive\"} (テスト中 / 運用中 / アーカイブ)。\
これらの名前は slug に使えない。archive は通常のワークフロー一覧・横断検索には現れない。";

SourceVaultWorkflowStageDirectory::usage =
  "SourceVaultWorkflowStageDirectory[stage] は stage (\"testing\" | \"production\" | \"archive\") の \
収納ディレクトリ (<root>/<stage>) を返す。";

SourceVaultWorkflowContext::usage =
  "SourceVaultWorkflowContext[slug] は slug を正規化したワークフロー context 文字列 \
\"SourceVaultWorkflow`<CanonicalSlug>`\" を返す (例: \"spec-review\" -> \
\"SourceVaultWorkflow`SpecReview`\")。";

SourceVaultWorkflowFolder::usage =
  "SourceVaultWorkflowFolder[slug] は slug の実フォルダパスを root / testing / production を \
横断して解決して返す (見つからなければ Missing[\"NotFound\"])。";

SourceVaultWorkflows::usage =
  "SourceVaultWorkflows[] は SourceVault_workflows/ 配下の収納済みワークフロー一覧を返す。\
各要素は <|\"Slug\",\"Stage\"(\"system\"|\"testing\"|\"production\"|\"archive\"),\"Path\",\"MainFile\",\"Context\",\"Loaded\"|>。";

SourceVaultLoadWorkflow::usage =
  "SourceVaultLoadWorkflow[slug] は SourceVault_workflows/(testing|production|)/<slug>/ の \
ワークフロー本体 .wl をオンデマンドで Get し、<|\"Status\",\"Slug\",\"Context\",\"Path\"|> を返す。\
既にロード済み (context が $Packages にある) ならロードをスキップする。\
ワークフロー本体は依存 (ClaudeOrchestrator`Workflow` / SourceVault`) を自己ブートストラップする。\
読み込みの直前に読み込み検査 (SourceVaultIntegrityLoadVerify) を通し、止まったら読み込まずに \
<|\"Status\"->\"LoadDenied\",\"Message\"(日本語の理由),\"Next\"(次の手段),\"NextExpression\"(評価できる式の文字列 | None),\
\"Slug\",\"Context\",\"Path\",\"LoadVerify\"|> を返す (例: 未受け入れの版は SourceVaultIntegrityOwnerAction[SourceVaultIntegrityAcceptBaseline[...]] の式)。";

SourceVaultRunWorkflowAsync::usage =
  "SourceVaultRunWorkflowAsync[slug, form:\"run\"] は生成ワークフローの launch entry を \
既存の External executor (ClaudeRuntime / ClaudeOrchestrator`Workflow`) 経由で FRONT END を止めずに \
非同期実行する。子プロセス (wolframscript) が SourceVaultRunWorkflowChild[slug, form, $Language] を評価し、\
完了時に single committer が呼出元ノートへ summary セルを書く (本体 View は inline せず output.wxf に保存)。\
返り値: <|\"Status\"->\"Submitted\",\"JobID\",\"JobDir\",\"WorkflowId\",\"Head\"|> または \
<|\"Status\"->\"RuntimeUnavailable\"|\"Failed\", ...|>。実行結果 (View) は SourceVaultRunWorkflowResult で取り出す。\
投入の前にこの PC で読み込み検査を確かめ、止まるならジョブを投入せず、呼出元のセル (ワークフロー一覧) の直後に理由の Text セルと \
次の手段の式の Input セル (評価しない) を書いて、SourceVaultLoadWorkflow と同じ形の <|\"Status\"->\"LoadDenied\",\"Message\",\"Next\",\
\"NextExpression\",...,\"Notebook\"->\"Written\"|\"NoNotebook\"|> を返す。オプション \"LoadPrecheck\" (既定 True): False なら確かめずに投入する \
(別の PC の配車が使う。止まったときは子の結果 LoadFailed の \"Message\" で知らせる)。\
\"Confidential\" (既定 True): 実行結果を機密ジョブとして封印する (input/output.wxf を暗号化、SystemCredential の鍵が要る)。\
準備ができていなければ投入せず <|\"Status\"->\"ConfidentialUnavailable\",\"Message\",\"Next\",\"NextExpression\" (\"Confidential\" -> False で実行する式)|> を返す。\
\"ResultLimit\" (既定 64 MB): 結果をそのまま保存する上限 (超えると要約に置き換わる)。投入に失敗したときも理由のセルを書く。\
前提: ClaudeRuntime (externalrunner) と ClaudeOrchestrator`Workflow` がロード済みであること。";

SourceVaultRunWorkflowChild::usage =
  "SourceVaultRunWorkflowChild[slug, form:\"run\", lang:Automatic] は外部子カーネルで評価される本体: \
$Language を lang に束ねてワークフローをロードし、launch entry を form で呼んで結果を返す。\
ロードできなければ <|\"Status\"->\"LoadFailed\",\"Message\"(日本語の理由と次の手段),\"Slug\",\"NextExpression\",\"LoadResult\"|> を返す。\
通常 SourceVaultRunWorkflowAsync が held 式として投入するので直接呼ぶ必要はない。";

SourceVaultRunWorkflowResult::usage =
  "SourceVaultRunWorkflowResult[] は最後に SourceVaultRunWorkflowAsync で投入したジョブの実行結果 (View など) を \
返す (パレット「▶ 実行」後の既定取得)。SourceVaultRunWorkflowResult[arg] で特定ジョブを指定: arg は \
SourceVaultRunWorkflowAsync の返り値 Association、JobDir 文字列、または JobID 文字列 (\"job-...\")。\
内部で完了ジョブの output.wxf を読む (機密ジョブの封印はこの PC の鍵で復号。できなければ Failure[\"ResultDecryptFailed\"])。\
まだ実行中 (output.wxf 未生成) なら Missing[\"NotReady\", ...]。\
SourceVaultRunWorkflowResult[\"View\"] は最後のジョブの、SourceVaultRunWorkflowResult[arg, \"View\"] は指定のジョブの、結果の \"View\" (一覧の表示) だけを返す \
(\"View\" が無ければ結果そのもの)。";

SourceVaultRunWorkflowAsyncJobs::usage =
  "SourceVaultRunWorkflowAsyncJobs[] は SourceVaultRunWorkflowAsync で投入され現在も実行中 (output.wxf 未生成) の \
ジョブ一覧を返す。各要素 <|\"Slug\",\"Form\",\"JobID\",\"JobDir\",\"WorkflowId\",\"SubmittedAt\",\"Elapsed\"(秒)|>。\
完了/JobDir 消滅したものは呼出時に追跡から除去する。ClaudeProcessList (プロセス一覧) が実行中ワークフロー名の表示に使う。";

Begin["`WorkflowRegistryPrivate`"]

(* ---- load-time package directory capture (this file lives at package root) ---- *)
iSVWFLoadDir = Quiet @ Check[
  If[StringQ[$InputFileName] && $InputFileName =!= "",
    DirectoryName[$InputFileName], ""], ""];

(* call-time root: prefer Global`$packageDirectory, then load-time dir, then cwd *)
iSVWFPackageRoot[] := Which[
  (* Symbol[Identity[...]], not a literal Symbol["Ctx`name"]: a literal lookup that once came back unevaluated stays unevaluated on every later call (WL 15, 2026-10-30) *)
  StringQ[Quiet @ Check[Symbol[Identity["Global`$packageDirectory"]], $Failed]],
    Symbol[Identity["Global`$packageDirectory"]],
  StringQ[iSVWFLoadDir] && iSVWFLoadDir =!= "",
    iSVWFLoadDir,
  True, Directory[]];

SourceVaultWorkflowDirectory[] :=
  FileNameJoin[{iSVWFPackageRoot[], "SourceVault_workflows"}];

(* ---- stage (テスト中 / 運用中) の予約サブフォルダ ---- *)
If[! ListQ[$SourceVaultWorkflowStages],
  $SourceVaultWorkflowStages = {"testing", "production"}];
(* "archive" stage を後から確実に補う (旧値が残るカーネルでの reload にも対応)。
   末尾に置くので testing/production の探索順は不変。 *)
If[! MemberQ[$SourceVaultWorkflowStages, "archive"],
  $SourceVaultWorkflowStages = Append[$SourceVaultWorkflowStages, "archive"]];

iSVWFReservedSlugQ[slug_String] := MemberQ[$SourceVaultWorkflowStages, slug];

SourceVaultWorkflowStageDirectory[stage_String] :=
  FileNameJoin[{SourceVaultWorkflowDirectory[], stage}];

(* ---- slug -> CamelCase symbol-safe leaf ("spec-review" -> "SpecReview") ----
   A WL context/symbol leaf may NOT begin with a digit, but a slug legitimately
   can (e.g. a date-prefixed notebook name "20260622-..."). Prefix "W" in that
   case so BeginPackage["...`<leaf>`"] is a valid context. *)
iSVWFCanonicalSlug[slug_String] := Module[{parts, canon},
  parts = Select[StringSplit[slug, Except[WordCharacter] ..], # =!= "" &];
  canon = If[parts === {}, slug, StringJoin[Capitalize /@ parts]];
  If[StringQ[canon] && canon =!= "" && StringStartsQ[canon, DigitCharacter],
    "W" <> canon, canon]];

SourceVaultWorkflowContext[slug_String] :=
  "SourceVaultWorkflow`" <> iSVWFCanonicalSlug[slug] <> "`";

(* ---- resolve a slug to its actual folder across root(system) + stages ----
   探索順: root/<slug> (system; 予約 slug は除外) -> root/testing/<slug> ->
   root/production/<slug>。最初に存在したものを返す。 *)
iSVWFResolveFolder[slug_String] := Module[{root, candidates},
  root = SourceVaultWorkflowDirectory[];
  candidates = Join[
    If[iSVWFReservedSlugQ[slug], {}, {FileNameJoin[{root, slug}]}],
    (FileNameJoin[{root, #, slug}] &) /@ $SourceVaultWorkflowStages];
  SelectFirst[candidates, DirectoryQ, Missing["NotFound"]]];

SourceVaultWorkflowFolder[slug_String] := iSVWFResolveFolder[slug];

(* ---- stage of a slug: "system" (root) | "testing" | "production" | Missing ---- *)
iSVWFStageOf[slug_String] := Module[{folder, parentLeaf},
  folder = iSVWFResolveFolder[slug];
  If[MissingQ[folder], Return[Missing["NotFound"]]];
  parentLeaf = FileNameTake[DirectoryName[folder]];
  If[MemberQ[$SourceVaultWorkflowStages, parentLeaf], parentLeaf, "system"]];

(* ---- main .wl directly under <slug>/ (depth 1; excludes _info subdirs) ---- *)
iSVWFMainFile[folder_String] := Module[{wls},
  wls = FileNames["*.wl", folder];
  If[wls === {}, Missing["NoMainFile"], First[Sort[wls]]]];

iSVWFLoadedQ[ctx_String] := MemberQ[$Packages, ctx];

(* ============================================================
   2026-11-20: 読み込み検査 (LoadVerify) で止めたときの説明と次の手段
   仕様実装で生成・変更したワークフローの .wl は「モデルが書き得る群」なので、所有者が受け入れる (基準に入れる) まで
   SourceVaultLoadWorkflow は LoadDenied を返す。以前は「実行」がジョブを投入してから子プロセスで止まり、完了通知に
   理由コード (UnauthorizedInstructionLoad など) が並ぶだけで、次に何をすればよいかが出なかった (Zelkova 出欠確認で発覚)。
   - iSVWFLoadVerify: 判定。SourceVaultLoadWorkflow と投入前の確認 (SourceVaultRunWorkflowAsync) が共有する。
   - iSVWFDenied: LoadDenied の結果に、所有者が読む日本語の "Message" / "Next" と、評価できる式 "NextExpression" (文字列) を付ける。
   - iSVWFDenialCells / iSVWFWriteDenialCells: 説明の Text セルと式の Input セル (評価はしない)。セルの操作は NBAccess の API。
   受け入れ・認可は所有者の操作なので、式は SourceVaultIntegrityOwnerAction で包む (評価すると ticket の窓が出る)。
   ============================================================ *)
iSVWFLoadVerify[main_String] :=
  (* 2026-11-11 (レビュー 20261111 F05): 照合が例外・Failure で終わったら、強制の設定 ($SourceVaultIntegrityLoadVerifyEnforce、既定 True) では
     読み込まない (以前は Allow)。integrity 未ロードは厳格な設定 (強制あり・$SourceVaultIntegrityBaselineAsAuthorization False) のときだけ
     読み込まない。迷子のメッセージで結果を捨てないよう、Check でなく戻り値の形で判断する *)
  If[Length[DownValues[SourceVault`SourceVaultIntegrityLoadVerify]] > 0,
    With[{r = Quiet @ Catch[SourceVault`SourceVaultIntegrityLoadVerify[main, "Workflow"]]},
      If[AssociationQ[r] && StringQ[Lookup[r, "Decision", None]], r,
        <|"Decision" -> If[TrueQ[SourceVault`$SourceVaultIntegrityLoadVerifyEnforce], "Deny", "Warn"], "Reason" -> "VerifyError"|>]],
    <|"Decision" -> If[TrueQ[SourceVault`$SourceVaultIntegrityLoadVerifyEnforce] && SourceVault`$SourceVaultIntegrityBaselineAsAuthorization === False,
        "Deny", "Allow"], "Reason" -> "IntegrityAbsent"|>];

iSVWFStrLit[s_String] := ToString[s, InputForm];   (* "\" を二重にし、日本語はそのまま残す *)

(* 受け入れる範囲: 本体と、同じフォルダ直下の .wl (分割したワークフローの _core 等。基準の照合 InstructionDrift の対象) *)
iSVWFAcceptPaths[main_String] := DeleteDuplicates[Join[{main},
  Replace[Quiet @ Check[Sort @ FileNames["*.wl", DirectoryName[main]], {}], Except[_List] -> {}]]];

iSVWFAcceptExpression[slug_String, main_String] := StringJoin[
  "SourceVaultIntegrityOwnerAction[\n",
  "  SourceVaultIntegrityAcceptBaseline[\"Instructions\",\n",
  "    \"Paths\" -> {", StringRiffle[iSVWFStrLit /@ iSVWFAcceptPaths[main], ",\n      "], "},\n",
  "    \"Note\" -> ", iSVWFStrLit["ワークフロー " <> slug <> " を受け入れ (実行前の読み込み検査で停止)"], "]]"];

iSVWFAuthorizeExpression[main_String] := StringJoin[
  "SourceVaultIntegrityOwnerAction[\n  SourceVaultIntegrityAuthorizeInstruction[", iSVWFStrLit[main], ", \"Workflow\"]]"];

$iSVWFFindingsExpr = "SourceVaultIntegrityFindingsView[]";

(* 理由コード -> {理由の 1 文, 次の手段, 式 (文字列 | None)}。理由コードは末尾に添える (理由コードだけを返さない) *)
iSVWFDenialAdvice[slug_String, main_String, reason_String] := Module[{who, msg, next, expr},
  who = "ワークフロー「" <> slug <> "」の本体 (" <> FileNameTake[main] <> ")";
  {msg, next, expr} = Which[
    reason === "UnauthorizedInstructionLoad",
      {who <> " は、所有者がまだ受け入れていない版なので、読み込み検査で止めました。仕様実装で生成・変更したワークフローは、最初に一度だけ受け入れが要ります。",
       "中身を確かめてよければ、下の式を評価して受け入れ (所有者の ticket の窓が出ます)、もう一度実行してください。",
       iSVWFAcceptExpression[slug, main]},
    reason === "UnrecordedInstructionChange",
      {who <> " は、受け入れた後に書き換えられているので、読み込み検査で止めました。",
       "書き換えに心当たりがあり中身を確かめてよければ、下の式を評価して受け入れ、もう一度実行してください。心当たりがなければ受け入れずに " <>
         $iSVWFFindingsExpr <> " で確かめてください。",
       iSVWFAcceptExpression[slug, main]},
    reason === "AuthorizationMissing",
      {who <> " は受け入れ済みの版と一致していますが、いまの設定 ($SourceVaultIntegrityBaselineAsAuthorization が False) では命令としての認可が別に要るので、読み込み検査で止めました。",
       "下の式を評価して認可し、もう一度実行してください。認可が効くのは来歴の取り込みの後なので、数分かかることがあります。",
       iSVWFAuthorizeExpression[main]},
    StringContainsQ[reason, "Quarantined"],
      {who <> " は隔離されている版なので、読み込み検査で止めました。",
       "隔離の理由を下の式で確かめてください。", $iSVWFFindingsExpr},
    StringContainsQ[reason, "UnknownDerived"],
      {who <> " は出自が不明な派生物として記録されている版なので、読み込み検査で止めました。",
       "記録を下の式で確かめてください。", $iSVWFFindingsExpr},
    StringContainsQ[reason, "NotCommitted"],
      {who <> " の認可の記録がまだ来歴の台帳で確定していないので、読み込み検査で止めました。",
       "数分おいて (service の取り込みの後に)、もう一度実行してください。", None},
    StringContainsQ[reason, "IndexUnavailable"],
      {"来歴の索引が読めない (再構築中など) ため、" <> who <> " の版を確かめられず、読み込み検査で止めました。",
       "しばらくおいてから、もう一度実行してください。", None},
    reason === "BaselineMissing",
      {"命令ファイルの基準がまだ無く、いまの設定 (厳格) では基準の無い版を読み込まないので、" <> who <> " を止めました。",
       "下の式を評価して基準を作り、もう一度実行してください。",
       "SourceVaultIntegrityOwnerAction[SourceVaultIntegrityInitializeInstructions[]]"},
    reason === "Unreadable",
      {who <> " を読めない (内容を確かめられない) ので、読み込み検査で止めました。",
       "ファイルが別のアプリで開かれていないか、Dropbox の同期中でないかを確かめて、もう一度実行してください。", None},
    reason === "VerifyError",
      {"読み込み検査そのものがエラーで終わったので、安全側に倒して " <> who <> " を止めました。",
       "SourceVault を読み込み直してから、もう一度実行してください。", None},
    reason === "IntegrityAbsent",
      {"読み込み検査 (SourceVault_integrity.wl) が読み込まれておらず、いまの設定 (厳格) では検査なしに読み込まないので、" <> who <> " を止めました。",
       "SourceVault を読み込み直してから、もう一度実行してください。", None},
    True,
      {who <> " を読み込み検査で止めました。", "理由を下の式で確かめてください。", $iSVWFFindingsExpr}];
  <|"Message" -> msg <> " (理由コード " <> reason <> "、判定した PC " <> ToString[$MachineName] <> ")",
    "Next" -> next, "NextExpression" -> expr|>];

iSVWFDenied[slug_String, ctx_String, main_String, lv_Association] :=
  With[{adv = iSVWFDenialAdvice[slug, main, ToString @ Lookup[lv, "Reason", "Unknown"]]},
    <|"Status" -> "LoadDenied", "Message" -> adv["Message"], "Next" -> adv["Next"], "NextExpression" -> adv["NextExpression"],
      "Slug" -> slug, "Context" -> ctx, "Path" -> main,
      "LoadVerify" -> KeyTake[lv, {"Decision", "Reason", "Group", "Class", "BlobId", "Baseline"}]|>];

(* 投入前の確認: 読み込み検査だけを行い、ワークフローは読み込まない (読み込むのは子プロセス)。
   見つからない・本体が無いは以前どおり子の結果で知らせる *)
iSVWFLoadPrecheck[slug_String] := Module[{folder, main, lv},
  folder = iSVWFResolveFolder[slug];
  If[MissingQ[folder], Return[<|"Status" -> "NotFound"|>]];
  main = iSVWFMainFile[folder];
  If[MissingQ[main], Return[<|"Status" -> "NoMainFile"|>]];
  lv = iSVWFLoadVerify[main];
  If[AssociationQ[lv] && Lookup[lv, "Decision", "Deny"] === "Deny",
    iSVWFDenied[slug, SourceVaultWorkflowContext[slug], main, lv],
    <|"Status" -> "OK", "LoadVerify" -> lv|>]];

(* 説明の Text セルと、次の手段の式の Input セル (評価しない) *)
iSVWFDenialCells[d_Association] := Module[{expr = Lookup[d, "NextExpression", None]},
  Join[
    {Cell[TextData[{
        StyleBox["\:26a0 ワークフローを実行しませんでした: " <> ToString[Lookup[d, "Slug", "?"]],
          FontWeight -> "Bold", FontColor -> RGBColor[0.7, 0.1, 0.1]], "\n",
        StyleBox[ToString[Lookup[d, "Message", ""]], FontColor -> RGBColor[0.7, 0.1, 0.1]], "\n",
        ToString[Lookup[d, "Next", ""]]}],
      "Text", CellTags -> {"SourceVaultWorkflowLoadDenied"}]},
    If[StringQ[expr], {Cell[expr, "Input", CellTags -> {"SourceVaultWorkflowLoadDenied"}]}, {}]]];

(* ボタンのあるセル (ワークフロー一覧) の直後に書く。セルの番号が取れないときはノートの末尾。FE が無い・NBAccess が無いときは書かない *)
iSVWFWriteDenialCells[d_Association] := Module[{nb, idx},
  If[! TrueQ[$Notebooks] || Length[DownValues[NBAccess`NBWriteCell]] === 0, Return["NoNotebook"]];
  nb = Quiet @ Check[NBAccess`NBParentNotebookOfCurrentCell[], $Failed];
  If[Head[nb] =!= NotebookObject, Return["NoNotebook"]];
  idx = Quiet @ Check[NBAccess`NBCurrentCellIndex[nb], 0];
  iSVWFWriteDenialCellsTo[nb, If[IntegerQ[idx], idx, 0], d]];
iSVWFWriteDenialCellsTo[nb_NotebookObject, idx_Integer, d_Association] := (
  If[idx > 0, NBAccess`NBMoveAfterCell[nb, idx], NBAccess`NBMoveToEnd[nb]];
  Scan[NBAccess`NBWriteCell[nb, #] &, iSVWFDenialCells[d]];
  "Written");

(* 子の結果 (LoadFailed) に付ける日本語の説明。LoadDenied は iSVWFDenied の説明をそのまま使う *)
iSVWFLoadFailMessage[slug_String, lr_] := Module[{st = If[AssociationQ[lr], ToString @ Lookup[lr, "Status", ""], ""]},
  Which[
    st === "LoadDenied" && StringQ[Lookup[lr, "Message", None]],
      lr["Message"] <> " " <> ToString[Lookup[lr, "Next", ""]] <> " (式は \"NextExpression\")",
    st === "NotFound", "ワークフロー「" <> slug <> "」が見つかりません (SourceVault_workflows の直下・testing・production を探しました)。",
    st === "NoMainFile", "ワークフロー「" <> slug <> "」のフォルダに本体の .wl がありません。",
    st === "LoadFailed", "ワークフロー「" <> slug <> "」の本体を読み込みましたが、context (" <> ToString[Lookup[lr, "Context", "?"]] <>
      ") が登録されませんでした。本体の .wl に構文の誤りが無いかを確かめてください。",
    True, "ワークフロー「" <> slug <> "」を読み込めませんでした (" <> If[st === "", ToString[Short[lr]], st] <> ")。"]];

iSVWFRow[stage_String, folder_String] := Module[{slug = FileNameTake[folder], main, ctx},
  main = iSVWFMainFile[folder];
  ctx = SourceVaultWorkflowContext[slug];
  <|"Slug" -> slug, "Stage" -> stage, "Path" -> folder, "MainFile" -> main,
    "Context" -> ctx, "Loaded" -> iSVWFLoadedQ[ctx]|>];

SourceVaultWorkflows[] := Module[{root, systemDirs, rows},
  root = SourceVaultWorkflowDirectory[];
  If[! DirectoryQ[root], Return[{}]];
  (* system workflows: root-level dirs that are not stage containers *)
  systemDirs = Select[FileNames["*", root],
    DirectoryQ[#] && ! iSVWFReservedSlugQ[FileNameTake[#]] &];
  rows = iSVWFRow["system", #] & /@ systemDirs;
  (* staged workflows: testing/* and production/* *)
  Do[
    With[{stageDir = SourceVaultWorkflowStageDirectory[stage]},
      If[DirectoryQ[stageDir],
        rows = Join[rows,
          iSVWFRow[stage, #] & /@ Select[FileNames["*", stageDir], DirectoryQ]]]],
    {stage, $SourceVaultWorkflowStages}];
  rows];

SourceVaultLoadWorkflow[slug_String] := Module[{folder, main, ctx, lv},
  ctx = SourceVaultWorkflowContext[slug];
  folder = iSVWFResolveFolder[slug];
  If[MissingQ[folder],
    Return[<|"Status" -> "NotFound", "Slug" -> slug, "Context" -> ctx,
      "Path" -> FileNameJoin[{SourceVaultWorkflowDirectory[], slug}]|>]];
  If[iSVWFLoadedQ[ctx],
    Return[<|"Status" -> "AlreadyLoaded", "Slug" -> slug, "Context" -> ctx,
      "Path" -> iSVWFMainFile[folder]|>]];
  main = iSVWFMainFile[folder];
  If[MissingQ[main],
    Return[<|"Status" -> "NoMainFile", "Slug" -> slug, "Context" -> ctx, "Path" -> folder|>]];
  (* Inc2 (03 v0.4 §7.1 LoadVerify、2026-11-10 第 4 週): ワークフローの .wl はモデルが書き得る群。読込の直前に基準ハッシュと照合し、
     不一致・認可 (基準の受入) なしは読み込まずに返す (Finding は LoadVerify 側)。判定は iSVWFLoadVerify (F05 の扱いもそこ)。
     2026-11-20: LoadDenied に日本語の理由 "Message"・次の手段 "Next"・評価できる式 "NextExpression" を付ける (iSVWFDenied) *)
  lv = iSVWFLoadVerify[main];
  If[AssociationQ[lv] && Lookup[lv, "Decision", "Deny"] === "Deny",
    Return[iSVWFDenied[slug, ctx, main, lv]]];
  (* Load and judge success by whether the context actually registered, NOT by
     whether any message was emitted: self-bootstrapping workflows commonly emit
     benign messages (e.g. re-Get / shadowing) while still loading correctly, so
     a message-based Check produced false LoadFailed results. *)
  Quiet @ Block[{$CharacterEncoding = "UTF-8"}, Get[main]];
  <|"Status" -> If[iSVWFLoadedQ[ctx], "Loaded", "LoadFailed"],
    "Slug" -> slug, "Context" -> ctx, "Path" -> main,
    "LoadVerify" -> If[AssociationQ[lv], KeyTake[lv, {"Decision", "Reason", "Group", "Class"}], Null]|>];

(* ============================================================
   非同期実行: 生成ワークフローの launch を FRONT END を止めずに走らせる。
   新しい非同期基盤は作らず、既存の External executor
   (ClaudeRuntime externalrunner + ClaudeOrchestrator`Workflow`ClaudeSubmitExternalHeldExprJob)
   に薄く配線するだけ。安全性のため完了時はノートへ summary のみ (single committer)、
   本体 (View) は output.wxf に保存し、SourceVaultRunWorkflowResult で明示取得する。
   ============================================================ *)

(* 子カーネル本体: BootstrapFiles で SourceVault.wl をロード済みの外部プロセスで
   評価される。$Language を FE から引き継ぎ、ワークフローをロードして launch を form で呼ぶ。 *)
SourceVaultRunWorkflowChild[slug_String, form_String: "run", lang_: Automatic] :=
  Block[{$Language = If[StringQ[lang] || (ListQ[lang] && AllTrue[lang, StringQ]), lang, $Language]},
    Module[{lr, ctx, launch, sym},
      lr = SourceVaultLoadWorkflow[slug];
      (* 2026-11-20: 完了通知の Preview と結果取得で理由が読めるよう、日本語の "Message" を Status の直後に置き、
         読み込み検査で止まったときは次の手段の式 "NextExpression" も返す (別の PC で実行したときも、その PC の判定が届く) *)
      If[! (AssociationQ[lr] && MemberQ[{"Loaded", "AlreadyLoaded"}, Lookup[lr, "Status", ""]]),
        Return[<|"Status" -> "LoadFailed", "Message" -> iSVWFLoadFailMessage[slug, lr], "Slug" -> slug,
          "NextExpression" -> If[AssociationQ[lr], Lookup[lr, "NextExpression", None], None], "LoadResult" -> lr|>]];
      ctx = Lookup[lr, "Context", ""];
      launch = Quiet @ Check[Lookup[Symbol[ctx <> "WorkflowInfo"][], "Launch", ""], ""];
      If[! (StringQ[launch] && launch =!= ""),
        Return[<|"Status" -> "NoLaunch", "Slug" -> slug, "Context" -> ctx|>]];
      sym = Symbol[ctx <> launch];
      sym[form]]];   (* 実行結果 (View など) を返す。final action が output.wxf に保存 *)

(* シンボルが「実際に呼び出せる (DownValues がある)」かを、context を PARSE 時に
   固定参照せず判定する。usage だけ宣言され本体が未ロードのケースを弾く。 *)
iSVFnDefinedQ[full_String] :=
  Names[full] =!= {} &&
    TrueQ[Quiet @ Check[
      ToExpression[full, InputForm, Function[s, Length[DownValues[s]] > 0, {HoldAll}]],
      False]];

(* FE 側: External executor を稼働 (冪等) させ held 式を投入。即座に返る (FE 非ブロック)。
   base SourceVault はエンジン (ClaudeOrchestrator`Workflow`) は載せるが外部ランナー
   (ClaudeRuntime_externalrunner.wl) は載せないので、未定義なら先に Get してから activate する。
   ClaudeRuntime` / ClaudeOrchestrator`Workflow` は Symbol[] で遅延参照する。 *)
(* 2026-11-20: 実行結果の保存 (output.wxf)。ワークフローの結果は学生の名前や成績などを含みうるので、既定で機密ジョブ
   ("ConfidentialHandling" -> "EncryptedBundle"、runner が input/output.wxf を SourceVaultSealPayload で封印) にする。
   以前は平文で %APPDATA%\Wolfram\ClaudeRuntime\jobs に残り、1 MB を超えると View が要約に置き換わって一覧を取り出せなかった
   (Zelkova 出欠確認: 744 行・1.1 MB)。結果の上限は "ResultLimit" (既定 64 MB) で上げる。
   封印には SystemCredential の鍵が要る。準備ができていなければ投入せず、理由と「暗号化なしで実行する式」を出す。 *)
iSVWFConfidentialProblem[] := With[{be = If[ValueQ[NBAccess`$NBCredentialBackend], NBAccess`$NBCredentialBackend, None]},
  Which[
    Length[DownValues[SourceVault`SourceVaultSealPayload]] === 0 || Length[DownValues[SourceVault`SourceVaultUnsealPayload]] === 0,
      "暗号の部品 (SourceVault_crypto.wl) が読み込まれていない",
    ! StringQ[be],
      "鍵の保管先 (NBAccess`$NBCredentialBackend) が設定されていない",
    be =!= "SystemCredential",
      "鍵の保管先が " <> be <> " で、SystemCredential でない",
    True, None]];

iSVWFConfidentialUnavailable[slug_String, form_String, why_String] :=
  <|"Status" -> "ConfidentialUnavailable",
    "Message" -> "ワークフロー「" <> slug <> "」の実行結果は、学生の情報などを含みうるので暗号化して保存する決まりですが、この PC では暗号化の準備ができていない (" <>
      why <> ") ので、実行しませんでした。(判定した PC " <> ToString[$MachineName] <> ")",
    "Next" -> "localInit.wl などで NBAccess`$NBCredentialBackend = \"SystemCredential\" にしてから、もう一度実行してください。結果に機密の情報が無く、平文で残してよければ、下の式で暗号化せずに実行できます。",
    "NextExpression" -> "SourceVaultRunWorkflowAsync[" <> iSVWFStrLit[slug] <> ", " <> iSVWFStrLit[form] <> ", \"Confidential\" -> False]",
    "Slug" -> slug, "Reason" -> why|>;

(* 投入できなかったとき (席が無い・基盤が無いなど) の日本語の説明。理由コードは添えるだけ *)
iSVWFSubmitFailed[slug_String, sub_] := Join[
  If[AssociationQ[sub], sub, <|"Status" -> "Failed", "Result" -> sub|>],
  <|"Message" -> "ワークフロー「" <> slug <> "」のジョブを投入できませんでした (理由 " <>
      ToString[If[AssociationQ[sub], Lookup[sub, "Reason", Lookup[sub, "Status", "?"]], sub]] <> ")。",
    "Next" -> "プロセス一覧で Wolfram の席の空きを確かめ、少しおいてから、もう一度実行してください。",
    "NextExpression" -> None, "Slug" -> slug|>];

Options[SourceVaultRunWorkflowAsync] = {"LoadPrecheck" -> True, "Confidential" -> True, "ResultLimit" -> 64*1024^2};
SourceVaultRunWorkflowAsync[slug_String, form_String: "run", opts : OptionsPattern[]] :=
  Module[{nb, root, sub, pre, conf, why, rl},
    (* 2026-11-20: 投入の前に、この PC で読み込み検査を確かめる。止まるならジョブを投入せず (子プロセスと席を使わない)、
       ボタンのあるセルの直後に理由と次の手段の式を書いて LoadDenied を返す。別の PC の配車 (autotrigger) は
       "LoadPrecheck" -> False で呼ぶ: 子の結果 (LoadFailed + Message) で知らせる *)
    If[TrueQ[OptionValue["LoadPrecheck"]],
      pre = Quiet @ Check[iSVWFLoadPrecheck[slug], <|"Status" -> "PrecheckError"|>];
      If[AssociationQ[pre] && Lookup[pre, "Status", ""] === "LoadDenied",
        Return[Append[pre, "Notebook" -> Quiet @ Check[iSVWFWriteDenialCells[pre], "WriteFailed"]]]]];
    conf = TrueQ[OptionValue["Confidential"]];
    rl = OptionValue["ResultLimit"];
    If[! (IntegerQ[rl] && rl > 0), rl = Automatic];
    root = iSVWFPackageRoot[];
    (* 外部ランナー本体を確実にロード ($ClaudeExternalJobLauncher を与える) *)
    If[! iSVFnDefinedQ["ClaudeRuntime`ClaudeActivateExternalExecutor"],
      Quiet @ Check[Block[{$CharacterEncoding = "UTF-8"},
        Get[FileNameJoin[{root, "ClaudeRuntime_externalrunner.wl"}]]], Null]];
    If[! (iSVFnDefinedQ["ClaudeOrchestrator`Workflow`ClaudeSubmitExternalHeldExprJob"] &&
          iSVFnDefinedQ["ClaudeRuntime`ClaudeActivateExternalExecutor"]),
      Return[<|"Status" -> "RuntimeUnavailable",
        "Message" ->
         "非同期実行の基盤 (ClaudeOrchestrator`Workflow` エンジン / ClaudeRuntime_externalrunner) をロードできませんでした。"|>]];
    (* 2026-11-20: 実行の基盤がある (上) と分かってから、結果を封印できるかを確かめる。できなければ投入しない *)
    why = If[conf, iSVWFConfidentialProblem[], None];
    If[StringQ[why],
      With[{d = iSVWFConfidentialUnavailable[slug, form, why]},
        Return[Append[d, "Notebook" -> Quiet @ Check[iSVWFWriteDenialCells[d], "WriteFailed"]]]]];
    (* External executor を live 稼働 (launcher/killer 結線・poll tick 登録・完了 hook)。冪等 *)
    Quiet @ Check[Symbol[Identity["ClaudeRuntime`ClaudeActivateExternalExecutor"]][], Null];
    nb = Quiet[InputNotebook[]];
    sub = Symbol[Identity["ClaudeOrchestrator`Workflow`ClaudeSubmitExternalHeldExprJob"]][
      With[{s = slug, f = form, lg = $Language},
        HoldComplete[SourceVault`SourceVaultRunWorkflowChild[s, f, lg]]],
      "BootstrapFiles" -> {FileNameJoin[{root, "SourceVault.wl"}]},
      "NotifyNotebook" -> If[Head[nb] === NotebookObject, nb, None],
      (* 完了時、呼出元ノートへ評価可能な結果取得 Input セルを書かせる *)
      "ResultRetriever" -> "SourceVault`SourceVaultRunWorkflowResult",
      (* ユーザー操作起点 = FE 対話の代理実行なので、席 broker の FE 予約席へ
         食い込める優先度で取得する (FE+常駐で空き=Reserve のトポロジーでも
         恒久 NoSeat にならない)。 *)
      "SeatPriority" -> 90,
      (* 2026-11-20: 結果の封印と上限 (上の注記) *)
      "ConfidentialHandling" -> If[conf, "EncryptedBundle", "ReferenceOnly"],
      "ResultLimit" -> rl];
    (* プロセス一覧 (ClaudeProcessList) に「実行中ワークフロー名+経過」を出すため登録 *)
    If[AssociationQ[sub] && Lookup[sub, "Status", ""] === "Submitted",
      iSVRunAsyncRegister[Lookup[sub, "JobID", ""], slug, form,
        Lookup[sub, "JobDir", ""], Lookup[sub, "WorkflowId", ""]];
      Return[sub]];
    (* 2026-11-20: 投入できなかったら、ボタンのセルの直後に理由を書く (以前はエラー回数が増えるだけで何も出なかった) *)
    With[{d = iSVWFSubmitFailed[slug, sub]},
      Append[d, "Notebook" -> Quiet @ Check[iSVWFWriteDenialCells[d], "WriteFailed"]]]];

(* ---- 実行中/直近 async ジョブのレジストリ (プロセス一覧表示 + 結果取得用) ---- *)
If[! AssociationQ[$iSVRunAsyncJobs], $iSVRunAsyncJobs = <||>];
If[! StringQ[$iSVRunAsyncLast], $iSVRunAsyncLast = ""];

iSVRunAsyncRegister[jobId_String, slug_String, form_String, jobDir_, wid_] :=
  If[jobId =!= "",
    AssociateTo[$iSVRunAsyncJobs, jobId -> <|
      "Slug" -> slug, "Form" -> form, "JobDir" -> If[StringQ[jobDir], jobDir, ""],
      "WorkflowId" -> If[StringQ[wid], wid, ""], "SubmittedAt" -> AbsoluteTime[]|>];
    $iSVRunAsyncLast = jobId];   (* 最後に投入したジョブ = 引数なし結果取得の既定 *)
iSVRunAsyncRegister[___] := Null;

(* ジョブが「死んでいる (二度と完了しない)」か判定。第一根拠は status.json:
     output.wxf あり        -> 完了 (死亡でない)
     status Failed/Expired  -> 死亡
     status Running         -> 実行中 (pid.json PID=-1 でも生存。ProcessInformation が
                               PID を返さないだけで子は動く場合がある -> 誤判定しない)
     status.json 無し        -> まだ起動時書込前 or 起動失敗。投入から猶予 (120s) を過ぎて
                               なお status が無ければ死亡 (起動直後の誤判定を避ける)。
   pid.json の PID は生存判定に使わない (-1 でも実際は動くケースがあるため)。 *)
iSVJobDeadQ[jobDir_String, submittedAt_] :=
  ! FileExistsQ[FileNameJoin[{jobDir, "output.wxf"}]] &&
    Module[{st = Quiet @ Check[Import[FileNameJoin[{jobDir, "status.json"}], "RawJSON"], <||>],
            statusStr, age},
      statusStr = If[AssociationQ[st], Lookup[st, "Status", ""], ""];
      age = If[NumericQ[submittedAt], AbsoluteTime[] - submittedAt, 999999];
      Which[
        MemberQ[{"Failed", "Expired"}, statusStr], True,
        statusStr === "Running", False,
        True, TrueQ[age > 120]]];
iSVJobDeadQ[___] := True;

(* JobDir 消滅 or 死亡ジョブ = 追跡から除去。完了ジョブ (output.wxf) は結果取得のため残す。 *)
iSVRunAsyncPrune[] := (
  If[! AssociationQ[$iSVRunAsyncJobs], $iSVRunAsyncJobs = <||>];
  $iSVRunAsyncJobs = Select[$iSVRunAsyncJobs,
    Function[j, With[{jd = Lookup[j, "JobDir", ""]},
      StringQ[jd] && jd =!= "" && DirectoryQ[jd] &&
        ! iSVJobDeadQ[jd, Lookup[j, "SubmittedAt", 0]]]]];);

(* プロセス一覧が読む: 実行中 (output.wxf 未生成・起動失敗でない) のみ + 経過秒 *)
SourceVaultRunWorkflowAsyncJobs[] := Module[{now = AbsoluteTime[], running},
  iSVRunAsyncPrune[];   (* 起動失敗/消滅ジョブはここで除去済み *)
  running = Select[$iSVRunAsyncJobs,
    Function[j, ! FileExistsQ[FileNameJoin[{Lookup[j, "JobDir", ""], "output.wxf"}]]]];
  KeyValueMap[Function[{jid, j},
    Join[j, <|"JobID" -> jid,
      "Elapsed" -> Round[now - Lookup[j, "SubmittedAt", now], 1]|>]],
    running]];

(* ---- 結果取得 ---- *)
iSVReadJobOutput[jobDir_String] := Module[{f, out, r},
  f = FileNameJoin[{jobDir, "output.wxf"}];
  If[! FileExistsQ[f], Return[Missing["NotReady", jobDir]]];  (* まだ実行中/未完了 *)
  out = Quiet @ Check[Import[f, "WXF"], $Failed];
  If[out === $Failed, Return[Missing["Unreadable", f]]];
  (* 2026-11-20: 機密ジョブの output.wxf は封印 record。この PC の鍵で復号する (改ざん・鍵違いは Failure、平文には戻さない) *)
  If[TrueQ[Quiet @ Check[SourceVault`SourceVaultEncryptedRecordQ[out], False]],
    r = Quiet @ Check[SourceVault`SourceVaultUnsealPayload[out], $Failed];
    If[! (AssociationQ[r] && Lookup[r, "Status", ""] === "Ok"),
      Return[Failure["ResultDecryptFailed", <|
        "MessageTemplate" -> "実行結果の封印を、この PC の鍵で復号できませんでした (改ざん、または別の PC の鍵で封印された結果の可能性があります): `1`",
        "MessageParameters" -> {f}, "Path" -> f, "Detail" -> If[AssociationQ[r], KeyDrop[r, "Payload"], r]|>]]];
    out = r["Payload"]];
  If[AssociationQ[out] && KeyExistsQ[out, "Result"], out["Result"], out]];

(* 2026-11-20: 表示用。結果に "View" があればそれを、無ければ結果をそのまま返す (行の一覧などの大きな値を FE に出さない) *)
iSVWFViewOf[r_] := If[AssociationQ[r] && KeyExistsQ[r, "View"], r["View"], r];
iSVReadJobOutput[_] := Missing["BadJobDir"];

(* 文字列: 既存ディレクトリなら JobDir、レジストリにある JobID ならそこから、無ければ
   durable job root (ClaudeExternalJobRoot/<jobId>) から解決 (セッション跨ぎ/prune 後も
   完了通知セルの SourceVaultRunWorkflowResult["job-..."] が効くように)。 *)
SourceVaultRunWorkflowResult[jobDirOrId_String] :=
  iSVReadJobOutput @ Which[
    DirectoryQ[jobDirOrId], jobDirOrId,
    AssociationQ[$iSVRunAsyncJobs] && KeyExistsQ[$iSVRunAsyncJobs, jobDirOrId],
      Lookup[$iSVRunAsyncJobs[jobDirOrId], "JobDir", jobDirOrId],
    StringStartsQ[jobDirOrId, "job-"] &&
      iSVFnDefinedQ["ClaudeRuntime`ClaudeExternalJobRoot"] &&
      DirectoryQ[FileNameJoin[{Symbol[Identity["ClaudeRuntime`ClaudeExternalJobRoot"]][], jobDirOrId}]],
      FileNameJoin[{Symbol[Identity["ClaudeRuntime`ClaudeExternalJobRoot"]][], jobDirOrId}],
    True, jobDirOrId];
(* Association: SourceVaultRunWorkflowAsync の返り値 (JobDir を含む) *)
SourceVaultRunWorkflowResult[submit_Association] :=
  With[{d = Lookup[submit, "JobDir", ""]},
    If[StringQ[d] && d =!= "", iSVReadJobOutput[d], Missing["NoJobDir"]]];
(* 引数なし: 最後に投入したジョブの結果 (パレット「▶ 実行」後の既定取得) *)
SourceVaultRunWorkflowResult[] :=
  If[StringQ[$iSVRunAsyncLast] && $iSVRunAsyncLast =!= "" &&
     AssociationQ[$iSVRunAsyncJobs] && KeyExistsQ[$iSVRunAsyncJobs, $iSVRunAsyncLast],
    iSVReadJobOutput[Lookup[$iSVRunAsyncJobs[$iSVRunAsyncLast], "JobDir", ""]],
    Missing["NoRecentJob"]];
(* 2026-11-20: 一覧の表示。["View"] は最後のジョブ、[job, "View"] はそのジョブの View (job は JobID・JobDir・投入の返り値) *)
SourceVaultRunWorkflowResult["View"] := iSVWFViewOf[SourceVaultRunWorkflowResult[]];
SourceVaultRunWorkflowResult[arg : (_String | _Association), "View"] := iSVWFViewOf[SourceVaultRunWorkflowResult[arg]];
SourceVaultRunWorkflowResult[_] := Missing["BadArgument"];

End[]  (* `WorkflowRegistryPrivate` *)

EndPackage[]
