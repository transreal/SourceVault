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

## adapter -> ObligationOccurrence + freshness(R2-3・§2.1/3.1/3.4)

- `SourceVaultRoutineFreshness[observedAt, now, opts]` — Fresh/Stale/Unavailable(FreshSeconds/StaleSeconds)。
- `SourceVaultRoutineStaleUsePolicy[fresh, use]` — §3.4 用途別 policy(Board/ActiveReminder/BusyGating/Plan)。
  Unavailable+BusyGating→FailOpen、Stale+Plan→Freeze 等。
- `SourceVaultRoutineBuildOccurrence[kind, d, srcMeta]` — source→統一 ObligationOccurrence(§2.1)。
- `SourceVaultRoutineApplyDurable[occ, replay]` — ledger fact overlay(Waive>Resolution>ManualMark・
  Snooze/Ack で Attention・WasOverdue OR 保持=AC-025)。

## ActionGate — capability-class router(R3・§7/P0-7)

UI クリックを class で分離し、副作用ゼロで**判定のみ**返す(実行は呼び出し側)。

- `SourceVaultRoutineActionClass[kind]` — Select/LocalNavigation/LocalMutation/WorkflowDispatch/
  ExternalNavigation/Unknown。
- `SourceVaultRoutineActionGate[action, context]` — Select=常に許可(effect-free) / LocalNavigation=path
  containment(".." 拒否)+occurrence 存在確認 / **WorkflowDispatch=current SemanticDigest 再検証**(stale は
  Blocked=AC-028、一致で DelegateToAutoTrigger) / **ExternalNavigation=scheme allowlist(既定 https のみ)+
  domain allowlist**(file:/custom/不許可 domain は拒否=AC-029・RequiresConfirm) / LocalMutation=OwnerPermit
  必須+RequiresPreview+**AuditFact**(呼び出し側が ledger へ append。内容最小化キーのみ)。

## Board — attention list(R3・§5.1)

- `SourceVaultRoutineBoardData[occs, now, opts]`(**pure・headless**) — 注意が必要な行(Overdue/DueSoon かつ
  未 Satisfied/Waived・未失効 Snooze 除外)を Mandatory/overdue 優先→due 昇順でソート。各行に kind 別の適用可能
  action kind 一覧。opts IncludeResolved/IncludeSnoozed/SoonWindow。
- `SourceVaultRoutineBoardView[occs, opts]`(**FE**) — BoardData を Dataset 描画し、各 action ボタンが
  ActionGate 経由で発火。**要 Front End(NB 実機検証)**。ActionHandler/OwnerPermit/AllowedRoots を受ける。

## AttentionContext gate + envelope + ladder(R4a・§5/P0-1)

- `SourceVaultRoutineNotificationEnvelope[kind, opts]` — Stage/Urgency/**MeetingBypass/QuietHoursBypass 独立**/
  Channel/OccurrenceKey/EpisodeId。
- `SourceVaultRoutineAttentionGate[env, ctx]` — **会議ゲートと静音ゲートを独立評価**: defer iff
  (BusyQ&&!MeetingBypass)||(InQuietHours&&!QuietHoursBypass)。Lead15 は会議貫通するが静音は貫通しない
  (AC-003/AC-004)。
- `SourceVaultRoutineInQuietHours[policy, now]`(StartHour..EndHour・日跨ぎ wrap・DateObject は自 TZ)。
- `SourceVaultRoutineMandatoryLadderStage[eventStart, now, policy]` — 入場した tightest lead window=現ステージ・
  最小 lead のみ MeetingBypass+Critical(§5.3)。
- `SourceVaultRoutineCoverageDegradedQ[fresh]`(Stale/Unavailable/Partial=AC-008)。
- `DefaultAttentionPolicy`/`SetAttentionPolicy`(OwnerAuthorization 必須)/`AttentionPolicy`。

## durable notification queue(R4b・§5.2/5.3/P0-5・machine-local 再生成可)

append-only JSONL・replay-latest per EnvelopeId・Pending→Deferred→Delivered|Superseded|Expired。

- `SourceVaultRoutineEnqueueNotification[env, opts]` — EnvelopeId=(OccKey,Kind,Stage,Channel,EpisodeId) digest で
  **冪等**(hysteresis)。
- `SourceVaultRoutineQueueTick[ctx, opts]` — 各 Pending/Deferred を**現 context で AttentionGate 再評価**
  (連続会議で re-defer・busy 解消で deliver)。**MaxDeferSeconds 超過は Board fallback で必ず送達**。毎回 fresh
  DeliveryAttemptId=**外部チャネル at-least-once/Board effectively-once**(P0-5)。ChannelFn 注入。
- `SourceVaultRoutineSupersedeNotifications[occKey]`(occurrence 移動/取消で未送達 Superseded=AC-002/033)/
  `SourceVaultRoutineQueueRecords`/`SourceVaultRoutineQueueReset`。
- **罠**: WriteRawJSONString は Missing で失敗→iSVRtnAppendLine で Missing→Null サニタイズ。

## 統計 stream -> anomaly(R7・§4.3・**「未実行=状態異常」の配線**)

- `SourceVaultRoutineExecutionStreams[occs, opts]` — resolved ObligationOccurrence を日次ビン化し
  `RoutineExecutionRate`(Exposure=その日 due 数/Event=Satisfied 数)+`RoutineOverdueRate`(Event=overdue/
  missed)を返す。**空 stream は omit(I-15)**。Points は WindowStart/End(ISO Z)+EventCount/ExposureCount で
  `SourceVaultRunCaneAnomalyWorkflow[<|"Streams"->...|>]` にそのまま渡せる。opts TimeZone/Kinds。
- `SourceVaultRoutineOverdueSecondsByDay[occs, opts]` — 日次 OverdueContractSeconds 積分(P1-11)。
- anomaly の baseline/逸脱検知/相関は既存 1H-A ワークフローが処理(observe-only=EnforcementActions {})。

## 検証

全 headless(BoardView のみ FE=NB 実機済み)。**routine 累計 262 green**:
- R1 65 / R2-2 ledger 32 / R2-3 adapter 42 / R3 actiongate 32・board 16 / R4a attention 33 / R4b queue 25 /
  R7 streams 17。
- `SourceVaultRoutineBoardView` は result.nb で実機確認済み。R7 は umbrella で anomaly ワークフロー実接続を確認。

## 自動化提案(R8・§8）

判定核(R8a):`SourceVaultRoutineFormulaicScore[traces]`(**決定的**・小標本は非候補=P1-4)+
`SourceVaultRoutineAutomationEligibility[spec]`(スコアより先の独立 gate・Unattended は IP5Wired かつ冪等+
postcondition のみ=AC-011)+`SourceVaultRoutineRecertificationClass[spec]`(§9 TTL/receipt A/B/C）。

提案フロー(R8b):`ProposeAutomation[routineId,spec,traces]`(Eligible+Candidate のみ AutomationProposal を
ledger に PendingReview・内容最小化・**自動適用しない**I-16)→`ApproveAutomation[propId,spec,OwnerAuth]`
(TriggerSpec draft=Enabled->False+provenance+ExpiresAt、**AT-1 の MintPermit で draft に紐づく one-shot
Register permit 発行**)→ owner が `SourceVaultRegisterAutoTrigger[draft,"Permit"->permit]`。`RejectAutomation`/
`AutomationProposals`。テスト=`SourceVault_routine_automation_test.wls` 29+`..._proposal_test.wls` 24。

AT-1(autotrigger.wl・§8.3/P0-6）: `$SourceVaultAutoTriggerEnforcePermit`(既定 off）で Register/Enable 境界に
one-shot 署名 permit(SpecHash/Action/ExpiresAt/Nonce）+ExpiresAt 執行+EnabledAudit を additive 付与。
テスト=`SourceVault_autotrigger_permit_test.wls` 25。

## 未実装(次以降)

R9=mail。extension 残=CapacityModel/daily replan/FocusRequest/可視化 RX-1(→api_routineplan.md）。
