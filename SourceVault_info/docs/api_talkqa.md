# SourceVault_talkqa API Reference

## Overview
Prebuilt live-Q&A layer for presentations: turns spoken audience questions into answers in tens of ms, respecting privacy. Sits on top of [SourceVault_kb](https://github.com/transreal/SourceVault_kb) (Graph-RAG index/search), [SourceVault_webingest](https://github.com/transreal/SourceVault_webingest) (web search fallback), [SourceVault_crosslink](https://github.com/transreal/SourceVault_crosslink) (cross-document discovery), [SourceVault_realtime](https://github.com/transreal/SourceVault_realtime) (voice-bridge ask tool), and [SlideWorkflow](https://github.com/transreal/SlideWorkflow) (deck + talk script `<deck>_talk.md`). It does not replace any of these; it adds three things:
1. `SourceVaultTalkQABuild` precomputes, per slide, "expected question -> candidate answer -> `sv://` citation" using an LLM and the KB (build time only, never at runtime).
2. `SourceVaultTalkQAAsk` answers a live question: first checks the prebuilt pack, then falls back to the KB, then offers to search the web.
3. `SourceVaultTalkQANeighbors` returns a k-hop neighborhood seeded from the currently open slide, for follow-up detail.

Privacy is baked into every candidate answer at build time (`PrivacyLevel` + `Route`), not re-evaluated at runtime (faster, and auditable later):
- `PrivacyLevel <= $SourceVaultTalkQAPublicMax` -> `Route "Public"` (cloud voice may read it aloud)
- otherwise, by mode: `$SourceVaultTalkQAMode = "Private"` -> `Route "Local"` (local voice/tsukuyomi reads it); `"Presentation"` (default) -> `Route "Deny"` (refuses to answer)
In presentation mode, a question that needs non-public material is not answered — reported via `Ask`'s `Status -> "Blocked"` so the caller (voice bridge) can react.

## Configuration Variables

### $SourceVaultTalkQAMode
型: String, 初期値: "Presentation"
QA runtime mode. `"Presentation"` refuses to answer questions that need non-public material. `"Private"` answers them with `Route -> "Local"` (read by local voice/tsukuyomi).

### $SourceVaultTalkQAPublicMax
型: Real, 初期値: 0.35
Upper bound on `PrivacyLevel` that may be read aloud via cloud voice. Material above this is unusable in `"Presentation"` mode.

### $SourceVaultTalkQADefaultPack
型: String, 初期値: ""
QA pack id used when `"PackId"` is omitted/Automatic. Set automatically by `SourceVaultTalkQALoad`/`SourceVaultTalkQABuild`/`SourceVaultTalkQASelectForDeck`.

### $SourceVaultTalkQAMinScore
型: Real, 初期値: 2.0
Minimum BM25 top score for a KB answer to be accepted. Below this the material is treated as absent and a web search is offered. Setting it too low causes plausible-looking answers to unrelated questions.

### $SourceVaultTalkQAPackSimilarity
型: Real, 初期値: 0.3
Minimum content-word overlap (F2-style coverage) between a live question and a pack question for the pack hit to be accepted. Prevents matching a different question that happens to share a proper noun; below this threshold the KB is re-queried instead.

### $SourceVaultTalkQASlide
型: Integer, 初期値: 0
Currently open slide number, set via `SourceVaultTalkQASetSlide`. Used for neighbor search and to weight pack-question matching.

## Pack Management

### SourceVaultTalkQABuild[deck, opts]
Builds a QA pack from a slide deck (.nb path). Reads the talk script `<deck>_talk.md` if present, ingests the deck into the KB (unless disabled), generates expected questions per slide via LLM (or a fallback heuristic), and precomputes KB-derived candidate answers with citations.
→ Association `<|"Status" -> "OK", "PackId", "KBId", "Slides", "Questions", "Public", "NonPublic", "ElapsedSeconds"|>` or a `Failure["DeckNotFound"|"IngestFailed"|"NoSlides"|"PackSaveFailed", ...]`.
Options: PackId -> Automatic (defaults to deck's file base name), KBId -> Automatic (defaults to `$SourceVaultKBDefaultId`), PrivacyLevel -> 0.3 (default PL for ingest), QuestionsPerSlide -> 3, Ingest -> True (ingest into KB before building; KB skips unchanged sources), Rebuild -> Automatic (rebuild KB index if ingest changed anything; True/False force), QuestionFn -> Automatic (Automatic picks Cloud/Local per deck's cloud-publishable flag; also accepts "Cloud", "Local", "None", or a custom `fn[slideText, talkText, k]`), QuestionModel -> Automatic (Cloud/Local override consulted only when QuestionFn is left Automatic), Slides -> All (or `{n, ...}` to restrict), Verbose -> True (progress `Print`s), AnswerLimit -> 3 (KB results considered per question).
例: `SourceVaultTalkQABuild["talk.nb", "QuestionsPerSlide" -> 5, "QuestionFn" -> "Local"]`

### SourceVaultTalkQAPacks[] → {String...}
Sorted list of built QA pack ids found across all known storage roots.

### SourceVaultTalkQALoad[packId] → Association
Loads a QA pack into memory and sets it as `$SourceVaultTalkQADefaultPack`. Returns `<|"Status" -> "OK", "PackId", "Slides", "Questions"|>` or `Failure["PackNotFound"|"PackUnreadable", ...]`.

### SourceVaultTalkQAWhere[] → Association
Diagnostic: resolves where packs are searched for/stored. Returns `<|"Version", "Root", "SearchedIn", "Files", "Packs", "DefaultPack", "Loaded", "LocalStateRoot", "OSLocalState", "KBRoot", "PackageFile"|>`. Use this to triage "no pack found" issues.

### SourceVaultTalkQASelectForDeck[deck] → Association
`deck`: a .nb path (String) or a `NotebookObject` (resolved via its saved file name). Selects and loads the QA pack matching that specific deck (by SourceId, deck path base name, or same-file check) rather than defaulting to the first pack in the list — needed because the deck in use changes between talks. Returns `Failure["NoPackForDeck"|"NoDeckPath", ...]` if none matches.

### SourceVaultTalkQAUnload[packId] → Association
Releases an in-memory pack. Returns `<|"Status" -> "OK", "PackId" -> packId|>`.

### SourceVaultTalkQAStatus[packId:Automatic] → Association
Pack summary: `<|"PackId", "KBId", "Deck", "BuiltAtUTC", "Slides", "Questions", "Public", "NonPublic", "Links", "Mode", "PublicMax"|>`.

## Runtime Query

### SourceVaultTalkQAAsk[question, opts]
Answers a live question in three stages: (1) prebuilt pack lookup by content-word overlap + slide proximity, (2) KB Graph-RAG answer (scoped to the pack's deck first, then any source), (3) if still insufficient, offers `"NeedWeb"` (or answers via web directly if `AllowWeb -> True`, or reports `"Unavailable"` if the web search service is down).
→ Association `<|"Status" ("OK"|"Blocked"|"NotFound"|"NeedWeb"|"Unavailable"), "Route" ("Public"|"Local"|"Deny"), "AnswerText", "SpeakText", "Citations", "Slide", "Source" ("Pack"|"KB"|"Web"|"None"), "PrivacyLevel", "ElapsedMs"|>` (plus `"ContextText"`/`"Question"` when Status is `"OK"` from a pack hit, `"WebAvailable"` when web-related).
Options: PackId -> Automatic, Slide -> Automatic (defaults to the live slide, tracked via SlideWorkflow if loaded, else `$SourceVaultTalkQASlide`), Mode -> Automatic (defaults to `$SourceVaultTalkQAMode`), AllowWeb -> False (if True, insufficient answers fall straight to `SourceVaultTalkQAWebAnswer`), MinScore -> 0.5 (pack-hit acceptance threshold, combined key-overlap score), KBId -> Automatic (defaults to the loaded pack's KBId, else `$SourceVaultKBDefaultId`).
例: `SourceVaultTalkQAAsk["フレドキンゲートとは何ですか", "AllowWeb" -> True]`

### SourceVaultTalkQANeighbors[slide, opts] → {Association...}
Returns a k-hop neighborhood in the KB graph, seeded from `slide`'s node, for supplementary explanation. Each item: `<|"Slide", "Title", "SourceTitle", "Score", "PrivacyLevel", "Route", "Text" (redacted to "" when Route is "Deny"), "URI"|>`. Returns a `Failure["SlideNotInPack", ...]` if the slide isn't recorded in the pack.
Options: PackId -> Automatic, Hops -> 2, Limit -> 5, Mode -> Automatic (governs per-item Route/redaction).

### SourceVaultTalkQAWebAnswer[question, opts]
Runs a web search (after user consent to go beyond local material), composes a 2-3 sentence Japanese answer from the results (via cloud LLM, falling back to a plain excerpt), and ingests the results into the KB so future asks of related questions answer instantly. Automatically appends slide-derived proper-noun context terms to the query to disambiguate acronyms; falls back to the bare question if the augmented query returns too few results.
→ Association `<|"Status" ("OK"|"NotFound"|"Unavailable"), "Route" -> "Public", "AnswerText", "SpeakText", "Query", "Citations", "Slide", "Source" -> "Web", "PrivacyLevel" -> 0., "SourceId", "ElapsedMs"|>`.
Options: PackId -> Automatic, KBId -> Automatic, Limit -> 5 (web results considered), Ingest -> True (ingest results into KB), Rebuild -> True (rebuild KB index after ingest), Slide -> Automatic (context source for query augmentation), Verbose -> False.

## Reference / Inspection

### SourceVaultTalkQAQuestions[slide:Automatic, packId:Automatic] → {Association...}
Precomputed question/answer entries for `slide` in the given (or default) pack.

### SourceVaultTalkQASlideInfo[slide:Automatic, packId:Automatic] → Association
Per-slide record: `<|"Slide", "Title", "Terms", "SlideNodeId", "ObjectURI", "PrivacyLevel", "Links", "QuestionCount"|>`.

### SourceVaultTalkQALinks[slide:Automatic, packId:Automatic] → {String...}
`sv://` URIs linked to `slide` (from its own object plus all its answers' citations).

### SourceVaultTalkQAView[packId:Automatic] → Dataset
Tabular view of pack entries: `<|"Slide", "Question", "Answer" (truncated to 80 chars), "PL", "Route", "Cites"|>` per row.

### SourceVaultTalkQASetSlide[n] → Integer
Records the currently open slide number into `$SourceVaultTalkQASlide` (called from SlideWorkflow on slide change).

## Voice Bridge

### SourceVaultTalkQAHandler[req] → Association
Entry point for spoken queries from the realtime voice bridge. `req`: `<|"query"|"Query", "allowWeb"|"AllowWeb" (Boolean), "slide"|"Slide" (Integer, optional)|>`. Delegates to `SourceVaultTalkQAAsk` and returns a lowercase-keyed response: `<|"status", "answer", "route", "source", "slide", "needWeb", "serviceDown", "citations" (up to 3 labels), "elapsedMs"|>`. Auto-registered as `SourceVault`$SourceVaultRealtimeAskHandler` on load if [SourceVault_realtime](https://github.com/transreal/SourceVault_realtime) is present.