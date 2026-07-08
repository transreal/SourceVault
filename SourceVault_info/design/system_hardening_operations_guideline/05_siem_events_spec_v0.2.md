# SIEM イベント拡充 実装仕様案 v0.2 — 「静かな失敗」の可視化

目的: spawn 失敗・席拒否・restart・tick 超過などの運用イベントを標準 schema で diagnostics（SIEM 層）へ集約し、「静かに諦める」コードパスを検出可能にする。他 4 案（01-04）の emit 基盤。

指針対応: P1-8（SessionSubmit 失敗の握り潰し）、原則 6（失敗可視化）、SIEM 方針メモ（producer 所有 probe / 弱結合 emit / メール通報別トラストクラス）。

変更履歴:
- v0.2: レビュー r1 反映。**(P0-1)** `SourceVaultDiagnosticsLog` への producer 直接 emit を廃止し、machine-local per-process spool + service 単一書き手 ingest に変更（JSONL 多重追記の再導入を排除）。fallback リングは spool に統合して削除。LLMCall の shard/prune を v0.2 スコープに昇格。**(P1-3)** Producer 固定値を廃し `$ClaudeDiagProducer` / option 化、`Type->"DiagnosticsEvent"` 付与と既存 reader 互換を Inc 1 の完了条件に追加、Severity↔既存キー対応表を追加。

## 1. 層構成（single writer 原則）

```
producer（claudecode / ClaudeRuntime / servicemanager / watchdog(PS) / bridge.py）
  │ iClaudeDiagEmit[class, payload, severity, opts]
  ▼
【書き込みは常に machine-local spool（per-process ファイル）】
  $UserBaseDirectory/ApplicationData/ClaudeRuntime/diag-spool/<producer>-<pid>-<yyyymmdd>.jsonl
  （producer+PID+日付でファイル名一意 → 各ファイルの書き手は常に 1 プロセス。追記競合は構造的に起きない）
  ▼
【正準ログへの書き手は SourceVault service カーネルただ 1 つ】
  service の低頻度 ingest hook（参照イベント rollup と同型）が spool を差分取り込み
  → EventId dedup 付きで正準 diagnostics-log.jsonl へ転記
  → 取り込みオフセットは spool 横の .ingest.json で管理、日付繰越後の消化済み spool は削除
  ▼
既存 Dropbox rollup → クロスマシン集約 → マイニング / SystemDoctor / 通報
```

- **producer が `SourceVaultDiagnosticsLog` を直接呼ぶことを禁止する**（親指針 P0-6「JSONL 非アトミック多重追記」を診断基盤の中心に再導入しないため）。呼んでよいのは service カーネル内の ingest hook のみ。既存の直接呼び出し箇所（diagnostics.wl:649, 1175, 1354, 1399 等）のうち service カーネル内実行のものはそのまま、他カーネルから呼ばれ得るものは Inc 5 で shim 経由へ移行する。
- producer は SourceVault を import しない（rule 11）。spool 書き込みは claudecode / ClaudeRuntime 自前実装で完結し、SourceVault の有無に依存しない。**v0.1 の「fallback リングファイル」は廃止** — spool がその役割を兼ねる（service 不在なら取り込まれず残るだけ。上限は §3.2）。
- WL 以外の producer（watchdog.ps1 / bridge.py）も同 schema で自分専用ファイルに書く（watchdog.log.jsonl / gateway ログ = 実質 per-process spool）。service ingest が正規化して取り込む。

## 2. イベント schema（正準 JSON）

```json
{"Type": "DiagnosticsEvent",
 "EventId": "uuid", "EventClass": "SeatDenied", "AtUTC": "2026-07-06T04:12:33Z",
 "MachineTag": "strixhalo128", "Producer": "claudecode", "ProducerPid": 12345,
 "Severity": "warn", "Payload": { ... }}
```

- `Type -> "DiagnosticsEvent"` を**必ず**付ける。既存 diagnostics log の `Type`/`Component`/`ReasonCode` 系レコードと共存し、既存 reader が新イベントを型で選別できるようにする（P1-3）。
- `EventId`: UUID。**ingest / rollup の dedup キー**（spool 再取り込み・rollup 二重適用の両方を冪等化）。
- `AtUTC` / `MachineTag`: **producer 側（shim）が発生時点で付与**する。v0.1 は `SourceVaultDiagnosticsLog` の自動付与（diagnostics.wl:673-675）に頼っていたが、spool 経由では ingest 時刻と発生時刻がずれる。ingest は `IngestedAtUTC` を追加してよいが発生時刻を上書きしない。
- `Payload` は class ごとに固定キー（§4）。**secrets・本文テキストを入れない**（metadata only）。

### 2.1 Severity と既存キーの対応（P1-3）

| Severity | 既存 Health 対応 | 既存 ReasonCode 系との関係 |
|---|---|---|
| info | OK | 記録のみ。集計の異常判定対象外 |
| warn | Degraded 相当 | ReasonCode がある場合 Payload."ReasonCode" に転記 |
| error | Degraded〜Failing | 同上 |
| critical | Failing | SystemDoctor GlobalHealth を直接 Failing に。通報候補 |

既存 reader / SystemDoctor 集計は「`Type=="DiagnosticsEvent"` の新形式」と「従来形式」の両方を読む。**Inc 1 の完了条件に「既存 reader が新イベントを読める」ことを含める**（書かれるが読まれない状態の防止）。

## 3. shim 実装

### 3.1 emit

```wolfram
(* 各パッケージ先頭で自分の身元を宣言（P1-3） *)
$ClaudeDiagProducer = "claudecode";   (* ClaudeRuntime.wl では "ClaudeRuntime"、servicemanager では "servicemanager" *)

iClaudeDiagEmit[class_String, payload_Association, severity_String: "warn", opts___Rule] :=
  Quiet @ Check[
    Module[{producer = Lookup[<|opts|>, "Producer",
              If[StringQ[$ClaudeDiagProducer], $ClaudeDiagProducer, "unknown"]],
            rec},
      rec = <|"Type" -> "DiagnosticsEvent", "EventId" -> CreateUUID[],
              "EventClass" -> class, "AtUTC" -> iClaudeUTCNowISO[],
              "MachineTag" -> iClaudeMachineTag[], "Producer" -> producer,
              "ProducerPid" -> $ProcessID, "Severity" -> severity,
              "Payload" -> payload|>;
      iClaudeDiagSpoolAppend[rec]],
    Null]  (* emit 自体の失敗は握り潰してよい唯一の場所（無限再帰防止） *)
```

- `"Producer"` は option で上書き可、既定は各パッケージの `$ClaudeDiagProducer`。**リテラル固定は禁止**。
- `iClaudeDiagSpoolAppend`: 自 PID 専用ファイルへの `OpenAppend`。書き手 1 プロセスが構造的に保証されるため、この追記はロック不要（規約 2 と整合）。

### 3.2 spool の上限と shard

- ファイル名: `<producer>-<pid>-<yyyymmdd>.jsonl`（**日次 shard**）。1 ファイル上限 20MB、超過時は `.1` へローテート 1 世代。
- 消化済み（offset==size かつ前日以前）の spool は ingest hook が削除。service 不在マシンでは 14 日超 or spool 総量 200MB 超で古い順に自己削除（shim が emit のついでに低頻度チェック）。
- **LLMCall は全件記録**（会計の基礎データ）だが、日次 shard + 上記 prune を v0.2 で最初から実装する（高頻度 class を無制限に溜めない）。
- 集約（collapse）: 同一 class×payload 署名が 60s 内に 10 件超 → `"Collapsed"->n` 付き 1 件（tick 暴走時の洪水防止）。

### 3.3 ingest hook（service 側・単一書き手）

- 参照イベント rollup と同じ低頻度 hook（既定 60s）に相乗り。各 spool の `.ingest.json`（`<|"Offset"->bytes|>`）から差分読み → EventId dedup → 正準 log へ転記 → offset 更新（temp-rename）。
- 転記先は既存 `diagnostics-log.jsonl`。**service カーネルのみが書くため single writer 成立**。
- 壊れた行（parse 失敗）はスキップし、service 自身が `SpoolLineCorrupt` を emit（自分の spool へ → 次周回で取り込まれる）。

## 4. イベントクラス一覧（v0.2）

| EventClass | Producer | Severity | Payload 主キー | 発火点（対応仕様） |
|---|---|---|---|---|
| SeatDenied | claudecode/Runtime | warn | Purpose, Pool, FreeSeats, Priority | 01 §5 |
| SeatLeaked | Runtime | error | Token, Purpose, TTLSeconds | 01: reaper が TTL/owner 死で強制回収した時（正常 Release では出さない） |
| SeatBrokerBusy | Runtime | warn | Purpose, RetriedTimes | 01 §4: acquire lock 競合で断念した時 |
| SpawnFailed | claudecode/Runtime | error | Purpose, Exe, ExitInfo | StartProcess 失敗（externalrunner:895-897 等） |
| SpawnManifestFinalizeFailed | Runtime | error | JobId, Purpose, KillAttempted, KillSucceeded | 03 §5 Phase C |
| ScheduleSubmitFailed | claudecode | error | Context, Detail | P1-8: SessionSubmit/ScheduledTask 作成失敗（6587-6590） |
| TickHandlerTimeout | claudecode | warn | HandlerKey, LimitSeconds | tick 個別 TimeConstrained 超過（P1-5 実装時） |
| OrphanReaped / ProcessVanished | Runtime | warn/error | JobId, Purpose, Reason, State | 03 §6（emit 条件対応表は 03 §7） |
| ProcessCleanupFailed | Runtime | error | JobId, Step("Kill"\|"Archive"\|"SeatRelease") | 03 §7 |
| ServiceRestarted | watchdog(PS)→ingest | warn | ServiceId, Success, NewPid, ConsecutiveFailures | 02 §4 |
| ServiceRestartGivenUp | 同上 | critical | ServiceId, Failures | 02 §4.2 |
| HealthDegraded / HealthRecovered | service/diagnostics | warn/info | Component, Layer(L1/L2/L3), Age | 02 §1（状態遷移時のみ、連続 emit しない） |
| PreflightFailed | claudecode | warn | Backend, Reason, TaskClass | 04 §3 |
| LLMEscalated | claudecode | info | From, To, Reason, TaskClass | 04 §4 |
| LLMCall | claudecode/RunTurn | info | Provider, Model, TaskClass, InTokens, OutTokens, CostUSD, DurationMs, Outcome | 04 §5（ClaudeRunTurn 普遍フック = Phase J §17.22 の頭金） |
| SpendLimitHit | claudecode | warn | LimitUSD, SpentUSD | 04 §5.2 |
| ConversationCompacted | claudecode | info | BeforeTokens, AfterTokens | 04 §6 |
| WatchdogDead | diagnostics | error | ServiceId, LastLogAge | 02 §6 probe |
| SpoolLineCorrupt | servicemanager | warn | SpoolFile, LineNo | §3.3 |
| UnknownTaskClass | claudecode | warn | TaskClass | 04 §2.1: 表に無い class 申告 (general 降格時) |
| FEBusyDeferred | claudecode | info | HandlerKey, Count | P1-5: FE 不応答で runInline handler を延期 (デッドロック回避。20 回毎に 1 emit) |

新クラス追加規約: 本表への追記 + Payload キー固定 + Severity 既定を仕様に書いてから実装する（schema drift 防止）。

## 5. 表面化（読む側）

### 5.1 SystemDoctor 統合

`SourceVaultSystemDoctor[]` に「直近 24h の warn 以上イベント集計」セクションを追加。読み取り対象は **正準 log（ingest 済み）+ 自マシンの未 ingest spool** の合算（service 停止中でも直近イベントが見えること。読みは読み手側で行う分には多重追記と無関係）:
- critical > 0 → GlobalHealth "Failing"
- SeatDenied が 1h に N(既定 10) 超 → "Degraded"（席計画の見直しシグナル）
- ServiceRestarted 頻発（24h に 5 超）→ "Degraded"

### 5.2 通報（メール）

SIEM 方針メモの別トラストクラスに従う: 自分宛固定 / metadata only / 事前承認済みテンプレート / rate limit（同一 class は 6h に 1 通）。対象は `critical` のみ。テンプレート整形のみで LLM 不使用。

### 5.3 マイニング接続

正準 log は既存 rollup でクロスマシン集約済みのため、llmwiki/mining 層が後からイベント列を対象化できる。v0.2 では接続しない（schema 互換のみ担保）。

## 6. 増分実装計画

- **Inc 1**: shim（emit + spool + shard/rotate + collapse）+ `ScheduleSubmitFailed` / `SpawnFailed` の 2 クラス実配線（P1-8 の即効修正を兼ねる）。**完了条件**: ①spool が per-process で衝突しないこと（2 カーネル同時 emit テスト）、②既存 diagnostics reader / SystemDoctor が `Type=="DiagnosticsEvent"` 行を読んでもエラーにならず、集計に反映されること（P1-3）。
- **Inc 2**: service ingest hook（offset 管理 + EventId dedup + prune）。
- **Inc 3**: SystemDoctor 集計セクション（正準 + 未 ingest spool 合算）。
- **Inc 4**: watchdog(PS)/bridge.py の同 schema 化 + ingest 取り込み。
- **Inc 5**: 既存の他カーネル発 `SourceVaultDiagnosticsLog` 直接呼び出しの棚卸しと shim 移行。
- **Inc 6**: LLMCall（04 Inc 4 と同時）+ ClaudeRunTurn フック。
- **Inc 7**: critical メール通報（rate limit 付き）。**NB + 実メールで検証**。

## 7. 検証レシピ

```wolfram
(* Inc1: SourceVault 無しで spool へ書けること *)
Get["claudecode.wl"];
iClaudeDiagEmit["SpawnFailed", <|"Purpose"->"test", "Exe"->"x"|>, "error"];
FileNames["*", FileNameJoin[{$UserBaseDirectory,"ApplicationData","ClaudeRuntime","diag-spool"}]]
(* → claudecode-<pid>-<date>.jsonl。行に Type/EventId/AtUTC/MachineTag/Producer が揃うこと *)

(* 多重書き手が起きないこと: 別 wolframscript から同時 emit → 各自の PID ファイルに分かれる *)

(* Producer 既定の確認: ClaudeRuntime から emit → Producer=="ClaudeRuntime" になること *)

(* Inc2: ingest の冪等性 *)
(* service を回して spool 取り込み → 正準 log に転記 → .ingest.json を削除して再取り込みさせても
   EventId dedup で重複しないこと *)

(* collapse *)
Do[iClaudeDiagEmit["TickHandlerTimeout", <|"HandlerKey"->"h1","LimitSeconds"->5|>], 20]
(* → 集約 1 件 + Collapsed カウント *)

(* 既存 reader 互換 (Inc1 完了条件②): 新イベント混在の diagnostics-log を SystemDoctor が読めること *)
```

## 8. 未解決事項

- ingest 周期 60s の妥当性（LLMCall 量の実測後に調整）。
- service 不在マシン（純クライアント）での spool 長期滞留 — 自己削除で足りるか、Dropbox 経由の軽量 uploader を持つか。
- bridge.py の既存ログ書式と新 schema の橋渡し（後方互換をどう保つか）は Inc 4 で決定。
