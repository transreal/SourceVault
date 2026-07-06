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
ワークフロー本体は依存 (ClaudeOrchestrator`Workflow` / SourceVault`) を自己ブートストラップする。";

SourceVaultRunWorkflowAsync::usage =
  "SourceVaultRunWorkflowAsync[slug, form:\"run\"] は生成ワークフローの launch entry を \
既存の External executor (ClaudeRuntime / ClaudeOrchestrator`Workflow`) 経由で FRONT END を止めずに \
非同期実行する。子プロセス (wolframscript) が SourceVaultRunWorkflowChild[slug, form, $Language] を評価し、\
完了時に single committer が呼出元ノートへ summary セルを書く (本体 View は inline せず output.wxf に保存)。\
返り値: <|\"Status\"->\"Submitted\",\"JobID\",\"JobDir\",\"WorkflowId\",\"Head\"|> または \
<|\"Status\"->\"RuntimeUnavailable\"|\"Failed\", ...|>。実行結果 (View) は SourceVaultRunWorkflowResult で取り出す。\
前提: ClaudeRuntime (externalrunner) と ClaudeOrchestrator`Workflow` がロード済みであること。";

SourceVaultRunWorkflowChild::usage =
  "SourceVaultRunWorkflowChild[slug, form:\"run\", lang:Automatic] は外部子カーネルで評価される本体: \
$Language を lang に束ねてワークフローをロードし、launch entry を form で呼んで結果を返す。\
通常 SourceVaultRunWorkflowAsync が held 式として投入するので直接呼ぶ必要はない。";

SourceVaultRunWorkflowResult::usage =
  "SourceVaultRunWorkflowResult[] は最後に SourceVaultRunWorkflowAsync で投入したジョブの実行結果 (View など) を \
返す (パレット「▶ 実行」後の既定取得)。SourceVaultRunWorkflowResult[arg] で特定ジョブを指定: arg は \
SourceVaultRunWorkflowAsync の返り値 Association、JobDir 文字列、または JobID 文字列 (\"job-...\")。\
内部で完了ジョブの output.wxf を読む。まだ実行中 (output.wxf 未生成) なら Missing[\"NotReady\", ...]。";

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
  StringQ[Quiet @ Check[Symbol["Global`$packageDirectory"], $Failed]],
    Symbol["Global`$packageDirectory"],
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

SourceVaultLoadWorkflow[slug_String] := Module[{folder, main, ctx},
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
  (* Load and judge success by whether the context actually registered, NOT by
     whether any message was emitted: self-bootstrapping workflows commonly emit
     benign messages (e.g. re-Get / shadowing) while still loading correctly, so
     a message-based Check produced false LoadFailed results. *)
  Quiet @ Block[{$CharacterEncoding = "UTF-8"}, Get[main]];
  <|"Status" -> If[iSVWFLoadedQ[ctx], "Loaded", "LoadFailed"],
    "Slug" -> slug, "Context" -> ctx, "Path" -> main|>];

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
      If[! (AssociationQ[lr] && MemberQ[{"Loaded", "AlreadyLoaded"}, Lookup[lr, "Status", ""]]),
        Return[<|"Status" -> "LoadFailed", "Slug" -> slug, "LoadResult" -> lr|>]];
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
SourceVaultRunWorkflowAsync[slug_String, form_String: "run"] :=
  Module[{nb, root, sub},
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
    (* External executor を live 稼働 (launcher/killer 結線・poll tick 登録・完了 hook)。冪等 *)
    Quiet @ Check[Symbol["ClaudeRuntime`ClaudeActivateExternalExecutor"][], Null];
    nb = Quiet[InputNotebook[]];
    sub = Symbol["ClaudeOrchestrator`Workflow`ClaudeSubmitExternalHeldExprJob"][
      With[{s = slug, f = form, lg = $Language},
        HoldComplete[SourceVault`SourceVaultRunWorkflowChild[s, f, lg]]],
      "BootstrapFiles" -> {FileNameJoin[{root, "SourceVault.wl"}]},
      "NotifyNotebook" -> If[Head[nb] === NotebookObject, nb, None],
      (* 完了時、呼出元ノートへ評価可能な結果取得 Input セルを書かせる *)
      "ResultRetriever" -> "SourceVault`SourceVaultRunWorkflowResult"];
    (* プロセス一覧 (ClaudeProcessList) に「実行中ワークフロー名+経過」を出すため登録 *)
    If[AssociationQ[sub] && Lookup[sub, "Status", ""] === "Submitted",
      iSVRunAsyncRegister[Lookup[sub, "JobID", ""], slug, form,
        Lookup[sub, "JobDir", ""], Lookup[sub, "WorkflowId", ""]]];
    sub];

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
iSVReadJobOutput[jobDir_String] := Module[{f, out},
  f = FileNameJoin[{jobDir, "output.wxf"}];
  If[! FileExistsQ[f], Return[Missing["NotReady", jobDir]]];  (* まだ実行中/未完了 *)
  out = Quiet @ Check[Import[f, "WXF"], $Failed];
  If[out === $Failed, Return[Missing["Unreadable", f]]];
  If[AssociationQ[out] && KeyExistsQ[out, "Result"], out["Result"], out]];
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
      DirectoryQ[FileNameJoin[{Symbol["ClaudeRuntime`ClaudeExternalJobRoot"][], jobDirOrId}]],
      FileNameJoin[{Symbol["ClaudeRuntime`ClaudeExternalJobRoot"][], jobDirOrId}],
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
SourceVaultRunWorkflowResult[_] := Missing["BadArgument"];

End[]  (* `WorkflowRegistryPrivate` *)

EndPackage[]
