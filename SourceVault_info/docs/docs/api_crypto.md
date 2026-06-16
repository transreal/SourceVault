# SourceVault_crypto API リファレンス

リポジトリ: https://github.com/transreal/SourceVault_crypto
依存: [NBAccess](https://github.com/transreal/NBAccess) / [NBAccess_crypto](https://github.com/transreal/NBAccess_crypto)

ロード順序:
```
Block[{$CharacterEncoding="UTF-8"},
  Get["NBAccess_crypto.wl"];
  Get["SourceVault_crypto.wl"];
  Get["SourceVault_keys.wl"];
  Get["SourceVault_keybundle.wl"];
  Get["SourceVault_encryptedstore.wl"];
  Get["SourceVault_release.wl"]]
```

全シンボルは `SourceVault`` コンテキスト。鍵材料は戻り値・ログに出ない。失敗時は `Status->"Error"` を返す (例外を投げない)。

## 暗号基盤 (SourceVault_crypto.wl)

### SourceVaultCryptoCapabilityReport[] → Association
この Wolfram 環境の暗号能力 (AEAD/GCM, RSA-PSS, HMAC) を実測し、既定 IntegrityMode を含む Association を返す。WL 14.3 実測では GCM/AEAD 不可・RSA-PSS 不可のため IntegrityMode は "EncryptThenMAC" が既定となる。

### SourceVaultCanonicalJSONBytes[expr] → ByteArray
expr を再帰的に KeySort した canonical JSON (UTF-8) の ByteArray を返す。共有・署名・MAC の安定 bytes に使う (Interoperable JSON profile)。

### SourceVaultCanonicalBytes[expr, profile_:"Internal"] → ByteArray
profile="Internal" は BinarySerialize (ローカル at-rest payload 用)、"JSON" は SourceVaultCanonicalJSONBytes に委譲する。

### SourceVaultCryptoSelfTest[] → Association
capability probe・canonical 決定性・encrypt-then-MAC roundtrip・改ざん検出を検査し、結果 Association を返す。

## 鍵 Bootstrap (SourceVault_keys.wl)

### $SourceVaultDefaultAtRestKeyRef
型: String, 初期値: "SourceVault:master:atrest:v1"
at-rest 暗号鍵 KeyRef。SymmetricKey 種別、rotation-stable=False。

### $SourceVaultDefaultAtRestMACKeyRef
型: String, 初期値: "SourceVault:master:mac:v1"
at-rest MAC 鍵 KeyRef (暗号鍵とは別)。Mac 種別、rotation-stable=False。

### $SourceVaultDefaultPlaintextHMACKeyRef
型: String, 初期値: "SourceVault:pthmac:digest:v1"
plaintext digest HMAC 鍵 KeyRef。Mac 種別、rotation-stable=True。

### $SourceVaultDefaultMailIdentityHMACKeyRef
型: String, 初期値: "SourceVault:mailid:mac:v1"
mail RecordId / header token HMAC 鍵 KeyRef。Mac 種別、rotation-stable=True。

### $SourceVaultDefaultAddressBookMACKeyRef
型: String, 初期値: "SourceVault:addressbook:mac:v1"
AddressBook email/handle token HMAC 鍵 KeyRef。Mac 種別、rotation-stable=True。

### $SourceVaultDefaultCapsuleQuarantineMACKeyRef
型: String, 初期値: "SourceVault:capsule:quarantine-mac:v1"
受信 capsule の local at-rest quarantine MAC 鍵 KeyRef。Mac 種別、rotation-stable=False。

### $SourceVaultDefaultBaselineMACKeyRef
型: String, 初期値: "SourceVault:baseline:policy-mac:v1"
Trusted Baseline local MAC 鍵 KeyRef。Mac 種別、rotation-stable=False。

### $SourceVaultDefaultBaselineSigningKeyRef
型: String, 初期値: "SourceVault:baseline:policy-sign:v1"
Trusted Baseline owner 署名鍵 KeyRef。Asymmetric 種別、rotation-stable=False。

### $SourceVaultDefaultSelfPrivateKeyRef
型: String, 初期値: "SourceVault:self:private:v1"
自分の envelope 復号 (capsule) 用秘密鍵 KeyRef。Asymmetric 種別、rotation-stable=False。

### $SourceVaultDefaultSelfSigningKeyRef
型: String, 初期値: "SourceVault:signing:sign:v1"
自分の capsule 署名鍵 KeyRef。Asymmetric 種別、rotation-stable=False。

### SourceVaultInitializeEncryption[opts]
欠落している標準鍵だけを NBAccess crypto 層経由で生成する冪等 bootstrap。既存鍵は破壊しない。鍵材料は返さない。
→ Association: `<|"Type"->"SourceVaultInitializeEncryptionResult", "Status"->_, "DryRun"->_, "CreatedKeyRefs"->_, "ExistingKeyRefs"->_, "MissingKeyRefs"->_, "KeyMaterialReturned"->False, "RequiresUserApproval"->False|>`
Options: "DryRun" -> False (True で生成せず不足 KeyRef のみ列挙)

### SourceVaultEncryptionKeyStatus[] → Association
標準 KeyRef ごとに `<|"Exists"->_, "Kind"->_, "RotationStable"->_, "Purpose"->_, "Fingerprint"->_|>` を値とする Association を返す。鍵材料は含まない。

## 鍵バンドル (SourceVault_keybundle.wl)

### $SourceVaultKeyBundleDefaultPath
型: String (動的評価)
鍵バンドルの既定パス。`FileNameJoin[{$HomeDirectory, "SourceVault_keybundle.svkeys"}]` (Dropbox 外)。

### SourceVaultExportKeyBundle[passphrase, opts]
標準マスター鍵を passphrase で包んだ可搬バンドルをファイルに書く。scrypt (2^17, ~128MB) で 64B 派生し、先頭 32B=AES256 ラップ鍵・末尾 32B=HMAC-SHA256 MAC 鍵として encrypt-then-MAC する。鍵材料は返さない。
→ Association: `<|"Status"->"Exported"|"Error", "Path"->_, "KeyRefs"->_, "KeyCount"->_, "Fingerprints"->_, "KDF"->_, "CreatedAt"->_, "OnSyncFolderWarning"->_, "KeyMaterialReturned"->False|>`
Options: "Path" -> Automatic (既定 $SourceVaultKeyBundleDefaultPath), "KeyRefs" -> Automatic (既定=標準鍵全件), "ScryptN" -> Automatic (既定 131072), "Force" -> False (True で弱 passphrase 許可)

例: `SourceVaultExportKeyBundle["my-long-passphrase", "Force"->True, "Path"->"/tmp/bk.svkeys"]`

### SourceVaultImportKeyBundle[passphrase, opts]
バンドルを passphrase で解錠し、各鍵を現マシンの credential store に書き戻す。誤 passphrase / 改ざんは MAC 検証で拒否 (fail-closed)。鍵材料は返さない。
→ Association: `<|"Status"->"Imported"|"Error", "RestoredKeyRefs"->_, "RestoredCount"->_, "Backend"->_, "Fingerprints"->_|>`
Options: "Path" -> Automatic (既定 $SourceVaultKeyBundleDefaultPath)

### SourceVaultKeyBundleInfo[path_String : Automatic] → Association
passphrase 無しで読める非秘密メタ (Version/CreatedAt/KeyRefs/KDF) を返す。`<|"Status"->"Ok"|"Error", "Path"->_, "Version"->_, "CreatedAt"->_, "KeyRefs"->_, "KeyCount"->_, "KDF"->_|>`

## 暗号化ストア (SourceVault_encryptedstore.wl)

### $SourceVaultPrivateThreshold
型: Real, 初期値: 0.75
private 判定の PrivacyLevel 閾値。これ以上で plaintext index / digest を抑制する。

### SourceVaultEncryptedPut[obj, opts]
obj を encrypt-then-MAC した record を作り (既定で in-kernel store に保存)、結果 Association を返す。plaintext は保存しない。AAD に Policy/Derived metadata を含め改ざんを HMAC で検出する。PrivacyLevel >= $SourceVaultPrivateThreshold で PlaintextDigest/PlaintextIndex を抑制。
→ Association: `<|"Status"->"Stored"|"Error", "RecordId"->_, "Record"->_, "PlaintextPersisted"->False, "PlaintextReturned"->False|>`
Options: "KeyRef" -> Automatic ($SourceVaultDefaultAtRestKeyRef), "MACKeyRef" -> Automatic ($SourceVaultDefaultAtRestMACKeyRef), "ContentType" -> "Generic", "PrivacyLevel" -> Automatic ($SourceVaultPrivateThreshold), "AccessTags" -> {}, "SensitiveFields" -> {"Prompt","Memo","TargetExprString","ResolvedMaterial"}, "CloudSendAllowed" -> False, "Persist" -> True, "PlaintextDigest" -> Automatic, "PlaintextIndex" -> Automatic

例: `SourceVaultEncryptedPut[<|"Prompt"->"secret"|>, "ContentType"->"Memo", "PrivacyLevel"->0.9]`

### SourceVaultEncryptedGet[recordId_String] → Association | Missing
保存済み暗号 record を in-kernel store から返す。plaintext は返さない。未発見時は `Missing["NotFound"]`。

### SourceVaultDecryptRecord[record] → Association
MAC 検証後に復号し plaintext を返す。失敗時は Status->"Error"、PlaintextReturned->False。
→ `<|"Status"->"Ok"|"Error", "PlaintextReturned"->_, "Plaintext"->_|>`

### SourceVaultEncryptedRecordQ[record] → True | False
record が SourceVault 暗号 record (Type="SourceVaultEncryptedRecord", Encryption/Ciphertext を持つ Association) か判定する。

### SourceVaultAssertNoPlaintextLeak[record, plaintextObj, sensitiveFields_List] → Association
serialized record に sensitiveFields の平文文字列値が現れないか検査する。
→ `<|"NoLeak"->True|False, "Leaked"->{...}|>`

### SourceVaultSealPayload[expr, opts]
任意の WL 式を `<|"Payload"->expr|>` として encrypt-then-MAC で封印した record を返す。ClaudeRuntime のジョブ I/O 等、式単位の at-rest 封印に使う。既定で in-kernel store には保存しない。
→ SourceVaultEncryptedPut と同形の Association (Status->"Stored")
Options: SourceVaultEncryptedPut の全 option を継承。"Persist"->False, "ContentType"->"RuntimePayload", "SensitiveFields"->{"Payload"} が既定で上書き。

### SourceVaultUnsealPayload[record] → Association
SourceVaultSealPayload の record を MAC 検証後に復号し Payload を返す。改ざん / wrong key 時は Status->"Error" で plaintext を返さない。
→ `<|"Status"->"Ok"|"Error", "PlaintextReturned"->_, "Payload"->_|>`

## Materialization ゲート (SourceVault_release.wl)

### $SourceVaultCloudThreshold
型: Real, 初期値: 0.5
cloud route に平文を出してよい PrivacyLevel 上限。

### SourceVaultAuthorizeRecordMaterialization[record, targetRoute, purpose_:"Materialize", opts]
record を targetRoute ("cloud" | "local" | 任意 Association) へ平文化してよいか判定する。cloud route では以下をすべて fail-closed で評価する: (1) CloudSendAllowed===True、(2) RequiresLocalDecrypt=!=True、(3) PrivacyLevel <= CloudThreshold、(4) Declassify or ApprovalTicket あり、(5) RequireNBAuthorize=True なら NBAuthorizeDecision="Permit"。local route は常に Allow。PrivacyLevel 欠落は fail-safe で 1.0 とみなす。
→ `<|"Decision"->"Allow"|"Deny", "Reasons"->_, "CloudRoute"->_, "PrivacyLevel"->_, "Threshold"->_|>`
Options: "Declassify" -> False, "ApprovalTicket" -> None, "CloudThreshold" -> Automatic ($SourceVaultCloudThreshold), "RequireNBAuthorize" -> False, "NBAuthorizeDecision" -> Automatic

例:
```
SourceVaultAuthorizeRecordMaterialization[
  record, "cloud", "Materialize",
  "Declassify"->True, "CloudThreshold"->0.6]
```

### SourceVaultMaterializeRecord[record, targetRoute, purpose_:"Materialize", opts]
materialization を認可した場合のみ SourceVaultDecryptRecord で復号し plaintext を返す。Deny 時は plaintext を返さない。
→ `<|"Status"->"Ok"|"Denied"|"Error", "PlaintextReturned"->_, "Plaintext"->_, "CloudRoute"->_, "Reasons"->_|>`
Options: SourceVaultAuthorizeRecordMaterialization と同一