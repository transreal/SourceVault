# SourceVault_oapdf API リファレンス

論文ページ (Nature / Elsevier / PNAS / Frontiers などの web ソース) にオープンアクセスの PDF があれば、その PDF を別の web ソースとして ingest し、ページのソースと相互に結ぶ (2026-10-12)。コンテキスト `SourceVault\`` (private は本体と同じ `` `Private` ``。core の ingest・メタの読み書きを使う)。SourceVault.wl のローダが `SourceVault_papernb.wl` の次に読む。

**自動**: `SourceVaultIngest[url]` は論文ページを取り込んだ直後 (再取り込みで未確認のときも) にこれを呼び、結果に `"OpenAccessPDF" -> <|Status, SourceId, URL, Via, DOI|>` を足す (ingest 自体の結果は変えない)。ページが 401 / 403 / 429 で取れない (PNAS・ScienceDirect) ときも、URL から DOI (`/doi/…`, `doi.org/…`, Nature の記事 ID, ScienceDirect の PII → Crossref) が分かれば PDF だけ取り込む。止めるには `$SourceVaultAutoOpenAccessPDF = False` か `SourceVaultIngest[url, "OpenAccessPDF" -> False]`。

**翻訳ノートブック**: `SourceVaultMakePaperNotebook` は web の HTML ソースに OA PDF が結ばれていれば PDF から `DocImportPaper` で作る (未確認ならその場で探す。`"PreferPDF" -> False` で HTML から)。

## オープンアクセスの判定

次のどれか 1 つがあれば OA。無ければ出版社の PDF は取りに行かない (大学の IP で購読誌の PDF が落とせても公開データ PL 0 として取り込まない)。arXiv は常に可。

- ページの Creative Commons ライセンスへのリンク (`creativecommons.org/licenses|publicdomain/…`)
- ページの schema.org `"isAccessibleForFree": true`
- Crossref (`api.crossref.org/works/<DOI>`) のライセンスが CC で開始日が到来している
- Europe PMC の `isOpenAccess = Y`
- Unpaywall の `is_oa` (`$SourceVaultUnpaywallEmail` を設定したときだけ)

## PDF の候補 (この順に試す)

本当に PDF (先頭が `%PDF-`) が返ったものを使う。出版社の 401 / 403 は拒否として回避せず次の候補へ (`Tried` に記録)。

1. arXiv (arxiv.org の abs / html / pdf、DOI 10.48550) → `SourceVaultIngest["arXiv:…"]`
2. ページの `citation_pdf_url` / `<link type="application/pdf">`
3. 出版社の URL 規則: Nature `<記事>.pdf`、`/doi/(abs|full|epdf|reader|epub)/` → `/doi/pdf/`、PNAS `/doi/pdf/<DOI>`、Frontiers `/full` → `/pdf`
4. Crossref の PDF リンク (text-mining 用と api.elsevier.com は除く)
5. Europe PMC の OA 版 (`europepmc.org/articles/PMC…?pdf=render`)。検索 API の 5xx は 3 回までやり直し、だめなら NCBI の ID 変換 (DOI → PMCID)。PDF の 403 / 429 は続けざまの要求への制限なので間を置いて 2 回までやり直す
6. Unpaywall の `url_for_pdf` (メール設定時)
7. Elsevier API (`api.elsevier.com/content/article/doi/<DOI>?httpAccept=application/pdf`、DOI 10.1016 のみ、`NBAccess\`NBGetAPIKey["elsevier"]` (SystemCredential `ELSEVIER_API_KEY`) があるときだけ。キーはヘッダ `X-ELS-APIKey` でだけ送り、URL・メタ・ログには残さない)
8. ページの `citation_arxiv_id` のプレプリント

外部へ送るのは DOI (と Unpaywall に設定したメール) だけ。Crossref・Europe PMC・NCBI は認証なし。

## 保存

- PDF のソースのメタ: `Title` (空かファイル名のときだけ書誌の題で上書き) / `Authors` / `Published` / `DOI` / `License` / `LandingSourceId` / `LandingURL` / `OpenAccessVia`。PrivacyLevel と Topic はページのソースから継承 (公開ページなら 0)。
- ページのソースのメタ: `"OpenAccessPDF" -> <|"Status" ("Linked" | "NotOpenAccess" | "NoCandidate" | "Blocked" | "NotRetrieved"), "SourceId", "URL", "Via", "DOI", "License", "Evidence", "CheckedAt", "Tried" ({<|URL, Via, Reason, StatusCode|>..})|>`。ページの題が未設定なら書誌の題で埋める。見つからなかった結果も記録し `$SourceVaultOARecheckDays` 日は自動で再試行しない。
- PDF の取り込みは `iIngestURL[pdfURL, "PrefetchedFetch" -> 検証済みダウンロード]` (同じ PDF を 2 度落とさない。既に同じ URL のソースがあればダウンロードせず結ぶ)。

## 変数

| 記号 | 既定 | 意味 |
|---|---|---|
| `$SourceVaultAutoOpenAccessPDF` | True | `SourceVaultIngest[url]` の後に OA PDF も取り込む |
| `$SourceVaultUnpaywallEmail` | None | 設定すると Unpaywall にも問い合わせる (利用条件でメールアドレスの送信が要る) |
| `$SourceVaultOARecheckDays` | 30 | 見つからなかった確認結果を自動では再試行しない日数 (PMC 登載・公開猶予明けで後から取れることがある) |

## 関数

### SourceVaultFindOpenAccessPDF[ref, opts] → Association
探すだけ (ダウンロード・書き込みなし)。ref = ingest 済みの src-ID / URL (未取り込みならページを読みに行く) / `"doi:10.…"` / arXiv の URL。
→ `<|"Status" ("Found" | "NotScholarly" | "NotOpenAccess" | "NoCandidate"), "DOI", "ArXivId", "Title", "Authors", "Published", "OpenAccess", "Evidence", "License", "Candidates" ({<|"URL", "Via"|>..})|>`
Options: "RequireOpenAccess" -> True (False なら OA の根拠が無くても出版社の PDF を候補に出す), "FetchPage" -> True

### SourceVaultIngestOpenAccessPDF[ref, opts] → Association
探して取り込み、ページと結ぶ。
→ `<|"Status" ("Ingested" | "AlreadyIngested" | "IsPDF" | "NotScholarly" | "NotOpenAccess" | "NoCandidate" | "Blocked" | "NotRetrieved"), "SourceId" (PDF のソース), "LandingSourceId", "URL", "Via", "DOI", "License", "Evidence", "Tried", "Title", "Cached"|>`
Options: "Force" -> False (確認済みでも探し直す), "RequireOpenAccess" -> True, "FetchPage" -> True, "Verbose" -> False
例: `SourceVaultIngestOpenAccessPDF["src-url-…", "Verbose" -> True]`、`SourceVaultIngestOpenAccessPDF["https://www.pnas.org/doi/10.1073/pnas.…"]`

### SourceVaultOpenAccessPDFSource[ref] → Association | Missing
ページに結ばれた PDF のソース `<|"SourceId", "URL", "File" (現 PC の raw パス), "Title", "PrivacyLevel", "Via", "DOI", "License", "LandingSourceId"|>`。結ばれていなければ `Missing["NotChecked" | "NotOpenAccess" | "Blocked" | …]`。

### SourceVaultBackfillOpenAccessPDFs[opts] → Dataset
ingest 済みの web ソースのうち論文ページ (HTML で DOI / citation_pdf_url / citation_arxiv_id / 論文 URL) を走査して取り込む。列: SourceId, Title, Status, Via, PDFSourceId, DOI。
Options: "Force" -> False, "Limit" -> All, "DryRun" -> False (True = `SourceVaultFindOpenAccessPDF` だけ。何も書かない), "Verbose" -> True
注意: arXiv の候補は arXiv の ingest になるので、アブストラクトの翻訳要約 (クラウド LLM) も走る。

## 一覧との接続

`SourceVaultSourcesView` (`iSVRenderRowsGrid`) の「ファイル」列: web の行に OA PDF が結ばれていれば「▶ 開く」の隣に「▶ PDF」(PDF のソースを開く)。PDF のソース自身も題 (Crossref) 付きの web ソースとして一覧に並び、「翻訳NB」はページ・PDF のどちらの行からでも同じノートを引く (登録の `PDFSourceId`)。

## 検証

`test codes/SourceVault_oapdf_test.wl` (37、`wolfram.exe -noinit -noprompt -script` で実行。vault を一時ディレクトリへ移し、ネットワークは全部モック: Nature 型 / PNAS 型 (出版社 403 → Europe PMC) / 購読誌 (ダウンロードしない) / ページ 403 / Europe PMC の 502・403 のやり直し / NCBI の ID 変換 / 非論文 / 一括補完 / 翻訳NB の PDF 優先 / 一覧の PDF ボタン)。実ネットワーク (2026-10-12、一時 vault): Nature・Frontiers は citation_pdf_url、PNAS (2022・2026) と Cell は Europe PMC で取得。ScienceDirect の SoftwareX は OA と判定できるが Elsevier のキー無しでは PDF に届かず `NoCandidate`。
