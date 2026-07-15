# SourceVault ルーチン注意喚起+自動化提案 core 仕様 v0.4

**v0.4 が core の正準**(v0.1〜v0.3 は歴史参照)。review v1(`..._v0_3_review_v1.md`)の
P1-10 に従い**分冊化**した:
- **本書(core)**: obligation/identity/ledger/忘却検知/AttentionContext/ActionGate/自動化境界。
  増分 R0〜R4, R7, AT-1, R8, R9。**本書のみで単独完結**(受入基準は §12 に全文収録=旧 P0-9 解消)。
- **extension**: `sourcevault_routine_planview_ext_spec_v0_1.md`(計画層 Plan+可視化 FabricView。
  旧 R5/R6)。core に依存するが core は extension に依存しない。

v0.3 からの主変更(review v1 対応。対応表は §0.1):
identity と revision の完全分離(immutable StableId+OccurrenceToken / SemanticDigest+
ObservedRevision)、LatestState の履歴保持(ResolutionState)、durable-facts 共有 ledger と
OwnerMachine 移管、チャネル別送達保証、AutoTrigger additive 増分 **AT-1**(one-shot permit /
ExpiresAt 執行 / EnabledAudit)の必須依存化、ActionGate(capability class router)、
evidence の 3 値論理、長周期 cadence の due 生成、StaleUsePolicy。

親仕様: cane v0.7(I-番号)/ AT 仕様 v0.1(AT §n)。
status: draft(r0)。実装済み=R0(NBAccess カレンダー API、56/56 green)。R0b は本書の
identity/revision 版(§3.2.1)に改訂されたため旧 R0b 案は破棄。

---

## 0. 結論

- 4 ソース(CalendarEvent / OnWorkTask / Commitment / Routine(+派生 PrepTask))を
  **occurrence 単位の Obligation** に正規化し、同じ忘却検知・同じ注意ルーターに流す。
  実行は AutoTrigger、事実取得は NBAccess、統計は anomaly に委譲(層は observe/propose のみ)。
- **identity は不変、変化は revision**: StableId+OccurrenceToken は履行・期限変更・メタデータ
  更新で決して変わらない。挙動に効く変化は SemanticDigest、観測上の変化は ObservedRevision。
  reconcile・supersede は SemanticDigest でのみ行う。
- **durable facts と derived state を区別**: ManualMark/waive/overdue 確定/identity mapping/
  PlanningConstraint は owner 単一書き手の**共有 ledger**(EventId dedup)。queue・fulfillment
  cache・plan は導出状態で、失われても再生成できる。
- 通知は durable queue+envelope(2 ゲート独立判定)。送達保証はチャネル別に現実的に定義
  (Board=effectively-once、mail/OS=at-least-once+bounded duplicate)。
- 自動化の権限境界は **AT-1**(AutoTrigger 側 additive 増分: one-shot permit 検証+ExpiresAt
  執行+EnabledAudit 強制)で API 層に置く。UI セル評価は入力手段であって境界ではない。
- クリック操作は **ActionGate** の capability class(Select / LocalNavigation / LocalMutation /
  WorkflowDispatch / ExternalNavigation)で分離。通常クリックは effect-free。

### 0.1 review v1(対 v0.3)対応表

| 指摘 | 対応 | 節 |
|---|---|---|
| P0-1 OccurrenceKey 可変 | Identity(StableId/OccurrenceToken)と Revision を分離。4 Kind とも immutable 化。identity 鍵を署名鍵と分離+rotation 規定 | §2.2 |
| P0-2 Revision が semantic でない | SemanticDigest(occurrence の解決済みフィールド)と ObservedRevision(SEQUENCE/DTSTAMP)を分離。supersede は SemanticDigest のみ | §2.3, §3.2.1 |
| P0-3 LatestState が履歴を消す | ResolutionState(OnTime/Late/SupersededByCatchUp/Missed/Waived)+WasOverdue/FirstOverdueAtUTC 不変+日次 bin immutable | §2.4, §4.3 |
| P0-4 ledger の可搬性 | durable-facts 共有 ledger(single-writer+EventId dedup)+移管 protocol(watermark 引き継ぎ前は tick 停止) | §2.8 |
| P0-5 exactly-once 不可能 | チャネル別送達保証表+DeliveryAttemptId/ChannelReceipt。受入基準を現実化(AC-005/AC-030) | §5.3 |
| P0-6 AT permit/TTL 不在 | **AT-1 増分を R8 の必須依存に**(permit one-shot/ExpiresAt 執行/EnabledAudit/negative test)。原則 5 を改訂 | §8.3, §11 |
| P0-7 ActionResolver 権限 | ActionGate=capability class router。通常クリック effect-free、URL allowlist、revision 再検証 | §7 |
| P0-8 Plan 正本 | extension spec へ(PlanChunk/PlanningConstraint/PlanningIntent 分離)。durable 部分(constraint/progress/intent)は本書 §2.8 の共有 ledger を使う | ext §1 |
| P0-9 単独完結 | 受入基準 AC-001〜AC-036 を本文に全文収録(provenance タグ付き) | §12 |
| P1-1 quality algebra | 3 値論理(Kleene)+quality 合成規則 | §2.6 |
| P1-2 held parser 敵対的入力 | ReleaseHold 禁止(静的受入)+held AST 検証+literal 再構築 | §3.3 |
| P1-3〜P1-4, P1-9(planner) | extension spec §1 | ext |
| P1-5 stale 利用 policy | StaleUsePolicy 表(Kind/Stage 別) | §3.4 |
| P1-6 R0b 試験範囲 | R0b テスト項目を仕様化 | §3.2.1 |
| P1-7 FireTimes cap | Capped=failure。長周期は直接計算/chunked scan(R1) | §4.1 |
| P1-8 TTL と action risk | RecertificationClass=f(Importance, ActionRisk, Reversibility, CredentialScope) | §9 |
| P1-10 分冊 | core/extension 分離。「Petri」は形式意味論のある scope 限定(ext) | 本書+ext |
| P1-11 OverdueContractSeconds | 日内区間積分として定義 | §4.3 |

## 1. 設計原則

1. **実行と注意の分離**: 本層は判定・通知・提案のみ。実行は AutoTrigger。
2. **スケジュール事実の単一取得点**: カレンダー・$onWork は NBAccess 公開関数のみ。
3. **証拠は決定的に**: 履行判定に LLM を使わない(I-15)。
4. **shadow-first 段階昇格**: 検知・通知・自動化とも「記録→受動→能動→実行」。
5. **AutoTrigger / NBAccess は additive 増分のみ**(v0.3 の「無改変」を改訂): 本仕様が要求する
   AT 側増分は **AT-1(§8.3)ただ一つ**で、既存 API の挙動を変えない追加検証・追加執行に限る。
   NBAccess 側は R0/R0b の公開読み出し関数のみ。
6. **認知データ境界**: 停滞・欠席は operational 信号に留める。event/stream に内容を書かない
   (I-13/I-14)。
7. **契約・policy の正本は owner 署名付き**(MAC+OwnerAuthorization)。
8. **identity は不変、変化は revision**(新): 履行・期限変更・移動・改名で ID が変わることは
   設計エラーとして扱う。
9. **durable facts と derived state の区別**(新): owner の意思表示(mark/waive/pin/intent/
   identity mapping)と確定履歴は共有 ledger に置き、それ以外(queue/plan/cache)は
   いつでも再生成できる導出状態とする。
10. **式中心 UI**: 入力は引数入り式テンプレート 1 セル。ただしテンプレート評価は入力手段で
    あって権限境界ではない(境界は API 側=AT-1/ActionGate)。

## 2. 正準データモデル

### 2.1 ObligationOccurrence

```wl
<|
  "Type" -> "ObligationOccurrence", "SchemaVersion" -> "0.4",
  "Identity" -> <|
    "Namespace" -> "Calendar"|"OnWork"|"Commitment"|"Routine"|"Prep",
    "StableId" -> "idv1:<KeyId>:...",    (* 義務/シリーズの不変 ID(§2.2) *)
    "OccurrenceToken" -> "..." |>,       (* 今回分の不変 token(§2.2) *)
  "Revision" -> <|
    "SemanticDigest" -> "...",           (* 挙動に効く解決済みフィールドの digest(§2.3) *)
    "ObservedRevision" -> "..." |>,      (* SEQUENCE/DTSTAMP/ETag 等の観測 revision *)
  "Kind" -> "CalendarEvent"|"OnWorkTask"|"Commitment"|"Routine"|"PrepTask",
  "Source" -> <|"ObservedAtUTC"->_, "FreshnessState"->"Fresh"|"Stale"|"Unavailable"|"Partial",
    "Completeness" -> 0..1|>,
  "Schedule" -> <|"StartUTC"->_|Missing, "EndUTC"->_|Missing,
    "DueAtUTC"->_|Missing, "GraceUntilUTC"->_|Missing,
    "TimeZone"->_, "AllDay"->_|>,
  "Fulfillment" -> <|
    "Mode" -> "LatestState"|"EachOccurrence"|"AnyWithinWindow",
    "State" -> "Unknown"|"Unfulfilled"|"Satisfied"|"Waived"|"Cancelled",
    "Resolution" -> "SatisfiedOnTime"|"SatisfiedLate"|"SupersededByCatchUp"|
                    "Missed"|"Waived"|"Cancelled"|Missing,      (* §2.4 *)
    "WasOverdue" -> True|False,          (* 一度 True になったら不変 *)
    "FirstOverdueAtUTC" -> _|Missing,    (* 不変 *)
    "EvidenceQuality" -> "AttemptObserved"|"ExecutionSucceeded"|"OutcomeSatisfied"|Missing,
    "EvidenceAtUTC" -> _|Missing |>,
  "Attention" -> <|"EpisodeId"->_, "State"->"Eligible"|"Deferred"|"Snoozed"|
    "Acknowledged"|"Delivered", "NextEligibleAtUTC"->_|Missing|>,
  "Effort" -> _|Missing, "Movable" -> _, "DependsOn" -> {___String},
  "ParentRef" -> _|Missing,              (* PrepTask → 親 (StableId, OccurrenceToken) *)
  "Importance" -> "Low"|"Normal"|"High"|"Mandatory"
|>
```

### 2.2 Identity(P0-1)

**規則: StableId と OccurrenceToken はいかなる属性変化でも不変。** 期限・状態・本文・時刻の
変化はすべて Revision(§2.3)。

| Namespace | StableId(`idv1:<KeyId>:` 接頭) | OccurrenceToken |
|---|---|---|
| Calendar | `cal:` + HMAC_id(UID) | 元開始時刻 UTC ISO(override は RECURRENCE-ID、通常展開は series 上の元 DTSTART=NBAccess `OriginalStart`)。**移動後 Start は Revision** |
| Routine | `rtn:` + RoutineId | 期待 window 開始 UTC(occurrence 生成時に確定・不変) |
| Commitment | `cmt:` + CommitmentId | **CommitmentOccurrenceId**(検出時に 1 回発番する ULID・不変)。deadline/メタデータ更新は Revision |
| OnWork | `nb:` + TaskId(§2.2.1) | **ReviewCycleOrdinal**(0,1,2,...。§2.2.1 の mapping 遷移でのみ増加)。Deadline/NextReview/Status の値変更は Revision |
| Prep | `prep:` + HMAC_id(親 StableId + StepId) | 親の OccurrenceToken(親 occurrence 毎に各 Step 1 つ)。StepId は PreparationSpec の不変キー(ext §1) |

#### 2.2.1 OnWorkTask の identity mapping

- notebook metadata whitelist に optional key `"TaskId"`(String・不変)を追加。あればそれが正。
- 無い notebook は**初回観測時**に「正準パス HMAC_id」を TaskId として **identity mapping**
  (durable facts ledger §2.8)に固定する。以後のパス変更・メタデータ変更で TaskId は変わらない
  (パス移動の自動追随は非目標。owner が mapping を付け替える操作のみ)。
- ReviewCycleOrdinal 遷移: 現 cycle の Fulfillment が Satisfied/Waived で確定した後、
  **新しい未来の Due(Deadline/NextReview)が観測された時**に ordinal+1 を mapping へ記録する。
  Due の値をいくら変更しても、この遷移以外で token は変わらない(AC-022)。

#### 2.2.2 identity 鍵の lifecycle

- HMAC_id の鍵(**identity key**)は署名/MAC 鍵と別に発行・保管(SystemCredential。
  ref 例 `svrtn:idkey:v1`)。`<KeyId>` を StableId に埋め込む。
- rotation: 新 KeyId を発行し、**旧鍵が読める間に** migration バッチが全既知 source id について
  旧→新 StableId の対応を durable ledger に書く(HMAC は不可逆なので raw id を参照できる
  時点でしか対応表を作れない)。以後 dual-accept 期間を経て旧 KeyId を退役(AC-024)。
- NBAccess 側(calendar)の identity key は `$NBCalendarIdentityKeyRef` で同じ鍵を参照する
  (§3.2.1)。

### 2.3 Revision(P0-2)

- `SemanticDigest` = **その occurrence の解決済み(展開後)の挙動フィールド**の正準 digest:
  Calendar は {OriginalStart, 実効 Start/End, Status, Transp, AllDay}(master の RRULE/EXDATE
  変更は解決結果の変化として自然に伝播し、無関係な occurrence の digest は変わらない)。
  Commitment は {Deadline, Category, ThreadState}。OnWork は {Due, Status}。
  Routine/Prep は {DueAtUTC, GraceUntilUTC, Cancelled}。
- `ObservedRevision` = 観測メタ(SEQUENCE/DTSTAMP digest、metadata hash 等)。診断用。
- **reconcile/supersede は SemanticDigest の変化でのみ発火**(AC-035: DTSTAMP-only 更新は
  supersede しない。時刻・取消の変化は supersede する)。SEQUENCE を更新しない client の変更も
  SemanticDigest が拾う。

### 2.4 状態と履歴保持(P0-3)

- 3 軸: TemporalState(導出)/ FulfillmentState / AttentionState(v0.3 と同じ遷移規則:
  Ack/Snooze は AttentionState のみ。Snooze 解除は同一 EpisodeId で Eligible へ)。
- **Resolution(確定時に一度だけ記録・不変)**:
  - `SatisfiedOnTime` / `SatisfiedLate`(GraceUntil 前/後に evidence 成立)
  - `SupersededByCatchUp`(LatestState 契約で、後続 evidence により**現在の coverage は回復
    したが、この occurrence 自身は期限内に満たされなかった**)
  - `Missed`(window が閉じ evidence 無し)/ `Waived` / `Cancelled`
- `WasOverdue` / `FirstOverdueAtUTC` は一度成立したら**いかなる catch-up でも消さない**(AC-025)。
- LatestState の意味論: 最新 evidence は「現在以降の coverage」を回復する。過去 occurrence は
  Satisfied に書き換えず `SupersededByCatchUp`(evidence 時点より前)として確定する。
  EachOccurrence は各 occurrence 独立(AC-010)。

### 2.5 FulfillmentMode と期限

v0.3 §2.4 と同じ(3 mode+occurrence 生成時に DueAtUTC/GraceUntilUTC を確定。GraceFactor 廃止。
due 生成の正準は routine 層純関数。長周期の扱いは §4.1)。

### 2.6 EvidenceQuality と 3 値論理(P0-8+P1-1)

- atom の評価結果は `{Truth ∈ True|False|Unknown, Quality, Freshness}`。source が
  Unavailable/Partial で判定不能なら **Unknown**(False ではない)。
- 合成は Kleene 3 値論理: `AllOf`=False 優越・残り Unknown 伝播 / `AnyOf`=True 優越 /
  **`Not[Unknown]=Unknown`**(AC-034: 「source が読めない」を否定成立にしない)。
- Quality: 成立(Truth=True)を決めた positive atom に由来。`AnyOf`=成立枝の最大 quality、
  `AllOf`=構成枝の最小 quality、`Not` は quality を供給しない(guard 専用)。
- Fulfillment 遷移は Truth=True かつ Quality ≥ 契約の MinimumEvidenceQuality のときのみ。
  Unknown は遷移させず、occurrence に freshness 由来の注記を残す。
- quality 段階(v0.3 と同じ): AttemptObserved / ExecutionSucceeded / OutcomeSatisfied。
  outcome 義務(送信・同期・更新)は OutcomeSatisfied 必須(AC-012)。

### 2.7 時刻の正準化

v0.3 §2.6 と同じ(永続 UTC・LocalDate+TimeZone 併記・DST 固定 policy・Fabric AsOfUTC+
全 source Revision で同一 snapshot 保証)。

### 2.8 durable-facts 共有 ledger(P0-4)

- 置き場所: `<VaultRoot>/routine/ledger/`(Dropbox 共有)。**書き手は OwnerMachine のみ**
  (single-writer)。append-only JSONL+EventId(ULID)dedup(既存の参照イベント rollup
  パターンを流用)。
- **durable facts(共有 ledger に置くもの)**: ManualMark / waive / Resolution 確定
  (WasOverdue/FirstOverdueAtUTC 含む)/ identity mapping(§2.2.1〜2.2.2)/ Ack/Snooze /
  PlanningConstraint・PlanningIntent・PlanChunk progress(ext)/ 自動化 provenance。
  内容最小化(StableId/OccurrenceToken/時刻/enum のみ。ラベル・本文なし=I-13)。
- **derived state(機械ローカル・再生成可)**: attention queue、fulfillment cache、plan、
  onwork cache、snapshot。
- **OwnerMachine 移管 protocol**: 新 machine は (1) 共有 ledger を末尾 watermark まで ingest し、
  (2) fulfillment cache を再構成し終えるまで **attention tick を開始しない**。旧 machine の
  queue は `Superseded("OwnerMoved")`。移管後に ManualMark/waive/overdue 履歴が保たれること
  (AC-026)。

### 2.9 RoutineContract(v0.3 §2.8 からの差分のみ)

- `Automation` に `"RecertificationClass" -> "A"|"B"|"C"`(§9。既定は f(Importance, ActionRisk,
  Reversibility, CredentialScope) の導出値)と provenance 4 фィールド(CreatedBy/ProposalId/
  ApprovedBy/AuthorizationId)を持つ。
- 他(Cadence/TimeZone/Grace/FulfillmentMode/MinimumEvidenceQuality/CalendarPolicy/
  EvidenceSpec/Importance/EscalationPolicy/ActionRef/Effort/Movable/署名)は v0.3 §2.8 の
  schema を本書の正準として引き継ぐ(全文は §2.9.1)。

#### 2.9.1 契約 schema 全文

```wl
<|"Type"->"RoutineContract","SchemaVersion"->"0.4",
  "RoutineId"->"routine-XXXXXXXXXXXX","Name"->_String,"Description"->_String,
  "Enabled"->True|False,
  "Owner"-><|"Mode"->"OwnerMachine","OwnerMachineTag"->Automatic|>,
  "Cadence"-><|AT §4 Schedule DSL|>,"TimeZone"->"Asia/Tokyo","Grace"->_Quantity,
  "FulfillmentMode"->"LatestState"|"EachOccurrence"|"AnyWithinWindow",
  "MinimumEvidenceQuality"->"AttemptObserved"|"ExecutionSucceeded"|"OutcomeSatisfied",
  "CalendarPolicy"-><|"SkipOn"->{"Away"},"SkipMode"->"Skip"|"ShiftEarlier"|"ShiftLater"|>,
  "EvidenceSpec"-><|boolean node+atom(§2.10)|>,
  "Importance"->"Low"|"Normal"|"High",
  "EscalationPolicy"-><|"Board"->True,"Badge"->False,"Digest"->False,"Mail"->False|>,
  "ActionRef"->Missing["None"]|<|"Kind"->_,"TargetId"->_,"TargetURI"->_|>,
  "Effort"->_Quantity|Missing,"Movable"->True|False,
  "Automation"-><|"State"->"Manual"|"Proposed"|"Supervised"|"Unattended",
    "TriggerId"->_|Missing,"ProposalId"->_|Missing,"ApprovedBy"->_|Missing,
    "AuthorizationId"->_|Missing,"SupervisedSince"->_|Missing,
    "SupervisedRunTarget"->10,"RecertificationClass"->"A"|"B"|"C"|>,
  "Signature"->_,"CreatedAt"->_,"UpdatedAt"->_,"EnabledAudit"->{}|>
```

### 2.10 EvidenceSpec atom

v0.3 §2.9 の atom 集合(CaneEvent / PipelineWatermark(+MinItems) / AutoTriggerRun /
SourceEvent / ManualMark / OnWorkTask / MailThreadReplied / FileState)を正準として引き継ぐ。
各 atom は {Truth, Quality, Freshness} を返す(§2.6)。quality 宣言: CaneEvent・ManualMark=
Attempt、AutoTriggerRun=Execution、MailThreadReplied・FileState・MinItems>0 付き watermark=
Outcome。

## 3. ScheduleFabric(事実層)

### 3.1 構成

adapter(calendar/onwork/commitment/routine)→ occurrence 正規化 → reconcile(SemanticDigest)
→ snapshot(AsOfUTC)→ 消費者(tick/Board/ActionGate/(ext)View・Plan)。

### 3.2 カレンダー adapter

R0 実装済み(v0.3 §3.2 記載のとおり。56/56 green)。

#### 3.2.1 R0b(identity/revision 版・旧 R0b 案を置換)

NBAccess へ additive に追加(**全アクセスレベルで返す**。いずれも opaque メタデータ):
- `"EventId"`: HMAC_id(UID)。鍵は `$NBCalendarIdentityKeyRef`(SystemCredential 管理・
  署名鍵と別・未設定時は Failure ではなく `"unkeyed:"` 接頭の非 keyed digest に縮退し
  Completeness 注記)。**0.5 だけで stable identity が取れる**(AC-023)。
- `"OriginalStart"`: override は RECURRENCE-ID、通常展開は series 上の元 DTSTART。
- `"SemanticDigest"`: {OriginalStart, 実効 Start/End, Status, Transp, AllDay} の digest。
- `"ObservedRevision"`: SEQUENCE/DTSTAMP の digest(SEQUENCE parse を追加)。
- 既存 `UIDDigest` は後方互換のため残す。

R0b テスト(P1-6 の範囲を仕様化):
DTSTAMP-only 変更で SemanticDigest 不変 / DTSTART/DTEND/STATUS/RRULE/EXDATE 変更で該当
occurrence の SemanticDigest 変化 / master 変更と個別 override の優先順位 / all-day recurrence の
OriginalStart(LocalDate)identity / TZID・DST 境界 / 取消 / 同一 UID の重複ソース /
`MaxEvents` 切り詰め時に `Completeness<1` / identity key 未設定縮退と rotation。

### 3.3 $onWork adapter(P0-9+P1-2)

v0.3 §3.3 の非評価契約を引き継ぎ、次を追加:
- **`ReleaseHold` を実装コードで使用しない**(静的受入=AC-033 前段。grep 可能)。
- held AST の検証は head/arity/leaf 数 whitelist で行い、`DateObject`/`Quantity` を含め
  **検査中に一切評価しない**。許可 literal(String/Integer/Real/リテラル引数の DateObject・
  Quantity/String リスト)のみを**安全に再構築**して採用する。
- 敵対的入力テストを R2 に含める: Notebook box 形(InterpretationBox/TemplateBox/DynamicBox)、
  独自 MakeExpression を想起させる形、巨大数・巨大 list、UpValues 持ちシンボル、
  不正 Association — いずれも評価ゼロ・当該ファイルのみ Partial・scan 継続(AC-013)。
- whitelist keys: Title/Status/Deadline/NextReview/EventDate/Keywords/Effort/Movable/
  DependsOn/**TaskId**(§2.2.1)。

### 3.4 ソース鮮度と StaleUsePolicy(P0-6 旧+P1-5)

adapter 返り値(Items/ObservedAtUTC/SourceVersion/FreshnessState/Completeness)と
coverage degradation 通知(1 episode 1 回)は v0.3 §3.4 を引き継ぐ。**stale データの用途別
policy** を追加:

| 用途 | Fresh | Stale(≤ StaleActiveTTL、既定 24h) | Stale 超過/Unavailable |
|---|---|---|---|
| Board 表示 | 通常 | **stale ラベル付き**表示 | 「ソース不能」表示(空と区別=AC-018) |
| active reminder(Lead15 等) | 通常 | 送るが Urgency を落とし「未確認の予定」と明示 | 送らない+coverage degradation |
| busy gating | 通常 | 使う(defer 側=安全側) | fail-open(not busy) |
| (ext)Plan 自動変更 | 通常 | 凍結+PlanInputDegraded | 凍結 |

### 3.5 privacy projection

v0.3 §3.5 を引き継ぐ(Fabric 自身が boundary。<0.7 は keyed digest+時刻+enum のみ。
ActionRef/パス/URI は owner-local 遅延解決のみ。AC-016)。

## 4. 忘却検知(判定層)

### 4.1 決定的判定

v0.3 §4.1 を引き継ぎ、次を追加:
- **長周期 cadence(P1-7)**: AT FireTimes/ScheduleMatch の返す `Capped->True` は **failure として
  扱い**、その場合 (a) Interval 系 cadence は直接算術で、(b) CalendarPattern 系は年単位の
  chunked scan で due を生成する(R1 の純関数に含める)。年次 cadence が cap で無音になる
  ことを禁止(AC-032)。
- Resolution 確定(§2.4)は durable ledger へ書く(occurrence 毎 1 回・冪等=AC-014)。

### 4.2 CalendarRole / AvailabilityClass

v0.3 §4.2 を引き継ぐ(Away は明示シグナルのみ。AC-007)。

### 4.3 統計層

v0.3 §4.3 を引き継ぎ、次を確定:
- `OverdueContractSeconds`(P1-11)= occurrence 毎に日次で
  `len([max(GraceUntilUTC, dayStart), min(resolvedAtUTC|dayEnd, dayEnd)])` を合計した
  日内 overdue 滞留の積分。日境界は owner TimeZone。SourceUnavailable 区間は除外して
  `SourceUnavailableSeconds` に分離。
- 日次 bin は close 後 **immutable**。訂正は correction event の追加で表す(P0-3)。

## 5. AttentionContext(注意層)

### 5.1 チャネル・段階・envelope

v0.3 §5.1〜§5.2 を引き継ぐ(envelope: Stage/Urgency/MeetingBypass/QuietHoursBypass 独立判定。
Mandatory ladder は Lead15Minutes のみ MeetingBypass。AC-003/AC-004)。

### 5.2 durable queue

v0.3 §5.3 の状態機械(Pending→Deferred→Claimed→Delivered|Superseded|Expired、冪等
EnvelopeId、lease、連続会議再 defer、MaxDefer→Board fallback、OwnerMoved)を引き継ぐ。

### 5.3 送達保証(P0-5。チャネル別に現実化)

| チャネル | 保証 | 機構 |
|---|---|---|
| Board / badge / 内部 digest | **effectively-once**(表示は冪等) | EnvelopeId keyed upsert。再描画・再 flush は同一表示に収束 |
| 冪等キーを受理する外部チャネル | exactly-once 相当 | EnvelopeId を idempotency key として渡す |
| mail / OS 通知(一般) | **at-least-once**。crash window(提示成功→Delivered 書込前)では bounded duplicate を許容 | `DeliveryAttemptId` を送信毎に発番・記録。rate limit と collapse が暴発を抑止 |

queue record に `DeliveryAttemptId` / `ChannelReceipt`(取得できるチャネルのみ)/
`CollapsedIntoEnvelopeId` を追加。**exactly-once を受入基準にしない**(AC-005/AC-030 は
本表の意味論で判定)。

### 5.4 AttentionPolicy / coverage degradation / failure domain

v0.3 §5.4〜§5.6 を引き継ぐ(BypassRules・Freshness 閾値・CalendarRoles・MandatoryPatterns 正本・
Channels DependencyClass。AC-008/AC-031)。

## 6. Commitment 供給

v0.3 §6(Candidate→Open 昇格制・thread obligation・FalseAlarm 実績)を引き継ぎ、
**CommitmentOccurrenceId**(§2.2)を検出時に発番する。deadline 修正・再解釈は Revision のみ
(AC-021)。

## 7. ActionGate(P0-7。旧 ActionResolver を置換)

クリック操作を capability class で分離する router。**通常クリック(図形・行選択)は
Select/Inspect に固定し、作用のある操作は明示の action ボタン/メニューのみ**。

| Class | 例 | 必須条件 |
|---|---|---|
| Select/Inspect | 詳細表示・選択・ジャンプ(view 内) | 制約なし |
| LocalNavigation | notebook/ディレクトリを開く | 登録 root(例 $onWork)への path containment+**現 snapshot revision の再解決**(mapping 経由) |
| LocalMutation | 準備ノート作成・pin・waive・Candidate→Open | preview 提示+owner 操作+durable ledger へ audit event |
| WorkflowDispatch | 「今すぐ実行」(AT 発火)・返信 draft 起動 | 既存 AT/Guard gate へ委譲+**current SemanticDigest 再検証**(stale view からの実行を停止=AC-028) |
| ExternalNavigation | イベント本文中の URL | **scheme allowlist(https のみ既定)+domain allowlist(owner policy)+明示確認**。calendar/mail 由来 URI の直接 SystemOpen 禁止(AC-029)。release 系は既存 PlanMessageRelease ゲートのみ |

- action 実行前に対象 occurrence を現 snapshot で再解決し、SemanticDigest 不一致なら停止して
  再表示(AC-028)。
- 対象パッケージ未ロード時は該当 action 非表示(rule 11)。
- (ext)の全 View はこの gate を経由する。Board(R3)も同じ。

## 8. 自動化提案

### 8.1 AutomationEligibility gate / 提案フロー

v0.3 §9.1〜§9.2 を引き継ぐ(eligibility 前置・IP-5 未配線間の Unattended 禁止(AC-011)・
FormulaicScore・AllowedWindows 内 slot)。eligibility 宣言値(冪等性・可逆性・pre/postcondition・
credential scope・rollback)は **TriggerSpec 側でなく契約 `Automation` と提案 record に正本を
持つ**(P1-4 の「宣言の正本」)。

### 8.2 承認フロー

routine 層は draft 生成と `SourceVaultRegisterAutoTrigger[draft]`(DryRun=検証)まで。
実書き込み・Enable は owner のテンプレートセル評価で行うが、**その呼び出しは §8.3 の permit を
携行する**(セル評価は入力手段、境界は API)。provenance(CreatedBy->"RoutineAutomationProposal"
/ProposalId/ApprovedBy->"Owner"/AuthorizationId)を TriggerSpec と契約の双方へ。

### 8.3 AT-1: AutoTrigger additive 増分(P0-6。**R8 の必須依存**)

AutoTrigger 側に additive で追加する(本仕様の唯一の AT 変更要求。AT 仕様への提案として起票):

1. **one-shot permit**: `<|"SpecHash", "ProposalId", "Action"->"Register"|"Enable",
   "ExpiresAt", "Nonce"|>` に owner 鍵で署名した permit を、Register(DryRun->False)/Enable の
   mutation boundary が検証し**一度だけ消費**する(consume-once ledger は capbroker
   PreparedInputToken パターンを流用)。permit なし・再利用・期限切れ・SpecHash 不一致は拒否
   (AC-027)。permit 生成は owner 明示操作のみ(LLM/external から不可到達)。
2. **ExpiresAt 執行**: enabled spec の load/tick が `ExpiresAt` を評価し、超過 trigger は
   dispatch せず、冪等な `Expired` event を 1 回記録する(AC-031)。現行
   `iSVATLoadEnabledSpecs` が Enabled しか見ない事実(review §2)への対応。
3. **EnabledAudit 強制**: Enable 経路が EnabledAudit エントリ(permit の ProposalId/
   AuthorizationId を含む)無しに Enabled->True を書けないようにする。

negative capability test(AC-027)は「routine 層コード」「UI テンプレートセル」「直接 API 呼び」
の 3 経路すべてで permit 検証が効くことを確認する(v0.3 受入 27 の grep 検査を置換)。

## 9. automation complacency(P1-8: risk-based → class-based)

`RecertificationClass = f(Importance, ActionRisk, Reversibility, CredentialScope)`:

| Class | 典型 | TTL | receipt | outcome audit |
|---|---|---|---|---|
| A | 外部送信・削除・不可逆(Importance 不問) | 30 日 | 週次 | **sampled**: 期間毎に無作為 n≥3 run の postcondition を再検証。失敗 1 件で Supervised へ自動降格提案 |
| B | 可逆なローカル状態変更 | 90 日 | 隔週 | 例外時のみ |
| C | read-only 取得・確認 | 180 日 | 月次/例外中心 | なし |

Importance=High は 1 段厳格化(C→B、B→A)。失効予告は 7 日前から(Class A は Urgency=Critical)。
失効=AT-1 の ExpiresAt 執行で dispatch 停止→義務は手動に戻り overdue 検知が拾う。

## 10. IP 表(統合点)

| IP | 内容 | 状態 |
|---|---|---|
| IP-1 | Cadence DSL 解釈に AT 純関数。**Capped は failure、長周期は直接計算/chunked scan** | v0.4 更新 |
| IP-2 | 「今すぐ実行」→ AT 手動発火(ActionGate WorkflowDispatch 経由) | v0.4 更新 |
| IP-3 | draft は DryRun まで。実書き込み/Enable は **permit 携行**(AT-1) | v0.4 更新 |
| IP-4 | AT runs.jsonl=Execution quality の evidence | 継続 |
| IP-5 | 未実行 window 条件。未配線間 Unattended 禁止 | AT 側待ち |
| IP-6 | ExpiresAt/EnabledAudit — **AT-1 で執行実装** | v0.4 更新 |
| IP-7 | カレンダー(R0 済+R0b=identity/revision 版) | R0b 未 |
| IP-8 | $onWork(NBOnWorkTasks・非評価契約+TaskId) | R2 |
| IP-9 | AT NextFire preview の表示利用 | ext |
| IP-10 | ActionGate → maildb/mailsuggest/NotebookOpen/claudecode の弱結合 | R3〜 |

## 11. 増分実装計画

| Inc | 内容 | 依存 |
|---|---|---|
| R0 | カレンダー API(**実装済み**・56/56) | — |
| R0b | identity/revision 追補(§3.2.1: EventId/OriginalStart/SemanticDigest/ObservedRevision+SEQUENCE parse+テスト群) | R0 |
| R1 | 正準 schema+純関数(identity 規則/3 値論理/Resolution/長周期 due/OverdueContractSeconds)。IO なし | — |
| R2 | adapter 4 種+freshness/StaleUsePolicy+held parser(敵対的テスト込み)+**durable-facts 共有 ledger**+fulfillment cache 再構成+移管 protocol | R0b,R1 |
| R3 | Board v2+3 軸遷移+**ActionGate**(capability class・URL allowlist・revision 再検証) | R2 |
| R4 | AttentionPolicy+durable queue+送達保証実装(DeliveryAttemptId 等)+ladder+coverage degradation+tick 結線 | R3 |
| AT-1 | AutoTrigger additive(permit/ExpiresAt 執行/EnabledAudit)。**AT 仕様側の増分として起票・実装** | — |
| R7 | 統計 stream(積分定義・immutable bin) | R2 |
| R8 | 自動化(eligibility/提案/承認 permit/supervised ledger/class-based receipt・TTL) | R4, **AT-1** |
| R9 | mail チャネル(AT §3.6 前提) | R4 |
| ext RX-1/RX-2 | 可視化 suite/計画層(extension spec v0.1) | R3〜R4 |

最小実用: R0〜R4 =「通知を失わず・会議を邪魔せず・identity が壊れない忘却注意」。

## 12. 受入基準(全文収録・固定 ID。provenance: rv2-n=v0.2 review §6 の n、rv3-n=v0.3 review §7 の n)

**AC-001**(rv2-1) 同一 UID の週次会議 2 回に、各 lead 段の通知がそれぞれ 1 回ずつ出る。
**AC-002**(rv2-2) occurrence の移動・取消・SemanticDigest 変化で古い pending 通知が supersede される。
**AC-003**(rv2-3) Lead15Minutes のみが meeting gate を貫通し、前日・2 時間前は貫通しない。
**AC-004**(rv2-4) MeetingBypass と QuietHoursBypass が独立に動作する。
**AC-005**(rv2-5 改) defer 書込直後・claim 後・delivery 後の各 crash から復旧し、重複は §5.3 の
チャネル別保証の範囲内に収まる(Board 系は重複表示なし、mail/OS は bounded duplicate)。
**AC-006**(rv2-6) 連続会議では flush 前に busy を再評価して再延期し、最後の会議後に 1 つへ collapse する。
**AC-007**(rv2-7) 終日 busy・transparent holiday・OOO・単なる終日予定を区別する(Away は明示シグナルのみ)。
**AC-008**(rv2-8) calendar Stale/Unavailable 時、Mandatory reminder coverage degradation が 1 episode 1 回だけ通知される。
**AC-009**(rv2-9) Ack/Snooze 後も evidence がなければ FulfillmentState は Unfulfilled のまま。
**AC-010**(rv2-10) LatestState と EachOccurrence で「複数回未実行後の 1 回実行」の結果が異なる
(LatestState: 現在 coverage 回復+過去は SupersededByCatchUp。EachOccurrence: 過去は Missed のまま)。
**AC-011**(rv2-13) IP-5 未配線の TriggerSpec は Unattended として enable できない。
**AC-012**(rv2-12) AT run が Completed でも postcondition 不成立なら outcome 義務は満たされない。
**AC-013**(rv2-15+P1-2) Initialization セルに副作用式・Notebook box・巨大式・不正 Association が
あっても一切評価せず、当該ファイルのみ Partial とし scan を継続する。実装は ReleaseHold を含まない。
**AC-014**(rv2-17) staleness/Resolution event は occurrence/episode 毎に冪等で、毎 tick 増殖しない。
**AC-015**(rv2-11) 月次・営業日補正・DST 境界で DueAtUTC/GraceUntilUTC が仕様の明示時刻に一致する。
**AC-016**(rv2-16) Fabric の AccessLevel 0.5 出力に Label・path・URI・生 UID・ActionRef が含まれない。
**AC-017**(rv2-14) 手動実行済み window では自動実行が duplicate skip になる(IP-5 配線後の試験)。
**AC-018**(rv2-18) Board が source unavailable と「obligation なし」を区別して表示する。
**AC-019**(rv3 19/20 相当) tick・Board・全 View が同一 AsOfUTC snapshot から同一判定を導き、
Board の各 action が Kind 相応の正しい対象を開く(未ロード時は非表示)。
**AC-020**(rv3-29) OnWorkTask の Status を Done にしても StableId/OccurrenceToken が変わらない。
**AC-021**(rv3-30) Commitment の deadline/metadata 更新で identity は不変、SemanticDigest のみ変わる。
**AC-022**(§2.2.1) OnWorkTask の Due 値変更では OccurrenceToken が変わらず、cycle 遷移
(Satisfied 確定→新未来 Due 観測)でのみ ordinal が進む。
**AC-023**(rv3-32) AccessLevel 0.5 だけで Calendar の opaque stable ID(EventId)を取得でき、
生 UID はどのレベル 0.5/0.7 出力にも現れない。
**AC-024**(rv3-33) identity key rotation 後、migration map により旧 ledger/queue/pin が同じ
obligation を指し続ける。
**AC-025**(rv3-34) LatestState の catch-up 後も WasOverdue/FirstOverdueAtUTC/SatisfiedLate/
SupersededByCatchUp が保持される。
**AC-026**(rv3-35) OwnerMachine 移動後も ManualMark/waive/overdue 履歴が維持され、watermark
引き継ぎ完了まで新 machine の tick が開始されない。
**AC-027**(rv3-37+P0-6) permit なし/再利用/期限切れ/SpecHash 不一致の Register(DryRun->False)/
Enable が、routine 層・UI セル・直接 API のどの経路でも失敗する。
**AC-028**(rv3-39) stale な View からの action 実行前に current SemanticDigest を再検証し、
不一致なら停止して再表示する。
**AC-029**(rv3-40) calendar/mail 由来の `file:`・custom scheme・不許可 domain の URL を
ActionGate が開かない。
**AC-030**(rv3-36) チャネル提示成功直後・Delivered 書込前 crash の再送が §5.3 の意味論どおり
(Board=重複なし、mail=DeliveryAttemptId が別発番の重複 1 通まで)。
**AC-031**(rv3-38) ExpiresAt 超過 trigger は Enabled=True でも dispatch されず、Expired event が
1 回だけ記録される。
**AC-032**(rv3-47) 年次等の疎な cadence が AT の scan cap(FireTimes 100k step)を超えても
due が生成されるか、明示 Failure になる(無音にならない)。
**AC-033**(rv3-49/P0-2) DTSTAMP-only 更新では通知が supersede されず、時刻・取消の変更では
supersede される。
**AC-034**(rv3-48) `Not[Unknown]`=Unknown であり、source unavailable が True/OutcomeSatisfied に
化けない。
**AC-035**(rv2 系規範) 契約・policy の登録変更は OwnerAuthorization 無しで Failure、署名不正は
fail-closed。event 記録は内容最小化(本文・ラベル・認知系数値なし)。
**AC-036**(rv3-50) 本書単独で全受入基準が読め、review 文書なしに試験実装できる。

## 13. 未解決論点

- (a)〜(k) は v0.3 §14 から継続(f 欠席事後判定=しない / g Mandatory 正本=AttentionPolicy /
  h 祝日=購読カレンダー / i,n OnWork 書き戻し=別増分 / j 実績見積=提案のみ / k ドラッグ=
  クリック代替)。
- (l) **解決**: AT-1(§8.3)として core の必須依存増分に昇格。
- (m) DependsOn/TaskId メタデータ key — whitelist 反映済み(§3.3)。
- (o) FocusSlot のカレンダー書き戻し — ext の非目標(承認ゲート付き別仕様)。
- (p) 新規: identity mapping の owner 手動付け替え UI(notebook 移動時)— R3 Board の
  LocalMutation として設計するが、v0.4 では仕様最小(mapping event の schema のみ確定)。
- (q) 新規: durable ledger の Dropbox 競合(single-writer でも同期遅延はある)— OwnerMachine
  単一書き手+EventId dedup で実害はないはずだが、R2 実装時に conflict copy 検知を追加検討。
