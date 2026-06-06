# api_crypto.md — SourceVault_crypto API リファレンス

SourceVault 暗号基盤。encrypt-then-MAC を primary とする at-rest 暗号化、鍵 bootstrap、可搬鍵バンドル、cloud materialization ゲートを提供する。鍵材料は NBAccess 層 (KeyRef) の外に出さず、戻り値・ログ・record にも出さない。依存: [NBAccess](https://github.com/transreal/NBAccess), [NBAccess_crypto](https://github.com/transreal/NBAccess_crypto)。

ロード順: NBAccess_crypto.wl → SourceVault_crypto.wl。暗号能力・canonical bytes・鍵 bootstrap・可搬鍵バンドル・at-rest 暗号 record・cloud materialization ゲートはすべて `SourceVault_crypto.wl` に統合済み (旧 SourceVault_keys/keybundle/encryptedstore/release.wl は廃止)。`Block[{$CharacterEncoding = "UTF-8"}, Get[...]]` でロード。全公開シンボルは context `SourceVault\``。

## 暗号能力 / canonical bytes

### SourceVaultCryptoCapabilityReport[] → Association
この WL 環境の暗号能力 (AEAD/GCM, RSA-PSS, HMAC) を実測し、既定 IntegrityMode を含む Association を返す。WL 14.3 では GCM/AEAD 不可・RSA-PSS Method 指定不可のため EncryptThenMAC が既定 primary となる。

### SourceVaultCanonicalJSONBytes[expr] → ByteArray
expr を再帰的に KeySort した canonical JSON (UTF-8) の ByteArray を返す。共有・署名・MAC の安定 bytes に使う (Interoperable JSON profile)。

### SourceVaultCanonicalBytes[expr, profile_:"Internal"] → ByteArray
canonical bytes を返す。profile="Internal" は BinarySerialize (ローカル at-rest payload 用)、profile="JSON" は SourceVaultCanonicalJSONBytes に委譲。

### SourceVaultCryptoSelfTest[] → Association
capability probe・canonical 決定性・encrypt-then-MAC roundtrip・改ざん検出を検査し、結果 Association を返す。

## 鍵 bootstrap

### SourceVaultInitializeEncryption[opts]
欠落している標準鍵だけを生成する冪等 bootstrap。既存鍵は破壊しない。鍵材料は返さない。
→ Association: Type, Status ("AlreadyInitialized"|"Initialized"|"Partial"), DryRun, CreatedKeyRefs, ExistingKeyRefs, MissingKeyRefs, KeyMaterialReturned (常に False), RequiresUserApproval (False)
Options: "DryRun" -> False (True で生成せず計画のみ、Status は欠落あれば "Partial")

### SourceVaultEncryptionKeyStatus[] → Association
標準 KeyRef ごとに <|Exists, Kind, RotationStable, Purpose, Fingerprint|> を返す (鍵材料なし)。Fingerprint は未生成時 Missing["NotGenerated"]。

標準 KeyRef 変数 (型: String、値は KeyRef 文字列):
### $SourceVaultDefaultAtRestKeyRef
"SourceVault:master:atrest:v1" — at-rest 暗号鍵 (Symmetric, rotationStable=False)。
### $SourceVaultDefaultAtRestMACKeyRef
"SourceVault:master:mac:v1" — at-rest MAC 鍵 (Mac, False)。暗号鍵とは別。
### $SourceVaultDefaultPlaintextHMACKeyRef
"SourceVault:pthmac:digest:v1" — plaintext digest HMAC 鍵 (Mac, rotationStable=True)。
### $SourceVaultDefaultMailIdentityHMACKeyRef
"SourceVault:mailid:mac:v1" — mail RecordId/header token HMAC 鍵 (Mac, True)。
### $SourceVaultDefaultAddressBookMACKeyRef
"SourceVault:addressbook:mac:v1" — AddressBook email/handle token HMAC 鍵 (Mac, True)。
### $SourceVaultDefaultCapsuleQuarantineMACKeyRef
"SourceVault:capsule:quarantine-mac:v1" — 受信 capsule local quarantine MAC 鍵 (Mac, False)。
### $SourceVaultDefaultBaselineMACKeyRef
"SourceVault:baseline:policy-mac:v1" — Trusted Baseline local MAC 鍵 (Mac, False)。
### $SourceVaultDefaultBaselineSigningKeyRef
"SourceVault:baseline:policy-sign:v1" — Trusted Baseline owner 署名鍵 (Asymmetric, False)。
### $SourceVaultDefaultSelfPrivateKeyRef
"SourceVault:self:private:v1" — 自分の envelope 復号 (capsule) 用秘密鍵 (Asymmetric, False)。
### $SourceVaultDefaultSelfSigningKeyRef
"SourceVault:signing:sign:v1" — 自分の capsule 署名鍵 (Asymmetric, False)。

## 可搬鍵バンドル

passphrase から scrypt で 64B 派生 (先頭32B=AES256 ラップ鍵, 末尾32B=HMAC-SHA256 MAC 鍵)。各マスター鍵を NBExportWrappedKeys で暗号化し、bundle 全体を encrypt-then-MAC。誤 passphrase/改ざんは MAC 検証で fail-closed。既定で Dropbox 外 (ホーム直下) に書く。復元は BinaryDeserialize のみ (ToExpression 不使用)。

### SourceVaultExportKeyBundle[passphrase, opts]
標準マスター鍵を passphrase で包んだ可搬バンドルをファイルに書く。実在する鍵のみ対象。鍵材料は返さない。
→ Association: Status ("Exported"|"Error"), Path, KeyRefs, KeyCount, Fingerprints, KDF, CreatedAt, OnSyncFolderWarning (sync フォルダ検出で True), KeyMaterialReturned (False)。Error の Reason: "WeakPassphrase"|"NoKeysFound"|"KDFFailed"|"WrapFailed"
Options: "Path" -> Automatic ($SourceVaultKeyBundleDefaultPath), "KeyRefs" -> Automatic (標準鍵全部), "ScryptN" -> Automatic (131072 = 2^17), "Force" -> False (12文字未満の弱 passphrase を許可)
例: SourceVaultExportKeyBundle["correct horse battery staple xyz"]

### SourceVaultImportKeyBundle[passphrase, opts]
バンドルを passphrase で解錠し、各鍵を現マシンの credential store に書き戻す。誤 passphrase/改ざんは MAC 検証で拒否。
→ Association: Status ("Imported"|"Error"), Path, RestoredKeyRefs, RestoredCount, Backend, Fingerprints。Error の Reason: "UnreadableOrMissing"|"BadKDFParams"|"KDFFailed"|"BadPassphraseOrTampered"
Options: "Path" -> Automatic ($SourceVaultKeyBundleDefaultPath)

### SourceVaultKeyBundleInfo[path_:Automatic] → Association
passphrase 無しで読める非秘密メタを返す。Status ("Ok"|"Error"), Path, Version, CreatedAt, KeyRefs, KeyCount, KDF。読めない/不在は Reason "UnreadableOrMissing"。

### $SourceVaultKeyBundleDefaultPath
型: String, 値: FileNameJoin[{$HomeDirectory, "SourceVault_keybundle.svkeys"}]
鍵バンドルの既定パス (Dropbox 外)。

## at-rest 暗号 record

encrypt-then-MAC を NBAccess KeyRef 経由で実行。AAD に Policy/Derived など判定駆動 metadata を含め HMAC で改ざん検出。失敗時 (wrong key/MAC mismatch/改ざん) は plaintext を返さない。record store は in-kernel ($iSVEncStore)。schema v3。

### SourceVaultEncryptedPut[obj, opts]
obj を encrypt-then-MAC した record を作り (既定で in-kernel store に保存)、結果を返す。plaintext は保存しない。append 前に SourceVaultAssertNoPlaintextLeak で漏洩検査。
→ Association: Status ("Stored"|"Error"), RecordId, Record, PlaintextPersisted (False), PlaintextReturned (False)。Error の Reason: "KeysNotInitialized"|"EncryptFailed"|"PlaintextLeakDetected"
Options: "KeyRef" -> Automatic ($SourceVaultDefaultAtRestKeyRef), "MACKeyRef" -> Automatic ($SourceVaultDefaultAtRestMACKeyRef), "ContentType" -> "Generic", "PrivacyLevel" -> Automatic ($SourceVaultPrivateThreshold=0.75), "AccessTags" -> {}, "SensitiveFields" -> {"Prompt","Memo","TargetExprString","ResolvedMaterial"} (漏洩検査対象), "CloudSendAllowed" -> False, "Persist" -> True (False で store に保存せず record のみ返す), "PlaintextDigest" -> Automatic, "PlaintextIndex" -> Automatic
PrivacyLevel >= 0.75 で PlaintextDigest/PlaintextIndex を抑制 (Suppressed)。未満なら digest は keyed HMAC-SHA256 (rotation-stable)。
例: SourceVaultEncryptedPut[<|"Prompt"->"secret"|>, "PrivacyLevel"->0.9, "ContentType"->"MailBody"]

### SourceVaultEncryptedGet[recordId] → Association | Missing
保存済み暗号 record を返す (plaintext は返さない)。未登録は Missing["NotFound"]。

### SourceVaultDecryptRecord[record, opts] → Association
MAC 検証後に復号し plaintext を返す。
→ Status ("Ok"|"Error"), PlaintextReturned, Plaintext (BinaryDeserialize 済)。Error の Reason: "UnsupportedVersion"|"MalformedRecord"|"AuthenticationFailed"|"WrongKey"

### SourceVaultEncryptedRecordQ[record] → True|False
SourceVault 暗号 record か判定 (Type=="SourceVaultEncryptedRecord" かつ Encryption.Ciphertext が String)。

### SourceVaultAssertNoPlaintextLeak[record, plaintextObj, sensitiveFields_List] → Association
serialized record に機密平文が現れないか検査。plaintextObj の sensitiveFields にある非空 String 値が ToString[record,InputForm] に含まれないか確認。
→ <|"NoLeak" -> Bool, "Leaked" -> {...}|>

### $SourceVaultPrivateThreshold
型: Real, 初期値: 0.75
private 判定の PL 閾値。これ以上で plaintext index/digest を抑制する。

## cloud materialization ゲート

暗号化/private record を cloud route へ materialize (平文化して送信) する唯一経路。fail-closed: 条件未達・不明・PL 欠落は Deny。local route はローカル復号を許可する対象外。

### SourceVaultAuthorizeRecordMaterialization[record, targetRoute, purpose_:"Materialize", opts] → Association
record を targetRoute へ平文化してよいか判定。targetRoute は "cloud"|"local" 文字列、または "Kind"/"Route" キーを持つ Association ("cloud" を含めば cloud 扱い)。cloud route では全条件を fail-closed 評価。
→ <|"Decision" -> "Allow"|"Deny", "Reasons" -> {...}, "CloudRoute" -> Bool, "PrivacyLevel" -> _, "Threshold" -> _|>。Deny Reasons: "MalformedRecord"|"CloudSendNotAllowed"|"RequiresLocalDecrypt"|"AbovePrivacyThreshold"|"NoDeclassifyOrApproval"|"NBAuthorizeNotPermitted"|"NBAuthorizeDenied"。local route は常に Allow ("LocalRoute")。PrivacyLevel は Policy/Derived の最大、欠落は 1.0 (fail-safe)。
Options: "Declassify" -> False, "ApprovalTicket" -> None (None/False 以外で declassify 扱い), "CloudThreshold" -> Automatic ($SourceVaultCloudThreshold=0.5), "RequireNBAuthorize" -> False (True で Permit 必須), "NBAuthorizeDecision" -> Automatic ("Permit"|"Deny" 等)
cloud 許可条件 (すべて必要): CloudSendAllowed===True, RequiresLocalDecrypt=!=True, PrivacyLevel<=threshold, Declassify または ApprovalTicket, (任意) NBAuthorize が Permit。

### SourceVaultMaterializeRecord[record, targetRoute, purpose_:"Materialize", opts] → Association
認可した場合のみ復号 plaintext を返す。拒否時は plaintext を返さない。
→ Status ("Ok"|"Denied"|"Error"), PlaintextReturned, Plaintext, CloudRoute。Denied は Reasons (Authorize と同じ)、Error は Reason (DecryptRecord 由来)。
Options: SourceVaultAuthorizeRecordMaterialization と同一。
例: SourceVaultMaterializeRecord[rec, "cloud", "Share", "Declassify"->True, "CloudThreshold"->0.5]

### $SourceVaultCloudThreshold
型: Real, 初期値: 0.5
cloud route に平文を出してよい PrivacyLevel 上限。