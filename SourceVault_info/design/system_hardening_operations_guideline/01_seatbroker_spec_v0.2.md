# SeatBroker 実装仕様案 v0.2

> **✅ 実装完了（2026-07-09）**。実物: `ClaudeRuntime_seatbroker.wl`（新規、claudecode.wl から自動ロード）+ spawn 5 点配線（mail summary/fetch・external runner・LaunchKernels[P0-2 修正込み]・service start）。Inc1（broker skeleton, 固定 acquire lock）+ Inc2（spawn 点 Acquire/Release）green、実 4/4 席枯渇環境で実証。mail は Priority 90（capacity=1 トポロジー対応, §3.3 errata）。詳細は auto-memory 参照。

目的: Wolfram ライセンス席（controller 4 / subkernel 16、strixhalo128 実測）を単一のアロケータで管理し、席枯渇による「wolframscript 起動不能」「サービスカーネル silent 死」「ParallelSubmit 30 秒フリーズ」を構造的に排除する。

指針対応: P0-1（席ゲート不在の spawn 点）、P0-2（LaunchKernels 失敗フリーズループ）。

変更履歴:
- v0.2: レビュー r1 反映。**(P1-1)** UUID token ファイル作成は acquisition の相互排他にならないとの指摘を受け、固定 acquire lock（TTL 付き stale 破棄）で Acquire を直列化する方式に変更。v0.1 の「self-revoke 2 相」は削除（lock により不要）。Phase 1 を「broker skeleton 先行 + 個別ゲートは broker 未ロード時の暫定 fallback」に再定義。**(P1-4)** Acquire 後 spawn 失敗時の release 義務を各 spawn 点に明記、SeatLeaked の emit 条件を 03 §7 の対応表と整合。

## 1. スコープ / 非目標

- スコープ: マシンローカルの席管理（発行・返却・拒否）。controller 席と subkernel 席の 2 プール。
- 非目標: マシン間の席調整（ライセンスが PC ごとか共有か未確認のため v0.2 はマシンローカル前提。共有と判明したら v0.3 で台帳を Dropbox 名前空間に拡張）。プロセスの生死管理は 03 ProcessSupervisor の責務。

## 2. 配置と依存

- 新規ファイル: `ClaudeRuntime_seatbroker.wl`。context は `ClaudeRuntime``（externalrunner と同様のサブファイル方式）。
- SourceVault 非依存。license 実測は自前で行う（`$MaxLicenseProcesses` 等はカーネル組込みシンボル）。`SourceVaultDiagnosticsLicenseProbe[]` は将来こちらへ delegate してよい。
- emit は 05 の `iClaudeDiagEmit`（spool 方式）経由。

## 3. データモデル

### 3.1 プール定義

```wolfram
$ClaudeSeatPools = <|
  "Controller" -> <|"CapacityFn" :> ($MaxLicenseProcesses - $LicenseProcesses),
                    "Reserve" -> 1|>,   (* FE 対話用に常時 1 席を予約 *)
  "Subkernel"  -> <|"CapacityFn" :> ($MaxLicenseSubprocesses - iClaudeSubkernelInUse[]),
                    "Reserve" -> 0|>
|>;
```

- `CapacityFn` は呼び出し時に実測（license サーバが真実。台帳は「実測にまだ現れていない spawn 中」の補正用）。
- `Reserve`: FE のインタラクティブ操作を batch に食い潰させないための予約席。

### 3.2 台帳（ledger）

インカーネル: `$iClaudeSeatLedger = <| token -> entry |>`（自プロセス発行分のキャッシュ）。
クロスプロセス（真実）: `<machine-local>/seatbroker/ledger/<token>.json`（temp-rename 書き）。machine-local は `$UserBaseDirectory/ApplicationData/ClaudeRuntime/seatbroker/`（**Dropbox 外**。席はマシンローカル資源）。

entry schema:
```json
{"Token": "seat-<uuid>", "Pool": "Controller", "Purpose": "MailFetch",
 "Priority": 40, "OwnerKernelPid": 12345, "AcquiredAtUTC": "...",
 "TTLSeconds": 600, "JobId": "..."}
```

- `TTLSeconds` 必須。期限切れ entry は capacity 計算から除外し、reaper が削除。owner kernel の死（PID 不在）でも失効。**返却漏れが席を恒久占有しない**ことを不変条件とする。
- reaper が TTL/owner 死で entry を強制回収したときのみ `SeatLeaked` を emit する（正常 Release では出さない。03 §7 の対応表と整合 — SeatLeaked は「supervisor の cleanup が機能しなかった」ことの診断指標）。

### 3.3 優先度

| Priority | 用途 | 例 |
|---|---|---|
| 90 | ユーザー明示起動の操作 | ClaudeEval の外部 dispatch、**mail fetch/summary（ユーザー起動）** |
| 60 | 常駐サービス | SourceVault service / MCP gateway |
| 40 | ユーザー起因の遅延バッチ | doc 更新チェーン等 |
| 20 | 自動バッチ | autotrigger / mining / rollup |

> 実装時修正 (2026-07-07, NB 検証由来): mail fetch/summary は当初 40 としていたが、
> FE + service + MCP gateway 常駐で **capacity=1** になる実トポロジーでは
> 「40 + Reserve 1」だとユーザーが明示起動しても恒久 NoSeat になる。
> ユーザーが今まさに指示した操作は Reserve に食い込んでよい（Reserve の目的は
> **自動**バックグラウンド作業から対話性を守ることであって、ユーザー起動の
> 操作を拒むことではない）ため 90 に変更。自動バッチが同じ spawn 関数を通る
> 経路は autotrigger 側の席ゲートが上流で防ぐ。

## 4. Acquire の直列化（P1-1）

UUID token ファイルの `CreateFile` は「entry の書き込み」としては原子的だが、token ごとにパスが異なるため**互いに衝突せず、Acquire 全体の相互排他にはならない**。複数プロセスが同時に `free > 0` を観測して全員発行し得る。よって固定 lock で臨界区間を作る。

### 4.1 acquire lock

- lock 実体: `<machine-local>/seatbroker/acquire.lock/`（**固定名ディレクトリ**。`CreateDirectory` は存在時に失敗するため原子的な取得判定になる。取得後、lock 内に `owner.json`（PID + AcquiredAtUTC）を書く）。
- stale 破棄: lock の `owner.json` が 30s 超過 or owner PID 不在なら、破棄してから再取得を試みる（破棄→取得の間の競合は再取得側の CreateDirectory 失敗で自然に解決）。
- 取得失敗: 50-150ms の jitter を挟んで最大 3 回 retry。それでも取れなければ `Failure["SeatBrokerBusy", <|"Deferred"->True|>]` を返し `SeatBrokerBusy` を emit。**待ち続けない**（呼び出し元の tick / RetryPolicy が再試行の主体）。

### 4.2 臨界区間の内容

```
lock 取得
  → ①reap expired（TTL 切れ / owner 死 entry の削除）
  → ②ledger 全読み
  → ③capacity 実測（CapacityFn）
  → ④free = capacity - 有効 entry 数 - Reserve を判定
  → ⑤free > 0（or Priority>=90 で Reserve 食い込み可）なら token entry を temp-rename 書き
lock 解放（owner.json 削除 → ディレクトリ削除）
```

- 臨界区間は数十 ms で終わる純ローカル I/O のみ（ネットワーク・LLM・license probe の遅い呼び出しを入れない。`$LicenseProcesses` 読みはカーネル内シンボルで即時）。
- Release は lock 不要（自分の token ファイルを消すだけ。他者と競合しない）。

## 5. API

```wolfram
ClaudeSeatAcquire[purpose_String, opts] → <|"Token"->..., ...|>
  | Failure["NoSeat", <|"Deferred"->True, "Pool"->..., "FreeSeats"->n|>]
  | Failure["SeatBrokerBusy", <|"Deferred"->True|>]
  (* opts: "Pool"->"Controller"|"Subkernel", "Priority"->_Integer, "TTLSeconds"->_Integer, "JobId"->_String *)

ClaudeSeatRelease[token_String] → True | Failure["UnknownToken", ...]
  (* UnknownToken は「既に TTL reaper が回収済み」も含む。呼び出し側はこれを致命エラー扱いしない *)

ClaudeSeatWithSeat[purpose_String, fn_, opts] → fn の結果 | Failure[...]
  (* acquire → fn[token] → finally release。同期スコープ用の安全ラッパ *)

ClaudeSeatLedger[] → Dataset   (* 現在の発行状況 + 実測 free。診断用 *)
ClaudeSeatReap[] → <|"Expired"->n, "OrphanOwner"->m|>   (* 独立実行用。Acquire 内①と同一実装 *)
```

### 5.1 Acquire 後の義務（P1-4）

**Acquire に成功した呼び出し元は、spawn の成否に関わらず席の行き先へ責任を持つ**:
- spawn 成功 → SeatToken を 03 の manifest に記録（release は supervisor cleanup が担う）。
- **spawn 失敗（StartProcess 失敗等）→ その場で `ClaudeSeatRelease` を呼ぶ**。呼び忘れ・呼べずに死んだ場合は TTL 失効が回収し `SeatLeaked` が痕跡になる。
- supervisor を使わない短命スコープは `ClaudeSeatWithSeat` を使う（finally release）。

## 6. 既存 spawn 点の改修（Phase 1 = broker skeleton 先行）

**v0.2 での再定義（P1-1）**: v0.1 の「broker を待たず各 spawn 点に直接ゲート」は、同時チェックの全通過を防げないため主経路にしない。**Inc 1 で broker skeleton（lock + ledger + Acquire/Release）を先に入れ、spawn 点は薄く `ClaudeSeatAcquire` を呼ぶ**。直接 probe ゲート（autotrigger の `LicenseSeatUnavailable` パターン）は「broker が未ロードの環境でだけ効く暫定 fallback」と位置付ける。

| spawn 点 | 監査時点の位置 | Acquire 失敗時 | spawn 失敗時（P1-4） |
|---|---|---|---|
| mail summary job | claudecode.wl:5161 | `<|"Submitted"->False, "Deferred"->True, "Reason"->"NoSeat"|>` を返す（Priority 90 = §3.3 修正参照） | 即 Release |
| mail fetch job | claudecode.wl:5318 | 同上 | 即 Release |
| external runner | ClaudeRuntime_externalrunner.wl:890 | `Failure["NoSeat", <|"Retryable"->True|>]` → Orchestrator RetryPolicy（Retryable クラスに "SeatUnavailable" を追加）でバックオフ再試行 | 即 Release（StartProcessFailed 経路 895-897 に Release を追加） |
| LaunchKernels | ClaudeRuntime.wl:5933 / 5897-5904 | Subkernel プール。**失敗時は必ず `$iParallelKernelsReady = True` を立てて sync fallback へ**（P0-2 修正を包含）。再試行は明示的な `ClaudeBeginParallelKernels[]` のみ | LaunchKernels 自体の失敗も同様に ready フラグ + Release |
| SourceVault service start | SourceVault_servicemanager.wl:1643 | Priority 60。拒否は Failure でユーザーに可視化（黙って起動失敗しない） | 即 Release |

各拒否点で `SeatDenied` を emit（Purpose / Pool / FreeSeats / Priority）。

## 7. キューイング（Phase 3・任意）

v0.2 では実装しない。拒否 + 呼び出し側の再試行（tick / RetryPolicy）で代替。Phase 3 で `"Wait"->Automatic` を追加する場合、待機は**メインカーネルをブロックしない**こと（tick 登録 + コールバック方式。orchestrator-async-llm skill の AwaitingLLM パターンに準拠）。

## 8. 増分実装計画

- **Inc 1**: broker skeleton（lock 直列化 / プール / Acquire / Release / TTL 失効 / ledger）。wolframscript 単体テスト:
  ① 発行→free 減少→Release→復元
  ② TTL 失効 / owner PID 死失効（子 wolframscript を起動して kill）→ SeatLeaked emit
  ③ **多重 Acquire 競合（P1-1）**: 残 1 席の状態で複数 wolframscript から同時 Acquire → **成功はちょうど 1 つ**、他は NoSeat/SeatBrokerBusy
  ④ stale lock 破棄（lock を残して owner を kill → 次の Acquire が 30s ルールで破棄・取得）
- **Inc 2**: spawn 点 5 箇所を Acquire/Release 化（spawn 失敗時 Release を含む）+ SeatDenied emit + 暫定 fallback ゲート。既存テスト（mail job 系、externalrunner 46 tests）green 維持。
- **Inc 3**: ProcessSupervisor（03）との token 連携（manifest に seatToken 記録、cleanup ①が Release）。
- **Inc 4**: ClaudeSeatLedger[] を SystemDoctor に統合（診断表示）。

## 9. 検証レシピ

```wolfram
Get["ClaudeRuntime.wl"];
ClaudeSeatLedger[]  (* free 実測と ledger の一致 *)
r1 = ClaudeSeatAcquire["test", "Pool"->"Controller", "TTLSeconds"->30];

(* 競合テスト (Inc1-③): 残 1 席で N 本の wolframscript から同時 Acquire。
   結果ファイルに token を書かせ、成功数がちょうど 1 であることを数える *)

(* TTL 失効 *)
Pause[35]; ClaudeSeatReap[]; ClaudeSeatLedger[]
(* → 回収 + SeatLeaked が spool にあること *)

(* mail ジョブ拒否経路: 席ゼロ状態で ClaudeFetchNewMail[] → Deferred が返り FE がフリーズしない *)

(* spawn 失敗 Release: 存在しない exe を指す external ジョブ → StartProcessFailed 後に
   ledger から当該 token が消えていること *)
```

## 10. 未解決事項

- ライセンスがマシン共有かの実測（ProArt 側で probe）→ 共有なら ledger を Dropbox マシン名前空間 + rollup に拡張。
- `$LicenseProcesses` の反映遅延（spawn 後に増えるまでのラグ）実測 → ledger 補正窓の長さ決定。
- FE 予約席 1 の妥当性（重バッチ運用日に 1 で足りるか）。
- lock ディレクトリ方式の Dropbox 外前提の再確認（$UserBaseDirectory が同期対象になっている環境がないか）。
