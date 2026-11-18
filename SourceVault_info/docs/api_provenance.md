# SourceVault_provenance API リファレンス
パッケージ: SourceVault_provenance (https://github.com/transreal/SourceVault_provenance)。Context は `SourceVault``。ロードは `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_provenance.wl"]]`。

## 概要
来歴台帳の中核 (03 SystemDoctor 拡張仕様 v0.4 §13.1、Inc1a/1b/2)。
- 範囲: Blob / Entity の分離と正準化 (CanonVersion 1)、emit、spool、既存ログの adapter、Ingest と確定の契約、PrevHash 連鎖、MAC、checkpoint (Merkle 根)、feeds、索引 (graph / logical / labels / effective / usability)、再構築、供給点 (ServedToContext)、LLMCall の結合。
- 分担: emit はどのカーネルでも可で、spool に追記するだけである。失敗は数えるだけで元の処理を止めない。Ingest・台帳・索引・checkpoint は service カーネルが単一書き手として行う (SourceVaultIntegrityServiceTick が 60 秒ごとに呼ぶ)。FE は usability.wxf を Seq で無効化するキャッシュ越しに読む。
- 確定の契約 (§12.8): Spooled (spool に 1 行を追記) → Ingested (service が Seq を割り当て台帳に追記) → Durable (閉じて開き直し末尾を確認、DurableSeq 更新、spool の読取位置を進める = ACK) → Committed (Durable かつ索引が DurableSeq まで反映)。待つのは SourceVaultProvAwaitCommitted。Spooled は確定ではない。
- 台帳の行 (§4.8): `{"Seq","PrevHash","EventId","Record","LineHash","Mac"}`。LineHash = sha256(Seq|PrevHash|Record の正準 JSON 原文)。Mac = HMAC-SHA256(LedgerMac 鍵, LineHash) で、KeyId つき (`hmac:<KeyId>:<hex64>`)。検証は行から原文を切り出して再計算する (JSON を読み直して再直列化しない)。
- 識別子: BlobId = `blob:sha256:<hex64>`、EntityId = `ent-<ULID>`、ActivityId = `act-<ULID>`。
- 認可 (表 11.1、主体は SourceVaultPrincipal[]):
  - Emit / Entity / Activity / Derive / Served はどの主体からも可。Actor と Role は記録点のコードが主体から決め、申告は Claimed に残すだけ。
  - IngestSpool / IngestAdapters / RebuildIndex / VerifyLedger / Checkpoint / RotateKey / SyncFeeds / JoinLLMCalls は Owner と Service のみ。
  - ChainRestart は Owner (OwnerFE / OwnerCode) + 所有者 ticket。
  - KeyedDigest は Model・MCP から呼べない (ProvNotAuthorized)。
- データ保護 (§12.2):
  - 本文・URL・送信者を台帳に書かない。Context の禁止キー (Url / Sender / Body 等の平文キー) は拒否する。
  - 外部識別子は SourceVaultProvKeyedDigest を使う。用途ごとに別鍵で、KeyId つき、呼出し回数を記録する。
  - 台帳・索引は同期しない LocalState に置く。
  - PL >= 0.5 の版の BlobId は Model / MCP への応答に出さず、feeds にも射影しない。
- 依存: service-loadable で、FrontEnd / Notebook / NBAccess に依存しない。NBAccess_crypto (NBMacWithKeyRef) と SourceVault_autotrigger (所有者 ticket) には弱結合。
- 保存場所: `LocalState/provenance/{ledger,index,checkpoints,health,peers}`、`PrivateVault/provenance/feeds/<machine>/`。
- 主な索引・状態ファイル: index/index-meta.json、index/usability.wxf、index/seen-events.wxf、index/pending.wxf、index/llmcall-queue.wxf、health/keyrefs.json、health/keyed-digest-calls.json、health/feeds-state.json。
- 方針変数への代入は NBAccess の承認対象 (SourceVault_integrity.wl が登録)。

## 設定変数
### $SourceVaultProvSpoolRoot
型: Automatic | String, 初期値: Automatic
来歴 spool のディレクトリ。Automatic は `$UserBaseDirectory/ApplicationData/SourceVault/prov-spool` である。
ファイルは `producer-<pid>-<yyyymmdd>[-k].jsonl` で、1 行 1 JSON (Type / EventId / EventClass / Producer / ProducerPid / MachineTag / AtUTC / Record)。
`$SourceVaultProvSpoolRotateBytes` を超えると -k を増やして回転する。取込 (ACK) 後に、過去日の消化済みファイルだけを削除する。試験の seam。
### $SourceVaultProvSpoolRotateBytes
型: Integer, 初期値: 20*1024*1024
spool ファイルを回転する大きさ。
### $SourceVaultProvProducer
型: Automatic | String, 初期値: Automatic
spool ファイル名と Record の Producer に使う producer 名。Automatic は FE なら fe、service なら service、それ以外は wl。
### $SourceVaultProvKeyRefs
型: Association, 初期値: 下記の 5 用途
形式は `<|purpose -> <|"KeyRef" -> NBAccess の KeyRef, "KeyId" -> 行に付ける短い id|>|>`。
- LedgerMac → `SourceVault:prov:ledger-mac:v1` / `ledger-mac-v1` (台帳の行と checkpoint の Mac)
- ExternalRef → `SourceVault:prov:externalref:v1` / `externalref-v1`
- Prompt → `SourceVault:prov:prompt:v1` / `prompt-v1`
- ToolArgs → `SourceVault:prov:toolargs:v1` / `toolargs-v1`
- Sync → `SourceVault:prov:sync:v1` / `sync-v1`
用途ごとに別鍵である。値が文字列 (KeyRef のみ) でもよく、その場合 KeyId は既定生成される。
KeyRef は NBMacWithKeyRef で解決し、鍵材料はこのモジュールに来ない。development profile に限り `"literal:<key>"` を鍵材料として使える (試験用)。production で literal 鍵があると SourceVaultSecurityProfileCheck[] が Error を出す。
### $SourceVaultProvRetiredKeyRefs
型: Association <|KeyId -> KeyRef|>, 初期値: <||>
更新で退役した鍵。検証にだけ使い、新しい digest には使わない。SourceVaultProvRotateKey が追加し、health/keyrefs.json に写す。
### $SourceVaultProvEmitBudgetMs
型: Number, 初期値: 50
emit 1 回の上限 (ms)。超過は数えて SourceVaultProvStatus[] の Emit/Slow に出す (止めない)。
### $SourceVaultProvIngestBudgetSeconds
型: Number, 初期値: 20
SourceVaultProvIngestSpool の 1 回の予算。超過分は持ち越す (CarriedOver)。
### $SourceVaultProvPendingTimeoutSeconds
型: Number, 初期値: 600
参照先の Entity が無い Activity を保留する時間。超えると Completeness Partial で確定する。
### $SourceVaultProvSessionKey
型: String | None, 初期値: None
現在の文脈組み立ての SessionKey (`provider|sessionKey`、LineageId の代用) を供給点に見せる動的変数。claudecode が文脈組み立て (tool loop・API 呼び出し) の前に Block で束縛する。
### $SourceVaultProvJoinWindowSeconds
型: Number, 初期値: 1800
LLMCall と同じ SessionKey の ServedToContext を結合する時刻窓 (LLMCall の前)。
### $SourceVaultProvJoinGraceSeconds
型: Number, 初期値: 90
取り込んだ LLMCall を結合するまでの猶予。別 producer の spool にある ServedToContext が同じ tick で届くのを待つ。試験では 0。
### $SourceVaultProvCheckpointLines
型: Integer, 初期値: 1000
Periodic checkpoint を書く行数。前回の checkpoint からこの行数を超えるか、`$SourceVaultProvCheckpointIntervalSeconds` を過ぎるか、サービス停止 (ServiceStop) のうち、最も早いもので書く。
### $SourceVaultProvCheckpointIntervalSeconds
型: Number, 初期値: 3600
Periodic checkpoint の最長間隔 (秒)。
### $SourceVaultProvFeedRetentionDays
型: Number, 初期値: 90
feeds の射影 (projection/YYYY-MM-DD.jsonl) の保持日数。checkpoint の写しは無期限。
### $SourceVaultProvSyncDigestKinds
型: List, 初期値: {}
feeds の射影に照合用の SyncDigest (同期鍵による BlobId の鍵付き digest) を付ける Entity の Kind のリスト。{} は付けない。所有者が射影を許した種類だけに付ける。PL >= 0.5 の版は射影しない。
### $SourceVaultProvScoreBudgetSeconds
型: Number, 初期値: 2
レビュー順の点数 (§8.3〜8.4) を索引の保存ごとに計算し直す予算 (秒)。超えた分は持ち越して Stale とし、次の保存で続きから計算する。

## 正準化と識別子
### SourceVaultProvCanonicalize[x, opts] → <|"CanonVersion", "Kind", "Bytes" -> ByteArray|>
x を digest 用に正準化する (§4.2)。
Options: "Kind" -> Automatic ("Bytes" | "Text" | "File" | "Cell" | "Expression")、"CanonVersion" -> 1 (0 も可)
CanonVersion 1 の規則:
- ファイル・ByteArray はバイト列そのもの。
- テキストは UTF-8 (先頭 BOM を除く)・改行は LF・Unicode 正規化なし。
- Association / List は、キーを符号位置順にした JSON。
  - 整数はそのまま。
  - 有理数は `{"$rational":"p/q"}`。
  - 実数は最短往復の桁を `d.ddde<exp>` にする。
  - `Missing[r]` は `{"$missing":r}`。
  - 記号は `{"$symbol":"Context`Name"}`。
  - True / False / Null は JSON の true / false / null。
  - DateObject は UTC の ISO 文字列。
  - ByteArray は `{"$bytes":base64}`。
- Cell は可変オプション (CellChangeTimes / CellID / CellLabel / CellLabelAutoDelete / ExpressionUUID) を除いた InputForm を Association 規則で包む。
CanonVersion 0 は既存の SourceVaultCanonicalizeForDigest (Association のみ、キーは WL の Sort 順、揮発 field を除く、RawJSON の表現) をそのまま返す (比較・移行用)。
### SourceVaultProvBlobId[x, opts] → <|"BlobId" -> "blob:sha256:<hex64>", "CanonVersion", "Kind", "Size"|>
x の BlobId を返す。opts は SourceVaultProvCanonicalize と同じ。
既存の blob (SourceVaultCommitBlob) の hex は CanonVersion 1 の Bytes と一致する。既存の snapshot (SourceVaultSnapshotDigest = CanonVersion 0) の hex は一致しないので共有しない。
### SourceVaultProvMerkleRoot[lineHashes] → "sha256:<hex64>"
台帳の LineHash の列 (`"sha256:<hex64>"` の文字列) の Merkle 根 (RFC 6962 Merkle Tree Hash)。
- 葉 = SHA-256(0x00 || UTF-8(LineHash))
- 節 = SHA-256(0x01 || 左 || 右)
- 空列は SHA-256 の空文字列
checkpoint の MerkleRoot は FirstSeq〜LastSeq の行 (欠落区間は除く) の根。

## 記録 (emit 側。どの主体・カーネルからも可)
### SourceVaultProvEmit[rec] → <|"Status" -> "Spooled", "EventId" -> ULID, "Ms", "Path"|> | Failure
rec (Type が ProvBlob / ProvEntity / ProvActivity の Association) を正準化して spool に 1 行追記する。
Failure: ProvBadRecord / ProvCanonicalizeFailed / ProvSpool*Failed (ProvSpoolDirUnwritable / ProvSpoolOpenFailed 等)。
Spooled は確定ではない。失敗は数えるだけで例外を投げない (呼び側は続行できる)。1 回 0.2 ms 程度。
### SourceVaultProvEntity[spec] → <|"Status" -> "Spooled", "EntityId", "BlobId", "CanonVersion", "PrivacyLevel", "Origin", "EventIds", "Ms"|> | Failure
資料・成果物の 1 つの版 (Entity) と、その内容の Blob を spool に記録する (§4.3)。不正な spec は Failure["ProvBadEntitySpec"] を返す。
spec キー:
- "Kind" (表 4.1、必須)。
- "Content" (式・文字列・ByteArray) | "ContentRef" (ファイルパス) | "BlobId" のいずれか。
- "ContentKind"、"LogicalRef"、"VersionOf"、"Media"、"Completeness"。
- "Refs" -> <|SourceId / ArtifactId ..|>。
- "Context" -> <|Channel, ExternalRefDigest, ...|>。Url / Sender / Body 等の平文キーは拒否する。
- "PrivacyLevel" (無ければ $SourceVaultDefaultObjectPrivacyLevel)。
- "Origin" -> <|Contributors, Taints|>。無ければ Kind から決める。PrimarySource は External (Taint `ext:<channel>`)、OwnerAuthored は Owner (Taint `edit:owner`)、他は不明 = OriginClass Unknown。
- "ProducedBy" -> {ActivityId..}。
OriginClass: Contributors 空 / Unknown 含む → Unknown、External 含む → ExternalDerived、Model 含む → ModelOverOwner、{"Owner"} → OwnerOnly。
### SourceVaultProvActivity[spec] → <|"Status" -> "Spooled", "ActivityId" -> "act-<ULID>", "EventId", "Actor", "Ms"|>
1 回の処理 (Activity) を spool に記録する (§4.4)。
spec キー:
- "Kind" (表 4.2)。
- "Inputs" -> {EntityId | <|"EntityId", "Role"|>..}。Role は Instruction / Context / Quote / Code / AttachmentOf / Contains / Cite で、既定 Context。
- "Outputs"、"ModelRef"、"Provider"、"ToolCalls"、"InputsCompleteness"、"UnrecordedInputs"、"ExternalRefs"、"Outcome"。
- "PromptDigest" (`hmac:..`) | "Prompt" (鍵付き digest にして平文は残さない)。
- "LineageId" | "SessionKey"。
Actor は記録点の主体 (SourceVaultPrincipal[]) から決め、spec の "Actor" は Claimed に残すだけ。
### SourceVaultProvDerive[kind, inputs, outputs, opts] → <|"Status", "ActivityId", "Outputs" -> {EntityId..}, "Entities", "Activity"|>
1 回の派生の糖衣。outputs の Entity spec を ProducedBy つきで記録してから Activity を記録する。
outputs の要素は EntityId 文字列か SourceVaultProvEntity の spec。opts は SourceVaultProvActivity の spec の残り (Association か規則)。
### SourceVaultProvAwaitCommitted[ids, timeout] → <|"Status" -> "Committed" | "Timeout", "Committed" -> {..}, "Pending" -> {..}, "Seconds"|>
EntityId / ActivityId が Committed になるまで最大 timeout 秒待つ。service が止まっていれば Timeout になる (Authorize / Publish はそこで止める)。
### SourceVaultProvKeyedDigest[s, purpose] → "hmac:<KeyId>:<hex64>"
purpose (ExternalRef / Prompt / ToolArgs / Sync) の MAC 鍵による鍵付き digest。NBMacWithKeyRef の薄い包みで、HMAC を新規実装しない。
Model・MCP の主体からは呼べず (Failure["ProvNotAuthorized"])、呼出し回数を用途ごとに health/keyed-digest-calls.json に記録する。鍵が無ければ Failure["ProvKeyUnavailable"]。

## 供給点・SessionKey・確定の関門 (Inc2)
### SourceVaultProvSessionKey[] → String | None
供給点が ServedToContext に付ける SessionKey を返す。順序は `$SourceVaultProvSessionKey` (Block 束縛) → 主体の SessionId (`"mcp|<SessionId>"`) → None。
### SourceVaultProvServed[specs, opts]
供給点 (SourceVaultSearch / KBAnswer / MCP get・search・get_document / NBAccess の読取) が文脈へ渡した Entity 群を、ServedToContext Activity として SessionKey・Role・PL つきで記録する (§6.1 / §6.2)。
specs: `{<|"LogicalRef", "Refs", "Kind", "PrivacyLevel", "Content" | "ContentRef" | "BlobId" | "ClaimedContentHash", "Role", "Media", "Origin"|>..}`
- 内容に届けば BlobId を計算する。届かなければ ClaimedContentHash で Partial にする。
- SessionKey も主体の束縛も無い呼び出し (手動の検索・試験) は記録しない (Skipped / NoSessionContext)。
- 同じ LogicalRef・内容・PL の Entity は 1 時間はこのカーネルで再利用する (Reused)。
- どの主体からも呼べる。失敗は数えるだけで止めない。
→ <|"Status" -> "Spooled" | "Skipped" | "Failed", "ActivityId", "EntityIds", "SessionKey", "Reused"|>
Options: "SupplyPoint" -> (名前), "Role" -> Context (検索結果・KB passage = Context、fs_read / get_document の本文 = Quote、Directives = Instruction), "SessionKey" -> Automatic (= SourceVaultProvSessionKey[]), "MaxEntities" -> 50
### SourceVaultProvRequireCommitted[ids, timeout] → <|"Status" -> "Committed", "Seq"|> | Failure
確定を要求する関門 (Authorize / Publish / PL >= 0.5 の自動処理、§6.1 / §12.5) の共通関数。
ids は EntityId / ActivityId か SourceVaultProvEntity / Activity の戻り値。
モジュールが使えない、または emit が失敗している (Failure が混じる) なら Failure["ProvenanceUnavailable"]。timeout 秒で確定しなければ Failure["ProvenanceNotCommitted"]。
### SourceVaultProvJoinLLMCalls[opts] → <|"Status", "Joined", "Unjoined", "Unrecorded", "Deferred", "Seconds"|>
取り込んだ LLMCall イベント (claudecode の prov-spool、Type ProvLLMCall) を、同じ SessionKey の ServedToContext と時刻窓で結合する (§6.1)。結果として LLMGenerate Activity を台帳に作る。
- Inputs = 結合した Entity と Role。
- Outputs = 応答 Entity (出力の SHA-256 を BlobId に)。
- Actor = Model + ModelRef (IdentityEvidence Claimed)。
- Completeness: 宣言した種類 (DeclaredInputs) が全部結合できれば Complete、一部なら Partial、結合できなければ Inputs 無しで Unknown。
- SessionKey の無い LLMCall は UnrecordedLLMDerivations として数える。
Owner / Service のみ。service の tick が取込の後に呼ぶ。
Options: "BudgetSeconds", "GraceSeconds" (既定は $SourceVaultProvJoinGraceSeconds)
### SourceVaultProvCoverage[days] → <|"WindowDays", "Total", "Complete", "Ratio", "ByKind", "Instruction", "SupplyPoint", "OutsideSupplyPoints", "UnrecordedLLMDerivations", "Backfilled", "IndexSeq"|>
直近 days 日の派生 Entity (DerivedText / DerivedCode / Answer / KnowledgeEdge / Instruction) のうち、Completeness Complete で、LLM 由来なら ModelRef と IdentityEvidence が揃うものの割合を返す (§7.1)。読取専用。
- Backfilled の版は分母から除く。
- Total / Complete / Ratio は Instruction を除く派生だけ。Instruction の基準の充足は "Instruction" と ByKind に出る。
- ByKind -> `<|kind -> <|Total, Complete, Ratio|>|>`。
- "SupplyPoint": 供給点を通った派生 (SessionKey つきの LLMGenerate が作った版、Inc2 の分母)。
- "OutsideSupplyPoints" -> `<|"LLMWithoutSessionKey", "NonLLM"|>`: 供給点の外の派生の件数。

## 取込・台帳・索引 (service。Owner / Service のみ)
### SourceVaultProvIngestSpool[opts]
spool → 台帳の取込。単一書き手は service である。
- 読取位置 (ファイル名・バイト位置) は index/index-meta.json に持つ。EventId で重複を除き、Seq を割り当てて ledger/YYYY-MM.jsonl に追記する (Ingested)。
- 閉じて開き直し末尾を確認して DurableSeq を更新する (Durable)。索引を差分更新し、読取位置を進める (ACK)。
- 改行の無い末尾行は持ち越す。壊れた JSON は Corrupt に計上して他を取り込む。
- 参照先の Entity が無い Activity は保留し、`$SourceVaultProvPendingTimeoutSeconds` で Partial 確定する。同じ BlobId の ProvBlob は 1 件。
→ <|"Status" -> "OK" | "CarriedOver", "Ingested", "Corrupt", "Duplicates", "BlobDuplicates", "Rejected", "PendingHeld", "PendingFlushed", "Files", "Pruned", "LastSeq", "DurableSeq", "IndexSeq", "Pending", "Seconds"|> | Failure (ProvNotAuthorized / ProvMacKeyUnavailable / ProvChainDamaged)
Options: "BudgetSeconds" -> $SourceVaultProvIngestBudgetSeconds (超過は持ち越し), "MaxLines" -> (行数上限)
### SourceVaultProvIngestAdapters[opts] → <|"Status", "Adapter" -> 件数, "ByAdapter", "Seconds"|>
既存ログの adapter (§6.3) を offset つきで読み、Execute 等の Activity として台帳に取り込む。
組み込み: mcp_calls (SourceVaultRecordMCPCall の月次 JSONL)、web_access (webguard のアクセスログ)、reference_events、mcp_deposits。
URL・query・本文は入れない (Host は ExternalRef の鍵付き digest)。
Options: "BudgetSeconds" -> (予算), "Adapters" -> All (または {name..})
### SourceVaultProvRegisterAdapter[name, spec] → name
spool adapter を登録する (冪等)。不正な引数は $Failed。
spec = `<|"Files" -> f (f[] がファイル一覧), "Parse" -> g (g[行の Association] が Record の Association のリスト), "MaxLinesPerTick" (既定 2000)|>`
g が返す Record は Type ProvActivity / ProvEntity / ProvBlob で、EventId は行の digest から決定的に付く (再読込で重複しない)。
### SourceVaultProvVerifyLedger[opts]
台帳の連鎖・LineHash・MAC・checkpoint (Merkle 根を含む) を検証し、feeds の写しと他機の証言と照合する。
→ <|"Status" -> "OK" | "Failing" | "Inconclusive", "Verified", "Findings", "Assurance", "Scope", "NotCovered"|>
- "Verified" -> `<|"Lines", "FromSeq", "ToSeq", "MacChecked", "KeyUnavailable", "Checkpoints", "MerkleChecked", "FeedCheckpoints", "PeerWitnesses", "FeedsCompared"|>`
- "Findings" -> `{<|"Kind", "Seq", "File", "Line", "Detail"|>..}`
- Kind:
  - 台帳: Corrupt / SeqGap / SeqReorder / ChainBreak / LineHashMismatch / MacMismatch / TailTruncated
  - checkpoint: CheckpointMismatch / CheckpointMacMismatch / CheckpointMerkleMismatch
  - feeds の写し・他機の証言との照合 (Inc1b): FeedCheckpointMismatch / FeedMerkleMismatch / FeedCheckpointBeyondLedger / LocalCheckpointMissing / FeedSyncMacMismatch / FeedCheckpointCorrupt / WitnessMismatch / WitnessBeyondLedger / PeerWitnessSyncMacMismatch
  - 情報扱い: ChainRestart (連鎖の再開の記録) / CheckpointSuperseded (欠落区間を見ていた checkpoint)
結果の表現は表 4.5 の範囲を超えない (「MAC 鍵に届かない改変は検出されなかった (Seq n まで)」)。feeds の写しは同じユーザー・同じ同期アカウントから書き換えられるので独立した証人ではない。台帳・checkpoint・feeds・他機の証言を整合的に作り直す書き換えや巻き戻しは検知しない。
Options: "Since" -> Automatic (Seq | "YYYY-MM"。Seq のときは 2 行以上手前を行頭の Seq だけ読んで飛ばす), "MaxLines" -> Infinity, "Checkpoints" -> True, "Feeds" -> Automatic (feeds があれば照合 | True | False)
### SourceVaultProvRebuildIndex[] → <|"Status", "Entities", "Activities", "Blobs", "LastSeq", "Digest", "Seconds"|>
台帳から索引 (graph / logical / labels / effective / usability) を決定的に再構築する。
再構築中は index-meta.json の Rebuilding が True で、Usability は Unknown になる。差分更新と再構築は同じ適用関数を Seq 順に使うので Digest が一致する (T-P5)。
### SourceVaultProvIndexDigest[]
メモリ上の索引 (読んでいなければ WXF から読む) の決定的な digest (sha256 hex) と件数を返す。再構築前後の一致確認に使う。
### SourceVaultProvCheckpoint[opts]
`LocalState/provenance/checkpoints/` に checkpoint を書く。内容は FirstSeq〜LastSeq、最終 LineHash、その区間の Merkle 根 (SourceVaultProvMerkleRoot)、TreeSize、前の checkpoint、MAC。
`PrivateVault/provenance/feeds/<machine>/checkpoints/` には、同期鍵の SyncMac つきの写しを置く (Inc1b)。
- 前回から新しい行が無ければ NoNewLines。
- 台帳の末尾が index-meta.json と合わなければ書かない (Failure["ProvCheckpointLedgerMismatch"])。
- feeds への写しの失敗は checkpoint を止めない ("FeedCopy" に出し、SourceVaultProvSyncFeeds が後で写す)。
Options: "Reason" -> "Periodic" | "Daily" | "ServiceStop" | "Manual"
- Periodic: 前回から `$SourceVaultProvCheckpointLines` 行か `$SourceVaultProvCheckpointIntervalSeconds` 秒のどちらかを超えたときだけ書く。それ以外は NotDue。
- Daily: YYYY-MM-DD.json に書く。その日のファイルが既にあれば Exists。
- Manual: 時刻つきの別ファイルに書く。
### SourceVaultProvChainRestart[spec, ticket]
破損・欠落の後に新しい連鎖を始める (§12.8)。Owner (OwnerFE / OwnerCode) + 所有者 ticket (Action `"ProvChainRestart"`、Bind に Display / LastVerifiedSeq / LastVerifiedLineHash の digest) が要る。
spec = `<|"LastVerifiedSeq", "LastVerifiedLineHash", "DetectedBy", "Note", "Display"|>`
最初の行を ProvChainRestart レコード (旧連鎖の最後に検証できた LineHash と Seq、欠落区間、検出の経緯、ticket の nonce) にし、ChainState を OK に戻す。索引を台帳から作り直す (欠落区間の版は索引から消える)。VerifyLedger は再開の記録を ChainRestart、欠落区間を見ていた checkpoint を CheckpointSuperseded として情報扱いにする。
### SourceVaultProvRotateKey[purpose, <|"KeyRef", "KeyId"|>, opts]
用途 purpose の鍵を更新し、更新の時点を ProvKeyRotation レコードとして台帳に残す (§12.8)。旧鍵は `$SourceVaultProvRetiredKeyRefs` に移り、検証にだけ使う。Owner / Service。
Options: "Reason" -> (文字列)
### SourceVaultProvStatus[] → <|"Emit", "Spool", "Meta", "KeyedDigestCalls", "LedgerMacKeyAvailable", "Profile"|>
来歴台帳の状態 (件数と状態だけ。本文・ID の一覧は含まない)。
- "Emit" -> `<|Count, Failed, Slow, TotalMs, MaxMs, LastError|>`
- "Meta": LastSeq / DurableSeq / IndexSeq / ChainState / CarryOver / Pending ..
### SourceVaultProvResetCaches[]
このカーネルのメモリ上の状態 (索引・seen・保留・spool の現在ファイル・FE の usability キャッシュ) を捨てる。service の再起動を模す試験の seam。emit の統計は残す。

## feeds・複数機照合 (Inc1b)
### SourceVaultProvSyncFeeds[opts]
feeds (`PrivateVault/provenance/feeds/<machine>/`、Dropbox 同期、書き手は各機 1 つ) を更新し、他機の feeds と照合する (§12.1〜12.3)。Owner / Service のみ。
- 自機:
  - checkpoints/ に checkpoint の写し (SyncMac つき、無期限)。
  - projection/YYYY-MM-DD.jsonl に、PL < 0.5 の版だけの射影 (SyncId・Kind・OriginClass・Usability・PL と関係)。保持は `$SourceVaultProvFeedRetentionDays` 日。
  - manifest.json。
  - witness.json (他機の checkpoint を自機が見た記録)。
  - SyncId は版ごとの乱数で、内容から計算しない。BlobId・EntityId・LogicalRef・本文は出さない。
- 他機: checkpoint の写しの SyncMac を確かめる。LocalState/provenance/peers/<machine>.json の記録と比べ、食い違い (PeerCheckpointChanged)・巻き戻し (PeerRollback)・消失 (PeerCheckpointMissing) を検出する。他機の witness.json に書かれた自機の checkpoint を自機の checkpoint と比べる (WitnessMismatch / WitnessBeyondLedger)。
- 結果は health/feeds-state.json に書く。他機の射影の統合は Inc6。
→ <|"Status" -> "OK" | "Degraded" | "Failing" | "FeedUnavailable", "Own", "Peers", "Findings", "Seconds"|>
Options: "Projection" -> True, "Peers" -> True
### SourceVaultProvFeedStatus[] → Association | Missing["NotFound"]
直近の SourceVaultProvSyncFeeds の結果 (health/feeds-state.json。件数・状態・Finding のメタデータだけ) を返す。無ければ Missing["NotFound"]。

## 問い合わせ (§11.2)
### SourceVaultProvResolve[ref] → <|"Status" -> "Found" | "NotFound", "Ref", "EntityIds", "Latest", "Versions"|>
EntityId / BlobId / LogicalRef (sv:// URI、パス、名前) / Refs の値 (SourceId / ArtifactId ..) から版の列を返す。
- "EntityIds" は古い順。
- "Versions" -> `{<|"EntityId", "Seq", "Kind", "PrivacyLevel", "BlobId", "LogicalRef", "Usability"|>..}`
Model / MCP の主体には PL >= 0.5 の版の BlobId を出さない。
### SourceVaultProvHumanEditedQ[ref] → True | False | Missing["NotFound"]
ref の版のどれかが HumanEdit の Activity で作られた (手で直した派生物) なら True (§7.4 / §11.4)。書込口が上書き前に呼ぶ。
### SourceVaultProvUsability[id] → <|"Usability", "Seq", "IndexSeq", "DurableSeq", "Committed"|>
Entity (または Activity) の利用可否 (§5.6)。`SourceVaultProvUsability[{id..}]` は一括。
"Usability" は Usable | Pending | Unknown | Quarantined | Recorded。判定 (Inc1a):
- Usable: Committed かつ OriginClass != Unknown かつ Completeness Complete。
- Pending: このカーネルが spool したが未確定。
- Unknown: 索引が古い・壊れている・再構築中、Completeness が Partial / Unknown、または OriginClass が Unknown。
FE 側は usability.wxf を読み、index-meta.json の IndexSeq が進んだときだけ読み直す (Seq による無効化)。
### SourceVaultProvUsabilityIndexLoad[] → <|"IndexSeq", "DurableSeq", "Count", "LoadSeconds", "Ids", "Codes", "Seq"|> | Failure
usability.wxf (EntityId → Usability 符号と Seq だけの小さな索引) を読む。10 万 Entity で読込 < 50 ms が目標 (Y-08)。
Failure: ProvIndexUnavailable (ファイル無し) / ProvIndexCorrupt (形式不正)。

## 備考
- Inc3 (ラベル・隔離・出自の合成)、V9 (Grounding)、Inc5 (レビュー順の点数) の内部関数が本ファイルにあるが、上記以外の公開シンボルとして宣言されたものは見当たらない。
- 公開 API の戻り値の Failure 名は `ProvBadRecord` / `ProvBadEntitySpec` / `ProvNotAuthorized` / `ProvKeyUnavailable` / `ProvMacKeyUnavailable` / `ProvChainDamaged` / `ProvCheckpointLedgerMismatch` / `ProvenanceUnavailable` / `ProvenanceNotCommitted` / `ProvIndexUnavailable` / `ProvIndexCorrupt`。