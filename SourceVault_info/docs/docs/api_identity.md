# SourceVault_identity API Reference

## 概要
SourceVault の identity/宛先解決サブシステム。4つの層で構成される。
- AddressBook: 連絡先 (ContactRecord) を保持する第0層。自分 (Self, Uid=1) を最初の連絡先として登録し、PL推定・release planningのidentity sourceとする。
- SenderAuth: メールのFromは認証なしに信用できないため、Authentication-Resultsヘッダをauthserv-id pinningで検証する。
- Identity (2層アドレス帳): 第1層Identifier(識別子=raw email/SNS/URI、メール取込で自動登録・冪等)と第2層Entity(実体=人/組織/Bot/ML/サービス、識別子を束ねる)。selfはEntityUid=1としてbootstrap。
- MessageRelease: 外部メール送信を保存と同じrelease boundaryとして扱い、recipient profile + tag policy + transportからmaterialをplaintext/encrypted capsule/redactionに分類する。自動送信はしない(既定DraftOnly)。

設計原則: identity resolutionはsecurity boundaryではない。自動作成contactはfail-closed(MaxPlaintextPL 0.0)。tag policyはDeny-wins、階層/wildcard対応、未知/未充足はfail-closed。鍵はNBAccess外に出さない。

## AddressBook (連絡先)
連絡先の登録・検索・永続化。email照合はraw正規化 + keyed HMAC token (SourceVault:addressbook:mac:v1) による。

### SourceVaultAddressBookPutContact[contact_Association, opts] → ContactId
連絡先を登録/更新し、Uid/ContactId/EmailTokensを補完して保存する。

### SourceVaultAddressBookRegisterSelf[email_String, opts] → ContactId
自分(OwnerKind->Self, TrustStatus->Verified)を連絡先として登録する。最初ならUid=1。

### SourceVaultAddressBookGetContact[contactIdOrUid] → Association
連絡先を返す。

### SourceVaultAddressBookFindByEmail[email_String] → Association | Missing
emailで連絡先を返す(正規化/トークン照合)。無ければMissing。

### SourceVaultAddressBookFindByName[query_String] → List
氏名(漢字/ローマ字/かな の3表記横断、部分一致)で連絡先のリストを返す。日本人名はかな表記が検索キー。

### SourceVaultAddressBookListContacts[] → List
全連絡先をUid昇順で返す。

### SourceVaultAddressBookSave[] → Association
連絡先をJSONLに永続化する。

### SourceVaultAddressBookLoad[] → Association
JSONLから連絡先を読み込む。

### SourceVaultAddressBookStorePath[] → String
contacts.jsonlのパスを返す。$SourceVaultAddressBookRootで上書き可。

### $SourceVaultAddressBookRoot
型: String | Automatic, 初期値: Automatic (PrivateVault/addressbook)
AddressBookの保存ルート。テスト時に一時ディレクトリへ上書きできる。

## SenderAuth (送信者認証)
Authentication-Resultsヘッダは送信者が任意に挿入できるため、受信側が信頼するauthserv-idが付けたものだけを採用する(authserv-id pinning)。
非対称ルール: PLを上げる/DenyTagを足す(tightening)は認証なしでも可。PLを下げる/平文ヘッダ化/cloud summary/DenyTagを外す(loosening)は認証(DMARC=Pass、またはDKIM=Passかつ From domain aligned)がpassの場合のみ。既存maildbはAuthentication-Resultsを保持しないためSource->"Missing"となりloosening不可(高PL維持)になる。

### SourceVaultParseAuthenticationResults[arHeader_String] → List
Authentication-Results文字列を`<|AuthservId, DKIM, SPF, DMARC, ARC, DKIMDomain, FromDomain|>`のリストに解析する。文字列でなければ`{}`。

### SourceVaultSenderAuthentication[record_Association, opts] → Association
メールrecordからSenderAuthentication判定metadataを作る。信頼authserv-id(TrustedAuthservIds)のA-Rのみ採用。戻り値キー: Source("Missing"|"UntrustedAuthservId"|"TrustedPinnedAuthservId"), DKIM, SPF, DMARC, ARC, Trusted, AuthservId, AlignedFromDomain, AuthenticatedIdentity。
Options: TrustedAuthservIds -> Automatic ($SourceVaultTrustedAuthservIdsを使用)

### SourceVaultSenderAuthenticatedQ[auth_Association] → Boolean
loosening に使える送信者認証が成立しているか(既定: DMARC=Pass、またはDKIM=Passかつaligned)。Association以外はFalse。

### SourceVaultSenderFeatureUseQ[auth, "Tightening"|"Loosening"] → Boolean
送信者由来featureをその方向に使ってよいか。Tighteningは常にTrue、Loosingは認証pass時のみ。

### $SourceVaultTrustedAuthservIds
型: List, 初期値: {}
受信側が信頼するauthserv-idのリスト(自分の受信MX/provider)。fail-closed: 未登録ならsender-based loosening不可。

## Identity (2層アドレス帳: Identifier / Entity)
第1層Identifier(識別子): raw なemail/SNS/URIを1レコード。メール取込でFrom/To/Ccを自動登録(判断不要・冪等)。EntityRefで実体へリンク(任意)。IdentifierIdは(kind, 正規化値)から決定的("idf-"+kind+SHA256先頭16文字)なので再取込でも冪等。
第2層Entity(実体): 人/組織/Bot/ML/サービス。識別子を束ねる。後からマージ可能。self(Imai)はEntityUid=1として最初にbootstrap(既存self連絡先を継承)。
キーは英語固定(i18n)。表示は呼び出し側でlocalize。

### SourceVaultObserveIdentifier[kind_String, value_String, opts] → IdentifierId
識別子(Email/SNS/URI等)を登録/更新しIdentifierIdを返す。冪等。空valueはMissing["EmptyValue"]。
Options: ObservedName -> Missing[] (観測名), MBox -> Missing[] (由来メールボックス), Persist -> False

### SourceVaultIngestAddressHeader[header_String, opts] → List
ヘッダ文字列("Name <a@x>, …")から全アドレスを識別子として登録しIdentifierIdのリストを返す。
Options: MBox -> Missing[], Persist -> False

### SourceVaultGetIdentifier[identifierId_String] → Association
識別子レコードを返す。

### SourceVaultListIdentifiers[] → List
全識別子を返す。

### SourceVaultFindIdentifier[kind_String, value_String] → Association | Missing
正規化値で識別子を返す。無ければMissing["NotFound"]。

### SourceVaultPutEntity[entity_Association, opts] → EntityId
実体(人/組織等)を登録/更新しEntityIdを返す。EntityUid未指定なら採番。Identifiers内の各IdentifierRefに対しEntityRefを張る(双方向同期)。ContactAccessProfile未指定はfail-closed(EstimatedAccessPL 0.0, MaxPlaintextPL 0.0, DenyTags {"NoEmailUnlessDeclassified"}, TrustStatus "Observed")。
Options: Persist -> True

### SourceVaultGetEntity[entityIdOrUid] → Association
実体レコードを返す。文字列ならEntityId、整数ならEntityUidで検索。

### SourceVaultListEntities[] → List
全実体をEntityUid昇順で返す。

### SourceVaultLinkIdentifierToEntity[identifierId_String, entityId_String] → Association
識別子を実体に紐付ける(双方向)。既に別実体にリンク済みなら付け替え(既存実体にアドレス追加=マージ)。戻り値`<|Status, EntityId, IdentifierId|>`。

### SourceVaultIdentifierCreateEntity[identifierId_String, opts] → Association
識別子から新規実体を作成し継承(DisplayName=観測名)してリンクする。戻り値`<|Status, EntityId, EntityUid, DisplayName|>`。
Options: Kind -> "Person", DisplayName -> Automatic (観測名優先、無ければ識別子Value), Names -> Automatic (->`<||>`), Persist -> True

### SourceVaultUnlinkIdentifier[identifierId_String, opts] → Association
識別子を実体から外す(EntityRefを未リンクに戻す)。
Options: Persist -> True

### SourceVaultUpdateEntity[entityIdOrUid, updates_Association, opts] → Association
実体のフィールドを更新する(updatesが既存を上書き)。実体が無ければ`<|Status->"Error", Reason->"EntityNotFound"|>`。
Options: Persist -> True

### SourceVaultOwnerEntity[] → Association | Missing
所有者(ユーザDB #1 / OwnerKind=Self)の実体を返す。未ロードなら自動でIdentityEnsureLoaded。無ければMissing["NoOwner"]。

### SourceVaultOwnerEmails[] → List
所有者にリンクされた全メールアドレス(正規化・重複除去)を返す。

### SourceVaultOwnerPrimaryEmail[] → String | Missing
所有者のプライマリメール(PrimaryEmailフィールド優先、無ければ先頭)を返す。

### SourceVaultOwnerLLMProfile[] → String
所有者実体のLLMProfile(LLMプロンプト用の受信者プロフィール文)を返す。未設定は""。

### SourceVaultSetOwnerLLMProfile[text_String, opts] → Association
所有者のLLMProfileを設定する。
Options: Persist -> True

### SourceVaultSetOwnerPrimaryEmail[email_String, opts] → Association
所有者のプライマリメールを設定する(小文字正規化)。
Options: Persist -> True

### SourceVaultResolveIdentifierDisplay[identifierId_String] → String | Missing
表示名を返す(実体DisplayName → 観測名 → raw値の優先順)。

### SourceVaultIdentitySave[] → Association
識別子/実体をJSONLに永続化する。戻り値`<|Status, Identifiers, Entities|>`(件数)。

### SourceVaultIdentityLoad[] → Association
JSONLから読み込む。戻り値`<|Status, Identifiers, Entities|>`(件数)。

### SourceVaultIdentityInitialize[] → Association
load + self(Imai, EntityUid=1) bootstrap。冪等。戻り値`<|Status, Identifiers, Entities, SelfUid|>`。

### SourceVaultIdentityEnsureLoaded[] → Association
未ロードならInitializeする(importが既存を上書きしないため)。

### SourceVaultIdentityBootstrapSelf[opts] → Association
selfをEntityUid=1として登録(既存self連絡先を継承)。既にあれば`<|Status->"AlreadyExists", EntityId|>`。email未指定はaddressbookのself連絡先→"NoEmail"の順で解決(ハードコードしない)。
Options: Email -> Automatic, Persist -> True

### SourceVaultIdentityStorePaths[] → {String, String}
`{identifiers.jsonl, entities.jsonl}`のパスを返す。

### $SourceVaultIdentityRoot
型: String | Automatic, 初期値: Automatic (PrivateVault/identity)
identityの保存ルート。テストで上書き可。

## Ownership Links 再計算 (identity-tag spec §1.2 / §9.1)
forward = Identifier.EntityRef、reverse = Entity.Identifiers。通常運用ではSourceVaultLinkIdentifierToEntity/PutEntityが両側を同時更新するが、部分ロード・手動編集・migration・クラッシュで乖離しうる。衝突時はIdentifier.EntityRefを正とする(確定リンクの所在はIdentifier側)。

### SourceVaultRecomputeOwnershipLinks[opts] → Association
オブジェクト間所有関係の双方向リンク(Identifier.EntityRef ⇄ Entity.Identifiers)を全走査で整合再計算する。dangling参照は除去、欠落した逆/順リンクは補完、両側の食い違いはIdentifier.EntityRefを正として解決する。UpdateEntitySummary->True(既定)ならevent logのEntityLinkProposalから各EntityのSuggestedIdentifierRefs/RejectedIdentifierRefs/EvidenceSummary(projection)も再生成する(SourceVault_mining/core未ロード時はskip)。戻り値`<|Status, IdentifierCount, EntityCount, RepairCount, RepairKinds, Repairs(先頭50件), EntitySummaryUpdated, Persisted|>`。
Options: Persist -> False (修復があった場合のみsave), UpdateEntitySummary -> True, EventLimit -> 5000

### SourceVaultScheduleOwnershipRefresh[opts] → Association
`SourceVaultRecomputeOwnershipLinks["Persist"->True]`をScheduledTask(SessionSubmit)でカーネル内定期実行する。冪等: 再呼出は既存タスクを差し替える。戻り値`<|Status, IntervalSeconds, Task|>`。
Options: IntervalSeconds -> 21600 (6時間), Remove -> False (Trueで解除のみ)

## Message Release Planning (Phase SV-E5 / spec v18 §10.9.7)
外部メール送信は保存と同じrelease boundary。各materialをrecipient profile(ContactAccessProfile) + tag policy + transport + public keyでplaintext(本文)/encrypted capsule(添付)/redactionに分類する。自動送信しない(Decision既定DraftOnly)。tag policyはDeny-wins、階層/wildcard、未知/未充足はfail-closed。

### SourceVaultTagPolicyEvaluate[material_Association, recipient_Association, purpose_String] → Association
tagベースのアクセス可否をDeny-wins/fail-closedで判定する。判定順: (1) material AccessTagsに$SourceVaultSystemDenyTagsが含まれれば即Deny("NoExternalTag") (2) material tagがrecipient DenyTagsに一致すればDeny("TagDenied") (3) purposeがrecipient PurposeAllowedに無ければDeny("PurposeDenied") (4) Project:/Role:/Person:/Course:/RequiresNDA等の階層tagがrecipient AccessTagsで満たされなければDeny("MissingRequiredTag")。全て通ればAllow。戻り値`<|Decision, ReasonClass, PublicReason|>`。

### SourceVaultResolveRecipientProfile[emailOrProfile] → Association
受信者をContactAccessProfileに解決する。Association渡しはそのまま返す。文字列(email)渡しはAddressBookから検索し、`<|Email, ContactId, MaxPlaintextPL, MaxEncryptedReadablePL, AccessTags, DenyTags, PurposeAllowed, TrustStatus, PublicKeyVerified, UsesSourceVault|>`を返す。未知の連絡先はfail-closed(MaxPlaintextPL 0.0など全閉じ)。PublicKeyVerifiedはTrustStatus=Verifiedかつ公開鍵レコードありの場合のみTrue。

### SourceVaultPlanMessageRelease[spec_Association] → Association
Recipients/Purpose/Transport/Materialsからmaterialをplaintext/capsule/redactionに分類したrelease planを返す。本文平文採用は全recipientでPL<=Min(TransportのMaxPlaintextPL, recipientのMaxPlaintextPL)かつtag policy Allowの場合のみ。それ以外はrecipientごとにcapsule(PL<=MaxEncryptedReadablePLかつPublicKeyVerifiedかつUsesSourceVault)またはredaction(理由: tag policy Deny / AboveRecipientAccess / NoVerifiedPublicKey)に振り分ける。既定DraftOnly、AutoSendAllowed常にFalse。
spec keys: Recipients(List of email|profile), Purpose(既定"Reply"), Transport(`<|MaxPlaintextPL->0.45|>`が既定), Materials(List of `<|Ref, PL, AccessTags,...|>`)
戻り値`<|Decision->"DraftOnly", PlaintextMaterials, EncryptedCapsules(recipient別), RedactedMaterials, Audit(<|TransportMaxPlaintextPL, Purpose, RecipientCount, RequiresHumanConfirmation->True, AutoSendAllowed->False|>)|>`

### $SourceVaultSystemDenyTags
型: List, 初期値: {"NoEmail", "NoExternal", "StudentPrivate", "Personal"}
外部送信を既定で禁止するシステムdeny tag。material側にこれらのAccessTagsが付くと無条件Deny。