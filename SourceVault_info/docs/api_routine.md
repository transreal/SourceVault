# SourceVault_routine API

ルーチン/義務(obligation)コア層。実行(AutoTrigger)・事実取得(NBAccess)・統計(anomaly)には
委譲し、本層は判定・通知・提案のみで**実行権限を持たない**(仕様
`sourcevault_routine_attention_spec_v0_4.md`)。

**R1(実装済み)= 決定的・副作用なしの純関数コア**。IO・LLM・他 SourceVault パッケージへの依存なし
(単体 `Get` 可能)。identity 規則・3値(Kleene)証拠論理・Resolution 状態機械・長周期 due 生成・
overdue 積分を提供する。時刻は内部で絶対秒として扱い、DateObject/絶対時刻のどちらの入力も受け付ける。

## Identity(仕様 §2.2)

- `SourceVaultRoutineIdentity[kind, data]` — obligation source レコードから
  `<|"Namespace","StableId","OccurrenceToken"|>` を返す。kind ∈
  `"CalendarEvent"|"Routine"|"Commitment"|"OnWorkTask"|"PrepTask"`。**StableId/OccurrenceToken は
  履行・期限変更・メタデータ変更で不変**(挙動変化は Revision 側の責務)。
  - CalendarEvent: `data["EventId"]`(NBAccess R0b の HMAC keyed id)+ `data["OriginalStart"]`。
    移動後の Start ではなく OriginalStart を token に使うので、移動しても token 不変。
  - Routine: RoutineId + WindowStartUTC。
  - Commitment: CommitmentId + CommitmentOccurrenceId(検出時 1 回発番。deadline 更新は Revision)。
  - OnWorkTask: TaskId + `"cyc:"<>ReviewCycleOrdinal`(Status→Done でも token 不変=AC-020、
    cycle 昇格でのみ ordinal 前進=AC-022)。
  - PrepTask: `prep:` + digest(ParentStableId+StepId) + 親 OccurrenceToken(StepId 不変=AC-031 基盤)。
  - 未知 kind は `Failure["NBRoutineUnknownKind"]`。
- `SourceVaultRoutineKeyString[identity]` — dedup/ledger 用の正準キー文字列
  `"StableId|OccurrenceToken"`。`"Identity"` キーを持つ occurrence も受ける。

## 3値(Kleene)証拠論理(仕様 §2.6)

証拠 atom は `<|"Truth"->True|False|"Unknown", "Quality"->_|Missing, "Freshness"->_|>` の triple。
source 不能で判定不能なら **Unknown**(False ではない)。

- `SourceVaultRoutineTriple[truth, quality:Missing, freshness:"Fresh"]` — 正規化した triple を構成。
  Quality ∈ `AttemptObserved|ExecutionSucceeded|OutcomeSatisfied`、Freshness ∈
  `Fresh|Stale|Partial|Unavailable`。
- `SourceVaultRoutineKleeneNot[t]` — True↔False、**Not[Unknown]=Unknown**(AC-034)。Quality は落とす。
- `SourceVaultRoutineKleeneAllOf[ts]` — any False→False / else any Unknown→Unknown / else True。
  空リスト=True。Quality=構成 triple の最小、Freshness=最悪。
- `SourceVaultRoutineKleeneAnyOf[ts]` — any True→True(Quality=True 枝の最大)/ else any Unknown→Unknown
  / else False。空リスト=False。
- `SourceVaultRoutineEvaluateEvidence[spec, atomFn]` — EvidenceSpec 木(`AllOf`/`AnyOf`/`Not`/`Atom`)を
  再帰評価。`atomFn[atomSpec]` が triple を返す**注入シーム**(実 atom resolver は R2 で供給)。
- `SourceVaultRoutineFulfillmentReached[triple, minQuality]` — Truth===True かつ quality rank ≥
  minQuality のときのみ True(Unknown/False は絶対に到達しない)。
- `SourceVaultRoutineQualityRank[quality]` — AttemptObserved/ExecutionSucceeded/OutcomeSatisfied →
  1/2/3(Missing/その他 →0)。

## Temporal / Resolution(仕様 §2.1/§2.4)

- `SourceVaultRoutineTemporalState[schedule, now, opts]` — `schedule["DueAtUTC"]`/`["GraceUntilUTC"]`
  と now から `"Upcoming"|"DueSoon"|"Overdue"` を返す。option `"SoonWindow"`(秒・既定 86400)。
- `SourceVaultRoutineResolveSeries[occurrences, evidence, now, mode]` — 系列全体を純粋に解決。
  occurrences=`<|"OccurrenceToken","DueAtUTC","GraceUntilUTC",("WindowStartUTC")|>` の Due 昇順リスト、
  evidence=`<|"AtUTC",("Quality")|>` の実行時刻リスト、mode ∈
  `"EachOccurrence"|"LatestState"|"AnyWithinWindow"`。各 occurrence に対し State/Resolution/WasOverdue/
  FirstOverdueAtUTC/EvidenceAtUTC/EvidenceQuality を返す。
  - Resolution ∈ `SatisfiedOnTime|SatisfiedLate|SupersededByCatchUp|Missed`(+open は State="Unknown")。
  - 証拠は Due 昇順で**最も早い該当 occurrence が 1 件だけ消費**(二重計上しない)。
  - LatestState: 過去 occurrence は後続 evidence で SupersededByCatchUp(State=Satisfied)だが
    **WasOverdue は保持**(AC-025)。EachOccurrence は各独立で過去は Missed のまま(AC-010)。
  - WasOverdue/FirstOverdueAtUTC は一度立つと catch-up で消えない(単調)。

## 長周期 due(仕様 §4.1 / AC-032)

- `SourceVaultRoutineNextDue[cadence, from, opts]` — `from` より真に後の次 due を
  `<|"DueAtUTC","GraceUntilUTC","Capped"->False|>` で返す。**直接算術**で計算するので、
  年次など疎な cadence が scan cap で無音にならない(AC-032)。
  - cadence Kind: `"Interval"`(IntervalSeconds+Anchor)/ `"Daily"|"Weekly"|"Monthly"|"Yearly"`
    (Interval 回数+Anchor)。Grace は `cadence["GraceSeconds"]` または option `"GraceSeconds"`(既定 0)。
    その他 Kind は option `"NextFireFn"`(`(cadence,fromAbs)->absOrMissing`)注入。無ければ
    `Failure["NBRoutineNoNextDue"]`。
  - 月/年ステップは短い月を clamp(due の目標値であり、NBCalendarEvents の厳密 skip 展開とは別方針)。

## Overdue 積分(仕様 §4.3 / P1-11)

- `SourceVaultRoutineOverdueSeconds[graceUntil, resolvedAt, dayStart, dayEnd]` —
  `[max(graceUntil,dayStart), min(resolvedAt|dayEnd, dayEnd)]` の長さ(秒・≥0)。1 occurrence の
  1 日分の overdue 滞留積分。resolvedAt=Missing は未解決→dayEnd を上限に使う。SourceUnavailable の
  滞留は呼び出し側で別勘定。

## durable-facts 共有 ledger(R2・仕様 §2.8 / P0-4。**IO あり**)

append-only JSONL・ULID EventId dedup・single-writer(OwnerMachine)・内容最小化(I-13)。
mark/waive/ack/snooze/Resolution/identity mapping 等の **owner の意思表示と確定履歴** を Dropbox 共有 ledger に置く
(queue/plan/fulfillment cache/snapshot は machine-local・再生成可でここには置かない)。

- `$SourceVaultRoutineLedgerRoot` — ledger ディレクトリ(共有)。`$SourceVaultRoutineCacheRoot`(machine-local
  watermark・既定は ledger 下の `_cache_<machine>`)。`$SourceVaultRoutineThisMachineTag`(既定 $MachineName)。
- `SourceVaultRoutineSetOwnerMachine[tag]` / `SourceVaultRoutineOwnerMachine[]` — 唯一の書き手を owner.json に記録。
- `SourceVaultRoutineLedgerAppend[fact, opts]` — fact(`"FactKind"` 必須+occurrence 系は StableId/
  OccurrenceToken)に EventId(ULID)/At/AtAbs/By を付与し 1 行追記。**content-bearing キー(Label/Body/
  Summary/Title/Description/Prompt/Text/Content/Note/Subject/From/To/Name)は `Failure["NBRoutineContentLeak"]`**
  (I-13)。**single-writer**: 別 OwnerMachine が設定済みなら `Failure["NBRoutineNotOwnerMachine"]`。
  option `"IdempotencyKey"`: 同キーの既存 fact があれば追記せず既存を返す(冪等=AC-014)。
- `SourceVaultRoutineLedgerEvents[opts]`(`"SinceEventId"` で handoff ingest)/
  `SourceVaultRoutineLedgerWatermark[]`(tail EventId・ULID lexical 単調)。
- `SourceVaultRoutineLedgerReplay[opts]` — `<|"Occurrences"-><|key-><|Mark,Waive,Ack,Snooze,Resolution|>|>,
  "IdentityMappings", "Watermark"|>`。append-only+latest-wins なので **OwnerMachine 移動後も全 mark/waive/
  overdue 履歴を保持**(AC-026)。
- `SourceVaultRoutineFulfillmentCacheRebuild[]`(replay→machine-local cache watermark 書込)/
  `SourceVaultRoutineTickGuard[]`(**cache watermark==ledger tail のときだけ Ready**。handoff 直後の新 machine は
  未 ingest=NotReady→Rebuild 必須。attention tick を不完全な durable state で走らせない=AC-026)。

## 検証

- `test codes/SourceVault_routine_test.wls`(R1・65/65 green・IO なし)。
- `test codes/SourceVault_routine_ledger_test.wls`(R2-2・32/32 green・temp dir)。append/dedup/内容最小化/
  冪等/watermark/replay latest-wins/single-writer/OwnerMachine handoff(NeverIngested→Rebuild→Ready・
  history 保持)を網羅。全 headless・FE 非依存。

## 未実装(次以降)

R2 残=adapter 4種→ObligationOccurrence+freshness/StaleUsePolicy、R3=Board+ActionGate、
R4=policy+durable queue+送達保証、AT-1=AutoTrigger permit 増分、R8=自動化。extension=Plan/可視化。
