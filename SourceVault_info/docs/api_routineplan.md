# SourceVault_routineplan API

routine の **extension**(計画層 RX-2)。core(SourceVault_routine.wl)に依存し、identity 以外は純粋数学。
IO なし・FE 非依存(可視化 RX-1 は別)。日次は UTC(TimeZone オプション既定 0)。
仕様 = `sourcevault_routine_planview_ext_spec_v0_1.md` §3。

## 準備見積(§2 / P1-9)

- `SourceVaultRoutinePreparationTasks[event, prepSpec]` — 会議/講演の PreparationSpec 各 Step から PrepTask を
  導出。**identity は不変**(`prep:` + HMAC(親 StableId + 不変 StepId)。Effort/ChunkMax 変更で再 identify しない=
  AC-031 基盤)。Due=event Start − MinLeadDays、EarliestStart=event Start − WindowDays、Effort、DependsOn は
  Step の DependsOnStepId を prep StableId へ写像、Movable→True、ParentRef=event。PlacePlan に渡せる形。

## procrastination 予防(§3.6)

- `SourceVaultRoutineLatestSafeStart[due, effortHours, capacityFn, opts]` — 締切から実効容量を逆算し、
  「これ以上遅らせると間に合わない」最遅開始日を返す(容量不足は Missing["Infeasible"])。capacityFn[dayStartAbs]→
  その日の可用時間。opts TimeZone(0)/HorizonDays(365)。**先延ばし防止の時計**。
- `SourceVaultRoutineSlack[due, effortHours, capacityFn, now, opts]` — LatestSafeStart − now(秒)。負=既に手遅れ。
  小/負の Slack が SlackLow/Infeasible nudge の発火条件。

## 配置アルゴリズム(§3.2・純関数・決定的)

- `SourceVaultRoutinePlacePlan[tasks, capacityFn, opts]` — tasks を日次 chunk に配置。
  - **hard**: (1) DependsOn の DAG 検証(**cycle は Infeasible**=AC-044・CycleDetected True)、
    (2) Kahn 位相順で**最早 Due の ready タスクを優先**(安定 tie-break=TaskId)、(3) 各タスクは
    max(EarliestStart, 依存の finish+1日, plan 開始)から Due 日まで容量を**前倒し**充填。
  - Due までに残工数が入らないタスクは **Infeasible として報告**(**静かに落とさない**=AC-023)。
  - zero/unknown Effort は DefaultEffortHours。**同一入力→同一 plan**(決定的=AC-041)。
  - opts TimeZone(0)/PlanStart(Automatic=now)/DefaultEffortHours(1)。
  - 返り値 `<|"Chunks"->{<|TaskId,DayAbs,Hours|>...}, "Infeasible"->{<|TaskId,ShortfallHours|>...},
    "Order"->{ids}, "CycleDetected"->Bool|>`。

## CapacityModel / リスケジューリング(RX-2b・§3.1/3.4/3.5/3.7)

- `SourceVaultRoutineDefaultCapacityModel[]`(WeekdayHours 平日4h/週末0・FrontLoad 0.7）+
  `SourceVaultRoutineDayCapacityFn[capModel, opts]` — capacityFn[dayStartAbs]→実効時間(WeekdayHours−busy−
  未束縛 reservation・Away 日=0）。opts BusyHoursByDay/ReservationHoursByDay/AwayDays（dayKey="YYYY-MM-DD"）。
- `SourceVaultRoutinePlacePlan` の `"Pins"` オプション — owner pin/FocusReservation/immovable を固定 chunk として
  容量先消費し再配置しない（pinned 依存も finishDay 反映）。
- `SourceVaultRoutineReplan[tasks, capacityFn, opts]` — **progress 差引で残工数を roll-forward**・pins 固定・
  diff report(Moved/Added/Dropped/NewInfeasible）。**InputFresh->False(stale)は前 plan 保持+Degraded=
  PlanInputDegraded**(silent 再配置しない=AC-046）。
- `SourceVaultRoutineFocusRequest[request, tasks, capacityFn, opts]` — **特定作業優先スロット確保**:
  immovable を prior-plan 日に pin・focus window の容量を予約・**movable を後回しにして再配置**・入らない movable は
  Conflicts+**escalation メニュー{Defer/Waive/Automate/NegotiateDeadline}**(締切を勝手に破らない・非 silent=AC-023）。

## 検証

全 headless(routine core+plan 両ロード）:
- `SourceVault_routineplan_test.wls` **28/28**（準備見積/LSS/Slack/front-load/Infeasible/DAG/決定性/Due優先/prep chain）。
- `SourceVault_routineplan_reschedule_test.wls` **20/20**（CapacityModel/pins/replan auto-heal/PlanInputDegraded/
  FocusRequest/Conflict+escalation/immovable pin）。**合計 48 green**。
- **罠**: `used` の日キーは Round[dayAbs] 整数化必須（浮動小数 bit 不一致で二重予約）。

## 可視化 suite(RX-1・§4・data=headless / view=FE）

各可視化は pure な data 関数 + view renderer(Graphics/Graph・表示は要 FE）。
- `SourceVaultRoutineGanttData[plan, tasks]` / `SourceVaultRoutineGanttView[plan, tasks]` — タスク別タイムライン
  (バー=スケジュール日・Due マーカー）。
- `SourceVaultRoutineLoadData[plan, capacityFn, from, to]` / `SourceVaultRoutineLoadView[...]` — **負荷ヒートマップ**
  (日毎 planned/capacity 比・over 日を色分け）。**todo が特定日に集中しているか一目で見える procrastination 計器**。
- `SourceVaultRoutineProcessGraph[tasks]` — DependsOn 依存を **Graph**（汎用 DAG は Graph で描き Petri と誤称しない・
  形式 Petri は ClaudeOrchestrator observability adapter の scope）。
- clickable 要素は core §7 ActionGate 経由(BoardView と同型・(StableId,OccurrenceToken) 保持）。

検証: `SourceVault_routineplan_view_test.wls`(**20/20**）= data 関数 + view が Graphics/Grid/Graph object を
返すことを headless 確認。**視覚描画は NB 実機で要確認**（GanttView=Graphics/LoadView=Grid/ProcessGraph=Graph）。

## 未実装(次以降)

- durable PlanningConstraint/PlanningIntent/PlanChunkProgress の ledger 結線(§1/3.3）。
- Petri view の ClaudeOrchestrator plotPetriNetDetail adapter（形式 workflow scope）/ Plan diff view。
