# SourceVault Physical Storage, Encryption, and Standalone Capsule Extension v0.13

作成日: 2026-05-12  
対象: `SourceVault.wl`, `NBAccess.wl`, `ClaudeAttach`, `ClaudeOrchestrator.wl`, `ClaudeRuntime.wl`, `maildb.wl`, `documentation.wl`, `NotebookExtensions.wl`, Mathematica notebooks  
位置づけ: v0.12 の `LocalPrivateVault` / `EncryptedVault` / `Standalone Capsule` / `LLMGraph convergence` 仕様に対し、暗号化方式・鍵管理・Capsule import 信頼境界・暗号化セルの hash 戦略を具体化する。

---

## 0. 結論

v0.12 で導入した `EncryptedVault` と `Standalone Capsule` は採用する。ただし、暗号化機構を抽象的な `Algorithm -> Automatic` のままにしてはならない。v0.13 では、Wolfram Language の native cryptography を第一候補とし、鍵管理・復旧・鍵更新・公開鍵暗号による Capsule 配布を仕様に組み込む。

Wolfram Language は `Encrypt` / `Decrypt` による式の暗号化、`EncryptFile` / `DecryptFile` によるファイル暗号化、`PublicKey` / `PrivateKey` を使う公開鍵暗号を標準機能として持つ。したがって、SourceVault は Python/OpenSSL 等への依存を初期実装では必須にしない。

v0.13 の中心原則は次である。

```text
1. SourceVault の暗号化は Mathematica native encryption を基本とする。
2. 鍵の実体は record / log / manifest に保存せず、KeyRef のみ保存する。
3. KeyRef は NBAccess/SystemCredential 管理下に置く。
4. 鍵紛失時に復旧できないことを明示し、escrow / backup を初期化時に必須確認する。
5. 外部受信 Capsule は、復号に成功しても trust しない。
6. 暗号化セルは CiphertextHash と PlaintextHash の二段 hash で扱う。
7. Notebook 単体配布には、公開鍵暗号または別経路鍵伝達を組み合わせる。
```

---

## 1. Mathematica native encryption policy

### 1.1 採用する暗号化層

SourceVault は次の 2 種類の暗号化を区別する。

```text
Object encryption
  小さな association / claim / metadata / notebook cell payload を EncryptedObject として保存する。

File encryption
  notebook snapshot / PDF / generated artifact / large context cache を encrypted file として保存する。
```

対応 API は次である。

```wl
Encrypt[key, expr]
Decrypt[key, encryptedObject]
EncryptFile[key, file]
DecryptFile[key, encryptedFile]
```

`Encrypt` の戻り値は `EncryptedObject` として notebook cell や SourceVault record に埋め込める。`EncryptFile` は SourceVault の `EncryptedVault` に置く大きな artifact の標準経路とする。

### 1.2 Algorithm policy

`EncryptionPolicy` は `Algorithm -> Automatic` を許すが、実装は必ず解決結果を record に書く。

```wl
"EncryptionPolicy" -> <|
  "Mode" -> "EncryptedAtRest",
  "Backend" -> "WolframLanguageNative",
  "KeyRef" -> "SourceVault:master:v1",
  "Algorithm" -> Automatic,
  "ResolvedAlgorithm" -> <|
    "Kind" -> "Symmetric" | "Asymmetric" | "HybridPublicKey",
    "WolframVersion" -> $VersionNumber,
    "Method" -> Automatic | "AES256" | "RSA" | "EllipticCurve" | _String,
    "RecordedAt" -> Now
  |>
|>
```

重要原則:

```text
- Algorithm -> Automatic はユーザ向け指定であり、保存 record では未解決のままにしない。
- 可能なら GenerateSymmetricKey[Method -> "AES256"] 等で明示 key を作る。
- Wolfram 側の既定値に委ねた場合も、実行時に得られる暗号メタ情報を record に保存する。
- 将来の Wolfram version で既定 algorithm が変わっても、既存 encrypted object の解釈が追跡できるようにする。
```

### 1.3 Backend selection

```text
Default backend:
  WolframLanguageNative

Allowed backends:
  WolframLanguageNative
  ExternalOpenSSL       (* Stage 8+ only *)
  GPGRecipientEnvelope  (* Capsule key wrapping only *)
```

初期 PoC では `WolframLanguageNative` のみを実装する。外部コマンドは、公開鍵 envelope や既存 GPG keyring との連携が必要な場合に限る。

---

## 2. Key management

### 2.1 KeyRef 命名規約

鍵そのものは SourceVault record に保存しない。保存するのは `KeyRef` のみである。

```wl
"KeyRef" -> "SourceVault:master:v1"
```

標準 KeyRef:

```text
SourceVault:master:v1
SourceVault:master:v2
SourceVault:project:<projectId>:v1
SourceVault:notebook:<notebookId>:v1
SourceVault:capsule:<capsuleId>:v1
SourceVault:recipient:<recipientId>:public:v1
SourceVault:recipient:<recipientId>:private:v1
```

KeyRef の実体は NBAccess を通して `SystemCredential` または OS keychain 相当から取得する。`SystemCredential` が OS keychain を利用できる場合、鍵は Dropbox sync の対象外になり、Dropbox-backed PrivateVault と EncryptedVault の境界が物理的に分かれる。

### 2.2 Symmetric keys

SourceVault 内部保存用の標準は symmetric key とする。

```wl
SourceVaultGenerateSymmetricKey[keyRef_String, opts___]
```

意味:

```text
- GenerateSymmetricKey[] または GenerateSymmetricKey[Method -> "AES256"] を使う。
- 生成した key は SystemCredential[keyRef] に保存する。
- key 値は audit log に出さない。
- keyRef のみ SourceVault record に保存する。
```

### 2.3 Public-key / hybrid encryption

Notebook Capsule を他者へ送る場合は、公開鍵暗号を直接大 payload に使うのではなく、hybrid envelope を標準とする。

```text
1. PayloadKey を一時 symmetric key として生成する。
2. Capsule payload を PayloadKey で暗号化する。
3. PayloadKey を受信者ごとの PublicKey で暗号化する。
4. Capsule には encrypted payload と encrypted key envelopes を入れる。
5. 受信者は自分の PrivateKey で PayloadKey を復号し、payload を復号する。
```

Capsule record 例:

```wl
<|
  "CapsuleMode" -> "EncryptedFull",
  "Payload" -> EncryptedObject[...],
  "KeyEnvelopes" -> {
    <|
      "Recipient" -> "Collaborator:nagoya-team",
      "PublicKeyFingerprint" -> "sha256-...",
      "EncryptedPayloadKey" -> EncryptedObject[...]
    |>
  },
  "FallbackMode" -> "ManifestOnly"
|>
```

この方式により、notebook 本体と復号鍵を同じ平文チャネルで共有しない。

### 2.4 Key rotation

Key rotation は SourceVault operation として扱い、個別ファイル操作にしない。

```wl
SourceVaultRotateKey[oldKeyRef_, newKeyRef_, opts___]
```

手順:

```text
1. newKeyRef を生成して SystemCredential に保存する。
2. oldKeyRef で復号可能な encrypted entries を列挙する。
3. 1 entry ずつ復号 → newKeyRef で再暗号化する。
4. CiphertextHash は変わる。PlaintextHash は変わらない。
5. ReEncryptionEvent を audit log に追記する。
6. oldKeyRef を保持するか削除するかは policy に従う。
```

Rotation event 例:

```wl
<|
  "Event" -> "ReEncryption",
  "ObjectRef" -> ref,
  "OldKeyRef" -> "SourceVault:master:v1",
  "NewKeyRef" -> "SourceVault:master:v2",
  "OldCiphertextHash" -> "sha256-cipher-old",
  "NewCiphertextHash" -> "sha256-cipher-new",
  "PlaintextHash" -> "sha256-plain",
  "Reason" -> "KeyRotation",
  "At" -> Now
|>
```

### 2.5 Recovery / escrow policy

暗号化データは鍵を失うと原理的に復旧できない。したがって EncryptedVault 初期化時には escrow policy を必須確認する。

```wl
SourceVaultInitializeEncryptedVault[
  "RequireEscrowConfirmation" -> True
]
```

Escrow options:

```text
Recommended:
  - 受信者または自分の公開鍵で master key を暗号化した escrow file を作る。
  - escrow file は SourceVault 内に置かない。
  - escrow file の path も audit log に残さない。

Allowed:
  - paper backup
  - hardware token
  - password manager secure note
  - offline USB media

Forbidden:
  - SourceVault record 内に key を保存する。
  - cloud mirror / public manifest に key または復号可能な key material を保存する。
```

Escrow 未完了の場合:

```text
- EncryptedVault write は既定で拒否する。
- 明示 override は可能だが、SourceVault::NoEscrowWarning を出し audit log に残す。
```

---

## 3. Encrypted notebook cells and semantic hash

### 3.1 Two-tier hash strategy

暗号化セルでは、ciphertext と plaintext の identity を分ける。

```wl
<|
  "CellRef" -> "notebook:.../cell/...",
  "Encrypted" -> True,
  "EncryptionPolicy" -> <|...|>,
  "CiphertextHash" -> "sha256-cipher-...",
  "PlaintextHash" -> "sha256-plain-..." | Missing["EncryptedEnvironment"],
  "PlaintextStorage" -> "NotStored",
  "AccessLabel" -> <|
    "Confidentiality" -> "Secret",
    "Origin" -> "UserNotebook",
    "Integrity" -> "UserAuthored",
    "Retention" -> "EncryptedAtRest"
  |>
|>
```

### 3.2 Notebook SemanticHash

Notebook semantic hash は次の規則で計算する。

```text
- 通常セル: canonicalized cell expression の hash を使う。
- 暗号化セル: CiphertextHash を使う。
- 復号可能環境では PlaintextHash も別途検証する。
- PlaintextHash は semantic equivalence の補助情報であり、cloud mirror には出さない。
```

### 3.3 Key rotation and hash behavior

Key rotation により ciphertext は変わる。

```text
- CiphertextHash: 変わる。
- PlaintextHash: 変わらない。
- Notebook RawContentHash: 変わる。
- Notebook SemanticHash: 既定では変わる。
- ただし ReEncryptionEvent と PlaintextHash が一致すれば RotationInduced change として扱う。
```

Lint:

```text
EncryptedCellPlaintextHashMissingForPromotion
  暗号化セル由来の claim / bundle を promote するのに PlaintextHash がない。

RotationInducedNotebookHashChange
  key rotation による notebook hash 変化。warning ではなく informational。

EncryptedPlaintextLeakedToCloudMirror
  PlaintextHash 以外の plaintext summary / extracted text が CloudMirror に出ている。
```

---

## 4. Capsule import trust boundary

### 4.1 Imported objects are untrusted

外部から受け取った notebook capsule は、送信者の metadata に何が書かれていても、受信側では untrusted として扱う。

強制 label:

```wl
AccessLabel = NBLabelMeetOrClamp[
  importedLabel,
  <|
    "Origin" -> "ExternallyReceived",
    "Integrity" -> "Parsed",
    "Confidentiality" -> importedLabel["Confidentiality"],
    "Retention" -> "NoPersistUnlessApproved"
  |>
]
```

規則:

```text
- Imported WorkflowTemplate は即実行不可。
- Imported PromptTemplate は production registry に入れない。
- Imported Claim は private imported claim store に入れる。
- Imported CompiledRegistryEntry は compiled/public に merge しない。
- 復号成功は authenticity / integrity の証明ではない。
```

### 4.2 Promotion after review

外部 capsule の object を通常 object として使うには明示的 promote が必要である。

```wl
SourceVaultPromoteImportedObject[
  importedRef,
  "AfterHumanReview",
  "TargetClass" -> "WorkflowTemplate" | "Claim" | "Context" | "Artifact"
]
```

Promotion に必要な条件:

```text
- NBAuthorize["PromoteImportedObject", ...] = Permit
- HumanReview record がある。
- WorkflowTemplate なら HoldComplete 形式で安全に parse されている。
- NBValidateHeldExpr / NBPolicyGate を通過している。
```

### 4.3 Signature and public key verification

v0.13 では、public-key signature は optional とする。

```text
- Signature verified: Origin は ExternallyReceived のまま、Integrity は VerifiedSender まで上げられる。
- Signature absent: Integrity は Parsed 上限。
- Signature valid でも HumanReviewed / Compiled には自動昇格しない。
```

---

## 5. Capsule mode and sink compatibility

### 5.1 Compatibility matrix

| CapsuleMode | Collaborator with key | Collaborator without key | Public archive | Internal self-archive |
|---|---:|---:|---:|---:|
| ManifestOnly | OK | OK | OK | OK |
| PublicContext | OK | OK | OK | OK |
| RedactedReproducible | OK after review | OK after review | OK after review | OK |
| EncryptedFull | OK if key channel exists | Not useful | Forbidden | OK |
| OnlineRequired | OK if SourceVault access exists | Not useful | Forbidden | OK |

`CapsuleModeTooPermissiveForSink` はこの表に基づいて判定する。

### 5.2 EncryptedFull key transmission protocol

Forbidden:

```text
- notebook と復号 key を同じメールに添付する。
- Slack / Discord / GitHub issue 等に平文 key を貼る。
- SourceVault PublicManifest に key material を含める。
```

Recommended:

```text
1. 受信者の PublicKey で payload key を wrap する。
2. 既存 PGP/GPG key を使う場合は external envelope として扱う。
3. 一時 passphrase を使う場合は別チャネルで渡し、期限を設ける。
4. key なしでも ManifestOnly に degrade して読める fallback を用意する。
```

---

## 6. EmbeddedCapsule physical representation

### 6.1 TaggingRules vs hidden cell

```text
TaggingRules:
  - manifest / refs / small metadata
  - 目安 < 100 KB
  - notebook open 時にすぐ読まれる

Hidden SourceVaultCapsule cell:
  - encrypted payload / redacted workflow trace / larger context
  - 目安 >= 100 KB
  - CellOpen -> False
  - CellTags -> {"SourceVaultCapsule", "DoNotEditManually"}
```

推奨構成:

```text
TaggingRules["SourceVault", "EmbeddedCapsuleManifest"]
  → capsule summary, schema version, hidden cell UUID

Hidden cell
  → EncryptedObject / compressed payload / redacted trace
```

### 6.2 Capsule schema version

```wl
"CapsuleSchema" -> "SourceVaultCapsule/v1"
```

Import policy:

```text
- same major version: import allowed
- older minor version: best-effort import + warning
- unknown major version: reject by default
- required fields missing: reject
```

### 6.3 Capsule size limits

Recommended limits:

```text
ManifestOnly         < 100 KB
PublicContext        < 1 MB
RedactedReproducible < 5 MB
EncryptedFull        < 50 MB
```

超過時:

```text
- downgrade to lighter mode
- move large payload to external encrypted file
- use OnlineRequired hybrid
- compress payload before embedding
```

---

## 7. LLMGraph / Petri workflow lifecycle

### 7.1 LLMGraph snapshot policy

```wl
SourceVaultSnapshotLLMGraph[nb_, historyTag_:"Latest", opts___]
```

Snapshot policy:

```text
KeepBoth        notebook history と SourceVault snapshot の両方を残す。default。
MoveToVault     notebook history から large payload を削除し、SourceVault ref のみ残す。
ReferenceOnly   notebook に manifest ref のみ残す。
```

### 7.2 Workflow lifecycle

```text
1. Exploration
   LLMGraph in notebook history。informal。SourceVault snapshot optional。

2. Stabilization
   SourceVaultSnapshotLLMGraph により LLMGraphSnapshot として固定。

3. Formalization
   LLMGraphSnapshot から PetriWorkflowTemplate を作る。
   HumanReviewed までは Orchestrator 実行不可。

4. Execution
   PetriWorkflowRun として append-only trace → finalized immutable run record。

5. Promotion
   成功した workflow / artifact を future template / source として promote。
```

---

## 8. ExternalOwned deletion handling

ExternalOwned source は SourceVault が所有しない。削除された場合、SourceVault は次の扱いにする。

```text
- SourceRef は DanglingExternalReference になる。
- 既存 claim / evidence bundle は hash と provenance を保持する限り invalid にはしない。
- 新規 context assembly は不可。
- 同一 ContentHash の copy が別 tier にあれば recovery candidate として提示する。
```

Lint:

```text
DanglingExternalReference
ExternalOwnedDeletedButBundleCurrent
ExternalOwnedRecoveryCandidateFound
```

---

## 9. Revised PoC dependency graph

```text
PoC 0.5  Storage config + boot assertion
  ↓
PoC 0.6a LocalPrivateVault, no encryption
  ↓
PoC 0.6b EncryptedVault, Mathematica native encryption
  ↓
PoC 0.7  EmbeddedCapsule ManifestOnly / PublicContext
  ↓
PoC 0.8  EncryptedFull Capsule + public-key envelope

PoC 1.0  ClaudeResolveModel + seed registry
PoC 1.2  PrivateVault raw store
PoC 1.3  CloudMirror materialization
PoC 1.4  ClaudeAttach migration
PoC 1.5  Notebook register + capsule skeleton

Stage 3.5 maildb ExternalOwned adapter, read-only
Stage 5   maildb-driven local context assembly
Stage 7+  Orchestrator Petri workflow integration
```

---

## 10. Additional lint rules

```text
EncryptionPolicyUnresolvedAutomatic
EncryptedVaultEnabledWithoutEscrowConfirmation
KeyRefStoredInPublicManifest
PlaintextKeyInRecordOrLog
EncryptedCellMissingCiphertextHash
EncryptedCellMissingPlaintextHashWhenPromoted
CapsuleImportTrustedWithoutReview
ImportedWorkflowTemplateExecutable
EncryptedFullCapsuleWithoutKeyEnvelope
CapsuleTooLargeForMode
UnknownCapsuleSchemaVersion
LLMGraphSnapshotFullPrivatePromptEmbedded
WorkflowFormalizedWithoutHumanReview
```

---

## 11. Summary

v0.13 は、v0.12 で導入された `EncryptedVault` と `Standalone Capsule` を実装可能な水準に具体化する。

特に重要なのは次である。

```text
- Mathematica native encryption を標準 backend とする。
- SystemCredential / KeyRef による鍵管理を必須化する。
- key rotation / escrow / recovery policy を EncryptedVault 初期実装に含める。
- 外部受信 Capsule は復号できても trust しない。
- 暗号化 cell は CiphertextHash / PlaintextHash の二段 hash で扱う。
- Capsule の public-key envelope を正式化し、notebook 単体配布を安全にする。
- LLMGraph → PetriWorkflowTemplate → PetriWorkflowRun の lifecycle を明示する。
```

これにより SourceVault は、論理 label、物理 storage tier、暗号化、standalone capsule の四重境界を持つ privacy-aware research knowledge platform となる。
