### Overview

SourceVault_mailfeedback records user corrections to the derived mail fields (Priority / PrivacyLevel / Category / WorkRequest, plus sender importance) in an append-only ledger, applies each correction immediately as a hard per-mail override, and generalizes it into future classification via two layers:

L1 rule layer: deterministic address/recipient/subject-word rules. Instant, fully explainable, authored via Scope -> "Sender"/"Rule" or promoted from L2 evidence after explicit confirmation.
L2 hierarchical Bayes: Dirichlet-multinomial posterior over Category given features (sender/domain/recipient-list/subject terms), shrunk toward the parent level (sender -> domain -> global); Normal-Normal shrunk residuals for Priority/PrivacyLevel.

The LLM inference is the prior. L2 only overrides it when the posterior margin exceeds $SourceVaultMailFeedbackSwitchMargin; every move is recorded in Derived.FeedbackAdjustment for traceability.

Layering precedence: explicit user override > L1 rules > L2 posterior > LLM prior. maildb's deterministic recipient privacy floor still binds the learned privacy value; only an explicit human override may go below it (and that is logged).

Coupling: weak. maildb calls this module only through the seam $SourceVaultMailDerivedAdjuster when this package is loaded; nothing here is required for maildb to function. Content-minimized: the ledger stores addresses and subject-derived terms/numbers, never the mail body.

Why hierarchical Bayes instead of plain naive Bayes: the correction stream is tiny and lopsided (few events, most features seen once). The shrinkage prior (alpha/kappa) plus per-family averaging (not summing) of log-odds gives graceful behavior at n=1 and converges to the empirical rate as evidence accumulates.

## Corrections

### SourceVaultMailCorrect[recordId_String, updates_Association, opts]
Records a user correction of the derived fields of one mail and applies it immediately.
Also: SourceVaultMailCorrect[recordId_String, field_String, value, opts] (single-field form).
updates keys: "Priority" (0-1), "PrivacyLevel" (0-1), "Category" (token or Japanese label), "WorkRequest" (0-1), "Deadline" (ISO string or Missing).
Stores the values as a hard per-mail override (Derived.UserOverride) that survives re-inference and priority recomputation; rewrites the snapshot and sidecar index; appends a correction event (features + old/new values, no body) to the ledger.
→ Association
Options: "Scope" -> "Mail" (this mail only, plus L2 evidence; also accepts "Sender" to also create an L1 rule keyed on sender address, "Rule" to create an L1 rule from "Match", "None" for no learning), "Match" -> Automatic (explicit rule match spec, used with Scope->"Rule"), "Learn" -> True (feed the L2 model), "Reason" -> "" (free text, ledger only), "Persist" -> True, "Snapshot" -> Automatic (test seam), "Reapply" -> False (True also re-scores other mails of the same sender)
Returns <|Status, RecordId, Old, New, Scope, RuleId, Learned, Priority, PrivacyLevel, Category, Reapplied?|>.
例: SourceVaultMailCorrect["m123", <|"Category" -> "TaskRequest", "Priority" -> 0.8|>, "Scope" -> "Sender"]

### SourceVaultMailSetSenderWeight[recordIdOrEmail_String, weight_?NumericQ, opts]
Sets the importance of a sender (0-1, base term of the structural priority). Writes PriorityWeight on the linked identity entity if known (shared across that entity's mail), otherwise falls back to an L1 rule on the address.
→ Association
Options: "Reapply" -> True (re-scores already-stored mails of that sender), "Persist" -> True
Returns <|Status, Email, Weight, Via ("Entity"|"Rule"), Reapplied?|>.

### SourceVaultMailCorrections[opts]
Returns recorded correction events, newest first.
→ List of Association (or SourceVaultPrivateResult-wrapped, if privacy layer present)
Options: "RecordId" -> Automatic, "Field" -> Automatic, "Limit" -> 200

### SourceVaultMailFeedbackView[opts]
View version of SourceVaultMailCorrections: a Dataset of the correction ledger (date/field/old->new/scope/sender/subject).
→ Dataset
Options: same as SourceVaultMailCorrections ("RecordId" -> Automatic, "Field" -> Automatic, "Limit" -> 200)

## Rules (L1)

### SourceVaultMailAddRule[spec_Association, opts]
Registers an L1 rule. spec: <|"Match" -> <|"From", "Domain", "To", "Subject" -> {terms...}, "Category"|>, "Action" -> <|"SetCategory", "SetWorkRequest", "PriorityAdjust", "PriorityMin", "PrivacyAdjust", "PrivacyMin", "PriorityMax", "PrivacyMax"|>, "Note", "Enabled", "Source"|>. Every given Match key must hold (AND); "Subject" requires ALL listed terms. RuleId is a hash of Match+Action, so re-adding the same rule is idempotent.
→ Association (the stored rule)
Options: "Persist" -> True

### SourceVaultMailRules[] → List of Association
Returns the registered L1 rules.

### SourceVaultMailRemoveRule[ruleId_String] → Association
Deletes an L1 rule. Returns <|Status, RuleId, Count|>.

### SourceVaultMailSetRuleEnabled[ruleId_String, on:(True|False)] → Association
Enables/disables an L1 rule without deleting it. Returns <|Status, RuleId, Enabled|>.

### SourceVaultMailRulesView[] → notebook expression
Shows the L1 rules as a Dataset with enable/delete buttons (front end).

### SourceVaultMailRuleProposals[opts]
Returns L2 evidence strong and consistent enough to promote to a deterministic L1 rule (>= $SourceVaultMailFeedbackPromoteCount corrections on one feature agreeing on one category with >=80% consistency, excluding what an enabled rule already covers). Never auto-applied.
→ List of Association, sorted by Count descending
Options: "MinCount" -> Automatic (defaults to $SourceVaultMailFeedbackPromoteCount)
Each proposal: <|ProposalId, Feature, Family, Count, Category, Confidence, Match, Action, Note|>.

### SourceVaultMailAcceptRuleProposal[proposalOrId] → Association
Promotes a proposal from SourceVaultMailRuleProposals (an Association, or a ProposalId String) to an enabled L1 rule (Source -> "Promoted").

## Model (L2)

### SourceVaultMailFeedbackModel[] → Association
Returns the L2 model: per-feature category counts ("Cat"), per-feature residual sufficient statistics N/Sum for Priority and PrivacyLevel ("Res"), global category counts ("Global"), event count ("Events"). Derived data, always rebuildable from the ledger.

### SourceVaultMailFeedbackRebuildModel[] → Association
Rebuilds the L2 model from the correction ledger (source of truth). Use after editing/pruning the ledger or when the model file is lost.
Returns <|Status, Events, Features|>.

### SourceVaultMailFeedbackFeatures[recordIdOrRowOrSnapshot] → Association
Returns the feature list used by the learner: <|"From" -> {...}, "Dom" -> {...}, "To" -> {...}, "Subj" -> {...}|> (addresses lowercased; subject reduced to ASCII words, bracketed tags, and 2/3-grams of kanji/katakana runs, capped at $SourceVaultMailFeedbackMaxSubjectTerms).

### SourceVaultMailFeedbackAdjust[snapshot, derived_Association] → Association
Applies the feedback layers (L1 then L2) to a derived association and returns the adjusted one, with the audit trail in "FeedbackAdjustment" (<|RuleIds, CategoryFrom, CategoryTo, CategoryMargin, PriorityAdjust, PrivacyAdjust, Explain, At|>). This is the function maildb calls through $SourceVaultMailDerivedAdjuster; it is pure (no store writes) and never touches a field pinned by Derived.UserOverride. Returns derived unchanged if $SourceVaultMailFeedbackEnabled is False.

### SourceVaultMailFeedbackExplain[recordId_String] → Association
Explains how the current values of a mail were reached: LLM prior, matched L1 rules, L2 posterior per category, residual adjustments, and the user override.
Returns <|Status, RecordId, Category, Priority, PrivacyLevel, WorkRequest, PriorityComponents, UserOverride, FeedbackAdjustment, Features, CategoryScores, MatchedRules|> (privacy-wrapped if the privacy layer is present).

## Reapply

### SourceVaultMailFeedbackReapply[opts]
Re-scores mails already in the store with the CURRENT rules and model (no LLM call): recomputes structural priority from the stored WorkRequest/Category, then applies L1 + L2, then the user override.
→ Association
Options: "From" -> Automatic (only this sender address), "MBox" -> Automatic, "RecordIds" -> Automatic, "Persist" -> True, "DryRun" -> False
Returns <|Status, Scanned, Changed, Total, DryRun|>. Returns <|Status -> "Skipped", Reason -> "MaildbUnavailable"|> if maildb's snapshot API is not loaded.

## UI (front end)

### SourceVaultMailFeedbackPanel[recordId_String] → notebook expression
Correction control shown under the reply buttons of the mail window: importance and secrecy steppers, a category picker, a sender-importance picker, and the learning scope selector (this mail / this sender / word rule). Applying calls SourceVaultMailCorrect.

### SourceVaultMailFeedbackWindow[recordId_String] → notebook expression
Opens the correction panel of one mail in its own window, for use from list views.

## Storage

### SourceVaultMailFeedbackRoot[] → String
Directory holding the correction ledger, L1 rules, and L2 model (`<mail store root>/feedback`). Falls back to a temp directory if no mail store root is available.

## Configuration Variables

### $SourceVaultMailFeedbackEnabled
型: Boolean, 初期値: True
Switches the L1+L2 layers off globally. Explicit per-mail overrides keep working.

### $SourceVaultMailFeedbackAlpha
型: Real, 初期値: 3.0
Dirichlet shrinkage of the category posterior toward the parent level. Larger = more conservative.

### $SourceVaultMailFeedbackKappa
型: Real, 初期値: 2.0
Normal-Normal shrinkage of the Priority/PrivacyLevel residuals toward 0.

### $SourceVaultMailFeedbackSwitchMargin
型: Real, 初期値: 1.2
Log-odds margin the posterior must beat the LLM category by before L2 overrides it. Calibrated: with alpha=3, one correction moves only mails matching sender+recipient-list+subject terms (margin ~1.8); a second correction on the same sender is what flips that sender's unrelated mail (margin ~1.4).

### $SourceVaultMailFeedbackMaxAdjust
型: Real, 初期値: 0.4
Caps the absolute value of a learned Priority/PrivacyLevel adjustment, so no amount of evidence lets L2 take full control from the structural model.

### $SourceVaultMailFeedbackFamilyWeights
型: Association, 初期値: <|"From" -> 1.0, "Dom" -> 0.5, "To" -> 0.7, "Subj" -> 0.4|>
Weights the feature families. Within a family the matched features are averaged, never summed, so correlated subject n-grams cannot dominate.

### $SourceVaultMailFeedbackPromoteCount
型: Integer, 初期値: 3
Number of consistent corrections on one feature after which SourceVaultMailRuleProposals offers to promote it to a deterministic L1 rule.

### $SourceVaultMailFeedbackLLMPrior
型: Real, 初期値: 1.0
Log-odds bonus given to the category the LLM inferred.

### $SourceVaultMailFeedbackMaxSubjectTerms
型: Integer, 初期値: 32
Caps the subject terms extracted per mail. Terms are collected round-robin over kanji/katakana runs, most specific first, so the cap trims noise rather than the topic word.