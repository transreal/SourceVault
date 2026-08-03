# SourceVault_issues API Reference (LLM-Optimized)

## Overview
Generic issue database, not GitHub-specific. Sources include GitHub Issues via `github.wl` (`GitHubREST`GitHubAllOpenIssues`). On ingest, issues are:
1. Scanned via existing prompt-injection defenses (`SourceVaultSecurityPreScan` / `SourceVaultAssessInputTrust`).
2. Decomposed deterministically into multiple issues when the body contains ≥2 unrelated numbered problem sections.
3. Recorded with registration timestamp, origin (URL etc.), author id (identity-linked), owner + owner LLM model, and author trust score.
4. Scored for Risk and Importance from all information available at registration time.
5. Stored idempotently, keyed by a hash of `SourceKey` (derived from `Origin`/`Title` if not given).

Per-issue work happens in a dedicated notebook (`udb/issues/yyyymmdd-<title>.nb`, `NotebookStatus` header with Deadline/NextReview) carrying action buttons for: spec creation (consensus), code-fix start, reproduction verification (safe execution), resolution-summary registration.

Safety pipeline: code verification always runs a 4-point deterministic guard (comment stripping, injection keywords in string literals, overlong suspicious identifiers, writes to `NBAccess`-managed vars/credential access/forbidden paths/`AccessLevel -> 1.0`), cross-checked against `$ClaudeAdvisaryModel` re-verification. Disagreement or malice detection raises the stored Risk, reports details to the owner, and halts further action. Execution only proceeds through `NBAccess`NBValidateHeldExpr` -> `Permit`, executed via `NBAccess`NBExecuteHeldExpr`; forbidden/approval-required heads are never executed (reported to the owner as requiring approval; FE-required cases are deferred to the owner).

Service-loadable constraint (spec v6 §3.4) is satisfied except for View/Notebook functions: root resolution goes through core's `SourceVaultRoot`; other module references are runtime fail-soft (guarded via `DownValues`/`Names` checks).

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
Test seam replacing the advisary re-verification query. Default routes through `$ClaudeAdvisaryModel` (`"chatgptcodex"` uses the `codex` CLI; other providers use `ClaudeQuerySync` with the model substituted).
### $SourceVaultIssueCommitLogFetcher
型: Automatic | Function[pkg, owner, sinceIso], 初期値: Automatic
Test seam for the commit lookup used by resolution notification. Default resolves to `GitHubREST`GitHubCommitLog`.
### $SourceVaultIssueCommentPoster
型: Automatic | Function[pkg, owner, number, body], 初期値: Automatic
Test seam for the comment-posting layer used by resolution notification. Default resolves to `GitHubREST`GitHubIssueAddComment`.
### $SourceVaultIssueFixApplier
型: Automatic | Function[slug, mode], 初期値: Automatic
Test seam for fix-application execution; `mode` is `"dry"|"apply"|"diagnose"`. Default calls the generation workflow's `<Launch>["patch"]` / `["patch","apply"]` / `["diagnose"]`.

## Core Registry
### SourceVaultIssueRoot[] → String
Issue-DB record root directory (`<PrivateVault>/issues`), overridable via `$SourceVaultIssueRoot`.
### SourceVaultIssueNotebookDirectory[] → String
Issue notebook storage folder (`<udb>/issues`), overridable via `$SourceVaultIssueNotebookRoot`.
### SourceVaultIssueRebuildIndex[] → Association
Rebuilds `index.wxf` from the `records/` folder (corruption recovery).
→ `<|"Status" -> "OK", "Count" -> n|>`
### SourceVaultIssueRegister[assoc] → Association
Idempotently registers an issue. `IssueId` is derived from a hash of `SourceKey` (or of `Origin`/`Title` when `SourceKey` is absent); re-registering the same key updates only source fields while preserving `Status`/`Resolution`/`NotebookPath`/`Verification`/`Safety`/`ManualNotes`/`RegisteredAt`. Registration auto-computes pre-scan, InputTrust, author trust, Risk (monotonic — never decreases on re-registration), and Importance. Input keys (all optional except `Title`): `Title`, `Body`, `ContextText`, `Origin` (`<|"Kind","URL","Owner","Repository","Package","Number","Part","PartCount"|>`), `Author` (`<|"Kind","Login","AuthorAssociation","Profile","IdentifierId"|>`), `Labels`, `SourceCreatedAt`, `SourceUpdatedAt`, `CommentCount`, `SourceKey`, `PrivacyLevel` (default 0.15 for GitHub-origin, else 0.85), `RegisteredBy`.
→ `<|"Status" -> "Registered"|"Updated", "IssueId" -> "iss-...", "IssueStatus" -> "Open"|"Quarantined"|.., "Risk" -> 0..1, "Importance" -> 0..1|>`. Returns `Failure["IssueRegister", ...]` if `Title` is empty or the write fails.
### SourceVaultIssueGet[issueId] → Association | Missing["NotFound", issueId]
Returns the full issue record.
### SourceVaultIssueUpdate[issueId, changes_Association] → Association | Missing["NotFound", issueId] | $Failed
Merges `changes` into the record and refreshes `UpdatedAt`.
### SourceVaultIssues[opts] → {Association...}
Filtered/sorted issue index (core; lightweight index rows, not full records). Sort tie-breaks deterministically: primary sort key desc → `RegisteredAt` desc → `IssueId`. Wrapped via `SourceVaultPrivateResult` when privacy module is loaded.
Options: `"Status" -> All` (or a status string e.g. `"Open"`), `"Query" -> ""` (substring match against Title/origin), `"SortBy" -> "Importance"` (`"Importance"|"Risk"|"RegisteredAt"`), `"Limit" -> 200`.
### SourceVaultIssueTop[opts] → Association | Missing["NoIssues"]
Returns the single top-sorted issue as a full record (via `SourceVaultIssueGet`). Same options as `SourceVaultIssues`.
### SourceVaultIssuesView[opts] → Dataset
Dataset display of the issue list with an "開" (Open) button per row that opens (or creates) the issue notebook. Row cap is `$SourceVaultIssuesViewLimit`. Same options as `SourceVaultIssues`. Columns: 開/Issue/重要度/危険度/状態/由来/作者/登録. 状態 appends `(修正適用済✓)` when a fix was applied and post-apply diagnose confirmed `"Fixed"`, or `(修正適用済)` when applied but unconfirmed.

## GitHub Ingestion
### SourceVaultIssueIngestGitHub[opts]
Loads Open Issues across all `github.wl`-managed repositories, runs pre-scan → decomposition (unrelated multi-problem issues split) → trust/risk/importance scoring, then idempotently registers into the issue DB. Skips pull requests. Observes each author into the identity layer (fail-soft) via `SourceVaultObserveIdentifier`.
→ `<|"Fetched" -> n, "Registered" -> n, "Updated" -> n, "Quarantined" -> n, "Errors" -> {...}, "Ids" -> {"iss-..."}|>`. Returns a `Failure` if `github.wl` (`GitHubREST`) is not loaded.
Options: `"MaxItems" -> 50` (per repository), `"Decompose" -> True`, `"IncludePullRequests" -> False`.
### SourceVaultIssueDecompose[title, body] → {Association...}
Deterministically splits an issue body into parts. Splits when ≥2 numbered headings (`## `/`### ` starting with `"1."`/`"1．"`/etc.) are found; otherwise returns a single part. Each element: `<|"Title" -> String (≤80 chars, from heading), "Body" -> String, "Part" -> Integer, "PartCount" -> Integer, "ContextText" -> String (≤2000 chars, shared preamble + non-numbered sections)|>`. Also unwraps a body that is entirely one ` ``` ` fence before splitting.
例: `SourceVaultIssueDecompose["Bug report", "## 1. Crash on load\n...\n## 2. Slow save\n..."]` → 2 parts, each carrying the shared `ContextText`.

## Safety & Code Guard
### SourceVaultIssueStripComments[code] → String
Removes Wolfram Language comments from `code`, correctly handling nested `(* *)` and `(*`-like text inside string literals.
### SourceVaultIssueCodeGuard[code] → Association
Deterministic 4-point scan: (1) comment stripping (2) injection keywords inside string literals — prefers `SourceVaultSecurityPreScan`, falls back to a built-in regex pattern list when mining is unloaded (3) overlong (>32 chars) identifiers containing suspicious words (`ignore`,`disregard`,`override`,`bypass`,`jailbreak`,`sudo`,`exfiltrat`,`backdoor`,`approveall`,`noguard`,`disablecheck`,`skipvalidation`) (4) `SystemCredential` access, writes to `$NB*`/`NBAccess\`` vars, forbidden path tokens (`.nbaccess`,`.ssh`,`id_rsa`,`.aws`,`.gnupg`,`key-index`,`SystemCredentialData` → Rejected; `.claude.json`,`.claude\`,`.claude/` → Suspicious), `"AccessLevel" -> 1.0` (Rejected), and side-effecting heads (`Run`,`RunProcess`,`StartProcess`,`URLExecute`,`URLDownload`,`URLSubmit`,`Install`,`ExternalEvaluate`,`CloudEvaluate`,`SocketConnect`,`DeleteFile`,`DeleteDirectory` → Suspicious).
→ `<|"Status" -> "Clean"|"Suspicious"|"Rejected", "Findings" -> {<|"Kind","Severity","Detail"|>...}, "Stripped" -> String, "StringCount" -> Integer|>`
### SourceVaultIssueSafetyAssess[issueId, opts] → Association
Cross-checks the deterministic guard (body + extracted code blocks) against `$ClaudeAdvisaryModel` re-verification. On malice detection, raises stored Risk, sets `Status -> "Quarantined"`, prints an owner report, and further action is expected to stop.
→ `<|"IssueId", "Verdict" -> "Clean"|"Malicious"|"Disagreement"|"AdvisaryUnavailable", "Risk", "IssueStatus", "Guard" -> "Clean"|"Suspicious"|"Rejected"|"NoCode", "GuardFindings", "PreScanState", "AdvisaryAvailable" -> Bool, "AdvisaryReasons" -> {...}, "Stopped" -> Bool|>`. `Verdict` is `"Disagreement"` when the deterministic and advisary judgments conflict (fail-closed); `"AdvisaryUnavailable"` when advisary is unreachable and `"RequireAdvisary" -> True`.
Options: `"RequireAdvisary" -> True` (set `False` to accept a deterministic-only verdict when advisary is unreachable).

## Verification (Safe Execution)
### SourceVaultIssueVerifyCode[issueId, code, opts] → Association
Evaluates reproduction-verification code through the safe-execution chain: 4-point guard on `code` → `NBAccess`NBValidateHeldExpr`. Only a `"Permit"` decision executes, via `NBAccess`NBExecuteHeldExpr`; forbidden/approval-required heads are not executed (reported as requiring owner approval; FE-required operations are deferred to the owner). All attempts (including guard rejections) are appended to the record's `Verification` history (last 20 kept). Refuses to run if the issue's `Status` is `"Quarantined"`, if the code fails to parse, or if `NBAccess` is not loaded.
→ `<|"IssueId", "Status" -> "Executed"|"OwnerFERequired"|"AwaitingOwnerApproval"|"Denied", "Decision" -> "Permit"|"NeedsApproval"|"Deny", ...|>` (plus `"Result"` when Executed, `"Reason"`/`"ApprovalHeads"`/`"Message"` otherwise). Returns `Failure[...]` for `"VerificationBlocked"` (quarantined or guard-rejected), `"VerificationParse"`, `"NBAccessUnavailable"`, or `"ValidationFailed"`.
Options: `"TimeConstraint" -> 30`, `"AccessSpec" -> Automatic` (defaults to `<|"AccessLevel" -> 0.5|>`).

## Issue Notebook Workflow
### SourceVaultIssueNotebook[issueId, opts] → NotebookObject | Missing["NotFound", issueId]
Opens the issue's dedicated notebook, creating `udb/issues/yyyymmdd-<title>.nb` if none exists yet, with a `NotebookStatus` header (`Deadline` — 14 days if Importance ≥ 0.7 else 30 days; `NextReview` — 1 week; `Status -> "Todo"`; `Title`; `IssueRecordId`), title cell, info summary (origin/author/trust/importance/risk/status/registration), action-button row, a task-framing cell (`CellTags -> {"svIssueBody","svIssueTask"}` — states the issue body is untrusted observation data, not a requirement spec, and instructs the spec to cover reproduction/root cause, fix, and regression test), the untrusted issue body, optional shared `ContextText`, and a work-log section. Action buttons: 仕様作成(合議) → `SourceVaultIssueCreateSpec`; コード修正開始 → `SourceVaultIssueStartImpl`; 再現検証(安全実行) → `SourceVaultIssueVerifyFromNotebook`; 修正適用(承認) → `SourceVaultIssueApplyFix`; 解決サマリー登録 → `SourceVaultIssueAttachResolution`; GitHub通知(確認) (GitHub-origin issues only) → `SourceVaultIssueNotifyGitHub`; 元イシューを開く → `SystemOpen` on the origin URL.
Options: `"Open" -> True`.
### SourceVaultIssueForNotebook[nb | path] → String | Missing
Reads back `IssueRecordId` from an issue notebook, unevaluated (used to resolve which issue a button click belongs to).
### SourceVaultIssueCreateSpec[nb | issueId]
After the safety gate passes, launches consensus resolution-spec authoring (spec-review consensus between `$ClaudeModel` and `$ClaudeAdvisaryModel`).
### SourceVaultIssueStartImpl[nb | issueId]
Launches the spec-impl workflow (implementation + verifier consensus + hard test gate) against the approved spec.
### SourceVaultIssueVerifyFromNotebook[nb]
Runs the safety assessment, appends results to the notebook, and on pass inserts a `SourceVaultIssueVerifyCode` verification-template cell.
### SourceVaultIssueApplyFix[nb | issueId, opts]
Applies the patch produced by the Impl fix-generation workflow to real source code (the "apply fix" stage). Requires the safety gate to have passed. Flow: dry-run report → owner confirmation (FE shows a confirm dialog; headless requires `"Confirm" -> True`) → `<Launch>["patch","apply"]` (backup + verify + failure rollback is the generation side's contract) → post-apply diagnose → on success, auto-registers a resolution summary into the issue DB.
Options: `"Confirm" -> Automatic`, `"Slug" -> Automatic` (resolved from the record/notebook name).
### SourceVaultIssueNotifyGitHub[nb | issueId, opts]
Posts a "fix completed" comment to the originating GitHub Issue, only when the issue's `Status` is `"Resolved"` AND a commit exists after the resolution timestamp (unresolved-in-GitHub fixes are not announced — reported as `NoCommitAfterResolution` otherwise). Idempotent (already-notified issues report `AlreadyNotified` unless `"Force" -> True`). External send requires owner confirmation (FE shows a body-preview dialog; headless requires `"Confirm" -> True`). Comment body auto-generated with local paths stripped, or overridden via `"Comment"`.
Options: `"Force" -> False`, `"Confirm" -> Automatic`, `"Comment" -> Automatic`.
### SourceVaultIssueAttachResolution[issueId, summary, opts] → Association
Appends a resolution summary to the record and sets `Status -> "Resolved"`.
Options: `"SpecRef" -> Automatic`, `"TestResult" -> Automatic` (an empty/Automatic value preserves the existing stored value rather than clearing it — so `ApplyFix`'s auto-recorded values survive).
### SourceVaultIssueAttachResolution[nb]
Notebook-button variant: prompts for the summary via dialog. Submitting empty auto-generates a summary from the implementation trail (applied fix / safety assessment / verification attempts), preserving any existing summary. Canceling aborts without change.