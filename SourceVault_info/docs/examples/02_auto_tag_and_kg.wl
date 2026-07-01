(* ============================================================
   Example 2: auto-tag（SeedMatched + RelationExpanded）と §6.3 KG 局所探索

   一般メールの段落に seed topic を自動付与する。
   - SeedMatched     : surface form が本文に出現する named topic（正準ラベル）
   - RelationExpanded: named topic の 1-hop 関連 topic（本文に無くてもよい、低 confidence）
   さらに relation graph を multi-hop で辿る KG 局所探索を示す。
   ============================================================ *)

(* ---- 設定（PC 非依存。$dropbox / $packageDirectory は init 定義。再定義しない）---- *)
$oopsTable = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "db", "table"}];
$oopsMail = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "oops-ml-generate"}];
Block[{$CharacterEncoding = "UTF-8"}, Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]];

dict = SourceVault`SourceVaultImportOOPSSeedDictionary[
   FileNameJoin[{$oopsTable, "item-name.index"}]]["Dictionary"];
surfaceIndex = SourceVault`SourceVaultBuildSurfaceIndex[dict];
refLabel = Association[(#["TopicItemRef"] -> #["CanonicalLabel"]) & /@ dict["Entries"]];
label = Function[r, Lookup[refLabel, r, r]];
relationGraph = SourceVault`SourceVaultBuildOOPSRelationGraph[$oopsTable]["RelationGraph"];

(* ---- 1. mail を段落に分割して auto-tag ---- *)
mail4439 = SelectFirst[
   SourceVault`SourceVaultParseOOPSMailFile[FileNameJoin[{$oopsMail, "oops 9805.txt"}]]["Mails"],
   #["Counter"] == 4439 &];
paragraphs = SourceVault`SourceVaultParseMailParagraphs[
   SourceVault`SourceVaultStripOOPSMarkers[mail4439["Body"]]];

assigned = SourceVault`SourceVaultAssignParagraphTopics[paragraphs, surfaceIndex,
   "RelationGraph" -> relationGraph,  (* RelationExpanded を有効化 *)
   "RefLabel" -> refLabel];           (* 同一ラベルの重複 topic を collapse *)

(* topic を含む最初の段落を見る *)
firstTagged = SelectFirst[assigned, #["Assignments"] =!= {} &];
byKind = GroupBy[firstTagged["Assignments"], #["AssignmentKind"] &];
Column[{
  "SeedMatched (named): " <> ToString[label[#["TopicItemRef"]] & /@ Lookup[byKind, "SeedMatched", {}]],
  "RelationExpanded (related): " <> ToString[label[#["TopicItemRef"]] & /@ Take[Lookup[byKind, "RelationExpanded", {}], UpTo[4]]]
}]
(* => SeedMatched: {Total Recall, Starship Troopers, 映画}
      RelationExpanded: {ヨーク軍曹, 映画, 宇宙の戦士, テレビ} など *)

(* ---- 2. §6.3 KG 局所探索: topic を multi-hop で辿る ---- *)
kg = SourceVault`SourceVaultExpandSearchGraph[{"svtopic:oops:ki:99"} (* Total Recall *),
   "RelationGraph" -> relationGraph, "RefLabel" -> refLabel,
   "MaxHops" -> 2, "MaxNodes" -> 8, "MinEdgeWeight" -> 2];
Column[{
  "KG 局所探索 (Total Recall から 2-hop):",
  Row[{"nodes=", kg["NodeCount"], " edges=", kg["EdgeCount"], " capped=", kg["Capped"]}],
  Grid[Prepend[{#["Hop"], #["Label"]} & /@ kg["Expanded"], {"Hop", "Label"}], Frame -> All]
}]
(* => hop1: {映画, テレビ, Starship Troopers}
      hop2: {チャーリーズ・エンジェル, 任天堂, Independence Day (ID4), 吾妻ひでお, ウゴウゴルーガ} *)

(* ============================================================
   期待出力（実測）:
   SeedMatched       -> {"Total Recall", "Starship Troopers", "映画"}
   RelationExpanded  -> {"ヨーク軍曹", "映画", "宇宙の戦士", "テレビ"}
   kg["NodeCount"]   -> 8,  kg["EdgeCount"] -> 20,  kg["Capped"] -> True
   kg hop1           -> 映画 / テレビ / Starship Troopers
   kg hop2           -> Independence Day (ID4) 等
   ============================================================ *)
