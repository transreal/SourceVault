(* ::Package:: *)

(* SourceVault codified workflow:                                              *)
(*   Slug : source-change integrated documentation update spec v5             *)
(* This package detects source-code changes in target packages and, when a    *)
(* change is found, drives ClaudeUpdateDocumentation to keep api/user_manual/  *)
(* README/example (and setup when relevant) consistent with the source.       *)
(* All Japanese text is written with \:XXXX unicode escapes per project rule. *)

BeginPackage["SourceVaultWorkflow`\:30bd\:30fc\:30b9\:30b3\:30fc\:30c9\:5909\:66f4\:6642\:306e\:7d71\:5408\:30c9\:30ad\:30e5\:30e1\:30f3\:30c8\:30a2\:30c3\:30d7\:30c7\:30fc\:30c8\:4ed5\:69d8V5`"]

WorkflowInfo::usage =
  "WorkflowInfo[] returns the metadata association describing this workflow (Slug, Name, Version, Context, Launch, Description, Routes).";

IntegratedDocUpdateWorkflow::usage =
  "IntegratedDocUpdateWorkflow[] detects target packages whose source code changed and that need documentation updates, returning a side-effect-free report. " <>
  "IntegratedDocUpdateWorkflow[spec] restricts detection to spec (a package name string, a list of names, Automatic, or All). " <>
  "IntegratedDocUpdateWorkflow[spec, \"Execute\"->True] runs ClaudeUpdateDocumentation for each changed package. Option \"Force\"->True treats every existing target as changed; \"Instruction\"->str overrides the update instruction.";

$IntegratedDocUpdateTargets::usage =
  "$IntegratedDocUpdateTargets is the ordered list of target package names this workflow watches.";

Begin["`Private`"]

(* ----------------------------------------------------------------------- *)
(* Metadata strings (escaped Japanese)                                     *)
(* ----------------------------------------------------------------------- *)

$context = "SourceVaultWorkflow`\:30bd\:30fc\:30b9\:30b3\:30fc\:30c9\:5909\:66f4\:6642\:306e\:7d71\:5408\:30c9\:30ad\:30e5\:30e1\:30f3\:30c8\:30a2\:30c3\:30d7\:30c7\:30fc\:30c8\:4ed5\:69d8V5`";

$slug = "\:30bd\:30fc\:30b9\:30b3\:30fc\:30c9\:5909\:66f4\:6642\:306e\:7d71\:5408\:30c9\:30ad\:30e5\:30e1\:30f3\:30c8\:30a2\:30c3\:30d7\:30c7\:30fc\:30c8\:4ed5\:69d8-v5";

$name = "\:30bd\:30fc\:30b9\:30b3\:30fc\:30c9\:5909\:66f4\:6642\:306e\:7d71\:5408\:30c9\:30ad\:30e5\:30e1\:30f3\:30c8\:30a2\:30c3\:30d7\:30c7\:30fc\:30c8\:4ed5\:69d8";

$version = "5.0.0";

$desc = "\:5bfe\:8c61\:30d1\:30c3\:30b1\:30fc\:30b8\:306e\:30bd\:30fc\:30b9\:5909\:66f4\:3092\:691c\:51fa\:3057\:3001ClaudeUpdateDocumentation \:3067 docs \:3092\:4e00\:8cab\:66f4\:65b0\:3059\:308b\:30ef\:30fc\:30af\:30d5\:30ed\:30fc\:3002";

$defaultInstruction = "\:30bd\:30fc\:30b9\:5909\:66f4\:3092 docs/api.md, docs/user_manual.md, docs/README.md, docs/examples/example.md \:306b\:53cd\:6620\:3059\:308b\:3002\:30bb\:30c3\:30c8\:30a2\:30c3\:30d7\:306b\:5f71\:97ff\:3059\:308b\:5834\:5408\:306f docs/setup.md \:3082\:66f4\:65b0\:3059\:308b\:3002examples.md \:306f\:4f5c\:6210\:3057\:306a\:3044\:3002\:5909\:66f4\:7bc4\:56f2\:306b\:9650\:5b9a\:3059\:308b\:3002";

(* ----------------------------------------------------------------------- *)
(* Target packages (approved spec)                                         *)
(* ----------------------------------------------------------------------- *)

$systemTargets = {"NBAccess", "claudecode", "ClaudeRuntime", "ClaudeOrchestrator", "SourceVault"};
$auxTargets    = {"github", "ClaudeTestKit", "PDFIndex", "documentation"};

$IntegratedDocUpdateTargets = Join[$systemTargets, $auxTargets];

(* ----------------------------------------------------------------------- *)
(* Dependency self-bootstrap (best-effort, guarded)                        *)
(* ----------------------------------------------------------------------- *)

$pkgRoot = Module[{ipkgd=DirectoryName[$InputFileName]},While[ipkgd=!=DirectoryName[ipkgd]&&!FileExistsQ[FileNameJoin[{ipkgd,"SourceVault.wl"}]],ipkgd=DirectoryName[ipkgd]];ipkgd];

bootstrapDep[fileParts_List, readyQ_] := Module[{f},
  If[TrueQ[readyQ], Return[Null]];
  f = FileNameJoin[Join[{$pkgRoot}, fileParts]];
  If[FileExistsQ[f], Quiet @ Check[Get[f], Null]];
];

claudeDocReadyQ[] := (Names["*`ClaudeUpdateDocumentation"] =!= {}) || (Names["ClaudeUpdateDocumentation"] =!= {});

(* claudecode / ClaudeRuntime usually provide ClaudeUpdateDocumentation;    *)
(* SourceVault provides the registry loader. All loads are guarded so a     *)
(* missing file is harmless.                                                *)
bootstrapDep[{"claudecode.wl"}, claudeDocReadyQ[]];
bootstrapDep[{"ClaudeRuntime.wl"}, claudeDocReadyQ[]];
bootstrapDep[{"SourceVault.wl"}, Names["SourceVault`*"] =!= {}];

(* ----------------------------------------------------------------------- *)
(* Symbol / package-directory resolution                                   *)
(* ----------------------------------------------------------------------- *)

selfContextQ[s_String] := StringStartsQ[s, "SourceVaultWorkflow`"];

packageDirectory[] := Module[{cands, v},
  cands = DeleteCases[Names["*`$packageDirectory"], _?selfContextQ];
  Do[
    v = Quiet @ ToExpression[c];
    If[StringQ[v] && DirectoryQ[v], Return[v, Module]],
    {c, cands}
  ];
  $pkgRoot
];

docUpdateFn[] := Module[{cands},
  cands = DeleteCases[Names["*`ClaudeUpdateDocumentation"], _?selfContextQ];
  If[cands === {}, cands = Names["ClaudeUpdateDocumentation"]];
  If[cands === {}, Missing["NotFound"], First[cands]]
];

(* ----------------------------------------------------------------------- *)
(* Package layout helpers                                                   *)
(* ----------------------------------------------------------------------- *)

pkgKind[dir_, name_] := Which[
  FileExistsQ[FileNameJoin[{dir, name <> ".wl"}]], "Single",
  DirectoryQ[FileNameJoin[{dir, name}]], "Paclet",
  True, "Missing"
];

infoDir[dir_, name_, kind_] := Switch[kind,
  "Single", FileNameJoin[{dir, name <> "_info"}],
  "Paclet", FileNameJoin[{dir, name}],
  _, Missing["NoPackage"]
];

docsDir[dir_, name_, kind_] := Module[{i = infoDir[dir, name, kind]},
  If[MissingQ[i], i, FileNameJoin[{i, "docs"}]]
];

sourceFiles[dir_, name_, kind_] := Switch[kind,
  "Single", Select[{FileNameJoin[{dir, name <> ".wl"}]}, FileExistsQ],
  "Paclet",
    Module[{base = FileNameJoin[{dir, name}], ddir, all},
      ddir = FileNameJoin[{base, "docs"}];
      all = Quiet @ FileNames[{"*.wl", "*.m"}, base, Infinity];
      Select[all, ! StringStartsQ[#, ddir] &]
    ],
  _, {}
];

latestDate[files_List] := Module[{ds},
  ds = Quiet @ Map[FileDate, Select[files, FileExistsQ]];
  ds = Select[ds, MatchQ[#, _DateObject] &];
  If[ds === {}, Missing["NoFiles"], Max[ds]]
];

sourceModified[dir_, name_, kind_] := latestDate[sourceFiles[dir, name, kind]];

docsModified[dir_, name_, kind_] := Module[{d = docsDir[dir, name, kind]},
  If[MissingQ[d] || ! DirectoryQ[d],
    Missing["NoDocs"],
    latestDate[Quiet @ FileNames["*.md", d, Infinity]]
  ]
];

(* ----------------------------------------------------------------------- *)
(* ClaudeUpdatePackage update record / changed-file probing.               *)
(* The approved spec requires that change detection consult update history, *)
(* changed-file lists, or package update records -- NOT git diff alone.     *)
(* We probe the package's _info area for any update-record / backup trail   *)
(* left by ClaudeUpdatePackage and derive a coarse "last update" timestamp  *)
(* plus a changed-file list when one is recorded. Everything is guarded so  *)
(* the absence of such records degrades gracefully to file-time detection.  *)
(* ----------------------------------------------------------------------- *)

$updateRecordFiles = {
  "update_history.json", "update-history.json", "history.json",
  "ClaudeUpdatePackage_history.json", "update_log.json", "updates.json", "changes.json"
};

extractChangedFiles[data_] := Module[{rec = data, val},
  If[ListQ[rec] && rec =!= {}, rec = Last[rec]];
  val = Which[
    AssociationQ[rec] && KeyExistsQ[rec, "ChangedFiles"], rec["ChangedFiles"],
    AssociationQ[rec] && KeyExistsQ[rec, "changedFiles"], rec["changedFiles"],
    AssociationQ[rec] && KeyExistsQ[rec, "files"], rec["files"],
    AssociationQ[rec] && KeyExistsQ[rec, "Files"], rec["Files"],
    True, {}
  ];
  If[ListQ[val], val, {}]
];

updateRecord[dir_, name_, kind_] := Module[
  {idir, cand, recTime, changed, jsons, newest, data},
  idir = infoDir[dir, name, kind];
  If[MissingQ[idir] || ! DirectoryQ[idir], Return[Missing["NoInfoDir"]]];
  cand = DeleteDuplicates @ Join[
    Select[FileNameJoin[{idir, #}] & /@ $updateRecordFiles, FileExistsQ],
    Quiet @ FileNames["*.json", FileNameJoin[{idir, "history"}], Infinity],
    Quiet @ FileNames["*.json", FileNameJoin[{idir, "updates"}], Infinity],
    Quiet @ FileNames["*", FileNameJoin[{idir, "backups"}], Infinity]
  ];
  cand = Select[cand, FileExistsQ];
  If[cand === {}, Return[Missing["NoRecord"]]];
  recTime = latestDate[cand];
  changed = {};
  jsons = Select[cand, StringEndsQ[#, ".json"] &];
  If[jsons =!= {},
    newest = Last @ SortBy[jsons, FileDate];
    data = Quiet @ Check[Import[newest, "RawJSON"], $Failed];
    If[data =!= $Failed, changed = extractChangedFiles[data]];
  ];
  <|"Time" -> recTime, "ChangedFiles" -> changed, "RecordFiles" -> cand|>
];

(* ----------------------------------------------------------------------- *)
(* Per-package change decision                                             *)
(* ----------------------------------------------------------------------- *)

decidePackage[dir_, name_] := Module[
  {kind, sm, dm, rec, recTime, changed, reason, action},
  kind = pkgKind[dir, name];
  If[kind === "Missing",
    Return[<|
      "Package" -> name, "Kind" -> "Missing",
      "SourceModified" -> Missing["NoPackage"],
      "DocsModified" -> Missing["NoPackage"],
      "UpdateRecord" -> Missing["NoPackage"],
      "Changed" -> False,
      "Reason" -> "package not found in package directory",
      "Action" -> "skip-not-found"
    |>]
  ];
  sm = sourceModified[dir, name, kind];
  dm = docsModified[dir, name, kind];
  rec = updateRecord[dir, name, kind];
  recTime = If[AssociationQ[rec] && MatchQ[rec["Time"], _DateObject], rec["Time"], Missing["NoTime"]];
  Which[
    MissingQ[dm],
      changed = True; reason = "documentation missing"; action = "update-docs",
    (! MissingQ[recTime] && recTime > dm),
      changed = True; reason = "ClaudeUpdatePackage record newer than docs"; action = "update-docs",
    (! MissingQ[sm] && sm > dm),
      changed = True; reason = "source newer than docs"; action = "update-docs",
    True,
      changed = False; reason = "docs up to date"; action = "none"
  ];
  <|
    "Package" -> name, "Kind" -> kind,
    "SourceModified" -> sm, "DocsModified" -> dm,
    "UpdateRecord" -> rec,
    "Changed" -> changed, "Reason" -> reason, "Action" -> action
  |>
];

(* ----------------------------------------------------------------------- *)
(* Target normalization                                                     *)
(* ----------------------------------------------------------------------- *)

normalizeTargets[spec_] := Which[
  spec === Automatic || spec === All, $IntegratedDocUpdateTargets,
  StringQ[spec], {spec},
  ListQ[spec], spec,
  True, $IntegratedDocUpdateTargets
];

(* ----------------------------------------------------------------------- *)
(* Public launch entry                                                      *)
(* ----------------------------------------------------------------------- *)

Options[IntegratedDocUpdateWorkflow] = {"Execute" -> False, "Force" -> False, "Instruction" -> Automatic};

IntegratedDocUpdateWorkflow[opts : OptionsPattern[]] :=
  IntegratedDocUpdateWorkflow[Automatic, opts];

IntegratedDocUpdateWorkflow[spec : (_String | _List | Automatic | All), opts : OptionsPattern[]] := Module[
  {dir, requested, known, unknown, force, exec, instr, detections, pending, fnName, results},
  dir = packageDirectory[];
  requested = normalizeTargets[spec];
  known = Select[requested, MemberQ[$IntegratedDocUpdateTargets, #] &];
  unknown = Complement[requested, $IntegratedDocUpdateTargets];
  force = TrueQ @ OptionValue["Force"];
  exec = TrueQ @ OptionValue["Execute"];
  instr = OptionValue["Instruction"];
  If[instr === Automatic || ! StringQ[instr], instr = $defaultInstruction];

  detections = decidePackage[dir, #] & /@ known;
  If[force,
    detections = Map[
      If[#["Kind"] =!= "Missing",
        <|#, "Changed" -> True, "Action" -> "update-docs", "Reason" -> "forced"|>,
        #
      ] &,
      detections
    ]
  ];

  pending = #["Package"] & /@ Select[detections, TrueQ[#["Changed"]] && #["Action"] === "update-docs" &];

  If[! exec,
    Return[<|
      "Slug" -> $slug,
      "Mode" -> "Report",
      "PackageDirectory" -> dir,
      "Targets" -> known,
      "UnknownRequested" -> unknown,
      "Detections" -> detections,
      "Pending" -> pending,
      "Note" -> "No side effects. To apply ClaudeUpdateDocumentation, call with \"Execute\"->True."
    |>]
  ];

  fnName = docUpdateFn[];
  If[MissingQ[fnName],
    Return[<|
      "Slug" -> $slug,
      "Mode" -> "Execute",
      "PackageDirectory" -> dir,
      "Targets" -> known,
      "UnknownRequested" -> unknown,
      "Detections" -> detections,
      "Pending" -> pending,
      "Results" -> <||>,
      "Error" -> "ClaudeUpdateDocumentation is not available in this kernel."
    |>]
  ];

  results = AssociationMap[
    Function[pkg, Quiet @ Check[ToExpression[fnName][pkg, instr], $Failed]],
    pending
  ];

  <|
    "Slug" -> $slug,
    "Mode" -> "Execute",
    "PackageDirectory" -> dir,
    "Targets" -> known,
    "UnknownRequested" -> unknown,
    "Detections" -> detections,
    "Pending" -> pending,
    "Instruction" -> instr,
    "Results" -> results
  |>
];

(* ----------------------------------------------------------------------- *)
(* Workflow metadata                                                        *)
(* ----------------------------------------------------------------------- *)

WorkflowInfo[] := <|
  "Slug" -> $slug,
  "Name" -> $name,
  "Version" -> $version,
  "Context" -> $context,
  "Launch" -> "IntegratedDocUpdateWorkflow",
  "Description" -> $desc,
  "Routes" -> {}
|>;

End[]

EndPackage[]