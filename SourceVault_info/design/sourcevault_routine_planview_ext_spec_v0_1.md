# SourceVault ルーチン: 計画層 + 可視化層 extension 仕様 v0.1

**core からの分冊**(review v0_3 review_v1 §P1-10 の指摘に従い、reliable reminder の core と
Plan/FabricView を別冊化)。本書は core に依存するが、**core は本書に依存しない**
(core だけで R0〜R4 の忘却注意は完結)。

core: `sourcevault_routine_attention_spec_v0_4.md`(以下「core §n」)。
旧記述元: v0.3 §7(計画層)/§8(可視化層)。本書はそれを review v1 の P0-8/P1-3/P1-4/P1-9/P1-10 で
補強したもの。

status: draft(r0)。実装は core R3/R4 完了後(本書 RX-1/RX-2)。

---

## 0. 結論

- **計画(Plan)は使い捨て、durable な意思だけ残す**(review P0-8): PlanChunk(割付)は再生成物、
  PlanningConstraint(pin/focus 予約)・PlanChunkProgress・PlanningIntent(ad-hoc タスク)は
  core §2.8 の durable-facts 共有 ledger に置く。
- **procrastination 予防 3 点**: PreparationSpec による準備タスク前倒し生成、CapacityModel による
  前倒し分散配置、LatestSafeStart/Slack の常時計算+3 段 nudge。
- **柔軟なリスケジューリング**: daily replan による auto-heal(未消化は前送り)、FocusRequest による
  集中スロット確保(Movable を制約内で後送→diff→承認)。
- **可視化はすべて ActionGate(core §7)経由でワンクリック作業着手**: ガント・負荷ヒートマップ・
  工程ビュー(形式意味論のある scope のみ Petri、汎用は Graph)・Plan diff・Board。
- 本層も **observe/propose のみ**。実行・外部作用は core の ActionGate と AutoTrigger/PlanMessageRelease
  ゲートに委譲する。

## 1. データモデル(review P0-8)

### 1.1 PlanChunk(再生成物・機械ローカル)

```wl
<|"Type"->"PlanChunk", "SchemaVersion"->"0.1",
  "ChunkId"->_,                         (* この plan 内でのみ有効。再生成で変わってよい *)
  "StableId"->_, "OccurrenceToken"->_,  (* 対象 obligation(core identity) *)
  "PlannedDayLocal"->_, "PlannedWindow"->_|Missing,
  "PlannedEffort"->_Quantity,
  "Status"->"Planned"|"InProgress"|"Completed"|"Dropped",
  "BoundToReservationId"->_|Missing|>   (* FocusReservation 内へ束縛(§3.4) *)
```

置き場所: `<LocalState>/routine/plan/current.wxf`+履歴。**失われても再生成可能**
(core §1 原則 9)。

### 1.2 durable(core §2.8 の共有 ledger に置く)

```wl
"PlanningConstraint" -> <|"ConstraintId"->_, "Kind"->"Pin"|"FocusReservation",
  "StableId"->_, "OccurrenceToken"->_|Missing, "Window"->_, "OwnerSigned"->True|>,
"PlanChunkProgress" -> <|"StableId"->_, "OccurrenceToken"->_,
  "CompletedEffort"->_Quantity, "EvidenceRefs"->{...}, "AtUTC"->_|>,
"PlanningIntent" -> <|"IntentId"->_, "Label"->_(*owner-local*), "TargetEffort"->_Quantity,
  "By"->_, "AllowedWindows"->_, "CreatedFrom"->"FocusRequest"|"Manual"|>
```

- **pin/FocusReservation は硬い制約なので durable**(review P0-8: plan 消失で hard constraint が
  消える問題)。
- **ad-hoc FocusRequest(`"Task"->"論文改訂"` のような文字列)は承認時に PlanningIntent または
  Commitment を作る**(次の replan で消えないため。AC-042 相当)。
- PlanChunkProgress は部分実行を残工数へ反映する正本(§3.3)。

### 1.3 PreparationSpec(owner 署名・core AttentionPolicy と同格)

```wl
<|"TemplateId"->_,
  "Match"-><|"Kind"->"CalendarEvent","MandatoryOnly"->_,"Patterns"->{...},"Categories"->{...}|>,
  "Prep"-><|"TotalEffort"->_Quantity,"WindowDays"->_,"ChunkMax"->_Quantity,"MinLeadDays"->_,
    "Steps"->{<|"StepId"->_(*不変*),"Label"->_,"Effort"->_Quantity,"DependsOnStepId"->_|Missing|>...}|>|>
```

- **StepId は不変**(review P0-1: Effort/ChunkMax 変更で ordinal がずれ pin が別 task を指す問題)。
  PrepTask occurrence の OccurrenceToken は親 occurrence の token(core §2.2)、StableId は
  `prep:HMAC(親StableId+StepId)`。Effort 等の変更は Revision に入り、identity は不変(AC-031rv 相当)。

## 2. PreparationSpec → PrepTask(準備見積・review P1-9)

- 会議・講演 occurrence が Match(照合は 0.7 情報=Summary/Categories)すると、各 Step から
  PrepTask occurrence を派生(EachOccurrence・Movable=True・Effort・
  Due=イベント開始−MinLeadDays・ParentRef=イベント)。
- **親取消・移動の reconcile(review P1-9)**:
  - 親が Cancelled → **未完了 PrepTask を Cancelled**、**履行済み PrepTask は履歴保持**
    (Resolution 済みは core §2.4 で不変)。
  - 親が reschedule → 同じ child identity(StableId/StepId 不変)のまま Due を更新(Revision)。
  - PreparationSpec の Step/Checklist 変更 → StepId 単位で追加/削除/Effort 改定。既存 StepId の
    pin/progress は保持。削除された StepId の未完了 PrepTask は Dropped、完了分は履歴保持。
- 見積り改善: 同 template の過去実績工数(PlanChunkProgress の合計・ManualMark 時刻差)の中央値で
  TotalEffort 既定の更新を**提案のみ**(自動変更しない。core 論点 j)。
- PrepTask の履行 evidence: ManualMark / リンクした OnWorkTask の Status=Done / checklist 全消化。

## 3. 計画層(配置・リスケ)

### 3.1 CapacityModel(owner 署名)

```wl
<|"WeekdayHours"-><|Monday->Quantity[4,"Hours"],...|>,
  "FrontLoad"->0.7,                     (* [0,1]。締切直前でなく早い日から埋める *)
  "AllowedWindows"->{...},              (* 曜日×時間帯。深夜等を除外 *)
  "Signature"->_|>
```

実効容量(日)= WeekdayHours − カレンダー busy(FreeBusy 0.5)− FocusReservation の
未束縛保持分(§3.4)。Away 日(core §4.2)は 0。

### 3.2 配置アルゴリズム(純関数・review P1-3)

**hard constraints(違反不可、lexicographic 優先)**:
1. DependsOn の DAG 順序(**配置前に cycle validation。cycle は Infeasible**=AC-044 相当)。
2. DueAtUTC/LatestSafeStart(締切)。
3. owner pin / FocusReservation の窓。
4. AllowedWindows・日次実効容量上限。

**soft objective(hard を満たす中で最小化、固定 lexicographic)**:
1. LatestSafeStart 違反リスク(Slack 最小の obligation を優先配置)。
2. FrontLoad(早い日バイアス)。
3. 日次負荷の分散(集中日の平準化)。
4. 安定 tie-break(StableId+OccurrenceToken の辞書順)。

- zero/unknown Effort: 既定 Effort(policy)を与え、unknown は「見積り要」フラグ付きで最小枠のみ確保。
- 部分日・複数 TimeZone: LatestSafeStart は日でなく owner TimeZone の instant/window で計算
  (review P1-3)。
- 同一入力→同一 plan(冪等・AC-041rv 相当)。

### 3.3 progress accounting(review P0-8)

- chunk の消化証明: ManualMark(完了/部分)・リンク OnWorkTask の mtime/Status・
  PrepTask checklist 消化。これらから PlanChunkProgress(CompletedEffort)を durable ledger へ。
- 残工数 = TotalEffort − Σ CompletedEffort。翌 replan は残工数で再配置(部分実行を正しく反映=
  AC-043rv 相当)。
- 工程ビューの InProgress token は PlanChunk.Status/PlanChunkProgress から決定(データモデルに
  in-progress を持たせた=review P0-8 の「doing token の裏付けなし」対応)。

### 3.4 FocusReservation と二重計数回避(review P1-4)

- FocusReservation は **capacity を消費する container**。対応 chunk はその**内側へ bind**
  (`BoundToReservationId`)。
- 実効容量計算では「未束縛の soft hold」分だけを控除し、**bind 済み chunk の工数を重ねて
  控除しない**(AC-045rv 相当)。busy/AllowedWindows と交差する時間のみ控除。

### 3.5 daily replan(auto-heal・使い捨て)

- daily tick(+on-demand)で PlanChunk を再生成。未消化(Planned/InProgress で過去日)は
  自動的に前へ転がる(AC-025rv 相当。手動操作不要)。
- pin/FocusReservation(durable)と締切だけが不動。
- **stale/partial 入力時は silent auto-heal を止める**(review P0-8): calendar/source が
  Stale/Partial なら前 plan を保持し `PlanInputDegraded` を出す(core §3.4 StaleUsePolicy の
  「Plan 自動変更=凍結」と一致。AC-046rv 相当)。
- ReplanReport(diff): moved/added/dropped/Slack 悪化を列挙。閾値未満は無通知(silent)、
  Slack 悪化・Infeasible 発生時のみ core §5 の envelope 経由で通知。

### 3.6 LatestSafeStart / Slack / nudge(procrastination 予防)

- `LatestSafeStart` = 締切から残工数と実効容量を逆算した instant/window(§3.2)。
- `Slack` = LatestSafeStart − now。
- nudge 3 段(すべて core envelope・occurrence 毎 1 回):
  `PrepWindowOpen`(準備 window 開始・親移動時は supersede 後に再評価=AC-028rv 相当)→
  `SlackLow`(Slack<Importance 別閾値)→ `Infeasible`(残容量<残工数)。
- **Infeasible は静かに諦めない**(review): §3.7 の選択肢メニューを必ず提示(AC-023rv 相当)。

### 3.7 FocusRequest と Infeasibility エスカレーション

FocusRequest は式テンプレート 1 セル(core §1 原則 10):

```wl
SourceVaultFocusRequest[<|"Task"->_(*obligation 参照 or 新規文字列*), "Hours"->_, "By"->_,
  "SlotGranularity"->_Quantity, "PreferDays"->Automatic, "PushMovable"->True|>]
```

動作(すべて提案→diff→1 クリック承認):
1. 承認時、新規文字列 Task は **PlanningIntent/Commitment を durable 化**(§1.2)。
2. FocusReservation(durable)を確保。カレンダー空き×容量から候補 slot。
3. `PushMovable` なら衝突 Movable chunk を各自の Due/GraceUntil を破らない範囲で後送。
4. 入らない場合は**衝突一覧**(後送不能・締切違反になる obligation を明示)+選択肢:
   (a) 延期候補(Movable+Slack 正)、(b) waive 候補(Importance Low)、
   (c) 自動化候補(core §8 eligible)、(d) 締切交渉(Commitment の返信作業を ActionGate 経由で開く)。
5. 選択は owner。層は自動実行しない。FocusSlot のカレンダー書き戻しは非目標(core 論点 o)。

## 4. 可視化層(FabricView suite)

### 4.1 共通基盤

- core/View 分離: `SourceVaultScheduleFabric`(core・AsOf snapshot)を各 View(純 renderer)が
  受け取る。全図形要素は (StableId, OccurrenceToken) を保持。
- クリックは **core §7 ActionGate 経由**。通常クリック=Select/Inspect(effect-free)、
  作用は明示 action メニュー内ボタンのみ(review P0-7)。action 前に current SemanticDigest 再検証。

ActionGate 経由の Kind 別ワンクリック(盛り込み一覧・v0.3 §8.1 を ActionGate class 付きで再掲):

| Kind | アクション(class) |
|---|---|
| Commitment(mail) | スレッド表示(Select)/ 返信作業開始=draft 起動(WorkflowDispatch)/ 延期依頼 draft(WorkflowDispatch)/ Candidate→Open(LocalMutation)/ FalseAlarm 報告(LocalMutation)/ Snooze・waive(LocalMutation) |
| OnWorkTask | ノートブックを開く(LocalNavigation・path containment+revision 再解決)/ ディレクトリを開く(LocalNavigation)/ focus slot 確保(LocalMutation→テンプレート)/ Snooze(LocalMutation) |
| CalendarEvent | 詳細(Select・レベル相応)/ PrepTask 一覧へ(Select)/ 準備ノート生成して開く(LocalMutation: メタ充填 .nb 作成)/ 本文 URL(ExternalNavigation・https allowlist)/ PreparationSpec override(LocalMutation) |
| Routine | 今すぐ実行(WorkflowDispatch→AT 発火)/ evidence 履歴(Select)/ 契約詳細(Select)/ Snooze・waive(LocalMutation) |
| PrepTask | 親へ(Select)/ リンクノートを開く・作成(LocalNavigation/LocalMutation)/ checklist 消化(LocalMutation)/ ManualMark(LocalMutation)/ 今日へ・後ろへ・pin(LocalMutation) |
| AutomationProposal | レビュー UI(Select)/ 承認テンプレート挿入(core §8.2、permit 携行)/ 却下(LocalMutation) |
| FocusSlot | 対象を開く(LocalNavigation)/ 解除・延長(LocalMutation) |
| SystemHealth | 診断 view(Select)/ 再取得(LocalMutation) |

### 4.2 ガント/タイムライン `SourceVaultFabricGanttView[from,to]`

行=obligation(Kind/親でグループ化)。準備 window(淡)/計画 chunk(濃)/会議ブロック/
Due=◆/GraceUntil=◇/today 線/overdue=赤/FocusSlot=枠。ズーム(日/週/月)。バークリック→
ActionGate。chunk の「今日へ/後ろへ」クイック操作(pin 化=LocalMutation)。
実装: Graphics+Rectangle+EventHandler(簡易は TimelinePlot fallback)。

### 4.3 工程ビュー(review P1-10: Petri は形式意味論のある scope 限定)

- **`SourceVaultFabricProcessView[scope]` の既定は Graph 可視化**(DependsOn/ParentRef/
  thread 連鎖の DAG)。汎用の依存関係は Graph で描く(Petri と誤称しない)。
- **`SourceVaultFabricPetriView[scope]` は明示 workflow semantics を持つ scope のみ**:
  1 routine のパイプライン、1 講演の Step 依存(place=状態 todo/doing/done/waived、
  transition=Step、token=現在状態、marking=fulfillment ledger 由来)。place/transition/token の
  正式 mapping を持つ adapter を通す。
  - **既存資産再利用**: ClaudeOrchestrator_observability.wl の `plotPetriNetDetail` /
    `checkPetriNetVertices` を adapter(obligation graph → net spec)経由。頂点クリックは
    adapter が EventHandler で ActionGate にラップ。
- BPMN 風スイムレーン: 同一グラフの別レンダリング(レーン=owner/自動化/外部相手)。往復
  (返信待ち)を可視化。BPMN 完全準拠は非目標(エンジンを作らない・可視化のみ)。
- done token 到達履歴(fulfillment ledger)を淡色残置=達成の可視化。

### 4.4 負荷ヒートマップ `SourceVaultFabricLoadView[month|week]`

カレンダー格子。日毎の色=計画負荷/実効容量。過負荷日・Away 日・focus 日を区別。
**todo の特定日集中を一目で示す**(procrastination 予防の主計器)。日クリック→その日の
chunk/会議一覧(各行 ActionGate)。「この日を空けたい」→ FocusRequest テンプレート挿入。

### 4.5 Plan diff `SourceVaultPlanDiffView[report]`

replan/FocusRequest の前後比較: 移動 chunk 表+ミニガント(旧=ghost、新=実線)+Slack 悪化
リスト。承認/却下/個別 pin。

### 4.6 Board v2(core R3 で実装・ここは Plan/View 統合分)

core §5 の Board にセクション追加: PrepTask(今日の chunk)/ FocusSlot / Plan diff への入口 /
他 View(ガント/工程/負荷)への入口ボタン。3 軸状態表示は core 準拠。

### 4.7 入力 UI 原則

FocusRequest・PreparationSpec 登録・pin/waive・自動化承認は式テンプレート 1 セルを Board/View が
挿入し owner が評価(core §1 原則 10)。フォーム UI を作らない。ドラッグは WL FE で非現実的の
ため「今日へ/後ろへ/pin」クリック+テンプレートで代替(core 論点 k)。

## 5. 増分実装計画

| Inc | 内容 | 依存 |
|---|---|---|
| RX-1 | 可視化 suite(ガント→負荷ヒートマップ→Graph 工程→Petri(plotPetriNetDetail adapter)→diff 骨格)。ActionGate 経由 | core R3,R4 |
| RX-2 | 計画層(PreparationSpec/PrepTask 派生+reconcile/CapacityModel/配置(DAG validation)/progress accounting/FocusReservation bind/daily replan auto-heal/FocusRequest/nudge 3 段) | core R4, RX-1 |

## 6. 受入基準(core AC 番号に連番。rv3-n=v0.3 review §7 の n を継承)

**AC-E01**(rv3-19) 各 View の全図形要素クリックが Kind 相応の正しい対象を core §7 ActionGate 経由で
開く。対象パッケージ未ロード時はアクション非表示で View 自体は動く。
**AC-E02**(rv3-21+P1-3) replan は冪等(同一入力→同一 plan)で、pin/FocusReservation と締切を破らない。
**AC-E03**(rv3-22) FocusRequest は Movable でない chunk・締切違反になる移動を勝手に行わず、
衝突一覧として提示する。
**AC-E04**(rv3-23) PrepTask chunk が LatestSafeStart より後にしか置けない場合、必ず Infeasible として
エスカレーションし、静かに諦めない。
**AC-E05**(rv3-24) Plan・可視化の AccessLevel<0.7 出力に Label/パス/URI/生 UID/ActionRef が含まれない。
**AC-E06**(rv3-25) 未消化 chunk は翌 replan で自動的に前送りされる(手動操作不要)。
**AC-E07**(rv3-26+P0-8) owner pin/FocusReservation は current plan を失って再生成しても durable ledger
から復元され、日付/窓を維持する(締切違反時のみ衝突一覧に載る)。
**AC-E08**(rv3-28) 準備 window 開始 nudge(PrepWindowOpen)は occurrence 毎 1 回で、親イベント移動時は
supersede 後に新 window で再評価される。
**AC-E09**(rv3-42) ad-hoc FocusRequest 承認後に durable PlanningIntent/Commitment が存在する
(次の replan で消えない)。
**AC-E10**(rv3-43) PlanChunk の partial completion が PlanChunkProgress 経由で残工数と翌 replan に
正しく反映される。
**AC-E11**(rv3-44) DependsOn cycle は配置せず Infeasible として説明される。
**AC-E12**(rv3-45) FocusReservation 内へ bind 済み chunk の工数を容量から二重控除しない。
**AC-E13**(rv3-46) calendar Stale/Partial 中に silent auto-heal で plan を大幅変更せず、
PlanInputDegraded を出す。
**AC-E14**(P1-9) 親 CalendarEvent の取消で未完了 PrepTask は Cancelled、履行済み PrepTask 履歴は保持、
reschedule では同一 child identity のまま Due 更新。
**AC-E15**(P1-10) `SourceVaultFabricPetriView` は place/transition/token の正式 mapping を持つ scope
にのみ適用され、汎用依存は Graph で描かれる(Petri と誤称しない)。

## 7. 未解決論点

- (o) FocusSlot のカレンダー書き戻し(実カレンダーに blocking 予定を作る)— 非目標。外向き作用の
  ため、やるなら PlanMessageRelease 級の承認ゲートを通す別仕様。
- (r) 見積り実績学習を自動化するか(現状 j: 提案のみ)。owner の受容率が高ければ将来 opt-in。
- (s) 複数 PreparationSpec が同一イベントに match した場合の合成規則(union か優先度か)— RX-2 で確定。
