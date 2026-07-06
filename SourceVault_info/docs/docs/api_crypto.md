# SourceVault_crypto API リファレンス

## 概要

SourceVault_crypto は SourceVault の暗号基盤であり、以下を提供する。

- 暗号能力実測 (`SourceVaultCryptoCapabilityReport`)
- canonical bytes 生成 (Internal/JSON プロファイル)
- encrypt-then-MAC の at-rest record 化 (`SourceVaultEncryptedPut`/`SourceVaultDecryptRecord`)
- 鍵 bootstrap (`SourceVaultInitializeEncryption`) とパスフレーズ保護鍵バンドル (import/export)
- cloud materialization 強制ゲート (`SourceVaultAuthorizeRecordMaterialization`/`SourceVaultMaterializeRecord`)

実測 (WL 14.3, 2026-06-04) に基づく設計判断:
- GCM/AEAD は `GenerateSymmetricKey` で利用不可のため、EncryptThenMAC を既定の primary IntegrityMode とする。
- 組み込み HMAC が無いため、RFC 2104 HMAC-SHA256 を自前構成している (`SourceVaultHMACSHA256Hex`)。
- `GenerateDigitalSignature` の RSA-PSS Method 指定は不可のため、capability report は該当項目に False を返す。

鍵隔離境界: 鍵材料は NBAccess の外に出さない。鍵を引数に取る内部 primitive (`iSV` 接頭辞) は本パッケージの外に公開しない。公開シンボルは capability report・canonical bytes・self-test・鍵 bootstrap・鍵バンドル・encrypted record・materialization ゲートに限る。

Load 順序:
```
Block[{$CharacterEncoding -> "UTF-8"},
  Get["NBAccess_crypto.wl"]; Get["SourceVault_crypto.wl"];
  Get["SourceVault_keys.wl"]; Get["SourceVault_keybundle.wl"];
  Get["SourceVault_encryptedstore.wl"]; Get["SourceVault_release.wl"]]
```
NBAccess (`NBAccess_crypto.wl`) が鍵材料の実体を保持し、SourceVault は KeyRef 経由でのみアクセスする。

## Capability / Canonical Bytes / Self-Test

### SourceVaultCryptoCapabilityReport[] → Association
この Wolfram 環境の暗号能力 (AEAD/GCM, RSA-PSS, HMAC) を実測し、既定 IntegrityMode を含む Association を返す。GCM/RSA-PSS は現行 WL では False が期待値。

### SourceVaultCanonicalJSONBytes[expr] → ByteArray
expr を再帰的に KeySort した canonical JSON (UTF-8) の ByteArray を返す。共有・署名・MAC の安定 bytes に使う (Interoperable JSON profile)。

### SourceVaultCanonicalBytes[expr, profile_:"Internal"] → ByteArray
canonical bytes を返す。profile="Internal" は `BinarySerialize` (ローカル at-rest payload 用)、"JSON" は `SourceVaultCanonicalJSONBytes` に委譲する。

### SourceVaultCryptoSelfTest[] → Association
capability probe・canonical 決定性・encrypt-then-MAC roundtrip・改ざん検出を検査し、結果 Association を返す。

### SourceVaultHMACSHA256Hex[keyBA_ByteArray, msgBA_ByteArray] → String
RFC2104 HMAC-SHA256 を hex 文字列で返す。AccessGrant 署名等の MAC に使う公開ラッパー。

### SourceVaultConstantTimeEqualQ[a_String, b_String] → Boolean
2つの hex/文字列を best-effort 定数時間で比較する (署名検証用)。

## 鍵 Bootstrap (SourceVault_keys.wl)

標準 KeyRef を定義し、欠落鍵だけを NBAccess crypto 層経由で生成する。鍵材料は戻り値・ログ・record に出さない。

### 標準 KeyRef 変数
- `$SourceVaultDefaultAtRestKeyRef` — 型: String, 値: `"SourceVault:master:atrest:v1"`。at-rest 暗号鍵 (Symmetric, rotation-stable=False)。
- `$SourceVaultDefaultAtRestMACKeyRef` — 型: String, 値: `"SourceVault:master:mac:v1"`。at-rest MAC 鍵 (Mac, 暗号鍵とは別)。
- `$SourceVaultDefaultPlaintextHMACKeyRef` — 型: String, 値: `"SourceVault:pthmac:digest:v1"`。plaintext digest HMAC 鍵 (Mac, rotation-stable)。
- `$SourceVaultDefaultMailIdentityHMACKeyRef` — 型: String, 値: `"SourceVault:mailid:mac:v1"`。mail RecordId/header token HMAC 鍵 (Mac, rotation-stable)。
- `$SourceVaultDefaultAddressBookMACKeyRef` — 型: String, 値: `"SourceVault:addressbook:mac:v1"`。AddressBook email/handle token HMAC 鍵 (Mac, rotation-stable)。
- `$SourceVaultDefaultCapsuleQuarantineMACKeyRef` — 型: String, 値: `"SourceVault:capsule:quarantine-mac:v1"`。受信 capsule の local at-rest quarantine MAC 鍵 (Mac)。
- `$SourceVaultDefaultBaselineMACKeyRef` — 型: String, 値: `"SourceVault:baseline:policy-mac:v1"`。Trusted Baseline local MAC 鍵 (Mac)。
- `$SourceVaultDefaultBaselineSigningKeyRef` — 型: String, 値: `"SourceVault:baseline:policy-sign:v1"`。Trusted Baseline owner 署名鍵 (Asymmetric)。
- `$SourceVaultDefaultSelfPrivateKeyRef` — 型: String, 値: `"SourceVault:self:private:v1"`。自分の envelope 復号 (capsule) 用秘密鍵 (Asymmetric)。
- `$SourceVaultDefaultSelfSigningKeyRef` — 型: String, 値: `"SourceVault:signing:sign:v1"`。自分の capsule 署名鍵 (Asymmetric)。

### SourceVaultInitializeEncryption[opts]
欠落している標準鍵だけを生成する冪等 bootstrap。鍵材料は返さない。既存鍵は破壊しない。
→ Association (`Type`->"SourceVaultInitializeEncryptionResult", `Status`: "AlreadyInitialized"|"Initialized"|"Partial", `DryRun`, `CreatedKeyRefs`, `ExistingKeyRefs`, `MissingKeyRefs`, `KeyMaterialReturned`->False, `RequiresUserApproval`->False)
Options: "DryRun" -> False (True の場合は生成せず判定のみ; missing がある場合 Status->"Partial")

### SourceVaultEncryptionKeyStatus[] → Association
標準 KeyRef ごとの存在状況 (`Exists`, `Kind`, `RotationStable`, `Purpose`, `Fingerprint`) を返す。鍵材料は含まない。未生成鍵の Fingerprint は `Missing["NotGenerated"]`。

## 鍵バンドル (SourceVault_keybundle.wl)

可搬・パスフレーズ保護の鍵バンドル。マルチ環境/災害復旧用。鍵は Dropbox 等の同期フォルダに載せない運用が既定。

設計: passphrase から scrypt (メモリ困難 KDF) で 64B 派生し、先頭32B を AES256-CBC ラップ鍵、末尾32B を HMAC-SHA256 MAC 鍵とする。salt はランダム生成し保存。各マスター鍵は `NBExportWrappedKeys` で wrapKey 暗号化し、平文鍵材料は出さない。bundle 全体を encrypt-then-MAC し、誤 passphrase / 改ざんは MAC 検証で fail-closed。復元は `BinaryDeserialize` のみで `ToExpression` は使わない。

### $SourceVaultKeyBundleDefaultPath
型: String (動的), 初期値: `FileNameJoin[{$HomeDirectory, "SourceVault_keybundle.svkeys"}]`
鍵バンドルの既定パス (Dropbox 等の同期フォルダ外)。

### SourceVaultExportKeyBundle[passphrase, opts]
標準マスター鍵を passphrase で包んだ可搬バンドルをファイルに書く。鍵材料は返さない。実在する鍵だけを対象にする。
→ Association (`Status`: "Exported"|"Error", 成功時 `Path`, `KeyRefs`, `KeyCount`, `Fingerprints`, `KDF`, `CreatedAt`, `OnSyncFolderWarning`, `KeyMaterialReturned`->False)
Options: "Path" -> Automatic (既定はホーム直下・非同期フォルダ), "KeyRefs" -> Automatic (既定=標準鍵一式), "ScryptN" -> Automatic (既定131072=2^17, ~128MB メモリ困難), "Force" -> False (12文字未満の弱 passphrase を強制許可)
passphrase が12文字未満かつ "Force"->False の場合は `Status->"Error"`, `Reason->"WeakPassphrase"` を返す。対象鍵が1つも存在しない場合は `Reason->"NoKeysFound"`。同期フォルダ (Dropbox/OneDrive/Google Drive/iCloud) 上のパスは `OnSyncFolderWarning->True` で警告する。

### SourceVaultImportKeyBundle[passphrase, opts]
バンドルを passphrase で解錠し、各鍵を現マシンの credential store に書き戻す。誤 passphrase/改ざんは MAC 検証で拒否 (`Reason->"BadPassphraseOrTampered"`)。
→ Association (`Status`: "Imported"|"Error", 成功時 `Path`, `RestoredKeyRefs`, `RestoredCount`, `Backend`, `Fingerprints`)
Options: "Path" -> Automatic
読めない/存在しない場合は `Reason->"UnreadableOrMissing"`、KDF パラメータ不正は `Reason->"BadKDFParams"`。

### SourceVaultKeyBundleInfo[path_:Automatic] → Association
passphrase 無しで読める非秘密メタ (`Status`, `Path`, `Version`, `CreatedAt`, `KeyRefs`, `KeyCount`, `KDF`) を返す。path 省略時は `$SourceVaultKeyBundleDefaultPath`。読めない/存在しない場合は `Status->"Error"`, `Reason->"UnreadableOrMissing"`。

## At-Rest Encrypted Record (SourceVault_encryptedstore.wl)

encrypt-then-MAC を NBAccess KeyRef 経由で行う (鍵材料は SourceVault に出ない)。AAD (Authenticated Associated Data) に Policy/Derived など判定駆動 metadata を含め、改ざんを HMAC で検出する。失敗時 (wrong key / MAC mismatch / 改ざん) は plaintext を返さない。record schema v3。本フェーズの record store は in-kernel (`$iSVEncStore`) であり、JSONL 永続化は未実装。

### $SourceVaultPrivateThreshold
型: Real, 初期値: `0.75`
private 判定の PrivacyLevel 閾値。これ以上で plaintext index / digest を抑制する。

### SourceVaultEncryptedPut[obj, opts]
obj を encrypt-then-MAC した record (schema v3) を作り、既定で in-kernel store に保存し、結果 Association を返す。plaintext は保存しない。保存前に `SourceVaultAssertNoPlaintextLeak` で漏洩検査を行い、検出時は `Status->"Error"`, `Reason->"PlaintextLeakDetected"` で保存しない。
→ Association (`Status`: "Stored"|"Error", 成功時 `RecordId`, `Record`, `PlaintextPersisted`->False, `PlaintextReturned`->False)
Options: "KeyRef" -> Automatic (既定 `$SourceVaultDefaultAtRestKeyRef`), "MACKeyRef" -> Automatic (既定 `$SourceVaultDefaultAtRestMACKeyRef`), "ContentType" -> "Generic", "PrivacyLevel" -> Automatic (既定 `$SourceVaultPrivateThreshold`), "AccessTags" -> {}, "SensitiveFields" -> {"Prompt", "Memo", "TargetExprString", "ResolvedMaterial"} (漏洩検査対象フィールド), "CloudSendAllowed" -> False, "Persist" -> True (False で store に保存せず record だけ返す), "PlaintextDigest" -> Automatic, "PlaintextIndex" -> Automatic
鍵未初期化時は `Status->"Error"`, `Reason->"KeysNotInitialized"` (`SourceVaultInitializeEncryption[]` を先に実行するようヒントを返す)。暗号化失敗は `Reason->"EncryptFailed"`。PrivacyLevel が `$SourceVaultPrivateThreshold` 以上の場合、`PlaintextDigest`/`PlaintextIndex` は Suppressed になる (低 privacy では keyed HMAC-SHA256 digest を付す)。生成 record の Policy は `RequiresLocalDecrypt->True`, `DeclassifyRequired->True` を含む。

### SourceVaultEncryptedGet[recordId_String] → Association | Missing["NotFound"]
保存済み暗号 record を返す (plaintext は返さない)。in-kernel store `$iSVEncStore` から検索する。

### SourceVaultDecryptRecord[record, opts] → Association
MAC 検証後に復号し plaintext を返す。失敗時は `Status->"Error"` (`Reason`: "UnsupportedVersion"|"MalformedRecord"|"AuthenticationFailed"|"WrongKey") で plaintext を返さない。成功時は `Status->"Ok"`, `PlaintextReturned->True`, `Plaintext`。

### SourceVaultEncryptedRecordQ[record] → Boolean
SourceVault 暗号 record (Type="SourceVaultEncryptedRecord" かつ Encryption["Ciphertext"] が String) か判定する。

### SourceVaultAssertNoPlaintextLeak[record, plaintextObj, sensitiveFields_List] → Association
serialized record (InputForm 文字列) に sensitiveFields の機密平文値が現れないか検査する。→ `<|"NoLeak"->Boolean, "Leaked"->{...}|>`。

### SourceVaultSealPayload[expr, opts]
任意の WL 式を `<|"Payload"->expr|>` として encrypt-then-MAC で封印した record を返す。ClaudeRuntime のジョブ I/O 等、式単位の at-rest 封印に使う。内部で `SourceVaultEncryptedPut` に委譲し、"Persist"->False, "ContentType"->"RuntimePayload", "SensitiveFields"->{"Payload"} を強制する。
→ Association (`Status->"Stored"`, `Record`, ...)
Options: `SourceVaultEncryptedPut` と同じ (上記の3項目を除き上書き可)

### SourceVaultUnsealPayload[record] → Association
`SourceVaultSealPayload` の record を MAC 検証後に復号し `<|"Status"->"Ok", "PlaintextReturned"->True, "Payload"->expr|>` を返す。record が該当形式でない場合は `Reason->"NotEncryptedRecord"`。改ざん・wrong key 時は `SourceVaultDecryptRecord` のエラーをそのまま返す (plaintext なし)。

## Cloud Materialization ゲート (SourceVault_release.wl)

暗号化/private record を cloud route へ materialize (= 平文化して送信) する唯一経路で必ず通すゲート。fail-closed: 条件が満たせない・不明・PrivacyLevel 欠落は Deny。

cloud route の判定条件 (すべて必要):
1. record `Policy["CloudSendAllowed"] === True`
2. `Policy["RequiresLocalDecrypt"] =!= True`
3. PrivacyLevel <= cloud threshold
4. Declassify または明示承認 (ApprovalTicket) がある
5. (任意強制) NBAuthorize が Permit

local route は対象外 (ローカル復号は RequiresLocalDecrypt と矛盾しない)。PrivacyLevel は Policy/Derived の最大値を採用し、欠落時は fail-safe で 1.0 (最高) とみなす。

### $SourceVaultCloudThreshold
型: Real, 初期値: `0.5`
cloud route に平文を出してよい PrivacyLevel 上限。

### SourceVaultAuthorizeRecordMaterialization[record, targetRoute, purpose_:"Materialize", opts]
record を targetRoute ("cloud"|"local"|文字列に"cloud"を含む|`<|"Kind"->...|>` または `<|"Route"->...|>` 形式の Association) へ平文化してよいか判定する。cloud route では CloudSendAllowed / RequiresLocalDecrypt / PrivacyLevel / Declassify / (任意)NBAuthorize を fail-closed で評価する。
→ Association (`Decision`: "Allow"|"Deny", `Reasons`->{...理由コード}, `CloudRoute`->Boolean, cloud時は `PrivacyLevel`, `Threshold` も含む)
Options: "Declassify" -> False, "ApprovalTicket" -> None (None/False 以外なら declassify 扱い), "CloudThreshold" -> Automatic (既定 `$SourceVaultCloudThreshold`), "RequireNBAuthorize" -> False, "NBAuthorizeDecision" -> Automatic ("Permit"|"Deny" 等を渡す)
Reasons の理由コード例: "MalformedRecord", "CloudSendNotAllowed", "RequiresLocalDecrypt", "AbovePrivacyThreshold", "NoDeclassifyOrApproval", "NBAuthorizeNotPermitted", "NBAuthorizeDenied"。local route の場合は `Reasons->{"LocalRoute"}` で常に Allow。

### SourceVaultMaterializeRecord[record, targetRoute, purpose_:"Materialize", opts]
materialization を認可した場合のみ復号 plaintext を返す。拒否時は plaintext を返さない。内部で `SourceVaultAuthorizeRecordMaterialization` → 認可時のみ `SourceVaultDecryptRecord` を呼ぶ。
→ Association (`Status`: "Denied"|"Error"|"Ok", 拒否時 `Reasons`, `CloudRoute`, `PlaintextReturned->False`; 復号失敗時 `Reason`, `PlaintextReturned->False`; 成功時 `Plaintext`, `CloudRoute`)
Options: `SourceVaultAuthorizeRecordMaterialization` と同じ