# SourceVault Cane / Knowledge Home 認知支援マイニングレイヤー仕様 v0.1

- 作成日: 2026-07-12
- 状態: **Draft(r0、レビュー未)**
- 対象:
  - 新規 `SourceVault_knowledgehome.wl`(Knowledge Home 閲覧/追記/位置づけ/近傍提案)
  - 新規 `SourceVault_cognition.wl`(想起レベル/認知レベル/信頼度/ガード。秘匿クラス最上位)
  - 既存の拡張: `SourceVault_oopsseed.wl` / `SourceVault_mailsuggest.wl` / `SourceVault_mining.wl` / `SourceVault_searchindex.wl` / `SourceVault_lexical.wl` / `SourceVault_identity.wl` / `SourceVault_maildb.wl` / `SourceVault_llmlog.wl` / `SourceVault_diagnostics.wl`
- 依拠資料:
  - 今井: 「思考のための杖: 一人称視点による認知症患者の思考支援システム設計における諸問題」(SSI2019) — 実装目的と展望の正準
  - cane3.pdf 抜粋(`ドキュメント/資料.pdf`) — Knowledge Home / topic item field / associative(想起) level / cognitive level / privacy level / me' / compress items の概念図
  - 参考: Masui 近傍検索(Neighbor Hopping)、Toffoli Knowledge Home、Lieder cognitive prostheses
- 前提仕様(全て準拠。**本仕様は既存機構の上に載る利用層であり、既存の正準を再定義しない**):
  - `sourcevault_llmwiki_datastore_requirements_draft.md`(event 基盤/AccessLevel 正準/ObjectInteractions/ObjectSignals)
  - `sourcevault_self_organizing_mining_identity_tag_spec_v0_1.md`(MiningObject/assertion/記憶代謝)
  - `sourcevault_search_foundation_implementation_spec_v1.md`(BM25/seed 辞書/KG 局所展開/SearchView/**§6.7 associative level**/retrieval episode)
  - `sourcevault_general_mail_structuring_spec_v0_1.md`(TopicVocabulary/MailRelationGraph)
  - `sourcevault_universal_mcp_access_spec_v2.md`(EffectiveAccessLevel 合成/OutputPrivacyEstimate/AccessProfile)
  - `sourcevault_auto_trigger_scheduler_spec_v0_1.md` + diagnostics SIEM 方針(弱結合 emit)

## 0. 目的と結論

**目的**: oops メーリングリスト(1992–2005、約6500通・約4100 topic item・引用/トピックリンク約4万本)を**ベースオントロジ(Knowledge Home)**とし、SourceVault の全データ(メール/ノートブック/Eagle/プロンプトログ)をそのトピックアイテム空間上に位置づける。その上で:

1. オーナーが**現在考えていることに近い位置**を推定し、周辺の関連事項を提案する(近傍検索・Neighbor Hopping)
2. 思考が**ループに陥らず前進する**ことを支援する(newer ノードへの誘導、類似反復の圧縮提案)
3. システム利用状況から**オーナーの認知レベルを推定**し、タスクの検証レベルと情報提示の粒度・件数を可変にして、**取り返しのつかないミス(誤送信・privacy 降下・締切/返信忘れ)を予防**する
4. メール送信先等の**信頼度**を identity 基盤上で推定し、リスク操作のゲートに供する

対象は認知症に限らず、高次脳機能障害・加齢・発達障害・健常者の日内変動を含む**あらゆる認知能力変動**である(SSI2019 §5)。

**結論(設計方針)**: 中核部品はほぼ実装済みである。oops 構造化(`SourceVault_oopsseed.wl`)、検索基盤(BM25+seed 辞書+KG 局所展開)、ObjectInteractions/ObjectSignals、identity/送信ゲート、llmlog digest が存在する。本仕様の新規部分は:

- (a) **Knowledge Home 閲覧/追記層**(NB ハイパーテキスト+oops 文法での拡張追記)
- (b) **OntologyPosition**(全 object の topic 空間座標 projection)と**近傍提案/前進支援**
- (c) **認知層**(RecallLevel / CognitiveLevel / TrustAssessment / Guard)— search foundation §1.2 が「本仕様の対象外」として明示的に切り出した部分の受け皿

当座実装(Phase 1)と中長期(Phase 2/3)は §7 で分離する。各節の【P1】【P2】【P3】マークが対応する。

## 1. 概念モデルと用語(資料 → SourceVault 語彙マッピング)

| 資料/論文の概念 | 本仕様の用語 | 実体(既存 or 新規) |
|---|---|---|
| Knowledge Home / oops mailing list | ベースオントロジ | 既存 `SourceVaultSeedEntityDictionary` + seed relation graph + `SourceVaultParseOOPSMailFile`(read-only) |
| topic item(ki xxx 等、人手命名) | TopicItem | 既存 `svtopic:oops:<ns>:<localId>`(owner-scoped namespace) |
| paragraph(◎○・付きテキストブロック) | Paragraph | 既存 `svmailpara:` / 新規追記は `svkhpara:`(§4.2) |
| paragraph quoting graph | QuoteEdge / TopicItemGraph | 既存 `SourceVaultMailQuoteEdge` / `SourceVaultTopicItemGraph` |
| session(1メール)/ cluster(議論のまとまり) | MailSession / Cluster | 既存 `SourceVaultMailSession`(SessionKind)。cluster 長推定は新規(§5.4) |
| associative level(ノード毎・変動する想起可能度) | **RecallLevel**(想起レベル) | 新規 event `RecallLevelSampled` + projection(§4.4)。search foundation §6.7 の associative level と同一概念で、名称を RecallLevel に正準化(オーナー状態の CognitiveLevel との混同防止) |
| cognitive level(オーナーの時刻依存状態、ノード作成時に付与) | **CognitiveLevel**(認知レベル) | 新規 event `CognitiveLevelSampled` + 現在値関数(§4.5) |
| privacy level(omote/ura、降下操作の検出) | AccessLevel / PrivacyLevel | 既存正準(0–1、大きいほど厳格)。降下検出は Guard(§5.7) |
| The desired behavior(closest node 推定→3リング提案→newer 誘導) | ThinkingContext + NeighborhoodSuggest | 新規(§5.4) |
| variable briefing level / encode 表示 | BriefingProfile | 新規(§5.5)。P1 は件数絞りのみ、P2 で粒度可変 |
| compress items created by similar repetitions | SimilarNode 通知 / CompressedNode | 新規 P2(§5.6)。**何も削除しない**(圧縮は新ノード+edge) |
| me'(自律 lifelog エージェント) | me' 起票 | 既存 ingest 群(llmlog/webingest/mail service)が初期形。パラグラフ自動起票は P2/P3(§5.8) |
| 送信先信頼度 | TrustAssessment | 新規 projection(§4.6)。既存 `ContactAccessProfile`/`SourceVaultResolveRecipientProfile`(fail-closed)の上に載る |
| 認知変動の6問題(検索不能→…→準備者忘却) | §5.9 の対応表 | P1: 問題1 / P2: 問題2,3,4 / P3: 問題5,6 |

用語の峻別(重要): **RecallLevel はノード(paragraph/topic)の属性の時系列**、**CognitiveLevel はオーナー(または人/LLM エンティティ)の属性の時系列**である。SSI2019 の「認知レベルはメール作成時にパラメータとして添付され、後日そのメールの信頼性判断に使う」は、「object 作成 event に当時の CognitiveLevel スナップショットを刻む」(§4.3)として実現する。

## 2. 不変条件(安全境界)

**I-1. 認知系データの秘匿(クラウド禁止)**
CognitiveLevel / RecallLevel / ThinkingContext / TrustAssessment(対人)/ Guard 判断ログは:
- 値・projection: `AccessLevel -> 1.0`、`Tags -> {PrivateBehaviorLog, NoCloudLLM, NoPublicExport}`。保存先は PrivateVault(既存 retrieval episode store と同クラス)。
- 特徴量 raw(打鍵内容・プロンプト本文断片・将来の音声/映像特徴): **同期しない `LocalState` のみ**。Dropbox にも置かない。event には集約値と Basis(粗い区分)のみ。
- MCP surface は**既定 deny**(既存 ObjectInteractions raw と同じ扱い)。prompt/ログ/トレースへは粗い tier(`Low|Mid|High`)のみ出してよい。数値そのものを LLM prompt に入れない。
- LLM で処理する場合(自己報告文の解析等)は `SourceVaultQueryLocalLLM`(LM Studio、UNTRUSTED 隔離)に限定。

**I-2. 単調安全性(認知レベルは gate を緩めない)**
CognitiveLevel の作用は次の 3 方向**のみ**: (a) リスク操作の検証レベルを**引き上げる** (b) 提示候補数・粒度を**絞る** (c) ランキング/表示順を変える。
- 「認知レベルが高いから privacy 降下を自動許可」は禁止。降下操作は常に人の明示確認(既存 release gate)を要する。
- camouflage(資料 p17)は P3 の研究課題とし、倫理レビュー完了までいかなる形でも実装しない(§9)。
- search foundation §6.7 の境界(associative level は ranking/presentation 専用)をそのまま継承する。

**I-3. ベース不変(write-once)**
oops 原アーカイブ(`oops*.txt`)と gold index(`item-name.index` 等)は read-only。拡張(新パラグラフ・新 topic item・annotation)はすべて event + extension projection で表現し、原本ファイルを変更しない。**何も削除しない**: 訂正は Supersede、圧縮は CompressedNode + edge(資料 p18 "The system never delete anything")。

**I-4. 既存 gate 全経由**
閲覧/検索/提案/View は `ReleaseContext` + request-time release gate + revocation set を必ず通る(SearchView と同一)。oops-ura 系は既存どおり `PrivacyLevel 0.6+ / {PrivateML, NoCloudLLM, NoPublicExport}`、`"CloudSafe"->True` で deny。トピック**ラベル自体が漏洩源**になる点(general_mail §1.3)に留意し、private scope の語彙を cloud/public scope の vocabulary・prompt に混入させない。

**I-5. bounded influence**
位置・近傍・重要度による boost は既存の bounded boost 規約(MaxBoost 0.2、LLM 寄与 0.7 係数、OwnerDismissed 抑制)を踏襲。RecallLevel/CognitiveLevel が検索スコアに与える影響も同じ上限クラスに置く。importance/recall で AccessLevel/DenyTag/SafetyState を緩めない。

**I-6. ゆるい運用(自動運転ではない)**
資料 p13/p15 の「秘訣はゆるく運用すること 自動運転とは違う!」を規約化する: auto-confirm 既定 off、me' 起票は `ReviewState -> "Pending"`、通知は rate limit(autotrigger 規約)、提案は非侵襲(明示要求 or 静かなサイドリスト)。推定の誤りが操作をブロックしないこと(検証レベル引き上げ=確認回数増であり、禁止ではない)。

**I-7. 可搬性(数十年維持・ブートストラップ移行可能)**
正準データは JSONL / markdown / 既存 index 形式(プレーンテキスト系)のみ。dense embedding・グラフキャッシュ・OntologyPosition は**再生成可能な cache**(Dropbox 外 `$UserBaseDirectory/SourceVault/cache/`)であり正準に昇格させない。SSI2019 制約1(汎用フォーマット)に対応。

**I-8. FE 非ブロック**
LLM 呼び出し・大規模索引再構築を FE メインカーネルで同期実行しない(既知のフリーズ事例に対する規約)。service / 外部 wolframscript ワーカー / `Submit*`+`AwaitJob` / ClaudeOrchestrator 経由とし、FE は軽量 tick と cache 読みのみ。

## 3. アーキテクチャ(層構成)

```
L0 ベースオントロジ      oopsseed(既存): seed辞書 / relation graph / quote / session / chunk / primer
L1 Knowledge Home 層     【P1】NB ハイパーテキスト閲覧 + oops 文法での追記(拡張パラグラフ)
L2 位置づけ層            【P1→P2】OntologyPosition: 全 object の topic 空間座標 projection
L3 思考文脈層            【P1→P2】ThinkingContext 推定 + 近傍提案(3リング) + 前進支援
L4 認知層                【P1最小→P2】RecallLevel / CognitiveLevel 推定、BriefingProfile
L5 ガード層              【P1最小→P2】TrustAssessment + TaskValidationLevel + 送信/公開ゲート強化
```

依存方向: L5→L4→L3→L2→L1→L0(下位は上位を知らない)。L4/L5 は `SourceVault_cognition.wl` に分離(秘匿クラスが異なるため)。L1–L3 は `SourceVault_knowledgehome.wl`。

信号の流れ: ObjectInteractions(閲覧/リンク追跡)と llmlog digest(プロンプト)→ L3 位置推定と L4 認知推定 → L3 の提案ランキングと L5 の検証レベル → View の提示。diagnostics sink が存在するときのみ弱結合で SIEM へ emit(rule 11)。

## 4. データモデル

### 4.1 OntologyPosition(projection、cache)【P1】

全 SourceVault object の「oops トピック空間上の位置」。正準ではなく再生成可能 projection。

```
<|ObjectClass -> "SourceVaultOntologyPosition",
  ObjectURI,                      (* sv://mail/<RecordId> / svnb:... / sveagle:... / svkhpara:... *)
  TopicWeights -> <|"svtopic:oops:ki:1373" -> 0.42, ...|>,   (* 疎ベクトル、上位K件のみ *)
  AnchorTopicRefs,                (* 明示マーカー/HumanConfirmed 由来(重み1.0固定) *)
  Method -> "SeedMatched"|"RelationExpanded"|"DenseProjected"|"LLMProposed"|"HumanConfirmed",
  Confidence, ComputedAtUTC, PipelineVersion|>
```

- 計算パイプライン(既存部品の合成): ①`SourceVaultAssignParagraphTopics`(SeedMatched)→ ②relation graph 1-hop(RelationExpanded)→ ③【P2】ローカル embedding(bge-m3)で seed chunk への近傍射影(DenseProjected)。confidence 序列は既存規約(SeedMatched > RelationExpanded > AutoExtracted)。
- 保存: cache dir に shard(`positions/<class>/<yyyymm>.jsonl`)。AccessLevel は元 object を継承(下回れない)。

### 4.2 Knowledge Home 拡張パラグラフ【P1】

oops 文法(◎○・+ `[ns id]`、`-*- Quote (from n) -*-`)を維持した追記。1追記 = 1 event。

```
event: KnowledgeHomeParagraphAdded
<|ParagraphRef -> "svkhpara:<serial>",       (* 追記シリアル、oops Counter の続きではなく独立採番 *)
  Body,                                       (* oops 文法テキスト *)
  TopicRefs,                                  (* 明示マーカー抽出結果 *)
  QuoteEdges,                                 (* 引用先 svmailpara:/svkhpara: *)
  PrivacyLevel, Tags,                         (* omote/ura 相当を owner が指定、既定は ura 相当 0.6 *)
  CognitiveLevelAtCreation,                   (* §4.3、tier のみ(Low|Mid|High)。数値は cognition 側 *)
  CreatedAtUTC, DeviceID|>
```

- **新規 topic item の採番**: 第一候補は既存 TopicVocabulary の決定的 ref `svtopic:auto:<owner>:<normLabelHash>`(冪等)。owner が oops 流の明示採番を望む場合は `SourceVaultKnowledgeHomeMintItem[label]` が `svtopic:oops:ki:<max+1>` を extension index(`kh-item-extension.jsonl`)に発行する(gold index は不変。event `KnowledgeHomeTopicItemMinted`)。seed 辞書ロード時に extension を合流。
- 追記は既存 `SourceVaultBuildMailChunks` 相当で chunk 化され、lexical index に増分投入される(検索対象に即時参加)。

### 4.3 作成時認知スナップショット【P1最小】

SSI2019「認知レベル[0,1]はメール作成時にパラメータとして添付」の実現。KH 追記・メール送信・公開系操作の event に `CognitiveLevelAtCreation -> "Low"|"Mid"|"High"|Missing["NotEstimated"]` を刻む(tier のみ。数値と根拠は cognition 側 event に分離し、参照は EventID リンクで)。後日の読解時に「その記述の信頼性」の判断材料として View に表示できる(資料 p16 "It reflects a kind of reliability of the data")。

### 4.4 RecallLevel(想起レベル)【P1最小→P2】

paragraph / topic item ごとの (値, timestamp) 追記列。SSI2019 Fig.6 の縦軸。

```
event: RecallLevelSampled
<|TargetURI, Value(0-1), Basis -> "Created"|"Viewed"|"DwellTime"|"FollowedLink"|"Cited"|
                                   "SelfReport"|"AskedAndRecalled"|"AskedAndForgotten"|"Decayed",
  DwellSeconds -> _?NumberQ|Missing, Confidence, SampledAtUTC, DeviceID|>
projection: SourceVaultRecallLevel[targetURI] ->
<|Current, Samples, Trend, LastRecalledAt, EstimatedTier -> "Frequent"|"Recallable"|"Forgotten"|>
```

- P1 の供給源は既存 ObjectInteractions(Open/Read/FollowedLink/Cite)からの機械的変換のみ(閲覧=想起の弱い証拠)。減衰(`Decayed`)は再計算時の合成サンプルとし、**コンテンツの古さに decay をかけない**既存原則と両立させる(decay がかかるのは「想起可能性の推定」であって重要度ではない)。
- P2 で dwell time / スクロール計測、閾値以下での能動確認(「覚えていますか」ダイアログ、SSI2019 の "Just ask me directly")を追加。

### 4.5 CognitiveLevel(認知レベル)【P1最小→P2/P3】

オーナー(将来は任意エンティティ/LLM)の時刻依存状態。`(subject, timestamp) -> [0,1]` の推定関数。

```
event: CognitiveLevelSampled          (* AccessLevel 1.0 / NoCloudLLM / MCP deny *)
<|SubjectRef -> "ent-owner",
  Value(0-1), Tier -> "Low"|"Mid"|"High",
  Basis -> <|"RetryLoopRate"->_, "TypoRate"->_, "LatePromptRate"->_,
             "MailReplyLatencyHours"->_, "ScheduleMissCount"->_, "SelfReport"->_|>,
                                       (* 集約値のみ。原データは LocalState *)
  Method -> "PromptProxyV1"|"SelfReport"|"Composite",
  Confidence, WindowStart, WindowEnd, SampledAtUTC, DeviceID|>
```

- **P1 の推定器(PromptProxyV1)**は保守的な粗い proxy に限定: llmlog digest からの (a) 同一意図の再試行/やり直しループ率 (b) プロンプト修正率(連続プロンプトの編集距離)(c) 深夜比率、maildb からの (d) 返信遅延、NotebookExtensions iCal / $onWork 突合からの (e) 締切・行事準備の見落とし数。EWMA で平滑化し、Confidence は常に Low〜Medium。
- **校正**: 任意の日次 self-report(1–5)を supervised アンカーにする(資料 p15 "Just ask me directly!")。ground truth なしの数値を過信しない — P1 では **Tier(3値)以外を下流に見せない**。
- マルチデバイス: 各機の event を既存 rollup 規約(`<CoreRoot>/rollup/cognition/<MachineTag>/YYYY-MM.jsonl`)で集約、EventID dedup。
- P2/P3 で音声/カメラ/バイオメトリクス特徴を Basis に追加(チャネルは diagnostics/SIEM の producer 所有・弱結合 emit 方式)。

### 4.6 TrustAssessment(信頼度)【P1最小→P2】

`(subject, timestamp) -> [0,1]` の推定。subject は `ent-`/`idf-`(人)または model AccessProfile(LLM)。

```
event: TrustEvidenceRecorded
<|SubjectRef, Kind -> "Recipient"|"Source"|"LLM",
  Evidence -> "AuthenticatedMail"|"DeliveryAnomaly"|"LongInteractionHistory"|
              "OwnerGrade"|"BouncedOrSpoofed"|"ManualPin",
  Weight, SourceRef, RecordedAtUTC|>
projection: SourceVaultTrustLevel[subjectRef] ->
<|Value, Tier, EvidenceCounts, LastEvidenceAt, FailClosedDefault -> True|>
```

- 既存基盤との関係: 未知送信先は既存どおり fail-closed(`MaxPlaintextPL 0.0`)。TrustAssessment は**既存 ContactAccessProfile を緩める側には使わない**(I-2 と同型の単調性)。使途は (a) Guard の警告強度 (b) 提案候補の並び (c) View での表示。
- LLM の信頼度は既存 AccessProfile(TrustDomain/MaxAccessLevel)を正とし、TrustAssessment はその上の観測履歴(成功/失敗、hallucination 検出)の記録面とする。

### 4.7 ThinkingContext【P1】

「いまオーナーが考えていること」の推定位置。秘匿クラスは認知系(I-1)。

```
<|ContextId, WindowStart, WindowEnd,
  SignalRefs,                          (* llmlog session, 直近 KH 閲覧 interaction, 直近メール閲覧 *)
  EstimatedPosition -> <|topicRef -> w, ...|>,
  NearestSessions -> {MailSessionId..},
  LoopScore,                           (* 同一 topic 集合の再訪度(新規ノード作成なし) *)
  ClusterLengthEstimate,               (* 直近 cluster 長(=短期記憶で支えられる思考長の proxy) *)
  ComputedAtUTC|>
```

### 4.8 新規 event class 一覧

`KnowledgeHomeParagraphAdded` / `KnowledgeHomeTopicItemMinted` / `RecallLevelSampled` / `CognitiveLevelSampled` / `TrustEvidenceRecorded` / `ThinkingContextSnapshotted` / `GuardDecisionRecorded` /【P2】`SimilarNodeNotified` / `CompressedNodeCreated`。すべて既存 `SourceVaultAppendEvent`(one-event-one-file、digest 冪等)。

## 5. 機能仕様

### 5.1 Knowledge Home NB ブラウザ【P1】

資料 p3–5 の Web 版(prev/index/next、topic の `[ki 1373] (prev/next)`、引用リンク)を Mathematica NB で再現する。実体は search foundation §3.4 `SourceVaultSearchView`(`LiveNotebookHypertext` / `ContextSubgraphNotebook`)の Knowledge Home 特化バインディングであり、レンダラを再発明しない。

- `SourceVaultKnowledgeHomeView[entry, opts]`(core→view→window の3層。既存 ThreadPanel 流儀)
  - entry: topic ref | mail Counter | `svkhpara:` | 検索クエリ | `SourceVaultOntologyPosition`
  - 1メール表示 = ヘッダ + パラグラフ列。各 topic item は Button 化: click で「その topic の時系列パラグラフ一覧」へ。**prev/next** は `SourceVaultKnowledgeHomeParagraphs[topicRef]`(時系列順序列)上の前後移動。
  - 引用は双方向: `Quote (from n)` → 引用元へ、被引用リスト(逆 edge view)→ 引用先へ。矢印の意味(citing→cited)は legend 表示(general_mail §3.3 note)。
  - lazy load: `LazyLoadPolicy{MaxInitialNodes->80, ExpandDepth->1}`、gated fetch。未許可 node は low-leak placeholder。
  - 閲覧行動は既存 `SourceVaultRecordTopicItemInteraction` で記録(→ RecallLevel / ThinkingContext の供給源)。
- 表示件数制限は専用変数(`$SourceVaultKnowledgeHomeViewMaxRows` 等)。ウィンドウ版は `CreateDocument`。

### 5.2 Knowledge Home 追記【P1】

- core: `SourceVaultKnowledgeHomeAppend[body, "Topics"->{...}, "Quotes"->{...}, "PrivacyLevel"->0.6]` — oops 文法の検証(明示マーカー/引用プロトコル)、event 追記、chunk 化と lexical 増分、TopicVocabulary 増分成長(既存 `SourceVaultGrowTopicVocabulary` 経路)。
- UI: **式テンプレート1セル**を正とする(フォーム的セル編集ではない)。`SourceVaultKnowledgeHomeAppendTemplate[]` が引数入りの評価可能式セルを挿入し、ユーザーが引数を書き換えて評価する。
- 新 topic item: `SourceVaultKnowledgeHomeMintItem[label]`(§4.2)。既存 label は「検索して既に誰かが付けていればそれを使う」(oops 694 の運用)を支援するため、Append 時に近接 label 候補を提示する(mint 前の重複チェック。I-6 に従い提案のみ)。

### 5.3 全データの位置づけ【P1: mail+KH+llmlog digest → P2: notebook/Eagle/全クラス】

- `SourceVaultComputeOntologyPositions[uris, opts]` — §4.1 のパイプライン。P1 では (a) oops メール(全量) (b) KH 追記 (c) maildb 一般メール(Summary/Subject ベース。本文復号は opt-in) (d) llmlog session digest を対象にする。
- P2 で notebook 内容サマリー・Eagle ファイルサマリー・アノテーションへ拡張(いずれも既存の要約 DerivedArtifact 経路を流用し、位置づけは summary に対して行う=本文の新規漏洩区分を作らない)。
- 実行は service / 外部ワーカー(I-8)。増分・冪等(`SkipExisting` 流儀)。
- `SourceVaultNeighborhoodSearch[posOrUriOrText, opts]` — 位置(または text→ 即時位置推定)から近傍 object を返す。既存 `SourceVaultMinedSearch`/`SourceVaultHybridSearch` の合成 + relation graph hop。EvidenceKind 規約遵守(SummaryPrimer 単独で回答根拠にしない)。

### 5.4 現在位置推定・近傍提案・前進支援【P1 v0 → P2】

資料 p11 "The desired behavior of the system" の実装。

- `SourceVaultThinkingContextEstimate[opts]` — 直近窓(既定 2h/1日)の llmlog digest・KH/メール閲覧 interaction・開いている NB($onWork)から §4.7 を構成。位置は各 signal の OntologyPosition の減衰加重和。
- `SourceVaultSuggestNextNodes[context, opts]` — 3リング提案(資料の 1/2/3):
  1. **similar topics and newer**: 現在位置に近い topic を持ち、かつ**より新しい** timestamp のノード(前進バイアス。ループ脱出の主経路、SSI2019 §4 問題4)
  2. **direct neighborhood**: 現在推定ノードの直接隣接(quote/reply/co-paragraph edge)
  3. **neighborhood**: relation graph 2-hop までの周辺
  - ランキング: 既存 bounded boost 規約内で `RecallLevel`(P2)・`EffectiveImportance`・freshness を合成。`LoopScore` が閾値超過(同一 topic 集合を新規ノード作成なしに N 回再訪)のときリング1の重みを上げ、「次のノードへ移る/作ることを促す」(urge to move to or create the next node)。
  - 件数は `SourceVaultBriefingProfile[]`(§5.5)に従う。
- `SourceVaultSuggestNextNodesView[...]` — Dataset 版。既存 `SourceVaultMailSessionSuggest` の `IdentityTags` boost と統合(同一候補面に mail session 提案も混ぜられる)。
- `ClusterLengthEstimate`: 直近 cluster(連続した関連作業列)の平均/最大長を推定し、トレンド低下+CognitiveLevel Low の併発を diagnostics へ emit(資料 p16 "Maximum cluster length ↓ & cognitive level ↓: harmful!")。**通知は SIEM の別トラストクラス規約に従う**(自分宛固定・metadata only・rate limited)。

### 5.5 可変 briefing(提示の絞り込み)【P1: 件数のみ → P2: 粒度】

- `SourceVaultBriefingProfile[]` → `<|MaxSuggestions, SummaryTier -> "Full"|"Summary"|"KeywordsOnly", ConfirmationSteps|>`。CognitiveLevel Tier からの決定表(P1 既定):

| CognitiveLevel | MaxSuggestions | SummaryTier | ConfirmationSteps(リスク操作) |
|---|---|---|---|
| High | 12 | Full | 標準(既存 gate のまま) |
| Mid | 6 | Full | 標準 |
| Low | 3 | Summary | +1(再確認を1段追加) |

- P2 で SSI2019 の「encode 表示」を実装: RecallLevel が高い paragraph はキーワードのみ/短い要約で畳み、低い paragraph は全文表示 — スクロールせず見当識を保てる範囲に情報を圧縮する。View 側は `SummaryTier` を各 cell group の折りたたみ初期状態にマップ。

### 5.6 類似反復の圧縮(compress items)【P2】

- 新規追記/起票時に近傍検索で類似既存ノードを検出し、(a) CognitiveLevel High なら「既存ノードがある」通知 (b) Low なら作成を許して後で圧縮候補に積む(資料 p18 の条件分岐)。
- `CompressedNodeCreated`: 類似ノード群への edge を持つ新ノードを作り、新ノードに高い RecallLevel 初期値を与える。**元ノードは削除しない**(反復作業をした事実自体が認知変動の重要データ)。

### 5.7 Guard: 信頼度×認知レベルによるエラー予防【P1最小 → P2】

- `SourceVaultTaskValidationLevel[actionKind, opts]` → `<|Level -> "Standard"|"Elevated"|"Hold", Reasons|>`。入力: actionKind のリスク分類(送信/公開/削除/privacy 降下)、TrustAssessment(相手)、CognitiveLevel Tier、内容の推定 PL と宛先 MaxPlaintextPL の差(**privacy 降下検出**)。
- 結線(P1): メール送信経路の既存 `SourceVaultPlanMessageRelease` / `SourceVaultEvaluateActionGate` の**手前**に挿入し、`Elevated` なら確認1段追加、`Hold` なら送信を defer queue に置いて再確認を促す(ブロックではなく遅延+再確認。I-6)。判断は `GuardDecisionRecorded` で監査可能に。
- 検出対象の例: 高 PL 内容を低信頼宛先へ(誤送信)、GitHub/SNS 公開系操作時の CognitiveLevel Low、深夜の不可逆操作、返信すべきメールの放置(deadline 系は autotrigger と連携し提案として浮上)。
- P2: 宛先候補の入れ違い検出(本文中の人名/文脈と宛先 identity の不整合を local LLM で照合)。

### 5.8 me' エージェント(自動起票)【P2 → P3】

- 現行の自動 ingest(llmlog/webingest/mail service)を me' の基盤と位置づける。P2 で定型起票(請求書・予定・返信 TODO)を `ReviewState -> "Pending"` の KH パラグラフ案として生成(SSI2019 §4 問題3)。owner が確認した時点で RecallLevel を高値に設定し「自らの行為」として扱う。
- 認知レベル閾値による me' 表示の切替(別ユーザー表示 ⇔ 混合表示、資料 p22)は P3。倫理・本人同意設計を伴う。

### 5.9 認知変動の6問題への対応マップ(SSI2019 §4)

| 問題 | 対応 | Phase |
|---|---|---|
| 1 検索できない | 近傍検索+ThinkingContext 起点の提案(キーワード不要の Neighbor Hopping)、P2 で RecallLevel 加味ランキング(「うろ覚え度」を検索リストに反映) | P1→P2 |
| 2 読んで把握できない | encode 表示(RecallLevel 連動の可変粒度) | P2 |
| 3 書けない | me' 起票 + 式テンプレート(記入欄最小化) | P2 |
| 4 検索する動機を失う | autotrigger/schedule 経由の能動提示(newer ノード優先でループ脱出支援) | P2 |
| 5 ログの存在を忘れる | 定期提示(サイネージ的 View、schedule 連携) | P3 |
| 6 誰が準備したか忘れる | 全提示面に「これはあなたが準備したシステム」の常時自己提示枠 | P3 |

## 6. Public API(草案)

`SourceVault_knowledgehome.wl`:
```
SourceVaultKnowledgeHomeEnsureLoaded[opts]           (* oopsseed EnsureLoaded + extension 合流。冪等 *)
SourceVaultKnowledgeHomeView[entry, opts]            (* core/View/Window 3層 *)
SourceVaultKnowledgeHomeParagraphs[topicRef]         (* 時系列パラグラフ列(prev/next 基盤) *)
SourceVaultKnowledgeHomeAppend[body, opts]
SourceVaultKnowledgeHomeAppendTemplate[]             (* 式テンプレセル挿入 *)
SourceVaultKnowledgeHomeMintItem[label, opts]
SourceVaultComputeOntologyPositions[uris, opts]
SourceVaultOntologyPositionOf[uri]
SourceVaultNeighborhoodSearch[posOrUriOrText, opts]
SourceVaultThinkingContextEstimate[opts]
SourceVaultSuggestNextNodes[context, opts]           (* + ...View *)
```

`SourceVault_cognition.wl`(AccessLevel 1.0 クラス):
```
SourceVaultRecallLevel[targetURI]                    (* projection *)
SourceVaultRecordRecallSample[targetURI, opts]
SourceVaultCognitiveLevel[opts]                      (* 現在 Tier(+opt-in で数値) *)
SourceVaultCognitiveLevelEstimate[opts]              (* PromptProxyV1、外部ワーカー実行 *)
SourceVaultRecordCognitiveSelfReport[v]
SourceVaultTrustLevel[subjectRef]
SourceVaultRecordTrustEvidence[subjectRef, evidence, opts]
SourceVaultBriefingProfile[]
SourceVaultTaskValidationLevel[actionKind, opts]
SourceVaultGuardEvaluate[actionDraft, opts]          (* 既存 gate の手前段。単調強化のみ *)
```

## 7. フェーズ分割

### Phase 1(当座実装。Inc C1–C7、各 DoD 付き)

| Inc | 内容 | DoD |
|---|---|---|
| C1 | KH NB ブラウザ(§5.1): SearchView バインディング、topic prev/next、引用双方向、interaction 記録 | oops 実データで任意 topic/mail から NB 内リンク遷移が閉じる。gate/CloudSafe 遵守のテスト green |
| C2 | KH 追記(§5.2): Append/Template/MintItem、lexical 増分、extension 合流 | 追記→即検索ヒット→C1 で閲覧、の往復。原本 index 不変検証。冪等再実行 |
| C3 | OntologyPosition v0(§5.3): mail+KH+llmlog digest、SeedMatched+RelationExpanded、外部ワーカー | 対象全量の position shard 生成。既知メールでの位置妥当性 spot check(NB 実機) |
| C4 | ThinkingContext v0 + 3リング提案(§5.4): LoopScore、mailsuggest 統合 View | 実プロンプト履歴から提案 Dataset が出る。ループ検出の合成テスト |
| C5 | RecallLevel v0(§4.4): ObjectInteractions 変換 + projection | 閲覧履歴から Tier(Frequent/Recallable/Forgotten)が引ける |
| C6 | 認知イベント基盤+CognitiveLevel v0(§4.5): PromptProxyV1、rollup、self-report、BriefingProfile(件数絞りのみ) | 各特徴の単体テスト+Tier 出力。I-1 の deny/local-only 検証。数値が prompt/MCP に漏れないこと |
| C7 | Guard v0(§5.7): TrustAssessment 最小+TaskValidationLevel+送信経路結線 | privacy 降下シナリオで Elevated/Hold になる e2e(モック送信)。既存送信テスト回帰 green |

依存: C1→C2、C3→C4、C5/C6→C7。C1–C3 は認知層なしで独立に価値がある(純粋な Knowledge Home 復活+近傍検索)。検証は既存規約どおり wolframscript スイート+ユーザー NB 実機(result*.nb)。

### Phase 2(半年〜2年)

- dense hybrid 本格化(bge-m3/JaColBERT、検索基盤スペックの B5)と DenseProjected 位置づけ
- 位置づけ対象の全クラス化(notebook/Eagle/アノテーション、要約 DerivedArtifact 経由)
- RecallLevel 本格化: dwell/scroll 計測、能動確認ダイアログ、encode 表示(可変粒度 View)
- compress items(類似ノード通知+圧縮ノード)
- me' 定型起票(Pending review)、autotrigger 連携の能動提示(問題3,4)
- Guard 拡張: 宛先入れ違い検出(local LLM)、GitHub/SNS 公開操作への結線
- 認知推定の特徴拡充(IME 変換確定パターン等)と self-report 校正の評価(held-out)

### Phase 3(2年以降・研究課題含む)

- 音声・カメラ・バイオメトリクス入力(soliloquy/body motion/heart rate/eye tracking。diagnostics SIEM の producer として)
- 家族/介護者/医療者との共有(universal MCP access の grant/AccessProfile 基盤で「必要な部分のみ」提示。資料 p21 の virtual→real user 遷移)
- 問題5/6 対処: 常時自己提示、サイネージ/AR 提示面、システム忘却後も機能する UI
- camouflage(倫理レビュー必須。それまで実装しない)、me' 混合表示
- ブートストラップ移行演習(正準データのみで別システムに再構成できることの定期検証)

## 8. 受け入れ基準(Phase 1 全体)

1. oops 原アーカイブ・gold index のハッシュが全 Inc 実行前後で不変
2. 認知系の値(数値)が cloud LLM prompt / MCP レスポンス / 共有ログのいずれにも出現しない(grep 監査+専用テスト)
3. `"CloudSafe"->True` / ReleaseContext deny 下で ura 系・認知系が漏れない(既存 gate 回帰含む)
4. Guard は既存 gate の判定を一切緩めない(同一入力での前後比較テスト)
5. FE メインカーネルでの同期 LLM 呼び出しゼロ(コードレビュー+実行トレース)
6. 全 event が digest 冪等・replay 可能。cache 全削除→再生成で projection が一致
7. NB 実機(result*.nb): C1 閲覧往復、C2 追記往復、C4 提案表示、C7 送信ガードのシナリオ

## 9. Open issues

1. **CognitiveLevel の妥当性**: ground truth がない。P1 は Tier のみ・下流影響を絞る設計だが、self-report との相関評価の設計(何ヶ月分でどう判定するか)は未定。
2. **camouflage の倫理**: 資料 p17/p34 の execute/stop/camouflage のうち camouflage は本人の事前同意(元気なうちの事前指示書に相当)の設計が必要。P3 まで凍結。
3. **トピックラベルの privacy**: 位置 projection の TopicWeights にラベルでなく ref のみ持つが、View 描画時の scope 混入(private 語彙が cloud 向け出力に載る)の網羅的な gate 位置は実装時に確定。
4. **cluster 境界の定義**: ClusterLengthEstimate の「cluster」を既存 MailSession とどう対応させるか(作業ログ側の session 化は llmlog digest 単位で近似する案)。
5. **KH 採番の複数オーナー拡張**: 将来、家族/他者が書き込む場合の namespace(oops の思想では各自の namespace で採番)— identity 基盤とは整合するが UI 未設計。
6. **RecallLevel の decay 関数**: 忘却曲線の形(指数/冪)と個人差パラメータ。P2 の能動確認データが集まるまで固定パラメータ。

## Appendix A: 資料の要点(実装への写像根拠)

- p1: 検索履歴の格納先は「自分の独断的な見方(リンク)を与えた」メールリスト = Knowledge Home。動機→キーワード選択→検索→結果からの行動、の作業履歴を随所からアプローチ可能に。
- p2/p6–9: topic relation & paragraph quoting graph、session/cluster、associative level の3層(thinking frequently / associative / completely forgotten)と時間変化。
- p10/p14: システムは (a) 現在思考に最も近い session を推定 (b) 直近 cluster の平均/最大長(短期記憶で支えられる思考長)を推定 (c) 各ノードの associative level を更新し続ける。1/associative level ∝ 忘れたエピソードの理解所要時間。
- p11–12: 提案の3リングと「ランキングを適切に表示し、次のノードへの移動または作成を促し、パラメータを更新する」。variable briefing level(「婆さんや、あれ、持ってきて」)。
- p16–17: cognitive level はノード作成時に記録されデータ信頼性を反映。privacy level 降下を含む操作は execute/stop/camouflage の判断対象。faults 数と他ユーザー評価から推定。
- p18: 類似反復ノードの圧縮。何も削除しない。
- p21–22: ユーザー分類(real/virtual)、me' の表示切替。
- SSI2019 §4: 認知変動の6問題、想起レベルの (値,timestamp) リスト化と閲覧時校正、encode 表示、me' 起票と想起レベルによる「自らの行為」化、ループ脱出(newer timestamp 優先提示)。

## Appendix B: 既存資産マップ(再利用一覧)

| 必要機能 | 既存資産(再利用) |
|---|---|
| ベースオントロジ読込 | `SourceVaultOOPSEnsureLoaded` / `SourceVaultImportOOPSSeedDictionary` / relation graph |
| パラグラフ topic 付与 | `SourceVaultAssignParagraphTopics` / `SourceVaultExtractExplicitTopics` |
| 引用/セッション | `SourceVaultBuildMailQuoteEdges` / `SourceVaultBuildMailSessions` |
| 検索 | `SourceVaultBuildLexicalStats`(EntityDictionary 注入)/ `SourceVaultMinedSearch` / `SourceVaultHybridSearch` |
| NB ハイパーテキスト | `SourceVaultSearchView`(LiveNotebookHypertext/ContextSubgraph)+ interaction meta-layer |
| セッション提案 | `SourceVaultMailSessionSuggest`(IdentityTags boost) |
| 行動記録 | ObjectInteractions / `SourceVaultReplayObjectSignals` / retrieval episode 規約 |
| 人物/宛先 | identity 層(`ent-`/`idf-`、`SourceVaultResolveRecipientProfile` fail-closed、`SourceVaultPlanMessageRelease`) |
| プロンプト信号 | `SourceVaultClaudeCodeSessionDigest` / `SourceVaultIngestClaudeCodeLogs` + rollup 規約 |
| 秘匿 LLM 処理 | `SourceVaultQueryLocalLLM`(LM Studio、UNTRUSTED 隔離)/ ローカル embedding provider |
| イベント/rollup | `SourceVaultAppendEvent`(one-event-one-file)/ `<CoreRoot>/rollup/<ns>/<MachineTag>/` |
| 通知 | diagnostics SIEM(自分宛固定・metadata only・rate limited)+ autotrigger |
