(* ::Package:: *)

(* ============================================================
   SourceVault_provenance.wl -- 来歴台帳の中核 (03 SystemDoctor 拡張仕様 v0.4 §13.1 Inc1a、2026-11-09 第 3 週)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_provenance.wl"]]

   範囲 (Inc1a): Blob / Entity の分離と正準化 (§4.1〜4.3、CanonVersion 1)・emit・spool・既存ログの adapter (§6.3)・
   Ingest と確定の契約 (§12.8)・PrevHash 連鎖・MAC (NBAccess の鍵 index の MAC 鍵、NBMacWithKeyRef)・簡易 checkpoint
   (最終 LineHash と Seq の日次記録)・graph / logical / labels / effective / usability 索引・再構築。
   範囲外: Merkle 根・feeds の射影・複数機照合 (Inc1b)、5 つの記録点・backfill・LLMCall の SessionKey (Inc2)、
   ラベルの合成・隔離・検索フィルタ・認可 (Inc3)。

   分担 (§3.2): emit はどのカーネルでも (spool への追記だけ、失敗は数えて元の処理を止めない)。Ingest・台帳・索引・
   checkpoint は service カーネルが単一書き手として行う (SourceVaultIntegrityServiceTick が 60 秒ごとに呼ぶ)。
   FE は usability.wxf (EntityId → Usability と Seq だけの小さな索引) を Seq で無効化するキャッシュ越しに読む。

   確定の契約 (§12.8): Spooled (1 行を 1 回の BinaryWrite で追記して閉じた) → Ingested (service が Seq を割り当て
   台帳に追記) → Durable (閉じて開き直し末尾を確かめ DurableSeq を更新、spool の読取位置を進める = ACK) →
   Committed (Durable かつ索引が DurableSeq まで反映)。SourceVaultProvAwaitCommitted はそれを待つ。

   台帳の行 (§4.8): {"Seq","PrevHash","EventId","Record","LineHash","Mac"}。
   LineHash = sha256(Seq | PrevHash | Record の正準 JSON 原文)、Mac = HMAC-SHA256(鍵 index の MAC 鍵, LineHash) に KeyId。
   Record の原文は producer が書いた正準 JSON をそのまま埋め、検証は行から原文を切り出して再計算する
   (JSON を読み直して再直列化しない: RawJSON の import は 1.0e2 を整数に戻す)。

   認可 (表 11.1、主体は第 2 週の SourceVaultPrincipal[]): Emit / Entity / Activity / Derive はどの主体からも可
   (Actor と Role は記録点のコードが主体から決め、申告は Claimed に残すだけ)。IngestSpool / IngestAdapters /
   RebuildIndex / VerifyLedger / Checkpoint / RotateKey は Owner と Service のみ、ChainRestart は Owner + 所有者 ticket。
   KeyedDigest は Model・MCP から呼べない (辞書攻撃の代行を防ぐ)。

   データ保護 (§12.2): 本文・URL・送信者を台帳に書かない (Context の禁止キーは拒否)。外部識別子は
   SourceVaultProvKeyedDigest (用途ごとに別鍵、KeyId つき、呼出し回数を記録)。台帳・索引は同期しない LocalState。
   PL >= 0.5 の版の BlobId は Model / MCP への応答に出さない。

   service-loadable: FrontEnd / Notebook / NBAccess 非依存 (NBAccess_crypto の NBMacWithKeyRef と
   autotrigger の所有者 ticket には弱結合)。
   ============================================================ *)

BeginPackage["SourceVault`"]

(* ---- 設定 (方針変数。代入は NBAccess の承認対象: SourceVault_integrity.wl が登録) ---- *)
$SourceVaultProvSpoolRoot::usage =
  "$SourceVaultProvSpoolRoot は来歴 spool のディレクトリ (既定 Automatic = $UserBaseDirectory/ApplicationData/SourceVault/prov-spool)。\n" <>
  "producer-<pid>-<yyyymmdd>[-k].jsonl に 1 行 1 JSON (診断 spool と同じ形: Type / EventId / EventClass / Producer / ProducerPid / MachineTag / AtUTC / Record)。\n" <>
  "20 MB ($SourceVaultProvSpoolRotateBytes) で -k を増やして回転する。取り込み (ACK) の後、過去日の消化済みファイルだけを削除する。試験の seam。";
$SourceVaultProvSpoolRotateBytes::usage = "$SourceVaultProvSpoolRotateBytes は spool ファイルを回転する大きさ (既定 20 MB)。";
$SourceVaultProvProducer::usage =
  "$SourceVaultProvProducer は spool ファイル名と Record の Producer に使う producer 名 (既定 Automatic: FE は fe、service は service、それ以外は wl)。";
$SourceVaultProvKeyRefs::usage =
  "$SourceVaultProvKeyRefs は用途ごとの MAC 鍵 <|purpose -> <|\"KeyRef\" -> NBAccess の KeyRef, \"KeyId\" -> 行に付ける短い id|>|>。\n" <>
  "purpose: LedgerMac (台帳の行と checkpoint の Mac)、ExternalRef (外部識別子の digest)、Prompt、ToolArgs、Sync。用途ごとに別鍵 (03 v0.4 §12.2)。\n" <>
  "KeyRef は NBAccess_crypto の NBMacWithKeyRef で解決する (鍵材料はこのモジュールに来ない)。development profile に限り \"literal:<key>\" を鍵材料として使える (試験用)。\n" <>
  "production で literal 鍵があると SourceVaultSecurityProfileCheck[] が Error を出す。代入は NBAccess の承認対象。";
$SourceVaultProvRetiredKeyRefs::usage =
  "$SourceVaultProvRetiredKeyRefs は更新で退役した鍵 <|KeyId -> KeyRef|>。検証にだけ使い、新しい digest には使わない (03 v0.4 §12.2 鍵の管理)。\n" <>
  "SourceVaultProvRotateKey が追加し LocalState/provenance/health/keyrefs.json に写す。";
$SourceVaultProvEmitBudgetMs::usage =
  "$SourceVaultProvEmitBudgetMs は emit 1 回の上限 (既定 50 ms、03 v0.4 §12.4)。超過は数えて SourceVaultProvStatus[] の Emit/Slow に出す (止めない)。";
$SourceVaultProvIngestBudgetSeconds::usage =
  "$SourceVaultProvIngestBudgetSeconds は SourceVaultProvIngestSpool の 1 回の予算 (既定 20 秒)。超過分は持ち越す (CarriedOver)。";
$SourceVaultProvPendingTimeoutSeconds::usage =
  "$SourceVaultProvPendingTimeoutSeconds は参照先の Entity が無い Activity を保留する時間 (既定 600 秒)。超えると Completeness Partial で確定する (03 v0.4 §12.8)。";

(* ---- 正準化と識別子 (§4.1〜4.2) ---- *)
SourceVaultProvCanonicalize::usage =
  "SourceVaultProvCanonicalize[x, opts] は x を digest 用に正準化し <|\"CanonVersion\", \"Kind\", \"Bytes\" -> ByteArray|> を返す (03 v0.4 §4.2)。\n" <>
  "\"Kind\" -> Automatic | \"Bytes\" | \"Text\" | \"File\" | \"Cell\" | \"Expression\"。CanonVersion 1 (既定): ファイル・ByteArray はバイト列そのもの、\n" <>
  "テキストは UTF-8 (先頭 BOM を除く)・改行は LF・Unicode 正規化なし、Association / List はキーを符号位置順にした JSON (整数はそのまま、\n" <>
  "有理数は {\"$rational\": \"p/q\"}、実数は最短往復の桁を d.ddde<exp> に、Missing[r] は {\"$missing\": r}、記号は {\"$symbol\": \"Context`Name\"}、\n" <>
  "True/False/Null は JSON の true/false/null、DateObject は UTC の ISO 文字列、ByteArray は {\"$bytes\": base64})、Cell は可変オプション\n" <>
  "(CellChangeTimes 等) を除いた InputForm を Association 規則で包む。\"CanonVersion\" -> 0 は既存の SourceVaultCanonicalizeForDigest\n" <>
  "(Association のみ、キーは WL の Sort 順、揮発 field を除く、RawJSON の表現) をそのまま返す (比較・移行用)。";
SourceVaultProvBlobId::usage =
  "SourceVaultProvBlobId[x, opts] は x の BlobId <|\"BlobId\" -> \"blob:sha256:<hex64>\", \"CanonVersion\", \"Kind\", \"Size\"|> を返す (03 v0.4 §4.1)。\n" <>
  "opts は SourceVaultProvCanonicalize と同じ。既存の blob (SourceVaultCommitBlob) の hex は CanonVersion 1 の Bytes と一致する。既存の snapshot\n" <>
  "(SourceVaultSnapshotDigest = CanonVersion 0) の hex は一致しないので共有しない。";

(* ---- 記録 (§11.1) ---- *)
SourceVaultProvEmit::usage =
  "SourceVaultProvEmit[rec] は rec (Type が ProvBlob / ProvEntity / ProvActivity の Association) を正準化して spool に 1 行追記する。\n" <>
  "戻り値 <|\"Status\" -> \"Spooled\", \"EventId\" -> ULID, \"Ms\", \"Path\"|> か Failure (ProvBadRecord / ProvCanonicalizeFailed / ProvSpool*Failed)。\n" <>
  "Spooled は確定ではない (03 v0.4 §6.1 / §12.8)。失敗は数えるだけで例外を投げない (呼び側は続行できる)。1 回 0.2 ms 程度 (2026-11-09 実測)。";
SourceVaultProvEntity::usage =
  "SourceVaultProvEntity[spec] は資料・成果物の 1 つの版 (Entity) と、その内容の Blob を spool に記録する (03 v0.4 §4.3)。\n" <>
  "spec = <|\"Kind\" (表 4.1)、\"Content\" (式・文字列・ByteArray) | \"ContentRef\" (ファイルパス) | \"BlobId\"、\"ContentKind\"、\"LogicalRef\", \"VersionOf\",\n" <>
  "\"Refs\" -> <|SourceId / ArtifactId ..|>, \"Media\", \"Context\" -> <|Channel, ExternalRefDigest, ...|> (Url / Sender / Body 等の平文キーは拒否),\n" <>
  "\"PrivacyLevel\" (無ければ $SourceVaultDefaultObjectPrivacyLevel), \"Origin\" -> <|Contributors, Taints|> (無ければ Kind から: PrimarySource は External、\n" <>
  "OwnerAuthored は Owner、他は不明 = OriginClass Unknown), \"ProducedBy\" -> {ActivityId..}, \"Completeness\"|>。\n" <>
  "戻り値 <|\"Status\" -> \"Spooled\", \"EntityId\" -> \"ent-<ULID>\", \"BlobId\", \"CanonVersion\", \"PrivacyLevel\", \"Origin\", \"EventIds\", \"Ms\"|> か Failure。";
SourceVaultProvActivity::usage =
  "SourceVaultProvActivity[spec] は 1 回の処理 (Activity) を spool に記録する (03 v0.4 §4.4)。spec = <|\"Kind\" (表 4.2), \"Inputs\" -> {EntityId | <|\"EntityId\", \"Role\"|>..}\n" <>
  "(Role は Instruction / Context / Quote / Code / AttachmentOf / Contains / Cite、既定 Context), \"Outputs\", \"ModelRef\", \"Provider\", \"PromptDigest\" (hmac:..) | \"Prompt\"\n" <>
  "(鍵付き digest にして平文は残さない), \"ToolCalls\", \"InputsCompleteness\", \"UnrecordedInputs\", \"LineageId\" | \"SessionKey\", \"ExternalRefs\", \"Outcome\"|>。\n" <>
  "Actor は記録点の主体 (SourceVaultPrincipal[]) から決め、spec の \"Actor\" は Claimed に残すだけ。戻り値 <|\"Status\" -> \"Spooled\", \"ActivityId\" -> \"act-<ULID>\", \"EventId\", \"Actor\", \"Ms\"|>。";
SourceVaultProvDerive::usage =
  "SourceVaultProvDerive[kind, inputs, outputs, opts] は 1 回の派生の糖衣: outputs の Entity spec (Association) を ProducedBy つきで記録してから Activity を記録する。\n" <>
  "outputs の要素は EntityId 文字列か SourceVaultProvEntity の spec。opts は SourceVaultProvActivity の spec の残り (Association か規則)。\n" <>
  "戻り値 <|\"Status\", \"ActivityId\", \"Outputs\" -> {EntityId..}, \"Entities\", \"Activity\"|>。";
SourceVaultProvAwaitCommitted::usage =
  "SourceVaultProvAwaitCommitted[ids, timeout] は EntityId / ActivityId が Committed (台帳で Durable かつ索引が反映) になるまで最大 timeout 秒待つ (03 v0.4 §12.8)。\n" <>
  "戻り値 <|\"Status\" -> \"Committed\" | \"Timeout\", \"Committed\" -> {..}, \"Pending\" -> {..}, \"Seconds\"|>。service が止まっていれば Timeout になる (Authorize / Publish はそこで止める)。";
SourceVaultProvKeyedDigest::usage =
  "SourceVaultProvKeyedDigest[s, purpose] は用途 purpose (ExternalRef / Prompt / ToolArgs / Sync) の MAC 鍵による鍵付き digest \"hmac:<KeyId>:<hex64>\" を返す\n" <>
  "(NBAccess_crypto の NBMacWithKeyRef の薄い包み、HMAC を新規に実装しない)。Model・MCP の主体からは呼べず (ProvNotAuthorized)、呼出し回数を用途ごとに数えて\n" <>
  "LocalState/provenance/health/keyed-digest-calls.json に記録する (03 v0.4 §12.2)。鍵が無ければ Failure[\"ProvKeyUnavailable\"]。";

(* ---- 取込・台帳・索引 (service、§11.1〜11.3) ---- *)
SourceVaultProvIngestSpool::usage =
  "SourceVaultProvIngestSpool[opts] は spool → 台帳の取込 (Owner / Service のみ、単一書き手は service)。読取位置 (ファイル名・バイト位置) は\n" <>
  "LocalState/provenance/index/index-meta.json、EventId で重複を除き、Seq を割り当てて ledger/YYYY-MM.jsonl に追記 (Ingested)、閉じて開き直し\n" <>
  "末尾を確かめ DurableSeq を更新 (Durable)、索引を差分更新、読取位置を進める (ACK)。改行の無い末尾行は持ち越し、壊れた JSON は Corrupt に計上して\n" <>
  "他を取り込む。参照先の Entity が無い Activity は保留し $SourceVaultProvPendingTimeoutSeconds で Partial 確定。同じ BlobId の ProvBlob は 1 件。\n" <>
  "opts: \"BudgetSeconds\" (既定 $SourceVaultProvIngestBudgetSeconds、超過は持ち越し)、\"MaxLines\"。\n" <>
  "戻り値 <|\"Status\" -> \"OK\" | \"CarriedOver\", \"Ingested\", \"Corrupt\", \"Duplicates\", \"BlobDuplicates\", \"Rejected\", \"PendingHeld\", \"PendingFlushed\",\n" <>
  "\"Files\", \"Pruned\", \"LastSeq\", \"DurableSeq\", \"IndexSeq\", \"Pending\", \"Seconds\"|> か Failure (ProvNotAuthorized / ProvMacKeyUnavailable / ProvChainDamaged)。";
SourceVaultProvIngestAdapters::usage =
  "SourceVaultProvIngestAdapters[opts] は既存ログの adapter (03 v0.4 §6.3) を offset つきで読み、Execute 等の Activity として台帳に取り込む (Owner / Service)。\n" <>
  "組み込み: mcp_calls (SourceVaultRecordMCPCall の月次 JSONL)、web_access (webguard のアクセスログ)、reference_events、mcp_deposits。\n" <>
  "URL・query・本文は入れない (Host は ExternalRef の鍵付き digest)。opts: \"BudgetSeconds\"、\"Adapters\" -> All | {name..}。\n" <>
  "戻り値 <|\"Status\", \"Adapter\" -> 件数, \"ByAdapter\", \"Seconds\"|>。";
SourceVaultProvRegisterAdapter::usage =
  "SourceVaultProvRegisterAdapter[name, <|\"Files\" -> f (f[] がファイル一覧), \"Parse\" -> g (g[行の Association] が Record の Association のリスト), \"MaxLinesPerTick\"|>]\n" <>
  "は spool adapter を登録する (冪等)。g が返す Record は Type ProvActivity / ProvEntity / ProvBlob で、EventId は行の digest から決定的に付く (再読込で重複しない)。";
SourceVaultProvVerifyLedger::usage =
  "SourceVaultProvVerifyLedger[opts] は台帳の連鎖・LineHash・MAC・checkpoint (Merkle 根を含む) を検証し、feeds の写しと他機の証言と照合する (Owner / Service)。\n" <>
  "opts: \"Since\" -> Automatic | Seq | \"YYYY-MM\"、\"MaxLines\"、\"Feeds\" -> Automatic (feeds があれば照合) | True | False。\n" <>
  "戻り値 <|\"Status\" -> \"OK\" | \"Failing\" | \"Inconclusive\", \"Verified\" -> <|\"Lines\", \"FromSeq\", \"ToSeq\", \"MacChecked\", \"KeyUnavailable\", \"Checkpoints\",\n" <>
  "\"MerkleChecked\", \"FeedCheckpoints\", \"PeerWitnesses\", \"FeedsCompared\"|>,\n" <>
  "\"Findings\" -> {<|\"Kind\" -> \"Corrupt\" | \"SeqGap\" | \"SeqReorder\" | \"ChainBreak\" | \"LineHashMismatch\" | \"MacMismatch\" | \"CheckpointMismatch\" | \"CheckpointMacMismatch\" | \"TailTruncated\"\n" <>
  "  | \"CheckpointMerkleMismatch\" | \"FeedCheckpointMismatch\" | \"FeedMerkleMismatch\" | \"FeedCheckpointBeyondLedger\" | \"LocalCheckpointMissing\" | \"FeedSyncMacMismatch\"\n" <>
  "  | \"FeedCheckpointCorrupt\" | \"WitnessMismatch\" | \"WitnessBeyondLedger\" | \"PeerWitnessSyncMacMismatch\" (Inc1b: feeds の写し・他機の証言との照合)\n" <>
  "  | \"ChainRestart\" | \"CheckpointSuperseded\" (後の 2 つは情報。連鎖の再開の記録と、その欠落区間を見ていた checkpoint),\n" <>
  "\"Seq\", \"File\", \"Line\", \"Detail\"|>..}, \"Assurance\", \"Scope\", \"NotCovered\"|>。結果の表現は表 4.5 の範囲を超えない\n" <>
  "(「MAC 鍵に届かない改変は検出されなかった (Seq n まで)」。feeds の写しは同じユーザー・同じ同期アカウントから書き換えられるので独立した証人ではない。\n" <>
  "台帳・checkpoint・feeds・他機の証言を整合的に作り直す書き換えや巻き戻しは検知しない)。";
SourceVaultProvRebuildIndex::usage =
  "SourceVaultProvRebuildIndex[] は台帳から索引 (graph / logical / labels / effective / usability) を決定的に再構築する (Owner / Service)。\n" <>
  "再構築中は index-meta.json の Rebuilding が True で Usability は Unknown。戻り値 <|\"Status\", \"Entities\", \"Activities\", \"Blobs\", \"LastSeq\", \"Digest\", \"Seconds\"|>。\n" <>
  "差分更新と再構築は同じ適用関数を Seq 順に使うので Digest が一致する (T-P5)。";
SourceVaultProvIndexDigest::usage =
  "SourceVaultProvIndexDigest[] はメモリ上の索引 (読んでいなければ WXF から読む) の決定的な digest (sha256 hex) と件数を返す。再構築前後の一致確認に使う。";
SourceVaultProvCheckpoint::usage =
  "SourceVaultProvCheckpoint[opts] は LocalState/provenance/checkpoints/ に checkpoint (FirstSeq〜LastSeq、最終 LineHash、その区間の行の Merkle 根 (SourceVaultProvMerkleRoot)、\n" <>
  "TreeSize、前の checkpoint、MAC) を書き、PrivateVault/provenance/feeds/<machine>/checkpoints/ に同期鍵の SyncMac つきの写しを置く (03 v0.4 §4.8 / §12.1、Inc1b)。\n" <>
  "\"Reason\" -> \"Periodic\" (前回から $SourceVaultProvCheckpointLines 行か $SourceVaultProvCheckpointIntervalSeconds 秒のどちらかを超えたときだけ。それ以外は NotDue) |\n" <>
  "\"Daily\" (YYYY-MM-DD.json、その日のファイルが既にあれば Exists) | \"ServiceStop\" | \"Manual\" (時刻つきの別ファイル)。前回から新しい行が無ければ NoNewLines。\n" <>
  "台帳の末尾が index-meta.json と合わなければ書かない (Failure[\"ProvCheckpointLedgerMismatch\"])。feeds への写しの失敗は checkpoint を止めない (\"FeedCopy\" に出し、\n" <>
  "SourceVaultProvSyncFeeds が後で写す)。Owner / Service。";
SourceVaultProvChainRestart::usage =
  "SourceVaultProvChainRestart[spec, ticket] は破損・欠落の後に新しい連鎖を始める (03 v0.4 §12.8 連鎖の再開)。Owner (OwnerFE / OwnerCode) + 所有者 ticket\n" <>
  "(Action \"ProvChainRestart\"、Bind に Display / LastVerifiedSeq / LastVerifiedLineHash の digest) が要る。spec = <|\"LastVerifiedSeq\", \"LastVerifiedLineHash\", \"DetectedBy\", \"Note\", \"Display\"|>。\n" <>
  "最初の行を ProvChainRestart レコード (旧連鎖の最後に検証できた LineHash と Seq、欠落区間、検出の経緯、ticket の nonce) にし、ChainState を OK に戻し、\n" <>
  "索引を台帳から作り直す (欠落区間の版は索引から消える)。VerifyLedger は再開の記録を ChainRestart、欠落区間を見ていた checkpoint を CheckpointSuperseded として情報扱いにする。";
SourceVaultProvRotateKey::usage =
  "SourceVaultProvRotateKey[purpose, <|\"KeyRef\", \"KeyId\"|>, opts] は用途 purpose の鍵を更新し、更新の時点を ProvKeyRotation レコードとして台帳に残す (03 v0.4 §12.8 鍵の更新)。\n" <>
  "旧鍵は $SourceVaultProvRetiredKeyRefs に移り検証にだけ使う。Owner / Service。\"Reason\" -> 文字列。";
SourceVaultProvStatus::usage =
  "SourceVaultProvStatus[] は来歴台帳の状態 <|\"Emit\" -> <|Count, Failed, Slow, TotalMs, MaxMs, LastError|>, \"Spool\", \"Meta\" (LastSeq / DurableSeq / IndexSeq / ChainState / CarryOver / Pending ..),\n" <>
  "\"KeyedDigestCalls\", \"LedgerMacKeyAvailable\", \"Profile\"|> を返す (件数と状態だけ。本文・ID の一覧は含まない)。";
SourceVaultProvResetCaches::usage =
  "SourceVaultProvResetCaches[] はこのカーネルのメモリ上の状態 (索引・seen・保留・spool の現在ファイル・FE の usability キャッシュ) を捨てる。service の再起動を模す試験の seam。emit の統計は残す。";

(* ---- 問い合わせ (§11.2) ---- *)
SourceVaultProvResolve::usage =
  "SourceVaultProvResolve[ref] は EntityId / BlobId / LogicalRef (sv:// URI、パス、名前) / Refs の値 (SourceId / ArtifactId ..) から版の列を返す。\n" <>
  "戻り値 <|\"Status\" -> \"Found\" | \"NotFound\", \"Ref\", \"EntityIds\" -> {古い順}, \"Latest\", \"Versions\" -> {<|\"EntityId\", \"Seq\", \"Kind\", \"PrivacyLevel\", \"BlobId\", \"LogicalRef\", \"Usability\"|>..}|>。\n" <>
  "Model / MCP の主体には PL >= 0.5 の版の BlobId を出さない (03 v0.4 §12.2)。";
SourceVaultProvHumanEditedQ::usage =
  "SourceVaultProvHumanEditedQ[ref] は ref の版のどれかが HumanEdit の Activity で作られた (手で直した派生物) なら True (03 v0.4 §7.4 / §11.4)。見つからなければ Missing[\"NotFound\"]。書込口が上書き前に呼ぶ。";
SourceVaultProvUsability::usage =
  "SourceVaultProvUsability[id] は Entity (または Activity) の利用可否 <|\"Usability\" -> \"Usable\" | \"Pending\" | \"Unknown\" | \"Quarantined\" | \"Recorded\", \"Seq\", \"IndexSeq\", \"DurableSeq\", \"Committed\"|> を返す (03 v0.4 §5.6)。\n" <>
  "Inc1a: Committed かつ OriginClass != Unknown かつ Completeness Complete なら Usable、このカーネルが spool したが未確定なら Pending、索引が古い・壊れている・再構築中・Completeness Partial / Unknown・OriginClass Unknown なら Unknown。\n" <>
  "FE 側は usability.wxf を読み、index-meta.json の IndexSeq が進んだときだけ読み直す (Seq による無効化)。SourceVaultProvUsability[{id..}] は一括。";
SourceVaultProvUsabilityIndexLoad::usage =
  "SourceVaultProvUsabilityIndexLoad[] は usability.wxf (EntityId → Usability 符号と Seq だけの小さな索引) を読み <|\"IndexSeq\", \"DurableSeq\", \"Count\", \"LoadSeconds\", \"Ids\", \"Codes\", \"Seq\"|> を返す。10 万 Entity で読込 < 50 ms が目標 (Y-08)。";

(* ---- Inc2 (03 v0.4 §6.1〜6.2、2026-11-10 第 4 週): 供給点・SessionKey・結合・確定の関門・Coverage ---- *)
$SourceVaultProvSessionKey::usage =
  "$SourceVaultProvSessionKey は現在の文脈組み立ての SessionKey (provider|sessionKey、03 v0.4 §4.1 の LineageId の代用) を供給点に見せる動的変数。\n" <>
  "claudecode が文脈組み立て (tool loop・API 呼び出し) の前に Block で束縛する。未束縛なら SourceVaultProvSessionKey[] は主体の SessionId (MCP) か None。";
SourceVaultProvSessionKey::usage =
  "SourceVaultProvSessionKey[] は供給点が ServedToContext に付ける SessionKey を返す: $SourceVaultProvSessionKey (Block 束縛) → 主体の SessionId (\"mcp|<SessionId>\") → None。";
SourceVaultProvServed::usage =
  "SourceVaultProvServed[specs, opts] は供給点 (SourceVaultSearch / KBAnswer / MCP get・search・get_document / NBAccess の読取) が文脈へ渡した Entity 群を\n" <>
  "ServedToContext Activity として SessionKey・Role・PL つきで記録する (03 v0.4 §6.1 / §6.2)。specs は {<|\"LogicalRef\", \"Refs\", \"Kind\", \"PrivacyLevel\",\n" <>
  "\"Content\" | \"ContentRef\" | \"BlobId\" | \"ClaimedContentHash\", \"Role\", \"Media\", \"Origin\"|>..}。内容に届けば BlobId を計算し、届かなければ ClaimedContentHash で Partial。\n" <>
  "SessionKey も主体の束縛も無い呼び出し (手動の検索・試験) は記録しない (Skipped / NoSessionContext)。同じ LogicalRef・内容・PL の Entity は 1 時間はこのカーネルで再利用する。opts: \"SupplyPoint\" (名前), \"Role\" (既定 Context: 検索結果・KB passage = Context、\n" <>
  "fs_read / get_document の本文 = Quote、Directives = Instruction), \"SessionKey\" (既定 Automatic = SourceVaultProvSessionKey[]), \"MaxEntities\" (50)。\n" <>
  "戻り値 <|\"Status\" -> \"Spooled\" | \"Skipped\" | \"Failed\", \"ActivityId\", \"EntityIds\", \"SessionKey\", \"Reused\"|>。どの主体からも呼べる。失敗は数えるだけで止めない。";
SourceVaultProvRequireCommitted::usage =
  "SourceVaultProvRequireCommitted[ids, timeout] は確定を要求する関門 (Authorize / Publish / PL >= 0.5 の自動処理、03 v0.4 §6.1 / §12.5) の共通関数。\n" <>
  "ids は EntityId / ActivityId か SourceVaultProvEntity / Activity の戻り値。モジュールが使えない・emit が失敗している (Failure が混じる) なら\n" <>
  "Failure[\"ProvenanceUnavailable\"]、timeout 秒で確定しなければ Failure[\"ProvenanceNotCommitted\"]、確定すれば <|\"Status\" -> \"Committed\", \"Seq\"|>。";
$SourceVaultProvJoinWindowSeconds::usage =
  "$SourceVaultProvJoinWindowSeconds は LLMCall と同じ SessionKey の ServedToContext を結合する時刻窓 (LLMCall の前、既定 1800 秒 = 30 分)。";
$SourceVaultProvJoinGraceSeconds::usage =
  "$SourceVaultProvJoinGraceSeconds は取り込んだ LLMCall を結合するまでの猶予 (既定 90 秒。別 producer の spool にある ServedToContext が同じ tick で届くのを待つ)。試験では 0。";
SourceVaultProvJoinLLMCalls::usage =
  "SourceVaultProvJoinLLMCalls[opts] は取り込んだ LLMCall イベント (claudecode の prov-spool、Type ProvLLMCall) を同じ SessionKey の ServedToContext と時刻窓で結合し、\n" <>
  "LLMGenerate Activity (Inputs = 結合した Entity と Role、Outputs = 応答 Entity (出力の SHA-256 を BlobId に)、Actor = Model + ModelRef (IdentityEvidence Claimed))\n" <>
  "を台帳に作る (03 v0.4 §6.1)。Completeness は宣言した種類 (DeclaredInputs) が全部結合できれば Complete、一部なら Partial、結合できなければ Inputs 無しで Unknown。\n" <>
  "SessionKey の無い LLMCall は UnrecordedLLMDerivations として数える。Owner / Service のみ。service の tick が取込の後に呼ぶ。opts: \"BudgetSeconds\", \"GraceSeconds\"。\n" <>
  "戻り値 <|\"Status\", \"Joined\", \"Unjoined\", \"Unrecorded\", \"Deferred\", \"Seconds\"|>。";
SourceVaultProvCoverage::usage =
  "SourceVaultProvCoverage[days] は直近 days 日の派生 Entity (DerivedText / DerivedCode / Answer / KnowledgeEdge / Instruction) のうち Completeness Complete で、\n" <>
  "LLM 由来なら ModelRef と IdentityEvidence が揃うものの割合を Kind ごとに返す (03 v0.4 §7.1 Coverage)。Backfilled の版は分母から除く。\n" <>
  "2026-11-11: Total / Complete / Ratio は Instruction を除く派生だけ (Instruction の基準の充足は \"Instruction\" と ByKind)。\"SupplyPoint\" は供給点を通った派生\n" <>
  "(SessionKey つきの LLMGenerate が作った版、仕様の Inc2 の分母)、\"OutsideSupplyPoints\" -> <|\"LLMWithoutSessionKey\", \"NonLLM\"|> は供給点の外の派生の件数。\n" <>
  "戻り値 <|\"WindowDays\", \"Total\", \"Complete\", \"Ratio\", \"ByKind\" -> <|kind -> <|Total, Complete, Ratio|>|>, \"Instruction\", \"SupplyPoint\", \"OutsideSupplyPoints\",\n" <>
  "\"UnrecordedLLMDerivations\", \"Backfilled\", \"IndexSeq\"|>。読取専用。";

(* ---- Inc1b (03 v0.4 §4.8 / §12.1〜12.3、2026-11-10): Merkle 根の checkpoint・feeds の射影・複数機の checkpoint 照合 ---- *)
$SourceVaultProvCheckpointLines::usage =
  "$SourceVaultProvCheckpointLines は Periodic checkpoint を書く行数 (既定 1000)。前回の checkpoint からこの行数を超えるか、$SourceVaultProvCheckpointIntervalSeconds を\n" <>
  "過ぎるか、サービス停止 (ServiceStop) のうち早いもので書く (03 v0.4 §4.8)。代入は NBAccess の承認対象。";
$SourceVaultProvCheckpointIntervalSeconds::usage = "$SourceVaultProvCheckpointIntervalSeconds は Periodic checkpoint の最長間隔 (既定 3600 秒)。代入は承認対象。";
$SourceVaultProvFeedRetentionDays::usage =
  "$SourceVaultProvFeedRetentionDays は feeds の射影 (projection/YYYY-MM-DD.jsonl) の保持日数 (既定 90、表 12.1)。checkpoint の写しは無期限。代入は承認対象。";
$SourceVaultProvSyncDigestKinds::usage =
  "$SourceVaultProvSyncDigestKinds は feeds の射影に照合用の SyncDigest (同期鍵による BlobId の鍵付き digest) を付ける Entity の Kind のリスト (既定 {} = 付けない)。\n" <>
  "所有者が射影を許した種類だけに付ける (03 v0.4 §12.2)。PL >= 0.5 の版はそもそも射影しない。代入は承認対象。";
$SourceVaultProvScoreBudgetSeconds::usage =
  "$SourceVaultProvScoreBudgetSeconds はレビュー順の点数 (03 v0.4 §8.3〜8.4) を索引の保存ごとに計算し直す予算 (秒、既定 2)。超えた分は持ち越して Stale とし、次の保存で続きから計算する。";
SourceVaultProvMerkleRoot::usage =
  "SourceVaultProvMerkleRoot[lineHashes] は台帳の LineHash の列 (\"sha256:<hex64>\" の文字列) の Merkle 根 \"sha256:<hex64>\" を返す (RFC 6962 の Merkle Tree Hash:\n" <>
  "葉 = SHA-256(0x00 || UTF-8(LineHash))、節 = SHA-256(0x01 || 左 || 右)、空列は SHA-256 の空文字列)。checkpoint の MerkleRoot は FirstSeq〜LastSeq の行 (欠落区間は除く) の根。";
SourceVaultProvSyncFeeds::usage =
  "SourceVaultProvSyncFeeds[opts] は feeds (PrivateVault/provenance/feeds/<machine>/、Dropbox 同期、書き手は各機 1 つ) を更新し、他機の feeds と照合する (03 v0.4 §12.1〜12.3)。\n" <>
  "自機: checkpoints/ に checkpoint の写し (同期鍵の SyncMac つき、無期限)、projection/YYYY-MM-DD.jsonl に PL < 0.5 の版だけの射影 (SyncId・Kind・OriginClass・Usability・PL と\n" <>
  "関係。SyncId は版ごとの乱数で内容から計算しない。BlobId・EntityId・LogicalRef・本文は出さない。保持 $SourceVaultProvFeedRetentionDays 日)、manifest.json、witness.json\n" <>
  "(他機の checkpoint を自機が見た記録)。他機: checkpoint の写しの SyncMac を確かめ、前に見た写しとの食い違い (PeerCheckpointChanged)・巻き戻し (PeerRollback)・\n" <>
  "消失 (PeerCheckpointMissing) を LocalState/provenance/peers/<machine>.json の記録と比べ、他機の witness.json に書かれた自機の checkpoint を自機の checkpoint と比べる\n" <>
  "(WitnessMismatch / WitnessBeyondLedger)。結果は health/feeds-state.json。Owner / Service のみ。opts: \"Projection\" (True), \"Peers\" (True)。\n" <>
  "戻り値 <|\"Status\" -> \"OK\" | \"Degraded\" | \"Failing\" | \"FeedUnavailable\", \"Own\", \"Peers\", \"Findings\", \"Seconds\"|>。他機の射影の統合は Inc6。";
SourceVaultProvFeedStatus::usage =
  "SourceVaultProvFeedStatus[] は直近の SourceVaultProvSyncFeeds の結果 (health/feeds-state.json) を返す (件数・状態・Finding のメタデータだけ)。無ければ Missing[\"NotFound\"]。";

Begin["`ProvenancePrivate`"]

(* ============================================================
   設定と定数
   ============================================================ *)
If[! ValueQ[$SourceVaultProvSpoolRoot], $SourceVaultProvSpoolRoot = Automatic];
If[! NumberQ[$SourceVaultProvSpoolRotateBytes], $SourceVaultProvSpoolRotateBytes = 20*1024*1024];
If[! ValueQ[$SourceVaultProvProducer], $SourceVaultProvProducer = Automatic];
If[! NumberQ[$SourceVaultProvEmitBudgetMs], $SourceVaultProvEmitBudgetMs = 50];
If[! NumberQ[$SourceVaultProvIngestBudgetSeconds], $SourceVaultProvIngestBudgetSeconds = 20];
If[! NumberQ[$SourceVaultProvPendingTimeoutSeconds], $SourceVaultProvPendingTimeoutSeconds = 600];
If[! AssociationQ[$SourceVaultProvKeyRefs],
  $SourceVaultProvKeyRefs = <|
    "LedgerMac"   -> <|"KeyRef" -> "SourceVault:prov:ledger-mac:v1",  "KeyId" -> "ledger-mac-v1"|>,
    "ExternalRef" -> <|"KeyRef" -> "SourceVault:prov:externalref:v1", "KeyId" -> "externalref-v1"|>,
    "Prompt"      -> <|"KeyRef" -> "SourceVault:prov:prompt:v1",      "KeyId" -> "prompt-v1"|>,
    "ToolArgs"    -> <|"KeyRef" -> "SourceVault:prov:toolargs:v1",    "KeyId" -> "toolargs-v1"|>,
    "Sync"        -> <|"KeyRef" -> "SourceVault:prov:sync:v1",        "KeyId" -> "sync-v1"|>|>];
If[! AssociationQ[$SourceVaultProvRetiredKeyRefs], $SourceVaultProvRetiredKeyRefs = <||>];
(* Inc2 (2026-11-10): 結合の時刻窓と猶予。SessionKey は Block 束縛の動的変数 (既定は未束縛) *)
If[! NumberQ[$SourceVaultProvJoinWindowSeconds], $SourceVaultProvJoinWindowSeconds = 1800];
If[! NumberQ[$SourceVaultProvJoinGraceSeconds], $SourceVaultProvJoinGraceSeconds = 90];
If[! ValueQ[$SourceVaultProvSessionKey], $SourceVaultProvSessionKey = None];
(* Inc1b (2026-11-10): checkpoint の頻度・feeds の保持・SyncDigest を許す種類 *)
If[! IntegerQ[$SourceVaultProvCheckpointLines], $SourceVaultProvCheckpointLines = 1000];
If[! NumberQ[$SourceVaultProvCheckpointIntervalSeconds], $SourceVaultProvCheckpointIntervalSeconds = 3600];
If[! NumberQ[$SourceVaultProvFeedRetentionDays], $SourceVaultProvFeedRetentionDays = 90];
If[! ListQ[$SourceVaultProvSyncDigestKinds], $SourceVaultProvSyncDigestKinds = {}];

(* Inc3 (2026-11-10、03 v0.4 §4.6 / §5.3〜5.5): ラベルの記録。Entity を書き換えず、索引で読取時に合成する *)
$iProvLabelRecordTypes = {"ProvFinding", "ProvFindingResolution", "ProvRelease", "ProvAuthorization", "ProvRevocation",
  "ProvVerification", "ProvVerifierRegistration"};
$iProvLabelIdKeys = <|"ProvFinding" -> "FindingId", "ProvFindingResolution" -> "ResolutionId", "ProvRelease" -> "ReleaseId",
  "ProvAuthorization" -> "AuthId", "ProvRevocation" -> "RevocationId", "ProvVerification" -> "VerificationId",
  "ProvVerifierRegistration" -> "RegistrationId"|>;
(* 所有者 ticket が要る記録と、その ticket の Action (11.5 節)。ProvFinding (隔離) と OwnerReviewed の検証主張は ticket があるときだけ照合する *)
$iProvTicketActions = <|"ProvFindingResolution" -> "ResolveFinding", "ProvRelease" -> "Release", "ProvAuthorization" -> "AuthorizeInstruction",
  "ProvRevocation" -> "RevokeAuthorization", "ProvVerifierRegistration" -> "RegisterVerifier",
  "ProvFinding" -> "Quarantine", "ProvVerification" -> "RecordOwnerReview"|>;
$iProvOwnerRecordTypes = {"ProvFindingResolution", "ProvRelease", "ProvAuthorization", "ProvRevocation", "ProvVerifierRegistration"};
$iProvCarryRoles = {"Quote", "Context", "Instruction", "Code", "AttachmentOf", "Contains"};
$iProvSevereLevels = {"High", "Critical"};
$iProvInstructionPurposes = {"Directive", "Workflow", "TurnWikiRule", "SystemPrompt", "SeriesSpec", "ProcessDelta"};
$iProvRecordTypes = Join[{"ProvBlob", "ProvEntity", "ProvActivity", "ProvKeyRotation", "ProvChainRestart"}, $iProvLabelRecordTypes];
(* ProvLLMCall (Inc2): claudecode の LLMCall イベント。台帳には直接入れず結合の待ち行列に入る (SourceVaultProvJoinLLMCalls) *)
(* ProvGrounding (文書 12 の V9、2026-11-13): claudecode の裏付けの検査の結果。台帳には直接入れず、回答の版 (LLMCall の出力) が
   できてから、service が検証の主張 (ProvVerification、Property "Grounding") として結び付ける (iProvGroundingItems) *)
$iProvSpoolTypes = Join[{"ProvBlob", "ProvEntity", "ProvActivity", "ProvLLMCall", "ProvGrounding"}, $iProvLabelRecordTypes];
$iProvEntityKinds = {"PrimarySource", "OwnerAuthored", "DerivedText", "DerivedCode", "KnowledgeEdge", "Answer",
  "Instruction", "Model", "ToolSchema", "Config", "Publication"};
$iProvActivityKinds = {"Ingest", "LLMGenerate", "Transform", "Execute", "HumanEdit", "Verify", "Authorize", "Publish",
  "Quarantine", "Release", "ServedToContext"};
$iProvDerivedKinds = {"DerivedText", "DerivedCode", "Answer", "KnowledgeEdge", "Instruction"};
$iProvInputRoles = {"Instruction", "Context", "Quote", "Code", "AttachmentOf", "Contains", "Cite"};
$iProvCompleteness = {"Complete", "Partial", "Unknown"};
$iProvGenesisHash = "sha256:" <> StringRepeat["0", 64];
$iProvForbiddenContextKeys = {"Url", "URL", "Uri", "URI", "Sender", "From", "To", "Cc", "Subject", "Body", "Text",
  "Content", "Query", "Prompt", "Address", "Email", "Mail"};
$iProvUsabilityCodes = <|"Unknown" -> 0, "Usable" -> 1, "Pending" -> 2, "Quarantined" -> 3, "Recorded" -> 9|>;
$iProvUsabilityNames = Association[Reverse /@ Normal[$iProvUsabilityCodes]];
$iProvOwnerService = {"OwnerFE", "OwnerCode", "Service"};
$iProvOwner = {"OwnerFE", "OwnerCode"};
$iProvULIDRE = "^[0-9A-HJKMNP-TV-Z]{26}$";
$iProvSeenMax = 50000;
$iProvChunk = 1000;

(* ============================================================
   小道具: 時刻・主体・ULID・JSON・ハッシュ
   ============================================================ *)
iProvAbsToIso[abs_?NumericQ] := DateString[abs, {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"},
  TimeZone -> 0];
iProvNowIso[] := iProvAbsToIso[AbsoluteTime[]];
iProvDateIso[d_DateObject] := With[{u = Quiet @ TimeZoneConvert[d, 0]},
  DateString[If[Head[u] === DateObject, u, d], {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"}]];
(* "yyyy-mm-ddThh:mm:ssZ" -> AbsoluteTime。手で解析する (AbsoluteTime[{str, fmt}, TimeZone -> 0] は時差を二重に足す) *)
iProvIsoToAbs[iso_String] := Module[{m},
  m = StringCases[iso, RegularExpression["^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?Z$"] :>
    (FromDigits /@ {"$1", "$2", "$3", "$4", "$5", "$6"})];
  If[m === {}, $Failed, Quiet @ Check[AbsoluteTime[DateObject[First[m], TimeZone -> 0]], $Failed]]];
iProvIsoToAbs[_] := $Failed;
(* UNIX ミリ秒 (結合の前後関係用、Inc2)。ISO 文字列は秒までなので、供給点と LLMCall には別にミリ秒を持たせる *)
iProvNowUnixMs[] := With[{t = Quiet @ Check[AbsoluteTime[TimeZone -> 0], $Failed]}, If[NumberQ[t], Round[1000 (t - 2208988800)], UnixTime[]*1000]];
iProvIsoToUnixMs[iso_] := With[{a = iProvIsoToAbs[iso], e = iProvIsoToAbs["1970-01-01T00:00:00Z"]}, If[NumberQ[a] && NumberQ[e], Round[1000 (a - e)], Null]];
iProvDateTag[] := DateString[AbsoluteTime[], {"Year", "Month", "Day"}, TimeZone -> 0];
iProvDayTag[] := DateString[AbsoluteTime[], {"Year", "-", "Month", "-", "Day"}, TimeZone -> 0];
iProvMonthTag[] := DateString[AbsoluteTime[], {"Year", "-", "Month"}, TimeZone -> 0];

iProvMachine[] := If[Length[DownValues[SourceVault`SourceVaultMachineTag]] > 0,
  SourceVault`SourceVaultMachineTag[],
  StringReplace[ToString[$MachineName], Except[LetterCharacter | DigitCharacter | "-" | "_"] .. -> "-"]];
iProvSafeName[s_String] := StringReplace[s, Except[LetterCharacter | DigitCharacter | "-" | "_"] .. -> "-"];

iProvPrincipalKind[] := With[{k = Quiet @ Check[SourceVault`SourceVaultPrincipal["Kind"], "Model"]}, If[StringQ[k], k, "Model"]];
iProvAuth[fn_String, kinds_List] := With[{k = iProvPrincipalKind[]},
  If[MemberQ[kinds, k], True,
    Failure["ProvNotAuthorized", <|"Function" -> fn, "Principal" -> k, "Allowed" -> kinds,
      "MessageTemplate" -> "`1` may be called only by `2` (03 v0.4 table 11.1); the current principal is `3`.",
      "MessageParameters" -> {fn, StringRiffle[kinds, ", "], k}|>]]];

$iProvCrockford = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"];
iProvCrock[n_Integer, len_Integer] := StringJoin @ $iProvCrockford[[IntegerDigits[Max[n, 0], 32, len] + 1]];
iProvULID[] := If[Length[DownValues[SourceVault`SourceVaultULID]] > 0, SourceVault`SourceVaultULID[],
  iProvCrock[UnixTime[]*1000 + Floor[1000*FractionalPart[AbsoluteTime[]]], 10] <> iProvCrock[RandomInteger[{0, 2^80 - 1}], 16]];
iProvULIDQ[s_] := StringQ[s] && StringMatchQ[s, RegularExpression[$iProvULIDRE]];
iProvEntityIdQ[s_] := StringQ[s] && StringMatchQ[s, RegularExpression["^ent-[0-9A-HJKMNP-TV-Z]{26}$"]];
iProvActivityIdQ[s_] := StringQ[s] && StringMatchQ[s, RegularExpression["^act-[0-9A-HJKMNP-TV-Z]{26}$"]];
iProvBlobIdQ[s_] := StringQ[s] && StringMatchQ[s, RegularExpression["^blob:sha256:[0-9a-f]{64}$"]];

iProvSHAHex[s_String] := Hash[StringToByteArray[s, "UTF-8"], "SHA256", "HexString"];
iProvSHAHex[b_ByteArray] := Hash[b, "SHA256", "HexString"];
iProvConstEq[a_String, b_String] := StringLength[a] === StringLength[b] &&
  (BitOr @@ MapThread[BitXor, {ToCharacterCode[a], ToCharacterCode[b]}]) === 0;
iProvConstEq[___] := False;

iProvParseJSON[s_String] := Quiet @ Check[ImportByteArray[StringToByteArray[s, "UTF-8"], "RawJSON"], $Failed];
iProvParseJSON[b_ByteArray] := Quiet @ Check[ImportByteArray[b, "RawJSON"], $Failed];
(* 複数行を 1 つの JSON 配列として一括で読む (1 行ずつ import する 30 倍速い)。配列として読めなければ 1 行ずつに落ちる *)
iProvParseJSONBatch[lines_List] := Module[{arr},
  If[lines === {}, Return[{}]];
  arr = Quiet @ Check[ImportByteArray[StringToByteArray["[" <> StringRiffle[lines, ","] <> "]", "UTF-8"], "RawJSON"], $Failed];
  If[ListQ[arr] && Length[arr] === Length[lines], arr, iProvParseJSON /@ lines]];

(* ============================================================
   正準化 CanonVersion 1 (§4.2)
   ============================================================ *)
iProvEscape[s_String] := StringReplace[s, {
  "\\" -> "\\\\", "\"" -> "\\\"", "\n" -> "\\n", "\r" -> "\\r", "\t" -> "\\t", "\b" -> "\\b", "\f" -> "\\f",
  c : RegularExpression["[\\x00-\\x1F]"] :> "\\u" <> IntegerString[First @ ToCharacterCode[c], 16, 4]}];

(* 実数: InputForm の最短往復の桁を d.ddde<exp> に (1.0e2, 6.0e-1, 3.0000000000000004e-1, 0.0e0)。-0.0 は 0.0e0 *)
iProvRealCanon[x_Real] := Module[{s, m, sign, ip, fp, ex, e, d, d2},
  s = ToString[x, InputForm];
  s = First[StringSplit[s, "`"], s];
  m = StringCases[s, RegularExpression["^(-?)(\\d+)\\.(\\d*)(?:\\*\\^(-?\\d+))?$"] :> {"$1", "$2", "$3", "$4"}];
  If[m === {}, Return[$Failed]];
  {sign, ip, fp, ex} = First[m];
  e = If[ex === "", 0, If[StringStartsQ[ex, "-"], -FromDigits[StringDrop[ex, 1]], FromDigits[ex]]] + StringLength[ip];
  d = ip <> fp;
  d2 = StringReplace[d, RegularExpression["^0+"] -> ""];
  e -= StringLength[d] - StringLength[d2];
  d2 = StringReplace[d2, RegularExpression["0+$"] -> ""];
  If[d2 === "", Return["0.0e0"]];
  sign <> StringTake[d2, 1] <> "." <> If[StringLength[d2] > 1, StringDrop[d2, 1], "0"] <> "e" <> ToString[e - 1]];

$iProvCellDroppedOptions = {"CellChangeTimes", "CellID", "CellLabel", "CellLabelAutoDelete", "ExpressionUUID"};
iProvCellAssoc[c_Cell] := <|
  "$cell" -> ToString[DeleteCases[c, (Rule | RuleDelayed)[CellChangeTimes | CellID | CellLabel | CellLabelAutoDelete | ExpressionUUID, _], {1}], InputForm],
  "DroppedOptions" -> $iProvCellDroppedOptions|>;

iProvKeyString[k_] := If[StringQ[k], k, ToString[k, InputForm]];
(* 符号位置順。WL の Sort / SortBy は長さの短いリストを先にするので、-1 で最長に詰めてから要素ごとに比べる
   (短いキーは接頭辞のときだけ先に来る = 辞書順) *)
iProvSortKeys[keys_List] := Module[{codes, maxLen},
  codes = ToCharacterCode[iProvKeyString[#]] & /@ keys;
  maxLen = Max[0, Max[Length /@ codes]];
  keys[[Ordering[PadRight[#, maxLen, -1] & /@ codes]]]];
iProvCanon[x_] := Which[
  StringQ[x], "\"" <> iProvEscape[x] <> "\"",
  IntegerQ[x], ToString[x],
  x === True, "true",
  x === False, "false",
  x === Null, "null",
  Head[x] === Real, With[{r = iProvRealCanon[x]}, If[StringQ[r], r, Throw[$Failed, iProvCanonTag]]],
  Head[x] === Rational, "{\"$rational\":\"" <> ToString[Numerator[x]] <> "/" <> ToString[Denominator[x]] <> "\"}",
  Head[x] === Missing, "{\"$missing\":" <> iProvCanon[Switch[Length[x], 0, Null, 1, First[x], _, List @@ x]] <> "}",
  Head[x] === DateObject, iProvCanon[iProvDateIso[x]],
  Head[x] === ByteArray, "{\"$bytes\":\"" <> BaseEncode[x] <> "\"}",
  Head[x] === Cell, iProvCanon[iProvCellAssoc[x]],
  AssociationQ[x],
    "{" <> StringRiffle[
      Function[k, iProvCanon[iProvKeyString[k]] <> ":" <> iProvCanon[x[k]]] /@ iProvSortKeys[Keys[x]], ","] <> "}",
  ListQ[x], "[" <> StringRiffle[iProvCanon /@ x, ","] <> "]",
  Head[x] === Symbol, "{\"$symbol\":\"" <> iProvEscape[Context[x] <> SymbolName[x]] <> "\"}",
  True, "{\"$expr\":\"" <> iProvEscape[ToString[x, InputForm]] <> "\"}"];
iProvCanonText[x_] := Catch[iProvCanon[x], iProvCanonTag];
iProvCanonTextString[s_String] := StringReplace[StringDelete[s, StartOfString ~~ "\:feff"], {"\r\n" -> "\n", "\r" -> "\n"}];

Options[SourceVaultProvCanonicalize] = {"Kind" -> Automatic, "CanonVersion" -> 1};
SourceVaultProvCanonicalize[x_, OptionsPattern[]] := Module[{ver = OptionValue["CanonVersion"], kind = OptionValue["Kind"], bytes, s, p},
  If[ver === 0,
    If[! AssociationQ[x],
      Return[Failure["ProvCanonVersionUnsupported", <|"CanonVersion" -> 0,
        "MessageTemplate" -> "CanonVersion 0 (SourceVaultCanonicalizeForDigest) is defined for Associations only."|>]]];
    s = Quiet @ Check[SourceVault`SourceVaultCanonicalizeForDigest[x], $Failed];
    If[! StringQ[s], Return[Failure["ProvCanonicalizeFailed", <|"CanonVersion" -> 0|>]]];
    Return[<|"CanonVersion" -> 0, "Kind" -> "Association", "Bytes" -> StringToByteArray[s, "UTF-8"]|>]];
  If[ver =!= 1, Return[Failure["ProvCanonVersionUnsupported", <|"CanonVersion" -> ver|>]]];
  If[kind === Automatic,
    kind = Which[ByteArrayQ[x], "Bytes", StringQ[x], "Text", Head[x] === File, "File", Head[x] === Cell, "Cell", True, "Expression"]];
  bytes = Switch[kind,
    "Bytes", If[ByteArrayQ[x], x, $Failed],
    "File",
      p = If[Head[x] === File, First[x], x];
      If[StringQ[p] && FileExistsQ[p],
        If[Quiet @ Check[FileByteCount[p], -1] === 0, StringToByteArray["", "UTF-8"], Quiet @ Check[ReadByteArray[p], $Failed]],
        $Failed],
    "Text", If[StringQ[x], StringToByteArray[iProvCanonTextString[x], "UTF-8"], $Failed],
    "Cell" | "Expression" | "Association", With[{t = iProvCanonText[x]}, If[StringQ[t], StringToByteArray[t, "UTF-8"], $Failed]],
    _, $Failed];
  If[! ByteArrayQ[bytes], Return[Failure["ProvCanonicalizeFailed", <|"CanonVersion" -> 1, "Kind" -> kind|>]]];
  <|"CanonVersion" -> 1, "Kind" -> kind, "Bytes" -> bytes|>];

SourceVaultProvBlobId[x_, opts : OptionsPattern[SourceVaultProvCanonicalize]] := Module[{c = SourceVaultProvCanonicalize[x, opts]},
  If[FailureQ[c], Return[c]];
  <|"BlobId" -> "blob:sha256:" <> iProvSHAHex[c["Bytes"]], "CanonVersion" -> c["CanonVersion"], "Kind" -> c["Kind"],
    "Size" -> Length[c["Bytes"]]|>];

(* ============================================================
   保存場所 (§12.1)・原子的な書込
   ============================================================ *)
iProvLocalState[] := With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["LocalState"], $Failed]},
  If[StringQ[r] && r =!= "", r, $Failed]];
iProvEnsureDir[d_String] := (If[! DirectoryQ[d], Quiet @ CreateDirectory[d, CreateIntermediateDirectories -> True]];
  If[DirectoryQ[d], d, $Failed]);
iProvDir[parts___String] := With[{ls = iProvLocalState[]},
  If[ls === $Failed, $Failed, iProvEnsureDir[FileNameJoin[{ls, "provenance", parts}]]]];
iProvLedgerDir[] := iProvDir["ledger"];
iProvIndexDir[] := iProvDir["index"];
iProvCheckpointDir[] := iProvDir["checkpoints"];
iProvHealthDir[] := iProvDir["health"];
iProvIndexPath[name_String] := With[{d = iProvIndexDir[]}, If[d === $Failed, $Failed, FileNameJoin[{d, name}]]];
iProvSpoolDir[] := If[StringQ[$SourceVaultProvSpoolRoot] && $SourceVaultProvSpoolRoot =!= "", $SourceVaultProvSpoolRoot,
  FileNameJoin[{$UserBaseDirectory, "ApplicationData", "SourceVault", "prov-spool"}]];
iProvProducer[] := iProvSafeName @ Which[
  StringQ[$SourceVaultProvProducer] && $SourceVaultProvProducer =!= "", $SourceVaultProvProducer,
  TrueQ[$Notebooks], "fe",
  TrueQ[SourceVault`$SourceVaultDiagnosticsCanonicalWriter], "service",
  True, "wl"];

iProvWriteBytesAtomic[path_String, ba_ByteArray] := Module[{tmp, strm, ok},
  If[iProvEnsureDir[DirectoryName[path]] === $Failed, Return[$Failed]];
  tmp = path <> ".tmp-" <> ToString[$ProcessID] <> "-" <> StringTake[CreateUUID[], 8];
  strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  ok = Quiet @ Check[(BinaryWrite[strm, ba]; Close[strm]; True), (Quiet @ Close[strm]; False)];
  If[! TrueQ[ok], Quiet @ DeleteFile[tmp]; Return[$Failed]];
  Quiet @ Check[RenameFile[tmp, path, OverwriteTarget -> True]; path, Quiet @ DeleteFile[tmp]; $Failed]];
iProvWriteJSONAtomic[path_, x_] := With[{t = iProvCanonText[x]},
  If[StringQ[t] && StringQ[path], iProvWriteBytesAtomic[path, StringToByteArray[t, "UTF-8"]], $Failed]];
iProvWriteWXFAtomic[path_, x_] := With[{b = Quiet @ Check[BinarySerialize[x], $Failed]},
  If[ByteArrayQ[b] && StringQ[path], iProvWriteBytesAtomic[path, b], $Failed]];
iProvReadBytes[path_] := If[StringQ[path] && FileExistsQ[path],
  If[Quiet @ Check[FileByteCount[path], -1] === 0, StringToByteArray["", "UTF-8"], Quiet @ Check[ReadByteArray[path], $Failed]], $Failed];
iProvReadJSON[path_] := With[{b = iProvReadBytes[path]}, If[ByteArrayQ[b], iProvParseJSON[b], $Failed]];
iProvReadWXF[path_] := With[{b = iProvReadBytes[path]}, If[ByteArrayQ[b], Quiet @ Check[BinaryDeserialize[b], $Failed], $Failed]];
(* ファイルの [off, off+n) バイトを読む *)
iProvReadRange[path_String, off_Integer, n_Integer] := Module[{strm, ba},
  If[n <= 0, Return[StringToByteArray["", "UTF-8"]]];
  strm = Quiet @ OpenRead[path, BinaryFormat -> True];
  If[Head[strm] =!= InputStream, Return[$Failed]];
  Quiet @ SetStreamPosition[strm, off];
  ba = Quiet @ Check[ReadByteArray[strm, n], $Failed];
  Quiet @ Close[strm];
  If[ByteArrayQ[ba], ba, $Failed]];
iProvReadLines[path_] := Module[{b = iProvReadBytes[path], t},
  If[! ByteArrayQ[b] || Length[b] === 0, Return[{}]];
  t = Quiet @ Check[ByteArrayToString[b, "UTF-8"], $Failed];
  If[! StringQ[t], Return[$Failed]];
  Select[StringTrim /@ StringSplit[t, "\n"], # =!= "" &]];

(* ============================================================
   鍵と MAC (§4.8 / §12.2): 鍵材料はこのモジュールに来ない (NBMacWithKeyRef)。development の literal 鍵だけ例外
   ============================================================ *)
iProvProfile[] := With[{p = SourceVault`$SourceVaultSecurityProfile}, If[MemberQ[{"production", "development"}, p], p, "production"]];
iProvDefaultKeyId[purpose_String, ref_String] := ToLowerCase[purpose] <> "-" <>
  StringReplace[Last[StringSplit[ref, ":"], "v1"], Except[LetterCharacter | DigitCharacter | "-" | "_" | "."] -> "-"];
iProvKeySpec[purpose_String] := Module[{v = Lookup[$SourceVaultProvKeyRefs, purpose, $Failed]},
  Which[
    AssociationQ[v] && StringQ[Lookup[v, "KeyRef", None]],
      <|"KeyRef" -> v["KeyRef"], "KeyId" -> ToString[Lookup[v, "KeyId", iProvDefaultKeyId[purpose, v["KeyRef"]]]]|>,
    StringQ[v], <|"KeyRef" -> v, "KeyId" -> iProvDefaultKeyId[purpose, v]|>,
    True, $Failed]];
(* RFC 2104 (SourceVault_crypto があればそれを使う) *)
iProvHMACLocal[key_ByteArray, msg_ByteArray] := Module[{k0, kp, ip, op, inner},
  k0 = If[Length[key] > 64, Hash[key, "SHA256", "ByteArray"], key];
  kp = PadRight[Normal[k0], 64, 0];
  ip = ByteArray[BitXor[#, 54] & /@ kp]; op = ByteArray[BitXor[#, 92] & /@ kp];
  inner = Hash[ByteArray[Join[Normal[ip], Normal[msg]]], "SHA256", "ByteArray"];
  StringJoin[IntegerString[#, 16, 2] & /@ Normal[Hash[ByteArray[Join[Normal[op], Normal[inner]]], "SHA256", "ByteArray"]]]];
iProvHMACHex[key_ByteArray, msg_ByteArray] := If[Length[DownValues[SourceVault`SourceVaultHMACSHA256Hex]] > 0,
  ToLowerCase @ SourceVault`SourceVaultHMACSHA256Hex[key, msg], iProvHMACLocal[key, msg]];
iProvMacWithKeyRef[keyRef_String, bytes_ByteArray] := Which[
  StringStartsQ[keyRef, "literal:"],
    If[iProvProfile[] === "development" && StringLength[keyRef] > 8,
      iProvHMACHex[StringToByteArray[StringDrop[keyRef, 8], "UTF-8"], bytes], $Failed],
  Length[DownValues[NBAccess`NBMacWithKeyRef]] > 0,
    With[{r = Quiet @ Check[NBAccess`NBMacWithKeyRef[keyRef, bytes, "SourceVaultProvenance"], $Failed]},
      If[StringQ[r] && StringLength[r] === 64, ToLowerCase[r], $Failed]],
  True, $Failed];
iProvMacWithKeyRef[___] := $Failed;
iProvMac[purpose_String, bytes_ByteArray] := With[{ks = iProvKeySpec[purpose]},
  If[ks === $Failed, $Failed,
    With[{h = iProvMacWithKeyRef[ks["KeyRef"], bytes]},
      If[StringQ[h], <|"KeyId" -> ks["KeyId"], "Hex" -> h, "Mac" -> "hmac:" <> ks["KeyId"] <> ":" <> h|>, $Failed]]]];
iProvLedgerKeyAvailableQ[] := iProvMac["LedgerMac", StringToByteArray["probe", "UTF-8"]] =!= $Failed;
iProvKeyRefForKeyId[keyId_String] := Module[{hit},
  hit = SelectFirst[Values[$SourceVaultProvKeyRefs], AssociationQ[#] && Lookup[#, "KeyId", None] === keyId &, None];
  Which[
    AssociationQ[hit], hit["KeyRef"],
    StringQ[Lookup[$SourceVaultProvRetiredKeyRefs, keyId, None]], $SourceVaultProvRetiredKeyRefs[keyId],
    True, $Failed]];
(* "OK" | "Mismatch" | "KeyUnavailable" | "BadFormat" *)
iProvVerifyMac[macStr_String, bytes_ByteArray] := Module[{m, keyId, hex, ref, got},
  m = StringCases[macStr, RegularExpression["^hmac:([A-Za-z0-9_.-]+):([0-9a-f]{64})$"] :> {"$1", "$2"}];
  If[m === {}, Return["BadFormat"]];
  {keyId, hex} = First[m];
  ref = iProvKeyRefForKeyId[keyId];
  If[ref === $Failed, Return["KeyUnavailable"]];
  got = iProvMacWithKeyRef[ref, bytes];
  If[! StringQ[got], Return["KeyUnavailable"]];
  If[iProvConstEq[got, hex], "OK", "Mismatch"]];
iProvKeyRefsPersistPath[] := With[{d = iProvHealthDir[]}, If[d === $Failed, $Failed, FileNameJoin[{d, "keyrefs.json"}]]];
iProvLoadRetiredKeyRefs[] := With[{r = iProvReadJSON[iProvKeyRefsPersistPath[]]},
  If[AssociationQ[r] && AssociationQ[Lookup[r, "Retired", None]],
    $SourceVaultProvRetiredKeyRefs = Join[Select[r["Retired"], StringQ], $SourceVaultProvRetiredKeyRefs]]];

(* KeyedDigest の呼出し回数 (§12.2) *)
If[! AssociationQ[$iProvKeyedDigestCalls], $iProvKeyedDigestCalls = <||>];
iProvKeyedDigestCallsPath[] := With[{d = iProvHealthDir[]}, If[d === $Failed, $Failed, FileNameJoin[{d, "keyed-digest-calls.json"}]]];
iProvNoteKeyedDigestCall[purpose_String] := Module[{p = iProvKeyedDigestCallsPath[], disk},
  $iProvKeyedDigestCalls[purpose] = Lookup[$iProvKeyedDigestCalls, purpose, 0] + 1;
  If[p =!= $Failed,
    disk = iProvReadJSON[p];
    If[! AssociationQ[disk], disk = <||>];
    disk[purpose] = Lookup[disk, purpose, 0] + 1;
    disk["UpdatedAtUTC"] = iProvNowIso[];
    disk["Principal"] = iProvPrincipalKind[];
    Quiet @ iProvWriteJSONAtomic[p, disk]]];

SourceVaultProvKeyedDigest[s_String, purpose_String] := Module[{auth, ks, mac},
  auth = iProvAuth["SourceVaultProvKeyedDigest", $iProvOwnerService];
  If[FailureQ[auth], Return[auth]];
  If[purpose === "LedgerMac" || ! KeyExistsQ[$SourceVaultProvKeyRefs, purpose],
    Return[Failure["ProvUnknownPurpose", <|"Purpose" -> purpose, "Allowed" -> DeleteCases[Keys[$SourceVaultProvKeyRefs], "LedgerMac"]|>]]];
  ks = iProvKeySpec[purpose];
  mac = iProvMac[purpose, StringToByteArray[s, "UTF-8"]];
  If[mac === $Failed,
    Return[Failure["ProvKeyUnavailable", <|"Purpose" -> purpose, "KeyRef" -> If[AssociationQ[ks], ks["KeyRef"], Null],
      "MessageTemplate" -> "The MAC key for purpose `1` is not available (NBAccess_crypto NBMacWithKeyRef / key index).",
      "MessageParameters" -> {purpose}|>]]];
  iProvNoteKeyedDigestCall[purpose];
  mac["Mac"]];
SourceVaultProvKeyedDigest[___] := Failure["ProvBadArguments", <|"MessageTemplate" -> "SourceVaultProvKeyedDigest[s_String, purpose_String]"|>];
(* 鍵が無ければ Null (平文は決して入れない)。記録点が Prompt / Args / 外部識別子を渡したときに使う *)
iProvDigestOrNull[purpose_String, s_String] := With[{m = iProvMac[purpose, StringToByteArray[s, "UTF-8"]]},
  If[m === $Failed, Null, iProvNoteKeyedDigestCall[purpose]; m["Mac"]]];
iProvDigestOrNull[___] := Null;

(* ============================================================
   spool (§12.1 / §12.8 Spooled) と emit (§3.2 / §12.4)
   ============================================================ *)
If[! AssociationQ[$iProvSpoolState], $iProvSpoolState = <||>];
If[! AssociationQ[$iProvEmitStats],
  $iProvEmitStats = <|"Count" -> 0, "Failed" -> 0, "Slow" -> 0, "TotalMs" -> 0., "MaxMs" -> 0., "LastError" -> Null, "LastEventId" -> Null|>];
If[! AssociationQ[$iProvLocalSpooled], $iProvLocalSpooled = <||>];

(* 今日の spool ファイル。20 MB で -k を増やす。ファイルサイズはメモリで追い、ファイルが変わったときだけ stat する *)
iProvSpoolPath[] := Module[{dir = iProvSpoolDir[], tag = iProvDateTag[], st = $iProvSpoolState, base, path, k, size},
  If[Lookup[st, "Date", None] =!= tag || Lookup[st, "Dir", None] =!= dir, st = <|"Date" -> tag, "Dir" -> dir, "K" -> 0|>];
  base = iProvProducer[] <> "-" <> ToString[$ProcessID] <> "-" <> tag;
  k = Lookup[st, "K", 0];
  path = FileNameJoin[{dir, base <> If[k === 0, "", "-" <> ToString[k]] <> ".jsonl"}];
  size = Lookup[st, "Bytes", None];
  If[! IntegerQ[size] || Lookup[st, "Path", None] =!= path,
    size = If[FileExistsQ[path], Quiet @ Check[FileByteCount[path], 0], 0]];
  While[size >= $SourceVaultProvSpoolRotateBytes && k < 100000,
    k++;
    path = FileNameJoin[{dir, base <> "-" <> ToString[k] <> ".jsonl"}];
    size = If[FileExistsQ[path], Quiet @ Check[FileByteCount[path], 0], 0]];
  $iProvSpoolState = <|"Date" -> tag, "Dir" -> dir, "K" -> k, "Path" -> path, "Bytes" -> size|>;
  path];

(* 1 行を 1 回の BinaryWrite で追記して閉じる (Spooled) *)
iProvSpoolAppend[ba_ByteArray] := Module[{path, dir, strm, ok},
  path = iProvSpoolPath[];
  dir = DirectoryName[path];
  If[! DirectoryQ[dir],
    Quiet @ Check[CreateDirectory[dir, CreateIntermediateDirectories -> True], Null];
    If[! DirectoryQ[dir], Return[Failure["ProvSpoolDirUnwritable", <|"Directory" -> dir|>]]]];
  strm = Quiet @ Check[OpenAppend[path, BinaryFormat -> True], $Failed];
  If[Head[strm] =!= OutputStream, Return[Failure["ProvSpoolOpenFailed", <|"Path" -> path|>]]];
  ok = Quiet @ Check[(BinaryWrite[strm, ba]; Close[strm]; True), (Quiet @ Close[strm]; False)];
  If[! TrueQ[ok], Return[Failure["ProvSpoolWriteFailed", <|"Path" -> path|>]]];
  $iProvSpoolState["Bytes"] = Lookup[$iProvSpoolState, "Bytes", 0] + Length[ba];
  path];

(* envelope: 診断 spool と同じ外形 (Type / EventId / EventClass / Producer / ProducerPid / MachineTag / AtUTC)、Record は最後に正準 JSON の原文 *)
iProvEnvelopeLine[eid_String, type_String, recText_String] := StringJoin[
  "{\"Type\":\"ProvenanceEvent\",\"EventId\":\"", eid, "\",\"EventClass\":\"", type,
  "\",\"Producer\":\"", iProvEscape[iProvProducer[]], "\",\"ProducerPid\":", ToString[$ProcessID],
  ",\"MachineTag\":\"", iProvEscape[iProvMachine[]], "\",\"AtUTC\":\"", iProvNowIso[], "\",\"Record\":", recText, "}\n"];
(* 行から Record の原文を切り出す。Record は最後の field で、その前の field は値に " を含まない *)
iProvRecordTextOfLine[line_String] := Module[{p = StringPosition[line, "\"Record\":", 1], t},
  If[p === {}, Return[$Failed]];
  t = StringTrim[line];
  If[! StringEndsQ[t, "}"], Return[$Failed]];
  StringTake[t, {p[[1, 2]] + 1, -2}]];

iProvNoteLocal[rec_Association] := Module[{id},
  id = Switch[Lookup[rec, "Type", None], "ProvEntity", Lookup[rec, "EntityId", None], "ProvActivity", Lookup[rec, "ActivityId", None], _, None];
  If[StringQ[id],
    $iProvLocalSpooled[id] = AbsoluteTime[];
    If[Length[$iProvLocalSpooled] > 20000, $iProvLocalSpooled = Take[$iProvLocalSpooled, -10000]]]];

SourceVaultProvEmit[rec_Association] := Module[{t0 = AbsoluteTime[], type, eid, recText, line, r, ms, fail},
  type = Lookup[rec, "Type", None];
  eid = With[{e = Lookup[rec, "EventId", None]}, If[iProvULIDQ[e], e, iProvULID[]]];
  fail = Function[{tag, detail},
    $iProvEmitStats["Count"]++; $iProvEmitStats["Failed"]++; $iProvEmitStats["LastError"] = tag;
    Failure[tag, Join[<|"EventId" -> eid, "Ms" -> (AbsoluteTime[] - t0)*1000|>, detail]]];
  If[! MemberQ[$iProvSpoolTypes, type],
    Return[fail["ProvBadRecord", <|"Type" -> type,
      "MessageTemplate" -> "Record Type must be one of ProvBlob / ProvEntity / ProvActivity (ProvKeyRotation / ProvChainRestart are written by the service directly)."|>]]];
  (* Inc3: ラベルの記録 (Finding・解決・解除・認可・検証主張・検証器の登録) はモデル・MCP クライアントから入れられない (表 11.1)。試みは Registry に残す *)
  If[MemberQ[$iProvLabelRecordTypes, type] && ! MemberQ[$iProvOwnerService, iProvPrincipalKind[]],
    iProvNoteRegistryAttempt[type, "SourceVaultProvEmit"];
    Return[fail["ProvNotAuthorized", <|"Type" -> type, "Principal" -> iProvPrincipalKind[],
      "MessageTemplate" -> "Label records (`1`) may be written only by the owner (with a ticket) or the service (03 v0.4 table 11.1).",
      "MessageParameters" -> {type}|>]]];
  recText = iProvCanonText[KeyDrop[rec, "EventId"]];
  If[! StringQ[recText], Return[fail["ProvCanonicalizeFailed", <|"Type" -> type|>]]];
  line = iProvEnvelopeLine[eid, type, recText];
  r = Quiet @ Check[iProvSpoolAppend[StringToByteArray[line, "UTF-8"]], Failure["ProvSpoolWriteFailed", <||>]];
  ms = (AbsoluteTime[] - t0)*1000;
  If[FailureQ[r], Return[fail[r[[1]], <|"Path" -> Lookup[r[[2]], "Path", Lookup[r[[2]], "Directory", Null]]|>]]];
  $iProvEmitStats["Count"]++;
  $iProvEmitStats["TotalMs"] += ms;
  If[ms > $iProvEmitStats["MaxMs"], $iProvEmitStats["MaxMs"] = ms];
  If[ms > $SourceVaultProvEmitBudgetMs, $iProvEmitStats["Slow"]++];
  $iProvEmitStats["LastEventId"] = eid;
  iProvNoteLocal[rec];
  <|"Status" -> "Spooled", "EventId" -> eid, "Ms" -> ms, "Path" -> r|>];
SourceVaultProvEmit[_] := ($iProvEmitStats["Count"]++; $iProvEmitStats["Failed"]++; $iProvEmitStats["LastError"] = "ProvBadRecord";
  Failure["ProvBadRecord", <|"MessageTemplate" -> "rec must be an Association."|>]);

(* ============================================================
   Entity / Activity / Derive (§4.3 / §4.4 / §11.1)
   ============================================================ *)
iProvOriginClass[contribs_List] := Which[
  contribs === {}, "Unknown",
  MemberQ[contribs, "Unknown"], "Unknown",
  MemberQ[contribs, "External"], "ExternalDerived",
  MemberQ[contribs, "Model"], "ModelOverOwner",
  contribs === {"Owner"}, "OwnerOnly",
  True, "Unknown"];
iProvNormalizeOrigin[o_] := Module[{c, t},
  c = If[AssociationQ[o], Lookup[o, "Contributors", {}], {}];
  t = If[AssociationQ[o], Lookup[o, "Taints", {}], {}];
  c = Sort @ DeleteDuplicates @ Select[If[ListQ[c], c, {}], StringQ];
  t = Sort @ DeleteDuplicates @ Select[If[ListQ[t], t, {}], StringQ];
  <|"Contributors" -> c, "Taints" -> t, "OriginClass" -> iProvOriginClass[c]|>];
iProvDefaultOrigin[kind_String, ctx_Association] := Switch[kind,
  "PrimarySource", <|"Contributors" -> {"External"},
    "Taints" -> {"ext:" <> ToLowerCase[ToString[Lookup[ctx, "Channel", "unknown"]]]}|>,
  "OwnerAuthored", <|"Contributors" -> {"Owner"}, "Taints" -> {"edit:owner"}|>,
  _, <|"Contributors" -> {}, "Taints" -> {}|>];
iProvStringAssoc[a_] := If[AssociationQ[a], Association @ KeyValueMap[iProvKeyString[#1] -> If[StringQ[#2], #2, ToString[#2, InputForm]] &, a], <||>];
iProvJSONNull[x_] := If[MissingQ[x] || x === None, Null, x];

SourceVaultProvEntity[spec_Association] := Module[
  {kind, blob, blobId, canonVer, size, media, lr, lrValid, pl, ctx, refs, origin, producedBy, compl, versionOf, eid, rec,
   blobRec, r1, r2, nowIso, bad, claimed = Null, extra},
  bad = Function[{msg, det}, Failure["ProvBadEntitySpec", Join[<|"MessageTemplate" -> msg|>, det]]];
  kind = Lookup[spec, "Kind", None];
  If[! MemberQ[$iProvEntityKinds, kind],
    Return[bad["Kind must be one of the 03 v0.4 table 4.1 kinds.", <|"Kind" -> kind, "Allowed" -> $iProvEntityKinds|>]]];
  Which[
    KeyExistsQ[spec, "Content"] || KeyExistsQ[spec, "ContentRef"],
      blob = SourceVaultProvBlobId[If[KeyExistsQ[spec, "Content"], spec["Content"], File[ToString @ spec["ContentRef"]]],
        "Kind" -> Lookup[spec, "ContentKind", Automatic], "CanonVersion" -> Lookup[spec, "CanonVersion", 1]];
      If[FailureQ[blob], Return[blob]];
      blobId = blob["BlobId"]; canonVer = blob["CanonVersion"]; size = blob["Size"],
    iProvBlobIdQ[Lookup[spec, "BlobId", None]],
      blobId = spec["BlobId"]; canonVer = Lookup[spec, "CanonVersion", 1];
      size = With[{s = Lookup[spec, "Size", Null]}, If[IntegerQ[s], s, Null]],
    (* Inc2 (§6.1): 記録点が内容に届かないときは呼び出し側の ContentHash を ClaimedContentHash として残し Completeness Partial。
       sha256 の 64 hex なら BlobId として持つが正準化の版は不明 (CanonVersion Null)。hex で無ければ BlobId 無し (Null) *)
    KeyExistsQ[spec, "ClaimedContentHash"],
      With[{c = ToString @ spec["ClaimedContentHash"], hx = Last[StringCases[ToString @ spec["ClaimedContentHash"], RegularExpression["([0-9a-fA-F]{64})"] -> "$1"], ""]},
        blobId = If[hx =!= "", "blob:sha256:" <> ToLowerCase[hx], Null]; canonVer = Null; size = Null; claimed = c],
    True, Return[bad["Content, ContentRef, a valid BlobId (blob:sha256:<hex64>) or ClaimedContentHash is required.", <||>]]];
  ctx = Lookup[spec, "Context", <||>];
  If[! AssociationQ[ctx], Return[bad["Context must be an Association.", <||>]]];
  With[{hit = Intersection[Keys[ctx], $iProvForbiddenContextKeys]},
    If[hit =!= {},
      Return[Failure["ProvContextForbiddenKey", <|"Keys" -> hit,
        "MessageTemplate" -> "Context must not carry plain external identifiers or content (`1`); use SourceVaultProvKeyedDigest (03 v0.4 12.2).",
        "MessageParameters" -> {StringRiffle[hit, ", "]}|>]]]];
  ctx = Association @ KeyValueMap[iProvKeyString[#1] -> iProvJSONNull[#2] &, ctx];
  refs = iProvStringAssoc[Lookup[spec, "Refs", <||>]];
  lr = Lookup[spec, "LogicalRef", Null];
  If[! StringQ[lr] || lr === "", lr = Null];
  lrValid = StringQ[lr];
  If[lrValid && StringStartsQ[lr, "sv://"] && Length[DownValues[SourceVault`SourceVaultCanonicalURI]] > 0,
    With[{c = Quiet @ Check[SourceVault`SourceVaultCanonicalURI[lr], $Failed]},
      If[StringQ[c], lr = c, lrValid = False]]];
  pl = Lookup[spec, "PrivacyLevel", Automatic];
  If[! (NumericQ[pl] && 0 <= pl <= 1),
    pl = If[NumberQ[SourceVault`$SourceVaultDefaultObjectPrivacyLevel], SourceVault`$SourceVaultDefaultObjectPrivacyLevel, 0.85]];
  pl = N[pl];
  media = With[{m = Lookup[spec, "Media", Null]}, If[StringQ[m], m, Null]];
  origin = Lookup[spec, "Origin", Automatic];
  If[! AssociationQ[origin],
    origin = If[ListQ[Lookup[spec, "Contributors", None]],
      <|"Contributors" -> spec["Contributors"], "Taints" -> Lookup[spec, "Taints", {}]|>,
      iProvDefaultOrigin[kind, ctx]]];
  origin = iProvNormalizeOrigin[origin];
  producedBy = Select[Flatten[{Lookup[spec, "ProducedBy", {}]}], iProvActivityIdQ];
  compl = With[{c = Lookup[spec, "Completeness", "Unknown"]}, If[MemberQ[$iProvCompleteness, c], c, "Unknown"]];
  If[StringQ[claimed] && compl === "Complete", compl = "Partial"];
  versionOf = With[{v = Lookup[spec, "VersionOf", Null]}, If[iProvEntityIdQ[v], v, Null]];
  eid = With[{e = Lookup[spec, "EntityId", None]}, If[iProvEntityIdQ[e], e, "ent-" <> iProvULID[]]];
  nowIso = iProvNowIso[];
  (* Inc2: 記録点の付加項目 (Backfilled / ClaimedContentHash / UnrecordedInputs) は Record に残す *)
  extra = DeleteCases[<|"Backfilled" -> If[TrueQ[Lookup[spec, "Backfilled", False]], True, Null],
    "ClaimedContentHash" -> If[StringQ[claimed], claimed, Null],
    "UnrecordedInputs" -> With[{u = Select[Flatten[{Lookup[spec, "UnrecordedInputs", {}]}], StringQ]},
      If[u === {} && ! StringQ[claimed], Null, DeleteDuplicates @ Join[u, If[StringQ[claimed], {"Content"}, {}]]]]|>, Null];
  rec = Join[<|"Type" -> "ProvEntity", "SchemaVersion" -> 2, "EntityId" -> eid, "BlobId" -> blobId, "CanonVersion" -> canonVer,
    "LogicalRef" -> lr, "LogicalRefValid" -> lrValid, "VersionOf" -> versionOf, "Refs" -> refs, "Kind" -> kind, "Media" -> media,
    "Context" -> ctx, "PrivacyLevel" -> pl, "Origin" -> origin, "ProducedBy" -> producedBy, "Completeness" -> compl,
    "CreatedAtUTC" -> nowIso, "Machine" -> iProvMachine[], "Producer" -> iProvProducer[]|>, extra];
  r1 = If[StringQ[blobId] && IntegerQ[canonVer],
    SourceVaultProvEmit[<|"Type" -> "ProvBlob", "BlobId" -> blobId, "CanonVersion" -> canonVer, "Size" -> size, "FirstSeenUTC" -> nowIso|>],
    <|"Status" -> "Skipped", "EventId" -> Null, "Ms" -> 0.|>];
  r2 = SourceVaultProvEmit[rec];
  If[FailureQ[r1] || FailureQ[r2],
    Return[Failure["ProvEmitFailed", <|"EntityId" -> eid, "BlobId" -> If[pl >= 0.5, Missing["Withheld"], blobId],
      "Blob" -> r1, "Entity" -> r2|>]]];
  <|"Status" -> "Spooled", "EntityId" -> eid, "BlobId" -> blobId, "CanonVersion" -> canonVer, "PrivacyLevel" -> pl,
    "Origin" -> origin, "Completeness" -> compl, "EventIds" -> DeleteCases[{r1["EventId"], r2["EventId"]}, Null], "Ms" -> r1["Ms"] + r2["Ms"]|>];
SourceVaultProvEntity[___] := Failure["ProvBadEntitySpec", <|"MessageTemplate" -> "spec must be an Association."|>];

(* Inputs / Outputs の正規化: 文字列 (EntityId) か <|"EntityId", "Role"|> *)
iProvNormalizeRefs[refs_, defaultRole_String, roles_] := Module[{out = {}, bad = {}},
  Scan[Function[r, Module[{id, role},
      {id, role} = Which[
        StringQ[r], {r, defaultRole},
        AssociationQ[r], {Lookup[r, "EntityId", None], Lookup[r, "Role", defaultRole]},
        True, {None, None}];
      If[! iProvEntityIdQ[id] || ! StringQ[role] || (roles =!= All && ! MemberQ[roles, role]),
        AppendTo[bad, r],
        AppendTo[out, <|"EntityId" -> id, "Role" -> role|>]]]],
    Flatten[{refs}]];
  If[bad =!= {}, Failure["ProvBadRefs", <|"Bad" -> bad, "AllowedRoles" -> roles|>], out]];
iProvActorFromPrincipal[spec_Association] := Module[{p, kind},
  p = Quiet @ Check[SourceVault`SourceVaultPrincipal[], <|"Kind" -> "Model"|>];
  If[! AssociationQ[p], p = <|"Kind" -> "Model"|>];
  kind = Switch[Lookup[p, "Kind", "Model"], "OwnerFE" | "OwnerCode", "Owner", "Service", "Service", "MCP", "MCPClient", _, "Model"];
  <|"Kind" -> kind, "Principal" -> ToString[Lookup[p, "Kind", "Model"]],
    "Channel" -> With[{c = Lookup[p, "Channel", Null]}, If[StringQ[c], c, "Unbound"]],
    "Provider" -> With[{v = Lookup[spec, "Provider", Null]}, If[StringQ[v], v, Null]],
    "ModelRef" -> With[{v = Lookup[spec, "ModelRef", Null]}, If[StringQ[v], v, Null]],
    "IdentityEvidence" -> If[StringQ[Lookup[spec, "ModelRef", Null]], "Claimed", "Unknown"],
    "OnBehalfOf" -> "Owner", "DeterminedBy" -> "Recorder"|>];
iProvNormalizeToolCalls[tc_] := Select[Map[Function[t, If[! AssociationQ[t], Null,
    <|"Name" -> ToString @ Lookup[t, "Name", "unknown"],
      "ArgsDigest" -> Which[
        StringQ[Lookup[t, "ArgsDigest", None]] && StringStartsQ[t["ArgsDigest"], "hmac:"], t["ArgsDigest"],
        StringQ[Lookup[t, "Args", None]], iProvDigestOrNull["ToolArgs", t["Args"]],
        True, Null],
      "Decision" -> With[{d = Lookup[t, "Decision", Null]}, If[StringQ[d], d, Null]],
      "DecisionRef" -> With[{d = Lookup[t, "DecisionRef", Null]}, If[StringQ[d], d, Null]]|>]],
  Flatten[{tc}]], AssociationQ];

SourceVaultProvActivity[spec_Association] := Module[
  {kind, inputs, outputs, actor, claimed, aid, rec, pd, tools, compl, unrec, lid, lsrc, ext, r, nowIso, started, ended, outcome},
  kind = Lookup[spec, "Kind", None];
  If[! MemberQ[$iProvActivityKinds, kind],
    Return[Failure["ProvBadActivitySpec", <|"Kind" -> kind, "Allowed" -> $iProvActivityKinds,
      "MessageTemplate" -> "Kind must be one of the 03 v0.4 table 4.2 kinds."|>]]];
  inputs = iProvNormalizeRefs[Lookup[spec, "Inputs", {}], "Context", $iProvInputRoles];
  If[FailureQ[inputs], Return[inputs]];
  outputs = iProvNormalizeRefs[Lookup[spec, "Outputs", {}], "Primary", All];
  If[FailureQ[outputs], Return[outputs]];
  actor = iProvActorFromPrincipal[spec];
  claimed = <|"Actor" -> With[{a = Lookup[spec, "Actor", Null]}, If[AssociationQ[a] || StringQ[a], a, Null]],
    "ClaimedClient" -> With[{c = Quiet @ Check[SourceVault`SourceVaultPrincipal["ClaimedClient"], Null]}, If[StringQ[c], c, Null]]|>;
  pd = Lookup[spec, "PromptDigest", Null];
  If[StringQ[Lookup[spec, "Prompt", None]], pd = iProvDigestOrNull["Prompt", spec["Prompt"]]];
  If[! (StringQ[pd] && StringStartsQ[pd, "hmac:"]), pd = Null];
  tools = iProvNormalizeToolCalls[Lookup[spec, "ToolCalls", {}]];
  compl = With[{c = Lookup[spec, "InputsCompleteness", Lookup[spec, "Completeness", "Unknown"]]}, If[MemberQ[$iProvCompleteness, c], c, "Unknown"]];
  unrec = Select[Flatten[{Lookup[spec, "UnrecordedInputs", {}]}], StringQ];
  lid = Lookup[spec, "LineageId", Null]; lsrc = Lookup[spec, "LineageSource", Null];
  If[! StringQ[lid] && StringQ[Lookup[spec, "SessionKey", None]], lid = spec["SessionKey"]; lsrc = "SessionKey"];
  If[! StringQ[lid], lid = Null; lsrc = Null];
  If[StringQ[lid] && ! StringQ[lsrc], lsrc = "SessionKey"];
  ext = iProvStringAssoc[Lookup[spec, "ExternalRefs", <||>]];
  nowIso = iProvNowIso[];
  started = With[{s = Lookup[spec, "StartedAtUTC", Null]}, If[StringQ[s], s, nowIso]];
  ended = With[{s = Lookup[spec, "EndedAtUTC", Null]}, If[StringQ[s], s, nowIso]];
  outcome = With[{s = Lookup[spec, "Outcome", "Succeeded"]}, If[StringQ[s], s, "Succeeded"]];
  aid = With[{a = Lookup[spec, "ActivityId", None]}, If[iProvActivityIdQ[a], a, "act-" <> iProvULID[]]];
  rec = <|"Type" -> "ProvActivity", "SchemaVersion" -> 2, "ActivityId" -> aid, "Kind" -> kind,
    "StartedAtUTC" -> started, "EndedAtUTC" -> ended, "Outcome" -> outcome, "Actor" -> actor,
    "Inputs" -> inputs, "InputsCompleteness" -> compl, "UnrecordedInputs" -> unrec, "Outputs" -> outputs,
    "PromptDigest" -> pd, "ToolCalls" -> tools,
    "PolicyDigest" -> With[{s = Lookup[spec, "PolicyDigest", Null]}, If[StringQ[s], s, Null]],
    "LineageId" -> lid, "LineageSource" -> lsrc, "ExternalRefs" -> ext, "Claimed" -> claimed,
    "Completeness" -> compl, "Machine" -> iProvMachine[], "Producer" -> iProvProducer[], "Pid" -> $ProcessID|>;
  (* Inc2: 記録点の付加項目。DeclaredInputs (宣言した入力の種類、§6.1)、Backfilled (§6.3)、Detail (メタデータだけ。禁止キーは落とす) *)
  rec = Join[rec, DeleteCases[<|
    "DeclaredInputs" -> With[{d = Select[Flatten[{Lookup[spec, "DeclaredInputs", {}]}], StringQ]}, If[d === {}, Null, d]],
    "Backfilled" -> If[TrueQ[Lookup[spec, "Backfilled", False]], True, Null],
    "Detail" -> With[{d = Lookup[spec, "Detail", Null]},
      If[AssociationQ[d] && d =!= <||>, Association @ KeyValueMap[iProvKeyString[#1] -> iProvJSONNull[#2] &, KeyDrop[d, $iProvForbiddenContextKeys]], Null]]|>, Null]];
  r = SourceVaultProvEmit[rec];
  If[FailureQ[r], Return[Failure["ProvEmitFailed", <|"ActivityId" -> aid, "Activity" -> r|>]]];
  <|"Status" -> "Spooled", "ActivityId" -> aid, "EventId" -> r["EventId"], "Actor" -> actor, "Ms" -> r["Ms"]|>];
SourceVaultProvActivity[___] := Failure["ProvBadActivitySpec", <|"MessageTemplate" -> "spec must be an Association."|>];

SourceVaultProvDerive[kind_String, inputs_, outputs_, opts___] := Module[{aid, optA, outIds = {}, ents = {}, act, ok = True},
  optA = Which[
    MatchQ[{opts}, {_Association}], First[{opts}],
    MatchQ[{opts}, {(_Rule | _RuleDelayed) ...}], Association[opts],
    True, <||>];
  aid = "act-" <> iProvULID[];
  Scan[Function[o, Which[
      iProvEntityIdQ[o], AppendTo[outIds, o],
      AssociationQ[o],
        With[{e = SourceVaultProvEntity[Append[o, "ProducedBy" -> Union[Select[Flatten[{Lookup[o, "ProducedBy", {}]}], iProvActivityIdQ], {aid}]]]},
          AppendTo[ents, e];
          If[FailureQ[e], ok = False, AppendTo[outIds, e["EntityId"]]]],
      True, ok = False; AppendTo[ents, Failure["ProvBadRefs", <|"Bad" -> {o}|>]]]],
    Flatten[{outputs}]];
  act = SourceVaultProvActivity[Join[optA, <|"Kind" -> kind, "ActivityId" -> aid, "Inputs" -> inputs, "Outputs" -> outIds|>]];
  <|"Status" -> If[ok && ! FailureQ[act], "Spooled", "Failed"], "ActivityId" -> aid, "Outputs" -> outIds, "Entities" -> ents,
    "Activity" -> act|>];

(* ============================================================
   index-meta.json (§8.1 / §12.8): 読取位置・Seq・DurableSeq・IndexSeq・ChainState
   ============================================================ *)
iProvDefaultMeta[] := <|"Format" -> "SourceVaultProvIndexMeta/1", "LastSeq" -> 0, "DurableSeq" -> 0, "IndexSeq" -> 0,
  "LastLineHash" -> $iProvGenesisHash, "LedgerFile" -> Null, "LedgerBytes" -> 0, "ChainState" -> "OK", "ChainDamage" -> Null,
  "Rebuilding" -> False, "CarryOver" -> False, "SpoolOffsets" -> <||>, "AdapterOffsets" -> <||>, "PendingCount" -> 0,
  "Counts" -> <|"Entities" -> 0, "Activities" -> 0, "Blobs" -> 0, "Corrupt" -> 0, "Duplicates" -> 0, "BlobDuplicates" -> 0,
    "Rejected" -> 0, "Adapter" -> 0, "PendingPartial" -> 0|>,
  "LastIngestAtUTC" -> Null, "LastCheckpointDate" -> Null, "RebuiltAtUTC" -> Null, "UpdatedAtUTC" -> Null,
  (* Inc1b: feeds に射影済みの Seq、射影した版の PL の最大 (下限 0.3)、checkpoint の読取位置 (次の checkpoint の Merkle 根を台帳の続きから計算する) *)
  "FeedSeq" -> 0, "FeedMaxPL" -> 0.3, "CheckpointCursor" -> Null, "LastFeedSyncAtUTC" -> Null,
  "Machine" -> iProvMachine[]|>;
iProvMetaPath[] := iProvIndexPath["index-meta.json"];
iProvReadMeta[] := Module[{p = iProvMetaPath[], m},
  If[p === $Failed, Return[$Failed]];
  m = iProvReadJSON[p];
  If[! AssociationQ[m] || Lookup[m, "Format", ""] =!= "SourceVaultProvIndexMeta/1", Return[iProvDefaultMeta[]]];
  m = Join[iProvDefaultMeta[], m];
  m["Counts"] = Join[iProvDefaultMeta[]["Counts"], If[AssociationQ[m["Counts"]], m["Counts"], <||>]];
  If[! AssociationQ[m["SpoolOffsets"]], m["SpoolOffsets"] = <||>];
  If[! AssociationQ[m["AdapterOffsets"]], m["AdapterOffsets"] = <||>];
  m];
iProvWriteMeta[m_Association] := ($iProvMetaCache = <||>; iProvWriteJSONAtomic[iProvMetaPath[], Append[m, "UpdatedAtUTC" -> iProvNowIso[]]]);
(* FE 側の短い TTL キャッシュ (Usability の無効化判定に毎回ファイルを読まない) *)
If[! AssociationQ[$iProvMetaCache], $iProvMetaCache = <||>];
iProvReadMetaCached[ttl_: 2] := Module[{now = AbsoluteTime[]},
  If[AssociationQ[Lookup[$iProvMetaCache, "Meta", None]] && now - Lookup[$iProvMetaCache, "At", 0] < ttl,
    Return[$iProvMetaCache["Meta"]]];
  With[{m = iProvReadMeta[]},
    $iProvMetaCache = <|"Meta" -> m, "At" -> now|>; m]];

(* ============================================================
   seen (EventId の重複抑止)・保留 (参照先の無い Activity)
   ============================================================ *)
If[! ValueQ[$iProvSeen], $iProvSeen = None];
If[! ValueQ[$iProvSeenDirty], $iProvSeenDirty = False];
iProvSeenPath[] := iProvIndexPath["seen-events.wxf"];
iProvSeenEnsure[] := If[! AssociationQ[$iProvSeen],
  With[{l = iProvReadWXF[iProvSeenPath[]]},
    $iProvSeen = If[ListQ[l], AssociationThread[Select[l, StringQ] -> True], <||>]];
  $iProvSeenDirty = False];
iProvSeenQ[eid_String] := (iProvSeenEnsure[]; KeyExistsQ[$iProvSeen, eid]);
iProvSeenAdd[eid_String] := (iProvSeenEnsure[]; $iProvSeen[eid] = True; $iProvSeenDirty = True);
iProvSeenSave[] := If[AssociationQ[$iProvSeen] && TrueQ[$iProvSeenDirty],
  If[Length[$iProvSeen] > $iProvSeenMax, $iProvSeen = Take[$iProvSeen, -$iProvSeenMax]];
  iProvWriteWXFAtomic[iProvSeenPath[], Keys[$iProvSeen]];
  $iProvSeenDirty = False];

If[! ValueQ[$iProvPending], $iProvPending = None];
If[! ValueQ[$iProvPendingDirty], $iProvPendingDirty = False];
iProvPendingPath[] := iProvIndexPath["pending.wxf"];
iProvPendingEnsure[] := If[! ListQ[$iProvPending],
  With[{l = iProvReadWXF[iProvPendingPath[]]}, $iProvPending = If[ListQ[l], Select[l, AssociationQ], {}]];
  $iProvPendingDirty = False];
iProvPendingSave[] := If[ListQ[$iProvPending] && TrueQ[$iProvPendingDirty],
  iProvWriteWXFAtomic[iProvPendingPath[], $iProvPending]; $iProvPendingDirty = False];

(* Inc2: LLMCall の結合待ち行列 (index/llmcall-queue.wxf)。取込で入り、SourceVaultProvJoinLLMCalls が消す *)
If[! ValueQ[$iProvLLMQueue], $iProvLLMQueue = None];
If[! ValueQ[$iProvLLMQueueDirty], $iProvLLMQueueDirty = False];
iProvLLMQueuePath[] := iProvIndexPath["llmcall-queue.wxf"];
iProvLLMQueueEnsure[] := (If[! ListQ[$iProvLLMQueue],
  With[{l = iProvReadWXF[iProvLLMQueuePath[]]}, $iProvLLMQueue = If[ListQ[l], Select[l, AssociationQ], {}]];
  $iProvLLMQueueDirty = False]; iProvGroundingQueueEnsure[]);
iProvLLMQueueSave[] := (If[ListQ[$iProvLLMQueue] && TrueQ[$iProvLLMQueueDirty],
  iProvWriteWXFAtomic[iProvLLMQueuePath[], $iProvLLMQueue]; $iProvLLMQueueDirty = False]; iProvGroundingQueueSave[]);
(* V9: 裏付けの結果の待ち行列 (index/grounding-queue.wxf)。取込で入り、回答の版に結び付いたら消す。LLMCall の待ち行列と同じ所で読み書きする *)
If[! ValueQ[$iProvGroundingQueue], $iProvGroundingQueue = None];
If[! ValueQ[$iProvGroundingQueueDirty], $iProvGroundingQueueDirty = False];
iProvGroundingQueuePath[] := iProvIndexPath["grounding-queue.wxf"];
iProvGroundingQueueEnsure[] := If[! ListQ[$iProvGroundingQueue],
  With[{l = iProvReadWXF[iProvGroundingQueuePath[]]}, $iProvGroundingQueue = If[ListQ[l], Select[l, AssociationQ], {}]];
  $iProvGroundingQueueDirty = False];
iProvGroundingQueueSave[] := If[ListQ[$iProvGroundingQueue] && TrueQ[$iProvGroundingQueueDirty],
  iProvWriteWXFAtomic[iProvGroundingQueuePath[], $iProvGroundingQueue]; $iProvGroundingQueueDirty = False];

(* ============================================================
   索引 (§8.1): メモリ上は平たい Association ごとに持つ (入れ子の部分代入を避ける)。
   差分更新と再構築は同じ iProvIndexApply を Seq 順に使う (決定的、T-P5)
   ============================================================ *)
iProvIndexReset[] := (
  $iProvEntities = <||>; $iProvActivities = <||>; $iProvBlobs = <||>; $iProvBlobRecords = <||>;
  $iProvLogical = <||>; $iProvRefs = <||>; $iProvLabels = <||>; $iProvEffective = <||>; $iProvChainEvents = {};
  (* Inc2: SessionKey (LineageId) -> Activity の列 (結合用)、Activity の ExternalRefs の値 -> ActivityId (adapter の重複抑止用) *)
  $iProvLineage = <||>; $iProvActRefs = <||>;
  (* Inc3: ラベルの記録 (Finding・解決・解除・認可・検証主張・検証器の登録)、carry / Cite の辺、隔離の集合、Registry の不一致 *)
  $iProvLabelIds = <||>; $iProvFindingsX = <||>; $iProvResolutionsX = <||>; $iProvReleasesX = <||>; $iProvAuthzX = <||>;
  $iProvClaimsX = <||>; $iProvVerifierRegX = <||>; $iProvCarryOut = <||>; $iProvCiteOut = <||>; $iProvQuarantineX = <||>;
  $iProvCiteReach = <||>; $iProvRegistryIssues = {}; $iProvTicketNonces = <||>; $iProvQuarantineDirty = False; $iProvInstrUseLog = {};
  $iProvStaleX = <||>;
  (* Inc5: レビュー順の点数 (親の一覧・点数・持ち越しの種・計算中の印・見つかった循環) *)
  $iProvParentsX = <||>; $iProvScoreX = <||>; $iProvScoreSeeds = {}; $iProvScoreStale = <||>; $iProvScoreCycles = {};
  $iProvIndexSeq = 0; $iProvIndexLoaded = True; $iProvIndexDirty = False);
If[! TrueQ[$iProvIndexLoaded], iProvIndexReset[]; $iProvIndexLoaded = False];

iProvEntityUsability[labels_Association] := Which[
  Lookup[labels, "Completeness", "Unknown"] =!= "Complete", {"Unknown", "Completeness" <> ToString[Lookup[labels, "Completeness", "Unknown"]]},
  Lookup[Lookup[labels, "Origin", <||>], "OriginClass", "Unknown"] === "Unknown", {"Unknown", "OriginUnknown"},
  True, {"Usable", "Committed"}];

iProvIndexApply[seq_Integer, rec_Association] := Module[{type = Lookup[rec, "Type", None], id, bid, lr, u},
  Switch[type,
    "ProvBlob",
      bid = Lookup[rec, "BlobId", None];
      If[iProvBlobIdQ[bid] && ! KeyExistsQ[$iProvBlobRecords, bid],
        $iProvBlobRecords[bid] = <|"Seq" -> seq, "CanonVersion" -> Lookup[rec, "CanonVersion", Null], "Size" -> Lookup[rec, "Size", Null]|>;
        If[! KeyExistsQ[$iProvBlobs, bid], $iProvBlobs[bid] = {}]],
    "ProvEntity",
      id = Lookup[rec, "EntityId", None];
      If[iProvEntityIdQ[id] && ! KeyExistsQ[$iProvEntities, id],
        bid = Lookup[rec, "BlobId", Null]; lr = Lookup[rec, "LogicalRef", Null];
        $iProvEntities[id] = <|"Seq" -> seq, "BlobId" -> bid, "LogicalRef" -> lr, "Kind" -> Lookup[rec, "Kind", Null],
          "ProducedBy" -> Select[Flatten[{Lookup[rec, "ProducedBy", {}]}], StringQ], "UsedBy" -> {}|>;
        If[StringQ[bid], $iProvBlobs[bid] = Append[Lookup[$iProvBlobs, bid, {}], id]];
        If[StringQ[lr], $iProvLogical[lr] = Append[Lookup[$iProvLogical, lr, {}], id]];
        With[{refs = Lookup[rec, "Refs", <||>]},
          If[AssociationQ[refs], Scan[Function[v, If[StringQ[v], $iProvRefs[v] = Append[Lookup[$iProvRefs, v, {}], id]]], Values[refs]]]];
        $iProvLabels[id] = <|"PrivacyLevel" -> Lookup[rec, "PrivacyLevel", Null],
          "Origin" -> With[{o = Lookup[rec, "Origin", <||>]}, If[AssociationQ[o], iProvNormalizeOrigin[o], iProvNormalizeOrigin[<||>]]],
          "Completeness" -> Lookup[rec, "Completeness", "Unknown"], "Kind" -> Lookup[rec, "Kind", Null],
          "Media" -> Lookup[rec, "Media", Null], "LogicalRef" -> lr, "Uses" -> 0, "Seq" -> seq,
          (* Inc2: Coverage の窓 (作成時刻) と backfill の除外印 *)
          "CreatedAbs" -> With[{a = iProvIsoToAbs[ToString @ Lookup[rec, "CreatedAtUTC", ""]]}, If[NumberQ[a], a, Null]],
          "Backfilled" -> TrueQ[Lookup[rec, "Backfilled", False]]|>;
        u = iProvEntityUsability[$iProvLabels[id]];
        $iProvEffective[id] = <|"Usability" -> u[[1]], "Seq" -> seq, "Reason" -> u[[2]]|>;
        (* Inc3: 内容 (BlobId) に対する Finding があれば、同じ内容の新しい版も隔離の対象になる *)
        If[$iProvFindingsX =!= <||>, $iProvQuarantineDirty = True];
        iProvScoreSeed[id]],
    "ProvActivity",
      id = Lookup[rec, "ActivityId", None];
      If[iProvActivityIdQ[id] && ! KeyExistsQ[$iProvActivities, id],
        With[{ins = Select[Flatten[{Lookup[rec, "Inputs", {}]}], AssociationQ], outs = Select[Flatten[{Lookup[rec, "Outputs", {}]}], AssociationQ],
              actor = With[{a = Lookup[rec, "Actor", <||>]}, If[AssociationQ[a], a, <||>]], lid = Lookup[rec, "LineageId", Null],
              startedAbs = With[{a = iProvIsoToAbs[ToString @ Lookup[rec, "StartedAtUTC", ""]]}, If[NumberQ[a], a, Null]]},
          $iProvActivities[id] = <|"Seq" -> seq, "Kind" -> Lookup[rec, "Kind", Null],
            "Inputs" -> ({Lookup[#, "EntityId", Null], Lookup[#, "Role", Null]} & /@ ins),
            "Outputs" -> ({Lookup[#, "EntityId", Null], Lookup[#, "Role", Null]} & /@ outs),
            "Adapter" -> Lookup[rec, "Adapter", Null],
            (* Inc2: Coverage (ModelRef / IdentityEvidence) と結合 (LineageId / 時刻) のための列 *)
            "ActorKind" -> Lookup[actor, "Kind", Null], "ModelRef" -> Lookup[actor, "ModelRef", Null],
            "IdentityEvidence" -> Lookup[actor, "IdentityEvidence", Null], "Completeness" -> Lookup[rec, "Completeness", Lookup[rec, "InputsCompleteness", "Unknown"]],
            "LineageId" -> If[StringQ[lid], lid, Null], "StartedAbs" -> startedAbs, "Backfilled" -> TrueQ[Lookup[rec, "Backfilled", False]],
            (* Inc4: 公開の関所が止めた Publish (Outcome Blocked) と通したものを分ける (PublishUnusable) *)
            "Outcome" -> With[{o = Lookup[rec, "Outcome", "Succeeded"]}, If[StringQ[o], o, "Succeeded"]],
            (* 2026-11-11: 公開の結果 (SourceVaultIntegrityPublishOutcome) が指す意図の ActivityId *)
            "IntentActivity" -> If[Lookup[rec, "Kind", Null] === "Publish",
              With[{x = Lookup[rec, "ExternalRefs", <||>]}, If[AssociationQ[x] && iProvActivityIdQ[Lookup[x, "IntentActivity", None]], x["IntentActivity"], Null]], Null]|>;
          If[StringQ[lid],
            $iProvLineage[lid] = Append[Lookup[$iProvLineage, lid, {}],
              <|"ActivityId" -> id, "Seq" -> seq, "Kind" -> Lookup[rec, "Kind", Null], "StartedAbs" -> startedAbs,
                "AtMs" -> With[{d = Lookup[rec, "Detail", <||>]}, With[{ms = If[AssociationQ[d], Lookup[d, "AtUnixMs", Null], Null]},
                  If[IntegerQ[ms], ms, iProvIsoToUnixMs[ToString @ Lookup[rec, "StartedAtUTC", ""]]]]]|>]];
          With[{ext = Lookup[rec, "ExternalRefs", <||>]},
            If[AssociationQ[ext],
              KeyValueMap[Function[{k, v}, If[StringQ[v] && v =!= "", $iProvActRefs[iProvKeyString[k] <> ":" <> v] = id]], ext]]];
          Scan[Function[i, With[{e = Lookup[i, "EntityId", None]},
              If[StringQ[e] && KeyExistsQ[$iProvEntities, e],
                $iProvEntities[e, "UsedBy"] = Append[$iProvEntities[e, "UsedBy"], id];
                $iProvLabels[e, "Uses"] = $iProvLabels[e, "Uses"] + 1]]], ins];
          Scan[Function[o, With[{e = Lookup[o, "EntityId", None]},
              If[StringQ[e] && KeyExistsQ[$iProvEntities, e] && ! MemberQ[$iProvEntities[e, "ProducedBy"], id],
                $iProvEntities[e, "ProducedBy"] = Append[$iProvEntities[e, "ProducedBy"], id]]]], outs];
          (* Inc3: Role Instruction の使用の記録 (7.1 節 InstructionAuthorization が全 Activity をなめずに読む) *)
          With[{iu = Select[ins, Lookup[#, "Role", ""] === "Instruction" && StringQ[Lookup[#, "EntityId", None]] &]},
            If[iu =!= {},
              $iProvInstrUseLog = Join[$iProvInstrUseLog, (<|"ActivityId" -> id, "Seq" -> seq, "EntityId" -> #["EntityId"]|> &) /@ iu];
              If[Length[$iProvInstrUseLog] > 20000, $iProvInstrUseLog = Take[$iProvInstrUseLog, -20000]]]];
          (* Inc3: carry / Cite の辺と出自の合成 (5.2 節) *)
          iProvComposeActivity[id, rec, ins, outs, actor]];
        $iProvEffective[id] = <|"Usability" -> "Recorded", "Seq" -> seq, "Reason" -> "Activity"|>],
    "ProvKeyRotation" | "ProvChainRestart",
      AppendTo[$iProvChainEvents, <|"Seq" -> seq, "Type" -> type|>],
    _?(MemberQ[$iProvLabelRecordTypes, #] &),
      iProvApplyLabelRecord[seq, type, rec],
    _, Null];
  $iProvIndexSeq = seq;
  $iProvIndexDirty = True];

iProvIndexSave[meta_Association] := Module[{ok = True},
  (* Inc3: 隔離の集合は保存の直前に計算し直す (到達可能性、8.2 節) *)
  If[TrueQ[$iProvQuarantineDirty], iProvQuarantineRecompute[]];
  (* Inc5: レビュー順の点数 (予算つき、持ち越しは Stale) *)
  If[ListQ[$iProvScoreSeeds] && $iProvScoreSeeds =!= {}, Quiet @ Check[iProvScoreUpdate[$SourceVaultProvScoreBudgetSeconds], Null]];
  ok = ok && iProvWriteWXFAtomic[iProvIndexPath["graph.wxf"],
    <|"Format" -> "SourceVaultProvGraph/1", "IndexSeq" -> $iProvIndexSeq, "Entities" -> $iProvEntities, "Activities" -> $iProvActivities,
      "Blobs" -> $iProvBlobs, "BlobRecords" -> $iProvBlobRecords, "Refs" -> $iProvRefs, "ChainEvents" -> $iProvChainEvents,
      "Lineage" -> $iProvLineage, "ActRefs" -> $iProvActRefs,
      "LabelRecords" -> iProvLabelState[]|>] =!= $Failed;
  ok = ok && iProvWriteWXFAtomic[iProvIndexPath["logical.wxf"], <|"Format" -> "SourceVaultProvLogical/1", "IndexSeq" -> $iProvIndexSeq, "Logical" -> $iProvLogical|>] =!= $Failed;
  ok = ok && iProvWriteWXFAtomic[iProvIndexPath["labels.wxf"], <|"Format" -> "SourceVaultProvLabels/1", "IndexSeq" -> $iProvIndexSeq, "Labels" -> $iProvLabels|>] =!= $Failed;
  ok = ok && iProvWriteWXFAtomic[iProvIndexPath["effective.wxf"], <|"Format" -> "SourceVaultProvEffective/1", "IndexSeq" -> $iProvIndexSeq, "Effective" -> $iProvEffective|>] =!= $Failed;
  ok = ok && iProvWriteUsability[meta] =!= $Failed;
  If[ok, $iProvIndexDirty = False];
  ok];
(* FE が読む小さな索引: Ids / Codes / Seq の 3 本の列 (Association より読込が速い) *)
iProvWriteUsability[meta_Association] := Module[{vals = Values[$iProvEffective]},
  iProvWriteWXFAtomic[iProvIndexPath["usability.wxf"],
    <|"Format" -> "SourceVaultProvUsability/1", "IndexSeq" -> $iProvIndexSeq, "DurableSeq" -> Lookup[meta, "DurableSeq", 0],
      "Ids" -> Keys[$iProvEffective],
      "Codes" -> Developer`ToPackedArray[Lookup[$iProvUsabilityCodes, Lookup[#, "Usability", "Unknown"], 0] & /@ vals],
      "Seq" -> Developer`ToPackedArray[Lookup[#, "Seq", 0] & /@ vals],
      (* Inc3: 検索フィルタ・LoadVerify が FE で読む小さな表 (隔離・AcceptedRisk・派生物の Unknown・有効な認可) *)
      "Extras" -> iProvUsabilityExtras[]|>]];
(* WXF から読む。IndexSeq が meta と合わなければ False (呼び側が再構築する) *)
iProvIndexLoadFiles[expectedSeq_] := Module[{g, l, b, e},
  g = iProvReadWXF[iProvIndexPath["graph.wxf"]]; l = iProvReadWXF[iProvIndexPath["logical.wxf"]];
  b = iProvReadWXF[iProvIndexPath["labels.wxf"]]; e = iProvReadWXF[iProvIndexPath["effective.wxf"]];
  If[! (AssociationQ[g] && AssociationQ[l] && AssociationQ[b] && AssociationQ[e]), Return[False]];
  If[Lookup[g, "IndexSeq", -1] =!= expectedSeq || Lookup[l, "IndexSeq", -1] =!= expectedSeq ||
     Lookup[b, "IndexSeq", -1] =!= expectedSeq || Lookup[e, "IndexSeq", -1] =!= expectedSeq, Return[False]];
  iProvIndexReset[];
  $iProvEntities = Lookup[g, "Entities", <||>]; $iProvActivities = Lookup[g, "Activities", <||>];
  $iProvBlobs = Lookup[g, "Blobs", <||>]; $iProvBlobRecords = Lookup[g, "BlobRecords", <||>]; $iProvRefs = Lookup[g, "Refs", <||>];
  $iProvChainEvents = Lookup[g, "ChainEvents", {}];
  $iProvLineage = Lookup[g, "Lineage", <||>]; $iProvActRefs = Lookup[g, "ActRefs", <||>];
  If[! AssociationQ[$iProvLineage], $iProvLineage = <||>]; If[! AssociationQ[$iProvActRefs], $iProvActRefs = <||>];
  iProvLabelStateLoad[Lookup[g, "LabelRecords", <||>]];
  $iProvLogical = Lookup[l, "Logical", <||>]; $iProvLabels = Lookup[b, "Labels", <||>]; $iProvEffective = Lookup[e, "Effective", <||>];
  $iProvIndexSeq = expectedSeq; $iProvIndexLoaded = True; $iProvIndexDirty = False;
  True];

(* ============================================================
   台帳 (§4.8): 行の生成・解析・一括追記 (Ingested → Durable)・照合
   ============================================================ *)
iProvLedgerPath[monthTag_String] := With[{d = iProvLedgerDir[]}, If[d === $Failed, $Failed, FileNameJoin[{d, monthTag <> ".jsonl"}]]];
iProvLedgerFiles[] := With[{d = iProvLedgerDir[]}, If[d === $Failed, {}, Sort @ FileNames["*.jsonl", d]]];
iProvLineHash[seq_Integer, prev_String, recText_String] := "sha256:" <> iProvSHAHex[ToString[seq] <> "|" <> prev <> "|" <> recText];
iProvLedgerLineText[seq_Integer, prev_String, eid_String, recText_String] := Module[{lh, mac},
  lh = iProvLineHash[seq, prev, recText];
  mac = iProvMac["LedgerMac", StringToByteArray[lh, "UTF-8"]];
  If[mac === $Failed, Return[$Failed]];
  <|"Text" -> StringJoin["{\"Seq\":", ToString[seq], ",\"PrevHash\":\"", prev, "\",\"EventId\":\"", eid, "\",\"Record\":", recText,
      ",\"LineHash\":\"", lh, "\",\"Mac\":\"", mac["Mac"], "\"}"], "LineHash" -> lh|>];
$iProvLedgerLineRE = "^\\{\"Seq\":(\\d+),\"PrevHash\":\"(sha256:[0-9a-f]{64})\",\"EventId\":\"([A-Za-z0-9:_.-]+)\",\"Record\":(.*),\"LineHash\":\"(sha256:[0-9a-f]{64})\",\"Mac\":\"(hmac:[A-Za-z0-9_.-]+:[0-9a-f]{64})\"\\}$";
iProvParseLedgerLine[line_String] := Module[{m},
  m = StringCases[StringTrim[line], RegularExpression[$iProvLedgerLineRE] :> {"$1", "$2", "$3", "$4", "$5", "$6"}];
  If[m === {}, $Failed,
    <|"Seq" -> FromDigits[m[[1, 1]]], "PrevHash" -> m[[1, 2]], "EventId" -> m[[1, 3]], "RecordText" -> m[[1, 4]],
      "LineHash" -> m[[1, 5]], "Mac" -> m[[1, 6]]|>]];
(* 行頭 {"Seq":<n>, から n だけを取り出す (正規表現で行全体を解析しない) *)
iProvQuickSeq[line_String] := If[StringStartsQ[line, "{\"Seq\":"],
  With[{p = StringPosition[line, ",", 1]}, If[p === {}, $Failed, Quiet @ Check[FromDigits[StringTake[line, {8, p[[1, 1]] - 1}]], $Failed]]], $Failed];
iProvEventIdOKQ[eid_] := StringQ[eid] && StringMatchQ[eid, RegularExpression["^[A-Za-z0-9:_.-]{1,120}$"]];

(* items: {<|"EventId", "RecordText"|>..} を Seq 順に 1 回の BinaryWrite で追記し、開き直して末尾を確かめる (Durable)。
   返り値 <|"Status" -> "OK" | .., "Appended", "Meta", "Lines" -> {<|Seq, EventId, RecordText, LineHash|>..}|> *)
iProvAppendBatch[meta_Association, items_List] := Module[
  {m = meta, seq, prev, lines = {}, texts, path, name, strm, ok, bytesBefore, bytesAfter, tail, l, failed = False},
  If[items === {}, Return[<|"Status" -> "OK", "Appended" -> 0, "Meta" -> m, "Lines" -> {}|>]];
  path = iProvLedgerPath[iProvMonthTag[]];
  If[path === $Failed, Return[<|"Status" -> "LedgerUnavailable", "Appended" -> 0, "Meta" -> m, "Lines" -> {}|>]];
  name = FileNameTake[path];
  If[m["LedgerFile"] =!= name, m["LedgerFile"] = name; m["LedgerBytes"] = If[FileExistsQ[path], Quiet @ Check[FileByteCount[path], 0], 0]];
  seq = m["LastSeq"]; prev = m["LastLineHash"];
  Do[
    seq++;
    l = iProvLedgerLineText[seq, prev, it["EventId"], it["RecordText"]];
    If[l === $Failed, failed = True; Break[]];
    AppendTo[lines, <|"Seq" -> seq, "EventId" -> it["EventId"], "RecordText" -> it["RecordText"], "LineHash" -> l["LineHash"], "Text" -> l["Text"]|>];
    prev = l["LineHash"],
    {it, items}];
  If[failed, Return[<|"Status" -> "MacKeyUnavailable", "Appended" -> 0, "Meta" -> meta, "Lines" -> {}|>]];
  texts = StringJoin[(#["Text"] <> "\n") & /@ lines];
  bytesBefore = If[FileExistsQ[path], Quiet @ Check[FileByteCount[path], -1], 0];
  If[bytesBefore =!= m["LedgerBytes"],
    m["ChainState"] = "Damaged";
    m["ChainDamage"] = <|"Reason" -> "LedgerTailUnexpected", "Expected" -> m["LedgerBytes"], "Found" -> bytesBefore, "File" -> name, "AtUTC" -> iProvNowIso[]|>;
    Return[<|"Status" -> "LedgerTailUnexpected", "Appended" -> 0, "Meta" -> m, "Lines" -> {}|>]];
  (* Ingested *)
  strm = Quiet @ Check[OpenAppend[path, BinaryFormat -> True], $Failed];
  If[Head[strm] =!= OutputStream, Return[<|"Status" -> "LedgerUnwritable", "Appended" -> 0, "Meta" -> m, "Lines" -> {}|>]];
  ok = Quiet @ Check[(BinaryWrite[strm, StringToByteArray[texts, "UTF-8"]]; Close[strm]; True), (Quiet @ Close[strm]; False)];
  (* Durable: 閉じて開き直し、書いた区間がそのまま読めることを確かめる *)
  bytesAfter = Quiet @ Check[FileByteCount[path], -1];
  tail = If[bytesAfter > bytesBefore, iProvReadRange[path, bytesBefore, bytesAfter - bytesBefore], $Failed];
  If[! TrueQ[ok] || ! ByteArrayQ[tail] || Quiet @ Check[ByteArrayToString[tail, "UTF-8"], $Failed] =!= texts,
    m["ChainState"] = "Damaged";
    m["ChainDamage"] = <|"Reason" -> "DurableCheckFailed", "File" -> name, "Expected" -> bytesBefore, "Found" -> bytesAfter, "AtUTC" -> iProvNowIso[]|>;
    Return[<|"Status" -> "DurableCheckFailed", "Appended" -> 0, "Meta" -> m, "Lines" -> {}|>]];
  m["LastSeq"] = seq; m["LastLineHash"] = prev; m["DurableSeq"] = seq; m["LedgerBytes"] = bytesAfter;
  <|"Status" -> "OK", "Appended" -> Length[lines], "Meta" -> m, "Lines" -> lines|>];

(* 起動・tick の冒頭: meta の知らない末尾 (前回 ACK 前に落ちた) を受け入れる / 切り詰めを検知する *)
iProvReconcile[meta_Association] := Module[{m = meta, path, size, extra, text, lines, seq, prev, ok = True, p},
  If[! StringQ[m["LedgerFile"]], Return[m]];
  path = With[{d = iProvLedgerDir[]}, If[d === $Failed, $Failed, FileNameJoin[{d, m["LedgerFile"]}]]];
  If[path === $Failed, Return[m]];
  If[! FileExistsQ[path],
    If[m["LedgerBytes"] > 0, m["ChainState"] = "Damaged"; m["ChainDamage"] = <|"Reason" -> "LedgerFileMissing", "File" -> m["LedgerFile"], "AtUTC" -> iProvNowIso[]|>];
    Return[m]];
  size = Quiet @ Check[FileByteCount[path], 0];
  Which[
    size < m["LedgerBytes"],
      m["ChainState"] = "Damaged";
      m["ChainDamage"] = <|"Reason" -> "LedgerTruncated", "Expected" -> m["LedgerBytes"], "Found" -> size, "File" -> m["LedgerFile"], "AtUTC" -> iProvNowIso[]|>,
    size > m["LedgerBytes"],
      extra = iProvReadRange[path, m["LedgerBytes"], size - m["LedgerBytes"]];
      text = If[ByteArrayQ[extra], Quiet @ Check[ByteArrayToString[extra, "UTF-8"], $Failed], $Failed];
      If[! StringQ[text] || ! StringEndsQ[text, "\n"], ok = False,
        lines = Select[StringSplit[text, "\n"], StringTrim[#] =!= "" &];
        seq = m["LastSeq"]; prev = m["LastLineHash"];
        Do[
          p = iProvParseLedgerLine[ln];
          If[p === $Failed || p["Seq"] =!= seq + 1 || p["PrevHash"] =!= prev || iProvLineHash[p["Seq"], p["PrevHash"], p["RecordText"]] =!= p["LineHash"],
            ok = False; Break[]];
          seq = p["Seq"]; prev = p["LineHash"]; iProvSeenAdd[p["EventId"]],
          {ln, lines}]];
      If[ok,
        m["LastSeq"] = seq; m["LastLineHash"] = prev; m["DurableSeq"] = seq; m["LedgerBytes"] = size,
        m["ChainState"] = "Damaged";
        m["ChainDamage"] = <|"Reason" -> "LedgerTailUnexpected", "Expected" -> m["LedgerBytes"], "Found" -> size, "File" -> m["LedgerFile"], "AtUTC" -> iProvNowIso[]|>]];
  m];

(* 台帳の Seq 範囲 (from, to] を索引に適用する (再構築・復旧) *)
iProvReplayLedger[from_Integer, to_Integer] := Module[{files = iProvLedgerFiles[], n = 0, parsed, recs, sel},
  Do[
    parsed = Select[iProvParseLedgerLine /@ Replace[iProvReadLines[f], $Failed -> {}], AssociationQ];
    sel = Select[parsed, from < #["Seq"] <= to &];
    If[sel =!= {},
      recs = iProvParseJSONBatch[#["RecordText"] & /@ sel];
      MapThread[Function[{p, r}, If[AssociationQ[r], iProvIndexApply[p["Seq"], r]; n++]], {sel, recs}]],
    {f, files}];
  n];

(* 索引をメモリに用意する: WXF が meta と合えば読み、合わなければ台帳から作り直し、IndexSeq < DurableSeq なら差分を再生する *)
iProvIndexEnsure[meta_Association] := Module[{m = meta},
  If[! (TrueQ[$iProvIndexLoaded] && $iProvIndexSeq === m["IndexSeq"]),
    If[! iProvIndexLoadFiles[m["IndexSeq"]],
      iProvIndexReset[];
      If[m["DurableSeq"] > 0, iProvReplayLedger[0, m["DurableSeq"]]]]];
  If[$iProvIndexSeq < m["DurableSeq"], iProvReplayLedger[$iProvIndexSeq, m["DurableSeq"]]];
  m["IndexSeq"] = $iProvIndexSeq;
  m];
(* 読むだけ (FE の Resolve 等): 再生はしない *)
iProvIndexEnsureRead[] := Module[{m = iProvReadMeta[]},
  If[! AssociationQ[m], Return[False]];
  If[TrueQ[$iProvIndexLoaded] && $iProvIndexSeq === m["IndexSeq"], Return[True]];
  iProvIndexLoadFiles[m["IndexSeq"]]];

(* 検証済みの Record の列 ({<|"EventId", "RecordText"|>..}) を台帳に追記し、索引に適用し、seen に入れる *)
iProvAppendItems[meta_Association, items_List] := Module[{r, recs},
  r = iProvAppendBatch[meta, items];
  If[r["Status"] =!= "OK", Return[r]];
  recs = iProvParseJSONBatch[#["RecordText"] & /@ r["Lines"]];
  MapThread[Function[{l, rec}, If[AssociationQ[rec], iProvIndexApply[l["Seq"], rec]]; iProvSeenAdd[l["EventId"]]], {r["Lines"], recs}];
  r["Meta"] = Append[r["Meta"], "IndexSeq" -> $iProvIndexSeq];
  r];

(* ============================================================
   Ingest (§12.8): spool → 台帳
   ============================================================ *)
iProvCount[stats_Association, key_String, n_: 1] := Append[stats, key -> Lookup[stats, key, 0] + n];
iProvMetaCount[meta_Association, key_String, n_: 1] := Module[{m = meta},
  m["Counts", key] = Lookup[m["Counts"], key, 0] + n; m];

(* 1 つの Activity が参照する EntityId のうち索引にも batch にも無いもの *)
iProvUnresolvedRefs[rec_Association, batchIds_Association] := Module[{ids},
  ids = Select[Lookup[#, "EntityId", None] & /@ Select[Flatten[{Lookup[rec, "Inputs", {}], Lookup[rec, "Outputs", {}]}], AssociationQ], StringQ];
  Select[DeleteDuplicates[ids], ! KeyExistsQ[$iProvEntities, #] && ! KeyExistsQ[batchIds, #] &]];

(* 1 チャンクの spool 行を分類し、台帳に追記する。返り値 {meta, stats, consumedCount} (追記に失敗したら 0 行消費) *)
iProvIngestLines[rawLines_List, meta_Association, stats_Association] := Module[
  {m = meta, st = stats, parsed, items = {}, batchIds = <||>, batchBlobs = <||>, pendingNew = {}, r, ok = True},
  parsed = iProvParseJSONBatch[rawLines];
  MapThread[Function[{line, env}, Module[{eid, rec, type, recText, unresolved},
      Which[
        ! AssociationQ[env] || Lookup[env, "Type", ""] =!= "ProvenanceEvent" || ! AssociationQ[Lookup[env, "Record", None]],
          st = iProvCount[st, "Corrupt"]; m = iProvMetaCount[m, "Corrupt"],
        True,
          eid = Lookup[env, "EventId", None]; rec = env["Record"]; type = Lookup[rec, "Type", None];
          recText = iProvRecordTextOfLine[line];
          Which[
            ! iProvULIDQ[eid] || ! StringQ[recText],
              st = iProvCount[st, "Corrupt"]; m = iProvMetaCount[m, "Corrupt"],
            ! MemberQ[$iProvSpoolTypes, type],
              st = iProvCount[st, "Rejected"]; m = iProvMetaCount[m, "Rejected"],
            iProvSeenQ[eid],
              st = iProvCount[st, "Duplicates"]; m = iProvMetaCount[m, "Duplicates"],
            type === "ProvBlob",
              With[{bid = Lookup[rec, "BlobId", None]},
                Which[
                  ! iProvBlobIdQ[bid], st = iProvCount[st, "Corrupt"]; m = iProvMetaCount[m, "Corrupt"],
                  KeyExistsQ[$iProvBlobRecords, bid] || KeyExistsQ[batchBlobs, bid],
                    st = iProvCount[st, "BlobDuplicates"]; m = iProvMetaCount[m, "BlobDuplicates"]; iProvSeenAdd[eid],
                  True, batchBlobs[bid] = True; AppendTo[items, <|"EventId" -> eid, "RecordText" -> recText|>]; m = iProvMetaCount[m, "Blobs"]]],
            type === "ProvLLMCall",
              (* Inc2: LLMCall は台帳に直接入れず結合の待ち行列へ (SourceVaultProvJoinLLMCalls が LLMGenerate を作る)。spool 側は ACK *)
              If[! AssociationQ[rec] || ! StringQ[Lookup[rec, "Provider", None]],
                st = iProvCount[st, "Corrupt"]; m = iProvMetaCount[m, "Corrupt"],
                iProvLLMQueueEnsure[];
                AppendTo[$iProvLLMQueue, <|"EventId" -> eid, "Record" -> rec, "FirstSeenAbs" -> AbsoluteTime[]|>]; $iProvLLMQueueDirty = True;
                iProvSeenAdd[eid]; st = iProvCount[st, "LLMCallsQueued"]; m = iProvMetaCount[m, "LLMCallsQueued"]],
            type === "ProvGrounding",
              (* V9: 裏付けの結果も、回答の版ができるまで待ち行列で待つ。決まった鍵だけを残す (本文は元から入っていない) *)
              If[! AssociationQ[rec] || ! MemberQ[$iProvGroundingStatuses, Lookup[rec, "Status", None]],
                st = iProvCount[st, "Corrupt"]; m = iProvMetaCount[m, "Corrupt"],
                iProvGroundingQueueEnsure[];
                AppendTo[$iProvGroundingQueue, <|"EventId" -> eid, "Record" -> KeyTake[rec, $iProvGroundingKeys], "FirstSeenAbs" -> AbsoluteTime[]|>];
                $iProvGroundingQueueDirty = True;
                iProvSeenAdd[eid]; st = iProvCount[st, "GroundingQueued"]; m = iProvMetaCount[m, "GroundingQueued"]],
            (* Inc3: ラベルの記録。ID の重複だけをここで見る (ticket の照合は索引に入れるとき。照合に落ちても台帳には残し、効かせない) *)
            MemberQ[$iProvLabelRecordTypes, type],
              With[{lid = Lookup[rec, $iProvLabelIdKeys[type], None]},
                Which[
                  ! StringQ[lid] || lid === "" || StringLength[lid] > 120, st = iProvCount[st, "Corrupt"]; m = iProvMetaCount[m, "Corrupt"],
                  KeyExistsQ[$iProvLabelIds, type <> "|" <> lid] || KeyExistsQ[batchIds, type <> "|" <> lid],
                    st = iProvCount[st, "Duplicates"]; m = iProvMetaCount[m, "Duplicates"]; iProvSeenAdd[eid],
                  True, batchIds[type <> "|" <> lid] = True; AppendTo[items, <|"EventId" -> eid, "RecordText" -> recText|>];
                    st = iProvCount[st, "LabelRecords"]; m = iProvMetaCount[m, "LabelRecords"]]],
            type === "ProvEntity",
              With[{id = Lookup[rec, "EntityId", None]},
                Which[
                  ! iProvEntityIdQ[id] || ! (iProvBlobIdQ[Lookup[rec, "BlobId", None]] || Lookup[rec, "BlobId", None] === Null),
                    st = iProvCount[st, "Corrupt"]; m = iProvMetaCount[m, "Corrupt"],
                  KeyExistsQ[$iProvEntities, id] || KeyExistsQ[batchIds, id], st = iProvCount[st, "Duplicates"]; m = iProvMetaCount[m, "Duplicates"]; iProvSeenAdd[eid],
                  True, batchIds[id] = True; AppendTo[items, <|"EventId" -> eid, "RecordText" -> recText|>]; m = iProvMetaCount[m, "Entities"]]],
            type === "ProvActivity",
              With[{id = Lookup[rec, "ActivityId", None]},
                Which[
                  ! iProvActivityIdQ[id], st = iProvCount[st, "Corrupt"]; m = iProvMetaCount[m, "Corrupt"],
                  KeyExistsQ[$iProvActivities, id], st = iProvCount[st, "Duplicates"]; m = iProvMetaCount[m, "Duplicates"]; iProvSeenAdd[eid],
                  True,
                    unresolved = iProvUnresolvedRefs[rec, batchIds];
                    If[unresolved === {},
                      AppendTo[items, <|"EventId" -> eid, "RecordText" -> recText|>]; m = iProvMetaCount[m, "Activities"],
                      AppendTo[pendingNew, <|"EventId" -> eid, "RecordText" -> recText, "Unresolved" -> unresolved, "FirstSeenAbs" -> AbsoluteTime[]|>];
                      st = iProvCount[st, "PendingHeld"]]]]]]]],
    {rawLines, parsed}];
  r = iProvAppendItems[m, items];
  If[r["Status"] =!= "OK",
    (* 追記できない: この chunk は何も消費しない (次回やり直す)。ChainState は AppendBatch が立てている *)
    Return[{Join[meta, KeyTake[r["Meta"], {"ChainState", "ChainDamage"}]], stats, 0, r["Status"]}]];
  m = r["Meta"];
  st = iProvCount[st, "Ingested", r["Appended"]];
  If[pendingNew =!= {},
    iProvPendingEnsure[];
    $iProvPending = Join[$iProvPending, pendingNew]; $iProvPendingDirty = True;
    Scan[iProvSeenAdd[#["EventId"]] &, pendingNew]];
  {m, st, Length[rawLines], "OK"}];

(* 保留中の Activity: 参照先が揃えば追記、時間切れなら Completeness Partial で追記 *)
iProvFlushPending[meta_Association, stats_Association, deadline_] := Module[{m = meta, st = stats, keep = {}, items = {}, now = AbsoluteTime[], r, recs},
  iProvPendingEnsure[];
  If[$iProvPending === {}, Return[{m, st}]];
  recs = iProvParseJSONBatch[#["RecordText"] & /@ $iProvPending];
  MapThread[Function[{p, rec}, Module[{unresolved, rec2, text2},
      If[! AssociationQ[rec], Return[Null, Module]];   (* 読めない保留は捨てる *)
      unresolved = iProvUnresolvedRefs[rec, <||>];
      Which[
        unresolved === {},
          AppendTo[items, <|"EventId" -> p["EventId"], "RecordText" -> p["RecordText"]|>]; st = iProvCount[st, "PendingFlushed"],
        now - Lookup[p, "FirstSeenAbs", now] > $SourceVaultProvPendingTimeoutSeconds,
          rec2 = Join[rec, <|"Completeness" -> "Partial", "InputsCompleteness" -> "Partial",
            "UnrecordedInputs" -> DeleteDuplicates @ Join[Select[Flatten[{Lookup[rec, "UnrecordedInputs", {}]}], StringQ], {"UnresolvedEntityRefs"}],
            "UnresolvedRefs" -> unresolved|>];
          text2 = iProvCanonText[rec2];
          If[StringQ[text2],
            AppendTo[items, <|"EventId" -> p["EventId"], "RecordText" -> text2|>];
            st = iProvCount[st, "PendingFlushed"]; st = iProvCount[st, "PendingPartial"]; m = iProvMetaCount[m, "PendingPartial"]],
        True, AppendTo[keep, p]]]],
    {$iProvPending, recs}];
  If[items === {}, Return[{m, st}]];
  r = iProvAppendItems[m, items];
  If[r["Status"] =!= "OK", Return[{r["Meta"], st}]];   (* 追記できなければ保留はそのまま *)
  m = r["Meta"];
  m = iProvMetaCount[m, "Activities", r["Appended"]];
  st = iProvCount[st, "Ingested", r["Appended"]];
  $iProvPending = keep; $iProvPendingDirty = True;
  {m, st}];

(* 1 つの spool ファイルを読取位置から読み、完全な行を chunk ごとに取り込む。返り値 {meta, stats, carriedQ} *)
iProvIngestSpoolFile[f_String, meta_Association, stats_Association, deadline_, maxLines_] := Module[
  {m = meta, st = stats, name = FileNameTake[f], off, size, ba, bytes, nls, text, rawLines, consumed = 0, carried = False, chunk, n, status, k},
  off = Lookup[Lookup[m["SpoolOffsets"], name, <||>], "Offset", 0];
  If[! IntegerQ[off] || off < 0, off = 0];
  size = Quiet @ Check[FileByteCount[f], 0];
  If[off > size, off = 0];   (* 巻き戻り (回転・差し替え): 重複は seen が守る *)
  If[size <= off, m["SpoolOffsets", name] = <|"Offset" -> off, "Size" -> size|>; Return[{m, st, False}]];
  ba = iProvReadRange[f, off, size - off];
  If[! ByteArrayQ[ba], Return[{m, st, False}]];
  bytes = Normal[ba];
  nls = Flatten @ Position[bytes, 10];
  If[nls === {}, m["SpoolOffsets", name] = <|"Offset" -> off, "Size" -> size|>; Return[{m, st, False}]];   (* 改行の無い末尾だけ: 持ち越し *)
  text = Quiet @ Check[ByteArrayToString[ByteArray[bytes[[1 ;; Last[nls]]]], "UTF-8"], $Failed];
  If[StringQ[text],
    rawLines = StringSplit[text, "\n", All];
    If[rawLines =!= {} && Last[rawLines] === "", rawLines = Most[rawLines]],
    (* UTF-8 として読めない: 行ごとに復号し、読めない行は壊れた行として扱う *)
    rawLines = Module[{starts = Prepend[Most[nls] + 1, 1]},
      MapThread[Function[{a, b}, With[{t = Quiet @ Check[ByteArrayToString[ByteArray[bytes[[a ;; b - 1]]], "UTF-8"], $Failed]}, If[StringQ[t], t, "\[InvisibleSpace]corrupt"]]], {starts, nls}]]];
  If[Length[rawLines] =!= Length[nls], rawLines = PadRight[rawLines, Length[nls], "\[InvisibleSpace]corrupt"]];
  k = 0;
  While[k < Length[rawLines],
    If[AbsoluteTime[] > deadline || Lookup[st, "Ingested", 0] >= maxLines, carried = True; Break[]];
    chunk = rawLines[[k + 1 ;; Min[k + $iProvChunk, Length[rawLines]]]];
    {m, st, n, status} = iProvIngestLines[chunk, m, st];
    If[n === 0, carried = True; Break[]];
    k += n; consumed = k];
  m["SpoolOffsets", name] = <|"Offset" -> off + If[consumed > 0, nls[[consumed]], 0], "Size" -> size|>;
  st = iProvCount[st, "LinesRead", consumed];
  {m, st, carried}];

Options[SourceVaultProvIngestSpool] = {"BudgetSeconds" -> Automatic, "MaxLines" -> Infinity};
SourceVaultProvIngestSpool[OptionsPattern[]] := Module[
  {auth, t0 = AbsoluteTime[], budget, maxLines, meta, dir, files, stats, carried = False, deadline, r, today, dateTag, offRec, ks},
  auth = iProvAuth["SourceVaultProvIngestSpool", $iProvOwnerService];
  If[FailureQ[auth], Return[auth]];
  budget = OptionValue["BudgetSeconds"] /. Automatic -> $SourceVaultProvIngestBudgetSeconds;
  If[! NumberQ[budget], budget = $SourceVaultProvIngestBudgetSeconds];
  maxLines = OptionValue["MaxLines"]; If[! (NumberQ[maxLines] || maxLines === Infinity), maxLines = Infinity];
  deadline = t0 + budget;
  meta = iProvReadMeta[];
  If[meta === $Failed, Return[Failure["ProvLocalStateUnresolved", <|"MessageTemplate" -> "SourceVaultRoot[\"LocalState\"] is not resolved; the ledger has no home."|>]]];
  If[! iProvLedgerKeyAvailableQ[],
    ks = iProvKeySpec["LedgerMac"];
    Return[Failure["ProvMacKeyUnavailable", <|"KeyRef" -> If[AssociationQ[ks], ks["KeyRef"], Null], "Profile" -> iProvProfile[],
      "MessageTemplate" -> "The ledger MAC key is not available (NBAccess_crypto NBMacWithKeyRef / key index); nothing was ingested and the spool is untouched."|>]]];
  meta = iProvReconcile[meta];
  If[meta["ChainState"] =!= "OK",
    iProvWriteMeta[meta];
    Return[Failure["ProvChainDamaged", Join[KeyTake[meta, {"ChainState", "ChainDamage", "LastSeq", "DurableSeq"}],
      <|"MessageTemplate" -> "The ledger chain is damaged; ingest is stopped until SourceVaultProvChainRestart (owner ticket)."|>]]]];
  meta = iProvIndexEnsure[meta];
  iProvSeenEnsure[]; iProvPendingEnsure[];
  stats = <|"Ingested" -> 0, "Corrupt" -> 0, "Duplicates" -> 0, "BlobDuplicates" -> 0, "Rejected" -> 0, "PendingHeld" -> 0,
    "PendingFlushed" -> 0, "PendingPartial" -> 0, "Files" -> 0, "Pruned" -> 0, "LinesRead" -> 0, "LLMCallsQueued" -> 0|>;
  {meta, stats} = iProvFlushPending[meta, stats, deadline];
  dir = iProvSpoolDir[];
  files = If[DirectoryQ[dir], Sort @ FileNames["*.jsonl", dir], {}];
  stats["Files"] = Length[files];
  Do[
    If[meta["ChainState"] =!= "OK", carried = True; Break[]];
    If[AbsoluteTime[] > deadline, carried = True; Break[]];
    {meta, stats, r} = iProvIngestSpoolFile[f, meta, stats, deadline, maxLines];
    If[TrueQ[r], carried = True; Break[]],
    {f, files}];
  (* ACK 済みの過去日のファイルを削除 (producer が今日も書いているファイルは残す) *)
  today = iProvDateTag[];
  Do[
    offRec = Lookup[meta["SpoolOffsets"], FileNameTake[f], None];
    dateTag = Last[StringCases[FileBaseName[f], RegularExpression["-(\\d{8})(?:-\\d+)?$"] -> "$1"], ""];
    If[AssociationQ[offRec] && dateTag =!= "" && dateTag =!= today && FileExistsQ[f] &&
        offRec["Offset"] >= Quiet @ Check[FileByteCount[f], -1],
      Quiet @ DeleteFile[f];
      If[! FileExistsQ[f], meta["SpoolOffsets"] = KeyDrop[meta["SpoolOffsets"], FileNameTake[f]]; stats = iProvCount[stats, "Pruned"]]],
    {f, files}];
  meta["CarryOver"] = carried; meta["LastIngestAtUTC"] = iProvNowIso[]; meta["PendingCount"] = Length[$iProvPending];
  meta["IndexSeq"] = $iProvIndexSeq;
  meta["LLMQueueCount"] = If[ListQ[$iProvLLMQueue], Length[$iProvLLMQueue], 0];
  iProvSeenSave[]; iProvPendingSave[]; iProvLLMQueueSave[];
  (* Inc5: 予算で持ち越した点数の種が残っていれば、新しい行が無くても続きを計算して保存する (Stale を残さない) *)
  If[TrueQ[$iProvIndexDirty] || ! FileExistsQ[iProvIndexPath["usability.wxf"]] || (ListQ[$iProvScoreSeeds] && $iProvScoreSeeds =!= {}), iProvIndexSave[meta]];
  iProvWriteMeta[meta];
  $iProvMetaCache = <||>;
  If[meta["ChainState"] =!= "OK",
    Return[Failure["ProvChainDamaged", Join[KeyTake[meta, {"ChainState", "ChainDamage", "LastSeq", "DurableSeq"}], stats]]]];
  Join[<|"Status" -> If[carried, "CarriedOver", "OK"]|>, stats,
    <|"LastSeq" -> meta["LastSeq"], "DurableSeq" -> meta["DurableSeq"], "IndexSeq" -> meta["IndexSeq"], "Pending" -> Length[$iProvPending],
      "Seconds" -> AbsoluteTime[] - t0|>]];

(* ============================================================
   adapter (§6.3): 既存ログ → Activity。offset は meta の AdapterOffsets、EventId は行の digest から決定的に
   ============================================================ *)
If[! AssociationQ[$iProvAdapters], $iProvAdapters = <||>];
SourceVaultProvRegisterAdapter[name_String, spec_Association] := (
  $iProvAdapters[name] = Join[<|"MaxLinesPerTick" -> 2000|>, spec]; name);
SourceVaultProvRegisterAdapter[___] := $Failed;
iProvHotlogFiles[sub_String] := With[{ls = iProvLocalState[]},
  If[ls === $Failed, {}, With[{d = FileNameJoin[{ls, "hotlog", sub}]}, If[DirectoryQ[d], Sort @ FileNames["*.jsonl", d], {}]]]];
iProvAdapterEventId[name_String, file_String, line_String, suffix_String] :=
  "adp-" <> iProvSafeName[name] <> "-" <> StringTake[iProvSHAHex[FileNameTake[file] <> "|" <> StringTrim[line]], 32] <> "-" <> suffix;
iProvAdapterActor[kind_String, principal_String] := <|"Kind" -> kind, "Principal" -> principal, "Channel" -> "Adapter",
  "Provider" -> Null, "ModelRef" -> Null, "IdentityEvidence" -> "Unknown", "OnBehalfOf" -> "Owner", "DeterminedBy" -> "Adapter"|>;
iProvStr[x_] := If[StringQ[x], x, Null];
iProvSvRefs[l_] := Select[Flatten[{l}], StringQ[#] && StringStartsQ[#, "sv://"] &];
iProvAdapterBase[name_String, kind_String, actor_Association, started_, ended_, outcome_] := <|
  "Type" -> "ProvActivity", "SchemaVersion" -> 2, "ActivityId" -> "act-" <> iProvULID[], "Kind" -> kind,
  "StartedAtUTC" -> If[StringQ[started], started, iProvNowIso[]], "EndedAtUTC" -> If[StringQ[ended], ended, If[StringQ[started], started, iProvNowIso[]]],
  "Outcome" -> If[StringQ[outcome], outcome, "Unknown"], "Actor" -> actor, "Inputs" -> {}, "InputsCompleteness" -> "Unknown",
  "UnrecordedInputs" -> {}, "Outputs" -> {}, "PromptDigest" -> Null, "ToolCalls" -> {}, "PolicyDigest" -> Null,
  "LineageId" -> Null, "LineageSource" -> Null, "ExternalRefs" -> <||>, "Claimed" -> <|"Actor" -> Null, "ClaimedClient" -> Null|>,
  "Completeness" -> "Partial", "Adapter" -> name, "Machine" -> iProvMachine[], "Producer" -> "adapter:" <> name, "Pid" -> $ProcessID|>;

(* mcp_calls: SourceVaultRecordMCPCall の出力 (CallId / Tool / Decision / Argument URIs ..) → Execute。
   Inc2 (2026-11-10): SourceVaultMCPCallTool の記録点 (SourceVaultProvRecordToolCall、ExternalRefs CallId) が同じ呼び出しを先に台帳に
   入れていれば、この adapter は補完専用 (無い分だけ) になる: 索引の ActRefs に "CallId:<id>" があれば何も作らない *)
iProvAdapterMCPCalls[rec_Association] := If[! StringQ[Lookup[rec, "CallId", None]] ||
    (AssociationQ[$iProvActRefs] && KeyExistsQ[$iProvActRefs, "CallId:" <> rec["CallId"]]), {},
  {Join[iProvAdapterBase["mcp_calls", "Execute", iProvAdapterActor["MCPClient", "MCP"], Lookup[rec, "StartedAtUTC", Null], Lookup[rec, "FinishedAtUTC", Null],
      If[Lookup[rec, "Decision", "Permit"] === "Denied", "Denied", "Succeeded"]],
    <|"UnrecordedInputs" -> {"ToolArguments", "ToolResult"},
      "ToolCalls" -> {<|"Name" -> ToString @ Lookup[rec, "Tool", "unknown"], "ArgsDigest" -> Null,
        "Decision" -> iProvStr[Lookup[rec, "Decision", Null]], "DecisionRef" -> iProvStr[Lookup[rec, "AccessGrantId", Null]]|>},
      "ArgumentRefs" -> iProvSvRefs[Lookup[rec, "ArgumentURIs", {}]], "ReleasedRefs" -> iProvSvRefs[Lookup[rec, "ReleasedURIs", {}]],
      "MaxReleasedPrivacy" -> With[{p = Lookup[rec, "MaxReleasedPrivacy", Null]}, If[NumericQ[p], N[p], Null]],
      "Reason" -> iProvStr[Lookup[rec, "Reason", Null]],
      "LineageId" -> iProvStr[Lookup[rec, "SessionId", Null]], "LineageSource" -> If[StringQ[Lookup[rec, "SessionId", None]], "SessionId", Null],
      "ExternalRefs" -> DeleteCases[<|"CallId" -> iProvStr[rec["CallId"]], "BatchId" -> iProvStr[Lookup[rec, "BatchId", Null]],
        "JobId" -> iProvStr[Lookup[rec, "JobId", Null]], "SessionId" -> iProvStr[Lookup[rec, "SessionId", Null]]|>, Null]|>]}];
(* web_access: webguard のアクセスログ → Execute (ToolCalls に Decision、Host は鍵付き digest、Url / Query は入れない) *)
iProvAdapterWebAccess[rec_Association] := If[! StringQ[Lookup[rec, "EventId", None]], {},
  Module[{kind = ToString @ Lookup[rec, "Kind", "Fetch"], actorKind, principal, host},
    principal = iProvStr[Lookup[rec, "Principal", Null]];
    actorKind = Switch[Lookup[rec, "ActorKind", ""], "Owner", "Owner", "Model", "Model", "MCPClient" | "MCP", "MCPClient", "Service", "Service", _,
      Switch[principal, "OwnerFE" | "OwnerCode", "Owner", "Service", "Service", "MCP", "MCPClient", _, "Model"]];
    host = Lookup[rec, "Host", Null];
    {Join[iProvAdapterBase["web_access", "Execute", iProvAdapterActor[actorKind, If[StringQ[principal], principal, "Unknown"]],
        Lookup[rec, "At", Null], Lookup[rec, "At", Null], iProvStr[Lookup[rec, "Decision", Null]]],
      <|"UnrecordedInputs" -> {"Url", "Query", "Response"},
        "ToolCalls" -> {<|"Name" -> "web_" <> ToLowerCase[kind], "ArgsDigest" -> If[StringQ[host] && host =!= "", iProvDigestOrNull["ExternalRef", host], Null],
          "Decision" -> iProvStr[Lookup[rec, "Decision", Null]], "DecisionRef" -> iProvStr[Lookup[rec, "RequestId", Null]]|>},
        "DecisionBy" -> iProvStr[Lookup[rec, "DecisionBy", Null]], "DecisionReason" -> iProvStr[Lookup[rec, "DecisionReason", Null]],
        "ContextPL" -> With[{p = Lookup[rec, "ContextPL", Null]}, If[NumericQ[p], N[p], Null]], "Channel" -> iProvStr[Lookup[rec, "Channel", Null]],
        "LineageId" -> iProvStr[Lookup[rec, "SessionId", Null]], "LineageSource" -> If[StringQ[Lookup[rec, "SessionId", None]], "SessionId", Null],
        "ExternalRefs" -> DeleteCases[<|"LogEventId" -> rec["EventId"], "HostIdentifierId" -> iProvStr[Lookup[rec, "HostIdentifierId", Null]],
          "RequestId" -> iProvStr[Lookup[rec, "RequestId", Null]], "SessionId" -> iProvStr[Lookup[rec, "SessionId", Null]]|>, Null]|>]}]];
(* reference_events: recordId / recordClass / eventType / channel → Transform 等 (query は入れない) *)
iProvAdapterReferenceEvents[rec_Association] := Module[{et = ToString @ Lookup[rec, "eventType", Lookup[rec, "EventType", "Unknown"]], kind, rid},
  rid = Lookup[rec, "recordId", Lookup[rec, "RecordId", Null]];
  If[! StringQ[rid], Return[{}]];
  kind = Switch[et, "Ingested" | "Fetched", "Ingest", "Searched" | "Served" | "Opened", "Execute", "Deposited" | "Summarized", "LLMGenerate", _, "Transform"];
  {Join[iProvAdapterBase["reference_events", kind, iProvAdapterActor["Service", "Unknown"], Lookup[rec, "At", Null], Lookup[rec, "At", Null], "Succeeded"],
    <|"UnrecordedInputs" -> {"Query", "Inputs"}, "EventType" -> et, "Channel" -> iProvStr[Lookup[rec, "channel", Lookup[rec, "Channel", Null]]],
      "Weight" -> With[{w = Lookup[rec, "Weight", Null]}, If[NumericQ[w], N[w], Null]],
      "ExternalRefs" -> DeleteCases[<|"RecordId" -> rid, "RecordClass" -> iProvStr[Lookup[rec, "recordClass", Lookup[rec, "RecordClass", Null]]],
        "LogEventId" -> iProvStr[Lookup[rec, "EventId", Null]]|>, Null]|>]}];
(* mcp_deposits: deposit の監査行 → LLMGenerate + 出力の Entity (ContentSHA256 = 生バイトの sha256 = CanonVersion 1 の Bytes) *)
iProvAdapterMCPDeposits[rec_Association] := Module[{uri = Lookup[rec, "ArtifactUri", None], sha = Lookup[rec, "ContentSHA256", None], pl, bid, act, ent, blob, eid, aid},
  If[! StringQ[uri], Return[{}]];
  pl = With[{p = Lookup[rec, "PrivacyLevel", Null]}, If[NumericQ[p], N[p], 0.85]];
  bid = If[StringQ[sha] && StringMatchQ[sha, RegularExpression["^[0-9a-fA-F]{64}$"]], "blob:sha256:" <> ToLowerCase[sha], None];
  aid = "act-" <> iProvULID[];
  act = Join[iProvAdapterBase["mcp_deposits", "LLMGenerate", iProvAdapterActor["MCPClient", "MCP"], Lookup[rec, "CreatedAtUTC", Null], Lookup[rec, "CreatedAtUTC", Null], "Succeeded"],
    <|"ActivityId" -> aid, "UnrecordedInputs" -> {"SourceRefs", "Prompt", "ModelRef"},
      "LineageId" -> iProvStr[Lookup[rec, "SessionId", Null]], "LineageSource" -> If[StringQ[Lookup[rec, "SessionId", None]], "SessionId", Null],
      "ExternalRefs" -> DeleteCases[<|"ArtifactUri" -> uri, "DerivedArtifactRef" -> iProvStr[Lookup[rec, "DerivedArtifactRef", Null]],
        "SessionId" -> iProvStr[Lookup[rec, "SessionId", Null]], "BatchId" -> iProvStr[Lookup[rec, "BatchId", Null]]|>, Null]|>];
  If[bid === None, Return[{act}]];
  eid = "ent-" <> iProvULID[];
  act["Outputs"] = {<|"EntityId" -> eid, "Role" -> "Primary"|>};
  blob = <|"Type" -> "ProvBlob", "BlobId" -> bid, "CanonVersion" -> 1, "Size" -> With[{b = Lookup[rec, "Bytes", Null]}, If[IntegerQ[b], b, Null]],
    "FirstSeenUTC" -> With[{c = Lookup[rec, "CreatedAtUTC", Null]}, If[StringQ[c], c, iProvNowIso[]]]|>;
  ent = <|"Type" -> "ProvEntity", "SchemaVersion" -> 2, "EntityId" -> eid, "BlobId" -> bid, "CanonVersion" -> 1,
    "LogicalRef" -> uri, "LogicalRefValid" -> True, "VersionOf" -> Null,
    "Refs" -> DeleteCases[<|"ArtifactUri" -> uri, "DerivedArtifactRef" -> iProvStr[Lookup[rec, "DerivedArtifactRef", Null]]|>, Null],
    "Kind" -> "DerivedText", "Media" -> Null, "Context" -> <|"Channel" -> "MCPDeposit"|>, "PrivacyLevel" -> pl,
    "Origin" -> iProvNormalizeOrigin[<|"Contributors" -> {"Model"}, "Taints" -> {"model:unknown", "prov:incomplete"}|>],
    "ProducedBy" -> {aid}, "Completeness" -> "Partial", "CreatedAtUTC" -> blob["FirstSeenUTC"], "Machine" -> iProvMachine[], "Producer" -> "adapter:mcp_deposits"|>;
  {blob, ent, act}];

SourceVaultProvRegisterAdapter["mcp_calls", <|"Files" -> (iProvHotlogFiles["mcp_calls"] &), "Parse" -> iProvAdapterMCPCalls|>];
SourceVaultProvRegisterAdapter["web_access", <|"Files" -> (iProvHotlogFiles["web_access"] &), "Parse" -> iProvAdapterWebAccess|>];
SourceVaultProvRegisterAdapter["reference_events", <|"Files" -> (iProvHotlogFiles["reference_events"] &), "Parse" -> iProvAdapterReferenceEvents|>];
SourceVaultProvRegisterAdapter["mcp_deposits", <|"Files" -> (iProvHotlogFiles["mcp_deposits"] &), "Parse" -> iProvAdapterMCPDeposits|>];

(* 1 adapter の 1 ファイル: 完全な行だけを読み、Record の列にして追記する。返り値 {meta, appended, carriedQ} *)
iProvAdapterIngestFile[name_String, spec_Association, f_String, meta_Association, deadline_, maxLines_] := Module[
  {m = meta, key = FileNameTake[f], off, size, ba, bytes, nls, text, rawLines, parsed, items = {}, appended = 0, consumed = 0, carried = False, r, suffixes},
  off = Lookup[Lookup[Lookup[m["AdapterOffsets"], name, <||>], key, <||>], "Offset", 0];
  If[! IntegerQ[off] || off < 0, off = 0];
  size = Quiet @ Check[FileByteCount[f], 0];
  If[off > size, off = 0];
  If[size <= off, Return[{m, 0, False}]];
  ba = iProvReadRange[f, off, size - off];
  If[! ByteArrayQ[ba], Return[{m, 0, False}]];
  bytes = Normal[ba]; nls = Flatten @ Position[bytes, 10];
  If[nls === {}, Return[{m, 0, False}]];
  text = Quiet @ Check[ByteArrayToString[ByteArray[bytes[[1 ;; Last[nls]]]], "UTF-8"], $Failed];
  If[! StringQ[text], Return[{m, 0, False}]];
  rawLines = StringSplit[text, "\n", All];
  If[rawLines =!= {} && Last[rawLines] === "", rawLines = Most[rawLines]];
  If[Length[rawLines] > maxLines, rawLines = Take[rawLines, maxLines]; carried = True];
  parsed = iProvParseJSONBatch[rawLines];
  suffixes = {"a", "b", "c", "d", "e", "f", "g", "h"};
  MapThread[Function[{line, rec}, If[AssociationQ[rec] && StringTrim[line] =!= "",
      Module[{recs = Quiet @ Check[spec["Parse"][rec], {}]},
        If[ListQ[recs],
          MapIndexed[Function[{rr, i}, With[{eid = iProvAdapterEventId[name, f, line, suffixes[[Min[First[i], 8]]]], t = iProvCanonText[rr]},
              If[AssociationQ[rr] && StringQ[t] && ! iProvSeenQ[eid], AppendTo[items, <|"EventId" -> eid, "RecordText" -> t|>]]]],
            Select[recs, AssociationQ]]]]]],
    {rawLines, parsed}];
  consumed = Length[rawLines];
  r = iProvAppendItems[m, items];
  If[r["Status"] =!= "OK", Return[{r["Meta"], 0, True}]];
  m = r["Meta"]; appended = r["Appended"];
  m = iProvMetaCount[m, "Adapter", appended];
  m["AdapterOffsets", name] = Append[Lookup[m["AdapterOffsets"], name, <||>], key -> <|"Offset" -> off + nls[[consumed]], "Size" -> size|>];
  {m, appended, carried}];

Options[SourceVaultProvIngestAdapters] = {"BudgetSeconds" -> 10, "Adapters" -> All};
SourceVaultProvIngestAdapters[OptionsPattern[]] := Module[{auth, t0 = AbsoluteTime[], deadline, meta, names, by = <||>, total = 0, carried = False, r},
  auth = iProvAuth["SourceVaultProvIngestAdapters", $iProvOwnerService];
  If[FailureQ[auth], Return[auth]];
  deadline = t0 + If[NumberQ[OptionValue["BudgetSeconds"]], OptionValue["BudgetSeconds"], 10];
  meta = iProvReadMeta[];
  If[meta === $Failed, Return[Failure["ProvLocalStateUnresolved", <||>]]];
  If[! iProvLedgerKeyAvailableQ[], Return[Failure["ProvMacKeyUnavailable", <||>]]];
  meta = iProvReconcile[meta];
  If[meta["ChainState"] =!= "OK", iProvWriteMeta[meta]; Return[Failure["ProvChainDamaged", KeyTake[meta, {"ChainState", "ChainDamage"}]]]];
  meta = iProvIndexEnsure[meta]; iProvSeenEnsure[];
  names = With[{a = OptionValue["Adapters"]}, If[ListQ[a], Select[a, KeyExistsQ[$iProvAdapters, #] &], Keys[$iProvAdapters]]];
  Do[
    by[nm] = 0;
    Do[
      If[AbsoluteTime[] > deadline || meta["ChainState"] =!= "OK", carried = True; Break[]];
      r = iProvAdapterIngestFile[nm, $iProvAdapters[nm], f, meta, deadline, Lookup[$iProvAdapters[nm], "MaxLinesPerTick", 2000]];
      meta = r[[1]]; by[nm] += r[[2]]; total += r[[2]]; If[TrueQ[r[[3]]], carried = True],
      {f, Quiet @ Check[$iProvAdapters[nm]["Files"][], {}]}],
    {nm, names}];
  meta["IndexSeq"] = $iProvIndexSeq;
  iProvSeenSave[];
  If[TrueQ[$iProvIndexDirty], iProvIndexSave[meta]];
  iProvWriteMeta[meta]; $iProvMetaCache = <||>;
  If[meta["ChainState"] =!= "OK", Return[Failure["ProvChainDamaged", KeyTake[meta, {"ChainState", "ChainDamage"}]]]];
  <|"Status" -> If[carried, "CarriedOver", "OK"], "Adapter" -> total, "ByAdapter" -> by, "LastSeq" -> meta["LastSeq"], "Seconds" -> AbsoluteTime[] - t0|>];

(* ============================================================
   検証 (§4.8 / T-P3)・再構築 (T-P5)・checkpoint・連鎖の再開・鍵の更新
   ============================================================ *)
iProvCheckpointFiles[] := With[{d = iProvCheckpointDir[]}, If[d === $Failed, {}, Sort @ FileNames["*.json", d]]];
iProvCheckpointCanon[cp_Association] := iProvCanonText[KeyDrop[cp, "Mac"]];

Options[SourceVaultProvVerifyLedger] = {"Since" -> Automatic, "MaxLines" -> Infinity, "Checkpoints" -> True, "Feeds" -> Automatic};
SourceVaultProvVerifyLedger[OptionsPattern[]] := Module[
  {auth, t0 = AbsoluteTime[], meta, files, findings = {}, seq = 0, prev = $iProvGenesisHash, n = 0, first = None, last = None,
   macChecked = 0, keyUnavailable = 0, since = OptionValue["Since"], maxLines = OptionValue["MaxLines"], started = False,
   cps = {}, cpNames = {}, cpSeqs, hashes = <||>, seqHash = <||>, p, recomputed, mv, rec, li, add, status, gaps = {}, inGapQ, gapQ,
   merkleChecked = 0, feedsQ, ownFeed = <|"Findings" -> {}, "Count" -> 0|>, wit = <|"Findings" -> {}, "Count" -> 0|>, endSeq},
  auth = iProvAuth["SourceVaultProvVerifyLedger", $iProvOwnerService];
  If[FailureQ[auth], Return[auth]];
  meta = iProvReadMeta[];
  files = iProvLedgerFiles[];
  If[StringQ[since], files = Select[files, FileBaseName[#] >= StringTake[since, UpTo[7]] &]];
  add = Function[{kind, s, f, l, detail}, AppendTo[findings, <|"Kind" -> kind, "Seq" -> s, "File" -> FileNameTake[f], "Line" -> l, "Detail" -> detail|>]];
  If[TrueQ[OptionValue["Checkpoints"]],
    With[{pairs = Select[{FileNameTake[#], iProvReadJSON[#]} & /@ iProvCheckpointFiles[],
        AssociationQ[#[[2]]] && Lookup[#[[2]], "Format", ""] === "SourceVaultProvCheckpoint/1" &]},
      cps = pairs[[All, 2]]; cpNames = pairs[[All, 1]]]];
  cpSeqs = Select[Lookup[#, "LastSeq", None] & /@ cps, IntegerQ];
  Do[
    li = 0;
    Do[
      li++;
      If[n >= maxLines, Break[]];
      (* Inc2 (2026-11-10): Since が Seq のとき、その 2 行以上手前は行頭の Seq だけ読んで飛ばす (検証器が毎時「前回の checkpoint 以降」だけを見るため) *)
      If[IntegerQ[since] && With[{qs = iProvQuickSeq[ln]}, IntegerQ[qs] && qs < since - 1], Continue[]];
      p = iProvParseLedgerLine[ln];
      If[p === $Failed, add["Corrupt", Null, f, li, <|"Length" -> StringLength[ln]|>]; Continue[]];
      If[IntegerQ[since] && p["Seq"] < since, seq = p["Seq"]; prev = p["LineHash"]; Continue[]];
      If[! started, started = True; first = p["Seq"];
        If[(IntegerQ[since] || StringQ[since]) && p["Seq"] > 1, seq = p["Seq"] - 1; prev = p["PrevHash"]]];
      If[p["Seq"] =!= seq + 1,
        rec = iProvParseJSON[p["RecordText"]];
        If[AssociationQ[rec] && Lookup[rec, "Type", ""] === "ProvChainRestart",
          add["ChainRestart", p["Seq"], f, li, KeyTake[rec, {"PreviousChain", "Gap", "DetectedBy", "AtUTC"}]];
          With[{g = Lookup[rec, "Gap", <||>]}, If[AssociationQ[g] && IntegerQ[Lookup[g, "FromSeq", None]] && IntegerQ[Lookup[g, "ToSeq", None]],
            AppendTo[gaps, {g["FromSeq"], g["ToSeq"]}]]];
          seq = p["Seq"] - 1; prev = p["PrevHash"],
          add[If[p["Seq"] > seq + 1, "SeqGap", "SeqReorder"], p["Seq"], f, li, <|"Expected" -> seq + 1, "Found" -> p["Seq"]|>]]];
      If[p["PrevHash"] =!= prev && p["Seq"] === seq + 1,
        rec = iProvParseJSON[p["RecordText"]];
        If[AssociationQ[rec] && Lookup[rec, "Type", ""] === "ProvChainRestart",
          add["ChainRestart", p["Seq"], f, li, KeyTake[rec, {"PreviousChain", "Gap", "DetectedBy", "AtUTC"}]];
          With[{g = Lookup[rec, "Gap", <||>]}, If[AssociationQ[g] && IntegerQ[Lookup[g, "FromSeq", None]] && IntegerQ[Lookup[g, "ToSeq", None]],
            AppendTo[gaps, {g["FromSeq"], g["ToSeq"]}]]],
          add["ChainBreak", p["Seq"], f, li, <|"Expected" -> prev, "Found" -> p["PrevHash"]|>]]];
      recomputed = iProvLineHash[p["Seq"], p["PrevHash"], p["RecordText"]];
      If[recomputed =!= p["LineHash"], add["LineHashMismatch", p["Seq"], f, li, <|"Expected" -> recomputed, "Found" -> p["LineHash"]|>]];
      mv = iProvVerifyMac[p["Mac"], StringToByteArray[p["LineHash"], "UTF-8"]];
      Switch[mv, "OK", macChecked++, "KeyUnavailable", keyUnavailable++, _, add["MacMismatch", p["Seq"], f, li, <|"Result" -> mv|>]];
      If[MemberQ[cpSeqs, p["Seq"]], hashes[p["Seq"]] = p["LineHash"]];
      seqHash[p["Seq"]] = p["LineHash"];   (* Inc1b: Merkle 根の再計算用 *)
      seq = p["Seq"]; prev = p["LineHash"]; n++; last = seq,
      {ln, Replace[iProvReadLines[f], $Failed -> {}]}],
    {f, files}];
  (* checkpoint: Mac と、その LastSeq の行の LineHash *)
  Do[
    mv = iProvVerifyMac[ToString @ Lookup[cp, "Mac", ""], StringToByteArray[iProvCheckpointCanon[cp], "UTF-8"]];
    Which[
      mv === "KeyUnavailable", keyUnavailable++,
      mv =!= "OK", add["CheckpointMacMismatch", Lookup[cp, "LastSeq", Null], "checkpoints/" <> ToString[Lookup[cp, "Date", ""]], Null, <|"Result" -> mv|>],
      True, macChecked++];
    inGapQ = IntegerQ[Lookup[cp, "LastSeq", None]] && AnyTrue[gaps, #[[1]] <= cp["LastSeq"] <= #[[2]] &];
    If[IntegerQ[Lookup[cp, "LastSeq", None]] && (since === Automatic || (IntegerQ[since] && cp["LastSeq"] >= since)),
      Which[
        inGapQ && (! KeyExistsQ[hashes, cp["LastSeq"]] || hashes[cp["LastSeq"]] =!= Lookup[cp, "LastLineHash", None]),
          add["CheckpointSuperseded", cp["LastSeq"], "checkpoints/" <> ToString[Lookup[cp, "Date", ""]], Null,
            <|"Reason" -> "InsideChainRestartGap", "Gaps" -> gaps|>],
        ! KeyExistsQ[hashes, cp["LastSeq"]], add["CheckpointMismatch", cp["LastSeq"], "checkpoints/" <> ToString[Lookup[cp, "Date", ""]], Null, <|"Reason" -> "LineMissing"|>],
        hashes[cp["LastSeq"]] =!= Lookup[cp, "LastLineHash", None], add["CheckpointMismatch", cp["LastSeq"], "checkpoints/" <> ToString[Lookup[cp, "Date", ""]], Null,
          <|"Expected" -> Lookup[cp, "LastLineHash", Null], "Found" -> hashes[cp["LastSeq"]]|>]]],
    {cp, cps}];
  (* meta は独立した証人ではないが、末尾の切り詰めの手がかりにはなる *)
  If[AssociationQ[meta] && since === Automatic && IntegerQ[last] && meta["DurableSeq"] > last,
    add["TailTruncated", last, "index-meta.json", Null, <|"DurableSeq" -> meta["DurableSeq"], "LastFound" -> last, "Witness" -> "index-meta.json (not independent)"|>]];
  If[AssociationQ[meta] && since === Automatic && last === None && meta["DurableSeq"] > 0,
    add["TailTruncated", 0, "index-meta.json", Null, <|"DurableSeq" -> meta["DurableSeq"], "LastFound" -> 0, "Witness" -> "index-meta.json (not independent)"|>]];
  (* Inc1b: checkpoint の Merkle 根を台帳から計算し直す (区間の全行を読んだときだけ。連鎖の再開の欠落区間に入る checkpoint は情報扱いなので除く) *)
  gapQ = Function[s, IntegerQ[s] && AnyTrue[gaps, #[[1]] <= s <= #[[2]] &]];
  Do[With[{cp = cps[[i]]},
      If[StringQ[Lookup[cp, "MerkleRoot", None]] && IntegerQ[Lookup[cp, "FirstSeq", None]] && IntegerQ[Lookup[cp, "LastSeq", None]] &&
          IntegerQ[first] && cp["FirstSeq"] >= first && ! gapQ[cp["LastSeq"]],
        merkleChecked++;
        If[iProvMerkleOf[seqHash, cp["FirstSeq"], cp["LastSeq"]] =!= cp["MerkleRoot"],
          add["CheckpointMerkleMismatch", cp["LastSeq"], "checkpoints/" <> cpNames[[i]], Null, <|"FirstSeq" -> cp["FirstSeq"]|>]]]],
    {i, Length[cps]}];
  (* Inc1b: feeds の写し・他機の証言との照合 (feeds があれば) *)
  feedsQ = Switch[OptionValue["Feeds"], True, True, False, False, _, With[{r = iProvFeedsRoot[]}, StringQ[r] && DirectoryQ[r]]];
  endSeq = If[IntegerQ[last], last, 0];
  If[TrueQ[feedsQ] && TrueQ[OptionValue["Checkpoints"]],
    ownFeed = iProvOwnFeedCompare[cps, cpNames, seqHash, first, endSeq, gapQ];
    wit = iProvWitnessOfMe[cps, endSeq];
    findings = Join[findings, KeyDrop[#, {"Peer", "Health"}] & /@ Join[ownFeed["Findings"], wit["Findings"]]]];
  status = Which[Select[findings, ! MemberQ[{"ChainRestart", "CheckpointSuperseded"}, #["Kind"]] &] =!= {}, "Failing", keyUnavailable > 0, "Inconclusive", True, "OK"];
  <|"Status" -> status,
    "Verified" -> <|"Lines" -> n, "FromSeq" -> first, "ToSeq" -> last, "MacChecked" -> macChecked, "KeyUnavailable" -> keyUnavailable, "Checkpoints" -> Length[cps],
      "MerkleChecked" -> merkleChecked, "FeedCheckpoints" -> ownFeed["Count"], "PeerWitnesses" -> wit["Count"], "FeedsCompared" -> TrueQ[feedsQ]|>,
    "Findings" -> findings,
    "Assurance" -> Switch[status,
      "OK", If[TrueQ[feedsQ] && ownFeed["Count"] + wit["Count"] > 0,
        "MAC 鍵に届かない改変と、feeds の写し・他機の証言と食い違う書き換えは検出されなかった (Seq " <> ToString[last] <> " まで)",
        "MAC 鍵に届かない改変は検出されなかった (Seq " <> ToString[last] <> " まで)"],
      "Inconclusive", "MAC 鍵が使えない行があり、MAC 鍵に届かない改変の有無を確かめきれなかった (Seq " <> ToString[last] <> " まで)",
      _, "台帳に連鎖・LineHash・MAC・checkpoint・feeds の写しとの不一致がある (位置は Findings)"],
    "Scope" -> "表 4.5 の 1〜2 行目: 偶発的な破損、MAC 鍵に届かないコードによる行の改変・挿入・削除・入れ替え、checkpoint 済み区間の削除" <>
      If[TrueQ[feedsQ], "。加えて 3 行目のうち、feeds の写しや他機が先に読んでいた checkpoint と食い違う書き換え", ""],
    "NotCovered" -> "MAC 鍵と同期鍵に届く同一ユーザーのコード (LLM 提案コードを含む) による台帳・checkpoint・feeds・他機の証言の整合的な書き換えと巻き戻し、" <>
      "直近 checkpoint 以降の末尾の削除、同期アカウントの侵害 (表 4.5 の 3〜4 行目)。feeds の写しは同じユーザー・同じ同期アカウントから書き換えられるので独立した証人ではない。" <>
      "「改ざんされていない」ことの証明ではない",
    "Seconds" -> AbsoluteTime[] - t0|>];

iProvIndexDigestValue[] := (If[TrueQ[$iProvQuarantineDirty], iProvQuarantineRecompute[]];
  If[ListQ[$iProvScoreSeeds] && $iProvScoreSeeds =!= {}, iProvScoreUpdate[600]];
  Hash[{KeySort[$iProvEntities], KeySort[$iProvActivities], KeySort[$iProvBlobs], KeySort[$iProvBlobRecords],
  KeySort[$iProvLogical], KeySort[$iProvRefs], KeySort[$iProvLabels], KeySort[$iProvEffective], $iProvChainEvents,
  KeySort[$iProvLineage], KeySort[$iProvActRefs], Map[If[AssociationQ[#], KeySort[#], #] &, iProvLabelState[]]}, "SHA256", "HexString"]);
SourceVaultProvIndexDigest[] := (
  If[! TrueQ[$iProvIndexLoaded] || Length[$iProvEntities] === 0, iProvIndexEnsureRead[]];
  <|"Digest" -> iProvIndexDigestValue[], "IndexSeq" -> $iProvIndexSeq, "Entities" -> Length[$iProvEntities],
    "Activities" -> Length[$iProvActivities], "Blobs" -> Length[$iProvBlobRecords]|>);

SourceVaultProvRebuildIndex[] := Module[{auth, t0 = AbsoluteTime[], meta, n},
  auth = iProvAuth["SourceVaultProvRebuildIndex", $iProvOwnerService];
  If[FailureQ[auth], Return[auth]];
  meta = iProvReadMeta[];
  If[meta === $Failed, Return[Failure["ProvLocalStateUnresolved", <||>]]];
  meta = iProvReconcile[meta];
  meta["Rebuilding"] = True; iProvWriteMeta[meta]; $iProvMetaCache = <||>;
  iProvIndexReset[];
  n = If[meta["DurableSeq"] > 0, iProvReplayLedger[0, meta["DurableSeq"]], 0];
  meta["IndexSeq"] = $iProvIndexSeq; meta["Rebuilding"] = False; meta["RebuiltAtUTC"] = iProvNowIso[];
  (* Inc5: 再構築では点数を全部計算しきる (持ち越すと差分更新の結果と比べられない) *)
  iProvScoreUpdate[600];
  iProvIndexSave[meta];
  iProvWriteMeta[meta]; $iProvMetaCache = <||>;
  <|"Status" -> If[meta["ChainState"] === "OK", "Rebuilt", "RebuiltChainDamaged"], "Entities" -> Length[$iProvEntities],
    "Activities" -> Length[$iProvActivities], "Blobs" -> Length[$iProvBlobRecords], "Applied" -> n, "LastSeq" -> meta["LastSeq"],
    "IndexSeq" -> $iProvIndexSeq, "Digest" -> iProvIndexDigestValue[], "Seconds" -> AbsoluteTime[] - t0|>];

(* Inc1b (2026-11-10): Merkle 根つき。区間は前の checkpoint の次の行から台帳の Durable な末尾まで。前の checkpoint の時点の台帳の位置
   (meta の CheckpointCursor) から読むので、毎時の checkpoint で月の台帳を全部読み直さない。カーソルが使えなければ全体を Seq で絞って読む *)
Options[SourceVaultProvCheckpoint] = {"Reason" -> "Manual"};
SourceVaultProvCheckpoint[OptionsPattern[]] := Module[
  {auth, meta, dir, day, path, prevCp, cp, mac, reason = ToString @ OptionValue["Reason"], existing, prevLast, lastAt, leaves, root, feedCopy},
  auth = iProvAuth["SourceVaultProvCheckpoint", $iProvOwnerService];
  If[FailureQ[auth], Return[auth]];
  meta = iProvReadMeta[];
  If[meta === $Failed, Return[Failure["ProvLocalStateUnresolved", <||>]]];
  If[meta["DurableSeq"] === 0, Return[<|"Status" -> "Empty"|>]];
  dir = iProvCheckpointDir[];
  If[dir === $Failed, Return[Failure["ProvLocalStateUnresolved", <||>]]];
  day = iProvDayTag[];
  path = FileNameJoin[{dir, day <> If[reason === "Daily", "", "-" <> ToLowerCase[iProvSafeName[reason]] <> "-" <>
    StringReplace[iProvNowIso[], {":" -> "", "-" -> "", "T" -> "t", "Z" -> ""}]] <> ".json"}];
  If[reason === "Daily" && FileExistsQ[path], Return[<|"Status" -> "Exists", "Path" -> path|>]];
  (* Inc1b: 時刻は秒までなので、同じ秒に 2 つ目を書くときは -2, -3 .. を付ける (上書きすると前の checkpoint と feeds の写しが食い違う) *)
  If[reason =!= "Daily" && FileExistsQ[path],
    With[{base = StringDrop[path, -5]},
      path = SelectFirst[Table[base <> "-" <> ToString[k] <> ".json", {k, 2, 999}], ! FileExistsQ[#] &, base <> "-" <> iProvULID[] <> ".json"]]];
  existing =Select[iProvReadJSON /@ iProvCheckpointFiles[], AssociationQ[#] && IntegerQ[Lookup[#, "LastSeq", None]] &];
  prevCp = If[existing === {}, Null, Last[SortBy[existing, Lookup[#, "LastSeq", 0] &]]];
  prevLast = If[AssociationQ[prevCp], prevCp["LastSeq"], 0];
  If[meta["DurableSeq"] <= prevLast, Return[<|"Status" -> "NoNewLines", "LastSeq" -> prevLast, "Reason" -> reason|>]];
  If[reason === "Periodic",
    lastAt = If[AssociationQ[prevCp], iProvIsoToAbs[ToString @ Lookup[prevCp, "AtUTC", ""]], $Failed];
    If[meta["DurableSeq"] - prevLast < $SourceVaultProvCheckpointLines && NumberQ[lastAt] && AbsoluteTime[] - lastAt < $SourceVaultProvCheckpointIntervalSeconds,
      Return[<|"Status" -> "NotDue", "LastSeq" -> prevLast, "PendingLines" -> meta["DurableSeq"] - prevLast, "Reason" -> reason|>]]];
  leaves = iProvLeafHashes[prevLast + 1, meta["DurableSeq"], meta];
  If[Lookup[leaves, meta["DurableSeq"], None] =!= meta["LastLineHash"],
    Return[Failure["ProvCheckpointLedgerMismatch", <|"DurableSeq" -> meta["DurableSeq"],
      "Found" -> If[KeyExistsQ[leaves, meta["DurableSeq"]], "LineHashDiffers", "LineMissing"],
      "MessageTemplate" -> "The ledger does not end with the line recorded in index-meta.json; no checkpoint is written over it (run SourceVaultProvVerifyLedger)."|>]]];
  root = SourceVaultProvMerkleRoot[Values[KeySort[leaves]]];
  cp = <|"Format" -> "SourceVaultProvCheckpoint/1", "CheckpointVersion" -> 2, "Date" -> day, "AtUTC" -> iProvNowIso[], "Reason" -> reason,
    "FirstSeq" -> prevLast + 1, "LastSeq" -> meta["DurableSeq"], "LastLineHash" -> meta["LastLineHash"],
    "MerkleRoot" -> root, "MerkleAlg" -> $iProvMerkleAlg, "TreeSize" -> Length[leaves],
    "LedgerFile" -> meta["LedgerFile"],
    "PreviousCheckpoint" -> If[AssociationQ[prevCp], KeyTake[prevCp, {"Date", "LastSeq", "LastLineHash", "MerkleRoot"}], Null],
    "Machine" -> iProvMachine[]|>;
  mac = iProvMac["LedgerMac", StringToByteArray[iProvCheckpointCanon[cp], "UTF-8"]];
  If[mac === $Failed, Return[Failure["ProvMacKeyUnavailable", <||>]]];
  cp["Mac"] = mac["Mac"];
  If[iProvWriteJSONAtomic[path, cp] === $Failed, Return[Failure["ProvCheckpointWriteFailed", <|"Path" -> path|>]]];
  meta["LastCheckpointDate"] = day;
  meta["CheckpointCursor"] = <|"File" -> meta["LedgerFile"], "Offset" -> meta["LedgerBytes"], "Seq" -> cp["LastSeq"]|>;
  iProvWriteMeta[meta]; $iProvMetaCache = <||>;
  (* feeds への写し (失敗しても checkpoint は書けている。SourceVaultProvSyncFeeds が後で写す) *)
  feedCopy = Quiet @ Check[iProvFeedCopyCheckpoint[path, cp], "Failed"];
  <|"Status" -> "Written", "Path" -> path, "LastSeq" -> cp["LastSeq"], "FirstSeq" -> cp["FirstSeq"], "Reason" -> reason,
    "MerkleRoot" -> root, "TreeSize" -> Length[leaves], "FeedCopy" -> feedCopy|>];

SourceVaultProvChainRestart[spec_Association, ticket_] := Module[{auth, meta, lastSeq, lastHash, bind, v, rec, r, path},
  auth = iProvAuth["SourceVaultProvChainRestart", $iProvOwner];
  If[FailureQ[auth], Return[auth]];
  If[Length[DownValues[SourceVault`SourceVaultOwnerTicketConsume]] === 0 || Length[DownValues[SourceVault`SourceVaultOwnerTicketDigest]] === 0,
    Return[Failure["ProvTicketUnavailable", <|"MessageTemplate" -> "SourceVault_autotrigger.wl (owner tickets) is not loaded."|>]]];
  meta = iProvReadMeta[];
  If[meta === $Failed, Return[Failure["ProvLocalStateUnresolved", <||>]]];
  If[! iProvLedgerKeyAvailableQ[], Return[Failure["ProvMacKeyUnavailable", <||>]]];
  lastSeq = Lookup[spec, "LastVerifiedSeq", meta["DurableSeq"]];
  lastHash = Lookup[spec, "LastVerifiedLineHash", meta["LastLineHash"]];
  If[! IntegerQ[lastSeq] || lastSeq < 0 || ! StringQ[lastHash] || ! StringMatchQ[lastHash, RegularExpression["^sha256:[0-9a-f]{64}$"]],
    Return[Failure["ProvBadChainRestartSpec", <|"LastVerifiedSeq" -> lastSeq, "LastVerifiedLineHash" -> lastHash|>]]];
  bind = <|"Display" -> SourceVault`SourceVaultOwnerTicketDigest[ToString @ Lookup[spec, "Display", ""]],
    "LastVerifiedSeq" -> SourceVault`SourceVaultOwnerTicketDigest[ToString[lastSeq]],
    "LastVerifiedLineHash" -> SourceVault`SourceVaultOwnerTicketDigest[lastHash]|>;
  v = SourceVault`SourceVaultOwnerTicketConsume[ticket, bind, "Action" -> "ProvChainRestart"];
  If[! (AssociationQ[v] && TrueQ[v["Consumed"]]), Return[Failure["ProvTicketRejected", <|"Result" -> v|>]]];
  rec = <|"Type" -> "ProvChainRestart", "PreviousChain" -> <|"LastVerifiedSeq" -> lastSeq, "LastVerifiedLineHash" -> lastHash|>,
    "Gap" -> <|"FromSeq" -> lastSeq + 1, "ToSeq" -> Max[meta["LastSeq"], lastSeq]|>,
    "DetectedBy" -> ToString @ Lookup[spec, "DetectedBy", "Owner"], "Detail" -> ToString @ Lookup[spec, "Note", ""],
    "PreviousDamage" -> meta["ChainDamage"], "Decision" -> "Restart", "TicketNonce" -> ToString @ Lookup[ticket, "Nonce", ""],
    "AtUTC" -> iProvNowIso[], "Machine" -> iProvMachine[]|>;
  (* 新しい連鎖: Seq は欠落区間の後から、PrevHash は最後に検証できた LineHash。ディスク上の現状を出発点として受け入れる *)
  meta["LastSeq"] = Max[meta["LastSeq"], lastSeq]; meta["LastLineHash"] = lastHash;
  meta["ChainState"] = "OK"; meta["ChainDamage"] = Null;
  meta["CheckpointCursor"] = Null;   (* Inc1b: 台帳の位置が変わるので checkpoint の読み始めの位置は捨てる *)
  path = If[StringQ[meta["LedgerFile"]],FileNameJoin[{iProvLedgerDir[], meta["LedgerFile"]}], $Failed];
  meta["LedgerBytes"] = If[StringQ[path] && FileExistsQ[path], Quiet @ Check[FileByteCount[path], 0], 0];
  If[! StringQ[path] || ! FileExistsQ[path], meta["LedgerFile"] = Null; meta["LedgerBytes"] = 0];
  iProvIndexEnsure[meta]; iProvSeenEnsure[];
  r = iProvAppendItems[meta, {<|"EventId" -> iProvULID[], "RecordText" -> iProvCanonText[rec]|>}];
  If[r["Status"] =!= "OK", iProvWriteMeta[r["Meta"]]; Return[Failure["ProvChainRestartFailed", <|"Status" -> r["Status"]|>]]];
  meta = r["Meta"];
  (* 索引は台帳から作り直す: 欠落区間 (失われた行) の版は索引から消え、再構築 (T-P5) と一致する *)
  iProvIndexReset[];
  If[meta["DurableSeq"] > 0, iProvReplayLedger[0, meta["DurableSeq"]]];
  meta["IndexSeq"] = $iProvIndexSeq; meta["RebuiltAtUTC"] = iProvNowIso[];
  iProvSeenSave[]; iProvIndexSave[meta]; iProvWriteMeta[meta]; $iProvMetaCache = <||>;
  <|"Status" -> "Restarted", "Seq" -> meta["LastSeq"], "PreviousChain" -> rec["PreviousChain"], "Gap" -> rec["Gap"],
    "IndexRebuilt" -> True, "Entities" -> Length[$iProvEntities]|>];
SourceVaultProvChainRestart[___] := Failure["ProvBadChainRestartSpec", <|"MessageTemplate" -> "SourceVaultProvChainRestart[spec_Association, ticket_Association]"|>];

Options[SourceVaultProvRotateKey] = {"Reason" -> "Scheduled"};
SourceVaultProvRotateKey[purpose_String, newSpec_Association, OptionsPattern[]] := Module[{auth, old, meta, rec, r, persist},
  auth = iProvAuth["SourceVaultProvRotateKey", $iProvOwnerService];
  If[FailureQ[auth], Return[auth]];
  If[! KeyExistsQ[$SourceVaultProvKeyRefs, purpose] || ! StringQ[Lookup[newSpec, "KeyRef", None]] || ! StringQ[Lookup[newSpec, "KeyId", None]] ||
      ! StringMatchQ[newSpec["KeyId"], RegularExpression["^[A-Za-z0-9_.-]+$"]],
    Return[Failure["ProvBadKeySpec", <|"Purpose" -> purpose, "Spec" -> KeyTake[newSpec, {"KeyId"}]|>]]];
  old = iProvKeySpec[purpose];
  If[old["KeyId"] === newSpec["KeyId"], Return[Failure["ProvBadKeySpec", <|"MessageTemplate" -> "the new KeyId must differ from the current one."|>]]];
  If[iProvMacWithKeyRef[newSpec["KeyRef"], StringToByteArray["probe", "UTF-8"]] === $Failed,
    Return[Failure["ProvKeyUnavailable", <|"Purpose" -> purpose, "KeyRef" -> newSpec["KeyRef"]|>]]];
  meta = iProvReadMeta[];
  If[meta === $Failed, Return[Failure["ProvLocalStateUnresolved", <||>]]];
  $SourceVaultProvRetiredKeyRefs[old["KeyId"]] = old["KeyRef"];
  $SourceVaultProvKeyRefs[purpose] = KeyTake[newSpec, {"KeyRef", "KeyId"}];
  persist = iProvWriteJSONAtomic[iProvKeyRefsPersistPath[], <|"Format" -> "SourceVaultProvKeyRefs/1", "Retired" -> $SourceVaultProvRetiredKeyRefs,
    "Current" -> Association @ KeyValueMap[#1 -> <|"KeyId" -> iProvKeySpec[#1]["KeyId"]|> &, $SourceVaultProvKeyRefs], "UpdatedAtUTC" -> iProvNowIso[]|>];
  rec = <|"Type" -> "ProvKeyRotation", "KeyPurpose" -> purpose, "OldKeyId" -> old["KeyId"], "NewKeyId" -> newSpec["KeyId"],
    "Reason" -> ToString @ OptionValue["Reason"], "Principal" -> iProvPrincipalKind[], "AtUTC" -> iProvNowIso[], "Machine" -> iProvMachine[]|>;
  meta = iProvReconcile[meta];
  If[meta["ChainState"] =!= "OK", iProvWriteMeta[meta]; Return[Failure["ProvChainDamaged", KeyTake[meta, {"ChainState", "ChainDamage"}]]]];
  iProvIndexEnsure[meta]; iProvSeenEnsure[];
  r = iProvAppendItems[meta, {<|"EventId" -> iProvULID[], "RecordText" -> iProvCanonText[rec]|>}];
  If[r["Status"] =!= "OK", iProvWriteMeta[r["Meta"]]; Return[Failure["ProvKeyRotationFailed", <|"Status" -> r["Status"]|>]]];
  meta = r["Meta"]; meta["IndexSeq"] = $iProvIndexSeq;
  iProvSeenSave[]; iProvIndexSave[meta]; iProvWriteMeta[meta]; $iProvMetaCache = <||>;
  <|"Status" -> "Rotated", "Purpose" -> purpose, "OldKeyId" -> old["KeyId"], "NewKeyId" -> newSpec["KeyId"], "Seq" -> meta["LastSeq"],
    "Persisted" -> (persist =!= $Failed)|>];

(* ============================================================
   Usability (§5.6 / §8.1 usability.wxf / Y-08)・AwaitCommitted・Resolve・HumanEditedQ・Status
   ============================================================ *)
If[! AssociationQ[$iProvUsabilityCache], $iProvUsabilityCache = <||>];
SourceVaultProvUsabilityIndexLoad[] := Module[{p = iProvIndexPath["usability.wxf"], t0 = AbsoluteTime[], d},
  If[p === $Failed || ! FileExistsQ[p], Return[Failure["ProvIndexUnavailable", <|"Path" -> p|>]]];
  d = iProvReadWXF[p];
  If[! AssociationQ[d] || Lookup[d, "Format", ""] =!= "SourceVaultProvUsability/1" || ! ListQ[Lookup[d, "Ids", None]],
    Return[Failure["ProvIndexCorrupt", <|"Path" -> p|>]]];
  <|"IndexSeq" -> Lookup[d, "IndexSeq", 0], "DurableSeq" -> Lookup[d, "DurableSeq", 0], "Count" -> Length[d["Ids"]],
    "LoadSeconds" -> AbsoluteTime[] - t0, "Ids" -> d["Ids"], "Codes" -> Lookup[d, "Codes", {}], "Seq" -> Lookup[d, "Seq", {}],
    "Extras" -> With[{x = Lookup[d, "Extras", <||>]}, If[AssociationQ[x], x, <||>]]|>];
(* Seq による無効化: meta の IndexSeq が進んだときだけ usability.wxf を読み直す。Lookup は初回だけ作る *)
iProvUsabilityEnsure[meta_] := Module[{need, d},
  need = ! AssociationQ[Lookup[$iProvUsabilityCache, "Lookup", None]] ||
    Lookup[$iProvUsabilityCache, "IndexSeq", -1] =!= Lookup[meta, "IndexSeq", 0];
  If[! need, Return[True]];
  d = SourceVaultProvUsabilityIndexLoad[];
  If[FailureQ[d], $iProvUsabilityCache = <||>; Return[False]];
  $iProvUsabilityCache = <|"IndexSeq" -> d["IndexSeq"], "DurableSeq" -> d["DurableSeq"], "LoadSeconds" -> d["LoadSeconds"],
    "Lookup" -> If[d["Ids"] === {}, <||>, AssociationThread[d["Ids"] -> Transpose[{Normal @ d["Codes"], Normal @ d["Seq"]}]]],
    "Extras" -> d["Extras"], "LoadedAt" -> AbsoluteTime[]|>;
  True];
iProvUsabilityOne[id_String, meta_, ok_] := Module[{hit, u, seq, idxSeq = Lookup[meta, "IndexSeq", 0], durSeq = Lookup[meta, "DurableSeq", 0], badQ},
  (* 索引が再構築中・連鎖が壊れている -> すべて Unknown (計算途中の値を安全確認済みとして出さない、§5.6)。
     索引ファイルがまだ無い / 読めないだけなら、このカーネルが spool した版は Pending、他は Unknown *)
  badQ = TrueQ[Lookup[meta, "Rebuilding", False]] || Lookup[meta, "ChainState", "OK"] =!= "OK";
  hit = If[TrueQ[ok], Lookup[$iProvUsabilityCache["Lookup"], id, None], None];
  Which[
    badQ, u = "Unknown"; seq = If[ListQ[hit], hit[[2]], Null],
    ListQ[hit], u = Lookup[$iProvUsabilityNames, hit[[1]], "Unknown"]; seq = hit[[2]],
    KeyExistsQ[$iProvLocalSpooled, id], u = "Pending"; seq = Null,
    True, u = "Unknown"; seq = Null];
  <|"EntityId" -> id, "Usability" -> u, "Seq" -> seq, "IndexSeq" -> idxSeq, "DurableSeq" -> durSeq,
    "Committed" -> (IntegerQ[seq] && seq <= durSeq && seq <= idxSeq && ! badQ && TrueQ[ok])|>];
SourceVaultProvUsability[id_String] := Module[{meta = iProvReadMetaCached[], ok},
  If[meta === $Failed, Return[<|"EntityId" -> id, "Usability" -> "Unknown", "Seq" -> Null, "IndexSeq" -> 0, "DurableSeq" -> 0, "Committed" -> False|>]];
  ok = iProvUsabilityEnsure[meta];
  iProvUsabilityOne[id, meta, ok]];
SourceVaultProvUsability[ids_List] := Module[{meta = iProvReadMetaCached[], ok},
  If[meta === $Failed, Return[Association[# -> <|"EntityId" -> #, "Usability" -> "Unknown", "Committed" -> False|> & /@ Select[ids, StringQ]]]];
  ok = iProvUsabilityEnsure[meta];
  Association[# -> iProvUsabilityOne[#, meta, ok] & /@ Select[ids, StringQ]]];
SourceVaultProvUsability[___] := Failure["ProvBadArguments", <|"MessageTemplate" -> "SourceVaultProvUsability[id_String] or [{id..}]"|>];

SourceVaultProvAwaitCommitted[ids_List, timeout_?NumericQ] := Module[{t0 = AbsoluteTime[], todo = Select[ids, StringQ], done = {}, u},
  While[True,
    $iProvMetaCache = <||>;
    u = SourceVaultProvUsability[todo];
    done = Join[done, Select[todo, TrueQ[Lookup[Lookup[u, #, <||>], "Committed", False]] &]];
    todo = Complement[todo, done];
    If[todo === {} || AbsoluteTime[] - t0 >= timeout, Break[]];
    Pause[Min[0.5, Max[0.05, timeout/10]]]];
  <|"Status" -> If[todo === {}, "Committed", "Timeout"], "Committed" -> done, "Pending" -> todo, "Seconds" -> AbsoluteTime[] - t0|>];
SourceVaultProvAwaitCommitted[id_String, timeout_?NumericQ] := SourceVaultProvAwaitCommitted[{id}, timeout];

iProvVersionView[id_String, withBlobQ_] := Module[{e = Lookup[$iProvEntities, id, <||>], l = Lookup[$iProvLabels, id, <||>], f = Lookup[$iProvEffective, id, <||>], pl},
  pl = Lookup[l, "PrivacyLevel", Null];
  <|"EntityId" -> id, "Seq" -> Lookup[e, "Seq", Null], "Kind" -> Lookup[e, "Kind", Null], "PrivacyLevel" -> pl,
    "BlobId" -> If[TrueQ[withBlobQ] || (NumericQ[pl] && pl < 0.5), Lookup[e, "BlobId", Null], Missing["Withheld"]],
    "LogicalRef" -> Lookup[e, "LogicalRef", Null], "Completeness" -> Lookup[l, "Completeness", Null],
    "OriginClass" -> Lookup[Lookup[l, "Origin", <||>], "OriginClass", "Unknown"],
    "Usability" -> Lookup[f, "Usability", "Unknown"], "ProducedBy" -> Lookup[e, "ProducedBy", {}], "Uses" -> Lookup[l, "Uses", 0]|>];
SourceVaultProvResolve[ref_String] := Module[{ids, withBlob, c},
  If[! iProvIndexEnsureRead[], Return[<|"Status" -> "IndexUnavailable", "Ref" -> ref, "EntityIds" -> {}, "Latest" -> Null, "Versions" -> {}|>]];
  withBlob = MemberQ[$iProvOwnerService, iProvPrincipalKind[]];
  ids = Which[
    iProvEntityIdQ[ref], If[KeyExistsQ[$iProvEntities, ref], {ref}, {}],
    iProvBlobIdQ[ref], Lookup[$iProvBlobs, ref, {}],
    True,
      c = If[StringStartsQ[ref, "sv://"] && Length[DownValues[SourceVault`SourceVaultCanonicalURI]] > 0,
        Quiet @ Check[SourceVault`SourceVaultCanonicalURI[ref], ref], ref];
      If[! StringQ[c], c = ref];
      DeleteDuplicates @ Join[Lookup[$iProvLogical, c, {}], Lookup[$iProvLogical, ref, {}], Lookup[$iProvRefs, ref, {}]]];
  ids = SortBy[ids, Lookup[Lookup[$iProvEntities, #, <||>], "Seq", 0] &];
  <|"Status" -> If[ids === {}, "NotFound", "Found"], "Ref" -> ref, "EntityIds" -> ids, "Latest" -> If[ids === {}, Null, Last[ids]],
    "Versions" -> (iProvVersionView[#, withBlob] & /@ ids)|>];
SourceVaultProvResolve[___] := Failure["ProvBadArguments", <|"MessageTemplate" -> "SourceVaultProvResolve[ref_String]"|>];

SourceVaultProvHumanEditedQ[ref_String] := Module[{r = SourceVaultProvResolve[ref]},
  If[! AssociationQ[r] || r["Status"] =!= "Found", Return[Missing["NotFound", ref]]];
  AnyTrue[r["EntityIds"], Function[id,
    AnyTrue[Lookup[Lookup[$iProvEntities, id, <||>], "ProducedBy", {}], Lookup[Lookup[$iProvActivities, #, <||>], "Kind", None] === "HumanEdit" &] &&
      MemberQ[Lookup[Lookup[Lookup[$iProvLabels, id, <||>], "Origin", <||>], "Contributors", {}], "Owner"]]]];
SourceVaultProvHumanEditedQ[___] := Missing["NotFound"];

SourceVaultProvStatus[] := Module[{meta = iProvReadMeta[], dir = iProvSpoolDir[], files},
  files = If[DirectoryQ[dir], Quiet @ Check[FileNames["*.jsonl", dir], {}], {}];
  <|"Emit" -> $iProvEmitStats,
    "Spool" -> <|"Files" -> Length[files], "Bytes" -> Total[Quiet @ Check[FileByteCount[#], 0] & /@ files], "Producer" -> iProvProducer[]|>,
    "Meta" -> If[AssociationQ[meta], KeyTake[meta, {"LastSeq", "DurableSeq", "IndexSeq", "ChainState", "CarryOver", "Rebuilding", "PendingCount",
      "LastIngestAtUTC", "LastCheckpointDate", "RebuiltAtUTC", "Counts"}], Missing["LocalStateUnresolved"]],
    "KeyedDigestCalls" -> $iProvKeyedDigestCalls, "LedgerMacKeyAvailable" -> iProvLedgerKeyAvailableQ[], "Profile" -> iProvProfile[],
    "IndexLoaded" -> TrueQ[$iProvIndexLoaded], "Pending" -> If[ListQ[$iProvPending], Length[$iProvPending], Null],
    "LocalSpooled" -> Length[$iProvLocalSpooled],
    "LLMQueue" -> If[ListQ[$iProvLLMQueue], Length[$iProvLLMQueue], If[AssociationQ[meta], Lookup[meta, "LLMQueueCount", 0], Null]],
    "Served" -> $iProvServedStats,
    (* Inc1b: feeds の射影済み Seq・最後の同期・写しの失敗数 *)
    "Feeds" -> Join[If[AssociationQ[meta], KeyTake[meta, {"FeedSeq", "LastFeedSyncAtUTC"}], <||>], $iProvFeedStats]|>];

SourceVaultProvResetCaches[] := (
  iProvIndexReset[]; $iProvIndexLoaded = False; $iProvSeen = None; $iProvSeenDirty = False; $iProvPending = None; $iProvPendingDirty = False;
  $iProvLLMQueue = None; $iProvLLMQueueDirty = False; $iProvServedCache = <||>; $iProvSyncIds = None; $iProvSyncIdsDirty = False;
  $iProvSpoolState = <||>; $iProvUsabilityCache = <||>; $iProvMetaCache = <||>; $iProvLocalSpooled = <||>; True);

(* ============================================================
   Inc3 (03 v0.4 §5.2〜5.6 / §8.2 / §11.6、2026-11-10): ラベルの記録・出自の合成・隔離の到達計算・FE が読む小さな表
   ============================================================ *)
(* ---- 所有者 ticket の Bind (Display 以外)。integrity の所有者操作は同じ関数で Bind を作る ---- *)
iProvTicketDigest[s_String] := "sha256:" <> iProvSHAHex[s];
iProvTicketDigest[x_] := iProvTicketDigest[ToString[x, InputForm]];
iProvLabelBind[type_String, rec_Association] := With[{d = iProvTicketDigest, s = Function[k, ToString @ Lookup[rec, k, ""]]},
  Switch[type,
    "ProvAuthorization", <|"Target" -> d[s["EntityId"] <> "|" <> s["BlobId"]], "Purpose" -> d[s["Purpose"]]|>,
    "ProvRevocation", <|"Auth" -> d[s["AuthId"]]|>,
    "ProvFindingResolution", <|"Finding" -> d[s["FindingId"]],
      "Resolution" -> d[ToString @ Lookup[With[{r = Lookup[rec, "Resolution", <||>]}, If[AssociationQ[r], r, <||>]], "Kind", ""]]|>,
    "ProvRelease", <|"Finding" -> d[s["FindingId"]], "Target" -> d[s["EntityId"]],
      "Ground" -> d[ToString @ Lookup[With[{g = Lookup[rec, "Ground", <||>]}, If[AssociationQ[g], g, <||>]], "Kind", ""]]|>,
    "ProvVerifierRegistration", <|"Verifier" -> d[s["Name"]], "Implementation" -> d[iProvCanonText[Lookup[rec, "Implementation", <||>]]]|>,
    "ProvFinding", <|"Target" -> d[StringRiffle[Sort[Select[Flatten[{Lookup[rec, "Targets", {}]}], StringQ]], ","]]|>,
    "ProvVerification", <|"Target" -> d[s["EntityId"] <> "|" <> s["BlobId"]], "Property" -> d[s["Property"]]|>,
    _, <||>]];

(* ---- Registry: 照合に落ちたラベルの記録と、モデル・MCP からの試み ---- *)
If[! IntegerQ[$iProvRegistryAttemptCount], $iProvRegistryAttemptCount = 0];
iProvRegistryIssue[seq_, type_String, lid_, reason_String] := (
  AppendTo[$iProvRegistryIssues, <|"Seq" -> seq, "Type" -> type, "Id" -> lid, "Reason" -> reason|>];
  If[Length[$iProvRegistryIssues] > 500, $iProvRegistryIssues = Take[$iProvRegistryIssues, -500]]);
iProvNoteRegistryAttempt[type_String, fn_String] := Module[{d = iProvHealthDir[]},
  $iProvRegistryAttemptCount++;
  If[d =!= $Failed,
    Quiet @ iProvAppendText[FileNameJoin[{d, "registry-attempts.jsonl"}],
      iProvCanonText[<|"AtUTC" -> iProvNowIso[], "Type" -> type, "Function" -> fn, "Principal" -> iProvPrincipalKind[],
        "Channel" -> With[{c = Quiet @ Check[SourceVault`SourceVaultPrincipal["Channel"], Null]}, If[StringQ[c], c, Null]]|>] <> "\n"]]];

(* ticket を同梱する記録の照合: Action・Bind (Display 以外)・消費済み・署名 (鍵があれば)・発行元・nonce の使い回し *)
iProvLabelTicketCheck[type_String, rec_Association, key_String] := Module[{t = Lookup[rec, "Ticket", None], chk, nonce},
  If[! AssociationQ[t], Return["TicketMissing"]];
  If[Length[DownValues[SourceVault`SourceVaultOwnerTicketCheckRecord]] === 0, Return["TicketCheckUnavailable"]];
  chk = Quiet @ Check[SourceVault`SourceVaultOwnerTicketCheckRecord[t, $iProvTicketActions[type], iProvLabelBind[type, rec]], $Failed];
  If[! AssociationQ[chk], Return["TicketCheckUnavailable"]];
  nonce = Lookup[chk, "Nonce", Null];
  Which[
    ! TrueQ[chk["Type"]], "TicketBadType",
    ! TrueQ[chk["Action"]], "TicketActionMismatch",
    ! TrueQ[chk["Bind"]], "TicketBindMismatch",
    chk["Signature"] === "Bad", "TicketBadSignature",
    chk["Consumed"] =!= True, "TicketNotConsumed",
    ! (chk["Issuer"] === "OwnerFE" || (chk["Issuer"] === "Development" && iProvProfile[] === "development")), "TicketIssuerNotOwner",
    StringQ[nonce] && KeyExistsQ[$iProvTicketNonces, nonce] && $iProvTicketNonces[nonce] =!= key, "TicketReused",
    True, If[StringQ[nonce], $iProvTicketNonces[nonce] = key]; "OK"]];

$iProvFindingSeverities = {"Info", "Low", "Medium", "High", "Critical"};
$iProvReleaseGrounds = {"IndependentOfTaint", "Sanitizer", "Regenerated"};
$iProvResolutionKinds = {"Acknowledged", "FalsePositive", "Remediated", "AcceptedRisk"};

iProvApplyLabelRecord[seq_Integer, type_String, rec_Association] := Module[{lid, key, needTicket, v, r, f},
  lid = Lookup[rec, $iProvLabelIdKeys[type], None];
  If[! StringQ[lid], Return[Null]];
  key = type <> "|" <> lid;
  If[KeyExistsQ[$iProvLabelIds, key], Return[Null]];
  $iProvLabelIds[key] = seq;
  needTicket = MemberQ[$iProvOwnerRecordTypes, type] || (type === "ProvFinding" && KeyExistsQ[rec, "Ticket"]) ||
    (type === "ProvVerification" && Lookup[rec, "Property", ""] === "OwnerReviewed");
  If[needTicket,
    v = iProvLabelTicketCheck[type, rec, key];
    If[v =!= "OK", iProvRegistryIssue[seq, type, lid, v]; Return[Null]]];
  Switch[type,
    "ProvFinding",
      $iProvFindingsX[lid] = <|"Seq" -> seq, "Kind" -> ToString @ Lookup[rec, "Kind", "Finding"],
        "Severity" -> With[{s = Lookup[rec, "Severity", "Medium"]}, If[MemberQ[$iProvFindingSeverities, s], s, "Medium"]],
        "Targets" -> Select[Flatten[{Lookup[rec, "Targets", {}]}], iProvEntityIdQ[#] || iProvBlobIdQ[#] &],
        "Reason" -> ToString @ Lookup[rec, "Reason", ""], "Source" -> ToString @ Lookup[rec, "Source", "Verifier"],
        "OpenedAtUTC" -> ToString @ Lookup[rec, "OpenedAtUTC", ""]|>;
      $iProvQuarantineDirty = True,
    "ProvFindingResolution",
      r = Lookup[rec, "Resolution", <||>]; If[! AssociationQ[r], r = <||>];
      Which[
        ! MemberQ[$iProvResolutionKinds, Lookup[r, "Kind", None]], iProvRegistryIssue[seq, type, lid, "ResolutionKindInvalid"],
        r["Kind"] === "Remediated" && With[{op = Lookup[r, "OpenPublications", 0]}, ! (IntegerQ[op] && op === 0)],
          iProvRegistryIssue[seq, type, lid, "RemediatedWithOpenPublications"],
        r["Kind"] === "AcceptedRisk" && ! (ListQ[Lookup[Lookup[r, "Scope", <||>], "Purposes", None]] && NumberQ[iProvIsoToAbs[ToString @ Lookup[r, "ExpiresAtUTC", ""]]]),
          iProvRegistryIssue[seq, type, lid, "AcceptedRiskWithoutScope"],
        True,
          $iProvResolutionsX[ToString @ Lookup[rec, "FindingId", ""]] = <|"Seq" -> seq, "ResolutionId" -> lid, "Kind" -> r["Kind"],
            "Purposes" -> Select[Flatten[{Lookup[Lookup[r, "Scope", <||>], "Purposes", {}]}], StringQ],
            "ExpiresAbs" -> With[{a = iProvIsoToAbs[ToString @ Lookup[r, "ExpiresAtUTC", ""]]}, If[NumberQ[a], a, Null]],
            "Replacements" -> Select[Flatten[{Lookup[r, "Replacements", {}]}], iProvEntityIdQ],
            "AtAbs" -> With[{a = iProvIsoToAbs[ToString @ Lookup[rec, "AtUTC", ""]]}, If[NumberQ[a], a, Null]]|>;
          $iProvQuarantineDirty = True],
    "ProvRelease",
      Which[
        ! MemberQ[$iProvReleaseGrounds, Lookup[With[{g = Lookup[rec, "Ground", <||>]}, If[AssociationQ[g], g, <||>]], "Kind", None]],
          iProvRegistryIssue[seq, type, lid, "ReleaseGroundInvalid"],
        ! iProvEntityIdQ[Lookup[rec, "EntityId", None]], iProvRegistryIssue[seq, type, lid, "ReleaseTargetInvalid"],
        True,
          With[{fid = ToString @ Lookup[rec, "FindingId", ""]},
            $iProvReleasesX[fid] = Union[Lookup[$iProvReleasesX, fid, {}], {rec["EntityId"]}]];
          $iProvQuarantineDirty = True],
    "ProvAuthorization",
      If[! MemberQ[$iProvInstructionPurposes, Lookup[rec, "Purpose", None]] || ! iProvBlobIdQ[Lookup[rec, "BlobId", None]],
        iProvRegistryIssue[seq, type, lid, "AuthorizationInvalid"],
        f = Lookup[$iProvAuthzX, lid, <||>];
        $iProvAuthzX[lid] = <|"Seq" -> seq, "EntityId" -> Lookup[rec, "EntityId", Null], "BlobId" -> rec["BlobId"], "Purpose" -> rec["Purpose"],
          "Scope" -> With[{sc = Lookup[rec, "Scope", <||>]}, If[AssociationQ[sc], sc, <||>]],
          "RequiredClaims" -> Select[Flatten[{Lookup[rec, "RequiredClaims", {}]}], StringQ],
          "ExpiresAbs" -> With[{a = iProvIsoToAbs[ToString @ Lookup[rec, "ExpiresAtUTC", ""]]}, If[NumberQ[a], a, Null]],
          "IssuedAtUTC" -> ToString @ Lookup[rec, "IssuedAtUTC", ""], "Revoked" -> TrueQ[Lookup[f, "Revoked", False]]|>],
    "ProvRevocation",
      With[{aid = ToString @ Lookup[rec, "AuthId", ""]},
        $iProvAuthzX[aid] = Join[Lookup[$iProvAuthzX, aid, <||>], <|"Revoked" -> True, "RevokedSeq" -> seq|>]],
    "ProvVerification",
      Module[{eid = Lookup[rec, "EntityId", Null], prop = ToString @ Lookup[rec, "Property", ""], ver = Lookup[rec, "Verifier", <||>], vk, nm, reg, eff},
        If[! AssociationQ[ver], ver = <||>];
        vk = ToString @ Lookup[ver, "Kind", "Unknown"]; nm = ToString @ Lookup[ver, "Name", ""];
        reg = Lookup[$iProvVerifierRegX, nm, None];
        eff = Which[
          prop === "OwnerReviewed", True,   (* ticket を照合済み (Human)。出自・隔離・認可は変えない *)
          (* V9: 裏付けの検査の結果 (service が claudecode の記録から作る)。ラベル Grounding の元になるだけで、認可の RequiredClaims には
             効かせない (信用を上げる方向には使わない)。登録表に無くても Registry の不一致にはしない *)
          prop === "Grounding", False,
          vk =!= "Deterministic", False,      (* Model の判定は参考情報 (5.3 節) *)
          AssociationQ[reg] && reg["Kind"] === "Deterministic" && TrueQ[Lookup[reg, "Active", True]] && MemberQ[Lookup[reg, "Properties", {}], prop], True,
          True, iProvRegistryIssue[seq, type, lid, "UnregisteredVerifierClaim"]; False];
        If[iProvEntityIdQ[eid],
          $iProvClaimsX[eid] = Append[Lookup[$iProvClaimsX, eid, {}],
            <|"VerificationId" -> lid, "BlobId" -> Lookup[rec, "BlobId", Null], "Property" -> prop, "Result" -> ToString @ Lookup[rec, "Result", "Inconclusive"],
              "VerifierKind" -> vk, "Verifier" -> nm, "Effective" -> eff, "Seq" -> seq|>]]],
    "ProvVerifierRegistration",
      If[! MemberQ[{"Deterministic", "Model"}, Lookup[rec, "Kind", None]] || ! StringQ[Lookup[rec, "Name", None]],
        iProvRegistryIssue[seq, type, lid, "RegistrationInvalid"],
        $iProvVerifierRegX[rec["Name"]] = <|"Seq" -> seq, "RegistrationId" -> lid, "Kind" -> rec["Kind"],
          "Properties" -> Select[Flatten[{Lookup[rec, "Properties", {}]}], StringQ],
          "Implementation" -> With[{im = Lookup[rec, "Implementation", <||>]}, If[AssociationQ[im], im, <||>]],
          "Active" -> ! TrueQ[Lookup[rec, "Retired", False]]|>],
    _, Null];
  (* Inc5: 点数の種 (Finding・解決・検証主張で p0 / v が変わる版) *)
  Switch[type,
    "ProvFinding" | "ProvFindingResolution",
      With[{f = Lookup[$iProvFindingsX, If[type === "ProvFinding", lid, ToString @ Lookup[rec, "FindingId", ""]], None]},
        If[AssociationQ[f], iProvScoreSeed[DeleteDuplicates @ Join[Select[f["Targets"], iProvEntityIdQ],
          Flatten[Lookup[$iProvBlobs, Select[f["Targets"], iProvBlobIdQ], {}]]]]]],
    "ProvVerification", iProvScoreSeed[Lookup[rec, "EntityId", Null]],
    _, Null];
  $iProvIndexDirty = True];

(* ---- 出自の合成 (5.2 節): carry 入力の和 ∪ Self(Kind)。出力の出自が広がったら carry の子孫へ (単調) ---- *)
iProvSelfOrigin[kind_, rec_Association, actor_Association, carryIns_List] := Module[{c = {}, t = {}, mref, ch},
  Switch[kind,
    "Ingest",
      ch = Lookup[With[{x = Lookup[rec, "ExternalRefs", <||>]}, If[AssociationQ[x], x, <||>]], "Channel", "unknown"];
      c = {"External"}; t = {"ext:" <> ToLowerCase[ToString[ch]]},
    "LLMGenerate",
      mref = Lookup[actor, "ModelRef", Null];
      c = {"Model"}; t = If[StringQ[mref], {"model:" <> mref}, {}];
      (* モデル識別子の無い出力・入力が 1 件も記録されていない出力は Unknown (記録漏れで扱いを緩めない、5.2 節・X-02) *)
      If[! StringQ[mref], c = Append[c, "Unknown"]; t = Append[t, "prov:no-model-ref"]];
      If[carryIns === {}, c = Append[c, "Unknown"]; t = Append[t, "prov:no-recorded-input"]],
    "HumanEdit", c = {"Owner"}; t = {"edit:owner"},
    "Execute", If[Lookup[actor, "Kind", ""] === "Model", c = {"Model"}; t = {"exec:model"}],
    _, Null];
  <|"Contributors" -> c, "Taints" -> t|>];

iProvOriginWiden[start_String, addC_List, addT_List, partialQ_] := Module[{bag, i = 1, item, x, ac, at, l, org, nc, nt, u, n = 0},
  bag = Internal`Bag[{{start, addC, addT, TrueQ[partialQ]}}];
  While[i <= Internal`BagLength[bag] && n < 200000,
    item = Internal`BagPart[bag, i]; i++; n++;
    {x, ac, at} = Take[item, 3];
    l = Lookup[$iProvLabels, x, None];
    If[! AssociationQ[l], Continue[]];
    org = Lookup[l, "Origin", <||>];
    nc = Union[Lookup[org, "Contributors", {}], ac]; nt = Union[Lookup[org, "Taints", {}], at];
    If[item[[4]] && Lookup[l, "Completeness", "Unknown"] === "Complete", $iProvLabels[x, "Completeness"] = "Partial"];
    If[nc =!= Lookup[org, "Contributors", {}] || nt =!= Lookup[org, "Taints", {}] || item[[4]],
      $iProvLabels[x, "Origin"] = iProvNormalizeOrigin[<|"Contributors" -> nc, "Taints" -> nt|>];
      u = iProvEntityUsability[$iProvLabels[x]];
      $iProvEffective[x] = <|"Usability" -> u[[1]], "Seq" -> Lookup[Lookup[$iProvEffective, x, <||>], "Seq", Lookup[l, "Seq", 0]], "Reason" -> u[[2]]|>;
      If[KeyExistsQ[$iProvQuarantineX, x], $iProvQuarantineDirty = True];
      iProvScoreSeed[x];
      If[nc =!= Lookup[org, "Contributors", {}] || nt =!= Lookup[org, "Taints", {}],
        Scan[Internal`StuffBag[bag, {#, nc, nt, False}] &, Lookup[$iProvCarryOut, x, {}]]]]];
  n];

iProvComposeActivity[aid_String, rec_Association, ins_List, outs_List, actor_Association] := Module[
  {kind = Lookup[rec, "Kind", None], carryIns, citeIns, outIds, self, inC, inT, partialQ},
  outIds = DeleteDuplicates @ Select[Lookup[#, "EntityId", None] & /@ outs, StringQ[#] && KeyExistsQ[$iProvEntities, #] &];
  If[outIds === {}, Return[Null]];
  carryIns = DeleteDuplicates @ Select[Lookup[#, "EntityId", None] & /@ Select[ins, MemberQ[$iProvCarryRoles, Lookup[#, "Role", ""]] &],
    StringQ[#] && KeyExistsQ[$iProvEntities, #] &];
  citeIns = DeleteDuplicates @ Select[Lookup[#, "EntityId", None] & /@ Select[ins, Lookup[#, "Role", ""] === "Cite" &],
    StringQ[#] && KeyExistsQ[$iProvEntities, #] &];
  Scan[($iProvCarryOut[#] = Union[Lookup[$iProvCarryOut, #, {}], outIds]) &, carryIns];
  Scan[($iProvCiteOut[#] = Union[Lookup[$iProvCiteOut, #, {}], outIds]) &, citeIns];
  (* Inc5: 点数のための親 (Role つき、Cite も含む) *)
  With[{pr = DeleteDuplicates @ Select[{Lookup[#, "EntityId", None], Lookup[#, "Role", "Context"]} & /@ ins,
      StringQ[#[[1]]] && KeyExistsQ[$iProvEntities, #[[1]]] && (MemberQ[$iProvCarryRoles, #[[2]]] || #[[2]] === "Cite") &]},
    Scan[($iProvParentsX[#] = Union[Lookup[$iProvParentsX, #, {}], pr]) &, outIds]];
  iProvScoreSeed[outIds];
  self = iProvSelfOrigin[kind, rec, actor, carryIns];
  inC = Union @@ Prepend[Lookup[Lookup[Lookup[$iProvLabels, #, <||>], "Origin", <||>], "Contributors", {}] & /@ carryIns, {}];
  inT = Union @@ Prepend[Lookup[Lookup[Lookup[$iProvLabels, #, <||>], "Origin", <||>], "Taints", {}] & /@ carryIns, {}];
  (* 宣言した入力の一部が欠けた Activity (Partial) の出力は Partial (T-L6)。既定値 Unknown の Activity では変えない *)
  partialQ = Lookup[rec, "Completeness", Lookup[rec, "InputsCompleteness", "Unknown"]] === "Partial";
  Scan[iProvOriginWiden[#, Union[inC, self["Contributors"]], Union[inT, self["Taints"]], partialQ] &, outIds];
  If[$iProvFindingsX =!= <||> && (carryIns =!= {} || citeIns =!= {}), $iProvQuarantineDirty = True];
  Null];

(* ---- 隔離 (8.2 節): 有効な Finding (High 以上、FalsePositive でない) の対象から carry 辺で到達できる版。段数で減衰しない。
   その Finding について解除 (Release) された版は通らない。Finding ごとに集合を持つ ---- *)
iProvFindingActiveQ[fid_String] := With[{f = Lookup[$iProvFindingsX, fid, None]},
  AssociationQ[f] && MemberQ[$iProvSevereLevels, f["Severity"]] && Lookup[Lookup[$iProvResolutionsX, fid, <||>], "Kind", None] =!= "FalsePositive"];
iProvQuarantineRecompute[] := Module[{active, newQ = <||>, cite = <||>, old = $iProvQuarantineX},
  active = Select[Keys[$iProvFindingsX], iProvFindingActiveQ];
  Scan[Function[fid, Module[{f = $iProvFindingsX[fid], targets, rel, seen = <||>, bag, i = 1, x, citeN = <||>},
      targets = DeleteDuplicates @ Join[Select[f["Targets"], iProvEntityIdQ[#] && KeyExistsQ[$iProvEntities, #] &],
        Flatten[Lookup[$iProvBlobs, Select[f["Targets"], iProvBlobIdQ], {}]]];
      rel = AssociationThread[Lookup[$iProvReleasesX, fid, {}] -> True];
      targets = Select[targets, ! KeyExistsQ[rel, #] &];
      Scan[(seen[#] = True) &, targets];
      bag = Internal`Bag[targets];
      While[i <= Internal`BagLength[bag],
        x = Internal`BagPart[bag, i]; i++;
        Scan[Function[y, If[! KeyExistsQ[seen, y] && ! KeyExistsQ[rel, y], seen[y] = True; Internal`StuffBag[bag, y]]], Lookup[$iProvCarryOut, x, {}]]];
      Scan[Function[x, newQ[x] = Append[Lookup[newQ, x, {}], fid];
          Scan[Function[y, If[! KeyExistsQ[seen, y], citeN[y] = True]], Lookup[$iProvCiteOut, x, {}]]], Keys[seen]];
      cite[fid] = Length[citeN]]], active];
  (* 実効の利用可否: 隔離中の版に印を付け、隔離から外れた版は元の判定に戻す *)
  KeyValueMap[Function[{x, fids}, With[{e = Lookup[$iProvEffective, x, <||>]},
      $iProvEffective[x] = <|"Usability" -> "Quarantined", "Seq" -> Lookup[e, "Seq", Lookup[Lookup[$iProvEntities, x, <||>], "Seq", 0]],
        "Reason" -> "Finding", "QuarantinedBy" -> Sort[fids]|>]], newQ];
  Scan[Function[x, If[! KeyExistsQ[newQ, x] && KeyExistsQ[$iProvLabels, x],
      With[{u = iProvEntityUsability[$iProvLabels[x]], e = Lookup[$iProvEffective, x, <||>]},
        $iProvEffective[x] = <|"Usability" -> u[[1]], "Seq" -> Lookup[e, "Seq", Lookup[$iProvLabels[x], "Seq", 0]], "Reason" -> u[[2]]|>]]], Keys[old]];
  $iProvQuarantineX = Sort /@ newQ; $iProvCiteReach = cite; $iProvQuarantineDirty = False; $iProvIndexDirty = True;
  (* Inc4: 記録外の変更 (EntityDrift の Finding、重大度によらず撤回されていないもの) の carry の子孫は Stale (隔離ではない、再派生の候補、7.1 節) *)
  $iProvStaleX = Module[{st = <||>},
    Scan[Function[fid, Module[{f = $iProvFindingsX[fid], targets, seen = <||>, bag, i = 1, x},
        targets = Select[f["Targets"], iProvEntityIdQ[#] && KeyExistsQ[$iProvEntities, #] &];
        bag = Internal`Bag[targets]; Scan[(seen[#] = True) &, targets];
        While[i <= Internal`BagLength[bag], x = Internal`BagPart[bag, i]; i++;
          Scan[Function[y, If[! KeyExistsQ[seen, y], seen[y] = True; Internal`StuffBag[bag, y]; st[y] = Union[Lookup[st, y, {}], {fid}]]],
            Lookup[$iProvCarryOut, x, {}]]]]],
      Select[Keys[$iProvFindingsX], $iProvFindingsX[#]["Kind"] === "EntityDrift" &&
        Lookup[Lookup[$iProvResolutionsX, #, <||>], "Kind", None] =!= "FalsePositive" &]];
    st];
  <|"ActiveFindings" -> Length[active], "Quarantined" -> Length[newQ], "CiteOnly" -> Total[Values[cite]], "Stale" -> Length[$iProvStaleX]|>];

(* ============================================================
   V9 (文書 12 の 4.6 節、2026-11-13): 裏付けのラベル (Grounding)
   ============================================================
   claudecode のツールループは、回答ごとに裏付けの検査の結果を来歴の spool に書く (ProvGrounding)。service はそれを待ち行列で待たせ、
   回答の版 (LLMCall の結合が作る DerivedText) ができたら、その版に検証の主張 (ProvVerification、Property "Grounding"、
   Result = Grounded | Partial | Ungrounded | NotNeeded) として結び付ける。主張は版の内容 (BlobId) に束縛される。
   - ラベル Grounding (版ごと): 自分の主張が Ungrounded、または Ungrounded の版から carry 辺で届く → "Ungrounded"。
     それ以外は自分の主張の値。主張が無ければ "Unknown"。
   - 伝搬 (隔離と同じ到達の計算。用途の制限は隔離より弱い): Ungrounded の版と同じ内容の版すべてを起点に、carry 辺をたどる。
     次の版は通らない (そこで止まる): 所有者が確認した版 (OwnerReviewed)、自分の主張が Grounded の版 (自分でウェブの資料を取得して
     照合した回答)。
   - Usability は変えない。検索・RAG では下位に回して印を付け、公開では警告する (SourceVault_integrity.wl)。
   索引の状態 (graph.wxf) には足さない: 主張 ($iProvClaimsX) と carry 辺から、索引の Seq が進んだときに計算し直す。
   usability.wxf の Extras には、FE が読む小さな表 (内容の BlobId ごと・LogicalRef ごと) を足す。 *)
$iProvGroundingStatuses = {"Grounded", "Partial", "Ungrounded", "BackendUnavailable", "WebNotAvailable", "NotApplicable", "NotNeeded"};
$iProvGroundingKeys = {"SessionKey", "OutputSHA256", "FinalSHA256", "LLMCallOutputSHA256", "Status", "PartialReason", "Rule", "Searches", "SearchesWithResults",
  "SearchesRefused", "BackendFailures", "Fetched", "FetchFailed", "FetchRefused", "Internal", "FallbackSearches", "SentBack",
  "ClaimsChecked", "ClaimsSupported", "Cited", "CitedVerified", "AtUTC", "AtUnixMs", "Machine"};
(* 検索の障害・外部検索が使えない会話・検索のツールが無い接続も「外部で未確認」 *)
iProvGroundingClass[s_] := Switch[s, "Grounded", "Grounded", "Partial", "Partial", "NotNeeded", "NotNeeded",
  "Ungrounded" | "BackendUnavailable" | "WebNotAvailable" | "NotApplicable", "Ungrounded", _, "Unknown"];
(* 結び付く版が現れるのを待つ時間 (秒)。過ぎたら捨てて数える (GroundingUnbound) *)
If[! NumberQ[$SourceVaultProvGroundingHoldSeconds], $SourceVaultProvGroundingHoldSeconds = 3600];
(* 待ち行列の 1 件を、結び付ける版 (EntityId の列) に引き当てる *)
iProvGroundingTargets[rec_Association] := Module[{hexes, ids = {}, key, ms, acts, a},
  (* 1. 回答と同じ内容 (SHA-256) の、LLM が作った版 (最大 3 つ。同じ文面の回答が何度か出ることがある)。
        ループが返した回答の SHA-256 と、最後の LLMCall が台帳に書いた応答の SHA-256 の順に試す *)
  hexes = Select[ToLowerCase /@ Select[{Lookup[rec, "OutputSHA256", Null], Lookup[rec, "LLMCallOutputSHA256", Null]}, StringQ],
    StringMatchQ[#, RegularExpression["^[0-9a-f]{64}$"]] &];
  Scan[Function[hex, If[ids === {}, ids = Select[Lookup[$iProvBlobs, "blob:sha256:" <> hex, {}],
    MemberQ[{"DerivedText", "DerivedCode", "Answer"}, Lookup[Lookup[$iProvEntities, #, <||>], "Kind", None]] &]]], hexes];
  If[ids =!= {}, Return[Take[ids, -Min[3, Length[ids]]], Module]];
  (* 2. 内容が一致しないとき (ツールループが応答を整形した): 同じ SessionKey の、この記録の時刻までで最も新しい LLMGenerate の出力 *)
  key = Lookup[rec, "SessionKey", Null]; ms = Lookup[rec, "AtUnixMs", Null];
  If[! StringQ[key] || ! IntegerQ[ms], Return[{}, Module]];
  acts = Select[Lookup[$iProvLineage, key, {}], AssociationQ[#] && Lookup[#, "Kind", None] === "LLMGenerate" &&
    IntegerQ[Lookup[#, "AtMs", None]] && ms - 600000 <= #["AtMs"] <= ms + 1000 &];
  If[acts === {}, Return[{}, Module]];
  a = Lookup[$iProvActivities, Last[SortBy[acts, {#["AtMs"] &, #["Seq"] &}]]["ActivityId"], <||>];
  Select[First[#, None] & /@ Select[Lookup[a, "Outputs", {}], ListQ], StringQ[#] && KeyExistsQ[$iProvEntities, #] &]];
(* 待ち行列から、台帳に入れる主張 (ProvVerification) を作る。戻り値 <|"Items", "Keep" (まだ待つもの), "Bound", "Unbound" (待ち切れずに捨てた数)|> *)
iProvGroundingItems[nowAbs_] := Module[{items = {}, keep = {}, bound = 0, unbound = 0, hold = $SourceVaultProvGroundingHoldSeconds},
  iProvGroundingQueueEnsure[];
  Scan[Function[q, Module[{rec = Replace[Lookup[q, "Record", <||>], Except[_Association] -> <||>], gid = ToString @ Lookup[q, "EventId", ""], targets},
      targets = Quiet @ Check[iProvGroundingTargets[rec], {}];
      Which[
        ListQ[targets] && targets =!= {},
          bound++;
          MapIndexed[Function[{eid, ix}, With[{k = ToString[First[ix]]},
              AppendTo[items, <|"EventId" -> "gnd-" <> gid <> "-" <> k, "RecordText" -> iProvCanonText[
                <|"Type" -> "ProvVerification", "SchemaVersion" -> 1, "VerificationId" -> "ver-gnd-" <> gid <> "-" <> k,
                  "EntityId" -> eid, "BlobId" -> Lookup[Lookup[$iProvEntities, eid, <||>], "BlobId", Null],
                  "Property" -> "Grounding", "Result" -> iProvGroundingClass[Lookup[rec, "Status", None]],
                  "Verifier" -> <|"Kind" -> "Deterministic", "Name" -> "GroundingCheck", "Producer" -> "claudecode"|>,
                  "Details" -> DeleteCases[KeyDrop[rec, {"SessionKey", "OutputSHA256", "FinalSHA256", "LLMCallOutputSHA256", "Machine", "AtUTC", "AtUnixMs"}], Null],
                  "GroundingEventId" -> gid, "AtUTC" -> With[{t = Lookup[rec, "AtUTC", Null]}, If[StringQ[t], t, iProvAbsToIso[nowAbs]]],
                  "Machine" -> ToString @ Lookup[rec, "Machine", iProvMachine[]], "Producer" -> "service:grounding"|>]|>]]], targets],
        nowAbs - Lookup[q, "FirstSeenAbs", nowAbs] > hold, unbound++,
        True, AppendTo[keep, q]]]],
    $iProvGroundingQueue];
  <|"Items" -> Select[items, StringQ[#["RecordText"]] && ! iProvSeenQ[#["EventId"]] &], "Keep" -> keep, "Bound" -> bound, "Unbound" -> unbound|>];

(* 版ごとの自分の主張 (その版の内容に付いた、いちばん新しい Grounding の主張)。無ければ None *)
iProvGroundingOwn[id_String] := Module[{bid = Lookup[Lookup[$iProvEntities, id, <||>], "BlobId", Null], cs},
  cs = Select[Lookup[$iProvClaimsX, id, {}], Lookup[#, "Property", ""] === "Grounding" && Lookup[#, "BlobId", Null] === bid &];
  If[cs === {}, None, With[{c = Last[SortBy[cs, Lookup[#, "Seq", 0] &]]}, <|"Result" -> c["Result"], "Seq" -> Lookup[c, "Seq", 0]|>]]];
(* 所有者が、その主張より後に確認した版か *)
iProvOwnerReviewedSinceQ[id_String, seq_] := With[{bid = Lookup[Lookup[$iProvEntities, id, <||>], "BlobId", Null]},
  AnyTrue[Lookup[$iProvClaimsX, id, {}], Lookup[#, "Property", ""] === "OwnerReviewed" && TrueQ[Lookup[#, "Effective", False]] &&
    Lookup[#, "BlobId", Null] === bid && Lookup[#, "Seq", 0] > seq &]];
If[! AssociationQ[$iProvUngroundedX], $iProvUngroundedX = <||>];
If[! ValueQ[$iProvUngroundedSeq], $iProvUngroundedSeq = None];
(* Ungrounded の到達: EntityId -> 起点の版 (最大 5)。索引の Seq が進んだときだけ計算し直す *)
iProvUngroundedEnsure[] := Module[{seeds = <||>, reach = <||>, own},
  If[$iProvUngroundedSeq === $iProvIndexSeq && AssociationQ[$iProvUngroundedX], Return[$iProvUngroundedX, Module]];
  (* 起点: 自分の主張が Ungrounded で、その後に所有者が確認していない版。同じ内容のほかの版も起点にする *)
  Scan[Function[id, own = iProvGroundingOwn[id];
      If[AssociationQ[own] && own["Result"] === "Ungrounded" && ! iProvOwnerReviewedSinceQ[id, own["Seq"]],
        Scan[Function[x, If[KeyExistsQ[$iProvEntities, x] && ! iProvOwnerReviewedSinceQ[x, own["Seq"]], seeds[x] = True]],
          Union[{id}, Lookup[$iProvBlobs, Lookup[Lookup[$iProvEntities, id, <||>], "BlobId", ""], {}]]]]],
    Keys[$iProvClaimsX]];
  Scan[Function[s, Module[{seen = <|s -> True|>, bag = Internal`Bag[{s}], i = 1, x, o},
      reach[s] = Take[Union[Lookup[reach, s, {}], {s}], UpTo[5]];
      While[i <= Internal`BagLength[bag] && i < 200000,
        x = Internal`BagPart[bag, i]; i++;
        Scan[Function[y, If[! KeyExistsQ[seen, y],
            seen[y] = True;
            o = iProvGroundingOwn[y];
            (* 止まる所: 所有者が確認した版、自分の主張が Grounded の版 *)
            If[! (AssociationQ[o] && o["Result"] === "Grounded") && ! iProvOwnerReviewedSinceQ[y, 0],
              reach[y] = Take[Union[Lookup[reach, y, {}], {s}], UpTo[5]];
              Internal`StuffBag[bag, y]]]],
          Lookup[$iProvCarryOut, x, {}]]]]],
    Keys[seeds]];
  $iProvUngroundedX = reach; $iProvUngroundedSeq = $iProvIndexSeq;
  reach];
(* 版の実効の Grounding *)
iProvGroundingOf[id_String] := Module[{own = iProvGroundingOwn[id], un = iProvUngroundedEnsure[]},
  <|"Grounding" -> Which[
      KeyExistsQ[un, id], "Ungrounded",
      (* 自分の主張は Ungrounded だが、その後に所有者が確認した (機械では裏付けが取れていない。人が確かめた) *)
      AssociationQ[own] && own["Result"] === "Ungrounded", "OwnerReviewed",
      AssociationQ[own], own["Result"], True, "Unknown"],
    "Own" -> If[AssociationQ[own], own["Result"], Null],
    "Inherited" -> (KeyExistsQ[un, id] && ! (AssociationQ[own] && own["Result"] === "Ungrounded")),
    "UngroundedFrom" -> Lookup[un, id, {}]|>];
(* FE が読む小さな表: 内容 (BlobId) ごと・LogicalRef ごと (その LogicalRef の最新の版が Ungrounded / Partial のとき) *)
iProvGroundingExtras[] := Module[{un = iProvUngroundedEnsure[], ub = <||>, ul = <||>, pb = <||>, e, own},
  Scan[Function[x, e = Lookup[$iProvEntities, x, <||>];
      If[StringQ[Lookup[e, "BlobId", Null]], ub[e["BlobId"]] = True];
      With[{lr = Lookup[e, "LogicalRef", Null]}, If[StringQ[lr] && Last[Lookup[$iProvLogical, lr, {}], None] === x, ul[lr] = True]]], Keys[un]];
  Scan[Function[id, own = iProvGroundingOwn[id];
      If[AssociationQ[own] && own["Result"] === "Partial" && ! KeyExistsQ[un, id],
        With[{b = Lookup[Lookup[$iProvEntities, id, <||>], "BlobId", Null]}, If[StringQ[b] && ! KeyExistsQ[ub, b], pb[b] = True]]]], Keys[$iProvClaimsX]];
  <|"UngroundedByBlob" -> ub, "UngroundedByLogical" -> ul, "PartialByBlob" -> pb,
    "Counts" -> <|"Ungrounded" -> Length[un], "UngroundedSeeds" -> Count[Keys[un], k_ /; MemberQ[un[k], k]], "Partial" -> Length[pb]|>|>];

(* ---- 永続化 (graph.wxf の LabelRecords) ---- *)
iProvLabelState[] := <|"LabelIds" -> $iProvLabelIds, "Findings" -> $iProvFindingsX, "Resolutions" -> $iProvResolutionsX,
  "Releases" -> $iProvReleasesX, "Authz" -> $iProvAuthzX, "Claims" -> $iProvClaimsX, "VerifierReg" -> $iProvVerifierRegX,
  "CarryOut" -> $iProvCarryOut, "CiteOut" -> $iProvCiteOut, "Quarantine" -> $iProvQuarantineX, "CiteReach" -> $iProvCiteReach,
  "RegistryIssues" -> $iProvRegistryIssues, "TicketNonces" -> $iProvTicketNonces, "InstructionUses" -> $iProvInstrUseLog, "Stale" -> $iProvStaleX,
  "Parents" -> $iProvParentsX, "Scores" -> $iProvScoreX, "ScoreSeeds" -> $iProvScoreSeeds, "ScoreStale" -> $iProvScoreStale, "ScoreCycles" -> $iProvScoreCycles|>;
iProvLabelStateLoad[a_] := Module[{g = If[AssociationQ[a], a, <||>], as},
  as = Function[k, With[{v = Lookup[g, k, <||>]}, If[AssociationQ[v], v, <||>]]];
  $iProvLabelIds = as["LabelIds"]; $iProvFindingsX = as["Findings"]; $iProvResolutionsX = as["Resolutions"];
  $iProvReleasesX = as["Releases"]; $iProvAuthzX = as["Authz"]; $iProvClaimsX = as["Claims"]; $iProvVerifierRegX = as["VerifierReg"];
  $iProvCarryOut = as["CarryOut"]; $iProvCiteOut = as["CiteOut"]; $iProvQuarantineX = as["Quarantine"]; $iProvCiteReach = as["CiteReach"];
  $iProvRegistryIssues = With[{v = Lookup[g, "RegistryIssues", {}]}, If[ListQ[v], v, {}]];
  $iProvTicketNonces = as["TicketNonces"]; $iProvQuarantineDirty = False;
  $iProvInstrUseLog = With[{v = Lookup[g, "InstructionUses", {}]}, If[ListQ[v], v, {}]]; $iProvStaleX = as["Stale"];
  $iProvParentsX = as["Parents"]; $iProvScoreX = as["Scores"]; $iProvScoreStale = as["ScoreStale"];
  $iProvScoreSeeds = With[{v = Lookup[g, "ScoreSeeds", {}]}, If[ListQ[v], v, {}]];
  $iProvScoreCycles = With[{v = Lookup[g, "ScoreCycles", {}]}, If[ListQ[v], v, {}]];];

(* ---- FE が読む小さな表 (usability.wxf の Extras)。検索フィルタと LoadVerify はこれだけを読む ---- *)
iProvUsabilityExtras[] := Module[{byL = <||>, byB = <||>, acc, unkL = <||>, unkB = <||>, usableB = <||>, authz = <||>, now = AbsoluteTime[]},
  KeyValueMap[Function[{x, fids}, With[{e = Lookup[$iProvEntities, x, <||>]},
      If[StringQ[Lookup[e, "LogicalRef", Null]], byL[e["LogicalRef"]] = Union[Lookup[byL, e["LogicalRef"], {}], fids]];
      If[StringQ[Lookup[e, "BlobId", Null]], byB[e["BlobId"]] = Union[Lookup[byB, e["BlobId"], {}], fids]]]], $iProvQuarantineX];
  acc = Association @ KeyValueMap[Function[{fid, r}, If[r["Kind"] === "AcceptedRisk", fid -> KeyTake[r, {"Purposes", "ExpiresAbs"}], Nothing]], $iProvResolutionsX];
  (* 派生物の Unknown: その LogicalRef の最新の版が派生物で Unknown / その内容の派生物の版がすべて Unknown *)
  KeyValueMap[Function[{x, eff}, With[{e = Lookup[$iProvEntities, x, <||>]},
      If[MemberQ[$iProvDerivedKinds, Lookup[e, "Kind", None]],
        Switch[Lookup[eff, "Usability", "Unknown"],
          "Unknown", If[StringQ[Lookup[e, "BlobId", Null]], unkB[e["BlobId"]] = True],
          "Usable", If[StringQ[Lookup[e, "BlobId", Null]], usableB[e["BlobId"]] = True],
          _, Null]]]], Select[$iProvEffective, Lookup[#, "Usability", ""] =!= "Recorded" &]];
  unkB = KeySelect[unkB, ! KeyExistsQ[usableB, #] &];
  KeyValueMap[Function[{lr, ids}, With[{last = Last[ids, None]},
      If[StringQ[last] && MemberQ[$iProvDerivedKinds, Lookup[Lookup[$iProvEntities, last, <||>], "Kind", None]] &&
          Lookup[Lookup[$iProvEffective, last, <||>], "Usability", "Unknown"] === "Unknown", unkL[lr] = True]]], $iProvLogical];
  KeyValueMap[Function[{aid, a}, If[! TrueQ[Lookup[a, "Revoked", False]] && StringQ[Lookup[a, "BlobId", Null]] &&
        (! NumberQ[Lookup[a, "ExpiresAbs", Null]] || a["ExpiresAbs"] > now),
      authz[a["BlobId"]] = Append[Lookup[authz, a["BlobId"], {}],
        <|"AuthId" -> aid, "Purpose" -> a["Purpose"], "EntityId" -> Lookup[a, "EntityId", Null], "ExpiresAbs" -> Lookup[a, "ExpiresAbs", Null],
          (* 2026-11-11 (レビュー 20261111 F02): LoadVerify が機とプロファイルを照合する *)
          "Scope" -> With[{sc = Lookup[a, "Scope", <||>]}, If[AssociationQ[sc], sc, <||>]]|>]]], $iProvAuthzX];
  <|"Format" -> "SourceVaultProvUsabilityExtras/1",
    "Quarantine" -> <|"ByEntity" -> $iProvQuarantineX, "ByLogical" -> byL, "ByBlob" -> byB|>,
    "Accepted" -> acc, "UnknownDerived" -> <|"ByLogical" -> unkL, "ByBlob" -> unkB|>, "Authorizations" -> authz,
    "VerifierRegistryDigest" -> Hash[KeySort[$iProvVerifierRegX], "SHA256", "HexString"],
    (* V9: 裏付けのラベル (外部で未確認の版・一部だけ確認できた版)。検索のフィルタと公開の関所が FE で読む *)
    "Grounding" -> With[{g = Quiet @ Check[iProvGroundingExtras[], $Failed]}, If[AssociationQ[g], g,
      <|"UngroundedByBlob" -> <||>, "UngroundedByLogical" -> <||>, "PartialByBlob" -> <||>, "Counts" -> <||>|>]],
    (* Inc5: Finding の状態 (Medium 以上)。Issue を閉じるときの検査 (9.3 節) が FE で読む *)
    "FindingStatus" -> Association @ KeyValueMap[Function[{fid, f}, If[MemberQ[{"Medium", "High", "Critical"}, f["Severity"]],
        fid -> <|"Status" -> Lookup[Lookup[$iProvResolutionsX, fid, <||>], "Kind", "Open"], "Severity" -> f["Severity"], "Kind" -> f["Kind"]|>, Nothing]],
      $iProvFindingsX],
    "Counts" -> <|"ActiveFindings" -> Count[Keys[$iProvFindingsX], _?iProvFindingActiveQ], "Quarantined" -> Length[$iProvQuarantineX],
      "CiteOnly" -> Total[Values[$iProvCiteReach]], "RegistryIssues" -> Length[$iProvRegistryIssues], "Authorizations" -> Total[Length /@ Values[authz]]|>|>];

(* FE 側: usability.wxf の Extras (meta の IndexSeq が進んだときだけ読み直す)。使えなければ $Failed *)
iProvUsabilityExtrasCached[] := Module[{meta = iProvReadMetaCached[], ok},
  If[meta === $Failed, Return[$Failed]];
  ok = iProvUsabilityEnsure[meta];
  If[! TrueQ[ok], Return[$Failed]];
  <|"Extras" -> Lookup[$iProvUsabilityCache, "Extras", <||>], "IndexSeq" -> Lookup[$iProvUsabilityCache, "IndexSeq", 0],
    "Rebuilding" -> TrueQ[Lookup[meta, "Rebuilding", False]], "ChainState" -> Lookup[meta, "ChainState", "OK"]|>];

(* 稼働中のカーネルで読み直したとき (索引は読み込み済みで Inc3 の変数が無い) は、次に索引を使うときに読み直させる *)
If[! (AssociationQ[$iProvLabelIds] && AssociationQ[$iProvFindingsX] && AssociationQ[$iProvResolutionsX] && AssociationQ[$iProvReleasesX] &&
      AssociationQ[$iProvAuthzX] && AssociationQ[$iProvClaimsX] && AssociationQ[$iProvVerifierRegX] && AssociationQ[$iProvCarryOut] &&
      AssociationQ[$iProvCiteOut] && AssociationQ[$iProvQuarantineX] && AssociationQ[$iProvCiteReach] && ListQ[$iProvRegistryIssues] &&
      AssociationQ[$iProvTicketNonces] && ListQ[$iProvInstrUseLog] && AssociationQ[$iProvStaleX] &&
      AssociationQ[$iProvParentsX] && AssociationQ[$iProvScoreX] && ListQ[$iProvScoreSeeds] && AssociationQ[$iProvScoreStale] && ListQ[$iProvScoreCycles]),
  iProvLabelStateLoad[<||>]; $iProvIndexLoaded = False];

(* 実効ラベル (11.2 節 SourceVaultIntegrityLabel の本体)。索引を読む (再生はしない) *)
iProvLabelOf[id_String] := Module[{e, l, f, bid, claims, q},
  If[! iProvIndexEnsureRead[], Return[Missing["IndexUnavailable"]]];
  e = Lookup[$iProvEntities, id, None];
  If[! AssociationQ[e], Return[Missing["NotFound", id]]];
  l = Lookup[$iProvLabels, id, <||>]; f = Lookup[$iProvEffective, id, <||>]; bid = Lookup[e, "BlobId", Null];
  claims = Select[Lookup[$iProvClaimsX, id, {}], Lookup[#, "BlobId", Null] === bid &];
  q = Lookup[$iProvQuarantineX, id, {}];
  <|"EntityId" -> id, "Kind" -> Lookup[e, "Kind", Null], "BlobId" -> bid, "LogicalRef" -> Lookup[e, "LogicalRef", Null],
    "PrivacyLevel" -> Lookup[l, "PrivacyLevel", Null], "Origin" -> Lookup[l, "Origin", <||>], "Completeness" -> Lookup[l, "Completeness", "Unknown"],
    "Claims" -> claims,
    "Quarantine" -> <|"Quarantined" -> q =!= {}, "FindingIds" -> q,
      "Findings" -> (Join[<|"FindingId" -> #|>, KeyTake[Lookup[$iProvFindingsX, #, <||>], {"Kind", "Severity", "Targets"}],
        <|"Resolution" -> Lookup[Lookup[$iProvResolutionsX, #, <||>], "Kind", Null]|>] & /@ q)|>,
    "Authorizations" -> KeyValueMap[Join[<|"AuthId" -> #1|>, KeyTake[#2, {"Purpose", "Revoked", "ExpiresAbs", "RequiredClaims"}]] &,
      Select[$iProvAuthzX, Lookup[#, "BlobId", None] === bid && StringQ[bid] &]],
    "Usability" -> Lookup[f, "Usability", "Unknown"], "UsabilityReason" -> Lookup[f, "Reason", Null],
    "Stale" -> KeyExistsQ[$iProvStaleX, id], "StaleBy" -> Lookup[$iProvStaleX, id, {}],
    (* V9 (文書 12 の 4.6 節): 裏付けのラベル。Grounded | Partial | Ungrounded | NotNeeded | Unknown。Usability は変えない *)
    With[{g = Quiet @ Check[iProvGroundingOf[id], $Failed]},
      If[AssociationQ[g], Sequence @@ {"Grounding" -> g["Grounding"], "GroundingOwn" -> g["Own"], "GroundingInherited" -> g["Inherited"],
        "UngroundedFrom" -> g["UngroundedFrom"]}, "Grounding" -> "Unknown"]],
    (* Inc5: レビュー順の点数 (経験的な並べ替え用。確率でも安全性の尺度でもない)。計算中は Null *)
    "ReviewScore" -> If[KeyExistsQ[$iProvScoreStale, id], Null, Lookup[$iProvScoreX, id, Null]], "ScoreStale" -> KeyExistsQ[$iProvScoreStale, id],
    "ObservedSeq" -> $iProvIndexSeq|>];

(* ============================================================
   Inc5 (03 v0.4 §8.3〜8.4、2026-11-10): レビュー順の点数。どれから確認するかを並べるためだけの経験的な値で、
   隔離・認可・公開の判断には使わない。差分計算は「種とその子孫」をトポロジカル順に計算し直す (合流でも全再計算と一致)。
   循環は強連結成分を縮約し、成分内は固定点 (FeedbackLoop)。予算を超えたら残りを持ち越して Stale にする
   ============================================================ *)
$iProvRoleWeight = <|"Instruction" -> 1., "Code" -> 1., "Quote" -> 0.95, "AttachmentOf" -> 0.9, "Contains" -> 0.9, "Context" -> 0.85, "Cite" -> 0.3|>;
$iProvOriginBase = <|"OwnerOnly" -> 0., "ModelOverOwner" -> 0.2, "ExternalDerived" -> 0.35, "Unknown" -> 0.5|>;
$iProvSeverityWeight = <|"Info" -> 0.1, "Low" -> 0.3, "Medium" -> 0.5, "High" -> 0.8, "Critical" -> 1.|>;
If[! NumberQ[$SourceVaultProvScoreBudgetSeconds], $SourceVaultProvScoreBudgetSeconds = 2.];

(* 純関数 (試験で直接使う): parentsF[x] -> {{親, Role}..}、childrenF[x] -> {子..}、p0F[x]、vF[x] (0.5 | 1)、prev = 現在の点数。
   seeds とその全子孫を計算し直し、<|"P" -> 計算した節点の新しい値, "Deferred" -> 予算で持ち越した節点, "Cycles" -> {成分..}, "Computed"|> *)
iProvScoreOf[x_, parentsF_, p0F_, vF_, val_] := Max[p0F[x],
  Max[0., (Lookup[$iProvRoleWeight, #[[2]], 0.85] * vF[x] * val[#[[1]]]) & /@ parentsF[x]]];
iProvScoreCompute[parentsF_, childrenF_, p0F_, vF_, prev_Association, seeds_List, deadline_] := Module[
  {aff = <||>, bag, i = 1, x, indeg = <||>, queue, qi = 1, out = <||>, val, done = <||>, left, deferred = {}, cycles = {}, g, comps, order, n = 0},
  (* 影響を受ける節点 = 種とその全子孫 *)
  bag = Internal`Bag[DeleteDuplicates[seeds]]; Scan[(aff[#] = True) &, DeleteDuplicates[seeds]];
  While[i <= Internal`BagLength[bag], x = Internal`BagPart[bag, i]; i++;
    Scan[If[! KeyExistsQ[aff, #], aff[#] = True; Internal`StuffBag[bag, #]] &, childrenF[x]]];
  (* 親の値: 計算済みならその値、影響の外なら前の値 (影響の外の値は変わらない) *)
  val = Function[p, If[KeyExistsQ[out, p], out[p], Lookup[prev, p, If[KeyExistsQ[aff, p], 0., p0F[p]]]]];
  (* 入次数は「異なる親」の数で数える (同じ親が役割違いで 2 本の辺を持つことがある。辺で数えると 0 にならず全節点が循環扱いになる) *)
  Scan[Function[y, indeg[y] = Length[DeleteDuplicates[Select[parentsF[y][[All, 1]], KeyExistsQ[aff, #] && # =!= y &]]]], Keys[aff]];
  queue = Internal`Bag[Select[Keys[aff], indeg[#] === 0 && ! MemberQ[parentsF[#][[All, 1]], #] &]];
  While[qi <= Internal`BagLength[queue],
    x = Internal`BagPart[queue, qi]; qi++;
    If[AbsoluteTime[] > deadline, deferred = Select[Keys[aff], ! KeyExistsQ[done, #] &]; Break[]];
    out[x] = iProvScoreOf[x, parentsF, p0F, vF, val]; done[x] = True; n++;
    Scan[Function[c, If[KeyExistsQ[aff, c] && c =!= x, indeg[c] = indeg[c] - 1;
        If[indeg[c] === 0 && ! KeyExistsQ[done, c] && ! MemberQ[parentsF[c][[All, 1]], c], Internal`StuffBag[queue, c]]]], DeleteDuplicates[childrenF[x]]]];
  If[deferred =!= {}, Return[<|"P" -> out, "Deferred" -> deferred, "Cycles" -> {}, "Computed" -> n|>]];
  (* 残り = 循環とその下流。強連結成分を縮約したグラフのトポロジカル順に、成分内は固定点。所属は連想配列で引く (総当たりにしない) *)
  left = Select[Keys[aff], ! KeyExistsQ[done, #] &];
  If[left =!= {},
    Module[{leftA = AssociationThread[left -> True], edges, compOf},
      edges = DeleteDuplicates @ Flatten[Function[c, (DirectedEdge[#, c] & /@ Select[DeleteDuplicates[parentsF[c][[All, 1]]], KeyExistsQ[leftA, #] &])] /@ left];
      g = Graph[left, edges];
      comps = ConnectedComponents[g];
      compOf = Association @ Flatten[MapIndexed[Function[{cm, ix}, (# -> First[ix]) & /@ cm], comps]];
      order = TopologicalSort[Graph[Range[Length[comps]],
        DeleteDuplicates @ Cases[edges, DirectedEdge[a_, b_] /; compOf[a] =!= compOf[b] :> DirectedEdge[compOf[a], compOf[b]]]]]];
    Scan[Function[ci, Module[{comp = comps[[ci]], it = 0, changed = True},
        If[Length[comp] > 1 || MemberQ[parentsF[First[comp]][[All, 1]], First[comp]], AppendTo[cycles, Sort[comp]]];
        Scan[(out[#] = p0F[#]) &, comp];
        While[changed && it <= Length[comp] + 1, it++; changed = False;
          Scan[Function[c, With[{nv = iProvScoreOf[c, parentsF, p0F, vF, val]}, If[nv =!= out[c], out[c] = nv; changed = True]]], comp]];
        n += Length[comp]]], order]];
  <|"P" -> out, "Deferred" -> {}, "Cycles" -> cycles, "Computed" -> n|>];

(* 索引の上の p0 と v *)
iProvFindingWeightByEntity[] := Module[{w = <||>},
  KeyValueMap[Function[{fid, f}, With[{rk = Lookup[Lookup[$iProvResolutionsX, fid, <||>], "Kind", None]},
      If[rk === None || rk === "Acknowledged",
        Scan[Function[e, w[e] = Max[Lookup[w, e, 0.], Lookup[$iProvSeverityWeight, f["Severity"], 0.5]]],
          DeleteDuplicates @ Join[Select[f["Targets"], iProvEntityIdQ], Flatten[Lookup[$iProvBlobs, Select[f["Targets"], iProvBlobIdQ], {}]]]]]]],
    $iProvFindingsX];
  w];
iProvScoreP0[fw_][x_] := Max[Lookup[$iProvOriginBase, Lookup[Lookup[Lookup[$iProvLabels, x, <||>], "Origin", <||>], "OriginClass", "Unknown"], 0.5], Lookup[fw, x, 0.]];
iProvScoreV[x_] := With[{bid = Lookup[Lookup[$iProvEntities, x, <||>], "BlobId", Null]},
  If[AnyTrue[Lookup[$iProvClaimsX, x, {}], TrueQ[#["Effective"]] && #["VerifierKind"] === "Deterministic" && #["Result"] === "Pass" && #["BlobId"] === bid &], 0.5, 1.]];
iProvScoreParents[x_] := Lookup[$iProvParentsX, x, {}];
iProvScoreChildren[x_] := Union[Lookup[$iProvCarryOut, x, {}], Lookup[$iProvCiteOut, x, {}]];
iProvScoreSeed[ids_] := ($iProvScoreSeeds = Join[$iProvScoreSeeds, Select[Flatten[{ids}], StringQ]]);
(* 保存の直前 (予算つき)。持ち越した節点は Stale、次の保存で続きから *)
iProvScoreUpdate[budget_] := Module[{seeds = DeleteDuplicates[Select[$iProvScoreSeeds, KeyExistsQ[$iProvEntities, #] &]], r, fw},
  If[seeds === {}, Return[<|"Computed" -> 0, "Deferred" -> 0|>]];
  fw = iProvFindingWeightByEntity[];
  r = iProvScoreCompute[iProvScoreParents, iProvScoreChildren, iProvScoreP0[fw], iProvScoreV, $iProvScoreX, seeds, AbsoluteTime[] + budget];
  KeyValueMap[($iProvScoreX[#1] = N[#2]) &, r["P"]];
  $iProvScoreStale = Join[KeyDrop[$iProvScoreStale, Keys[r["P"]]], AssociationThread[r["Deferred"] -> True]];
  $iProvScoreSeeds = r["Deferred"];
  If[r["Cycles"] =!= {}, $iProvScoreCycles = Take[DeleteDuplicates[Join[$iProvScoreCycles, r["Cycles"]]], -200]];
  $iProvIndexDirty = True;
  <|"Computed" -> r["Computed"], "Deferred" -> Length[r["Deferred"]], "Cycles" -> Length[r["Cycles"]]|>];
iProvReviewTop[k_Integer] := (If[! iProvIndexEnsureRead[], Return[$Failed]];
  Take[SortBy[Select[Keys[$iProvScoreX], ! KeyExistsQ[$iProvScoreStale, #] && ! AnyTrue[Lookup[$iProvClaimsX, #, {}], #["Property"] === "OwnerReviewed" &] &],
    -$iProvScoreX[#] &], UpTo[k]]);

(* ---- Inc5: 健全性の指標 (表 8.1) と KHI (参考値)。活性な版 = 直近 90 日に作成されたか、入力として使われた版 ---- *)
iProvFindingEntities[f_Association] := DeleteDuplicates @ Join[Select[f["Targets"], iProvEntityIdQ], Flatten[Lookup[$iProvBlobs, Select[f["Targets"], iProvBlobIdQ], {}]]];
iProvIndicators[] := Module[{now = AbsoluteTime[], active, byKind, unres, unresInstr, oldest, recov, khiNum = 0., khiDen = 0., dist = <||>, qByKind = <||>,
    top, debtOld, meta = iProvReadMeta[]},
  If[! iProvIndexEnsureRead[], Return[$Failed]];
  active = Select[Keys[$iProvLabels], With[{l = $iProvLabels[#]},
    (NumberQ[Lookup[l, "CreatedAbs", Null]] && now - l["CreatedAbs"] <= 90*86400) || Lookup[l, "Uses", 0] > 0] &];
  byKind = GroupBy[Select[active, ! TrueQ[Lookup[$iProvLabels[#], "Backfilled", False]] &], Lookup[$iProvLabels[#], "Kind", "?"] &];
  byKind = Map[<|"Total" -> Length[#], "Complete" -> Count[#, x_ /; Lookup[$iProvLabels[x], "Completeness", ""] === "Complete"],
      "Ratio" -> N[Count[#, x_ /; Lookup[$iProvLabels[x], "Completeness", ""] === "Complete"]/Max[1, Length[#]]]|> &, byKind];
  unres = Select[Keys[$iProvFindingsX], MemberQ[$iProvSevereLevels, $iProvFindingsX[#]["Severity"]] &&
    MemberQ[{None, "Acknowledged"}, Lookup[Lookup[$iProvResolutionsX, #, <||>], "Kind", None]] &];
  unresInstr = Select[unres, AnyTrue[iProvFindingEntities[$iProvFindingsX[#]], Lookup[Lookup[$iProvEntities, #, <||>], "Kind", None] === "Instruction" &] &];
  oldest = Max[0, (now - #) & /@ Select[iProvIsoToAbs[ToString @ $iProvFindingsX[#]["OpenedAtUTC"]] & /@ unres, NumberQ]]/86400.;
  recov = Select[KeyValueMap[Function[{fid, r}, If[MemberQ[{"FalsePositive", "Remediated"}, r["Kind"]] && NumberQ[Lookup[r, "AtAbs", Null]] && KeyExistsQ[$iProvFindingsX, fid],
      With[{o = iProvIsoToAbs[ToString @ $iProvFindingsX[fid]["OpenedAtUTC"]]}, If[NumberQ[o], (r["AtAbs"] - o)/3600., Nothing]], Nothing]], $iProvResolutionsX], NumberQ];
  Scan[Function[x, With[{l = $iProvLabels[x], p = If[KeyExistsQ[$iProvScoreStale, x], Null, Lookup[$iProvScoreX, x, Null]]},
      With[{u = Log[1. + Lookup[l, "Uses", 0]] + 1. + If[Lookup[l, "Kind", ""] === "Instruction", 1., 0.] +
          If[NumericQ[Lookup[l, "PrivacyLevel", Null]] && l["PrivacyLevel"] >= 0.5, 0.5, 0.]},
        khiDen += u; khiNum += u * If[NumberQ[p], p, Lookup[$iProvOriginBase, Lookup[Lookup[l, "Origin", <||>], "OriginClass", "Unknown"], 0.5]]];
      With[{k = Lookup[l, "Kind", "?"], oc = Lookup[Lookup[l, "Origin", <||>], "OriginClass", "Unknown"]},
        dist[k] = Append[Lookup[dist, k, <||>], oc -> Lookup[Lookup[dist, k, <||>], oc, 0] + 1];
        If[KeyExistsQ[$iProvQuarantineX, x], qByKind[k] = Lookup[qByKind, k, 0] + 1]]]], active];
  top = iProvReviewTop[20];
  debtOld = If[top === {} || ! ListQ[top], 0, Max[0, (now - #) & /@ Select[Lookup[$iProvLabels[#], "CreatedAbs", Null] & /@ top, NumberQ]]/86400.];
  <|"ActiveVersions" -> Length[active], "CompletenessByKind" -> byKind,
    "UnresolvedSevere" -> <|"Count" -> Length[unres], "Instruction" -> Length[unresInstr], "OldestDays" -> N[oldest], "FindingIds" -> Take[unres, UpTo[20]]|>,
    "RecoveryHoursMedian" -> If[recov === {}, Null, N[Median[recov]]],
    "KHI" -> If[khiDen > 0, N[100 (1 - khiNum/khiDen)], Null],
    "Distribution" -> dist, "QuarantinedByKind" -> qByKind,
    "ReviewDebt" -> <|"Top" -> If[ListQ[top], Length[Select[top, Lookup[$iProvScoreX, #, 0] >= 0.5 &]], 0], "OldestDays" -> N[debtOld]|>,
    "Freshness" -> If[AssociationQ[meta], <|"Lag" -> Max[0, Lookup[meta, "DurableSeq", 0] - Lookup[meta, "IndexSeq", 0]], "CarryOver" -> TrueQ[Lookup[meta, "CarryOver", False]],
      "ScoreStale" -> Length[$iProvScoreStale], "ScoreSeedsPending" -> Length[$iProvScoreSeeds]|>, <||>],
    "Cycles" -> Length[$iProvScoreCycles], "IndexSeq" -> $iProvIndexSeq|>];
(* 隔離されていた版 (Finding が Activity より前) の利用と、Unknown の版の自動処理での利用 (sinceSeq より後の Activity) *)
iProvContaminatedUses[sinceSeq_Integer] := Module[{q = {}, unk = {}},
  If[! iProvIndexEnsureRead[], Return[$Failed]];
  KeyValueMap[Function[{aid, a}, If[Lookup[a, "Seq", 0] > sinceSeq,
      Scan[Function[pr, If[ListQ[pr] && StringQ[pr[[1]]],
          With[{fids = Lookup[$iProvQuarantineX, pr[[1]], {}], auto = MemberQ[{"ServedToContext", "Execute", "Publish", "Authorize"}, a["Kind"]] || pr[[2]] === "Instruction"},
            If[AnyTrue[fids, Lookup[Lookup[$iProvFindingsX, #, <||>], "Seq", Infinity] < a["Seq"] &],
              AppendTo[q, <|"ActivityId" -> aid, "Kind" -> a["Kind"], "Role" -> pr[[2]], "EntityId" -> pr[[1]], "Automatic" -> auto, "Outcome" -> Lookup[a, "Outcome", "Succeeded"]|>]];
            If[(MemberQ[{"Execute"}, a["Kind"]] || MemberQ[{"Service"}, Lookup[a, "ActorKind", ""]]) &&
                Lookup[Lookup[$iProvEffective, pr[[1]], <||>], "Usability", ""] === "Unknown" && ! KeyExistsQ[$iProvQuarantineX, pr[[1]]],
              AppendTo[unk, <|"ActivityId" -> aid, "Kind" -> a["Kind"], "EntityId" -> pr[[1]]|>]]]]], Lookup[a, "Inputs", {}]]]],
    $iProvActivities];
  <|"Quarantined" -> Select[q, #["Outcome"] =!= "Blocked" &], "Unknown" -> unk, "IndexSeq" -> $iProvIndexSeq|>];
(* 影響範囲 (11.2 節 BlastRadius): Finding の対象から carry 辺で届く版の数・Kind 別・Instruction を含むか・公開済みの版 *)
iProvBlastRadius[fid_String] := Module[{f = Lookup[$iProvFindingsX, fid, None], seen = <||>, bag, i = 1, x, desc, pub},
  If[! iProvIndexEnsureRead[] || ! AssociationQ[f], Return[Missing["NotFound", fid]]];
  bag = Internal`Bag[iProvFindingEntities[f]]; Scan[(seen[#] = True) &, iProvFindingEntities[f]];
  While[i <= Internal`BagLength[bag], x = Internal`BagPart[bag, i]; i++;
    Scan[If[! KeyExistsQ[seen, #], seen[#] = True; Internal`StuffBag[bag, #]] &, Lookup[$iProvCarryOut, x, {}]]];
  desc = Complement[Keys[seen], iProvFindingEntities[f]];
  pub = Select[Keys[$iProvActivities], $iProvActivities[#]["Kind"] === "Publish" && Lookup[$iProvActivities[#], "Outcome", "Succeeded"] =!= "Blocked" &&
    IntersectingQ[Select[$iProvActivities[#]["Inputs"], ListQ][[All, 1]], Keys[seen]] &];
  <|"FindingId" -> fid, "Kind" -> f["Kind"], "Severity" -> f["Severity"], "Targets" -> Length[iProvFindingEntities[f]], "Descendants" -> Length[desc],
    "ByKind" -> Counts[Lookup[Lookup[$iProvEntities, #, <||>], "Kind", "?"] & /@ desc],
    "IncludesInstruction" -> AnyTrue[Keys[seen], Lookup[Lookup[$iProvEntities, #, <||>], "Kind", None] === "Instruction" &],
    "Published" -> Length[pub], "Resolution" -> Lookup[Lookup[$iProvResolutionsX, fid, <||>], "Kind", "Open"]|>];
iProvFindingsSince[sinceSeq_Integer] := (If[! iProvIndexEnsureRead[], Return[$Failed]];
  <|"Rows" -> KeyValueMap[Join[<|"FindingId" -> #1|>, #2, <|"Resolution" -> Lookup[Lookup[$iProvResolutionsX, #1, <||>], "Kind", "Open"],
      "AcceptedExpiresAbs" -> Lookup[Lookup[$iProvResolutionsX, #1, <||>], "ExpiresAbs", Null],
      "MaxPL" -> Max[0.3, Select[Lookup[Lookup[$iProvLabels, #, <||>], "PrivacyLevel", 0.3] & /@ iProvFindingEntities[#2], NumericQ]]|>] &,
    Select[$iProvFindingsX, Lookup[#, "Seq", 0] > sinceSeq &]], "AllResolutions" -> $iProvResolutionsX, "IndexSeq" -> $iProvIndexSeq|>);

(* ---- Inc4 (2026-11-10): 検証器が読む一覧 ---- *)
(* sinceSeq より後に入った Entity (kinds が All でなければその種類だけ)。前の版は同じ LogicalRef のひとつ前 *)
iProvEntityRow[id_String] := Module[{e = Lookup[$iProvEntities, id, <||>], l = Lookup[$iProvLabels, id, <||>], lr, prev = Null},
  lr = Lookup[e, "LogicalRef", Null];
  If[StringQ[lr], With[{ids = Lookup[$iProvLogical, lr, {}]}, With[{p = FirstPosition[ids, id]},
    If[! MissingQ[p] && p[[1]] > 1, prev = ids[[p[[1]] - 1]]]]]];
  <|"EntityId" -> id, "Seq" -> Lookup[e, "Seq", 0], "Kind" -> Lookup[e, "Kind", Null], "BlobId" -> Lookup[e, "BlobId", Null], "LogicalRef" -> lr,
    "PrivacyLevel" -> Lookup[l, "PrivacyLevel", Null], "OriginClass" -> Lookup[Lookup[l, "Origin", <||>], "OriginClass", "Unknown"],
    "Usability" -> Lookup[Lookup[$iProvEffective, id, <||>], "Usability", "Unknown"], "Uses" -> Length[Lookup[e, "UsedBy", {}]],
    "Previous" -> prev, "PreviousBlobId" -> If[StringQ[prev], Lookup[Lookup[$iProvEntities, prev, <||>], "BlobId", Null], Null],
    "Latest" -> (! StringQ[lr] || Last[Lookup[$iProvLogical, lr, {id}], id] === id)|>];
iProvEntitiesSince[sinceSeq_Integer, kinds_] := (If[! iProvIndexEnsureRead[], Return[$Failed]];
  <|"Rows" -> (iProvEntityRow /@ Keys[Select[$iProvEntities, Lookup[#, "Seq", 0] > sinceSeq && (kinds === All || MemberQ[kinds, Lookup[#, "Kind", None]]) &]]),
    "IndexSeq" -> $iProvIndexSeq|>);
iProvEntitySample[n_Integer] := (If[! iProvIndexEnsureRead[], Return[$Failed]];
  <|"Rows" -> (iProvEntityRow /@ If[Length[$iProvEntities] <= n, Keys[$iProvEntities], RandomSample[Keys[$iProvEntities], n]]), "Total" -> Length[$iProvEntities],
    "IndexSeq" -> $iProvIndexSeq|>);
(* Quote / Cite の辺 (入力 → 出力)。daily の CitationIntegrity が読む *)
iProvQuoteCiteEdges[] := Module[{out = {}},
  If[! iProvIndexEnsureRead[], Return[$Failed]];
  KeyValueMap[Function[{aid, a}, With[{outs = Select[Lookup[a, "Outputs", {}][[All, 1]], StringQ]},
      Scan[Function[pr, If[ListQ[pr] && MemberQ[{"Quote", "Cite"}, pr[[2]]] && StringQ[pr[[1]]],
          Scan[AppendTo[out, <|"ActivityId" -> aid, "Role" -> pr[[2]], "Source" -> pr[[1]], "Target" -> #, "Seq" -> Lookup[a, "Seq", 0]|>] &, outs]]],
        Lookup[a, "Inputs", {}]]]], $iProvActivities];
  out];
(* Publish の Activity (PublishUnusable)。入力の版の現在の利用可否と、その版の隔離を起こした Finding の Seq *)
(* 2026-11-11 (F04): 公開の意図 (Outcome Approved) の結果 ("Result")。SourceVaultIntegrityPublishOutcome の記録 (IntentActivity を持つ Publish) のうち、
   所有者・service が残した最後のもの (モデル・MCP の記録は数えない)。結果の記録の行は "IntentActivity" を持つ *)
iProvPublishActivities[sinceSeq_Integer] := Module[{rows, results = <||>},
  If[! iProvIndexEnsureRead[], Return[$Failed]];
  KeyValueMap[Function[{aid, a}, With[{ia = Lookup[a, "IntentActivity", Null]},
      If[StringQ[ia] && MemberQ[{"Owner", "Service"}, Lookup[a, "ActorKind", ""]] && Lookup[a, "Seq", 0] >= Lookup[Lookup[results, ia, <||>], "Seq", -1],
        results[ia] = <|"Seq" -> Lookup[a, "Seq", 0], "Result" -> Lookup[a, "Outcome", "Unknown"]|>]]],
    Select[$iProvActivities, Lookup[#, "Kind", None] === "Publish" && StringQ[Lookup[#, "IntentActivity", Null]] &]];
  rows = KeyValueMap[Function[{aid, a}, <|"ActivityId" -> aid, "Seq" -> Lookup[a, "Seq", 0], "Outcome" -> Lookup[a, "Outcome", "Succeeded"],
      "IntentActivity" -> Lookup[a, "IntentActivity", Null], "Result" -> Lookup[Lookup[results, aid, <||>], "Result", Null],
      "Inputs" -> Map[Function[pr, With[{e = pr[[1]]}, <|"EntityId" -> e,
          "Usability" -> Lookup[Lookup[$iProvEffective, e, <||>], "Usability", "Unknown"],
          "FindingSeqs" -> (Lookup[Lookup[$iProvFindingsX, #, <||>], "Seq", 0] & /@ Lookup[$iProvQuarantineX, e, {}])|>]],
        Select[Lookup[a, "Inputs", {}], ListQ[#] && StringQ[First[#]] &]]|>],
    Select[$iProvActivities, Lookup[#, "Kind", None] === "Publish" && Lookup[#, "Seq", 0] > sinceSeq &]];
  <|"Rows" -> rows, "IndexSeq" -> $iProvIndexSeq|>];
(* Role Instruction で使われた入力 (7.1 節 InstructionAuthorization)。sinceSeq より後の Activity だけ *)
iProvInstructionUses[sinceSeq_Integer] := Module[{out},
  If[! iProvIndexEnsureRead[], Return[$Failed]];
  out = Map[Function[u, With[{e = Lookup[$iProvEntities, u["EntityId"], <||>], l = Lookup[$iProvLabels, u["EntityId"], <||>]},
      <|"ActivityId" -> u["ActivityId"], "Seq" -> u["Seq"], "ActivityKind" -> Lookup[Lookup[$iProvActivities, u["ActivityId"], <||>], "Kind", Null],
        "EntityId" -> u["EntityId"], "BlobId" -> Lookup[e, "BlobId", Null], "LogicalRef" -> Lookup[e, "LogicalRef", Null],
        "OriginClass" -> Lookup[Lookup[l, "Origin", <||>], "OriginClass", "Unknown"],
        "Usability" -> Lookup[Lookup[$iProvEffective, u["EntityId"], <||>], "Usability", "Unknown"]|>]],
    Select[$iProvInstrUseLog, AssociationQ[#] && Lookup[#, "Seq", 0] > sinceSeq &]];
  <|"Uses" -> out, "IndexSeq" -> $iProvIndexSeq|>];
iProvRegistryState[] := (iProvIndexEnsureRead[];
  <|"Issues" -> $iProvRegistryIssues, "Verifiers" -> $iProvVerifierRegX, "IndexSeq" -> $iProvIndexSeq,
    "AttemptsThisKernel" -> $iProvRegistryAttemptCount|>);

(* ============================================================
   Inc1b (03 v0.4 §4.8 / §12.1〜12.3、2026-11-10): Merkle 根・feeds (checkpoint の写し・射影・証言)・他機の checkpoint 照合
   ============================================================ *)
$iProvMerkleAlg = "RFC6962-SHA256(LineHash)";
$iProvEmptyRoot = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
iProvBytesHex[b_ByteArray] := StringJoin[IntegerString[#, 16, 2] & /@ Normal[b]];
iProvMerkleLeaf[lh_String] := Hash[Join[ByteArray[{0}], StringToByteArray[lh, "UTF-8"]], "SHA256", "ByteArray"];
iProvMerkleNode[a_ByteArray, b_ByteArray] := Hash[Join[ByteArray[{1}], a, b], "SHA256", "ByteArray"];
(* 下から 2 つずつ節にし、奇数個の最後は 1 段上へそのまま上げる (RFC 6962 の MTH と同じ根になる) *)
SourceVaultProvMerkleRoot[hashes_List] := Module[{level},
  If[hashes === {}, Return[$iProvEmptyRoot]];
  If[! AllTrue[hashes, StringQ],
    Return[Failure["ProvBadArguments", <|"MessageTemplate" -> "SourceVaultProvMerkleRoot[{lineHash..}] takes a list of LineHash strings."|>]]];
  level = iProvMerkleLeaf /@ hashes;
  While[Length[level] > 1,
    level = Join[iProvMerkleNode @@@ Partition[level, 2], If[OddQ[Length[level]], {Last[level]}, {}]]];
  "sha256:" <> iProvBytesHex[First[level]]];
SourceVaultProvMerkleRoot[___] := Failure["ProvBadArguments", <|"MessageTemplate" -> "SourceVaultProvMerkleRoot[{lineHash..}]"|>];
(* Seq -> LineHash の対応から [a, b] の根 (欠落した Seq は除く。checkpoint を書いたときと同じ規則) *)
iProvMerkleOf[seqHash_Association, a_Integer, b_Integer] :=
  SourceVaultProvMerkleRoot[DeleteCases[Lookup[seqHash, Range[a, b], Missing[]], _Missing]];

(* checkpoint の区間 [firstSeq, lastSeq] の LineHash。前の checkpoint の時点の位置 (CheckpointCursor) が合えばそこから先だけ読む *)
iProvLeafHashes[firstSeq_Integer, lastSeq_Integer, meta_Association] := Module[
  {cur = Lookup[meta, "CheckpointCursor", Null], ld = iProvLedgerDir[], files = iProvLedgerFiles[], useCursor, idx, out = <||>, off, size, ba, text, p, qs},
  If[ld === $Failed, Return[out]];
  useCursor = AssociationQ[cur] && Lookup[cur, "Seq", -1] === firstSeq - 1 && StringQ[Lookup[cur, "File", None]] &&
    IntegerQ[Lookup[cur, "Offset", None]] && FileExistsQ[FileNameJoin[{ld, cur["File"]}]] &&
    Quiet @ Check[FileByteCount[FileNameJoin[{ld, cur["File"]}]], -1] >= cur["Offset"];
  idx = If[useCursor, FirstPosition[FileNameTake /@ files, cur["File"], {1}, {1}][[1]], 1];
  Do[
    off = If[useCursor && FileNameTake[f] === cur["File"], cur["Offset"], 0];
    size = Quiet @ Check[FileByteCount[f], 0];
    If[size > off,
      ba = iProvReadRange[f, off, size - off];
      text = If[ByteArrayQ[ba], Quiet @ Check[ByteArrayToString[ba, "UTF-8"], $Failed], $Failed];
      If[StringQ[text],
        Scan[Function[ln,
            qs = iProvQuickSeq[ln];
            If[IntegerQ[qs] && firstSeq <= qs <= lastSeq,
              p = iProvParseLedgerLine[ln];
              If[AssociationQ[p], out[p["Seq"]] = p["LineHash"]]]],
          StringSplit[text, "\n"]]]],
    {f, Drop[files, idx - 1]}];
  (* カーソルの位置が古い (連鎖の再開・手での修復で台帳が縮んだ等) と区間の先頭を読み落とす。先頭の行が無ければ全体を読み直す *)
  If[useCursor && ! KeyExistsQ[out, firstSeq], Return[iProvLeafHashes[firstSeq, lastSeq, KeyDrop[meta, "CheckpointCursor"]]]];
  out];

(* ---- feeds の置き場 (PrivateVault/provenance/feeds/<machine>/、書き手は各機 1 つ) ---- *)
If[! AssociationQ[$iProvFeedStats], $iProvFeedStats = <|"Syncs" -> 0, "CopyFailed" -> 0, "WriteFailed" -> 0|>];
iProvFeedsRoot[] := With[{pv = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
  If[StringQ[pv] && pv =!= "", FileNameJoin[{pv, "provenance", "feeds"}], $Failed]];
iProvFeedName[] := iProvSafeName[ToString @ iProvMachine[]];
iProvFeedDir[] := With[{r = iProvFeedsRoot[]}, If[r === $Failed, $Failed, iProvEnsureDir[FileNameJoin[{r, iProvFeedName[]}]]]];
iProvFeedCheckpointCanon[c_Association] := iProvCanonText[KeyDrop[c, {"Mac", "SyncMac"}]];
(* 同期鍵 (Sync) の MAC。鍵が無ければ Null (写しは書くが他機は真正性を確かめられない) *)
iProvSyncMacOf[text_String] := With[{m = iProvMac["Sync", StringToByteArray[text, "UTF-8"]]}, If[m === $Failed, Null, m["Mac"]]];
iProvSyncMacCheck[c_Association, canon_String] := With[{m = Lookup[c, "SyncMac", Null]},
  If[! StringQ[m], "Missing", iProvVerifyMac[m, StringToByteArray[canon, "UTF-8"]]]];
iProvCpCore[c_] := If[AssociationQ[c], KeyTake[c, {"FirstSeq", "LastSeq", "LastLineHash", "MerkleRoot"}], <||>];
iProvSameCheckpointQ[a_, b_] := Lookup[a, "LastLineHash", None] === Lookup[b, "LastLineHash", None] &&
  (! StringQ[Lookup[a, "MerkleRoot", None]] || ! StringQ[Lookup[b, "MerkleRoot", None]] || a["MerkleRoot"] === b["MerkleRoot"]);
iProvLocalCheckpointOKQ[c_Association] := iProvVerifyMac[ToString @ Lookup[c, "Mac", ""], StringToByteArray[iProvCheckpointCanon[c], "UTF-8"]] === "OK";
iProvAppendText[path_String, text_String] := Module[{strm},
  If[iProvEnsureDir[DirectoryName[path]] === $Failed, Return[$Failed]];
  strm = Quiet @ OpenAppend[path, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  Quiet @ Check[(BinaryWrite[strm, StringToByteArray[text, "UTF-8"]]; Close[strm]; path), (Quiet @ Close[strm]; $Failed)]];
$iProvFeedDegradedKinds = {"PeerCheckpointMissing", "PeerCheckpointCorrupt", "FeedCheckpointCorrupt", "FeedWriteFailed"};
iProvFinding[kind_String, peer_, file_, seq_, detail_] := <|"Kind" -> kind, "Seq" -> seq, "File" -> file, "Line" -> Null, "Detail" -> detail,
  "Peer" -> peer, "Health" -> If[MemberQ[$iProvFeedDegradedKinds, kind], "Degraded", "Failing"]|>;

(* checkpoint を書いた直後の写し (自機の MAC が合うものだけ) *)
iProvFeedCopyCheckpoint[localPath_String, cp_Association] := Module[{fd = iProvFeedDir[], dest},
  If[fd === $Failed, $iProvFeedStats["CopyFailed"]++; Return["Unavailable"]];
  dest = FileNameJoin[{fd, "checkpoints", FileNameTake[localPath]}];
  If[FileExistsQ[dest], Return["Exists"]];
  If[iProvWriteJSONAtomic[dest, Append[cp, "SyncMac" -> iProvSyncMacOf[iProvFeedCheckpointCanon[cp]]]] === $Failed,
    $iProvFeedStats["CopyFailed"]++; "Failed", "Copied"]];

(* ---- SyncId (版ごとの乱数。内容から計算しない。対応は同期しない LocalState の index/syncids.wxf) ---- *)
If[! ValueQ[$iProvSyncIds], $iProvSyncIds = None];
If[! ValueQ[$iProvSyncIdsDirty], $iProvSyncIdsDirty = False];
iProvSyncIdsPath[] := iProvIndexPath["syncids.wxf"];
iProvSyncIdsEnsure[] := If[! AssociationQ[$iProvSyncIds],
  With[{a = iProvReadWXF[iProvSyncIdsPath[]]}, $iProvSyncIds = If[AssociationQ[a], a, <||>]]; $iProvSyncIdsDirty = False];
iProvSyncIdsSave[] := If[AssociationQ[$iProvSyncIds] && TrueQ[$iProvSyncIdsDirty],
  If[iProvWriteWXFAtomic[iProvSyncIdsPath[], $iProvSyncIds] =!= $Failed, $iProvSyncIdsDirty = False]];
iProvSyncIdOf[id_String] := (iProvSyncIdsEnsure[];
  If[KeyExistsQ[$iProvSyncIds, id], $iProvSyncIds[id],
    With[{s = "s-" <> IntegerString[RandomInteger[{0, 2^128 - 1}], 16, 32]}, $iProvSyncIds[id] = s; $iProvSyncIdsDirty = True; s]]);
iProvProjectableQ[id_] := StringQ[id] && With[{pl = Lookup[Lookup[$iProvLabels, id, <||>], "PrivacyLevel", Null]}, NumericQ[pl] && pl < 0.5];

(* ---- 射影 (表 12.1 の既定: Kind・OriginClass・Usability・SyncId・関係。PL < 0.5 の版だけ。BlobId・EntityId・LogicalRef・本文は出さない) ---- *)
iProvProjection[from_Integer, to_Integer] := Module[{eids, aids, lines = {}, maxPL = 0., nE = 0, nA = 0, kinds = Select[Flatten[{$SourceVaultProvSyncDigestKinds}], StringQ]},
  eids = SortBy[Select[Keys[$iProvEntities], With[{s = Lookup[$iProvEntities[#], "Seq", 0]}, IntegerQ[s] && from < s <= to] &], $iProvEntities[#]["Seq"] &];
  Scan[Function[id, If[iProvProjectableQ[id], Module[{l = $iProvLabels[id], rec},
      rec = <|"T" -> "Entity", "SyncId" -> iProvSyncIdOf[id], "Kind" -> Lookup[l, "Kind", Null],
        "OriginClass" -> Lookup[Lookup[l, "Origin", <||>], "OriginClass", "Unknown"],
        "Usability" -> Lookup[Lookup[$iProvEffective, id, <||>], "Usability", "Unknown"], "PrivacyLevel" -> N[l["PrivacyLevel"]]|>;
      (* 照合用の SyncDigest は所有者が許した種類だけ (同期鍵の鍵付き digest。平文の BlobId は出さない) *)
      If[MemberQ[kinds, Lookup[l, "Kind", None]] && StringQ[Lookup[$iProvEntities[id], "BlobId", None]],
        With[{d = iProvSyncMacOf[$iProvEntities[id]["BlobId"]]}, If[StringQ[d], rec["SyncDigest"] = d]]];
      maxPL = Max[maxPL, rec["PrivacyLevel"]]; nE++;
      AppendTo[lines, iProvCanonText[rec]]]]], eids];
  aids = SortBy[Select[Keys[$iProvActivities], With[{s = Lookup[$iProvActivities[#], "Seq", 0]}, IntegerQ[s] && from < s <= to] &], $iProvActivities[#]["Seq"] &];
  Scan[Function[id, Module[{a = $iProvActivities[id], all, ins, outs, rec},
      all = Join[Lookup[a, "Inputs", {}], Lookup[a, "Outputs", {}]];
      ins = Select[Lookup[a, "Inputs", {}], iProvProjectableQ[First[#]] &];
      outs = Select[Lookup[a, "Outputs", {}], iProvProjectableQ[First[#]] &];
      (* 射影できる版が 1 つも無い処理は出さない (高 PL の版だけを扱った処理の存在も出さない) *)
      If[ins =!= {} || outs =!= {},
        rec = <|"T" -> "Activity", "SyncId" -> iProvSyncIdOf[id], "Kind" -> Lookup[a, "Kind", Null],
          "Inputs" -> (<|"SyncId" -> iProvSyncIdOf[#[[1]]], "Role" -> #[[2]]|> & /@ ins),
          "Outputs" -> (<|"SyncId" -> iProvSyncIdOf[#[[1]]], "Role" -> #[[2]]|> & /@ outs),
          "Complete" -> (Length[ins] + Length[outs] === Length[all])|>;
        nA++; AppendTo[lines, iProvCanonText[rec]]]]], aids];
  <|"Lines" -> lines, "MaxPL" -> maxPL, "Entities" -> nE, "Activities" -> nA|>];
iProvPruneProjection[fd_String] := Module[{cutoff = AbsoluteTime[] - 86400 $SourceVaultProvFeedRetentionDays, n = 0},
  Scan[Function[f, With[{a = iProvIsoToAbs[FileBaseName[f] <> "T00:00:00Z"]},
      If[NumberQ[a] && a < cutoff, Quiet @ DeleteFile[f]; If[! FileExistsQ[f], n++]]]],
    FileNames["*.jsonl", FileNameJoin[{fd, "projection"}]]];
  n];

(* ---- 他機の feeds: checkpoint の写しを見た記録 (LocalState/provenance/peers/<machine>.json、同期しない) と比べる ----
   2026-11-11: 比べるのは項目ごと (iProvPeerEntryCore)。見た記録は JSON に書くとキーが並べ替わる (iProvCanonText) ので、連想全体の
   SameQ では中身が同じでも 2 回目以降が必ず食い違いになり、同期鍵の照合が通る写しに PeerCheckpointChanged (Failing) が出ていた *)
iProvPeerEntryCore[x_Association] := KeySort[AssociationMap[Lookup[x, #, Null] &, {"File", "FirstSeq", "LastSeq", "MerkleRoot", "LastLineHash"}]];
iProvPeerEntryCore[_] := <||>;
iProvPeerCheck[peer_String, pdir_String] := Module[
  {storePath, store, files, findings = {}, cur = <||>, stats = <|"Checkpoints" -> 0, "New" -> 0, "MacOK" -> 0, "MacUnverified" -> 0|>, maxSeq, prevMax, missing},
  storePath = With[{d = iProvDir["peers"]}, If[d === $Failed, $Failed, FileNameJoin[{d, iProvSafeName[peer] <> ".json"}]]];
  store = If[storePath === $Failed, $Failed, iProvReadJSON[storePath]];
  If[! AssociationQ[store], store = <|"Format" -> "SourceVaultProvPeerWitness/1", "Peer" -> peer, "Checkpoints" -> <||>, "MaxSeq" -> 0|>];
  If[! AssociationQ[Lookup[store, "Checkpoints", None]], store["Checkpoints"] = <||>];
  files = Sort @ FileNames["*.json", FileNameJoin[{pdir, "checkpoints"}]];
  Do[Module[{c = iProvReadJSON[f], key = FileNameTake[f], mv, entry, old},
      stats["Checkpoints"]++;
      If[! AssociationQ[c] || ! IntegerQ[Lookup[c, "LastSeq", None]],
        AppendTo[findings, iProvFinding["PeerCheckpointCorrupt", peer, key, Null, <||>]]; Continue[]];
      mv = iProvSyncMacCheck[c, iProvFeedCheckpointCanon[c]];
      Switch[mv,
        "OK", stats["MacOK"]++,
        "Mismatch" | "BadFormat",
          (* 同期鍵を持たない書き換え: 記録には入れない *)
          AppendTo[findings, iProvFinding["PeerSyncMacMismatch", peer, key, c["LastSeq"], <|"Result" -> mv|>]]; Continue[],
        _, stats["MacUnverified"]++];
      entry = <|"File" -> key, "FirstSeq" -> Lookup[c, "FirstSeq", Null], "LastSeq" -> c["LastSeq"],
        "MerkleRoot" -> Lookup[c, "MerkleRoot", Null], "LastLineHash" -> Lookup[c, "LastLineHash", Null]|>;
      cur[key] = entry;
      old = Lookup[store["Checkpoints"], key, None];
      Which[
        (* 前に見た写しと食い違う = 他機の台帳・checkpoint・feeds の書き換え。記録 (最初に見た値) は上書きしない *)
        AssociationQ[old] && iProvPeerEntryCore[old] =!= iProvPeerEntryCore[entry],
          AppendTo[findings, iProvFinding["PeerCheckpointChanged", peer, key, c["LastSeq"],
            <|"Witnessed" -> KeyTake[old, {"LastSeq", "MerkleRoot", "LastLineHash"}], "Now" -> KeyTake[entry, {"LastSeq", "MerkleRoot", "LastLineHash"}]|>]],
        ! AssociationQ[old],
          store["Checkpoints", key] = Append[entry, "FirstSeenUTC" -> iProvNowIso[]]; stats["New"]++]],
    {f, files}];
  missing = Complement[Keys[store["Checkpoints"]], Keys[cur]];
  If[missing =!= {},
    AppendTo[findings, iProvFinding["PeerCheckpointMissing", peer, Null, Null, <|"Count" -> Length[missing], "Files" -> Take[missing, UpTo[10]]|>]]];
  maxSeq = Max[0, Cases[Values[cur], KeyValuePattern["LastSeq" -> s_Integer] :> s]];
  prevMax = With[{m = Lookup[store, "MaxSeq", 0]}, If[IntegerQ[m], m, 0]];
  If[maxSeq < prevMax,
    AppendTo[findings, iProvFinding["PeerRollback", peer, Null, maxSeq, <|"WitnessedMaxSeq" -> prevMax, "NowMaxSeq" -> maxSeq|>]]];
  store["MaxSeq"] = Max[prevMax, maxSeq]; store["UpdatedAtUTC"] = iProvNowIso[];
  If[Length[store["Checkpoints"]] > 5000, store["Checkpoints"] = Take[SortBy[store["Checkpoints"], Lookup[#, "LastSeq", 0] &], -5000]];
  If[storePath =!= $Failed, iProvWriteJSONAtomic[storePath, store]];
  <|"Findings" -> findings, "Stats" -> stats,
    "Latest" -> Take[SortBy[Values[store["Checkpoints"]], Lookup[#, "LastSeq", 0] &], -Min[20, Length[store["Checkpoints"]]]]|>];

(* ---- 他機の witness.json に書かれた自機の checkpoint を自機の checkpoint と比べる (表 4.5 の 3 行目: 他機が先に読んでいた場合) ---- *)
iProvWitnessOfMe[localCps_List, endSeq_Integer] := Module[{root = iProvFeedsRoot[], me = iProvFeedName[], out = {}, n = 0, peers},
  If[root === $Failed || ! DirectoryQ[root], Return[<|"Findings" -> {}, "Count" -> 0|>]];
  peers = Select[FileNames["*", root], DirectoryQ[#] && FileNameTake[#] =!= me &];
  Do[Module[{peer = FileNameTake[pd], w, mv, entries},
      w = iProvReadJSON[FileNameJoin[{pd, "witness.json"}]];
      If[! AssociationQ[w] || Lookup[w, "Format", ""] =!= "SourceVaultProvWitness/1", Continue[]];
      mv = iProvSyncMacCheck[w, iProvCanonText[KeyDrop[w, {"SyncMac"}]]];
      If[MemberQ[{"Mismatch", "BadFormat"}, mv],
        AppendTo[out, iProvFinding["PeerWitnessSyncMacMismatch", peer, "witness.json", Null, <|"Result" -> mv|>]]; Continue[]];
      entries = Select[Flatten[{Lookup[Lookup[w, "Peers", <||>], me, {}]}], AssociationQ];
      Scan[Function[e, Module[{s = Lookup[e, "LastSeq", None], matches},
          If[IntegerQ[s],
            n++;
            matches = Select[localCps, Lookup[#, "LastSeq", None] === s &];
            Which[
              matches === {} && s > endSeq,
                AppendTo[out, iProvFinding["WitnessBeyondLedger", peer, Lookup[e, "File", Null], s, <|"LedgerEndSeq" -> endSeq|>]],
              matches === {},
                AppendTo[out, iProvFinding["WitnessMismatch", peer, Lookup[e, "File", Null], s, <|"Reason" -> "LocalCheckpointMissing"|>]],
              NoneTrue[matches, iProvSameCheckpointQ[#, e] &],
                AppendTo[out, iProvFinding["WitnessMismatch", peer, Lookup[e, "File", Null], s,
                  <|"Reason" -> "CheckpointDiffers", "Witnessed" -> KeyTake[e, {"MerkleRoot", "LastLineHash"}]|>]]]]]],
        entries]],
    {pd, peers}];
  <|"Findings" -> out, "Count" -> n|>];

(* ---- 自機の feeds の写しと、台帳・自機の checkpoint を比べる (VerifyLedger から) ---- *)
iProvOwnFeedCompare[cps_List, cpNames_List, seqHash_Association, firstV_, endSeq_Integer, gapQ_] := Module[
  {fd, files, out = {}, n = 0, byName = AssociationThread[cpNames -> cps]},
  fd = With[{r = iProvFeedsRoot[]}, If[r === $Failed, $Failed, FileNameJoin[{r, iProvFeedName[], "checkpoints"}]]];
  If[fd === $Failed || ! DirectoryQ[fd], Return[<|"Findings" -> {}, "Count" -> 0|>]];
  files = Sort @ FileNames["*.json", fd];
  Do[Module[{c = iProvReadJSON[f], nm = FileNameTake[f], loc, s, mv, label},
      n++; label = "feeds/" <> iProvFeedName[] <> "/checkpoints/" <> nm;
      If[! AssociationQ[c] || ! IntegerQ[Lookup[c, "LastSeq", None]],
        AppendTo[out, iProvFinding["FeedCheckpointCorrupt", Null, label, Null, <||>]]; Continue[]];
      s = c["LastSeq"];
      mv = iProvSyncMacCheck[c, iProvFeedCheckpointCanon[c]];
      If[MemberQ[{"Mismatch", "BadFormat"}, mv], AppendTo[out, iProvFinding["FeedSyncMacMismatch", Null, label, s, <|"Result" -> mv|>]]];
      If[TrueQ[gapQ[s]], Continue[]];
      loc = Lookup[byName, nm, None];
      If[AssociationQ[loc],
        If[iProvCpCore[loc] =!= iProvCpCore[c],
          AppendTo[out, iProvFinding["FeedCheckpointMismatch", Null, label, s, <|"Local" -> iProvCpCore[loc], "Feed" -> iProvCpCore[c]|>]]],
        AppendTo[out, iProvFinding["LocalCheckpointMissing", Null, label, s, <||>]]];
      (* 写しが台帳の末尾より先の行を checkpoint している = checkpoint 済みの区間の削除 (自機の checkpoint を消しても写しが残る) *)
      If[s > endSeq, AppendTo[out, iProvFinding["FeedCheckpointBeyondLedger", Null, label, s, <|"LedgerEndSeq" -> endSeq|>]]];
      If[(! AssociationQ[loc] || iProvCpCore[loc] =!= iProvCpCore[c]) && StringQ[Lookup[c, "MerkleRoot", None]] &&
          IntegerQ[Lookup[c, "FirstSeq", None]] && IntegerQ[firstV] && c["FirstSeq"] >= firstV && s <= endSeq,
        If[iProvMerkleOf[seqHash, c["FirstSeq"], s] =!= c["MerkleRoot"],
          AppendTo[out, iProvFinding["FeedMerkleMismatch", Null, label, s, <|"FirstSeq" -> c["FirstSeq"]|>]]]]],
    {f, files}];
  <|"Findings" -> out, "Count" -> n|>];

iProvFeedsStatePath[] := With[{d = iProvHealthDir[]}, If[d === $Failed, $Failed, FileNameJoin[{d, "feeds-state.json"}]]];
SourceVaultProvFeedStatus[] := With[{s = iProvReadJSON[iProvFeedsStatePath[]]},
  If[AssociationQ[s] && Lookup[s, "Format", ""] === "SourceVaultProvFeedsState/1", s, Missing["NotFound"]]];

Options[SourceVaultProvSyncFeeds] = {"Projection" -> True, "Peers" -> True};
SourceVaultProvSyncFeeds[OptionsPattern[]] := Module[
  {auth, t0 = AbsoluteTime[], meta, root, me, fd, findings = {}, copied = 0, present = 0, proj = <|"Entities" -> 0, "Activities" -> 0|>,
   projStatus = "Skipped", pruned = 0, peersOut = <||>, witnessPeers = <||>, wf = <|"Findings" -> {}, "Count" -> 0|>, localFiles, localCps, status,
   writeFailed = False, state, from, to, pr, ok, manifest, witness, lastCp},
  auth = iProvAuth["SourceVaultProvSyncFeeds", $iProvOwnerService];
  If[FailureQ[auth], Return[auth]];
  meta = iProvReadMeta[];
  If[meta === $Failed, Return[Failure["ProvLocalStateUnresolved", <||>]]];
  $iProvFeedStats["Syncs"]++;
  root = iProvFeedsRoot[]; me = iProvFeedName[];
  fd = If[root === $Failed, $Failed, iProvEnsureDir[FileNameJoin[{root, me}]]];
  If[fd === $Failed,
    $iProvFeedStats["WriteFailed"]++;
    state = <|"Format" -> "SourceVaultProvFeedsState/1", "AtUTC" -> iProvNowIso[], "Machine" -> me, "Status" -> "FeedUnavailable",
      "Findings" -> {iProvFinding["FeedWriteFailed", Null, Null, Null, <|"Reason" -> If[root === $Failed, "PrivateVaultUnresolved", "FeedDirUnwritable"]|>]},
      "Own" -> <|"FeedSeq" -> Lookup[meta, "FeedSeq", 0], "WriteFailed" -> True|>, "Peers" -> <||>, "WitnessesOfMe" -> 0|>;
    iProvWriteJSONAtomic[iProvFeedsStatePath[], state];
    Return[Append[state, "Seconds" -> AbsoluteTime[] - t0]]];
  (* 1. checkpoint の写し: 無いものを写す (自機の MAC が合うものだけ)。既にある写しが自機の checkpoint と食い違えば Finding (上書きしない) *)
  localFiles = iProvCheckpointFiles[];
  Do[Module[{c = iProvReadJSON[lp], dest = FileNameJoin[{fd, "checkpoints", FileNameTake[lp]}], fc},
      If[! AssociationQ[c] || ! IntegerQ[Lookup[c, "LastSeq", None]], Continue[]];
      If[FileExistsQ[dest],
        present++; fc = iProvReadJSON[dest];
        If[AssociationQ[fc] && iProvCpCore[fc] =!= iProvCpCore[c],
          AppendTo[findings, iProvFinding["FeedCheckpointMismatch", Null, FileNameTake[lp], c["LastSeq"], <|"Local" -> iProvCpCore[c], "Feed" -> iProvCpCore[fc]|>]]],
        If[iProvLocalCheckpointOKQ[c],
          If[iProvWriteJSONAtomic[dest, Append[c, "SyncMac" -> iProvSyncMacOf[iProvFeedCheckpointCanon[c]]]] === $Failed, writeFailed = True, copied++]]]],
    {lp, localFiles}];
  (* 2. 射影 (前回の FeedSeq から索引の Seq まで)。SyncId の対応を先に保存してから追記し、最後に FeedSeq を進める *)
  If[TrueQ[OptionValue["Projection"]],
    meta = iProvIndexEnsure[meta];
    from = Lookup[meta, "FeedSeq", 0]; to = Lookup[meta, "IndexSeq", 0];
    If[! IntegerQ[from], from = 0];
    If[to > from,
      pr = iProvProjection[from, to];
      iProvSyncIdsSave[];
      ok = pr["Lines"] === {} || iProvAppendText[FileNameJoin[{fd, "projection", iProvDayTag[] <> ".jsonl"}], StringJoin[(# <> "\n") & /@ pr["Lines"]]] =!= $Failed;
      If[ok,
        meta["FeedSeq"] = to; meta["FeedMaxPL"] = Max[0.3, N @ Lookup[meta, "FeedMaxPL", 0.3], pr["MaxPL"]];
        proj = KeyTake[pr, {"Entities", "Activities"}]; projStatus = "Projected",
        writeFailed = True; projStatus = "WriteFailed"],
      projStatus = "UpToDate"];
    pruned = iProvPruneProjection[fd]];
  (* 3. 他機 *)
  localCps = Select[iProvReadJSON /@ localFiles, AssociationQ];
  If[TrueQ[OptionValue["Peers"]] && StringQ[root] && DirectoryQ[root],
    Do[If[DirectoryQ[pd] && FileNameTake[pd] =!= me,
        With[{r = iProvPeerCheck[FileNameTake[pd], pd]},
          findings = Join[findings, r["Findings"]]; peersOut[FileNameTake[pd]] = r["Stats"]; witnessPeers[FileNameTake[pd]] = r["Latest"]]],
      {pd, FileNames["*", root]}];
    wf = iProvWitnessOfMe[localCps, Lookup[meta, "DurableSeq", 0]];
    findings = Join[findings, wf["Findings"]]];
  (* 4. manifest と witness (同期鍵の SyncMac つき。manifest の PrivacyLevel は実数なので MAC の対象から外す) *)
  lastCp = If[localCps === {}, Null, iProvCpCore[Last[SortBy[localCps, Lookup[#, "LastSeq", 0] &]]]];
  manifest = <|"Format" -> "SourceVaultProvFeedManifest/1", "Machine" -> me, "UpdatedAtUTC" -> iProvNowIso[], "FeedSeq" -> Lookup[meta, "FeedSeq", 0],
    "CheckpointCopies" -> present + copied, "LastCheckpoint" -> lastCp, "ProjectionRetentionDays" -> Round[$SourceVaultProvFeedRetentionDays],
    "SyncDigestKinds" -> Select[Flatten[{$SourceVaultProvSyncDigestKinds}], StringQ],
    "SyncKeyId" -> With[{ks = iProvKeySpec["Sync"]}, If[AssociationQ[ks], ks["KeyId"], Null]],
    "PrivacyLevel" -> N @ Max[0.3, Lookup[meta, "FeedMaxPL", 0.3]]|>;
  manifest["SyncMac"] = iProvSyncMacOf[iProvCanonText[KeyDrop[manifest, {"SyncMac", "PrivacyLevel"}]]];
  If[iProvWriteJSONAtomic[FileNameJoin[{fd, "manifest.json"}], manifest] === $Failed, writeFailed = True];
  If[TrueQ[OptionValue["Peers"]],
    witness = <|"Format" -> "SourceVaultProvWitness/1", "Machine" -> me, "AtUTC" -> iProvNowIso[], "Peers" -> witnessPeers|>;
    witness["SyncMac"] = iProvSyncMacOf[iProvCanonText[KeyDrop[witness, {"SyncMac"}]]];
    If[iProvWriteJSONAtomic[FileNameJoin[{fd, "witness.json"}], witness] === $Failed, writeFailed = True]];
  If[writeFailed, $iProvFeedStats["WriteFailed"]++; AppendTo[findings, iProvFinding["FeedWriteFailed", Null, Null, Null, <|"Reason" -> "PartialWrite"|>]]];
  meta["LastFeedSyncAtUTC"] = iProvNowIso[];
  iProvWriteMeta[meta]; $iProvMetaCache = <||>;
  status = Which[AnyTrue[findings, #["Health"] === "Failing" &], "Failing", findings =!= {}, "Degraded", True, "OK"];
  state = <|"Format" -> "SourceVaultProvFeedsState/1", "AtUTC" -> iProvNowIso[], "Machine" -> me, "Status" -> status, "Findings" -> findings,
    "Own" -> <|"CheckpointsCopied" -> copied, "CheckpointsPresent" -> present, "Projection" -> projStatus, "Projected" -> proj, "Pruned" -> pruned,
      "FeedSeq" -> Lookup[meta, "FeedSeq", 0], "WriteFailed" -> writeFailed|>,
    "Peers" -> peersOut, "WitnessesOfMe" -> wf["Count"]|>;
  iProvWriteJSONAtomic[iProvFeedsStatePath[], state];
  Append[state, "Seconds" -> AbsoluteTime[] - t0]];
SourceVaultProvSyncFeeds[___] := Failure["ProvBadArguments", <|"MessageTemplate" -> "SourceVaultProvSyncFeeds[opts]"|>];

(* ============================================================
   Inc2 (03 v0.4 §6.1〜6.2、2026-11-10 第 4 週): SessionKey・供給点 (ServedToContext)・確定の関門・
   LLMCall の結合 (LLMGenerate)・Coverage
   ============================================================ *)
SourceVaultProvSessionKey[] := Module[{k = $SourceVaultProvSessionKey, p, sid},
  If[StringQ[k] && k =!= "", Return[k]];
  p = Quiet @ Check[SourceVault`SourceVaultPrincipal[], <||>];
  sid = If[AssociationQ[p], Lookup[p, "SessionId", None], None];
  If[StringQ[sid] && sid =!= "", "mcp|" <> sid, None]];

(* 供給点が同じ資料を繰り返し渡すときは Entity を作り直さない (LogicalRef・内容・Kind・PL が同じなら 1 時間はこのカーネルで再利用) *)
If[! AssociationQ[$iProvServedCache], $iProvServedCache = <||>];
$iProvServedCacheSeconds = 3600;
(* MCP の記録点が Block で {} に束縛すると、その間の ServedToContext の ActivityId が溜まる *)
If[! ValueQ[$iProvServedCollector], $iProvServedCollector = None];
If[! AssociationQ[$iProvServedStats], $iProvServedStats = <|"Calls" -> 0, "Entities" -> 0, "Reused" -> 0, "Failed" -> 0|>];

Options[SourceVaultProvServed] = {"SupplyPoint" -> "unknown", "Role" -> "Context", "SessionKey" -> Automatic, "MaxEntities" -> 50, "Channel" -> Automatic};
SourceVaultProvServed[specsIn_List, OptionsPattern[]] := Module[
  {specs, key, role, sp, chan, now = AbsoluteTime[], inputs = {}, eids = {}, reused = 0, maxPl = 0., act, failed = 0, aid},
  $iProvServedStats["Calls"]++;
  specs = Take[Select[specsIn, AssociationQ], UpTo[Max[1, OptionValue["MaxEntities"]]]];
  If[specs === {}, Return[<|"Status" -> "Skipped", "Reason" -> "NoEntities", "ActivityId" -> Null, "EntityIds" -> {}, "SessionKey" -> Null, "Reused" -> 0|>]];
  key = With[{k = OptionValue["SessionKey"]}, If[k === Automatic, SourceVaultProvSessionKey[], If[StringQ[k] && k =!= "", k, None]]];
  (* SessionKey も主体の束縛も無い呼び出し (FE のセルでの手動の検索、headless の試験) は「文脈へ渡した」ことにならないので記録しない。
     claudecode の turn (SessionKey)、MCP (主体 MCP)、tool loop (主体 Model)、NBExecuteHeldExpr (主体 OwnerCode) からの呼び出しは記録する *)
  If[key === None && ! TrueQ[Quiet @ Check[SourceVault`SourceVaultPrincipal["Bound"], False]],
    Return[<|"Status" -> "Skipped", "Reason" -> "NoSessionContext", "ActivityId" -> Null, "EntityIds" -> {}, "SessionKey" -> Null, "Reused" -> 0|>]];
  role = With[{r = OptionValue["Role"]}, If[MemberQ[$iProvInputRoles, r], r, "Context"]];
  sp = ToString @ OptionValue["SupplyPoint"];
  chan = With[{c = OptionValue["Channel"]}, If[StringQ[c], c, sp]];
  If[Length[$iProvServedCache] > 5000 || RandomReal[] < 0.01,
    $iProvServedCache = Select[$iProvServedCache, now - Lookup[#, "At", 0] < $iProvServedCacheSeconds &]];
  Scan[Function[s, Module[{pl, roleS, kind, bid, canon, size, ck, hit, spec2, r, ctx},
      pl = With[{p = Lookup[s, "PrivacyLevel", Automatic]}, If[NumericQ[p] && 0 <= p <= 1, N[p],
        If[NumberQ[SourceVault`$SourceVaultDefaultObjectPrivacyLevel], SourceVault`$SourceVaultDefaultObjectPrivacyLevel, 0.85]]];
      roleS = With[{r0 = Lookup[s, "Role", role]}, If[MemberQ[$iProvInputRoles, r0], r0, role]];
      kind = With[{k = Lookup[s, "Kind", "PrimarySource"]}, If[MemberQ[$iProvEntityKinds, k], k, "PrimarySource"]];
      (* 内容に届くなら BlobId を計算する (届かなければ ClaimedContentHash で Partial、何も無ければ BlobId 無し) *)
      {bid, canon, size} = Which[
        KeyExistsQ[s, "Content"] || KeyExistsQ[s, "ContentRef"],
          With[{b = SourceVaultProvBlobId[If[KeyExistsQ[s, "Content"], s["Content"], File[ToString @ s["ContentRef"]]], "Kind" -> Lookup[s, "ContentKind", Automatic]]},
            If[FailureQ[b], {Null, Null, Null}, {b["BlobId"], b["CanonVersion"], b["Size"]}]],
        iProvBlobIdQ[Lookup[s, "BlobId", None]], {s["BlobId"], Lookup[s, "CanonVersion", 1], Lookup[s, "Size", Null]},
        True, {Null, Null, Null}];
      ck = StringJoin[ToString @ Lookup[s, "LogicalRef", ""], "|", ToString[bid], "|", ToString @ Lookup[s, "ClaimedContentHash", ""], "|", kind, "|", ToString[pl]];
      hit = Lookup[$iProvServedCache, ck, None];
      If[AssociationQ[hit] && now - Lookup[hit, "At", 0] < $iProvServedCacheSeconds && iProvEntityIdQ[Lookup[hit, "EntityId", None]],
        AppendTo[inputs, <|"EntityId" -> hit["EntityId"], "Role" -> roleS|>]; AppendTo[eids, hit["EntityId"]]; reused++,
        ctx = With[{c = Lookup[s, "Context", <||>]}, If[AssociationQ[c], KeyDrop[c, $iProvForbiddenContextKeys], <||>]];
        spec2 = Join[KeyDrop[s, {"Content", "ContentRef", "ContentKind", "Role"}],
          <|"Kind" -> kind, "PrivacyLevel" -> pl, "Context" -> Join[ctx, <|"Channel" -> chan, "SupplyPoint" -> sp|>],
            "Completeness" -> If[StringQ[bid], "Complete", "Partial"]|>,
          Which[StringQ[bid], <|"BlobId" -> bid, "CanonVersion" -> canon, "Size" -> size|>,
                KeyExistsQ[s, "ClaimedContentHash"], <|"ClaimedContentHash" -> s["ClaimedContentHash"]|>,
                True, <|"ClaimedContentHash" -> "", "UnrecordedInputs" -> {"Content"}|>]];
        r = SourceVaultProvEntity[spec2];
        If[FailureQ[r], failed++,
          $iProvServedCache[ck] = <|"EntityId" -> r["EntityId"], "At" -> now|>;
          AppendTo[inputs, <|"EntityId" -> r["EntityId"], "Role" -> roleS|>]; AppendTo[eids, r["EntityId"]]]];
      If[pl > maxPl, maxPl = pl]]],
    specs];
  $iProvServedStats["Entities"] += Length[eids]; $iProvServedStats["Reused"] += reused; $iProvServedStats["Failed"] += failed;
  If[inputs === {}, Return[<|"Status" -> "Failed", "Reason" -> "NoEntityRecorded", "ActivityId" -> Null, "EntityIds" -> {}, "SessionKey" -> key, "Reused" -> reused|>]];
  act = SourceVaultProvActivity[Join[<|"Kind" -> "ServedToContext", "Inputs" -> inputs, "Outputs" -> {}, "InputsCompleteness" -> "Complete",
    "ExternalRefs" -> <|"SupplyPoint" -> sp, "Channel" -> chan|>,
    "Detail" -> <|"ServedCount" -> Length[inputs], "MaxPrivacyLevel" -> maxPl, "Reused" -> reused, "Failed" -> failed, "AtUnixMs" -> iProvNowUnixMs[]|>|>,
    If[StringQ[key], <|"SessionKey" -> key|>, <||>]]];
  If[FailureQ[act], $iProvServedStats["Failed"]++;
    Return[<|"Status" -> "Failed", "Reason" -> "ActivityEmitFailed", "ActivityId" -> Null, "EntityIds" -> eids, "SessionKey" -> key, "Reused" -> reused|>]];
  aid = act["ActivityId"];
  If[ListQ[$iProvServedCollector], AppendTo[$iProvServedCollector, aid]];
  <|"Status" -> "Spooled", "ActivityId" -> aid, "EntityIds" -> eids, "SessionKey" -> key, "Reused" -> reused, "Role" -> role, "MaxPrivacyLevel" -> maxPl|>];
SourceVaultProvServed[spec_Association, opts___] := SourceVaultProvServed[{spec}, opts];
SourceVaultProvServed[___] := <|"Status" -> "Skipped", "Reason" -> "BadArguments", "ActivityId" -> Null, "EntityIds" -> {}, "SessionKey" -> Null, "Reused" -> 0|>;

(* 確定を要求する関門の共通関数 (T-H2 / X-02): Authorize・Publish 相当は記録が確定していなければ進まない *)
SourceVaultProvRequireCommitted[idsIn_, timeout_: 5] := Module[{items = Flatten[{idsIn}], ids, bad, r},
  If[iProvLocalState[] === $Failed,
    Return[Failure["ProvenanceUnavailable", <|"Reason" -> "LocalStateUnresolved",
      "MessageTemplate" -> "The provenance ledger has no home (LocalState unresolved); operations that require committed records are stopped."|>]]];
  bad = Select[items, FailureQ[#] || MissingQ[#] || # === $Failed || # === None || # === Null ||
    (AssociationQ[#] && MemberQ[{"Failed", "Skipped"}, Lookup[#, "Status", "Spooled"]]) &];
  If[bad =!= {},
    Return[Failure["ProvenanceUnavailable", <|"Reason" -> "EmitFailed", "Count" -> Length[bad], "First" -> First[bad],
      "MessageTemplate" -> "A provenance record could not be spooled; operations that require committed records are stopped (03 v0.4 12.5)."|>]]];
  ids = DeleteDuplicates @ Flatten[Map[Function[x, Which[
      StringQ[x], {x},
      AssociationQ[x], Join[Select[{Lookup[x, "EntityId", None], Lookup[x, "ActivityId", None]}, StringQ],
        Select[Flatten[{Lookup[x, "EntityIds", {}], Lookup[x, "Outputs", {}]}], StringQ]],
      True, {}]], items]];
  If[ids === {}, Return[Failure["ProvenanceUnavailable", <|"Reason" -> "NoIds"|>]]];
  If[! AllTrue[ids, iProvEntityIdQ[#] || iProvActivityIdQ[#] &],
    Return[Failure["ProvenanceUnavailable", <|"Reason" -> "BadId", "Ids" -> Select[ids, ! (iProvEntityIdQ[#] || iProvActivityIdQ[#]) &]|>]]];
  r = SourceVaultProvAwaitCommitted[ids, If[NumericQ[timeout], timeout, 5]];
  If[r["Status"] === "Committed",
    <|"Status" -> "Committed", "Ids" -> ids, "Seconds" -> r["Seconds"]|>,
    Failure["ProvenanceNotCommitted", <|"Pending" -> r["Pending"], "Committed" -> r["Committed"], "Seconds" -> r["Seconds"],
      "MessageTemplate" -> "`1` provenance record(s) are not committed yet (spooled but not ingested, or the service is down); the operation waits for the ledger (03 v0.4 12.8).",
      "MessageParameters" -> {Length[r["Pending"]]}|>]]];

(* ModelRef (ModelManifest は Inc4): provider|model の sha256 の先頭 24 hex。claudecode (iClaudeProvModelRef) と同じ式 *)
iProvModelRefOf[provider_, model_] := If[StringQ[model] && model =!= "",
  "mdl-" <> StringTake[iProvSHAHex[ToLowerCase[ToString[provider]] <> "|" <> model], 24], Null];

(* 1 件の LLMCall を結合して LLMGenerate (+ 応答 Entity) の台帳項目にする *)
iProvJoinBuild[rec_Association, eid_String, nowAbs_] := Module[
  {key, atIso, atAbs, served = {}, inputs = {}, declared, joinedRoles, missing, compl, unrec, carry, inputLabels, contribs, taints, pl,
   outHex, oeid = Null, aid, modelRef, provider, actor, ent, blob, act, items = {}, via, win, llmMs},
  key = Lookup[rec, "SessionKey", Null]; If[! StringQ[key] || key === "", key = Null];
  atIso = ToString @ Lookup[rec, "AtUTC", ""]; atAbs = iProvIsoToAbs[atIso];
  If[! NumberQ[atAbs], atAbs = nowAbs; atIso = iProvAbsToIso[nowAbs]];
  provider = ToString @ Lookup[rec, "Provider", "unknown"];
  modelRef = With[{m = Lookup[rec, "ModelRef", Null]}, If[StringQ[m] && m =!= "", m, iProvModelRefOf[provider, Lookup[rec, "Model", Null]]]];
  via = ToString @ Lookup[rec, "Via", "unknown"];
  win = If[NumberQ[$SourceVaultProvJoinWindowSeconds], $SourceVaultProvJoinWindowSeconds, 1800];
  (* 前後関係はミリ秒で比べる: LLMCall より前 (同時刻を含む) で窓の内側の ServedToContext だけを結合する。tool loop の 1 往復目の
     LLMCall の直後に実行したツールの結果は、その 1 往復目には結合しない。ミリ秒の無い LLMCall (AtUTC だけ) はその秒の終わりとみなす *)
  llmMs = With[{m = Lookup[rec, "AtUnixMs", Null]}, If[IntegerQ[m], m, With[{im = iProvIsoToUnixMs[atIso]}, If[IntegerQ[im], im + 999, iProvNowUnixMs[]]]]];
  If[StringQ[key],
    served = Select[Lookup[$iProvLineage, key, {}], AssociationQ[#] && Lookup[#, "Kind", None] === "ServedToContext" &&
      IntegerQ[Lookup[#, "AtMs", None]] && llmMs - 1000 win <= #["AtMs"] <= llmMs &];
    inputs = DeleteDuplicatesBy[Flatten[Function[s, With[{a = Lookup[$iProvActivities, s["ActivityId"], <||>]},
        Select[Map[<|"EntityId" -> #[[1]], "Role" -> #[[2]]|> &, Lookup[a, "Inputs", {}]],
          StringQ[#["EntityId"]] && KeyExistsQ[$iProvEntities, #["EntityId"]] && StringQ[#["Role"]] &]]] /@ served, 1], #["EntityId"] &]];
  declared = Select[Flatten[{Lookup[rec, "DeclaredInputs", {}]}], StringQ];
  joinedRoles = DeleteDuplicates[#["Role"] & /@ inputs];
  missing = Complement[declared, joinedRoles];
  compl = Which[inputs === {}, "Unknown", missing === {}, "Complete", True, "Partial"];
  unrec = DeleteDuplicates @ Join[Select[Flatten[{Lookup[rec, "UnrecordedInputs", {}]}], StringQ], missing, If[inputs === {}, {"Inputs"}, {}]];
  carry = Select[inputs, MemberQ[{"Quote", "Context", "Instruction", "Code", "AttachmentOf", "Contains"}, #["Role"]] &];
  inputLabels = Lookup[$iProvLabels, #["EntityId"], <||>] & /@ carry;
  contribs = Union @@ Join[Lookup[Lookup[#, "Origin", <||>], "Contributors", {}] & /@ inputLabels, {{"Model"}}];
  taints = Union @@ Join[Lookup[Lookup[#, "Origin", <||>], "Taints", {}] & /@ inputLabels, {{"model:" <> If[StringQ[modelRef], modelRef, "unknown"]}}];
  (* 入力の記録が無い・一部欠けた LLM 出力は Unknown として扱う (§4.7 / §5.2: 記録漏れで扱いが緩くならない) *)
  If[compl =!= "Complete", contribs = Union[contribs, {"Unknown"}]; taints = Union[taints, {"prov:incomplete"}]];
  (* モデル識別子が無い (IdentityEvidence Unknown、表 4.3): 出力の OriginClass も Unknown (X-02) *)
  If[! StringQ[modelRef], contribs = Union[contribs, {"Unknown"}]];
  pl = With[{pls = Select[Lookup[#, "PrivacyLevel", Null] & /@ inputLabels, NumericQ]},
    If[pls === {}, If[NumberQ[SourceVault`$SourceVaultDefaultObjectPrivacyLevel], SourceVault`$SourceVaultDefaultObjectPrivacyLevel, 0.85], Max[pls]]];
  aid = "act-" <> iProvULID[];
  outHex = With[{h = Lookup[rec, "OutputSHA256", Null]}, If[StringQ[h] && StringMatchQ[h, RegularExpression["^[0-9a-fA-F]{64}$"]], ToLowerCase[h], Null]];
  If[StringQ[outHex],
    oeid = "ent-" <> iProvULID[];
    blob = <|"Type" -> "ProvBlob", "BlobId" -> "blob:sha256:" <> outHex, "CanonVersion" -> 1,
      "Size" -> With[{b = Lookup[rec, "OutputBytes", Null]}, If[IntegerQ[b], b, Null]], "FirstSeenUTC" -> atIso|>;
    ent = <|"Type" -> "ProvEntity", "SchemaVersion" -> 2, "EntityId" -> oeid, "BlobId" -> "blob:sha256:" <> outHex, "CanonVersion" -> 1,
      "LogicalRef" -> Null, "LogicalRefValid" -> False, "VersionOf" -> Null, "Refs" -> <|"LLMCallEventId" -> eid|>,
      "Kind" -> If[Lookup[rec, "OutputKind", "DerivedText"] === "DerivedCode", "DerivedCode", "DerivedText"], "Media" -> "text/plain",
      "Context" -> <|"Channel" -> "LLMCall", "Provider" -> provider, "Via" -> via|>, "PrivacyLevel" -> N[pl],
      "Origin" -> iProvNormalizeOrigin[<|"Contributors" -> contribs, "Taints" -> taints|>],
      "ProducedBy" -> {aid}, "Completeness" -> compl, "CreatedAtUTC" -> atIso,
      "Machine" -> ToString @ Lookup[rec, "Machine", iProvMachine[]], "Producer" -> "service:join"|>;
    AppendTo[items, <|"EventId" -> "join-" <> eid <> "-b", "RecordText" -> iProvCanonText[blob]|>];
    AppendTo[items, <|"EventId" -> "join-" <> eid <> "-e", "RecordText" -> iProvCanonText[ent]|>]];
  actor = <|"Kind" -> "Model", "Principal" -> "Model", "Channel" -> "claudecode:" <> via, "Provider" -> provider, "ModelRef" -> modelRef,
    "IdentityEvidence" -> If[StringQ[modelRef], "Claimed", "Unknown"], "OnBehalfOf" -> "Owner", "DeterminedBy" -> "Recorder"|>;
  act = <|"Type" -> "ProvActivity", "SchemaVersion" -> 2, "ActivityId" -> aid, "Kind" -> "LLMGenerate", "StartedAtUTC" -> atIso, "EndedAtUTC" -> atIso,
    "Outcome" -> If[ToString @ Lookup[rec, "Outcome", "success"] === "success", "Succeeded", "Failed"], "Actor" -> actor,
    "Inputs" -> inputs, "InputsCompleteness" -> compl, "UnrecordedInputs" -> unrec,
    "Outputs" -> If[StringQ[outHex], {<|"EntityId" -> oeid, "Role" -> "Primary"|>}, {}],
    "PromptDigest" -> With[{p = Lookup[rec, "PromptDigest", Null]}, If[StringQ[p] && StringStartsQ[p, "hmac:"], p, Null]],
    "ToolCalls" -> iProvNormalizeToolCalls[Lookup[rec, "ToolCalls", {}]], "PolicyDigest" -> Null,
    "LineageId" -> key, "LineageSource" -> If[StringQ[key], "SessionKey", Null],
    "ExternalRefs" -> DeleteCases[<|"LLMCallEventId" -> eid, "DiagEventId" -> iProvStr[Lookup[rec, "DiagEventId", Null]],
      "RuntimeId" -> iProvStr[Lookup[rec, "RuntimeId", Null]], "TaskClass" -> iProvStr[Lookup[rec, "TaskClass", Null]]|>, Null],
    "Claimed" -> <|"Actor" -> Lookup[rec, "ClaimedActor", Null], "ClaimedClient" -> Null|>, "Completeness" -> compl,
    "DeclaredInputs" -> declared, "JoinedActivities" -> (#["ActivityId"] & /@ served), "Model" -> iProvStr[Lookup[rec, "Model", Null]],
    "Machine" -> ToString @ Lookup[rec, "Machine", iProvMachine[]], "Producer" -> "service:join",
    "Pid" -> With[{p = Lookup[rec, "Pid", Null]}, If[IntegerQ[p], p, $ProcessID]]|>;
  AppendTo[items, <|"EventId" -> "join-" <> eid <> "-a", "RecordText" -> iProvCanonText[act]|>];
  <|"Items" -> Select[items, StringQ[#["RecordText"]] &], "Joined" -> (inputs =!= {}), "HasKey" -> StringQ[key], "Completeness" -> compl,
    "ActivityId" -> aid, "OutputEntityId" -> oeid|>];

Options[SourceVaultProvJoinLLMCalls] = {"BudgetSeconds" -> 5, "GraceSeconds" -> Automatic};
SourceVaultProvJoinLLMCalls[OptionsPattern[]] := Module[
  {auth, t0 = AbsoluteTime[], deadline, grace, meta, keep = {}, items = {}, joined = 0, unjoined = 0, unrecorded = 0, deferred = 0, r, now, built = {},
   grounding = <|"Bound" -> 0, "Unbound" -> 0, "Waiting" -> 0, "Appended" -> 0|>},
  auth = iProvAuth["SourceVaultProvJoinLLMCalls", $iProvOwnerService];
  If[FailureQ[auth], Return[auth]];
  grace = With[{g = OptionValue["GraceSeconds"]}, If[NumberQ[g], g, $SourceVaultProvJoinGraceSeconds]];
  deadline = t0 + If[NumberQ[OptionValue["BudgetSeconds"]], OptionValue["BudgetSeconds"], 5];
  meta = iProvReadMeta[];
  If[meta === $Failed, Return[Failure["ProvLocalStateUnresolved", <||>]]];
  iProvLLMQueueEnsure[];
  (* V9: 裏付けの結果だけが待っているときも進む (版への結び付けと、待ち切れなかったものの整理) *)
  If[$iProvLLMQueue === {} && $iProvGroundingQueue === {},
    Return[<|"Status" -> "OK", "Joined" -> 0, "Unjoined" -> 0, "Unrecorded" -> 0, "Deferred" -> 0, "Appended" -> 0, "Grounding" -> grounding,
      "Seconds" -> AbsoluteTime[] - t0|>]];
  If[! iProvLedgerKeyAvailableQ[], Return[Failure["ProvMacKeyUnavailable", <||>]]];
  meta = iProvReconcile[meta];
  If[meta["ChainState"] =!= "OK", iProvWriteMeta[meta]; Return[Failure["ProvChainDamaged", KeyTake[meta, {"ChainState", "ChainDamage"}]]]];
  meta = iProvIndexEnsure[meta]; iProvSeenEnsure[];
  now = AbsoluteTime[];
  Scan[Function[q, Module[{b},
      Which[
        AbsoluteTime[] > deadline, AppendTo[keep, q]; deferred++,
        now - Lookup[q, "FirstSeenAbs", now] < grace, AppendTo[keep, q]; deferred++,
        True,
          b = iProvJoinBuild[Lookup[q, "Record", <||>], ToString @ Lookup[q, "EventId", ""], now];
          items = Join[items, Select[b["Items"], ! iProvSeenQ[#["EventId"]] &]];
          AppendTo[built, KeyTake[b, {"ActivityId", "OutputEntityId", "Completeness", "Joined", "HasKey"}]];
          If[! b["HasKey"], unrecorded++];
          If[b["Joined"], joined++, unjoined++]]]],
    $iProvLLMQueue];
  r = If[items === {}, <|"Status" -> "OK", "Meta" -> meta, "Appended" -> 0|>, iProvAppendItems[meta, items]];
  If[r["Status"] =!= "OK",
    (* 追記できない: 待ち行列はそのまま、次回やり直す。ChainState は AppendBatch が立てている *)
    iProvWriteMeta[Join[meta, KeyTake[r["Meta"], {"ChainState", "ChainDamage"}]]]; $iProvMetaCache = <||>;
    Return[Failure["ProvJoinAppendFailed", <|"Status" -> r["Status"]|>]]];
  meta = r["Meta"];
  (* V9 (文書 12 の 4.6 節): 裏付けの結果を、いま索引にある回答の版に結び付ける (検証の主張として台帳に入れる)。
     追記に失敗しても結合は成功として扱い、裏付けの待ち行列はそのまま残す (次回やり直す) *)
  With[{gb = Quiet @ Check[iProvGroundingItems[AbsoluteTime[]], $Failed]},
    If[AssociationQ[gb],
      With[{gr = If[gb["Items"] === {}, <|"Status" -> "OK", "Meta" -> meta, "Appended" -> 0|>, iProvAppendItems[meta, gb["Items"]]]},
        If[gr["Status"] === "OK",
          meta = gr["Meta"];
          meta = iProvMetaCount[meta, "LabelRecords", gr["Appended"]];
          meta = iProvMetaCount[meta, "GroundingBound", gb["Bound"]]; meta = iProvMetaCount[meta, "GroundingUnbound", gb["Unbound"]];
          If[Length[gb["Keep"]] =!= Length[$iProvGroundingQueue], $iProvGroundingQueue = gb["Keep"]; $iProvGroundingQueueDirty = True];
          grounding = <|"Bound" -> gb["Bound"], "Unbound" -> gb["Unbound"], "Waiting" -> Length[gb["Keep"]], "Appended" -> gr["Appended"]|>,
          grounding = <|"Bound" -> 0, "Unbound" -> 0, "Waiting" -> Length[$iProvGroundingQueue], "Appended" -> 0, "Error" -> gr["Status"]|>]]]];
  meta = iProvMetaCount[meta, "Activities", Count[items, KeyValuePattern["EventId" -> _?(StringEndsQ[#, "-a"] &)]]];
  meta = iProvMetaCount[meta, "Entities", Count[items, KeyValuePattern["EventId" -> _?(StringEndsQ[#, "-e"] &)]]];
  meta = iProvMetaCount[meta, "Blobs", Count[items, KeyValuePattern["EventId" -> _?(StringEndsQ[#, "-b"] &)]]];
  meta = iProvMetaCount[meta, "LLMGenerateJoined", joined]; meta = iProvMetaCount[meta, "LLMGenerateUnjoined", unjoined];
  meta = iProvMetaCount[meta, "UnrecordedLLMDerivations", unrecorded];
  $iProvLLMQueue = keep; $iProvLLMQueueDirty = True; iProvLLMQueueSave[];
  meta["LLMQueueCount"] = Length[keep]; meta["IndexSeq"] = $iProvIndexSeq; meta["LastJoinAtUTC"] = iProvNowIso[];
  iProvSeenSave[]; If[TrueQ[$iProvIndexDirty], iProvIndexSave[meta]]; iProvWriteMeta[meta]; $iProvMetaCache = <||>;
  <|"Status" -> If[deferred > 0 && AbsoluteTime[] > deadline, "CarriedOver", "OK"], "Joined" -> joined, "Unjoined" -> unjoined,
    "Unrecorded" -> unrecorded, "Deferred" -> deferred, "Appended" -> r["Appended"], "Built" -> built, "LastSeq" -> meta["LastSeq"],
    (* V9: 裏付けの結果の結び付け (結び付けた数・待ち切れずに捨てた数・まだ待っている数) *)
    "Grounding" -> grounding, "Seconds" -> AbsoluteTime[] - t0|>];

(* Coverage (§7.1): 直近 days 日の派生 Entity のうち Complete で (LLM 由来なら) ModelRef / IdentityEvidence が揃う割合。Backfilled は分母から除く *)
(* 2026-11-11 (レビュー 20261111 F07): 総率 (Total / Complete / Ratio) から Instruction を外す (以前は Instruction の基準 159/159 が入り、
   DerivedText 0/10 でも総率が 94% になった)。仕様の Inc2 の分母「供給点を通った派生」は SupplyPoint (SessionKey つきの LLMGenerate が
   作った版)。供給点の外の派生は OutsideSupplyPoints で件数を数える (LLMWithoutSessionKey = SessionKey の無い LLM 経路、NonLLM = LLM 以外の生成) *)
SourceVaultProvCoverage[daysIn_: 7] := Module[{days = If[NumberQ[daysIn] && daysIn > 0, daysIn, 7], cutoff, byKind = <||>, total = 0, complete = 0, backfilled = 0, meta, unrec,
    spT = 0, spC = 0, outLLM = 0, outNon = 0, ratio},
  ratio[c_, t_] := If[t > 0, N[c/t], Null];
  If[! iProvIndexEnsureRead[],
    Return[<|"Status" -> "IndexUnavailable", "WindowDays" -> days, "Total" -> 0, "Complete" -> 0, "Ratio" -> Null, "ByKind" -> <||>,
      "Instruction" -> <|"Total" -> 0, "Complete" -> 0, "Ratio" -> Null|>, "SupplyPoint" -> <|"Total" -> 0, "Complete" -> 0, "Ratio" -> Null|>,
      "OutsideSupplyPoints" -> <|"LLMWithoutSessionKey" -> 0, "NonLLM" -> 0|>,
      "UnrecordedLLMDerivations" -> 0, "Backfilled" -> 0, "IndexSeq" -> $iProvIndexSeq|>]];
  cutoff = AbsoluteTime[] - days*86400;
  KeyValueMap[Function[{id, l}, Module[{kind = Lookup[l, "Kind", Null], created = Lookup[l, "CreatedAbs", Null], okQ, prodActs, llmQ, spQ},
      If[MemberQ[$iProvDerivedKinds, kind] && NumberQ[created] && created >= cutoff,
        If[TrueQ[Lookup[l, "Backfilled", False]], backfilled++,
          prodActs = Lookup[$iProvActivities, #, <||>] & /@ Lookup[Lookup[$iProvEntities, id, <||>], "ProducedBy", {}];
          llmQ = AnyTrue[prodActs, Lookup[#, "Kind", None] === "LLMGenerate" &];
          okQ = Lookup[l, "Completeness", "Unknown"] === "Complete" &&
            (! llmQ || AnyTrue[prodActs, Lookup[#, "Kind", None] === "LLMGenerate" && StringQ[Lookup[#, "ModelRef", Null]] &&
              MemberQ[{"Claimed", "Measured", "MeasuredByPeer", "Attested"}, Lookup[#, "IdentityEvidence", Null]] &]);
          byKind[kind] = With[{c = Lookup[byKind, kind, <|"Total" -> 0, "Complete" -> 0|>]},
            <|"Total" -> c["Total"] + 1, "Complete" -> c["Complete"] + Boole[okQ]|>];
          If[kind =!= "Instruction",
            total++; If[okQ, complete++];
            spQ = AnyTrue[prodActs, Lookup[#, "Kind", None] === "LLMGenerate" && StringQ[Lookup[#, "LineageId", Null]] &];
            Which[
              spQ, spT++; If[okQ, spC++],
              llmQ, outLLM++,
              True, outNon++]]]]]], $iProvLabels];
  byKind = Map[Append[#, "Ratio" -> ratio[#["Complete"], #["Total"]]] &, byKind];
  meta = iProvReadMeta[];
  unrec = If[AssociationQ[meta], Lookup[meta["Counts"], "UnrecordedLLMDerivations", 0], 0];
  <|"Status" -> "OK", "WindowDays" -> days, "Total" -> total, "Complete" -> complete, "Ratio" -> ratio[complete, total],
    "ByKind" -> byKind,
    "Instruction" -> Lookup[byKind, "Instruction", <|"Total" -> 0, "Complete" -> 0, "Ratio" -> Null|>],
    "SupplyPoint" -> <|"Total" -> spT, "Complete" -> spC, "Ratio" -> ratio[spC, spT]|>,
    "OutsideSupplyPoints" -> <|"LLMWithoutSessionKey" -> outLLM, "NonLLM" -> outNon|>,
    "UnrecordedLLMDerivations" -> unrec, "Backfilled" -> backfilled, "IndexSeq" -> $iProvIndexSeq|>];

(* ============================================================
   登録: SecurityProfile の検査 (literal 鍵・台帳鍵)、privacy 契約 (弱結合)、退役鍵の読込
   ============================================================ *)
iProvSecurityProfileCheck[prof_String] := Module[{lits, v = {}},
  lits = Select[Keys[$SourceVaultProvKeyRefs], With[{ks = iProvKeySpec[#]}, AssociationQ[ks] && StringStartsQ[ks["KeyRef"], "literal:"]] &];
  If[prof === "production" && lits =!= {},
    AppendTo[v, <|"Code" -> "ProvLiteralKeyInProduction", "Severity" -> "Error",
      "Message" -> "$SourceVaultProvKeyRefs has literal key material for " <> StringRiffle[lits, ", "] <> " while the security profile is production; literal keys are for development only (03 v0.4 12.2)."|>]];
  If[! iProvLedgerKeyAvailableQ[],
    AppendTo[v, <|"Code" -> "ProvLedgerMacKeyUnavailable", "Severity" -> "Warning",
      "Message" -> "The provenance ledger MAC key (" <> ToString[iProvKeySpec["LedgerMac"]["KeyRef"]] <> ") is not resolvable in this kernel; the service cannot ingest the spool until the owner generates it (NBGenerateMacKeyRef) and NBAccess_crypto is loaded there."|>]];
  v];
If[Length[DownValues[SourceVault`SourceVaultRegisterSecurityProfileCheck]] > 0,
  Quiet @ SourceVault`SourceVaultRegisterSecurityProfileCheck["Provenance", iProvSecurityProfileCheck]];

iProvRegisterPrivacyContracts[] := Quiet @ Check[
  If[Length[DownValues[SourceVault`SourceVaultRegisterPrivacyContract]] > 0,
    Scan[SourceVault`SourceVaultRegisterPrivacyContract[First[#],
        <|"Class" -> "Internal", "Module" -> "SourceVault_provenance.wl", "NoDataFlow" -> Last[#]|>] &,
      {{"SourceVaultProvEmit", "Appends one canonical JSON record to the machine-local provenance spool; returns status, EventId and timing only."},
       {"SourceVaultProvEntity", "Hashes the caller's content into a BlobId and spools identifiers, labels and digests; no content is stored or returned."},
       {"SourceVaultProvActivity", "Spools identifiers, roles, digests and the recorder-determined actor; prompts and arguments are reduced to keyed digests."},
       {"SourceVaultProvDerive", "Sugar over SourceVaultProvEntity / SourceVaultProvActivity; same data flow."},
       {"SourceVaultProvKeyedDigest", "Keyed digest through NBMacWithKeyRef; returns hmac:<KeyId>:<hex> only and counts calls."},
       {"SourceVaultProvIngestSpool", "Service-side move of spool records into the LocalState ledger and index; returns counts and sequence numbers."},
       {"SourceVaultProvIngestAdapters", "Service-side read of hotlog identifiers and decisions into the ledger; URLs, queries and bodies are never copied."},
       {"SourceVaultProvVerifyLedger", "Recomputes hashes and MACs of the LocalState ledger; returns positions of mismatches, no record content."},
       {"SourceVaultProvRebuildIndex", "Rebuilds the LocalState index from the ledger; returns counts and a digest."},
       {"SourceVaultProvCheckpoint", "Writes the last LineHash and Seq range with a MAC; no record content."},
       {"SourceVaultProvResolve", "Returns identifiers, labels and usability of versions; BlobId withheld for PL >= 0.5 unless the principal is the owner or the service."},
       {"SourceVaultProvUsability", "Returns usability codes and sequence numbers from the small FE index."},
       {"SourceVaultProvStatus", "Counts and state only."},
       {"SourceVaultProvServed", "Supply-point record: spools identifiers, roles, digests and PL of the records a supply point handed to the model context; no content is stored or returned."},
       {"SourceVaultProvRequireCommitted", "Waits for ledger commitment of the given ids; returns status and ids only."},
       {"SourceVaultProvJoinLLMCalls", "Service-side join of LLMCall events with ServedToContext activities into LLMGenerate activities; returns counts."},
       {"SourceVaultProvCoverage", "Counts and ratios over the LocalState index; no record content."},
       {"SourceVaultProvSessionKey", "Returns the session key string of the current context (provider|session), or None."},
       {"SourceVaultProvMerkleRoot", "Pure function over LineHash strings; returns a digest."},
       {"SourceVaultProvSyncFeeds", "Writes checkpoint copies, a projection of PL < 0.5 versions (random SyncIds, kinds, origin classes, usability, relations; no BlobId, EntityId, reference or content) and witnesses to the synced feeds folder; reads other machines' checkpoint copies; returns counts and finding metadata."},
       {"SourceVaultProvFeedStatus", "Reads the last feeds sync state (counts, statuses, finding metadata)."}}]];
  Null, Null];
iProvRegisterPrivacyContracts[];
Quiet @ Check[iProvLoadRetiredKeyRefs[], Null];

End[]  (* `ProvenancePrivate` *)

EndPackage[]  (* SourceVault` *)
