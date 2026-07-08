# ProcessSupervisor 実装仕様案 v0.2 — 2 相 spawn manifest + 孤児回収

目的: 「poll tick が死ぬと spawn 済みプロセスが漏れる」構造(mail jobs / `$iExternalProcs`)を閉じる。すべての外部プロセス spawn を manifest 記録付きヘルパ経由にし、期限切れ・親不在プロセスを決定論的に回収する。

指針対応: P1-1（orphan プロセス）。01 SeatBroker の token 返却漏れ対策とも連動。

変更履歴:
- v0.2: レビュー r1 反映。**(P0-2)** manifest を 2 相化（PendingSpawn → Running）。StartProcess 成功後・manifest 確定前に親カーネルが死ぬクラッシュ窓を閉じ、finalize 失敗時の kill/release（Phase C）を追加。クラッシュ注入テストを検証レシピに追加。**(P1-4)** manifest 状態機械（PendingSpawn/Running/Completed/Reaped/Vanished/CleanupFailed）を明示、DoneMarker cleanup が Complete と同一 release path を通ることを明記、release 失敗時の扱いと emit 条件対応表（§7）を追加。

## 1. スコープ / 非目標

- スコープ: claudecode / ClaudeRuntime / servicemanager が起動する**一時プロセス**（wolframscript ジョブ、PowerShell ランナー）。
- 非目標: 常駐サービス（service kernel / watchdog / proxy）の生死管理 — 02 Health v2 の責務。supervisor は常駐プロセスの manifest を「登録のみ」行い、回収対象にしない（`"Persistent"->True`）。

## 2. 配置

- 新規ファイル: `ClaudeRuntime_processsupervisor.wl`（context `ClaudeRuntime``）。SourceVault 非依存、emit は 05 shim 経由。
- manifest ディレクトリ: `FileNameJoin[{$UserBaseDirectory, "ApplicationData", "ClaudeRuntime", "processes"}]`（**Dropbox 外**。PID はマシンローカルな事実であり同期は誤り）。

## 3. manifest schema と状態機械

`processes/<jobId>.json`（すべての遷移は write-temp-rename）:

```json
{"JobId": "mail-fetch-20260706-...", "State": "Running",
 "Pid": 23456, "ProcessStartTimeUTC": "2026-07-06T04:12:33Z",
 "Exe": "wolframscript", "Cmd": ["wolframscript","-file","..."],
 "Purpose": "MailFetch",
 "OwnerKernelPid": 12345, "CreatedAtUTC": "...", "SpawnedAtUTC": "...",
 "DeadlineUTC": "2026-07-06T04:22:33Z",
 "SeatToken": "seat-...", "DoneMarker": "C:/.../done.json",
 "Persistent": false,
 "CleanupFailure": null}
```

### 3.1 状態機械（P1-4）

```
PendingSpawn ──(StartProcess成功+finalize成功)──▶ Running
     │  │                                          │
     │  └─(finalize失敗: Phase C kill/release)──▶ 終了(archive) or CleanupFailed
     │
     └─(猶予超過: spawn されなかった/親死亡)──▶ 終了(archive, seat release)

Running ──(DoneMarker検出 or Complete呼び出し)──▶ Completed ──cleanup──▶ archive
   │
   ├─(Deadline超過: reap が kill)──▶ Reaped ──cleanup──▶ archive
   ├─(プロセス不在/StartTime不一致)──▶ Vanished ──cleanup──▶ archive
   └─(cleanup のどこかが失敗)──▶ CleanupFailed（manifest 残置・次回 reap が再試行）
```

- **`ProcessStartTimeUTC` は必須**。回収時に `Get-Process -Id pid` の StartTime と照合し、不一致なら **PID 再利用**と判定して kill しない（無関係プロセス誤殺の防止。本仕様の最重要正しさ要件）。
- `DeadlineUTC`: 用途別既定（mail job 15min / external runner は expectedSeconds×3・上限 2h / 既定 30min）。
- `CleanupFailed` は `CleanupFailure -> <|"Step"->"Kill"|"Archive"|"SeatRelease", "AtUTC"->...|>` を保持し、次回 reap が該当 Step から再試行する。**release 失敗で manifest を archive に流さない**（席リークの追跡可能性を優先）。

## 4. API

```wolfram
ClaudeSupervisedStartProcess[cmd_List, purpose_String, opts] → <|"Process"->proc, "JobId"->..., "Manifest"->path|> | Failure["SpawnFailed"|"SpawnManifestFinalizeFailed", ...]
  (* opts: "DeadlineSeconds", "DoneMarker", "SeatToken", "JobId", "Persistent" *)
  (* 内部は §5 の 2 相。呼び出し側から見れば従来 StartProcess の置き換え *)

ClaudeSupervisedComplete[jobId_String] → True | Failure["CleanupFailed", ...]
  (* 正常完了時: State->Completed → cleanup（archive 移動 + SeatToken release）。§6 の分類 1 と同一 path *)

ClaudeProcessReap[] → <|"Reaped"->{...}, "Expired"->n, "OrphanOwner"->m, "PendingExpired"->p, "CleanupRetried"->r, "Skipped"->k|>

ClaudeProcessInventory[] → Dataset   (* 診断用: 生存 manifest 一覧 + 実プロセス照合 + State 別集計 *)
```

## 5. spawn の 2 相プロトコル（P0-2）

```
Phase A（spawn 前）:
  manifest を State="PendingSpawn" で atomic write。
  記録: JobId / Cmd / Purpose / OwnerKernelPid / DeadlineUTC / SeatToken / CreatedAtUTC。
  （この時点で「これから起きるプロセス」の存在が永続化される）

Phase B（spawn）:
  StartProcess 実行 → PID / ProcessStartTimeUTC 取得
  → manifest に追記し State="Running" で atomic rename。

Phase C（Phase B の finalize 失敗時）:
  StartProcess は成功したが PID/StartTime 取得 or manifest 書き込みに失敗した場合:
    その場で kill を試行（proc オブジェクト経由 KillProcess、失敗時 taskkill）
    + SeatToken release を試行
    + SpawnManifestFinalizeFailed を emit（KillAttempted/KillSucceeded を payload に）。
    kill まで失敗した場合は manifest を State="CleanupFailed"（Step="Kill"）で残す
    （PendingSpawn に Cmd が残っているため、reap が Exe+CommandLine 照合で後追い回収を試みる）。
```

- **クラッシュ窓の解析**: Phase A 前に死 → 何も起きていない（プロセス無し）。Phase A〜B 間に死 → プロセスは存在し得るが `PendingSpawn` manifest が残るので §6 分類 2' が回収。Phase B 後に死 → `Running` manifest が残り通常の reap 対象。**どのタイミングで親が死んでも manifest なしの孤児は生じない。**
- 残余リスク: Phase A〜B 間クラッシュで実プロセスが起きていた場合、PID 不明のため確実な kill はできない。reap は `PendingSpawn` の Cmd（実行ファイル+スクリプトパス）と一致するプロセスを Get-CimInstance の CommandLine 照合で探し、一致・単一・当該 CreatedAtUTC 以降開始のものだけ kill する（曖昧なら kill せず `ProcessVanished`(Reason="PendingUnresolved") を emit して人間に委ねる）。

## 6. 回収ロジック（ClaudeProcessReap）

manifest 全走査で各 entry を分類:

```
1. State==Running かつ DoneMarker 存在
     → Completed へ遷移 → cleanup（archive + seat release）。
       ※ ClaudeSupervisedComplete と同一の cleanup 関数を通す（P1-4: path を分岐させない）
2. State==Running かつ プロセス不在（PID 無し or StartTime 不一致）
     → Vanished → cleanup + ProcessVanished emit（異常終了の痕跡）
2'. State==PendingSpawn かつ CreatedAtUTC + 猶予(既定 5min) 超過
     → §5 残余リスク手順で後追い解決 → cleanup + seat release
3. Persistent → skip
4. State==Running かつ DeadlineUTC 超過
     → taskkill /PID /T /F → Reaped → cleanup + OrphanReaped emit
5. State==Running かつ OwnerKernelPid 不在 かつ 猶予(10min) 超過
     → 同上（owner 死亡孤児）
6. State==CleanupFailed → CleanupFailure.Step から cleanup 再試行
7. それ以外 → 生存中、何もしない
```

- kill は `taskkill /T`（子プロセスツリーごと）。wolframscript は子カーネルを持つため /T 必須。
- cleanup の内部順序は固定: **①SeatToken release → ②archive 移動**（release を先にするのは、archive 成功後に release だけ失敗すると追跡が切れるため。①失敗なら CleanupFailed(Step="SeatRelease") で manifest 残置 → 次回 reap 再試行 → SeatBroker 側 TTL 失効が最終防衛線）。
- archive: `processes/archive/<yyyymmdd>/<jobId>.json` に最終 State + 回収理由を追記して移動。7 日超は削除。

## 7. emit 条件対応表（P1-4: SeatBroker との突き合わせ）

| 状況 | ProcessSupervisor の emit | SeatBroker 側の emit | 席の回収者 |
|---|---|---|---|
| 正常完了（Complete/DoneMarker） | なし（info 不要） | なし | supervisor cleanup ① |
| deadline 超過 kill | OrphanReaped | なし | supervisor cleanup ① |
| プロセス消滅（異常終了） | ProcessVanished | なし | supervisor cleanup ① |
| PendingSpawn 期限切れ | ProcessVanished(Reason="PendingExpired") | なし | supervisor cleanup ① |
| finalize 失敗 | SpawnManifestFinalizeFailed | なし | Phase C（即時） |
| cleanup の release 失敗が続き TTL 失効 | ProcessCleanupFailed(Step="SeatRelease") | **SeatLeaked**（TTL reaper が回収した時） | SeatBroker TTL reaper |
| supervisor 自体が動かず TTL 失効 | なし（動いていない） | **SeatLeaked** | SeatBroker TTL reaper |

`SeatLeaked` が出る = supervisor の cleanup が機能しなかった、という診断指標として読む。

## 8. 実行タイミング

1. **カーネル起動時**（ClaudeRuntime ロード時に 1 回、TimeConstrained[.., 10]）— 前セッションの残骸（PendingSpawn 含む）を回収。ここが最重要。
2. **共有 polling tick**（claudecode.wl の iSharedPollingTick へ登録、5 分に 1 回に間引き、TimeConstrained[.., 5]）。
3. **手動** `ClaudeProcessReap[]`（SystemDoctor からも呼べるように）。

tick 依存を 1. が補償する二重化により「tick が死ぬと漏れる」問題を構造的に解消する。

## 9. 既存 spawn 点の移行

| spawn 点 | 監査時点の位置 | 移行内容 |
|---|---|---|
| mail summary | claudecode.wl:5161 | `ClaudeSupervisedStartProcess[..., "MailSummary", "DeadlineSeconds"->900, "DoneMarker"->doneJson]`。完了検出時 `ClaudeSupervisedComplete` |
| mail fetch | claudecode.wl:5318 | 同上（"MailFetch"） |
| external runner | ClaudeRuntime_externalrunner.wl:890-900 | `$iExternalProcs` 登録と同時に 2 相 manifest。完了検出（1017-1020）で Complete。poll tick 停止時の孤児は reap が拾う |
| web-search PowerShell | claudecode.wl:2943, 8178 | **実装時判断 (2026-07-07) で延期**: これらは API/CLI 呼び出しの自己終了型プロセス（有限で自然終了・WL ライセンス席も非消費）であり、poll tick 死による無期限孤児化のリスクが実質無い。クリティカルな query 経路に手を入れるリスクの方が大きい。必要になれば同ヘルパで包むだけ |
| service/watchdog/proxy | servicemanager | `"Persistent"->True` で登録のみ（inventory 可視化目的） |

移行後、`$iClaudeMailSummaryJobs` / `$iExternalProcs` は「進行中ジョブの高速参照」として残してよいが、**真実は manifest**（カーネル再起動で in-memory は消えるが manifest は残る）。

## 10. 増分実装計画

- **Inc 1**: supervisor 骨格（2 相 spawn / 状態機械 / Reap / StartTime 照合 / cleanup 順序）。wolframscript 単体テスト:
  ① 短命子プロセス spawn→done→Completed→archive
  ② deadline 超過→kill→Reaped
  ③ PID 再利用（manifest の Pid を無関係 PID に書き換え StartTime 不一致 → kill せず Vanished）
  ④ owner kernel kill→孤児回収
  ⑤ **クラッシュ注入（P0-2）**: 子 wolframscript で Phase A のみ実行して即死 → 親再起動相当の Reap で PendingSpawn が回収されること / Phase B 直前で親を kill → 同様
  ⑥ finalize 失敗シミュレーション（manifest dir を一時 read-only 化）→ Phase C の kill + SpawnManifestFinalizeFailed
  ⑦ release 失敗（SeatBroker 未ロード等）→ CleanupFailed 残置 → 再 Reap で回収
- **Inc 2**: mail 2 経路 + web-search の移行。既存メールジョブのテストが green のまま。
- **Inc 3**: external runner 移行 + SeatToken 連携（01 Inc 3 と同期）。
- **Inc 4**: 起動時 reap + tick 登録 + ClaudeProcessInventory の SystemDoctor 統合。**tick 部分は NB 検証**。

## 11. 検証レシピ

```wolfram
Get["ClaudeRuntime.wl"];
(* 孤児シナリオ *)
r = ClaudeSupervisedStartProcess[{"powershell","-Command","Start-Sleep 300"},
      "test", "DeadlineSeconds"->5];
Pause[10];
ClaudeProcessReap[]   (* → Reaped に jobId、プロセスが実際に消えていること *)

(* クラッシュ窓 (Inc1-⑤): 別 wolframscript で
     Phase A 相当だけ実行して Exit[] → メインカーネルで ClaudeProcessReap[]
   → PendingExpired として回収され seat release されること *)

(* PID 再利用ガード: manifest の Pid を現存の無関係 PID に書き換え
   → Reap が kill せず Vanished 扱いにすること（対象プロセスが生きたまま） *)

(* 起動時回収: Running manifest を残したままカーネル再起動 → ロード時に回収 (NB) *)
```

## 12. 未解決事項

- external runner の expectedSeconds が無いジョブの既定 deadline（30min 案）の妥当性。
- PendingSpawn 後追い解決の CommandLine 照合精度（wolframscript の引数がどこまで一意か実測）。
- archive の保持期間（7 日案）と SIEM への rollup 要否。
- Linux/mac 対応（taskkill / Get-Process 部分の抽象化）は当面 win32 のみ。
