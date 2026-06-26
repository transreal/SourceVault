# SourceVault_crypto — LLM 向け API リファレンス

パッケージ: `SourceVault`` (名前空間共有、複数ファイル構成)
GitHub: https://github.com/transreal/SourceVault_crypto

SourceVault の暗号基盤層。暗号能力レポート・canonical bytes・encrypt-then-MAC primitive・鍵 bootstrap・可搬鍵バンドル・暗号化 record ストア・cloud materialization ゲートを提供する。鍵材料は戻り値・ログに出さない (鍵隔離境界)。

## ロード順序

```wl
Block[{$CharacterEncoding = "UTF-8"},
  Get["NBAccess_crypto.wl"];
  Get["SourceVault_crypto.wl"];
  Get["SourceVault_keys.wl"];
  Get["SourceVault_keybundle.wl"];
  Get["SourceVault_encryptedstore.wl"];
  Get["SourceVault_release.wl"]]
```

## 依存関係

[NBAccess](https://github.com/transreal/NBAccess) / [NBAccess_crypto](https://github.com/transreal/NBAccess_crypto) — 鍵管理・暗号操作の下位層。NBAccess の `NBEncryptWithKeyRef`, `NBDecryptWithKeyRef`, `NBMacWithKeyRef`, `NBVerifyMacWithKeyRef`, `NBGenerateSymmetricKeyRef`, `NBGenerateMacKeyRef`, `NBGenerateAsymmetricKeyRefPair`, `NBKeyStatus`, `NBExportWrappedKeys`, `NBImportWrappedKeys` を使用する。

## 暗号基盤 (SourceVault_crypto.wl)

### SourceVaultCryptoCapabilityReport[] → Association
この Wolfram 環境の暗号能力 (AEAD/GCM, RSA-PSS, HMAC) を実測し、既定 IntegrityMode を含む Association を返す。WL 14.3 では GCM/AEAD 不可のため IntegrityMode は `"EncryptThenMAC"` となる。

### SourceVaultCanonicalJSONBytes[expr] → ByteArray
expr を再帰的に KeySort した canonical JSON (UTF-8) の ByteArray を返す。共有・署名・MAC の安定 bytes に使う (Interoperable JSON profile)。

### SourceVaultCanonicalBytes[expr, profile_:"Internal"] → ByteArray
canonical bytes を返す。profile `"Internal"` は `BinarySerialize` (ローカル at-rest payload 用)、`"JSON"` は `SourceVaultCanonicalJSONBytes` に委譲する。

### SourceVaultCryptoSelfTest[] → Association
capability probe・canonical 決定性・encrypt-then-MAC roundtrip・改ざん検出を検査し、結果 Association を返す。

### SourceVaultHMACSHA256Hex[keyBA_ByteArray, msgBA_ByteArray] → String
RFC2104 HMAC-SHA256 を hex 文字列で返す。AccessGrant 署名等の MAC に使う公開ラッパー。

### SourceVaultConstantTimeEqualQ[a_String, b_String] → True|False
2つの hex/文字列を best-effort 定数時間で比較する (署名検証用)。

## 鍵 Bootstrap (SourceVault_keys.wl)

### 標準 KeyRef 変数

### $SourceVaultDefaultAtRestKeyRef
型: String, 初期値: `"SourceVault:master:atrest:v1"`
at-rest 暗号鍵 KeyRef。

### $SourceVaultDefaultAtRestMACKeyRef
型: String, 初期値: `"SourceVault:master:mac:v1"`
at-rest MAC 鍵 KeyRef (暗号鍵とは別)。

### $SourceVaultDefaultPlaintextHMACKeyRef
型: String, 初期値: `"SourceVault:pthmac:digest:v1"`
plaintext digest HMAC 鍵 KeyRef (rotation-stable)。

### $SourceVaultDefaultMailIdentityHMACKeyRef
型: String, 初期値: `"SourceVault:mailid:mac:v1"`
mail RecordId / header token HMAC 鍵 KeyRef (rotation-stable)。

### $SourceVaultDefaultAddressBookMACKeyRef
型: String, 初期値: `"SourceVault:addressbook:mac:v1"`
AddressBook email/handle token HMAC 鍵 KeyRef (rotation-stable)。

### $SourceVaultDefaultCapsuleQuarantineMACKeyRef
型: String, 初期値: `"SourceVault:capsule:quarantine-mac:v1"`
受信 capsule の local at-rest quarantine MAC 鍵 KeyRef。

### $SourceVaultDefaultBaselineMACKeyRef
型: String, 初期値: `"SourceVault:baseline:policy-mac:v1"`
Trusted Baseline local MAC 鍵 KeyRef。

### $SourceVaultDefaultBaselineSigningKeyRef
型: String, 初期値: `"SourceVault:baseline:policy-sign:v1"`
Trusted Baseline owner 署名鍵 KeyRef。

### $SourceVaultDefaultSelfPrivateKeyRef
型: String, 初期値: `"SourceVault:self:private:v1"`
自分の envelope 復号 (capsule) 用秘密鍵 KeyRef。

### $SourceVaultDefaultSelfSigningKeyRef
型: String, 初期値: `"SourceVault:signing:sign:v1"`
自分の capsule 署名鍵 KeyRef。

### SourceVaultInitializeEncryption[opts]
欠落している標準鍵だけを生成する冪等 bootstrap。鍵材料は返さない。既存鍵は破壊しない。
→ Association: `<|"Type"->"SourceVaultInitializeEncryptionResult", "Status"->_, "DryRun"->_, "CreatedKeyRefs"->{...}, "ExistingKeyRefs"->{...}, "MissingKeyRefs"->{...}, "KeyMaterialReturned"->False, "RequiresUserApproval"->False|>`
Options: `"DryRun" -> False` (True で実際の鍵生成を行わず不足一覧のみ返す)

### SourceVaultEncryptionKeyStatus[] → Association
標準 KeyRef の存在状況 (鍵材料なし) を返す。各 KeyRef をキーとし `<|"Exists"->_, "Kind"->_, "RotationStable"->_, "Purpose"->_, "Fingerprint"->_|>` の Association を値とする。

## 可搬鍵バンドル (SourceVault_keybundle.wl)

鍵を passphrase (scrypt KDF) で包んでファイルに書き出し、別マシンで復元する仕組み。bundle は encrypt-then-MAC 済み。鍵材料は戻り値・ログに出ない。

### $SourceVaultKeyBundleDefaultPath
型: String (動的評価)
鍵バンドルの既定パス。`FileNameJoin[{$HomeDirectory, "SourceVault_keybundle.svkeys"}]` — Dropbox 等の同期フォルダ外。

### SourceVaultExportKeyBundle[passphrase_String, opts]
標準マスター鍵を passphrase で包んだ可搬バンドルをファイルに書く。鍵材料は返さない。passphrase が 12 文字未満で `"Force"->False` の場合はエラーを返す。Dropbox 等の同期フォルダへの書き込みは警告 (`"OnSyncFolderWarning"->True`) を返す。
→ Association: `<|"Status"->"Exported"|"Error", "Path"->_, "KeyRefs"->{...}, "KeyCount"->_, "Fingerprints"->_, "KDF"-><|"Function"->"scrypt","N"->_|>, "CreatedAt"->_, "OnSyncFolderWarning"->_, "KeyMaterialReturned"->False|>`
Options:
- `"Path" -> Automatic` (既定 `$SourceVaultKeyBundleDefaultPath`)
- `"KeyRefs" -> Automatic` (既定 = 標準 KeyRef 全種)
- `"ScryptN" -> Automatic` (既定 131072 = 2^17, ~128MB)
- `"Force" -> False` (True で弱 passphrase を許可)

例: `SourceVaultExportKeyBundle["diceware-six-words-here", "Path" -> "/media/usb/sv.svkeys"]`

### SourceVaultImportKeyBundle[passphrase_String, opts]
バンドルを passphrase で解錠し、各鍵を現マシンの credential store に書き戻す。誤 passphrase / 改ざんは MAC 検証で拒否 (fail-closed)。鍵材料は返さない。
→ Association: `<|"Status"->"Imported"|"Error", "Path"->_, "RestoredKeyRefs"->{...}, "RestoredCount"->_, "Backend"->_, "Fingerprints"->_|>`
Options: `"Path" -> Automatic` (既定 `$SourceVaultKeyBundleDefaultPath`)

### SourceVaultKeyBundleInfo[path_String : Automatic] → Association
passphrase 無しで読める非秘密メタ (Version/CreatedAt/KeyRefs/KDF) を返す。
→ `<|"Status"->"Ok"|"Error", "Path"->_, "Version"->_, "CreatedAt"->_, "KeyRefs"->{...}, "KeyCount"->_, "KDF"->_|>`

## 暗号化 Record ストア (SourceVault_encryptedstore.wl)

encrypt-then-MAC (NBAccess keyRef 経由) で at-rest 暗号化。AAD に policy metadata を含め改ざんを HMAC で検出。失敗時は plaintext を返さない。in-kernel ストア `$iSVEncStore` を使用 (JSONL 永続化は後フェーズ)。

### $SourceVaultPrivateThreshold
型: Real, 初期値: `0.75`
private 判定の PrivacyLevel 閾値。これ以上の PL では plaintext index / digest を抑制する。

### SourceVaultEncryptedPut[obj_, opts]
obj を encrypt-then-MAC した record を作り (既定で in-kernel store に保存)、結果 Association を返す。plaintext は保存しない。PL >= `$SourceVaultPrivateThreshold` では PlaintextDigest/PlaintextIndex を抑制。plaintext 漏洩検出 (`SourceVaultAssertNoPlaintextLeak`) を実行し検出時はエラー返却。
→ `<|"Status"->"Stored"|"Error", "RecordId"->_, "Record"->_, "PlaintextPersisted"->False, "PlaintextReturned"->False|>`
Options:
- `"KeyRef" -> Automatic` (既定 `$SourceVaultDefaultAtRestKeyRef`)
- `"MACKeyRef" -> Automatic` (既定 `$SourceVaultDefaultAtRestMACKeyRef`)
- `"ContentType" -> "Generic"` (record のコンテンツ種別ラベル)
- `"PrivacyLevel" -> Automatic` (既定 `$SourceVaultPrivateThreshold`)
- `"AccessTags" -> {}` (Derived.AccessTags に格納)
- `"SensitiveFields" -> {"Prompt","Memo","TargetExprString","ResolvedMaterial"}` (漏洩検査対象フィールド名)
- `"CloudSendAllowed" -> False` (Policy.CloudSendAllowed)
- `"Persist" -> True` (False で in-kernel store に保存しない)
- `"PlaintextDigest" -> Automatic`
- `"PlaintextIndex" -> Automatic`

例: `SourceVaultEncryptedPut[<|"Body" -> "secret"|>, "PrivacyLevel" -> 0.9, "ContentType" -> "Mail"]`

### SourceVaultEncryptedGet[recordId_String] → Association | Missing
保存済み暗号 record を返す (plaintext は返さない)。未存在は `Missing["NotFound"]`。

### SourceVaultDecryptRecord[record_] → Association
MAC 検証後に復号し、plaintext を返す。失敗時は `Status -> "Error"` で plaintext を返さない。
→ 成功: `<|"Status"->"Ok", "PlaintextReturned"->True, "Plaintext"->_|>`
→ 失敗: `<|"Status"->"Error", "Reason"->_, "PlaintextReturned"->False|>` (Reason: `"UnsupportedVersion"` | `"MalformedRecord"` | `"AuthenticationFailed"` | `"WrongKey"`)

### SourceVaultEncryptedRecordQ[record_] → True | False
SourceVault 暗号 record か判定する。`Type == "SourceVaultEncryptedRecord"` かつ `Encryption.Ciphertext` が String であることを確認する。

### SourceVaultAssertNoPlaintextLeak[record_, plaintextObj_, sensitiveFields_List] → Association
serialized record に機密平文が現れないか検査する。
→ `<|"NoLeak"->True|False, "Leaked"->{...}|>`
plaintextObj が Association の場合、sensitiveFields に対応する String 値のみ検査する。

### SourceVaultSealPayload[expr_, opts]
任意の WL 式を `<|"Payload"->expr|>` として encrypt-then-MAC で封印した record を返す。`"Persist"->False`, `"ContentType"->"RuntimePayload"`, `"SensitiveFields"->{"Payload"}` を強制設定。opts は `SourceVaultEncryptedPut` と同じ。
→ `<|"Status"->"Stored"|"Error", "RecordId"->_, "Record"->_, ...|>`

### SourceVaultUnsealPayload[record_] → Association
`SourceVaultSealPayload` の record を MAC 検証後に復号し `<|"Status"->"Ok", "Payload"->expr|>` を返す。改ざん・wrong key 時は `Status->"Error"` で plaintext を返さない。
→ 成功: `<|"Status"->"Ok", "PlaintextReturned"->True, "Payload"->_|>`
→ 失敗: `<|"Status"->"Error", "Reason"->_, "PlaintextReturned"->False|>`

## Cloud Materialization ゲート (SourceVault_release.wl)

暗号化/private record を cloud route へ平文化して送信する唯一の経路。fail-closed: 条件不明・PL 欠落は Deny。local route は対象外。

### $SourceVaultCloudThreshold
型: Real, 初期値: `0.5`
cloud route に平文を出してよい PrivacyLevel 上限。record の PrivacyLevel がこれ以下でなければ Deny。

### SourceVaultAuthorizeRecordMaterialization[record_, targetRoute_, purpose_String:"Materialize", opts]
record を targetRoute へ平文化してよいか判定する。cloud route の場合は 5 条件を fail-closed で評価する:
1. `Policy.CloudSendAllowed === True`
2. `Policy.RequiresLocalDecrypt =!= True`
3. `PrivacyLevel <= CloudThreshold` (欠落は 1.0 とみなす)
4. Declassify または ApprovalTicket がある
5. (オプション) `NBAuthorize` が Permit

local route は無条件 Allow。
→ `<|"Decision"->"Allow"|"Deny", "Reasons"->{...}, "CloudRoute"->_, "PrivacyLevel"->_, "Threshold"->_|>`
Options:
- `"Declassify" -> False` (True で条件4を満たす)
- `"ApprovalTicket" -> None` (None 以外で条件4を満たす)
- `"CloudThreshold" -> Automatic` (既定 `$SourceVaultCloudThreshold`)
- `"RequireNBAuthorize" -> False` (True で NBAuthorize Permit を必須にする)
- `"NBAuthorizeDecision" -> Automatic` (`"Permit"` | `"Deny"` | Automatic)

targetRoute の cloud 判定: String に `"cloud"` (大小無視) を含む場合、または Association の `"Kind"` / `"Route"` キーが `"cloud"` を含む場合に cloud route とみなす。

例: `SourceVaultAuthorizeRecordMaterialization[rec, "cloud", "Materialize", "Declassify"->True, "CloudThreshold"->0.4]`

### SourceVaultMaterializeRecord[record_, targetRoute_, purpose_String:"Materialize", opts]
materialization を認可した場合のみ復号 plaintext を返す。拒否時は plaintext を返さない。内部で `SourceVaultAuthorizeRecordMaterialization` → `SourceVaultDecryptRecord` の順に実行する。
→ 成功: `<|"Status"->"Ok", "PlaintextReturned"->True, "Plaintext"->_, "CloudRoute"->_|>`
→ 拒否: `<|"Status"->"Denied", "Reasons"->{...}, "CloudRoute"->_, "PlaintextReturned"->False|>`
→ 復号失敗: `<|"Status"->"Error", "Reason"->_, "PlaintextReturned"->False|>`
Options: `SourceVaultAuthorizeRecordMaterialization` と同じ。

## Record スキーマ (SchemaVersion 3)

`SourceVaultEncryptedPut` が生成する record の主要フィールド:

```
<|
  "Type" -> "SourceVaultEncryptedRecord",
  "SchemaVersion" -> 3,
  "RecordId" -> "svrec-<uuid>",
  "ContentType" -> _String,
  "CreatedAt" -> _String,
  "Encryption" -> <|
    "Backend" -> "WolframLanguageNative",
    "Mode" -> "SymmetricAtRest",
    "KeyRef" -> _String,
    "MACKeyRef" -> _String,
    "PayloadCanonicalization" -> "SourceVaultCanonicalBytes/Internal/v1",
    "IntegrityMode" -> "EncryptThenMAC",
    "IV" -> _String,        (* Base64 *)
    "Ciphertext" -> _String, (* Base64 *)
    "AuthenticatedAssociatedData" -> <|...|>,
    "CiphertextChecksum" -> <|"Algorithm"->"SHA256", "Value"->_String, ...|>,
    "CiphertextHMAC" -> <|"Algorithm"->"HMAC-SHA256", "Value"->_|>,
    "PlaintextDigest" -> <|"Mode"->"Suppressed"|"HMAC-SHA256", ...|>
  |>,
  "PlaintextIndex" -> <|"IndexPolicy"->"Suppressed"|"PublicOnly", ...|>,
  "Policy" -> <|"PrivacyLevel"->_, "CloudSendAllowed"->_, "RequiresLocalDecrypt"->True, "DeclassifyRequired"->True|>,
  "Derived" -> <|"PrivacyLevel"->_, "AccessTags"->{...}, "DenyTags"->{}|>,
  "Provenance" -> <|"CreatedBy"->"SourceVaultEncryptedPut"|>
|>