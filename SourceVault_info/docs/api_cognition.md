# SourceVault_cognition.wl API

Cane Phase 0: SensitiveLocalVault 契約(認知系データの保存境界・暗号化・crypto-shredding 消去)。
仕様: `sourcevault_cane_knowledge_home_mining_spec_v0_7.md` §2 I-1/I-3b/I-9・§4.11。
decision record: `SourceVault_info/design/sourcevault_cane_phase0_decisions_v1.md`。

人間 subject の認知系 event(OperationalSignalSampled / CognitiveSelfReported / RecallAssessed /
ThinkingContextSnapshotted 等)の**唯一の書込み口**。root は `<LocalState>/sensitive/cognition/`
(同期対象外)。PrivateVault/CoreRoot 配下は sink guard が実行時拒否(fail-closed)。
shard(subject×月)毎の AES256 鍵(NBAccess KeyRef、backend=SystemCredential/DPAPI)で行単位暗号化し、
消去=鍵削除(crypto-shredding)+ファイル削除+削除後検査。鍵喪失=復元不能(設計どおり)。

### $SourceVaultCognitionEnabled
型: Boolean, 既定 True。マスタースイッチ。False で全書込み拒否(「全推定を停止」の保存層実体)。

### $SourceVaultCognitionRetentionDays
型: Integer, 既定 730。retention 上限日数(§2 I-3b)。

### SourceVaultCognitionInitialize[opts]
SensitiveLocalVault を初期化(冪等)。sink guard / 鍵 backend 検査(SystemCredential 必須。
`"AllowMemoryBackend"->True` はテスト専用)/ 除外チェックリスト README 生成。
→ `<|Status, Root, Backend, MemoryBackendAllowed|>` / Failure
Options: `"Root"`(Automatic)、`"AllowMemoryBackend"`(False)。

### SourceVaultCognitionStatus[]
→ `<|Initialized, Root, Backend, Enabled, SubjectCount, ShardCount|>`

### SourceVaultCognitionAppendEvent[event, opts]
認知系 event を暗号化追記(専用 API)。必須: `"SubjectRef"`, `"OccurredAtUTC"`(bitemporal)。
`"ObservedAtUTC"` / `"EventId"`("cogev:<ULID>")自動補完。停止中/未初期化/検証失敗/sink 違反は Failure。
→ EventId 付き event / Failure
Options: `"Root"`(Automatic)。

### SourceVaultCognitionEvents[subjectRef, opts]
復号読み出し(OccurredAtUTC 昇順)。crypto-shred 済み shard は `Notes` に `"Shredded:<period>"`
として報告され本文は返らない(復活しない)。
→ `<|Events, Notes|>`
Options: `"Period"`(All | "yyyy-mm")、`"Root"`。

### SourceVaultCognitionSubjects[opts]
shard index にある subject ref 一覧(local のみ)。

### SourceVaultCognitionErase[subjectRef|All, opts]
物理消去(crypto-shredding)。削除 manifest(shard ファイル+KeyRef+bytes 列挙)→(実行時)
鍵削除→ファイル削除→index 更新→削除後検査(ファイル不存在+鍵 Missing+読み戻し空)→
metadata のみの監査行(subjectToken ハッシュ・件数。値/subject 平文なし)。**既定 DryRun=True**(impact report)。
→ `<|Manifest, Executed, Inspection(<|FilesGone,KeysGone,ReplayEmpty,Passed|>), BestEffortNote|>`
Options: `"Period"`(All | "yyyy-mm")、`"DryRun"`(True)、`"Root"`。

### SourceVaultCognitionPruneExpired[opts]
retention 超過 shard を消去機構で処理。→ `<|Cutoff, ExpiredShards, Results|>`
Options: `"DryRun"`(True)、`"Root"`。

### SourceVaultCognitionSetEnabled[True|False]
マスタースイッチ切替(即時)。

## 不変条件(実装で担保)

- I-1: 書込み先は SensitiveLocalVault のみ。PrivateVault/CoreRoot 配下 root は実行時拒否。
  平文は vault 内にも残らない(行単位暗号化)。監査行は metadata のみ。
- I-3b: retention 上限+owner による停止/消去。消去後の replay で復活しない(検査で保証)。
- I-9: bitemporal(OccurredAtUTC 必須・ObservedAtUTC 自動)。欠落 fail-closed。
