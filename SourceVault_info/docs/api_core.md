# SourceVault_core API リファレンス

パッケージ: `SourceVault`` (コンテキスト: `SourceVault`CorePrivate`` に実装)
ロード順: `SourceVault.wl` → `SourceVault_core.wl` → `SourceVault_searchindex.wl` → `SourceVault_servicemanager.wl`
GitHub: https://github.com/transreal/SourceVault_core

## Root 解決

### $SourceVaultCoreRoot
型: String | Automatic, 初期値: 未設定 (Automatic)
core storage の root directory override。未設定の場合 `SourceVault`$SourceVaultRoots["PrivateVault"]` を使う。どちらも未解決なら core API は fail-closed する。

### $SourceVaultInjectedRoots
型: Association | (未設定)
service kernel 起動時に `run.wls` から注入される root snapshot。main kernel では通常未設定。設定時は root 解決で最優先される (start-time snapshot)。

### $SourceVaultInjectedRootHash
型: String | (未設定)
注入された root 構成の hash。health check で main kernel と比較する。

### SourceVaultCoreRoot[] → String | Failure
core storage root の絶対パスを返す。解決できなければ `Failure["SourceVaultCoreRootUnresolved", ...]`。

### SourceVaultRootAssociation[] → Association
現在有効な root 解決結果を返す。`$SourceVaultInjectedRoots` (service kernel) を最優先し、次に `SourceVault`$SourceVaultRoots` (main kernel) を読む。両方未設定なら `<||>`。

### SourceVaultResolveRoots[] → Association
`SourceVaultRootAssociation[]` の別名。

### SourceVaultRoot[key] → String | Missing
root key (`"PrivateVault"` / `"Tmp"` / `"LocalState"` 等) のパスを返す。未解決なら `Missing["NotResolved", key]`。

### SourceVaultSetRoot[key, path] → String
root 設定を変更する (`SourceVault`$SourceVaultRoots` を更新)。設定変更のみで既存データの移動は行わない。service kernel では restart まで反映されない。

### SourceVaultRootConfigHash[] → String
現在の root 構成の SHA256 hex を返す。main kernel と service kernel の root 一致検証に使う。root が空なら `""`。

### SourceVaultStorageDir[class] → String | Failure
storage class の絶対パスを返す。
`class` の値: `"Raw"` (pv/raw/by-hash) / `"Meta"` (pv/raw/meta) / `"Parsed"` (pv/parsed) / `"Attachments"` (pv/attachments) / `"Compiled"` (pv/compiled/public) / `"LocalState"` (`SourceVaultRoot["LocalState"]`)。
不明な class は `Failure["SourceVaultUnknownStorageClass", ...]`。

## Digest / Canonicalization

### SourceVaultCanonicalizeForDigest[assoc, opts]
assoc を digest 用 canonical JSON 文字列に正規化する。Association key を再帰 sort し、DateObject を UTC ISO-8601 文字列化し、揮発 field を除外する。
→ String | Failure
Options: `"DropFields" -> {}` (追加除外する key のリスト)

### SourceVaultSnapshotDigest[assoc, opts]
canonical JSON の UTF-8 bytes の SHA256 を `"sha256:<hex>"` 形式で返す。
→ String | Failure
Options: `"DropFields" -> {}` (`SourceVaultCanonicalizeForDigest` と同じ)

揮発 field (digest 計算から自動除外): `CreatedAtUTC`, `StoredAtUTC`, `CreatedBy`, `BuildHost`, `RuntimeResolved`, `LocalPath`, `ResolvedCredential`, `ProcessID`, `LastAccessedAtUTC`, `Digest`。

## Immutable Snapshot Store (§8.2a)

### SourceVaultSaveImmutableSnapshot[class, assoc, opts]
assoc を immutable snapshot として content-addressed store に保存する。同一内容の再保存は idempotent。
→ `<|"Status" -> "OK", "Ref" -> "snapshot:class:hex", "Digest" -> "sha256:...", "Path" -> path, "Class" -> class, "Existed" -> True|False|>` | Failure
Options: `"Alias" -> None` (文字列を指定すると alias も同時に割り当てる), `"AliasOverwrite" -> False` (`True` で既存 alias を新 ref に張り替える＝同 alias で内容更新する rebuildable snapshot 用。既定は create-only で別 ref なら `NameCollision`)
例: `SourceVaultSaveImmutableSnapshot["parsed", <|"Title" -> "foo", "Body" -> "bar"|>, "Alias" -> "latest"]`

### SourceVaultLoadImmutableSnapshot[ref] → Association | Failure
snapshot ref または `"class/alias"` 形式を読み、digest 検証済み assoc を返す。
ref 形式: `"snapshot:class:hex"` または `"class/alias"`。

### SourceVaultReadSnapshot[id] → Association | Failure
`SourceVaultLoadImmutableSnapshot` の別名。

### SourceVaultVerifyImmutableSnapshot[ref] → Association
保存済み snapshot の digest を再計算して整合を検証する。
→ `<|"Status" -> "Valid"|"Mismatch", "Ref" -> ref, "StoredDigest" -> ..., "Recomputed" -> ..., "Valid" -> True|False|>`

### SourceVaultAllocateSnapshotAlias[class, alias, ref, opts] → Association | Failure
alias → ref の割り当てを行う。同 alias に異なる ref を割り当てようとすると `Failure["NameCollision", ...]` で拒否する (idempotent: 同じ ref なら成功)。`"Overwrite" -> True` で既存 alias を新 ref に張り替える (immutable blob は残し alias ポインタのみ更新)。
→ `<|"Status" -> "OK", "Alias" -> alias, "Ref" -> ref, "Existed" -> True|False, "Updated" -> True|False|>`

### SourceVaultImmutableSnapshotExistsQ[ref] → True | False
不変スナップショット本体がストアに存在するか判定する。
ref 形式: `"snapshot:class:hex"` / `"class/alias"` / `"sv://snapshot/class/hex"`。

## Privacy (privacy invariant phase 1)

### $SourceVaultDefaultObjectPrivacyLevel
型: Real, 初期値: 0.85
privacy 未指定オブジェクトの既定 privacy level。クラウド閾値 (0.5) を超えるため、明示ダウングレードしない限りクラウド sink へ出ない (fail-closed)。

### SourceVaultSnapshotPrivacyLevel[ref] → Real
不変スナップショットの privacy level を返す。privacy サイドレコードがあればその `Level`、無ければ `$SourceVaultDefaultObjectPrivacyLevel` (0.85)。`[0.0, 1.0]` に clip される。read-only。変更は `NBAccess`NBSetSnapshotPrivacyLevel` 経由のみ。

### SourceVaultSnapshotPrivacyRecord[ref] → Association
不変スナップショットの privacy サイドレコードを返す。
キー: `Level` / `Source` / `Present` / `Class` / `Hex` / `Ref` / `Encrypted`。
サイドレコード未設定でも既定値 (`Level -> 0.85`, `Present -> False`) で返す。

### SourceVaultSetImmutableSnapshotPrivacyLevel[ref, level] → Association
不変スナップショットの privacy サイドレコードを設定する (本体は不変なので別ファイル)。
→ `<|"Status" -> "OK"|"Failed", "Ref" -> ref, "SnapshotKind" -> "Immutable", "OldPrivacyLevel" -> old, "NewPrivacyLevel" -> new, "Lowered" -> True|False, "PrivacyLevelSource" -> "Manual", "SetAt" -> ts|>`
サンクションされた呼び出し経路: `NBAccess`NBSetSnapshotPrivacyLevel` → `SourceVault`SourceVaultSetSnapshotPrivacyLevel` → この関数。直接呼び出しは承認ゲートを迂回する。

## Lock primitive (§17.12.2)

### SourceVaultTryLock[name, opts]
atomic directory creation で lock を一度だけ試みる (指数 backoff なし)。同一 host の期限切れ lock は自動回収する。異 host の lock は `"NeedsOperatorRecovery"` として返す。
→ `<|"Acquired" -> True|False, "Handle" -> <|"LockName", "LockDir", "Owner", "PID", "Host"|>, "Reason" -> "Created"|"RecoveredStale"|"Held"|"NeedsOperatorRecovery", ...|>`
Options: `"TTLSeconds" -> 30` (lock の有効期間)

### SourceVaultWithLock[name, body, opts]
`SetAttributes[HoldRest]`。lock を取得して body を評価し、必ず lock を解放する。取得できなければ `Failure["LockTimeout", ...]` を返す。body は lock 取得まで評価されない。Abort 時も lock を解放してから再 Abort する。
→ body の評価結果 | Failure
Options: `"TimeoutSeconds" -> 5` (取得タイムアウト秒), `"TTLSeconds" -> 30` (lock TTL 秒)
例: `SourceVaultWithLock["my-lock", doSomething[], "TimeoutSeconds" -> 10]`

### SourceVaultReleaseLock[handle] → Association | Failure
`SourceVaultTryLock` が返した `Handle` Association を渡して lock を解放する。他プロセスの lock は解放しない (Owner 同一性確認、不一致なら `<|"Status" -> "NotOwner", ...|>`)。handle が不正なら `Failure["BadLockHandle", ...]`。

### SourceVaultRecoverLocks[opts] → Association
同一 host の期限切れ (stale) lock を回収する。異 host の lock は回収せず `NeedsOperatorRecovery` として報告する。
→ `<|"Status" -> "OK", "Recovered" -> {lockName, ...}, "NeedsOperatorRecovery" -> {<|"LockDir", "Owner"|>, ...}|>`

## Event log (§17.12.5)

### SourceVaultAppendEvent[event, opts]
event を append-only event directory に one-event-one-file で commit する。`EventID` が無ければ `"evt:"<>CreateUUID[]` を付与。`Digest` と `CreatedAtUTC` を補う。同一 `EventID` の再 commit は digest 一致なら idempotent 成功、不一致なら `"EventIdCollision"`。内部で `"vault-write-event"` lock を取得する。
→ `<|"Status" -> "OK"|"EventIdCollision"|"CommitFailed", "EventID" -> eid, "Digest" -> "sha256:...", "Path" -> path, "Idempotent" -> True|False, "Ref" -> "event:evt:..."|>`

### SourceVaultTransactionLog[opts]
event directory の event を新しい順に返す。
→ List[Association]
Options: `"Limit" -> 100` (取得上限; `All` で全件), `"EventClass" -> All` (class でフィルタ)

## Blob store (§17.12.6)

### SourceVaultCommitBlob[data, opts]
`ByteArray` または `String` (UTF-8) を content-addressed blob として create-only で保存する。同一内容の再保存は idempotent。hash 不一致の既存 blob は `Failure["BlobCorruption", ...]` で fail-closed。
→ `<|"Status" -> "OK", "Hash" -> hex, "BlobRef" -> "blob:sha256:hex", "Path" -> path, "Existed" -> True|False|>` | Failure
Options: `"Meta" -> <||>` (meta.json に保存するメタデータ Association)

### SourceVaultReadBlob[hashOrRef] → Association
`SourceVaultCommitBlob` の読み出し対。content-addressed blob を読み、読み出し時に hash を再計算して検証した bytes を返す。不一致は `"BlobCorruption"` で fail-closed。main kernel 用 storage primitive であり MCP / 低trust へは公開しない。
`hashOrRef` 形式: `"blob:sha256:<hex>"` / `"sha256:<hex>"` / `<hex64>` / `"sv://hash/sha256/<hex>"`。
→ `<|"Status" -> "OK", "Hash" -> hex, "Bytes" -> ByteArray, "Path" -> path, "Meta" -> assoc|>` | `<|"Status" -> "Error", "Reason" -> "BadHash"|"BlobNotFound"|"BlobReadFailed"|"BlobCorruption", ...|>`

### SourceVaultBlobRefs[hash, opts] → Association
blob hash を参照する snapshot / event を走査して参照元を返す。
`hash` 形式: hex / `"sha256:hex"` / `"blob:sha256:hex"`。
→ `<|"Hash" -> hex, "RefCount" -> n, "Refs" -> {path, ...}|>`

## Artifact content resolve (sanctioned reader)

### SourceVaultResolveArtifactContent[uriOrId, opts]
deposit 済み artifact の内容を PrivacyLevel 付きで解決する main-kernel sanctioned reader。`sv://artifact/<id>` / bare `<id>` は DerivedArtifact snapshot → blob を辿り、`sv://hash/sha256/<hex>` / `"blob:sha256:<hex>"` は blob 直接参照する (この場合 PrivacyLevel は fail-closed 既定)。生データを PrivacyLevel なしで返すことはなく、PrivacyLevel 欠落時は既定値 (0.85) に fail-closed。サンクションされた表示経路は `NBAccess`NBInsertArtifactCell` (privacy marking 付きノートブック表示) であり、MCP / 低trust projection へは公開しない。
→ `<|"Status" -> "OK"|"Error", "ArtifactId" -> id|Missing, "Ref" -> ref, "MediaKind" -> "Image"|"Video"|"Text"|"Binary", "MediaType" -> mt, "PrivacyLevel" -> level, "Bytes" -> ByteArray | "Text" -> str, "File" -> path|Missing, "Filename" -> name|Missing|>`
Options: `"Materialize" -> Automatic` (`Automatic` は Video/Binary のみ vault 内 `materialized/` へ content-addressed にファイル化。`True` で常にファイル化、`False` でしない)
MediaKind 判定: `image/gif` は Video 扱い、`image/*` → Image、`video/*` → Video、`text/*` / `application/json` → Text、他は Binary。

## Rate limit (過剰実行対策)

NBAccess は `SourceVault*` head を承認不要 (trusted package) として扱う。その代償として、高コスト/副作用のある公開関数は entry でこの sliding-window limiter を通し、runaway loop や LLM 生成コードの暴走を止める。

### $SourceVaultRateLimits
型: Association, 初期値: `<|"Ingest" -> <|"Limit" -> 120, "WindowSeconds" -> 3600|>, "ComfyUISubmit" -> <|"Limit" -> 60, "WindowSeconds" -> 3600|>, "Default" -> <|"Limit" -> 600, "WindowSeconds" -> 3600|>|>`
key 別 rate limit 設定。既定: Ingest 120/h, ComfyUISubmit 60/h, Default 600/h。未定義 key は `"Default"` を使う。意図的な一括処理は window を待つか limit を上げる。

### SourceVaultRateLimit[key] → Association
key の sliding-window 実行回数を記録し、上限内なら許可、超過なら拒否を返す (カーネル内 in-memory)。`SourceVaultIngest` / `SourceVaultComfyUIQueuePrompt` 等の高コスト公開関数が entry で呼ぶ。
→ 許可: `<|"Allowed" -> True, "Key" -> key, "Count" -> n, "Limit" -> lim, "WindowSeconds" -> win|>`
→ 超過: `<|"Allowed" -> False, "Key" -> key, "Count" -> n, "Limit" -> lim, "WindowSeconds" -> win, "Hint" -> ...|>`

## Pointer (§17.12.7)

### SourceVaultAtomicUpdatePointer[name, value, opts] → Association | Failure
pointer を更新する。内部で `"active-pointer:<name>"` lock を取得し、pointer event を追加して `active.json` cache を更新する。
→ `<|"Status" -> "OK", "Name" -> name, "Sequence" -> n, "Value" -> value, "EventRef" -> "evt:..."|>`

### SourceVaultPointerReplay[name, opts] → Association | Failure
pointer event を replay し、最大 `Sequence` の digest 検証済み値を返す。
→ `<|"Status" -> "OK"|"Empty", "Value" -> v, "Sequence" -> n, "EventCount" -> total, "ValidCount" -> valid, "CacheConsistent" -> True|False, "SequenceDuplicated" -> True|False|>`

### SourceVaultPointerHistory[name] → List[Association]
pointer の digest 検証済み event 履歴を `Sequence` 昇順で返す。各要素: `<|"Sequence" -> n, "Value" -> v, "CreatedAtUTC" -> s|>`。rollback 等で前版を辿るのに使う。

## GC / Retention (§17.12.10)

### SourceVaultGCGracePeriod[] → Integer
in-flight blob 保護の既定 grace period (秒) を返す。既定値 86400 (24 時間)。

### SourceVaultGCDryRun[opts] → Association
削除せずに GC 候補 blob を報告する。`SourceVaultRunGC["ConfirmDelete" -> False]` と同じ。

### SourceVaultRunGC[opts]
未参照かつ retention 期限切れの blob を回収する。grace period 内の blob / in-flight write / replay 失敗 vault は削除しない (fail-closed)。実削除前に `SourceVaultCheckVaultConsistency["Quick" -> True]` を実行し、不健全な vault では GC しない。
→ `<|"Status" -> "DryRun"|"Deleted"|"Skipped", "Candidates" -> [...], "Deleted" -> [hex, ...], "ProtectedByInFlightWrite" -> [...], "GraceSeconds" -> n, "Confirmed" -> True|False|>`
Options: `"ConfirmDelete" -> False` (True にしないと実削除しない), `"GraceSeconds" -> Automatic` (Automatic は `SourceVaultGCGracePeriod[]` の値)

### SourceVaultRetentionPlan[scope, opts] → Association
blob 群の参照状態と retention 判定の計画を返す (削除しない)。
→ `<|"Status" -> "OK", "Scope" -> scope, "BlobCount" -> n, "Plan" -> [{<|"Hash", "RefCount", "Referenced", "AgeSeconds"|>}, ...]|>`

## Consistency / Test (§17.12.11)

### SourceVaultCheckVaultConsistency[opts]
vault の不変条件を検査し報告を返す。検査項目: event digest 一致 / EventID 一意 / pointer sequence 単調 / cache 整合 / blob hash 整合 (quick でない場合) / orphan tmp / stale lock。
→ `<|"Status" -> "OK", "Healthy" -> True|False, "EventCount" -> n, "EventIdUnique" -> True|False, "EventDigestMismatches" -> [...], "EventIdCollisions" -> [...], "SidecarMissing" -> [...], "PointerIssues" -> [...], "BlobHashMismatches" -> [...], "OrphanTmp" -> [...], "StaleLocks" -> [...], "Quick" -> True|False|>`
Options: `"Quick" -> False` (True にすると blob hash 整合チェックをスキップして高速化)

### SourceVaultConcurrentWriteTest[opts]
append / blob / pointer の並行書込と idempotency / collision 検出を検証する。内部で `SourceVaultCheckVaultConsistency[]` を実行する。
→ `<|"Status" -> "OK", "Passed" -> True|False, "Criteria" -> <|"NoEventIdCollisionInBulk", "IdempotentRetry", "CollisionDetected", "BlobIdempotent", "PointerSequenceOK", "ConsistencyHealthy"|>, "Processes" -> n, "PerProcessEvents" -> n, "Parallel" -> True|False, "BulkEventsWritten" -> n, "Consistency" -> ...|>`
Options: `"Processes" -> 2` (仮想プロセス数), `"PerProcessEvents" -> 100` (プロセスあたり event 数), `"Parallel" -> False` (True かつ parallel kernel 存在時に `ParallelTable` を使用)

## 識別子フォーマット

| 種類 | フォーマット |
|------|-------------|
| event id | `"evt:" <> CreateUUID[]` |
| blob ref | `"blob:sha256:" <> hex` |
| snapshot ref | `"snapshot:" <> class <> ":" <> hex` |
| digest | `"sha256:" <> hex` |

## 設計上の注意点

- LLM / HTTP 等の長時間処理中は data lock を保持しない (§17.12.1)。
- 書き込みは append-only (one-event-one-file)。既存 object の破壊的更新は禁止。
- lock 取得は atomic directory creation を使う (advisory file lock に依存しない)。
- `CommandID` / `EventID` の既定は `CreateUUID[]`。
- 異 host の stale lock は自動回収せず operator review が必要 (`NeedsOperatorRecovery`)。
- root が未解決な場合、core API は fail-closed する (推測 fallback しない)。
- blob 読み出し (`SourceVaultReadBlob`) / artifact 内容解決 (`SourceVaultResolveArtifactContent`) は main-kernel sanctioned reader であり、MCP / 低trust projection へは公開しない。生データは必ず PrivacyLevel を伴わせ、欠落時は既定 0.85 に fail-closed する。