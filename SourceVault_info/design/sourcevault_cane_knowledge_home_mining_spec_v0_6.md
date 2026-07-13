# SourceVault Cane / Knowledge Home 認知支援マイニングレイヤー仕様 v0.6

- 作成日: 2026-07-12(v0.1)/ 更新日: 2026-07-12(v0.6)
- 状態: **Draft(r5 レビュー全反映+異常分析のワークフロー化(オーナー指示)。v0.5 の 1H 前半(構造的 security)は r5 で採用可能判定済み。本版は v0.5 への差分)**
- 本版 v0.6 の変更(r5 `sourcevault_cane_knowledge_home_mining_spec_v0_5_review.md` 全反映+オーナー指示。対応表は Appendix G):
  1. **Phase 1H を 1H-S(Structural security)と 1H-A(Anomaly analytics)に分割**。1H-S は active enforcement 可、1H-A は observe-only から段階昇格
  2. **異常分析のワークフロー化(オーナー指示)**: §5.14 の統計的異常検知×相関分析は**本体仕様の常駐機構ではなく、独立した分析ワークフロー(Cane Anomaly Workflow)として作成・実行**する。本体仕様が定義するのはスキーマ・契約・保存先のみ。ワークフローは観測専用で何も enforce せず、通知・containment はワークフロー出力を消費する別の昇格ゲートが担う
  3. security 構造の確定(r5 P0-01〜06): CapabilityLease 正準 schema、**PreparedInputToken の provider 境界強制**、taint 伝播 edge 表(content-carrying のみ)、declassification の risk 別要件(owner 確認単独では解除不可)、`RunIntegrityTransitioned`(step 単位遷移)、SafetyState enum の既存小文字への統一(不正値 fail-closed)
  4. 異常分析の統計規律(r5 P0-07〜12): lineage dependence 分類(DirectLineage は相関仮説にしない)、HypothesisStatus の association/causality 分離、仮説段階 containment の上限(TTL/blast radius/rollback)、baseline epoch と poisoning 対策、rate の分母・coverage・CI 必須、事前登録 stream pair、**cold start を不変条件化**(`Missing["InsufficientBaseline"]`)
  5. SystemDoctor 連携の是正(r5 P0-13〜15): `SourceVaultDiagnosticsRegisterProbe` 経由の producer-owned probe、**sensitive local doctor と通常 SystemDoctor probe の二層分離**(通常側は pipeline health と PendingSensitiveAlerts フラグのみ)
  6. 遡及 taint の禁止事項(時間相関のみでは不可)、SafeInspection の詳細要件、owner 向け文言規範(「攻撃されています」等の禁止)
- v0.5 までの本文は変更なし(無印の節は v0.5/v0.4/v0.3 を正とする)

## 0. 目的と結論(v0.6 追補)

r5 の判定を受けて確定する二点:

1. **構造的 security 境界が先、異常分析は後**。統一入口・authority 分離・capability 最小化・taint 非降下・commit 前 gate(1H-S)は detector が見逃しても被害を限定する主防御であり、active enforcement で実装する。
2. **異常分析(1H-A)は「実行するワークフロー」である**(オーナー指示)。状態異常×入力異常の時間相関は研究仮説としての価値をもつが、常駐 subsystem として自動 containment に直結させると、機械的共起の誤認・警報 DoS・可用性毀損・baseline 汚染の危険がある。そこで分析本体を観測専用のバッチワークフローに切り出し、**「分析の実行」「結果の閲覧」「通知」「containment」を別々の昇格段階**にする。

## 2. 不変条件(v0.6 追加・改訂)

**I-14 改訂(r5 P0-03/04/06 反映)**
- **taint 伝播は content-carrying edge に限定**(§4.17c の表)。`Cites / RelatedTo / SameTopic` は ref の存在だけでは伝播しない。伝播 record は `ContributingSpanRefs / PropagationReason / PolicyVersion` を持つ(どの source 部分がどの output に寄与したかを追跡)。
- **declassification の risk 別要件**: 高リスク content の解除は owner 確認**単独では不可**(owner を狙う social engineering 耐性)。要件 = owner 確認 + deterministic sanitizer/test 成功 + safe preview + 元 payload と sanitized projection の差分提示 + release 先と purpose の再確認。owner 確認単独で許すのは local read-only inspection まで。
- **SafetyState enum は既存実装の小文字を正準とする**: `"active" / "warning" / "quarantined" / "unknown"`。security enum は暗黙の大文字小文字正規化をせず、**不正値・未知値は fail-closed**。v0.5 の大文字表記は本版で全て読み替える。

**I-15 改訂(r5 P0-08〜10 反映)**
- 相関仮説の status は **association と causality を分離**する(§4.20 改訂)。`CausalEvidenceSupported` へは決定的 attack chain・隔離による再発停止・controlled replay 等の追加根拠がある場合のみ到達し、**owner 確認だけでは到達しない**。
- 仮説段階の containment(昇格後に解禁される段階でも)には上限を課す: **TTL と自動失効・最大対象件数(input/domain/run)・source scope 最小化・累積 cost/遅延 budget・repeated alert collapse・deterministic safe mode(emergency bypass ではなく)・rollback plan**。`Warning` 昇格は per-input/per-source に限定し、topic/domain 全体へ波及させない。
- **cold start は不変条件**: baseline が最小 sample・最低期間・最低 coverage を満たすまで `Missing["InsufficientBaseline"]` を返し、**通知・containment を一切行わない**(observe-only 蓄積のみ)。
- **baseline poisoning 対策**: `BaselineEpochRef`(固定期間+署名)、model/config/toolchain 変更時の epoch 切替、maintenance/holiday/travel marker、最大更新率、短期 detector と凍結長期 reference の併用、suspected window は pending として確定まで学習に入れない、手動 reset/rollback。
- **owner 状態との相関を送信者 trust/authorization の自動降格に使わない**(security detector の精度向上への利用は可)。

**I-16. 異常分析のワークフロー分離(新設。オーナー指示+r5 §9)**
- 異常検知・相関分析は常駐 subsystem ではなく、**明示的に実行される観測専用ワークフロー**として実装する。ワークフローは event/projection(SensitiveLocalVault / local-only store)への書き込みと report 生成のみを行い、**いかなる enforcement(通知・Warning 昇格・isolation 変更・policy freeze)も直接実行しない**。
- 通知・containment は、ワークフロー出力(hypothesis/recommendation)を消費する**別の昇格ゲート**が担い、r5 §9 のラダーに従う:
  ```
  offline replay → local dashboard のみ → owner opt-in local notification
  → bounded/TTL 付き containment recommendation → 低 risk scope のみ自動 containment
  ```
  高 risk・owner 状態関連の自動 containment は最後まで owner 確認または決定的 security evidence を要する。
- owner 状態を含む分析は SensitiveLocalVault を保持する端末上でのみ実行する(結果も同 vault。マルチデバイス集約はしない。I-1 準拠)。

## 4. データモデル(v0.6 追加・改訂)

### 4.21 CapabilityLease(新設。r5 P0-01)【1H-S】

```
<|LeaseId, IssuerRef,                 (* mint は capability broker のみ *)
  RunRef, ActorRef, CapabilityKind,   (* read/write/network/secret/send/publish/delete は別 lease *)
  AllowedOperation, TargetScope, Purpose,
  MaxPrivacyLevel, DenyTags,
  IssuedAt, ExpiresAt, MaxUses, RemainingUses,
  ParentDecisionRef, RevocationEpoch, SignatureOrMAC|>
```

不変条件: LLM・untrusted tool result は lease を mint/延長/複製できない。lease は run×operation×target×purpose に bind。既定 one-shot・短時間・deny-wins。broker が唯一の検証主体。run containment 時に未使用 lease を一括失効(RevocationEpoch)。lease token/MAC を prompt・ログ・candidate に出さない。**正準基盤(既存 MCP grant/revocation epoch か servicemanager action gate か)は Phase 0 の必須 decision**。

### 4.22 PreparedLLMInput / PreparedInputToken(新設。r5 P0-02)【1H-S】

「入口関数を呼んだ事実」ではなく **provider/executor 境界が token を要求する**構造にする。

```
<|PreparedInputId, InputDigest, InputTrustAssessmentRefs,
  PrivacyDecisionRef, IsolationProfileRef, CapabilityCeiling,
  PolicyVersion, ExpiresAt, MAC|>
```

- provider adapter(`SourceVaultQueryLocalLLM` を含む全実行系)は有効 token なしに外部由来 input を送信しない。
- legacy の生 string API は移行期間中 monitor-only warning(監査 event 化)、期限後は拒否。CI で public LLM entrypoint を列挙し contract 有無を監査。mock/test 経路も明示 `TestBypassRef` なしに迂回不可。

### 4.17c taint 伝播 edge 表(新設。r5 P0-03)【1H-S】

| EdgeKind | 伝播 |
|---|---|
| `DerivedFrom` / `Contains` / `ExtractedFrom` / `SummarizedFrom` | 必須 |
| `QuotedFrom` | 引用 span の寄与範囲へ伝播 |
| `AttachmentOf` | attachment を実際に読んだ artifact へ伝播 |
| `Cites` / `RelatedTo` / `SameTopic` | ref の存在だけでは伝播しない |
| `OwnerReviewed` | 自動 declassification を意味しない |

### 4.18b RunIntegrityTransitioned(新設。r5 P0-05)【1H-S】

`RunIntegrityState` は projection とし、正準は step 単位の遷移 event:

```
<|RunRef, StepRef, FromState, ToState, TriggerObservationRefs,
  EffectiveFromUTC, AffectedArtifactRefs, PolicyVersion|>
```

CandidateArtifact は**生成 step 時点の integrity snapshot** を参照する(run 後半の CompromiseSuspected が開始直後の決定的 artifact を一律不採用にしない。逆に最終 Clean が途中異常を隠さない)。

### 4.20 改訂: 異常分析スキーマ(r5 P0-07/08/10/11)

**anomaly event への追加(rate の分母と品質)**:

```
追加: ExposureCount, EventCount, MissingCount, CoverageRatio,
      ConfidenceInterval, BaselineSampleCount, BaselineEpochRef, DataQualityFlags
```

収集停止による rate 低下を「改善」と誤認しないよう、liveness と coverage を同時評価する。

**lineage dependence(相関前の必須分類)**:

```
LineageDependence -> "DirectLineage"       (* 同じ InputRef/RunRef 由来の機械的関係。
                                              相関仮説にせず既知 provenance chain として扱う *)
                   | "SharedUpstream"      (* 同じ campaign/source 群を共有 *)
                   | "IndependentStreams"  (* provenance 上独立 — 統計的相関の価値はここ *)
                   | "UnknownDependence"
```

**HypothesisStatus(association/causality 分離)**:

```
"Hypothesized" | "AssociationSupported" | "AssociationRefuted" |
"MechanicallyCoupled" | "CommonCauseLikely" | "CausalEvidenceSupported" |
"InsufficientEvidence"
```

**相関設計の事前登録(r5 P0-12)**: 対象 stream pair・許容 lag 範囲・最小 effect size・最小 overlap window 数・autocorrelation を考慮した empirical null/permutation・missing data 規則・FDR family 単位・hypothesis dedup/cooldown・holdout 期間での閾値評価・method/version 変更時の baseline reset を、ワークフロー設定(`AnomalyWorkflowProfile`)として**事前登録**する。全組み合わせの探索的解析は研究ビュー限定とし、通知 pipeline に接続しない。

## 5. 機能仕様(v0.6 改訂)

### 5.13 追補: SafeInspection の詳細要件(r5 §8)【1H-S】

local-only・no-tools・no-network・no-secret・output schema 限定・**output も tainted**・KH/通常 search index へ自動保存しない・raw payload を Notebook へ自動描画しない・hidden text/URL/image は非活性表示・copy/export 時に明示 warning・bounded input/output size と timeout・inspection run 終了時に capability lease 全失効。

### 5.14 全面改訂: Cane Anomaly Workflow(観測専用の分析ワークフロー)【1H-A】

**位置づけ(オーナー指示)**: 統計的異常検知×相関分析は本体の常駐機構ではない。本体仕様が定義するのは (a) スキーマ(§4.20)、(b) ワークフローが従う契約(I-15/I-16)、(c) 保存先と閲覧面、のみ。分析本体は**独立ワークフローとして作成し、明示的に実行する**。

**実行形態**:
- 実装は LLM を使わない決定的バッチ(外部 wolframscript ワーカー)。FE 非ブロック(I-8)。ClaudeOrchestrator は不要(LLM ステップが無いため)。将来ステップが増えれば `ClaudeOrchestrator` Workflow` に載せ替え可。
- 起動: 手動(`SourceVaultRunCaneAnomalyWorkflow[]`)または低頻度スケジュール(service hook。既存の参照イベント rollup hook と同様の頻度クラス)。
- 段階(ワークフロー内部): ①baseline 維持(epoch 管理・pending window 処理)→ ②stream 別逸脱検知(分母・coverage 付き)→ ③lineage dependence 分類 → ④事前登録 pair のみ相関 → ⑤hypothesis 生成(Hypothesized)→ ⑥report 出力。
- **ワークフローは書き込みと report のみ**。通知・Warning 昇格・isolation 変更・policy freeze・遡及 taint はワークフローの権限外(I-16)。

**出力と閲覧**:
- 出力は SensitiveLocalVault(owner 状態を含む分)/ local-only telemetry(LLM 分)への event/projection と、`SourceVaultCaneSensitiveDoctor[]`(local 詳細ビュー: 逸脱一覧・仮説・lineage 分類・分母/coverage・推奨事項)。
- 昇格ラダー(I-16)の初期段階では **local dashboard のみ**。owner opt-in の local notification、TTL 付き containment recommendation、低 risk 自動 containment は、§8 の評価ゲートを通過した段階でのみ順に解禁する。

**遡及 taint の禁止事項(r5 §7)**: 時間相関だけでは遡及 taint しない(`NeedsReview` tag まで)。遡及 taint の要件 = concrete source/span と derived artifact の lineage + `CausalEvidenceSupported` または決定的 compromise chain + affected span/artifact の明示列挙 + **dry-run impact report + max blast radius + reversible quarantine projection**(active index からの除外と原本保持の分離)+ owner への安全な説明。

**owner 向け文言規範(r5 §6)**: 事実ベースに限定する。可: 「最近の外部入力パターンと操作支援 signal に、通常と異なる同時変化がありました。因果関係は確認されていません。疑わしい入力を安全モードで確認しますか。」 不可: 「攻撃されています」「認知状態が低下した原因はこのメールです」「この送信者があなたを操作しました」。

### 5.15 SystemDoctor / diagnostics 連携の是正(r5 P0-13〜15)【1H-A】

- **producer-owned probe**: `SourceVaultMakeDiagnosticProbe`(mining 層の対象 URI 検査)は使わない。Cane 側が probe/view を実装し、`SourceVaultDiagnosticsRegisterProbe[id, probeFn]` で弱く冪等に登録する(rule 11)。doctor は `SourceVaultDiagnosticsLightweightDoctor[]`、必要時のみ `SourceVaultDiagnosticsEscalate[event]`。
- **二層分離**:
  1. `SourceVaultCaneSensitiveDoctor[]` — SensitiveLocalVault 内の local 詳細ビュー(owner 状態・相関仮説・CandidateCauseRefs)。**local UI 限定**。
  2. 通常 SystemDoctor probe(`SourceVaultCaneDiagnosticsProbe[]`)— **`DetectorPipelineHealth -> OK|Degraded|Failing` と `PendingSensitiveAlerts -> True|False` のみ**。owner 状態の stream 種別・異常 window・hypothesis ID・SensitiveLocalVault への URI/dereference 可能な ID を含めない。
- 通常 diagnostics log・heartbeat・multi-machine rollup・cloud・診断メールに sensitive 参照を出さない。外部通知が必要な場合は「ローカルで要確認」の固定文のみ。
- 検知パイプラインの liveness は通常 probe 側(`DetectorPipelineHealth`)で監視する(「緑のまま死亡」防止は維持)。

## 6. Public API(v0.6 改訂)

```
(改名・分離)
SourceVaultCaneDiagnosticsProbe[]            (* sanitized health のみ。DiagnosticsRegisterProbe で登録 *)
SourceVaultCaneSensitiveDoctor[]             (* local 詳細ビュー(SensitiveLocalVault) *)
SourceVaultRegisterCaneDiagnostics[]         (* weak/idempotent 登録 *)
SourceVaultRunCaneAnomalyWorkflow[opts]      (* 観測専用ワークフロー実行。enforcement 権限なし *)
(廃止) SourceVaultSystemDoctorCaneSection[]  (* diagnostics 本体へのハードコードをやめる *)

(追加)
SourceVaultMintCapabilityLease[...]          (* broker 専用。§4.21 *)
SourceVaultPreparedInputToken[...]           (* §4.22。provider 境界が要求 *)
```

`SourceVaultDetectStreamAnomalies` / `SourceVaultCorrelateAnomalies` はワークフロー内部関数となり、単体呼び出しも observe-only 契約(I-16)を継承する。

## 7. フェーズ(v0.6 改訂: 1H の二分割)

### Phase 1H-S: Structural security(active enforcement 可)
- r5 P0-01〜06 の修正(CapabilityLease 正準・PreparedInputToken 境界強制・taint edge 表・declassification 要件・RunIntegrityTransitioned・SafetyState enum 統一)
- v0.5 の P0-01〜05 是正(SummarizeText QuarantinePolicy 等)・candidate/KH commit gate・SafeInspection sandbox(§5.13 追補)・red-team fixture
- DoD: §8(10.1)の指標 green(PreparedInputToken なし provider call ゼロ、lease 偽造/期限切れ拒否、taint 過剰伝播/漏れの edge 別測定、declassification false release ゼロ、SafeInspection 漏出ゼロ、integrity transition の時系列整合)

### Phase 1H-A: Anomaly analytics(観測専用ワークフロー。1H-S 完成後に有効化)
- baseline epoch/data quality → State/Input anomaly の observe-only 生成 → lineage 分類 → 事前登録 pair のみの相関 → sensitive local doctor → shadow alert 評価
- 昇格: offline replay → local dashboard のみ → owner opt-in local notification → bounded/TTL 付き containment recommendation → 低 risk scope のみ自動 containment(各段に §8(10.2)の評価ゲート)
- **anomaly analytics は structural security 完成前に active containment へ使わない**(受入 86)

## 8. 評価計画(v0.6 追加)

**10.1 構造的 security(r5)**: PreparedInputToken なし provider call 件数 / expired・replayed・forged lease 拒否率 / taint edge 別の過剰伝播率・伝播漏れ率 / declassification false release / SafeInspection からの永続化・clipboard・export 漏れ / run integrity transition の artifact 時系列整合性。

**10.2 anomaly analytics(r5)**: lineage-coupled pair の誤 hypothesis 生成率 / **baseline cold-start 中の通知件数(必須ゼロ)** / slow drift attack 検知率 / maintenance・holiday 変化の false alarm / alert・containment DoS 耐性 / hypothesis ごとの blast radius / TTL 後の containment 解除・rollback 成功率 / **association と causal evidence の混同件数(必須ゼロ)** / **sensitive metadata の diagnostics・cloud・mail 到達件数(必須ゼロ)**。

## 9. 受け入れ基準(v0.6 追加。1〜66 は既存。63〜65 は本版の I-15/I-16 改訂で読み替え)

67. capability lease が run/action/target/purpose へ署名付きで bind され、LLM が mint/延長できないこと
68. provider/executor 境界が有効な PreparedInputToken を要求すること(監査は CI 列挙+移行期限後の拒否)
69. taint が content-carrying edge だけを伝播し、`RelatedTo`/`SameTopic` だけでは伝播しないこと
70. declassification に risk 別の sanitizer/test/owner 確認が必要で、owner 確認単独では高リスク解除ができないこと
71. RunIntegrity が step 単位 transition を持ち、candidate が生成時点の snapshot を参照すること
72. SafetyState enum が既存実装(小文字)と一致し、不正値が fail-closed になること
73. 相関前に lineage dependence が分類され、DirectLineage が因果仮説として生成されないこと
74. HypothesisStatus が association と causal evidence を区別し、owner 確認だけで CausalEvidenceSupported に到達しないこと
75. 仮説段階(および昇格後)の containment に TTL・scope・件数・cost・rollback の上限があること
76. baseline 不足時は `Missing["InsufficientBaseline"]` で observe-only となり、通知・containment が発生しないこと
77. baseline が epoch/version/maintenance marker を持ち、suspected/pending 期間を学習しないこと
78. rate anomaly が分母(ExposureCount 等)・coverage・CI・data quality を持つこと
79. 通知対象 stream pair・lag・effect size・FDR family が事前登録されていること
80. SystemDoctor 連携が `SourceVaultDiagnosticsRegisterProbe` 経由で producer-owned に実装されること
81. 通常 SystemDoctor/heartbeat/cloud/mail に owner 状態種別・window・hypothesis ID・SensitiveLocalVault ref が出ないこと
82. full Cane anomaly view が SensitiveLocalVault 内の local UI に限定されること
83. 時間相関だけで CandidateCauseRefs が遡及 taint されないこと(`NeedsReview` まで)
84. 遡及 taint 前に lineage・impact dry-run・blast radius・rollback が確認されること
85. SafeInspection が local/no-tools/no-network/no-persist であること
86. anomaly analytics が structural security(1H-S)完成前に active containment へ使われないこと
87. **異常分析がワークフローとして実行され(常駐 enforcement なし)、ワークフロー自体に通知・containment・taint 変更の権限が無いこと**(I-16。オーナー指示)

## 10. Open issues(v0.6)

1. CapabilityLease の正準基盤選定(MCP grant/revocation epoch vs servicemanager action gate)— Phase 0 必須 decision
2. PreparedInputToken の legacy 移行期限と監査運用(CI での entrypoint 列挙の自動化)
3. AnomalyWorkflowProfile の初期事前登録セット(どの stream pair から始めるか — 推奨初期値: InjectionSignalRate×RunIntegrityRate(SharedUpstream 検出用)と MailSenderNovelty×OwnerOperationalSignal の 2 pair のみ)
4. ワークフローのスケジュール頻度と実行コスト(service hook の頻度クラス)
5. v0.5 からの継続分(claim 正規化 / RequiredEvidencePolicy / AttackFamily 語彙 / ほか)

## Appendix G: r5 レビュー+オーナー指示 対応表

| 項目 | 反映箇所 |
|---|---|
| r5 §9 Phase 1H 二分割 | §7(1H-S / 1H-A)+受入 86 |
| **オーナー指示: §5.14 はワークフローとして作成・実行** | I-16 / §5.14 全面改訂(観測専用バッチ、enforcement 権限なし、昇格ゲート分離)/ §6 `SourceVaultRunCaneAnomalyWorkflow` / 受入 87 |
| r5 P0-01 capability lease 未定義 | §4.21(schema+不変条件+正準基盤は Phase 0 decision)(受入 67) |
| r5 P0-02 統一入口の迂回路 | §4.22 PreparedInputToken 境界強制+legacy 移行+CI 監査+TestBypassRef(受入 68) |
| r5 P0-03 taint 過剰伝播 | I-14 改訂+§4.17c edge 表+ContributingSpanRefs(受入 69) |
| r5 P0-04 declassification の social engineering 耐性 | I-14 改訂(risk 別要件、owner 単独不可)(受入 70) |
| r5 P0-05 RunIntegrity の step 単位化 | §4.18b RunIntegrityTransitioned(受入 71) |
| r5 P0-06 SafetyState 大小文字 | I-14 改訂(小文字正準・不正値 fail-closed)(受入 72) |
| r5 P0-07 lineage 相関の誤認 | §4.20 LineageDependence(DirectLineage は仮説にしない)(受入 73) |
| r5 P0-08 Confirmed の意味過剰 | §4.20 HypothesisStatus 分離+I-15 改訂(受入 74) |
| r5 P0-09 仮説段階 containment の害 | I-15 改訂(TTL/blast radius/rollback/alert collapse/safe mode)(受入 75) |
| r5 P0-10 baseline poisoning/cold start | I-15 改訂(epoch/marker/凍結 reference/pending/InsufficientBaseline 不変条件化)(受入 76,77) |
| r5 P0-11 rate の分母欠如 | §4.20 改訂(ExposureCount/CoverageRatio/CI/DataQualityFlags)(受入 78) |
| r5 P0-12 多重性・自己相関 | §4.20 事前登録(AnomalyWorkflowProfile)+探索解析は研究ビュー限定(受入 79) |
| r5 P0-13 DiagnosticProbe 誤用 | §5.15(DiagnosticsRegisterProbe/LightweightDoctor/Escalate)(受入 80) |
| r5 P0-14 owner metadata の漏洩 | §5.15 二層分離(sensitive local doctor / sanitized probe)(受入 81,82) |
| r5 P0-15 producer 所有 | §5.15+§6 改名(CaneDiagnosticsProbe/RegisterCaneDiagnostics)(受入 80) |
| r5 §6 owner 文言 | §5.14 文言規範+trust 自動降格禁止(I-15) |
| r5 §7 遡及 taint 条件 | §5.14(NeedsReview まで/CausalEvidenceSupported+dry-run+blast radius+reversible)(受入 83,84) |
| r5 §8 SafeInspection 詳細 | §5.13 追補(受入 85) |
| r5 §10 評価追加 | §8(10.1/10.2 全数) |
| r5 §11 受け入れ 20 項目 | §9 の 67〜86 に統合 |
| r5 §12 最小修正 14 項目 | 上記各行で全数反映 |
