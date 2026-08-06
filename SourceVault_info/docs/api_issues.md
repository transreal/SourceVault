# SourceVault_issues API Reference (LLM-Optimized)

## Overview
Generic issue database, not GitHub-specific. Sources include GitHub Issues via `github.wl` (`GitHubREST`GitHubAllOpenIssues`), and machine-local producers (diagnostics/watchdog/workflow/privacy/nbaccess) via the signal pipeline. On ingest, issues are:
1. Scanned via existing prompt-injection defenses (`SourceVaultSecurityPreScan` / `SourceVaultAssessInputTrust`).
2. Decomposed deterministically into multiple issues when the body contains ≥2 unrelated numbered problem sections.
3. Recorded with registration timestamp, origin (URL etc.), author id (identity-linked), owner + owner LLM model, and author trust score.
4. Scored for Risk and Importance from all information available at registration time.
5. Stored idempotently, keyed by a hash of `SourceKey` (derived from `Origin`/`Title` if not given).

Per-issue work happens in a dedicated notebook (`udb/issues/yyyymmdd-<title>.nb`, `NotebookStatus` header with Deadline/NextReview) carrying action buttons for: spec creation (consensus), code-fix start, reproduction verification (safe execution / auto-proposed), fix application, package commit, resolution-summary registration, GitHub notification.

Safety pipeline: code verification always runs a 4-point deterministic guard (comment stripping, injection keywords in string literals, overlong suspicious identifiers, writes to `NBAccess`-managed vars/credential access/forbidden paths/`AccessLevel -> 1.0`), cross-checked against `$ClaudeAdvisaryModel` re-verification. Disagreement or malice detection raises the stored Risk, reports details to the owner, and halts further action. Execution only proceeds through `NBAccess`NBValidateHeldExpr` -> `Permit`, executed via `NBAccess`NBExecuteHeldExpr`; forbidden/approval-required heads are never executed (reported to the owner as requiring approval; FE-required cases are deferred to the owner).

Service-loadable constraint (spec v6 §3.4) is satisfied except for View/Notebook functions: root resolution goes through core's `SourceVaultRoot`; other module references are runtime fail-soft (guarded via `DownValues`/`Names` checks).

## Data Model (spec v0.4)
Record schema version 2. Read normalizes v1 records into a v2 view without touching disk (`Revision -> 0`, nested containers defaulted, unknown legacy fields preserved); the first mutation materializes it.
Container defaults added on normalize: `Relations -> <|"ParentIssueId" -> "", "SubIssueIds" -> {}|>`, `ResolutionHistory -> {}`, `Archive -> <||>`, `ArchiveHistory -> {}`, `Remediations -> {}`, `ReopenCount -> 0`, `SchemaVersion -> 2`, `Revision -> Integer`.
Reserved (internal-only) fields — rejected by `SourceVaultIssueUpdate` / `SourceVaultIssueUpdateAtomic` with `Failure["ReservedIssueField"]`: `Type`, `SchemaVersion`, `Revision`, `IssueId`, `SourceKey`, `RegisteredAt`, `Status`, `Safety`, `Resolution`, `ResolutionHistory`, `Archive`, `ArchiveHistory`, `Relations`, `Remediations`, `ReopenCount`, `DoctorState`, `Evidence`, `EvidenceSafety`, `AnalysisJobRef`, `Writer`. Change them only through the canonical APIs (`SourceVaultIssueTransition`, `SourceVaultIssueAttachResolution`, `SourceVaultIssueLinkChild`, `SourceVaultIssueArchive`, …).
Commit path (single serialized writer): journal `Prepared` → index dirty marker → atomic record write (`Revision`+1, `Writer -> <|MachineTag, Epoch|>`, `UpdatedAt`) → `RecordCommitted` → index row update → `IndexCommitted` → marker clear → journal `Completed` (failure → `Failed` with `FailureClass`/`LastError`). All writes are tmp→rename atomic. Index write failure still leaves the record commit valid; the dirty marker forces a later rebuild. Index file is `index.wxf` v2 (`IndexSchemaVersion = 3`, `<|"IndexSchemaVersion", "BuiltAtUTC", "AppliedOperationId", "Rows"|>`); legacy flat indexes are rebuilt on first commit.
Index row fields (projection used by list/panel/view): `IssueId`, `SourceKey`, `Title`, `Status`, `Class`, `RecordRevision`, `ResolutionSummary` (≤90 chars), `MachineTag`, `Component`, `ReasonCode`, `IncidentKey`, `EpisodeId`, `OccurrenceCount`, `LastSeenAt`, `LastObservedHealth`, `ParentIssueId`, `SubIssueCount`, `ArchiveAt`, `Risk`, `Importance`, `RegisteredAt`, `UpdatedAt`, `OriginKind`, `OriginURL`, `Package`, `PartLabel`, `AuthorLogin`, `NotebookPath`, `FixAppliedAt`, `FixDiagnose`, `NotifiedAt`, `NotifiedSHA`, `ImplTestGate`, `ImplCommitReady`, `GroupNotifiedAt`, `CommitCheckFound`, `PrivacyLevel`.
Reducer field domains (each reducer may only touch its own fields): `Event -> {Evidence, DoctorState, Importance, UpdatedAt}`, `Observation -> {DoctorState, UpdatedAt}`, `Transition -> {Status, Resolution, ResolutionHistory, Archive, ArchiveHistory, ReopenCount, LastTransition, UpdatedAt}`, `Relation -> {Relations, UpdatedAt}`, `Remediation -> {Remediations, UpdatedAt}`, `Analysis -> {AnalysisJobRef, UpdatedAt}`. Violations return `Failure["InvariantViolation"]`.

## Configuration
### $SourceVaultIssueRoot
型: Automatic | String, 初期値: Automatic
Override for the issue-DB record root. When Automatic, resolves via `SourceVaultRoot["PrivateVault"]` + `"issues"`, falling back to a temp dir.
### $SourceVaultIssueNotebookRoot
型: Automatic | String, 初期値: Automatic
Override for the issue notebook folder (default `<udb>/issues`, where `udb` is the parent of `PrivateVault`).
### $SourceVaultIssuesViewLimit
型: Integer, 初期値: 50
Row cap for `SourceVaultIssuesView`.
### $SourceVaultIssueGitHubFetcher
型: Automatic | Function[], 初期値: Automatic
Test seam replacing the GitHub fetch layer used by `SourceVaultIssueIngestGitHub`. Default resolves to `GitHubREST`GitHubAllOpenIssues`.
### $SourceVaultIssueProfileFetcher
型: Automatic | Function[login], 初期値: Automatic
Test seam replacing author-profile fetch. Default resolves to `GitHubREST`GitHubIssueAuthorProfile`.
### $SourceVaultIssueAdvisaryQuery
型: Automatic | Function[prompt], 初期値: Automatic
Test seam replacing the advisary re-verification query. Default routes through `$ClaudeAdvisaryModel` (`"chatgptcodex"` uses the `codex` CLI in `read-only` sandbox with `approval_policy=never`; other providers use `ClaudeQuerySync` with the model substituted).
### $SourceVaultIssueCommitLogFetcher
型: Automatic | Function[pkg, owner, sinceIso], 初期値: Automatic
Test seam for the commit lookup used by resolution notification. Default resolves to `GitHubREST`GitHubCommitLog`.
### $SourceVaultIssueCommentPoster
型: Automatic | Function[pkg, owner, number, body], 初期値: Automatic
Test seam for the comment-posting layer used by resolution notification. Default resolves to `GitHubREST`GitHubIssueAddComment`.
### $SourceVaultIssueCommentFetcher
型: Automatic | Function[pkg, owner, number], 初期値: Automatic
Test seam for GitHub comment listing. Default resolves to `GitHubREST`GitHubIssueComments`; when unloaded, rediscovery of already-posted markers is skipped.
### $SourceVaultIssueFixApplier
型: Automatic | Function[slug, mode], 初期値: Automatic
Test seam for fix-application execution; `mode` is `"dry"|"apply"|"diagnose"`. Default calls the generation workflow's `<Launch>["patch"]` / `["patch","apply"]` / `["diagnose"]`.
### $SourceVaultIssueDocUpdater
型: Automatic | Function[pkg], 初期値: Automatic
Test seam for the docs-update layer of the commit button. Default is `ClaudeUpdateDocumentation` in synchronous mode.
### $SourceVaultIssueDocsGateChecker
型: Automatic | Function[pkg], 初期値: Automatic
Test seam for the pre-commit docs-freshness gate. Default resolves to `GitHubREST`PackageDocsFreshnessGate`.
### $SourceVaultIssuePackageCommitter
型: Automatic | Function[pkg], 初期値: Automatic
Test seam for the commit layer of the commit button. Default is `PackageCommit[pkg, "DryRun" -> False]`.
### $SourceVaultIssueVerifyProposer
型: Automatic | Function[prompt], 初期値: Automatic
Test seam for the LLM layer that proposes verification code. Default is `ClaudeQuerySync` with `$ClaudeModel`.
### $SourceVaultIssueImplLauncher
型: Automatic | Function[nb, suppressDialog], 初期値: Automatic
Test seam for the implementation launcher. Default is the same spec-impl entry point the palette uses.
### $SourceVaultIssueResumeScheduler
型: Automatic | Function[id, fireAt], 初期値: Automatic
Test seam for auto-resume scheduling. Default is `SessionSubmit[ScheduledTask[...]]`.
### $SourceVaultIssueOutboxRoot
型: Automatic | String, 初期値: Automatic
Override for the machine-local issue-outbox (default `$UserBaseDirectory/ApplicationData/SourceVault/issue-outbox`). Test seam.
### $SourceVaultIssueProducerAdapters
型: Association, 初期値: 下記の trusted registry
Maps producer → `<|"AllowedClasses" -> {..}, "PLFloor" -> x, "ProducerCapability" -> ..|>`. Producer self-declared `IssueClass`/`PrivacyLevel` is never trusted; this registry forces them (v0.4 §4.3). Defaults: `"diagnostics" -> <|{"doctor"}, 1.0, "DoctorObserver"|>`, `"watchdog" -> <|{"doctor"}, 1.0|>`, `"workflowcatalog" -> <|{"workflow"}, 0.85|>`, `"specimpl" -> <|{"workflow"}, 0.85|>`, `"privacy" -> <|{"security"}, 1.0|>`, `"nbaccess" -> <|{"security"}, 1.0|>`.
### $SourceVaultIssueWriterMachineTag
型: Automatic | String, 初期値: Automatic
Override for the writer designation. Automatic treats `<IssueRoot>/writer.json` as authoritative; a string takes effect only when `writer.json` is absent.
### $SourceVaultIssueApprovalKey
型: Automatic | String, 初期値: Automatic
Override for the approval-capability signing key (test seam). Default order: `SystemCredential["SourceVaultIssueApprovalKey"]` → machine-local secret.
### $SourceVaultIssueSyncMinIntervalSeconds
型: Integer, 初期値: 60
Debounce interval (seconds) for `SourceVaultIssueSyncNow`.
### $SourceVaultIssueRiskReviewLeadDays
型: Integer, 初期値: 7
How many days before an `AcceptedRisk` `ReviewBy` date the re-review issue is generated.

## Core Registry
### SourceVaultIssueRoot[] → String
Issue-DB record root directory (`<PrivateVault>/issues`), overridable via `$SourceVaultIssueRoot`.
### SourceVaultIssueNotebookDirectory[] → String
Issue notebook storage folder (`<udb>/issues`), overridable via `$SourceVaultIssueNotebookRoot`.
### SourceVaultIssueRebuildIndex[] → Association
Rebuilds `index.wxf` (v2 form) from the `records/` folder (corruption recovery). Writer-only.
→ `<|"Status" -> "OK", "Count" -> n|>`; `Failure["IndexWrite", ...]` on write failure, `Failure["NotWriter", ...]` on a non-writer machine.
### SourceVaultIssueEnsureIndex[] → Association
Detects index schema-version mismatch, legacy flat format, or leftover dirty markers, and rebuilds index v2 from `records/` (tmp → publish). Rebuild is writer-only.
→ `<|"Status" -> "OK", "Rebuilt" -> False|>` when healthy, `<|"Status" -> "OK", "Rebuilt" -> True, "Count", "ClearedDirty"|>` after rebuild, `<|"Status" -> "StaleIndex", "Rebuilt" -> False, "DirtyCount" -> n|>` on a non-writer machine.
### SourceVaultIssueStartupRepair[] → Association
Crash recovery: scans the pending operation journal, re-projects index rows for records already committed, clears dirty markers, and closes the journal entries. Idempotent (repairs missing projections/receipts rather than being a no-op).
→ `<|"Status" -> "OK", "RepairedRows" -> n, "ClosedOperations" -> n, "Rebuilt" -> Bool|>` or `<|"Status" -> "NotWriter", "Writer" -> ..|>`.
### SourceVaultIssueRegister[assoc] → Association
Idempotently registers an issue. `IssueId` is derived from a hash of `SourceKey` (or of `Origin`/`Title` when `SourceKey` is absent); re-registering the same key updates only source fields while preserving `Status`/`Resolution`/`NotebookPath`/`Verification`/`Safety`/`ManualNotes`/`RegisteredAt`. Registration auto-computes pre-scan, InputTrust, author trust, Risk (monotonic — never decreases on re-registration), and Importance. Input keys (all optional except `Title`): `Title`, `Body`, `ContextText`, `Origin` (`<|"Kind","URL","Owner","Repository","Package","Number","Part","PartCount"|>`), `Author` (`<|"Kind","Login","AuthorAssociation","Profile","IdentifierId"|>`), `Labels`, `SourceCreatedAt`, `SourceUpdatedAt`, `CommentCount`, `SourceKey`, `PrivacyLevel` (default 0.15 for GitHub-origin, else 0.85), `RegisteredBy`.
→ `<|"Status" -> "Registered"|"Updated", "IssueId" -> "iss-...", "IssueStatus" -> "Open"|"Quarantined"|.., "Risk" -> 0..1, "Importance" -> 0..1|>`. Returns `Failure["IssueRegister", ...]` if `Title` is empty or the write fails, `Failure["NotWriter", ...]` on a non-writer machine.
### SourceVaultIssueGet[issueId] → Association | Missing["NotFound", issueId]
Returns the full issue record, normalized to schema v2 (read-only normalization; disk is untouched).
### SourceVaultIssueUpdate[issueId, changes_Association] → Association | Missing["NotFound", issueId] | Failure | $Failed
Merges `changes` into the record and refreshes `UpdatedAt`/`Revision`. [v0.4 breaking change] Returns `Failure["ReservedIssueField", ...]` when `changes` touches an internal-only field (see Data Model). Use `SourceVaultIssueTransition` for `Status` and `SourceVaultIssueAttachResolution` for resolution.
### SourceVaultIssueUpdateAtomic[issueId, fn, opts] → Association | Failure
CAS update: commits `fn[record]`'s return value with `Revision`+1.
→ record Association; `Failure["Conflict", ...]` when `"ExpectedRevision"` differs from the current `Revision`, `Failure["ReservedIssueField", ...]` when `fn` mutated an internal-only field.
Options: `"ExpectedRevision" -> Automatic` (integer to enforce CAS)
### SourceVaultIssueTransition[issueId, to, meta] → Association | Failure
Canonical Status API, enforcing the transition matrix (spec v0.4 §7.1): `Open -> Quarantined|Resolved`; `Resolved -> Open` (reopen: current `Resolution` is pushed onto `ResolutionHistory`, `ReopenCount`++); `Resolved -> Archived`; `Archived -> Archive.PreviousStatus` (unarchive); `Quarantined -> Open|Resolved` (requires `meta` `"OwnerReview" -> True`). Legacy statuses can be normalized into `Open|Resolved|Quarantined`. `Quarantined -> Archived` is always refused.
meta keys: `"Resolution" -> <|"Summary" -> .., ..|>` (required, with `Summary`, when `to` is `"Resolved"`), `"Reason"`, `"OwnerReview"`.
### SourceVaultIssueClass[record | issueId] → String
Derives the origin class from `Origin.Kind`: `"github"` | `"manual"` (`manual`/`url`) | `"doctor"` | `"security"` | `"workflow"` | `"unknown"`. `unknown` is never folded into `manual`.
### SourceVaultIssueNew[assoc, opts] → Association
Sugar for manual issue creation: `Register` + issue-notebook creation + (when `"ParentIssueId"` is given) parent/child linking in one operation. Notebook-creation failure does not invalidate the registration (re-evaluation stays duplicate-free). Internal-only fields cannot be injected via `assoc`. On a non-writer machine the Register command is enqueued and `Queued` is returned.
→ `<|"Status" -> "Created"|"AlreadyExists"|"RegisteredNotebookFailed"|"Queued", "IssueId", ..|>`
Options: `"Notebook" -> Automatic` (`False` skips notebook creation)
Use the `SourceKey` baked into the generated template cell so re-evaluation is idempotent.
### SourceVaultIssueLinkChild[parentId, childId] → Association | Failure
Canonical bidirectional parent/child link (idempotent). Self-link, cycles, and an existing different parent are rejected.
### SourceVaultIssueUnlinkChild[parentId, childId] → Association | Failure
Removes the parent/child link from both sides (idempotent).
### SourceVaultIssues[opts] → {Association...}
Filtered/sorted issue index (core; lightweight index rows, not full records). Sort tie-breaks deterministically: primary sort key desc → `RegisteredAt` desc → `IssueId`. Wrapped via `SourceVaultPrivateResult` when privacy module is loaded.
Options: `"Status" -> All` (or a status string e.g. `"Open"`), `"Query" -> ""` (substring match against Title/origin), `"SortBy" -> "Importance"` (`"Importance"|"Risk"|"RegisteredAt"`), `"Limit" -> 200`.
### SourceVaultIssueTop[opts] → Association | Missing["NoIssues"]
Returns the single top-sorted issue as a full record (via `SourceVaultIssueGet`). Same options as `SourceVaultIssues`.

## Signals (Producer → Transport → Reconcile)
Producers never write the shared DB directly. Flow: `SignalNormalize` (trusted adapter forces class/privacy) → `SignalEnqueue` (machine-local outbox, immutable 1-file-per-EventId, temp→rename) → `ForwardOutbox` (publish into the shared inbox) → `SignalReconcile` (writer-side dedup by global EventId receipt, aggregate into episodes, apply to issue records).
### SourceVaultIssueSignalNormalize[event] → Association | Failure
Normalizes a producer event into the canonical `SourceVaultIssueSignal/1` (v0.4 §4.2). `IssueClass` is forced into the adapter's `AllowedClasses`, `PrivacyLevel` gets the adapter floor applied, `Severity`/`Health` are canonicalized to their enums, and `IncidentKey` is the canonical-JSON hash of (class, machine, component, reason, subject).
→ normalized signal Association; `Failure["UnroutableIssueSignal", ...]` for an unknown adapter/producer.
### SourceVaultIssueSignalEnqueue[event] → Association
Normalizes and appends the signal to the machine-local issue-outbox as an immutable envelope (producer-side entry point, short-lived). Below the firing threshold (Severity < High AND Health =!= Failing AND not `IssueRequested`) nothing is written.
→ `<|"Queued" -> True, "EventId", ..|>` or `<|"Queued" -> False, "Reason" -> "BelowThreshold"|>`. Re-running with the same EventId + same digest is treated as success.
### SourceVaultIssueForwardOutbox[] → Association
Publishes local outbox envelopes into the shared inbox (`<IssueRoot>/inbox/<machine>/pending/<date>/`). `PublishedAtUTC` is fixed once at first publish and never changes on retry. Same-digest re-publish succeeds; a differing digest is quarantined into `conflict/`.
### SourceVaultIssueSignalReconcile[opts] → Association
Writer-side reconciler: dedups pending shared-inbox signals by global EventId receipt, aggregates them into episodes, and applies them to issue records. Per-`SignalKind` reducers — `Recovery` does not increment `OccurrenceCount` and never creates a new issue when no active episode exists. Processed envelopes move to `done/`.
Options: `"Limit" -> 200`
### SourceVaultIssueObserveSignal[event] → Association
Direct entry point that normalizes and applies in one call, bypassing the transport (test seam / synchronous use). Receipts and evidence are recorded exactly as the reconciler would.
### SourceVaultIssueFromDiagnostics[event] → Association
Doctor-compatible wrapper for a diagnostics escalation event: checks the firing threshold (`High`/`Critical`/`Failing`/`Escalate`) and, when exceeded, forwards to `SourceVaultIssueSignalEnqueue`. Return value includes `"Queued"` (recorded by the caller as `IssueSignalQueued`).

## Writer / Command Queue / Approval
Single-writer model (v0.4 §5): only the designated machine may write shared records/index. Other machines enqueue mutation commands. No automatic failover.
### SourceVaultIssueWriterStatus[] → Association
Returns the writer configuration (`<IssueRoot>/writer.json`) and this machine's relation to it.
→ `<|"Configured" -> Bool, "MachineTag", "Epoch", "SelfMachineTag", "IsWriter" -> Bool, "CompatMode" -> Bool|>`. Unconfigured = compatibility mode (single-machine operation: any machine may commit, Epoch 0). When configured, only the designated machine can write; other machines' mutations return `Failure["NotWriter", ...]` (→ command queue).
### SourceVaultIssueWriterClaim[] → Association
Registers this machine as the writer when unconfigured (Epoch 1). If already configured, returns `AlreadyConfigured` (use `SourceVaultIssueWriterHandoff` to change).
### SourceVaultIssueWriterHandoff[toTag, opts] → Association | Failure
Explicit writer handoff (`WriterEpoch`++). No auto-failover: the owner must confirm the old writer service is stopped and Dropbox sync has completed, then pass `"Confirm" -> True`. The old writer is fenced with `NotWriter` on its next commit and reports to diagnostics.
Options: `"Confirm" -> False`
### SourceVaultIssueCommandEnqueue[cmd] → Association
Registers a mutation command into the shared command queue (`<IssueRoot>/commands/pending/`) — the FE entry point on non-writer machines.
cmd: `<|"Command" -> "Update"|"Transition"|"AttachResolution"|"Register"|"ExternalAction", "TargetIssueId", "Args" -> <|..|>` (JSON-safe values only)`, "ExpectedRevision"` (optional)`, "ApprovalRef"` (approval-required commands only)`|>`
→ Association including `"OperationId"` and `"ResultQuery"`.
### SourceVaultIssueCommandResult[operationId] → Association
Current state of a command: `Queued` | `Applied` | `Conflict` | `Failed` | `ApprovalInvalid` | `Missing`.
### SourceVaultIssueCommandProcess[opts] → Association | Failure
Writer-side validation and execution of pending commands, writing outcomes to `done/`. On a non-writer machine returns `NotWriter`. Approval-required commands execute only after the capability's target/digest/expiry/signature all verify — `RequestedBy`/`Confirmed` flags are audit metadata and are never treated as authentication (v0.4 §5.2).
Options: `"Limit" -> 100`
### SourceVaultIssueApprovalCreate[actionId, targetIssueId, payloadDigest, opts] → Association
Creates an owner-approval capability (target / payload digest / expiry binding + keyed-hash signature). Key resolution order: `$SourceVaultIssueApprovalKey` (seam) → `SystemCredential` → machine-local secret.
Options: `"ExpiresSeconds" -> 3600`, `"ApprovedBy" -> Automatic`

## Archive
### SourceVaultIssueArchiveEligibility[issueId] → Association
Evaluates the class × Disposition retention conditions (spec v0.4 §8.2).
→ `<|"Eligible" -> Bool, "Reasons" -> {..}, "Class", "AutoArchive" -> Bool|>`
Conditions: github = Resolved ∧ fix applied ∧ notified; doctor(`Fixed`|`Recovered`) = stability window (`StableCandidate`) ∧ children complete; doctor(`FalsePositive`) = `TuningProposal` recorded; (`AcceptedRisk`) = `ReviewBy` required; manual = `Summary`; workflow = `Summary` + fix reference; security = `Disposition`; `unknown` and `Quarantined` are never eligible.
### SourceVaultIssueArchive[issueId, reason] → Association | Failure
Logical archive (`Status -> "Archived"`). When eligibility does not hold, nothing is executed and `Failure["NotEligible", ...]` reports the missing conditions (confirmation cannot override it; use `SourceVaultIssueForceArchive`). Notebooks are not moved (v0.4 §8.1).
### SourceVaultIssueUnarchive[issueId, opts] → Association | Failure
Restores `Archive.PreviousStatus` and pushes `Archive` onto `ArchiveHistory`. When `PreviousStatus` is `Quarantined`, `"OwnerReview" -> True` is required.
Options: `"OwnerReview" -> False`
### SourceVaultIssueForceArchive[issueId, opts] → Association | Failure
Owner-only forced archive, bypassing the transition matrix while still saving `PreviousStatus`. `Quarantined` cannot be archived even by force.
Options: `"AuditReason" -> None` (required; a string must be supplied)
### SourceVaultIssueAutoArchiveSweep[opts] → Association
Archives Resolved issues matching the auto-archive rules (github = notification complete / doctor = stability established), and generates exactly one re-review issue when an `AcceptedRisk` `ReviewBy` date comes due (lead time `$SourceVaultIssueRiskReviewLeadDays`). Writer-only; never call it from Panel rendering.
Options: `"DryRun" -> False`, `"Limit" -> 100`

## Sync
### SourceVaultIssueSyncNow[] → Association | Failure
"Sync latest issues" (v0.4 §5.4): idempotent GitHub open-issue ingest + immediate reconcile of pending signals + recording `SourceOpenMissingAt` for github issues that vanished from the open list, all in one operation, returning a summary. Debounced — a call within `$SourceVaultIssueSyncMinIntervalSeconds` returns the previous result with `Status -> "Debounced"`. Non-writer machines get `Failure["NotWriter", ...]` (the Panel enqueues a Sync command instead).

## Panel / View
### SourceVaultIssuePanel[] → Panel expression
Displays the issue list in the same style as the workflow list: status/class badges, search, class and PC filters, sync, archive-in-separate-window, new issue, archive candidates, manual refresh (avoids FE freezes). Rows are built read-only from the index projection alone. Mutation buttons execute directly on the writer machine and enqueue commands elsewhere.
### SourceVaultIssueArchivePanel[] → Panel expression
Lists only archived issues in the same layout; the action column is 「戻す」 (Unarchive).
### SourceVaultIssuesView[opts] → Dataset
Dataset display of the issue list with an "開" (Open) button per row that opens (or creates) the issue notebook. Row cap is `$SourceVaultIssuesViewLimit`. Same options as `SourceVaultIssues`. Columns: 開/Issue/重要度/危険度/状態/由来/作者/登録. 状態 appends `(修正適用済✓)` when a fix was applied and post-apply diagnose confirmed `"Fixed"`, or `(修正適用済)` when applied but unconfirmed; also surfaces impl-result (`TestGate`/`CommitReady`) and 「コミット待ち」 for resolved-but-uncommitted issues.

## GitHub Ingestion
### SourceVaultIssueIngestGitHub[opts]
Loads Open Issues across all `github.wl`-managed repositories, runs pre-scan → decomposition (unrelated multi-problem issues split) → trust/risk/importance scoring, then idempotently registers into the issue DB. Skips pull requests. Observes each author into the identity layer (fail-soft) via `SourceVaultObserveIdentifier`.
→ `<|"Fetched" -> n, "Registered" -> n, "Updated" -> n, "Quarantined" -> n, "Errors" -> {...}, "Ids" -> {"iss-..."}|>`. Returns a `Failure` if `github.wl` (`GitHubREST`) is not loaded.
Options: `"MaxItems" -> 50` (per repository), `"Decompose" -> True`, `"IncludePullRequests" -> False`.
### SourceVaultIssueDecompose[title, body] → {Association...}
Deterministically splits an issue body into parts. Section boundaries are `##`〜`####` heading lines; splitting happens only when ≥2 of those headings are numbered (heading text matches `^[0-9０-９]+\s*[.．、)】]`), otherwise a single part is returned. Each element: `<|"Title" -> String (≤80 chars, from heading), "Body" -> String, "Part" -> Integer, "PartCount" -> Integer, "ContextText" -> String (≤2000 chars, shared preamble + non-numbered sections)|>`. Also unwraps a body that is entirely one ` ``` ` fence before splitting.
例: `SourceVaultIssueDecompose["Bug report", "## 1. Crash on load\n...\n## 2. Slow save\n..."]` → 2 parts, each carrying the shared `ContextText`.

## Safety & Code Guard
### SourceVaultIssueStripComments[code] → String
Removes Wolfram Language comments from `code`, correctly handling nested `(* *)` and `(*`-like text inside string literals.
### SourceVaultIssueCodeGuard[code] → Association
Deterministic 4-point scan: (1) comment stripping (2) injection keywords inside string literals — prefers `SourceVaultSecurityPreScan`, falls back to a built-in regex pattern list when mining is unloaded (3) overlong (>32 chars) identifiers containing suspicious words (`ignore`,`disregard`,`override`,`bypass`,`jailbreak`,`sudo`,`exfiltrat`,`backdoor`,`approveall`,`noguard`,`disablecheck`,`skipvalidation`) (4) `SystemCredential` access, writes to `$NB*`/`NBAccess\`` vars, forbidden path tokens (`.nbaccess`,`.ssh`,`id_rsa`,`.aws`,`.gnupg`,`key-index`,`SystemCredentialData` → Rejected; `.claude.json`,`.claude\`,`.claude/` → Suspicious), `"AccessLevel" -> 1.0` (Rejected), and side-effecting heads (`Run`,`RunProcess`,`StartProcess`,`URLExecute`,`URLDownload`,`URLSubmit`,`Install`,`ExternalEvaluate`,`CloudEvaluate`,`SocketConnect`,`DeleteFile`,`DeleteDirectory` → Suspicious).
→ `<|"Status" -> "Clean"|"Suspicious"|"Rejected", "Findings" -> {<|"Kind","Severity","Detail"|>...}, "Stripped" -> String, "StringCount" -> Integer|>`
### SourceVaultIssueSafetyAssess[issueId, opts] → Association
Cross-checks the deterministic guard (body + extracted code blocks) against `$ClaudeAdvisaryModel` re-verification. Only executable fenced blocks (language empty/`wl`/`wolfram`/`mathematica`/`wls`/`m`) are guarded; prose fences are ignored. On malice detection, raises stored Risk, sets `Status -> "Quarantined"`, prints an owner report, and further action is expected to stop.
→ `<|"IssueId", "Verdict" -> "Clean"|"Malicious"|"Disagreement"|"AdvisaryUnavailable", "Risk", "IssueStatus", "Guard" -> "Clean"|"Suspicious"|"Rejected"|"NoCode", "GuardFindings", "PreScanState", "AdvisaryAvailable" -> Bool, "AdvisaryReasons" -> {...}, "Stopped" -> Bool|>`. `Verdict` is `"Disagreement"` when the deterministic and advisary judgments conflict (fail-closed); `"AdvisaryUnavailable"` when advisary is unreachable and `"RequireAdvisary" -> True`.
Options: `"RequireAdvisary" -> True` (set `False` to accept a deterministic-only verdict when advisary is unreachable).

## Verification (Safe Execution)
### SourceVaultIssueVerifyCode[issueId, code, opts] → Association
Evaluates reproduction-verification code through the safe-execution chain: 4-point guard on `code` → `NBAccess`NBValidateHeldExpr`. Only a `"Permit"` decision executes, via `NBAccess`NBExecuteHeldExpr`; forbidden/approval-required heads are not executed (reported as requiring owner approval; FE-required operations are deferred to the owner). All attempts (including guard rejections) are appended to the record's `Verification` history (last 20 kept). Refuses to run if the issue's `Status` is `"Quarantined"`, if the code fails to parse, or if `NBAccess` is not loaded.
→ `<|"IssueId", "Status" -> "Executed"|"OwnerFERequired"|"AwaitingOwnerApproval"|"Denied", "Decision" -> "Permit"|"NeedsApproval"|"Deny", ...|>` (plus `"Result"` when Executed, `"Reason"`/`"ApprovalHeads"`/`"Message"` otherwise). Returns `Failure[...]` for `"VerificationBlocked"` (quarantined or guard-rejected), `"VerificationParse"`, `"NBAccessUnavailable"`, or `"ValidationFailed"`.
Options: `"TimeConstraint" -> 30`, `"AccessSpec" -> Automatic` (defaults to `<|"AccessLevel" -> 0.5|>`).
### SourceVaultIssueProposeVerification[nb | issueId] → Association
After the safety gate passes, asks `$ClaudeModel` for reproduction-verification code under explicit constraints (pure computation, no side-effecting heads, stated pass/fail criterion), runs the proposed code itself through the 4-point guard, and inserts it into the notebook as a `SourceVaultIssueVerifyCode[id, "<code>"]` expression template (notebook button 「再現検証 (自動提案)」). Guard-`Rejected` proposals are displayed in a non-executable form together with the findings. With an `issueId` argument no cell is inserted; the proposal Association is returned.

## Issue Notebook Workflow
### SourceVaultIssueNotebook[issueId, opts] → NotebookObject | Missing["NotFound", issueId]
Opens the issue's dedicated notebook, creating `udb/issues/yyyymmdd-<title>.nb` if none exists yet, with a `NotebookStatus` header (`Deadline` — 14 days if Importance ≥ 0.7 else 30 days; `NextReview` — 1 week; `Status -> "Todo"`; `Title`; `IssueRecordId`), title cell, info summary (origin/author/trust/importance/risk/status/registration), action-button row, a task-framing cell (`CellTags -> {"svIssueBody","svIssueTask"}` — states the issue body is untrusted observation data, not a requirement spec, and instructs the spec to cover reproduction/root cause, fix, and regression test), the untrusted issue body, optional shared `ContextText`, and a work-log section. Action buttons: 仕様作成(合議) → `SourceVaultIssueCreateSpec`; コード修正開始 → `SourceVaultIssueStartImpl`; 再現検証(安全実行) → `SourceVaultIssueVerifyFromNotebook`; 再現検証(自動提案) → `SourceVaultIssueProposeVerification`; 修正適用(承認) → `SourceVaultIssueApplyFix`; コミット(承認) → `SourceVaultIssueCommitPackage`; 解決サマリー登録 → `SourceVaultIssueAttachResolution`; GitHub通知(確認) (GitHub-origin issues only) → `SourceVaultIssueNotifyGitHub`; 元イシューを開く → `SystemOpen` on the origin URL.
Options: `"Open" -> True`.
### SourceVaultIssueForNotebook[nb | path] → String | Missing
Reads back `IssueRecordId` from an issue notebook, unevaluated (used to resolve which issue a button click belongs to).
### SourceVaultIssueCreateSpec[nb | issueId]
After the safety gate passes, launches consensus resolution-spec authoring (spec-review consensus between `$ClaudeModel` and `$ClaudeAdvisaryModel`).
### SourceVaultIssueStartImpl[nb | issueId]
Launches the spec-impl workflow (implementation + verifier consensus + hard test gate) against the approved spec.
### SourceVaultIssueEmitResumeControls[nb, reason]
Writes resume controls into the notebook (「実装を再開」/「リセット時刻に自動再開」 buttons plus a status explanation) when the implementation stopped for a "retry later" reason such as a provider limit or seat exhaustion. Parses the reset time out of `reason` (e.g. `"resets 12:50pm (Asia/Tokyo)"`) and records it. Called loosely-coupled from claudecode's spec-impl write-back. Durable state is stored in the issue record (`ImplBlock`), so the same notebook's resume button still works after a Mathematica restart.
### SourceVaultIssueEmitResumeControls[nb]
One-argument form: reads the reason from the existing notebook's blocked cell (`CellTags "sourcevault-impl-blocked"`) and appends the controls.
### SourceVaultIssueResumeImpl[nb | issueId, opts]
Resumes an implementation workflow that stopped on a limit, restarting from the approved spec (a new run). Works after a Mathematica restart via the notebook button or an explicit id.
Options: `"Confirm" -> Automatic` (auto-resume suppresses the confirmation dialog)
### SourceVaultIssueScheduleResumeImpl[nb | issueId, opts]
Schedules a task that runs `SourceVaultIssueResumeImpl` at the recorded reset time (plus a margin). The schedule lives only while the kernel does (lost when Mathematica exits); its contents are stored in the record's `ResumeSchedule`, so after a restart press the button again to re-arm.
Options: `"At" -> Automatic` (record's `ImplBlock.ResetAt`), `"Delay" -> 60` (seconds)
### SourceVaultIssueVerifyFromNotebook[nb]
Runs the safety assessment, appends results to the notebook, and on pass inserts a `SourceVaultIssueVerifyCode` verification-template cell.
### SourceVaultIssueApplyFix[nb | issueId, opts]
Applies the patch produced by the Impl fix-generation workflow to real source code (the "apply fix" stage). Requires the safety gate to have passed. Flow: dry-run report → owner confirmation (FE shows a confirm dialog; headless requires `"Confirm" -> True`) → `<Launch>["patch","apply"]` (backup + verify + failure rollback is the generation side's contract) → post-apply diagnose → on success, auto-registers a resolution summary into the issue DB.
Options: `"Confirm" -> Automatic`, `"Slug" -> Automatic` (resolved from the record/notebook name).
### SourceVaultIssueCommitPackage[nb | issueId, opts]
Runs documentation update for the target package (`ClaudeUpdateDocumentation`, including api.md, synchronous mode) and then commits to GitHub via `PackageCommit[pkg, "DryRun" -> False]` (notebook button 「コミット」). External propagation, so owner confirmation is mandatory (FE = confirm dialog; headless = `"Confirm" -> True`). Docs freshness is gated via `$SourceVaultIssueDocsGateChecker` before committing. On success, metadata is recorded into the record's `PackageCommit`.
Options: `"Package" -> Automatic` (`Origin.Package`), `"Confirm" -> Automatic`
### SourceVaultIssueRecordImplResult[nb, info] → Association
Records the implementation workflow's outcome (final state / hard test gate `TestGate` / `Proven` / `CommitReady` and its reason) into the record's `ImplResult`. Called loosely-coupled from claudecode's spec-impl write-back; re-surfaced in the commit button's confirmation dialog and in `SourceVaultIssuesView`.
### SourceVaultIssueNotifyGitHub[nb | issueId, opts]
Posts a "fix completed" comment to the originating GitHub Issue, only when the issue's `Status` is `"Resolved"` AND a commit exists after the resolution timestamp (unresolved-in-GitHub fixes are not announced — reported as `NoCommitAfterResolution` otherwise). Idempotent (already-notified issues report `AlreadyNotified` unless `"Force" -> True`). External send requires owner confirmation (FE shows a body-preview dialog; headless requires `"Confirm" -> True`). Comment body auto-generated with local paths stripped, or overridden via `"Comment"`.
Options: `"Force" -> False`, `"Confirm" -> Automatic`, `"Comment" -> Automatic`.
### SourceVaultIssueNotifyGitHubAll[opts] → Association
Scans all issues and bulk-posts fix-completed comments to those that are Resolved with a post-resolution GitHub commit but no comment yet. When every issue of a same-origin group (parts decomposed from one GitHub Issue) is Resolved + notified, a single closing "all parts complete" comment is posted once at the end (idempotent via the `GroupNotified` record). External send requires one bulk confirmation (FE = a single plan-list dialog; headless = `"Confirm" -> True`). Issues without a post-resolution commit are skipped with a `CommitCheck` record (shown as 「コミット待ち」 in the View).
→ `<|"Checked", "Notified", "AwaitingCommit", "GroupCompleted", "Errors"|>`
Options: `"Confirm" -> Automatic`
### SourceVaultIssueAttachResolution[issueId, summary, opts] → Association
Appends a resolution summary to the record and sets `Status -> "Resolved"` (through the canonical transition, so the previous `Resolution` is preserved in `ResolutionHistory` on later reopen).
Options: `"SpecRef" -> Automatic`, `"TestResult" -> Automatic` (an empty/Automatic value preserves the existing stored value rather than clearing it — so `ApplyFix`'s auto-recorded values survive).
### SourceVaultIssueAttachResolution[nb]
Notebook-button variant: prompts for the summary via dialog. Submitting empty auto-generates a summary from the implementation trail (applied fix / safety assessment / verification attempts), preserving any existing summary. Canceling aborts without change.