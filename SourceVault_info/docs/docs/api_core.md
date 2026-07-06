# SourceVault_core API リファレンス

## 概要
SourceVault_core.wl は SourceVault 検索拡張 Phase 0 の core 基盤。既存の [SourceVault](https://github.com/transreal/SourceVault) を書き換えず `SourceVault`` 文脈へ新規ファイルとして追加する core extension であり、immutable snapshot store・content-addressed blob store・event log・advisory-free lock・pointer(event-sourced)・GC/retention・整合性検査という下位ストレージ基盤を提供する。[SourceVault_searchindex](https://github.com/transreal/SourceVault_searchindex) / [SourceVault_servicemanager](https://github.com/transreal/SourceVault_servicemanager) がこの core helper を利用する。load order: SourceVault.wl → SourceVault_core.wl → SourceVault_searchindex.wl → SourceVault_servicemanager.wl。UTF-8 encode され、`Block[{$CharacterEncoding="UTF-8"}, Get[...]]` で読む。

設計原則(§17.12.1):(1) LLM/ASR/TTS/OCR/HTTP/Discord/shell 実行中に data lock を保持しない。(2) 書き込みは append-only event directory(one-event-one-file)。(3) blob は content-addressed storage に create-only。(4) 既存 object の破壊的更新禁止、active pointer は pointer event 追加で表現。(5) lock は atomic directory creation(advisory file lock に依存しない)。(6) 明示 fsync 前提なし、一貫性は checksum 検証 + replay + idempotent ID。(7) CommandID/EventID は `CreateUUID[]` 既定。(8) 既定は同一 host 上の複数 process、異 host stale lock は operator review。

識別子フォーマット:event id `"evt:"<>CreateUUID[]`、blob ref `"blob:sha256:"<>hex64`、snapshot ref `"snapshot:"<>class<>":"<>hex64`、digest `"sha256:"<>hex64`。private helper は `SourceVault`CorePrivate`` に隔離し既存 `SourceVault`Private`` と衝突しない。

fail-closed 方針:root 未解決時 core API は推測 fallback せず Failure を返す。privacy 未指定 object は既定 0.85(クラウド閾値 0.5 超)なので明示ダウングレードしない限りクラウド sink へ出ない。多くの storage primitive は main kernel 専用で MCP / 低trust projection へは公開しない。

## Root 解決
core は root 解決ロジックを複製せず、注入値(service kernel)か bootstrap 済み `SourceVault`$SourceVaultRoots`(main kernel)を読む薄いアクセサ。

### $SourceVaultCoreRoot
型: String | Automatic, 初期値: Automatic
core storage root directory の override。未設定(Automatic)なら `$SourceVaultRoots["PrivateVault"]` を使う。どちらも解決不能なら core API は fail-closed。

### $SourceVaultInjectedRoots
型: Association, 初期値: 未設定
service kernel 起動時に run.wls から注入される root snapshot。main kernel では通常未設定。設定時は root 解決で最優先(start-time snapshot, spec v6 §3.8)。

### $SourceVaultInjectedRootHash
型: String, 初期値: 未設定
注入された root 構成の hash。health check で main kernel と比較する。

### SourceVaultCoreRoot[] → String | Failure
core storage root の絶対パスを返し、無ければ ensure 生成する。解決できなければ Failure["SourceVaultCoreRootUnresolved"]。

### SourceVaultRootAssociation[] → Association
現在有効な root 解決結果。`$SourceVaultInjectedRoots` を最優先、次に `$SourceVaultRoots` を読む。どちらも未設定なら `<||>`(fail-soft)。

### SourceVaultResolveRoots[] → Association
`SourceVaultRootAssociation[]` の別名。

### SourceVaultRoot[key] → String | Missing
root key("PrivateVault"/"Tmp"/"LocalState" 等)のパス。未解決なら `Missing["NotResolved", key]`。

### SourceVaultSetRoot[key, path] → path
root 設定を変更(`$SourceVaultRoots` を更新)。設定変更のみで既存データ移動は行わない(spec v6 §3.9)。注入値がある service kernel では restart/reload まで反映されない。

### SourceVaultRootConfigHash[] → String
現在の root 構成の SHA256 hex(`KeySort` した association ベース)。空構成なら ""。main/service kernel の root 一致検証に使う。

### SourceVaultStorageDir[class] → String | Failure
storage class の絶対パス。class: "Raw"→raw/by-hash, "Meta"→raw/meta, "Parsed"→parsed, "Attachments"→attachments, "Compiled"→compiled/public, "LocalState"→root["LocalState"]。未知 class は Failure["SourceVaultUnknownStorageClass"]、PrivateVault 未解決は Failure["SourceVaultRootUnresolved"]。

## Digest / Canonicalization (§8.2a)
digest 用に assoc を canonical 化する。key を再帰 sort、DateObject を UTC ISO-8601 文字列化、揮発 field を除外。揮発 field: CreatedAtUTC, StoredAtUTC, CreatedBy, BuildHost, RuntimeResolved, LocalPath, ResolvedCredential, ProcessID, LastAccessedAtUTC, Digest。

### SourceVaultCanonicalizeForDigest[assoc, opts]
assoc を digest 用 canonical JSON 文字列に正規化。
→ String | Failure["CanonicalizeFailed"]
Options: "DropFields" -> {} (揮発 field に加えて除外する key のリスト)

### SourceVaultSnapshotDigest[assoc, opts] → String | Failure
canonical JSON の UTF-8 bytes の SHA256 を "sha256:<hex>" で返す。
Options: "DropFields" -> {} (SourceVaultCanonicalizeForDigest と同じ)

## Immutable snapshot store (§8.2a)
content-addressed(digest 固定)な不変 snapshot。同一内容の再保存は idempotent、既存の破壊的更新はしない。

### SourceVaultSaveImmutableSnapshot[class, assoc, opts]
assoc を immutable snapshot として保存。保存内容は元 assoc に SnapshotClass/Digest/StoredAtUTC を付与(digest 対象外)。元 assoc の key は書き換えない。
→ `<|"Status","Ref","Digest","Path","Class","Existed"|>` | Failure
Options: "Alias" -> None (String 指定で alias 割当), "AliasOverwrite" -> False (既存 alias を張り替え)
例: SourceVaultSaveImmutableSnapshot["SearchIndex", assoc, "Alias" -> "latest"]

### SourceVaultLoadImmutableSnapshot[ref] → Association | Failure
snapshot ref または "class/alias" を読み、検証済み assoc を返す。ref 形式: "snapshot:class:hex" | "class/alias"。未解決は Failure["SnapshotRefUnresolved"]、未存在は Failure["SnapshotNotFound"]、破損は Failure["SnapshotCorrupt"]。

### SourceVaultReadSnapshot[id] → Association | Failure
`SourceVaultLoadImmutableSnapshot` の別名。

### SourceVaultVerifyImmutableSnapshot[ref] → Association
保存済み snapshot の digest を、保存時付与 field(Digest/StoredAtUTC/SnapshotClass)を除いた元内容で再計算し整合を返す。
→ `<|"Status"("Valid"|"Mismatch"),"Ref","StoredDigest","Recomputed","Valid"|>`

### SourceVaultAllocateSnapshotAlias[class, alias, ref, opts]
alias -> ref を割り当てる。同 alias に同 ref は idempotent 成功。異 ref は既定で NameCollision 拒否。
→ `<|"Status","Alias","Ref","Existed","Updated"|>` | Failure["NameCollision"]
Options: "Overwrite" -> False (True で既存 alias を新 ref に張り替え; rebuildable index 用)

## Snapshot privacy side-record (privacy invariant phase 1)
不変 snapshot は content-addressed なので privacy を内容へ焼き込めない。ref をキーにした可変サイドレコードで保持し、本体は書き換えない。レコード非存在 = 既定 0.85。書き込みはサンクション経路(NBAccess`NBSetSnapshotPrivacyLevel → SourceVault`SourceVaultSetSnapshotPrivacyLevel → SourceVaultSetImmutableSnapshotPrivacyLevel)のみ。

### $SourceVaultDefaultObjectPrivacyLevel
型: Real, 初期値: 0.85
privacy 未指定 object の既定 privacy level。0.5 のクラウド閾値超のため明示ダウングレードしない限りクラウド sink へ出ない(fail-closed)。

### SourceVaultSnapshotPrivacyLevel[ref] → Real
不変 snapshot(snapshot:class:hex / class/alias / sv://snapshot/class/hex)の privacy level。サイドレコードがあればその Level、無ければ 0.85。`Clip[.,{0,1}]` 済み。read-only。

### SourceVaultSnapshotPrivacyRecord[ref] → Association
privacy サイドレコード。キー Level/Source/Present/Class/Hex/Ref/Encrypted。未設定でも既定値(Level 0.85, Source "Default", Present False)で返す。

### SourceVaultImmutableSnapshotExistsQ[ref] → True|False
不変 snapshot 本体がストアに存在するか判定。

### SourceVaultSetImmutableSnapshotPrivacyLevel[ref, level] → Association
不変 snapshot の privacy サイドレコードを設定(本体は不変なので別ファイル)。level は `Clip[.,{0,1}]` される。サンクション経路は NBAccess`NBSetSnapshotPrivacyLevel(承認ゲート付き)のみ。
→ `<|"Status","Ref","SnapshotKind"("Immutable"),"OldPrivacyLevel","NewPrivacyLevel","Lowered","PrivacyLevelSource"("Manual"),"SetAt"|>`。未存在は `<|"Status"->"Failed","Reason"->"SnapshotNotFound"|>`。

## Lock primitive (§17.12.2)
atomic directory creation で実装。lock 名のコロン等は Windows 安全化される。同一 host の期限切れ lock は自動回収、異 host lock は自動回収せず operator review。

### SourceVaultTryLock[lockName, opts]
lock を一度だけ試みる。
→ `<|"Acquired"->True|False,"Handle","Reason"("Created"|"RecoveredStale"|"Held"|"NeedsOperatorRecovery")|>`。取得成功時のみ Handle を含む。
Options: "TTLSeconds" -> 30

### SourceVaultWithLock[lockName, body, opts]
lock を取得して body を評価し必ず解放する(HoldRest, body は取得まで評価されない)。取得失敗は Failure["LockTimeout"] / Failure["LockNeedsOperatorRecovery"]。Abort は lock 解放後に再送出。
→ body の評価結果 | Failure
Options: "TimeoutSeconds" -> 5, "TTLSeconds" -> 30
例: SourceVaultWithLock["vault-write-event", commitBody[], "TimeoutSeconds" -> 5]

### SourceVaultReleaseLock[handle] → Association | Failure
`SourceVaultTryLock` が返した Handle を解放。owner 同一性を確認してから解放(他者の lock は消さない)。
→ `<|"Status"("Released"|"NotOwner"),...|>`。不正 handle は Failure["BadLockHandle"]。

### SourceVaultRecoverLocks[opts] → Association
同一 host の stale lock を回収。異 host は回収せず NeedsOperatorRecovery で報告。
→ `<|"Status","Recovered"->{lockName..},"NeedsOperatorRecovery"->{..}|>`

## Event log (§17.12.5)
append-only event directory へ one-event-one-file で commit(年/月/日で分割)。

### SourceVaultAppendEvent[event, opts] → Association | Failure
event を commit。EventID 無ければ "evt:"<>CreateUUID[] 付与、Digest(Digest field を除いた内容で算出)と CreatedAtUTC を補う。"vault-write-event" lock 下で書く。同一 EventID の再 commit は digest 一致なら idempotent 成功、不一致なら EventIdCollision。
→ `<|"Status"("OK"|"EventIdCollision"|"CommitFailed"),"EventID","Digest","Path","Idempotent","Ref"->"event:"<>eid|>`

### SourceVaultTransactionLog[opts] → List
event directory の event を新しい順(CreatedAtUTC 降順)に返す。
Options: "Limit" -> 100 (Integer で先頭 N 件), "EventClass" -> All (指定で EventClass filter)

## Blob commit (§17.12.6) / content resolve
content-addressed blob を create-only 保存。読み出しは hash 再検証付き。main kernel 用 storage primitive で MCP/低trust へ公開しない。

### SourceVaultCommitBlob[data, opts] → Association | Failure
ByteArray / String を content-addressed blob として create-only 保存。既存 blob の hash 不一致は Failure["BlobCorruption"] で fail-closed。meta は meta.json に保存(Hash/Bytes/CreatedAtUTC + Meta)。
→ `<|"Status","Hash","BlobRef"->"blob:sha256:"<>hex,"Path","Existed"|>`
Options: "Meta" -> <||> (meta.json に merge する assoc)

### SourceVaultReadBlob[hashOrRef] → Association
content-addressed blob を読み hash 検証済み bytes を返す(CommitBlob の読み出し対)。hashOrRef: "blob:sha256:<hex>" | "sha256:<hex>" | <hex64> | "sv://hash/sha256/<hex>"。読み出し時に hash 再計算し不一致は Corruption で fail-closed。
→ `<|"Status"("OK"|"Error"),"Hash","Bytes"->ByteArray,"Path","Meta"|>`(Error 時 "Reason"->"BadHash"|"BlobNotFound"|"BlobReadFailed"|"BlobCorruption")

### SourceVaultBlobRefs[hash, opts] → Association
blob hash を参照する snapshot/event JSON を走査し参照元を返す(hex 文字列の出現を保守的に参照とみなす)。
→ `<|"Hash","RefCount","Refs"->{path..}|>`

### SourceVaultResolveArtifactContent[uriOrId, opts]
deposit 済み artifact(sv://artifact/<id> / <id> / sv://hash/sha256/<hex> / blob:sha256:<hex>)の内容を必ず PrivacyLevel 付きで解決する main-kernel sanctioned reader。生データを PrivacyLevel なしで返すことはなく、PrivacyLevel 欠落は fail-closed で既定 0.85。sv://artifact/<id> は DerivedArtifact snapshot → blob と辿り、hash 直接参照は record を経ないため PL は fail-closed 既定。サンクション表示経路は NBAccess`NBInsertArtifactCell(privacy marking 付きノートブック表示)であり MCP/低trust へは公開しない。MediaKind は image/*→"Image"、image/gif・video/*→"Video"、text/*・application/json→"Text"、他→"Binary"。
→ `<|"Status","ArtifactId","Ref","MediaKind"("Image"|"Video"|"Text"|"Binary"),"MediaType","PrivacyLevel","Bytes"|"Text","File","Filename"|>`(Error 時 "Reason")
Options: "Materialize" -> Automatic (Automatic は Video/Binary のみ vault 内 materialized/ へ content-addressed にファイル化 | True | False)

## Rate limit (過剰実行対策)
NBAccess は SourceVault* head を承認不要(trusted package)扱いする。その代償として高コスト/副作用のある公開関数(SourceVaultIngest, SourceVaultComfyUIQueuePrompt 等)が entry でこの sliding-window limiter を呼び runaway loop や LLM 生成コードの暴走を止める。カーネル内 in-memory。

### $SourceVaultRateLimits
型: Association, 初期値: `<|"Ingest"-><|"Limit"->120,"WindowSeconds"->3600|>, "ComfyUISubmit"-><|"Limit"->60,"WindowSeconds"->3600|>, "Default"-><|"Limit"->600,"WindowSeconds"->3600|>|>`
key 別 rate limit 設定。既定: Ingest 120/h, ComfyUISubmit 60/h, Default 600/h。

### SourceVaultRateLimit[key] → Association
key の sliding-window 実行回数を記録し判定。設定は $SourceVaultRateLimits[key](無ければ "Default")。
→ 上限内 `<|"Allowed"->True,"Key","Count","Limit","WindowSeconds"|>`、超過 `<|"Allowed"->False,"Key","Count","Limit","WindowSeconds","Hint"|>`

## Pointer (§17.12.7)
event-sourced。overwrite-rename せず pointer event を追加、active.json は cache(正本でない)。reader は digest 検証し失敗時 replay。

### SourceVaultAtomicUpdatePointer[name, value, opts] → Association | Failure
"active-pointer:<name>" lock 下で pointer event(EventClass "PointerUpdated", Sequence = max+1)を追加し active.json cache を更新。
→ `<|"Status","Name","Sequence","Value","EventRef"|>`

### SourceVaultPointerReplay[name, opts] → Association | Failure
pointer event を digest 検証しながら replay、最大 Sequence の検証済み値を返す。全 event 破損は Failure["PointerAllEventsCorrupt"]。event 無しは Status "Empty"(Value Missing["NoPointer"])。
→ `<|"Status"("OK"|"Empty"),"Value","Sequence","EventCount","ValidCount","CacheConsistent","SequenceDuplicated"|>`

### SourceVaultPointerHistory[name] → List
pointer の検証済み event 履歴を Sequence 昇順で返す。各要素 `<|"Sequence","Value","CreatedAtUTC"|>`。rollback 等で前版を辿る。

## GC / retention (§17.12.10)
未参照かつ retention 期限切れの blob を回収。既定 dry-run、実削除は "ConfirmDelete"->True。grace period 内 / in-flight write / replay 失敗 vault は削除しない(fail-closed)。

### SourceVaultGCGracePeriod[] → Integer
in-flight blob 保護の既定 grace period(秒, 既定 86400 = 24h)。

### SourceVaultRunGC[opts] → Association
未参照かつ retention 期限切れ blob を回収。vault が Healthy でなければ Skipped(VaultNotHealthy)。事前チェックは SourceVaultCheckVaultConsistency["Quick"->True]。
→ `<|"Status"("DryRun"|"Deleted"|"Skipped"),"Candidates","Deleted","ProtectedByInFlightWrite","GraceSeconds","Confirmed"|>`
Options: "ConfirmDelete" -> False (True で実削除), "GraceSeconds" -> Automatic (Automatic は 86400)

### SourceVaultGCDryRun[opts] → Association
削除せず GC 候補 blob を報告。`SourceVaultRunGC["ConfirmDelete"->False, opts]` と同じ。

### SourceVaultRetentionPlan[scope, opts] → Association
blob 群の参照状態と retention 判定の計画を返す(削除しない)。scope 既定 All。
→ `<|"Status","Scope","BlobCount","Plan"->{<|"Hash","RefCount","Referenced","AgeSeconds"|>..}|>`

## Consistency / test (§17.12.11)

### SourceVaultCheckVaultConsistency[opts] → Association
vault の不変条件を検査し報告を返す。検査: event digest 一致 / EventID 一意 / sidecar 存在 / pointer sequence 単調・cache 整合 / blob hash 整合 / orphan tmp(grace 超過) / stale lock。
→ `<|"Status","Healthy","EventCount","EventIdUnique","EventDigestMismatches","EventIdCollisions","SidecarMissing","PointerIssues","BlobHashMismatches","OrphanTmp","StaleLocks","Quick"|>`
Options: "Quick" -> False (True で blob hash 整合検査を skip; GC の事前チェック用)

### SourceVaultConcurrentWriteTest[opts] → Association | Failure
append / blob / pointer の並行書込と idempotency / collision 検出を検証。Parallel True かつ subkernel があれば各 kernel で core を Get して ParallelTable、無ければ逐次。
→ Passed と不変条件チェック結果を含む Association
Options: "Processes" -> 2, "PerProcessEvents" -> 100, "Parallel" -> False