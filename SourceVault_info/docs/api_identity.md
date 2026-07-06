# api_identity.md — SourceVault_identity

SourceVault の identity 層。2層アドレス帳(識別子/実体)、送信者認証(authserv-id pinning)、返信/共有の release planning を提供する。`BeginPackage["SourceVault`", {"NBAccess`"}]`。鍵は NBAccess 外に出さず Token は AddressBook MAC 鍵の HMAC。永続化は JSONL。

設計原則: identity resolution は security boundary ではない。自動作成 contact は fail-closed (MaxPlaintextPL 0.0, TrustStatus Observed/Unverified)。送信者由来 feature の loosening は認証 pass 時のみ。

## 識別子 (第1層 Identifier)
raw な email/SNS/URI を1レコード。メール取込で From/To/Cc を自動登録(冪等)。IdentifierId は (kind, 正規化値) から決定的(鍵非依存)。

### SourceVaultObserveIdentifier[kind_String, rawValue_String, opts]
識別子(Email/SNS/URI…)を登録/更新し IdentifierId を返す。冪等(同じ kind+正規化値なら同 ID で upsert; ObservedNames/Provenance を追記、Count++)。Email/その他は ToLowerCase、URI はそのまま正規化。空値は Missing["EmptyValue"]。
→ String (IdentifierId 例 "idf-email-xxxxxxxxxxxxxxxx") | Missing
Options: "ObservedName" -> Missing[] (観測名), "MBox" -> Missing[] (Provenance), "Persist" -> False (保存)

### SourceVaultIngestAddressHeader[header_String, opts]
ヘッダ文字列("Name <a@x>, …")から全アドレスを Email 識別子として登録し IdentifierId のリストを返す。SourceVaultMailParseEmails でパース、各アドレスに表示名を ObservedName 付与。
→ List (IdentifierId のリスト、失敗時 {})
Options: "MBox" -> Missing[], "Persist" -> False
例: SourceVaultIngestAddressHeader["Taro <taro@x.jp>, jiro@y.jp", "MBox" -> "INBOX"]

### SourceVaultGetIdentifier[id_String] → Association | Missing["NotFound"]
識別子レコードを返す。

### SourceVaultListIdentifiers[] → List
全識別子レコードを返す。

### SourceVaultFindIdentifier[kind_String, value_String] → Association | Missing["NotFound"]
正規化値で識別子を返す。

### SourceVaultResolveIdentifierDisplay[identifierId_String] → String | Missing
表示名を返す(実体 DisplayName → 観測名 → raw 値 の優先順)。

### SourceVaultUnlinkIdentifier[identifierId_String, opts]
識別子を実体から外す(EntityRef を Missing["Unlinked"] に戻し、実体 Identifiers から除去)。
→ Association(<|"Status"->"Unlinked"|> / "Error"+"Reason")
Options: "Persist" -> True

識別子レコード構造: <|"Type"->"SourceVaultIdentifier", "SchemaVersion"->1, "IdentifierId", "Kind", "Value"(正規化), "ObservedNames"(List), "Token"(HMAC/Missing["NoKey"]), "FirstSeen", "LastSeen", "Count", "Provenance"(List), "EntityRef"(EntityId/Missing["Unlinked"])|>

## 実体 (第2層 Entity)
人/組織/Bot/ML/サービス。識別子を束ねる。後からマージ可。EntityUid は採番(self=1)。

### SourceVaultPutEntity[entity_Association, opts]
実体を登録/更新し EntityId を返す。EntityUid 未指定なら採番、EntityId 未指定なら "ent-<uid>"。DisplayName 未指定は Names の Kanji→Romaji→id で補完。ContactAccessProfile 未指定は fail-closed プロファイル。Identifiers の各識別子へ EntityRef を張る。
→ String (EntityId)
Options: "Persist" -> True

### SourceVaultUpdateEntity[idOrUid, updates_Association, opts]
実体フィールドを更新(updates が既存を上書き、Join 後 PutEntity)。
→ Association(<|"Status"->"Updated", "EntityId", "EntityUid"|> / "Error"+"Reason"->"EntityNotFound")
Options: "Persist" -> True

### SourceVaultGetEntity[idOrUid] → Association | Missing["NotFound"]
実体レコードを返す。idOrUid は String(EntityId) または Integer(EntityUid)。

### SourceVaultListEntities[] → List
全実体を EntityUid 昇順で返す。

### SourceVaultLinkIdentifierToEntity[identifierId_String, entityId_String]
識別子を実体に紐付ける(双方向)。既に別実体にリンク済みなら旧実体の Identifiers から外して付け替え(=マージ)。
→ Association(<|"Status"->"Linked", "EntityId", "IdentifierId"|> / "Error"+"Reason"->"EntityNotFound"|"IdentifierNotFound")

### SourceVaultIdentifierCreateEntity[identifierId_String, opts]
識別子から新規実体を作成し継承(DisplayName=観測名 or Value)してリンクする。
→ Association(<|"Status"->"Created", "EntityId", "EntityUid", "DisplayName"|> / "Error"+"Reason")
Options: "Kind" -> "Person", "DisplayName" -> Automatic (Automatic は観測名→Value), "Names" -> Automatic (Automatic は <||>), "Persist" -> True

実体レコード構造: <|"Type"->"SourceVaultEntity", "SchemaVersion"->1, "EntityUid"(Int), "EntityId", "Kind"(既定"Person"), "Identifiers"(List), "MemberOf", "Categories"(List), "Group", "PriorityWeight", "ContactAccessProfile"(Assoc), "DisplayName", "Names"(<|"Kanji","Romaji",…|>), ["OwnerKind", "LLMProfile", "PrimaryEmail", "SuggestedIdentifierRefs", "RejectedIdentifierRefs", "EvidenceSummary"]|>

ContactAccessProfile(fail-closed 既定): <|"EstimatedAccessPL"->0.0, "MaxPlaintextPL"->0.0, "AccessTags"->{}, "DenyTags"->{"NoEmailUnlessDeclassified"}, "TrustStatus"->"Observed", "Confidence"->0.0|>

## 所有者 (Self / OwnerKind=Self / EntityUid=1)
アクセサは内部で SourceVaultIdentityEnsureLoaded を呼ぶ。

### SourceVaultOwnerEntity[] → Association | Missing["NoOwner"]
所有者(EntityUid=1 か OwnerKind=Self)の実体を返す。

### SourceVaultOwnerEmails[] → List
所有者にリンクされた全メールアドレス(正規化、重複排除)を返す。

### SourceVaultOwnerPrimaryEmail[] → String | Missing
プライマリメール(PrimaryEmail フィールド優先、無ければ Emails 先頭)。Missing["NoOwner"]/Missing["NoEmail"]。

### SourceVaultOwnerLLMProfile[] → String
所有者実体の LLMProfile(LLM プロンプト用受信者プロフィール文)。未設定は ""。

### SourceVaultSetOwnerLLMProfile[text_String, opts]
所有者の LLMProfile を設定。
→ Association(UpdateEntity 結果 / "Error"+"Reason"->"NoOwner")
Options: "Persist" -> True

### SourceVaultSetOwnerPrimaryEmail[email_String, opts]
所有者のプライマリメールを設定(ToLowerCase/Trim)。
→ Association(UpdateEntity 結果 / "Error"+"Reason"->"NoOwner")
Options: "Persist" -> True

## 永続化 / 初期化
JSONL(ISO8859-1, RawJSON Compact)。{identifiers.jsonl, entities.jsonl}。Missing/$Failed は Null で書き、load 時に Missing へ復元。

### SourceVaultIdentitySave[] → Association
識別子/実体を JSONL に永続化。<|"Status"->"Saved", "Identifiers", "Entities"|>。

### SourceVaultIdentityLoad[] → Association
JSONL から読み込み($iSVIDLoaded=True)。<|"Status"->"Loaded", "Identifiers", "Entities"|>。

### SourceVaultIdentityInitialize[] → Association
load + self(Imai, EntityUid=1) bootstrap。冪等。<|"Status"->"Initialized", "Identifiers", "Entities", "SelfUid"|>。

### SourceVaultIdentityEnsureLoaded[] → Association
未ロードなら Initialize。<|"Status"->"AlreadyLoaded"|> など。

### SourceVaultIdentityBootstrapSelf[opts]
self を EntityUid=1 として登録(addressbook self 連絡先を継承)。既にあれば何もしない。私的 email はハードコードせず addressbook self→Email オプション の順で解決。
→ Association(<|"Status"->"Bootstrapped"|"AlreadyExists", "EntityId", "EntityUid", "IdentifierId"|>)
Options: "Email" -> Automatic, "Persist" -> True

### SourceVaultIdentityStorePaths[] → List
{identifiers.jsonl, entities.jsonl} の絶対パスを返す。

### $SourceVaultIdentityRoot
型: String, 初期値: 未設定(PrivateVault/identity)
identity の保存ルート。テストで上書き可。

## 所有関係リンク整合性 (identity-tag spec §1.2/§9.1)
forward(Identifier.EntityRef)と reverse(Entity.Identifiers)は通常 SourceVaultLinkIdentifierToEntity/PutEntity が同時更新するが、部分ロード・手動編集・migration・クラッシュで乖離しうる。衝突時は Identifier.EntityRef を正とする。

### SourceVaultRecomputeOwnershipLinks[opts] → Association
Identifier.EntityRef ⇄ Entity.Identifiers の双方向リンクを全走査で整合再計算する。dangling 参照は除去、欠落した逆/順リンクは補完、両側の食い違いは Identifier.EntityRef を正として解決する。UpdateEntitySummary->True(既定)なら event log の EntityLinkProposal から各 Entity の SuggestedIdentifierRefs/RejectedIdentifierRefs/EvidenceSummary(再生成可能な projection)も再生成する(mining/core 未ロード時は skip)。
→ <|"Status"->"OK", "IdentifierCount", "EntityCount", "RepairCount", "RepairKinds"(Association; "DanglingEntityRef"|"MissingReverseLink"|"DanglingIdentifierRef"|"ConflictResolvedByIdentifier"|"MissingForwardLink" 別カウント), "Repairs"(List、先頭50件), "EntitySummaryUpdated"(Int), "Persisted"(Bool)|>
Options: "Persist" -> False (修復または summary 更新があった場合のみ save), "UpdateEntitySummary" -> True, "EventLimit" -> 5000

### SourceVaultScheduleOwnershipRefresh[opts] → Association
SourceVaultRecomputeOwnershipLinks["Persist"->True] を ScheduledTask(SessionSubmit)でカーネル内定期実行する。冪等: 再呼出は既存タスクを TaskRemove して差し替える。
→ <|"Status"->"Scheduled", "IntervalSeconds", "Task"|> | <|"Status"->"Removed"|>
Options: "IntervalSeconds" -> 21600 (6時間), "Remove" -> False (True で解除のみ、再登録しない)

## 送信者認証 (senderauth, spec v18 §24)
From は認証なしには信用できない。信頼する authserv-id が付けた Authentication-Results のみ採用(authserv-id pinning)。Tightening(PL 上げ/DenyTag 追加)は認証なしでも可。Loosening(PL 下げ/平文化/cloud summary/DenyTag 除去)は認証 pass 時のみ。

### SourceVaultParseAuthenticationResults[arHeader_String] → List
Authentication-Results 文字列(改行区切り複数可)を解析。各要素 <|"AuthservId", "DKIM", "SPF", "DMARC", "ARC"(各 "Pass"|"Fail"|"None"|"Neutral"|"Unknown"), "DKIMDomain", "FromDomain"|>。非文字列入力は {}。

### SourceVaultSenderAuthentication[record_Association, opts]
メール record から SenderAuthentication 判定 metadata を作る。record の "Authentication-Results"/"authentication-results"/"AuthenticationResults" と "from" を参照。信頼 authserv-id(TrustedAuthservIds)の A-R のみ採用、偽装 inline A-R は無視。
→ Association: <|"Source"("Missing"|"UntrustedAuthservId"|"TrustedPinnedAuthservId"), "DKIM", "SPF", "DMARC", "ARC", "Trusted"(Bool), "AuthservId", "AlignedFromDomain", "AuthenticatedIdentity"|>
Options: "TrustedAuthservIds" -> Automatic (Automatic は $SourceVaultTrustedAuthservIds)
aligned 判定: DMARC=Pass で FromDomain/from、または DKIM=Pass かつ DKIMDomain===fromDomain。

### SourceVaultSenderAuthenticatedQ[auth_Association] → Bool
loosening に使える認証が成立しているか。True 条件: auth["Trusted"] かつ (DMARC=Pass、または DKIM=Pass かつ AlignedFromDomain が文字列)。非 Association は False。

### SourceVaultSenderFeatureUseQ[auth, direction_String] → Bool
送信者由来 feature をその方向に使ってよいか。direction "Tightening" は常に True、"Loosening" は SourceVaultSenderAuthenticatedQ[auth] のとき True。その他は False。

### $SourceVaultTrustedAuthservIds
型: List, 初期値: {}
受信側が信頼する authserv-id のリスト(自分の受信 MX/provider)。fail-closed: 未登録なら sender-based loosening 不可。

## Release planning (messagerelease, spec v18 §10.9.7)
外部メール送信は保存と同じ release boundary。各 material を recipient profile + tag policy + transport + public key で plaintext/encrypted capsule/redaction に分類。自動送信しない(Decision 既定 DraftOnly)。tag policy は Deny-wins、階層/wildcard、未知/未充足は fail-closed。

### SourceVaultTagPolicyEvaluate[material_Association, recipient_Association, purpose_String] → Association
tag ベースのアクセス可否を Deny-wins/fail-closed で判定。判定順: ①material AccessTags が $SourceVaultSystemDenyTags と交差→Deny(NoExternalTag) ②recipient DenyTags と交差→Deny(TagDenied) ③purpose が recipient PurposeAllowed に無い→Deny(PurposeDenied) ④required tag(":" 含む or "RequiresNDA")を AccessTags で階層込み充足しない→Deny(MissingRequiredTag) ⑤Allow。
→ <|"Decision"("Allow"|"Deny"), "ReasonClass", "PublicReason"|>
required 充足: "RequiresNDA" は "NDA:Signed"、完全一致、または "Prefix:*" wildcard。

### SourceVaultResolveRecipientProfile[emailOrProfile] → Association
受信者を ContactAccessProfile に解決。Association はそのまま返す。String は SourceVaultAddressBookFindByEmail で解決、未知は fail-closed(MaxPlaintextPL 0.0)。
→ <|"Email", "ContactId", "MaxPlaintextPL", "MaxEncryptedReadablePL", "AccessTags", "DenyTags", "PurposeAllowed", "TrustStatus", "PublicKeyVerified"(TrustStatus=Verified かつ PublicKeyRecordRef あり), "UsesSourceVault"(OwnerKind≠ExternalCollaborator)|>

### SourceVaultPlanMessageRelease[spec_Association] → Association
spec の Recipients/Purpose/Transport/Materials から material を plaintext/capsule/redaction に分類した release plan を返す。本文平文は全 recipient で PL<=Min(transportMax, recipient MaxPlaintextPL) かつ tag Allow のとき。不可なら recipient 単位で capsule(要 PublicKeyVerified+UsesSourceVault かつ PL<=MaxEncryptedReadablePL)、それ以外は redaction。既定 DraftOnly・自動送信不可。
→ <|"Decision"->"DraftOnly", "PlaintextMaterials"(List of Ref), "EncryptedCapsules"(List of <|"Recipient", "Materials"|>), "RedactedMaterials"(List of <|"Material", "Recipient", "Reason"|>), "Audit"(<|"TransportMaxPlaintextPL", "Purpose", "RecipientCount", "RequiresHumanConfirmation"->True, "AutoSendAllowed"->False|>)|>
spec 構造: <|"Recipients"(email/profile List), "Purpose"(既定"Reply"), "Transport"-><|"MaxPlaintextPL"(既定0.45)|>, "Materials"(List of <|"Ref", "PL", "AccessTags"|>)|>

### $SourceVaultSystemDenyTags
型: List, 初期値: {"NoEmail", "NoExternal", "StudentPrivate", "Personal"}
外部送信を既定で禁止するシステム deny tag。

## 依存
[NBAccess](https://github.com/transreal/NBAccess)(MAC 鍵/HMAC、crypto)。AddressBook 機能(SourceVaultAddressBookFindByEmail/ListContacts、$SourceVaultDefaultAddressBookMACKeyRef)、SourceVaultMailParseEmails、$SourceVaultRoots["PrivateVault"] に依存。SourceVaultRecomputeOwnershipLinks の Entity summary 再生成は SourceVault_mining(SourceVaultReplayEntityLinkProposals)、SourceVault_core(SourceVaultTransactionLog) と弱結合(未ロード時は skip)。