# SourceVault_integrity API リファレンス

パッケージ: SourceVault_integrity (https://github.com/transreal/SourceVault_integrity)。コンテキストは `SourceVault``。
読込: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_integrity.wl"]]`

## 概要
知識ネットワーク健全性監視 (03 SystemDoctor 拡張仕様 v0.4) の実装。service-loadable で、FrontEnd・Notebook・NBAccess には依存しない。NBAccess・diagnostics・ClaudeDirectives・webingest・KG とは弱結合。
- 所有者専用関数 (§11.5) と、方針・出口 API の承認 head 登録 (02 v1.2 §7.1 A-4)。
- 来歴台帳 (SourceVault_provenance、https://github.com/transreal/SourceVault_provenance) の上に載る。
- 記録点 (Inc2)、Instruction の基準ハッシュ・LoadVerify・InstructionDrift、検証器と state.json・probe、backfill。
- Inc3 のラベルと認可、実効ラベル、検索フィルタ、Policy。
- Inc4 の公開の関所と ModelManifest。
- Inc5 の KnowledgeHealth・BlastRadius・fail-closed の準備。
- "SourceVault*" の一括信頼 ($NBTrustedPackageHeads) より、$NBApprovalHeads / $NBDenyHeads の明示登録が先に評価される。登録された関数は提案コードから呼ぶと NeedsApproval になる。

## 規約
- 所有者操作の共通動作:
  - 主体は所有者 (OwnerFE / OwnerCode) に限る。
  - ticket は SourceVaultOwnerTicketDialog (FE、発行元 OwnerFE) か、development profile の開発用の鍵だけ。
  - "Ticket" 無しで呼ぶと実行せず `<|"Status"->"ReviewRequired","TicketAction","Bind","BindDisplay"|>` を返す。Dialog に Display と Bind を渡す。
  - Model / MCP / Service からの呼出しは拒否し (Failure NotAuthorized 系)、Registry に試みを記録する。
  - 記録は台帳のラベルの記録 (ticket を同梱) で、service が取り込むと効く。
- 記録点 (SourceVaultProvRecord*) はどの主体からも呼べる。失敗は数えるだけで、元の処理を止めない。
- 状態を変える関数・設定変数の代入は NBAccess の承認対象。
- 状態ファイルは LocalState/provenance/health/ 配下にある。
  - state.json
  - instruction-baseline.json
  - policy-baseline-<role>.json
  - policy-snapshot-service.json
  - model-manifest-baseline.json
  - backfill.json
  - findings.jsonl
  - warn-state.json
  - probe-state.json
  - registry-attempts.jsonl
- Finding は health/findings.jsonl に残す。Failing と High は診断 spool へ EventClass IntegrityFinding・Producer integrity で書く。同じ Component|ReasonCode|Target は 24 時間に 1 回。
- 時刻は ISO UTC 文字列 (`2026-11-10T12:00:00Z`)。
- Instruction 系は 2 群に分かれる。
  - HumanEdited (手編集が正常な群): Claude Directives の CLAUDE.md・rules・skills、~/.claude の CLAUDE.md・rules。
  - ModelWritable (モデルが書き得る群): SourceVault_workflows の *.wl・TurnWiki の wiki と skill・AutoTrigger 設定・runner manifest。
- Inc3 の AuthorizeInstruction が入るまでは、所有者が受け入れた基準ハッシュが認可の代用になる ($SourceVaultIntegrityBaselineAsAuthorization)。

## 承認 head・方針変数

### $SourceVaultApprovalHeads
型: List[String]
NBAccess の $NBApprovalHeads に登録する公開関数名のリスト。含まれるもの:
- 方針・出口 API: MailSend / WebGuardResolveRequest / Set*PrivacyLevel 系 / ResetEvaluationPrivacy / ExportKeyBundle / DecryptRecord / MCPRegisterTools。
- §11.5 の所有者専用関数。
- 所有者 ticket の発行 (OwnerTicketDialog / Mint)。
- SecurityProfile 検査の登録。
- 来歴台帳の状態を変える関数。

### $SourceVaultApprovalSetSymbols
型: List[String]
NBAccess の $NBApprovalSetSymbols に登録する方針変数名のリスト。Module 内の代入でも承認対象になる。含まれるもの:
- $SourceVaultPrincipal と $SourceVaultSecurityProfile。
- 所有者 ticket の鍵と店。
- AutoTrigger permit の鍵と強制。
- 要約 LLM の送り先。
- Web 関所の切替。
- 来歴の鍵と spool。
- Instruction 群の root と LoadVerify の強制。

### SourceVaultRegisterApprovalHeadsWithNBAccess[] → Association
$SourceVaultApprovalHeads と $SourceVaultApprovalSetSymbols を NBAccess に登録する。冪等。NBAccess 未ロードなら `<|"Status"->"NBAccessAbsent"|>`。ロード時に 1 回呼ばれる。NBAccess を後からロードした場合は既定表が同名を持つので再登録は不要 (呼んでもよい)。

## 所有者専用操作 (ticket 必須・承認 head)

### SourceVaultIntegrityRecordOwnerReview[ref, scope, note, opts] → Association | Failure
所有者の確認を OwnerReviewed の検証主張 (ProvVerification、Kind Human) として記録する (§5.3 / §11.5)。
出自・隔離・認可は変えない。主張であって、正しさの証明でも命令採用の認可でもない。
ticket の Action は "RecordOwnerReview"。Ungrounded の外れにも効く。

### SourceVaultIntegrityAuthorizeInstruction[ref, purpose, opts] → Association | Failure
版 (BlobId) を用途の命令として採用する認可 (ProvAuthorization、§5.4 / §11.5)。
- ref: EntityId / BlobId / LogicalRef / Instruction 系ファイルのパス。
- purpose: "Directive" | "Workflow" | "TurnWikiRule" | "SystemPrompt" | "SeriesSpec" | "ProcessDelta"。
- 隔離中・OriginClass Unknown・確定前 (Pending)・記録の無い版には出さない (Failure["NotUsable"])。
- 認可は BlobId と用途に束縛され、内容が 1 バイトでも変われば LoadVerify が拒否する。
- ExternalDerived の版は、確認の表示に外部由来と出る。
- Options: "Ticket" (Action "AuthorizeInstruction"), "RequiredClaims" -> {property..} (登録済みの決定的検証器の Pass で満たす), "ExpiresAtUTC", "Note", "Scope" -> <|"Machines"->"All"|{machineTag..}, "Profiles"->"All"|{"production"|"development"..}|> (既定は両方 All 相当。ほかの鍵・空の一覧・未知のプロファイルは Failure["BadScope"])。
- LoadVerify は、読む機 (SourceVaultMachineTag[]、大小文字を区別しない) と $SourceVaultSecurityProfile が Scope に入る認可だけを数える。
- 次のときは認可を使わない (2026-11-11)。
  - 索引が使えない (再構築中・連鎖の破損を含む)。
  - 版がいま隔離中・Unknown・確定前。

### SourceVaultIntegrityRevokeAuthorization[authId, reason, opts] → Association | Failure
認可の取消し (ProvRevocation)。Options: "Ticket" (Action "RevokeAuthorization")。

### SourceVaultIntegrityQuarantine[ref, reason, opts] → Association | Failure
版を明示的に隔離する (Severity High の ProvFinding、Kind OwnerQuarantine、§5.5 / §9.2)。
- ref は EntityId / BlobId (同じ内容の版すべて) / LogicalRef / ファイル。
- carry 辺の子孫も隔離される。ファイルは残す。
- Options: "Ticket" (Action "Quarantine")。

### SourceVaultIntegrityRelease[ref, findingId, ground, opts] → Association | Failure
版をその Finding による隔離から解除する (ProvRelease、§5.5)。解除した版を通る子孫も外れる。
ground:
- `<|"Kind"->"IndependentOfTaint","Scope"->..|>` (主張単位で汚染部分に依存しない確認。"Scope" 必須)
- `<|"Kind"->"Sanitizer","Sanitizer"->..|>` (適用範囲の明確な決定的 sanitizer。"Sanitizer" 必須)
- `<|"Kind"->"Regenerated"|>` (汚染の無い入力からの新しい版)

Options: "Ticket" (Action "Release")。

### SourceVaultIntegrityResolveFinding[fid, resolution, opts] → Association | Failure
Finding を解決する (ProvFindingResolution、§4.6 / §9.3)。resolution:
- `<|"Kind"->"FalsePositive","Reason"->..|>`: 撤回。子孫の隔離もすべて外れる。
- `<|"Kind"->"Remediated","Replacements"->{訂正版 EntityId..},"OpenPublications"->0|>`: 旧版と子孫は隔離のまま。公開済みの訂正が残る間 (OpenPublications > 0) はできない。
- `<|"Kind"->"AcceptedRisk","Scope"->|"Purposes"->{"HumanSearch"..}|>,"ExpiresAtUTC"->..,"Reason"->..|>`: 範囲の用途で期限まで外れる。RAG / AutoExec / Publish / Instruction を含めるには "ConfirmAutomatic" -> True。

Options: "Ticket" (Action "ResolveFinding"), "ConfirmAutomatic"。
例: `SourceVaultIntegrityResolveFinding["fnd-...", <|"Kind"->"FalsePositive","Reason"->"誤検知"|>, "Ticket"->t]`

### SourceVaultIntegrityAcceptBaseline[component, opts] → Association | Failure
基準を受け入れる (§11.5)。component ごとの動作:
- "Instructions" (Inc2):
  - SourceVaultInstructionFiles[] を再ハッシュし、基準 (health/instruction-baseline.json) との差分 (変更・追加・削除) を記録する。記録先は Instruction Entity (Kind Instruction、VersionOf 前の版) と HumanEdit Activity。
  - その後で基準を更新する。
  - ticket は Action "AcceptBaseline"、Bind = <|"Display"->変更一覧の digest,"Component"->"Instructions" の digest|> (digest は SourceVaultOwnerTicketDigest)。
  - ticket 無し・"DryRun"->True では変更一覧と Bind の digest を返すだけ ("Status"->"ReviewRequired")。
  - $SourceVaultIntegrityBaselineAsAuthorization が True の間 (移行期間)、この受入はモデルが書き得る群の認可の代わりにもなる。
- "SecurityProfile" (Inc3): Policy 部品の基準を受け入れる。
  - 基準は SourceVaultIntegrityPolicySnapshot[] の項目ごとの digest で、カーネルの役割 FE / Service ごとに health/policy-baseline-<role>.json に置く。
  - Bind "Component" は SecurityProfile の digest。
  - "Role"->"Service" を付けて FE から呼ぶと service の基準 (policy-baseline-service.json) を受け入れる (2026-11-11)。
  - service は Policy の検査のたびに policy-snapshot-service.json (項目ごとの digest だけ、値は含まない) を書く。これを読み、形式・digest と項目の一致・新しさを確かめてから受け入れる。Bind に "Role" の digest が加わる。
  - 失敗: Failure["ServiceSnapshotMissing" | "ServiceSnapshotInvalid" | "ServiceSnapshotStale"]。
- "ModelManifest" (Inc4): LM Studio のモデル・テンプレート・版の基準 (health/model-manifest-baseline.json)。系列は未実装 (Inc8)。

Options: "Ticket", "DryRun" -> False, "Paths" -> All | {path..} (Instructions の受入範囲), "Note", "Role" -> Automatic (SecurityProfile。Automatic はこのカーネルの役割), "MaxSnapshotAgeSeconds" -> 900 (service 要約の許容年齢)。

カーネルの役割の決まり方:
- Service: service の目印 ($SourceVaultDiagnosticsCanonicalWriter、SourceVaultServiceMain が立てる) がある。
- FE: ノートブックが使える。
- Other: どちらでもない (並列の子カーネル・台本・起動途中の FE)。

Other では Policy を検査せず要約も書かず、基準も受け入れない。

### SourceVaultIntegrityRegisterVerifier[name, spec, opts] → Association | Failure
検証器の登録・変更 (ProvVerifierRegistration、§5.3 / §11.5 / 表 11.1)。
spec = `<|"Kind"->"Deterministic"|"Model","Properties"->{..},"Implementation"-><|"Package","Function","Digest"|>,"Applies","Period","Budget"|>`。
検証主張 (ProvVerification) は、登録表にある決定的検証器のものだけが認可の RequiredClaims に効く。
モデル・MCP クライアントからの登録は拒否して Registry に記録する。Options: "Ticket" (Action "RegisterVerifier")。

### SourceVaultRederiveApprove[planId] → Failure["NotImplemented"]
作り直し計画の承認 (§11.5 / 14 章)。未実装 (Inc7)。

### SourceVaultIntegrityOwnerAction[call] → 評価結果
所有者操作 (例 `SourceVaultIntegrityResolveFinding[fid, <|...|>]`) を FE から 1 回で行う。HoldFirst。
- 主体を OwnerCode にして call を評価する。
- ReviewRequired が返れば SourceVaultOwnerTicketDialog に表示文と Bind を渡し、承認された ticket を付けて call をもう一度評価する。
- View のボタンが置く式テンプレートが使う。NBAccess の承認 head。

## ラベル・検索フィルタ・Policy

### SourceVaultIntegrityLabel[ref] → Association | Missing["IndexUnavailable"]
版の実効ラベルを返す (§11.2)。ref は EntityId / BlobId / LogicalRef (最新の版)。
キー:
- "PrivacyLevel"
- "Origin" (Contributors / Taints / OriginClass、5.2 節の合成後)
- "Completeness", "Claims"
- "Quarantine" -> <|"Quarantined","FindingIds","Findings"|>
- "Authorizations", "Usability", "ObservedSeq"
- V9 (文書 12、2026-11-13):
  - "Grounding" -> "Grounded" | "Partial" | "Ungrounded" | "NotNeeded" | "Unknown" (裏付け検査の結果。回答の版に束縛)
  - "GroundingOwn" (その版自身の判定)
  - "GroundingInherited" (Ungrounded の版から carry 辺で届いた)
  - "UngroundedFrom" (起点の版)

Model / MCP には、PL 0.5 以上の版の BlobId・Origin の Taints・Claims を伏せる。索引が使えなければ Missing["IndexUnavailable"]。
Ungrounded は Usability を変えない。検索では下位に回して印を付け、公開では警告する。所有者の確認 (RecordOwnerReview) で外れる。

### SourceVaultIntegrityRetrievalFilter[candidates, opts] → List | Association | Failure
検索・RAG の候補から利用できない版を除く (§9.2 / §11.2)。
候補は EntityId / BlobId / LogicalRef (ObjectURI・URI・SourceId 等) で usability.wxf の表に引き当てる。
Options:
- "Purpose" -> Automatic。"RAG" | "AutoExec" | "HumanSearch" | "AuditView"。
  - Automatic のときは、Model / MCP / 未束縛は RAG、Service は AutoExec、所有者は HumanSearch になる。
  - Model / MCP は指定しても RAG に固定される。
- "SupplyPoint" -> (記録用の名前)
- "Report" -> False。True で `<|"Results","Purpose","Filter"->"OK"|"Unavailable","Excluded","Marked","NotRecorded","Grounding"|>` を返す。

用途ごとの動作:
- RAG / AutoExec: 隔離中 (その用途の AcceptedRisk の外) と派生物の Unknown を除外し、件数を記録する。
- HumanSearch: 除かず "IntegrityUsability"->"Quarantined" の印を付ける。
- AuditView: OwnerFE だけ (他は拒否して Registry に記録)。隔離中を含めて印を付け、結果に自動の文脈へ渡せない印 "IntegrityPurpose"->"AuditView" を持たせる。
- 記録の無い候補は NotRecorded として通す。
- フィルタが使えない (索引が無い・再構築中・連鎖の破損) とき:
  - $SourceVaultIntegrityFilterFailClosed が True なら RAG / AutoExec は Failure["IntegrityFilterUnavailable"]。
  - False なら記録して通す。
- V9: Ungrounded の版は除かず、"IntegrityGrounding"->"Ungrounded" の印を付けて結果の末尾に回す (AuditView では並びを変えない)。Partial には "IntegrityGrounding"->"Partial" の印だけを付ける。件数は "Grounding"-><|"Ungrounded","Partial"|>。

### SourceVaultIntegrityPolicySnapshot[] → Association
Policy 部品 (§7.1 SecurityProfile) が見る設定の項目ごとの digest `<|"Role"->"FE"|"Service","Items"-><|name->digest|>,"Digest"|>`。値そのものは返さない。
項目:
- SecurityProfile・WebGuard の有効・ConservativePrivacyDefault
- 承認 head と方針変数・信頼 head
- tool loop の許可一覧・MCP の無効ツール・AccessibleDirs
- integrity / provenance の設定・来歴の鍵の KeyId・検証器の登録表

基準は SourceVaultIntegrityAcceptBaseline["SecurityProfile"]。

## 公開の関所 (Inc4)

### SourceVaultIntegrityPublishGate[items, destination, opts] → Association
公開 (メール送信・コミット・アップロード) の直前の関所 (§9.2)。
- items の要素: ファイルのパス / `<|"Path"|>` / `<|"Text"|>` / `<|"EntityId"|>` / `<|"BlobId"|>` / `<|"LogicalRef"|>`。
- Options: "Channel", "Record" -> True。
- 戻り値: `<|"Decision","Reasons","Items"->{<|Index,Verdict,FindingIds|>..},"Recorded","ActivityId","Outcome","IndexState"|>`。
- Deny: 次のいずれかを含む。
  - 隔離中 (用途 Publish の AcceptedRisk の外) の版。
  - 派生物の Unknown の版。
  - 確定して Usable になっていない名指しの版 (NotCommitted)。
- Warn: 索引が使えない (再構築中 IndexRebuilding・連鎖の破損 LedgerChainDamaged を含む) か、24 時間より古い。記録して通す。$SourceVaultIntegrityPublishFailClosed なら Deny。
- Allow: それ以外。
- 公開の意図を Publish Activity (Outcome Approved / Blocked、入力は記録のある版、宛先は鍵付き digest) に残す。書けなければ ProvenanceUnavailable で Deny。
- 実際の送信・コミットの成否は、呼び出し側が SourceVaultIntegrityPublishOutcome で別に残す。
- V9: 外部で未確認 (Ungrounded) の内容を含むとき、理由 "UngroundedContent" で Warn にする (止めない)。<|"Text"|> の項目は、台帳のラベルのほかに文章そのものからも引き当てる。引き当ての手がかりは次の 2 つ。
  - 回答の SHA-256 が裏付けの記録にある。
  - 先頭に「外部で未確認」の印がある。

### SourceVaultIntegrityPublishBlockedQ[gate] → True | False
関所の結果を呼び出し側の止める・止めないに直す (2026-11-11)。
- Decision Deny なら True。
- Allow / Warn なら False。
- それ以外 (関所が無い・例外・Failure・None) は $SourceVaultIntegrityPublishFailClosed の値。呼び出し側は True なら公開しない。

### SourceVaultIntegrityPublishOutcome[activityId, outcome, opts] → Association | Failure
関所が通した意図 (ActivityId) の実結果 ("Succeeded" | "Failed") を Publish Activity (ExternalRefs IntentActivity) として残す (2026-11-11)。
- Failed の意図は PublishUnusable の公開に数えない。
- Options: "Channel"。
- 戻り値: `<|"Status"->"Recorded","ActivityId","IntentActivity","Outcome"|>`、または Failure["ProvenanceUnavailable"]。

## ModelManifest (Inc4)

### SourceVaultModelManifest[] → Association
LM Studio の機のモデル manifest (§7.1 ModelManifest)。読むもの:
- ~/.lmstudio の model-index-cache.json (モデル ID・形式・大きさ)
- gguf-metadata-cache.json (チャットテンプレートの digest)
- インストール先の package.json (版)
- http-server-config (待受)

ネットワークは使わず、トークン等の値は持たない。IdentityEvidence は Claimed (重みの全体ハッシュは未計算)。LM Studio の機でなければ "Status"->"NotApplicable"。

### SourceVaultModelManifestDiff[] → Association
manifest を、所有者が受け入れた基準 (AcceptBaseline["ModelManifest"]) と比べる。
`<|"NewModels","RemovedModels","TemplateChanged","RuntimeChanged","Advisories"|>`。Advisories は版が $SourceVaultModelRuntimeAdvisories に該当するもの。

### $SourceVaultModelRuntimeAdvisories
型: List, 初期値: {}
実行系の既知の脆弱性の表 `{<|"Runtime"->"LM Studio","Id"->"CVE-…","AffectedBelow"->"x.y.z"|"Versions"->{..}|>..}`。
所有者が原記録で確かめた範囲だけを書く (二次情報で「安全」と判定しない)。該当すると ModelManifest は Failing。代入は承認対象。

### $SourceVaultLMStudioRoot
型: String | Automatic, 初期値: Automatic (= ~/.lmstudio)
LM Studio の設定フォルダ。試験の seam。代入は承認対象。

### $SourceVaultLMStudioInstallDir
型: String | Automatic, 初期値: Automatic (= .internal/app-install-location.json の cwd)
LM Studio のインストール先。代入は承認対象。

## 健全性・影響範囲 (Inc5)

### SourceVaultKnowledgeHealth[] → Association
state.json の内容 (§11.2)。含まれるもの:
- 部品別の Health・ReasonCode・件数。
- 表 8.1 の指標: 来歴の充足率・未解決の重大 Finding・隔離対象と Unknown の利用・レビュー債務・鮮度・復旧時間。
- Kind × 出自の区分の分布。
- KHI (参考値。判定には使わない)。

### SourceVaultIntegrityBlastRadius[findingId] → Association
影響範囲 (§11.2)。含まれるもの:
- 対象から carry 辺で届く版の数。
- Kind 別の数。
- Instruction を含むか。
- 公開済みの版の数。
- 解決の状態。

Model / MCP には件数だけ。

### SourceVaultIntegrityFailClosedReadiness[] → Association
公開の関所と検索フィルタを fail-closed に切り替えてよいかを示す (§9.2、D-27)。
`<|"Ready","Reasons","IngestAgeSeconds","StateAgeSeconds","Advice"|>`。見る項目:
- 台帳の MAC 鍵。
- 取込の鮮度 (1 時間)。
- service の検証器の鮮度 (15 分)。
- 連鎖の状態。

### $SourceVaultIntegrityPublishFailClosed
型: Boolean, 初期値: False
True なら、索引が使えない・24 時間より古いとき、公開の関所はすべての公開を止める (§9.2 Inc5 の規則)。
呼び出し側 (メール・PackageCommit) も、関所が無い・例外・Failure を PublishBlockedQ で止める扱いにする (2026-11-11)。False の間は、Instruction 系を含む公開だけを止め、他は警告して通す。FailClosedReadiness[] が Ready になってから所有者が True にする。代入は承認対象。

### $SourceVaultIntegrityFilterFailClosed
型: Boolean, 初期値: False
True なら、検索フィルタが使えないとき RAG / AutoExec を Failure["IntegrityFilterUnavailable"] で止める (§9.2)。False の間 (Inc3〜4、Publish の関所と同じ段階的な規則) は記録して通す。代入は承認対象。

### $SourceVaultIntegrityBaselineAsAuthorization
型: Boolean, 初期値: True (移行期間)
True の間、モデルが書き得る群の LoadVerify は、所有者が受け入れた基準ハッシュ (AcceptBaseline["Instructions"]) も認可の代わりに認める。所有者が使うファイルに AuthorizeInstruction を出し終えたら False にする。代入は承認対象。

### $SourceVaultIntegrityReviewDebtLimit
型: Integer, 初期値: 10
ReviewDebt が Degraded になる未確認の上位版 (点数 0.5 以上) の件数 (7 日以上滞留)。

## service 実行口・設定

### SourceVaultIntegrityServiceTick[opts] → Association
service の 60 秒 hook (iSMSafeHook) から呼ぶ 1 つの実行口 (§3.2 / §11.3)。順に実行する。
1. 来歴 spool の取込 (SourceVaultProvIngestSpool、予算の 5 割)
2. 既存ログの adapter (SourceVaultProvIngestAdapters)
3. LLMCall の結合 (SourceVaultProvJoinLLMCalls)
4. InstructionDrift (10 分ごと)
5. Merkle 根つき checkpoint ("Periodic": 1,000 行か 1 時間)
6. feeds の同期と他機の照合 (SourceVaultProvSyncFeeds。checkpoint を書いたときか 300 秒ごと)
7. 検証器と state.json (Ingest・Heartbeat は毎回、Chain・Coverage は 1 時間ごと)
8. 補助の tick: 評判リスト (webguard、1 時間ごと、SourceVaultWebReputationUpdate["MaxSources"->1])、方針の提案 (SourceVaultPolicyProposalsRefresh、1 時間ごと)。どちらも弱結合。

Options: "BudgetSeconds" -> 20。Service / Owner のみ (表 11.1)。
SourceVault_provenance.wl 未ロードなら `<|"Status"->"ProvenanceUnavailable"|>`。
戻り値: `<|"Status"->"OK"|"CarriedOver"|"IngestFailed","Ingest","Adapters","Join","Drift","Verifiers","Checkpoint","Feeds","Seconds"|>`。

### $SourceVaultIntegrityStateMaxAge
型: Number, 初期値: 3600
state.json の許容年齢 (秒)。これより古ければ probe は Degraded / IntegrityStateStale を返す。

### $SourceVaultInstructionRoots
型: Association | Automatic, 初期値: Automatic
Instruction 系ファイルの探索 root の上書き `<|"Directives"->dir,"UserClaude"->dir,"Workflows"->dir,"TurnWiki"->dir,"AutoTrigger"->dir,"RunnerManifest"->dir|>`。試験の seam。代入は承認対象。
Automatic のときの探索先:
- ClaudeDirectives の root
- ~/.claude
- SourceVault_workflows
- Claude TurnWiki
- PrivateVault/autotrigger
- <CoreRoot>/runtime

### $SourceVaultIntegrityLoadVerifyEnforce
型: Boolean, 初期値: True
False のとき、LoadVerify はモデルが書き得る群でも拒否せず、警告の Finding だけを出す (緊急時の所有者の判断)。代入は承認対象。

### $SourceVaultIntegrityDriftIntervalSeconds
型: Number, 初期値: 600
InstructionDrift の周期 (秒)。

### $SourceVaultIntegrityVerifyIntervalSeconds
型: Number, 初期値: 3600
Chain / Coverage の周期 (秒)。

### $SourceVaultIntegrityInstructionPrivacyLevel
型: Number, 初期値: 0.3
Instruction Entity の既定 PL。Claude Directives の root は 0.0 と決まっているので、そちらは 0.0。

### $SourceVaultProvWebDocumentPrivacyLevel
型: Number, 初期値: 0.3
webingest が取り込んだ WebDocument の Entity の PL。

## Instruction 系 (基準ハッシュ・drift・LoadVerify)

### SourceVaultInstructionFiles[] → List[Association]
Instruction 系の現行ファイル `{<|"Path","Group"->"HumanEdited"|"ModelWritable","Class","Root"|>..}` (表 4.1 Instruction、§7.1)。
- HumanEdited: Claude Directives の CLAUDE.md・rules/*.md・skills/*/SKILL.md、~/.claude の CLAUDE.md・rules/*.md。
- ModelWritable: SourceVault_workflows の *.wl (archive を除く)、Claude TurnWiki の wiki/*.md・wiki/patterns/*.md・skills/*/SKILL.md、AutoTrigger 設定 (*.json)、runner manifest (manifest.resolved.wl)。

Class の値:
- HumanEdited: ClaudeMD / Rule / Skill / UserClaudeMD / UserRule
- ModelWritable: Workflow / TurnWikiPage / TurnWikiPattern / TurnWikiSkill / AutoTriggerConfig / RunnerManifest

### SourceVaultIntegrityInitializeInstructions[opts] → Association | Failure
基準ハッシュの初期化 (§6.3、1 回限り)。基準が無いときだけ AcceptBaseline["Instructions", opts] を呼ぶ。所有者 + 所有者 ticket。
- 既にあれば Failure["BaselineExists"]。
- Options: "Force" -> False (True で上書き)。残りは AcceptBaseline["Instructions"] の opts ("Ticket", "DryRun", "Paths", "Note") を渡す。

### SourceVaultIntegrityInstructionDrift[opts] → Association
Instruction 系の全ファイルを再ハッシュして基準と比較する (§7.1 InstructionDrift、service が 10 分ごと)。Owner / Service。Options: "Publish" -> True (Finding を出す)。
判定:
- モデルが書き得る群の記録の無い変更・追加: Failing / UnrecordedInstructionChange (IntegrityFinding を診断 spool へ)
- 手編集の群: Degraded / InstructionEditPendingReview
- 基準に無いファイルの消失 (読めないものを含む): Degraded / InstructionFileMissing
- 基準が無い: Degraded / InstructionBaselineMissing
- 変更なし: OK / InstructionsOK

戻り値: `<|"Health","ReasonCode","Counts"-><|Checked,Changed,New,Missing,Failing,Degraded|>,"Changed"->{<|RelPath,Group,Class,Change|>..},"ComputedAtUTC"|>`。

### SourceVaultIntegrityLoadVerify[path, purpose] → Association
読込側 (SourceVaultLoadWorkflow・TurnWiki の配布・runner manifest・Directives) が、読込の直前に呼ぶ照合 (§7.1 LoadVerify)。どの主体からも呼べる。
- purpose: "Workflow" | "TurnWikiRule" | "RunnerManifest" | "Directive" | "Instruction"。
- 戻り値: `<|"Decision"->"Allow"|"Warn"|"Deny","Reason","Group","Class","BlobId","Baseline","IndexState"|>`。
- モデルが書き得る群 (Workflow / TurnWikiRule): 基準に無い・不一致は Deny (Finding Failing / UnauthorizedInstructionLoad)。
- 手編集の群 (Directive) と runner manifest: Warn (Degraded の Finding)。読込は止めない。
- 基準が無ければ Warn / BaselineMissing (初期化前)。ただし厳格な設定 (LoadVerifyEnforce True かつ BaselineAsAuthorization False) では Deny (2026-11-11)。
- 認可 (AuthorizeInstruction) が Allow / Authorized になる条件:
  - 索引が使える。
  - Scope が読む機とプロファイルを含む。
  - 版がいま隔離中・Unknown・確定前でない。
- 移行期間の基準一致も、隔離中・Unknown の版なら止める。台帳がある機で索引が読めないときは Warn / BaselineMatchUnchecked。
- 引数の誤りは Deny / BadArguments。Instruction 系でないパスは Allow / NotInstruction。

## 検証器・state.json・probe

### SourceVaultIntegrityVerifiers[opts] → Association
service の検証器 (§7.1) を回し、LocalState/provenance/health/state.json に書く。Owner / Service。戻り値は state.json の内容。
Options: "Force" -> False (True で Chain / Coverage も即実行)。
- Provenance:
  - Coverage (直近 7 日):
    - Instruction を除く派生の率 < 0.9: Degraded。
    - 供給点を通った派生の率 < 0.9: Degraded。
    - SessionKey の無い LLM 派生 (供給点の外): Degraded。
    - Instruction / DerivedCode で < 0.99: Failing。
    - 活動が無ければ NotApplicable。
  - Chain: 前回 checkpoint 以降の連鎖と MAC (SourceVaultProvVerifyLedger)。
  - Ingest:
    - spool の滞留 > 1 時間: Degraded。
    - Corrupt、emit 失敗 (前回検査からの増分): Degraded。
- MonitorSelf = Heartbeat: tick の最終時刻・予算超過・再構築年齢。
- Instructions = 直近の InstructionDrift。
- Integrity / Models / Egress の決定的検証器 (Inc4)。
  - Integrity: EntityDrift・InjectionResidue・CitationIntegrity・GeneratedCodeHealth。
  - Models: ModelManifest・LMStudioMCPScope。
  - Egress: EgressPattern・PublishUnusable。
- KnowledgeHealth (Inc5): Contamination・FeedbackLoop・ReviewDebt・Indicators。
- Chain / Coverage は "Force" か $SourceVaultIntegrityVerifyIntervalSeconds ごと。Ingest / Heartbeat は毎回。

### SourceVaultIntegrityState[] → Association | Missing["NotFound"]
state.json を読んで返す (2 秒キャッシュ)。

### SourceVaultIntegrityProbe[component] → Association
SystemDoctor の probe。component は "Provenance" | "MonitorSelf" | "Instructions"。state.json を読むだけで (< 1 秒)、`<|"Health","ReasonCode","Message","Counts","FindingIds","StateAsOfUTC","StateAgeSeconds"|>` を返す。
- state.json が $SourceVaultIntegrityStateMaxAge より古い: Degraded / IntegrityStateStale。MonitorSelf は 15 分で Failing / ServiceTickStalled。
- state.json が無い: OK / NotApplicable (この機で service の検証器が動いていない)。

### SourceVaultIntegrityRegisterProbes[] → Association
Provenance と MonitorSelf の probe を SourceVaultDiagnosticsRegisterProbe に登録する。冪等。diagnostics 未ロードなら no-op。ロード時に 1 回呼ばれる。

### SourceVaultIntegrityFindings[opts] → List[Association]
health/findings.jsonl の直近の Finding (メタデータだけ: FindingId / Component / ReasonCode / Severity / Health / Targets / AtUTC)。Options: "Limit" -> 100。

## 記録点 (Inc2、§6.2)
どの主体からも呼べる。失敗は数えて元の処理を止めない。来歴モジュールが無ければ `<|"Status"->"Skipped","Reason"->"ProvenanceAbsent"|>`。

### SourceVaultProvRecordToolCall[name, args, result, opts] → Association
SourceVaultMCPCallTool の tools/call 1 回を Execute Activity として記録する。
- クライアント profile は接続経路 (主体の Channel) から取る。
- 引数は鍵付き digest (ToolArgs)。
- 結果の SHA-256 は、放出した PL < 0.5 のときだけ記録する。
- 結果に含めた Entity は、供給点の ServedToContext の ActivityId ("ServedActivityIds") で結ぶ。
- Options:
  - "CallId" -> None (SourceVaultRecordMCPCall の CallId。ExternalRefs に持ち、mcp_calls adapter はそれを見て補完専用になる)
  - "ServedActivityIds" -> {}
  - "MaxReleasedPrivacy" -> Null
  - "Decision" -> Automatic (Automatic は Permit、結果が isError なら Error)

### SourceVaultProvRecordWebIngest[doc, opts] → Association
SourceVaultWebFetch が取り込んだ WebDocument を Ingest Activity + PrimarySource Entity として記録する。
- URL は鍵付き digest (ExternalRef、鍵が無ければ Null)。
- 取得時刻と pre-scan 結果 (SourceVaultSecurityPreScan があれば。"CleanText" を渡したとき) を記録する。
- Taints は ext:web。Actor は主体から取る。
- ContentHash (SourceVaultCommitBlob の sha256 = CanonVersion 1 の Bytes) を BlobId に写す。
- Options: "Guard" (関所の判定), "CleanText"。

### SourceVaultProvRecordNBRead[path, pl] → Association
NBAccess の読取 (評価スコープ透かしと同じ場所) が読んだファイルを ServedToContext (Role Quote) として記録する (供給点)。
Kind は OwnerAuthored (所有者のファイルと見なす。外部由来の区別は Inc3)。50 MB 超は内容を digest せず Partial。

### SourceVaultProvRecordTurnWikiMaintain[traces, files, opts] → Association
TurnWiki Maintain (raw トレース → wiki パターン) を LLMGenerate として記録し、wiki パターンの Evidence に元トレースの EntityId を返す (T-H4)。
戻り値: `<|"Status","ActivityId","TraceEntities"-><|TraceId->EntityId|>,"PatternEntities"-><|path->EntityId|>,"Evidence"->{EntityId..}|>`。

## backfill (§6.3)

### SourceVaultIntegrityBackfill[opts] → Association | Failure
既存の記録から台帳を一度だけ初期化する (所有者専用)。
- adapter で取り込める系統 (mcp_calls / web_access / reference_events / mcp_deposits) は、読取位置を先頭に戻して再取込する (EventId は行の digest なので重複しない)。
- 無い系統は次を記録する。いずれも "Backfilled"->True・"Completeness"->"Partial"・OriginClass Unknown。Coverage の分母から除外される。
  - DerivedArtifact snapshot (SourceVaultDerivedArtifactList)
  - PromptRunRecord (prompt-runs.jsonl)
  - KG (SourceVaultKGList / KGLoad)
- 済みの系統は health/backfill.json に残し、再実行しない。本番データでは所有者が判断して実行する。
- 失敗: Failure["ProvenanceUnavailable"] / Failure["ProvLocalStateUnresolved"]。
- Options: "Adapters" -> All (All | {name..} | None), "DerivedArtifacts" -> True, "PromptRuns" -> True, "KnowledgeGraphs" -> True, "BudgetSeconds" -> 60, "MaxItems" -> 5000, "Force" -> False (True で再実行)。