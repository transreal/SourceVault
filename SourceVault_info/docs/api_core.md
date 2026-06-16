# SourceVault_core API Reference

パッケージ: `SourceVault`` (SourceVault_core.wl)
ロード順: `SourceVault.wl` → `SourceVault_core.wl` → `SourceVault_searchindex.wl` → `SourceVault_servicemanager.wl`
ロード方法: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_core.wl"]]`
リポジトリ: https://github.com/transreal/SourceVault_core

## 識別子フォーマット

| 種別 | フォーマット |
|------|-------------|
| event id | `"evt:" <> CreateUUID[]` |
| blob ref | `"blob:sha256:" <> <hex64>` |
| snapshot ref | `"snapshot:" <> <class> <> ":" <> <hex64>` |
| digest | `"sha256:" <> <hex64>` |

## 変数

### $SourceVaultCoreRoot
型: String|Automatic, 初期値: Automatic
core storage の root directory override。未設定時は `SourceVault`$SourceVaultRoots["PrivateVault"]` を使う。どちらも解決できない場合は fail-closed (推測 fallback しない)。

### $SourceVaultInjectedRoots
型: Association|Undefined
service kernel 起動時に run.wls から注入される root snapshot。main kernel では通常未設定。設定時は root 解決で最優先される (start-time snapshot)。

### $SourceVaultInjectedRootHash
型: String|Undefined
注入された root 構成の hash。health check で main kernel と比較する。

## Root 解決 API

### SourceVaultCoreRoot[] → String|Failure
core storage root の絶対パスを返す。解決できなければ `Failure["SourceVaultCoreRootUnresolved", ...]` を返す。

### SourceVaultRootAssociation[] → Association
現在有効な root 解決結果を返す。`$SourceVaultInjectedRoots` (service kernel) を最優先し、次に `SourceVault`$SourceVaultRoots` を読む。どちらも未設定なら `<||>` を返す (fail-soft)。

### SourceVaultResolveRoots[] → Association
`SourceVaultRootAssociation[]` の別名。

### SourceVaultRoot[key] → String|Missing
root key (`"PrivateVault"` / `"Tmp"` / `"LocalState"` 等) のパスを返す。未解決なら `Missing["NotResolved", key]`。

### SourceVaultSetRoot[key, path] → String
root 設定を変更する (`SourceVault`$SourceVaultRoots` を更新)。設定変更のみ。既存データの移動は行わない。service kernel では restart/reload まで反映されない。

### SourceVaultRootConfigHash[] → String
現在の root 構成の SHA256 hex を返す。main kernel と service kernel の root 一致検証 (health check) に使う。root が空なら `""` を返す。

### SourceVaultStorageDir[class] → String|Failure
storage class の絶対パスを返す。有効な class: `"Raw"`, `"Meta"`, `"Parsed"`, `"Attachments"`, `"Compiled"`, `"LocalState"`。未知の class は `Failure["SourceVaultUnknownStorageClass", ...]`。`"LocalState"` は `SourceVaultRoot["LocalState"]` を直接返す。

## Digest / Canonicalization (§8.2a)

### SourceVaultCanonicalizeForDigest[assoc, opts]
assoc を digest 用 canonical JSON 文字列に正規化する。Association の key を再帰 sort し、DateObject を UTC ISO-8601 文字列化し、揮発 field を除く。
→ String|Failure
Options: `"DropFields" -> {}` (追加除外 key のリスト)

揮発 field (常に除外): `"CreatedAtUTC"`, `"StoredAtUTC"`, `"CreatedBy"`, `"BuildHost"`, `"RuntimeResolved"`, `"LocalPath"`, `"ResolvedCredential"`, `"ProcessID"`, `"LastAccessedAtUTC"`, `"Digest"`

### SourceVaultSnapshotDigest[assoc, opts]
canonical JSON の UTF-8 bytes の SHA256 を `"sha256:<hex>"` 形式で返す。
→ String|Failure
Options: `"DropFields" -> {}` (`SourceVaultCanonicalizeForDigest` と同じ)

## Immutable Snapshot Store (§8.2a)

### SourceVaultSaveImmutableSnapshot[class, assoc, opts]
assoc を immutable snapshot として保存する。同一内容の再保存は idempotent。保存時に `"SnapshotClass"`, `"Digest"`, `"StoredAtUTC"` を付与するが、digest 計算対象外。
→ `<|"Status" -> "OK", "Ref" -> ref, "Digest" -> digest, "Path" -> path, "Class" -> class, "Existed" -> True|False|>`
Options: `"Alias" -> None` (alias 名を指定すると同時に alias を割り当てる)

例: `SourceVaultSaveImmutableSnapshot["MyClass", <|"Key" -> "val"|>, "Alias" -> "latest"]`

### SourceVaultLoadImmutableSnapshot[ref] → Association|Failure
snapshot ref (`"snapshot:class:hex"`) または `"class/alias"` 形式を読み、検証済み assoc を返す。見つからなければ `Failure["SnapshotNotFound", ...]`、破損なら `Failure["SnapshotCorrupt", ...]`。

### SourceVaultReadSnapshot[id] → Association|Failure
`SourceVaultLoadImmutableSnapshot` の別名。

### SourceVaultVerifyImmutableSnapshot[ref] → Association|Failure
保存済み snapshot の digest を再計算して整合を検証する。
→ `<|"Status" -> "Valid"|"Mismatch", "Ref" -> ref, "StoredDigest" -> d, "Recomputed" -> d, "Valid" -> True|False|>`

### SourceVaultAllocateSnapshotAlias[class, alias, ref, opts] → Association|Failure
alias → ref を割り当てる。同 alias に既に別 ref が割り当てられている場合は `Failure["NameCollision", ...]` で拒否する。同 alias・同 ref の再割り当ては idempotent 成功。
→ `<|"Status" -> "OK", "Alias" -> alias, "Ref" -> ref, "Existed" -> True|False|>`

## Lock Primitive (§17.12.2)

設計原則: lock 取得は atomic directory creation による。advisory file lock に依存しない。同一 host の期限切れ lock は自動回収。異 host の stale lock は operator review が必要。

### SourceVaultTryLock[lockName, opts]
atomic directory creation で lock を一度だけ試みる (ブロックしない)。
→ `<|"Acquired" -> True|False, "Handle" -> handle, "Reason" -> reason, ...|>`
Options: `"TTLSeconds" -> 30` (lock の有効期間)

`"Reason"` の値: `"Created"` (取得成功), `"RecoveredStale"` (stale 回収後取得), `"Held"` (他者保持中), `"NeedsOperatorRecovery"` (異 host lock)

例:
```
res = SourceVaultTryLock["my-lock"];
If[TrueQ[res["Acquired"]],
  (* 処理 *);
  SourceVaultReleaseLock[res["Handle"]]
]
```

### SourceVaultWithLock[lockName, body, opts]
lock を取得して body を評価し、必ず lock を解放する (HoldRest)。取得できなければ `Failure["LockTimeout", ...]` を返す。body は lock 取得まで評価されない。
→ body の評価結果|Failure
Options: `"TimeoutSeconds" -> 5` (取得タイムアウト), `"TTLSeconds" -> 30` (lock 有効期間)

例: `SourceVaultWithLock["write-lock", SourceVaultAppendEvent[ev], "TimeoutSeconds" -> 10]`

### SourceVaultReleaseLock[handle] → Association|Failure
`SourceVaultTryLock` が返した lock handle (`"Handle"` フィールドの Association) を解放する。owner 同一性を確認してから解放するため他者の lock は消さない。
→ `<|"Status" -> "Released", "LockName" -> name|>` または `<|"Status" -> "NotOwner", ...|>`

### SourceVaultRecoverLocks[opts] → Association
同一 host の期限切れ (stale) lock を回収する。異 host の lock は回収せず `"NeedsOperatorRecovery"` として報告する。
→ `<|"Status" -> "OK", "Recovered" -> {lockName...}, "NeedsOperatorRecovery" -> {<|"LockDir", "Owner"|>...}|>`

## Event Log (§17.12.5)

設計原則: append-only event directory に one-event-one-file で書く。EventID が未指定なら `"evt:" <> CreateUUID[]` を付与する。

### SourceVaultAppendEvent[event, opts] → Association|Failure
event を append-only event directory に commit する。`"EventID"` 未指定時は自動付与。`"CreatedAtUTC"` と `"Digest"` も自動補完する。同一 EventID・同一 digest の再 commit は idempotent 成功。同一 EventID・異 digest は `"EventIdCollision"` で拒否。
→ `<|"Status" -> "OK"|"EventIdCollision", "EventID" -> id, "Digest" -> d, "Path" -> path, "Idempotent" -> True|False, "Ref" -> "event:evt:..."|>`

### SourceVaultTransactionLog[opts]
event directory の event を新しい順に返す。
→ `{assoc...}`
Options: `"Limit" -> 100` (取得上限), `"EventClass" -> All` (EventClass フィールドでフィルタ)

## Blob Commit (§17.12.6)

設計原則: content-addressed storage に create-only で書く。hash 不一致の既存 blob は `"Corruption"` で fail-closed。

### SourceVaultCommitBlob[data, opts]
ByteArray または String (UTF-8) を content-addressed blob として create-only で保存する。同一内容の再保存は idempotent。既存 blob の hash 不一致は `Failure["BlobCorruption", ...]`。
→ `<|"Status" -> "OK", "Hash" -> hex, "BlobRef" -> "blob:sha256:hex", "Path" -> path, "Existed" -> True|False|>`
Options: `"Meta" -> <||>` (meta.json に追記する追加メタデータ)

### SourceVaultBlobRefs[hash, opts] → Association
blob hash を参照する snapshot / event を走査して参照元ファイルを返す。hash は `"blob:sha256:hex"` 形式または bare hex を受け付ける。
→ `<|"Hash" -> hex, "RefCount" -> n, "Refs" -> {path...}|>`

## Pointer (§17.12.7)

設計原則: pointer の更新は overwrite-rename ではなく pointer event の追加で表現する。active.json は cache であり正本ではない。reader は digest 検証に失敗した場合 replay する。

### SourceVaultAtomicUpdatePointer[name, value, opts] → Association|Failure
pointer を更新する。内部で `"active-pointer:<name>"` lock の下で pointer event を追加し active.json cache を更新する。
→ `<|"Status" -> "OK", "Name" -> name, "Sequence" -> n, "Value" -> value, "EventRef" -> "evt:..."|>`

### SourceVaultPointerReplay[name, opts] → Association|Failure
pointer event を replay し、最大 Sequence の検証済み値を返す。event が全件 corrupt の場合は `Failure["PointerAllEventsCorrupt", ...]`。
→ `<|"Status" -> "OK"|"Empty", "Value" -> value, "Sequence" -> n, "EventCount" -> n, "ValidCount" -> n, "CacheConsistent" -> True|False, "SequenceDuplicated" -> True|False|>`

### SourceVaultPointerHistory[name] → {Association...}
pointer の検証済み event 履歴を Sequence 昇順で返す。各要素: `<|"Sequence" -> n, "Value" -> value, "CreatedAtUTC" -> str|>`。rollback 等で前版を辿るのに使う。

## GC / Retention (§17.12.10)

### SourceVaultGCGracePeriod[] → Integer
in-flight blob 保護の既定 grace period (秒) を返す。既定値: `86400` (24時間)。

### SourceVaultRunGC[opts]
未参照かつ retention 期限切れの blob を回収する。既定は dry-run。実削除には `"ConfirmDelete" -> True` が必要。consistency check 失敗時は GC を実行しない (fail-closed)。grace period 内の blob は削除しない。
→ `<|"Status" -> "DryRun"|"Deleted"|"Skipped", "Candidates" -> {...}, "Deleted" -> {hex...}, "ProtectedByInFlightWrite" -> {...}, "GraceSeconds" -> n, "Confirmed" -> True|False|>`
Options: `"ConfirmDelete" -> False` (True で実削除), `"GraceSeconds" -> Automatic` (Automatic は `SourceVaultGCGracePeriod[]` を使用)

### SourceVaultGCDryRun[opts] → Association
削除せずに GC 候補 blob を報告する。`SourceVaultRunGC["ConfirmDelete" -> False, opts]` と同じ。

### SourceVaultRetentionPlan[scope, opts] → Association
blob 群の参照状態と retention 判定の計画を返す (削除しない)。
→ `<|"Status" -> "OK", "Scope" -> scope, "BlobCount" -> n, "Plan" -> {<|"Hash", "RefCount", "Referenced", "AgeSeconds"|>...}|>`

## Consistency / Test (§17.12.11)

### SourceVaultCheckVaultConsistency[opts]
vault の不変条件を検査し報告を返す。検査項目: event digest 一致、EventID 一意、pointer sequence 単調、cache 整合、blob hash 整合 (Quick 時 skip)、orphan tmp、stale lock。
→ `<|"Status" -> "OK", "Healthy" -> True|False, "EventCount" -> n, "EventIdUnique" -> True|False, "EventDigestMismatches" -> {path...}, "EventIdCollisions" -> {...}, "SidecarMissing" -> {path...}, "PointerIssues" -> {<|"Pointer", "Issue"|>...}, "BlobHashMismatches" -> {path...}, "OrphanTmp" -> {path...}, "StaleLocks" -> {name...}, "Quick" -> True|False|>`
Options: `"Quick" -> False` (True でblob hash 整合検査を skip し高速化)

### SourceVaultConcurrentWriteTest[opts]
append / blob / pointer の並行書込と idempotency / collision 検出を検証する。単一 kernel での逐次実行、または parallel kernel での並行実行をサポート。
→ `<|"Status" -> "OK", "Passed" -> True|False, "Criteria" -> <|"NoEventIdCollisionInBulk", "IdempotentRetry", "CollisionDetected", "BlobIdempotent", "PointerSequenceOK", "ConsistencyHealthy"|>, "Processes" -> n, "PerProcessEvents" -> n, "Parallel" -> True|False, "BulkEventsWritten" -> n, "Consistency" -> {...}|>`
Options: `"Processes" -> 2` (プロセス数), `"PerProcessEvents" -> 100` (プロセスあたりイベント数), `"Parallel" -> False` (True で ParallelTable 使用、parallel kernel が必要)