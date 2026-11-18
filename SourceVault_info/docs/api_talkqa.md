# SourceVault_talkqa API Reference

## Overview
Prebuilt live-Q&A layer for presentations: turns spoken audience questions into answers in tens of ms, respecting privacy. Sits on top of [SourceVault_kb](https://github.com/transreal/SourceVault_kb) (Graph-RAG index/search), [SourceVault_webingest](https://github.com/transreal/SourceVault_webingest) (web search fallback), [SourceVault_crosslink](https://github.com/transreal/SourceVault_crosslink) (cross-document discovery), [SourceVault_realtime](https://github.com/transreal/SourceVault_realtime) (voice-bridge ask tool), and [SlideWorkflow](https://github.com/transreal/SlideWorkflow) (deck + talk script `<deck>_talk.md`). It does not replace any of these; it adds three things:
1. `SourceVaultTalkQABuild` precomputes, per slide, "expected question -> candidate answer -> `sv://` citation" using an LLM and the KB (build time only, never at runtime). `SourceVaultTalkQAImport` does the same but from author-written Q&A cells instead of LLM guesses.
2. `SourceVaultTalkQAAsk` answers a live question: first checks the prebuilt pack, then falls back to the KB, then offers to search the web.
3. `SourceVaultTalkQANeighbors` returns a k-hop neighborhood seeded from the currently open slide, for follow-up detail.

Privacy is baked into every candidate answer at build time (`PrivacyLevel` + `Route`), not re-evaluated at runtime (faster, and auditable later):
- `PrivacyLevel <= $SourceVaultTalkQAPublicMax` -> `Route "Public"` (cloud voice may read it aloud)
- otherwise, by mode: `$SourceVaultTalkQAMode = "Private"` -> `Route "Local"` (local voice/tsukuyomi reads it); `"Presentation"` (default) -> `Route "Deny"` (refuses to answer)
In presentation mode, a question that needs non-public material is not answered — reported via `Ask`'s `Status -> "Blocked"` so the caller (voice bridge) can react.

Load/registration side effects: on load, registers a crosslink provider `"talkqa"` (Kinds `{"TalkQA"}`, searches Public entries' question+answer text, returns up to 10 items `<|"Kind"->"TalkQA", "Id", "URI", "Title", "Snippet", "Score"->0.6, "Provider"->"talkqa"|>`) if `SourceVaultRegisterCrossLinkProvider` exists, and sets `$SourceVaultRealtimeAskHandler = SourceVaultTalkQAHandler` if that symbol exists. Package context is `SourceVault``; all public symbols are `SourceVault`...`.

## Configuration Variables

### $SourceVaultTalkQAMode
型: String, 初期値: "Presentation"
QA runtime mode. `"Presentation"` refuses to answer questions that need non-public material. `"Private"` answers them with `Route -> "Local"` (read by local voice/tsukuyomi).

### $SourceVaultTalkQAPublicMax
型: Real, 初期値: 0.35
Upper bound on `PrivacyLevel` that may be read aloud via cloud voice. Material above this is unusable in `"Presentation"` mode.

### $SourceVaultTalkQADefaultPack
型: String, 初期値: ""
QA pack id used when `"PackId"` is omitted/Automatic. Set automatically by `SourceVaultTalkQALoad`/`SourceVaultTalkQABuild`/`SourceVaultTalkQAImport`/`SourceVaultTalkQASelectForDeck`.

### $SourceVaultTalkQAMinScore
型: Real, 初期値: 2.0
Minimum BM25 top score for a KB answer to be accepted. Below this the material is treated as absent and a web search is offered. Setting it too low causes plausible-looking answers to unrelated questions.

### $SourceVaultTalkQAPackSimilarity
型: Real, 初期値: 0.3
Minimum content-word overlap (F2-style coverage) between a live question and a pack question for the pack hit to be accepted. Prevents matching a different question that happens to share a proper noun; below this threshold the KB is re-queried instead. A pack hit is also rejected when the asked aspect (where/when/how many/why/how/who/what) is incompatible with the pack question's aspect.

### $SourceVaultTalkQASlide
型: Integer, 初期値: 0
Currently open slide number, set via `SourceVaultTalkQASetSlide`. Used for neighbor search and to weight pack-question matching.

## Pack Management

### SourceVaultTalkQABuild[deck, opts]
Builds a QA pack from a slide deck (.nb path). Reads the talk script `<deck>_talk.md` if present, ingests the deck into the KB (unless disabled), generates expected questions per slide via LLM (or a fallback heuristic), and precomputes KB-derived candidate answers with citations.
→ Association `<|"Status" -> "OK", "PackId", "KBId", "Slides", "Questions", "Public", "NonPublic", "ElapsedSeconds"|>` or a `Failure["DeckNotFound"|"IngestFailed"|"NoSlides"|"PackSaveFailed", ...]`.
Options: PackId -> Automatic (defaults to deck's file base name), KBId -> Automatic (defaults to `$SourceVaultKBDefaultId`), PrivacyLevel -> 0.3 (default PL for ingest), QuestionsPerSlide -> 3, Ingest -> True (ingest into KB before building; KB skips unchanged sources), Rebuild -> Automatic (rebuild KB index if ingest changed anything; True/False force), QuestionFn -> Automatic (Automatic picks Cloud/Local per deck's cloud-publishable flag; also accepts "Cloud", "Local", "None", or a custom `fn[slideText, talkText, k]`), QuestionModel -> Automatic (Cloud/Local override consulted only when QuestionFn is left Automatic), Slides -> All (or `{n, ...}` to restrict), Verbose -> True (progress `Print`s), AnswerLimit -> 3 (KB results considered per question).
例: `SourceVaultTalkQABuild["talk.nb", "QuestionsPerSlide" -> 5, "QuestionFn" -> "Local"]`

### SourceVaultTalkQAImport[deck, slides, opts]
Builds/updates a QA pack from author-written Q&A cells (e.g. SlideWorkflow's SlideQA cells) instead of LLM-generated questions — the author's wording is authoritative and is not paraphrased by an LLM. `deck`: .nb path (String). `slides`: List of `<|"Slide"->n, "Title"->..., "Text"->slide body, "Talk"->talk script, "Entries"->{<|"Question"->q, "Answer"->a, "Citations"->{...}, "PrivacyLevel"->pl|>...}|>` (non-Association items ignored; per-slide `"PrivacyLevel"` optional). Citations may be Associations or strings (`sv://` URI strings become ObjectURI; other strings become Label). Entries with an empty `"Question"` are dropped; entries with an empty `"Answer"` are dropped unless `Enrich -> True` fills them from the KB (scoped to the deck's SourceId first; then PL is raised to the max of the KB answer's PL), so `SourceVaultTalkQAAsk` falls through to the KB instead of matching an empty answer. Entry PL defaults to the slide PL. If a pack already exists for `deck`, its PackId/KBId/SourceId are reused so the same deck doesn't accumulate duplicate packs. Also ingests the deck into the KB (talk script passed as slide notes; unless disabled) so questions not covered by the authored cells still have a fallback; KB ingest failures do not abort pack creation. Sets `$SourceVaultTalkQADefaultPack`.
→ Association `<|"Status" -> "OK", "PackId", "KBId", "Origin" -> "Cells", "Slides", "Questions", "Dropped", "Public", "NonPublic", "ElapsedSeconds"|>` or `Failure["NoSlides"|"NoAnswers"|"PackSaveFailed", ...]`.
Options: PackId -> Automatic (reuses prior pack for this deck if any, else SourceId), KBId -> Automatic (reuses prior pack's KBId, else `$SourceVaultKBDefaultId`, else "cn"), SourceId -> Automatic (reuses prior pack's SourceId, else deck's file base name), PrivacyLevel -> Automatic (resolves to the deck's default PL, 0.3, for entries lacking their own; the raw option value is passed to KB ingest), Ingest -> True (ingest deck into KB as a fallback for uncovered questions; requires deck file to exist), Rebuild -> Automatic (rebuild KB if ingest status isn't "Unchanged"; True/False force), Enrich -> True (fills empty-answer entries from the KB), Verbose -> False.

### SourceVaultTalkQAPacks[] → {String...}
Sorted list of built QA pack ids found across all known storage roots.

### SourceVaultTalkQALoad[packId] → Association
Loads a QA pack into memory and sets it as `$SourceVaultTalkQADefaultPack`. Returns `<|"Status" -> "OK", "PackId", "Slides", "Questions"|>` or `Failure["PackNotFound"|"PackUnreadable", ...]`.

### SourceVaultTalkQAWhere[] → Association
Diagnostic: resolves where packs are searched for/stored. Returns `<|"Version", "Root", "SearchedIn", "Files", "Packs", "DefaultPack", "Loaded", "LocalStateRoot", "OSLocalState", "KBRoot", "PackageFile"|>`. Use this to triage "no pack found" issues. If it is undefined after load, the kernel holds an old version.

### SourceVaultTalkQASelectForDeck[deck] → Association
`deck`: a .nb path (String) or a `NotebookObject` (resolved via its saved file name). Selects and loads the QA pack matching that specific deck (by SourceId, deck path base name, or same-file check) rather than defaulting to the first pack in the list — needed because the deck in use changes between talks. Returns `Failure["NoPackForDeck"|"NoDeckPath", ...]` if none matches.

### SourceVaultTalkQAUnload[packId] → Association
Releases an in-memory pack. Returns `<|"Status" -> "OK", "PackId" -> packId|>`.

### SourceVaultTalkQAStatus[packId:Automatic] → Association
Pack summary: `<|"PackId", "KBId", "Deck", "BuiltAtUTC", "Slides", "Questions", "Public", "NonPublic", "Links", "Mode", "PublicMax"|>`. Returns the pack-resolution Failure if no pack is available.

## Runtime Query

### SourceVaultTalkQAAsk[question, opts]
Answers a live question in three stages: (1) prebuilt pack lookup by content-word overlap + slide proximity (+ aspect compatibility and `$SourceVaultTalkQAPackSimilarity` check), (2) KB Graph-RAG answer (scoped to the pack's deck SourceId first, then any source; weak/unrelated hits rejected via `$SourceVaultTalkQAMinScore` and a keyword-overlap check), (3) if still insufficient: answers via web directly if `AllowWeb -> True` (delegates to `SourceVaultTalkQAWebAnswer` with PackId/Slide), else reports `"Unavailable"` if the web search service is down (health cached ~60 s), else offers `"NeedWeb"`.
Pack/KB results are chosen by mode: `"Private"` -> full answer (Route "Local" or "Public" by PL); otherwise public-only answer, and if none → `Status "Blocked"`, `Route "Deny"`, `AnswerText ""`.
→ Association `<|"Status" ("OK"|"Blocked"|"NotFound"|"NeedWeb"|"Unavailable"), "Route" ("Public"|"Local"|"Deny"), "AnswerText", "SpeakText", "Citations", "Slide", "Source" ("Pack"|"KB"|"Web"|"None"), "PrivacyLevel", "ElapsedMs"|>` (plus `"ContextText"`/`"Question"` (matched pack/KB question) when Status is `"OK"`, `"WebAvailable"` for NeedWeb/Unavailable).
Options: PackId -> Automatic, Slide -> Automatic (defaults to the live slide, tracked via SlideWorkflow if loaded, else `$SourceVaultTalkQASlide`), Mode -> Automatic (defaults to `$SourceVaultTalkQAMode`), AllowWeb -> False (if True, insufficient answers fall straight to `SourceVaultTalkQAWebAnswer`), MinScore -> 0.5 (pack-hit acceptance threshold, combined key-overlap score; at least 2 matched keys also required), KBId -> Automatic (defaults to the loaded pack's KBId, else `$SourceVaultKBDefaultId`).
例: `SourceVaultTalkQAAsk["フレドキンゲートとは何ですか", "AllowWeb" -> True]`

### SourceVaultTalkQANeighbors[slide:Automatic, opts] → {Association...}
Returns a k-hop neighborhood in the KB graph, seeded from `slide`'s node (Automatic = `$SourceVaultTalkQASlide`), for supplementary explanation. Each item: `<|"Slide", "Title", "SourceTitle", "Score", "PrivacyLevel", "Route", "Text" (redacted to "" when Route is "Deny"), "URI"|>`. Returns a `Failure["SlideNotInPack", ...]` if the slide isn't recorded in the pack.
Options: PackId -> Automatic, Hops -> 2, Limit -> 5, Mode -> Automatic (governs per-item Route/redaction).

### SourceVaultTalkQAWebAnswer[question, opts]
Runs a web search (after user consent to go beyond local material), composes a 2-3 sentence Japanese answer from the results (via cloud LLM `ClaudeCode`ClaudeQuerySync`, then local LLM, falling back to a plain excerpt), and — only when `Ingest -> True` — ingests the results into the KB. Default does NOT ingest: web snippets are UNTRUSTED external text and would become grounds for later answers (A-5, 02 v1.2 P1-15), so ingestion is limited to explicit owner opt-in. Automatically appends slide-derived proper-noun context terms (up to 2, from the slide's `Terms`/title, excluding those already in the question) to the query to disambiguate acronyms; falls back to the bare question if the augmented query returns fewer than 2 results. Returns `"NotFound"` (with a message) if the web search layer (`SourceVaultWebSearch`) isn't loaded or no results/bodies.
→ Association `<|"Status" ("OK"|"NotFound"|"Unavailable"), "Route" -> "Public", "AnswerText", "SpeakText", "Query", "Citations" ({<|"Title", "URI"|>...}), "Slide", "Source" -> "Web", "PrivacyLevel" -> 0., "SourceId" ("web-" + 10-char hash of question), "ElapsedMs"|>` (plus `"Reason"` — the failed status tag, e.g. `"SearXNGTimeout"` — when Status is `"Unavailable"`; NotFound/Unavailable results omit Query/SourceId).
Options: PackId -> Automatic, KBId -> Automatic, Limit -> 5 (web results considered), Ingest -> False (ingest results into KB as Kind "Web", PL 0.0, tags {"web","talkqa"}; requires `SourceVaultKBIngestTexts`), Rebuild -> True (rebuild KB index after ingest; only effective when Ingest is True), Slide -> Automatic (context source for query augmentation), Verbose -> False.

## Reference / Inspection

### SourceVaultTalkQAQuestions[slide:Automatic, packId:Automatic] → {Association...}
Precomputed question/answer entries for `slide` in the given (or default) pack. Entry keys include `"Slide", "Question", "Keys", "QNorm", "AnswerText", "PublicAnswer", "PublicCitations", "PublicPrivacyLevel", "FullAnswer", "FullCitations", "ContextText", "PrivacyLevel", "Route", "RoutePrivate", "Citations", "CitationURIs", "Count", "Origin"`.

### SourceVaultTalkQASlideInfo[slide:Automatic, packId:Automatic] → Association
Per-slide record: `<|"Slide", "Title", "Terms", "SlideNodeId", "ObjectURI", "PrivacyLevel", "Links", "QuestionCount"|>` (empty Association if the slide is absent).

### SourceVaultTalkQALinks[slide:Automatic, packId:Automatic] → {String...}
`sv://` URIs linked to `slide` (from its own object plus all its answers' citations).

### SourceVaultTalkQAView[packId:Automatic] → Dataset
Tabular view of pack entries: `<|"Slide", "Question", "Answer" (truncated to 80 chars), "PL", "Route", "Cites"|>` per row.

### SourceVaultTalkQAExport[packId:Automatic] → {Association...}
Round-trips a pack back into the `SourceVaultTalkQAImport` entry shape, so an LLM-built pack can be written back into a deck's Q&A cells for the presenter to edit and re-import. Each item: `<|"Slide", "Question", "Answer" (full, not truncated), "Citations" (list of `sv://` URIs, falling back to label text), "PrivacyLevel"|>`.

### SourceVaultTalkQASetSlide[n] → Integer
Records the currently open slide number into `$SourceVaultTalkQASlide` (called from SlideWorkflow on slide change). Non-integer argument just returns the current value.

## Voice Bridge

### SourceVaultTalkQAHandler[req] → Association
Entry point for spoken queries from the realtime voice bridge. `req`: `<|"query"|"Query", "allowWeb"|"AllowWeb" (Boolean), "slide"|"Slide" (Integer, optional; if >0 calls `SourceVaultTalkQASetSlide`)|>`. Delegates to `SourceVaultTalkQAAsk` and returns a lowercase-keyed response: `<|"status" (lowercased Ask Status), "answer" (SpeakText), "route", "source", "matchedQuestion" (the pack question that was hit, if any — lets the caller judge whether the answer actually fits the live question), "slide", "needWeb", "serviceDown", "citations" (up to 3 labels), "elapsedMs"|>`. Empty query or failed answer → `<|"status" -> "error", "message" -> ...|>`. Auto-registered as `SourceVault`$SourceVaultRealtimeAskHandler` on load if [SourceVault_realtime](https://github.com/transreal/SourceVault_realtime) is present.