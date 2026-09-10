# SourceVault_todo API Reference

Unified todo cache database (context `SourceVault\``). Merges two sources into one query surface:
1. Notebook-derived todos — read index-first from `notebooks/sources/*.json` + snapshots (`TodosCompressed`); never re-imports `.nb` files on the query path. Notebooks with Status Done/Keep still contribute their open items.
2. Standalone todos — items not belonging to any notebook, stored at `<PrivateVault>/todo/items/<id>.json`. Created by `SourceVaultNewTodo`, the palette template, the mail agenda inherit-todo button, the Wolfram Cloud `RegisterTodoForm` inbox, or `SourceVaultTodoForSummary`.

Overlays (`<PrivateVault>/todo/overlays/<id>.json`) carry user-side state for notebook todos WITHOUT writing into the `.nb`: Done/Pass marking, deadline fixes, LLM summaries, and the recurrence marker. Standalone items are mutated directly (no overlay layer). Notebook todo ids start with `svtodo-nb-`; standalone ids start with `svtodo-` (hash-based).

Notes: `SourceVaultTodoShowSummary` opens a summary notebook with a save button (Eagle-style); the saved note under `todo/notes/*.nb` is the canonical user-annotated version and its text joins the search index.

Search integration: `SourceVaultTodos` (core, `List[Association]`) / `SourceVaultTodosView` (rendered view), plus a `"todo"` provider registered in `SourceVault\`$SourceVaultSummaryProviders` so todos surface in `SourceVaultSummaries` / `CrossLinks` like any other summary kind.

Weak coupling: loads and degrades gracefully when sibling packages (SourceVault core, NBAccess, notebook-extensions font helper) are absent.

## Record schema (SourceVaultTodos rows)
Keys: `TodoId`, `Origin` (`"notebook"`|`"standalone"`), `Source` (`"notebook"`|`"manual"`|`"cloud"`|`"mail"`|`"summary"`), `Text`, `Title`, `Status` (`"Open"`|`"Done"`|`"Pass"`|`"Keep"`), `StatusSource`, `Deadline` (DateObject or `Missing["None"]`), `DeadlineSource` (`"Explicit"`|`"TextParse"`|`"Overlay"`|`"Cleared"`|`""`), `Recur` (Association `<|"Cycle"->...|>` or `Missing["None"]`), `DoneAt`, `PassAt`, `Priority` (0..1 importance, 0.5 neutral default), `Summary`, `SummaryAt`, `Description`, `HasNote`, `NotebookPath`, `NotebookRef`, `NotebookTitle`, `NotebookStatus`, `CellStatus`, `LastChanged`, `PrivacyLevel`, `AddedAt`, `LinkKind`, `LinkId`, `MailRecordId`, `URI`. Effective `Status`/`Deadline`/`Recur`/`Priority` already have the overlay and recurrence logic applied — callers should not re-merge overlays manually.

## Core query

### SourceVaultTodos[query, opts]
Returns the unified todo list as `List[Association]`. Chain with `Select`/`SortBy`, or render with `SourceVaultTodosView`. `SourceVaultTodos[opts]` is shorthand for `SourceVaultTodos["", opts]` (empty query = no text filter). Default ordering (`"SortBy"->"Deadline"`): dated items first by ascending deadline (overdue included), then undated items newest-`AddedAt`-first.
→ List[Association]
Options: "Status" -> "Open" (also accepts "All", a status string, or a list of statuses), "Origin" -> All ("notebook" | "standalone" | All), "Source" -> All ("manual"|"cloud"|"mail"|"summary"|"notebook" | All), "HasDeadline" -> All (True | False | All), "DueWithinDays" -> None (integer n: only items due within n days, overdue included), "MinPriority" -> None (number: only items with effective Priority >= this value), "SortBy" -> "Deadline" ("Deadline" | "Priority"), "Limit" -> Automatic (integer caps result count)
例: SourceVaultTodos["", "Status" -> "Open", "DueWithinDays" -> 7]

### SourceVaultTodosView[query, opts]
Renders SourceVaultTodos as a Grid with row actions (done mark, recurrence marker, open note/notebook). All SourceVaultTodos options pass through. Display capped at $SourceVaultTodoViewMaxRows unless overridden.
→ Grid | Style (message string if no rows match)
Options: (all SourceVaultTodos options) plus "MaxRows" -> Automatic (integer, or All for no cap; falls back to $SourceVaultTodoViewMaxRows)

### SourceVaultTodoGet[todoId] → Association | Missing["NotFound"]
Returns the effective merged record for one todo id (notebook or standalone).

## Mutations

### SourceVaultNewTodo[spec] → Association
Creates a standalone todo (not attached to any notebook). `SourceVaultNewTodo[title_String]` is shorthand for `SourceVaultNewTodo[<|"Title"->title|>]`. Returns `<|"Status"->"OK"|"Failed", "TodoId"->..., "Record"->...|>` (on failure, `"Reason"` instead of `"Record"`).
spec keys: "Title" (required, non-empty string), "Description" (string), "Deadline" (DateObject | "yyyy-mm-dd" string | None), "Priority" (0..1), "PrivacyLevel" (number 0.–1., default 1.0 fail-safe), "Source" (default "manual"), "MailRecordId", "LinkKind"/"LinkId" (attach to an existing summary row), "Recur", "AddedAt" (ISO string, defaults to now).

### SourceVaultNewTodoTemplate[] → Association
Inserts an editable `SourceVaultNewTodo[<|...|>]` input template cell into the current InputNotebook[] (expression-centric input UI; used by the claudecode palette button). Fails with `<|"Status"->"Failed","Reason"->"NoInputNotebook"|>` if there is no input notebook.

### SourceVaultTodoSetStatus[todoId, status] → Association
Sets the effective status. `status`: `"Open"`|`"Done"`|`"Pass"`|`"Keep"`, or `Automatic` to clear the overlay override entirely (also clears DoneAt and PassAt). For notebook todos this writes the OVERLAY only — the `.nb` cell itself is untouched (use SourceVaultMarkTodo from the notebook-editing layer to change the cell). Setting `"Done"` stamps `DoneAt`; setting `"Pass"` stamps `PassAt` (both are recurrence anchors — a Passed item with a review cycle resurfaces at the next cycle just like a Done one).

### SourceVaultTodoDone[todoId] → Association
Shorthand for `SourceVaultTodoSetStatus[todoId, "Done"]`.

### SourceVaultTodoPass[todoId] → Association
Marks a todo Pass ("skipped this time"; records `PassAt`). With a review cycle set (see SourceVaultTodoRemindNext), the item resurfaces at the next cycle exactly as a Done one does.

### SourceVaultTodoRemindNext[todoId, cycle] → Association
### SourceVaultTodoRemindNext[todoId, cycle, leadDays] → Association
Adds/removes a recurrence marker. Once the todo is Done or Pass, it resurfaces as Open when the next cycle comes due (lead window before the due date depends on cycle: Yearly uses $SourceVaultTodoRecurLeadDays days, HalfYearly/Quarterly/Monthly/Weekly use progressively shorter caps of that value: 21/14/7/2 days). `cycle`: `"Yearly"`|`"HalfYearly"`|`"Quarterly"`|`"Monthly"`|`"Weekly"`|`None` (removes the marker). The 3-arg form sets the lead window explicitly (`leadDays`; `Automatic` = the cycle-scaled default). Typical use: mark an annual carry-over item Done, then `SourceVaultTodoRemindNext[id, "Yearly"]`.

### SourceVaultTodoUpdate[todoId, spec] → Association
Applies several settings in one write (what the settings panel apply button calls), so a half-finished edit never reaches the store. Notebook todos get an overlay; standalone todos are updated in place.
spec keys: "Status" ("Open"|"Done"|"Pass"|"Keep"|Automatic), "Deadline" (DateObject | "yyyy-mm-dd" | "yyyy/mm/dd" | None to clear, which also suppresses the text-parsed deadline), "Priority" (0..1), "PrivacyLevel" (0..1 | Automatic to drop an override), "Recur" (cycle string | None), "RecurLeadDays".
Returns `<|"Status", "TodoId", "Applied"|>`.

### SourceVaultTodoSetDeadline[todoId, date] → Association
Sets the deadline (DateObject or "yyyy-mm-dd"/"yyyy/mm/dd"). `SourceVaultTodoSetDeadline[todoId, None]` clears it AND suppresses the deadline the text parser would otherwise infer from the todo text, so a cleared deadline stays cleared.

### SourceVaultTodoSetPriority[todoId, p] → Association
Sets the importance 0..1 (0.5 is the neutral value used when nothing was set). Sort and filter with SourceVaultTodos's `"SortBy"->"Priority"` and `"MinPriority"` options.

### SourceVaultTodoSetPrivacyLevel[todoId, pl] → Association
Sets the privacy level of one todo, 0..1. For a notebook todo this OVERRIDES, for that item only, the level inherited from its notebook (an owner decision: it can raise or lower it); for a standalone todo it replaces the stored level. Automatic drops the override and returns to the inherited value.

## Settings panel

### SourceVaultTodoEditPanel[todoId]
The todo settings control (deadline, review cycle, importance, privacy level, Open/Done/Pass/Keep), in the shape of the mail classification panel — edits are collected in the panel and written by one apply call (SourceVaultTodoUpdate). Shown inside the todo note window (SourceVaultTodoShowSummary) and from the list view settings button.
→ dynamic panel expression

### SourceVaultTodoEditWindow[todoId]
Opens SourceVaultTodoEditPanel in its own window.
→ NotebookObject side effect

## Summaries and notes

### SourceVaultTodoShowSummary[todoId, opts]
Opens the todo summary notebook (metadata + LLM summary + description + live SourceVaultTodoEditPanel). Like the Eagle summary window it has a save button; once saved under `todo/notes/`, the saved note (carrying user annotations) is opened instead on subsequent calls, and its plaintext becomes searchable via SourceVaultTodos text queries.
→ Association (the effective record) | NotebookObject side effect
Options: "Fresh" -> False (True regenerates the summary window, ignoring any saved note)

### SourceVaultTodoBackfillSummaries[opts]
Generates LLM summaries for todos lacking one, and refines deadlines: a "\:3006\:5207 yyyy/mm/dd"-style pattern in the text is parsed deterministically first (see deadline text-parse rules below); the LLM confirms/extracts otherwise. Notebook-derived rows add notebook context (title/keywords + plaintext up to "MaxChars"). Text is wrapped as UNTRUSTED before any LLM call.
Model routing is fail-closed: rows with PrivacyLevel >= 0.5 (the confidential convention; undeclared/ordinary notebooks default to exactly 0.5) are sent ONLY to $ClaudePrivateModel (local LLM), passed explicitly so the hub's routing test cannot send them to the cloud; when no valid private model is configured, those rows are SKIPPED with reason "PrivateModelUnavailable" rather than falling back to cloud. Only PrivacyLevel < 0.5 rows use the cloud CLI. An explicit "Model" -> {provider, model, ...} option is an owner override that bypasses this guard entirely. There is no silent local→cloud fallback (calls `iCallSummaryLLM`, never the fallback variant).
→ Association (counts / per-row results)
Options: "Limit" -> 10, "Force" -> False, "Model" -> Automatic (owner override, bypasses PL routing guard), "MaxChars" -> 6000 (notebook context truncation), "TimeoutSeconds" -> 120, "Status" -> "Open" (which rows are eligible)

Deadline text-parse confidence tiers (used both live in SourceVaultTodos and during backfill): keyword ("\:3006\:5207"/"\:7de0\:5207"/"\:7de0\:3081\:5207\:308a"/"\:671f\:9650"/"deadline"/"due") + full yyyy/mm/dd → 0.9; keyword + month/day only (resolves to next future occurrence) → 0.7; bare yyyy/mm/dd anywhere in text with no keyword → 0.4. Only confidence >= 0.6 is auto-applied as the effective Deadline when no overlay/explicit deadline exists.

## Index and agenda

### SourceVaultTodoRebuildIndex[opts] → Association
Refreshes the notebook-todo cache (LOCALAPPDATA-cached, keyed by source-file count/stamp).
Options: "Scan" -> "OnWork" (incrementally re-indexes $onWork via the existing snapshot machinery; "All" also scans $offWork — slow the first time, but needed once so archived Done notebooks contribute their open todos; "None" only re-reads existing index files without rescanning)

### SourceVaultTodoAgendaItems[opts] → List[Association]
Returns OPEN standalone (non-notebook) todos shaped for the routine agenda: keys `Kind` ("Todo"), `TodoId`, `Label`, `DueT` (absolute time or Missing["None"]), `HasDeadline`, `State` ("Open"), `Summary`, `Recurred`, `Priority`, `PrivacyLevel`. Rows are filtered to `PrivacyLevel <= AccessLevel` (fail-safe: unparseable/missing level defaults to 1.0, i.e. excluded unless AccessLevel is 1.0). `SourceVaultRoutineAgendaData` folds these into the day list / overdue band and a dedicated todo band.
Options: PrivacySpec -> <|"AccessLevel" -> 1.0|> (or a bare number), "MaxItems" -> 50

### SourceVaultTodoForSummary[kind, id, spec] → Association
Attaches a todo/reminder to an existing summary row. `kind`: "eagle"|"arxiv"|"web"|"local"|"mail"|... ; `id`: that row's Id. Creates a standalone todo with LinkKind/LinkId so the row's open-action (of that kind) opens the original item. `spec` follows SourceVaultNewTodo's spec shape.
例: SourceVaultTodoForSummary["arxiv", rowId, <|"Recur"->"Yearly", "Title"->"\:5e74\:6b21\:78ba\:8a8d"|>]

## Wolfram Cloud form

### SourceVaultTodoDeployCloudForm[opts]
Deploys the Wolfram Cloud todo entry form to `<cloudbase>/obj/<user>/RegisterTodoForm` ($SourceVaultTodoCloudFormPath). Requires $SourceVaultTodoAllowCloudDeploy = True (deploy guard) or returns `Failure["DeployBlocked", ...]`. Form fields: item (required string), description (optional string), deadline (optional Date), privacy (Restricted["Number",{0,1}], default 1.0). AddedAt is stamped automatically server-side. The deployed handler runs in the cloud without SourceVault loaded — it only uses System` symbols and CloudPut, with the inbox path baked in as a literal. Submissions land in the private cloud inbox $SourceVaultTodoCloudInboxPath, one CloudObject per submission.
→ CloudObject | Failure["DeployBlocked", ...]
Options: "Permissions" -> "Public"

### SourceVaultTodoCloudFetch[opts] → Association
Fetches pending submissions from the cloud todo inbox, registers each as a standalone todo (Source -> "cloud"), and DELETES the cloud object after a successful local persist. Skips gracefully (message SourceVaultTodos::cloudskip) when not cloud-connected.
Options: "Delete" -> True (set False to keep the cloud object after fetching)

### SourceVaultTodoCloudSyncStart[] → Association
Registers the periodic cloud-inbox fetch on the shared claudecode polling tick (opt-in; does not create its own ScheduledTask). The fetch runs at most every $SourceVaultTodoCloudSyncIntervalHours hours and only when $CloudConnected is True. Set $SourceVaultTodoCloudSyncAutoStart = True in localInit to start automatically on package load.

### SourceVaultTodoCloudSyncStop[] → Association
Unregisters the periodic cloud todo fetch registered by SourceVaultTodoCloudSyncStart.

### SourceVaultTodoCloudSyncStatus[] → Association
Reports the periodic cloud todo fetch state: registered / last fetch time / last result.

## Cross-search integration
A `"todo"` provider is registered into `SourceVault\`$SourceVaultSummaryProviders`, returning rows shaped like other summary providers (Kind "todo", Id, URI, Title, Authors "", Published (deadline ISO date), Summary, URL "", File (NotebookPath), Date (AddedAt), PrivacyLevel, plus todo-specific Status/Origin columns) so todos surface inside `SourceVaultSummaries`/`CrossLinks` alongside eagle/arxiv/mail rows. Row title-click opens `SourceVaultTodoShowSummary`; row open-action opens the linked notebook (NotebookPath), else the linked summary (LinkKind/LinkId), else falls back to the summary window.

## Configuration variables

### $SourceVaultTodoStoreRoot
型: String (default unset → computed), 初期値: not set by default
Overrides the todo store root. When unset, resolves to `<PrivateVault>/todo` via SourceVault`$SourceVaultRoots["PrivateVault"] (falls back to $TemporaryDirectory/todo if the vault root is unavailable).

### $SourceVaultTodoRecurLeadDays
型: Integer, 初期値: 30
Days before the next recurrence due date at which a Done/Pass recurring todo resurfaces as Open. Used directly for "Yearly" cycles; shorter cycles (HalfYearly/Quarterly/Monthly/Weekly) cap this value at 21/14/7/2 days respectively.

### $SourceVaultTodoViewMaxRows
型: Integer, 初期値: 200
Max rows SourceVaultTodosView renders unless "MaxRows" option overrides it.

### $SourceVaultTodoCloudFormPath
型: String, 初期値: "RegisterTodoForm"
Cloud object name of the entry form deployed by SourceVaultTodoDeployCloudForm.

### $SourceVaultTodoCloudInboxPath
型: String, 初期値: "todo-inbox"
Cloud directory holding pending form submissions, consumed by SourceVaultTodoCloudFetch.

### $SourceVaultTodoAllowCloudDeploy
型: Boolean, 初期値: False
Deploy guard; SourceVaultTodoDeployCloudForm refuses (returns Failure["DeployBlocked",...]) unless True.

### $SourceVaultTodoCloudSyncIntervalHours
型: Number, 初期値: 12
Minimum hours between automatic cloud inbox fetches triggered by the shared polling tick.

### $SourceVaultTodoCloudSyncAutoStart
型: Boolean, 初期値: False
True → SourceVaultTodoCloudSyncStart[] runs automatically when SourceVault_todo loads (opt-in, set in localInit).