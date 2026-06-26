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

End[]  (* `WorkflowRegistryPrivate` *)

EndPackage[]
