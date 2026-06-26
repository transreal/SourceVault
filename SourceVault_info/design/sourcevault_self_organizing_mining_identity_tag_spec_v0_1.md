# SourceVault 自己組織化マイニング / 著者同定 / タグ付け仕様 v0.1

作成日: 2026-06-23  
対象: SourceVault / SourceVault_identity.wl / SourceVault_searchindex.wl / SourceVault_eagle.wl / ClaudeOrchestrator  
前提仕様: `sourcevault_llmwiki_datastore_requirements_draft.md`, `sourcevault_universal_mcp_access_spec_v1.md`  

## 0. 目的

SourceVault に取り込まれた mail / local file / web / arXiv / Eagle / Notebook / PDF / generated artifact などの object は、最初は孤立した記録として存在する。  
本仕様は、それらの object 間に、著者・送信者・作成者・タグ・主題・引用・派生関係を半自動で見つけ、候補として提示し、人間の明示判断と後日の再スコアを通じて SourceVault 内部グラフを自己組織化する仕組みを定義する。

このマイニング実装の最大目的は、object の安全性と有用性を評価し、object 間の関係記述を半自動化することである。
著者同定、タグ付け、summary、privacy / safety assessment、Prompt Injection 判定、ObjectSignals、memory metabolism は、
この安全性評価・有用性評価・関係記述を実用的に回すための部品として扱う。

中心目標は次である。

1. ファイル系 source の `Authors` 文字列と、maildb の `From` / `FromContact` / AddressBook / Identity 二層モデルを統合する。
2. web ページ著者、arXiv 著者、Eagle 管理 PDF / 書籍の書誌著者、Office / PDF / Notebook の作成者を `Identifier` として観測する。
3. `Identifier` と `Entity` のリンクは、同一人物・法人・サービスである確率を持つ `EntityLinkProposal` として保存し、確定リンクとは分離する。
4. ユーザーが正誤を UI で明示でき、その判断を今後の候補生成・再スコア・自動確定に利用する。
5. Eagle 由来タグを全 object のタグ付け一般機構に拡張し、Manual / Imported / Mining / System の由来を区別する。
6. タグを検索・マイニング・entity disambiguation の特徴量として積極的に利用する。
7. マイニング処理は ClaudeOrchestrator workflow として定義・snapshot 化・監査できるようにする。
8. identity / tag / wiki mining を、検証・誤り訂正・記憶代謝の循環に組み込み、後日の evidence により提案、確定、拒否、固定事実を再評価できるようにする。
9. 既存の privacy level 推定、summary、Eagle summary / memo、検索結果、Prompt Injection risk、workflow log 分析を、すべて `MiningObject` として統一的に扱う。
10. LLM / workflow の不確実性を `MetacognitiveAssessment` として記録し、低確信時の search / read / followLinks / ask user / defer を制御する。

参照 snapshot は仕様本文に固定せず、mining workflow の `input-manifest.json`
で外部から与える。必要なら `SourceVaultSaveImmutableSnapshot` の `Alias` を用いて、
`svref:identity-tag-corpus:v1` のような環境非依存名で参照する。

本仕様は、次の arXiv 論文で議論される LLMWiki / companion memory の設計原則を SourceVault 向けに取り込む。

- Stefan Miteski, "Memory as Metabolism: A Design for Companion Knowledge Systems", arXiv:2604.12034, <https://arxiv.org/abs/2604.12034>.
- Juan M. Huerta, "WiCER: Wiki-memory Compile, Evaluate, Refine Iterative Knowledge Compilation for LLM Wiki Systems", arXiv:2605.07068, <https://arxiv.org/abs/2605.07068>.
- Haoliang Ming, Feifei Li, Xiaoqing Wu, Wenhui Que, "Retrieval as Reasoning: Self-Evolving Agent-Native Retrieval via LLM-Wiki", arXiv:2605.25480, <https://arxiv.org/abs/2605.25480>.
- Gal Yona, Mor Geva, Yossi Matias, "Hallucinations Undermine Trust; Metacognition is a Way Forward", arXiv:2605.01428v1, <https://arxiv.org/abs/2605.01428v1>.

ここから採用する中核は、単発の RAG / mining ではなく、`TRIAGE` / `CONTEXTUALIZE` / `DECAY` / `CONSOLIDATE` / `AUDIT`、diagnostic probe、pinned fact、ErrorBook、search-read-follow-sufficiency 型 retrieval を組み合わせた、自己修復する知識基盤である。

### 0.1 MiningObject の定義

SourceVault における mining とは、SourceVault object、object 集合、検索結果、workflow run、
または実行ログから、補助情報・評価・関係・要約・安全性・可視化構造を生成する処理である。

`MiningObject` はその結果であり、次を含む。

- 単一メール / PDF / web / image / notebook の summary、privacy estimate、category、deadline、language profile
- Eagle summary と、それに対するユーザー memo / annotation
- tag proposal、authorship assertion、entity link proposal
- 検索結果集合と、それに対するユーザーまたは workflow annotation
- 複数論文・複数メール・添付ファイル群から得た relation / survey insight
- Prompt Injection / tool misuse / data exfiltration / cross-object contamination risk
- faithful uncertainty / metacognitive assessment / search-control decision
- ClaudeEval、MCP tool call、ClaudeOrchestrator workflow log の meta-mining result
- mining graph、risk propagation graph、workflow run graph 等の visualization artifact

すべての `MiningObject` は `Confidence`、必要なら `ScoreVector` / `RiskVector`、
`TargetRefs`、`InputRefs`、`GeneratedByRunID`、`ReviewState` を持つ。
object 内に denormalize されている既存 `Derived` 値は、互換 projection として扱う。

## 1. 既存実装との接続

### 1.1 現状

`SourceVault_identity.wl` は次の二層モデルを持つ。

- 第1層 `Identifier`: raw な email / URI / SNS 等。`SourceVaultObserveIdentifier` で冪等登録され、`EntityRef` は任意リンクである。
- 第2層 `Entity`: Person / Organization / Bot / Service などの実体。複数 `Identifier` を束ね、後でマージできる。

mail では `From` header を `Identifier` として観測し、AddressBook / ContactAccessProfile により送信者・アクセス方針を構造化している。  
一方で file / web / arXiv / Eagle / PDF 系は、現状では `SourceVaultSourceRow` / `SourceVaultEagleSummaryRow` の `Authors` 文字列に denormalize され、専用の author master は持たない。

`SourceVault_searchindex.wl` と `SourceVault_mcp.wl` はすでに `Tags` / `TopicTags` / `AccessTags` を release gate、TPOProfile、PurposeIndex、Eagle adapter で利用している。ただし、タグの由来・信頼度・人間承認状態は一般化されていない。

### 1.2 追加方針

既存の `Identifier.EntityRef` は、確定済みリンクのまま維持する。  
候補リンク、確率、根拠、否定判断、再スコア履歴は `Identifier` や `Entity` に直接押し込まず、正準表 `EntityLinkProposals` とイベントで管理する。

`Entity` には UI・検索用の軽い summary field だけを追加する。

```wolfram
<|
  "SuggestedIdentifierRefs" -> {"idf-...", ...},
  "RejectedIdentifierRefs" -> {"idf-...", ...},
  "EvidenceSummary" -> <|"Positive" -> n, "Negative" -> m, "LastScoredAtUTC" -> "... "|>,
  "AutoLinkPolicy" -> <|"Enabled" -> False, "Threshold" -> 0.98, "RequireHumanForAccessChange" -> True|>
|>
```

この summary は snapshot / projection で再生成可能であり、真の履歴は event log と proposal table に置く。

## 2. Identity / Authorship データモデル

### 2.1 Identifier 拡張

`Identifier.Kind` は既存の `"Email"` / `"URI"` に加え、次を許可する。

| Kind | 用途 | 正規化 |
|---|---|---|
| Email | mail From / To / Cc | lowercase trim |
| PersonName | PDF / web / arXiv / document metadata の著者名 | script-aware normalization |
| OrganizationName | 所属・法人名 | casefold + 記号正規化 |
| ORCID | ORCID iD | hyphen normalized |
| arXivAuthor | arXiv API / author page 由来名 | arXiv name normalization |
| DOIName | Crossref 等の contributor 名 | DOI source + name |
| WebAuthorProfile | rel=author / schema.org / profile URL | canonical URL |
| DocumentCreator | PDF / Office / Notebook creator metadata | application specific normalized string |
| LLMOrAgent | LLM / ClaudeOrchestrator / MCP client 等 | provider + model / agent id |

日本語氏名は、既存 AddressBook の `Names.Kanji` / `Names.Kana` /
`Names.Romaji` に合わせ、`PersonName` Identifier に `Script` と
`NameParts` を持たせる。

```wolfram
<|
  "Kind" -> "PersonName",
  "Value" -> "imai takashi",
  "Script" -> "Romaji" | "Kanji" | "Kana" | "Mixed" | "Unknown",
  "NameParts" -> <|"Family" -> "...", "Given" -> "...", "Order" -> "FamilyGiven" | "GivenFamily" | "Unknown"|>
|>
```

初期実装では、日本語名の auto-candidate は完全一致または AddressBook 既知別名一致に限定する。
漢字 / かな / ローマ字間の対応は誤同定リスクが高いため、auto confirm 不可とし human review 必須にする。
異 script 間 match は scorer で強い負バイアスを持たせる。

`SourceVaultObserveIdentifier` は後方互換のまま使えるが、v0.1 では option を増やす。

```wolfram
SourceVaultObserveIdentifier[
  kind_String,
  rawValue_String,
  "ObservedName" -> _String | Missing[],
  "ObservedRole" -> "Author" | "Sender" | "Creator" | "Editor" | "Publisher" | "Mentioned",
  "ObservedIn" -> "sv://...",
  "ObservationSource" -> "MailHeader" | "WebMetadata" | "ArxivAPI" | "EagleBibMeta" | "PDFXMP" | "OfficeCoreProps" | "NotebookMetadata" | "LLMExtraction",
  "Confidence" -> _Real,
  "Persist" -> False
]
```

Identifier record には、従来の `Provenance` 文字列 list に加えて、構造化された `Observations` を持てる。

```wolfram
<|
  "IdentifierId" -> "idf-personname-...",
  "Kind" -> "PersonName",
  "Value" -> "yoshua bengio",
  "ObservedNames" -> {"Yoshua Bengio"},
  "Observations" -> {
    <|
      "ObjectURI" -> "sv://object/...",
      "Role" -> "Author",
      "Source" -> "ArxivAPI",
      "ObservedName" -> "Yoshua Bengio",
      "ObservedAtUTC" -> "...",
      "Confidence" -> 0.95,
      "ExtractorVersion" -> "AuthorExtractor-v1"
    |>
  },
  "EntityRef" -> Missing["Unlinked"]
|>
```

### 2.2 AuthorshipAssertions

object と Identifier / Entity の間の「著者・作成者・送信者」関係は `AuthorshipAssertions` として正準化する。

| Field | Type | Description |
|---|---|---|
| AuthorshipID | String | assertion id |
| ObjectURI | String | 対象 object |
| ObjectClass | String | mail / web / arxiv / eagle / pdf / notebook / artifact |
| Role | String | Author / Sender / Creator / Editor / Publisher / Contributor |
| IdentifierRef | String / Missing | 観測された raw identifier |
| EntityRef | String / Missing | 確定済み entity がある場合 |
| DisplayName | String | UI 表示名 |
| SourceField | String | Authors / From / Creator / XMP:Author / schema.org:author 等 |
| ExtractionSource | String | parser / API / LLM |
| Confidence | Real | assertion の抽出信頼度 |
| EvidenceRefs | List[String] | chunk / snapshot / metadata URI |
| AccessLevel | Real | object 由来 |
| CreatedAtUTC | String | 追加時刻 |
| Status | String | active / superseded / rejected |

`AuthorshipAssertion.EntityRef` は、`Identifier.EntityRef` が確定している場合だけ補完する。候補段階では入れない。

### 2.3 EntityLinkProposals

`Identifier` と `Entity` の候補リンクを保存する。

| Field | Type | Description |
|---|---|---|
| ProposalID | String | proposal id |
| CandidateIdentifierRef | String | idf-... |
| CandidateEntityRef | String | ent-... |
| CandidateKind | String | SamePerson / SameOrganization / SameAgent / MergeEntity |
| Score | Real | 0..1 の同一性確率 |
| ScoreVersion | String | scorer version |
| FeatureVector | Association | name/email/domain/coauthor/tag 等の特徴量 |
| PositiveEvidenceRefs | List[String] | 根拠 |
| NegativeEvidenceRefs | List[String] | 反証 |
| ProposedByRunID | String | mining run |
| ProposedAtUTC | String | 提案時刻 |
| LastScoredAtUTC | String | 最終スコア時刻 |
| Status | String | pending / accepted / rejected / autoConfirmed / superseded / stale |
| Decision | Association | reviewer / reason / timestamp |
| AutoConfirmEligible | Boolean | 自動確定候補か |
| RequiresHumanReason | String / Missing | 自動不可理由 |
| PinnedByProbeRefs | List[String] | この候補を保持すべき diagnostic probe / pinned fact |
| ErrorBookRefs | List[String] | 誤提案・競合・未解決問題の ErrorBook entry |
| MinorityBranchRef | String / Missing | 少数仮説として保持する branch |
| AuditState | String | none / suspended / challenged / reaffirmed |

明示拒否された proposal は、同じ `(IdentifierRef, EntityRef)` に対する将来 proposal の強い negative evidence とする。  
拒否は `Identifier` 自体を削除しないし、別 entity への候補生成も禁止しない。

### 2.4 EntityMergeProposals

複数 `Entity` が同一実体である可能性も同じ機構で扱う。

```wolfram
<|
  "ProposalID" -> "mergeprop:...",
  "CandidateKind" -> "MergeEntity",
  "FromEntityRef" -> "ent-12",
  "ToEntityRef" -> "ent-57",
  "Score" -> 0.91,
  "MergePlan" -> <|"Keep" -> "ent-57", "MoveIdentifiers" -> {...}, "Conflicts" -> {...}|>,
  "Status" -> "pending"
|>
```

merge は破壊的に見えるが、実装上は `EntityMerged` event により alias / supersede 関係を作る。旧 entity を物理削除しない。

## 3. タグ付け一般仕様

### 3.1 TagAssertion

全 object のタグは、単なる string list ではなく `TagAssertion` として保存する。

| Field | Type | Description |
|---|---|---|
| TagAssertionID | String | assertion id |
| TargetURI | String | object / chunk / entity / claim / page |
| Tag | String | tag 本体 |
| TagNamespace | String | User / Eagle / Topic / Access / Entity / Workflow / System |
| TagClass | String | UserTag / TopicTag / AccessTag / DenyTag / WorkflowTag / Facet |
| SourceKind | String | Manual / Imported / Mining / System |
| SourceRef | String / Missing | Eagle item, workflow run, UI session 等 |
| Confidence | Real | Manual は原則 1.0 |
| Status | String | active / rejected / superseded / expired |
| ReviewState | String | HumanReviewed / NeedsHumanReview / AutoAccepted |
| CreatedBy | String | user / workflow / adapter |
| CreatedAtUTC | String | 追加時刻 |
| EvidenceRefs | List[String] | 根拠 |
| AccessImpact | String | None / TightenOnly / MayLoosen / Deny |
| ExpiresAtUTC | String / Missing | 一時タグ |
| PinnedByProbeRefs | List[String] | 検証上維持すべき tag の根拠 |
| ErrorBookRefs | List[String] | 誤タグ・過剰一般化等の記録 |
| AuditState | String | none / suspended / challenged / reaffirmed |

`Tags` / `TopicTags` / `AccessTags` は、この `TagAssertion` から作る projection とする。

### 3.2 タグ由来の意味

| SourceKind | 意味 | 既定 ReviewState | 検索での重み |
|---|---|---|---|
| Manual | ユーザーが明示付与 | HumanReviewed | 強 |
| Imported | Eagle 等の既存管理系から取り込み | HumanReviewed または ImportedTrusted | 中〜強 |
| Mining | LLM / parser / classifier が推定 | NeedsHumanReview または AutoAccepted | 弱〜中 |
| System | SourceVault が状態管理用に付与 | HumanReviewed 相当 | 用途別 |

Eagle の既存 `tags` は `SourceKind -> "Imported"`, `TagNamespace -> "Eagle"` として取り込む。  
Eagle から SourceVault へ取り込んだタグは、Eagle が user-managed な正本であることを `SourceRef` に残す。SourceVault 側で編集したタグを Eagle に戻すかは別 workflow とし、v0.1 では逆同期しない。
同一 Eagle item を再取り込みした場合、前回 import には存在したが今回 import から消えた
`Imported` tag は `TagAssertionSuperseded` または `Status -> "superseded"` として projection から外す。

### 3.3 AccessTag と TopicTag の分離

タグは検索精度向上に積極利用するが、アクセス制御と話題分類は混同しない。

- `TopicTag`: mining / retrieval / clustering / TPO 用。誤付与しても情報公開を緩めない。
- `AccessTag`: release / sharing / recipient profile 用。自動付与は `TightenOnly` を既定とし、アクセスを緩める効果を持つタグは人間承認必須。
- `DenyTag`: NoExternal / Personal 等。mining が付けても安全側に働くため autoAccepted を許可できる。
- `UserTag`: ユーザー整理用。検索 ranking には強く効かせるが、権限根拠にはしない。

### 3.4 タグ projection

```wolfram
SourceVaultObjectTags[targetURI_, opts___] -> <|
  "Tags" -> {...},
  "TopicTags" -> {...},
  "AccessTags" -> {...},
  "DenyTags" -> {...},
  "Assertions" -> {...}
|>
```

projection 生成規則:

1. `Status -> "active"` のみ採用。
2. `Manual` が同一 tag の `Mining` reject を上書きする。
3. 明示 `rejected` は、同じ SourceKind / Tag / TargetURI の再提案を抑制する。
4. `AccessTag` / `DenyTag` は `ReviewState` と `AccessImpact` を評価する。
5. query / mining 用には `Confidence` を ranking feature として保持する。
6. `TargetURI` が tombstone / superseded / retracted された object を指す assertion は、正準 record を削除せず projection から除外する。

## 4. MiningObject / Annotation / Safety

### 4.1 MiningObject

`MiningObject` は mining workflow の標準出力である。identity / tag 専用 table は、
頻用 query と UI のための specialized projection として維持するが、上位では
`MiningObject` として扱える必要がある。

| Field | Type | Description |
|---|---|---|
| MiningObjectID | String | mining object id |
| MiningObjectType | String | Summary / PrivacyAssessment / SecurityAssessment / MetacognitiveAssessment / SearchResultSet / SurveyInsight / WorkflowObservation / Visualization 等 |
| Scope | String | SingleObject / MultiObject / QueryResult / WorkflowRun / Meta |
| TargetRefs | List[String] | 対象 object / entity / run / search result |
| InputRefs | List[String] | source / snapshot / prior mining object / log |
| Result | Association | 結果本体 |
| Confidence | Real / Missing | 0..1 |
| ScoreVector | Association | relevance / novelty / privacy / safety 等 |
| RiskVector | Association | promptInjection / crossObjectContamination 等 |
| GeneratedByRunID | String / Missing | workflow run |
| ReviewState | String | HumanReviewed / NeedsHumanReview / AutoAccepted / System |
| Status | String | active / pending / rejected / superseded / stale |

正準所在は次で固定する。

| Type | Canonical store |
|---|---|
| Summary / PrivacyAssessment / SearchResultSet / SurveyInsight / WorkflowObservation / Visualization | `MiningObject` |
| SecurityAssessment / MetacognitiveAssessment | `MiningObject` + 専用 projection（`SecurityAssessment` / `MetacognitiveAssessment`）。正準は `MiningObject`、projection は surface 用 |
| Authorship / TagProposal / EntityLinkProposal | `AuthorshipAssertions` / `TagAssertions` / `EntityLinkProposals` |
| Human / workflow annotation | `MiningAnnotation` |

identity / tag 系では specialized table が正準であり、`MiningObject` は workflow 横断 view として扱う。
security / meta / visualization 系では `MiningObject` が正準である。

### 4.2 MiningAnnotation

`MiningAnnotation` は mining object に対する annotation である。
Eagle summary へのユーザーメモ、検索結果集合へのメモ、prompt injection 判定の訂正、
自動 annotation、review decision を同じ形式で扱う。

annotation は mining object を直接書き換えない。`MiningObjectAnnotated` event として追加し、
projection で現在の表示・採否・補足説明を構成する。

### 4.3 Prompt Injection / SecurityAssessment

Prompt Injection 判定は、すべての SourceVault object に対する基本 safety mining である。
判定結果は `MiningObjectType -> "SecurityAssessment"` とし、少なくとも次の score を持つ。
正準値は mining object に置き、object projection では `SafetyScore` /
`PromptInjectionRisk` / `SecurityAssessmentRef` / `SafetyState` / `TextTrustState` /
`SafetyUpdatedAtUTC` として表示・検索に使う。

```wolfram
<|
  "PromptInjection" -> 0.0,
  "ToolMisuseInstruction" -> 0.0,
  "CredentialExfiltration" -> 0.0,
  "CrossObjectContamination" -> 0.0,
  "AttachmentPropagatedRisk" -> 0.0
|>
```

`SafetyScore` は初期実装では `Max[Values[RiskVector]]` とする。
`SafetyState` は `active` / `warning` / `quarantined` / `cleared`、
`TextTrustState` は `trusted` / `untrusted` / `forcedUntrusted` / `sanitized` を取る。

| Condition | Action |
|---|---|
| `Max[RiskVector] < 0.35` | `active` |
| `0.35 <= Max[RiskVector] < 0.65` | `warning`。後段 LLM は isolated / tool-less |
| `Max[RiskVector] >= 0.65` | `quarantined`。後段 LLM mining / compile / reasoning retrieval から除外 |
| `CredentialExfiltration >= 0.50` | `quarantined` |
| `CrossObjectContamination >= 0.50` | multi-object risk を生成し関係 object を再評価 |

単一 object の risk は `Scope -> "SingleObject"`、複数 object にまたがる stealth interference は
`Scope -> "MultiObject"` とする。添付ファイル・引用・同一 session・同一 workflow context は
risk propagation edge を持つ。添付ファイルの risk が上がった場合は親メールの safety score も再評価する。

最重要不変条件:

1. Prompt Injection 判定 LLM 自身は untrusted text に注入されうるため、LLM 判定は単独の信頼根拠にしない。
2. `SecurityPreScan` は LLM を使わない Wolfram Language / Mathematica 式による deterministic first-pass とする。
3. pre-scan が検出した risk は、LLM judge の出力で下げられない。下げるには human review が必要。
4. mail / PDF / image OCR / web / Office / Notebook text は、summary や author extraction に渡す前に pre-scan する。
5. external-origin text は、`SafetyState -> "active"` でも、すべての LLM stage で data boundary 化する。
6. external-origin text の内部に書かれた命令は、author extraction / tag mining / summary / survey / contamination 判定の instruction として扱わない。
7. `quarantined` object は通常の LLM mining、wiki compile / consolidate、reasoning retrieval、agent tool-use context に投入しない。

`SecurityPreScan` は、ClaudeEval が式の head で実行停止するのと同じ発想で、text 自体を構文的に検査する。
検査例は、既知 injection phrase、不可視 Unicode、bidi override、HTML comment / 白文字、base64 / JS / shell 断片、
credential らしき文字列、MCP / tool use を操作する命令、OCR 由来の隠し指示である。
rule pack は多言語を前提とし、language detection、Unicode script、domain/user dictionary、
新しい injection pattern を versioned rule pack として追加できるようにする。

LLM judge を使う場合は、対象 text を明示的な data boundary で囲み、tool / MCP / file / network access を渡さず、
JSON schema / WL Association schema のみを受け取る。LLM judge は local model を既定にする。

multi-object / cross-object contamination 判定では、複数 raw text を同じ prompt に同梱しない。
各 object の個別 `SecurityPreScan` summary、すなわち `RiskVector`、`TextTrustState`、
`MatchedRules`、metadata、session / attachment relation のみを LLM judge に渡す。
生 text を同梱する分析は、対象 object が human review により `SafetyState -> "cleared"` になっている場合に限る。

`TextTrustState -> "sanitized"` は、検出 span を data-escape / redaction した派生 text を指す。
正準 text は元 text のままとし、sanitized text は `OffsetMapRef` と `SanitizationRuleRefs` を持つ再生成可能 artifact とする。

`SecurityPreScan` は text layer の prompt injection / data exfiltration / tool misuse 指示を対象とする。
binary malware、Office macro、PDF JavaScript などの静的 malware 解析は初期 scope 外であり、
SourceVault は添付を実行せず text 抽出のみ行う。`Malware` / `SupplyChain` は将来拡張点として残す。

研究用途の false positive には `ResearchCorpus` / `SecurityResearch` tag を使い、risk 値を維持したまま
`warning` に留める policy を許可する。ただし access 緩和には使わない。

### 4.4 MetacognitiveAssessment / faithful uncertainty

SourceVault では hallucination を単なる誤りではなく、十分な不確実性表明を伴わない confident error として扱う。
LLM / workflow は、回答・claim・検索結果・proposal を出すとき、必要に応じて
`MetacognitiveAssessment` を生成し、自分の不確実性を検索・検証・保留・仮説提示の制御に使う。

| Field | Type | Description |
|---|---|---|
| AssessmentID | String | assessment id |
| MiningObjectID | String | 正準 `MiningObject` への参照。初期実装では `AssessmentID == MiningObjectID` としてよい |
| TargetRef | String | answer / claim / mining object / query result / workflow stage |
| IntrinsicUncertainty | Real / Missing | 0..1。self-consistency / sampling / model signal 等からの不確実性 |
| IntrinsicConfidence | Real / Missing | `1 - IntrinsicUncertainty`。導出値として保存してよい |
| ExpressedUncertainty | Real / Missing | 0..1。出力文の hedging / confidence 表明 |
| FaithfulnessGap | Real / Missing | `IntrinsicUncertainty - ExpressedUncertainty`。符号付き |
| ConfidentErrorRisk | Real / Missing | `Max[0, FaithfulnessGap]`。不確実なのに断定した risk |
| OverHedgeRisk | Real / Missing | `Max[0, -FaithfulnessGap]`。過剰に曖昧化した utility loss risk |
| EvidenceSufficiency | Real / Missing | 0..1。根拠が十分か |
| UncertaintyKind | List[String] | Aleatoric / Epistemic / Normative |
| RecommendedAction | String | Answer / Hedge / Search / ReadMore / AskUser / Defer / CreateProbe / AddErrorBook |
| SearchTriggered | Boolean | 不確実性により retrieval を起動したか |
| ConflictWithRetrievedEvidence | Boolean | retrieval evidence と内部推定が衝突したか |
| ProbeRefs | List[String] | 生成・参照した diagnostic probe |
| ErrorBookRefs | List[String] | retrieval insufficiency / confident error の記録 |

本表は workflow 用の要約であり、完全なフィールド（`AssessmentScope` / `LinguisticMarker` / `RunID` /
`CreatedAtUTC` / `AccessLevel` 等）と正準定義は
`sourcevault_llmwiki_datastore_requirements_draft.md` §8.8.5 を正とする。

不変条件:

1. `IntrinsicConfidence` または採用作業 score（= 下層 `MiningObject.Confidence` / proposal の Score）が高くても `EvidenceSufficiency` が低ければ自動確定しない。
2. `IntrinsicUncertainty` が高いのに断定的な出力をした場合、`ConfidentErrorRisk` を error signal とする。
3. uncertainty が高い場合は search / read / followLinks / ask user / defer を優先し、必要なら hypothesis として保存する。
4. retrieval evidence と model prior が衝突した場合、retrieval を盲信せず `ConflictWithRetrievedEvidence -> True` として probe / ErrorBook へ戻す。
5. 複数 claim を含む summary / answer では、可能な限り claim 単位の `TargetRef` に分解して assessment を付ける。
6. `MetacognitiveAssessment` projection は `MiningObjectID` で正準 `MiningObject` に接続する。projection は再生成可能 surface であり、正準事実を二重保持しない。

#### 4.4.1 arXiv:2605.01428 との関連とレビュー反映

§4.4 の `MetacognitiveAssessment` は Yona, Geva, Matias,
"Hallucinations Undermine Trust; Metacognition is a Way Forward",
arXiv:2605.01428v1（§0 参照）に依拠する。
忠実に取り込めた点・レビュー反映項目の正準記述は
`sourcevault_llmwiki_datastore_requirements_draft.md` §8.8.5.1 を正とし、
本節は本仕様の workflow（§7, §10.4.3）に直接かかわる点のみ要約する。

論文の核は、hallucination を confident error（適切な qualification を伴わない誤り）と捉え、
faithful uncertainty を「expressed uncertainty を **モデルの内部状態（intrinsic uncertainty）に**
整合させること（外部の正しさではない）」と定義し、agentic system ではこの metacognition が
「いつ検索し何を信頼するか」の control layer になる、という点である。

忠実に取り込めている点:

- confident error の定義（§4.4 冒頭）。
- reasoning retrieval を control layer とする設計（§10.4.3 `assessUncertainty`）。
- 衝突時に retrieval を盲信しない "what to trust"（§4.4 不変条件4 / §10.6）。

レビューで確認し反映した仕様修正:

- **P-1** faithful uncertainty は内部状態との一致であり外部証拠の十分性ではない。
  `assessUncertainty`（§10.4.3）は `IntrinsicUncertainty` を self-consistency から、
  `EvidenceSufficiency` とは独立に算出する。§4.4 不変条件1 は agentic 規制であって
  faithfulness そのものではない、と区別する。
- **P-3** §4.4 の `UncertaintyKind` を論文の源泉分類 `{Aleatoric, Epistemic, Normative}` に揃え、
  `SourceConflict` / `RetrievalInsufficient` は `ConflictWithRetrievedEvidence` / `EvidenceSufficiency`
  で表す。§5.2 `FeatureVector` と Appendix A.1 の配送異常例も conflict フラグ側へ移した。
- **P-5** §4.4 の `FaithfulnessGap` を符号付き `IntrinsicUncertainty - ExpressedUncertainty` にし、
  不変条件2 を `ConfidentErrorRisk = Max[0, IntrinsicUncertainty - ExpressedUncertainty]` に限定する
  （over-hedge を confident error と誤判定しない）。
- **P-4** §4.4 表に `Confidence` 列が無いのに不変条件1 が confidence を参照する不整合を、
  `IntrinsicConfidence` / `ExpressedUncertainty` 語彙へ統一して解消する。
- **P-2** MA 自体の faithfulness / discrimination を測る指標（cMFG 近似 / AUROC）を
  §10.2.9 `MemoryVitalityScores` に追加する。ground truth は owner 訂正・`ProbeRun`・`ErrorBook` から供給する。
- **A-5** `RecommendedAction -> "verifySender" / "inspectHeaders"` は MA の enum 外
  （`MailDeliveryObservations` 側の値）。Appendix A.1 では、MA 側を `AskUser` / `Search`、
  delivery observation 側を verifySender / inspectHeaders に分離した。

`IntrinsicUncertainty` は backend 依存で取得不能時は `Missing` とし、その場合 `EvidenceSufficiency` を
主ゲートに degrade する。self-consistency のコストは §7.2 の `MaxIterations` / `TokenBudget` に従う。

### 4.5 Meta-mining

Meta-mining は mining process 自体の mining である。
ClaudeEval 呼び出し、LLM / MCP tool call、ClaudeOrchestrator workflow log、
retrieval path、latency、failure、ErrorBook 更新、security assessment 更新履歴を入力にする。

meta-mining の目的:

- 特定日時・領域における safety score 低下の検出
- 特定 workflow / prompt / model version の異常検知
- retrieval sufficiency failure の集中検出
- Prompt Injection risk の連鎖や、添付ファイル由来 risk の伝播検出
- mining workflow 自体の drift / degradation の可視化

meta-mining は自己言及的に増殖しうるため、`MaxMetaDepth -> 1` を既定上限とし、
`MaxIterations` / `TokenBudget` / `WallClockBudgetSeconds` / `NoProgressTermination` を必須にする。
meta-mining run 自体の mining は自動実行せず、必要時のみ human review 後に明示実行する。

### 4.6 可視化 artifact

MiningObject は Graph / Dataset / Timeline / Geo / Matrix などの可視化 artifact を生成できる。
Mathematica / Wolfram Language の graph visualization を活用し、workflow から呼べる標準関数群を用意する。

```wolfram
SourceVaultBuildMiningGraph[vault_, scope_, opts___]
SourceVaultVisualizeMiningGraph[graph_, opts___]
SourceVaultRiskPropagationGraph[vault_, opts___]
SourceVaultWorkflowRunGraph[runID_, opts___]
SourceVaultMiningDashboard[vault_, opts___]
```

可視化 artifact は正準事実ではなく mining object の派生表示であり、input snapshot、
graph spec、layout option、renderer version を保存して再生成可能にする。

## 5. Scoring / Re-scoring

### 5.1 Candidate generation

候補生成は blocking で候補を絞る。

- normalized name exact / near match
- email local-part / domain
- ORCID / DOI / arXiv metadata
- coauthor overlap
- affiliation / organization overlap
- object tags / topic tags overlap
- same web domain / GitHub org / publisher
- temporal proximity
- citation / reference graph proximity
- mail thread / meeting / attachment relation
- mail delivery baseline / Received chain / DKIM-SPF-DMARC alignment / relay country-ASN anomaly

### 5.2 FeatureVector

`EntityLinkProposal.FeatureVector` は説明可能な Association とする。

```wolfram
<|
  "NameSimilarity" -> 0.94,
  "ExactEmailMatch" -> False,
  "EmailDomainMatch" -> True,
  "ORCIDMatch" -> Missing["NoORCID"],
  "CoauthorOverlap" -> 3,
  "AffiliationSimilarity" -> 0.8,
  "TopicTagJaccard" -> 0.42,
  "EagleTagOverlap" -> {"deep-learning", "paper"},
  "TemporalDistanceDays" -> 120,
  "PriorUserRejected" -> False,
  "SenderAuthentication" -> "DMARCPass",
  "MetadataTrustClass" -> "AuthenticatedHeader",
  "MailDeliveryAnomalyScore" -> 0.12,
  "UnexpectedRelayCountry" -> False,
  "UnexpectedRelayASN" -> False,
  "BenignExceptionHypotheses" -> {},
  "EvidenceCount" -> 8
|>
```

mail delivery feature は sender identity を直接確定する根拠ではなく、信頼度と追加検証の要否を調整する evidence とする。
たとえば同じ学科メンバーの mail が一通だけ未知 ASN / 海外 IP を経由した場合、
`MailDeliveryAnomalyScore` を上げ、`MetacognitiveAssessment.UncertaintyKind -> {"Epistemic"}`、
`ConflictWithRetrievedEvidence -> True`、`EvidenceSufficiency` 低下として扱う。
ただし、海外出張、VPN、転送、mailing list relay などの
benign exception も候補として保持し、即座に spoofing と断定しない。

### 5.3 Score policy

推奨初期値:

| Score | 動作 |
|---|---|
| >= 0.98 | auto confirm 候補。ただし初期導入では auto confirm は off |
| 0.85 - 0.98 | UI の高優先 pending |
| 0.60 - 0.85 | UI の通常 pending |
| < 0.60 | 原則保存しないか low-priority mining result に留める |

初期導入では `AutoLinkPolicy.Enabled -> False` を既定とし、
human-in-the-loop only で誤り率を実測する。その後、自動確定は次を満たす場合だけ許可する。

1. `AutoLinkPolicy.Enabled -> True`
2. score が threshold 以上
3. 明示 reject 履歴がない
4. 異なる entity への競合候補が低い
5. link により `ContactAccessProfile` や AccessTag が緩まない
6. extractor / scorer version が allowlist に入っている
7. 日本語名の異 script match など、human review 固定の条件に該当しない

### 5.4 Re-score

新しい object / tag / identifier / decision / merge が追加されたとき、既存 proposal は再スコア対象になる。
ただし全 proposal を走査しない。normalized name、email domain、ORCID、
coauthor、affiliation、tag overlap などの blocking key から affected set を作り、
変更に触れる proposal だけを再スコアする。
LLM adjudication は feature 変化が閾値を超えた候補に限定する。

```wolfram
SourceVaultRecomputeEntityLinkProposals[
  "Scope" -> <|"Identifiers" -> {...}, "Entities" -> {...}, "ChangeKind" -> "NewCoauthorEvidence"|>,
  "UseLLM" -> "WhenFeatureDeltaExceedsThreshold"
]
```

再スコア event:

```wolfram
<|
  "EventClass" -> "EntityLinkProposalRescored",
  "ProposalID" -> "...",
  "OldScore" -> 0.76,
  "NewScore" -> 0.91,
  "ScoreVersion" -> "EntityScorer-v2",
  "Reason" -> "NewCoauthorEvidence",
  "EvidenceRefsAdded" -> {...}
|>
```

`Status -> "accepted"` / `"rejected"` の人間判断は再スコアで勝手に覆さない。  
ただし、新 evidence により `NeedsReviewAgain` を立てることはできる。

## 6. Event / Segment / Snapshot

### 6.1 新規 segments

`sourcevault_llmwiki_datastore_requirements_draft.md` の `segments/` に次を追加する。

```text
segments/
  identifiers/
  entities/
  authorship_assertions/
  entity_link_proposals/
  entity_merge_proposals/
  tag_assertions/
  object_relations/
  object_interactions/
  object_signals/
  metacognitive_assessments/
  mining_objects/
  mining_annotations/
  security_assessments/
  security_prescans/
  security_prescan_rulepacks/
  safety_quarantines/
  sanitized_texts/
  workflow_observations/
  visualization_artifacts/
  mining_runs/
  mining_decisions/
  diagnostic_probes/
  probe_runs/
  pinned_facts/
  compilation_constraints/
  errorbook_entries/
  wiki_compile_runs/
  memory_branches/
  audit_records/
  memory_vitality_scores/
```

### 6.2 新規 event class

| EventClass | Description |
|---|---|
| IdentifierObserved | Identifier / Observation 追加 |
| AuthorshipObserved | object と author identifier の関係追加 |
| EntityLinkProposed | Identifier -> Entity 候補リンク追加 |
| EntityLinkProposalRescored | 候補リンク再スコア |
| EntityLinkDecisionRecorded | accept / reject / snooze 等の明示判断 |
| IdentifierLinkedToEntity | 確定リンク |
| IdentifierUnlinkedFromEntity | 確定解除 |
| EntityMergeProposed | entity merge 候補 |
| EntityMerged | entity merge 確定 |
| ObjectInteractionRecorded | owner / LLM / workflow の object 操作・参照履歴 |
| ObjectImportanceSet | owner / LLM による 0..1 の重要度明示 |
| ObjectSignalRecomputed | ObjectSignals projection 再計算 |
| MetacognitiveAssessmentAdded | faithful uncertainty / uncertainty-control assessment 追加 |
| UncertaintyTriggeredSearch | 不確実性に基づく search / read / followLinks 起動 |
| MiningObjectAdded | mining object 追加 |
| MiningObjectSuperseded | mining object 置換 |
| MiningObjectAnnotated | mining object への annotation |
| SecurityAssessmentAdded | prompt injection 等の safety assessment |
| SecurityPreScanCompleted | deterministic pre-scan 結果 |
| SecurityPreScanRulePackUpdated | pre-scan rule pack / pattern 更新 |
| SafetyQuarantineApplied | safety quarantine 適用 |
| SafetyQuarantineCleared | human review による quarantine 解除 |
| SecurityRiskPropagated | 添付・リンク・session による risk 伝播 |
| CrossObjectContaminationDetected | 複数 object 間の stealth interference 候補 |
| WorkflowLogObserved | ClaudeEval / MCP / workflow log 観測 |
| MetaMiningObjectAdded | mining process 自体の mining 結果 |
| TagAsserted | tag assertion 追加 |
| TagDecisionRecorded | tag accept / reject |
| TagAssertionSuperseded | tag 置換 |
| DiagnosticProbeAdded | diagnostic probe 追加 |
| ProbeRunRecorded | diagnostic probe 実行結果 |
| PinnedFactAdded | compilation / scoring の固定 fact |
| CompilationConstraintAdded | pinned fact / ErrorBook / policy 由来制約 |
| ErrorBookEntryAdded | 誤 link / 誤 tag / retrieval failure 等の追加 |
| ErrorBookEntryClosed | ErrorBook entry の検証済み close |
| ErrorBookEntryReopened | fixed / monitoring error の再発 |
| WikiCompileRunStarted | compile-refine workflow 開始 |
| WikiCompileRunCompleted | compile-refine workflow 完了 |
| MemoryBranchOpened | minority / alternative branch 追加 |
| AuditRecordAdded | audit 結果追加 |
| MemoryVitalityScoreUpdated | vitality score 更新 |
| MiningRunStarted | workflow run 開始 |
| MiningRunCompleted | workflow run 完了 |
| MiningResultCommitted | proposal / tag / relation を正準化 |

`MetacognitiveAssessmentAdded` と `SecurityAssessmentAdded` は wrapper / logical event として扱う。
正準事実は `MiningObjectAdded[MiningObjectType -> "..."]` であり、wrapper event を保存する場合も
同一 `MiningObjectID` を含めて replay 時に重複登録しない。専用 segment は `MiningObject` から
再生成可能な surface projection とする。

### 6.3 Immutable snapshot

ClaudeOrchestrator の workflow / prompt / corpus は `SourceVaultSaveImmutableSnapshot` で保存する。

```wolfram
SourceVaultSaveImmutableSnapshot[
  "SourceVaultMiningWorkflowSpec",
  <|
    "WorkflowKind" -> "IdentityAndTagMining",
    "InputManifestRefs" -> {...},
    "ScorerVersion" -> "EntityScorer-v1",
    "ExtractorVersions" -> {...},
    "AccessPolicyRef" -> "...",
    "CreatedAtUTC" -> "..."
  |>,
  "Alias" -> "svminingwf:identity-tag:v0.1"
]
```

## 7. ClaudeOrchestrator workflow

### 7.1 Workflow stages

`SourceVaultIdentityTagMiningWorkflow` は Petri / WorkflowNet として構成する。

1. `BuildInputManifest`  
   対象 object URI、snapshot URI、既存 identity/tag/proposal high-watermark を固定する。

2. `ExtractObjectMetadata`  
   deterministic parser を優先する。mail header、arXiv API cache、web metadata、PDF XMP、Eagle BibTail、Office core properties、Notebook metadata を抽出する。
   IMAP 由来 mail では raw RFC 5322 header 全体、重複順序つき header fields、Received chain、
   Authentication-Results、DKIM / SPF / DMARC / ARC、IMAP UID / mailbox metadata を保存し、配送経路・認証・送信者同定 feature として使う。

3. `SecurityPreScan`  
   mail / PDF / image OCR / web / Office / Notebook text を Wolfram Language / Mathematica の deterministic rule で検査する。
   高 risk text は `TextTrustState -> "forcedUntrusted"` とし、LLM stage に渡さないか isolated / tool-less に縮退する。

4. `ApplySafetyGate`  
   `SafetyState -> "quarantined"` の object を後続 LLM mining、wiki compile、reasoning retrieval から除外する。
   external-origin text は `active` / `warning` に関わらず data boundary 付きで処理し、tool 無しを既定にする。

5. `ExtractTextualAuthorsWithLLM`  
   parser で不足する PDF / web / book front matter だけ LLM extraction を使う。AccessLevel に従い local model を既定にする。

6. `ObserveIdentifiers`  
   Identifier と AuthorshipAssertion を生成する。ここでは entity へ確定リンクしない。

7. `GenerateCandidates`  
   blocking により Identifier-Entity / Entity-Entity 候補を作る。

8. `ScoreCandidates`  
   feature scorer と必要最小限の LLM adjudication で `EntityLinkProposal` を作る。

9. `MineTags`  
   content / title / abstract / Eagle tags / folder / coauthor graph から TopicTag / UserTag / Access tightening tag を提案する。
   日本語 content では `TokenizationMetadata` と `AnalyzerProfile` を参照し、表層形、原形、読み、複合語分割、n-gram fallback を特徴量に使う。

10. `AssessObjectSafety`  
   pre-scan 結果、必要なら isolated LLM judge、添付ファイル情報を統合し、
   Prompt Injection、tool misuse、credential exfiltration、添付ファイル risk の `SecurityAssessment` mining object を作る。

11. `PropagateSafetyRisk`  
   添付ファイル、同一 thread、同一 session、workflow context、引用関係に基づき、
   multi-object risk を生成し、個別 object の risk score を再評価する。
   LLM を使う場合は raw text を束ねず、各 object の pre-scan summary と関係 metadata だけを渡す。

12. `ValidatePolicy`  
   自動確定候補が access 緩和や privacy 逆流を起こさないか検査する。

13. `CommitMiningResults`  
   proposal / tag assertion / authorship assertion を append-only event と segment に保存する。

14. `PrepareReviewQueue`  
    UI 用 queue snapshot を作成する。

15. `BuildMiningVisualizationArtifacts`  
    object relation graph、risk propagation graph、workflow run graph などを生成する。

### 7.2 Workflow token payload

```wolfram
<|
  "RunID" -> "svmine:...",
  "VaultRef" -> "sv://vault/default",
  "InputManifest" -> <|
    "ObjectURIs" -> {...},
    "SnapshotURIs" -> {...},
    "SinceEventHighWatermark" -> "...",
    "ReferenceSnapshotURIs" -> {
      "svref:identity-tag-corpus:v1",
      "svref:llmwiki-mining-reference:v1"
    }
  |>,
  "Policy" -> <|
    "DefaultAccessLevel" -> 0.85,
    "AllowCloudLLM" -> False,
    "MaxIterations" -> 2,
    "TokenBudget" -> 200000,
    "WallClockBudgetSeconds" -> 1800,
    "NoProgressTermination" -> True,
    "AutoConfirmEnabled" -> False,
    "AutoConfirmThreshold" -> 0.98,
    "TagAutoAccept" -> <|"TopicTag" -> True, "AccessTag" -> "TightenOnly"|>,
    "SecurityPreScan" -> <|
      "Enabled" -> True,
      "Engine" -> "SourceVaultSecurityPreScan-v1",
      "WarningThreshold" -> 0.35,
      "QuarantineThreshold" -> 0.65,
      "DataBoundaryForExternalText" -> "Always",
      "MultiObjectJudgeInput" -> "PreScanSummaryOnly",
      "LLMJudgeIsolation" -> <|"Tools" -> False, "MCP" -> False, "Network" -> False, "LocalModelDefault" -> True|>
    |>,
    "MetaMining" -> <|"MaxMetaDepth" -> 1|>
  |>
|>
```

### 7.3 Public API 草案

```wolfram
SourceVaultCreateIdentityTagMiningWorkflowSpec[opts___]
SourceVaultRunIdentityTagMining[vault_, opts___]
SourceVaultMiningRunStatus[vault_, runID_String]
SourceVaultMiningRunReport[vault_, runID_String]
SourceVaultCommitMiningRun[vault_, runID_String, opts___]
SourceVaultRecomputeEntityLinkProposals[vault_, opts___]
SourceVaultSecurityPreScan[vault_, targetRefs_, opts___]
SourceVaultApplySafetyQuarantine[vault_, assessmentID_, opts___]
SourceVaultClearSafetyQuarantine[vault_, targetRef_, opts___]
```

実装初期は `SourceVaultRunIdentityTagMining` が `ClaudeCreateWorkflowNet` / `ClaudeRunWorkflow` を呼ぶ薄い wrapper とする。
ただし ClaudeOrchestrator / ClaudeRuntime の Petri net、retry、approval、worker spawn の責務境界は
実装直前の現行 `ClaudeOrchestrator_workflow.wl` に合わせ、workflow spec 側へ固定しすぎない。

## 8. UI 仕様

### 8.1 Entity resolution queue

```wolfram
SourceVaultEntityResolutionQueueView[opts___]
```

表示列:

- Score
- Identifier display
- Candidate entity
- Evidence summary
- Positive / negative feature badges
- Affected object count
- Tags overlap
- Last scored
- Actions

Actions:

- `Accept`: `IdentifierLinkedToEntity` event を追加
- `Reject`: `EntityLinkDecisionRecorded` with reject
- `CreateNewEntity`: Identifier から entity を新規作成
- `MergeEntities`: merge proposal へ遷移
- `Snooze`: 一定期間 queue から隠す
- `OpenEvidence`: object / metadata / chunk を SourceVaultObjectToCell で表示

### 8.2 Entity detail view

```wolfram
SourceVaultEntityView[entityRef_, "Show" -> {"Identifiers", "Candidates", "Objects", "Tags"}]
```

entity にリンク済み Identifier と、pending / rejected candidates を分けて表示する。  
明示 reject は UI 上で再考可能だが、再提案の理由を表示する。

### 8.3 Tag review queue

```wolfram
SourceVaultTagReviewQueueView[opts___]
```

表示列:

- Target object
- Proposed tag
- TagClass
- SourceKind
- Confidence
- Evidence
- AccessImpact
- Actions

Actions:

- Accept
- Reject
- Rename / map to existing tag
- Convert class: UserTag -> TopicTag 等
- Apply to similar objects

### 8.4 UI 原則

1. `Manual` decision は event として保存し、後で説明可能にする。
2. access を緩める可能性がある操作は一括承認しない。
3. reject は削除ではなく negative evidence である。
4. UI は raw path を主表示しない。`sv://` URI と title / citation / summary を使う。
5. Dataset のボタンは side-effect を伴うため、DryRun / confirmation summary を挟めるようにする。

## 9. 検索・マイニングへの利用

### 9.1 Graph projection

次の edge を graph cache / search index に入れる。

```text
Object --authoredBy--> Entity
Object --observedAuthorIdentifier--> Identifier
Identifier --candidateSameAs(score)--> Entity
Object --hasTag--> Tag
Tag --cooccursWith--> Tag
Entity --associatedWithTag--> Tag
Entity --coauthorWith--> Entity
Object --cites / derivedFrom / mentions--> Object
```

確定 edge と candidate edge は分ける。candidate edge は score threshold と query mode に応じて使う。

### 9.2 検索 API 拡張

```wolfram
SourceVaultSearch[
  query_,
  "Author" -> entityRef | identifierRef | nameString | All,
  "AuthorConfidenceMin" -> 0.85,
  "IncludeCandidateAuthors" -> False,
  "Tags" -> {...},
  "TagSourceKinds" -> {"Manual", "Imported", "Mining"},
  "TagConfidenceMin" -> 0.7
]
```

既定では確定 author link だけを検索 filter に使う。  
`IncludeCandidateAuthors -> True` の場合は UI に「候補リンク由来」であることを明示する。

### 9.3 Ranking features

検索 ranking は次を使える。

- query と object text の keyword / semantic score
- query と object text の lexical token / base form / reading / compound / n-gram score
- query と tag の一致
- Manual / Imported tag の一致
- author entity の確定一致
- candidate author score
- entity と tag の関連度
- coauthor graph proximity
- user が過去に accept した proposal との近さ
- `OwnerImportance` / `LLMImportance` / `EffectiveImportance`
- `OwnerRefCount` / `LLMRefCount`
- `PinState` / `OwnerDismissed` / `OwnerReadState`
- `LLMUsefulCount` / `LLMFailedUseCount`

日本語 ranking では、形態素解析由来の lexical hit を dense embedding の補助ではなく独立した根拠として扱う。
特に person / organization / paper title / mail subject / domain term は `Surface` / `Compound` channel を高く評価し、
一般語の広がりは `Decompound` / `BaseForm` / `NGramFallback` で recall を補う。

Object signal 系 feature は bounded boost として使う。owner の明示重要度は LLM の重要度より優先する。
LLM が自分で参照した object をさらに上げ続ける自己増幅を避けるため、`LLMImportance` / `LLMRefCount`
の寄与には上限を置き、owner feedback、successful diagnostic probe、または `LLMUsefulCount` で補強された場合だけ強くする。
importance は AccessLevel / DenyTag / SafetyState を緩める根拠にはしない。

## 10. 記憶代謝 / WiCER / ErrorBook

### 10.1 位置付け

identity / authorship / tag mining は、単独の batch job ではなく、SourceVault 内の LLMWiki を継続的に改善する memory metabolism の一部として扱う。

採用する設計単位は次である。

| Concept | SourceVault での解釈 |
|---|---|
| TRIAGE | 新規 object / event / mining result を、raw buffer、即時 index、review queue、保留 branch に振り分ける |
| CONTEXTUALIZE | object を author / tag / claim / page / citation / mail thread / Eagle folder などの周辺文脈に接続する |
| DECAY | 古い・低信頼・低利用の派生情報を削除ではなく圧縮、低優先化、または要約へ移す |
| CONSOLIDATE | snapshot 固定された入力に対して wiki page / claim / entity / tag projection を再構成する |
| AUDIT | 確定済み link / tag / claim を一時停止または challenge し、下流検索・probe への影響を測る |
| WiCER | Compile -> Evaluate -> Diagnose -> Refine の反復で、wiki compilation の脱落を diagnostic probe と pinned fact で修復する |
| ErrorBook | 構造エラー、意味エラー、誤 entity link、誤 tag、検索不足、検証失敗を永続的に蓄積し、次回 workflow の制約にする |
| Retrieval as Reasoning | `search` だけでなく `read`、`follow links`、`sufficiency check`、必要なら再検索を行う agent-native retrieval |

### 10.2 追加正準表

#### 10.2.1 DiagnosticProbes

compiled wiki / identity graph / tag projection が保持すべき情報を、質問または検査式として保存する。

| Field | Type | Description |
|---|---|---|
| ProbeID | String | probe id |
| TargetURI | String | object / page / entity / claim / tag / proposal |
| ProbeKind | String | QA / FactPresence / LinkPresence / TagPresence / Contradiction / AccessPolicy |
| Question | String | 自然言語 probe |
| ExpectedAnswer | String / Association / Missing | 期待される答えまたは条件 |
| SourceEvidenceRefs | List[String] | original source 側の根拠 |
| MustPreserve | Boolean | compilation で保持必須か |
| CreatedFrom | String | user / workflow / errorbook / paper-eval |
| Status | String | active / retired / superseded |

#### 10.2.2 ProbeRuns

| Field | Type | Description |
|---|---|---|
| ProbeRunID | String | run id |
| ProbeID | String | 対象 probe |
| RunID | String | workflow / compile run |
| EvaluatedArtifactRef | String | wiki snapshot / graph projection / search index |
| Result | String | pass / fail / partial / inconclusive |
| Score | Real | 0..1 |
| ObservedAnswer | String / Association | 実測回答 |
| FailureClass | String / Missing | missingFact / wrongLink / wrongTag / accessBlocked / insufficientRetrieval |
| ErrorBookRef | String / Missing | 失敗時の ErrorBook entry |
| CreatedAtUTC | String | 時刻 |

#### 10.2.3 PinnedFacts

WiCER の pinned facts は、単なるメモではなく、次回 compilation / consolidation / entity scoring の制約として扱う。

| Field | Type | Description |
|---|---|---|
| PinnedFactID | String | pinned fact id |
| FactKind | String | Claim / EntityLink / TagAssertion / Authorship / PageSection / SourceRef |
| TargetURI | String | 保存すべき対象 |
| Fact | Association | 構造化 fact |
| SourceEvidenceRefs | List[String] | original source の根拠 |
| CreatedByProbeRunID | String / Missing | 失敗 probe から生成された場合 |
| ConstraintStrength | String | MustPreserve / ShouldPreserve / NegativeConstraint |
| Status | String | active / retired / superseded |
| ReviewState | String | HumanReviewed / AutoGenerated / NeedsReview |

`CreatedByProbeRunID` がある場合、その `ProbeRun` は hot storage に保持するか、
cold archive manifest / content hash により後から解決可能でなければならない。
同じ規則を `EntityLinkProposal.PinnedByProbeRefs` と `TagAssertion.PinnedByProbeRefs` にも適用する。

#### 10.2.4 CompilationConstraints

| Field | Type | Description |
|---|---|---|
| ConstraintID | String | constraint id |
| AppliesTo | String | workflow / page / entity / tag / proposal |
| ConstraintKind | String | PreserveFact / PreserveMinority / AvoidLink / AvoidTag / AccessGuard / StructuralRule |
| Payload | Association | 制約本体 |
| SourceRef | String | pinned fact / user decision / errorbook / policy |
| Active | Boolean | 有効か |

#### 10.2.5 ErrorBookEntries

`ErrorBookEntries` は mining の失敗を消す場所ではなく、次回 workflow の入力制約にするための正準表である。

| Field | Type | Description |
|---|---|---|
| ErrorID | String | error id |
| ErrorClass | String | Structural / Semantic / IdentityLink / Tagging / Retrieval / AccessPolicy / Compilation |
| TargetRefs | List[String] | 関連 object / page / entity / proposal / tag |
| Symptom | String | 何が壊れたか |
| Diagnosis | String / Missing | 原因仮説 |
| EvidenceRefs | List[String] | 根拠 |
| Severity | String | info / warning / blocking |
| ProposedFix | Association / Missing | 修正案 |
| Status | String | open / fixed / wontfix / superseded / monitoring |
| OpenedByRunID | String | workflow run |
| ClosedByRunID | String / Missing | 検証済み close run |

#### 10.2.6 WikiCompileRuns

| Field | Type | Description |
|---|---|---|
| CompileRunID | String | compile run id |
| InputSnapshotRef | String | 固定入力 snapshot |
| OutputArtifactRef | String | compiled wiki / graph / projection |
| CompilerVersion | String | compiler / prompt / model version |
| ConstraintRefs | List[String] | pinned facts / ErrorBook / policies |
| ProbeSetRefs | List[String] | 評価に使う probe set |
| Metrics | Association | pass rate / lost pinned facts / error count 等 |
| Status | String | started / completed / failed / superseded |

#### 10.2.7 MemoryBranches

少数仮説や競合する entity / tag / claim は、早期に消さず branch として保持する。

| Field | Type | Description |
|---|---|---|
| BranchID | String | branch id |
| BranchKind | String | MinorityHypothesis / AlternativeEntityLink / AlternativeTag / PageRevision |
| TargetRefs | List[String] | 関連 proposal / claim / tag / page |
| Rationale | String | 保持理由 |
| Gravity | Real | 重要度 / 利用頻度 / evidence 量 |
| Status | String | active / promoted / decayed / retired |
| ReviewAfterUTC | String / Missing | 再検討時刻 |

#### 10.2.8 AuditRecords

| Field | Type | Description |
|---|---|---|
| AuditID | String | audit id |
| TargetRef | String | link / tag / claim / page / entity |
| AuditKind | String | Suspension / Challenge / Reaffirmation / ImpactTest |
| SuspendedProjectionRefs | List[String] | 一時停止した projection |
| ProbeRunRefs | List[String] | audit 中の検証結果 |
| Outcome | String | reaffirmed / weakened / reversed / needsReview |
| CreatedAtUTC | String | 時刻 |

#### 10.2.9 MemoryVitalityScores

記憶の健全性を、単なる件数ではなく運用品質として測る。

| Field | Type | Description |
|---|---|---|
| ScoreID | String | score id |
| ScopeRef | String | vault / page / entity / topic / workflow |
| CoherenceStability | Real | evidence 追加後の整合性 |
| FragilityResistance | Real | 一部 source 欠落時の耐性 |
| MinorityInfluence | Real | 少数仮説が検索・判断に残る度合い |
| ProbePassRate | Real | diagnostic probe pass rate |
| ErrorReopenRate | Real | fixed error の再発率 |
| MetacognitiveFaithfulnessScore | Real / Missing | cMFG 近似。intrinsic uncertainty と expressed uncertainty の整合 |
| UncertaintyDiscrimination | Real / Missing | AUROC 近似。事後正誤を intrinsic uncertainty が弁別できたか |
| MeasuredAtUTC | String | 時刻 |

初期実装では `MemoryVitalityScores` は検索 ranking に使わず、監査 dashboard 専用の近似指標とする。
各値は 0..1 に正規化し、scope ごとに日次または compile / metabolism run 完了時に更新する。

| Metric | 初期近似式 / proxy | 必要データ |
|---|---|---|
| CoherenceStability | `1 - ContradictionRateAfterConsolidation`。同一 subject / predicate の active contradiction 比率で近似 | Claims, Links, ErrorBookEntries |
| FragilityResistance | pinned fact あたりの独立 evidence source 数を capped mean で正規化。source 間引き再 compile は行わない | PinnedFacts, SourceEvidenceRefs |
| MinorityInfluence | active `MemoryBranch` のうち、検索 / audit / probe で参照された branch 比率 | MemoryBranches, AuditRecords, Query logs |
| ProbePassRate | 対象 scope の active `DiagnosticProbe` に対する pass / total | DiagnosticProbes, ProbeRuns |
| ErrorReopenRate | closed error のうち一定期間内に `ErrorBookEntryReopened` された比率 | ErrorBookEntries, ErrorBook events |
| MetacognitiveFaithfulnessScore | `1 - Mean[Abs[IntrinsicUncertainty - ExpressedUncertainty]]` を初期 proxy とし、十分な標本があれば cMFG 近似へ置換 | MetacognitiveAssessments |
| UncertaintyDiscrimination | owner 訂正・`ProbeRun`・`ErrorBook` で事後判明した正誤を `IntrinsicUncertainty` が弁別できたかの AUROC 近似 | MetacognitiveAssessments, ProbeRuns, ErrorBookEntries, MiningDecisions |

### 10.3 既存 identity / tag 機構との接続

`EntityLinkProposal` と `TagAssertion` は、信頼度が高いから即座に真になるのではなく、probe / pinned fact / ErrorBook / audit の影響を受ける。

1. 高 confidence の候補でも、ErrorBook に同種の誤りがある場合は auto confirm を停止する。
2. 失敗 probe により失われた author link / tag / claim は `PinnedFact` に昇格し、次回 consolidation の `CompilationConstraint` になる。
3. 明示 reject は negative constraint として使い、同じ誤提案を ErrorBook に束ねる。
4. 同姓同名や組織名曖昧性は `MemoryBranch` として保持し、十分な反証なしに decay しない。
5. `AuditRecord` で一時停止された link / tag は検索 projection から外し、probe pass rate と検索品質への影響を見る。

### 10.4 ClaudeOrchestrator workflow 追加

#### 10.4.1 SourceVaultWikiCompileRefineWorkflow

WiCER 型の compile / evaluate / refine workflow。
既定では `MaxIterations -> 2` とし、同一 failure signature が再掲された場合は
`NoProgressTermination` で停止する。`TokenBudget` と `WallClockBudgetSeconds` は
workflow manifest の必須項目である。

1. `BuildCompileManifest`  
   入力 snapshot、対象 page / entity / tag projection、既存 ErrorBook / PinnedFacts / constraints を固定する。

2. `CompileWikiArtifact`  
   SourceVault object / claim / link / tag / entity graph から LLMWiki artifact を生成する。

3. `GenerateOrSelectDiagnosticProbes`  
   既存 probe、重要 pinned facts、最近の ErrorBook、ユーザー指定関心領域から probe set を作る。

4. `EvaluateCompiledArtifact`  
   compiled artifact に対して probe を実行し、source 側に存在する fact が wiki 側で答えられるか確認する。

5. `DiagnoseFailures`  
   score 低下、missing fact、wrong link、wrong tag、insufficient retrieval を分類する。

6. `UpdateErrorBookAndPinnedFacts`  
   失敗が original source には存在する情報の脱落なら `PinnedFact` を追加する。構造エラーや誤 link / tag は ErrorBook に追加する。

7. `RefineCompileConstraints`  
   次回 compilation の `CompilationConstraints` を更新する。

8. `CommitCompileRun`  
   `WikiCompileRuns`, `ProbeRuns`, `PinnedFacts`, `ErrorBookEntries` を append-only event として保存する。

#### 10.4.2 SourceVaultMemoryMetabolismWorkflow

定期実行される sleep-cycle workflow。

1. `TRIAGE`  
   新規 object / event / proposal / tag を raw buffer、review queue、auto index、deferred branch に振り分ける。

2. `CONTEXTUALIZE`  
   author / sender / creator、tags、citations、Eagle folders、mail thread、web domain を graph に接続する。

3. `DECAY`  
   低利用・低信頼の派生情報を削除せず、summary 化、priority 低下、または inactive projection に移す。`Gravity` が高い entry と pinned facts は decay 対象から除外する。
   `IngestedAt` からの grace period 内、または `LastOwnerInteractionAtUTC` / `LastLLMInteractionAtUTC` が新しい object は、低 refcount だけを理由に decay 対象にしない。

4. `CONSOLIDATE`  
   snapshot 固定された入力に対して entity projection、tag projection、wiki page、claim graph を再構成する。
   決定性が必要な compile / consolidate stage は `Temperature -> 0`、固定 seed、固定 decoding option を要求する。
   ただし provider 側の非決定性が残る場合、bit 単位の同一性ではなく、diagnostic probe pass set と pinned fact preservation の再現性を監査基準とする。

5. `AUDIT`  
   確定済み link / tag / claim を一時停止し、probe と検索結果への影響を測る。問題がなければ reaffirm、問題があれば review queue または ErrorBook へ送る。

#### 10.4.3 SourceVaultReasoningRetrievalWorkflow

agent-native retrieval は一発検索ではなく、次の tool sequence を許す。
既定では `MaxIterations -> 4` とし、同一 query / read / follow path が再掲された場合は停止する。

```text
assessUncertainty -> search -> read -> followLinks -> inspectEvidence
       -> checkSufficiency -> refineQuery -> search ...
```

`checkSufficiency` が false の場合、検索不足を `ErrorBookEntry[ErrorClass -> "Retrieval"]` として残せる。  
この情報は次回の index / tag / wiki compilation / probe generation に戻す。

`assessUncertainty` は `MetacognitiveAssessment` を生成する。
不確実性が低く evidence sufficiency が高い場合は回答へ進み、不確実性が高い場合は search / read /
followLinks / ask user / defer を選ぶ。回答を出す場合でも、`IntrinsicUncertainty` と
`ExpressedUncertainty` の符号付き差を `FaithfulnessGap` として記録する。
`ConfidentErrorRisk` が高い場合は ErrorBook / probe に戻し、`OverHedgeRisk` が高い場合は
回答有用性低下として meta-mining / evaluation に戻す。

### 10.5 自動確定ポリシーへの追加条件

既存の auto confirm 条件に加え、次を満たす必要がある。

1. 対象 proposal / tag に blocking severity の open ErrorBook entry がない。
2. 関連 probe の pass rate が policy threshold 以上である。
3. 同じ対象に active な minority branch がある場合、branch を消さずに確定 projection と並存できる。
4. `PinnedFact` または `CompilationConstraint` と矛盾しない。
5. audit suspension 中ではない。

### 10.6 実装上の不変条件

1. `CONSOLIDATE` は、必ず固定 snapshot / fixed high-watermark を入力にする。
2. 同じ snapshot、workflow spec、model / prompt version、runtime option では、同じ diagnostic probe pass set と pinned fact preservation を再生成できることを再現性の最低基準とする。
3. `DECAY` は raw source、human decision、pinned fact を物理削除しない。
4. `AUDIT` は削除ではなく、一時停止 projection と probe evaluation で行う。
5. ErrorBook は workflow prompt への単なる添付ではなく、構造化 constraint に変換して使う。
6. search / mining UI は、確定 edge、候補 edge、audit suspended edge、minority branch を区別して表示する。

### 10.7 追加 API 草案

```wolfram
SourceVaultRunWikiCompileRefine[vault_, opts___]
SourceVaultGenerateDiagnosticProbes[target_, opts___]
SourceVaultEvaluateCompiledWiki[artifactRef_, probes_, opts___]
SourceVaultAddPinnedFact[fact_Association, opts___]
SourceVaultPinnedFacts[opts___]

SourceVaultErrorBookEntries[opts___]
SourceVaultAddErrorBookEntry[assoc_Association]
SourceVaultCloseErrorBookEntry[errorID_, opts___]
SourceVaultReopenErrorBookEntry[errorID_, opts___]

SourceVaultRunMemoryMetabolism[vault_, opts___]
SourceVaultRunMemoryAudit[targetRef_, opts___]
SourceVaultMemoryBranches[opts___]
SourceVaultMemoryVitalityScores[opts___]

SourceVaultReasoningRetrieve[vault_, query_, opts___]
SourceVaultCheckRetrievalSufficiency[result_, opts___]
```

## 11. Privacy / Security

1. identity resolution は security boundary ではない。  
   `Identifier -> Entity` が確定しても、それだけで access を緩めてはならない。

2. sender / author 由来の loosening は認証・人間承認なしに行わない。  
   mail sender では既存 `SourceVaultSenderAuthentication` の DMARC / DKIM alignment を用いる。web / PDF / arXiv author は送信者認証ではないため、ContactAccessProfile を緩める根拠にはしない。

3. mining tag の AccessTag は `TightenOnly` を既定にする。  
   例: `NoExternal`, `Personal`, `StudentPrivate` は自動付与可能。`CloudPublishable` のような緩和タグは人間承認必須。

4. high privacy object の author / tag extraction は local workflow を既定にする。  
   cloud LLM へ出す場合は AccessLevel / ReleaseContext / grant が必要。

5. hash URI は identity leak になり得る。UI・prompt では opaque `sv://object/...` / `sv://artifact/...` を優先する。

6. PDF XMP / Office core props / web metadata の author / creator は偽装可能である。  
   `FeatureVector` には `MetadataTrustClass` を持たせ、未認証 metadata 由来 evidence だけで high-confidence link にしない。DMARC / DKIM pass の mail sender と PDF creator metadata は同列に扱わない。

7. LLM 生成 `DiagnosticProbe` は、それ自体が誤る可能性がある。  
   `MustPreserve -> True` の probe、source evidence を直接持たない probe、または `PinnedFact` / `CompilationConstraint` へ昇格する probe は human review を要求する。

8. `ErrorBookEntries`, `ProbeRuns`, `AuditRecords`, `MemoryVitalityScores` は内部診断情報を含む。  
   MCP surface では既定 deny とし、明示 grant がある場合だけ要約版を公開する。公開時の `AccessLevel` は関連 target refs の最大値、すなわち最も厳格な値を継承する。

9. raw `ObjectInteractions` は owner の閲覧・編集・関心・LLM 参照履歴を含む高機微データである。  
   MCP surface では既定 deny とし、公開する場合も原則 `ObjectSignals` の集約値だけにする。
   公開時の `AccessLevel` は関連 target refs の最大値、すなわち最も厳格な値を継承する。

10. mail delivery baseline、sender exception、travel / VPN / forwarding rule、private allowlist / denylist は operational secret とする。  
    `AccessLevel -> 1.0` の private profile としてローカル暗号化保存し、cloud LLM / MCP surface /
    shared snapshot へ raw profile を出さない。delivery anomaly scoring は関数実行時に profile をロードし、
    mining result には profile hash、coarse score、hypothesis だけを残す。

## 12. Migration plan

### Phase 0: schema / projection only

- `TagAssertion`, `AuthorshipAssertion`, `EntityLinkProposal` の schema を追加。
- 既存 `SourceVault_identity.wl` の保存形式を壊さず、proposal は別 store に置く。
- Eagle tags を `Imported` tag assertion として projection できるようにする。

### Phase 1: deterministic extraction

- mail From / AddressBook / existing Identifier を authorship assertion へ投影。
- Eagle `Authors`, `Tags`, `Folders` を assertion 化。
- Eagle stars / mail unread-read / owner open-read 操作を `ObjectInteractions` へ投影。
- arXiv API cache と PDF metadata から author identifiers を観測。
- web metadata / schema.org author を観測。

### Phase 2: proposal / UI

- name / email / ORCID / arXiv / coauthor / tag overlap による候補生成。
- EntityResolutionQueueView / TagReviewQueueView を実装。
- accept / reject events を保存。

### Phase 2.5: security pre-scan / quarantine gate

- `MiningObject` / `MiningAnnotation` / `SecurityAssessment` の schema を追加。
- Wolfram Language / Mathematica 式による deterministic `SecurityPreScan` を実装。
- mail / PDF / image OCR / web / Office / Notebook text を LLM に渡す前に pre-scan する。
- `SafetyState` / `TextTrustState` / `SafetyQuarantine` projection を実装。
- quarantined object を LLM mining / wiki compile / reasoning retrieval から除外する。
- LLM judge を使う場合は tool / MCP / network 無し、schema 出力のみの isolated classifier に限定する。
- external-origin text をすべての LLM stage で data boundary 化する。
- multi-object contamination judge は pre-scan summary / metadata を入力とし、raw text を束ねない。
- sanitized text の offset map / rule ref と pre-scan rule pack version を保存する。

### Phase 3: ClaudeOrchestrator workflow

- `SourceVaultRunIdentityTagMining` を WorkflowNet として実装。
- run manifest / workflow snapshot / report を保存。
- LLM extraction は parser 不足分に限定する。
- Phase 2.5 の safety gate を通過した object だけを通常 LLM stage に投入する。

### Phase 4: re-score / auto confirm

- 新 evidence 追加時に proposal を再スコア。
- auto confirm は既定 off のまま、human decision との一致率・誤り率を測る。
- auto confirm threshold と policy gate を実装。ただし有効化は計測結果に基づく明示設定後に限る。
- accepted/rejected decision を scorer feedback として利用。

### Phase 5: search integration

- `SourceVaultSearch` の author / tag filter を拡張。
- PurposeIndex / ProjectionIndex に object tags と author entity edges を取り込む。
- `ObjectInteractions` rollup から `ObjectSignals` をローカル projection として再生成する。
- `ObjectSignals` を bounded ranking boost として利用する。
- `MetacognitiveAssessment` を reasoning retrieval の search / defer / ask user 制御に使う。
- query explanation に「どの tag / entity link が効いたか」を表示する。

### Phase 6: memory metabolism / compile-refine

- `DiagnosticProbe`, `ProbeRun`, `PinnedFact`, `ErrorBookEntry` の schema を追加。
- `SourceVaultWikiCompileRefineWorkflow` を ClaudeOrchestrator workflow として実装。
- identity / tag mining の失敗を ErrorBook に記録し、次回 proposal / scorer / compiler の制約へ戻す。
- `TRIAGE` / `CONTEXTUALIZE` / `DECAY` / `CONSOLIDATE` / `AUDIT` を sleep-cycle workflow として実装。
- meta-mining は `MaxMetaDepth -> 1`、budget、no-progress termination を必須とする。

## 13. 受け入れ基準

1. mail From 由来 Identifier と、PDF / arXiv / web / Eagle の Authors 由来 Identifier が同じ UI queue に出る。
2. `Identifier.EntityRef` は人間 accept または policy を満たす auto confirm まで変更されない。
3. reject された candidate は後続 mining で negative evidence として使われる。
4. Eagle tag は `Imported` として保存され、Manual / Mining tag と区別して検索できる。
5. mining が付けた tag は、由来・confidence・evidence・review state を持つ。
6. AccessTag の自動付与は tightening に限定され、loosening は human review 必須。
7. ClaudeOrchestrator workflow の run manifest に入力 snapshot URI、extractor/scorer version、AccessPolicy が残る。
8. 新 evidence 追加により proposal score が再計算され、accepted/rejected の人間判断は勝手に覆らない。
9. `SourceVaultSearch` は確定 author link と candidate author link を区別して使える。
10. local cache を消しても event / segment / snapshot から identity proposal と tag projection を再構築できる。
11. compiled wiki / projection に対して diagnostic probe を実行し、失敗を `ProbeRun` と `ErrorBookEntry` として保存できる。
12. original source に存在した fact が compilation で脱落した場合、`PinnedFact` として次回 workflow の制約にできる。
13. 誤 entity link / 誤 tag は ErrorBook に残り、同じ誤提案の auto confirm を抑制する。
14. audit は確定済み link / tag を物理削除せず、一時停止 projection と probe によって影響を測れる。
15. reasoning retrieval は search / read / follow links / sufficiency check の履歴を残し、検索不足を ErrorBook に戻せる。
16. reasoning retrieval は `MetacognitiveAssessment` により、低確信時に search / read / followLinks / ask user / defer を起動できる。
17. high confidence だが evidence sufficiency が低い claim は、自動確定せず hypothesis / probe / ErrorBook へ回せる。
18. IMAP mail ingest では raw RFC 5322 header 全体、重複順序つき header fields、Received chain、Authentication-Results、DKIM / SPF / DMARC / ARC を保存できる。
19. mail delivery path が sender / organization の baseline から外れた場合、DeliveryAnomaly として記録し、spoofing と benign exception の両方を hypothesis として扱える。
20. mail delivery baseline / private exception rule は `AccessLevel -> 1.0` の private operational profile としてローカル暗号化保存され、cloud LLM / MCP / shared snapshot へ raw profile が出ない。
21. `AutoLinkPolicy.Enabled -> False` でも extraction、proposal、review、search がすべて動作する。
22. workflow は `MaxIterations` / `TokenBudget` / `WallClockBudgetSeconds` / `NoProgressTermination` を manifest に残す。
23. privacy estimate、summary、Eagle memo、search result annotation、security assessment は `MiningObject` / `MiningAnnotation` として履歴化できる。
24. owner / LLM の refcount、0..1 importance、pin / dismiss / read state を `ObjectInteractions` として履歴化し、`ObjectSignals` projection として利用できる。
25. owner の mark-as-important は LLM importance より優先され、importance により AccessLevel / SafetyState / DenyTag は緩和されない。
26. Prompt Injection risk は単一 object と multi-object contamination の両方で保存でき、添付ファイル risk が親メールへ伝播する。
27. Prompt Injection 判定は LLM 前の deterministic pre-scan を必ず通り、pre-scan risk を LLM 判定で下げられない。
28. `SafetyState -> "quarantined"` の object は LLM mining / wiki compile / reasoning retrieval に投入されない。
29. external-origin text は `SafetyState -> "active"` でも全 LLM stage で data boundary 化される。
30. multi-object contamination judge は既定で raw text を同梱せず、pre-scan summary と metadata のみを入力にする。
31. ClaudeEval / MCP / ClaudeOrchestrator workflow logs を meta-mining し、safety score 低下や workflow 異常を検出できる。
32. mining graph / risk propagation graph / workflow run graph を visualization artifact として再生成できる。

## 14. 未決事項

1. `Identifier.Kind` の正式 enum と既存データ migration の互換性。
2. 日本語氏名の human review UI で、漢字 / かな / ローマ字の evidence をどう並べるか。
3. ORCID / Crossref / Semantic Scholar 等の外部照合を使う場合の network / privacy policy。
4. Entity merge UI の詳細。
5. tag ontology を flat string のままにするか、階層 tag / alias / synonym table を持つか。
6. auto confirm threshold を個人運用でどこまで許すか。
7. AccessTag / TopicTag / UserTag の既存 API 名との対応。
8. `SourceVault_identity.wl` 本体に proposal API を入れるか、`SourceVault_mining.wl` / `SourceVault_tags.wl` に分けるか。
9. diagnostic probe を人間が書く UI と、workflow が生成する UI をどう分けるか。
10. ErrorBook entry の粒度を、object 単位、page 単位、proposal 単位のどこに寄せるか。
11. memory vitality score は初期実装では監査 dashboard に留め、検索 ranking へ入れるかは実測後に判断する。

## 15. 最小 API 一覧

```wolfram
SourceVaultObserveIdentifier[vault_, kind_, value_, opts___]
SourceVaultAddAuthorshipAssertion[vault_, assoc_]
SourceVaultProposeEntityLink[vault_, identifierRef_, entityRef_, opts___]
SourceVaultEntityLinkProposals[vault_, opts___]
SourceVaultAcceptEntityLinkProposal[vault_, proposalID_, opts___]
SourceVaultRejectEntityLinkProposal[vault_, proposalID_, opts___]
SourceVaultRecomputeEntityLinkProposals[vault_, opts___]

SourceVaultLoadPrivateProfile[vault_, profileKind_, opts___]
SourceVaultSavePrivateProfile[vault_, profileKind_, profile_Association, opts___]
SourceVaultAssessMailDeliveryAnomaly[vault_, sourceID_, opts___]
SourceVaultRecordObjectInteraction[vault_, targetURI_, interaction_Association, opts___]
SourceVaultSetObjectImportance[vault_, targetURI_, actorKind_, value_Real, opts___]
SourceVaultObjectSignals[vault_, targetURI_, opts___]
SourceVaultRecomputeObjectSignals[vault_, opts___]

SourceVaultAddMiningObject[vault_, object_Association, opts___]
SourceVaultMiningObjects[vault_, opts___]
SourceVaultAnnotateMiningObject[vault_, miningObjectID_, annotation_, opts___]
SourceVaultAddMetacognitiveAssessment[vault_, assessment_Association, opts___]
SourceVaultAssessUncertainty[vault_, targetRef_, opts___]
SourceVaultSecurityPreScan[vault_, targetRefs_, opts___]
SourceVaultClassifyPromptInjectionText[text_String, opts___]
SourceVaultAssessPromptInjectionRisk[vault_, targetRefs_, opts___]
SourceVaultApplySafetyQuarantine[vault_, assessmentID_, opts___]
SourceVaultClearSafetyQuarantine[vault_, targetRef_, opts___]
SourceVaultPropagateSecurityRisk[vault_, assessmentID_, opts___]
SourceVaultMineWorkflowLogs[vault_, opts___]
SourceVaultBuildMiningGraph[vault_, scope_, opts___]
SourceVaultVisualizeMiningGraph[graph_, opts___]
SourceVaultMiningDashboard[vault_, opts___]

SourceVaultAssertTag[vault_, targetURI_, tag_, opts___]
SourceVaultObjectTags[vault_, targetURI_, opts___]
SourceVaultTagAssertions[vault_, opts___]
SourceVaultAcceptTagAssertion[vault_, tagAssertionID_, opts___]
SourceVaultRejectTagAssertion[vault_, tagAssertionID_, opts___]

SourceVaultEntityResolutionQueueView[vault_, opts___]
SourceVaultTagReviewQueueView[vault_, opts___]
SourceVaultEntityView[vault_, entityRef_, opts___]

SourceVaultCreateIdentityTagMiningWorkflowSpec[opts___]
SourceVaultRunIdentityTagMining[vault_, opts___]
SourceVaultMiningRunStatus[vault_, runID_]
SourceVaultMiningRunReport[vault_, runID_]

SourceVaultRunWikiCompileRefine[vault_, opts___]
SourceVaultGenerateDiagnosticProbes[vault_, target_, opts___]
SourceVaultEvaluateCompiledWiki[vault_, artifactRef_, probes_, opts___]
SourceVaultAddPinnedFact[vault_, fact_, opts___]
SourceVaultErrorBookEntries[vault_, opts___]
SourceVaultRunMemoryMetabolism[vault_, opts___]
SourceVaultRunMemoryAudit[vault_, targetRef_, opts___]
SourceVaultReasoningRetrieve[vault_, query_, opts___]
SourceVaultReopenErrorBookEntry[vault_, errorID_, opts___]
```

`SourceVaultAddMetacognitiveAssessment` は `SourceVaultAddMiningObject` の wrapper であり、
戻り値には少なくとも `MiningObjectID` と `AssessmentID` を含める。初期実装では両者を同一 ID にしてよい。
projection segment への書き込みは同じ event transaction 内で行うか、replay から再生成する。

## 16. 結論

SourceVault の自己組織化は、LLM が直接 entity や tag を確定更新する仕組みではなく、観測、候補、根拠、確率、人間判断、再スコア、確定リンクを分離した event-sourced なグラフ成長機構として実装する。

特に重要なのは次の分離である。

- `Identifier` と `Entity`
- 確定リンクと候補リンク
- 著者 assertion と access policy
- Manual / Imported / Mining / System tag
- TopicTag と AccessTag
- mining result と human decision
- compiled wiki と raw source
- auto confirm と audit / probe / pinned fact

この分離を保てば、web / arXiv / Eagle / mail / document metadata から得られる弱い情報を積極的に使いながら、誤リンクや同姓同名、タグ誤付与、privacy 逆流を安全に扱える。  
そのうえで、確定済み entity link と信頼度つき tag を PurposeIndex / semantic search / graph search に取り込み、probe / ErrorBook / pinned fact / audit によって誤りを次回 workflow の制約へ戻すことで、SourceVault は単なる保存庫ではなく、利用するほど object 間の構造が濃くなり、失敗から学習する知識基盤になる。

## Appendix A. Ingest 時の MetacognitiveAssessment の動作例

### A.1 mail ingest

IMAP から mail を取り込むとき、SourceVault は From / To / Subject / Date などの代表 metadata だけでなく、
raw RFC 5322 header 全体、Received chain、Authentication-Results、DKIM / SPF / DMARC / ARC、
IMAP mailbox / UID などを保存する。

`MetacognitiveAssessment` は、要約・重要度推定・送信者同定・安全性評価の前後で次を評価する。

- この sender は AddressBook / Identity / DKIM-DMARC alignment からどの程度確からしいか。
- 本文要約、締切、依頼事項、重要度推定は header / body / attachment evidence に支えられているか。
- 添付ファイルや OCR text を読まずに判断していないか。
- delivery path が sender / organization の通常 profile から外れていないか。
- Prompt Injection / phishing / credential exfiltration の兆候がないか。

例: 普段は国内大学 network または既知 cloud relay を通る学科メンバーの mail が、
一通だけ未知 ASN / 海外 IP を経由し、Authentication-Results も弱い場合、
SourceVault はそれを `MailDeliveryAnomalyDetected` として記録する。
ただし、それだけで spoofing と断定せず、海外出張、VPN、転送、mailing list relay などの
`BenignExceptionHypotheses` も保持する。
この場合 `MetacognitiveAssessment` は `UncertaintyKind -> {"Epistemic"}`、
`ConflictWithRetrievedEvidence -> True`、`EvidenceSufficiency` 低下、
`RecommendedAction -> "AskUser"` または `"Search"` のようにし、
`MailDeliveryObservation.RecommendedAction` は `"verifySender"` または `"inspectHeaders"` のようにして、
通常の自動確定や高 confidence summary へ進ませない。

### A.2 web / PDF / arXiv ingest

web page や PDF / arXiv 論文では、author metadata、schema.org、PDF XMP、引用、本文 chunk、
同一 ingest session の文献集合、既存 SourceVault object との一致・矛盾を evidence とする。

`MetacognitiveAssessment` は次を確認する。

- author / creator は本文由来か、metadata 由来か、LLM extraction 由来か。
- 引用・関連論文を実際に読んだか、それとも title / abstract だけで判断しているか。
- summary や claim は全文・該当 chunk に支えられているか。
- 既存 SourceVault 内の claim / tag / entity link と矛盾していないか。
- OCR 品質や chunk boundary が低く、読めたつもりになっていないか。

根拠が不足する場合、workflow は断定的な summary / claim として保存せず、
`RecommendedAction -> "Search"` / `"ReadMore"` / `"CreateProbe"` / `"Defer"` を選び、
関連論文検索、follow links、diagnostic probe、ErrorBook へ接続する。
一方、十分な evidence がある場合は、MiningObject、TagAssertion、AuthorshipAssertion、
EntityLinkProposal へ通常通り投影できる。

### A.3 SourceVault と相性が良い理由

SourceVault は一回の応答で完結する chat system ではなく、object、evidence、proposal、decision、
ErrorBook、probe、ObjectSignals を長期に保存し、後日再評価する知識基盤である。
そのため、LLM が「今は不確か」と判断した状態自体を保存できる。

```text
未確定 / 候補 / 仮説 / 要検索 / 要人間確認 / 根拠不足 / source conflict
```

を正準状態として持てることが、faithful uncertainty と相性がよい。
後日、同じ sender からの追加 mail、arXiv metadata、関連論文、owner の mark-as-important、
DKIM / DMARC の新 evidence、ErrorBook の誤判定記録が増えれば、過去の
`MetacognitiveAssessment` を再評価できる。

このため SourceVault の ingest workflow は、LLM が即断する保管庫ではなく、
安全性・有用性・関係記述の不確実性を保存し、検索・検証・人間判断へ回すための
半自動的な制御系として機能する。
