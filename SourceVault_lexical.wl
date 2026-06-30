(* ::Package:: *)

(* ============================================================
   SourceVault_lexical.wl -- 日本語 lexical 検索層 (検索基盤 Phase 1)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_lexical.wl"]]

   仕様: ドキュメント/sourcevault_search_foundation_implementation_spec_v1.md
         §4.1 正規化 / §4.2 Token fields / §4.3 BM25 / §4.4 Scoring API

   設計 (レビュー r1-r5 の結論):
     - 既存 KeywordBigram / iKeywordScore は無変更で温存。本層は KeywordBM25V1 用の純関数。
     - lexical 先行: 正規化 -> unigram+bigram+token -> BM25。形態素は後続 profile (本層では非依存)。
     - bigram を OOV 基盤として残す (CJK-IR)。正規化で表記ゆれを叩く。
     - スコアは生 Boole でなく BM25 (IDF + 文書長正規化 + TF 飽和)。
     - exact(substring) と entity(後続) の literal bonus は CorrelatedSurfaceCap で合算上限。

   Increment 2 (本ファイル) のスコープ = 辞書なし BM25 ベースライン (Phase 0.5 counterfactual の片側):
     - 正規化            iSVNormalizeSearchText (NFKC + lower + 数値桁区切り除去 + 空白正規化)
     - token fields      iSVSearchTerms (token / unigram / bigram)
     - lexical stats     iSVBuildLexicalStats (per-chunk term counts + DF + AvgDL + N)
     - BM25 scoring      iSVBM25Score / iSVScoreChunkRecord
     - ranker / explain  SourceVaultLexicalRank / SourceVaultExplainSearchScore
     entity stream (辞書あり arm) は Increment 3 で entity dictionary と接続する (hook 済み)。
   ============================================================ *)

BeginPackage["SourceVault`"];

SourceVaultNormalizeSearchText::usage =
  "SourceVaultNormalizeSearchText[text] は ja-nfkc-v1 正規化 (NFKC, lower, 数値桁区切り除去, 空白正規化) を返す。";

SourceVaultSearchTerms::usage =
  "SourceVaultSearchTerms[normText] は <|\"token\"->{...}, \"unigram\"->{...}, \"bigram\"->{...}|> を返す。";

SourceVaultBuildLexicalStats::usage =
  "SourceVaultBuildLexicalStats[chunks] は chunk list から BM25 用 LexicalStats (N, DF, AvgDL, ChunkTerms) を作る純関数。" <>
  "各 chunk は \"ChunkId\" と \"SearchFields\" または \"Text\" を持つ Association。" <>
  "オプション \"EntityDictionary\" に seed entity dictionary (§4.1.1) を渡すと entity stream を追加し、" <>
  "surface form の OR-match で表記非一致/OOV の topic を index/query 両側で結ぶ。";

SourceVaultBuildSurfaceIndex::usage =
  "SourceVaultBuildSurfaceIndex[dict] は seed entity dictionary から <|正規化 surface form -> {topicRef...}|> を作る。" <>
  "同じ surface form が複数 owner namespace に対応する場合は全 ref を保持 (owner-scoped union)。";

SourceVaultLexicalRank::usage =
  "SourceVaultLexicalRank[query, stats] は LexicalStats に対して BM25 で chunk を順位付けし、" <>
  "{<|\"ChunkId\",\"Score\",\"Breakdown\"|>, ...} を score 降順で返す。オプション \"Limit\" (既定 20)。";

SourceVaultExplainSearchScore::usage =
  "SourceVaultExplainSearchScore[query, chunkIdOrAssoc, stats] は 1 chunk の BM25 score breakdown を返すデバッグ用。" <>
  "raw path / 非公開 body は出さず term と score のみ。";

Begin["`Private`"];

(* ------------------------------------------------------------
   既定パラメータ (§4.3)
   ------------------------------------------------------------ *)

$svBM25Defaults = <|
  "k1" -> 1.2, "b" -> 0.75,
  "FieldWeights" -> <|"exact" -> 3.0, "entity" -> 0.8, "token" -> 1.0, "unigram" -> 0.35, "bigram" -> 0.65|>,
  "MaxExactBoost" -> 3.0,
  "CorrelatedSurfaceCap" -> 3.5|>;

iSVParams[opts___] := Module[{u = Association[opts]},
  Join[$svBM25Defaults, KeyTake[u, Keys[$svBM25Defaults]]]];

(* ------------------------------------------------------------
   §4.1 正規化 (ja-nfkc-v1)
   ------------------------------------------------------------ *)

iSVNormalizeSearchText[text_String, profile_String : "ja-nfkc-v1"] := Module[{s = text},
  s = CharacterNormalize[s, "NFKC"];          (* 全半角/互換文字を正準化 *)
  s = ToLowerCase[s];                          (* ASCII 大小無視 *)
  s = StringReplace[s, RegularExpression["(?<=\\d)[,，](?=\\d)"] -> ""];  (* 数値桁区切り除去 *)
  s = StringReplace[s, RegularExpression["[\\x{200B}\\x{200C}\\x{200D}\\x{FEFF}\\x{00AD}]"] -> ""];  (* zero-width *)
  s = StringReplace[s, RegularExpression["[\\p{C}\\p{Z}\\s]+"] -> " "];   (* 制御/分離/空白 -> 単一空白 *)
  StringTrim[s]];
iSVNormalizeSearchText[Missing[___] | None, ___] := "";
iSVNormalizeSearchText[x_, p___] := iSVNormalizeSearchText[ToString[x], p];

(* ------------------------------------------------------------
   §4.2 Token fields (ja-ngram-v1)
   ------------------------------------------------------------ *)

(* CJK ideograph / かな / カナ / 反復記号 の単一文字か *)
iSVCJKCodeQ[u_Integer] :=
  (12352 <= u <= 12447) ||     (* Hiragana 3040-309F *)
  (12448 <= u <= 12543) ||     (* Katakana 30A0-30FF *)
  (13056 <= u <= 13311) ||     (* CJK compat 31xx (含半角etc小) *)
  (19968 <= u <= 40959) ||     (* CJK Unified 4E00-9FFF *)
  (13312 <= u <= 19903) ||     (* CJK Ext-A 3400-4DBF *)
  (u == 12293) || (u == 12294) || (u == 12540);  (* 々 〆 ー *)

iSVSearchTerms[normText_String, profile_String : "ja-ngram-v1"] := Module[
  {tokens, stripped, chars, codes, unigrams, bigrams},
  tokens = DeleteCases[StringSplit[normText, RegularExpression["[\\s\\p{P}\\p{Z}]+"]], ""];
  stripped = StringReplace[normText, RegularExpression["[\\s\\p{P}\\p{Z}]+"] -> ""];
  chars = Characters[stripped];
  codes = If[stripped === "", {}, ToCharacterCode[stripped, "Unicode"]];
  unigrams = Pick[chars, iSVCJKCodeQ /@ codes];
  bigrams = Which[
    StringLength[stripped] < 2, DeleteCases[{stripped}, ""],
    True, StringJoin /@ Partition[chars, 2, 1]];
  <|"token" -> tokens, "unigram" -> unigrams, "bigram" -> bigrams|>];

(* ------------------------------------------------------------
   chunk text 抽出 (release gate には触れない。検索可能 field を連結)
   ------------------------------------------------------------ *)

iSVFieldText[v_String] := v;
iSVFieldText[v_List] := StringRiffle[Flatten[{v}] /. x_ :> ToString[x], " "];
iSVFieldText[v_] := ToString[v];

iSVChunkText[chunk_Association] := Module[{sf = Lookup[chunk, "SearchFields", Missing[]]},
  If[AssociationQ[sf],
    StringRiffle[iSVFieldText /@ DeleteMissing[Lookup[sf, {"title", "summary", "body", "tags", "author"}]], " "],
    iSVFieldText[Lookup[chunk, "Text", Lookup[chunk, "NormalizedText", ""]]]]];

(* ------------------------------------------------------------
   §4.1.1 entity dictionary: surface form -> topic ref, OR-match entity terms
   query が "Bruce Sterling"、doc が "ブルース・スターリング" でも、双方に entity term
   entity:<ref> が立つので一致する (表記非一致/OOV 回復)。
   ------------------------------------------------------------ *)

iSVBuildSurfaceIndex[dict_Association] := Module[{entries = Lookup[dict, "Entries", {}]},
  Merge[
    Flatten@Map[Function[ent,
      With[{ref = ent["TopicItemRef"]},
        (iSVNormalizeSearchText[#] -> ref) & /@
          Select[Lookup[ent, "SurfaceForms", {}], StringLength[iSVNormalizeSearchText[#]] >= 2 &]]],
      entries],
    DeleteDuplicates]];
SourceVaultBuildSurfaceIndex[dict_Association] := iSVBuildSurfaceIndex[dict];

(* normText に substring 出現する surface form の entity term (OR-match) *)
iSVEntityTerms[normText_String, surfaceIndex_Association] := Module[{refs},
  refs = DeleteDuplicates@Flatten@Map[
     If[StringContainsQ[normText, #], surfaceIndex[#], {}] &, Keys[surfaceIndex]];
  ("entity:" <> #) & /@ refs];
iSVEntityTerms[_, _] := {};

(* query 側 term streams (entity dict があれば entity stream を足す) *)
iSVQueryStreams[normQ_String, stats_Association] := Module[{base = iSVSearchTerms[normQ], si},
  si = Lookup[stats, "SurfaceIndex", None];
  If[AssociationQ[si], Append[base, "entity" -> iSVEntityTerms[normQ, si]], base]];

(* ------------------------------------------------------------
   §4.4 LexicalStats build
   ------------------------------------------------------------ *)

$svStreams = {"token", "unigram", "bigram"};

iSVChunkId[ch_Association] := Lookup[ch, "ChunkId", "chunk:auto:" <> IntegerString[Hash[ch], 16]];

Options[SourceVaultBuildLexicalStats] = {"NormalizationProfile" -> "ja-nfkc-v1", "TokenizerProfile" -> "ja-ngram-v1",
  "EntityDictionary" -> None};
SourceVaultBuildLexicalStats[chunks_List, OptionsPattern[]] := Module[{ed = OptionValue["EntityDictionary"]},
  iSVBuildLexicalStats[chunks, If[AssociationQ[ed], iSVBuildSurfaceIndex[ed], None]]];

iSVBuildLexicalStats[chunks_List, surfaceIndex_ : None] := Module[{recs, n, df, avgdl, postings, streams, hasEnt},
  hasEnt = AssociationQ[surfaceIndex];
  streams = If[hasEnt, Append[$svStreams, "entity"], $svStreams];
  recs = Association@Map[Function[ch,
     Module[{cid = iSVChunkId[ch], nt, terms, counts, dls},
       nt = iSVNormalizeSearchText[iSVChunkText[ch]];
       terms = iSVSearchTerms[nt];
       If[hasEnt, terms = Append[terms, "entity" -> iSVEntityTerms[nt, surfaceIndex]]];
       counts = Association@Map[# -> Counts[terms[#]] &, streams];
       dls = Association@Map[# -> Total[Values[counts[#]], Infinity] &, streams] /. {} -> 0;
       cid -> <|"ChunkId" -> cid, "NormText" -> nt, "Counts" -> counts, "DL" -> dls,
                "ObjectURI" -> Lookup[ch, "ObjectURI", Missing[]]|>]],
     chunks];
  n = Length[recs];
  df = Association@Map[Function[s,
     s -> Merge[Map[AssociationMap[1 &, Keys[#["Counts"][s]]] &, Values[recs]], Total]], streams];
  avgdl = Association@Map[Function[s,
     s -> If[n == 0, 1., N@Mean[Map[#["DL"][s] &, Values[recs]]]]], streams];
  (* 転置インデックス: term -> {docId...} (query-time を軽くする, §17) *)
  postings = Association@Map[Function[s,
     s -> Merge[Flatten@Map[Function[r, (# -> r["ChunkId"]) & /@ Keys[r["Counts"][s]]], Values[recs]], Identity]],
     streams];
  <|"ObjectClass" -> "SourceVaultLexicalStats", "N" -> n, "Streams" -> streams,
    "DF" -> df, "AvgDL" -> avgdl, "Postings" -> postings, "ChunkTerms" -> recs,
    "SurfaceIndex" -> surfaceIndex|>];

(* ------------------------------------------------------------
   §4.3 BM25
   ------------------------------------------------------------ *)

iSVIDF[n_, df_] := Log[1 + (n - df + 0.5)/(df + 0.5)];
iSVBM25TF[tf_, dl_, avgdl_, k1_, b_] := Module[{ratio = If[avgdl <= 0, 1., dl/avgdl]},
  (tf (k1 + 1))/(tf + k1 (1 - b + b ratio))];
iSVBM25Term[tf_, dl_, avgdl_, df_, n_, k1_, b_] := iSVIDF[n, df] * iSVBM25TF[tf, dl, avgdl, k1, b];

iSVScoreChunkRecord[rec_Association, qStreams_Association, normQ_String, stats_Association, P_Association] :=
  Module[{n = stats["N"], streams = stats["Streams"], streamScores, exact, total, bd},
    streamScores = Association@Map[Function[s,
      Module[{w = Lookup[P["FieldWeights"], s, 1.], avgdl = stats["AvgDL"][s], dfTab = stats["DF"][s],
              cnt = rec["Counts"][s], dl = rec["DL"][s], qts = DeleteDuplicates[Lookup[qStreams, s, {}]], sc},
        sc = Total@Map[Function[t,
           With[{tf = Lookup[cnt, t, 0]},
             If[tf == 0, 0., iSVBM25Term[tf, dl, avgdl, Lookup[dfTab, t, 0], n, P["k1"], P["b"]]]]], qts];
        s -> w*sc]], streams];
    exact = If[StringLength[normQ] > 0 && StringContainsQ[rec["NormText"], normQ],
       Min[P["MaxExactBoost"], P["CorrelatedSurfaceCap"]], 0.];
    total = Total[Values[streamScores]] + exact;
    bd = Append[Append[KeyMap["BM25" <> Capitalize[#] &, streamScores], "Exact" -> exact], "Score" -> total];
    {total, bd}];

iSVBM25Score[rec_Association, query_String, stats_Association, opts___] := Module[{P = iSVParams[opts], normQ, qStreams},
  normQ = iSVNormalizeSearchText[query];
  qStreams = iSVQueryStreams[normQ, stats];
  iSVScoreChunkRecord[rec, qStreams, normQ, stats, P]];

(* ------------------------------------------------------------
   public ranker / explain
   ------------------------------------------------------------ *)

(* 転置インデックス accumulator: query term の postings に出る doc だけ採点する。
   候補 doc にのみ exact boost を加え、top-k だけ breakdown を再計算する。 *)
Options[SourceVaultLexicalRank] = {"Limit" -> 20, "Breakdown" -> True};
SourceVaultLexicalRank[query_String, stats_Association, opts : OptionsPattern[]] := Module[
  {P = iSVParams[], normQ, qStreams, recs = stats["ChunkTerms"], n = stats["N"], contribs, scores, withExact, topk},
  normQ = iSVNormalizeSearchText[query];
  qStreams = iSVQueryStreams[normQ, stats];
  contribs = Flatten@Reap[
    Do[With[{w = Lookup[P["FieldWeights"], s, 1.], avgdl = stats["AvgDL"][s], dfTab = stats["DF"][s],
             post = stats["Postings"][s], qts = DeleteDuplicates[Lookup[qStreams, s, {}]]},
        Do[With[{df = Lookup[dfTab, t, 0], plist = Lookup[post, t, {}]},
            If[df > 0 && plist =!= {},
              With[{idf = iSVIDF[n, df]},
                Do[With[{r = recs[docId]},
                    Sow[docId -> w*idf*iSVBM25TF[r["Counts"][s][t], r["DL"][s], avgdl, P["k1"], P["b"]]]],
                  {docId, plist}]]]],
          {t, qts}]],
      {s, stats["Streams"]}]][[2]];
  scores = If[contribs === {}, <||>, Merge[contribs, Total]];
  withExact = If[StringLength[normQ] == 0 || Length[scores] == 0, scores,
    Association@KeyValueMap[Function[{docId, sc},
       docId -> sc + If[StringContainsQ[recs[docId]["NormText"], normQ],
          Min[P["MaxExactBoost"], P["CorrelatedSurfaceCap"]], 0.]], scores]];
  topk = Take[ReverseSort[withExact], UpTo[OptionValue["Limit"]]];
  If[TrueQ[OptionValue["Breakdown"]],
    KeyValueMap[Function[{docId, sc},
       <|"ChunkId" -> docId, "ObjectURI" -> recs[docId]["ObjectURI"], "Score" -> sc,
         "Breakdown" -> iSVScoreChunkRecord[recs[docId], qStreams, normQ, stats, P][[2]]|>], topk],
    KeyValueMap[Function[{docId, sc},
       <|"ChunkId" -> docId, "ObjectURI" -> recs[docId]["ObjectURI"], "Score" -> sc|>], topk]]];

SourceVaultExplainSearchScore[query_String, chunkId_String, stats_Association] :=
  Module[{rec = Lookup[stats["ChunkTerms"], chunkId, Missing["NoChunk"]]},
    If[MissingQ[rec], rec,
      Module[{r = iSVBM25Score[rec, query, stats]}, <|"ChunkId" -> chunkId, "Query" -> query,
        "NormalizedQuery" -> iSVNormalizeSearchText[query], "Breakdown" -> r[[2]]|>]]];
SourceVaultExplainSearchScore[query_String, chunk_Association, stats_Association] :=
  SourceVaultExplainSearchScore[query, iSVChunkId[chunk], stats];

(* debug wrappers *)
SourceVaultNormalizeSearchText[text_String] := iSVNormalizeSearchText[text];
SourceVaultSearchTerms[normText_String] := iSVSearchTerms[normText];

End[];

EndPackage[];
