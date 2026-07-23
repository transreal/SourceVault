## 概要

Implements de-identification primitives for SourceVault (spec `sourcevault_anonymization_spec_v1_0.md` v1.0):
- L0a: canonical encoding v1, KeyRing over NBAccess MAC KeyRefs, collision-resistant ID expressions (EntityID / SourceObjectID / SourceUnitID / DerivedUnitID), role tokens (Subject/Item/Job/ResultSlot) + CSPRNG ReleaseHandle.
- G0a: schema-only `SourceVaultAnonymizationPlan` (never reads document bodies).
- L0b: `LineageManifest` node/edge graph + self-validator.
- G0b: `DeclassificationGrant` request/approve/verify/consume-use lifecycle.
- L1: `PseudonymMap` (immutable MapVersion snapshots + MapHead CAS pointer).
- U0: `ReleaseHandle` mapping/revoke/rotate.

Design principles (spec §2):
- P-A3 fail-closed: undecidable/missing-key/unknown-type inputs return `$Failed`/`Failure`, never a guess.
- P-A13 identity independence: `SourceUnitID` embeds `SourceObjectID` so two different logical objects with identical content never collide; order-independent.
- P-A15 owner-authorized execution: this module's Plan never reads body content. A high-PL-reading Execute (`SourceVaultAnonymize`) is added once the G0b grant gate exists; not defined in this file.
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
Verifies current key fingerprints against the shared pin file (spec §5.5.1 / AC-053). First run pins current fingerprints (`Status->"Pinned"`); a match returns `Status->"OK"` (with `NewlyPinnedKeyRefs` for any newly-added keys, e.g. the grant key); a mismatch returns `Status->"Failed", Reason->"KeyFingerprintMismatch"` and blocks further ID generation (guards against a volatile-backend kernel, e.g. MCP, silently minting IDs under a different key). Also returns `Status->"Failed"` for `"VolatileKeyBackend"` or `"KeysMissing"`, or `Status->"Skipped"` if the pin store is unavailable.

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
→ Association: `<|Status->"OK", Type->"AnonymizationPlan", SchemaVersion->1, SchemaOnly->True, Origins (record-bound: OriginRef/RefForm/ObjectClass/Role/PrivacyLevel/PrivacyLevelSource), OriginSetDigest, UnitCountRange->"SchemaOnly", TargetLevelChoices->{"0.45","0.2"}, SinkChoices->{"CloudLLM","CloudLLM-LowTrust"}, CandidatePolicies, CandidateProfiles, CanonicalizationVersion, EngineVersion, PlanDigest, CreatedAtUTC, PlanRef (if Save->True)|>`
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
Options: `"TargetLevel" -> None` (must be a member of `plan`'s `TargetLevelChoices`), `"Purpose" -> None` (required String), `"IntendedSink" -> None` (required `<|"Class"->...|>`), `"PolicyRef" -> "unspecified"`, `"PolicyDigest" -> "unspecified"`, `"PublishMode" -> "StageForOwnerReview"` (alt: `"PublishIfVerified"`), `"MaxExecuteUses" -> 1`, `"TTLSeconds" -> 86400`.

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
→ `<|Status->"OK", MapId, MapRef, MapVersion, Assignments, NewVersion->True|>`
`identities` elements: `<|"Institution", "CanonicalID", "Identity"-><|...|>, "KnownStrings"->{...}|>`. The same entity (by `EntityID`) always returns its existing `SubjectToken` (stable numbering); `KnownStrings` are expanded deterministically (NFC, full-width→half-width, whitespace-stripped variants) and merged.
Failure reasons: `"InvalidMapSpec"`, `"CoreUnavailable"`, `"EmptyIdentities"`, `"EntityIDFailed"`, `"LockUnavailable"`, `"CASRetriesExhausted"`, `"SnapshotSaveFailed"`.

### SourceVaultAnonymizePseudonymMap[mapIdOrRef] → Association
Reads the pseudonym map. Pass a `MapId` (`"map:..."`) for the latest MapHead version, or an exact snapshot ref for that exact version (content immutable even as head advances, AC-029). Returns the map Association with `MapRef` appended.
Failure reasons: `"MapHeadNotFound"`, `"MapVersionUnreadable"`.

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

This is the full content — no file was written per your instruction. Let me know if you'd like me to save it (I'd need write permission granted first).