# SourceVault_kb API Reference

## Overview
Low-latency Graph-RAG knowledge base for VRCRealtime voice answers. Existing MCP search (web/mail/eagle/PDFIndex embedding) can take tens of seconds — too slow for realtime voice. This layer pre-builds everything so that query time is BM25 + in-memory graph propagation only (tens of ms).
Indexing unit: "slide" and "figure". Text cells are bundled per slide; figure cells get vision-read captions merged into the same slide as surrounding text.
Not plain chunk RAG but Graph-RAG: builds a Deck -- Slide -- Chunk -- Topic graph, propagates 2 hops from BM25/topic seeds to pull in context (adjacent slides, other sessions on the same topic), then aggregates back to slide level.
Reuses: BM25 (SourceVaultBuildLexicalStats / SourceVaultLexicalRank), EntityDictionary for term variation, SourceVaultEvaluateReleasePolicy for release gating, PDFIndex chunks (ingested once, not queried live), optional dense embeddings (SourceVaultEmbedTexts / RegisterHTTPEmbeddingProvider).
Three idempotent, independently re-runnable stages: 1) ingest (notebook/PDF → source document, no LLM), 2) caption (figure → vision description, hash-cached, budgeted), 3) build (source + caption → chunk + graph + BM25 index).
Load order: [SourceVault](https://github.com/transreal/SourceVault) → [SourceVault_core](https://github.com/transreal/SourceVault_core) → [SourceVault_lexical](https://github.com/transreal/SourceVault_lexical) → [SourceVault_searchindex](https://github.com/transreal/SourceVault_searchindex) → SourceVault_kb. Optional deps: [SlideWorkflow](https://github.com/transreal/SlideWorkflow) (deck splitting), [PDFIndex](https://github.com/transreal/PDFIndex) (PDF chunk ingest), claudecode (vision captioning).

## Configuration / Globals
### $SourceVaultKBVersion
型: String
Version string of SourceVault_kb.wl.
### $SourceVaultKBDefaultId
型: String, 初期値: "cn"
Default KB name used when kbId is omitted (MCP / local voice bridge default to this KB).
### $SourceVaultKBReleaseContext
型: String, 初期値: "kb-public"
Default release context name for the KB.
### SourceVaultKBRegisterDefaults[] → Association
Registers the KB release contexts ("kb-public" = cloud-allowed, MaxPrivacyLevel 0.35; "kb-local" = local TTS only, MaxPrivacyLevel 0.85). Runs automatically on load; idempotent. Returns <|"Status"->"OK"|"Skipped", ...|>.

## KB Management
### SourceVaultKBRoot[kbId] → String
Storage directory for the KB (under LocalState, outside Dropbox sync). kbId defaults to $SourceVaultKBDefaultId.
### SourceVaultKBList[] → List of String
Lists created KB ids.
### SourceVaultKBStatus[kbId] → Association
KB state: source/slide/figure counts (total and uncaptioned), chunk/node/edge counts, build timestamp, whether loaded in memory. Keys include KBId, Root, Sources, Slides, Passages, Figures, CaptionedFigures, PendingFigures, ChunkCount, NodeCount, EdgeCount, TopicCount, ReleaseContext, BuiltAtUTC, Loaded, SourceList.
### SourceVaultKBSources[kbId] → List of Association
Overview of ingested source documents (no body text). Fields: SourceId, Kind, Title, Slides, Passages, Figures, PrivacyLevel, IngestedAtUTC.
### SourceVaultKBLoad[kbId] → Association
Loads the built KB index into memory (subsequent searches run entirely in memory). Fails with "KBNotBuilt" if index.wxf is missing.
### SourceVaultKBUnload[kbId] → Association
Releases the in-memory KB.
### SourceVaultKBLoadedQ[kbId] → True | False
Whether the KB is currently loaded in memory.

## Ingest
### SourceVaultKBIngestSlideDeck[kbId, nbPath, opts]
Parses one slide notebook and stores per-slide text plus figures (rendered PNG + hash) as a source document. No LLM call (figure captions are filled later by SourceVaultKBCaptionFigures). Skips re-parsing if file size/mtime digest is unchanged, unless "Force"->True.
→ Association (<|"Status"->"OK"|"Unchanged", "KBId", "SourceId", "Slides", "ElapsedSeconds"|> or Failure)
Options: "SourceId" -> Automatic (default: file base name), "Title" -> Automatic, "PrivacyLevel" -> 0.3, "Tags" -> {}, "RenderFigures" -> Automatic (True if front end available), "MaxFiguresPerSlide" -> 4, "FigureImageWidth" -> 1024, "IncludeCode" -> False, "Force" -> False, "MaxSlideCharacters" -> 1500, "Verbose" -> True
### SourceVaultKBIngestSlideDecks[kbId, dirOrFiles, opts]
Batch-ingests multiple slide notebooks; a directory is searched recursively for .nb files.
→ Association (batch summary)
Options: all SourceVaultKBIngestSlideDeck options, plus "FileNamePattern" -> "*.nb", "Exclude" -> {substring...}, "MaxFiles" -> Automatic
### SourceVaultKBIngestPDFCollection[kbId, collection, opts]
Imports chunks from an existing PDFIndex collection into the KB (e.g. student handbook reuse). PDFIndex is read once at ingest time; search never touches it, keeping queries fast.
→ Association
Options: "Group" -> None (registered search group name; inherits PrivacyLevel/ReleaseContext), "Docs" -> All (list of docId to include), "PrivacyLevel" -> Automatic (from group or 0.3), "Tags" -> {}, "MaxChunks" -> Automatic, "SourceId" -> Automatic (default "pdf-<collection>[-<group>]"), "Title" -> Automatic, "Verbose" -> True

## Figure Captioning
### SourceVaultKBPendingFigures[kbId] → List of Association
Figures without a generated caption yet. Fields: FigureId, Hash, SourceId, SlideIndex, SlideTitle, HasImage.
### SourceVaultKBCaptionFigures[kbId, opts]
Reads uncaptioned figures via vision, combining surrounding slide text/title as context, and writes captions + keywords to the hash-keyed cache (re-runnable, resumes where it left off).
→ Association (run summary)
Options: "MaxFigures" -> 20, "CaptionFn" -> Automatic (Automatic uses ClaudeCode`ClaudeQueryBg; else fn[{prompt, Image}]), "SourceId" -> All, "TimeConstraint" -> 120 (seconds per figure), "Verbose" -> True
### SourceVaultKBSetCaption[kbId, figureId, caption, opts] → Association
Manually sets a figure's caption (no LLM call) — for correcting misreads or replacing sensitive figures.
Options: "Keywords" -> {}

## Build
### SourceVaultKBBuild[kbId, opts]
Builds chunks / graph / BM25 index from ingested sources and figure captions, and saves it (seconds). Re-run after adding sources. Applies build-time release gate: only chunks that Permit under the release context are indexed (fail-closed); auto-registers default release contexts if unregistered.
→ Association (<|"Status", "ChunkCount", "ExcludedChunks", ...|> or Failure: "NoSources", "NoChunks", "AllChunksDenied", "UnregisteredReleaseContext")
Options: "ReleaseContext" -> Automatic (default $SourceVaultKBReleaseContext), "Dense" -> False (no embeddings), "MaxChunkCharacters" -> 1500, "IncludePendingFigures" -> False, "MaxTopics" -> 3000, "EntityStream" -> False (True only when using the synonym dictionary), "Load" -> True (load into memory right after build), "Verbose" -> True

## Search & Answer
### SourceVaultKBSearch[kbId, query, opts]
Core Graph-RAG search: BM25 + topic seeds propagate through the graph for Hops iterations, chunk scores aggregate to slide level, request-time release gate filters results.
→ List of Association (slide-level results) or Failure
Options: "Limit" -> 5, "RetrievalDepth" -> 40, "Hops" -> 3 (chunk→slide→adjacent slide→chunk needs 3 hops), "Damping" -> 0.45, "UseGraph" -> True, "UseDense" -> False, "ReleaseContext" -> Automatic, "DeadlineMs" -> 400, "SourceId" -> All, "MaxCharactersPerResult" -> 700, "FrontierCap" -> 240, "Explain" -> False
### SourceVaultKBAnswer[kbId, question, opts]
Low-latency voice-answer builder. No LLM call; assembles a cited ContextText and a short AnswerText from search results. If the question names a single ordinal session (e.g. "第9回"/"#9"), resolves the source deterministically by numeric match before searching (BM25 alone confuses "第9回" with "第19回").
→ Association <|"Status","Route","ContextText","AnswerText","Citations","Results","Count","MaxPrivacyLevel","ElapsedMs","KBId"|>
Options: all SourceVaultKBSearch options, plus "MaxContextCharacters" -> 1200, "MaxAnswerCharacters" -> 160, "TPO" -> None (registered TPOProfile name for optional topic gating)
例: SourceVaultKBAnswer["cn", "第9回の計算と自然では何を扱った?"]

## Graph / View
### SourceVaultKBGraph[kbId, opts]
Returns the KB graph as a Graph object for inspection/viewing.
→ Graph
Options: "Center" -> None (node id to center BFS on), "Radius" -> 2, "MaxVertices" -> 200, "Kinds" -> All (restrict to node kinds: "Chunk","Slide","Deck","Topic")
### SourceVaultKBSearchView[kbId, query, opts]
Displays SourceVaultKBSearch results as a Dataset (view layer).
→ Dataset | Style["該当なし", Gray]
Options: same as SourceVaultKBSearch
### SourceVaultKBExplain[kbId, query, opts] → Association
Debug function returning the breakdown of seeds, graph propagation, and scoring for a query.