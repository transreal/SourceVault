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

## 検証

`test codes/SourceVault_routineplan_test.wls`(routine core+plan 両ロード・**28/28 green**)。
LatestSafeStart/Slack・front-load 配置・over-capacity Infeasible(非 silent)・DependsOn 順序・DAG cycle・
決定性・Due 優先・準備見積(identity 不変・Step 依存写像)・prep chain の end-to-end 配置を網羅。全 headless。

## 未実装(次以降)

- CapacityModel(owner 署名)+ カレンダー busy/FocusReservation 控除の capacityFn 生成(§3.1/3.4)。
- daily replan auto-heal + ReplanReport diff(§3.5)/ FocusRequest + Infeasibility エスカレーション(§3.7)。
- PlanChunkProgress(残工数反映)+ durable PlanningConstraint/Intent(§1/3.3)。
- 可視化 suite RX-1(ガント/負荷ヒートマップ/Graph 工程/Petri/Plan diff・**FE=NB 実機**)。
