# SourceVault 統合メッセージ・Discord 拡張仕様 v1

- 状態: 実装前仕様
- 策定日: 2026-06-15
- 対象パッケージ: `SourceVault`
- 新規ファイル:
  - `SourceVault_message.wl`
  - `SourceVault_discord.wl`
- 変更対象:
  - `SourceVault_maildb.wl`
  - `SourceVault_identity.wl`
  - `SourceVault.wl`
  - `SourceVault_info/docs/api_maildb.md`
  - `SourceVault_info/docs/user_manual.md`

## 1. 目的

メール、Discord サーバー内メッセージ、Discord DM、将来追加される SNS
メッセージを、SourceVault 内で同一の `SourceVaultMessageRecord` として扱う。

本仕様は次を実現する。

1. 複数メールアカウント、複数 Discord Bot アカウント、複数 Discord
   サーバー、各チャンネル、Bot が当事者である DM を取り込む。
2. メールと Discord を横断して、新着一覧、検索、本文表示、添付表示を行う。
3. 投稿者を既存の `SourceVault_identity.wl` の Identifier / Entity
   2 層モデルへ取り込む。
4. メールと Discord の新規投稿、返信、翻訳返信を共通ドラフト API で扱う。
5. 明示返信、暗黙返信、引用、ネイティブスレッド等を型付きリンクとして保存する。
6. 引用本文を参照リンクへ置換した、非冗長なハイパーテキスト版を生成する。
7. 時間的・意味的にまとまった議論をセッショングループとして構成する。
8. 任意のメッセージ集合を、それ自体が検索・表示・要約可能な
   `SourceVaultMessageRecord` として扱い、階層化を許す。

## 2. 主要設計判断

### 2.1 共通層を Discord ファイル内に置かない

`SourceVault_discord.wl` は Discord 固有アダプタとし、共通データモデル、
検索、リンク、グループ、ドラフト、送信管理は新規 `SourceVault_message.wl`
に置く。

```text
SourceVault_identity.wl
        |
SourceVault_message.wl
   |              |
SourceVault_maildb.wl   SourceVault_discord.wl
```

メール専用 schema を共通 schema に改名して拡張する方式は採用しない。
既存 `SourceVaultMailSnapshot` は後方互換用の source snapshot として残し、
共通 MessageRecord への projection を追加する。

### 2.2 原文は不変、ハイパーテキスト版は派生物

引用テキストを「削除」する処理は、原文を破壊してはならない。

- `Original`: 取り込み時の原文。原則 immutable。
- `Normalized`: 改行、文字コード等のみ正規化した版。
- `Hypertext`: 引用ブロックを `QuoteRef` ノードへ置換した版。

表示の既定は `Hypertext` とするが、監査、再解析、送信確認のため
`Original` を常に取得可能にする。

### 2.3 リンクは独立レコードを正本とする

双方向リンクを両メッセージへ直接複製すると不整合が起きるため、
`SourceVaultMessageLink` を正本とする。MessageRecord 内の `LinkRefs`
は高速表示用キャッシュであり、再構築可能とする。

### 2.4 「スレッド」は一種類に固定しない

以下を区別する。

- `NativeThread`: Discord thread、メール provider の thread id。
- `ReplyComponent`: 明示・承認済み暗黙返信リンクの連結成分。
- `Session`: 時間的・意味的に連続する議論単位。
- `MessageGroup`: ユーザーが自由に作る集合または階層。
- `ThreadView`: 指定したリンク型をたどって動的に作る表示。

本仕様では、reply graph の連結成分を「返信クリーク」と呼ばず
`ReplyComponent` と呼ぶ。全頂点間にリンクを作る数学的 clique 化は行わない。

### 2.5 自動推論リンクと明示リンクを混同しない

- API/header による返信: `ReplyExplicit`
- 高信頼で承認済みの推論返信: `ReplyImplicit`
- 未承認候補: `ImplicitReplyCandidate`

検索やセッション構築は、既定では候補リンクを使用しない。

## 3. Discord API 上の制約

### 3.1 正規取得経路

正規取得は Discord Bot API のみを使う。

- Bot が参加している guild のうち、Bot に `View Channel` と
  `Read Message History` があるチャンネルを対象にできる。
- メッセージ本文、embed、attachment 等の取得には原則として
  `MESSAGE_CONTENT` privileged intent が必要である。
- realtime 取得は Gateway の `GUILD_MESSAGES`、`DIRECT_MESSAGES`、
  `MESSAGE_CONTENT` を使用する。
- 履歴 backfill は HTTP API、継続取得は Gateway と HTTP 差分取得を併用する。
- rate limit は固定 sleep ではなく response header と HTTP 429 の
  `retry_after` に従う。

### 3.2 DM の意味

Bot API で取得可能な DM は「Bot 自身が当事者である DM」である。
個人 Discord アカウントの既存 DM 全体を Bot で読むことはできない。

通常ユーザー token を用いる self-bot は Discord の規約上禁止されるため、
実装しない。個人アカウントとしての自動送信も行わない。

### 3.3 公式データパッケージ取込

個人アカウントの過去データについては、Discord の公式 Data Package ZIP
をオフライン import する補助経路を提供してよい。

ただし公式 Data Package の messages は、原則として本人が送信した
メッセージのみであり、会話全体の完全な復元にはならない。この経路の
record には必ず次を記録する。

```wl
"Completeness" -> "AuthorSentMessagesOnly"
"ReadOnlySource" -> True
"CanReplyViaSourceAccount" -> False
```

## 4. ファイル構成とロード順

### 4.1 新規 `SourceVault_message.wl`

担当範囲:

- 共通 MessageRecord schema
- message store と shard 管理
- adapter registry
- 横断検索、一覧、本文表示
- MessageLink store と graph traversal
- Hypertext content
- Session / MessageGroup
- summary stale 判定
- 共通 draft / transport dispatch

### 4.2 新規 `SourceVault_discord.wl`

担当範囲:

- Discord account 設定
- REST backfill / incremental fetch
- Gateway listener
- Discord API object の MessageRecord 化
- Discord identity observe
- Discord 添付取得
- Discord transport による投稿、返信
- Discord Data Package import

Gateway の WebSocket、heartbeat、resume、rate-limit 制御は Python helper
を Mathematica から呼んでよい。永続化、schema 検証、暗号化、検索、
リンク解決、UI は Mathematica 側を正本とする。

### 4.3 `SourceVault_maildb.wl`

追加担当:

- `SourceVaultMailSnapshot` から MessageRecord への projection
- IMAP 取得時の `Message-ID`、`In-Reply-To`、`References` 保持
- SMTP transport
- 共通 draft への mail recipient/header 変換
- 既存 Mail UI API の共通 API wrapper 化

### 4.4 ロード順

```text
NBAccess_crypto.wl
SourceVault_crypto.wl
SourceVault_identity.wl
SourceVault_message.wl
SourceVault_maildb.wl
SourceVault_discord.wl
SourceVault_promptrouter.wl
```

`SourceVault.wl` の aux auto-load に `SourceVault_message.wl` と
`SourceVault_discord.wl` を追加する。Discord の設定が存在しなくても
SourceVault 全体の load は失敗させない。

## 5. 共通 MessageRecord

### 5.1 共通 envelope

Atomic message と MessageGroup は同じ envelope を使用する。

```wl
<|
  "Type" -> "SourceVaultMessageRecord",
  "SchemaVersion" -> 1,
  "RecordId" -> "svmsg-...",
  "RecordKind" -> "Atomic" | "Group" | "ExternalStub",
  "Revision" -> 1,

  "Source" -> <|
    "Provider" -> "Mail" | "Discord" | "SourceVault",
    "Adapter" -> "mail" | "discord" | "group",
    "AccountRef" -> "mail:work" | "discord:main" | Missing[],
    "SourceRecordRef" -> _Association | Missing[],
    "NativeIdToken" -> _String | Missing[],
    "NativeLocatorRef" -> encryptedRecord | Missing[],
    "NativeURL" -> _String | Missing["Suppressed"],
    "ObservedAtUTC" -> _String
  |>,

  "Conversation" -> <|
    "ConversationKind" ->
      "MailThread" | "GuildChannel" | "DiscordThread" |
      "DirectMessage" | "GroupDM" | "MessageGroup",
    "ConversationToken" -> _String,
    "DisplayName" -> _String | Missing["Encrypted"],
    "GuildToken" -> _String | Missing[],
    "ChannelToken" -> _String | Missing[],
    "NativeThreadToken" -> _String | Missing[]
  |>,

  "Actors" -> <|
    "AuthorIdentifier" -> _String | Missing[],
    "AuthorEntity" -> _String | Missing["Unlinked"],
    "RecipientIdentifiers" -> {_String ...},
    "MentionedIdentifiers" -> {_String ...},
    "ParticipantEntities" -> {_String ...}
  |>,

  "MetadataPublic" -> <|
    "CreatedAtUTC" -> _String,
    "EditedAtUTC" -> _String | Missing[],
    "Title" -> _String | Missing["Encrypted"],
    "AuthorDisplay" -> _String | Missing["Encrypted"],
    "ConversationDisplay" -> _String | Missing["Encrypted"],
    "AttachmentCount" -> _Integer,
    "HasBody" -> True | False,
    "Direction" -> "Inbound" | "Outbound" | "Self" | "Unknown",
    "ReadState" -> "Unread" | "Read" | "Archived",
    "DeletedAtSource" -> True | False,
    "PinnedAtSource" -> True | False
  |>,

  "PayloadRefs" -> <|
    "OriginalBody" -> payloadLocator | encryptedRecord | Missing["NoBody"],
    "NormalizedBody" -> encryptedRecord | Missing["NotGenerated"],
    "HypertextBody" -> encryptedRecord | Missing["NotGenerated"],
    "Attachments" -> {attachmentRef ...},
    "RawSource" -> encryptedRecord | Missing["NotStored"]
  |>,

  "Derived" -> <|
    "Summary" -> _String | Missing["NotGenerated"],
    "SummaryRef" -> encryptedRecord | Missing[],
    "SummaryStatus" -> "Current" | "Stale" | "Pending",
    "Priority" -> _Real | Missing["NotGenerated"],
    "PrivacyLevel" -> _Real,
    "Category" -> _String | Missing["NotGenerated"],
    "Deadline" -> _String | Missing["None"],
    "Language" -> _String | Missing["NotDetected"],
    "TopicTags" -> {_String ...},
    "DerivedStatus" -> "Pending" | "Processed"
  |>,

  "LinkRefs" -> {
    <|"LinkId" -> _String, "Role" -> "Source" | "Target"|> ...
  },

  "Group" -> groupSpec | Missing["NotGroup"],

  "State" -> <|
    "Lifecycle" -> "Active" | "DeletedAtSource" | "Tombstone",
    "FirstIngestedAtUTC" -> _String,
    "LastSynchronizedAtUTC" -> _String,
    "RevisionRefs" -> {_String ...}
  |>,

  "Policy" -> <|
    "RequiresLocalDecrypt" -> True,
    "ReleaseRequiresPlan" -> True,
    "AutoSendAllowed" -> False,
    "OriginalBodyImmutable" -> True
  |>,

  "Provenance" -> <|
    "ImportedBy" -> _String,
    "AdapterVersion" -> _String,
    "Completeness" -> "Complete" | "BestEffort" |
      "AuthorSentMessagesOnly" | "MetadataOnly",
    "InferenceRecords" -> {_Association ...}
  |>
|>
```

### 5.2 RecordId

Atomic message:

```text
svmsg- + SHA256(provider, accountRef, nativeMessageId)[0..23]
```

Group:

```text
svmsg-group- + UUID
```

Native ID は equality と再取得に必要だが、そのまま同期領域へ露出させない。
`NativeIdToken` は HMAC、実 native locator は暗号化 record に保存する。

### 5.3 ExternalStub

`In-Reply-To` や Discord reference の対象がまだ未取得の場合、
`RecordKind -> "ExternalStub"` を作成できる。後で対象 message が入った時に
同一 native token で実 record へ resolve し、link endpoint を更新する。

### 5.4 Adapter registry と payload locator

既存 MailSnapshot の暗号化本文を MessageRecord へ複製しないため、
共通層は provider adapter を登録する。

```wl
SourceVaultRegisterMessageAdapter["mail", <|
  "GetBody" -> mailBodyFunction,
  "GetAttachments" -> mailAttachmentFunction,
  "ComposeTarget" -> mailComposeFunction,
  "SendDraft" -> mailSendFunction,
  "ResolveNativeURL" -> mailURLFunction
|>]
```

adapter contract:

```wl
<|
  "GetBody" -> Function[{payloadLocator, version}, result],
  "GetAttachments" -> Function[{payloadLocator}, result],
  "ComposeTarget" -> Function[{messageRecord, operation}, targetSpec],
  "SendDraft" -> Function[{draft, deliveryContext}, deliveryResult],
  "ResolveNativeURL" -> Function[{messageRecord}, urlOrMissing]
|>
```

`payloadLocator` はデータのみを保存し、関数や評価式を永続化しない。

```wl
<|
  "Adapter" -> "mail" | "discord",
  "SourceRecordId" -> _String,
  "Field" -> "Body" | "Attachment" | "RawSource",
  "Revision" -> _Integer,
  "ExpectedDigest" -> _String | Missing[]
|>
```

公開 API:

```wl
SourceVaultRegisterMessageAdapter[name, spec]
SourceVaultMessageAdapter[name]
SourceVaultListMessageAdapters[]
SourceVaultMessageGetBody[recordId, opts]
SourceVaultMessageAttachments[recordId]
```

adapter が未登録、digest 不一致、復号失敗の場合は、空文字へ黙って
フォールバックせず型付き error を返す。

## 6. Provider 固有情報

### 6.1 Mail source locator

```wl
<|
  "Provider" -> "Mail",
  "MBox" -> "work",
  "MessageIDToken" -> _String,
  "MessageIDEncrypted" -> encryptedRecord,
  "InReplyToTokens" -> {_String ...},
  "ReferenceTokens" -> {_String ...},
  "UID" -> _Integer | Missing[],
  "UIDValidity" -> _Integer | Missing[]
|>
```

`maildb_legacy.wl` 由来 record には `In-Reply-To` / `References` がないため、
`Completeness -> "BestEffort"` とする。必要なら IMAP 再取得で補完する。

### 6.2 Discord source locator

```wl
<|
  "Provider" -> "Discord",
  "AccountRef" -> "discord:main",
  "MessageIdToken" -> _String,
  "ChannelIdToken" -> _String,
  "GuildIdToken" -> _String | Missing["DM"],
  "ThreadIdToken" -> _String | Missing[],
  "AuthorUserIdToken" -> _String,
  "MessageType" -> _Integer,
  "Flags" -> _Integer,
  "WebhookIdToken" -> _String | Missing[],
  "ApplicationIdToken" -> _String | Missing[]
|>
```

実 snowflake は encrypted `NativeLocatorRef` 内に置く。API call 前にローカルで
復号する。

## 7. MessageLink

### 7.1 schema

```wl
<|
  "Type" -> "SourceVaultMessageLink",
  "SchemaVersion" -> 1,
  "LinkId" -> "svlnk-...",
  "Class" ->
    "ReplyExplicit" |
    "ReplyImplicit" |
    "ImplicitReplyCandidate" |
    "ThreadReference" |
    "Quotes" |
    "NativeThreadMember" |
    "Contains" |
    "SameTopic" |
    "Manual",
  "SourceRecordId" -> _String,
  "TargetRecordId" -> _String | Missing["Unresolved"],
  "TargetNativeToken" -> _String | Missing[],
  "Directed" -> True | False,
  "Status" -> "Accepted" | "Proposed" | "Rejected" | "Superseded",
  "Confidence" -> _Real,
  "Evidence" -> {
    <|"Kind" -> _String, "Value" -> _ | Missing[]|> ...
  },
  "SourceSpan" -> {start_Integer, end_Integer} | Missing[],
  "TargetSpan" -> {start_Integer, end_Integer} | Missing[],
  "Resolver" -> <|
    "Name" -> _String,
    "Version" -> _String,
    "ModelRef" -> _String | Missing["RuleBased"],
    "ResolvedAtUTC" -> _String
  |>,
  "CreatedAtUTC" -> _String,
  "ReviewedBy" -> _String | Missing["NotReviewed"]
|>
```

### 7.2 双方向 traversal

edge 自体が directed でも、次の API は逆方向を含めて探索できる。

```wl
SourceVaultMessageNeighbors[id,
  "Classes" -> {"ReplyExplicit", "ReplyImplicit"},
  "Direction" -> "Both"]
```

`Source` 側には parent、`Target` 側には child という固定命名をしない。
`ReplyExplicit` では `SourceRecordId` が返信、`TargetRecordId` が返信先である。

## 8. 明示返信の解決

### 8.1 Mail

1. `Message-ID` token index を作る。
2. `In-Reply-To` の最後の有効 token を `ReplyExplicit` とする。
3. `References` の各 token は `ThreadReference` とする。
4. `In-Reply-To` がなく `References` のみある場合、最後の reference を
   `ReplyExplicit` 候補にしてよいが、Evidence にその事実を残す。
5. 対象未取得なら ExternalStub または unresolved link とする。

IMAP Python helper は最低限次を返すよう変更する。

```python
{
  "message_id": ...,
  "in_reply_to": ...,
  "references": [...],
  "reply_to": ...,
  "date": ...,
  "subject": ...,
  "from": ...,
  "to": ...,
  "cc": ...,
  "body": ...
}
```

### 8.2 Discord

- message object の `message_reference.message_id` を `ReplyExplicit` にする。
- `referenced_message` が含まれる場合は対象 stub の metadata 補完に使う。
- Discord thread 内所属は `NativeThreadMember` で表す。
- thread starter message と parent message の reference も保存する。
- forward reference は reply とせず、別 class `ThreadReference` または
  将来の `ForwardReference` として扱う。

## 9. 暗黙返信の解決

### 9.1 候補生成

暗黙返信の候補は、既定では同一 Conversation 内から生成する。

- 時間窓内の過去 message
- author / recipient / mention の連続性
- normalized subject の一致
- 同一 topic tag
- 本文内の固有語、質問、回答表現
- 過去 message の一部引用
- Discord の mention、メールの宛名

cross-provider 推論は誤結合の危険が高いため、既定 `False` とする。
明示的に有効化した場合も、同一 Entity が両 provider の identifier に
リンク済みであることを必要条件とする。

### 9.2 score と承認

resolver は候補ごとに 0.0-1.0 の score と根拠を保存する。

```text
score >= 0.92 かつ 2 位との差 >= 0.15:
    ReplyImplicit として自動採用可能
0.65 <= score < 0.92:
    ImplicitReplyCandidate
score < 0.65:
    保存しない
```

閾値は option 化する。LLM を使う場合は local model を既定とし、
本文の PL が release policy を超える cloud model へ送らない。

### 9.3 再現性

推論結果には resolver version、model ref、prompt digest、候補集合 digest、
生成時刻を残す。同一入力と同一 resolver version の再実行は冪等とする。

## 10. 引用ブロックとハイパーテキスト化

### 10.1 ContentDocument

`NormalizedBody` と `HypertextBody` は次の AST として保存する。

```wl
<|
  "Type" -> "SourceVaultMessageContent",
  "SchemaVersion" -> 1,
  "ContentVersion" -> "Original" | "Normalized" | "Hypertext",
  "SourceRecordId" -> _String,
  "Nodes" -> {
    <|"NodeType" -> "Text", "Text" -> _String|>,
    <|"NodeType" -> "Code", "Text" -> _String, "Language" -> _String|>,
    <|"NodeType" -> "Mention", "IdentifierRef" -> _String,
      "Display" -> _String|>,
    <|"NodeType" -> "AttachmentRef", "AttachmentRef" -> _String|>,
    <|"NodeType" -> "QuoteRef",
      "TargetRecordId" -> _String,
      "TargetSpan" -> {start_Integer, end_Integer},
      "LinkId" -> _String,
      "DisplayMode" -> "Collapsed",
      "FallbackPreview" -> _String|>
  },
  "Transform" -> <|
    "Name" -> _String,
    "Version" -> _String,
    "InputDigest" -> _String,
    "CreatedAtUTC" -> _String
  |>
|>
```

### 10.2 quote 検出

次を組み合わせる。

1. メールの `>` prefix、`On ... wrote:`、転送 header 等の構文解析。
2. Discord の block quote と引用記法。
3. reply component 内の過去本文との exact block hash。
4. 空白、引用記号、署名差を除いた near-duplicate block。
5. 長い共通部分列または局所類似度。

一致対象は、原則として引用 message より過去の message とする。
複数対象が同程度の場合は置換せず候補として残す。

### 10.3 冗長性除去

引用部分を物理削除せず、Hypertext 版では `QuoteRef` に置換する。
`Quotes` link を同時作成し、引用側から被引用側、被引用側から引用側の
どちらにも traversal 可能にする。

表示では `QuoteRef` を折り畳み表示し、クリックで対象本文と該当 span を開く。

## 11. Session と MessageGroup

### 11.1 Group schema

Group も `SourceVaultMessageRecord` であり、`RecordKind -> "Group"` とする。

```wl
"Group" -> <|
  "GroupKind" ->
    "Session" | "NativeThread" | "ReplyComponent" |
    "ManualCollection" | "SmartCollection" | "PeriodCollection",
  "Title" -> _String,
  "MemberRefs" -> {
    <|"RecordId" -> _String, "Order" -> _Integer,
      "Role" -> "Member" | "Root" | "SummarySource"|> ...
  },
  "MemberDigest" -> _String,
  "GroupingPolicy" -> _Association,
  "DateRangeUTC" -> {_String, _String},
  "ParentGroupRefs" -> {_String ...},
  "ChildGroupRefs" -> {_String ...},
  "CycleChecked" -> True
|>
```

Group は Atomic message と Group の両方を member にできる。
循環包含は禁止する。membership の正本は `Contains` link とし、
`MemberRefs` は順序付き cache とする。

### 11.2 Session 定義

Session は reply link があるだけでは成立しない。次を満たす局所的集合である。

- message 間の時間差が provider / conversation 種別ごとの閾値以内。
- topic coherence が一定以上。
- participant または conversation の連続性がある。

既定 gap:

| Conversation | 基本 gap |
|---|---:|
| Discord guild channel | 6 時間 |
| Discord DM / Group DM | 24 時間 |
| Mail thread | 7 日 |
| provider 横断 | 48 時間 |

adaptive mode では inter-message gap 分布と topic coherence を使って
境界を補正する。長期間空いた後に古いメールへ返信した場合、
`ReplyExplicit` は保持するが別 Session にする。

### 11.3 Session summary

Session summary は通常 message summary と同じ `Derived.Summary` に置くが、
次を追加する。

```wl
"SummaryBasis" -> <|
  "MemberDigest" -> _String,
  "MemberCount" -> _Integer,
  "ModelRef" -> _String,
  "PromptDigest" -> _String,
  "GeneratedAtUTC" -> _String
|>
```

member の追加、削除、本文 revision、採用 link の変更で `MemberDigest` が
変わった場合、`SummaryStatus -> "Stale"` とする。

### 11.4 階層例

```text
R8年度 学科会議                 PeriodCollection
  ├─ 2026-04 学科会議 session   Session
  ├─ 2026-05 学科会議 session   Session
  └─ 2026-06 学科会議 session   Session
```

各 session に summary を付け、上位 `R8年度 学科会議` にも
下位 summary 群を入力として summary を付けられる。

## 12. Identity 拡張

### 12.1 Identifier kind

`SourceVaultObserveIdentifier` に以下を追加する。

```text
DiscordUser
DiscordWebhook
DiscordRole
```

通常投稿者は `DiscordUser` とし、Value は raw user snowflake の正規化値とする。
username は変更可能なので identity key に使用しない。

### 12.2 観測属性

Identifier record を schema v2 に拡張する。

```wl
"ObservedProfiles" -> {
  <|
    "Provider" -> "Discord",
    "Username" -> _String,
    "GlobalName" -> _String | Missing[],
    "GuildNickname" -> _String | Missing[],
    "GuildToken" -> _String | Missing["DM"],
    "Bot" -> True | False,
    "ObservedAtUTC" -> _String
  |> ...
}
```

既存 `"ObservedNames"` は表示と検索の後方互換のため維持する。
`"MBox"` option は残しつつ、汎用 `"Source"` / `"Provenance"` option を追加する。

### 12.3 Entity link

- Discord identifier は自動作成する。
- Person / Bot / Service Entity の自動作成は既定で行わない。
- `SourceVaultIdentityLinkUI` で既存メール Entity へ merge できる。
- Bot account の owner user id は `EntityUid -> 1` へ明示リンクできる。
- Discord user id と email の自動同一人物判定は行わない。

## 13. Discord account 設定

```wl
SourceVaultRegisterDiscordAccount[<|
  "Account" -> "main",
  "ApplicationId" -> "...",
  "BotUserId" -> "...",
  "BotTokenCredKey" -> "SV_DISCORD_MAIN_BOT_TOKEN",
  "OwnerUserId" -> "...",
  "AllowedGuildIds" -> All | {...},
  "AllowedChannelIds" -> All | {...},
  "DeniedChannelIds" -> {...},
  "IncludeBotDMs" -> True,
  "AllowCreateDM" -> False,
  "MessageContentIntent" -> True,
  "AttachmentPolicy" -> "EncryptedDownload",
  "DefaultPrivacyLevel" -> 0.85
|>]
```

token 本体は `SystemCredential` または NBAccess credential backend に置き、
設定ファイルには `BotTokenCredKey` だけを保存する。

公開 API:

```wl
SourceVaultRegisterDiscordAccount[assoc, opts]
SourceVaultDiscordAccounts[]
SourceVaultGetDiscordAccount[name]
SourceVaultRemoveDiscordAccount[name]
SourceVaultDiscordAccountsLoad[]
SourceVaultDiscordAccountStatus[name]
```

## 14. Discord ingest

### 14.1 backfill

```wl
SourceVaultDiscordBackfill[account,
  "Guilds" -> All,
  "Channels" -> All,
  "Period" -> {from, to} | n | All,
  "IncludeThreads" -> True,
  "IncludeDMs" -> True,
  "MaxMessagesPerChannel" -> Automatic,
  "Persist" -> True]
```

処理:

1. guild / channel 一覧を取得する。
2. allow / deny policy と Discord permission を確認する。
3. channel ごとに message history をページングする。
4. rate limit bucket と `retry_after` に従う。
5. MessageRecord 化、identity observe、明示 link 解決を行う。
6. channel checkpoint を保存する。

### 14.2 incremental fetch

```wl
SourceVaultDiscordFetchNew[account, opts]
```

channel ごとの `LastMessageId` と `LastSuccessfulSyncAtUTC` を使う。
message snowflake の大小だけに依存せず、edited / deleted event のため
reconciliation window を持つ。

### 14.3 Gateway

```wl
SourceVaultDiscordStartListener[account, opts]
SourceVaultDiscordStopListener[account]
SourceVaultDiscordListenerStatus[account]
```

最低限処理する event:

- `MESSAGE_CREATE`
- `MESSAGE_UPDATE`
- `MESSAGE_DELETE`
- `MESSAGE_DELETE_BULK`
- `THREAD_CREATE`
- `THREAD_UPDATE`
- `THREAD_DELETE`
- `CHANNEL_CREATE`
- `CHANNEL_UPDATE`
- `GUILD_CREATE`

resume 用の `session_id`、`resume_gateway_url`、sequence number は
credential ではないが private runtime state として保存する。
Gateway が停止していた期間は HTTP reconciliation で補う。

### 14.4 edit / delete

- edit は latest record を更新し、旧本文を revision store に残す。
- delete は `DeletedAtSource -> True` と tombstone event を残す。
- SourceVault 上の暗号化済み原文を直ちに消すかは retention policy に従う。
- message id の再利用はない前提だが RecordId の冪等性を維持する。

### 14.5 添付

`AttachmentPolicy`:

- `"MetadataOnly"`
- `"EncryptedDownload"` 既定
- `"Skip"`

download 時は content hash、size、MIME、original filename encrypted ref、
Discord CDN source URL、取得時刻を保存する。URL だけを永続本文とみなさない。

### 14.6 Data Package

```wl
SourceVaultImportDiscordDataPackage[zipOrDirectory,
  "Account" -> "personal-export",
  "Persist" -> True]
```

この adapter は read-only であり、送信 transport として登録しない。

## 15. Mail projection と migration

### 15.1 projection

```wl
SourceVaultMessageFromMailSnapshot[snapshot]
SourceVaultProjectLoadedMailSnapshots[]
```

projection は同じ mail snapshot から常に同じ MessageRecord ID を生成する。
本文を二重暗号化せず、既存 `PayloadRefs.Body` を adapter locator 経由で参照する。

### 15.2 新規 IMAP 取得

`SourceVaultMailFetchNew` は保存後に MessageRecord projection を自動 upsert する。
`Message-ID`、`In-Reply-To`、`References` を保持するよう IMAP helper を変更する。

### 15.3 legacy

旧 snapshot の projection は可能だが、明示 thread 情報が欠落する。
その場合は subject、participants、time、引用一致による
`ImplicitReplyCandidate` のみ生成する。

## 16. Store と shard

既定 root:

```text
PrivateVault/messages/
  records/<provider>/<account>/<yyyymm>.svmsg
  links/<yyyymm>.svlink
  groups/<yyyy>.svgroup
  revisions/<provider>/<account>/<yyyymm>.svrev
  checkpoints/discord.jsonl
  checkpoints/mail.jsonl
  drafts/<yyyy>/<mm>.svdraft
  delivery/<yyyy>/<mm>.svdelivery
```

MessageRecord の shard key は原則
`provider/account/CreatedAtUTC-yyyyMM` とする。
Group は作成年で shard し、member の期間に依存して移動させない。

write は temp file、flush、rename の transactional write とし、
dirty shard のみ保存する。Dropbox 同期で全 store を毎回書き換えない。

公開 API:

```wl
SourceVaultMessagePut[record, opts]
SourceVaultMessageGet[recordId]
SourceVaultMessageList[]
SourceVaultMessageEnsureLoaded[spec]
SourceVaultMessageAvailableShards[]
SourceVaultMessageStoreSave[opts]
SourceVaultMessageUnloadAll[]
SourceVaultMessageLoadedCount[]
```

## 17. 横断検索と新着一覧

### 17.1 検索

```wl
SourceVaultSearchMessages[query_String : "", opts]
```

主な option:

```text
"Providers" -> All | {"Mail", "Discord"}
"Accounts" -> All | {...}
"RecordKind" -> All | "Atomic" | "Group"
"GroupKind" -> All | "Session" | ...
"Guild" -> All | token/name
"Channel" -> All | token/name
"ConversationKind" -> All | ...
"Author" -> All | IdentifierId | EntityId | name query
"Participants" -> All | {...}
"DateFrom" -> Automatic
"DateTo" -> Automatic
"IngestedAfter" -> Automatic
"ReadState" -> All | "Unread" | "Read" | "Archived"
"HasAttachment" -> All | True | False
"Category" -> Automatic
"HasDeadline" -> Automatic
"LinkClass" -> All | ...
"Session" -> All | sessionId
"IncludeBody" -> False
"IncludeGroups" -> True
"SortBy" -> "Date" | "Priority" | "PrivacyLevel" | "Deadline"
"SortOrder" -> "Desc" | "Asc"
"Limit" -> Infinity
```

本文検索は復号を伴うため `"IncludeBody" -> False` を既定とする。
`True` の場合は local-only search とし、結果全体を Confidential 扱いにする。

### 17.2 新着

```wl
SourceVaultUnifiedInbox[
  "Providers" -> {"Mail", "Discord"},
  "ReadState" -> "Unread",
  "Limit" -> 100]
```

Discord の user client 上の既読状態は Bot API から一般に取得できないため、
`ReadState` は SourceVault 内の状態である。

```wl
SourceVaultMarkMessageRead[id]
SourceVaultMarkMessageUnread[id]
SourceVaultArchiveMessage[id]
```

### 17.3 表示

```wl
SourceVaultMessageSummaryRow[record]
SourceVaultMessageDataset[query, opts]
SourceVaultMessageView[query, opts]
```

共通列:

```text
本文 / スレッド / 添付 / 返信 / Provider / 日付 / 重要度 / 秘匿度 /
会話 / 件名・先頭文 / 投稿者 / 概要
```

`SourceVaultSummaries` へ `"messages"` provider を登録し、既存の
SourceVault 全体横断検索にも summary 行を提供する。

## 18. Thread / Session 表示

### 18.1 traversal API

```wl
SourceVaultMessageThread[id,
  "Mode" -> "Session" | "ReplyComponent" | "NativeThread" | "Custom",
  "LinkClasses" -> {"ReplyExplicit", "ReplyImplicit", "Quotes"},
  "IncludeCandidates" -> False,
  "MaxDepth" -> Infinity]
```

### 18.2 Notebook

```wl
SourceVaultMessageOpenNotebook[id,
  "Context" -> "Session",
  "BodyVersion" -> "Hypertext",
  "CollapseQuotes" -> True,
  "ShowLinkClasses" -> True]
```

既存 `SourceVaultMailShowBody` は、後方互換 option を除き
`SourceVaultMessageOpenNotebook` の mail wrapper に移行する。
既定表示を単一メールから Session 表示へ変更する場合は、
互換性のため `"Context" -> "Single"` も残す。

Notebook は次を表示する。

1. session / group title と summary
2. participant
3. 時系列 message
4. 明示返信と暗黙返信の表示差
5. 折り畳まれた QuoteRef
6. 前後 session へのリンク
7. raw original を開く監査操作

## 19. Resolver API

```wl
SourceVaultResolveMessageLinks[spec, opts]
SourceVaultResolveExplicitReplies[spec, opts]
SourceVaultResolveImplicitReplies[spec, opts]
SourceVaultResolveMessageQuotes[spec, opts]
SourceVaultBuildMessageSessions[spec, opts]
SourceVaultReviewMessageLink[linkId, "Accept" | "Reject"]
SourceVaultRebuildMessageLinkCache[recordIds : All]
```

`spec` は record id、conversation、期間、provider、group を受け付ける。
大規模再解析は checkpoint 付き batch とし、中断後に再開可能にする。

## 20. MessageGroup API

```wl
SourceVaultMessageGroupCreate[title, members, opts]
SourceVaultMessageGroupGet[groupId]
SourceVaultMessageGroupAdd[groupId, members]
SourceVaultMessageGroupRemove[groupId, members]
SourceVaultMessageGroupSetChildren[groupId, childGroups]
SourceVaultMessageGroupValidate[groupId]
SourceVaultMessageGroupSummarize[groupId, opts]
SourceVaultMessageSummaryStatus[groupId]
```

Group summary は local LLM を既定とする。上位 group の summary 入力には、
privacy policy が許せば下位 summary を使い、許さなければ local decrypt 下で
下位本文を使う。

## 21. 共通 draft と送信

### 21.1 Draft schema

```wl
<|
  "Type" -> "SourceVaultMessageDraft",
  "SchemaVersion" -> 1,
  "DraftId" -> "svdraft-...",
  "Operation" -> "New" | "Reply" | "ReplyAll" | "Forward",
  "Provider" -> "Mail" | "Discord",
  "AccountRef" -> _String,
  "Target" -> <|
    "ReplyToRecordId" -> _String | Missing[],
    "ConversationRef" -> _Association,
    "Recipients" -> {_Association ...}
  |>,
  "Subject" -> _String | Missing["NotApplicable"],
  "BodyOriginalLanguage" -> _String,
  "BodyOriginal" -> encryptedRecord,
  "BodyTranslated" -> encryptedRecord | Missing["NotTranslated"],
  "TargetLanguage" -> _String | Automatic,
  "Attachments" -> {_Association ...},
  "ReplyMetadata" -> <|
    "MailInReplyTo" -> encryptedValue | Missing[],
    "MailReferences" -> {encryptedValue ...},
    "DiscordMessageReference" -> encryptedValue | Missing[]
  |>,
  "ReleasePlan" -> _Association | Missing["NotPlanned"],
  "Status" ->
    "Draft" | "Translated" | "Prepared" | "Confirmed" |
    "Sending" | "Sent" | "Failed" | "Cancelled",
  "Confirmation" -> <|
    "Required" -> True,
    "ConfirmedAtUTC" -> _String | Missing[],
    "ContentDigest" -> _String
  |>,
  "DeliveryRef" -> _String | Missing[],
  "CreatedAtUTC" -> _String,
  "UpdatedAtUTC" -> _String
|>
```

### 21.2 共通 API

```wl
SourceVaultComposeMessage[target, opts]
SourceVaultComposeReply[recordId, opts]
SourceVaultTranslateDraft[draftId, language, opts]
SourceVaultPreviewDraft[draftId]
SourceVaultConfirmDraft[draftId]
SourceVaultSendDraft[draftId, opts]
SourceVaultCancelDraft[draftId]
```

`SourceVaultComposeReply` option:

```text
"ReplyAll" -> False
"Body" -> ""
"TargetLanguage" -> Automatic
"QuoteMode" -> "LinkAware"
"IncludeQuotedTextForTransport" -> Automatic
```

SourceVault 内表示では QuoteRef を使う。外部送信時には相手が SourceVault
リンクを解決できないため、transport policy に従って必要最小限の引用本文へ
materialize する。

### 21.3 翻訳

英語翻訳:

```wl
SourceVaultTranslateDraft[draftId, "English",
  "PreserveNames" -> True,
  "PreserveURLs" -> True,
  "PreserveCode" -> True,
  "MatchSourceFormality" -> True]
```

- 既定は local LLM。
- 翻訳結果のみを送信候補にし、元の日本語 draft を保持する。
- 翻訳後に必ず preview と人間確認を要求する。
- confirmation は draft content digest に結び付ける。
- 確認後に本文が変わった場合、confirmation を無効化する。

### 21.4 release planning

送信前に既存 `SourceVaultPlanMessageRelease` を必ず通す。
recipient resolution は Email だけでなく Discord Entity / Identifier を扱うよう
拡張する。未知 recipient は fail-closed とする。

`AutoSendAllowed -> False` は維持する。定期 task や LLM が単独で
`SourceVaultSendDraft` を完了させてはならない。

## 22. Mail transport

`SourceVaultRegisterMailAccount` に後方互換で SMTP field を追加する。

```wl
<|
  "SMTPServer" -> "...",
  "SMTPPort" -> 587,
  "SMTPCredKey" -> "...",
  "SMTPUser" -> "...",
  "From" -> "..."
|>
```

送信実装は `SendMail` だけに依存しない。実際に次の header を設定できる
SMTP backend を用いる。

- `Message-ID`
- `In-Reply-To`
- `References`
- `Reply-To`

Python `email` / `smtplib` helper を Mathematica から呼ぶ実装を許可する。
送信 Message-ID は DraftId から安定生成し、再試行による二重送信を防ぐ。

## 23. Discord transport

Discord 送信は Bot として行う。

- new message: target channel へ Create Message
- reply: `message_reference` を設定
- mention: `allowed_mentions` を既定で空にし、明示対象だけ許可
- 新規 DM channel の作成は既定禁止とし、既存 DM への返信または
  ユーザー操作を起点とする場合だけ `"AllowCreateDM" -> True` を許可
- API response の message object を直ちに ingest
- 作成した record と返信先の間へ `ReplyExplicit` を追加
- DraftId を nonce / delivery log と結び、二重送信を防ぐ

個人アカウント本人としての送信は行わない。

## 24. Delivery log

```wl
<|
  "Type" -> "SourceVaultMessageDelivery",
  "DeliveryId" -> "svdelivery-...",
  "DraftId" -> _String,
  "Provider" -> "Mail" | "Discord",
  "Attempt" -> _Integer,
  "StartedAtUTC" -> _String,
  "CompletedAtUTC" -> _String | Missing[],
  "Status" -> "Succeeded" | "Failed" | "Unknown",
  "NativeMessageToken" -> _String | Missing[],
  "ErrorClass" -> _String | Missing[],
  "Retryable" -> True | False,
  "ResponseDigest" -> _String | Missing[]
|>
```

timeout 後に成否不明の場合は `Unknown` とし、同一 idempotency key の
存在確認をしてから再送する。

## 25. Security / privacy

1. Bot token、SMTP password、IMAP password を record や設定 JSONL に保存しない。
2. message body と attachment は既定で暗号化する。
3. guild 名、channel 名、DM 相手名も header metadata として PL 判定対象にする。
4. 未分類 Discord message の既定 PL は 0.85 とする。
5. summary、embedding、implicit link 推論、翻訳も materialization とみなす。
6. private body の cloud LLM 利用は禁止し、release policy を毎回評価する。
7. MessageRecord / Link / Group の表示セルを既存 confidential view registry に登録する。
8. Discord channel permission が失われた場合も過去 snapshot は勝手に削除せず、
   access state と provenance を更新する。
9. Bot がアクセスできるからといって SourceVault user が再公開してよいとは
   判断しない。

## 26. エラー分類

共通:

```text
NotFound
NotLoaded
NoCredential
PermissionDenied
RateLimited
NetworkUnavailable
SourceUnavailable
DecryptFailed
SchemaInvalid
PolicyDenied
ConfirmationRequired
ConfirmationStale
DeliveryStateUnknown
UnsupportedSourceAccount
IncompleteSource
```

Discord:

```text
MessageContentIntentUnavailable
GuildNotAllowed
ChannelNotAllowed
MissingReadHistoryPermission
BotDMOnly
GatewayResumeFailed
InvalidDiscordResponse
```

resolver:

```text
NoCandidate
AmbiguousCandidate
TargetNotIngested
LowConfidence
CycleDetected
SummaryStale
```

## 27. 既存 API の互換性

次は維持する。

```wl
SourceVaultSearchMailSnapshots
SourceVaultMailSearchSummary
SourceVaultMailDataset
SourceVaultMailView
SourceVaultMailGetBody
SourceVaultMailShowBody
SourceVaultMailComposeReply
SourceVaultMailOpenReplyNotebook
```

内部では共通 Message API を利用できるが、既存の返り値 schema を壊さない。

新規 wrapper:

```wl
SourceVaultDiscordView
SourceVaultDiscordDataset
SourceVaultDiscordSearchSummary
SourceVaultDiscordShowBody
SourceVaultDiscordComposeReply
```

これらは provider filter を付けた共通 API wrapper とする。

## 28. テスト要件

### 28.1 単体

- MessageRecord schema validation
- deterministic RecordId
- shard save/load byte exact
- mail snapshot projection 冪等性
- Discord API object projection 冪等性
- Discord user identity observe
- explicit mail reply resolution
- explicit Discord reply resolution
- unresolved stub の後解決
- implicit candidate score と threshold
- quote block exact / near match
- ambiguous quote を置換しない
- Hypertext から Original へ戻れる
- session gap 分割
- group cycle 検出
- member digest と summary stale
- draft confirmation digest
- translation 後の再確認
- delivery retry idempotency

### 28.2 adapter fake

Discord API、Gateway event source、SMTP、IMAP、LLM は注入可能にし、
network なしの fake で headless test を行う。

### 28.3 acceptance

1. 同一 Dataset に mail と Discord が新着順で並ぶ。
2. 投稿者名検索で email identifier と Discord identifier が同一 Entity
   に merge された結果を横断取得できる。
3. Discord explicit reply と mail `In-Reply-To` が同じ UI 表現になる。
4. 古いメールへの数か月後の返信は reply link を保ちつつ別 session になる。
5. 引用された旧本文が Hypertext 表示で重複せず、リンク先を開ける。
6. session を年度 group に入れ、session summary と年度 summary を作れる。
7. 日本語 draft を英訳、preview、confirm 後に mail または Discord へ送れる。
8. 送信成功後、outbound message が store に入り reply graph に現れる。
9. Bot がアクセスできない個人 DM を取得しようとした場合、
   self-bot fallback をせず `BotDMOnly` を返す。

## 29. 実装フェーズ

### Phase M1: 共通 message core

- `SourceVault_message.wl`
- MessageRecord / store / adapter registry
- mail projection
- 横断検索、Dataset、View
- identity generic provenance option

完了条件: 既存 mail が MessageRecord として検索・表示できる。

### Phase D1: Discord REST ingest

- `SourceVault_discord.wl`
- account config
- guild/channel backfill
- Bot DM
- attachment
- identity
- fake API tests

完了条件: 複数 guild/channel/DM の新着が mail と同じ一覧に出る。

### Phase L1: explicit links

- Mail header 追加取得
- Discord message_reference
- link store
- ReplyComponent / NativeThread view

完了条件: 明示返信を双方向にたどれる。

### Phase H1: implicit reply / hypertext

- candidate resolver
- review UI
- quote resolver
- ContentDocument / QuoteRef

完了条件: 引用冗長性を除いた thread 表示ができる。

### Phase G1: session / group / summary

- session clustering
- group hierarchy
- summary stale
- session notebook

完了条件: 学科会議の各 session と年度集合を階層表示・要約できる。

### Phase O1: outbound

- common draft
- mail SMTP transport
- Discord transport
- translation
- confirmation / delivery log

完了条件: mail / Discord の返信を同じ draft workflow で送信できる。

### Phase D2: Gateway realtime

- listener
- resume
- edit/delete
- HTTP reconciliation

完了条件: listener 停止・再開を含め、重複なしで継続同期できる。

## 30. 実装時の優先順位

1. 共通 schema と store を先に固定する。
2. mail projection で既存データを使い、共通 UI を先に検証する。
3. Discord REST backfill を実装する。
4. explicit link を先に完成させ、implicit 推論は後段にする。
5. Hypertext と Group は immutable original を前提に実装する。
6. 送信は最後に実装し、必ず release plan と人間確認を通す。
7. Gateway は REST ingest と checkpoint が安定してから追加する。

## 31. 公式 Discord 資料

- Gateway / intents:
  https://docs.discord.com/developers/events/gateway
- Message resource / message reference:
  https://docs.discord.com/developers/resources/message
- Channel resource / DM channel:
  https://docs.discord.com/developers/resources/channel
- User resource / Create DM:
  https://docs.discord.com/developers/resources/user
- Rate limits:
  https://docs.discord.com/developers/topics/rate-limits
- Self-bot 禁止:
  https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots
- Discord Data Package:
  https://support.discord.com/hc/en-us/articles/360004957991-Your-Discord-Data-Package
