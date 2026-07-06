(* ::Package:: *)

(* ============================================================
   SourceVault_packageapi.wl -- package API chunker / 索引 / 検索 / 契約 view

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_packageapi.wl"]]

   仕様書:
     sourcevault_directive_api_retrieval_spec_v0_3.md (以下 R-spec)
       §4.2 packageapi adapter / §4.4 chunk grammar / §7.1 index versioning /
       §7.2 stable URI (opaque id) / §7.3 freshness / §8.2 deterministic ranking
     sourcevault_function_contract_wiring_spec_v0_3.md (以下 W-spec)
       §8.1 view=contract / §8.2 related candidates / §8.3 DocGranularityProfile /
       §8.4 増分スキャン + 契約 audit 連携

   実装 increment: R1+R2 (F6 の kernel 層。MCP 露出は R3 で SourceVault_mcp.wl へ)
     - chunker:  <pkg>_info/docs/api.md + api_*.md を `## section`/`### symbol` で分割
                 (終端 = 次の ###/##/EOF、section preface は metadata、
                  同名 symbol の連続 ### 見出しは 1 chunk に併合、
                  aux と main の重複は aux 優先 + duplicateOf 記録)
     - 索引:     pkg 単位 atomic replace、SourceMTimeToken による増分再構築、
                 IndexSchemaVersion/ChunkerVersion/DocsBuildId、tombstone
     - URI:      sv://packageapi/<opaqueId>、opaqueId = stableHash(pkg, symbol, auxName)
                 (世代非依存。実パス・layout は URI から推測不能)
     - 検索:     R-spec §8.2 の決定的 ranking (関数名完全一致 > alias 一致 >
                 aux keyword 一致 > bigram overlap。閾値未満は 0 件許容)
     - view:     metadata | summary | body | contract (W-spec §8.1。契約 registry が正、
                 評価可能式は投影しない = W10)
     - related:  Composable(契約から決定的) / AliasCanonical / UseInsteadOf /
                 SameCapability / SameSection / RequiresNeighbor / SimilarUsage
     - tier:     Expert / Guided / Scaffolded (W-spec §8.3。索引は 1 本、描画だけ変える。
                 Scaffolded は EnsureInitialized 前置き + allowed options のみ)
     - freshness: Fresh / StaleDocs (source .wl が docs より新しい) /
                 StaleContract (契約 audit 失敗、W-spec §8.4)

   非衝突方針: private helper は SourceVault`PackageApiPrivate` 文脈。
   privacy: chunk 本文は PrivacyLevel 0 (PublicDoc、R-spec P4)。
   ============================================================ *)

BeginPackage["SourceVault`"]

$SourceVaultPackageApiPackages::usage =
  "$SourceVaultPackageApiPackages は索引対象パッケージの既定リスト。\n" <>
  "各 pkg の docs は <base>/<pkg>_info/docs/api.md + api_*.md (base = 本ファイルのディレクトリ)。";

SourceVaultPackageApiIndexBuild::usage =
  "SourceVaultPackageApiIndexBuild[pkg|All, opts] は package API chunk 索引を構築する。\n" <>
  "SourceMTimeToken が一致すれば skip (増分)。再構築は pkg 単位 atomic replace、\n" <>
  "消えた symbol は tombstone (R-spec §7.1)。\n" <>
  "→ Association <|\"Status\", \"Built\", \"Skipped\", \"Failed\"|>\n" <>
  "Options: \"Force\" -> False";

SourceVaultPackageApiIndexStatus::usage =
  "SourceVaultPackageApiIndexStatus[] は索引の状態 (pkg 別 chunk 数 / DocsBuildId / 版) を返す。";

SourceVaultPackageApiChunks::usage =
  "SourceVaultPackageApiChunks[pkg] は pkg の全 chunk を返す (索引未構築なら自動構築)。";

SourceVaultPackageApiResolve::usage =
  "SourceVaultPackageApiResolve[symbol] は symbol 名から chunk を返す (全 pkg 横断)。\n" <>
  "deprecated alias (契約 Supersedes) は正準 symbol の chunk に解決し \"ResolvedFromAlias\" を付す。\n" <>
  "→ chunk Association | Missing[\"NotFound\", symbol]";

SourceVaultPackageApiSearch::usage =
  "SourceVaultPackageApiSearch[query, opts] は決定的 ranking (R-spec §8.2) で chunk を検索する:\n" <>
  "  強加点 = 関数名完全一致 > legacy alias 一致 (正準を上位) > aux keyword 一致、\n" <>
  "  トークン加点 = query を acronym-aware に語分割し symbol トークンと OR 一致\n" <>
  "    (token 完全一致 > prefix > substring。package 名トークンは非弁別的で弱加点)、\n" <>
  "  弱加点 = token が取れない query (Japanese/全 stopword 等) のみ whole-query bigram。\n" <>
  "  閾値未満は 0 件を許す (無関係注入をしない)。並びは決定論 tie-break で安定\n" <>
  "  (exact/alias tier > Score > exact 数 > function>variable > package 順 > Fresh > 名前)。\n" <>
  "→ List of <|\"Symbol\", \"Uri\", \"Pkg\", \"AuxName\", \"Section\", \"Kind\", \"Score\",\n" <>
  "            \"Rank\", \"Reasons\", \"Freshness\", \"Signature\"|>\n" <>
  "Options: \"MaxResults\" -> 10, \"MinScore\" -> 3., \"Packages\" -> All (canonical 名を\n" <>
  "         大小無視で解決、不明は無視), \"ExpandRelated\" -> False (True で \"Related\" 付与)";

SourceVaultPackageApiGet::usage =
  "SourceVaultPackageApiGet[uriOrSymbol, opts] は chunk を projection して返す (W-spec §8.1)。\n" <>
  "\"View\" -> \"metadata\" (本文なし) | \"summary\" (tier 描画の要約) | \"body\" (chunk 全文) |\n" <>
  "          \"contract\" (契約 registry の投影。評価可能式は含めない = W10。AuditStatus 付き)\n" <>
  "\"Tier\" -> Automatic(=Expert) | \"Expert\" | \"Guided\" | \"Scaffolded\" (W-spec §8.3。\n" <>
  "  Scaffolded は SourceVaultEnsureInitialized 前置きテンプレート + allowed options のみを明示)。\n" <>
  "→ Association | Missing | Failure";

SourceVaultPackageApiRelated::usage =
  "SourceVaultPackageApiRelated[symbolOrUri, opts] は関連・類似 API の ranked 候補を返す (W-spec §8.2)。\n" <>
  "Relation: \"Composable\" (契約の出力ポートが相手の入力に適合、決定的) | \"AliasCanonical\" |\n" <>
  "  \"UseInsteadOf\" | \"SameCapability\" | \"SameSection\" | \"RequiresNeighbor\" | \"SimilarUsage\"。\n" <>
  "固定重み Composable > AliasCanonical > UseInsteadOf > SameCapability > SameSection >\n" <>
  "RequiresNeighbor > SimilarUsage。\n" <>
  "→ List of <|\"Symbol\", \"Uri\", \"Relation\", \"Score\", \"Reason\"|>\n" <>
  "Options: \"MaxResults\" -> 8";

Begin["`PackageApiPrivate`"]

$svPAIndexSchemaVersion = 1;
$svPAChunkerVersion     = 1;

(* docs base = 本ファイルのディレクトリ (MyPackages)。ロード時に確定 *)
If[!StringQ[$svPABase] || $svPABase === "",
  $svPABase = Quiet @ Check[DirectoryName[$InputFileName], ""]];

If[!ListQ[SourceVault`$SourceVaultPackageApiPackages],
  SourceVault`$SourceVaultPackageApiPackages =
    {"SourceVault", "claudecode", "ClaudeRuntime", "ClaudeOrchestrator",
     "NBAccess", "github"}];

If[!AssociationQ[$svPAIndex],      $svPAIndex = <||>];
If[!AssociationQ[$svPATombstones], $svPATombstones = <||>];

(* ============================================================
   1. chunker (R-spec §4.4)
   ============================================================ *)

iPAHex[expr_] :=
  StringPadLeft[IntegerString[Hash[expr, "SHA256"], 16], 64, "0"];

iPAOpaqueId[pkg_, symbol_, auxName_] :=
  StringTake[iPAHex[{pkg, symbol, auxName}], 16];

iPAUri[pkg_, symbol_, auxName_] :=
  "sv://packageapi/" <> iPAOpaqueId[pkg, symbol, auxName];

(* "### SourceVaultFoo[args]" / "### $Var" -> symbol 名 *)
iPAHeadingSymbol[heading_String] :=
  Module[{h = StringTrim[heading]},
    h = First[StringSplit[h, "[" | " " | "\t"], h];
    h = StringTrim[h, "`"];
    If[StringLength[h] > 0 &&
       StringMatchQ[h, ("$" | WordCharacter) ~~ ___], h, $Failed]];

(* 1 ファイルを chunk 列へ。終端 = 次の ###/##/EOF。
   同名 symbol の連続 ### は 1 chunk に併合 (variant signatures)。 *)
iPAParseFile[path_String, pkg_String, auxName_String] :=
  Module[{text, lines, chunks = {}, cur = None, section = "",
          preface = <||>, flush},
    text = Quiet @ Check[
      Block[{$CharacterEncoding = "UTF-8"}, Import[path, "Text"]], $Failed];
    If[!StringQ[text], Return[{}]];
    lines = StringSplit[text, "\n"];
    flush[] := If[AssociationQ[cur],
      AppendTo[chunks,
        Append[cur, "Body" -> StringTrim @ StringRiffle[cur["BodyLines"], "\n"]]];
      cur = None];
    Scan[
      Function[line,
        Which[
          StringStartsQ[line, "### "],
            Module[{heading = StringDrop[line, 4], sym},
              sym = iPAHeadingSymbol[heading];
              Which[
                sym === $Failed,
                  If[AssociationQ[cur], cur["BodyLines"] =
                    Append[cur["BodyLines"], line]],
                (* 連続 ### 同一 symbol -> signature 併合 *)
                AssociationQ[cur] && cur["Symbol"] === sym &&
                  StringTrim @ StringRiffle[cur["BodyLines"], ""] === "",
                  cur["Signatures"] = Append[cur["Signatures"], heading],
                True,
                  flush[];
                  cur = <|"Symbol" -> sym,
                    "Signatures" -> {heading},
                    "Section" -> section,
                    "Kind" -> If[StringStartsQ[sym, "$"],
                      "variable", "function"],
                    "Pkg" -> pkg, "AuxName" -> auxName,
                    "SourceFile" -> FileNameTake[path],
                    "BodyLines" -> {}|>]],
          StringStartsQ[line, "## "],
            flush[];
            section = StringTrim @ StringDrop[line, 3];
            preface[section] = "",
          AssociationQ[cur],
            cur["BodyLines"] = Append[cur["BodyLines"], line],
          section =!= "",
            (* section preface (## と最初の ### の間) は metadata へ *)
            preface[section] = preface[section] <> line <> "\n"]],
      lines];
    flush[];
    Map[
      Function[c,
        Join[KeyDrop[c, "BodyLines"],
          <|"Uri" -> iPAUri[pkg, c["Symbol"], auxName],
            "OpaqueId" -> iPAOpaqueId[pkg, c["Symbol"], auxName],
            "Signature" -> First[c["Signatures"]],
            "SectionPreface" -> StringTrim @ Lookup[preface, c["Section"], ""],
            "ReturnsLine" -> SelectFirst[
              StringSplit[c["Body"], "\n"],
              StringStartsQ[StringTrim[#], "\[RightArrow]" | "->" | "→"] &,
              Missing[]],
            "OptionsLine" -> SelectFirst[
              StringSplit[c["Body"], "\n"],
              StringStartsQ[StringTrim[#], "Options:"] &, Missing[]]|>]],
      chunks]
  ];

(* ============================================================
   2. 索引 build (R-spec §7.1: pkg 単位 atomic + 増分 + tombstone)
   ============================================================ *)

iPADocsDir[pkg_String] :=
  FileNameJoin[{$svPABase, pkg <> "_info", "docs"}];

iPADocFiles[pkg_String] :=
  Module[{dir = iPADocsDir[pkg], main, aux},
    If[!DirectoryQ[dir], Return[{}]];
    main = FileNameJoin[{dir, "api.md"}];
    aux = Sort @ FileNames["api_*.md", dir];
    Join[If[FileExistsQ[main], {main}, {}], aux]];

iPAMTimeToken[files_List] :=
  Association @ Map[
    # -> Quiet @ Check[ToString @ AbsoluteTime @ FileDate[#], "?"] &, files];

(* pkg の全ソース .wl の最新 mtime (StaleDocs 判定用) *)
iPASourceMTime[pkg_String] :=
  Module[{files},
    files = Quiet @ Check[
      FileNames[pkg <> ".wl" | pkg <> "_*.wl", $svPABase], {}];
    If[files === {}, Missing[],
      Max[Quiet @ Check[AbsoluteTime @ FileDate[#], 0] & /@ files]]];

Options[SourceVault`SourceVaultPackageApiIndexBuild] = {"Force" -> False};

SourceVault`SourceVaultPackageApiIndexBuild[
    All, opts : OptionsPattern[]] :=
  Module[{built = {}, skipped = {}, failed = {}},
    Scan[
      Function[pkg,
        With[{r = SourceVault`SourceVaultPackageApiIndexBuild[pkg,
            "Force" -> OptionValue["Force"]]},
          Switch[Lookup[r, "Status", "Failed"],
            "Built", AppendTo[built, pkg],
            "Skipped", AppendTo[skipped, pkg],
            _, AppendTo[failed, pkg]]]],
      SourceVault`$SourceVaultPackageApiPackages];
    <|"Status" -> If[failed === {}, "OK", "Partial"],
      "Built" -> built, "Skipped" -> skipped, "Failed" -> failed|>
  ];

SourceVault`SourceVaultPackageApiIndexBuild[
    pkg_String, OptionsPattern[]] :=
  Module[{files, token, old, chunks = {}, bySymbol = <||>, byUri = <||>,
          staleDocsQ, srcMTime, docsMTime, tombstoned = {}},
    files = iPADocFiles[pkg];
    If[files === {},
      Return[<|"Status" -> "Failed", "Pkg" -> pkg,
        "Reason" -> "NoDocs", "DocsDir" -> iPADocsDir[pkg]|>]];
    token = iPAMTimeToken[files];
    old = Lookup[$svPAIndex, pkg, <||>];
    If[!TrueQ[OptionValue["Force"]] &&
       Lookup[old, "SourceMTimeToken", <||>] === token &&
       Lookup[old, "ChunkerVersion", 0] === $svPAChunkerVersion &&
       Lookup[old, "IndexSchemaVersion", 0] === $svPAIndexSchemaVersion,
      Return[<|"Status" -> "Skipped", "Pkg" -> pkg,
        "Chunks" -> Length @ Lookup[old, "ByUri", <||>]|>]];

    (* main -> aux の順で parse。同名 symbol は aux 優先 + duplicateOf (R-spec §4.4) *)
    Scan[
      Function[f,
        Module[{auxName, parsed},
          auxName = With[{base = FileBaseName[f]},
            If[base === "api", "", StringDrop[base, 4]]];  (* "api_xxx" -> "xxx" *)
          parsed = iPAParseFile[f, pkg, auxName];
          Scan[
            Function[c,
              Module[{sym = c["Symbol"], c2 = c},
                If[KeyExistsQ[bySymbol, sym],
                  (* 後勝ち = aux 優先 (main が先に parse される) *)
                  c2["DuplicateOf"] = bySymbol[sym]];
                bySymbol[sym] = c2["Uri"];
                byUri[c2["Uri"]] = c2]],
            parsed]]],
      files];

    (* freshness: pkg ソースが docs より新しければ StaleDocs (R-spec §7.3) *)
    srcMTime = iPASourceMTime[pkg];
    docsMTime = Max[Quiet @ Check[AbsoluteTime @ FileDate[#], 0] & /@ files];
    staleDocsQ = NumberQ[srcMTime] && srcMTime > docsMTime;
    byUri = Map[Append[#, "Freshness" ->
      If[staleDocsQ, "StaleDocs", "Fresh"]] &, byUri];

    (* tombstone: 旧索引にあって新索引に無い symbol (stable URI 単位) *)
    Scan[
      Function[uri,
        If[!KeyExistsQ[byUri, uri],
          $svPATombstones[uri] = <|"Pkg" -> pkg,
            "TombstonedAt" -> DateString["ISODateTime"]|>;
          AppendTo[tombstoned, uri]]],
      Keys @ Lookup[old, "ByUri", <||>]];

    (* atomic replace (生成完了後に世代差し替え) *)
    $svPAIndex[pkg] = <|
      "ByUri" -> byUri, "BySymbol" -> bySymbol,
      "SourceMTimeToken" -> token,
      "IndexSchemaVersion" -> $svPAIndexSchemaVersion,
      "ChunkerVersion" -> $svPAChunkerVersion,
      "DocsBuildId" -> StringTake[iPAHex[token], 12],
      "StaleDocs" -> staleDocsQ,
      "BuiltAt" -> DateString["ISODateTime"]|>;
    <|"Status" -> "Built", "Pkg" -> pkg, "Chunks" -> Length[byUri],
      "Tombstoned" -> tombstoned,
      "DocsBuildId" -> $svPAIndex[pkg]["DocsBuildId"]|>
  ];

SourceVault`SourceVaultPackageApiIndexStatus[] :=
  Map[
    <|"Chunks" -> Length @ Lookup[#, "ByUri", <||>],
      "DocsBuildId" -> Lookup[#, "DocsBuildId"],
      "StaleDocs" -> Lookup[#, "StaleDocs", False],
      "BuiltAt" -> Lookup[#, "BuiltAt"]|> &,
    $svPAIndex];

iPAEnsureIndex[pkg_String] :=
  If[!KeyExistsQ[$svPAIndex, pkg],
    SourceVault`SourceVaultPackageApiIndexBuild[pkg]];

iPAEnsureAll[] :=
  Scan[iPAEnsureIndex, SourceVault`$SourceVaultPackageApiPackages];

SourceVault`SourceVaultPackageApiChunks[pkg_String] :=
  (iPAEnsureIndex[pkg];
   Values @ Lookup[Lookup[$svPAIndex, pkg, <||>], "ByUri", <||>]);

(* ============================================================
   3. 解決 / 契約連携 (StaleContract, W-spec §8.4)
   ============================================================ *)

iPAContractsAvailableQ[] :=
  Names["SourceVault`SourceVaultFunctionContract"] =!= {} &&
  Length[DownValues[SourceVault`SourceVaultFunctionContract]] > 0;

iPAAliasIndex[] :=
  If[iPAContractsAvailableQ[],
    Quiet @ Check[SourceVault`SourceVaultContractAliasIndex[], <||>], <||>];

(* chunk の遅延装飾: 契約有無 / audit / StaleContract *)
iPADecorate[chunk_Association] :=
  Module[{sym = chunk["Symbol"], contract, audit, fresh},
    fresh = Lookup[chunk, "Freshness", "Fresh"];
    If[!iPAContractsAvailableQ[], Return[chunk]];
    contract = Quiet @ Check[
      SourceVault`SourceVaultFunctionContract[sym], Missing[]];
    If[!AssociationQ[contract],
      Return[Append[chunk, "HasContract" -> False]]];
    audit = Quiet @ Check[
      SourceVault`SourceVaultAuditFunctionContracts[
        contract["Package"]]["PerSymbol"][sym], Missing[]];
    Join[chunk, <|
      "HasContract" -> True,
      "AuditStatus" -> If[AssociationQ[audit],
        Lookup[audit, "AuditStatus", "?"], "?"],
      "Freshness" -> If[AssociationQ[audit] &&
        Lookup[audit, "AuditStatus"] === "Failed",
        "StaleContract", fresh]|>]
  ];

SourceVault`SourceVaultPackageApiResolve[sym_String] :=
  Module[{alias, target = sym, hit = Missing[]},
    iPAEnsureAll[];
    alias = Lookup[iPAAliasIndex[], sym];
    If[StringQ[alias], target = alias];
    Scan[
      Function[pkg,
        With[{idx = Lookup[$svPAIndex, pkg, <||>]},
          With[{uri = Lookup[Lookup[idx, "BySymbol", <||>], target]},
            If[StringQ[uri] && MissingQ[hit],
              hit = iPADecorate @ Lookup[idx, "ByUri", <||>][uri]]]]],
      Keys[$svPAIndex]];
    Which[
      MissingQ[hit], Missing["NotFound", sym],
      StringQ[alias], Append[hit, "ResolvedFromAlias" -> sym],
      True, hit]
  ];

(* ============================================================
   4. 検索 (R-spec §8.2 deterministic ranking)
   ============================================================ *)

iPABigrams[s_String] :=
  With[{t = ToLowerCase[s]},
    If[StringLength[t] < 2, {t},
      Table[StringTake[t, {i, i + 1}], {i, StringLength[t] - 1}]]];

iPAOverlap[qBigrams_List, s_String] :=
  Length[Intersection[qBigrams, iPABigrams[s]]];

(* aux keyword 一致 (claudecode の登録 map を弱結合で参照) *)
iPAAuxKeywordBonus[query_String, pkg_String, auxName_String] :=
  Module[{map, kws},
    If[auxName === "" ||
       Names["ClaudeCode`$ClaudePackageAuxKeywordMap"] === {},
      Return[0.]];
    map = Quiet @ Check[
      ToExpression["ClaudeCode`$ClaudePackageAuxKeywordMap"], <||>];
    If[!AssociationQ[map], Return[0.]];
    kws = Lookup[Lookup[map, pkg, <||>], auxName, {}];
    If[ListQ[kws] &&
       AnyTrue[kws, StringLength[#] >= 3 &&
         StringContainsQ[ToLowerCase[query], ToLowerCase[#]] &],
      3., 0.]];

(* --- トークナイザ (acronym-aware, R2 B-6) -------------------
   camelCase / acronym run / 数字 を語に割る。連続大文字は 1 語に保つ
   (LLM/MCP/NB 等): "$LLMCallLog"->{llm,call,log}, "NBAccess"->{nb,access},
   "SourceVaultServiceRuntimeDir"->{source,vault,service,runtime,dir}。 *)
iPACamelWords[s_String] :=
  ToLowerCase /@ StringCases[s,
    RegularExpression["[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+"]];

$iPAStopwords = {"the", "a", "an", "of", "to", "in", "into", "for",
  "and", "or", "with", "on", "by", "is", "at", "as"};
$iPAShortAllow = {"wl", "nb", "id", "ui", "ai"};

(* query を記号/空白/camel 境界で分割し stopword と短語を落とす *)
iPAQueryTokens[query_String] :=
  DeleteDuplicates @ Select[
    Flatten[iPACamelWords /@
      StringSplit[query, RegularExpression["[^A-Za-z0-9]+"]]],
    !MemberQ[$iPAStopwords, #] &&
      (StringLength[#] >= 3 || MemberQ[$iPAShortAllow, #]) &];

iPASymbolTokens[sym_String] :=
  DeleteDuplicates @ iPACamelWords[StringReplace[sym, "$" -> ""]];

(* 1 chunk へのトークン単位 OR 採点 (R2 B-4/B-5/B-6)。{score, reasons} を返す。
   package 名トークン一致は非弁別的なので弱加点。短語 substring は厳格化。 *)
iPATokenScore[qTokens_List, symTokens_List, secTokens_List,
    pkgTokens_List] :=
  Module[{score = 0., reasons = {}},
    Scan[
      Function[t,
        Which[
          MemberQ[symTokens, t],
            With[{w = If[MemberQ[pkgTokens, t], 1.0, 5.0]},
              score += w; AppendTo[reasons, "TokenExact(" <> t <> ")"]],
          StringLength[t] >= 3 && AnyTrue[symTokens, StringStartsQ[#, t] &],
            score += 2.0; AppendTo[reasons, "TokenPrefix(" <> t <> ")"],
          StringLength[t] >= 4 &&
            AnyTrue[Join[symTokens, secTokens], StringContainsQ[#, t] &],
            score += 1.0; AppendTo[reasons, "TokenSub(" <> t <> ")"],
          MemberQ[secTokens, t],
            score += 0.5; AppendTo[reasons, "SectionMatch(" <> t <> ")"]]],
      qTokens];
    {score, reasons}];

(* Packages 正規化 (R2 B-3): canonical 名へ大小無視で解決し不明は落とす *)
iPANormalizePackages[All] := All;
iPANormalizePackages[spec_] :=
  Module[{canon = SourceVault`$SourceVaultPackageApiPackages, want},
    want = Select[Flatten @ {spec}, StringQ];
    DeleteDuplicates @ Select[
      Map[Function[p,
        SelectFirst[canon,
          ToLowerCase[#] === ToLowerCase[p] &, Missing[]]], want],
      StringQ]];

(* 決定論 tie-break sort key (R2 B-4/B-5)。ascending SortBy 用に降順は符号反転。
   exact/alias は最優先 tier、function > variable、Fresh > StaleDocs、
   package priority は明示 Packages の list 順のみ (固定 bias を持たせない)。 *)
iPASearchHasExact[a_Association] :=
  MemberQ[Lookup[a, "Reasons", {}], "SymbolExactInQuery"] ||
  AnyTrue[Lookup[a, "Reasons", {}], StringStartsQ[#, "AliasCanonical"] &];

iPASearchExactCount[a_Association] :=
  Count[Lookup[a, "Reasons", {}],
    r_ /; StringStartsQ[r, "SymbolExactInQuery"] ||
      StringStartsQ[r, "AliasCanonical"] || StringStartsQ[r, "TokenExact"]];

iPASearchSortKey[pkgList_List, a_Association] :=
  {-Boole[iPASearchHasExact[a]],
   -Lookup[a, "Score", 0.],
   -iPASearchExactCount[a],
   -If[StringStartsQ[Lookup[a, "Symbol", ""], "$"], 1, 2],
   If[pkgList === {}, 0,
     With[{p = FirstPosition[pkgList, Lookup[a, "Pkg", ""]]},
       If[MissingQ[p], 999, First[p]]]],
   If[Lookup[a, "Freshness", "Fresh"] === "Fresh", 0, 1],
   StringLength[Lookup[a, "Symbol", ""]],
   Lookup[a, "Symbol", ""]};

Options[SourceVault`SourceVaultPackageApiSearch] =
  {"MaxResults" -> 10, "MinScore" -> 3., "Packages" -> All,
   "ExpandRelated" -> False};

SourceVault`SourceVaultPackageApiSearch[
    query_String, OptionsPattern[]] :=
  Module[{reqPkgs, pkgs, pkgList, qLower, qTokens, qBigrams, aliasIdx,
          useBigram, results = {}},
    (* Packages 正規化 + scoped ensure (R2 B-1/B-3) *)
    reqPkgs = iPANormalizePackages[OptionValue["Packages"]];
    If[reqPkgs === All, iPAEnsureAll[], Scan[iPAEnsureIndex, reqPkgs]];
    pkgs = If[reqPkgs === All, Keys[$svPAIndex],
      Intersection[Keys[$svPAIndex], reqPkgs]];
    pkgList = If[reqPkgs === All, {}, reqPkgs];
    qLower = ToLowerCase[query];
    qTokens = iPAQueryTokens[query];
    qBigrams = iPABigrams[query];
    aliasIdx = iPAAliasIndex[];
    (* whole-query bigram は ASCII 語を全く含まない query (Japanese 等) の
       フォールバックに限定。ASCII 語がある query は token 採点に委ね、全て
       stopword なら 0 件を返す (無関係注入をしない、R2 B-7)。 *)
    useBigram = !StringContainsQ[query, RegularExpression["[A-Za-z]"]];
    Scan[
      Function[pkg,
        With[{pkgTokens = iPASymbolTokens[pkg]},
        Scan[
          Function[chunk,
            Module[{sym = chunk["Symbol"], score = 0., reasons = {},
                    symLower, tk},
              symLower = ToLowerCase[sym];
              (* 強加点 1: 関数名/変数名の完全一致 (R-spec §8.2) *)
              Which[
                StringContainsQ[qLower, symLower],
                  score += 12.; AppendTo[reasons, "SymbolExactInQuery"],
                StringLength[query] >= 5 &&
                  StringContainsQ[symLower, qLower],
                  score += 8.; AppendTo[reasons, "QueryInSymbol"]];
              (* 強加点 2: legacy alias 一致 -> 正準 symbol を上位 *)
              Scan[
                Function[al,
                  If[aliasIdx[al] === sym &&
                     StringContainsQ[qLower, ToLowerCase[al]],
                    score += 9.;
                    AppendTo[reasons, "AliasCanonical: " <> al]]],
                Keys[aliasIdx]];
              (* 強加点 3: aux keyword 一致 (aux task-match > main) *)
              With[{b = iPAAuxKeywordBonus[query, pkg,
                  Lookup[chunk, "AuxName", ""]]},
                If[b > 0, score += b;
                  AppendTo[reasons, "AuxKeywordMatch"]]];
              (* 加点 4: トークン単位 OR (R2 B-4/B-5/B-6) *)
              tk = iPATokenScore[qTokens, iPASymbolTokens[sym],
                iPACamelWords[Lookup[chunk, "Section", ""]], pkgTokens];
              If[First[tk] > 0,
                score += First[tk]; reasons = Join[reasons, Last[tk]]];
              (* 弱加点: whole-query bigram (useBigram = ASCII 語なしのときのみ)。
                 ASCII 概念 query では token 採点が精密なので希釈
                 (source/vault 部分一致の一律ノイズ) を避ける。 *)
              If[useBigram,
                With[{ov = iPAOverlap[qBigrams,
                    sym <> " " <> Lookup[chunk, "Section", ""] <> " " <>
                    StringTake[Lookup[chunk, "Body", ""], UpTo[200]]]},
                  If[ov >= 3,
                    score += Min[4., ov/3.];
                    AppendTo[reasons,
                      "BigramOverlap(" <> ToString[ov] <> ")"]]]];
              If[score >= OptionValue["MinScore"],
                AppendTo[results,
                  <|"Symbol" -> sym, "Uri" -> chunk["Uri"],
                    "Pkg" -> pkg,
                    "AuxName" -> Lookup[chunk, "AuxName", ""],
                    "Section" -> Lookup[chunk, "Section", ""],
                    "Kind" -> Lookup[chunk, "Kind", "function"],
                    "Score" -> score, "Reasons" -> reasons,
                    "Freshness" -> Lookup[chunk, "Freshness", "Fresh"],
                    "Signature" -> Lookup[chunk, "Signature", sym]|>]]]],
          Values @ Lookup[Lookup[$svPAIndex, pkg, <||>],
            "ByUri", <||>]]]],
      pkgs];
    results = Take[SortBy[results, iPASearchSortKey[pkgList, #] &],
      UpTo[OptionValue["MaxResults"]]];
    results = MapIndexed[Append[#1, "Rank" -> First[#2]] &, results];
    If[TrueQ[OptionValue["ExpandRelated"]],
      results = Map[
        Append[#, "Related" ->
          SourceVault`SourceVaultPackageApiRelated[#["Symbol"],
            "MaxResults" -> 5]] &, results]];
    results
  ];

(* ============================================================
   5. related candidates (W-spec §8.2)
   ============================================================ *)

$svPARelationWeights = <|
  "Composable" -> 5., "AliasCanonical" -> 4.5, "UseInsteadOf" -> 4.,
  "SameCapability" -> 3., "SameSection" -> 2.,
  "RequiresNeighbor" -> 1.5, "SimilarUsage" -> 1.|>;

iPAPortsCompatibleQ[outPort_, inPort_] :=
  (StringQ[Lookup[outPort, "DomainKind"]] &&
     Lookup[outPort, "DomainKind"] === Lookup[inPort, "DomainKind"]) ||
  (StringQ[Lookup[outPort, "MediaKind"]] &&
     Lookup[outPort, "MediaKind"] === Lookup[inPort, "MediaKind"]);

Options[SourceVault`SourceVaultPackageApiRelated] = {"MaxResults" -> 8};

SourceVault`SourceVaultPackageApiRelated[
    symOrUri_String, OptionsPattern[]] :=
  Module[{chunk, sym, contract, out = {}, add, myContract},
    chunk = If[StringStartsQ[symOrUri, "sv://"],
      Module[{hit = Missing[]},
        iPAEnsureAll[];
        Scan[
          Function[pkg,
            With[{c = Lookup[Lookup[Lookup[$svPAIndex, pkg, <||>],
                "ByUri", <||>], symOrUri]},
              If[AssociationQ[c] && MissingQ[hit], hit = c]]],
          Keys[$svPAIndex]];
        hit],
      SourceVault`SourceVaultPackageApiResolve[symOrUri]];
    If[!AssociationQ[chunk], Return[{}]];
    sym = chunk["Symbol"];
    add[relSym_, relation_, reason_] :=
      If[relSym =!= sym &&
         !AnyTrue[out, #["Symbol"] === relSym &&
           #["Relation"] === relation &],
        With[{rc = SourceVault`SourceVaultPackageApiResolve[relSym]},
          AppendTo[out,
            <|"Symbol" -> relSym,
              "Uri" -> If[AssociationQ[rc], rc["Uri"], Missing[]],
              "Relation" -> relation,
              "Score" -> $svPARelationWeights[relation],
              "Reason" -> reason|>]]];

    myContract = If[iPAContractsAvailableQ[],
      Quiet @ Check[SourceVault`SourceVaultFunctionContract[sym],
        Missing[]], Missing[]];

    (* 契約由来 (決定的) *)
    If[AssociationQ[myContract],
      (* AliasCanonical: 自分の deprecated alias *)
      Scan[add[#, "AliasCanonical",
          "deprecated alias of " <> sym] &,
        Lookup[myContract, "Supersedes", {}]];
      (* UseInsteadOf *)
      Scan[
        Function[r,
          If[MatchQ[r, _Rule],
            add[First[r], "UseInsteadOf", Last[r]]]],
        Lookup[myContract, "UseInsteadOf", {}]];
      If[iPAContractsAvailableQ[],
        Scan[
          Function[other,
            Module[{osym = other["Symbol"]},
              (* Composable: 自分の出力 -> 相手の入力 (W-spec: 契約から決定的) *)
              If[AnyTrue[Lookup[myContract, "Outputs", {}],
                  Function[op, AnyTrue[Lookup[other, "Inputs", {}],
                    iPAPortsCompatibleQ[op, #] &]]],
                add[osym, "Composable",
                  "output port of " <> sym <> " feeds its input"]];
              (* SameCapability *)
              If[Intersection[
                    Lookup[myContract, "CapabilityTags", {}],
                    Lookup[other, "CapabilityTags", {}]] =!= {},
                add[osym, "SameCapability",
                  StringRiffle[Intersection[
                    Lookup[myContract, "CapabilityTags", {}],
                    Lookup[other, "CapabilityTags", {}]], ", "]]];
              (* RequiresNeighbor *)
              If[Intersection[
                    Lookup[myContract, "Requires", {}],
                    Lookup[other, "Requires", {}]] =!= {} &&
                 Lookup[other, "Requires", {}] =!= {},
                add[osym, "RequiresNeighbor", "shared init requirements"]]]],
          Select[SourceVault`SourceVaultFunctionContracts[],
            #["Symbol"] =!= sym &]]]];

    (* chunk 由来 *)
    Module[{idx = Lookup[$svPAIndex, chunk["Pkg"], <||>], sameSec, simTop},
      sameSec = Select[Values @ Lookup[idx, "ByUri", <||>],
        Lookup[#, "Section", ""] === Lookup[chunk, "Section", "?"] &&
          Lookup[#, "SourceFile"] === Lookup[chunk, "SourceFile"] &&
          #["Symbol"] =!= sym &];
      Scan[add[#["Symbol"], "SameSection",
          Lookup[chunk, "Section", ""]] &,
        Take[sameSec, UpTo[4]]];
      (* SimilarUsage: 本文 bigram 近傍 (同 pkg、上位のみ) *)
      With[{qb = iPABigrams[StringTake[Lookup[chunk, "Body", ""],
          UpTo[300]]]},
        simTop = Take[
          Reverse @ SortBy[
            Select[
              Map[{#, iPAOverlap[qb,
                  StringTake[Lookup[#, "Body", ""], UpTo[300]]]} &,
                Select[Values @ Lookup[idx, "ByUri", <||>],
                  #["Symbol"] =!= sym &]],
              #[[2]] >= 15 &],
            Last],
          UpTo[3]];
        Scan[add[#[[1]]["Symbol"], "SimilarUsage",
            "usage text similarity"] &, simTop]]];

    Take[Reverse @ SortBy[out, Lookup[#, "Score"] &],
      UpTo[OptionValue["MaxResults"]]]
  ];

(* ============================================================
   6. Get / tier 描画 (W-spec §8.1 / §8.3)
   ============================================================ *)

iPASummaryText[chunk_Association] :=
  Module[{paras},
    paras = Select[
      StringSplit[Lookup[chunk, "Body", ""], "\n\n" | "\n"],
      StringTrim[#] =!= "" &&
        !StringStartsQ[StringTrim[#],
          "Options:" | "\[RightArrow]" | "→" | "->"] &];
    If[paras === {}, "", First[paras]]];

iPARenderTier[chunk_Association, tier_String] :=
  Module[{sym = chunk["Symbol"], lines = {}, contract, explain},
    AppendTo[lines, "### " <> Lookup[chunk, "Signature", sym]];
    AppendTo[lines, iPASummaryText[chunk]];
    With[{r = Lookup[chunk, "ReturnsLine"]},
      If[StringQ[r], AppendTo[lines, r]]];
    With[{o = Lookup[chunk, "OptionsLine"]},
      If[StringQ[o], AppendTo[lines, o]]];
    contract = If[iPAContractsAvailableQ[],
      Quiet @ Check[SourceVault`SourceVaultFunctionContract[sym],
        Missing[]], Missing[]];
    Which[
      tier === "Guided" || tier === "Scaffolded",
        If[AssociationQ[contract] &&
           Lookup[contract, "Requires", {}] =!= {},
          AppendTo[lines, "Requires: " <>
            StringRiffle[contract["Requires"], ", "]]];
        (* body 抜粋: 既に載せた要約/Returns/Options 行と重複する部分は除く *)
        Module[{body = Lookup[chunk, "Body", ""]},
          Scan[
            Function[dup,
              If[StringQ[dup] && dup =!= "",
                body = StringReplace[body, dup -> "", 1]]],
            {iPASummaryText[chunk], Lookup[chunk, "ReturnsLine"],
             Lookup[chunk, "OptionsLine"]}];
          body = StringTrim @ StringReplace[body,
            ("\n\n\n" | "\n\n") .. -> "\n\n"];
          If[body =!= "",
            AppendTo[lines, StringTake[body, UpTo[600]]]]]];
    If[tier === "Scaffolded",
      (* 完全テンプレート + allowed options のみ (W-spec §8.3, G-tier-1) *)
      explain = If[AssociationQ[contract] &&
          Names["SourceVault`SourceVaultExplainCallContract"] =!= {},
        Quiet @ Check[
          SourceVault`SourceVaultExplainCallContract[sym], Missing[]],
        Missing[]];
      If[StringQ[explain], AppendTo[lines, explain]];
      If[AssociationQ[contract] &&
         Lookup[contract, "Requires", {}] =!= {},
        AppendTo[lines,
          "Template (run this first):\n  SourceVaultEnsureInitialized[\"" <>
          sym <> "\"]"]];
      AppendTo[lines,
        "Use ONLY the options listed above; do not invent option names."]];
    StringRiffle[DeleteCases[lines, ""], "\n"]
  ];

Options[SourceVault`SourceVaultPackageApiGet] =
  {"View" -> "summary", "Tier" -> Automatic};

SourceVault`SourceVaultPackageApiGet[
    symOrUri_String, OptionsPattern[]] :=
  Module[{chunk, view = OptionValue["View"], tier = OptionValue["Tier"],
          meta},
    chunk = If[StringStartsQ[symOrUri, "sv://"],
      Module[{hit = Missing[]},
        iPAEnsureAll[];
        Scan[
          Function[pkg,
            With[{c = Lookup[Lookup[Lookup[$svPAIndex, pkg, <||>],
                "ByUri", <||>], symOrUri]},
              If[AssociationQ[c] && MissingQ[hit],
                hit = iPADecorate[c]]]],
          Keys[$svPAIndex]];
        hit],
      SourceVault`SourceVaultPackageApiResolve[symOrUri]];
    If[!AssociationQ[chunk],
      Return[Missing["NotFound", symOrUri]]];
    If[tier === Automatic, tier = "Expert"];
    meta = KeyDrop[chunk, {"Body", "SectionPreface", "Signatures"}];
    Switch[view,
      "metadata",
        Append[meta, "PrivacyLevel" -> 0.],
      "summary",
        Join[meta, <|"Text" -> iPARenderTier[chunk, tier],
          "Tier" -> tier, "PrivacyLevel" -> 0.|>],
      "body",
        Join[meta, <|"Text" -> Lookup[chunk, "Body", ""],
          "PrivacyLevel" -> 0.|>],
      "contract",
        (* W-spec §8.1: 契約 registry の投影。評価可能式は含めない (W10) *)
        If[!iPAContractsAvailableQ[],
          Failure["ContractsUnavailable",
            <|"MessageTemplate" ->
              "SourceVault packageapi: ContractsUnavailable"|>],
          With[{c = Quiet @ Check[
              SourceVault`SourceVaultFunctionContract[chunk["Symbol"]],
              Missing[]]},
            If[!AssociationQ[c],
              Missing["NoContract", chunk["Symbol"]],
              Join[
                KeyDrop[c, {"InitializedQRef"}],   (* ref 名すら不要な評価情報は落とす *)
                <|"InitializedQRef" ->
                    Lookup[c, "InitializedQRef", Missing[]],  (* 名前のみ (W10) *)
                  "Uri" -> chunk["Uri"],
                  "AuditStatus" -> Lookup[chunk, "AuditStatus", "?"],
                  "Freshness" -> Lookup[chunk, "Freshness", "Fresh"],
                  "PrivacyLevel" -> 0.|>]]]],
      _,
        Failure["InvalidView",
          <|"MessageTemplate" -> "SourceVault packageapi: InvalidView",
            "Detail" -> view|>]]
  ];

End[] (* `PackageApiPrivate` *)

EndPackage[]
