# SourceVault ルーチン注意喚起+自動化提案+スケジュール計画 仕様案 v0.3

**status: superseded**(`sourcevault_routine_attention_spec_v0_3_review_v1.md` を受けて
**`sourcevault_routine_attention_spec_v0_4.md`(core・正準)**+
**`sourcevault_routine_planview_ext_spec_v0_1.md`(計画/可視化 extension)**に分冊改訂。
v0.4 で v0.3 review の P0-1〜P0-9・P1-1〜P1-11 を反映=identity/revision 分離・履歴保持ledger・
チャネル別送達保証・AT-1 permit 増分・ActionGate・3値論理・分冊化)。本書は歴史参照用。

**v0.3 が正準**(v0.1/v0.2 は歴史参照)。本書は単独で完結する(v0.1/v0.2 への「同一」参照を廃し、
規範部分を全て取り込んだ=review P1-7 対応)。

v0.2 からの主変更:
1. **レビュー `sourcevault_routine_attention_spec_v0_2_review_v1.md` の P0-1〜P0-9 を全て解消、
   P1-1〜P1-10 を具体化**(§0.1 の対応表参照)。
2. **可視化層(§8)を新設**: ガント/タイムライン・工程ビュー(Petri net / BPMN 風スイムレーン)・
   負荷ヒートマップ・Plan diff。全ての図形要素からワンクリックで「メール返信作業」「対象ノートブック」
   「今すぐ実行」等へ到達するハイパーテキスト機構(ActionResolver)。
3. **計画層(§7)を新設**: 会議・講演の準備期間見積(PreparationSpec→派生 PrepTask)、
   日次容量モデルによる todo の分散配置(procrastination 予防)、**計画は使い捨て**を原則とする
   auto-heal リスケジューリング、集中作業スロット確保(FocusRequest)。

親仕様:
- `sourcevault_cane_knowledge_home_mining_spec_v0_7.md`(Cane 本体。I-番号 invariant)
- `sourcevault_auto_trigger_scheduler_spec_v0_1.md`(AutoTrigger。「AT §n」と表記)

status: draft(r0)。実装済みは §3.2 の R0(NBAccess カレンダー API、headless 56/56 green)のみ。
R0 の occurrence 識別追補(R0b)が本仕様で必要になった(§3.2.1)。

---

## 0. 結論

- 中核は 4 層: **ScheduleFabric(事実)→ 忘却検知(判定)→ AttentionContext(注意)→ Plan(計画)**。
  すべて observe/propose のみで実行権限ゼロ(I-16)。実行は AutoTrigger、単発責務は Commitment(1E)、
  統計検知は anomaly(1H-A)、スケジュール事実の取得は NBAccess に委譲。
- **義務(Obligation)は occurrence 単位が一級市民**。安定 ID(ObligationKey/OccurrenceKey)を持ち、
  状態は 3 軸(Temporal / Fulfillment / Attention)に分離。Ack/Snooze は注意状態のみを変え、
  履行状態には触れない。
- **通知は durable queue を通る**。会議中(NBCalendarBusyQ)は保留し会議後に collapse して flush。
  貫通可否は通知 envelope(Stage/Urgency/MeetingBypass/QuietHoursBypass)で会議ゲート・静音ゲート
  独立に判定。crash/再起動を跨いで通知を失わない。
- **計画(Plan)は契約(Contract)と別物で、使い捨て**。「予定は遅延変更されるのが常」を前提に、
  日次 replan で未消化分が自動的に転がり、owner の pin と締切制約だけが硬い。集中スロット確保は
  「Movable な計画チャンクを制約内で後送 → 影響一覧を diff 提示 → 1 クリック承認」。
- **procrastination 予防は 3 点セット**: (a) 準備期間の見積り(PreparationSpec)で会議・講演から
  PrepTask を前倒し生成、(b) 容量モデルで特定日への集中を検出し前倒し分散を提案、
  (c) LatestSafeStart(これ以降に始めると間に合わない日)と slack を常時計算し、余裕枯渇を段階通知。
- **可視化はすべて「クリックしたら作業が始まる」**: 図中のあらゆる要素が OccurrenceKey を持ち、
  ActionResolver 経由で対象(メールスレッド/ノートブック/実行/レビュー UI)を開く。

### 0.1 レビュー対応表(P0/P1 → 本書の節)

| 指摘 | 対応節 | 要点 |
|---|---|---|
| P0-1 通知貫通の矛盾 | §5.2 | envelope 化。会議ゲートと静音ゲートを独立判定。PierceKinds 廃止 |
| P0-2 occurrence 安定 ID | §2.2, §3.2.1 | ObligationKey/OccurrenceKey 必須化+SEQUENCE reconcile。NBAccess に R0b 追補 |
| P0-3 State 混在 | §2.3 | Temporal/Fulfillment/Attention の 3 軸分離 |
| P0-4 履行意味論 | §2.4 | FulfillmentMode 3 種+occurrence 毎 DueAtUTC/GraceUntilUTC。GraceFactor 廃止 |
| P0-5 defer queue 非永続 | §5.3 | durable queue 状態機械(冪等キー/lease/crash 復旧/連続会議/最大保留) |
| P0-6 ソース鮮度 | §3.4, §5.5 | FreshnessState 伝播+coverage degradation 通知+snapshot TTL |
| P0-7 自動化の権限境界 | §9.3 | 実書き込みは owner がテンプレートセルを自評価。provenance 4 фィールド |
| P0-8 Completed=履行の同一視 | §2.5 | EvidenceQuality 3 段+契約が最低 quality を宣言 |
| P0-9 $onWork 非評価読み | §3.3 | HoldComplete 構造読み+whitelist+サイズ上限+失敗分離+cache 鍵強化 |
| P1-1 AllDayBusy 推論 | §4.2 | CalendarRole/AvailabilityClass。単なる AllDay+Busy を Away 扱いしない |
| P1-2 TZ/DST/snapshot | §2.6 | 永続は UTC、日付意味論は LocalDate+TimeZone、Fabric に AsOfUTC |
| P1-3 mail Commitment 過剰供給 | §6 | Candidate→Open 昇格制+thread obligation |
| P1-4 定型度と自動化可否の混同 | §9.1 | AutomationEligibility gate を FormulaicScore の前置に。slot は AllowedWindows 内 |
| P1-5 stream 意味論 | §4.3 | occurrence 毎 1 回計数+OverdueContractSeconds+SourceUnavailable 分離 |
| P1-6 Board/queue の増分脱落 | §12 | R1〜R4 を依存順に再編。Board は R3 で明示 |
| P1-7 v0.1 参照依存 | 全体 | 本書を単独完結化 |
| P1-8 Fabric 出力の privacy | §3.5 | Fabric 自身を privacy boundary に。ActionRef は owner-local 遅延解決 |
| P1-9 一律 TTL/receipt | §10 | risk 別 ladder |
| P1-10 通知チャネル障害領域 | §5.6 | DependencyClass。監視対象と同一 failure domain のみの通知を禁止 |

## 1. 設計原則

1. **実行と注意の分離**: 本層は判定・通知・計画提案のみ。実行(gate/dispatch/run 記録)は AutoTrigger。
2. **スケジュール事実の単一取得点**: カレンダー・$onWork は NBAccess 公開関数のみ
   (アクセスレベルゲートを一点で保証。routine 層は NotebookExtensions 非依存)。
3. **証拠は決定的に**: 履行判定に LLM を使わない(I-15)。event store / watermark / AT runs /
   postcondition / 明示 marker の機械的照合のみ。
4. **shadow-first 段階昇格**: 検知・通知・自動化とも「記録→受動→能動→実行」。初期は最も静か。
5. **AutoTrigger / NBAccess 無改変**(additive 追加のみ)。
6. **認知データ境界**: 停滞・欠席は operational 信号に留め 1D 入力にしない。event/stream に
   カレンダー内容・ノート名・メール本文を書かない(I-13/I-14)。
7. **契約・policy の正本は owner 署名付き**(MAC+OwnerAuthorization。LLM/external は
   Propose→PendingReview→owner 承認のみ)。
8. **計画は使い捨て、契約は不変条件**(新): Contract=「何が満たされるべきか」、Plan=「いつやる
   つもりか」。Plan は決定的に再生成でき、失っても義務は失われない。硬いのは締切と owner pin だけ。
9. **式中心 UI**(新・memory feedback-expression-centric-ui): FocusRequest・PreparationSpec 登録・
   自動化の実書き込み等の入力は「引数入り式テンプレート 1 セル」で提示し owner が評価する。
   フォーム的セル編集を作らない。テンプレートセルの自評価が owner authorization を兼ねる。

## 2. 正準データモデル

### 2.1 ObligationOccurrence(review §5 のモデルを正準採用+計画フィールド追加)

```wl
<|
  "Type" -> "ObligationOccurrence", "SchemaVersion" -> "0.3",
  "ObligationKey" -> "...",              (* 義務/シリーズの安定 ID(§2.2) *)
  "OccurrenceKey" -> "...",              (* 今回分の安定 ID(§2.2) *)
  "Kind" -> "CalendarEvent"|"OnWorkTask"|"Commitment"|"Routine"|"PrepTask",
  "Source" -> <|
    "RefDigest" -> "...",                (* keyed digest(HMAC)。生 UID/path を含まない *)
    "Revision" -> "...",                 (* SEQUENCE / metadata hash / CommitmentRevision *)
    "ObservedAtUTC" -> "...",
    "FreshnessState" -> "Fresh"|"Stale"|"Unavailable"|"Partial" |>,
  "Schedule" -> <|
    "StartUTC" -> _|Missing, "EndUTC" -> _|Missing,         (* CalendarEvent *)
    "DueAtUTC" -> _|Missing, "GraceUntilUTC" -> _|Missing,  (* 期限系(§2.4) *)
    "TimeZone" -> "Asia/Tokyo", "AllDay" -> _ |>,
  "Fulfillment" -> <|
    "Mode" -> "LatestState"|"EachOccurrence"|"AnyWithinWindow",
    "State" -> "Unknown"|"Unfulfilled"|"Satisfied"|"Waived"|"Cancelled",
    "EvidenceQuality" -> "AttemptObserved"|"ExecutionSucceeded"|"OutcomeSatisfied"|Missing,
    "EvidenceAtUTC" -> _|Missing |>,
  "Attention" -> <|
    "EpisodeId" -> "...",
    "State" -> "Eligible"|"Deferred"|"Snoozed"|"Acknowledged"|"Delivered",
    "NextEligibleAtUTC" -> _|Missing |>,
  (* --- 計画層(§7)用 --- *)
  "Effort" -> _Quantity|Missing,         (* 見積り工数 *)
  "Movable" -> True|False,               (* 計画上後送可能か(締切内で) *)
  "DependsOn" -> {___String},            (* 先行 OccurrenceKey(工程ビュー/計画順序) *)
  "ParentKey" -> _|Missing,              (* PrepTask → 親イベント *)
  "Importance" -> "Low"|"Normal"|"High"|"Mandatory",
  "ActionHints" -> <|...|>               (* ActionResolver 用(owner-local のみ。§3.5) *)
|>
```

Fabric はこれらを合成する read-only view(独自 store なし)。attention queue(§5.3)と
fulfillment ledger(§2.7)は別 store。

### 2.2 ObligationKey / OccurrenceKey の生成規則(P0-2)

すべて keyed digest(HMAC。鍵管理は anomaly MAC と同方式)で、生 ID を出力に含めない:

| Kind | ObligationKey | OccurrenceKey |
|---|---|---|
| CalendarEvent | `cal:` + HMAC(UID) | ObligationKey + `:` + **元の開始時刻**(override は RECURRENCE-ID、通常展開は展開時の DTSTART)の UTC ISO |
| Routine | `rtn:` + RoutineId | ObligationKey + `:` + 期待 window 開始 UTC |
| Commitment | `cmt:` + CommitmentId | ObligationKey + `:` + Revision |
| OnWorkTask | `nb:` + HMAC(正準パス) | ObligationKey + `:` + HMAC(Deadline,NextReview,Status) |
| PrepTask | `prep:` + 親 OccurrenceKey | ObligationKey + `:` + chunk 序数 |

- **移動後の Start は属性であり ID にしない**。会議が動いても OccurrenceKey は不変
  → pending 通知・履行記録・pin が追随する。
- reconcile 規則: カレンダー adapter は SEQUENCE/DTSTAMP の増加・STATUS:CANCELLED・
  RECURRENCE-ID 変更を検出し、当該 OccurrenceKey の pending 通知を `Superseded`(時刻変更=
  新 envelope を再生成)または `Cancelled` にする。Revision 不変なら何もしない(冪等)。

### 2.3 状態 3 軸(P0-3)

- `TemporalState`(導出値・保存しない): `Upcoming | DueSoon | Overdue | Past`。
- `FulfillmentState`: `Unknown | Unfulfilled | Satisfied | Waived | Cancelled`。
  **遷移規則: Satisfied へは evidence(§2.5 の最低 quality 充足)または owner 明示 waive
  (→Waived)のみ。Ack/Snooze では絶対に遷移しない。**
- `AttentionState`: `Eligible | Deferred | Snoozed | Acknowledged | Delivered`。
  Snooze は `NextEligibleAtUTC` 付き。解除時に Fulfillment が依然 Unfulfilled なら
  **同一 EpisodeId のまま** Eligible に戻る(新規 episode を切らない=重複計数防止。
  episode が変わるのは occurrence が変わるか owner が明示 reopen したときのみ)。

### 2.4 FulfillmentMode と期限(P0-4)

- `LatestState`: 最新の 1 回の確認で過去未実行分も解消(例: IMAP 新着確認)。
- `EachOccurrence`: 各 occurrence が独立義務(例: 日報・出席・PrepTask)。
- `AnyWithinWindow`: 定義 window 内に 1 回あればよい(例: 週次レビュー=週内いつでも)。

occurrence 生成時に `DueAtUTC` と `GraceUntilUTC` を**具体的な時刻として確定**する
(判定時に都度計算しない)。生成は契約の Cadence(AT §4 DSL)+ `Grace`(明示 duration。
**GraceFactor は廃止**)+ CalendarPolicy(§4.2)から決定的に行い、月末・営業日補正・DST を
生成時に解決する。AT `NextFire` は strictly-after/horizon の契約差があるため、
**due 生成の正準関数は routine 層の純関数**とし、AT 関数は Cadence DSL の解釈(FireTimes 列挙)
にのみ使う。

### 2.5 EvidenceQuality(P0-8)

- `AttemptObserved`: 起動・確認操作の痕跡(watermark 前進、ClaudeEval 実行 event、ManualMark)。
- `ExecutionSucceeded`: 実行基盤上の成功(AT runs.jsonl Completed、workflow 正常終了)。
- `OutcomeSatisfied`: 契約固有の決定的 postcondition 成立(例: 「maildb 上で当該 thread に
  owner 返信が存在」「対象ファイルの mtime が window 内」「watermark 前進かつ処理件数>0」)。

契約は `MinimumEvidenceQuality` を宣言する。**確認型義務(CheckPerformed)のみ
Attempt/Execution で充足可。送信・同期・更新などの outcome 義務は OutcomeSatisfied 必須**。
EvidenceSpec(§2.8)に postcondition atom を追加してこれを表現する。

### 2.6 時刻の正準化(P1-2)

- 永続時刻はすべて UTC ISO。日付意味論(全日・営業日)は `LocalDate + TimeZone` を併記。
- 契約に正準 `TimeZone` を必須化(既定 owner 既定値)。DST の不存在時刻は後方シフト、
  重複時刻は最初の出現を採る(固定 policy として明記)。
- Fabric の返り値に `AsOfUTC` と全 source の `Revision` を付け、**tick と Board と全 View が
  同一 snapshot で同一判定**になることを保証する(View は snapshot を受け取って描くだけ)。

### 2.7 fulfillment ledger(新規 store)

`<LocalState>/routine/fulfillment/`(機械ローカル・append-only JSONL+compaction)。
occurrence 毎の Fulfillment 遷移と evidence 参照(RefDigest のみ)を記録。
staleness event(§4)はこの ledger から冪等に導出(occurrence 毎 1 回=受入 17)。

### 2.8 RoutineContract(正準 schema)

```wl
<|
  "Type" -> "RoutineContract", "SchemaVersion" -> "0.3",
  "RoutineId" -> "routine-XXXXXXXXXXXX",
  "Name" -> _String, "Description" -> _String,
  "Enabled" -> True|False,
  "Owner" -> <|"Mode" -> "OwnerMachine", "OwnerMachineTag" -> Automatic|>,
  "Cadence" -> <|AT §4 Schedule DSL|>,
  "TimeZone" -> "Asia/Tokyo",
  "Grace" -> _Quantity,                          (* 例 Quantity[12,"Hours"] *)
  "FulfillmentMode" -> "LatestState"|"EachOccurrence"|"AnyWithinWindow",
  "MinimumEvidenceQuality" -> "AttemptObserved"|"ExecutionSucceeded"|"OutcomeSatisfied",
  "CalendarPolicy" -> <|"SkipOn" -> {"Away"},    (* AvailabilityClass(§4.2) *)
    "SkipMode" -> "Skip"|"ShiftEarlier"|"ShiftLater"|>,
  "EvidenceSpec" -> <|boolean node + atom(§2.9)|>,
  "Importance" -> "Low"|"Normal"|"High",
  "EscalationPolicy" -> <|"Board"->True,"Badge"->False,"Digest"->False,"Mail"->False|>,
  "ActionRef" -> Missing["None"] |
    <|"Kind"->"WorkflowRoute"|"PromptRoute", "TargetId"->_, "TargetURI"->_|>,
  "Effort" -> _Quantity|Missing, "Movable" -> True|False,
  "Automation" -> <|
    "State" -> "Manual"|"Proposed"|"Supervised"|"Unattended",
    "TriggerId" -> _|Missing, "ProposalId" -> _|Missing,
    "ApprovedBy" -> _|Missing, "AuthorizationId" -> _|Missing,
    "SupervisedSince" -> _|Missing, "SupervisedRunTarget" -> 10,
    "RecertifyEvery" -> _Quantity|>,             (* risk 別既定は §10 *)
  "Signature" -> _, "CreatedAt" -> _, "UpdatedAt" -> _, "EnabledAudit" -> {}
|>
```

保存: 契約=`<VaultRoot>/routine/contracts/<RoutineId>.wxf`(共有)、
state/queue/plan=`<LocalState>/routine/`(OwnerMachine ローカル)。

### 2.9 EvidenceSpec atom(正準)

boolean node `AllOf|AnyOf|Not` +:

```wl
<|"Atom"->"CaneEvent", "EventClass"->_, "Match"-><|...|>|>          (* observe-only event store *)
<|"Atom"->"PipelineWatermark", "Pipeline"->_, "AdvancedWithin"->_,
  "MinItems"->0|>                                                    (* MinItems>0 で outcome 化 *)
<|"Atom"->"AutoTriggerRun", "TriggerId"->_, "Status"->"Completed"|>  (* Execution 止まり *)
<|"Atom"->"SourceEvent", ...|>
<|"Atom"->"ManualMark", ...|>                                        (* SourceVaultObligationMark *)
<|"Atom"->"OnWorkTask", "RefDigest"->_, "StatusIn"->{"Done"}|>
<|"Atom"->"MailThreadReplied", "ThreadRefDigest"->_|>                (* postcondition(P0-8) *)
<|"Atom"->"FileState", "PathRefDigest"->_, "MTimeWithin"->_|>        (* postcondition *)
```

各 atom は quality を宣言する(CaneEvent/ManualMark=Attempt、AutoTriggerRun=Execution、
MailThreadReplied/FileState/MinItems 付き watermark=Outcome)。合成式の quality は
「成立した枝の最大 quality」。

## 3. ScheduleFabric(事実層)

### 3.1 構成

source adapter(calendar / onwork / commitment / routine+prep)→ occurrence 正規化(§2)→
reconcile(§2.2)→ snapshot(AsOfUTC)→ 消費者(検知 tick / Board / 各 View / Plan)。

### 3.2 カレンダー adapter(R0 実装済み+R0b 追補)

R0(実装済み・2026-07-15): `NBCalendarEvents / NBCalendarFreeBusy / NBCalendarBusyQ /
NBICSParseEvents / NBICSEventOccurrences`。RRULE 展開修正(単一オフセット・INTERVAL 無視・
月 30.437 日近似・DAILY/COUNT/UNTIL/BYDAY/BYMONTHDAY/EXDATE/RECURRENCE-ID/全日/DURATION/
折返し/escape/TZID)。アクセスレベル別フィールド(0.5=free/busy+Mandatory / 0.7=+Summary /
1.0=全部)。`NBAccess_calendar_test.wls` 56/56 green。

#### 3.2.1 R0b: occurrence 識別追補(P0-2 のため必要・未実装)

NBAccess へ additive に追加する:
- occurrence 出力に `"OriginalStart"`(override は RECURRENCE-ID、通常展開は自身の展開時刻)を
  **全アクセスレベルで**含める(時刻メタデータであり内容ではない)。
- `SEQUENCE` / `DTSTAMP` を parse し、1.0 出力と `"Revision"`(全レベル。SEQUENCE+DTSTAMP の
  digest)に反映。
- 既存テストへ: 移動 override の OriginalStart が元時刻を保つ/Revision が SEQUENCE 更新で変わる。

### 3.3 $onWork adapter: `NBOnWorkTasks`(P0-9 の非評価契約)

- **notebook を評価しない**。`Import[file, "Notebook"]` で構造として読み、Initialization 相当
  セルの内容文字列を `ToExpression[..., StandardForm, HoldComplete]` で held のまま構造検査する。
  許可するのは「whitelist キー(Title/Status/Deadline/NextReview/EventDate/Keywords/Effort/
  Movable/DependsOn)→ リテラル値(String/Integer/Real/リテラル引数の DateObject・Quantity/
  String リスト)」の Association のみ。それ以外の式は**評価せず破棄**し `Partial` を立てる。
- 上限: ファイル >20MB は skip(Partial)、セルテキスト >64KB skip、深さ制限。symlink・
  $onWork 外への path は拒否。1 ファイルの失敗は分離し scan は継続(受入 15)。
- cache: 鍵=(正準パス digest, size, mtime)、疑義時(size/mtime 同一で Dropbox conflict marker
  等)は content hash で確認。atomic write。削除検知(cache にあるがファイル無し→prune)。
- NextReview の Quantity 形式は「ModificationDate + offset」で解決(NotebookExtensions と同義。
  一致回帰テストを R2 に含める)。
- アクセスレベル: 0.5=Due/State/RefDigest のみ / 0.7=+Title/Keywords / 1.0=+パス。

### 3.4 ソース鮮度(P0-6)

全 adapter の返り値: `<|"Items"->{...}, "ObservedAtUTC"->_, "SourceVersion"->_,
"FreshnessState"->"Fresh"|"Stale"|"Unavailable"|"Partial", "Completeness"->0..1|>`。

- 閾値は AttentionPolicy(§5.4)に持つ(calendar 既定: Fresh<30min<Stale<24h<Unavailable)。
- **calendar が Stale/Unavailable のとき**: 最後の成功 snapshot(`<LocalState>/routine/snapshots/`、
  TTL 付き)を `Stale` フラグ付きで使い続け、**「Mandatory 会議リマインダーの coverage が低下」
  を system health 通知として 1 回だけ**(episode 化・hysteresis)発する(受入 8)。これは
  routine overdue とは別 Kind(`SystemHealth`)であり、§5.6 の独立チャネル規則に従う。
- $onWork の scan 失敗は「タスクなし」と区別して Board に表示(受入 18)。
- FreshnessState は occurrence に伝播し(§2.1 Source)、Stale 由来の判定は staleness event に
  `SourceFreshness` を併記(検知の確度を下流が知れる)。

### 3.5 Fabric 自身の privacy projection(P1-8)

`SourceVaultScheduleFabric[from, to, opts]` に `PrivacySpec` を持たせ、**Fabric 出力を
privacy boundary にする**:
- <0.7: `Label`/`ActionHints` を含めない。`Ref` は keyed digest(HMAC)のみ。時刻・Kind・
  状態・Importance フラグだけ(受入 16)。
- `ActionRef`/パス/URI は**出力に載せず**、owner-local UI の描画時に ActionResolver(§8.1)が
  OccurrenceKey から遅延解決する。event/LLM payload へ入る経路を作らない。
- 通常 hash でなく HMAC を使う(入力空間が小さい UID/パスの照合攻撃対策)。

## 4. 忘却検知(判定層)

### 4.1 決定的判定(occurrence ベース)

tick(service 弱結合・既定 off・anomaly tick と同型)と Board 描画が**同一の純関数**を同一
snapshot に適用する:
- occurrence 生成(§2.4)→ evidence 照合(§2.9。watermark 増分)→ Fulfillment 更新(ledger)
  → `GraceUntilUTC` 超過かつ Unfulfilled → staleness event(occurrence 毎 1 回・冪等)
  → 注意層へ envelope 発行。
- `LatestState` 契約は最新 evidence で全過去 occurrence を Satisfied(quality 充足時)に、
  `EachOccurrence` は各 occurrence 独立に判定(受入 10)。
- 日付比較は AbsoluteTime 数値(罠22 回避)。

### 4.2 CalendarRole / AvailabilityClass(P1-1)

- AttentionPolicy にカレンダー分類規則を持つ: `CalendarRole`(purpose 別: Availability /
  Holiday / Meetings。ソース(購読カレンダー)単位または category 指定)と
  `AvailabilityClass`(`Working | Away | Unknown`)。
- **Away の判定は明示シグナルのみ**: OOO カテゴリ・owner 指定 pattern・Holiday role の全日
  イベント。**単なる AllDay+Busy を Away とみなさない**(受入 7)。
- 契約の `CalendarPolicy.SkipOn`(既定 {"Away"})に該当する日の occurrence は
  `SkipMode` に従い: `Skip`=Waived("SkippedByPolicy")/ `ShiftEarlier|ShiftLater`=
  DueAtUTC を直前/直後の Working 日へ移して生成。

### 4.3 統計層(P1-5)

anomaly(1H-A)への供給 stream を occurrence 意味論で再定義:
- `RoutineFulfillmentRate`: 日次。分母=その日 `GraceUntilUTC` を迎えた occurrence 数、
  分子=そのうち Satisfied。**occurrence 毎に 1 回だけ計数**。
- `OverdueContractSeconds`: 日次 snapshot(持続 overdue の総秒数)。翌日 0 に見える問題を排除。
- `SourceUnavailableRate`: 鮮度劣化を owner 非実行と分離(P0-6/P1-5)。
- cohort 化: per-routine(既定)+ 同 cadence/Importance cohort の集約(個別異常を埋没させない)。
- 実データ無し stream は出力しない(I-15)。分母補正(§4.2)は数値のみ(理由テキスト無し)。

## 5. AttentionContext(注意層)

### 5.1 チャネルと段階

段 0=event 記録(常時)/ 段 1=Board(pull・ゲート対象外)/ 段 2=palette badge+ロード時 digest /
段 3=日次 digest / 段 4=メール(AT §3.6 トラストクラス相乗り・opt-in)。
alarm fatigue 対策: episode 単位 hysteresis・collapse・rate limit・静音帯。

### 5.2 通知 envelope(P0-1)

```wl
<|
  "EnvelopeId" -> _,                     (* 冪等キー=(OccurrenceKey,EpisodeId,Stage,Channel) *)
  "OccurrenceKey" -> _, "EpisodeId" -> _,
  "Kind" -> "OverdueNotice"|"MandatoryMeetingReminder"|"PrepNudge"|"SlackLow"|
            "AutomationFailure"|"SystemHealth"|"ReceiptDigest"|...,
  "Stage" -> "LeadDay"|"Lead2Hours"|"Lead15Minutes"|"Immediate"|"Digest",
  "Urgency" -> "Info"|"Normal"|"High"|"Critical",
  "Channel" -> "Badge"|"Digest"|"Mail",
  "MeetingBypass" -> True|False,         (* 会議ゲート貫通 *)
  "QuietHoursBypass" -> True|False       (* 静音ゲート貫通(独立判定) *)
|>
```

- 会議ゲートと静音ゲートは**独立に**評価(受入 4)。
- 既定 BypassRules(AttentionPolicy で owner 変更可):
  MandatoryMeetingReminder は **Lead15Minutes 段のみ** MeetingBypass=True(前日・2h 前は False。
  受入 3)。QuietHoursBypass は Urgency=Critical かつ owner 明示のもののみ True。
  AutomationFailure(High)は MeetingBypass=True/QuietHoursBypass=False 既定。
- payload に内容を含めない(obligation 参照+projection パラメータのみ)。

### 5.3 durable attention queue(P0-5)

`<LocalState>/routine/attention/queue/<EnvelopeId>.json`(1 record 1 file・atomic write)。

- 状態機械: `Pending → Deferred → Claimed → Delivered | Superseded | Expired`。
- 発行: 冪等(同一 EnvelopeId は再発行しない)。
- defer: busy/quiet で `Deferred`(`DeferredUntil`=会議終了見込み+FlushAfterMinutes)。
- flush: `Claimed`(lease=ClaimedAtUTC+TTL)→ 提示成功で `Delivered`。**flush 直前に
  busy/quiet/source Revision を再評価**: 連続会議なら再 defer(受入 6)、occurrence が
  変更/取消済みなら `Superseded`。crash 復旧: lease 失効した Claimed → Deferred へ戻す
  (重複防止は EnvelopeId 冪等で担保。受入 5)。
- `MaxDeferSeconds`(Kind 別。時限性のある reminder は超過で `Expired`+Board 常設表示へ
  fallback。時限性のない notice は次の digest へ合流)。
- collapse: flush 時に同時 Deferred を 1 digest に束ねる(個々の record は Delivered)。
- OwnerMachine 移管: queue は導出状態なので移管しない。旧機械は `Superseded("OwnerMoved")`、
  新機械が obligations から再生成する。

### 5.4 AttentionPolicy(owner 署名付き・単一)

```wl
<|"Type"->"AttentionPolicy","SchemaVersion"->"0.3",
  "MeetingGate"-><|"Enabled"->True,"FlushAfterMeetingMinutes"->5,
    "MandatoryLeadStages"->{"LeadDay","Lead2Hours","Lead15Minutes"}|>,
  "QuietHours"->_|Missing,
  "BypassRules"->{<|"Kind"->_,"Stage"->_,"MeetingBypass"->_,"QuietHoursBypass"->_|>...},
  "Freshness"-><|"CalendarStaleAfter"->Quantity[30,"Minutes"],
    "CalendarUnavailableAfter"->Quantity[24,"Hours"],"SnapshotTTL"->Quantity[7,"Days"]|>,
  "CalendarRoles"->{...}, "AvailabilityRules"->{...},        (* §4.2 *)
  "MandatoryPatterns"->{...},                                 (* 論点(g): 正本はここ。ロード時に
                                                                 $NBCalendarMandatoryPatterns へ反映 *)
  "Channels"->{<|"Channel"->_,"DependencyClass"->_,"Enabled"->_|>...},
  "Signature"->_, "UpdatedAt"->_, "EnabledAudit"->{}|>
```

### 5.5 coverage degradation(P0-6)

calendar Stale/Unavailable 中は「必須会議 reminder の coverage 低下」を SystemHealth envelope
(1 episode 1 回)で通知し、Board に常設バナー表示。復旧で episode 終了。

### 5.6 チャネル障害領域(P1-10)

Channels に `DependencyClass`(例: "Mail","Calendar","FE")を持ち、**ソース X の障害通知を
X と同じ failure domain のチャネルだけに送ることを禁止**(検証は policy 保存時)。Board/badge は
常に有効。High の SystemHealth は独立経路(FE local)を必ず含む。

## 6. Commitment 供給(P1-3)

- detector(maildb: HasDeadline / オーナー宛 / response-required)は **`Candidate`** を作る
  (Open にしない)。
- 昇格: owner 署名 rule(送信者/ドメイン・response-required・deadline 有無・**thread に owner
  返信が無いことの決定的照合**)を満たすもののみ。rule 毎に自動昇格を owner が個別承認
  (実績と FalseAlarm 率を receipt に表示し、率が閾値超の rule は自動昇格を停止提案)。
- **thread obligation**: ObligationKey=thread digest。同一スレッドの複数メールで義務は 1 つ。
  owner 返信の出現(MailThreadReplied atom)で OutcomeSatisfied。
- Candidate は Board の専用セクションに表示(1 クリックで Open/Dismiss/rule 化)。

## 7. Plan(計画層・新設): 準備見積・分散・リスケジューリング

### 7.1 PreparationSpec と派生 PrepTask(準備期間の見積り)

owner 署名 template 集(AttentionPolicy と同格の signed config):

```wl
<|"TemplateId"->_,
  "Match"-><|"Kind"->"CalendarEvent","MandatoryOnly"->False,
    "Patterns"->{"講演","invited talk"},"Categories"->{...}|>,   (* 照合は 0.7 情報で *)
  "Prep"-><|"Effort"->Quantity[8,"Hours"],"WindowDays"->14,
    "ChunkMax"->Quantity[2,"Hours"],"MinLeadDays"->1,
    "Checklist"->{"スライド構成","スライド作成","通し練習"}|>|>
```

- 会議・講演 occurrence に match すると **PrepTask occurrence 列を派生**(§2.2 の key 規則。
  EachOccurrence・Movable=True・Effort 付き・Due=イベント開始−MinLeadDays・ParentKey=イベント)。
- 個別イベントへの override(工数増減・不要化)は Board の 1 クリック+式テンプレート。
- 見積りの改善: 過去の同 template の実績工数(plan 実行記録・ManualMark 時刻)の中央値で
  template 既定値の更新を**提案**(自動変更しない)。v0.3 では optional(論点 j)。
- PrepTask の履行は ManualMark / リンクした OnWorkTask の Status=Done / checklist 全消化。

### 7.2 容量モデルと分散配置(procrastination 予防)

- CapacityModel(owner 署名): 曜日別の可処分時間(例: 平日 4h)。実効容量 =
  可処分 − カレンダー busy(FreeBusy 0.5)− FocusSlot 予約 − Away 日は 0。
- **配置(純関数)**: 未 Satisfied で Effort を持つ occurrence(PrepTask・OnWorkTask・
  Movable routine)を chunk(≤ChunkMax)に割り、決定的アルゴリズムで日へ割付ける:
  制約=締切(DueAtUTC)・DependsOn 順序・日次容量上限・AllowedWindows。
  目的=**前倒しバイアス**(`FrontLoad`∈[0,1]、既定 0.7: 締切直前でなく早い日から埋める)+
  日次負荷の平準化(特定日への集中排除)。同一入力→同一出力(安定 sort key)。
- **procrastination 指標**(occurrence 毎に常時計算):
  - `LatestSafeStart` = 締切から残工数と実効容量を逆算した「これ以降に始めると間に合わない日」。
  - `Slack` = LatestSafeStart − today。
  - nudge 段階: `PrepWindowOpen`(準備 window 開始を 1 回通知)→ `SlackLow`(Slack<閾値。
    Importance 別閾値)→ `Infeasible`(残容量<残工数。§7.5)。すべて envelope 経由(§5.2)。

### 7.3 Plan は使い捨て(auto-heal リスケジューリング)

- Plan = chunk→日 の割付表。`<LocalState>/routine/plan/current.json`+履歴。
  **義務の正本ではない**ので失われても安全(§1 原則 8)。
- **daily replan tick**(+on-demand): 未消化 chunk は自動的に前へ転がる(受入 25)。
  owner pin(`Pinned->True` の chunk)と締切制約だけが不動(受入 26)。replan は冪等。
- ReplanReport(diff): moved/added/dropped/リスク変化(Slack 悪化した obligation)を列挙。
  変更が閾値未満なら通知せず(silent auto-heal)、Slack 悪化や Infeasible 発生時のみ envelope。

### 7.4 FocusRequest(集中スロット確保)

式テンプレート 1 セル(§1 原則 9)で発行:

```wl
SourceVaultFocusRequest[<|
  "Task" -> "論文改訂",                    (* 既存 obligation 参照 or 新規 ad-hoc *)
  "Hours" -> 12, "By" -> "2026-07-25",
  "SlotGranularity" -> Quantity[3, "Hours"],
  "PreferDays" -> Automatic,               (* 会議の少ない日を自動選択 *)
  "PushMovable" -> True|>]
```

planner の動作(すべて提案→diff 提示→1 クリック承認):
1. カレンダー空き(FreeBusy)×容量から focus slot 候補を確保。
2. `PushMovable` なら、衝突する Movable chunk を**各自の GraceUntil/Due を破らない範囲で**後送。
3. どうしても入らない場合は**衝突一覧**を提示(受入 22): 後送不能な obligation・締切違反に
   なる obligation を明示し、選択肢(§7.5)を添える。
4. 承認で plan 適用+focus slot をカレンダーへ**書き戻さない**(v0.3 非目標。Board/ガントに
   表示。カレンダー書き戻しは論点 o)。

### 7.5 Infeasibility エスカレーション

残容量不足・focus 衝突時に決定的な選択肢メニューを生成(全て 1 クリックで着手可能):
(a) 延期候補(Movable+Slack 正の obligation と新提案日)、(b) waive 候補(Importance Low)、
(c) 自動化候補(§9 の eligible な routine を自動化して容量を空ける)、
(d) **締切交渉**: Commitment なら「延期依頼の返信作業を開く」(ActionResolver 経由で
mail 返信導線へ直結)。選択は owner。層は何も自動実行しない。

## 8. 可視化層(FabricView suite・新設)

### 8.1 共通基盤: ActionResolver(ハイパーテキスト機構)

- **core/View 分離**(memory 規則): `SourceVaultScheduleFabric`(データ+AsOf snapshot)を
  各 View(純 renderer)が受け取る。全図形要素は OccurrenceKey を保持。
- `SourceVaultObligationActions[occKey]` → その occurrence で可能なアクション列
  (弱結合 registry。対象パッケージ未ロードなら該当アクション非表示=rule 11)。
  クリック=owner authorization。層は自動実行しない。

| Kind | ワンクリックアクション(盛り込み一覧) |
|---|---|
| Commitment(mail) | **スレッドを開く**(SourceVaultMailView)/ **返信作業を開始**(mailsuggest セッション or 返信 draft 式テンプレートセル挿入→既存 PlanMessageRelease ゲートへ)/ 延期依頼 draft / Candidate→Open / FalseAlarm 報告 / Snooze / waive |
| OnWorkTask | **ノートブックを開く**(NotebookOpen)/ ディレクトリを開く / 「このタスクの focus slot を確保」(§7.4 テンプレート挿入)/ Snooze。(Status/NextReview の書き戻しは論点 n) |
| CalendarEvent | 詳細(レベル相応)/ **PrepTask 一覧へジャンプ** / **準備ノートを作成して開く**($onWork に Initialization メタデータ(Title/Deadline=イベント日/DependsOn)を事前充填した .nb を生成)/ 本文中 URL を開く(1.0・SystemOpen)/ PreparationSpec override |
| Routine | **今すぐ実行**(AT 手動発火=IP-2)/ evidence 履歴 / 契約詳細 / Snooze / waive(今回分) |
| PrepTask | 親イベントへ / **リンク先ノートを開く/作成** / checklist 表示・消化 / ManualMark(完了)/ chunk を今日へ・明日へ(pin) |
| AutomationProposal | レビュー UI を開く / 承認テンプレートセル挿入(§9.3)/ 却下 |
| FocusSlot | 対象タスクを開く / slot 解除 / 延長テンプレート挿入 |
| SystemHealth | 該当 source の診断 view(SensitiveDoctor 系)/ 再取得(Refresh) |

- 実装 idiom: Dataset の Button 列(既存 NotebookExtensions 流)+ Graphics 内は
  `Button`/`EventHandler`/`ClickPane`+全要素 `Tooltip`(レベル相応ラベル)。
- ActionHints(パス・RecordId 等)は owner-local 解決のみ(§3.5)。

### 8.2 ガント/タイムライン: `SourceVaultFabricGanttView[from, to]`

- 行=obligation(Kind/親イベントでグループ化)。描画: 準備 window(淡)/計画 chunk(濃)/
  会議ブロック/Due=◆/GraceUntil=◇/today 線/overdue=赤/FocusSlot=枠。
- ズームプリセット(日/週/月)。バークリック→ActionResolver。バー上の chunk は
  「今日へ/後ろへ」クイック操作(pin 化)。
- 実装: Graphics+Rectangle+EventHandler(簡易版は TimelinePlot fallback)。

### 8.3 工程ビュー(Petri net / BPMN 風): `SourceVaultFabricProcessView[scope]`

- 対象 scope(例: 1 つの講演とその PrepTask 群、1 スレッドの Commitment、1 routine の
  パイプライン)を **Petri net** として描く: place=状態(todo/doing/done/waived)、
  transition=作業ステップ、token=現在状態。依存は DependsOn/ParentKey/thread 連鎖から決定的に
  構成。
- **既存資産再利用**: ClaudeOrchestrator_observability.wl の `plotPetriNetDetail` /
  `checkPetriNetVertices` を adapter(ObligationOccurrence graph → net spec)経由で使う。
  頂点クリック→ActionResolver(EventHandler ラップを adapter 側で付与)。
- **BPMN 風スイムレーン**は同一グラフの別レンダリング(レーン=実行主体: owner / 自動化 /
  外部相手)。往復(メール返信待ち等)が視覚的に分かる。記法は BPMN 完全準拠を目標にしない
  (エンジンを作らない。可視化のみ)。
- done の token 到達履歴(fulfillment ledger)で「済んだ工程」を淡色残置=達成の可視化。

### 8.4 負荷ヒートマップ: `SourceVaultFabricLoadView[month|week]`

- カレンダー格子。日毎の色=計画負荷/実効容量。過負荷日・Away 日・focus 日を区別表示。
  **todo が特定日に集中していることを一目で示す**(procrastination 予防の主計器)。
- 日クリック→その日の chunk/会議一覧(各行から ActionResolver)。「この日を空けたい」ボタン→
  FocusRequest テンプレート挿入。

### 8.5 Plan diff ビュー: `SourceVaultPlanDiffView[report]`

replan/FocusRequest の前後比較: 移動 chunk 表+ミニガント(旧=ghost、新=実線)+Slack 悪化
リスト。承認/却下/個別 pin ボタン。

### 8.6 Board v2(既定 pull UI・P1-6)

- セクション: Overdue / DueSoon / 会議(next 48h・Mandatory 強調)/ PrepTask(今日の chunk)/
  Candidate(Commitment)/ 自動化(supervised 結果・receipt・失効予告)/ SystemHealth。
- 3 軸状態を正しく表示・操作(Ack/Snooze/waive は AttentionState/FulfillmentState を
  それぞれ正しく遷移。受入 9)。source unavailable と「obligation なし」を区別表示(受入 18)。
- 他 View への入口ボタン(ガント/工程/負荷/diff)。

### 8.7 入力 UI 原則

FocusRequest・PreparationSpec・契約登録・自動化承認は**引数入り式テンプレート 1 セル**を
Board/View が挿入し owner が編集・評価する(フォーム UI を作らない)。

## 9. 自動化提案

### 9.1 AutomationEligibility gate(P1-4。FormulaicScore の前置)

チェック(全て決定的): ActionRef 実在+AT `AutoRunCapability` が HeadlessAsync 系 /
risk class(Guard taxonomy)/ 可逆性 / **冪等性宣言** / pre/postcondition の有無 /
credential scope / rollback 手段 / テスト実績(runs 成功数)。不合格理由は提案に明記
(rejected reason 方式)。**IP-5(未実行 window 条件)が未配線の間、Unattended は禁止**
(受入 13)。Supervised は「target が冪等かつ同一 window dedup を宣言」した場合のみ。
Supervised の意味は「各 run の結果 digest を owner が事後確認」と定義する(実行前承認では
ない。実行前承認が必要な risk class は自動化対象外)。

### 9.2 提案フロー

eligible → FormulaicScore(trace 類似度・介入回数・失敗率。決定的)→ 閾値+最小標本(10 run)
→ `AutomationProposal`(PendingReview)。提案 slot は **owner 署名 `AllowedWindows` 内**で
busy 率最小を選ぶ(深夜を勝手に選ばない。supervised は owner 対応可能時間を優先)。

### 9.3 承認と権限境界(P0-7)

- routine 層が行うのは **`SourceVaultRegisterAutoTrigger[draft]`(DryRun=検証のみ)まで**。
  **実書き込み(DryRun->False)と Enable は、Board が提示する式テンプレートセルを owner 自身が
  評価する**(§1 原則 9。テンプレート自評価=owner authorization。routine 層に registry 変更
  経路が存在しないことを受入基準化)。
- provenance: `"CreatedBy"->"RoutineAutomationProposal", "ProposalId"->_,
  "ApprovedBy"->"Owner", "AuthorizationId"->_` を TriggerSpec と契約 Automation の両方に記録。
- AT 側 mutation boundary での permit 検証は AT 仕様への additive 提案として別増分(論点 l)。

## 10. automation complacency(risk-based・P1-9)

| Importance | TTL(ExpiresAt) | receipt 頻度 | 失効時 |
|---|---|---|---|
| High | 30 日 | 週次+sampled outcome audit(runs の postcondition 抜き取り確認) | 失効 7 日前から envelope(Critical)。失効=自動 Disable→義務は手動へ戻り overdue 検知が拾う |
| Normal | 90 日 | 隔週 | 失効 7 日前 envelope(Normal) |
| Low | 180 日 | 月次(例外中心) | 失効時 Board のみ |

失効予告は MeetingBypass=False だが Board 常設表示があるため会議ゲートで消えない(P1-9 の
「失効に気づかない」対策)。green-but-dead は契約残置(§1 原則 8)+ §2.5 の quality で検知。

## 11. AutoTrigger / NBAccess 統合点(IP 表)

| IP | 内容 | 状態 |
|---|---|---|
| IP-1 | Cadence DSL 解釈に AT 純関数(ScheduleMatch/FireTimes)。due の正準は routine 純関数(§2.4) | 仕様確定 |
| IP-2 | Board/View の「今すぐ実行」→ AT 手動発火 | 仕様確定 |
| IP-3 | TriggerSpec draft は DryRun まで。実書き込みは owner テンプレート評価(§9.3) | v0.3 で強化 |
| IP-4 | AT runs.jsonl を evidence(Execution quality)として照合 | 仕様確定 |
| IP-5 | 未実行 window 条件(SourceVaultPredicate atom)。**未配線の間 Unattended 禁止** | AT 側待ち |
| IP-6 | ExpiresAt/EnabledAudit で TTL 再認証 | 仕様確定 |
| IP-7 | カレンダー(NBCalendarEvents/FreeBusy/BusyQ) | **R0 実装済み+R0b 追補要** |
| IP-8 | $onWork(NBOnWorkTasks・非評価契約) | R2 |
| IP-9 | AT NextFire preview の表示利用(ガント/工程ビュー) | R5 |
| IP-10 | ActionResolver → maildb/mailsuggest/NotebookOpen/claudecode の弱結合 | R3〜 |

## 12. 増分実装計画(P1-6 の依存順に再編)

| Inc | 内容 | 依存 |
|---|---|---|
| R0 | カレンダー API(**実装済み**・56/56) | — |
| R0b | occurrence 識別追補(OriginalStart/SEQUENCE/Revision。§3.2.1) | R0 |
| R1 | 正準 schema+純関数(occurrence 生成/due・grace/3 軸状態機械/EvidenceQuality 合成/LatestSafeStart・Slack)。IO なし・全て headless | — |
| R2 | source adapter 4 種+freshness+held $onWork parser+reconcile+fulfillment ledger | R0b,R1 |
| R3 | **Board v2**+Ack/Snooze/waive 遷移+ActionResolver v1(mail/notebook/AT 発火/Candidate 操作) | R2 |
| R4 | AttentionPolicy+**durable queue**+会議/静音ゲート+Mandatory ladder+coverage degradation+attention tick 結線 | R3 |
| R5 | 可視化 suite(ガント→負荷ヒートマップ→工程 Petri(plotPetriNetDetail adapter)→diff 骨格) | R3 |
| R6 | 計画層(PreparationSpec/PrepTask 派生/CapacityModel/配置+replan/FocusRequest/diff 適用/nudge 3 段) | R4,R5 |
| R7 | 統計 stream(§4.3)を anomaly 既定供給へ | R2 |
| R8 | 自動化(eligibility gate/提案/承認テンプレート/supervised ledger/risk-based receipt・TTL) | R4 |
| R9 | mail チャネル(AT §3.6 実装が前提) | R4 |

最小実用: **R0〜R4 = 「通知を失わず・会議を邪魔しない忘却注意」**。+R5 で可視化、
+R6 で procrastination 予防とリスケジューリング。

## 13. 受入基準

review §6 の 18 項を全て採用(1〜18)。追加:

19. 各 View の全図形要素クリックが Kind 相応の正しい対象を開く(mail thread / notebook /
    AT 発火 / レビュー UI)。対象パッケージ未ロード時はアクション非表示で View 自体は動く。
20. tick・Board・全 View が同一 AsOfUTC snapshot から同一判定・同一表示を導く。
21. replan は冪等(同一入力→同一 plan)で、pin と締切制約を破らない。
22. FocusRequest は Movable でない chunk・締切違反になる移動を勝手に行わず、衝突一覧として
    提示する。
23. PrepTask chunk が LatestSafeStart より後にしか置けない場合、必ず Infeasible として
    エスカレーションし、静かに諦めない。
24. Plan・可視化の AccessLevel<0.7 出力に Label/パス/URI/生 UID/ActionRef が含まれない。
25. 未消化 chunk は翌 replan で自動的に前送りされる(手動操作不要)。
26. owner pin した chunk は replan・FocusRequest を跨いで日付を維持する(締切違反時のみ
    衝突一覧に載る)。
27. routine 層のコードパスに TriggerSpec の実書き込み(DryRun->False)・Enable が存在しない
    (grep 可能な受入)。
28. 準備 window 開始 nudge(PrepWindowOpen)は occurrence 毎 1 回で、イベント移動時は
    supersede 後に新 window で再評価される。

## 14. 未解決論点

- (a) 停滞の認知層(1D)接続 — 入れない(現状維持)。
- (b) mail チャネル初期スコープ — R9 に隔離(AT §3.6 依存)。
- (c) IP-5 配線時期 — AT 側増分。配線まで Unattended 禁止(§9.1 で仕様化済み)。
- (d) 証拠クロスマシン rollup — OwnerMachine 前提で見送り(queue/plan は導出状態なので
  移管規則のみ §5.3 で定義)。
- (e) schedule 実行 event 化フック — 1G' 同型の非侵襲 recorder 方針を維持。
- (f) 欠席の事後判定 — 導入しない(将来 opt-in+ShadowOnly)。
- (g) Mandatory 分類の正本 — **解決**: AttentionPolicy に持ち、ロード時 auto-apply で
  $NBCalendarMandatoryPatterns へ反映(§5.4)。
- (h) 祝日ソース — CalendarRole=Holiday の購読カレンダー(§4.2)。不足時に祝日表を検討。
- (i)(n) OnWorkTask への書き戻し(Status/NextReview/Done 化)— NBAccess 0.7 書き込みゲート
  準拠の別増分。それまで ActionResolver は「開く」まで。
- (j) 実績からの Effort 見積り更新 — v0.3 では提案表示のみ(自動更新しない)。
- (k) ドラッグ操作 — WL FE では非現実的。クリックベース(今日へ/後ろへ/pin)+式テンプレートで
  代替(§8 で仕様化済み)。
- (l) AT mutation boundary の permit 検証 — AT 仕様への additive 提案として起票する。
- (m) DependsOn メタデータ key($onWork Initialization への追加)— whitelist に含めた(§3.3)。
  既存ノートは無変更で動く(optional key)。
- (o) FocusSlot のカレンダー書き戻し(実カレンダーに blocking 予定を作る)— v0.3 非目標。
  書き戻しは外向き作用なので、やるなら PlanMessageRelease 級の承認ゲートを通す別仕様。
