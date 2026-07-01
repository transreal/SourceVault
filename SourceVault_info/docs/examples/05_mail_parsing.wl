(* ============================================================
   Example 5: メール解析の品質（MIME 復号 / Latin↔CJK 境界 / catch-all 除外）

   検索の入力品質を支える 3 つの実装:
   (a) RFC 2047 MIME encoded-word の Subject 復号（ISO-2022-JP を含む）
   (b) Latin 語の照合を「ASCII 英数の境界」で行い、Latin が CJK に直接
       隣接する日本語（"iTMSの" 等）でも取りこぼさない（かつ語中誤一致は防ぐ）
   (c) 記号のみラベル・surface form 過多の catch-all 退化トピックを index から除外
   ============================================================ *)

(* ---- 設定（PC 非依存。$dropbox / $packageDirectory は init 定義。再定義しない）---- *)
$oopsTable = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "db", "table"}];
$oopsMail = FileNameJoin[{$dropbox, "udb", "oops-ml-archive", "oops-ml-archive", "oops-ml-generate"}];
Block[{$CharacterEncoding = "UTF-8"}, Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]];

(* ---- (a) MIME Subject 復号 ---- *)
mails = SourceVault`SourceVaultParseOOPSMailFile[FileNameJoin[{$oopsMail, "oops 9805.txt"}]]["Mails"];
subject4444 = SelectFirst[mails, #["Counter"] == 4444 &]["Subject"];
stillEncoded = Count[#["Subject"] & /@ mails,
   s_ /; StringContainsQ[s, "=?"] && StringContainsQ[s, "?="]];
Column[{
  Row[{"mail 4444 の Subject（復号後）: ", subject4444}],       (* => "転勤" *)
  Row[{"encoded-word が残っている Subject 数: ", stillEncoded}]  (* => 0 *)
}]
(* 元ヘッダは "=?ISO-2022-JP?B?GyRCRT42UBsoSg==?=" （ISO-2022-JP + Base64）。
   WL は ISO-2022-JP 非対応だが JIS X0208 バイトを +0x80 して EUC-JP 経由で復号する。 *)

(* ---- (b) Latin↔CJK の語境界照合 ---- *)
present = SourceVault`Private`iSVSurfaceFormPresentQ;
Grid[{
  {"itms in 'itmsの提供'", present["itmsの提供", "itms"]},    (* True: Latin が CJK に隣接 *)
  {"apple in 'appleが発表'", present["appleが発表", "apple"]}, (* True *)
  {"tar in 'starship'", present["starship", "tar"]}          (* False: 語中誤一致は防ぐ *)
}, Frame -> All]

(* ---- (c) catch-all 退化トピックの除外 ---- *)
dict = SourceVault`SourceVaultImportOOPSSeedDictionary[
   FileNameJoin[{$oopsTable, "item-name.index"}]]["Dictionary"];
surfaceIndex = SourceVault`SourceVaultBuildSurfaceIndex[dict];
allRefs = DeleteDuplicates@Flatten@Values[surfaceIndex];
Column[{
  Row[{"surface form '映画' -> refs: ", Lookup[surfaceIndex, "映画", {}]}],
  Row[{"catch-all anonymous:0（ラベル「・」で数百 form）が index から除外: ",
    ! MemberQ[allRefs, "svtopic:oops:anonymous:0"]}]
}]
(* => 映画 -> {svtopic:oops:ki:195, svtopic:oops:e:203}（退化 anonymous:0 は含まれない）
      除外: True *)

(* ============================================================
   期待出力（実測）:
   (a) subject4444 -> "転勤"、stillEncoded -> 0
   (b) itmsの/appleが -> True、tar∈starship -> False
   (c) 映画 -> {svtopic:oops:ki:195, svtopic:oops:e:203}、anonymous:0 除外 -> True
   ============================================================ *)
