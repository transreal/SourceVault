# SourceVault_identity API リファレンス

パッケージ: `SourceVault`` (コンテキスト共有)
依存: [NBAccess](https://github.com/transreal/NBAccess)
GitHub: [SourceVault_identity](https://github.com/transreal/SourceVault_identity)

2層アドレス帳・送信者認証・release planning を提供する。第1層 Identifier は raw な email/SNS/URI を1レコードとして冪等登録する。第2層 Entity は人/組織/Bot/ML/サービスを表し識別子を束ねる。所有者 (Self) は EntityUid=1 で bootstrap する。Token は AddressBook MAC 鍵の HMAC であり鍵は NBAccess 外に出さない。

## 送信者認証

### $SourceVaultTrustedAuthservIds
型: List, 初期値: {}
受信側が信頼する authserv-id のリスト。未登録なら sender-based loosening 不可 (fail-closed)。

### SourceVaultParseAuthenticationResults[arHeader] → List
Authentication-Results 文字列を解析し `<|AuthservId, DKIM, SPF, DMARC, ARC, DKIMDomain, FromDomain|>` のリストを返す。

### SourceVaultSenderAuthentication[record, opts]
メール record (Association) から SenderAuthentication 判定 metadata を作る。信頼 authserv-id が付けた A-R のみ採用し偽装 inline A-R は無視する。
→ `<|Source, DKIM, SPF, DMARC, ARC, Trusted, AuthservId, AlignedFromDomain, AuthenticatedIdentity|>`
Options: "TrustedAuthservIds" -> Automatic ($SourceVaultTrustedAuthservIds を使用)

### SourceVaultSenderAuthenticatedQ[auth] → True|False
loosening に使える送信者認証が成立しているかを返す (DMARC=Pass、または DKIM=Pass かつ AlignedFromDomain が String)。

### SourceVaultSenderFeatureUseQ[auth, direction] → True|False
direction は `"Tightening"` または `"Loosening"`。Tightening は常に True、Loosening は SourceVaultSenderAuthenticatedQ が True の場合のみ True。

## 識別子操作

### SourceVaultObserveIdentifier[kind, rawValue, opts]
識別子を登録/更新し IdentifierId を返す。冪等。kind は `"Email"` 等の文字列。Email は小文字正規化する。IdentifierId は (kind, 正規化値) から決定的に生成する。
→ IdentifierId (String) または Missing["EmptyValue"]
Options: "ObservedName" -> Missing[] (観測名、重複なく追記), "MBox" -> Missing[] (provenance mbox), "Persist" -> False

### SourceVaultIngestAddressHeader[header, opts]
ヘッダ文字列 (`"Name <a@x>, ..."`) から全アドレスを識別子として登録し IdentifierId のリストを返す。
→ List[IdentifierId]
Options: "MBox" -> Missing[], "Persist" -> False

### SourceVaultGetIdentifier[identifierId] → Association|Missing
識別子レコードを返す。無ければ Missing["NotFound"]。

### SourceVaultListIdentifiers[] → List
全識別子レコードのリストを返す。

### SourceVaultFindIdentifier[kind, value] → Association|Missing
正規化値で識別子を検索する。無ければ Missing["NotFound"]。

### SourceVaultResolveIdentifierDisplay[identifierId] → String|Missing
表示名を返す。解決順: 実体の DisplayName → 識別子の ObservedNames 先頭 → raw 値。

## 実体操作

### SourceVaultPutEntity[entity, opts]
実体 (Association) を登録/更新し EntityId を返す。EntityUid 未指定なら自動採番。Identifiers リスト内の各識別子に EntityRef を張る。ContactAccessProfile 未指定は fail-closed (MaxPlaintextPL 0.0, TrustStatus "Observed") になる。DisplayName 未指定は Names.Kanji → Names.Romaji → EntityId の順で設定する。
→ EntityId (String)
Options: "Persist" -> True
例: `SourceVaultPutEntity[<|"Kind" -> "Person", "DisplayName" -> "山田太郎", "Names" -> <|"Kanji" -> "山田太郎", "Romaji" -> "Yamada Taro"|>, "Identifiers" -> {"idf-email-xxxx"}|>]`

### SourceVaultGetEntity[entityIdOrUid] → Association|Missing
実体レコードを返す。String なら EntityId 検索、Integer なら EntityUid 検索。

### SourceVaultListEntities[] → List
全実体を EntityUid 昇順で返す。

### SourceVaultUpdateEntity[entityIdOrUid, updates, opts]
実体のフィールドを更新する (updates が既存を上書き)。
→ `<|Status, EntityId, EntityUid|>`
Options: "Persist" -> True

### SourceVaultLinkIdentifierToEntity[identifierId, entityId]
識別子を実体に双方向で紐付ける。既に別実体にリンク済みなら付け替え (旧実体の Identifiers から削除、新実体に追加)。
→ `<|Status, EntityId, IdentifierId|>`

### SourceVaultIdentifierCreateEntity[identifierId, opts]
識別子から新規実体を作成し継承してリンクする。DisplayName は ObservedNames 先頭 → raw 値の順で継承する。
→ `<|Status, EntityId, EntityUid, DisplayName|>`
Options: "Kind" -> "Person", "DisplayName" -> Automatic, "Names" -> Automatic (空 Association), "Persist" -> True

### SourceVaultUnlinkIdentifier[identifierId, opts]
識別子を実体から外す (EntityRef を Missing["Unlinked"] に戻し、実体の Identifiers から削除する)。
→ `<|Status, IdentifierId|>`
Options: "Persist" -> True

## 所有者アクセサ

### SourceVaultOwnerEntity[] → Association|Missing
OwnerKind=Self (EntityUid=1) の実体を返す。未ロードなら SourceVaultIdentityEnsureLoaded を呼び出す。

### SourceVaultOwnerEmails[] → List
所有者にリンクされた全メールアドレス (正規化済み小文字、重複除去) を返す。

### SourceVaultOwnerPrimaryEmail[] → String|Missing
所有者のプライマリメールを返す。PrimaryEmail フィールド優先、無ければ Identifiers 先頭。

### SourceVaultOwnerLLMProfile[] → String
所有者の LLMProfile (LLM プロンプト用受信者プロフィール文) を返す。未設定は ""。

### SourceVaultSetOwnerLLMProfile[text, opts]
所有者の LLMProfile を設定する。
→ `<|Status, EntityId, EntityUid|>`
Options: "Persist" -> True

### SourceVaultSetOwnerPrimaryEmail[email, opts]
所有者のプライマリメールを設定する (小文字正規化)。
→ `<|Status, EntityId, EntityUid|>`
Options: "Persist" -> True

## 永続化・初期化

### $SourceVaultIdentityRoot
型: String|Unset
identity の保存ルート。既定は `PrivateVault/identity`。テスト時に一時ディレクトリへ上書きできる。

### SourceVaultIdentityStorePaths[] → {String, String}
`{identifiers.jsonl, entities.jsonl}` のパスを返す。

### SourceVaultIdentitySave[] → Association
識別子/実体を JSONL に永続化する (Missing/$Failed は Null として保存)。
→ `<|Status -> "Saved", Identifiers, Entities|>`

### SourceVaultIdentityLoad[] → Association
JSONL から識別子/実体を読み込む ($iSVIDLoaded を True に設定)。
→ `<|Status -> "Loaded", Identifiers, Entities|>`

### SourceVaultIdentityInitialize[] → Association
load + self (EntityUid=1) bootstrap。冪等。
→ `<|Status -> "Initialized", Identifiers, Entities, SelfUid|>`

### SourceVaultIdentityEnsureLoaded[] → Association
未ロードなら SourceVaultIdentityInitialize を呼び出す。import が既存を上書きしないための guard として使う。

### SourceVaultIdentityBootstrapSelf[opts]
self を EntityUid=1 で登録する (既存 addressbook self 連絡先から Names/DisplayName を継承)。既に存在すれば何もしない。メールアドレスはハードコードせず addressbook self → "Email" オプション → なしの順で決定する。
→ `<|Status, EntityId, EntityUid, IdentifierId|>`
Options: "Email" -> Automatic, "Persist" -> True

## タグポリシー・Release Planning

### $SourceVaultSystemDenyTags
型: List, 初期値: {"NoEmail", "NoExternal", "StudentPrivate", "Personal"}
外部送信を既定で禁止するシステム deny tag。material にこれらが含まれると DualApproval なしには送信不可になる。

### SourceVaultTagPolicyEvaluate[material, recipient, purpose]
tag ベースのアクセス可否を Deny-wins / fail-closed で判定する。material, recipient は Association、purpose は String。
→ `<|Decision ("Allow"|"Deny"), ReasonClass, PublicReason|>`
判定順: (1) material の AccessTags が $SourceVaultSystemDenyTags に含まれる → Deny (ReasonClass "NoExternalTag"), (2) material tag が recipient DenyTags に一致 → Deny ("TagDenied"), (3) purpose が recipient PurposeAllowed に含まれない → Deny ("PurposeDenied"), (4) 必須 tag (`:` 含む tag または RequiresNDA) が recipient AccessTags で未充足 → Deny ("MissingRequiredTag"), (5) Allow。

### SourceVaultResolveRecipientProfile[emailOrProfile] → Association
受信者を ContactAccessProfile に解決する。Association ならそのまま返す。String (email) なら AddressBook から検索し未知は fail-closed (MaxPlaintextPL 0.0) を返す。
返す Association キー: Email, MaxPlaintextPL, MaxEncryptedReadablePL, AccessTags, DenyTags, PurposeAllowed, TrustStatus, PublicKeyVerified (TrustStatus=Verified かつ PublicKeyRecordRef 有り), UsesSourceVault。

### SourceVaultPlanMessageRelease[spec]
Recipients/Purpose/Transport/Materials から各 material を plaintext/capsule/redaction に分類した release plan を返す。自動送信しない (Decision 常に "DraftOnly")。
→ `<|Decision -> "DraftOnly", PlaintextMaterials, EncryptedCapsules, RedactedMaterials, Audit|>`
spec キー: "Recipients" (email String のリストまたは profile Association のリスト), "Purpose" (String、既定 "Reply"), "Transport" (`<|"MaxPlaintextPL" -> 0.45|>` 等), "Materials" (Association のリスト、各要素に "Ref", "PL", "AccessTags" 等)。
plaintext 条件: 全 recipient で `material PL <= Min[transport MaxPlaintextPL, recipient MaxPlaintextPL]` かつ tag Allow。capsule 条件: tag Allow かつ `PL <= MaxEncryptedReadablePL` かつ `PublicKeyVerified && UsesSourceVault`。いずれも満たさなければ redaction。
例:
```
SourceVaultPlanMessageRelease[<|
  "Recipients" -> {"alice@example.com"},
  "Purpose" -> "Reply",
  "Transport" -> <|"MaxPlaintextPL" -> 0.45|>,
  "Materials" -> {<|"Ref" -> "body", "PL" -> 0.3, "AccessTags" -> {}|>}
|>]