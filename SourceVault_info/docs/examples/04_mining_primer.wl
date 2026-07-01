(* ============================================================
   Example 4: Mining primer（§6.1/6.2）

   raw chunk でなく「mining サマリー由来の item」を index する低コスト探索層。
   スコアは
     PrimerScore = BM25(summary/title/tags/authors)
                 + bounded MiningBoost (= Min[MaxBoost, MaxBoost*EffectiveImportance])
                 + EffectiveImportance * ImportanceWeight
                 - StalePrimerPenalty (Freshness=="StalePrimer" のとき)
   結果は EvidenceKind="SummaryPrimer"（回答根拠にはしない）で、build/request
   両時に release gate を通す。

   ここでは importance / freshness の効きを見るため、summary/title を同一にして
   BM25 を揃えた 3 item を使う:
     hi   : importance 0.9, Fresh
     stale: importance 0.9, StalePrimer（penalty を受ける）
     lo   : importance 0.1, Fresh
   期待順位: hi > stale > lo
   ============================================================ *)

(* ---- 設定（PC 非依存。$packageDirectory は init 定義。再定義しない）---- *)
Block[{$CharacterEncoding = "UTF-8"}, Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]];

(* ---- 1. primer item を用意（実運用では mining 層のサマリーから供給）---- *)
mkItem = Function[{id, imp, freshness},
   <|"ObjectURI" -> "sv://primer/" <> id, "SourceVaultObjectId" -> "synth:" <> id,
     "Title" -> "PRIMER", "Summary" -> "人工生命 alpha 共通サマリー",
     "Tags" -> {"alife"}, "Authors" -> {"imai"},
     "Signals" -> <|"EffectiveImportance" -> imp|>,   (* mining 由来の重要度 *)
     "Freshness" -> freshness,                          (* "Fresh" | "StalePrimer" *)
     "PrivacyLevel" -> 0.2, "State" -> "Published"|>];
items = {mkItem["hi", 0.9, "Fresh"], mkItem["lo", 0.1, "Fresh"], mkItem["stale", 0.9, "StalePrimer"]};

(* ---- 2. release context を登録し primer index を build（build-time gate 付き）---- *)
(* primer id は毎回ユニークに（immutable snapshot の alias 衝突回避。01 と同じ理由）*)
$primerId = "primer-rc-primer-" <> StringTake[StringDelete[CreateUUID[], "-"], 8];
SourceVault`SourceVaultRegisterReleaseContext["primer-rc", <|"MaxPrivacyLevel" -> 1.0|>];
built = SourceVault`SourceVaultBuildPrimerIndex["primer-rc",
   "Items" -> items, "PrimerId" -> $primerId];
SourceVault`SourceVaultLoadPrimerIndex[$primerId];
(* built => <|"Status" -> "OK", "ItemCount" -> 3, "ExcludedCount" -> 0, ...|> *)

(* ---- 3. primer 検索（importance / freshness を加味した採点）---- *)
results = SourceVault`SourceVaultPrimerSearch["人工生命",
   "ReleaseContext" -> "primer-rc", "PrimerIndex" -> $primerId, "Limit" -> 5];
Grid[Prepend[
  {StringDrop[#["SourceVaultObjectId"], 6], Round[#["Score"], 0.001], Round[#["BM25"], 0.001],
    Round[#["MiningBoost"], 0.001], Round[#["ImportanceTerm"], 0.001], #["FreshnessPenalty"],
    #["EvidenceKind"]} & /@ results,
  {"id", "Score", "BM25", "MiningBoost", "ImportanceTerm", "Penalty", "EvidenceKind"}],
  Frame -> All]

(* ---- 後始末 ---- *)
SourceVault`SearchIndexPrivate`$registries["ReleaseContext"] =
  KeyDrop[SourceVault`SearchIndexPrivate`$registries["ReleaseContext"], {"primer-rc"}];
SourceVault`SearchIndexPrivate`iRegistrySave[];

(* ============================================================
   期待出力（実測。全 item は summary/title 同一なので BM25=3.581 で揃う）:
     id    Score  BM25   MiningBoost ImportanceTerm Penalty EvidenceKind
     hi    3.851  3.581  0.18        0.09           0.      SummaryPrimer
     stale 3.701  3.581  0.18        0.09           0.15    SummaryPrimer
     lo    3.611  3.581  0.02        0.01           0.      SummaryPrimer
   順位: hi > stale > lo（importance boost と stale penalty が効く）
   全結果 ReleaseDecision -> "Permit"、EvidenceKind -> "SummaryPrimer"
   ============================================================ *)
