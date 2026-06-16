(* ::Package:: *)

(* ============================================================
   SourceVault.wl -- \:5916\:90e8 source \:7ba1\:7406\:30d1\:30c3\:30b1\:30fc\:30b8
   
   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault.wl"]]
   Or via claudecode.wl which handles encoding automatically.
   
   \:4ed5\:69d8\:66f8: sourcevault-spec-v0_13.md
                     sourcevault-physical-storage-extension-v0_13.md
   \:5b9f\:88c5 Stage: 0-3 + Stage 4 Phase 4A
     Stage 0: \:6539\:540d (WikiDB -> SourceVault) \:3068\:65b9\:91dd\:78ba\:5b9a
     Stage 1: \:6700\:5c0f compiled registry (Model resolve)
     Stage 1.5: Local PDF ingest (network-free, LLM-free)
     Stage 2: Source / Snapshot store + transactional write + dedup
     Stage 3: ClaudeAttach \:4e92\:63db PDF context retrieval
              + P1-P4 hook \:7d71\:5408 (ClaudeAttach / Attachments / A5 / A6)
     Stage 4 Phase 4A: URL / arXiv ingest (HTTPS \[RightArrow] URLDownload \[RightArrow] raw store)
     Stage 4 Phase 4A-async: LLMGraphDAGCreate \:7d4c\:7531\:306e\:975e\:540c\:671f ingest API
                             (Asynchronous -> True \:6642\:3001JobId \:5373\:6642 return)
     Stage 4 Phase 4B: PDF page extraction (cache + page hash + OCR hook)
                       SourceVaultExtractPages \:3001\:5358\:30da\:30fc\:30b8\:30fb\:8907\:6570\:30fb\:5168\:30da\:30fc\:30b8
     Stage 4 Phase 4C: OCR backends
                       SourceVaultOCREnable["ClaudeVision" | "TextRecognize" | "Custom"]
                       (PDFIndex \:30d1\:30bf\:30fc\:30f3\:8e0f\:8972\:3001\:4e0a\:4e0b\:5206\:5272 + 30px overlap)
     Stage 5: Claim extraction
                       SourceVaultExtract[sourceSpan, schema, opts]
                       Schema registry + LLM-backed extractor + ClaimStore (JSONL)
     Stage 6a: Claim dedup + Compact
                       SourceVaultExtract "Dedup" -> True (default)
                       SourceVaultClaimStoreCompact[] (master rebuild + uniq)
                       by-source \:5358\:4f4d\:306e ContentHash \:7167\:5408\:3001SkippedDuplicates \:8fd4\:5374
     Stage 6c: Evidence Bundle
                       SourceVaultBundleCreate[name, deps, opts]
                       SourceVaultBundleStatus[bundleId] (snapshot lifecycle \:7d4c\:7531)
                       SourceVaultBundleInvalidate / Get / List / Delete
                       bundles/<bundleId>.json \:30b9\:30c8\:30ec\:30fc\:30b8
     Stage 8: vN diff + snapshot lifecycle
                       SourceVaultDiffVersions[v1Snap, v2Snap]
                       SourceVaultMarkSnapshotStale / Invalidated
                       SourceVaultRefreshSnapshot[old, new, reason]
                       SourceVaultBundlesForSnapshot / SourceEvents
                       events/source-events.jsonl append-only event log
                       Bundle \:304c snapshot LifecycleStatus \:3092\:53c2\:7167\:3057\:3066\:81ea\:52d5 stale \:5316
     Stage 6d: NBAuthorize \:7d71\:5408
                       SourceVaultExtract: sendDecision + persistDecision
                       SourceVaultContext: RequireApproval \:3082 block
                       "AuthorizationCheck" -> True (\:30c7\:30d5\:30a9\:30eb\:30c8\:3001False \:3067 skip)
                       \:30ec\:30b9\:30dd\:30f3\:30b9\:306b AccessDecision \:30d5\:30a3\:30fc\:30eb\:30c9\:8ffd\:52a0
     Stage 6b: Compiled Registry
                       SourceVaultLookup[topic, key, opts]
                       SourceVaultResolve[kind, query, opts]
                       ClaudeResolveModel[provider, intent] (\:4e92\:63db wrapper)
                       SourceVaultCompileRegistry / RegisterSeed / ListRegistries
                       seeds/ + compiled/{public,private}/ 2 \:5c64\:69cb\:9020
                       \:30c7\:30d5\:30a9\:30eb\:30c8 model-seed bootstrap
     Stage 9: Notebook Management (P0)
                       SourceVaultRegisterNotebook[path]
                       SourceVaultIndexNotebook[path, opts]
                       SourceVaultExtractNotebookHeader / Todos
                       SourceVaultFindNotebooks[OpenTodos|NextReview|Deadline|Keywords]
                       SourceVaultNotebookLint[record] (7 \:7a2e lint)
                       notebooks/ \:914d\:4e0b\:306b sources/snapshots/todos/review/lint
                       safe parse (HoldComplete + whitelist)
     Stage 9 P1 Step 1: TaggingRules \:6a19\:6e96\:5316
                       SourceVaultExtractNotebookTaggingRules[path]
                       Notebook \:5168\:4f53 + \:5404 TodoItem cell \:306e TaggingRules \:53d6\:5f97
                       rule 102 (Wolfram \:6a19\:6e96\:95a2\:6570\:512a\:5148) \:306b\:6e96\:62e0
                       Import[\"Notebook\"] + NotebookImport[\"Cell\"] \:7d4c\:7531
     Stage 9 P1 Step 2: NotebookSemanticHash
                       SourceVaultNotebookSemanticHash[path]
                       \:610f\:5473\:7684\:5185\:5bb9\:306e\:307f\:3092\:30cf\:30c3\:30b7\:30e5\:5bfe\:8c61\:3068\:3057\:8868\:793a\:30e1\:30bf\:30c7\:30fc\:30bf\:9664\:5916
                       Hash[normalizedExpr, \"SHA256\", \"HexString\"]
                       SourceVaultIndexNotebook \:306e snapshot \:306b SemanticHash \:81ea\:52d5\:8ffd\:52a0
     Stage 9 P1 Step 4: Summary artifact stale \:5224\:5b9a
                       SourceVaultRegisterNotebookSummary[path, summary, opts]
                       SourceVaultGetNotebookSummary[path]
                       SourceVaultNotebookSummaryStatus[path]
                       Summary \:3092 SnapshotId + SemanticHash \:306b\:7d10\:3065\:3051\:3066 4 \:5024 lifecycle \:5224\:5b9a
                       (Missing / Current / StaleFormattingOnly / Stale)
                       notebooks/summaries/ \:914d\:4e0b\:306b sum-<nbRef>.json
     Stage 9 P1 Step 4 utf8fix:
                       Stage 9 P0 \:7531\:6765\:306e UTF-8 \:4e8c\:91cd encode \:30d0\:30b0\:3092 12 \:7bb9\:6240\:4e00\:62ec\:4fee\:6b63
                       \:65e7: BinaryWrite to strm with ExportString[X, Text-format, UTF-8] (\:4e8c\:91cd encode)
                       \:65b0: BinaryWrite to strm with StringToByteArray[X, UTF-8] (1 \:56de\:30e8\:30b1)
                       Claims/Bundle/SourceEvent/Registry + NotebookSource/Snapshot/Todo/Lint/Review/Summary
     Stage 9 P1 Step 4 utf8fix v2:
                       result13.nb \:3067\:6587\:5b57\:5316\:3051\:7d99\:7d9a\:78ba\:8a8d\[RightArrow] \:8aad\:307f\:51fa\:3057\:5074\:306e Import RawJSON \:3082\:539f\:56e0
                       Windows \:74b0\:5883\:3067 Import \:304c OS \:30c7\:30d5\:30a9\:30eb\:30c8 encoding (CP932) \:3067\:8aad\:3080\:5834\:5408\:304c\:3042\:308b\:305f\:3081\:3001
                       \:65b0\:898f helper iLoadJSONFromFile[path] \:3092\:8ffd\:52a0\[RightArrow]
                       ReadByteArray + ByteArrayToString[..., UTF-8] + Developer`ReadRawJSONString
                       Import[path, RawJSON] \:306e\:5168 5 \:7bb9\:6240\:3092\:7f6e\:63db
     Stage 9 P1 Step 4 utf8fix v3:
                       result14.nb \:3067\:6587\:5b57\:5316\:3051\:7d99\:7d9a\:78ba\:8a8d\[RightArrow] 2 \:7b87\:6240\:306e\:5b9a\:91cf\:7684\:306a\:539f\:56e0\:3092\:9664\:53bb
                       (1) OpenWrite/OpenAppend \:304b\:3089 CharacterEncoding -> UTF-8 \:3092\:524a\:9664 (12 \:7bb9\:6240)
                           BinaryFormat -> True + CharacterEncoding \:540c\:6642\:6307\:5b9a\:306f Wolfram \:306e\:6328\:62f6\:7740\:30c9\:30ad\:30e5\:30e1\:30f3\:30c8\:5316
                       (2) Developer`ReadRawJSONString \:3092 ImportString[\"RawJSON\"] \:306b\:5909\:66f4 (documented API)
                           L5973 \:3067 Imai \:5148\:751f\:304c\:65e2\:306b\:78ba\:7acb\:6e08\:307f\:306e\:30d1\:30bf\:30fc\:30f3\:3068\:5b8c\:5168\:540c\:4e00\:5316
     Stage 9 P1 Step 4 utf8fix v4:
                       result15.nb \:3067\:753b\:9762\:8868\:793a\:306f\:6b63\:5e38\:3060\:304c JSON \:30d5\:30a1\:30a4\:30eb\:81ea\:4f53\:304c\:4e8c\:91cd encode \:78ba\:8a8d
                       \:539f\:56e0: ExportString[record, RawJSON] \:306e\:623b\:308a\:5024 String \:306f\:3001
                       \:5404 Unicode codepoint \:304c\:65e2\:306b UTF-8 byte sequence \:306e Latin-1 \:8868\:73fe (\:7b2c\[RightArrow]\[CCedilla]+\[Not]+\[Not]) \:306b\:306a\:3063\:3066\:3044\:308b\:3002
                       \:305d\:308c\:306b StringToByteArray[X, UTF-8] \:3092\:9069\:7528\:3057\:3066\:4e8c\:91cd encode \:306b\:306a\:3063\:3066\:3044\:305f\:3002
                       \:4fee\:6b63: \:66f8\:304d\:51fa\:3057 12 \:7bb9\:6240\:3092 StringToByteArray[X, ISO8859-1] \:306b\:5909\:66f4\[RightArrow]
                       Latin-1 \:306f 1 codepoint = 1 byte \:306a\:306e\:3067 String \:5185\:90e8\:306e UTF-8 byte sequence \:304c\:305d\:306e\:307e\:307e byte \:306b\:306a\:308b
                       (iComputeSHA256 \:306f\:6587\:5b57\:5217 hash \:7528\:9014\:306a\:306e\:3067 UTF-8 \:3092\:7dad\:6301)
     Stage 9 P1 Step 5: LLM \:8981\:7d04
                       SourceVaultNotebookSummary[path, opts]
                       prompt \:69cb\:7bc9 (header / todo / lint / \:5148\:982d\:8907\:6570 cell text)
                       ClaudeQuerySync \:7d4c\:7531 (claudecode.wl)\:3001default PrivacyLevel = 1.0 (\:30ed\:30fc\:30ab\:30eb LM)
                       Step 4 \:306e Register \:3092\:5185\:90e8\:547c\:3073\:51fa\:3057\:3001lifecycle \:7ba1\:7406\:81ea\:52d5
     Stage 9 P1 Step 5 pkgfix:
                       result17.nb \:3067 ClaudeQuerySync \:304c SourceVault\`Private\`ClaudeQuerySync \:3068\:3057\:3066
                       shadow \:3055\:308c\:308b\:30d1\:30c3\:30b1\:30fc\:30b8\:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:554f\:984c\:3092\:4fee\:6b63\:3002
                       \:5b8c\:5168\:4fee\:98fe\:5f62\:5f0f ClaudeCode\`ClaudeQuerySync + Needs[\"ClaudeCode\`\"] \:3067\:89e3\:6c7a\:3002
                       BeginPackage \:306f SourceVault\`+NBAccess\` \:306e\:307e\:307e\:7dad\:6301 (\:5f37\:4f9d\:5b58\:3092\:5897\:3084\:3055\:306a\:3044)\:3002
   
   \:7269\:7406\:30b9\:30c8\:30ec\:30fc\:30b8 tier (v0.11/v0.13):
     PrivateVault     -- authoritative \:6b63\:672c (Dropbox \:914d\:4e0b)
     CloudMirror      -- $ClaudeWorkingDirectory \:914d\:4e0b\:306e mirror
     Tmp              -- $ClaudeWorkingDirectory/tmp \:914d\:4e0b
     AttachmentMirror -- $packageDirectory/claude_attachments \:4e92\:63db
   
   \:5fc5\:9808\:524d\:63d0: NBAccess.wl \:306e NBAuthorize (\:6bce\:56de\:547c\:3076)
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];



(* ::Subsection:: *)
(* Public symbols *)


(* \[HorizontalLine]\[HorizontalLine] Bootstrap / configuration \[HorizontalLine]\[HorizontalLine] *)

$SourceVaultVersion::usage =
  "$SourceVaultVersion \:306f SourceVault \:30d1\:30c3\:30b1\:30fc\:30b8\:306e\:30d0\:30fc\:30b8\:30e7\:30f3\:6587\:5b57\:5217\:3002";

$SourceVaultRoots::usage =
  "$SourceVaultRoots \:306f SourceVault \:306e\:7269\:7406 root \:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:30de\:30c3\:30d4\:30f3\:30b0\:3002\n" <>
  "Keys: \"PrivateVault\" | \"CloudMirror\" | \"Tmp\" | \"AttachmentMirror\" | \"ExternalOwned\"\n" <>
  "PrivateVault \:306f authoritative storage \:3002cloud LLM / Claude Code CLI \:306b\:76f4\:63a5\:8aad\:307e\:305b\:306a\:3044\:3002\n" <>
  "CloudMirror / AttachmentMirror \:306f materialize \:6e08\:307f projection \:306e\:307f\:3092\:7f6e\:304f\:3002";

$SourceVaultSeedModelRegistry::usage =
  "$SourceVaultSeedModelRegistry \:306f bootstrap \:6642\:306e fallback model registry\:3002\n" <>
  "Production truth \:3067\:306f\:306a\:304f\:3001compiled registry \:304c\:7121\:3044\:5834\:5408\:306e\:707d\:5bb3\:5fa9\:65e7\:7528 fallback\:3002\n" <>
  "LLM \:304c\:81ea\:52d5\:66f4\:65b0\:3057\:306a\:3044\:3002\:66f4\:65b0\:306f review \:5fc5\:9808\:3002";

SourceVaultInitialize::usage =
  "SourceVaultInitialize[] \:306f SourceVault \:306e\:7269\:7406 root \:3092\:751f\:6210\:3057\:3066\:521d\:671f\:5316\:3059\:308b\:3002\n" <>
  "\:6307\:5b9a oder: PrivateVault, Tmp \:306f\:5fc5\:9808\:3002\:4f5c\:6210\:6e08\:307f\:3067\:3042\:308c\:3070 noop\:3002\n" <>
  "Options:\n" <>
  "  \"Roots\" -> $SourceVaultRoots \:3092 override\n" <>
  "  \"Force\" -> True \:3067\:518d\:521d\:671f\:5316";

SourceVaultStatus::usage =
  "SourceVaultStatus[sourceRef] \:306f\:6307\:5b9a source / snapshot / \:30d5\:30a1\:30a4\:30eb\:306e\:6982\:8981\:3092\:8fd4\:3059\:3002\n" <>
  "SourceVaultStatus[] (\:5f15\:6570\:306a\:3057) \:306f vault \:5168\:4f53\:306e\:6982\:8981\:3092\:8fd4\:3059\:3002";

SourceVaultList::usage =
  "SourceVaultList[] \:306f vault \:5185\:306e\:5168 source ID \:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002";

SourceVaultSnapshots::usage =
  "SourceVaultSnapshots[sourceRef] \:306f\:6307\:5b9a source \:306b\:9650\:5b9a\:3057\:305f snapshot ID \:30ea\:30b9\:30c8\:3002";

(* ―― ソース一覧 / 横断検索 (表示用) ―― *)

SourceVaultSources::usage =
  "SourceVaultSources[query] は ingest 済み全ソースをメタデータ付きの表で表示する。\n" <>
  "arXiv は論文タイトル・著者・出版日 (arXiv API から自動取得し meta にキャッシュ)、\n" <>
  "Web ページは HTML <title>、ローカルファイルはファイル名を Title に出す。\n" <>
  "各行に URL リンク (▶ URL) と ingest 済みファイルを開くリンク (▶ 開く) が付く。\n" <>
  "query は Title/Authors/URL/Id 等の部分一致 (\"\" または省略で全件)。\n" <>
  "Options: \"Limit\" -> Automatic|n, \"Kind\" -> All|\"arxiv\"|\"web\"|\"local\",\n" <>
  "  \"FetchMetadata\" -> Automatic (未取得のみ取得)|False (network なし)|True (再取得),\n" <>
  "  \"Format\" -> \"Grid\" (既定)|\"Dataset\"|\"Rows\"";

SourceVaultSourceRow::usage =
  "SourceVaultSourceRow[sourceId] は 1 ソースの共通スキーマ行を返す:\n" <>
  "<|\"Kind\", \"Id\", \"Title\", \"Authors\", \"Published\", \"Summary\", \"URL\", \"File\", \"Date\", \"PrivacyLevel\"|>\n" <>
  "SourceVaultEagleSummaryRow と同じキーを共有する。";

SourceVaultSummaries::usage =
  "SourceVaultSummaries[query] は SourceVault が抱えるデータ全体 (ingest 済みソース +\n" <>
  "Eagle 保存済みサマリー等、登録 provider 横断) を検索し統合表で表示する。\n" <>
  "例: SourceVaultSummaries[\"可逆計算\"]\n" <>
  "Options: \"Providers\" -> All|{\"sources\", \"eagle\", ...}, \"Limit\", \"Kind\",\n" <>
  "  \"FetchMetadata\", \"Format\" -> \"Grid\" (既定)|\"Dataset\"|\"Rows\"";

SourceVaultRegisterSummaryProvider::usage =
  "SourceVaultRegisterSummaryProvider[name, fn] は SourceVaultSummaries の横断検索 provider を登録する。\n" <>
  "fn[query_String, opts_Association] は共通スキーマ行 (SourceVaultSourceRow 参照) のリストを返すこと。";

$SourceVaultSummaryProviders::usage =
  "$SourceVaultSummaryProviders は SourceVaultSummaries が横断する provider の Association (name -> fn)。";

(* \[HorizontalLine]\[HorizontalLine] Stage 1: Lookup / Resolve \[HorizontalLine]\[HorizontalLine] *)

SourceVaultResolve::usage =
  "SourceVaultResolve[kind, query] \:306f\:6307\:5b9a\:7a2e\:5225\:306e deterministic lookup \:3092\:884c\:3046\:3002\n" <>
  "Network \:306a\:3057\:3002LLM \:306a\:3057\:3002\n" <>
  "\:4f8b: SourceVaultResolve[\"Model\", <|\"Provider\" -> \"anthropic\", \"Intent\" -> \"heavy\"|>]";

SourceVaultLookup::usage =
  "SourceVaultLookup[topic, key] \:306f compiled registry \:3078\:306e\:5358\:7d14\:30ad\:30fc\:5f15\:304d\:3002";

ClaudeResolveModel::usage =
  "ClaudeResolveModel[provider, intent] \:306f SourceVaultResolve[\"Model\", ...] \:306e\:4e92\:63db wrapper\:3002\n" <>
  "\:4f8b: ClaudeResolveModel[\"anthropic\", \"heavy\"]";

(* \[HorizontalLine]\[HorizontalLine] Stage 1.5 / 2: Ingest \[HorizontalLine]\[HorizontalLine] *)

SourceVaultIngest::usage =
  "SourceVaultIngest[source] \:306f\:5916\:90e8 source \:3092\:767b\:9332\:3057 raw snapshot \:3092 PrivateVault \:306b\:4fdd\:5b58\:3002\n" <>
  "\:5b9f\:88c5\:7bc4\:56f2 (Stage 4 Phase 4A \:6642\:70b9):\n" <>
  "  - Local file path: \:30d5\:30a1\:30a4\:30eb\:3092 content-addressed raw \:30b9\:30c8\:30a2\:306b transactional copy\n" <>
  "  - HTTPS / HTTP URL: URLDownload \:7d4c\:7531\:3067 fetch\:3001hash \:8a08\:7b97\:3001metadata \:4fdd\:5b58\n" <>
  "  - arXiv:NNNN.NNNNN[vN]: arxiv.org/pdf/... \:306b canonicalize \:3057\:3066 URL ingest\n" <>
  "Options:\n" <>
  "  Topic -> Automatic | _String\n" <>
  "  TrustLevel -> Automatic | \"OfficialAPI\" | \"OfficialDocs\" | \"PublicWeb\" | \"LocalFile\"\n" <>
  "  PrivacyLabel -> Automatic | _Real\n" <>
  "  PinVersion -> True | False | Automatic\n" <>
  "  Asynchronous -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 False)\:3002True \:6307\:5b9a\:6642\:306f LLMGraphDAGCreate \:7d4c\:7531\:3067\n" <>
  "    \:30b8\:30e7\:30d6\:30ad\:30e5\:30fc\:306b\:6295\:5165\:3057 JobId \:3092\:5373\:6642 return\:3002LLMGraphDAGCreate (claudecode.wl) \:5fc5\:9808\:3002" <>
  "  EnsureUUID -> Automatic | True | False (.nb \:53d6\:308a\:8fbc\:307f\:6642\:306e UUID \:81ea\:52d5\:4ed8\:4e0e)\n" <>
  "    Automatic / True: .nb \:306a\:3089 hash \:8a08\:7b97\:306e\:524d\:306b SourceVaultEnsureNotebookUUID \:3092\:547c\:3073\:5143\:30d5\:30a1\:30a4\:30eb\:306b UUID \:3092\:57cb\:3081\:8fbc\:3080\n" <>
  "    .nb \:4ee5\:5916\:3068\:5de8\:5927\:30d5\:30a1\:30a4\:30eb (>$SourceVaultMaxFileSizeMB) \:306f\:30b9\:30ad\:30c3\:30d7\:3002\:4ed8\:4e0e\:306b\:5931\:6557\:3057\:3066\:3082 ingest \:306f\:7d9a\:884c\:3059\:308b";

SourceVaultIngestWait::usage =
  "SourceVaultIngestWait[ingestResult, timeoutSec] \:306f\:975e\:540c\:671f ingest \:306e\:5b8c\:4e86\:3092\:5f85\:3064\:3002\n" <>
  "  - ingestResult \:304c sync \:5b8c\:4e86\:6e08\:307f (Status: Ingested/AlreadyCurrent/RebuiltMetadata) \:306a\:3089\:5373\:5ea7 return\:3002\n" <>
  "  - Status: Queued \:306e\:5834\:5408\:3001SourceId \:306e snapshot \:5897\:52a0\:3092 polling \:3057\:3066\:65b0\:898f snapshot \:51fa\:73fe\:3067\:5b8c\:4e86\:3002\n" <>
  "  - timeoutSec (\:30c7\:30d5\:30a9\:30eb\:30c8 60) \:79d2\:8d85\:904e\:3067 Status: Timeout \:3092\:8fd4\:3059\:3002\n" <>
  "  - \:7b2c\:4e00\:5f15\:6570\:306f SourceVaultIngest \:306e\:7d50\:679c Association \:307e\:305f\:306f SourceId String\:3002";

(* \[HorizontalLine]\[HorizontalLine] Stage 4 Phase 4B: PDF page extraction \[HorizontalLine]\[HorizontalLine] *)

SourceVaultExtractPages::usage =
  "SourceVaultExtractPages[snapshot, pages] \:306f snapshot \:306e\:6307\:5b9a page \:3092\:62bd\:51fa\:3057 cache \:306b\:4fdd\:5b58\:3059\:308b\:3002\n" <>
  "  - snapshot: SnapshotId String \:307e\:305f\:305f SourceId String (latest snapshot \:3092\:4f7f\:7528)\n" <>
  "  - pages: Integer (\:5358\:30da\:30fc\:30b8) / List of Integer / All\n" <>
  "  - \:5404 page \:3092 parsed/by-snap/<id>/pages/NNNN.txt \:306b cache \:3057\:3001page-hashes.json \:306b\n" <>
  "    SHA-256 hash \:3092\:4fdd\:5b58\:3059\:308b\:3002cache hit \:6642\:306f Import \:3057\:306a\:3044\:3002\n" <>
  "  - \:62bd\:51fa\:7d50\:679c\:304c\:7a7a or 5 \:6587\:5b57\:672a\:6e80\:306e\:3068\:304d\:306f $SourceVaultOCRHook (\:5b9a\:7fa9\:3055\:308c\:3066\:3044\:308c\:3070) \:3092\n" <>
  "    \:547c\:3076 (Phase 4B \:6642\:70b9\:3067\:306f hook \:70b9\:306e\:307f\:3001OCR \:5b9f\:88c5\:306f Phase 4C)\:3002\n" <>
  "Options:\n" <>
  "  Force -> False | True (cache \:7121\:8996\:3057\:3066\:518d\:62bd\:51fa)\n" <>
  "  \"ForceOCR\" -> False | True (\:3053\:306e\:547c\:51fa\:3057\:3060\:3051 OCR \:3092\:5f37\:5236\:5b9f\:884c\:3001\:30b9\:30ad\:30e3\:30f3\:5224\:5b9a\:3092\:30b9\:30ad\:30c3\:30d7)\n" <>
  "    - hook \:304c\:8a2d\:5b9a\:3055\:308c\:3066\:3044\:308b\:5fc5\:8981\:3042\:308a\:3002\:6c38\:7d9a\:7684\:306b\:5f37\:5236\:30e2\:30fc\:30c9\:306b\:3057\:305f\:3044\:5834\:5408\:306f\n" <>
  "      SourceVaultOCREnable[..., \"Mode\" -> \"Force\"] \:3092\:4f7f\:3046\:3002\n" <>
  "    - ForceOCR -> True \:6642\:306f Force -> True \:3082\:81ea\:52d5\:3067\:9069\:7528\:3055\:308c\:308b (cache \:8aad\:307f\:3092\:30d0\:30a4\:30d1\:30b9\:3057\:3066\:307e\:305a\:518d OCR)\:3002\n" <>
  "\:623b\:308a\:5024: <|\"Status\", \"SnapshotId\", \"Pages\" -> {n: text, ...}, \"Hashes\" -> <|...|>, \"CachedFrom\" -> \"Disk\"|\"Fresh\"|\"Mixed\", \"OCRCalled\" -> True|False|>";

$SourceVaultOCRHook::usage =
  "$SourceVaultOCRHook \:306f\:30b9\:30ad\:30e3\:30f3 PDF \:306e fallback \:5024\:3002\n" <>
  "  - \:30c7\:30d5\:30a9\:30eb\:30c8: None (OCR \:7121\:3057\:3001\:7a7a\:30c6\:30ad\:30b9\:30c8\:306e\:307e\:307e)\n" <>
  "  - \:30b7\:30b0\:30cd\:30c1\:30e3: Function[<|\"RawPath\" -> _, \"Page\" -> _Integer, \"SnapshotId\" -> _|>] :> _String\n" <>
  "  - SourceVaultExtractPages \:304c\:30da\:30fc\:30b8\:30c6\:30ad\:30b9\:30c8\:62bd\:51fa\:5931\:6557\:6642 (\:7a7a or 5 \:6587\:5b57\:672a\:6e80) \:306b\:547c\:3070\:308c\:3001\n" <>
  "    \:8fd4\:5024\:6587\:5b57\:5217\:304c text \:3068\:3057\:3066 cache \:3055\:308c\:308b\:3002\n" <>
  "  - Phase 4C \:306e SourceVaultOCREnable[...] \:7d4c\:7531\:3067\:8a2d\:5b9a\:3059\:308b\:306e\:304c\:63a8\:5968\:3002";

$SourceVaultOCRMode::usage =
  "$SourceVaultOCRMode \:306f OCR \:767a\:706b\:30e2\:30fc\:30c9\:3092\:5236\:5fa1\:3059\:308b\:5909\:6570\:3002\n" <>
  "  - \"Auto\" (\:30c7\:30d5\:30a9\:30eb\:30c8): iIsPDFLikelyScanned (Plaintext \:62bd\:51fa\:7d50\:679c\:304c 5 \:6587\:5b57\:672a\:6e80) \:306e\:6642\:306e\:307f OCR \:3092\:547c\:3076\:3002\n" <>
  "  - \"Force\": Plaintext \:306e\:9577\:3055\:306b\:95a2\:308f\:3089\:305a\:5e38\:306b OCR \:3092\:547c\:3076\:3002\:4f4e\:54c1\:8cea OCR \:30c6\:30ad\:30b9\:30c8\:5c64\:3092\:6301\:3064 PDF \:7fa4\:306b\:5bfe\:3057\:3066\:3001\n" <>
  "    \:300c\:30b9\:30ad\:30e3\:30f3\:5224\:5b9a\:300d\:3092\:30b9\:30ad\:30c3\:30d7\:3057\:3066\:5168\:30da\:30fc\:30b8\:3092\:518d OCR \:3057\:305f\:3044\:6642\:306b\:4f7f\:3046\:3002\n" <>
  "  - SourceVaultOCREnable[..., \"Mode\" -> \"Force\"] \:3067\:6c38\:7d9a\:5316\:53ef\:80fd\:3002SourceVaultOCRDisable[] \:3067 \"Auto\" \:306b\:30ea\:30bb\:30c3\:30c8\:3002\n" <>
  "  - \:5358\:767a\:7684\:306a\:5f37\:5236 OCR \:306b\:306f SourceVaultExtractPages \:306e \"ForceOCR\" -> True \:3092\:4f7f\:3046\:3002";

$SourceVaultOCRVerbose::usage =
  "$SourceVaultOCRVerbose \:306f OCR \:5b9f\:884c\:6642\:306e\:9032\:6357 Print \:3092\:5236\:5fa1\:3059\:308b\:5909\:6570\:3002\n" <>
  "  - \:30c7\:30d5\:30a9\:30eb\:30c8: False (\:9759\:304b\:306b\:5b9f\:884c)\n" <>
  "  - True: rasterization / API \:547c\:51fa / \:30ec\:30b9\:30dd\:30f3\:30b9\:9577\:3055\:7b49\:306e\:9032\:6357\:3092 Print\:3002\n" <>
  "  - OCR \:304c\:7121\:97f3\:3067\:5931\:6557\:3057\:3066\:3044\:308b\:6642\:306e\:30c7\:30d0\:30c3\:30b0\:7528\:3002\n" <>
  "  - SourceVaultOCREnable[..., \"Verbose\" -> True] \:3067\:6709\:52b9\:5316\:53ef\:80fd\:3002";

(* \[HorizontalLine]\[HorizontalLine] Stage 4 Phase 4C: OCR backends (Tesseract / Custom) \[HorizontalLine]\[HorizontalLine] *)

SourceVaultOCREnable::usage =
  "SourceVaultOCREnable[backend, opts] \:306f OCR hook \:3092\:6709\:52b9\:5316\:3059\:308b\:3002\n" <>
  "  - backend (\:30c7\:30d5\:30a9\:30eb\:30c8 \"ClaudeVision\"): \"ClaudeVision\" | \"TextRecognize\" | \"Custom\"\n" <>
  "  - \"ClaudeVision\": ClaudeCode`ClaudeQueryBg \:7d4c\:7531\:3067 Claude API \:306b page \:753b\:50cf\:3092\:9001\:308a OCR (PDFIndex \:5b9f\:8a3c\:6e08\:30d1\:30bf\:30fc\:30f3)\:3002\n" <>
  "    \:5927\:304d\:3044 page \:306f\:81ea\:52d5\:3067\:4e0a\:4e0b\:5206\:5272 (30px overlap) \:3057\:3066 2 \:56de OCR \:30de\:30fc\:30b8\:3002\n" <>
  "    Options: \"DPI\" -> 300, \"SplitHalves\" -> True, \"Timeout\" -> 180, \"Prompt\" -> Automatic\n" <>
  "  - \"TextRecognize\": Mathematica \:7d44\:8fbc\:307f TextRecognize (Python \:4e0d\:8981\:3001\:7cbe\:5ea6\:6e96\:7b49)\n" <>
  "    Options: \"DPI\" -> 150, \"Language\" -> \"Japanese\"\n" <>
  "  - \"Custom\": \:30e6\:30fc\:30b6\:63d0\:4f9b Function \:3092\:305d\:306e\:307e\:307e $SourceVaultOCRHook \:306b\:8a2d\:5b9a\:3002\n" <>
  "    Options: \"Hook\" -> Function[req, text]\n" <>
  "\:5171\:901a Option:\n" <>
  "  - \"Mode\" -> \"Auto\" (\:30c7\:30d5\:30a9\:30eb\:30c8) | \"Force\"\n" <>
  "    \"Auto\": Plaintext \:62bd\:51fa\:7d50\:679c\:304c 5 \:6587\:5b57\:672a\:6e80\:306e\:6642\:306b\:306e\:307f OCR \:3092\:547c\:3076\:3002\n" <>
  "    \"Force\": Plaintext \:306e\:9577\:3055\:306b\:95a2\:308f\:3089\:305a\:5e38\:306b OCR \:3092\:547c\:3076 (\:4f4e\:54c1\:8cea\:30c6\:30ad\:30b9\:30c8\:5c64\:5bfe\:7b56)\:3002\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> \"Enabled\", \"Backend\" -> _String, \"Mode\" -> _String, \"Options\" -> _Association|>";

SourceVaultOCRDisable::usage =
  "SourceVaultOCRDisable[] \:306f OCR hook \:3092\:7121\:52b9\:5316\:3059\:308b ($SourceVaultOCRHook = None)\:3002";

SourceVaultOCRStatus::usage =
  "SourceVaultOCRStatus[] \:306f\:73fe\:5728\:306e OCR hook \:8a2d\:5b9a\:3092\:8fd4\:3059\:3002\n" <>
  "  - Backend: Disabled / ClaudeVision / TextRecognize / Custom\n" <>
  "  - HookSet: True \:306a\:3089 $SourceVaultOCRHook \:306b Function \:304c\:8a2d\:5b9a\:6e08\:307f\:3002";

(* \[HorizontalLine]\[HorizontalLine] Stage 5: Claim extraction \[HorizontalLine]\[HorizontalLine] *)

SourceVaultExtract::usage =
  "SourceVaultExtract[sourceSpan, schema, opts] \:306f sourceSpan \:306e page text \:3092 LLM \:306b\:6e21\:3057\:3066 claim \:3092\:62bd\:51fa\:3059\:308b\:3002\n" <>
  "  - sourceSpan: SourceVaultSpan[...] \:306e\:7d50\:679c\:3001\:307e\:305f\:306f SnapshotId/SourceId String\n" <>
  "  - schema: \:6587\:5b57\:5217 (\:767b\:9332\:6e08\:307f schema \:540d)\:3001\:307e\:305f\:306f Association (\:30a4\:30f3\:30e9\:30a4\:30f3\:5b9a\:7fa9)\n" <>
  "  - schema \:306e\:8aac\:660e\:3001JSON \:51fa\:529b\:5f62\:5f0f\:3001\:9805\:76ee\:540d\:3092 prompt \:306b\:5dee\:3057\:8fbc\:307f\:3001\:6587\:5b57\:5217\:30fb\:6570\:5024\:30fb\:914d\:5217\:3092\:62bd\:51fa\:3002\n" <>
  "Options:\n" <>
  "  \"Topic\" -> _String (claim \:306e topic\:3001\:30c7\:30d5\:30a9\:30eb\:30c8 schema \:540d)\n" <>
  "  \"ModelIntent\" -> \"summary\" | \"extraction\" | \"math-extraction-heavy\"\n" <>
  "  \"StoreClaims\" -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 True)\n" <>
  "  \"Dedup\" -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 True\:3002by-source \:30d5\:30a1\:30a4\:30eb\:5358\:4f4d\:3067 ContentHash \:7167\:5408)\n" <>
  "  \"AuthorizationCheck\" -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 True\:3002Stage 6d: 2 \:6bb5\:968e NBAuthorize)\n" <>
  "  \"Validation\" -> \"None\" | \"Required\"\n" <>
  "  MaxCharacters -> 8000 (LLM \:306b\:6e21\:3059 context \:306e\:6700\:5927\:6587\:5b57\:6570)\n" <>
  "  Timeout -> 180\n" <>
  "\:5b9f\:884c\:30d5\:30ed\:30fc (AuthorizationCheck -> True \:6642):\n" <>
  "  1. sendDecision \[LongDash] source span \:3092 LLM \:306b\:9001\:308b\:524d (\:4ed5\:69d8\:66f8 \[Section] 14.4.2)\n" <>
  "  2. context \:53d6\:5f97 + LLM \:62bd\:51fa\n" <>
  "  3. persistDecision \[LongDash] claim \:3092\:4fdd\:5b58\:3059\:308b\:524d\n" <>
  "\:623b\:308a\:5024: <|\"Claims\" -> {claim1, ...}, \"Count\" -> _Integer (\:5b9f\:7d0d\:6570), \"ExtractedCount\" -> _Integer (LLM \:751f\:62bd\:51fa\:6570), \"DedupSkipped\" -> _Integer, \"AccessDecisions\" -> <|\"Send\" -> _, \"Persist\" -> _|>, \"ValidationStatus\" -> _, \"SchemaName\" -> _, \"ExtractedAt\" -> DateObject, \"Errors\" -> {...}|>\n" <>
  "Decision \:304c Deny: <|\"Status\" -> \"DeniedByNBAccess\", \"Reason\" -> _, \"AccessDecisions\" -> _|>\n" <>
  "Decision \:304c RequireApproval: <|\"Status\" -> \"RequiresApproval\", \"Reason\" -> _, \"AccessDecisions\" -> _|>";

SourceVaultRegisterSchema::usage =
  "SourceVaultRegisterSchema[name, definition] \:306f\:62bd\:51fa schema \:3092\:30b0\:30ed\:30fc\:30d0\:30eb\:306b\:767b\:9332\:3059\:308b\:3002\n" <>
  "definition \:306f Association:\n" <>
  "  \"Description\" -> \:6587\:5b57\:5217 (LLM \:5411\:3051\:306e\:8aac\:660e)\n" <>
  "  \"Fields\" -> {<|\"Name\" -> \"InitialValue\", \"Type\" -> \"Number\", \"Required\" -> True, \"Description\" -> \"...\"|>, ...}\n" <>
  "  \"OutputShape\" -> \"List\" | \"Single\" (\:8907\:6570 claim or 1 claim)\n" <>
  "  \"PromptTemplate\" -> Automatic | _String (\:30c7\:30d5\:30a9\:30eb\:30c8\:306f Fields \:304b\:3089\:81ea\:52d5\:751f\:6210)\n" <>
  "\:30d3\:30eb\:30c8\:30a4\:30f3 schema: \"FreeText\" (\:81ea\:7531\:62bd\:51fa)\:3001\"NumericFacts\" (\:6570\:5024\:30fb\:5358\:4f4d\:30fb\:5b9a\:7fa9\:30fb\:6587\:8108)\:3001\"DefinitionList\" (\:7528\:8a9e\:30fb\:5b9a\:7fa9)\:3002";

SourceVaultClaim::usage =
  "SourceVaultClaim[claimId] \:306f\:6307\:5b9a\:3057\:305f claim \:306e Association \:3092\:8fd4\:3059\:3002\:898b\:3064\:304b\:3089\:306a\:3051\:308c\:3070 Missing[\"NotFound\"]\:3002";

SourceVaultClaimsForSource::usage =
  "SourceVaultClaimsForSource[sourceIdOrSnapshotId] \:306f\:6307\:5b9a source \:306b\:7d10\:3065\:304f claim \:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002";

SourceVaultClaimsForTopic::usage =
  "SourceVaultClaimsForTopic[topic] \:306f\:6307\:5b9a topic \:306b\:7d10\:3065\:304f claim \:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002";

SourceVaultListSchemas::usage =
  "SourceVaultListSchemas[] \:306f\:73fe\:5728\:767b\:9332\:6e08\:307f\:306e schema \:540d\:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002";

SourceVaultGetSchema::usage =
  "SourceVaultGetSchema[name] \:306f\:767b\:9332\:6e08\:307f schema \:5b9a\:7fa9 (Association) \:3092\:8fd4\:3059\:3002";

SourceVaultClaimStoreStatus::usage =
  "SourceVaultClaimStoreStatus[] \:306f ClaimStore \:306e\:72b6\:614b\:3092\:8fd4\:3059 (debug \:7528)\:3002\n" <>
  "  - ClaimsDir / MasterPath / MasterExists / MasterClaims (\:884c\:6570) / TopicFiles / SourceFiles";

SourceVaultClaimStoreCompact::usage =
  "SourceVaultClaimStoreCompact[opts] \:306f master + by-topic + by-source \:3092\:5168\:8aad\:307f\:3057\:3001\n" <>
  "ContentHash \:30ad\:30fc\:3067 dedup \:3057\:3066\:5168\:30a4\:30f3\:30c7\:30c3\:30af\:30b9\:3092 rebuild \:3059\:308b\:3002\n" <>
  "atomic rewrite (tmp \:30d5\:30a1\:30a4\:30eb \[Rule] rename)\:3002dedup \:8a18\:9332\:306f master \:306e\:5148\:982d\:884c\:3092\:6b8b\:3059 (\:6700\:53e4\:306e\:7d50\:679c\:3092\:4fdd\:5b58)\:3002\n" <>
  "Options:\n" <>
  "  \"Backup\" -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 True\:3002.bak.<timestamp> \:30b5\:30d5\:30a3\:30c3\:30af\:30b9)\n" <>
  "  \"DryRun\" -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 False\:3002True \:6642\:306f\:7d71\:8a08\:306e\:307f\:8fd4\:3059)\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> \"OK\" | \"Failed\", \"BeforeCount\" -> _Integer, \"AfterCount\" -> _Integer, \"Removed\" -> _Integer, \"BackupPaths\" -> {...}, \"DryRun\" -> _|>";

(* \[HorizontalLine]\[HorizontalLine] Stage 6c: Evidence Bundle \[HorizontalLine]\[HorizontalLine] *)

SourceVaultBundleCreate::usage =
  "SourceVaultBundleCreate[name, deps, opts] \:306f generated artifact \:306e\:4f9d\:5b58\:3092 evidence bundle \:3068\:3057\:3066\:4fdd\:5b58\:3059\:308b\:3002\n" <>
  "  - name: \:6587\:5b57\:5217 (bundle \:306e\:8868\:793a\:540d\:3002BundleId \:306f\:81ea\:52d5\:751f\:6210\:3055\:308c\:308b)\n" <>
  "  - deps: Association\n" <>
  "      \"GeneratedFiles\" -> {\"path/to/output1.wl\", ...}\n" <>
  "      \"Sources\" -> {<|\"SourceId\" -> ..., \"SnapshotId\" -> ...|>, ...}\n" <>
  "      \"SourceSpans\" -> {...} (optional)\n" <>
  "      \"Claims\" -> {\"claim-...\", ...}\n" <>
  "      \"Generator\" -> <|\"Tool\" -> ..., \"WorkflowId\" -> ..., \"ModelIntent\" -> ..., \"ResolvedModel\" -> ...|>\n" <>
  "Options:\n" <>
  "  \"Kind\" -> \"SimulationExample\" | \"LaTeXExport\" | \"DocumentGeneration\" | \"CodeGeneration\" | \"Notebook\" | _String\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> \"OK\" | \"Failed\", \"BundleId\" -> _String, \"Path\" -> _String|>";

SourceVaultBundleGet::usage =
  "SourceVaultBundleGet[bundleId] \:306f\:6307\:5b9a bundle \:3092\:8aad\:307f\:8fbc\:307f\:8fd4\:3059\:3002\:898b\:3064\:304b\:3089\:306a\:3051\:308c\:3070 Missing[\"NotFound\"]\:3002";

SourceVaultBundleList::usage =
  "SourceVaultBundleList[] \:306f\:5168 bundle id \:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002";

SourceVaultBundleStatus::usage =
  "SourceVaultBundleStatus[bundleId] \:306f bundle \:306e\:73fe\:5728\:306e Status \:3092\:8a08\:7b97\:3057\:3066\:8fd4\:3059\:3002\n" <>
  "  - \:53c2\:7167\:3059\:308b snapshot \:306e LifecycleStatus \:3092\:96c6\:7d04\n" <>
  "  - \:4f8b: \"Current\" | \"Stale\" | \"NeedsReview\" | \"Invalidated\"\n" <>
  "  - \:624b\:52d5 Invalidate \:6e08\:307f\:306a\:3089\:5f37\:5236\:7684\:306b \"Invalidated\" \:3092\:8fd4\:3059\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> _, \"Reason\" -> _, \"AffectedSnapshots\" -> {...}, \"AffectedClaims\" -> {...}|>";

SourceVaultBundleInvalidate::usage =
  "SourceVaultBundleInvalidate[bundleId, reason] \:306f bundle \:3092\:624b\:52d5\:3067 invalidate \:3059\:308b\:3002\n" <>
  "  - reason: \:6587\:5b57\:5217\:3002\:8a18\:9332\:3055\:308c\:3001\:5f8c\:306b SourceVaultBundleStatus \:3067\:8fd4\:3055\:308c\:308b\:3002";

SourceVaultBundleDelete::usage =
  "SourceVaultBundleDelete[bundleId] \:306f bundle \:30d5\:30a1\:30a4\:30eb\:3092\:524a\:9664\:3059\:308b (debug \:7528)\:3002";

(* \[HorizontalLine]\[HorizontalLine] Stage 8: vN diff + snapshot lifecycle \[HorizontalLine]\[HorizontalLine] *)

SourceVaultDiffVersions::usage =
  "SourceVaultDiffVersions[v1Snap, v2Snap] \:306f\:4e8c\:3064\:306e snapshot \:306e page hash \:96c6\:5408\:3092\:6bd4\:8f03\:3057\:3001\:5dee\:5206\:3092\:8fd4\:3059\:3002\n" <>
  "  - \:5404 snapshot \:306e page-hashes.json (Stage 4B) \:3092\:8aad\:307f\:8fbc\:307f\:3001\:30da\:30fc\:30b8\:756a\:53f7\:3054\:3068\:306b hash \:3092\:6bd4\:8f03\n" <>
  "  - \:30b9\:30ad\:30fc\:30de\:3068\:3057\:3066\:306f set/dict \:306e \:4ea4\:96c6\:5408 \:3068 \:5dee\:96c6\:5408 \:3092\:9069\:7528 \n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> _, \"V1Snap\" -> _, \"V2Snap\" -> _,\n" <>
  "  \"AddedPages\" -> {_Integer, ...},     (* v2 \:306b\:3057\:304b\:306a\:3044 page *)\n" <>
  "  \"RemovedPages\" -> {_Integer, ...},   (* v1 \:306b\:3057\:304b\:306a\:3044 page *)\n" <>
  "  \"ChangedPages\" -> {_Integer, ...},   (* \:4e21\:65b9\:306b\:3042\:308b\:304c hash \:304c\:9055\:3046 *)\n" <>
  "  \"UnchangedPages\" -> {_Integer, ...} (* \:4e21\:65b9\:306b\:3042\:308a hash \:4e00\:81f4 *)|>";

SourceVaultMarkSnapshotStale::usage =
  "SourceVaultMarkSnapshotStale[snapshotId, reason] \:306f snapshot meta \:306e LifecycleStatus \:3092 \"Stale\" \:306b\:66f4\:65b0\:3057\:3001\n" <>
  "events/source-events.jsonl \:306b VersionedUpdate event \:3092\:8a18\:9332\:3059\:308b\:3002\n" <>
  "\:3053\:308c\:306b\:3088\:308a\:3001\:305d\:306e snapshot \:3092\:53c2\:7167\:3059\:308b Bundle \:306f SourceVaultBundleStatus \:3067\:81ea\:52d5\:7684\:306b \"Stale\" \:3092\:8fd4\:3059\:3088\:3046\:306b\:306a\:308b\:3002";

SourceVaultMarkSnapshotInvalidated::usage =
  "SourceVaultMarkSnapshotInvalidated[snapshotId, reason] \:306f snapshot meta \:306e LifecycleStatus \:3092 \"Invalidated\" \:306b\:66f4\:65b0\:3059\:308b\:3002\n" <>
  "Retraction \:306a\:3069\:3001\:53c2\:7167\:3092\:4e0d\:53ef\:306b\:3057\:305f\:3044\:5834\:5408\:306b\:4f7f\:3046\:3002Bundle \:306f \"Invalidated\" \:3092\:8fd4\:3059\:3088\:3046\:306b\:306a\:308b\:3002";

SourceVaultRefreshSnapshot::usage =
  "SourceVaultRefreshSnapshot[oldSnapId, newSnapId, reason] \:306f\:9ad8\:30ec\:30d9\:30eb refresh API\:3002\n" <>
  "  1. oldSnap \:3068 newSnap \:306e diff \:3092\:8a08\:7b97\n" <>
  "  2. oldSnap \:306e LifecycleStatus \:3092 \"Stale\" \:306b\:66f4\:65b0 + SupersededBy \:3092 newSnap \:306b\:8a2d\:5b9a\n" <>
  "  3. event \:3092 source-events.jsonl \:306b\:8a18\:9332 (EventType: VersionedUpdate)\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> _, \"Diff\" -> _Association, \"Event\" -> _Association|>";

SourceVaultBundlesForSnapshot::usage =
  "SourceVaultBundlesForSnapshot[snapshotId] \:306f\:6307\:5b9a\:306e snapshot \:3092\:53c2\:7167\:3059\:308b\:5168 bundle id \:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002\n" <>
  "  - \:5168 bundle \:30d5\:30a1\:30a4\:30eb\:3092\:8aad\:307f\:3001Sources[].SnapshotId \:304c\:4e00\:81f4\:3059\:308b\:3082\:306e\:3092\:53ce\:96c6\:3002\n" <>
  "Stage 6c Phase 2 \:306e\:53cc\:65b9\:5411\:30ea\:30f3\:30af\:306e\:5148\:53d6\:308a\:3002";

SourceVaultSourceEvents::usage =
  "SourceVaultSourceEvents[opts] \:306f events/source-events.jsonl \:306e\:5168 event \:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002\n" <>
  "Options:\n" <>
  "  \"SourceId\" -> _String (\:6307\:5b9a source \:306b\:95a2\:9023\:3059\:308b event \:306e\:307f)\n" <>
  "  \"SnapshotId\" -> _String (\:6307\:5b9a snapshot \:306b\:95a2\:9023\:3059\:308b event \:306e\:307f)\n" <>
  "  \"EventType\" -> _String (VersionedUpdate / Retraction / SourceDeletion / SchemaChange)";

SourceVaultSourceEventAppend::usage =
  "SourceVaultSourceEventAppend[event] \:306f event Association \:3092 events/source-events.jsonl \:306b append \:3059\:308b\:3002\n" <>
  "event \:306b\:306f EventType / SourceId / Reason \:306f\:5fc5\:9808\:3002OldSnapshotId / NewSnapshotId / Metadata \:306f\:4efb\:610f\:3002\n" <>
  "EventId \:3068 Timestamp \:306f\:81ea\:52d5\:751f\:6210\:3055\:308c\:308b\:3002";

(* \[HorizontalLine]\[HorizontalLine] Stage 6b: Compiled Registry \[HorizontalLine]\[HorizontalLine] *)

SourceVaultLookup::usage =
  "SourceVaultLookup[topic, key, opts] \:306f compiled registry \:304b\:3089 key \:306b\:5bfe\:5fdc\:3059\:308b entry \:3092\:8fd4\:3059\:3002\n" <>
  "  - topic: \"model-registry\" | \"mathematica-graph-options\" | _String\n" <>
  "  - key: \:6587\:5b57\:5217\:3001\:307e\:305f\:306f Association (Resolve \:540c\:69d8\:306b structured query)\n" <>
  "  - \:30b3\:30f3\:30d1\:30a4\:30eb\:30c9 registry \:306b\:898b\:3064\:304b\:3089\:306a\:3051\:308c\:3070 seed \:306b fallback\n" <>
  "Options:\n" <>
  "  \"Channel\" -> \"public\" | \"private\" (\:30c7\:30d5\:30a9\:30eb\:30c8 \"public\")\n" <>
  "  \"AllowSeed\" -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 True\:3001compiled \:7121\:3057\:6642 seed \:3092\:4f7f\:3046)\n" <>
  "\:623b\:308a\:5024: entry Association \:307e\:305f\:306f Missing[\"NotFound\"]";

SourceVaultResolve::usage =
  "SourceVaultResolve[kind, query, opts] \:306f compiled registry \:304b\:3089 query \:306b match \:3059\:308b entry \:3092\:8fd4\:3059\:3002\n" <>
  "  - kind: \"Model\" | _String\n" <>
  "  - query: <|\"Provider\" -> ..., \"Intent\" -> ...|> \:306e\:3088\:3046\:306a structured \:691c\:7d22\:6761\:4ef6\n" <>
  "  - \:8907\:6570 match \:6642\:306f Availability != \"Unavailable\" \:3092\:30d5\:30a3\:30eb\:30bf\:3001Class/Freshness \:3067 sort \:3057\:3066\:5148\:982d\:3092\:8fd4\:3059\n" <>
  "Options:\n" <>
  "  \"Channel\" -> \"public\" | \"private\"\n" <>
  "  \"AllowSeed\" -> True | False\n" <>
  "  \"Topic\" -> _String (\:30c7\:30d5\:30a9\:30eb\:30c8 \"<kind>-registry\" \:3092\:5c0f\:6587\:5b57\:5316)\n" <>
  "\:623b\:308a\:5024: entry Association \:307e\:305f\:306f Missing[\"NotFound\"]";

ClaudeResolveModel::usage =
  "ClaudeResolveModel[provider, intent] \:306f SourceVaultResolve[\"Model\", ...] \:306e\:4e92\:63db wrapper (\:4ed5\:69d8\:66f8 \\:00a7 5.4)\:3002\n" <>
  "\:65e7 WikiDBResolveModel \:306e\:7f6e\:304d\:63db\:3048\:3068\:3057\:3066\:5229\:7528\:3067\:304d\:308b\:3002";

SourceVaultListModels::usage =
  "SourceVaultListModels[provider] \:306f\:6307\:5b9a provider \:306b\:767b\:9332\:3055\:308c\:305f\:9078\:629e\:53ef\:80fd\:306a\:5168\:30e2\:30c7\:30eb ID \:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002\n" <>
  "SourceVaultResolve \:304c intent \:5358\:4f4d\:306e\:6700\:9069 1 \:4ef6\:3092\:8fd4\:3059\:306e\:306b\:5bfe\:3057\:3001\:3053\:308c\:306f catalog \:3092\:5217\:6319\:3059\:308b (\:4f8b: \:30d1\:30ec\:30c3\:30c8\:306e\:30e2\:30c7\:30eb\:9078\:629e)\:3002\n" <>
  "compiled registry \:3092\:512a\:5148\:3057\:3001\:7121\:3051\:308c\:3070 seed \:306b fallback\:3002Availability \:304c Unavailable \:306e\:30a8\:30f3\:30c8\:30ea\:306f\:9664\:5916\:3002";

SourceVaultModelContextLength::usage =
  "SourceVaultModelContextLength[provider, modelId] \:306f\:30e2\:30c7\:30eb\:306b\:7d10\:3065\:304f ContextLength \:3092\:8fd4\:3059\:3002\n" <>
  "SourceVaultSetModel[..., \"ContextLength\" -> n] \:3067\:6c38\:7d9a\:5316\:3055\:308c\:305f\:5024\:3002\n" <>
  "LM Studio \:7b49\:30ed\:30fc\:30ab\:30eb LLM \:306e context_length \:306b\:4f7f\:3046\:3002\:672a\:8a2d\:5b9a\:306a\:3089 None\:3002";

SourceVaultModelIntegrations::usage =
  "SourceVaultModelIntegrations[provider, modelId] \:306f\:30e2\:30c7\:30eb\:306b\:7d10\:3065\:304f LM Studio MCP \:306e\n" <>
  "integrations \:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002SourceVaultSetModel[..., \"Integrations\" -> {...}] \:3067\n" <>
  "\:6c38\:7d9a\:5316\:3055\:308c\:305f\:5024\:3002LM Studio /api/v1/chat \:306e integrations \:30d1\:30e9\:30e1\:30fc\:30bf\:306b\:4f7f\:3046\:3002\n" <>
  "\:4f8b: SourceVaultSetModel[\"lmstudio\", \"local-heavy\", \"qwen/qwen3-coder-30b\",\n" <>
  "        \"Integrations\" -> {\"mcp/exa\"}, \"ContextLength\" -> 32000]\n" <>
  "\:672a\:8a2d\:5b9a\:306a\:3089 None\:3002\:3053\:308c\:306f MCP ID (\"mcp/exa\" \:7b49) \:3092\:30b3\:30fc\:30c9\:306b\:30cf\:30fc\:30c9\:30b3\:30fc\:30c9\:305b\:305a\n" <>
  "SourceVault \:30b9\:30c8\:30a2\:306b\:6c38\:7d9a\:5316\:3059\:308b\:305f\:3081\:306e\:6a5f\:69cb\:3002";

SourceVaultListRegistries::usage =
  "SourceVaultListRegistries[opts] \:306f\:767b\:9332\:6e08\:307f registry topic \:3068 channel \:3092\:8fd4\:3059\:3002\n" <>
  "Options: \"Channel\" -> \"public\" | \"private\" | All (\:30c7\:30d5\:30a9\:30eb\:30c8 All)";

SourceVaultRegistryStatus::usage =
  "SourceVaultRegistryStatus[topic, opts] \:306f\:6307\:5b9a topic \:306e registry \:72b6\:614b\:3092\:8fd4\:3059\:3002\n" <>
  "Options: \"Channel\" -> \"public\" | \"private\"\n" <>
  "\:623b\:308a\:5024: <|\"Topic\" -> _, \"Channel\" -> _, \"CompiledPath\" -> _, \"CompiledExists\" -> _Bool,\n" <>
  "  \"CompiledCount\" -> _Integer, \"SeedPath\" -> _, \"SeedExists\" -> _Bool, \"SeedCount\" -> _Integer,\n" <>
  "  \"LastModified\" -> _String|>";

SourceVaultCompileRegistry::usage =
  "SourceVaultCompileRegistry[topic, entries, opts] \:306f entries (List of Association) \:3092 compiled registry \:306b\:4fdd\:5b58\:3059\:308b\:3002\n" <>
  "  - topic: \"model-registry\" \:306a\:3069\n" <>
  "  - entries: {<|\"Provider\" -> ..., \"Intent\" -> ..., \"ModelId\" -> ...|>, ...}\n" <>
  "Options:\n" <>
  "  \"Channel\" -> \"public\" | \"private\" (\:30c7\:30d5\:30a9\:30eb\:30c8 \"public\")\n" <>
  "  \"Sources\" -> {_String, ...} (\:95a2\:9023 claim/snapshot id)\n" <>
  "  \"PolicySource\" -> _String\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> _, \"Topic\" -> _, \"Channel\" -> _, \"Path\" -> _, \"Count\" -> _Integer|>";

SourceVaultRegisterSeed::usage =
  "SourceVaultRegisterSeed[topic, entries] \:306f seed entries \:3092 seeds/<topic>-seed.json \:306b\:4fdd\:5b58\:3059\:308b (bootstrap \:7528)\:3002\n" <>
  "seed \:306f production truth \:3067\:306f\:306a\:304f\:3001compiled registry \:304c\:306a\:3044\:6642\:306e fallback \:3060\:3051\:306b\:4f7f\:308f\:308c\:308b\:3002";

(* \[HorizontalLine]\[HorizontalLine] Stage 9: Notebook Management (P0) \[HorizontalLine]\[HorizontalLine] *)

SourceVaultRegisterNotebook::usage =
  "SourceVaultRegisterNotebook[path] \:306f\:6307\:5b9a path \:306e notebook \:3092 SourceVault \:306b\:767b\:9332\:3059\:308b\:3002\n" <>
  "  - path: \:7d76\:5bfe\:30d1\:30b9 or \:30ed\:30fc\:30ab\:30eb\:30d1\:30b9\:306e _String\n" <>
  "  - NotebookRef \:306f path-based hash \:3067\:5b89\:5b9a\:751f\:6210\:3055\:308c\:308b\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> _, \"NotebookRef\" -> _, \"Path\" -> _, \"RegisteredAt\" -> _|>";

SourceVaultIndexNotebook::usage =
  "SourceVaultIndexNotebook[path, opts] \:306f notebook \:306e Header / Todo / Cell \:3092\:62bd\:51fa\:3057\:3066 index \:3092\:66f4\:65b0\:3059\:308b\:3002\n" <>
  "Options:\n" <>
  "  \"ExtractHeader\" -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 True)\n" <>
  "  \"ExtractTodos\" -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 True)\n" <>
  "  \"ForceReindex\" -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 False\:3001file mtime \:540c\:3058\:306a\:3089 skip)\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> _, \"NotebookRef\" -> _, \"SnapshotId\" -> _,\n" <>
  "  \"Header\" -> _, \"TodoCount\" -> _, \"OpenTodoCount\" -> _, \"ReviewState\" -> _,\n" <>
  "  \"DeadlineState\" -> _, \"Lint\" -> {...}|>";

SourceVaultIndexNotebookFolder::usage =
  "SourceVaultIndexNotebookFolder[dir, opts] \:306f\:6307\:5b9a folder \:914d\:4e0b\:306e .nb \:3092\:5168\:3066 index \:3059\:308b\:3002\n" <>
  "Options:\n" <>
  "  \"Recursive\" -> True | False (\:30c7\:30d5\:30a9\:30eb\:30c8 False)\n" <>
  "  \"ExcludePatterns\" -> {\"*.bak.nb\", \"Untitled*.nb\"} (\:30c7\:30d5\:30a9\:30eb\:30c8)\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> _, \"Processed\" -> _Integer, \"Failed\" -> _Integer, \"Results\" -> {...}|>";

SourceVaultExtractNotebookHeader::usage =
  "SourceVaultExtractNotebookHeader[path] \:306f notebook \:306e\:5148\:982d Input \:30bb\:30eb\:304b\:3089 Header Association \:3092 safe parse \:3059\:308b\:3002\n" <>
  "HoldComplete + whitelist \:3067 RunProcess / Get / Import \:7b49\:306e\:5371\:967a\:5f0f\:3092\:62d2\:5426\:3002\n" <>
  "\:623b\:308a\:5024: <|\"ParseStatus\" -> \"OK\" | \"MissingHeader\" | \"UnsafeExpression\",\n" <>
  "  \"Keywords\" -> _, \"Deadline\" -> _, \"NextReview\" -> _, \"Status\" -> _|>";

SourceVaultExtractNotebookTodos::usage =
  "SourceVaultExtractNotebookTodos[path] \:306f notebook \:5185\:306e TodoItem \:30b9\:30bf\:30a4\:30eb\:30bb\:30eb\:3092\:5217\:6319\:3059\:308b\:3002\n" <>
  "Status \:306f 3 \:5024 (Open / Done / Pass) \:3002\:5224\:5b9a\:306f TaggingRules > FontVariations StrikeThrough + FontColor > Default \:306e\:512a\:5148\:9806\:4f4d\:3002\n" <>
  "  - StrikeThrough \:306a\:3057                                          \[RightArrow] Open (Todo)\n" <>
  "  - StrikeThrough \:3042\:308a + FontColor \:7dd1 (RGB g > r, g > b)            \[RightArrow] Done\n" <>
  "  - StrikeThrough \:3042\:308a + FontColor \:7070 (GrayLevel / RGB r\[TildeTilde]g\[TildeTilde]b)      \[RightArrow] Pass\n" <>
  "  - StrikeThrough \:3042\:308a + \:305d\:306e\:4ed6                                \[RightArrow] Done (\:5f8c\:65b9\:4e92\:63db)\n" <>
  "\:623b\:308a\:5024: {<|\"Text\" -> _, \"Status\" -> _, \"StatusSource\" -> _, \"StrikeThrough\" -> _Bool|>, ...}";

SourceVaultFindNotebooks::usage =
  "SourceVaultFindNotebooks[opts] \:306f index \:6e08\:307f notebook \:3092\:691c\:7d22\:3059\:308b\:3002LLM \:4e0d\:8981\:306e deterministic query\:3002\n" <>
  "Options:\n" <>
  "  \"OpenTodos\" -> True | False (\:672a\:5b8c\:4e86 Todo \:3092\:542b\:3080 / \:542b\:307e\:306a\:3044 notebook)\n" <>
  "  \"NextReview\" -> \"Today\" | \"Overdue\" | \"ThisWeek\" | \"DueSoon\" | <|\"From\" -> _, \"To\" -> _|>\n" <>
  "    \:203b \"Today\" \:306f\:53b3\:5bc6\:306b\:4eca\:65e5\:306e\:307f\:3001\"ThisWeek\"/\"DueSoon\" \:306f\:4eca\:65e5\[PlusMinus]7\:65e5\:4ee5\:5185 (\:4eca\:9031\:5185\:306b\:904e\:304e\:305f\:671f\:9650\:5207\:308c\:3082\:542b\:3080\:304c\:9060\:3044\:904e\:53bb\:306f\:9664\:5916)\:3001\"Overdue\" \:306f\:671f\:9650\:5207\:308c\:5168\:90e8\n" <>
  "  \"Deadline\" -> \"Today\" | \"Overdue\" | \"ThisWeek\" | \"DueSoon\" | <|\"From\" -> _, \"To\" -> _|>\n" <>
  "  \"Keywords\" -> {_String, ...} | _String -- \:90e8\:5206\:4e00\:81f4\:691c\:7d22\n" <>
  "    \:691c\:7d22\:5bfe\:8c61: Header.Keywords + Header.Title + FileBaseName[Path] + \:89aa\:30d5\:30a9\:30eb\:30c0\:540d\n" <>
  "    \:8907\:6570\:6307\:5b9a\:6642\:306f OR (\:3069\:308c\:304b\:306b\:90e8\:5206\:4e00\:81f4\:3057\:305f\:3089\:8a72\:5f53)\n" <>
  "  \"Title\" -> _String | {_String, ...} -- \"Keywords\" \:3068\:540c\:3058\:691c\:7d22\:30d7\:30fc\:30eb\:3092\:898b\:308b (\:30a8\:30a4\:30ea\:30a2\:30b9)\n" <>
  "  \"Status\" -> \"Todo\" | \"Done\" | \"Done\" | _String\n" <>
  "  \"Scope\" -> \"Today\" \:8907\:5408\:30d5\:30a3\:30eb\:30bf: (NextReview==\:4eca\:65e5) | (Deadline==\:4eca\:65e5) | (Path \:306b YYYYMMDD \:5f62\:5f0f\:3067\:4eca\:65e5\:3092\:542b\:3080) \:306e OR\n" <>
  "    \:203b NoReviewDate / NoDeadline \:306f\:30ec\:30d3\:30e5\:30fc\:4e0d\:8981\:6271\:3044\:3001Scope \"Today\" \:306b\:306f\:542b\:307e\:308c\:306a\:3044\n" <>
  "  \"ForceReindex\" -> True | False (\:65e2\:5b9a False) -- True \:306a\:3089 mtime/\:30cf\:30c3\:30b7\:30e5 cache \:3092\:7121\:8996\:3057\:5168 notebook \:3092\:518d index\:3002\n" <>
  "    notebook \:3092\:7de8\:96c6\:3057\:305f\:306e\:306b\:7d50\:679c\:304c\:53e4\:3044 (Deadline/NextReview/Status \:304c\:66f4\:65b0\:3055\:308c\:306a\:3044) \:5834\:5408\:306b\:4f7f\:3046\:3002\n" <>
  "  \"Format\" -> True | False (\:65e2\:5b9a False) -- True \:306a\:3089\:7d50\:679c\:3092 SourceVaultFormatNotebookList \:3067\n" <>
  "    \:30b9\:30b1\:30b8\:30e5\:30fc\:30eb\:8868\:3068\:540c\:5f62\:5f0f\:306e Grid \:306b\:3057\:3066\:8fd4\:3059\:3002\:4e00\:89a7\:8868\:793a\:7528\:30b7\:30e7\:30fc\:30c8\:30ab\:30c3\:30c8\:3002\n" <>
  "\:623b\:308a\:5024: {record, ...}\:3002\:5404 record \:306f Association \:3067\:6b21\:306e\:30ad\:30fc\:3092\:6301\:3064:\n" <>
  "  \"Path\" / \"OriginalPath\" -> notebook \:306e\:5b9f\:30d5\:30a1\:30a4\:30eb\:30d1\:30b9 (\:540c\:5024\:30a8\:30a4\:30ea\:30a2\:30b9)\n" <>
  "  \"Title\" -> \:30bf\:30a4\:30c8\:30eb (Header.Title \:307e\:305f\:306f FileBaseName)\n" <>
  "  \"NotebookRef\" -> \:53c2\:7167\:30ad\:30fc, \"Header\" -> Header Association (Keywords/Deadline/NextReview/Status/Title)\n" <>
  "  \"Todos\" -> {<|\"Text\", \"Status\"(Open|Done|Pass), ...|>, ...} (\:62bd\:51fa\:6e08\:307f todo \:672c\:4f53)\n" <>
  "  \"TodoCount\" / \"OpenTodoCount\" / \"DoneTodoCount\" / \"PassTodoCount\" -> _Integer\n" <>
  "  \"ReviewState\" / \"DeadlineState\" -> _String, \"Lint\" -> {...}\n" <>
  "  \:203b todo \:9805\:76ee\:81ea\:4f53\:3092\:5217\:6319\:3057\:305f\:3044\:5834\:5408\:306f record[\"Todos\"] \:3092\:4f7f\:3046\:3002\n" <>
  "    SourceVaultExtractNotebookTodos[record[\"Path\"]] \:3067\:3082\:53d6\:308c\:308b\:304c\:3001\:518d\:62bd\:51fa\:3068\:306a\:308b\:305f\:3081 record[\"Todos\"] \:63a8\:5968\:3002";

SourceVaultNotebookLint::usage =
  "SourceVaultNotebookLint[record] \:306f notebook record (\:307e\:305f\:306f path) \:306b\:5bfe\:3057\:3066 lint \:30c1\:30a7\:30c3\:30af\:3092\:884c\:3046\:3002\n" <>
  "\:691c\:51fa\:3055\:308c\:308b lint:\n" <>
  "  MissingHeader / UnsafeHeaderExpression / HeaderDeadlineMalformed / HeaderNextReviewMalformed\n" <>
  "  HeaderStatusTodoButNoOpenTodos / HeaderStatusDoneButOpenTodosExist\n" <>
  "  DeadlinePast / NextReviewPast / TodoCellStatusHeuristicOnly\n" <>
  "\:623b\:308a\:5024: {\"LintName1\", \"LintName2\", ...}";

(* \[HorizontalLine]\[HorizontalLine] Stage 9 Phase 2 (P1) Step 1: TaggingRules \:6a19\:6e96\:5316 \[HorizontalLine]\[HorizontalLine] *)

SourceVaultExtractNotebookTaggingRules::usage =
  "SourceVaultExtractNotebookTaggingRules[path] \:306f notebook \:5168\:4f53\:304a\:3088\:3073\:5404 TodoItem cell \:306e TaggingRules \:3092\:53d6\:5f97\:3059\:308b\:3002\n" <>
  "Stage 9 Phase 2 (P1) Step 1 \:3067\:8ffd\:52a0\:3055\:308c\:305f\:3001TaggingRules \:6a19\:6e96\:5316\:306e\:305f\:3081\:306e\:30d5\:30a1\:30a4\:30eb\:7d4c\:7531\:30e1\:30bf\:30c7\:30fc\:30bf\:53d6\:5f97 API\:3002\n" <>
  "Wolfram \:6a19\:6e96\:95a2\:6570\:512a\:5148\:539f\:5247 (rule 102) \:306b\:57fa\:3065\:304d\:3001`Import[path, \"Notebook\"]` \:306e Notebook \:5f0f\:304b\:3089 TaggingRules \:3092\:62bd\:51fa + `NotebookImport[path, style -> \"Cell\"]` \:3067\:5404 TodoItem cell \:306e options \:304b\:3089 TaggingRules \:3092\:62bd\:51fa\:3059\:308b\:3002\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> \"OK\" | \"Failed\",\n" <>
  "  \"Path\" -> _String,\n" <>
  "  \"NotebookTaggingRules\" -> _Association  (Notebook[..., TaggingRules -> _] \:306e\:5024\:3001\:7121\:3051\:308c\:3070 <||>),\n" <>
  "  \"CellTaggingRules\" -> {<|\"Index\" -> _Integer, \"CellStyle\" -> _String, \"TaggingRules\" -> _Association|>, ...}|>";

SourceVaultNotebookSemanticHash::usage =
  "SourceVaultNotebookSemanticHash[path] \:306f notebook \:306e\:610f\:5473\:7684\:5185\:5bb9\:306e\:307f\:3092\:5bfe\:8c61\:306b\:3057\:305f\:30cf\:30c3\:30b7\:30e5\:3092\:8a08\:7b97\:3059\:308b\:3002\n" <>
  "Stage 9 Phase 2 (P1) Step 2 \:3067\:8ffd\:52a0\:3055\:308c\:305f\:3001NotebookSemanticHash \:5b9f\:88c5\:3002\n" <>
  "\:8868\:793a\:30e1\:30bf\:30c7\:30fc\:30bf (ExpressionUUID / CellChangeTimes / CellLabel / FontFamily \:7b49)\:3084\n" <>
  "\:30a6\:30a3\:30f3\:30c9\:30a6\:8a2d\:5b9a (WindowSize / WindowMargins / FrontEndVersion \:7b49) \:306f\:9664\:5916\:3057\:3001\n" <>
  "\:610f\:5473\:7684\:306b\:91cd\:8981\:306a\:8981\:7d20 (content / style / TaggingRules / FontVariations / FontColor / Background) \:3060\:3051\:3092\:30cf\:30c3\:30b7\:30e5\:5bfe\:8c61\:3068\:3059\:308b\:3002\n" <>
  "Stage 8 (vN diff / snapshot lifecycle) \:3068\:9023\:643a\:3001formatting \:306e\:307f\:306e\:5909\:66f4\:3067 Stale \:5316\:8aa4\:5224\:5b9a\:3092\:9632\:3050\:3002\n" <>
  "Wolfram \:6a19\:6e96\:95a2\:6570\:512a\:5148\:539f\:5247 (rule 102): Import[path, \"Notebook\"] + Hash[normalizedExpr, \"SHA256\", \"HexString\"]\:3002\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> \"OK\" | \"Failed\", \"Path\" -> _String, \"SemanticHash\" -> _String|>";

(* \[HorizontalLine]\[HorizontalLine] Stage 9 Phase 2 (P1) Step 4: Summary artifact stale \:5224\:5b9a \[HorizontalLine]\[HorizontalLine] *)

SourceVaultRegisterNotebookSummary::usage =
  "SourceVaultRegisterNotebookSummary[path, summary, opts:OptionsPattern[]] \:306f notebook \:306e summary artifact \:3092\:767b\:9332\:3059\:308b\:3002\n" <>
  "Stage 9 Phase 2 (P1) Step 4 \:3067\:8ffd\:52a0\:3055\:308c\:305f\:3001Summary artifact lifecycle \:7ba1\:7406\:306e\:679a\:7d44\:307f\:3002\n" <>
  "Step 5 (LLM \:8981\:7d04) \:304c\:672a\:5b9f\:88c5\:306e\:73fe\:6642\:70b9\:3067\:306f\:3001summary \:6587\:5b57\:5217\:3092\:5916\:90e8\:304b\:3089\:53d7\:3051\:53d6\:3063\:3066\:4fdd\:5b58\:3059\:308b\:5f62\:5f0f\:3002\n" <>
  "\:73fe\:5728\:306e snapshot (SnapshotId + SemanticHash) \:3068\:7d10\:3065\:3051\:3066\:4fdd\:5b58\:3055\:308c\:308b\:305f\:3081\:3001\:5f8c\:65e5 stale \:5224\:5b9a\:53ef\:80fd\:3002\n" <>
  "\:30aa\:30d7\:30b7\:30e7\:30f3: \"SummaryFormat\" -> \"text\" | \"markdown\" (default \"text\"),\n" <>
  "          \"GeneratedBy\" -> _String (default \"manual\")\:3002\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> \"OK\" | \"Failed\", \"SummaryId\" -> _String, \"NotebookRef\" -> _String, ...|>";

SourceVaultGetNotebookSummary::usage =
  "SourceVaultGetNotebookSummary[path] \:306f notebook \:306b\:7d10\:3065\:304f summary record \:3092\:53d6\:5f97\:3059\:308b\:3002\n" <>
  "Summary \:304c\:672a\:767b\:9332\:306e\:5834\:5408\:306f \"Status\" -> \"Missing\" \:3092\:8fd4\:3059\:3002\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> \"OK\" | \"Missing\" | \"Failed\",\n" <>
  "  \"Summary\" -> _String, \"SummaryFormat\" -> _String,\n" <>
  "  \"BasedOnSnapshot\" -> _String, \"BasedOnSemanticHash\" -> _String,\n" <>
  "  \"GeneratedBy\" -> _String, \"CreatedAt\" -> _String|>";

SourceVaultNotebookSummaryStatus::usage =
  "SourceVaultNotebookSummaryStatus[path] \:306f notebook \:306e summary artifact \:306e\:73fe\:5728 lifecycle \:30b9\:30c6\:30fc\:30bf\:30b9\:3092\:5224\:5b9a\:3059\:308b\:3002\n" <>
  "\:5224\:5b9a\:30ed\:30b8\:30c3\:30af (Step 5 \:4ee5\:964d\:3067\:81ea\:52d5\:30ea\:30d5\:30ec\:30c3\:30b7\:30e5\:6c7a\:5b9a\:306b\:6d3b\:7528):\n" <>
  "  Missing                 - summary \:304c\:307e\:3060\:5b58\:5728\:3057\:306a\:3044 (Step 5 \:521d\:56de\:5b9f\:884c\:5fc5\:9808)\n" <>
  "  Current                 - summary \:306e BasedOnSnapshot \:304c\:73fe\:5728\:306e snapshot \:3068\:4e00\:81f4\n" <>
  "  StaleFormattingOnly     - SemanticHash \:304c\:4e00\:81f4 (formatting \:306e\:307f\:306e\:5909\:66f4\:3001\:518d\:751f\:6210\:4efb\:610f)\n" <>
  "  Stale                   - SemanticHash \:304c\:5909\:308f\:3063\:305f (\:518d\:751f\:6210\:63a8\:5968)\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> _String, \"Reason\" -> _String,\n" <>
  "  \"CurrentSnapshot\" -> _String, \"SummaryBasedOnSnapshot\" -> _String|_Missing|>";

(* \[HorizontalLine]\[HorizontalLine] Stage 9 Phase 2 (P1) Step 6: SourceVaultMarkTodo \[HorizontalLine]\[HorizontalLine] *)

SourceVaultMarkTodo::usage =
  "SourceVaultMarkTodo[path, target, newStatus, opts:OptionsPattern[]] \:306f notebook \:5185\:306e Todo cell \:306e Status \:3092\:5909\:66f4\:3059\:308b\:3002\n" <>
  "Stage 9 Phase 2 (P1) Step 6 \:3067\:8ffd\:52a0\:3055\:308c\:305f\:3001\:66f8\:304d\:8fbc\:307f\:7cfb\:6700\:521d\:306e API\:3002\n" <>
  "NBAccess \:306e\:9ad8\:30ec\:30d9\:30eb API NBWriteTodoStatus \:3078\:306e\:8584\:3044\:30e9\:30c3\:30d1\:30fc\:3002\n" <>
  "target: Integer (1-based Todo Index) / String (TodoId) / Association (<|\"Index\" -> n, \"Text\" -> \"...\"|>)\n" <>
  "newStatus: \"Open\" / \"Done\" / \"Pass\"\n" <>
  "\:5909\:66f4\:5185\:5bb9 (NBWriteTodoStatus \:306b\:59d4\:3060):\n" <>
  "  - Cell options: FontVariations StrikeThrough + FontColor (\:7dd1/\:7070)\n" <>
  "  - Cell TaggingRules: <|\"SourceVault\" -> <|\"TodoStatus\" -> newStatus|>|>\n" <>
  "\:30aa\:30d7\:30b7\:30e7\:30f3:\n" <>
  "  \"DryRun\" -> True              - True \:306f preview \:306e\:307f (default True\:3001\:5b89\:5168\:5074)\n" <>
  "  \"AutoReindex\" -> True         - \:7de8\:96c6\:6210\:529f\:5f8c\:306b SourceVaultIndexNotebook \:3092\:81ea\:52d5\:547c\:3073\:51fa\:3057 (default True\:3001\:5b9f\:884c\:6642\:306e\:307f)\n" <>
  "  \"AccessSpec\" -> <|\"AccessLevel\" -> 0.7, ...|>  - NBAccess \:306b\:6e21\:3055\:308c\:308b\:3002default level=0.7\n" <>
  "\:623b\:308a\:5024 (DryRun):\n" <>
  "  <|\"Status\" -> \"DryRunOK\", \"Target\" -> _, \"MatchedTodo\" -> <|...|>,\n" <>
  "    \"OldStatus\" -> _, \"NewStatus\" -> _, \"CellPath\" -> {_Integer...},\n" <>
  "    \"Before\" -> HoldComplete[...], \"After\" -> HoldComplete[...]|>\n" <>
  "\:623b\:308a\:5024 (\:5b9f\:884c):\n" <>
  "  <|\"Status\" -> \"OK\" | \"Failed\", \"Target\" -> _, \"MatchedTodo\" -> <|...|>,\n" <>
  "    \"OldStatus\" -> _, \"NewStatus\" -> _,\n" <>
  "    \"ReindexResult\" -> _Association | Missing[\"NotRequested\"]|>";

(* \[HorizontalLine]\[HorizontalLine] Stage 9 Phase 2 (P1) Step 5: LLM \:8981\:7d04 \[HorizontalLine]\[HorizontalLine] *)

SourceVaultNotebookSummary::usage =
  "SourceVaultNotebookSummary[path, opts:OptionsPattern[]] \:306f notebook \:306e\:5185\:5bb9\:3092 LLM \:3067\:8981\:7d04\:3057\:3001Summary artifact \:3068\:3057\:3066\:4fdd\:5b58\:3059\:308b\:3002\n" <>
  "Stage 9 Phase 2 (P1) Step 5 \:3067\:8ffd\:52a0\:3055\:308c\:305f\:3001LLM \:7d4c\:7531\:306e notebook \:8981\:7d04 API\:3002\n" <>
  "Step 4 \:306e SourceVaultRegisterNotebookSummary \:3092\:5185\:90e8\:3067\:547c\:3076\:305f\:3081\:3001snapshot \:30fb SemanticHash \:7d10\:3065\:3051\:30fb lifecycle \:7ba1\:7406\:306f\:81ea\:52d5\:3002\n" <>
  "\:30d7\:30e9\:30a4\:30d0\:30b7\:30fc: \:9ed8\:8a8d\:3067 PrivacyLevel -> 1.0 (\:30ed\:30fc\:30ab\:30eb LM \:7d4c\:7531\:3067 notebook \:5185\:5bb9\:3092 API \:306b\:9001\:3089\:306a\:3044)\:3002\n" <>
  "\:30aa\:30d7\:30b7\:30e7\:30f3:\n" <>
  "  \"ForceRefresh\" -> False    - \:65e2\:5b58 summary \:304c Current \:3067\:3082\:5f37\:5236\:518d\:751f\:6210\n" <>
  "  \"MaxLength\" -> 500          - \:8981\:7d04\:306e\:6700\:5927\:6587\:5b57\:6570 (LLM prompt \:7d4c\:7531\:3067\:6307\:5b9a)\n" <>
  "  \"Language\" -> Automatic     - \:8981\:7d04\:8a00\:8a9e (Automatic / \"Japanese\" / \"English\")\n" <>
  "  \"Model\" -> Automatic        - {\"provider\", \"model\"} \:660e\:793a\:6307\:5b9a\:53ef\n" <>
  "  \"PrivacyLevel\" -> 1.0       - 0.0 (API \:8a31\:53ef) \:301c 1.0 (\:30ed\:30fc\:30ab\:30eb\:306e\:307f)\n" <>
  "  \"FallbackToCloud\" -> \"Ask\"  - \"Ask\" | \"Allow\" | \"Deny\" (Step 3 \:8ffd\:52a0)\n" <>
  "\:623b\:308a\:5024:\n" <>
  "  Current \:3067 ForceRefresh \:7121\:3057\:306e\:5834\:5408: \:65e2\:5b58 record \:3092\:8fd4\:3059 (Get \:3068\:540c\:5f62)\n" <>
  "  \:751f\:6210\:6210\:529f\:306e\:5834\:5408: Register \:3068\:540c\:5f62\:306e Association\n" <>
  "  Inconsistent \:306e\:5834\:5408 (FallbackToCloud \:30ad\:30e3\:30f3\:30bb\:30eb): <|\"Status\" -> \"Inconsistent\", \"Reason\" -> _String, ...|>\n" <>
  "  \:5931\:6557\:306e\:5834\:5408: <|\"Status\" -> \"Failed\", \"Reason\" -> _String, ...|>";


(* \[HorizontalLine]\[HorizontalLine] Stage 9 Phase 2 (P1) Step 3 (Step 2 in palette): SourceVaultUpcomingSchedule \[HorizontalLine]\[HorizontalLine] *)

SourceVaultUpcomingSchedule::usage =
  "SourceVaultUpcomingSchedule[opts:OptionsPattern[]] \:306f\:300c\:4eca\:65e5\:304b\:3089 N \:65e5\:4ee5\:5185\:300d\:306b Deadline / NextReview \:304c\:3042\:308b\n" <>
  "notebook \:306e\:4e00\:89a7\:3092 Dataset \:3067\:8fd4\:3059\:3002\:6982\:8981\:3082\:30ad\:30e3\:30c3\:30b7\:30e5\:304b\:3089\:53d6\:308a\:8fbc\:3080 (\:5fc5\:8981\:6642\:306f\:81ea\:52d5\:518d\:751f\:6210)\:3002\n" <>
  "\:65e5\:4ed8\:306f yyyy/mm/dd \:5f62\:5f0f\:3001\:671f\:9650\:5207\:308c\:306f\:8d64\:3001\:4eca\:65e5\:307e\:305f\:306f\:660e\:65e5\:306f\:9752\:3002\n" <>
  "\:30aa\:30d7\:30b7\:30e7\:30f3:\n" <>
  "  \"Scope\" -> dir | _String                - \:30c7\:30a3\:30ec\:30af\:30c8\:30ea (default $onWork \:307e\:305f\:306f $packageDirectory)\n" <>
  "  \"Period\" -> Quantity[7, \"Days\"]          - \:4eca\:65e5\:304b\:3089\:306e\:5c06\:6765\:671f\:9593 (default 7 \:65e5)\n" <>
  "  \"IncludeOverdue\" -> True                 - Deadline \:8d85\:904e\:3082\:542b\:3081\:308b (default True)\n" <>
  "  \"Recursive\" -> True                      - \:30b5\:30d6\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:3082\:30b9\:30ad\:30e3\:30f3 (default True)\n" <>
  "  \"Refresh\" -> \"Never\"                     - \"Never\" | \"IfStale\" | \"Force\" \:6982\:8981\:518d\:751f\:6210\:65b9\:91dd\:3002\n" <>
  "    \:65e2\:5b9a Never \:306f\:8868\:793a\:6642\:306b LLM \:3092\:547c\:3070\:305a\:4fdd\:5b58\:6e08\:307f Summary \:3060\:3051\:3092\:8868\:793a\:3001\:7121\:3051\:308c\:3070 Keywords \:3092\n" <>
  "    \:30c4\:30fc\:30eb\:30c1\:30c3\:30d7\:306b fallback (\:5f31\:3044 LLM \:74b0\:5883\:7528)\:3002\:751f\:6210\:306f SourceVaultRefreshAllSummaries \:3067\:884c\:3046\:3002\n" <>
  "  \"FallbackToCloud\" -> \"Ask\"               - \"Ask\" | \"Allow\" | \"Deny\" (\:30ed\:30fc\:30ab\:30eb LLM \:4e0d\:5728\:6642)\n" <>
  "  \"StatusFilter\" -> {\"Todo\"}               - {\"Todo\"} | {\"Todo\", \"Done\", \"Pass\"} | All (default \"Todo\" \:306e\:307f)\n" <>
  "  \"UseCache\" -> True                       - \:524d\:56de\:5b9f\:884c\:306e in-memory cache \:3092\:6d3b\:7528\:3057\:9ad8\:901f\:5316 (default True)\n" <>
  "\:623b\:308a\:5024: Dataset[\:884c={Deadline, NextReview, Title (Open button), Dir (Open button),\n" <>
  "                  OpenTodos, Status, Privacy}]";

SourceVaultFormatNotebookList::usage =
  "SourceVaultFormatNotebookList[records_List, opts:OptionsPattern[]] \:306f notebook record \:306e List \:3092\n" <>
  "\:30b9\:30b1\:30b8\:30e5\:30fc\:30eb\:8868\:3068\:540c\:3058\:8868\:5f62\:5f0f (Deadline / NextReview / Title (Open button) / Dir (Open button) /\n" <>
  "OpenTodos / Status / Summary / Publishable) \:3067 Grid \:8868\:793a\:3059\:308b\:3002\n" <>
  "SourceVaultFindNotebooks \:306e\:623b\:308a\:5024\:3001SourceVaultIndexNotebook \:306e OK record \:306e List\:3001\n" <>
  "Path/Header \:3092\:6301\:3064\:4efb\:610f\:306e Association List \:3092\:53d7\:3051\:4ed8\:3051\:308b\:3002\n" <>
  "\:30aa\:30d7\:30b7\:30e7\:30f3:\n" <>
  "  \"Refresh\" -> \"Never\"                     - \"Never\" | \"IfStale\" | \"Force\" \:6982\:8981\:518d\:751f\:6210\:65b9\:91dd\:3002\n" <>
  "    \:65e2\:5b9a Never \:306f\:8868\:793a\:6642\:306b LLM \:3092\:547c\:3070\:305a\:4fdd\:5b58\:6e08\:307f Summary \:3060\:3051\:3092\:8868\:793a\:3001\:7121\:3051\:308c\:3070 Keywords \:3092\n" <>
  "    \:30c4\:30fc\:30eb\:30c1\:30c3\:30d7\:306b fallback (\:5f31\:3044 LLM \:74b0\:5883\:7528)\:3002\:751f\:6210\:306f SourceVaultRefreshAllSummaries \:3067\:884c\:3046\:3002\n" <>
  "  \"FallbackToCloud\" -> \"Deny\"              - \"Ask\" | \"Allow\" | \"Deny\"\n" <>
  "  \"UseCache\" -> True                       - in-memory cache \:3092\:6d3b\:7528\n" <>
  "\:623b\:308a\:5024: Grid (\:884c={Deadline, NextReview, Title, Dir, OpenTodos, Status, Summary, Publishable})\:3002\n" <>
  "ClaudeEval \:306a\:3069\:3067 notebook list \:3092\:8868\:793a\:3059\:308b\:969b\:306e\:65e2\:5b9a\:30d5\:30a9\:30fc\:30de\:30c3\:30c8\:95a2\:6570\:3002";

SourceVaultFindTodos::usage =
  "SourceVaultFindTodos[opts] \:306f\:6761\:4ef6\:306b\:5408\:3046 notebook \:306e todo \:9805\:76ee\:3092\:30d5\:30e9\:30c3\:30c8\:306a List \:3067\:8fd4\:3059\:3002\n" <>
  "SourceVaultFindNotebooks \:3068\:540c\:3058 notebook \:691c\:7d22\:30aa\:30d7\:30b7\:30e7\:30f3 (OpenTodos / NextReview / Deadline / Keywords / Title / Status / Scope) \:3092\:53d7\:3051\:3001\n" <>
  "\:30de\:30c3\:30c1\:3057\:305f\:5404 notebook \:306e todo \:30bb\:30eb\:3092 1 \:884c 1 \:9805\:76ee\:306b\:5c55\:958b\:3059\:308b\:3002\n" <>
  "\:300c\:4eca\:9031\:671f\:9650\:306e todo \:3092\:30ea\:30b9\:30c8\:300d\:306e\:3088\:3046\:306a todo \:5358\:4f4d\:306e\:8981\:6c42\:306b\:306f notebook \:5358\:4f4d\:306e FindNotebooks \:3067\:306f\:306a\:304f\:3053\:3061\:3089\:3092\:4f7f\:3046\:3002\n" <>
  "Options:\n" <>
  "  \"TodoStatus\" -> \"Open\" | \"Done\" | \"Pass\" | All (\:65e2\:5b9a \"Open\" -- \:5c55\:958b\:5f8c\:306e todo \:3092\:3055\:3089\:306b status \:3067\:7d5e\:308b)\n" <>
  "  \:305d\:306e\:4ed6\:306f SourceVaultFindNotebooks \:3068\:5171\:901a (OpenTodos / NextReview / Deadline / Keywords / Title / Status / Scope)\n" <>
  "  \"Format\" -> True | False (\:65e2\:5b9a False) -- True \:306a\:3089 Grid \:8868\:793a\n" <>
  "\:623b\:308a\:5024: {<|\"Title\", \"Path\", \"NotebookRef\", \"Deadline\", \"NextReview\", \"ReviewState\", \"DeadlineState\",\n" <>
  "  \"TodoText\", \"TodoStatus\", \"TodoStrikeThrough\"|>, ...}\:3002Format->True \:306e\:3068\:304d\:306f Grid\:3002";

SourceVaultNewNotebook::usage =
  "SourceVaultNewNotebook[opts] \:306f\:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:304b\:3089\:65b0\:898f\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092 CreateNotebook \:3067\:958b\:304f\:3002\n" <>
  "\:30c6\:30f3\:30d7\:30ec\:30fc\:30c8 ($packageDirectory/Templates/SourceVault notebook template.nb) \:3092\:8907\:88fd\:3057\:3001\n" <>
  "NotebookStatus \:30bb\:30eb\:306e Deadline \:3068 NextReview \:3092\:751f\:6210\:65e5 (\:65e2\:5b9a: \:4eca\:65e5) \:306b\:7f6e\:63db\:3057\:3066\n" <>
  "\:672a\:4fdd\:5b58\:306e\:65b0\:898f\:30a6\:30a3\:30f3\:30c9\:30a6\:3068\:3057\:3066\:8868\:793a\:3059\:308b (\:30d5\:30a1\:30a4\:30eb\:306b\:306f\:4fdd\:5b58\:3057\:306a\:3044)\:3002\n" <>
  "Deadline/NextReview \:306f DateObject[{y, m, d}] \:306e\:7de8\:96c6\:53ef\:80fd\:306a\:5165\:529b\:5f0f\:3067\:633f\:5165\:3055\:308c\:308b\:3002\n" <>
  "Options:\n" <>
  "  \"TemplatePath\" -> Automatic | path  -- \:30c6\:30f3\:30d7\:30ec\:30fc\:30c8 .nb (\:65e2\:5b9a: \:30d1\:30c3\:30b1\:30fc\:30b8\:5185 Templates)\n" <>
  "  \"Title\" -> Automatic | _String      -- \:30a6\:30a3\:30f3\:30c9\:30a6\:30bf\:30a4\:30c8\:30eb (\:65e2\:5b9a \"\:65b0\:898f\:30ce\:30fc\:30c8\")\n" <>
  "  \"Date\" -> Automatic | _DateObject    -- Deadline/NextReview \:306b\:5165\:308c\:308b\:65e5\:4ed8 (\:65e2\:5b9a: \:4eca\:65e5)\n" <>
  "  \"Keywords\" -> Automatic | {_String..} | _String -- NotebookStatus \:306e Keywords \:3092\:7f6e\:63db (\:65e2\:5b9a Automatic \:306f\:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:5024\:3092\:7dad\:6301)\n" <>
  "  \"SessionID\" -> Automatic | _String -- NotebookStatus \:306b capture session \:3078\:306e\:9006\:30ea\:30f3\:30af (SessionID) \:3092\:57cb\:3081\:8fbc\:3080 (\:65e2\:5b9a Automatic \:306f\:8ffd\:52a0\:3057\:306a\:3044)\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> \"OK\", \"Notebook\" -> _NotebookObject, \"Date\" -> _, \"StatusCellReplaced\" -> _Bool, \"Saved\" -> False, ...|>\:3002\n" <>
  "\:526f\:4f5c\:7528: \:65b0\:898f\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:30a6\:30a3\:30f3\:30c9\:30a6\:3092\:958b\:304f (\:672a\:4fdd\:5b58)\:3002\:30e6\:30fc\:30b6\:304c\:660e\:793a\:7684\:306b\:4fdd\:5b58\:3059\:308b\:307e\:3067\:30c7\:30a3\:30b9\:30af\:306b\:306f\:66f8\:304b\:306a\:3044\:3002";

SourceVaultRefreshAllSummaries::usage =
  "SourceVaultRefreshAllSummaries[opts:OptionsPattern[]] \:306f Scope \:914d\:4e0b\:5168 notebook \:306e\:6982\:8981\:3092\:4e00\:62ec\:518d\:751f\:6210\:3059\:308b\:3002\n" <>
  "\:30aa\:30d7\:30b7\:30e7\:30f3:\n" <>
  "  \"Scope\" -> dir | _String                - \:30c7\:30a3\:30ec\:30af\:30c8\:30ea (default $onWork)\n" <>
  "  \"Recursive\" -> True                      - \:30b5\:30d6\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:3082\:30b9\:30ad\:30e3\:30f3 (default True)\n" <>
  "  \"ForceRefresh\" -> False                  - True \:306f\:5168\:4ef6\:518d\:751f\:6210\n" <>
  "  \"FallbackToCloud\" -> \"Deny\"              - \"Ask\" | \"Allow\" | \"Deny\" (\:4e00\:62ec\:6642\:306f Deny \:63a8\:5968)\n" <>
  "  \"OpenTodosOnly\" -> False                  - True \:306a\:3089 OpenTodoCount > 0 \:306e\:30ce\:30fc\:30c8\:3060\:3051\:751f\:6210\:5bfe\:8c61 (\:5b9f\:7528\:7684\:306a\:30b5\:30d6\:30bb\:30c3\:30c8)\n" <>
  "  \"Model\" -> Automatic                      - SourceVaultNotebookSummary \:306b\:6e21\:3059\:30e2\:30c7\:30eb\:6307\:5b9a\:3002\:5f37\:529b LLM \:74b0\:5883 / \:5225 PC \:30d0\:30c3\:30c1\:30b8\:30e7\:30d6\:7528\n" <>
  "  \"Progress\" -> False                       - True \:306a\:3089 Print \:3067 10 \:4ef6\:6bce\:306b\:9032\:6357\:8868\:793a\n" <>
  "  \"Limit\" -> Infinity                       - \:6700\:5927\:51e6\:7406\:30d5\:30a1\:30a4\:30eb\:6570 (\:30c6\:30b9\:30c8\:30fb\:6bb5\:968e\:5b9f\:884c\:7528)\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> \"OK\", \"Scope\", \"TotalFiles\", \"Refreshed\", \"Cached\", \"Inconsistent\", \"Failed\", \"Details\"|>";


(* \[HorizontalLine]\[HorizontalLine] Stage 9 P1 Step 5: \:30af\:30ed\:30b9 PC \:30d1\:30b9\:6b63\:898f\:5316 + \:30b9\:30c8\:30a2\:30ea\:30bb\:30c3\:30c8 \[HorizontalLine]\[HorizontalLine] *)

$SourceVaultCloudRoots::usage =
  "$SourceVaultCloudRoots \:306f\:30af\:30e9\:30a6\:30c9\:5171\:6709\:30d5\:30a9\:30eb\:30c0\:306e\:30b7\:30f3\:30dc\:30eb\:540d\:30ea\:30b9\:30c8\:3002\n" <>
  "\:4f8b: {\"$packageDirectory\", \"$dropbox\", \"$onWork\", \"$offWork\", \"$mathematicaWork\"}\:3002\n" <>
  "\:7d76\:5bfe\:30d1\:30b9\:306f\:3053\:308c\:3089\:306e\:914d\:4e0b\:306b\:3042\:308c\:3070 {\"$onWork\", \"folder\", \"file.nb\"} \:306e\:3088\:3046\:306a\n" <>
  "\:30b7\:30f3\:30dc\:30ea\:30c3\:30af\:30d1\:30b9\:306b\:6b63\:898f\:5316\:3055\:308c\:3001PC / OS \:3092\:307e\:305f\:3044\:3067\:540c\:4e00 ID \:306b\:306a\:308b\:3002\n" <>
  "PC \:56fa\:6709\:30d5\:30a9\:30eb\:30c0 ($ClaudeWorkingDirectory \:7b49) \:306f\:542b\:3081\:306a\:3044\:3053\:3068\:3002";

$SourceVaultCloudRootAliases::usage =
  "$SourceVaultCloudRootAliases \:306f\:30af\:30e9\:30a6\:30c9\:30eb\:30fc\:30c8\:306e\:30b7\:30f3\:30dc\:30eb\:540d (\"$onWork\" \:7b49) \:304b\:3089\:3001\:65e7 PC \:306a\:3069\:5225\:74b0\:5883\:3067\:306e\:7d76\:5bfe\:30d1\:30b9\:306e\:30ea\:30b9\:30c8\:3078\:306e\:5bfe\:5fdc\:3092\:8868\:3059 Association\:3002\n" <>
  "\:5f62\:5f0f: <|\"$onWork\" -> {\"C:/Users/imai_/Dropbox/On Work\"}, ...|> (\:30d1\:30b9\:533a\:5207\:308a\:306f / \:3067\:3082 \\ \:3067\:3082\:53ef\:3001\:5185\:90e8\:3067\:7d71\:4e00\:3055\:308c\:308b)\:3002\n" <>
  "iSVSymbolicPath \:306f\:30eb\:30fc\:30c8\:306e\:73fe PC \:5b9f\:4f53\:306b\:52a0\:3048\:3001\:3053\:3053\:306b\:767b\:9332\:3055\:308c\:305f\:30a8\:30a4\:30ea\:30a2\:30b9\:30d1\:30b9\:306e\:914d\:4e0b\:3082\:540c\:3058\:30b7\:30f3\:30dc\:30eb\:540d\:306b\:30de\:30c3\:30c1\:3055\:305b\:308b\:3002\n" <>
  "\:3053\:308c\:306b\:3088\:308a\:5225 PC \:3067 index \:3055\:308c\:305f\:30ec\:30b3\:30fc\:30c9\:306e\:65e7\:30d1\:30b9\:3092 {\"$onWork\", ...} \:306b\:6b63\:898f\:5316\:3067\:304d\:3001\:8907\:6570 PC \:3092\:307e\:305f\:3044\:3060\:4e8c\:91cd\:767b\:9332\:3092\:672a\:7136\:306b\:9632\:3050\:3002\n" <>
  "\:30a8\:30a4\:30ea\:30a2\:30b9\:30d1\:30b9\:306f\:73fe PC \:306b\:5b9f\:5728\:3057\:306a\:304f\:3066\:3088\:3044 (\:6587\:5b57\:5217\:524d\:65b9\:4e00\:81f4\:3001Windows \:3092\:60f3\:5b9a\:3057\:5927\:6587\:5b57\:5c0f\:6587\:5b57\:306f\:7121\:8996)\:3002\:65e2\:5b9a\:306f <||> (\:30a8\:30a4\:30ea\:30a2\:30b9\:306a\:3057)\:3002";

$SourceVaultDefaultNotebookFolder::usage =
  "$SourceVaultDefaultNotebookFolder is the default folder for SourceVault notebooks. " <>
  "When Automatic (the default), it resolves to Global`$onWork, falling back to $packageDirectory. " <>
  "Set it to an absolute directory path to make that folder the default Scope for SourceVault " <>
  "and the save target used by PresentationListener.";


SourceVaultResetStore::usage =
  "SourceVaultResetStore[opts:OptionsPattern[]] \:306f SourceVault \:306e notebooks \:30b9\:30c8\:30a2\n" <>
  "(sources / snapshots / summaries / todos / review / lint / sync / relink) \:3092\:5168\:524a\:9664\:3057\:3066\:521d\:671f\:5316\:3059\:308b\:3002\n" <>
  "NotebookRef \:65b9\:5f0f\:5909\:66f4\:306a\:3069\:3067\:65e7\:30c7\:30fc\:30bf\:3092\:7834\:68c4\:3057\:305f\:3044\:3068\:304d\:306b\:4f7f\:3046\:3002\n" <>
  "\:7834\:58ca\:7684\:64cd\:4f5c\:306e\:305f\:3081\:3001\:5b9f\:884c\:306b\:306f\:660e\:793a\:7684\:306a\:627f\:8a8d\:304c\:5fc5\:8981:\n" <>
  "  \"Confirm\" -> True                        - \:3053\:308c\:304c\:7121\:3044\:3068 DryRun \:6271\:3044\:3001\:5b9f\:969b\:306b\:306f\:524a\:9664\:3057\:306a\:3044\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> \"OK\"|\"DryRun\"|\"Failed\", \"Deleted\" -> _List, \"NotebooksDir\" -> _|>";

$SourceVaultMaxFileSizeMB::usage =
  "$SourceVaultMaxFileSizeMB \:306f index \:6642\:306b .nb \:3092 Import \:3059\:308b\:30d5\:30a1\:30a4\:30eb\:30b5\:30a4\:30ba\:306e\:4e0a\:9650 (MB)\:3002\n" <>
  "\:65e2\:5b9a: 50\:3002\:3053\:308c\:3092\:8d85\:3048\:308b .nb (\:30b7\:30df\:30e5\:30ec\:30fc\:30b7\:30e7\:30f3\:7d50\:679c\:7b49\:306e\:5de8\:5927\:30d5\:30a1\:30a4\:30eb) \:306f\n" <>
  "Import \:305b\:305a\:3001\:30d5\:30a1\:30a4\:30eb\:60c5\:5831\:3060\:3051\:306e\:8efd\:91cf snapshot \:3092\:4f5c\:308b (Skipped \:30de\:30fc\:30af)\:3002\n" <>
  "\:5de8\:5927\:30d5\:30a1\:30a4\:30eb\:306e Import \:306b\:3088\:308b\:30e1\:30e2\:30ea\:67af\:6e07\:30fb\:30cf\:30f3\:30b0\:3092\:9632\:3050\:3002";

(* \[HorizontalLine]\[HorizontalLine] Stage 3: Context retrieval / ClaudeAttach \:4e92\:63db \[HorizontalLine]\[HorizontalLine] *)

SourceVaultSpan::usage =
  "SourceVaultSpan[snapshotOrRef, opts] \:306f SourceSpan association \:3092\:4f5c\:308b\:3002\n" <>
  "snapshotOrRef \:306f SnapshotId, SourceRef, file path \:306e\:3044\:305a\:308c\:304b\:3002\n" <>
  "Options:\n" <>
  "  \"Pages\" -> {1, 3, 5} | All | _Integer\n" <>
  "  \"Role\" -> \"ReferenceContext\" | \"Evidence\" | \"ExtractionInput\"\n" <>
  "  \"Purpose\" -> \"LaTeXMathFormatting\" | _String";

SourceVaultContext::usage =
  "SourceVaultContext[sourceSpan, opts] \:306f sourceSpan \:306e plaintext \:3092\:53d6\:308a\:51fa\:3057\:3001\n" <>
  "NBAuthorize \:306e\:5224\:5b9a\:4ed8\:304d\:3067 LLM \:6587\:8108\:3068\:3057\:3066\:8fd4\:3059\:3002\n" <>
  "Options: MaxCharacters, \"Sink\", \"Purpose\".";

SourceVaultContextAssemble::usage =
  "SourceVaultContextAssemble[sourceSpans, opts] \:306f\:8907\:6570 span \:3092 1 \:3064\:306e prompt context \:306b\:7d44\:307f\:7acb\:3066\:308b\:3002\n" <>
  "Options:\n" <>
  "  \"Purpose\" -> _String\n" <>
  "  MaxCharacters -> _Integer\n" <>
  "  \"Ordering\" -> \"PageOrder\" | \"Citation\" | \"GivenOrder\"\n" <>
  "  \"Separators\" -> \"ByPage\" | \"BySource\" | None\n" <>
  "  \"IncludeCitations\" -> True | False\n" <>
  "  \"Sink\" -> _Association";

SourceVaultAttach::usage =
  "SourceVaultAttach[nb, source, opts] \:306f notebook \:306b source \:3092 attach \:3057\:3001\n" <>
  "TaggingRules \:306b sourceVaultRefs \:3092\:8a18\:9332\:3059\:308b\:3002\n" <>
  "\:65e7 ClaudeAttach \:306e\:30d0\:30c3\:30af\:30a8\:30f3\:30c9\:4ee3\:308f\:308a\:3002";

SourceVaultAttachToCell::usage =
  "SourceVaultAttachToCell[nb, cellIdx, sourceSpan, opts] \:306f cell \:306b SourceSpan \:3092 attach \:3059\:308b\:3002";

SourceVaultGetAttachments::usage =
  "SourceVaultGetAttachments[nb] \:306f notebook \:306b attach \:3055\:308c\:305f source \:4e00\:89a7\:3092\:8fd4\:3059\:3002";

SourceVaultGetCellSources::usage =
  "SourceVaultGetCellSources[nb, cellIdx] \:306f cell \:306b\:7d10\:3065\:304f SourceSpan \:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002\n" <>
  "\:65e7\:5f62\:5f0f (refSources) \:3092 read-only normalization \:3057\:3066\:65b0\:5f62\:5f0f\:3068\:3057\:3066\:8fd4\:3059\:3002";

SourceVaultEnsureRegistered::usage =
  "SourceVaultEnsureRegistered[ref] \:306f\:65e7 refSources \:5f62\:5f0f (\:3042\:308b\:3044\:306f file path) \:3092\n" <>
  "SourceSpan \:5f62\:5f0f\:306b normalize \:3059\:308b\:3002\:5fc5\:8981\:306b\:5fdc\:3058\:3066 ingest \:3059\:308b\:3002";

(* \[HorizontalLine]\[HorizontalLine] Materialization \[HorizontalLine]\[HorizontalLine] *)

SourceVaultMaterializeForSink::usage =
  "SourceVaultMaterializeForSink[sourceRef, sinkSpec, opts] \:306f source \:3092 cloud-accessible mirror \:3078\n" <>
  "materialize \:3059\:308b\:3002\:5185\:90e8\:3067\:5fc5\:305a NBAuthorize \:3092\:547c\:3076\:3002";

SourceVaultResolvePath::usage =
  "SourceVaultResolvePath[ref, opts] \:306f source/snapshot \:306e\:7269\:7406 path \:3092\:8fd4\:3059\:3002\n" <>
  "\"Tier\" -> \"PrivateVault\" \:306f local kernel / maintenance \:5c02\:7528\:3002\n" <>
  "cloud LLM \:5411\:3051\:306b\:306f SourceVaultMaterializeForSink \:3092\:4f7f\:3046\:3053\:3068\:3002";

SourceVaultObjectSpec::usage =
  "SourceVaultObjectSpec[ref, opts] \:306f source/snapshot \:3092 NBAuthorize \:304c\:53d7\:3051\:53d6\:308c\:308b\n" <>
  "object spec association \:306b\:5909\:63db\:3059\:308b\:3002";

(* \[HorizontalLine]\[HorizontalLine] Options \[HorizontalLine]\[HorizontalLine] *)

Topic::usage = "Topic \:306f SourceVaultIngest \:30aa\:30d7\:30b7\:30e7\:30f3\:3002";
PinVersion::usage = "PinVersion \:306f SourceVaultIngest \:30aa\:30d7\:30b7\:30e7\:30f3\:3002";
TrustLevel::usage = "TrustLevel \:306f SourceVaultIngest \:30aa\:30d7\:30b7\:30e7\:30f3\:3002";
PrivacyLabel::usage = "PrivacyLabel \:306f SourceVaultIngest \:30aa\:30d7\:30b7\:30e7\:30f3\:3002";
MaxCharacters::usage = "MaxCharacters \:306f SourceVaultContext / SourceVaultContextAssemble \:30aa\:30d7\:30b7\:30e7\:30f3\:3002";


(* \[HorizontalLine]\[HorizontalLine] ClaudeAttach Integration (Stage 3 integrated, 2026-05-18) \[HorizontalLine]\[HorizontalLine] *)

SourceVaultClaudeAttachIntegrationEnable::usage =
  "SourceVaultClaudeAttachIntegrationEnable[] \:306f ClaudeAttach \:547c\:51fa\:6642\:306b\n" <>
  "SourceVault \:3078\:306e side-channel ingest \:3092\:884c\:3046 hook \:3092\:6709\:52b9\:5316\:3059\:308b\:3002\n" <>
  "\:65e2\:306b\:6709\:52b9\:5316\:6e08\:307f\:306e\:5834\:5408\:306f noop\:3002\n" <>
  "\:5143\:306e DownValue \:306f\:4fdd\:6301\:3055\:308c\:3001Disable \:3067\:5fa9\:5143\:53ef\:3002\n" <>
  "\:524d\:63d0: claudecode.wl (ClaudeCode`ClaudeAttach) \:304c\:30ed\:30fc\:30c9\:6e08\:307f\:3067\:3042\:308b\:3053\:3068\:3002";

SourceVaultClaudeAttachIntegrationDisable::usage =
  "SourceVaultClaudeAttachIntegrationDisable[] \:306f hook \:3092\:5916\:3057\:3001\n" <>
  "ClaudeAttach \:3092\:5143\:306e DownValue \:306b\:5fa9\:5143\:3059\:308b\:3002";

SourceVaultClaudeAttachIntegrationStatus::usage =
  "SourceVaultClaudeAttachIntegrationStatus[] \:306f\:73fe\:5728\:306e hook \:72b6\:614b\:3092\:8fd4\:3059\:3002\n" <>
  "Keys: Enabled, OriginalSaved, OriginalDVCount, HookTarget";

SourceVaultGetClaudeAttachRefs::usage =
  "SourceVaultGetClaudeAttachRefs[nb] \:306f notebook nb \:306b\:7d10\:3065\:3044\:305f\n" <>
  "ClaudeAttach side-channel ingest \:8a18\:9332\:306e flat list \:3092\:8fd4\:3059\:3002\n" <>
  "\:5404 entry \:306f Association: OriginalPathOrURL / ExpandedPath / SnapshotId /\n" <>
  "SourceId / ContentHash / IngestStatus / AttachedAt\:3002\n" <>
  "SourceVaultGetClaudeAttachRefs[] \:306f EvaluationNotebook[] \:3092\:4f7f\:3046\:3002";


(* \[HorizontalLine]\[HorizontalLine] ClaudeAttachments Integration (Stage 3 integrated P2, 2026-05-18) \[HorizontalLine]\[HorizontalLine] *)

SourceVaultClaudeAttachmentsIntegrationEnable::usage =
  "SourceVaultClaudeAttachmentsIntegrationEnable[] \:306f ClaudeAttachments[] \:547c\:51fa\:6642\:306b\n" <>
  "\:623b\:308a\:5024\:3092 List of paths \:304b\:3089 Association list \:306b\:62e1\:5f35\:3059\:308b hook \:3092\:6709\:52b9\:5316\:3059\:308b\:3002\n" <>
  "\:5404 Association \:306b\:306f cached path / source / metadata + SourceVault \:306e\n" <>
  "SnapshotId / SourceId / ContentHash / IngestStatus \:304c join \:3055\:308c\:308b\:3002\n" <>
  "\:524d\:63d0: claudecode.wl (ClaudeCode`ClaudeAttachments) \:304c\:30ed\:30fc\:30c9\:6e08\:307f\:3067\:3042\:308b\:3053\:3068\:3002";

SourceVaultClaudeAttachmentsIntegrationDisable::usage =
  "SourceVaultClaudeAttachmentsIntegrationDisable[] \:306f hook \:3092\:5916\:3057\:3001\n" <>
  "ClaudeAttachments \:3092\:5143\:306e DownValue \:306b\:5fa9\:5143\:3059\:308b\:3002";

SourceVaultClaudeAttachmentsIntegrationStatus::usage =
  "SourceVaultClaudeAttachmentsIntegrationStatus[] \:306f\:73fe\:5728\:306e hook \:72b6\:614b\:3092\:8fd4\:3059\:3002";


(* \[HorizontalLine]\[HorizontalLine] WorkerPrompt Integration (Stage 3 integrated P3, 2026-05-18) \[HorizontalLine]\[HorizontalLine] *)

SourceVaultWorkerPromptIntegrationEnable::usage =
  "SourceVaultWorkerPromptIntegrationEnable[] \:306f ClaudeOrchestrator \:306e A5 hook \:306b\n" <>
  "SourceVault context \:6ce8\:5165\:95a2\:6570\:3092\:767b\:9332\:3057\:3001worker prompt \:69cb\:7bc9\:6642\:306b\:5439\:51fa\:3055\:308c\:308b\:3088\:3046\:306b\:3059\:308b\:3002\n" <>
  "\:524d\:63d0: ClaudeOrchestrator.wl \:306b A5 hook 5 \:884c\:304c\:8ffd\:52a0\:6e08\:307f (Phase 34 A4 hook \:3068\:540c\:4f4d\:7f6e)\:3002\n" <>
  "\:30c8\:30ea\:30ac\:30fc: task[\"SourceSpans\"] (\:660e\:793a\:6307\:5b9a) + ClaudeAttach \:5c65\:6b74 (\:81ea\:52d5\:691c\:51fa)\:3002";

SourceVaultWorkerPromptIntegrationDisable::usage =
  "SourceVaultWorkerPromptIntegrationDisable[] \:306f A5 hook \:306e\:5b9a\:7fa9\:3092\:30af\:30ea\:30a2\:3057\:3001\n" <>
  "ClaudeOrchestrator \:306f A5 hook \:3092\:30b9\:30ad\:30c3\:30d7\:3059\:308b (Names \:3067\:30bb\:30fc\:30d5\:30c1\:30a7\:30c3\:30af\:3055\:308c\:3066\:3044\:308b)\:3002";

SourceVaultWorkerPromptIntegrationStatus::usage =
  "SourceVaultWorkerPromptIntegrationStatus[] \:306f\:73fe\:5728\:306e A5 hook \:72b6\:614b\:3092\:8fd4\:3059\:3002";

$SourceVaultWorkerPromptAutoDetect::usage =
  "$SourceVaultWorkerPromptAutoDetect \:306f A5 hook \:6709\:52b9\:6642\:306e\:81ea\:52d5\:691c\:51fa ON/OFF\:3002\n" <>
  "True (\:30c7\:30d5\:30a9\:30eb\:30c8): ClaudeAttach \:5c65\:6b74\:304b\:3089 SnapshotId \:3092\:81ea\:52d5\:691c\:51fa\:3057\:3066\:6ce8\:5165\:3002\n" <>
  "False: task[\"SourceSpans\"] \:660e\:793a\:6307\:5b9a\:306e\:307f\:4f7f\:7528\:3002";


(* \[HorizontalLine]\[HorizontalLine] ParseProposal Integration (Stage 3 integrated P4, 2026-05-18) \[HorizontalLine]\[HorizontalLine] *)

SourceVaultParseProposalIntegrationEnable::usage =
  "SourceVaultParseProposalIntegrationEnable[] \:306f ClaudeOrchestrator \:306e A6 hook \:306b\n" <>
  "parseProposal post-processing \:95a2\:6570\:3092\:767b\:9332\:3057\:3001LLM \:5fdc\:7b54\:5185\:306e\n" <>
  "<source>snap-...</source> / <source>src-...</source> XML \:30bf\:30b0\:3092\:62bd\:51fa\:3057\:3066\n" <>
  "parseProposal \:306e\:623b\:308a\:5024 Association \:306b \"SourceVaultRefs\" \:30ad\:30fc\:3092\:8ffd\:52a0\:3059\:308b\:3002\n" <>
  "\:524d\:63d0: ClaudeOrchestrator.wl \:306b iApplyA6Hook + A6 hook \:5448\:5165\:3057\:6e08\:307f (P4 \:5bfe\:5fdc\:7248)\:3002";

SourceVaultParseProposalIntegrationDisable::usage =
  "SourceVaultParseProposalIntegrationDisable[] \:306f A6 hook \:306e\:5b9a\:7fa9\:3092\:30af\:30ea\:30a2\:3057\:3001\n" <>
  "iApplyA6Hook \:306f no-op \:306b\:623b\:308b\:3002";

SourceVaultParseProposalIntegrationStatus::usage =
  "SourceVaultParseProposalIntegrationStatus[] \:306f\:73fe\:5728\:306e A6 hook \:72b6\:614b\:3092\:8fd4\:3059\:3002";

SourceVaultSetSnapshotPrivacyLevel::usage =
  "SourceVaultSetSnapshotPrivacyLevel[snapshotId, level] \:306f snapshot record \:306e PrivacyLevel \:30d5\:30a3\:30fc\:30eb\:30c9\:3092\n" <>
  "\:660e\:793a\:7684\:306b\:4e0a\:66f8\:304d\:3059\:308b\:3002NBAccess`NBSetSnapshotPrivacyLevel \:306e\:59d4\:8b72\:5148\:3067\:3042\:308a\:3001\n" <>
  "\:627f\:8a8d\:30b2\:30fc\:30c8\:306f NBAccess \:5074\:306e $NBApprovalHeads \:767b\:9332\:3067\:767a\:706b\:3059\:308b\:3002\n" <>
  "Notebook snapshot (notebooks/snapshots/) \:3068 PDF/URL snapshot (raw/meta/) \:306e\:4e21\:7cfb\:7d71\:3092\n" <>
  "\:30d5\:30a1\:30a4\:30eb\:5b58\:5728\:3067\:5224\:5225\:3057\:3066\:51e6\:7406\:3059\:308b\:3002level \:306f 0.0-1.0 \:306b clip \:3055\:308c\:308b\:3002\n" <>
  "\:65e2\:5b58\:5024\:3088\:308a\:4f4e\:3044\:5024\:3092\:6307\:5b9a\:3057\:305f\:5834\:5408\:306f \"Lowered\" -> True \:3092\:8fd4\:3059 (\:624b\:52d5\:64cd\:4f5c\:306a\:306e\:3067\:8a31\:53ef\:3001Sync \:7d4c\:8def\:306e\:5358\:8abf\:6027\:5236\:7d04\:3068\:306f\:5225)\:3002\n" <>
  "\:623b\:308a\:5024: <|\"Status\" -> _, \"SnapshotId\" -> _, \"OldPrivacyLevel\" -> _, \"NewPrivacyLevel\" -> _, \"Lowered\" -> _, \"SnapshotKind\" -> _|>";

SourceVaultSelectSources::usage =
  "SourceVaultSelectSources[opts] \:306f\:540c\:671f\:5bfe\:8c61\:3068\:306a\:308b source \:3092\:9078\:5b9a\:3057\:3066\:8fd4\:3059\:3002\nScope \:914d\:4e0b\:306e .nb \:3092\:30b9\:30ad\:30e3\:30f3\:3057\:3001\:5404\:30d5\:30a1\:30a4\:30eb\:3092 source descriptor \:5316\:3059\:308b\:3002\n\:30aa\:30d7\:30b7\:30e7\:30f3: Scope / Recursive / Kind / ExcludePatterns\:3002\n\:623b\:308a\:5024: <|\"Status\" -> _, \"Scope\" -> _, \"Count\" -> _, \"Sources\" -> {_Association..}|>";

SourceVaultSyncPlan::usage =
  "SourceVaultSyncPlan[opts] \:306f\:5404 source \:306e\:9bae\:5ea6\:3092\:5224\:5b9a\:3057\:540c\:671f\:8a08\:753b\:3092\:8fd4\:3059 (dry-run\:3001\:526f\:4f5c\:7528\:306a\:3057)\:3002\n\:9bae\:5ea6\:30c8\:30fc\:30af\:30f3 (\:30ed\:30fc\:30ab\:30eb\:306f mtime) \:3092\:73fe snapshot \:306e\:8a18\:9332\:3068\:6bd4\:8f03\:3057 Fresh/Stale/Missing/NeverIndexed \:306b\:5206\:985e\:3059\:308b\:3002\n\:30aa\:30d7\:30b7\:30e7\:30f3: Scope / Recursive / Kind / ExcludePatterns\:3002\n\:623b\:308a\:5024: <|\"Status\" -> _, \"Total\" -> _, \"StaleCount\" -> _, \"Plan\" -> _Dataset, ...|>";

SourceVaultSync::usage =
  "SourceVaultSync[opts] \:306f SyncPlan \:306b\:5f93\:3044 Stale \:306a source \:3092\:518d index \:3059\:308b (\:30af\:30ed\:30fc\:30e9\:30fc\:9aa8\:683c)\:3002\n\:30ed\:30fc\:30ab\:30eb notebook \:306f SourceVaultIndexNotebook \:3067\:518d index \:3059\:308b\:3002PrivacyLevel \:306f\:5358\:8abf (\:81ea\:52d5\:3067\:4e0b\:3052\:306a\:3044):\n\:518d index \:3067 PrivacyLevel \:304c\:4e0b\:304c\:3063\:305f\:5834\:5408\:306f SourceVaultSetSnapshotPrivacyLevel \:3067\:65e7\:5024\:306b\:5f15\:304d\:4e0a\:3052\:3001\:8b66\:544a\:3092\:8a18\:9332\:3059\:308b\:3002\n\:30aa\:30d7\:30b7\:30e7\:30f3: Scope / Recursive / Kind / DryRun / ForceAll / RefreshSummary / FallbackToCloud (\:4e00\:62ec\:540c\:671f\:306e\:65e2\:5b9a\:306f \"Deny\")\:3002\nsync/sync-history.jsonl \:306b\:8a18\:9332\:3057 sync/last-sync.json \:3092\:66f4\:65b0\:3059\:308b\:3002\n\:623b\:308a\:5024: <|\"Status\" -> _, \"SyncId\" -> _, \"Refreshed\" -> _, \"Skipped\" -> _, \"Failed\" -> _, \"PrivacyWarnings\" -> _|>";

SourceVaultSyncStatus::usage =
  "SourceVaultSyncStatus[] \:306f\:76f4\:8fd1\:306e sync \:5b9f\:884c\:306e\:72b6\:614b (sync/last-sync.json) \:3092\:8fd4\:3059\:3002\n\:4e00\:5ea6\:3082 sync \:3057\:3066\:3044\:306a\:3051\:308c\:3070 <|\"Status\" -> \"NoSyncYet\"|>\:3002";

SourceVaultRelinkSources::usage =
  "SourceVaultRelinkSources[opts] \:306f OriginalPath \:304c\:5b58\:5728\:3057\:306a\:304f\:306a\:3063\:305f (\:79fb\:52d5\:3055\:308c\:305f) notebook source \:3092\:691c\:51fa\:3057\:3001Scope \:914d\:4e0b\:304b\:3089\:79fb\:52d5\:5148\:3092\:63a2\:3057\:3066\:518d\:30ea\:30f3\:30af\:3059\:308b\:3002\n\:7167\:5408\:306f (1) \:57cb\:3081\:8fbc\:307f UUID (TaggingRules \:306e SourceVault > NotebookUUID\:3001SourceVaultEnsureNotebookUUID \:3067\:4ed8\:4e0e)\:3001(2) \:5185\:5bb9\:30cf\:30c3\:30b7\:30e5 (RawContentHash \:5b8c\:5168\:4e00\:81f4)\:3001(3) \:30d5\:30a1\:30a4\:30eb\:540d\:4e00\:610f\:4e00\:81f4 \:306e\:9806\:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3059\:308b\:3002\n\:30aa\:30d7\:30b7\:30e7\:30f3: Scope / Recursive / DryRun (\:65e2\:5b9a True\:3001\:5b89\:5168\:5074) / ApplyNameOnly (\:65e2\:5b9a False) / DeleteStale (\:65e2\:5b9a False) / ExcludePatterns\:3002\n\:79fb\:52d5\:5224\:5b9a\:306f\:30b7\:30f3\:30dc\:30ea\:30c3\:30af\:30d1\:30b9\:89e3\:6c7a\:30d9\:30fc\:30b9 (\:5358\:306a\:308b PC\:30fb\:30eb\:30fc\:30c8\:30d1\:30b9\:5dee\:3092\:79fb\:52d5\:3068\:8aa4\:691c\:51fa\:3057\:306a\:3044)\:3002\nUUID/ContentHash \:4e00\:81f4\:306f\:81ea\:52d5\:9069\:7528\:3059\:308b\:304c\:3001NameOnly (\:5f31\:3044\:8a3c\:62e0) \:306f ApplyNameOnly -> True \:306e\:3068\:304d\:306e\:307f\:9069\:7528\:3057\:30ec\:30dd\:30fc\:30c8\:306e\:307f\:304c\:65e2\:5b9a\:3002\n\:30de\:30c3\:30c1\:5148\:304c\:65e2\:306b\:5225\:306e\:73fe\:5f79 record \:306e\:6307\:3059\:5b9f\:30d5\:30a1\:30a4\:30eb\:306a\:3089\:79fb\:52d5\:3067\:306a\:304f StaleDuplicate (\:65e7 PC index \:306e\:6b8b\:9ab8) \:3068\:3057\:3066\:5206\:985e\:3059\:308b (\:5b9f\:30d1\:30b9\:3067\:5224\:5b9a)\:3002\nDeleteStale -> True \:3067 StaleDuplicate \:306e\:6b8b\:9ab8 record \:30d5\:30a1\:30a4\:30eb\:3092 sources/ \:304b\:3089\:524a\:9664\:3059\:308b (\:65e2\:5b9a False \:306f\:975e\:7834\:58ca\:30de\:30fc\:30af\:306e\:307f)\:3002\nDryRun -> False \:306e\:3068\:304d: \:79fb\:52d5\:5148\:3092 SourceVaultIndexNotebook \:3067\:518d index \:3057\:3001\:65e7 source record \:306b Superseded \:30de\:30fc\:30af\:3092\:4ed8\:3051\:308b (\:65e7 record \:306f\:524a\:9664\:3057\:306a\:3044\:3001\:53ef\:9006)\:3002\nrelink/relink-log.jsonl \:306b\:8a18\:9332\:3059\:308b\:3002\n\:623b\:308a\:5024: <|\"Status\" -> _, \"Linked\" -> _, \"Relinked\" -> {..}, \"RelinkedCount\" -> _, \"ByMethod\" -> <|\"UUID\"/\"ContentHash\"/\"NameOnly\" -> _|>, \"Unresolved\" -> {..}, \"DryRun\" -> _|>";

$SourceVaultModelEndpoints::usage =
  "$SourceVaultModelEndpoints \:306f provider \:540d\:304b\:3089 \:30e2\:30c7\:30eb\:4e00\:89a7\:30a8\:30f3\:30c9\:30dd\:30a4\:30f3\:30c8\:8a2d\:5b9a\:3078\:306e Association\:3002\:30e6\:30fc\:30b6\:30fc\:304c\:4e0a\:66f8\:304d\:53ef\:80fd (LM Studio \:306e\:30dd\:30fc\:30c8\:7b49\:306f\:74b0\:5883\:4f9d\:5b58)\:3002\:5404\:5024\:306f <|\"ModelsURL\" -> _, \"Kind\" -> \"Cloud\"|\"Local\", \"AuthProvider\" -> _|>\:3002";

SourceVaultModelEndpointStatus::usage =
  "SourceVaultModelEndpointStatus[] \:306f\:5404 provider \:30a8\:30f3\:30c9\:30dd\:30a4\:30f3\:30c8\:306e\:5230\:9054\:6027 (\:30aa\:30d5\:30e9\:30a4\:30f3\:691c\:77e5) \:3092\:8fd4\:3059\:3002\:77ed\:3044\:30bf\:30a4\:30e0\:30a2\:30a6\:30c8\:3067 probe \:3057\:3001401/403 \:304c\:8fd4\:3063\:3066\:3082 \:30b5\:30fc\:30d0\:30fc\:5230\:9054 = Online \:3068\:307f\:306a\:3059\:3002\:623b\:308a\:5024: <|\"Status\" -> _, \"Endpoints\" -> <|provider -> <|\"Status\" -> \"Online\"|\"Offline\", ...|>|>|>\:3002";

SourceVaultDetectLocalModels::usage =
  "SourceVaultDetectLocalModels[opts] \:306f\:30ed\:30fc\:30ab\:30eb LLM \:30b5\:30fc\:30d0\:30fc (LM Studio \:7b49\:3001OpenAI \:4e92\:63db /v1/models) \:304b\:3089\:30e2\:30c7\:30eb\:4e00\:89a7\:3092\:63a8\:6e2c\:3059\:308b\:3002API \:30ad\:30fc\:4e0d\:8981\:3002\n\:30aa\:30d7\:30b7\:30e7\:30f3: Provider (\:65e2\:5b9a \"lmstudio\") / Endpoint (\:65e2\:5b9a\:306f ClaudeCode`$ClaudePrivateModel \:306e url \:3092\:512a\:5148\:3001\:7121\:3051\:308c\:3070 $SourceVaultModelEndpoints \:306e\:8a2d\:5b9a)\:3002\:30b5\:30fc\:30d0\:30fc\:304c\:30ad\:30fc\:4fdd\:8b77\:6709\:52b9\:306a\:5834\:5408\:3001API \:30ad\:30fc\:306f NBAccess`NBGetLocalLLMAPIKey \:7d4c\:7531\:3067\:81ea\:52d5\:89e3\:6c7a\:3055\:308c\:308b (\:4e8b\:524d\:306b NBStoreLocalLLMAPIKey \:3067\:767b\:9332)\:3002\n\:623b\:308a\:5024: <|\"Status\" -> \"OK\"|\"Offline\", \"Provider\" -> _, \"Endpoint\" -> _, \"Models\" -> {_String..}|>\:3002";

SourceVaultSetModel::usage =
  "SourceVaultSetModel[provider, intent, modelId, opts] \:306f compiled model registry \:306b\n" <>
  "\:624b\:52d5\:3067 1 \:30a8\:30f3\:30c8\:30ea\:3092\:66f8\:304d\:8fbc\:3080 (API \:30ad\:30fc\:4e0d\:8981)\:3002Source -> \"manual\" \:3067\:4fdd\:5b58\:3057\:3001\:540c (provider,\n" <>
  "intent) \:306e\:65e2\:5b58\:30a8\:30f3\:30c8\:30ea\:3092\:7f6e\:304d\:63db\:3048\:308b\:3002\:30aa\:30d5\:30e9\:30a4\:30f3\:74b0\:5883\:3084 API \:30ad\:30fc\:672a\:767b\:9332\:74b0\:5883\:3067\:6700\:65b0\:30e2\:30c7\:30eb\:3092\n" <>
  "\:56fa\:5b9a\:3057\:305f\:3044\:3068\:304d\:3001\:307e\:305f\:306f\:81ea\:52d5\:53d6\:5f97\:3067\:304d\:306a\:3044\:30e2\:30c7\:30eb\:3092\:6307\:5b9a\:3057\:305f\:3044\:3068\:304d\:306b\:4f7f\:3046\:3002\n" <>
  "\:30aa\:30d7\:30b7\:30e7\:30f3: Channel (\:65e2\:5b9a public) / Class (\:65e2\:5b9a Automatic=\:63a8\:8ad6) / Capabilities (\:65e2\:5b9a Automatic)\:3002\n" <>
  "\:4f8b: SourceVaultSetModel[\"anthropic\", \"heavy\", \"claude-opus-4-8\"]";

SourceVaultClearModelRegistry::usage =
  "SourceVaultClearModelRegistry[opts] \:306f compiled model registry \:3092\:524a\:9664\:3057\:3001\:6b21\:56de\:30a2\:30af\:30bb\:30b9\:6642\:306b\n" <>
  "seed (\:30b3\:30fc\:30c9\:5185\:306e\:6700\:65b0 iModelSeedEntries) \:304b\:3089\:518d\:69cb\:7bc9\:3055\:305b\:308b\:3002compiled \:306b\:53e4\:3044 seed \:30b3\:30d4\:30fc\n" <>
  "(\:4f8b: \:904e\:53bb\:306b\:30b3\:30d4\:30fc\:3055\:308c\:305f claude-opus-4-7) \:304c\:6b8b\:3063\:3066 ClaudeResolveModel \:304c\:53e4\:3044 ID \:3092\:8fd4\:3057\n" <>
  "\:7d9a\:3051\:308b\:3068\:304d\:306e\:5fa9\:65e7\:7528\:3002seed \:81ea\:4f53\:306f\:6d88\:3055\:306a\:3044\:3002\:30aa\:30d7\:30b7\:30e7\:30f3: Channel (\:65e2\:5b9a public)\:3002\n" <>
  "\:4f8b: SourceVaultClearModelRegistry[]";

SourceVaultSetModelIntent::usage =
  "SourceVaultSetModelIntent[variable, spec] \:306f SourceVault \:304c\:9078\:629e\:3059\:308b\:30e2\:30c7\:30eb\:306e intent \:5272\:308a\:5f53\:3066\:3092\n" <>
  "\:5909\:66f4\:3059\:308b\:3002variable: \"$ClaudeModel\" | \"$ClaudeDocModel\" | \"$ClaudePrivateModel\" |\n" <>
  "\"$ClaudeFallbackModels\"\:3002spec: {provider, intent} (\:4f8b {\"anthropic\", \"heavy\"})\:3001\n" <>
  "FallbackModels \:306f {{provider,intent}, ...}\:3002\:8a2d\:5b9a\:5f8c SourceVaultAssignClaudeModels[] \:3092\:547c\:3093\:3067\n" <>
  "\:5b9f\:5909\:6570\:306b\:53cd\:6620\:3059\:308b\:3002\:3053\:306e\:95a2\:6570\:306f $NBApprovalHeads \:306b\:767b\:9332\:3055\:308c\:3001ClaudeEval \:7d4c\:7531\:3067\:306f\n" <>
  "Hold -> Approve \:304c\:5fc5\:8981 (\:30e2\:30c7\:30eb\:9078\:629e\:306e\:5909\:66f4\:306f\:691c\:8a3c\:5bfe\:8c61)\:3002\n" <>
  "\:4f8b: SourceVaultSetModelIntent[\"$ClaudeModel\", {\"anthropic\", \"heavy\"}]";

SourceVaultModelIntentMap::usage =
  "SourceVaultModelIntentMap[] \:306f\:5909\:6570\:540d -> intent spec \:306e\:30de\:30c3\:30d4\:30f3\:30b0\:3092\:8fd4\:3059\:8aad\:307f\:53d6\:308a\:516c\:958b\:95a2\:6570\:3002\n" <>
  "NBAccess`NBSyncClaudeModelVars \:304c\:3053\:308c\:3092\:8aad\:3093\:3067\:30e2\:30c7\:30eb\:5909\:6570\:3092\:89e3\:6c7a\:30fb\:4ee3\:5165\:3059\:308b\:3002\n" <>
  "\:4f8b: <|\"$ClaudeModel\" -> {\"claudecode\",\"code-heavy\"}, ...|>";

SourceVaultAssignClaudeModels::usage =
  "SourceVaultAssignClaudeModels[opts] \:306f intent \:30de\:30c3\:30d4\:30f3\:30b0 (SourceVault) \:3068\:4fe1\:983c\:30ed\:30fc\:30ab\:30eb\:30b5\:30fc\:30d0\n" <>
  "(NBAccess`NBResolveLocalServer) \:304b\:3089 $ClaudeModel / $ClaudeDocModel / $ClaudePrivateModel /\n" <>
  "$ClaudeFallbackModels \:3092\:8a2d\:5b9a\:3059\:308b\:3002SourceVault \:30ed\:30fc\:30c9\:6642\:306b\:81ea\:52d5\:5b9f\:884c\:3055\:308c\:308b\:3002\n" <>
  "\:30ed\:30fc\:30ab\:30eb\:30b5\:30fc\:30d0\:306e IP/URL \:306f NBAccess \:304c\:5b89\:5168\:306b\:89e3\:6c7a (\:672a\:77e5\:30b5\:30d6\:30cd\:30c3\:30c8\:306f localhost \:306e\:307f)\:3001\n" <>
  "\:30e2\:30c7\:30eb\:540d\:306f ClaudeResolveModel \:306e intent \:89e3\:6c7a\:306b\:3088\:308b\:3002\:30aa\:30d7\:30b7\:30e7\:30f3: Verbose (\:65e2\:5b9a False)\:3002";

SourceVaultRefreshModelRegistry::usage =
  "SourceVaultRefreshModelRegistry[opts] \:306f\:30af\:30e9\:30a6\:30c9 (anthropic/openai) \:3068\:30ed\:30fc\:30ab\:30eb (LM Studio) \:306e\:30a8\:30f3\:30c9\:30dd\:30a4\:30f3\:30c8\:304b\:3089\:30e2\:30c7\:30eb\:4e00\:89a7\:3092\:53d6\:5f97\:3057\:3001compiled model registry \:3092\:66f4\:65b0\:3059\:308b\:3002\n\:30af\:30e9\:30a6\:30c9\:306e API \:30ad\:30fc\:306f NBAccess`NBGetAPIKey \:7d4c\:7531\:3067\:53d6\:5f97\:3057\:3001\:30ad\:30fc\:304c\:7121\:3044 provider \:306f\:30b9\:30ad\:30c3\:30d7\:3059\:308b\:3002\n\:53d6\:5f97\:3057\:305f\:30a8\:30f3\:30c8\:30ea\:306f Source -> \"auto-fetch\" \:3067\:30de\:30fc\:30af\:3057\:3001\:65e2\:5b58\:306e seed/manual \:30a8\:30f3\:30c8\:30ea\:306f\:6e29\:5b58\:3057\:3066\:30de\:30fc\:30b8\:3059\:308b\:3002\n\:30aa\:30d7\:30b7\:30e7\:30f3: Providers (\:65e2\:5b9a All) / IncludeCloud (\:65e2\:5b9a Automatic) / DryRun (\:65e2\:5b9a False)\:3002\nregistry \:30a8\:30f3\:30c8\:30ea\:306f {Provider, ModelId, Endpoint, Class, Availability, Source} \:5f62\:5f0f\:3002\n\:623b\:308a\:5024: <|\"Status\" -> _, \"FetchedCount\" -> _, \"RegistryTotal\" -> _, \"PerProvider\" -> _, \"RegistryPath\" -> _|>\:3002";

SourceVaultNotebookUUID::usage =
  "SourceVaultNotebookUUID[path] \:306f notebook \:306b\:57cb\:3081\:8fbc\:307e\:308c\:305f UUID (TaggingRules > SourceVault > NotebookUUID) \:3092\:8fd4\:3059\:3002\n\:672a\:8a2d\:5b9a\:306a\:3089 Missing[]\:3002\:8aad\:307f\:53d6\:308a\:306e\:307f (\:30d5\:30a1\:30a4\:30eb\:306f\:66f8\:304d\:63db\:3048\:306a\:3044)\:3002";

SourceVaultEnsureNotebookUUID::usage =
  "SourceVaultEnsureNotebookUUID[path, opts] \:306f notebook \:306b UUID \:304c\:7121\:3051\:308c\:3070\:751f\:6210\:3057\:3066\:57cb\:3081\:8fbc\:3080\:3002\nUUID \:306f notebook \:81ea\:8eab\:306e TaggingRules \:306b\:4fdd\:5b58\:3055\:308c\:3001\:30d5\:30a1\:30a4\:30eb\:540d\:5909\:66f4\:30fb\:5185\:5bb9\:7de8\:96c6\:3092\:307e\:305f\:3044\:3067\:5b89\:5b9a\:3059\:308b (SourceVaultRelinkSources \:306e\:6700\:3082\:4fe1\:983c\:3067\:304d\:308b\:7167\:5408\:30ad\:30fc)\:3002\n\:30aa\:30d7\:30b7\:30e7\:30f3: Force (\:65e2\:5b9a False\:3001True \:3067\:65e2\:5b58 UUID \:3082\:518d\:751f\:6210)\:3002\n\:623b\:308a\:5024: <|\"Status\" -> _, \"Path\" -> _, \"UUID\" -> _, \"Created\" -> True|False|>\:3002";

SourceVaultEnsureNotebookUUIDFolder::usage =
  "SourceVaultEnsureNotebookUUIDFolder[dir, opts] \:306f folder \:914d\:4e0b\:306e .nb \:5168\:3066\:306b UUID \:3092\:4ed8\:4e0e\:3059\:308b\:3002\n\:30aa\:30d7\:30b7\:30e7\:30f3: Recursive (\:65e2\:5b9a True) / ExcludePatterns / MaxFileSizeMB (\:65e2\:5b9a\:306f $SourceVaultMaxFileSizeMB)\:3002\n\:623b\:308a\:5024: <|\"Status\" -> _, \"TotalFiles\" -> _, \"Created\" -> _, \"AlreadyPresent\" -> _, \"Skipped\" -> _ (\:5de8\:5927\:30d5\:30a1\:30a4\:30eb\:7b49), \"Failed\" -> _|>\:3002";



(* ::Subsection:: *)
(* Private implementation *)


(* ===================================================================
   Phase 2a: DirectiveRepository source kind
   (Codex integration spec 5th review, sections 11.1 / 11.2)
   Registers and snapshots a Claude Directives repository as a
   SourceVault source. Depends on ClaudeDirectives` but does not add
   it to BeginPackage (no new hard dependency); each function loads
   it lazily via Needs.
   =================================================================== *)

SourceVaultRegisterDirectiveRepository::usage =
  "SourceVaultRegisterDirectiveRepository[root] registers a Claude Directives repository (a directory) as a DirectiveRepository source. Returns <|\"Status\", \"RepoId\", \"Root\", \"Path\", \"Registration\"|>. The RepoId is derived deterministically from the repository root path.";

SourceVaultIndexDirectiveRepository::usage =
  "SourceVaultIndexDirectiveRepository[root] indexes a Claude Directives repository: it computes the file inventory and manifest hash via ClaudeDirectives` and writes a DirectiveRepository snapshot record. Auto-registers the repository if needed. Returns <|\"Status\", \"RepoId\", \"SnapshotId\", \"ManifestHash\", \"FileCount\", \"Path\", \"Snapshot\"|>.";

SourceVaultDirectiveRepositoryStatus::usage =
  "SourceVaultDirectiveRepositoryStatus[root] reports whether a Claude Directives repository is registered, how many snapshots exist, and whether the latest snapshot's manifest hash matches the repository on disk. Status is one of \"NotRegistered\", \"RegisteredNotIndexed\", \"UpToDate\", \"Stale\".";

SourceVaultCurrentDirectiveSnapshot::usage =
  "SourceVaultCurrentDirectiveSnapshot[root] returns the most recent DirectiveRepository snapshot record for a repository, or an association with Status -> \"NoSnapshot\" if none exists.";

SourceVaultDiffDirectiveSnapshots::usage =
  "SourceVaultDiffDirectiveSnapshots[old, new] compares two DirectiveRepository snapshot records (or snapshot file paths) by RelativePath/ContentHash and returns <|\"Status\", \"Added\", \"Removed\", \"Changed\", \"UnchangedCount\", \"ManifestHashChanged\"|>.";


(* ===================================================================
   Phase 2b: HarnessMaterialization bundle kind + stale judgement
   (Codex integration spec 5th review, sections 11.3 / 11.4)
   Registers a materialized harness as a SourceVault bundle and
   separates canonical-snapshot staleness from runtime-environment
   change. Depends on ClaudeDirectives` (lazy Needs only).
   =================================================================== *)

SourceVaultRegisterHarnessMaterialization::usage =
  "SourceVaultRegisterHarnessMaterialization[target, files, meta] registers a materialized harness as a HarnessMaterialization bundle. target is \"Codex\" or \"ClaudeCLI\"; files is the list of generated file paths; meta supplies HarnessMode, DirectiveRoot, DirectiveRepositorySnapshotId, DirectiveRepositoryManifestHash, RuntimeEnvironmentHash, PermissionProfileHash and Generator. Returns <|\"Status\", \"BundleId\", \"Path\", \"Bundle\"|>. The bundle is stored under the SourceVault bundles directory and is readable with SourceVaultBundleGet.";

SourceVaultDirectiveSnapshotStaleQ::usage =
  "SourceVaultDirectiveSnapshotStaleQ[bundle] reports whether the canonical Claude Directives snapshot a HarnessMaterialization bundle was built from is stale, by comparing the bundle's DirectiveRepositoryManifestHash with the current repository hash. Returns <|\"Stale\", \"Reason\", \"RecordedManifestHash\", \"CurrentManifestHash\"|>. A stale snapshot means the harness should be regenerated.";

SourceVaultHarnessRuntimeEnvironmentChangedQ::usage =
  "SourceVaultHarnessRuntimeEnvironmentChangedQ[bundle, currentEnv] reports whether the runtime environment (permission profile, temp project path, attachments) of a HarnessMaterialization bundle has changed. currentEnv may carry precomputed PermissionProfileHash / RuntimeEnvironmentHash, or raw PermissionProfile / RuntimeEnvironment associations to be hashed. A runtime-environment change requires config.toml regeneration but does NOT make the canonical snapshot stale.";

Begin["`Private`"];

(* iL: $Language-based JA/EN switch *)
iL[ja_String, en_String] := If[$Language === "Japanese", ja, en];

(* ClearAll \:30ea\:30b9\:30c8 \[LongDash] \:5916\:90e8\:304b\:3089 Private \:8a08\:7b97\:53c2\:7167\:3055\:308c\:308b\:5168\:5185\:90e8\:95a2\:6570\:3001
   \:307e\:305f\:30ea\:30ed\:30fc\:30c9\:6642\:306b\:53e4\:5b9a\:7fa9\:304c\:6b8b\:3089\:306a\:3044\:3088\:3046 ClearAll \:3059\:308b *)
ClearAll[
  iL,
  iSVStandardFont,
  iSVParseModelVersion, iSVInferModelIntentClass, iSVCompareVersions,
  iSVVersionSortKey, iSVAssignIntentsToFetched,
  iSVNormalizeRegistryTopic,
  iSVMirrorAnthropicToClaudecode, iSVResolveIntentToTuple,
  iSVModelIntentMapPath, iSVSaveModelIntentMap, iSVLoadModelIntentMap,
  iSVValidIntentSpec,
  iLog, iWarn, iVerbose,
  iReadStringSymbol, iCwd, iPackageDir,
  iResolveDropboxRoot, iResolveRoots, iEnsureRoots, iEnsureDir,
  iComputeSHA256, iComputeFileSHA256, iHexHash,
  iSourceTypeOf, iParseSourceRef, iNormalizeSourceRef,
  iMakeSourceId, iMakeSnapshotId,
  iRawDir, iMetaDir, iParsedDir, iAttachmentsDir, iCompiledDir,
  iRawPathOf, iSourceMetaPathOf, iSnapshotMetaPathOf,
  iTransactionalCopy, iTransactionalWrite,
  iLockTryAcquire, iLockRelease, iWithLock,
  iLoadJSON, iSaveJSON, iLoadJSONFromFile,
  iSourceMetaLoad, iSourceMetaSave, iSnapshotMetaLoad, iSnapshotMetaSave,
  iAuthorize, iAuthorizeIngest, iAuthorizeContext, iAuthorizeMaterialize,
  iNBAccessLoaded, iCallNBAuthorize,
  iIngestLocalFile, iIngestURL, iIngestArXiv,
  iCanonicalizeURL, iAutoTrustLevel, iFetchURL, iIngestURLAsync,
  iSeedLookupModel, iCompiledLookupModel, iCompiledRegistryPath,
  iCompiledLoadModelRegistry, iCompiledSaveModelRegistry,
  iExtractTextPages, iCachePageText, iPageTextCachePath,
  iLoadCachedPageText, iPageHashesPath, iSavePageHashes, iLoadPageHashes,
  iExtractSinglePageWithCache, iIsPDFLikelyScanned,
  iRasterizePagePDF, iRasterizePagePDF$PyMuPDF, iRasterizePagePDF$Native,
  iOCRTmpDir, iDefaultOCRPrompt,
  iOCRViaClaudeVision, iOCRViaTextRecognize,
  iClaimsDir, iClaimsMasterPath, iClaimsByTopicPath, iClaimsBySourcePath,
  iClaimsAppendJSONL, iClaimsLoadJSONL, iSanitizeForJSON,
  iLoadClaimHashesForSource, iClaimsBackupAll, iClaimsRewriteAll,
  iClaimsAtomicWrite,
  iBundlesDir, iBundlePath, iMakeBundleId, iBundleSave, iBundleLoad,
  iBundleComputeStatus,
  iSourceEventsPath, iAppendSourceEvent, iLoadSourceEvents,
  iComputePageHashDiff, iUpdateSnapshotLifecycle, iMakeEventId,
  iSeedsDir, iCompiledDir, iSeedPath, iCompiledPath,
  iLoadRegistryEntries, iSaveRegistryEntries, iRecAssoc, RuleQ,
  iRegistryEntryMatchesQuery, iRegistryResolveOrder,
  iBootstrapDefaultSeeds, iModelSeedEntries,
  iNotebooksDir, iNotebookSourcePath, iNotebookSnapshotPath,
  iNotebookTodosByNotebookPath, iNotebookTodosOpenPath, iNotebookTodosDonePath,
  iNotebookReviewOverduePath, iNotebookLintPath,
  iNotebookSummaryPath, iLoadNotebookSummaryRecord, iSaveNotebookSummaryRecord,
  iComputeNotebookSummaryStatus,
  iBuildNotebookSummaryPrompt, iCallSummaryLLM, iExtractFirstCellTexts,
  iSVCellConfidentialTag,
  iSVLooksLikeLLMError,
  iSVResolveTodoTarget, iSVCheckMTimeCache,
  iNotebookRefFromPath, iReadNotebookExpr, iCellTextExtract,
  iFlattenCells, iFlattenCellRec, iCellIsInitializationInputQ,
  iNotebookHeaderParse, iNotebookHeaderParseFromInitialization,
  iNotebookHeaderParseFromBoxes, iNotebookHeaderParseFromStatusCell,
  iSVResolveRelativeDate, iAllowedHeaderValueQ,
  iSVDateInputString, iSVStringToBoxes,
  iExtractTodoCells, iExtractTodoCellsFromPath, iCellOptionsAssociation, iStrikeThroughQ,
  iColorIsGrayQ, iColorIsGreenQ, iCellFontColor,
  iTodoStatusFromOptions, iComputeReviewState, iComputeDeadlineState,
  iComputeNotebookLint, iNotebookRecordMatchesQuery,
  iMakeClaimId, iSchemaRegistry, iRegisterDefaultSchemas,
  iBuildExtractionPrompt, iCallExtractorLLM, iParseExtractionJSON,
  iExtractFirstJSONBlock, iRecoverPartialJSONArray,
  iNormalizeClaim, iValidateClaim, iComputeClaimHash,
  iNormalizeRefSourceOld,
  iCellGetRefSources, iCellGetSourceVaultRefs, iCellSetSourceVaultRefs,
  iSpecFromSnapshotMeta, iSpecFromSourceMeta, iSpecFromClaim,
  iIsoNow, iRandomTmpName, iTrimChars,
  iJoinTextPages, iAccessLabelForSource, iSinkSpecNormalize, iSinkToNBString,
  (* Step 3: Upcoming schedule *)
  iSVResolveScope, iSVUpcomingMatches, iSVEnsureSummary, iSVSummaryShort,
  iSVKeywordsCell, iSVSummaryCell, iSVTitleTipBody,
  iSVScheduleSummaryCell, iSVPublishableCell,
  iSVFormatScheduleDataset, iSVScheduleNormalRecords,
  iSVScheduleFilterFieldType, iSVScheduleFilterCanonicalField,
  iSVScheduleFilterOpWhitelist, iSVScheduleFilterEvalField,
  iSVScheduleFilterEval, iSVApplyScheduleFilterSpec,
  iSVPeriodToDays, iCallSummaryLLMWithFallback,
  iSVAskCloudFallback, iSVResolveReviewDate,
  (* Step 3 Hotfix 3: styled dataset *)
  iSVStyledDate, iSVTitleButton, iSVDirButton, iSVStatusFromRecord,
  iSVRowFromRecord, $iSVScheduleCache, iSVMTimeOf, iSVEnsureSummaryInline,
  iSVCleanTitle, $iSVIndexCache, iSVGetCachedRecords, $iSVLastCacheStats,
  (* Step 5: cross-PC path normalization *)
  iSVCloudRootValue, iSVSymbolicPath, iSVResolvePath, iSVSymbolicPathString,
  iSVRelinkSources, iSVValidateSummarySchema, iSVSnapshotPrivacyLevel,
  iSVLightRecord, iSVMaxFileSizeMB,
  iSVSnapshotKindOf, iSVTitleButtonSym, iSVDirButtonSym,
  iSVSyncDir, iSVSyncHistoryPath, iSVSyncLastPath, iSVMakeSyncId,
  iSVFreshnessToken, iSVSnapshotInfoForSource,
  iSVSourceDescriptorFromPath, iSVCheckSourceFreshness,
  iSVRelinkDir, iSVRelinkLogPath, iSVContentHashOf, iSVHeaderUUIDOf,
  iSVProbeEndpoint, iSVFetchModelIds, iSVFetchCodexModelIds,
  iSVParseModelVersion, iSVInferModelIntentClass, iSVCompareVersions,
  iSVAssignIntentsToFetched, iSVVersionSortKey, iSVMirrorAnthropicToClaudecode,
  iSVMergeModelRegistry,
  iSVNormalizeRegistryTopic,
  iSVResolveLocalKey, iSVPrivateModelTuple, iSVResolveLocalEndpoint,
  iSVPathSlash, iSVPathMatchKey, iSVRootMatchCands,
  iIngestEnsureNotebookUUID
];

(* \:6a19\:6e96\:30d5\:30a9\:30f3\:30c8 (2026-05-31 \:8ffd\:52a0)\:3002
   \:91cd\:8981: \:3053\:306e\:5b9a\:7fa9\:306f\:5fc5\:305a\:4e0a\:306e ClearAll[...] \:30d6\:30ed\:30c3\:30af\:306e\:5f8c\:308d\:306b\:7f6e\:304f\:3053\:3068\:3002
   ClearAll \:30ea\:30b9\:30c8\:306b iSVStandardFont \:304c\:542b\:307e\:308c\:308b\:305f\:3081\:3001\:5b9a\:7fa9\:3092 ClearAll \:3088\:308a
   \:524d\:306b\:7f6e\:304f\:3068 ClearAll \:304c\:5b9a\:7fa9\:3092\:6d88\:53bb\:3057\:3001iSVStandardFont[] \:304c\:672a\:5b9a\:7fa9\:306b\:306a\:308b\:3002
   (\:305d\:308c\:304c\:300c\:95a2\:6570\:304c\:8a55\:4fa1\:3055\:308c\:305a\:5165\:529b\:304c\:305d\:306e\:307e\:307e\:8fd4\:308b\:300d\:539f\:56e0\:3060\:3063\:305f\:3002)
   ClaudeCode`$ClaudeStandardFont \:304c\:5b9a\:7fa9\:6e08\:306a\:3089\:305d\:306e\:5024\:3092\:3001\:672a\:30ed\:30fc\:30c9\:30fb
   \:672a\:5b9a\:7fa9\:30fb\:975e\:6587\:5b57\:5217\:306a\:3089 "Yu Gothic UI" \:3092\:8fd4\:3059\:3002 *)
iSVStandardFont[] :=
  Module[{val},
    val = Quiet[ToExpression["ClaudeCode`$ClaudeStandardFont"]];
    If[StringQ[val] && StringLength[val] > 0, val, "Yu Gothic UI"]
  ];
iSVStandardFont[___] := "Yu Gothic UI";

(* ============================================================
   0. \:30ed\:30b0\:51fa\:529b\:30e6\:30fc\:30c6\:30a3\:30ea\:30c6\:30a3
   ============================================================ *)

If[!BooleanQ[SourceVault`$SourceVaultVerbose],
  SourceVault`$SourceVaultVerbose = False];

iVerbose[args___] :=
  If[TrueQ[SourceVault`$SourceVaultVerbose],
    Print["[SourceVault] ", args]];

iWarn[args___] :=
  Message[SourceVault::warning, StringJoin[ToString /@ {args}]];
SourceVault::warning = "SourceVault warning: `1`";
SourceVault::error   = "SourceVault error: `1`";
SourceVault::nbaccess =
  "SourceVault requires NBAccess`NBAuthorize to be defined. NBAccess might not be loaded.";
SourceVault::denied =
  "SourceVault: NBAuthorize denied the operation. ReasonClass=`1`";
SourceVault::nopath =
  "SourceVault: path resolution failed: `1`";

iLog[evt_String, payload_Association] :=
  Module[{logFile, line, merged},
    Quiet[
      logFile = FileNameJoin[{$SourceVaultRoots["PrivateVault"], "logs", "events.jsonl"}];
      iEnsureDir[DirectoryName[logFile]];
      (* Append \:306f 2 \:5f15\:6570\:3057\:304b\:53d6\:3089\:306a\:3044\:306e\:3067 Join \:3092\:4f7f\:3046\:3002
         RawJSON Export \:304c $Failed \:306b\:306a\:308c\:3070\:30ed\:30b0\:3092\:65ad\:5ff5\:3057\:3066 noop \:3002 *)
      merged = Join[payload, <|"Event" -> evt, "At" -> iIsoNow[]|>];
      line = ExportString[merged, "RawJSON", "Compact" -> True];
      If[StringQ[line] && line =!= "" && line =!= "$Failed",
        With[{s = OpenAppend[logFile, CharacterEncoding -> "UTF-8"]},
          If[s =!= $Failed, WriteString[s, line, "\n"]; Close[s]]]]
    ];
  ];

iIsoNow[] := DateString[Now, {"ISODateTime", "Z"}];


(* ============================================================
   1. \:7269\:7406 root \:89e3\:6c7a (PrivateVault / CloudMirror / Tmp / AttachmentMirror)
   ============================================================ *)

(* \[FilledSquare] Symbol value resolution without creating new symbols \[FilledSquare]
   `Global\`$ClaudeWorkingDirectory` \:306e\:3088\:3046\:306b\:6587\:5b57\:5217\:30ea\:30c6\:30e9\:30eb\:3067
   \:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:4ed8\:304d\:30b7\:30f3\:30dc\:30eb\:3092\:66f8\:304f\:3068\:3001
   \:65e2\:5b58\:30b7\:30f3\:30dc\:30eb\:3068 shdw \:8b66\:544a\:3092\:8d77\:3053\:3057\:3046\:308b\:3002
   \:3053\:306e helper \:306f Names[] \:7d4c\:7531\:3067\:6587\:5b57\:5217\:540d\:3092\:691c\:7d22\:3057\:3001
   \:65e2\:5b58\:30b7\:30f3\:30dc\:30eb\:306e\:307f\:3092\:6271\:3046\:3002\:65b0\:898f\:30b7\:30f3\:30dc\:30eb\:3092\:4f5c\:3089\:306a\:3044\:3002 *)
iReadStringSymbol[name_String] :=
  Module[{candidates, sorted, val, ranked, direct},
    (* \:307e\:305a Global\` \:3092\:76f4\:63a5\:53c2\:7167 ($ \:4ed8\:304d\:30b7\:30f3\:30dc\:30eb\:3067 Names \:30d1\:30bf\:30fc\:30f3\:304c
       \:53d6\:308a\:3053\:307c\:3059\:30b1\:30fc\:30b9\:3078\:306e\:5bfe\:7b56\:3002\:6210\:529f\:3057\:305f\:3089\:5373\:8fd4\:3059) *)
    direct = Quiet @ Symbol["Global`" <> name];
    If[StringQ[direct] && direct =!= "", Return[direct]];
    candidates = Quiet[Names["*`" <> name]];
    If[!ListQ[candidates] || Length[candidates] === 0, Return[Null]];
    (* \:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:512a\:5148\:5ea6: ClaudeCode\` > Global\` > \:305d\:306e\:4ed6 *)
    ranked = Function[c,
      Which[
        StringStartsQ[c, "ClaudeCode`"], 1,
        StringStartsQ[c, "Global`"], 2,
        True, 3]];
    sorted = SortBy[candidates, ranked];
    val = Quiet[ToExpression[First[sorted]]];
    If[StringQ[val] && val =!= "", val, Null]
  ];

iCwd[] := iReadStringSymbol["$ClaudeWorkingDirectory"];
(* iPackageDir: $packageDirectory \:306f\:901a\:5e38 Global\` \:6587\:8108\:306b\:3042\:308b\:3002
   iReadStringSymbol \:306e Names["*`$packageDirectory"] \:30d1\:30bf\:30fc\:30f3\:306f\:30b7\:30f3\:30dc\:30eb\:540d\:306b
   "$" \:3092\:542b\:3080\:5834\:5408\:306b\:30de\:30c3\:30c1\:3057\:306a\:3044\:3053\:3068\:304c\:3042\:308a (TemplateNotFound \:306e\:539f\:56e0)\:3001
   Symbol["Global`$packageDirectory"] \:306e\:76f4\:63a5\:53c2\:7167\:3092\:7b2c\:4e00\:9078\:629e\:3068\:3059\:308b\:3002
   \:898b\:3064\:304b\:3089\:306a\:3051\:308c\:3070\:5f93\:6765\:306e iReadStringSymbol \:306b fallback\:3002 *)
iPackageDir[] :=
  Module[{direct},
    direct = Quiet @ Symbol["Global`$packageDirectory"];
    If[StringQ[direct] && direct =!= "", Return[direct]];
    iReadStringSymbol["$packageDirectory"]
  ];

(* Dropbox root \:3092\:53d6\:5f97\:3002Imai \:74b0\:5883: F:\Dropbox \:307e\:305f\:306f $HomeDirectory\Dropbox *)
iResolveDropboxRoot[] :=
  Module[{candidates, ok},
    candidates = {
      "F:\\Dropbox",
      "F:/Dropbox",
      FileNameJoin[{$HomeDirectory, "Dropbox"}],
      If[StringQ[Environment["USERPROFILE"]],
        FileNameJoin[{Environment["USERPROFILE"], "Dropbox"}], Nothing],
      If[StringQ[Environment["HOME"]],
        FileNameJoin[{Environment["HOME"], "Dropbox"}], Nothing]
    };
    candidates = DeleteCases[candidates, Nothing | "" | Null];
    ok = SelectFirst[candidates, DirectoryQ, $Failed];
    ok
  ];

iResolveRoots[] :=
  Module[{dropboxRoot, privateRoot, cloudRoot, tmpRoot, attachmentRoot,
          localStateRoot, cwd, pkgDir},
    cwd = iCwd[];
    pkgDir = iPackageDir[];
    
    (* CloudMirror / Tmp \:306f $ClaudeWorkingDirectory \:914d\:4e0b *)
    cloudRoot = If[StringQ[cwd],
      FileNameJoin[{cwd, "sourcevault-public"}],
      FileNameJoin[{$TemporaryDirectory, "sourcevault-public"}]];
    
    tmpRoot = If[StringQ[cwd],
      FileNameJoin[{cwd, "tmp"}],
      $TemporaryDirectory];
    
    (* AttachmentMirror = $packageDirectory/claude_attachments (\:65e7 ClaudeAttach \:4e92\:63db) *)
    attachmentRoot = If[StringQ[pkgDir],
      FileNameJoin[{pkgDir, "claude_attachments"}],
      FileNameJoin[{cloudRoot, "claude_attachments"}]];
    
    (* PrivateVault: Dropbox \:914d\:4e0b\:3092\:512a\:5148\:3001\:5931\:6557\:6642\:306f $ClaudeWorkingDirectory/sourcevault *)
    dropboxRoot = iResolveDropboxRoot[];
    privateRoot = Which[
      StringQ[dropboxRoot] && DirectoryQ[dropboxRoot],
        FileNameJoin[{dropboxRoot, "udb", "sourcevault"}],
      StringQ[cwd],
        FileNameJoin[{cwd, "sourcevault"}],
      True,
        FileNameJoin[{$TemporaryDirectory, "sourcevault"}]
    ];
    
    (* LocalState: Dropbox 非同期の hot state 用 root (spec v6 §3.6)。
       %LOCALAPPDATA% (Windows) 等。明示変更は SourceVaultSetRoot が上書きする。 *)
    localStateRoot = Which[
      $OperatingSystem === "Windows",
        With[{la = Environment["LOCALAPPDATA"]},
          If[StringQ[la] && StringLength[la] > 0,
            FileNameJoin[{la, "SourceVault"}],
            FileNameJoin[{$HomeDirectory, "AppData", "Local", "SourceVault"}]]],
      $OperatingSystem === "MacOSX",
        FileNameJoin[{$HomeDirectory, "Library", "Application Support", "SourceVault"}],
      True,
        FileNameJoin[{$HomeDirectory, ".local", "state", "sourcevault"}]
    ];

    <|
      "PrivateVault"     -> privateRoot,
      "CloudMirror"      -> cloudRoot,
      "Tmp"              -> tmpRoot,
      "AttachmentMirror" -> attachmentRoot,
      "ExternalOwned"    -> Automatic,
      "LocalState"       -> localStateRoot
    |>
  ];

(* \:30ed\:30fc\:30c9\:6642\:306b $SourceVaultRoots \:3092\:521d\:671f\:5316 (\:65e2\:5b58\:5024\:306f\:5c0a\:91cd) *)
If[!AssociationQ[SourceVault`$SourceVaultRoots],
  SourceVault`$SourceVaultRoots = iResolveRoots[]];

iEnsureDir[dir_String] :=
  If[!DirectoryQ[dir], Quiet[CreateDirectory[dir, CreateIntermediateDirectories -> True]]];

iRawDir[]         := FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "raw", "by-hash"}];
iMetaDir[]        := FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "raw", "meta"}];
iParsedDir[]      := FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "parsed"}];
iAttachmentsDir[] := FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "attachments"}];
iCompiledDir[]    := FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "compiled", "public"}];

iEnsureRoots[] :=
  Module[{},
    Scan[iEnsureDir, {
      SourceVault`$SourceVaultRoots["PrivateVault"],
      SourceVault`$SourceVaultRoots["Tmp"],
      iRawDir[], iMetaDir[],
      FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "logs"}],
      FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "locks"}],
      FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "seeds"}],
      iCompiledDir[],
      iAttachmentsDir[],
      iParsedDir[]
    }];
    (* CloudMirror / AttachmentMirror \:306f optional\:3002 *)
    iEnsureDir[SourceVault`$SourceVaultRoots["CloudMirror"]];
    iEnsureDir[SourceVault`$SourceVaultRoots["AttachmentMirror"]];
    True
  ];

Options[SourceVaultInitialize] = {"Roots" -> Automatic, "Force" -> False};

SourceVaultInitialize[OptionsPattern[]] :=
  Module[{newRoots, force},
    newRoots = OptionValue["Roots"];
    force    = TrueQ[OptionValue["Force"]];
    If[AssociationQ[newRoots],
      SourceVault`$SourceVaultRoots = Join[SourceVault`$SourceVaultRoots, newRoots]];
    If[!iEnsureRoots[],
      Return[<|"Status" -> "Failed", "Reason" -> "EnsureRoots failed"|>]];
    iLog["Initialize", <|"Roots" -> SourceVault`$SourceVaultRoots|>];
    <|"Status" -> "Initialized", "Roots" -> SourceVault`$SourceVaultRoots|>
  ];


(* ============================================================
   2. Hash / ID \:751f\:6210
   ============================================================ *)

(* SHA256 \:306e 16 \:9032 64 \:6841\:6587\:5b57\:5217 *)
iHexHash[bytes_] :=
  StringPadLeft[IntegerString[Hash[bytes, "SHA256"], 16], 64, "0"];

iComputeSHA256[bytes_ByteArray] := iHexHash[bytes];
iComputeSHA256[s_String]        := iHexHash[StringToByteArray[s, "UTF-8"]];

iComputeFileSHA256[path_String] :=
  If[!FileExistsQ[path], $Failed,
    iHexHash[File[path]]];

iMakeSourceId[parts___] :=
  "src-" <> StringJoin[Riffle[ToString /@ {parts}, "-"]];

iMakeSnapshotId[hash_String] := "snap-sha256-" <> hash;


(* ============================================================
   3. SourceRef parsing / normalization
   ============================================================ *)

iSourceTypeOf[ref_String] :=
  Module[{lower},
    lower = ToLowerCase[ref];
    Which[
      StringStartsQ[lower, "arxiv:"],                "ArXiv",
      StringStartsQ[lower, "http://"]
        || StringStartsQ[lower, "https://"],         "URL",
      StringStartsQ[lower, "attached:"],             "Attachment",
      StringStartsQ[lower, "maildb:"],               "MailDB",
      StringStartsQ[lower, "local:"],                "LocalFile",
      StringStartsQ[lower, "snap-"]
        || StringStartsQ[lower, "src-"],             "Internal",
      Quiet[FileExistsQ[ref]] === True,              "LocalFile",
      True,                                          "Unknown"
    ]
  ];

iParseSourceRef[ref_String] :=
  Module[{tp, ident},
    tp = iSourceTypeOf[ref];
    ident = Switch[tp,
      "ArXiv",      StringDrop[ref, 6],
      "Attachment", StringDrop[ref, 9],
      "MailDB",     StringDrop[ref, 7],
      "LocalFile",  If[StringStartsQ[ToLowerCase[ref], "local:"],
        StringDrop[ref, 6], ref],
      _, ref];
    <|"Type" -> tp, "Identifier" -> ident, "Raw" -> ref|>
  ];

iNormalizeSourceRef[ref_String] := ExpandFileName[ref];
iNormalizeSourceRef[ref_Association] := ref;
iNormalizeSourceRef[other_] := ToString[other];


(* ============================================================
   4. Transactional write / lock
   ============================================================ *)

iRandomTmpName[ext_String] :=
  "sv-tmp-" <> IntegerString[RandomInteger[10^15], 16] <> "-" <>
  IntegerString[$ProcessID] <> ext;

iTransactionalCopy[srcFile_String, destFile_String] :=
  Module[{tmpDir, tmpFile, ext, copied, renamed},
    If[!FileExistsQ[srcFile], Return[$Failed]];
    tmpDir = FileNameJoin[{SourceVault`$SourceVaultRoots["Tmp"], "sourcevault"}];
    iEnsureDir[tmpDir];
    ext = If[FileExtension[srcFile] === "", "", "." <> FileExtension[srcFile]];
    tmpFile = FileNameJoin[{tmpDir, iRandomTmpName[ext]}];
    
    iEnsureDir[DirectoryName[destFile]];
    
    copied = Quiet[CopyFile[srcFile, tmpFile, OverwriteTarget -> True]];
    If[copied === $Failed,
      Return[$Failed]];
    
    If[FileExistsQ[destFile],
      (* \:65e2\:306b\:5b58\:5728: \:540c\:4e00 hash \:306e\:306f\:305a\:3002tmp \:3092\:6368\:3066\:3066 destFile \:3092\:8fd4\:3059 *)
      Quiet[DeleteFile[tmpFile]];
      Return[destFile]];
    
    renamed = Quiet[RenameFile[tmpFile, destFile]];
    If[renamed === $Failed,
      (* \:7af6\:5408\:3057\:305f\:53ef\:80fd\:6027\:3002CopyFile \:3057\:3066 tmp \:524a\:9664 \:3092\:8a66\:3059 *)
      Quiet[CopyFile[tmpFile, destFile, OverwriteTarget -> False]];
      Quiet[DeleteFile[tmpFile]]];
    destFile
  ];

iTransactionalWrite[destFile_String, content_String] :=
  Module[{tmpDir, tmpFile, ext, s, renamed},
    tmpDir = FileNameJoin[{SourceVault`$SourceVaultRoots["Tmp"], "sourcevault"}];
    iEnsureDir[tmpDir];
    ext = If[FileExtension[destFile] === "", ".tmp", "." <> FileExtension[destFile]];
    tmpFile = FileNameJoin[{tmpDir, iRandomTmpName[ext]}];
    iEnsureDir[DirectoryName[destFile]];
    s = Quiet[OpenWrite[tmpFile, CharacterEncoding -> "UTF-8"]];
    If[s === $Failed, Return[$Failed]];
    WriteString[s, content];
    Close[s];
    renamed = Quiet[RenameFile[tmpFile, destFile, OverwriteTarget -> True]];
    If[renamed === $Failed,
      Quiet[CopyFile[tmpFile, destFile, OverwriteTarget -> True]];
      Quiet[DeleteFile[tmpFile]]];
    destFile
  ];

(* Advisory lock: \:30d5\:30a1\:30a4\:30eb\:5b58\:5728\:30c1\:30a7\:30c3\:30af + PID/timestamp\:3002OS-level atomicity \:3067\:306f\:306a\:3044\:3082\:306e\:306e
   PoC \:30ec\:30d9\:30eb\:3067\:306f\:5341\:5206\:3002 *)
iLockTryAcquire[lockId_String] :=
  Module[{lockFile, content, s, ok},
    lockFile = FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"],
      "locks", lockId <> ".lock"}];
    iEnsureDir[DirectoryName[lockFile]];
    If[FileExistsQ[lockFile],
      (* \:53e4\:3044 lock \:306f\:30b9\:30c8\:30fc\:30eb\:3068\:307f\:306a\:3057 \:5fc5\:8981\:306a\:3089\:30ea\:30af\:30a8\:30b9\:30c8\:5074\:3067\:4e0a\:66f8\:304d *)
      Return[<|"Acquired" -> False, "Path" -> lockFile|>]];
    content = ExportString[<|
      "PID" -> $ProcessID,
      "At" -> iIsoNow[]
    |>, "RawJSON", "Compact" -> True];
    s = Quiet[OpenWrite[lockFile, CharacterEncoding -> "UTF-8"]];
    If[s === $Failed, Return[<|"Acquired" -> False, "Path" -> lockFile|>]];
    WriteString[s, content];
    Close[s];
    <|"Acquired" -> True, "Path" -> lockFile|>
  ];

iLockRelease[lockInfo_Association] :=
  If[FileExistsQ[lockInfo["Path"]],
    Quiet[DeleteFile[lockInfo["Path"]]]];

SetAttributes[iWithLock, HoldRest];
iWithLock[lockId_String, body_] :=
  Module[{lockInfo, result},
    lockInfo = iLockTryAcquire[lockId];
    If[!TrueQ[lockInfo["Acquired"]],
      Return[<|"Status" -> "LockBusy", "LockId" -> lockId|>]];
    result = body;
    iLockRelease[lockInfo];
    result
  ];


(* ============================================================
   5. JSON load / save (\:30e1\:30bf\:30c7\:30fc\:30bf)
   ============================================================ *)

(* ExportString[..., "RawJSON"] は UTF-8 バイト列の Latin-1 表現を返すため、
   そのまま UTF-8 指定の iTransactionalWrite に渡すと非 ASCII が二重エンコード
   になる (rule 30)。ExportByteArray -> ByteArrayToString で本物の文字列に
   戻してから一度だけ UTF-8 で書く。 *)
iSaveJSON[file_String, data_] :=
  Module[{str},
    str = Quiet @ Check[
      ByteArrayToString[
        ExportByteArray[data, "RawJSON", "Compact" -> False], "UTF-8"],
      $Failed];
    If[!StringQ[str],
      str = ExportString[data, "RawJSON", "Compact" -> False]];
    If[!StringQ[str], Return[$Failed]];
    iTransactionalWrite[file, str]
  ];

iLoadJSON[file_String] :=
  If[!FileExistsQ[file], Missing["NoFile"],
    iLoadJSONFromFile[file]];

(* UTF-8 \:5b89\:5168\:306a JSON \:30d5\:30a1\:30a4\:30eb\:8aad\:307f\:8fbc\:307f (Stage 9 P1 Step 4 utf8fix v2)
   - Import[path, "RawJSON"] \:306f Windows \:7b49\:3067 OS \:30c7\:30d5\:30a9\:30eb\:30c8 encoding \:3092\:4f7f\:3046\:5834\:5408\:304c\:3042\:308a\:3001
     UTF-8 \:3067\:66f8\:3044\:305f\:30d5\:30a1\:30a4\:30eb\:304c\:5316\:3051\:308b\:3053\:3068\:304c\:3042\:308b\:3002
   - ReadByteArray \:3067 byte \:306b\:3066\:8aad\:307f\:3001ByteArrayToString[..., "UTF-8"] \:3067\:660e\:793a\:7684\:306b decode \:3057\:3001
     ImportString[str, "RawJSON"] \:3067 parse \:3059\:308b\:3002\:3053\:308c\:306f Imai \:5148\:751f\:304c
     SourceVaultFindNotebooks (L5973) \:3067\:65e2\:306b\:78ba\:7acb\:3057\:3066\:3044\:308b\:30d1\:30bf\:30fc\:30f3\:3002
   - utf8fix v3: Developer`ReadRawJSONString \:304b\:3089 ImportString[\"RawJSON\"] \:3078\:5909\:66f4 (\:660e\:793a\:7684\:306b documented API)\:3002 *)
iLoadJSONFromFile[path_String] :=
  Module[{rawBytes, str, data, dataJSON},
    If[!FileExistsQ[path], Return[Null]];
    rawBytes = Quiet @ ReadByteArray[path];
    If[!ByteArrayQ[rawBytes], Return[Null]];
    (* 第 0 選択: バイト列を直接 parse。非 ASCII を含む本物の文字列を
       ImportString["RawJSON"] に渡すと jsonoutofrangeunicode で失敗するため
       (rule 30)、UTF-8 ファイルはこの経路が最も確実。 *)
    data = Quiet @ ImportByteArray[rawBytes, "RawJSON"];
    If[AssociationQ[data] || ListQ[data], Return[data]];
    str = Quiet @ ByteArrayToString[rawBytes, "UTF-8"];
    If[!StringQ[str], Return[Null]];
    (* \:7b2c\:4e00\:9078\:629e: ImportString[..., \"RawJSON\"] *)
    data = Quiet @ ImportString[str, "RawJSON"];
    If[AssociationQ[data] || ListQ[data], Return[data]];
    (* \:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af 1: Developer\`ReadRawJSONString (\:7c21\:6f54\:306a\:30d1\:30fc\:30b5\:30fc) *)
    data = Quiet @ Developer`ReadRawJSONString[str];
    If[AssociationQ[data] || ListQ[data], Return[data]];
    (* \:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af 2: ImportString[..., \"JSON\"] (\:65e7\:30d1\:30fc\:30b5\:30fc) *)
    dataJSON = Quiet @ ImportString[str, "JSON"];
    Which[
      AssociationQ[dataJSON] || ListQ[dataJSON], dataJSON,
      (* JSON \:30d1\:30fc\:30b5\:30fc\:306f Rule \:306e List \:3092\:8fd4\:3057\:5f97\:308b *)
      MatchQ[dataJSON, {(_Rule | _RuleDelayed) ..}],
        Association @@ dataJSON,
      True, Null]
  ];


(* ============================================================
   6. Source / Snapshot \:30e1\:30bf\:4fdd\:5b58
   ============================================================ *)

iRawPathOf[hash_String, ext_String] :=
  FileNameJoin[{iRawDir[], "sha256-" <> hash <>
    If[ext === "" || ext === Null, "", "." <> ext]}];

iSourceMetaPathOf[sourceId_String] :=
  FileNameJoin[{iMetaDir[],
    If[StringStartsQ[sourceId, "src-"], sourceId, "src-" <> sourceId] <> ".json"}];

iSnapshotMetaPathOf[snapshotId_String] :=
  FileNameJoin[{iMetaDir[],
    If[StringStartsQ[snapshotId, "snap-"], snapshotId, "snap-" <> snapshotId] <> ".json"}];

iSourceMetaLoad[sourceId_String] := iLoadJSON[iSourceMetaPathOf[sourceId]];
iSourceMetaSave[sourceId_String, data_Association] :=
  iSaveJSON[iSourceMetaPathOf[sourceId], data];

iSnapshotMetaLoad[snapshotId_String] := iLoadJSON[iSnapshotMetaPathOf[snapshotId]];
iSnapshotMetaSave[snapshotId_String, data_Association] :=
  iSaveJSON[iSnapshotMetaPathOf[snapshotId], data];


(* ============================================================
   7. NBAccess \:7d50\:5408 (NBAuthorize \:5fc5\:9808)
   ============================================================ *)

iNBAccessLoaded[] :=
  And[
    StringQ[Quiet[Context[]]] || True,
    Quiet[ValueQ[NBAccess`NBAuthorize]] === True
      || MatchQ[Quiet[DownValues[NBAccess`NBAuthorize]], {___, _ :> _}]
  ];

iCallNBAuthorize[obj_Association, req_Association] :=
  Module[{result},
    If[!iNBAccessLoaded[],
      Message[SourceVault::nbaccess];
      (* \:5fc5\:9808\:524d\:63d0\:306e policy \:3067\:306f\:3001NBAccess \:672a\:30ed\:30fc\:30c9\:306f Deny \:3068\:3059\:308b\:3079\:304d *)
      Return[<|
        "Decision" -> "Deny",
        "ReasonClass" -> "NBAccessNotLoaded",
        "VisibleExplanation" -> "NBAccess`NBAuthorize is not available"
      |>]];
    result = Quiet[NBAccess`NBAuthorize[obj, req]];
    If[!AssociationQ[result] || !KeyExistsQ[result, "Decision"],
      Return[<|
        "Decision" -> "Deny",
        "ReasonClass" -> "NBAuthorizeReturnedInvalid",
        "RawResult" -> result
      |>]];
    result
  ];

(* AccessLabel-equivalent association for NBAuthorize input.
   Stage 0-3 \:3067\:306f scalar (PrivacyLevel / AccessLevel) + 4 \:9805\:30e9\:30d9\:30eb\:3092\:8907\:5408\:3067\:6e21\:3059\:3002
   \:5b8c\:5168\:306a label algebra \:306f Stage 5+ \:3067\:62e1\:5f35 *)
iAccessLabelForSource[sourceInfo_Association] :=
  Module[{tp, trust, privacy, conf, origin},
    tp = Lookup[sourceInfo, "SourceType", "Unknown"];
    trust = Lookup[sourceInfo, "TrustLevel", Automatic];
    privacy = Lookup[sourceInfo, "PrivacyLevel", Automatic];
    
    {conf, origin, privacy} = Switch[tp,
      "ArXiv",      {"Public",  "ArXiv",         If[NumericQ[privacy], privacy, 0.0]},
      "URL",        {"Public",  "PublicWeb",     If[NumericQ[privacy], privacy, 0.0]},
      "LocalFile",  {"Private", "LocalFile",     If[NumericQ[privacy], privacy, 0.8]},
      "Attachment", {"Private", "UserAttached",  If[NumericQ[privacy], privacy, 0.8]},
      "MailDB",     {"Private", "UserMailbox",   If[NumericQ[privacy], privacy, 1.0]},
      _,            {"Private", "Unknown",       If[NumericQ[privacy], privacy, 0.5]}
    ];
    
    <|
      "Confidentiality" -> conf,
      "Origin" -> origin,
      "Integrity" -> Switch[tp,
        "ArXiv", "SnapshotPinned",
        "LocalFile", "UserPrivateSource",
        "Attachment", "UserAuthored",
        _, "Unknown"],
      "Retention" -> Switch[tp,
        "ArXiv", "CacheOK",
        _, "NoPersistUnlessApproved"],
      "PrivacyLevel" -> privacy,
      "AccessLevel"  -> privacy,
      "Owner" -> If[conf === "Public", "Public", "User"]
    |>
  ];

(* SourceVaultObjectSpec[ref]: NBAuthorize \:5165\:529b\:3068\:306a\:308b object association *)
SourceVaultObjectSpec[snapshotId_String] :=
  Module[{meta},
    meta = iSnapshotMetaLoad[snapshotId];
    If[!AssociationQ[meta], Return[<|"AccessLevel" -> 0.5, "SourceId" -> snapshotId|>]];
    iSpecFromSnapshotMeta[meta]
  ];

SourceVaultObjectSpec[sourceInfo_Association] :=
  iSpecFromSourceMeta[sourceInfo];

iSpecFromSnapshotMeta[meta_Association] :=
  Module[{label},
    label = iAccessLabelForSource[meta];
    <|
      "ObjectClass" -> "Snapshot",
      "SnapshotId"  -> meta["SnapshotId"],
      "SourceId"    -> Lookup[meta, "SourceId", Missing[]],
      "AccessLabel" -> label,
      "AccessLevel" -> label["AccessLevel"],
      "PrivacyLevel" -> label["PrivacyLevel"],
      "Confidentiality" -> label["Confidentiality"],
      "Origin" -> label["Origin"],
      "ContentHash" -> Lookup[meta, "ContentHash", Missing[]]
    |>
  ];

iSpecFromSourceMeta[info_Association] :=
  Module[{label},
    label = iAccessLabelForSource[info];
    <|
      "ObjectClass" -> Lookup[info, "ObjectClass", "Source"],
      "SourceId"   -> Lookup[info, "SourceId", Missing[]],
      "SourceType" -> Lookup[info, "SourceType", "Unknown"],
      "AccessLabel" -> label,
      "AccessLevel" -> label["AccessLevel"],
      "PrivacyLevel" -> label["PrivacyLevel"],
      "Confidentiality" -> label["Confidentiality"],
      "Origin" -> label["Origin"]
    |>
  ];

(* Stage 6d: claim Association \:304b\:3089 NBClaimSpec equivalent \:3092\:751f\:6210 (\:4ed5\:69d8\:66f8 \[Section] 14.2.3) *)
iSpecFromClaim[claim_Association] :=
  Module[{sourceSpan, sourceId, snapshotId, snapshotMeta, label},
    sourceSpan = Lookup[claim, "SourceSpan", <||>];
    sourceId = Lookup[sourceSpan, "SourceId", ""];
    snapshotId = Lookup[sourceSpan, "SnapshotId", ""];
    (* AccessLabel \:306f\:5143 source \:306e\:30e9\:30d9\:30eb\:3092\:7d99\:627f\:3057\:3066\:751f\:6210 *)
    label = If[StringQ[snapshotId] && snapshotId =!= "",
      Module[{m},
        m = iSnapshotMetaLoad[snapshotId];
        If[AssociationQ[m],
          iAccessLabelForSource[m],
          iAccessLabelForSource[<|"SourceType" -> "Unknown"|>]]],
      iAccessLabelForSource[<|"SourceType" -> "Unknown"|>]];
    <|
      "ObjectClass" -> "Claim",
      "ClaimId" -> Lookup[claim, "ClaimId", ""],
      "Topic" -> Lookup[claim, "Topic", ""],
      "Schema" -> Lookup[claim, "Schema", ""],
      "SourceId" -> sourceId,
      "SnapshotId" -> snapshotId,
      "ContentHash" -> Lookup[claim, "ContentHash", ""],
      "AccessLabel" -> label,
      "AccessLevel" -> label["AccessLevel"],
      "PrivacyLevel" -> label["PrivacyLevel"],
      "Confidentiality" -> label["Confidentiality"],
      "Origin" -> "Extracted"
    |>
  ];

iSinkSpecNormalize[sink_] :=
  Which[
    AssociationQ[sink], sink,
    sink === None || sink === Automatic,
      <|"Kind" -> "LocalKernel", "Route" -> "PrivateLLM"|>,
    StringQ[sink],
      <|"Kind" -> sink|>,
    True,
      <|"Kind" -> "Unknown"|>
  ];

(* \[FilledSquare] NBAccess \:306e Sink \:6587\:5b57\:5217\:8a17\:9001 \[FilledSquare]
   NBEnvironmentGate \:306f sink \:3092\:6587\:5b57\:5217\:3068\:3057\:3066 MemberQ \:6bd4\:8f03\:3059\:308b\:305f\:3081\:3001
   \:30e6\:30fc\:30b6\:30fc\:5074\:3067 Association \:3092\:6e21\:3057\:3066\:3082\:5168 Deny\:306b\:306a\:308b\:3002
   \:3053\:306e helper \:306f Association/String \:30c9\:30e1\:30a4\:30f3\:3092
   NBAccess \:304c\:8a8d\:3081\:308b 4 \:7a2e\:6587\:5b57\:5217\:306b\:7d0d\:3081\:308b\:3002
   \:8a8d\:3081\:308b sink: "CloudLLM" | "PrivateLLM" | "LocalOnly" | "Notebook" *)
iSinkToNBString[sink_Association] :=
  Module[{kind, route},
    kind = Lookup[sink, "Kind", Missing[]];
    route = Lookup[sink, "Route", Missing[]];
    Which[
      (* \:660e\:793a\:7684\:306b NBAccess sink \:540d\:3092\:6307\:5b9a\:3057\:3066\:3044\:308c\:3070\:305d\:308c\:3092\:4f7f\:3046 *)
      MemberQ[{"CloudLLM", "PrivateLLM", "LocalOnly", "Notebook"}, kind], kind,
      MemberQ[{"CloudLLM", "PrivateLLM", "LocalOnly", "Notebook"}, route], route,
      (* Kind \:5225\:540d *)
      kind === "LocalStorage" || kind === "LocalKernel" || kind === "Vault", "LocalOnly",
      kind === "CloudAPI" || kind === "Cloud", "CloudLLM",
      kind === "Private" || kind === "LocalLLM", "PrivateLLM",
      kind === "NotebookCell", "Notebook",
      (* Route \:5225\:540d *)
      route === "LocalLLM", "PrivateLLM",
      route === "Cloud", "CloudLLM",
      (* default *) True, "PrivateLLM"
    ]
  ];
iSinkToNBString[sink_String] :=
  If[MemberQ[{"CloudLLM", "PrivateLLM", "LocalOnly", "Notebook"}, sink],
    sink,
    Switch[sink,
      (* \:5b9f LLM \:306b\:6e21\:3055\:306a\:3044 (vault\:5185\:30d5\:30a1\:30a4\:30eb\:64cd\:4f5c\:306e\:307f) *)
      "LocalKernel" | "LocalStorage" | "Vault" | "Local", "LocalOnly",
      (* \:30ed\:30fc\:30ab\:30eb LLM \:63a8\:8ad6 (LM Studio etc.) *)
      "LocalLLM" | "Private", "PrivateLLM",
      (* \:30af\:30e9\:30a6\:30c9 LLM (Claude API / OpenAI etc.) *)
      "Cloud" | "CloudAPI", "CloudLLM",
      (* \:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:30bb\:30eb\:8868\:793a\:306e\:307f *)
      "NotebookCell" | "Cell" | "Display", "Notebook",
      _, "PrivateLLM"]
  ];
iSinkToNBString[_] := "PrivateLLM";

(* Authorize wrappers \[LongDash] \:5168\:3066 NBAccess \:306e\:6587\:5b57\:5217 sink \:898f\:683c\:306b\:5408\:308f\:305b\:308b *)
iAuthorizeIngest[sourceInfo_Association, opts_:{}] :=
  iCallNBAuthorize[
    iSpecFromSourceMeta[sourceInfo],
    <|
      "Action" -> "Ingest",
      "TargetTier" -> "PrivateVault",
      (* Ingest \:306f file \[RightArrow] PrivateVault \:30b3\:30d4\:30fc\:306e\:307f\:3001LLM \:306b\:306f\:6e21\:3055\:306a\:3044\:3002LocalOnly \:304c\:9069\:5207 *)
      "Sink" -> "LocalOnly"
    |>
  ];

iAuthorizeContext[obj_Association, sink_, purpose_String] :=
  iCallNBAuthorize[
    obj,
    <|
      "Action" -> "ReadContext",
      "Purpose" -> purpose,
      "Sink" -> iSinkToNBString[sink]
    |>
  ];

iAuthorizeMaterialize[obj_Association, sinkSpec_] :=
  iCallNBAuthorize[
    obj,
    <|
      "Action" -> "MaterializeForSink",
      "TargetTier" -> "CloudMirror",
      "TargetRoot" -> SourceVault`$SourceVaultRoots["CloudMirror"],
      "Sink" -> iSinkToNBString[sinkSpec]
    |>
  ];


(* ============================================================
   8. Stage 1: Seed model registry + Resolve / Lookup
   ============================================================ *)

(* Seed model registry: bootstrap fallback only.
   \:5b9f\:5b9f\:7269\:306e production registry \:306f compiled/public/model-registry.wl \:306b\:3042\:308b\:3079\:304d *)
If[!ListQ[SourceVault`$SourceVaultSeedModelRegistry],
  SourceVault`$SourceVaultSeedModelRegistry = {
    <|"Provider" -> "anthropic", "Intent" -> "heavy",
      "ModelId" -> "claude-opus-4-8", "Class" -> "Heavy-Cloud",
      "Availability" -> "Available", "Source" -> "seed"|>,
    <|"Provider" -> "anthropic", "Intent" -> "math-extraction-heavy",
      "ModelId" -> "claude-opus-4-8", "Class" -> "Heavy-Cloud",
      "Availability" -> "Available", "Source" -> "seed"|>,
    <|"Provider" -> "anthropic", "Intent" -> "code-heavy",
      "ModelId" -> "claude-opus-4-8", "Class" -> "Heavy-Cloud",
      "Availability" -> "Available", "Source" -> "seed"|>,
    <|"Provider" -> "anthropic", "Intent" -> "sonnet",
      "ModelId" -> "claude-sonnet-4-6", "Class" -> "Mid-Cloud",
      "Availability" -> "Available", "Source" -> "seed"|>,
    <|"Provider" -> "anthropic", "Intent" -> "haiku",
      "ModelId" -> "claude-haiku-4-5-20251001", "Class" -> "Fast-Cloud",
      "Availability" -> "Available", "Source" -> "seed"|>,
    <|"Provider" -> "openai", "Intent" -> "heavy",
      "ModelId" -> "gpt-5.5", "Class" -> "Heavy-Cloud",
      "Availability" -> "Unknown", "Source" -> "seed"|>,
    <|"Provider" -> "lmstudio", "Intent" -> "local-confidential",
      "ModelId" -> "qwen-32b", "Class" -> "Local",
      "Availability" -> "Available", "Source" -> "seed"|>
  }];

iCompiledRegistryPath[] :=
  FileNameJoin[{iCompiledDir[], "model-registry.wl"}];

iCompiledLoadModelRegistry[] :=
  Module[{path, result},
    path = iCompiledRegistryPath[];
    If[!FileExistsQ[path], Return[Missing["NoCompiled"]]];
    result = Quiet[Get[path]];
    If[ListQ[result], result, Missing["InvalidCompiled"]]
  ];

iCompiledSaveModelRegistry[entries_List] :=
  Module[{path, content},
    path = iCompiledRegistryPath[];
    iEnsureDir[DirectoryName[path]];
    content = "(* Auto-generated by SourceVault. Do not edit by hand. *)\n" <>
      "(* CompiledAt: " <> iIsoNow[] <> " *)\n" <>
      ToString[entries, InputForm] <> "\n";
    iTransactionalWrite[path, content];
    path
  ];

(* registry \:691c\:7d22\:306e\:4e3b\:4f53 *)
iCompiledLookupModel[provider_String, intent_String] :=
  Module[{compiled, src, hit},
    compiled = iCompiledLoadModelRegistry[];
    src = If[ListQ[compiled], compiled,
      SourceVault`$SourceVaultSeedModelRegistry];
    hit = SelectFirst[src,
      Function[entry,
        Lookup[entry, "Provider", ""] === provider &&
        Lookup[entry, "Intent", ""] === intent],
      Missing["NoMatch"]];
    hit
  ];

iSeedLookupModel[provider_String, intent_String] :=
  SelectFirst[SourceVault`$SourceVaultSeedModelRegistry,
    Lookup[#, "Provider", ""] === provider &&
    Lookup[#, "Intent", ""] === intent &,
    Missing["NoSeedMatch"]];

(* SourceVaultResolve / SourceVaultLookup / ClaudeResolveModel \:306e\:5b9f\:88c5\:306f
   Stage 6b (file-based compiled registry) \:306b\:5b8c\:5168\:7d71\:5408\:3055\:308c\:305f\:3002
   \:65e7 Stage 1 in-memory \:5b9a\:7fa9\:306f\:524a\:9664\:6e08\:307f\:3002
   $SourceVaultSeedModelRegistry / iCompiledLookupModel / iSeedLookupModel \:306f
   \:5f8c\:65b9\:4e92\:63db\:306e\:305f\:3081\:306b helper \:3068\:3057\:3066\:306e\:307f\:6b8b\:3059\:3002 *)


(* ============================================================
   9. Stage 1.5 / 2: SourceVaultIngest
   ============================================================ *)

Options[SourceVaultIngest] = {
  Topic         -> Automatic,
  TrustLevel    -> Automatic,
  PrivacyLabel  -> Automatic,
  PinVersion    -> Automatic,
  "Asynchronous"-> False,
  "EnsureUUID"  -> Automatic
};

SourceVaultIngest[source_String, opts:OptionsPattern[]] :=
  Module[{tp, parsed},
    iEnsureRoots[];
    parsed = iParseSourceRef[source];
    tp = parsed["Type"];
    Switch[tp,
      "LocalFile", iIngestLocalFile[parsed["Identifier"], opts],
      "ArXiv",     iIngestArXiv[parsed["Identifier"], opts],
      "URL",       iIngestURL[parsed["Identifier"], opts],
      _,
        <|"Status" -> "Failed",
          "Reason" -> "UnsupportedSourceType: " <> tp,
          "SourceRef" -> source|>
    ]
  ];

(* SourceVaultIngest \:6642\:306e Notebook UUID \:81ea\:52d5\:4ed8\:4e0e\:30d8\:30eb\:30d1\:30fc\:3002
   ensureOpt: True \:306a\:3089\:5e38\:306b\:4ed8\:4e0e\:3001False \:306a\:3089\:4ed8\:4e0e\:305b\:305a\:3001Automatic \:306f .nb \:306e\:3068\:304d\:306e\:307f\:4ed8\:4e0e\:3002
   .nb \:4ee5\:5916\:30fb\:5de8\:5927\:30d5\:30a1\:30a4\:30eb\:30fbensureOpt False \:306e\:3068\:304d\:306f\:4ed8\:4e0e\:3057\:306a\:3044\:3002
   UUID \:57cb\:3081\:8fbc\:307f\:306f\:5185\:5bb9\:3092\:5909\:3048\:308b (TaggingRules \:8ffd\:52a0) \:305f\:3081\:3001\:547c\:3073\:51fa\:3057\:5074\:306f hash \:8a08\:7b97\:306e\:524d\:306b\:547c\:3076\:3002
   \:4ed8\:4e0e\:306b\:5931\:6557\:3057\:3066\:3082 ingest \:81ea\:4f53\:306f\:7d9a\:884c\:3067\:304d\:308b\:3088\:3046\:3001\:4f8b\:5916\:306f\:63e1\:308a\:3064\:3076\:3057\:7d50\:679c\:3092 Association \:3067\:8fd4\:3059\:3002
   \:623b\:308a\:5024: <|"Attempted" -> _, "UUID" -> _, "Created" -> _, "Reason" -> _|>\:3002 *)
iIngestEnsureNotebookUUID[expanded_String, ensureOpt_] :=
  Module[{ext, sizeMB, r},
    If[ensureOpt === False,
      Return[<|"Attempted" -> False, "Reason" -> "Disabled"|>]];
    ext = ToLowerCase[FileExtension[expanded]];
    If[ext =!= "nb",
      Return[<|"Attempted" -> False, "Reason" -> "NotNotebook"|>]];
    (* ensureOpt \:306f True \:307e\:305f\:306f Automatic\:3002.nb \:306a\:306e\:3067\:3044\:305a\:308c\:3082\:4ed8\:4e0e\:5bfe\:8c61\:3002 *)
    sizeMB = Quiet @ Check[FileByteCount[expanded] / 1024.^2, 0];
    If[NumericQ[sizeMB] && sizeMB > iSVMaxFileSizeMB[],
      Return[<|"Attempted" -> False, "Reason" -> "FileTooLarge",
        "SizeMB" -> Round[sizeMB]|>]];
    r = Quiet @ Check[SourceVaultEnsureNotebookUUID[expanded], $Failed];
    If[!AssociationQ[r] || Lookup[r, "Status", ""] =!= "OK",
      Return[<|"Attempted" -> True, "Reason" -> "EnsureFailed"|>]];
    <|"Attempted" -> True,
      "UUID" -> Lookup[r, "UUID", Missing[]],
      "Created" -> TrueQ[Lookup[r, "Created", False]],
      "Reason" -> "OK"|>
  ];

iIngestLocalFile[file_String, opts:OptionsPattern[SourceVaultIngest]] :=
  Module[{expanded, hash, ext, rawPath, sourceId, snapshotId,
          decision, byteCount, contentType, trustLevel, privacy, topicVal,
          existingSnap, sourceMeta, snapshotMeta, lockInfo, ingestResult,
          uuidEnsure},
    expanded = ExpandFileName[file];
    If[!FileExistsQ[expanded] || DirectoryQ[expanded],
      Return[<|"Status" -> "Failed",
        "Reason" -> "FileNotFound",
        "Path" -> expanded|>]];
    
    trustLevel = OptionValue[SourceVaultIngest, {opts}, TrustLevel];
    If[trustLevel === Automatic, trustLevel = "LocalFile"];
    privacy = OptionValue[SourceVaultIngest, {opts}, PrivacyLabel];
    If[privacy === Automatic, privacy = 0.8];
    
    (* Topic: Automatic \[Rule] Null (JSON \:5b89\:5168) *)
    topicVal = OptionValue[SourceVaultIngest, {opts}, Topic];
    If[topicVal === Automatic, topicVal = Null];
    
    (* 1. NBAuthorize *)
    decision = iAuthorizeIngest[<|
      "SourceType" -> "LocalFile",
      "OriginalPath" -> expanded,
      "TrustLevel" -> trustLevel,
      "PrivacyLevel" -> privacy
    |>];
    If[decision["Decision"] === "Deny",
      Message[SourceVault::denied, decision["ReasonClass"]];
      Return[<|"Status" -> "DeniedByNBAccess",
        "ReasonClass" -> decision["ReasonClass"],
        "Decision" -> decision|>]];
    
    (* 1.5. Notebook UUID \:81ea\:52d5\:4ed8\:4e0e (.nb \:306e\:307f\:3001hash \:8a08\:7b97\:3088\:308a\:524d)\:3002
       UUID \:57cb\:3081\:8fbc\:307f\:306f\:5185\:5bb9\:3092\:5909\:3048\:308b\:305f\:3081 hash \:8a08\:7b97\:524d\:306b\:884c\:3044\:3001ContentHash \:3092 UUID \:5165\:308a\:3067\:5b89\:5b9a\:3055\:305b\:308b\:3002
       \:3053\:308c\:306b\:3088\:308a\:540c\:3058 .nb \:306e\:518d ingest \:304c\:51aa\:7b49\:306b\:306a\:308b (2 \:56de\:76ee\:306f\:65e2\:5b58 UUID \:4fdd\:6301\:3067\:5185\:5bb9\:4e0d\:5909)\:3002
       NBAuthorize \:3092 Permit \:3057\:305f\:30d5\:30a1\:30a4\:30eb\:306b\:306e\:307f\:4ed8\:4e0e\:3059\:308b (\:3053\:306e\:6642\:70b9\:3067 Deny \:306f\:65e9\:671f return \:6e08\:307f)\:3002 *)
    uuidEnsure = iIngestEnsureNotebookUUID[expanded,
      OptionValue[SourceVaultIngest, {opts}, "EnsureUUID"]];
    
    (* 2. Hash + dedup *)
    hash = iComputeFileSHA256[expanded];
    If[hash === $Failed,
      Return[<|"Status" -> "Failed",
        "Reason" -> "HashComputationFailed",
        "Path" -> expanded|>]];
    
    ext = ToLowerCase[FileExtension[expanded]];
    rawPath = iRawPathOf[hash, ext];
    snapshotId = iMakeSnapshotId[hash];
    sourceId = iMakeSourceId["local", StringTake[hash, UpTo[12]]];
    
    (* concurrent ingest dedup: lock on hash *)
    lockInfo = iLockTryAcquire["ingest-" <> hash];
    
    If[FileExistsQ[rawPath],
      existingSnap = iSnapshotMetaLoad[snapshotId];
      If[AssociationQ[existingSnap],
        (* \:65e2\:5b58: \:30e1\:30bf\:30b5\:30a4\:30c9\:5b8c\:5099 \[RightArrow] AlreadyCurrent \:3067\:65e9\:671f Return *)
        iLockRelease[lockInfo];
        Return[<|
          "Status" -> "AlreadyCurrent",
          "SourceId" -> Lookup[existingSnap, "SourceId", sourceId],
          "SnapshotId" -> snapshotId,
          "ContentHash" -> "sha256-" <> hash,
          "RawPath" -> rawPath,
          "ByteCount" -> Lookup[existingSnap, "ByteCount", Quiet[FileByteCount[expanded]]],
          "Decision" -> decision,
          "UUIDEnsured" -> uuidEnsure
        |>],
        (* file \:306f\:3042\:308b\:304c metadata \:304c\:6b20\:640d \[RightArrow] \:4f5c\:308a\:76f4\:3057 *)
        ingestResult = "NeedsMetadata"],
      (* \:65b0\:898f *)
      ingestResult = "NeedsCopy"
    ];
    
    If[ingestResult === "NeedsCopy",
      (* transactional copy *)
      If[iTransactionalCopy[expanded, rawPath] === $Failed,
        iLockRelease[lockInfo];
        Return[<|"Status" -> "Failed",
          "Reason" -> "CopyFailed",
          "Path" -> expanded|>]];
    ];
    
    (* metadata \:4f5c\:6210 *)
    byteCount = Quiet[FileByteCount[expanded]];
    contentType = Switch[ext,
      "pdf",  "application/pdf",
      "html"|"htm", "text/html",
      "txt"|"md", "text/plain",
      "json", "application/json",
      "wl"|"m"|"nb", "text/x-wolfram",
      _, "application/octet-stream"];
    
    sourceMeta = <|
      "SourceId" -> sourceId,
      "SourceType" -> "LocalFile",
      "CanonicalURI" -> "local:" <> expanded,
      "DisplayName" -> FileNameTake[expanded],
      "Topic" -> topicVal,
      "TrustLevel" -> trustLevel,
      "PrivacyLevel" -> privacy,
      "OriginalPath" -> expanded,
      "Snapshots" -> {snapshotId},
      "CreatedAt" -> iIsoNow[],
      "SourceUUID" -> If[AssociationQ[uuidEnsure],
        Lookup[uuidEnsure, "UUID", Missing[]], Missing[]]
    |>;
    
    snapshotMeta = <|
      "SnapshotId" -> snapshotId,
      "SourceId" -> sourceId,
      "SourceType" -> "LocalFile",
      "OriginalURI" -> "local:" <> expanded,
      "OriginalPath" -> expanded,
      "FetchedAt" -> iIsoNow[],
      "Method" -> "LocalCopy",
      "ContentType" -> contentType,
      "ContentHash" -> "sha256-" <> hash,
      "ByteCount" -> byteCount,
      "Path" -> rawPath,
      "Truncated" -> False,
      "ExtractorReady" -> True,
      "LifecycleStatus" -> "Current",
      "PrivacyLevel" -> privacy,
      "TrustLevel" -> trustLevel,
      "Storage" -> <|
        "AuthoritativeTier" -> "PrivateVault",
        "CanonicalHash" -> "sha256-" <> hash,
        "CanonicalPath" -> rawPath,
        "MirrorPaths" -> {}
      |>
    |>;
    
    iSourceMetaSave[sourceId, sourceMeta];
    iSnapshotMetaSave[snapshotId, snapshotMeta];
    
    iLockRelease[lockInfo];
    
    iLog["Ingest", <|
      "SourceType" -> "LocalFile",
      "SourceId" -> sourceId,
      "SnapshotId" -> snapshotId,
      "ContentHash" -> "sha256-" <> hash,
      "OriginalPath" -> expanded,
      "Decision" -> Lookup[decision, "Decision", "Permit"]
    |>];
    
    <|
      "Status" -> If[ingestResult === "NeedsMetadata",
        "RebuiltMetadata", "Ingested"],
      "SourceId" -> sourceId,
      "SnapshotId" -> snapshotId,
      "ContentHash" -> "sha256-" <> hash,
      "RawPath" -> rawPath,
      "ByteCount" -> byteCount,
      "Decision" -> decision,
      "UUIDEnsured" -> uuidEnsure
    |>
  ];

(* ============================================================
   9.5 Stage 4 Phase 4A: URL ingest helpers
   ============================================================ *)

(* URL canonicalization:
   - arXiv:NNNN.NNNNN          \[Rule] https://arxiv.org/pdf/NNNN.NNNNN.pdf
   - arXiv:NNNN.NNNNNvN        \[Rule] https://arxiv.org/pdf/NNNN.NNNNNvN.pdf
   - https://arxiv.org/abs/...  \[Rule] https://arxiv.org/pdf/....pdf   (PDF \:3092\:512a\:5148)
   - \:305d\:306e\:4ed6 https?://...        \[Rule] \:305d\:306e\:307e\:307e (\:6700\:5c0f\:9650\:306e\:6b63\:898f\:5316\:306e\:307f)
*)
iCanonicalizeURL[ref_String] :=
  Module[{trimmed, lower, body, absPath, pdfPath},
    trimmed = StringTrim[ref];
    lower = ToLowerCase[trimmed];
    Which[
      (* arXiv shorthand *)
      StringStartsQ[lower, "arxiv:"],
        body = StringDrop[trimmed, 6];
        body = StringTrim[body];
        If[body === "",
          Return[<|"Status" -> "Failed", "Reason" -> "EmptyArXivId"|>]];
        <|"Status" -> "OK",
          "URL" -> "https://arxiv.org/pdf/" <> body <> ".pdf",
          "SourceKind" -> "ArXiv",
          "ArXivId" -> body|>,
      
      (* arxiv.org/abs/... \[Rule] arxiv.org/pdf/....pdf *)
      StringMatchQ[lower, "https://arxiv.org/abs/" ~~ __] ||
        StringMatchQ[lower, "http://arxiv.org/abs/" ~~ __],
        absPath = StringReplace[trimmed,
          RegularExpression["^https?://arxiv\\.org/abs/"] -> ""];
        pdfPath = If[StringEndsQ[absPath, ".pdf"],
          absPath,
          absPath <> ".pdf"];
        <|"Status" -> "OK",
          "URL" -> "https://arxiv.org/pdf/" <> pdfPath,
          "SourceKind" -> "ArXiv",
          "ArXivId" -> StringReplace[absPath, ".pdf" ~~ EndOfString -> ""]|>,
      
      (* arxiv.org/pdf/... \[Rule] \:305d\:306e\:307e\:307e\:3060\:304c ArXiv \:3068\:3057\:3066\:6271\:3046 *)
      StringMatchQ[lower, "https://arxiv.org/pdf/" ~~ __] ||
        StringMatchQ[lower, "http://arxiv.org/pdf/" ~~ __],
        Module[{cleaned},
          cleaned = StringReplace[trimmed,
            RegularExpression["^http://"] -> "https://"];
          <|"Status" -> "OK",
            "URL" -> cleaned,
            "SourceKind" -> "ArXiv",
            "ArXivId" -> StringReplace[
              StringReplace[cleaned,
                RegularExpression["^https?://arxiv\\.org/pdf/"] -> ""],
              ".pdf" ~~ EndOfString -> ""]|>
        ],
      
      (* \:4e00\:822c\:7684\:306a HTTPS / HTTP URL *)
      StringStartsQ[lower, "https://"] || StringStartsQ[lower, "http://"],
        <|"Status" -> "OK",
          "URL" -> trimmed,
          "SourceKind" -> "Web",
          "ArXivId" -> Missing["NotApplicable"]|>,
      
      True,
        <|"Status" -> "Failed",
          "Reason" -> "UnrecognizedURLForm: " <> trimmed|>
    ]
  ];

(* TrustLevel \:81ea\:52d5\:63a8\:5b9a *)
iAutoTrustLevel[url_String] :=
  Module[{lower},
    lower = ToLowerCase[url];
    Which[
      (* \:516c\:5f0f API endpoint *)
      StringMatchQ[lower, "https://api.anthropic.com/" ~~ __] ||
        StringMatchQ[lower, "https://api.openai.com/" ~~ __] ||
        StringMatchQ[lower, "https://generativelanguage.googleapis.com/" ~~ __],
        "OfficialAPI",
      
      (* \:516c\:5f0f\:30c9\:30ad\:30e5\:30e1\:30f3\:30c8\:30b5\:30a4\:30c8 *)
      StringMatchQ[lower, "https://docs.anthropic.com/" ~~ __] ||
        StringMatchQ[lower, "https://platform.openai.com/docs/" ~~ __] ||
        StringMatchQ[lower, "https://ai.google.dev/" ~~ __] ||
        StringMatchQ[lower, "https://reference.wolfram.com/" ~~ __] ||
        StringMatchQ[lower, "https://developer.mozilla.org/" ~~ __] ||
        StringMatchQ[lower, "https://arxiv.org/" ~~ __] ||
        StringMatchQ[lower, "https://www.python.org/" ~~ __] ||
        StringMatchQ[lower, "https://docs.python.org/" ~~ __] ||
        StringMatchQ[lower, "https://en.wikipedia.org/" ~~ __],
        "OfficialDocs",
      
      (* \:305d\:306e\:4ed6 HTTPS *)
      StringStartsQ[lower, "https://"], "PublicWeb",
      
      (* HTTP (\:975e SSL) \:306f PublicWeb \:3060\:304c PrivacyLevel \:3092\:4f4e\:3081\:306b\:3057\:305f\:3044 *)
      StringStartsQ[lower, "http://"], "PublicWeb",
      
      True, "PublicWeb"
    ]
  ];

(* HTTP GET: tmp \:30d5\:30a1\:30a4\:30eb\:306b download \:3057\:3001\:7d50\:679c\:30e1\:30bf\:3092\:8fd4\:3059 *)
iFetchURL[url_String, opts_:{}] :=
  Module[{tmpDir, tmpFile, headers, statusCode, contentType, contentLength,
          result, timeoutSec, downloadResult},
    tmpDir = FileNameJoin[{SourceVault`$SourceVaultRoots["Tmp"], "sourcevault", "fetch"}];
    iEnsureDir[tmpDir];
    
    (* tmp \:30d5\:30a1\:30a4\:30eb\:306f\:62e1\:5f35\:5b50\:306a\:3057 (Content-Type \:3092\:898b\:3066\:304b\:3089\:5224\:65ad) *)
    tmpFile = FileNameJoin[{tmpDir, iRandomTmpName[""]}];
    
    timeoutSec = Lookup[Association[opts], "Timeout", 60];
    
    (* URLDownload \:306f redirect \:3092\:81ea\:52d5\:8ffd\:8de1\:3059\:308b *)
    downloadResult = Quiet[
      TimeConstrained[
        URLDownload[url, tmpFile,
          {"Path", "StatusCode", "Headers", "ContentType"}],
        timeoutSec,
        $Failed]
    ];
    
    If[downloadResult === $Failed || !AssociationQ[downloadResult],
      Quiet[DeleteFile[tmpFile]];
      Return[<|
        "Status" -> "Failed",
        "Reason" -> "FetchFailed",
        "URL" -> url,
        "Hint" -> "Network unreachable, timeout, or invalid URL"
      |>]];
    
    statusCode = Lookup[downloadResult, "StatusCode", 0];
    headers = Lookup[downloadResult, "Headers", {}];
    contentType = Lookup[downloadResult, "ContentType", "application/octet-stream"];
    
    If[!IntegerQ[statusCode] || statusCode < 200 || statusCode >= 300,
      Quiet[DeleteFile[tmpFile]];
      Return[<|
        "Status" -> "Failed",
        "Reason" -> "HTTPError",
        "StatusCode" -> statusCode,
        "URL" -> url|>]];
    
    If[!FileExistsQ[tmpFile] || Quiet[FileByteCount[tmpFile]] === 0,
      Quiet[DeleteFile[tmpFile]];
      Return[<|
        "Status" -> "Failed",
        "Reason" -> "EmptyDownload",
        "URL" -> url|>]];
    
    contentLength = Quiet[FileByteCount[tmpFile]];
    
    <|
      "Status" -> "OK",
      "TmpFile" -> tmpFile,
      "StatusCode" -> statusCode,
      "ContentType" -> contentType,
      "ContentLength" -> contentLength,
      "Headers" -> headers,
      "URL" -> url
    |>
  ];


iIngestArXiv[id_String, opts:OptionsPattern[SourceVaultIngest]] :=
  Module[{canonical, url},
    (* arXiv:NNNN.NNNNN \[Rule] https://arxiv.org/pdf/... *)
    canonical = iCanonicalizeURL["arXiv:" <> id];
    If[!AssociationQ[canonical] || canonical["Status"] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> "InvalidArXivId: " <> id,
        "Detail" -> canonical|>]];
    
    url = canonical["URL"];
    
    (* TrustLevel \:306e\:30c7\:30d5\:30a9\:30eb\:30c8\:3092 ArXiv \:6587\:8108\:3067 OfficialDocs \:306b\:8a2d\:5b9a *)
    iIngestURL[url,
      Sequence @@ FilterRules[{opts}, Options[SourceVaultIngest]],
      "ArXivIdHint" -> canonical["ArXivId"]]
  ];

(* URL ingest \:672c\:4f53\:3002Asynchronous -> False \:306e\:307f\:30b5\:30dd\:30fc\:30c8\:3002 *)
iIngestURL[url_String, opts:OptionsPattern[]] :=
  Module[{canonical, canonicalUrl, sourceKind, arXivId, trustLevel, privacy,
          decision, fetchResult, tmpFile, hash, ext, rawPath, snapshotId, sourceId,
          contentType, byteCount, existingSnap, sourceMeta, snapshotMeta,
          lockInfo, ingestResult, asyncReq, displayName, isArXivHint,
          arXivIdHint, baseOpts, topicVal, existingSrcMeta, existingSnapList,
          latestSnapId, latestSnap, urlHashShort},
    iEnsureRoots[];
    
    (* opts \:304b\:3089 SourceVaultIngest \:306e\:6b63\:898f\:30aa\:30d7\:30b7\:30e7\:30f3\:3092\:62bd\:51fa *)
    baseOpts = FilterRules[{opts}, Options[SourceVaultIngest]];
    
    asyncReq = OptionValue[SourceVaultIngest, baseOpts, "Asynchronous"];
    If[TrueQ[asyncReq],
      (* \:30b8\:30e7\:30d6\:7d4c\:7531\:306e\:975e\:540c\:671f ingest *)
      Return[iIngestURLAsync[url, opts]]];
    
    (* arXiv-side hint \:306f opts \:5185\:306b\:5165\:3063\:3066\:3044\:308b\:53ef\:80fd\:6027\:304c\:3042\:308b *)
    arXivIdHint = Lookup[Association[{opts}], "ArXivIdHint", Missing[]];
    
    (* 1. URL canonicalization *)
    canonical = iCanonicalizeURL[url];
    If[!AssociationQ[canonical] || canonical["Status"] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> "URLCanonicalizationFailed",
        "URL" -> url,
        "Detail" -> canonical|>]];
    canonicalUrl = canonical["URL"];
    sourceKind = canonical["SourceKind"];
    arXivId = If[StringQ[arXivIdHint], arXivIdHint, canonical["ArXivId"]];
    isArXivHint = (sourceKind === "ArXiv");
    
    (* 2. TrustLevel \:306e\:81ea\:52d5\:63a8\:5b9a *)
    trustLevel = OptionValue[SourceVaultIngest, baseOpts, TrustLevel];
    If[trustLevel === Automatic,
      trustLevel = iAutoTrustLevel[canonicalUrl]];
    
    privacy = OptionValue[SourceVaultIngest, baseOpts, PrivacyLabel];
    If[privacy === Automatic,
      privacy = Switch[trustLevel,
        "OfficialAPI" | "OfficialDocs", 0.6,
        "PublicWeb", 0.4,
        _, 0.4]];
    
    (* Topic: Automatic \[Rule] Null (JSON \:5b89\:5168) *)
    topicVal = OptionValue[SourceVaultIngest, baseOpts, Topic];
    If[topicVal === Automatic, topicVal = Null];
    
    (* 3. SourceId \:8a08\:7b97 (content hash \:975e\:4f9d\:5b58\:3001URL \:30d9\:30fc\:30b9\:3067\:5b89\:5b9a\:5316)
       \[LongDash] arxiv.org \:7b49\:306f\:540c\:3058 URL \:3092 re-fetch \:3057\:3066\:3082 content bytes \:304c\:6bce\:56de\:5fae\:5999\:306b\:5909\:308f\:308b\:305f\:3081\:3001
         content hash dedup \:3060\:3051\:3067\:306f\:51fa\:308b\:3002URL \:30ec\:30d9\:30eb dedup \:304c\:5fc5\:8981\:3002 *)
    sourceId = If[isArXivHint && StringQ[arXivId],
      iMakeSourceId["arxiv",
        StringReplace[arXivId, RegularExpression["[^A-Za-z0-9._-]"] -> "-"]],
      Module[{urlHash},
        urlHash = iComputeSHA256[canonicalUrl];
        urlHashShort = If[StringQ[urlHash], StringTake[urlHash, UpTo[12]], "unknown"];
        iMakeSourceId["url", urlHashShort]]];
    
    (* 4. NBAuthorize *)
    decision = iAuthorizeIngest[<|
      "SourceType" -> If[isArXivHint, "ArXiv", "URL"],
      "OriginalURL" -> canonicalUrl,
      "TrustLevel" -> trustLevel,
      "PrivacyLevel" -> privacy
    |>];
    If[decision["Decision"] === "Deny",
      Message[SourceVault::denied, decision["ReasonClass"]];
      Return[<|"Status" -> "DeniedByNBAccess",
        "ReasonClass" -> decision["ReasonClass"],
        "Decision" -> decision,
        "URL" -> canonicalUrl|>]];
    
    (* 5. URL \:30ec\:30d9\:30eb dedup: \:540c\:3058 SourceId \:306e\:6700\:65b0 snapshot \:304c Current \:306a\:3089\:8fd4\:3059 *)
    existingSrcMeta = iSourceMetaLoad[sourceId];
    If[AssociationQ[existingSrcMeta] && KeyExistsQ[existingSrcMeta, "Snapshots"],
      existingSnapList = Lookup[existingSrcMeta, "Snapshots", {}];
      If[ListQ[existingSnapList] && Length[existingSnapList] > 0,
        latestSnapId = Last[existingSnapList];
        latestSnap = iSnapshotMetaLoad[latestSnapId];
        If[AssociationQ[latestSnap] &&
           Lookup[latestSnap, "LifecycleStatus", "Current"] === "Current" &&
           FileExistsQ[Lookup[latestSnap, "Path", ""]],
          Return[<|
            "Status" -> "AlreadyCurrent",
            "SourceId" -> sourceId,
            "SnapshotId" -> latestSnapId,
            "ContentHash" -> Lookup[latestSnap, "ContentHash", ""],
            "RawPath" -> Lookup[latestSnap, "Path", ""],
            "ByteCount" -> Lookup[latestSnap, "ByteCount", 0],
            "URL" -> canonicalUrl,
            "TrustLevel" -> Lookup[latestSnap, "TrustLevel", trustLevel],
            "Decision" -> decision
          |>]]]];
    
    (* 6. HTTP GET *)
    fetchResult = iFetchURL[canonicalUrl];
    If[!AssociationQ[fetchResult] || fetchResult["Status"] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[fetchResult, "Reason", "FetchFailed"],
        "URL" -> canonicalUrl,
        "Detail" -> fetchResult|>]];
    
    tmpFile = fetchResult["TmpFile"];
    contentType = fetchResult["ContentType"];
    byteCount = fetchResult["ContentLength"];
    
    (* 7. content hash \:8a08\:7b97 *)
    hash = iComputeFileSHA256[tmpFile];
    If[hash === $Failed,
      Quiet[DeleteFile[tmpFile]];
      Return[<|"Status" -> "Failed",
        "Reason" -> "HashComputationFailed",
        "URL" -> canonicalUrl|>]];
    
    (* 8. \:62e1\:5f35\:5b50\:3092 Content-Type \:3068 URL \:304b\:3089\:63a8\:5b9a *)
    ext = Which[
      StringContainsQ[contentType, "pdf"], "pdf",
      StringContainsQ[contentType, "html"], "html",
      StringContainsQ[contentType, "json"], "json",
      StringContainsQ[contentType, "text/plain"]
        || StringContainsQ[contentType, "text/markdown"], "txt",
      (* fallback: URL \:672b\:5c3e\:304b\:3089 *)
      True,
        Module[{urlExt},
          urlExt = ToLowerCase[FileExtension[canonicalUrl]];
          If[StringQ[urlExt] && urlExt =!= "" &&
             MemberQ[{"pdf", "html", "htm", "json", "txt", "md"}, urlExt],
            If[urlExt === "htm", "html", If[urlExt === "md", "txt", urlExt]],
            "bin"]
        ]];
    
    rawPath = iRawPathOf[hash, ext];
    snapshotId = iMakeSnapshotId[hash];
    
    (* 9. concurrent ingest dedup: lock on hash *)
    lockInfo = iLockTryAcquire["ingest-" <> hash];
    
    If[FileExistsQ[rawPath],
      existingSnap = iSnapshotMetaLoad[snapshotId];
      If[AssociationQ[existingSnap],
        iLockRelease[lockInfo];
        Quiet[DeleteFile[tmpFile]];
        Return[<|
          "Status" -> "AlreadyCurrent",
          "SourceId" -> Lookup[existingSnap, "SourceId", sourceId],
          "SnapshotId" -> snapshotId,
          "ContentHash" -> "sha256-" <> hash,
          "RawPath" -> rawPath,
          "ByteCount" -> Lookup[existingSnap, "ByteCount", byteCount],
          "URL" -> canonicalUrl,
          "Decision" -> decision
        |>],
        ingestResult = "NeedsMetadata"],
      ingestResult = "NeedsCopy"
    ];
    
    (* 10. transactional move (tmp \[Rule] raw/by-hash) *)
    If[ingestResult === "NeedsCopy",
      If[iTransactionalCopy[tmpFile, rawPath] === $Failed,
        iLockRelease[lockInfo];
        Quiet[DeleteFile[tmpFile]];
        Return[<|"Status" -> "Failed",
          "Reason" -> "CopyFailed",
          "URL" -> canonicalUrl|>]];
    ];
    Quiet[DeleteFile[tmpFile]];   (* tmp \:524a\:9664 *)
    
    (* 11. metadata \:4f5c\:6210 (JSON \:5b89\:5168\:5316: Automatic / Missing \:6392\:9664) *)
    displayName = Which[
      isArXivHint && StringQ[arXivId], "arXiv:" <> arXivId,
      True, FileNameTake[canonicalUrl]];
    
    sourceMeta = <|
      "SourceId" -> sourceId,
      "SourceType" -> If[isArXivHint, "ArXiv", "URL"],
      "CanonicalURI" -> If[isArXivHint && StringQ[arXivId],
        "arXiv:" <> arXivId, canonicalUrl],
      "DisplayName" -> displayName,
      "Topic" -> topicVal,
      "TrustLevel" -> trustLevel,
      "PrivacyLevel" -> privacy,
      "OriginalURL" -> canonicalUrl,
      "Snapshots" -> {snapshotId},
      "CreatedAt" -> iIsoNow[]
    |>;
    
    snapshotMeta = <|
      "SnapshotId" -> snapshotId,
      "SourceId" -> sourceId,
      "SourceType" -> If[isArXivHint, "ArXiv", "URL"],
      "OriginalURI" -> canonicalUrl,
      "OriginalURL" -> canonicalUrl,
      "FetchedAt" -> iIsoNow[],
      "Method" -> "URLDownload",
      "ContentType" -> contentType,
      "ContentHash" -> "sha256-" <> hash,
      "ByteCount" -> byteCount,
      "Path" -> rawPath,
      "Truncated" -> False,
      "ExtractorReady" -> (ext =!= "bin"),
      "LifecycleStatus" -> "Current",
      "PrivacyLevel" -> privacy,
      "TrustLevel" -> trustLevel,
      "Storage" -> <|
        "AuthoritativeTier" -> "PrivateVault",
        "CanonicalHash" -> "sha256-" <> hash,
        "CanonicalPath" -> rawPath,
        "MirrorPaths" -> {}
      |>
    |>;
    
    (* ArXivId \:306f\:6761\:4ef6\:4ed8\:304d\:3067\:8ffd\:52a0 (Missing[] \:3092 JSON \:306b\:5165\:308c\:306a\:3044) *)
    If[isArXivHint && StringQ[arXivId],
      snapshotMeta = Append[snapshotMeta, "ArXivId" -> arXivId]];
    
    iSourceMetaSave[sourceId, sourceMeta];
    iSnapshotMetaSave[snapshotId, snapshotMeta];
    
    iLockRelease[lockInfo];
    
    iLog["Ingest", <|
      "SourceType" -> If[isArXivHint, "ArXiv", "URL"],
      "SourceId" -> sourceId,
      "SnapshotId" -> snapshotId,
      "ContentHash" -> "sha256-" <> hash,
      "URL" -> canonicalUrl,
      "Decision" -> Lookup[decision, "Decision", "Permit"]
    |>];
    
    <|
      "Status" -> If[ingestResult === "NeedsMetadata",
        "RebuiltMetadata", "Ingested"],
      "SourceId" -> sourceId,
      "SnapshotId" -> snapshotId,
      "ContentHash" -> "sha256-" <> hash,
      "RawPath" -> rawPath,
      "ByteCount" -> byteCount,
      "URL" -> canonicalUrl,
      "TrustLevel" -> trustLevel,
      "Decision" -> decision
    |>
  ];


(* ============================================================
   9.6 Stage 4 Phase 4A-async: LLMGraphDAG \:7d4c\:7531\:306e\:975e\:540c\:671f URL ingest
   \[LongDash] rules/95-scheduled-task-safety \[Section]C \:6e96\:62e0 (\:72ec\:81ea ScheduledTask \:7981\:6b62)
   ============================================================ *)

(* Asynchronous -> True \:6307\:5b9a\:6642\:306e dispatch \:5148\:3002
   LLMGraphDAGCreate (claudecode.wl \:63d0\:4f9b) \:306b 1 \:30ce\:30fc\:30c9 sync DAG \:3068\:3057\:3066\:6295\:5165\:3002
   handler \:5185\:3067 iIngestURL \:3092 Asynchronous -> False \:3067\:518d\:5165\:3001snapshot \:3092 registry \:306b\:4fdd\:5b58\:3002
   \:30e6\:30fc\:30b6\:306b\:306f JobId + \:4e8b\:524d\:5b89\:5b9a SourceId \:3092\:5373\:6642 return\:3002 *)
iIngestURLAsync[url_String, opts___] :=
  Module[{canonical, canonicalUrl, sourceKind, arXivId, isArXivHint,
          sourceId, urlHash, urlHashShort,
          existingSrcMeta, existingSnapList, latestSnapId, latestSnap,
          jobId, dagHandler, dagCompleteFn, nodeAssoc, dagDescriptor,
          dagCreateFn, dagNodeFn, ingestOpts,
          baseOpts},
    iEnsureRoots[];
    
    (* 1. LLMGraphDAGCreate \:5b58\:5728\:78ba\:8a8d (claudecode.wl \:307e\:305f\:306f Global \:7d4c\:7531) *)
    dagCreateFn = First[
      Select[Names["*`LLMGraphDAGCreate"],
        StringQ[#] && Length[Names[#]] > 0 &],
      None];
    dagNodeFn = First[
      Select[Names["*`iLLMGraphNode"],
        StringQ[#] && Length[Names[#]] > 0 &],
      None];
    If[dagCreateFn === None || dagNodeFn === None,
      Return[<|"Status" -> "Failed",
        "Reason" -> "AsyncRequiresClaudeRuntime",
        "Hint" -> "LLMGraphDAGCreate / iLLMGraphNode not available. " <>
                  "Load claudecode.wl first, or use Asynchronous -> False."|>]];
    
    (* 2. URL canonicalize *)
    canonical = iCanonicalizeURL[url];
    If[!AssociationQ[canonical] || canonical["Status"] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> "URLCanonicalizationFailed",
        "URL" -> url,
        "Detail" -> canonical|>]];
    canonicalUrl = canonical["URL"];
    sourceKind = canonical["SourceKind"];
    arXivId = canonical["ArXivId"];
    isArXivHint = (sourceKind === "ArXiv");
    
    (* 3. SourceId \:4e8b\:524d\:7b97\:51fa (content \:975e\:4f9d\:5b58\:3001URL \:30d9\:30fc\:30b9\:3067\:5b89\:5b9a\:5316) *)
    sourceId = If[isArXivHint && StringQ[arXivId],
      iMakeSourceId["arxiv",
        StringReplace[arXivId, RegularExpression["[^A-Za-z0-9._-]"] -> "-"]],
      Module[{urlHashLocal},
        urlHashLocal = iComputeSHA256[canonicalUrl];
        urlHashShort = If[StringQ[urlHashLocal], StringTake[urlHashLocal, UpTo[12]], "unknown"];
        iMakeSourceId["url", urlHashShort]]];
    
    (* 4. URL \:30ec\:30d9\:30eb dedup (sync \:3068\:540c\:69d8\:3002fetch \:3092\:30b9\:30ad\:30c3\:30d7\:3057\:3066\:5373\:5ea7 AlreadyCurrent return) *)
    existingSrcMeta = iSourceMetaLoad[sourceId];
    If[AssociationQ[existingSrcMeta] && KeyExistsQ[existingSrcMeta, "Snapshots"],
      existingSnapList = Lookup[existingSrcMeta, "Snapshots", {}];
      If[ListQ[existingSnapList] && Length[existingSnapList] > 0,
        latestSnapId = Last[existingSnapList];
        latestSnap = iSnapshotMetaLoad[latestSnapId];
        If[AssociationQ[latestSnap] &&
           Lookup[latestSnap, "LifecycleStatus", "Current"] === "Current" &&
           FileExistsQ[Lookup[latestSnap, "Path", ""]],
          Return[<|
            "Status" -> "AlreadyCurrent",
            "SourceId" -> sourceId,
            "SnapshotId" -> latestSnapId,
            "JobId" -> None,
            "URL" -> canonicalUrl,
            "Note" -> "Async ingest skipped: already current"
          |>]]]];
    
    (* 5. opts \:304b\:3089 SourceVaultIngest \:30aa\:30d7\:30b7\:30e7\:30f3\:3092\:62bd\:51fa\:3001
       Asynchronous \:3092 False \:306b\:5897\:3057\:3066 handler \:5185\:3067\:518d\:5165\:30eb\:30fc\:30d7\:3092\:9632\:3050 *)
    baseOpts = FilterRules[{opts}, Options[SourceVaultIngest]];
    ingestOpts = Append[
      Select[baseOpts, #[[1]] =!= "Asynchronous" &],
      "Asynchronous" -> False];
    
    (* 6. sync handler: handler \:5185\:3067 iIngestURL \:3092\:5b8c\:5168 sync \:3067\:5b9f\:884c\:3002
       LLMGraphDAGCreate \:304c\:30b8\:30e7\:30d6\:30b9\:30b1\:30b8\:30e5\:30fc\:30e9\:7d4c\:7531\:3067\:8d77\:52d5\:3002 *)
    dagHandler = Function[{job},
      Module[{ctx, urlInCtx, optsInCtx, syncResult},
        ctx = Lookup[job, "context", <||>];
        urlInCtx = Lookup[ctx, "URL", ""];
        optsInCtx = Lookup[ctx, "IngestOpts", {}];
        syncResult = SourceVault`Private`iIngestURL[urlInCtx,
          Sequence @@ optsInCtx];
        (* sync API \:3068\:540c\:3058 Association \:3092\:8fd4\:3059 *)
        syncResult]];
    
    dagCompleteFn = Function[{job},
      Module[{nodesOut, fetchOut},
        nodesOut = Lookup[job, "nodes", <||>];
        fetchOut = Lookup[Lookup[nodesOut, "fetch", <||>], "result", <||>];
        SourceVault`Private`iLog["AsyncIngestComplete", <|
          "URL" -> canonicalUrl,
          "SourceId" -> sourceId,
          "ResultStatus" -> Lookup[fetchOut, "Status", "Unknown"],
          "SnapshotId" -> Lookup[fetchOut, "SnapshotId", Missing[]]
        |>]]];
    
    (* 7. DAG \:69cb\:7bc9 *)
    nodeAssoc = <|
      "fetch" -> Symbol[dagNodeFn]["fetch", "sync", "ingest", {}, dagHandler]
    |>;
    
    dagDescriptor = <|
      "name" -> "SourceVault Async Ingest: " <> canonicalUrl,
      "categoryMap" -> <|"ingest" -> "sync"|>
    |>;
    
    (* 8. LLMGraphDAGCreate \:8d77\:52d5 *)
    jobId = Symbol[dagCreateFn][<|
      "nodes" -> nodeAssoc,
      "taskDescriptor" -> dagDescriptor,
      "context" -> <|
        "URL" -> canonicalUrl,
        "IngestOpts" -> ingestOpts,
        "SourceId" -> sourceId
      |>,
      "onComplete" -> dagCompleteFn
    |>];
    
    iLog["IngestQueued", <|
      "URL" -> canonicalUrl,
      "SourceId" -> sourceId,
      "JobId" -> jobId
    |>];
    
    <|
      "Status" -> "Queued",
      "JobId" -> jobId,
      "SourceId" -> sourceId,
      "SnapshotId" -> Missing["Async"],
      "URL" -> canonicalUrl,
      "Note" -> "Use SourceVaultStatus[\"" <> sourceId <>
                "\"] after job completes to see snapshot."
    |>
  ];


(* \:975e\:540c\:671f ingest \:5f85\:6a5f API\:3002
   - sync \:5b8c\:4e86\:6e08\:307f (Ingested/AlreadyCurrent/RebuiltMetadata) \:306f\:5373\:5ea7 return
   - Queued \:306f SourceId \:306e snapshot \:5897\:52a0\:3092 polling
   - LLMGraphDAGInspect \:306e\:5185\:90e8\:69cb\:9020\:306b\:4f9d\:5b58\:3057\:306a\:3044 (\:5b89\:5168) *)
SourceVaultIngestWait[ingestResultOrSourceId_, timeoutSec_:60] :=
  Module[{sourceId, startTime, status, snaps, beforeCount, currentCount,
          inputStatus, waited},
    (* \:5165\:529b\:5224\:5b9a *)
    Which[
      AssociationQ[ingestResultOrSourceId],
        sourceId = Lookup[ingestResultOrSourceId, "SourceId", None];
        inputStatus = Lookup[ingestResultOrSourceId, "Status", ""];
        (* sync \:5b8c\:4e86\:7d50\:679c\:306f\:5373\:5ea7 return *)
        If[MemberQ[{"Ingested", "AlreadyCurrent", "RebuiltMetadata"}, inputStatus],
          Return[ingestResultOrSourceId]];
        (* Failed \:7d50\:679c\:3082\:5373\:5ea7 return *)
        If[MatchQ[inputStatus, "Failed" | "DeniedByNBAccess"],
          Return[ingestResultOrSourceId]],
      StringQ[ingestResultOrSourceId],
        sourceId = ingestResultOrSourceId,
      True,
        Return[<|"Status" -> "Failed",
          "Reason" -> "InvalidArgument",
          "Hint" -> "Pass SourceVaultIngest result Association or SourceId String."|>]
    ];
    
    If[!StringQ[sourceId],
      Return[<|"Status" -> "Failed",
        "Reason" -> "MissingSourceId"|>]];
    
    iEnsureRoots[];
    
    (* polling \:958b\:59cb\:6642\:70b9\:306e snapshot \:6570\:3092\:8a18\:9332 (\:65b0\:898f\:5897\:52a0\:3092\:691c\:51fa) *)
    status = Quiet[SourceVaultStatus[sourceId]];
    beforeCount = If[AssociationQ[status],
      Length[Lookup[status, "Snapshots", {}]], 0];
    
    startTime = AbsoluteTime[];
    
    While[True,
      waited = N[AbsoluteTime[] - startTime];
      If[waited > timeoutSec,
        Return[<|"Status" -> "Timeout",
          "SourceId" -> sourceId,
          "WaitedSeconds" -> waited,
          "Hint" -> "Job may still be running. Try a longer timeoutSec or " <>
                    "check SourceVaultStatus[sourceId] manually."|>]];
      
      status = Quiet[SourceVaultStatus[sourceId]];
      If[AssociationQ[status],
        snaps = Lookup[status, "Snapshots", {}];
        currentCount = If[ListQ[snaps], Length[snaps], 0];
        If[currentCount > beforeCount,
          (* \:65b0\:898f snapshot \:51fa\:73fe \[Rule] \:5b8c\:4e86 *)
          Return[<|
            "Status" -> "Ready",
            "SourceId" -> sourceId,
            "SnapshotId" -> Last[snaps],
            "WaitedSeconds" -> waited
          |>]]];
      Pause[0.5]]
  ];


(* ============================================================
   10. SourceVaultStatus / List / Snapshots
   ============================================================ *)

SourceVaultList[] :=
  Module[{files},
    iEnsureRoots[];
    files = FileNames["src-*.json", iMetaDir[]];
    Map[FileBaseName, files]
  ];

SourceVaultSnapshots[sourceRefOrId_] :=
  Module[{ids},
    iEnsureRoots[];
    Which[
      StringQ[sourceRefOrId] && StringStartsQ[sourceRefOrId, "src-"],
        Module[{meta},
          meta = iSourceMetaLoad[sourceRefOrId];
          If[AssociationQ[meta], Lookup[meta, "Snapshots", {}], {}]
        ],
      True,
        (* fall-through: \:5168 snapshot \:3092\:8fd4\:3059 (TODO: filter) *)
        ids = Map[FileBaseName, FileNames["snap-*.json", iMetaDir[]]];
        ids
    ]
  ];

SourceVaultStatus[] :=
  Module[{sources, snapshots, rawFiles, rawBytes},
    iEnsureRoots[];
    sources   = SourceVaultList[];
    snapshots = Map[FileBaseName, FileNames["snap-*.json", iMetaDir[]]];
    rawFiles  = FileNames["sha256-*", iRawDir[]];
    rawBytes  = Total[Quiet[FileByteCount /@ rawFiles] /. _?(Not @* NumericQ) -> 0];
    <|
      "Roots" -> SourceVault`$SourceVaultRoots,
      "SourceCount" -> Length[sources],
      "SnapshotCount" -> Length[snapshots],
      "RawFileCount" -> Length[rawFiles],
      "RawTotalBytes" -> rawBytes,
      "Initialized" -> DirectoryQ[SourceVault`$SourceVaultRoots["PrivateVault"]]
    |>
  ];

SourceVaultStatus[refOrId_String] :=
  Module[{src, snap},
    iEnsureRoots[];
    Which[
      StringStartsQ[refOrId, "src-"],
        src = iSourceMetaLoad[refOrId];
        If[AssociationQ[src], src, <|"Status" -> "NotFound", "SourceId" -> refOrId|>],
      StringStartsQ[refOrId, "snap-"],
        snap = iSnapshotMetaLoad[refOrId];
        If[AssociationQ[snap], snap, <|"Status" -> "NotFound", "SnapshotId" -> refOrId|>],
      True,
        (* try to interpret as file path or general ref *)
        Module[{normalized, found},
          normalized = If[FileExistsQ[refOrId], ExpandFileName[refOrId], refOrId];
          found = SelectFirst[
            (iSourceMetaLoad /@ SourceVaultList[]),
            AssociationQ[#] && Lookup[#, "OriginalPath", ""] === normalized &,
            Missing[]];
          If[AssociationQ[found], found,
            <|"Status" -> "NotFound", "Ref" -> refOrId|>]
        ]
    ]
  ];


(* ============================================================
   11. SourceVaultResolvePath (\:30ed\:30fc\:30ab\:30eb\:4f7f\:7528\:3001cloud sink \:4f7f\:7528\:7981\:6b62)
   ============================================================ *)

Options[SourceVaultResolvePath] = {"Tier" -> "PrivateVault"};

SourceVaultResolvePath[ref_, OptionsPattern[]] :=
  Module[{tier, meta},
    tier = OptionValue["Tier"];
    Which[
      StringQ[ref] && StringStartsQ[ref, "snap-"],
        meta = iSnapshotMetaLoad[ref];
        If[AssociationQ[meta] && tier === "PrivateVault",
          Lookup[meta, "Path", $Failed],
          $Failed],
      StringQ[ref] && StringStartsQ[ref, "src-"],
        meta = iSourceMetaLoad[ref];
        If[AssociationQ[meta],
          Module[{snaps, latest},
            snaps = Lookup[meta, "Snapshots", {}];
            If[Length[snaps] === 0, Return[$Failed]];
            latest = iSnapshotMetaLoad[Last[snaps]];
            If[AssociationQ[latest], Lookup[latest, "Path", $Failed], $Failed]
          ],
          $Failed],
      True,
        $Failed
    ]
  ];


(* ============================================================
   11.5 ソース一覧 / 横断検索 (SourceVaultSources / SourceVaultSummaries)

   共通行スキーマ (provider 契約):
     <|"Kind" -> "arxiv"|"web"|"local"|"eagle"|...,
       "Id" -> _String, "Title" -> _String, "Authors" -> _String,
       "Published" -> _String (内容の出版日 ISO / ""),
       "Summary" -> _String, "URL" -> _String, "File" -> _String,
       "Date" -> _String (登録/生成日時), "PrivacyLevel" -> _Real|>
   SourceVaultEagleSummaryRow (SourceVault_eagle.wl) と同じキーを共有する。
   provider は SourceVaultRegisterSummaryProvider[name, fn] で登録し、
   fn[query_String, opts_Association] が共通行のリストを返す。
   ============================================================ *)

iSVUIFont[] := If[$Language === "Japanese", "Yu Gothic UI", "Segoe UI"];

iSVTruncStr[s_, n_Integer] :=
  With[{t = If[StringQ[s], s, ToString[s]]},
    If[StringLength[t] > n, StringTake[t, n] <> "…", t]];

iSVKindOfSourceType[st_] :=
  Switch[ToString[st],
    "ArXiv", "arxiv",
    "URL", "web",
    "LocalFile", "local",
    _, ToLowerCase[ToString[st]]];

(* source meta から arXiv id を引く (CanonicalURI 優先、無ければ latest snapshot) *)
iSVArXivIdOfMeta[meta_Association] :=
  Module[{canon = ToString @ Lookup[meta, "CanonicalURI", ""], snaps, snap},
    If[StringStartsQ[canon, "arXiv:"],
      StringDrop[canon, 6],
      snaps = Lookup[meta, "Snapshots", {}];
      snap = If[ListQ[snaps] && snaps =!= {},
        iSnapshotMetaLoad[Last[snaps]], Missing[]];
      If[AssociationQ[snap], Lookup[snap, "ArXivId", Missing[]], Missing[]]
    ]
  ];
iSVArXivIdOfMeta[___] := Missing[];

(* arXiv API (export.arxiv.org) から title/authors/published を一括取得。
   戻り値: <|id -> <|"Title"->_, "Authors"->{__String}, "Published"->_|>, ...|>
   失敗 id はセッション内キャッシュ $iSVArXivFetchFailed に記録し再試行しない。 *)
If[!AssociationQ[$iSVArXivFetchFailed], $iSVArXivFetchFailed = <||>];

iSVArXivMetaFetchBatch[ids : {__String}] :=
  Module[{url, xml, entries, out = <||>},
    url = "https://export.arxiv.org/api/query?max_results=" <>
      ToString[Length[ids]] <> "&id_list=" <> StringRiffle[ids, ","];
    xml = Quiet @ Check[
      TimeConstrained[Import[url, "XML"], 30, $Failed], $Failed];
    entries = If[xml === $Failed, {},
      Cases[xml, XMLElement["entry", _, _], Infinity]];
    Scan[
      Function[entry,
        Module[{eid, title, authors, published, key},
          eid = FirstCase[entry,
            XMLElement["id", _, {s_String}] :> s, "", Infinity];
          eid = StringReplace[eid,
            RegularExpression["^https?://arxiv\\.org/abs/"] -> ""];
          title = FirstCase[entry,
            XMLElement["title", _, {t_String}] :> t, "", Infinity];
          title = StringTrim @
            StringReplace[title, WhitespaceCharacter .. -> " "];
          authors = Cases[entry,
            XMLElement["author", _, ac_] :>
              FirstCase[ac, XMLElement["name", _, {n_String}] :> n,
                Nothing, Infinity],
            Infinity];
          published = FirstCase[entry,
            XMLElement["published", _, {p_String}] :> p, "", Infinity];
          (* リクエスト id との対応付け: 完全一致 -> version 抜き一致 *)
          key = SelectFirst[ids, # === eid &,
            SelectFirst[ids,
              StringReplace[eid, RegularExpression["v[0-9]+$"] -> ""] === # &,
              Missing[]]];
          If[StringQ[key] && title =!= "",
            out[key] = <|
              "Title" -> title,
              "Authors" -> Select[authors, StringQ],
              "Published" -> published|>]
        ]],
      entries];
    Scan[If[!KeyExistsQ[out, #], $iSVArXivFetchFailed[#] = True] &, ids];
    out
  ];
iSVArXivMetaFetchBatch[{}] := <||>;

(* 保存済み HTML snapshot から <title> を抽出 (network なし、先頭 256KB のみ)。
   チャンク末尾で UTF-8 マルチバイト列が切れると decode が失敗するので、
   末尾 1〜3 byte を削って再試行してから Latin-1 にフォールバックする。 *)
iSVHtmlTitleOf[path_String] :=
  Module[{strm, bytes, str, hits, title},
    If[!FileExistsQ[path], Return[""]];
    strm = Quiet @ OpenRead[path, BinaryFormat -> True];
    If[Head[strm] =!= InputStream, Return[""]];
    bytes = Quiet @ Check[BinaryReadList[strm, "Byte", 262144], {}];
    Quiet @ Close[strm];
    If[!ListQ[bytes] || bytes === {}, Return[""]];
    str = SelectFirst[
      Map[Function[drop,
        If[Length[bytes] > drop,
          Quiet @ Check[
            ByteArrayToString[ByteArray[Drop[bytes, -drop]], "UTF-8"],
            $Failed],
          $Failed]],
        {0, 1, 2, 3}],
      StringQ, $Failed];
    If[!StringQ[str],
      str = Quiet @ Check[FromCharacterCode[bytes], $Failed]];
    If[!StringQ[str], Return[""]];
    hits = StringCases[str,
      RegularExpression["(?is)<title[^>]*>(.*?)</title>"] -> "$1", 1];
    If[hits === {}, Return[""]];
    title = StringTrim @
      StringReplace[First[hits], WhitespaceCharacter .. -> " "];
    StringReplace[title, {"&amp;" -> "&", "&lt;" -> "<", "&gt;" -> ">",
      "&quot;" -> "\"", "&#39;" -> "'", "&nbsp;" -> " "}]
  ];
iSVHtmlTitleOf[___] := "";

iSVSourceTitleMissingQ[meta_] :=
  !StringQ[Lookup[meta, "Title", Missing[]]] ||
    StringTrim[ToString @ Lookup[meta, "Title", ""]] === "";

(* meta 1 件に表示用 Title/Authors/Published を補完し、変化したら保存する *)
iSVSourceEnrichOne[meta_Association, fetch_, arxivBatch_Association] :=
  Module[{m = meta, st, changed = False, aid, hit, snaps, snap, ct, path, t},
    st = ToString @ Lookup[m, "SourceType", ""];
    Which[
      st === "ArXiv" && (TrueQ[fetch] || iSVSourceTitleMissingQ[m]),
        aid = iSVArXivIdOfMeta[m];
        hit = If[StringQ[aid], Lookup[arxivBatch, aid, Missing[]], Missing[]];
        If[AssociationQ[hit],
          m["Title"] = Lookup[hit, "Title", ""];
          m["Authors"] = Lookup[hit, "Authors", {}];
          m["Published"] = Lookup[hit, "Published", ""];
          m["MetaFetchedAt"] = iIsoNow[];
          changed = True],
      st === "URL" && (TrueQ[fetch] || iSVSourceTitleMissingQ[m]),
        snaps = Lookup[m, "Snapshots", {}];
        snap = If[ListQ[snaps] && snaps =!= {},
          iSnapshotMetaLoad[Last[snaps]], Missing[]];
        If[AssociationQ[snap],
          ct = ToString @ Lookup[snap, "ContentType", ""];
          path = ToString @ Lookup[snap, "Path", ""];
          (* HTML 判定: ContentType / raw 拡張子 / (ContentType 欠落時は
             PDF 系でない限り試す。<title> が無ければ無害に "" が返る) *)
          If[StringQ[path] && path =!= "" && FileExistsQ[path] &&
             (StringContainsQ[ct, "html"] ||
              MemberQ[{"html", "htm"}, ToLowerCase[FileExtension[path]]] ||
              (ct === "" && !MemberQ[{"pdf", "bin"},
                 ToLowerCase[FileExtension[path]]])),
            t = iSVHtmlTitleOf[path];
            If[StringQ[t] && t =!= "",
              m["Title"] = t;
              m["MetaFetchedAt"] = iIsoNow[];
              changed = True]]],
      True, Null];
    If[changed,
      Quiet @ Check[iSourceMetaSave[ToString @ Lookup[m, "SourceId", ""], m], Null]];
    m
  ];
iSVSourceEnrichOne[m_, ___] := m;

(* metas リストを一括補完 (arXiv API は 1 リクエストにまとめる) *)
iSVSourcesEnrich[metas_List, fetch_] :=
  Module[{needIds, batch},
    If[fetch === False, Return[metas]];
    needIds = DeleteDuplicates @ Select[
      Map[Function[m,
        If[AssociationQ[m] &&
            ToString @ Lookup[m, "SourceType", ""] === "ArXiv" &&
            (TrueQ[fetch] || iSVSourceTitleMissingQ[m]) &&
            !TrueQ[Lookup[$iSVArXivFetchFailed,
              iSVArXivIdOfMeta[m] /. Missing[___] -> "", False]],
          iSVArXivIdOfMeta[m], Missing[]]], metas],
      StringQ];
    batch = If[needIds === {}, <||>, iSVArXivMetaFetchBatch[needIds]];
    Map[iSVSourceEnrichOne[#, fetch, batch] &, metas]
  ];

(* meta -> 共通スキーマ行 *)
iSVSourceRowOf[meta_Association] :=
  Module[{kind, id, title, authors, published, url, file, date, pl,
          snaps, snap, aid},
    id = ToString @ Lookup[meta, "SourceId", ""];
    kind = iSVKindOfSourceType[Lookup[meta, "SourceType", ""]];
    snaps = Lookup[meta, "Snapshots", {}];
    snap = If[ListQ[snaps] && snaps =!= {},
      iSnapshotMetaLoad[Last[snaps]], Missing[]];
    file = If[AssociationQ[snap], ToString @ Lookup[snap, "Path", ""], ""];
    If[file =!= "" && !FileExistsQ[file], file = ""];  (* purge 済み raw は空欄 *)
    aid = iSVArXivIdOfMeta[meta];
    url = Which[
      kind === "arxiv" && StringQ[aid], "https://arxiv.org/abs/" <> aid,
      True, ToString @ Lookup[meta, "OriginalURL", ""]];
    title = ToString @ Lookup[meta, "Title", ""];
    If[StringTrim[title] === "",
      title = ToString @ Lookup[meta, "DisplayName", ""]];
    If[StringTrim[title] === "",
      title = Which[
        kind === "local",
          FileNameTake[ToString @ Lookup[meta, "OriginalPath", id]],
        url =!= "", url,
        True, id]];
    authors = Lookup[meta, "Authors", {}];
    authors = Which[
      ListQ[authors], StringRiffle[ToString /@ authors, ", "],
      StringQ[authors], authors,
      True, ""];
    published = ToString @ Lookup[meta, "Published", ""];
    date = ToString @ Lookup[meta, "CreatedAt", ""];
    pl = With[{p = Lookup[meta, "PrivacyLevel", Missing[]]},
      If[NumericQ[p], N[p], 1.0]];
    <|"Kind" -> kind, "Id" -> id, "Title" -> title, "Authors" -> authors,
      "Published" -> published,
      "Summary" -> ToString @ Lookup[meta, "Summary", ""],
      "URL" -> url, "File" -> file, "Date" -> date, "PrivacyLevel" -> pl|>
  ];

(* ingest 済み全ソースの共通行 (query フィルタ付き)。
   opts キー: "FetchMetadata", "Kind" *)
iSVSourcesRows[query_String, opts_Association] :=
  Module[{fetch, kindFilter, ids, metas, rows, q},
    fetch = Lookup[opts, "FetchMetadata", Automatic];
    kindFilter = Lookup[opts, "Kind", All];
    iEnsureRoots[];
    ids = SourceVaultList[];
    metas = Select[iSourceMetaLoad /@ ids, AssociationQ];
    metas = iSVSourcesEnrich[metas, fetch];
    rows = iSVSourceRowOf /@ metas;
    If[kindFilter =!= All && kindFilter =!= Automatic,
      rows = Select[rows,
        MemberQ[ToLowerCase /@ (ToString /@ Flatten[{kindFilter}]),
          ToString @ Lookup[#, "Kind", ""]] &]];
    q = StringTrim[query];
    If[q =!= "",
      rows = Select[rows, Function[r, AnyTrue[
        {Lookup[r, "Title", ""], Lookup[r, "Authors", ""],
         Lookup[r, "Summary", ""], Lookup[r, "URL", ""],
         Lookup[r, "File", ""], Lookup[r, "Id", ""], Lookup[r, "Kind", ""]},
        StringContainsQ[ToString[#], q, IgnoreCase -> True] &]]]];
    rows
  ];
iSVSourcesRows[query_String] := iSVSourcesRows[query, <||>];

(* ソース 1 件の全メタ情報を別ウインドウで表示 (タイトルクリック既定動作) *)
iSVSourceShowInfo[sourceId_String] :=
  Module[{meta, title},
    meta = iSourceMetaLoad[sourceId];
    If[!AssociationQ[meta],
      Return[<|"Status" -> "Error", "Reason" -> "NotFound",
        "SourceId" -> sourceId|>]];
    title = ToString @ Lookup[meta, "Title",
      Lookup[meta, "DisplayName", sourceId]];
    CreateDocument[
      {Cell[title, "Subsection"],
       ExpressionCell[Dataset[meta], "Output"]},
      WindowTitle -> sourceId, WindowSize -> {760, 520}];
    <|"Status" -> "Opened", "SourceId" -> sourceId|>
  ];

(* Kind ごとの行アクション (adapter が上書き登録できる):
   $iSVRowTitleActions[kind] = fn[id]  (タイトルクリック。既定: メタ情報ウインドウ)
   $iSVRowOpenActions[kind]  = fn[id]  (ファイルを開く。既定: row の File を SystemOpen) *)
If[!AssociationQ[$iSVRowTitleActions], $iSVRowTitleActions = <||>];
If[!AssociationQ[$iSVRowOpenActions], $iSVRowOpenActions = <||>];

(* 共通行リスト -> notebook list 風 Grid (SourceVaultEagleSummaries と同系の見た目) *)
iSVRenderRowsGrid[rows_List, total_Integer, caption_String] :=
  Module[{ff = iSVUIFont[], header, body, grid, capLine},
    If[rows === {},
      Return[Style["該当するデータはありません。", "Text", FontFamily -> ff]]];
    header = (Style[#, Bold, FontFamily -> ff] &) /@
      {"種別", "タイトル", "著者", "出版", "サマリー", "PL", "URL", "ファイル", "登録"};
    body = Function[row,
      Module[{kind, id, title, authors, published, summary, pl, url, file,
              date, titleAct, openAct},
        kind = ToString @ Lookup[row, "Kind", ""];
        id = ToString @ Lookup[row, "Id", ""];
        title = ToString @ Lookup[row, "Title", ""];
        authors = ToString @ Lookup[row, "Authors", ""];
        published = ToString @ Lookup[row, "Published", ""];
        summary = ToString @ Lookup[row, "Summary", ""];
        pl = Lookup[row, "PrivacyLevel", Missing[]];
        url = ToString @ Lookup[row, "URL", ""];
        file = ToString @ Lookup[row, "File", ""];
        date = ToString @ Lookup[row, "Date", ""];
        titleAct = Lookup[$iSVRowTitleActions, kind, Automatic];
        openAct = Lookup[$iSVRowOpenActions, kind, Automatic];
        {kind,
         With[{act = If[titleAct === Automatic, iSVSourceShowInfo, titleAct],
               theId = id},
           Tooltip[
             Button[Style[iSVTruncStr[title, 60], "Hyperlink", FontFamily -> ff],
               act[theId], Appearance -> "Frameless", Method -> "Queued",
               BaseStyle -> "Hyperlink"],
             title <> "\nId: " <> theId]],
         If[authors === "", "",
           Tooltip[Style[iSVTruncStr[authors, 40], FontFamily -> ff], authors]],
         StringTake[published, UpTo[7]],
         If[summary === "", "",
           Tooltip[Style[iSVTruncStr[summary, 60], FontFamily -> ff], summary]],
         If[NumericQ[pl], ToString[N[pl]], ""],
         If[StringStartsQ[url, "http"],
           Tooltip[Hyperlink[Style["▶ URL", FontFamily -> ff], url], url], ""],
         Which[
           openAct =!= Automatic,
             With[{act = openAct, theId = id},
               Button[Style["▶ 開く", "Hyperlink", FontFamily -> ff],
                 act[theId], Appearance -> "Frameless", Method -> "Queued",
                 BaseStyle -> "Hyperlink"]],
           file =!= "",
             With[{f = file},
               Tooltip[
                 Button[Style["▶ 開く", "Hyperlink", FontFamily -> ff],
                   SystemOpen[f], Appearance -> "Frameless", Method -> "Queued",
                   BaseStyle -> "Hyperlink"], f]],
           True, ""],
         If[date === "", "",
           Tooltip[Style[StringTake[date, UpTo[10]], FontFamily -> ff], date]]}
      ]] /@ rows;
    grid = Grid[Prepend[body, header],
      Frame -> All, FrameStyle -> Directive[GrayLevel[0.85]],
      Background -> {None, {GrayLevel[0.92], {White}}},
      Alignment -> {Left, Center}, Spacings -> {1.2, 0.7},
      BaseStyle -> {FontFamily -> ff}];
    capLine = Style[caption <> " (" <> ToString[total] <> " 件)",
      Bold, 14, FontFamily -> ff];
    If[Length[rows] < total,
      Column[{capLine,
        Style["全 " <> ToString[total] <> " 件中 " <> ToString[Length[rows]] <>
          " 件を表示。全件は \"Limit\" -> Automatic。",
          FontFamily -> ff, GrayLevel[0.45]],
        grid}],
      Column[{capLine, grid}]]
  ];

(* ---- 公開: ingest 済みソース一覧 ---- *)

Options[SourceVaultSourceRow] = {"FetchMetadata" -> Automatic};
SourceVaultSourceRow[sourceId_String, OptionsPattern[]] :=
  Module[{meta},
    meta = iSourceMetaLoad[sourceId];
    If[!AssociationQ[meta], Return[Missing["NotFound", sourceId]]];
    meta = First @ iSVSourcesEnrich[{meta}, OptionValue["FetchMetadata"]];
    iSVSourceRowOf[meta]
  ];

Options[SourceVaultSources] = {
  "Limit" -> Automatic, "Kind" -> All,
  "FetchMetadata" -> Automatic, "Format" -> "Grid"};
SourceVaultSources[query_String : "", OptionsPattern[]] :=
  Module[{rows, total, lim},
    rows = iSVSourcesRows[query, <|
      "FetchMetadata" -> OptionValue["FetchMetadata"],
      "Kind" -> OptionValue["Kind"]|>];
    rows = ReverseSortBy[rows, ToString @ Lookup[#, "Date", ""] &];
    total = Length[rows];
    lim = OptionValue["Limit"];
    If[IntegerQ[lim] && lim >= 0, rows = Take[rows, UpTo[lim]]];
    Switch[OptionValue["Format"],
      "Rows", rows,
      "Dataset", Dataset[rows],
      _, iSVRenderRowsGrid[rows, total, "Ingest 済みソース一覧"]]
  ];

(* ---- 公開: 横断検索 (provider 横断) ---- *)

If[!AssociationQ[$SourceVaultSummaryProviders],
  $SourceVaultSummaryProviders = <||>];

SourceVaultRegisterSummaryProvider[name_String, fn_] :=
  ($SourceVaultSummaryProviders[name] = fn;
   <|"Status" -> "Registered", "Provider" -> name|>);

(* ingest 済みソース provider (本体) *)
SourceVaultRegisterSummaryProvider["sources", iSVSourcesRows];

Options[SourceVaultSummaries] = {
  "Limit" -> Automatic, "Providers" -> All, "Kind" -> All,
  "FetchMetadata" -> Automatic, "Format" -> "Grid"};
SourceVaultSummaries[query_String : "", OptionsPattern[]] :=
  Module[{provs, sel, o, rows, total, lim},
    provs = If[AssociationQ[$SourceVaultSummaryProviders],
      $SourceVaultSummaryProviders, <||>];
    sel = OptionValue["Providers"];
    If[sel =!= All && sel =!= Automatic,
      provs = KeyTake[provs, ToString /@ Flatten[{sel}]]];
    o = <|"FetchMetadata" -> OptionValue["FetchMetadata"],
      "Kind" -> OptionValue["Kind"]|>;
    rows = Join @@ Map[
      Function[fn, Module[{r = Quiet @ Check[fn[query, o], {}]},
        If[ListQ[r], Select[r, AssociationQ], {}]]],
      Values[provs]];
    rows = ReverseSortBy[rows, ToString @ Lookup[#, "Date", ""] &];
    total = Length[rows];
    lim = OptionValue["Limit"];
    If[IntegerQ[lim] && lim >= 0, rows = Take[rows, UpTo[lim]]];
    Switch[OptionValue["Format"],
      "Rows", rows,
      "Dataset", Dataset[rows],
      _, iSVRenderRowsGrid[rows, total, "SourceVault 横断検索結果"]]
  ];

(* ---- View 出力セルの自動機密マーク spec 登録 ----
   SourceVaultSources / SourceVaultSummaries の出力はソース・item のメタ情報
   (タイトル/パス/サマリー等) を含むので、表示行の最大 PrivacyLevel をセル PL
   とする (SourceVault_maildb.wl / SourceVault_eagle.wl と同じ共有レジストリ枠組み。
   maildb の SourceVaultMarkConfidentialViewCells / 自動フックが spec を走査する)。 *)

iSVCatalogViewInputQ[text_String] :=
  StringContainsQ[text,
    RegularExpression["SourceVault(Sources|Summaries)\\s*\\["]];
iSVCatalogViewInputQ[_] := False;

(* read-only プローブ: Format->"Rows" で再実行し最大 PL を返す。
   Limit は外して superset を見る (安全側)。network 再取得はしない。 *)
iSVCatalogPLProbe[query_String : "", opts___] :=
  Module[{rows},
    rows = Quiet @ Check[
      SourceVaultSummaries[query, "Format" -> "Rows",
        "FetchMetadata" -> False, "Limit" -> Automatic, opts],
      $Failed];
    If[!ListQ[rows], Return[1.0]];
    If[rows === {}, Return[0.0]];
    Max[Map[
      Function[r, With[{p = Lookup[r, "PrivacyLevel", Missing[]]},
        If[NumericQ[p], N[p], 1.0]]],
      rows]]
  ];
iSVCatalogPLProbe[___] := 1.0;

iSVCatalogCellMaxPLFromText[text_String] :=
  Module[{held, vals},
    held = Quiet @ Check[ToExpression[text, InputForm, HoldComplete], $Failed];
    If[held === $Failed, Return[1.0]];
    vals = Quiet @ Check[
      Cases[held,
        HoldPattern[(SourceVaultSources | SourceVaultSummaries)[a___]] :>
          iSVCatalogPLProbe[a],
        {0, Infinity}], {}];
    If[ListQ[vals] && Length[vals] > 0 && AllTrue[vals, NumericQ],
      Max[vals], 1.0]];
iSVCatalogCellMaxPLFromText[_] := 1.0;

If[!ListQ[$iSVConfidentialViewSpecRegistry],
  $iSVConfidentialViewSpecRegistry = {}];
$iSVConfidentialViewSpecRegistry = Append[
  DeleteCases[$iSVConfidentialViewSpecRegistry, {iSVCatalogViewInputQ, _}],
  {iSVCatalogViewInputQ, iSVCatalogCellMaxPLFromText}];


(* ============================================================
   12. Stage 3: SourceVaultSpan / Context / ContextAssemble
   ============================================================ *)

Options[SourceVaultSpan] = {
  "Pages" -> All,
  "Role" -> "ReferenceContext",
  "Purpose" -> "Generic",
  "EquationLabels" -> Missing["NotSpecified"]
};

(* span constructor: accepts SnapshotId, SourceId, or file path *)
SourceVaultSpan[ref_, opts:OptionsPattern[]] :=
  Module[{snapshotId, sourceId, snapshotMeta, ingestResult},
    Which[
      (* \:65e2\:5b58 SnapshotId *)
      StringQ[ref] && StringStartsQ[ref, "snap-"],
        snapshotId = ref;
        snapshotMeta = iSnapshotMetaLoad[snapshotId];
        sourceId = If[AssociationQ[snapshotMeta],
          Lookup[snapshotMeta, "SourceId", Missing[]], Missing[]],
      (* SourceId \[RightArrow] latest snapshot *)
      StringQ[ref] && StringStartsQ[ref, "src-"],
        sourceId = ref;
        Module[{src, snaps},
          src = iSourceMetaLoad[sourceId];
          snaps = If[AssociationQ[src], Lookup[src, "Snapshots", {}], {}];
          snapshotId = If[Length[snaps] > 0, Last[snaps], Missing["NoSnapshot"]];
        ],
      (* file path \[RightArrow] ingest \:3057\:3066 latest snapshot *)
      StringQ[ref] && FileExistsQ[ref],
        ingestResult = SourceVaultIngest[ref];
        If[KeyExistsQ[ingestResult, "SnapshotId"],
          snapshotId = ingestResult["SnapshotId"];
          sourceId = ingestResult["SourceId"],
          snapshotId = Missing["IngestFailed"]; sourceId = Missing[]],
      (* fall-through: unsupported *)
      True,
        snapshotId = Missing["InvalidRef"]; sourceId = Missing[]
    ];
    
    <|
      "SnapshotId" -> snapshotId,
      "SourceId" -> sourceId,
      "Locator" -> <|
        "Pages" -> OptionValue["Pages"],
        "EquationLabels" -> OptionValue["EquationLabels"]
      |>,
      "Role" -> OptionValue["Role"],
      "Purpose" -> OptionValue["Purpose"]
    |>
  ];


(* ---------- Text extraction ---------- *)

iPageTextCachePath[snapshotId_String, page_] :=
  FileNameJoin[{iParsedDir[], snapshotId, "pages",
    StringPadLeft[ToString[page], 4, "0"] <> ".txt"}];

iCachePageText[snapshotId_String, page_Integer, text_String] :=
  Module[{path},
    path = iPageTextCachePath[snapshotId, page];
    iEnsureDir[DirectoryName[path]];
    iTransactionalWrite[path, text];
    path
  ];

(* cache \:8aad\:307f\:8fbc\:307f: \:30d5\:30a1\:30a4\:30eb\:304c\:5b58\:5728\:3059\:308c\:3070 string\:3001\:7121\:3051\:308c\:3070 Missing[] *)
iLoadCachedPageText[snapshotId_String, page_Integer] :=
  Module[{path, txt},
    path = iPageTextCachePath[snapshotId, page];
    If[!FileExistsQ[path], Return[Missing["NotCached"]]];
    txt = Quiet[Import[path, "Text", CharacterEncoding -> "UTF-8"]];
    If[StringQ[txt], txt, Missing["ReadFailed"]]
  ];

(* page-hashes.json \:306e\:30d1\:30b9 *)
iPageHashesPath[snapshotId_String] :=
  FileNameJoin[{iParsedDir[], snapshotId, "page-hashes.json"}];

(* page-hashes.json \:8aad\:307f\:8fbc\:307f: \:7121\:3051\:308c\:3070\:7a7a Association *)
iLoadPageHashes[snapshotId_String] :=
  Module[{path, data},
    path = iPageHashesPath[snapshotId];
    If[!FileExistsQ[path], Return[<||>]];
    data = Quiet[iLoadJSON[path]];
    If[AssociationQ[data], data, <||>]
  ];

(* page-hashes.json \:66f8\:304d\:8fbc\:307f (\:5168\:7f6e\:63db) *)
iSavePageHashes[snapshotId_String, hashes_Association] :=
  Module[{path},
    path = iPageHashesPath[snapshotId];
    iEnsureDir[DirectoryName[path]];
    iSaveJSON[path, hashes];
    path
  ];

(* PDF \:30b9\:30ad\:30e3\:30f3\:5224\:5b9a: \:7a7a\:6587\:5b57\:5217 or 5 \:6587\:5b57\:672a\:6e80 \:3092\:300c\:30b9\:30ad\:30e3\:30f3\:300d\:3068\:307f\:306a\:3059 *)
iIsPDFLikelyScanned[text_String] :=
  Module[{trimmed},
    trimmed = StringTrim[text];
    StringLength[trimmed] < 5
  ];
iIsPDFLikelyScanned[_] := True;

(* \:5358\:30da\:30fc\:30b8\:62bd\:51fa\:30d8\:30eb\:30d1\:3002cache hit \:306a\:3089 disk \:304b\:3089\:3001miss \:306a\:3089 Import + cache \:66f8\:304d\:3002
   OCR hook \:304c\:5b9a\:7fa9\:3055\:308c\:3066\:3044\:3066 plaintext \:62bd\:51fa\:304c\:30b9\:30ad\:30e3\:30f3\:5224\:5b9a\:3055\:308c\:308c\:3070 hook \:3092\:547c\:3076\:3002
   forceOCR=True \:307e\:305f\:306f $SourceVaultOCRMode=="Force" \:306e\:5834\:5408\:306f\:30b9\:30ad\:30e3\:30f3\:5224\:5b9a\:3092\:30b9\:30ad\:30c3\:30d7\:3057\:3066\:5fc5\:305a OCR \:3092\:547c\:3076\:3002
   \:623b\:308a\:5024: <|\"Text\" -> _String, \"FromCache\" -> True|False,
                   \"OCRUsed\" -> True|False, \"Hash\" -> _String|>
*)
iExtractSinglePageWithCache[rawPath_String, snapshotId_String, page_Integer,
    force_:False, forceOCR_:False] :=
  Module[{cached, text, ocrHook, ocrResult, hash, mode, shouldCallOCR,
          effectiveForce, ocrAttempted, ocrFailReason, verbose, hookRet,
          plaintextLen},
    effectiveForce = TrueQ[force] || TrueQ[forceOCR];
    verbose = TrueQ[If[ValueQ[SourceVault`$SourceVaultOCRVerbose],
      SourceVault`$SourceVaultOCRVerbose, False]];
    
    (* 1. cache hit ? *)
    If[!effectiveForce,
      cached = iLoadCachedPageText[snapshotId, page];
      If[StringQ[cached],
        hash = iComputeSHA256[cached];
        Return[<|
          "Text" -> cached,
          "FromCache" -> True,
          "OCRUsed" -> False,
          "OCRAttempted" -> False,
          "OCRFailReason" -> Null,
          "Hash" -> If[StringQ[hash], "sha256-" <> hash, ""]
        |>]]];
    
    (* 2. PDF \:304b\:3089\:62bd\:51fa *)
    text = Quiet[Import[rawPath, {"Plaintext", page}]];
    If[!StringQ[text], text = ""];
    plaintextLen = StringLength[StringTrim[text]];
    
    If[verbose,
      Print["[SourceVault OCR] page ", page,
        ": plaintext extracted (", plaintextLen, " chars)"]];
    
    (* 3. OCR \:767a\:706b\:5224\:5b9a *)
    ocrHook = If[ValueQ[SourceVault`$SourceVaultOCRHook],
      SourceVault`$SourceVaultOCRHook, None];
    mode = If[ValueQ[SourceVault`$SourceVaultOCRMode],
      SourceVault`$SourceVaultOCRMode, "Auto"];
    
    shouldCallOCR = (ocrHook =!= None && Head[ocrHook] === Function) && (
      TrueQ[forceOCR] ||
      mode === "Force" ||
      iIsPDFLikelyScanned[text]
    );
    
    If[verbose,
      Print["[SourceVault OCR] page ", page,
        ": shouldCallOCR=", shouldCallOCR,
        " (mode=", mode, ", forceOCR=", forceOCR,
        ", isScanned=", iIsPDFLikelyScanned[text], ")"]];
    
    ocrResult = False;
    ocrAttempted = False;
    ocrFailReason = Null;
    
    If[shouldCallOCR,
      ocrAttempted = True;
      If[verbose,
        Print["[SourceVault OCR] page ", page, ": calling hook..."]];
      hookRet = Quiet @ ocrHook[<|
        "RawPath" -> rawPath,
        "Page" -> page,
        "SnapshotId" -> snapshotId
      |>];
      If[verbose,
        Print["[SourceVault OCR] page ", page,
          ": hook returned ",
          Which[
            StringQ[hookRet], "String(" <> ToString[StringLength[hookRet]] <> " chars)",
            hookRet === $Failed, "$Failed",
            Head[hookRet] === Failure, "Failure[...]",
            True, ToString[Head[hookRet]]
          ]]];
      Which[
        StringQ[hookRet] && StringStartsQ[hookRet, "Error:"],
          (* hook \:304c\:30a8\:30e9\:30fc\:30e1\:30c3\:30bb\:30fc\:30b8\:3092\:8fd4\:3057\:305f \[RightArrow] OCRFailReason \:306b\:683c\:7d0d *)
          ocrFailReason = StringTake[hookRet, UpTo[200]],
        StringQ[hookRet] && StringTrim[hookRet] =!= "",
          text = hookRet;
          ocrResult = True,
        StringQ[hookRet],
          ocrFailReason = "EmptyOrWhitespaceResponse",
        hookRet === $Failed,
          ocrFailReason = "HookReturned$Failed",
        Head[hookRet] === Failure,
          ocrFailReason = "HookReturnedFailure",
        True,
          ocrFailReason = "HookReturnedNonString:" <> ToString[Head[hookRet]]
      ]];
    
    (* 4. cache \:66f8\:304d\:8fbc\:307f *)
    iCachePageText[snapshotId, page, text];
    
    hash = iComputeSHA256[text];
    <|
      "Text" -> text,
      "FromCache" -> False,
      "OCRUsed" -> ocrResult,
      "OCRAttempted" -> ocrAttempted,
      "OCRFailReason" -> ocrFailReason,
      "Hash" -> If[StringQ[hash], "sha256-" <> hash, ""]
    |>
  ];

iExtractTextPages[rawPath_String, pages_, snapshotId_:Missing[]] :=
  Module[{txt, list, ext, hasSnap, pageList, results, perPageTexts,
          updatedHashes},
    If[!FileExistsQ[rawPath], Return[""]];
    ext = ToLowerCase[FileExtension[rawPath]];
    hasSnap = StringQ[snapshotId];
    
    Which[
      (* \:5e73\:30c6\:30ad\:30b9\:30c8\:7cfb\:306f\:4e00\:62ec\:8aad\:307f (cache \:5bfe\:8c61\:5916) *)
      ext === "txt" || ext === "md",
        txt = Quiet[Import[rawPath, "Text", CharacterEncoding -> "UTF-8"]];
        If[!StringQ[txt], txt = ""];
        txt,
      
      (* PDF: page\:6307\:5b9a\:53ef\:3002snapshotId \:304c\:6e21\:3055\:308c\:308c\:3070 cache \:7d4c\:7531\:3002 *)
      ext === "pdf",
        Which[
          pages === All,
            (* All \:6307\:5b9a\:306f cache \:5bfe\:8c61\:5916 (\:5168\:30da\:30fc\:30b8\:62bd\:51fa\:306f\:30b3\:30b9\:30c8\:9ad8\:3001
               \:30e6\:30fc\:30b6\:306f\:660e\:793a\:7684\:306b SourceVaultExtractPages \:3092\:4f7f\:3046\:3002\:5f93\:6765\:52d5\:4f5c\:7dad\:6301) *)
            txt = Quiet[Import[rawPath, "Plaintext"]];
            If[!StringQ[txt], txt = ""];
            txt,
          IntegerQ[pages],
            If[hasSnap,
              results = iExtractSinglePageWithCache[rawPath, snapshotId, pages];
              results["Text"],
              txt = Quiet[Import[rawPath, {"Plaintext", pages}]];
              If[!StringQ[txt], txt = ""];
              txt],
          ListQ[pages],
            If[hasSnap,
              (* \:5404 page \:3092 cache \:7d4c\:7531\:3067\:62bd\:51fa\:3001page-hashes \:3082 update *)
              perPageTexts = Map[
                Function[p,
                  Module[{r = iExtractSinglePageWithCache[rawPath, snapshotId, p]},
                    {p, r["Text"], r["Hash"]}]],
                pages];
              (* page-hashes.json \:306b\:30de\:30fc\:30b8\:4fdd\:5b58 (\:30ad\:30fc\:306f 4 \:6841 0 \:30d1\:30c7\:30a3\:30f3\:30b0\:6587\:5b57\:5217) *)
              updatedHashes = iLoadPageHashes[snapshotId];
              Do[
                If[StringQ[entry[[3]]] && entry[[3]] =!= "",
                  updatedHashes = Append[updatedHashes,
                    StringPadLeft[ToString[entry[[1]]], 4, "0"] -> entry[[3]]]],
                {entry, perPageTexts}];
              iSavePageHashes[snapshotId, updatedHashes];
              iJoinTextPages[perPageTexts[[All, 2]], pages],
              (* snapshotId \:7121\:3057: \:5f93\:6765\:901a\:308a *)
              list = Map[Function[p,
                Quiet[Import[rawPath, {"Plaintext", p}]]], pages];
              list = list /. Except[_String] -> "";
              iJoinTextPages[list, pages]],
          True, ""
        ],
      
      (* HTML *)
      ext === "html" || ext === "htm",
        txt = Quiet[Import[rawPath, "Plaintext"]];
        If[!StringQ[txt], txt = ""];
        txt,
      
      True,
        txt = Quiet[Import[rawPath, "Plaintext"]];
        If[!StringQ[txt], txt = "", txt]
    ]
  ];

iJoinTextPages[texts_List, pages_List] :=
  Module[{labeled, i},
    labeled = Table[
      "[Page " <> ToString[pages[[i]]] <> "]\n" <> texts[[i]],
      {i, Length[texts]}];
    StringJoin[Riffle[labeled, "\n\n"]]
  ];

iTrimChars[text_String, max_Integer] :=
  If[StringLength[text] > max,
    StringTake[text, max] <> "\n[... truncated " <>
    ToString[StringLength[text] - max] <> " chars]",
    text];
iTrimChars[text_, _] := If[StringQ[text], text, ""];

(* ---------- Stage 4 Phase 4B: SourceVaultExtractPages ---------- *)

(* OCR hook: \:521d\:671f\:5024 None (Phase 4C \:3067 Function \:3092\:5165\:308c\:3066\:6709\:52b9\:5316) *)
If[!ValueQ[SourceVault`$SourceVaultOCRHook],
  SourceVault`$SourceVaultOCRHook = None];

(* OCR mode: \"Auto\" (\:30b9\:30ad\:30e3\:30f3\:5224\:5b9a\:6642\:306e\:307f) | \"Force\" (\:5e38\:306b OCR) *)
If[!ValueQ[SourceVault`$SourceVaultOCRMode],
  SourceVault`$SourceVaultOCRMode = "Auto"];

(* OCR verbose flag *)
If[!ValueQ[SourceVault`$SourceVaultOCRVerbose],
  SourceVault`$SourceVaultOCRVerbose = False];

Options[SourceVaultExtractPages] = {
  "Force" -> False,
  "ForceOCR" -> False
};

SourceVaultExtractPages[snapOrSrc_String, pages_, opts:OptionsPattern[]] :=
  Module[{snapshotId, snapshotMeta, rawPath, pageList, force, forceOCR,
          pageResults,
          textByPage, hashes, fromCacheCount, freshCount, ocrCount,
          updatedHashes, ext, totalPages, p, r},
    iEnsureRoots[];
    force = TrueQ[OptionValue["Force"]];
    forceOCR = TrueQ[OptionValue["ForceOCR"]];
    
    (* 1. snapshot \:3092\:89e3\:6c7a *)
    Which[
      StringStartsQ[snapOrSrc, "snap-"],
        snapshotId = snapOrSrc;
        snapshotMeta = iSnapshotMetaLoad[snapshotId],
      StringStartsQ[snapOrSrc, "src-"],
        Module[{srcMeta, snaps},
          srcMeta = iSourceMetaLoad[snapOrSrc];
          If[!AssociationQ[srcMeta],
            Return[<|"Status" -> "Failed",
              "Reason" -> "SourceNotFound",
              "Ref" -> snapOrSrc|>]];
          snaps = Lookup[srcMeta, "Snapshots", {}];
          If[!ListQ[snaps] || Length[snaps] === 0,
            Return[<|"Status" -> "Failed",
              "Reason" -> "NoSnapshots",
              "Ref" -> snapOrSrc|>]];
          snapshotId = Last[snaps];
          snapshotMeta = iSnapshotMetaLoad[snapshotId]
        ],
      True,
        Return[<|"Status" -> "Failed",
          "Reason" -> "InvalidRef",
          "Hint" -> "Pass snap-... or src-... String."|>]
    ];
    
    If[!AssociationQ[snapshotMeta],
      Return[<|"Status" -> "Failed",
        "Reason" -> "SnapshotMetaMissing",
        "SnapshotId" -> snapshotId|>]];
    
    rawPath = Lookup[snapshotMeta, "Path", $Failed];
    If[!StringQ[rawPath] || !FileExistsQ[rawPath],
      Return[<|"Status" -> "Failed",
        "Reason" -> "RawFileMissing",
        "SnapshotId" -> snapshotId,
        "Path" -> rawPath|>]];
    
    ext = ToLowerCase[FileExtension[rawPath]];
    If[ext =!= "pdf",
      Return[<|"Status" -> "Failed",
        "Reason" -> "NotPDF",
        "ContentType" -> Lookup[snapshotMeta, "ContentType", ext],
        "Hint" -> "SourceVaultExtractPages is for PDF only. Use SourceVaultContext for text/html."|>]];
    
    (* 2. page list \:306e\:6b63\:898f\:5316 *)
    pageList = Which[
      pages === All,
        (* \:5168\:30da\:30fc\:30b8: Import \:3067 page \:6570\:3092\:53d6\:5f97 *)
        totalPages = Quiet[Import[rawPath, "PageCount"]];
        If[!IntegerQ[totalPages] || totalPages < 1,
          Return[<|"Status" -> "Failed",
            "Reason" -> "PageCountFailed",
            "SnapshotId" -> snapshotId|>]];
        Range[totalPages],
      IntegerQ[pages], {pages},
      ListQ[pages] && AllTrue[pages, IntegerQ], pages,
      True,
        Return[<|"Status" -> "Failed",
          "Reason" -> "InvalidPagesArg",
          "Hint" -> "Pages: Integer / List of Integer / All."|>]
    ];
    
    (* 3. \:5404 page \:3092 cache \:7d4c\:7531\:3067\:62bd\:51fa *)
    pageResults = Association @ Map[
      Function[p,
        Module[{r2},
          r2 = iExtractSinglePageWithCache[rawPath, snapshotId, p, force, forceOCR];
          p -> r2]],
      pageList];
    
    (* 4. page-hashes.json \:3092 update *)
    updatedHashes = iLoadPageHashes[snapshotId];
    Do[
      r = pageResults[p];
      If[StringQ[r["Hash"]] && r["Hash"] =!= "",
        updatedHashes = Append[updatedHashes,
          StringPadLeft[ToString[p], 4, "0"] -> r["Hash"]]],
      {p, pageList}];
    iSavePageHashes[snapshotId, updatedHashes];
    
    (* 5. \:96c6\:8a08
       \:7f60: AssociationMap[f, list] \:306f <|x -> f[x]|>\:3002f \:304c Rule \:3092\:8fd4\:3059\:3068
       <|x -> (k -> v)|> \:306b\:306a\:308b\:306e\:3067\:3001Map + Association \:30d1\:30bf\:30fc\:30f3\:3092\:4f7f\:3046\:3002 *)
    textByPage = Association[
      Map[Function[p, p -> pageResults[p]["Text"]], pageList]];
    hashes = Association[
      Map[Function[p,
        StringPadLeft[ToString[p], 4, "0"] -> pageResults[p]["Hash"]],
        pageList]];
    fromCacheCount = Count[pageList, _?(pageResults[#]["FromCache"] &)];
    freshCount = Length[pageList] - fromCacheCount;
    ocrCount = Count[pageList, _?(pageResults[#]["OCRUsed"] &)];
    
    Module[{ocrAttemptedCount, failReasons},
      ocrAttemptedCount = Count[pageList,
        _?(TrueQ[pageResults[#]["OCRAttempted"]] &)];
      failReasons = DeleteDuplicates @ DeleteCases[
        Map[pageResults[#]["OCRFailReason"] &, pageList],
        Null | False];
      <|
        "Status" -> "OK",
        "SnapshotId" -> snapshotId,
        "Pages" -> textByPage,
        "Hashes" -> hashes,
        "CachedFrom" -> Which[
          fromCacheCount === Length[pageList], "Disk",
          fromCacheCount === 0, "Fresh",
          True, "Mixed"],
        "OCRCalled" -> (ocrCount > 0),
        "OCRUsed" -> ocrCount,
        "OCRAttempted" -> (ocrAttemptedCount > 0),
        "OCRFailReasons" -> failReasons,
        "CacheStats" -> <|
          "TotalPages" -> Length[pageList],
          "FromCache" -> fromCacheCount,
          "Fresh" -> freshCount,
          "OCRAttempted" -> ocrAttemptedCount,
          "OCRUsed" -> ocrCount
        |>,
        "HashesPath" -> iPageHashesPath[snapshotId]
      |>
    ]
  ];


(* ============================================================
   Stage 4 Phase 4C: OCR backends
   - ClaudeVision: ClaudeCode`ClaudeQueryBg \:7d4c\:7531 (PDFIndex \:5b9f\:8a3c\:30d1\:30bf\:30fc\:30f3)
   - TextRecognize: Mathematica \:7d44\:8fbc\:307f (Python \:4e0d\:8981)
   - Custom: \:30e6\:30fc\:30b6\:63d0\:4f9b Function \:3092 hook \:306b\:6ce8\:5165
   ============================================================ *)

(* OCR \:7528 tmp \:30c7\:30a3\:30ec\:30af\:30c8\:30ea (\:81ea\:52d5\:4f5c\:6210) *)
iOCRTmpDir[] :=
  Module[{d},
    d = FileNameJoin[{SourceVault`$SourceVaultRoots["Tmp"], "sourcevault", "ocr"}];
    iEnsureDir[d];
    d
  ];

(* PyMuPDF \:7d4c\:7531\:306e page \[Rule] PNG \:30ec\:30f3\:30c0\:30ea\:30f3\:30b0 (PDFIndex \:30d1\:30bf\:30fc\:30f3\:8e0f\:8972) *)
iRasterizePagePDF$PyMuPDF[rawPath_String, page_Integer, dpi_Integer] :=
  Module[{imgFile, escapedPath, pyCode, result, img},
    imgFile = FileNameJoin[{iOCRTmpDir[],
      "rasterize_" <> IntegerString[Round[AbsoluteTime[] * 1000]] <>
      "_p" <> ToString[page] <> ".png"}];
    escapedPath = StringReplace[rawPath, "\\" -> "/"];
    pyCode = "
import fitz
doc = fitz.open(r'" <> escapedPath <> "')
pix = doc[" <> ToString[page - 1] <> "].get_pixmap(dpi=" <> ToString[dpi] <> ")
pix.save(r'" <> StringReplace[imgFile, "\\" -> "/"] <> "')
doc.close()
'done'
";
    result = Quiet[ExternalEvaluate["Python", pyCode]];
    If[!FileExistsQ[imgFile], Return[$Failed]];
    img = Quiet[Import[imgFile, "PNG"]];
    Quiet[DeleteFile[imgFile]];
    If[ImageQ[img], img, $Failed]
  ];

(* Wolfram native \:306e page \[Rule] Image \:30ec\:30f3\:30c0\:30ea\:30f3\:30b0 (Python \:4e0d\:8981\:306e fallback) *)
iRasterizePagePDF$Native[rawPath_String, page_Integer, dpi_Integer] :=
  Module[{img},
    (* \:65b9\:6cd5 1: PageGraphics *)
    img = Quiet[Import[rawPath, {"PageGraphics", page}]];
    If[Head[img] === Graphics,
      Return[Rasterize[img, ImageResolution -> dpi]]];
    (* \:65b9\:6cd5 2: ImageList *)
    img = Quiet[Import[rawPath, {"ImageList", page}]];
    If[Head[img] === Image, Return[img]];
    $Failed
  ];

(* page \[Rule] Image: PyMuPDF \:512a\:5148\:3001\:4f7f\:3048\:306a\:3051\:308c\:3070 Wolfram native *)
iRasterizePagePDF[rawPath_String, page_Integer, dpi_Integer] :=
  Module[{img},
    img = iRasterizePagePDF$PyMuPDF[rawPath, page, dpi];
    If[ImageQ[img], Return[img]];
    iRasterizePagePDF$Native[rawPath, page, dpi]
  ];

(* \:30c7\:30d5\:30a9\:30eb\:30c8 OCR prompt (\:65e5\:82f1\:5bfe\:5fdc) *)
iDefaultOCRPrompt[] :=
  "\:3053\:308c\:306f PDF \:30da\:30fc\:30b8\:306e\:753b\:50cf\:3067\:3059\:3002\:30da\:30fc\:30b8\:306b\:542b\:307e\:308c\:308b\:5168\:3066\:306e\:30c6\:30ad\:30b9\:30c8\:3092\:6b63\:78ba\:306b\:62bd\:51fa\:3057\:3066\:304f\:3060\:3055\:3044\:3002\n" <>
  "\:8868\:306f\:69cb\:9020\:3092\:4fdd\:6301\:3057\:3001\:6570\:5f0f\:306f LaTeX \:5f62\:5f0f\:3067\:8a18\:8ff0\:3057\:3066\:304f\:3060\:3055\:3044\:3002\n" <>
  "\:8aac\:660e\:3084\:524d\:7f6e\:304d\:306f\:4e0d\:8981\:3001\:62bd\:51fa\:30c6\:30ad\:30b9\:30c8\:306e\:307f\:3092\:51fa\:529b\:3057\:3066\:304f\:3060\:3055\:3044\:3002";

(* === Claude Vision OCR ===
   PDFIndex \:306e iOCRPageWithClaudeVision \:30d1\:30bf\:30fc\:30f3\:3092\:8e0f\:8972:
   - PyMuPDF \:3067 300 DPI \:30ec\:30f3\:30c0\:30ea\:30f3\:30b0
   - SplitHalves -> True \:306a\:3089\:4e0a\:4e0b\:5206\:5272 + 30px overlap
   - ClaudeQueryBg \:7d4c\:7531\:3067\:540c\:671f\:547c\:51fa
   - $iMediaMaxImageSize = 1568 \:3067 Block \:30b5\:30a4\:30ba\:5236\:9650\:4e00\:6642\:62e1\:5927 *)
iOCRViaClaudeVision[req_Association, params_Association] :=
  Module[{rawPath, page, img, dims, halfH, topImg, botImg,
          topText, botText, prompt, timeout, dpi, splitHalves, singleResult,
          verbose, merged, errorMsg},
    dpi = Lookup[params, "DPI", 300];
    splitHalves = TrueQ[Lookup[params, "SplitHalves", True]];
    timeout = Lookup[params, "Timeout", 180];
    prompt = Lookup[params, "Prompt", Automatic];
    If[prompt === Automatic || !StringQ[prompt],
      prompt = iDefaultOCRPrompt[]];
    verbose = TrueQ[If[ValueQ[SourceVault`$SourceVaultOCRVerbose],
      SourceVault`$SourceVaultOCRVerbose, False]];
    errorMsg = "";
    
    rawPath = Lookup[req, "RawPath", ""];
    page = Lookup[req, "Page", 1];
    
    (* ClaudeQueryBg \:5b58\:5728\:78ba\:8a8d *)
    If[Length[Names["ClaudeCode`ClaudeQueryBg"]] === 0,
      If[verbose, Print["[ClaudeVision] ClaudeQueryBg not found"]];
      Return["Error: ClaudeQueryBg not available"]];
    
    If[verbose,
      Print["[ClaudeVision] rasterizing page ", page,
        " at ", dpi, " DPI..."]];
    img = iRasterizePagePDF[rawPath, page, dpi];
    If[!ImageQ[img],
      If[verbose, Print["[ClaudeVision] rasterization FAILED for page ", page]];
      Return["Error: rasterization failed for page " <> ToString[page]]];
    If[verbose,
      Print["[ClaudeVision] rasterized: ", ImageDimensions[img]]];
    
    If[!splitHalves,
      If[verbose, Print["[ClaudeVision] sending whole image to API..."]];
      singleResult = Quiet[
        Block[{ClaudeCode`$iMediaMaxImageSize = 1568},
          ClaudeCode`ClaudeQueryBg[{prompt, img},
            "NonBlocking" -> True, "Timeout" -> timeout]]];
      If[verbose,
        Print["[ClaudeVision] API returned: ",
          Which[
            StringQ[singleResult],
              "String(" <> ToString[StringLength[singleResult]] <> " chars) " <>
              If[StringLength[singleResult] > 0,
                "\"" <> StringTake[singleResult, UpTo[80]] <> "...\"",
                "(empty)"],
            singleResult === $Failed, "$Failed",
            True, ToString[Head[singleResult]]
          ]]];
      Which[
        StringQ[singleResult] && StringStartsQ[singleResult, "Error:"],
          Return[singleResult],   (* \:30a8\:30e9\:30fc\:6587\:5b57\:5217\:3092\:305d\:306e\:307e\:307e\:8fd4\:3059 *)
        !StringQ[singleResult],
          Return["Error: API returned non-string (" <> ToString[Head[singleResult]] <> ")"],
        True,
          Return[StringTrim[singleResult]]
      ]
    ];
    
    (* \:4e0a\:4e0b\:5206\:5272 *)
    dims = ImageDimensions[img];
    halfH = Round[dims[[2]] / 2];
    topImg = ImageTake[img, {1, halfH + 30}];
    botImg = ImageTake[img, {halfH - 30, dims[[2]]}];
    
    If[verbose, Print["[ClaudeVision] OCRing top half..."]];
    topText = Quiet[
      Block[{ClaudeCode`$iMediaMaxImageSize = 1568},
        ClaudeCode`ClaudeQueryBg[{prompt, topImg},
          "NonBlocking" -> True, "Timeout" -> timeout]]];
    If[verbose,
      Print["[ClaudeVision] top returned: ",
        Which[
          StringQ[topText],
            ToString[StringLength[topText]] <> " chars" <>
            If[StringLength[topText] > 0 && StringLength[topText] < 200,
              " = \"" <> topText <> "\"", ""],
          topText === $Failed, "$Failed",
          True, ToString[Head[topText]]
        ]]];
    Which[
      !StringQ[topText],
        errorMsg = "Error: API returned non-string (" <> ToString[Head[topText]] <> ")";
        topText = "",
      StringStartsQ[topText, "Error:"],
        errorMsg = topText;
        topText = ""
    ];
    
    If[verbose, Print["[ClaudeVision] OCRing bottom half..."]];
    botText = Quiet[
      Block[{ClaudeCode`$iMediaMaxImageSize = 1568},
        ClaudeCode`ClaudeQueryBg[{prompt, botImg},
          "NonBlocking" -> True, "Timeout" -> timeout]]];
    If[verbose,
      Print["[ClaudeVision] bottom returned: ",
        Which[
          StringQ[botText],
            ToString[StringLength[botText]] <> " chars" <>
            If[StringLength[botText] > 0 && StringLength[botText] < 200,
              " = \"" <> botText <> "\"", ""],
          botText === $Failed, "$Failed",
          True, ToString[Head[botText]]
        ]]];
    Which[
      !StringQ[botText],
        If[errorMsg === "",
          errorMsg = "Error: API returned non-string (" <> ToString[Head[botText]] <> ")"];
        botText = "",
      StringStartsQ[botText, "Error:"],
        If[errorMsg === "", errorMsg = botText];
        botText = ""
    ];
    
    (* \:30de\:30fc\:30b8: \:4e21\:65b9\:7a7a\:3067\:30a8\:30e9\:30fc\:304c\:3042\:308c\:3070 Error \:6587\:5b57\:5217\:3092\:8fd4\:3059 *)
    merged = StringTrim[topText] <> "\n" <> StringTrim[botText];
    If[StringTrim[merged] === "",
      If[verbose, Print["[ClaudeVision] both halves empty, returning empty"]];
      If[errorMsg =!= "",
        Return[errorMsg],
        Return[""]]];
    merged
  ];

(* === TextRecognize OCR (Mathematica native fallback) === *)
iOCRViaTextRecognize[req_Association, params_Association] :=
  Module[{rawPath, page, img, dpi, lang, text},
    dpi = Lookup[params, "DPI", 150];
    lang = Lookup[params, "Language", "Japanese"];
    rawPath = Lookup[req, "RawPath", ""];
    page = Lookup[req, "Page", 1];
    
    img = iRasterizePagePDF[rawPath, page, dpi];
    If[!ImageQ[img], Return[""]];
    
    text = Quiet[TextRecognize[img, Language -> lang]];
    If[StringQ[text], StringTrim[text], ""]
  ];

(* === SourceVaultOCREnable / Disable / Status === *)

(* \:73fe\:5728\:306e backend (\:8ffd\:8de1\:7528) *)
If[!ValueQ[SourceVault`$SourceVaultOCRBackend],
  SourceVault`$SourceVaultOCRBackend = "Disabled"];

Options[SourceVaultOCREnable] = {
  "DPI" -> 300,
  "SplitHalves" -> True,
  "Timeout" -> 180,
  "Language" -> "Japanese",
  "Prompt" -> Automatic,
  "Hook" -> None,
  "Mode" -> "Auto",
  "Verbose" -> False
};

SourceVaultOCREnable[backend_String:"ClaudeVision", opts:OptionsPattern[]] :=
  Module[{params, customHook, modeOpt, normalizedMode},
    params = Association[FilterRules[{opts}, Options[SourceVaultOCREnable]]];
    
    (* Mode \:306e\:6b63\:898f\:5316 *)
    modeOpt = Lookup[params, "Mode", "Auto"];
    normalizedMode = Which[
      StringQ[modeOpt] && ToLowerCase[modeOpt] === "force", "Force",
      StringQ[modeOpt] && ToLowerCase[modeOpt] === "auto", "Auto",
      True, "Auto"
    ];
    
    (* Verbose \:306e\:8a2d\:5b9a (Option \:3067\:6e21\:3055\:308c\:305f\:3089\:53cd\:6620) *)
    If[KeyExistsQ[params, "Verbose"],
      SourceVault`$SourceVaultOCRVerbose = TrueQ[params["Verbose"]]];
    
    Switch[backend,
      "ClaudeVision",
        (* claudecode.wl \:30ed\:30fc\:30c9\:78ba\:8a8d *)
        If[Length[Names["ClaudeCode`ClaudeQueryBg"]] === 0,
          Return[<|"Status" -> "Failed",
            "Reason" -> "ClaudeQueryBgNotFound",
            "Hint" -> "ClaudeVision backend requires claudecode.wl loaded."|>]];
        SourceVault`$SourceVaultOCRHook = Function[reqAssoc,
          SourceVault`Private`iOCRViaClaudeVision[reqAssoc, params]];
        SourceVault`$SourceVaultOCRBackend = "ClaudeVision";
        SourceVault`$SourceVaultOCRMode = normalizedMode;
        (* Provider \:78ba\:8a8d: vision \:306f anthropic / openai \:306e\:307f\:5bfe\:5fdc\:3001
           claudecode \(CLI\) \:306f\:73fe\:5728\:672a\:5b9f\:88c5 *)
        Module[{currentModel, currentProvider, warning},
          currentModel = If[ValueQ[ClaudeCode`$ClaudeModel],
            ClaudeCode`$ClaudeModel, None];
          currentProvider = Which[
            ListQ[currentModel] && Length[currentModel] >= 1, currentModel[[1]],
            StringQ[currentModel], "anthropic",
            True, "unknown"];
          warning = If[currentProvider === "claudecode",
            "$ClaudeModel uses provider 'claudecode' (CLI) which does NOT support vision. " <>
            "Set $ClaudeModel = {\"anthropic\", \"claude-sonnet-4-20250514\"} (paid) before OCR runs, " <>
            "or use \"TextRecognize\" / \"Custom\" backend.",
            Null];
          <|"Status" -> "Enabled",
            "Backend" -> "ClaudeVision",
            "Mode" -> normalizedMode,
            "Provider" -> currentProvider,
            "Warning" -> warning,
            "Options" -> params|>
        ],
      
      "TextRecognize",
        SourceVault`$SourceVaultOCRHook = Function[reqAssoc,
          SourceVault`Private`iOCRViaTextRecognize[reqAssoc, params]];
        SourceVault`$SourceVaultOCRBackend = "TextRecognize";
        SourceVault`$SourceVaultOCRMode = normalizedMode;
        <|"Status" -> "Enabled",
          "Backend" -> "TextRecognize",
          "Mode" -> normalizedMode,
          "Options" -> params|>,
      
      "Custom",
        customHook = Lookup[params, "Hook", None];
        If[Head[customHook] =!= Function,
          Return[<|"Status" -> "Failed",
            "Reason" -> "CustomRequiresHookFunction",
            "Hint" -> "Pass \"Hook\" -> Function[req, text] for Custom backend."|>]];
        SourceVault`$SourceVaultOCRHook = customHook;
        SourceVault`$SourceVaultOCRBackend = "Custom";
        SourceVault`$SourceVaultOCRMode = normalizedMode;
        <|"Status" -> "Enabled",
          "Backend" -> "Custom",
          "Mode" -> normalizedMode|>,
      
      _,
        <|"Status" -> "Failed",
          "Reason" -> "UnknownBackend: " <> backend,
          "SupportedBackends" -> {"ClaudeVision", "TextRecognize", "Custom"}|>
    ]
  ];

SourceVaultOCRDisable[] :=
  Module[{},
    SourceVault`$SourceVaultOCRHook = None;
    SourceVault`$SourceVaultOCRBackend = "Disabled";
    SourceVault`$SourceVaultOCRMode = "Auto";   (* \:30ea\:30bb\:30c3\:30c8 *)
    <|"Status" -> "Disabled"|>
  ];

SourceVaultOCRStatus[] :=
  <|
    "Backend" -> If[ValueQ[SourceVault`$SourceVaultOCRBackend],
      SourceVault`$SourceVaultOCRBackend, "Disabled"],
    "Mode" -> If[ValueQ[SourceVault`$SourceVaultOCRMode],
      SourceVault`$SourceVaultOCRMode, "Auto"],
    "Verbose" -> TrueQ[If[ValueQ[SourceVault`$SourceVaultOCRVerbose],
      SourceVault`$SourceVaultOCRVerbose, False]],
    "HookSet" -> (Head[SourceVault`$SourceVaultOCRHook] === Function),
    "ClaudeQueryBgAvailable" -> (Length[Names["ClaudeCode`ClaudeQueryBg"]] > 0),
    "PythonAvailable" -> (Length[Names["System`ExternalEvaluate"]] > 0)
  |>;


(* ============================================================
   Stage 5: Claim extraction
   - Schema \:5b9a\:7fa9: SourceVaultRegisterSchema / SourceVaultListSchemas / SourceVaultGetSchema
   - \:62bd\:51fa\:5b9f\:884c: SourceVaultExtract (LLM via ClaudeQueryBg, page text from Phase 4B)
   - ClaimStore: claims/claims.jsonl + by-topic + by-source (JSONL append-only)
   - \:691c\:7d22 API: SourceVaultClaim / SourceVaultClaimsForSource / SourceVaultClaimsForTopic
   ============================================================ *)

(* Extract verbose flag (debug \:7528 LLM \:5fdc\:7b54\:5236\:9650\:8a3a\:65ad) *)
If[!ValueQ[SourceVault`$SourceVaultExtractVerbose],
  SourceVault`$SourceVaultExtractVerbose = False];

(* \:30b9\:30c8\:30ec\:30fc\:30b8\:30d1\:30b9\:30d8\:30eb\:30d1 *)

iClaimsDir[] :=
  Module[{d},
    d = FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "claims"}];
    iEnsureDir[d];
    iEnsureDir[FileNameJoin[{d, "by-topic"}]];
    iEnsureDir[FileNameJoin[{d, "by-source"}]];
    d
  ];

iClaimsMasterPath[] :=
  FileNameJoin[{iClaimsDir[], "claims.jsonl"}];

iClaimsByTopicPath[topic_String] :=
  Module[{safe},
    safe = StringReplace[topic,
      RegularExpression["[^A-Za-z0-9_\\-]"] -> "_"];
    FileNameJoin[{iClaimsDir[], "by-topic", safe <> ".jsonl"}]
  ];

iClaimsBySourcePath[sourceId_String] :=
  FileNameJoin[{iClaimsDir[], "by-source", sourceId <> ".jsonl"}];

(* JSONL append-only \:66f8\:304d\:8fbc\:307f (1 \:884c = 1 \:7570\:308b\:30af\:30ec\:30fc\:30e0\:306e RawJSON) *)
(* claim Association \:3092 JSON \:5316\:524d\:306b\:30b5\:30cb\:30bf\:30a4\:30ba:
   - Missing[...] / DateObject \:7b49\:3092 String \:5316
   - \:975e\:30b5\:30dd\:30fc\:30c8 Head \:3092 ToString \:3067\:6b63\:898f\:5316
*)
iSanitizeForJSON[expr_] :=
  Which[
    AssociationQ[expr],
      Association[KeyValueMap[#1 -> iSanitizeForJSON[#2] &, expr]],
    ListQ[expr],
      Map[iSanitizeForJSON, expr],
    StringQ[expr] || NumericQ[expr] || expr === True || expr === False ||
      expr === Null,
      expr,
    MissingQ[expr],
      Null,
    Head[expr] === DateObject,
      DateString[expr],
    True,
      ToString[expr, InputForm]
  ];

iClaimsAppendJSONL[path_String, claim_Association] :=
  Module[{sanitized, line, strm},
    sanitized = iSanitizeForJSON[claim];
    line = Quiet @ ExportString[sanitized, "RawJSON", "Compact" -> True];
    If[!StringQ[line],
      Return[<|"Status" -> "Failed",
        "Reason" -> "JSONEncodeFailed",
        "Path" -> path|>]];
    iEnsureDir[DirectoryName[path]];
    strm = Quiet[OpenAppend[path, BinaryFormat -> True]];
    If[Head[strm] =!= OutputStream,
      Return[<|"Status" -> "Failed",
        "Reason" -> "OpenAppendFailed",
        "Path" -> path|>]];
    BinaryWrite[strm, StringToByteArray[line <> "\n", "ISO8859-1"]];
    Close[strm];
    <|"Status" -> "OK", "Path" -> path|>
  ];

(* JSONL \:8aad\:307f\:8fbc\:307f: \:5404\:884c\:3092 Association \:306b\:30d1\:30fc\:30b9\:3057\:3001\:30ea\:30b9\:30c8\:3067\:8fd4\:3059 *)
iClaimsLoadJSONL[path_String] :=
  Module[{rawBytes, content, lines, parsed},
    If[!FileExistsQ[path], Return[{}]];
    (* \:30d0\:30a4\:30ca\:30ea\:8aad\:307f\:8fbc\:307f \[Rule] UTF-8 \:30c7\:30b3\:30fc\:30c9 \[Rule] \:884c\:5206\:5272 *)
    rawBytes = Quiet[ReadByteArray[path]];
    If[!ByteArrayQ[rawBytes], Return[{}]];
    content = Quiet[ByteArrayToString[rawBytes, "UTF-8"]];
    If[!StringQ[content], Return[{}]];
    (* CRLF \:307e\:305f\:306f LF \:3067\:5206\:5272 *)
    lines = StringSplit[content, RegularExpression["\\r?\\n"]];
    lines = Select[lines, StringTrim[#] =!= "" &];
    parsed = Map[Function[ln,
      Module[{r = Quiet[ImportString[ln, "RawJSON"]]},
        If[ListQ[r] && !AssociationQ[r], r = Association[r]];
        If[AssociationQ[r], r, Missing["ParseFailed"]]]],
      lines];
    Select[parsed, AssociationQ]
  ];

(* ---------- Stage 6a: dedup helpers ----------
   iLoadClaimHashesForSource: by-source \:30d5\:30a1\:30a4\:30eb\:304b\:3089\:65e2\:5b58 ContentHash \:30bb\:30c3\:30c8 (Association) \:3092\:8fd4\:3059\:3002
   iClaimsAtomicWrite       : tmp \:30d5\:30a1\:30a4\:30eb \[Rule] rename \:306e atomic write\:3002
   iClaimsBackupAll         : master / by-topic / by-source \:5168\:30d5\:30a1\:30a4\:30eb\:3092 .bak.<ts> \:306b\:8907\:88fd\:3002
   iClaimsRewriteAll        : claim list \:3092\:53d7\:3051\:53d6\:308a\:3001\:5168\:30a4\:30f3\:30c7\:30c3\:30af\:30b9 (master+by-topic+by-source)
                              \:3092\:30af\:30ea\:30a2 \[Rule] \:9806\:6b21 append \:3067\:518d\:69cb\:7bc9\:3002
*)

iLoadClaimHashesForSource[sourceId_String] :=
  Module[{path, claims, hashes},
    If[!StringQ[sourceId] || sourceId === "" || sourceId === "unknown",
      Return[<||>]];
    path = iClaimsBySourcePath[sourceId];
    If[!FileExistsQ[path], Return[<||>]];
    claims = iClaimsLoadJSONL[path];
    hashes = Select[
      Map[Lookup[#, "ContentHash", ""] &, claims],
      StringQ[#] && # =!= "" &];
    AssociationThread[hashes, ConstantArray[True, Length[hashes]]]
  ];

iClaimsAtomicWrite[path_String, lines_List] :=
  Module[{tmp, strm, ok = True},
    iEnsureDir[DirectoryName[path]];
    tmp = path <> ".tmp";
    strm = Quiet[OpenWrite[tmp, BinaryFormat -> True]];
    If[Head[strm] =!= OutputStream,
      Return[<|"Status" -> "Failed",
        "Reason" -> "OpenTmpFailed",
        "Path" -> path|>]];
    Scan[
      Function[ln,
        Module[{wr},
          wr = Quiet[BinaryWrite[strm, StringToByteArray[ln <> "\n", "ISO8859-1"]]];
          If[Head[wr] =!= ByteArray && wr =!= Null && !IntegerQ[wr],
            ok = False]
        ]
      ],
      lines];
    Close[strm];
    If[!ok,
      Quiet[DeleteFile[tmp]];
      Return[<|"Status" -> "Failed",
        "Reason" -> "WriteFailed",
        "Path" -> path|>]];
    (* atomic rename: \:65e2\:5b58 path \:306f delete \:3057\:3066\:304b\:3089 RenameFile (Windows \:5bfe\:5fdc) *)
    If[FileExistsQ[path], Quiet[DeleteFile[path]]];
    Quiet[RenameFile[tmp, path]];
    If[!FileExistsQ[path],
      Return[<|"Status" -> "Failed",
        "Reason" -> "RenameFailed",
        "Path" -> path|>]];
    <|"Status" -> "OK", "Path" -> path|>
  ];

iClaimsBackupAll[ts_String] :=
  Module[{dir, masterPath, topicDir, sourceDir, files, backups = {}},
    dir = iClaimsDir[];
    masterPath = iClaimsMasterPath[];
    topicDir = FileNameJoin[{dir, "by-topic"}];
    sourceDir = FileNameJoin[{dir, "by-source"}];
    files = Join[
      If[FileExistsQ[masterPath], {masterPath}, {}],
      If[DirectoryQ[topicDir], FileNames["*.jsonl", topicDir], {}],
      If[DirectoryQ[sourceDir], FileNames["*.jsonl", sourceDir], {}]
    ];
    Scan[Function[p,
      Module[{bak},
        bak = p <> ".bak." <> ts;
        Quiet[CopyFile[p, bak]];
        If[FileExistsQ[bak], AppendTo[backups, bak]]
      ]], files];
    backups
  ];

iClaimsRewriteAll[uniqClaims_List] :=
  Module[{dir, topicDir, sourceDir,
          claimsByTopic, claimsBySource, masterLines, ws,
          errors = {}, masterPath},
    dir = iClaimsDir[];
    topicDir = FileNameJoin[{dir, "by-topic"}];
    sourceDir = FileNameJoin[{dir, "by-source"}];
    masterPath = iClaimsMasterPath[];
    (* by-topic, by-source \:65e2\:5b58\:30d5\:30a1\:30a4\:30eb\:306f truncate (atomic write \:3067\:7a7a\:5185\:5bb9\:7f6e\:63db) *)
    Module[{existingTopic, existingSource},
      existingTopic = If[DirectoryQ[topicDir],
        FileNames["*.jsonl", topicDir], {}];
      existingSource = If[DirectoryQ[sourceDir],
        FileNames["*.jsonl", sourceDir], {}];
      Scan[Function[p, Quiet[DeleteFile[p]]],
        Join[existingTopic, existingSource]]];
    (* claim \:3054\:3068\:306b 1 line JSON \:5316 \[Rule] master \[Rule] topic \[Rule] source \:3078\:632f\:308a\:5206\:3051 *)
    masterLines = {};
    claimsByTopic = <||>;
    claimsBySource = <||>;
    Scan[Function[c,
      Module[{sanitized, line, topic, srcId, ok = True},
        sanitized = iSanitizeForJSON[c];
        line = Quiet @ ExportString[sanitized, "RawJSON",
          "Compact" -> True];
        If[!StringQ[line],
          AppendTo[errors,
            "JSONEncodeFailed for " <>
            ToString[Lookup[c, "ClaimId", "<unknown>"]]];
          ok = False];
        If[ok,
          AppendTo[masterLines, line];
          topic = Lookup[c, "Topic", ""];
          If[StringQ[topic] && topic =!= "",
            claimsByTopic[topic] = Append[
              Lookup[claimsByTopic, topic, {}], line]];
          srcId = Lookup[
            Lookup[c, "SourceSpan", <||>], "SourceId", ""];
          If[StringQ[srcId] && srcId =!= "" && srcId =!= "unknown",
            claimsBySource[srcId] = Append[
              Lookup[claimsBySource, srcId, {}], line]]
        ]
      ]], uniqClaims];
    (* atomic write each *)
    ws = iClaimsAtomicWrite[masterPath, masterLines];
    If[Lookup[ws, "Status", ""] =!= "OK",
      AppendTo[errors, "MasterRewriteFailed: " <>
        ToString[Lookup[ws, "Reason", "Unknown"]]]];
    KeyValueMap[Function[{topic, lns},
      Module[{wsT, p},
        p = iClaimsByTopicPath[topic];
        wsT = iClaimsAtomicWrite[p, lns];
        If[Lookup[wsT, "Status", ""] =!= "OK",
          AppendTo[errors, "TopicRewriteFailed " <> topic]]
      ]], claimsByTopic];
    KeyValueMap[Function[{src, lns},
      Module[{wsS, p},
        p = iClaimsBySourcePath[src];
        wsS = iClaimsAtomicWrite[p, lns];
        If[Lookup[wsS, "Status", ""] =!= "OK",
          AppendTo[errors, "SourceRewriteFailed " <> src]]
      ]], claimsBySource];
    <|"Errors" -> errors,
      "MasterLines" -> Length[masterLines],
      "TopicFiles" -> Length[claimsByTopic],
      "SourceFiles" -> Length[claimsBySource]|>
  ];

(* Claim ID \:751f\:6210: claim-<topic_safe>-<6 hex random> *)
iMakeClaimId[topic_String] :=
  Module[{safeTopic, ts, rnd},
    safeTopic = StringTake[
      StringReplace[topic, RegularExpression["[^A-Za-z0-9]"] -> "-"],
      UpTo[20]];
    ts = ToString[Round[AbsoluteTime[] * 1000]];
    rnd = IntegerString[RandomInteger[{0, 16^6 - 1}], 16, 6];
    "claim-" <> safeTopic <> "-" <> ts <> "-" <> rnd
  ];

(* Claim hash: content \:30cf\:30c3\:30b7\:30e5 (dedup \:8b58\:5225\:7528) *)
iComputeClaimHash[claim_Association] :=
  Module[{key, sanitized, ser, hash},
    key = <|
      "Subject" -> Lookup[claim, "Subject", ""],
      "Predicate" -> Lookup[claim, "Predicate", ""],
      "Object" -> Lookup[claim, "Object", Null],
      "SourceSpan" -> Lookup[claim, "SourceSpan", <||>]
    |>;
    sanitized = iSanitizeForJSON[key];
    ser = Quiet @ ExportString[sanitized, "RawJSON", "Compact" -> True];
    If[!StringQ[ser], Return[""]];
    hash = iComputeSHA256[ser];
    If[StringQ[hash], "sha256-" <> hash, ""]
  ];

(* === Schema Registry === *)

(* Schema \:30b0\:30ed\:30fc\:30d0\:30eb\:30ec\:30b8\:30b9\:30c8\:30ea (Association) *)
If[!ValueQ[SourceVault`$SourceVaultSchemas] ||
   !AssociationQ[SourceVault`$SourceVaultSchemas],
  SourceVault`$SourceVaultSchemas = <||>];

iSchemaRegistry[] := SourceVault`$SourceVaultSchemas;

SourceVaultRegisterSchema[name_String, definition_Association] :=
  Module[{normalized, fields, outputShape},
    fields = Lookup[definition, "Fields", {}];
    outputShape = Lookup[definition, "OutputShape", "List"];
    normalized = <|
      "Name" -> name,
      "Description" -> Lookup[definition, "Description", ""],
      "Fields" -> If[ListQ[fields], fields, {}],
      "OutputShape" -> If[outputShape === "Single", "Single", "List"],
      "PromptTemplate" -> Lookup[definition, "PromptTemplate", Automatic],
      "RegisteredAt" -> DateString[DateObject[]]
    |>;
    SourceVault`$SourceVaultSchemas = Append[
      SourceVault`$SourceVaultSchemas, name -> normalized];
    <|"Status" -> "Registered", "Name" -> name|>
  ];

SourceVaultListSchemas[] :=
  Keys[SourceVault`$SourceVaultSchemas];

SourceVaultGetSchema[name_String] :=
  Lookup[SourceVault`$SourceVaultSchemas, name, Missing["NotRegistered"]];

(* \:30c7\:30d5\:30a9\:30eb\:30c8 schema \:306e\:30ed\:30fc\:30c9 (\:521d\:56de\:30b3\:30fc\:30eb\:6642\:306e\:307f) *)
iRegisterDefaultSchemas[] :=
  Module[{},
    If[!KeyExistsQ[SourceVault`$SourceVaultSchemas, "FreeText"],
      SourceVaultRegisterSchema["FreeText",
        <|"Description" -> "Free-form text claim extraction. Each claim is a self-contained statement supported by the source.",
          "Fields" -> {
            <|"Name" -> "Statement", "Type" -> "String", "Required" -> True,
              "Description" -> "The factual statement extracted from the source"|>,
            <|"Name" -> "Quote", "Type" -> "String", "Required" -> False,
              "Description" -> "Verbatim quote from the source supporting this claim (optional)"|>
          },
          "OutputShape" -> "List"|>]];
    If[!KeyExistsQ[SourceVault`$SourceVaultSchemas, "NumericFacts"],
      SourceVaultRegisterSchema["NumericFacts",
        <|"Description" -> "Extract numeric facts: each fact has a quantity name, numeric value, unit (if any), and context.",
          "Fields" -> {
            <|"Name" -> "Quantity", "Type" -> "String", "Required" -> True,
              "Description" -> "Name of the quantity (e.g., 'initial velocity', 'learning rate')"|>,
            <|"Name" -> "Value", "Type" -> "Number", "Required" -> True,
              "Description" -> "The numeric value"|>,
            <|"Name" -> "Unit", "Type" -> "String", "Required" -> False,
              "Description" -> "Unit of measurement, or null if dimensionless"|>,
            <|"Name" -> "Context", "Type" -> "String", "Required" -> False,
              "Description" -> "Brief context where this fact appears in the source"|>
          },
          "OutputShape" -> "List"|>]];
    If[!KeyExistsQ[SourceVault`$SourceVaultSchemas, "DefinitionList"],
      SourceVaultRegisterSchema["DefinitionList",
        <|"Description" -> "Extract term definitions: each entry has a term and its definition.",
          "Fields" -> {
            <|"Name" -> "Term", "Type" -> "String", "Required" -> True,
              "Description" -> "The term being defined"|>,
            <|"Name" -> "Definition", "Type" -> "String", "Required" -> True,
              "Description" -> "The definition of the term"|>
          },
          "OutputShape" -> "List"|>]];
  ];

(* Schema \:521d\:671f\:5316\:3092\:30d1\:30c3\:30b1\:30fc\:30b8\:30ed\:30fc\:30c9\:6642\:306b\:5b9f\:884c *)
iRegisterDefaultSchemas[];

(* === Extraction prompt builder === *)

iBuildExtractionPrompt[schemaDef_Association, contextText_String] :=
  Module[{userPrompt, fieldsDesc, jsonShape, outputShape, customTpl, fields},
    customTpl = Lookup[schemaDef, "PromptTemplate", Automatic];
    If[StringQ[customTpl] && customTpl =!= "" && customTpl =!= "Automatic",
      Return[
        StringReplace[customTpl, "{CONTEXT}" -> contextText]
      ]];
    
    fields = Lookup[schemaDef, "Fields", {}];
    outputShape = Lookup[schemaDef, "OutputShape", "List"];
    
    fieldsDesc = StringJoin[Riffle[
      MapIndexed[
        Function[{f, idx},
          ToString[First[idx]] <> ". " <>
          Lookup[f, "Name", "field"] <>
          " (" <> Lookup[f, "Type", "String"] <>
          If[TrueQ[Lookup[f, "Required", False]], ", required", ", optional"] <>
          ")" <>
          If[StringQ[Lookup[f, "Description", ""]] && Lookup[f, "Description"] =!= "",
            ": " <> Lookup[f, "Description"], ""]],
        fields],
      "\n"]];
    
    jsonShape = If[outputShape === "Single",
      "{\n" <> StringJoin[Riffle[
        Map[Function[f,
          "  \"" <> Lookup[f, "Name", "field"] <> "\": " <>
          Switch[Lookup[f, "Type", "String"],
            "Number", "<number>",
            "Boolean", "<true|false>",
            "Array", "<array>",
            _, "<string>"]],
          fields],
        ",\n"]] <> "\n}",
      "[\n  {\n" <> StringJoin[Riffle[
        Map[Function[f,
          "    \"" <> Lookup[f, "Name", "field"] <> "\": " <>
          Switch[Lookup[f, "Type", "String"],
            "Number", "<number>",
            "Boolean", "<true|false>",
            "Array", "<array>",
            _, "<string>"]],
          fields],
        ",\n"]] <> "\n  },\n  ...\n]"
    ];
    
    StringJoin[
      "You are extracting structured claims from a source document. ",
      "Read the SOURCE TEXT below and extract claims according to the SCHEMA.\n\n",
      "## SCHEMA: ", Lookup[schemaDef, "Name", "Unknown"], "\n",
      Lookup[schemaDef, "Description", ""], "\n\n",
      "Fields to extract per claim:\n", fieldsDesc, "\n\n",
      "## OUTPUT FORMAT\n",
      "Respond with ONLY a JSON ",
      If[outputShape === "Single", "object", "array"],
      " (no prose, no markdown code fences). Schema:\n", jsonShape, "\n\n",
      "If no claims can be extracted, respond with ",
      If[outputShape === "Single", "null", "[]"], ".\n\n",
      "## SOURCE TEXT\n", contextText
    ]
  ];

(* === Extractor LLM caller === *)

iCallExtractorLLM[prompt_String, timeout_:180] :=
  Module[{resp, verbose, t0, elapsed},
    verbose = TrueQ[If[ValueQ[SourceVault`$SourceVaultExtractVerbose],
      SourceVault`$SourceVaultExtractVerbose, False]];
    
    If[Length[Names["ClaudeCode`ClaudeQueryBg"]] === 0,
      Return[<|"Status" -> "Failed",
        "Reason" -> "ClaudeQueryBgNotAvailable"|>]];
    
    If[verbose,
      Print["[SourceVaultExtract] calling ClaudeQueryBg with prompt of ",
        StringLength[prompt], " chars (timeout=", timeout, "s)..."]];
    t0 = AbsoluteTime[];
    resp = Quiet[
      ClaudeCode`ClaudeQueryBg[prompt,
        "NonBlocking" -> True, "Timeout" -> timeout]];
    elapsed = Round[AbsoluteTime[] - t0, 0.1];
    
    If[verbose,
      Print["[SourceVaultExtract] response in ", elapsed, "s: ",
        Which[
          StringQ[resp],
            "String(" <> ToString[StringLength[resp]] <> " chars)" <>
            If[StringLength[resp] < 200,
              " = \"" <> resp <> "\"", ""],
          resp === $Failed, "$Failed",
          True, ToString[Head[resp]]
        ]]];
    
    Which[
      !StringQ[resp],
        <|"Status" -> "Failed",
          "Reason" -> "NonStringResponse",
          "Head" -> ToString[Head[resp]]|>,
      StringStartsQ[resp, "Error:"],
        <|"Status" -> "Failed",
          "Reason" -> "LLMError",
          "Message" -> StringTake[resp, UpTo[300]]|>,
      True,
        <|"Status" -> "OK", "Response" -> resp, "Elapsed" -> elapsed|>
    ]
  ];

(* === JSON response parser ===
   LLM \:5fdc\:7b54\:304b\:3089 JSON \:90e8\:5206\:3092\:62bd\:51fa\:3057\:3066\:30d1\:30fc\:30b9\:3002
   markdown code fence (```json ... ```) \:306b\:5305\:307e\:308c\:3066\:3044\:308b\:5834\:5408\:3082\:9664\:53bb\:3002
   \:524d\:5f8c\:306b\:89e3\:8aac\:6587\:304c\:4ed8\:3044\:3066\:3044\:308b\:5834\:5408\:306f\:3001bracket counting \:3067 [...] / {...} \:3092\:5207\:308a\:51fa\:3059\:3002
   \:5fdc\:7b54\:304c\:9014\:4e2d\:3067\:5207\:308c\:3066\:3044\:308b\:5834\:5408\:306f\:3001\:90e8\:5206\:7684\:306b\:30d1\:30fc\:30b9\:3057\:3066\:6709\:52b9\:306a\:8981\:7d20\:3060\:3051\:5fa9\:65e7\:3059\:308b\:3002 *)

(* Bracket counting: \:6700\:521d\:306e [ or { \:304b\:3089\:5b8c\:5168\:306b\:9589\:3058\:308b\:307e\:3067 substring \:3092\:8fd4\:3059\:3002
   \:6587\:5b57\:5217\:5185\:306e bracket \:306f\:7121\:8996\:3002\:9014\:4e2d\:3067\:5207\:308c\:3066\:3044\:308b\:5834\:5408\:306f Missing \:3092\:8fd4\:3059\:3002 *)
iExtractFirstJSONBlock[text_String] :=
  Module[{posBrack, posBrace, startPos, openCh, closeCh,
          chars, n, depth, inStr, esc, ch, result},
    posBrack = StringPosition[text, "[", 1];
    posBrace = StringPosition[text, "{", 1];
    Which[
      Length[posBrack] > 0 && Length[posBrace] > 0,
        If[posBrack[[1, 1]] < posBrace[[1, 1]],
          startPos = posBrack[[1, 1]]; openCh = "["; closeCh = "]",
          startPos = posBrace[[1, 1]]; openCh = "{"; closeCh = "}"],
      Length[posBrack] > 0,
        startPos = posBrack[[1, 1]]; openCh = "["; closeCh = "]",
      Length[posBrace] > 0,
        startPos = posBrace[[1, 1]]; openCh = "{"; closeCh = "}",
      True,
        Return[Missing["NoBracket"]]
    ];
    
    chars = Characters[text];
    n = Length[chars];
    depth = 0;
    inStr = False;
    esc = False;
    result = Missing["Truncated"];
    
    Catch[
      Do[
        ch = chars[[i]];
        If[inStr,
          If[esc, esc = False,
            If[ch === "\\", esc = True,
              If[ch === "\"", inStr = False]]],
          Which[
            ch === "\"", inStr = True,
            ch === openCh, depth = depth + 1,
            ch === closeCh,
              depth = depth - 1;
              If[depth === 0,
                result = StringTake[text, {startPos, i}];
                Throw[Null]]
          ]],
        {i, startPos, n}]
    ];
    result
  ];

(* Truncated \:914d\:5217\:304b\:3089\:300c\:5b8c\:5168\:306a object\:300d\:3060\:3051\:62fe\:3046 fallback\:3002 *)
iRecoverPartialJSONArray[text_String] :=
  Module[{posStart, startIdx, chars, depth, inStr, esc, n, ch,
          objStart, objStrings, parsed},
    posStart = StringPosition[text, "[", 1];
    If[!ListQ[posStart] || Length[posStart] === 0, Return[{}]];
    startIdx = posStart[[1, 1]] + 1;
    
    chars = Characters[text];
    n = Length[chars];
    objStrings = {};
    depth = 0;
    inStr = False;
    esc = False;
    objStart = 0;
    
    Do[
      ch = chars[[i]];
      If[inStr,
        If[esc, esc = False,
          If[ch === "\\", esc = True,
            If[ch === "\"", inStr = False]]],
        Which[
          ch === "\"", inStr = True,
          ch === "{",
            If[depth === 0, objStart = i];
            depth = depth + 1,
          ch === "}",
            depth = depth - 1;
            If[depth === 0 && objStart > 0,
              AppendTo[objStrings, StringTake[text, {objStart, i}]];
              objStart = 0]
        ]],
      {i, startIdx, n}
    ];
    
    parsed = Map[Function[s, Quiet[ImportString[s, "RawJSON"]]], objStrings];
    parsed = Select[parsed,
      AssociationQ[#] || (ListQ[#] && AllTrue[#, RuleQ]) &];
    parsed = Map[If[AssociationQ[#], #, Association[#]] &, parsed];
    parsed
  ];

iParseExtractionJSON[respText_String, outputShape_String] :=
  Module[{cleaned, parsed, fenceMatch, jsonBlock, recovered},
    cleaned = StringTrim[respText];
    
    (* 1. code fence \:9664\:53bb *)
    fenceMatch = StringCases[cleaned,
      RegularExpression["(?s)```(?:json)?\\s*(.+?)\\s*```"] :> "$1"];
    If[Length[fenceMatch] > 0, cleaned = First[fenceMatch]];
    cleaned = StringTrim[cleaned];
    
    (* 2. \:7a7a\:7d50\:679c\:30b7\:30b0\:30ca\:30eb *)
    If[cleaned === "[]" || cleaned === "null" || cleaned === "",
      Return[<|"Status" -> "OK", "Items" -> {}|>]];
    
    (* 3. \:307e\:305a\:3001\:3068\:308a\:3042\:3048\:305a\:5168\:4f53\:3092\:30d1\:30fc\:30b9\:3057\:3066\:307f\:308b *)
    parsed = Quiet[ImportString[cleaned, "RawJSON"]];
    
    (* 4. \:5931\:6557\:3057\:305f\:3089 bracket extraction \:3092\:8a66\:3059 *)
    If[parsed === $Failed,
      jsonBlock = iExtractFirstJSONBlock[cleaned];
      If[StringQ[jsonBlock],
        parsed = Quiet[ImportString[jsonBlock, "RawJSON"]]
      ];
    ];
    
    (* 5. \:307e\:3060\:5931\:6557\:3057\:3066\:3044\:308b\:5834\:5408\:306f\:3001\:90e8\:5206\:30ea\:30ab\:30d0\:30ea\:3092\:8a66\:3059 (truncated \:914d\:5217) *)
    If[parsed === $Failed,
      recovered = iRecoverPartialJSONArray[cleaned];
      If[ListQ[recovered] && Length[recovered] > 0,
        Return[<|"Status" -> "OK",
          "Items" -> recovered,
          "Note" -> "PartialRecovery: " <> ToString[Length[recovered]] <> " object(s) recovered from truncated response"|>]
      ]];
    
    If[parsed === $Failed,
      Return[<|"Status" -> "Failed",
        "Reason" -> "JSONParseFailed",
        "Sample" -> StringTake[cleaned, UpTo[400]],
        "FullLength" -> StringLength[cleaned]|>]];
    
    (* 6. outputShape \:306b\:5408\:308f\:305b\:308b *)
    Which[
      outputShape === "Single",
        If[AssociationQ[parsed] || (ListQ[parsed] && AllTrue[parsed, RuleQ]),
          If[AssociationQ[parsed], parsed = parsed, parsed = Association[parsed]];
          <|"Status" -> "OK", "Items" -> {parsed}|>,
          <|"Status" -> "Failed", "Reason" -> "ExpectedObject"|>],
      True,
        If[ListQ[parsed],
          parsed = Map[Function[item,
            If[ListQ[item] && AllTrue[item, RuleQ],
              Association[item], item]], parsed];
          parsed = Select[parsed, AssociationQ];
          <|"Status" -> "OK", "Items" -> parsed|>,
          If[AssociationQ[parsed],
            <|"Status" -> "OK", "Items" -> {parsed}|>,
            <|"Status" -> "Failed", "Reason" -> "ExpectedArray"|>]]
    ]
  ];

(* === Claim \:6b63\:898f\:5316 === *)

iNormalizeClaim[item_Association, ctx_Association] :=
  Module[{claimId, topic, sourceSpan, claim, hash},
    topic = Lookup[ctx, "Topic", "Generic"];
    claimId = iMakeClaimId[topic];
    sourceSpan = Lookup[ctx, "SourceSpan", <||>];
    
    claim = <|
      "ClaimId" -> claimId,
      "Topic" -> topic,
      "Schema" -> Lookup[ctx, "SchemaName", "Unknown"],
      "Fields" -> item,
      "Subject" -> Lookup[item, "Subject", Lookup[item, "Term",
        Lookup[item, "Quantity", Lookup[item, "Statement", ""]]]],
      "Predicate" -> Lookup[ctx, "SchemaName", "Generic"],
      "Object" -> item,
      "SourceSpan" -> sourceSpan,
      "ExtractionMethod" -> "LLM",
      "Extractor" -> <|
        "SchemaName" -> Lookup[ctx, "SchemaName", "Unknown"],
        "ModelIntent" -> Lookup[ctx, "ModelIntent", "extraction"]
      |>,
      "Confidence" -> Lookup[item, "Confidence", 0.7],
      "ValidationStatus" -> "Unreviewed",
      "ObservedAt" -> DateString[DateObject[]]
    |>;
    hash = iComputeClaimHash[claim];
    claim["ContentHash"] = hash;
    claim
  ];

(* === Claim \:6700\:5c0f\:30d0\:30ea\:30c7\:30fc\:30b7\:30e7\:30f3 === *)

iValidateClaim[claim_Association, schemaDef_Association] :=
  Module[{fields, requiredFields, item, missing},
    fields = Lookup[schemaDef, "Fields", {}];
    requiredFields = Cases[fields,
      f_Association /; TrueQ[Lookup[f, "Required", False]] :>
        Lookup[f, "Name", ""]];
    item = Lookup[claim, "Fields", <||>];
    If[!AssociationQ[item], Return[<|"Valid" -> False, "Reason" -> "FieldsNotAssoc"|>]];
    missing = Select[requiredFields,
      !KeyExistsQ[item, #] || item[#] === "" || item[#] === Null &];
    If[Length[missing] > 0,
      <|"Valid" -> False, "Reason" -> "MissingRequiredFields",
        "MissingFields" -> missing|>,
      <|"Valid" -> True|>]
  ];

(* === SourceVaultExtract \:672c\:4f53 === *)

Options[SourceVaultExtract] = {
  "Topic" -> Automatic,
  "ModelIntent" -> "extraction",
  "StoreClaims" -> True,
  "Dedup" -> True,
  "Validation" -> "None",
  "AuthorizationCheck" -> True,
  MaxCharacters -> 8000,
  Timeout -> 180
};

SourceVaultExtract[sourceSpan_, schemaArg_, opts:OptionsPattern[]] :=
  Module[{schemaDef, schemaName, span, spanResolved, ctxResult, contextText,
          prompt, llmResult, parseResult, items, claims, topic,
          storeClaims, validation, validationRes, errors = {},
          maxChars, timeoutVal, sourceIdForIndex, snapshotIdForSpan,
          dedupEnabled, extractedCount, dedupSkipped = 0, verbose,
          authCheck, spanObjSpec, sendDecision, persistDecision,
          accessDecisions = <||>, spanSnapId, spanSnapMeta},
    iEnsureRoots[];
    storeClaims = TrueQ[OptionValue["StoreClaims"]];
    dedupEnabled = TrueQ[OptionValue["Dedup"]];
    authCheck = TrueQ[OptionValue["AuthorizationCheck"]];
    validation = OptionValue["Validation"];
    maxChars = OptionValue[MaxCharacters];
    timeoutVal = OptionValue[Timeout];
    verbose = TrueQ[If[ValueQ[SourceVault`$SourceVaultExtractVerbose],
      SourceVault`$SourceVaultExtractVerbose, False]];
    
    (* 1. Schema \:89e3\:6c7a *)
    Which[
      StringQ[schemaArg],
        schemaName = schemaArg;
        schemaDef = SourceVaultGetSchema[schemaName];
        If[MissingQ[schemaDef],
          Return[<|"Status" -> "Failed",
            "Reason" -> "SchemaNotRegistered",
            "Schema" -> schemaName,
            "AvailableSchemas" -> SourceVaultListSchemas[]|>]],
      AssociationQ[schemaArg],
        schemaDef = schemaArg;
        schemaName = Lookup[schemaDef, "Name", "Inline"],
      True,
        Return[<|"Status" -> "Failed",
          "Reason" -> "InvalidSchemaArg",
          "Hint" -> "Pass schema name (String) or schema Association."|>]
    ];
    
    (* 2. Topic \:6c7a\:5b9a *)
    topic = OptionValue["Topic"];
    If[topic === Automatic || !StringQ[topic],
      topic = schemaName];
    
    (* 3. SourceSpan \:6b63\:898f\:5316: String \:306a\:3089 SourceVaultSpan \:3067\:62fc\:3052\:308b *)
    span = Which[
      AssociationQ[sourceSpan], sourceSpan,
      StringQ[sourceSpan], SourceVaultSpan[sourceSpan],
      True,
        Return[<|"Status" -> "Failed",
          "Reason" -> "InvalidSourceSpan"|>]
    ];
    
    (* Stage 6d: 3b. sendDecision \[LongDash] LLM \:306b source span \:3092\:9001\:308b\:524d\:306b NBAuthorize \:3092\:547c\:3076 *)
    If[authCheck,
      spanSnapId = Lookup[span, "SnapshotId", ""];
      If[StringQ[spanSnapId] && spanSnapId =!= "",
        spanSnapMeta = iSnapshotMetaLoad[spanSnapId];
        If[AssociationQ[spanSnapMeta],
          spanObjSpec = iSpecFromSnapshotMeta[spanSnapMeta];
          sendDecision = iCallNBAuthorize[
            spanObjSpec,
            <|"Action" -> "ExtractClaim",
              "Schema" -> schemaName,
              "Topic" -> topic,
              "Purpose" -> "ClaimExtraction",
              "Sink" -> "CloudLLM"|>];
          accessDecisions["Send"] = sendDecision;
          If[verbose,
            Print["[SourceVaultExtract] sendDecision: ",
              Lookup[sendDecision, "Decision", "<unknown>"]]];
          Switch[Lookup[sendDecision, "Decision", "Deny"],
            "Permit" | "Screen", Null,  (* \:7d9a\:884c\:3002Screen \:306f Phase 1 \:3067\:306f Permit \:3068\:540c\:7b49\:6271\:3044 *)
            "RequireApproval",
              Return[<|"Status" -> "RequiresApproval",
                "Reason" -> "sendDecision: RequireApproval",
                "AccessDecisions" -> accessDecisions|>],
            _,
              Return[<|"Status" -> "DeniedByNBAccess",
                "Reason" -> "sendDecision: " <>
                  ToString[Lookup[sendDecision, "Decision", "Deny"]],
                "ReasonClass" -> Lookup[sendDecision, "ReasonClass", ""],
                "AccessDecisions" -> accessDecisions|>]
          ]]]];
    
    (* 4. Context \:53d6\:5f97 (SourceVaultContext \:7d4c\:7531 = Phase 4B cache \:6709\:52b9) *)
    ctxResult = SourceVaultContext[span,
      MaxCharacters -> maxChars,
      "Purpose" -> "ClaimExtraction"];
    If[Lookup[ctxResult, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> "ContextRetrievalFailed",
        "ContextResult" -> ctxResult,
        "AccessDecisions" -> accessDecisions|>]];
    contextText = Lookup[ctxResult, "Text", ""];
    If[!StringQ[contextText] || StringTrim[contextText] === "",
      Return[<|"Status" -> "Failed",
        "Reason" -> "EmptyContext"|>]];
    
    (* 5. Prompt \:69cb\:7bc9 + LLM \:547c\:51fa *)
    prompt = iBuildExtractionPrompt[schemaDef, contextText];
    llmResult = iCallExtractorLLM[prompt, timeoutVal];
    If[Lookup[llmResult, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> "LLMCallFailed",
        "LLMResult" -> llmResult|>]];
    
    (* 6. JSON \:30d1\:30fc\:30b9 *)
    parseResult = iParseExtractionJSON[
      llmResult["Response"],
      Lookup[schemaDef, "OutputShape", "List"]];
    If[Lookup[parseResult, "Status", ""] =!= "OK",
      Module[{rawResp = llmResult["Response"]},
        Return[<|"Status" -> "Failed",
          "Reason" -> "ParseFailed",
          "ParseResult" -> parseResult,
          "RawResponseLength" -> StringLength[rawResp],
          "RawResponseHead" -> StringTake[rawResp, UpTo[1500]],
          "RawResponseTail" -> If[StringLength[rawResp] > 1500,
            StringTake[rawResp, -Min[1500, StringLength[rawResp]]],
            ""]|>]
      ]];
    items = Lookup[parseResult, "Items", {}];
    
    (* 7. Claim \:5316 *)
    Module[{ctx, pagesVal, snapVal, srcVal},
      pagesVal = Lookup[span, "Pages", Null];
      If[MissingQ[pagesVal] || pagesVal === Automatic, pagesVal = Null];
      snapVal = Lookup[span, "SnapshotId", Null];
      If[MissingQ[snapVal], snapVal = Null];
      srcVal = Lookup[span, "SourceId", Null];
      If[MissingQ[srcVal], srcVal = Null];
      ctx = <|
        "Topic" -> topic,
        "SchemaName" -> schemaName,
        "ModelIntent" -> OptionValue["ModelIntent"],
        "SourceSpan" -> <|
          "SnapshotId" -> snapVal,
          "SourceId" -> srcVal,
          "Pages" -> pagesVal
        |>
      |>;
      claims = Map[iNormalizeClaim[#, ctx] &, items]];
    
    (* 8. Validation *)
    If[validation === "Required",
      validationRes = Map[iValidateClaim[#, schemaDef] &, claims];
      Module[{invalid},
        invalid = Pick[claims, validationRes,
          v_Association /; !TrueQ[Lookup[v, "Valid", False]]];
        If[Length[invalid] > 0,
          errors = Join[errors,
            {"Validation failed for " <> ToString[Length[invalid]] <> " claim(s)"}];
          claims = Pick[claims, validationRes,
            v_Association /; TrueQ[Lookup[v, "Valid", False]]]]
      ]];
    
    (* Stage 6a: extractedCount \:306f LLM \:751f\:62bd\:51fa\:6570 (dedup \:524d) *)
    extractedCount = Length[claims];
    
    (* Stage 6d: persistDecision \[LongDash] \:62bd\:51fa\:3055\:308c\:305f claim \:3092\:4fdd\:5b58\:3057\:3066\:3088\:3044\:304b NBAuthorize \:3092\:547c\:3076\:3002
       \:4ed5\:69d8\:66f8 \[Section] 14.4.2: 1 \:3064\:3067\:3082\:4ee3\:8868 claim \:3067 NBAuthorize \:3092\:547c\:3093\:3067 batch \:5224\:5b9a\:3059\:308b *)
    If[authCheck && storeClaims && Length[claims] > 0,
      Module[{claimObj},
        claimObj = iSpecFromClaim[First[claims]];
        persistDecision = iCallNBAuthorize[
          claimObj,
          <|"Action" -> "PersistClaim",
            "Schema" -> schemaName,
            "Topic" -> topic,
            "Purpose" -> "ClaimStore",
            "Sink" -> "LocalKernel"|>];
        accessDecisions["Persist"] = persistDecision;
        If[verbose,
          Print["[SourceVaultExtract] persistDecision: ",
            Lookup[persistDecision, "Decision", "<unknown>"]]];
        Switch[Lookup[persistDecision, "Decision", "Deny"],
          "Permit" | "Screen", Null,  (* \:7d9a\:884c *)
          "RequireApproval",
            Return[<|"Status" -> "RequiresApproval",
              "Reason" -> "persistDecision: RequireApproval",
              "Claims" -> claims,
              "Count" -> 0,
              "ExtractedCount" -> extractedCount,
              "DedupSkipped" -> 0,
              "AccessDecisions" -> accessDecisions|>],
          _,
            Return[<|"Status" -> "DeniedByNBAccess",
              "Reason" -> "persistDecision: " <>
                ToString[Lookup[persistDecision, "Decision", "Deny"]],
              "ReasonClass" -> Lookup[persistDecision, "ReasonClass", ""],
              "Claims" -> claims,
              "Count" -> 0,
              "ExtractedCount" -> extractedCount,
              "DedupSkipped" -> 0,
              "AccessDecisions" -> accessDecisions|>]
        ]
      ]];
    
    (* 9. Store \:5230 ClaimStore *)
    If[storeClaims && Length[claims] > 0,
      snapshotIdForSpan = Lookup[span, "SnapshotId", Missing[]];
      sourceIdForIndex = Which[
        StringQ[Lookup[span, "SourceId", ""]] &&
          Lookup[span, "SourceId", ""] =!= "",
          Lookup[span, "SourceId"],
        StringQ[snapshotIdForSpan],
          (* snapshot \:304b\:3089 source \:3092\:9006\:5f15\:304d *)
          Module[{meta},
            meta = iSnapshotMetaLoad[snapshotIdForSpan];
            If[AssociationQ[meta],
              Lookup[meta, "SourceId", snapshotIdForSpan],
              snapshotIdForSpan]],
        True, "unknown"];
      
      (* Stage 6a: dedup \:30d5\:30a3\:30eb\:30bf (by-source \:30d5\:30a1\:30a4\:30eb\:5358\:4f4d) *)
      If[dedupEnabled,
        Module[{existingHashes, keep},
          existingHashes = iLoadClaimHashesForSource[sourceIdForIndex];
          keep = Select[claims, Function[c,
            Module[{h = Lookup[c, "ContentHash", ""]},
              !(StringQ[h] && h =!= "" &&
                KeyExistsQ[existingHashes, h])]]];
          dedupSkipped = Length[claims] - Length[keep];
          claims = keep;
          If[verbose && dedupSkipped > 0,
            Print["[SourceVaultExtract] Dedup: ", dedupSkipped,
              " claim(s) skipped (already in by-source/",
              sourceIdForIndex, ".jsonl)"]]
        ]];
      
      Scan[Function[c,
        Module[{r},
          r = iClaimsAppendJSONL[iClaimsMasterPath[], c];
          If[!AssociationQ[r] || Lookup[r, "Status", ""] =!= "OK",
            AppendTo[errors,
              "Failed to append to master: " <>
              ToString[Lookup[r, "Reason", "Unknown"]]]];
          r = iClaimsAppendJSONL[iClaimsByTopicPath[topic], c];
          If[!AssociationQ[r] || Lookup[r, "Status", ""] =!= "OK",
            AppendTo[errors,
              "Failed to append to topic index: " <>
              ToString[Lookup[r, "Reason", "Unknown"]]]];
          If[StringQ[sourceIdForIndex] && sourceIdForIndex =!= "unknown",
            r = iClaimsAppendJSONL[iClaimsBySourcePath[sourceIdForIndex], c];
            If[!AssociationQ[r] || Lookup[r, "Status", ""] =!= "OK",
              AppendTo[errors,
                "Failed to append to source index: " <>
                ToString[Lookup[r, "Reason", "Unknown"]]]]]
        ]],
        claims]];
    
    <|
      "Status" -> "OK",
      "SchemaName" -> schemaName,
      "Topic" -> topic,
      "Claims" -> claims,
      "Count" -> Length[claims],
      "ExtractedCount" -> extractedCount,
      "DedupSkipped" -> dedupSkipped,
      "ValidationStatus" -> Which[
        validation === "Required" && Length[errors] === 0, "Validated",
        validation === "Required", "PartiallyValidated",
        True, "Unreviewed"],
      "ExtractedAt" -> DateString[DateObject[]],
      "Errors" -> errors,
      "AccessDecisions" -> accessDecisions,
      "BundleId" -> Missing["NotCreated"]
    |>
  ];

(* === Claim retrieval === *)

SourceVaultClaim[claimId_String] :=
  Module[{all, hit},
    iEnsureRoots[];
    all = iClaimsLoadJSONL[iClaimsMasterPath[]];
    hit = SelectFirst[all,
      Lookup[#, "ClaimId", ""] === claimId &, Missing["NotFound"]];
    hit
  ];

SourceVaultClaimsForTopic[topic_String] :=
  (iEnsureRoots[];
   iClaimsLoadJSONL[iClaimsByTopicPath[topic]]);

SourceVaultClaimsForSource[sourceIdOrSnap_String] :=
  Module[{key, meta},
    iEnsureRoots[];
    key = If[StringStartsQ[sourceIdOrSnap, "snap-"],
      meta = iSnapshotMetaLoad[sourceIdOrSnap];
      If[AssociationQ[meta],
        Lookup[meta, "SourceId", sourceIdOrSnap], sourceIdOrSnap],
      sourceIdOrSnap];
    iClaimsLoadJSONL[iClaimsBySourcePath[key]]
  ];

(* Debug \:30d8\:30eb\:30d1\:30fc: claim store \:306e\:72b6\:614b\:3092\:8fd4\:3059 *)
SourceVaultClaimStoreStatus[] :=
  Module[{masterPath, masterExists, masterLines, byTopicDir, bySourceDir,
          topicFiles, sourceFiles},
    iEnsureRoots[];
    masterPath = iClaimsMasterPath[];
    masterExists = FileExistsQ[masterPath];
    masterLines = If[masterExists,
      Length[iClaimsLoadJSONL[masterPath]], 0];
    byTopicDir = FileNameJoin[{iClaimsDir[], "by-topic"}];
    bySourceDir = FileNameJoin[{iClaimsDir[], "by-source"}];
    topicFiles = If[DirectoryQ[byTopicDir],
      FileNames["*.jsonl", byTopicDir], {}];
    sourceFiles = If[DirectoryQ[bySourceDir],
      FileNames["*.jsonl", bySourceDir], {}];
    <|
      "ClaimsDir" -> iClaimsDir[],
      "MasterPath" -> masterPath,
      "MasterExists" -> masterExists,
      "MasterClaims" -> masterLines,
      "TopicFiles" -> Map[FileNameTake, topicFiles],
      "SourceFiles" -> Map[FileNameTake, sourceFiles]
    |>
  ];

(* === Stage 6a: ClaimStore Compact ===
   - master \:5168\:8aad\:307f \[Rule] ContentHash \:30ad\:30fc\:3067 DeleteDuplicatesBy
   - dedup \:6642\:306f\:6700\:53e4\:306e\:884c (master \:5148\:982d\:306b\:8fd1\:3044\:65b9) \:3092\:6b8b\:3059
   - by-topic, by-source \:306f master \:304b\:3089\:518d\:5206\:914d
   - DryRun: \:7d71\:8a08\:306e\:307f\:8fd4\:3059
   - Backup: True \:306a\:3089 .bak.<ts> \:5168\:30d5\:30a1\:30a4\:30eb\:8907\:88fd
*)

Options[SourceVaultClaimStoreCompact] = {
  "Backup" -> True,
  "DryRun" -> False
};

SourceVaultClaimStoreCompact[opts:OptionsPattern[]] :=
  Module[{masterPath, all, beforeCount, dedupedRev, deduped, afterCount,
          removed, doBackup, dryRun, ts, backups = {},
          rewriteResult, errors = {}},
    iEnsureRoots[];
    doBackup = TrueQ[OptionValue["Backup"]];
    dryRun = TrueQ[OptionValue["DryRun"]];
    masterPath = iClaimsMasterPath[];
    If[!FileExistsQ[masterPath],
      Return[<|"Status" -> "OK",
        "BeforeCount" -> 0, "AfterCount" -> 0, "Removed" -> 0,
        "BackupPaths" -> {}, "DryRun" -> dryRun,
        "Reason" -> "MasterEmpty"|>]];
    all = iClaimsLoadJSONL[masterPath];
    beforeCount = Length[all];
    
    (* dedup: \:6700\:53e4\:306e\:884c\:3092\:6b8b\:3059\:305f\:3081\:306b\:3001Reverse \[Rule] DeleteDuplicates \[Rule] Reverse *)
    dedupedRev = DeleteDuplicatesBy[Reverse[all],
      Lookup[#, "ContentHash", ToString[Lookup[#, "ClaimId", ""]]] &];
    deduped = Reverse[dedupedRev];
    afterCount = Length[deduped];
    removed = beforeCount - afterCount;
    
    If[dryRun,
      Return[<|"Status" -> "OK",
        "BeforeCount" -> beforeCount,
        "AfterCount" -> afterCount,
        "Removed" -> removed,
        "BackupPaths" -> {},
        "DryRun" -> True,
        "Errors" -> {}|>]];
    
    If[removed === 0,
      Return[<|"Status" -> "OK",
        "BeforeCount" -> beforeCount,
        "AfterCount" -> afterCount,
        "Removed" -> 0,
        "BackupPaths" -> {},
        "DryRun" -> False,
        "Reason" -> "NoDuplicates",
        "Errors" -> {}|>]];
    
    (* Backup *)
    ts = DateString["ISODateTime", "DateSeparator" -> "",
      "TimeSeparator" -> ""];
    If[doBackup,
      backups = iClaimsBackupAll[ts]];
    
    (* Rewrite atomic *)
    rewriteResult = iClaimsRewriteAll[deduped];
    errors = Lookup[rewriteResult, "Errors", {}];
    
    <|"Status" -> If[Length[errors] === 0, "OK", "PartialFailure"],
      "BeforeCount" -> beforeCount,
      "AfterCount" -> afterCount,
      "Removed" -> removed,
      "BackupPaths" -> backups,
      "DryRun" -> False,
      "Errors" -> errors,
      "RewriteResult" -> rewriteResult|>
  ];


(* ============================================================
   Stage 6c: Evidence Bundle
   - generated artifact \:306e\:4f9d\:5b58 (source / snapshot / claim / generator) \:3092
     bundle \:3068\:3057\:3066 PrivateVault/bundles/<bundleId>.json \:306b\:4fdd\:5b58
   - SourceVaultBundleStatus \:306f snapshot LifecycleStatus \:3092\:96c6\:7d04\:3057\:3066
     bundle \:306e\:73fe\:5728 status \:3092\:8a08\:7b97 (Current/Stale/NeedsReview/Invalidated)
   - \:624b\:52d5 invalidate \:306f bundle JSON \:5185\:306b ManualInvalidation \:30d5\:30a3\:30fc\:30eb\:30c9\:3092\:6b8b\:3057\:3001
     Status \:8a08\:7b97\:6642\:306b\:6700\:3082\:512a\:5148\:3055\:308c\:308b
   ============================================================ *)

iBundlesDir[] :=
  Module[{d},
    d = FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "bundles"}];
    iEnsureDir[d];
    d
  ];

iBundlePath[bundleId_String] :=
  FileNameJoin[{iBundlesDir[], bundleId <> ".json"}];

(* Bundle ID \:751f\:6210: bundle-<safe-name>-<timestamp>-<6 hex random> *)
iMakeBundleId[name_String] :=
  Module[{safeName, ts, rnd},
    safeName = StringTake[
      StringReplace[name, RegularExpression["[^A-Za-z0-9]"] -> "-"],
      UpTo[30]];
    ts = ToString[Round[AbsoluteTime[] * 1000]];
    rnd = IntegerString[RandomInteger[{0, 16^6 - 1}], 16, 6];
    "bundle-" <> safeName <> "-" <> ts <> "-" <> rnd
  ];

iBundleSave[bundle_Association] :=
  Module[{bundleId, path, sanitized, json, strm},
    bundleId = Lookup[bundle, "BundleId", ""];
    If[!StringQ[bundleId] || bundleId === "",
      Return[<|"Status" -> "Failed", "Reason" -> "MissingBundleId"|>]];
    path = iBundlePath[bundleId];
    sanitized = iSanitizeForJSON[bundle];
    json = Quiet @ ExportString[sanitized, "RawJSON", "Compact" -> False];
    If[!StringQ[json],
      Return[<|"Status" -> "Failed", "Reason" -> "JSONEncodeFailed",
        "Path" -> path|>]];
    iEnsureDir[DirectoryName[path]];
    strm = Quiet[OpenWrite[path, BinaryFormat -> True]];
    If[Head[strm] =!= OutputStream,
      Return[<|"Status" -> "Failed", "Reason" -> "OpenWriteFailed",
        "Path" -> path|>]];
    BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
    Close[strm];
    <|"Status" -> "OK", "Path" -> path|>
  ];

iBundleLoad[bundleId_String] :=
  Module[{path, rawBytes, content, parsed},
    path = iBundlePath[bundleId];
    If[!FileExistsQ[path], Return[Missing["NotFound"]]];
    rawBytes = Quiet[ReadByteArray[path]];
    If[!ByteArrayQ[rawBytes], Return[Missing["ReadFailed"]]];
    content = Quiet[ByteArrayToString[rawBytes, "UTF-8"]];
    If[!StringQ[content], Return[Missing["DecodeFailed"]]];
    parsed = Quiet[ImportString[content, "RawJSON"]];
    If[ListQ[parsed] && !AssociationQ[parsed], parsed = Association[parsed]];
    If[AssociationQ[parsed], parsed, Missing["ParseFailed"]]
  ];

(*
  Status \:8a08\:7b97\:30ed\:30b8\:30c3\:30af:
    1. ManualInvalidation \:30d5\:30a3\:30fc\:30eb\:30c9\:304c\:3042\:308c\:3070 "Invalidated" \:3092\:8fd4\:3059
    2. Sources \:306e\:5404 SnapshotId \:3092 iSnapshotMetaLoad \:3067\:8aad\:307f\:3001LifecycleStatus \:3092\:96c6\:7d04
       - \:3044\:305a\:308c\:304b\:304c "Invalidated" -> "Invalidated"
       - \:3044\:305a\:308c\:304b\:304c "Stale" / "Frozen" -> "Stale"
       - \:3059\:3079\:3066 "Current" or \:672a\:5b9a\:7fa9 -> "Current"
       - snapshot \:304c\:5b58\:5728\:3057\:306a\:3044 (\:524a\:9664\:6e08\:307f) -> "NeedsReview"
    3. \:8fd4\:308a\:5024: <|"Status" -> _, "Reason" -> _, "AffectedSnapshots" -> {...}, "AffectedClaims" -> {...}|>
*)
iBundleComputeStatus[bundle_Association] :=
  Module[{manualInvalid, sources, snapshotIds, lifecycles,
          affectedSnaps = {}, missingSnaps = {}, finalStatus, reason},
    manualInvalid = Lookup[bundle, "ManualInvalidation", Missing[]];
    If[AssociationQ[manualInvalid],
      Return[<|
        "Status" -> "Invalidated",
        "Reason" -> "Manual: " <>
          ToString[Lookup[manualInvalid, "Reason", "(no reason)"]],
        "AffectedSnapshots" -> {},
        "AffectedClaims" -> Lookup[bundle, "Claims", {}],
        "InvalidatedAt" -> Lookup[manualInvalid, "InvalidatedAt", Missing[]]
      |>]];
    
    sources = Lookup[bundle, "Sources", {}];
    If[!ListQ[sources], sources = {}];
    snapshotIds = Cases[sources,
      a_Association :> Lookup[a, "SnapshotId", ""]];
    snapshotIds = Select[snapshotIds, StringQ[#] && # =!= "" &];
    
    lifecycles = Map[Function[snapId,
      Module[{meta, lc},
        meta = iSnapshotMetaLoad[snapId];
        If[!AssociationQ[meta],
          AppendTo[missingSnaps, snapId];
          "Missing",
          lc = Lookup[meta, "LifecycleStatus", "Current"];
          If[lc =!= "Current",
            AppendTo[affectedSnaps,
              <|"SnapshotId" -> snapId, "LifecycleStatus" -> lc|>]];
          lc]
      ]], snapshotIds];
    
    finalStatus = Which[
      MemberQ[lifecycles, "Invalidated"], "Invalidated",
      Length[missingSnaps] > 0, "NeedsReview",
      MemberQ[lifecycles, "Stale"] || MemberQ[lifecycles, "Frozen"], "Stale",
      True, "Current"];
    
    reason = Switch[finalStatus,
      "Invalidated", "One or more snapshots are Invalidated",
      "NeedsReview", "Missing snapshot(s): " <>
        StringTake[StringRiffle[missingSnaps, ", "], UpTo[200]],
      "Stale", "One or more snapshots are Stale/Frozen",
      _, "All snapshots are Current"];
    
    <|"Status" -> finalStatus,
      "Reason" -> reason,
      "AffectedSnapshots" -> affectedSnaps,
      "AffectedClaims" -> Lookup[bundle, "Claims", {}],
      "MissingSnapshots" -> missingSnaps,
      "Lifecycles" -> lifecycles|>
  ];

(* === Public API === *)

Options[SourceVaultBundleCreate] = {
  "Kind" -> "Generic"
};

SourceVaultBundleCreate[name_String, deps_Association,
  opts:OptionsPattern[]] :=
  Module[{bundleId, bundle, sources, claims, generator, spans,
          generatedFiles, kind, saveResult},
    iEnsureRoots[];
    bundleId = iMakeBundleId[name];
    kind = OptionValue["Kind"];
    
    generatedFiles = Lookup[deps, "GeneratedFiles", {}];
    If[!ListQ[generatedFiles], generatedFiles = {}];
    sources = Lookup[deps, "Sources", {}];
    If[!ListQ[sources], sources = {}];
    spans = Lookup[deps, "SourceSpans", {}];
    If[!ListQ[spans], spans = {}];
    claims = Lookup[deps, "Claims", {}];
    If[!ListQ[claims], claims = {}];
    generator = Lookup[deps, "Generator", <||>];
    If[!AssociationQ[generator], generator = <||>];
    
    bundle = <|
      "BundleId" -> bundleId,
      "Name" -> name,
      "Kind" -> kind,
      "GeneratedAt" -> DateString[DateObject[]],
      "GeneratedFiles" -> generatedFiles,
      "Sources" -> sources,
      "SourceSpans" -> spans,
      "Claims" -> claims,
      "Generator" -> generator,
      "ManualInvalidation" -> Missing["NotInvalidated"],
      "ParentBundle" -> Lookup[deps, "ParentBundle", Missing["NoParent"]],
      "ChildBundles" -> Lookup[deps, "ChildBundles", {}]
    |>;
    
    saveResult = iBundleSave[bundle];
    If[Lookup[saveResult, "Status", ""] === "OK",
      <|"Status" -> "OK",
        "BundleId" -> bundleId,
        "Path" -> Lookup[saveResult, "Path", ""],
        "Bundle" -> bundle|>,
      <|"Status" -> "Failed",
        "Reason" -> Lookup[saveResult, "Reason", "Unknown"],
        "BundleId" -> bundleId|>]
  ];

SourceVaultBundleGet[bundleId_String] :=
  (iEnsureRoots[];
   iBundleLoad[bundleId]);

SourceVaultBundleList[] :=
  Module[{dir, files},
    iEnsureRoots[];
    dir = iBundlesDir[];
    If[!DirectoryQ[dir], Return[{}]];
    files = FileNames["bundle-*.json", dir];
    Map[StringDrop[FileNameTake[#], -5] &, files]   (* ".json" \:3092\:524a\:9664 *)
  ];

SourceVaultBundleStatus[bundleId_String] :=
  Module[{bundle},
    iEnsureRoots[];
    bundle = iBundleLoad[bundleId];
    If[!AssociationQ[bundle],
      Return[<|"Status" -> "NotFound",
        "Reason" -> "Bundle not found: " <> bundleId,
        "AffectedSnapshots" -> {},
        "AffectedClaims" -> {}|>]];
    iBundleComputeStatus[bundle]
  ];

SourceVaultBundleInvalidate[bundleId_String, reason_String] :=
  Module[{bundle, updated, saveResult},
    iEnsureRoots[];
    bundle = iBundleLoad[bundleId];
    If[!AssociationQ[bundle],
      Return[<|"Status" -> "Failed",
        "Reason" -> "Bundle not found: " <> bundleId|>]];
    updated = Append[bundle, "ManualInvalidation" -> <|
      "Reason" -> reason,
      "InvalidatedAt" -> DateString[DateObject[]]
    |>];
    saveResult = iBundleSave[updated];
    If[Lookup[saveResult, "Status", ""] === "OK",
      <|"Status" -> "OK",
        "BundleId" -> bundleId,
        "Reason" -> reason|>,
      <|"Status" -> "Failed",
        "Reason" -> Lookup[saveResult, "Reason", "Unknown"]|>]
  ];

SourceVaultBundleDelete[bundleId_String] :=
  Module[{path},
    iEnsureRoots[];
    path = iBundlePath[bundleId];
    If[!FileExistsQ[path],
      Return[<|"Status" -> "NotFound", "BundleId" -> bundleId|>]];
    Quiet[DeleteFile[path]];
    If[FileExistsQ[path],
      <|"Status" -> "Failed", "Reason" -> "DeleteFailed",
        "BundleId" -> bundleId|>,
      <|"Status" -> "Deleted", "BundleId" -> bundleId|>]
  ];


(* ============================================================
   Stage 8: vN diff + snapshot lifecycle
   - SourceVaultDiffVersions: page-hashes.json \:7d4c\:7531\:306e snapshot \:9593 diff
   - SourceVaultMarkSnapshotStale / Invalidated: snapshot meta \:306e LifecycleStatus \:66f4\:65b0
   - SourceVaultRefreshSnapshot: \:9ad8\:30ec\:30d9\:30eb refresh (diff + Stale + event)
   - SourceVaultBundlesForSnapshot: \:5f71\:97ff\:7bc4\:56f2\:53ce\:96c6
   - SourceVaultSourceEvents / Append: events/source-events.jsonl append-only log
   ============================================================ *)

(* Source events JSONL \:30d1\:30b9 *)
iSourceEventsPath[] :=
  Module[{d},
    d = FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "events"}];
    iEnsureDir[d];
    FileNameJoin[{d, "source-events.jsonl"}]
  ];

(* Event ID: evt-<timestamp>-<6 hex> *)
iMakeEventId[] :=
  Module[{ts, rnd},
    ts = ToString[Round[AbsoluteTime[] * 1000]];
    rnd = IntegerString[RandomInteger[{0, 16^6 - 1}], 16, 6];
    "evt-" <> ts <> "-" <> rnd
  ];

(* Append-only event log *)
iAppendSourceEvent[event_Association] :=
  Module[{path, sanitized, line, strm},
    path = iSourceEventsPath[];
    sanitized = iSanitizeForJSON[event];
    line = Quiet @ ExportString[sanitized, "RawJSON", "Compact" -> True];
    If[!StringQ[line],
      Return[<|"Status" -> "Failed", "Reason" -> "JSONEncodeFailed"|>]];
    iEnsureDir[DirectoryName[path]];
    strm = Quiet[OpenAppend[path, BinaryFormat -> True]];
    If[Head[strm] =!= OutputStream,
      Return[<|"Status" -> "Failed", "Reason" -> "OpenAppendFailed",
        "Path" -> path|>]];
    BinaryWrite[strm, StringToByteArray[line <> "\n", "ISO8859-1"]];
    Close[strm];
    <|"Status" -> "OK", "Path" -> path, "Event" -> sanitized|>
  ];

(* events.jsonl \:8aad\:307f\:8fbc\:307f: \:7f60 #20 \:5bfe\:5fdc *)
iLoadSourceEvents[] :=
  Module[{path, rawBytes, content, lines, parsed},
    path = iSourceEventsPath[];
    If[!FileExistsQ[path], Return[{}]];
    rawBytes = Quiet[ReadByteArray[path]];
    If[!ByteArrayQ[rawBytes], Return[{}]];
    content = Quiet[ByteArrayToString[rawBytes, "UTF-8"]];
    If[!StringQ[content], Return[{}]];
    lines = StringSplit[content, RegularExpression["\\r?\\n"]];
    lines = Select[lines, StringTrim[#] =!= "" &];
    parsed = Map[Function[ln,
      Module[{r = Quiet[ImportString[ln, "RawJSON"]]},
        If[ListQ[r] && !AssociationQ[r], r = Association[r]];
        If[AssociationQ[r], r, Missing["ParseFailed"]]]],
      lines];
    Select[parsed, AssociationQ]
  ];

(* page-hashes.json \:306e diff:
   - keys (page \:756a\:53f7) \:306f String \:3068\:3057\:3066\:8aad\:307f\:51fa\:3055\:308c\:308b\:306e\:3067 ToExpression \:3057\:3066 Integer \:306b
   - \:6bd4\:8f03\:306f set/dict-style: Added (v2\:306e\:307f) / Removed (v1\:306e\:307f) / Changed (\:4e21\:65b9\:3060\:304chash\:9055\:3046) / Unchanged
*)
iComputePageHashDiff[hashes1_Association, hashes2_Association] :=
  Module[{keys1, keys2, common, added, removed, changed = {}, unchanged = {}},
    keys1 = Keys[hashes1];
    keys2 = Keys[hashes2];
    common = Intersection[keys1, keys2];
    added = Complement[keys2, keys1];
    removed = Complement[keys1, keys2];
    Scan[Function[k,
      Module[{h1, h2},
        h1 = Lookup[hashes1, k, ""];
        h2 = Lookup[hashes2, k, ""];
        If[h1 === h2,
          AppendTo[unchanged, k],
          AppendTo[changed, k]]
      ]], common];
    (* Integer \:5316: page \:756a\:53f7\:306f Integer \:3067\:51fa\:3057\:305f\:3044 *)
    Module[{toInt},
      toInt = Function[k,
        Module[{r},
          r = If[StringQ[k], Quiet[ToExpression[k]], k];
          If[IntegerQ[r], r, k]]];
      <|"AddedPages" -> Sort[Map[toInt, added]],
        "RemovedPages" -> Sort[Map[toInt, removed]],
        "ChangedPages" -> Sort[Map[toInt, changed]],
        "UnchangedPages" -> Sort[Map[toInt, unchanged]]|>
    ]
  ];

(* snapshot meta \:306e LifecycleStatus \:3092\:66f4\:65b0\:3057\:4fdd\:5b58 *)
iUpdateSnapshotLifecycle[snapshotId_String, newStatus_String,
  additionalFields_Association] :=
  Module[{meta, updated},
    meta = iSnapshotMetaLoad[snapshotId];
    If[!AssociationQ[meta],
      Return[<|"Status" -> "Failed", "Reason" -> "SnapshotNotFound",
        "SnapshotId" -> snapshotId|>]];
    updated = meta;
    updated["LifecycleStatus"] = newStatus;
    KeyValueMap[Function[{k, v}, updated[k] = v], additionalFields];
    iSnapshotMetaSave[snapshotId, updated];
    <|"Status" -> "OK", "SnapshotId" -> snapshotId,
      "LifecycleStatus" -> newStatus|>
  ];

(* === Public API === *)

SourceVaultDiffVersions[v1Snap_String, v2Snap_String] :=
  Module[{hashes1, hashes2, diff, meta1, meta2},
    iEnsureRoots[];
    hashes1 = iLoadPageHashes[v1Snap];
    hashes2 = iLoadPageHashes[v2Snap];
    If[!AssociationQ[hashes1] || Length[hashes1] === 0,
      meta1 = iSnapshotMetaLoad[v1Snap];
      If[!AssociationQ[meta1],
        Return[<|"Status" -> "Failed",
          "Reason" -> "V1SnapshotNotFound",
          "V1Snap" -> v1Snap|>]];
      Return[<|"Status" -> "Failed",
        "Reason" -> "V1PageHashesNotFound",
        "V1Snap" -> v1Snap,
        "Hint" -> "Run SourceVaultExtractPages[v1Snap, All] first."|>]];
    If[!AssociationQ[hashes2] || Length[hashes2] === 0,
      meta2 = iSnapshotMetaLoad[v2Snap];
      If[!AssociationQ[meta2],
        Return[<|"Status" -> "Failed",
          "Reason" -> "V2SnapshotNotFound",
          "V2Snap" -> v2Snap|>]];
      Return[<|"Status" -> "Failed",
        "Reason" -> "V2PageHashesNotFound",
        "V2Snap" -> v2Snap,
        "Hint" -> "Run SourceVaultExtractPages[v2Snap, All] first."|>]];
    diff = iComputePageHashDiff[hashes1, hashes2];
    <|"Status" -> "OK",
      "V1Snap" -> v1Snap,
      "V2Snap" -> v2Snap,
      "V1PageCount" -> Length[hashes1],
      "V2PageCount" -> Length[hashes2],
      "AddedPages" -> diff["AddedPages"],
      "RemovedPages" -> diff["RemovedPages"],
      "ChangedPages" -> diff["ChangedPages"],
      "UnchangedPages" -> diff["UnchangedPages"]|>
  ];

SourceVaultMarkSnapshotStale[snapshotId_String, reason_String] :=
  Module[{updateResult, eventResult, meta, sourceId},
    iEnsureRoots[];
    meta = iSnapshotMetaLoad[snapshotId];
    sourceId = If[AssociationQ[meta],
      Lookup[meta, "SourceId", ""],
      ""];
    updateResult = iUpdateSnapshotLifecycle[snapshotId, "Stale", <||>];
    If[Lookup[updateResult, "Status", ""] =!= "OK",
      Return[updateResult]];
    eventResult = iAppendSourceEvent[<|
      "EventId" -> iMakeEventId[],
      "EventType" -> "VersionedUpdate",
      "SourceId" -> sourceId,
      "OldSnapshotId" -> snapshotId,
      "NewSnapshotId" -> Missing["NotProvided"],
      "Reason" -> reason,
      "Timestamp" -> DateString[DateObject[]]
    |>];
    <|"Status" -> "OK",
      "SnapshotId" -> snapshotId,
      "LifecycleStatus" -> "Stale",
      "Reason" -> reason,
      "Event" -> Lookup[eventResult, "Event", Missing[]]|>
  ];

SourceVaultMarkSnapshotInvalidated[snapshotId_String, reason_String] :=
  Module[{updateResult, eventResult, meta, sourceId},
    iEnsureRoots[];
    meta = iSnapshotMetaLoad[snapshotId];
    sourceId = If[AssociationQ[meta],
      Lookup[meta, "SourceId", ""],
      ""];
    updateResult = iUpdateSnapshotLifecycle[snapshotId, "Invalidated", <||>];
    If[Lookup[updateResult, "Status", ""] =!= "OK",
      Return[updateResult]];
    eventResult = iAppendSourceEvent[<|
      "EventId" -> iMakeEventId[],
      "EventType" -> "Retraction",
      "SourceId" -> sourceId,
      "OldSnapshotId" -> snapshotId,
      "NewSnapshotId" -> Missing["NotProvided"],
      "Reason" -> reason,
      "Timestamp" -> DateString[DateObject[]]
    |>];
    <|"Status" -> "OK",
      "SnapshotId" -> snapshotId,
      "LifecycleStatus" -> "Invalidated",
      "Reason" -> reason,
      "Event" -> Lookup[eventResult, "Event", Missing[]]|>
  ];

SourceVaultRefreshSnapshot[oldSnapId_String, newSnapId_String,
  reason_String] :=
  Module[{diff, updateResult, eventResult, oldMeta, sourceId},
    iEnsureRoots[];
    oldMeta = iSnapshotMetaLoad[oldSnapId];
    If[!AssociationQ[oldMeta],
      Return[<|"Status" -> "Failed", "Reason" -> "OldSnapshotNotFound"|>]];
    sourceId = Lookup[oldMeta, "SourceId", ""];
    
    (* 1. diff \:8a08\:7b97 (page hashes \:304c\:306a\:3044\:3068\:3059\:3046\:3082\:9001\:3089\:305a\:7d9a\:884c) *)
    diff = Quiet[SourceVaultDiffVersions[oldSnapId, newSnapId]];
    
    (* 2. \:65e7 snapshot \:3092 Stale + SupersededBy \:8a2d\:5b9a *)
    updateResult = iUpdateSnapshotLifecycle[oldSnapId, "Stale",
      <|"SupersededBy" -> newSnapId|>];
    If[Lookup[updateResult, "Status", ""] =!= "OK",
      Return[updateResult]];
    
    (* 3. event \:8a18\:9332 *)
    eventResult = iAppendSourceEvent[<|
      "EventId" -> iMakeEventId[],
      "EventType" -> "VersionedUpdate",
      "SourceId" -> sourceId,
      "OldSnapshotId" -> oldSnapId,
      "NewSnapshotId" -> newSnapId,
      "Reason" -> reason,
      "Timestamp" -> DateString[DateObject[]],
      "DiffSummary" -> If[AssociationQ[diff] && Lookup[diff, "Status", ""] === "OK",
        <|"AddedPages" -> Length[Lookup[diff, "AddedPages", {}]],
          "RemovedPages" -> Length[Lookup[diff, "RemovedPages", {}]],
          "ChangedPages" -> Length[Lookup[diff, "ChangedPages", {}]],
          "UnchangedPages" -> Length[Lookup[diff, "UnchangedPages", {}]]|>,
        Missing["DiffUnavailable"]]
    |>];
    
    <|"Status" -> "OK",
      "OldSnapshotId" -> oldSnapId,
      "NewSnapshotId" -> newSnapId,
      "Diff" -> diff,
      "Event" -> Lookup[eventResult, "Event", Missing[]]|>
  ];

(* \:6b8b\:8ab2\:984c 2: snapshot \:306e\:7cfb\:7d71\:3092\:5224\:5225\:3059\:308b\:3002
   Notebook snapshot \:306f notebooks/snapshots/<id>.json\:3001
   PDF/URL snapshot \:306f raw/meta/<id>.json \:306b\:4fdd\:5b58\:3055\:308c\:308b\:3002
   \:30d5\:30a1\:30a4\:30eb\:5b58\:5728\:3067\:5224\:5225\:3057\:3001\:3069\:3061\:3089\:3067\:3082\:306a\:3051\:308c\:3070 "NotFound"\:3002 *)
iSVSnapshotKindOf[snapshotId_String] :=
  Which[
    FileExistsQ[iNotebookSnapshotPath[snapshotId]], "Notebook",
    FileExistsQ[iSnapshotMetaPathOf[snapshotId]], "PdfUrl",
    True, "NotFound"
  ];

(* === Public API: SourceVaultSetSnapshotPrivacyLevel ===
   NBAccess`NBSetSnapshotPrivacyLevel \:306e\:59d4\:8b72\:5148\:3002
   snapshot record \:306e PrivacyLevel \:30d5\:30a3\:30fc\:30eb\:30c9\:3092\:660e\:793a\:7684\:306b\:4e0a\:66f8\:304d\:3059\:308b\:3002
   \:624b\:52d5\:64cd\:4f5c\:306a\:306e\:3067\:4e0a\:3052\:4e0b\:3052\:4e21\:65b9\:3092\:8a31\:53ef (rule 101 \:306e\:5358\:8abf\:6027\:5236\:7d04\:306f
   Sync \:81ea\:52d5\:51e6\:7406\:5411\:3051\:3067\:3001\:660e\:793a\:64cd\:4f5c\:3068\:306f\:5225)\:3002\:4e0b\:3052\:305f\:5834\:5408\:306f
   "Lowered" -> True \:3092\:8fd4\:3057\:3066\:547c\:3073\:51fa\:3057\:5074\:306b\:6ce8\:610f\:3092\:4fc3\:3059\:3002 *)
SourceVaultSetSnapshotPrivacyLevel[snapshotId_String, level_?NumericQ] :=
  Module[{lv, kind, path, rec, oldLv, lowered, ts, updated, saveOK},
    iEnsureRoots[];
    lv = N[Clip[level, {0.0, 1.0}]];
    kind = iSVSnapshotKindOf[snapshotId];
    If[kind === "NotFound",
      Return[<|"Status" -> "Failed",
        "Reason" -> "SnapshotNotFound",
        "SnapshotId" -> snapshotId|>]];
    path = If[kind === "Notebook",
      iNotebookSnapshotPath[snapshotId],
      iSnapshotMetaPathOf[snapshotId]];
    rec = iLoadJSONFromFile[path];
    If[!AssociationQ[rec],
      Return[<|"Status" -> "Failed",
        "Reason" -> "SnapshotRecordUnreadable",
        "SnapshotId" -> snapshotId,
        "SnapshotKind" -> kind|>]];
    oldLv = Module[{v = Lookup[rec, "PrivacyLevel", Missing[]]},
      If[NumericQ[v], N[v], Missing[]]];
    lowered = NumericQ[oldLv] && lv < oldLv;
    ts = DateString[DateObject[]];
    updated = rec;
    updated["PrivacyLevel"] = lv;
    updated["PrivacyLevelSource"] = "Manual";
    updated["PrivacyLevelSetAt"] = ts;
    saveOK = Module[{sanitized, json, strm, ok = False},
      sanitized = iSanitizeForJSON[updated];
      json = Quiet @ ExportString[sanitized, "RawJSON", "Compact" -> False];
      If[StringQ[json],
        strm = Quiet[OpenWrite[path, BinaryFormat -> True]];
        If[Head[strm] === OutputStream,
          BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
          Close[strm];
          ok = True]];
      ok];
    If[!saveOK,
      Return[<|"Status" -> "Failed",
        "Reason" -> "SnapshotSaveFailed",
        "SnapshotId" -> snapshotId,
        "SnapshotKind" -> kind|>]];
    <|"Status" -> "OK",
      "SnapshotId" -> snapshotId,
      "SnapshotKind" -> kind,
      "OldPrivacyLevel" -> If[NumericQ[oldLv], oldLv,
        Missing["NotPresent"]],
      "NewPrivacyLevel" -> lv,
      "Lowered" -> lowered,
      "PrivacyLevelSource" -> "Manual",
      "SetAt" -> ts|>
  ];

SourceVaultBundlesForSnapshot[snapshotId_String] :=
  Module[{ids, hits = {}},
    iEnsureRoots[];
    ids = SourceVaultBundleList[];
    Scan[Function[bid,
      Module[{b, sources, snapshotIds},
        b = iBundleLoad[bid];
        If[AssociationQ[b],
          sources = Lookup[b, "Sources", {}];
          snapshotIds = Cases[sources,
            a_Association :> Lookup[a, "SnapshotId", ""]];
          If[MemberQ[snapshotIds, snapshotId],
            AppendTo[hits, bid]]]
      ]], ids];
    hits
  ];

Options[SourceVaultSourceEvents] = {
  "SourceId" -> All,
  "SnapshotId" -> All,
  "EventType" -> All
};

SourceVaultSourceEvents[opts:OptionsPattern[]] :=
  Module[{all, sourceFilter, snapFilter, typeFilter, filtered},
    iEnsureRoots[];
    all = iLoadSourceEvents[];
    sourceFilter = OptionValue["SourceId"];
    snapFilter = OptionValue["SnapshotId"];
    typeFilter = OptionValue["EventType"];
    filtered = Select[all, Function[e,
      Module[{ok = True},
        If[sourceFilter =!= All && StringQ[sourceFilter],
          If[Lookup[e, "SourceId", ""] =!= sourceFilter, ok = False]];
        If[ok && snapFilter =!= All && StringQ[snapFilter],
          If[Lookup[e, "OldSnapshotId", ""] =!= snapFilter &&
             Lookup[e, "NewSnapshotId", ""] =!= snapFilter, ok = False]];
        If[ok && typeFilter =!= All && StringQ[typeFilter],
          If[Lookup[e, "EventType", ""] =!= typeFilter, ok = False]];
        ok]]];
    filtered
  ];

SourceVaultSourceEventAppend[event_Association] :=
  Module[{enriched},
    iEnsureRoots[];
    enriched = event;
    If[!KeyExistsQ[enriched, "EventId"],
      enriched = Append[enriched, "EventId" -> iMakeEventId[]]];
    If[!KeyExistsQ[enriched, "Timestamp"],
      enriched = Append[enriched, "Timestamp" -> DateString[DateObject[]]]];
    iAppendSourceEvent[enriched]
  ];


(* ============================================================
   Stage 6b: Compiled Registry
   - Seed registry: \:30d6\:30fc\:30c8\:30b9\:30c8\:30e9\:30c3\:30d7\:7528\:306e\:6700\:5c0f\:30c7\:30fc\:30bf (seeds/<topic>-seed.json)
   - Compiled registry: claim \:304b\:3089 compile \:3055\:308c\:305f production data
       compiled/public/<topic>.json  (public)
       compiled/private/<topic>.json (private routing / user override)
   - SourceVaultLookup: \:6587\:5b57\:5217 key \:691c\:7d22
   - SourceVaultResolve: structured query \:691c\:7d22 (Provider/Intent \:306a\:3069)
   - ClaudeResolveModel: \:4ed5\:69d8\:66f8 \[Section] 5.4 \:4e92\:63db wrapper
   ============================================================ *)

(* \:30c7\:30a3\:30ec\:30af\:30c8\:30ea path helpers *)
iSeedsDir[] :=
  Module[{d},
    d = FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "seeds"}];
    iEnsureDir[d];
    d
  ];

iCompiledDir[channel_String] :=
  Module[{d},
    d = FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"],
      "compiled", channel}];
    iEnsureDir[d];
    d
  ];

iSeedPath[topic_String] :=
  FileNameJoin[{iSeedsDir[], topic <> "-seed.json"}];

iCompiledPath[topic_String, channel_String] :=
  FileNameJoin[{iCompiledDir[channel], topic <> ".json"}];

(* Registry entries load: JSON \:304b\:3089 List of Association \:3092\:8aad\:307f\:8fbc\:3080
   \:7f60 #20 \:5bfe\:5fdc: ReadByteArray \:7d4c\:7531 *)
iLoadRegistryEntries[path_String] :=
  Module[{rawBytes, content, parsed},
    If[!FileExistsQ[path], Return[{}]];
    rawBytes = Quiet[ReadByteArray[path]];
    If[!ByteArrayQ[rawBytes], Return[{}]];
    content = Quiet[ByteArrayToString[rawBytes, "UTF-8"]];
    If[!StringQ[content], Return[{}]];
    (* JSON \:30d1\:30fc\:30b9: \:7f60 #28 (ImportString[..., \"RawJSON\"] \:304c\:74b0\:5883\:30fb\:5185\:5bb9\:306b\:3088\:308a\:5931\:6557\:3057
       $Failed \:3092\:8fd4\:3059) \:5bfe\:7b56\:3002Developer`ReadRawJSONString \:3092\:512a\:5148\:3057\:30013\:6bb5\:968e\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3002 *)
    parsed = Quiet @ Check[
      Developer`ReadRawJSONString[content], $Failed];
    If[parsed === $Failed || Head[parsed] === Developer`ReadRawJSONString,
      parsed = Quiet @ Check[ImportString[content, "RawJSON"], $Failed]];
    If[parsed === $Failed,
      parsed = Quiet @ Check[
        ImportString[content, "JSON"] /. r:{__Rule} :> Association[r],
        $Failed]];
    If[parsed === $Failed, Return[{}]];
    (* JSON \:30e9\:30a6\:30f3\:30c9\:30c8\:30ea\:30c3\:30d7\:3067 Association \:304c\:300c\:898f\:5247\:306e\:30ea\:30b9\:30c8\:300d\:306b\:306a\:308b\:3053\:3068\:304c\:3042\:308b\:3002
       \:30c8\:30c3\:30d7\:30ec\:30d9\:30eb\:3060\:3051\:3067\:306a\:304f Matcher / Target \:7b49\:306e\:30cd\:30b9\:30c8\:3057\:305f Association \:3082
       \:30ea\:30b9\:30c8\:306e\:307e\:307e\:3060\:3068\:3001\:5f8c\:6bb5\:306e Lookup[matcher, ...] \:304c Lookup::invrl \:3092\:8d77\:3053\:3059\:3002
       iRecAssoc \:3067\:518d\:5e30\:7684\:306b Association \:5316\:3057\:3066\:9632\:3050\:3002 *)
    If[ListQ[parsed],
      Map[iRecAssoc, parsed],
      If[AssociationQ[parsed], {iRecAssoc[parsed]}, {}]]
  ];

(* JSON \:30e9\:30a6\:30f3\:30c9\:30c8\:30ea\:30c3\:30d7\:5f8c\:306e\:5024\:3092\:518d\:5e30\:7684\:306b\:6b63\:898f\:5316\:3059\:308b\:3002
   - \:898f\:5247\:306e\:30ea\:30b9\:30c8 ({_Rule...}) \[RightArrow] Association \:306b\:5909\:63db\:3057\:5404\:5024\:3082\:518d\:5e30\:51e6\:7406
   - Association \[RightArrow] \:5404\:5024\:3092\:518d\:5e30\:51e6\:7406
   - \:305d\:306e\:4ed6\:306e\:30ea\:30b9\:30c8 \[RightArrow] \:5404\:8981\:7d20\:3092\:518d\:5e30\:51e6\:7406 (\:7d20\:306e\:30ea\:30b9\:30c8\:306f\:305d\:306e\:307e\:307e)
   - \:539f\:5b50\:5024 \[RightArrow] \:305d\:306e\:307e\:307e *)
(* RuleQ: Wolfram 14.x \:306b\:3088\:3063\:3066\:306f\:30b7\:30b9\:30c6\:30e0\:95a2\:6570\:3068\:3057\:3066\:5b58\:5728\:3057\:306a\:3044\:305f\:3081\:81ea\:524d\:5b9a\:7fa9\:3002
   \:672a\:5b9a\:7fa9\:306e\:307e\:307e\:3060\:3068 AllTrue[x, RuleQ] \:304c\:8a55\:4fa1\:3055\:308c\:305a\:3001JSON \:30d1\:30fc\:30b9\:5f8c\:306e
   Association \:5224\:5b9a\:304c\:5168\:90e8\:6a5f\:80fd\:4e0d\:5168\:306b\:9665\:308b (Matcher.Examples \:306b\:5b9a\:7fa9\:5f0f\:304c\:6df7\:5165\:3059\:308b\:7b49)\:3002 *)
RuleQ[r_] := MatchQ[r, _Rule | _RuleDelayed];

iRecAssoc[x_] :=
  Which[
    AssociationQ[x],
      Association[KeyValueMap[#1 -> iRecAssoc[#2] &, x]],
    ListQ[x] && x =!= {} && AllTrue[x, MatchQ[#, _Rule | _RuleDelayed] &],
      Association[Map[(First[#] -> iRecAssoc[Last[#]]) &, x]],
    ListQ[x],
      Map[iRecAssoc, x],
    True, x];

(* Registry entries save: List of Association \:3092 JSON \:306b *)
iSaveRegistryEntries[path_String, entries_List] :=
  Module[{sanitized, json, strm},
    sanitized = Map[iSanitizeForJSON, entries];
    json = Quiet @ ExportString[sanitized, "RawJSON",
      "Compact" -> False];
    If[!StringQ[json],
      Return[<|"Status" -> "Failed", "Reason" -> "JSONEncodeFailed",
        "Path" -> path|>]];
    iEnsureDir[DirectoryName[path]];
    strm = Quiet[OpenWrite[path, BinaryFormat -> True]];
    If[Head[strm] =!= OutputStream,
      Return[<|"Status" -> "Failed", "Reason" -> "OpenWriteFailed",
        "Path" -> path|>]];
    BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
    Close[strm];
    <|"Status" -> "OK", "Path" -> path, "Count" -> Length[entries]|>
  ];

(*
  Query match: query Association \:306e\:5168\:30ad\:30fc\:304c entry \:3068\:4e00\:81f4\:3059\:308c\:3070 True\:3002
    - query \:306e\:30ad\:30fc\:306f entry \:306b\:5b58\:5728\:3057\:3066\:3044\:308b\:5fc5\:8981\:304c\:3042\:308b
    - value \:306f === \:3067\:6bd4\:8f03 (\:6587\:5b57\:5217 / \:6570\:5024)
    - List \:306a\:3089 MemberQ \:30c1\:30a7\:30c3\:30af (entry["Capabilities"] \:306b\:542b\:307e\:308c\:308b\:304b)
*)
iRegistryEntryMatchesQuery[entry_Association, query_] :=
  Which[
    StringQ[query],
      (* \:6587\:5b57\:5217 key: ModelId / Key \:30d5\:30a3\:30fc\:30eb\:30c9\:306e\:3044\:305a\:308c\:304b *)
      Or[
        Lookup[entry, "Key", Missing[]] === query,
        Lookup[entry, "ModelId", Missing[]] === query,
        Lookup[entry, "Name", Missing[]] === query],
    AssociationQ[query],
      AllTrue[Normal[query], Function[rule,
        Module[{k = First[rule], v = Last[rule], ev},
          ev = Lookup[entry, k, Missing["NotPresent"]];
          Which[
            ListQ[ev], MemberQ[ev, v],
            True, ev === v]]]],
    True, False
  ];

(*
  Resolve order: Resolve \:3067\:8907\:6570 match \:3057\:305f\:3068\:304d\:306e sort \:30ad\:30fc\:3002
  \:512a\:5148\:9806\:4f4d:
    1. Availability == "Available" \:3092\:4e0a\:4f4d
    2. Freshness: "Fresh" > "Stale" > "Expired" > "Unusable"
    3. Class: "Heavy-Cloud" > "Heavy-Local" > "Light-Cloud" > "Light-Local"
  Sort key tuple \:3092\:8fd4\:3059\:3002
*)
iRegistryResolveOrder[entry_Association] :=
  Module[{srcOrder, availOrder, freshOrder, classOrder,
          versionOrder, suffixOrder, src, policy},
    (* Stage 9 P1.5: Source \:512a\:5148\:5ea6\:3092\:6700\:512a\:5148\:30ad\:30fc\:306b\:3059\:308b\:3002
       manual (SourceVaultSetModel \:660e\:793a\:6307\:5b9a) > auto-fetch (Refresh \:53d6\:5f97) >
       seed (\:30b3\:30fc\:30c9\:306e\:30c7\:30d5\:30a9\:30eb\:30c8)\:3002\:30e6\:30fc\:30b6\:30fc\:304c\:660e\:793a\:6307\:5b9a\:3057\:305f\:30e2\:30c7\:30eb\:304c
       Refresh \:3084 seed \:306b\:4e0a\:66f8\:304d\:3055\:308c\:305a\:78ba\:5b9f\:306b\:9078\:3070\:308c\:308b\:3088\:3046\:306b\:3059\:308b\:3002
       Source \:30d5\:30a3\:30fc\:30eb\:30c9\:304c\:7121\:3044\:53e4\:3044\:30a8\:30f3\:30c8\:30ea\:306f PolicySource \:304b\:3089\:63a8\:5b9a\:3002 *)
    src = Lookup[entry, "Source", ""];
    policy = Lookup[entry, "PolicySource", ""];
    srcOrder = Which[
      src === "manual" || StringMatchQ[policy, "manual:" ~~ ___], 0,
      src === "auto-fetch" || StringMatchQ[policy, "auto-fetch:" ~~ ___], 1,
      StringMatchQ[policy, "seed:" ~~ ___], 2,
      True, 1];
    availOrder = Switch[Lookup[entry, "Availability", "Unknown"],
      "Available", 0, "Deprecated", 1, "Unknown", 2, _, 3];
    freshOrder = Switch[Lookup[entry, "Freshness", "Unknown"],
      "Fresh", 0, "Stale", 1, "Expired", 2, "Unusable", 3, _, 4];
    classOrder = Switch[Lookup[entry, "Class", "Unknown"],
      "Heavy-Cloud", 0, "Heavy-Local", 1,
      "Light-Cloud", 2, "Light-Local", 3, _, 4];
    (* Stage 9 P1.5: \:540c\:3058 provider/intent \:306b\:8907\:6570\:5019\:88dc\:304c\:3042\:308b\:3068\:304d
       (seed \:306e opus-4-7 \:3068 auto-fetch \:306e opus-4-8 \:7b49)\:3001
       \:30d0\:30fc\:30b8\:30e7\:30f3\:756a\:53f7\:304c\:5927\:304d\:3044 (\:65b0\:3057\:3044) \:307b\:3069\:512a\:5148\:3059\:308b\:3002
       SortBy \:306f\:6607\:9806\:306a\:306e\:3067\:8ca0\:5024\:5316\:3057\:3066\:300c\:5927\:304d\:3044\:307b\:3069\:5148\:982d\:300d\:306b\:3002
       \:307e\:305f preview/beta \:7b49 suffix \:4ed8\:304d\:306f\:5f8c\:65b9\:306b\:56de\:3059\:3002 *)
    versionOrder = -iSVVersionSortKey[
      Part[iSVParseModelVersion[Lookup[entry, "ModelId", ""]], 2]];
    suffixOrder = If[
      TrueQ[Part[iSVParseModelVersion[Lookup[entry, "ModelId", ""]], 3]],
      1, 0];
    {srcOrder, availOrder, freshOrder, suffixOrder, versionOrder, classOrder}
  ];

(* \:30c7\:30d5\:30a9\:30eb\:30c8 model seed entries (\:30d6\:30fc\:30c8\:30b9\:30c8\:30e9\:30c3\:30d7\:7528):
   - \:4ed6\:306e\:30d1\:30c3\:30b1\:30fc\:30b8 (claudecode.wl) \:3092\:53c2\:8003\:306b\:3057\:3064\:3064\:3001
     SourceVault \:81ea\:8eab\:306f\:4f4e\:4fa1\:683c\:30c0\:30a4\:30b8\:30a7\:30b9\:30c8\:3092\:4fdd\:6301 (\:4ed5\:69d8\:66f8 \[Section] 2.5)
*)
iModelSeedEntries[] := {
  <|"Kind" -> "Model", "Provider" -> "claudecode", "Intent" -> "extraction",
    "ModelId" -> "claude-sonnet-4-6", "Availability" -> "Available",
    "Class" -> "Heavy-Local", "Capabilities" -> {"Reasoning", "Code"},
    "Freshness" -> "Fresh", "PolicySource" -> "seed:model-seed"|>,
  <|"Kind" -> "Model", "Provider" -> "claudecode", "Intent" -> "code-heavy",
    "ModelId" -> "claude-opus-4-8", "Availability" -> "Available",
    "Class" -> "Heavy-Local", "Capabilities" -> {"Reasoning", "Code", "ToolUse"},
    "Freshness" -> "Fresh", "PolicySource" -> "seed:model-seed"|>,
  <|"Kind" -> "Model", "Provider" -> "anthropic", "Intent" -> "heavy",
    "ModelId" -> "claude-opus-4-8", "Availability" -> "Available",
    "Class" -> "Heavy-Cloud", "Capabilities" -> {"Reasoning", "Code", "ToolUse"},
    "Freshness" -> "Fresh", "PolicySource" -> "seed:model-seed"|>,
  <|"Kind" -> "Model", "Provider" -> "anthropic", "Intent" -> "extraction",
    "ModelId" -> "claude-sonnet-4-6", "Availability" -> "Available",
    "Class" -> "Heavy-Cloud", "Capabilities" -> {"Reasoning", "Code"},
    "Freshness" -> "Fresh", "PolicySource" -> "seed:model-seed"|>,
  (* Light x Cloud: cloud light tier (used by power-aware routing when on
     battery / no local LLM). Registered as a table entry, not hardcoded in
     routing logic (rule 02). *)
  <|"Kind" -> "Model", "Provider" -> "anthropic", "Intent" -> "light",
    "ModelId" -> "claude-haiku-4-5", "Availability" -> "Available",
    "Class" -> "Light-Cloud", "Capabilities" -> {"Reasoning"},
    "Freshness" -> "Fresh", "PolicySource" -> "seed:model-seed"|>,
  <|"Kind" -> "Model", "Provider" -> "openai", "Intent" -> "heavy",
    "ModelId" -> "gpt-5", "Availability" -> "Available",
    "Class" -> "Heavy-Cloud", "Capabilities" -> {"Reasoning", "Code", "ToolUse"},
    "Freshness" -> "Fresh", "PolicySource" -> "seed:model-seed"|>,
  <|"Kind" -> "Model", "Provider" -> "lmstudio", "Intent" -> "extraction",
    "ModelId" -> "qwen-local", "Availability" -> "Available",
    "Class" -> "Light-Local", "Capabilities" -> {"Reasoning"},
    "Freshness" -> "Fresh", "PolicySource" -> "seed:model-seed"|>,
  (* chatgptcodex seed entries: disaster-recovery fallback only
     (spec section 2.5). Production truth comes from the compiled
     registry refreshed via `codex debug models`. The slugs below
     are the visibility:list models observed in the Codex CLI
     model catalog; SourceVault keeps a minimal set, not the full
     catalog. LLMs must not edit these directly. *)
  <|"Kind" -> "Model", "Provider" -> "chatgptcodex", "Intent" -> "heavy",
    "ModelId" -> "gpt-5.5", "Availability" -> "Available",
    "Class" -> "Heavy-Cloud", "Capabilities" -> {"Reasoning", "Code", "ToolUse"},
    "Freshness" -> "Fresh", "PolicySource" -> "seed:model-seed"|>,
  <|"Kind" -> "Model", "Provider" -> "chatgptcodex", "Intent" -> "code-heavy",
    "ModelId" -> "gpt-5.3-codex", "Availability" -> "Available",
    "Class" -> "Heavy-Cloud", "Capabilities" -> {"Reasoning", "Code", "ToolUse"},
    "Freshness" -> "Fresh", "PolicySource" -> "seed:model-seed"|>
};

(* \:30d6\:30fc\:30c8\:30b9\:30c8\:30e9\:30c3\:30d7: seeds/model-registry-seed.json \:3092\:7528\:610f\:3059\:308b\:3002
   \:30d5\:30a1\:30a4\:30eb\:304c\:7121\:3044\:5834\:5408\:306f\:65b0\:898f\:4f5c\:6210\:3002\:30d5\:30a1\:30a4\:30eb\:304c\:3042\:3063\:3066\:3082\:3001
   \:30b3\:30fc\:30c9\:4e0a\:306e\:6b63\:672c iModelSeedEntries[] \:3068\:5185\:5bb9\:304c\:9055\:3046\:5834\:5408\:306f\:66f8\:304d\:76f4\:3059\:3002
   \:3053\:308c\:306f LLM \:306b\:3088\:308b\:81ea\:52d5\:66f4\:65b0\:3067\:306f\:306a\:304f\:3001review \:6e08\:307f\:30b3\:30fc\:30c9\:5b9a\:7fa9\:3078\:306e
   \:8ffd\:5f93\:3067\:3042\:308a\:3001\:4ed5\:69d8 \[Section] 2.5 \:306b\:53cd\:3057\:306a\:3044\:3002\:65b0\:3057\:3044 provider \:306e
   seed \:3092\:8ffd\:52a0\:3057\:305f\:3068\:304d\:65e7\:30d5\:30a1\:30a4\:30eb\:304c\:6b8b\:308b\:554f\:984c\:3092\:9632\:3050\:3002
   \:30d1\:30c3\:30b1\:30fc\:30b8\:521d\:671f\:5316\:6642\:306b 1 \:56de\:547c\:3076\:3002 *)
iBootstrapDefaultSeeds[] :=
  Module[{seedPath, current, want, keyOf},
    seedPath = iSeedPath["model-registry"];
    want = iModelSeedEntries[];
    If[!FileExistsQ[seedPath],
      iSaveRegistryEntries[seedPath, want];
      Return[seedPath]];
    (* file exists: rewrite only when its set of {Provider, Intent,
       ModelId} triples differs from the code seed. A stable-key
       comparison avoids false positives from JSON round-trip
       differences (key ordering, Null encoding). *)
    current = iLoadRegistryEntries[seedPath];
    keyOf = Function[e,
      If[AssociationQ[e],
        {Lookup[e, "Provider", ""], ToString[Lookup[e, "Intent", ""]],
         Lookup[e, "ModelId", ""]},
        e]];
    If[!ListQ[current] ||
        Sort[keyOf /@ current] =!= Sort[keyOf /@ want],
      iSaveRegistryEntries[seedPath, want]];
    seedPath
  ];

(* === Public API === *)

Options[SourceVaultLookup] = {
  "Channel" -> "public",
  "AllowSeed" -> True
};

SourceVaultLookup[topic_String, key_, opts:OptionsPattern[]] :=
  Module[{channel, allowSeed, compiledEntries, seedEntries, candidates, hit},
    iEnsureRoots[];
    iBootstrapDefaultSeeds[];
    channel = OptionValue["Channel"];
    allowSeed = TrueQ[OptionValue["AllowSeed"]];
    
    (* 1. compiled \:3092\:5148\:306b\:898b\:308b *)
    compiledEntries = iLoadRegistryEntries[iCompiledPath[topic, channel]];
    candidates = Select[compiledEntries,
      iRegistryEntryMatchesQuery[#, key] &];
    
    (* 2. \:898b\:3064\:304b\:3089\:305a allowSeed \:306a\:3089 seed \:306b fallback *)
    If[Length[candidates] === 0 && allowSeed,
      seedEntries = iLoadRegistryEntries[iSeedPath[topic]];
      candidates = Select[seedEntries,
        iRegistryEntryMatchesQuery[#, key] &]];
    
    If[Length[candidates] === 0, Return[Missing["NotFound"]]];
    
    (* 3. \:8907\:6570\:898b\:3064\:304b\:3063\:305f\:3089 Resolve \:540c\:69d8 sort *)
    hit = First[SortBy[candidates, iRegistryResolveOrder]];
    hit
  ];

Options[SourceVaultResolve] = {
  "Channel" -> "public",
  "AllowSeed" -> True,
  "Topic" -> Automatic
};

SourceVaultResolve[kind_String, query_Association,
  opts:OptionsPattern[]] :=
  Module[{topic, channel, allowSeed, compiledEntries, seedEntries,
          candidates, sourceUsed},
    iEnsureRoots[];
    iBootstrapDefaultSeeds[];
    channel = OptionValue["Channel"];
    allowSeed = TrueQ[OptionValue["AllowSeed"]];
    topic = OptionValue["Topic"];
    If[topic === Automatic || !StringQ[topic],
      topic = ToLowerCase[kind] <> "-registry"];
    (* Stage 9 P1.5: \:660e\:793a Topic \:3082\:6b63\:898f\:5316\:3057\:3066\:66f8\:304d\:8fbc\:307f\:7d4c\:8def\:3068\:7d71\:4e00 *)
    topic = iSVNormalizeRegistryTopic[topic];
    
    compiledEntries = iLoadRegistryEntries[iCompiledPath[topic, channel]];
    candidates = Select[compiledEntries,
      iRegistryEntryMatchesQuery[#, query] &];
    sourceUsed = "compiled";
    
    If[Length[candidates] === 0 && allowSeed,
      seedEntries = iLoadRegistryEntries[iSeedPath[topic]];
      candidates = Select[seedEntries,
        iRegistryEntryMatchesQuery[#, query] &];
      sourceUsed = "seed"];
    
    (* Availability == "Unavailable" \:306f\:9664\:5916 *)
    candidates = Select[candidates,
      Lookup[#, "Availability", "Unknown"] =!= "Unavailable" &];
    
    If[Length[candidates] === 0, Return[Missing["NotFound"]]];
    
    (* Resolve order \:3067 sort *)
    Append[First[SortBy[candidates, iRegistryResolveOrder]],
      "ResolvedFrom" -> sourceUsed]
  ];

(* \:4ed5\:69d8\:66f8 \[Section] 5.4: \:4e92\:63db wrapper *)
ClaudeResolveModel[provider_String, intent_String] :=
  SourceVaultResolve["Model",
    <|"Provider" -> provider, "Intent" -> intent|>];

(* SourceVaultListModels[provider] returns every selectable model
   id registered for a provider, deduplicated, compiled registry
   preferred over seed. Unlike SourceVaultResolve (which resolves a
   single best model for an intent) this enumerates the catalog --
   e.g. for a palette model picker. Unavailable entries are
   dropped. Returns a list of strings (possibly empty). *)
Options[SourceVaultListModels] = {
  "Channel" -> "public",
  "AllowSeed" -> True
};

SourceVaultListModels[provider_String, opts:OptionsPattern[]] :=
  Module[{channel, allowSeed, topic, compiledEntries, seedEntries,
          entries, ids},
    iEnsureRoots[];
    iBootstrapDefaultSeeds[];
    channel = OptionValue["Channel"];
    allowSeed = TrueQ[OptionValue["AllowSeed"]];
    topic = "model-registry";
    compiledEntries = iLoadRegistryEntries[
      iCompiledPath[topic, channel]];
    If[!ListQ[compiledEntries], compiledEntries = {}];
    entries = Select[compiledEntries,
      Lookup[#, "Provider", ""] === provider &];
    (* Stage 9 P1.5: compiled \:304c\:7a7a\:30fb\:8aad\:307f\:8fbc\:307f\:5931\:6557\:30fb\:5f53\:8a72 provider \:7121\:3057\:306e
       \:3044\:305a\:308c\:3067\:3082 seed \:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3059\:308b (allowSeed \:6642)\:3002
       \:4ee5\:524d\:306f compiled \:304c\:5b58\:5728\:3057\:3066\:3082\:7a7a\:30ea\:30b9\:30c8\:306e\:3068\:304d\:306b 2 \:56de\:76ee {} \:306b\:306a\:308b
       \:4e0d\:5b89\:5b9a\:6027\:304c\:3042\:3063\:305f\:305f\:3081\:3001Length 0 \:5224\:5b9a\:3092\:78ba\:5b9f\:306b\:884c\:3046\:3002 *)
    If[Length[entries] === 0 && allowSeed,
      seedEntries = iLoadRegistryEntries[iSeedPath[topic]];
      If[!ListQ[seedEntries], seedEntries = {}];
      entries = Select[seedEntries,
        Lookup[#, "Provider", ""] === provider &]];
    entries = Select[entries,
      Lookup[#, "Availability", "Unknown"] =!= "Unavailable" &];
    ids = DeleteDuplicates @ Select[
      Map[Lookup[#, "ModelId", Missing[]] &, entries],
      StringQ];
    ids
  ];
SourceVaultListModels[___] := {};

(* Stage 9 P1.5: provider + modelId \:304b\:3089 ContextLength \:3092\:89e3\:6c7a\:3059\:308b\:516c\:958b\:95a2\:6570\:3002
   claudecode \:304c $ClaudePrivateModel = {provider, modelId, url} \:306e context_length \:3092
   \:5f15\:304f\:305f\:3081\:306b\:4f7f\:3046\:3002\:30ec\:30b8\:30b9\:30c8\:30ea\:306b ContextLength \:5c5e\:6027\:304c\:306a\:3051\:308c\:3070 None\:3002
   \:91cd\:8981: modelId \:5b8c\:5168\:4e00\:81f4\:306e\:307f\:3092\:8fd4\:3059\:3002context_length \:306f\:30e2\:30c7\:30eb\:30fb\:74b0\:5883\:6bce\:306b
   \:7570\:306a\:308b\:306e\:3067\:3001\:5225\:30e2\:30c7\:30eb\:306e\:5024\:3092\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3067\:8fd4\:3059\:3068\:8aa4\:3063\:305f\:9577\:3055\:3092\:9001\:308b
   \:5371\:967a\:304c\:3042\:308b\:3002\:5b8c\:5168\:4e00\:81f4\:304c\:7121\:3051\:308c\:3070 None (\:30b0\:30ed\:30fc\:30d0\:30eb/\:65e2\:5b9a\:306b\:59d4\:306d\:308b)\:3002 *)
Options[SourceVaultModelContextLength] = {"Channel" -> "public"};
SourceVaultModelContextLength[provider_String, modelId_String,
    opts:OptionsPattern[]] :=
  Module[{channel, path, entries, exact, cl},
    channel = OptionValue["Channel"];
    path = iCompiledPath["model-registry", channel];
    entries = iLoadRegistryEntries[path];
    If[!ListQ[entries], Return[None]];
    (* modelId \:5b8c\:5168\:4e00\:81f4\:30a8\:30f3\:30c8\:30ea\:306e\:307f (\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:306a\:3057) *)
    exact = Select[entries,
      Lookup[#, "Provider", ""] === provider &&
        Lookup[#, "ModelId", ""] === modelId &];
    cl = FirstCase[exact,
      e_ /; IntegerQ[Lookup[e, "ContextLength", None]] :>
        Lookup[e, "ContextLength"], None];
    If[IntegerQ[cl], cl, None]
  ];
SourceVaultModelContextLength[___] := None;

(* ============================================================
   SourceVaultModelIntegrations[provider, modelId]:
   \:30e2\:30c7\:30eb\:306b\:7d10\:3065\:304f LM Studio MCP integrations \:30ea\:30b9\:30c8\:3092 model-registry \:304b\:3089\:8fd4\:3059\:3002
   ContextLength \:3068\:5b8c\:5168\:306b\:5bfe\:79f0\:306a\:8a2d\:8a08\:3002modelId \:5b8c\:5168\:4e00\:81f4\:306e\:307f\:3092\:8fd4\:3057\:3001
   \:5b8c\:5168\:4e00\:81f4\:304c\:7121\:3051\:308c\:3070 None (\:30b0\:30ed\:30fc\:30d0\:30eb $ClaudeLMStudioIntegrations / \:65e2\:5b9a\:306b\:59d4\:306d\:308b)\:3002
   \:623b\:308a\:5024\:306f integrations \:30ea\:30b9\:30c8 (\:6587\:5b57\:5217 ID \:307e\:305f\:306f Association \:306e\:6df7\:5728\:53ef) \:307e\:305f\:306f None\:3002
   ============================================================ *)
Options[SourceVaultModelIntegrations] = {"Channel" -> "public"};
SourceVaultModelIntegrations[provider_String, modelId_String,
    opts:OptionsPattern[]] :=
  Module[{channel, path, entries, exact, integ},
    channel = OptionValue["Channel"];
    path = iCompiledPath["model-registry", channel];
    entries = iLoadRegistryEntries[path];
    If[!ListQ[entries], Return[None]];
    (* modelId \:5b8c\:5168\:4e00\:81f4\:30a8\:30f3\:30c8\:30ea\:306e\:307f (\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:306a\:3057) *)
    exact = Select[entries,
      Lookup[#, "Provider", ""] === provider &&
        Lookup[#, "ModelId", ""] === modelId &];
    integ = FirstCase[exact,
      e_ /; ListQ[Lookup[e, "Integrations", None]] &&
            Length[Lookup[e, "Integrations"]] > 0 :>
        Lookup[e, "Integrations"], None];
    If[ListQ[integ] && Length[integ] > 0,
      (* SearXNG が使える環境なら web 検索 backend を exa->SourceVault に切替、
         使えなければ exa にフォールバックする (SourceVault_webingest.wl 提供; 無ければ素通し)。 *)
      If[Length[Names["SourceVault`SourceVaultSwapWebSearchBackend"]] > 0,
        SourceVault`SourceVaultSwapWebSearchBackend[integ], integ],
      None]
  ];
SourceVaultModelIntegrations[___] := None;

(* ============================================================
   Stage 9 P1.5: \:30e2\:30c7\:30eb\:30ec\:30b8\:30b9\:30c8\:30ea\:306e\:624b\:52d5\:4e0a\:66f8\:304d / \:30af\:30ea\:30a2\:3002

   API \:30ad\:30fc\:304c\:7121\:3044\:74b0\:5883\:3084\:3001compiled registry \:306b\:53e4\:3044 seed \:30b3\:30d4\:30fc\:304c
   \:7269\:7406\:7684\:306b\:6b8b\:3063\:3066\:3044\:308b\:5834\:5408\:306e\:305f\:3081\:306e\:3001\:30e6\:30fc\:30b6\:30fc\:304c\:660e\:793a\:7684\:306b\:547c\:3076\:95a2\:6570\:3002
   \:3069\:3061\:3089\:3082\:81ea\:52d5\:5b9f\:884c\:3057\:306a\:3044\:3002
   ============================================================ *)

(* SourceVaultSetModel[provider, intent, modelId]:
   compiled registry \:306b\:624b\:52d5\:3067 1 \:30a8\:30f3\:30c8\:30ea\:3092\:66f8\:304d\:8fbc\:3080 (API \:30ad\:30fc\:4e0d\:8981)\:3002
   \:65e2\:5b58\:306e\:540c (provider, intent) auto-fetch/seed \:30a8\:30f3\:30c8\:30ea\:3088\:308a\:512a\:5148\:3055\:308c\:308b
   \:3088\:3046 Source -> "manual"\:3001Freshness -> "Fresh" \:3067\:4fdd\:5b58\:3059\:308b\:3002
   \:30aa\:30d5\:30e9\:30a4\:30f3\:74b0\:5883\:3084 API \:30ad\:30fc\:672a\:767b\:9332\:74b0\:5883\:3067\:6700\:65b0\:30e2\:30c7\:30eb\:3092\:56fa\:5b9a\:3057\:305f\:3044\:3068\:304d\:306b\:4f7f\:3046\:3002 *)
Options[SourceVaultSetModel] = {
  "Channel" -> "public",
  "Class" -> Automatic,
  "Capabilities" -> Automatic,
  "ContextLength" -> Automatic,
  "Integrations" -> Automatic
};

SourceVaultSetModel[provider_String, intent_String, modelId_String,
  opts:OptionsPattern[]] :=
  Module[{channel, class, caps, ctxLen, integ, infer, topic, path, existing,
          newEntry, merged, saveResult},
    iEnsureRoots[];
    iBootstrapDefaultSeeds[];
    channel = OptionValue["Channel"];
    class = OptionValue["Class"];
    caps = OptionValue["Capabilities"];
    ctxLen = OptionValue["ContextLength"];
    integ = OptionValue["Integrations"];
    infer = iSVInferModelIntentClass[provider, modelId];
    If[class === Automatic,
      class = Lookup[infer, "Class", "Unknown"]];
    If[caps === Automatic,
      caps = Lookup[infer, "Capabilities", {"Reasoning"}]];
    topic = "model-registry";
    path = iCompiledPath[topic, channel];
    existing = iLoadRegistryEntries[path];
    If[!ListQ[existing], existing = {}];
    (* \:540c (provider, intent) \:306e\:65e2\:5b58\:30a8\:30f3\:30c8\:30ea\:306f\:9664\:53bb\:3057\:3066\:7f6e\:304d\:63db\:3048\:308b *)
    existing = Select[existing,
      !(Lookup[#, "Provider", ""] === provider &&
        Lookup[#, "Intent", ""] === intent) &];
    newEntry = <|
      "Kind" -> "Model",
      "Provider" -> provider,
      "Intent" -> intent,
      "ModelId" -> modelId,
      "Class" -> class,
      "Capabilities" -> caps,
      "Availability" -> "Available",
      "Freshness" -> "Fresh",
      "Source" -> "manual",
      "PolicySource" -> "manual:set-model"|>;
    (* Stage 9 P1.5: ContextLength \:5c5e\:6027\:3092\:6c38\:7d9a\:5316 (\:30e2\:30c7\:30eb\:30fb\:74b0\:5883\:4f9d\:5b58\:3002
       \:6574\:6570\:304c\:6307\:5b9a\:3055\:308c\:305f\:3068\:304d\:306e\:307f\:8a18\:9332\:3002LM Studio \:7b49\:30ed\:30fc\:30ab\:30eb LLM \:306e
       context_length \:306b\:4f7f\:308f\:308c\:308b\:3002Automatic \:306a\:3089\:8a18\:9332\:3057\:306a\:3044) *)
    If[IntegerQ[ctxLen] && ctxLen > 0,
      newEntry = Append[newEntry, "ContextLength" -> ctxLen]];
    (* LM Studio MCP integrations \:5c5e\:6027\:3092\:6c38\:7d9a\:5316\:3002\:30ea\:30b9\:30c8\:304c\:6307\:5b9a\:3055\:308c\:305f\:3068\:304d\:306e\:307f\:8a18\:9332\:3002
       MCP ID (\"mcp/exa\" \:7b49) \:3092\:30b3\:30fc\:30c9\:306b\:30cf\:30fc\:30c9\:30b3\:30fc\:30c9\:305b\:305a SourceVault \:30b9\:30c8\:30a2\:306b
       \:6301\:305f\:305b\:308b\:305f\:3081\:306e\:30d5\:30a3\:30fc\:30eb\:30c9\:3002Automatic / \:7a7a\:30ea\:30b9\:30c8 \:306a\:3089\:8a18\:9332\:3057\:306a\:3044\:3002 *)
    If[ListQ[integ] && Length[integ] > 0,
      newEntry = Append[newEntry, "Integrations" -> integ]];
    merged = Append[existing, newEntry];
    saveResult = iSaveRegistryEntries[path, merged];
    <|"Status" -> "OK", "Provider" -> provider, "Intent" -> intent,
      "ModelId" -> modelId, "Class" -> class,
      "ContextLength" -> If[IntegerQ[ctxLen] && ctxLen > 0, ctxLen, None],
      "Integrations" -> If[ListQ[integ] && Length[integ] > 0, integ, None],
      "RegistryPath" -> Lookup[saveResult, "Path", path],
      "RegistryTotal" -> Length[merged]|>
  ];
SourceVaultSetModel[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" -> "SourceVaultSetModel[provider_String, intent_String, modelId_String, opts]"|>;

(* SourceVaultClearModelRegistry[]:
   compiled model registry \:3092\:524a\:9664\:3057\:3001\:6b21\:56de\:30a2\:30af\:30bb\:30b9\:6642\:306b seed (\:30b3\:30fc\:30c9\:5185\:306e
   \:6700\:65b0 iModelSeedEntries) \:304b\:3089\:518d\:69cb\:7bc9\:3055\:305b\:308b\:3002compiled \:306b\:53e4\:3044 seed \:30b3\:30d4\:30fc
   (\:4f8b: \:904e\:53bb\:306b\:30b3\:30d4\:30fc\:3055\:308c\:305f claude-opus-4-7) \:304c\:6b8b\:3063\:3066 ClaudeResolveModel \:304c
   \:53e4\:3044 ID \:3092\:8fd4\:3057\:7d9a\:3051\:308b\:3068\:304d\:306e\:5fa9\:65e7\:7528\:3002seed \:81ea\:4f53\:306f\:6d88\:3055\:306a\:3044\:3002 *)
Options[SourceVaultClearModelRegistry] = {"Channel" -> "public"};

SourceVaultClearModelRegistry[opts:OptionsPattern[]] :=
  Module[{channel, topic, path, existed},
    iEnsureRoots[];
    channel = OptionValue["Channel"];
    topic = "model-registry";
    path = iCompiledPath[topic, channel];
    existed = FileExistsQ[path];
    If[existed, Quiet @ DeleteFile[path]];
    (* seed \:3092\:518d\:30d6\:30fc\:30c8\:30b9\:30c8\:30e9\:30c3\:30d7 (seed \:30d5\:30a1\:30a4\:30eb\:304c\:30b3\:30fc\:30c9 seed \:3068\:4e00\:81f4\:3059\:308b\:3088\:3046\:66f4\:65b0) *)
    iBootstrapDefaultSeeds[];
    <|"Status" -> "OK", "Channel" -> channel,
      "CompiledExisted" -> existed, "ClearedPath" -> path,
      "Note" -> "compiled cleared; next resolve rebuilds from seed"|>
  ];
SourceVaultClearModelRegistry[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments"|>;

(* ============================================================
   Stage 9 P1.5: Claude \:30e2\:30c7\:30eb\:5909\:6570\:306e\:8d77\:52d5\:6642\:81ea\:52d5\:5272\:308a\:5f53\:3066\:3002

   $ClaudeModel / $ClaudeDocModel / $ClaudePrivateModel /
   $ClaudeFallbackModels \:3092 SourceVault \:30ed\:30fc\:30c9\:6642\:306b\:81ea\:52d5\:8a2d\:5b9a\:3059\:308b\:3002

   \:8cac\:52d9\:5206\:96e2:
   - intent (\:3069\:306e provider \:306e\:4f55\:7528\:30e2\:30c7\:30eb\:304b) \:306f SourceVault \:304c\:7ba1\:7406\:3057\:3001
     ClaudeResolveModel[provider, intent] \:3067\:30e2\:30c7\:30eb ID \:306b\:89e3\:6c7a\:3059\:308b\:3002
   - \:30ed\:30fc\:30ab\:30eb\:30b5\:30fc\:30d0\:306e IP / URL (\:30bb\:30ad\:30e5\:30ea\:30c6\:30a3\:5883\:754c) \:306f NBAccess \:306e
     NBResolveLocalServer[] \:304c\:73fe\:5728\:306e\:30de\:30b7\:30f3\:74b0\:5883\:304b\:3089\:5b89\:5168\:306b\:89e3\:6c7a\:3059\:308b\:3002
     \:672a\:77e5\:30b5\:30d6\:30cd\:30c3\:30c8\:3067\:306f localhost \:306e\:307f (NBAccess \:5074\:3067\:4fdd\:8a3c)\:3002
   - SourceVault \:306f\:3053\:306e 2 \:3064\:3092\:7d44\:307f\:5408\:308f\:305b\:3066\:5b9f\:5909\:6570\:3092\:8a2d\:5b9a\:3059\:308b\:3002

   intent \:5272\:308a\:5f53\:3066\:81ea\:4f53\:306e\:5909\:66f4\:306f SourceVaultSetModelIntent \:3067\:884c\:3044\:3001
   \:3053\:306e\:95a2\:6570\:306f $NBApprovalHeads \:306b\:767b\:9332\:3055\:308c\:308b\:306e\:3067 ClaudeEval \:304b\:3089
   \:547c\:3076\:3068 Hold -> Approve UI \:304c\:51fa\:308b (\:30e2\:30c7\:30eb\:5909\:66f4\:306f\:8981\:627f\:8a8d\:64cd\:4f5c)\:3002
   ============================================================ *)

(* \:5909\:6570\:540d -> intent spec \:306e\:30c7\:30d5\:30a9\:30eb\:30c8\:30de\:30c3\:30d4\:30f3\:30b0\:3002
   spec = {provider, intent}\:3002$ClaudePrivateModel \:306f\:7279\:5225\:6271\:3044
   (provider=local\:3001URL \:306f NBAccess \:89e3\:6c7a) \:306a\:306e\:3067 intent \:306e\:307f\:6301\:3064\:3002
   \:30ed\:30fc\:30c9\:306e\:305f\:3073\:306b\:7121\:6761\:4ef6\:3067\:518d\:521d\:671f\:5316\:3059\:308b (\:30ab\:30fc\:30cd\:30eb\:306b\:6b8b\:3063\:305f\:53e4\:3044
   \:5024\:306b\:5f71\:97ff\:3055\:308c\:306a\:3044\:3088\:3046\:306b)\:3002\:30e6\:30fc\:30b6\:30fc\:5909\:66f4\:306f\:8d77\:52d5\:30d5\:30a1\:30a4\:30eb\:3067
   SourceVaultSetModelIntent \:3092\:547c\:3093\:3067\:884c\:3046\:3002 *)
$iSVModelIntentMap = <|
  "$ClaudeModel"        -> {"claudecode", "code-heavy"},
  "$ClaudeDocModel"     -> {"claudecode", "extraction"},
  "$ClaudePrivateModel" -> {"lmstudio", "extraction"},
  "$ClaudeFallbackModels" -> {
    {"anthropic", "heavy"},
    {"openai", "heavy"}}
|>;

(* intent \:30de\:30c3\:30d4\:30f3\:30b0\:306e\:6c38\:7d9a\:5316 (2026-05-31 \:8ffd\:52a0)\:3002
   \:4ee5\:524d\:306f $iSVModelIntentMap \:304c\:30ed\:30fc\:30c9\:6bce\:306b\:30c7\:30d5\:30a9\:30eb\:30c8\:521d\:671f\:5316\:3055\:308c\:308b\:3060\:3051\:3067\:3001
   SourceVaultSetModelIntent \:306e\:5909\:66f4\:304c\:30e1\:30e2\:30ea\:4e0a\:306e\:307f\:3002\:518d\:8d77\:52d5\:30fb\:518d\:30ed\:30fc\:30c9\:3067
   \:8a2d\:5b9a\:304c\:6d88\:3048\:3066\:3044\:305f\:3002PrivateVault/config/model-intent-map.json \:306b\:6c38\:7d9a\:5316\:3059\:308b\:3002
   provider/intent \:306f ASCII \:306e\:307f\:306a\:306e\:3067 RawJSON \:5f80\:5fa9\:306f\:5b89\:5168\:3002 *)
iSVModelIntentMapPath[] :=
  Module[{d},
    d = FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "config"}];
    iEnsureDir[d];
    FileNameJoin[{d, "model-intent-map.json"}]
  ];

(* \:30c7\:30a3\:30b9\:30af\:3078\:4fdd\:5b58\:3002\:5931\:6557\:3057\:3066\:3082\:30e1\:30e2\:30ea\:4e0a\:306e\:5024\:306f\:6709\:52b9\:306a\:307e\:307e\:7d99\:7d9a\:3002 *)
iSVSaveModelIntentMap[] :=
  Quiet @ Check[
    If[AssociationQ[$iSVModelIntentMap],
      iSaveJSON[iSVModelIntentMapPath[], $iSVModelIntentMap]; True,
      False],
    False];

(* \:30c7\:30a3\:30b9\:30af\:304b\:3089\:5fa9\:5143\:3057\:3066\:30c7\:30d5\:30a9\:30eb\:30c8\:306b\:30de\:30fc\:30b8\:3002
   \:30ad\:30fc\:6bce\:306b\:4e0a\:66f8\:304d (\:5b58\:5728\:3057\:306a\:3044\:30ad\:30fc\:306f\:30c7\:30d5\:30a9\:30eb\:30c8\:5024\:3092\:7dad\:6301)\:3002
   \:8aad\:307f\:8fbc\:3093\:3060\:5024\:306e\:578b\:3092\:691c\:8a3c\:3057\:3001\:4e0d\:6b63\:306a\:30a8\:30f3\:30c8\:30ea\:306f\:7121\:8996\:3059\:308b\:3002 *)
iSVLoadModelIntentMap[] :=
  Module[{path, loaded},
    path = Quiet @ Check[iSVModelIntentMapPath[], $Failed];
    If[!StringQ[path] || !FileExistsQ[path], Return[$iSVModelIntentMap, Module]];
    loaded = Quiet @ iLoadJSONFromFile[path];
    If[!AssociationQ[loaded], Return[$iSVModelIntentMap, Module]];
    KeyValueMap[
      Function[{k, v},
        If[MemberQ[{"$ClaudeModel", "$ClaudeDocModel",
                    "$ClaudePrivateModel", "$ClaudeFallbackModels"}, k] &&
           iSVValidIntentSpec[k, v],
          $iSVModelIntentMap[k] = v]],
      loaded];
    $iSVModelIntentMap
  ];

(* spec \:306e\:578b\:691c\:8a3c\:3002$ClaudeFallbackModels \:306f {{provider,intent},...}\:3001
   \:305d\:308c\:4ee5\:5916\:306f {provider,intent}\:3002JSON \:5f80\:5fa9\:5f8c\:306f List \:306b\:306a\:308b\:306e\:3067 ListQ \:3067\:5224\:5b9a\:3002 *)
iSVValidIntentSpec["$ClaudeFallbackModels", v_] :=
  ListQ[v] && AllTrue[v, ListQ[#] && Length[#] >= 2 &&
    StringQ[#[[1]]] && StringQ[#[[2]]] &];
iSVValidIntentSpec[_String, v_] :=
  ListQ[v] && Length[v] >= 2 && StringQ[v[[1]]] && StringQ[v[[2]]];
iSVValidIntentSpec[___] := False;

(* \:30ed\:30fc\:30c9\:6642\:306b\:30c7\:30a3\:30b9\:30af\:304b\:3089\:5fa9\:5143 (\:30c7\:30d5\:30a9\:30eb\:30c8\:521d\:671f\:5316\:306e\:5f8c) *)
Quiet @ Check[iSVLoadModelIntentMap[], Null];

(* intent \:30de\:30c3\:30d4\:30f3\:30b0\:306e\:8aad\:307f\:53d6\:308a\:516c\:958b\:95a2\:6570\:3002NBAccess`NBSyncClaudeModelVars \:304c
   \:3053\:308c\:3092\:8aad\:3093\:3067\:30e2\:30c7\:30eb\:89e3\:6c7a\:30fb\:4ee3\:5165\:3092\:884c\:3046\:3002intent \:5272\:308a\:5f53\:3066\:81ea\:4f53\:306f
   SourceVault \:304c\:7ba1\:8f96\:3057\:3001NBAccess \:306f\:8aad\:307f\:53d6\:308b\:3060\:3051\:3002 *)
SourceVaultModelIntentMap[] :=
  If[AssociationQ[$iSVModelIntentMap], $iSVModelIntentMap, <||>];

Options[SourceVaultSetModelIntent] = {};

(* SourceVaultSetModelIntent[variable, spec]:
   SourceVault \:304c\:9078\:629e\:3059\:308b\:30e2\:30c7\:30eb\:306e intent \:5272\:308a\:5f53\:3066\:3092\:5909\:66f4\:3059\:308b\:3002
   variable: "$ClaudeModel" | "$ClaudeDocModel" | "$ClaudePrivateModel" |
             "$ClaudeFallbackModels"
   spec: {provider, intent} (FallbackModels \:306f {{provider,intent}, ...})
   \:3053\:306e\:95a2\:6570\:306f $NBApprovalHeads \:306b\:767b\:9332\:3055\:308c\:3001ClaudeEval \:7d4c\:7531\:3067\:306f
   Hold -> Approve \:304c\:5fc5\:8981 (\:30e2\:30c7\:30eb\:9078\:629e\:306e\:5909\:66f4\:306f\:691c\:8a3c\:5bfe\:8c61)\:3002
   \:8a2d\:5b9a\:5f8c\:306b SourceVaultAssignClaudeModels[] \:3092\:547c\:3093\:3067\:5b9f\:5909\:6570\:306b\:53cd\:6620\:3059\:308b\:3002 *)
SourceVaultSetModelIntent[variable_String, spec_, opts:OptionsPattern[]] :=
  Module[{},
    If[!MemberQ[{"$ClaudeModel", "$ClaudeDocModel",
                 "$ClaudePrivateModel", "$ClaudeFallbackModels"}, variable],
      Return[<|"Status" -> "Failed", "Reason" -> "UnknownVariable",
        "Variable" -> variable|>]];
    $iSVModelIntentMap[variable] = spec;
    (* \:30c7\:30a3\:30b9\:30af\:306b\:6c38\:7d9a\:5316 (\:518d\:8d77\:52d5\:5f8c\:3082\:8a2d\:5b9a\:304c\:6b8b\:308b) *)
    iSVSaveModelIntentMap[];
    (* \:5373\:5ea7\:306b\:5b9f\:5909\:6570\:3078\:53cd\:6620 (Private \:5185\:306a\:306e\:3067\:5b8c\:5168\:4fee\:98fe) *)
    SourceVault`SourceVaultAssignClaudeModels[];
    <|"Status" -> "OK", "Variable" -> variable, "Spec" -> spec,
      "Note" -> "intent updated, persisted to disk, and applied to live variable"|>
  ];
SourceVaultSetModelIntent[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" -> "SourceVaultSetModelIntent[variable_String, spec]"|>;

(* spec {provider, intent} \:3092 SourceVaultResolve \:3067\:89e3\:6c7a\:3057
   {provider, modelId} \:3092\:8fd4\:3059\:3002\:89e3\:6c7a\:5931\:6557\:6642\:306f\:8a73\:7d30\:7406\:7531\:4ed8\:304d Missing\:3002
   \:5b9a\:7fa9\:76f4\:524d\:306b ClearAll \:3057\:3066\:53e4\:3044\:5b9a\:7fa9\:306e\:6b8b\:5b58\:3092\:9632\:3050 (\:30ab\:30fc\:30cd\:30eb\:518d\:30ed\:30fc\:30c9\:5bfe\:7b56)\:3002 *)
ClearAll[iSVResolveIntentToTuple];
iSVResolveIntentToTuple[spec_] :=
  Module[{provider, intent, resolved, mid},
    (* \:30ac\:30fc\:30c9: List \:3067 2 \:8981\:7d20\:4ee5\:4e0a\:3002Part \:30a2\:30af\:30bb\:30b9\:3092\:5b89\:5168\:306b\:3002 *)
    If[!ListQ[spec] || Length[spec] < 2,
      Return[Missing["BadSpec", spec]]];
    provider = spec[[1]];
    intent = spec[[2]];
    (* provider/intent \:304c\:6587\:5b57\:5217\:3067\:306a\:3051\:308c\:3070\:3001ToString \:3067\:5f37\:5236\:5909\:63db\:3092\:8a66\:307f\:308b
       (\:30b7\:30f3\:30dc\:30eb\:7b49\:304c\:6df7\:5165\:3057\:3066\:3082\:6551\:6e08\:3001\:65e7\:7248\:3068\:306e\:4e92\:63db\:6027) *)
    If[!StringQ[provider], provider = ToString[provider]];
    If[!StringQ[intent], intent = ToString[intent]];
    If[provider === "" || intent === "",
      Return[Missing["EmptySpec", spec]]];
    (* Private \:5185\:304b\:3089\:306e\:547c\:3073\:51fa\:3057\:306a\:306e\:3067\:516c\:958b\:30b7\:30f3\:30dc\:30eb\:3092\:5b8c\:5168\:4fee\:98fe\:3059\:308b\:3002
       \:5b9f\:4f53\:306e SourceVaultResolve \:3092\:76f4\:63a5\:547c\:3076 (\:30e9\:30c3\:30d1\:30fc\:7d4c\:7531\:306e
       \:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:89e3\:6c7a\:554f\:984c\:3092\:56de\:907f)\:3002 *)
    resolved = Quiet @ SourceVault`SourceVaultResolve["Model",
      <|"Provider" -> provider, "Intent" -> intent|>];
    If[!AssociationQ[resolved],
      Return[Missing["Unresolved", {provider, intent}]]];
    mid = Lookup[resolved, "ModelId", Missing[]];
    If[!StringQ[mid],
      Return[Missing["NoModelId", {provider, intent}]]];
    {provider, mid}];

(* SourceVaultAssignClaudeModels[]:
   intent \:30de\:30c3\:30d4\:30f3\:30b0 (SourceVault) \:3068\:4fe1\:983c\:30ed\:30fc\:30ab\:30eb\:30b5\:30fc\:30d0 (NBAccess) \:304b\:3089
   ClaudeCode \:306e\:5b9f\:5909\:6570\:3092\:8a2d\:5b9a\:3059\:308b\:3002SourceVault \:30ed\:30fc\:30c9\:6642\:306b\:81ea\:52d5\:5b9f\:884c\:3002 *)
Options[SourceVaultAssignClaudeModels] = {"Verbose" -> False};

SourceVaultAssignClaudeModels[opts:OptionsPattern[]] :=
  Module[{verbose, report = <||>, mainSpec, docSpec, privSpec,
          fbSpec, mainTuple, docTuple, localServer, privModel,
          privTuple, fbResolved},
    verbose = TrueQ[OptionValue["Verbose"]];

    (* --- $ClaudeModel --- *)
    mainSpec = Lookup[$iSVModelIntentMap, "$ClaudeModel",
      {"claudecode", "code-heavy"}];
    mainTuple = iSVResolveIntentToTuple[mainSpec];
    If[ListQ[mainTuple],
      ClaudeCode`$ClaudeModel = mainTuple;
      report["$ClaudeModel"] = mainTuple,
      report["$ClaudeModel_FAILED"] =
        <|"Spec" -> mainSpec, "Result" -> mainTuple|>];

    (* --- $ClaudeDocModel --- *)
    docSpec = Lookup[$iSVModelIntentMap, "$ClaudeDocModel",
      {"claudecode", "extraction"}];
    docTuple = iSVResolveIntentToTuple[docSpec];
    If[ListQ[docTuple],
      ClaudeCode`$ClaudeDocModel = docTuple;
      report["$ClaudeDocModel"] = docTuple,
      report["$ClaudeDocModel_FAILED"] =
        <|"Spec" -> docSpec, "Result" -> docTuple|>];

    (* --- $ClaudePrivateModel ---
       provider/URL \:306f NBAccess \:306e\:4fe1\:983c\:30b5\:30fc\:30d0\:89e3\:6c7a (\:30bb\:30ad\:30e5\:30ea\:30c6\:30a3\:5883\:754c)\:3001
       \:30e2\:30c7\:30eb\:540d\:306f SourceVault \:306e intent \:89e3\:6c7a\:3002\:4e21\:8005\:3092\:7d44\:307f\:5408\:308f\:305b\:308b\:3002 *)
    localServer = Quiet @ Check[
      NBAccess`NBResolveLocalServer[], <||>];
    privSpec = Lookup[$iSVModelIntentMap, "$ClaudePrivateModel",
      {"lmstudio", "extraction"}];
    privTuple = iSVResolveIntentToTuple[privSpec];
    If[AssociationQ[localServer] &&
       StringQ[Lookup[localServer, "URL", Missing[]]],
      Module[{prov, url, mid},
        prov = Lookup[localServer, "Provider", "lmstudio"];
        url = Lookup[localServer, "URL", "http://127.0.0.1:1234"];
        mid = If[ListQ[privTuple] && Length[privTuple] >= 2,
          privTuple[[2]], Missing[]];
        (* \:30e2\:30c7\:30eb\:540d\:304c\:89e3\:6c7a\:3067\:304d\:308c\:3070\:305d\:308c\:3092\:3001\:3067\:304d\:306a\:3051\:308c\:3070 provider \:65e2\:5b9a\:306b\:4efb\:305b\:308b *)
        privModel = If[StringQ[mid],
          {prov, mid, url},
          {prov, url}];
        ClaudeCode`$ClaudePrivateModel = privModel;
        report["$ClaudePrivateModel"] = privModel;
        report["LocalServerTrusted"] =
          Lookup[localServer, "Trusted", False]]];

    (* --- $ClaudeFallbackModels --- *)
    fbSpec = Lookup[$iSVModelIntentMap, "$ClaudeFallbackModels", {}];
    If[ListQ[fbSpec],
      fbResolved = DeleteCases[
        Map[iSVResolveIntentToTuple, fbSpec],
        _Missing];
      If[fbResolved =!= {},
        ClaudeCode`$ClaudeFallbackModels = fbResolved;
        report["$ClaudeFallbackModels"] = fbResolved]];

    If[verbose, Print["[SourceVaultAssignClaudeModels] ", report]];
    <|"Status" -> "OK", "Assigned" -> report|>
  ];
SourceVaultAssignClaudeModels[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments"|>;

Options[SourceVaultListRegistries] = {"Channel" -> All};

SourceVaultListRegistries[opts:OptionsPattern[]] :=
  Module[{channel, channels, result = {}},
    iEnsureRoots[];
    channel = OptionValue["Channel"];
    channels = If[channel === All, {"public", "private"},
      If[StringQ[channel], {channel}, {"public"}]];
    Scan[Function[ch,
      Module[{dir, files},
        dir = iCompiledDir[ch];
        If[DirectoryQ[dir],
          files = FileNames["*.json", dir];
          Scan[Function[f,
            AppendTo[result, <|
              "Topic" -> StringDrop[FileNameTake[f], -5],
              "Channel" -> ch,
              "Path" -> f|>]], files]]
      ]], channels];
    (* seeds \:3082\:30ea\:30b9\:30c8 *)
    Module[{seedDir = iSeedsDir[], seedFiles},
      If[DirectoryQ[seedDir],
        seedFiles = FileNames["*-seed.json", seedDir];
        Scan[Function[f,
          AppendTo[result, <|
            "Topic" -> StringDrop[FileNameTake[f], -10],  (* -seed.json = 10 \:6587\:5b57 *)
            "Channel" -> "seed",
            "Path" -> f|>]], seedFiles]]
    ];
    result
  ];

Options[SourceVaultRegistryStatus] = {"Channel" -> "public"};

SourceVaultRegistryStatus[topic_String, opts:OptionsPattern[]] :=
  Module[{channel, compiledPath, seedPath, compiledEntries, seedEntries,
          lastMod},
    iEnsureRoots[];
    channel = OptionValue["Channel"];
    compiledPath = iCompiledPath[topic, channel];
    seedPath = iSeedPath[topic];
    compiledEntries = iLoadRegistryEntries[compiledPath];
    seedEntries = iLoadRegistryEntries[seedPath];
    lastMod = If[FileExistsQ[compiledPath],
      DateString[FileDate[compiledPath]],
      Missing["NoCompiled"]];
    <|"Topic" -> topic,
      "Channel" -> channel,
      "CompiledPath" -> compiledPath,
      "CompiledExists" -> FileExistsQ[compiledPath],
      "CompiledCount" -> Length[compiledEntries],
      "SeedPath" -> seedPath,
      "SeedExists" -> FileExistsQ[seedPath],
      "SeedCount" -> Length[seedEntries],
      "LastModified" -> lastMod|>
  ];

(* Stage 9 P1.5: registry topic \:6b63\:898f\:5316\:3002\:8aad\:307f\:53d6\:308a (SourceVaultResolve) \:3068
   \:66f8\:304d\:8fbc\:307f (SourceVaultCompileRegistry / SourceVaultSetModel) \:304c\:540c\:4e00\:30d5\:30a1\:30a4\:30eb\:3092
   \:6307\:3059\:3088\:3046\:7d71\:4e00\:3059\:308b\:3002\:65e2\:306b "-registry" \:3067\:7d42\:308f\:308b\:306a\:3089\:305d\:306e\:307e\:307e\:3001
   \:305d\:3046\:3067\:306a\:3051\:308c\:3070 ToLowerCase[topic] <> "-registry"\:3002
   \:4f8b: "Model" -> "model-registry", "model-registry" -> "model-registry"\:3002 *)
iSVNormalizeRegistryTopic[topic_String] :=
  If[StringEndsQ[topic, "-registry"],
    topic,
    ToLowerCase[topic] <> "-registry"];
iSVNormalizeRegistryTopic[other_] := other;

Options[SourceVaultCompileRegistry] = {
  "Channel" -> "public",
  "Sources" -> {},
  "PolicySource" -> "config/policies.wl"
};

SourceVaultCompileRegistry[topic_String, entries_List,
  opts:OptionsPattern[]] :=
  Module[{channel, sources, policySource, enriched, path, saveResult,
          ts, normTopic},
    iEnsureRoots[];
    channel = OptionValue["Channel"];
    sources = OptionValue["Sources"];
    policySource = OptionValue["PolicySource"];
    ts = DateString[DateObject[]];
    (* Stage 9 P1.5: topic \:3092\:6b63\:898f\:5316\:3057\:3066\:8aad\:307f\:53d6\:308a\:7d4c\:8def (SourceVaultResolve /
       SourceVaultSetModel) \:3068\:540c\:4e00\:30d5\:30a1\:30a4\:30eb\:3092\:6307\:3059\:3088\:3046\:306b\:3059\:308b\:3002
       \:904e\:53bb\:306b SourceVaultCompileRegistry["Model", ...] (\:5927\:6587\:5b57) \:3067\:547c\:3076\:3068
       Model.json \:304c\:3067\:304d\:3001model-registry.json \:3092\:8aad\:3080\:89e3\:6c7a\:7d4c\:8def\:3068\:98df\:3044\:9055\:3046
       \:5b64\:5150\:30d5\:30a1\:30a4\:30eb\:554f\:984c\:304c\:3042\:3063\:305f\:3002\:6b63\:898f\:5316\:30eb\:30fc\:30eb:
       \:65e2\:306b "-registry" \:3067\:7d42\:308f\:308b\:306a\:3089\:305d\:306e\:307e\:307e\:3001\:305d\:3046\:3067\:306a\:3051\:308c\:3070
       ToLowerCase[topic] <> "-registry" (\:4f8b: "Model" -> "model-registry")\:3002 *)
    normTopic = iSVNormalizeRegistryTopic[topic];
    (* \:5404 entry \:306b CompiledAt / Sources / PolicySource \:3092\:88dc\:3046 *)
    enriched = Map[Function[e,
      Module[{m = If[AssociationQ[e], e, <||>]},
        If[!KeyExistsQ[m, "CompiledAt"],
          m = Append[m, "CompiledAt" -> ts]];
        If[!KeyExistsQ[m, "Sources"],
          m = Append[m, "Sources" -> sources]];
        If[!KeyExistsQ[m, "PolicySource"],
          m = Append[m, "PolicySource" -> policySource]];
        m]], entries];
    
    path = iCompiledPath[normTopic, channel];
    saveResult = iSaveRegistryEntries[path, enriched];
    If[Lookup[saveResult, "Status", ""] === "OK",
      <|"Status" -> "OK",
        "Topic" -> normTopic,
        "Channel" -> channel,
        "Path" -> path,
        "Count" -> Length[enriched]|>,
      saveResult]
  ];

SourceVaultRegisterSeed[topic_String, entries_List] :=
  Module[{path, saveResult},
    iEnsureRoots[];
    path = iSeedPath[topic];
    saveResult = iSaveRegistryEntries[path, entries];
    If[Lookup[saveResult, "Status", ""] === "OK",
      <|"Status" -> "OK",
        "Topic" -> topic,
        "Path" -> path,
        "Count" -> Length[entries]|>,
      saveResult]
  ];


(* ============================================================
   Stage 9: Notebook Management (P0)
   - Notebook \:3092 first-class source \:3068\:3057\:3066\:6271\:3046
   - Header / Todo \:62bd\:51fa\:3001\:30c7\:30c3\:30c9\:30e9\:30a4\:30f3 / \:6b21\:56de\:30ec\:30d3\:30e5\:30fc\:6307\:6a19\:3001Todo \:5b8c\:4e86\:5224\:5b9a
   - notebooks/{sources,snapshots,todos,review,lint}/ \:914d\:4e0b\:306b index
   - safe parse (HoldComplete + whitelist) \:3067 RunProcess / Import \:7b49\:3092\:62d2\:5426
   ============================================================ *)

(* \:30c7\:30a3\:30ec\:30af\:30c8\:30ea path helpers *)
iNotebooksDir[] :=
  Module[{d},
    d = FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"], "notebooks"}];
    iEnsureDir[d];
    d
  ];

iNotebookSourcePath[nbRef_String] :=
  Module[{d},
    d = FileNameJoin[{iNotebooksDir[], "sources"}];
    iEnsureDir[d];
    FileNameJoin[{d, nbRef <> ".json"}]
  ];

iNotebookSnapshotPath[snapshotId_String] :=
  Module[{d},
    d = FileNameJoin[{iNotebooksDir[], "snapshots"}];
    iEnsureDir[d];
    FileNameJoin[{d, snapshotId <> ".json"}]
  ];

iNotebookTodosByNotebookPath[nbRef_String] :=
  Module[{d},
    d = FileNameJoin[{iNotebooksDir[], "todos", "by-notebook"}];
    iEnsureDir[d];
    FileNameJoin[{d, nbRef <> ".jsonl"}]
  ];

iNotebookTodosOpenPath[] :=
  Module[{d},
    d = FileNameJoin[{iNotebooksDir[], "todos"}];
    iEnsureDir[d];
    FileNameJoin[{d, "open.jsonl"}]
  ];

iNotebookTodosDonePath[] :=
  Module[{d},
    d = FileNameJoin[{iNotebooksDir[], "todos"}];
    iEnsureDir[d];
    FileNameJoin[{d, "done.jsonl"}]
  ];

iNotebookReviewOverduePath[] :=
  Module[{d},
    d = FileNameJoin[{iNotebooksDir[], "review"}];
    iEnsureDir[d];
    FileNameJoin[{d, "overdue.jsonl"}]
  ];

iNotebookLintPath[] :=
  Module[{d},
    d = FileNameJoin[{iNotebooksDir[], "lint"}];
    iEnsureDir[d];
    FileNameJoin[{d, "notebook-lint.jsonl"}]
  ];

(* Stage 9 P1 Step 4: Summary artifact \:7269\:7406\:30d1\:30b9 *)
iNotebookSummaryPath[nbRef_String] :=
  Module[{d},
    d = FileNameJoin[{iNotebooksDir[], "summaries"}];
    iEnsureDir[d];
    FileNameJoin[{d, "sum-" <> nbRef <> ".json"}]
  ];

iLoadNotebookSummaryRecord[nbRef_String] :=
  Module[{path, data},
    path = iNotebookSummaryPath[nbRef];
    data = iLoadJSONFromFile[path];
    If[AssociationQ[data], data, Null]
  ];

iSaveNotebookSummaryRecord[record_Association] :=
  Module[{nbRef, path, json, strm},
    nbRef = Lookup[record, "NotebookRef", ""];
    If[!StringQ[nbRef] || nbRef === "",
      Return[<|"Status" -> "Failed", "Reason" -> "MissingNotebookRef"|>]];
    path = iNotebookSummaryPath[nbRef];
    json = Quiet @ ExportString[iSanitizeForJSON[record],
      "RawJSON", "Compact" -> False];
    If[!StringQ[json],
      Return[<|"Status" -> "Failed", "Reason" -> "SerializationFailed"|>]];
    strm = Quiet[OpenWrite[path, BinaryFormat -> True]];
    If[Head[strm] =!= OutputStream,
      Return[<|"Status" -> "Failed", "Reason" -> "WriteFailed"|>]];
    BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
    Close[strm];
    <|"Status" -> "OK", "Path" -> path|>
  ];

(* Summary record \:3068\:73fe\:5728 snapshot \:60c5\:5831\:304b\:3089 lifecycle status \:3092\:5224\:5b9a *)
iComputeNotebookSummaryStatus[summaryRecord_, currentSnapshotId_String,
    currentSemanticHash_] :=
  Which[
    summaryRecord === Null || !AssociationQ[summaryRecord],
      <|"Status" -> "Missing", "Reason" -> "SummaryNotFound",
        "CurrentSnapshot" -> currentSnapshotId,
        "SummaryBasedOnSnapshot" -> Missing["NotApplicable"]|>,
    Lookup[summaryRecord, "BasedOnSnapshot", ""] === currentSnapshotId,
      <|"Status" -> "Current", "Reason" -> "SameSnapshot",
        "CurrentSnapshot" -> currentSnapshotId,
        "SummaryBasedOnSnapshot" -> Lookup[summaryRecord, "BasedOnSnapshot"]|>,
    StringQ[currentSemanticHash] &&
      Lookup[summaryRecord, "BasedOnSemanticHash", ""] === currentSemanticHash,
      <|"Status" -> "StaleFormattingOnly",
        "Reason" -> "SnapshotChangedButSemanticHashIdentical",
        "CurrentSnapshot" -> currentSnapshotId,
        "SummaryBasedOnSnapshot" -> Lookup[summaryRecord, "BasedOnSnapshot"]|>,
    True,
      <|"Status" -> "Stale",
        "Reason" -> "SemanticHashChanged",
        "CurrentSnapshot" -> currentSnapshotId,
        "SummaryBasedOnSnapshot" -> Lookup[summaryRecord, "BasedOnSnapshot"]|>
  ];

(* ============================================================
   Stage 9 Phase 2 (P1) Step 5: \:30af\:30ed\:30b9 PC / \:30af\:30ed\:30b9 OS \:5bfe\:5fdc\:30d1\:30b9\:6b63\:898f\:5316
   ------------------------------------------------------------
   Dropbox \:7b49\:306e\:30af\:30e9\:30a6\:30c9\:5171\:6709\:30d5\:30a9\:30eb\:30c0\:306f PC \:6bce\:306b\:30de\:30a6\:30f3\:30c8\:5148\:304c\:7570\:306a\:308b\:3002
   \:7d76\:5bfe\:30d1\:30b9\:3092\:305d\:306e\:307e\:307e ID \:5316\:30fb\:4fdd\:5b58\:3059\:308b\:3068\:3001\:540c\:3058\:30d5\:30a1\:30a4\:30eb\:304c PC \:6bce\:306b
   \:5225 ID \:306b\:306a\:308a\:3001\:307e\:305f Mac/Linux \:3068\:4e92\:63db\:6027\:304c\:53d6\:308c\:306a\:3044\:3002
   \:89e3\:6c7a: \:30af\:30e9\:30a6\:30c9\:30eb\:30fc\:30c8\:5909\:6570\:306e\:30ea\:30b9\:30c8\:3092\:6301\:3061\:3001
   \:7d76\:5bfe\:30d1\:30b9\:3092 {"$onWork", "folder", "file.nb"} \:306e\:3088\:3046\:306a\:30b7\:30f3\:30dc\:30ea\:30c3\:30af\:30d1\:30b9\:306b
   \:6b63\:898f\:5316\:3057\:3001\:305d\:308c\:3092 ID / \:4fdd\:5b58 / SystemOpen \:306e\:5168\:3066\:3067\:4e00\:8cab\:3057\:3066\:4f7f\:3046\:3002
   ============================================================ *)

(* \:30af\:30e9\:30a6\:30c9\:5171\:6709\:30d5\:30a9\:30eb\:30c0\:306e\:30b7\:30f3\:30dc\:30eb\:540d\:30ea\:30b9\:30c8\:3002
   \:5404\:8981\:7d20\:306f Global\` \:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:306e\:5909\:6570\:540d (\:6587\:5b57\:5217)\:3002
   $ClaudeWorkingDirectory \:7b49\:306e PC \:56fa\:6709\:30d5\:30a9\:30eb\:30c0\:306f\:542b\:3081\:306a\:3044\:3002 *)
If[!ValueQ[$SourceVaultCloudRoots],
  $SourceVaultCloudRoots = {
    "$packageDirectory", "$dropbox", "$onWork",
    "$offWork", "$mathematicaWork"}];

(* \[HorizontalLine]\[HorizontalLine] \:30af\:30e9\:30a6\:30c9\:30eb\:30fc\:30c8\:306e\:30a8\:30a4\:30ea\:30a2\:30b9 (\:65e7 PC \:306a\:3069\:5225\:74b0\:5883\:306e\:7d76\:5bfe\:30d1\:30b9) \[HorizontalLine]\[HorizontalLine]
   \:30b7\:30f3\:30dc\:30eb\:540d -> \:65e7 PC \:306e\:30eb\:30fc\:30c8\:7d76\:5bfe\:30d1\:30b9\:306e\:30ea\:30b9\:30c8\:3002\:73fe PC \:306b\:5b9f\:5728\:3057\:306a\:3044\:30d1\:30b9\:3067\:3088\:3044\:3002
   \:5225 PC \:3067 index \:3055\:308c\:305f\:65e7\:30d1\:30b9\:3092 {"$onWork", ...} \:306b\:6b63\:898f\:5316\:3057\:4e8c\:91cd\:767b\:9332\:3092\:9632\:3050\:3002 *)
If[!ValueQ[$SourceVaultCloudRootAliases],
  $SourceVaultCloudRootAliases = <||>];

(* Default folder for SourceVault notebooks. Automatic -> Global`$onWork ->
   $packageDirectory (resolved at use time by iSVDefaultNotebookFolder). *)
If[!ValueQ[$SourceVaultDefaultNotebookFolder],
  $SourceVaultDefaultNotebookFolder = Automatic];

(* \:30d1\:30b9\:6587\:5b57\:5217\:3092\:30bb\:30d1\:30ec\:30fc\:30bf\:7d71\:4e00 (/ \:56fa\:5b9a) + \:672b\:5c3e\:30bb\:30d1\:30ec\:30fc\:30bf\:9664\:53bb\:3002\:5927\:6587\:5b57\:5c0f\:6587\:5b57\:306f\:4fdd\:6301\:3002
   \:30b7\:30f3\:30dc\:30ea\:30c3\:30af\:30d1\:30b9\:306e rest \:62bd\:51fa\:306b\:4f7f\:3046 (NotebookRef ID \:5b89\:5b9a\:306e\:305f\:3081\:8868\:8a18\:3092\:5909\:3048\:306a\:3044)\:3002 *)
iSVPathSlash[s_String] :=
  StringReplace[
    StringReplace[s, "\\" -> "/"],
    RegularExpression["/+$"] -> ""];

(* \:30de\:30c3\:30c1\:5224\:5b9a\:5c02\:7528\:30ad\:30fc: \:30bb\:30d1\:30ec\:30fc\:30bf\:7d71\:4e00 + \:672b\:5c3e\:9664\:53bb + \:5c0f\:6587\:5b57\:5316 (Windows \:5927\:6587\:5b57\:5c0f\:6587\:5b57\:7121\:8996)\:3002
   \:3053\:306e\:5024\:306f\:524d\:65b9\:4e00\:81f4\:6bd4\:8f03\:306b\:306e\:307f\:4f7f\:3044\:3001ID \:751f\:6210\:3084 rest \:62bd\:51fa\:306b\:306f\:4f7f\:308f\:306a\:3044\:3002 *)
iSVPathMatchKey[s_String] := ToLowerCase[iSVPathSlash[s]];

(* \:3042\:308b\:30b7\:30f3\:30dc\:30eb\:540d\:306b\:5bfe\:3059\:308b\:5019\:88dc\:30eb\:30fc\:30c8\:306e\:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002
   \:5404\:8981\:7d20 {symName, rootSlash, rootKey, isLive}:
     isLive = True  : \:73fe PC \:306b\:5b9f\:5728\:3059\:308b\:30eb\:30fc\:30c8 (iSVCloudRootValue)
     isLive = False : $SourceVaultCloudRootAliases \:767b\:9332\:306e\:30a8\:30a4\:30ea\:30a2\:30b9 (\:65e7 PC \:30d1\:30b9) *)
iSVRootMatchCands[symName_String] :=
  Module[{liveAbs, aliasList, cands},
    cands = {};
    liveAbs = iSVCloudRootValue[symName];
    If[Head[liveAbs] =!= Missing,
      AppendTo[cands,
        {symName, iSVPathSlash[liveAbs], iSVPathMatchKey[liveAbs], True}]];
    aliasList = Lookup[$SourceVaultCloudRootAliases, symName, {}];
    If[ListQ[aliasList],
      Scan[
        Function[a,
          If[StringQ[a] && a =!= "",
            AppendTo[cands,
              {symName, iSVPathSlash[a], iSVPathMatchKey[a], False}]]],
        aliasList]];
    cands
  ];


(* \:30b7\:30f3\:30dc\:30eb\:540d (\"$onWork\" \:7b49) \[Rule] \:5b9f\:30d1\:30b9 (\:73fe PC)\:3002
   \:672a\:5b9a\:7fa9\:30fb\:975e\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:306a\:3089 Missing\:3002 *)
iSVCloudRootValue[symName_String] :=
  Module[{bareName, v},
    (* \"$onWork\" \:304b\:3089\:5148\:982d\:306e $ \:3092\:5916\:3057\:3001Global\` \:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:3067\:89e3\:6c7a *)
    bareName = StringTrim[symName, "$"];
    v = Quiet @ ToExpression["Global`$" <> bareName];
    If[StringQ[v] && DirectoryQ[v], ExpandFileName[v], Missing[]]
  ];

(* \:7d76\:5bfe\:30d1\:30b9 -> \:30b7\:30f3\:30dc\:30ea\:30c3\:30af\:30d1\:30b9 {"$root", "sub", ..., "file.nb"}\:3002
   \:73fe PC \:5b9f\:4f53\:30eb\:30fc\:30c8\:306b\:52a0\:3048 $SourceVaultCloudRootAliases \:306e\:30a8\:30a4\:30ea\:30a2\:30b9\:306b\:3082\:30de\:30c3\:30c1\:3059\:308b\:3002
   \:3069\:306e\:30eb\:30fc\:30c8\:306b\:3082\:30de\:30c3\:30c1\:3057\:306a\:3051\:308c\:3070 {"<ABS>", \:7d76\:5bfe\:30d1\:30b9} (\:30af\:30e9\:30a6\:30c9\:5916\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af)\:3002
   \:30de\:30c3\:30c1\:5224\:5b9a\:306f\:5c0f\:6587\:5b57\:5316\:30ad\:30fc\:3001rest \:306e\:6587\:5b57\:8868\:8a18\:306f\:5143\:306e\:307e\:307e (NotebookRef ID \:5b89\:5b9a)\:3002 *)
iSVSymbolicPath[path_String] :=
  Module[{abs, absSlash, absKey, cands, matched, best,
          symName, rootKey, restSlash, rest},
    abs = ExpandFileName[path];
    absSlash = iSVPathSlash[abs];
    absKey   = iSVPathMatchKey[abs];
    (* \:5168\:30af\:30e9\:30a6\:30c9\:30eb\:30fc\:30c8 x (\:73fe PC \:5b9f\:4f53 + \:30a8\:30a4\:30ea\:30a2\:30b9) \:306e\:5019\:88dc\:3092\:96c6\:3081\:308b *)
    cands = Join @@ Map[iSVRootMatchCands, $SourceVaultCloudRoots];
    (* absKey \:304c rootKey \:3068\:4e00\:81f4\:3001\:307e\:305f\:306f rootKey + "/" \:3067\:59cb\:307e\:308b\:5019\:88dc\:3060\:3051\:6b8b\:3059 *)
    matched = Select[cands,
      Function[c,
        With[{rk = c[[3]]},
          rk =!= "" &&
          (absKey === rk || StringStartsQ[absKey, rk <> "/"])]]];
    If[matched === {},
      (* \:3069\:306e\:30eb\:30fc\:30c8\:306b\:3082\:30de\:30c3\:30c1\:3057\:306a\:3044: \:7d76\:5bfe\:30d1\:30b9\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af *)
      Return[{"<ABS>", abs}]];
    (* \:6700\:9577\:30de\:30c3\:30c1\:3092\:9078\:3076 ($dropbox \:3068 $onWork \:306e\:5165\:308c\:5b50\:5bfe\:7b56)\:3002
       \:540c\:9577\:306a\:3089\:73fe PC \:5b9f\:4f53\:30eb\:30fc\:30c8 (isLive) \:3092\:512a\:5148\:3002 *)
    best = First @ SortBy[matched,
      {-StringLength[#[[3]]], If[TrueQ[#[[4]]], 0, 1]} &];
    symName = best[[1]];
    rootKey = best[[3]];
    (* rest \:306f\:5143\:8868\:8a18\:306e absSlash \:304b\:3089\:3001\:30eb\:30fc\:30c8\:9577 (rootKey \:3068\:540c\:9577) \:5206 drop\:3002
       \:5c0f\:6587\:5b57\:5316\:306f\:5224\:5b9a\:306e\:307f\:3067\:3001\:3053\:3053\:3067\:306f\:7d76\:5bfe\:30d1\:30b9\:306e\:5143\:8868\:8a18\:3092\:4fdd\:3064\:3002 *)
    restSlash = StringDrop[absSlash, StringLength[rootKey]];
    rest = StringSplit[StringTrim[restSlash, "/"], "/"];
    Prepend[rest, symName]
  ];

(* \:30b7\:30f3\:30dc\:30ea\:30c3\:30af\:30d1\:30b9 \[Rule] \:7d76\:5bfe\:30d1\:30b9 (\:73fe PC)\:3002
   {"<ABS>", abs} \:306a\:3089 abs \:3092\:305d\:306e\:307e\:307e\:3002
   \:30af\:30e9\:30a6\:30c9\:30eb\:30fc\:30c8\:304c\:73fe PC \:3067\:672a\:5b9a\:7fa9\:306a\:3089 Missing\:3002 *)
iSVResolvePath[symPath_List] :=
  Module[{head, rootAbs},
    If[symPath === {}, Return[Missing[]]];
    head = First[symPath];
    If[head === "<ABS>",
      Return[If[Length[symPath] >= 2, symPath[[2]], Missing[]]]];
    rootAbs = iSVCloudRootValue[head];
    If[Head[rootAbs] === Missing, Return[Missing[]]];
    If[Length[symPath] === 1,
      rootAbs,
      FileNameJoin[Prepend[Rest[symPath], rootAbs]]]
  ];
iSVResolvePath[other_] := Missing[];

(* Stage 9 P1.5: Scope -> "Today" \:7528\:30d8\:30eb\:30d1\:3002
   Path \:6587\:5b57\:5217\:306b\:4eca\:65e5\:306e\:65e5\:4ed8 (YYYYMMDD \:5f62\:5f0f) \:304c\:542b\:307e\:308c\:308b\:304b\:3092\:5224\:5b9a\:3059\:308b\:3002
   \:30d5\:30a1\:30a4\:30eb\:540d\:3084\:30d5\:30a9\:30eb\:30c0\:540d\:304c "20260528-\:6559\:52d9\:59d4\:54e1\:4f1a.nb" \:306e\:3088\:3046\:306b
   \:4eca\:65e5\:306e\:65e5\:4ed8\:3092\:542b\:3080\:5834\:5408\:3001NextReview / Deadline \:304c\:672a\:8a2d\:5b9a\:3067\:3082
   \:300c\:4eca\:65e5\:306e\:3082\:306e\:300d\:3068\:3057\:3066\:8a8d\:8b58\:3059\:308b\:305f\:3081\:306b\:4f7f\:3046\:3002 *)
iSVTodayYYYYMMDD[today_DateObject] :=
  Module[{y, m, d},
    y = DateValue[today, "Year"];
    m = DateValue[today, "Month"];
    d = DateValue[today, "Day"];
    IntegerString[y, 10, 4] <>
      IntegerString[m, 10, 2] <>
      IntegerString[d, 10, 2]];

iSVPathHasTodayDate[path_String, today_DateObject] :=
  StringContainsQ[path, iSVTodayYYYYMMDD[today]];
iSVPathHasTodayDate[_, _] := False;

(* Stage 9 P1.5: \:65e5\:4ed8\:7bc4\:56f2\:30af\:30a8\:30ea\:7528\:30d8\:30eb\:30d1\:3002
   <|"From" -> _, "To" -> _|> \:5f62\:5f0f\:306e Association \:3092 {fromDO|None, toDO|None} \:306b\:5909\:63db\:3059\:308b\:3002
   \:6587\:5b57\:5217 ("2026-05-01") \:3082 DateObject \:3082\:53d7\:3051\:3001\:7121\:52b9\:5024\:306f None\:3002
   SourceVault `Deadline` / `NextReview` \:30aa\:30d7\:30b7\:30e7\:30f3\:3067 usage \:306b\:8a18\:8f09\:3055\:308c\:3066\:3044\:308b\:304c
   \:5b9f\:88c5\:304c\:5165\:3063\:3066\:3044\:306a\:304b\:3063\:305f\:7bc4\:56f2\:6307\:5b9a\:3092\:6709\:52b9\:5316\:3059\:308b\:305f\:3081\:306e\:30d8\:30eb\:30d1\:3002 *)
iSVParseDateRange[spec_] :=
  Module[{from, to, toDO},
    If[!AssociationQ[spec], Return[{None, None}]];
    toDO = Function[v,
      Which[
        MatchQ[v, _DateObject], v,
        StringQ[v], Quiet @ Check[DateObject[v, "Day"], None],
        True, None]];
    from = toDO[Lookup[spec, "From", Missing[]]];
    to   = toDO[Lookup[spec, "To", Missing[]]];
    {from, to}];

(* AbsoluteTime \:30d9\:30fc\:30b9\:3067 d \:304c [from, to] \:306b\:5165\:308b\:304b\:3092\:30c1\:30a7\:30c3\:30af\:3002
   DateObject \:540c\:58eb\:306e <= \:306f\:30bf\:30a4\:30e0\:30be\:30fc\:30f3\:30fb\:5185\:90e8\:8868\:73fe\:6b21\:7b2c\:3067 Inequality \:304c\:672a\:8a55\:4fa1\:306e\:307e\:307e\:6b8b\:308b\:3053\:3068\:304c\:3042\:308a\:3001
   \:300cTrue \:3067\:306a\:3044 \\:2192 False\\:300d\:3068\:3057\:3066\:5168\:4ef6\:6f0f\:308c\:308b\:30d0\:30b0\:304c\:51fa\:3066\:3044\:305f\:3002AbsoluteTime \:306f\:5e38\:306b\:6570\:5024\:3092\:8fd4\:3059 *)
iSVDateInRange[d_, spec_] :=
  Module[{from, to, dT, fromT, toT},
    {from, to} = iSVParseDateRange[spec];
    If[from === None && to === None, Return[True]];
    If[!MatchQ[d, _DateObject], Return[False]];
    dT = Quiet @ AbsoluteTime[d];
    If[!NumericQ[dT], Return[False]];
    fromT = If[from === None, None, Quiet @ AbsoluteTime[from]];
    toT   = If[to === None,   None, Quiet @ AbsoluteTime[to]];
    And[
      fromT === None || (NumericQ[fromT] && fromT <= dT),
      toT   === None || (NumericQ[toT]   && dT <= toT)]];
iSVDateInRange[_, _] := False;

(* \:30d5\:30a1\:30a4\:30eb\:540d\:898f\:7d04 "yyyymmdd-title.nb" \:306e\:5148\:982d 8 \:6841\:3092 DateObject \:306b\:30d1\:30fc\:30b9\:3057\:3001
   \:7bc4\:56f2\:30c1\:30a7\:30c3\:30af\:3092\:884c\:3046\:3002\:898f\:7d04\:5916\:30d5\:30a1\:30a4\:30eb\:30d1\:30b9\:306f False\:3002
   "Deadline"/"NextReview" \:306e Association \:7bc4\:56f2\:6307\:5b9a\:3067\:3001Header \:5024\:3060\:3051\:3067\:306a\:304f
   \:30d5\:30a1\:30a4\:30eb\:540d\:65e5\:4ed8\:3082\:8003\:616e\:3059\:308b\:305f\:3081\:306b\:4f7f\:3046 (Imai \:5148\:751f\:306e\:898f\:7d04)\:3002 *)
iSVPathDateInRange[path_String, spec_] :=
  Module[{base, ymd, d},
    If[!StringQ[path], Return[False]];
    base = FileBaseName[path];
    If[!StringMatchQ[base, RegularExpression["^\\d{8}-.*"]], Return[False]];
    ymd = StringTake[base, 8];
    d = Quiet @ Check[DateObject[ymd, "Day"], None];
    If[!MatchQ[d, _DateObject], Return[False]];
    iSVDateInRange[d, spec]];
iSVPathDateInRange[_, _] := False;

(* \:30b7\:30f3\:30dc\:30ea\:30c3\:30af\:30d1\:30b9\:3092\:6b63\:898f\:5316\:6587\:5b57\:5217\:306b (ID \:751f\:6210\:7528\:3001\:533a\:5207\:308a\:306f / \:56fa\:5b9a) *)
iSVSymbolicPathString[symPath_List] :=
  StringRiffle[symPath, "/"];

(* NotebookRef: \:30b7\:30f3\:30dc\:30ea\:30c3\:30af\:30d1\:30b9\:30d9\:30fc\:30b9\:306e\:5b89\:5b9a ID (\:30af\:30ed\:30b9 PC / OS \:4e0d\:5909) *)
iNotebookRefFromPath[path_String] :=
  Module[{symPath, key, h},
    symPath = iSVSymbolicPath[path];
    key = iSVSymbolicPathString[symPath];
    h = Hash[key, "SHA256", "HexString"];
    "nb-src-" <> StringTake[h, 16]
  ];

(* Stage 9 P1 Step 8 Hotfix 2: \:30d5\:30a1\:30a4\:30eb\:30b5\:30a4\:30ba\:95be\:5024 (MB)\:3002
   \:3053\:308c\:3092\:8d85\:3048\:308b .nb \:306f index \:6642\:306b Import \:305b\:305a\:8efd\:91cf snapshot \:306e\:307f\:4f5c\:308b\:3002
   \:30b7\:30df\:30e5\:30ec\:30fc\:30b7\:30e7\:30f3\:7d50\:679c\:3092\:53ce\:3081\:305f\:5de8\:5927\:30ce\:30fc\:30c8 (\:6570\:767e MB\:ff5eGB) \:5bfe\:7b56\:3002 *)
If[!ValueQ[$SourceVaultMaxFileSizeMB], $SourceVaultMaxFileSizeMB = 50];

(* \:73fe\:5728\:306e\:95be\:5024 (MB) \:3092\:8fd4\:3059\:3002\:4e0d\:6b63\:5024\:306a\:3089 50 \:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3002 *)
iSVMaxFileSizeMB[] :=
  If[NumericQ[$SourceVaultMaxFileSizeMB] && $SourceVaultMaxFileSizeMB > 0,
    N[$SourceVaultMaxFileSizeMB], 50.];

(* Stage 9 P1 Step 6: snapshot \:306e\:4ee3\:8868 PrivacyLevel \:3092\:6c7a\:5b9a\:3002
   \:30ed\:30fc\:30ab\:30eb .nb \:306f NBAccess \:306e NBFileSpec \:5224\:5b9a\:3092\:7d99\:627f\:3002
   NBFileSpec \:306f 0.5 / 1.0 / {0.5, 1.0} \:6df7\:5728 \:3092\:8fd4\:3057\:5f97\:3001
   \:6df7\:5728\:6642\:306f\:6700\:3082\:53b3\:3057\:3044\:5024 (\:6700\:5927\:5024) \:3092\:63a1\:308b (\:5b89\:5168\:5074)\:3002
   NBAccess \:304c\:5229\:7528\:4e0d\:53ef\:307e\:305f\:306f\:5224\:5b9a\:4e0d\:80fd\:306a\:3089 1.0 (\:30af\:30e9\:30a6\:30c9\:7981\:6b62) \:3092\:8fd4\:3059\:3002 *)
iSVSnapshotPrivacyLevel[path_String] :=
  Module[{spec, pl},
    spec = Quiet @ Check[NBAccess`NBFileSpec[path], $Failed];
    If[!AssociationQ[spec], Return[1.0]];
    pl = Lookup[spec, "PrivacyLevel", 1.0];
    Which[
      NumericQ[pl], N[pl],
      ListQ[pl] && Length[pl] > 0 && AllTrue[pl, NumericQ], N[Max[pl]],
      True, 1.0
    ]
  ];

(* Notebook \:30d5\:30a1\:30a4\:30eb\:3092 safe \:306b\:8aad\:307f\:8fbc\:3080:
   - Import[path, "Notebook"] \:306f documented \:306b Notebook[{Cell[...], ...}, opts] \:5f0f\:3092\:8fd4\:3059
   - Notebook / Cell / BoxData / RowBox / CellGroupData \:306f\:5168\:3066 inert symbol\:3067\:526f\:4f5c\:7528\:306a\:3057
   - Cell \:5185\:306e BoxData \:306f\:8868\:793a\:7528 box \:5f62\:5f0f\:3067\:3001\:30e6\:30fc\:30b6\:30fc\:304c\:8a55\:4fa1\:3059\:308b\:307e\:3067\:5b9f\:884c\:3055\:308c\:306a\:3044
   - Safe Parse \:304c\:5fc5\:8981\:306a\:306e\:306f Header cell \:306e BoxData \:3092\:5f0f\:306b\:5909\:63db\:3059\:308b\:6642\:3060\:3051 (MakeExpression \:3067\:5b9f\:88c5)
   - Get[path] \:306f .nb \:306b\:5bfe\:3057\:3066 NotebookObject \:5316\:7b49\:306e\:7279\:6b8a\:52d5\:4f5c\:3092\:8d77\:3053\:3057\:5f97\:308b\:305f\:3081\:4f7f\:308f\:306a\:3044
*)
iReadNotebookExpr[path_String] :=
  Module[{nbExpr},
    If[!FileExistsQ[path],
      Return[<|"Status" -> "Failed", "Reason" -> "FileNotFound", "Path" -> path|>]];
    nbExpr = Quiet[Import[path, "Notebook"]];
    If[FailureQ[nbExpr] || !MatchQ[nbExpr, Notebook[_List, ___]],
      Return[<|"Status" -> "Failed", "Reason" -> "NotANotebookFile", "Path" -> path|>]];
    <|"Status" -> "OK", "Expr" -> HoldComplete[nbExpr], "Path" -> path|>
  ];

(* Cell content \:304b\:3089\:30c6\:30ad\:30b9\:30c8\:3092\:53d6\:308a\:51fa\:3059 (BoxData / TextData / plain string \:7b49):
   \:898b\:3084\:3059\:3044\:5358\:4e00\:6587\:5b57\:5217\:3092\:8fd4\:3059 *)
iCellTextExtract[content_] :=
  Module[{txt},
    txt = Which[
      StringQ[content], content,
      MatchQ[content, _BoxData] || MatchQ[content, _TextData] ||
        MatchQ[content, _StyleBox] || MatchQ[content, _RowBox],
        Quiet[ToString[content, StandardForm]],
      True, ToString[Unevaluated[content], InputForm]];
    If[!StringQ[txt], txt = ""];
    StringTrim[txt]
  ];

(* === Header parse (safe with whitelist) === *)

(*
  whitelist: \:30d8\:30c3\:30c0\:5024\:3068\:3057\:3066\:8a31\:53ef\:3059\:308b\:578b\:3092\:53b3\:5bc6\:306b\:9650\:5b9a
  - \:6587\:5b57\:5217 / \:6574\:6570 / \:5b9f\:6570
  - True / False
  - Missing[...]
  - DateObject[{y,m,d}] (3 \:8981\:7d20 list \:306e\:307f)
  - List of \:6587\:5b57\:5217
  - Association of \:4e0a\:8a18 (\:30cd\:30b9\:30c8\:3057\:305f Header \:3092\:8a31\:53ef)
*)
iAllowedHeaderValueQ[expr_] :=
  Or[
    StringQ[expr],
    IntegerQ[expr],
    NumericQ[expr] && Head[expr] === Real,
    expr === True, expr === False,
    MatchQ[expr, Missing[___]],
    MatchQ[expr, DateObject[{_Integer, _Integer, _Integer}, ___]],
    MatchQ[expr, DateObject[{_Integer, _Integer, _Integer, _Integer, _Integer, _?NumericQ}, ___]],
    (* NotebookStatus \:65b0\:65b9\:5f0f: NextReview/Deadline \:306b\:76f8\:5bfe\:6307\:5b9a Quantity[n,"Weeks"|"Days"|...] \:3092\:8a31\:53ef\:3002
       \:5024\:81ea\:4f53\:306f\:526f\:4f5c\:7528\:7121\:3057\:306e inert \:5358\:4f4d\:4ed8\:304d\:6570\:5024\:3002 *)
    MatchQ[expr, Quantity[_?NumericQ, _String]],
    MatchQ[expr, Quantity[_?NumericQ, _]],
    ListQ[expr] && AllTrue[expr, StringQ[#] || IntegerQ[#] &],
    AssociationQ[expr] && AllTrue[Values[expr], iAllowedHeaderValueQ]
  ];

(* Header parse: \:4e8c\:6bb5\:968e\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af
   (A) Import[path, "Initialization"] \:3092\:4f7f\:3046 \[LongDash] \:7c21\:6f54\:3001Wolfram \:7d44\:307f\:8fbc\:307f\:6a5f\:80fd\:3002
       \:6ce8\:610f: InitializationCell \:5185\:90e8\:3092 Wolfram \:304c\:8a55\:4fa1\:3059\:308b\:305f\:3081\:526f\:4f5c\:7528\:30b3\:30fc\:30c9\:3082\:8d70\:308b\:3002
       \:305d\:306e\:305f\:3081\:8fd4\:308a\:5024\:306e Association \:3092 whitelist \:3067\:30c1\:30a7\:30c3\:30af\:3057\:3066\:5fdc\:63f4\:3002
   (B) Import[path, "Notebook"] + MakeExpression \:3067 box \:3092\:8a55\:4fa1\:305b\:305a\:306b\:5f0f\:5316
*)

iNotebookHeaderParseFromInitialization[path_String] :=
  Module[{inits, assoc, parseStatus = "OK"},
    inits = Quiet[Import[path, "Initialization"]];
    If[!ListQ[inits] || inits === {},
      Return[Missing["InitImportFailed"]]];
    assoc = First[inits];
    If[!AssociationQ[assoc],
      Return[Missing["InitNotAssociation"]]];
    If[!AllTrue[Values[assoc], iAllowedHeaderValueQ],
      parseStatus = "UnsafeExpression"];
    <|"ParseStatus" -> parseStatus,
      "Keywords" -> Lookup[assoc, "Keywords", Missing["NotSpecified"]],
      "Deadline" -> Lookup[assoc, "Deadline", Missing["NotSpecified"]],
      "NextReview" -> Lookup[assoc, "NextReview", Missing["NotSpecified"]],
      "Status" -> Lookup[assoc, "Status", Missing["NotSpecified"]],
      "RawHeader" -> assoc,
      "Source" -> "Initialization"|>
  ];

iNotebookHeaderParseFromBoxes[nbExpr_HoldComplete] :=
  Module[{cells, headerCell, boxData, held, assoc, parseStatus = "OK"},
    cells = iFlattenCells[nbExpr];
    If[!ListQ[cells] || cells === {},
      Return[<|"ParseStatus" -> "MissingHeader"|>]];
    headerCell = SelectFirst[cells, iCellIsInitializationInputQ, Missing[]];
    If[MissingQ[headerCell],
      (* fallback: \:6700\:521d\:306e Input Cell (context \:975e\:4f9d\:5b58\:3067\:691c\:7d22) *)
      headerCell = SelectFirst[cells, Function[c,
        SymbolName[Head[c]] === "Cell" &&
          Length[c] >= 2 && StringQ[c[[2]]] && c[[2]] === "Input"],
        Missing[]]];
    If[MissingQ[headerCell],
      Return[<|"ParseStatus" -> "MissingHeader"|>]];
    boxData = First[headerCell];
    held = Quiet[MakeExpression[boxData, StandardForm]];
    If[!MatchQ[held, HoldComplete[_Association]],
      Return[<|"ParseStatus" -> "UnsafeExpression",
        "RawExpr" -> ToString[held, InputForm],
        "Source" -> "MakeExpression"|>]];
    assoc = ReleaseHold[held];
    If[!AllTrue[Values[assoc], iAllowedHeaderValueQ],
      parseStatus = "UnsafeExpression"];
    <|"ParseStatus" -> parseStatus,
      "Keywords" -> Lookup[assoc, "Keywords", Missing["NotSpecified"]],
      "Deadline" -> Lookup[assoc, "Deadline", Missing["NotSpecified"]],
      "NextReview" -> Lookup[assoc, "NextReview", Missing["NotSpecified"]],
      "Status" -> Lookup[assoc, "Status", Missing["NotSpecified"]],
      "RawHeader" -> assoc,
      "Source" -> "MakeExpression"|>
  ];

(* === NotebookStatus \:30b9\:30bf\:30a4\:30eb\:30bb\:30eb\:304b\:3089\:306e Header \:62bd\:51fa (\:65b0\:65b9\:5f0f\:3001\:7b2c\:4e00\:9078\:629e) ===
   \:4eca\:5f8c\:306f\:521d\:671f\:5316\:30bb\:30eb\:3067\:306f\:306a\:304f "NotebookStatus" \:30b9\:30bf\:30a4\:30eb\:306e\:30bb\:30eb\:306b
   <|"Keywords"->..., "NextReview"->..., "Status"->...|> \:3092\:683c\:7d0d\:3059\:308b\:3002
   NotebookImport[path, "NotebookStatus"] \:306f {BoxData[...]} \:3092\:8fd4\:3059\:306e\:3067\:3001
   \:305d\:306e BoxData \:3092 MakeExpression \:3067\:5b89\:5168\:306b\:5f0f\:5316\:3059\:308b (\:7f60 #22 \:7d4c\:8def\:3001\:526f\:4f5c\:7528\:7121\:3057)\:3002
   \:898b\:3064\:304b\:3089\:306a\:3051\:308c\:3070 Missing["NoStatusCell"] \:3092\:8fd4\:3057\:3001\:547c\:3073\:51fa\:3057\:5074\:304c
   \:5f93\:6765\:65b9\:5f0f (MakeExpression \:521d\:671f\:5316\:30bb\:30eb / Initialization) \:306b fallback \:3059\:308b\:3002 *)
iNotebookHeaderParseFromStatusCell[path_String] :=
  Module[{imported, boxData, held, assoc, parseStatus = "OK"},
    If[!FileExistsQ[path], Return[Missing["FileNotFound"]]];
    (* NotebookStatus \:30b9\:30bf\:30a4\:30eb\:306e\:30bb\:30eb\:5185\:5bb9\:3092 BoxData \:3068\:3057\:3066\:53d6\:5f97 *)
    imported = Quiet @ Check[
      NotebookImport[path, "NotebookStatus" -> "BoxData"], $Failed];
    (* "NotebookStatus" -> "BoxData" \:304c\:7121\:52b9\:306a\:74b0\:5883\:5411\:3051\:306b\:7d20\:306e\:30b9\:30bf\:30a4\:30eb\:6307\:5b9a\:3082\:8a66\:3059 *)
    If[!ListQ[imported] || imported === {},
      imported = Quiet @ Check[
        NotebookImport[path, "NotebookStatus"], $Failed]];
    If[!ListQ[imported] || imported === {},
      Return[Missing["NoStatusCell"]]];
    (* \:6700\:521d\:306e BoxData (\:8907\:6570\:3042\:308c\:3070\:5148\:982d) \:3092\:4f7f\:3046 *)
    boxData = SelectFirst[imported,
      SymbolName[Head[#]] === "BoxData" &, First[imported]];
    held = Quiet[MakeExpression[boxData, StandardForm]];
    If[!MatchQ[held, HoldComplete[_Association]],
      Return[Missing["StatusCellNotAssociation"]]];
    assoc = ReleaseHold[held];
    If[!AllTrue[Values[assoc], iAllowedHeaderValueQ],
      parseStatus = "UnsafeExpression"];
    <|"ParseStatus" -> parseStatus,
      "Keywords" -> Lookup[assoc, "Keywords", Missing["NotSpecified"]],
      "Deadline" -> iSVResolveRelativeDate[
        Lookup[assoc, "Deadline", Missing["NotSpecified"]]],
      "NextReview" -> iSVResolveRelativeDate[
        Lookup[assoc, "NextReview", Missing["NotSpecified"]]],
      "Status" -> Lookup[assoc, "Status", Missing["NotSpecified"]],
      "RawHeader" -> assoc,
      "Source" -> "NotebookStatus"|>
  ];

(* \:76f8\:5bfe\:65e5\:4ed8\:6307\:5b9a (Quantity[n,"Weeks"] \:7b49) \:3092\:7d76\:5bfe\:65e5\:4ed8 DateObject \:306b\:89e3\:6c7a\:3002
   \:57fa\:6e96\:306f\:4eca\:65e5 (DateObject[Today])\:3002\:65e2\:306b DateObject / \:6587\:5b57\:5217 / Missing \:306f\:305d\:306e\:307e\:307e\:8fd4\:3059\:3002
   NextReview->Quantity[2,"Weeks"] \:306a\:3089 2 \:9031\:9593\:5f8c\:306e\:65e5\:4ed8\:3068\:306a\:308b\:3002 *)
iSVResolveRelativeDate[v_] :=
  Which[
    MatchQ[v, Quantity[_?NumericQ, _]],
      Quiet @ Check[
        DateObject[DatePlus[Today, v], "Day"],
        v],
    True, v];


(* \:30e1\:30a4\:30f3\:30a8\:30f3\:30c8\:30ea\:30fc (path \:7248): 3 \:6bb5\:968e\:30cf\:30a4\:30d6\:30ea\:30c3\:30c9\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af
   2026-06: NotebookStatus \:30b9\:30bf\:30a4\:30eb\:30bb\:30eb\:65b9\:5f0f\:3078\:306e\:6bb5\:968e\:79fb\:884c\:3002
     (0) NotebookStatus \:30b9\:30bf\:30a4\:30eb\:30bb\:30eb (\:65b0\:65b9\:5f0f\:3001\:7b2c\:4e00\:9078\:629e)
     (B) Import["Notebook"] + MakeExpression (\:5f93\:6765\:306e\:521d\:671f\:5316\:30bb\:30eb box)
     (A) Import["Initialization"] (\:8a55\:4fa1\:526f\:4f5c\:7528\:6709\:308a\:3001\:6700\:7d42 fallback)
   \:79fb\:884c\:5b8c\:4e86\:307e\:3067\:306f\:30cf\:30a4\:30d6\:30ea\:30c3\:30c9\:904b\:7528\:3002NotebookStatus \:30bb\:30eb\:7121\:3057\:306f\:5f93\:6765\:65b9\:5f0f\:3067\:8aad\:3080\:3002 *)
iNotebookHeaderParse[path_String] :=
  Module[{statusResult, readResult, boxResult, initResult},
    (* (0) \:7b2c\:4e00\:9078\:629e: NotebookStatus \:30b9\:30bf\:30a4\:30eb\:30bb\:30eb (\:65b0\:65b9\:5f0f) *)
    statusResult = iNotebookHeaderParseFromStatusCell[path];
    If[AssociationQ[statusResult] &&
        MemberQ[{"OK", "UnsafeExpression"},
          Lookup[statusResult, "ParseStatus", ""]],
      Return[statusResult]];
    (* (B) fallback: Import["Notebook"] + MakeExpression (\:526f\:4f5c\:7528\:306a\:3057) *)
    readResult = iReadNotebookExpr[path];
    If[Lookup[readResult, "Status", ""] === "OK",
      boxResult = iNotebookHeaderParseFromBoxes[Lookup[readResult, "Expr"]];
      If[AssociationQ[boxResult] &&
          MemberQ[{"OK", "UnsafeExpression"},
            Lookup[boxResult, "ParseStatus", ""]],
        Return[boxResult]]];
    (* (A) fallback: Import["Initialization"] (\:8a55\:4fa1\:526f\:4f5c\:7528\:6709\:308a) *)
    initResult = iNotebookHeaderParseFromInitialization[path];
    If[AssociationQ[initResult] && KeyExistsQ[initResult, "ParseStatus"],
      Return[initResult]];
    (* \:6700\:7d42 fallback: MissingHeader *)
    If[AssociationQ[boxResult] && KeyExistsQ[boxResult, "ParseStatus"],
      Return[boxResult]];
    <|"ParseStatus" -> "MissingHeader",
      "Reason" -> Lookup[readResult, "Reason", "ReadFailed"]|>
  ];

(* HoldComplete \:7248 (\:9593\:63a5\:547c\:51fa\:3057\:4e92\:63db) *)
iNotebookHeaderParse[nbExpr_HoldComplete] :=
  iNotebookHeaderParseFromBoxes[nbExpr];

(* === Todo cell \:62bd\:51fa === *)

(* CellGroupData \:3092\:8d8a\:3048\:3066\:5168 Cell \:3092\:518d\:5e30\:7684\:306b flatten\:3002
   \:6ce8\:610f: \:30d1\:30b9\:30a8\:30fc\:30f3\:5185\:3067 Cell / Notebook / CellGroupData \:3092\:30d1\:30bf\:30fc\:30f3\:30de\:30c3\:30c1\:30f3\:30b0\:3059\:308b\:3068
   SourceVault`Private` \:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:306e\:30b7\:30f3\:30dc\:30eb\:3068\:3057\:3066\:89e3\:91c8\:3055\:308c\:308b\:3053\:3068\:304c\:3042\:308a\:3001
   Import[path, "Notebook"] \:304c\:8fd4\:3059 System` \:30b7\:30f3\:30dc\:30eb\:3068\:30de\:30c3\:30c1\:3057\:306a\:3044\:3002
   \:305d\:306e\:305f\:3081 SymbolName[Head[...]] \:3067 \:6587\:5b57\:5217\:6bd4\:8f03\:3059\:308b context \:975e\:4f9d\:5b58\:5b9f\:88c5\:3068\:3059\:308b\:3002 *)
iFlattenCells[nbExpr_HoldComplete] :=
  Module[{nbAtom, cells},
    nbAtom = Replace[nbExpr, HoldComplete[x_] :> x, {0}];
    If[SymbolName[Head[nbAtom]] =!= "Notebook",
      Return[{}]];
    If[Length[nbAtom] < 1, Return[{}]];
    cells = First[nbAtom];
    If[!ListQ[cells], Return[{}]];
    Flatten[Map[iFlattenCellRec, cells]]
  ];

iFlattenCellRec[c_] :=
  Module[{args, firstArg, innerCells},
    If[SymbolName[Head[c]] =!= "Cell", Return[{}]];
    args = List @@ c;
    If[Length[args] === 0, Return[{}]];
    firstArg = First[args];
    If[SymbolName[Head[firstArg]] === "CellGroupData" && Length[firstArg] >= 1,
      innerCells = First[firstArg];
      If[ListQ[innerCells],
        Return[Flatten[Map[iFlattenCellRec, innerCells]]]];
      Return[{}]];
    {c}
  ];

(* Cell \:306e options Association \:3092\:53d6\:308a\:51fa\:3059 (context \:975e\:4f9d\:5b58) *)
iCellOptionsAssociation[c_] :=
  Module[{args},
    If[SymbolName[Head[c]] =!= "Cell", Return[<||>]];
    args = List @@ c;
    If[Length[args] < 3, Return[<||>]];
    Association[Cases[Drop[args, 2], _Rule]]
  ];

(* FontVariations -> {"StrikeThrough" -> True} \:5224\:5b9a (context \:975e\:4f9d\:5b58: SymbolName \:3067\:691c\:7d22) *)
iStrikeThroughQ[opts_Association] :=
  Module[{fvKey, fv},
    fvKey = SelectFirst[Keys[opts],
      SymbolName[#] === "FontVariations" &, Null];
    If[fvKey === Null, Return[False]];
    fv = opts[fvKey];
    If[!ListQ[fv], Return[False]];
    TrueQ[Lookup[Association[fv], "StrikeThrough", False]]
  ];

(* InitializationCell -> True \:306e Input \:30bb\:30eb\:304b (context \:975e\:4f9d\:5b58) *)
iCellIsInitializationInputQ[c_] :=
  Module[{args, opts, initKey},
    If[SymbolName[Head[c]] =!= "Cell", Return[False]];
    args = List @@ c;
    If[Length[args] < 2, Return[False]];
    If[!StringQ[args[[2]]] || args[[2]] =!= "Input", Return[False]];
    opts = Association[Cases[Drop[args, 2], _Rule]];
    initKey = SelectFirst[Keys[opts],
      SymbolName[#] === "InitializationCell" &, Null];
    If[initKey === Null, Return[False]];
    TrueQ[opts[initKey]]
  ];

(* Todo \:306e Status \:3068 StatusSource \:3092\:5224\:5b9a (\:30ec\:30d3\:30e5\:30fc \[Section] 3.4 \:512a\:5148\:9806\:4f4d) *)
(* FontColor \:304b\:3089 Done/Pass \:3092\:5224\:5b9a\:3059\:308b helper:
   - GrayLevel[_]      \:307e\:305f\:306f RGB(r,g,b) \:3067 r\[TildeTilde]g\[TildeTilde]b   \[RightArrow] \"Pass\" (\:30b0\:30ec\:30fc\:3001\:30b9\:30ad\:30c3\:30d7)
   - RGB(r,g,b) \:3067 g > r && g > b                                  \[RightArrow] \"Done\" (\:7dd1\:3001\:5b8c\:4e86)
   - \:305d\:306e\:4ed6                                                   \[RightArrow] \"Done\" (\:30c7\:30d5\:30a9\:30eb\:30c8\:3001\:5f8c\:65b9\:4e92\:63db) *)
iColorIsGrayQ[fc_] :=
  MatchQ[fc, GrayLevel[_?NumericQ]] ||
  MatchQ[fc, GrayLevel[_?NumericQ, _?NumericQ]] ||
  MatchQ[fc, RGBColor[r_?NumericQ, g_?NumericQ, b_?NumericQ] /;
    Abs[r - g] < 0.05 && Abs[g - b] < 0.05 && Abs[r - b] < 0.05] ||
  MatchQ[fc, RGBColor[r_?NumericQ, g_?NumericQ, b_?NumericQ, _?NumericQ] /;
    Abs[r - g] < 0.05 && Abs[g - b] < 0.05 && Abs[r - b] < 0.05];

iColorIsGreenQ[fc_] :=
  MatchQ[fc, RGBColor[r_?NumericQ, g_?NumericQ, b_?NumericQ] /;
    g > r && g > b && (g - Min[r, b] > 0.1)] ||
  MatchQ[fc, RGBColor[r_?NumericQ, g_?NumericQ, b_?NumericQ, _?NumericQ] /;
    g > r && g > b && (g - Min[r, b] > 0.1)];

(* FontColor \:3092 options \:304b\:3089\:53d6\:308a\:51fa\:3059 (context \:975e\:4f9d\:5b58) *)
iCellFontColor[opts_Association] :=
  Module[{fcKey},
    fcKey = SelectFirst[Keys[opts], SymbolName[#] === "FontColor" &, Null];
    If[fcKey === Null, Null, opts[fcKey]]
  ];

iTodoStatusFromOptions[opts_Association] :=
  Module[{tagKey, tagging, todoStatus, strike, fc, sv},
    (* 1. TaggingRules \:7d4c\:7531\:306e\:660e\:793a TodoStatus (\:5c06\:6765\:306e\:6a19\:6e96\:3001context \:975e\:4f9d\:5b58\:691c\:7d22) *)
    tagKey = SelectFirst[Keys[opts],
      SymbolName[#] === "TaggingRules" &, Null];
    tagging = If[tagKey =!= Null, opts[tagKey], Missing[]];
    If[AssociationQ[tagging],
      sv = Lookup[tagging, "SourceVault", Missing[]];
      If[AssociationQ[sv],
        todoStatus = Lookup[sv, "TodoStatus", Missing[]];
        If[StringQ[todoStatus],
          Return[<|"Status" -> todoStatus, "StatusSource" -> "TaggingRules"|>]]];
      todoStatus = Lookup[tagging, "TodoStatus", Missing[]];
      If[StringQ[todoStatus],
        Return[<|"Status" -> todoStatus, "StatusSource" -> "TaggingRules"|>]]];
    
    (* 2. StrikeThrough + FontColor heuristic (3 \:5024\:5224\:5b9a) *)
    strike = iStrikeThroughQ[opts];
    fc = iCellFontColor[opts];
    
    If[!strike,
      (* StrikeThrough \:306a\:3057 \[RightArrow] Open (Todo) *)
      Return[<|"Status" -> "Open", "StatusSource" -> "Default"|>]
    ];
    
    (* StrikeThrough \:3042\:308a \[RightArrow] FontColor \:3067 Done/Pass \:3092\:533a\:5225 *)
    Which[
      iColorIsGrayQ[fc],
        <|"Status" -> "Pass", "StatusSource" -> "CellOptionGray"|>,
      iColorIsGreenQ[fc],
        <|"Status" -> "Done", "StatusSource" -> "CellOptionGreen"|>,
      True,
        (* StrikeThrough \:3060\:3051\:3001\:8272\:306f\:4e0d\:660e\:3068 \[RightArrow] Done (\:5f8c\:65b9\:4e92\:63db) *)
        <|"Status" -> "Done", "StatusSource" -> "CellOption"|>
    ]
  ];

(* Notebook \:5168\:4f53\:304b\:3089 TodoItem \:30b9\:30bf\:30a4\:30eb\:306e Cell \:3092\:5217\:6319 *)

(* iExtractTodoCells (HoldComplete \:7248): pattern-match \:30d9\:30fc\:30b9 \[LongDash] \:7d4c\:8def\:3068\:3057\:3066\:6b8b\:7f6e\:3060\:304c\:63a8\:5968\:3055\:308c\:308b\:306e\:306f iExtractTodoCellsFromPath *)
iExtractTodoCells[nbExpr_HoldComplete] :=
  Module[{allCells, results = {}, idx = 0},
    allCells = iFlattenCells[nbExpr];
    Scan[Function[c,
      Module[{args, style, txt, opts, status},
        If[SymbolName[Head[c]] === "Cell",
          args = List @@ c;
          If[Length[args] >= 2 && StringQ[args[[2]]],
            style = args[[2]];
            If[StringStartsQ[style, "TodoItem"],
              idx = idx + 1;
              txt = iCellTextExtract[args[[1]]];
              opts = iCellOptionsAssociation[c];
              status = iTodoStatusFromOptions[opts];
              AppendTo[results, <|
                "Index" -> idx,
                "CellStyle" -> style,
                "Text" -> txt,
                "Status" -> status["Status"],
                "StatusSource" -> status["StatusSource"],
                "StrikeThrough" -> iStrikeThroughQ[opts]
              |>]]]]]], allCells];
    results
  ];

(* Stage 9 P0 \:63a8\:5968\:5b9f\:88c5: NotebookImport[path, style -> "Cell"] \:3092\:4f7f\:3046
   - Wolfram \:6a19\:6e96\:95a2\:6570 (NotebookImport) \:306a\:306e\:3067 context \:554f\:984c\:7121\:3057
   - \:30d1\:30bf\:30fc\:30f3\:30de\:30c3\:30c1\:30f3\:30b0\:4e0d\:8981\:3001Notebook \:306e\:69cb\:9020\:5909\:66f4\:306b\:5f37\:3044
   - TodoItem_1 / TodoItem_2 / TodoItem_3 \:306e 3 \:30b9\:30bf\:30a4\:30eb\:3092\:9806\:306b\:8a66\:3059
   - \:9650\:5b9a\:7684\:30b9\:30bf\:30a4\:30eb\:3060\:3051\:3092\:7279\:5b9a\:3057\:3066\:53d6\:308a\:51fa\:3059\:306e\:3067\:9ad8\:901f *)
iExtractTodoCellsFromPath[path_String] :=
  Module[{styles, results = {}, idx = 0},
    If[!FileExistsQ[path], Return[{}]];
    styles = {"TodoItem_1", "TodoItem_2", "TodoItem_3"};
    Scan[
      Function[style,
        Module[{cells},
          cells = Quiet[NotebookImport[path, style -> "Cell"]];
          If[ListQ[cells],
            Scan[
              Function[c,
                If[SymbolName[Head[c]] === "Cell" && Length[c] >= 2,
                  Module[{args = List @@ c, txt, opts, status},
                    idx = idx + 1;
                    txt = iCellTextExtract[args[[1]]];
                    opts = Association[Cases[Drop[args, 2], _Rule]];
                    status = iTodoStatusFromOptions[opts];
                    AppendTo[results, <|
                      "Index" -> idx,
                      "CellStyle" -> style,
                      "Text" -> txt,
                      "Status" -> status["Status"],
                      "StatusSource" -> status["StatusSource"],
                      "StrikeThrough" -> iStrikeThroughQ[opts]
                    |>]
                  ]
                ]
              ],
              cells
            ]
          ]
        ]
      ],
      styles
    ];
    results
  ];

(* === Review / Deadline state \:8a08\:7b97 === *)

iComputeReviewState[nextReview_, today_] :=
  Which[
    MissingQ[nextReview], "NoReviewDate",
    MatchQ[nextReview, _DateObject],
      Module[{diff},
        diff = Quiet[QuantityMagnitude[
          DateDifference[nextReview, today, "Day"]]];
        (* diff > 0  : nextReview \:304c\:904e\:53bb (today \:304c\:5f8c) = \:671f\:9650\:5207\:308c
           diff == 0 : \:4eca\:65e5
           diff < 0  : nextReview \:304c\:672a\:6765
           \:7f60: \:5f93\:6765 diff>0 \:3092\:4e00\:5f8b "Overdue" \:306b\:3057\:3066\:3044\:305f\:305f\:3081\:3001"ThisWeek"
           \:30d5\:30a3\:30eb\:30bf\:304c\:6628\:5e74\:306e\:671f\:9650\:5207\:308c\:307e\:3067\:62fe\:3063\:3066\:3044\:305f\:3002\:4eca\:9031\:5185 (7\:65e5\:4ee5\:5185) \:306b
           \:904e\:304e\:305f\:3082\:306e\:3092 "OverdueThisWeek" \:3068\:3057\:3066\:5206\:96e2\:3059\:308b\:3002 *)
        Which[
          !NumericQ[diff], "NoReviewDate",
          diff > 7, "Overdue",
          diff > 0, "OverdueThisWeek",
          diff == 0, "DueToday",
          diff >= -7, "DueThisWeek",
          True, "Current"]],
    True, "NoReviewDate"
  ];

iComputeDeadlineState[deadline_, today_] :=
  Which[
    MissingQ[deadline], "NoDeadline",
    MatchQ[deadline, _DateObject],
      Module[{diff},
        diff = Quiet[QuantityMagnitude[
          DateDifference[deadline, today, "Day"]]];
        (* \:7f60\:540c\:69d8: \:4eca\:9031\:5185 (7\:65e5\:4ee5\:5185) \:306b\:904e\:304e\:305f\:671f\:9650\:5207\:308c\:3092
           "OverdueThisWeek" \:3068\:3057\:3066\:9060\:3044\:904e\:53bb "Overdue" \:3068\:533a\:5225\:3059\:308b\:3002 *)
        Which[
          !NumericQ[diff], "NoDeadline",
          diff > 7, "Overdue",
          diff > 0, "OverdueThisWeek",
          diff == 0, "DueToday",
          diff >= -7, "DueSoon",
          True, "Future"]],
    True, "NoDeadline"
  ];

(* === Lint \:8a08\:7b97 === *)

iComputeNotebookLint[record_Association] :=
  Module[{lints = {}, header, todos, openCount, doneCount, passCount,
          closedCount, hasHeuristic, status, deadline, nextReview, today,
          parseStatus},
    header = Lookup[record, "Header", <||>];
    todos = Lookup[record, "Todos", {}];
    today = DateObject[Now, "Day"];
    
    parseStatus = Lookup[header, "ParseStatus", "MissingHeader"];
    If[parseStatus === "MissingHeader",
      AppendTo[lints, "MissingHeader"]];
    If[parseStatus === "UnsafeExpression",
      AppendTo[lints, "UnsafeHeaderExpression"]];
    
    deadline = Lookup[header, "Deadline", Missing[]];
    nextReview = Lookup[header, "NextReview", Missing[]];
    status = Lookup[header, "Status", Missing[]];
    
    (* Malformed date check *)
    If[!MissingQ[deadline] && !MatchQ[deadline, _DateObject],
      AppendTo[lints, "HeaderDeadlineMalformed"]];
    If[!MissingQ[nextReview] && !MatchQ[nextReview, _DateObject],
      AppendTo[lints, "HeaderNextReviewMalformed"]];
    
    openCount = Count[todos, t_Association /; Lookup[t, "Status", ""] === "Open"];
    doneCount = Count[todos, t_Association /; Lookup[t, "Status", ""] === "Done"];
    passCount = Count[todos, t_Association /; Lookup[t, "Status", ""] === "Pass"];
    closedCount = doneCount + passCount;   (* Done + Pass = \:9589\:3058\:305f Todo *)
    
    (* Header / Todo \:6574\:5408\:6027 (Done \:3082 Pass \:3082 closed \:3068\:3057\:3066\:6271\:3046) *)
    If[StringQ[status] && status === "Todo" && Length[todos] > 0 && openCount === 0,
      AppendTo[lints, "HeaderStatusTodoButNoOpenTodos"]];
    If[StringQ[status] && status === "Done" && openCount > 0,
      AppendTo[lints, "HeaderStatusDoneButOpenTodosExist"]];
    
    (* Date past check *)
    If[MatchQ[deadline, _DateObject],
      Module[{diff = Quiet[QuantityMagnitude[
        DateDifference[deadline, today, "Day"]]]},
        If[NumericQ[diff] && diff > 0,
          AppendTo[lints, "DeadlinePast"]]]];
    If[MatchQ[nextReview, _DateObject],
      Module[{diff = Quiet[QuantityMagnitude[
        DateDifference[nextReview, today, "Day"]]]},
        If[NumericQ[diff] && diff > 0,
          AppendTo[lints, "NextReviewPast"]]]];
    
    (* Heuristic \:306e\:307f\:3067 Done/Pass \:5224\:5b9a\:3055\:308c\:305f Todo \:306e\:8b66\:544a
       StatusSource \:304c "CellOption" / "CellOptionGreen" / "CellOptionGray" \:306e\:3044\:305a\:308c\:304b *)
    hasHeuristic = AnyTrue[todos,
      StringQ[Lookup[#, "StatusSource", ""]] &&
      StringStartsQ[Lookup[#, "StatusSource", ""], "CellOption"] &];
    If[hasHeuristic && !AnyTrue[todos,
        Lookup[#, "StatusSource", ""] === "TaggingRules" &],
      AppendTo[lints, "TodoCellStatusHeuristicOnly"]];
    
    lints
  ];

(* === FindNotebooks: query match === *)

iNotebookRecordMatchesQuery[record_Association, query_Association,
  today_] :=
  Module[{ok = True, openTodoQ, nextReviewQ, deadlineQ, keywordsQ, titleQ,
          searchTerms, statusQ,
          openCount, header, reviewState, deadlineState, kws, hdrStatus,
          scopeQ},
    header = Lookup[record, "Header", <||>];
    openCount = Lookup[record, "OpenTodoCount", 0];
    reviewState = Lookup[record, "ReviewState", "NoReviewDate"];
    deadlineState = Lookup[record, "DeadlineState", "NoDeadline"];
    
    (* OpenTodos *)
    openTodoQ = Lookup[query, "OpenTodos", Missing[]];
    If[!MissingQ[openTodoQ],
      If[TrueQ[openTodoQ], If[openCount === 0, ok = False],
        If[openCount > 0, ok = False]]];
    
    (* NextReview: "Today" \:306f\:53b3\:5bc6\:306b\:4eca\:65e5\:306e\:307f\:3002
       "ThisWeek"/"DueSoon" \:306f\:5f93\:6765\:901a\:308a\:300c\:4eca\:65e5\:307e\:3067 + \:4eca\:65e5\:304b\:30897\:65e5\:5185\:300d\:3092
       \:5305\:3080 (DueToday \:8ffd\:52a0\:3082\:5f8c\:65b9\:4e92\:63db)\:3002
       Association \:306e\:7bc4\:56f2\:6307\:5b9a (<|"From"->_,"To"->_|>) \:306b\:3082\:5bfe\:5fdc\:3059\:308b\:3002 *)
    nextReviewQ = Lookup[query, "NextReview", Missing[]];
    If[ok && !MissingQ[nextReviewQ],
      Which[
        StringQ[nextReviewQ],
          Switch[nextReviewQ,
            "Today", If[reviewState =!= "DueToday", ok = False],
            (* "Overdue" \:5358\:72ec\:30af\:30a8\:30ea\:306f\:5f93\:6765\:901a\:308a\:300c\:671f\:9650\:5207\:308c\:5168\:90e8\:300d:
               \:9060\:3044\:904e\:53bb (Overdue) + \:4eca\:9031\:5185\:306b\:904e\:304e\:305f (OverdueThisWeek) \:4e21\:65b9 *)
            "Overdue", If[!MemberQ[{"Overdue", "OverdueThisWeek"}, reviewState], ok = False],
            (* "ThisWeek": \:4eca\:65e5 + \:4eca\:9031\:5185 (\:524d\:5f8c7\:65e5) \:306e\:307f\:3002\:9060\:3044\:904e\:53bb Overdue \:306f\:9664\:5916\:3002 *)
            "ThisWeek", If[!MemberQ[{"DueToday", "DueThisWeek", "OverdueThisWeek"}, reviewState], ok = False],
            "DueSoon", If[!MemberQ[{"DueToday", "DueThisWeek", "OverdueThisWeek"}, reviewState], ok = False],
            _, Null],
        AssociationQ[nextReviewQ],
          (* Header.NextReview \:307e\:305f\:306f\:30d5\:30a1\:30a4\:30eb\:540d\:65e5\:4ed8 (yyyymmdd-title.nb) \:306e
             \:3044\:305a\:308c\:304b\:304c\:7bc4\:56f2\:5185\:306a\:3089 True\:3002Imai \:5148\:751f\:306e\:898f\:7d04\:306b\:5408\:308f\:305b\:3066
             \:5bdb\:5bb9\:306b\:62fe\:3046\:3002 *)
          If[!(iSVDateInRange[Lookup[header, "NextReview", Missing[]], nextReviewQ] ||
               iSVPathDateInRange[Lookup[record, "Path",
                 Lookup[record, "OriginalPath", ""]], nextReviewQ]),
            ok = False],
        True, Null]];
    
    (* Deadline: "Today" \:306f\:53b3\:5bc6\:306b\:4eca\:65e5\:306e\:307f\:3002ThisWeek/DueSoon \:306f\:5f93\:6765\:901a\:308a\:3002
       Association \:306e\:7bc4\:56f2\:6307\:5b9a (<|"From"->_,"To"->_|>) \:306b\:3082\:5bfe\:5fdc\:3059\:308b\:3002 *)
    deadlineQ = Lookup[query, "Deadline", Missing[]];
    If[ok && !MissingQ[deadlineQ],
      Which[
        StringQ[deadlineQ],
          Switch[deadlineQ,
            "Today", If[deadlineState =!= "DueToday", ok = False],
            (* "Overdue" \:5358\:72ec\:30af\:30a8\:30ea\:306f\:671f\:9650\:5207\:308c\:5168\:90e8 (\:9060\:3044\:904e\:53bb + \:4eca\:9031\:5185) *)
            "Overdue", If[!MemberQ[{"Overdue", "OverdueThisWeek"}, deadlineState], ok = False],
            (* "ThisWeek": \:4eca\:65e5 + \:4eca\:9031\:5185 (\:524d\:5f8c7\:65e5) \:306e\:307f\:3002\:9060\:3044\:904e\:53bb Overdue \:306f\:9664\:5916\:3002 *)
            "ThisWeek", If[!MemberQ[{"DueToday", "DueSoon", "OverdueThisWeek"}, deadlineState], ok = False],
            "DueSoon", If[!MemberQ[{"DueToday", "DueSoon", "OverdueThisWeek"}, deadlineState], ok = False],
            _, Null],
        AssociationQ[deadlineQ],
          (* Header.Deadline \:307e\:305f\:306f\:30d5\:30a1\:30a4\:30eb\:540d\:65e5\:4ed8 (yyyymmdd-title.nb) \:306e
             \:3044\:305a\:308c\:304b\:304c\:7bc4\:56f2\:5185\:306a\:3089 True (Imai \:5148\:751f\:898f\:7d04)\:3002 *)
          If[!(iSVDateInRange[Lookup[header, "Deadline", Missing[]], deadlineQ] ||
               iSVPathDateInRange[Lookup[record, "Path",
                 Lookup[record, "OriginalPath", ""]], deadlineQ]),
            ok = False],
        True, Null]];
    
    (* Keywords (\:3044\:305a\:308c\:304b\:306b match) *)
    (* Stage 9 P1.5: Keywords / Title \:90e8\:5206\:4e00\:81f4\:691c\:7d22\:3002
       - "Keywords" \:3068 "Title" \:306f\:540c\:7b49\:6271\:3044 (\:3069\:3061\:3089\:3092\:6307\:5b9a\:3057\:3066\:3082\:540c\:3058\:691c\:7d22\:30d7\:30fc\:30eb\:3092\:898b\:308b)\:3002
       - \:5404\:30af\:30a8\:30ea\:6587\:5b57\:5217\:306f StringContainsQ \:3067\:90e8\:5206\:4e00\:81f4 (\:300c\:4f1a\:8b70\:300d\[RightArrow]\:300c\:5b66\:79d1\:4f1a\:8b70\:300d\:3082\:62fe\:3046)\:3002
       - \:691c\:7d22\:30d7\:30fc\:30eb: Header.Keywords \:306e\:5404\:6587\:5b57\:5217 + Header.Title + FileBaseName[Path]
         + \:89aa\:30d5\:30a9\:30eb\:30c0\:540d (FileNameTake[DirectoryName[path], -1])\:3002
         Path \:5168\:4f53\:306f\:4f7f\:308f\:306a\:3044 (\:5171\:901a\:30d5\:30a9\:30eb\:30c0 "On Work" \:7b49\:3067\:8aa4\:30de\:30c3\:30c1\:3092\:9632\:3050)\:3002
       - \:8907\:6570\:30af\:30a8\:30ea\:6587\:5b57\:5217\:306f OR (\:3069\:308c\:304b\:306b\:30de\:30c3\:30c1\:3059\:308c\:3070\:8a72\:5f53)\:3002
       - \:4e21\:30aa\:30d7\:30b7\:30e7\:30f3\:3092\:540c\:6642\:6307\:5b9a\:3057\:305f\:5834\:5408\:306f Join \:3057\:3066\:540c\:3058\:52d5\:4f5c\:3002 *)
    keywordsQ = Lookup[query, "Keywords", Missing[]];
    titleQ = Lookup[query, "Title", Missing[]];
    searchTerms = Join[
      Which[
        ListQ[keywordsQ], Select[keywordsQ, StringQ],
        StringQ[keywordsQ], {keywordsQ},
        True, {}],
      Which[
        ListQ[titleQ], Select[titleQ, StringQ],
        StringQ[titleQ], {titleQ},
        True, {}]];
    If[ok && Length[searchTerms] > 0,
      Module[{hdrKws, hdrTitle, recPath, fileName, parentDir, pool, matched},
        hdrKws = Lookup[header, "Keywords", {}];
        If[!ListQ[hdrKws], hdrKws = {}];
        hdrTitle = Lookup[header, "Title", ""];
        recPath = Lookup[record, "Path", Lookup[record, "OriginalPath", ""]];
        fileName = If[StringQ[recPath] && recPath =!= "",
          FileBaseName[recPath], ""];
        parentDir = If[StringQ[recPath] && recPath =!= "",
          Quiet[FileNameTake[DirectoryName[recPath], -1]], ""];
        If[!StringQ[parentDir], parentDir = ""];
        pool = DeleteCases[
          Join[Select[hdrKws, StringQ],
               {If[StringQ[hdrTitle], hdrTitle, ""], fileName, parentDir}],
          ""];
        matched = AnyTrue[searchTerms,
          Function[q, AnyTrue[pool,
            StringContainsQ[#, q] &]]];
        If[!matched, ok = False]]];
    
    (* Header Status *)
    statusQ = Lookup[query, "Status", Missing[]];
    If[ok && !MissingQ[statusQ] && StringQ[statusQ],
      hdrStatus = Lookup[header, "Status", ""];
      If[hdrStatus =!= statusQ, ok = False]];
    
    (* Scope: \:8907\:5408\:30d5\:30a3\:30eb\:30bf\:3002"Today" \:306f
       (NextReview \:304c\:4eca\:65e5) OR (Deadline \:304c\:4eca\:65e5) OR (Path \:306b YYYYMMDD \:3068\:3057\:3066\:4eca\:65e5\:3092\:542b\:3080)
       \:306e\:3044\:305a\:308c\:304b\:3092\:6e80\:305f\:3059\:3082\:306e\:306b\:7d5e\:308b\:3002NoReviewDate / NoDeadline \:306f
       \:300c\:30ec\:30d3\:30e5\:30fc\:4e0d\:8981\:300d\:3068\:307f\:306a\:3057\:542b\:3081\:306a\:3044 (\:30d5\:30a9\:30eb\:30c0\:540d/\:30d5\:30a1\:30a4\:30eb\:540d\:306b
       \:4eca\:65e5\:306e\:65e5\:4ed8\:3092\:542b\:3080\:3082\:306e\:306f\:5225\:9014\:6551\:3046)\:3002
       OpenTodos \:7b49\:306e\:4ed6\:30aa\:30d7\:30b7\:30e7\:30f3\:3068 AND \:3067\:7d44\:307f\:5408\:308f\:305b\:53ef\:80fd\:3002 *)
    scopeQ = Lookup[query, "Scope", Missing[]];
    If[ok && !MissingQ[scopeQ],
      Switch[scopeQ,
        "Today",
          If[!(reviewState === "DueToday" ||
               deadlineState === "DueToday" ||
               iSVPathHasTodayDate[Lookup[record, "Path", ""], today]),
            ok = False],
        _, Null]];
    
    ok
  ];

(* {y, m, d} \:3092\:7de8\:96c6\:53ef\:80fd\:306a DateObject \:5165\:529b\:5f0f\:6587\:5b57\:5217\:306b\:3059\:308b\:3002
   \:4f8b: {2026, 6, 1} -> "DateObject[{2026, 6, 1}]"
   InputForm \:81ea\:52d5\:5c55\:958b ("Gregorian" \:7b49\:306e\:4ed8\:4e0e) \:3092\:907f\:3051\:3001\:30e6\:30fc\:30b6\:304c\:305d\:306e\:307e\:307e
   \:66f8\:304d\:76f4\:305b\:308b\:7c21\:6f54\:306a\:5f62\:3068\:3059\:308b\:3002 *)
iSVDateInputString[dateList_List] :=
  "DateObject[{" <>
  StringRiffle[Map[ToString, dateList], ", "] <>
  "}]";

(* \:5165\:529b\:5f0f\:6587\:5b57\:5217\:3092 NotebookStatus \:30bb\:30eb\:7528\:306e box \:306b\:3059\:308b\:3002
   BoxData \:306b\:6587\:5b57\:5217\:3092\:5165\:308c\:308b\:3068\:30d5\:30ed\:30f3\:30c8\:30a8\:30f3\:30c9\:306f\:305d\:308c\:3092\:5165\:529b\:30c6\:30ad\:30b9\:30c8\:3068\:3057\:3066
   \:30d1\:30fc\:30b9\:30fb\:8868\:793a\:3057\:3001DateObject[{2026, 6, 1}] \:3082\:7de8\:96c6\:53ef\:80fd\:306a\:5165\:529b\:5f0f\:3068\:306a\:308b\:3002
   (FrontEnd \:30d1\:30fc\:30b5\:306e\:975e\:516c\:958b API \:306f\:74b0\:5883\:306b\:3088\:308a\:5931\:6557\:3057\:5f97\:308b\:305f\:3081\:4f7f\:308f\:305a\:3001
    \:6700\:3082\:5b89\:5b9a\:306a\:751f\:6587\:5b57\:5217\:3092 BoxData \:306b\:5165\:308c\:308b\:65b9\:5f0f\:3068\:3059\:308b) \:3002 *)
iSVStringToBoxes[inputStr_String] := inputStr;

(* === Public API === *)

(* ============================================================
   SourceVaultNewNotebook: \:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:304b\:3089\:65b0\:898f\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:751f\:6210
   - \:30c6\:30f3\:30d7\:30ec\:30fc\:30c8: $packageDirectory/Templates/SourceVault notebook template.nb
   - NotebookStatus \:30bb\:30eb\:306e Deadline / NextReview \:3092\:751f\:6210\:65e5 (\:4eca\:65e5) \:306b\:7f6e\:63db\:3057\:3066\:51fa\:529b
   - "\:65b0\:898f\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092" / "\:65b0\:3057\:3044\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092" \:7b49\:306e\:30d7\:30ed\:30f3\:30d7\:30c8\:304b\:3089\:8d77\:52d5
   \:526f\:4f5c\:7528: \:30d5\:30a1\:30a4\:30eb\:751f\:6210 (SideEffect)\:3002\:65e2\:5b58\:30d5\:30a1\:30a4\:30eb\:306f\:4e0a\:66f8\:304d\:3057\:306a\:3044\:3002
   ============================================================ *)
Options[SourceVaultNewNotebook] = {
  "TemplatePath" -> Automatic,
  "Title" -> Automatic,
  "Date" -> Automatic,
  "Keywords" -> Automatic,
  "SessionID" -> Automatic
};

SourceVaultNewNotebook[opts:OptionsPattern[]] :=
  Module[{tmplPath, title, theDate, dateList, keywords, sessionId,
          nbExpr, replaced, found = False, newNb, nbObj},
    iEnsureRoots[];
    (* \:751f\:6210\:65e5 (\:65e2\:5b9a: \:4eca\:65e5) *)
    theDate = OptionValue["Date"];
    If[theDate === Automatic, theDate = DateObject[Today, "Day"]];
    dateList = Quiet @ Check[
      DateValue[theDate, {"Year", "Month", "Day"}], $Failed];
    If[!MatchQ[dateList, {_Integer, _Integer, _Integer}],
      dateList = DateValue[DateObject[Today, "Day"],
        {"Year", "Month", "Day"}]];

    (* \:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:30d1\:30b9 *)
    tmplPath = OptionValue["TemplatePath"];
    If[tmplPath === Automatic,
      Module[{pkgDir = iPackageDir[]},
        If[!StringQ[pkgDir] || pkgDir === "",
          Return[<|"Status" -> "Failed",
            "Reason" -> "PackageDirectoryNotSet",
            "Hint" -> "$packageDirectory \:304c\:672a\:8a2d\:5b9a\:3067\:3059\:3002Global`$packageDirectory \:3092\:8a2d\:5b9a\:3059\:308b\:304b\:3001\"TemplatePath\" \:30aa\:30d7\:30b7\:30e7\:30f3\:3067\:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:3092\:660e\:793a\:3057\:3066\:304f\:3060\:3055\:3044\:3002"|>]];
        tmplPath = FileNameJoin[{pkgDir, "Templates",
          "SourceVault notebook template.nb"}]]];
    If[!StringQ[tmplPath] || !FileExistsQ[tmplPath],
      Return[<|"Status" -> "Failed", "Reason" -> "TemplateNotFound",
        "TemplatePath" -> tmplPath|>]];

    (* \:30bf\:30a4\:30c8\:30eb (WindowTitle \:7528\:3002\:65e2\:5b9a \"\:65b0\:898f\:30ce\:30fc\:30c8\")\:3002
       CreateNotebook \:3067\:672a\:4fdd\:5b58\:30a6\:30a3\:30f3\:30c9\:30a6\:3068\:3057\:3066\:958b\:304f\:305f\:3081\:3001\:30d5\:30a1\:30a4\:30eb\:540d\:30fb\:51fa\:529b\:5148\:306f\:4e0d\:8981\:3002 *)
    title = OptionValue["Title"];
    If[title === Automatic || !StringQ[title], title = "\:65b0\:898f\:30ce\:30fc\:30c8"];

    (* Keywords: a list of strings replaces the template's "Keywords" value.
       Automatic (default) keeps the template's value (e.g. {"template"}). *)
    keywords = OptionValue["Keywords"];
    If[StringQ[keywords], keywords = {keywords}];

    (* SessionID: a string stores a back-link to a capture session into the
       NotebookStatus association, so a found notebook can recover its session
       events. Automatic (default) adds nothing. *)
    sessionId = OptionValue["SessionID"];

    (* \:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:3092\:5f0f\:3068\:3057\:3066\:8aad\:307f\:8fbc\:3080 (\:526f\:4f5c\:7528\:306a\:3057) *)
    nbExpr = Quiet[Import[tmplPath, "Notebook"]];
    If[!MatchQ[nbExpr, Notebook[_List, ___]],
      Return[<|"Status" -> "Failed", "Reason" -> "TemplateNotANotebook",
        "TemplatePath" -> tmplPath|>]];

    (* NotebookStatus \:30b9\:30bf\:30a4\:30eb\:306e\:30bb\:30eb\:3092\:898b\:3064\:3051\:3001Deadline/NextReview \:3092\:4eca\:65e5\:306b\:7f6e\:63db\:3002
       \:30bb\:30eb\:306e BoxData \:3092 MakeExpression \:3067 Association \:5316\:3057\:3001\:5024\:3092\:5dee\:3057\:66ff\:3048\:308b\:3002
       \:91cd\:8981: ToBoxes[DateObject[...]] \:306f\:7de8\:96c6\:4e0d\:53ef\:306a TemplateBox (\"Mon 1 Jun 2026\" \:30a6\:30a3\:30b8\:30a7\:30c3\:30c8) \:306b
       \:306a\:308b\:305f\:3081\:4f7f\:308f\:306a\:3044\:3002\:4ee3\:308f\:308a\:306b Association \:5168\:4f53\:3092 InputForm \:6587\:5b57\:5217\:5316\:3057 box \:5316\:3059\:308b\:3053\:3068\:3067\:3001
       DateObject[{2026, 6, 1}] \:306e\:3088\:3046\:306a\:7de8\:96c6\:53ef\:80fd\:306a\:5165\:529b\:5f0f\:30c6\:30ad\:30b9\:30c8\:3068\:3057\:3066\:633f\:5165\:3059\:308b\:3002 *)
    replaced = Replace[nbExpr,
      Cell[content_, "NotebookStatus", cellOpts___] :> (
        Module[{held, assoc, newAssoc, newBoxes, inputStr},
          held = Quiet[MakeExpression[content, StandardForm]];
          If[MatchQ[held, HoldComplete[_Association]],
            assoc = ReleaseHold[held];
            newAssoc = assoc;
            (* DateObject \:3092\:7de8\:96c6\:53ef\:80fd\:306a\:5165\:529b\:5f0f\:3067\:51fa\:3059\:305f\:3081\:3001\:4e00\:65e6\:30e6\:30cb\:30fc\:30af\:306a
               \:30d7\:30ec\:30fc\:30b9\:30db\:30eb\:30c0\:6587\:5b57\:5217\:3092\:5165\:308c\:3066 InputForm \:5316\:5f8c\:306b\:5b9f\:30c7\:30fc\:30bf\:5165\:529b\:5f0f\:306b\:7f6e\:63db\:3059\:308b\:3002
               \:30d7\:30ec\:30fc\:30b9\:30db\:30eb\:30c0\:306f\:885d\:7a81\:3057\:306a\:3044 ASCII \:30c8\:30fc\:30af\:30f3\:3002 *)
            newAssoc["Deadline"]   = "@@SV_DEADLINE_DATE@@";
            newAssoc["NextReview"] = "@@SV_NEXTREVIEW_DATE@@";
            If[MatchQ[keywords, {___String}], newAssoc["Keywords"] = keywords];
            If[StringQ[sessionId], newAssoc["SessionID"] = sessionId];
            inputStr = ToString[newAssoc, InputForm];
            (* \:30d7\:30ec\:30fc\:30b9\:30db\:30eb\:30c0 (\:30af\:30a9\:30fc\:30c8\:4ed8\:304d\:6587\:5b57\:5217\:3068\:3057\:3066\:51fa\:529b\:3055\:308c\:308b) \:3092\:5b9f DateObject \:5165\:529b\:5f0f\:306b *)
            inputStr = StringReplace[inputStr, {
              "\"@@SV_DEADLINE_DATE@@\""   -> iSVDateInputString[dateList],
              "\"@@SV_NEXTREVIEW_DATE@@\"" -> iSVDateInputString[dateList]}];
            found = True;
            (* \:5165\:529b\:5f0f\:6587\:5b57\:5217\:3092 box \:5316 (\:8a55\:4fa1\:305b\:305a)\:3002\:5931\:6557\:6642\:306f\:5143\:306e content \:3092\:6b8b\:3059 *)
            newBoxes = Quiet @ Check[
              iSVStringToBoxes[inputStr], $Failed];
            If[newBoxes === $Failed,
              Cell[content, "NotebookStatus", cellOpts],
              Cell[BoxData[newBoxes], "NotebookStatus", cellOpts]],
            (* MakeExpression \:5931\:6557\:6642\:306f\:30bb\:30eb\:3092\:305d\:306e\:307e\:307e\:6b8b\:3059 *)
            Cell[content, "NotebookStatus", cellOpts]]]),
      Infinity];

    newNb = replaced;

    (* WindowTitle \:30aa\:30d7\:30b7\:30e7\:30f3\:3092\:9664\:53bb\:3059\:308b\:3002
       WindowTitle \:3092\:660e\:793a\:8a2d\:5b9a\:3059\:308b\:3068\:30bf\:30a4\:30c8\:30eb\:30d0\:30fc\:304c\:305d\:308c\:306b\:56fa\:5b9a\:3055\:308c\:3001
       \:30d5\:30a1\:30a4\:30eb\:4fdd\:5b58\:3057\:3066\:3082\:30d5\:30a1\:30a4\:30eb\:540d\:304c\:30bf\:30a4\:30c8\:30eb\:306b\:53cd\:6620\:3055\:308c\:306a\:3044\:3002
       \:672a\:8a2d\:5b9a\:306b\:3057\:3066\:304a\:3051\:3070\:3001\:30d5\:30ed\:30f3\:30c8\:30a8\:30f3\:30c9\:304c\:4fdd\:5b58\:6642\:306b\:81ea\:52d5\:3067\:30d5\:30a1\:30a4\:30eb\:540d\:3092\:8868\:793a\:3059\:308b\:3002
       \:30c6\:30f3\:30d7\:30ec\:30fc\:30c8\:7531\:6765\:306e WindowTitle \:3082\:9664\:53bb\:3057\:3066\:304a\:304f\:3002 *)
    newNb = Replace[newNb,
      Notebook[cells_, before___, (Rule | RuleDelayed)[WindowTitle, _], after___] :>
        Notebook[cells, before, after],
      {0}];
    (* \:8907\:6570\:6b8b\:308b\:53ef\:80fd\:6027\:306b\:5099\:3048 FixedPoint \:3067\:7e70\:308a\:8fd4\:3057\:9664\:53bb *)
    newNb = FixedPoint[
      Replace[#,
        Notebook[cells_, before___, (Rule | RuleDelayed)[WindowTitle, _], after___] :>
          Notebook[cells, before, after],
        {0}] &,
      newNb];

    (* \:672a\:4fdd\:5b58\:306e\:65b0\:898f\:30a6\:30a3\:30f3\:30c9\:30a6\:3068\:3057\:3066\:958b\:304f (\:30d5\:30a1\:30a4\:30eb\:4fdd\:5b58\:3057\:306a\:3044)\:3002
       newNb \:306f Notebook[{Cell[...], ...}, opts...] \:5f0f\:3002NotebookPut \:306f\:5b8c\:5168\:306a
       Notebook \:5f0f (\:30bb\:30eb\:30ea\:30b9\:30c8 + \:30aa\:30d7\:30b7\:30e7\:30f3) \:3092\:305d\:306e\:307e\:307e\:53d7\:3051\:53d6\:308a\:3001
       \:65b0\:898f\:30a6\:30a3\:30f3\:30c9\:30a6\:3068\:3057\:3066\:8868\:793a\:3057\:3066 NotebookObject \:3092\:8fd4\:3059\:3002
       WindowTitle \:3092\:8a2d\:5b9a\:3057\:306a\:3044\:306e\:3067\:3001\:4fdd\:5b58\:6642\:306b\:30d5\:30a1\:30a4\:30eb\:540d\:304c\:30bf\:30a4\:30c8\:30eb\:306b\:8868\:793a\:3055\:308c\:308b\:3002 *)
    nbObj = Quiet @ Check[NotebookPut[newNb], $Failed];
    If[Head[nbObj] =!= NotebookObject,
      Return[<|"Status" -> "Failed", "Reason" -> "CreateNotebookFailed",
        "TemplatePath" -> tmplPath,
        "NewNotebookHead" -> ToString[Head[newNb]]|>]];
    (* WindowTitle \:3092\:30d5\:30ed\:30f3\:30c8\:30a8\:30f3\:30c9\:65e2\:5b9a\:306b\:623b\:3059\:3002
       \:30b9\:30bf\:30a4\:30eb\:30b7\:30fc\:30c8 (SourceVault default.nb) \:5074\:306b WindowTitle \:304c\:5b9a\:7fa9\:3055\:308c\:3066\:3044\:308b\:3068\:3001
       Notebook \:5f0f\:304b\:3089 WindowTitle \:3092\:9664\:53bb\:3057\:3066\:3082\:30b9\:30bf\:30a4\:30eb\:7531\:6765\:306e\:30bf\:30a4\:30c8\:30eb\:304c\:6b8b\:308b\:3002
       Inherited / Automatic \:3092\:9806\:306b\:8a66\:3057\:3001\:30d5\:30a1\:30a4\:30eb\:540d\:30d9\:30fc\:30b9\:306e\:81ea\:52d5\:30bf\:30a4\:30c8\:30eb\:306b\:623b\:3059\:3002 *)
    Quiet @ Check[SetOptions[nbObj, WindowTitle -> Inherited], Null];
    Quiet @ Check[CurrentValue[nbObj, WindowTitle] = Inherited, Null];

    <|"Status" -> "OK",
      "Notebook" -> nbObj,
      "Title" -> title,
      "Date" -> DateObject[dateList, "Day"],
      "Deadline" -> DateObject[dateList, "Day"],
      "NextReview" -> DateObject[dateList, "Day"],
      "StatusCellReplaced" -> found,
      "Saved" -> False,
      "TemplatePath" -> tmplPath|>
  ];

SourceVaultNewNotebook[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments",
    "Hint" -> "Expected SourceVaultNewNotebook[opts]."|>;

SourceVaultRegisterNotebook[path_String] :=
  Module[{abs, nbRef, fileMTime, ts, record, sourcePath, saveResult},
    iEnsureRoots[];
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[<|"Status" -> "Failed", "Reason" -> "FileNotFound",
        "Path" -> abs|>]];
    nbRef = iNotebookRefFromPath[abs];
    fileMTime = Quiet[DateString[FileDate[abs]]];
    ts = DateString[DateObject[]];
    record = <|
      "Type" -> "NotebookSource",
      "NotebookRef" -> nbRef,
      "OriginalPath" -> abs,
      "Title" -> FileBaseName[abs],
      "FileMTime" -> fileMTime,
      "CurrentSnapshotId" -> Missing["NotIndexed"],
      "RegisteredAt" -> ts,
      "LastIndexedAt" -> Missing["NotIndexed"]
    |>;
    sourcePath = iNotebookSourcePath[nbRef];
    saveResult = Module[{sanitized, json, strm},
      sanitized = iSanitizeForJSON[record];
      json = Quiet @ ExportString[sanitized, "RawJSON", "Compact" -> False];
      strm = Quiet[OpenWrite[sourcePath, BinaryFormat -> True]];
      If[Head[strm] === OutputStream,
        BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
        Close[strm];
        "OK",
        "Failed"]];
    <|"Status" -> saveResult,
      "NotebookRef" -> nbRef,
      "Path" -> abs,
      "RegisteredAt" -> ts|>
  ];

Options[SourceVaultExtractNotebookHeader] = {};

SourceVaultExtractNotebookHeader[path_String, opts:OptionsPattern[]] :=
  Module[{abs},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[<|"ParseStatus" -> "MissingHeader", "Reason" -> "FileNotFound"|>]];
    iNotebookHeaderParse[abs]
  ];

Options[SourceVaultExtractNotebookTodos] = {};

SourceVaultExtractNotebookTodos[path_String, opts:OptionsPattern[]] :=
  Module[{abs},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs], Return[{}]];
    iExtractTodoCellsFromPath[abs]
  ];

(* Stage 9 P1 Step 7: mtime \:30d9\:30fc\:30b9 skip \:30d8\:30eb\:30d1\:30fc
   \:65e2\:5b58 snapshot \:306e SourceMTime \:3068\:73fe\:5728\:306e mtime \:3092\:6bd4\:8f03\:3057\:3001
   \:4e00\:81f4\:3057\:305f\:3089\:5b8c\:5168\:306a Index \:7d50\:679c\:3092\:8fd4\:3059 (\:6700\:5c0f\:9650\:306e\:30c7\:30a3\:30b9\:30af\:30a2\:30af\:30bb\:30b9)\:3002
   \:4e0d\:4e00\:81f4 / \:65e2\:5b58 snapshot \:7121\:3057 / \:30d5\:30a3\:30fc\:30eb\:30c9\:6b20\:5982 \:306a\:3089 None \:3092\:8fd4\:3059\:3002 *)
iSVCheckMTimeCache[abs_String, nbRef_String, currentMTime_Integer] :=
  Module[{sourcePath, sourceRec, sourceRawBytes, sourceRawString,
          sourceImportTry, snapshotId, snapshotPath, snapshotRec,
          cachedMTime, header, todos, openCount, doneCount, passCount,
          today, deadlineVal, nextReviewVal, reviewState, deadlineState,
          lint, ts, cachedHash, curHash, cachedSize, curSize,
          hdrC, todoC, hdrRestored, todoRestored, reindexed},
    sourcePath = iNotebookSourcePath[nbRef];
    If[!FileExistsQ[sourcePath],
      Return[<|"Cached" -> False,
        "CacheMissReason" -> "SourcePathNotFound",
        "SourcePath" -> sourcePath|>]];
    sourceRec = iLoadJSONFromFile[sourcePath];
    If[!AssociationQ[sourceRec],
      (* \:8a73\:7d30\:8a3a\:65ad: \:5404\:6bb5\:968e\:3092\:9806\:306b\:518d\:73fe *)
      sourceRawBytes = Quiet @ ReadByteArray[sourcePath];
      sourceRawString = Which[
        Head[sourceRawBytes] === ByteArray,
          Quiet @ ByteArrayToString[sourceRawBytes, "UTF-8"],
        True, "ReadByteArrayFailed_" <> SymbolName[Head[sourceRawBytes]]];
      sourceImportTry = If[StringQ[sourceRawString],
        Quiet @ ImportString[sourceRawString, "RawJSON"],
        "PreviousStepFailed"];
      Return[<|"Cached" -> False,
        "CacheMissReason" -> "SourceRecordNotAssociation",
        "SourceRecordHead" -> SymbolName[Head[sourceRec]],
        "SourceRecordValue" -> ToString[sourceRec, InputForm],
        "SourcePath" -> sourcePath,
        "RawBytesHead" -> SymbolName[Head[sourceRawBytes]],
        "RawStringHead" -> SymbolName[Head[sourceRawString]],
        "RawStringLength" -> If[StringQ[sourceRawString],
          StringLength[sourceRawString], -1],
        "ImportTryHead" -> SymbolName[Head[sourceImportTry]],
        "ImportTryValue" -> ToString[sourceImportTry, InputForm],
        "SourceRawJSON" -> If[StringQ[sourceRawString],
          StringTake[sourceRawString, UpTo[500]],
          ToString[sourceRawString, InputForm]]|>]];
    snapshotId = Lookup[sourceRec, "CurrentSnapshotId", Missing["NotPresent"]];
    If[!StringQ[snapshotId],
      Return[<|"Cached" -> False,
        "CacheMissReason" -> "SnapshotIdNotString",
        "SnapshotIdValue" -> snapshotId|>]];

    snapshotPath = iNotebookSnapshotPath[snapshotId];
    If[!FileExistsQ[snapshotPath],
      Return[<|"Cached" -> False,
        "CacheMissReason" -> "SnapshotPathNotFound",
        "SnapshotPath" -> snapshotPath|>]];
    snapshotRec = iLoadJSONFromFile[snapshotPath];
    If[!AssociationQ[snapshotRec],
      Return[<|"Cached" -> False,
        "CacheMissReason" -> "SnapshotRecordNotAssociation",
        "SnapshotRecordHead" -> SymbolName[Head[snapshotRec]]|>]];

    cachedMTime = Lookup[snapshotRec, "SourceMTime", Missing["NotPresent"]];
    (* JSON \:8aad\:307f\:8fbc\:307f\:3067 Integer \:304c Real \:306b\:306a\:308b\:53ef\:80fd\:6027\:3092\:8003\:616e\:3057 NumericQ + \:6570\:5024\:6bd4\:8f03 *)
    If[!NumericQ[cachedMTime],
      Return[<|"Cached" -> False,
        "CacheMissReason" -> "CachedMTimeNotNumeric",
        "CachedMTime" -> cachedMTime,
        "CachedMTimeHead" -> SymbolName[Head[cachedMTime]],
        "CurrentMTime" -> currentMTime|>]];
    If[N[cachedMTime] =!= N[currentMTime],
      Return[<|"Cached" -> False,
        "CacheMissReason" -> "MTimeMismatch",
        "CachedMTime" -> cachedMTime,
        "CurrentMTime" -> currentMTime|>]];

    (* mtime \:304c\:5076\:7136\:4e00\:81f4\:3057\:3066\:3082\:5185\:5bb9\:304c\:5909\:308f\:3063\:3066\:3044\:308c\:3070 cache miss \:3068\:3059\:308b\:3002
       \:7de8\:96c6\:5f8c\:3082 mtime \:304c\:79d2\:7c92\:5ea6\:3067\:540c\:3058\:307e\:307e\:30fb\:30af\:30e9\:30a6\:30c9\:540c\:671f\:3067 mtime \:304c\:5fa9\:5143\:3055\:308c\:308b\:7b49\:306e
       \:30b1\:30fc\:30b9\:3067\:65e7\:30ad\:30e3\:30c3\:30b7\:30e5\:304c\:8fd4\:308a\:7d9a\:3051\:308b\:554f\:984c (NextReview \:7de8\:96c6\:304c\:53cd\:6620\:3055\:308c\:306a\:3044) \:3092\:9632\:3050\:3002

       \:9ad8\:901f\:5316: \:6b63\:5e38\:6642 (mtime \:4e00\:81f4) \:306b\:6bce\:56de Hash[Import[abs,"Text"]] \:3092\:8a08\:7b97\:3059\:308b\:3068
       \:30d5\:30a1\:30a4\:30eb\:5168\:8aad\:307f\:8fbc\:307f\:306e\:30b3\:30b9\:30c8\:304c\:304b\:304b\:308b\:3002\:305d\:3053\:3067 mtime \:306b\:52a0\:3048\:3066
       \:8efd\:91cf\:306a FileByteCount (\:5168\:8aad\:307f\:8fbc\:307f\:4e0d\:8981) \:3092\:4f75\:7528\:3057\:3001
       mtime + \:30b5\:30a4\:30ba\:304c\:5171\:306b\:4e00\:81f4\:3059\:308c\:3070\:30cf\:30c3\:30b7\:30e5\:8a08\:7b97\:3092\:30b9\:30ad\:30c3\:30d7\:3057\:3066 cache hit \:3068\:3059\:308b\:3002
       mtime \:3082\:30b5\:30a4\:30ba\:3082\:5909\:308f\:3089\:305a\:5185\:5bb9\:3060\:3051\:5909\:308f\:308b\:30b1\:30fc\:30b9 (\:540c\:30d0\:30a4\:30c8\:6570\:306e\:7de8\:96c6) \:306f
       \:4e8b\:5b9f\:4e0a\:3042\:308a\:5f97\:306a\:3044\:305f\:3081\:5b89\:5168\:3002\:30b5\:30a4\:30ba\:304c snapshot \:306b\:7121\:3044\:65e7\:7248 / \:53d6\:5f97\:4e0d\:53ef\:306e\:5834\:5408\:306e\:307f
       \:5f93\:6765\:306e\:30cf\:30c3\:30b7\:30e5\:5224\:5b9a\:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3059\:308b (\:5f8c\:65b9\:4e92\:63db)\:3002 *)
    cachedSize = Lookup[snapshotRec, "SourceSize", Missing["NotPresent"]];
    cachedHash = Lookup[snapshotRec, "RawContentHash", Missing["NotPresent"]];
    If[IntegerQ[cachedSize],
      (* \:30b5\:30a4\:30ba\:5224\:5b9a\:7d4c\:8def (\:9ad8\:901f): FileByteCount \:306e\:307f\:3067\:5224\:5b9a\:3057\:30cf\:30c3\:30b7\:30e5\:306f\:8a08\:7b97\:3057\:306a\:3044 *)
      curSize = Quiet @ Check[FileByteCount[abs], Missing["SizeFailed"]];
      If[IntegerQ[curSize] && curSize =!= cachedSize,
        Return[<|"Cached" -> False,
          "CacheMissReason" -> "ContentSizeMismatch",
          "CachedSize" -> cachedSize,
          "CurrentSize" -> curSize|>]],
      (* \:30b5\:30a4\:30ba\:672a\:4fdd\:5b58\:306e\:65e7 snapshot: \:5f93\:6765\:306e\:30cf\:30c3\:30b7\:30e5\:5224\:5b9a\:3067\:5f8c\:65b9\:4e92\:63db *)
      If[StringQ[cachedHash],
        curHash = Quiet @ Check[
          "sha256-" <> Hash[Import[abs, "Text"], "SHA256", "HexString"],
          Missing["HashFailed"]];
        If[StringQ[curHash] && curHash =!= cachedHash,
          Return[<|"Cached" -> False,
            "CacheMissReason" -> "ContentHashMismatch",
            "CachedHash" -> cachedHash,
            "CurrentHash" -> curHash|>]]]];

    (* \:4e00\:81f4: \:5b8c\:5168\:306a Index \:7d50\:679c\:3092\:518d\:69cb\:7bc9\:3002
       Stage 9 P1 Step 8: snapshot \:306b HeaderCompressed/TodosCompressed \:304c\:3042\:308c\:3070
       \:305d\:308c\:3092 Uncompress \:3057\:3066\:4f7f\:3046 (.nb \:3092 Import \:3057\:306a\:3044 \[Rule] \:518d\:8d77\:52d5\:5f8c\:3082\:9ad8\:901f)\:3002

       Stage 9 P1 Step 8 \:6052\:4e45\:5bfe\:7b56 (\:6848 B):
       \:5727\:7e2e\:30d5\:30a3\:30fc\:30eb\:30c9\:304c\:7121\:3044 / Uncompress \:5931\:6557\:306e\:5834\:5408\:3001
       \:4ee5\:524d\:306f\:3053\:306e\:5834\:3067 iNotebookHeaderParse + iExtractTodoCellsFromPath
       \:3092\:7121\:6761\:4ef6\:306b\:547c\:3093\:3067 .nb \:3092\:30d5\:30eb\:30d1\:30fc\:30b9\:3057\:3066\:3044\:305f\:3002\:3053\:308c\:306f
       (a) \:5de8\:5927 .nb (\:51fa\:529b\:30bb\:30eb\:591a\:6570\:306e\:7d50\:679c\:30ce\:30fc\:30c8) \:306b\:5bfe\:3057\:3066
       \:30b5\:30a4\:30ba\:95be\:5024\:30ac\:30fc\:30c9\:3092\:901a\:3089\:305a\:6570\:767e\:79d2\:304b\:304b\:308b\:3001
       (b) \:65e7 snapshot \:304c\:3044\:3064\:307e\:3067\:3082\:65e7\:7248\:306e\:307e\:307e\:3067\:518d\:8d77\:52d5\:6bce\:306b\:540c\:3058
       \:30b3\:30b9\:30c8\:3092\:6255\:3046\:3001\:3068\:3044\:3046\:4e8c\:91cd\:306e\:554f\:984c\:304c\:3042\:3063\:305f\:3002
       \:65b0\:65b9\:5f0f: \:5fa9\:5143\:3067\:304d\:306a\:3044\:5834\:5408\:306f SourceVaultIndexNotebook \:3092
       ForceReindex -> True \:3067 1 \:56de\:547c\:3073\:3001snapshot \:3092 Step 8 \:5f62\:5f0f
       (\:5727\:7e2e\:30d5\:30a3\:30fc\:30eb\:30c9\:4ed8\:304d) \:306b\:66f4\:65b0\:3057\:3066\:304b\:3089\:305d\:306e\:7d50\:679c\:3092\:8fd4\:3059\:3002\:3053\:308c\:306b\:3088\:308a
       - SourceVaultIndexNotebook \:672c\:4f53\:306e\:30b5\:30a4\:30ba\:95be\:5024\:30ac\:30fc\:30c9\:304c\:52b9\:304f
       - \:65e7 snapshot \:304c\:6f38\:9032\:7684\:306b\:81ea\:52d5\:30a2\:30c3\:30d7\:30b0\:30ec\:30fc\:30c9\:3055\:308c\:3001\:6b21\:56de\:304b\:3089\:306f
         \:3053\:306e\:95a2\:6570\:306e fast path \:306b\:4e57\:308b
       \:518d\:5e30\:306e\:5fc3\:914d\:306f\:7121\:3044: SourceVaultIndexNotebook \:306f forceReindex=True
       \:306e\:3068\:304d iSVCheckMTimeCache \:3092\:547c\:3070\:306a\:3044\:3002 *)
      hdrC = Lookup[snapshotRec, "HeaderCompressed", Missing[]];
      todoC = Lookup[snapshotRec, "TodosCompressed", Missing[]];
      hdrRestored = If[StringQ[hdrC],
        Quiet @ Check[Uncompress[hdrC], $Failed], $Failed];
      todoRestored = If[StringQ[todoC],
        Quiet @ Check[Uncompress[todoC], $Failed], $Failed];
      If[AssociationQ[hdrRestored] && ListQ[todoRestored],
        (* snapshot \:304b\:3089\:5fa9\:5143\:6210\:529f: .nb Import \:4e0d\:8981 *)
        header = hdrRestored;
        todos = todoRestored,
        (* \:5fa9\:5143\:5931\:6557 (\:65e7\:7248 snapshot \:7b49):
           \:305d\:306e\:5834\:3067 .nb \:3092\:30d1\:30fc\:30b9\:305b\:305a\:3001ForceReindex \:3067 snapshot \:3092
           \:6700\:65b0\:5f62\:5f0f\:3078\:66f4\:65b0\:3057\:3001\:305d\:306e\:7d50\:679c\:3092\:305d\:306e\:307e\:307e\:8fd4\:3059\:3002 *)
        reindexed = Quiet @ Check[
          SourceVaultIndexNotebook[abs, "ForceReindex" -> True],
          $Failed];
        If[AssociationQ[reindexed] &&
            Lookup[reindexed, "Status", ""] === "OK",
          Return[reindexed]];
        (* ForceReindex \:3082\:5931\:6557\:3057\:305f\:5834\:5408\:306e\:307f\:6700\:5f8c\:306e\:624b\:6bb5\:3068\:3057\:3066\:65e7\:7d4c\:8def *)
        header = iNotebookHeaderParse[abs];
        todos = iExtractTodoCellsFromPath[abs]
      ];
    openCount = Count[todos, t_Association /; Lookup[t, "Status", ""] === "Open"];
    doneCount = Count[todos, t_Association /; Lookup[t, "Status", ""] === "Done"];
    passCount = Count[todos, t_Association /; Lookup[t, "Status", ""] === "Pass"];
    today = DateObject[Now, "Day"];
    deadlineVal = Lookup[header, "Deadline", Missing[]];
    nextReviewVal = Lookup[header, "NextReview", Missing[]];
    reviewState = iComputeReviewState[nextReviewVal, today];
    deadlineState = iComputeDeadlineState[deadlineVal, today];
    lint = iComputeNotebookLint[<|"Header" -> header, "Todos" -> todos|>];
    ts = Lookup[sourceRec, "LastIndexedAt", DateString[DateObject[]]];

    <|"Status" -> "OK",
      "Cached" -> True,
      "NotebookRef" -> nbRef,
      "SnapshotId" -> snapshotId,
      "Path" -> abs,
      (* \:5f8c\:65b9\:4e92\:63db: usage \:8a18\:8f09\:30fb\:65e7\:5229\:7528\:30b3\:30fc\:30c9\:304c\:671f\:5f85\:3059\:308b\:30ad\:30fc\:3002
         OriginalPath \:306f Path \:306e\:30a8\:30a4\:30ea\:30a2\:30b9\:3001Title \:306f Header.Title \:307e\:305f\:306f
         \:30d5\:30a1\:30a4\:30eb\:540d\:3002Todos \:306f\:62bd\:51fa\:6e08\:307f todo \:672c\:4f53 (\:5b9f\:5728\:3057\:306a\:3044 OriginalPath \:3078\:306e
         \:518d\:62bd\:51fa\:3092\:4e0d\:8981\:306b\:3059\:308b)\:3002 *)
      "OriginalPath" -> abs,
      "Title" -> Lookup[header, "Title", FileBaseName[abs]],
      "Todos" -> todos,
      "Header" -> header,
      "TodoCount" -> Length[todos],
      "OpenTodoCount" -> openCount,
      "DoneTodoCount" -> doneCount,
      "PassTodoCount" -> passCount,
      "ReviewState" -> reviewState,
      "DeadlineState" -> deadlineState,
      "Lint" -> lint,
      "IndexedAt" -> ts,
      "SourceMTime" -> currentMTime|>
  ];

Options[SourceVaultIndexNotebook] = {
  "ExtractHeader" -> True,
  "ExtractTodos" -> True,
  "ForceReindex" -> False
};

SourceVaultIndexNotebook[path_String, opts:OptionsPattern[]] :=
  Module[{abs, nbRef, readResult, nbExpr, snapshotId, rawHash, content,
          header, todos, openCount, doneCount, passCount, reviewState, deadlineState,
          today, lint, ts, sourcePath, sourceRecord, snapshotPath,
          snapshotRecord, todoRecords, byNotebookPath, todoLines,
          openTodoLines, doneTodoLines, lintLines,
          extractHeader, extractTodos, forceReindex,
          headerVal, deadlineVal, nextReviewVal, todoCount,
          currentMTime, cachedResult, cacheCheckDebug},
    iEnsureRoots[];
    extractHeader = TrueQ[OptionValue["ExtractHeader"]];
    extractTodos = TrueQ[OptionValue["ExtractTodos"]];
    forceReindex = TrueQ[OptionValue["ForceReindex"]];
    
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[<|"Status" -> "Failed", "Reason" -> "FileNotFound",
        "Path" -> abs|>]];
    nbRef = iNotebookRefFromPath[abs];

    (* Stage 9 P1 Step 7: mtime \:30d9\:30fc\:30b9 skip *)
    currentMTime = Quiet @ UnixTime[FileDate[abs, "Modification"]];
    cacheCheckDebug = <||>;
    If[!forceReindex && IntegerQ[currentMTime],
      cachedResult = iSVCheckMTimeCache[abs, nbRef, currentMTime];
      If[AssociationQ[cachedResult] && cachedResult["Cached"] === True,
        Return[cachedResult]];
      (* cache miss \:306e\:8a3a\:65ad\:60c5\:5831\:3092\:30ed\:30b0\:7528\:306b\:6e21\:3059 *)
      If[AssociationQ[cachedResult],
        cacheCheckDebug = cachedResult,
        cacheCheckDebug = <|"CacheMissReason" -> "ReturnedNone"|>]];
    
    (* Stage 9 P1 Step 8 Hotfix 2: \:30d5\:30a1\:30a4\:30eb\:30b5\:30a4\:30ba\:95be\:5024\:3002
       \:30b7\:30df\:30e5\:30ec\:30fc\:30b7\:30e7\:30f3\:7d50\:679c\:3092\:53ce\:3081\:305f .nb \:306f\:6570\:767e MB\:ff5eGB \:306b\:306a\:308a\:5f97\:3001
       Import \:3059\:308b\:3068\:30e1\:30e2\:30ea\:67af\:6e07\:30fb\:51e6\:7406\:30cf\:30f3\:30b0\:306e\:539f\:56e0\:306b\:306a\:308b\:3002
       \:95be\:5024\:8d85\:3048\:306e\:30d5\:30a1\:30a4\:30eb\:306f .nb \:3092 Import \:305b\:305a\:3001
       \:30d5\:30a1\:30a4\:30eb\:60c5\:5831\:3060\:3051\:306e\:8efd\:91cf snapshot \:3092\:4f5c\:3063\:3066\:8fd4\:3059\:3002 *)
    Module[{sizeBytes, maxBytes, sizeMB},
      sizeBytes = Quiet @ Check[FileByteCount[abs], 0];
      maxBytes = iSVMaxFileSizeMB[] * 1024.^2;
      If[NumericQ[sizeBytes] && sizeBytes > maxBytes,
        sizeMB = Round[sizeBytes / 1024.^2, 0.1];
        ts = DateString[DateObject[]];
        snapshotId = "snap-toolarge-" <>
          IntegerString[Hash[abs, "SHA256"], 16, 16];
        Module[{srcRec, srcPath, snapRec, snapPath, json, strm},
          (* too-large \:7d4c\:8def\:3067\:3082 SymbolicPath \:306f\:5fc5\:9808: cross-PC \:691c\:7d22
             (SourceVaultFindNotebooks \:306e iSVResolvePath \:89e3\:6c7a) \:3067\:4f7f\:3046\:3002
             iSVSymbolicPath \:306f\:30d1\:30b9\:6587\:5b57\:5217\:3060\:3051\:3067\:8a08\:7b97\:3057\:30d5\:30a1\:30a4\:30eb\:3092\:958b\:304b\:306a\:3044\:306e\:3067
             \:5de8\:5927\:30ce\:30fc\:30c8\:3067\:3082\:5b89\:5168\:3002\:4e00\:65b9 SourceUUID \:306f\:30ce\:30fc\:30c8\:3092\:958b\:304f\:5fc5\:8981\:304c\:3042\:308a
             too-large \:7d4c\:8def\:306e\:8da3\:65e8 (\:5de8\:5927 .nb \:3092 Import \:3057\:306a\:3044) \:306b\:53cd\:3059\:308b\:305f\:3081\:3001
             \:3053\:3053\:3067\:306f\:53d6\:5f97\:305b\:305a Missing["SkippedTooLarge"] \:3068\:3059\:308b\:3002
             \:901a\:5e38\:7d4c\:8def\:306e sourceRecord \:3068\:30d5\:30a3\:30fc\:30eb\:30c9\:69cb\:9020\:3092\:63c3\:3048\:308b\:3002 *)
          srcRec = <|
            "Type" -> "NotebookSource",
            "NotebookRef" -> nbRef,
            "OriginalPath" -> abs,
            "SymbolicPath" -> iSVSymbolicPath[abs],
            "Title" -> FileBaseName[abs],
            "FileMTime" -> Quiet[DateString[FileDate[abs]]],
            "CurrentSnapshotId" -> snapshotId,
            "SourceUUID" -> Missing["SkippedTooLarge"],
            "RegisteredAt" -> ts,
            "LastIndexedAt" -> ts|>;
          srcPath = iNotebookSourcePath[nbRef];
          json = Quiet @ ExportString[iSanitizeForJSON[srcRec],
            "RawJSON", "Compact" -> False];
          strm = Quiet[OpenWrite[srcPath, BinaryFormat -> True]];
          If[Head[strm] === OutputStream,
            BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
            Close[strm]];
          snapRec = <|
            "Type" -> "NotebookSnapshot",
            "SnapshotId" -> snapshotId,
            "NotebookRef" -> nbRef,
            "LifecycleStatus" -> "Current",
            "SourceMTime" -> If[IntegerQ[currentMTime], currentMTime,
              Missing["NotPresent"]],
            "SourceSize" -> Quiet @ Check[FileByteCount[abs],
              Missing["NotPresent"]],
            "Skipped" -> True,
            "SkipReason" -> "FileTooLarge",
            "FileSizeMB" -> sizeMB,
            "PrivacyLevel" -> 1.0,
            "PrivacyLevelSource" -> "Default",
            "AcquisitionContext" -> "LocalFile",
            "CreatedAt" -> ts|>;
          snapPath = iNotebookSnapshotPath[snapshotId];
          json = Quiet @ ExportString[iSanitizeForJSON[snapRec],
            "RawJSON", "Compact" -> False];
          strm = Quiet[OpenWrite[snapPath, BinaryFormat -> True]];
          If[Head[strm] === OutputStream,
            BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
            Close[strm]]];
        Return[<|"Status" -> "OK",
          "Skipped" -> True,
          "SkipReason" -> "FileTooLarge",
          "FileSizeMB" -> sizeMB,
          "NotebookRef" -> nbRef,
          "SnapshotId" -> snapshotId,
          "Path" -> abs,
          "Header" -> <|"ParseStatus" -> "SkippedTooLarge"|>,
          "TodoCount" -> 0,
          "OpenTodoCount" -> 0,
          "DoneTodoCount" -> 0,
          "PassTodoCount" -> 0,
          "SourceMTime" -> currentMTime|>]]
    ];

    (* notebook \:3092\:8aad\:3080 *)
    readResult = iReadNotebookExpr[abs];
    If[Lookup[readResult, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[readResult, "Reason", "ReadFailed"],
        "Path" -> abs|>]];
    nbExpr = Lookup[readResult, "Expr"];
    
    (* SnapshotId: content hash *)
    content = Quiet[Import[abs, "Text"]];
    rawHash = Hash[content, "SHA256", "HexString"];
    snapshotId = "snap-sha256-" <> rawHash;
    
    ts = DateString[DateObject[]];
    today = DateObject[Now, "Day"];
    
    (* Header / Todo \:62bd\:51fa\:3002Header \:306f path \:76f4\:6e21\:3057\:3067 2 \:6bb5\:968e fallback\:3001
       Todo \:306f NotebookImport \:30d9\:30fc\:30b9 (Wolfram \:6a19\:6e96\:95a2\:6570\:3001context \:554f\:984c\:306a\:3057) *)
    header = If[extractHeader,
      iNotebookHeaderParse[abs], <|"ParseStatus" -> "Skipped"|>];
    todos = If[extractTodos,
      iExtractTodoCellsFromPath[abs], {}];
    todoCount = Length[todos];
    openCount = Count[todos, t_Association /; Lookup[t, "Status", ""] === "Open"];
    doneCount = Count[todos, t_Association /; Lookup[t, "Status", ""] === "Done"];
    passCount = Count[todos, t_Association /; Lookup[t, "Status", ""] === "Pass"];
    
    deadlineVal = Lookup[header, "Deadline", Missing[]];
    nextReviewVal = Lookup[header, "NextReview", Missing[]];
    reviewState = iComputeReviewState[nextReviewVal, today];
    deadlineState = iComputeDeadlineState[deadlineVal, today];
    
    (* SourceRecord \:4fdd\:5b58 *)
    sourceRecord = <|
      "Type" -> "NotebookSource",
      "NotebookRef" -> nbRef,
      "OriginalPath" -> abs,
      (* symbolic path: cross-PC stable. Relink uses this to
         tell a real move from a mere PC/root-path difference. *)
      "SymbolicPath" -> iSVSymbolicPath[abs],
      "Title" -> FileBaseName[abs],
      "FileMTime" -> Quiet[DateString[FileDate[abs]]],
      "CurrentSnapshotId" -> snapshotId,
      (* embedded UUID for file-move tracking (Relink). Missing
         if the notebook has no UUID; SourceVaultEnsureNotebookUUID
         can add one. *)
      "SourceUUID" -> Module[{u = Quiet @ SourceVaultNotebookUUID[abs]},
        If[StringQ[u], u, Missing["NoUUID"]]],
      "RegisteredAt" -> ts,
      "LastIndexedAt" -> ts
    |>;
    sourcePath = iNotebookSourcePath[nbRef];
    Module[{json, strm},
      json = Quiet @ ExportString[iSanitizeForJSON[sourceRecord],
        "RawJSON", "Compact" -> False];
      strm = Quiet[OpenWrite[sourcePath, BinaryFormat -> True]];
      If[Head[strm] === OutputStream,
        BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
        Close[strm]]];
    
    (* SnapshotRecord \:4fdd\:5b58 *)
    snapshotRecord = <|
      "Type" -> "NotebookSnapshot",
      "SnapshotId" -> snapshotId,
      "NotebookRef" -> nbRef,
      "RawContentHash" -> "sha256-" <> rawHash,
      "SemanticHash" -> Module[{h = iNotebookSemanticHashFromExpr[nbExpr]},
        If[MissingQ[h], Missing["SemanticHashFailed"], h]],
      (* Stage 9 P1 \:5225\:4ef6 CellCount = 0 \:30d0\:30b0\:4fee\:6b63:
         \:65e7\:7248 Length[Replace[nbExpr, HoldComplete[Notebook[c_List, ___]] :> c, {0}] /. ...]
         \:306f Notebook \:5185\:306e Cell[CellGroupData[...]] \:30cd\:30b9\:30c8 (\:7f60 #26) \:3092\:6271\:3048\:305a
         \:30c8\:30c3\:30d7\:30ec\:30d9\:30eb cell \:6570\:306e\:307f\:8a08\:7b97\:3057\:3066\:3044\:305f\:3002
         iFlattenCells \:306f CellGroupData \:3092\:518d\:5e30\:5c55\:958b\:3057\:3066\:771f\:306e leaf cell \:6570\:3092\:8fd4\:3059\:3002 *)
      "CellCount" -> Length[iFlattenCells[nbExpr]],
      "LifecycleStatus" -> "Current",
      "SourceMTime" -> If[IntegerQ[currentMTime], currentMTime,
        Missing["NotPresent"]],
      (* mtime \:3068\:4f75\:7528\:3059\:308b\:8efd\:91cf\:306a cache \:5224\:5b9a\:7528\:30b5\:30a4\:30ba (\:30d0\:30a4\:30c8\:6570)\:3002
         FileByteCount \:306f\:5168\:8aad\:307f\:8fbc\:307f\:4e0d\:8981\:3067\:53d6\:5f97\:3067\:304d\:308b\:305f\:3081\:3001
         cache hit \:5224\:5b9a\:3092 Hash[Import[...]] \:306a\:3057\:3067\:9ad8\:901f\:5316\:3059\:308b\:306e\:306b\:4f7f\:3046\:3002 *)
      "SourceSize" -> Quiet @ Check[FileByteCount[abs], Missing["NotPresent"]],
      (* Stage 9 P1 Step 6: snapshot \:5358\:4f4d\:306e PrivacyLevel\:3002
         \:30ed\:30fc\:30ab\:30eb .nb \:306f NBAccess \:306e\:5224\:5b9a\:3092\:7d99\:627f (\:30bb\:30eb\:6df7\:5728\:306f\:6700\:3082\:53b3\:3057\:3044\:5024)\:3002
         \:6982\:8981 (Summary) \:306f\:30b9\:30ad\:30fc\:30de\:5316\:5236\:7d04\:306b\:3088\:308a\:5e38\:306b 0.0 \:6271\:3044\:3002 *)
      "PrivacyLevel" -> iSVSnapshotPrivacyLevel[abs],
      "PrivacyLevelSource" -> "Inherited",
      "AcquisitionContext" -> "LocalFile",
      (* Stage 9 P1 Step 8: \:518d\:8d77\:52d5\:5f8c\:9ad8\:901f\:5316\:3002
         Header \:3068 Todos \:3092 Compress \:6587\:5b57\:5217\:3068\:3057\:3066 snapshot \:306b\:6c38\:7d9a\:5316\:3002
         \:3053\:308c\:306b\:3088\:308a cache hit \:6642\:306b .nb \:3092 Import \:305b\:305a record \:3092\:518d\:69cb\:7bc9\:3067\:304d\:3001
         Mathematica \:518d\:8d77\:52d5\:5f8c\:3067\:3082 mtime \:4e00\:81f4\:30d5\:30a1\:30a4\:30eb\:306f\:9ad8\:901f\:306b\:51e6\:7406\:3055\:308c\:308b\:3002
         Compress \:306f DateObject / Quantity / Missing \:3092\:542b\:3080\:4efb\:610f\:5f0f\:3092\:5b89\:5168\:306b\:5f80\:5fa9\:3067\:304d\:308b\:3002 *)
      "HeaderCompressed" -> Quiet @ Check[Compress[header], Missing[]],
      "TodosCompressed" -> Quiet @ Check[Compress[todos], Missing[]],
      "CreatedAt" -> ts
    |>;
    snapshotPath = iNotebookSnapshotPath[snapshotId];
    Module[{json, strm},
      json = Quiet @ ExportString[iSanitizeForJSON[snapshotRecord],
        "RawJSON", "Compact" -> False];
      strm = Quiet[OpenWrite[snapshotPath, BinaryFormat -> True]];
      If[Head[strm] === OutputStream,
        BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
        Close[strm]]];
    
    (* Todo records \:3092 by-notebook JSONL \:306b *)
    todoRecords = MapIndexed[Function[{t, i},
      <|"Type" -> "NotebookTodo",
        "TodoId" -> "todo-" <> nbRef <> "-" <> ToString[First[i]],
        "NotebookRef" -> nbRef,
        "SnapshotId" -> snapshotId,
        "Text" -> Lookup[t, "Text", ""],
        "Status" -> Lookup[t, "Status", "Open"],
        "StatusSource" -> Lookup[t, "StatusSource", "Default"],
        "StrikeThrough" -> Lookup[t, "StrikeThrough", False],
        "CellStyle" -> Lookup[t, "CellStyle", ""],
        "ExtractedAt" -> ts|>], todos];
    byNotebookPath = iNotebookTodosByNotebookPath[nbRef];
    todoLines = Map[Function[r,
      Quiet @ ExportString[iSanitizeForJSON[r], "RawJSON",
        "Compact" -> True]], todoRecords];
    Module[{strm},
      strm = Quiet[OpenWrite[byNotebookPath, BinaryFormat -> True]];
      If[Head[strm] === OutputStream,
        Scan[Function[ln,
          If[StringQ[ln],
            BinaryWrite[strm, StringToByteArray[ln <> "\n", "ISO8859-1"]]]], todoLines];
        Close[strm]]];
    
    (* open.jsonl / done.jsonl \:306b append (notebook \:3054\:3068\:306e\:30b9\:30ca\:30c3\:30d7\:30b7\:30e7\:30c3\:30c8) *)
    openTodoLines = Select[todoLines, StringQ];   (* \:5168\:4ef6\:306f\:30b7\:30f3\:30d7\:30eb\:306b \:540c\:5fd7\:3060\:304c P0 \:306f\:4e0a\:8a18 by-notebook \:3060\:3051\:3067\:5341\:5206 *)
    (* P0 \:306f overdue.jsonl \:3068 lint \:306f append-only \:3001\:30bf\:30a4\:30e0\:30b7\:30ea\:30fc\:30ba *)
    
    (* lint \:8a08\:7b97 + \:4fdd\:5b58 *)
    lint = iComputeNotebookLint[<|"Header" -> header, "Todos" -> todos|>];
    Module[{lintRec, lintJson, strm},
      lintRec = <|
        "Type" -> "NotebookLint",
        "NotebookRef" -> nbRef,
        "SnapshotId" -> snapshotId,
        "Lint" -> lint,
        "ComputedAt" -> ts|>;
      lintJson = Quiet @ ExportString[iSanitizeForJSON[lintRec],
        "RawJSON", "Compact" -> True];
      strm = Quiet[OpenAppend[iNotebookLintPath[],
        BinaryFormat -> True]];
      If[Head[strm] === OutputStream && StringQ[lintJson],
        BinaryWrite[strm, StringToByteArray[lintJson <> "\n", "ISO8859-1"]];
        Close[strm]]];
    
    (* Overdue Review record append (\:4eca\:9031\:5185\:306b\:904e\:304e\:305f OverdueThisWeek \:3082\:671f\:9650\:5207\:308c\:306e\:4e00\:7a2e\:306a\:306e\:3067\:542b\:3081\:308b) *)
    If[MemberQ[{"Overdue", "OverdueThisWeek"}, reviewState] ||
       MemberQ[{"Overdue", "OverdueThisWeek"}, deadlineState],
      Module[{revRec, revJson, strm},
        revRec = <|
          "Type" -> "NotebookReview",
          "NotebookRef" -> nbRef,
          "SnapshotId" -> snapshotId,
          "OriginalPath" -> abs,
          "Title" -> FileBaseName[abs],
          "Deadline" -> deadlineVal,
          "NextReview" -> nextReviewVal,
          "ReviewState" -> reviewState,
          "DeadlineState" -> deadlineState,
          "OpenTodoCount" -> openCount,
          "DoneTodoCount" -> doneCount,
          "PassTodoCount" -> passCount,
          "Lint" -> lint,
          "ComputedAt" -> ts|>;
        revJson = Quiet @ ExportString[iSanitizeForJSON[revRec],
          "RawJSON", "Compact" -> True];
        strm = Quiet[OpenAppend[iNotebookReviewOverduePath[],
          BinaryFormat -> True]];
        If[Head[strm] === OutputStream && StringQ[revJson],
          BinaryWrite[strm, StringToByteArray[revJson <> "\n", "ISO8859-1"]];
          Close[strm]]]];
    
    <|"Status" -> "OK",
      "Cached" -> False,
      "NotebookRef" -> nbRef,
      "SnapshotId" -> snapshotId,
      "Path" -> abs,
      (* \:5f8c\:65b9\:4e92\:63db: usage \:8a18\:8f09\:30fb\:65e7\:5229\:7528\:30b3\:30fc\:30c9\:304c\:671f\:5f85\:3059\:308b\:30ad\:30fc *)
      "OriginalPath" -> abs,
      "Title" -> Lookup[header, "Title", FileBaseName[abs]],
      "Todos" -> todos,
      "Header" -> header,
      "TodoCount" -> todoCount,
      "OpenTodoCount" -> openCount,
      "DoneTodoCount" -> doneCount,
      "PassTodoCount" -> passCount,
      "ReviewState" -> reviewState,
      "DeadlineState" -> deadlineState,
      "Lint" -> lint,
      "IndexedAt" -> ts,
      "SourceMTime" -> If[IntegerQ[currentMTime], currentMTime,
        Missing["NotPresent"]],
      "CacheCheck" -> cacheCheckDebug|>
  ];

Options[SourceVaultIndexNotebookFolder] = {
  "Recursive" -> False,
  "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}
};

SourceVaultIndexNotebookFolder[dir_String, opts:OptionsPattern[]] :=
  Module[{abs, recursive, excludes, files, results = {},
          processed = 0, failed = 0},
    iEnsureRoots[];
    recursive = TrueQ[OptionValue["Recursive"]];
    excludes = OptionValue["ExcludePatterns"];
    abs = ExpandFileName[dir];
    If[!DirectoryQ[abs],
      Return[<|"Status" -> "Failed", "Reason" -> "DirectoryNotFound",
        "Path" -> abs|>]];
    files = If[recursive,
      FileNames["*.nb", abs, Infinity],
      FileNames["*.nb", abs]];
    (* Stage 9 P1 Step 3 Hotfix 2: \:65e7\:7248\:306e Select \:306f
       StringExpression @@ StringSplit[#, "*"] -> ___ \:3068\:3044\:3046\:7121\:52b9\:306a\:69cb\:6587\:3092\:7d44\:307f\:7acb\:3066
       Quiet \:3067\:5168\:90e8\:6291\:6b62\:3055\:308c\:308b\:305f\:3081\:30d1\:30bf\:30fc\:30f3 match \:304c\:5e38\:306b $Failed \:306b\:306a\:308a\:3001
       \:7d50\:679c\:3068\:3057\:3066\:5168\:30d5\:30a1\:30a4\:30eb\:3092\:9664\:5916\:3057\:3066\:3044\:305f\:3002
       StringMatchQ \:306f\:30ef\:30a4\:30eb\:30c9\:30ab\:30fc\:30c9\:3092\:305d\:306e\:307e\:307e\:53d7\:3051\:53d6\:308b\:306e\:3067\:6e21\:3057\:65b9\:3092\:5358\:7d14\:5316\:3002 *)
    files = Select[files, Function[f,
      With[{name = FileNameTake[f]},
        !AnyTrue[excludes, StringMatchQ[name, #] &]]]];
    Scan[Function[f,
      Module[{r = Quiet[SourceVaultIndexNotebook[f]]},
        If[AssociationQ[r] && Lookup[r, "Status", ""] === "OK",
          processed = processed + 1,
          failed = failed + 1];
        AppendTo[results, r]]], files];
    <|"Status" -> "OK",
      "Directory" -> abs,
      "TotalFiles" -> Length[files],
      "Processed" -> processed,
      "Failed" -> failed,
      "Results" -> results|>
  ];

Options[SourceVaultFindNotebooks] = {
  "OpenTodos" -> Missing[],
  "NextReview" -> Missing[],
  "Deadline" -> Missing[],
  "Keywords" -> Missing[],
  "Title" -> Missing[],
  "Status" -> Missing[],
  "Scope" -> Missing[],
  "ForceReindex" -> False,
  "Format" -> False
};

SourceVaultFindNotebooks[opts:OptionsPattern[]] :=
  Module[{sourcesDir, files, today, query, allRecords = {}, matched, forceReindex},
    iEnsureRoots[];
    query = <|
      "OpenTodos" -> OptionValue["OpenTodos"],
      "NextReview" -> OptionValue["NextReview"],
      "Deadline" -> OptionValue["Deadline"],
      "Keywords" -> OptionValue["Keywords"],
      "Title" -> OptionValue["Title"],
      "Status" -> OptionValue["Status"],
      "Scope" -> OptionValue["Scope"]|>;
    forceReindex = TrueQ[OptionValue["ForceReindex"]];
    today = DateObject[Now, "Day"];
    sourcesDir = FileNameJoin[{iNotebooksDir[], "sources"}];
    If[!DirectoryQ[sourcesDir], Return[{}]];
    files = FileNames["*.json", sourcesDir];
    Scan[Function[f,
      Module[{source, path, indexed},
        (* Trap #28 \:5bfe\:5fdc: source JSON \:306e OriginalPath \:306f Windows \:30d1\:30b9
           (\:30d0\:30c3\:30af\:30b9\:30e9\:30c3\:30b7\:30e5) \:3092\:542b\:307f\:3001ImportString["RawJSON"] \:5358\:72ec\:3067\:306f
           parse \:306b\:5931\:6557\:3059\:308b\:3053\:3068\:304c\:3042\:308b (\:7f60 #28)\:3002iLoadJSONFromFile \:306f
           ImportString["RawJSON"] \[RightArrow] Developer`ReadRawJSONString \[RightArrow] ImportString["JSON"]
           \:306e 3 \:6bb5\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3092\:6301\:3064\:305f\:3081\:3001\:5fc5\:305a\:3053\:308c\:3092\:7d4c\:7531\:3059\:308b\:3002
           \:65e7\:5b9f\:88c5\:306f ImportString["RawJSON"] \:5358\:72ec\:3067\:3001\:5931\:6557\:6642\:306b notebook \:3092
           \:7121\:8a00\:3067 skip \:3057 SourceVaultFindNotebooks \:304c {} \:3092\:8fd4\:3059\:30d0\:30b0\:304c\:3042\:3063\:305f\:3002 *)
        source = iLoadJSONFromFile[f];
        If[ListQ[source] && !AssociationQ[source],
          source = Association[Cases[source, _Rule]]];
        If[AssociationQ[source],
          (* OriginalPath \:306f\:8a18\:9332\:6642 PC \:4f9d\:5b58\:306e\:7d76\:5bfe\:30d1\:30b9\:3002$dropbox \:7b49\:306e\:8ad6\:7406\:30eb\:30fc\:30c8\:306e
             \:30d5\:30eb\:30d1\:30b9\:306f PC \:3054\:3068\:306b\:5909\:308f\:308b\:305f\:3081\:3001\:5225 PC \:3067 index \:3055\:308c\:305f record \:306e
             OriginalPath \:306f\:73fe PC \:306b\:5b58\:5728\:3057\:306a\:3044\:3053\:3068\:304c\:3042\:308b\:3002\:305d\:3053\:3067 SymbolicPath
             ({"$onWork", ...} \:5f62\:5f0f) \:3092 iSVResolvePath \:3067\:73fe PC \:306e\:5b9f\:30d1\:30b9\:3078\:89e3\:6c7a\:3057\:3001
             \:305d\:308c\:3092\:512a\:5148\:3059\:308b\:3002SymbolicPath \:304c\:7121\:3044\:65e7 record \:306f OriginalPath \:3092
             \:305d\:306e\:307e\:307e\:4f7f\:3046\:3002\:3069\:3061\:3089\:3082\:73fe PC \:306b\:5b9f\:5728\:3057\:306a\:3051\:308c\:3070 skip \:3059\:308b\:3002 *)
          path = Module[{sym, resolved, orig},
            sym = Lookup[source, "SymbolicPath", Missing[]];
            resolved = If[ListQ[sym], iSVResolvePath[sym], Missing[]];
            orig = Lookup[source, "OriginalPath", ""];
            Which[
              StringQ[resolved] && FileExistsQ[resolved], resolved,
              StringQ[orig] && FileExistsQ[orig], orig,
              True, Missing[]]];
          If[StringQ[path],
            (* notebook \:3054\:3068\:306b in-memory \:3067 index \:3092\:4f5c\:308b (mtime cache \:3067\:9ad8\:901f) *)
            indexed = Quiet[SourceVaultIndexNotebook[path,
              "ForceReindex" -> forceReindex]];
            If[AssociationQ[indexed] && Lookup[indexed, "Status", ""] === "OK",
              AppendTo[allRecords, indexed]]]]]], files];
    matched = Select[allRecords,
      iNotebookRecordMatchesQuery[#, query, today] &];
    (* "Format" -> True \:306e\:3068\:304d\:306f\:30b9\:30b1\:30b8\:30e5\:30fc\:30eb\:8868\:3068\:540c\:5f62\:5f0f\:306e
       Grid \:3092\:8fd4\:3059\:3002LLM \:304c 1 \:95a2\:6570\:547c\:3073\:51fa\:3057\:3060\:3051\:3067\:6b63\:3057\:3044\:8868\:793a\:3092
       \:5f97\:3089\:308c\:308b\:3088\:3046\:306b\:3059\:308b\:305f\:3081\:306e\:30b7\:30e7\:30fc\:30c8\:30ab\:30c3\:30c8\:3002
       \:65e2\:5b9a (False) \:306f\:5f93\:6765\:901a\:308a record \:306e\:751f List \:3092\:8fd4\:3059 (\:5b8c\:5168\:5f8c\:65b9\:4e92\:63db)\:3002 *)
    If[TrueQ[OptionValue["Format"]],
      SourceVaultFormatNotebookList[matched],
      matched]
  ];

(* ============================================================
   SourceVaultFindTodos: todo \:9805\:76ee\:5358\:4f4d\:306e\:30d5\:30e9\:30c3\:30c8\:691c\:7d22
   SourceVaultFindNotebooks \:3067 notebook \:3092\:7d5e\:308a\:8fbc\:307f\:3001\:5404 record \:306e
   "Todos" \:3092 1 \:884c 1 \:9805\:76ee\:306b\:5c55\:958b\:3059\:308b\:3002\:300c\:4eca\:9031\:671f\:9650\:306e todo \:3092
   \:30ea\:30b9\:30c8\:300d\:306e\:3088\:3046\:306a todo \:5358\:4f4d\:306e\:8981\:6c42\:7528\:3002
   ============================================================ *)
Options[SourceVaultFindTodos] = {
  "OpenTodos" -> True,
  "NextReview" -> Missing[],
  "Deadline" -> Missing[],
  "Keywords" -> Missing[],
  "Title" -> Missing[],
  "Status" -> Missing[],
  "Scope" -> Missing[],
  "TodoStatus" -> "Open",
  "ForceReindex" -> False,
  "Format" -> False
};

SourceVaultFindTodos[opts:OptionsPattern[]] :=
  Module[{records, todoStatus, rows},
    (* notebook \:691c\:7d22\:306f FindNotebooks \:306b\:59d4\:8b72 (Format \:306f\:5fc5\:305a False \:3067 raw record \:3092\:5f97\:308b) *)
    records = SourceVaultFindNotebooks[
      "OpenTodos" -> OptionValue["OpenTodos"],
      "NextReview" -> OptionValue["NextReview"],
      "Deadline" -> OptionValue["Deadline"],
      "Keywords" -> OptionValue["Keywords"],
      "Title" -> OptionValue["Title"],
      "Status" -> OptionValue["Status"],
      "Scope" -> OptionValue["Scope"],
      "ForceReindex" -> OptionValue["ForceReindex"],
      "Format" -> False];
    If[!ListQ[records], records = {}];
    todoStatus = OptionValue["TodoStatus"];
    rows = Flatten[
      Map[
        Function[rec,
          Module[{header, title, path, nbRef, deadline, nextReview,
                  reviewState, deadlineState, todos, sel},
            header        = Lookup[rec, "Header", <||>];
            title         = Lookup[rec, "Title",
              FileBaseName[Lookup[rec, "Path", Lookup[rec, "OriginalPath", ""]]]];
            path          = Lookup[rec, "Path", Lookup[rec, "OriginalPath", ""]];
            nbRef         = Lookup[rec, "NotebookRef", ""];
            deadline      = Lookup[header, "Deadline", Missing[]];
            nextReview    = Lookup[header, "NextReview", Missing[]];
            reviewState   = Lookup[rec, "ReviewState", "NoReviewDate"];
            deadlineState = Lookup[rec, "DeadlineState", "NoDeadline"];
            (* record["Todos"] \:512a\:5148\:3002\:7121\:3051\:308c\:3070 path \:304b\:3089\:518d\:62bd\:51fa (\:5f8c\:65b9\:4e92\:63db) *)
            todos = Lookup[rec, "Todos", Missing[]];
            If[!ListQ[todos],
              todos = If[StringQ[path] && FileExistsQ[path],
                Quiet @ Check[SourceVaultExtractNotebookTodos[path], {}], {}]];
            (* TodoStatus \:3067\:7d5e\:308b (All \:306a\:3089\:5168\:90e8) *)
            sel = If[todoStatus === All || MissingQ[todoStatus],
              todos,
              Select[todos, Lookup[#, "Status", ""] === todoStatus &]];
            Map[
              Function[td,
                <|"Title" -> title,
                  "Path" -> path,
                  "NotebookRef" -> nbRef,
                  "Deadline" -> deadline,
                  "NextReview" -> nextReview,
                  "ReviewState" -> reviewState,
                  "DeadlineState" -> deadlineState,
                  "TodoText" -> Lookup[td, "Text", ""],
                  "TodoStatus" -> Lookup[td, "Status", ""],
                  "TodoStrikeThrough" -> Lookup[td, "StrikeThrough", False]|>],
              sel]
          ]],
        records],
      1];
    If[TrueQ[OptionValue["Format"]],
      iSVFormatTodoList[rows],
      rows]
  ];

(* todo \:30d5\:30e9\:30c3\:30c8 List \:3092 Grid \:8868\:793a (Format -> True \:7528) *)
iSVFormatTodoList[rows_List] :=
  If[rows === {},
    Style["\:6761\:4ef6\:306b\:5408\:3046 todo \:306f\:3042\:308a\:307e\:305b\:3093\:3002", 14],
    Grid[
      Prepend[
        Map[
          Function[r,
            {Lookup[r, "Title", ""],
             iSVTodoDateString[Lookup[r, "Deadline", Missing[]]],
             iSVTodoDateString[Lookup[r, "NextReview", Missing[]]],
             Lookup[r, "TodoStatus", ""],
             Lookup[r, "TodoText", ""]}],
          rows],
        {Style["Notebook", Bold], Style["Deadline", Bold],
         Style["NextReview", Bold], Style["Status", Bold],
         Style["Todo", Bold]}],
      Frame -> All,
      Alignment -> {Left, Center},
      Background -> {None, {{GrayLevel[0.95], White}}}]
  ];

(* DateObject \:3092 yyyy/mm/dd \:6587\:5b57\:5217\:306b\:3002Missing / \:7a7a\:306f\:7a7a\:6587\:5b57\:5217 *)
iSVTodoDateString[d_] :=
  Which[
    MatchQ[d, _DateObject], Quiet @ Check[DateString[d, {"Year", "/", "Month", "/", "Day"}], ""],
    StringQ[d], d,
    True, ""];

SourceVaultNotebookLint[record_Association] :=
  iComputeNotebookLint[record];

SourceVaultNotebookLint[path_String] :=
  Module[{abs, header, todos},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs], Return[{"MissingHeader"}]];
    header = iNotebookHeaderParse[abs];
    todos = iExtractTodoCellsFromPath[abs];
    iComputeNotebookLint[<|"Header" -> header, "Todos" -> todos|>]
  ];


(* ============================================================
   Stage 9 Phase 2 (P1) Step 1: TaggingRules \:6a19\:6e96\:5316
   - Notebook \:5168\:4f53\:306e TaggingRules: Import[path, "Notebook"] \:7d4c\:7531
   - Cell \:5358\:4f4d\:306e TaggingRules: NotebookImport[path, style -> "Cell"] \:7d4c\:7531
   - \:3044\:305a\:308c\:3082 Wolfram \:6a19\:6e96\:95a2\:6570\:7d4c\:7531 (rule 102)
   - context \:975e\:4f9d\:5b58 (`SymbolName[Head[]]` / `SymbolName[Keys[]]` \:30d1\:30bf\:30fc\:30f3\:3001\:7f60 #23 \:56de\:907f)
   ============================================================ *)

(* Notebook[_List, opts___] \:306e opts \:90e8\:5206\:3092 Association \:5316\:3002
   nbExpr \:306f HoldComplete[Notebook[...]] (iReadNotebookExpr \:306e\:8fd4\:308a\:5024 Expr \:30d5\:30a3\:30fc\:30eb\:30c9)\:3002 *)
iNotebookOptionsAssociation[nbExpr_HoldComplete] :=
  Module[{nb, optsList},
    nb = Replace[nbExpr, HoldComplete[x_] :> x, {0}];
    If[!MatchQ[nb, Notebook[_List, ___]],
      Return[<||>]];
    optsList = Drop[List @@ nb, 1];
    Association[Cases[optsList, _Rule]]
  ];

(* Notebook \:5168\:4f53\:306e TaggingRules (Notebook[..., TaggingRules -> _] \:306e\:5024) \:3092\:53d6\:5f97 *)
iNotebookTaggingRulesFromExpr[nbExpr_HoldComplete] :=
  Module[{opts, tagKey, tagging},
    opts = iNotebookOptionsAssociation[nbExpr];
    tagKey = SelectFirst[Keys[opts],
      SymbolName[#] === "TaggingRules" &, Null];
    If[tagKey === Null, Return[<||>]];
    tagging = opts[tagKey];
    If[AssociationQ[tagging], tagging, <||>]
  ];

(* Cell \:306e opts (Association) \:304b\:3089 TaggingRules \:3092\:53d6\:5f97 (Stage 9 P0 iTodoStatusFromOptions
   \:306e\:5197\:982d\:30ed\:30b8\:30c3\:30af\:6d41\:7528\:3001context \:975e\:4f9d\:5b58)\:3002
   TaggingRules \:304c\:7121\:3051\:308c\:3070 <||>\:3001\:3042\:308c\:3070 Association \:3092\:8fd4\:3059\:3002 *)
iCellTaggingRulesFromOptions[opts_Association] :=
  Module[{tagKey, tagging},
    tagKey = SelectFirst[Keys[opts],
      SymbolName[#] === "TaggingRules" &, Null];
    If[tagKey === Null, Return[<||>]];
    tagging = opts[tagKey];
    If[AssociationQ[tagging], tagging, <||>]
  ];

(* \:5404 TodoItem cell \:306e TaggingRules \:3092 path \:304b\:3089\:53d6\:5f97 (NotebookImport \:7d4c\:7531\:3001Stage 9 P0 \:3068\:540c\:3058\:7d4c\:8def) *)
iExtractTodoCellTaggingRulesFromPath[path_String] :=
  Module[{styles, results = {}, idx = 0},
    If[!FileExistsQ[path], Return[{}]];
    styles = {"TodoItem_1", "TodoItem_2", "TodoItem_3"};
    Scan[
      Function[style,
        Module[{cells},
          cells = Quiet[NotebookImport[path, style -> "Cell"]];
          If[ListQ[cells],
            Scan[
              Function[c,
                If[SymbolName[Head[c]] === "Cell" && Length[c] >= 2,
                  Module[{args = List @@ c, opts, tr},
                    idx = idx + 1;
                    opts = Association[Cases[Drop[args, 2], _Rule]];
                    tr = iCellTaggingRulesFromOptions[opts];
                    AppendTo[results, <|
                      "Index" -> idx,
                      "CellStyle" -> style,
                      "TaggingRules" -> tr
                    |>]
                  ]
                ]
              ],
              cells
            ]
          ]
        ]
      ],
      styles
    ];
    results
  ];

(* === Public API: SourceVaultExtractNotebookTaggingRules === *)

Options[SourceVaultExtractNotebookTaggingRules] = {};

SourceVaultExtractNotebookTaggingRules[path_String,
  opts:OptionsPattern[]] :=
  Module[{abs, readResult, nbExpr, nbTr, cellTrs},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[<|"Status" -> "Failed", "Reason" -> "FileNotFound",
        "Path" -> abs|>]];
    readResult = iReadNotebookExpr[abs];
    If[Lookup[readResult, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[readResult, "Reason", "ReadFailed"],
        "Path" -> abs|>]];
    nbExpr = Lookup[readResult, "Expr"];
    nbTr = iNotebookTaggingRulesFromExpr[nbExpr];
    cellTrs = iExtractTodoCellTaggingRulesFromPath[abs];
    <|"Status" -> "OK",
      "Path" -> abs,
      "NotebookTaggingRules" -> nbTr,
      "CellTaggingRules" -> cellTrs|>
  ];


(* ============================================================
   Stage 9 Phase 2 (P1) Step 2: NotebookSemanticHash
   - notebook \:306e\:610f\:5473\:7684\:5185\:5bb9\:306e\:307f\:3092\:30cf\:30c3\:30b7\:30e5\:5bfe\:8c61\:3068\:3057\:3001\:8868\:793a\:3084 cache \:30e1\:30bf\:30c7\:30fc\:30bf\:3092\:9664\:5916
   - Stage 8 lifecycle \:3068\:9023\:643a\:3001formatting \:306e\:307f\:306e\:5909\:66f4\:3067 Stale \:5316\:8aa4\:5224\:5b9a\:3092\:9632\:3050
   - Wolfram \:6a19\:6e96\:95a2\:6570\:512a\:5148\:539f\:5247 (rule 102): Hash[normalizedExpr, "SHA256", "HexString"]
   - \:9664\:5916\:30ea\:30b9\:30c8\:30a2\:30d7\:30ed\:30fc\:30c1 (\:610f\:5473\:7684\:306b\:91cd\:8981\:306a\:8981\:7d20\:306f\:4fdd\:6301)
   ============================================================ *)

(* \:9664\:5916\:5bfe\:8c61\:306e Cell options \:30ad\:30fc\:540d (SymbolName \:3067\:6587\:5b57\:5217\:6bd4\:8f03)
   - ExpressionUUID / CellChangeTimes / CellLabel: notebook \:8a55\:4fa1\:3067\:5909\:308f\:308b\:3001\:610f\:5473\:7121\:3057
   - CellID: \:53cc\:65b9\:5411 link \:306e\:305f\:3081\:306e ID\:3001\:610f\:5473\:7121\:3057
   - FontFamily / FontSize: \:8868\:793a\:8a2d\:5b9a\:3001\:610f\:5473\:7121\:3057 (FontVariations / FontColor / Background \:306f\:4fdd\:6301: Todo Status \:306e\:6839\:62e0)
   - PageWidth / PageBreakBelow: \:5370\:5237\:8a2d\:5b9a *)
$iNotebookSemanticHashCellExcludeKeys = {
  "ExpressionUUID", "CellChangeTimes", "CellLabel",
  "CellID", "CellTags",
  "FontFamily", "FontSize",
  "PageWidth", "PageBreakBelow", "PageBreakAbove",
  "ShowCellTags", "ShowCellLabel", "ShowGroupOpener"
};

(* \:9664\:5916\:5bfe\:8c61\:306e Notebook \:5168\:4f53 options \:30ad\:30fc\:540d *)
$iNotebookSemanticHashNotebookExcludeKeys = {
  "ExpressionUUID", "FrontEndVersion",
  "WindowSize", "WindowMargins", "WindowFrame", "WindowTitle",
  "Saveable", "DockedCells",
  "StyleDefinitions",
  "TaggingRules"
  (* \:6ce8: notebook \:5168\:4f53\:306e TaggingRules \:3082\:9664\:5916\:3002\:73fe\:6642\:70b9\:3067\:306f cell \:5358\:4f4d\:306e TaggingRules \:306f\:4fdd\:6301\:3055\:308c\:308b *)
};

iNormalizeCellOptionsForHash[opts_Association] :=
  KeySelect[opts,
    !MemberQ[$iNotebookSemanticHashCellExcludeKeys,
      SymbolName[#]] &];

(* Cell content \:90e8\:5206\:306e\:6b63\:898f\:5316: BoxData \:306f\:305d\:306e\:307e\:307e\:3001
   CellGroupData \:304c\:5165\:308c\:5b50\:306b\:3042\:308b\:5834\:5408\:306f\:518d\:5e30 normalize *)
iNormalizeCellContent[content_] :=
  Which[
    SymbolName[Head[content]] === "CellGroupData",
      iNormalizeCellForHash[content],
    True, content
  ];

(* Cell \:307e\:305f\:306f CellGroupData \:3092\:6b63\:898f\:5316\:3002
   - Cell[content, style, opts___] \:306f opts \:3092\:9664\:5916\:3001content \:3082\:518d\:5e30 normalize
   - CellGroupData[{Cell, Cell, ...}, ...] \:306f\:5165\:308c\:5b50\:306e Cell \:30ea\:30b9\:30c8\:3092\:518d\:5e30 normalize *)
iNormalizeCellForHash[c_] :=
  Module[{head, args, content, style, rest, opts, normOpts},
    head = SymbolName[Head[c]];
    args = List @@ c;
    Which[
      head === "Cell" && Length[args] >= 2,
        content = args[[1]];
        style = args[[2]];
        rest = Drop[args, 2];
        opts = Association[Cases[rest, _Rule]];
        normOpts = iNormalizeCellOptionsForHash[opts];
        content = iNormalizeCellContent[content];
        Cell[content, style, Sequence @@ Normal[normOpts]],
      head === "CellGroupData" && Length[args] >= 1,
        Module[{cells = args[[1]], normCells},
          normCells = If[ListQ[cells],
            iNormalizeCellForHash /@ cells,
            cells];
          CellGroupData[normCells, Sequence @@ Drop[args, 1]]
        ],
      True, c
    ]
  ];

(* Notebook[{cells}, opts___] \:5168\:4f53\:3092\:6b63\:898f\:5316 *)
iNormalizeNotebookForHash[nbExpr_HoldComplete] :=
  Module[{nb, cells, optsList, opts, normCells, normOpts},
    nb = Replace[nbExpr, HoldComplete[x_] :> x, {0}];
    If[!MatchQ[nb, Notebook[_List, ___]],
      Return[Missing["NotANotebook"]]];
    cells = First[nb];
    optsList = Drop[List @@ nb, 1];
    opts = Association[Cases[optsList, _Rule]];
    normCells = iNormalizeCellForHash /@ cells;
    normOpts = KeySelect[opts,
      !MemberQ[$iNotebookSemanticHashNotebookExcludeKeys,
        SymbolName[#]] &];
    Notebook[normCells, Sequence @@ Normal[normOpts]]
  ];

(* SemanticHash \:8a08\:7b97\:672c\:4f53\:3002Wolfram \:6a19\:6e96 Hash[expr, "SHA256", "HexString"] \:3092\:4f7f\:7528 (rule 102)\:3002
   \:6b63\:898f\:5316\:6e08\:307f\:5f0f\:306b\:5bfe\:3057\:3066 deterministic \:306a hex 64 \:6841\:3002 *)
iNotebookSemanticHashFromExpr[nbExpr_HoldComplete] :=
  Module[{norm, h},
    norm = iNormalizeNotebookForHash[nbExpr];
    If[FailureQ[norm] || MissingQ[norm],
      Return[Missing["NotANotebook"]]];
    h = Quiet[Hash[norm, "SHA256", "HexString"]];
    If[!StringQ[h], Return[Missing["HashFailed"]]];
    "semhash-sha256-" <> h
  ];

(* === Public API: SourceVaultNotebookSemanticHash === *)

Options[SourceVaultNotebookSemanticHash] = {};

SourceVaultNotebookSemanticHash[path_String, opts:OptionsPattern[]] :=
  Module[{abs, readResult, nbExpr, hash},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[<|"Status" -> "Failed", "Reason" -> "FileNotFound",
        "Path" -> abs|>]];
    readResult = iReadNotebookExpr[abs];
    If[Lookup[readResult, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[readResult, "Reason", "ReadFailed"],
        "Path" -> abs|>]];
    nbExpr = Lookup[readResult, "Expr"];
    hash = iNotebookSemanticHashFromExpr[nbExpr];
    If[MissingQ[hash],
      Return[<|"Status" -> "Failed",
        "Reason" -> ToString[hash], "Path" -> abs|>]];
    <|"Status" -> "OK", "Path" -> abs, "SemanticHash" -> hash|>
  ];


(* ============================================================
   Stage 9 Phase 2 (P1) Step 4: Summary artifact stale \:5224\:5b9a
   - Summary artifact \:3092 notebook \:306e\:7279\:5b9a snapshot \:306b\:7d10\:3065\:3051\:3066\:4fdd\:5b58
   - SemanticHash (Step 2) \:3092\:5229\:7528\:3057 formatting \:306e\:307f\:306e\:5909\:66f4\:3092\:533a\:5225
   - Step 5 (LLM \:8981\:7d04) \:304c\:6765\:305f\:3068\:304d\:3001\:5185\:90e8\:3067 RegisterNotebookSummary \:3092\:547c\:3076\:3060\:3051\:3067\:9023\:643a
   ============================================================ *)

(* === Public API: SourceVaultRegisterNotebookSummary === *)

Options[SourceVaultRegisterNotebookSummary] = {
  "SummaryFormat" -> "text",
  "GeneratedBy" -> "manual"
};

SourceVaultRegisterNotebookSummary[path_String, summary_String,
    opts:OptionsPattern[]] :=
  Module[{abs, indexResult, nbRef, snapshotId, semanticHash,
          summaryFormat, generatedBy, ts, summaryId, record,
          saveResult, snapshotRecPath, snapshotRec},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[<|"Status" -> "Failed", "Reason" -> "FileNotFound",
        "Path" -> abs|>]];
    summaryFormat = OptionValue["SummaryFormat"];
    generatedBy = OptionValue["GeneratedBy"];
    nbRef = iNotebookRefFromPath[abs];
    (* \:73fe\:5728 snapshot \:3092\:5fc5\:8981\:3002Index \:6e08\:307f\:306a\:3089 sources/ \:304b\:3089 SnapshotId
       \:53d6\:5f97\:3001\:672a Index \:306a\:3089 IndexNotebook \:3092\:5b9f\:884c\:3002 *)
    Module[{srcRec, srcPath = iNotebookSourcePath[nbRef]},
      srcRec = iLoadJSONFromFile[srcPath];
      snapshotId = If[AssociationQ[srcRec],
        Lookup[srcRec, "CurrentSnapshotId", Null], Null]];
    If[!StringQ[snapshotId],
      (* \:672a Index \:306a\:306e\:3067 IndexNotebook \:3092\:5b9f\:884c\:3002 *)
      indexResult = SourceVaultIndexNotebook[abs];
      If[Lookup[indexResult, "Status", ""] =!= "OK",
        Return[<|"Status" -> "Failed",
          "Reason" -> "IndexNotebookFailed",
          "IndexResult" -> indexResult|>]];
      snapshotId = Lookup[indexResult, "SnapshotId", ""]];
    (* SnapshotId \:304b\:3089 snapshot record \:3092\:8aad\:3093\:3067 SemanticHash \:3092\:53d6\:308b\:3002 *)
    snapshotRecPath = iNotebookSnapshotPath[snapshotId];
    snapshotRec = iLoadJSONFromFile[snapshotRecPath];
    semanticHash = If[AssociationQ[snapshotRec],
      Lookup[snapshotRec, "SemanticHash", Missing["NotPresent"]],
      Missing["SnapshotRecordNotFound"]];
    ts = DateString[Now, {"Year", "-", "Month", "-", "Day", "T",
      "Hour", ":", "Minute", ":", "Second"}];
    summaryId = "sum-" <> nbRef;
    record = <|
      "Type" -> "NotebookSummary",
      "SummaryId" -> summaryId,
      "NotebookRef" -> nbRef,
      "BasedOnSnapshot" -> snapshotId,
      "BasedOnSemanticHash" -> semanticHash,
      "Summary" -> summary,
      "SummaryFormat" -> summaryFormat,
      "GeneratedBy" -> generatedBy,
      "CreatedAt" -> ts
    |>;
    saveResult = iSaveNotebookSummaryRecord[record];
    If[Lookup[saveResult, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[saveResult, "Reason", "WriteFailed"]|>]];
    <|"Status" -> "OK",
      "SummaryId" -> summaryId,
      "NotebookRef" -> nbRef,
      "BasedOnSnapshot" -> snapshotId,
      "BasedOnSemanticHash" -> semanticHash,
      "Path" -> Lookup[saveResult, "Path", ""],
      "CreatedAt" -> ts|>
  ];

(* === Public API: SourceVaultGetNotebookSummary === *)

Options[SourceVaultGetNotebookSummary] = {};

SourceVaultGetNotebookSummary[path_String, opts:OptionsPattern[]] :=
  Module[{abs, nbRef, record},
    abs = ExpandFileName[path];
    nbRef = iNotebookRefFromPath[abs];
    record = iLoadNotebookSummaryRecord[nbRef];
    If[record === Null,
      Return[<|"Status" -> "Missing",
        "Reason" -> "SummaryNotFound",
        "NotebookRef" -> nbRef|>]];
    <|"Status" -> "OK",
      "SummaryId" -> Lookup[record, "SummaryId", ""],
      "NotebookRef" -> nbRef,
      "Summary" -> Lookup[record, "Summary", ""],
      "SummaryFormat" -> Lookup[record, "SummaryFormat", "text"],
      "BasedOnSnapshot" -> Lookup[record, "BasedOnSnapshot", ""],
      "BasedOnSemanticHash" -> Lookup[record, "BasedOnSemanticHash",
        Missing["NotPresent"]],
      "GeneratedBy" -> Lookup[record, "GeneratedBy", ""],
      "CreatedAt" -> Lookup[record, "CreatedAt", ""]|>
  ];

(* === Public API: SourceVaultNotebookSummaryStatus === *)

Options[SourceVaultNotebookSummaryStatus] = {};

SourceVaultNotebookSummaryStatus[path_String, opts:OptionsPattern[]] :=
  Module[{abs, nbRef, srcRec, srcPath, currentSnapshotId,
          snapshotRecPath, snapshotRec, currentSemanticHash,
          summaryRecord},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[<|"Status" -> "Failed", "Reason" -> "FileNotFound",
        "Path" -> abs|>]];
    nbRef = iNotebookRefFromPath[abs];
    srcPath = iNotebookSourcePath[nbRef];
    srcRec = iLoadJSONFromFile[srcPath];
    currentSnapshotId = If[AssociationQ[srcRec],
      Lookup[srcRec, "CurrentSnapshotId", Null], Null];
    If[!StringQ[currentSnapshotId],
      Return[<|"Status" -> "Failed",
        "Reason" -> "NotebookNotIndexed",
        "NotebookRef" -> nbRef|>]];
    snapshotRecPath = iNotebookSnapshotPath[currentSnapshotId];
    snapshotRec = iLoadJSONFromFile[snapshotRecPath];
    currentSemanticHash = If[AssociationQ[snapshotRec],
      Lookup[snapshotRec, "SemanticHash", Missing["NotPresent"]],
      Missing["SnapshotRecordNotFound"]];
    summaryRecord = iLoadNotebookSummaryRecord[nbRef];
    iComputeNotebookSummaryStatus[summaryRecord,
      currentSnapshotId, currentSemanticHash]
  ];


(* ============================================================
   Stage 9 Phase 2 (P1) Step 5: LLM \:8981\:7d04
   - SourceVaultNotebookSummary[path, opts] \:3092\:8ffd\:52a0
   - prompt \:751f\:6210 (header / todo / lint / \:5148\:982d\:8907\:6570 cell text)
   - LLM \:547c\:3073\:51fa\:3057 = ClaudeQuerySync (claudecode.wl \:65e2\:5b58 API)
   - default PrivacyLevel = 1.0 (\:30ed\:30fc\:30ab\:30eb LM \:7d4c\:7531)
   - Step 4 \:306e Register \:7d4c\:7531\:3067\:81ea\:52d5\:7684\:306b lifecycle \:7ba1\:7406\:306b\:4e57\:308b
   ============================================================ *)

(* notebook \:306e\:5148\:982d\:8907\:6570 cell \:304b\:3089\:30c6\:30ad\:30b9\:30c8\:3092\:62bd\:51fa (Title/Section/Text/Input) *)
(* Stage 9 P1 ext: read the explicit confidentiality tag from a raw
   Cell expression (TaggingRules > "claudecode" > "confidential").
   Works on file-loaded cells, so the summary builder can drop
   confidential cells up front instead of relying on the LLM. *)
iSVCellConfidentialTag[c_] :=
  Module[{tr = Missing[], cc, conf},
    If[SymbolName[Head[c]] =!= "Cell", Return[Missing[]]];
    Scan[
      Function[o,
        If[(Head[o] === Rule || Head[o] === RuleDelayed) &&
            Head[o[[1]]] === Symbol &&
            SymbolName[o[[1]]] === "TaggingRules",
          tr = o[[2]]]],
      List @@ c];
    If[MissingQ[tr] || !(ListQ[tr] || AssociationQ[tr]),
      Return[Missing[]]];
    cc = Lookup[tr, "claudecode", {}];
    If[!(ListQ[cc] || AssociationQ[cc]), Return[Missing[]]];
    conf = Lookup[cc, "confidential", Missing[]];
    conf
  ];

iExtractFirstCellTexts[path_String, maxCells_Integer:8] :=
  Module[{readResult, nbExpr, cells, texts = {}, count = 0},
    readResult = iReadNotebookExpr[path];
    If[Lookup[readResult, "Status", ""] =!= "OK", Return[{}]];
    nbExpr = Lookup[readResult, "Expr"];
    cells = Replace[nbExpr, HoldComplete[Notebook[c_List, ___]] :> c, {0}];
    If[!ListQ[cells], Return[{}]];
    Scan[
      Function[c,
        If[count < maxCells &&
            SymbolName[Head[c]] === "Cell" && Length[c] >= 2,
          Module[{style = c[[2]], text},
            (* style \:304c String \:307e\:305f\:306f String \:30ea\:30b9\:30c8 *)
            If[(StringQ[style] || (ListQ[style] && Length[style] > 0 && StringQ[First[style]])) &&
                MemberQ[{"Title", "Subtitle", "Chapter", "Section", "Subsection",
                  "Subsubsection", "Text", "Input", "Code", "InitializationCell"},
                  If[StringQ[style], style, First[style]]] &&
                iSVCellConfidentialTag[c] =!= True,
              text = iCellTextExtract[c];
              If[StringQ[text] && StringLength[text] > 0,
                AppendTo[texts, <|
                  "Style" -> If[StringQ[style], style, First[style]],
                  "Text" -> text|>];
                count = count + 1]]]]],
      cells];
    texts
  ];

(* notebook \:306e\:5185\:5bb9\:304b\:3089 LLM prompt \:3092\:69cb\:7bc9 *)
iBuildNotebookSummaryPrompt[path_String, header_Association,
    todos_List, lint_List, maxLength_Integer, language_] :=
  Module[{title, keywords, status, deadline, nextReview,
          openTodos, doneTodos, passTodos, firstCells,
          effectiveLang, langInstruction, prompt},
    title = FileBaseName[path];
    keywords = Lookup[header, "Keywords", {}];
    status = Lookup[header, "Status", "Unknown"];
    deadline = Lookup[header, "Deadline", Missing["NotPresent"]];
    nextReview = Lookup[header, "NextReview", Missing["NotPresent"]];
    openTodos = Select[todos, Lookup[#, "Status", ""] === "Open" &];
    doneTodos = Select[todos, Lookup[#, "Status", ""] === "Done" &];
    passTodos = Select[todos, Lookup[#, "Status", ""] === "Pass" &];
    firstCells = iExtractFirstCellTexts[path, 8];
    (* Stage 9 P1.5: $Language \:304b\:3089\:65e2\:5b9a\:8a00\:8a9e\:3092\:89e3\:6c7a\:3057\:3001
       Japanese \:306a\:3089\:5e38\:4f53 (da/dearu) \:9650\:5b9a\:3067\:66f8\:304b\:305b\:308b\:3002\:305d\:308c\:4ee5\:5916\:306f\:82f1\:6587\:3002
       Automatic \:6307\:5b9a\:6642\:306e\:307f $Language \:3092\:53c2\:7167\:3059\:308b (\:660e\:793a\:6307\:5b9a\:3055\:308c\:305f\:8a00\:8a9e\:306f\:5c0a\:91cd)\:3002 *)
    effectiveLang = Which[
      language === "Japanese", "Japanese",
      language === "English", "English",
      language === Automatic && MemberQ[Flatten[{$Language}], "Japanese"],
        "Japanese",
      language === Automatic, "English",
      True, "English"
    ];
    langInstruction = Which[
      effectiveLang === "Japanese",
        StringJoin[
          "Respond in Japanese using \:5e38\:4f53 (plain form, da/dearu style) only. ",
          "Do NOT use \:656c\:4f53 (polite form). ",
          "Sentence endings must be \"...\:3067\:3042\:308b\" / \"...\:3060\" / \"...\:3059\:308b\" etc. ",
          "Never use \"...\:3067\:3059\" / \"...\:307e\:3059\" / \"...\:3067\:3057\:3087\:3046\"."],
      True, "Respond in English."
    ];
    prompt = StringJoin[
      "You are summarizing a Mathematica notebook for an index. ",
      "Produce a concise summary in at most ", ToString[maxLength],
      " characters. ", langInstruction, "\n\n",
      (* Stage 9 P1 Step 9: \:8981\:7d04\:54c1\:8cea\:6539\:5584\:3002
         \:65e7\:30d7\:30ed\:30f3\:30d7\:30c8\:306f current state / todos / deadline \:3092
         \:8981\:7d04\:306b\:542b\:3081\:308b\:3088\:3046\:6307\:793a\:3057\:3066\:3044\:305f\:304c\:3001\:3053\:308c\:3089\:306f\:8868\:306e
         \:5225\:5217 (Status / OpenTodos / Deadline / NextReview) \:3067\:65e2\:306b
         \:8868\:793a\:3055\:308c\:3066\:304a\:308a\:3001\:8981\:7d04\:306b\:518d\:63b2\:3059\:308b\:3068
         \"\:30b9\:30c6\:30fc\:30bf\:30b9\:306f Todo\:3001Todo \:306f\:8a18\:9332\:306a\:3057\" \:306e\:3088\:3046\:306a
         \:5197\:9577\:3067\:7121\:5185\:5bb9\:306a\:8981\:7d04\:306b\:306a\:308b\:3002\:8981\:7d04\:306f
         \:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:5b9f\:8cea\:7684\:306a\:4e2d\:8eab\:30fb\:4e3b\:984c\:306e\:307f\:3092\:8a18\:8ff0\:3059\:308b\:3002 *)
      "Summarize WHAT THE NOTEBOOK CONTAINS: its actual subject matter, ",
      "the concrete topics, methods, data, or results it covers. ",
      "Write 1-3 substantive sentences a reader could not guess from the ",
      "title and keywords alone.\n\n",
      "Do NOT mention any of the following - they are shown separately ",
      "in other columns of the index table and must NOT appear in the ",
      "summary:\n",
      "- the notebook status (Todo / Done / Pass)\n",
      "- the number of open / done / pass todos, or that there are none\n",
      "- deadline or next-review dates\n",
      "- the title verbatim, or a restatement of the keyword list\n",
      "Also do NOT include disclaimers or self-reference. ",
      "If the notebook has little substantive content, say so briefly ",
      "rather than padding with the metadata above.\n\n",
      (* Stage 9 P1 Step 6: \:30b9\:30ad\:30fc\:30de\:5316\:5236\:7d04\:3002
         \:6982\:8981\:306f\:5b9a\:7fa9\:4e0a\:30af\:30e9\:30a6\:30c9 LLM \:306b\:6295\:5165\:53ef\:80fd\:306a\:30b9\:30ad\:30fc\:30de\:60c5\:5831\:3067\:3042\:308b\:3079\:304d\:3002
         \:305d\:306e\:305f\:3081\:500b\:4eba\:60c5\:5831\:30fb\:6a5f\:5bc6\:60c5\:5831\:3092\:6982\:8981\:306b\:542b\:3081\:3055\:305b\:306a\:3044\:3002 *)
      "=== CRITICAL PRIVACY CONSTRAINT ===\n",
      "This summary will be treated as schema-level information that may be ",
      "sent to cloud services. You MUST NOT include any of the following:\n",
      "- Personal names (of individuals). Generalize to roles like ",
      "'a student', 'a collaborator', 'the instructor' instead.\n",
      "- Email addresses, phone numbers, postal addresses.\n",
      "- Authentication tokens, passwords, API keys, URL query parameters.\n",
      "- Any other personally identifying or confidential information.\n",
      "Describe only the SUBJECT, STATE, and FIELD of the work. ",
      "If the notebook content centers on a specific person, describe the ",
      "topic abstractly without naming them.\n\n",
      "=== Notebook metadata (context only - do NOT echo into summary) ===\n",
      "Title: ", title, "\n",
      "Status (header): ", ToString[status], "\n",
      If[!MissingQ[deadline],
        "Deadline: " <> ToString[deadline] <> "\n", ""],
      If[!MissingQ[nextReview],
        "Next review: " <> ToString[nextReview] <> "\n", ""],
      If[ListQ[keywords] && Length[keywords] > 0,
        "Keywords: " <> StringRiffle[keywords, ", "] <> "\n", ""],
      "\n=== Todos (context only - do NOT echo counts into summary) ===\n",
      "Open (", ToString[Length[openTodos]], "): ",
      StringRiffle[Lookup[#, "Text", "?"] & /@ openTodos, "; "], "\n",
      "Done (", ToString[Length[doneTodos]], "): ",
      StringRiffle[Lookup[#, "Text", "?"] & /@ doneTodos, "; "], "\n",
      "Pass (", ToString[Length[passTodos]], "): ",
      StringRiffle[Lookup[#, "Text", "?"] & /@ passTodos, "; "], "\n",
      If[Length[lint] > 0,
        "\n=== Lint flags ===\n" <> StringRiffle[lint, ", "] <> "\n", ""],
      "\n=== First cells (primary source for the summary) ===\n",
      StringJoin[Function[c,
        "[" <> Lookup[c, "Style", "?"] <> "] " <>
        StringTake[Lookup[c, "Text", ""], UpTo[200]] <> "\n"] /@ firstCells],
      "\n=== Output ===\nProvide only the summary text, nothing else. ",
      "Describe the notebook's actual content. ",
      "Do NOT restate status, todo counts, or dates. ",
      "Remember: no personal names, no contact info, no credentials."
    ];
    prompt
  ];


(* Stage 9 P1 Step 6: \:6982\:8981\:30c6\:30ad\:30b9\:30c8\:306e\:30b9\:30ad\:30fc\:30de\:9069\:5408\:6027\:691c\:8a3c\:3002
   \:500b\:4eba\:60c5\:5831\:30fb\:9023\:7d61\:5148\:30fb\:8a8d\:8a3c\:60c5\:5831\:304c\:6df7\:5165\:3057\:3066\:3044\:306a\:3044\:304b\:6b63\:898f\:8868\:73fe\:3067\:30c1\:30a7\:30c3\:30af\:3002
   \:8fd4\:308a\:5024: <|"Valid" -> True|False, "Violations" -> {_String, ...}|> *)
iSVValidateSummarySchema[summary_String] :=
  Module[{violations = {}},
    (* \:30e1\:30fc\:30eb\:30a2\:30c9\:30ec\:30b9 *)
    If[StringContainsQ[summary,
        RegularExpression["[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"]],
      AppendTo[violations, "EmailAddress"]];
    (* \:96fb\:8a71\:756a\:53f7\:3089\:3057\:304d\:6570\:5b57\:5217 (\:30cf\:30a4\:30d5\:30f3 / \:62ec\:5f27\:533a\:5207\:308a\:306e 9 \:6841\:4ee5\:4e0a) *)
    If[StringContainsQ[summary,
        RegularExpression["\\d{2,4}[-()]\\d{2,4}[-()]?\\d{3,4}"]],
      AppendTo[violations, "PhoneNumber"]];
    (* URL \:306e\:8a8d\:8a3c\:30d1\:30e9\:30e1\:30fc\:30bf (token / key / password / auth \:3092\:542b\:3080 query) *)
    If[StringContainsQ[summary,
        RegularExpression["[?&](token|key|password|passwd|auth|secret)="]],
      AppendTo[violations, "AuthURLParameter"]];
    (* API \:30ad\:30fc\:3089\:3057\:304d\:9577\:3044\:82f1\:6570\:5b57\:5217 (32 \:6841\:4ee5\:4e0a\:306e hex / base64 \:7247) *)
    If[StringContainsQ[summary,
        RegularExpression["\\b[A-Za-z0-9_-]{32,}\\b"]],
      AppendTo[violations, "PossibleAPIKey"]];
    <|"Valid" -> (violations === {}),
      "Violations" -> violations|>
  ];

(* LLM \:547c\:3073\:51fa\:3057 (ClaudeQuerySync \:7d4c\:7531)
   \:91cd\:8981\:306a\:6559\:8a13: ClaudeCode\`PrivacyLevel \:30aa\:30d7\:30b7\:30e7\:30f3\:540d\:306e\:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:89e3\:6c7a\:306b\:983c\:308b\:3068\:3001
   ClaudeQuerySync \:5185\:90e8\:306e OptionValue[PrivacyLevel] \:304c Automatic \:306b\:5224\:5b9a\:3055\:308c\:308b\:30b1\:30fc\:30b9\:304c\:3042\:308b\:3002
   \:78ba\:5b9f\:306a\:65b9\:6cd5: SourceVault \:5074\:3067 PrivacyLevel \:3092\:30e2\:30c7\:30eb\:9078\:629e\:306b\:5909\:63db\:3057\:3001
   \:5e38\:306b Model \:3092\:660e\:793a\:7684\:306b\:6307\:5b9a\:3059\:308b (PrivacyLevel \:30aa\:30d7\:30b7\:30e7\:30f3\:306f\:6e21\:3055\:306a\:3044)\:3002 *)
iCallSummaryLLM[prompt_String, model_, privacyLevel_] :=
  Module[{response, effectiveModel, privModel},
    (* ClaudeCode \:30d1\:30c3\:30b1\:30fc\:30b8\:3092\:5fc5\:8981\:6642\:306b\:30ed\:30fc\:30c9 *)
    Quiet @ Needs["ClaudeCode`"];
    If[Length[Names["ClaudeCode`ClaudeQuerySync"]] === 0,
      Return[<|"Status" -> "Failed",
        "Reason" -> "ClaudeQuerySyncNotAvailable",
        "Detail" -> "ClaudeCode`ClaudeQuerySync \:304c\:30ed\:30fc\:30c9\:3055\:308c\:3066\:3044\:307e\:305b\:3093\:3002claudecode.wl \:3092\:5148\:306b\:30ed\:30fc\:30c9\:3057\:3066\:304f\:3060\:3055\:3044\:3002"|>]];

    (* $ClaudePrivateModel \:306e\:5024\:3092\:53d6\:5f97 (Symbol \:7d4c\:7531\:3067 ClaudeCode \:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:306e\:5024\:3092\:53d6\:308b) *)
    privModel = Which[
      Length[Names["ClaudeCode`$ClaudePrivateModel"]] > 0,
        Quiet @ Symbol["ClaudeCode`$ClaudePrivateModel"],
      True, Null
    ];

    (* \:30e2\:30c7\:30eb\:6c7a\:5b9a\:30ed\:30b8\:30c3\:30af:
       (1) \:30e6\:30fc\:30b6\:304c\:660e\:793a\:6307\:5b9a \[Rule] \:305d\:308c\:3092\:4f7f\:3046
       (2) PrivacyLevel > 0.5 (default 1.0) \:304b\:3064 $ClaudePrivateModel \:6709\:52b9 \[Rule] \:305d\:306e\:30e2\:30c7\:30eb
       (3) \:305d\:308c\:4ee5\:5916 \[Rule] Automatic (ClaudeQuerySync \:5185\:90e8\:306e\:81ea\:52d5\:5224\:5b9a\:3001\:901a\:5e38 CLI) *)
    effectiveModel = Which[
      ListQ[model] && Length[model] >= 2, model,
      NumericQ[privacyLevel] && privacyLevel > 0.5 &&
        ListQ[privModel] && Length[privModel] >= 2,
        privModel,
      True, Automatic
    ];

    response = Quiet @ ClaudeCode`ClaudeQuerySync[prompt,
      ClaudeCode`Model -> effectiveModel];
    (* Stage 9 P1 Step 9: \:30a8\:30e9\:30fc\:6587\:5b57\:5217\:691c\:51fa\:3002
       ClaudeQuerySync \:306f LM Studio \:306e HTTP 500 \:306a\:3069\:306e\:969b\:3001
       \:30a8\:30e9\:30fc\:672c\:6587 ("Error: LM Studio /api/... StatusCode=500 ...")
       \:3092\:6b63\:5e38\:306a\:6587\:5b57\:5217\:5fdc\:7b54\:3068\:3057\:3066\:8fd4\:3059\:3053\:3068\:304c\:3042\:308b\:3002
       \:3053\:308c\:3092\:305d\:306e\:307e\:307e\:8981\:7d04\:3068\:3057\:3066\:4fdd\:5b58\:3057\:306a\:3044\:3088\:3046\:3001
       StringQ \:3060\:3051\:3067\:306a\:304f\:5185\:5bb9\:3082\:691c\:67fb\:3057\:3066 Failed \:306b\:843d\:3068\:3059\:3002 *)
    If[StringQ[response] && iSVLooksLikeLLMError[response],
      Return[<|"Status" -> "Failed",
        "Reason" -> "LLMReturnedErrorText",
        "RawResponse" -> response,
        "ResolvedModel" -> effectiveModel|>]];
    If[StringQ[response] && StringLength[StringTrim[response]] === 0,
      Return[<|"Status" -> "Failed",
        "Reason" -> "LLMReturnedEmptyText",
        "ResolvedModel" -> effectiveModel|>]];
    If[StringQ[response],
      <|"Status" -> "OK", "Response" -> response,
        "ResolvedModel" -> effectiveModel|>,
      <|"Status" -> "Failed", "Reason" -> "LLMQueryFailed",
        "RawResponse" -> response,
        "ResolvedModel" -> effectiveModel|>]
  ];

(* ClaudeQuerySync \:304c\:8fd4\:3057\:305f\:6587\:5b57\:5217\:304c\:3001\:6b63\:5e38\:306a\:8981\:7d04\:5fdc\:7b54\:3067\:306f\:306a\:304f
   LLM \:30d0\:30c3\:30af\:30a8\:30f3\:30c9\:30fb\:30b5\:30fc\:30d0\:306e\:30a8\:30e9\:30fc\:672c\:6587\:3067\:3042\:308b\:53ef\:80fd\:6027\:3092\:5224\:5b9a\:3002
   \:8981\:7d04\:30c6\:30ad\:30b9\:30c8\:306f\:901a\:5e38\:6570\:767e\:6587\:5b57\:306e\:6587\:7ae0\:306a\:306e\:3067\:3001\:5148\:982d\:8fd1\:304f\:306b
   "Error:" / StatusCode / JSON \:5f62\:5f0f\:306e error \:30aa\:30d6\:30b8\:30a7\:30af\:30c8\:7b49\:304c\:3042\:308c\:3070
   \:30a8\:30e9\:30fc\:3068\:307f\:306a\:3059\:3002\:8aa4\:691c\:51fa\:3092\:907f\:3051\:308b\:305f\:3081\:5148\:982d 200 \:6587\:5b57\:306e\:307f\:3092\:898b\:308b\:3002 *)
iSVLooksLikeLLMError[s_String] :=
  Module[{head},
    head = StringTake[s, UpTo[200]];
    Or[
      StringStartsQ[StringTrim[head], "Error:"],
      StringStartsQ[StringTrim[head], "Error "],
      StringContainsQ[head, "StatusCode=" ~~ DigitCharacter ..],
      StringContainsQ[head,
        RegularExpression["\"error\"\\s*:\\s*\\{"]],
      StringContainsQ[head, "Model unloaded"],
      StringContainsQ[head, "internal_error"]
    ]
  ];
iSVLooksLikeLLMError[_] := False;

(* === Public API: SourceVaultNotebookSummary === *)

Options[SourceVaultNotebookSummary] = {
  "ForceRefresh" -> False,
  "MaxLength" -> 500,
  "Language" -> Automatic,
  "Model" -> Automatic,
  "PrivacyLevel" -> 1.0,
  "FallbackToCloud" -> "Ask"     (* Step 3: \"Ask\" | \"Allow\" | \"Deny\" *)
};

SourceVaultNotebookSummary[path_String, opts:OptionsPattern[]] :=
  Module[{abs, forceRefresh, maxLength, language, model, privacyLevel,
          fallback, statusResult, existingRec, header, todos, lint,
          prompt, llmResult, summaryText, generatedBy, modelString,
          registerResult},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[<|"Status" -> "Failed", "Reason" -> "FileNotFound",
        "Path" -> abs|>]];
    (* Stage 9 P1 ext: refuse summary generation for a notebook
       explicitly declared NOT cloud-publishable. The summary is, by
       design, schema-level info that may reach cloud services, so a
       deny-declared notebook must not get one at all. *)
    If[Quiet @ Check[NBAccess`NBGetCloudPublishable[abs],
         Missing["ReadFailed"]] === False,
      Return[<|"Status" -> "Refused",
        "Reason" -> "CloudPublishDenied",
        "Path" -> abs,
        "Detail" -> "This notebook is marked Private (CloudPublishable=False); summary generation is skipped."|>]];
    forceRefresh = OptionValue["ForceRefresh"];
    maxLength = OptionValue["MaxLength"];
    language = OptionValue["Language"];
    model = OptionValue["Model"];
    privacyLevel = OptionValue["PrivacyLevel"];
    fallback = OptionValue["FallbackToCloud"];

    (* \:65e2\:5b58 summary \:304c Current \:304b\:3064 ForceRefresh \:7121\:3057\:306a\:3089\:65e2\:5b58\:3092\:8fd4\:3059 *)
    If[forceRefresh =!= True,
      statusResult = SourceVaultNotebookSummaryStatus[abs];
      If[AssociationQ[statusResult] &&
          Lookup[statusResult, "Status", ""] === "Current",
        existingRec = SourceVaultGetNotebookSummary[abs];
        If[AssociationQ[existingRec] &&
            Lookup[existingRec, "Status", ""] === "OK",
          Return[Join[existingRec, <|"Cached" -> True|>]]]]];

    (* notebook \:306e header / todo / lint \:3092\:53d6\:5f97 *)
    header = SourceVaultExtractNotebookHeader[abs];
    todos = SourceVaultExtractNotebookTodos[abs];
    lint = SourceVaultNotebookLint[abs];

    (* prompt \:69cb\:7bc9 + LLM \:547c\:3073\:51fa\:3057 (Step 3: fallback \:5bfe\:5fdc\:7248) *)
    prompt = iBuildNotebookSummaryPrompt[abs, header, todos, lint,
      maxLength, language];
    llmResult = iCallSummaryLLMWithFallback[prompt, model, privacyLevel,
      abs, fallback];

    (* Inconsistent \:30b9\:30c6\:30fc\:30bf\:30b9 (Step 3) *)
    If[Lookup[llmResult, "Status", ""] === "Inconsistent",
      Return[Join[llmResult, <|"Path" -> abs|>]]];

    If[Lookup[llmResult, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Failed",
        "Reason" -> Lookup[llmResult, "Reason", "LLMFailed"],
        "Path" -> abs,
        "LLMResult" -> llmResult|>]];

    summaryText = StringTrim @ Lookup[llmResult, "Response", ""];
    If[!StringQ[summaryText] || StringLength[summaryText] === 0,
      Return[<|"Status" -> "Failed",
        "Reason" -> "EmptyLLMResponse",
        "Path" -> abs|>]];

    (* Stage 9 P1 Step 6: \:6982\:8981\:306e\:30b9\:30ad\:30fc\:30de\:9069\:5408\:6027\:691c\:8a3c\:3002
       \:500b\:4eba\:60c5\:5831\:30fb\:9023\:7d61\:5148\:30fb\:8a8d\:8a3c\:60c5\:5831\:304c\:6df7\:5165\:3057\:3066\:3044\:305f\:3089\:6982\:8981\:3092\:7834\:68c4\:3002
       \:6982\:8981\:306f\:5b9a\:7fa9\:4e0a\:30af\:30e9\:30a6\:30c9\:6295\:5165\:53ef\:80fd\:306a\:30b9\:30ad\:30fc\:30de\:60c5\:5831\:3067\:306a\:3051\:308c\:3070\:306a\:3089\:306a\:3044\:3002 *)
    Module[{schemaCheck},
      schemaCheck = iSVValidateSummarySchema[summaryText];
      If[!TrueQ[Lookup[schemaCheck, "Valid", False]],
        Return[<|"Status" -> "SchemaViolation",
          "Reason" -> "SummaryContainsPrivateInfo",
          "Violations" -> Lookup[schemaCheck, "Violations", {}],
          "Path" -> abs,
          "Detail" ->
            "\:751f\:6210\:3055\:308c\:305f\:6982\:8981\:306b\:500b\:4eba\:60c5\:5831\:307e\:305f\:306f\:6a5f\:5bc6\:60c5\:5831\:304c\:6df7\:5165\:3057\:305f\:305f\:3081\:7834\:68c4\:3057\:307e\:3057\:305f\:3002"|>]]];

    (* GeneratedBy \:3092\:30e2\:30c7\:30eb\:60c5\:5831\:3067\:69cb\:7bc9 *)
    modelString = Which[
      ListQ[model] && Length[model] === 2,
        "claude-" <> ToString[model[[1]]] <> "/" <> ToString[model[[2]]],
      model === Automatic && privacyLevel === 1.0,
        "claude-local-private",
      model === Automatic,
        "claude-automatic",
      True, "claude-" <> ToString[model]
    ];
    generatedBy = modelString;

    (* Step 4 \:306e Register \:7d4c\:7531\:3067\:4fdd\:5b58 (lifecycle \:7ba1\:7406\:306b\:81ea\:52d5\:3067\:4e57\:308b) *)
    registerResult = SourceVaultRegisterNotebookSummary[abs, summaryText,
      "SummaryFormat" -> "text",
      "GeneratedBy" -> generatedBy];

    If[AssociationQ[registerResult] &&
        Lookup[registerResult, "Status", ""] === "OK",
      Join[registerResult, <|"Summary" -> summaryText,
        "Cached" -> False,
        "PromptLength" -> StringLength[prompt],
        "ResolvedModel" -> Lookup[llmResult, "ResolvedModel",
          Missing["NotPresent"]]|>],
      <|"Status" -> "Failed",
        "Reason" -> "RegisterFailed",
        "RegisterResult" -> registerResult|>]
  ];


(* ============================================================
   Stage 9 Phase 2 (P1) Step 3: SourceVaultUpcomingSchedule
   ------------------------------------------------------------
   \:300c\:4eca\:65e5\:304b\:3089 N \:65e5\:4ee5\:5185\:300d\:306b Deadline / NextReview \:304c\:5165\:308b notebook \:3092 Dataset \:3067\:8fd4\:3059\:3002
   \:6982\:8981\:3082\:30ad\:30e3\:30c3\:30b7\:30e5\:304b\:3089\:53d6\:308a\:8fbc\:3080\:3001\:7121\:3051\:308c\:3070 SourceVaultNotebookSummary \:3092\:81ea\:52d5\:547c\:3073\:51fa\:3057\:3002
   FallbackToCloud \:30aa\:30d7\:30b7\:30e7\:30f3\:3067\:30ed\:30fc\:30ab\:30eb LLM \:4e0d\:5728\:6642\:306e\:632f\:308b\:821e\:3044\:3092\:5236\:5fa1\:3002
   ============================================================ *)

(* Scope \:6587\:5b57\:5217\:307e\:305f\:306f\:30d1\:30b9\:3092\:5b9f\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:306b\:89e3\:6c7a *)
(* Resolve $SourceVaultDefaultNotebookFolder to a concrete directory string.
   Automatic / non-directory -> Global`$onWork -> $packageDirectory. *)
iSVDefaultNotebookFolder[] :=
  Module[{f, v},
    f = $SourceVaultDefaultNotebookFolder;
    If[StringQ[f] && DirectoryQ[f], Return[f]];
    v = Quiet @ Symbol["Global`$onWork"];
    If[StringQ[v] && DirectoryQ[v], Return[v]];
    v = iPackageDir[];
    If[StringQ[v] && DirectoryQ[v], Return[v]];
    $Failed
  ];

iSVResolveScope[scope_] :=
  Module[{val},
    Which[
      scope === Automatic || scope === None,
        val = iSVDefaultNotebookFolder[];
        If[StringQ[val] && DirectoryQ[val], val,
          Quiet @ Symbol["Global`$packageDirectory"]],
      StringQ[scope] && DirectoryQ[scope], scope,
      StringQ[scope] && StringStartsQ[scope, "$"],
        val = Quiet @ Symbol["Global`" <> StringDrop[scope, 1]];
        If[StringQ[val] && DirectoryQ[val], val, scope],
      True, scope
    ]
  ];

(* Quantity[N, "Days"] \:307e\:305f\:306f Integer \:3092\:65e5\:6570\:306b\:5909\:63db *)
iSVPeriodToDays[period_] :=
  Which[
    IntegerQ[period], period,
    Head[period] === Quantity,
      Quiet @ Check[
        Round @ QuantityMagnitude @ UnitConvert[period, "Days"],
        7],
    True, 7
  ];

(* Quantity[N, "Days" | "Weeks" | "Months" | ...] \:307e\:305f\:306f DateObject \:307e\:305f\:306f\:6587\:5b57\:5217\:3092
   DateObject (Day \:7cbe\:5ea6) \:306b\:6b63\:898f\:5316\:3059\:308b\:3002Quantity \:306e\:5834\:5408\:306f\:30d5\:30a1\:30a4\:30eb\:306e mtime \:306b\:52a0\:7b97\:3002 *)
iSVResolveReviewDate[value_, mtime_] :=
  Module[{baseDate, qty},
    Which[
      Head[value] === DateObject, value,
      StringQ[value],
        Quiet @ Check[DateObject[value, "Day"], Missing[]],
      Head[value] === Quantity,
        (* mtime + Quantity (\:30d5\:30a1\:30a4\:30eb\:306e mtime \:3092\:57fa\:6e96\:306b\:76f8\:5bfe\:6307\:5b9a) *)
        If[Head[mtime] === DateObject,
          baseDate = mtime,
          (* mtime \:7121\:3057\:306e\:5834\:5408\:306f\:4eca\:65e5\:3092\:57fa\:6e96\:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af *)
          baseDate = DateObject[Now, "Day"]];
        Quiet @ Check[
          DateObject[DatePlus[baseDate, value], "Day"],
          Missing[]],
      True, Missing[]
    ]
  ];

(* record \:304c upcoming \:6761\:4ef6\:306b\:30de\:30c3\:30c1\:3059\:308b\:304b\:5224\:5b9a *)
iSVUpcomingMatches[record_Association, today_, deadline_, includeOverdue_] :=
  Module[{header, path, mtime, dl, nr, dlDate, nrDate},
    header = Lookup[record, "Header", <||>];
    path = Lookup[record, "Path", Lookup[record, "OriginalPath", ""]];

    (* \:30d5\:30a1\:30a4\:30eb\:306e mtime \:3092 DateObject \:5316 (Quantity \:5024\:306e\:57fa\:6e96\:65e5\:7528) *)
    mtime = Which[
      StringQ[path] && FileExistsQ[path],
        Quiet @ Check[DateObject[FileDate[path], "Day"], Missing[]],
      True, Missing[]
    ];

    dl = Lookup[header, "Deadline", Missing[]];
    nr = Lookup[header, "NextReview", Missing[]];
    dlDate = iSVResolveReviewDate[dl, mtime];
    nrDate = iSVResolveReviewDate[nr, mtime];

    Or[
      (* Deadline \:304c\:671f\:9593\:5185 *)
      Head[dlDate] === DateObject &&
        Quiet @ Check[
          (dlDate >= today) && (dlDate <= deadline),
          False],
      (* NextReview \:304c\:671f\:9593\:5185 *)
      Head[nrDate] === DateObject &&
        Quiet @ Check[
          (nrDate >= today) && (nrDate <= deadline),
          False],
      (* IncludeOverdue: Deadline \:8d85\:904e *)
      TrueQ[includeOverdue] && Head[dlDate] === DateObject &&
        Quiet @ Check[dlDate < today, False],
      (* IncludeOverdue: NextReview \:8d85\:904e *)
      TrueQ[includeOverdue] && Head[nrDate] === DateObject &&
        Quiet @ Check[nrDate < today, False]
    ]
  ];

(* \:30ed\:30fc\:30ab\:30eb LLM \:4e0d\:5728\:6642\:306e\:78ba\:8a8d\:30c0\:30a4\:30a2\:30ed\:30b0 *)
iSVAskCloudFallback[path_String, localErr_] :=
  Module[{decision},
    decision = Quiet @ ChoiceDialog[
      Column[{
        Style["\:30ed\:30fc\:30ab\:30eb LLM \:304c\:5fdc\:7b54\:3057\:307e\:305b\:3093\:3067\:3057\:305f",
          Bold, RGBColor[0.7, 0.3, 0.1]],
        Spacer[6],
        Row[{"\:5bfe\:8c61: ", Style[FileBaseName[path], Italic]}],
        Row[{"\:7406\:7531: ",
          Style[ToString[Lookup[localErr, "Reason", "?"]], 10]}],
        Spacer[6],
        "\:3053\:306e\:30ce\:30fc\:30c8\:306f\:30af\:30e9\:30a6\:30c9\:516c\:958b\:8a31\:53ef\:6e08\:307f\:3067\:3059\:3002\:30af\:30e9\:30a6\:30c9 LLM \:3067\:8981\:7d04\:3057\:307e\:3059\:304b?",
        "(\:30ad\:30e3\:30f3\:30bb\:30eb\:6642\:306f\:300cInconsistent\:300d\:30b9\:30c6\:30fc\:30bf\:30b9\:3067\:7d50\:679c\:3092\:6b8b\:3057\:307e\:3059)"
      }],
      {"\:30af\:30e9\:30a6\:30c9\:3067\:8981\:7d04" -> True,
       "\:30ad\:30e3\:30f3\:30bb\:30eb" -> False}];
    TrueQ[decision]
  ];

(* iCallSummaryLLM \:306e fallback \:5bfe\:5fdc\:7248\:3002
   - PrivacyLevel \:304c\:30af\:30e9\:30a6\:30c9\:7981\:6b62 (1.0) \:306a\:3089\:30ed\:30fc\:30ab\:30eb\:306e\:307f\:3067\:8a66\:884c
   - PrivacyLevel \:30af\:30e9\:30a6\:30c9\:53ef (0.5 \:307e\:305f\:306f\:6df7\:5728) \:306a\:3089\:3001
       (a) \:307e\:305a\:30ed\:30fc\:30ab\:30eb\:3067\:8a66\:3057\:3001
       (b) \:5931\:6557\:6642\:306f fallback \:30e2\:30fc\:30c9\:306b\:5f93\:3063\:3066\:30af\:30e9\:30a6\:30c9\:3092\:8a66\:884c\:3002
   Inconsistent \:30b9\:30c6\:30fc\:30bf\:30b9 (\:30ed\:30fc\:30ab\:30eb\:5931\:6557\:30fb\:30af\:30e9\:30a6\:30c9\:62d2\:5426) \:3082\:8fd4\:308a\:5024\:3068\:3059\:308b\:3002 *)
iCallSummaryLLMWithFallback[prompt_String, model_, privacyLevel_,
    path_String, fallback_String] :=
  Module[{routes, localResult, cloudOk, cloudResult, fileSpec},

    (* \:30d5\:30a1\:30a4\:30eb\:306e PrivacyLevel \:3092 NBAccess \:304b\:3089\:53d6\:308a\:5bc4\:305b *)
    fileSpec = Quiet @ Check[NBAccess`NBFileSpec[path], <||>];
    routes = Quiet @ Check[
      NBAccess`NBPrivacyLevelToRoutes[
        Lookup[fileSpec, "PrivacyLevel", privacyLevel]],
      {"local"}];
    If[!ListQ[routes], routes = {"local"}];

    (* \:30af\:30e9\:30a6\:30c9\:4e0d\:53ef\:30d5\:30a1\:30a4\:30eb\:306f\:30ed\:30fc\:30ab\:30eb\:306e\:307f *)
    If[FreeQ[routes, "cloud"],
      Return[iCallSummaryLLM[prompt, model, 1.0]]];

    (* (a) \:307e\:305a\:30ed\:30fc\:30ab\:30eb\:3067\:8a66\:884c (privacyLevel \:3092 1.0 \:6271\:3044\:306b\:3057\:3066 $ClaudePrivateModel \:7d4c\:7531) *)
    localResult = iCallSummaryLLM[prompt, model, 1.0];
    If[Lookup[localResult, "Status", ""] === "OK", Return[localResult]];

    (* (b) \:30ed\:30fc\:30ab\:30eb\:304c\:5931\:6557 \[DoubleRightArrow] \:5224\:5b9a\:5f8c\:30af\:30e9\:30a6\:30c9 *)
    cloudOk = Switch[fallback,
      "Allow", True,
      "Deny",  False,
      _,       iSVAskCloudFallback[path, localResult]   (* "Ask" \:306f\:30c0\:30a4\:30a2\:30ed\:30b0 *)
    ];

    If[!TrueQ[cloudOk],
      Return[<|"Status" -> "Inconsistent",
        "Reason" -> "LocalLLMUnavailableAndCloudDeclined",
        "LocalResult" -> localResult,
        "Path" -> path|>]];

    (* \:30af\:30e9\:30a6\:30c9\:3067\:8a66\:884c (privacyLevel \:3092 0.5 \:306b\:3057\:3066 $ClaudePrivateModel \:3092\:30b9\:30ad\:30c3\:30d7) *)
    cloudResult = iCallSummaryLLM[prompt, model, 0.5];
    If[Lookup[cloudResult, "Status", ""] === "OK",
      Return[cloudResult]];

    (* \:30af\:30e9\:30a6\:30c9\:3082\:5931\:6557 \[DoubleRightArrow] Inconsistent *)
    <|"Status" -> "Inconsistent",
      "Reason" -> "BothLocalAndCloudFailed",
      "LocalResult" -> localResult,
      "CloudResult" -> cloudResult,
      "Path" -> path|>
  ];


(* === Public API: SourceVaultUpcomingSchedule === *)

Options[SourceVaultUpcomingSchedule] = {
  "Scope" -> Automatic,
  "Period" -> Quantity[7, "Days"],
  "IncludeOverdue" -> True,
  "Recursive" -> True,
  "Refresh" -> "Never",              (* Stage 9 P1.5: \:8868\:793a\:6642\:306b LLM \:3092\:547c\:3070\:306a\:3044 (\:65e2\:5b9a)\:3002
                                        "Never" | "IfStale" | "Force"\:3002
                                        \:5f31\:3044\:30ed\:30fc\:30ab\:30eb LLM \:74b0\:5883\:3067\:306f\:8868\:793a\:304c\:91cd\:304f\:306a\:3089\:306a\:3044\:3088\:3046 Never \:65e2\:5b9a\:3002
                                        Summary \:7121\:3057\:30ce\:30fc\:30c8\:306f Keywords \:30c4\:30fc\:30eb\:30c1\:30c3\:30d7\:306b fallback\:3002
                                        \:751f\:6210\:306f SourceVaultRefreshAllSummaries \:3067\:884c\:3046\:3002 *)
  "FallbackToCloud" -> "Ask",        (* "Ask" | "Allow" | "Deny" *)
  "StatusFilter" -> {"Todo"},         (* {"Todo"} | {"Todo","Done","Pass"} | All *)
  "UseCache" -> True,                  (* in-memory cache for repeat calls *)

  (* PromptRouter / notebook management extension (spec v11 6.1) *)
  "OpenTodos" -> Missing[],            (* True | False | Missing[] *)
  "DateField" -> "Both",               (* "Both" | "Deadline" | "NextReview" *)
  "FilterSpec" -> Missing[],           (* structured predicate Association, spec 5.4.2 *)
  "OutputFormat" -> "Dataset"          (* "Dataset" | "Rows" | "Records" *)
};

(* In-memory cache for records\:3002
   Hotfix 3.2: \:30d5\:30a1\:30a4\:30eb\:5358\:4f4d\:306e\:5dee\:5206\:66f4\:65b0\:30ad\:30e3\:30c3\:30b7\:30e5\:3002
   \:65e7\:7248 (Hotfix 3.1) \:306f\:300c\:5168\:30d5\:30a1\:30a4\:30eb\:306e mtime \:304c\:5b8c\:5168\:4e00\:81f4\:3057\:305f\:3089\:5168 records \:518d\:5229\:7528\:300d
   \:3068\:3044\:3046\:30aa\:30fc\:30eb\:30fb\:30aa\:30a2\:30fb\:30ca\:30c3\:30b7\:30f3\:30b0\:3060\:3063\:305f\:305f\:3081\:30011 \:30d5\:30a1\:30a4\:30eb\:5909\:308f\:308b\:3060\:3051\:3067\:5168\:4ef6\:518d index\:3002
   \:65b0\:7248\:306f\:30d5\:30a1\:30a4\:30eb\:6bce\:306b mtime \:3092\:898b\:3066\:3001\:5909\:66f4\:7121\:3057\:30d5\:30a1\:30a4\:30eb\:306f
   SourceVaultIndexNotebook \:3092\:547c\:3070\:305a\:30ad\:30e3\:30c3\:30b7\:30e5\:306e record \:3092\:518d\:5229\:7528\:3059\:308b\:3002 *)
If[!ValueQ[$iSVIndexCache], $iSVIndexCache = <||>];
If[!ValueQ[$iSVLastCacheStats], $iSVLastCacheStats = <||>];

(* records \:3092\:30d5\:30a1\:30a4\:30eb\:5358\:4f4d\:5dee\:5206\:66f4\:65b0\:3067\:53d6\:5f97\:3002
   $iSVIndexCache[cacheKey] = <|path -> <|"mtime" -> _, "record" -> _|>, ...|>
   \:5909\:66f4\:7121\:3057\:30d5\:30a1\:30a4\:30eb \[Rule] \:30ad\:30e3\:30c3\:30b7\:30e5\:306e record \:3092\:518d\:5229\:7528 (Import \:3057\:306a\:3044)
   \:5909\:66f4 / \:65b0\:898f \[Rule] \:305d\:306e\:30d5\:30a1\:30a4\:30eb\:3060\:3051 SourceVaultIndexNotebook \:3067\:518d\:53d6\:5f97
   \:6d88\:3048\:305f\:30d5\:30a1\:30a4\:30eb \[Rule] \:30ad\:30e3\:30c3\:30b7\:30e5\:304b\:3089\:9664\:5916 *)
(* record \:304b\:3089 UpcomingSchedule \:304c\:5b9f\:969b\:306b\:4f7f\:3046\:30d5\:30a3\:30fc\:30eb\:30c9\:3060\:3051\:3092\:62bd\:51fa\:3057\:305f
   \:8efd\:91cf\:30ec\:30b3\:30fc\:30c9\:3092\:8fd4\:3059\:3002Todo \:4e00\:89a7\:672c\:4f53\:30fbLint\:30fbCell \:60c5\:5831\:7b49\:306f\:6368\:3066\:3001
   \:30e1\:30e2\:30ea\:6d88\:8cbb\:3092\:5927\:5e45\:306b\:524a\:6e1b\:3059\:308b (228 \:4ef6\:30d5\:30eb index \:3067\:306e\:30e1\:30e2\:30ea\:67af\:6e07\:5bfe\:7b56)\:3002 *)
iSVLightRecord[rec_] :=
  If[!AssociationQ[rec], rec,
    <|
      "Status" -> Lookup[rec, "Status", ""],
      "Path" -> Lookup[rec, "Path", Lookup[rec, "OriginalPath", ""]],
      "NotebookRef" -> Lookup[rec, "NotebookRef", Missing[]],
      "Title" -> Lookup[rec, "Title", Missing[]],
      "Header" -> Module[{h = Lookup[rec, "Header", <||>]},
        If[AssociationQ[h],
          KeyTake[h, {"Deadline", "NextReview", "Keywords",
            "Status", "Title"}],
          <||>]],
      "OpenTodoCount" -> Lookup[rec, "OpenTodoCount", 0],
      "DoneTodoCount" -> Lookup[rec, "DoneTodoCount", 0],
      "PassTodoCount" -> Lookup[rec, "PassTodoCount", 0],
      "TodoCount" -> Lookup[rec, "TodoCount", 0]
    |>
  ];

iSVGetCachedRecords[root_String, recursive_, useCache_] :=
  Module[{cacheKey, cached, files, fileSet, perFile,
          reused, reindexed, records, n, i},
    cacheKey = root <> "|" <> ToString[recursive];

    (* \:30d5\:30a1\:30a4\:30eb\:4e00\:89a7 (\:8efd\:91cf) *)
    files = If[recursive,
      FileNames["*.nb", root, Infinity],
      FileNames["*.nb", root]];
    files = Select[files, !StringContainsQ[FileBaseName[#], ".tmp-"] &];
    fileSet = files;
    n = Length[fileSet];

    (* useCache=False \:306a\:3089\:5168\:4ef6\:518d index *)
    cached = If[useCache && KeyExistsQ[$iSVIndexCache, cacheKey],
      $iSVIndexCache[cacheKey], <||>];
    If[!AssociationQ[cached], cached = <||>];

    (* \:30d5\:30a1\:30a4\:30eb\:6bce\:306b\:9010\:6b21\:51e6\:7406\:3002
       Step 8 \:4fee\:6b63: \:5168\:4ef6\:306e record \:5168\:4f53\:3092\:30e1\:30e2\:30ea\:306b\:7a4d\:307e\:305a\:3001
       iSVLightRecord \:3067\:5fc5\:8981\:30d5\:30a3\:30fc\:30eb\:30c9\:306e\:307f\:62bd\:51fa\:3057\:3066\:4fdd\:6301\:3059\:308b\:3002
       \:3055\:3089\:306b\:4e00\:5b9a\:4ef6\:6570\:3054\:3068\:306b\:30b7\:30b9\:30c6\:30e0\:30ad\:30e3\:30c3\:30b7\:30e5\:3092\:89e3\:653e\:3002 *)
    perFile = Association @ MapIndexed[
      Function[{path, idxList},
        Module[{curMtime, cachedEntry, rec, light},
          curMtime = Quiet @ Check[UnixTime[FileDate[path]], 0];
          cachedEntry = Lookup[cached, path, Missing[]];
          i = First[idxList];
          (* \:5b9a\:671f\:7684\:306b NotebookImport \:7531\:6765\:306e\:30e1\:30e2\:30ea\:3092\:89e3\:653e *)
          If[Mod[i, 25] === 0, ClearSystemCache["Notebooks"]];
          If[AssociationQ[cachedEntry] &&
              Lookup[cachedEntry, "mtime", Missing[]] === curMtime,
            (* \:5909\:66f4\:7121\:3057 \[Rule] \:8efd\:91cf\:30ad\:30e3\:30c3\:30b7\:30e5\:306e record \:3092\:518d\:5229\:7528 *)
            path -> Append[cachedEntry, "reused" -> True],
            (* \:5909\:66f4 / \:65b0\:898f \[Rule] \:305d\:306e\:30d5\:30a1\:30a4\:30eb\:3060\:3051\:518d index\:3001
               \:7d50\:679c\:306f\:8efd\:91cf\:5316\:3057\:3066\:304b\:3089\:4fdd\:6301 (record \:5168\:4f53\:306f\:6368\:3066\:308b) *)
            rec = Quiet @ SourceVaultIndexNotebook[path];
            light = iSVLightRecord[rec];
            rec =.;   (* record \:5168\:4f53\:3092\:5373\:5ea7\:306b\:89e3\:653e *)
            path -> <|"mtime" -> curMtime, "record" -> light,
              "reused" -> False|>
          ]]],
      fileSet];

    (* \:8a3a\:65ad\:7d71\:8a08\:3092\:8a18\:9332 *)
    reused = Count[Values[perFile], e_ /; TrueQ[Lookup[e, "reused", False]]];
    reindexed = Length[perFile] - reused;
    $iSVLastCacheStats = <|
      "Root" -> root,
      "TotalFiles" -> Length[perFile],
      "Reused" -> reused,
      "Reindexed" -> reindexed,
      "Timestamp" -> AbsoluteTime[]|>;

    (* \:30ad\:30e3\:30c3\:30b7\:30e5\:66f4\:65b0 (\:8efd\:91cf\:30ec\:30b3\:30fc\:30c9\:306e\:307f\:3001reused \:30d5\:30e9\:30b0\:306f\:9664\:304f) *)
    If[useCache,
      $iSVIndexCache[cacheKey] = Map[KeyDrop[#, "reused"] &, perFile]];

    (* record (\:8efd\:91cf\:7248) \:306e\:307f\:62bd\:51fa\:3057\:3001Status OK \:306e\:3082\:306e\:306b\:7d5e\:308b *)
    records = Select[
      Map[Lookup[#, "record", $Failed] &, Values[perFile]],
      AssociationQ[#] && Lookup[#, "Status", ""] === "OK" &];

    ClearSystemCache["Notebooks"];
    records
  ];

SourceVaultUpcomingSchedule[opts:OptionsPattern[]] :=
  Module[{root, periodDays, today, deadline, includeOverdue, recursive,
          refresh, fallback, statusFilter, useCache,
          openTodosOpt, dateFieldOpt, filterSpecOpt, outputFmt,
          records, filtered, statusFiltered, normalRecords,
          todoFiltered, dateFiltered, specFiltered},
    root = iSVResolveScope[OptionValue["Scope"]];
    If[!StringQ[root] || !DirectoryQ[root],
      Return[<|"Status" -> "Failed", "Reason" -> "ScopeNotFound",
        "Scope" -> root|>]];

    periodDays = iSVPeriodToDays[OptionValue["Period"]];
    today = DateObject[Now, "Day"];
    deadline = DatePlus[today, {periodDays, "Day"}];
    includeOverdue = TrueQ[OptionValue["IncludeOverdue"]];
    recursive = TrueQ[OptionValue["Recursive"]];
    refresh = OptionValue["Refresh"];
    fallback = OptionValue["FallbackToCloud"];
    statusFilter = OptionValue["StatusFilter"];
    useCache = TrueQ[OptionValue["UseCache"]];
    openTodosOpt  = OptionValue["OpenTodos"];
    dateFieldOpt  = OptionValue["DateField"];
    filterSpecOpt = OptionValue["FilterSpec"];
    outputFmt     = OptionValue["OutputFormat"];

    (* (1) records \:53d6\:5f97 (\:30ad\:30e3\:30c3\:30b7\:30e5\:7d4c\:7531 \[Rule] mtime \:540c\:3058\:306a\:3089\:5373\:5e30) *)
    records = iSVGetCachedRecords[root, recursive, useCache];

    (* (2) Period / Overdue \:30d5\:30a3\:30eb\:30bf *)
    filtered = Select[records,
      iSVUpcomingMatches[#, today, deadline, includeOverdue] &];

    (* (3) StatusFilter \:30d5\:30a3\:30eb\:30bf *)
    statusFiltered = Which[
      statusFilter === All || statusFilter === {}, filtered,
      ListQ[statusFilter],
        Select[filtered,
          MemberQ[statusFilter, iSVStatusFromRecord[#]] &],
      True, filtered
    ];

    (* (4) OpenTodos filter (spec 6.1): records with / without
       open-todo cells. This is distinct from StatusFilter,
       which looks at the header Status. *)
    todoFiltered = Which[
      openTodosOpt === True,
        Select[statusFiltered,
          Lookup[#, "OpenTodoCount", 0] > 0 &],
      openTodosOpt === False,
        Select[statusFiltered,
          Lookup[#, "OpenTodoCount", 0] === 0 &],
      True, statusFiltered];

    (* (5) DateField filter (spec 6.1): keep only records that
       carry the requested date field. "Both" keeps everything;
       the Period window itself was already applied in step (2). *)
    dateFiltered = Switch[dateFieldOpt,
      "Deadline",
        Select[todoFiltered,
          Head[iSVResolveReviewDate[
            Lookup[Lookup[#, "Header", <||>], "Deadline",
              Missing[]], iSVMTimeOf[Lookup[#, "Path",
                Lookup[#, "OriginalPath", ""]]]]] ===
            DateObject &],
      "NextReview",
        Select[todoFiltered,
          Head[iSVResolveReviewDate[
            Lookup[Lookup[#, "Header", <||>], "NextReview",
              Missing[]], iSVMTimeOf[Lookup[#, "Path",
                Lookup[#, "OriginalPath", ""]]]]] ===
            DateObject &],
      _, todoFiltered];

    (* (6) FilterSpec (spec 5.4.2 / 5.4.3): a structured,
       closed-DSL predicate applied to the NORMALIZED records.
       An off-DSL FilterSpec yields a Failed result rather than
       a silently wrong list. *)
    normalRecords = iSVScheduleNormalRecords[dateFiltered];
    specFiltered = If[AssociationQ[filterSpecOpt],
      iSVApplyScheduleFilterSpec[normalRecords, filterSpecOpt],
      normalRecords];
    If[specFiltered === $Failed,
      Return[<|"Status" -> "Failed",
        "Reason" -> "InvalidFilterSpec",
        "Hint" -> "FilterSpec must be a closed-DSL predicate " <>
          "(Kind And/Or/Not/Field, whitelisted Op, schema " <>
          "field names only)."|>]];

    (* (7) OutputFormat (spec 6.1):
         "Dataset" (default) -- the existing decorated schedule
           Grid (Title links, tooltips, date styling);
         "Rows"    -- a Dataset of the normalized records;
         "Records" -- the raw normalized record list, Select-able.
       When a FilterSpec narrowed the set, the decorated Grid is
       rebuilt from just the surviving records. *)
    Switch[outputFmt,
      "Records",
        specFiltered,
      "Rows",
        Dataset[specFiltered],
      _,  (* "Dataset": decorated Grid *)
        If[AssociationQ[filterSpecOpt],
          (* rebuild the decorated Grid from the index records
             whose Path survived the FilterSpec *)
          iSVFormatScheduleDataset[
            Select[dateFiltered,
              MemberQ[
                Map[Lookup[#, "Path", ""] &, specFiltered],
                Lookup[#, "Path",
                  Lookup[#, "OriginalPath", ""]]] &],
            today, refresh, fallback, useCache],
          iSVFormatScheduleDataset[
            dateFiltered, today, refresh, fallback, useCache]]
    ]
  ];

(* record \:306b summary \:30d5\:30a3\:30fc\:30eb\:30c9\:3092\:8ffd\:52a0 *)
iSVEnsureSummary[record_Association, refresh_, fallback_] :=
  Module[{path, status, summary, needRebuild},
    path = Lookup[record, "Path", Lookup[record, "OriginalPath", ""]];
    If[!StringQ[path] || !FileExistsQ[path],
      Return[Append[record, "Summary" -> <|"Status" -> "Missing",
        "Reason" -> "PathNotFound"|>]]];

    status = Quiet @ SourceVaultNotebookSummaryStatus[path];
    needRebuild = Switch[refresh,
      "Never", False,
      "Force", True,
      _, (* "IfStale" *)
        !AssociationQ[status] ||
          Lookup[status, "Status", ""] =!= "Current"
    ];
    summary = If[needRebuild,
      Quiet @ SourceVaultNotebookSummary[path,
        "ForceRefresh" -> (refresh === "Force"),
        "FallbackToCloud" -> fallback],
      Quiet @ SourceVaultGetNotebookSummary[path]];
    Append[record, "Summary" -> summary]
  ];

(* summary \:3092\:77ed\:7e2e\:3057\:3066\:8868\:793a\:7528\:6587\:5b57\:5217\:306b\:3059\:308b *)
iSVSummaryShort[summary_, maxLen_:80] :=
  Module[{text, status},
    If[!AssociationQ[summary], Return[""]];
    status = Lookup[summary, "Status", ""];
    Which[
      status === "OK",
        text = Lookup[summary, "Summary", ""];
        If[StringQ[text] && StringLength[text] > maxLen,
          StringTake[text, maxLen] <> "\[Ellipsis]",
          ToString[text]],
      status === "Inconsistent", "(\:8981\:7d04\:4e0d\:6210\:7acb)",
      status === "Missing",      "(\:672a\:8981\:7d04)",
      True,                       "(\:5931\:6557)"
    ]
  ];

(* Stage 9 P1 Step 9: Keywords \:30bb\:30eb\:3002\:9577\:304f\:306a\:308b\:3068\:8868\:304c\:5d29\:308c\:308b\:305f\:3081\:3001
   \:5148\:982d\:6570\:8a9e\:306e\:307f\:8868\:793a\:3057\:3001\:5168\:30ad\:30fc\:30ef\:30fc\:30c9\:306f Tooltip \:3067\:30dd\:30c3\:30d7\:30a2\:30c3\:30d7\:3002
   keywords \:7a7a\:306e\:5834\:5408\:306f\:7a7a\:6587\:5b57\:5217 (Tooltip \:306a\:3057)\:3002
   \:6ce8: Step 9 \:5f8c\:534a\:3067 Keywords \:5217\:81ea\:4f53\:3092\:8868\:304b\:3089\:524a\:9664\:3057\:305f\:305f\:3081\:3001
   \:73fe\:5728\:3053\:306e\:30d8\:30eb\:30d1\:30fc\:306f\:672a\:4f7f\:7528\:3002\:5c06\:6765 Keywords \:3092\:5225\:5f62\:3067
   \:8868\:793a\:3059\:308b\:5834\:5408\:306b\:5099\:3048\:3066\:5b9a\:7fa9\:306f\:6b8b\:3057\:3066\:3042\:308b\:3002
   Keywords \:306f\:73fe\:5728 Title \:30c4\:30fc\:30eb\:30c1\:30c3\:30d7 (iSVTitleTipBody \:7d4c\:7531) \:306b
   Summary \:304c\:7121\:3044\:5834\:5408\:306e\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3068\:3057\:3066\:8868\:793a\:3055\:308c\:308b\:3002 *)
iSVKeywordsCell[keywords_] :=
  Module[{kws, shown, hidden, label},
    kws = If[ListQ[keywords],
      Select[keywords, StringQ[#] && StringTrim[#] =!= "" &], {}];
    If[kws === {}, Return[""]];
    (* \:8868\:793a\:306f\:5148\:982d 2 \:8a9e\:307e\:3067 + \:6b8b\:308a\:4ef6\:6570 *)
    shown = Take[kws, UpTo[2]];
    hidden = Length[kws] - Length[shown];
    label = StringRiffle[shown, ", "] <>
      If[hidden > 0, " +" <> ToString[hidden], ""];
    Tooltip[
      Style[label, FontFamily -> iSVStandardFont[]],
      Column[
        Style[#, FontFamily -> iSVStandardFont[]] & /@ kws]]
  ];
iSVKeywordsCell[_] := "";

(* Stage 9 P1 Step 9: Summary \:30bb\:30eb\:3002\:8981\:7d04\:304c\:3042\:308c\:3070\:77ed\:7e2e\:8868\:793a\:3057\:3001
   \:5168\:6587\:3092 Tooltip \:3067\:30dd\:30c3\:30d7\:30a2\:30c3\:30d7\:3002\:8981\:7d04\:7121\:3057 ((\:672a\:8981\:7d04) \:7b49) \:306f
   \:305d\:306e\:30e9\:30d9\:30eb\:3092 Tooltip \:306a\:3057\:3067\:8868\:793a\:3059\:308b\:3002
   \:6ce8: Step 9 \:5f8c\:534a\:3067 Summary \:5217\:81ea\:4f53\:3092\:8868\:304b\:3089\:524a\:9664\:3057\:305f\:305f\:3081\:3001
   \:73fe\:5728\:3053\:306e\:30d8\:30eb\:30d1\:30fc\:306f\:672a\:4f7f\:7528\:3002Summary \:306f\:73fe\:5728 Title \:30c4\:30fc\:30eb\:30c1\:30c3\:30d7
   (iSVTitleTipBody \:7d4c\:7531) \:306b\:8868\:793a\:3055\:308c\:308b\:3002\:5c06\:6765 Summary \:3092\:5225\:5f62\:3067
   \:8868\:793a\:3059\:308b\:5834\:5408\:306b\:5099\:3048\:3066\:5b9a\:7fa9\:306f\:6b8b\:3057\:3066\:3042\:308b\:3002 *)
iSVSummaryCell[summary_] :=
  Module[{status, full, short},
    If[!AssociationQ[summary],
      Return[Style["", FontFamily -> iSVStandardFont[]]]];
    status = Lookup[summary, "Status", ""];
    If[status =!= "OK",
      Return[Style[iSVSummaryShort[summary],
        FontFamily -> iSVStandardFont[], GrayLevel[0.5]]]];
    full = Lookup[summary, "Summary", ""];
    If[!StringQ[full] || StringTrim[full] === "",
      Return[Style["(\:672a\:8981\:7d04)",
        FontFamily -> iSVStandardFont[], GrayLevel[0.5]]]];
    short = If[StringLength[full] > 40,
      StringTake[full, 38] <> "\[Ellipsis]", full];
    Tooltip[
      Style[short, FontFamily -> iSVStandardFont[]],
      Pane[Style[full, FontFamily -> iSVStandardFont[]],
        ImageSize -> {UpTo[380], Automatic}]]
  ];
iSVSummaryCell[_] := Style["", FontFamily -> iSVStandardFont[]];

(* Stage 9 P1 Step 9: Title \:30c4\:30fc\:30eb\:30c1\:30c3\:30d7\:306e\:672c\:6587\:6587\:5b57\:5217\:3092\:7d44\:307f\:7acb\:3066\:308b\:3002
   - Summary \:304c\:3042\:308c\:3070 (Status=OK \:304b\:3064\:7a7a\:3067\:306a\:3044) \:8981\:7d04\:5168\:6587\:3092\:8fd4\:3059
   - \:7121\:3051\:308c\:3070 Keywords \:3092\:30ab\:30f3\:30de\:533a\:5207\:308a\:3067\:8fd4\:3059
   - \:3069\:3061\:3089\:3082\:7121\:3051\:308c\:3070\:7a7a\:6587\:5b57\:5217 (\:547c\:3073\:51fa\:3057\:5074\:3067\:30d1\:30b9\:540d\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af) *)
iSVTitleTipBody[summary_, keywords_] :=
  Module[{sumText, kws},
    sumText = If[AssociationQ[summary] &&
        Lookup[summary, "Status", ""] === "OK",
      Lookup[summary, "Summary", ""], ""];
    If[StringQ[sumText] && StringTrim[sumText] =!= "",
      Return[StringTrim[sumText]]];
    kws = If[ListQ[keywords],
      Select[keywords, StringQ[#] && StringTrim[#] =!= "" &], {}];
    If[kws =!= {},
      Return[StringRiffle[kws, ", "]]];
    ""
  ];

(* Stage 9 P1 Step 9 ext: Summary column cell.
   Receives the already-resolved status string (OK / Missing / Failed,
   computed by the caller exactly as the old Privacy column did) plus a
   tooltip body. Kept free of any in-function Association lookup so the
   displayed value cannot silently fall through to "?". *)
iSVScheduleSummaryCell[statusStr_, tip_] :=
  Module[{label, color},
    {label, color} = Switch[statusStr,
      "OK",      {"OK",      GrayLevel[0.2]},
      "Missing", {"Missing", GrayLevel[0.55]},
      "Failed",  {"Failed",  RGBColor[0.7, 0.15, 0.15]},
      _,         {ToString[statusStr], GrayLevel[0.55]}];
    If[StringQ[tip] && StringTrim[tip] =!= "",
      Tooltip[
        Style[label, FontFamily -> iSVStandardFont[], color],
        Pane[Style[tip, FontFamily -> iSVStandardFont[]],
          ImageSize -> {UpTo[380], Automatic}]],
      Style[label, FontFamily -> iSVStandardFont[], color]]
  ];

(* Stage 9 P1 Step 9 ext: Publishable column cell.
   Renders the notebook-level cloud-publish declaration read via
   NBAccess`NBGetCloudPublishable (True / False / Missing).
   Wording and colors are kept in sync with the palette
   (iCloudPaletteLabel / iCloudPaletteColor in claudecode.wl). *)
iSVPublishableCell[realPath_] :=
  Module[{state, label, color},
    state = If[StringQ[realPath] && FileExistsQ[realPath],
      Quiet @ Check[NBAccess`NBGetCloudPublishable[realPath],
        Missing["ReadFailed"]],
      Missing["NoPath"]];
    (* Stage 9 P1.5: \:8868\:793a\:6587\:5b57\:5217\:3092\:82f1\:5358\:8a9e\:306b\:7d71\:4e00\:3002\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306b
       \:7d44\:307f\:8fbc\:307e\:308c\:308b\:6587\:5b57\:5217\:306f\:8a00\:8a9e\:74b0\:5883 ($Language) \:306b\:4f9d\:5b58\:3057\:306a\:3044\:8868\:8a18\:306b\:3059\:308b\:3053\:3068\:3067
       \:5225\:74b0\:5883\:3078\:9001\:4ed8\:3057\:305f\:3068\:304d\:306e\:898b\:305f\:76ee\:306e\:30d6\:30ec\:3092\:9632\:3050\:3002\:5185\:90e8\:5024 (True/False/Missing) \:306f\:4e0d\:5909\:3002 *)
    {label, color} = Which[
      state === True,  {"Public",      RGBColor[0.25, 0.55, 0.75]},
      state === False, {"Private",     RGBColor[0.6, 0.4, 0.3]},
      True,            {"Unspecified", GrayLevel[0.55]}];
    Style[label, FontFamily -> iSVStandardFont[], color]
  ];

(* enriched records \:3092 Dataset \:5f62\:5f0f\:306b\:6574\:5f62 *)
(* ---- Step 3 Hotfix 3: styled date / open button helpers ---- *)

(* mtime \:3092 DateObject (Day) \:3067\:8fd4\:3059 *)
iSVMTimeOf[path_] :=
  If[StringQ[path] && FileExistsQ[path],
    Quiet @ Check[DateObject[FileDate[path], "Day"], Missing[]],
    Missing[]];

(* \:65e5\:4ed8\:5024\:3092 yyyy/mm/dd \:6587\:5b57\:5217 + \:8272\:4ed8\:3051\:3067 Style \:3059\:308b\:3002
   value: DateObject / String / Quantity / Missing
   mtime: \:30d5\:30a1\:30a4\:30eb\:306e mtime DateObject (Quantity \:89e3\:6c7a\:7528)
   \:8272: \:671f\:5207\:308c \[Rule] Red \:3001\:4eca\:65e5\:307e\:305f\:306f\:660e\:65e5 \[Rule] Blue \:3001\:305d\:308c\:4ee5\:5916 \[Rule] Black\:3002 *)
iSVStyledDate[value_, mtime_] :=
  Module[{absDate, today, datetime, str},
    absDate = iSVResolveReviewDate[value, mtime];
    If[Head[absDate] =!= DateObject, Return[""]];
    today = CurrentDate["Day"];
    datetime = DateObject[absDate, "Day"];
    str = DateString[datetime, {"Year", "/", "Month", "/", "Day"}];
    Style[str,
      Which[
        datetime < today, Red,
        datetime < DatePlus[today, {2, "Day"}], Blue,
        True, Black]]
  ];

(* Title \:30dc\:30bf\:30f3: \:30af\:30ea\:30c3\:30af\:3067 SystemOpen \:3057\:30ce\:30fc\:30c8\:3092\:958b\:304f
   ShowStringCharacters -> False \:3067\:5f15\:7528\:7b26\:3092\:62bc\:3055\:3048\:308b
   2026-05-31 fix: Style[..., "Hyperlink", FontFamily -> ...] \:306e\:5f62\:3067\:3001
   "Hyperlink" \:30b9\:30bf\:30a4\:30eb (\:8272\:30fb\:30b5\:30a4\:30ba\:30fb\:4e0b\:7dda) \:3092\:7d99\:627f\:3057\:3064\:3064 FontFamily \:3060\:3051\:3092\:5f8c\:7f6e\:3067\:4e0a\:66f8\:304d\:3059\:308b\:3002
   ("Hyperlink" \:3092 BaseStyle \:306b\:5165\:308c\:308b\:3068\:30c6\:30ad\:30b9\:30c8\:306e\:30d5\:30a9\:30f3\:30c8\:304c\:6238\:308b\:304c\:3001
    Style \:5185\:306e\:540c\:968e\:5c64\:3067\:6307\:5b9a\:3059\:308c\:3070\:5f8c\:52dd\:3061\:3067\:30d5\:30a9\:30f3\:30c8\:304c\:52b9\:304f\:3002) *)
iSVTitleButton[title_, path_] :=
  With[{ff = iSVStandardFont[]},
    If[StringQ[path] && FileExistsQ[path],
      Button[Style[title, "Hyperlink", FontFamily -> ff,
          ShowStringCharacters -> False],
        SystemOpen[path],
        Appearance -> "Frameless"],
      Style[title, FontFamily -> ff,
        ShowStringCharacters -> False]]];

(* Dir \:30dc\:30bf\:30f3: \:30af\:30ea\:30c3\:30af\:3067\:89aa\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:3092\:958b\:304f *)
iSVDirButton[path_] :=
  With[{ff = iSVStandardFont[]},
    If[StringQ[path] && FileExistsQ[path],
      Button[Style["\:958b\:304f", "Hyperlink", FontFamily -> ff,
          ShowStringCharacters -> False],
        SystemOpen[DirectoryName[path]],
        Appearance -> "Frameless"],
      ""]];

(* \:6b8b\:8ab2\:984c 1: \:30af\:30ed\:30b9 PC \:5bfe\:5fdc\:306e Title / Dir \:30dc\:30bf\:30f3\:3002
   symPath (iSVSymbolicPath \:306e\:623b\:308a List) \:3092 Button \:306b\:4fdd\:6301\:3057\:3001
   \:30af\:30ea\:30c3\:30af\:6642\:306b iSVResolvePath \:3067\:73fe PC \:306e\:7d76\:5bfe\:30d1\:30b9\:306b\:89e3\:6c7a\:3059\:308b\:3002
   \:540c\:4e00 PC \:306a\:3089 origPath \:306b\:623b\:308b round-trip\:3002
   \:5225 PC \:3067 Dataset \:3092\:518d\:8868\:793a\:3057\:3066\:3082 symPath \:304b\:3089\:6b63\:3057\:304f\:89e3\:6c7a\:3055\:308c\:308b\:3002
   \:6d3b\:6027\:5224\:5b9a (Button vs Style) \:306f\:751f\:6210 PC \:306e\:5b9f\:30d1\:30b9\:5b58\:5728\:3067\:884c\:3046\:3002
   \:8868\:793a\:90e8\:306f Pane \:3067\:56fa\:5b9a\:5e45\:5316\:3059\:308b\:3002Dataset \:306f Button \:3092\:542b\:3080\:30bb\:30eb\:306e
   \:5e45\:3092\:6e2c\:308c\:305a\:5217\:3092\:6975\:5c0f\:5316\:3057 "..." \:7701\:7565\:306b\:306a\:308b\:305f\:3081\:3001
   Pane \:3067\:6700\:5c0f\:5e45\:3092\:78ba\:4fdd\:3057 Title \:306b\:306f Tooltip \:3067\:30d5\:30eb\:30d1\:30b9\:3092\:6dfb\:3048\:308b\:3002 *)
(* Stage 9 P1 Step 9: Title \:30bb\:30eb\:3002
   \:30c4\:30fc\:30eb\:30c1\:30c3\:30d7\:306b\:306f title (\:592a\:5b57) \:306b\:52a0\:3048\:3066 tipBody \:3092\:8868\:793a\:3059\:308b\:3002
   tipBody \:306f\:547c\:3073\:51fa\:3057\:5074\:3067\:300cSummary \:304c\:3042\:308c\:3070 Summary\:3001
   \:7121\:3051\:308c\:3070 Keywords\:300d\:3068\:3057\:3066\:7d44\:307f\:7acb\:3066\:308b\:3002tipBody \:304c\:7a7a\:306e\:5834\:5408\:306f
   \:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3068\:3057\:3066\:30d1\:30b9\:540d\:3092\:8868\:793a\:3059\:308b\:3002 *)
(* Stage 9 P1 Step 9: Title \:30bb\:30eb\:3002
   \:30c4\:30fc\:30eb\:30c1\:30c3\:30d7\:306b\:306f title (\:592a\:5b57) \:306b\:52a0\:3048\:3066 tipBody \:3092\:8868\:793a\:3059\:308b\:3002
   tipBody \:306f\:547c\:3073\:51fa\:3057\:5074\:3067\:300cSummary \:304c\:3042\:308c\:3070 Summary\:3001
   \:7121\:3051\:308c\:3070 Keywords\:300d\:3068\:3057\:3066\:7d44\:307f\:7acb\:3066\:308b\:3002tipBody \:304c\:7a7a\:306e\:5834\:5408\:306f
   \:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3068\:3057\:3066\:30d1\:30b9\:540d\:3092\:8868\:793a\:3059\:308b\:3002

   Step 9 Hotfix: \:300c2 \:56de\:30af\:30ea\:30c3\:30af\:3057\:306a\:3044\:3068\:958b\:304b\:306a\:3044\:300d\:554f\:984c\:306e\:4fee\:6b63\:3002
   \:65e7\:7248\:306f Button[Tooltip[...], action] \:3068\:3001Tooltip \:3092 Button \:306e
   \:30e9\:30d9\:30eb (\:5185\:5074) \:306b\:3057\:3066\:3044\:305f\:3002Tooltip \:81ea\:4f53\:304c\:30a4\:30f3\:30bf\:30e9\:30af\:30c6\:30a3\:30d6
   \:8981\:7d20\:306a\:306e\:3067\:30011 \:56de\:76ee\:306e\:30af\:30ea\:30c3\:30af\:304c Tooltip \:306e\:51e6\:7406\:306b\:6d88\:8cbb\:3055\:308c\:3001
   2 \:56de\:76ee\:3067\:521d\:3081\:3066 Button \:306e\:30a2\:30af\:30b7\:30e7\:30f3\:304c\:767a\:706b\:3057\:3066\:3044\:305f\:3002
   \:65b0\:7248\:306f Tooltip[Button[...], tip] \:3068\:5165\:308c\:5b50\:3092\:9006\:8ee2\:3055\:305b\:3001
   Button \:304c\:30af\:30ea\:30c3\:30af\:3092\:76f4\:63a5\:53d7\:3051\:53d6\:308b\:3088\:3046\:306b\:3059\:308b
   (Tooltip \:306f\:5916\:5074\:3067\:30db\:30d0\:30fc\:8868\:793a\:5c02\:7528)\:3002 *)
iSVTitleButtonSym[title_, symPath_, origPath_String, tipBody_:""] :=
  Module[{disp, tipContent, core, ff},
    ff = iSVStandardFont[];
    disp = If[StringQ[title] && StringLength[title] > 28,
      StringTake[title, 26] <> "\[Ellipsis]", title];
    tipContent = If[StringQ[tipBody] && StringTrim[tipBody] =!= "",
      Column[{
        Style[ToString[title], Bold, FontFamily -> ff],
        Pane[Style[tipBody, FontFamily -> ff],
          ImageSize -> {UpTo[380], Automatic}]}],
      (* tipBody \:7121\:3057: \:5f93\:6765\:901a\:308a title + \:30d1\:30b9\:540d *)
      Column[{
        Style[ToString[title], Bold, FontFamily -> ff],
        Style[origPath, GrayLevel[0.4]]}]];
    (* Button \:3092\:5185\:5074\:3001Tooltip \:3092\:5916\:5074\:306b\:3059\:308b\:3002
       \:3053\:308c\:306b\:3088\:308a Button \:304c\:30af\:30ea\:30c3\:30af\:3092 1 \:56de\:3067\:53d7\:3051\:53d6\:308b\:3002
       2026-05-31 fix: Button \:306f\:30e9\:30d9\:30eb\:3092 Hold \:3059\:308b\:305f\:3081 iSVStandardFont[] \:304c
       \:672a\:8a55\:4fa1\:306e\:307e\:307e StyleBox \:306b\:7126\:304d\:8fbc\:307e\:308c\:3001FontFamily \:304c\:52b9\:304b\:306a\:3044\:3002
       Module \:5185\:3067\:5148\:306b ff \:306b\:6587\:5b57\:5217\:8a55\:4fa1\:3057\:3001\:305d\:306e\:6587\:5b57\:5217\:3092\:57cb\:3081\:8fbc\:3080\:3002 *)
    core = With[{ff2 = ff},
      If[StringQ[origPath] && FileExistsQ[origPath],
        Button[
          Style[disp, "Hyperlink", FontFamily -> ff2,
            ShowStringCharacters -> False],
          Module[{p},
            p = If[ListQ[symPath], iSVResolvePath[symPath], Missing[]];
            Which[
              StringQ[p] && FileExistsQ[p], SystemOpen[p],
              StringQ[origPath] && FileExistsQ[origPath], SystemOpen[origPath],
              True, Null]],
          Appearance -> "Frameless"],
        Style[disp, FontFamily -> ff2,
          ShowStringCharacters -> False]]];
    Tooltip[core, tipContent]
  ];

iSVDirButtonSym[symPath_, origPath_String] :=
  With[{ff = iSVStandardFont[]},
    If[StringQ[origPath] && FileExistsQ[origPath],
      Button[
        Style["\:958b\:304f", "Hyperlink", FontFamily -> ff,
          ShowStringCharacters -> False],
        Module[{p},
          p = If[ListQ[symPath], iSVResolvePath[symPath], Missing[]];
          Which[
            StringQ[p] && FileExistsQ[p], SystemOpen[DirectoryName[p]],
            StringQ[origPath] && FileExistsQ[origPath],
              SystemOpen[DirectoryName[origPath]],
            True, Null]],
        Appearance -> "Frameless"],
      ""]];

(* \:30d5\:30a1\:30a4\:30eb\:540d\:30d9\:30fc\:30b9\:306e\:30bf\:30a4\:30c8\:30eb\:6587\:5b57\:5217\:304b\:3089 yyyymmdd- \:30d7\:30ec\:30d5\:30a3\:30c3\:30af\:30b9\:3092\:524a\:9664 *)
iSVCleanTitle[s_String] :=
  StringReplace[s, RegularExpression["^\\d{8}-"] -> ""];
iSVCleanTitle[other_] := other;

(* record \:304b\:3089 Status \:6587\:5b57\:5217\:3092\:6c7a\:5b9a\:3002Header.Status \:304c\:6700\:3082\:512a\:5148\:3002
   Header.Status \:7121\:3057\:306e\:5834\:5408\:306f Todo \:96c6\:8a08\:304b\:3089\:63a8\:5b9a *)
iSVStatusFromRecord[record_Association] :=
  Module[{header, hdrStatus, open, done, pass},
    header = Lookup[record, "Header", <||>];
    hdrStatus = Lookup[header, "Status", Missing[]];
    Which[
      StringQ[hdrStatus], hdrStatus,
      True,
        open = Lookup[record, "OpenTodoCount", 0];
        done = Lookup[record, "DoneTodoCount", 0];
        pass = Lookup[record, "PassTodoCount", 0];
        Which[
          open > 0, "Todo",
          done > 0 && pass === 0, "Done",
          pass > 0 && done === 0, "Pass",
          done > 0 || pass > 0, "Done",
          True, "Todo"]
    ]
  ];

(* In-memory cache: key = abs path, value = <|"mtime" -> _, "row" -> _Association|> *)
If[!ValueQ[$iSVScheduleCache], $iSVScheduleCache = <||>];

(* record \[Rule] \:8868\:793a\:7528 row (Association)\:3002\:30ad\:30e3\:30c3\:30b7\:30e5\:3082\:3053\:3053\:3067\:5224\:5b9a\:3002 *)
iSVRowFromRecord[record_Association, today_, refresh_, fallback_,
    useCache_] :=
  Module[{path, symPath, realPath, mtime, cached, header, summary,
          statusLabel, dlResolved, nrResolved, sortKey},
    path = Lookup[record, "Path", Lookup[record, "OriginalPath", ""]];
    symPath = If[StringQ[path] && path =!= "",
      iSVSymbolicPath[path], {"<ABS>", ""}];
    mtime = iSVMTimeOf[path];

    (* Cache hit \:30c1\:30a7\:30c3\:30af *)
    If[useCache && KeyExistsQ[$iSVScheduleCache, path],
      cached = $iSVScheduleCache[path];
      If[AssociationQ[cached] &&
          Lookup[cached, "mtime", Missing[]] === mtime,
        Return[Lookup[cached, "row", <||>]]]];

    header = Lookup[record, "Header", <||>];
    summary = iSVEnsureSummaryInline[record, refresh, fallback];
    realPath = Module[{p =
        If[ListQ[symPath], iSVResolvePath[symPath], Missing[]]},
      Which[
        StringQ[p] && FileExistsQ[p], p,
        StringQ[path] && FileExistsQ[path], path,
        True, Missing["NoPath"]]];
    statusLabel = iSVStatusFromRecord[record];

    dlResolved = iSVResolveReviewDate[
      Lookup[header, "Deadline", Missing[]], mtime];
    nrResolved = iSVResolveReviewDate[
      Lookup[header, "NextReview", Missing[]], mtime];

    sortKey = Which[
      Head[dlResolved] === DateObject &&
        Head[nrResolved] === DateObject,
        Min[AbsoluteTime[dlResolved], AbsoluteTime[nrResolved]],
      Head[dlResolved] === DateObject, AbsoluteTime[dlResolved],
      Head[nrResolved] === DateObject, AbsoluteTime[nrResolved],
      True, Infinity];

    Module[{row},
      row = <|
        "Deadline" -> iSVStyledDate[
          Lookup[header, "Deadline", Missing[]], mtime],
        "NextReview" -> iSVStyledDate[
          Lookup[header, "NextReview", Missing[]], mtime],
        "Title" -> iSVTitleButtonSym[
          Which[
            StringQ[Lookup[header, "Title", Null]],
              iSVCleanTitle @ Lookup[header, "Title"],
            StringQ[Lookup[record, "Title", Null]],
              iSVCleanTitle @ Lookup[record, "Title"],
            True, iSVCleanTitle @ FileBaseName[path]],
          symPath, path],
        "Dir" -> iSVDirButtonSym[symPath, path],
        "OpenTodos" -> Lookup[record, "OpenTodoCount", 0],
        "Status" -> statusLabel,
        "Summary" -> iSVScheduleSummaryCell[
          If[AssociationQ[summary],
            Lookup[summary, "Status", "?"], "?"],
          iSVTitleTipBody[summary,
            Lookup[header, "Keywords", {}]]],
        "Publishable" -> iSVPublishableCell[realPath],
        "_SortKey" -> If[Head[nrResolved] === DateObject,
          AbsoluteTime[nrResolved],
          -Infinity]   (* NextReview \:7121\:3057\:306f\:6700\:5f8c\:306b (ReverseSort \:6642) *)
      |>;
      (* Cache \:66f4\:65b0 *)
      If[useCache,
        $iSVScheduleCache[path] = <|"mtime" -> mtime, "row" -> row|>];
      row
    ]
  ];

(* iSVEnsureSummary \:306e inline \:7248 (record \:81ea\:4f53\:3092\:8fd4\:3055\:305a summary \:304c\:3051\:6238\:308a\:8fd4\:3059) *)
iSVEnsureSummaryInline[record_Association, refresh_, fallback_] :=
  Module[{path, status, needRebuild},
    path = Lookup[record, "Path", Lookup[record, "OriginalPath", ""]];
    If[!StringQ[path] || !FileExistsQ[path],
      Return[<|"Status" -> "Missing", "Reason" -> "PathNotFound"|>]];
    (* Stage 9 P1.5: "Never" \:306f\:5168\:304f LLM \:3092\:547c\:3070\:305a\:3001Status \:53d6\:5f97\:3082\:30b9\:30ad\:30c3\:30d7\:3057\:3066
       \:4fdd\:5b58\:6e08\:307f Summary \:3092 1 \:56de\:8aad\:3080\:3060\:3051\:3002\:5f31\:3044\:30ed\:30fc\:30ab\:30eb LLM \:74b0\:5883\:3067\:306f\:3053\:308c\:304c\:65e2\:5b9a\:3002
       \:751f\:6210\:306f SourceVaultRefreshAllSummaries (\:5225 PC / \:5f37\:529b LLM \:74b0\:5883 / \:30d0\:30c3\:30c1\:30b8\:30e7\:30d6) \:3067\:884c\:3046\:3002
       Summary \:7121\:3057\:306e\:30ce\:30fc\:30c8\:306f\:547c\:3073\:51fa\:3057\:5074 (iSVTitleTipBody) \:3067 Keywords \:3092
       \:30c4\:30fc\:30eb\:30c1\:30c3\:30d7\:306b\:51fa\:3059 fallback \:304c\:52d5\:304f\:3002 *)
    If[refresh === "Never",
      Return[Quiet @ SourceVaultGetNotebookSummary[path]]];
    status = Quiet @ SourceVaultNotebookSummaryStatus[path];
    needRebuild = Switch[refresh,
      "Force", True,
      _,
        !AssociationQ[status] ||
          Lookup[status, "Status", ""] =!= "Current"
    ];
    If[needRebuild,
      Quiet @ SourceVaultNotebookSummary[path,
        "ForceRefresh" -> (refresh === "Force"),
        "FallbackToCloud" -> fallback],
      Quiet @ SourceVaultGetNotebookSummary[path]]
  ];

(* enriched records \:3092\:8868\:5f62\:5f0f\:306b\:6574\:5f62\:3002
   Imai \:5148\:751f\:306e\:5143\:5b9f\:88c5\:306b\:5408\:308f\:305b\:3066 NextReview \:964d\:9806 (ReverseSortBy) \:3067\:30bd\:30fc\:30c8\:3002
   \:6b8b\:8ab2\:984c 1 Hotfix: Dataset \:306f Button \:3092\:542b\:3080\:30bb\:30eb\:3092\:69cb\:9020\:7684\:306b "..." \:7701\:7565\:3059\:308b\:305f\:3081
   (\:30bb\:30eb\:5185 Pane \:306e\:5e45\:6307\:5b9a\:3082\:7121\:8996\:3055\:308c\:308b)\:3001Grid \:306b\:5207\:308a\:66ff\:3048\:308b\:3002
   Grid \:306f\:5b50\:8981\:7d20 Pane \:306e\:30b5\:30a4\:30ba\:3092\:5c0a\:91cd\:3057 Button \:3092\:7701\:7565\:3057\:306a\:3044\:3002
   Dataset \:98a8\:306e\:5916\:89b3 (\:30d8\:30c3\:30c0\:5f37\:8abf\:30fb\:8584\:3044\:7f6b\:7dda) \:306f Grid \:30aa\:30d7\:30b7\:30e7\:30f3\:3067\:518d\:73fe\:3002 *)
(* ----- Order T (PromptRouter / TabularQuery support) -----
   record \:306e List \:304b\:3089\:3001Select / SortBy \:53ef\:80fd\:306a\:6b63\:898f\:30ec\:30b3\:30fc\:30c9\:306e List \:3092\:4f5c\:308b\:3002
   iSVRowFromRecord \:304c\:4f5c\:308b\:8868\:793a\:7528 row \:3068\:306f\:5225\:7269: \:5024\:306f\:8868\:793a\:88c5\:98fe\:3092\:4e00\:5207\:6301\:305f\:306a\:3044
   \:751f\:5024 (Deadline/NextReview \:306f DateObject \:307e\:305f\:306f Missing[], OpenTodos \:306f
   \:6574\:6570, Title/Status/Path \:306f\:6587\:5b57\:5217)\:3002TabularQuery \:6a5f\:69cb\:306f\:3053\:308c\:3092 Select \:3059\:308b\:3002
   \:8868\:793a\:304c\:8981\:308b\:3068\:304d\:306f\:547c\:3073\:51fa\:3057\:5074\:304c iSVFormatScheduleDataset \:3067 Grid \:5316\:3059\:308b\:3002 *)
iSVScheduleNormalRecords[records_List] :=
  Map[
    Function[record,
      Module[{header, mtime, path, dl, nr},
        header = Lookup[record, "Header", <||>];
        If[!AssociationQ[header], header = <||>];
        path = Lookup[record, "Path",
          Lookup[record, "OriginalPath", ""]];
        mtime = iSVMTimeOf[path];
        dl = iSVResolveReviewDate[
          Lookup[header, "Deadline", Missing[]], mtime];
        nr = iSVResolveReviewDate[
          Lookup[header, "NextReview", Missing[]], mtime];
        <|
          "Deadline"   -> dl,
          "NextReview" -> nr,
          "Title"      -> Which[
            StringQ[Lookup[header, "Title", Null]],
              Lookup[header, "Title"],
            StringQ[Lookup[record, "Title", Null]],
              Lookup[record, "Title"],
            StringQ[path] && path =!= "",
              FileBaseName[path],
            True, ""],
          "OpenTodos"  -> Lookup[record, "OpenTodoCount", 0],
          "DoneTodos"  -> Lookup[record, "DoneTodoCount", 0],
          "PassTodos"  -> Lookup[record, "PassTodoCount", 0],
          "Status"     -> iSVStatusFromRecord[record],
          "Keywords"   -> Lookup[header, "Keywords", {}],
          "Path"       -> path
        |>
      ]],
    Select[records, AssociationQ]];
iSVScheduleNormalRecords[_] := {};

(* ----- FilterSpec predicate engine (spec v11 5.4.2 / 5.4.3) -----
   Applies a structured predicate (a closed DSL) to a normalized
   schedule record list. The DSL is deliberately tiny so that a
   FilterSpec option value can be a plain literal Association --
   no Function, no Slot, no arbitrary code. This is the
   SourceVault-side counterpart of the PromptRouter TabularQuery
   compiler; SourceVaultUpcomingSchedule uses it internally so
   that ClaudeEval can propose
     SourceVaultUpcomingSchedule[..., "FilterSpec" -> <|...|>]
   as a single allowlisted-callable expression.

   Predicate grammar (spec 5.4.3):
     <|"Kind"->"And"|"Or", "Clauses"->{...}|>
     <|"Kind"->"Not", "Clause"-><|...|>|>
     <|"Kind"->"Field", "Field"->name, "Op"->op, "Value"->v|>
   Op whitelist: Equal, NotEqual, Greater, GreaterEqual, Less,
   LessEqual, Contains, DateWithin, NonEmpty.
   A normalized record has Deadline / NextReview (DateObject or
   Missing[]), OpenTodos / DoneTodos / PassTodos (Integer),
   Title / Status / Path (String), Keywords (list). Field names
   not in that set make the whole FilterSpec invalid. *)

iSVScheduleFilterFieldType[field_] :=
  Switch[field,
    "Deadline" | "NextReview",            "Date",
    "OpenTodos" | "DoneTodos" | "PassTodos" |
      "OpenTodoCount" | "DoneTodoCount" |
      "PassTodoCount",                    "Integer",
    "Title" | "Status" | "Path",          "String",
    "Keywords",                           "StringList",
    _,                                    Missing["UnknownField"]];

(* canonical field name: accept the record key aliases too *)
iSVScheduleFilterCanonicalField[field_] :=
  Switch[field,
    "OpenTodoCount",  "OpenTodos",
    "DoneTodoCount",  "DoneTodos",
    "PassTodoCount",  "PassTodos",
    _,                field];

iSVScheduleFilterOpWhitelist[] :=
  {"Equal", "NotEqual", "Greater", "GreaterEqual",
   "Less", "LessEqual", "Contains", "DateWithin", "NonEmpty"};

(* evaluate a single Field clause against one record.
   Returns True / False, or $Failed if the clause is off-DSL. *)
iSVScheduleFilterEvalField[record_Association, node_Association] :=
  Module[{field, canonical, op, type, v, val},
    field = Lookup[node, "Field", Null];
    op    = Lookup[node, "Op", Null];
    If[!StringQ[field] || !StringQ[op], Return[$Failed]];
    If[!MemberQ[iSVScheduleFilterOpWhitelist[], op],
      Return[$Failed]];
    canonical = iSVScheduleFilterCanonicalField[field];
    type = iSVScheduleFilterFieldType[canonical];
    If[!StringQ[type], Return[$Failed]];
    v   = Lookup[record, canonical, Missing[]];
    val = Lookup[node, "Value", Null];
    Switch[op,
      "NonEmpty",
        Which[
          MissingQ[v], False,
          type === "StringList", ListQ[v] && v =!= {},
          type === "String", StringQ[v] && v =!= "",
          True, True],
      "DateWithin",
        (* Value is {lowDate, highDate}; record date in [lo,hi) *)
        If[type =!= "Date" || !ListQ[val] || Length[val] =!= 2,
          $Failed,
          If[MissingQ[v] || Head[v] =!= DateObject, False,
            AbsoluteTime[v] >= AbsoluteTime[val[[1]]] &&
            AbsoluteTime[v] <  AbsoluteTime[val[[2]]]]],
      "Contains",
        Which[
          MissingQ[v], False,
          type === "StringList",
            ListQ[v] && AnyTrue[v,
              StringQ[#] && StringQ[val] &&
              StringContainsQ[#, val, IgnoreCase -> True] &],
          True,
            StringQ[val] &&
            StringContainsQ[ToString[v], val,
              IgnoreCase -> True]],
      "Equal",
        If[MissingQ[v], False,
          If[type === "String", ToString[v] === ToString[val],
            v === val]],
      "NotEqual",
        If[MissingQ[v], True,
          If[type === "String", ToString[v] =!= ToString[val],
            v =!= val]],
      _,  (* Greater / GreaterEqual / Less / LessEqual *)
        Module[{cmp},
          cmp = Switch[op,
            "Greater", Greater, "GreaterEqual", GreaterEqual,
            "Less", Less, "LessEqual", LessEqual];
          Which[
            MissingQ[v], False,
            type === "Date",
              Head[v] === DateObject &&
              Head[val] === DateObject &&
              TrueQ[cmp[AbsoluteTime[v], AbsoluteTime[val]]],
            type === "Integer",
              IntegerQ[v] && (IntegerQ[val] || NumericQ[val]) &&
              TrueQ[cmp[v, val]],
            True, $Failed]]
    ]
  ];

(* evaluate any predicate node against one record *)
iSVScheduleFilterEval[record_Association, node_Association] :=
  Module[{kind, clauses, sub, vals},
    kind = Lookup[node, "Kind", Null];
    Switch[kind,
      "Field",
        iSVScheduleFilterEvalField[record, node],
      "And" | "Or",
        clauses = Lookup[node, "Clauses", Null];
        If[!ListQ[clauses] || clauses === {}, Return[$Failed]];
        vals = Map[iSVScheduleFilterEval[record, #] &, clauses];
        If[MemberQ[vals, $Failed], $Failed,
          If[kind === "And", AllTrue[vals, TrueQ],
            AnyTrue[vals, TrueQ]]],
      "Not",
        sub = Lookup[node, "Clause", Null];
        If[!AssociationQ[sub], Return[$Failed]];
        With[{r = iSVScheduleFilterEval[record, sub]},
          If[r === $Failed, $Failed, !TrueQ[r]]],
      _, $Failed]
  ];
iSVScheduleFilterEval[_, _] := $Failed;

(* apply a FilterSpec to a normalized record list.
   Returns the filtered list, or $Failed when the spec is
   off-DSL (caller then treats it as an invalid FilterSpec). *)
iSVApplyScheduleFilterSpec[records_List, spec_Association] :=
  Module[{evaluated},
    evaluated = Map[
      Function[rec,
        rec -> iSVScheduleFilterEval[rec, spec]],
      Select[records, AssociationQ]];
    If[AnyTrue[evaluated, Last[#] === $Failed &],
      $Failed,
      Keys[Select[evaluated, TrueQ[Last[#]] &]]]
  ];
iSVApplyScheduleFilterSpec[records_List, _] := records;
iSVApplyScheduleFilterSpec[_, _] := $Failed;


iSVFormatScheduleDataset[records_List, today_, refresh_, fallback_,
    useCache_] :=
  Module[{rows, cols, header, body, fontName, gridExpr},
    (* 2026-05-31 fix: iSVStandardFont[] \:304c Button \:30e9\:30d9\:30eb\:7b49\:306e Hold / box \:5316\:6587\:8108\:3067
       \:672a\:8a55\:4fa1\:306e\:307e\:307e StyleBox \:306b\:7126\:304d\:8fbc\:307e\:308c\:3001FontFamily -> iSVStandardFont[] \:304c
       \:30d5\:30ed\:30f3\:30c8\:30a8\:30f3\:30c9\:3067\:7121\:8996\:3055\:308c\:308b\:554f\:984c\:3078\:306e\:6839\:6cbb\:7b56\:3002
       Grid \:5168\:4f53\:3092\:7d44\:307f\:7acb\:3066\:305f\:5f8c\:3001\:6b8b\:5b58\:3059\:308b iSVStandardFont[] \:3092\:78ba\:5b9a\:6587\:5b57\:5217\:306b
       \:4e00\:62ec\:7f6e\:63db\:3057\:3066\:304b\:3089\:8fd4\:3059\:3002\:5404\:30bb\:30eb\:95a2\:6570\:5074\:3067\:8a55\:4fa1\:3055\:308c\:3066\:3044\:3066\:3082\:7f6e\:63db\:306f\:7121\:5bb3\:3002 *)
    fontName = iSVStandardFont[];
    If[!StringQ[fontName] || StringLength[fontName] == 0,
      fontName = "Yu Gothic UI"];
    rows = Map[
      iSVRowFromRecord[#, today, refresh, fallback, useCache] &,
      records];
    rows = ReverseSortBy[rows, #["_SortKey"] &];
    rows = Map[KeyDrop[#, "_SortKey"] &, rows];
    cols = {"Deadline", "NextReview", "Title", "Dir",
            "OpenTodos", "Status", "Summary", "Publishable"};
    body = Map[
      Function[r, Map[Lookup[r, #, ""] &, cols]],
      rows];
    If[body === {},
      Return[Style[
        "\:8a72\:5f53\:3059\:308b notebook \:306f\:3042\:308a\:307e\:305b\:3093\:3002",
        FontFamily -> fontName]]];
    header = Map[
      Style[#, Bold, FontFamily -> fontName] &, cols];
    gridExpr = Grid[
      Prepend[body, header],
      Frame -> All,
      FrameStyle -> Directive[GrayLevel[0.85]],
      Background -> {None, {GrayLevel[0.92], {White}}},
      Alignment -> {Left, Center},
      Spacings -> {1.2, 0.7},
      BaseStyle -> {FontFamily -> fontName}
    ];
    (* \:6b8b\:5b58\:3059\:308b\:672a\:8a55\:4fa1\:306e iSVStandardFont[] \:3092\:6587\:5b57\:5217\:306b\:7f6e\:63db (Hold \:56de\:907f)\:3002
       \:5de6\:8fba\:306f HoldPattern \:3067\:5305\:307f\:3001\:30eb\:30fc\:30eb\:69cb\:7bc9\:6642\:306b iSVStandardFont[] \:304c
       \:8a55\:4fa1\:3055\:308c\:3066\:7121\:610f\:5473\:306a\:30eb\:30fc\:30eb\:306b\:306a\:308b\:306e\:3092\:9632\:3050\:3002 *)
    gridExpr /. HoldPattern[iSVStandardFont[]] -> fontName
  ];


(* === Public API: SourceVaultFormatNotebookList === *)

(* Stage 9 P1.5: \:4efb\:610f\:306e notebook record List \:3092\:3001
   SourceVaultUpcomingSchedule \:3068\:540c\:3058\:8868\:5f62\:5f0f\:3067\:8868\:793a\:3059\:308b public API\:3002
   ClaudeEval \:306a\:3069\:3067\:300cnotebook \:306e\:4e00\:89a7\:300d\:3092\:30e6\:30fc\:30b6\:30fc\:306b\:898b\:305b\:308b\:5834\:9762\:306e
   \:65e2\:5b9a\:30d5\:30a9\:30fc\:30de\:30c3\:30c8\:95a2\:6570\:3002SourceVaultFindNotebooks \:306e\:623b\:308a\:5024\:3084\:3001
   SourceVaultIndexNotebook \:306e OK record \:306e List \:3092\:305d\:306e\:307e\:307e\:6e21\:305b\:308b\:3002

   \:5185\:90e8\:7684\:306b\:306f iSVRowFromRecord + iSVFormatScheduleDataset \:3092\:547c\:3076\:3060\:3051\:3060\:304c\:3001
   Public API \:3068\:3057\:3066 export \:3059\:308b\:3053\:3068\:3067 skill \:304b\:3089\:540d\:6307\:3057\:3067\:6307\:793a\:3067\:304d\:308b\:3088\:3046\:306b\:3059\:308b\:3002 *)

Options[SourceVaultFormatNotebookList] = {
  "Refresh" -> "Never",        (* Stage 9 P1.5: \:8868\:793a\:6642\:306b LLM \:3092\:547c\:3070\:306a\:3044 (\:65e2\:5b9a)\:3002
                                  Summary \:7121\:3057\:306e\:30ce\:30fc\:30c8\:306f Keywords \:3092 Title \:30c4\:30fc\:30eb\:30c1\:30c3\:30d7\:306b\:51fa\:3059\:3002
                                  \:5f37\:529b LLM \:74b0\:5883\:3067\\:306f\\:660e\\:793a\\:7684\\:306b "IfStale" / "Force" \:3092\:6e21\:3059\:3002 *)
  "FallbackToCloud" -> "Deny",
  "UseCache" -> True
};

SourceVaultFormatNotebookList[records_List, opts:OptionsPattern[]] :=
  Module[{today, refresh, fallback, useCache, filtered},
    today = DateObject[Now, "Day"];
    refresh = OptionValue["Refresh"];
    fallback = OptionValue["FallbackToCloud"];
    useCache = TrueQ[OptionValue["UseCache"]];
    (* AssociationQ \:3067 record \:3060\:3051\:62fe\:3046 (\:30e6\:30fc\:30b6\:304c Mixed list \:3092\:6e21\:3059\:5834\:5408\:306b\:5099\:3048\:308b) *)
    filtered = Select[records, AssociationQ];
    iSVFormatScheduleDataset[filtered, today, refresh, fallback, useCache]
  ];

SourceVaultFormatNotebookList[_, ___] := $Failed;

(* === Public API: SourceVaultRefreshAllSummaries === *)

Options[SourceVaultRefreshAllSummaries] = {
  "Scope" -> Automatic,
  "Recursive" -> True,
  "ForceRefresh" -> False,
  "FallbackToCloud" -> "Deny",        (* \:4e00\:62ec\:6642\:306f\:30c7\:30d5\:30a9\:30eb\:30c8\:3067 Deny *)
  (* Stage 9 P1.5: \:30d0\:30c3\:30c1\:751f\:6210\:7528 *)
  "OpenTodosOnly" -> False,           (* True \:306a\:3089 OpenTodoCount > 0 \:306e\:30ce\:30fc\:30c8\:3060\:3051\:751f\:6210\:5bfe\:8c61 *)
  "Model" -> Automatic,               (* \:660e\:793a\:7684\:306b\:5f37\:529b LLM \:3092\:6307\:5b9a\:3057\:305f\:3044\:3068\:304d *)
  "Progress" -> False,                (* True \:306a\:3089 Print \:3067\:9032\:6357\:8868\:793a\:3092\:51fa\:3059 *)
  "Limit" -> Infinity                 (* \:6700\:5927\:51e6\:7406\:30d5\:30a1\:30a4\:30eb\:6570 (\:30c6\:30b9\:30c8\:7528) *)
};

SourceVaultRefreshAllSummaries[opts:OptionsPattern[]] :=
  Module[{root, recursive, force, fallback, openTodosOnly, modelOpt,
          showProgress, limit, indexResult, files, candidates,
          results, refreshed = 0, cached = 0, incon = 0, failed = 0,
          skipped = 0, total, startTime},
    root = iSVResolveScope[OptionValue["Scope"]];
    If[!StringQ[root] || !DirectoryQ[root],
      Return[<|"Status" -> "Failed", "Reason" -> "ScopeNotFound",
        "Scope" -> root|>]];

    recursive = TrueQ[OptionValue["Recursive"]];
    force = TrueQ[OptionValue["ForceRefresh"]];
    fallback = OptionValue["FallbackToCloud"];
    openTodosOnly = TrueQ[OptionValue["OpenTodosOnly"]];
    modelOpt = OptionValue["Model"];
    showProgress = TrueQ[OptionValue["Progress"]];
    limit = OptionValue["Limit"];

    (* (1) index \:5168\:4ef6 *)
    indexResult = Quiet @ SourceVaultIndexNotebookFolder[root,
      "Recursive" -> recursive];
    candidates = If[AssociationQ[indexResult],
      Cases[Lookup[indexResult, "Results", {}], a_Association :> a],
      {}];

    (* (1.5) OpenTodosOnly \:30d5\:30a3\:30eb\:30bf *)
    If[openTodosOnly,
      candidates = Select[candidates,
        NumericQ[Lookup[#, "OpenTodoCount", 0]] &&
        Lookup[#, "OpenTodoCount", 0] > 0 &]];

    files = Cases[candidates,
      a_Association :>
        With[{p = Lookup[a, "Path", Missing[]]},
          If[StringQ[p] && FileExistsQ[p], p, Nothing]]];

    (* Limit \:9069\:7528 *)
    If[NumericQ[limit] && limit < Length[files],
      skipped = Length[files] - limit;
      files = Take[files, limit]];

    total = Length[files];
    startTime = AbsoluteTime[];

    If[showProgress,
      Print["[SourceVaultRefreshAllSummaries] ",
        total, " notebooks to process",
        If[openTodosOnly, " (OpenTodos > 0 only)", ""],
        If[skipped > 0, ", " <> ToString[skipped] <> " skipped by Limit", ""]]];

    (* (2) \:5404\:30d5\:30a1\:30a4\:30eb\:3092 SourceVaultNotebookSummary \:3067\:518d\:751f\:6210 *)
    results = MapIndexed[
      Function[{p, idx},
        Module[{r, summaryOpts},
          summaryOpts = {
            "ForceRefresh" -> force,
            "FallbackToCloud" -> fallback};
          If[modelOpt =!= Automatic,
            AppendTo[summaryOpts, "Model" -> modelOpt]];
          r = Quiet @ SourceVaultNotebookSummary[p,
            Sequence @@ summaryOpts];
          Switch[Lookup[r, "Status", ""],
            "OK",
              If[TrueQ @ Lookup[r, "Cached", False],
                cached++, refreshed++],
            "Inconsistent", incon++,
            _, failed++];
          If[showProgress && Mod[First[idx], 10] === 0,
            Print["  [", First[idx], "/", total,
              "] refreshed=", refreshed, " cached=", cached,
              " failed=", failed,
              " elapsed=", Round[AbsoluteTime[] - startTime], "s"]];
          <|"Path" -> p, "Result" -> r|>]],
      files];

    If[showProgress,
      Print["[SourceVaultRefreshAllSummaries] done. ",
        "refreshed=", refreshed, " cached=", cached,
        " inconsistent=", incon, " failed=", failed,
        " total time=", Round[AbsoluteTime[] - startTime], "s"]];

    <|"Status" -> "OK",
      "Scope" -> root,
      "TotalFiles" -> total,
      "Refreshed" -> refreshed,
      "Cached" -> cached,
      "Inconsistent" -> incon,
      "Failed" -> failed,
      "SkippedByLimit" -> skipped,
      "Details" -> results|>
  ];


(* ============================================================
   Stage 9 Phase 2 (P1) Step 5: SourceVaultResetStore
   ------------------------------------------------------------
   notebooks \:30b9\:30c8\:30a2\:3092\:5168\:524a\:9664\:3057\:3066\:521d\:671f\:5316\:3059\:308b\:3002
   \:7834\:58ca\:7684\:64cd\:4f5c\:306a\:306e\:3067 "Confirm" -> True \:304c\:7121\:3044\:3068 DryRun \:6271\:3044\:3002
   ============================================================ *)

Options[SourceVaultResetStore] = {"Confirm" -> False};

SourceVaultResetStore[opts:OptionsPattern[]] :=
  Module[{confirm, nbDir, targets, existing, deleted},
    confirm = TrueQ[OptionValue["Confirm"]];
    nbDir = iNotebooksDir[];

    (* \:524a\:9664\:5bfe\:8c61\:30b5\:30d6\:30c7\:30a3\:30ec\:30af\:30c8\:30ea *)
    targets = {"sources", "snapshots", "summaries", "todos",
               "review", "lint", "sync", "relink"};
    existing = Select[
      Map[FileNameJoin[{nbDir, #}] &, targets],
      DirectoryQ];

    If[!confirm,
      (* DryRun: \:524a\:9664\:305b\:305a\:3001\:5bfe\:8c61\:3092\:8fd4\:3059\:3060\:3051 *)
      Return[<|
        "Status" -> "DryRun",
        "NotebooksDir" -> nbDir,
        "WouldDelete" -> existing,
        "Message" ->
          "Confirm -> True \:3092\:6e21\:3059\:3068\:5b9f\:969b\:306b\:524a\:9664\:3057\:307e\:3059\:3002"|>]];

    (* \:5b9f\:524a\:9664 *)
    deleted = {};
    Scan[
      Function[d,
        If[DirectoryQ[d],
          Quiet @ Check[
            DeleteDirectory[d, DeleteContents -> True];
            AppendTo[deleted, d],
            Null]]],
      existing];

    (* in-memory \:30ad\:30e3\:30c3\:30b7\:30e5\:3082\:30af\:30ea\:30a2 *)
    $iSVIndexCache = <||>;
    $iSVScheduleCache = <||>;
    $iSVLastCacheStats = <||>;

    <|"Status" -> "OK",
      "NotebooksDir" -> nbDir,
      "Deleted" -> deleted|>
  ];


(* \:30b7\:30f3\:30dc\:30ea\:30c3\:30af\:30d1\:30b9\:518d\:30ea\:30f3\:30af: sources \:306e Location \:3092\:73fe\:5728\:5730\:306b\:66f4\:65b0\:3002
   (Step 5: \:30d5\:30a1\:30a4\:30eb\:79fb\:52d5\:6642\:306e\:518d\:30ea\:30f3\:30af\:7528\:3001\:5c06\:6765\:306e index \:7d71\:5408\:7528\:30d8\:30eb\:30d1\:3002) *)

(* ============================================================
   Next phase 2: SourceVaultRelinkSources (file-move tracking)
   ------------------------------------------------------------
   Detects NotebookSource records whose OriginalPath no longer
   exists (the file was moved) and finds the new location under
   Scope. Matching fallback order:
     (1) embedded UUID  (Header "NotebookUUID")
     (2) content hash   (RawContentHash exact match)
     (3) name-only      (unique FileBaseName match)
   Non-destructive: with DryRun -> False the new location is
   re-indexed via SourceVaultIndexNotebook and the old source
   record is marked Superseded (the old record is NOT deleted).
   ============================================================ *)

(* relink store directory under notebooks/ *)
iSVRelinkDir[] :=
  Module[{d},
    d = FileNameJoin[{iNotebooksDir[], "relink"}];
    iEnsureDir[d];
    d
  ];

iSVRelinkLogPath[] :=
  FileNameJoin[{iSVRelinkDir[], "relink-log.jsonl"}];

(* content hash of a notebook file (RawContentHash form).
   Skips files above the size threshold. *)
iSVContentHashOf[path_String] :=
  Module[{sizeBytes, maxBytes, content},
    If[!FileExistsQ[path], Return[Missing["FileNotFound"]]];
    sizeBytes = Quiet @ Check[FileByteCount[path], 0];
    maxBytes = iSVMaxFileSizeMB[] * 1024.^2;
    If[NumericQ[sizeBytes] && sizeBytes > maxBytes,
      Return[Missing["FileTooLarge"]]];
    content = Quiet[Import[path, "Text"]];
    If[!StringQ[content], Return[Missing["ReadFailed"]]];
    "sha256-" <> Hash[content, "SHA256", "HexString"]
  ];

(* embedded UUID from a notebook header, if present *)
(* embedded UUID of a notebook (TaggingRules SourceVault >
   NotebookUUID). Delegates to the public API. *)
iSVHeaderUUIDOf[path_String] :=
  Module[{uuid},
    If[!FileExistsQ[path], Return[Missing["FileNotFound"]]];
    uuid = Quiet @ SourceVaultNotebookUUID[path];
    If[StringQ[uuid] && uuid =!= "", uuid, Missing["NoUUID"]]
  ];

(* === Public API: SourceVaultRelinkSources === *)

Options[SourceVaultRelinkSources] = {
  "Scope" -> Automatic,
  "Recursive" -> True,
  "DryRun" -> True,
  "ApplyNameOnly" -> False,
  "DeleteStale" -> False,
  "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}
};

SourceVaultRelinkSources[opts:OptionsPattern[]] :=
  Module[{root, recursive, dryRun, applyNameOnly, deleteStale,
          excludes, sourcesDir, srcFiles,
          candidateFiles, candHashCache, candUUIDCache, livePathSet,
          linked, relinked, unresolved, staleDuplicates,
          staleDeleted, ts, relinkId},
    iEnsureRoots[];
    root = iSVResolveScope[OptionValue["Scope"]];
    If[!StringQ[root] || !DirectoryQ[root],
      Return[<|"Status" -> "Failed", "Reason" -> "ScopeNotFound",
        "Scope" -> root|>]];
    recursive = TrueQ[OptionValue["Recursive"]];
    dryRun = TrueQ[OptionValue["DryRun"]];
    applyNameOnly = TrueQ[OptionValue["ApplyNameOnly"]];
    deleteStale = TrueQ[OptionValue["DeleteStale"]];
    excludes = OptionValue["ExcludePatterns"];

    sourcesDir = FileNameJoin[{iNotebooksDir[], "sources"}];
    If[!DirectoryQ[sourcesDir],
      Return[<|"Status" -> "OK", "Linked" -> 0,
        "Relinked" -> {}, "Unresolved" -> {},
        "DryRun" -> dryRun,
        "Note" -> "No source records yet."|>]];
    srcFiles = FileNames["*.json", sourcesDir];

    (* candidate .nb files under Scope (lazy hash / uuid caches) *)
    candidateFiles = If[recursive,
      FileNames["*.nb", root, Infinity],
      FileNames["*.nb", root]];
    candidateFiles = Select[candidateFiles, Function[f,
      With[{name = FileNameTake[f]},
        !StringContainsQ[name, ".tmp-"] &&
        !AnyTrue[excludes, StringMatchQ[name, #] &]]]];
    candHashCache = <||>;
    candUUIDCache = <||>;

    (* set of real file paths that LIVE (not Superseded /
       StaleDuplicate) source records currently point to.
       A matched file already in this set is not a moved file
       but a stale leftover record -- detected by real path,
       not by NotebookRef (which can collide across PC roots). *)
    livePathSet = Module[{paths = {}},
      Scan[
        Function[sf,
          Module[{r, st, p, sym, resolved},
            r = iLoadJSONFromFile[sf];
            If[AssociationQ[r] &&
                Lookup[r, "Type", ""] === "NotebookSource",
              st = Lookup[r, "RelinkStatus", ""];
              If[st =!= "Superseded" && st =!= "StaleDuplicate",
                p = Lookup[r, "OriginalPath", ""];
                If[StringQ[p] && FileExistsQ[p],
                  AppendTo[paths, ExpandFileName[p]]];
                sym = Lookup[r, "SymbolicPath", Null];
                If[ListQ[sym],
                  resolved = iSVResolvePath[sym];
                  If[StringQ[resolved] && FileExistsQ[resolved],
                    AppendTo[paths,
                      ExpandFileName[resolved]]]]]]]],
        srcFiles];
      Association @ Map[# -> True &, DeleteDuplicates[paths]]];

    linked = 0; relinked = {}; unresolved = {};
    staleDuplicates = {}; staleDeleted = {};
    relinkId = "relink-" <>
      IntegerString[Round[1000 * AbsoluteTime[]], 36];
    ts = DateString[DateObject[]];

    Scan[
      Function[srcFile,
        Module[{rec, op, nbRef, snapInfo, oldHash, oldUUID,
                match, method, base, sameName, symResolved},
          rec = iLoadJSONFromFile[srcFile];
          If[!AssociationQ[rec], Return[Null, Module]];
          If[Lookup[rec, "Type", ""] =!= "NotebookSource",
            Return[Null, Module]];
          op = Lookup[rec, "OriginalPath", ""];
          nbRef = Lookup[rec, "NotebookRef", ""];
          (* skip records already superseded by a prior relink *)
          If[Lookup[rec, "RelinkStatus", ""] === "Superseded",
            Return[Null, Module]];
          (* "still linked" test: the file is considered present
             (not moved) if EITHER its OriginalPath exists, OR
             its SymbolicPath resolves to an existing file on
             this PC. The symbolic-path check prevents a mere
             PC / root-path difference (e.g. C:\Users\imai_ vs
             F:\Dropbox) from being misread as a file move.
             NB: symResolved is declared in this Function's
             Module so that Return[Null, Module] below exits
             the whole per-record Function, not just an inner
             Module (the earlier inner-Module form let the
             record fall through into the match loop). *)
          symResolved = Module[{sp = Lookup[rec, "SymbolicPath", Null]},
            If[ListQ[sp], iSVResolvePath[sp], Missing[]]];
          If[(StringQ[op] && FileExistsQ[op]) ||
             (StringQ[symResolved] && FileExistsQ[symResolved]),
            linked = linked + 1;
            Return[Null, Module]];

          (* the file moved or was deleted; try to find it *)
          snapInfo = iSVSnapshotInfoForSource[nbRef];
          oldHash = If[Lookup[snapInfo, "HasSnapshot", False] === True,
            Module[{sp, sr},
              sp = iNotebookSnapshotPath[
                Lookup[snapInfo, "SnapshotId", ""]];
              sr = If[FileExistsQ[sp], iLoadJSONFromFile[sp], Missing[]];
              If[AssociationQ[sr],
                Lookup[sr, "RawContentHash", Missing[]],
                Missing[]]],
            Missing[]];
          oldUUID = Lookup[rec, "SourceUUID", Missing["NoUUID"]];

          match = Missing[]; method = "None";

          (* (1) UUID match -- only if old record carries a UUID *)
          If[StringQ[oldUUID] && oldUUID =!= "",
            Module[{hit},
              hit = SelectFirst[candidateFiles,
                Function[cf,
                  If[!KeyExistsQ[candUUIDCache, cf],
                    candUUIDCache[cf] = iSVHeaderUUIDOf[cf]];
                  candUUIDCache[cf] === oldUUID],
                Missing[]];
              If[StringQ[hit], match = hit; method = "UUID"]]];

          (* (2) content hash match *)
          If[MissingQ[match] && StringQ[oldHash],
            Module[{hit},
              hit = SelectFirst[candidateFiles,
                Function[cf,
                  If[!KeyExistsQ[candHashCache, cf],
                    candHashCache[cf] = iSVContentHashOf[cf]];
                  candHashCache[cf] === oldHash],
                Missing[]];
              If[StringQ[hit], match = hit; method = "ContentHash"]]];

          (* (3) name-only match (unique basename) *)
          If[MissingQ[match] && StringQ[op],
            base = FileBaseName[op];
            sameName = Select[candidateFiles,
              FileBaseName[#] === base &];
            If[Length[sameName] === 1,
              match = First[sameName]; method = "NameOnly"]];

          (* StaleDuplicate detection: if the matched file is
             ALREADY pointed to by a LIVE source record (real
             path membership in livePathSet), then this record
             is not a moved file -- it is a leftover record from
             an earlier index pass on another PC (different root
             path). Real-path check avoids NotebookRef hash
             collisions across PC roots.
             With DeleteStale -> True the stale record file is
             removed from sources/; otherwise it is marked
             RelinkStatus -> StaleDuplicate (non-destructive). *)
          If[StringQ[match],
            Module[{matchAbs},
              matchAbs = ExpandFileName[match];
              If[TrueQ[Lookup[livePathSet, matchAbs, False]] &&
                  (!StringQ[op] ||
                   ExpandFileName[op] =!= matchAbs),
                AppendTo[staleDuplicates,
                  <|"NotebookRef" -> nbRef,
                    "Title" -> Lookup[rec, "Title",
                      FileBaseName[op]],
                    "OldPath" -> op,
                    "LiveRecordPath" -> matchAbs,
                    "Method" -> method,
                    "Action" -> Which[
                      dryRun, "WouldMark",
                      deleteStale, "Deleted",
                      True, "Marked"]|>];
                If[!dryRun,
                  If[deleteStale,
                    (* delete the stale leftover record file *)
                    Quiet @ DeleteFile[srcFile];
                    AppendTo[staleDeleted, srcFile],
                    (* non-destructive: mark only *)
                    Module[{updated, json, strm},
                      updated = rec;
                      updated["RelinkStatus"] = "StaleDuplicate";
                      updated["DuplicateOfPath"] = matchAbs;
                      updated["RelinkedAt"] = ts;
                      json = Quiet @ ExportString[
                        iSanitizeForJSON[updated], "RawJSON",
                        "Compact" -> False];
                      If[StringQ[json],
                        strm = Quiet[OpenWrite[srcFile,
                          BinaryFormat -> True]];
                        If[Head[strm] === OutputStream,
                          BinaryWrite[strm,
                            StringToByteArray[json, "ISO8859-1"]];
                          Close[strm]]]]]];
                match = Missing["StaleDuplicate"]]]];

          If[StringQ[match],
            AppendTo[relinked,
              <|"NotebookRef" -> nbRef,
                "Title" -> Lookup[rec, "Title", FileBaseName[op]],
                "OldPath" -> op,
                "NewPath" -> match,
                "Method" -> method|>];
            (* apply only strong matches (UUID / ContentHash)
               automatically. NameOnly is a weak signal: many
               notebooks share a basename pattern (e.g. numbered
               series), so a unique-basename hit can be wrong.
               NameOnly is applied only when ApplyNameOnly -> True;
               otherwise it is reported but not committed. *)
            If[!dryRun &&
               (method =!= "NameOnly" || applyNameOnly),
              (* re-index the new location (creates a fresh
                 record + snapshot under the new NotebookRef) *)
              Quiet @ SourceVaultIndexNotebook[match];
              (* mark the old source record Superseded
                 (non-destructive; old record kept) *)
              Module[{updated, json, strm},
                updated = rec;
                updated["RelinkStatus"] = "Superseded";
                updated["SupersededByPath"] = match;
                updated["SupersededByRef"] =
                  iNotebookRefFromPath[match];
                updated["RelinkMethod"] = method;
                updated["RelinkedAt"] = ts;
                json = Quiet @ ExportString[
                  iSanitizeForJSON[updated], "RawJSON",
                  "Compact" -> False];
                If[StringQ[json],
                  strm = Quiet[OpenWrite[srcFile,
                    BinaryFormat -> True]];
                  If[Head[strm] === OutputStream,
                    BinaryWrite[strm,
                      StringToByteArray[json, "ISO8859-1"]];
                    Close[strm]]]]],
            (* unresolved *)
            AppendTo[unresolved,
              <|"NotebookRef" -> nbRef,
                "Title" -> Lookup[rec, "Title", FileBaseName[op]],
                "OldPath" -> op,
                "Reason" -> If[StringQ[op] && !FileExistsQ[op],
                  "FileMovedOrDeleted", "NoOriginalPath"]|>]]
        ]],
      srcFiles];

    (* append to relink log *)
    Module[{logRec, json, strm},
      logRec = <|
        "Type" -> "SourceVaultRelink",
        "RelinkId" -> relinkId,
        "Scope" -> root,
        "RanAt" -> ts,
        "DryRun" -> dryRun,
        "DeleteStale" -> deleteStale,
        "Linked" -> linked,
        "RelinkedCount" -> Length[relinked],
        "StaleDuplicateCount" -> Length[staleDuplicates],
        "StaleDeletedCount" -> Length[staleDeleted],
        "UnresolvedCount" -> Length[unresolved]|>;
      json = Quiet @ ExportString[iSanitizeForJSON[logRec],
        "RawJSON", "Compact" -> True];
      If[StringQ[json],
        strm = Quiet[OpenAppend[iSVRelinkLogPath[],
          BinaryFormat -> True]];
        If[Head[strm] === OutputStream,
          BinaryWrite[strm,
            StringToByteArray[json <> "\n", "ISO8859-1"]];
          Close[strm]]]];

    <|"Status" -> "OK",
      "RelinkId" -> relinkId,
      "Scope" -> root,
      "DryRun" -> dryRun,
      "ApplyNameOnly" -> applyNameOnly,
      "DeleteStale" -> deleteStale,
      "Linked" -> linked,
      "Relinked" -> relinked,
      "RelinkedCount" -> Length[relinked],
      "ByMethod" -> Module[{m = Counts[
          Map[Lookup[#, "Method", "?"] &, relinked]]},
        <|"UUID" -> Lookup[m, "UUID", 0],
          "ContentHash" -> Lookup[m, "ContentHash", 0],
          "NameOnly" -> Lookup[m, "NameOnly", 0]|>],
      "StaleDuplicates" -> staleDuplicates,
      "StaleDuplicateCount" -> Length[staleDuplicates],
      "StaleDeletedCount" -> Length[staleDeleted],
      "Unresolved" -> unresolved,
      "UnresolvedCount" -> Length[unresolved]|>
  ];

(* legacy alias: kept for backward compatibility *)
iSVRelinkSources[] := SourceVaultRelinkSources[];

(* ============================================================
   Next phase 3: Model registry dynamic update
   ------------------------------------------------------------
   Refreshes the compiled model registry from live endpoints:
   cloud providers (anthropic / openai) and local LLM servers
   (LM Studio, OpenAI-compatible). Reachability is checked so an
   offline endpoint is detected rather than hanging. Registry
   entries are {Provider, ModelId, Endpoint, Class, Availability,
   Source}. Auto-fetched entries are merged into the existing
   compiled registry; seed / manual entries are preserved.
   Endpoint URLs are configuration data, not model branch names,
   so they live here; concrete model ids are never hard-coded
   (they come from the live endpoint or the seed registry).
   ============================================================ *)

(* provider -> endpoint configuration (user-overridable).
   Local endpoints (e.g. LM Studio port) vary per machine. *)
If[!AssociationQ[SourceVault`$SourceVaultModelEndpoints],
  SourceVault`$SourceVaultModelEndpoints = <|
    "anthropic" -> <|
      "ModelsURL" -> "https://api.anthropic.com/v1/models",
      "Kind" -> "Cloud", "AuthProvider" -> "anthropic"|>,
    "openai" -> <|
      "ModelsURL" -> "https://api.openai.com/v1/models",
      "Kind" -> "Cloud", "AuthProvider" -> "openai"|>,
    "lmstudio" -> <|
      "ModelsURL" -> "http://127.0.0.1:1234/v1/models",
      "Kind" -> "Local", "AuthProvider" -> None|>,
    (* chatgptcodex: the ChatGPT Codex CLI exposes its model
       catalog through `codex debug models` (JSON on stdout),
       not an HTTP /v1/models endpoint. Kind "CodexCLI" routes
       SourceVaultRefreshModelRegistry to the CLI fetch path.
       "Exe" is the codex executable name/path; the CLI is run
       via cmd /c so it is resolved against the full user PATH. *)
    "chatgptcodex" -> <|
      "Kind" -> "CodexCLI", "Exe" -> "codex",
      "AuthProvider" -> None|>
  |>];

(* short-timeout reachability probe; returns an Association.
   A 401/403 still means the server is reachable (Online).
   Uses TimeConstrained instead of a URLRead option (URLRead
   does not accept TimeConstraint as an option). *)
iSVProbeEndpoint[url_String] :=
  Module[{resp, code},
    resp = Quiet @ Check[
      TimeConstrained[URLRead[HTTPRequest[url]], 6, $Failed],
      $Failed];
    code = If[Head[resp] === HTTPResponse,
      resp["StatusCode"], $Failed];
    If[IntegerQ[code] && code > 0,
      <|"Reachable" -> True, "StatusCode" -> code|>,
      <|"Reachable" -> False, "StatusCode" -> Missing["Unreachable"]|>]
  ];

(* fetch OpenAI-compatible /v1/models JSON and extract model ids.
   headers: list of Rule for HTTPRequest, or {} for none. *)
iSVFetchModelIds[url_String, headers_List] :=
  Module[{req, resp, code, body, parsed, data},
    req = If[headers === {},
      HTTPRequest[url],
      HTTPRequest[url, <|"Headers" -> headers|>]];
    resp = Quiet @ Check[
      TimeConstrained[URLRead[req], 15, $Failed],
      $Failed];
    If[Head[resp] =!= HTTPResponse,
      Return[<|"Status" -> "Failed", "Reason" -> "RequestFailed"|>]];
    code = resp["StatusCode"];
    If[code =!= 200,
      Return[<|"Status" -> "Failed",
        "Reason" -> "HTTPStatus" <> ToString[code],
        "StatusCode" -> code|>]];
    body = resp["Body"];
    If[!StringQ[body],
      body = Quiet @ Check[
        ByteArrayToString[resp["BodyByteArray"], "UTF-8"], $Failed]];
    If[!StringQ[body],
      Return[<|"Status" -> "Failed", "Reason" -> "EmptyBody"|>]];
    parsed = Quiet @ Check[
      Developer`ReadRawJSONString[body], $Failed];
    If[!AssociationQ[parsed],
      parsed = Quiet @ Check[
        ImportString[body, "RawJSON"], $Failed]];
    If[!AssociationQ[parsed],
      Return[<|"Status" -> "Failed", "Reason" -> "JSONParseFailed"|>]];
    data = Lookup[parsed, "data", {}];
    If[!ListQ[data],
      Return[<|"Status" -> "Failed", "Reason" -> "NoDataArray"|>]];
    <|"Status" -> "OK",
      "ModelIds" -> DeleteCases[
        Map[Function[m,
          If[AssociationQ[m], Lookup[m, "id", Missing[]], Missing[]]],
          data],
        _Missing]|>
  ];

(* fetch the ChatGPT Codex model catalog via `codex debug models`.
   The CLI prints JSON {"models":[{"slug":..,"visibility":..}, ...]}
   to stdout. Entries with visibility "hide" are internal and are
   dropped; the slug is the id accepted by config.toml's model key.
   The CLI is run through cmd /c so the codex executable is resolved
   against the full user PATH (a bare RunProcess[{"codex",...}] does
   not see the user's PATH on Windows). Returns the same shape as
   iSVFetchModelIds: <|"Status"->"OK"|"Failed", "ModelIds"->{..}|>. *)
iSVFetchCodexModelIds[exe_String] :=
  Module[{cmd, run, out, data, models, slugs},
    cmd = If[$OperatingSystem === "Windows",
      {"cmd", "/c", exe, "debug", "models"},
      {exe, "debug", "models"}];
    run = Quiet @ TimeConstrained[
      Check[RunProcess[cmd, All], $Failed], 30, $Failed];
    If[!AssociationQ[run],
      Return[<|"Status" -> "Failed", "Reason" -> "RunProcessFailed"|>]];
    If[Lookup[run, "ExitCode", 1] =!= 0,
      Return[<|"Status" -> "Failed",
        "Reason" -> "CodexExitCode" <>
          ToString[Lookup[run, "ExitCode", "?"]]|>]];
    out = Lookup[run, "StandardOutput", ""];
    If[!StringQ[out] || out === "",
      Return[<|"Status" -> "Failed", "Reason" -> "EmptyOutput"|>]];
    data = Quiet @ Check[
      Developer`ReadRawJSONString[out], $Failed];
    If[!AssociationQ[data],
      Return[<|"Status" -> "Failed",
        "Reason" -> "JSONParseFailed"|>]];
    models = Lookup[data, "models", {}];
    If[!ListQ[models],
      Return[<|"Status" -> "Failed", "Reason" -> "NoModelsArray"|>]];
    slugs = Cases[models,
      m_Association /;
        (StringQ[Lookup[m, "slug", Missing[]]] &&
         Lookup[m, "visibility", "list"] =!= "hide") :>
        Lookup[m, "slug"]];
    slugs = DeleteDuplicates @ Select[slugs, StringQ];
    <|"Status" -> "OK", "ModelIds" -> slugs|>
  ];
iSVFetchCodexModelIds[___] :=
  <|"Status" -> "Failed", "Reason" -> "BadArguments"|>;

(* === Public API: SourceVaultModelEndpointStatus === *)

SourceVaultModelEndpointStatus[] :=
  Module[{eps, status},
    eps = SourceVault`$SourceVaultModelEndpoints;
    If[!AssociationQ[eps],
      Return[<|"Status" -> "Failed",
        "Reason" -> "NoEndpointConfig"|>]];
    status = Association @ KeyValueMap[
      Function[{provider, cfg},
        Module[{url, probe},
          (* Local provider: probe the URL actually used,
             i.e. $ClaudePrivateModel url has priority. *)
          url = If[Lookup[cfg, "Kind", ""] === "Local",
            iSVResolveLocalEndpoint[provider, Null, cfg],
            Lookup[cfg, "ModelsURL", ""]];
          probe = If[StringQ[url] && url =!= "",
            iSVProbeEndpoint[url],
            <|"Reachable" -> False,
              "StatusCode" -> Missing["NoURL"]|>];
          provider -> <|
            "Endpoint" -> url,
            "Kind" -> Lookup[cfg, "Kind", "Unknown"],
            "Status" -> If[Lookup[probe, "Reachable", False],
              "Online", "Offline"],
            "StatusCode" -> Lookup[probe, "StatusCode", Missing[]]|>]],
      eps];
    <|"Status" -> "OK",
      "CheckedAt" -> DateString[DateObject[]],
      "Endpoints" -> status|>
  ];

(* read ClaudeCode`$ClaudePrivateModel via Symbol (avoids a
   hard dependency on claudecode.wl being loaded).
   Form: {provider, model, url}. Returns Missing[] if unset. *)
iSVPrivateModelTuple[] :=
  Module[{v},
    If[Length[Names["ClaudeCode`$ClaudePrivateModel"]] === 0,
      Return[Missing["NotDefined"]]];
    v = Quiet @ Symbol["ClaudeCode`$ClaudePrivateModel"];
    If[MatchQ[v, {_String, _String, _String}], v,
      Missing["NotConfigured"]]
  ];

(* resolve the effective /v1/models URL for a local provider.
   Priority: (1) explicit Endpoint override (caller) ->
   (2) $ClaudePrivateModel url, if its provider matches ->
   (3) $SourceVaultModelEndpoints config.
   $ClaudePrivateModel wins over the fixed 127.0.0.1:1234
   default because the user may point LM Studio elsewhere. *)
iSVResolveLocalEndpoint[provider_String, explicit_, cfg_Association] :=
  Module[{priv, privProvider, privUrl, base},
    If[StringQ[explicit] && explicit =!= "",
      Return[explicit]];
    priv = iSVPrivateModelTuple[];
    If[MatchQ[priv, {_String, _String, _String}],
      privProvider = priv[[1]];
      privUrl = priv[[3]];
      If[privProvider === provider &&
          StringQ[privUrl] && privUrl =!= "",
        base = StringReplace[privUrl,
          ("/v1/models" | "/v1" | "/") ~~ EndOfString -> ""];
        Return[base <> "/v1/models"]]];
    Lookup[cfg, "ModelsURL", ""]
  ];

(* resolve a local LLM server API key via NBAccess.
   API keys are NBAccess's responsibility: SourceVault never
   reads SystemCredential directly and never accepts a raw key
   string. NBGetLocalLLMAPIKey requires AccessLevel >= 1.0, so
   a local PrivacySpec is passed explicitly (api-key-handling
   skill pattern). Returns a key string, or Missing[] when no
   key is registered (anonymous request is then attempted). *)
iSVResolveLocalKey[provider_String, url_String] :=
  Module[{key},
    key = Quiet @ Check[
      NBAccess`NBGetLocalLLMAPIKey[provider, url,
        NBAccess`PrivacySpec -> <|"AccessLevel" -> 1.0|>],
      $Failed];
    If[StringQ[key] && key =!= "", key, Missing["NoLocalKey"]]
  ];

(* === Public API: SourceVaultDetectLocalModels === *)

Options[SourceVaultDetectLocalModels] = {
  "Provider" -> "lmstudio",
  "Endpoint" -> Automatic
};

SourceVaultDetectLocalModels[opts:OptionsPattern[]] :=
  Module[{provider, eps, cfg, explicit, url, baseUrl, key,
          headers, fetch},
    provider = OptionValue["Provider"];
    eps = SourceVault`$SourceVaultModelEndpoints;
    cfg = If[AssociationQ[eps], Lookup[eps, provider, <||>], <||>];
    explicit = OptionValue["Endpoint"];
    If[explicit === Automatic, explicit = Null];
    (* $ClaudePrivateModel url takes priority over the fixed
       config default when its provider matches. *)
    url = iSVResolveLocalEndpoint[provider, explicit, cfg];
    If[!StringQ[url] || url === "",
      Return[<|"Status" -> "Failed",
        "Reason" -> "NoEndpoint", "Provider" -> provider|>]];
    (* server base URL for credential lookup: strip the
       /v1/models suffix so NBGetLocalLLMAPIKey sees the same
       host:port the user registered. *)
    baseUrl = StringReplace[url,
      "/v1/models" ~~ EndOfString -> ""];
    (* optional bearer auth resolved through NBAccess. The key
       is sent only in a header, never in the URL. *)
    key = iSVResolveLocalKey[provider, baseUrl];
    headers = If[StringQ[key],
      {"Authorization" -> "Bearer " <> key}, {}];
    fetch = iSVFetchModelIds[url, headers];
    If[Lookup[fetch, "Status", ""] =!= "OK",
      Return[<|"Status" -> "Offline",
        "Provider" -> provider,
        "Endpoint" -> url,
        "Reason" -> Lookup[fetch, "Reason", "Unknown"],
        "Hint" -> If[Lookup[fetch, "Reason", ""] === "HTTPStatus401",
          "Server requires auth; register a key via " <>
          "NBAccess`NBStoreLocalLLMAPIKey[provider, url, name, key].",
          Missing["NotApplicable"]]|>]];
    <|"Status" -> "OK",
      "Provider" -> provider,
      "Endpoint" -> url,
      "Models" -> Lookup[fetch, "ModelIds", {}]|>
  ];

(* merge auto-fetched entries into existing registry entries.
   Existing seed/manual entries are kept; an auto-fetch entry
   replaces a prior auto-fetch entry with the same
   {Provider, ModelId}. *)
(* ============================================================
   Stage 9 P1.5: fetch \:3057\:305f\:30e2\:30c7\:30eb\:3078\:306e Intent/Class \:63a8\:8ad6\:4ed8\:4e0e\:3001
   \:540c\:7cfb\:6700\:5927\:30d0\:30fc\:30b8\:30e7\:30f3\:81ea\:52d5\:9078\:629e\:3001claudecode \:3078\:306e \:30df\:30e9\:30fc\:3002

   \:8a2d\:8a08 (rule 03): \:30e2\:30c7\:30eb ID \:3092\:30cf\:30fc\:30c9\:30b3\:30fc\:30c9\:3057\:306a\:3044\:3002/v1/models
   \:304c\:8fd4\:3059 ID \:3092\:89e3\:91c8\:3057\:3066 intent \:306b\:5272\:308a\:5f53\:3066\:308b\:3002\:30d0\:30fc\:30b8\:30e7\:30f3\:756a\:53f7\:306f
   ID \:304b\:3089\:62bd\:51fa\:3057\:3066\:6570\:5024\:6bd4\:8f03\:3057\:3001\:540c family \:306e\:6700\:5927\:7248\:3092 heavy \:7b49\:306b
   \:6607\:683c\:3059\:308b\:3002preview/beta/rc \:30b5\:30d5\:30a3\:30c3\:30af\:30b9\:4ed8\:304d\:306f\:5b89\:5b9a\:7248\:9078\:629e\:304b\:3089\:9664\:5916\:3002
   ============================================================ *)

(* model id \:304b\:3089\:30d5\:30a1\:30df\:30ea\:540d\:3068\:30d0\:30fc\:30b8\:30e7\:30f3\:3092\:62bd\:51fa\:3002
   "claude-opus-4-8"      -> {"claude-opus", {4,8}, False}
   "claude-opus-4-8-1m"   -> {"claude-opus", {4,8}, True (suffix\:6709)}
   "claude-sonnet-4-6"    -> {"claude-sonnet", {4,6}, False}
   "gpt-5.5"              -> {"gpt", {5,5}, False}
   \:623b\:308a\:5024 {family_String, version_List, hasSuffix_Bool}\:3002
   \:89e3\:91c8\:4e0d\:80fd\:306a\:3089 {id, {}, False}\:3002 *)
iSVParseModelVersion[id_String] :=
  Module[{m, family, nums, rest, hasSuffix},
    (* \:6570\:5b57\:3068\:30c9\:30c3\:30c8/\:30cf\:30a4\:30d5\:30f3\:3067\:533a\:5207\:3089\:308c\:305f\:30d0\:30fc\:30b8\:30e7\:30f3\:90e8\:3092\:63a2\:3059 *)
    m = StringCases[id,
      RegularExpression["^([a-zA-Z][a-zA-Z]*(?:-[a-zA-Z]+)*)-(\\d+(?:[.-]\\d+)*)(.*)$"]
        :> {"$1", "$2", "$3"}];
    If[Length[m] === 0,
      Return[{id, {}, False}]];
    {family, rest, hasSuffix} = First[m];
    nums = ToExpression /@ StringSplit[rest, {".", "-"}];
    nums = Select[nums, IntegerQ];
    (* \:65e5\:4ed8\:30b5\:30d5\:30a3\:30c3\:30af\:30b9 (YYYYMMDD = 5 \:6841\:4ee5\:4e0a) \:306f\:30d0\:30fc\:30b8\:30e7\:30f3\:6bd4\:8f03\:304b\:3089\:9664\:5916\:3059\:308b\:3002
       \:4f8b: claude-opus-4-5-20251101 \:306f {4,5} \:3068\:3057\:3066\:6271\:3044\:3001\:65e5\:4ed8 20251101 \:306f
       \:7121\:8996\:3059\:308b\:3002\:3053\:308c\:304c\:7121\:3044\:3068 sortkey \:304c\:6841\:3042\:3075\:308c\:3057\:3066 4-5-\:65e5\:4ed8\:7248\:304c
       4-8 \:3088\:308a\:5927\:304d\:3044\:3068\:8aa4\:5224\:5b9a\:3055\:308c\:308b\:30d0\:30b0\:304c\:51fa\:3066\:3044\:305f\:3002
       \:65e5\:4ed8\:4ed8\:304d ID \:306f\:30d4\:30f3\:7559\:3081\:7248\:306a\:306e\:3067 hasSuffix=True \:6271\:3044\:306b\:3057\:3001
       \:30a8\:30a4\:30ea\:30a2\:30b9 (claude-opus-4-8 \:306e\:3088\:3046\:306a\:65e5\:4ed8\:7121\:3057) \:3092\:6700\:65b0\:3068\:3057\:3066\:512a\:5148\:3059\:308b\:3002 *)
    If[AnyTrue[nums, # >= 10000 &], hasSuffix = hasSuffix <> "datestamp"];
    nums = Select[nums, # < 10000 &];
    (* suffix \:306b\:82f1\:5b57 (preview/beta/rc/1m \:7b49) \:307e\:305f\:306f\:65e5\:4ed8\:304c\:3042\:308c\:3070 hasSuffix=True *)
    hasSuffix = StringMatchQ[hasSuffix, RegularExpression[".*[a-zA-Z].*"]];
    {family, nums, hasSuffix}];
iSVParseModelVersion[_] := {"", {}, False};

(* model id \:304b\:3089 intent \:3068 class \:3092\:63a8\:8ad6\:3059\:308b\:3002
   provider \:3054\:3068\:306b\:3001\:30d5\:30a1\:30df\:30ea\:540d\:3067 intent \:3092\:5272\:308a\:5f53\:3066\:308b\:3002 *)
iSVInferModelIntentClass[provider_String, id_String] :=
  Module[{family, lc},
    {family} = Take[iSVParseModelVersion[id], 1];
    lc = ToLowerCase[id];
    Which[
      (* Anthropic / claudecode: opus=heavy(code-heavy), sonnet=extraction,
         haiku=light *)
      StringContainsQ[lc, "opus"],
        <|"Intent" -> If[provider === "claudecode", "code-heavy", "heavy"],
          "Class" -> If[provider === "claudecode", "Heavy-Local", "Heavy-Cloud"],
          "Capabilities" -> {"Reasoning", "Code", "ToolUse"}|>,
      StringContainsQ[lc, "sonnet"],
        <|"Intent" -> "extraction",
          "Class" -> If[provider === "claudecode", "Heavy-Local", "Heavy-Cloud"],
          "Capabilities" -> {"Reasoning", "Code"}|>,
      StringContainsQ[lc, "haiku"],
        <|"Intent" -> "light",
          "Class" -> "Light-Cloud",
          "Capabilities" -> {"Reasoning"}|>,
      (* OpenAI: gpt-5 \:7cfb = heavy (\:305f\:3060\:3057 gpt-oss \:306f\:30ed\:30fc\:30ab\:30eb\:306a\:306e\:3067\:9664\:5916) *)
      StringContainsQ[lc, "gpt"] && !StringContainsQ[lc, "gpt-oss"],
        <|"Intent" -> "heavy",
          "Class" -> "Heavy-Cloud",
          "Capabilities" -> {"Reasoning", "Code", "ToolUse"}|>,
      (* \:30ed\:30fc\:30ab\:30eb provider (lmstudio \:7b49) \:306e\:30e2\:30c7\:30eb\:306f extraction \:306b\:5272\:308a\:5f53\:3066\:308b\:3002
         qwen / llama / gemma / mistral \:7b49\:30ed\:30fc\:30ab\:30eb\:30e2\:30c7\:30eb\:306f\:540d\:524d\:304c\:591a\:69d8\:306a\:306e\:3067\:3001
         provider \:3067\:5224\:5b9a\:3059\:308b\:3002\:3053\:308c\:304c\:7121\:3044\:3068 Refresh \:3057\:3066\:3082 intent \:304c Null \:306e\:307e\:307e
         extraction \:306b\:6607\:683c\:3055\:308c\:305a\:3001seed \:30c7\:30d5\:30a9\:30eb\:30c8 (qwen-local) \:304c\:6b8b\:308b (B-1 \:3092\:59a8\:3052\:308b)\:3002 *)
      provider === "lmstudio" || StringContainsQ[lc, "qwen"] ||
        StringContainsQ[lc, "llama"] || StringContainsQ[lc, "gemma"] ||
        StringContainsQ[lc, "mistral"] || StringContainsQ[lc, "gpt-oss"],
        <|"Intent" -> "extraction",
          "Class" -> "Local",
          "Capabilities" -> {"Reasoning"}|>,
      (* \:305d\:308c\:4ee5\:5916\:306f intent \:672a\:78ba\:5b9a (\:4e00\:89a7\:306b\:306f\:6b8b\:308b\:304c\:6607\:683c\:3055\:308c\:306a\:3044) *)
      True,
        <|"Intent" -> Null, "Class" -> "Unknown",
          "Capabilities" -> {"Reasoning"}|>]];
iSVInferModelIntentClass[_, _] := <|"Intent" -> Null, "Class" -> "Unknown"|>;

(* \:30d0\:30fc\:30b8\:30e7\:30f3\:756a\:53f7\:30ea\:30b9\:30c8\:306e\:8f9e\:66f8\:5f0f\:6bd4\:8f03\:3002a > b \:306a\:3089 1, a < b \:306a\:3089 -1, \:7b49\:3057\:3044\:306a\:3089 0 *)
iSVCompareVersions[a_List, b_List] :=
  Module[{la = Length[a], lb = Length[b], n, i, av, bv},
    n = Max[la, lb];
    Catch[
      Do[
        av = If[i <= la, a[[i]], 0];
        bv = If[i <= lb, b[[i]], 0];
        Which[av > bv, Throw[1], av < bv, Throw[-1]],
        {i, n}];
      0]];
iSVCompareVersions[_, _] := 0;

(* fetched \:30a8\:30f3\:30c8\:30ea\:7fa4\:306b intent/class \:3092\:4ed8\:4e0e\:3057\:3001\:540c provider\[Times]family\[Times]intent \:3067
   \:6700\:5927\:30d0\:30fc\:30b8\:30e7\:30f3\:306e\:3082\:306e\:3060\:3051\:3092\:300c\:6b63\:898f intent \:30a8\:30f3\:30c8\:30ea\:300d\:306b\:6607\:683c\:3059\:308b\:3002
   - \:5168 fetched \:30a8\:30f3\:30c8\:30ea\:306f "Availability"->"Available" \:306e\:5019\:88dc\:3068\:3057\:3066\:6b8b\:3059
     (Intent=Null \:306e\:307e\:307e\:3002SourceVaultListModels \:3067\:4e00\:89a7\:306b\:51fa\:308b)
   - \:5404 (provider, intent) \:306b\:3064\:3044\:3066\:6700\:5927\:30d0\:30fc\:30b8\:30e7\:30f3\:306e 1 \:4ef6\:306b Intent \:3092\:8a2d\:5b9a
   - preview/beta/rc/suffix \:4ed8\:304d (hasSuffix=True) \:306f intent \:6607\:683c\:306e\:5bfe\:8c61\:5916
     (\:4e00\:89a7\:306b\:306f\:6b8b\:308b\:304c heavy \:7b49\:306b\:306f\:9078\:3070\:308c\:306a\:3044) *)
iSVAssignIntentsToFetched[fetched_List] :=
  Module[{withMeta, byKey, promoted, base},
    (* (1) \:5404\:30a8\:30f3\:30c8\:30ea\:306b family/version/suffix \:3068\:63a8\:8ad6 intent \:3092\:4ed8\:4e0e *)
    withMeta = Map[
      Function[e,
        Module[{provider, id, pv, family, version, hasSuffix, infer},
          provider = Lookup[e, "Provider", ""];
          id = Lookup[e, "ModelId", ""];
          pv = iSVParseModelVersion[id];
          {family, version, hasSuffix} = pv;
          infer = iSVInferModelIntentClass[provider, id];
          <|"Entry" -> e, "Provider" -> provider, "ModelId" -> id,
            "Family" -> family, "Version" -> version,
            "HasSuffix" -> hasSuffix,
            "InferIntent" -> Lookup[infer, "Intent", Null],
            "InferClass" -> Lookup[infer, "Class", "Unknown"],
            "InferCaps" -> Lookup[infer, "Capabilities", {"Reasoning"}]|>]],
      fetched];
    (* (2) intent \:304c\:63a8\:8ad6\:3067\:304d\:4e14\:3064 suffix \:7121\:3057\:306e\:3082\:306e\:3092 (provider,intent) \:3067
       \:30b0\:30eb\:30fc\:30d4\:30f3\:30b0\:3057\:3001\:6700\:5927\:30d0\:30fc\:30b8\:30e7\:30f3\:3092\:9078\:3076 *)
    byKey = GroupBy[
      Select[withMeta,
        StringQ[#["InferIntent"]] && !TrueQ[#["HasSuffix"]] &],
      {#["Provider"], #["InferIntent"]} &];
    promoted = Association @ KeyValueMap[
      Function[{key, group},
        Module[{best},
          best = First @ SortBy[group,
            -iSVVersionSortKey[#["Version"]] &];
          key -> best]],
      byKey];
    (* (3) base: \:5168 fetched \:3092 Intent=Null \:306e\:307e\:307e (\:4e00\:89a7\:7528)\:3002
       promoted \:306b\:8a72\:5f53\:3059\:308b (provider,modelid) \:306f Intent \:4ed8\:304d\:306b\:7f6e\:63db *)
    base = Map[
      Function[m,
        Module[{e = m["Entry"], key, isPromoted},
          key = {m["Provider"], m["InferIntent"]};
          isPromoted = StringQ[m["InferIntent"]] &&
            KeyExistsQ[promoted, key] &&
            promoted[key]["ModelId"] === m["ModelId"] &&
            !TrueQ[m["HasSuffix"]];
          If[isPromoted,
            <|e,
              "Intent" -> m["InferIntent"],
              "Class" -> m["InferClass"],
              "Capabilities" -> m["InferCaps"],
              "Kind" -> "Model",
              "PolicySource" -> "auto-fetch:max-version"|>,
            (* \:975e\:6607\:683c\:30a8\:30f3\:30c8\:30ea\:306f Class \:3060\:3051\:63a8\:8ad6\:5024\:3067\:88dc\:5b8c\:3001Intent \:306f Null \:306e\:307e\:307e *)
            <|e, "Class" -> m["InferClass"]|>]]],
      withMeta];
    base];
iSVAssignIntentsToFetched[_] := {};

(* SortBy \:7528\:306e\:6570\:5024\:30ad\:30fc: \:30d0\:30fc\:30b8\:30e7\:30f3 {4,8} \:3092 4*1000+8 \:306e\:3088\:3046\:306a\:5358\:8abf\:5024\:306b\:3002
   \:5404\:6841\:3092 1000 \:9032\:3067\:91cd\:307f\:4ed8\:3051 (\:5341\:5206\:5927\:304d\:3044\:57fa\:6570)\:3002 *)
iSVVersionSortKey[version_List] :=
  Module[{v = Select[version, IntegerQ]},
    If[v === {}, 0,
      Total @ MapIndexed[
        #1 * 1000^(Length[v] - First[#2]) &, v]]];
iSVVersionSortKey[_] := 0;

(* anthropic provider \:306e auto-fetch \:30a8\:30f3\:30c8\:30ea\:3092 claudecode provider \:306b
   \:30df\:30e9\:30fc\:3059\:308b\:3002Claude Code CLI \:306f\:7121\:8ab2\:91d1\:3060\:304c claude model list \:304c\:7121\:3044\:306e\:3067\:3001
   anthropic /v1/models \:3067\:5f97\:305f\:6700\:65b0\:30e2\:30c7\:30eb ID \:3092\:305d\:306e\:307e\:307e claudecode \:306e
   \:5019\:88dc\:3068\:3059\:308b (claude --model <id> \:3067\:4f7f\:3048\:308b)\:3002
   intent \:306f claudecode \:7528\:306b\:518d\:30de\:30c3\:30d4\:30f3\:30b0 (opus->code-heavy)\:3002 *)
iSVMirrorAnthropicToClaudecode[entries_List] :=
  Module[{anthropicFetched, mirrored},
    anthropicFetched = Select[entries,
      Lookup[#, "Provider", ""] === "anthropic" &&
      Lookup[#, "Source", ""] === "auto-fetch" &];
    mirrored = Map[
      Function[e,
        Module[{id = Lookup[e, "ModelId", ""], infer},
          infer = iSVInferModelIntentClass["claudecode", id];
          <|e,
            "Provider" -> "claudecode",
            "Intent" -> Lookup[e, "Intent", Null] /.
              (* anthropic intent \:3092 claudecode intent \:306b\:5909\:63db *)
              {"heavy" -> "code-heavy"},
            "Class" -> Lookup[infer, "Class", "Heavy-Local"],
            "Endpoint" -> "claude-code-cli",
            "Source" -> "auto-fetch:mirror-anthropic",
            "PolicySource" -> "auto-fetch:mirror-anthropic"|>]],
      anthropicFetched];
    mirrored];
iSVMirrorAnthropicToClaudecode[_] := {};

iSVMergeModelRegistry[existing_List, fetched_List] :=
  Module[{kept, fetchedKeys, merged},
    fetchedKeys = Map[
      {Lookup[#, "Provider", ""], Lookup[#, "ModelId", ""]} &,
      fetched];
    kept = Select[existing,
      Function[e,
        Lookup[e, "Source", ""] =!= "auto-fetch" ||
        !MemberQ[fetchedKeys,
          {Lookup[e, "Provider", ""], Lookup[e, "ModelId", ""]}]]];
    merged = Join[kept, fetched];
    merged
  ];

(* === Public API: SourceVaultRefreshModelRegistry === *)

Options[SourceVaultRefreshModelRegistry] = {
  "Providers" -> All,
  "IncludeCloud" -> Automatic,
  "DryRun" -> False
};

SourceVaultRefreshModelRegistry[opts:OptionsPattern[]] :=
  Module[{eps, providers, includeCloud, dryRun, ts, fetched,
          perProvider, existing, merged, savedPath},
    iEnsureRoots[];
    eps = SourceVault`$SourceVaultModelEndpoints;
    If[!AssociationQ[eps],
      Return[<|"Status" -> "Failed",
        "Reason" -> "NoEndpointConfig"|>]];
    providers = OptionValue["Providers"];
    If[providers === All, providers = Keys[eps]];
    includeCloud = OptionValue["IncludeCloud"];
    dryRun = TrueQ[OptionValue["DryRun"]];
    ts = DateString[DateObject[]];

    fetched = {};
    perProvider = {};

    Scan[
      Function[provider,
        Module[{cfg, kind, url, authProvider, headers,
                result, entries},
          cfg = Lookup[eps, provider, <||>];
          kind = Lookup[cfg, "Kind", "Unknown"];
          url = Lookup[cfg, "ModelsURL", ""];
          authProvider = Lookup[cfg, "AuthProvider", None];

          If[kind === "Cloud" &&
              (includeCloud === False),
            AppendTo[perProvider,
              <|"Provider" -> provider, "Result" -> "Skipped",
                "Reason" -> "CloudExcluded"|>];
            Return[Null, Module]];

          (* CodexCLI provider: the ChatGPT Codex model catalog is
             obtained from `codex debug models`, not an HTTP
             endpoint. Fetch here and skip the URL-based path. *)
          If[kind === "CodexCLI",
            Module[{exe, cresult, centries},
              exe = Lookup[cfg, "Exe", "codex"];
              cresult = iSVFetchCodexModelIds[
                If[StringQ[exe], exe, "codex"]];
              If[Lookup[cresult, "Status", ""] =!= "OK",
                AppendTo[perProvider,
                  <|"Provider" -> provider, "Result" -> "Failed",
                    "Reason" ->
                      Lookup[cresult, "Reason", "Unknown"]|>];
                Return[Null, Module]];
              centries = Map[
                Function[mid,
                  <|"Provider" -> provider,
                    "ModelId" -> mid,
                    "Endpoint" -> "codex-cli:debug-models",
                    "Class" -> "Heavy-Cloud",
                    "Availability" -> "Available",
                    "Source" -> "auto-fetch",
                    "Intent" -> Null,
                    "FetchedAt" -> ts|>],
                Lookup[cresult, "ModelIds", {}]];
              fetched = Join[fetched, centries];
              AppendTo[perProvider,
                <|"Provider" -> provider, "Result" -> "OK",
                  "ModelCount" -> Length[centries]|>]];
            Return[Null, Module]];

          (* Cloud provider: API \:30ad\:30fc\:3092\:4f7f\:3046\:51e6\:7406\:306f NBAccess \:306b\:9589\:3058\:8fbc\:3081\:308b\:3002
             NBListProviderModels \:306f\:5185\:90e8\:3067 SystemCredential \:304b\:3089\:30ad\:30fc\:3092\:8aad\:307f\:3001
             \:30e2\:30c7\:30eb\:540d\:30ea\:30b9\:30c8 (\:79d8\:533f\:6027\:306a\:3057) \:3060\:3051\:3092\:8fd4\:3059\:306e\:3067\:3001SourceVault \:5074\:306f
             PrivacySpec / AccessLevel \:3092\:6307\:5b9a\:305b\:305a\:306b\:547c\:3079\:308b (\:8a2d\:8a08\:65b9\:91dd)\:3002 *)
          If[kind === "Cloud",
            Module[{listResult, cloudIds},
              listResult = Quiet @ Check[
                NBAccess`NBListProviderModels[
                  If[StringQ[authProvider], authProvider, provider]],
                <|"Status" -> "Failed", "Models" -> {}|>];
              If[Lookup[listResult, "Status", ""] =!= "OK",
                AppendTo[perProvider,
                  <|"Provider" -> provider,
                    "Result" -> If[
                      Lookup[listResult, "Status", ""] === "NoAPIKey",
                      "Skipped", "Failed"],
                    "Reason" -> Lookup[listResult, "Reason",
                      Lookup[listResult, "Status", "Unknown"]]|>];
                Return[Null, Module]];
              cloudIds = Lookup[listResult, "Models", {}];
              entries = Map[
                Function[mid,
                  <|"Provider" -> provider,
                    "ModelId" -> mid,
                    "Endpoint" -> url,
                    "Class" -> "Unknown",
                    "Availability" -> "Available",
                    "Source" -> "auto-fetch",
                    "Intent" -> Null,
                    "FetchedAt" -> ts|>],
                Select[cloudIds, StringQ]];
              fetched = Join[fetched, entries];
              AppendTo[perProvider,
                <|"Provider" -> provider, "Result" -> "OK",
                  "ModelCount" -> Length[entries]|>]];
            Return[Null, Module]];

          (* local provider: $ClaudePrivateModel url takes
             priority over the config default; key resolved via
             NBAccess (NBGetLocalLLMAPIKey). API keys are
             NBAccess's responsibility; the key is sent only as
             a header and is never logged. *)
          headers = {};
          If[kind === "Local",
            url = iSVResolveLocalEndpoint[provider, Null, cfg];
            Module[{baseUrl, localKey},
              baseUrl = StringReplace[url,
                "/v1/models" ~~ EndOfString -> ""];
              localKey = iSVResolveLocalKey[provider, baseUrl];
              If[StringQ[localKey],
                headers = {"Authorization" ->
                  "Bearer " <> localKey}]]];

          If[!StringQ[url] || url === "",
            AppendTo[perProvider,
              <|"Provider" -> provider, "Result" -> "Skipped",
                "Reason" -> "NoEndpoint"|>];
            Return[Null, Module]];

          result = iSVFetchModelIds[url, headers];
          If[Lookup[result, "Status", ""] =!= "OK",
            AppendTo[perProvider,
              <|"Provider" -> provider, "Result" -> "Failed",
                "Reason" -> Lookup[result, "Reason", "Unknown"]|>];
            Return[Null, Module]];

          entries = Map[
            Function[mid,
              <|"Provider" -> provider,
                "ModelId" -> mid,
                "Endpoint" -> url,
                "Class" -> "Unknown",
                "Availability" -> "Available",
                "Source" -> "auto-fetch",
                "Intent" -> Null,
                "FetchedAt" -> ts|>],
            Lookup[result, "ModelIds", {}]];
          fetched = Join[fetched, entries];
          AppendTo[perProvider,
            <|"Provider" -> provider, "Result" -> "OK",
              "ModelCount" -> Length[entries]|>]]],
      providers];

    (* Stage 9 P1.5: fetch \:3057\:305f\:30e2\:30c7\:30eb\:306b intent/class \:3092\:63a8\:8ad6\:4ed8\:4e0e\:3057\:3001
       \:540c family \:6700\:5927\:30d0\:30fc\:30b8\:30e7\:30f3\:3092 intent \:306b\:6607\:683c\:3059\:308b\:3002\:3055\:3089\:306b anthropic \:306e
       \:6700\:65b0\:30e2\:30c7\:30eb\:3092 claudecode (\:7121\:8ab2\:91d1 CLI) provider \:306b\:30df\:30e9\:30fc\:3059\:308b\:3002 *)
    fetched = iSVAssignIntentsToFetched[fetched];
    fetched = Join[fetched, iSVMirrorAnthropicToClaudecode[fetched]];

    (* read the existing compiled registry from the SAME json path
       that SourceVaultResolve / SourceVaultListModels read. The
       legacy iCompiledLoadModelRegistry (.wl) path is not used:
       refresh and resolve must agree on one storage location, or
       a refresh never becomes visible to resolve. When no compiled
       registry exists yet, fall back to the json seed registry
       (iBootstrapDefaultSeeds has already created it). *)
    existing = Module[{compiledPath, seedPath, c},
      compiledPath = iCompiledPath["model-registry", "public"];
      c = iLoadRegistryEntries[compiledPath];
      If[ListQ[c] && c =!= {}, c,
        seedPath = iSeedPath["model-registry"];
        Module[{s = iLoadRegistryEntries[seedPath]},
          If[ListQ[s], s, {}]]]];
    merged = iSVMergeModelRegistry[existing, fetched];

    If[dryRun,
      Return[<|"Status" -> "DryRun",
        "FetchedCount" -> Length[fetched],
        "PerProvider" -> perProvider,
        "WouldMergeTotal" -> Length[merged]|>]];

    (* save to the json compiled registry path. iSaveRegistryEntries
       is the writer used by the rest of the Stage 6b registry code;
       it keeps refresh output readable by SourceVaultResolve. *)
    Module[{saveResult},
      saveResult = iSaveRegistryEntries[
        iCompiledPath["model-registry", "public"], merged];
      savedPath = Lookup[saveResult, "Path",
        iCompiledPath["model-registry", "public"]]];

    <|"Status" -> "OK",
      "RefreshedAt" -> ts,
      "FetchedCount" -> Length[fetched],
      "RegistryTotal" -> Length[merged],
      "PerProvider" -> perProvider,
      "RegistryPath" -> savedPath|>
  ];

(* ============================================================
   Next phase 4: Notebook UUID embedding
   ------------------------------------------------------------
   Embeds a stable UUID into a notebook's TaggingRules under
   SourceVault > NotebookUUID. This is the most reliable anchor
   for file-move tracking (SourceVaultRelinkSources): it survives
   both renaming and content edits. The UUID lives in the
   notebook's own TaggingRules (same namespace as Step 1's
   CloudPublishable), so it travels with the file.
   Reading is cheap (TaggingRules only); writing opens the file
   invisibly via NBFileOpen, sets the rule, saves, and closes.
   ============================================================ *)

(* read the embedded UUID from a notebook file.
   Returns the UUID string, or Missing[] if none is set. *)
SourceVaultNotebookUUID[path_String] :=
  Module[{abs, nb, uuid},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[Missing["FileNotFound"]]];
    nb = Quiet @ Check[NBAccess`NBFileOpen[abs], $Failed];
    If[Head[nb] =!= NotebookObject,
      Return[Missing["OpenFailed"]]];
    uuid = Quiet @ NBAccess`NBGetTaggingRule[nb,
      {"SourceVault", "NotebookUUID"}];
    Quiet @ NBAccess`NBFileClose[nb];
    If[StringQ[uuid] && uuid =!= "", uuid, Missing["NoUUID"]]
  ];

(* ensure a notebook has an embedded UUID; create one if absent.
   Returns <|"Status", "UUID", "Created", "Path"|>.
   Created -> True means a new UUID was written this call. *)
Options[SourceVaultEnsureNotebookUUID] = {
  "Force" -> False
};

SourceVaultEnsureNotebookUUID[path_String, opts:OptionsPattern[]] :=
  Module[{abs, force, nb, existing, uuid, created},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[<|"Status" -> "Failed",
        "Reason" -> "FileNotFound", "Path" -> abs|>]];
    force = TrueQ[OptionValue["Force"]];
    nb = Quiet @ Check[NBAccess`NBFileOpen[abs], $Failed];
    If[Head[nb] =!= NotebookObject,
      Return[<|"Status" -> "Failed",
        "Reason" -> "OpenFailed", "Path" -> abs|>]];
    existing = Quiet @ NBAccess`NBGetTaggingRule[nb,
      {"SourceVault", "NotebookUUID"}];
    Which[
      StringQ[existing] && existing =!= "" && !force,
        uuid = existing; created = False,
      True,
        uuid = "nbuuid-" <> StringReplace[
          CreateUUID[], "-" -> ""];
        Quiet @ NBAccess`NBSetTaggingRule[nb,
          {"SourceVault", "NotebookUUID"}, uuid];
        Quiet @ NBAccess`NBFileSave[nb, None];
        created = True
    ];
    Quiet @ NBAccess`NBFileClose[nb];
    <|"Status" -> "OK",
      "Path" -> abs,
      "UUID" -> uuid,
      "Created" -> created|>
  ];

(* ensure UUIDs across a folder of notebooks.
   Returns counts of created vs already-present. *)
Options[SourceVaultEnsureNotebookUUIDFolder] = {
  "Recursive" -> True,
  "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"},
  "MaxFileSizeMB" -> Automatic
};

SourceVaultEnsureNotebookUUIDFolder[dir_String,
    opts:OptionsPattern[]] :=
  Module[{abs, recursive, excludes, maxMB, files, created = 0,
          existed = 0, skipped = 0, failed = 0, details = {}},
    abs = ExpandFileName[dir];
    If[!DirectoryQ[abs],
      Return[<|"Status" -> "Failed",
        "Reason" -> "DirectoryNotFound", "Path" -> abs|>]];
    recursive = TrueQ[OptionValue["Recursive"]];
    excludes = OptionValue["ExcludePatterns"];
    maxMB = OptionValue["MaxFileSizeMB"];
    If[maxMB === Automatic, maxMB = iSVMaxFileSizeMB[]];
    files = If[recursive,
      FileNames["*.nb", abs, Infinity],
      FileNames["*.nb", abs]];
    files = Select[files, Function[f,
      With[{name = FileNameTake[f]},
        !StringContainsQ[name, ".tmp-"] &&
        !AnyTrue[excludes, StringMatchQ[name, #] &]]]];
    Scan[
      Function[f,
        Module[{sizeMB, r},
          sizeMB = Quiet @ Check[
            FileByteCount[f] / 1024.^2, 0];
          (* large files are intentionally skipped, not failed:
             writing TaggingRules would require opening a huge
             notebook (see Stage 8 size threshold). *)
          If[NumericQ[sizeMB] && sizeMB > maxMB,
            skipped = skipped + 1;
            AppendTo[details,
              <|"Path" -> f, "Result" -> "SkippedTooLarge",
                "SizeMB" -> Round[sizeMB]|>];
            Return[Null, Module]];
          r = SourceVaultEnsureNotebookUUID[f];
          Which[
            !AssociationQ[r] || Lookup[r, "Status", ""] =!= "OK",
              failed = failed + 1;
              AppendTo[details,
                <|"Path" -> f, "Result" -> "Failed",
                  "Reason" -> If[AssociationQ[r],
                    Lookup[r, "Reason", "Unknown"], "NoResult"]|>],
            TrueQ[Lookup[r, "Created", False]],
              created = created + 1,
            True,
              existed = existed + 1]]],
      files];
    <|"Status" -> "OK",
      "Directory" -> abs,
      "TotalFiles" -> Length[files],
      "Created" -> created,
      "AlreadyPresent" -> existed,
      "Skipped" -> skipped,
      "Failed" -> failed,
      "Details" -> details|>
  ];




(* ============================================================
   Next phase 1: SourceVaultSync crawler skeleton
   ------------------------------------------------------------
   Freshness token abstraction + source selection + sync plan +
   sync execution. Local notebooks only in this skeleton; web
   sources (ETag / Last-Modified / TTL) are reserved as a shape.
   PrivacyLevel is monotone: a re-index that lowers PrivacyLevel
   is raised back to the previous value via
   SourceVaultSetSnapshotPrivacyLevel, and a warning is recorded.
   ============================================================ *)

(* sync store directory under notebooks/ *)
iSVSyncDir[] :=
  Module[{d},
    d = FileNameJoin[{iNotebooksDir[], "sync"}];
    iEnsureDir[d];
    d
  ];

iSVSyncHistoryPath[] :=
  FileNameJoin[{iSVSyncDir[], "sync-history.jsonl"}];

iSVSyncLastPath[] :=
  FileNameJoin[{iSVSyncDir[], "last-sync.json"}];

iSVMakeSyncId[] :=
  "sync-" <> IntegerString[Round[1000 * AbsoluteTime[]], 36] <>
    "-" <> IntegerString[RandomInteger[{0, 46655}], 36, 3];

(* freshness token: local file -> mtime (UnixTime Integer).
   Web kind is reserved; returns NotImplemented for now. *)
iSVFreshnessToken[descriptor_Association] :=
  Module[{kind, path, mt},
    kind = Lookup[descriptor, "Kind", "Notebook"];
    Which[
      kind === "Notebook" || kind === "LocalFile",
        path = Lookup[descriptor, "Path", ""];
        If[!StringQ[path] || !FileExistsQ[path],
          <|"Kind" -> "LocalFile", "Reachable" -> False,
            "Token" -> Missing["FileNotFound"]|>,
          mt = Quiet @ Check[
            UnixTime[FileDate[path, "Modification"]], Missing["MTimeFailed"]];
          <|"Kind" -> "LocalFile", "Reachable" -> True,
            "Token" -> mt|>],
      kind === "Web",
        <|"Kind" -> "Web", "Reachable" -> Missing["Unknown"],
          "Token" -> Missing["NotImplemented"]|>,
      True,
        <|"Kind" -> kind, "Reachable" -> Missing["Unknown"],
          "Token" -> Missing["UnknownKind"]|>
    ]
  ];

(* current snapshot info for a NotebookRef:
   reads sources/<nbRef>.json -> CurrentSnapshotId,
   then snapshots/<snapId>.json -> SourceMTime / PrivacyLevel. *)
iSVSnapshotInfoForSource[nbRef_String] :=
  Module[{srcPath, srcRec, snapId, snapPath, snapRec},
    srcPath = iNotebookSourcePath[nbRef];
    If[!FileExistsQ[srcPath],
      Return[<|"HasSnapshot" -> False,
        "Reason" -> "SourceRecordNotFound"|>]];
    srcRec = iLoadJSONFromFile[srcPath];
    If[!AssociationQ[srcRec],
      Return[<|"HasSnapshot" -> False,
        "Reason" -> "SourceRecordUnreadable"|>]];
    snapId = Lookup[srcRec, "CurrentSnapshotId", Missing[]];
    If[!StringQ[snapId],
      Return[<|"HasSnapshot" -> False,
        "Reason" -> "NotIndexed"|>]];
    snapPath = iNotebookSnapshotPath[snapId];
    If[!FileExistsQ[snapPath],
      Return[<|"HasSnapshot" -> False,
        "Reason" -> "SnapshotRecordNotFound",
        "SnapshotId" -> snapId|>]];
    snapRec = iLoadJSONFromFile[snapPath];
    If[!AssociationQ[snapRec],
      Return[<|"HasSnapshot" -> False,
        "Reason" -> "SnapshotRecordUnreadable",
        "SnapshotId" -> snapId|>]];
    <|"HasSnapshot" -> True,
      "SnapshotId" -> snapId,
      "SourceMTime" -> Lookup[snapRec, "SourceMTime", Missing[]],
      "PrivacyLevel" -> Lookup[snapRec, "PrivacyLevel", Missing[]]|>
  ];

(* build a source descriptor from a local .nb path *)
iSVSourceDescriptorFromPath[path_String] :=
  Module[{abs},
    abs = ExpandFileName[path];
    <|"Kind" -> "Notebook",
      "NotebookRef" -> iNotebookRefFromPath[abs],
      "Path" -> abs,
      "SymbolicPath" -> iSVSymbolicPath[abs],
      "Title" -> FileBaseName[abs]|>
  ];

(* freshness classification for one descriptor:
   Fresh / Stale / Missing / NeverIndexed *)
iSVCheckSourceFreshness[descriptor_Association] :=
  Module[{tok, snapInfo, curTok, idxTok, freshness},
    tok = iSVFreshnessToken[descriptor];
    If[Lookup[tok, "Reachable", False] =!= True,
      Return[<|"Freshness" -> "Missing",
        "CurrentToken" -> Lookup[tok, "Token", Missing[]],
        "IndexedToken" -> Missing["NotApplicable"],
        "SnapshotId" -> Missing["NotApplicable"],
        "PrivacyLevel" -> Missing["NotApplicable"]|>]];
    curTok = Lookup[tok, "Token", Missing[]];
    snapInfo = iSVSnapshotInfoForSource[
      Lookup[descriptor, "NotebookRef", ""]];
    If[Lookup[snapInfo, "HasSnapshot", False] =!= True,
      Return[<|"Freshness" -> "NeverIndexed",
        "CurrentToken" -> curTok,
        "IndexedToken" -> Missing["NotIndexed"],
        "SnapshotId" -> Missing["NotIndexed"],
        "PrivacyLevel" -> Missing["NotIndexed"]|>]];
    idxTok = Lookup[snapInfo, "SourceMTime", Missing[]];
    freshness = Which[
      IntegerQ[curTok] && IntegerQ[idxTok] && curTok === idxTok,
        "Fresh",
      IntegerQ[curTok] && IntegerQ[idxTok] && curTok =!= idxTok,
        "Stale",
      True, "Stale"   (* indeterminate token -> treat as Stale (safe) *)
    ];
    <|"Freshness" -> freshness,
      "CurrentToken" -> curTok,
      "IndexedToken" -> idxTok,
      "SnapshotId" -> Lookup[snapInfo, "SnapshotId", Missing[]],
      "PrivacyLevel" -> Lookup[snapInfo, "PrivacyLevel", Missing[]]|>
  ];

(* === Public API: SourceVaultSelectSources === *)

Options[SourceVaultSelectSources] = {
  "Scope" -> Automatic,
  "Recursive" -> True,
  "Kind" -> "Notebook",
  "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}
};

SourceVaultSelectSources[opts:OptionsPattern[]] :=
  Module[{root, recursive, kind, excludes, files, descriptors},
    iEnsureRoots[];
    kind = OptionValue["Kind"];
    If[kind =!= "Notebook" && kind =!= "All",
      Return[<|"Status" -> "Failed",
        "Reason" -> "UnsupportedKind",
        "Kind" -> kind,
        "Detail" -> "Skeleton supports Kind -> Notebook only."|>]];
    root = iSVResolveScope[OptionValue["Scope"]];
    If[!StringQ[root] || !DirectoryQ[root],
      Return[<|"Status" -> "Failed", "Reason" -> "ScopeNotFound",
        "Scope" -> root|>]];
    recursive = TrueQ[OptionValue["Recursive"]];
    excludes = OptionValue["ExcludePatterns"];
    files = If[recursive,
      FileNames["*.nb", root, Infinity],
      FileNames["*.nb", root]];
    files = Select[files, Function[f,
      With[{name = FileNameTake[f]},
        !StringContainsQ[name, ".tmp-"] &&
        !AnyTrue[excludes, StringMatchQ[name, #] &]]]];
    descriptors = Map[iSVSourceDescriptorFromPath, files];
    <|"Status" -> "OK",
      "Scope" -> root,
      "Recursive" -> recursive,
      "Kind" -> "Notebook",
      "Count" -> Length[descriptors],
      "Sources" -> descriptors|>
  ];

(* === Public API: SourceVaultSyncPlan === *)

Options[SourceVaultSyncPlan] = {
  "Scope" -> Automatic,
  "Recursive" -> True,
  "Kind" -> "Notebook",
  "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"}
};

SourceVaultSyncPlan[opts:OptionsPattern[]] :=
  Module[{sel, descriptors, planRows, byClass, planDataset},
    iEnsureRoots[];
    sel = SourceVaultSelectSources[
      "Scope" -> OptionValue["Scope"],
      "Recursive" -> OptionValue["Recursive"],
      "Kind" -> OptionValue["Kind"],
      "ExcludePatterns" -> OptionValue["ExcludePatterns"]];
    If[Lookup[sel, "Status", ""] =!= "OK", Return[sel]];
    descriptors = Lookup[sel, "Sources", {}];
    planRows = Map[
      Function[d,
        Module[{fr},
          fr = iSVCheckSourceFreshness[d];
          <|"Title" -> Lookup[d, "Title", ""],
            "Freshness" -> Lookup[fr, "Freshness", "Stale"],
            "CurrentToken" -> Lookup[fr, "CurrentToken", Missing[]],
            "IndexedToken" -> Lookup[fr, "IndexedToken", Missing[]],
            "NotebookRef" -> Lookup[d, "NotebookRef", ""],
            "SnapshotId" -> Lookup[fr, "SnapshotId", Missing[]],
            "Path" -> Lookup[d, "Path", ""],
            "SymbolicPath" -> Lookup[d, "SymbolicPath", {}]|>]],
      descriptors];
    byClass = GroupBy[planRows, #["Freshness"] &];
    planDataset = Dataset[
      Map[KeyTake[#, {"Title", "Freshness",
        "CurrentToken", "IndexedToken", "NotebookRef"}] &,
        planRows]];
    <|"Status" -> "OK",
      "Scope" -> Lookup[sel, "Scope", ""],
      "Total" -> Length[planRows],
      "FreshCount" -> Length[Lookup[byClass, "Fresh", {}]],
      "StaleCount" -> Length[Lookup[byClass, "Stale", {}]],
      "MissingCount" -> Length[Lookup[byClass, "Missing", {}]],
      "NeverIndexedCount" -> Length[Lookup[byClass, "NeverIndexed", {}]],
      "Plan" -> planDataset,
      "PlanRows" -> planRows|>
  ];

(* === Public API: SourceVaultSync === *)

Options[SourceVaultSync] = {
  "Scope" -> Automatic,
  "Recursive" -> True,
  "Kind" -> "Notebook",
  "ExcludePatterns" -> {"*.bak.nb", "Untitled*.nb"},
  "DryRun" -> False,
  "ForceAll" -> False,
  "RefreshSummary" -> False,
  "FallbackToCloud" -> "Deny"
};

SourceVaultSync[opts:OptionsPattern[]] :=
  Module[{plan, planRows, dryRun, forceAll, refreshSummary, fallback,
          targets, syncId, startedAt, refreshed, skipped, failed,
          privacyWarnings, details, summary, ts},
    iEnsureRoots[];
    dryRun = TrueQ[OptionValue["DryRun"]];
    forceAll = TrueQ[OptionValue["ForceAll"]];
    refreshSummary = TrueQ[OptionValue["RefreshSummary"]];
    fallback = OptionValue["FallbackToCloud"];

    plan = SourceVaultSyncPlan[
      "Scope" -> OptionValue["Scope"],
      "Recursive" -> OptionValue["Recursive"],
      "Kind" -> OptionValue["Kind"],
      "ExcludePatterns" -> OptionValue["ExcludePatterns"]];
    If[Lookup[plan, "Status", ""] =!= "OK", Return[plan]];
    planRows = Lookup[plan, "PlanRows", {}];

    (* targets: Stale + NeverIndexed (or all reachable if ForceAll) *)
    targets = If[forceAll,
      Select[planRows, #["Freshness"] =!= "Missing" &],
      Select[planRows,
        MemberQ[{"Stale", "NeverIndexed"}, #["Freshness"]] &]];

    If[dryRun,
      Return[<|"Status" -> "DryRun",
        "Scope" -> Lookup[plan, "Scope", ""],
        "Total" -> Lookup[plan, "Total", 0],
        "WouldRefresh" -> Length[targets],
        "Plan" -> Lookup[plan, "Plan", Missing[]]|>]];

    syncId = iSVMakeSyncId[];
    startedAt = DateString[DateObject[]];
    refreshed = 0; skipped = 0; failed = 0;
    privacyWarnings = {}; details = {};

    Scan[
      Function[row,
        Module[{path, oldPL, idxResult, newSnapId, newPL, raised},
          path = row["Path"];
          oldPL = Module[{v = Lookup[row, "PrivacyLevel", Missing[]]},
            If[NumericQ[v], N[v], Missing[]]];
          idxResult = Quiet @ SourceVaultIndexNotebook[path,
            "ForceReindex" -> True];
          If[AssociationQ[idxResult] &&
              Lookup[idxResult, "Status", ""] === "OK",
            refreshed = refreshed + 1;
            newSnapId = Lookup[idxResult, "SnapshotId", Missing[]];
            (* PrivacyLevel monotone enforcement *)
            raised = False;
            If[StringQ[newSnapId] && NumericQ[oldPL],
              Module[{ni},
                ni = iSVSnapshotInfoForSource[
                  Lookup[row, "NotebookRef", ""]];
                newPL = Module[{v = Lookup[ni, "PrivacyLevel", Missing[]]},
                  If[NumericQ[v], N[v], Missing[]]];
                If[NumericQ[newPL] && newPL < oldPL,
                  Quiet @ SourceVaultSetSnapshotPrivacyLevel[
                    newSnapId, oldPL];
                  raised = True;
                  AppendTo[privacyWarnings,
                    <|"NotebookRef" -> Lookup[row, "NotebookRef", ""],
                      "Title" -> Lookup[row, "Title", ""],
                      "SnapshotId" -> newSnapId,
                      "OldPrivacyLevel" -> oldPL,
                      "ComputedPrivacyLevel" -> newPL,
                      "Action" -> "RaisedToPrevious"|>]]]];
            (* optional summary refresh *)
            If[refreshSummary,
              Quiet @ SourceVaultNotebookSummary[path,
                "FallbackToCloud" -> fallback]];
            AppendTo[details,
              <|"Title" -> Lookup[row, "Title", ""],
                "NotebookRef" -> Lookup[row, "NotebookRef", ""],
                "Result" -> "Refreshed",
                "SnapshotId" -> newSnapId,
                "PrivacyRaised" -> raised|>],
            (* index failed *)
            failed = failed + 1;
            AppendTo[details,
              <|"Title" -> Lookup[row, "Title", ""],
                "NotebookRef" -> Lookup[row, "NotebookRef", ""],
                "Result" -> "Failed",
                "Reason" -> If[AssociationQ[idxResult],
                  Lookup[idxResult, "Reason", "Unknown"],
                  "NoResult"]|>]]]],
      targets];

    skipped = Lookup[plan, "Total", 0] - Length[targets];
    ts = DateString[DateObject[]];
    summary = <|
      "Type" -> "SourceVaultSync",
      "SyncId" -> syncId,
      "Scope" -> Lookup[plan, "Scope", ""],
      "StartedAt" -> startedAt,
      "FinishedAt" -> ts,
      "Total" -> Lookup[plan, "Total", 0],
      "Refreshed" -> refreshed,
      "Skipped" -> skipped,
      "Failed" -> failed,
      "PrivacyWarningCount" -> Length[privacyWarnings],
      "RefreshSummary" -> refreshSummary,
      "FallbackToCloud" -> fallback|>;

    (* persist: append to history, overwrite last-sync *)
    Module[{histLine, strm},
      histLine = Quiet @ ExportString[iSanitizeForJSON[summary],
        "RawJSON", "Compact" -> True];
      If[StringQ[histLine],
        strm = Quiet[OpenAppend[iSVSyncHistoryPath[],
          BinaryFormat -> True]];
        If[Head[strm] === OutputStream,
          BinaryWrite[strm,
            StringToByteArray[histLine <> "\n", "ISO8859-1"]];
          Close[strm]]]];
    Module[{lastRec, json, strm},
      lastRec = Append[summary,
        "PrivacyWarnings" -> privacyWarnings];
      json = Quiet @ ExportString[iSanitizeForJSON[lastRec],
        "RawJSON", "Compact" -> False];
      If[StringQ[json],
        strm = Quiet[OpenWrite[iSVSyncLastPath[],
          BinaryFormat -> True]];
        If[Head[strm] === OutputStream,
          BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
          Close[strm]]]];

    <|"Status" -> "OK",
      "SyncId" -> syncId,
      "Scope" -> Lookup[plan, "Scope", ""],
      "Total" -> Lookup[plan, "Total", 0],
      "Refreshed" -> refreshed,
      "Skipped" -> skipped,
      "Failed" -> failed,
      "PrivacyWarnings" -> privacyWarnings,
      "Details" -> details|>
  ];

(* === Public API: SourceVaultSyncStatus === *)

SourceVaultSyncStatus[] :=
  Module[{lastPath, rec},
    iEnsureRoots[];
    lastPath = iSVSyncLastPath[];
    If[!FileExistsQ[lastPath],
      Return[<|"Status" -> "NoSyncYet"|>]];
    rec = iLoadJSONFromFile[lastPath];
    If[!AssociationQ[rec],
      Return[<|"Status" -> "Failed",
        "Reason" -> "LastSyncUnreadable"|>]];
    Append[rec, "Status" -> "OK"]
  ];



(* ============================================================
   Stage 9 Phase 2 (P1) Step 6: SourceVaultMarkTodo
   ------------------------------------------------------------
   NBAccess \:306e\:9ad8\:30ec\:30d9\:30eb API NBWriteTodoStatus \:3078\:306e\:8584\:3044\:30e9\:30c3\:30d1\:30fc\:3002
   target \:6b63\:898f\:5316:
     Integer       -> <|"Index" -> n, "Text" -> (\:65e2\:5b58 Todo \:304b\:3089\:5f15\:304d\:5f53\:3066)|>
     String        -> TodoId \:5f62\:5f0f "todo-<nbRef>-<idx>" \:304b\:3089 Index \:62bd\:51fa
     Association   -> \:305d\:306e\:307e\:307e (Index/Text \:4e21\:65b9\:30c1\:30a7\:30c3\:30af)
   AutoReindex: \:7de8\:96c6\:6210\:529f\:5f8c\:306b SourceVaultIndexNotebook \:3092\:81ea\:52d5\:547c\:3073\:51fa\:3057 (\:5b9f\:884c\:6642\:306e\:307f)
   ============================================================ *)

(* String/Integer/Association \:3092 NBWriteTodoStatus \:7528\:306e Association \:306b\:6b63\:898f\:5316 *)
iSVResolveTodoTarget[path_String, target_] :=
  Module[{todos, normalizedIdx, normalizedText, todoMatch, nbRef,
          extractedIdx},
    Which[
      AssociationQ[target] &&
        IntegerQ[Lookup[target, "Index", Null]] &&
        StringQ[Lookup[target, "Text", Null]],
        Return[<|"Status" -> "OK",
          "TodoKey" -> <|"Index" -> target["Index"],
            "Text" -> target["Text"]|>|>],

      IntegerQ[target],
        normalizedIdx = target,

      StringQ[target] && StringStartsQ[target, "todo-"],
        (* TodoId \:304b\:3089 Index \:90e8\:5206\:3092\:62bd\:51fa: "todo-<nbRef>-<idx>" *)
        Module[{parts},
          parts = StringSplit[target, "-"];
          extractedIdx = If[Length[parts] >= 2,
            ToExpression[Last[parts]],
            $Failed];
          If[IntegerQ[extractedIdx],
            normalizedIdx = extractedIdx,
            Return[<|"Status" -> "Failed",
              "Reason" -> "InvalidTodoId",
              "Target" -> target|>]]],

      True,
        Return[<|"Status" -> "Failed",
          "Reason" -> "UnsupportedTargetType",
          "Target" -> target|>]
    ];

    (* SourceVault \:7d4c\:7531\:3067 Todo \:30ea\:30b9\:30c8\:3092\:53d6\:5f97\:3057 normalizedIdx \:304b\:3089 Text \:3092\:5f15\:304d\:5f53\:3066 *)
    todos = Quiet @ SourceVaultExtractNotebookTodos[path];
    If[!ListQ[todos],
      Return[<|"Status" -> "Failed",
        "Reason" -> "ExtractNotebookTodosFailed",
        "Target" -> target|>]];
    todoMatch = SelectFirst[todos,
      Lookup[#, "Index", Null] === normalizedIdx &, Null];
    If[todoMatch === Null,
      Return[<|"Status" -> "Failed",
        "Reason" -> "TodoIndexOutOfRange",
        "Target" -> target,
        "ProvidedIndex" -> normalizedIdx,
        "AvailableCount" -> Length[todos]|>]];

    normalizedText = Lookup[todoMatch, "Text", ""];
    <|"Status" -> "OK",
      "TodoKey" -> <|"Index" -> normalizedIdx,
        "Text" -> normalizedText|>,
      "Todo" -> todoMatch|>
  ];


(* === Public API: SourceVaultMarkTodo === *)

Options[SourceVaultMarkTodo] = {
  "DryRun" -> True,
  "AutoReindex" -> True,
  "AccessSpec" -> Automatic
};

SourceVaultMarkTodo[path_String, target_, newStatus_String,
    opts:OptionsPattern[]] :=
  Module[{abs, dryRun, autoReindex, accessSpec,
          resolved, todoKey, nbwResult, reindexResult},
    abs = ExpandFileName[path];
    If[!FileExistsQ[abs],
      Return[<|"Status" -> "Failed",
        "Reason" -> "FileNotFound", "Path" -> abs|>]];

    dryRun = TrueQ[OptionValue["DryRun"]];
    autoReindex = TrueQ[OptionValue["AutoReindex"]];
    accessSpec = OptionValue["AccessSpec"];

    (* default \:306f write-eligible (0.7) \:3092\:6e21\:3059 *)
    If[accessSpec === Automatic,
      accessSpec = <|"AccessLevel" -> 0.7,
        "Environment" -> "Notebook",
        "AllowedSinks" -> {"LocalOnly", "Notebook"}|>];

    (* target \:3092 NBWriteTodoStatus \:7528\:306e Association \:306b\:6b63\:898f\:5316 *)
    resolved = iSVResolveTodoTarget[abs, target];
    If[Lookup[resolved, "Status", ""] =!= "OK",
      Return[Join[resolved, <|"Path" -> abs|>]]];
    todoKey = resolved["TodoKey"];

    (* NBAccess \:7d4c\:7531\:3067 NBWriteTodoStatus \:3092\:547c\:3076 *)
    Quiet @ Needs["NBAccess`"];
    If[Length[Names["NBAccess`NBWriteTodoStatus"]] === 0,
      Return[<|"Status" -> "Failed",
        "Reason" -> "NBWriteTodoStatusNotAvailable",
        "Detail" -> "NBAccess`NBWriteTodoStatus \:304c\:30ed\:30fc\:30c9\:3055\:308c\:3066\:3044\:307e\:305b\:3093\:3002NBAccess.wl \:3092\:5148\:306b\:30ed\:30fc\:30c9\:3057\:3066\:304f\:3060\:3055\:3044\:3002"|>]];

    nbwResult = NBAccess`NBWriteTodoStatus[abs, todoKey, newStatus,
      "DryRun" -> dryRun,
      "AccessSpec" -> accessSpec];

    If[!AssociationQ[nbwResult] ||
        !MemberQ[{"OK", "DryRunOK"}, Lookup[nbwResult, "Status", ""]],
      Return[<|"Status" -> "Failed",
        "Reason" -> "NBWriteTodoStatusFailed",
        "Target" -> target,
        "TodoKey" -> todoKey,
        "NBResult" -> nbwResult|>]];

    (* AutoReindex (\:5b9f\:884c\:6642\:306e\:307f) *)
    reindexResult = If[!dryRun && autoReindex,
      Quiet @ SourceVaultIndexNotebook[abs],
      Missing["NotRequested"]];

    (* \:7d50\:679c\:69cb\:7bc9 *)
    Join[
      <|"Status" -> nbwResult["Status"],
        "Target" -> target,
        "MatchedTodo" -> Lookup[nbwResult, "MatchedTodo", todoKey],
        "OldStatus" -> Lookup[nbwResult, "OldStatus", "Unknown"],
        "NewStatus" -> newStatus,
        "DryRun" -> Lookup[nbwResult, "DryRun", dryRun],
        "CellPath" -> Lookup[nbwResult, "CellPath", Missing["NotPresent"]],
        "ExpressionUUID" ->
          Lookup[nbwResult, "ExpressionUUID", Missing["NotPresent"]],
        "Path" -> abs,
        "ReindexResult" -> reindexResult|>,
      If[dryRun,
        <|"Before" -> Lookup[nbwResult, "Before", Missing["NotPresent"]],
          "After" -> Lookup[nbwResult, "After", Missing["NotPresent"]]|>,
        <||>]]
  ];


(* ---------- SourceVaultContext ---------- *)

Options[SourceVaultContext] = {
  MaxCharacters -> 8000,
  "Sink" -> None,
  "Purpose" -> "Generic"
};

SourceVaultContext[span_Association, opts:OptionsPattern[]] :=
  Module[{snapshotId, snapshotMeta, pages, rawPath, text,
          decision, maxChars, objSpec, sink, purpose},
    iEnsureRoots[];
    snapshotId = Lookup[span, "SnapshotId", Missing[]];
    If[MissingQ[snapshotId] || !StringQ[snapshotId],
      Return[<|
        "Status" -> "Failed",
        "Reason" -> "InvalidSpan: SnapshotId missing",
        "Text" -> ""
      |>]];
    
    snapshotMeta = iSnapshotMetaLoad[snapshotId];
    If[!AssociationQ[snapshotMeta],
      Return[<|
        "Status" -> "Failed",
        "Reason" -> "SnapshotNotFound",
        "Text" -> "",
        "SnapshotId" -> snapshotId
      |>]];
    
    objSpec = iSpecFromSnapshotMeta[snapshotMeta];
    sink = iSinkSpecNormalize[OptionValue["Sink"]];
    purpose = OptionValue["Purpose"];
    
    decision = iCallNBAuthorize[
      objSpec,
      <|
        "Action" -> "ReadContext",
        "Purpose" -> purpose,
        "Sink" -> iSinkToNBString[sink]
      |>
    ];
    
    If[decision["Decision"] === "Deny",
      Message[SourceVault::denied, decision["ReasonClass"]];
      Return[<|
        "Status" -> "DeniedByNBAccess",
        "Text" -> "",
        "SourceSpans" -> {span},
        "AccessDecision" -> decision,
        "ReasonClass" -> decision["ReasonClass"]
      |>]];
    
    (* Stage 6d: RequireApproval \:3082 block (\:4ed5\:69d8\:66f8 \[Section] 14.4.1) *)
    If[decision["Decision"] === "RequireApproval",
      Return[<|
        "Status" -> "RequiresApproval",
        "Text" -> "",
        "SourceSpans" -> {span},
        "AccessDecision" -> decision,
        "Reason" -> "Context retrieval requires approval"
      |>]];
    
    (* "Permit" / "Screen" / \:305d\:306e\:4ed6 unknown decision \:306f\:7d9a\:884c\:3002
       "Screen" \:306f Phase 2 \:3067 redaction \:3092\:5b9f\:88c5\:4e88\:5b9a\:3002\:73fe\:72b6\:306f Permit \:3068\:540c\:7b49\:6271\:3044\:3002 *)
    pages = Lookup[Lookup[span, "Locator", <||>], "Pages", All];
    rawPath = snapshotMeta["Path"];
    
    text = iExtractTextPages[rawPath, pages, snapshotId];
    maxChars = OptionValue[MaxCharacters];
    If[IntegerQ[maxChars] && maxChars > 0,
      text = iTrimChars[text, maxChars]];
    
    <|
      "Status" -> "OK",
      "Text" -> text,
      "SourceSpans" -> {span},
      "Citations" -> {<|
        "SnapshotId" -> snapshotId,
        "SourceId" -> Lookup[snapshotMeta, "SourceId", Missing[]],
        "Pages" -> pages,
        "DisplayName" -> Lookup[snapshotMeta, "OriginalPath",
          Lookup[snapshotMeta, "OriginalURI", snapshotId]]
      |>},
      "Freshness" -> If[Lookup[snapshotMeta, "LifecycleStatus", "Current"] === "Current",
        "Pinned", "Stale"],
      "AccessDecision" -> decision,
      "Warnings" -> {}
    |>
  ];


(* ---------- SourceVaultContextAssemble ---------- *)

Options[SourceVaultContextAssemble] = {
  MaxCharacters -> 8000,
  "Sink" -> None,
  "Purpose" -> "Generic",
  "Ordering" -> "GivenOrder",
  "Separators" -> "ByPage",
  "IncludeCitations" -> True
};

SourceVaultContextAssemble[spans_List, opts:OptionsPattern[]] :=
  Module[{maxChars, sink, purpose, ordering, separators, includeCit,
          ordered, parts, currentChars, partsAcc, warnings, decisions,
          sep, citation, partText, charBefore},
    iEnsureRoots[];
    maxChars = OptionValue[MaxCharacters];
    sink = iSinkSpecNormalize[OptionValue["Sink"]];
    purpose = OptionValue["Purpose"];
    ordering = OptionValue["Ordering"];
    separators = OptionValue["Separators"];
    includeCit = TrueQ[OptionValue["IncludeCitations"]];
    
    (* order spans *)
    ordered = Switch[ordering,
      "PageOrder",
        SortBy[spans, {Lookup[#, "SnapshotId", ""] &,
          Min[Cases[Lookup[Lookup[#, "Locator", <||>], "Pages", {}],
            _Integer]] &}],
      "Citation",
        SortBy[spans, Lookup[#, "SnapshotId", ""] &],
      _, spans
    ];
    
    parts = {}; partsAcc = {}; warnings = {}; decisions = {};
    currentChars = 0;
    
    Module[{flag, i, span, ctx, spanText, allowedChars},
      flag = "ok"; i = 1;
      While[flag === "ok" && i <= Length[ordered],
        span = ordered[[i]];
        ctx = SourceVaultContext[span,
          MaxCharacters -> maxChars,
          "Sink" -> sink,
          "Purpose" -> purpose];
        AppendTo[decisions, Lookup[ctx, "AccessDecision", <||>]];
        If[ctx["Status"] === "DeniedByNBAccess",
          AppendTo[warnings,
            "Span denied by NBAccess: " <> ToString[Lookup[ctx, "ReasonClass", ""]]];
          i++;
          Continue[]];
        If[ctx["Status"] =!= "OK",
          AppendTo[warnings,
            "Span failed: " <> ToString[Lookup[ctx, "Reason", "Unknown"]]];
          i++;
          Continue[]];
        spanText = ctx["Text"];
        
        sep = Switch[separators,
          "ByPage",
            "\n\n--- Page span: " <>
              ToString[Lookup[Lookup[span, "Locator", <||>], "Pages", "?"]] <>
              " (snapshot " <> StringTake[Lookup[span, "SnapshotId", "?"], UpTo[24]] <> "...) ---\n\n",
          "BySource",
            "\n\n--- Source: " <>
              StringTake[Lookup[span, "SnapshotId", "?"], UpTo[24]] <> "... ---\n\n",
          _, "\n\n"
        ];
        
        partText = sep <> spanText;
        allowedChars = maxChars - currentChars;
        If[allowedChars <= 0,
          flag = "exhausted";
          AppendTo[warnings, "MaxCharacters reached; remaining spans skipped"],
          (* else *)
          If[StringLength[partText] > allowedChars,
            partText = iTrimChars[partText, allowedChars];
            AppendTo[warnings, "Truncated to MaxCharacters"]];
          AppendTo[partsAcc, partText];
          AppendTo[parts, <|
            "SourceSpan" -> span,
            "CitationKey" -> Lookup[ctx["Citations"][[1]], "DisplayName",
              Lookup[span, "SnapshotId", ""]],
            "CharCount" -> StringLength[partText]
          |>];
          currentChars += StringLength[partText];
        ];
        i++;
      ];
    ];
    
    <|
      "Status" -> If[Length[partsAcc] > 0, "OK", "Empty"],
      "Text" -> StringJoin[partsAcc],
      "Parts" -> parts,
      "SourceSpans" -> ordered,
      "Citations" -> If[includeCit,
        Map[Function[p, <|
          "SnapshotId" -> Lookup[Lookup[p, "SourceSpan", <||>], "SnapshotId", ""],
          "CitationKey" -> Lookup[p, "CitationKey", ""],
          "CharCount" -> Lookup[p, "CharCount", 0]
        |>], parts],
        {}],
      "AccessDecisions" -> decisions,
      "Warnings" -> warnings
    |>
  ];


(* ============================================================
   13. ClaudeAttach \:4e92\:63db API
   ============================================================ *)

(* \:65e7\:5f62\:5f0f refSources -> SourceSpan normalization.
   \:65e7\:5f62\:5f0f:
     {"paper.pdf", {1, 3, 5}}             ; { filename or path, pages }
     {"paper.pdf", All}                   ; \:5168\:30da\:30fc\:30b8
     "paper.pdf"                          ; \:5168\:30da\:30fc\:30b8
     <|...|> (\:65b0\:5f62\:5f0f)         ; \:305d\:306e\:307e\:307e *)
iNormalizeRefSourceOld[refOld_] :=
  Module[{file, pages, expanded, ingestResult},
    Which[
      AssociationQ[refOld] && KeyExistsQ[refOld, "SnapshotId"],
        refOld,
      (* {file, pages} \:5f62\:5f0f *)
      ListQ[refOld] && Length[refOld] >= 1 && StringQ[refOld[[1]]],
        file = refOld[[1]];
        pages = If[Length[refOld] >= 2, refOld[[2]], All];
        expanded = If[FileExistsQ[file], ExpandFileName[file],
          (* relative path \:306e\:53ef\:80fd\:6027 *)
          file];
        If[!FileExistsQ[expanded],
          Return[<|"SnapshotId" -> Missing["FileNotFound"],
            "Locator" -> <|"Pages" -> pages|>,
            "OriginalPath" -> file,
            "Role" -> "ReferenceContext"|>]];
        SourceVaultSpan[expanded, "Pages" -> pages],
      (* \:5358\:4e00 file path *)
      StringQ[refOld] && FileExistsQ[refOld],
        SourceVaultSpan[ExpandFileName[refOld], "Pages" -> All],
      True,
        <|"SnapshotId" -> Missing["UnnormalizableRef"],
          "Original" -> refOld,
          "Role" -> "ReferenceContext"|>
    ]
  ];

SourceVaultEnsureRegistered[ref_] := iNormalizeRefSourceOld[ref];


(* ---------- TaggingRules access ---------- *)

(* NBAccess`NBGetTaggingRule / NBSetTaggingRule \:3092\:4f7f\:3046 (\:5fc5\:9808\:524d\:63d0) *)

iCellGetRefSources[nb_NotebookObject, cellIdx_Integer] :=
  Module[{r},
    r = Quiet[NBAccess`NBCellGetTaggingRule[nb, cellIdx, {"documentation", "refSources"}]];
    If[!ListQ[r], r = {}];
    r
  ];

iCellGetSourceVaultRefs[nb_NotebookObject, cellIdx_Integer] :=
  Module[{r},
    r = Quiet[NBAccess`NBCellGetTaggingRule[nb, cellIdx, {"documentation", "sourceVaultRefs"}]];
    If[!ListQ[r], r = {}];
    r
  ];

iCellSetSourceVaultRefs[nb_NotebookObject, cellIdx_Integer, refs_List] :=
  Quiet[NBAccess`NBCellSetTaggingRule[nb, cellIdx, {"documentation", "sourceVaultRefs"}, refs]];

(* SourceVaultGetCellSources[nb, cellIdx]: \:65b0\:5f62\:5f0f\:304c\:3042\:308c\:3070\:305d\:308c\:3092\:3001\:306a\:3051\:308c\:3070\:65e7\:5f62\:5f0f\:3092 read-only normalize *)
SourceVaultGetCellSources[nb_NotebookObject, cellIdx_Integer] :=
  Module[{newRefs, oldRefs},
    newRefs = iCellGetSourceVaultRefs[nb, cellIdx];
    If[ListQ[newRefs] && Length[newRefs] > 0,
      Return[newRefs]];
    oldRefs = iCellGetRefSources[nb, cellIdx];
    Map[iNormalizeRefSourceOld, oldRefs]
  ];

SourceVaultAttachToCell[nb_NotebookObject, cellIdx_Integer, span_Association,
    opts:OptionsPattern[]] :=
  Module[{existing, newList},
    existing = iCellGetSourceVaultRefs[nb, cellIdx];
    newList = Append[existing, span];
    iCellSetSourceVaultRefs[nb, cellIdx, newList];
    <|"Status" -> "Attached", "CellIndex" -> cellIdx, "Span" -> span|>
  ];

Options[SourceVaultAttach] = {
  "Pages" -> All,
  "Role" -> "ReferenceContext",
  "Purpose" -> "Generic",
  "CellIndex" -> Automatic
};

SourceVaultAttach[nb_NotebookObject, source_, opts:OptionsPattern[]] :=
  Module[{span, cellIdx, attachList, existing},
    span = If[AssociationQ[source] && KeyExistsQ[source, "SnapshotId"],
      source,
      SourceVaultSpan[source,
        "Pages" -> OptionValue["Pages"],
        "Role" -> OptionValue["Role"],
        "Purpose" -> OptionValue["Purpose"]]];
    cellIdx = OptionValue["CellIndex"];
    If[IntegerQ[cellIdx],
      SourceVaultAttachToCell[nb, cellIdx, span],
      (* notebook level attach *)
      existing = Quiet[NBAccess`NBGetTaggingRule[nb, {"documentation", "sourceVaultRefs"}]];
      attachList = If[ListQ[existing], existing, {}];
      attachList = Append[attachList, span];
      Quiet[NBAccess`NBSetTaggingRule[nb,
        {"documentation", "sourceVaultRefs"}, attachList]];
      <|"Status" -> "Attached", "Notebook" -> nb, "Span" -> span|>
    ]
  ];

SourceVaultGetAttachments[nb_NotebookObject] :=
  Module[{nbLevel, allCells, byCell, n, i},
    nbLevel = Quiet[NBAccess`NBGetTaggingRule[nb, {"documentation", "sourceVaultRefs"}]];
    If[!ListQ[nbLevel], nbLevel = {}];
    
    n = Quiet[NBAccess`NBCellCount[nb]];
    If[!IntegerQ[n], n = 0];
    
    byCell = Association @@ Table[
      Module[{refs},
        refs = SourceVaultGetCellSources[nb, i];
        If[Length[refs] > 0, i -> refs, Nothing]
      ],
      {i, 1, n}];
    
    <|
      "Notebook" -> nbLevel,
      "ByCell" -> byCell
    |>
  ];


(* ============================================================
   14. Materialization gate (Stage 0-3 \:30b9\:30b1\:30eb\:30c8\:30f3)
   ============================================================ *)

Options[SourceVaultMaterializeForSink] = {"Force" -> False};

SourceVaultMaterializeForSink[ref_, sinkSpec_, opts:OptionsPattern[]] :=
  Module[{obj, decision, snapshotMeta, srcPath, mirrorPath, sinkAssoc},
    iEnsureRoots[];
    sinkAssoc = iSinkSpecNormalize[sinkSpec];
    
    obj = Which[
      StringQ[ref] && StringStartsQ[ref, "snap-"],
        SourceVaultObjectSpec[ref],
      AssociationQ[ref] && KeyExistsQ[ref, "SnapshotId"],
        SourceVaultObjectSpec[ref["SnapshotId"]],
      True,
        <|"AccessLevel" -> 0.5, "ObjectClass" -> "Unknown"|>
    ];
    
    decision = iAuthorizeMaterialize[obj, sinkAssoc];
    
    Switch[decision["Decision"],
      "Permit",
        snapshotMeta = If[StringQ[ref], iSnapshotMetaLoad[ref],
          iSnapshotMetaLoad[ref["SnapshotId"]]];
        If[!AssociationQ[snapshotMeta],
          Return[<|"Status" -> "Failed", "Reason" -> "SnapshotNotFound"|>]];
        srcPath = snapshotMeta["Path"];
        mirrorPath = FileNameJoin[{
          SourceVault`$SourceVaultRoots["CloudMirror"],
          "raw", "by-hash",
          FileNameTake[srcPath]}];
        iEnsureDir[DirectoryName[mirrorPath]];
        If[iTransactionalCopy[srcPath, mirrorPath] === $Failed,
          Return[<|"Status" -> "Failed", "Reason" -> "CopyFailed"|>]];
        iLog["Materialize", <|
          "SnapshotId" -> Lookup[snapshotMeta, "SnapshotId", "?"],
          "SinkKind" -> Lookup[sinkAssoc, "Kind", "?"],
          "MirrorPath" -> mirrorPath
        |>];
        <|"Status" -> "Materialized",
          "Path" -> mirrorPath,
          "Decision" -> decision|>,
      "Screen",
        <|"Status" -> "Screened",
          "Reason" -> "Materialization requires screening (Stage 4+ feature)",
          "Decision" -> decision|>,
      "RequireApproval",
        <|"Status" -> "RequiresApproval",
          "Reason" -> "Materialization requires human approval",
          "Decision" -> decision|>,
      _,
        Message[SourceVault::denied, decision["ReasonClass"]];
        <|"Status" -> "DeniedByNBAccess",
          "Decision" -> decision|>
    ]
  ];


(* ============================================================
   15. ClaudeAttach Integration (P1)
   
   ClaudeCode`ClaudeAttach \:306e DownValues \:3092 hook \:3057\:3066\:3001\:5147\:54e1\:3068\:3057\:3066
   SourceVaultIngest \:3092\:5b9f\:884c\:3002 \:7d50\:679c\:306f notebook \:306e TaggingRule path
     {"documentation", "claudeAttachSourceVaultRefs"}
   \:306b\:7d4c\:6642\:8a18\:9332\:3002
   
   \:8a2d\:8a08:
     \:30fb ClaudeAttach \:306e\:7d50\:679c\:81ea\:8eab\:306f\:7121\:5909\:66f4 (\:65e2\:5b58\:30b3\:30fc\:30c9\:30fb\:30c6\:30b9\:30c8\:306b\:5f71\:97ff\:7121\:3057)
     \:30fb side-channel \:30a8\:30e9\:30fc\:306f\:5168\:3066 Quiet \:3067\:5305\:307f\:3001\:5fc5\:305a\:5143\:306e\:7d50\:679c\:3092\:8fd4\:3059
     \:30fb URL \:6dfb\:4ed8\:306f Stage 4 (URL adapter) \:307e\:3067\:30b9\:30ad\:30c3\:30d7
     \:30fb \:660e\:793a\:7684\:306a Enable/Disable \:3067\:30ed\:30fc\:30eb\:30d0\:30c3\:30af\:53ef\:3002 \:81ea\:52d5 enable \:306f\:884c\:308f\:306a\:3044
     \:30fb Block \:3067\:5143\:306e DownValues \:3092\:4e00\:6642\:5fa9\:5143\:3057\:3066\:539f\:5b9f\:88c5\:3092\:547c\:3076 (\:518d\:5165\:5b89\:5168)
   ============================================================ *)

(* hook \:6709\:52b9\:5316\:30d5\:30e9\:30b0 *)
If[!ValueQ[$IntegrationClaudeAttachEnabled],
  $IntegrationClaudeAttachEnabled = False];

(* \:5143\:306e DownValue \:30b9\:30ca\:30c3\:30d7\:30b7\:30e7\:30c3\:30c8 *)
If[!ValueQ[$IntegrationClaudeAttachOriginalDV],
  $IntegrationClaudeAttachOriginalDV = Null];

(* P1 hook \:304c attach \:3057\:305f refs \:306e\:30e1\:30e2\:30ea\:30ec\:30b8\:30b9\:30c8\:3002
   notebook TaggingRule \:3068\:5e76\:884c\:3057\:3066\:8a18\:9332\:3001
   \:30b9\:30b1\:30b8\:30e5\:30fc\:30eb\:30c9\:30bf\:30b9\:30af\:7b49 EvaluationNotebook[] \:304c\:898b\:3048\:306a\:3044\:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:7528\:306e fallback\:3002 *)
If[!ValueQ[$LastAttachedRefs],
  $LastAttachedRefs = {}];

(* side-channel ingest \:5b9f\:88c5 *)
iClaudeAttachSideChannelIngest[pathOrURL_String] :=
  Module[{ingestResult, expanded, snapshotRef, isUrl, currentList, nb,
          attachedPathOrURL},
    nb = EvaluationNotebook[];
    Quiet[
      Module[{},
        isUrl = StringMatchQ[pathOrURL, ("http://" | "https://" | "arXiv:" | "arxiv:") ~~ __];
        Which[
          (* URL / arXiv \:30a2\:30bf\:30c3\:30c1: Phase 4A \:7d4c\:7531\:3067 ingest *)
          isUrl,
            attachedPathOrURL = pathOrURL;
            ingestResult = SourceVaultIngest[pathOrURL,
              Topic -> "ClaudeAttach"];
            (* TrustLevel \:306f Automatic \:307e\:307e -- iAutoTrustLevel \:304c\:81ea\:52d5\:5224\:5b9a *)
            If[AssociationQ[ingestResult] &&
               KeyExistsQ[ingestResult, "SnapshotId"] &&
               StringQ[ingestResult["SnapshotId"]],
              snapshotRef = <|
                "OriginalPathOrURL" -> attachedPathOrURL,
                "ExpandedPath" -> Lookup[ingestResult, "URL",
                  Lookup[ingestResult, "RawPath", attachedPathOrURL]],
                "SnapshotId" -> ingestResult["SnapshotId"],
                "SourceId" -> Lookup[ingestResult, "SourceId", Missing[]],
                "ContentHash" -> Lookup[ingestResult, "ContentHash", Missing[]],
                "TrustLevel" -> Lookup[ingestResult, "TrustLevel", Missing[]],
                "IngestStatus" -> Lookup[ingestResult, "Status", "Unknown"],
                "AttachedAt" -> DateString[]
              |>;
              currentList = NBAccess`NBGetTaggingRule[nb,
                {"documentation", "claudeAttachSourceVaultRefs"}];
              If[!ListQ[currentList], currentList = {}];
              NBAccess`NBSetTaggingRule[nb,
                {"documentation", "claudeAttachSourceVaultRefs"},
                Append[currentList, snapshotRef]];
              (* \:30e1\:30e2\:30ea\:30ec\:30b8\:30b9\:30c8\:306b\:3082\:8a18\:9332 (\:7f60 #19 \:5bfe\:7b56) *)
              If[!ListQ[$LastAttachedRefs], $LastAttachedRefs = {}];
              $LastAttachedRefs = DeleteDuplicatesBy[
                Append[$LastAttachedRefs, snapshotRef],
                Lookup[#, "SnapshotId", ""] &]],
          
          (* \:30ed\:30fc\:30ab\:30eb\:30d5\:30a1\:30a4\:30eb\:306e\:5834\:5408\:306e\:307f ingest *)
          True,
            expanded = ExpandFileName[pathOrURL];
            If[StringQ[expanded] && FileExistsQ[expanded] && !DirectoryQ[expanded],
              ingestResult = SourceVaultIngest[expanded,
                Topic -> "ClaudeAttach",
                TrustLevel -> "LocalFile"];
              If[AssociationQ[ingestResult] &&
                 KeyExistsQ[ingestResult, "SnapshotId"] &&
                 StringQ[ingestResult["SnapshotId"]],
                snapshotRef = <|
                  "OriginalPathOrURL" -> pathOrURL,
                  "ExpandedPath" -> expanded,
                  "SnapshotId" -> ingestResult["SnapshotId"],
                  "SourceId" -> Lookup[ingestResult, "SourceId", Missing[]],
                  "ContentHash" -> Lookup[ingestResult, "ContentHash", Missing[]],
                  "IngestStatus" -> Lookup[ingestResult, "Status", "Unknown"],
                  "AttachedAt" -> DateString[]
                |>;
                currentList = NBAccess`NBGetTaggingRule[nb,
                  {"documentation", "claudeAttachSourceVaultRefs"}];
                If[!ListQ[currentList], currentList = {}];
                NBAccess`NBSetTaggingRule[nb,
                  {"documentation", "claudeAttachSourceVaultRefs"},
                  Append[currentList, snapshotRef]];
                (* \:30e1\:30e2\:30ea\:30ec\:30b8\:30b9\:30c8\:306b\:3082\:8a18\:9332 (SnapshotId \:3067 dedup) \[LongDash]
                   worker scheduled task \:7b49 EvaluationNotebook[] \:304c\:898b\:3048\:306a\:3044\:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:7528 fallback *)
                If[!ListQ[$LastAttachedRefs], $LastAttachedRefs = {}];
                $LastAttachedRefs = DeleteDuplicatesBy[
                  Append[$LastAttachedRefs, snapshotRef],
                  Lookup[#, "SnapshotId", ""] &]]]
        ]
      ]
    ];
    Null
  ];

(* Enable: ClaudeAttach \:306e DownValues \:3092\:5168\:90e8\:5165\:308c\:66ff\:3048\:308b\:3002
   Block \:3067\:5143\:306e DownValues \:3092\:4e00\:6642\:5fa9\:5143\:3057\:3066\:539f\:5b9f\:88c5\:3092\:547c\:3076\:3002 *)
SourceVaultClaudeAttachIntegrationEnable[] :=
  Module[{},
    (* claudecode.wl \:306e\:5b58\:5728\:78ba\:8a8d (\:4f9d\:5b58\:306f\:30aa\:30d7\:30b7\:30e7\:30ca\:30eb \[LongDash]
       SourceVault \:81ea\:4f53\:306f claudecode \:7121\:3057\:3067\:3082\:30ed\:30fc\:30c9\:3055\:308c\:308b) *)
    If[Length[Names["ClaudeCode`ClaudeAttach"]] === 0,
      Print[Style["[SourceVault] claudecode.wl (ClaudeAttach) \:304c\:898b\:3064\:304b\:308a\:307e\:305b\:3093\:3002", Red]];
      Print["  claudecode.wl \:3092\:30ed\:30fc\:30c9\:3057\:3066\:304b\:3089 Enable \:3057\:3066\:304f\:3060\:3055\:3044\:3002"];
      Return[<|"Status" -> "Failed", "Reason" -> "ClaudeAttachNotFound"|>]];
    
    If[Length[DownValues[ClaudeCode`ClaudeAttach]] === 0,
      Print[Style["[SourceVault] ClaudeAttach \:306e DownValue \:304c\:7a7a\:3067\:3059\:3002", Red]];
      Return[<|"Status" -> "Failed", "Reason" -> "ClaudeAttachEmpty"|>]];
    
    If[TrueQ[$IntegrationClaudeAttachEnabled],
      Print["[SourceVault] ClaudeAttach hook \:306f\:65e2\:306b\:6709\:52b9\:5316\:6e08\:307f (noop)\:3002"];
      Return[<|"Status" -> "AlreadyEnabled"|>]];
    
    (* \:5143\:306e DownValue \:3092\:4fdd\:5b58 *)
    $IntegrationClaudeAttachOriginalDV =
      DownValues[ClaudeCode`ClaudeAttach];
    
    (* DownValues \:3092\:7a7a\:306b\:3057\:3066\:65b0\:5b9a\:7fa9\:3092\:8ffd\:52a0\:3002 ClearAll \:3067\:306f\:306a\:304f
       Attributes / Options / Messages \:306f\:7dad\:6301\:3002 *)
    DownValues[ClaudeCode`ClaudeAttach] = {};
    
    (* Helper: original \:3092\:5b89\:5168\:306b\:547c\:3076 (Block \:4e0d\:53ef \[LongDash] Block \:306f Options \:307e\:3067 \:9000\:907f\:3057\:3066\:3057\:307e\:3046\:305f\:3081
       Options[ClaudeCode`ClaudeAttach] \:304c\:4e00\:6642\:7684\:306b\:7a7a\:306b\:306a\:308a OptionValue::optnf \:304c\:7a3a\:53d1) *)
    SourceVault`Private`iClaudeAttachOriginalCall[args___] :=
      Module[{result, hookDV},
        hookDV = DownValues[ClaudeCode`ClaudeAttach];
        DownValues[ClaudeCode`ClaudeAttach] =
          SourceVault`Private`$IntegrationClaudeAttachOriginalDV;
        result = CheckAbort[
          ClaudeCode`ClaudeAttach[args],
          DownValues[ClaudeCode`ClaudeAttach] = hookDV;
          Abort[]
        ];
        DownValues[ClaudeCode`ClaudeAttach] = hookDV;
        result
      ];
    
    (* \:30aa\:30fc\:30d0\:30fc\:30ed\:30fc\:30c9 1: ClaudeAttach[path, opts] *)
    ClaudeCode`ClaudeAttach[path_String, opts___] :=
      Module[{result, isUrlOrArXiv},
        isUrlOrArXiv = StringMatchQ[path,
          ("http://" | "https://" | "arXiv:" | "arxiv:") ~~ __];
        If[isUrlOrArXiv,
          (* URL / arXiv: ClaudeAttach \:672c\:4f53\:306f file-only \:60f3\:5b9a\:306a\:306e\:3067\:5468\:308a\:8fbc\:307f\:3001
             SourceVault \:7d4c\:7531\:306e\:307f attach\:3002side-channel ingest \:3060\:3051\:884c\:3046\:3002 *)
          SourceVault`Private`iClaudeAttachSideChannelIngest[path];
          <|"Status" -> "AttachedViaSourceVault",
            "OriginalPathOrURL" -> path,
            "Note" -> "URL / arXiv source is attached through SourceVault only " <>
                      "(ClaudeAttach native API expects local file paths)."|>,
          (* \:30ed\:30fc\:30ab\:30eb\:30d5\:30a1\:30a4\:30eb: \:5f93\:6765\:901a\:308a original \:3092\:547c\:3093\:3067 side-channel ingest *)
          result = SourceVault`Private`iClaudeAttachOriginalCall[path, opts];
          SourceVault`Private`iClaudeAttachSideChannelIngest[path];
          result
        ]
      ];
    
    (* \:30aa\:30fc\:30d0\:30fc\:30ed\:30fc\:30c9 2: ClaudeAttach[session, path, opts] *)
    ClaudeCode`ClaudeAttach[session_Association, path_String, opts___] :=
      Module[{result, isUrlOrArXiv},
        isUrlOrArXiv = StringMatchQ[path,
          ("http://" | "https://" | "arXiv:" | "arxiv:") ~~ __];
        If[isUrlOrArXiv,
          SourceVault`Private`iClaudeAttachSideChannelIngest[path];
          <|"Status" -> "AttachedViaSourceVault",
            "OriginalPathOrURL" -> path,
            "Session" -> session,
            "Note" -> "URL / arXiv source is attached through SourceVault only."|>,
          result = SourceVault`Private`iClaudeAttachOriginalCall[session, path, opts];
          SourceVault`Private`iClaudeAttachSideChannelIngest[path];
          result
        ]
      ];
    
    $IntegrationClaudeAttachEnabled = True;
    Print[Style[
      "[SourceVault] ClaudeAttach hook \:6709\:52b9\:5316\:3002", Bold]];
    Print["  ClaudeAttach[path] / ClaudeAttach[session, path] \:306f\:65e2\:5b58\:901a\:308a\:52d5\:4f5c\:3001"];
    Print["  side-channel \:3067 SourceVault \:306b\:3082 ingest \:3055\:308c\:308b\:3002"];
    Print["  \:7121\:52b9\:5316: SourceVaultClaudeAttachIntegrationDisable[]"];
    <|"Status" -> "Enabled",
      "OriginalDVCount" -> Length[$IntegrationClaudeAttachOriginalDV]|>
  ];

(* Disable: \:5143\:306e DownValues \:306b\:5fa9\:5143 *)
SourceVaultClaudeAttachIntegrationDisable[] :=
  Module[{},
    If[!TrueQ[$IntegrationClaudeAttachEnabled],
      Print["[SourceVault] ClaudeAttach hook \:306f\:6709\:52b9\:5316\:3055\:308c\:3066\:3044\:307e\:305b\:3093 (noop)\:3002"];
      Return[<|"Status" -> "NotEnabled"|>]];
    
    If[ValueQ[$IntegrationClaudeAttachOriginalDV] &&
       ListQ[$IntegrationClaudeAttachOriginalDV],
      DownValues[ClaudeCode`ClaudeAttach] = {};
      DownValues[ClaudeCode`ClaudeAttach] = $IntegrationClaudeAttachOriginalDV;
      $IntegrationClaudeAttachEnabled = False;
      Print[Style["[SourceVault] ClaudeAttach hook \:7121\:52b9\:5316\:3002", Bold]];
      Print["  ClaudeAttach \:3092\:5143\:306e DownValue \:306b\:5fa9\:5143\:6e08\:307f\:3002"];
      <|"Status" -> "Disabled"|>,
      Print[Style["[SourceVault] \:5143\:306e DownValue \:30b9\:30ca\:30c3\:30d7\:30b7\:30e7\:30c3\:30c8\:304c\:898b\:3064\:304b\:308a\:307e\:305b\:3093\:3002", Red]];
      <|"Status" -> "Failed", "Reason" -> "NoOriginalSnapshot"|>]
  ];

(* Status *)
SourceVaultClaudeAttachIntegrationStatus[] :=
  <|
    "Enabled" -> TrueQ[$IntegrationClaudeAttachEnabled],
    "OriginalSaved" -> ListQ[$IntegrationClaudeAttachOriginalDV],
    "OriginalDVCount" ->
      If[ListQ[$IntegrationClaudeAttachOriginalDV],
        Length[$IntegrationClaudeAttachOriginalDV], 0],
    "HookTarget" -> "ClaudeCode`ClaudeAttach"
  |>;

(* \:6dfb\:4ed8\:60c5\:5831\:53d6\:5f97 *)
SourceVaultGetClaudeAttachRefs[nb_NotebookObject] :=
  Module[{r},
    r = Quiet[NBAccess`NBGetTaggingRule[nb,
      {"documentation", "claudeAttachSourceVaultRefs"}]];
    If[ListQ[r], r, {}]
  ];

SourceVaultGetClaudeAttachRefs[] :=
  SourceVaultGetClaudeAttachRefs[EvaluationNotebook[]];


(* ============================================================
   16. ClaudeAttachments Integration (P2)
   
   ClaudeCode`ClaudeAttachments \:306e DownValues \:3092 hook \:3057\:3066\:3001
   \:623b\:308a\:5024\:3092 List of String paths \:304b\:3089 Association list \:306b\:62e1\:5f35\:3059\:308b\:3002
   \:5404 entry \:306b\:65e2\:5b58 attachment metadata (source / keywords / title / cachedAt)
   \:3068 SourceVault TaggingRule \:60c5\:5831 (SnapshotId / SourceId / ContentHash /
   IngestStatus) \:3092 join \:3057\:3066\:8fd4\:3059\:3002
   
   \:8a2d\:8a08\:30dd\:30a4\:30f3\:30c8:
     \:30fb hook \:5bfe\:8c61: ClaudeCode`ClaudeAttachments (Public)
     \:30fb metadata \:53d6\:5f97\:306f Private symbol \:3092\:907f\:3051\:3001 _meta.json \:3092\:76f4\:8aad\:307f
       (claudecode \:306e Private context \:898b\:3048\:306a\:3044\:30b1\:30fc\:30b9\:5bfe\:7b56)
     \:30fb join key: source \:30d5\:30a3\:30fc\:30eb\:30c9 \[LeftRightArrow] ExpandedPath / OriginalPathOrURL
     \:30fb _meta.json \:306f ModificationDate-based cache \:3067\:8907\:6570\:6dfb\:4ed8\:3092\:30d0\:30c3\:30c1\:8aad\:307f
     \:30fb URL \:6dfb\:4ed8\:306f Stage 4 \:307e\:3067 SourceVault \:60c5\:5831\:7121\:3057
     \:30fb \:660e\:793a\:7684\:306a Enable/Disable\:3001\:81ea\:52d5 enable \:306f\:884c\:308f\:306a\:3044
   ============================================================ *)

(* hook \:6709\:52b9\:5316\:30d5\:30e9\:30b0 *)
If[!ValueQ[$IntegrationClaudeAttachmentsEnabled],
  $IntegrationClaudeAttachmentsEnabled = False];

If[!ValueQ[$IntegrationClaudeAttachmentsOriginalDV],
  $IntegrationClaudeAttachmentsOriginalDV = Null];

(* _meta.json cache *)
If[!ValueQ[$AttachmentMetaCache],
  $AttachmentMetaCache = <||>];

If[!ValueQ[$AttachmentMetaCacheKey],
  $AttachmentMetaCacheKey = ""];

(* cached file \:306e parent dir \:306b\:3042\:308b _meta.json \:3092\:8aad\:307f\:8fbc\:3093\:3067
   \:8a72\:5f53\:30d1\:30b9\:306e Association \:3092\:8fd4\:3059\:3002
   ClaudeAttach \:306f Developer`WriteRawJSONFile \:3067\:4fdd\:5b58\:3057\:3066\:3044\:308b\:306e\:3067\:3001
   \:30c8\:30c3\:30d7\:30ec\:30d9\:30eb\:306f cachedPath \:3092\:30ad\:30fc\:3068\:3059\:308b Association\:3002 *)
iLoadAttachmentMetaJSON[cachedPath_String] :=
  Module[{cacheDir, metaFile, raw, sig},
    Quiet[
      cacheDir = DirectoryName[cachedPath];
      metaFile = FileNameJoin[{cacheDir, "_meta.json"}];
      If[!StringQ[metaFile] || !FileExistsQ[metaFile], <||>,
        (* \:540c\:3058\:30d5\:30a1\:30a4\:30eb\:3092\:7e70\:308a\:8fd4\:3057\:8aad\:307e\:306a\:3044\:3088\:3046 ModificationDate-based cache *)
        sig = metaFile <> ToString[Quiet[UnixTime[FileDate[metaFile]]]];
        If[sig =!= $AttachmentMetaCacheKey,
          raw = Quiet[Developer`ReadRawJSONFile[metaFile]];
          If[!AssociationQ[raw], raw = <||>];
          $AttachmentMetaCache = raw;
          $AttachmentMetaCacheKey = sig];
        Lookup[$AttachmentMetaCache, cachedPath, <||>]
      ]
    ]
  ];

(* SourceVault ref \:306e\:5024\:3092 source \:6587\:5b57\:5217\:3067\:691c\:7d22\:3002
   join \:3057\:8a18\:8ff0\:4e21\:65b9 (ExpandedPath / OriginalPathOrURL) \:3068\:4e00\:81f4\:3055\:305b\:308b\:3002 *)
iFindSourceVaultRefForSource[refs_List, source_] :=
  Module[{normSource, found},
    If[!StringQ[source], Return[<||>]];
    normSource = Quiet[ExpandFileName[source]];
    found = SelectFirst[refs,
      Function[ref,
        (KeyExistsQ[ref, "ExpandedPath"] && ref["ExpandedPath"] === normSource) ||
        (KeyExistsQ[ref, "ExpandedPath"] && ref["ExpandedPath"] === source) ||
        (KeyExistsQ[ref, "OriginalPathOrURL"] && ref["OriginalPathOrURL"] === source)
      ],
      <||>];
    If[AssociationQ[found], found, <||>]
  ];

(* \:5358\:4e00 cached path \:3092 Association \:306b enrich *)
iEnrichAttachmentEntry[cachedPath_String, refs_List] :=
  Module[{meta, source, svRef, baseAssoc},
    meta = iLoadAttachmentMetaJSON[cachedPath];
    If[!AssociationQ[meta], meta = <||>];
    source = Lookup[meta, "source", Missing[]];
    svRef = iFindSourceVaultRefForSource[refs, source];
    
    baseAssoc = <|
      "Path"        -> cachedPath,
      "DisplayName" -> FileNameTake[cachedPath],
      "Source"      -> source,
      "Keywords"    -> Lookup[meta, "keywords", {}],
      "Title"       -> Lookup[meta, "title", Missing[]],
      "CachedAt"    -> Lookup[meta, "cachedAt", Missing[]],
      "FileExists"  -> Quiet[FileExistsQ[cachedPath]],
      "ByteCount"   -> Quiet[FileByteCount[cachedPath]]
    |>;
    
    If[AssociationQ[svRef] && KeyExistsQ[svRef, "SnapshotId"],
      Join[baseAssoc, <|
        "SnapshotId"   -> svRef["SnapshotId"],
        "SourceId"     -> Lookup[svRef, "SourceId", Missing[]],
        "ContentHash"  -> Lookup[svRef, "ContentHash", Missing[]],
        "IngestStatus" -> Lookup[svRef, "IngestStatus", "Unknown"],
        "AttachedAt"   -> Lookup[svRef, "AttachedAt", Missing[]]
      |>],
      Join[baseAssoc, <|
        "SnapshotId"   -> None,
        "SourceId"     -> None,
        "ContentHash"  -> None,
        "IngestStatus" -> "NotIngested",
        "AttachedAt"   -> None
      |>]
    ]
  ];

iEnrichAttachments[paths_List, nb_NotebookObject] :=
  Module[{refs},
    refs = Quiet[SourceVaultGetClaudeAttachRefs[nb]];
    If[!ListQ[refs], refs = {}];
    iEnrichAttachmentEntry[#, refs] & /@ paths
  ];

(* Enable: ClaudeAttachments \:306e DownValues \:3092\:5168\:90e8\:5165\:308c\:66ff\:3048\:308b\:3002 *)
SourceVaultClaudeAttachmentsIntegrationEnable[] :=
  Module[{},
    If[Length[Names["ClaudeCode`ClaudeAttachments"]] === 0,
      Print[Style["[SourceVault] claudecode.wl (ClaudeAttachments) \:304c\:898b\:3064\:304b\:308a\:307e\:305b\:3093\:3002", Red]];
      Return[<|"Status" -> "Failed", "Reason" -> "ClaudeAttachmentsNotFound"|>]];
    
    If[Length[DownValues[ClaudeCode`ClaudeAttachments]] === 0,
      Print[Style["[SourceVault] ClaudeAttachments \:306e DownValue \:304c\:7a7a\:3067\:3059\:3002", Red]];
      Return[<|"Status" -> "Failed", "Reason" -> "ClaudeAttachmentsEmpty"|>]];
    
    If[TrueQ[$IntegrationClaudeAttachmentsEnabled],
      Print["[SourceVault] ClaudeAttachments hook \:306f\:65e2\:306b\:6709\:52b9\:5316\:6e08\:307f (noop)\:3002"];
      Return[<|"Status" -> "AlreadyEnabled"|>]];
    
    $IntegrationClaudeAttachmentsOriginalDV =
      DownValues[ClaudeCode`ClaudeAttachments];
    
    DownValues[ClaudeCode`ClaudeAttachments] = {};
    
    (* Helper: original \:3092 Block \:30d5\:30ea\:30fc\:3067\:547c\:3076\:3002Options \:9000\:907f\:56de\:907f *)
    SourceVault`Private`iClaudeAttachmentsOriginalCall[args___] :=
      Module[{result, hookDV},
        hookDV = DownValues[ClaudeCode`ClaudeAttachments];
        DownValues[ClaudeCode`ClaudeAttachments] =
          SourceVault`Private`$IntegrationClaudeAttachmentsOriginalDV;
        result = CheckAbort[
          ClaudeCode`ClaudeAttachments[args],
          DownValues[ClaudeCode`ClaudeAttachments] = hookDV;
          Abort[]
        ];
        DownValues[ClaudeCode`ClaudeAttachments] = hookDV;
        result
      ];
    
    (* \:30aa\:30fc\:30d0\:30fc\:30ed\:30fc\:30c9 1: ClaudeAttachments[] *)
    ClaudeCode`ClaudeAttachments[] :=
      Module[{rawPaths, nb},
        nb = EvaluationNotebook[];
        rawPaths = SourceVault`Private`iClaudeAttachmentsOriginalCall[];
        If[!ListQ[rawPaths], Return[{}]];
        SourceVault`Private`iEnrichAttachments[rawPaths, nb]
      ];
    
    (* \:30aa\:30fc\:30d0\:30fc\:30ed\:30fc\:30c9 2: ClaudeAttachments[session] *)
    ClaudeCode`ClaudeAttachments[session_Association] :=
      Module[{rawPaths, nb},
        nb = Lookup[session, "Notebook", EvaluationNotebook[]];
        rawPaths = SourceVault`Private`iClaudeAttachmentsOriginalCall[session];
        If[!ListQ[rawPaths], Return[{}]];
        SourceVault`Private`iEnrichAttachments[rawPaths, nb]
      ];
    
    $IntegrationClaudeAttachmentsEnabled = True;
    Print[Style[
      "[SourceVault] ClaudeAttachments hook \:6709\:52b9\:5316\:3002", Bold]];
    Print["  ClaudeAttachments[] / ClaudeAttachments[session] \:306f Association list \:3092\:8fd4\:3059\:3088\:3046\:306b\:306a\:308b\:3002"];
    Print["  \:5404 entry: Path, DisplayName, Source, Keywords, Title, CachedAt,"];
    Print["              SnapshotId, SourceId, ContentHash, IngestStatus, AttachedAt"];
    Print["  \:7121\:52b9\:5316: SourceVaultClaudeAttachmentsIntegrationDisable[]"];
    <|"Status" -> "Enabled",
      "OriginalDVCount" -> Length[$IntegrationClaudeAttachmentsOriginalDV]|>
  ];

(* Disable *)
SourceVaultClaudeAttachmentsIntegrationDisable[] :=
  Module[{},
    If[!TrueQ[$IntegrationClaudeAttachmentsEnabled],
      Print["[SourceVault] ClaudeAttachments hook \:306f\:6709\:52b9\:5316\:3055\:308c\:3066\:3044\:307e\:305b\:3093 (noop)\:3002"];
      Return[<|"Status" -> "NotEnabled"|>]];
    
    If[ValueQ[$IntegrationClaudeAttachmentsOriginalDV] &&
       ListQ[$IntegrationClaudeAttachmentsOriginalDV],
      DownValues[ClaudeCode`ClaudeAttachments] = {};
      DownValues[ClaudeCode`ClaudeAttachments] = $IntegrationClaudeAttachmentsOriginalDV;
      $IntegrationClaudeAttachmentsEnabled = False;
      Print[Style["[SourceVault] ClaudeAttachments hook \:7121\:52b9\:5316\:3002", Bold]];
      Print["  ClaudeAttachments \:3092\:5143\:306e DownValue \:306b\:5fa9\:5143\:6e08\:307f\:3002"];
      <|"Status" -> "Disabled"|>,
      Print[Style["[SourceVault] \:5143\:306e DownValue \:30b9\:30ca\:30c3\:30d7\:30b7\:30e7\:30c3\:30c8\:304c\:898b\:3064\:304b\:308a\:307e\:305b\:3093\:3002", Red]];
      <|"Status" -> "Failed", "Reason" -> "NoOriginalSnapshot"|>]
  ];

(* Status *)
SourceVaultClaudeAttachmentsIntegrationStatus[] :=
  <|
    "Enabled" -> TrueQ[$IntegrationClaudeAttachmentsEnabled],
    "OriginalSaved" -> ListQ[$IntegrationClaudeAttachmentsOriginalDV],
    "OriginalDVCount" ->
      If[ListQ[$IntegrationClaudeAttachmentsOriginalDV],
        Length[$IntegrationClaudeAttachmentsOriginalDV], 0],
    "HookTarget" -> "ClaudeCode`ClaudeAttachments"
  |>;


(* ============================================================
   17. WorkerPrompt Integration (P3)
   
   ClaudeOrchestrator \:306e iWorkerBuildSystemPrompt \:5185\:306b A4 hook \:3068\:540c\:69d8\:306e
   A5 hook \:3092\:8a2d\:7f6e\:3057\:3001SourceVault \:306b\:767b\:9332\:6e08\:307f source \:306e\:62b9\:7c8b\:30c6\:30ad\:30b9\:30c8\:3092
   worker prompt \:306b\:6ce8\:5165\:3059\:308b\:3002
   
   \:30c8\:30ea\:30ac\:30fc:
     (a) \:660e\:793a\:6307\:5b9a: task["SourceSpans"] = {SnapshotId or Span Association, ...}
     (b) \:81ea\:52d5\:691c\:51fa: ClaudeAttach \:5c65\:6b74 (SourceVaultGetClaudeAttachRefs) \:304b\:3089
                     SnapshotId \:4e00\:89a7\:3092\:53d6\:5f97 ($SourceVaultWorkerPromptAutoDetect \:3067\:5236\:5fa1)
   
   \:524d\:63d0:
     ClaudeOrchestrator.wl \:306b A5 hook 5 \:884c\:304c\:8ffd\:52a0\:6e08\:307f
     (Phase 34 A4 hook \:3068\:540c\:4f4d\:7f6e\:3001\:540c\:30d1\:30bf\:30fc\:30f3)
   
   \:5b89\:5168\:6027:
     \:30fb hook \:306f Public \:30b7\:30f3\:30dc\:30eb ClaudeOrchestrator`A5InjectSourceVaultContext
     \:30fb \:30a8\:30e9\:30fc\:306f Quiet \:3067\:5305\:307f\:3001\:5fc5\:305a\:5143\:306e prompt \:307e\:305f\:306f\:6ce8\:5165\:5f8c\:306e
       prompt \:3092\:8fd4\:3059\:3002 \:64cd\:4f5c\:306b\:30a8\:30e9\:30fc\:304c\:3042\:3063\:3066\:3082 ClaudeOrchestrator \:306f\:52d5\:304f\:3002
   ============================================================ *)

(* hook \:6709\:52b9\:5316\:30d5\:30e9\:30b0 *)
If[!ValueQ[$IntegrationWorkerPromptEnabled],
  $IntegrationWorkerPromptEnabled = False];

(* SourceVaultGetClaudeAttachRefs \:304b\:3089 SnapshotId List \:3092\:53d6\:308a\:51fa\:3059 *)
iExtractSnapshotIdsFromRefs[refs_List] :=
  Cases[refs,
    ref_Association /; (KeyExistsQ[ref, "SnapshotId"] && StringQ[ref["SnapshotId"]]) :>
      ref["SnapshotId"]];

iAutoDetectSourceVaultRefs[] :=
  Module[{nb, refs, fromNB, fromMemory},
    (* 1st: \:30c8\:30c3\:30d7 notebook \:304c\:898b\:3048\:308b\:30b3\:30f3\:30c6\:30ad\:30b9\:30c8 (\:30e6\:30fc\:30b6\:304c\:76f4\:63a5\:5b9f\:884c\:6642) *)
    nb = Quiet[EvaluationNotebook[]];
    fromNB = If[nb =!= Null && nb =!= $Failed && Head[nb] =!= EvaluationNotebook,
      Quiet[SourceVaultGetClaudeAttachRefs[nb]],
      {}];
    If[!ListQ[fromNB], fromNB = {}];
    
    (* 2nd: \:30e1\:30e2\:30ea\:30ec\:30b8\:30b9\:30c8 (scheduled task / worker DAG \:306a\:3069 EvaluationNotebook[] \:304c
       \:898b\:3048\:306a\:3044\:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:7528 fallback) *)
    fromMemory = If[ListQ[$LastAttachedRefs], $LastAttachedRefs, {}];
    
    (* \:4e21\:65b9\:3092 merge\:3002SnapshotId \:3067 dedup\:3002Notebook \:304c\:898b\:3048\:306a\:3044\:30b1\:30fc\:30b9\:3067\:3082
       \:30e1\:30e2\:30ea\:30ec\:30b8\:30b9\:30c8\:304b\:3089 attach \:5c65\:6b74\:3092\:53d6\:308a\:51fa\:305b\:308b\:3002 *)
    refs = Join[fromNB, fromMemory];
    refs = DeleteDuplicatesBy[refs, Lookup[#, "SnapshotId", ""] &];
    DeleteDuplicates @ iExtractSnapshotIdsFromRefs[refs]
  ];

(* \:5358\:4e00 source (SnapshotId String \:307e\:305f\:306f Span Association) \:304b\:3089 text \:3092\:53d6\:5f97 *)
iResolveSourceToText[src_, maxChars_Integer:8000] :=
  Module[{span, ctx},
    Quiet[
      span = Which[
        StringQ[src] && StringStartsQ[src, "snap-"],
          SourceVaultSpan[src],
        StringQ[src] && StringStartsQ[src, "src-"],
          SourceVaultSpan[src],
        AssociationQ[src] && KeyExistsQ[src, "SnapshotId"],
          src,
        True,
          $Failed
      ];
      If[!AssociationQ[span], Return["", Module]];
      ctx = SourceVaultContext[span, MaxCharacters -> maxChars];
      If[AssociationQ[ctx] && Lookup[ctx, "Status", ""] === "OK" &&
         StringQ[Lookup[ctx, "Text", ""]],
        ctx["Text"],
        ""]
    ]
  ];

(* \:8907\:6570 sources \:304b\:3089 prompt \:306b\:6ce8\:5165\:3059\:308b context section \:3092\:69cb\:7bc9 *)
iBuildSourceVaultContextSection[sources_List] :=
  Module[{contexts, nonEmpty, body, header, footer, n, isJa, instruction},
    contexts = Map[iResolveSourceToText[#, 8000] &, sources];
    nonEmpty = Select[contexts, StringQ[#] && StringTrim[#] =!= "" &];
    n = Length[nonEmpty];
    If[n === 0,
      "",
      isJa = $Language === "Japanese";
      (* LLM \:304c\:300c<sources> \:306f\:53c2\:7167\:7528 \[NotEqual] \:4f9d\:5b58 artifact\:300d\:3068\:6df7\:540c\:3057\:306a\:3044\:3088\:3046\:3001
         \:30bf\:30b0\:540d\:3092 attached-documents \:3068\:3057\:3001
         \:300c\:4f9d\:5b58 artifact \:76f8\:5f53\:3068\:3057\:3066\:6271\:3046\:300d\:3068\:6307\:793a\:6587\:3092\:5165\:308c\:308b *)
      instruction = If[isJa,
        "<!-- \:4ee5\:4e0b\:306f worker \:30bf\:30b9\:30af\:304c\:53c2\:7167\:3059\:3079\:304d\:6df7\:6587 (\:4f9d\:5b58 artifact \:76f8\:5f53)\:3002Goal \:9054\:6210\:306b\:306f\:3053\:308c\:3089\:306e\:5185\:5bb9\:3092\:5fc5\:305a\:53c2\:7167\:3057\:3001\:8a73\:7d30\:30c7\:30fc\:30bf\:304c\:300c\:5b9f\:4f53\:300d\:3068\:3057\:3066\:3053\:3053\:306b\:5b58\:5728\:3057\:3066\:3044\:308b\:3068\:898b\:306a\:3057\:3066\:304f\:3060\:3055\:3044\:3002 -->",
        "<!-- The following documents are reference content (treat as dependency artifacts).\n     Use them to fulfill the Goal; their full text is provided here as ground truth. -->"];
      header = "<attached-documents count=\"" <> ToString[n] <> "\">\n" <>
        instruction <> "\n";
      body = StringJoin @ MapIndexed[
        Function[{txt, idx},
          "<document index=\"" <> ToString[First[idx]] <> "\">\n" <>
          txt <> "\n</document>\n"],
        nonEmpty];
      footer = "</attached-documents>";
      header <> body <> footer
    ]
  ];

(* \:30e1\:30a4\:30f3\:306e A5 hook \:5b9f\:88c5\:95a2\:6570 *)
iA5InjectSourceVaultContext[prompt_, role_, task_] :=
  Module[{explicitSources, propagatedSources, autoSources, allSources,
          contextText, finalPrompt, promptStr, replaced, newPrompt},
    Quiet[
      explicitSources = If[AssociationQ[task],
        Lookup[task, "SourceSpans", {}], {}];
      If[!ListQ[explicitSources], explicitSources = {}];
      
      (* P4 \:9023\:643a: \:524d\:30bf\:30fc\:30f3\:306e parseProposal \:304c\:62bd\:51fa\:3057\:305f
         SourceVaultRefs \:3082\:30bd\:30fc\:30b9\:3068\:3057\:3066\:53d6\:308a\:8fbc\:3080 *)
      propagatedSources = If[AssociationQ[task],
        Lookup[task, "SourceVaultRefs", {}], {}];
      If[!ListQ[propagatedSources], propagatedSources = {}];
      
      autoSources = If[TrueQ[$SourceVaultWorkerPromptAutoDetect],
        iAutoDetectSourceVaultRefs[],
        {}];
      
      (* explicit \:304c\:512a\:5148\:3001\:6b21\:306b propagated\:3001\:305d\:306e\:5f8c auto \:3092\:91cd\:8907\:9664\:53bb\:3057\:3066\:8ffd\:52a0 *)
      allSources = explicitSources;
      Do[
        If[!MemberQ[allSources, s], AppendTo[allSources, s]],
        {s, Join[propagatedSources, autoSources]}];
      
      promptStr = If[StringQ[prompt], prompt, ToString[prompt]];
      
      If[Length[allSources] === 0,
        Return[promptStr, Module]];
      
      contextText = iBuildSourceVaultContextSection[allSources];
      
      If[!StringQ[contextText] || StringTrim[contextText] === "",
        Return[promptStr, Module]];
      
      (* DEPENDENCY_SECTION \:306e\:300c\:306a\:3057\:300d\:30e9\:30d9\:30eb\:3092 context \:3067\:7f6e\:63db\:3059\:308b\:3002
         ClaudeOrchestrator \:306e iWorkerBuildSystemPrompt \:304c\:51fa\:529b\:3059\:308b
         \:300c\:4f9d\:5b58 artifact \:306a\:3057\:300d\:307e\:305f\:306f "No dependency artifacts."
         \:3092 attached-documents \:30bb\:30af\:30b7\:30e7\:30f3\:3067\:7f6e\:63db\:3002
         \:3053\:308c\:306b\:3088\:308a LLM \:306f\:300c\:4f9d\:5b58 artifact = attached-documents \:306e\:5185\:5bb9\:300d\:3068\:8aad\:3080\:3002
         \:30e9\:30d9\:30eb\:304c\:898b\:3064\:304b\:3089\:306a\:3044 (\:4ed6\:7d4c\:8def) \:5834\:5408\:306f\:5f93\:6765\:901a\:308a prepend \:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3002 *)
      replaced = False;
      Do[
        newPrompt = StringReplace[promptStr, pat -> contextText, 1];
        If[newPrompt =!= promptStr,
          promptStr = newPrompt;
          replaced = True;
          Break[]],
        {pat, {"\:4f9d\:5b58 artifact \:306a\:3057\:3002",
               "No dependency artifacts."}}];
      
      finalPrompt = If[replaced,
        promptStr,
        (* fallback: prepend (\:6cd5\:5b9a DEPENDENCY_SECTION \:304c\:898b\:3064\:304b\:3089\:306a\:3044 \:307e\:305f\:306f
           \:65e2\:306b\:4f9d\:5b58 artifact \:304c\:3042\:308b\:5834\:5408) *)
        contextText <> "\n\n---\n\n" <> promptStr];
      
      finalPrompt
    ]
  ];

(* Enable *)
SourceVaultWorkerPromptIntegrationEnable[] :=
  Module[{},
    If[TrueQ[$IntegrationWorkerPromptEnabled],
      Print["[SourceVault] WorkerPrompt hook \:306f\:65e2\:306b\:6709\:52b9\:5316\:6e08\:307f (noop)\:3002"];
      Return[<|"Status" -> "AlreadyEnabled"|>]];
    
    (* A5 hook \:5b9a\:7fa9\:3092 ClaudeOrchestrator \:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:306b\:767b\:9332 *)
    ClaudeOrchestrator`A5InjectSourceVaultContext[
        prompt_, role_, task_] :=
      SourceVault`Private`iA5InjectSourceVaultContext[prompt, role, task];
    
    $IntegrationWorkerPromptEnabled = True;
    Print[Style[
      "[SourceVault] WorkerPrompt hook \:6709\:52b9\:5316\:3002", Bold]];
    Print["  ClaudeOrchestrator \:306e A5 hook \:306b SourceVault context \:6ce8\:5165\:95a2\:6570\:3092\:767b\:9332\:6e08\:307f\:3002"];
    Print["  \:660e\:793a\:6307\:5b9a:  task[\"SourceSpans\"] = {SnapshotId or Span Assoc, ...}"];
    Print["  \:81ea\:52d5\:691c\:51fa:  $SourceVaultWorkerPromptAutoDetect = ",
      TrueQ[$SourceVaultWorkerPromptAutoDetect]];
    Print["  \:7121\:52b9\:5316:    SourceVaultWorkerPromptIntegrationDisable[]"];
    <|"Status" -> "Enabled",
      "AutoDetect" -> TrueQ[$SourceVaultWorkerPromptAutoDetect]|>
  ];

(* Disable *)
SourceVaultWorkerPromptIntegrationDisable[] :=
  Module[{},
    If[!TrueQ[$IntegrationWorkerPromptEnabled],
      Print["[SourceVault] WorkerPrompt hook \:306f\:6709\:52b9\:5316\:3055\:308c\:3066\:3044\:307e\:305b\:3093 (noop)\:3002"];
      Return[<|"Status" -> "NotEnabled"|>]];
    
    Clear[ClaudeOrchestrator`A5InjectSourceVaultContext];
    $IntegrationWorkerPromptEnabled = False;
    Print[Style["[SourceVault] WorkerPrompt hook \:7121\:52b9\:5316\:3002", Bold]];
    Print["  A5InjectSourceVaultContext \:3092\:30af\:30ea\:30a2\:3057\:305f\:3002"];
    <|"Status" -> "Disabled"|>
  ];

(* Status *)
SourceVaultWorkerPromptIntegrationStatus[] :=
  <|
    "Enabled" -> TrueQ[$IntegrationWorkerPromptEnabled],
    "AutoDetect" -> TrueQ[$SourceVaultWorkerPromptAutoDetect],
    "HookTarget" -> "ClaudeOrchestrator`A5InjectSourceVaultContext",
    "HookFunctionDefined" ->
      Length[Names["ClaudeOrchestrator`A5InjectSourceVaultContext"]] > 0 &&
      Length[DownValues[ClaudeOrchestrator`A5InjectSourceVaultContext]] > 0
  |>;


(* ============================================================
   18. ParseProposal Integration (P4)
   
   ClaudeOrchestrator \:306e iApplyA6Hook \:7d4c\:7531\:3067 parseProposal \:306e
   \:623b\:308a\:5024\:3092 post-process \:3057\:3001LLM \:5fdc\:7b54\:5185\:306e
   <source>snap-...</source> / <source>src-...</source> XML \:30bf\:30b0\:3092
   \:62bd\:51fa\:3057\:3066 result Association \:306b "SourceVaultRefs" \:30ad\:30fc\:3092\:8ffd\:52a0\:3059\:308b\:3002
   
   \:6d41\:308c (\:30e6\:30fc\:30b9\:30b1\:30fc\:30b9 C):
     1. LLM \:304c\:51fa\:529b\:306b <source>snap-...</source> \:3092\:542b\:3081\:308b
     2. P4 A6 hook \:304c parseProposal \:306e\:623b\:308a\:5024\:306b
        "SourceVaultRefs" -> {"snap-..."} \:3092\:8ffd\:52a0
     3. caller \:304c\:6b21\:30bf\:30fc\:30f3\:306e task \:306b "SourceVaultRefs" \:304c\:8a18\:8ff0\:3055\:308c\:308b
        \:3088\:3046\:4f1d\:642c\:3059\:308b (\:5fc5\:8981\:306b\:5fdc\:3058\:3066)
     4. P3 A5 hook \:304c task["SourceVaultRefs"] + task["SourceSpans"]
        + ClaudeAttach \:5c65\:6b74 \:3092\:7d71\:5408\:3057\:3066 worker prompt \:306b\:6ce8\:5165
   
   \:6cf3\:30c8\:30ea\:30ac\:30fc:
     XML \:30bf\:30b0 <source>...</source> \:5185\:90e8\:306b snap- / src- ID \:304c\:3042\:308b\:3068\:62bd\:51fa\:3002
     \:691c\:51fa\:3055\:308c\:305f ID \:306f result Association \:306b "SourceVaultRefs" \:30ad\:30fc\:3068\:3057\:3066\:8ffd\:52a0\:3002
   
   \:524d\:63d0:
     ClaudeOrchestrator.wl \:306b iApplyA6Hook + A6 hook \:5448\:5165\:6e08\:307f (P4 \:5bfe\:5fdc\:7248)\:3002
   ============================================================ *)

(* hook \:6709\:52b9\:5316\:30d5\:30e9\:30b0 *)
If[!ValueQ[$IntegrationParseProposalEnabled],
  $IntegrationParseProposalEnabled = False];

(* LLM \:5fdc\:7b54\:30c6\:30ad\:30b9\:30c8\:304b\:3089 <source>...</source> XML \:30bf\:30b0\:3092\:62bd\:51fa\:3002
   \:30bf\:30b0\:5185\:90e8\:306e snap-\... / src-... ID \:3092\:30ea\:30b9\:30c8\:3068\:3057\:3066\:8fd4\:3059\:3002 *)
iExtractSourceVaultRefsFromText[rawStr_String] :=
  Module[{matches},
    matches = Quiet[
      StringCases[rawStr,
        RegularExpression[
          "(?s)<source>\\s*(snap-[A-Za-z0-9-]+|src-[A-Za-z0-9_-]+)\\s*</source>"
        ] :> "$1"]];
    If[ListQ[matches],
      DeleteDuplicates[matches],
      {}]
  ];

iExtractSourceVaultRefsFromText[_] := {};

(* A6 hook \:5b9f\:88c5\:95a2\:6570: parseProposal \:306e\:623b\:308a\:5024 result \:306b
   SourceVaultRefs \:30ad\:30fc\:3092\:8ffd\:52a0\:3057\:305f\:3082\:306e\:3092\:8fd4\:3059\:3002 *)
iA6PostProcessParseProposal[result_, rawStr_] :=
  Module[{refs, newResult},
    If[!AssociationQ[result], Return[result, Module]];
    refs = Quiet[iExtractSourceVaultRefsFromText[
      If[StringQ[rawStr], rawStr, ToString[rawStr]]]];
    If[!ListQ[refs] || Length[refs] === 0,
      Return[result, Module]];
    newResult = result;
    newResult["SourceVaultRefs"] = refs;
    newResult
  ];

(* Enable *)
SourceVaultParseProposalIntegrationEnable[] :=
  Module[{},
    If[TrueQ[$IntegrationParseProposalEnabled],
      Print["[SourceVault] ParseProposal hook \:306f\:65e2\:306b\:6709\:52b9\:5316\:6e08\:307f (noop)\:3002"];
      Return[<|"Status" -> "AlreadyEnabled"|>]];
    
    (* A6 hook \:5b9a\:7fa9\:3092 ClaudeOrchestrator \:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:306b\:767b\:9332 *)
    ClaudeOrchestrator`A6PostProcessParseProposal[result_, rawStr_] :=
      SourceVault`Private`iA6PostProcessParseProposal[result, rawStr];
    
    $IntegrationParseProposalEnabled = True;
    Print[Style[
      "[SourceVault] ParseProposal hook \:6709\:52b9\:5316\:3002", Bold]];
    Print["  ClaudeOrchestrator \:306e A6 hook \:306b parseProposal post-processing \:3092\:767b\:9332\:6e08\:307f\:3002"];
    Print["  \:62bd\:51fa syntax: <source>snap-...</source> / <source>src-...</source>"];
    Print["  \:62bd\:51fa\:7d50\:679c\:306f result[\"SourceVaultRefs\"] \:306b\:8ffd\:52a0\:3055\:308c\:308b\:3002"];
    Print["  \:7121\:52b9\:5316:  SourceVaultParseProposalIntegrationDisable[]"];
    <|"Status" -> "Enabled"|>
  ];

(* Disable *)
SourceVaultParseProposalIntegrationDisable[] :=
  Module[{},
    If[!TrueQ[$IntegrationParseProposalEnabled],
      Print["[SourceVault] ParseProposal hook \:306f\:6709\:52b9\:5316\:3055\:308c\:3066\:3044\:307e\:305b\:3093 (noop)\:3002"];
      Return[<|"Status" -> "NotEnabled"|>]];
    
    Clear[ClaudeOrchestrator`A6PostProcessParseProposal];
    $IntegrationParseProposalEnabled = False;
    Print[Style["[SourceVault] ParseProposal hook \:7121\:52b9\:5316\:3002", Bold]];
    <|"Status" -> "Disabled"|>
  ];

(* Status *)
SourceVaultParseProposalIntegrationStatus[] :=
  <|
    "Enabled" -> TrueQ[$IntegrationParseProposalEnabled],
    "HookTarget" -> "ClaudeOrchestrator`A6PostProcessParseProposal",
    "HookFunctionDefined" ->
      Length[Names["ClaudeOrchestrator`A6PostProcessParseProposal"]] > 0 &&
      Length[DownValues[ClaudeOrchestrator`A6PostProcessParseProposal]] > 0,
    "DetectionPattern" -> "<source>snap-...|src-...</source>"
  |>;




(* ===================================================== *)
(* Phase 4.18 : handoff 7.3 SourceVault-side resolver,    *)
(* merged-in (formerly a standalone add-on file).         *)
(* ===================================================== *)

(* ---- resolver: notebook path -> SourceVault context ---- *)

SourceVault`iPreflightContextResolver[path_String] :=
  Module[{uuid},
    (* SourceVaultNotebookUUID is read-only: it opens the notebook,
       reads TaggingRules > SourceVault > NotebookUUID, and closes it.
       It returns the UUID string, or Missing["FileNotFound"
       | "OpenFailed" | "NoUUID"]. *)
    uuid = Quiet @ Check[
      SourceVaultNotebookUUID[path],
      Missing["ResolveError"]];
    If[StringQ[uuid] && uuid =!= "",
      <|"InVault" -> True,
        "NotebookUUID" -> uuid,
        "NotebookRef" -> <|
          "Type" -> "SourceVaultNotebook",
          "NotebookUUID" -> uuid|>|>,
      <|"InVault" -> False,
        "NotebookUUID" -> uuid|>
    ]
  ];
SourceVault`iPreflightContextResolver[_] := Missing["InvalidPath"];

(* ---- register the resolver into the claudecode 7.3 hook ---- *)
(* Load-order independent.  ClaudeCode`$ClaudeCloudSendPreflightContextResolver
   is a plain hook variable; assigning it here also works when
   SourceVault.wl is loaded BEFORE claudecode.wl, because claudecode.wl
   initialises that variable with If[!ValueQ[...], ...=None] and therefore
   preserves the resolver set here.  claudecode.wl still has no static
   dependency on SourceVault (rule 11): the dependency direction stays
   SourceVault -> claudecode. *)
ClaudeCode`$ClaudeCloudSendPreflightContextResolver =
  SourceVault`iPreflightContextResolver;


(* ===================================================================
   Phase 2a: DirectiveRepository source kind
   Spec 5th review: sections 11.1 / 11.2.
   Snapshot store layout:
     <PrivateVault>/directive-repositories/<repoId>/registration.json
     <PrivateVault>/directive-repositories/<repoId>/snapshot-<id>.json
   =================================================================== *)

(* ---- store layout ---- *)

iDirRepoStoreDir[] :=
  Module[{d},
    d = FileNameJoin[{SourceVault`$SourceVaultRoots["PrivateVault"],
      "directive-repositories"}];
    iEnsureDir[d];
    d];

(* deterministic repo id from the repository root path *)
iDirRepoId[root_String] :=
  "dirrepo-" <> StringTake[
    ToLowerCase[Hash[ExpandFileName[root], "SHA256", "HexString"]],
    UpTo[16]];

iDirRepoDir[repoId_String] :=
  Module[{d},
    d = FileNameJoin[{iDirRepoStoreDir[], repoId}];
    iEnsureDir[d];
    d];

(* snapshot id: manifest-hash tail + millisecond timestamp *)
iMakeDirSnapshotId[manifestHash_] :=
  Module[{h},
    h = StringReplace[ToLowerCase[ToString[manifestHash]],
      RegularExpression["[^a-z0-9]"] -> ""];
    h = If[StringLength[h] >= 12, StringTake[h, -12], h];
    "dirsnap-" <> h <> "-" <>
      ToString[Round[AbsoluteTime[] * 1000]]];

(* ---- JSON I/O (SourceVault style: RawJSON + ISO8859-1) ---- *)

iDirRepoWriteJSON[path_String, assoc_Association] :=
  Module[{sanitized, json, strm},
    sanitized = iSanitizeForJSON[assoc];
    json = Quiet @ ExportString[sanitized, "RawJSON",
      "Compact" -> False];
    If[!StringQ[json],
      Return[<|"Status" -> "Failed",
        "Reason" -> "JSONEncodeFailed", "Path" -> path|>]];
    iEnsureDir[DirectoryName[path]];
    strm = Quiet[OpenWrite[path, BinaryFormat -> True]];
    If[Head[strm] =!= OutputStream,
      Return[<|"Status" -> "Failed",
        "Reason" -> "OpenWriteFailed", "Path" -> path|>]];
    BinaryWrite[strm, StringToByteArray[json, "ISO8859-1"]];
    (* Stage 9 P1.5 utf8fix: ExportString["RawJSON"] \:306e\:623b\:308a\:5024\:306f UTF-8 byte \:306e
       Latin-1 \:8868\:73fe\:306a\:306e\:3067 ISO8859-1 \:3067 byte \:5316 (\:65e7 UTF-8 \:306f\:4e8c\:91cd encode)\:3002
       \:8aad\:307f\:53d6\:308a iDirRepoReadJSON \:306e ByteArrayToString[..., "UTF-8"] \:3068\:6574\:5408\:3002 *)
    Close[strm];
    <|"Status" -> "OK", "Path" -> path|>];

iDirRepoReadJSON[path_String] :=
  Module[{rawBytes, content, parsed},
    If[!FileExistsQ[path], Return[Missing["NotFound"]]];
    rawBytes = Quiet[ReadByteArray[path]];
    If[!ByteArrayQ[rawBytes], Return[Missing["ReadFailed"]]];
    content = Quiet[ByteArrayToString[rawBytes, "UTF-8"]];
    If[!StringQ[content], Return[Missing["DecodeFailed"]]];
    parsed = Quiet[ImportString[content, "RawJSON"]];
    If[ListQ[parsed] && !AssociationQ[parsed],
      parsed = Association[parsed]];
    If[AssociationQ[parsed], parsed, Missing["ParseFailed"]]];

(* ---- snapshot enumeration ---- *)

iDirSnapshotPaths[repoId_String] :=
  Module[{d, files},
    d = iDirRepoDir[repoId];
    files = FileNames["snapshot-*.json", d];
    SortBy[files, FileDate[#, "Modification"] &]];

iLatestDirSnapshotRecord[repoId_String] :=
  Module[{paths},
    paths = iDirSnapshotPaths[repoId];
    If[paths === {},
      Missing["NoSnapshot"],
      iDirRepoReadJSON[Last[paths]]]];

(* ---- SourceVaultRegisterDirectiveRepository (spec 11.1) ---- *)

SourceVaultRegisterDirectiveRepository[
    root_String, opts:OptionsPattern[]] :=
  Module[{repoId, regPath, regRecord, saveRes},
    Needs["ClaudeDirectives`"];
    iEnsureRoots[];
    If[!DirectoryQ[root],
      Return[<|"Status" -> "Failed",
        "Reason" -> "RootNotADirectory", "Root" -> root|>]];
    repoId = iDirRepoId[root];
    regRecord = <|
      "Kind"            -> "DirectiveRepositoryRegistration",
      "RepoId"          -> repoId,
      "Root"            -> ExpandFileName[root],
      "CanonicalFormat" -> "ClaudeDirectives",
      "Tool"            -> "claudecode_directives",
      "RegisteredAt"    -> DateString[Now]|>;
    regPath = FileNameJoin[{iDirRepoDir[repoId],
      "registration.json"}];
    saveRes = iDirRepoWriteJSON[regPath, regRecord];
    If[Lookup[saveRes, "Status", ""] === "OK",
      <|"Status"       -> "OK",
        "RepoId"       -> repoId,
        "Root"         -> ExpandFileName[root],
        "Path"         -> regPath,
        "Registration" -> regRecord|>,
      <|"Status" -> "Failed",
        "Reason" -> Lookup[saveRes, "Reason", "Unknown"],
        "RepoId" -> repoId|>]];

SourceVaultRegisterDirectiveRepository[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments"|>;

(* ---- SourceVaultIndexDirectiveRepository (spec 11.1 / 11.2) ---- *)

SourceVaultIndexDirectiveRepository[
    root_String, opts:OptionsPattern[]] :=
  Module[{repoId, regPath, inv, manifestHash, snapId, snapRecord,
          snapPath, saveRes},
    Needs["ClaudeDirectives`"];
    iEnsureRoots[];
    If[!DirectoryQ[root],
      Return[<|"Status" -> "Failed",
        "Reason" -> "RootNotADirectory", "Root" -> root|>]];
    repoId = iDirRepoId[root];
    regPath = FileNameJoin[{iDirRepoDir[repoId],
      "registration.json"}];
    If[!FileExistsQ[regPath],
      SourceVaultRegisterDirectiveRepository[root]];

    inv = ClaudeDirectives`ClaudeDirectiveFileInventory[root];
    If[FailureQ[inv] || !ListQ[inv],
      Return[<|"Status" -> "Failed",
        "Reason" -> "InventoryFailed", "RepoId" -> repoId|>]];
    manifestHash =
      ClaudeDirectives`ClaudeDirectiveRepositoryHash[root];

    snapId = iMakeDirSnapshotId[manifestHash];
    snapRecord = <|
      "Kind"            -> "DirectiveRepository",
      "CanonicalFormat" -> "ClaudeDirectives",
      "Root"            -> ExpandFileName[root],
      "RepoId"          -> repoId,
      "SnapshotId"      -> snapId,
      "Files"           -> inv,
      "FileCount"       -> Length[inv],
      "ManifestHash"    -> manifestHash,
      "CreatedAt"       -> DateString[Now],
      "Tool"            -> "claudecode_directives"|>;
    snapPath = FileNameJoin[{iDirRepoDir[repoId],
      "snapshot-" <> snapId <> ".json"}];
    saveRes = iDirRepoWriteJSON[snapPath, snapRecord];
    If[Lookup[saveRes, "Status", ""] === "OK",
      <|"Status"       -> "OK",
        "RepoId"       -> repoId,
        "SnapshotId"   -> snapId,
        "ManifestHash" -> manifestHash,
        "FileCount"    -> Length[inv],
        "Path"         -> snapPath,
        "Snapshot"     -> snapRecord|>,
      <|"Status" -> "Failed",
        "Reason" -> Lookup[saveRes, "Reason", "Unknown"],
        "RepoId" -> repoId|>]];

SourceVaultIndexDirectiveRepository[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments"|>;

(* ---- SourceVaultCurrentDirectiveSnapshot (spec 11.1) ---- *)

SourceVaultCurrentDirectiveSnapshot[
    root_String, opts:OptionsPattern[]] :=
  Module[{repoId, rec},
    iEnsureRoots[];
    repoId = iDirRepoId[root];
    rec = iLatestDirSnapshotRecord[repoId];
    If[AssociationQ[rec],
      rec,
      <|"Status" -> "NoSnapshot",
        "RepoId" -> repoId, "Root" -> root|>]];

SourceVaultCurrentDirectiveSnapshot[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments"|>;

(* ---- SourceVaultDirectiveRepositoryStatus (spec 11.4) ---- *)

SourceVaultDirectiveRepositoryStatus[
    root_String, opts:OptionsPattern[]] :=
  Module[{repoId, regPath, registered, snapCount, latest,
          snapHash, currentHash, upToDate, status},
    Needs["ClaudeDirectives`"];
    iEnsureRoots[];
    repoId = iDirRepoId[root];
    regPath = FileNameJoin[{iDirRepoDir[repoId],
      "registration.json"}];
    registered = FileExistsQ[regPath];
    snapCount  = Length[iDirSnapshotPaths[repoId]];
    latest     = iLatestDirSnapshotRecord[repoId];
    snapHash = If[AssociationQ[latest],
      Lookup[latest, "ManifestHash", Missing["NotAvailable"]],
      Missing["NoSnapshot"]];
    currentHash = If[DirectoryQ[root],
      ClaudeDirectives`ClaudeDirectiveRepositoryHash[root],
      Missing["RootMissing"]];
    upToDate = StringQ[snapHash] && StringQ[currentHash] &&
      snapHash === currentHash;
    status = Which[
      !registered,        "NotRegistered",
      snapCount === 0,    "RegisteredNotIndexed",
      upToDate,           "UpToDate",
      True,               "Stale"];
    <|
      "Status"              -> status,
      "RepoId"              -> repoId,
      "Root"                -> root,
      "Registered"          -> registered,
      "SnapshotCount"       -> snapCount,
      "LatestSnapshotId"    -> If[AssociationQ[latest],
        Lookup[latest, "SnapshotId", Missing["NotAvailable"]],
        Missing["NoSnapshot"]],
      "LatestManifestHash"  -> snapHash,
      "CurrentManifestHash" -> currentHash,
      "UpToDate"            -> upToDate
    |>];

SourceVaultDirectiveRepositoryStatus[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments"|>;

(* ---- SourceVaultDiffDirectiveSnapshots (spec 11.1) ---- *)

SourceVaultDiffDirectiveSnapshots[old_, new_, opts:OptionsPattern[]] :=
  Module[{oldRec, newRec, oldFiles, newFiles, oldMap, newMap,
          oldKeys, newKeys, added, removed, changed, unchanged},
    oldRec = Which[
      AssociationQ[old], old,
      StringQ[old],      iDirRepoReadJSON[old],
      True,              $Failed];
    newRec = Which[
      AssociationQ[new], new,
      StringQ[new],      iDirRepoReadJSON[new],
      True,              $Failed];
    If[!AssociationQ[oldRec] || !AssociationQ[newRec],
      Return[<|"Status" -> "Failed",
        "Reason" -> "InvalidSnapshotArguments"|>]];
    oldFiles = Lookup[oldRec, "Files", {}];
    newFiles = Lookup[newRec, "Files", {}];
    If[!ListQ[oldFiles], oldFiles = {}];
    If[!ListQ[newFiles], newFiles = {}];
    oldMap = Association[
      (Lookup[#, "RelativePath", ""] ->
        Lookup[#, "ContentHash", ""]) & /@ oldFiles];
    newMap = Association[
      (Lookup[#, "RelativePath", ""] ->
        Lookup[#, "ContentHash", ""]) & /@ newFiles];
    oldKeys = Keys[oldMap];
    newKeys = Keys[newMap];
    added   = Complement[newKeys, oldKeys];
    removed = Complement[oldKeys, newKeys];
    changed = Select[Intersection[oldKeys, newKeys],
      oldMap[#] =!= newMap[#] &];
    unchanged = Select[Intersection[oldKeys, newKeys],
      oldMap[#] === newMap[#] &];
    <|
      "Status"              -> "OK",
      "Added"               -> Sort[added],
      "Removed"             -> Sort[removed],
      "Changed"             -> Sort[changed],
      "UnchangedCount"      -> Length[unchanged],
      "ManifestHashChanged" ->
        (Lookup[oldRec, "ManifestHash", Missing["a"]] =!=
         Lookup[newRec, "ManifestHash", Missing["b"]])
    |>];

SourceVaultDiffDirectiveSnapshots[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments"|>;


(* ===================================================================
   Phase 2b: HarnessMaterialization bundle kind + stale judgement
   Spec 5th review: sections 11.3 / 11.4.
   The bundle is written with iDirRepoWriteJSON (UTF-8) so that a
   non-ASCII DirectiveRoot path round-trips correctly and the bundle
   is still readable via the UTF-8 iBundleLoad path.
   =================================================================== *)

(* ---- canonical, order-independent hash of an environment value ---- *)

iCanonicalSort[a_Association] := KeySort[iCanonicalSort /@ a];
iCanonicalSort[l_List]        := iCanonicalSort /@ l;
iCanonicalSort[x_]            := x;

iCanonicalAssocHash[expr_] :=
  Module[{json},
    json = Quiet @ ExportString[
      iSanitizeForJSON[iCanonicalSort[expr]],
      "RawJSON", "Compact" -> True];
    If[!StringQ[json], Return[Missing["HashFailed"]]];
    "sha256-" <> ToLowerCase[Hash[json, "SHA256", "HexString"]]];

(* resolve a runtime-environment hash from currentEnv: use a
   precomputed <hashKey> if present, else hash the raw <dataKey> *)
iHarnessEnvHash[envAssoc_Association, dataKey_String, hashKey_String] :=
  Which[
    StringQ[Lookup[envAssoc, hashKey, Null]],
      Lookup[envAssoc, hashKey],
    KeyExistsQ[envAssoc, dataKey],
      iCanonicalAssocHash[Lookup[envAssoc, dataKey]],
    True,
      Missing["NotProvided"]];

iHarnessEnvHash[___] := Missing["NotProvided"];

(* ---- SourceVaultRegisterHarnessMaterialization (spec 11.3) ---- *)

SourceVaultRegisterHarnessMaterialization[
    target_String, files_List, meta_Association] :=
  Module[{bundleId, defaultFn, bundle, saveRes},
    iEnsureRoots[];
    If[!MemberQ[{"Codex", "ClaudeCLI"}, target],
      Return[<|"Status" -> "Failed",
        "Reason" -> "InvalidTarget", "Target" -> target|>]];
    bundleId = iMakeBundleId["harness-" <> ToLowerCase[target]];
    defaultFn = If[target === "Codex",
      "ClaudeDirectiveMaterializeCodexHarness",
      "ClaudeDirectiveMaterializeClaudeHarness"];
    bundle = <|
      "BundleId"     -> bundleId,
      "Kind"         -> "HarnessMaterialization",
      "Target"       -> target,
      "HarnessMode"  -> Lookup[meta, "HarnessMode", "Generated"],
      "GeneratedFiles" -> files,
      "GeneratedAt"  -> DateString[Now],
      "DirectiveRoot" ->
        Lookup[meta, "DirectiveRoot", Missing["NotProvided"]],
      "DirectiveRepositorySnapshotId" ->
        Lookup[meta, "DirectiveRepositorySnapshotId",
          Missing["NotProvided"]],
      "DirectiveRepositoryManifestHash" ->
        Lookup[meta, "DirectiveRepositoryManifestHash",
          Missing["NotProvided"]],
      "RuntimeEnvironmentHash" ->
        Lookup[meta, "RuntimeEnvironmentHash",
          Missing["NotProvided"]],
      "PermissionProfileHash" ->
        Lookup[meta, "PermissionProfileHash",
          Missing["NotProvided"]],
      "Generator" -> Lookup[meta, "Generator", <|
        "Package"  -> "claudecode_directives",
        "Function" -> defaultFn,
        "HarnessMaterializationMode" ->
          Lookup[meta, "HarnessMaterializationMode",
            "BootstrapIndexSkills"]|>]
    |>;
    (* UTF-8 write (iDirRepoWriteJSON) so a non-ASCII DirectiveRoot
       survives the round trip; iBundleLoad reads UTF-8 too *)
    saveRes = iDirRepoWriteJSON[iBundlePath[bundleId], bundle];
    If[Lookup[saveRes, "Status", ""] === "OK",
      <|"Status"   -> "OK",
        "BundleId" -> bundleId,
        "Path"     -> Lookup[saveRes, "Path", ""],
        "Bundle"   -> bundle|>,
      <|"Status" -> "Failed",
        "Reason" -> Lookup[saveRes, "Reason", "Unknown"],
        "BundleId" -> bundleId|>]];

SourceVaultRegisterHarnessMaterialization[___] :=
  <|"Status" -> "Failed", "Reason" -> "InvalidArguments"|>;

(* ---- SourceVaultDirectiveSnapshotStaleQ (spec 11.4) ---- *)

SourceVaultDirectiveSnapshotStaleQ[bundle_Association] :=
  Module[{root, recordedHash, currentHash, stale},
    Needs["ClaudeDirectives`"];
    recordedHash = Lookup[bundle, "DirectiveRepositoryManifestHash",
      Missing["NotAvailable"]];
    root = Lookup[bundle, "DirectiveRoot", Missing["NotAvailable"]];
    If[!StringQ[root] || !DirectoryQ[root],
      Return[<|
        "Stale"  -> Missing["RootUnavailable"],
        "Reason" -> "DirectiveRoot not available; cannot compare.",
        "RecordedManifestHash" -> recordedHash,
        "CurrentManifestHash"  -> Missing["RootUnavailable"]|>]];
    currentHash =
      ClaudeDirectives`ClaudeDirectiveRepositoryHash[root];
    stale = StringQ[recordedHash] && StringQ[currentHash] &&
      recordedHash =!= currentHash;
    <|
      "Stale"  -> stale,
      "Reason" -> If[stale,
        "CanonicalDirectiveSnapshotStale", "UpToDate"],
      "RecordedManifestHash" -> recordedHash,
      "CurrentManifestHash"  -> currentHash
    |>];

SourceVaultDirectiveSnapshotStaleQ[___] :=
  <|"Stale" -> $Failed, "Reason" -> "InvalidArguments"|>;

(* ---- SourceVaultHarnessRuntimeEnvironmentChangedQ (spec 11.4) ---- *)

SourceVaultHarnessRuntimeEnvironmentChangedQ[
    bundle_Association, currentEnv_Association] :=
  Module[{recPerm, recEnv, curPerm, curEnv, permChanged, envChanged},
    recPerm = Lookup[bundle, "PermissionProfileHash",
      Missing["NotAvailable"]];
    recEnv  = Lookup[bundle, "RuntimeEnvironmentHash",
      Missing["NotAvailable"]];
    curPerm = iHarnessEnvHash[currentEnv,
      "PermissionProfile", "PermissionProfileHash"];
    curEnv  = iHarnessEnvHash[currentEnv,
      "RuntimeEnvironment", "RuntimeEnvironmentHash"];
    permChanged = StringQ[recPerm] && StringQ[curPerm] &&
      recPerm =!= curPerm;
    envChanged  = StringQ[recEnv] && StringQ[curEnv] &&
      recEnv =!= curEnv;
    <|
      "Changed" -> (permChanged || envChanged),
      "Reason"  -> If[permChanged || envChanged,
        "RuntimeEnvironmentChanged", "Unchanged"],
      "PermissionProfileChanged"  -> permChanged,
      "RuntimeEnvironmentChanged" -> envChanged,
      "RecordedPermissionProfileHash"  -> recPerm,
      "CurrentPermissionProfileHash"   -> curPerm,
      "RecordedRuntimeEnvironmentHash" -> recEnv,
      "CurrentRuntimeEnvironmentHash"  -> curEnv
    |>];

SourceVaultHarnessRuntimeEnvironmentChangedQ[___] :=
  <|"Changed" -> $Failed, "Reason" -> "InvalidArguments"|>;

End[];   (* `Private` *)

EndPackage[];


(* ============================================================
   $SourceVaultVersion \:5024\:3092\:30d1\:30c3\:30b1\:30fc\:30b8\:5916\:3067\:8a2d\:5b9a
   ============================================================ *)

SourceVault`$SourceVaultVersion =
  "2026-05-29-stage-9-p1.5-model-registry-autoupdate";

(* $SourceVaultWorkerPromptAutoDetect \:30c7\:30d5\:30a9\:30eb\:30c8\:5024 (P3) *)
If[!ValueQ[SourceVault`$SourceVaultWorkerPromptAutoDetect],
  SourceVault`$SourceVaultWorkerPromptAutoDetect = True];

(* ============================================================
   $ClaudePackageKeywordMap \:3078\:306e\:767b\:9332 (api.md \:81ea\:52d5\:6ce8\:5165)

   maildb \:3068\:540c\:69d8\:3001\:30d7\:30ed\:30f3\:30d7\:30c8\:306b\:3053\:308c\:3089\:306e\:30ad\:30fc\:30ef\:30fc\:30c9\:304c\:542b\:307e\:308c\:308b\:3068
   SourceVault \:306e api.md \:304c ClaudeEval/ClaudeQuery \:306e\:30b3\:30f3\:30c6\:30ad\:30b9\:30c8\:306b
   \:81ea\:52d5\:6ce8\:5165\:3055\:308c\:308b\:3002api.md \:304c\:6700\:65b0\:3067\:3042\:308c\:3070 ClaudeEval \:304c\:6b63\:3057\:3044
   API \:30b7\:30b0\:30cd\:30c1\:30e3 (Format / Keywords / Scope / SourceVaultFormatNotebookList /
   SaveLastPrompt \:7b49) \:3092\:9ad8\:78ba\:7387\:3067\:751f\:6210\:3059\:308b\:3002\:81ea\:52d5\:6ce8\:5165\:304c\:7121\:3044\:3068
   \:6ce8\:5165\:306e\:6709\:7121\:304c\:4e0d\:5b89\:5b9a\:306b\:306a\:308a\:3001\:81ea\:4f5c Grid \:7b49\:3078\:306e\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:304c\:5897\:3048\:308b\:3002
   ============================================================ *)
If[AssociationQ[ClaudeCode`$ClaudePackageKeywordMap],
  ClaudeCode`$ClaudePackageKeywordMap["SourceVault"] =
    {"SourceVault",  (* generic "notebook"/JP removed: over-matched *)
     "\:4e88\:5b9a", "\:30b9\:30b1\:30b8\:30e5\:30fc\:30eb", "schedule",
     "\:30ec\:30d3\:30e5\:30fc", "review", "\:7de0\:5207", "\:671f\:9650", "deadline",
     (* generic removed (over-matched unrelated prompts): keyword / list / prompt *)
     (* ソース一覧 / 横断検索 (SourceVaultSources / SourceVaultSummaries) *)
     "ingest", "Ingest", "取り込み",
     "論文", "arxiv", "arXiv", "横断検索",  (* bare "source"/"検索" removed *)
     "SourceVaultSources", "SourceVaultSummaries", "SourceVaultSourceRow",
     "SourceVaultFindNotebooks", "SourceVaultFormatNotebookList",
     "SourceVaultFindTodos", "Todo",  (* generic "todo"/JP task/item removed *)
     "SourceVaultNewNotebook",  (* generic new/template removed *)
     "SourceVaultUpcomingSchedule", "SourceVaultIndexNotebook",
     "SourceVaultExtractNotebookHeader", "SourceVaultNotebookSummary",
     "SaveLastPrompt", "SourceVaultSearchPromptRoutes",
     "SourceVaultFormatPromptRouteList",
     (* generic "model"/JP removed: over-matched "which model are you" *)
     "ClaudeResolveModel",
     "SourceVaultRefreshModelRegistry", "SourceVaultListModels",
     "SourceVaultSetModel", "SourceVaultClearModelRegistry",
     "SourceVaultSetModelIntent", "SourceVaultAssignClaudeModels",
     "SourceVaultModelIntentMap",
     (* \:30e1\:30fc\:30eb (\:6b63\:5b9a\:306f SourceVault mail \:30b5\:30d6\:30b7\:30b9\:30c6\:30e0\:3002\:65e7 maildb \:30ad\:30fc\:30ef\:30fc\:30c9\:306e\:5f8c\:7d99) *)
     "\:30e1\:30fc\:30eb", "mail", "Mail", "univ", "\:53d7\:4fe1", "inbox", "IMAP",
     "\:8fd4\:4fe1", "reply",
     "SourceVaultMailEnsureLoaded", "SourceVaultMailView", "SourceVaultMailDataset",
     "SourceVaultSearchMailSnapshots", "SourceVaultInferMailDerivedBatch",
     "SourceVaultMailFetchNew", "SourceVaultMailComposeReply"}];

(* \:88dc\:52a9 api_maildb.md \:306e\:6ce8\:5165\:6761\:4ef6 ($ClaudePackageAuxKeywordMap)\:3002
   \:30e1\:30fc\:30eb\:7cfb\:30ad\:30fc\:30ef\:30fc\:30c9\:304c task \:306b\:542b\:307e\:308c\:308b\:3068\:304d\:306e\:307f api_maildb.md \:3092\:6ce8\:5165\:3057\:3001
   Eagle \:7b49\:30e1\:30fc\:30eb\:7121\:95a2\:4fc2\:306e\:30bf\:30b9\:30af\:3067 25KB \:7d1a\:306e api_maildb.md \:304c\:7121\:6761\:4ef6\:6ce8\:5165
   \:3055\:308c\:308b\:306e\:3092\:9632\:3050\:3002\:30c8\:30ea\:30ac\:96c6\:5408\:306f\:4e0a\:306e pkg \:30ec\:30d9\:30eb\:306e\:30e1\:30fc\:30eb\:7cfb\:30ad\:30fc\:30ef\:30fc\:30c9\:3092
   \:5305\:542b\:3059\:308b\:306e\:3067\:3001\:5f93\:6765\:30e1\:30fc\:30eb\:7d4c\:8def\:3067\:6ce8\:5165\:3055\:308c\:3066\:3044\:305f\:30b1\:30fc\:30b9\:306f\:5168\:3066\:7dad\:6301\:3055\:308c\:308b\:3002
   \:672a\:767b\:9332\:306e\:88dc\:52a9 api (core/crypto/promptrouter \:7b49) \:306f\:5f93\:6765\:3069\:304a\:308a\:5e38\:6642\:6ce8\:5165\:3002 *)
If[AssociationQ[ClaudeCode`$ClaudePackageAuxKeywordMap],
  Module[{auxMap},
    auxMap = Lookup[ClaudeCode`$ClaudePackageAuxKeywordMap,
      "SourceVault", <||>];
    If[!AssociationQ[auxMap], auxMap = <||>];
    auxMap["maildb"] = {
      "\:30e1\:30fc\:30eb", "mail", "univ", "\:53d7\:4fe1", "inbox", "IMAP",
      "\:8fd4\:4fe1", "reply", "\:5dee\:51fa\:4eba", "\:5b9b\:5148", "\:4ef6\:540d",
      "SourceVaultMail",   (* \:5168 Mail \:95a2\:6570\:540d\:3092\:90e8\:5206\:4e00\:81f4\:3067\:30ab\:30d0\:30fc *)
      "SourceVaultSearchMailSnapshots", "SourceVaultInferMailDerivedBatch"};
    ClaudeCode`$ClaudePackageAuxKeywordMap["SourceVault"] = auxMap]];


(* ============================================================
   PromptRouter auto-load bootstrap (appended).
   Loading SourceVault.wl now also Get[]s
   SourceVault_promptrouter.wl from the same directory.
   ============================================================ *)

(* ============================================================
   SourceVault_promptrouter_bootstrap.wl

   PromptRouter auto-load bootstrap for SourceVault.wl.

   This is a SNIPPET, not a standalone package. Append its body to
   the END of SourceVault.wl, AFTER the final EndPackage[] of the
   SourceVault` package. It is written with fully-qualified
   SourceVault`Private` names so that it works correctly even when
   placed outside the BeginPackage/EndPackage block.

   Behaviour (spec v9, section 3.2):

     - When SourceVault.wl is loaded, it looks for
       SourceVault_promptrouter.wl in the same directory and Get[]s it.
     - It does NOT call Needs["ClaudeRuntime`"] or
       Needs["ClaudeOrchestrator`"].
     - A missing or failing extension does NOT fail the SourceVault
       load. The outcome is recorded for diagnostics in
       SourceVault`Private`$iSVPromptRouterLoadResult.
     - The extension file is itself idempotent, so a repeated Get[]
       is safe.

   To disable auto-load, set
     SourceVault`Private`$iSVDisablePromptRouterAutoLoad = True
   before loading SourceVault.wl.

   Source is all-ASCII (rule 30 / trap #11).
   ============================================================ *)

(* --- diagnostics holder --- *)
If[!ValueQ[SourceVault`Private`$iSVPromptRouterLoadResult],
  SourceVault`Private`$iSVPromptRouterLoadResult =
    <|"Status" -> "NotAttempted"|>];

(* --- locate and load the extension --- *)
SourceVault`Private`iSVLoadPromptRouterExtension[] :=
  Module[{base, path, getResult},
    base = Quiet @ Check[DirectoryName[$InputFileName], $Failed];
    If[!StringQ[base],
      SourceVault`Private`$iSVPromptRouterLoadResult =
        <|"Status" -> "Failed",
          "Reason" -> "CannotResolveSourceVaultDirectory"|>;
      Return[SourceVault`Private`$iSVPromptRouterLoadResult]];

    (* SourceVault 暗号モジュール (Phase SV-E3) を promptrouter より先にロードする。
       存在する場合のみ。鍵隔離 (NBAccess_crypto) -> crypto primitive -> bootstrap
       -> encrypted store の依存順。SaveLastPrompt の Encrypt -> True がこれらに依存する。 *)
    Scan[
      Function[fn,
        With[{p = FileNameJoin[{base, fn}]},
          If[FileExistsQ[p], Quiet @ Check[Get[p], $Failed]]]],
      (* 集約済み: crypto=crypto+keys+keybundle+encryptedstore+release /
         identity=addressbook+senderauth+identity+messagerelease /
         maildb=maildb+imap+mailui。NBAccess_crypto は別文脈で分離。 *)
      {"NBAccess_crypto.wl", "SourceVault_crypto.wl",
       "SourceVault_identity.wl", "SourceVault_maildb.wl"}];

    path = FileNameJoin[{base, "SourceVault_promptrouter.wl"}];
    If[!FileExistsQ[path],
      SourceVault`Private`$iSVPromptRouterLoadResult =
        <|"Status" -> "NotFound",
          "Reason" -> "ExtensionFileMissing",
          "Path" -> path|>;
      Return[SourceVault`Private`$iSVPromptRouterLoadResult]];

    getResult = Quiet @ Check[Get[path], $Failed];
    If[getResult === $Failed,
      SourceVault`Private`$iSVPromptRouterLoadResult =
        <|"Status" -> "Failed",
          "Reason" -> "GetReturnedFailed",
          "Path" -> path|>;
      Return[SourceVault`Private`$iSVPromptRouterLoadResult]];

    SourceVault`Private`$iSVPromptRouterLoadResult =
      <|"Status" -> "Loaded",
        "Path" -> path|>;
    SourceVault`Private`$iSVPromptRouterLoadResult
  ];

(* --- run auto-load unless explicitly disabled --- *)
If[!TrueQ[SourceVault`Private`$iSVDisablePromptRouterAutoLoad],
  Quiet @ Check[
    SourceVault`Private`iSVLoadPromptRouterExtension[],
    SourceVault`Private`$iSVPromptRouterLoadResult =
      <|"Status" -> "Failed",
        "Reason" -> "BootstrapException"|>
  ]
];


(* ============================================================
   Stage 9 P1.5: \:30e2\:30c7\:30eb\:5909\:6570\:306e\:8d77\:52d5\:6642\:81ea\:52d5\:5272\:308a\:5f53\:3066\:3068\:627f\:8a8d\:767b\:9332 (appended)
   ============================================================ *)

(* SourceVaultSetModelIntent \:3092 $NBApprovalHeads \:306b\:767b\:9332\:3059\:308b\:3002
   ClaudeEval \:3067\:30e2\:30c7\:30eb\:9078\:629e\:3092\:5909\:66f4\:3059\:308b\:30d7\:30ed\:30f3\:30d7\:30c8\:3092\:5b9f\:884c\:3059\:308b\:3068
   Hold -> Approve UI \:304c\:51fa\:308b (\:30e2\:30c7\:30eb\:5909\:66f4\:306f\:691c\:8a3c\:5bfe\:8c61)\:3002 *)
If[TrueQ[Quiet @ Check[
    ListQ[NBAccess`$NBApprovalHeads], False]],
  If[!MemberQ[NBAccess`$NBApprovalHeads, "SourceVaultSetModelIntent"],
    NBAccess`$NBApprovalHeads = Append[
      NBAccess`$NBApprovalHeads, "SourceVaultSetModelIntent"]]];

(* \:30ed\:30fc\:30c9\:6642\:306b\:30e2\:30c7\:30eb\:5909\:6570\:3092\:81ea\:52d5\:5272\:308a\:5f53\:3066 (Q1: \:81ea\:52d5\:5b9f\:884c\:53ef)\:3002
   \:5b9f\:4ee3\:5165\:306f NBAccess`NBSyncClaudeModelVars \:304c\:62c5\:3046 (\:30d7\:30e9\:30a4\:30d0\:30b7\:30fc\:5883\:754c)\:3002
   SourceVault \:306f NBAccess \:3092 Needs \:3057\:3066\:3044\:308b\:306e\:3067\:3001SourceVault \:304c\:5b58\:5728\:3059\:308b
   \:6642\:70b9\:3067 NBAccess \:3082\:5fc5\:305a\:5b58\:5728\:3059\:308b\:3002claudecode.wl \:306e\:30cf\:30fc\:30c9\:30b3\:30fc\:30c9\:3055\:308c\:305f
   \:73fe\:72b6\:8a18\:8ff0\:306f\:6b8b\:308a\:3001\:305d\:306e\:4e0a\:306b NBSyncClaudeModelVars \:304c\:4e0a\:66f8\:304d\:3059\:308b\:3002
   \:5931\:6557\:3057\:3066\:3082\:30ed\:30fc\:30c9\:306f\:7d99\:7d9a\:3059\:308b\:3002 *)
Quiet @ Check[
  SourceVault`Private`$iSVSyncResult =
    If[Length[Names["NBAccess`NBSyncClaudeModelVars"]] > 0,
      NBAccess`NBSyncClaudeModelVars[],
      (* NBAccess \:304c\:7121\:3051\:308c\:3070 (\:901a\:5e38\:8d77\:304d\:306a\:3044\:304c\:5b89\:5168\:5074) SourceVault \:5358\:4f53\:3067\:4ee3\:5165 *)
      SourceVault`SourceVaultAssignClaudeModels[]],
  SourceVault`Private`$iSVSyncResult =
    <|"Status" -> "Failed", "Reason" -> "SyncException"|>
];

(* ============================================================
   Auto-load aux subfiles: Get["SourceVault.wl"] alone also loads
   SourceVault_core / SourceVault_searchindex / SourceVault_servicemanager.
   $CharacterEncoding is pinned to UTF-8 so Japanese literals load correctly
   regardless of the caller's default encoding.
   ============================================================ *)
With[{svDir = Quiet @ Check[DirectoryName[$InputFileName], ""]},
  Block[{$CharacterEncoding = "UTF-8"},
    Scan[
      Function[f, Module[{p = FileNameJoin[{svDir, f}]},
        Quiet @ Check[Get[If[StringLength[svDir] > 0 && FileExistsQ[p], p, f]], $Failed]]],
      {"SourceVault_core.wl", "SourceVault_searchindex.wl",
       "SourceVault_servicemanager.wl", "SourceVault_webingest.wl",
       "SourceVault_mcp.wl"}]]];
