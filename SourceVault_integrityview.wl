(* ::Package:: *)

(* ============================================================
   SourceVault_integrityview.wl -- 知識ネットワーク健全性監視 (03 SystemDoctor 拡張仕様 v0.4) の View (10 章、Inc5 2026-11-10)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_integrityview.wl"]]

   位置づけ: FE カーネル専用。core 関数 (SourceVault_integrity.wl / SourceVault_provenance.wl) が返す Association を表示するだけ
   (core/View 分離)。表示するのは ID・件数・ラベル・LogicalRef までで、Entity の本文は出さない。
   行の操作は記入済みの式テンプレートを下のセルに置く (式中心の UI)。所有者操作は SourceVaultIntegrityOwnerAction[...] で包み、
   評価すると確認 → ticket のダイアログ → 実行になる。Dataset のボタンは 1 列目のタグ + ItemDisplayFunction (maildb の正準の規約)。
   ============================================================ *)

BeginPackage["SourceVault`"]

SourceVaultKnowledgeHealthView::usage =
  "SourceVaultKnowledgeHealthView[] は知識ネットワークの健全性のダッシュボード (03 v0.4 §10.1): 表 8.1 の指標 (未解決の重大 Finding・来歴の充足率・\n" <>
  "隔離中の版)、部品別の状態 (ボタンで FindingsView の式を置く)、Kind × 出自の区分の分布、KHI (参考値、判定に使わない)。FE 専用。";
SourceVaultIntegrityFindingsView::usage =
  "SourceVaultIntegrityFindingsView[opts] は Entity の Finding の一覧 (03 v0.4 §10.3): 重大度・部品・種類・対象・影響範囲・状態。行の操作 (系譜 / 確認の記録 /\n" <>
  "隔離 / 解決) は式テンプレートを下のセルに置く。opts: \"Status\" -> \"Open\" | All, \"Component\" -> All | name, \"Limit\" -> 100。FE 専用。";
SourceVaultLineageView::usage =
  "SourceVaultLineageView[ref, opts] は版の系譜 (03 v0.4 §10.2): 色は利用可否 (Usable 緑 / Pending 灰青 / Quarantined 赤 / Unknown 灰)、ラベルに出自の区分、\n" <>
  "Cite の辺は点線 (隔離を伝えない)。opts: \"Direction\" -> \"Up\" | \"Down\" | \"Both\", \"Depth\" -> 3, \"Kinds\" -> All。FE 専用。";
SourceVaultInstructionsView::usage =
  "SourceVaultInstructionsView[] は Instruction 系ファイルの一覧 (03 v0.4 §10.3): 群 (手編集 / モデルが書き得る)・種別・基準との一致・認可の有無と用途。\n" <>
  "操作: 基準の一括受入 / 認可の式テンプレート。FE 専用。";
SourceVaultModelManifestView::usage =
  "SourceVaultModelManifestView[] は LM Studio のモデル manifest (03 v0.4 §10.3): モデルごとの形式・大きさ・テンプレートの digest・同一性の証拠と、基準との差。FE 専用。";
SourceVaultProvenanceCoverageView::usage =
  "SourceVaultProvenanceCoverageView[] は記録点ごとの来歴の充足率 (03 v0.4 §10.3、Kind 別の Complete の割合) と記録の無い LLMCall の件数。FE 専用。";

Begin["`IntegrityViewPrivate`"]

$iSVIVColor = <|"OK" -> RGBColor[0.16, 0.55, 0.30], "Degraded" -> RGBColor[0.85, 0.55, 0.10], "Failing" -> RGBColor[0.80, 0.15, 0.15]|>;
$iSVIVUsabilityColor = <|"Usable" -> RGBColor[0.30, 0.65, 0.35], "Pending" -> RGBColor[0.55, 0.62, 0.75], "Quarantined" -> RGBColor[0.85, 0.20, 0.20],
  "Unknown" -> GrayLevel[0.6], "Recorded" -> GrayLevel[0.85]|>;
iSVIVHealth[h_] := Style[ToString[h], Bold, Lookup[$iSVIVColor, h, GrayLevel[0.4]]];
iSVIVText[s_] := Style[ToString[s], "Text", 11];
iSVIVSmall[s_] := Style[ToString[s], "Text", 9, GrayLevel[0.45]];
iSVIVShort[s_String] := If[StringLength[s] > 18, StringTake[s, 14] <> "\[Ellipsis]", s];
iSVIVShort[s_] := ToString[s];

(* 式テンプレートを下のセルに置く (評価しない)。HoldComplete で受けて MakeBoxes で箱にする。
   セルの操作は NBAccess の API だけで行う (core/View 分離の規約): ボタンのあるセルの番号の直後へ移って Input セルを書く。
   セルの番号が取れないとき (パレットなど) は入力ノートの選択位置に書く *)
iSVIVInsert[h : HoldComplete[_]] := Module[{boxes, nb, idx},
  (* 保持したままの <|...|> は Association[...] と表示されるので、連想だけ評価して <|...|> の形にする *)
  boxes = Replace[h /. HoldPattern[Association[r___]] :> With[{a = Association[r]}, a /; True], HoldComplete[x_] :> MakeBoxes[x, StandardForm]];
  If[Length[DownValues[NBAccess`NBInsertInputTemplate]] === 0, Return[$Failed]];
  nb = Quiet @ Check[NBAccess`NBParentNotebookOfCurrentCell[], $Failed];
  If[Head[nb] =!= NotebookObject, Return[$Failed]];
  idx = Quiet @ Check[NBAccess`NBCurrentCellIndex[nb], 0];
  If[IntegerQ[idx] && idx > 0, NBAccess`NBMoveAfterCell[nb, idx]];
  NBAccess`NBInsertInputTemplate[nb, boxes]];
SetAttributes[iSVIVButton, HoldRest];
iSVIVButton[label_, expr_] := Button[Style[label, 10], iSVIVInsert[HoldComplete[expr]], Appearance -> "Frameless", Method -> "Queued",
  BaseStyle -> {FontColor -> RGBColor[0.15, 0.35, 0.70]}];

iSVIVProv[name_String, args___] := With[{f = Symbol["SourceVault`ProvenancePrivate`" <> name]},
  If[Length[DownValues[f]] > 0, Quiet @ Check[f[args], $Failed], $Failed]];

(* ---- 10.1 KnowledgeHealthView ---- *)
SourceVaultKnowledgeHealthView[] := Module[{kh = Quiet @ Check[SourceVault`SourceVaultKnowledgeHealth[], $Failed], comps, ind, at, age, ck, tot, comp, instr, q, unres, khi, dist, ocs},
  If[! AssociationQ[kh],
    Return[Panel[Column[{Style["Knowledge Network Health", Bold, 14], iSVIVText["state.json がありません (service の検証器がまだ動いていません)。"]}]]]];
  comps = Lookup[kh, "Components", <||>]; ind = Lookup[kh, "Indicators", <||>]; If[! AssociationQ[ind], ind = <||>];
  at = Lookup[kh, "ComputedAtUTC", Null];
  age = With[{a = If[StringQ[at], Quiet @ Check[AbsoluteTime[DateObject[at, TimeZone -> 0]], $Failed], $Failed]}, If[NumberQ[a], Round[AbsoluteTime[] - a], Null]];
  ck = Lookup[ind, "CompletenessByKind", <||>]; If[! AssociationQ[ck], ck = <||>];
  (* 2026-11-11 (レビュー 20261111 F07): 総率は Instruction を除く (Instruction の基準の充足は右に別に出す) *)
  tot = Total[Lookup[Values[KeyDrop[ck, "Instruction"]], "Total", 0]]; comp = Total[Lookup[Values[KeyDrop[ck, "Instruction"]], "Complete", 0]];
  instr = Lookup[ck, "Instruction", <||>];
  q = Total[Values[Lookup[ind, "QuarantinedByKind", <||>]]];
  unres = Lookup[ind, "UnresolvedSevere", <||>];
  khi = Lookup[ind, "KHI", Null];
  dist = Lookup[ind, "Distribution", <||>]; If[! AssociationQ[dist], dist = <||>];
  ocs = {"OwnerOnly", "ModelOverOwner", "ExternalDerived", "Unknown"};
  Panel[Column[{
    Row[{Style["Knowledge Network Health", Bold, 14], "   ", iSVIVSmall["状態の時刻 " <> ToString[at] <> If[IntegerQ[age], " (" <> ToString[age] <> " 秒前)", ""]]}],
    Grid[{
      {iSVIVText["未解決の重大 Finding"], Style[ToString @ Lookup[unres, "Count", 0], Bold, 14], iSVIVSmall["うち Instruction 系 " <> ToString @ Lookup[unres, "Instruction", 0]]},
      {iSVIVText["来歴の充足率 (活性な版、Instruction を除く)"], Style[If[tot > 0, ToString[Round[100. comp/tot]] <> "%", "-"], Bold, 14],
        iSVIVSmall["Instruction " <> If[AssociationQ[instr] && Lookup[instr, "Total", 0] > 0, ToString[Round[100. instr["Ratio"]]] <> "%", "-"]]},
      {iSVIVText["隔離中の版"], Style[ToString[q], Bold, 14], iSVIVSmall["レビュー債務 " <> ToString @ Lookup[Lookup[ind, "ReviewDebt", <||>], "Top", 0]]},
      {iSVIVText["KHI (参考値)"], Style[If[NumberQ[khi], ToString[NumberForm[khi, {4, 1}]], "-"], 11, GrayLevel[0.4]],
        iSVIVSmall["構成比で変わる経験的な値。判定には使いません"]}}, Alignment -> Left, Spacings -> {2, 0.6}],
    Style["部品", Bold, 12],
    Grid[Prepend[KeyValueMap[Function[{name, c}, {iSVIVText[name], iSVIVHealth[Lookup[c, "Health", "?"]], iSVIVSmall[Lookup[c, "ReasonCode", ""]],
        With[{n = name}, iSVIVButton["Finding", SourceVaultIntegrityFindingsView["Component" -> n]]]}], comps],
      {iSVIVSmall["部品"], iSVIVSmall["状態"], iSVIVSmall["理由"], ""}], Alignment -> Left, Spacings -> {1.5, 0.4},
      Dividers -> {False, {False, True}}],
    Style["Kind \[Times] 出自の区分 (活性な版の数)", Bold, 12],
    If[dist === <||>, iSVIVSmall["(活性な版がありません)"],
      Grid[Prepend[KeyValueMap[Function[{k, row}, Join[{iSVIVText[k]}, (ToString @ Lookup[row, #, 0] &) /@ ocs,
          {Style[ToString @ Lookup[Lookup[ind, "QuarantinedByKind", <||>], k, 0], RGBColor[0.8, 0.15, 0.15]]}]], dist],
        Join[{""}, iSVIVSmall /@ {"Owner", "Model", "Ext.", "Unknown", "隔離中"}]], Alignment -> {{Left, Right, Right, Right, Right, Right}}, Spacings -> {1.5, 0.3}]]},
    Spacings -> 1]]];

(* ---- FindingsView: 行の操作は 1 列目のタグ、表示関数で組む ---- *)
iSVIVFindingRow[fid_String, tgt_] := Row[{
  If[StringQ[tgt], With[{t = tgt}, iSVIVButton["系譜", SourceVaultLineageView[t]]], ""], " ",
  If[StringQ[tgt], With[{t = tgt}, iSVIVButton["確認", SourceVaultIntegrityOwnerAction[SourceVaultIntegrityRecordOwnerReview[t, "範囲を書く", "メモ"]]]], ""], " ",
  If[StringQ[tgt], With[{t = tgt}, iSVIVButton["隔離", SourceVaultIntegrityOwnerAction[SourceVaultIntegrityQuarantine[t, "理由を書く"]]]], ""], " ",
  With[{f = fid}, iSVIVButton["解決", SourceVaultIntegrityOwnerAction[SourceVaultIntegrityResolveFinding[f, <|"Kind" -> "FalsePositive", "Reason" -> "理由を書く"|>]]]]}];
iSVIVActDisplay[x_, ___] := Replace[x, iSVIVFindingAct[fid_, tgt_] :> iSVIVFindingRow[fid, tgt]];
$iSVIVSevOrder = <|"Critical" -> 1, "High" -> 2, "Medium" -> 3, "Low" -> 4, "Info" -> 5|>;
$iSVIVComponentOf = <|"InjectionResidue" -> "Integrity", "CitationIntegrity" -> "Integrity", "GeneratedCodeHealth" -> "Integrity", "EntityDrift" -> "Integrity"|>;
Options[SourceVaultIntegrityFindingsView] = {"Status" -> "Open", "Component" -> All, "Limit" -> 100};
SourceVaultIntegrityFindingsView[OptionsPattern[]] := Module[{r = iSVIVProv["iProvFindingsSince", 0], rows},
  If[! AssociationQ[r], Return[Panel[iSVIVText["来歴の索引が読めません (service の取込がまだ動いていない可能性があります)。"]]]];
  rows = r["Rows"];
  If[OptionValue["Status"] === "Open", rows = Select[rows, MemberQ[{"Open", "Acknowledged"}, #["Resolution"]] &]];
  If[StringQ[OptionValue["Component"]], rows = Select[rows, Lookup[$iSVIVComponentOf, #["Kind"], "KnowledgeHealth"] === OptionValue["Component"] &]];
  rows = Take[SortBy[rows, {Lookup[$iSVIVSevOrder, #["Severity"], 9] &, -Lookup[#, "Seq", 0] &}], UpTo[OptionValue["Limit"]]];
  If[rows === {}, Return[Panel[iSVIVText["該当する Finding はありません。"]]]];
  Dataset[Map[Function[f, With[{br = iSVIVProv["iProvBlastRadius", f["FindingId"]], tgt = First[Lookup[f, "Targets", {}], Null]},
      <|"操作" -> iSVIVFindingAct[f["FindingId"], tgt], "重大度" -> f["Severity"], "部品" -> Lookup[$iSVIVComponentOf, f["Kind"], "KnowledgeHealth"],
        "種類" -> f["Kind"], "理由" -> iSVIVShort[ToString @ Lookup[f, "Reason", ""]], "対象" -> Length[Lookup[f, "Targets", {}]],
        "子孫" -> If[AssociationQ[br], br["Descendants"], "-"], "公開済み" -> If[AssociationQ[br], br["Published"], "-"], "状態" -> f["Resolution"],
        "FindingId" -> f["FindingId"]|>]], rows],
    ItemDisplayFunction -> (iSVIVActDisplay[#] &)]];

(* ---- 10.2 LineageView ---- *)
Options[SourceVaultLineageView] = {"Direction" -> "Both", "Depth" -> 3, "Kinds" -> All};
SourceVaultLineageView[ref_String, OptionsPattern[]] := Module[{res, eid, ok, dir = OptionValue["Direction"], depth = OptionValue["Depth"], parents, children,
    nodes = <||>, edges = {}, frontier, roleOf, vstyle, vlabel, kinds = OptionValue["Kinds"]},
  res = Quiet @ Check[SourceVault`SourceVaultProvResolve[ref], $Failed];
  If[! AssociationQ[res] || res["Status"] =!= "Found", Return[Panel[iSVIVText["版が見つかりません: " <> ref]]]];
  eid = res["Latest"];
  ok = iSVIVProv["iProvIndexEnsureRead"];
  If[! TrueQ[ok], Return[Panel[iSVIVText["来歴の索引が読めません。"]]]];
  parents = Function[x, Lookup[SourceVault`ProvenancePrivate`$iProvParentsX, x, {}]];
  children = Function[x, Union[Lookup[SourceVault`ProvenancePrivate`$iProvCarryOut, x, {}], Lookup[SourceVault`ProvenancePrivate`$iProvCiteOut, x, {}]]];
  roleOf = Function[{p, c}, With[{m = Select[parents[c], #[[1]] === p &]}, If[m === {}, "Context", m[[1, 2]]]]];
  nodes[eid] = 0;
  If[MemberQ[{"Up", "Both"}, dir],
    frontier = {eid};
    Do[frontier = DeleteDuplicates @ Flatten[Function[x, (AppendTo[edges, {#[[1]], x, #[[2]]}]; If[! KeyExistsQ[nodes, #[[1]]], nodes[#[[1]]] = -d]; #[[1]]) & /@ parents[x]] /@ frontier];
      If[frontier === {}, Break[]], {d, depth}]];
  If[MemberQ[{"Down", "Both"}, dir],
    frontier = {eid};
    Do[frontier = DeleteDuplicates @ Flatten[Function[x, (AppendTo[edges, {x, #, roleOf[x, #]}]; If[! KeyExistsQ[nodes, #], nodes[#] = d]; #) & /@ children[x]] /@ frontier];
      If[frontier === {}, Break[]], {d, depth}]];
  If[ListQ[kinds], nodes = KeySelect[nodes, # === eid || MemberQ[kinds, Lookup[Lookup[SourceVault`ProvenancePrivate`$iProvEntities, #, <||>], "Kind", None]] &]];
  edges = DeleteDuplicates @ Select[edges, KeyExistsQ[nodes, #[[1]]] && KeyExistsQ[nodes, #[[2]]] &];
  vlabel = Function[x, With[{l = Lookup[SourceVault`ProvenancePrivate`$iProvLabels, x, <||>]},
    Placed[Style[ToString @ Lookup[l, "Kind", "?"] <> "\n" <> ToString @ Lookup[Lookup[l, "Origin", <||>], "OriginClass", "?"], 8], Below]]];
  vstyle = Function[x, Lookup[$iSVIVUsabilityColor, Lookup[Lookup[SourceVault`ProvenancePrivate`$iProvEffective, x, <||>], "Usability", "Unknown"], GrayLevel[0.6]]];
  Panel[Column[{
    Row[{Style["Lineage", Bold, 13], "  ", iSVIVSmall[eid]}],
    Graph[Keys[nodes], DirectedEdge[#[[1]], #[[2]]] & /@ edges,
      VertexLabels -> (# -> vlabel[#] & /@ Keys[nodes]), VertexStyle -> (# -> vstyle[#] & /@ Keys[nodes]),
      VertexSize -> (# -> If[# === eid, 0.32, 0.2] & /@ Keys[nodes]),
      EdgeStyle -> (DirectedEdge[#[[1]], #[[2]]] -> If[#[[3]] === "Cite", Directive[Dashed, GrayLevel[0.6]],
        If[Lookup[Lookup[SourceVault`ProvenancePrivate`$iProvEffective, #[[2]], <||>], "Usability", ""] === "Quarantined", RGBColor[0.85, 0.2, 0.2], GrayLevel[0.4]]] & /@ edges),
      VertexShapeFunction -> "Circle", GraphLayout -> "LayeredDigraphEmbedding", ImageSize -> Medium,
      PlotRangePadding -> Scaled[0.08]],
    iSVIVSmall["赤: 隔離中 (carry 辺で伝わる、段数で弱まらない)。点線: Cite (隔離を伝えない)。色は利用可否。"]}, Spacings -> 0.6]]];

(* ---- InstructionsView ---- *)
iSVIVInstrDisplay[x_, ___] := Replace[x, iSVIVInstrAct[path_, purpose_] :> Row[{
  With[{p = path, pu = purpose}, iSVIVButton["認可", SourceVaultIntegrityOwnerAction[SourceVaultIntegrityAuthorizeInstruction[p, pu]]]], " ",
  iSVIVButton["基準", SourceVaultIntegrityOwnerAction[SourceVaultIntegrityAcceptBaseline["Instructions"]]]}]];
SourceVaultInstructionsView[] := Module[{files = Quiet @ Check[SourceVault`SourceVaultInstructionFiles[], {}], base, entries},
  base = Quiet @ Check[SourceVault`IntegrityPrivate`iSVIReadBaseline[], Missing[]];
  entries = If[AssociationQ[base], base["Entries"], <||>];
  If[files === {}, Return[Panel[iSVIVText["Instruction 系のファイルが見つかりません。"]]]];
  Dataset[Map[Function[f, With[{bid = SourceVault`IntegrityPrivate`iSVIFileBlobId[f["Path"]], e = Lookup[entries, f["Path"], None],
        pu = SourceVault`IntegrityPrivate`iSVIPurposeForClass[f["Class"], "Instruction"]},
      <|"操作" -> iSVIVInstrAct[f["Path"], pu], "群" -> If[f["Group"] === "ModelWritable", "モデルが書き得る", "手編集"], "種別" -> f["Class"],
        "ファイル" -> iSVIVShort[f["RelPath"]],
        "基準" -> Which[! AssociationQ[e], "未受入", StringQ[bid] && e["BlobId"] === bid, "一致", True, "変更あり"],
        "認可" -> If[StringQ[bid] && AssociationQ[SourceVault`IntegrityPrivate`iSVIAuthorizationFor[bid, pu]], pu, "-"]|>]], files],
    ItemDisplayFunction -> (iSVIVInstrDisplay[#] &)]];

(* ---- ModelManifestView ---- *)
SourceVaultModelManifestView[] := Module[{m = Quiet @ Check[SourceVault`SourceVaultModelManifest[], $Failed], d},
  If[! AssociationQ[m] || m["Status"] =!= "OK", Return[Panel[iSVIVText["この機は LM Studio の機ではありません (manifest なし)。"]]]];
  d = Quiet @ Check[SourceVault`SourceVaultModelManifestDiff[], <||>];
  Panel[Column[{
    Row[{Style["Model manifest", Bold, 13], "  ", iSVIVSmall["LM Studio " <> ToString[m["Runtime"]["Version"]] <> " / 同一性の証拠 " <> ToString[m["IdentityEvidence"]] <>
      " / 重みの全体ハッシュ " <> If[StringQ[m["WeightsHashedAtUTC"]], m["WeightsHashedAtUTC"], "未計算"]]}],
    If[AssociationQ[d] && d["Status"] === "OK",
      iSVIVSmall["基準との差: 新規 " <> ToString[Length[d["NewModels"]]] <> " / テンプレート変化 " <> ToString[Length[d["TemplateChanged"]]] <>
        " / 脆弱性表の該当 " <> ToString[Length[d["Advisories"]]]],
      Row[{iSVIVSmall["基準がありません。"], iSVIVButton["基準を受け入れる", SourceVaultIntegrityOwnerAction[SourceVaultIntegrityAcceptBaseline["ModelManifest"]]]}]],
    Dataset[KeyValueMap[<|"モデル" -> iSVIVShort[#1], "種類" -> ToString[#2["Domain"]], "形式" -> ToString[#2["Format"]],
        "大きさ (MB)" -> If[NumberQ[#2["SizeBytes"]], Round[#2["SizeBytes"]/2.^20], "-"],
        "テンプレート" -> If[StringQ[#2["TemplateDigest"]], StringTake[#2["TemplateDigest"], UpTo[19]], "-"],
        "変化" -> If[AssociationQ[d] && MemberQ[Lookup[d, "TemplateChanged", {}], #1], "テンプレート", If[AssociationQ[d] && MemberQ[Lookup[d, "NewModels", {}], #1], "新規", ""]]|> &,
      m["Models"]]]}, Spacings -> 0.6]]];

(* ---- ProvenanceCoverageView ---- *)
SourceVaultProvenanceCoverageView[] := Module[{s = Quiet @ Check[SourceVault`SourceVaultIntegrityState[], $Failed], cov, byKind},
  If[! AssociationQ[s], Return[Panel[iSVIVText["state.json がありません。"]]]];
  cov = Lookup[Lookup[Lookup[Lookup[s, "Components", <||>], "Provenance", <||>], "Checks", <||>], "Coverage", <||>];
  byKind = Lookup[Lookup[cov, "Counts", <||>], "ByKind", <||>]; If[! AssociationQ[byKind], byKind = <||>];
  Panel[Column[{
    Row[{Style["Provenance coverage (7 日)", Bold, 13], "  ", iSVIHealthFallback[Lookup[cov, "Health", "?"]], "  ", iSVIVSmall[Lookup[cov, "ReasonCode", ""]]}],
    If[byKind === <||>, iSVIVSmall["(活動がありません)"],
      Grid[Prepend[KeyValueMap[{iSVIVText[#1], ToString @ Lookup[#2, "Total", 0], ToString @ Lookup[#2, "Complete", 0],
          If[NumberQ[Lookup[#2, "Ratio", Null]], ToString[Round[100. #2["Ratio"]]] <> "%", "-"]} &, byKind],
        iSVIVSmall /@ {"Kind", "派生", "Complete", "割合"}], Alignment -> {{Left, Right, Right, Right}}, Spacings -> {1.5, 0.3}]],
    iSVIVSmall["記録の無い LLMCall: " <> ToString @ Lookup[Lookup[cov, "Counts", <||>], "UnrecordedLLMDerivations", 0]]}, Spacings -> 0.6]]];
iSVIHealthFallback[h_] := iSVIVHealth[h];

End[]  (* `IntegrityViewPrivate` *)

EndPackage[]  (* SourceVault` *)
