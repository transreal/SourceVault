# SourceVault 匿名化拡張(anonymize)仕様 v1.0

**v1.0 が本拡張の唯一の正準であり、本書単独で完結する(過去版 v0.1–v0.4・レビュー文書 r1–r4 への参照なしに読める)。**
履歴: v0.1(2026-07-23 初版)→ r1–r4 の 4 回のレビューを経て本版に収束。反映済みレビューは `sourcevault_anonymization_spec_v0_1_review.md` 〜 `…_v0_4_review.md`(歴史参照のみ・本書の理解には不要)。
親仕様: `NBAccess_claudecode_privacy_spec_v0_1.md` §11 Declassify / `sourcevault_universal_mcp_access_spec_v2.md` §10.7 DerivedArtifact・§13.4 Output Privacy Estimation / `sourcevault-spec-v0.13.md` §3 PrivacyLevel スケール。
参考文献: 佐久間淳『データ解析におけるプライバシー保護』(機械学習プロフェッショナルシリーズ、講談社)— `sv://object/eagle-LHXH1104F7GUJ`(§21)。
status: 実装着手可(実装順は §19)。実装配置: 一般層 = 新規 `SourceVault_anonymize.wl`、応用層 = `Cerezo.wl`。

---

## 0. 結論

- **匿名化 = 明示的・監査付き declassification**。元オブジェクトの PrivacyLevel(PL)は一切変えず、検証ゲート合格時のみ**別 URI の派生成果物**を低 PL で公開する。privacy 層の非降下原則(Max 伝搬)は破らない — 引き下げは「同一オブジェクトの PL 変更」ではなく「オーナーが許可した変換の、検証合格した別オブジェクトの生成」で実現する。
- **privacy は四軸で扱う**: (1) object PL、(2) 実行権限(owner grant)、(3) 利用履歴(cumulative exposure)、(4) 発見可能性(unlisted)。「高 PL はスキーマのみ」という既存原則は匿名化の存在によって緩和されない。
- **操作は四段階**: Plan(schema-only・無許可)→ Execute(**DeclassificationExecutionGrant 必須**・本文 read 前に検証)→ Publish(**PublishIfVerified 事前許可または artifact-bound PublicationGrant**)→ Reuse(exact ReleaseHandle の bearer get のみ無許可・全件記録)。
- **TargetLevel はオーナーが grant で exact 指定**(既定 0.45 = クラウド LLM 境界 0.5 未満、オプション 0.2 = 低信頼クラウド上限 0.25 未満。システム既定の自動採用はない)。
- 入力は **sv:// 参照から形式を自動判別**(複雑な連想・配列・画像 1 枚・画像集合・マルチページ PDF・混在)し、ポリシーの形式別 handler が fail-closed に処理する。同一入力・同一ポリシー・同一レベルは**再計算なしに同一成果物**(冪等)。
- **誤帰属防止の 3 本柱**: (1) 論理オブジェクトを含む衝突耐性 ID 式、(2) 役割別 token(Subject/Item/Job/ResultSlot)+ node/edge lineage graph、(3) artifact-bound な結果(quarantine → AnnotationContent/Binding)と全件 join 検証付き原子的書き戻し。
- **公開状態の正本は immutable PublicationRecord + 単一 PublicationHead**(CAS)。低 PL 側の取得ハンドルは content と独立な **ランダム ReleaseHandle**(revoke/rotate 可)。成果物は **unlisted**(検索・カタログ・一覧に非掲載)。
- **cloud が返した結果(成績等)は受信 byte の時点から高 PL quarantine**(Cerezo の Grade は 1.0)。複数 subject の個別値を含む**集約は PL 1.0**(CompositionPolicy — Max では判定しない)。
- **全 release/egress は事前に durable 記録**(PreReleaseIntent WAL)され、ExposureGuard が同一 cohort の集中利用・variant 横断・coverage 超過で自動処理を停止しオーナー再承認を要求。System Doctor には sanitized 報告、詳細はオーナー専用。
- 採点は**一受験者 = 一 EvaluationUnit = 一セッション**。provider へは JobToken(+複数結果時は ResultSlotToken)と匿名化本文のみ。provider 分散はオーナー承認の DistributionPlan による明示選択。

---

## 1. 背景と目的

SourceVault は ingest 済みオブジェクトを PL(0.0–1.0)で保護し、release gate が「PL > 実効アクセスレベル」のオブジェクトをスキーマ/メタデータのみに縮約する。この設計は安全側だが、「個人情報を除けば低リスクであり、匿名化すれば低い実効 PL で利用できる」ケース — 典型例はレポートの LLM 採点 — に対応できない。

動機実例(2026-07-23 実測、Cerezo=福山大 manaba 提出物):

- `CerezoCollectionData[runURI]` の各行は PL 1.0。秘匿の核は `StudentName`/`StudentID` と、その複製の染み出しである。
- 実データでは `Files[*].ExtractedText` の**先頭行に生の学籍番号**、`ReportHeader` に「〈氏名〉さんが提出したレポート(提出日時: …)」、`Files[*].URL` に日本語ファイル名の percent-encoding が残る。**フィールド置換だけでは不十分で、テキスト内スキャンが必須**である。
- 仮名化+残存 PII 削除により、この事例では PL 0.45 の派生版を作りクラウド LLM 採点に投入できる。

本拡張はこの操作を、(1) プライバシー保護を前提としたデータ解析全般に使える一般機構として、(2) ポリシーファイル駆動で自動・再現可能に、(3) オーナー許可・監査・系譜保証付きの declassification として SourceVault に追加する。

> **スケール注記**: 議論中に現れる「プライバシーレベル 10.0」という表記は、正準スケール(0.0–1.0)の **1.0 (Secret)** に対応する。本書の数値はすべて 0.0–1.0。0.5 が cloud 境界(cloud 系 provider の実効アクセスレベル上限は 0.5、AccessProfile 既定 0.49)、z.ai/kimi 等の低信頼 provider は 0.25。

### 1.1 既存機構との関係(実装調査済みの事実)

| 既存機構 | 本仕様での扱い |
|---|---|
| PL 0.0–1.0 スケール・0.5 cloud 境界・provider 上限表(zai/kimi 0.25) | TargetLevel 0.45/0.2 の根拠。変更しない |
| `SourceVaultMCPReleaseGate`(`plevel > effLevel` → Deny、cloud hard cap) | 判定は流用。**PublicationHead 確認・Unlisted 索引除外を additive に追加改修** |
| DerivedArtifact(親仕様 §10.7)・現行 `SourceVaultSaveDerivedArtifact` | 保存クラスとして統合。ただし現行 builder は Text/Summary 必須・`ArtifactId->CreateUUID[]`(random)で本 schema を保存できない → **content-addressed builder を新設**(§5.6)。既存逆引き `SourceVaultDerivedArtifactsForSource` は ArtifactBinding index を読む adapter 拡張が必要 |
| `SourceVaultSetImmutableSnapshotPrivacyLevel`(手動 PL 設定・承認ゲート付き) | 手動経路として存続。匿名化はこれを直接呼ばず、専用内部 API 経由(§10.3) |
| privacy 層(`SourceVaultNotePrivacy` 系: Max 伝搬・非降下・fail-closed 既定 0.85) | 実行スコープの透かしはそのまま適用(P-A2)。本拡張が正式な declassification トラック |
| `$ClaudePrivateModel` = {provider, model, url}(ローカル LLM) | Redact 段・Verify 段・MediaScan のローカル LLM/vision に再利用 |
| `SourceVaultLLMBoundaryGate`(capbroker、egress 境界) | クラウド送信 envelope はこの境界を通す |
| privacy 契約 + `privacy_reviewed.m` コミットゲート | 新規 public シンボルは全て契約登録・レビュー登録必須(§16.1) |
| `SourceVaultSaveImmutableSnapshot` / `SourceVaultCommitBlob` / snapshot-alias | 保存基盤(blob 意味論は §5.8) |
| NBAccess 承認ゲート・action registry | **declassification effect class を登録**: Execute/Publish/段階的匿名化/profile・grant 変更は実行境界で owner 承認。trusted package head の免除を適用しない。内部 API・subkernel 経路も同一 grant 検証(迂回防止) |
| `SourceVaultDiagnosticsRegisterProbe` / `SourceVaultDiagnosticsEscalate` | ExposureGuard の probe/escalation に再利用(§16.2) |
| PrivateVault/secrets(非公開・全ノード同期) | KeyRing の配置先(§5.5) |

---

## 2. 設計原則

- **P-A1(派生・不変)**: 匿名化は元オブジェクトを変更しない。成果物は不変 snapshot・別 URI。元の PL・アクセス制御は不変。
- **P-A2(非降下との整合)**: 匿名化処理を実行するカーネル評価は元データを読むため、評価スコープの透かしは元 PL に上がる(正しい挙動)。低 PL は**成果物オブジェクトの属性**であり評価スコープの属性ではない。
- **P-A3(fail-closed)**: 検証不合格・LLM 不通・ポリシー解決不能・系譜不整合・join 不一致・ledger 不通(自動大量処理時)は、すべて「公開しない/書き戻さない/実行しない」側に倒す。
- **P-A4(ポリシーが正準)**: 匿名化手順はコードでなくポリシーファイル(sv:// 登録・digest 固定)が定義する。ポリシー変更 = 新 digest = 新 variant。
- **P-A5(決定論コア + injectable シーム)**: 決定論段は LLM なしで完結しテスト可能。LLM/vision スキャンは注入シーム経由で、テストは mock で完結する。
- **P-A6(対応表・系譜の分離)**: 対応表・系譜・評価計画・identity 証跡は成果物と物理的に別の PL 1.0 オブジェクト。低 PL 成果物単体からは実 ID にも原本にも到達できない。
- **P-A7(監査可能な declassification)**: すべての公開は監査レコードを durable にした後にのみ有効化される。
- **P-A8(additive)**: 既存挙動を変えない additive 増分のみ。明示的な改修対象: release gate への PublicationHead 確認、検索 index の Unlisted 除外、DerivedArtifact 逆引き adapter、NBAccess action registry 登録。
- **P-A9(要素系譜)**: 原本の各要素から全派生片・全結果までの対応は node/edge graph の LineageManifest が正準。list index 等の暗黙対応を identity にしない。
- **P-A10(artifact-bound results)**: 解析結果は対象 artifact・lineage・map・evaluation の exact ref/digest を焼き込んだ binding 経由でのみ受理する。裸の list/Association の書き戻しは拒否する。
- **P-A11(atomic publish)**: 公開状態の正本は PublicationHead ただ一つ。全 release 経路がそこを参照し、途中障害は「未公開」に倒れる。
- **P-A12(revocable)**: 公開は Revoke/Supersede/Expire でき、release は毎回状態を確認する。grant の失効と publication の失効は別効果(§10.6)。
- **P-A13(identity の独立性)**: unit の同一性は「論理オブジェクト × 内容版 × canonical locator × 内容 digest」で決まる。並び順・ファイル名・現在位置に依存せず、**別の論理オブジェクトが同一内容を持っても衝突しない**。低 PL payload の各 unit は一意な ItemToken を持つ。
- **P-A14(universal, 保守的)**: 既定ポリシーは任意の入力形式を自動判別して匿名化候補を生成できる。自動で判断できない部分(未知フィールド・低信頼検出・宣言なきメディア)は常に「落とす/伏せる/要確認」に倒す。
- **P-A15(owner-authorized execution)**: 高 PL 本文を読む Execute と低 PL 化する Publish は、オーナーが exact に固定した typed grant なしに開始しない。Profile・レビュー待ち状態は grant の代替ではない。agent/LLM は grant を自己発行・自己承認できない。
- **P-A16(composition)**: 派生物の PL を個別 object PL の Max だけで決めない。センシティブクラス(成績等)を含む永続物・複数 subject の個別値を含む集約は CompositionPolicy の最低 PL を適用する。
- **P-A17(cumulative exposure)**: 利用履歴は object PL を書き換えず、release/automation 時の動的 risk として扱う。全 sanctioned release/egress を事前 durable 記録し、閾値超過は自動処理を止めてオーナーへ報告する。
- **P-A18(unlisted discoverability)**: 匿名化成果物とその派生は列挙不能(検索・カタログ・一覧に非掲載)。低 PL 側の到達手段は content と独立なランダム ReleaseHandle のみ。unlisted は**アクセス制御ではなく発見面の縮小**(defense in depth)であり、第一の防御は gate・grant・guard である。
- **P-A19(record 束縛)**: 参照と digest、token と role のように対で意味を持つ値は、**平行配列でなく同一 record に束縛**し、集合全体を canonical sort + digest する(順序変更・欠落・重複・role 取り違えの機械検出)。

---

## 3. 用語

| 用語 | 定義 |
|---|---|
| **仮名化 (pseudonymization)** | 直接識別子を仮名に置換し、対応表があれば可逆な変換 |
| **匿名化 (anonymization)** | 仮名化+残存 PII 削除+一般化等の合成。API 名はこの合成全体を指す(対応表が存在するため厳密には仮名化+リスク低減だが慣用に従う) |
| **直接識別子** | 単独で個人を特定する属性(氏名・学籍番号・メール等) |
| **準識別子** | 組合せ・外部知識との結合で特定に至る属性(所属・学年・性別・提出時刻等) |
| **一般化階層** | 準識別子を粗い値へ写す階層(時刻→日→週、学科→学部、年齢→年代) |
| **k 匿名性** | 準識別子の値の組が同じレコードが常に k 件以上ある性質 |
| **TargetLevel** | 成果物に付与を目指す PL。オーナーが grant で exact 指定(代表値 0.45 / 0.2) |
| **Strength tier** | ポリシー内の強度段。TargetLevel ごとに適用規則が異なる(低いレベルほど強い変換) |
| **AnonymizationPolicy** | 匿名化手順の宣言(sv:// 登録・digest 固定)。§5.1 |
| **DeclassificationProfile** | 許容範囲の制約テンプレート(それ自体は許可ではない)。§5.2 |
| **AnonymizationPlan** | schema-only 情報だけから作る計画(本文非読)。オーナーの承認判断材料。§7.1 |
| **DeclassificationExecutionGrant / ArtifactPublicationGrant / EvaluationEgressGrant** | 型分離されたオーナー許可。§5.13 |
| **GrantExecutionLease** | grant 使用の予約→確定/中止の冪等機構。§5.13 |
| **PseudonymMap** | 実体↔SubjectToken の対応。MapId+不変 MapVersion+MapHead。PL 1.0。§5.3 |
| **LineageManifest** | SourceNodes/DerivedNodes/Edges/Partitions の系譜 graph。PL 1.0。§5.4 |
| **ArtifactBinding** | 成果物↔origin/policy/map/lineage/profile の exact 束縛。PL 1.0。§5.6 |
| **PublicationRecord / PublicationHead** | 公開状態の不変レコードと単一可変 pointer(状態の正本)。§5.10 |
| **ReleaseHandle** | 低 PL 側の bearer 取得ハンドル。CSPRNG 由来・content 非依存・revoke/rotate 可。§5.10 |
| **SubjectToken / ItemToken / JobToken / ResultSlotToken** | 役割別 token(主体/派生 unit/外部 job/結果 slot)。§5.5 |
| **EvaluationUnit** | 採点の単位 = 一受験者/一提出物(複数ページ・添付を含む)。§5.11 |
| **EvaluationPlanManifest / EvaluationResultManifest** | LLM job 群の送信前計画/受信後結果の trusted binding。PL 1.0。§5.11 |
| **CloudTransportResult (quarantine)** | provider 生応答の高 PL 隔離保管(受信 byte から)。§5.9 |
| **AnnotationContent / AnnotationBinding** | 結果の本体(protected minimum PL)と PL 1.0 束縛の二層。§5.9 |
| **CompositionPolicy** | 集約・結合物の最低 PL 規則。§13.5 |
| **ExposureLedger / ExposureEvent / ExposurePolicy / ExposureGuard** | 累積露出の記録・閾値・実行時判定。§5.14, §15.2 |
| **EvaluationDistributionPlan** | provider 分散のオーナー承認計画。§13.6 |
| **PublishedReuse** | 既公開成果物の再利用 fast path(新 declassification ではない)。§10.5 |
| **Unlisted** | 列挙不能な公開状態。§15.1 |
| **IdentityEvidence** | OCR 等の identity 候補の証跡(PL 1.0)+adjudication 状態。§12.2 |
| **AdHocOrigin** | 直渡し値を書き戻し可能にする自動 immutable snapshot。§7.1 |
| **KeyRing / KeyId / CanonicalizationVersion** | ID 生成の HMAC 鍵束と正規化規則の版。§5.5 |
| **MediaScan** | ローカル OCR/vision による画像・PDF ラスタ内 PII の自動検出→黒塗り。§6.8 |

---

## 4. 操作モデル・TargetLevel・冪等規則

### 4.0 四段階操作モデル

| 段階 | 高 PL 本文 | owner 許可 | 内容 |
|---|---:|---:|---|
| **Plan** | 読まない | 不要 | schema-only projection から形式・件数の安全な範囲・候補ポリシー・必要 verifier・target/sink の選択肢を提示 |
| **Execute** | 読む | **必須**(ExecutionGrant) | grant が固定した origin/selection/policy/TargetLevel で匿名化候補を生成・検証 |
| **Publish** | 候補を低 PL 化 | **必須**(PublishIfVerified 事前許可 or artifact-bound PublicationGrant) | PublicationHead の有効化+ReleaseHandle 発行 |
| **Reuse** | Published 低 PL のみ | 原則不要 | exact ReleaseHandle の bearer get。全件を事前 durable 記録し guard が監視 |

規則:

- **R4-1**: `TargetLevel >= 元オブジェクトの PL` の要求はエラー(匿名化は引き下げ専用)。
- **R4-2**: ポリシーが当該 TargetLevel の strength tier を定義していない場合はエラー(近い段を勝手に適用しない)。
- **R4-3**: 成果物 PL は検証合格+Publish 時のみ TargetLevel。不合格は既定で保存しない(`"KeepFailed"->True` なら元 PL 継承の Draft)。
- **R4-4**: release 判定は既存 gate 判定(PL・cloud cap・provider 上限)に加え、PublicationHead の状態確認を必須とする。
- **R4-5(参照透過)**: 同一 TransformCacheIdentity(§11)の再呼び出しは再計算なし(全ヒット監査+release 時は ExposureEvent)。
- **R4-6(no-op)**: 匿名化成果物への同一ポリシー・同一 TargetLevel の再適用は、`Published 状態 ∧ 現行 revocation/profile 有効性 ∧ exact TransformCacheIdentity ∧ 現行 policy/verifier/MediaScan 有効性 ∧ exact TargetLevel` の完全一致時のみ no-op(同一成果物返却)。満たさなければ再検証または新 grant を要求(Revoked/旧 verifier 成果物を返さない)。
- **R4-7(段階的匿名化)**: 0.45→0.2 のような更なる引き下げは許可されるが**新しい owner grant 必須**(新 target・新 sink 境界)。過去の 0.45 開示は取り消せない — 意味は「将来、低信頼 provider に渡す内容をさらに縮約する」こと。lineage は元成果物を親として連鎖。
- **R4-8(owner grant)**: Execute/Publish は有効な typed grant 必須。grant 検証はパイプライン段 0(§8.1)で行い、検証前に payload/blob 解決・KnownStrings/Identity 生成・MediaScan/OCR/LLM 呼出し・AdHocOrigin 保存・PseudonymMap 追記・ItemToken/派生 content 生成のいずれも行わない。

### 4.1 入力形式の自動判別(universal dispatch)

`SourceVaultAnonymize` は `orig` の解決結果(ObjectClass/MediaType/Format/値の構造)から入力形式を自動判別し、ポリシーの形式別 handler に dispatch する:

| 判別された形式 | handler | 匿名化対象の検出 |
|---|---|---|
| Association / Association の list(入れ子含む) | Records | FieldRules(未知フィールドは既定 Redact = fail-closed)+ Keep 文字列への TextRules 三層 |
| 配列・数値テーブル | Records(ArrayElement locator) | 同上(文字列要素のみ TextRules) |
| 画像 1 枚 / 画像集合 | ImageList | 宣言 Regions + MediaScan(§6.8)。どちらも無ければ NeedsReview |
| マルチページ PDF | PageImageList | ページごとラスタ化 → 宣言 Regions + MediaScan。テキスト層があれば TextRules 適用後に破棄 |
| 混在(レコード+添付 blob) | Records + 添付を再帰 dispatch | 添付は MediaType ごとに上記へ再帰(系譜は edge で連結) |

- dispatch は決定論で、判別結果は LineageManifest に記録。判別不能な形式は `Failed`(勝手に文字列化しない)。
- 既定ポリシー `generic-universal-v1` がこの dispatch 表と保守的既定を同梱する。**既定ポリシーは Plan の候補提示用であり、実行は常に grant が policy を固定する。**

---

## 5. データモデル

### 5.1 AnonymizationPolicy

SourceVault に ingest 済みの不変ポリシー文書。JSON(canonical 化して digest)。`sv://` URI または登録名で参照。

```jsonc
{
  "ObjectClass": "AnonymizationPolicy",
  "SchemaVersion": 1,
  "PolicyId": "cerezo-collection-v1",
  "Description": "Cerezo 提出物コレクションの匿名化",
  "PolicyPrivacyLevel": 0.3,          // ポリシー文書自体の PL(§6.7)
  "SchemaPin": {                       // 省略時は universal(Dispatch: "Universal")
    "OriginClass": "CerezoCollectionRun",
    "OriginSchemaVersions": [1]
  },
  "TargetLevelDefault": 0.45,          // オーナー UI の候補提示用(自動採用はしない)
  "Tiers": {
    "0.45": { /* strength tier(§6.2 の 5 規則群) */ },
    "0.2":  { /* より強い tier */ }
  }
}
```

「編集」は新版登録(新 digest)であり、旧版で作られた成果物・キャッシュはそのまま有効。

### 5.2 DeclassificationProfile(制約テンプレート)

Profile は「安全条件のテンプレート」であり、**それ自体は許可ではない**。役割: (1) 許容 origin class/policy/target×sink の上限宣言 (2) オーナー UI への候補提示 (3) verifier・risk assessment の最低条件強制。

```jsonc
{
  "ObjectClass": "DeclassificationProfile", "SchemaVersion": 1,
  "ProfileId": "cerezo-grading-v1", "ProfileVersion": 2,
  "ParentProfileRef": "...",                       // immutable versioned snapshot
  "AllowedOriginClass": "CerezoCollectionRun",
  "AllowedOriginSchemaVersions": [1],
  "AllowedPurposes": ["grading"],
  "AllowedReleases": [                             // 直積でなく tuple(0.45×LowTrust は通らない)
    { "TargetLevel": 0.45, "SinkClass": "CloudLLM" },
    { "TargetLevel": 0.2,  "SinkClass": "CloudLLM-LowTrust" } ],
  "AllowedPolicies": ["cerezo-collection-v1"],
  "MaxUnitsPerRun": 500, "MaxOutputBytes": 50000000,
  "RequiredVerifiers": ["V1","V2","V3","L1","L2","L3","L4","L5"],
  "RequireIndependentMediaVerifier": true,
  "Principals": ["<authenticated principal>"],
  "ExpiresAtUTC": "...", "RevocationEpoch": 0,
  "RiskAssessmentRef": "sv://...", "RiskAssessmentDigest": "sha256:..."
}
```

profile の登録・変更は承認ゲート必須(mutation authorization)。承認そのものは常に独立の typed grant(§5.13)であり、profile へ承認記録を埋め込む方式は採らない。

### 5.3 PseudonymMap — SubjectToken の正本

不変性と追記を両立する三層:

- **MapId**(論理 ID): `H({VaultID, TenantID, EntityClass, NormalizedMapScope, TokenSchemeVersion, IdentityKeyId, CanonicalizationVersion})`
- **MapVersion**: ある時点の不変 snapshot。`ParentMapRef` で直前版へ連鎖。**成果物・annotation は必ず exact MapRef(特定版)を pin する。**
- **MapHead**: MapId → 最新 MapRef の可変 pointer。更新は lock + compare-and-swap。

```jsonc
{
  "ObjectClass": "PseudonymMap", "SchemaVersion": 1,
  "MapId": "map:<hex>", "MapVersion": 3, "ParentMapRef": "...",
  "MapScope": "cerezo:course:1919736:collection:1948092",
  "PolicyRef": "...", "KeyId": "idkey-1", "CanonicalizationVersion": 1,
  "CreatedAtUTC": "...",
  "Entries": [
    { "EntityID": "ent:<hmac>", "EntityClass": "Student",
      "SubjectToken": "S-7K3QX2-C",          // scope-bound・checksum 付き
      "DisplayLabel": "S-001",                // 表示専用。join key 禁止
      "Identity": { "StudentID": "5423035", "StudentName": "…",
                    "SubmissionKey": "student:5423035" },
      "KnownStrings": ["5423035", "…氏名表記ゆれ展開…"] }
  ]
}
```

- **PL 1.0 固定**。管理対象は SubjectToken のみ(ItemToken は LineageManifest、JobToken/ResultSlotToken は EvaluationPlanManifest が正本)。
- 追記手順(並行安全): `SourceVaultWithLock["anonymize-map:"<>MapId]` の範囲で (1) MapHead 再読込 (2) merge (3) uniqueness 検査(`(MapId, EntityID)`・`(MapId, SubjectToken)` 一意)(4) 新 MapVersion 保存 (5) MapHead CAS。CAS 失敗は再試行または明示失敗(二重割当 0 件)。
- `KnownStrings` は Redact 段の既知値スキャンと Verify V1 の照合辞書。氏名の表記ゆれ(姓のみ・名のみ・空白有無・全半角)は決定論展開で生成する。
- MapScope が同一なら同一実体→同一 SubjectToken(採点の書き戻しと同一課題内の比較に必要)。scope が異なれば独立採番(意図しないコース間リンクを防ぐ)。

### 5.4 LineageManifest — node/edge graph

要素単位の系譜と分割不変条件を保持する PL 1.0 の不変 snapshot。多対一・多対多(複数ページ→一答案、複数画像→一回答)を正準に表現する。

```jsonc
{
  "ObjectClass": "LineageManifest", "SchemaVersion": 2,
  "LineageSetID": "lin:<hex>",
  "Origins": [                                  // record 束縛(P-A19。平行配列禁止)
    { "OriginRef": "sv://snapshot/...", "ExpectedDigest": "sha256:...",
      "ObjectClass": "CerezoCollectionRun", "Role": "submission-run",
      "LogicalObjectID": "sobj:...", "SelectionDigest": "sha256:..." }
  ],
  "OriginSetDigest": "sha256:...",
  "PolicyRef": "...", "MapRef": "...",           // exact
  "KeyId": "idkey-1", "CanonicalizationVersion": 1,
  "SourceNodes": [
    { "UnitID": "sunit:<hmac>", "ObjectID": "sobj:<hmac>", "VersionID": "sver:<hex>",
      "Locator": { "Kind": "AssociationRow" | "ArrayElement" | "Image" | "PDFPage" | "OCRSpan",
                   "CanonicalPath": [...], "ContainerDigest": "..." },
      "ContentDigest": "sha256:..." }
  ],
  "DerivedNodes": [
    { "UnitID": "dunit:<hmac>", "ItemToken": "I-9F2K1-C",
      "SubjectToken": "S-7K3QX2-C",
      "Role": "AnswerPage" | "AnswerText" | "Submission" | "RedactedRecord",
      "MediaType": "...", "ContentDigest": "sha256:..." }
  ],
  "Edges": [
    { "EdgeID": "edge:<hex>",
      "Relation": "Split" | "Redacted" | "Extracted" | "Aggregated" | "Pseudonymized",
      "FromUnitIDs": [...], "ToUnitIDs": [...],
      "InputSetDigest": "...", "OutputSetDigest": "...",
      "TransformDigest": "...", "Cardinality": "1:1" | "1:N" | "N:1" | "N:M" }
  ],
  "Partitions": [
    { "PartitionID": "part:<hex>", "Purpose": "CloudGrading",
      "MemberUnitIDs": [...], "MemberSetDigest": "...",
      "Coverage": "Complete" | "DeclaredSubset",
      "Excluded": [ { "UnitID": "...", "Reason": "Unsubmitted" } ] }
  ],
  "Invariants": { "DuplicatePolicy": "Reject", "OrderingIsIdentity": false,
                  "ExpectedSourceNodeCount": 24, "ExpectedDerivedNodeCount": 72 },
  "ManifestDigest": "sha256:..."
}
```

低 PL 側(成果物 payload)に出るのは DerivedNodes の ItemToken(+SubjectToken)のみ。SourceUnitID・locator・実 ID・系譜参照は manifest(PL 1.0)にしか存在しない。

#### 5.4.1 入力形式別 locator 規約

| 入力形式 | locator の正本 | 必須検査 |
|---|---|---|
| Association の list | authoritative primary key(namespaced)+行内容 digest。key 無しは ingest 時に SourceUnitID 発行 | 同一 key 2 件 → `DuplicateSourceKey` 失敗。並び替え・フィールド順変更後も同一論理行へ戻ることをテスト必須 |
| 配列 | index+形状+親 digest+要素 digest の組 | reshape/filter/sort は transform edge と index mapping を記録。詰め直し index 単独での書き戻し禁止 |
| ID+画像の対応表 | authoritative ID+画像 content digest+SourceUnitID の三者 | ID 重複・1 画像多 ID・1 ID 多画像は cardinality policy に従う(自動上書き禁止)。ファイル名は identity にしない |
| 複数ページ PDF | PDF 全体 digest+元ファイル名+ページ数+physical page index+page image digest | ファイル名由来 ID は IdentityEvidence の一つ(唯一の正本にしない)。回転・crop box・DPI・テンプレート alignment を正規化してから黒塗り。順序入替/空白/表紙/差替え/重複ページを受入試験に含める |
| OCR(学籍番号・氏名欄) | §12.2 の IdentityEvidence + adjudication | ID↔氏名の roster 不一致・低 confidence・境界曖昧・員数不一致は fail-closed |

### 5.5 KeyRing・ID 式・token

#### 5.5.1 KeyRing と canonicalization

- KeyRing: `PrivateVault/secrets/sourcevault-anonymize-id-keys.json`。`{KeyId, Algorithm: "HMAC-SHA256", OutputEncoding, TruncationLength, CreatedAtUTC, Fingerprint}` の束。既定 KeyId `idkey-1`。
- 全 ID・MapId・manifest は使用した **KeyId と CanonicalizationVersion**(Unicode 正規化・数値・日時・path・Association key 順序の規則版)を pin する。
- ノード間整合: 実行開始時に鍵 fingerprint を検査し、**不一致なら匿名化・書き戻しを停止**(黙って別 ID を発行しない)。鍵紛失時は新 KeyId の明示発行のみ(旧 ID との同一性は主張しない)。rotation の正式仕様化は非目標(§18)。
- **生 ID の単純 SHA-256 は禁止**(学籍番号等の低エントロピー値は辞書攻撃可能)。必ず namespaced HMAC。

#### 5.5.2 ID 式(衝突耐性)

```text
EntityID     = HMAC(namespaceKey[KeyId], {VaultOrTenantID, institution, canonicalStudentID})
SourceObjectID = source 側 primary key の namespaced HMAC(無ければ ingest 時 UUID を provenance に固定)
SourceVersionID = canonical 化した原本の digest

SourceUnitID = HMAC(lineageKey[KeyId], CanonicalEncode({
  VaultOrTenantID, SourceObjectID,          // 論理オブジェクト(別人の同一内容を区別)
  SourceVersionID, SourceUnitKind,
  CanonicalLocatorDigest, SourceContentDigest,
  CanonicalizationVersion, LineageSchemaVersion, KeyId }))

DerivedUnitID = HMAC(lineageKey[KeyId], CanonicalEncode({
  SortedParentUnitIDs,                      // 1 件以上(N:1 対応)
  RelationType, PolicyDigest, TransformDigest,
  DerivedLocatorDigest, DerivedContentDigest,
  OutputOrdinalOrRole,                      // transform が定義する正準 role(単なる index でない)
  CanonicalizationVersion, KeyId }))
```

本質的に自動区別できない場合(同一内容の重複ページ等)は ID を推測せず `NeedsAdjudication`。

#### 5.5.3 役割別 token

| token | 対象 | 一意性の範囲 | 正本 | 露出範囲 |
|---|---|---|---|---|
| `SubjectToken` | 主体(学生) | MapScope 内 | PseudonymMap | 低 PL payload 可(グループ化が必要な場合) |
| `ItemToken` | DerivedUnit 1 個 | artifact 内一意 | LineageManifest | **低 PL payload の識別の正本** |
| `JobToken` | 外部 job 1 件 | batch 内一意 | EvaluationPlanManifest | provider payload(表示用短縮+内部は 128 bit 以上の request binding nonce を分離) |
| `ResultSlotToken` | job 内の結果 slot 1 個 | job 内一意 | EvaluationPlanManifest | provider payload(複数結果 job のみ) |
| `ReleaseHandle` | 公開成果物の取得ハンドル | グローバル | PublicationRecord(owner 側 mapping) | 低 PL 側の bearer 取得手段(§5.10) |

いずれも非意味的(乱数由来)+checksum 1 文字(転記ミス検出)。元 ID・件数・順序を推測させない。`S-001` 型は DisplayLabel(高 PL 表示専用)であり join key にしない。

### 5.6 成果物と ArtifactBinding

成果物本体(既存 DerivedArtifact クラスに統合、`ArtifactType->"Anonymized"`):

```jsonc
{
  "ObjectClass": "DerivedArtifact", "ArtifactType": "Anonymized",
  "ArtifactSchemaVersion": 2,               // legacy(v1)との reader 分岐用
  "TargetLevel": 0.45,
  "Format": "Records" | "ImageList" | "PageImageList",
  "Payload": [ /* 各 unit が ItemToken(+SubjectToken)を持つ。系譜参照・実 ID・locator なし */ ],
  "PayloadDigest": "sha256:...",
  "VerifyReportDigest": "sha256:...",
  "CreatedAtUTC": "..."
}
```

- **本体は公開状態(Status)を持たない**(正本は PublicationHead、§5.10)。
- `ArtifactRef`(content-addressed)は**内部の冪等性・整合性専用の identity** であり、低 PL 側の取得 capability ではない(§5.10 ReleaseHandle)。derived content identity は tenant/owner namespace・policy・canonicalization 版を含み、cross-tenant の同一性確認 oracle にしない。
- 系譜束縛は immutable **ArtifactBinding**(PL 1.0):

```jsonc
{
  "ObjectClass": "ArtifactBinding", "SchemaVersion": 1,
  "ArtifactRef": "...", "ArtifactDigest": "...",   // 一方向 pin(binding→artifact)
  "Origins": [ /* §5.4 と同じ record 形式 */ ], "OriginSetDigest": "...",
  "PolicyRef": "...", "MapRef": "...", "LineageManifestRef": "...",
  "ProfileRef": "...", "KeyId": "...", "CanonicalizationVersion": 1,
  "SourceRefs": [...],                              // 既存逆引き互換情報
  "BindingDigest": "sha256:..."
}
```

- create-only。**pin は一方向**: Binding → Artifact、PublicationRecord → Artifact と Binding の両方(循環 digest を作らない)。欠落・digest 不一致・差替えは release/join とも fail-closed。
- 既存逆引き `SourceVaultDerivedArtifactsForSource` は ArtifactBinding index を読む adapter 拡張が必要(additive 改修)。

**content-addressed builder(新設)**: 現行 `SourceVaultSaveDerivedArtifact` は Text/Summary 必須・ArtifactId が random で本 schema を保存できないため、`SourceVaultSaveContentAddressedDerivedArtifact[artifact, opts]` を新設する。要件: Text / Content.BlobRef / 構造化 Payload のいずれか必須、PayloadDigest 必須、**ArtifactId は content/idempotency identity から決定**(volatile field は digest から除外、同一 content → 同一 ref)、Origin/SourceRefs は ArtifactBinding へ、binary は artifact 経由でのみ解決、legacy とは ArtifactSchemaVersion で分岐。

### 5.7 Partition 不変条件

分割操作(PL 別・ページ別・添付別)は §5.4 の Partitions が保持し、次の 10 条件を検証する(§9.2 L1):

1. **Coverage**: `Complete` なら原本 unit 集合 = 分割片の親 unit 集合。
2. **DeclaredSubset**: 一部のみ対象なら除外 unit と理由を列挙(例 Unsubmitted)。
3. **Disjointness**: 重複禁止の変換では同じ SourceUnitID が複数 partition に入らない。
4. **NoUnknown**: manifest に無い unit/token を結果側が返したら失敗。
5. **NoDuplicateResult**: 同一 target への複数結果は、明示の attempt/merge policy がなければ失敗。
6. **NoMissingResult**: 全件必要な batch では欠落 1 件でも commit しない。未提出等は `NotGradable` の明示状態。
7. **Order Independence**: 現在位置(list index)だけを join key にしない。
8. **Exact Version**: 再 ingest 版へ旧版の結果を書き戻さない(明示 migration/adjudication のみ例外)。
9. **Cardinality**: 1:N / N:1 / N:M の関係型を Edges に記録。
10. **Join Preview**: commit 前に matched/missing/duplicate/unknown/version-mismatch 件数と digest を提示し、全合格時のみ一括 commit。

### 5.8 blob の privacy 意味論

- **既存共有 blob の PL は決して引き下げない**(同一 blob を高 PL オブジェクトが参照し得る)。
- 匿名化出力のバイナリは必ず新規コンテンツ(ラスタ化・再エンコードで hash が変わる)として commit し、**参照する artifact の publication 状態+release gate 経由でのみ**取得可能。privacy 判定は blob hash 単体で行わない。
- `sv://hash/...` の直接解決は「匿名化済みであることの証明」にしない(検証を通った artifact 経由のみが保証を持つ)。

### 5.9 結果の三段: quarantine → AnnotationContent → AnnotationBinding

| 段 | 内容 | 保存 | PL |
|---|---|---|---:|
| **CloudTransportResult(quarantine)** | JobToken+provider 生応答 byte | internal quarantine object: encrypted at rest・短期 TTL・owner/service principal のみ可読。get/search/MCP/Publish/unlisted のいずれの対象にもならない | **IngressQuarantinePL = Max[入力 artifact PL, EvaluationPlan の ExpectedAnnotationProtectedMinimum, 組織 IngressQuarantineMinimum]**(Cerezo Grade は**受信 byte の時点から 1.0**) |
| **AnnotationContent** | schema/range/slot/receipt 検証成功後に抽出した結果本体(ItemToken+値) | immutable | AnnotationType 別の組織 protected minimum 以上(§13.3) |
| **AnnotationBinding** | 系譜束縛 | immutable | 1.0 |

- score・reason・provider が復唱した本文は parse 前から応答 byte 内に存在する — 分類は parse 後に始まる性質ではないため、**受信時から高 PL に置く**。「外へ送った入力の PL(egress、0.45)」と「外から戻った結果の分類(ingress)」は独立であり矛盾しない。cloud が知った事実は消せないが、SourceVault から再配布する権限は別である。
- parse 失敗・未知 field・PII 再出現は PL を下げず quarantine 維持/adjudication。TTL は SourceVault 内の保持期間のみを意味し、provider 側の削除保証を意味しない。

```jsonc
// AnnotationContent
{ "ObjectClass": "AnnotationContent", "SchemaVersion": 1,
  "AnnotationType": "Grade" | "Review" | "Classification",
  "Items": [ { "ItemToken": "I-9F2K1-C", "Score": 4, "Reason": "...",
               "Attempt": 1, "Supersedes": null } ],
  "ItemsDigest": "sha256:..." }

// AnnotationBinding(PL 1.0)
{ "ObjectClass": "AnnotationBinding", "SchemaVersion": 1,
  "ContentRef": "...", "ContentDigest": "...",
  "TargetArtifactRef": "...", "TargetArtifactDigest": "...",
  "ArtifactBindingRef": "...", "LineageManifestRef": "...", "MapRef": "...",
  "EvaluationPlanManifestRef": "...", "EvaluationPlanDigest": "...",
  "EvaluationResultManifestRef": "...", "EvaluationResultDigest": "...",
  "RubricDigest": "...", "ExpectedItemTokenSetDigest": "...",
  "ResultPLAssessor": { "Version": "...", "Digest": "..." },
  "BindingDigest": "sha256:..." }
```

再採点・修正は Items 上書きでなく新 Attempt+`Supersedes`。最終採用は adjudication event で確定する。

### 5.10 PublicationRecord / PublicationHead / ReleaseHandle

**PublicationRecord**(immutable、公開 1 状態分):

```jsonc
{ "ObjectClass": "DeclassificationPublication", "SchemaVersion": 1,
  "PublicationID": "pub:<hex>",
  "ArtifactRef": "...", "ArtifactDigest": "...",
  "ArtifactBindingRef": "...", "BindingDigest": "...",
  "VerifyReportRef": "...", "ProfileRef": "...", "ProfileDigest": "...",
  "ExecutionGrantRef": "...", "PublicationGrantRef": "...",   // §5.13(該当時)
  "ExposurePolicyRef": "...",
  "TargetLevel": 0.45, "Discoverability": "Unlisted",
  "State": "Published" | "Revoked" | "Superseded" | "Expired",
  "PreparedEventRef": "event:...", "PublishedAtUTC": "...",
  "PreviousPublicationRef": null, "RevocationEpoch": 0 }
```

- **PublicationHead[ArtifactRef]** = 最新 record への単一可変 pointer。更新は atomic CAS のみ。**これが公開状態の唯一の正本**(artifact 本体は状態を持たない)。
- **release の必須条件**(gate への additive 改修): (1) active head が存在 (2) record と artifact/binding/verify/profile の digest 一致 (3) State == Published かつ revocation epoch 一致 (4) release 判定の PL は record の TargetLevel を使用。

**ReleaseHandle**(低 PL 側の bearer 取得ハンドル):

```jsonc
{ "ReleaseHandle": "sv://release/<256-bit-CSPRNG>",
  "PublicationRef": "...", "HandleDigest": "hmac:...",
  "State": "Active" | "Revoked" | "Expired",
  "ExpiresAtUTC": "...", "RevocationEpoch": 3 }
```

- **content から導出しない**(CSPRNG、最低 128 bit・推奨 256 bit)。content hash は誰でも同じ内容から再計算でき、既知平文の列挙照合・cross-tenant 同一性確認・rotation 不能という問題があるため、capability として扱わない。
- handle→Publication の対応表はオーナー側 protected object。revoke/expire/**rotate**(新 handle 発行、content identity は不変)が可能で、release 時に PublicationHead と同じ epoch を検査する。
- 無許可の Reuse は `SourceVaultGet[releaseHandle]` の bearer access としてのみ成立する(§10.5)。
- handle は準機密: 低 PL ログ・通知・diagnostics・provider payload に平文で書かない(ledger には keyed HMAC)。外部 adapter は handle を URL path/query に載せず、redaction 対象の Authorization header または request body で渡す(proxy/access log/browser history/APM への漏洩防止)。

### 5.11 EvaluationUnit / EvaluationPlanManifest / EvaluationResultManifest

**EvaluationUnit** = 採点の単位(一受験者/一提出物。複数ページ・添付を含む):

```jsonc
{ "EvaluationUnitID": "eunit:<hmac>",
  "SubjectAttemptRefDigest": "...",
  "Members": [                                   // record multiset(P-A19)
    { "ItemToken": "I-...", "DerivedContentDigest": "...",
      "MediaType": "...", "Role": "answer-page-1" } ],
  "MemberMultisetDigest": "...", "ExpectedResultCardinality": 1 }
```

**EvaluationPlanManifest**(送信前に immutable、PL 1.0):

```jsonc
{ "ObjectClass": "EvaluationPlanManifest", "EvaluationBatchID": "batch:<hex>",
  "TargetArtifactRef": "...", "TargetPublicationDigest": "...",
  "RequestDigest": "...", "RubricDigest": "...",
  "DistributionPlanRef": "...",
  "Jobs": [
    { "JobID": "job:<hex>", "JobToken": "J-4T8M2-C",
      "AttemptID": "...", "RequestBindingNonceDigest": "...",   // 内部 128bit nonce(表示 token と分離)
      "EvaluationUnitID": "eunit:...",
      "ResultSlots": [                            // 複数結果 job のみ
        { "ResultSlotToken": "R-<random>", "TargetItemToken": "...",
          "ExpectedOutputSchemaDigest": "..." } ],
      "ExpectedResultSlotMultisetDigest": "...",
      "RequestContentDigest": "..." } ],
  "ExpectedJobSetDigest": "..." }
```

**EvaluationResultManifest**(受信後に immutable):

```jsonc
{ "ObjectClass": "EvaluationResultManifest", "PlanRef": "...", "PlanDigest": "...",
  "Jobs": [ { "JobID": "...", "ResponseDigest": "...", "ProviderReceipt": "...",
              "Status": "Completed" | "Failed" | "Timeout" } ] }
```

- **結果帰属の正本は Plan の JobID→EvaluationUnit(→ResultSlot→ItemToken)の out-of-band binding**。LLM が本文中で名乗った token・配列順・ファイル名・自然言語記述を join key にしない。
- 一 job 一結果なら score は unit/attempt に束縛。設問別・ページ別など複数結果は ResultSlotToken で slot 単位に束縛(provider は slot token を復唱するだけで、ItemToken は知らない)。
- 受理時検証: unknown/missing/duplicate slot・別 Attempt・別 RequestDigest・別 provider receipt・replay はいずれも unit 全体で fail-closed。transport の request ID/provider receipt とローカル job state を pin する。
- AnnotationBinding は Plan/Result 両 manifest の ref/digest を pin する。

### 5.12 監査イベント

正準はイベントログ(snapshot class は追加しない)。主要 EventClass:

- `SourceVaultDeclassified`(Publish 成立。grant/profile/verify 要約・元 PL→先 PL。PII 非含有)
- `PublicationPrepared`(durable、head CAS 前)/ `PublicationCompleted`(best-effort、CAS 後)— CAS 完了前の正本状態は「未公開」。Prepared に「Published」と虚偽記録しない。監査回復は Prepared+head の突合。
- `PublishedReuse` / `Reverified` / `Revoked` / `Superseded`
- Exposure 系(§5.14)

### 5.13 typed grants と execution lease

**権限は効果別に型で分離する**(一つの grant を複数の効果に流用しない):

| grant | 許可する効果 | 主な pin |
|---|---|---|
| **DeclassificationExecutionGrant** | 高 PL 本文を読む匿名化 Execute(+PublishMode が PublishIfVerified なら検証合格時の Publish まで) | Plan digest・Origins(record 形式+OriginSetDigest)・SelectionSpecDigest・PolicyRef/Digest・**ExactTargetLevel**・MapScopeDigest・Purpose・IntendedSink・PublishMode・ExposurePolicyRef・DistributionPlanRef・MaxUnits・action 別 MaxUses・ExpiresAtUTC・Nonce |
| **ArtifactPublicationGrant** | `StageForOwnerReview` で Staged になった**特定成果物**の Publish | StagedArtifactRef/Digest・ArtifactBindingDigest・VerifyReportDigest・ExactTargetLevel・Discoverability・ReleaseHandlePolicyDigest・OwnerDecisionAtUTC |
| **EvaluationEgressGrant** | 公開済み成果物の cloud への送信(採点等) | TargetArtifactRef+PublicationDigest・EvaluationPlanDigest・provider/sink・DistributionPlanRef・subject/byte budget・期限 |

共通要件:

- **発行はオーナーのみ**: agent/LLM は grant を自己作成・自己承認できない。owner identity は authenticated principal + acts-for/custodian 根拠(`OwnerAuthorityRef`)で検証(文字列 "owner" は不可)。multi-owner origin はポリシーが定める all-owner/custodian 承認。
- **approval receipt**: UI の authenticated session・step-up 認証・(利用可能なら)KMS/HSM 鍵による署名・receipt digest・request/decision timestamp・principal/acts-for chain を pin する。署名と MAC の trust model を混同しない(service 自身が生成できる MAC だけでは自己承認排除を証明できないことを明記)。
- 一項目でも不一致(origin digest / selection / policy / target / purpose / sink)なら実行前拒否。origin の版変更は TOCTOU として grant 無効化。
- **GrantExecutionLease**: 使用は `Reserved(OperationID, exact inputs) → Committed | Aborted | Indeterminate` の lease で管理。同一 OperationID の retry は冪等に再開し、別入力への replay は拒否。use count は action 別に消費(crash のたびに再承認を要求せず、かつ再利用も許さない)。
- `StageForOwnerReview` の grant では、**staged 成果物の Publish は ArtifactPublicationGrant なしに head CAS してはならない**(元 grant の流用禁止 — 「見てから公開を決める」の意味を保つ)。

### 5.14 ExposureLedger / ExposurePolicy

**ExposureEvent**(高 PL・append-only・本文/実 token 非含有)。event class は事象別に分ける:

| EventClass | 意味 | coverage 加算 |
|---|---|---|
| `PublicationActivated` | 公開可能状態の成立(潜在的可用性) | しない |
| `ContentReleased` / `CloudEgressed` | 実際の開示(get/download/export/LLM 送信) | **する** |
| `CloudIngressReceived` | provider からの受信 | しない |
| `AggregateCreated` | 集約物の生成(CompositionPolicy 用) | 別軸 |
| `ReleaseDenied` / `ReleaseIndeterminate` | 拒否/送信後結果不明(**privacy 上は Released と数える**) | Indeterminate はする |

共通フィールド: `ExposureScopeID`(owner-only key の HMAC)・OriginCohortDigest・ArtifactRefDigest・PublicationRef・Purpose・ProviderTrustDomain/Provider/ModelID・AccountOrTenantDigest・SessionID/BatchID・DistinctSubjectCount/ItemCount・SubjectSetDigest/VariantSetDigest(keyed HMAC+key epoch+canonical set encoding)・Bytes・`ReaderPrincipalDigest`(匿名 bearer は専用 bucket)・DestinationTrustDomain・Operation・RequestID・GuardDecisionRef・AtUTC。

**release 前 durable 記録(WAL)**:

```text
PreReleaseIntent(durable, RequestID, planned subjects/sink)
  -> GuardDecision -> Released(receipt/digest) | NotReleased | Indeterminate
```

- content byte を reader/provider へ返す**前に**、少なくとも local append-only WAL への durable append を成功させる。central rollup 不通時は local WAL+保守的な未同期 budget で判定。**local durable 記録すらできなければ release しない**。
- 「manual である」という自己申告を security boundary にしない — exact ReleaseHandle の get・MCP get・download・export・LLM egress の**すべて**を事前 guard 対象にする(閾値未満は自動 Permit されるため、通常の単発参照の体感は変わらない)。
- retry は RequestID で dedupe。別 destination/session への再送は新 exposure。

**ExposurePolicy**(オーナー設定、grant が pin):

```jsonc
{ "MaxSubjectsPerSession": 1,
  "MaxDistinctSubjectsPerProviderPerWindow": 20, "Window": "24h",
  "MaxCohortCoveragePerProvider": 0.25,
  "MaxVariantsPerOriginPerProvider": 1,
  "MaxProvidersPerRun": 2,
  "AlertThreshold": 0.15, "RequireOwnerReapprovalThreshold": 0.25,
  "OnLedgerUnavailable": "StopAutomatedEgress" }
```

規範化必須項目: 閾値の単位、cohort denominator の正本と版、window 境界・遅延 event・clock skew、provider/tenant/account/backend → trust domain の正規化規則、distinct subject と variant の union 算法・retry dedupe、複数 policy 該当時の precedence、owner 再承認後の budget reset/例外枠。これらは決定論テストで検証可能にする。

複数 PC: 各ノードが append-only event を記録し、owner の安定 HMAC scope で rollup。詳細 ledger は高 PL/暗号化、cross-machine diagnostics へは sanitized count/digest のみ。rollup stale で大規模自動処理を続行しない。

### 5.15 control-plane object の分類表

| object | PL | reader | 検索可否 | 備考 |
|---|---:|---|---|---|
| AnonymizationPolicy(一般) | < 0.5 | 通常 | 可 | センシティブ規則入りは ≥ 0.5 |
| DeclassificationProfile | 0.85 | owner/service | 不可 | 許容範囲自体が情報 |
| AnonymizationPlan | 0.85 | owner | 不可 | 件数・schema を含む |
| 各種 grant / lease / approval receipt | 1.0 | owner/service | 不可 | |
| PseudonymMap / LineageManifest / ArtifactBinding / AnnotationBinding / EvaluationPlan・Result / IdentityEvidence | 1.0 | owner/service | 不可 | |
| PublicationRecord / head | 0.85 | owner/service(gate は判定参照のみ) | 不可 | low-side projection に GrantRef・BindingRef を出さない |
| ReleaseHandle mapping | 1.0 | owner/service | 不可 | |
| CloudTransportResult(quarantine) | ≥ protected minimum(Grade 1.0) | owner/service | 不可 | encrypted at rest・TTL |
| 成果物(DerivedArtifact) | TargetLevel | ReleaseHandle bearer | **不可(Unlisted)** | |
| AnnotationContent | protected minimum 以上 | 高 PL 側 | 不可(Unlisted) | |
| ExposureLedger | 1.0 | owner/service | 不可 | diagnostics へは sanitized のみ |

---

## 6. ポリシーファイル仕様

### 6.1 登録と参照

```wolfram
SourceVaultRegisterAnonymizationPolicy[assocOrFile]   (* ingest+snapshot+registry。<|Status,PolicyId,URI,Digest|> *)
SourceVaultAnonymizationPolicies[]                    (* 一覧(View 版は Dataset) *)
SourceVaultAnonymizationPolicy[idOrURI]               (* PolicyId | sv:// | snapshot ref *)
```

### 6.2 tier スキーマ(5 規則群)

```jsonc
{ "FieldRules":     { "<path pattern>": <FieldRule>, ... },
  "TextRules":      { "Patterns": [...], "KnownValueScan": true,
                      "PrivateModelScan": true, "Replacement": "[REDACTED]" },
  "PseudonymRules": { "Scope": "<MapScope 式>", "EntityClasses": {...} },
  "Generalization": { "<attr>": <hierarchy>, ... },
  "KAnonymity":     { "K": 1, "QuasiIdentifiers": [...], "OnFail": "Suppress" },
  "Transforms":     [ <TransformRule>, ... ] }
```

### 6.3 FieldRules

path pattern は Association の階層パス(`"Top.StudentName"`, `"Detail.Files.*.URL"`, `"*"`)。より具体的なパスが勝つ。**未マッチの既定は `"Redact"`(fail-closed)**。

| FieldRule | 意味 |
|---|---|
| `"Keep"` | 保持(文字列値は TextRules を通す) |
| `"KeepRaw"` | TextRules も通さず保持。**`"AllowedType"`(enum/number/boolean/値集合/range)の宣言必須** — 自由文字列への KeepRaw は登録時拒否 |
| `"Drop"` | フィールド削除 |
| `"Redact"` | `Replacement` 定数に置換 |
| `{"Pseudonym", "<EntityClass>", "<attr>"}` | 仮名化(値 → SubjectToken)。Identity 収集元 |
| `{"Generalize", "<hierarchy 名>"}` | 一般化階層適用 |
| `{"Template", "<テンプレ>"}` | 許可トークンのみで再構成(例 `"{SubjectToken} さんが提出したレポート"`) |

汎用 Hash 置換 rule は提供しない(低エントロピー値の salted hash は総当たり可能。リンク用トークンが必要なら §5.5 の HMAC ID 基盤を使う)。

### 6.4 TextRules(自由テキスト三層)

`"Keep"` されたすべての文字列値に適用:

1. **KnownValueScan**(決定論): PseudonymMap の全 KnownStrings(実 ID・氏名・表記ゆれ展開)を検索し、SubjectToken または Replacement に置換。**最重要層**(実例: ExtractedText 先頭の生学籍番号はここで確実に落ちる)。
2. **Patterns**(決定論): ポリシー宣言の正規表現群。標準セット `jp-pii-basic-v1` 同梱: 学籍番号形・メール・電話・郵便番号+住所手掛かり・percent-encoded 日本語ファイル名・「〜さん/君/氏」直前の人名候補・属性語彙(「3年生の女性」型の間接識別記述)。
3. **PrivateModelScan**(シーム): `$ClaudePrivateModel`(ローカル LLM)に残存 PII span の列挙を依頼し置換。**ローカル限定**(入力はまだ高 PL)。不通時は Verify が `NeedsReview`(fail-closed)。

### 6.5 Generalization / KAnonymity

- 標準階層 5 種同梱: `timestamp→date` / `timestamp→week` / `date→month` / `age→decade` / `dept→faculty`。カスタムは `{"Levels": [...]}`。
- `K >= 2` で(一般化後の)準識別子組の同値類サイズを検査。違反時 `OnFail`: `"Suppress"`(違反レコードの準識別子を Replacement 化・レコードは残す、既定)/ `"GeneralizeUp"`(一様に 1 段粗くして再検査)/ `"Fail"`。
- **`K:1` は「検査なし」であり匿名性の根拠にしない**。構造化準識別子 = 本節、テキスト内準識別子 = §6.4 の責務分担。

### 6.6 Transforms

| TransformRule | 入力→出力 | 内容 |
|---|---|---|
| `{"ImageRedact", "Regions": [...]}` | 画像→画像 | 正規化座標矩形を黒塗り(ラスタ上書き・メタデータ/レイヤ破棄の再エンコード) |
| `{"PDFPageImages", "DPI": 150, "Regions": [...], "Pages": All}` | PDF→画像リスト | ページごとラスタ化+指定領域黒塗り(例: 学籍番号・氏名欄)。`Format: "PageImageList"` |
| `{"TextOnly"}` | レコード→テキスト | 添付・バイナリを落とし抽出テキストのみ(強 tier 向け) |

原則: **変換は必ずラスタ化・再エンコードを伴う**(PDF テキスト層・EXIF・レイヤに元情報が残る「見かけ黒塗り」の構造的排除)。

### 6.7 ポリシー自身の PrivacyLevel

一般ポリシー(汎用パターン・汎用階層のみ)< 0.5。センシティブポリシー(特定個人の別名リスト・内部組織構造を写す階層等)≥ 0.5(ポリシー文書自体が release gate で保護される)。承認可否はポリシー PL では決めない(grant が決める)。

### 6.8 MediaScan(画像・PDF ラスタ内 PII の自動検出黒塗り)

- ローカル OCR/vision(`$ClaudePrivateModel` の vision 経路、注入シーム `MediaScanFn`)でテキスト・顔・ID 形状を検出し黒塗り。**検出器はローカル限定**。検出証跡(engine/version/region/confidence)は PL 1.0。
- fail-closed: 検出器不通・confidence 閾値未満・「読めないがテキストらしき領域」は `NeedsReview`。宣言 Regions がある場合は**必ず塗った上で** MediaScan を追加適用(排他でない)。
- **V5 verifier は redaction detector と独立系統**(別 identity/prompt/model、可能なら別方式)。同一 detector の再実行だけで合格にしない(共通モード false negative 対策)。V5 は (a) 宣言 Regions の決定論検査 (b) OCR テキスト層不在 (c) pixel 領域単色性 (d) metadata 不在を個別検査。auto Publish には profile が独立 verifier identity を要求。

---

## 7. 公開 API(SourceVault 一般層 = SourceVault_anonymize.wl)

すべて `SourceVault`` コンテキスト。privacy 契約(§16.1)と `privacy_reviewed.m` 登録必須。

### 7.1 四段階 API

```wolfram
SourceVaultAnonymizationPlan[origRef, opts]
  (* schema-only。payload/blob 解決・KnownStrings/Identity 生成・MediaScan/OCR/LLM・
     AdHocOrigin 保存・Map 追記・ItemToken 生成を行わない(本文 hash 計算も schema-only と呼ばない)。
     返り値: ObjectClass/SchemaVersion/MediaType/件数の安全な範囲/候補 handler/
             利用可能 policy・profile/target・sink 選択肢(オーナー UI 向け) *)

SourceVaultRequestDeclassification[planRef, opts]       (* 承認要求(NBAccess フロー) *)
SourceVaultApproveDeclassification[requestRef, decision]
  (* オーナー対話環境のみ。ExactTargetLevel/policy/sink/範囲/PublishMode を固定した
     DeclassificationExecutionGrant を発行 *)

SourceVaultAnonymize[origRef, "GrantRef" -> grantRef, opts] → <|
  "Status" -> "OK" | "NeedsReview" | "Failed",
  "ArtifactRef" -> ..., "PublicationDigest" -> ...,
  "ReleaseHandle" -> ...,                 (* Published 時のみ *)
  "PrivacyLevel" -> 0.45, "PublicationState" -> "Published" | "Staged",
  "Payload" -> ..., "CacheHit" -> True|False,
  "Report" -> <|...検証要約(PII 非含有)...|> |>
  (* Options: "TargetLevel"->Automatic(= grant の ExactTargetLevel 解決。数値明示が grant と
     不一致なら DeclassificationTargetMismatch)、"Policy"/"MapScope"->Automatic、
     "Force"->False、"KeepFailed"->False、"PrivateModelScanFn"/"MediaScanFn"->Automatic(シーム。
     差し替えは cache identity に反映)、"Purpose"/"IntendedSink"(grant と照合)、
     "OriginMode"->"Persist"(直渡し値を AdHocOrigin snapshot 化・書き戻し可)|"PreviewOnly"
     (snapshot なし・Publish 不可・書き戻し拒否)。両モードとも grant 必須。
     mutable origin は grant 対象外 — 事前に immutable snapshot 化する(§8.1) *)

SourceVaultPublishStagedArtifact[stagedRef, "PublicationGrantRef" -> pubGrant]
  (* StageForOwnerReview の staged 成果物を、artifact-bound PublicationGrant により Publish *)
```

### 7.2 系譜・結果・書き戻し

```wolfram
SourceVaultValidateLineage[refOrAnnotation]
  (* graph/partition/token の機械検証: source/derived unit 数・missing/duplicate/unknown/
     version-mismatch・manifest digest・map version を報告。PII 値は含めない *)
SourceVaultCreateDerivedAnnotations[artifactRef, resultEnvelope, opts]
  (* quarantine から検証済み結果を取り出し AnnotationContent+Binding を生成。
     Plan/Result manifest と突合し、token/slot の欠落・重複・未知は Failed *)
SourceVaultValidateDerivedJoin[annotationRef]      (* join preview(§13.1-10) *)
SourceVaultAttachDerivedResults[annotationRef, opts]
  (* 全件合格時のみ原子的に PL 1.0 の結合結果を返す/保存。
     origin/map/scope の引数上書きは受けない(指定があれば fail-closed) *)
SourceVaultReidentify[data, mapRef]                (* 高 PL 対話用。PrivateResult[...,1.0] *)
SourceVaultPseudonymMap[mapRefOrMapId]             (* 対応表(MapId なら head)。PL 1.0 *)
```

### 7.3 ライフサイクル・監査

```wolfram
SourceVaultRevokeDeclassifiedArtifact[artifactRef, reason]   (* 要 mutation authorization *)
SourceVaultRotateReleaseHandle[artifactRef]                  (* 新 handle 発行・旧無効化 *)
SourceVaultAnonymizationAuditSummary[]     (* 低 PL: 件数・状態集計のみ *)
SourceVaultAnonymizationAudit[opts]        (* 高 PL/owner: refs・principal・reason 含む *)
SourceVaultAnonymizedVariants[origRefOrURI]
  (* origin を読む権限を持つ principal 専用(unlisted の唯一の一覧経路) *)
SourceVaultAnonymizationVerify[artifactOrPayload, opts]      (* V/L 検査の独立再実行 *)
```

### 7.4 定数

```wolfram
$SourceVaultDefaultAnonymizationPolicy = "generic-universal-v1"   (* Plan 候補提示用 *)
$SourceVaultAnonymizeEngineVersion     = "anonymize-1"            (* EngineDigest の一成分 *)
```

---

## 8. 匿名化パイプライン

### 8.1 処理段

| 段 | 名称 | 内容 |
|---|---|---|
| **0a** | **AuthorizeWithoutPayload** | grant 署名/receipt・owner authority・immutable OriginRef・metadata 版/etag・policy/target/purpose/sink 一致・期限/budget を**本文非読で**検証し、execution lease を Reserve。 不合格は `NeedsOwnerApproval`/`DeclassificationTargetMismatch` で即返し |
| **0b** | **OpenExactOrigin** | 許可後に exact snapshot を開き streaming digest を再計算。期待 digest と不一致なら transform 前に fail-closed(TOCTOU)。mutable origin はここに来ない(grant 対象外) |
| 1 | Resolve & Dispatch | 形式自動判別(§4.1)・鍵 fingerprint 検査 |
| 2 | Identify | OriginManifest(SourceNodes 列挙、locator 規約)・SourceObjectID/SourceUnitID 確定 |
| 3 | Plan 束縛 | tier 選択・FieldRules 束縛・cache identity 計算(§11) |
| 4 | Pseudonymize | MapId 解決 → lock/CAS 追記 → SubjectToken。KnownStrings 展開 |
| 5 | Redact / Generalize | 決定論(KnownValueScan+Patterns)→ PrivateModelScan(シーム)→ 一般化+k 検査 |
| 6 | Transform | 形式変換+MediaScan。DerivedNodes/Edges/Partitions 構築・ItemToken 採番 |
| 7 | Verify | privacy V1–V5 + lineage L1–L5(§9) |
| 8 | Stage & Publish | §8.2。lease を Committed へ |

### 8.2 二相 publish

```text
Draft -> Staged -> Verified -> Published(= PublicationHead が指す)
                   \-> Failed
Published -> Revoked | Superseded | Expired   (新 record + head CAS)
```

1. Staging: artifact・blob・ArtifactBinding・LineageManifest・VerifyReport・PublicationRecord 案を保存(head 未更新なので release gate から不可視)。
2. 全 digest・不変条件を再検証。`StageForOwnerReview` grant ならここで停止しオーナーの ArtifactPublicationGrant を待つ。
3. durable `PublicationPrepared` event。
4. **PublicationHead を atomic CAS**(公開の唯一の決定点)+ ReleaseHandle 発行。
5. best-effort `PublicationCompleted` event(欠けても Prepared+head から監査回復)。

- direct snapshot ref を含む**全 release 経路**が head を確認する。どの段の障害でも観測可能な状態は「未公開」。
- 実装は内部 API `SourceVaultPublishDeclassifiedArtifact`(非 export、exact grant/record/verify を要求)に集約。手動 PL 設定経路の直接呼出し禁止。

---

## 9. 検証ゲート(Publish 条件 = V 全合格 ∧ L 全合格)

### 9.1 privacy verify(V1–V5)

| 検査 | 内容 | 不合格時 |
|---|---|---|
| **V1 既知値非出現** | PseudonymMap の全 KnownStrings(正規化: 全半角・大小・空白)がどの文字列にも非出現 | `Failed` |
| **V2 パターン再スキャン** | tier の Patterns+標準セットで再走査、ヒット 0 件 | `Failed` |
| **V3 ローカル LLM 判定** | `$ClaudePrivateModel` による「特定個人を識別できるか」判定(シーム)。PrivateModelScan 有効ポリシーで必須 | `NeedsReview` |
| **V4 k 匿名性** | `K>=2` 指定時、同値類サイズ ≥ K | OnFail 後も違反なら `Failed` |
| **V5 変換完全性** | 独立 verifier(§6.8): Regions 決定論検査・テキスト層不在・pixel 単色性・metadata 不在 | `Failed` |

VerifyReport には PII そのもの・IdentityEvidence 実体を含めない(件数・パス・検査名・evidence ref のみ)。

### 9.2 lineage verify(L1–L5)

| 検査 | 内容 |
|---|---|
| **L1 Graph/Partition** | §5.7 の Coverage/DeclaredSubset/Disjointness・Edge cardinality 整合・member set digest 一致 |
| **L2 ItemToken multiset** | payload の ItemToken **multiset** == manifest 期待 == partition 期待、かつ `(ItemToken, PayloadContentDigest, MediaType, Role)` 組の一致(「1 ページ欠落+別ページ複製」を件数同数でも検出) |
| **L3 Exact pin** | artifact ↔ ArtifactBinding ↔ LineageManifest ↔ MapVersion ↔ Origins の digest 一致 |
| **L4 非漏洩** | 低 PL payload/annotation content に ID・locator・系譜参照・元ファイル名が不在(ItemToken/SubjectToken を除く) |
| **L5 カウント** | Expected node counts と実数の一致 |

---

## 10. 承認・公開・失効

### 10.1 承認の構造

許可の実体は typed grant(§5.13)のみ。Profile は制約テンプレート(§5.2)。grant の発行はオーナー対話環境+approval receipt。実行時判定は grant の pin と呼び出し(Purpose/IntendedSink/TargetLevel/origin digest/policy)の完全一致。

### 10.2 universal ポリシーの制限

universal(SchemaPin なし)も schema-pinned も、**grant なしでは Execute 不可**。universal 経路の PublishMode は `StageForOwnerReview` を推奨既定とする(生成・検証まで自動、公開はオーナーが staged preview を確認して ArtifactPublicationGrant で確定)。定型業務(Cerezo 等)は `PublishIfVerified` grant により全自動化できる。

### 10.3 Publish

内部 API に集約(§8.2)。監査 durable → head CAS の順序を強制する唯一の経路。

### 10.4 ライフサイクル

状態の正本は PublicationHead。release gate・MCP 解決・キャッシュヒット・ReleaseHandle get は毎回 head を解決し、record の digest・State・revocation epoch を確認する。

### 10.5 PublishedReuse fast path

- **無許可の reuse は exact ReleaseHandle の bearer get のみ**。
- origin→variant の解決(`SourceVaultAnonymizedVariants`・policy/target 指定の照会)は **origin を読む権限を持つ principal 専用**。権限がない場合、variant の存在/不在で error code・件数・timing を変えない(存在 oracle 防止)。
- `SourceVaultAnonymize[highOrigin]` の grantless fast path は owner/high-side authorization が確認できる場合のみ: (1) schema-only で exact Published variant index を検索 (2) head が Published (3) requested policy/target が exact match (4) engine/verifier/policy の現行有効性 (5) 非 Revoked/Expired/Superseded — 合致すれば `PublishedReuse` として監査(+ExposureEvent)し返却。なければ本文へ進まず `NeedsOwnerApproval`。

### 10.6 失効の区別

- **grant の失効**(未使用 grant の revoke・実行中 lease の cancel)と**publication の失効**(公開済み成果物の Revoke/Supersede/Expire)は別効果。grant revoke は過去の publication を自動 revoke しない — オーナー UI が連動 revoke を提案する。
- publication revoke 後: head 参照の全経路(gate/MCP/handle)が拒否。**既に外部へ渡った copy は回収不能**であることを監査に表示する。
- ReleaseHandle は publication と独立に revoke/rotate 可能(handle 漏洩対応。content identity は不変)。

---

## 11. キャッシュと露出の分離

**二層 identity**:

```text
TransformCacheIdentity = SHA256(canonicalJSON({
  OriginManifestDigest, SelectionManifestDigest,
  PolicyDigest, TargetLevel, NormalizedMapScopeDigest,
  UsedMappingDigest,          // 実使用 mapping subset: H(sorted {EntityID, SubjectToken, TokenSchemeVersion})
  LineageSchemaVersion, KeyId, CanonicalizationVersion,
  AnonymizeEngineDigest,      // コード版+PatternSet+Normalization
  PrivateScannerIdentity, MediaScanIdentity, VerifierIdentity, TransformIdentity }))

PublicationIdentity = SHA256(canonicalJSON({
  <TransformCacheIdentity の成果物 ref>, ProfileRef/Digest,
  Purpose, SinkClass, GrantRef, RevocationEpoch }))
```

- **transform(計算の再利用)と publication(公開の権限)を独立評価**: 同じ匿名化 content の別 purpose/sink 利用は再計算不要だが、publish/egress authorization は毎回評価。
- `UsedMappingDigest` により MapHead に無関係な entry が増えても cache 有効。使用 mapping の token 変更時のみ無効化。
- **cache reuse と egress exposure は別事象**: cache hit・no-op・PublishedReuse でも、新しい provider/session/sink へ渡る場合は PreReleaseIntent → guard → ExposureEvent を通す。
- ヒット時再検証: head 状態・digest・revocation epoch(§10.4)。
- `"Force"->True` の再計算が同一 content(同一 ref/digest)に到達したら `Reverified` イベントのみ(自己 Supersede しない)。異なる ref なら旧を Superseded、新を Published。

---

## 12. フォーマット変換匿名化(画像・PDF・OCR)

### 12.1 変換と系譜

- page 単位の SourceUnit(PDF 全体 digest+page index+page image digest)。回転・crop box・DPI・alignment を正規化してから黒塗り。ページ順入替・空白・重複ページに digest ベースで頑健。
- 黒塗りは必ずラスタ化・再エンコード+V5(独立 verifier)。page/derived 画像は DerivedNodes+Edges(1:N/N:1)で表現。

### 12.2 OCR による identity と IdentityEvidence

OCR 出力を identity として即採用しない。**IdentityEvidence(PL 1.0 の immutable snapshot)**として保存し adjudication を経て確定:

- 記録: OCR engine/version/config・page digest・bounding box・raw text・normalized candidate・confidence・StudentID 候補と氏名候補の一致/不一致・roster(名簿)照合・複数ページ間の継続性根拠・adjudication 状態(`AutoConfirmed/NeedsAdjudication/Rejected`)と担当者。
- fail-closed 条件: ID と氏名が roster 上で別人 / 同一 ID の不可能な位置での重複 / confidence 閾値未満 / ページ境界曖昧 / 想定人数・冊数・ページ数の不一致 → `NeedsAdjudication`(自動確定しない)。
- 目視確定は原本 digest と候補を固定した append-only adjudication event。
- VerifyReport・監査 event には `IdentityEvidenceRef` のみ(実体を入れない)。
- 運用推奨: 答案テンプレートに barcode/QR/機械可読冊子 ID を付け、OCR 氏名を主 join key にしない。

---

## 13. 結果の受理と書き戻し

### 13.1 正準フロー

1. 原本を immutable snapshot 化 → OriginManifest/SourceUnitID 確定。
2. 匿名化(grant 下): exact MapVersion+LineageManifest+ItemToken → Publish+ReleaseHandle。
3. **exact Published artifact を pin した EvaluationPlanManifest** を送信前に確定(TargetArtifactRef+PublicationDigest。高 PL run からの「最新 variant」暗黙選択禁止)。
4. オーナーが EvaluationEgressGrant(provider/budget/DistributionPlan)を承認。
5. **一受験者 = 一 EvaluationUnit = 一 cloud request/session**。provider へは JobToken(複数結果 job は+ResultSlotToken)+匿名化本文のみ。**ItemToken/SubjectToken/artifact URI/ReleaseHandle は送らない**。conversation history を受験者間で共有しない。
6. 送信前: PreReleaseIntent(durable WAL)→ ExposureGuard → 送信。応答は transport request ID/provider receipt とローカル job state を pin。
7. 生応答は**受信 byte から quarantine**(§5.9)。schema/range/slot multiset/receipt/replay 検証成功後に AnnotationContent+Binding 化。
8. 書き戻し前検証: exact artifact/map/lineage/evaluation digest・件数・token/slot multiset・schema・score range。
9. join 経路: `(ResultSlotToken →) ItemToken → DerivedUnitID → SourceUnitID → SourceObjectID/EntityID`(高 PL、Plan の out-of-band binding が正本)。
10. **全件 join preview 合格時のみ**原子的に PL 1.0 で一括 commit。部分書き戻し禁止。

### 13.2 誤帰属防止の機械的保証

binding digest 不一致・別 variant・別 MapRef は `LineageMismatch` で 0 件失敗。token/slot の欠落・重複・未知・replay は unit/batch 全体で失敗。配列 index・ファイル名・LLM が本文中で名乗った情報を join key にしない。ItemToken 一意性により同一学生の複数ページも page 単位で一意帰属。

### 13.3 結果の PrivacyLevel

```text
AnnotationContent PL = Max[ 入力 artifact PL,
                            AnnotationType の組織 protected minimum(Grade: Cerezo=1.0、Review: owner policy),
                            出力スキャン推定(V1/V2 を理由文にも適用 — KnownStrings 再出現で失敗),
                            CompositionPolicy 判定(§13.5) ]
```

protected minimum は組織 policy registry の保護値(profile が下回る値を宣言できない)。下げたい場合は成績データに対する**別の** declassification grant。assessor の version/digest を AnnotationBinding に記録。逆写像後(実 ID と結合後)は常に PL 1.0。

### 13.5 CompositionPolicy

- `AnnotationType == "Grade"` を 1 件でも含む永続 object → Grade minimum PL 以上。
- **複数 subject の個別 score/reason を含む list/table → PL 1.0**(0.5 未満の断片 × N は秘匿性を持つ)。
- SubjectToken/ItemToken ↔ score の対応表 → PL 1.0。
- cohort の平均・分布等の統計のみの公開も、低 PL 化には別の statistical release policy+owner grant が必要。差分プライバシー未実装の間、少人数集計を自動で低 PL と判定しない。
- 判定器 `SourceVaultEstimateComposedPrivacy`: AnnotationType/データクラス tag・distinct subject count・cohort coverage・個別値残存・token linkability・group size/min cell size・variant 数・集約演算子・assessor 版を入力。**単純 Max[入力 PL] では判定しない**。

### 13.6 EvaluationDistributionPlan

```jsonc
{ "Mode": "SingleSubjectSessions" | "DisjointProviderShards",
  "AllowedProviders": [...], "ProviderTrustDomains": {...},
  "MaxSubjectsPerSession": 1, "MaxSubjectsPerProvider": 20,
  "AssignmentSeedDigest": "...", "Disjoint": true,
  "AllowCrossProviderDuplicateSubject": false }
```

- EgressGrant が pin。未許可 provider・上限超過・同一 subject の重複送信(冗長採点はオーナー明示承認のみ)を拒否。
- **provider 分散は自動的に安全ではない**(trust domain が増える)。同一企業・account・共有 backend は同一 trust domain。session 分離は prompt context の分離であり provider の server-side 横断集約までは防げない — 残余リスクをオーナー UI に表示。

---

## 14. Cerezo 適用(Cerezo.wl に集約)

### 14.1 フィールド分類(cerezo-collection-v1 の根拠表)

`CerezoCollectionData` の行(実データ確認済み)に対する tier 別規則。SchemaPin: `{OriginClass: "CerezoCollectionRun", OriginSchemaVersions: [1]}`。MapScope 式 = `CollectionKey`(課題単位で SubjectToken 安定。コース・年度跨ぎの結合は別ポリシーの明示選択)。

| フィールド | 分類 | 0.45 tier | 0.2 tier |
|---|---|---|---|
| `Top.StudentName` | 直接識別子 | Pseudonym → SubjectToken | 同左 |
| `Top.StudentID` / `SubmissionKey` | 直接識別子 | Pseudonym(同一実体 = 同一 token) | 同左 |
| `Detail.ReportHeader` | 氏名埋め込み文 | Template `"{SubjectToken} さんが提出したレポート"` | Drop |
| 本文系(`BodyText`/`SummaryText`/`ContentBlocks[*].Text`/`Files[*].ExtractedText`) | 本文(PII 混入実例あり) | Keep + TextRules 三層 | 同左+固有名詞強度増 |
| `Files[*].Name` | ファイル名(氏名入りがあり得る) | Keep + TextRules | `attachment-<i>.<ext>` 正規化 |
| URL・参照系(`Files[*].URL/BlobRef/URI/Hash`・`DetailURL`・`RunRef/RunURI/DetailRef/DetailURI`・`CollectionURL`) | 学生固有参照・encoded 名 | Drop(往復は lineage 経由) | Drop |
| `SubmittedAt` / `GradedAt` | 準識別子(時刻リンク) | Generalize timestamp→date | Drop |
| `Top.Grade` / `Comment` | 既存評価情報 | Keep + TextRules | 同左 |
| `Course` / `AssignmentName` / `AcademicYear` / `CollectionKey` | 集団属性・課題キー | Keep | Keep |
| `ObservedAtUTC` | 運用メタ | Generalize timestamp→date | Drop |
| `Status` / `Change` / `Version` | 運用メタ(enum/integer) | KeepRaw(AllowedType 宣言) | Drop |
| `Reason` | 運用メタ(自由文の可能性) | Keep + TextRules | Drop |

### 14.2 Cerezo 公開 API と正準フロー

```wolfram
run   = "sv://snapshot/CerezoCollectionRun/411cdd…";

plan  = CerezoAnonymizationPlan[run];
  (* schema-only: 件数・提出状況レンジ・policy/profile/target/provider の選択肢 *)

grant = SourceVaultRequestDeclassification[plan];
  (* オーナー UI: ExactTargetLevel(0.45/0.2)・PublishMode・provider・ExposurePolicy・
     DistributionPlan を選択し承認 → ExecutionGrant(+定型なら PublishIfVerified) *)

anon  = CerezoAnonymizedSubmissions[run, "GrantRef" -> grant];
  (* 未提出者は ExcludedUnits(Reason->"Unsubmitted")として manifest 宣言 *)

evalPlan = CerezoEvaluationPlan[anon["ArtifactRef"],
             "PublicationDigest" -> anon["PublicationDigest"], rubric];
  (* exact artifact を pin(高 PL run から「最新 variant」を暗黙選択しない)。
     一受験者一 EvaluationUnit。プロンプトは基準+「点数:/評価理由:」固定形式+Clip、
     提出物本文は data として区切り指示追従を禁止 *)

g     = CerezoGradeSubmissions[evalPlan, "GrantRef" -> egressGrant];
  (* EvaluationEgressGrant 下で一受験者一セッション送信 → quarantine → 検証 →
     GradeAnnotation(PL 1.0)。"Async"->True で SourceVault job 二層(非ブロック) *)

full  = CerezoAttachGrades[g["GradeArtifactRef"], "Save"->True];
  (* join preview → 全件合格 → 原子 commit → 元行+LLMGrade/Reason/GradedBy/Attempt
     (SourceVaultPrivateResult[..., 1.0])。"Save" で CerezoGradeRecord(PL 1.0) *)

CerezoGradeReport[run, "Export"->"xlsx"]
  (* 成績表 = 複数 subject 集約 → PL 1.0(CompositionPolicy)。
     SourceVaultPrivateView[Dataset, 1.0](赤枠バッジ)+xlsx/csv 出力(ローカルのみ)。
     未提出者は「未提出」行(NotGradable)。再採点は adjudication で確定した Attempt を採用 *)
```

- 高 PL `run` を受ける convenience API を残す場合も、内部で exact ArtifactRef/PublicationDigest/BindingDigest を確定し、オーナー UI と EvaluationPlanManifest の双方に表示・pin する。
- 同一 grant の budget/期限内の再実行はキャッシュ(PublishedReuse)で高速。
- Cerezo 本番の feature flag は、Doctor 報告(G1c)・EvaluationUnit orchestration(G2)・Unlisted 基盤(U0–U2)が未実装なら有効化できない(§19)。

### 14.3 答案 PDF 採点(将来、C4)

スキャン PDF(受験者数×ページ数、PL 1.0)→ ページ SourceUnit 化 → 宣言 Regions(学籍番号・氏名欄)+MediaScan で黒塗り → `PageImageList` 成果物 → vision LLM 採点(EvaluationUnit=一受験者の全ページ、ResultSlot=設問別)→ quarantine → 書き戻し。ページ↔受験者の対応は IdentityEvidence+adjudication(§12.2)。既存 `recognizeAnswerSheet.wl` の資産を移植・接続。

---

## 15. 発見可能性・release gate・実行時 guard

### 15.1 Unlisted(限定配信)原則

- 匿名化成果物・AnnotationContent・quarantine は `Discoverability -> "Unlisted"`(生成時固定)。
- **列挙遮断**: `sourcevault_search`/catalog/fs_list/一覧系 API の索引・結果に決して現れない(adapter が Unlisted クラスを index 除外 — additive 改修)。低 PL 側に一覧 API を提供しない。
- **到達経路は 2 つのみ**: (a) exact ReleaseHandle の bearer get、(b) origin を読む権限を持つ principal のリンクたどり(`SourceVaultAnonymizedVariants`・ExposureLedger・監査)。YouTube の限定公開と同型 — オーナー環境(Studio 相当)だけが一覧を持つ。
- unlisted の秘匿性は **ランダム handle の非掲載性**に依存する(content hash の推測困難性に依存しない — §5.10)。
- 存在 oracle 防止: 権限のない照会に対し、variant の有無で error code・件数・timing を変えない。
- 限界の明記: unlisted はアクセス制御ではない。第一の防御は gate・grant・guard。

### 15.2 ExposureGuard

LLM egress・自動 batch・handle get・MCP get・download・export の直前に ledger rollup を評価し `Permit / PermitAndReport / RequireOwnerApproval / Deny` を返す。

- 閾値未満の単発低 PL 参照は自動 Permit(体感は従来どおり「0.5 未満の参照に許可不要」)。ただし**無記録では許可しない**(PreReleaseIntent WAL が前提、§5.14)。
- 閾値超過は object PL を変えず、**自動 workflow/egress を停止しオーナー再承認を要求**。
- ledger 不通・coverage 不明・rollup stale のとき、高集中 automation は fail-closed(local WAL が生きていれば単発参照は保守的 budget で継続可)。

### 15.3 MCP 統合

- 成果物の MCP get は ReleaseHandle 経由+head 確認+guard。低 PL projection に系譜参照・ID・元ファイル名・locator・GrantRef を含めない(ItemToken/SubjectToken のみ)。
- annotation の低 PL projection は AnnotationContent のみ(Binding は高 PL/main-kernel 限定)。
- PL 1.0 の control-plane 群(§5.15)は従来どおり gate が遮断。
- 内部の authorization envelope は artifact ref・PublicationRecord 参照を含んでよいが、**provider へ実際に送信される released payload は JobToken(/ResultSlotToken)+匿名化本文のみ**。boundary gate はこの境界で検査する。

---

## 16. 監査・診断・privacy 契約

### 16.1 privacy 契約(新規 public シンボル)

| シンボル | Class | Exit |
|---|---|---|
| SourceVaultAnonymize / SourceVaultPublishStagedArtifact | Private | Result |
| SourceVaultReidentify / SourceVaultPseudonymMap / SourceVaultAttachDerivedResults / SourceVaultValidateDerivedJoin / SourceVaultCreateDerivedAnnotations / SourceVaultValidateLineage / SourceVaultAnonymizationVerify | Private | Result |
| SourceVaultAnonymizationPlan(schema-only)/ SourceVaultRequestDeclassification / SourceVaultApproveDeclassification(オーナー対話環境限定) | Public | Result |
| SourceVaultRegisterAnonymizationPolicy / SourceVaultAnonymizationPolicy(s) / SourceVaultRegisterDeclassificationProfile / SourceVaultDeclassificationProfiles | Public(登録系は mutation authorization) | Result |
| SourceVaultAnonymizationAuditSummary(低 PL 集計)/ SourceVaultAnonymizationExposureProbe(sanitized) | Public | Result |
| SourceVaultAnonymizationAudit / SourceVaultAnonymizedVariants / SourceVaultAnonymizationExposureSensitiveDoctor | Private(owner/高 PL) | Result / View |
| SourceVaultRevokeDeclassifiedArtifact / SourceVaultRotateReleaseHandle | Public(mutation authorization 必須) | Result |
| SourceVaultSaveContentAddressedDerivedArtifact / SourceVaultPublishDeclassifiedArtifact | Internal(非 export) | Result |

コミットゲート: 実装増分ごとに `privacy_reviewed.m` を更新し、`SourceVaultPrivacyAudit["Mode"->"Source"]` Unreviewed 0 件・`"Runtime"` UndeclaredLeak 0 件。

### 16.2 System Doctor 統合

- **sanitized probe**(`SourceVaultSystemDoctor` 向け): Health/ReasonCode/件数レンジのみ。artifact/provider/owner の実値を出さない(alert 自体の漏洩防止)。
- **owner-only sensitive doctor**: provider trust domain・cohort coverage・session/batch・variant 数・該当 publication refs・推奨 remediation。
- High/Critical は `SourceVaultDiagnosticsEscalate`(cloud-safe summary のみ)。
- ReasonCode: `DeclassificationExecutionWithoutOwnerGrant`(Critical)/ `DeclassificationTargetMismatch`(Critical)/ `AnonymizedArtifactConcentratedUse`(High)/ `CohortCoverageThresholdExceeded`(High/Critical)/ `RepeatedVariantExposure`(High)/ `GradeAggregationDetected`(High)/ `ExposureLedgerUnavailable`(High)/ `CrossMachineExposureRollupStale`(Warning/High)/ `ProviderDistributionPolicyViolation`(High)。
- **検出可能性の限界**: SourceVault 外へコピーされた低 PL content・provider 側の非公開横断集約は検出・回収できない。保証範囲は sanctioned reader/MCP/LLM boundary/job orchestration を通る利用のみ。

---

## 17. 脅威と対策

| # | 脅威 | 対策(節) |
|---|---|---|
| T1 | 本文・ヘッダ・ファイル名・URL に残る識別子の複製(実例確認済み) | KnownValueScan+V1。URL/参照は Drop(§6.4, §14.1) |
| T2 | 表記ゆれ(姓のみ・全半角・空白)のすり抜け | KnownStrings 決定論展開+Patterns+PrivateModelScan(§6.4) |
| T3 | 準識別子の組合せ再識別(「情報工学科 3 年・女性」) | 構造化=Generalize+k 検査、テキスト内=Patterns 属性語彙+LLM(§6.4/6.5) |
| T4 | 提出時刻等の高分解能値によるリンク | timestamp→date 丸め / 強 tier で Drop(§14.1) |
| T5 | 同一 MapScope 内成果物の token リンク | 意図的性質(採点に必要)。scope を課題単位に限定(§5.3) |
| T6 | 提出物経由のプロンプトインジェクション | data 区切り・指示追従禁止・点数形式固定+Clip・数値+短文のみ受理(§14.2) |
| T7 | 見かけ黒塗り(テキスト層・EXIF・レイヤ残存) | ラスタ化・再エンコード必須+V5(§6.6/6.8) |
| T8 | VerifyReport/監査ログ自体からの漏洩 | 報告・イベントに PII 非含有(§9, §5.12) |
| T9 | ローカル LLM 不通時の素通し | fail-closed: NeedsReview(§9.1 V3) |
| T10 | ポリシー改竄・すり替え | 不変 snapshot+digest が cache/grant に焼き込み(§5.1) |
| T11 | 対応表の漏洩 | PL 1.0+gate+高 PL 側 API のみ。envelope に不載(§5.3) |
| T12 | 匿名化の悪用(機械的 declassify) | grant 必須+Verify 必須+全件監査+Audit 追跡(§4.0, §10) |
| T13 | 別 artifact/scope の結果誤書き戻し | artifact-bound annotation・exact pin・引数上書き禁止(§13) |
| T14 | 並替えによる index 対応ずれ | content digest+canonical locator・order-independent join(P-A13) |
| T15 | 分割時の欠落・重複 | Partition 10 不変条件+L1/L2(§5.7, §9.2) |
| T16 | OCR の別人誤認 | IdentityEvidence・roster 照合・fail-closed・adjudication(§12.2) |
| T17 | PseudonymMap 並行更新競合 | lock+CAS・uniqueness・不変 MapVersion(§5.3) |
| T18 | commit 途中障害での不整合公開 | 状態機械・audit durable→head CAS(§8.2) |
| T19 | cache 衝突で別 scope の成果物返却 | MapScopeDigest 等を cache identity に包含(§11) |
| T20 | LLM の token 欠落・重複・捏造 | out-of-band binding・multiset 完全一致(§5.11, §13) |
| T21 | 欠陥発見後も旧成果物が release | Revoke/Supersede/Expire+release 時 head 再検査(§10.4) |
| T22 | 系譜参照(OriginRef 等)による相関・存在確認 | 低 PL projection から排除・高 PL binding へ(§5.6, §15.3) |
| T23 | 再採点の無言上書き | append-only annotation・Attempt/Supersedes/adjudication(§5.9) |
| T24 | score/reason が新たな PII を運ぶ | 出力スキャン+result PL 評価(§13.3) |
| T25 | 別人の同一内容提出での unit ID 衝突 | ID 式に SourceObjectID 包含(§5.5.2) |
| T26 | 複数ページの欠落+複製のすり抜け | ItemToken multiset+(token,digest,MediaType,Role) 検査(§9.2 L2) |
| T27 | binding の差替え・欠落による誤結合 | immutable binding+digest pin+fail-closed(§5.6) |
| T28 | publish 中間状態の観測 | 公開決定点を head CAS に一元化・全経路 head 確認(§8.2) |
| T29 | ノード間の鍵・正規化版不一致 | fingerprint 検査で停止(§5.5.1) |
| T30 | audit metadata(活動・存在・担当者)の漏洩 | Summary/Audit projection 分離(§7.3, §16.2) |
| T31 | profile の直積許可の悪用(0.45×LowTrust) | AllowedReleases tuple(§5.2) |
| T32 | 無許可の匿名化候補生成(本文 read) | schema-only Plan/grant/段 0 gate(§4.0, §8.1) |
| T33 | caller による TargetLevel の勝手な選択 | ExactTargetLevel を grant に pin(§4.2) |
| T34 | profile 承認の流用による別 origin 自動 declassify | profile と grant の分離・origin/版/uses を grant に固定(§5.13) |
| T35 | 個別成績の低 PL 永続化・再公開 | quarantine+protected minimum(Grade 1.0)(§5.9, §13.3) |
| T36 | 低 PL 断片の集約による再構成 | CompositionPolicy(複数 subject 表=1.0)+判定器(§13.5) |
| T37 | 同一 provider/session への cohort 一括送信 | EvaluationUnit(一受験者一セッション)・coverage guard(§13.6, §15.2) |
| T38 | 複数 variant 横断による redaction 差分復元 | ledger の variant set 検査・variant 上限(§5.14) |
| T39 | provider 分散による露出面拡大 | owner-approved DistributionPlan・trust domain 単位評価(§13.6) |
| T40 | 露出記録不通時の batch 続行 | 高集中自動 egress は fail-closed・WAL 必須(§5.14) |
| T41 | Doctor 詳細 alert 自体の漏洩 | sanitized probe/owner-only doctor 二層(§16.2) |
| T42 | Revoked/旧 verifier 成果物の no-op 返却 | R4-6 完全一致条件(§4.2) |
| T43 | 匿名化 handle の列挙・拡散による網羅収集 | Unlisted・handle 準機密扱い・guard(§15.1) |
| T44 | 既知平文の列挙照合による content hash 導出・cross-tenant 同一性確認 | ReleaseHandle(CSPRNG・content 非依存)と内部 identity の分離・tenant namespace(§5.10, §5.6) |
| T45 | provider 生応答(成績・復唱本文)の低 PL 滞留 | 受信 byte からの quarantine(§5.9) |
| T46 | grant の型混用・crash retry での多重/不能 | typed grants+action 別 budget+GrantExecutionLease(§5.13) |
| T47 | handle の URL path 経由の観測(proxy/APM/history) | header/body 渡し・log scrub・観測系まで AC 対象(§5.10) |

---

## 18. 非目標

- 差分プライバシー(ノイズ付与型統計公開)。将来 `Tiers` に `"DP"` 型 tier を追加する余地のみ残す。
- Incognito 型の最適一般化探索・l-多様性・t-近接性(k 匿名性は一様昇格 GeneralizeUp のみ)。
- 元オブジェクト自体の PL 変更(既存の手動経路のまま)。
- 匿名化版の自動陳腐化(元の新版 ingest 時の自動再匿名化)。Supersede は手動。
- HMAC 鍵の rotation の正式仕様化(KeyId・fingerprint 検査・紛失時の新 KeyId 発行までは scope 内)。
- 統計的公開(平均・分布)の低 PL 化規則の詳細(statistical release policy は別仕様。本書は「別 grant 必須」の境界のみ定める)。
- provider の server-side 横断集約の検出・回収(§16.2 の限界)。
- FieldRule としての汎用 Hash 置換。

---

## 19. 増分実装計画

**control plane と owner gate を匿名化本体・universal dispatch より先に実装する**(強力な dispatch を先に作ると owner gate のない declassification 面が成立するため):

| 群 | Inc | 内容 | 依存 |
|---|---|---|---|
| 1. Identity/control plane | **L0a** | Canonicalization 規則+KeyRing(fingerprint 検査)+ID 式の純関数(衝突耐性テスト込み) | — |
| | **L0b** | LineageManifest graph+役割別 token+EvaluationUnit/ResultSlot schema+record 束縛(P-A19)+`SourceVaultValidateLineage` | L0a |
| 2. Authorization | **G0a** | schema-only `SourceVaultAnonymizationPlan`(本文非読の保証テスト) | — |
| | **G0b** | typed grants(Execution/Publication/Egress)+approval receipt+GrantExecutionLease+NBAccess action registry+段 0a/0b gate | G0a |
| 3. Unlisted transport | **U0** | ReleaseHandle(CSPRNG・owner mapping・revoke/rotate) | — |
| | **U1** | search/catalog/list の index 除外+存在 oracle テスト | U0 |
| | **U2** | handle の log/diagnostics/notification/provider envelope scrub(proxy/APM 統合テスト) | U0 |
| 4. Ingress protection | **G1a** | protected minimum registry+quarantine(encrypted・TTL)+schema/receipt/slot 検証+CompositionPolicy 判定器 | L0b |
| 5. Exposure | **G1b** | PreReleaseIntent WAL+typed ExposureEvent+決定論 rollup/guard(複数 PC) | — |
| | **G1c** | Doctor sanitized probe+owner sensitive doctor+escalation | G1b |
| | **G2** | EvaluationDistributionPlan+一受験者一セッション orchestration+ResultSlot binding | G0b, L0b |
| 6. Lineage/publication | **L1** | PseudonymMap(MapId/MapVersion/MapHead CAS)+SubjectToken uniqueness | L0a |
| | **L2a** | ArtifactBinding+content-addressed builder+逆引き adapter 拡張 | L0b |
| | **L2b** | PublicationRecord/Head+lifecycle-aware release gate(additive)+crash injection tests | L2a, U0 |
| | **L3a** | EvaluationPlan/Result manifest | L0b |
| | **L3b** | quarantine→AnnotationContent/Binding+exact join validator+原子的書き戻し | L2b, L3a, G1a |
| | **L4** | 入力形式 adapter(Association list/配列/ID+画像/PDF/OCR evidence) | L0b |
| 7. Anonymization | **A0** | ポリシー/profile 登録・解決(AllowedReleases tuple) | — |
| | **A1** | Pseudonymize コア+成果物保存+二層 cache identity+variants | L0–L2, A0, G0b |
| | **A2** | 決定論 Redact+Generalize+V1/V2+L1–L5 統合(LLM なし end-to-end) | A1 |
| | **A3** | PrivateModelScan シーム+V3+NeedsReview フロー | A2 |
| | **A4** | 監査イベント一式+AuditSummary/Audit 分離+Revoke/Rotate | A1, L2b |
| | **A5** | k 匿名性(V4) | A2 |
| | **A6** | Transforms+V5(独立 verifier)+page 系譜 | A1, L4 |
| | **A7** | MCP projection+gate 実機確認 | A1, L2b, U1 |
| | **A8** | MediaScan(ローカル OCR/vision+証跡+V5 連動) | A6, A3 |
| 8. Cerezo | **C1** | cerezo ポリシー/profile+`CerezoAnonymizationPlan`+`CerezoAnonymizedSubmissions` | A2(A3 推奨), G0b |
| | **C2** | `CerezoEvaluationPlan`+`CerezoGradeSubmissions`(EvaluationUnit・quarantine) | C1, L3b, G2 |
| | **C3** | `CerezoAttachGrades`+`CerezoGradeReport` | C2 |
| | **C4** | 答案 PDF 採点(OCR evidence+adjudication+MediaScan) | A6, A8, L4 |

- **universal dispatch の公開は control plane(群 1–3)と owner gate 完成後**。
- **Cerezo 本番最小構成: L0a–L3b + G0a–G2 + U0–U2 + A0–A4 + C1–C3**(G1c/G2/U 系は省略不可 — 一受験者一セッション・Doctor 報告・unlisted 基盤は本仕様の必須規則)。
- テストは ClaudeTestKit headless green を各 Inc の完了条件。L0a は ID 衝突耐性、L2b は crash injection、G0a は本文非読保証、U1 は存在 oracle、U2 は観測系 scrub を必須完了条件に含む。LLM/vision 依存段は mock シームで決定論化。

---

## 20. 受入基準

### 20.1 匿名化コア

**AC-001** PL 1.0 の Cerezo run から TargetLevel 0.45 の grant で生成した成果物の PL が 0.45 であり、元 run・元提出物 snapshot の PL が 1.0 のまま変わらない。
**AC-002** 同一 cache identity での 2 回目の呼び出しが `CacheHit->True` で同一 ArtifactRef を返し、パイプライン(LLM 段含む)を再実行しない。ヒット時に head 状態・revocation の再検証が行われる。
**AC-003** `"Force"->True` は再計算し、異なる content なら旧 publication が Superseded になる。同一 content なら `Reverified` のみで状態維持。
**AC-004** ポリシー改訂(新 digest)後の呼び出しは別 identity で新規計算され、旧成果物も `SourceVaultAnonymizedVariants` に状態付きで残る。
**AC-005** 成果物 Payload のどの文字列にも対応表の KnownStrings(実 ID・氏名・表記ゆれ)が出現しない(V1。「ExtractedText 先頭の生学籍番号」ケースを含む)。
**AC-006** `ReportHeader` が Template 規則により SubjectToken のみで再構成される。
**AC-007** URL・参照系フィールドが 0.45 tier で Drop されている。
**AC-008** 同一 MapScope での再実行時、同一学生に同一 SubjectToken が割り当てられる。別 MapScope では独立採番。
**AC-009** PseudonymMap・LineageManifest の PL が 1.0 であり、アクセスレベル 0.5 の環境(MCP cloud sink)では中身が返らない。
**AC-010** `$ClaudePrivateModel` 不通のとき、PrivateModelScan 必須ポリシーの実行が `NeedsReview`(Staged 止まり)になり Publish されない(mock で不通を再現)。
**AC-011** V1/V2 に意図的に検出させる注入データ(本文に生 ID を残す)で `Failed` になり、低 PL 成果物が公開されない。
**AC-012** 未定義 TargetLevel の tier 要求・`TargetLevel >= 元 PL` はエラー(R4-1/R4-2)。
**AC-013** 0.2 tier でファイル名正規化・SubmittedAt Drop が行われ、成果物 PL 0.2 が低信頼 provider(上限 0.25)の release 判定を通る。
**AC-014** すべての Publish・キャッシュヒット・Revoke に監査イベントが記録され、`SourceVaultAnonymizationAudit` で元 PL→先 PL・policy・grant・principal が追跡できる。イベント・VerifyReport に PII が含まれない。
**AC-015** grant なし・grant 不一致の Execute はいずれも実行前に拒否される(profile 適合だけでは何も実行されない)。
**AC-016** `CerezoGradeSubmissions` が provider へ送信する payload に JobToken(/ResultSlotToken)と匿名化本文のみが載る(boundary gate ログで確認)。
**AC-017** `CerezoAttachGrades` 後のデータで StudentID/StudentName が復元され、返り値が `SourceVaultPrivateResult[..., 1.0]` で包まれる(透かし 1.0)。
**AC-018** `CerezoGradeReport` の Dataset が `SourceVaultPrivateView`(赤枠バッジ)で表示され、xlsx が出力される。未提出者は「未提出」行になる。
**AC-019** k 匿名性 `K:2, OnFail:"Suppress"` で違反同値類の準識別子のみが抑制されレコード数は不変。`"Fail"` では全体が `Failed`。
**AC-020** ImageRedact 成果物の指定領域ピクセルが単色であり(V5)、PDFPageImages 成果物にテキスト層が存在しない。
**AC-021** 新規 public シンボルが `SourceVaultPrivacyAudit["Mode"->"Source"]` で Unreviewed 0 件・`"Runtime"` 監査で UndeclaredLeak 0 件。
**AC-022** 本書単独で(レビュー文書・過去版なしに)全受入基準が読め、試験実装に着手できる。

### 20.2 lineage / result-binding

**AC-023** 同じ原本・policy・target でも MapScope が異なる呼出しは異なる cache identity となり、要求 scope と artifact の MapScopeDigest が一致しなければ失敗する。
**AC-024** list の順序をランダムに入れ替えても、各 score/review は同じ SourceUnitID/EntityID に帰属する。list index のみを join key にした実装は失格。
**AC-025** 別 run・別 origin 版・別 artifact variant・別 MapRef の annotation を渡すと `LineageMismatch` で失敗し、書込みは 0 件。
**AC-026** expected token set に対して missing・duplicate・unknown を各 1 件注入すると全 batch が失敗し、部分成績 snapshot が作られない。
**AC-027** PL 別 partition の union が declared source unit set と一致し、重複禁止 partition の intersection が空。欠落/重複注入時は publish されない。
**AC-028** 同一 MapId への二並行プロセスの追記で、同じ EntityID は同じ token、異なる EntityID は異なる token となる。MapHead 更新競合は再試行または明示失敗し、二重割当は 0 件。
**AC-029** artifact は exact MapRef と LineageManifestRef を pin し、MapHead が進んだ後も旧 artifact の逆写像は同じ結果になる。
**AC-030** commit の各段に crash を注入し、再起動後に `Published && audit absent`・`low-PL && verify absent`・dangling published alias がいずれも 0 件。
**AC-031** PDF ページの並べ替え・空白ページ・重複ページを加えても page digest/SourceUnitID により誤帰属せず、manifest 不整合は fail-closed。
**AC-032** OCR で ID と氏名を意図的に別人へ誤認させると自動確定されず `NeedsAdjudication` になる。低 confidence・roster 不一致も同様。
**AC-033** LLM 応答本文に別 token を書かせても、out-of-band binding では別人へ付かない。batch mode では token-set 不一致で失敗する。
**AC-034** `Revoked`/`Expired` artifact は cache hit しても返却・cloud release されず、新版生成または再検証を要求する。
**AC-035** 低 PL の MCP/cloud projection に OriginRef・MapRef・LineageManifestRef・SourceUnitID・元ファイル名・page locator が含まれない。
**AC-036** grade/review 出力に KnownStrings を注入すると result verification が失敗し、入力 artifact と同じ PL を無条件継承しない。
**AC-037** 裸の Association/list を書き戻し API に渡すと provenance 不足で拒否される。明示の preview-only mode だけは保存なしで利用できる。
**AC-038** 再採点は旧 score を上書きせず、新 Attempt と `Supersedes` を持つ。最終採用 score は adjudication event から一意に求まる。
**AC-039** 同じファイル名に別内容・別ファイル名に同じ内容・同じ学生 ID に複数画像を与えたとき、filename/order でなく明示 cardinality policy と content digest に従う。
**AC-040** `SourceVaultValidateLineage` が source/derived unit 数・missing/duplicate/unknown/version mismatch・manifest digest・map version を機械可読に報告し、PII 値自体を報告に含めない。

### 20.3 ID・graph・publication・builder

**AC-041** 異なる SourceObjectID を持つ二原本に同一内容・同一 locator・同一 page index を与えても SourceUnitID が異なる。
**AC-042** 一つの SourceUnit から同一 transform で二派生片を作り、DerivedLocator/role が異なれば DerivedUnitID が異なる。
**AC-043** 複数 SourceUnit の一集約で、parent set の順序を変えても同一 DerivedUnitID、parent を 1 件変えれば異なる DerivedUnitID。
**AC-044** 一学生三ページの payload から page 2 削除+page 1 複製 — 件数と SubjectToken 集合が同じでも ItemToken multiset/content digest 検査で失敗。
**AC-045** 同一 SubjectToken の複数ページに別々の ItemToken があり、page 単位 annotation が一意の DerivedUnitID へ結合される。
**AC-046** N:1 / N:M の lineage edge を保存・再読込・digest 検証でき、入れ子複製を正本に使わない。
**AC-047** artifact 本体に可変 lifecycle 状態を持たず、PublicationHead/Record だけから状態が一意に求まる。
**AC-048** side record 書込み・Prepared event・head CAS・completion event の各直前直後に crash を注入し、direct snapshot ref を含む全 release 経路で未公開 artifact が返らない。
**AC-049** ArtifactBinding/AnnotationBinding の欠落・digest mismatch・別 artifact への差替えで release/join が fail-closed になる。
**AC-050** 低 PL の annotation projection に TargetArtifactRef・MapRef・LineageManifestRef・OriginRef・DerivedUnitID・JobBinding が含まれない。
**AC-051** legacy と新 schema を reader が version で分岐して読め、新 builder は同一 content identity に同一 ref を返す。
**AC-052** 直渡し persistent mode は AdHocOrigin snapshot を自動生成し、preview-only mode の成果物からの書き戻しは拒否される。
**AC-053** 異なる鍵 fingerprint / canonicalization version のノードからの同一 MapId 更新は停止し、黙って別 EntityID/token を発行しない。
**AC-054** MapHead に無関係 entity を追加しても TransformCacheIdentity は不変、使用 mapping の token 変更時のみ変わる。
**AC-055** profile の AllowedReleases tuple にない TargetLevel×SinkClass の grant 要求は発行時に拒否される。期限切れ・RiskAssessmentRef 不在も同様。

### 20.4 universal dispatch / 冪等

**AC-056** grant 下で「複雑な連想のリスト」「画像 1 枚」「画像集合」「マルチページ PDF」の各 sv:// 参照を渡すと、形式が自動判別され(判別結果が manifest に記録)、それぞれ Records/ImageList/PageImageList の匿名化候補が生成される。判別不能形式は `Failed`。
**AC-057** universal ポリシーの grant(StageForOwnerReview)では検証合格後も Staged であり、ArtifactPublicationGrant を経て初めて Publish される。schema-pinned+PublishIfVerified grant の同一入力は検証合格で自動 Publish される。
**AC-058** 匿名化成果物を同一ポリシー・同一 TargetLevel で再度渡すと、R4-6 の完全一致条件下で新規生成なしに同一成果物が返る。より低い TargetLevel は新 grant 下で段階的匿名化が行われ、lineage が連鎖する。
**AC-059** 宣言 Regions も MediaScan も適用できない画像/PDF 入力は `NeedsReview` になり、Publish されない。

### 20.5 owner grant・composition・exposure

**AC-060** grant なしで高 PL sv:// に `SourceVaultAnonymize` を呼ぶと、payload/blob/Map/OCR/LLM に触れる前に `NeedsOwnerApproval` を返す(生成されるのは schema-only Plan のみ)。
**AC-061** universal/schema-pinned/Cerezo のいずれの policy でも、profile 適合だけでは Execute/Publish されない。exact owner grant が必要。
**AC-062** grant の OriginDigest/SelectionDigest/PolicyDigest/TargetLevel/Purpose/Sink の各一項目の変更で実行前拒否。
**AC-063** `TargetLevel->Automatic` は grant の exact level を解決する。caller 指定が grant と不一致なら `DeclassificationTargetMismatch`。
**AC-064** 自己署名 grant・期限切れ・nonce 再利用・MaxUses 超過・acts-for 根拠不在はいずれも拒否される。
**AC-065** exact Published variant の再利用は新 grant なしで可能だが `PublishedReuse`+ExposureEvent が記録され、高 PL 本文を再読しない。
**AC-066** Revoked/Expired/旧 verifier identity の成果物は同 policy/target でも R4-6 no-op にならない。
**AC-067** 0.45→0.2 の段階的匿名化は新 owner grant なしでは開始されない。
**AC-068** cloud から返った Grade response は低 PL Published にならず、schema 検証後に組織 Grade minimum PL(Cerezo 1.0)で保存される。
**AC-069** 複数 subject の score/reason list/table は入力断片が 0.45 でも PL 1.0(単純 Max では判定しない)。
**AC-070** 統計のみの低 PL 化は別 statistical release policy+owner grant 必須。少人数集計は自動で低 PL にならない。
**AC-071** provider payload には JobToken(/ResultSlotToken)と匿名化 content のみ(ItemToken/SubjectToken/artifact URI/ReleaseHandle 不含)。
**AC-072** 既定で一 session/request に複数 subject を入れると拒否。複数ページは一 subject の EvaluationUnit にまとめられる。
**AC-073** 同一 provider trust domain への distinct subject 数・cohort coverage・variant 数が閾値超過で自動 batch 停止+owner reapproval 要求。
**AC-074** DistributionPlan の disjoint assignment に従い、未許可 provider・上限超過・同 subject 重複送信を拒否。
**AC-075** ledger 不通/rollup stale で大規模自動 egress は fail-closed(local WAL が生きていれば単発の通常参照は保守的 budget で継続可)。
**AC-076** `SourceVaultSystemDoctor` には sanitized Health/ReasonCode のみ。owner-only doctor だけが provider/cohort/publication detail を表示。
**AC-077** 集中利用・複数 variant・coverage 超過の注入で `SourceVaultDiagnosticsEscalate` に内容最小化 event(High/Critical)が送られる。
**AC-078** EvaluationPlanManifest は送信前に immutable、EvaluationResultManifest は受信後に immutable として保存され、AnnotationBinding が両 digest を pin する。
**AC-079** ArtifactBinding は artifact を一方向 pin し、PublicationRecord が artifact と binding の両方を pin する(循環 digest なし)。
**AC-080** MediaScan detector が意図的に見逃す注入画像を independent V5 verifier が検出し、同一 detector の再実行だけで Auto Publish されない。

### 20.6 unlisted・handle・quarantine・帰属一意性

**AC-081** 匿名化成果物・AnnotationContent は `sourcevault_search`/catalog/一覧系のどの結果にも現れない(released 対象であっても)。exact ReleaseHandle の get は release gate 判定内で成功する。
**AC-082** 低 PL 環境から匿名化成果物を列挙する API 経路が存在しない。`SourceVaultAnonymizedVariants` は origin を読む権限を持つ principal のみで動作する。
**AC-083** ReleaseHandle が低 PL ログ・通知・diagnostics event・provider payload に平文で現れない(ExposureLedger には keyed HMAC で記録される)。
**AC-084** 既知 plaintext と候補列挙から ArtifactDigest を計算しても ReleaseHandle を導出できない。ReleaseHandle は content identity と独立した CSPRNG 値である。
**AC-085** handle rotate/revoke 後、旧 handle の exact get は失敗する。新 handle の発行で artifact content identity は変わらない。
**AC-086** Cerezo Grade の provider 生応答は、最初の durable byte から PL 1.0 quarantine に入り、PL 0.45 の get/search/MCP 経路から取得できない。
**AC-087** `StageForOwnerReview` の成果物は、artifact/binding/verify digest を pin した ArtifactPublicationGrant なしに PublicationHead を更新できない。
**AC-088** declassification・publication・cloud egress の grant/use budget は型で分離され、同じ grant の `MaxUses:1` を三操作へ曖昧に流用できない。crash retry は exact OperationID で冪等である。
**AC-089** 一 job が複数結果を返す場合、ResultSlotToken multiset の unknown/missing/duplicate/replay のいずれでも unit 全体が fail-closed になり、配列順で ItemToken へ割り当てない。
**AC-090** Cerezo grading は exact ArtifactRef+PublicationDigest+BindingDigest を pin し、高 PL run から「最新 variant」を暗黙選択しない。
**AC-091** mutable/ad hoc origin では、grant 認証前に digest 計算のため本文を読まない。許可後の exact open で digest 不一致なら transform 前に停止する。
**AC-092** 複数 origin の ref/digest/role は同一 record に束縛され、配列順変更・欠落・重複で OriginSetDigest 検証が失敗する。
**AC-093** origin を読む権限のない caller は、`SourceVaultAnonymize[highOrigin]` から Published variant の有無・policy・target を推測できない(error code・件数・timing 不変)。owner 不要の reuse は exact ReleaseHandle のみ。
**AC-094** central ledger 不通中も release 前 local WAL が必須で、反復した「手動」exact get が無記録で guard を迂回できない。
**AC-095** send 後 crash の `Indeterminate` は exposure と数えられ、同 RequestID retry は二重計数せず、別 sink/session への再送は新 exposure になる。
**AC-096** ExposurePolicy の window・cohort denominator・trust-domain normalization・subject/variant union・threshold precedence が決定論的テストで一致する。
**AC-097** reverse proxy/APM/access log/crash dump を含む統合テストで ReleaseHandle 平文が残らない。
**AC-098** Cerezo 本番 feature flag は G1c・G2・U0–U2 が未実装なら有効化できない。

---

## 21. 参考文献

- 佐久間淳『データ解析におけるプライバシー保護』機械学習プロフェッショナルシリーズ、講談社。`sv://object/eagle-LHXH1104F7GUJ`。
  依拠概念: 対応表による仮名化/乱数による仮名化(§3, §5.3)、識別情報と準識別子・標本一意性/母集団一意性(§3, §6.5)、一般化・トップ/ボトムコーディング・抑制・マイクロアグリゲーション(§6.5)、k 匿名化と有用性・匿名性のトレードオフ(§6.5, §18)、履歴データの仮名化/匿名化の注意(§17-T4/T5)、攻撃者モデル(§17)。
- L. Sweeney, "k-Anonymity: A Model for Protecting Privacy" (2002)。
- 内部仕様: `NBAccess_claudecode_privacy_spec_v0_1.md`(§11 Declassify)、`sourcevault_universal_mcp_access_spec_v2.md`(§8, §10.7, §13.4)、`sourcevault-spec-v0.13.md`(§3)、`nbaccess_phase4_privacy_projection_policy_revised3.md`。
- 歴史参照(本書の理解には不要): `sourcevault_anonymization_spec_v0_1.md`〜`v0_4.md` および各レビュー r1–r4。
