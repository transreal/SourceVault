(* ::Package:: *)

(* ============================================================
   SourceVault_oapdf.wl -- 論文ページのオープンアクセス PDF を見つけて取り込む

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_oapdf.wl"]] (SourceVault.wl のローダが読む)

   何をするか:
     Nature / Elsevier / PNAS / Frontiers などの論文ページ (web ソース) にオープンアクセスの PDF が
     あれば、その PDF を別の web ソースとして ingest し、ページのソースと相互に結ぶ。
     翻訳ノートブック (SourceVault_papernb.wl) は PDF が結ばれていれば PDF から作る (数式・図が崩れない)。
     SourceVaultIngest[url] は論文ページを取り込んだ直後にこれを呼ぶ ($SourceVaultAutoOpenAccessPDF)。
     ページ自体が 401/403 で取れない (PNAS・ScienceDirect) ときも、URL から DOI が分かれば PDF だけ取り込む。

   オープンアクセスの判定 (どれか 1 つあれば OA):
     ページの Creative Commons ライセンスへのリンク / schema.org の "isAccessibleForFree": true /
     Crossref のライセンス (CC で開始日が到来) / Europe PMC の isOpenAccess / Unpaywall の is_oa (メール設定時)。
     OA の証拠が無ければ出版社の PDF は取りに行かない (大学の IP で購読誌の PDF が落とせても、
     公開データ (PL 0) として取り込まない)。arXiv のプレプリントは常に可。

   PDF の候補 (この順に試し、本当に PDF (先頭が %PDF-) が返ったものを使う):
     arXiv (arxiv.org の abs / html / pdf → SourceVaultIngest["arXiv:..."]) /
     ページの citation_pdf_url / <link type="application/pdf"> /
     出版社の URL 規則 (Nature: <記事>.pdf、/doi/(abs|full|epdf)/ → /doi/pdf/、PNAS: /doi/pdf/<DOI>、Frontiers: /full → /pdf) /
     Crossref の PDF リンク / Europe PMC (PMC の OA 版。出版社のサイトが機械取得を拒むとき。Europe PMC の
     検索 API は 502 / 503 を間欠的に返すので 3 回までやり直し、だめなら NCBI の ID 変換で PMCID を引く) /
     Unpaywall (メール設定時) / Elsevier API (NBAccess に "elsevier" のキーがあるとき、DOI 10.1016 のみ) /
     ページが citation_arxiv_id を持てば arXiv のプレプリント。
     401 / 403 / 429 で拒まれたら回避はせず次の候補へ (Status "Blocked" として記録)。

   保存:
     PDF のソースのメタ: Title / Authors / Published / DOI / License / LandingSourceId / LandingURL / OpenAccessVia
     ページのソースのメタ: "OpenAccessPDF" -> <|Status ("Linked" | "NotOpenAccess" | "NoCandidate" | "Blocked" |
       "NotRetrieved"), SourceId, URL, Via, DOI, License, CheckedAt, Tried|>
     見つからなかった結果も記録し、$SourceVaultOARecheckDays 日は自動では再試行しない (Force で再試行)。

   外部サービス: Crossref (api.crossref.org)・Europe PMC (www.ebi.ac.uk / europepmc.org)・NCBI の ID 変換
     (www.ncbi.nlm.nih.gov) は認証なし・DOI だけを送る。
     Unpaywall は利用者のメールアドレスが要るので既定では使わない ($SourceVaultUnpaywallEmail を設定したときだけ)。
     Elsevier API のキーは NBAccess`NBGetAPIKey["elsevier"] (SystemCredential "ELSEVIER_API_KEY") から取り、
     HTTP ヘッダでだけ送る (URL・ログ・メタには残さない)。
   ============================================================ *)

BeginPackage["SourceVault`"]

SourceVaultFindOpenAccessPDF::usage =
  "SourceVaultFindOpenAccessPDF[ref, opts] は論文ページ (ingest 済みの src-ID / URL / DOI \"doi:10....\" / arXiv の URL) の " <>
  "オープンアクセス PDF を探す (ダウンロード・取り込みはしない)。戻り値 <|\"Status\" (\"Found\" | \"NotScholarly\" | " <>
  "\"NotOpenAccess\" | \"NoCandidate\"), \"DOI\", \"ArXivId\", \"Title\", \"Authors\", \"Published\", \"OpenAccess\", " <>
  "\"Evidence\" (OA の根拠), \"License\", \"Candidates\" ({<|\"URL\", \"Via\"|>..})|>。" <>
  "opts: \"RequireOpenAccess\" -> True (OA の根拠が無ければ出版社の PDF を候補にしない), \"FetchPage\" -> True (未取り込みの URL はページを読みに行く)。";

SourceVaultIngestOpenAccessPDF::usage =
  "SourceVaultIngestOpenAccessPDF[ref, opts] は論文ページのオープンアクセス PDF を探して web ソースとして ingest し、" <>
  "ページのソースと結ぶ (ページのメタに \"OpenAccessPDF\"、PDF のメタに LandingSourceId / DOI / Title / Authors / License)。" <>
  "ref = ingest 済みの src-ID / URL / DOI / arXiv の URL (ページが 403 で取り込めなくても DOI が分かれば PDF だけ取り込む)。" <>
  "戻り値 <|\"Status\" (\"Ingested\" | \"AlreadyIngested\" | \"NotScholarly\" | \"NotOpenAccess\" | \"NoCandidate\" | " <>
  "\"Blocked\" | \"NotRetrieved\"), \"SourceId\" (PDF のソース), \"LandingSourceId\", \"URL\", \"Via\", \"DOI\", \"License\", " <>
  "\"Tried\" ({<|URL, Via, Reason, StatusCode|>..}), \"Cached\"|>。PDF の PrivacyLevel と Topic はページのソースから継承。" <>
  "opts: \"Force\" -> False (確認済みでも探し直す。既定では $SourceVaultOARecheckDays 日以内の確認結果を返す), " <>
  "\"RequireOpenAccess\" -> True, \"FetchPage\" -> True, \"Verbose\" -> False。";

SourceVaultOpenAccessPDFSource::usage =
  "SourceVaultOpenAccessPDFSource[ref] はページのソース (src-ID / URL) に結ばれたオープンアクセス PDF のソース " <>
  "<|\"SourceId\", \"URL\", \"File\" (現 PC の raw パス), \"Title\", \"PrivacyLevel\", \"Via\", \"DOI\", \"License\", \"LandingSourceId\"|> を返す。" <>
  "結ばれていなければ Missing (確認結果の Status を理由に入れる)。翻訳ノートブック (SourceVaultMakePaperNotebook) が使う。";

SourceVaultBackfillOpenAccessPDFs::usage =
  "SourceVaultBackfillOpenAccessPDFs[opts] は ingest 済みの web ソースのうち論文ページ (DOI / citation_pdf_url / arXiv) を走査し、" <>
  "オープンアクセス PDF を取り込んで結ぶ。結果の Dataset (SourceId, Title, Status, Via, PDFSourceId, DOI) を返す。" <>
  "opts: \"Force\" -> False (確認済みも探し直す), \"Limit\" -> All, \"DryRun\" -> False (True = 探すだけ), \"Verbose\" -> True。";

$SourceVaultAutoOpenAccessPDF::usage =
  "$SourceVaultAutoOpenAccessPDF (既定 True) は SourceVaultIngest[url] が論文ページを取り込んだ直後 (または 401/403 で取れなかったとき) に " <>
  "オープンアクセス PDF も取り込むか。SourceVaultIngest[url, \"OpenAccessPDF\" -> False] でその回だけ止められる。";

$SourceVaultUnpaywallEmail::usage =
  "$SourceVaultUnpaywallEmail (既定 None) に連絡先メールアドレスを設定すると Unpaywall (api.unpaywall.org) にも DOI を問い合わせ、" <>
  "リポジトリ版などの OA PDF も候補にする (Unpaywall の利用条件でメールアドレスの送信が要る)。";

$SourceVaultOARecheckDays::usage =
  "$SourceVaultOARecheckDays (既定 30) は見つからなかった (NotOpenAccess / Blocked 等) 確認結果を自動では再試行しない日数。" <>
  "PMC への登載や公開猶予の明けで後から取れるようになるため。";

Begin["`Private`"]

If[! ValueQ[SourceVault`$SourceVaultAutoOpenAccessPDF], SourceVault`$SourceVaultAutoOpenAccessPDF = True];
If[! ValueQ[SourceVault`$SourceVaultUnpaywallEmail], SourceVault`$SourceVaultUnpaywallEmail = None];
If[! ValueQ[SourceVault`$SourceVaultOARecheckDays], SourceVault`$SourceVaultOARecheckDays = 30];

$iOAUserAgent = "SourceVault/1.0 (Wolfram Language; open-access PDF lookup)";
$iOAMaxPDFBytes = 200 * 10^6;

iOAStr[v_] := Which[StringQ[v], v, v === Null || MissingQ[v] || v === None, "", True, ToString[v]];

(* ---------------- HTTP (テストはこの 2 つを Block で差し替える) ---------------- *)

(* GET → <|"StatusCode", "ContentType", "Bytes"|> | $Failed *)
iOAGet[url_String, query_List, headers_List] :=
  Module[{r},
    r = Quiet[URLRead[HTTPRequest[url, <|"Query" -> query,
        "Headers" -> Join[{"User-Agent" -> $iOAUserAgent}, headers]|>],
      {"StatusCode", "ContentType", "BodyByteArray"}, TimeConstraint -> 30]];
    If[AssociationQ[r],
      <|"StatusCode" -> r["StatusCode"], "ContentType" -> iOAStr[r["ContentType"]], "Bytes" -> r["BodyByteArray"]|>,
      $Failed]];

(* ファイルの先頭 n バイト (All = 全部)。ReadByteArray[path, n] はファイルを開いたままにし、
   次の ReadByteArray[path] が続きから読んでしまう (先頭の <meta> を取りこぼした) ので、自分で開いて閉じる *)
iOAReadBytes[path_String, n_ : All] :=
  Module[{s = Quiet[OpenRead[path, BinaryFormat -> True]], b},
    If[Head[s] =!= InputStream, Return[$Failed]];
    b = Quiet[If[n === All, ReadByteArray[s], ReadByteArray[s, n]]];
    Close[s];
    If[ByteArrayQ[b], b, $Failed]];

(* PDF を一時ファイルへ → iFetchURL と同じ形 (iIngestURL の "PrefetchedFetch" にそのまま渡せる) か失敗理由 *)
iOADownloadPDF[url_String, headers_List] :=
  Module[{dir, tmp, r, code, ct, size, head},
    dir = FileNameJoin[{SourceVault`$SourceVaultRoots["Tmp"], "sourcevault", "fetch"}];
    iEnsureDir[dir];
    tmp = FileNameJoin[{dir, iRandomTmpName[""]}];
    r = Quiet[TimeConstrained[
      URLDownload[HTTPRequest[url, <|"Headers" -> Join[{"User-Agent" -> $iOAUserAgent,
          "Accept" -> "application/pdf,*/*;q=0.8"}, headers]|>], tmp, {"StatusCode", "ContentType"}],
      180, $Failed]];
    If[! AssociationQ[r],
      Quiet[DeleteFile[tmp]];
      Return[<|"Status" -> "Failed", "Reason" -> "FetchFailed", "URL" -> url|>]];
    code = r["StatusCode"];
    ct = ToLowerCase[iOAStr[r["ContentType"]]];
    size = If[FileExistsQ[tmp], Quiet[FileByteCount[tmp]], 0];
    head = If[IntegerQ[size] && size >= 5, With[{b = iOAReadBytes[tmp, 5]}, If[ByteArrayQ[b], FromCharacterCode[Normal[b]], ""]], ""];
    Which[
      ! IntegerQ[code] || code < 200 || code >= 300,
        Quiet[DeleteFile[tmp]];
        <|"Status" -> "Failed", "Reason" -> If[MemberQ[{401, 403, 429}, code], "Blocked", "HTTPError"],
          "StatusCode" -> If[IntegerQ[code], code, 0], "URL" -> url|>,
      head =!= "%PDF-",
        Quiet[DeleteFile[tmp]];
        <|"Status" -> "Failed", "Reason" -> "NotPDF", "StatusCode" -> code, "ContentType" -> ct, "URL" -> url|>,
      size > $iOAMaxPDFBytes,
        Quiet[DeleteFile[tmp]];
        <|"Status" -> "Failed", "Reason" -> "TooLarge", "StatusCode" -> code, "URL" -> url|>,
      True,
        <|"Status" -> "OK", "TmpFile" -> tmp, "StatusCode" -> code, "ContentType" -> "application/pdf",
          "ContentLength" -> size, "Headers" -> {}, "URL" -> url|>]];

(* 一時的な失敗 (Europe PMC は 502 / 503 を間欠的に返す) は間を置いて 3 回まで *)
$iOATransientCodes = {429, 500, 502, 503, 504};
iOAGetJSON[url_String, query_List] :=
  Module[{r, j, k = 0},
    While[True,
      r = iOAGet[url, query, {"Accept" -> "application/json"}];
      k++;
      If[k >= 3 || (AssociationQ[r] && ! MemberQ[$iOATransientCodes, r["StatusCode"]]), Break[]];
      Pause[1.5 k]];
    If[! AssociationQ[r] || r["StatusCode"] =!= 200 || ! ByteArrayQ[r["Bytes"]], Return[Missing["HTTP"]]];
    j = Quiet[ImportByteArray[r["Bytes"], "RawJSON"]];
    If[AssociationQ[j], j, Missing["BadJSON"]]];

(* 一時的な失敗 (5xx・接続失敗) だけ 1 度やり直す。出版社の 401 / 403 は拒否なのでやり直さない。
   Europe PMC の PDF (europepmc.org/articles/PMC..?pdf=render) は続けざまの要求に 403 / 429 を返し、
   数秒後の同じ要求には 200 を返す (2026-10-12 実測) ので、そこだけ間を置いて 2 回までやり直す *)
iOADownloadWithRetry[url_String, headers_List] :=
  Module[{f = iOADownloadPDF[url, headers], epmc = StringContainsQ[url, "europepmc.org/", IgnoreCase -> True], k = 0},
    While[k < If[epmc, 2, 1] &&
        (Lookup[f, "Reason", ""] === "FetchFailed" ||
         (Lookup[f, "Reason", ""] === "HTTPError" && MemberQ[$iOATransientCodes, Lookup[f, "StatusCode", 0]]) ||
         (epmc && Lookup[f, "Reason", ""] === "Blocked")),
      k++; Pause[3 k]; f = iOADownloadPDF[url, headers]];
    f];

iOABytesToString[b_] :=
  Module[{s},
    If[! ByteArrayQ[b], Return[""]];
    s = Quiet[ByteArrayToString[b, "UTF-8"]];
    If[StringQ[s], s, FromCharacterCode[Normal[b]]]];

(* ---------------- ページ (HTML) から読む ---------------- *)

iOADecodeEntities[s_String] := StringReplace[s, {"&amp;" -> "&", "&quot;" -> "\"", "&#39;" -> "'", "&#x27;" -> "'",
  "&lt;" -> "<", "&gt;" -> ">", "&#x2F;" -> "/", "&#47;" -> "/"}];

(* <meta name|property|itemprop="..." content="..."> → {name -> content, ..} (name は小文字。同名は複数あり得る) *)
iOAMetaTags[html_String] :=
  Map[Function[t, Module[{nm, ct},
      nm = StringCases[t, RegularExpression["(?i)\\b(?:name|property|itemprop)\\s*=\\s*[\"']([^\"']+)[\"']"] -> "$1", 1];
      ct = StringCases[t, RegularExpression["(?is)\\bcontent\\s*=\\s*\"([^\"]*)\"|\\bcontent\\s*=\\s*'([^']*)'"] -> "$1$2", 1];
      If[nm === {} || ct === {}, Nothing, ToLowerCase[First[nm]] -> StringTrim[iOADecodeEntities[First[ct]]]]]],
    StringCases[html, RegularExpression["(?is)<meta\\b[^>]*>"]]];

iOAMeta[tags_List, names_List] := Select[Flatten[Map[Function[n, Cases[tags, (n -> v_String) :> v]], names]], # =!= "" &];

iOAPDFLinkTags[html_String] :=
  Flatten[Map[Function[t,
      If[StringContainsQ[t, RegularExpression["(?i)type\\s*=\\s*[\"']application/pdf[\"']"]],
        iOADecodeEntities /@ StringCases[t, RegularExpression["(?i)\\bhref\\s*=\\s*[\"']([^\"']+)[\"']"] -> "$1", 1], {}]],
    StringCases[html, RegularExpression["(?is)<link\\b[^>]*>"]]]];

iOAHTMLTitle[html_String] :=
  With[{m = StringCases[html, RegularExpression["(?is)<title[^>]*>(.*?)</title>"] -> "$1", 1]},
    If[m === {}, "", StringTrim[StringReplace[iOADecodeEntities[First[m]], WhitespaceCharacter .. -> " "]]]];

iOAFreeToReadQ[html_String] := StringContainsQ[html, RegularExpression["(?i)\"isAccessibleForFree\"\\s*:\\s*\"?true"]];

iOAPageLicense[html_String] :=
  With[{m = StringCases[html, RegularExpression["(?i)creativecommons\\.org/(?:licenses|publicdomain)/[a-z0-9./-]+"], 1]},
    If[m === {}, "", "https://" <> First[m]]];

(* ---------------- 識別子 (DOI / arXiv / Elsevier PII) ---------------- *)

iOACleanDOI[s_String] :=
  Module[{m = StringCases[URLDecode[s], RegularExpression["10\\.\\d{4,9}/[^\\s\"'<>#?&]+"], 1]},
    If[m === {}, "", StringReplace[First[m], ("." | "," | ";" | ")" | "]") .. ~~ EndOfString -> ""]]];
iOACleanDOI[_] := "";

iOADOIFromURL[url_String] :=
  Module[{m},
    Which[
      StringContainsQ[url, RegularExpression["(?i)(?:dx\\.)?doi\\.org/10\\."]], iOACleanDOI[url],
      StringContainsQ[url, RegularExpression["(?i)/doi/(?:abs/|full/|epdf/|pdf/|epub/|reader/|pdfdirect/)?10\\."]], iOACleanDOI[url],
      (m = StringCases[url, RegularExpression["(?i)nature\\.com/articles/([a-z0-9][a-z0-9.\\-]*[a-z0-9])"] -> "$1", 1]) =!= {},
        "10.1038/" <> StringReplace[First[m], ".pdf" ~~ EndOfString -> ""],
      True, ""]];

iOAArXivId[s_String] :=
  With[{m = StringCases[s, RegularExpression["(?i)(?:arxiv\\.org/(?:abs|html|pdf)/|arxiv[.:])(\\d{4}\\.\\d{4,5})"] -> "$1", 1]},
    If[m === {}, "", First[m]]];

iOAPII[url_String] :=
  With[{m = StringCases[url, RegularExpression["(?i)/pii/(S?[0-9X]{15,17})"] -> "$1", 1]},
    If[m === {}, "", ToUpperCase[First[m]]]];

(* URL だけで論文と分かるか (ページが 403 で取れないときの判定) *)
iOAScholarlyURLQ[url_String] := iOADOIFromURL[url] =!= "" || iOAArXivId[url] =!= "" || iOAPII[url] =!= "";
iOAScholarlyURLQ[_] := False;

(* ---------------- 外部メタデータ ---------------- *)

(* Crossref の date-parts {{2024, 9, 11}} → "2024-09-11" *)
iOADateString[parts_] :=
  If[MatchQ[parts, {{_Integer, ___}, ___}],
    StringRiffle[MapIndexed[If[First[#2] === 1, ToString[#1], IntegerString[#1, 10, 2]] &, First[parts]], "-"], ""];

iOACrossref[doi_String] :=
  Module[{j = iOAGetJSON["https://api.crossref.org/works/" <> URLEncode[doi], {}], m},
    If[! AssociationQ[j], Return[<||>]];
    m = Lookup[j, "message", <||>];
    If[! AssociationQ[m], Return[<||>]];
    <|"Title" -> iOAStr[First[Replace[Lookup[m, "title", {}], Except[_List] -> {}], ""]],
      "Authors" -> Map[StringTrim[iOAStr[Lookup[#, "given", ""]] <> " " <> iOAStr[Lookup[#, "family", ""]]] &,
        Select[Replace[Lookup[m, "author", {}], Except[_List] -> {}], AssociationQ]],
      "Published" -> iOADateString[Lookup[Replace[Lookup[m, "published", Lookup[m, "issued", <||>]], Except[_Association] -> <||>], "date-parts", {}]],
      "Licenses" -> Select[Replace[Lookup[m, "license", {}], Except[_List] -> {}], AssociationQ],
      "Links" -> Select[Replace[Lookup[m, "link", {}], Except[_List] -> {}], AssociationQ]|>];

iOACrossrefDOIByPII[pii_String] :=
  Module[{j = iOAGetJSON["https://api.crossref.org/works", {"filter" -> "alternative-id:" <> pii, "rows" -> "1"}], items},
    items = If[AssociationQ[j], Lookup[Lookup[j, "message", <||>], "items", {}], {}];
    If[ListQ[items] && items =!= {} && AssociationQ[First[items]], iOAStr[Lookup[First[items], "DOI", ""]], ""]];

(* CC / パブリックドメインのライセンスで、開始日が到来しているもの *)
iOAActiveOpenLicenseQ[lic_Association] :=
  Module[{u = ToLowerCase[iOAStr[Lookup[lic, "URL", ""]]], parts},
    If[! StringContainsQ[u, "creativecommons.org"], Return[False]];
    parts = Lookup[Replace[Lookup[lic, "start", <||>], Except[_Association] -> <||>], "date-parts", {}];
    If[MatchQ[parts, {{_Integer, ___}, ___}], DateObject[First[parts]] <= Today, True]];

iOAEuropePMC[doi_String] :=
  Module[{j, res, x, urls, pdf, pmcid, oa},
    j = iOAGetJSON["https://www.ebi.ac.uk/europepmc/webservices/rest/search",
      {"query" -> "DOI:" <> doi, "format" -> "json", "resultType" -> "core", "pageSize" -> "1"}];
    res = If[AssociationQ[j], Lookup[Lookup[j, "resultList", <||>], "result", {}], {}];
    If[! ListQ[res] || res === {} || ! AssociationQ[First[res]], Return[<||>]];
    x = First[res];
    pmcid = iOAStr[Lookup[x, "pmcid", ""]];
    oa = Lookup[x, "isOpenAccess", "N"] === "Y";
    urls = Select[Replace[Lookup[Replace[Lookup[x, "fullTextUrlList", <||>], Except[_Association] -> <||>], "fullTextUrl", {}],
      Except[_List] -> {}], AssociationQ];
    pdf = SelectFirst[urls, Lookup[#, "documentStyle", ""] === "pdf" && Lookup[#, "availabilityCode", ""] === "OA" &, None];
    <|"PMCID" -> pmcid, "OpenAccess" -> oa, "License" -> iOAStr[Lookup[x, "license", ""]],
      "PDFURL" -> Which[
        AssociationQ[pdf], iOAStr[Lookup[pdf, "url", ""]],
        oa && StringStartsQ[pmcid, "PMC"], "https://europepmc.org/articles/" <> pmcid <> "?pdf=render",
        True, ""],
      "Title" -> iOAStr[Lookup[x, "title", ""]]|>];

(* Europe PMC の検索 API が落ちているときの代わり: NCBI の ID 変換 (DOI → PMCID。認証不要・DOI だけ送る) *)
iOAPMCIDFromNCBI[doi_String] :=
  Module[{j = iOAGetJSON["https://www.ncbi.nlm.nih.gov/pmc/utils/idconv/v1.0/",
      {"ids" -> doi, "format" -> "json", "tool" -> "sourcevault"}], recs},
    recs = If[AssociationQ[j], Select[Replace[Lookup[j, "records", {}], Except[_List] -> {}], AssociationQ], {}];
    If[recs === {}, "", With[{p = iOAStr[Lookup[First[recs], "pmcid", ""]]}, If[StringStartsQ[p, "PMC"], p, ""]]]];

iOAUnpaywall[doi_String] :=
  Module[{email = SourceVault`$SourceVaultUnpaywallEmail, j, locs},
    If[! StringQ[email] || ! StringContainsQ[email, "@"], Return[<||>]];
    j = iOAGetJSON["https://api.unpaywall.org/v2/" <> URLEncode[doi], {"email" -> email}];
    If[! AssociationQ[j], Return[<||>]];
    locs = Select[Prepend[Replace[Lookup[j, "oa_locations", {}], Except[_List] -> {}],
      Replace[Lookup[j, "best_oa_location", <||>], Except[_Association] -> <||>]], AssociationQ];
    <|"OpenAccess" -> TrueQ[Lookup[j, "is_oa", False]],
      "PDFURLs" -> DeleteDuplicates[Select[iOAStr[Lookup[#, "url_for_pdf", ""]] & /@ locs, # =!= "" &]],
      "License" -> iOAStr[Lookup[First[locs, <||>], "license", ""]]|>];

(* Elsevier API のキーが設定されているか (真偽値だけ。キーはダウンロードの直前に NBGetAPIKey から
   ヘッダへ直接入れ、変数・ログ・メタ・URL には残さない) *)
iOAElsevierAvailableQ[] :=
  Length[DownValues[NBAccess`NBGetAPIKey]] > 0 &&
  StringQ[Quiet[NBAccess`NBGetAPIKey["elsevier", NBAccess`PrivacySpec -> <|"AccessLevel" -> 1.0|>]]];

(* ---------------- 対象 (ページのソース・ページの本文) ---------------- *)

iOALatestRaw[meta_Association] :=
  Module[{snaps = Lookup[meta, "Snapshots", {}], snap},
    snap = If[ListQ[snaps] && snaps =!= {}, iSnapshotMetaLoad[Last[snaps]], Missing[]];
    If[AssociationQ[snap], iSVLiveRawPathOf[snap], ""]];

iOAReadHTML[path_String] :=
  If[path =!= "" && FileExistsQ[path] && MemberQ[{"html", "htm", "xhtml", "shtml"}, ToLowerCase[FileExtension[path]]],
    StringTake[iOABytesToString[iOAReadBytes[path]], UpTo[4000000]], ""];

iOALandingSid[ref_String] :=
  Which[
    StringStartsQ[ref, "src-"], If[AssociationQ[iSourceMetaLoad[ref]], ref, ""],
    StringMatchQ[ref, RegularExpression["(?i)https?://.+"]],
      With[{r = Quiet[Check[SourceVault`SourceVaultResolveReference[ref], $Failed]]},
        If[AssociationQ[r] && Lookup[r, "Status", ""] === "OK", iOAStr[r["SourceId"]], ""]],
    True, ""];

iOARefDOI[ref_String] :=
  Which[
    StringStartsQ[ref, "doi:", IgnoreCase -> True], iOACleanDOI[StringDrop[ref, 4]],
    StringStartsQ[ref, "10."], iOACleanDOI[ref],
    True, ""];

(* <|"Ref", "LandingSourceId", "LandingMeta", "PageURL", "HTML", "PL", "Topic"|> *)
iOAContext[ref_String, fetchPage_] :=
  Module[{sid = iOALandingSid[ref], meta = <||>, url = "", html = "", doi = iOARefDOI[ref], r},
    If[sid =!= "",
      meta = iSourceMetaLoad[sid];
      url = iOAStr[Lookup[meta, "OriginalURL", ""]];
      html = iOAReadHTML[iOALatestRaw[meta]]];
    If[url === "", url = Which[
      StringMatchQ[ref, RegularExpression["(?i)https?://.+"]], ref,
      doi =!= "", "https://doi.org/" <> doi,
      True, ""]];
    (* 取り込んでいないページは読みに行く (403 なら空のまま、URL / DOI だけで進む) *)
    If[html === "" && TrueQ[fetchPage] && StringMatchQ[url, RegularExpression["(?i)https?://.+"]] && iOAArXivId[url] === "",
      r = iOAGet[url, {}, {"Accept" -> "text/html,application/xhtml+xml"}];
      If[AssociationQ[r] && r["StatusCode"] === 200 && StringContainsQ[ToLowerCase[r["ContentType"]], "html"],
        html = StringTake[iOABytesToString[r["Bytes"]], UpTo[4000000]]]];
    <|"Ref" -> ref, "LandingSourceId" -> sid, "LandingMeta" -> If[AssociationQ[meta], meta, <||>],
      "PageURL" -> url, "HTML" -> html, "DOIHint" -> doi,
      "PL" -> With[{p = Lookup[meta, "PrivacyLevel", Missing[]]}, If[NumericQ[p], N[p], Automatic]],
      "Topic" -> With[{t = Lookup[meta, "Topic", Null]}, If[StringQ[t], t, Automatic]]|>];

(* ---------------- 解析: OA の根拠と PDF の候補 ---------------- *)

iOAPublisherPDFURLs[pageURL_String, doi_String] :=
  DeleteDuplicates @ Select[{
    If[StringMatchQ[pageURL, RegularExpression["(?i)https?://(www\\.)?nature\\.com/articles/[^/?#]+"]] &&
       ! StringEndsQ[pageURL, ".pdf", IgnoreCase -> True],
      StringReplace[pageURL, RegularExpression["[?#].*$"] -> ""] <> ".pdf", ""],
    If[StringMatchQ[pageURL, RegularExpression["(?i)https?://[^/]*frontiersin\\.org/.+/full([?#].*)?"]],
      StringReplace[StringReplace[pageURL, RegularExpression["[?#].*$"] -> ""], RegularExpression["/full$"] -> "/pdf"], ""],
    If[StringMatchQ[pageURL, RegularExpression["(?i)https?://[^/]+/doi/(abs|full|epdf|reader|epub)/10\\..+"]],
      StringReplace[pageURL, RegularExpression["(?i)/doi/(abs|full|epdf|reader|epub)/"] -> "/doi/pdf/", 1], ""],
    If[StringStartsQ[doi, "10.1073/"], "https://www.pnas.org/doi/pdf/" <> doi, ""]},
    # =!= "" &];

iOAAbsURL[base_String, u_String] :=
  Which[
    StringMatchQ[u, RegularExpression["(?i)https?://.+"]], u,
    StringStartsQ[u, "//"], "https:" <> u,
    StringStartsQ[u, "/"] && StringMatchQ[base, RegularExpression["(?i)https?://.+"]],
      First[StringCases[base, RegularExpression["(?i)^https?://[^/?#]+"]]] <> u,
    True, u];

Options[iOAAnalyze] = {"RequireOpenAccess" -> True};
iOAAnalyze[ctx_Association, OptionsPattern[]] :=
  Module[{html = ctx["HTML"], url = ctx["PageURL"], tags, doi, arxiv, preprint, pii, cr = <||>, ep = <||>, up = <||>,
          evidence = {}, license = "", oa, cands = {}, add, title, authors, published, pdfMeta},
    tags = If[html === "", {}, iOAMetaTags[html]];
    doi = Which[
      ctx["DOIHint"] =!= "", ctx["DOIHint"],
      (doi = SelectFirst[iOACleanDOI /@ iOAMeta[tags, {"citation_doi", "prism.doi", "dc.identifier", "bepress_citation_doi", "dc.relation"}],
        # =!= "" &, ""]) =!= "", doi,
      True, iOADOIFromURL[url]];
    arxiv = Which[iOAArXivId[url] =!= "", iOAArXivId[url], iOAArXivId[doi] =!= "", iOAArXivId[doi], True, ""];
    preprint = If[arxiv === "", SelectFirst[iOAArXivId["arXiv:" <> #] & /@ iOAMeta[tags, {"citation_arxiv_id"}], # =!= "" &, ""], ""];
    pii = iOAPII[url];
    If[doi === "" && pii =!= "", doi = iOACrossrefDOIByPII[pii]];
    pdfMeta = iOAAbsURL[url, #] & /@ Join[iOAMeta[tags, {"citation_pdf_url", "eprints.document_url", "bepress_citation_pdf_url"}],
      iOAPDFLinkTags[html]];
    If[doi === "" && arxiv === "" && pdfMeta === {},
      Return[<|"Status" -> "NotScholarly", "PageURL" -> url, "Candidates" -> {}|>]];
    add = Function[{u, via, oaNeeded}, If[StringQ[u] && u =!= "" && ! MemberQ[Lookup[cands, "URL", {}], u],
      AppendTo[cands, <|"URL" -> u, "Via" -> via, "NeedsOA" -> oaNeeded|>]]];
    (* arXiv そのもの: OA の根拠は要らない *)
    If[arxiv =!= "",
      add["arXiv:" <> arxiv, "arxiv", False];
      Return[<|"Status" -> "Found", "PageURL" -> url, "DOI" -> doi, "ArXivId" -> arxiv, "Title" -> iOAHTMLTitle[html],
        "Authors" -> {}, "Published" -> "", "OpenAccess" -> True, "Evidence" -> {"arxiv"}, "License" -> "",
        "Candidates" -> cands|>]];
    (* OA の根拠 *)
    If[iOAFreeToReadQ[html], AppendTo[evidence, "page:isAccessibleForFree"]];
    license = iOAPageLicense[html];
    If[license =!= "", AppendTo[evidence, "page:license " <> license]];
    If[doi =!= "",
      cr = iOACrossref[doi];
      With[{act = Select[Lookup[cr, "Licenses", {}], iOAActiveOpenLicenseQ]},
        If[act =!= {},
          AppendTo[evidence, "crossref:license " <> iOAStr[Lookup[First[act], "URL", ""]]];
          If[license === "", license = iOAStr[Lookup[First[act], "URL", ""]]]]];
      ep = iOAEuropePMC[doi];
      If[TrueQ[Lookup[ep, "OpenAccess", False]], AppendTo[evidence, "europepmc:isOpenAccess " <> iOAStr[Lookup[ep, "PMCID", ""]]];
        If[license === "", license = iOAStr[Lookup[ep, "License", ""]]]];
      up = iOAUnpaywall[doi];
      If[TrueQ[Lookup[up, "OpenAccess", False]], AppendTo[evidence, "unpaywall:is_oa"];
        If[license === "", license = iOAStr[Lookup[up, "License", ""]]]]];
    oa = evidence =!= {};
    (* PDF の候補 (出版社 → Crossref → Europe PMC → Unpaywall → Elsevier API → プレプリント) *)
    Scan[add[#, "citation_pdf_url", True] &, pdfMeta];
    Scan[add[#, "publisher-pattern", True] &, iOAPublisherPDFURLs[url, doi]];
    Scan[Function[l, With[{u = iOAStr[Lookup[l, "URL", ""]], ct = ToLowerCase[iOAStr[Lookup[l, "content-type", ""]]],
        app = iOAStr[Lookup[l, "intended-application", ""]]},
      If[(ct === "application/pdf" || StringContainsQ[u, "pdf", IgnoreCase -> True]) && app =!= "text-mining" &&
         ! StringContainsQ[u, "api.elsevier.com"], add[u, "crossref", True]]]], Lookup[cr, "Links", {}]];
    add[iOAStr[Lookup[ep, "PDFURL", ""]], "europepmc", True];
    If[doi =!= "" && iOAStr[Lookup[ep, "PDFURL", ""]] === "",
      With[{pm = iOAPMCIDFromNCBI[doi]},
        If[pm =!= "", add["https://europepmc.org/articles/" <> pm <> "?pdf=render", "pmc", True]]]];
    Scan[add[#, "unpaywall", True] &, Lookup[up, "PDFURLs", {}]];
    If[StringStartsQ[doi, "10.1016/"] && iOAElsevierAvailableQ[],
      add["https://api.elsevier.com/content/article/doi/" <> doi <> "?httpAccept=application/pdf", "elsevier-api", True]];
    If[preprint =!= "", add["arXiv:" <> preprint, "arxiv-preprint", False]];
    If[TrueQ[OptionValue["RequireOpenAccess"]] && ! oa, cands = Select[cands, ! #["NeedsOA"] &]];
    title = SelectFirst[{iOAStr[Lookup[cr, "Title", ""]], First[iOAMeta[tags, {"citation_title", "dc.title", "og:title"}], ""],
      iOAHTMLTitle[html], iOAStr[Lookup[ep, "Title", ""]]}, # =!= "" &, ""];
    authors = With[{a = Lookup[cr, "Authors", {}]}, If[ListQ[a] && a =!= {}, a, iOAMeta[tags, {"citation_author", "dc.creator"}]]];
    published = SelectFirst[{iOAStr[Lookup[cr, "Published", ""]],
      First[iOAMeta[tags, {"citation_publication_date", "citation_date", "dc.date", "prism.publicationdate"}], ""]}, # =!= "" &, ""];
    <|"Status" -> Which[cands =!= {}, "Found", ! oa && TrueQ[OptionValue["RequireOpenAccess"]], "NotOpenAccess", True, "NoCandidate"],
      "PageURL" -> url, "DOI" -> doi, "ArXivId" -> preprint, "Title" -> title, "Authors" -> authors, "Published" -> published,
      "OpenAccess" -> oa, "Evidence" -> evidence, "License" -> license, "Candidates" -> cands|>];

Options[SourceVaultFindOpenAccessPDF] = {"RequireOpenAccess" -> True, "FetchPage" -> True};
SourceVaultFindOpenAccessPDF[ref_String, OptionsPattern[]] :=
  Module[{info},
    iEnsureRoots[];
    info = iOAAnalyze[iOAContext[ref, OptionValue["FetchPage"]], "RequireOpenAccess" -> OptionValue["RequireOpenAccess"]];
    Append[info, "Candidates" -> Map[KeyTake[#, {"URL", "Via"}] &, Lookup[info, "Candidates", {}]]]];

(* ---------------- 取り込みと結び付け ---------------- *)

(* iIngestURL と同じ規則で、その URL の web ソースが既にあればその SourceId *)
iOAExistingURLSource[url_String] :=
  Module[{c = Quiet[iCanonicalizeURL[url]], sid, m},
    If[! AssociationQ[c] || Lookup[c, "Status", ""] =!= "OK" || Lookup[c, "SourceKind", ""] === "ArXiv", Return[""]];
    sid = iMakeSourceId["url", StringTake[iComputeSHA256[c["URL"]], UpTo[12]]];
    m = iSourceMetaLoad[sid];
    If[AssociationQ[m] && With[{p = iOALatestRaw[m]}, p =!= "" && FileExistsQ[p]], sid, ""]];

iOAIngestOKQ[r_] := AssociationQ[r] && MemberQ[{"Ingested", "AlreadyCurrent", "RebuiltMetadata"}, Lookup[r, "Status", ""]];

iOARecentQ[rec_Association] :=
  Module[{t = Quiet[DateObject[iOAStr[Lookup[rec, "CheckedAt", ""]]]]},
    DateObjectQ[t] && (Now - t) < Quantity[SourceVault`$SourceVaultOARecheckDays, "Days"]];

(* PDF のソースのメタに書誌とページへの参照を足す (題は空かファイル名のときだけ上書き) *)
iOAAnnotatePDFSource[pdfSid_String, info_Association, landingSid_String, landingURL_String, via_String] :=
  Module[{m = iSourceMetaLoad[pdfSid], t},
    If[! AssociationQ[m], Return[$Failed]];
    t = iOAStr[Lookup[m, "Title", ""]];
    If[iOAStr[info["Title"]] =!= "" && (t === "" || t === iOAStr[Lookup[m, "DisplayName", ""]] ||
        StringEndsQ[t, ".pdf", IgnoreCase -> True] || StringContainsQ[t, "?pdf="]),
      m["Title"] = info["Title"]];
    If[ListQ[info["Authors"]] && info["Authors"] =!= {} && ! MatchQ[Lookup[m, "Authors", {}], {__}], m["Authors"] = info["Authors"]];
    If[iOAStr[info["Published"]] =!= "" && iOAStr[Lookup[m, "Published", ""]] === "", m["Published"] = info["Published"]];
    If[iOAStr[info["DOI"]] =!= "", m["DOI"] = info["DOI"]];
    If[iOAStr[info["License"]] =!= "", m["License"] = info["License"]];
    If[landingSid =!= "", m["LandingSourceId"] = landingSid];
    If[landingURL =!= "", m["LandingURL"] = landingURL];
    m["OpenAccessVia"] = via;
    iSourceMetaSave[pdfSid, m]];

(* ページのメタに確認結果を書く。ページの題が未設定なら書誌の題で埋める (既にあれば触らない) *)
iOARecordLanding[landingSid_String, rec_Association, title_String : ""] :=
  If[landingSid =!= "",
    With[{m = iSourceMetaLoad[landingSid]},
      If[AssociationQ[m],
        iSourceMetaSave[landingSid, Join[m, <|"OpenAccessPDF" -> rec|>,
          If[title =!= "" && StringTrim[iOAStr[Lookup[m, "Title", ""]]] === "", <|"Title" -> title|>, <||>]]]]]];

Options[SourceVaultIngestOpenAccessPDF] = {"Force" -> False, "RequireOpenAccess" -> True, "FetchPage" -> True, "Verbose" -> False};
SourceVaultIngestOpenAccessPDF[ref_String, OptionsPattern[]] :=
  Module[{ctx, sid, prior, info, tried = {}, got = None, status, rec, verbose = TrueQ[OptionValue["Verbose"]], log},
    iEnsureRoots[];
    log = Function[s, If[verbose, Print["[OA PDF] ", s]]];
    ctx = iOAContext[ref, OptionValue["FetchPage"]];
    sid = ctx["LandingSourceId"];
    (* PDF のソース自身 (取り込んだ OA PDF や PDF の URL) はページではない *)
    If[sid =!= "" && (KeyExistsQ[ctx["LandingMeta"], "LandingSourceId"] ||
        ToLowerCase[FileExtension[iOALatestRaw[ctx["LandingMeta"]]]] === "pdf"),
      Return[<|"Status" -> "IsPDF", "LandingSourceId" -> sid, "SourceId" -> sid, "Cached" -> False|>]];
    (* 確認済み: 結ばれている PDF が生きていればそれ、見つからなかった結果は期限内なら繰り返さない *)
    prior = Lookup[ctx["LandingMeta"], "OpenAccessPDF", None];
    If[! TrueQ[OptionValue["Force"]] && AssociationQ[prior],
      Which[
        Lookup[prior, "Status", ""] === "Linked" && AssociationQ[iSourceMetaLoad[iOAStr[Lookup[prior, "SourceId", ""]]]],
          Return[Join[prior, <|"Status" -> "AlreadyIngested", "LandingSourceId" -> sid, "Cached" -> True|>]],
        Lookup[prior, "Status", ""] =!= "Linked" && iOARecentQ[prior],
          Return[Join[prior, <|"LandingSourceId" -> sid, "Cached" -> True|>]]]];
    info = iOAAnalyze[ctx, "RequireOpenAccess" -> OptionValue["RequireOpenAccess"]];
    log[ctx["PageURL"] <> " -> " <> info["Status"] <> " (DOI " <> iOAStr[Lookup[info, "DOI", ""]] <> ")"];
    If[info["Status"] === "NotScholarly",
      Return[<|"Status" -> "NotScholarly", "LandingSourceId" -> sid, "URL" -> "", "Cached" -> False|>]];
    If[info["Status"] =!= "Found",
      rec = <|"Status" -> info["Status"], "DOI" -> iOAStr[info["DOI"]], "Evidence" -> info["Evidence"],
        "CheckedAt" -> iIsoNow[], "Tried" -> {}|>;
      iOARecordLanding[sid, rec, iOAStr[info["Title"]]];
      Return[Join[rec, <|"LandingSourceId" -> sid, "Cached" -> False|>]]];
    Catch[
      Do[
        Module[{u = c["URL"], via = c["Via"], existing, fetch, r},
          Which[
            StringStartsQ[u, "arXiv:"],
              r = SourceVault`SourceVaultIngest[u, "OpenAccessPDF" -> False];
              If[iOAIngestOKQ[r],
                Throw[got = <|"SourceId" -> iOAStr[r["SourceId"]], "URL" -> iOAStr[Lookup[r, "URL", u]], "Via" -> via,
                  "New" -> (r["Status"] =!= "AlreadyCurrent")|>, "oa"],
                AppendTo[tried, <|"URL" -> u, "Via" -> via, "Reason" -> iOAStr[Lookup[r, "Reason", "IngestFailed"]], "StatusCode" -> 0|>]],
            (existing = iOAExistingURLSource[u]) =!= "",
              Throw[got = <|"SourceId" -> existing, "URL" -> u, "Via" -> via, "New" -> False|>, "oa"],
            True,
              log["try " <> via <> ": " <> u];
              fetch = If[via === "elsevier-api",
                iOADownloadWithRetry[u, Replace[Quiet[NBAccess`NBGetAPIKey["elsevier", NBAccess`PrivacySpec -> <|"AccessLevel" -> 1.0|>]],
                  {k_String :> {"X-ELS-APIKey" -> k}, _ -> {}}]],
                iOADownloadWithRetry[u, {}]];
              If[Lookup[fetch, "Status", ""] =!= "OK",
                AppendTo[tried, <|"URL" -> u, "Via" -> via, "Reason" -> iOAStr[Lookup[fetch, "Reason", "Failed"]],
                  "StatusCode" -> Replace[Lookup[fetch, "StatusCode", 0], Except[_Integer] -> 0]|>],
                r = iIngestURL[u, PrivacyLabel -> ctx["PL"], Topic -> ctx["Topic"], "PrefetchedFetch" -> fetch];
                Quiet[DeleteFile[fetch["TmpFile"]]];
                If[iOAIngestOKQ[r],
                  Throw[got = <|"SourceId" -> iOAStr[r["SourceId"]], "URL" -> u, "Via" -> via,
                    "New" -> (r["Status"] =!= "AlreadyCurrent")|>, "oa"],
                  AppendTo[tried, <|"URL" -> u, "Via" -> via, "Reason" -> iOAStr[Lookup[r, "Reason", "IngestFailed"]],
                    "StatusCode" -> 0|>]]]]],
        {c, info["Candidates"]}],
      "oa"];
    If[! AssociationQ[got],
      status = If[AnyTrue[tried, #["Reason"] === "Blocked" &], "Blocked", "NotRetrieved"];
      rec = <|"Status" -> status, "DOI" -> iOAStr[info["DOI"]], "Evidence" -> info["Evidence"],
        "CheckedAt" -> iIsoNow[], "Tried" -> tried|>;
      iOARecordLanding[sid, rec, iOAStr[info["Title"]]];
      log[status <> ": " <> ToString[Length[tried]] <> " candidates failed"];
      Return[Join[rec, <|"LandingSourceId" -> sid, "Cached" -> False|>]]];
    iOAAnnotatePDFSource[got["SourceId"], info, sid, ctx["PageURL"], got["Via"]];
    rec = <|"Status" -> "Linked", "SourceId" -> got["SourceId"], "URL" -> got["URL"], "Via" -> got["Via"],
      "DOI" -> iOAStr[info["DOI"]], "License" -> iOAStr[info["License"]], "Evidence" -> info["Evidence"],
      "CheckedAt" -> iIsoNow[], "Tried" -> tried|>;
    iOARecordLanding[sid, rec, iOAStr[info["Title"]]];
    log["linked " <> got["SourceId"] <> " via " <> got["Via"]];
    iLog["OpenAccessPDF", <|"LandingSourceId" -> sid, "SourceId" -> got["SourceId"], "Via" -> got["Via"], "DOI" -> iOAStr[info["DOI"]]|>];
    Join[rec, <|"Status" -> If[TrueQ[got["New"]], "Ingested", "AlreadyIngested"], "LandingSourceId" -> sid,
      "Title" -> iOAStr[info["Title"]], "Cached" -> False|>]];

SourceVaultOpenAccessPDFSource[ref_String] :=
  Module[{sid = iOALandingSid[ref], meta, rec, pm, file},
    If[sid === "", Return[Missing["NotIngested"]]];
    meta = iSourceMetaLoad[sid];
    rec = If[AssociationQ[meta], Lookup[meta, "OpenAccessPDF", None], None];
    If[! AssociationQ[rec], Return[Missing["NotChecked"]]];
    If[Lookup[rec, "Status", ""] =!= "Linked", Return[Missing[iOAStr[Lookup[rec, "Status", "NotFound"]]]]];
    pm = iSourceMetaLoad[iOAStr[rec["SourceId"]]];
    If[! AssociationQ[pm], Return[Missing["PDFSourceMissing"]]];
    file = iOALatestRaw[pm];
    <|"SourceId" -> rec["SourceId"], "URL" -> iOAStr[Lookup[rec, "URL", ""]], "File" -> file,
      "Title" -> iOAStr[Lookup[pm, "Title", ""]],
      "PrivacyLevel" -> With[{p = Lookup[pm, "PrivacyLevel", 1.0]}, If[NumericQ[p], N[p], 1.0]],
      "Via" -> iOAStr[Lookup[rec, "Via", ""]], "DOI" -> iOAStr[Lookup[rec, "DOI", ""]],
      "License" -> iOAStr[Lookup[rec, "License", ""]], "LandingSourceId" -> sid|>];

(* SourceVaultIngest[url] の後に呼ばれる (SourceVault.wl)。論文ページなら OA PDF も取り込み、結果に "OpenAccessPDF" を足す。
   取り込みの結果そのものは変えない (失敗しても ingest は成功のまま) *)
iSVOpenAccessAfterIngest[res_Association, url_String, opts_List] :=
  Module[{st = iOAStr[Lookup[res, "Status", ""]], raw = iOAStr[Lookup[res, "RawPath", ""]], sid = iOAStr[Lookup[res, "SourceId", ""]],
          code, oa},
    If[! TrueQ[SourceVault`$SourceVaultAutoOpenAccessPDF] || Lookup[Association[opts], "OpenAccessPDF", True] === False,
      Return[res]];
    code = Lookup[res, "StatusCode", Lookup[Replace[Lookup[res, "Detail", <||>], Except[_Association] -> <||>], "StatusCode", 0]];
    oa = Which[
      MemberQ[{"Ingested", "RebuiltMetadata", "AlreadyCurrent"}, st] && sid =!= "" &&
        MemberQ[{"html", "htm", "xhtml", "shtml"}, ToLowerCase[FileExtension[raw]]],
        Quiet[TimeConstrained[SourceVaultIngestOpenAccessPDF[sid], 300, <|"Status" -> "Timeout"|>]],
      st === "Failed" && MemberQ[{401, 403, 429}, code] && iOAScholarlyURLQ[url],
        Quiet[TimeConstrained[SourceVaultIngestOpenAccessPDF[url, "FetchPage" -> False], 300, <|"Status" -> "Timeout"|>]],
      True, Return[res]];
    If[AssociationQ[oa] && Lookup[oa, "Status", ""] =!= "NotScholarly",
      Append[res, "OpenAccessPDF" -> KeyTake[oa, {"Status", "SourceId", "URL", "Via", "DOI"}]],
      res]];
iSVOpenAccessAfterIngest[res_, ___] := res;

(* ---------------- 既存ソースの一括補完 ---------------- *)

iOAScholarlyPageQ[meta_Association] :=
  Module[{url = iOAStr[Lookup[meta, "OriginalURL", ""]], raw = iOALatestRaw[meta], head},
    (* ページ (HTML) だけ。PDF のソースは対象外 *)
    If[raw === "" || ! MemberQ[{"html", "htm", "xhtml", "shtml"}, ToLowerCase[FileExtension[raw]]], Return[False]];
    If[iOAScholarlyURLQ[url], Return[True]];
    head = iOABytesToString[iOAReadBytes[raw, 600000]];
    StringContainsQ[head, "citation_pdf_url" | "citation_doi" | "prism.doi" | "citation_arxiv_id", IgnoreCase -> True]];

Options[SourceVaultBackfillOpenAccessPDFs] = {"Force" -> False, "Limit" -> All, "DryRun" -> False, "Verbose" -> True};
SourceVaultBackfillOpenAccessPDFs[OptionsPattern[]] :=
  Module[{rows = {}, n = 0, lim = OptionValue["Limit"], dry = TrueQ[OptionValue["DryRun"]]},
    iEnsureRoots[];
    Do[
      Module[{m = iSourceMetaLoad[id], r},
        If[AssociationQ[m] && Lookup[m, "SourceType", ""] === "URL" && ! KeyExistsQ[m, "LandingSourceId"] &&
           (lim === All || n < lim) && iOAScholarlyPageQ[m],
          n++;
          r = If[dry, SourceVaultFindOpenAccessPDF[id], SourceVaultIngestOpenAccessPDF[id, "Force" -> OptionValue["Force"]]];
          AppendTo[rows, <|"SourceId" -> id,
            "Title" -> StringTake[iOAStr[Lookup[m, "Title", Lookup[m, "OriginalURL", ""]]], UpTo[80]],
            "Status" -> iOAStr[Lookup[r, "Status", ""]],
            "Via" -> iOAStr[Lookup[r, "Via", If[dry, StringRiffle[Lookup[Lookup[r, "Candidates", {}], "Via", {}], ","], ""]]],
            "PDFSourceId" -> iOAStr[Lookup[r, "SourceId", ""]], "DOI" -> iOAStr[Lookup[r, "DOI", ""]]|>];
          If[TrueQ[OptionValue["Verbose"]], Print[id, "  ", Last[rows]["Status"], "  ", Last[rows]["Via"], "  ", Last[rows]["Title"]]]]],
      {id, Select[SourceVaultList[], StringStartsQ[#, "src-url-"] &]}];
    Dataset[rows]];

End[]

EndPackage[]
