### Overview
SourceVault_slidedeck (`SourceVault\`` context, private impl in `SlideDeckPrivate\``) is a registry mapping a talk title (e.g. "計算と自然集会31の発表") to its Sliden mp4 URL and compiled presentation scenario (narration script). It does NOT create slide/script content — that's [SlideWorkflow](https://github.com/transreal/SlideWorkflow)'s job. This layer only holds location + release policy.
Service-loadable constraint: no FrontEnd/Notebook/NBAccess/UI dependency, no dependency on other SourceVault modules (root resolution optionally consults [SourceVault_core](https://github.com/transreal/SourceVault_core) via a DownValues guard, so a standalone `Get` still works if `$SourceVaultSlideDeckRoot` is set).
Privacy: every entry declares `PrivacyLevel` at registration (default 0.0 = public). Readers treat a missing/non-numeric level as 1.0 (fail-closed). Entries with `PrivacyLevel >= $SourceVaultSlideDeckReleaseCeiling` (default 0.5) have their narration withheld (`talkWithheld -> True`, `talk -> Null`, URL omitted) from `SourceVaultSlideDeckPresentationSpec`. `DeckFile` is a local absolute path and is never included in payloads.
Storage layout: root/`registry.json` (all entries) + root/`talks/<id>.json` (compiled scenario) + root/`talks/<id>.md` (optional raw narration markdown, if `TalkMarkdown` was given at registration). JSON is written/read via `ExportByteArray`/`ReadByteArray` with `"RawJSON"` (never `ExportString`, which mangles UTF-8 on Japanese Windows) and short retries (5x, 0.05s pause) to tolerate transient Dropbox-sync lock failures.
Title matching: normalized (NFKC, lowercased, letters/digits only) bigram-Jaccard/substring scoring via `SourceVaultSlideDeckMatchScore`, with a hard rule that trailing-digit mismatches (e.g. "31" vs "30") never match. Lookup threshold is 0.34.

### $SourceVaultSlideDeckRoot
型: String | Automatic, 初期値: Automatic
Override for the registry storage root. Set a `String` to force a directory (testing). With `Automatic`, resolves to `SourceVaultCoreRoot[]/slidedecks` if SourceVault_core is loaded, else `%LOCALAPPDATA%/SourceVault/slidedecks` (or `$TemporaryDirectory` if `LOCALAPPDATA` is unavailable).

### $SourceVaultSlideDeckReleaseCeiling
型: Real, 初期値: 0.5
Upper bound (exclusive) on `PrivacyLevel` for narration to be released to external consumers (MCP / voice bridge) via `SourceVaultSlideDeckPresentationSpec`. Entries with `PrivacyLevel >= this` get `talkWithheld -> True`.

### SourceVaultSlideDeckRoot[] → String
Returns the absolute registry directory path, creating it if missing.

### SourceVaultSlideDeckRegister[entry] → Association | Failure
### SourceVaultSlideDeckRegister[entry, talk] → Association | Failure
Upserts a talk entry into the registry (matched/replaced by `Id`). `entry` is an `Association` with keys:
Title (String, required), SlideURL (String, required, must start with "http://" or "https://"), Aliases (list of String, default {}), Id (String, default: derived from normalized Title, or an 8-char hash if Title is empty), DeckFile (local path, not exposed in payloads), SecondsPerSlide (Real, default 25.), StartSlide (Integer >= 1, default 1), EndSlide (Integer >= 1 or Null, default Null), SlideCount (Integer >= 0 or Null; auto-filled from `talk`'s Slides count if Null and `talk` given), NarrationInstructions (String, default ""), Event, Author, Date (String, freeform), PrivacyLevel (Real, default 0.0), TalkMarkdown (String; if non-empty, saved verbatim to talks/<id>.md and referenced as entry["TalkFile"]).
`talk` (optional, 2nd arg) is a compiled scenario `<|"Opening"->String, "Closing"->String, "Slides"->{<|"Slide"->Integer,"Title"->String,"Seconds"->Real|Null,"Text"->String|>...}|>` (lowercase key aliases "opening"/"closing"/"slides"/"slide"/"title"/"seconds"/"text" also accepted); saved to talks/<id>.json, and entry gets `TalkURI -> "sv://slidetalk/<id>"`.
Returns the normalized stored entry Association, or `Failure["SlideDeckTitleRequired",...]` / `Failure["SlideDeckURLRequired",...]` / `Failure["SlideDeckRegistryWriteFailed",...]`.
例: SourceVaultSlideDeckRegister[<|"Title"->"計算と自然集会31","SlideURL"->"https://example.com/talk31.mp4","PrivacyLevel"->0.|>, <|"Opening"->"...","Closing"->"...","Slides"->{<|"Slide"->1,"Text"->"..."|>}|>]

### SourceVaultSlideDeckUnregister[idOrTitle_String] → Association | Missing
Removes the matched entry (via `SourceVaultSlideDeckLookup`) from the registry. Returns `<|"Status"->"Unregistered","Id"->id,"Title"->title|>`, or `Missing["NotFound", idOrTitle]` if no match.

### SourceVaultSlideDeckRegistry[] → {Association...}
Returns all registered entries as-stored (internal keys, not JSON-safe/lowercase; includes all privacy levels).

### SourceVaultSlideDeckLookup[query] → Association | Missing["NotFound", query]
Resolves a title/alias/id (with fuzzy matching, typo/wording tolerant) to one stored entry. Matches Title, Id, and each Aliases entry; picks the highest-scoring candidate at or above threshold 0.34. Trailing-number mismatches (e.g. querying "31" against a "30" entry) never match.

### SourceVaultSlideDeckMatchScore[query, candidate] → Real
Normalizes both strings (NFKC, lowercase, letters/digits only) and scores 0.0-1.0: 0. if either is empty or trailing digits differ; 1. if equal; 0.9 if one starts with the other; 0.8 if one contains the other; else bigram Jaccard similarity.

### SourceVaultSlideDeckTalk[idOrTitle] → Association | Missing
Accepts a query string or an already-resolved entry Association. Returns the compiled scenario `<|"Version"->1,"Id"->String,"Title"->String,"Language"->String,"Opening"->String,"Closing"->String,"Slides"->{<|"Slide"->Integer,"Title"->String,"Seconds"->Real|Null,"Text"->String|>...}|>`. Returns `Missing["NotFound", query]` if no entry matches, or `Missing["NoTalk", id]` if the entry has no compiled talk JSON.

### SourceVaultSlideDeckPresentationSpec[query, opts]
Resolves a query to the full payload needed to run a presentation (URL, timing, and — if released — narration). Privacy-gated: entries at/above the release ceiling return only id/title/privacyLevel with `talkWithheld -> True`.
→ Association (JSON-safe, lowercase keys)
Options: "IncludeTalk" -> True (whether to fetch and embed the compiled talk under `"talk"`; ignored/forced Null when the entry is not released)
Return shape when not found: `<|"found"->False,"query"->String,"reason"->"NotRegistered","available"->{titles...}|>`.
Return shape when found but withheld (PrivacyLevel >= ceiling): `<|"found"->True,"released"->False,"talkWithheld"->True,"talk"->Null,"id"->...,"title"->...,"privacyLevel"->...|>`.
Return shape when released: `<|"found"->True,"released"->True,"id"->String,"title"->String,"aliases"->{String...},"url"->String,"event"->String,"author"->String,"date"->String,"slideCount"->Integer|Null,"secondsPerSlide"->Real,"startSlide"->Integer,"endSlide"->Integer|Null,"narrationInstructions"->String,"talkURI"->String,"privacyLevel"->Real,"updatedAtUTC"->String,"talkWithheld"->False,"talk"->Null|<|"opening"->String,"closing"->String,"slides"->{<|"slide"->Integer,"title"->String,"seconds"->Real|Null,"text"->String|>...}|>|>`. (`slides` only includes entries with non-empty text.)

### SourceVaultSlideDeckList[] → {Association...}
Returns all *released* entries (PrivacyLevel < `$SourceVaultSlideDeckReleaseCeiling`) as JSON-safe, lowercase-keyed Associations (same shape as `SourceVaultSlideDeckPresentationSpec`'s released `payload` fields, minus `talk`). Does not include narration text.