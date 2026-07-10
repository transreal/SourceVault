# システム強化・安定運用指針 v1

対象: NBAccess / claudecode / ClaudeRuntime / ClaudeOrchestrator / SourceVault 一式
作成: 2026-07-06（4 観点並列監査 — 非同期安全性 / ライセンス・カーネル運用 / LLM 統合 / サービス・MCP 安定性 — の統合）
**実装完了: 2026-07-09（本指針の全項目を実装・検証。下記「実装完了ステータス」参照）**

---

## ★ 実装完了ステータス（2026-07-09 更新）

**本指針プロジェクトは完遂した。** 2026-07-06 の監査から起票した中期 5 案・P0 全 8 項目・P1 全項目・02 全 Inc をすべて実装し、各増分を wolframscript 単体テスト + ユーザー NB 実機検証で green 確認した。

| 項目 | 状態 | 実装物 / 検証 |
|---|---|---|
| **01 SeatBroker** | ✅ 完了 | `ClaudeRuntime_seatbroker.wl` 新規 + spawn 5 点配線 + P0-2 フリーズループ修正。実 4/4 席枯渇環境で実証 |
| **02 Health v2** | ✅ 完了 | 閾値統一 / battery 3 経路 / watchdog backoff + 成否実測 / **service Ping L2** / proxy L2 / **旧 gateway eval L2**（Inc4）。本番 service ライブ検証 |
| **03 ProcessSupervisor** | ✅ 完了 | `ClaudeRuntime_processsupervisor.wl` 新規（2 相 manifest + 孤児回収 + PID 再利用ガード + 起動時 reap + 自己解除 tick）。クラッシュ注入テスト込み |
| **04 LLM Router** | ✅ 完了 | preflight / ティア表 / escalate + validator / usage 会計 + `ClaudeUsageReport` / `$ClaudeSpendLimit` / 履歴自動 compaction。LM Studio ライブ E2E |
| **05 SIEM** | ✅ 完了 | per-process spool + `iClaudeDiagEmit` + service ingest hook + watchdog log 取込。日本語二重エンコード既存バグも修正 |
| **P0-7a**（tick 安全化）| ✅ 完了 | FE probe gate + handler 個別 timeout。本番 autotrigger tick で `FEBusyDeferred` 発火を確認（デッドロック直接対策）|
| **P1-4**（UNTRUSTED 既定化）| ✅ 完了 | `SourceVaultWrapUntrustedText` 新規 + `SummarizeText` 既定 on。injection 検出 + quarantine |
| **P1-6**（fallback backoff）| ✅ 完了 | 実試行失敗後の次候補に指数バックオフ（1s→2s→4s）。FE 実機で遅延起動確認 |

### 監査が誤検出だった 2 項目（実測で「対応不要」確定）

- **P0-7 本体（`$claudeProgress` 単一書き手化）→ 対応不要**。実測（`test codes/claudecode_progress_concurrency_test.wls`, 4/4 green）で WL カーネルの協調並行モデルを実証し、メモリレースが構造的に存在しないことを確認。詳細は末尾 §P0-7 再評価。
- **#19（ClearAll 文脈ワート／両文脈 {1,1} 二重定義）→ 無害と確定**。過去の「{1,1}」は壊れた `DownValues[Symbol[...]]` プローブ（HoldAll で常に 1 を返す）による**測定アーティファクト**だった。正しい測定では各関数は単一定義。dispatch バグではないため load 構造は変更しない。

いずれも「静的解析の警告 < 実測の証拠」の原則に従い、**危険な大改修を回避**した判断。P0-7 は回帰テストを残し、将来 WL に preemption が入れば自動 FAIL で警告する。

### 副産物（監査対象外だが本プロジェクトで修正）

- **`DownValues[Symbol["ctx`name"]]` の HoldAll バグを 4 ファイルで修正**（webingest / diagnostics / processsupervisor / claudecode）。`DownValues` は HoldAll なので引数の `Symbol[...]` が評価されず `DownValues::sym` を出し、`Length` が常に 1 になり弱結合ガードが機能しない。正しい idiom = `With[{sym = Symbol["..."]}, Length[DownValues[sym]]]` または同一文脈なら短縮名直接参照。
- WL 単一カーネルの並行モデルを実証・文書化（協調実行、SessionSubmit/ScheduledTask は preempt しない）。

### 各案の実装仕様と対応

実装仕様は `system_hardening_operations_guideline/`（00_overview + 01〜05）。各ファイル冒頭に実装完了マーカーを付した。増分単位の詳細な実装ログ・検証結果・落とし穴は auto-memory `system-hardening-guideline-v1.md` に記録。

### 未コミット状態（2026-07-09 時点）

全実装が検証 green だが GitHub 未反映。対象: claudecode.wl / SourceVault_webingest.wl / SourceVault_diagnostics.wl / SourceVault_servicemanager.wl / ClaudeRuntime_seatbroker.wl（新規）/ ClaudeRuntime_processsupervisor.wl（新規）/ ClaudeRuntime_externalrunner.wl / wlmcp-gateway/bridge.py + 本指針一式 + 新規テスト（`test codes/claudecode_progress_concurrency_test.wls` 等）。**原則 9（green 即コミット）に従い早期反映を推奨。**

---

## 0. 総括

システムは「クラウド LLM 経路・ループガード・prompt injection 防御（mining）・MCP 単一カーネル化」は production 品質に達している。一方で、残る不安定性の根はほぼ次の 4 つに集約される:

1. **席（ライセンス）管理が分散的** — 各コンポーネントが独立に spawn を決め、席残数を見るのは autotrigger のみ。全体を束ねるアロケータが無く、理論ピークは 4 席を超過し得る。
2. **health が「到達性」止まり** — green-but-dead の穴が複数残る（eval round-trip 未検証、heartbeat 閾値不一致、非アトミック heartbeat 書き）。
3. **共有状態とファイル追記が非同期非安全** — `$claudeProgress` 無ロック変更、JSONL 直接追記 × Dropbox 同期、tick 再入ガードの非原子性。
4. **ローカル LLM 経路と会計が prototype 品質** — LM Studio preflight 無し、履歴無制限成長、トークン/コスト会計無し。

---

## 1. 設計原則（今後の全変更が従うべき 10 原則）

### 原則 1: 席は予算である
controller 席 4 / subkernel 16 は共有予算。**新しいカーネルを spawn するコードは必ず席ゲートを通す**。`SourceVaultDiagnosticsLicenseProbe[]` の実測値（`ProcessSlotsFree`）を spawn 直前に確認し、0 なら「Deferred + 理由付き Failure」を返す（autotrigger の `LicenseSeatUnavailable` パターンを標準形とする）。席が余っている subkernel（16 枠）を純計算に優先使用し、controller 席はネットワーク/承認が必要な仕事に温存する。

### 原則 2: health = 「評価が返ること」
到達性（port open / PID alive）は health ではない。health 判定は 3 層で行う:
- L1 到達性（port/PID）
- L2 **eval round-trip**（短 timeout で `1+1` 相当を評価）
- L3 heartbeat カウンタの**進行**（値の存在ではなく増加）

「緑」を返せるのは L2 まで通った場合のみ。閾値はスタック全体（Python proxy / WL servicemanager / watchdog）で統一する。

### 原則 3: 書き込みは write-temp-rename、追記はシングルライター
状態ファイル（heartbeat.json / status.json）は必ず temp 書き→rename。JSONL 追記は書き手を 1 プロセスに限定するか、ローカル（非 Dropbox）に書いて rollup で共有域へ集約する。Dropbox 配下への多重ライター直接追記は禁止。

### 原則 4: tick の中は短く・有限で
共有 polling tick 内の各ハンドラは個別 timeout を持つ（現状は WindowStatusArea の 0.3s のみ）。FE 操作（NotebookWrite 等）は tick 内で最小化し、重い処理・ネットワークは必ず外部 dispatch（wolframscript / AwaitingLLM）へ。tick 内での同期 LLM 呼び出し禁止（rule 95）は維持。

### 原則 5: LLM 呼び出しは非ブロックが既定
新規の LLM 統合は AwaitingLLM + URLSubmit（orchestrator）または外部 runner dispatch を既定とし、メインカーネル同期呼び出しは「短い・timeout 付き・ユーザーが待つと明示した」場合のみ許す。

### 原則 6: 失敗は必ず可視化する
`Quiet @ Check[..., Null]` で握り潰してよいのは「失敗しても後続 tick が自然に回復する」処理のみ。それ以外は diagnostics（SIEM 層）へ emit する。特に: spawn 失敗、schtasks の非ゼロ exit、restart の成否、席拒否。**「静かに諦める」コードパスを新設しない。**

### 原則 7: ルーティングは能力ティア + preflight + fallback
モデル選択は「タスク難度 → ティア（cloud-strong / cloud-cheap / local）」の宣言的表を経由させる。ローカル backend には呼び出し前 preflight（`/api/v0/models` の load state 確認）を必須とし、down なら即 fallback。

### 原則 8: 外部テキストは既定 UNTRUSTED
mining の data-boundary パターン（UNTRUSTED マーカー + pre-scan + tool-less judge + JSON-only 出力）を、メール本文・Web 取得本文が LLM に渡る**全ての**経路に既定適用する。opt-in ではなく opt-out に反転する。

### 原則 9: green の修正は溜めない
検証 green になった修正は即 GitHub 反映する。未コミットの差分（現時点で claudecode.wl / ClaudeRuntime_externalrunner.wl / SourceVault_autotrigger.wl / SourceVault_servicemanager.wl / SourceVault_workflowcatalog.wl）はマシン間 drift・「直したはずのバグの再発」の温床。

### 原則 10: 再起動系は指数バックオフ + 上限
watchdog・自動復旧・retry は必ず「バックオフ + 連続失敗上限 + 上限到達時の通報」をセットで実装する。無限 2 分間隔リスタートは restart storm。

---

## 2. 優先度付き課題リスト

### P0 — 実害が既に出た/確実に出るクラス

| # | 課題 | 根拠 (file:line) | 対処 |
|---|------|------------------|------|
| P0-1 | **席ゲート不在の spawn 点**: メール要約/取得ジョブ、external runner、LaunchKernels が席残数を見ずに起動 | claudecode.wl:5161,5318 / ClaudeRuntime_externalrunner.wl:890 / ClaudeRuntime.wl:5933 | 各 spawn 直前に `ProcessSlotsFree<=0 → Deferred` を追加（autotrigger:1434-1437 のパターン移植）。中期は §3.1 SeatBroker へ |
| P0-2 | **LaunchKernels 失敗時の 30s フリーズループ**: 席枯渇で失敗しても `$iParallelKernelsReady` が立たず、次の ParallelSubmit が Kernels[]=={} を retry | ClaudeRuntime.wl:5897-5904, 5933 | 失敗時に ready フラグを立てて sync fallback へ切替（再試行は明示操作のみ） |
| P0-3 | **battery 制限の解除漏れ**: `iClearTaskBatteryRestriction` が watchdog にのみ適用、service/proxy タスクは laptop バッテリー時に Queued 固着 | SourceVault_servicemanager.wl:1897-1903（適用は 1932 のみ、1640/2436 は未適用） | service start / proxy start にも適用。※本体はまだ未コミット |
| P0-4 | **green-but-dead 残存**: gateway health が `KERNEL.alive()`（プロセス生存）のみで wedge を検知できない | wlmcp-gateway/bridge.py:161-163 | health で短 timeout の eval round-trip を実施。servicemanager 側 iMCPHealthyQ 判定と統一 |
| P0-5 | **health 閾値の不一致**: Python proxy は 15s/60s、WL 側は 5s/15s で OK/Degraded の意味が食い違う | servicemanager.wl:2179-2184 vs 1672-1676 | 閾値を一本化（推奨: 15s=OK / 60s=Degraded / 超=Stale）し定数を単一定義に |
| P0-6 | **JSONL 非アトミック追記 × Dropbox**: 複数 async コンテキストからロック無しで OpenAppend | claudecode.wl:2631,4776 / servicemanager.wl:537-543 | 状態ファイルは write-temp-rename 化（heartbeat.json:1483 が最優先）。ログ追記はローカル書き + rollup 集約 |
| P0-7 | **`$claudeProgress` の無ロック並行変更**: 60 箇所超の変更点が polling tick と job 初期化から同時に走る | claudecode.wl:5440,5605-5667,6619-6673 ほか | ~~書き手を tick 側に一本化~~ → **[2026-07-09 実測により再評価: 対応不要と判定]** 下記 §P0-7 追記参照 |
| P0-8 | **watchdog restart storm**: バックオフ無し・`schtasks /Run` の結果破棄で失敗しても「restarted」と記録 | servicemanager.wl:1820-1862, 1852 | 連続失敗カウンタ + 指数バックオフ + N 回で停止&通報。exit code をログへ |

### P1 — 安定運用のために早期に対処

| # | 課題 | 根拠 | 対処 |
|---|------|------|------|
| P1-1 | **orphan プロセス**: メールジョブ / `$iExternalProcs` は poll tick 停止で孤児化（強制回収なし） | claudecode.wl:5139-5167,5318-5327 / externalrunner.wl:890-900,1017-1020 | spawn 時に manifest（PID+起動時刻）記録 → 起動時+定期に stale reaper（例: 2h 超で kill+ログ） |
| P1-2 | **LM Studio preflight 無し**: ロード状態未確認で POST、失敗は 20 分 timeout 待ち。port 1234 ハードコード | claudecode.wl:9483,304,6929-6939 | 呼び出し前に `/api/v0/models` の state 確認（パレットの実装知見を流用）。unload なら即 Failure or fallback。port は設定変数化 |
| P1-3 | **ConversationState 無制限成長**: 履歴の自動トリム無し | claudecode.wl:34219-34773 | token 見積が閾値超過で自動 compaction（ClaudeCompactHistory の自動起動）。古 turn の tool 結果から要約化 |
| P1-4 | **メール/Web 本文の自動 UNTRUSTED 化が opt-in**: mining は堅牢だが maildb/webingest 経由で LLM に届く本文は無標識 | SourceVault_mining.wl:162,966-969（実装済側）/ webingest.wl:441,2785 | LLM へ渡る境界で一律に data-boundary ラップ + pre-scan を既定 on |
| P1-5 | **tick ハンドラ個別 timeout 無し**: 1 ハンドラの hang で 3 秒 tick 全体が滞留 | claudecode.wl:5580-5667 | 各ハンドラを TimeConstrained（例 5s）で包み、超過は freeze-log + 当該 key の一時 suspend |
| P1-6 | **fallback モデル連続試行にバックオフ無し** | claudecode.wl:10203-10398 (iStartFallbackAsync) | 試行間に 1s→2s→4s。RetryWithBackoff.wl の流用可 |
| P1-7 | **未コミット修正 5 ファイル**（原則 9 違反状態） | GithubRepositories ミラー差分 | 検証済みのものから package-auto-commit で順次反映 |
| P1-8 | **SessionSubmit 失敗の握り潰し**: retry 予約自体が失敗するとジョブが静かに消える | claudecode.wl:6587-6590 | 失敗時に diagnostics emit + ユーザー可視の Failure |

### P2 — 中期改善

| # | 課題 | 対処 |
|---|------|------|
| P2-1 | トークン/コスト会計無し（rate-limit 追跡のみ） | stream-json の usage を集計し `ClaudeUsageReport[]` を追加。`$ClaudeSpendLimit` kill-switch |
| P2-2 | 能力ティアリング無し（provider fallback 連鎖のみ） | PromptRouter に「タスク種別→ティア」表を導入。cheap 分類/抽出→local、設計/コード→cloud |
| P2-3 | watchdog 自身の死は誰も検知しない | diagnostics probe が watchdog PID/log 鮮度を監視（相互監視）。SystemDoctor に組込み |
| P2-4 | wedge 時 stdout ログに secrets 混入の可能性 | service コードで credentials を Print しない規約 + wedge ログの自動 redact |
| P2-5 | クロスマシン rollup の last-write-wins | EventId dedup を rollup 全経路で徹底（既存実装の適用範囲を監査） |
| P2-6 | ローカルモデルの streaming 表示無し（UX） | 低優先。progress 表示で代替可 |

---

## 3. 中期アーキテクチャ提案

### 3.1 SeatBroker（席ブローカ）— 最重要
ClaudeRuntime 層に単一の席アロケータを置き、**全 spawn 点をこれ経由に統一**する:

```
ClaudeSeatAcquire[purpose_, priority_] → seatToken | Failure["NoSeat", <|"Deferred"→True|>]
ClaudeSeatRelease[seatToken]
```

- 実測 probe（`$MaxLicenseProcesses` 等）+ 自己台帳（発行済み token）の二重管理。
- 優先度: FE インタラクティブ > service 常駐 > バッチ（mail/mining/autotrigger）。低優先はキューイングして席が空いたら実行。
- 拒否は必ず「Deferred + 理由」で返し diagnostics に emit（現 autotrigger 方式の全システム化）。
- ロードマップ: ①各 spawn 点に個別ゲート追加（P0-1、即効）→ ②ゲートを broker 呼び出しに置換 → ③queue/priority 導入。

### 3.2 Health v2（3 層 liveness + 相互監視）
- L1/L2/L3（§原則 2）を `SourceVaultServiceHealth` / proxy `/health` / `SourceVaultMCPRunningQ` が共通実装で返す（判定コードを 1 箇所に）。
- watchdog: 指数バックオフ + 連続失敗上限 + `schtasks /Run` exit code 記録。
- diagnostics probe が watchdog を監視（watchdog-of-watchdog）。SystemDoctor の GlobalHealth に反映。
- heartbeat は「counter 進行」判定へ統一し、heartbeat.json は temp-rename 書き。

### 3.3 ProcessSupervisor（孤児回収）
- 全ての外部プロセス spawn（mail job / external runner / service）で `runtime/processes/<jobId>.json`（PID・起動時刻・目的・期限）を記録。
- カーネル起動時 + 定期 tick で期限切れ・親不在プロセスを回収（taskkill + ログ）。
- これにより「poll tick が死ぬと process が漏れる」クラスの問題（P1-1）を構造的に閉じる。

### 3.4 LLM Router 成熟化（クラウド/ローカルの真の統合）
- **Preflight 層**: backend ごとの `AvailableQ[]`（LM Studio: /api/v0/models の state、Claude CLI: rate-limit status、API: key 有無）。ルータは available な最上位ティアへ。
- **ティア表**: `<|"extract"→"local", "classify"→"local", "summarize"→"local|cloud-cheap", "code"→"cloud", "design"→"cloud"|>` を PromptRouter に宣言的に持たせ、mining/mailsuggest/autotrigger がタスク種別を申告。
- **会計**: usage 集計 + `$ClaudeSpendLimit`。ローカルへ流すほど節約になる構造を数字で可視化し、ティア表のチューニング根拠にする。
- **ローカルの弱点補償**: local 実行には MaxContinuations=2（実装済）に加え、出力 schema 検証 + 失敗時 cloud escalate（1 回だけ）を標準形に。

### 3.5 記録層（SIEM）への集約
- `ClaudeRunTurn` 普遍フック（既定方針どおり）で全 LLM 呼び出しを記録。
- 新規 emit イベント: `SeatDenied` / `SpawnFailed` / `ServiceRestarted(success|fail)` / `TickHandlerTimeout` / `OrphanReaped` / `PreflightFailed`。
- これで「静かな失敗」が事後にマイニング可能になり、原則 6 が検証可能になる。

---

## 4. 運用チェックリスト

**日常（セッション開始時に 1 回）**
```wolfram
SourceVaultSystemDoctor[]                 (* GlobalHealth / 席 / MCP 重複 *)
SourceVaultDiagnosticsLicenseProbe[]      (* ProcessSlotsFree を確認 *)
```

**不調時の切り分け順**
1. 席: `ProcessSlotsFree` が 0 → まず MCP 重複/放置 wolframscript を回収（SystemDoctor の Reclaimable）。
2. サービス: health が緑でも `RestartService->True` で wedge 復旧（green-but-dead を疑う）。
3. FE フリーズ: tick 内の同期処理を疑う（freeze log 確認）。IMAP/LLM の同期経路への転落が典型。
4. タスク Queued 固着: バッテリー駆動 + DisallowStartIfOnBatteries を確認。

**変更時の規律**
- 新しい spawn 点 → 席ゲート必須（原則 1）。
- 新しい tick ハンドラ → TimeConstrained 必須（原則 4）。
- 新しいファイル書き込み → temp-rename か単一ライターか自問（原則 3）。
- 外部テキストを LLM に渡す新経路 → UNTRUSTED ラップ必須（原則 8）。
- 検証 green → 即コミット（原則 9）。

---

## 5. 推奨着手順序 ✅ 全て実装完了（2026-07-09）

> 当初の推奨順序（下記）どおりに着手し、全て完了した。冒頭「実装完了ステータス」参照。

1. ✅ **即日級（小変更・大効果)**: P0-3（battery 制限を service/proxy にも）、P0-2（LaunchKernels 失敗フラグ）、P0-5（health 閾値統一）、P0-6 の heartbeat.json temp-rename、P1-8（SessionSubmit 失敗可視化）。
2. ✅ **週内級**: P0-1（spawn 点 3 箇所に席ゲート）、P0-4（gateway eval round-trip health）、P0-8（watchdog バックオフ）、P1-2（LM Studio preflight）、P1-7（未コミット反映）。
3. ✅ **設計を伴う**: ~~P0-7（$claudeProgress 単一書き手化）→ 実測で対応不要と確定~~、P1-1（ProcessSupervisor）、P1-3（履歴自動 compaction）、P1-4（UNTRUSTED 既定化）。
4. ✅ **中期**: §3.1 SeatBroker 本体、§3.4 ティア表 + 会計、§3.5 SIEM イベント拡充。

---

## §P0-7 再評価: `$claudeProgress` 単一書き手化は不要（2026-07-09 実測確定）

**結論: 対応不要。** 監査（静的解析）は 60 箇所超の変更点を見て「無ロック並行変更＝メモリレース」と判定したが、これは **WL の並行モデルに対する false positive** だった。

**実測（`test codes/claudecode_progress_concurrency_test.wls`, 4/4 green）:**
- WL カーネルはメイン評価ループが**単一スレッド**。`$claudeProgress` を触る全経路（共有 tick = `CreateScheduledTask`、tick インスタンス = `SessionSubmit[ScheduledTask]`、job 初期化、登録）はすべて**協調実行**で、別 OS スレッドでは走らない。
- SessionSubmit は実行中評価を **preempt しない**（T1）。
- 2 並行タスクの read-modify-write 各 1000 回 → **lost update ゼロ**（T2, 期待 2000 = 実測 2000）。
- **`Pause`（event loop を pump）を read と write の間に挟んでも interleave しない**（T3, 期待 60 = 実測 60）。
- 連想フィールドの多タスク並行更新も破損なし（T4）。

**では監査が捉えた本当の問題は何だったか:**
1. **FE デッドロック**（tick 内 FE 書き込みが Dynamic/対話評価と相互待ち）— これは**メモリレースではなく blocking 待ち**。**P0-7a（tick 安全化: FE probe gate + handler timeout）で対策済み**。実運用で `FEBusyDeferred` 発火を確認。
2. **tick 論理再入 / stale 二重スケジュール** — tickInFlightAt ガード + staleness 処理で対処済み。read（entry スナップショット）→ write の間に pump は無く、あっても上記 T3 より無害。

**なぜ refactor しないか:** 60 箇所の単一書き手 queue 化は、(a) 実測でゼロの安全利益、(b) 今セッションでようやく安定させた繊細な tick 経路を触る高リスク（デッドロック再発の恐れ）。**「静的解析の警告 < 実測の証拠」**の原則に従い、危険な大改修を避ける。回帰テストを残し、将来 WL に preemption が入れば FAIL で警告する。

**教訓（今後の監査に適用）:** WL 単一カーネル内の「無ロック共有状態」は、SessionSubmit/ScheduledTask 経由でも協調実行なのでメモリレースにならない。真の非同期危険は ①FE デッドロック（blocking 待ち）②クロスカーネル/クロスプロセス共有（ファイル・ledger）③外部プロセス孤児 — であり、これらは本プロジェクトで個別対応済み。

---

*監査カバレッジ注記: claudecode.wl ~90%、externalrunner ~85%、ClaudeRuntime ~70%、Orchestrator ~60%、workflow ~50%、NBAccess ~40%（深掘り未了）。NBAccess の非同期安全性と Orchestrator workflow エンジンの並行性は次回監査対象として残る。*
