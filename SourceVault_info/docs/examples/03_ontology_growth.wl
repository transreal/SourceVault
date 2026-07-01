(* ============================================================
   Example 3: オントロジ育成（新トピック候補 → 確認 → 永続 → 検索可能）

   seed（1992–2005 の語彙）に無い新しい語（例: 2005 年の "iTMS" = iTunes
   Music Store）を、一般メールから候補として抽出し、owner が確認したら
   seed と同形の topic entry にして辞書に編入する。編入後は SeedMatched で
   引けるようになる。＝一般メールから語彙を育てるループ。
   ============================================================ *)

(* ---- 設定（PC 非依存。$dropbox / $packageDirectory は init 定義。再定義しない）---- *)
$oopsTable = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "db", "table"}];
$oopsMail = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "oops-ml-generate"}];
$store = FileNameJoin[{$packageDirectory, "SourceVault_info", "docs", "examples", "extracted-topics.wxf"}];
Block[{$CharacterEncoding = "UTF-8"}, Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]];

dict = SourceVault`SourceVaultImportOOPSSeedDictionary[
   FileNameJoin[{$oopsTable, "item-name.index"}]]["Dictionary"];
surfaceIndex = SourceVault`SourceVaultBuildSurfaceIndex[dict];

(* ---- 1. iTMS を含む段落を取り出す ---- *)
mails = SourceVault`SourceVaultParseOOPSMailFile[FileNameJoin[{$oopsMail, "oops 200506.txt"}]]["Mails"];
paragraph = First@Select[
   Flatten[SourceVault`SourceVaultParseMailParagraphs[
       SourceVault`SourceVaultStripOOPSMarkers[#["Body"]]] & /@ Take[mails, UpTo[10]]],
   #["Kind"] === "Prose" && StringContainsQ[#["Text"], "iTMS"] &];

(* ---- 2. 新トピック候補を抽出（seed 既知語は除外）---- *)
candidates = SourceVault`SourceVaultExtractCandidateTopics[paragraph["Text"],
   "KnownSurfaceIndex" -> surfaceIndex, "Limit" -> 6];
#["Surface"] & /@ candidates
(* => {アップルコンピュータ, iTunes, 日本経済新聞, Store, Music, iTMS} *)

(* この段階で auto-tag すると iTMS は AssignmentKind="AutoExtracted"（要確認候補）*)
paraAssoc = {<|"Index" -> 1, "Kind" -> "Prose", "Text" -> paragraph["Text"]|>};
before = SelectFirst[
   First[SourceVault`SourceVaultAssignParagraphTopics[paraAssoc, surfaceIndex,
       "ExtractCandidates" -> True]]["Assignments"],
   Lookup[#, "ProposedLabel", ""] === "iTMS" &];
before["AssignmentKind"]  (* => "AutoExtracted" *)

(* ---- 3. owner が iTMS を確認 → seed 同形 entry にして辞書に merge ---- *)
confirmed = SourceVault`SourceVaultConfirmCandidateTopics[
   {<|"Surface" -> "iTMS", "ExtractionKind" -> "Latin"|>},
   "ExistingDictionary" -> dict, "OwnerRef" -> "sventity:owner:imai"];
confirmed["ConfirmedEntries"][[1]]
(* => <|"TopicItemRef" -> "svtopic:extracted:1", "CanonicalLabel" -> "iTMS",
        "SurfaceForms" -> {"iTMS"}, "NamespaceKind" -> "Extracted", ...|> *)

(* ---- 4. 確認 topic をファイルに永続（owner store）---- *)
SourceVault`SourceVaultSaveExtractedTopics[confirmed["ConfirmedEntries"], $store];
reloaded = SourceVault`SourceVaultLoadExtractedTopics[$store];
reloaded === confirmed["ConfirmedEntries"]  (* => True（往復一致）*)

(* ---- 5. merge 済み辞書で再 index → iTMS が SeedMatched で引ける ---- *)
surfaceIndex2 = SourceVault`SourceVaultBuildSurfaceIndex[confirmed["MergedDictionary"]];
after = SelectFirst[
   First[SourceVault`SourceVaultAssignParagraphTopics[paraAssoc, surfaceIndex2]]["Assignments"],
   StringQ[#["TopicItemRef"]] && StringContainsQ[#["TopicItemRef"], "extracted"] &];
{after["AssignmentKind"], after["TopicItemRef"]}
(* => {"SeedMatched", "svtopic:extracted:1"}  ← 候補から確認済 topic へ昇格し検索可能に *)

(* 後始末: 例で作った store を消す（残したい場合はコメントアウト）*)
If[FileExistsQ[$store], DeleteFile[$store]];

(* ============================================================
   期待出力（実測）:
   candidates surfaces -> {アップルコンピュータ, iTunes, 日本経済新聞, Store, Music, iTMS}
   before["AssignmentKind"] -> "AutoExtracted"
   confirmed entry ref/label -> svtopic:extracted:1 / "iTMS"
   Save/Load 一致 -> True
   after -> {"SeedMatched", "svtopic:extracted:1"}
   ============================================================ *)
