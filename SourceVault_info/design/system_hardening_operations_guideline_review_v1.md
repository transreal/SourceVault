# system_hardening_operations_guideline v1 レビュー

作成: 2026-07-06  
対象:
- `system_hardening_operations_guideline_v1.md`
- `system_hardening_operations_guideline/00_overview.md`
- `system_hardening_operations_guideline/01_seatbroker_spec_v0.1.md`
- `system_hardening_operations_guideline/02_health_v2_spec_v0.1.md`
- `system_hardening_operations_guideline/03_process_supervisor_spec_v0.1.md`
- `system_hardening_operations_guideline/04_llm_router_maturation_spec_v0.1.md`
- `system_hardening_operations_guideline/05_siem_events_spec_v0.1.md`

## 総評

方針そのものは妥当。特に「席を予算として扱う」「health を評価往復に引き上げる」「失敗を SIEM 化する」「LLM 経路を preflight / tier / accounting に分ける」という分解は、現行の ClaudeOrchestrator / SourceVault 系の不安定要因にかなり正面から当たっている。

ただし、実装仕様案 v0.1 のまま着手すると、次の 3 点で事故りやすい。

1. SIEM emit shim が既存 `SourceVaultDiagnosticsLog` への直接追記を前提にしており、親指針が P0 として潰そうとしている JSONL 多重追記を再導入し得る。
2. ProcessSupervisor は `StartProcess` 後に manifest を書く設計に読めるため、親カーネルがその隙間で死ぬと、まさに回収したい孤児が manifest なしで残る。
3. SeatBroker の楽観競合制御は、UUID token ファイル作成を原子操作としているが、それは acquisition 全体の相互排他になっていない。

以下、実装前に仕様へ反映したい指摘を優先度順に並べる。

## Findings

### P0-1: SIEM が JSONL 多重追記リスクを再導入する

参照:
- `system_hardening_operations_guideline/00_overview.md:17`
- `system_hardening_operations_guideline/00_overview.md:29`
- `system_hardening_operations_guideline/05_siem_events_spec_v0.1.md:14`
- `system_hardening_operations_guideline/05_siem_events_spec_v0.1.md:45-52`
- `system_hardening_operations_guideline/05_siem_events_spec_v0.1.md:69`
- `SourceVault_diagnostics.wl:666-680`

`00_overview` は JSONL 追記を「書き手 1 プロセス限定」としているが、`05_siem_events_spec` は SourceVault ロード済みなら各 producer が `SourceVaultDiagnosticsLog[record]` へ直接 emit する設計になっている。現行 `SourceVaultDiagnosticsLog` は machine-scoped な `diagnostics-log.jsonl` を `OpenAppend` で直接追記しているため、claudecode / ClaudeRuntime / service kernel など複数 WL プロセスが同一 machine log を同時に書ける。

これは親指針の P0-6「JSONL 非アトミック追記 x Dropbox」を、診断基盤の中心に再導入する形になる。しかも `LLMCall` は全件記録かつレート制御なしなので、ログ量と競合頻度が上がる。

推奨修正:

- `05` の Inc 1 は、`SourceVaultDiagnosticsLog` 直書きではなく、まず machine-local spool に書く方針へ変更する。
- SourceVault service だけを SIEM の single writer / rollup writer にする。WL producer は `$UserBaseDirectory/ApplicationData/ClaudeRuntime/diag-spool/<producer>/<pid>.jsonl` のようなローカル per-process ファイルへ書き、service が低頻度で取り込む。
- 既存 `SourceVaultDiagnosticsLog` を使う場合も、少なくとも per-process/per-producer ファイル化してから rollup する。
- `LLMCall` は高頻度なので、最初から per-day/per-process shard と prune/rollup を仕様に入れる。

この修正は `05` が全案の前提になっているため、最初に潰すべき。

### P0-2: ProcessSupervisor に spawn 後 manifest 書き込みのクラッシュ窓がある

参照:
- `system_hardening_operations_guideline/03_process_supervisor_spec_v0.1.md:3`
- `system_hardening_operations_guideline/03_process_supervisor_spec_v0.1.md:38-40`
- `system_hardening_operations_guideline/03_process_supervisor_spec_v0.1.md:69-73`
- `system_hardening_operations_guideline/03_process_supervisor_spec_v0.1.md:79-81`

仕様の目的は「poll tick が死ぬと spawn 済みプロセスが漏れる」問題を閉じることだが、API 説明は `StartProcess 実行 + PID/StartTime 取得 + manifest 書き込み` を一体で行う、としている。この順序だと、`StartProcess` 成功後、manifest 書き込み前に親カーネルが死んだ場合、次回起動時の reap はそのプロセスを発見できない。

推奨修正:

- 2 相 manifest にする。
  - Phase A: `PendingSpawn` manifest を先に atomic write する。cmd / purpose / owner / deadline / seatToken / createdAt を記録。
  - Phase B: `StartProcess` 成功後に PID / ProcessStartTime / state=`Running` を追記して atomic rename。
  - Phase C: Phase B に失敗したら、その場で kill + seat release を試み、`SpawnManifestFinalizeFailed` を emit。
- reap は `PendingSpawn` が一定時間以上残った場合も cleanup / seat release する。
- 検証に「`StartProcess` 直後、manifest finalize 前に親カーネルを kill」するクラッシュ注入を追加する。

これを入れないと、仕様名に反して「最も嫌なタイミングの孤児」だけ回収対象外になる。

### P1-1: SeatBroker の競合制御が acquisition を直列化していない

参照:
- `system_hardening_operations_guideline/01_seatbroker_spec_v0.1.md:72-78`
- `system_hardening_operations_guideline/01_seatbroker_spec_v0.1.md:82`
- `system_hardening_operations_guideline/01_seatbroker_spec_v0.1.md:100-102`

`CreateFile` が原子的という記述は正しいが、UUID token ごとのファイル作成は互いに衝突しないので、Acquire 全体の相互排他にはならない。複数プロセスが同時に `free > 0` を見て token を発行し、全員が recheck を通過する/または self-revoke 判定が揺れる可能性がある。

また、Phase 1 の個別ゲートは broker 台帳を使わないため、同時チェックの全通過を防げない。P0 の即効性はあるが、実装順としては Inc 1 の broker skeleton を先に入れ、個別ゲートも薄く `ClaudeSeatAcquire` に寄せる方が安全。

推奨修正:

- `<machine-local>/seatbroker/acquire.lock` のような固定 lock を `CreateDirectory` または固定名 `CreateFile` で取る。TTL 付きで stale lock を破棄する。
- lock 内で `reap expired -> read ledger -> measure capacity -> write token -> re-read` を行う。
- lock 取得失敗は短い jitter retry 後に `Failure["SeatBrokerBusy", <|"Deferred"->True|>]`。
- Phase 1 は「直接 gate」ではなく「broker が無い場合だけ diagnostics probe による暫定 gate」と明記する。
- `Acquire` 後、実 spawn に失敗した場合の release を各 spawn 点の仕様に明記する。

### P1-2: Health v2 の service L2 が親指針の「eval round-trip」を満たしていない

参照:
- `system_hardening_operations_guideline/02_health_v2_spec_v0.1.md:3`
- `system_hardening_operations_guideline/02_health_v2_spec_v0.1.md:12-15`
- `system_hardening_operations_guideline/02_health_v2_spec_v0.1.md:56`
- `system_hardening_operations_guideline/02_health_v2_spec_v0.1.md:61`

親指針は health を「評価が返ること」と定義している。一方、`02` は SourceVault service の L2 を heartbeat counter の進行で代替している。heartbeat 進行が service の公開処理系・RPC・キュー処理の健全性と同じループなら成立するが、そうでない場合は「heartbeat は進むが実処理は詰まる」green-but-dead が残る。

推奨修正:

- service に軽量 ping/eval コマンドを追加できるなら、L2 はそれを使う。
- 追加しない場合、service の counter 進行は L3 とし、L2 代替であることを明示する。その場合 OK ではなく最大 Degraded に落とす設計も検討する。
- proxy health の初回読み時に「前回 counter がない」状態をどう扱うかを定義する。例: 初回は `Unknown` / `Degraded`、2 回目以降に進行判定。

`SourceVaultMCPRunningQ` を gateway `/health ok` に寄せる方針は良い。service 側だけ、親指針の言葉と実装証拠の強さがずれている。

### P1-3: SIEM shim の producer / schema 境界が曖昧

参照:
- `system_hardening_operations_guideline/05_siem_events_spec_v0.1.md:20`
- `system_hardening_operations_guideline/05_siem_events_spec_v0.1.md:34`
- `system_hardening_operations_guideline/05_siem_events_spec_v0.1.md:39-48`
- `SourceVault_diagnostics.wl:673-675`

shim 例では `"Producer" -> "claudecode"` が固定値になっている。ClaudeRuntime や servicemanager に同一実装を置くと、イベントの出所が誤記録される。また、既存 diagnostics log は `Type` / `Component` / `ReasonCode` 系の記録が多く、新 schema は `EventClass` / `Severity` / `Payload` を主軸にしている。既存 reader / rollup / SystemDoctor 集計がどちらを見るかを仕様で明確にしないと、イベントは書かれるが読まれない状態になり得る。

推奨修正:

- `iClaudeDiagEmit[class, payload, severity, opts]` に `"Producer"` option を持たせるか、各パッケージで `$ClaudeDiagProducer` を定義する。
- `Type -> "DiagnosticsEvent"` を新 SIEM record に必ず付けるか、既存 reader 側の `EventClass` 対応を Inc 1 に含める。
- `Severity` と既存 `Health` / `ReasonCode` の対応表を追加する。

### P1-4: SeatBroker と ProcessSupervisor の責務境界に「完了時 release」の失敗処理が不足

参照:
- `system_hardening_operations_guideline/01_seatbroker_spec_v0.1.md:60-69`
- `system_hardening_operations_guideline/03_process_supervisor_spec_v0.1.md:42-44`
- `system_hardening_operations_guideline/03_process_supervisor_spec_v0.1.md:51-60`

`ClaudeSupervisedComplete` が SeatToken を release する構想は良い。ただし、完了検出側が落ちる、DoneMarker はあるが Complete が呼ばれない、archive 移動に失敗する、release が UnknownToken になる、などのケースが仕様上まだ曖昧。

推奨修正:

- manifest state を `PendingSpawn | Running | Completed | Reaped | Vanished | CleanupFailed` のように明示する。
- DoneMarker 存在時の cleanup は `Complete` と同じ release path を通ると明記する。
- release 失敗時は manifest を残して retry するのか、archive へ移すのかを決める。
- SeatBroker の `SeatLeaked` と ProcessSupervisor の `ProcessVanished` / `OrphanReaped` の emit 条件を対応表にする。

### P2-1: LLM Router は実装前に TaskClass 語彙と fallback 契約を固定したい

参照:
- `system_hardening_operations_guideline/04_llm_router_maturation_spec_v0.1.md:24`
- `system_hardening_operations_guideline/04_llm_router_maturation_spec_v0.1.md:31-36`
- `system_hardening_operations_guideline/04_llm_router_maturation_spec_v0.1.md:66-72`
- `system_hardening_operations_guideline/04_llm_router_maturation_spec_v0.1.md:133-135`

TaskClass 未申告時の後方互換を保つ設計は良い。一方で、`extract/classify/summarize/code/design/general` だけだと、autotrigger / orchestrator / mail / mining の境界で「安い分類なのか、失敗時 cloud escalate すべき重要判断なのか」が曖昧になりやすい。

推奨修正:

- 初版 TaskClass を仕様末尾の未解決事項ではなく、v0.1 の固定表として置く。
- TaskClass ごとに `AllowEscalation`, `RequiresValidator`, `MaxCostClass`, `DefaultTimeout` を定義する。
- schema validator 契約は 04 Inc 3 の前提にする。Function か contracts schema assoc かを Inc 2 までに決める。

### P2-2: Health v2 のサンプルに実装時混入しそうな typo がある

参照:
- `system_hardening_operations_guideline/02_health_v2_spec_v0.1.md:41`

`KERNEEL_ALIVE` は typo。仕様サンプル由来のコピー事故を避けるため、`KERNEL.alive()` 相当の疑似コードに直す。

## 良い点

- 親指針の 10 原則は実装時の判断基準として使いやすい。特に「席は予算」「health = 評価が返ること」「書き込みは write-temp-rename / append は single writer」は、既存障害の再発防止に直結している。
- 5 案の分割は概ね自然。`05 SIEM` を先に置く設計も、上記 P0-1 を直せばかなり良い。
- `03 ProcessSupervisor` の PID 再利用対策として `ProcessStartTimeUTC` を必須にしている点は強い。これは実装で絶対に落とさない方がよい。
- `04 LLM Router` の LM Studio `/api/v0/models` preflight と `/api/v1` state 欠落への注意は、実運用知見が反映されていて良い。

## 推奨修正順

1. `05_siem_events_spec_v0.1.md` を修正し、SIEM 書き込みを single-writer / local spool 前提に変える。
2. `03_process_supervisor_spec_v0.1.md` に 2 相 manifest と spawn 後 finalize 失敗時の kill/release を追加する。
3. `01_seatbroker_spec_v0.1.md` に固定 acquire lock と、Phase 1 の broker 優先導入を追加する。
4. `02_health_v2_spec_v0.1.md` で service L2 の証拠を再定義する。可能なら軽量 ping/eval を追加する。
5. `05` の producer/schema 境界を明確化し、既存 diagnostics reader が新イベントを読めることを Inc 1 の検証条件に入れる。
6. `04` の TaskClass / validator / escalation 契約を固定する。

## 実装 Go/No-Go

現状のまま大きく実装へ進むのは少し危険。特に `05` は全仕様の前提なので、P0-1 を直すまでは Go にしない方がよい。

ただし、親指針自体は Go。中期仕様案は v0.2 として上記を反映すれば、実装ロードマップとして十分使える。
