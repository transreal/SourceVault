(* ============================================================
   Example 1: seed → 検索パイプライン（プロジェクトの核）

   OOPS seed 辞書を取り込み、一般メールを「topic 注入付きの検索 chunk」に
   変換して日本語 BM25 index を build し、検索する。

   ねらい: mail 4439 は本文で映画「Total Recall」「Starship Troopers」を
   語るが、「Independence Day」という語は本文に無い。auto-tag が relation
   経由でこの関連トピックを chunk の SearchFields["topics"] に注入するので、
   「Independence Day」で検索すると mail 4439 がヒットする。
   ＝「一般メールを seed 形式に変換して検索精度を上げる」ことの実証。
   ============================================================ *)

(* ---- 設定（PC 非依存）----
   $dropbox（Dropbox ルート、別ドライブ可）と $packageDirectory（パッケージのパス）は
   init ファイルで定義済み。$packageDirectory はユーザ以外の再定義禁止ゆえここでは設定しない。 *)
$oopsTable = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "db", "table"}];
$oopsMail = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "oops-ml-generate"}];
Block[{$CharacterEncoding = "UTF-8"}, Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]];

(* ---- 1. seed 辞書・surface index・relation graph を用意 ---- *)
dict = SourceVault`SourceVaultImportOOPSSeedDictionary[
   FileNameJoin[{$oopsTable, "item-name.index"}]]["Dictionary"];
surfaceIndex = SourceVault`SourceVaultBuildSurfaceIndex[dict];
refLabel = Association[(#["TopicItemRef"] -> #["CanonicalLabel"]) & /@ dict["Entries"]];
relationGraph = SourceVault`SourceVaultBuildOOPSRelationGraph[$oopsTable]["RelationGraph"];

(* ---- 2. mail を topic 注入付き chunk にする ---- *)
mail4439 = SelectFirst[
   SourceVault`SourceVaultParseOOPSMailFile[FileNameJoin[{$oopsMail, "oops 9805.txt"}]]["Mails"],
   #["Counter"] == 4439 &];
chunks = SourceVault`SourceVaultBuildMailChunks[mail4439, surfaceIndex,
   "Granularity" -> "Mail",           (* mail 全体で 1 chunk。段落単位なら "Paragraph" *)
   "RelationGraph" -> relationGraph,  (* 関連トピックも topics に注入 *)
   "RefLabel" -> refLabel, "PrivacyLevel" -> 0.3];
(* chunk["SearchFields"]["topics"] に auto-tag した topic ラベルが入る:
   "Total Recall quote Adobe After Effects Starship Troopers 宇宙の戦士 リコール La..." *)

(* ---- 3. release context を登録し BM25 projection index を build ---- *)
(* index id は毎回ユニークにする。immutable snapshot は content-addressed で、
   固定 id だと再実行時に BuiltAtUTC 差でハッシュが変わり alias 衝突するため。 *)
$indexId = "example-bm25-" <> StringTake[StringDelete[CreateUUID[], "-"], 8];
SourceVault`SourceVaultRegisterReleaseContext["example-rc", <|"MaxPrivacyLevel" -> 1.0|>];
built = SourceVault`SourceVaultBuildProjectionIndex["example-rc",
   "Chunks" -> chunks, "IndexKind" -> "KeywordBM25V1",
   "EntityDictionary" -> dict,        (* entity OR-match で表記非一致/OOV も結ぶ *)
   "IndexId" -> $indexId];
(* built => <|"Status" -> "OK", "ChunkCount" -> 1, ...|> *)

(* ---- 4. 本文に出ない関連トピックで検索する ---- *)
results = SourceVault`SourceVaultSearch["Independence Day",
   "ReleaseContext" -> "example-rc", "Index" -> $indexId, "Limit" -> 3];
Column[{
  "Independence Day で検索 (本文に literal 不在の関連トピック):",
  {#["ChunkId"], Round[#["Score"], 0.01], #["RetrievalKind"], #["ReleaseDecision"]} & /@ results
}]
(* => oops-4439 が score 6.29 / KeywordBM25 / Permit でヒット。
   topics 注入が無い plain index では 4439 はヒットしない (README の主張)。 *)

(* ---- 後始末（テスト context を registry から除去）---- *)
SourceVault`SearchIndexPrivate`$registries["ReleaseContext"] =
  KeyDrop[SourceVault`SearchIndexPrivate`$registries["ReleaseContext"], {"example-rc"}];
SourceVault`SearchIndexPrivate`iRegistrySave[];

(* ============================================================
   期待出力（実測）:
   built                          -> <|"Status" -> "OK", "IndexId" -> "example-bm25",
                                        "ChunkCount" -> 1, "ExcludedCount" -> 0, ...|>
   results[[1]]["ChunkId"]        -> "oops-4439"
   results[[1]]["Score"]          -> 6.29 (KeywordBM25)
   results[[1]]["ReleaseDecision"]-> "Permit"
   ============================================================ *)
