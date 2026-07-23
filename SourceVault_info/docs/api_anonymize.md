## 概要

Implements de-identification primitives for SourceVault (spec `sourcevault_anonymization_spec_v1_0.md` v1.0):
- L0a: canonical encoding v1, KeyRing over NBAccess MAC KeyRefs, collision-resistant ID expressions (EntityID / SourceObjectID / SourceUnitID / DerivedUnitID), role tokens (Subject/Item/Job/ResultSlot) + CSPRNG ReleaseHandle.
- G0a: schema-only `SourceVaultAnonymizationPlan` (never reads document bodies).
- L0b: `LineageManifest` node/edge graph + self-validator.
- G0b: `DeclassificationGrant` request/approve/verify/consume-use lifecycle.
- L1: `PseudonymMap` (immutable MapVersion snapshots + MapHead CAS pointer).
- L2a: content-addressed `DerivedArtifact` builder + `ArtifactBinding` + origin reverse-lookup index.
- L2b: `DeclassificationPublication` record/head + two-phase publish + revoke.
- L3a/L3b: `EvaluationPlanManifest` builder + quarantined ingress, `EvaluationResultManifest`, `AnnotationContent`/`AnnotationBinding`, join preview + atomic write-back.
- A0: `AnonymizationPolicy` registry.
- A1-A3: `SourceVaultAnonymize` end-to-end execution under an owner grant.
- A6: image/PDF-page redaction (raster black-out + re-encode) and an independent (V5) redaction-completeness verifier.
- A7: MCP-facing low-PL projection getter (`SourceVaultAnonymizeGetByHandle`) and the unlisted-ObjectClass predicate.
- G1: `CompositionPolicy` (aggregate/join PrivacyLevel) + append-only `ExposureLedger` (record/guard).
- G2: `EvaluationDistributionPlan` conformance check.
- G1c: SystemDoctor-facing sanitized exposure probe, owner-only detailed diagnostic, SIEM registration, and escalation.
- U0: `ReleaseHandle` mapping/revoke/rotate.

Design principles (spec §2):
- P-A3 fail-closed: undecidable/missing-key/unknown-type inputs return `$Failed`/`Failure`, never a guess.
- P-A7 durable-audit-first: publish/lineage-affecting steps refuse to proceed if the audit event can't be durably appended.
- P-A13 identity independence: `SourceUnitID` embeds `SourceObjectID` so two different logical objects with identical content never collide; order-independent.
- P-A15 owner-authorized execution: `SourceVaultAnonymize` (the high-PL-reading Execute) requires a verified `DeclassificationGrant`; without one it fails closed with `NeedsOwnerApproval` and never touches the body. It is also registered in `NBAccess`$NBApprovalHeads` alongside `SourceVaultApproveDeclassification`, so agent/LLM-driven calls route through Hold → owner Approve UI.
- P-A19 record binding: `Origins` binds ref+digest+role in one record, then canonical-sorts + digests (no parallel arrays).

Private helpers live in ``SourceVault`AnonymizePrivate`` with an `iSVA` prefix and are not part of the public API.

## Constants

### $SourceVaultAnonymizeEngineVersion
型: String, 初期値: `"anonymize-1"`
Pipeline implementation version identifier (cache-identity component).

### $SourceVaultAnonymizeCanonicalizationVersion
型: Integer, 初期値: `1`
CanonicalEncode rule version; baked into every ID.

### $SourceVaultAnonymizeLineageSchemaVersion
型: Integer, 初期値: `2`
LineageManifest schema version; baked into `SourceUnitID`.

### $SourceVaultAnonymizeIdentityKeyRef
型: String, 初期値: `"SourceVault:anonid:identity:v1"`
KeyRef (namespaceKey) for the EntityID/SourceObjectID HMAC key.

### $SourceVaultAnonymizeLineageKeyRef
型: String, 初期値: `"SourceVault:anonid:lineage:v1"`
KeyRef (lineageKey) for the SourceUnitID/DerivedUnitID HMAC key.

### $SourceVaultAnonymizeKeyId
型: String, 初期値: `"idkey-1"`
Current anonymization ID key generation identifier; baked into every ID.

### $SourceVaultAnonymizeTenantID
型: String, 初期値: `"default"` (set only if not already bound)
VaultOrTenantID — the ID namespace.

### $SourceVaultAnonymizeFingerprintPinPath
型: String | Automatic, 初期値: `Automatic`
Explicit override path for the key-fingerprint pin file (test use). `Automatic` resolves to `PrivateVault/config/anonymize-key-fingerprints.json` via `SourceVaultRoot["PrivateVault"]`.

### $SourceVaultAnonymizeAllowVolatileKeys
型: Boolean, 初期値: `False`
When `False`, key generation/ID generation is refused on volatile key backends (`NBAccess\`$NBCredentialBackend =!= "SystemCredential"`), since IDs minted on volatile keys become unreproducible after a kernel restart (fail-closed). `True` is test-only, meant to pair with a temporary pin path.

## KeyRing

### SourceVaultAnonymizeInitializeKeys[] → Association
Idempotently generates the anonymization MAC keys (identity/lineage/grant KeyRefs) via NBAccess. Never destroys existing keys, never returns key material.
Fails (`Status->"Failed"`) with `Reason->"NBAccessCryptoUnavailable"` if NBAccess crypto is absent, or `Reason->"VolatileKeyBackend"` if the backend is volatile and `$SourceVaultAnonymizeAllowVolatileKeys` is `False`.
On success: `<|Status->"Initialized"|"AlreadyInitialized", CreatedKeyRefs, ExistingKeyRefs, KeyId, KeyMaterialReturned->False|>`.

### SourceVaultAnonymizeKeyStatus[] → Association
Returns existence + Fingerprint (no key material) per KeyRef, keyed by KeyRef string: `<|Exists, Purpose, KeyId, CanonicalizationVersion, Fingerprint|>`. Used for cross-node fingerprint checks (spec §5.5.1).

### SourceVaultAnonymizeVerifyKeyFingerprints[] → Association
Verifies current key fingerprints against the shared pin file (spec §5.5.1 / AC-053). First run pins current fingerprints (`Status->"Pinned"`); a match returns `Status->"OK"` (with `NewlyPinnedKeyRefs` for any newly-added keys, e.g. the grant key); a mismatch returns `Status->"Failed", Reason->"KeyFingerprintMismatch"` and blocks further ID generation (guards against a volatile-backend kernel, e.g. MCP, silently minting IDs under a different key). Also returns `Status->"Failed"` for `"VolatileKeyBackend"`, `"KeysMissing"`, or `"PinUnreadable"`, or `Status->"Skipped"` for `"PinStoreUnavailable"`/`"PinWriteFailed"`.

## Canonicalization

### SourceVaultAnonymizeCanonicalEncode[expr] → String | $Failed
Deterministic canonical encoding v1. Association keys sorted by strict codepoint order; String is NFC-normalized + JSON-style escaped; accepts Integer/True/False/Null/ByteArray/List/Association. `Real` and any other type are rejected fail-closed (`$Failed`, with `::badtype` message) so IDs never depend on a non-deterministic type.

### SourceVaultAnonymizeCanonicalDigest[expr] → String (64-hex) | $Failed
SHA-256 of the UTF-8 bytes of `CanonicalEncode[expr]`, as 64 lowercase hex chars. `$Failed` if not encodable.

## ID Expressions (spec §5.5.2)

All ID functions take an `Association` spec, require specific String-valued keys, and fail-closed (`$Failed`) on any missing/non-string required key or unavailable key material. Form: `prefix:hex40` (160-bit truncated HMAC), namespaced by `$SourceVaultAnonymizeTenantID`.

### SourceVaultAnonymizeEntityID[spec] → "ent:hex" | $Failed
Required keys: `Institution`, `CanonicalID`. Stable entity identity via namespaced HMAC (never a plain hash of a raw ID).

### SourceVaultAnonymizeSourceObjectID[spec] → "sobj:hex" | $Failed
Required keys: `SourceSystem`, `PrimaryKey`. Stable logical-object ID. If no authoritative key exists, pass the ingest-time UUID as `PrimaryKey` (spec §5.5.2).

### SourceVaultAnonymizeSourceUnitID[spec] → "sunit:hex" | $Failed
Required keys: `SourceObjectID`, `SourceVersionID`, `SourceUnitKind`, `CanonicalLocatorDigest`, `SourceContentDigest`. `VaultOrTenantID`/`CanonicalizationVersion`/`LineageSchemaVersion`/`KeyId` are auto-attached. Never collides across different logical objects with identical content (P-A13).

### SourceVaultAnonymizeDerivedUnitID[spec] → "dunit:hex" | $Failed
Required keys: `ParentUnitIDs` (non-empty list of strings, sorted internally so order doesn't matter), `RelationType`, `PolicyDigest`, `TransformDigest`, `DerivedLocatorDigest`, `DerivedContentDigest`, `OutputOrdinalOrRole`.

## Tokens / ReleaseHandle (spec §5.5.3, §5.10)

CSPRNG-backed (via `GenerateSymmetricKey`, never `RandomInteger`).

### SourceVaultAnonymizeGenerateToken[type] → String | $Failed
`type`: `"Subject"` → `"S-XXXXXX-C"`, `"Item"` → `"I-..."`, `"Job"` → `"J-..."`, `"ResultSlot"` → `"R-..."`. Crockford base32, 6-char body + 1-char checksum. Non-semantic (doesn't leak source ID, count, or order). `$Failed` for unknown `type`.

### SourceVaultAnonymizeTokenValidQ[token] → Boolean
Validates token shape and checksum (catches transcription errors). `False` for non-string input.

### SourceVaultAnonymizeGenerateReleaseHandle[] → "sv://release/<64hex>" | $Failed
Low-PL-side bearer retrieval handle, 256-bit CSPRNG. Never derived from content (spec §5.10).

### SourceVaultAnonymizeReleaseHandleValidQ[h] → Boolean
Validates ReleaseHandle shape (`sv://release/` + 64 lowercase hex chars). `False` for non-string input.

## LineageManifest (L0b, spec §5.4, §5.7, §9.2)

### SourceVaultAnonymizeBuildLineageManifest[spec]
Builds a node/edge graph `LineageManifest`.
→ Association (`Status->"OK"` + manifest fields) | `<|Status->"Failed", Reason, ...|>`
`spec` keys: `Origins` (non-empty list of Association records, required), `PolicyRef`, `MapRef`, `SourceNodes`, `DerivedNodes`, `Edges` (each gets `InputSetDigest`/`OutputSetDigest`/`EdgeID` computed), `Partitions` (each gets `MemberSetDigest`/`PartitionID` computed), `Invariants` (merged with defaults `DuplicatePolicy->"Reject"`, `OrderingIsIdentity->False`, expected node counts). Computes `OriginSetDigest`, `LineageSetID`, `ManifestDigest`, then self-validates via `SourceVaultValidateLineage` — self-validation failure returns `Status->"Failed", Reason->"SelfValidationFailed"`. N:1/N:M aggregation is represented canonically via `Edges[[..,"Cardinality"]]` (no nested duplication).
Reason values: `"MalformedSpec"`, `"NonCanonicalContent"`, `"SelfValidationFailed"`.

### SourceVaultValidateLineage[manifest] → Association
Machine-verifies graph/partition/token/digest consistency (spec §9.2 L1-L5 structural checks / AC-040/044/046). Returns `<|Status->"OK"|"Failed", Findings->{<|Check,Detail|>...}, Counts-><|SourceNodes,DerivedNodes,Edges,Partitions|>|>`. Findings report only unit IDs/counts — never locators, Identity, or other PII.
Findings `Check` values include: `SchemaVersion`, `MissingKey`, `BadSourceUnitIDPrefix`, `BadDerivedUnitIDPrefix`, `DuplicateUnitID`, `InvalidItemToken`, `DuplicateItemToken`, `UnknownUnitInEdge`, `EdgeTargetNotDerived`, `BadCardinality`, `CardinalityMismatch`, `EdgeSetDigestMismatch`, `UnknownUnitInPartition`, `MemberSetDigestMismatch`, `IncompletePartitionCoverage`, `DuplicatePartitionMember`, `UncoveredSourceUnit`, `NodeCountMismatch`, `OriginSetDigestMismatch`, `ManifestDigestMismatch`.

## Schema-only AnonymizationPlan (G0a, spec §7.1)

Never reads document bodies/blobs/OCR/LLM/pseudonym maps — only parses ref strings and reads the snapshot privacy sidecar (`SourceVaultSnapshotPrivacyLevel`, a file separate from body content).

### SourceVaultAnonymizationPlan[origRef, opts]
Also accepts a `List` of ref strings: `SourceVaultAnonymizationPlan[origRefs_List, opts]`.
Builds a schema-only anonymization plan for one or more origin refs (`sv://` URI / snapshot ref / `blob:sha256:...`).
→ Association: `<|Status->"OK", Type->"AnonymizationPlan", SchemaVersion->1, SchemaOnly->True, Origins (record-bound: OriginRef/RefForm/ObjectClass/Role/PrivacyLevel/PrivacyLevelSource — Role is hardcoded `"origin"` for every entry, never derived from list position, so the OriginSetDigest stays order-independent), OriginSetDigest, UnitCountRange->"SchemaOnly", TargetLevelChoices->{"0.45","0.2"}, SinkChoices->{"CloudLLM","CloudLLM-LowTrust"}, CandidatePolicies (registered PolicyId keys), CandidateProfiles->{}, CanonicalizationVersion, EngineVersion, PlanDigest, CreatedAtUTC, PlanRef (if Save->True)|>`
On failure: `<|Status->"Failed", Reason->"EmptyOrNonStringOrigins"|"InvalidOriginRef", Invalid->{...}|>`.
Options: `"Save" -> False` (when `True`, persists the plan as an `AnonymizationPlan` snapshot via `SourceVaultSaveImmutableSnapshot` and includes `PlanRef`; save failure leaves `PlanRef -> $Failed`).
Ref forms recognized: `snapshot:<Class>:<hex>`, `sv://snapshot/<Class>/<hex>`, `sv://hash/sha256/<64hex>`, `blob:sha256:<64hex>`, generic `sv://<namespace>/<id...>`. Unrecognized/malformed refs make that origin invalid, and the whole plan fails.
Unrecognized privacy-level lookups (any ref not a `SnapshotRef`, or sidecar unavailable) fail-closed to `PrivacyLevel->0.85, PrivacyLevelSource->"FailClosedDefault"`.

## DeclassificationGrant (G0b, spec §5.13, §8.1 段 0a, §10)

Issuance requires an owner interactive FrontEnd session (`Head[$FrontEnd]===FrontEndObject`, non-cloud) — agents/LLMs cannot self-approve.

### SourceVaultRequestDeclassification[plan, opts]
Builds a `DeclassificationRequest` from a schema-only `AnonymizationPlan` (never reads body content).
→ Association: `<|ObjectClass->"DeclassificationRequest", SchemaVersion->1, Status->"OK", RequestID, PlanDigest, Origins (PrivacyLevel/-Source dropped), OriginSetDigest, TargetLevel, Purpose, IntendedSink, PolicyRef, PolicyDigest, PublishMode, MaxExecuteUses, TTLSeconds, CreatedAtUTC|>`
On failure: `<|Status->"Failed", Reason->"InvalidPlan"|"TargetLevelNotChosen"|"PurposeNotChosen"|"IntendedSinkNotChosen", ...|>` — the owner must make an exact, explicit choice; the system never silently defaults `TargetLevel`/`Purpose`/`IntendedSink`.
Options: `"TargetLevel" -> None` (must be a member of `plan`'s `TargetLevelChoices`), `"Purpose" -> None` (required String), `"IntendedSink" -> None` (required `<|"Class"->...|>`), `"PolicyRef" -> "unspecified"`, `"PolicyDigest" -> "unspecified"` (both flow verbatim into the request and are later exact-matched by `SourceVaultVerifyDeclassificationGrant`), `"PublishMode" -> "StageForOwnerReview"` (alt: `"PublishIfVerified"`), `"MaxExecuteUses" -> 1`, `"TTLSeconds" -> 86400`.

### SourceVaultApproveDeclassification[request] → Association
Owner-interactive-only approval. Issues and MAC-signs a `DeclassificationGrant` binding the exact origin/policy/TargetLevel/purpose/sink/expiry/uses.
→ `<|ObjectClass->"DeclassificationGrant", SchemaVersion->1, GrantID, OwnerPrincipal, ApprovalReceipt, PlanDigest, Origins, OriginSetDigest, ExactTargetLevel, Purpose, IntendedSink, PolicyRef, PolicyDigest, PublishMode, MaxUses-><|Execute->n|>, ExpiresAtUnix, Nonce, KeyId, CanonicalizationVersion, GrantDigest, OwnerMAC, Status->"OK"|>`
Failure reasons: `"InvalidRequest"`, `"NonInteractiveApprovalRefused"`, `"VolatileKeyBackend"`, `"GrantKeyMissing"`, `"KeyFingerprintGateFailed"`, `"RandomUnavailable"`, `"NonCanonicalGrant"`, `"MACFailed"`.

### SourceVaultVerifyDeclassificationGrant[grant, request] → Association
Verifies grant MAC/digest/expiry and exact match of `OriginSetDigest`/`TargetLevel`/`Purpose`/`IntendedSink.Class`/`PolicyDigest` against the execution request (spec 段 0a: never reads body content).
Success: `<|Status->"OK", GrantID, PublishMode|>`.
Failure reasons: `"NotAGrant"`, `"GrantMACInvalid"`, `"GrantExpired"`, `"DeclassificationTargetMismatch"` (includes `GrantLevel`/`RequestedLevel`), `"GrantRequestMismatch"` (includes `Field`).

### SourceVaultConsumeDeclassificationGrantUse[grant, operationId] → Association
Consumes an Execute use as a lease (create-only file). Re-calling with the same `operationId` idempotently resumes (crash retry: `Resumed->True`); a different `operationId` past `MaxUses.Execute` fails (spec GrantExecutionLease / AC-088).
Success: `<|Status->"OK", Resumed->True|False, GrantID, OperationID|>`.
Failure reasons: `"KeyFingerprintGateFailed"`, `"GrantMACInvalid"`, `"GrantExpired"`, `"LeaseStoreUnavailable"`, `"GrantUsesExhausted"` (includes `MaxUses`), `"LeaseWriteFailed"`.

## PseudonymMap (L1, spec §5.3)

MapVersion snapshots are immutable (PL 1.0 sidecar-watermarked); MapHead is a lock + compare-and-swap file pointer, so concurrent assignment retries safely (no double-issuance, AC-028). Downstream artifacts/annotations pin an exact MapRef so the reverse mapping stays fixed even as MapHead advances (AC-029).

### SourceVaultAnonymizePseudonymMapId[spec] → "map:hex" | $Failed
Required keys: `EntityClass`, `MapScope`. Independent numbering per distinct scope (prevents unintended cross-course linkage).

### SourceVaultAnonymizeAssignSubjectTokens[mapSpec, identities]
Appends entities to the map and assigns `SubjectToken`s (lock → reload head → merge → uniqueness check → save new immutable MapVersion (PL 1.0) → MapHead CAS; retries up to 3 times on conflict).
→ `<|Status->"OK", MapId, MapRef, MapVersion, Assignments, NewVersion->True|False|>` (`NewVersion->False` when the batch changed nothing — no new MapVersion is written, fully idempotent)
`identities` elements: `<|"Institution", "CanonicalID", "Identity"-><|...|>, "KnownStrings"->{...}|>`. The same entity (by `EntityID`) always returns its existing `SubjectToken` (stable numbering); `KnownStrings` are expanded deterministically (NFC, full-width→half-width, whitespace-stripped variants) and merged.
Failure reasons: `"InvalidMapSpec"`, `"CoreUnavailable"`, `"EmptyIdentities"`, `"EntityIDFailed"`, `"TokenGenerationFailed"`, `"UniquenessViolation"`, `"LockUnavailable"`, `"CASRetriesExhausted"`, `"SnapshotSaveFailed"`.

### SourceVaultAnonymizePseudonymMap[mapIdOrRef] → Association
Reads the pseudonym map. Pass a `MapId` (`"map:..."`) for the latest MapHead version, or an exact snapshot ref for that exact version (content immutable even as head advances, AC-029). Returns the map Association with `MapRef` appended.
Failure reasons: `"MapHeadNotFound"`, `"MapVersionUnreadable"`.

## ArtifactBinding + Reverse Lookup (L2a, spec §5.6)

Anonymized artifacts are saved as content-addressed `DerivedArtifact` snapshots (identical content → identical ref; no volatile fields such as `CreatedAtUTC`/`Status` allowed in the body — the builder is `Private`/internal, used only by `SourceVaultAnonymize`/publish). `ArtifactBinding` is an immutable PL 1.0 snapshot that pins one direction only: binding → artifact/origins/policy/map/lineage. The origin reverse-lookup index is keyed by a keyed-HMAC digest of the canonical origin ref, so only a principal who already knows the origin ref can derive the lookup key (consistent with unlisted discoverability).

### SourceVaultAnonymizedVariants[origRefOrURI] → Association
The only listing path for a given origin's anonymized variants. Looks up the origin's reverse-index file, loads each bound `ArtifactBinding`, and verifies its `BindingDigest` before including it.
→ `<|Status->"OK", OriginRef, Variants->{<|BindingRef, ArtifactRef, PolicyRef, MapRef, LineageManifestRef|>...}|>` | `<|Status->"Failed", Reason->"BindingIndexUnavailable"|"DigestUnavailable"|>`
Tampered/unreadable bindings are silently dropped from `Variants` rather than failing the whole call. Read carries a PL 1.0 privacy note.

## Publication (L2b, spec §5.10, §8.2, §10.4)

Publication state's single source of truth is `PublicationHead` (per-artifact file pointer, CAS-updated) → `DeclassificationPublication` record. The internal publish sequence (used by `SourceVaultAnonymize`) is: staged verification → durable `AnonymizePublicationPrepared` event → head CAS → PL sidecar set → best-effort `AnonymizePublicationCompleted` event → ReleaseHandle issuance. Whatever point a crash occurs at, the observable state is either "not published" or "published + high-PL sidecar" (safe side); re-running resumes idempotently. Staged/Draft artifacts are structurally invisible — no head exists for them yet (AC-048).

### SourceVaultAnonymizePublicationStatus[artifactRef] → Association
Resolves and integrity-checks the publication head for an artifact.
→ `<|Status->"OK", State->"Published"|"Revoked", PublicationRef, TargetLevel, Discoverability->"Unlisted", ArtifactRef|>`
No head yet: `<|Status->"NotPublished", ArtifactRef|>`. Record/artifact digest mismatch: `<|Status->"IntegrityFailed", ArtifactRef|>`.

### SourceVaultRevokeDeclassifiedArtifact[artifactRef, reason] → Association
Owner-interactive-only mutation. Writes a new `DeclassificationPublication` record (`State->"Revoked"`, `RevocationEpoch` incremented) via head CAS, revokes every `ReleaseHandle` for the artifact, and resets the PL sidecar to the fail-closed default (`0.85`). Copies already released to an external party cannot be recalled — this is recorded verbatim in the `AnonymizePublicationRevoked` audit event.
→ `<|Status->"OK", PublicationRef, State->"Revoked", ArtifactRef|>`
Failure reasons: `"NonInteractiveMutationRefused"`, `"NotPublished"`, `"RecordUnreadable"`, `"RecordSaveFailed"`, `"HeadCASConflict"`.

## Evaluation & Annotations (L3a/L3b, spec §5.9, §5.11, §13)

Grading results are attributed via the `EvaluationPlanManifest`'s `JobID -> TargetItemTokens` binding, computed at plan-build time — a token an inbound response claims for itself is never trusted (out-of-band binding). Any received cloud-transport payload should first land in a quarantined `CloudTransportResult` snapshot at protected-minimum PL via `SourceVaultAnonymizeQuarantineIngress`, before parsing untrusted responses.

### SourceVaultAnonymizeBuildEvaluationPlan[spec]
Builds and saves (PL 1.0) the pre-send `EvaluationPlanManifest`: 1 unit = 1 job = 1 examinee. Fixes the `JobID -> TargetItemTokens` out-of-band binding that result attribution later trusts.
→ `<|Status->"OK", PlanRef, Jobs->{<|JobID, JobToken, AttemptID, RequestBindingNonceDigest, EvaluationUnitID, TargetItemTokens, SubjectToken, ExpectedResultCardinality|>...}, EvaluationBatchID|>`
`spec` keys: `TargetArtifactRef` (String, required), `ArtifactBindingRef` (String, required), `Units` (non-empty list, required) — each unit: `ItemTokens` (non-empty list of strings, required), `AttemptID -> "attempt-1"`, `EvaluationUnitID` (default derived from a digest of the sorted `ItemTokens`), `SubjectToken -> "unspecified"`, `ExpectedResultCardinality -> 1`; top-level `RequestDigest`/`RubricDigest`/`DistributionPlanRef -> "unspecified"`.
Failure reasons: `"MissingPlanFields"`, `"BadUnitTokens"`, `"PlanSaveFailed"`.

### SourceVaultAnonymizeQuarantineIngress[planRef, jobId, raw] → Association
Saves a raw provider response verbatim as a `CloudTransportResult` snapshot at protected-minimum PL (1.0), from the instant it is received (AC-086) — before any parsing of untrusted content.
→ `<|Status->"OK", QuarantineRef|>` | `<|Status->"Failed", Reason->"QuarantineSaveFailed"|>`

### SourceVaultCreateDerivedAnnotations[artifactRef, envelope] → Association
Validates the result envelope's `JobID`s against the Plan's job set (exact match required — no partial batches), builds an `EvaluationResultManifest`, an `AnnotationContent` snapshot (saved at `ProtectedMinimum` PL) whose `Items` carry `ItemToken`/`SubjectToken`/`Score`/`Reason` resolved from the Plan (not the response), and an `AnnotationBinding` (PL 1.0) pinning content ↔ artifact ↔ plan ↔ result ↔ rubric digest.
→ `<|Status->"OK", AnnotationBindingRef, AnnotationContentRef, ResultManifestRef, ItemCount|>`
`envelope`: `<|"PlanRef", "Results"->{<|"JobID","Score","Reason"|>...}, "ProtectedMinimum"->1.0, "AnnotationType"->"Grade"|>`.
Failure reasons: `"MalformedEnvelope"`, `"PlanUnreadable"`, `"ArtifactMismatch"`, `"JobSetMismatch"` (includes `Missing`/`Unknown`/`Duplicate` counts — unknown/missing/duplicate JobIDs fail the whole batch, AC-026/033), `"ResultManifestSaveFailed"`, `"ContentSaveFailed"`, `"NonCanonicalBinding"`, `"BindingSaveFailed"`.

### SourceVaultValidateDerivedJoin[annotationBindingRef] → Association
Join preview: verifies the `AnnotationBinding` digest, pins to the referenced `LineageManifest`/`PseudonymMap`/`ArtifactBinding`, and resolves every `ItemToken` along `ItemToken -> DerivedUnit -> SubjectToken -> Entity`. Reports counts only — never PII.
→ `<|Status->"OK", AllMatched, Matched, Unknown, Duplicate, SetMismatch, UnresolvedSubject|>`
Failure reasons: `"AnnotationBindingUnreadable"`, `"AnnotationBindingTampered"`, `"ContentUnreadable"`, `"LineageMismatch"`, `"LineageUnreadable"`, `"MapUnreadable"`.

### SourceVaultAttachDerivedResults[annotationBindingRef] → Association
Re-runs the join preview; only if `AllMatched` does it join scores to real Identity and return rows (PL 1.0-watermarked). Any single mismatch fails the whole call with zero rows (no partial write-back, AC-025). Takes no origin/map override arguments — everything resolves from the annotation's own reference chain.
→ `<|Status->"OK", Rows->{<|ItemToken, SubjectToken, EntityID, Identity, DisplayLabel, DerivedUnitID, Score, Reason, Attempt|>...}, RowCount|>`
Failure: `<|Status->"Failed", Reason->"JoinPreviewFailed", Preview|>`, or any `SourceVaultValidateDerivedJoin` failure reason.

## Anonymization Policy Registry (A0, spec §5.1, §6.1)

### SourceVaultRegisterAnonymizationPolicy[policy] → Association
Saves `policy` as an immutable `AnonymizationPolicy` snapshot (PL sidecar = `PolicyPrivacyLevel`) and records `PolicyId -> ref` in a local JSON registry file. A revised policy gets a new digest (= a distinct variant); the registry is updated to point at the latest.
Required `policy` keys: `PolicyId` (String), `Tiers` (non-empty Association keyed by TargetLevel string, each tier holding e.g. `FieldRules`, `DefaultFieldRule`, `TextRules`). Optional: `"PolicyPrivacyLevel" -> 0.5`.
→ `<|Status->"OK", PolicyId, PolicyRef, PolicyDigest|>`
Failure reasons: `"MalformedPolicy"`, `"PolicySaveFailed"`, `"RegistryUnavailable"`.

### SourceVaultAnonymizationPolicies[] → Association
Returns the registry map `PolicyId -> PolicyRef` (empty `<||>` if none registered or the registry file is unavailable).

### SourceVaultAnonymizationPolicy[idOrRef] → Association
Resolves a policy, either by a registered `PolicyId` or by passing a direct `snapshot:...`/`sv://...` ref, and loads it.
→ policy fields + `<|Status->"OK", PolicyRef, PolicyDigest|>`
Failure reasons: `"PolicyNotRegistered"`, `"PolicyUnreadable"`.

## SourceVaultAnonymize (A1-A3, spec §8)

The Execute head: the only public function in this module that reads document bodies, and only after verifying an owner-issued `DeclassificationGrant`.

### SourceVaultAnonymize[origRef, opts]
Runs the full pipeline: 段 0a grant verification (no body read yet) → 段 0b exact origin open → build/reuse `PseudonymMap` entries for fields marked `{"Pseudonym", ..., ...}` in the policy tier → apply `FieldRules` (`"Drop"`/`"Redact"`/`"KeepRaw"`/`"Keep"`/`{"Pseudonym",...}`/`{"Generalize","timestamp->date"}`, default from `DefaultFieldRule`) → three-layer `TextRules` on `"Keep"` string fields (KnownValueScan pairs, regex `Patterns`, optional `PrivateModelScanFn` seam) → per-row `ItemToken` + `SourceUnitID`/`DerivedUnitID` lineage node/edge construction → Verify gate (V1 known-value leak scan / V2 pattern leak scan / V3 external `VerifyFn` / k-anonymity check) → save `LineageManifest` + content-addressed `DerivedArtifact` + `ArtifactBinding` → publish per the grant's `PublishMode` → local cache-identity write.
→ `<|Status->"OK", ArtifactRef, ArtifactBindingRef, LineageManifestRef, MapRef, PublicationState->"Staged"|"Published", ReleaseHandle, Payload->{rows...}, CacheHit->False, Report-><|Rows,Entities,Verify->"Pass"|>|>`
Cache hit (identical `OriginSetDigest`+`PolicyDigest`+`TargetLevel`+`EngineVersion`+`CanonicalizationVersion`, already `Published`, `Force->False`): `<|Status->"OK", ArtifactRef, PublicationState->"Published", CacheHit->True, MapRef|>` (reduced shape — no `ArtifactBindingRef`/`LineageManifestRef`/`ReleaseHandle`/`Payload`/`Report`; no body re-processed).
Options: `"GrantRef" -> None` (required `DeclassificationGrant` Association; absent → `<|Status->"Failed", Reason->"NeedsOwnerApproval"|>` without reading the body), `"TargetLevel" -> Automatic` (defaults to the grant's `ExactTargetLevel`), `"Policy" -> Automatic` (defaults to the grant's `PolicyRef`), `"Purpose" -> None` (defaults to the grant's `Purpose`; if explicitly given, must exactly match the grant's `Purpose` or `SourceVaultVerifyDeclassificationGrant` fails with `GrantRequestMismatch`), `"IntendedSink" -> None` (same, matched against the grant's `IntendedSink.Class`), `"PrivateModelScanFn" -> None` and `"VerifyFn" -> None` (local-LLM seam functions; if the resolved policy tier sets `TextRules.PrivateModelScan->True` and either is missing, returns `<|Status->"NeedsReview", Reason->"PrivateModelScanUnavailable"|>` without saving), `"Force" -> False` (bypass the cache hit).
Failure/Review reasons: `"NeedsOwnerApproval"`, `"PlanFailed"` (schema-only plan build failed), any `SourceVaultVerifyDeclassificationGrant` reason, any `SourceVaultAnonymizationPolicy` reason, `"TierNotDefined"` (policy has no tier for the resolved `TargetLevel`), any `SourceVaultConsumeDeclassificationGrantUse` reason, `"OriginUnreadable"`, `"NoRows"`, `"NeedsReview"` with `"PrivateModelScanUnavailable"`, `"Failed"` with `"V1KnownValueLeak"`/`"V2PatternLeak"`/`"KAnonymityViolation"`, `"NeedsReview"` with `"V3VerifierRejected"`, `"LineageBuildFailed"`, or any lineage/artifact/binding/publish save failure reason (see the corresponding sections above).
Origin rows: reads the loaded origin's `"Rows"` field (list of Association rows) if present, else treats the whole origin as a single row.
Both `SourceVaultApproveDeclassification` and `SourceVaultAnonymize` are registered in `NBAccess`$NBApprovalHeads` — agent/LLM-driven calls route through Hold → owner Approve UI (self-approval is structurally blocked).

## ReleaseHandle mapping (U0, spec §5.10, §10.5)

Handle plaintext is never stored in the mapping — only its keyed HMAC digest keys the record.

### SourceVaultResolveReleaseHandle[handle] → Association
Resolves a bearer-retrieval `"sv://release/..."` handle to its publication (the only path for unauthorized-reuse checks). Returns `<|Status->"OK", ArtifactRef, PublicationRef|>` only if Active and unexpired. NotFound/Revoked/Expired are all reported identically as `<|Status->"Failed", Reason->"HandleInvalid"|>` (prevents an existence oracle).

### SourceVaultRevokeReleaseHandle[artifactRef] → Association
Revokes every ReleaseHandle for an artifact (owner-interactive-only mutation; content identity unchanged).
→ `<|Status->"OK", RevokedCount, ArtifactRef|>` | `<|Status->"Failed", Reason->"NonInteractiveMutationRefused"|"HandleStoreUnavailable"|>`

### SourceVaultRotateReleaseHandle[artifactRef] → Association
Revokes all old handles and issues a fresh one (handle-leak response; owner-interactive-only). New handle plaintext is returned only in the result (mapping retains only its digest); artifact content identity is unchanged (AC-085).
→ `<|Status->"OK", RevokedCount, ReleaseHandle, ArtifactRef|>` | `<|Status->"Failed", Reason->"NonInteractiveMutationRefused"|"HandleStoreUnavailable"|>`

## MCP Projection / Unlisted (A7, spec §15.1, §15.3, §10.5)

### SourceVaultAnonymizeGetByHandle[releaseHandle] → Association
The only unauthorized-reuse-safe retrieval path: resolves the handle, re-verifies `SourceVaultAnonymizePublicationStatus` is exactly `"Published"` (defense-in-depth beyond the handle store's own check), loads the artifact, and returns a low-PL projection — `Payload`/`Format`/`TargetLevel` only, never `OriginRef`/`MapRef`/`ArtifactBindingRef`/`LineageManifestRef`.
→ `<|Status->"OK", ArtifactRef, TargetLevel, Format->"Records", Discoverability->"Unlisted", Payload|>`
Failure reasons: `"HandleInvalid"` (NotFound/Revoked/Expired all indistinguishable), `"NotPublished"`, `"ArtifactUnreadable"`.

### SourceVaultAnonymizeUnlistedClassQ[source] → Boolean
`True` if `source` (an Association, e.g. a snapshot record) is in the unlisted class set (spec §15.1): `Discoverability->"Unlisted"`, or `ObjectClass` in `{"AnnotationContent","AnnotationBinding","CloudTransportResult","PseudonymMap","LineageManifest","ArtifactBinding","DeclassificationPublication","EvaluationPlanManifest","EvaluationResultManifest","CerezoGradingProjection","AnonymizationPlan","DeclassificationGrant"}`, or `ObjectClass->"DerivedArtifact"` with `ArtifactType->"Anonymized"`. `False` for non-Association input. Called weakly from the search index's release policy so search/catalog never lists these.

## Composition Policy + Exposure Ledger (G1, spec §5.14, §13.5, §15.2)

### SourceVaultAnonymizeComposedPrivacy[spec] → Association
Returns the composed `PrivacyLevel` for an aggregate/joined artifact (spec §13.5) — not a simple `Max` of inputs.
→ `<|PrivacyLevel, Basis|>` (always returns; no `Status`/failure branch)
`spec` keys (all optional, defaulted): `AnnotationType -> "None"`, `DistinctSubjectCount -> 1`, `IndividualValuesPresent -> False`, `InputPL -> 0.45`. Decision order: `AnnotationType->"Grade"` with individual values present → `PL 1.0, Basis->"GradeWithIndividualValues"`; ≥2 distinct subjects with individual values → `PL 1.0, Basis->"MultiSubjectAggregate"`; ≥2 distinct subjects without individual values → `PL 0.85, Basis->"AggregateStatisticsNeedsPolicy"`; else → `PL->Max[InputPL,0], Basis->"SingleItemInputPL"`.

### SourceVaultAnonymizeRecordExposure[event] → Association
Durably appends an `ExposureEvent` to a high-PL append-only JSONL ledger (`PrivateVault/config/anonymize-exposure-ledger.jsonl`). Never includes body content or real tokens; `ScopeID` is replaced with an owner-only keyed HMAC digest before writing.
`event["EventClass"]`: `"PublicationActivated"`/`"ContentReleased"`/`"CloudEgressed"`/`"CloudIngressReceived"`/`"AggregateCreated"`/`"ReleaseDenied"`/`"ReleaseIndeterminate"`, plus the internal `"PreReleaseIntent"` used by `SourceVaultAnonymizeExposureGuard`. Only `"ContentReleased"`/`"CloudEgressed"`/`"ReleaseIndeterminate"` are coverage-counted (`CoverageCounted->True`).
→ `<|Status->"OK", EventClass, CoverageCounted|>`
Failure reasons: `"LedgerUnavailable"`, `"LedgerWriteFailed"`.

### SourceVaultAnonymizeExposureGuard[intent]
Evaluates an ExposureLedger rollup immediately before a release/egress and returns a gate decision (spec §15.2). First durably records a `"PreReleaseIntent"` event via `SourceVaultAnonymizeRecordExposure` — if that record fails, the call denies outright (never proceeds unrecorded).
→ `<|Decision->"Deny", Reason->"PreReleaseIntentUnrecordable"|>` (early-exit shape, no coverage fields) | `<|Decision->"Deny"|"RequireOwnerApproval"|"PermitAndReport"|"Permit", Reason, CoverageAfter, CohortRatio, RequestID|>`
`intent` keys: `ScopeID -> "none"` (hashed), `ProviderTrustDomain -> "Unknown"`, `DistinctSubjects -> 0`, `CohortSize -> 0`, `RequestID` (default a fresh UUID), `ExposurePolicy -> <||>` (sub-keys, checked in order: `MaxDistinctSubjectsPerProviderPerWindow` Integer → over → `RequireOwnerApproval`/`"DistinctSubjectThresholdExceeded"`; `MaxCohortCoveragePerProvider` Numeric → over → `RequireOwnerApproval`/`"CohortCoverageThresholdExceeded"`; `MaxVariantsPerOriginPerProvider` Integer → over → `RequireOwnerApproval`/`"RepeatedVariantExposure"`; `AlertThreshold` Numeric → over → `PermitAndReport`/`"AlertThreshold"`; else → `Permit`/`"BelowThresholds"`; `WindowSeconds -> 86400` controls the rollup window).

## Evaluation Distribution Plan (G2, spec §13.6)

### SourceVaultAnonymizeValidateDistribution[plan, assignment] → Association
Checks whether a provider `assignment` conforms to an owner-approved `DistributionPlan` (spec §13.6): rejects unauthorized providers, per-provider subject-count overflow, and duplicate-subject cross-provider sends (redundant grading requires explicit permission).
→ `<|Status->"OK"|"Failed", UnauthorizedProviders->count, OverLimitProviders->count, DuplicateSubjects->count|>` (failure is signaled purely by nonzero counts, no named per-violation Reason)
`plan` keys: `AllowedProviders -> {}`, `MaxSubjectsPerProvider -> Infinity` (only enforced when set to an Integer), `AllowCrossProviderDuplicateSubject -> False`. `assignment`: list of `<|"SubjectToken", "Provider"|>`.

## System Doctor Diagnostics (G1c, spec §16.2)

### SourceVaultAnonymizeExposureProbe[] → Association
Sanitized SystemDoctor-facing probe over the ExposureLedger — never exposes actual artifact/provider/owner/scope values, only Health + coarse range buckets (`"0"`/`"1-9"`/`"10-49"`/`"50-199"`/`"200+"`), guarding against the alert itself leaking information (spec T41).
→ `<|Health->"High"|"OK", ReasonCode->"AnonymizedArtifactConcentratedUse"|"BelowThreshold", ScopeCountRange, MaxScopeReleaseRange|>` | `<|Health->"Warning", ReasonCode->"ExposureLedgerUnavailable"|>` (reduced shape on ledger read failure)
`Health->"High"` when any single scope has more coverage-counted releases than the (internal, mutable) concentration threshold — default `50`.

### SourceVaultAnonymizeExposureSensitiveDoctor[] → Association
Owner-interactive-only detailed diagnostic (unsanitized): per-provider-trust-domain coverage, top-5 scopes by release count, and a remediation hint.
→ `<|Status->"OK", TotalReleases, DistinctScopes, ByProviderTrustDomain-><|domain->count,...|>, TopScopes->{<|Scope,Releases,Variants|>...}, Remediation|>`
Failure reasons: `"OwnerOnly"` (non-interactive caller), `"ExposureLedgerUnavailable"`.

### SourceVaultRegisterAnonymizeExposureDiagnostics[] → Association
Weakly registers `SourceVaultAnonymizeExposureProbe` as probe id `"anonymize-exposure"` into SourceVault diagnostics/SIEM (`SourceVaultDiagnosticsRegisterProbe`, if loaded).
→ `<|Status->"Registered"|"Failed", ProbeId->"anonymize-exposure"|>` | `<|Status->"DiagnosticsUnavailable"|>` if diagnostics isn't loaded.

### SourceVaultAnonymizeExposureEscalateIfNeeded[] → Association
Runs `SourceVaultAnonymizeExposureProbe[]`; if `Health` is `"High"` or `"Critical"` and `SourceVaultDiagnosticsEscalate` is loaded, sends a cloud-safe escalation event (`EventClass->"AnonymizeExposureConcentration"`, `Severity->"High"` — hardcoded regardless of the actual probe `Health`, `ReasonCode`, `Component->"anonymize-exposure"`, `MaxScopeReleaseRange`).
→ `<|Status->"Escalated", ReasonCode|>` | `<|Status->"NoEscalation", Health|>`

## Image Redaction (A6, spec §6.6, §6.8, AC-020)

### SourceVaultAnonymizeImageRedact[img, regions] → Image
Black-out redaction: zeroes the raw byte pixels inside each region, then rebuilds a fresh `Image` (full re-encode — no metadata/layers survive). Returns a raw `Image`, not an Association.
`regions`: `{<|"x1","y1","x2","y2"|>...}`, normalized 0-1 coordinates (bottom-origin; internally flipped to top-origin pixel rows). Degenerate regions (after clipping, `c2<c1` or `r2<r1`) are silently skipped.

### SourceVaultAnonymizePDFPageImages[pages, opts] → Association
Applies `SourceVaultAnonymizeImageRedact` to every page in a list, using the same flat `"Regions"` list on every page (not per-page). Non-`Image` list elements pass through unchanged.
→ `<|Status->"OK", Format->"PageImageList", Pages->{redactedOrPassthrough...}|>` (always `"OK"`, no failure path)
Options: `"Regions" -> {}`, `"DPI" -> 150` (defined but currently unused by the implementation — DPI must already be baked into the input `Image`s).

### SourceVaultAnonymizeVerifyRedactedImage[img, regions] → Association
Independent V5 redaction-completeness check (spec §6.8/AC-020, a separate code path from the redactor): for each region, fails if the pixel patch has nonzero variance (`Max-Min>0`, i.e. not solid black) — a different check than `ImageRedact`'s own logic. Degenerate region bounds count as a failure here (opposite of `ImageRedact`'s silent-skip).

## MediaScan — auto-detected redaction (A8, spec §6.8)

### SourceVaultAnonymizeMediaScan[img, opts] → Association
Redacts PII regions found by a **local** OCR/vision detector, combined with declared regions. Detector and declared regions are **not** exclusive: declared regions are always burned in, detected ones are added.
→ `<|Status->"OK"|"NeedsReview", Reason, Image, Regions, Evidence|>`
Options: `"DeclaredRegions" -> {}`, `"MediaScanFn" -> None` (`img -> {<|"x1","y1","x2","y2","confidence"|>...}`; injection seam, local only — unset means no detection), `"ConfidenceThreshold" -> 0.5`, `"IndependentVerifierFn" -> None` (`img -> {residual regions...}`; must be a different code path from the redactor).
Fail-closed → `"NeedsReview"` (caller must not auto-publish) in four cases, reported in `Reason`: `"MediaScannerUnavailable"` (detector threw; declared regions are still burned in), `"LowConfidenceDetection"` (something was detected below threshold — evidence that the page could not be fully covered), `"NoRegionsToRedact"` (nothing declared and nothing detected — never a silent pass), `"V5CompletenessFailed"` / `"IndependentVerifierFoundResidual"`.
`Evidence` (detector, detected/kept/low-confidence/declared counts, V5 status, independent residual count) is meant to be persisted at PL 1.0 by the caller.

## Answer-sheet PDF grading (C4, spec §12.1, §12.2, §14.3)

### SourceVaultAnonymizeBuildPageUnits[spec, opts] → Association
Splits a scanned PDF into per-page SourceUnits. `spec`: `<|"SourceObjectID", "SourceVersionID", "PDFDigest", "Pages"->{Image...}|>`.
Each page gets **two** ids: `SourceUnitID` (locator = PDF digest + physical page index — changes when pages are reordered) and `ContentUnitID` (locator = PDF digest + page image digest — invariant under reordering, and identical for duplicated pages). `PageUnitContentSetDigest` is therefore stable across page reordering while `PageUnitSetDigest` is not; that pair is what makes the spec's "robust by digest" property checkable.
Also flags `Blank` (byte spread ≤ `"BlankTolerance"`, default 0) and `DuplicateOf` (index of the first page with the same image digest).
→ `<|Status->"OK", PDFDigest, PageUnits, PageCount, DuplicatePageCount, BlankPageCount, PageUnitSetDigest, PageUnitContentSetDigest|>`

### SourceVaultAnonymizeRecordIdentityEvidence[candidates, opts] → Association
Stores OCR identity candidates as an immutable PL 1.0 `IdentityEvidence` snapshot. **OCR output is never adopted as identity directly** (spec §12.2) — a subject is `"AutoConfirmed"` only if it trips none of the fail-closed conditions, otherwise `"NeedsAdjudication"`.
`candidates`: `{<|"PageIndex", "PageDigest", "BoundingBox", "RawText", "StudentIDCandidate", "StudentNameCandidate", "Confidence"|>...}`.
Options: `"Roster" -> {<|"StudentID","StudentName"|>...}`, `"ConfidenceThreshold" -> 0.8`, `"ExpectedSubjectCount"`/`"ExpectedPageCount" -> Automatic`, `"Engine"`/`"EngineVersion"`/`"Config"`.
Per-subject reason codes: `"LowConfidence"`, `"IDNotInRoster"`, `"RosterNameMismatch"` (id and name are different people on the roster), `"NonContiguousPages"` (same id at non-adjacent pages = a split booklet), `"DuplicatePageIndex"`, `"AmbiguousPageBoundary"` (page with no id candidate). Evidence-wide reasons land in `GlobalReasons`: `"SubjectCountMismatch"`, `"PageCountMismatch"`, `"AmbiguousPageBoundary"`.
**The return value deliberately carries no PII** — only `EvidenceRef`, `EvidenceDigest` and `SubjectKey` (HMAC prefix of the normalized id). Names, raw OCR text and bounding boxes stay inside the PL 1.0 snapshot.
Note: digests are taken over a real-safe projection (confidences/bounding boxes are `Real`, which CanonicalEncode v1 rejects fail-closed).

### SourceVaultAnonymizeAdjudicateIdentity[evidenceRef, decision] → Association
Append-only adjudication event pinning `EvidenceDigest` and the candidate digest of the subject. `decision`: `<|"SubjectKey", "Decision"->"Confirmed"|"Rejected", "Adjudicator", "Note"|>`.
Requires an interactive owner session (`NonInteractiveMutationRefused` otherwise); refuses unknown subject keys; fails (`AdjudicationLogWriteFailed`) if the durable log cannot be appended. Events go to `config/anonymize-identity-adjudications.jsonl` and are weakly emitted to the publication audit log.

### SourceVaultAnonymizeIdentityStatus[evidenceRef] → Association
Folds adjudication events (matched on both `EvidenceRef` **and** `EvidenceDigest`, so events do not carry over to a re-recorded evidence) onto the initial per-subject states; the latest decision per subject wins.
**While `GlobalReasons` is non-empty, `AutoConfirmed` no longer implies `Confirmed`** — if the page↔examinee correspondence itself is in doubt (headcount/page-count mismatch), only an explicit owner decision can confirm a subject.
→ `<|Status->"OK", State->"Resolved"|"NeedsAdjudication", Subjects, ConfirmedSubjectKeys, PendingSubjectKeys, RejectedSubjectKeys, GlobalReasons|>`

### SourceVaultAnonymizeAnswerSheetPages[pages, opts] → Association
Runs `SourceVaultAnonymizeMediaScan` over each answer page (same options) and keeps only the pages it returned `"OK"` for; anything else is dropped into `ExcludedPages` and never reaches the artifact. `PageReports` carries the per-page status/reason/evidence but **not** the images.
→ `<|Status->"OK"|"NeedsReview", Format->"PageImageList", Pages, PageIndices, PageReports, ExcludedPages|>`

### SourceVaultAnonymizeAnswerSheetPlan[spec, opts] → Association
Builds the EvaluationPlanManifest for answer-sheet grading: **EvaluationUnit = one examinee (all their pages), ResultSlot = one question**.
`spec`: `<|"TargetArtifactRef", "ArtifactBindingRef", "RubricDigest", "Subjects"->{<|"SubjectKey", "SubjectToken", "ItemTokens", "Slots"|>...}|>`; `Slots` entries are either a plain key string or `<|"SlotKey", "TargetItemToken", "ExpectedOutputSchemaDigest"|>`.
Option `"IdentityEvidenceRef" -> None`: when given, only subjects whose identity is `Confirmed` are graded; the rest are returned as `ExcludedUnits` with `Reason->"IdentityNotConfirmed"` (this is what prevents grades from being written back to the wrong person). All subjects unconfirmed → `Failed`/`"NoConfirmedSubjects"`. Without the option no identity check is performed and every subject is included.
→ plan fields (`PlanRef`, `Jobs`, `EvaluationBatchID`) plus `<|IncludedSubjectCount, ExcludedUnits, IdentityEvidenceRef|>`

### ResultSlots in the evaluation plan (spec §5.11)
`SourceVaultAnonymizeBuildEvaluationPlan` accepts `"ResultSlots"` on a unit and mints one `ResultSlotToken` per slot plus `ExpectedResultSlotMultisetDigest`; a slot whose `TargetItemToken` is not in that unit's `ItemTokens` is refused (`SlotTargetNotInUnit`), so a slot can never point at another examinee's item.
`SourceVaultCreateDerivedAnnotations` then requires each result of a slotted job to carry `"Slots" -> {<|"ResultSlotToken", "Score", "Reason"|>...}`: a missing list is `MissingResultSlots`, a differing multiset is `ResultSlotSetMismatch`, and both refuse the **whole batch**. The item token always comes from the plan; response tokens are only used to match slots. Annotation items gain a `SlotKey`, and the join key becomes `ItemToken#SlotKey` (unchanged for slot-less annotations, so existing digests still match).
→ `<|Status->"OK"|"Failed", NonSolidRegions->count|>`