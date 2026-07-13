# Cane Phase 0 decision record v1(SensitiveLocalVault / 鍵 / 消去 / lease 基盤)

- 作成日: 2026-07-13
- 依拠: `sourcevault_cane_knowledge_home_mining_spec_v0_7.md` §2 I-1/I-3b/I-9、§4.11、§5.16
- 実装: `SourceVault_cognition.wl` / 検証: `test codes/SourceVault_cognition_test.wls`(43 checks)
- 位置づけ: 仕様が「SensitiveLocalVault への最初の書込み前に確定」(受入 24)と定める decision の記録。

## D-1 保存境界(root)

- 正準 root = `<LocalState>/sensitive/cognition/`。**LocalState は同期対象外**(既存規約)。
- **sink guard を実行時強制**: 解決 root が PrivateVault(Dropbox)/CoreRoot(クロスマシン共有)配下なら
  Initialize/Append とも Failure(fail-closed)。パス比較は正規化(ExpandFileName+小文字+区切り統一)prefix。
- 書込みは専用 API(`SourceVaultCognitionAppendEvent`)のみ。汎用 `SourceVaultAppendEvent` を認知系に使わない。
- マルチデバイス同期は行わない(v0.3 I-1。将来は E2E 暗号化つき別仕様)。

## D-2 threat model と暗号化

- 前提: OS フルディスク暗号化(BitLocker)を推奨基盤とし、その上にアプリ層暗号を重ねる。
- アプリ層: **shard(subject×月)毎の AES256 鍵**。鍵は NBAccess KeyRef 経由で
  **Windows Credential Manager(DPAPI)** に保存(`NBAccess`$NBCredentialBackend = "SystemCredential"` を必須化。
  Memory backend は `"AllowMemoryBackend" -> True` 明示時のみ=テスト専用、鍵はカーネル終了で消える)。
- event は行単位で encrypt(KeyRef 解決は NBAccess 内部、鍵材料は返らない)。ファイル形式は
  暗号文 B64 の JSONL(`shards/<subjectToken>-<yyyy-mm>.cogx`)。subjectToken は SHA-256 由来
  (credential 名・監査行に subject ref 平文を出さない)。
- **鍵喪失 = 当該 shard 復元不能(設計どおり)**。recovery を作らないことが crypto-shredding の前提。
  (owner が長期保全したい認知データはそもそも本ストアの対象ではない。)

## D-3 消去(crypto-shredding)と retention

- `SourceVaultCognitionErase[subject|All, "Period"->..]`:
  1. **削除 manifest**(全 shard ファイル+KeyRef+バイト数を列挙)— 既定 DryRun=impact report。
  2. 実行: **鍵削除が先**(ファイル残骸があっても復号不能)→ ファイル削除 → index 更新。
  3. **削除後検査**: ファイル不存在+`NBKeyStatus` Missing+読み戻し空(replay で復活しない)。
  4. 監査行は **metadata のみ**(subjectToken ハッシュ・件数・bytes・検査結果。値・subject 平文なし)。
- best-effort の限界を明示: OS レベル複製(crash dump / swap / 過去の手動コピー)は対象外(README に記載)。
- retention: `$SourceVaultCognitionRetentionDays`(既定 730)。`SourceVaultCognitionPruneExpired` が
  超過 shard を同じ消去機構で処理(DryRun 既定)。
- bitemporal(I-9): `OccurredAtUTC` 必須・`ObservedAtUTC` 自動補完。欠落は Failure(fail-closed)。

## D-4 除外チェックリスト(手動 OS 設定。README-EXCLUSIONS.txt として vault に常置)

- Dropbox/OneDrive 等クラウド同期: LocalState 配下から動かさない。
- Windows Search インデックス除外 / antivirus のクラウド検体送信除外 / OS バックアップ(File History 等)除外。
- crash dump / swap の平文残存は best-effort 限界として明示。

## D-5 CapabilityLease 正準基盤(§5.16 の decision。実装は Phase 1H-S)

- **二者択一にせず層合成**を採用: AccessProfile/Grant(MCP: authorization・provenance・epoch 失効)
  → ActionGate(servicemanager: action risk・可否)→ lease mint → **atomic consume+dispatch のみ新 broker ledger**。
- 新 broker は authorization/gate を再実装しない(上流 decision ref を参照)。二重正準を作らない。
- ledger の物理は cognition と同様の LocalState 系 + `.lockdir` CAS を第一候補とする(実装時に確定)。

## D-6 マスタースイッチと owner control

- `$SourceVaultCognitionEnabled`(既定 True)/ `SourceVaultCognitionSetEnabled[False]` で全書込み即時停止
  (「全推定を停止」の保存層実体。受入 12 の基盤)。
- 完全消去は `SourceVaultCognitionErase[All, "DryRun"->False]`。

## 検証(sink matrix ハーネス)

`SourceVault_cognition_test.wls`: marker 平文が vault 内(暗号化)・PrivateVault・CoreRoot のどこにも
現れないこと、cognition artifact が PrivateVault/CoreRoot に生じないこと、fail-closed(SubjectRef/
OccurredAtUTC 欠落・停止中・sink 違反 root)、消去の manifest→実行→検査→復活なし、shred 済み shard の
不可読、retention prune、を 43 checks で確認(2026-07-13 green)。
