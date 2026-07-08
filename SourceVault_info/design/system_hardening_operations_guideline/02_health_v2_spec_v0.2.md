# Health v2 実装仕様案 v0.2 — 3 層 liveness + watchdog 相互監視

目的: 「緑のまま死亡（green-but-dead）」を撲滅する。health 判定を到達性から「評価が返ること」へ引き上げ、閾値をスタック全体で統一し、watchdog を storm-safe にする。

指針対応: P0-3（battery）、P0-4（gateway health）、P0-5（閾値不一致）、P0-6 の heartbeat 部分、P0-8（restart storm）、P2-3（watchdog 相互監視）。

変更履歴:
- v0.2: レビュー r1 反映。**(P1-2)** service の L2 を「heartbeat counter 進行で代替」から「command queue 経由の軽量 Ping コマンド」に変更（counter 進行は L3 に降格）。Ping 未実装の移行期は L3 で OK を返さず最大 Degraded（`Layer` 注記付き）。proxy の counter 進行判定に「初回読みは Unknown/Degraded」を定義。**(P2-2)** bridge.py 疑似コードの typo（KERNEEL_ALIVE）を修正。

## 1. 3 層 liveness モデル

| 層 | 検証内容 | 実装 |
|---|---|---|
| L1 到達性 | port open / PID alive | 既存（変更なし） |
| L2 評価往復 | 短 timeout で公開処理系が実際に仕事を返す | gateway: RPC eval。service: **command queue 経由の Ping コマンド**（§3.2） |
| L3 heartbeat 鮮度・進行 | counter が閾値内に進行している | 閾値統一（§2）。**counter 進行は L3 であって L2 ではない**（heartbeat ループと公開処理ループが別なら「heartbeat は進むが実処理は詰まる」green-but-dead が残るため） |

**緑（OK）を返せるのは L2 まで通った場合のみ。** L1+L3 のみ通過は最大 "Degraded"（`"Layer"->"L3"` 注記付きで、どの証拠までで判定したかを常に返す）。

## 2. 閾値の単一定義（P0-5）

`SourceVault_servicemanager.wl` に単一定数を置き、**生成物（watchdog.ps1 / proxy config.json）へ生成時に注入**する。Python/PS 側にリテラルを直書きしない。

```wolfram
$SourceVaultHealthThresholds = <|
  "OKSeconds" -> 15,        (* heartbeat age <= 15s → OK 相当 *)
  "DegradedSeconds" -> 60,  (* <= 60s → Degraded、> 60s → Stale *)
  "EvalTimeoutSeconds" -> 5,
  "EvalCacheSeconds" -> 30,
  "PingTimeoutSeconds" -> 10,
  "PingIntervalSeconds" -> 60
|>;
```

- WL 側 `SourceVaultServiceHealth`（監査時点 1672-1676: 5/15s）と Python proxy `health()`（2179-2184: 15/60s）を両方この定数由来に変更。
- **セマンティクス反転（重要）**: heartbeat.json の parse 失敗・age 計算不能は現状 "ok" 扱い（watchdog 1847 付近）→ **"Stale" 扱い**に変更する。「読めない = 健康」は禁止。

## 3. 各コンポーネントの L2 実装

### 3.1 wlmcp-gateway（bridge.py:161-163）

```python
# /health: プロセス生存だけでなく eval round-trip（疑似コード）
def health():
    if not KERNEL.alive():
        return {"ok": False, "layer": "L1"}
    if cache_fresh(EVAL_CACHE_SECONDS):
        return cached
    try:
        r = kernel_rpc("1+1", timeout=EVAL_TIMEOUT_SECONDS)
        ok = (r == "2")
    except TimeoutError:
        ok = False
    return {"ok": ok, "layer": "L2", "evalMs": elapsed, "atUTC": ...}
```

- eval は `EvalCacheSeconds`（30s）キャッシュ。通常トラフィックの RPC 成功もキャッシュ更新に流用（成功した実 RPC が最良の health 証拠）。
- eval 失敗 2 回連続 → gateway 自身が kernel を respawn（既存 ensure() 経路）し、`ServiceRestarted` 相当を自ログ（= 05 の spool）に記録。

### 3.2 SourceVault service の L2 = Ping コマンド（P1-2）

service の公開処理系は**filesystem command queue**なので、L2 の証拠は「queue に入れたコマンドが処理されて返ってくること」でなければならない。heartbeat counter は service メインループの生存しか証明しない（公開処理と同一ループである保証を health の根拠にしない）。

- 新コマンド `{"Command":"Ping","PingId":"uuid"}` を追加。service は他コマンドと同じ dispatch 経路で処理し、`pong-<PingId>.json`（`<|"PingId"->..., "AtUTC"->..., "HeartbeatCounter"->n|>`）を書く。**処理コストは µs 級**、通常キューに混ぜても無害。
- proxy `health()` が `PingIntervalSeconds`（60s）ごとに Ping を投入し、`PingTimeoutSeconds`（10s）以内の pong を L2 成立とする（結果はキャッシュ）。通常のコマンド処理成功も L2 証拠としてキャッシュ更新に流用（gateway と同じ思想）。
- タイムアウト → L2 不成立。L1+L3 の状態に応じて Degraded / Stale を返し、`HealthDegraded`（Layer="L2"）を emit。
- **移行期の扱い**: Ping コマンド実装（Inc 3）前は、counter 進行（L3）までで **OK を返さず最大 Degraded** とする…と原則どおりにすると既存運用の health 表示が一斉に Degraded になるため、移行期に限り「L3 成立 → OK'（`"Layer"->"L3"` 注記付き）」を許す。**Inc 3 完了をもって OK は L2 必須に切り替える**（切替はフラグ 1 つ: `$SourceVaultHealthRequireL2`）。

### 3.3 counter 進行判定の初回問題（P1-2）

- proxy はプロセス内に `last_counter` / `last_read_at` を保持。**初回読み（前回値なし）は "Unknown" とし Degraded 扱い**。2 回目以降に「counter が進んだか」を判定する。
- watchdog の 2 回読み（1838-1848: 5s 間隔）は現行維持。ただし §2 の反転（parse 失敗=Stale）を適用。
- heartbeat.json 書き込み（1483）を **write-temp-rename** 化。diagnostics 側の machine heartbeat（SourceVault_diagnostics.wl:683- に atomic write 実装あり）とヘルパを共通化（`iSVAtomicWriteJSON[path, assoc]`）。

### 3.4 SourceVaultMCPRunningQ

- 判定を「proxy 到達性」から「gateway /health の `ok`（=L2）」へ変更（既定方針 iMCPHealthyQ の完成）。パレットのトグル誤表示 → 逆 Stop → タスク消滅、の連鎖（既知障害⑤）をここで断つ。

## 4. watchdog の storm-safe 化（P0-8）

watchdog.ps1 生成部（監査時点 1820-1862）へ以下を注入:

### 4.1 restart 状態ファイル

`<runtime>/services/<svc>/restart_state.json`:
```json
{"ConsecutiveFailures": 2, "LastRestartAtUTC": "...", "GivenUp": false}
```

### 4.2 バックオフと上限

```
backoff = min(BaseIntervalMinutes * 2^ConsecutiveFailures, 60min)
ConsecutiveFailures >= 5 → GivenUp=true。以後 restart しない。
  watchdog.log.jsonl に ServiceRestartGivenUp を記録し、
  diagnostics probe（§6）が SystemDoctor へ "Failing" として表面化。
成功（新 PID + heartbeat 進行を確認）→ ConsecutiveFailures = 0
```

### 4.3 restart 成否の実測（現状: /Run 結果破棄 1852）

```powershell
$rc = (Start-Process schtasks -ArgumentList "/Run","/TN",$task -Wait -PassThru).ExitCode
# 成功判定は exit code ではなく実体で行う:
#   30 秒以内に pid.json が「新しい PID」になり、heartbeat counter が進行を開始したら成功
```

- `schtasks /Run` が ExitCode 0 でも Queued 固着（battery）で実体が起きないケースを観測済みのため、**成功 = 新 PID + heartbeat 進行**と定義する。

### 4.4 mutex 例外処理

`New-Object System.Threading.Mutex`（1829）を try-catch で包み、取得失敗時は watchdog.log.jsonl へ記録して即終了（多重 watchdog を作らない側に倒す）。

## 5. battery 制限の全タスク適用（P0-3）

`iClearTaskBatteryRestriction`（1897-1903、未コミット）を以下 3 箇所すべての schtasks /Create 直後に呼ぶ:
- service task 作成（1636-1640 付近）
- watchdog task 作成（1930-1933、適用済み）
- proxy task 作成（2433-2436 付近）

加えて `Set-ScheduledTask` で `-Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries)` の両方を設定（起動許可と実行中停止禁止はフラグが別）。install 時だけでなく **start 経路でも冪等に適用**する（既存タスクが古い設定のまま残る再発を防ぐ）。

## 6. watchdog 相互監視（P2-3）

- `SourceVault_diagnostics.wl` の probe 群に `iSVDiagWatchdogProbe[]` を追加:
  - watchdog PID（pid ファイル）生存
  - watchdog.log.jsonl の最終行 age < IntervalMinutes*2
  - restart_state.json の GivenUp フラグ
- SystemDoctor の GlobalHealth に反映: watchdog 死 → "Degraded"、GivenUp → "Failing"。
- 通報はメール通報の別トラストクラス方針に従い、05 の閾値ルールで発火。

## 7. 増分実装計画

- **Inc 1（即日級）**: 閾値定数化 + 両実装の統一 / parse 失敗→Stale 反転 / 初回読み Unknown / heartbeat temp-rename / battery 3 箇所適用。wolframscript: 閾値注入後の watchdog.ps1 / config.json 生成内容を文字列検査。
- **Inc 2**: watchdog backoff + restart 成否実測 + restart_state.json。検証はサービスを故意に即死させ（core を一時 rename）、2min→4min→8min…→GivenUp の進行を watchdog.log.jsonl で確認。
- **Inc 3**: **service Ping コマンド + proxy の L2 判定 + `$SourceVaultHealthRequireL2` 切替**。検証: 通常時 L2=OK / service メインループに長時間評価を注入（heartbeat は進むが queue 処理が止まる状態を作る）→ L2 不成立で Degraded になること（v0.1 設計では検出できなかったケース）。
- **Inc 4**: bridge.py /health eval round-trip + キャッシュ + respawn。curl で wedge 注入（長時間評価を投げた直後の /health が Degraded になること）。
- **Inc 5**: SourceVaultMCPRunningQ の L2 化 + パレット表示。**FE 依存のため NB 検証必須**。
- **Inc 6**: watchdog 相互監視 probe + SystemDoctor 統合。

## 8. 検証レシピ

```wolfram
(* Inc1: 閾値統一の確認 *)
Get["SourceVault_servicemanager.wl"];
$SourceVaultHealthThresholds
(* 生成物へ注入されているか *)
StringContainsQ[iWatchdogPS1Content[...], "60"]  (* 実装時の関数名に合わせる *)

(* Inc2: restart storm 抑制。service の run.wls を一時的に壊してから *)
SourceVaultServiceStart["..."];
(* 10 分後: *)
Import[".../watchdog.log.jsonl", "Lines"] // Length  (* 2min 間隔で無限に増えないこと *)
Import[".../restart_state.json", "RawJSON"]           (* ConsecutiveFailures 増加 → GivenUp *)

(* Inc3: service L2。green-but-dead の再現から *)
(* service に Pause[600] を仕込んだコマンドを 1 本入れて queue を塞ぐ
   → heartbeat は進む(L3 OK)が Ping が timeout → health が Degraded になること *)

(* Inc4: gateway L2 *)
URLExecute["http://127.0.0.1:9701/health"]  (* {"ok":true,"layer":"L2",...} *)
(* 共有カーネルに Pause[600] を投げた直後 → ok:false / Degraded *)
```

## 9. 未解決事項

- gateway eval / service Ping のキャッシュ・間隔（30s/60s）は MCP 呼び出し頻度実測で調整。
- service の queue が単一 worker の場合、長時間ジョブ実行中は Ping も待たされ L2 が偽陽性で落ちる — 「実行中ジョブあり」を pong 側 metadata で返し、health が Busy と Dead を区別する拡張を Inc 3 で検討。
- GivenUp からの自動復帰条件（人手 reset のみ、で v0.2 は良いか）。
- 閾値 15/60s の妥当性（バッテリー省電力時の tick 遅延実測を踏まえて）。
