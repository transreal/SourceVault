# SourceVault Cane / Knowledge Home 認知支援マイニングレイヤー仕様 v0.7

- 作成日: 2026-07-12(v0.1)/ 更新日: 2026-07-12(v0.7)
- 状態: **Draft(r6 レビュー全反映。r6 判定: 1H-S は本版の token/lease 原子性+diagnostics 漏洩修正で着手可能、1H-A は observe-only 実装に進める。本版は v0.6 への差分)**
- 本版 v0.7 の変更(r6 `sourcevault_cane_knowledge_home_mining_spec_v0_6_review.md` 全反映。対応表は Appendix H):
  1. **CapabilityLease の原子性(P0-01)**: 署名付き token を正準にせず、**broker 側 authoritative ledger + 原子的 consume**(CAS/単一 writer)を正準に。consume→dispatch の TOCTOU 排除(broker が dispatch まで所有 or 同一 transaction の one-time execution ticket)
  2. **PreparedInputToken の完全 request binding(P0-02)**: input text でなく**送信される request envelope 全体**(model/messages/tool schema/retrieval/isolation/privacy/capability ceiling/output schema)の digest に bind。送信直前に再計算・不一致拒否
  3. **mint API の非公開化(P0-03)**と **TestBypass の production 無効化(P0-04、不変条件化)**
  4. **taint edge の方向・寄与条件(P0-05)**: `PropagationEdge`(CarriesContent/ContributingSpanRefs/TransformRef/Direction)。部分 taint と全体 quarantine の区別
  5. **SafeInspection 通常モードの copy/export 禁止(P0-06)**: warning 方式を廃止し禁止に。Export は別モード(sanitized projection+declassification gate)
  6. **ワークフローの冪等性(P0-07〜09)**: `CaneAnomalyWorkflowRun` 正準化(input snapshot/idempotency key/watermark/lock)、schedule の owner 登録・排他・catch-up 規則、`AnomalyWorkflowProfile` の署名付き trusted config 化
  7. **初期 pair から owner 相関を除外(P0-10)**: 初期 active は LLM 系・system 系のみ。owner 状態相関は research-only の明示 opt-in へ
  8. **SharedUpstream の昇格上限(P0-11)**、**baseline の candidate/validate/activate 三段階(P0-12)**
  9. **diagnostics 漏洩の是正(P0-13/14)**: 通常 probe から `PendingSensitiveAlerts` を削除(heartbeat.json が ComponentHealth 全体を書く現行実装への対処)。diagnostics 側に sink 別 field allowlist を追加(SourceVault_diagnostics 改修を依存に明記)
- v0.6 までの本文は変更なし(無印の節は前版を正とする)

## 2. 不変条件(v0.7 追加・改訂)

**I-14 追補(lease/token の実行契約)**
- **ledger 正準**: one-shot/MaxUses/revocation の正は broker 側 ledger(§4.21b)。token 内の `RemainingUses` を判定に使わない。同一 LeaseId の replay を拒否。process crash 等で実行有無が不明な場合は `indeterminate` とし**再実行しない**。expiry 判定は broker 時刻(clock rollback 耐性)。key rotation・旧 KeyId の受理期限・全 lease 一括失効(RevocationEpoch)を定義する。
- **TOCTOU 排除**: consume 判定と実 action の間に隙間を作らない — broker が action dispatch まで所有するか、consume と同一 transaction で one-time execution ticket を発行し、実行系は ticket のみを受理する。
- **完全 request binding**: PreparedInputToken は §4.22b の `PreparedRequestDigest` に bind。provider adapter は**送信直前に digest を再計算**し、不一致(system prompt/tool schema/retrieval/model/endpoint/sampling config の差し替え)を拒否する。token は短命・one-shot・provider×deployment×run×step に bind し、consume ledger で replay を防ぐ。
- **mint の非公開**: mint は broker 内部関数(`iSV*`)のみ。public は request/verify/consume 系 API(§6)。`IssuerRef` は呼び出し引数から受け取らず broker が自己 identity から付与する。
- **TestBypass の production 無効化**: production build/profile では bypass の code path 自体を無効化する。test 利用は環境 attestation+process-local secret を要し、使用は fail-loud な監査 event。persistent config・prompt・cloud/MCP/LLM 引数から指定・到達不可。bypass 下の artifact は production store へ commit 不可。

**I-16 追補(ワークフローの決定性と信頼境界)**
- ワークフロー実行は §4.23 の run record を持ち、`ProfileVersion × InputSnapshotDigest × Window` の idempotency key で冪等(同一 key の completed run は再利用、再実行で event/baseline を二重更新しない)。baseline 更新は単一 writer/lock。retry は同一 input snapshot。profile 変更は別 run。
- **schedule 規則**: 起動できるのは owner が明示登録した ScheduleSpec のみ(既定 manual)。schedule は分析権限のみ(enforcement 権限なし = I-16 本則)。pause/disable/next-run 表示、同時 run の排他、sleep 復帰 catch-up の最大遡及 window を持つ。
- **AnomalyWorkflowProfile は trusted signed config**: SensitiveLocalVault(または trusted local config)に保存、owner のみ変更可、schema validation+MAC/署名、versioned+変更 diff+rollback、LLM/model output からの自動更新不可、external content 由来の提案は PendingReview、profile 変更後は baseline epoch 切替。
- **baseline 更新の三段階**: candidate 生成 → validation(更新前後 diff+backtest)→ activate。自動 activate は coverage 十分・pending window なし・config 不変の場合のみ。それ以外は review 待ち。observe-only でも baseline 書換えは将来判定を変える state mutation として扱う。

## 4. データモデル(v0.7 追加・改訂)

### 4.21b CapabilityLeaseLedgerRecord(新設。P0-01)【1H-S】

```
<|LeaseId, State -> "issued"|"consumed"|"revoked"|"expired",
  UsesConsumed, LastConsumeAttemptAt,
  ConsumedByRunRef, StepRef, RevocationEpoch, Version|>
```

consume は compare-and-swap または単一 writer broker で原子的に行う(既存の `.lockdir`/tmp+rename 規約を再利用)。

### 4.22b PreparedRequestDigest(新設。P0-02)【1H-S】

```
PreparedRequestDigest = Hash[ model/deployment + system/developer/user/tool messages
  + tool schemas + retrieval refs/digests + isolation profile
  + privacy decision + capability ceiling + output schema ]
```

`PreparedLLMInput` の `InputDigest` を本 digest に置換(input text 単独の digest は補助フィールドに降格)。

### 4.17d PropagationEdge(新設。P0-05)【1H-S】

```
<|FromRef, ToRef, EdgeKind, CarriesContent -> True|False,
  ContributingSpanRefs, TransformRef, Direction, PolicyVersion|>
```

- taint 伝播は `CarriesContent -> True` **かつ寄与 span あり**の場合に限定。`Contains` は方向を明示(container→child と child→container で影響が異なる)。`AttachmentOf` は添付の存在ではなく、**実際に読まれた span が寄与した** artifact のみへ伝播。
- container の集約値は「一部 tainted」(部分 span の taint)と「全体 quarantined」を区別する。

### 4.23 CaneAnomalyWorkflowRun(新設。P0-07)【1H-A】

```
<|WorkflowRunId, ProfileRef, ProfileVersion,
  InputSnapshotDigest, BaselineEpochRefs,
  WindowStart, WindowEnd, Watermarks,
  OutputEventRefs, Status, StartedAt, CompletedAt|>
```

report は OutputEventRefs から再生成可能とする(report 自体を正準にしない)。

### 4.20 追補(P0-11)

`AnomalyCorrelationHypothesis` に `DependenceAdjustment / EffectiveSampleSize / AttributionConfidence` を追加。**`SharedUpstream` の hypothesis は既定で `AssociationSupported` を上限**とし(campaign の存在の材料にはなるが因果証拠にならない)、`CausalEvidenceSupported` への昇格は IndependentStreams 相当の追加根拠(controlled replay 等)を要する。

## 5. 機能仕様(v0.7 改訂)

### 5.13 追補: SafeInspection のモード分離(P0-06)

- **通常モード**: clipboard/export/drag&drop/save を**禁止**(warning 方式を廃止)。「漏出ゼロ」DoD と整合。
- **ExportReview モード**(明示起動): sanitized projection のみ、declassification gate(I-14 の risk 別要件)必須。
- **raw payload export**: 別の forensic workflow として分離。local encrypted target 限定+owner 再確認。

### 5.14 追補: 初期 stream pair(P0-10)

初期 active pair は次の 2 系のみ:
1. LLM 系: `InjectionSignalRate × RunIntegrityRate`
2. system 系: `pre-scan failure/liveness × unexpected tool request`

**owner 状態系 pair(MailSenderNovelty × OwnerOperationalSignal 等)は初期 active に含めない**。offline research view 限定とし、十分な baseline・privacy 検査・文言評価・false alarm 評価の後に owner の明示 opt-in で有効化する(v0.6 Open issue 3 の推奨初期値を本版で置換)。

### 5.15 改訂: diagnostics 境界の強制(P0-13/14)

- 通常 registered probe は **pipeline health のみ**を返す:
  ```
  SourceVaultCaneDiagnosticsProbe[] ->
    <|"Health" -> "OK"|"Degraded"|"Failing",
      "ReasonCode" -> "PipelineHealthy"|"PipelineStale"|"PipelineFailed"|>
  ```
  **`PendingSensitiveAlerts` は通常 probe から削除**(現行 `SourceVaultDiagnosticsMachineHeartbeat` は SystemDoctor の ComponentHealth 全体を heartbeat.json に書き、Dropbox 同期・multi-machine rollup から見えるため、boolean ですら通常経路に載せない)。alert の有無は `SourceVaultCaneSensitiveDoctor[]` のみが表示する。
- probe の Health は **pipeline の liveness のみ**で決まる(alert の有無で Degraded にしない)— Cane alert の有無で GlobalHealth・Cloud heartbeat が変化しないことを保証。
- **diagnostics 側の sink 別 field allowlist**(SourceVault_diagnostics の sanitizer 改修。本仕様の依存タスクとして明記): heartbeat = component 名+Health+公開 ReasonCode のみ / diagnostics log = 明示 allowlist / cloud heartbeat = GlobalHealth のみ / mail = 固定文のみ / local SystemDoctor UI = 必要に応じ local-only field(`ProbeVisibility -> "LocalOnlyNotHeartbeat"` scope の追加)。producer 規約だけに頼らず、serialization 境界で強制する。

### 5.16 capability 基盤の層合成(新設。r6 §6)【Phase 0 decision の指針】

正準基盤の選定は二者択一にせず層として合成する(二重正準を作らない):

```
AccessProfile/Grant(MCP: authorization・provenance・epoch 失効)
  → ActionGate decision(servicemanager: action risk・capability profile)
  → CapabilityLease mint(新 broker: §4.21)
  → atomic consume + dispatch(新 broker ledger: §4.21b)
```

新 broker は既存 authorization/gate を再実装しない(判断は上流の decision ref を参照)。

## 6. Public API(v0.7 改訂)

```
(public)
SourceVaultRequestCapabilityLease[request]           (* 申請。mint はしない *)
SourceVaultVerifyCapabilityLease[lease, action]
SourceVaultConsumeCapabilityLease[leaseId, action]   (* broker の原子的 consume 入口 *)
SourceVaultPrepareLLMInput[input, opts]
SourceVaultVerifyPreparedRequest[token, requestEnvelope]
SourceVaultRunCaneAnomalyWorkflow[opts]
SourceVaultCaneAnomalyWorkflowRuns[opts]             (* run record 照会 *)
SourceVaultCaneBaselineCandidates[opts]
SourceVaultActivateCaneBaseline[candidateRef, opts]  (* validation 済みのみ受理 *)

(broker internal — public export しない)
iSVMintCapabilityLease[validatedRequest]
iSVMintPreparedInputToken[preparedEnvelope]

(廃止) SourceVaultMintCapabilityLease / SourceVaultPreparedInputToken(public mint 面を撤去)
```

## 8. 評価計画(v0.7 追加)

**Structural security**: 並行 replay した one-shot lease の二重成功(必須ゼロ)/ crash・timeout 時の indeterminate action 再実行(必須ゼロ)/ prepare 後 request 改変の拒否率 / model・tool schema・endpoint 差替え token misuse の拒否 / production での TestBypass 到達(必須ゼロ)/ partial taint と whole-object quarantine の誤分類率 / SafeInspection の clipboard・export・drag&drop・save 漏洩(必須ゼロ)。

**Anomaly workflow**: 同一 snapshot 再実行時の重複 event(必須ゼロ)/ concurrent workflow の baseline 競合(必須ゼロ)/ partial failure 後 retry の再現性 / profile 改ざん・未承認変更の拒否 / SharedUpstream の因果誤昇格(必須ゼロ)/ baseline candidate backtest の劣化検出率 / owner 系 stream 未 opt-in 時の読み取り(必須ゼロ)。

**Diagnostics**: registered probe の追加 field が heartbeat へ出ないこと / PendingSensitiveAlerts 相当の boolean が Dropbox・cloud・mail へ出ないこと / Cane alert 有無で Cloud GlobalHealth が変化しないこと / pipeline 停止時だけ sanitized health が Degraded/Failing になること。

## 9. 受け入れ基準(v0.7 追加。1〜87 は既存)

88. one-shot lease が broker 側 ledger で原子的に consume されること(並行 replay の二重成功ゼロ)
89. consume と action dispatch の間で replay/TOCTOU が起きないこと(broker 所有 dispatch or 同一 transaction ticket)
90. PreparedInputToken が完全な provider request envelope(model/messages/tool schema/retrieval/isolation/privacy/ceiling/output schema)へ bind されること
91. token が run/step/provider/deployment へ bind され one-shot であること
92. mint API が untrusted caller/LLM から到達不能であること(public は request/verify/consume のみ)
93. production で TestBypass が利用不能であること(code path 無効化+attestation+fail-loud 監査)
94. taint propagation edge が方向・span 寄与・transform を持ち、CarriesContent=True+寄与 span ありの場合のみ伝播すること
95. SafeInspection 通常モードで clipboard/export/drag&drop/save が禁止されること(ExportReview は sanitized+declassification gate)
96. anomaly workflow が input snapshot・idempotency key・watermark・lock を持つこと
97. workflow 再実行で event/baseline が二重更新されないこと
98. schedule が owner 登録済み ScheduleSpec のみで、pause/disable/排他/max catch-up を持つこと
99. AnomalyWorkflowProfile が署名付き trusted local config であり、LLM/external content から自動変更されないこと
100. 初期 active pair に owner 状態 stream を含めないこと(owner 系は research-only 明示 opt-in)
101. SharedUpstream が因果状態へ自動昇格しないこと(既定上限 AssociationSupported)
102. baseline 更新が candidate/validate/activate の三段階で、無条件自動 activate が起きないこと
103. 通常 SystemDoctor probe が sensitive alert の有無を返さないこと(Health+ReasonCode のみ)
104. diagnostics の heartbeat/log/cloud/mail が sink 別 field allowlist を強制すること(diagnostics 側 sanitizer 改修を含む)
105. owner 状態 alert の有無で GlobalHealth/cloud heartbeat が変化しないこと

## 10. Open issues(v0.7)

1. broker ledger の実装位置(servicemanager 内 vs 新 `SourceVault_capbroker.wl`)と、MCP grant/ActionGate との decision ref 連携の詳細(§5.16 の層合成の配線)
2. PreparedRequestDigest の正規化規則(message 序列・tool schema の canonical JSON 化 — digest 安定性)
3. diagnostics field allowlist の後方互換(既存 probe が Association を返している場合の移行)
4. ExportReview モードの sanitizer 実装(決定的 redaction の対象クラス)
5. v0.6 からの継続分(claim 正規化 / RequiredEvidencePolicy / AttackFamily 語彙 / workflow スケジュール頻度 / ほか)

## Appendix H: r6 レビュー対応表

| r6 項目 | 反映箇所 |
|---|---|
| P0-01 lease 多重使用 | I-14 追補+§4.21b ledger+CAS/単一 writer+indeterminate 非再実行+broker 時刻+key rotation+TOCTOU 排除(受入 88,89) |
| P0-02 token の request binding | I-14 追補+§4.22b PreparedRequestDigest+送信直前再計算拒否(受入 90,91) |
| P0-03 mint API 公開 | §6 分離(public request/verify/consume、iSV mint 内部化、IssuerRef は broker 付与)(受入 92) |
| P0-04 TestBypass | I-14 追補(production code path 無効化・attestation・fail-loud・prompt/MCP 不到達・artifact 非 commit)(受入 93) |
| P0-05 taint edge 方向・寄与 | §4.17d PropagationEdge+部分/全体の区別(受入 94) |
| P0-06 SafeInspection copy/export | §5.13 追補(通常=禁止 / ExportReview / forensic 分離)(受入 95) |
| P0-07 workflow 冪等性 | I-16 追補+§4.23 CaneAnomalyWorkflowRun(受入 96,97) |
| P0-08 schedule 規則 | I-16 追補(owner 登録・分析権限のみ・排他・catch-up)(受入 98) |
| P0-09 profile 信頼境界 | I-16 追補(署名付き trusted config・PendingReview・epoch 切替)(受入 99) |
| P0-10 初期 pair から owner 除外 | §5.14 追補(LLM 系+system 系のみ。owner 系は research-only opt-in)(受入 100) |
| P0-11 SharedUpstream 上限 | §4.20 追補(DependenceAdjustment/EffectiveSampleSize/AttributionConfidence+AssociationSupported 上限)(受入 101) |
| P0-12 baseline 三段階 | I-16 追補(candidate/validate/activate+diff+backtest)(受入 102) |
| P0-13 PendingSensitiveAlerts 漏洩 | §5.15 改訂(通常 probe は Health+ReasonCode のみ、alert 有無は sensitive doctor 限定、Health は liveness のみ)(受入 103,105) |
| P0-14 field allowlist | §5.15 改訂(sink 別 allowlist+ProbeVisibility scope。diagnostics sanitizer 改修を依存明記)(受入 104) |
| §6 基盤の層合成 | §5.16(Grant→ActionGate→mint→atomic consume+dispatch。二重正準禁止) |
| §7 API 修正 | §6 全数反映 |
| §8 評価追加 | §8 全数反映 |
| §9 受け入れ 18 項目 | §9 の 88〜105 に統合 |
| §10 最小修正 13 項目 | 上記各行で全数反映 |
