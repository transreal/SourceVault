(* ::Package:: *)

(* ============================================================
   SourceVault_oopsseed.wl -- OOPS seed ontology import primitives
   (検索基盤 Phase 0.5 / Phase 6 foundation)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_oopsseed.wl"]]

   仕様: ドキュメント/sourcevault_search_foundation_implementation_spec_v1.md
         §4.1.1 Seed ontology entity dictionary
         §6.5.2 Seed import parser (Common Lisp S式 reader / legacy decode)
         §6.5.1 Owner-scoped topic item

   レビュー由来の実装原則 (r1-r5):
     - 名前空間は enum で決め打ちしない。実データに ki/aga/e/mi/caitsith/tom/ara/anonymous
       および typo (catisith,lki) の 10 種が存在する。総称的に (SYMBOL INT) を読む。
     - index は「S式風」ではなく Common Lisp S式。regex/単純行分割で読まない。
     - 文字エンコーディングは実機で確定する: item-name.index は CR 区切りの ShiftJIS(CP932)。
       ESC(27)=0 ゆえ ISO-2022-JP ではない。0x85 は CP932 二重バイトの一部 (NEL 行終端ではない)。
       quoted-table.index 等の mixed file 用には iSVDecodeLegacyJapanese の cascade を用意。
     - owner-scoped: ki=owner(imai) namespace、mi/aga 等は別 owner namespace。
       未解決 owner は drop せず Missing["UnknownOwner"]。

   Increment 1 (本ファイル) のスコープ:
     - Common Lisp S式 reader                       SourceVaultReadSExprString / iSVReadAllSExpr
     - legacy Japanese decoder (file -> string)     iSVDecodeLegacyJapaneseFile
     - item-name.index parser -> topic name records SourceVaultImportOOPSItemNames
     - owner-scoped seed entity dictionary builder  SourceVaultBuildSeedEntityDictionary
     - 検証用 stats                                  SourceVaultSeedDictionaryStats

   次 Increment 予定: relation/quote/mail-info parser、mail archive 突き合わせ、
                      held-out 仮説実測 (辞書あり/なし BM25 counterfactual)。
   ============================================================ *)

BeginPackage["SourceVault`"];

SourceVaultReadSExprString::usage =
  "SourceVaultReadSExprString[s] は Common Lisp S式の文字列 s を読み、top-level S式のリストを返す。" <>
  "(...)->List, \"...\"->String, 整数->Integer, bareword(nil 含む)->SourceVault`SVSym[name]。";

SourceVaultImportOOPSItemNames::usage =
  "SourceVaultImportOOPSItemNames[path] は OOPS の item-name.index を読み、" <>
  "{<|\"Namespace\",\"LocalId\",\"CanonicalLabel\",\"SurfaceForms\",\"LanguageHints\"|>, ...} を返す。" <>
  "オプション \"Encoding\" (既定 \"ShiftJIS\")。";

SourceVaultBuildSeedEntityDictionary::usage =
  "SourceVaultBuildSeedEntityDictionary[items] は item-name records から owner-scoped な " <>
  "SourceVaultSeedEntityDictionary (仕様 §4.1.1) を作る。オプション \"OwnerMap\", \"PersonNamespaces\", " <>
  "\"DictionaryId\", \"SharedNamespaces\"。";

SourceVaultSeedDictionaryStats::usage =
  "SourceVaultSeedDictionaryStats[dict] は seed entity dictionary の検証用統計 (namespace 分布、" <>
  "owner 解決率、bilingual 数、surface form 総数など) を返す純関数。";

SourceVaultImportOOPSSeedDictionary::usage =
  "SourceVaultImportOOPSSeedDictionary[itemNameIndexPath, opts] は import + dictionary build を一括で行う便宜関数。";

SourceVaultImportOOPSMailToItem::usage =
  "SourceVaultImportOOPSMailToItem[path] は mail-to-item.index を読み、" <>
  "<|mailNumber -> {<|\"Namespace\",\"LocalId\",\"Role\"(title/body)|>, ...}|> を返す。" <>
  "これは人手が付与した topic の gold データ (held-out 実験用)。";

SourceVaultImportOOPSMailInfo::usage =
  "SourceVaultImportOOPSMailInfo[path] は mail-info.index を読み、" <>
  "<|mailNumber -> <|\"List\",\"Hash\",\"Author\",\"SourceFile\",\"ByteStart\",\"ByteEnd\"|>|> を返す。" <>
  "List 名 (oops/oops-ura) は privacy 入力。注意: ByteStart/ByteEnd は 2005 年原ファイル基準で、" <>
  "現 UTF-8 ファイルでは byte offset が無効。本文抽出は mbox 直接 parse (SourceVaultParseOOPSMailFile) を使う。";

SourceVaultParseOOPSMailFile::usage =
  "SourceVaultParseOOPSMailFile[path] は UTF-8 の oops*.txt を mbox として parse し、" <>
  "{<|\"Counter\",\"MlName\",\"Subject\",\"From\",\"Date\",\"Body\"|>, ...} を返す。" <>
  "Counter (X-Ml-Counter) で gold (mail-to-item) と join する。CR 行終端対応。";

SourceVaultStripOOPSMarkers::usage =
  "SourceVaultStripOOPSMarkers[text] は OOPS の topic ID ref ([ns n])、brace wrapper、" <>
  "◎○・ structural marker を除去して query 用 plain text を返す。label 本文は残す (held-out で cheat 防止)。";

SourceVaultParseMailParagraphs::usage =
  "SourceVaultParseMailParagraphs[body] は mail 本文を段落に分割し、" <>
  "{<|\"Index\",\"Kind\"(Prose/Quote/Signature/Footer),\"Text\"|>, ...} を返す。空行区切り、引用/署名/footer を分離 (§6.5)。";

SourceVaultAssignParagraphTopics::usage =
  "SourceVaultAssignParagraphTopics[paragraphs, surfaceIndex] は各 prose 段落に対し、seed 辞書の " <>
  "surface form OR-match で topic item を自動割当する (auto-tag)。各割当は TopicItemRef / MatchedSurfaceForms / " <>
  "Confidence / AssignmentKind=\"SeedMatched\"。surfaceIndex は SourceVaultBuildSurfaceIndex[dict]。" <>
  "\"RelationGraph\" を渡すと named topic から 1-hop の関連 topic を低 confidence の AssignmentKind=\"RelationExpanded\"" <>
  "(ViaSeed/RelationWeight 付き) として追加する。" <>
  "オプション \"MinSurfaceLength\"(既定2), \"TopicLimit\"(既定10), \"ProseOnly\"(既定 True), " <>
  "\"RelationGraph\"(既定 None), \"MaxRelationTopics\"(既定8), \"MinRelationWeight\"(既定2)。";

SourceVaultImportOOPSItemRelations::usage =
  "SourceVaultImportOOPSItemRelations[path, opts] は item-relation.index / item-relation-up.index を読み、" <>
  "<|TopicItemRef -> {<|\"To\", \"Weight\", \"Direction\"|>...}|> の重み付き有向 relation を返す。" <>
  "オプション \"Direction\"(既定 \"Down\")。";

SourceVaultBuildOOPSRelationGraph::usage =
  "SourceVaultBuildOOPSRelationGraph[tableDir] は item-relation.index(Down)＋item-relation-up.index(Up) を" <>
  "結合した relation graph <|TopicItemRef -> {neighbor...}|> を返す。";

SourceVaultExpandTopicsByRelation::usage =
  "SourceVaultExpandTopicsByRelation[refs, relationGraph] は seed topic 集合を重み付き 1-hop 近傍へ拡張する。" <>
  "seed 自身は除外し To 単位で最大重みに dedup、重み降順。KG 局所探索(§6.3)・auto-tag 拡張に使う。" <>
  "オプション \"MaxNeighborsPerSeed\"(既定5), \"MinWeight\"(既定1), \"MaxTotal\"(既定20)。";

Begin["`Private`"];

(* ------------------------------------------------------------
   §6.5.2  Common Lisp S式 reader (proper, paren-balanced)
   表現: list->List, string->String, integer->Integer, bareword->SVSym[name]
   ------------------------------------------------------------ *)

$svNel = FromCharacterCode[133];

iSVWhiteQ[c_String] := (c === " " || c === "\t" || c === "\n" || c === "\r" || c === $svNel || c === "\f");
iSVDelimQ[c_String] := (c === "(" || c === ")" || c === "\"");

iSVSkipWS[cs_, n_Integer, p0_Integer] := Module[{p = p0},
  While[p <= n && iSVWhiteQ[cs[[p]]], p++]; p];

(* read one S-expr starting at position p (assumes non-WS). returns {expr, nextPos} *)
iSVReadOne[s_String, cs_, n_Integer, p0_Integer] := Module[{c = cs[[p0]]},
  Which[
    c === "(", iSVReadList[s, cs, n, p0 + 1],
    c === "\"", iSVReadString[s, cs, n, p0 + 1],
    True, iSVReadAtom[s, cs, n, p0]]];

iSVReadList[s_String, cs_, n_Integer, p0_Integer] := Module[{p, items},
  items = Reap[
      p = iSVSkipWS[cs, n, p0];
      While[p <= n && cs[[p]] =!= ")",
        With[{r = iSVReadOne[s, cs, n, p]}, Sow[r[[1]]]; p = iSVSkipWS[cs, n, r[[2]]]]];
    ][[2]];
  {If[items === {}, {}, First[items]], p + 1}  (* +1 skips the ')' *)];

iSVReadString[s_String, cs_, n_Integer, p0_Integer] := Module[{p = p0, raw},
  While[p <= n && cs[[p]] =!= "\"",
    If[cs[[p]] === "\\" && p < n, p += 2, p++]];
  raw = If[p > p0, StringTake[s, {p0, p - 1}], ""];
  raw = StringReplace[raw, {"\\\"" -> "\"", "\\\\" -> "\\", "\\n" -> "\n", "\\t" -> "\t"}];
  {raw, p + 1}  (* +1 skips closing quote *)];

iSVReadAtom[s_String, cs_, n_Integer, p0_Integer] := Module[{p = p0, tok},
  While[p <= n && ! iSVWhiteQ[cs[[p]]] && ! iSVDelimQ[cs[[p]]], p++];
  tok = StringTake[s, {p0, p - 1}];
  {iSVClassifyAtom[tok], p}];

iSVClassifyAtom[tok_String] :=
  If[StringMatchQ[tok, ("-" | "") ~~ DigitCharacter ..], ToExpression[tok], SVSym[tok]];

iSVReadAllSExpr[s_String] := Module[{cs = Characters[s], n = StringLength[s], p},
  p = iSVSkipWS[cs, n, 1];
  Reap[
      While[p <= n,
        With[{r = iSVReadOne[s, cs, n, p]}, Sow[r[[1]]]; p = iSVSkipWS[cs, n, r[[2]]]]];
    ][[2]] /. {{} -> {}, {x_List} :> x}];

SourceVaultReadSExprString[s_String] := iSVReadAllSExpr[s];

(* ------------------------------------------------------------
   §6.5.2  legacy Japanese decode
   item-name.index は ShiftJIS。mixed file 用に cascade も用意 (本 increment では未使用 path)。
   ------------------------------------------------------------ *)

iSVDecodeLegacyJapaneseFile[path_String, enc_String: "ShiftJIS"] :=
  Module[{b = BinaryReadList[path, "Byte"], s},
    s = Quiet@Check[FromCharacterCode[b, enc], $Failed];
    If[s === $Failed || StringContainsQ[s, FromCharacterCode[65533]],
      (* fallback cascade: ISO-2022-JP -> UTF-8 -> Latin1 *)
      s = SelectFirst[
        {Quiet@Check[FromCharacterCode[b, "ISO2022-JP"], $Failed],
         Quiet@Check[FromCharacterCode[b, "UTF-8"], $Failed],
         FromCharacterCode[b, "ISOLatin1"]},
        # =!= $Failed && ! StringContainsQ[#, FromCharacterCode[65533]] &,
        FromCharacterCode[b, "ISOLatin1"]]];
    s];

(* ------------------------------------------------------------
   bilingual / language helpers (OOV 辞書資産: "日本語 English" 併記を分割)
   ------------------------------------------------------------ *)

iSVHasCJKQ[s_String] := StringContainsQ[s, RegularExpression["[^\\x00-\\x7F]"]];
iSVHasLatinQ[s_String] := StringContainsQ[s, RegularExpression["[A-Za-z]"]];

iSVLanguageHints[s_String] :=
  DeleteCases[{If[iSVHasCJKQ[s], "ja", Nothing], If[iSVHasLatinQ[s], "en", Nothing]}, Nothing];

(* 併記語を分割: "日本語 English" / "日本語(English)" の両形を別名化。
   例: "ブルース・スターリング Bruce Sterling" -> {full,"ブルース・スターリング","Bruce Sterling"}
       "時刻表(time table)" -> {full,"時刻表","time table"}  (英語が括弧内の頻出形) *)
iSVBilingualForms[label_String] := Module[{forms = {label}, paren, spaced},
  paren = StringCases[label,
    RegularExpression["^(.+?)\\(([^()]*[A-Za-z][^()]*)\\)\\s*$"] :> {"$1", "$2"}];
  If[paren =!= {},
    forms = Join[forms, StringTrim /@ First[paren]],
    (* 括弧形でなければ末尾 latin run の空白区切りを試す *)
    spaced = StringCases[label,
      RegularExpression["^(.*[^\\x00-\\x7F])\\s+([A-Za-z][\\x20-\\x7E]*?)\\s*$"] :> {"$1", "$2"}];
    If[spaced =!= {}, forms = Join[forms, StringTrim /@ First[spaced]]]];
  DeleteDuplicates@DeleteCases[StringTrim /@ forms, ""]];

(* ------------------------------------------------------------
   §6.5  item-name.index parser
   record = key (SYM INT) then value (STRING ...). top-level S式が key,value,key,value... と並ぶ。
   ------------------------------------------------------------ *)

Options[SourceVaultImportOOPSItemNames] = {"Encoding" -> "ShiftJIS"};
SourceVaultImportOOPSItemNames[path_String, OptionsPattern[]] :=
  Module[{s, exprs, recs, warnings = {}},
    If[! FileExistsQ[path],
      Return[Failure["FileNotFound", <|"MessageTemplate" -> "item-name.index がない: `1`", "MessageParameters" -> {path}|>]]];
    s = iSVDecodeLegacyJapaneseFile[path, OptionValue["Encoding"]];
    exprs = iSVReadAllSExpr[s];
    (* 2 つずつ key/value を取り出す *)
    recs = Reap[
      Module[{i = 1, len = Length[exprs], key, val},
        While[i <= len,
          key = exprs[[i]];
          val = If[i + 1 <= len, exprs[[i + 1]], Missing["NoValue"]];
          Which[
            MatchQ[key, {SVSym[_String], _Integer}] && MatchQ[val, {___String}] && val =!= {},
              Sow[<|
                "Namespace" -> key[[1, 1]],
                "LocalId" -> key[[2]],
                "CanonicalLabel" -> First[val],
                "SurfaceForms" -> DeleteDuplicates@Flatten[iSVBilingualForms /@ val],
                "LanguageHints" -> iSVLanguageHints[First[val]]|>];
              i += 2,
            MatchQ[key, {SVSym[_String], _Integer}],
              (* value 不在/想定外: key だけ進めて警告 *)
              AppendTo[warnings, <|"Kind" -> "BadValue", "Key" -> key, "Value" -> val|>]; i += 2,
            True,
              AppendTo[warnings, <|"Kind" -> "BadKey", "Expr" -> key|>]; i += 1]]];
    ][[2]];
    recs = If[recs === {}, {}, First[recs]];
    <|"Items" -> recs, "Count" -> Length[recs], "Warnings" -> warnings,
      "SourcePath" -> path, "Encoding" -> OptionValue["Encoding"]|>];

(* ------------------------------------------------------------
   §4.1.1  owner-scoped seed entity dictionary
   ------------------------------------------------------------ *)

Options[SourceVaultBuildSeedEntityDictionary] = {
  "OwnerMap" -> <|"ki" -> "sventity:owner:imai"|>,
  "SharedNamespaces" -> {"e"},
  "DictionaryId" -> Automatic};

SourceVaultBuildSeedEntityDictionary[importResult_Association, opts : OptionsPattern[]] :=
  SourceVaultBuildSeedEntityDictionary[Lookup[importResult, "Items", {}], opts];

SourceVaultBuildSeedEntityDictionary[items_List, OptionsPattern[]] :=
  Module[{ownerMap, shared, dictId, entries},
    ownerMap = OptionValue["OwnerMap"];
    shared = OptionValue["SharedNamespaces"];
    dictId = OptionValue["DictionaryId"] /. Automatic -> "svdict:oops-topic:item-name";
    entries = Map[
      Function[it,
        Module[{ns = it["Namespace"], owner, nsKind},
          owner = Lookup[ownerMap, ns, Missing["UnknownOwner"]];
          nsKind = Which[
            MemberQ[shared, ns], "Shared",
            ! MissingQ[owner], "Person",
            True, "Unknown"];
          <|
            "TopicItemRef" -> "svtopic:oops:" <> ns <> ":" <> ToString[it["LocalId"]],
            "Namespace" -> ns,
            "LocalId" -> it["LocalId"],
            "OwnerRef" -> owner,
            "OwnerConfidence" -> If[MissingQ[owner], 0.0, 1.0],
            "NamespaceKind" -> nsKind,
            "CanonicalLabel" -> it["CanonicalLabel"],
            "SurfaceForms" -> it["SurfaceForms"],
            "LanguageHints" -> it["LanguageHints"],
            "PrivacyLevel" -> Missing["FromSupportingMail"],
            "SourceRefs" -> {"table/item-name.index"}|>]],
      items];
    <|
      "ObjectClass" -> "SourceVaultSeedEntityDictionary",
      "DictionaryId" -> dictId,
      "Entries" -> entries,
      "EntryCount" -> Length[entries]|>];

SourceVaultImportOOPSSeedDictionary[path_String, opts : OptionsPattern[]] :=
  Module[{imp = SourceVaultImportOOPSItemNames[path, FilterRules[{opts}, Options[SourceVaultImportOOPSItemNames]]]},
    If[FailureQ[imp], imp,
      <|"Dictionary" -> SourceVaultBuildSeedEntityDictionary[imp,
           FilterRules[{opts}, Options[SourceVaultBuildSeedEntityDictionary]]],
        "Import" -> KeyDrop[imp, "Items"]|>]];

(* ------------------------------------------------------------
   検証用 stats
   ------------------------------------------------------------ *)

SourceVaultSeedDictionaryStats[dict_Association] := Module[{es = Lookup[dict, "Entries", {}]},
  <|
    "EntryCount" -> Length[es],
    "NamespaceTally" -> ReverseSort@Counts[#["Namespace"] & /@ es],
    "OwnerResolved" -> Count[es, e_ /; ! MissingQ[e["OwnerRef"]]],
    "OwnerUnresolved" -> Count[es, e_ /; MissingQ[e["OwnerRef"]]],
    "NamespaceKindTally" -> ReverseSort@Counts[#["NamespaceKind"] & /@ es],
    "BilingualCount" -> Count[es, e_ /; Length[e["LanguageHints"]] >= 2],
    "TotalSurfaceForms" -> Total[Length[#["SurfaceForms"]] & /@ es],
    "SampleBilingual" -> Take[Select[es, Length[#["LanguageHints"]] >= 2 &], UpTo[5]][[All, {"CanonicalLabel", "SurfaceForms"}]]
  |>];

(* ------------------------------------------------------------
   §6.5  mail-to-item.index / mail-info.index parser
   どちらも top-level が (integer, list) の繰り返し。namespace は総称。
   ------------------------------------------------------------ *)

SourceVaultImportOOPSMailToItem[path_String] := Module[{s, exprs, rules},
  If[! FileExistsQ[path], Return[Failure["FileNotFound", <|"MessageTemplate" -> path|>]]];
  s = iSVDecodeLegacyJapaneseFile[path, "ShiftJIS"];
  exprs = iSVReadAllSExpr[s];
  rules = Reap[Module[{i = 1, len = Length[exprs], num, lst},
      While[i + 1 <= len,
        num = exprs[[i]]; lst = exprs[[i + 1]];
        If[IntegerQ[num] && ListQ[lst],
          Sow[num -> Cases[lst,
            {{SVSym[ns_String], lid_Integer}, SVSym[role_String]} :>
              <|"Namespace" -> ns, "LocalId" -> lid, "Role" -> role|>]]];
        i += 2]]][[2]];
  rules = If[rules === {}, {}, First[rules]];
  <|"MailToItem" -> Association[rules], "MailCount" -> Length[rules], "SourcePath" -> path|>];

SourceVaultImportOOPSMailInfo[path_String] := Module[{s, exprs, rules},
  If[! FileExistsQ[path], Return[Failure["FileNotFound", <|"MessageTemplate" -> path|>]]];
  s = iSVDecodeLegacyJapaneseFile[path, "ShiftJIS"];
  exprs = iSVReadAllSExpr[s];
  rules = Reap[Module[{i = 1, len = Length[exprs], num, info},
      While[i + 1 <= len,
        num = exprs[[i]]; info = exprs[[i + 1]];
        If[IntegerQ[num] &&
           MatchQ[info, {SVSym[_String], _Integer, _String, {_String, _Integer, _Integer}}],
          Sow[num -> <|
            "List" -> info[[1, 1]], "Hash" -> info[[2]], "Author" -> info[[3]],
            "SourceFile" -> info[[4, 1]], "ByteStart" -> info[[4, 2]], "ByteEnd" -> info[[4, 3]]|>]];
        i += 2]]][[2]];
  rules = If[rules === {}, {}, First[rules]];
  <|"MailInfo" -> Association[rules], "MailCount" -> Length[rules], "SourcePath" -> path|>];

(* ------------------------------------------------------------
   §6.5  mbox 直接 parse (UTF-8, CR 行終端)
   2005 年の byte offset は再エンコードで無効ゆえ、X-Ml-Counter で gold と join する。
   ------------------------------------------------------------ *)

iSVDecodeMailFile[path_String] := Module[{b = BinaryReadList[path, "Byte"], s},
  s = Quiet@Check[FromCharacterCode[b, "UTF-8"], $Failed];
  If[s === $Failed || StringContainsQ[s, FromCharacterCode[65533]],
    s = iSVDecodeLegacyJapaneseFile[path, "UTF-8"]];
  s];

iSVHdr[headers_String, key_String] :=
  FirstCase[StringCases[headers, RegularExpression["(?:^|\\r|\\n)" <> key <> ":[ \\t]*([^\\r\\n]*)"] :> "$1"],
    _String, "", {1}];

SourceVaultParseOOPSMailFile[path_String] := Module[{s, parts, mails},
  If[! FileExistsQ[path], Return[Failure["FileNotFound", <|"MessageTemplate" -> path|>]]];
  s = iSVDecodeMailFile[path];
  parts = StringSplit[s, RegularExpression["[\\r\\n]From oops-adm@\\S+"]];
  mails = Reap[
    Do[Module[{hb, headers, body, counter},
      hb = StringSplit[part, RegularExpression["\\r\\r|\\n\\n|\\r\\n\\r\\n"], 2];
      headers = hb[[1]]; body = If[Length[hb] >= 2, hb[[2]], ""];
      counter = StringCases[headers, RegularExpression["X-Ml-Counter:[ \\t]*(\\d+)"] :> "$1"];
      If[counter =!= {},
        Sow[<|
          "Counter" -> ToExpression[First[counter]],
          "MlName" -> StringTrim@iSVHdr[headers, "X-Ml-Name"],
          "Subject" -> StringTrim@iSVHdr[headers, "Subject"],
          "From" -> StringTrim@iSVHdr[headers, "From"],
          "Date" -> StringTrim@iSVHdr[headers, "Date"],
          "Body" -> body|>]]],
      {part, parts}]][[2]];
  mails = If[mails === {}, {}, First[mails]];
  <|"Mails" -> mails, "MailCount" -> Length[mails], "SourcePath" -> path|>];

SourceVaultStripOOPSMarkers[text_String] := Module[{s = text},
  s = StringReplace[s, RegularExpression["\\[[A-Za-z]+[ \\t]+\\d+\\]"] -> ""];  (* [ns n] ID ref *)
  s = StringReplace[s, {"{" -> "", "}" -> ""}];                                  (* brace wrapper *)
  s = StringReplace[s, RegularExpression["[◎○・]"] -> " "];                      (* structural bullet *)
  s = StringReplace[s, {"\r" -> "\n"}];
  StringReplace[s, RegularExpression["[ \\t]+"] -> " "]];

(* ------------------------------------------------------------
   §6.5  paragraph 分割 ＋ topic 自動付与 (auto-tag, Track B MVP)
   ------------------------------------------------------------ *)

iSVParaKind[t_String] := Which[
  StringContainsQ[t, "-*- Quote"] || StringContainsQ[t, "-*- Unquote"] ||
    StringMatchQ[t, RegularExpression["(?s)^[ \\t]*>.*"]], "Quote",
  StringMatchQ[t, RegularExpression["(?s)^[；;]\\s*[A-Za-z]{0,4}\\s*$"]], "Signature",
  StringContainsQ[t, "X-Ml-"] || StringContainsQ[t, "Errors-To:"] ||
    StringContainsQ[t, "Reply-To:"], "Footer",
  True, "Prose"];

SourceVaultParseMailParagraphs[body_String] := Module[{norm, blocks, paras},
  norm = StringReplace[body, "\r" -> "\n"];
  blocks = StringSplit[norm, RegularExpression["\\n[ \\t]*\\n+"]];
  blocks = Select[StringTrim /@ blocks, # =!= "" &];
  paras = MapIndexed[<|"Index" -> #2[[1]], "Kind" -> iSVParaKind[#1], "Text" -> #1|> &, blocks];
  paras];

Options[SourceVaultAssignParagraphTopics] = {"MinSurfaceLength" -> 2, "TopicLimit" -> 10, "ProseOnly" -> True,
  "RelationGraph" -> None, "MaxRelationTopics" -> 8, "MinRelationWeight" -> 2};
SourceVaultAssignParagraphTopics[paragraphs_List, surfaceIndex_Association, OptionsPattern[]] :=
  Module[{minLen = OptionValue["MinSurfaceLength"], lim = OptionValue["TopicLimit"],
          proseOnly = OptionValue["ProseOnly"], keys,
          relGraph = OptionValue["RelationGraph"], maxRel = OptionValue["MaxRelationTopics"],
          minRelW = OptionValue["MinRelationWeight"]},
    keys = Select[Keys[surfaceIndex], StringLength[#] >= minLen &];
    Map[Function[para,
      If[proseOnly && para["Kind"] =!= "Prose",
        <|"ParagraphIndex" -> para["Index"], "Kind" -> para["Kind"], "Assignments" -> {}|>,
        Module[{nt = iSVNormalizeSearchText[para["Text"]], matches, byRef, seedAssigns, relAssigns},
          matches = Flatten@Map[Function[sf,
             If[iSVSurfaceFormPresentQ[nt, sf], (sf -> #) & /@ surfaceIndex[sf], {}]], keys];
          byRef = GroupBy[matches, Last -> First];  (* ref -> {surfaceForm...} *)
          seedAssigns = Take[ReverseSortBy[
            KeyValueMap[Function[{ref, sfs},
              <|"TopicItemRef" -> ref, "MatchedSurfaceForms" -> DeleteDuplicates[sfs],
                "AssignmentKind" -> "SeedMatched",
                "Confidence" -> Min[1.0, 0.4 + 0.12*Max[StringLength /@ sfs]]|>], byRef],
            #Confidence &], UpTo[lim]];
          (* relation 1-hop 拡張: named topic から関連 topic を低 confidence で付与 (RelationGraph 指定時) *)
          relAssigns = If[AssociationQ[relGraph] && seedAssigns =!= {},
            Map[<|"TopicItemRef" -> #["To"], "MatchedSurfaceForms" -> {},
                  "AssignmentKind" -> "RelationExpanded",
                  "Confidence" -> Min[0.45, 0.2 + 0.03*#["Weight"]],
                  "ViaSeed" -> #["ViaSeed"], "RelationWeight" -> #["Weight"]|> &,
              SourceVaultExpandTopicsByRelation[#["TopicItemRef"] & /@ seedAssigns, relGraph,
                "MaxTotal" -> maxRel, "MinWeight" -> minRelW]],
            {}];
          <|"ParagraphIndex" -> para["Index"], "Kind" -> para["Kind"],
            "Assignments" -> Join[seedAssigns, relAssigns]|>]]],
      paragraphs]];

(* ------------------------------------------------------------
   §6.5.4 / §6.3  weighted directed relation 取り込み ＋ 1-hop 拡張
   ------------------------------------------------------------ *)

Options[SourceVaultImportOOPSItemRelations] = {"Direction" -> "Down"};
SourceVaultImportOOPSItemRelations[path_String, OptionsPattern[]] := Module[{s, exprs, rules, dir},
  If[! FileExistsQ[path], Return[Failure["FileNotFound", <|"MessageTemplate" -> path|>]]];
  dir = OptionValue["Direction"];
  s = iSVDecodeLegacyJapaneseFile[path, "ShiftJIS"];
  exprs = iSVReadAllSExpr[s];
  rules = Reap[Module[{i = 1, len = Length[exprs], key, val},
      While[i + 1 <= len,
        key = exprs[[i]]; val = exprs[[i + 1]];
        If[MatchQ[key, {SVSym[_String], _Integer}] && ListQ[val],
          Sow[("svtopic:oops:" <> key[[1, 1]] <> ":" <> ToString[key[[2]]]) ->
            Cases[val, {{SVSym[ns_String], lid_Integer}, w_Integer} :>
              <|"To" -> "svtopic:oops:" <> ns <> ":" <> ToString[lid], "Weight" -> w, "Direction" -> dir|>]]];
        i += 2]]][[2]];
  rules = If[rules === {}, {}, First[rules]];
  <|"Relations" -> Association[rules], "Count" -> Length[rules], "SourcePath" -> path, "Direction" -> dir|>];

SourceVaultBuildOOPSRelationGraph[tableDir_String, opts___] := Module[{down, up, merged},
  down = SourceVaultImportOOPSItemRelations[FileNameJoin[{tableDir, "item-relation.index"}], "Direction" -> "Down"];
  up = SourceVaultImportOOPSItemRelations[FileNameJoin[{tableDir, "item-relation-up.index"}], "Direction" -> "Up"];
  If[FailureQ[down], Return[down]];
  merged = Merge[{Lookup[down, "Relations", <||>],
     If[FailureQ[up], <||>, Lookup[up, "Relations", <||>]]}, Apply[Join]];
  <|"RelationGraph" -> merged, "Count" -> Length[merged], "TableDir" -> tableDir|>];

Options[SourceVaultExpandTopicsByRelation] = {"MaxNeighborsPerSeed" -> 5, "MinWeight" -> 1, "MaxTotal" -> 20};
SourceVaultExpandTopicsByRelation[refs_List, relationGraph_Association, OptionsPattern[]] :=
  Module[{seeds = Union[refs], expanded},
    expanded = Flatten@Map[Function[ref,
      Module[{nbrs = Select[Lookup[relationGraph, ref, {}], #["Weight"] >= OptionValue["MinWeight"] &]},
        Map[Append[#, "ViaSeed" -> ref] &,
          Take[ReverseSortBy[nbrs, #["Weight"] &], UpTo[OptionValue["MaxNeighborsPerSeed"]]]]]], seeds];
    expanded = Select[expanded, ! MemberQ[seeds, #["To"]] &];
    expanded = Map[First@ReverseSortBy[#, #["Weight"] &] &, Values@GroupBy[expanded, #["To"] &]];
    Take[ReverseSortBy[expanded, #["Weight"] &], UpTo[OptionValue["MaxTotal"]]]];

End[];

EndPackage[];
