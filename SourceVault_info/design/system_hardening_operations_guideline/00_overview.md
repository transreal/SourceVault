# 中期アーキテクチャ実装仕様 — 概要と依存関係

親文書: `../system_hardening_operations_guideline_v1.md`（2026-07-06 監査統合指針）
本フォルダは指針 §3「中期アーキテクチャ提案」5 案の実装仕様案を収める。

> ## ★ 実装完了（2026-07-09）
> **本フォルダの 5 案（01〜05）はすべて実装・検証完了した。** 各仕様ファイル冒頭に実装完了マーカーと実物ファイル名を付した。増分単位の詳細ログ・落とし穴は auto-memory `system-hardening-guideline-v1.md` に記録。親文書「実装完了ステータス」節に全体総括あり。
> - 実測により対応不要と確定した項目: **P0-7 本体（$claudeProgress 単一書き手化）**、**#19（ClearAll 文脈ワート）** — いずれも静的解析/壊れたプローブの false positive で、危険な大改修を回避した（「静的警告 < 実測証拠」）。
> - 新規ファイル: `ClaudeRuntime_seatbroker.wl`、`ClaudeRuntime_processsupervisor.wl`。テスト: `test codes/claudecode_progress_concurrency_test.wls` 他。

改訂: v0.2（2026-07-06）— レビュー `../system_hardening_operations_guideline_review_v1.md` の全指摘（P0×2 / P1×4 / P2×2）を反映。主変更: SIEM を per-process spool + service 単一書き手 ingest に（P0-1）、ProcessSupervisor を 2 相 manifest に（P0-2）、SeatBroker に固定 acquire lock（P1-1）、service L2 を Ping コマンドに（P1-2）、producer/schema 境界の明確化（P1-3）、release 失敗処理と emit 対応表（P1-4）、TaskClass/validator 契約の固定（P2-1）、typo（P2-2）。

| # | 仕様 | 新規/変更ファイル | 依存 |
|---|------|-------------------|------|
| 01 | [SeatBroker（席ブローカ）](01_seatbroker_spec_v0.2.md) | 新規 `ClaudeRuntime_seatbroker.wl` + spawn 点 5 箇所改修 | 05 (emit) |
| 02 | [Health v2（3層 liveness + 相互監視）](02_health_v2_spec_v0.2.md) | `SourceVault_servicemanager.wl` / `wlmcp-gateway/bridge.py` / `SourceVault_diagnostics.wl` | 05 (emit) |
| 03 | [ProcessSupervisor（2 相 manifest + 孤児回収）](03_process_supervisor_spec_v0.2.md) | 新規 `ClaudeRuntime_processsupervisor.wl` + spawn ヘルパ移行 | 01 (token), 05 (emit) |
| 04 | [LLM Router 成熟化](04_llm_router_maturation_spec_v0.2.md) | `claudecode.wl` / `SourceVault_promptrouter.wl` | 05 (emit) |
| 05 | [SIEM イベント拡充](05_siem_events_spec_v0.2.md) | `claudecode.wl` / `ClaudeRuntime.wl` に emit shim + spool、`SourceVault_servicemanager.wl` に ingest hook | なし（最初に実装） |

## 実装順序（推奨）

```
05 Inc1 SIEM shim + spool（全案の前提。レビュー Go 条件 = P0-1 修正済みのこの形で着手）
→ 02 Inc1 即効部分（閾値統一 / parse失敗=Stale 反転 / heartbeat temp-rename / battery 3 箇所）
→ 01 Inc1 broker skeleton（lock 直列化。※個別ゲート先行は v0.2 で廃止 — 同時チェック全通過を防げないため）
→ 01 Inc2 spawn 点 5 箇所の Acquire/Release 化
→ 03 ProcessSupervisor（2 相 manifest。01 と token 連携）
→ 05 Inc2-3 ingest hook + SystemDoctor 集計
→ 04 LLM Router（preflight → ティア表+validator → escalate → 会計）
→ 02 Inc3-6 残（service Ping L2 / gateway eval / MCPRunningQ / 相互監視）
```

## 全仕様に共通する規約

1. **層境界**: claudecode / ClaudeRuntime は SourceVault 非依存を維持する（rule 11 弱結合）。診断イベントは 05 の shim で **常に machine-local spool へ書き**、正準ログへの転記は SourceVault service（単一書き手）の ingest hook だけが行う。producer から `SourceVaultDiagnosticsLog` を直接呼ばない。
2. **書き込み**: 状態ファイル（*.json）は write-temp-rename。追記（*.jsonl）は**ファイル単位で書き手 1 プロセス**（per-process spool 方式）。多重書き手の共有 JSONL を新設しない。
3. **失敗の返し方**: 拒否・不能は `Failure[tag, <|"MessageTemplate"->..., "Deferred"->True|False, ...|>]` で返し、同時に 05 のイベントを emit。silent `Null` 返しの新設禁止。
4. **検証**: 各 Inc は wolframscript 単体テスト green → ユーザー NB 検証（verify-loop）。FE 依存部分（tick / Dynamic）だけ NB 必須。**クラッシュ注入・競合注入テスト**（03 Inc1-⑤、01 Inc1-③）は省略しない。
5. **命名**: 内部関数は `iClaude...` / `iSV...` 接頭辞、公開シンボルは usage message 必須（既存規約踏襲）。
6. **語彙の追加**: SIEM イベントクラス（05 §4）と TaskClass（04 §2.1）は「表に追記してから実装」。schema drift 防止。

## 5 案が閉じる指針上の課題（トレーサビリティ）

- 01 → P0-1, P0-2（+P1-6 の一部）
- 02 → P0-3, P0-4, P0-5, P0-6(heartbeat), P0-8, P2-3
- 03 → P1-1（+ P0-6 の manifest 書き込み部）
- 04 → P1-2, P1-3, P1-6, P2-1, P2-2
- 05 → P1-8, 原則 6 全般

## レビュー指摘との対応（r1）

| レビュー指摘 | 反映先 |
|---|---|
| P0-1 SIEM の JSONL 多重追記再導入 | 05 §1, §3（spool + 単一書き手 ingest、fallback リング廃止、LLMCall shard/prune） |
| P0-2 spawn 後 manifest のクラッシュ窓 | 03 §5（2 相プロトコル + Phase C）、Inc1-⑤ クラッシュ注入 |
| P1-1 Acquire が直列化されていない | 01 §4（固定 acquire lock + stale 破棄 + SeatBrokerBusy）、Phase 1 再定義 |
| P1-2 service L2 が eval round-trip でない | 02 §3.2（Ping コマンド）、counter 進行は L3 へ、初回読み Unknown |
| P1-3 producer / schema 境界 | 05 §2（Type 付与・Severity 対応表）、§3.1（$ClaudeDiagProducer） |
| P1-4 完了時 release の失敗処理 | 03 §3.1（状態機械）、§6（cleanup 順序）、§7（emit 対応表）、01 §5.1 |
| P2-1 TaskClass / validator 契約 | 04 §2.1（属性表固定）、§4.1（純関数契約 + CompileValidator） |
| P2-2 typo | 02 §3.1 |
