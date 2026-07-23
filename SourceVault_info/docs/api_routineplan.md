# SourceVault_routineplan API

routine の **extension**(計画層 RX-2)。core(SourceVault_routine.wl)に依存し、identity 以外は純粋数学。
IO なし・FE 非依存(可視化 RX-1 は別)。日次は UTC(TimeZone オプション既定 0)。
仕様 = `sourcevault_routine_planview_ext_spec_v0_1.md` §3。

## 準備見積(§2 / P1-9)

### SourceVaultRoutinePreparationTasks[event, prepSpec] → {task...}
会議/講演の PreparationSpec 各 Step から PrepTask を導出。**identity は不変**(`prep:` + HMAC(親 StableId +
不変 StepId)。Effort/ChunkMax 変更で再 identify しない=AC-031 基盤)。Due=event Start − MinLeadDays、
EarliestStart=event Start − WindowDays、Effort、DependsOn は Step の DependsOnStepId を prep StableId へ写像、
Movable→True、ParentRef=event。event: `<|"EventId","OriginalStart","Start"|>`。prepSpec: `<|"MinLeadDays",
"WindowDays","Steps"->{<|"StepId","Effort",("DependsOnStepId")|>...}|>`。PlacePlan に渡せる形。

## procrastination 予防(§3.6)

### SourceVaultRoutineLatestSafeStart[due, effortHours, capacityFn, opts]
締切から実効容量を逆算し、「これ以上遅らせると間に合わない」最遅開始日を返す(容量不足は
`Missing["Infeasible"]`)。capacityFn[dayStartAbs]→その日の可用時間。**先延ばし防止の時計**。
→ dayStartAbs (Real) | Missing["Infeasible"]
Options: TimeZone -> 0, HorizonDays -> 365 (この日数を超えても effort が入らなければ Infeasible)

### SourceVaultRoutineSlack[due, effortHours, capacityFn, now, opts]
LatestSafeStart − now(秒)。負=既に手遅れ、Infeasible なら Missing。小/負の Slack が SlackLow/Infeasible
nudge の発火条件。
→ Real (seconds) | Missing
Options: TimeZone -> 0, HorizonDays -> 365

## 配置アルゴリズム(§3.2・純関数・決定的)

### SourceVaultRoutinePlacePlan[tasks, capacityFn, opts]
tasks を日次 chunk に配置。
- **hard**: (1) DependsOn の DAG 検証(**cycle は Infeasible**=AC-044・CycleDetected True)、
  (2) Kahn 位相順で**最早 Due の ready タスクを優先**(安定 tie-break=TaskId)、(3) 各タスクは
  max(EarliestStart, 依存の finish+1日, plan 開始)から Due 日まで容量を**前倒し**充填。
- Due までに残工数が入らないタスクは **Infeasible として報告**(**静かに落とさない**=AC-023)。
- zero/unknown Effort は DefaultEffortHours。**同一入力→同一 plan**(決定的=AC-041)。
tasks: `{<|"TaskId","DueAtUTC","Effort"(hours or Quantity),("DependsOn"->{ids}),("EarliestStart")|>...}`。
capacityFn[dayStartAbs]→hours。
→ `<|"Chunks"->{<|"TaskId","DayAbs","Hours"|>...}, "Infeasible"->{<|"TaskId","ShortfallHours"|>...},
"Order"->{ids}, "CycleDetected"->Bool|>`
Options: TimeZone -> 0, PlanStart -> Automatic (=now), DefaultEffortHours -> 1,
Pins -> {} ({<|"TaskId","DayAbs","Hours"|>...} — owner pin/FocusReservation/immovable を固定 chunk として
容量先消費し再配置しない。pinned 依存も finishDay に反映)

## CapacityModel / リスケジューリング(RX-2b・§3.1/3.4/3.5/3.7)

### SourceVaultRoutineDefaultCapacityModel[] → CapacityModel
既定 CapacityModel: WeekdayHours(平日4h/週末0)、FrontLoad 0.7、AllowedWindows All。

### SourceVaultRoutineDayCapacityFn[capModel, opts] → Function[dayStartAbs -> hours]
capacityFn を構築: WeekdayHours − calendar busy − 未束縛(unbound) FocusReservation hold。Away 日=0。
束縛済み reservation chunk は Pins として配置され二重減算されない(AC-045)。
Options: BusyHoursByDay -> <||> (dayKey="YYYY-MM-DD"→hours), ReservationHoursByDay -> <||>,
AwayDays -> {} ({dayKeys}), TimeZone -> 0

### SourceVaultRoutineReplan[tasks, capacityFn, opts]
**progress 差引で残工数を roll-forward**・pins 固定・diff report(Moved/Added/Dropped/NewInfeasible)。
**InputFresh->False(stale)は前 plan 保持+Degraded=PlanInputDegraded**(silent 再配置しない=AC-046)。
→ `<|"Plan", "Report"-><|"Moved","Added","Dropped","NewInfeasible"|>, "Degraded"->Bool|>`
Options: PriorPlan -> (none), Pins -> {}, Progress -> <||> (`<|taskId->completedHours|>`),
InputFresh -> True, + SourceVaultRoutinePlacePlan の全 opts

### SourceVaultRoutineFocusRequest[request, tasks, capacityFn, opts]
**特定作業優先スロット確保**: immovable(Movable->False)を prior-plan 日に pin・focus window の容量を予約・
**movable を後回しにして再配置**・入らない movable は Conflicts+**escalation メニュー
{Defer/Waive/Automate/NegotiateDeadline}**(締切を勝手に破らない・非 silent=AC-023)。
request: `<|"WindowStart","WindowEnd"(abs),"Hours"|>`。
→ `<|"Plan", "Conflicts"->{taskIds}, "Feasible"->Bool, "Options"->{"Defer"|"Waive"|"Automate"|
"NegotiateDeadline"}|>` (Options = Conflicts がある時に出す escalation メニュー)
Options: PriorPlan -> (none), + SourceVaultRoutinePlacePlan の全 opts

## 検証

全 headless(routine core+plan 両ロード):
- `SourceVault_routineplan_test.wls` **28/28**(準備見積/LSS/Slack/front-load/Infeasible/DAG/決定性/Due優先/prep chain)。
- `SourceVault_routineplan_reschedule_test.wls` **20/20**(CapacityModel/pins/replan auto-heal/PlanInputDegraded/
  FocusRequest/Conflict+escalation/immovable pin)。**合計 48 green**。
- **罠**: `used` の日キーは Round[dayAbs] 整数化必須(浮動小数 bit 不一致で二重予約)。

## プライバシー継承原則(全 view/data 共通)

**出力のプライバシーレベル = 入力データの PrivacyLevel の最大値**。
- item/task レベル: FabricTasks の OnWorkTask/PrepTask、AgendaData の day item(calendar/deadline/
  review/MailDeadline)は全て `"PrivacyLevel"` を運ぶ(欠落/非数値は **1.0 扱い= fail-safe**。
  prep task はラベルに event summary を埋め込むため event の PL を継承)。
- 集約レベル: AgendaData は `"MaxPrivacyLevel"` = max(day items, overdue, mail items) を返す
  (空= 0.0、計算失敗= 1.0)。メールは加えて `MailMaxPrivacyLevel` オプション(既定 1.0)と AccessLevel の
  Min が実効上限となり、上限超のメールは Mail リストから**除外**される(wrap ではなく除外)。
- view レベル: AgendaView/GanttView/LoadView は集約 PL ≥ 0.5 で**秘匿 wrap**
  (`iSVRPWrapConfidential`: L1 自己マーキング badge 付き Framed + L2 ClaudeCode`Confidential +
  L3 NB スキャン予約 + L4 共有 registry)。wrap 時の返り値 Head は Graphics/Grid でなく Framed になる。
- ProcessGraph は**合成用データ**(Graph)なので wrap しない。描画する caller が
  `iSVRPMaxPL[tasks]` で wrap する責務を持つ。

## 可視化 suite(RX-1・§4・data=headless / view=FE)

各可視化は pure な data 関数 + view renderer(Graphics/Graph・表示は要 FE)。TaskId は identity として保持、
表示ラベルは Label/StepId/TaskId の順で解決(内部 `iSVRPLabel`)。

### SourceVaultRoutineGanttData[plan, tasks] → {row...}
タスク別タイムライン行を返す(FirstDay 昇順、TaskId で安定 tie-break)。
→ `{<|"TaskId","Label","Days"->{dayAbs...},"HoursByDay","TotalHours","DueAtUTC","FirstDay","LastDay"|>...}`

### SourceVaultRoutineGanttView[plan, tasks, opts]
Gantt/timeline Graphics を描画(バー=スケジュール日・Due マーカー・バーは TaskId ツールチップ付き)。
クリック導線は BoardView/ActionGate と同型。要 FE。
→ Graphics(max task PL ≥ 0.5 なら秘匿 wrap で Framed)
Options: TimeZone -> 0

### SourceVaultRoutineLoadData[plan, capacityFn, from, to, opts] → {day...}
日毎の load を [from, to] 区間で返す。**todo が特定日に集中しているか一目で見える procrastination 計器**。
→ `{<|"DayAbs","DayKey","Planned"(hours),"Capacity","Ratio","Over"->Bool,"Tasks"->{<|"TaskId","Label",
"Hours"|>...}|>...}`
Options: TimeZone -> 0, Tasks -> {} (ラベル解決用に元 tasks リストを渡す)

### SourceVaultRoutineLoadView[plan, capacityFn, from, to, opts]
**負荷ヒートマップ**(日毎 planned/capacity 比のカレンダーグリッド・over 日を色分け・セルに task ラベル+
ツールチップ)。要 FE。
→ Grid(max task PL ≥ 0.5 なら秘匿 wrap で Framed。"Tasks" 未指定は開示ラベルなし= plain)
Options: TimeZone -> 0, Tasks -> {}

### SourceVaultRoutineProcessGraph[tasks, opts]
DependsOn 依存を **Graph** で構築(頂点=TaskId・辺=DependsOn)。汎用 DAG は Graph で描き Petri と誤称しない
(形式 Petri は ClaudeOrchestrator observability adapter の scope)。headless でも使える。
→ Graph
Options: VertexLabels -> Automatic (Label/StepId/TaskId に解決したラベルを表示。None で無効化)

検証: `SourceVault_routineplan_view_test.wls`(**20/20**)= data 関数 + view が Graphics/Grid/Graph object を
返すことを headless 確認。**視覚描画は NB 実機で要確認**(GanttView=Graphics/LoadView=Grid/ProcessGraph=Graph)。

## ScheduleFabric 連携(実カレンダー + $onWork → plan tasks/capacity)

[NBAccess](https://github.com/transreal/NBAccess) の `NBOnWorkTasks`/`NBCalendarEvents`/`NBCalendarFreeBusy`
に**弱結合**(未ロードなら空 `{}`/既定 capacityFn を返す。ハード依存しない)。

### SourceVaultRoutineFabricTasks[from, to, opts] → {task...}
実データから plan tasks を構築: $onWork の notebook 締切(NBAccess`NBOnWorkTasks、[from,to] に Due がある
open task を Title でラベル、Effort はメタデータか既定値)+ PreparationSpecs にマッチする calendar meeting
から導出した準備タスク(SourceVaultRoutinePreparationTasks 経由)。
→ `{<|"Kind"->"OnWorkTask","TaskId"->"nb:"<>id,"Label","DueAtUTC","Effort","Movable","PrivacyLevel",
"DependsOn"->{}|>...}` (+ prep task 由来のエントリ)。SourceVaultRoutinePlacePlan / 各 view にそのまま渡せる。
Options: PrivacySpec -> `<|"AccessLevel"->1.0|>` (LOCAL FE view は Title/Summary ラベルに 1.0 が必要),
OnWorkTasks -> Automatic (live NBAccess 読み取り。テスト時はリストを注入可), CalendarEvents -> Automatic,
PreparationSpecs -> {} (`{<|"Match"-><|"Patterns","MandatoryOnly"|>,"Prep"->PreparationSpec|>...}`),
DefaultEffortHours -> 2, IncludeDone -> False

### SourceVaultRoutineFabricCapacityFn[from, to, opts] → Function[dayStartAbs -> hours]
CapacityModel から**オーナーの実カレンダー busy 時間を差し引いた** capacityFn を構築(NBAccess`
NBCalendarFreeBusy、free/busy メタデータのみで AccessLevel 0.5 で動作)。実際の会議を避けて配置される。
Options: CapacityModel -> Automatic (=SourceVaultRoutineDefaultCapacityModel[]), FreeBusy -> Automatic
(live 読み取り。注入可), AwayDays -> {}, TimeZone -> 0

## 日次アジェンダ統合(calendar events + $onWork deadlines/reviews + 要対応メール)

### SourceVaultRoutineAgendaData[from, to, opts] / [Quantity[n,"Days"], opts] / [] → agenda
オーナーの calendar events(NBAccess`NBCalendarEvents)と $onWork の notebook 締切/NextReviews
(NBAccess`NBOnWorkTasks)、要対応メール(SourceVaultMailAgendaItems — [SourceVault_mailagenda](https://github.com/transreal/SourceVault_mailagenda)
に弱結合)を日ごとにグループ化した統合アジェンダ。各 notebook item は "Path" を持ち、view から
ワンクリックで開ける。引数なし呼び出しは `Quantity[7,"Days"]` 既定。NBAccess/mailagenda 未ロード時は
それぞれ空。
**Deadline と NextReview は独立した2件として配置**(NBOnWorkTasks の `"DeadlineDue"` /
`"ReviewDue"` を使用): 〆切は〆切の日、レビューはレビューの日に出る。同じ日に両方来る場合は
〆切が優先(重複行なし)。`Due`/`DueKind` しか持たないレガシー/注入レコードは従来どおり1件。
これがないと**遠い将来の Deadline が窓内の NextReview を隠し**、「今週のノートブック」
(SourceVaultUpcomingSchedule は Deadline 列と NextReview 列を両方出す)と食い違う。
締切のあるメールは `"MailDeadline"` として該当日の AllDay にも合流(クリックで対応ウィンドウを開く)。
AllDay 内の並びは Deadline→MailDeadline→NextReview→all-day event→その他 のランク順(同ランク内は Label)。
→ `<|"From","To","TimeZone","Overdue"->{期限超過の deadline/review item...},
"Mail"->{mail agenda item...}, "MailPendingCount",
"Days"->{<|"DayAbs","DayKey","Weekday","AllDay"->{deadline/review/all-day-event/MailDeadline item...},
"Timed"->{timed event...}|>...}, "MaxPrivacyLevel"->Real|>`
(各 item は "PrivacyLevel" を運ぶ。"MaxPrivacyLevel" = day items/Overdue/Mail 全開示成分の max、
空 0.0/失敗 1.0)。Mail item(mailagenda 由来): `<|"RecordId","Subject","From","Summary","Date","Deadline",
"Category","ThreadCount","PrivacyLevel"|>`。
Options: PrivacySpec -> `<|"AccessLevel"->1.0|>`, CalendarEvents -> Automatic, OnWorkTasks -> Automatic,
ModifiedWithinDays -> 120 (task スキャン窓), IncludeOverdue -> True, TimeZone -> Automatic (=$TimeZone),
IncludeMail -> Automatic (=True。要対応メールバンドを含めるか), MailItems -> Automatic
(live SourceVaultMailAgendaItems 読み取り。テスト時はリスト注入可), MailMaxPrivacyLevel -> 1.0
(Min[この値, AccessLevel] が実効上限。上限超のメールは Mail リストから除外=非表示ではなく除外)

### SourceVaultRoutineAgendaView[from, to, opts] / [Quantity[n,"Days"], opts] / []
SourceVaultRoutineAgendaData を縦型タイムラインとして描画: 日毎に all-day band(notebook Deadline=赤・
MailDeadline=赤褐色・NextReview=青・all-day event=緑)→timed event、続いて overdue バナー(期限超過・
赤枠)、続いて要対応メールバンド(締切超過→今後の締切→締切なし の3グループ、件数見出し付き)。
notebook 行/メール行はクリック可能(notebook=SystemOpen — Dropbox online-only ファイルもダウンロードして
開く。mail=SourceVaultMailAgendaOpen で対応ウィンドウ)。全セクション空なら「予定・締切・要対応メールは
ありません」を返す。要 FE。
→ column layout (Framed/Column)
Options: SourceVaultRoutineAgendaData と同一

## 未実装(次以降)

- durable PlanningConstraint/PlanningIntent/PlanChunkProgress の ledger 結線(§1/3.3)。
- Petri view の ClaudeOrchestrator plotPetriNetDetail adapter(形式 workflow scope)/ Plan diff view。