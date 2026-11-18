(* ::Package:: *)

(* ============================================================
   SourceVault_integrity.wl -- 知識ネットワーク健全性監視 (03 SystemDoctor 拡張仕様 v0.4) の
   所有者専用関数 (§11.5) の先行登録と、方針 / 出口 API の承認 head 登録 (02 リスク評価 v1.2 §7.1 A-4)、
   Inc2 (第 4 週、2026-11-10) の記録点・Instruction の基準ハッシュ・検証器 (state.json)・probe・backfill

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_integrity.wl"]]

   位置づけ:
     第 2 週 (2026-11-09): 03 v0.4 §11.5 の関数名を先に公開し (本体は Failure["NotImplemented"])、NBAccess の承認 head に登録。
     第 3 週 (2026-11-09、Inc1a): SourceVaultIntegrityServiceTick を本体化 (Ingest → adapter → 日次 checkpoint)。
     第 4 週 (2026-11-10、Inc2): 03 v0.4 §13.1 Inc2「記録点を 5 つに絞る」。
       - 記録点: SourceVaultMCPCallTool の Execute (SourceVaultProvRecordToolCall)、webingest の Ingest (SourceVaultProvRecordWebIngest)、
         NBAccess の読取 (SourceVaultProvRecordNBRead、ServedToContext)、TurnWiki Maintain (SourceVaultProvRecordTurnWikiMaintain)。
         供給点 (SourceVaultProvServed) と LLMCall の SessionKey・結合 (SourceVaultProvJoinLLMCalls) は SourceVault_provenance.wl。
       - Instruction 系の基準ハッシュ 2 群 (§6.2 / §7.1 Instructions): 手編集が正常な群 (Claude Directives・rules・skills・CLAUDE.md・
         ~/.claude) と、モデルが書き得る群 (SourceVault_workflows の .wl・TurnWiki の wiki と skill・AutoTrigger 設定・runner manifest)。
         SourceVaultIntegrityInitializeInstructions / AcceptBaseline["Instructions"] (所有者 + 所有者 ticket) が現行ファイルを
         Instruction Entity として登録し、health/instruction-baseline.json に基準を置く。InstructionDrift (service、10 分) が再ハッシュし、
         モデルが書き得る群の記録の無い変更は Failing、手編集の群は Degraded。LoadVerify は読込側 (SourceVaultLoadWorkflow・TurnWiki の
         配布・runner manifest・Directives) が読込の直前に呼び、モデルが書き得る群は不一致・認可なしを拒否、Directives は警告して続行。
         Inc3 の AuthorizeInstruction (ticket つきの認可) が入るまで、所有者が受け入れた基準ハッシュを認可の代用とする。
       - 検証器 (service): Provenance = Coverage / Chain / Ingest、MonitorSelf = Heartbeat、Instructions = InstructionDrift を
         LocalState/provenance/health/state.json にまとめ、FE の probe (SourceVaultIntegrityProbe) は state.json を読むだけ (< 1 秒)。
         Failing と High の Finding は診断 spool に EventClass IntegrityFinding・Producer integrity で書く (§9.1、Issue は producer integrity)。
       - backfill (§6.3): SourceVaultIntegrityBackfill (所有者専用、一度限り。adapter の offset を先頭に戻し、DerivedArtifact snapshot・
         PromptRunRecord・KG を Backfilled / Partial で台帳に入れる。Coverage の分母から除外)。
     Inc3 (2026-11-10): 03 v0.4 §13.1 Inc3「ラベルと認可の正準仕様」。§11.5 の所有者操作 (AuthorizeInstruction / RevokeAuthorization /
       Quarantine / Release / ResolveFinding / RecordOwnerReview / RegisterVerifier、AcceptBaseline["SecurityProfile"]) を台帳のラベルの記録
       (ticket を同梱、SourceVault_provenance.wl が索引で照合) として本体化。実効ラベル (SourceVaultIntegrityLabel)、検索フィルタ
       (SourceVaultIntegrityRetrievalFilter、§9.2)、LoadVerify の認可、Instructions 部品 (命令使用の認可・Registry) と Policy 部品 (SecurityProfile)。
     "SourceVault*" の一括信頼 ($NBTrustedPackageHeads) より $NBApprovalHeads / $NBDenyHeads の明示登録が先に評価される
     (NBAccess.wl の usage) ので、登録すれば NeedsApproval になる。NBAccess 側の既定表にも同じ名前を置いてある。

   service-loadable: FrontEnd / Notebook / NBAccess 非依存 (NBAccess・diagnostics・ClaudeDirectives・webingest・KG へは弱結合)。
   ============================================================ *)

BeginPackage["SourceVault`"]

$SourceVaultApprovalHeads::usage =
  "$SourceVaultApprovalHeads は、SourceVault が NBAccess の承認 head ($NBApprovalHeads) に登録する公開関数名のリスト。\n" <>
  "02 v1.2 §7.1 A-4 の方針・出口 API (SourceVaultMailSend / SourceVaultWebGuardResolveRequest / Set*PrivacyLevel 系 /\n" <>
  "SourceVaultResetEvaluationPrivacy / SourceVaultExportKeyBundle / SourceVaultDecryptRecord / SourceVaultMCPRegisterTools)、\n" <>
  "03 v0.4 §11.5 の所有者専用関数、所有者 ticket の発行 (SourceVaultOwnerTicketDialog / Mint)、SecurityProfile 検査の登録、\n" <>
  "来歴台帳の状態を変える関数 (Inc1a / Inc2)。提案コードからこれらを呼ぶと NBValidateHeldExpr が NeedsApproval を返す (\"SourceVault*\" の一括信頼より優先)。";

$SourceVaultApprovalSetSymbols::usage =
  "$SourceVaultApprovalSetSymbols は、SourceVault が NBAccess の $NBApprovalSetSymbols に登録する方針変数名のリスト\n" <>
  "(代入が Module 内でも承認対象になる): 主体 $SourceVaultPrincipal、$SourceVaultSecurityProfile、所有者 ticket の鍵と店、\n" <>
  "AutoTrigger permit の鍵と強制、要約 LLM の送り先、Web 関所の切替、来歴の鍵と spool、Inc2 の Instruction 群の root と LoadVerify の強制。";

SourceVaultRegisterApprovalHeadsWithNBAccess::usage =
  "SourceVaultRegisterApprovalHeadsWithNBAccess[] は $SourceVaultApprovalHeads と $SourceVaultApprovalSetSymbols を NBAccess に\n" <>
  "登録する (冪等、NBAccess 未ロードなら <|\"Status\" -> \"NBAccessAbsent\"|>)。ロード時に 1 回呼ばれる。NBAccess を後から\n" <>
  "ロードした場合は NBAccess の既定表が同じ名前を持つので、再登録は不要 (呼んでもよい)。";

(* ---- 03 v0.4 §11.5 所有者専用 (ticket 必須・承認 head)。AcceptBaseline["Instructions"] は Inc2、他は Inc3 (2026-11-10) で本体化。
   共通: 主体は所有者 (OwnerFE / OwnerCode)、ticket は SourceVaultOwnerTicketDialog (FE、発行元 OwnerFE) か development profile の開発用の鍵だけ。
   "Ticket" 無しで呼ぶと実行せず <|"Status" -> "ReviewRequired", "TicketAction", "Bind", "BindDisplay"|> を返す (Dialog に Display と Bind を渡す)。
   Model / MCP / Service からの呼び出しは拒否し、Registry に試みを記録する。記録は台帳のラベルの記録 (ticket を同梱) で、service が取り込むと効く。 ---- *)
SourceVaultIntegrityRecordOwnerReview::usage =
  "SourceVaultIntegrityRecordOwnerReview[ref, scope, note, opts] は所有者の確認を OwnerReviewed の検証主張 (ProvVerification、Kind Human) として記録する (03 v0.4 §5.3 / §11.5)。\n" <>
  "出自・隔離・認可は変えない (主張であって正しさの証明でも命令採用の認可でもない)。所有者 ticket (Action \"RecordOwnerReview\") 必須・NBAccess 承認 head。";
SourceVaultIntegrityAuthorizeInstruction::usage =
  "SourceVaultIntegrityAuthorizeInstruction[ref, purpose, opts] は版 (BlobId) を用途の命令として採用する認可 (ProvAuthorization、03 v0.4 §5.4 / §11.5)。\n" <>
  "ref: EntityId / BlobId / LogicalRef / Instruction 系のファイルのパス。purpose: \"Directive\" | \"Workflow\" | \"TurnWikiRule\" | \"SystemPrompt\" | \"SeriesSpec\" | \"ProcessDelta\"。\n" <>
  "隔離中・OriginClass Unknown・確定前 (Pending)・記録の無い版には出さない (Failure[\"NotUsable\"])。\"RequiredClaims\" -> {property..} は登録済みの決定的検証器の Pass で満たす。\n" <>
  "ExternalDerived の版は確認の表示に外部由来と出す。認可は BlobId と用途に束縛され、内容が 1 バイトでも変われば LoadVerify が拒否する。\n" <>
  "opts: \"Ticket\" (Action \"AuthorizeInstruction\"), \"RequiredClaims\", \"ExpiresAtUTC\", \"Note\",\n" <>
  "\"Scope\" -> <|\"Machines\" -> \"All\" | {machineTag..}, \"Profiles\" -> \"All\" | {\"production\" | \"development\"..}|> (既定は両方 All 相当。ほかの鍵・空の一覧・未知のプロファイルは Failure[\"BadScope\"])。\n" <>
  "LoadVerify は読む機 (SourceVaultMachineTag[]、大小文字を区別しない) と $SourceVaultSecurityProfile が Scope に入る認可だけを数え、索引が使えない (再構築中・連鎖の破損を含む) とき・\n" <>
  "版がいま隔離中・Unknown・確定前のときは認可を使わない (2026-11-11)。所有者 ticket 必須・NBAccess 承認 head。";
SourceVaultIntegrityRevokeAuthorization::usage =
  "SourceVaultIntegrityRevokeAuthorization[authId, reason, opts] は認可の取消し (ProvRevocation、03 v0.4 §11.5)。所有者 ticket (Action \"RevokeAuthorization\") 必須。";
SourceVaultIntegrityQuarantine::usage =
  "SourceVaultIntegrityQuarantine[ref, reason, opts] は版を明示的に隔離する (Severity High の ProvFinding、Kind OwnerQuarantine、03 v0.4 §5.5 / §9.2 / §11.5)。\n" <>
  "ref は EntityId / BlobId (同じ内容の版すべて) / LogicalRef / ファイル。carry 辺の子孫も隔離される。ファイルは残す。所有者 ticket (Action \"Quarantine\") 必須。";
SourceVaultIntegrityRelease::usage =
  "SourceVaultIntegrityRelease[ref, findingId, ground, opts] は版をその Finding による隔離から解除する (ProvRelease、03 v0.4 §5.5 / §11.5)。解除した版を通る子孫も外れる。\n" <>
  "ground: <|\"Kind\" -> \"IndependentOfTaint\" (主張単位で汚染部分に依存しない確認、\"Scope\" 必須) | \"Sanitizer\" (適用範囲の明確な決定的 sanitizer、\"Sanitizer\" 必須) |\n" <>
  "\"Regenerated\" (汚染の無い入力からの新しい版)|>。所有者 ticket (Action \"Release\") 必須。";
SourceVaultIntegrityResolveFinding::usage =
  "SourceVaultIntegrityResolveFinding[fid, resolution, opts] は Finding を解決する (ProvFindingResolution、03 v0.4 §4.6 / §9.3 / §11.5)。resolution:\n" <>
  "<|\"Kind\" -> \"FalsePositive\", \"Reason\"|> (撤回: 子孫の隔離もすべて外れる) | <|\"Kind\" -> \"Remediated\", \"Replacements\" -> {訂正版の EntityId..}, \"OpenPublications\" -> 0|>\n" <>
  "(旧版と子孫は隔離のまま。公開済みの訂正が残る間 (OpenPublications > 0) はできない) | <|\"Kind\" -> \"AcceptedRisk\", \"Scope\" -> <|\"Purposes\" -> {\"HumanSearch\"..}|>,\n" <>
  "\"ExpiresAtUTC\", \"Reason\"|> (範囲の用途で期限まで外れる。RAG / AutoExec / Publish / Instruction を含めるには \"ConfirmAutomatic\" -> True)。所有者 ticket (Action \"ResolveFinding\") 必須。";
SourceVaultIntegrityAcceptBaseline::usage =
  "SourceVaultIntegrityAcceptBaseline[component, opts] は基準を受け入れる (03 v0.4 §11.5)。Inc2 (2026-11-10) で \"Instructions\" を本体化:\n" <>
  "Instruction 系の現行ファイル (SourceVaultInstructionFiles[]) を再ハッシュし、基準 (LocalState/provenance/health/instruction-baseline.json) との差分\n" <>
  "(変更・追加・削除) を Instruction Entity (Kind Instruction、VersionOf 前の版) と HumanEdit Activity として台帳に記録し、基準を更新する。\n" <>
  "所有者 (OwnerFE / OwnerCode) + 所有者 ticket (\"Ticket\" -> SourceVaultOwnerTicketMint / Dialog の票、Action \"AcceptBaseline\"、Bind = <|\"Display\" -> 変更一覧の digest,\n" <>
  "\"Component\" -> \"Instructions\" の digest|>、digest は SourceVaultOwnerTicketDigest) が必須。ticket 無し・\"DryRun\" -> True では変更一覧と Bind の digest を返すだけ (\"Status\" -> \"ReviewRequired\")。\n" <>
  "opts: \"Paths\" -> All | {path..} (受け入れる範囲), \"Note\"。モデルが書き得る群では、$SourceVaultIntegrityBaselineAsAuthorization が True の間 (移行期間) この受入も認可の代わりになる。\n" <>
  "Inc3 (2026-11-10): \"SecurityProfile\" は Policy 部品の基準 (SourceVaultIntegrityPolicySnapshot[] の項目ごとの digest、カーネルの役割 FE / Service ごと、\n" <>
  "health/policy-baseline-<role>.json) を受け入れる (Action \"AcceptBaseline\"、Bind \"Component\" -> SecurityProfile の digest)。\n" <>
  "Inc4 (2026-11-10): \"ModelManifest\" は LM Studio のモデル・テンプレート・版の基準 (health/model-manifest-baseline.json)。系列は未実装 (Inc8)。\n" <>
  "2026-11-11: \"SecurityProfile\" に \"Role\" -> \"Service\" を付けて FE から呼ぶと、service の基準 (health/policy-baseline-service.json) を受け入れる。\n" <>
  "service は Policy の検査のたびに自分の設定の要約 (項目ごとの digest だけ、値は含まない) を health/policy-snapshot-service.json に書くので、それを読み、\n" <>
  "形式・digest と項目の一致・新しさ (\"MaxSnapshotAgeSeconds\" 既定 900) を確かめてから所有者 ticket で受け入れる (Bind に \"Role\" の digest が加わる)。\n" <>
  "要約が無い・壊れている・古いときは Failure[\"ServiceSnapshotMissing\" | \"ServiceSnapshotInvalid\" | \"ServiceSnapshotStale\"]。\"Role\" は Automatic (このカーネルの役割) が既定。\n" <>
  "カーネルの役割は service の目印 ($SourceVaultDiagnosticsCanonicalWriter、SourceVaultServiceMain が立てる) があれば Service、ノートブックが使えれば FE、\n" <>
  "どちらでもなければ Other (並列の子カーネル・台本・起動途中の FE) で、Other では Policy を検査せず要約も書かず、基準も受け入れない。";
SourceVaultIntegrityRegisterVerifier::usage =
  "SourceVaultIntegrityRegisterVerifier[name, spec, opts] は検証器の登録・変更 (ProvVerifierRegistration、03 v0.4 §5.3 / §11.5 / 表 11.1)。spec = <|\"Kind\" -> \"Deterministic\" | \"Model\",\n" <>
  "\"Properties\" -> {..}, \"Implementation\" -> <|\"Package\", \"Function\", \"Digest\"|>, \"Applies\", \"Period\", \"Budget\"|>。検証主張 (ProvVerification) は登録表にある決定的検証器のものだけが\n" <>
  "認可の RequiredClaims に効く。モデル・MCP クライアントからの登録は拒否して Registry に記録する。所有者 ticket (Action \"RegisterVerifier\") 必須。";
SourceVaultRederiveApprove::usage =
  "SourceVaultRederiveApprove[planId] は作り直しの計画を承認し、計画のハッシュ付きでワークフロー層へ渡す (03 v0.4 §11.5 / 14 章)。未実装 (Inc7): Failure[\"NotImplemented\"]。";

(* ---- Inc3 (2026-11-10): ラベルの読取・検索フィルタ・Policy ---- *)
SourceVaultIntegrityLabel::usage =
  "SourceVaultIntegrityLabel[ref] は版の実効ラベル <|\"PrivacyLevel\", \"Origin\" (Contributors / Taints / OriginClass、5.2 節の合成後), \"Completeness\", \"Claims\",\n" <>
  "\"Quarantine\" -> <|\"Quarantined\", \"FindingIds\", \"Findings\"|>, \"Authorizations\", \"Usability\", \"ObservedSeq\"|> を返す (03 v0.4 §11.2)。ref は EntityId / BlobId / LogicalRef (最新の版)。\n" <>
  "Model / MCP には PL が 0.5 以上の版の BlobId・Origin の Taints・Claims を伏せる。索引が使えなければ Missing[\"IndexUnavailable\"]。\n" <>
  "文書 12 の V9 (2026-11-13): \"Grounding\" -> \"Grounded\" | \"Partial\" | \"Ungrounded\" | \"NotNeeded\" | \"Unknown\" (裏付けの検査の結果。回答の版に束縛)、\n" <>
  "\"GroundingOwn\" (その版自身の判定)、\"GroundingInherited\" (Ungrounded の版から carry 辺で届いた)、\"UngroundedFrom\" (起点の版)。\n" <>
  "Ungrounded は Usability を変えない: 検索では下位に回して印を付け、公開では警告する。所有者の確認 (RecordOwnerReview) で外れる。";
SourceVaultIntegrityRetrievalFilter::usage =
  "SourceVaultIntegrityRetrievalFilter[candidates, opts] は検索・RAG の候補から利用できない版を除く (03 v0.4 §9.2 / §11.2)。opts: \"Purpose\" -> \"RAG\" | \"AutoExec\" |\n" <>
  "\"HumanSearch\" | \"AuditView\" (既定 Automatic: Model / MCP / 未束縛は RAG、Service は AutoExec、所有者は HumanSearch。Model / MCP は指定しても RAG に固定)、\n" <>
  "\"SupplyPoint\" (記録用の名前), \"Report\" -> False。候補は EntityId / BlobId / LogicalRef (ObjectURI・URI・SourceId 等) で usability.wxf の表に引き当てる。\n" <>
  "RAG / AutoExec: 隔離中 (その用途の AcceptedRisk の外) と派生物の Unknown を除外し件数を記録。HumanSearch: 除かず \"IntegrityUsability\" -> \"Quarantined\" の印を付ける。\n" <>
  "AuditView: OwnerFE だけ (他は拒否して Registry に記録)。隔離中を含めて印を付け、用途・件数を記録し、結果は自動の文脈に渡せない印 \"IntegrityPurpose\" -> \"AuditView\" を持つ。\n" <>
  "記録の無い候補は NotRecorded として通す (一次資料の検索を止めない)。フィルタが使えない (索引が無い・再構築中・連鎖の破損) とき、\n" <>
  "$SourceVaultIntegrityFilterFailClosed が True なら RAG / AutoExec は Failure[\"IntegrityFilterUnavailable\"]、False (Inc3〜4 の既定) なら記録して通す。\n" <>
  "\"Report\" -> True で <|\"Results\", \"Purpose\", \"Filter\" -> \"OK\" | \"Unavailable\", \"Excluded\", \"Marked\", \"NotRecorded\", \"Grounding\"|> を返す。\n" <>
  "文書 12 の V9: 外部で未確認 (Ungrounded) の版は除かず、\"IntegrityGrounding\" -> \"Ungrounded\" の印を付けて結果の末尾に回す (AuditView では並びを変えない)。\n" <>
  "一部だけ確認できた版には \"IntegrityGrounding\" -> \"Partial\" の印だけを付ける。件数は \"Grounding\" -> <|\"Ungrounded\", \"Partial\"|>。";
SourceVaultIntegrityPolicySnapshot::usage =
  "SourceVaultIntegrityPolicySnapshot[] は Policy 部品 (03 v0.4 §7.1 SecurityProfile) が見る設定の項目ごとの digest <|\"Role\" -> \"FE\" | \"Service\", \"Items\" -> <|name -> digest|>, \"Digest\"|> を返す。\n" <>
  "項目: SecurityProfile・WebGuard の有効・ConservativePrivacyDefault・承認 head と方針変数・信頼 head・tool loop の許可一覧・MCP の無効ツール・AccessibleDirs・\n" <>
  "integrity / provenance の設定・来歴の鍵の KeyId・検証器の登録表。値そのものは返さない。基準は SourceVaultIntegrityAcceptBaseline[\"SecurityProfile\"]。";
(* ---- Inc4 (2026-11-10): 決定的検証器・公開の関所・モデル manifest ---- *)
SourceVaultIntegrityPublishGate::usage =
  "SourceVaultIntegrityPublishGate[items, destination, opts] は公開 (メール送信・コミット・アップロード) の直前の関所 (03 v0.4 §9.2、6.2 節の Inc 4 の記録点)。\n" <>
  "items: ファイルのパス / <|\"Path\"|> / <|\"Text\"|> / <|\"EntityId\"|> / <|\"BlobId\"|> / <|\"LogicalRef\"|>。隔離中 (用途 Publish の AcceptedRisk の外) か派生物の Unknown の版、\n" <>
  "確定して Usable になっていない名指しの版 (NotCommitted) を含めば \"Decision\" -> \"Deny\"。索引が使えない (再構築中 IndexRebuilding・連鎖の破損 LedgerChainDamaged を含む)・\n" <>
  "24 時間より古いときは \"Warn\" (Inc1〜Inc4 の段階的な規則、記録して通す。$SourceVaultIntegrityPublishFailClosed なら Deny)、それ以外は \"Allow\"。\n" <>
  "公開の意図を Publish Activity (Outcome Approved / Blocked、入力は記録のある版、宛先は鍵付き digest) に残し、書けなければ ProvenanceUnavailable で Deny。\n" <>
  "実際の送信・コミットの成否は呼び出し側が SourceVaultIntegrityPublishOutcome[ActivityId, \"Succeeded\" | \"Failed\"] で別に残す。opts: \"Channel\", \"Record\" -> True。\n" <>
  "戻り値 <|\"Decision\", \"Reasons\", \"Items\" -> {<|Index, Verdict, FindingIds|>..}, \"Recorded\", \"ActivityId\", \"Outcome\", \"IndexState\"|>。\n" <>
  "呼び出し側は SourceVaultIntegrityPublishBlockedQ[戻り値] が True なら公開しない (関所が無い・例外・Failure も fail-closed なら止める)。\n" <>
  "文書 12 の V9: 外部で未確認 (Ungrounded) の内容を含むとき、理由 \"UngroundedContent\" で \"Warn\" にする (止めない)。台帳のラベルのほか、\n" <>
  "<|\"Text\"|> の項目は文章そのもの (回答の SHA-256 が裏付けの記録にある・先頭に「外部で未確認」の印がある) からも引き当てる。";
SourceVaultIntegrityPublishBlockedQ::usage =
  "SourceVaultIntegrityPublishBlockedQ[gate] は公開の関所の結果を呼び出し側の止める・止めないに直す (2026-11-11): Decision Deny なら True、Allow / Warn なら False、\n" <>
  "それ以外 (関所が無い・例外・Failure・None) は $SourceVaultIntegrityPublishFailClosed の値 (True なら止める)。";
SourceVaultIntegrityPublishOutcome::usage =
  "SourceVaultIntegrityPublishOutcome[activityId, outcome, opts] は公開の関所が通した意図 (ActivityId) の実際の結果 (\"Succeeded\" | \"Failed\") を\n" <>
  "Publish Activity (ExternalRefs IntentActivity) として残す (2026-11-11)。Failed の意図は PublishUnusable の公開に数えない (所有者・service の記録だけ)。\n" <>
  "opts: \"Channel\"。戻り値 <|\"Status\" -> \"Recorded\", \"ActivityId\", \"IntentActivity\", \"Outcome\"|> / 記録できなければ Failure[\"ProvenanceUnavailable\"]。";
SourceVaultModelManifest::usage =
  "SourceVaultModelManifest[] は LM Studio の機のモデル manifest (03 v0.4 §7.1 ModelManifest): ~/.lmstudio の model-index-cache.json (モデル ID・形式・大きさ)・\n" <>
  "gguf-metadata-cache.json (チャットテンプレートの digest)・インストール先の package.json (版)・http-server-config (待受) を読む。ネットワークは使わず、トークン等の値は持たない。\n" <>
  "IdentityEvidence は Claimed (重みの全体ハッシュは未計算)。LM Studio の機でなければ \"Status\" -> \"NotApplicable\"。";
SourceVaultModelManifestDiff::usage =
  "SourceVaultModelManifestDiff[] は manifest を所有者が受け入れた基準 (SourceVaultIntegrityAcceptBaseline[\"ModelManifest\"]) と比べる:\n" <>
  "<|\"NewModels\", \"RemovedModels\", \"TemplateChanged\", \"RuntimeChanged\", \"Advisories\" (版が $SourceVaultModelRuntimeAdvisories に該当)|>。";
$SourceVaultModelRuntimeAdvisories::usage =
  "$SourceVaultModelRuntimeAdvisories は実行系の既知の脆弱性の表 {<|\"Runtime\" -> \"LM Studio\", \"Id\" -> \"CVE-…\", \"AffectedBelow\" -> \"x.y.z\" | \"Versions\" -> {..}|>..} (既定 {})。\n" <>
  "所有者が原記録で確かめた範囲だけを書く (二次情報で「安全」と判定しない)。該当すると ModelManifest は Failing。代入は NBAccess の承認対象。";
$SourceVaultLMStudioRoot::usage = "$SourceVaultLMStudioRoot は LM Studio の設定フォルダ (既定 Automatic = ~/.lmstudio)。試験の seam。代入は承認対象。";
$SourceVaultLMStudioInstallDir::usage = "$SourceVaultLMStudioInstallDir は LM Studio のインストール先 (既定 Automatic = .internal/app-install-location.json の cwd)。代入は承認対象。";

(* ---- Inc5 (2026-11-10): 健全性・影響範囲・fail-closed の準備 ---- *)
SourceVaultKnowledgeHealth::usage =
  "SourceVaultKnowledgeHealth[] は state.json の内容 (03 v0.4 §11.2): 部品別の Health・ReasonCode・件数と、表 8.1 の指標 (来歴の充足率・未解決の重大 Finding・\n" <>
  "隔離対象と Unknown の利用・レビュー債務・鮮度・復旧時間)、Kind × 出自の区分の分布、KHI (参考値。判定には使わない)。";
SourceVaultIntegrityBlastRadius::usage =
  "SourceVaultIntegrityBlastRadius[findingId] は影響範囲 (03 v0.4 §11.2): 対象から carry 辺で届く版の数・Kind 別・Instruction を含むか・公開済みの版の数・解決の状態。\n" <>
  "Model / MCP には件数だけ。";
SourceVaultIntegrityFailClosedReadiness::usage =
  "SourceVaultIntegrityFailClosedReadiness[] は公開の関所と検索フィルタを fail-closed に切り替えてよいかを示す (03 v0.4 §9.2、D-27「索引の鮮度が運用で確かめられてから」):\n" <>
  "台帳の MAC 鍵・取込の鮮度 (1 時間)・service の検証器の鮮度 (15 分)・連鎖の状態。<|\"Ready\", \"Reasons\", \"IngestAgeSeconds\", \"StateAgeSeconds\", \"Advice\"|>。";
$SourceVaultIntegrityPublishFailClosed::usage =
  "$SourceVaultIntegrityPublishFailClosed (既定 False) が True なら、索引が使えない・24 時間より古いとき公開の関所はすべての公開を止める (03 v0.4 §9.2 の Inc5 の規則)。\n" <>
  "呼び出し側 (メール・PackageCommit) も、関所が無い・例外・Failure を SourceVaultIntegrityPublishBlockedQ で止める扱いにする (2026-11-11)。\n" <>
  "False の間は Instruction 系を含む公開だけを止め、他は警告して通す。SourceVaultIntegrityFailClosedReadiness[] が Ready になってから所有者が True にする。代入は承認対象。";
SourceVaultIntegrityOwnerAction::usage =
  "SourceVaultIntegrityOwnerAction[call] は所有者操作 (03 v0.4 §11.5、例: SourceVaultIntegrityResolveFinding[fid, <|...|>]) を FE から 1 回で行う:\n" <>
  "主体を OwnerCode にして call を評価し、確認 (ReviewRequired) が返れば SourceVaultOwnerTicketDialog に表示文と Bind を渡し、承認された ticket を付けて call をもう一度評価する。\n" <>
  "View のボタンが置く式テンプレートが使う。NBAccess の承認 head (提案コードからは呼べない)。HoldFirst。";
$SourceVaultIntegrityReviewDebtLimit::usage = "$SourceVaultIntegrityReviewDebtLimit は ReviewDebt が Degraded になる未確認の上位版 (点数 0.5 以上) の件数 (既定 10、7 日以上滞留)。";

$SourceVaultIntegrityFilterFailClosed::usage =
  "$SourceVaultIntegrityFilterFailClosed (既定 False) が True なら、検索フィルタが使えないとき RAG / AutoExec を Failure[\"IntegrityFilterUnavailable\"] で止める (03 v0.4 §9.2)。\n" <>
  "False の間 (Inc3〜Inc4、Publish の関所と同じ段階的な規則) は記録して通す。代入は NBAccess の承認対象。";
$SourceVaultIntegrityBaselineAsAuthorization::usage =
  "$SourceVaultIntegrityBaselineAsAuthorization (既定 True、移行期間) が True の間、モデルが書き得る群の LoadVerify は所有者が受け入れた基準ハッシュ\n" <>
  "(AcceptBaseline[\"Instructions\"]) も認可の代わりに認める。所有者が使うファイルに AuthorizeInstruction を出し終えたら False にする。代入は承認対象。";

(* ---- 03 v0.4 §3.2 / §11.3 service の実行口 (Inc1a で本体化、Inc2 で結合・検証器・state.json を追加) ---- *)
SourceVaultIntegrityServiceTick::usage =
  "SourceVaultIntegrityServiceTick[opts] は service の 60 秒 hook (iSMSafeHook) から呼ぶ 1 つの実行口 (03 v0.4 §3.2 / §11.3)。\n" <>
  "来歴 spool の取込 (SourceVaultProvIngestSpool、予算の 5 割) → 既存ログの adapter (SourceVaultProvIngestAdapters) → LLMCall の結合\n" <>
  "(SourceVaultProvJoinLLMCalls、Inc2) → InstructionDrift (10 分ごと) → Merkle 根つき checkpoint (\"Periodic\": 1,000 行か 1 時間、Inc1b) →\n" <>
  "feeds の同期と他機の照合 (SourceVaultProvSyncFeeds、checkpoint を書いたときか 300 秒ごと、Inc1b) → 検証器と state.json (SourceVaultIntegrityVerifiers:\n" <>
  "Ingest は毎回、Chain / Coverage は 1 時間ごと、Heartbeat は毎回) を \"BudgetSeconds\" (既定 20) 以内で順に回す。\n" <>
  "Service / Owner のみ (表 11.1)。SourceVault_provenance.wl 未ロードなら <|\"Status\" -> \"ProvenanceUnavailable\"|>。\n" <>
  "戻り値 <|\"Status\" -> \"OK\" | \"CarriedOver\" | \"IngestFailed\", \"Ingest\", \"Adapters\", \"Join\", \"Drift\", \"Verifiers\", \"Checkpoint\", \"Feeds\", \"Seconds\"|>。";

(* ---- Inc2 (2026-11-10): 設定 ---- *)
$SourceVaultIntegrityStateMaxAge::usage =
  "$SourceVaultIntegrityStateMaxAge は state.json の許容年齢 (秒、既定 3600)。これより古ければ probe は自分の判定でなく Degraded / IntegrityStateStale を返す (03 v0.4 7 章)。";
$SourceVaultInstructionRoots::usage =
  "$SourceVaultInstructionRoots は Instruction 系ファイルの探索 root の上書き <|\"Directives\" -> dir, \"UserClaude\" -> dir, \"Workflows\" -> dir, \"TurnWiki\" -> dir,\n" <>
  "\"AutoTrigger\" -> dir, \"RunnerManifest\" -> dir|> (既定 Automatic: ClaudeDirectives の root / ~/.claude / SourceVault_workflows / Claude TurnWiki /\n" <>
  "PrivateVault/autotrigger / <CoreRoot>/runtime)。試験の seam。代入は NBAccess の承認対象。";
$SourceVaultIntegrityLoadVerifyEnforce::usage =
  "$SourceVaultIntegrityLoadVerifyEnforce (既定 True) が False のとき、LoadVerify はモデルが書き得る群でも拒否せず警告の Finding だけを出す (緊急時の所有者の判断)。代入は承認対象。";
$SourceVaultIntegrityDriftIntervalSeconds::usage = "$SourceVaultIntegrityDriftIntervalSeconds は InstructionDrift の周期 (既定 600 秒)。";
$SourceVaultIntegrityVerifyIntervalSeconds::usage = "$SourceVaultIntegrityVerifyIntervalSeconds は Chain / Coverage の周期 (既定 3600 秒)。";
$SourceVaultIntegrityInstructionPrivacyLevel::usage =
  "$SourceVaultIntegrityInstructionPrivacyLevel は Instruction Entity の既定 PL (既定 0.3。Claude Directives の root は 0.0 と決まっているのでそちらは 0.0)。";
$SourceVaultProvWebDocumentPrivacyLevel::usage = "$SourceVaultProvWebDocumentPrivacyLevel は webingest が取り込んだ WebDocument の Entity の PL (既定 0.3)。";

(* ---- Inc2: Instruction 系 (基準ハッシュ 2 群・drift・LoadVerify) ---- *)
SourceVaultInstructionFiles::usage =
  "SourceVaultInstructionFiles[] は Instruction 系の現行ファイル {<|\"Path\", \"Group\" -> \"HumanEdited\" | \"ModelWritable\", \"Class\", \"Root\"|>..} を返す (03 v0.4 表 4.1 Instruction、§7.1 Instructions)。\n" <>
  "HumanEdited: Claude Directives の CLAUDE.md・rules/*.md・skills/*/SKILL.md、~/.claude の CLAUDE.md・rules/*.md。\n" <>
  "ModelWritable: SourceVault_workflows の *.wl (archive を除く)、Claude TurnWiki の wiki/*.md・wiki/patterns/*.md・skills/*/SKILL.md、AutoTrigger 設定 (*.json)、runner manifest (manifest.resolved.wl)。";
SourceVaultIntegrityInitializeInstructions::usage =
  "SourceVaultIntegrityInitializeInstructions[opts] は Instruction 系の基準ハッシュの初期化 (03 v0.4 §6.3 の 1 回限りの初期化操作)。基準が無いときだけ\n" <>
  "SourceVaultIntegrityAcceptBaseline[\"Instructions\", opts] を呼ぶ (既にあれば Failure[\"BaselineExists\"]、\"Force\" -> True で上書き)。所有者 + 所有者 ticket。";
SourceVaultIntegrityInstructionDrift::usage =
  "SourceVaultIntegrityInstructionDrift[opts] は Instruction 系の全ファイルを再ハッシュして基準と比較する (03 v0.4 §7.1 InstructionDrift、service が 10 分ごと)。\n" <>
  "モデルが書き得る群の記録の無い変更・追加は Failing / UnrecordedInstructionChange (IntegrityFinding を診断 spool へ)、手編集の群は Degraded / InstructionEditPendingReview、\n" <>
  "基準に無いファイルの消失は Degraded / InstructionFileMissing、基準が無ければ Degraded / InstructionBaselineMissing。Owner / Service。\n" <>
  "戻り値 <|\"Health\", \"ReasonCode\", \"Counts\" -> <|Checked, Changed, New, Missing, Failing, Degraded|>, \"Changed\" -> {<|RelPath, Group, Class, Change|>..}, \"ComputedAtUTC\"|>。";
SourceVaultIntegrityLoadVerify::usage =
  "SourceVaultIntegrityLoadVerify[path, purpose] は読込側 (SourceVaultLoadWorkflow・TurnWiki の配布・runner manifest・Directives) が読込の直前に呼ぶ照合 (03 v0.4 §7.1 LoadVerify)。\n" <>
  "purpose: \"Workflow\" | \"TurnWikiRule\" | \"RunnerManifest\" | \"Directive\" | \"Instruction\"。戻り値 <|\"Decision\" -> \"Allow\" | \"Warn\" | \"Deny\", \"Reason\", \"Group\", \"Class\", \"BlobId\", \"Baseline\"|>。\n" <>
  "モデルが書き得る群 (Workflow / TurnWikiRule): 基準に無い・不一致は Deny (Finding Failing / UnauthorizedInstructionLoad)。手編集の群 (Directive) と runner manifest は Warn (Degraded の Finding) で読込を止めない。\n" <>
  "基準が無ければ Warn / BaselineMissing で止めない (初期化前)。ただし厳格な設定 (LoadVerifyEnforce True かつ BaselineAsAuthorization False) では Deny (2026-11-11)。\n" <>
  "認可 (AuthorizeInstruction) は索引が使え、Scope が読む機とプロファイルを含み、版がいま隔離中・Unknown・確定前でないときだけ Allow / Authorized。\n" <>
  "移行期間の基準一致も隔離中・Unknown の版なら止め、台帳がある機で索引が読めないときは Warn / BaselineMatchUnchecked。戻り値に \"IndexState\"。\n" <>
  "引数の誤りは Deny / BadArguments。Instruction 系でないパスは Allow / NotInstruction。どの主体からも呼べる。";

(* ---- Inc2: 検証器・state.json・probe ---- *)
SourceVaultIntegrityVerifiers::usage =
  "SourceVaultIntegrityVerifiers[opts] は service の検証器 (03 v0.4 §7.1): Provenance = Coverage (直近 7 日、Instruction を除く派生の率 < 0.9 Degraded、供給点を通った派生の率 < 0.9 と\n" <>
  "SessionKey の無い LLM 派生 (供給点の外) は Degraded、Instruction / DerivedCode で < 0.99 Failing、\n" <>
  "活動が無ければ NotApplicable) + Chain (前回 checkpoint 以降の連鎖と MAC、SourceVaultProvVerifyLedger) + Ingest (spool の滞留 > 1 時間 Degraded、Corrupt、emit 失敗)、\n" <>
  "MonitorSelf = Heartbeat (tick の最終時刻・予算超過・再構築年齢)、Instructions = 直近の InstructionDrift。結果を LocalState/provenance/health/state.json に書く。\n" <>
  "Chain / Coverage は \"Force\" -> True か $SourceVaultIntegrityVerifyIntervalSeconds ごと、Ingest / Heartbeat は毎回。Owner / Service。戻り値は state.json の内容。";
SourceVaultIntegrityState::usage =
  "SourceVaultIntegrityState[] は state.json を読んで返す (2 秒キャッシュ)。無ければ Missing[\"NotFound\"]。";
SourceVaultIntegrityProbe::usage =
  "SourceVaultIntegrityProbe[component] は SystemDoctor の probe (\"Provenance\" | \"MonitorSelf\" | \"Instructions\"): state.json を読むだけで (< 1 秒)\n" <>
  "<|\"Health\", \"ReasonCode\", \"Message\", \"Counts\", \"FindingIds\", \"StateAsOfUTC\", \"StateAgeSeconds\"|> を返す。state.json が $SourceVaultIntegrityStateMaxAge より\n" <>
  "古ければ Degraded / IntegrityStateStale (MonitorSelf は 15 分で Failing / ServiceTickStalled)、無ければ OK / NotApplicable (この機で service の検証器が動いていない)。";
SourceVaultIntegrityRegisterProbes::usage =
  "SourceVaultIntegrityRegisterProbes[] は Provenance と MonitorSelf の probe を SourceVaultDiagnosticsRegisterProbe に登録する (冪等、diagnostics 未ロードなら no-op)。ロード時に 1 回呼ばれる。";
SourceVaultIntegrityFindings::usage =
  "SourceVaultIntegrityFindings[opts] は health/findings.jsonl の直近の Finding (メタデータだけ: FindingId / Component / ReasonCode / Severity / Health / Targets / AtUTC) を返す。\"Limit\" (既定 100)。";

(* ---- Inc2: 記録点 (どの主体からも呼べる。失敗は数えて元の処理を止めない) ---- *)
SourceVaultProvRecordToolCall::usage =
  "SourceVaultProvRecordToolCall[name, args, result, opts] は SourceVaultMCPCallTool の tools/call 1 回を Execute Activity として記録する (03 v0.4 §6.2)。\n" <>
  "クライアント profile は接続経路 (主体の Channel) から、引数は鍵付き digest (ToolArgs)、結果の SHA-256 は放出した PL < 0.5 のときだけ、結果に含めた Entity は\n" <>
  "供給点の ServedToContext の ActivityId (\"ServedActivityIds\")。\"CallId\" -> SourceVaultRecordMCPCall の CallId を ExternalRefs に持ち、mcp_calls adapter はそれを見て補完専用になる。";
SourceVaultProvRecordWebIngest::usage =
  "SourceVaultProvRecordWebIngest[doc, opts] は SourceVaultWebFetch が取り込んだ WebDocument を Ingest Activity + PrimarySource Entity として記録する (03 v0.4 §6.2)。\n" <>
  "URL は鍵付き digest (ExternalRef、鍵が無ければ Null)、取得時刻、pre-scan 結果 (SourceVaultSecurityPreScan があれば、\"CleanText\" を渡したとき)、Taints ext:web、Actor は主体から。\n" <>
  "ContentHash (SourceVaultCommitBlob の sha256 = CanonVersion 1 の Bytes) を BlobId に写す。opts: \"Guard\" (関所の判定), \"CleanText\"。";
SourceVaultProvRecordNBRead::usage =
  "SourceVaultProvRecordNBRead[path, pl] は NBAccess の読取 (評価スコープ透かしと同じ場所) が読んだファイルを ServedToContext (Role Quote) として記録する (03 v0.4 §6.2 供給点)。\n" <>
  "Kind は OwnerAuthored (所有者のファイルと見なす。外部由来の区別は Inc3)。50 MB 超は内容を digest せず Partial。";
SourceVaultProvRecordTurnWikiMaintain::usage =
  "SourceVaultProvRecordTurnWikiMaintain[traces, files, opts] は TurnWiki Maintain (raw トレース → wiki パターン) を LLMGenerate として記録し、wiki パターンの Evidence に元トレースの EntityId を返す (T-H4)。\n" <>
  "戻り値 <|\"Status\", \"ActivityId\", \"TraceEntities\" -> <|TraceId -> EntityId|>, \"PatternEntities\" -> <|path -> EntityId|>, \"Evidence\" -> {EntityId..}|>。";

(* ---- Inc2: backfill (§6.3) ---- *)
SourceVaultIntegrityBackfill::usage =
  "SourceVaultIntegrityBackfill[opts] は既存の記録から台帳を一度だけ初期化する (03 v0.4 §6.3、所有者専用)。adapter で取り込める系統 (mcp_calls / web_access /\n" <>
  "reference_events / mcp_deposits) は読取位置を先頭に戻して再取込 (EventId は行の digest なので重複しない)、無い系統は DerivedArtifact snapshot (SourceVaultDerivedArtifactList)・\n" <>
  "PromptRunRecord (prompt-runs.jsonl)・KG (SourceVaultKGList / KGLoad) を \"Backfilled\" -> True・\"Completeness\" -> \"Partial\"・OriginClass Unknown で記録する\n" <>
  "(Coverage の分母から除外)。済みの系統は health/backfill.json に残し再実行しない (\"Force\" -> True で再実行)。本番データでは所有者が判断して実行する。\n" <>
  "opts: \"Adapters\" -> All | {name..} | None, \"DerivedArtifacts\", \"PromptRuns\", \"KnowledgeGraphs\" (既定 True), \"BudgetSeconds\" (60), \"MaxItems\" (5000)。";

Begin["`IntegrityPrivate`"]

(* ============================================================
   stubs (Inc3)
   ============================================================ *)
iSVINotImplemented[name_String, args_List] :=
  Failure["NotImplemented", <|
    "Function" -> name, "Spec" -> "03 SystemDoctor 拡張仕様 v0.4 §11.5",
    "MessageTemplate" -> "`1` is reserved by 03 v0.4 §11.5 (owner-only, owner ticket required) and is not implemented yet (Inc3).",
    "MessageParameters" -> {name}, "ArgumentCount" -> Length[args]|>];

(* Inc3 (2026-11-10): RecordOwnerReview / AuthorizeInstruction / RevokeAuthorization / Quarantine / Release / ResolveFinding /
   RegisterVerifier は本体化 (下の「所有者操作」の節)。RederiveApprove は 14 章 (Inc7) まで stub *)
SourceVaultRederiveApprove[args___] := iSVINotImplemented["SourceVaultRederiveApprove", {args}];

(* ============================================================
   設定・小道具
   ============================================================ *)
If[! NumberQ[$SourceVaultIntegrityStateMaxAge], $SourceVaultIntegrityStateMaxAge = 3600];
If[! ValueQ[$SourceVaultInstructionRoots], $SourceVaultInstructionRoots = Automatic];
If[! BooleanQ[$SourceVaultIntegrityLoadVerifyEnforce], $SourceVaultIntegrityLoadVerifyEnforce = True];
If[! NumberQ[$SourceVaultIntegrityDriftIntervalSeconds], $SourceVaultIntegrityDriftIntervalSeconds = 600];
If[! NumberQ[$SourceVaultIntegrityVerifyIntervalSeconds], $SourceVaultIntegrityVerifyIntervalSeconds = 3600];
If[! NumberQ[$SourceVaultIntegrityInstructionPrivacyLevel], $SourceVaultIntegrityInstructionPrivacyLevel = 0.3];
If[! NumberQ[$SourceVaultProvWebDocumentPrivacyLevel], $SourceVaultProvWebDocumentPrivacyLevel = 0.3];
(* Inc3 (2026-11-10): 検索フィルタが使えないときの扱い (Inc5 で True に)、基準ハッシュを認可の代わりに認める移行期間 *)
If[! BooleanQ[$SourceVaultIntegrityFilterFailClosed], $SourceVaultIntegrityFilterFailClosed = False];
If[! BooleanQ[$SourceVaultIntegrityBaselineAsAuthorization], $SourceVaultIntegrityBaselineAsAuthorization = True];

$iSVIPackageDir = If[StringQ[$InputFileName] && $InputFileName =!= "", DirectoryName[$InputFileName],
  If[StringQ[Global`$packageDirectory], Global`$packageDirectory, Directory[]]];
$iSVIHumanClasses = {"ClaudeMD", "Rule", "Skill", "UserClaudeMD", "UserRule"};
$iSVIModelClasses = {"Workflow", "TurnWikiPage", "TurnWikiPattern", "TurnWikiSkill", "AutoTriggerConfig", "RunnerManifest"};
$iSVIMaxInstructionFiles = 2000;
$iSVIMaxHashBytes = 50*1024*1024;

iSVINowIso[] := DateString[AbsoluteTime[], {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"}, TimeZone -> 0];
iSVIIsoToAbs[iso_String] := Module[{m},
  m = StringCases[iso, RegularExpression["^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?Z$"] :>
    (FromDigits /@ {"$1", "$2", "$3", "$4", "$5", "$6"})];
  If[m === {}, $Failed, Quiet @ Check[AbsoluteTime[DateObject[First[m], TimeZone -> 0]], $Failed]]];
iSVIIsoToAbs[_] := $Failed;
iSVISHAHex[s_String] := Hash[StringToByteArray[s, "UTF-8"], "SHA256", "HexString"];
iSVIULID[] := If[Length[DownValues[SourceVault`SourceVaultULID]] > 0, SourceVault`SourceVaultULID[],
  StringJoin[Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"][[IntegerDigits[UnixTime[]*1000, 32, 10] + 1]]] <>
    StringJoin[Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"][[IntegerDigits[RandomInteger[{0, 2^80 - 1}], 32, 16] + 1]]]];
iSVIPrincipalKind[] := With[{k = Quiet @ Check[SourceVault`SourceVaultPrincipal["Kind"], "Model"]}, If[StringQ[k], k, "Model"]];
iSVIOwnerQ[] := MemberQ[{"OwnerFE", "OwnerCode"}, iSVIPrincipalKind[]];
iSVIOwnerServiceQ[] := MemberQ[{"OwnerFE", "OwnerCode", "Service"}, iSVIPrincipalKind[]];
iSVINotAuthorized[fn_String, allowed_List] := Failure["ProvNotAuthorized", <|"Function" -> fn, "Principal" -> iSVIPrincipalKind[], "Allowed" -> allowed,
  "MessageTemplate" -> "`1` may be called only by `2` (03 v0.4 table 11.1); the current principal is `3`.",
  "MessageParameters" -> {fn, StringRiffle[allowed, ", "], iSVIPrincipalKind[]}|>];
iSVIProvQ[] := Length[DownValues[SourceVault`SourceVaultProvEmit]] > 0 && Length[DownValues[SourceVault`SourceVaultProvEntity]] > 0;
iSVIFn[name_String] := If[Names[name] =!= {}, With[{s = Symbol[Identity[name]]}, If[Length[DownValues[s]] > 0, s, None]], None];
iSVIStr[x_] := If[StringQ[x], x, Null];

iSVILocalState[] := With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["LocalState"], $Failed]}, If[StringQ[r] && r =!= "", r, $Failed]];
iSVIEnsureDir[d_String] := (If[! DirectoryQ[d], Quiet @ CreateDirectory[d, CreateIntermediateDirectories -> True]]; If[DirectoryQ[d], d, $Failed]);
iSVIHealthDir[] := With[{ls = iSVILocalState[]}, If[ls === $Failed, $Failed, iSVIEnsureDir[FileNameJoin[{ls, "provenance", "health"}]]]];
iSVIHealthPath[name_String] := With[{d = iSVIHealthDir[]}, If[d === $Failed, $Failed, FileNameJoin[{d, name}]]];
iSVIReadBytes[p_] := If[StringQ[p] && FileExistsQ[p], If[Quiet @ Check[FileByteCount[p], -1] === 0, StringToByteArray["", "UTF-8"], Quiet @ Check[ReadByteArray[p], $Failed]], $Failed];
iSVIReadJSON[p_] := With[{b = iSVIReadBytes[p]}, If[ByteArrayQ[b] && Length[b] > 0, Quiet @ Check[ImportByteArray[b, "RawJSON"], $Failed], $Failed]];
iSVIJSONSafe[a_Association] := Association @ KeyValueMap[ToString[#1] -> iSVIJSONSafe[#2] &, a];
iSVIJSONSafe[l_List] := iSVIJSONSafe /@ l;
iSVIJSONSafe[x : (_String | _Integer | _Real | True | False | Null)] := x;
iSVIJSONSafe[x_Missing] := Null;
iSVIJSONSafe[None] := Null;
iSVIJSONSafe[x_] := ToString[x, InputForm];
iSVIWriteJSON[p_, x_] := Module[{ba, tmp, strm, ok},
  If[! StringQ[p], Return[$Failed]];
  ba = Quiet @ Check[ExportByteArray[iSVIJSONSafe[x], "RawJSON", "Compact" -> True], $Failed];
  If[! ByteArrayQ[ba], Return[$Failed]];
  If[iSVIEnsureDir[DirectoryName[p]] === $Failed, Return[$Failed]];
  tmp = p <> ".tmp-" <> ToString[$ProcessID] <> "-" <> StringTake[CreateUUID[], 8];
  strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  ok = Quiet @ Check[(BinaryWrite[strm, ba]; Close[strm]; True), (Quiet @ Close[strm]; False)];
  If[! TrueQ[ok], Quiet @ DeleteFile[tmp]; Return[$Failed]];
  Quiet @ Check[RenameFile[tmp, p, OverwriteTarget -> True]; p, Quiet @ DeleteFile[tmp]; $Failed]];
iSVIAppendLine[p_, x_] := Module[{ba, strm},
  If[! StringQ[p], Return[$Failed]];
  ba = Quiet @ Check[ExportByteArray[iSVIJSONSafe[x], "RawJSON", "Compact" -> True], $Failed];
  If[! ByteArrayQ[ba], Return[$Failed]];
  If[iSVIEnsureDir[DirectoryName[p]] === $Failed, Return[$Failed]];
  strm = Quiet @ OpenAppend[p, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  Quiet @ Check[(BinaryWrite[strm, ba]; BinaryWrite[strm, StringToByteArray["\n", "UTF-8"]]; Close[strm]; p), (Quiet @ Close[strm]; $Failed)]];

(* ファイルの BlobId (CanonVersion 1 File = バイト列そのもの)。size + mtime でキャッシュ *)
If[! AssociationQ[$iSVIHashCache], $iSVIHashCache = <||>];
iSVIFileBlobId[path_String] := Module[{size, mtime, c, b},
  If[! FileExistsQ[path] || DirectoryQ[path], Return[$Failed]];
  size = Quiet @ Check[FileByteCount[path], -1];
  mtime = Quiet @ Check[AbsoluteTime[FileDate[path, "Modification"]], 0];
  c = Lookup[$iSVIHashCache, path, None];
  If[AssociationQ[c] && c["Size"] === size && c["Mtime"] === mtime, Return[c["BlobId"]]];
  If[size > $iSVIMaxHashBytes, Return[Missing["TooLarge", size]]];
  b = iSVIReadBytes[path];
  If[! ByteArrayQ[b], Return[$Failed]];
  With[{bid = "blob:sha256:" <> Hash[b, "SHA256", "HexString"]},
    $iSVIHashCache[path] = <|"Size" -> size, "Mtime" -> mtime, "BlobId" -> bid|>;
    If[Length[$iSVIHashCache] > 5000, $iSVIHashCache = Take[$iSVIHashCache, -2500]];
    bid]];
iSVICanonPath[p_String] := With[{e = Quiet @ Check[ExpandFileName[p], p]}, If[StringQ[e], e, p]];
iSVIRelPath[p_String, root_String] := If[StringStartsQ[p, root], StringReplace[StringDrop[p, StringLength[root]], {StartOfString ~~ ("\\" | "/") -> "", "\\" -> "/"}], FileNameTake[p]];

(* ============================================================
   Finding (§4.6 / §9.1): health/findings.jsonl に残し、Failing / High は診断 spool へ EventClass IntegrityFinding・Producer integrity
   (service なら正準ログ + Issue、FE なら spool)。同じ Component|ReasonCode|Target は 24 時間に 1 回
   ============================================================ *)
If[! AssociationQ[$iSVIWarnState], $iSVIWarnState = <||>];
If[! TrueQ[$iSVIWarnStateLoaded], $iSVIWarnStateLoaded = False];
If[! AssociationQ[$iSVIFindingStats], $iSVIFindingStats = <|"Recorded" -> 0, "Published" -> 0, "Suppressed" -> 0|>];
iSVIWarnStateLoad[] := Module[{p, a},
  If[TrueQ[$iSVIWarnStateLoaded], Return[$iSVIWarnState]];
  $iSVIWarnStateLoaded = True;
  p = iSVIHealthPath["warn-state.json"];
  a = iSVIReadJSON[p];
  If[AssociationQ[a], $iSVIWarnState = Merge[{Select[KeySelect[a, StringQ], NumericQ], $iSVIWarnState}, Max]];
  $iSVIWarnState];
iSVIWarnStateSave[] := With[{now = AbsoluteTime[]},
  iSVIWriteJSON[iSVIHealthPath["warn-state.json"], Select[$iSVIWarnState, NumericQ[#] && now - # < 7*86400 &]]];
iSVIDiagPublish[event_Association] := If[Length[DownValues[SourceVault`SourceVaultDiagnosticsPublish]] > 0,
  Quiet @ Check[SourceVault`SourceVaultDiagnosticsPublish[event], $Failed], <|"Route" -> "DiagnosticsAbsent"|>];

(* 通知・Issue の PL: 対象の版の PL の最大値 (呼び出し側が渡す)、下限は表 12.1 の 0.3 *)
If[! NumberQ[$iSVIFindingPLFloor], $iSVIFindingPLFloor = 0.3];
Options[iSVIFinding] = {"Targets" -> {}, "Detail" -> <||>, "PrivacyLevel" -> Automatic, "Publish" -> Automatic};
iSVIFinding[comp_String, rc_String, severity_String, health_String, OptionsPattern[]] := Module[
  {fid = "fnd-" <> iSVIULID[], targets, rec, key, now = AbsoluteTime[], prior, publishQ, pl, pub = Null},
  targets = Select[Flatten[{OptionValue["Targets"]}], StringQ];
  pl = With[{p = OptionValue["PrivacyLevel"]}, If[NumericQ[p], Max[$iSVIFindingPLFloor, N[p]], $iSVIFindingPLFloor]];
  rec = <|"Type" -> "ProvFinding", "FindingId" -> fid, "Component" -> comp, "Kind" -> rc, "ReasonCode" -> rc, "Severity" -> severity, "Health" -> health,
    "Targets" -> Take[targets, UpTo[50]], "TargetCount" -> Length[targets], "Detail" -> OptionValue["Detail"], "Status" -> "Open",
    "PrivacyLevel" -> pl, "AtUTC" -> iSVINowIso[], "Machine" -> If[Length[DownValues[SourceVault`SourceVaultMachineTag]] > 0, SourceVault`SourceVaultMachineTag[], $MachineName],
    "Principal" -> iSVIPrincipalKind[]|>;
  (* 同じ Component|ReasonCode|Targets の Finding は 24 時間に 1 回だけ記録・通知する (drift は 10 分ごと、LoadVerify は読込のたびに呼ばれる) *)
  iSVIWarnStateLoad[];
  key = comp <> "|" <> rc <> "|" <> iSVISHAHex[StringRiffle[Sort[targets], ","]];
  With[{rp = Lookup[$iSVIWarnState, "rec|" <> key, None]},
    If[NumericQ[rp] && now - rp <= 86400,
      $iSVIFindingStats["Suppressed"]++;
      Return[Join[rec, <|"Recorded" -> False, "Published" -> Null|>]]]];
  $iSVIWarnState["rec|" <> key] = now;
  Quiet @ iSVIAppendLine[iSVIHealthPath["findings.jsonl"], rec];
  $iSVIFindingStats["Recorded"]++;
  publishQ = With[{p = OptionValue["Publish"]}, If[BooleanQ[p], p, health === "Failing" || MemberQ[{"High", "Critical"}, severity]]];
  If[! publishQ, Quiet @ iSVIWarnStateSave[]];
  If[publishQ,
    prior = Lookup[$iSVIWarnState, key, None];
    If[! NumericQ[prior] || now - prior > 86400,
      $iSVIWarnState[key] = now; Quiet @ iSVIWarnStateSave[];
      pub = iSVIDiagPublish[<|"Type" -> "DiagnosticsEvent", "EventId" -> CreateUUID[], "EventClass" -> "IntegrityFinding", "Producer" -> "integrity",
        "Component" -> comp, "ReasonCode" -> rc, "Severity" -> severity, "Health" -> health, "IssueRequested" -> True, "IssueClass" -> "security",
        "PrivacyLevel" -> pl,
        (* 本文はメタデータだけ: ID・件数・部品名・ReasonCode (03 v0.4 §9.1) *)
        "Summary" -> comp <> ": " <> rc <> " (" <> ToString[Length[targets]] <> " target(s), finding " <> fid <> ")",
        "Payload" -> <|"FindingId" -> fid, "Component" -> comp, "ReasonCode" -> rc, "TargetCount" -> Length[targets]|>|>];
      $iSVIFindingStats["Published"]++,
      $iSVIFindingStats["Suppressed"]++]];
  Append[rec, "Published" -> pub]];

Options[SourceVaultIntegrityFindings] = {"Limit" -> 100};
SourceVaultIntegrityFindings[OptionsPattern[]] := Module[{p = iSVIHealthPath["findings.jsonl"], b, t, lines, recs, lim = OptionValue["Limit"]},
  b = iSVIReadBytes[p];
  If[! ByteArrayQ[b] || Length[b] === 0, Return[{}]];
  t = Quiet @ Check[ByteArrayToString[b, "UTF-8"], ""];
  lines = Select[StringSplit[t, "\n"], StringTrim[#] =!= "" &];
  If[IntegerQ[lim] && lim > 0, lines = Take[lines, -Min[lim, Length[lines]]]];
  recs = Quiet @ Check[ImportByteArray[StringToByteArray[#, "UTF-8"], "RawJSON"], Nothing] & /@ lines;
  Reverse @ Select[recs, AssociationQ]];

(* ============================================================
   Instruction 系 (§6.2 / §7.1): 2 群のファイル一覧
   ============================================================ *)
iSVIRootOverride[key_String] := With[{o = $SourceVaultInstructionRoots},
  If[AssociationQ[o] && StringQ[Lookup[o, key, None]], o[key], None]];
iSVIDirectivesRoot[] := Module[{r = iSVIRootOverride["Directives"], f},
  If[StringQ[r], Return[If[DirectoryQ[r], r, None]]];
  f = iSVIFn["ClaudeDirectives`ClaudeResolveDirectiveRoot"];
  If[f =!= None, r = Quiet @ Check[f[Automatic], $Failed]; If[StringQ[r] && DirectoryQ[r], Return[r]]];
  r = FileNameJoin[{$iSVIPackageDir, "Claude Directives"}];
  If[DirectoryQ[r], r, None]];
iSVIUserClaudeRoot[] := Module[{r = iSVIRootOverride["UserClaude"]},
  If[StringQ[r], Return[If[DirectoryQ[r], r, None]]];
  r = FileNameJoin[{$HomeDirectory, ".claude"}]; If[DirectoryQ[r], r, None]];
iSVIWorkflowsRoot[] := Module[{r = iSVIRootOverride["Workflows"], f},
  If[StringQ[r], Return[If[DirectoryQ[r], r, None]]];
  f = iSVIFn["SourceVault`SourceVaultWorkflowDirectory"];
  If[f =!= None, r = Quiet @ Check[f[], $Failed]; If[StringQ[r] && DirectoryQ[r], Return[r]]];
  r = FileNameJoin[{$iSVIPackageDir, "SourceVault_workflows"}]; If[DirectoryQ[r], r, None]];
iSVITurnWikiRoot[] := Module[{r = iSVIRootOverride["TurnWiki"]},
  If[StringQ[r], Return[If[DirectoryQ[r], r, None]]];
  r = With[{v = Quiet @ Check[Symbol[Identity["ClaudeOrchestrator`$ClaudeTurnWikiRoot"]], None]}, If[StringQ[v] && DirectoryQ[v], v, None]];
  If[StringQ[r], Return[r]];
  r = FileNameJoin[{$iSVIPackageDir, "Claude TurnWiki"}]; If[DirectoryQ[r], r, None]];
iSVIAutoTriggerRoot[] := Module[{r = iSVIRootOverride["AutoTrigger"], pv},
  If[StringQ[r], Return[If[DirectoryQ[r], r, None]]];
  pv = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed];
  If[StringQ[pv] && DirectoryQ[FileNameJoin[{pv, "autotrigger"}]], FileNameJoin[{pv, "autotrigger"}], None]];
iSVIRunnerManifestRoot[] := Module[{r = iSVIRootOverride["RunnerManifest"], cr},
  If[StringQ[r], Return[If[DirectoryQ[r], r, None]]];
  cr = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed];
  If[StringQ[cr] && DirectoryQ[FileNameJoin[{cr, "runtime"}]], FileNameJoin[{cr, "runtime"}], None]];
iSVIFilesSafe[pat_, dir_, depth_: 1] := If[StringQ[dir] && DirectoryQ[dir], Quiet @ Check[Sort @ FileNames[pat, dir, depth], {}], {}];
iSVIRow[path_, group_, class_, root_] := <|"Path" -> iSVICanonPath[path], "Group" -> group, "Class" -> class, "Root" -> root, "RelPath" -> iSVIRelPath[iSVICanonPath[path], iSVICanonPath[root]]|>;

SourceVaultInstructionFiles[] := Module[{rows = {}, d, u, w, t, a, m},
  d = iSVIDirectivesRoot[];
  If[StringQ[d],
    rows = Join[rows,
      iSVIRow[#, "HumanEdited", "ClaudeMD", d] & /@ Select[{FileNameJoin[{d, "CLAUDE.md"}]}, FileExistsQ],
      iSVIRow[#, "HumanEdited", "Rule", d] & /@ iSVIFilesSafe["*.md", FileNameJoin[{d, "rules"}]],
      iSVIRow[#, "HumanEdited", "Skill", d] & /@ Select[iSVIFilesSafe["SKILL.md", FileNameJoin[{d, "skills"}], 2], FileExistsQ]]];
  u = iSVIUserClaudeRoot[];
  If[StringQ[u],
    rows = Join[rows,
      iSVIRow[#, "HumanEdited", "UserClaudeMD", u] & /@ Select[{FileNameJoin[{u, "CLAUDE.md"}]}, FileExistsQ],
      iSVIRow[#, "HumanEdited", "UserRule", u] & /@ iSVIFilesSafe["*.md", FileNameJoin[{u, "rules"}]]]];
  w = iSVIWorkflowsRoot[];
  If[StringQ[w],
    rows = Join[rows, iSVIRow[#, "ModelWritable", "Workflow", w] & /@
      Select[iSVIFilesSafe["*.wl", w, Infinity], ! StringContainsQ[iSVIRelPath[#, w], "archive/" | "_info/" | "/bak/"] &]]];
  t = iSVITurnWikiRoot[];
  If[StringQ[t],
    rows = Join[rows,
      iSVIRow[#, "ModelWritable", "TurnWikiPage", t] & /@ iSVIFilesSafe["*.md", FileNameJoin[{t, "wiki"}]],
      iSVIRow[#, "ModelWritable", "TurnWikiPattern", t] & /@ iSVIFilesSafe["*.md", FileNameJoin[{t, "wiki", "patterns"}]],
      iSVIRow[#, "ModelWritable", "TurnWikiSkill", t] & /@ iSVIFilesSafe["SKILL.md", FileNameJoin[{t, "skills"}], 2]]];
  a = iSVIAutoTriggerRoot[];
  If[StringQ[a],
    rows = Join[rows, iSVIRow[#, "ModelWritable", "AutoTriggerConfig", a] & /@
      Select[iSVIFilesSafe["*.json", a, 2], ! StringContainsQ[FileNameTake[#], "jobs" | "runs" | ".ingest"] &]]];
  m = iSVIRunnerManifestRoot[];
  If[StringQ[m],
    rows = Join[rows, iSVIRow[#, "ModelWritable", "RunnerManifest", m] & /@ iSVIFilesSafe["manifest.resolved.wl", m, 4]]];
  rows = DeleteDuplicatesBy[rows, #["Path"] &];
  Take[rows, UpTo[$iSVIMaxInstructionFiles]]];

(* パスから群と種別を決める (LoadVerify 用): 一覧に無くても root の下なら種別を推定する *)
(* root の解決 (ClaudeDirectives の探索を含む) は LoadVerify のたびに行わない: 10 秒のキャッシュ ($SourceVaultInstructionRoots が変われば捨てる) *)
If[! AssociationQ[$iSVIRootsCache], $iSVIRootsCache = <||>];
iSVIRootsCached[] := Module[{now = AbsoluteTime[], stamp = Hash[$SourceVaultInstructionRoots]},
  If[AssociationQ[Lookup[$iSVIRootsCache, "Roots", None]] && Lookup[$iSVIRootsCache, "Stamp", None] === stamp && now - Lookup[$iSVIRootsCache, "At", 0] < 10,
    Return[$iSVIRootsCache["Roots"]]];
  With[{r = <|"d" -> iSVIDirectivesRoot[], "u" -> iSVIUserClaudeRoot[], "w" -> iSVIWorkflowsRoot[], "t" -> iSVITurnWikiRoot[], "a" -> iSVIAutoTriggerRoot[], "m" -> iSVIRunnerManifestRoot[]|>},
    $iSVIRootsCache = <|"Roots" -> r, "Stamp" -> stamp, "At" -> now|>; r]];
iSVIClassifyPath[pathIn_String] := Module[{p = iSVICanonPath[pathIn], rs = iSVIRootsCached[], d, u, w, t, a, m, under, lower},
  {d, u, w, t, a, m} = Lookup[rs, {"d", "u", "w", "t", "a", "m"}];
  under = Function[r, StringQ[r] && StringStartsQ[ToLowerCase[p], ToLowerCase[iSVICanonPath[r]]]];
  lower = ToLowerCase[p];
  Which[
    under[w] && StringEndsQ[lower, ".wl"], <|"Group" -> "ModelWritable", "Class" -> "Workflow", "Root" -> w|>,
    under[t] && StringContainsQ[lower, "skill.md"], <|"Group" -> "ModelWritable", "Class" -> "TurnWikiSkill", "Root" -> t|>,
    under[t] && StringContainsQ[lower, "patterns"], <|"Group" -> "ModelWritable", "Class" -> "TurnWikiPattern", "Root" -> t|>,
    under[t] && StringEndsQ[lower, ".md"], <|"Group" -> "ModelWritable", "Class" -> "TurnWikiPage", "Root" -> t|>,
    under[a] && StringEndsQ[lower, ".json"], <|"Group" -> "ModelWritable", "Class" -> "AutoTriggerConfig", "Root" -> a|>,
    under[m] && StringEndsQ[lower, "manifest.resolved.wl"], <|"Group" -> "ModelWritable", "Class" -> "RunnerManifest", "Root" -> m|>,
    StringEndsQ[lower, "manifest.resolved.wl"], <|"Group" -> "ModelWritable", "Class" -> "RunnerManifest", "Root" -> DirectoryName[p]|>,
    under[d] && StringContainsQ[lower, "skill.md"], <|"Group" -> "HumanEdited", "Class" -> "Skill", "Root" -> d|>,
    under[d] && StringEndsQ[lower, "claude.md"], <|"Group" -> "HumanEdited", "Class" -> "ClaudeMD", "Root" -> d|>,
    under[d] && StringEndsQ[lower, ".md"], <|"Group" -> "HumanEdited", "Class" -> "Rule", "Root" -> d|>,
    under[u] && StringEndsQ[lower, "claude.md"], <|"Group" -> "HumanEdited", "Class" -> "UserClaudeMD", "Root" -> u|>,
    under[u] && StringEndsQ[lower, ".md"], <|"Group" -> "HumanEdited", "Class" -> "UserRule", "Root" -> u|>,
    True, None]];

(* ============================================================
   基準 (health/instruction-baseline.json) と AcceptBaseline["Instructions"] (§6.3 / §7.1)
   ============================================================ *)
iSVIBaselinePath[] := iSVIHealthPath["instruction-baseline.json"];
iSVIReadBaseline[] := With[{b = iSVIReadJSON[iSVIBaselinePath[]]},
  If[AssociationQ[b] && Lookup[b, "Format", ""] === "SourceVaultInstructionBaseline/1" && AssociationQ[Lookup[b, "Entries", None]], b, Missing["NotFound"]]];
If[! AssociationQ[$iSVIBaselineCache], $iSVIBaselineCache = <||>];
iSVIReadBaselineCached[] := Module[{p = iSVIBaselinePath[], mt, c},
  If[p === $Failed, Return[Missing["NotFound"]]];
  mt = If[FileExistsQ[p], Quiet @ Check[{FileByteCount[p], AbsoluteTime[FileDate[p, "Modification"]]}, None], None];
  c = $iSVIBaselineCache;
  If[AssociationQ[c] && Lookup[c, "Stamp", None] === mt && KeyExistsQ[c, "Baseline"], Return[c["Baseline"]]];
  With[{b = iSVIReadBaseline[]}, $iSVIBaselineCache = <|"Stamp" -> mt, "Baseline" -> b|>; b]];

(* 現行ファイルと基準の差分 *)
iSVIDiff[baseline_] := Module[{files = SourceVaultInstructionFiles[], entries, changed = {}, new = {}, same = {}, missing = {}, seen = <||>},
  entries = If[AssociationQ[baseline], Lookup[baseline, "Entries", <||>], <||>];
  Scan[Function[f, Module[{bid = iSVIFileBlobId[f["Path"]], e = Lookup[entries, f["Path"], None]},
      seen[f["Path"]] = True;
      Which[
        ! StringQ[bid], AppendTo[changed, Append[f, <|"Change" -> "Unreadable", "BlobId" -> Null, "Baseline" -> If[AssociationQ[e], e["BlobId"], Null]|>]],
        ! AssociationQ[e], AppendTo[new, Append[f, <|"Change" -> "New", "BlobId" -> bid, "Baseline" -> Null|>]],
        e["BlobId"] === bid, AppendTo[same, Append[f, <|"Change" -> "Same", "BlobId" -> bid, "Baseline" -> bid, "EntityId" -> Lookup[e, "EntityId", Null]|>]],
        True, AppendTo[changed, Append[f, <|"Change" -> "Changed", "BlobId" -> bid, "Baseline" -> e["BlobId"], "EntityId" -> Lookup[e, "EntityId", Null]|>]]]]],
    files];
  KeyValueMap[Function[{p, e}, If[! KeyExistsQ[seen, p],
      AppendTo[missing, <|"Path" -> p, "Group" -> Lookup[e, "Group", "?"], "Class" -> Lookup[e, "Class", "?"], "RelPath" -> Lookup[e, "RelPath", FileNameTake[p]],
        "Change" -> "Missing", "BlobId" -> Null, "Baseline" -> e["BlobId"], "EntityId" -> Lookup[e, "EntityId", Null]|>]]], entries];
  <|"Changed" -> changed, "New" -> new, "Same" -> same, "Missing" -> missing, "Files" -> Length[files]|>];
iSVITicketDigest[x_String] := If[Length[DownValues[SourceVault`SourceVaultOwnerTicketDigest]] > 0, SourceVault`SourceVaultOwnerTicketDigest[x], "sha256:" <> iSVISHAHex[x]];
iSVIChangeDigestText[rows_List] := StringRiffle[Sort[(#["Path"] <> "|" <> ToString[#["Change"]] <> "|" <> ToString[#["BlobId"]]) & /@ rows], "\n"];
iSVIInstructionPL[row_Association] := If[MemberQ[{"ClaudeMD", "Rule", "Skill"}, Lookup[row, "Class", ""]], 0.0, $SourceVaultIntegrityInstructionPrivacyLevel];

Options[SourceVaultIntegrityAcceptBaseline] = {"Ticket" -> None, "Paths" -> All, "DryRun" -> False, "Note" -> "", "Force" -> False,
  "Role" -> Automatic, "MaxSnapshotAgeSeconds" -> 900};
SourceVaultIntegrityAcceptBaseline[component_String, OptionsPattern[]] := Module[
  {baseline, diff, scope, rows, bindText, bind, ticket, v, aid, ents = {}, entries, act, now, removed = {}, accepted = 0, prevEnt, r, pathsOpt},
  (* Inc3: SecurityProfile (Policy 部品の基準)。ModelManifest / 系列は Inc4 以降 *)
  If[component === "SecurityProfile",
    Return[iSVIAcceptPolicyBaseline[OptionValue["Ticket"], TrueQ[OptionValue["DryRun"]], ToString @ OptionValue["Note"],
      OptionValue["Role"], OptionValue["MaxSnapshotAgeSeconds"]]]];
  (* Inc4: ModelManifest (LM Studio のモデル・テンプレート・版の基準) *)
  If[component === "ModelManifest",
    Return[iSVIAcceptModelBaseline[OptionValue["Ticket"], TrueQ[OptionValue["DryRun"]], ToString @ OptionValue["Note"]]]];
  If[component =!= "Instructions", Return[iSVINotImplemented["SourceVaultIntegrityAcceptBaseline", {component}]]];
  If[! iSVIOwnerQ[], iSVIRegistryAttempt["SourceVaultIntegrityAcceptBaseline"];
    Return[iSVINotAuthorized["SourceVaultIntegrityAcceptBaseline", {"OwnerFE", "OwnerCode"}]]];
  If[iSVIHealthDir[] === $Failed, Return[Failure["ProvLocalStateUnresolved", <|"MessageTemplate" -> "SourceVaultRoot[\"LocalState\"] is not resolved."|>]]];
  baseline = iSVIReadBaseline[];
  diff = iSVIDiff[baseline];
  pathsOpt = OptionValue["Paths"];
  rows = Join[diff["Changed"], diff["New"], diff["Missing"]];
  If[ListQ[pathsOpt], With[{ps = iSVICanonPath /@ Select[pathsOpt, StringQ]}, rows = Select[rows, MemberQ[ps, #["Path"]] &]]];
  rows = Select[rows, #["Change"] =!= "Unreadable" &];
  bindText = iSVIChangeDigestText[rows];
  (* 所有者 ticket の Bind: Display (所有者に見せた変更一覧) と Component の digest。Mint と Consume で同じ digest 関数 (SourceVaultOwnerTicketDigest) *)
  bind = <|"Display" -> iSVITicketDigest[bindText], "Component" -> iSVITicketDigest["Instructions"]|>;
  ticket = OptionValue["Ticket"];
  If[TrueQ[OptionValue["DryRun"]] || ! AssociationQ[ticket],
    Return[<|"Status" -> "ReviewRequired", "Component" -> "Instructions", "BaselineExists" -> AssociationQ[baseline],
      "Changes" -> (KeyTake[#, {"RelPath", "Group", "Class", "Change"}] & /@ rows), "ChangeCount" -> Length[rows], "Unchanged" -> Length[diff["Same"]],
      "Unreadable" -> Count[Join[diff["Changed"]], KeyValuePattern["Change" -> "Unreadable"]],
      "Bind" -> bind, "BindDisplay" -> bindText, "TicketAction" -> "AcceptBaseline",
      "MessageTemplate" -> "Review the change list, then call again with an owner ticket (Action AcceptBaseline, Bind as returned)."|>]];
  If[Length[DownValues[SourceVault`SourceVaultOwnerTicketConsume]] === 0 || Length[DownValues[SourceVault`SourceVaultOwnerTicketDigest]] === 0,
    Return[Failure["ProvTicketUnavailable", <|"MessageTemplate" -> "SourceVault_autotrigger.wl (owner tickets) is not loaded."|>]]];
  (* 記録できないなら ticket を消費する前に止める (12.5 節: 確定を要求する操作は ProvenanceUnavailable) *)
  If[! iSVIProvQ[], Return[Failure["ProvenanceUnavailable", <|"Reason" -> "ProvenanceModuleAbsent"|>]]];
  v = SourceVault`SourceVaultOwnerTicketConsume[ticket,
    bind,
    "Action" -> "AcceptBaseline"];
  If[! (AssociationQ[v] && TrueQ[v["Consumed"]]), Return[Failure["ProvTicketRejected", <|"Result" -> v|>]]];
  If[! iSVIProvQ[], Return[Failure["ProvenanceUnavailable", <|"Reason" -> "ProvenanceModuleAbsent"|>]]];
  now = iSVINowIso[];
  aid = "act-" <> iSVIULID[];
  entries = If[AssociationQ[baseline], baseline["Entries"], <||>];
  Scan[Function[row, Module[{e},
      Switch[row["Change"],
        "Missing", entries = KeyDrop[entries, row["Path"]]; AppendTo[removed, row["RelPath"]],
        "New" | "Changed",
          prevEnt = Lookup[row, "EntityId", Null];
          e = SourceVault`SourceVaultProvEntity[<|"Kind" -> "Instruction", "ContentRef" -> row["Path"], "ContentKind" -> "File",
            "LogicalRef" -> "instr://" <> ToLowerCase[row["Class"]] <> "/" <> row["RelPath"], "VersionOf" -> If[StringQ[prevEnt], prevEnt, Null],
            "Refs" -> <|"RelPath" -> row["RelPath"], "Class" -> row["Class"]|>,
            "Media" -> If[StringEndsQ[ToLowerCase[row["Path"]], ".wl"], "application/vnd.wolfram.wl", "text/markdown"],
            "Context" -> <|"Channel" -> "InstructionBaseline", "Group" -> row["Group"], "Class" -> row["Class"], "AcceptedAtUTC" -> now|>,
            "PrivacyLevel" -> iSVIInstructionPL[row],
            "Origin" -> <|"Contributors" -> {"Owner"}, "Taints" -> {"edit:owner", "baseline:instructions"}|>,
            "ProducedBy" -> {aid}, "Completeness" -> "Complete"|>];
          If[! FailureQ[e],
            accepted++; AppendTo[ents, e["EntityId"]];
            entries[row["Path"]] = <|"BlobId" -> e["BlobId"], "EntityId" -> e["EntityId"], "Group" -> row["Group"], "Class" -> row["Class"],
              "RelPath" -> row["RelPath"], "AcceptedAtUTC" -> now|>]]]],
    rows];
  act = SourceVault`SourceVaultProvActivity[<|"Kind" -> "HumanEdit", "ActivityId" -> aid, "Inputs" -> {}, "Outputs" -> ents,
    "InputsCompleteness" -> "Complete", "ExternalRefs" -> <|"Baseline" -> "Instructions", "TicketNonce" -> ToString @ Lookup[ticket, "Nonce", ""]|>,
    "Detail" -> <|"BaselineAccepted" -> True, "Accepted" -> accepted, "Removed" -> Length[removed], "Unchanged" -> Length[diff["Same"]],
      "Note" -> ToString @ OptionValue["Note"], "Initial" -> Not[AssociationQ[baseline]]|>|>];
  r = iSVIWriteJSON[iSVIBaselinePath[], <|"Format" -> "SourceVaultInstructionBaseline/1", "AcceptedAtUTC" -> now, "AcceptedBy" -> iSVIPrincipalKind[],
    "TicketNonce" -> ToString @ Lookup[ticket, "Nonce", ""], "ActivityId" -> aid, "Entries" -> entries, "Count" -> Length[entries]|>];
  $iSVIBaselineCache = <||>;
  <|"Status" -> If[r === $Failed, "BaselineWriteFailed", "Accepted"], "Component" -> "Instructions", "Accepted" -> accepted, "Removed" -> Length[removed],
    "Unchanged" -> Length[diff["Same"]], "Entries" -> Length[entries], "ActivityId" -> aid, "EntityIds" -> ents, "Activity" -> act,
    "Initial" -> Not[AssociationQ[baseline]]|>];
SourceVaultIntegrityAcceptBaseline[args___] := iSVINotImplemented["SourceVaultIntegrityAcceptBaseline", {args}];

Options[SourceVaultIntegrityInitializeInstructions] = Options[SourceVaultIntegrityAcceptBaseline];
SourceVaultIntegrityInitializeInstructions[opts : OptionsPattern[]] := Module[{b},
  If[! iSVIOwnerQ[], Return[iSVINotAuthorized["SourceVaultIntegrityInitializeInstructions", {"OwnerFE", "OwnerCode"}]]];
  b = iSVIReadBaseline[];
  If[AssociationQ[b] && ! TrueQ[OptionValue["Force"]],
    Return[Failure["BaselineExists", <|"AcceptedAtUTC" -> Lookup[b, "AcceptedAtUTC", Null], "Entries" -> Lookup[b, "Count", 0],
      "MessageTemplate" -> "The Instructions baseline already exists; use SourceVaultIntegrityAcceptBaseline[\"Instructions\"] for changes or \"Force\" -> True."|>]]];
  SourceVaultIntegrityAcceptBaseline["Instructions", opts]];

(* ============================================================
   InstructionDrift (service、10 分) と LoadVerify (読込側)
   ============================================================ *)
If[! AssociationQ[$iSVILastDrift], $iSVILastDrift = <||>];
Options[SourceVaultIntegrityInstructionDrift] = {"Publish" -> True};
SourceVaultIntegrityInstructionDrift[OptionsPattern[]] := Module[{baseline, diff, failing = {}, degraded = {}, health, rc, res, pub = TrueQ[OptionValue["Publish"]], changedRows},
  If[! iSVIOwnerServiceQ[], Return[iSVINotAuthorized["SourceVaultIntegrityInstructionDrift", {"OwnerFE", "OwnerCode", "Service"}]]];
  baseline = iSVIReadBaseline[];
  If[! AssociationQ[baseline],
    res = <|"Health" -> "Degraded", "ReasonCode" -> "InstructionBaselineMissing", "Message" -> "Instructions baseline not initialized (SourceVaultIntegrityInitializeInstructions)",
      "Counts" -> <|"Checked" -> Length[SourceVaultInstructionFiles[]], "Changed" -> 0, "New" -> 0, "Missing" -> 0, "Failing" -> 0, "Degraded" -> 0|>,
      "Changed" -> {}, "ComputedAtUTC" -> iSVINowIso[]|>;
    $iSVILastDrift = res; Return[res]];
  diff = iSVIDiff[baseline];
  changedRows = Join[diff["Changed"], diff["New"], diff["Missing"]];
  Scan[Function[row, Which[
      row["Change"] === "Missing" || row["Change"] === "Unreadable", AppendTo[degraded, row],
      row["Group"] === "ModelWritable", AppendTo[failing, row],
      True, AppendTo[degraded, row]]], changedRows];
  health = Which[failing =!= {}, "Failing", degraded =!= {}, "Degraded", True, "OK"];
  rc = Which[
    failing =!= {}, "UnrecordedInstructionChange",
    AnyTrue[degraded, MemberQ[{"Changed", "New"}, #["Change"]] &], "InstructionEditPendingReview",
    degraded =!= {}, "InstructionFileMissing",
    True, "InstructionsOK"];
  If[pub && failing =!= {},
    iSVIFinding["Instructions", "UnrecordedInstructionChange", "High", "Failing", "Targets" -> (#["RelPath"] & /@ failing),
      "Detail" -> <|"Classes" -> Tally[#["Class"] & /@ failing]|>]];
  If[pub && health === "Degraded",
    iSVIFinding["Instructions", rc, "Medium", "Degraded", "Targets" -> (#["RelPath"] & /@ degraded), "Publish" -> False]];
  res = <|"Health" -> health, "ReasonCode" -> rc,
    "Message" -> Switch[health, "Failing", ToString[Length[failing]] <> " model-writable instruction file(s) changed without an owner activity",
      "Degraded", ToString[Length[degraded]] <> " human-edited instruction file(s) changed or missing; review and SourceVaultIntegrityAcceptBaseline[\"Instructions\"]",
      _, "all " <> ToString[diff["Files"]] <> " instruction files match the accepted baseline"],
    "Counts" -> <|"Checked" -> diff["Files"], "Changed" -> Length[diff["Changed"]], "New" -> Length[diff["New"]], "Missing" -> Length[diff["Missing"]],
      "Failing" -> Length[failing], "Degraded" -> Length[degraded], "Baseline" -> Lookup[baseline, "Count", 0]|>,
    "Changed" -> Take[KeyTake[#, {"RelPath", "Group", "Class", "Change"}] & /@ changedRows, UpTo[50]], "ComputedAtUTC" -> iSVINowIso[]|>;
  $iSVILastDrift = res;
  res];

If[! AssociationQ[$iSVILoadVerifyStats], $iSVILoadVerifyStats = <|"Allowed" -> 0, "Warned" -> 0, "Denied" -> 0|>];
(* 2026-11-11 (レビュー 20261111 F01 / F02 / F05):
   - 認可は、索引が使え (再構築中・連鎖の破損でない、iSVIExtrasState)、Scope が読む機と security profile を含み、版がいま隔離中・
     Unknown・確定前でないときだけ Allow にする。以前は BlobId と用途が合えば即 Allow で、認可の後に隔離しても読み込めた。
   - 移行期間の基準一致 ($SourceVaultIntegrityBaselineAsAuthorization) にも隔離・Unknown の条件を掛ける。台帳がある機で索引が
     読めないときの一致は Warn / BaselineMatchUnchecked (Medium、公開しない)。来歴がまだ無い機 (初期導入) は以前どおり Allow。
   - 厳格な設定 (強制あり・移行期間の終了) では基準の欠落を Deny にする。引数の誤りは Deny。 *)
SourceVaultIntegrityLoadVerify[pathIn_String, purposeIn_: "Instruction"] := Module[
  {path = iSVICanonPath[pathIn], purpose = ToString[purposeIn], cls, baseline, entry = None, bid, group, modelQ, enforce, strict, out, auth, xs, ixs, blk},
  cls = iSVIClassifyPath[path];
  If[cls === None, $iSVILoadVerifyStats["Allowed"]++;
    Return[<|"Decision" -> "Allow", "Reason" -> "NotInstruction", "Group" -> Null, "Class" -> Null, "Path" -> path, "BlobId" -> Null, "Baseline" -> Null, "Enforced" -> False|>]];
  group = cls["Group"];
  (* runner manifest は StartService が自分で作り直すので (モデルの書込口ではない) 拒否せず警告に留める。Directives (手編集の群) も警告のみ *)
  modelQ = group === "ModelWritable" && cls["Class"] =!= "RunnerManifest" && purpose =!= "RunnerManifest";
  enforce = modelQ && TrueQ[$SourceVaultIntegrityLoadVerifyEnforce];
  strict = enforce && ! TrueQ[$SourceVaultIntegrityBaselineAsAuthorization];
  baseline = iSVIReadBaselineCached[];
  bid = iSVIFileBlobId[path];
  xs = iSVIExtrasState[]; ixs = xs["State"];
  (* Inc3: 読み込む版の BlobId に、その用途の有効な認可 (ProvAuthorization) があれば Allow (5.4 節)。認可は版に束縛される。
     2026-11-11: 索引が使えるときだけ・Scope が合うものだけを数え、版がいま隔離中・Unknown・確定前なら使わない *)
  auth = If[StringQ[bid], iSVIAuthorizationFor[bid, iSVIPurposeForClass[cls["Class"], purpose], xs], None];
  If[AssociationQ[auth],
    blk = iSVIVersionBlock[bid, Lookup[auth, "EntityId", Null], xs, True];
    If[blk === None,
      $iSVILoadVerifyStats["Allowed"]++;
      Return[<|"Decision" -> "Allow", "Reason" -> "Authorized", "AuthId" -> auth["AuthId"], "Group" -> group, "Class" -> cls["Class"], "Path" -> path,
        "BlobId" -> bid, "Baseline" -> Null, "Enforced" -> enforce, "Purpose" -> purpose, "IndexState" -> ixs|>]];
    out = <|"Decision" -> If[enforce, "Deny", "Warn"], "Reason" -> "AuthorizedVersion" <> blk, "AuthId" -> auth["AuthId"]|>,
    If[AssociationQ[baseline], entry = Lookup[baseline["Entries"], path, None]];
    out = Which[
      ! AssociationQ[baseline], <|"Decision" -> If[strict, "Deny", "Warn"], "Reason" -> "BaselineMissing"|>,
      ! StringQ[bid], <|"Decision" -> If[enforce, "Deny", "Warn"], "Reason" -> "Unreadable"|>,
      (* 受け入れた基準と一致: 手編集の群は Allow。モデルが書き得る群は移行期間 ($SourceVaultIntegrityBaselineAsAuthorization) の間だけ認可の代わり。
         2026-11-11: どちらも、索引が使えれば版がいま隔離中・Unknown でないことを確かめる *)
      AssociationQ[entry] && entry["BlobId"] === bid && (! modelQ || TrueQ[$SourceVaultIntegrityBaselineAsAuthorization]),
        (blk = If[ixs === "OK", iSVIVersionBlock[bid, Lookup[entry, "EntityId", Null], xs, False], None];
         Which[
           StringQ[blk], <|"Decision" -> If[enforce, "Deny", "Warn"], "Reason" -> "BaselineVersion" <> blk|>,
           modelQ && ixs =!= "OK" && TrueQ[xs["Deployed"]], <|"Decision" -> "Warn", "Reason" -> "BaselineMatchUnchecked"|>,
           True, <|"Decision" -> "Allow", "Reason" -> "BaselineMatch"|>]),
      AssociationQ[entry] && entry["BlobId"] === bid, <|"Decision" -> If[enforce, "Deny", "Warn"], "Reason" -> "AuthorizationMissing"|>,
      ! AssociationQ[entry], <|"Decision" -> If[enforce, "Deny", "Warn"], "Reason" -> If[modelQ, "UnauthorizedInstructionLoad", "NotInBaseline"]|>,
      True, <|"Decision" -> If[enforce, "Deny", "Warn"], "Reason" -> If[modelQ, "UnrecordedInstructionChange", "InstructionEditPendingReview"]|>]];
  out = Join[out, <|"Group" -> group, "Class" -> cls["Class"], "Path" -> path, "BlobId" -> If[StringQ[bid], bid, Null],
    "Baseline" -> If[AssociationQ[entry], entry["BlobId"], Null], "Enforced" -> enforce, "Purpose" -> purpose, "IndexState" -> ixs|>];
  Switch[out["Decision"],
    "Deny", $iSVILoadVerifyStats["Denied"]++;
      iSVIFinding["Instructions", "LoadVerify:" <> out["Reason"], "High", "Failing", "Targets" -> {iSVIRelPath[path, iSVICanonPath[ToString @ cls["Root"]]]},
        "Detail" -> <|"Purpose" -> purpose, "Class" -> cls["Class"], "Denied" -> True, "IndexState" -> ixs|>],
    "Warn", $iSVILoadVerifyStats["Warned"]++;
      (* 基準の無い初期化前の Warn は以前どおり Finding にしない。索引が読めないだけの一致は Medium で公開しない *)
      If[out["Reason"] =!= "BaselineMissing",
        With[{loud = modelQ && out["Reason"] =!= "BaselineMatchUnchecked"},
          iSVIFinding["Instructions", "LoadVerify:" <> out["Reason"], If[loud, "High", "Medium"], "Degraded",
            "Targets" -> {iSVIRelPath[path, iSVICanonPath[ToString @ cls["Root"]]]},
            "Detail" -> <|"Purpose" -> purpose, "Class" -> cls["Class"], "Denied" -> False, "IndexState" -> ixs|>, "Publish" -> loud]]],
    _, $iSVILoadVerifyStats["Allowed"]++];
  out];
(* 2026-11-11 (F05): 引数の誤りは読ませない *)
SourceVaultIntegrityLoadVerify[___] := <|"Decision" -> "Deny", "Reason" -> "BadArguments", "Group" -> Null, "Class" -> Null, "Enforced" -> True|>;

(* ============================================================
   検証器 (§7.1) と state.json (§7 冒頭 / §12.1)
   ============================================================ *)
If[! AssociationQ[$iSVITickStats], $iSVITickStats = <|"Count" -> 0, "BudgetExceeded" -> 0, "LastTickAbs" -> Null, "LastTickAtUTC" -> Null, "LastSeconds" -> Null, "LastStatus" -> Null|>];
If[! AssociationQ[$iSVIVerifyCache], $iSVIVerifyCache = <||>];
If[! NumberQ[$iSVILastEmitFailed], $iSVILastEmitFailed = 0];
iSVIStatePath[] := iSVIHealthPath["state.json"];
iSVIProvStatus[] := If[Length[DownValues[SourceVault`SourceVaultProvStatus]] > 0, Quiet @ Check[SourceVault`SourceVaultProvStatus[], <||>], <||>];
iSVIWorst[hs_List] := Which[MemberQ[hs, "Failing"], "Failing", MemberQ[hs, "Degraded"], "Degraded", True, "OK"];

iSVICheckIngest[] := Module[{st = iSVIProvStatus[], meta, emit, lastIngest, age, spoolFiles, spoolBytes, reasons = {}, counts, health, llmq},
  meta = Lookup[st, "Meta", <||>]; If[! AssociationQ[meta], meta = <||>];
  emit = Lookup[st, "Emit", <||>]; If[! AssociationQ[emit], emit = <||>];
  lastIngest = iSVIIsoToAbs[ToString @ Lookup[meta, "LastIngestAtUTC", ""]];
  spoolFiles = Lookup[Lookup[st, "Spool", <||>], "Files", 0]; spoolBytes = Lookup[Lookup[st, "Spool", <||>], "Bytes", 0];
  age = If[NumberQ[lastIngest], AbsoluteTime[] - lastIngest, Null];
  llmq = Lookup[st, "LLMQueue", 0];
  If[Lookup[meta, "ChainState", "OK"] =!= "OK", AppendTo[reasons, "LedgerChainDamaged"]];
  If[Lookup[st, "LedgerMacKeyAvailable", True] === False, AppendTo[reasons, "LedgerMacKeyUnavailable"]];
  If[IntegerQ[spoolFiles] && spoolFiles > 0 && IntegerQ[spoolBytes] && spoolBytes > 0 && (! NumberQ[age] || age > 3600), AppendTo[reasons, "IngestDelayed"]];
  If[TrueQ[Lookup[meta, "CarryOver", False]], AppendTo[reasons, "IngestCarriedOver"]];
  (* emit の失敗は前回の検査からの増分で見る (カーネルの累計のままだと 1 回の失敗で Degraded が戻らない)。累計は Counts に出す *)
  If[Lookup[emit, "Failed", 0] > $iSVILastEmitFailed, AppendTo[reasons, "EmitFailures"]];
  $iSVILastEmitFailed = Lookup[emit, "Failed", 0];
  If[IntegerQ[spoolBytes] && spoolBytes > 1024^3, AppendTo[reasons, "SpoolBacklog"]];
  (* Inc1b: feeds (PrivateVault) に書けない。checkpoint は手元に書けているが、写しと射影が他機に届かない *)
  With[{fs = If[Length[DownValues[SourceVault`SourceVaultProvFeedStatus]] > 0, Quiet @ Check[SourceVault`SourceVaultProvFeedStatus[], Missing[]], Missing[]]},
    If[AssociationQ[fs] && MemberQ[{"FeedUnavailable"}, Lookup[fs, "Status", ""]] || (AssociationQ[fs] && TrueQ[Lookup[Lookup[fs, "Own", <||>], "WriteFailed", False]]),
      AppendTo[reasons, "FeedsUnavailable"]]];
  health = Which[MemberQ[reasons, "LedgerChainDamaged"], "Failing", reasons =!= {}, "Degraded", True, "OK"];
  counts = <|"SpoolFiles" -> spoolFiles, "SpoolBytes" -> spoolBytes, "IngestAgeSeconds" -> If[NumberQ[age], Round[age], Null],
    "Corrupt" -> Lookup[Lookup[meta, "Counts", <||>], "Corrupt", 0], "EmitFailed" -> Lookup[emit, "Failed", 0], "EmitSlow" -> Lookup[emit, "Slow", 0],
    "Pending" -> Lookup[meta, "PendingCount", 0], "LLMQueue" -> llmq, "DurableSeq" -> Lookup[meta, "DurableSeq", 0], "IndexSeq" -> Lookup[meta, "IndexSeq", 0]|>;
  <|"Health" -> health, "ReasonCode" -> If[reasons === {}, "IngestOK", First[reasons]], "Reasons" -> reasons, "Counts" -> counts|>];

(* Chain (§7.1): 前回の checkpoint 以降の連鎖と MAC。台帳全体の検証は 15 万行で 3 分かかる (2026-11-09 実測) ので、service の tick では
   「最新より 1 つ前の checkpoint の LastSeq 以降」だけを見る (その行の LineHash が checkpoint と合うことも確かめる)。前の checkpoint が無い・
   遠すぎるときは末尾 $iSVIChainMaxLines 行に絞る (Counts の FromSeq / Clamped に出す)。全体の検証は所有者が SourceVaultProvVerifyLedger[] で行う *)
If[! IntegerQ[$iSVIChainMaxLines], $iSVIChainMaxLines = 20000];
iSVIChainSince[] := Module[{meta, durable, cps, prev, since, clamped = False},
  meta = If[Length[DownValues[SourceVault`ProvenancePrivate`iProvReadMeta]] > 0, Quiet @ Check[SourceVault`ProvenancePrivate`iProvReadMeta[], $Failed], $Failed];
  durable = If[AssociationQ[meta], Lookup[meta, "DurableSeq", 0], 0];
  cps = If[Length[DownValues[SourceVault`ProvenancePrivate`iProvCheckpointFiles]] > 0,
    Select[Lookup[#, "LastSeq", None] & /@ Select[iSVIReadJSON /@ SourceVault`ProvenancePrivate`iProvCheckpointFiles[], AssociationQ], IntegerQ[#] && # < durable &], {}];
  prev = If[cps === {}, 0, Max[cps]];
  since = Max[1, prev];
  If[durable - since > $iSVIChainMaxLines, since = durable - $iSVIChainMaxLines; clamped = True];
  <|"Since" -> since, "Clamped" -> clamped, "DurableSeq" -> durable, "PreviousCheckpointSeq" -> prev|>];
iSVICheckChain[] := Module[{v, status, findings, sc, fs, peerFail, ownFail},
  If[Length[DownValues[SourceVault`SourceVaultProvVerifyLedger]] === 0, Return[<|"Health" -> "OK", "ReasonCode" -> "NotApplicable"|>]];
  sc = iSVIChainSince[];
  v = Quiet @ Check[If[sc["Since"] <= 1, SourceVault`SourceVaultProvVerifyLedger[], SourceVault`SourceVaultProvVerifyLedger["Since" -> sc["Since"]]], $Failed];
  If[FailureQ[v] || ! AssociationQ[v], Return[<|"Health" -> "Degraded", "ReasonCode" -> "ChainVerifyFailed", "Counts" -> <|"Error" -> ToString[If[FailureQ[v], First[v], v]]|>|>]];
  status = Lookup[v, "Status", "Inconclusive"];
  findings = Select[Lookup[v, "Findings", {}], ! MemberQ[{"ChainRestart", "CheckpointSuperseded"}, Lookup[#, "Kind", ""]] &];
  (* Inc1b: 直近の feeds の同期で見つかった他機の写しの食い違い・巻き戻し (自機の台帳の検証とは別に数える) *)
  fs = If[Length[DownValues[SourceVault`SourceVaultProvFeedStatus]] > 0, Quiet @ Check[SourceVault`SourceVaultProvFeedStatus[], Missing[]], Missing[]];
  peerFail = If[AssociationQ[fs], Select[Lookup[fs, "Findings", {}], AssociationQ[#] && Lookup[#, "Health", ""] === "Failing" && StringStartsQ[ToString @ Lookup[#, "Kind", ""], "Peer"] &], {}];
  ownFail = If[AssociationQ[fs], Select[Lookup[fs, "Findings", {}], AssociationQ[#] && Lookup[#, "Health", ""] === "Failing" && ! StringStartsQ[ToString @ Lookup[#, "Kind", ""], "Peer"] &], {}];
  <|"Health" -> Which[status === "Failing" || ownFail =!= {} || peerFail =!= {}, "Failing", status === "OK", "OK", True, "Degraded"],
    "ReasonCode" -> Which[status === "Failing" || ownFail =!= {}, "LedgerTamperOrCorruption", peerFail =!= {}, "PeerFeedTamperOrCorruption",
      status === "OK", "ChainOK", True, "ChainInconclusive"],
    "Counts" -> <|"Lines" -> Lookup[Lookup[v, "Verified", <||>], "Lines", 0], "ToSeq" -> Lookup[Lookup[v, "Verified", <||>], "ToSeq", Null],
      "MacChecked" -> Lookup[Lookup[v, "Verified", <||>], "MacChecked", 0], "KeyUnavailable" -> Lookup[Lookup[v, "Verified", <||>], "KeyUnavailable", 0],
      "Findings" -> Length[findings], "FindingKinds" -> Tally[Lookup[#, "Kind", "?"] & /@ findings],
      "FromSeq" -> Lookup[Lookup[v, "Verified", <||>], "FromSeq", Null], "Clamped" -> sc["Clamped"], "PreviousCheckpointSeq" -> sc["PreviousCheckpointSeq"],
      "MerkleChecked" -> Lookup[Lookup[v, "Verified", <||>], "MerkleChecked", 0], "FeedCheckpoints" -> Lookup[Lookup[v, "Verified", <||>], "FeedCheckpoints", 0],
      "PeerWitnesses" -> Lookup[Lookup[v, "Verified", <||>], "PeerWitnesses", 0],
      "FeedSyncFindings" -> Length[ownFail], "PeerFindings" -> Length[peerFail], "PeerFindingKinds" -> Tally[Lookup[#, "Kind", "?"] & /@ peerFail],
      "FeedsSyncedAtUTC" -> If[AssociationQ[fs], Lookup[fs, "AtUTC", Null], Null]|>,
    "Assurance" -> Lookup[v, "Assurance", Null]|>];

iSVICheckCoverage[] := Module[{c, ratio, byKind, critical, health, rc, sp, outside},
  If[Length[DownValues[SourceVault`SourceVaultProvCoverage]] === 0, Return[<|"Health" -> "OK", "ReasonCode" -> "NotApplicable"|>]];
  c = Quiet @ Check[SourceVault`SourceVaultProvCoverage[7], $Failed];
  If[! AssociationQ[c], Return[<|"Health" -> "Degraded", "ReasonCode" -> "CoverageComputeFailed"|>]];
  (* 2026-11-11 (レビュー 20261111 F07): 総率 (Total / Ratio) は Instruction を除く派生だけ (SourceVaultProvCoverage)。Instruction の
     基準の充足は ByKind / "Instruction" で、供給点を通った派生 (SessionKey つきの LLMGenerate) の率は "SupplyPoint"、供給点の外の
     LLM 派生 (SessionKey が無い CLI・外部実行器・service 内部の経路) の件数は "OutsideSupplyPoints" で別に見る。
     Instruction / DerivedCode < 0.99 は Failing、総率 < 0.9・供給点の率 < 0.9・供給点の外の LLM 派生ありは Degraded *)
  byKind = Lookup[c, "ByKind", <||>];
  critical = Select[KeyTake[byKind, {"Instruction", "DerivedCode"}], NumberQ[Lookup[#, "Ratio", Null]] && #["Ratio"] < 0.99 &];
  sp = Lookup[c, "SupplyPoint", <||>]; If[! AssociationQ[sp], sp = <||>];
  outside = Lookup[c, "OutsideSupplyPoints", <||>]; If[! AssociationQ[outside], outside = <||>];
  If[critical === <||> && Lookup[c, "Total", 0] === 0,
    Return[<|"Health" -> "OK", "ReasonCode" -> "NotApplicable", "Counts" -> <|"Total" -> 0, "UnrecordedLLMDerivations" -> Lookup[c, "UnrecordedLLMDerivations", 0],
      "Backfilled" -> Lookup[c, "Backfilled", 0], "Instruction" -> Lookup[c, "Instruction", Lookup[byKind, "Instruction", Null]]|>|>]];
  ratio = Lookup[c, "Ratio", 0.];
  health = Which[critical =!= <||>, "Failing",
    (NumberQ[ratio] && ratio < 0.9) || (NumberQ[Lookup[sp, "Ratio", Null]] && sp["Ratio"] < 0.9) || Lookup[outside, "LLMWithoutSessionKey", 0] > 0, "Degraded",
    True, "OK"];
  rc = Which[critical =!= <||>, "ProvenanceCoverageLowCritical",
    NumberQ[ratio] && ratio < 0.9, "ProvenanceCoverageLow",
    NumberQ[Lookup[sp, "Ratio", Null]] && sp["Ratio"] < 0.9, "SupplyPointCoverageLow",
    Lookup[outside, "LLMWithoutSessionKey", 0] > 0, "DerivationsOutsideSupplyPoints",
    True, "CoverageOK"];
  <|"Health" -> health, "ReasonCode" -> rc,
    "Counts" -> <|"Total" -> c["Total"], "Complete" -> c["Complete"], "Ratio" -> ratio, "WindowDays" -> 7,
      "ByKind" -> Map[KeyTake[#, {"Total", "Complete", "Ratio"}] &, byKind],
      "SupplyPoint" -> KeyTake[sp, {"Total", "Complete", "Ratio"}], "OutsideSupplyPoints" -> outside,
      "Instruction" -> Lookup[c, "Instruction", Lookup[byKind, "Instruction", Null]],
      "UnrecordedLLMDerivations" -> Lookup[c, "UnrecordedLLMDerivations", 0], "Backfilled" -> Lookup[c, "Backfilled", 0]|>|>];

iSVIHeartbeat[] := Module[{st = iSVIProvStatus[], meta, rebuilt, rebuiltAge, lastTick, tickAge, reasons = {}, health},
  meta = Lookup[st, "Meta", <||>]; If[! AssociationQ[meta], meta = <||>];
  rebuilt = iSVIIsoToAbs[ToString @ Lookup[meta, "RebuiltAtUTC", ""]];
  rebuiltAge = If[NumberQ[rebuilt], Round[AbsoluteTime[] - rebuilt], Null];
  lastTick = Lookup[$iSVITickStats, "LastTickAbs", Null];
  tickAge = If[NumberQ[lastTick], Round[AbsoluteTime[] - lastTick], Null];
  If[NumberQ[tickAge] && tickAge > 900, AppendTo[reasons, "ServiceTickStalled"]];
  If[Lookup[$iSVITickStats, "BudgetExceeded", 0] > 0 && Lookup[$iSVITickStats, "Count", 0] > 0 &&
     Lookup[$iSVITickStats, "BudgetExceeded", 0] > 0.5 Lookup[$iSVITickStats, "Count", 0], AppendTo[reasons, "TickBudgetExceeded"]];
  If[TrueQ[Lookup[meta, "Rebuilding", False]], AppendTo[reasons, "IndexRebuilding"]];
  health = Which[MemberQ[reasons, "ServiceTickStalled"], "Failing", reasons =!= {}, "Degraded", True, "OK"];
  <|"Health" -> health, "ReasonCode" -> If[reasons === {}, "HeartbeatOK", First[reasons]],
    "Counts" -> <|"TickCount" -> Lookup[$iSVITickStats, "Count", 0], "BudgetExceeded" -> Lookup[$iSVITickStats, "BudgetExceeded", 0],
      "LastTickAtUTC" -> Lookup[$iSVITickStats, "LastTickAtUTC", Null], "TickAgeSeconds" -> tickAge, "LastTickSeconds" -> Lookup[$iSVITickStats, "LastSeconds", Null],
      "RebuildAgeSeconds" -> rebuiltAge, "EmitFailed" -> Lookup[Lookup[st, "Emit", <||>], "Failed", 0], "EmitSlow" -> Lookup[Lookup[st, "Emit", <||>], "Slow", 0],
      "FindingsRecorded" -> $iSVIFindingStats["Recorded"], "FindingsPublished" -> $iSVIFindingStats["Published"],
      "LoadVerify" -> $iSVILoadVerifyStats|>|>];

Options[SourceVaultIntegrityVerifiers] = {"Force" -> False, "BudgetSeconds" -> 10};
SourceVaultIntegrityVerifiers[OptionsPattern[]] := Module[
  {t0 = AbsoluteTime[], force = TrueQ[OptionValue["Force"]], budget, ingest, chain, coverage, hb, drift, provHealth, provRc, prov, state, interval, due, meta, st, comps, prevFindings,
   instrUse, registry, policy, inc4},
  If[! iSVIOwnerServiceQ[], Return[iSVINotAuthorized["SourceVaultIntegrityVerifiers", {"OwnerFE", "OwnerCode", "Service"}]]];
  If[iSVIHealthDir[] === $Failed, Return[Failure["ProvLocalStateUnresolved", <||>]]];
  budget = If[NumberQ[OptionValue["BudgetSeconds"]], OptionValue["BudgetSeconds"], 10];
  interval = $SourceVaultIntegrityVerifyIntervalSeconds;
  ingest = iSVICheckIngest[];
  due = force || ! NumberQ[Lookup[$iSVIVerifyCache, "At", None]] || AbsoluteTime[] - $iSVIVerifyCache["At"] > interval;
  If[due && AbsoluteTime[] - t0 < budget,
    chain = iSVICheckChain[];
    coverage = iSVICheckCoverage[];
    $iSVIVerifyCache = <|"At" -> AbsoluteTime[], "Chain" -> chain, "Coverage" -> coverage|>,
    chain = Lookup[$iSVIVerifyCache, "Chain", <|"Health" -> "OK", "ReasonCode" -> "NotYetVerified"|>];
    coverage = Lookup[$iSVIVerifyCache, "Coverage", <|"Health" -> "OK", "ReasonCode" -> "NotYetVerified"|>]];
  hb = iSVIHeartbeat[];
  drift = If[$iSVILastDrift === <||>, <|"Health" -> "OK", "ReasonCode" -> "NotYetChecked", "Counts" -> <||>|>, $iSVILastDrift];
  (* Inc4: 決定的検証器 (Integrity / Models / Egress)。周期は各検査ごと (iSVIRunInc4Checks)、"Force" -> True で全部 *)
  inc4 = Quiet @ Check[iSVIRunInc4Checks[force, Max[2, budget - (AbsoluteTime[] - t0)]], <||>];
  (* Inc3: Instructions = drift + 命令使用の認可 + Registry、Policy = SecurityProfile の digest (このカーネルの役割の基準) *)
  instrUse = Quiet @ Check[iSVICheckInstructionUse[], <|"Health" -> "Degraded", "ReasonCode" -> "InstructionUseCheckFailed"|>];
  registry = Quiet @ Check[iSVICheckRegistry[], <|"Health" -> "Degraded", "ReasonCode" -> "RegistryCheckFailed"|>];
  policy = Quiet @ Check[iSVIPolicyCheck[], <|"Health" -> "Degraded", "ReasonCode" -> "PolicyCheckFailed"|>];
  provHealth = iSVIWorst[{ingest["Health"], chain["Health"], coverage["Health"]}];
  provRc = Which[chain["Health"] === "Failing", chain["ReasonCode"], coverage["Health"] === "Failing", coverage["ReasonCode"],
    ingest["Health"] =!= "OK", ingest["ReasonCode"], chain["Health"] =!= "OK", chain["ReasonCode"], coverage["Health"] =!= "OK", coverage["ReasonCode"], True, "ProvenanceOK"];
  (* Failing の Finding (Chain の改ざん・Coverage の重大な不足) は診断 spool へ *)
  If[chain["Health"] === "Failing", iSVIFinding["Provenance", chain["ReasonCode"], "Critical", "Failing", "Detail" -> KeyTake[chain, {"Counts", "Assurance"}]]];
  If[coverage["Health"] === "Failing", iSVIFinding["Provenance", coverage["ReasonCode"], "High", "Failing", "Detail" -> KeyTake[coverage, {"Counts"}]]];
  If[ingest["Health"] === "Failing", iSVIFinding["Provenance", ingest["ReasonCode"], "High", "Failing", "Detail" -> KeyTake[ingest, {"Counts"}]]];
  If[hb["Health"] === "Failing", iSVIFinding["MonitorSelf", hb["ReasonCode"], "High", "Failing", "Detail" -> KeyTake[hb, {"Counts"}]]];
  st = iSVIProvStatus[]; meta = Lookup[st, "Meta", <||>]; If[! AssociationQ[meta], meta = <||>];
  prov = <|"Health" -> provHealth, "ReasonCode" -> provRc,
    "Message" -> Switch[provHealth, "OK", "provenance ledger ingest, chain and coverage are within limits",
      _, "provenance: " <> provRc <> " (ingest " <> ingest["Health"] <> ", chain " <> chain["Health"] <> ", coverage " <> coverage["Health"] <> ")"],
    "Counts" -> Join[Lookup[ingest, "Counts", <||>],
      <|"CoverageRatio" -> Lookup[Lookup[coverage, "Counts", <||>], "Ratio", Null], "CoverageTotal" -> Lookup[Lookup[coverage, "Counts", <||>], "Total", Null],
        "UnrecordedLLMDerivations" -> Lookup[Lookup[coverage, "Counts", <||>], "UnrecordedLLMDerivations", 0],
        "ChainFindings" -> Lookup[Lookup[chain, "Counts", <||>], "Findings", 0]|>],
    "Checks" -> <|"Ingest" -> ingest, "Chain" -> chain, "Coverage" -> coverage|>|>;
  comps = <|"Provenance" -> prov,
    "MonitorSelf" -> <|"Health" -> hb["Health"], "ReasonCode" -> hb["ReasonCode"],
      "Message" -> If[hb["Health"] === "OK", "service tick and verifiers are running", "monitor: " <> hb["ReasonCode"]], "Counts" -> hb["Counts"]|>,
    "Instructions" -> With[{h = iSVIWorst[{Lookup[drift, "Health", "OK"], instrUse["Health"], registry["Health"]}]},
      <|"Health" -> h,
        "ReasonCode" -> Which[instrUse["Health"] === "Failing", instrUse["ReasonCode"], registry["Health"] === "Failing", registry["ReasonCode"],
          Lookup[drift, "Health", "OK"] =!= "OK", Lookup[drift, "ReasonCode", "?"], registry["Health"] =!= "OK", registry["ReasonCode"],
          instrUse["Health"] =!= "OK", instrUse["ReasonCode"], True, Lookup[drift, "ReasonCode", "NotYetChecked"]],
        "Message" -> Which[instrUse["Health"] === "Failing", "an instruction input was used without a valid authorization (UnauthorizedInstructionUse)",
          registry["Health"] === "Failing", "a label record (authorization / release / resolution / verifier) failed the owner ticket check (RegistryTampered)",
          True, Lookup[drift, "Message", "instruction drift not checked yet"]],
        "Counts" -> Join[Lookup[drift, "Counts", <||>], <|"UnauthorizedUses" -> Lookup[Lookup[instrUse, "Counts", <||>], "UnauthorizedNow", 0],
          "RegistryIssues" -> Lookup[Lookup[registry, "Counts", <||>], "Issues", 0], "RegistryAttempts" -> Lookup[Lookup[registry, "Counts", <||>], "Attempts", 0]|>],
        "Changed" -> Lookup[drift, "Changed", {}], "ComputedAtUTC" -> Lookup[drift, "ComputedAtUTC", Null],
        "Checks" -> <|"Drift" -> KeyTake[drift, {"Health", "ReasonCode", "Counts"}], "InstructionAuthorization" -> instrUse, "Registry" -> registry|>|>],
    "Policy" -> policy,
    (* Inc4: 残りの部品は watched に加えない (Inc5)。state.json と View で見る *)
    "Integrity" -> iSVIComponentOf["Integrity", KeyTake[inc4, {"EntityDrift", "InjectionResidue", "CitationIntegrity", "GeneratedCodeHealth"}]],
    "Models" -> iSVIComponentOf["Models", KeyTake[inc4, {"LMStudioMCPScope", "ModelManifest"}]],
    "Egress" -> iSVIComponentOf["Egress", KeyTake[inc4, {"EgressPattern", "PublishUnusable"}]],
    (* Inc5: KnowledgeHealth (Contamination・FeedbackLoop・ReviewDebt・Indicators、指標と KHI の参考値つき) *)
    "KnowledgeHealth" -> Lookup[inc4, "KnowledgeHealth", <|"Health" -> "OK", "ReasonCode" -> "NotYetRun"|>]|>;
  state = <|"Format" -> "SourceVaultIntegrityState/1", "ComputedAtUTC" -> iSVINowIso[], "ObservedSeq" -> Lookup[meta, "DurableSeq", 0],
    "IndexSeq" -> Lookup[meta, "IndexSeq", 0], "Machine" -> If[Length[DownValues[SourceVault`SourceVaultMachineTag]] > 0, SourceVault`SourceVaultMachineTag[], $MachineName],
    "Principal" -> iSVIPrincipalKind[], "Components" -> comps,
    "Tick" -> KeyTake[$iSVITickStats, {"Count", "BudgetExceeded", "LastTickAtUTC", "LastSeconds", "LastStatus"}],
    "LastFullVerifyAtUTC" -> With[{a = Lookup[$iSVIVerifyCache, "At", Null]}, If[NumberQ[a], DateString[a, {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"}, TimeZone -> 0], Null]],
    "Seconds" -> AbsoluteTime[] - t0|>;
  iSVIWriteJSON[iSVIStatePath[], state];
  $iSVIStateCache = <||>;
  state];

If[! AssociationQ[$iSVIStateCache], $iSVIStateCache = <||>];
SourceVaultIntegrityState[] := Module[{p = iSVIStatePath[], now = AbsoluteTime[], s},
  If[p === $Failed, Return[Missing["LocalStateUnresolved"]]];
  If[AssociationQ[Lookup[$iSVIStateCache, "State", None]] && now - Lookup[$iSVIStateCache, "At", 0] < 2, Return[$iSVIStateCache["State"]]];
  s = iSVIReadJSON[p];
  If[! AssociationQ[s] || Lookup[s, "Format", ""] =!= "SourceVaultIntegrityState/1", Return[Missing["NotFound"]]];
  $iSVIStateCache = <|"State" -> s, "At" -> now|>;
  s];

SourceVaultIntegrityProbe[comp_String] := Module[{s, at, age, c, maxAge},
  If[! TrueQ[$iSVINBHookRegistered], Quiet @ iSVIRegisterNBAccessHook[]];
  (* Inc3: Policy は設定を持つカーネル (FE / service) ごとに違うので、state.json でなくこのカーネルでその場で比べる (項目の digest だけ、< 0.1 秒) *)
  If[comp === "Policy",
    Return[With[{p = Quiet @ Check[iSVIPolicyCheck[], <|"Health" -> "Degraded", "ReasonCode" -> "PolicyCheckFailed"|>]},
      <|"Component" -> "Policy", "Health" -> Lookup[p, "Health", "Degraded"], "ReasonCode" -> Lookup[p, "ReasonCode", "?"],
        "Message" -> ToString @ Lookup[p, "Message", "Policy"], "Counts" -> Lookup[p, "Counts", <||>], "FindingIds" -> {},
        "StateAsOfUTC" -> iSVINowIso[], "StateAgeSeconds" -> 0|>]]];
  s = SourceVaultIntegrityState[];
  If[! AssociationQ[s],
    Return[<|"Component" -> comp, "Health" -> "OK", "ReasonCode" -> "NotApplicable",
      "Message" -> "no integrity state on this machine (the service verifiers have not written state.json)", "Counts" -> <||>, "FindingIds" -> {},
      "StateAsOfUTC" -> Null, "StateAgeSeconds" -> Null|>]];
  at = iSVIIsoToAbs[ToString @ Lookup[s, "ComputedAtUTC", ""]];
  age = If[NumberQ[at], Round[AbsoluteTime[] - at], Null];
  maxAge = If[NumberQ[$SourceVaultIntegrityStateMaxAge], $SourceVaultIntegrityStateMaxAge, 3600];
  c = Lookup[Lookup[s, "Components", <||>], comp, <||>];
  If[! AssociationQ[c], c = <||>];
  Which[
    comp === "MonitorSelf" && (! NumberQ[age] || age > 900),
      <|"Component" -> comp, "Health" -> "Failing", "ReasonCode" -> "ServiceTickStalled",
        "Message" -> "the service integrity tick has not written state.json for " <> ToString[age] <> " s (limit 900 s)",
        "Counts" -> Lookup[c, "Counts", <||>], "FindingIds" -> {}, "StateAsOfUTC" -> Lookup[s, "ComputedAtUTC", Null], "StateAgeSeconds" -> age|>,
    ! NumberQ[age] || age > maxAge,
      <|"Component" -> comp, "Health" -> "Degraded", "ReasonCode" -> "IntegrityStateStale",
        "Message" -> "state.json is " <> ToString[age] <> " s old (limit " <> ToString[maxAge] <> " s); the verdict is not current",
        "Counts" -> Lookup[c, "Counts", <||>], "FindingIds" -> {}, "StateAsOfUTC" -> Lookup[s, "ComputedAtUTC", Null], "StateAgeSeconds" -> age|>,
    c === <||>,
      <|"Component" -> comp, "Health" -> "OK", "ReasonCode" -> "NotApplicable", "Message" -> "component not present in state.json",
        "Counts" -> <||>, "FindingIds" -> {}, "StateAsOfUTC" -> Lookup[s, "ComputedAtUTC", Null], "StateAgeSeconds" -> age|>,
    True,
      <|"Component" -> comp, "Health" -> With[{h = Lookup[c, "Health", "OK"]}, If[MemberQ[{"OK", "Degraded", "Failing"}, h], h, "Degraded"]],
        "ReasonCode" -> ToString @ Lookup[c, "ReasonCode", "?"], "Message" -> ToString @ Lookup[c, "Message", comp],
        "Counts" -> Lookup[c, "Counts", <||>], "FindingIds" -> {}, "StateAsOfUTC" -> Lookup[s, "ComputedAtUTC", Null], "StateAgeSeconds" -> age|>]];
SourceVaultIntegrityProbe[___] := <|"Health" -> "OK", "ReasonCode" -> "NotApplicable"|>;

SourceVaultIntegrityRegisterProbes[] := If[Length[DownValues[SourceVault`SourceVaultDiagnosticsRegisterProbe]] > 0,
  Quiet @ SourceVault`SourceVaultDiagnosticsRegisterProbe["Provenance", Function[SourceVaultIntegrityProbe["Provenance"]]];
  Quiet @ SourceVault`SourceVaultDiagnosticsRegisterProbe["MonitorSelf", Function[SourceVaultIntegrityProbe["MonitorSelf"]]];
  (* Inc3 (2026-11-10): Instructions と Policy を加える (7 章: Inc3 で watched に) *)
  Quiet @ SourceVault`SourceVaultDiagnosticsRegisterProbe["Instructions", Function[SourceVaultIntegrityProbe["Instructions"]]];
  Quiet @ SourceVault`SourceVaultDiagnosticsRegisterProbe["Policy", Function[SourceVaultIntegrityProbe["Policy"]]];
  (* Inc4: Integrity / Models / Egress は probe だけ登録 (表に出す)。watched には Inc5 で加える *)
  Quiet @ SourceVault`SourceVaultDiagnosticsRegisterProbe["Integrity", Function[SourceVaultIntegrityProbe["Integrity"]]];
  Quiet @ SourceVault`SourceVaultDiagnosticsRegisterProbe["Models", Function[SourceVaultIntegrityProbe["Models"]]];
  Quiet @ SourceVault`SourceVaultDiagnosticsRegisterProbe["Egress", Function[SourceVaultIntegrityProbe["Egress"]]];
  Quiet @ SourceVault`SourceVaultDiagnosticsRegisterProbe["KnowledgeHealth", Function[SourceVaultIntegrityProbe["KnowledgeHealth"]]];
  <|"Status" -> "Registered", "Probes" -> {"Provenance", "MonitorSelf", "Instructions", "Policy", "Integrity", "Models", "Egress", "KnowledgeHealth"}|>,
  <|"Status" -> "DiagnosticsAbsent"|>];

(* ============================================================
   service tick (Inc1a 本体、Inc2 で結合・drift・検証器を追加): Ingest → adapter → join → drift → verifiers → checkpoint
   ============================================================ *)
If[! NumberQ[$iSVILastDriftAbs], $iSVILastDriftAbs = 0];
(* Inc1b: feeds の同期は checkpoint を書いたときか 300 秒ごと (他機の写しの照合を含む) *)
If[! NumberQ[$iSVILastFeedsAbs], $iSVILastFeedsAbs = 0];
$iSVIFeedsIntervalSeconds = 300;
(* V4 (文書 12 §3.3 の L3、2026-11-13): 行き先の評判のリスト (webguard) の更新を見る間隔 *)
If[! NumberQ[$iSVILastReputationAbs], $iSVILastReputationAbs = 0];
$iSVIReputationIntervalSeconds = 3600;
(* 期限の半分を過ぎたリストを 1 回に 1 つ取り直す (弱結合。webguard が無ければ何もしない)。取りに行く先は設定の固定の URL だけ。
   大きい上位サイト表 (約 10 MB) の回は、この tick が予算を超えることがある (半月に 1 回)。見る時期でなければ Null *)
iSVIReputationTick[] := If[Length[DownValues[SourceVault`SourceVaultWebReputationUpdate]] > 0 &&
    AbsoluteTime[] - $iSVILastReputationAbs > $iSVIReputationIntervalSeconds,
  $iSVILastReputationAbs = AbsoluteTime[];
  Quiet @ Check[SourceVault`SourceVaultWebReputationUpdate["MaxSources" -> 1], Failure["ReputationUpdateError", <||>]],
  Null];
iSVIReputationView[r_] := Which[r === Null, <|"Status" -> "NotDue"|>, AssociationQ[r], KeyTake[r, {"Updated", "Failed"}], True, r];
(* V7 (文書 12 の 7.2 節、2026-11-13): 方針の提案 (webguard)。1 時間に 1 回、関所の記録を集計し直す (弱結合。通信はしない)。
   FE が動いていなくても、期限の来た提案の取り下げと、翌日に回した提案の提示が進む *)
If[! NumberQ[$iSVILastProposalsAbs], $iSVILastProposalsAbs = 0];
$iSVIProposalsIntervalSeconds = 3600;
iSVIProposalsTick[] := If[Length[DownValues[SourceVault`SourceVaultPolicyProposalsRefresh]] > 0 &&
    AbsoluteTime[] - $iSVILastProposalsAbs > $iSVIProposalsIntervalSeconds,
  $iSVILastProposalsAbs = AbsoluteTime[];
  Quiet @ Check[SourceVault`SourceVaultPolicyProposalsRefresh[], Failure["PolicyProposalsRefreshError", <||>]],
  Null];
iSVIProposalsView[r_] := Which[r === Null, <|"Status" -> "NotDue"|>,
  AssociationQ[r], KeyTake[r, {"Created", "Presented", "Withdrawn", "Open", "Deferred"}], True, r];
Options[SourceVaultIntegrityServiceTick] = {"BudgetSeconds" -> 20};
SourceVaultIntegrityServiceTick[OptionsPattern[]] := Module[{t0 = AbsoluteTime[], budget, kind, ingest, adapters, join = Null, drift = Null, ver = Null, cp = Null, feeds = Null, remaining, status,
    reputation = Null},
  budget = OptionValue["BudgetSeconds"];
  If[! NumberQ[budget] || budget <= 0, budget = 20];
  kind = Quiet @ Check[SourceVault`SourceVaultPrincipal["Kind"], "Model"];
  If[! MemberQ[{"Service", "OwnerFE", "OwnerCode"}, kind],
    Return[Failure["ProvNotAuthorized", <|"Function" -> "SourceVaultIntegrityServiceTick", "Principal" -> kind,
      "Allowed" -> {"OwnerFE", "OwnerCode", "Service"},
      "MessageTemplate" -> "SourceVaultIntegrityServiceTick runs only in the service kernel (or for the owner); the current principal is `1`.",
      "MessageParameters" -> {kind}|>]]];
  If[Length[DownValues[SourceVault`SourceVaultProvIngestSpool]] === 0,
    (* 来歴の層が無くても、評判のリストの更新は行う (V4) *)
    reputation = iSVIReputationTick[];
    Return[<|"Status" -> "ProvenanceUnavailable", "Reputation" -> iSVIReputationView[reputation],
      "Proposals" -> iSVIProposalsView[iSVIProposalsTick[]], "Seconds" -> AbsoluteTime[] - t0|>]];
  ingest = Quiet @ Check[SourceVault`SourceVaultProvIngestSpool["BudgetSeconds" -> 0.5 budget], Failure["ProvIngestError", <||>]];
  remaining = budget - (AbsoluteTime[] - t0);
  adapters = If[remaining > 4 && Length[DownValues[SourceVault`SourceVaultProvIngestAdapters]] > 0,
    Quiet @ Check[SourceVault`SourceVaultProvIngestAdapters["BudgetSeconds" -> 0.5 (remaining - 2)], Failure["ProvAdapterError", <||>]],
    <|"Status" -> "Skipped"|>];
  remaining = budget - (AbsoluteTime[] - t0);
  If[remaining > 2 && Length[DownValues[SourceVault`SourceVaultProvJoinLLMCalls]] > 0,
    join = Quiet @ Check[SourceVault`SourceVaultProvJoinLLMCalls["BudgetSeconds" -> Min[3, remaining - 1]], Failure["ProvJoinError", <||>]]];
  remaining = budget - (AbsoluteTime[] - t0);
  If[remaining > 3 && AbsoluteTime[] - $iSVILastDriftAbs > $SourceVaultIntegrityDriftIntervalSeconds,
    drift = Quiet @ Check[SourceVaultIntegrityInstructionDrift[], Failure["DriftError", <||>]];
    $iSVILastDriftAbs = AbsoluteTime[]];
  remaining = budget - (AbsoluteTime[] - t0);
  (* Inc1b: checkpoint は 1,000 行・1 時間のどちらか早い方 (Periodic)。サービス停止時は servicemanager が ServiceStop を書く *)
  If[AbsoluteTime[] - t0 < budget && Length[DownValues[SourceVault`SourceVaultProvCheckpoint]] > 0,
    cp = Quiet @ Check[SourceVault`SourceVaultProvCheckpoint["Reason" -> "Periodic"], Failure["ProvCheckpointError", <||>]]];
  remaining = budget - (AbsoluteTime[] - t0);
  If[remaining > 2 && Length[DownValues[SourceVault`SourceVaultProvSyncFeeds]] > 0 &&
      ((AssociationQ[cp] && Lookup[cp, "Status", ""] === "Written") || AbsoluteTime[] - $iSVILastFeedsAbs > $iSVIFeedsIntervalSeconds),
    feeds = Quiet @ Check[SourceVault`SourceVaultProvSyncFeeds[], Failure["ProvFeedsError", <||>]];
    $iSVILastFeedsAbs = AbsoluteTime[]];
  status = Which[
    FailureQ[ingest], "IngestFailed",
    AssociationQ[ingest] && Lookup[ingest, "Status", ""] === "CarriedOver", "CarriedOver",
    AssociationQ[adapters] && Lookup[adapters, "Status", ""] === "CarriedOver", "CarriedOver",
    AssociationQ[join] && Lookup[join, "Status", ""] === "CarriedOver", "CarriedOver",
    True, "OK"];
  (* heartbeat: tick の統計は検証器 (state.json) の前に更新する *)
  $iSVITickStats["Count"]++; $iSVITickStats["LastTickAbs"] = AbsoluteTime[]; $iSVITickStats["LastTickAtUTC"] = iSVINowIso[];
  $iSVITickStats["LastSeconds"] = AbsoluteTime[] - t0; $iSVITickStats["LastStatus"] = status;
  If[AbsoluteTime[] - t0 > budget, $iSVITickStats["BudgetExceeded"]++];
  remaining = budget - (AbsoluteTime[] - t0);
  ver = Quiet @ Check[SourceVaultIntegrityVerifiers["BudgetSeconds" -> Max[1, remaining]], Failure["VerifierError", <||>]];
  (* V4: 行き先の評判のリストの更新 (iSVIReputationTick。1 時間に 1 回見て、1 回に 1 つ) *)
  reputation = iSVIReputationTick[];
  <|"Status" -> status, "Ingest" -> ingest, "Adapters" -> adapters, "Join" -> join, "Drift" -> If[drift === Null, <|"Status" -> "NotDue"|>, drift],
    "Reputation" -> iSVIReputationView[reputation],
    (* V7: 方針の提案の集計 (iSVIProposalsTick。1 時間に 1 回) *)
    "Proposals" -> iSVIProposalsView[iSVIProposalsTick[]],
    "Verifiers" -> If[AssociationQ[ver], KeyTake[ver, {"ComputedAtUTC", "ObservedSeq"}], ver], "Checkpoint" -> cp,
    "Feeds" -> If[AssociationQ[feeds], KeyTake[feeds, {"Status", "Own", "Peers", "WitnessesOfMe"}], If[feeds === Null, <|"Status" -> "NotDue"|>, feeds]],
    "Seconds" -> AbsoluteTime[] - t0|>];

(* ============================================================
   記録点 (Inc2、§6.2): MCP tools/call の Execute、webingest の Ingest、NBAccess の読取、TurnWiki Maintain
   ============================================================ *)
If[! AssociationQ[$iSVIRecordStats], $iSVIRecordStats = <|"ToolCall" -> 0, "WebIngest" -> 0, "NBRead" -> 0, "TurnWiki" -> 0, "Failed" -> 0|>];
iSVICanonText[x_] := If[Length[DownValues[SourceVault`ProvenancePrivate`iProvCanonText]] > 0, SourceVault`ProvenancePrivate`iProvCanonText[x], $Failed];
iSVIDigestOrNull[purpose_String, s_String] := If[Length[DownValues[SourceVault`ProvenancePrivate`iProvDigestOrNull]] > 0,
  SourceVault`ProvenancePrivate`iProvDigestOrNull[purpose, s], Null];

Options[SourceVaultProvRecordToolCall] = {"CallId" -> None, "ServedActivityIds" -> {}, "MaxReleasedPrivacy" -> Null, "Decision" -> Automatic};
SourceVaultProvRecordToolCall[name_String, args_Association, result_, OptionsPattern[]] := Quiet @ Check[Module[
  {p, argsText, argsDigest, resText, resSha, decision, served, callId, maxPl, r, isErr},
  If[! iSVIProvQ[], Return[<|"Status" -> "Skipped", "Reason" -> "ProvenanceAbsent"|>, Module]];
  p = Quiet @ Check[SourceVault`SourceVaultPrincipal[], <||>]; If[! AssociationQ[p], p = <||>];
  argsText = iSVICanonText[KeyDrop[args, {"_mcpClient"}]];
  argsDigest = If[StringQ[argsText], iSVIDigestOrNull["ToolArgs", argsText], Null];
  isErr = AssociationQ[result] && TrueQ[Lookup[result, "isError", False]];
  decision = With[{d = OptionValue["Decision"]}, If[StringQ[d], d, If[isErr, "Error", "Permit"]]];
  maxPl = With[{m = OptionValue["MaxReleasedPrivacy"]}, If[NumericQ[m], N[m], Null]];
  resText = iSVICanonText[result];
  (* 結果の SHA-256 は放出した PL が 0.5 未満 (か不明で isError) のときだけ (§12.2: 高 PL の平文 digest を台帳に出さない) *)
  resSha = If[StringQ[resText] && (! NumericQ[maxPl] || maxPl < 0.5), Hash[StringToByteArray[resText, "UTF-8"], "SHA256", "HexString"], Null];
  served = Select[Flatten[{OptionValue["ServedActivityIds"]}], StringQ];
  callId = With[{c = OptionValue["CallId"]}, If[StringQ[c], c, Null]];
  r = SourceVault`SourceVaultProvActivity[<|"Kind" -> "Execute", "Inputs" -> {}, "Outputs" -> {}, "InputsCompleteness" -> "Complete",
    "DeclaredInputs" -> {}, "ToolCalls" -> {<|"Name" -> name, "ArgsDigest" -> argsDigest, "Decision" -> decision, "DecisionRef" -> callId|>},
    "ExternalRefs" -> DeleteCases[<|"CallId" -> callId, "SessionId" -> iSVIStr[Lookup[p, "SessionId", Null]],
      "ClientProfile" -> iSVIStr[Lookup[p, "Channel", Null]]|>, Null],
    "Detail" -> <|"Tool" -> name, "ResultSHA256" -> resSha, "ResultWithheld" -> (! StringQ[resSha]), "ServedActivities" -> served,
      "ServedCount" -> Length[served], "MaxReleasedPrivacy" -> maxPl, "IsError" -> isErr|>,
    "Actor" -> Lookup[args, "_mcpClient", Null]|>];
  If[FailureQ[r], $iSVIRecordStats["Failed"]++, $iSVIRecordStats["ToolCall"]++];
  r], ($iSVIRecordStats["Failed"]++; $Failed)];
SourceVaultProvRecordToolCall[___] := <|"Status" -> "Skipped", "Reason" -> "BadArguments"|>;

iSVIPreScan[text_] := Module[{f = iSVIFn["SourceVault`SourceVaultSecurityPreScan"], r},
  If[f === None || ! StringQ[text] || text === "", Return[<|"Status" -> If[f === None, "Unavailable", "NoText"], "Flagged" -> Null|>]];
  r = Quiet @ Check[TimeConstrained[f[StringTake[text, UpTo[200000]]], 5, $Failed], $Failed];
  If[! AssociationQ[r], Return[<|"Status" -> "Failed", "Flagged" -> Null|>]];
  <|"Status" -> "Scanned", "Flagged" -> (TrueQ[Lookup[r, "Quarantined", False]] || TrueQ[Lookup[r, "Flagged", False]] || Lookup[r, "Matched", {}] =!= {} ||
      (NumericQ[Lookup[r, "Risk", Null]] && r["Risk"] >= 0.5)),
    "Matched" -> Take[Select[Flatten[{Lookup[r, "Matched", {}]}], StringQ], UpTo[10]], "Risk" -> With[{x = Lookup[r, "Risk", Lookup[r, "Score", Null]]}, If[NumericQ[x], N[x], Null]]|>];

Options[SourceVaultProvRecordWebIngest] = {"Guard" -> <||>, "CleanText" -> None};
SourceVaultProvRecordWebIngest[doc_Association, OptionsPattern[]] := Quiet @ Check[Module[
  {hex, bid, url, urlDigest, guard, prov, pre, taints, ent, r, snapRef, chan},
  If[! iSVIProvQ[], Return[<|"Status" -> "Skipped", "Reason" -> "ProvenanceAbsent"|>, Module]];
  hex = Last[StringCases[ToString @ Lookup[doc, "ContentHash", ""], RegularExpression["([0-9a-fA-F]{64})"] -> "$1"], ""];
  If[hex === "", Return[<|"Status" -> "Skipped", "Reason" -> "NoContentHash"|>, Module]];
  bid = "blob:sha256:" <> ToLowerCase[hex];
  url = ToString @ Lookup[doc, "Url", ""];
  urlDigest = If[url =!= "", iSVIDigestOrNull["ExternalRef", url], Null];
  guard = With[{g = OptionValue["Guard"]}, If[AssociationQ[g], g, <||>]];
  prov = With[{x = Lookup[doc, "IngestProvenance", <||>]}, If[AssociationQ[x], x, <||>]];
  chan = iSVIStr[Lookup[prov, "RequestChannel", Null]];
  pre = iSVIPreScan[OptionValue["CleanText"]];
  taints = Join[{"ext:web"}, If[TrueQ[pre["Flagged"]], {"prescan:flagged"}, {}]];
  snapRef = iSVIStr[Lookup[doc, "SnapshotRef", Null]];
  r = SourceVault`SourceVaultProvDerive["Ingest", {},
    {<|"Kind" -> "PrimarySource", "BlobId" -> bid, "CanonVersion" -> 1, "Size" -> With[{b = Lookup[doc, "ByteCount", Null]}, If[IntegerQ[b], b, Null]],
      "LogicalRef" -> If[StringQ[snapRef], snapRef, Null],
      "Refs" -> DeleteCases[<|"SnapshotRef" -> snapRef, "RawBlobRef" -> iSVIStr[Lookup[doc, "RawBlobRef", Null]], "CleanTextRef" -> iSVIStr[Lookup[doc, "CleanTextRef", Null]]|>, Null],
      "Media" -> iSVIStr[Lookup[doc, "ContentType", Null]],
      "Context" -> DeleteCases[<|"Channel" -> "Web", "ExternalRefDigest" -> urlDigest, "FetchedAtUTC" -> iSVIStr[Lookup[doc, "FetchedAt", Null]],
        "StatusCode" -> With[{s = Lookup[doc, "StatusCode", Null]}, If[IntegerQ[s], s, Null]], "ExtractionStatus" -> iSVIStr[Lookup[doc, "ExtractionStatus", Null]],
        "CleanTextLength" -> With[{n = Lookup[doc, "CleanTextLength", Null]}, If[IntegerQ[n], n, Null]], "PreScan" -> pre, "RequestChannel" -> chan,
        "GuardDecision" -> iSVIStr[Lookup[guard, "Decision", Null]]|>, Null],
      "PrivacyLevel" -> $SourceVaultProvWebDocumentPrivacyLevel,
      "Origin" -> <|"Contributors" -> {"External"}, "Taints" -> taints|>, "Completeness" -> "Complete"|>},
    <|"InputsCompleteness" -> "Complete", "DeclaredInputs" -> {},
      "ExternalRefs" -> DeleteCases[<|"SnapshotRef" -> snapRef, "RequestId" -> iSVIStr[Lookup[guard, "RequestId", Null]],
        "ProvenanceId" -> iSVIStr[Lookup[prov, "ProvenanceId", Null]], "SearchRunRef" -> iSVIStr[Lookup[doc, "SearchRunRef", Null]]|>, Null],
      "Detail" -> <|"PreScan" -> pre, "InitiationType" -> iSVIStr[Lookup[prov, "InitiationType", Null]], "Channel" -> chan|>,
      "Actor" -> Lookup[prov, "Actor", Null]|>];
  If[! AssociationQ[r] || Lookup[r, "Status", "Failed"] =!= "Spooled", $iSVIRecordStats["Failed"]++, $iSVIRecordStats["WebIngest"]++];
  r], ($iSVIRecordStats["Failed"]++; $Failed)];
SourceVaultProvRecordWebIngest[___] := <|"Status" -> "Skipped", "Reason" -> "BadArguments"|>;

SourceVaultProvRecordNBRead[path_String, pl_] := Quiet @ Check[Module[{size, spec, r},
  If[! iSVIProvQ[] || ! FileExistsQ[path] || DirectoryQ[path], Return[<|"Status" -> "Skipped"|>, Module]];
  size = Quiet @ Check[FileByteCount[path], -1];
  spec = <|"Kind" -> "OwnerAuthored", "LogicalRef" -> iSVICanonPath[path], "Refs" -> <|"Path" -> FileNameTake[path]|>,
    "PrivacyLevel" -> If[NumericQ[pl], N[Clip[pl, {0., 1.}]], Automatic], "Context" -> <|"Channel" -> "NBAccess", "OriginAssumed" -> "OwnerFile"|>|>;
  (* 内容の digest は size + mtime のキャッシュ越し (同じファイルを読むたびに全体を読み直さない) *)
  spec = With[{bid = If[IntegerQ[size] && 0 <= size <= $iSVIMaxHashBytes, iSVIFileBlobId[path], $Failed]},
    If[StringQ[bid], Join[spec, <|"BlobId" -> bid, "CanonVersion" -> 1, "Size" -> size|>], Append[spec, "ClaimedContentHash" -> ""]]];
  r = SourceVault`SourceVaultProvServed[{spec}, "SupplyPoint" -> "nbaccess:read", "Role" -> "Quote"];
  If[AssociationQ[r] && Lookup[r, "Status", ""] === "Spooled", $iSVIRecordStats["NBRead"]++, $iSVIRecordStats["Failed"]++];
  r], ($iSVIRecordStats["Failed"]++; $Failed)];
SourceVaultProvRecordNBRead[___] := <|"Status" -> "Skipped", "Reason" -> "BadArguments"|>;

Options[SourceVaultProvRecordTurnWikiMaintain] = {"ModelRef" -> Null, "Provider" -> "turnwiki", "Iteration" -> Null};
SourceVaultProvRecordTurnWikiMaintain[traces_List, files_List, OptionsPattern[]] := Quiet @ Check[Module[
  {aid, traceEnts = <||>, patEnts = <||>, inputs = {}, outputs = {}, act, pl = $SourceVaultIntegrityInstructionPrivacyLevel, e},
  If[! iSVIProvQ[], Return[<|"Status" -> "Skipped", "Reason" -> "ProvenanceAbsent", "Evidence" -> {}|>, Module]];
  aid = "act-" <> iSVIULID[];
  Scan[Function[t, Module[{tid = ToString @ Lookup[t, "TraceId", "?"], txt = ToString @ Lookup[t, "Text", ""]},
      e = SourceVault`SourceVaultProvEntity[<|"Kind" -> "DerivedText", "Content" -> txt, "ContentKind" -> "Text", "LogicalRef" -> "turnwiki://raw/" <> tid,
        "Refs" -> <|"TraceId" -> tid|>, "Media" -> "text/plain", "Context" -> <|"Channel" -> "TurnWiki", "TraceKind" -> ToString @ Lookup[t, "Kind", "?"]|>,
        "PrivacyLevel" -> pl, "Origin" -> <|"Contributors" -> {"Model"}, "Taints" -> {"model:unknown", "turnwiki:trace"}|>, "Completeness" -> "Partial",
        "UnrecordedInputs" -> {"ModelRef"}|>];
      If[! FailureQ[e], traceEnts[tid] = e["EntityId"]; AppendTo[inputs, <|"EntityId" -> e["EntityId"], "Role" -> "Context"|>]]]],
    Select[traces, AssociationQ]];
  Scan[Function[f, If[StringQ[f] && FileExistsQ[f],
      e = SourceVault`SourceVaultProvEntity[<|"Kind" -> "DerivedText", "ContentRef" -> f, "ContentKind" -> "File",
        "LogicalRef" -> "turnwiki://wiki/patterns/" <> FileBaseName[f], "Refs" -> <|"File" -> FileNameTake[f]|>, "Media" -> "text/markdown",
        "Context" -> <|"Channel" -> "TurnWiki", "Stage" -> "wiki"|>, "PrivacyLevel" -> pl,
        "Origin" -> <|"Contributors" -> {"Model"}, "Taints" -> {"model:unknown", "turnwiki:pattern"}|>, "ProducedBy" -> {aid},
        "Completeness" -> If[inputs === {}, "Unknown", "Partial"], "UnrecordedInputs" -> {"ModelRef"}|>];
      If[! FailureQ[e], patEnts[iSVICanonPath[f]] = e["EntityId"]; AppendTo[outputs, <|"EntityId" -> e["EntityId"], "Role" -> "Primary"|>]]]],
    files];
  act = SourceVault`SourceVaultProvActivity[<|"Kind" -> "LLMGenerate", "ActivityId" -> aid, "Inputs" -> inputs, "Outputs" -> outputs,
    "Provider" -> ToString @ OptionValue["Provider"], "ModelRef" -> iSVIStr[OptionValue["ModelRef"]],
    "InputsCompleteness" -> If[inputs === {}, "Unknown", "Partial"], "DeclaredInputs" -> {"Context"}, "UnrecordedInputs" -> {"Prompt", "ModelRef", "CurrentWiki"},
    "ExternalRefs" -> DeleteCases[<|"TurnWikiIteration" -> With[{i = OptionValue["Iteration"]}, If[i === Null, Null, ToString[i]]]|>, Null],
    "Detail" -> <|"Traces" -> Length[traceEnts], "Patterns" -> Length[patEnts]|>|>];
  If[FailureQ[act], $iSVIRecordStats["Failed"]++, $iSVIRecordStats["TurnWiki"]++];
  <|"Status" -> If[FailureQ[act], "Failed", "Spooled"], "ActivityId" -> aid, "TraceEntities" -> traceEnts, "PatternEntities" -> patEnts,
    "Evidence" -> Values[traceEnts]|>], ($iSVIRecordStats["Failed"]++; <|"Status" -> "Failed", "Evidence" -> {}|>)];
SourceVaultProvRecordTurnWikiMaintain[___] := <|"Status" -> "Skipped", "Reason" -> "BadArguments", "Evidence" -> {}|>;

(* ============================================================
   backfill (§6.3): 一度限り。adapter の offset を先頭に戻す / DerivedArtifact snapshot / PromptRunRecord / KG
   ============================================================ *)
iSVIBackfillPath[] := iSVIHealthPath["backfill.json"];
iSVIReadBackfill[] := With[{b = iSVIReadJSON[iSVIBackfillPath[]]}, If[AssociationQ[b], b, <||>]];
iSVIModelRef[provider_, model_] := If[Length[DownValues[SourceVault`ProvenancePrivate`iProvModelRefOf]] > 0, SourceVault`ProvenancePrivate`iProvModelRefOf[provider, model], Null];

Options[SourceVaultIntegrityBackfill] = {"Adapters" -> All, "DerivedArtifacts" -> True, "PromptRuns" -> True, "KnowledgeGraphs" -> True,
  "BudgetSeconds" -> 60, "MaxItems" -> 5000, "Force" -> False};
SourceVaultIntegrityBackfill[OptionsPattern[]] := Module[
  {t0 = AbsoluteTime[], deadline, done, force = TrueQ[OptionValue["Force"]], out = <||>, maxItems, n, meta, names, f, recs, j, kgs, adp, lines, path},
  If[! iSVIOwnerQ[], Return[iSVINotAuthorized["SourceVaultIntegrityBackfill", {"OwnerFE", "OwnerCode"}]]];
  If[! iSVIProvQ[], Return[Failure["ProvenanceUnavailable", <|"Reason" -> "ProvenanceModuleAbsent"|>]]];
  If[iSVIHealthDir[] === $Failed, Return[Failure["ProvLocalStateUnresolved", <||>]]];
  deadline = t0 + If[NumberQ[OptionValue["BudgetSeconds"]], OptionValue["BudgetSeconds"], 60];
  maxItems = If[IntegerQ[OptionValue["MaxItems"]] && OptionValue["MaxItems"] > 0, OptionValue["MaxItems"], 5000];
  done = iSVIReadBackfill[];
  (* 1. adapter で取り込める系統: 読取位置を先頭に戻し、取込 (EventId は行の digest なので重複しない) *)
  names = With[{a = OptionValue["Adapters"]}, Which[a === None, {}, ListQ[a], Select[a, StringQ], True, {"mcp_calls", "web_access", "reference_events", "mcp_deposits"}]];
  If[names =!= {} && (force || ! KeyExistsQ[done, "Adapters"]) && Length[DownValues[SourceVault`ProvenancePrivate`iProvReadMeta]] > 0,
    meta = SourceVault`ProvenancePrivate`iProvReadMeta[];
    If[AssociationQ[meta],
      meta["AdapterOffsets"] = KeyDrop[Lookup[meta, "AdapterOffsets", <||>], names];
      SourceVault`ProvenancePrivate`iProvWriteMeta[meta]];
    adp = Quiet @ Check[SourceVault`SourceVaultProvIngestAdapters["BudgetSeconds" -> Max[2, 0.4 (deadline - AbsoluteTime[])], "Adapters" -> names], $Failed];
    out["Adapters"] = If[AssociationQ[adp], KeyTake[adp, {"Status", "Adapter", "ByAdapter"}], <|"Status" -> "Failed"|>];
    If[AssociationQ[adp], done["Adapters"] = <|"DoneAtUTC" -> iSVINowIso[], "Count" -> Lookup[adp, "Adapter", 0], "Names" -> names|>],
    out["Adapters"] = <|"Status" -> If[names === {}, "Skipped", "AlreadyDone"]|>];
  (* 2. DerivedArtifact snapshot → LLMGenerate (SourceRefs → ArtifactId)。Model があれば ModelRef *)
  If[TrueQ[OptionValue["DerivedArtifacts"]] && (force || ! KeyExistsQ[done, "DerivedArtifacts"]),
    f = iSVIFn["SourceVault`SourceVaultDerivedArtifactList"];
    recs = If[f === None, {}, Quiet @ Check[f[], {}]];
    If[! ListQ[recs], recs = {}];
    n = 0;
    Scan[Function[rec, If[AbsoluteTime[] < deadline && n < maxItems && AssociationQ[rec] && StringQ[Lookup[rec, "Text", None]],
        Module[{aid = "act-" <> iSVIULID[], artId = ToString @ Lookup[rec, "ArtifactId", "?"], model = iSVIStr[Lookup[rec, "Model", Null]], srcRefs, e, a},
          srcRefs = Select[Flatten[{Lookup[rec, "SourceRefs", {}]}], StringQ];
          e = SourceVault`SourceVaultProvEntity[<|"Kind" -> "DerivedText", "Content" -> rec["Text"], "ContentKind" -> "Text",
            "LogicalRef" -> "sv://artifact/" <> artId, "Refs" -> DeleteCases[<|"ArtifactId" -> artId, "SnapshotRef" -> iSVIStr[Lookup[rec, "Ref", Null]]|>, Null],
            "Media" -> "text/plain", "Context" -> <|"Channel" -> "DerivedArtifactBackfill", "ArtifactType" -> ToString @ Lookup[rec, "ArtifactType", "Generic"],
              "CreatedAt" -> iSVIStr[Lookup[rec, "CreatedAt", Null]]|>,
            "PrivacyLevel" -> Automatic, "Origin" -> <|"Contributors" -> {}, "Taints" -> {"prov:backfilled", "prov:incomplete"}|>,
            "ProducedBy" -> {aid}, "Completeness" -> "Partial", "Backfilled" -> True, "UnrecordedInputs" -> {"SourceRefs", "Prompt"}|>];
          a = SourceVault`SourceVaultProvActivity[<|"Kind" -> "LLMGenerate", "ActivityId" -> aid, "Inputs" -> {},
            "Outputs" -> If[FailureQ[e], {}, {e["EntityId"]}], "Provider" -> "unknown", "ModelRef" -> iSVIModelRef["unknown", model],
            "InputsCompleteness" -> "Partial", "UnrecordedInputs" -> {"SourceRefs", "Prompt"}, "DeclaredInputs" -> {"Context"}, "Backfilled" -> True,
            "StartedAtUTC" -> iSVIStr[Lookup[rec, "CreatedAt", Null]], "EndedAtUTC" -> iSVIStr[Lookup[rec, "CreatedAt", Null]],
            "ExternalRefs" -> DeleteCases[<|"ArtifactId" -> artId, "SnapshotRef" -> iSVIStr[Lookup[rec, "Ref", Null]], "SourceRefCount" -> ToString[Length[srcRefs]]|>, Null],
            "Detail" -> <|"SourceRefs" -> Take[srcRefs, UpTo[20]], "Model" -> model|>|>];
          If[! FailureQ[a], n++]]]],
      recs];
    out["DerivedArtifacts"] = <|"Status" -> If[f === None, "Unavailable", "OK"], "Count" -> n, "Seen" -> Length[recs]|>;
    If[f =!= None, done["DerivedArtifacts"] = <|"DoneAtUTC" -> iSVINowIso[], "Count" -> n|>],
    out["DerivedArtifacts"] = <|"Status" -> "AlreadyDone"|>];
  (* 3. PromptRunRecord (prompt-runs.jsonl): PromptHash (既存の平文 sha256) は ExternalRefs に、依存 snapshot とモデル解決をそのまま *)
  If[TrueQ[OptionValue["PromptRuns"]] && (force || ! KeyExistsQ[done, "PromptRuns"]),
    path = With[{pv = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
      If[StringQ[pv], FileNameJoin[{pv, "promptrouter", "runs", "prompt-runs.jsonl"}], $Failed]];
    lines = If[StringQ[path] && FileExistsQ[path],
      With[{b = iSVIReadBytes[path]}, If[ByteArrayQ[b] && Length[b] > 0, Select[StringSplit[Quiet @ Check[ByteArrayToString[b, "UTF-8"], ""], "\n"], StringTrim[#] =!= "" &], {}]], {}];
    n = 0;
    Scan[Function[ln, If[AbsoluteTime[] < deadline && n < maxItems,
        Module[{rec = Quiet @ Check[ImportByteArray[StringToByteArray[ln, "UTF-8"], "RawJSON"], $Failed], mr, deps, a},
          If[AssociationQ[rec] && Lookup[rec, "Type", ""] === "PromptRun",
            mr = With[{m = Lookup[rec, "ModelResolution", <||>]}, If[AssociationQ[m], m, <||>]];
            deps = With[{d = Lookup[rec, "Dependencies", <||>]}, If[AssociationQ[d], d, <||>]];
            a = SourceVault`SourceVaultProvActivity[<|"Kind" -> "LLMGenerate", "Inputs" -> {}, "Outputs" -> {},
              "Provider" -> ToString @ Lookup[mr, "Provider", Lookup[mr, "Service", "unknown"]],
              "ModelRef" -> iSVIModelRef[Lookup[mr, "Provider", "unknown"], iSVIStr[Lookup[mr, "Model", Lookup[mr, "ModelId", Null]]]],
              "InputsCompleteness" -> "Partial", "UnrecordedInputs" -> {"Inputs", "Output"}, "DeclaredInputs" -> {"Context"}, "Backfilled" -> True,
              "StartedAtUTC" -> iSVIStr[Lookup[rec, "Timestamp", Null]], "EndedAtUTC" -> iSVIStr[Lookup[rec, "Timestamp", Null]],
              "ExternalRefs" -> DeleteCases[<|"RunId" -> iSVIStr[Lookup[rec, "RunId", Null]], "PromptHashSHA256" -> iSVIStr[Lookup[rec, "PromptHash", Null]],
                "RouteId" -> iSVIStr[Lookup[Lookup[rec, "Route", <||>], "RouteId", Null]]|>, Null],
              "Detail" -> <|"Dependencies" -> Take[Keys[deps], UpTo[20]], "ModelResolution" -> KeyTake[mr, {"Provider", "Model", "ModelId", "Tier"}],
                "RawPromptStored" -> TrueQ[Lookup[rec, "RawPromptStored", False]]|>|>];
            If[! FailureQ[a], n++]]]]],
      lines];
    out["PromptRuns"] = <|"Status" -> If[StringQ[path] && FileExistsQ[path], "OK", "Unavailable"], "Count" -> n, "Seen" -> Length[lines]|>;
    done["PromptRuns"] = <|"DoneAtUTC" -> iSVINowIso[], "Count" -> n|>,
    out["PromptRuns"] = <|"Status" -> "AlreadyDone"|>];
  (* 4. KG: グラフごとに 1 Entity (内容は正準 JSON) + Transform。辺ごとの生成元は不明なので Taints prov:incomplete *)
  If[TrueQ[OptionValue["KnowledgeGraphs"]] && (force || ! KeyExistsQ[done, "KnowledgeGraphs"]),
    f = iSVIFn["SourceVault`SourceVaultKGList"]; j = iSVIFn["SourceVault`SourceVaultKGLoad"];
    kgs = If[f === None || j === None, {}, Quiet @ Check[f[], {}]];
    If[! ListQ[kgs], kgs = {}];
    n = 0;
    Scan[Function[row, If[AbsoluteTime[] < deadline && n < Min[maxItems, 500] && AssociationQ[row] && StringQ[Lookup[row, "GraphId", None]],
        Module[{gid = row["GraphId"], kg = Quiet @ Check[j[row["GraphId"]], $Failed], aid = "act-" <> iSVIULID[], edges, evid, e, a},
          If[AssociationQ[kg],
            edges = Select[Flatten[{Lookup[kg, "Edges", {}]}], AssociationQ];
            evid = Count[edges, _?(Lookup[#, "EvidenceRefs", {}] =!= {} &)];
            e = SourceVault`SourceVaultProvEntity[<|"Kind" -> "KnowledgeEdge", "Content" -> kg, "ContentKind" -> "Expression",
              "LogicalRef" -> "sv://kg/" <> gid, "Refs" -> <|"GraphId" -> gid|>, "Media" -> "application/json",
              "Context" -> <|"Channel" -> "KGBackfill", "Kind" -> ToString @ Lookup[row, "Kind", ""], "UpdatedAtUTC" -> iSVIStr[Lookup[row, "UpdatedAtUTC", Null]]|>,
              "PrivacyLevel" -> With[{p = Lookup[kg, "PrivacyLevel", Lookup[row, "PrivacyLevel", Automatic]]}, If[NumericQ[p], N[p], Automatic]],
              "Origin" -> <|"Contributors" -> {}, "Taints" -> {"prov:backfilled", "prov:incomplete"}|>, "ProducedBy" -> {aid},
              "Completeness" -> "Partial", "Backfilled" -> True, "UnrecordedInputs" -> {"EdgeOrigins", "SourceText"}|>];
            a = SourceVault`SourceVaultProvActivity[<|"Kind" -> "Transform", "ActivityId" -> aid, "Inputs" -> {}, "Outputs" -> If[FailureQ[e], {}, {e["EntityId"]}],
              "InputsCompleteness" -> "Partial", "UnrecordedInputs" -> {"EdgeOrigins", "SourceText"}, "DeclaredInputs" -> {"Context"}, "Backfilled" -> True,
              "ExternalRefs" -> <|"GraphId" -> gid|>, "Detail" -> <|"Nodes" -> Length[Select[Flatten[{Lookup[kg, "Nodes", {}]}], AssociationQ]], "Edges" -> Length[edges], "EdgesWithEvidence" -> evid|>|>];
            If[! FailureQ[a], n++]]]]],
      kgs];
    out["KnowledgeGraphs"] = <|"Status" -> If[f === None, "Unavailable", "OK"], "Count" -> n, "Seen" -> Length[kgs]|>;
    If[f =!= None, done["KnowledgeGraphs"] = <|"DoneAtUTC" -> iSVINowIso[], "Count" -> n|>],
    out["KnowledgeGraphs"] = <|"Status" -> "AlreadyDone"|>];
  iSVIWriteJSON[iSVIBackfillPath[], done];
  Join[<|"Status" -> If[AbsoluteTime[] > deadline, "CarriedOver", "OK"], "Seconds" -> AbsoluteTime[] - t0|>, out]];

(* ============================================================
   Inc3 (03 v0.4 §5 / §7.1 / §9.2 / §11.2 / §11.5 / 表 11.1、2026-11-10):
   所有者操作 (ticket 必須)・service の Finding と検証主張・実効ラベル・検索フィルタ・Policy (SecurityProfile)・Instructions の照合
   ============================================================ *)
$iSVIInstructionPurposes = {"Directive", "Workflow", "TurnWikiRule", "SystemPrompt", "SeriesSpec", "ProcessDelta"};
$iSVIFilterPurposes = {"RAG", "AutoExec", "HumanSearch", "AuditView"};
$iSVIAcceptedRiskPurposes = {"HumanSearch", "HumanView", "Search", "RAG", "AutoExec", "Publish", "Instruction"};
iSVIPLabelBind[type_String, rec_Association] := If[Length[DownValues[SourceVault`ProvenancePrivate`iProvLabelBind]] > 0,
  SourceVault`ProvenancePrivate`iProvLabelBind[type, rec], <||>];
iSVIIsoFutureQ[s_] := StringQ[s] && With[{a = iSVIIsoToAbs[s]}, NumberQ[a] && a > AbsoluteTime[]];

(* Registry: 所有者操作の権限外の試み (Model / MCP / Service、発行元が所有者でない ticket) を数える *)
iSVIRegistryAttempt[fn_String] := If[Length[DownValues[SourceVault`ProvenancePrivate`iProvNoteRegistryAttempt]] > 0,
  Quiet @ SourceVault`ProvenancePrivate`iProvNoteRegistryAttempt["OwnerOperation", fn],
  Quiet @ iSVIAppendLine[iSVIHealthPath["registry-attempts.jsonl"], <|"AtUTC" -> iSVINowIso[], "Type" -> "OwnerOperation", "Function" -> fn,
    "Principal" -> iSVIPrincipalKind[]|>]];

(* 所有者 ticket の発行元: FE のダイアログ (OwnerFE)。development profile のときだけ開発用の鍵 (Development) *)
iSVITicketIssuerOK[t_] := AssociationQ[t] && With[{p = ToString @ Lookup[t, "Principal", ""]},
  p === "OwnerFE" || (p === "Development" && SourceVault`$SourceVaultSecurityProfile === "development")];

(* 所有者操作の共通部: 主体 → (ticket が無ければ確認用の Bind と表示文を返す) → 発行元 → ticket の消費 → 記録 *)
iSVIOwnerOperation[fn_String, action_String, bindExtra_Association, display_String, ticket_, emit_] := Module[{bind, v},
  If[! iSVIOwnerQ[], iSVIRegistryAttempt[fn]; Return[iSVINotAuthorized[fn, {"OwnerFE", "OwnerCode"}]]];
  bind = Append[bindExtra, "Display" -> iSVITicketDigest[display]];
  If[! AssociationQ[ticket],
    Return[<|"Status" -> "ReviewRequired", "Function" -> fn, "TicketAction" -> action, "Bind" -> bind, "BindDisplay" -> display,
      "MessageTemplate" -> "Review the display, then call again with \"Ticket\" -> SourceVaultOwnerTicketDialog[<|\"Action\" -> TicketAction, \"Display\" -> BindDisplay, \"Bind\" -> Bind|>]."|>]];
  If[! iSVITicketIssuerOK[ticket], iSVIRegistryAttempt[fn <> ":TicketIssuerNotOwner"];
    Return[Failure["ProvTicketRejected", <|"Function" -> fn, "Reason" -> "TicketIssuerNotOwner", "Issuer" -> Lookup[ticket, "Principal", Null]|>]]];
  If[Length[DownValues[SourceVault`SourceVaultOwnerTicketConsume]] === 0,
    Return[Failure["ProvTicketUnavailable", <|"MessageTemplate" -> "SourceVault_autotrigger.wl (owner tickets) is not loaded."|>]]];
  If[! iSVIProvQ[], Return[Failure["ProvenanceUnavailable", <|"Reason" -> "ProvenanceModuleAbsent"|>]]];
  v = SourceVault`SourceVaultOwnerTicketConsume[ticket, bind, "Action" -> action];
  If[! (AssociationQ[v] && TrueQ[v["Consumed"]]), Return[Failure["ProvTicketRejected", <|"Function" -> fn, "Result" -> v|>]]];
  emit[ticket]];
iSVIEmitLabel[rec_Association] := With[{r = SourceVault`SourceVaultProvEmit[rec]},
  If[FailureQ[r], r, <|"Status" -> "Spooled", "EventId" -> r["EventId"]|>]];

(* ref (EntityId / BlobId / LogicalRef / ファイル) → 版。ファイルはその内容 (BlobId) の版 *)
iSVIResolveRef[ref_String] := Module[{bid, r},
  If[! iSVIProvQ[], Return[<|"Status" -> "ProvenanceUnavailable", "EntityIds" -> {}, "Latest" -> Null|>]];
  If[! StringStartsQ[ref, "ent-" | "blob:" | "sv://" | "instr://"] && FileExistsQ[ref] && ! DirectoryQ[ref],
    bid = iSVIFileBlobId[iSVICanonPath[ref]];
    If[! StringQ[bid], Return[<|"Status" -> "Unreadable", "EntityIds" -> {}, "Latest" -> Null, "Path" -> ref|>]];
    r = SourceVault`SourceVaultProvResolve[bid];
    Return[If[AssociationQ[r], Join[r, <|"BlobId" -> bid, "Path" -> iSVICanonPath[ref]|>], <|"Status" -> "IndexUnavailable", "EntityIds" -> {}, "Latest" -> Null, "BlobId" -> bid|>]]];
  r = SourceVault`SourceVaultProvResolve[ref];
  If[AssociationQ[r], Join[r, If[StringStartsQ[ref, "blob:"], <|"BlobId" -> ref|>, <||>]], <|"Status" -> "IndexUnavailable", "EntityIds" -> {}, "Latest" -> Null|>]];
iSVILabelOf[eid_String] := If[Length[DownValues[SourceVault`ProvenancePrivate`iProvLabelOf]] > 0,
  SourceVault`ProvenancePrivate`iProvLabelOf[eid], Missing["ProvenanceUnavailable"]];

(* ---- 認可 (5.4 節) ---- *)
Options[SourceVaultIntegrityAuthorizeInstruction] = {"Ticket" -> None, "RequiredClaims" -> {}, "ExpiresAtUTC" -> None, "Scope" -> Automatic, "Note" -> ""};
SourceVaultIntegrityAuthorizeInstruction[ref_String, purpose_String, OptionsPattern[]] := Module[
  {fn = "SourceVaultIntegrityAuthorizeInstruction", r, eid, lab, bid, oc, req, missing, exp, display, rec, scope},
  If[! iSVIOwnerQ[], iSVIRegistryAttempt[fn]; Return[iSVINotAuthorized[fn, {"OwnerFE", "OwnerCode"}]]];
  If[! MemberQ[$iSVIInstructionPurposes, purpose], Return[Failure["BadPurpose", <|"Purpose" -> purpose, "Allowed" -> $iSVIInstructionPurposes|>]]];
  If[! iSVIProvQ[], Return[Failure["ProvenanceUnavailable", <|"Reason" -> "ProvenanceModuleAbsent"|>]]];
  r = iSVIResolveRef[ref];
  If[Lookup[r, "Status", ""] =!= "Found", Return[Failure["NotUsable", <|"Reason" -> "NotRecorded", "Ref" -> ref, "Status" -> Lookup[r, "Status", Null],
    "MessageTemplate" -> "The version is not in the committed index (record it first, e.g. SourceVaultIntegrityAcceptBaseline[\"Instructions\"], and wait for the service ingest)."|>]]];
  eid = r["Latest"];
  lab = iSVILabelOf[eid];
  If[! AssociationQ[lab], Return[Failure["NotUsable", <|"Reason" -> "IndexUnavailable", "EntityId" -> eid|>]]];
  bid = lab["BlobId"]; oc = Lookup[lab["Origin"], "OriginClass", "Unknown"];
  (* 隔離中・Unknown・確定前の版には認可を発行しない (9.2 節「命令採用の阻止」) *)
  Which[
    lab["Usability"] === "Quarantined", Return[Failure["NotUsable", <|"Reason" -> "Quarantined", "EntityId" -> eid, "FindingIds" -> lab["Quarantine"]["FindingIds"]|>]],
    oc === "Unknown", Return[Failure["NotUsable", <|"Reason" -> "OriginUnknown", "EntityId" -> eid|>]],
    lab["Usability"] =!= "Usable", Return[Failure["NotUsable", <|"Reason" -> ToString[lab["Usability"]], "EntityId" -> eid|>]],
    ! StringQ[bid], Return[Failure["NotUsable", <|"Reason" -> "NoBlobId", "EntityId" -> eid|>]]];
  req = Select[Flatten[{OptionValue["RequiredClaims"]}], StringQ];
  (* RequiredClaims は登録済みの決定的検証器の Pass だけで満たす (Model の判定・未登録の検証器は数えない、5.3 節) *)
  missing = Select[req, Function[p, NoneTrue[Lookup[lab, "Claims", {}], Lookup[#, "Property", ""] === p && TrueQ[Lookup[#, "Effective", False]] && Lookup[#, "Result", ""] === "Pass" &]]];
  If[missing =!= {}, Return[Failure["RequiredClaimsMissing", <|"Missing" -> missing, "EntityId" -> eid|>]]];
  exp = OptionValue["ExpiresAtUTC"];
  If[exp =!= None && ! iSVIIsoFutureQ[exp], Return[Failure["BadExpiry", <|"ExpiresAtUTC" -> exp|>]]];
  (* 2026-11-11 (F02): Scope は LoadVerify が照合する。照合できない形 (ほかの鍵・空の一覧・未知のプロファイル) は受け付けない *)
  scope = With[{s = OptionValue["Scope"]}, If[s === Automatic, <|"Machines" -> "All", "Profiles" -> {"production", "development"}|>, s]];
  If[! iSVIScopeValidQ[scope], Return[Failure["BadScope", <|"Scope" -> scope, "AllowedKeys" -> $iSVIScopeKeys, "Profiles" -> $iSVIScopeProfiles,
    "MessageTemplate" -> "Scope must be <|\"Machines\" -> \"All\" | {tag..}, \"Profiles\" -> \"All\" | {\"production\" | \"development\"..}|>."|>]]];
  display = StringRiffle[Join[{"命令採用の認可 (03 v0.4 5.4)", "用途: " <> purpose, "版: " <> eid, "内容: " <> bid,
      "種類: " <> ToString[lab["Kind"]] <> " / 出自: " <> oc <> " / Taints: " <> StringRiffle[Lookup[lab["Origin"], "Taints", {}], ", "]},
    If[oc === "ExternalDerived", {"注意: 外部由来 (ExternalDerived) の内容を含む版です。外部の文が命令として使われます。"}, {}],
    If[StringQ[Lookup[r, "Path", None]], {"ファイル: " <> r["Path"]}, {}],
    {"RequiredClaims: " <> If[req === {}, "(なし)", StringRiffle[req, ", "]], "期限: " <> If[StringQ[exp], exp, "(なし)"],
     "範囲: 機 " <> If[scope["Machines"] === "All", "すべて", StringRiffle[scope["Machines"], ", "]] <>
       " / プロファイル " <> If[scope["Profiles"] === "All", "すべて", StringRiffle[scope["Profiles"], ", "]],
     "メモ: " <> ToString @ OptionValue["Note"]}], "\n"];
  rec = <|"Type" -> "ProvAuthorization", "AuthId" -> "aut-" <> iSVIULID[], "EntityId" -> eid, "BlobId" -> bid, "Purpose" -> purpose, "Scope" -> scope,
    "RequiredClaims" -> req, "AuthorizedBy" -> <|"Actor" -> "Owner", "Principal" -> iSVIPrincipalKind[]|>, "IssuedAtUTC" -> iSVINowIso[],
    "ExpiresAtUTC" -> If[StringQ[exp], exp, Null], "Note" -> ToString @ OptionValue["Note"]|>;
  iSVIOwnerOperation[fn, "AuthorizeInstruction", iSVIPLabelBind["ProvAuthorization", rec], display, OptionValue["Ticket"],
    Function[t, With[{e = iSVIEmitLabel[Append[rec, "Ticket" -> t]]},
      If[FailureQ[e], e, <|"Status" -> "Authorized", "AuthId" -> rec["AuthId"], "EntityId" -> eid, "BlobId" -> bid, "Purpose" -> purpose,
        "OriginClass" -> oc, "EventId" -> e["EventId"], "Effective" -> "AfterIngest"|>]]]]];
SourceVaultIntegrityAuthorizeInstruction[___] := Failure["BadArguments", <|"MessageTemplate" -> "SourceVaultIntegrityAuthorizeInstruction[ref_String, purpose_String, opts]"|>];

Options[SourceVaultIntegrityRevokeAuthorization] = {"Ticket" -> None};
SourceVaultIntegrityRevokeAuthorization[authId_String, reason_String, OptionsPattern[]] := Module[{fn = "SourceVaultIntegrityRevokeAuthorization", rec},
  If[! iSVIOwnerQ[], iSVIRegistryAttempt[fn]; Return[iSVINotAuthorized[fn, {"OwnerFE", "OwnerCode"}]]];
  rec = <|"Type" -> "ProvRevocation", "RevocationId" -> "rev-" <> iSVIULID[], "AuthId" -> authId, "Reason" -> reason, "AtUTC" -> iSVINowIso[]|>;
  iSVIOwnerOperation[fn, "RevokeAuthorization", iSVIPLabelBind["ProvRevocation", rec],
    StringRiffle[{"認可の取消し", "認可: " <> authId, "理由: " <> reason}, "\n"], OptionValue["Ticket"],
    Function[t, With[{e = iSVIEmitLabel[Append[rec, "Ticket" -> t]]}, If[FailureQ[e], e, <|"Status" -> "Revoked", "AuthId" -> authId, "EventId" -> e["EventId"]|>]]]]];
SourceVaultIntegrityRevokeAuthorization[___] := Failure["BadArguments", <|"MessageTemplate" -> "SourceVaultIntegrityRevokeAuthorization[authId_String, reason_String, opts]"|>];

(* ---- 隔離・解除・Finding の解決 (5.5 節・4.6 節) ---- *)
iSVIQuarantineTargets[ref_String] := Module[{r},
  Which[
    StringStartsQ[ref, "blob:sha256:"], {ref},
    StringStartsQ[ref, "ent-"], {ref},
    ! StringStartsQ[ref, "sv://" | "instr://"] && FileExistsQ[ref] && ! DirectoryQ[ref], With[{b = iSVIFileBlobId[iSVICanonPath[ref]]}, If[StringQ[b], {b}, {}]],
    True, r = iSVIResolveRef[ref]; If[Lookup[r, "Status", ""] === "Found", r["EntityIds"], {}]]];
Options[SourceVaultIntegrityQuarantine] = {"Ticket" -> None, "Severity" -> "High"};
SourceVaultIntegrityQuarantine[ref_String, reason_String, OptionsPattern[]] := Module[{fn = "SourceVaultIntegrityQuarantine", targets, rec, sev},
  If[! iSVIOwnerQ[], iSVIRegistryAttempt[fn]; Return[iSVINotAuthorized[fn, {"OwnerFE", "OwnerCode"}]]];
  targets = Sort @ DeleteDuplicates @ iSVIQuarantineTargets[ref];
  If[targets === {}, Return[Failure["NotFound", <|"Ref" -> ref|>]]];
  sev = If[MemberQ[{"High", "Critical"}, OptionValue["Severity"]], OptionValue["Severity"], "High"];
  rec = <|"Type" -> "ProvFinding", "FindingId" -> "fnd-" <> iSVIULID[], "Kind" -> "OwnerQuarantine", "Severity" -> sev, "Targets" -> targets,
    "Reason" -> reason, "Source" -> "Owner", "OpenedAtUTC" -> iSVINowIso[]|>;
  iSVIOwnerOperation[fn, "Quarantine", iSVIPLabelBind["ProvFinding", rec],
    StringRiffle[Join[{"隔離 (03 v0.4 5.5)。carry 辺の子孫も自動の利用から外れます。", "理由: " <> reason, "重大度: " <> sev, "対象:"}, Take[targets, UpTo[20]],
      If[Length[targets] > 20, {"... ほか " <> ToString[Length[targets] - 20] <> " 件"}, {}]], "\n"], OptionValue["Ticket"],
    Function[t, With[{e = iSVIEmitLabel[Append[rec, "Ticket" -> t]]}, If[FailureQ[e], e,
      <|"Status" -> "Quarantined", "FindingId" -> rec["FindingId"], "Targets" -> targets, "EventId" -> e["EventId"], "Effective" -> "AfterIngest"|>]]]]];
SourceVaultIntegrityQuarantine[___] := Failure["BadArguments", <|"MessageTemplate" -> "SourceVaultIntegrityQuarantine[ref_String, reason_String, opts]"|>];

Options[SourceVaultIntegrityRelease] = {"Ticket" -> None};
SourceVaultIntegrityRelease[ref_String, findingId_String, ground_Association, OptionsPattern[]] := Module[{fn = "SourceVaultIntegrityRelease", eid, r, gk, rec, g},
  If[! iSVIOwnerQ[], iSVIRegistryAttempt[fn]; Return[iSVINotAuthorized[fn, {"OwnerFE", "OwnerCode"}]]];
  gk = Lookup[ground, "Kind", None];
  If[! MemberQ[{"IndependentOfTaint", "Sanitizer", "Regenerated"}, gk], Return[Failure["BadGround", <|"Kind" -> gk, "Allowed" -> {"IndependentOfTaint", "Sanitizer", "Regenerated"}|>]]];
  If[gk === "IndependentOfTaint" && ! (StringQ[Lookup[ground, "Scope", None]] && StringTrim[ground["Scope"]] =!= ""),
    Return[Failure["BadGround", <|"Reason" -> "ScopeRequired", "MessageTemplate" -> "IndependentOfTaint needs \"Scope\" (which claims were checked and why they do not depend on the tainted part)."|>]]];
  If[gk === "Sanitizer" && ! (StringQ[Lookup[ground, "Sanitizer", None]] && ground["Sanitizer"] =!= ""),
    Return[Failure["BadGround", <|"Reason" -> "SanitizerRequired"|>]]];
  eid = If[StringStartsQ[ref, "ent-"], ref, r = iSVIResolveRef[ref]; If[Lookup[r, "Status", ""] === "Found", r["Latest"], None]];
  If[! StringQ[eid], Return[Failure["NotFound", <|"Ref" -> ref|>]]];
  g = KeyTake[ground, {"Kind", "Scope", "Sanitizer", "Note", "RegeneratedFrom"}];
  rec = <|"Type" -> "ProvRelease", "ReleaseId" -> "rel-" <> iSVIULID[], "FindingId" -> findingId, "EntityId" -> eid, "Ground" -> g, "AtUTC" -> iSVINowIso[]|>;
  iSVIOwnerOperation[fn, "Release", iSVIPLabelBind["ProvRelease", rec],
    StringRiffle[{"隔離の解除 (03 v0.4 5.5)。この版とそれを通る子孫が、この Finding による隔離から外れます。", "Finding: " <> findingId, "版: " <> eid,
      "根拠: " <> gk, "範囲: " <> ToString @ Lookup[ground, "Scope", Lookup[ground, "Sanitizer", ""]]}, "\n"], OptionValue["Ticket"],
    Function[t, With[{e = iSVIEmitLabel[Append[rec, "Ticket" -> t]]}, If[FailureQ[e], e,
      <|"Status" -> "Released", "ReleaseId" -> rec["ReleaseId"], "FindingId" -> findingId, "EntityId" -> eid, "EventId" -> e["EventId"], "Effective" -> "AfterIngest"|>]]]]];
SourceVaultIntegrityRelease[___] := Failure["BadArguments", <|"MessageTemplate" -> "SourceVaultIntegrityRelease[ref_String, findingId_String, ground_Association, opts]"|>];

Options[SourceVaultIntegrityResolveFinding] = {"Ticket" -> None};
SourceVaultIntegrityResolveFinding[fid_String, resolution_Association, OptionsPattern[]] := Module[{fn = "SourceVaultIntegrityResolveFinding", k, res, rec, purposes, auto},
  If[! iSVIOwnerQ[], iSVIRegistryAttempt[fn]; Return[iSVINotAuthorized[fn, {"OwnerFE", "OwnerCode"}]]];
  k = Lookup[resolution, "Kind", None];
  Switch[k,
    "FalsePositive",
      If[! (StringQ[Lookup[resolution, "Reason", None]] && StringTrim[resolution["Reason"]] =!= ""), Return[Failure["BadResolution", <|"Reason" -> "ReasonRequired"|>]]];
      res = <|"Kind" -> k, "Reason" -> resolution["Reason"], "DetectorFeedback" -> True|>,
    "Remediated",
      With[{rep = Select[Flatten[{Lookup[resolution, "Replacements", {}]}], StringQ[#] && StringStartsQ[#, "ent-"] &], op = Lookup[resolution, "OpenPublications", 0]},
        If[rep === {}, Return[Failure["BadResolution", <|"Reason" -> "ReplacementsRequired"|>]]];
        (* 公開済みの成果物の訂正が残る間は Remediated にできない (9.3 節、X-06) *)
        If[! (IntegerQ[op] && op === 0), Return[Failure["OpenPublications", <|"OpenPublications" -> op,
          "MessageTemplate" -> "Published corrections are still open; the finding cannot be marked Remediated (03 v0.4 9.3)."|>]]];
        res = <|"Kind" -> k, "Replacements" -> rep, "OpenPublications" -> 0, "Reason" -> ToString @ Lookup[resolution, "Reason", ""]|>],
    "AcceptedRisk",
      purposes = Select[Flatten[{Lookup[Lookup[resolution, "Scope", <||>], "Purposes", {}]}], StringQ];
      If[purposes === {} || ! SubsetQ[$iSVIAcceptedRiskPurposes, purposes], Return[Failure["BadResolution", <|"Reason" -> "PurposesRequired", "Allowed" -> $iSVIAcceptedRiskPurposes|>]]];
      If[! iSVIIsoFutureQ[Lookup[resolution, "ExpiresAtUTC", None]], Return[Failure["BadResolution", <|"Reason" -> "FutureExpiryRequired"|>]]];
      auto = Intersection[purposes, {"RAG", "AutoExec", "Publish", "Instruction"}];
      If[auto =!= {} && ! TrueQ[Lookup[resolution, "ConfirmAutomatic", False]],
        Return[Failure["AutomaticScopeNeedsConfirmation", <|"Purposes" -> auto,
          "MessageTemplate" -> "Accepting a risk for automatic use (RAG / AutoExec / Publish / Instruction) needs \"ConfirmAutomatic\" -> True (03 v0.4 table 4.4)."|>]]];
      res = <|"Kind" -> k, "Scope" -> <|"Purposes" -> purposes|>, "ExpiresAtUTC" -> resolution["ExpiresAtUTC"], "Reason" -> ToString @ Lookup[resolution, "Reason", ""],
        "ConfirmAutomatic" -> TrueQ[Lookup[resolution, "ConfirmAutomatic", False]]|>,
    "Acknowledged", res = <|"Kind" -> k, "Reason" -> ToString @ Lookup[resolution, "Reason", ""]|>,
    _, Return[Failure["BadResolution", <|"Kind" -> k, "Allowed" -> {"FalsePositive", "Remediated", "AcceptedRisk", "Acknowledged"}|>]]];
  rec = <|"Type" -> "ProvFindingResolution", "ResolutionId" -> "res-" <> iSVIULID[], "FindingId" -> fid, "Resolution" -> res,
    "ResolvedBy" -> <|"Actor" -> "Owner", "Principal" -> iSVIPrincipalKind[]|>, "AtUTC" -> iSVINowIso[]|>;
  iSVIOwnerOperation[fn, "ResolveFinding", iSVIPLabelBind["ProvFindingResolution", rec],
    StringRiffle[Join[{"Finding の解決 (03 v0.4 4.6)", "Finding: " <> fid, "種類: " <> k},
      Switch[k, "FalsePositive", {"撤回します。この Finding による隔離はすべて外れます。", "理由: " <> res["Reason"]},
        "Remediated", {"訂正版: " <> StringRiffle[res["Replacements"], ", "], "旧版とその子孫は隔離のままです。"},
        "AcceptedRisk", {"範囲 (用途): " <> StringRiffle[res["Scope", "Purposes"], ", "], "期限: " <> res["ExpiresAtUTC"], "範囲外・期限後は隔離に戻ります。"},
        _, {}]], "\n"], OptionValue["Ticket"],
    Function[t, With[{e = iSVIEmitLabel[Append[rec, "Ticket" -> t]]}, If[FailureQ[e], e,
      <|"Status" -> "Resolved", "Resolution" -> k, "FindingId" -> fid, "ResolutionId" -> rec["ResolutionId"], "EventId" -> e["EventId"], "Effective" -> "AfterIngest"|>]]]]];
SourceVaultIntegrityResolveFinding[___] := Failure["BadArguments", <|"MessageTemplate" -> "SourceVaultIntegrityResolveFinding[fid_String, resolution_Association, opts]"|>];

(* ---- 検証主張 (5.3 節): 所有者の確認と、登録表 ---- *)
Options[SourceVaultIntegrityRecordOwnerReview] = {"Ticket" -> None};
SourceVaultIntegrityRecordOwnerReview[ref_String, scope_, note_, OptionsPattern[]] := Module[{fn = "SourceVaultIntegrityRecordOwnerReview", r, eid, lab, rec},
  If[! iSVIOwnerQ[], iSVIRegistryAttempt[fn]; Return[iSVINotAuthorized[fn, {"OwnerFE", "OwnerCode"}]]];
  r = iSVIResolveRef[ref];
  If[Lookup[r, "Status", ""] =!= "Found", Return[Failure["NotFound", <|"Ref" -> ref|>]]];
  eid = r["Latest"]; lab = iSVILabelOf[eid];
  If[! AssociationQ[lab], Return[Failure["IndexUnavailable", <|"EntityId" -> eid|>]]];
  rec = <|"Type" -> "ProvVerification", "VerificationId" -> "ver-" <> iSVIULID[], "EntityId" -> eid, "BlobId" -> lab["BlobId"], "Property" -> "OwnerReviewed",
    "Result" -> "Pass", "Verifier" -> <|"Name" -> "owner", "Kind" -> "Human"|>, "Scope" -> ToString[scope], "Note" -> ToString[note], "AtUTC" -> iSVINowIso[]|>;
  iSVIOwnerOperation[fn, "RecordOwnerReview", iSVIPLabelBind["ProvVerification", rec],
    StringRiffle[{"所有者の確認の記録 (OwnerReviewed)。出自・隔離・認可は変わりません。", "版: " <> eid, "範囲: " <> ToString[scope], "メモ: " <> ToString[note]}, "\n"],
    OptionValue["Ticket"],
    Function[t, With[{e = iSVIEmitLabel[Append[rec, "Ticket" -> t]]}, If[FailureQ[e], e,
      <|"Status" -> "Recorded", "VerificationId" -> rec["VerificationId"], "EntityId" -> eid, "EventId" -> e["EventId"]|>]]]]];
SourceVaultIntegrityRecordOwnerReview[___] := Failure["BadArguments", <|"MessageTemplate" -> "SourceVaultIntegrityRecordOwnerReview[ref_String, scope, note, opts]"|>];

Options[SourceVaultIntegrityRegisterVerifier] = {"Ticket" -> None};
SourceVaultIntegrityRegisterVerifier[name_String, spec_Association, OptionsPattern[]] := Module[{fn = "SourceVaultIntegrityRegisterVerifier", kind, props, impl, rec},
  If[! iSVIOwnerQ[], iSVIRegistryAttempt[fn <> ":" <> ToString @ Lookup[spec, "Kind", "?"]]; Return[iSVINotAuthorized[fn, {"OwnerFE", "OwnerCode"}]]];
  kind = Lookup[spec, "Kind", None];
  If[! MemberQ[{"Deterministic", "Model"}, kind], Return[Failure["BadVerifierSpec", <|"Reason" -> "Kind", "Allowed" -> {"Deterministic", "Model"}|>]]];
  props = Select[Flatten[{Lookup[spec, "Properties", {}]}], StringQ];
  If[props === {}, Return[Failure["BadVerifierSpec", <|"Reason" -> "PropertiesRequired"|>]]];
  If[MemberQ[props, "OwnerReviewed"], Return[Failure["BadVerifierSpec", <|"Reason" -> "OwnerReviewedIsHumanOnly"|>]]];
  impl = Lookup[spec, "Implementation", <||>];
  If[! (AssociationQ[impl] && StringQ[Lookup[impl, "Package", None]] && StringQ[Lookup[impl, "Function", None]]),
    Return[Failure["BadVerifierSpec", <|"Reason" -> "ImplementationRequired", "MessageTemplate" -> "Implementation must be <|\"Package\", \"Function\", \"Digest\"|>."|>]]];
  impl = KeyTake[impl, {"Package", "Function", "Digest", "Version"}];
  rec = <|"Type" -> "ProvVerifierRegistration", "RegistrationId" -> "vreg-" <> iSVIULID[], "Name" -> name, "Kind" -> kind, "Properties" -> props,
    "Implementation" -> impl, "Applies" -> ToString @ Lookup[spec, "Applies", ""], "Period" -> ToString @ Lookup[spec, "Period", ""],
    "Budget" -> ToString @ Lookup[spec, "Budget", ""], "Retired" -> TrueQ[Lookup[spec, "Retired", False]], "AtUTC" -> iSVINowIso[]|>;
  iSVIOwnerOperation[fn, "RegisterVerifier", iSVIPLabelBind["ProvVerifierRegistration", rec],
    StringRiffle[{"検証器の登録 (03 v0.4 11.6 登録表)", "名前: " <> name, "種類: " <> kind <> If[kind === "Model", " (参考情報だけ。認可の条件には使えません)", ""],
      "性質: " <> StringRiffle[props, ", "], "実装: " <> impl["Package"] <> " / " <> impl["Function"] <> " / " <> ToString @ Lookup[impl, "Digest", ""]}, "\n"],
    OptionValue["Ticket"],
    Function[t, With[{e = iSVIEmitLabel[Append[rec, "Ticket" -> t]]}, If[FailureQ[e], e,
      <|"Status" -> "Registered", "Name" -> name, "RegistrationId" -> rec["RegistrationId"], "EventId" -> e["EventId"]|>]]]]];
SourceVaultIntegrityRegisterVerifier[___] := Failure["BadArguments", <|"MessageTemplate" -> "SourceVaultIntegrityRegisterVerifier[name_String, spec_Association, opts]"|>];

(* service (と所有者) の記録: 検証器の Finding (隔離を足すだけなので ticket は要らない) と決定的検証器の主張 *)
iSVIEntityFinding[targets_List, kind_String, severity_String, reason_String, detail_: <||>] := Module[{rec},
  If[! iSVIOwnerServiceQ[], iSVIRegistryAttempt["EntityFinding"]; Return[iSVINotAuthorized["iSVIEntityFinding", {"OwnerFE", "OwnerCode", "Service"}]]];
  rec = <|"Type" -> "ProvFinding", "FindingId" -> "fnd-" <> iSVIULID[], "Kind" -> kind, "Severity" -> severity,
    "Targets" -> Select[targets, StringQ], "Reason" -> reason, "Source" -> "Verifier", "Detail" -> If[AssociationQ[detail], detail, <||>],
    "OpenedAtUTC" -> iSVINowIso[]|>;
  With[{e = iSVIEmitLabel[rec]}, If[FailureQ[e], e, <|"Status" -> "Spooled", "FindingId" -> rec["FindingId"]|>]]];
iSVIRecordClaim[eid_String, property_String, result_String, verifier_String, kind_: "Deterministic"] := Module[{lab, rec},
  If[! iSVIOwnerServiceQ[], iSVIRegistryAttempt["RecordClaim"]; Return[iSVINotAuthorized["iSVIRecordClaim", {"OwnerFE", "OwnerCode", "Service"}]]];
  lab = iSVILabelOf[eid];
  rec = <|"Type" -> "ProvVerification", "VerificationId" -> "ver-" <> iSVIULID[], "EntityId" -> eid, "BlobId" -> If[AssociationQ[lab], lab["BlobId"], Null],
    "Property" -> property, "Result" -> result, "Verifier" -> <|"Name" -> verifier, "Kind" -> kind|>, "AtUTC" -> iSVINowIso[]|>;
  With[{e = iSVIEmitLabel[rec]}, If[FailureQ[e], e, <|"Status" -> "Spooled", "VerificationId" -> rec["VerificationId"]|>]]];

(* ---- 実効ラベル (11.2 節) ---- *)
SourceVaultIntegrityLabel[ref_String] := Module[{r, lab, pk = iSVIPrincipalKind[]},
  If[! iSVIProvQ[], Return[Missing["ProvenanceUnavailable"]]];
  r = iSVIResolveRef[ref];
  If[Lookup[r, "Status", ""] =!= "Found", Return[Missing[If[Lookup[r, "Status", ""] === "IndexUnavailable", "IndexUnavailable", "NotFound"], ref]]];
  lab = iSVILabelOf[r["Latest"]];
  If[! AssociationQ[lab], Return[lab]];
  (* Model / MCP には PL の上限で射影する (表 11.1、12.2 節: メタデータも PL を継承) *)
  If[MemberQ[{"Model", "MCP"}, pk] && ! (NumericQ[lab["PrivacyLevel"]] && lab["PrivacyLevel"] < 0.5),
    lab = Join[lab, <|"BlobId" -> Missing["Withheld"], "LogicalRef" -> Missing["Withheld"], "Origin" -> KeyTake[lab["Origin"], {"OriginClass"}],
      "Claims" -> Missing["Withheld"], "Authorizations" -> Missing["Withheld"]|>]];
  lab];
SourceVaultIntegrityLabel[___] := Missing["BadArguments"];

(* ---- 検索フィルタ (9.2 節、11.2 節) ---- *)
If[! AssociationQ[$iSVIFilterStats], $iSVIFilterStats = <|"Calls" -> 0, "Excluded" -> 0, "Marked" -> 0, "Unavailable" -> 0, "AuditView" -> 0, "Refused" -> 0|>];
iSVIFilterKeys[c_Association, keyf_] := Module[{k, cit = Lookup[c, "Citation", <||>]},
  If[! AssociationQ[cit], cit = <||>];
  k = <|"EntityIds" -> Select[{Lookup[c, "EntityId", None]}, StringQ],
    "BlobIds" -> Select[{Lookup[c, "BlobId", None]}, StringQ[#] && StringStartsQ[#, "blob:"] &],
    "LogicalRefs" -> DeleteDuplicates @ Select[{Lookup[c, "LogicalRef", None], Lookup[c, "ObjectURI", None], Lookup[c, "URI", None], Lookup[c, "Uri", None],
      Lookup[c, "SourceId", None], Lookup[c, "SourceVaultObjectId", None], Lookup[cit, "ObjectURI", None]}, StringQ[#] && # =!= "" &],
    "Text" -> SelectFirst[{Lookup[c, "Text", None], Lookup[c, "Snippet", None], Lookup[c, "Body", None]}, StringQ[#] && # =!= "" &, None]|>;
  If[keyf =!= Automatic,
    With[{x = Quiet @ Check[keyf[c], <||>]},
      If[AssociationQ[x], k = Join[k, <|"EntityIds" -> Union[k["EntityIds"], Select[Flatten[{Lookup[x, "EntityIds", {}]}], StringQ]],
        "BlobIds" -> Union[k["BlobIds"], Select[Flatten[{Lookup[x, "BlobIds", {}]}], StringQ]],
        "LogicalRefs" -> Union[k["LogicalRefs"], Select[Flatten[{Lookup[x, "LogicalRefs", {}]}], StringQ]]|>]]]];
  k];
iSVIPurposeCovers[purpose_String, accepted_List] := Switch[purpose,
  "HumanSearch", IntersectingQ[accepted, {"HumanSearch", "HumanView", "Search"}],
  "RAG", MemberQ[accepted, "RAG"], "AutoExec", MemberQ[accepted, "AutoExec"], _, False];
iSVIFilterLog[purpose_, sp_, n_, excluded_Association, marked_] := Quiet @ iSVIAppendLine[iSVIHealthPath["filter-log.jsonl"],
  <|"AtUTC" -> iSVINowIso[], "Purpose" -> purpose, "SupplyPoint" -> sp, "Principal" -> iSVIPrincipalKind[], "Candidates" -> n,
    "Excluded" -> Total[Values[excluded]], "ByReason" -> excluded, "Marked" -> marked|>];

Options[SourceVaultIntegrityRetrievalFilter] = {"Purpose" -> Automatic, "SupplyPoint" -> "unknown", "KeyFunction" -> Automatic, "Report" -> False};
SourceVaultIntegrityRetrievalFilter[cands_List, OptionsPattern[]] := Module[
  {pk = iSVIPrincipalKind[], req = OptionValue["Purpose"], purpose, sp = ToString @ OptionValue["SupplyPoint"], ex, x, qE, qL, qB, acc, uL, uB, now = AbsoluteTime[],
   out = {}, excluded = <|"Quarantined" -> 0, "UnknownDerived" -> 0, "NotCommitted" -> 0|>, marked = 0, notRec = 0, avail, report, needBlob,
   (* V9 (文書 12 の 4.6 節): 裏付けのラベル。外部で未確認の版は除かず、印を付けて下位に回す *)
   gU = <||>, gL = <||>, gP = <||>, low = {}, nUng = 0, nPart = 0},
  $iSVIFilterStats["Calls"]++;
  report = Function[{res, filt}, If[TrueQ[OptionValue["Report"]],
    <|"Results" -> res, "Purpose" -> purpose, "Filter" -> filt, "Excluded" -> excluded, "Marked" -> marked, "NotRecorded" -> notRec, "Candidates" -> Length[cands],
      "Grounding" -> <|"Ungrounded" -> nUng, "Partial" -> nPart|>|>, res]];
  (* AuditView は OwnerFE だけ。他の主体からの指定は拒否して Registry に残す (表 11.1、T-I4) *)
  If[req === "AuditView" && pk =!= "OwnerFE",
    $iSVIFilterStats["Refused"]++; iSVIRegistryAttempt["SourceVaultIntegrityRetrievalFilter:AuditView"];
    Return[Failure["ProvNotAuthorized", <|"Function" -> "SourceVaultIntegrityRetrievalFilter", "Purpose" -> "AuditView", "Principal" -> pk,
      "MessageTemplate" -> "AuditView is for the owner in the front end only (03 v0.4 table 11.1)."|>]]];
  purpose = Which[
    MemberQ[{"Model", "MCP"}, pk], "RAG",   (* 経路で固定 *)
    MemberQ[$iSVIFilterPurposes, req], req,
    pk === "Service", "AutoExec",
    MemberQ[{"OwnerFE", "OwnerCode"}, pk], "HumanSearch",
    True, "RAG"];
  (* 2026-11-11: 索引の状態は公開の関所・LoadVerify と同じ判定 (iSVIExtrasState) *)
  ex = iSVIExtrasState[];
  avail = ex["State"] === "OK";
  If[! avail,
    $iSVIFilterStats["Unavailable"]++;
    iSVIFilterLog[purpose, sp, Length[cands], <|"FilterUnavailable" -> 0|>, 0];
    If[MemberQ[{"RAG", "AutoExec"}, purpose] && TrueQ[$SourceVaultIntegrityFilterFailClosed],
      Return[Failure["IntegrityFilterUnavailable", <|"Purpose" -> purpose, "SupplyPoint" -> sp, "IndexState" -> ex["State"],
        "MessageTemplate" -> "The quarantine filter cannot run (index missing, rebuilding or chain damaged); automatic use is stopped (03 v0.4 9.2)."|>]]];
    Return[report[If[MemberQ[{"HumanSearch", "AuditView"}, purpose],
      If[AssociationQ[#], Append[#, "IntegrityUsability" -> "Unchecked"], #] & /@ cands, cands], "Unavailable"]]];
  x = ex["Extras"];
  qE = x["Quarantine"]["ByEntity"]; qL = x["Quarantine"]["ByLogical"]; qB = x["Quarantine"]["ByBlob"];
  acc = Lookup[x, "Accepted", <||>]; uL = x["UnknownDerived"]["ByLogical"]; uB = x["UnknownDerived"]["ByBlob"];
  With[{gx = Replace[Lookup[x, "Grounding", <||>], Except[_Association] -> <||>]},
    gU = Replace[Lookup[gx, "UngroundedByBlob", <||>], Except[_Association] -> <||>];
    gL = Replace[Lookup[gx, "UngroundedByLogical", <||>], Except[_Association] -> <||>];
    gP = Replace[Lookup[gx, "PartialByBlob", <||>], Except[_Association] -> <||>]];
  needBlob = qB =!= <||> || uB =!= <||> || gU =!= <||> || gP =!= <||>;
  Scan[Function[c, Module[{k, fids, active, unk, bids, pend, ung, part, put},
      If[! AssociationQ[c], AppendTo[out, c]; Return[Null, Module]];
      k = iSVIFilterKeys[c, OptionValue["KeyFunction"]];
      bids = k["BlobIds"];
      If[needBlob && bids === {} && StringQ[k["Text"]] && Length[DownValues[SourceVault`SourceVaultProvBlobId]] > 0,
        With[{b = Quiet @ Check[SourceVault`SourceVaultProvBlobId[k["Text"], "Kind" -> "Text"], $Failed]}, If[AssociationQ[b], bids = {b["BlobId"]}]]];
      fids = Union[Flatten[Lookup[qE, k["EntityIds"], {}]], Flatten[Lookup[qL, k["LogicalRefs"], {}]], Flatten[Lookup[qB, bids, {}]]];
      (* AcceptedRisk: 範囲の用途で期限内なら、その Finding による隔離はこの用途では効かない *)
      active = Select[fids, Function[f, With[{a = Lookup[acc, f, None]},
        ! (AssociationQ[a] && iSVIPurposeCovers[purpose, Lookup[a, "Purposes", {}]] && NumberQ[Lookup[a, "ExpiresAbs", Null]] && a["ExpiresAbs"] > now)]]];
      unk = AnyTrue[k["LogicalRefs"], KeyExistsQ[uL, #] &] || AnyTrue[bids, KeyExistsQ[uB, #] &];
      (* 版 (EntityId) を名指しした候補: 確定前 (Pending)・Unknown の版は自動の利用に出さない (5.6 節) *)
      pend = Select[k["EntityIds"], ! MemberQ[{"Usable", "Quarantined"}, Lookup[SourceVault`SourceVaultProvUsability[#], "Usability", "Unknown"]] &];
      If[fids === {} && ! unk && k["EntityIds"] === {} && ! AnyTrue[k["LogicalRefs"], KeyExistsQ[qL, #] &], notRec++];
      (* V9: 外部で未確認 (Ungrounded) の版・一部だけ確認できた (Partial) 版。除かない: 印 "IntegrityGrounding" を付け、
         未確認のものは結果の末尾に回す (AuditView では並びを変えない)。隔離より弱い扱い (文書 12 の 4.6 節) *)
      ung = AnyTrue[bids, KeyExistsQ[gU, #] &] || AnyTrue[k["LogicalRefs"], KeyExistsQ[gL, #] &];
      part = ! ung && AnyTrue[bids, KeyExistsQ[gP, #] &];
      put = Function[cc, Which[
        ung, nUng++; If[purpose === "AuditView", AppendTo[out, Append[cc, "IntegrityGrounding" -> "Ungrounded"]],
          AppendTo[low, Append[cc, "IntegrityGrounding" -> "Ungrounded"]]],
        part, nPart++; AppendTo[out, Append[cc, "IntegrityGrounding" -> "Partial"]],
        True, AppendTo[out, cc]]];
      Switch[purpose,
        "RAG" | "AutoExec",
          Which[
            active =!= {}, excluded["Quarantined"]++,
            unk, excluded["UnknownDerived"]++,
            pend =!= {}, excluded["NotCommitted"]++,
            True, put[c]],
        "HumanSearch",
          If[active =!= {}, marked++; put[Join[c, <|"IntegrityUsability" -> "Quarantined", "QuarantinedBy" -> active|>]], put[c]],
        "AuditView",
          If[active =!= {} || fids =!= {}, marked++];
          put[Join[c, <|"IntegrityPurpose" -> "AuditView", "IntegrityUsability" -> If[active =!= {}, "Quarantined", If[unk, "Unknown", "Usable"]],
            "QuarantinedBy" -> fids|>]]]]],
    cands];
  out = Join[out, low];
  $iSVIFilterStats["Excluded"] += Total[Values[excluded]]; $iSVIFilterStats["Marked"] += marked;
  If[purpose === "AuditView", $iSVIFilterStats["AuditView"]++];
  If[Total[Values[excluded]] > 0 || purpose === "AuditView", iSVIFilterLog[purpose, sp, Length[cands], excluded, marked]];
  report[out, "OK"]];
SourceVaultIntegrityRetrievalFilter[___] := Failure["BadArguments", <|"MessageTemplate" -> "SourceVaultIntegrityRetrievalFilter[candidates_List, opts]"|>];

(* ---- 認可の引き当て (LoadVerify)。usability.wxf の Extras だけを読む ---- *)
iSVIPurposeForClass[class_, purpose_String] := Which[
  MemberQ[$iSVIInstructionPurposes, purpose], purpose,
  class === "Workflow" || class === "AutoTriggerConfig", "Workflow",
  MemberQ[{"TurnWikiPage", "TurnWikiPattern", "TurnWikiSkill"}, class], "TurnWikiRule",
  MemberQ[$iSVIHumanClasses, class], "Directive",
  True, "Workflow"];
(* ---- 2026-11-11 (レビュー 20261111 F01 / F02 / F03): 索引の状態・認可の範囲・版の使用可否 ----
   iSVIExtrasState[]: 検索フィルタ・公開の関所・LoadVerify が共有する索引の状態。"OK" は usability.wxf の表が読め、再構築中でなく、
   連鎖が OK で、表の形式が合うときだけ。ほかは "IndexUnavailable" / "IndexRebuilding" / "LedgerChainDamaged" / "ProvenanceAbsent"
   (来歴のモジュールがこのカーネルに無い)。"Deployed" は台帳の取込が一度でもあったか (初期導入の互換の判定に使う)。 *)
iSVIExtrasState[] := Module[{ex, st, meta},
  If[Length[DownValues[SourceVault`ProvenancePrivate`iProvUsabilityExtrasCached]] === 0,
    Return[<|"State" -> "ProvenanceAbsent", "Extras" -> None, "Deployed" -> False|>]];
  ex = Quiet @ Check[SourceVault`ProvenancePrivate`iProvUsabilityExtrasCached[], $Failed];
  st = Which[
    ! AssociationQ[ex], "IndexUnavailable",
    TrueQ[Lookup[ex, "Rebuilding", False]], "IndexRebuilding",
    Lookup[ex, "ChainState", "OK"] =!= "OK", "LedgerChainDamaged",
    ! (AssociationQ[Lookup[ex, "Extras", None]] && Lookup[ex["Extras"], "Format", ""] === "SourceVaultProvUsabilityExtras/1"), "IndexUnavailable",
    True, "OK"];
  meta = If[st === "OK", None, iSVIProvRows["iProvReadMetaCached"]];
  <|"State" -> st, "Extras" -> If[st === "OK", ex["Extras"], None],
    "Deployed" -> (st === "OK" || (AssociationQ[meta] && Lookup[meta, "DurableSeq", 0] > 0))|>];
(* 認可の範囲 (Scope)。鍵は Machines と Profiles の 2 つだけ、どちらも "All" か空でない文字列の一覧。照合できない形は拒否 (fail-closed) *)
$iSVIScopeKeys = {"Machines", "Profiles"};
$iSVIScopeProfiles = {"production", "development"};
iSVIScopeValidQ[s_] := AssociationQ[s] && Sort[Keys[s]] === Sort[$iSVIScopeKeys] &&
  (s["Machines"] === "All" || (ListQ[s["Machines"]] && s["Machines"] =!= {} && AllTrue[s["Machines"], StringQ[#] && StringTrim[#] =!= "" &])) &&
  (s["Profiles"] === "All" || (ListQ[s["Profiles"]] && s["Profiles"] =!= {} && AllTrue[s["Profiles"], StringQ] && SubsetQ[$iSVIScopeProfiles, s["Profiles"]]));
iSVINormMachine[m_String] := ToLowerCase @ If[Length[DownValues[SourceVault`SourceVaultMachineTag]] > 0, SourceVault`SourceVaultMachineTag[m], m];
iSVICurrentProfile[] := If[StringQ[SourceVault`$SourceVaultSecurityProfile], SourceVault`$SourceVaultSecurityProfile, "production"];
iSVIScopeMatchQ[s_] := iSVIScopeValidQ[s] &&
  (s["Machines"] === "All" || MemberQ[iSVINormMachine /@ s["Machines"], iSVINormMachine[ToString[$MachineName]]]) &&
  (s["Profiles"] === "All" || MemberQ[s["Profiles"], iSVICurrentProfile[]]);
(* 版 (BlobId、分かれば EntityId) をいま命令として使えるか。None なら使える。止める理由: Quarantined (BlobId か EntityId に有効な Finding、
   用途 AutoExec の AcceptedRisk で外したものを除く)、UnknownDerived、NotCommitted (committedQ のとき、名指しの版が確定して Usable でない) *)
iSVIVersionBlock[bid_, eid_, xs_Association, committedQ_] := Module[{x = xs["Extras"], fids, acc, active, now = AbsoluteTime[], u},
  If[! AssociationQ[x], Return["IndexUnavailable"]];
  fids = Union[If[StringQ[bid], Flatten[{Lookup[x["Quarantine"]["ByBlob"], bid, {}]}], {}],
    If[StringQ[eid], Flatten[{Lookup[x["Quarantine"]["ByEntity"], eid, {}]}], {}]];
  acc = Lookup[x, "Accepted", <||>];
  active = Select[fids, Function[f, With[{a = Lookup[acc, f, None]},
    ! (AssociationQ[a] && MemberQ[Lookup[a, "Purposes", {}], "AutoExec"] && NumberQ[Lookup[a, "ExpiresAbs", Null]] && a["ExpiresAbs"] > now)]]];
  Which[
    active =!= {}, "Quarantined",
    StringQ[bid] && KeyExistsQ[x["UnknownDerived"]["ByBlob"], bid], "UnknownDerived",
    TrueQ[committedQ] && StringQ[eid],
      (u = If[Length[DownValues[SourceVault`SourceVaultProvUsability]] > 0, Quiet @ SourceVault`SourceVaultProvUsability[eid], $Failed];
       If[AssociationQ[u] && Lookup[u, "Usability", ""] === "Usable" && TrueQ[Lookup[u, "Committed", False]], None, "NotCommitted"]),
    True, None]];
iSVIAuthorizationFor[bid_String, purpose_String] := iSVIAuthorizationFor[bid, purpose, iSVIExtrasState[]];
iSVIAuthorizationFor[bid_String, purpose_String, xs_Association] := Module[{lst, now = AbsoluteTime[]},
  If[xs["State"] =!= "OK" || ! AssociationQ[xs["Extras"]], Return[None]];
  lst = Lookup[Lookup[xs["Extras"], "Authorizations", <||>], bid, {}];
  SelectFirst[lst, Lookup[#, "Purpose", ""] === purpose && (! NumberQ[Lookup[#, "ExpiresAbs", Null]] || #["ExpiresAbs"] > now) &&
    iSVIScopeMatchQ[Lookup[#, "Scope", None]] &, None]];

(* ---- Instructions 部品: 命令使用の認可 (InstructionAuthorization) と Registry (7.1 節) ---- *)
If[! IntegerQ[$iSVIInstrUseSeq], $iSVIInstrUseSeq = 0];
If[! IntegerQ[$iSVIRegistrySeenSeq], $iSVIRegistrySeenSeq = 0];
If[! IntegerQ[$iSVIRegistryAttemptsSeen], $iSVIRegistryAttemptsSeen = 0];
If[! AssociationQ[$iSVIInstrUseCounts], $iSVIInstrUseCounts = <|"Checked" -> 0, "Unauthorized" -> 0, "DirectiveServes" -> 0|>];
iSVICheckInstructionUse[] := Module[{u, ex, authz, base, baseBlobs, bad = {}, dir = 0, checked = 0, crit},
  If[Length[DownValues[SourceVault`ProvenancePrivate`iProvInstructionUses]] === 0, Return[<|"Health" -> "OK", "ReasonCode" -> "NotApplicable"|>]];
  u = Quiet @ Check[SourceVault`ProvenancePrivate`iProvInstructionUses[$iSVIInstrUseSeq], $Failed];
  If[! AssociationQ[u], Return[<|"Health" -> "OK", "ReasonCode" -> "IndexUnavailable"|>]];
  ex = Quiet @ Check[SourceVault`ProvenancePrivate`iProvUsabilityExtrasCached[], $Failed];
  authz = If[AssociationQ[ex] && AssociationQ[ex["Extras"]], Lookup[ex["Extras"], "Authorizations", <||>], <||>];
  base = iSVIReadBaseline[];
  baseBlobs = If[AssociationQ[base], Association[(#["BlobId"] -> #["Group"]) & /@ Select[Values[base["Entries"]], AssociationQ[#] && StringQ[Lookup[#, "BlobId", None]] &]], <||>];
  Scan[Function[use, Module[{bid = use["BlobId"], g},
      checked++;
      g = If[StringQ[bid], Lookup[baseBlobs, bid, None], None];
      Which[
        StringQ[bid] && Lookup[authz, bid, {}] =!= {}, Null,
        g === "HumanEdited", Null,
        g === "ModelWritable" && TrueQ[$SourceVaultIntegrityBaselineAsAuthorization], Null,
        (* sourcevault_directives の提供 (内容の一覧で、ファイルのハッシュとは対応しない): 基準 (drift) で見て、ここでは数えるだけ *)
        StringQ[use["LogicalRef"]] && StringStartsQ[use["LogicalRef"], "sv://directive"], dir++,
        True, AppendTo[bad, use]]]], u["Uses"]];
  $iSVIInstrUseSeq = Max[$iSVIInstrUseSeq, Lookup[u, "IndexSeq", 0]];
  $iSVIInstrUseCounts = <|"Checked" -> $iSVIInstrUseCounts["Checked"] + checked, "Unauthorized" -> $iSVIInstrUseCounts["Unauthorized"] + Length[bad],
    "DirectiveServes" -> $iSVIInstrUseCounts["DirectiveServes"] + dir|>;
  crit = AnyTrue[bad, MemberQ[{"ExternalDerived", "Unknown"}, #["OriginClass"]] || #["Usability"] === "Quarantined" &];
  If[bad =!= {},
    iSVIFinding["Instructions", "UnauthorizedInstructionUse", If[crit, "Critical", "High"], "Failing", "Targets" -> DeleteDuplicates[#["EntityId"] & /@ bad],
      "Detail" -> <|"Uses" -> Length[bad], "OriginClasses" -> Tally[#["OriginClass"] & /@ bad]|>]];
  <|"Health" -> If[bad =!= {}, "Failing", "OK"], "ReasonCode" -> If[bad =!= {}, "UnauthorizedInstructionUse", "InstructionUseOK"],
    "Counts" -> <|"CheckedNow" -> checked, "UnauthorizedNow" -> Length[bad], "DirectiveServesNow" -> dir, "Total" -> $iSVIInstrUseCounts|>|>];
iSVICheckRegistry[] := Module[{st, issues, newI, attemptsPath, nAtt = 0, newAtt, tamper},
  If[Length[DownValues[SourceVault`ProvenancePrivate`iProvRegistryState]] === 0, Return[<|"Health" -> "OK", "ReasonCode" -> "NotApplicable"|>]];
  st = Quiet @ Check[SourceVault`ProvenancePrivate`iProvRegistryState[], $Failed];
  If[! AssociationQ[st], Return[<|"Health" -> "OK", "ReasonCode" -> "IndexUnavailable"|>]];
  issues = Lookup[st, "Issues", {}];
  newI = Select[issues, Lookup[#, "Seq", 0] > $iSVIRegistrySeenSeq &];
  $iSVIRegistrySeenSeq = Max[$iSVIRegistrySeenSeq, Max[0, Lookup[#, "Seq", 0] & /@ issues]];
  attemptsPath = iSVIHealthPath["registry-attempts.jsonl"];
  If[StringQ[attemptsPath] && FileExistsQ[attemptsPath],
    nAtt = Length[Select[StringSplit[Quiet @ Check[ByteArrayToString[ReadByteArray[attemptsPath], "UTF-8"], ""], "\n"], StringTrim[#] =!= "" &]]];
  newAtt = Max[0, nAtt - $iSVIRegistryAttemptsSeen]; $iSVIRegistryAttemptsSeen = nAtt;
  tamper = Select[newI, Lookup[#, "Reason", ""] =!= "UnregisteredVerifierClaim" &];
  If[tamper =!= {},
    iSVIFinding["Instructions", "RegistryTampered", "High", "Failing", "Targets" -> (ToString[#["Type"]] <> ":" <> ToString[#["Id"]] & /@ tamper),
      "Detail" -> <|"Reasons" -> Tally[Lookup[#, "Reason", "?"] & /@ tamper]|>]];
  <|"Health" -> Which[tamper =!= {}, "Failing", issues =!= {}, "Degraded", True, "OK"],
    "ReasonCode" -> Which[tamper =!= {}, "RegistryTampered", issues =!= {}, "RegistryIssuesPresent", True, "RegistryOK"],
    "Counts" -> <|"Issues" -> Length[issues], "NewIssues" -> Length[newI], "IssueReasons" -> Tally[Lookup[#, "Reason", "?"] & /@ issues],
      "Attempts" -> nAtt, "NewAttempts" -> newAtt, "Verifiers" -> Length[Lookup[st, "Verifiers", <||>]]|>|>];

(* ---- Policy 部品 (7.1 節 SecurityProfile): 設定の項目ごとの digest を、所有者が受け入れた基準と比べる ---- *)
(* 2026-11-11: 役割は「service の目印」で決める。以前は $Notebooks だけで FE / Service を分けていたため、FE のカーネルも起動直後の
   初期化中 ($Notebooks がまだ偽) や並列の子カーネル・台本のカーネルが Service と判定され、FE の設定を service の要約として書き出したり
   (11-11 に実際に起きた)、service の基準と比べて誤った PolicyChanged を出し得た。目印は SourceVaultServiceMain だけが立てる
   $SourceVaultDiagnosticsCanonicalWriter (来歴の producer 名と同じ判定)。どちらでもないカーネルは "Other" で、Policy を検査しない。 *)
iSVIRole[] := Which[TrueQ[SourceVault`$SourceVaultDiagnosticsCanonicalWriter], "Service", TrueQ[$Notebooks], "FE", True, "Other"];
iSVIValueByName[short_String] := Module[{names = Select[Names["*`" <> short], ! StringStartsQ[#, "Global`"] &], held},
  If[names === {}, Return["Absent"]];
  held = ToExpression[First[Sort[names]], InputForm, HoldComplete];
  If[ValueQ @@ held, ReleaseHold[held], "Unset"]];
iSVIKeyIdsOnly[a_] := If[AssociationQ[a], Map[If[AssociationQ[#], <|"KeyId" -> Lookup[#, "KeyId", Null], "Literal" -> StringQ[Lookup[#, "KeyRef", None]] && StringStartsQ[#["KeyRef"], "literal:"]|>, "?"] &, a], a];
iSVIPolicyItems[] := Module[{ex},
  ex = If[Length[DownValues[SourceVault`ProvenancePrivate`iProvUsabilityExtrasCached]] > 0, Quiet @ Check[SourceVault`ProvenancePrivate`iProvUsabilityExtrasCached[], $Failed], $Failed];
  <|"SecurityProfile" -> iSVIValueByName["$SourceVaultSecurityProfile"],
    "WebGuardEnabled" -> iSVIValueByName["$SourceVaultWebGuardEnabled"], "WebGuardRequired" -> iSVIValueByName["$SourceVaultWebGuardRequired"],
    "WebGuardPolicy" -> iSVIValueByName["$SourceVaultWebGuardPolicy"], "WebGuardPrompter" -> iSVIValueByName["$SourceVaultWebGuardPrompter"],
    "ConservativePrivacyDefault" -> iSVIValueByName["$ConservativePrivacyDefault"], "ToolGate" -> iSVIValueByName["$ClaudeRuntimeToolGate"],
    "PermissionMode" -> iSVIValueByName["$ClaudePermissionMode"],
    "TrustedPackageHeads" -> iSVIValueByName["$NBTrustedPackageHeads"], "DenyHeads" -> iSVIValueByName["$NBDenyHeads"],
    "ApprovalHeads" -> With[{v = iSVIValueByName["$NBApprovalHeads"]}, If[ListQ[v], Sort[v], v]],
    "ApprovalSetSymbols" -> With[{v = iSVIValueByName["$NBApprovalSetSymbols"]}, If[ListQ[v], Sort[v], v]],
    "SourceVaultApprovalHeads" -> Sort[$SourceVaultApprovalHeads], "SourceVaultApprovalSetSymbols" -> Sort[$SourceVaultApprovalSetSymbols],
    "ToolLoopAllowlist" -> iSVIValueByName["$ClaudeLocalToolLoopTools"], "MCPDisabledTools" -> iSVIValueByName["$iSVMCPDisabledTools"],
    "AccessibleDirs" -> iSVIValueByName["$ClaudeAccessibleDirs"],
    "IntegritySettings" -> <|"LoadVerifyEnforce" -> $SourceVaultIntegrityLoadVerifyEnforce, "FilterFailClosed" -> $SourceVaultIntegrityFilterFailClosed,
      "BaselineAsAuthorization" -> $SourceVaultIntegrityBaselineAsAuthorization, "StateMaxAge" -> $SourceVaultIntegrityStateMaxAge,
      "DriftInterval" -> $SourceVaultIntegrityDriftIntervalSeconds, "VerifyInterval" -> $SourceVaultIntegrityVerifyIntervalSeconds,
      "InstructionRoots" -> $SourceVaultInstructionRoots|>,
    "ProvenanceKeys" -> iSVIKeyIdsOnly[iSVIValueByName["$SourceVaultProvKeyRefs"]],
    "ProvenanceSettings" -> <|"CheckpointLines" -> iSVIValueByName["$SourceVaultProvCheckpointLines"],
      "CheckpointInterval" -> iSVIValueByName["$SourceVaultProvCheckpointIntervalSeconds"], "FeedRetention" -> iSVIValueByName["$SourceVaultProvFeedRetentionDays"],
      "SyncDigestKinds" -> iSVIValueByName["$SourceVaultProvSyncDigestKinds"]|>,
    "OwnerTicketKeys" -> <|"Owner" -> StringQ[iSVIValueByName["$SourceVaultOwnerTicketKeyRef"]],
      "Development" -> StringQ[iSVIValueByName["$SourceVaultOwnerTicketDevelopmentKeyRef"]]|>,
    "VerifierRegistry" -> If[AssociationQ[ex] && AssociationQ[ex["Extras"]], Lookup[ex["Extras"], "VerifierRegistryDigest", "Unavailable"], "Unavailable"],
    (* 2026-11-11 (レビュー 20261111 F06): 承認対象なのに監視していなかった切替。既存の項目に足すと PolicyChanged (Failing) になるので新しい項目にする *)
    "PublishFailClosed" -> $SourceVaultIntegrityPublishFailClosed,
    "AutoTriggerEnforcePermit" -> iSVIValueByName["$SourceVaultAutoTriggerEnforcePermit"],
    "ProvSpoolRoot" -> iSVIValueByName["$SourceVaultProvSpoolRoot"],
    (* 承認対象の変数 (SourceVault と NBAccess の一覧の和) から監視対象を導出する。呼出しごとに変わる主体は除く。literal: の鍵は値を残さない *)
    "ApprovalGatedSettings" -> iSVIApprovalGatedSettings[]|>];
$iSVIPolicyDynamicSymbols = {"$SourceVaultPrincipal", "$SourceVaultProvSessionKey"};
(* 値の要約: literal: の鍵とバイト列は値を残さない。関数・記号はモジュールの局所名の番号 (x$123) を落として、カーネルごとに変わらない形にする *)
iSVIPolicyStable[a_Association] := iSVIPolicyStable /@ a;
iSVIPolicyStable[l_List] := iSVIPolicyStable /@ l;
iSVIPolicyStable[s_String] := If[StringStartsQ[s, "literal:"], "literal:<redacted>", s];
iSVIPolicyStable[_ByteArray] := "ByteArray<redacted>";
iSVIPolicyStable[sym_Symbol] := If[Context[sym] === "System`", sym, StringReplace[Context[sym] <> SymbolName[sym], RegularExpression["\\$[0-9]+$"] -> ""]];
iSVIPolicyStable[f_Function] := StringReplace[ToString[f, InputForm], RegularExpression["\\$[0-9]+"] -> ""];
iSVIPolicyStable[x_] := x;
iSVIApprovalGatedSettings[] := Module[{names},
  names = Complement[Union[Select[Flatten[{$SourceVaultApprovalSetSymbols}], StringQ],
    With[{v = iSVIValueByName["$NBApprovalSetSymbols"]}, If[ListQ[v], Select[v, StringQ], {}]]], $iSVIPolicyDynamicSymbols];
  (* 記号がまだ無い ("Absent") と値が無い ("Unset") は同じ扱い: 後から別のコードが記号に触れただけで要約が変わらないように *)
  Association[(# -> iSVIPolicyStable[With[{v = iSVIValueByName[#]}, If[v === "Absent", "Unset", v]]]) & /@ names]];
SourceVaultIntegrityPolicySnapshot[] := Module[{items = iSVIPolicyItems[], dig},
  dig = Hash[#, "SHA256", "HexString"] & /@ items;
  <|"Format" -> "SourceVaultPolicySnapshot/1", "Role" -> iSVIRole[], "Items" -> dig, "Digest" -> Hash[KeySort[dig], "SHA256", "HexString"],
    "ComputedAtUTC" -> iSVINowIso[]|>];
iSVIPolicyBaselinePath[role_String] := iSVIHealthPath["policy-baseline-" <> ToLowerCase[role] <> ".json"];
iSVIPolicyCheck[] := Module[{snap, base, items, changed, missingI, newI},
  If[iSVIRole[] === "Other",
    Return[<|"Health" -> "OK", "ReasonCode" -> "NotApplicable", "Role" -> "Other",
      "Message" -> "this kernel is neither the front end nor the SourceVault service (a subkernel, a script, or a front end still starting)",
      "Counts" -> <||>, "Changed" -> {}|>]];
  snap = SourceVaultIntegrityPolicySnapshot[];
  (* 2026-11-11: service は自分の設定の要約を書き出し、FE の所有者がそれを ticket つきで service の基準として受け入れられるようにする *)
  If[snap["Role"] === "Service", Quiet @ Check[iSVIPublishServiceSnapshot[snap], $Failed]];
  base = iSVIReadJSON[iSVIPolicyBaselinePath[snap["Role"]]];
  If[! AssociationQ[base] || ! AssociationQ[Lookup[base, "Items", None]],
    Return[<|"Health" -> "Degraded", "ReasonCode" -> "PolicyBaselineMissing", "Role" -> snap["Role"],
      "Message" -> "no accepted SecurityProfile baseline for this kernel role (SourceVaultIntegrityAcceptBaseline[\"SecurityProfile\"])",
      "Counts" -> <|"Items" -> Length[snap["Items"]], "Changed" -> 0|>, "Changed" -> {}|>]];
  items = snap["Items"];
  (* 検証器の登録表は service の索引が進むたびに変わり得るので、ここでは Registry の照合に任せて比べない *)
  changed = Select[Keys[items], KeyExistsQ[base["Items"], #] && base["Items"][#] =!= items[#] && # =!= "VerifierRegistry" &];
  newI = Select[Keys[items], ! KeyExistsQ[base["Items"], #] &]; missingI = Select[Keys[base["Items"]], ! KeyExistsQ[items, #] &];
  If[changed =!= {}, iSVIFinding["Policy", "PolicyChanged", "High", "Failing", "Targets" -> changed, "Detail" -> <|"Role" -> snap["Role"]|>]];
  <|"Health" -> Which[changed =!= {}, "Failing", newI =!= {} || missingI =!= {}, "Degraded", True, "OK"],
    "ReasonCode" -> Which[changed =!= {}, "PolicyChanged", newI =!= {} || missingI =!= {}, "PolicyItemsChanged", True, "PolicyOK"], "Role" -> snap["Role"],
    "Message" -> If[changed === {}, "security settings match the accepted baseline", "changed: " <> StringRiffle[changed, ", "]],
    "Counts" -> <|"Items" -> Length[items], "Changed" -> Length[changed], "New" -> Length[newI], "Missing" -> Length[missingI]|>,
    "Changed" -> changed, "BaselineAcceptedAtUTC" -> Lookup[base, "AcceptedAtUTC", Null]|>];
(* ---- 2026-11-11: service の役割の基準を FE から受け入れる ----
   service kernel には FE (ticket のダイアログ) も所有者 ticket の鍵 (NBGetCredential) も無いので、service 自身では基準を受け入れられず、
   service の Policy 部品は PolicyBaselineMissing (Degraded) のままだった。service は Policy の検査のたびに自分の設定の要約
   (SourceVaultIntegrityPolicySnapshot と同じ形、項目ごとの digest だけ) を LocalState の health に書き、FE の所有者がそれを読んで受け入れる。
   要約は同じ OS ユーザーのコードなら書き換えられる (表 4.5 の 3 行目と同じ限界) が、受け入れた後も service は自分の実際の設定と基準を
   比べ続けるので、実際と違う要約を受け入れさせても PolicyChanged (Failing) で表に出る。 *)
If[! NumberQ[$iSVIServiceSnapshotRefreshSeconds], $iSVIServiceSnapshotRefreshSeconds = 300];
iSVIServiceSnapshotPath[] := iSVIHealthPath["policy-snapshot-service.json"];
iSVIPublishServiceSnapshot[snap_Association] := Module[{p = iSVIServiceSnapshotPath[], cur, at},
  If[p === $Failed, Return[$Failed]];
  cur = iSVIReadJSON[p];
  at = If[AssociationQ[cur], iSVIIsoToAbs[ToString @ Lookup[cur, "ComputedAtUTC", ""]], $Failed];
  (* 内容が同じで新しければ書き直さない (毎分の書込を避ける)。新しさの判定のため $iSVIServiceSnapshotRefreshSeconds ごとには書く *)
  If[AssociationQ[cur] && Lookup[cur, "Digest", ""] === snap["Digest"] && NumericQ[at] && 0 <= AbsoluteTime[] - at < $iSVIServiceSnapshotRefreshSeconds,
    Return[cur]];
  iSVIWriteJSON[p, Join[KeyTake[snap, {"Format", "Role", "Items", "Digest", "ComputedAtUTC"}],
    <|"Pid" -> $ProcessID,
      "MachineTag" -> If[Length[DownValues[SourceVault`SourceVaultMachineTag]] > 0, Quiet @ Check[SourceVault`SourceVaultMachineTag[], $MachineName], $MachineName]|>]]];
iSVIReadServiceSnapshot[maxAge_] := Module[{p = iSVIServiceSnapshotPath[], s, at, age},
  If[p === $Failed || ! FileExistsQ[p],
    Return[Failure["ServiceSnapshotMissing", <|"MessageTemplate" ->
      "The service has not written its policy snapshot (health/policy-snapshot-service.json). Start or restart the service and wait for one tick (about a minute).",
      "Path" -> p|>]]];
  s = iSVIReadJSON[p];
  If[! AssociationQ[s] || Lookup[s, "Format", ""] =!= "SourceVaultPolicySnapshot/1" || Lookup[s, "Role", ""] =!= "Service" ||
      ! AssociationQ[Lookup[s, "Items", None]] || ! AllTrue[Values[s["Items"]], StringQ] ||
      Hash[KeySort[s["Items"]], "SHA256", "HexString"] =!= Lookup[s, "Digest", ""],
    Return[Failure["ServiceSnapshotInvalid", <|"MessageTemplate" ->
      "The service policy snapshot is malformed, or its digest does not match its items.", "Path" -> p|>]]];
  at = iSVIIsoToAbs[ToString @ Lookup[s, "ComputedAtUTC", ""]];
  age = If[NumericQ[at], AbsoluteTime[] - at, Infinity];
  If[! (NumericQ[age] && -120 <= age <= maxAge),
    Return[Failure["ServiceSnapshotStale", <|"MessageTemplate" -> "The service policy snapshot is older than `1` seconds (is the service running?).",
      "MessageParameters" -> {maxAge}, "AgeSeconds" -> age, "Path" -> p|>]]];
  s];
iSVIAcceptPolicyBaseline[ticket_, dryRun_, note_String] := iSVIAcceptPolicyBaseline[ticket, dryRun, note, Automatic, 900];
iSVIAcceptPolicyBaseline[ticket_, dryRun_, note_String, role_, maxAge_] := Module[
  {here = iSVIRole[], target, snap, src = <||>, base, display, bindExtra, fn = "SourceVaultIntegrityAcceptBaseline"},
  target = If[role === Automatic, here, ToString[role]];
  If[here === "Other",
    Return[Failure["PolicyRoleNotSupported", <|"MessageTemplate" ->
      "This kernel is neither the front end nor the SourceVault service (a subkernel, a script, or a front end still starting); accept SecurityProfile baselines from the front end.",
      "Role" -> target|>]]];
  Which[
    target === here, snap = SourceVaultIntegrityPolicySnapshot[],
    target === "Service" && here === "FE",
      snap = iSVIReadServiceSnapshot[If[NumericQ[maxAge] && maxAge > 0, maxAge, 900]];
      If[FailureQ[snap], Return[snap]];
      src = <|"Source" -> "ServiceSnapshot", "SnapshotComputedAtUTC" -> Lookup[snap, "ComputedAtUTC", Null],
        "SnapshotPid" -> Lookup[snap, "Pid", Null], "SnapshotMachineTag" -> Lookup[snap, "MachineTag", Null]|>,
    True,
      Return[Failure["PolicyRoleNotSupported", <|"MessageTemplate" ->
        "The SecurityProfile baseline of role `1` cannot be accepted from a `2` kernel (use Automatic, or \"Service\" from the front end).",
        "MessageParameters" -> {target, here}|>]]];
  base = iSVIReadJSON[iSVIPolicyBaselinePath[target]];
  (* 表示文には時刻や PID を入れない: service が要約を書き直すと文面が変わり、ダイアログの後の照合 (Bind の Display) に落ちるため *)
  display = StringRiffle[Join[{"SecurityProfile の基準の受入 (03 v0.4 7.1 Policy)",
      "カーネルの役割: " <> target <> If[src === <||>, "", " (service が書いた設定の要約から受け入れる)"], "digest: " <> snap["Digest"], "項目:"},
    KeyValueMap[#1 <> " = " <> StringTake[#2, 16] <> If[AssociationQ[base] && AssociationQ[Lookup[base, "Items", None]] && Lookup[base["Items"], #1, None] =!= #2, "  (変更)", ""] &, snap["Items"]]], "\n"];
  bindExtra = Join[<|"Component" -> iSVITicketDigest["SecurityProfile"], "Snapshot" -> iSVITicketDigest[snap["Digest"]]|>,
    If[src === <||>, <||>, <|"Role" -> iSVITicketDigest[target]|>]];
  If[TrueQ[dryRun], Return[<|"Status" -> "ReviewRequired", "Component" -> "SecurityProfile", "BindDisplay" -> display, "TicketAction" -> "AcceptBaseline",
    "Bind" -> Append[bindExtra, "Display" -> iSVITicketDigest[display]]|>]];
  iSVIOwnerOperation[fn, "AcceptBaseline", bindExtra, display, ticket,
    Function[t, With[{w = iSVIWriteJSON[iSVIPolicyBaselinePath[target], Join[<|"Format" -> "SourceVaultPolicyBaseline/1", "Role" -> target, "Items" -> snap["Items"],
        "Digest" -> snap["Digest"], "AcceptedAtUTC" -> iSVINowIso[], "TicketNonce" -> ToString @ Lookup[t, "Nonce", ""], "Note" -> note|>, src]]},
      Join[<|"Status" -> If[w === $Failed, "BaselineWriteFailed", "Accepted"], "Component" -> "SecurityProfile", "Role" -> target, "Digest" -> snap["Digest"]|>,
        KeyTake[src, {"Source", "SnapshotComputedAtUTC"}]]]]]];

(* ============================================================
   Inc4 (03 v0.4 §7.1 / §7.3 / §9.2 / 6.2 節の Inc 4、2026-11-10): 決定的検証器
   Integrity = EntityDrift・InjectionResidue・CitationIntegrity・GeneratedCodeHealth、Models = ModelManifest・LMStudioMCPScope、
   Egress = EgressPattern・PublishUnusable、公開の関所 SourceVaultIntegrityPublishGate。Chain は Inc1b。
   ============================================================ *)
If[! ListQ[$SourceVaultModelRuntimeAdvisories], $SourceVaultModelRuntimeAdvisories = {}];
If[! ValueQ[$SourceVaultLMStudioRoot], $SourceVaultLMStudioRoot = Automatic];
If[! ValueQ[$SourceVaultLMStudioInstallDir], $SourceVaultLMStudioInstallDir = Automatic];
(* LM Studio 自身のチャット欄で確認を省いてはいけないツール (書込・外向き)。2026-11-11: sourcevault_web_search は claudecode の
   ツールループの許可一覧 ($ClaudeLocalToolLoopTools) に入ったが、LM Studio のチャット欄では従来どおり確認を求めるので、ここに足す
   (足さないと「読取の一覧にある」扱いになり、確認省略の一覧に入れても違反にならなくなる) *)
$iSVILMStudioWriteTools = {"sourcevault_deposit", "sourcevault_workflow_write", "sourcevault_feedback_submit", "sourcevault_request_access",
  "sourcevault_submit_web_search", "sourcevault_orchestrator_subtask", "sourcevault_web_search"};
$iSVIDynamicEvalNames = {"ToExpression", "Symbol", "Uncompress", "Get", "BinaryDeserialize", "ImportString", "ReleaseHold", "Activate"};
$iSVISensitiveNames = {"URLRead", "URLFetch", "URLExecute", "URLSubmit", "URLDownload", "URLSave", "SendMail", "SocketConnect", "SocketOpen",
  "RunProcess", "StartProcess", "Run", "ExternalEvaluate", "DeleteFile", "DeleteDirectory", "RenameFile", "CopyFile", "Put", "PutAppend",
  "Export", "WriteString", "BinaryWrite", "CreateFile", "SetDirectory", "NBGetCredential", "SystemCredential", "SourceVaultExportKeyBundle",
  "SourceVaultMailSend", "SourceVaultDecryptRecord", "SourceVaultWebSearch", "SourceVaultWebFetch"};

(* ---- 検証器の状態 (health/probe-state.json): 増分の読取位置・Finding の重複抑止・最後の実行時刻 ---- *)
iSVIProbeStatePath[] := iSVIHealthPath["probe-state.json"];
iSVIProbeStateLoad[] := With[{s = iSVIReadJSON[iSVIProbeStatePath[]]},
  Join[<|"Format" -> "SourceVaultProbeState/1", "Seqs" -> <||>, "Seen" -> <||>, "LastRun" -> <||>, "InstrBlobs" -> <||>, "FlaggedInstr" -> <||>, "Last" -> <||>,
      "Hits" -> <||>, "Expired" -> <||>, "KnownCycles" -> 0|>,
    If[AssociationQ[s], Map[If[AssociationQ[#], #, <||>] &, KeyTake[s, {"Seqs", "Seen", "LastRun", "InstrBlobs", "FlaggedInstr", "Last", "Hits", "Expired"}]], <||>],
    If[AssociationQ[s] && IntegerQ[Lookup[s, "KnownCycles", None]], <|"KnownCycles" -> s["KnownCycles"]|>, <||>],
    If[AssociationQ[s] && IntegerQ[Lookup[s, "InjectionRuleVersion", None]], <|"InjectionRuleVersion" -> s["InjectionRuleVersion"]|>, <||>]]];
iSVIProbeStateSave[s_Association] := iSVIWriteJSON[iSVIProbeStatePath[],
  Append[s, "Seen" -> With[{seen = s["Seen"]}, If[Length[seen] > 20000, Take[seen, -20000], seen]]]];
iSVIDue[s_Association, check_String, interval_, force_] := TrueQ[force] || ! NumberQ[Lookup[s["LastRun"], check, Null]] || AbsoluteTime[] - s["LastRun"][check] > interval;
(* Entity の Finding は同じ (種類・対象・理由) で 1 回だけ (日次の再走査で同じ Finding を積まない) *)
iSVIEntityFindingOnce[s_Association, targets_List, kind_String, sev_String, reason_String, detail_: <||>] := Module[{key = kind <> "|" <> StringRiffle[Sort[targets], ","] <> "|" <> reason},
  If[KeyExistsQ[s["Seen"], key], Return[{s, Null}]];
  With[{r = iSVIEntityFinding[targets, kind, sev, reason, detail]},
    {If[AssociationQ[r], Append[s, "Seen" -> Append[s["Seen"], key -> iSVINowIso[]]], s], r}]];

(* ---- 内容の取り出し: blob store (ハッシュ照合つき) → LogicalRef のファイル → Instruction の基準のパス ---- *)
iSVIInstrPathOf[eid_String] := With[{b = iSVIReadBaselineCached[]},
  If[AssociationQ[b], SelectFirst[Keys[b["Entries"]], Lookup[b["Entries"][#], "EntityId", None] === eid &, None], None]];
iSVIContentOf[row_Association] := Module[{bid = Lookup[row, "BlobId", Null], lr = Lookup[row, "LogicalRef", Null], r, path, b},
  If[StringQ[bid] && Length[DownValues[SourceVault`SourceVaultReadBlob]] > 0,
    r = Quiet @ Check[SourceVault`SourceVaultReadBlob[bid], $Failed];
    If[AssociationQ[r] && r["Status"] === "OK", Return[<|"Bytes" -> r["Bytes"], "Source" -> "Blob", "Matches" -> True|>]];
    If[AssociationQ[r] && Lookup[r, "Reason", ""] === "BlobCorruption", Return[<|"Corrupt" -> True, "Source" -> "Blob", "Matches" -> False|>]]];
  path = Which[
    StringQ[lr] && StringStartsQ[lr, "instr://"], iSVIInstrPathOf[row["EntityId"]],
    StringQ[lr] && ! StringStartsQ[lr, "sv://" | "kb:" | "pdfindex:" | "instr://" | "http"] && Quiet[FileExistsQ[lr]] && ! DirectoryQ[lr], lr,
    True, None];
  If[StringQ[path], b = iSVIReadBytes[path];
    If[ByteArrayQ[b], Return[<|"Bytes" -> b, "Source" -> "File", "Path" -> path, "Matches" -> ("blob:sha256:" <> Hash[b, "SHA256", "HexString"] === bid)|>]]];
  <|"Source" -> "None"|>];
iSVITextOf[c_Association] := If[ByteArrayQ[Lookup[c, "Bytes", None]], Quiet @ Check[ByteArrayToString[c["Bytes"], "UTF-8"], $Failed], $Failed];
iSVIProvRows[fn_String, args___] := With[{f = Symbol["SourceVault`ProvenancePrivate`" <> fn]},
  If[Length[DownValues[f]] > 0, Quiet @ Check[f[args], $Failed], $Failed]];

(* ---- 不可視文字 (Unicode Tag・ゼロ幅・双方向制御・異体字セレクタの連続) ---- *)
iSVIInvisibleScan[s_String] := Module[{c = ToCharacterCode[s], vs, runs},
  vs = Boole[(65024 <= # <= 65039) || (917760 <= # <= 917999)] & /@ c;
  runs = Count[Partition[vs, 2, 1], {1, 1}];
  <|"Tag" -> Count[c, x_ /; 917504 <= x <= 917631], "ZeroWidth" -> Count[Rest[Prepend[c, 0]], 8203 | 8204 | 8205 | 8288] + Count[Rest[c], 65279],
    "Bidi" -> Count[c, 8206 | 8207 | 8234 | 8235 | 8236 | 8237 | 8238 | 8294 | 8295 | 8296 | 8297], "VariationRuns" -> runs|>];
iSVIInvisibleTotal[a_Association] := Total[Values[a]];
iSVIPreScanFlag[s_String] := If[Length[DownValues[SourceVault`SourceVaultSecurityPreScan]] > 0,
  With[{r = Quiet @ Check[SourceVault`SourceVaultSecurityPreScan[s], $Failed]}, AssociationQ[r] && Lookup[r, "SafetyState", ""] === "quarantined"], False];

(* ---- InjectionResidue (毎回、増分): 新しい PrimarySource・Instruction・DerivedCode と、内容が変わった Instruction 系ファイル ----
   2026-11-11 (規則の版 2): 命令系 (Kind Instruction と Instruction 系ファイル) には注入の pre-scan で Finding を出さない。pre-scan は外部の文書
   (Web・メール) 向けの「指示文らしさ」の判定で、命令系のファイルはそもそも指示文でできているため、所有者の CLAUDE.md・rules・skill・
   ワークフローが High で隔離された (11-11 に 8 件、不可視文字はどれも 0)。命令系では不可視文字 (Unicode Tag・ゼロ幅・双方向制御・
   異体字セレクタの連続) だけを High にし、pre-scan に掛かった数は Counts の PreScanHitsInInstructions に参考として残す。モデルが書き得る
   命令の無記録の変更は InstructionDrift と LoadVerify が止める。規則の版が変わったら Instruction 系ファイルをすべて読み直す
   (以前の規則で付けた FlaggedInstr を、内容が変わっていなくても見直すため)。既に台帳に記録された Finding は所有者が FalsePositive で解決する。 *)
$iSVIInjectionRuleVersion = 2;
iSVICheckInjectionResidue[s0_Association, budget_] := Module[{s = s0, t0 = AbsoluteTime[], rows, flagged = {}, instrFlag = {}, scanned = 0, files, r, preInstr = 0},
  If[Lookup[s, "InjectionRuleVersion", 1] =!= $iSVIInjectionRuleVersion,
    s["InstrBlobs"] = <||>; s["FlaggedInstr"] = <||>; s["InjectionRuleVersion"] = $iSVIInjectionRuleVersion];
  rows = iSVIProvRows["iProvEntitiesSince", Lookup[s["Seqs"], "Injection", 0], {"PrimarySource", "Instruction", "DerivedCode"}];
  If[AssociationQ[rows],
    Scan[Function[row, If[AbsoluteTime[] - t0 < budget, Module[{c = iSVIContentOf[row], t, inv, pre, reasons},
        t = iSVITextOf[c];
        If[StringQ[t], scanned++;
          inv = iSVIInvisibleScan[t]; pre = iSVIPreScanFlag[t];
          If[row["Kind"] === "Instruction", If[pre, preInstr++]; pre = False];
          reasons = Join[Keys[Select[inv, # > 0 &]], If[pre, {"PreScanQuarantined"}, {}]];
          If[reasons =!= {},
            {s, r} = iSVIEntityFindingOnce[s, {row["EntityId"]}, "InjectionResidue", "High", StringRiffle[reasons, "+"], inv];
            AppendTo[flagged, row["EntityId"]];
            If[row["Kind"] === "Instruction", AppendTo[instrFlag, row["EntityId"]]]]]]]], rows["Rows"]];
    s["Seqs", "Injection"] = rows["IndexSeq"]];
  (* Instruction 系ファイル: 内容 (BlobId) が変わったものだけ読み直す。検出したら内容 (BlobId) に Finding (同じ内容の版はすべて隔離) *)
  files = Quiet @ Check[SourceVaultInstructionFiles[], {}];
  Scan[Function[f, If[AbsoluteTime[] - t0 < budget, Module[{bid = iSVIFileBlobId[f["Path"]], t, inv, pre, reasons},
      If[StringQ[bid] && Lookup[s["InstrBlobs"], f["Path"], None] =!= bid,
        t = With[{b = iSVIReadBytes[f["Path"]]}, If[ByteArrayQ[b], Quiet @ Check[ByteArrayToString[b, "UTF-8"], $Failed], $Failed]];
        If[StringQ[t], scanned++;
          inv = iSVIInvisibleScan[t]; pre = iSVIPreScanFlag[t];
          If[pre, preInstr++]; pre = False;  (* 命令系ファイルは不可視文字だけで判定する (規則の版 2) *)
          reasons = Join[Keys[Select[inv, # > 0 &]], If[pre, {"PreScanQuarantined"}, {}]];
          If[reasons =!= {},
            {s, r} = iSVIEntityFindingOnce[s, {bid}, "InjectionResidue", "High", StringRiffle[reasons, "+"], Join[inv, <|"Class" -> f["Class"]|>]];
            s["FlaggedInstr", f["Path"]] = bid,
            s["FlaggedInstr"] = KeyDrop[s["FlaggedInstr"], f["Path"]]]];
        s["InstrBlobs", f["Path"]] = bid]]]], files];
  (* いまも同じ内容のまま残っている Instruction 系の検出は Failing (7.1 節) *)
  instrFlag = Join[instrFlag, Select[Keys[s["FlaggedInstr"]], Lookup[s["InstrBlobs"], #, None] === s["FlaggedInstr"][#] &]];
  {s, <|"Health" -> Which[instrFlag =!= {}, "Failing", flagged =!= {}, "Degraded", True, "OK"],
    "ReasonCode" -> Which[instrFlag =!= {}, "InjectionResidueInInstruction", flagged =!= {}, "InjectionResidue", True, "InjectionResidueOK"],
    "Counts" -> <|"Scanned" -> scanned, "Flagged" -> Length[flagged], "InstructionFlagged" -> Length[DeleteDuplicates[instrFlag]],
      "PreScanHitsInInstructions" -> preInstr, "RuleVersion" -> $iSVIInjectionRuleVersion|>|>}];

(* ---- CitationIntegrity (日次): Quote の文字列が引用先に無い・引用先が隔離中 → Medium (隔離しない) ---- *)
iSVINormText[t_String] := ToLowerCase[StringDelete[Quiet @ Check[CharacterNormalize[t, "NFKC"], t], WhitespaceCharacter]];
iSVIQuoteSpans[t_String] := DeleteDuplicates @ Select[StringTrim /@ Join[
    StringCases[t, "\:300c" ~~ x : Except["\:300d"] .. ~~ "\:300d" :> x],
    StringCases[t, "\:201c" ~~ x : Except["\:201d"] .. ~~ "\:201d" :> x],
    StringCases[t, "\"" ~~ x : Except["\"" | "\n"] .. ~~ "\"" :> x],
    StringCases[t, StartOfLine ~~ ">" ~~ x : Except["\n"] .. :> x]], StringLength[iSVINormText[#]] >= 6 &];
iSVICheckCitationIntegrity[s0_Association, budget_] := Module[{s = s0, t0 = AbsoluteTime[], edges, bad = 0, checked = 0, r, rowsCache = <||>, rowOf},
  edges = iSVIProvRows["iProvQuoteCiteEdges"];
  If[! ListQ[edges], Return[{s, <|"Health" -> "OK", "ReasonCode" -> "IndexUnavailable"|>}]];
  rowOf = Function[id, If[KeyExistsQ[rowsCache, id], rowsCache[id], rowsCache[id] = iSVIProvRows["iProvEntityRow", id]]];
  Scan[Function[ed, If[AbsoluteTime[] - t0 < budget, Module[{src = rowOf[ed["Source"]], tgt = rowOf[ed["Target"]], ts, tt, spans, missing},
      checked++;
      Which[
        AssociationQ[src] && src["Usability"] === "Quarantined",
          {s, r} = iSVIEntityFindingOnce[s, {ed["Target"]}, "CitationIntegrity", "Medium", ed["Role"] <> "OfQuarantined"]; If[AssociationQ[r], bad++],
        ed["Role"] === "Quote" && AssociationQ[src] && AssociationQ[tgt],
          ts = iSVITextOf[iSVIContentOf[src]]; tt = iSVITextOf[iSVIContentOf[tgt]];
          If[StringQ[ts] && StringQ[tt],
            spans = iSVIQuoteSpans[tt];
            missing = Select[spans, ! StringContainsQ[iSVINormText[ts], iSVINormText[#]] &];
            If[missing =!= {},
              {s, r} = iSVIEntityFindingOnce[s, {ed["Target"]}, "CitationIntegrity", "Medium", "QuoteNotInSource",
                <|"Spans" -> Length[spans], "Missing" -> Length[missing], "Source" -> ed["Source"]|>]; bad++]]]]]], edges];
  {s, <|"Health" -> If[bad > 0, "Degraded", "OK"], "ReasonCode" -> If[bad > 0, "CitationMismatch", "CitationIntegrityOK"],
    "Counts" -> <|"Edges" -> Length[edges], "Checked" -> checked, "Mismatched" -> bad|>|>}];

(* ---- GeneratedCodeHealth (毎回、増分、7.3 節): 前の版との差 ---- *)
iSVICallCount[t_String, name_String] := StringCount[t, RegularExpression["(?<![A-Za-z0-9$`])" <> name <> "\\s*\\["]];
iSVICodeMetrics[t_String] := <|"Dynamic" -> Total[iSVICallCount[t, #] & /@ $iSVIDynamicEvalNames],
  "Approval" -> Total[iSVICallCount[t, #] & /@ $SourceVaultApprovalHeads],
  "Sensitive" -> Select[$iSVISensitiveNames, iSVICallCount[t, #] > 0 &], "LintIgnore" -> StringCount[t, ":PolicyLintIgnore:"],
  "Invisible" -> iSVIInvisibleTotal[iSVIInvisibleScan[t]], "Syntax" -> TrueQ[Quiet @ SyntaxQ[t]]|>;
iSVICheckGeneratedCode[s0_Association, budget_] := Module[{s = s0, t0 = AbsoluteTime[], rows, n = 0, high = 0, instrHigh = 0, med = 0, r, kinds = <||>},
  rows = iSVIProvRows["iProvEntitiesSince", Lookup[s["Seqs"], "Code", 0], {"DerivedCode", "Instruction"}];
  If[! AssociationQ[rows], Return[{s, <|"Health" -> "OK", "ReasonCode" -> "IndexUnavailable"|>}]];
  Scan[Function[row, If[AbsoluteTime[] - t0 < budget && (row["Kind"] === "DerivedCode" || StringQ[row["LogicalRef"]] && StringStartsQ[row["LogicalRef"], "instr://workflow"]),
      Module[{t = iSVITextOf[iSVIContentOf[row]], pt = Missing[], m, pm, instrQ = row["Kind"] === "Instruction", emit},
        If[! StringQ[t], Return[Null, Module]];
        n++; m = iSVICodeMetrics[t];
        If[StringQ[row["Previous"]], With[{prow = iSVIProvRows["iProvEntityRow", row["Previous"]]}, If[AssociationQ[prow], pt = iSVITextOf[iSVIContentOf[prow]]]]];
        pm = If[StringQ[pt], iSVICodeMetrics[pt], None];
        emit = Function[{sev, reason, det}, {s, r} = iSVIEntityFindingOnce[s, {row["EntityId"]}, "GeneratedCodeHealth", sev, reason, det];
          kinds[reason] = Lookup[kinds, reason, 0] + 1;
          Switch[sev, "High", high++; If[instrQ, instrHigh++], "Medium", med++, _, Null]];
        If[! m["Syntax"], emit["Low", "SyntaxError", <||>]];
        If[m["Invisible"] > 0, emit["High", "InvisibleCharacters", <|"Count" -> m["Invisible"]|>]];
        If[m["LintIgnore"] > If[AssociationQ[pm], pm["LintIgnore"], 0], emit["High", "PolicyLintIgnoreAdded", <|"Count" -> m["LintIgnore"]|>]];
        If[AssociationQ[pm],
          If[m["Dynamic"] + m["Approval"] > pm["Dynamic"] + pm["Approval"],
            emit[If[instrQ, "High", "Medium"], "DynamicEvalIncreased", <|"Now" -> m["Dynamic"] + m["Approval"], "Before" -> pm["Dynamic"] + pm["Approval"]|>]];
          With[{added = Complement[m["Sensitive"], pm["Sensitive"]]},
            If[added =!= {}, emit["High", "SensitiveCallAdded", <|"Names" -> added|>]]]]]]], rows["Rows"]];
  s["Seqs", "Code"] = rows["IndexSeq"];
  {s, <|"Health" -> Which[instrHigh > 0, "Failing", high > 0 || med > 0, "Degraded", True, "OK"],
    "ReasonCode" -> Which[instrHigh > 0, "GeneratedCodeHealthInstruction", high > 0 || med > 0, "GeneratedCodeHealth", True, "GeneratedCodeOK"],
    "Counts" -> <|"Checked" -> n, "High" -> high, "Medium" -> med, "ByReason" -> kinds|>|>}];

(* ---- EntityDrift (日次、標本 500): blob store の内容の食い違い・LogicalRef のファイルが最新の版と違う → Medium、子孫は Stale ---- *)
iSVICheckEntityDrift[s0_Association, budget_, sampleN_: 500] := Module[{s = s0, t0 = AbsoluteTime[], smp, checked = 0, drift = 0, r},
  smp = iSVIProvRows["iProvEntitySample", sampleN];
  If[! AssociationQ[smp], Return[{s, <|"Health" -> "OK", "ReasonCode" -> "IndexUnavailable"|>}]];
  Scan[Function[row, If[AbsoluteTime[] - t0 < budget && ! (StringQ[row["LogicalRef"]] && StringStartsQ[row["LogicalRef"], "instr://"]),
      Module[{c = iSVIContentOf[row]},
        Which[
          TrueQ[Lookup[c, "Corrupt", False]], checked++; drift++;
            {s, r} = iSVIEntityFindingOnce[s, {row["EntityId"]}, "EntityDrift", "Medium", "BlobCorruption"],
          c["Source"] === "File" && TrueQ[Lookup[row, "Latest", True]], checked++;
            If[! TrueQ[c["Matches"]], drift++; {s, r} = iSVIEntityFindingOnce[s, {row["EntityId"]}, "EntityDrift", "Medium", "FileChangedOutsideRecord"]],
          c["Source"] === "Blob", checked++,
          True, Null]]]], smp["Rows"]];
  {s, <|"Health" -> If[checked > 0 && drift/checked > 0.01, "Degraded", "OK"], "ReasonCode" -> If[drift > 0, "EntityDrift", "EntityDriftOK"],
    "Counts" -> <|"Sampled" -> Length[smp["Rows"]], "Checked" -> checked, "Drifted" -> drift, "Total" -> smp["Total"]|>|>}];

(* ---- LM Studio の機の設定 (Models 部品)。値は必要な鍵だけを取り出す (トークン等は持たない) ---- *)
iSVILMRoot[] := If[StringQ[$SourceVaultLMStudioRoot], $SourceVaultLMStudioRoot, FileNameJoin[{$HomeDirectory, ".lmstudio"}]];
iSVILMJSON[rel__String] := iSVIReadJSON[FileNameJoin[{iSVILMRoot[], rel}]];
iSVILMInstallDir[] := Module[{d = $SourceVaultLMStudioInstallDir, a},
  If[StringQ[d], Return[d]];
  a = iSVILMJSON[".internal", "app-install-location.json"];
  If[AssociationQ[a] && StringQ[Lookup[a, "cwd", None]], a["cwd"], None]];
iSVILMVersion[] := With[{d = iSVILMInstallDir[]}, If[StringQ[d],
  With[{p = iSVIReadJSON[FileNameJoin[{d, "resources", "app", "package.json"}]]}, If[AssociationQ[p] && StringQ[Lookup[p, "version", None]], p["version"], Missing["Unknown"]]],
  Missing["Unknown"]]];
iSVIVersionList[v_String] := FromDigits /@ StringCases[First[StringSplit[v, "+" | "-"], v], DigitCharacter ..];
iSVIVersionLess[a_String, b_String] := Module[{x = iSVIVersionList[a], y = iSVIVersionList[b], n},
  n = Max[Length[x], Length[y]]; x = PadRight[x, n]; y = PadRight[y, n];
  With[{d = SelectFirst[Transpose[{x, y}], #[[1]] =!= #[[2]] &, None]}, ListQ[d] && d[[1]] < d[[2]]]];

Options[SourceVaultModelManifest] = {};
SourceVaultModelManifest[OptionsPattern[]] := Module[{root = iSVILMRoot[], idx, gg, tpl = <||>, models = <||>, http, perm, ver},
  If[! DirectoryQ[root], Return[<|"Format" -> "SourceVaultModelManifest/1", "Status" -> "NotApplicable", "Root" -> Null|>]];
  gg = iSVILMJSON[".internal", "gguf-metadata-cache.json"];
  If[AssociationQ[gg] && ListQ[Lookup[Lookup[gg, "json", <||>], "map", None]],
    Scan[Function[pr, If[ListQ[pr] && Length[pr] >= 2 && StringQ[pr[[1]]] && AssociationQ[pr[[2]]],
        With[{ct = Lookup[Lookup[pr[[2]], "metadata", <||>], "chatTemplate", Null]},
          tpl[FileNameTake[pr[[1]]]] = If[StringQ[ct], "sha256:" <> iSVISHAHex[ct], Null]]]], gg["json"]["map"]]];
  idx = iSVILMJSON[".internal", "model-index-cache.json"];
  If[AssociationQ[idx] && ListQ[Lookup[idx, "models", None]],
    Scan[Function[m, If[AssociationQ[m] && StringQ[Lookup[m, "indexedModelIdentifier", None]],
        models[m["indexedModelIdentifier"]] = <|"Domain" -> Lookup[m, "domain", Null], "Format" -> Lookup[m, "format", Null], "Arch" -> Lookup[m, "arch", Null],
          "Quant" -> With[{q = Lookup[m, "quant", Null]}, If[AssociationQ[q], ToString @ Lookup[q, "name", ""], q]], "SizeBytes" -> Lookup[m, "sizeBytes", Null],
          "TemplateDigest" -> Lookup[tpl, FileNameTake[m["indexedModelIdentifier"]], Null]|>]], idx["models"]]];
  http = iSVILMJSON[".internal", "http-server-config.json"]; perm = iSVILMJSON[".internal", "permissions-store.json"];
  ver = iSVILMVersion[];
  <|"Format" -> "SourceVaultModelManifest/1", "Status" -> "OK", "Machine" -> If[Length[DownValues[SourceVault`SourceVaultMachineTag]] > 0, SourceVault`SourceVaultMachineTag[], $MachineName],
    "Runtime" -> <|"Name" -> "LM Studio", "Version" -> If[StringQ[ver], ver, Null]|>, "Models" -> KeySort[models],
    "Network" -> <|"Interface" -> If[AssociationQ[http], Lookup[http, "networkInterface", Null], Null], "Port" -> If[AssociationQ[http], Lookup[http, "port", Null], Null],
      "TokenMode" -> If[AssociationQ[perm], Lookup[Lookup[perm, "json", <||>], "tokenMode", Null], Null]|>,
    (* 重みの全体ハッシュは計算していない (メタデータだけ)。表 4.3 の Measured ではなく Claimed *)
    "IdentityEvidence" -> "Claimed", "WeightsHashedAtUTC" -> Null, "ComputedAtUTC" -> iSVINowIso[]|>];
iSVIModelBaselinePath[] := iSVIHealthPath["model-manifest-baseline.json"];
iSVIAdvisoryHits[ver_] := If[! StringQ[ver], {}, Select[Select[$SourceVaultModelRuntimeAdvisories, AssociationQ], Function[a,
  Lookup[a, "Runtime", "LM Studio"] === "LM Studio" && (
    (StringQ[Lookup[a, "AffectedBelow", None]] && iSVIVersionLess[ver, a["AffectedBelow"]]) ||
    (ListQ[Lookup[a, "Versions", None]] && MemberQ[a["Versions"], First[StringSplit[ver, "+"], ver]]))]]];
SourceVaultModelManifestDiff[] := Module[{cur = SourceVaultModelManifest[], base, bm, cm, newM, gone, tplCh, adv},
  If[cur["Status"] =!= "OK", Return[<|"Status" -> cur["Status"]|>]];
  base = iSVIReadJSON[iSVIModelBaselinePath[]];
  adv = iSVIAdvisoryHits[cur["Runtime"]["Version"]];
  If[! AssociationQ[base] || ! AssociationQ[Lookup[base, "Models", None]],
    (* 2026-11-11: 括弧が無いと ("Advisories" -> ..) & /@ adv と読まれ、注意情報が 0 件のとき "Advisories" の項目ごと消えて
       Missing =!= {} で RuntimeAdvisory (Failing) になっていた *)
    Return[<|"Status" -> "BaselineMissing", "Advisories" -> (Lookup[#, "Id", "?"] & /@ adv), "Models" -> Length[cur["Models"]]|>]];
  bm = base["Models"]; cm = cur["Models"];
  newM = Complement[Keys[cm], Keys[bm]]; gone = Complement[Keys[bm], Keys[cm]];
  tplCh = Select[Intersection[Keys[cm], Keys[bm]], Lookup[cm[#], "TemplateDigest", Null] =!= Lookup[bm[#], "TemplateDigest", Null] &];
  <|"Status" -> "OK", "NewModels" -> newM, "RemovedModels" -> gone, "TemplateChanged" -> tplCh,
    "RuntimeChanged" -> Lookup[Lookup[base, "Runtime", <||>], "Version", Null] =!= cur["Runtime"]["Version"],
    "Runtime" -> cur["Runtime"], "Advisories" -> (Lookup[#, "Id", "?"] & /@ adv), "BaselineAcceptedAtUTC" -> Lookup[base, "AcceptedAtUTC", Null]|>];
iSVICheckModelManifest[] := Module[{d = SourceVaultModelManifestDiff[]},
  Switch[d["Status"],
    "NotApplicable", <|"Health" -> "OK", "ReasonCode" -> "NotApplicable"|>,
    "BaselineMissing", <|"Health" -> If[d["Advisories"] =!= {}, "Failing", "Degraded"],
      "ReasonCode" -> If[d["Advisories"] =!= {}, "RuntimeAdvisory", "ModelManifestBaselineMissing"], "Counts" -> <|"Models" -> d["Models"], "Advisories" -> d["Advisories"]|>|>,
    _, With[{fail = d["TemplateChanged"] =!= {} || d["Advisories"] =!= {}},
      If[fail, iSVIFinding["Models", If[d["Advisories"] =!= {}, "RuntimeAdvisory", "ModelTemplateChanged"], "High", "Failing",
        "Targets" -> Join[d["TemplateChanged"], d["Advisories"]]]];
      <|"Health" -> Which[fail, "Failing", d["NewModels"] =!= {} || TrueQ[d["RuntimeChanged"]], "Degraded", True, "OK"],
        "ReasonCode" -> Which[d["Advisories"] =!= {}, "RuntimeAdvisory", d["TemplateChanged"] =!= {}, "ModelTemplateChanged",
          d["NewModels"] =!= {}, "NewModelPendingAcceptance", TrueQ[d["RuntimeChanged"]], "RuntimeChanged", True, "ModelManifestOK"],
        "Counts" -> <|"New" -> Length[d["NewModels"]], "Removed" -> Length[d["RemovedModels"]], "TemplateChanged" -> Length[d["TemplateChanged"]],
          "Advisories" -> d["Advisories"], "RuntimeVersion" -> d["Runtime"]["Version"]|>|>]]];
iSVIAcceptModelBaseline[ticket_, dryRun_, note_String] := Module[{cur = SourceVaultModelManifest[], display, dig},
  If[cur["Status"] =!= "OK", Return[Failure["NotApplicable", <|"Reason" -> "LMStudioRootAbsent"|>]]];
  dig = iSVISHAHex[ToString[KeySort[cur["Models"]], InputForm] <> "|" <> ToString[cur["Runtime"]["Version"]]];
  display = StringRiffle[Join[{"ModelManifest の基準の受入 (03 v0.4 7.1 Models)", "LM Studio: " <> ToString[cur["Runtime"]["Version"]], "モデル:"},
    KeyValueMap[#1 <> "  template " <> StringTake[ToString[Lookup[#2, "TemplateDigest", "-"]], UpTo[20]] &, cur["Models"]]], "\n"];
  If[TrueQ[dryRun], Return[<|"Status" -> "ReviewRequired", "Component" -> "ModelManifest", "BindDisplay" -> display, "TicketAction" -> "AcceptBaseline",
    "Bind" -> <|"Component" -> iSVITicketDigest["ModelManifest"], "Snapshot" -> iSVITicketDigest[dig], "Display" -> iSVITicketDigest[display]|>|>]];
  iSVIOwnerOperation["SourceVaultIntegrityAcceptBaseline", "AcceptBaseline", <|"Component" -> iSVITicketDigest["ModelManifest"], "Snapshot" -> iSVITicketDigest[dig]|>,
    display, ticket,
    Function[t, With[{w = iSVIWriteJSON[iSVIModelBaselinePath[], Join[KeyTake[cur, {"Runtime", "Models", "Machine"}],
        <|"Format" -> "SourceVaultModelManifestBaseline/1", "AcceptedAtUTC" -> iSVINowIso[], "TicketNonce" -> ToString @ Lookup[t, "Nonce", ""], "Note" -> note|>]]},
      <|"Status" -> If[w === $Failed, "BaselineWriteFailed", "Accepted"], "Component" -> "ModelManifest", "Models" -> Length[cur["Models"]]|>]]]];

(* LMStudioMCPScope (10 分): 運用前提 (LM Studio の MCP は SourceVault だけ) の検証 *)
iSVIMCPServerOK[spec_] := AssociationQ[spec] && ! KeyExistsQ[spec, "command"] && StringQ[Lookup[spec, "url", None]] &&
  StringMatchQ[spec["url"], RegularExpression["^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\])(:[0-9]+)?/sv/mcp/?$"]];
iSVICheckLMStudioScope[] := Module[{root = iSVILMRoot[], v = <||>, deg = {}, mcp, synced, perm, http, set, readTools, pats, bad},
  If[! DirectoryQ[root], Return[<|"Health" -> "OK", "ReasonCode" -> "NotApplicable", "Message" -> "not the LM Studio machine"|>]];
  mcp = iSVILMJSON["mcp.json"]; synced = iSVILMJSON[".internal", "last-synced-mcp-state.json"];
  With[{f = Function[{a, code}, If[AssociationQ[a] && AssociationQ[Lookup[a, "mcpServers", None]],
        With[{badS = Keys[Select[a["mcpServers"], ! iSVIMCPServerOK[#] &]]}, If[badS =!= {}, v[code] = badS]]]]},
    f[mcp, "MCPServerNotAllowed"]; f[synced, "SyncedMCPServerNotAllowed"]];
  perm = iSVILMJSON[".internal", "permissions-store.json"];
  If[AssociationQ[perm] && AssociationQ[Lookup[perm, "json", None]],
    With[{sp = Lookup[perm["json"], "serverPermissions", <||>], toks = Select[Flatten[{Lookup[perm["json"], "tokens", {}]}], AssociationQ]},
      If[AssociationQ[sp] && Lookup[sp, "dynamicRemoteMcpServer", "deny"] =!= "deny", v["DynamicRemoteMcpAllowed"] = {"server"}];
      With[{n = Count[toks, t_ /; Lookup[Lookup[t, "permissions", <||>], "dynamicRemoteMcpServer", "deny"] =!= "deny"]},
        If[n > 0, v["TokenDynamicRemoteMcpAllowed"] = {ToString[n] <> " token(s)"}]]]];
  http = iSVILMJSON[".internal", "http-server-config.json"];
  If[AssociationQ[http],
    If[! MemberQ[{"127.0.0.1", "localhost", "::1"}, Lookup[http, "networkInterface", "127.0.0.1"]] &&
        (! AssociationQ[perm] || Lookup[Lookup[perm, "json", <||>], "tokenMode", "disabled"] === "disabled"),
      v["LANWithoutAuth"] = {ToString @ Lookup[http, "networkInterface", "?"]}];
    If[TrueQ[Lookup[http, "logSensitiveData", False]], AppendTo[deg, "LogSensitiveData"]]];
  set = iSVILMJSON["settings.json"];
  If[AssociationQ[set] && AssociationQ[Lookup[set, "chat", None]],
    readTools = With[{t = iSVIValueByName["$ClaudeLocalToolLoopTools"]}, If[ListQ[t], Select[t, StringQ], None]];
    pats = Select[Flatten[{Lookup[set["chat"], "skipToolConfirmationPatterns", {}]}], StringQ];
    bad = Select[pats, Function[p, StringContainsQ[p, "*"] ||
      With[{tool = Last[StringSplit[p, ":"], p]}, MemberQ[$iSVILMStudioWriteTools, tool] || (ListQ[readTools] && StringStartsQ[tool, "sourcevault_"] && ! MemberQ[readTools, tool])]]];
    If[bad =!= {}, v["SkipConfirmationIncludesWriteTools"] = bad];
    If[TrueQ[Lookup[set["chat"], "neverAskForToolConfirmation", False]], v["NeverAskToolConfirmation"] = {"chat"}]];
  If[v =!= <||>, iSVIFinding["Models", "LMStudioMCPScopeViolated", "High", "Failing", "Targets" -> Keys[v]]];
  <|"Health" -> Which[v =!= <||>, "Failing", deg =!= {}, "Degraded", True, "OK"],
    "ReasonCode" -> Which[v =!= <||>, "LMStudioMCPScopeViolated", deg =!= {}, First[deg], True, "LMStudioMCPScopeOK"],
    "Message" -> If[v === <||>, "LM Studio uses only the SourceVault MCP server", "violations: " <> StringRiffle[Keys[v], ", "]],
    "Counts" -> <|"Violations" -> Keys[v], "Detail" -> v, "Degraded" -> deg|>|>];

(* ---- EgressPattern (日次): 高 PL を読んだセッションの直後の新規ホスト・Opaque の比率・量の外れ ---- *)
iSVIEgressRows[] := If[Length[DownValues[SourceVault`SourceVaultWebAccessLog]] > 0,
  With[{r = Quiet @ Check[SourceVault`SourceVaultWebAccessLog["Days" -> 30, "Limit" -> 100000], $Failed]}, If[ListQ[r], Select[r, AssociationQ], $Failed]], $Failed];
iSVICheckEgressPattern[] := Module[{rows, now = AbsoluteTime[], recent, prior, newHosts, flagged = <||>, opaque, reasons = {}, byDay, today, med, mad},
  rows = iSVIEgressRows[];
  If[! ListQ[rows], Return[<|"Health" -> "OK", "ReasonCode" -> "NotApplicable"|>]];
  rows = Select[Map[Join[#, <|"Abs" -> iSVIIsoToAbs[ToString @ Lookup[#, "At", ""]]|>] &, rows], NumberQ[#["Abs"]] && StringQ[Lookup[#, "Host", None]] && #["Host"] =!= "" &];
  recent = Select[rows, now - #["Abs"] <= 86400 &]; prior = Select[rows, now - #["Abs"] > 86400 &];
  newHosts = Complement[Union[Lookup[recent, "Host", {}]], Union[Lookup[prior, "Host", {}]]];
  (* セッション (SessionId、無ければ ActorId) ごとに時刻順。PL 0.5 以上の文脈の行の後 30 分以内に新規ホスト 2 つ以上 *)
  KeyValueMap[Function[{sk, rs}, Module[{srt = SortBy[rs, #["Abs"] &]},
      Do[If[NumericQ[Lookup[srt[[i]], "ContextPL", Null]] && srt[[i]]["ContextPL"] >= 0.5,
          With[{after = Union[Select[Lookup[Select[Drop[srt, i], #["Abs"] - srt[[i]]["Abs"] <= 1800 &], "Host", {}], MemberQ[newHosts, #] &]]},
            If[Length[after] >= 2, flagged[sk] = Length[after]]]], {i, Length[srt]}]]],
    GroupBy[recent, Function[r, ToString @ With[{s = Lookup[r, "SessionId", Missing[]]}, If[StringQ[s] && s =!= "", s, Lookup[r, "ActorId", "?"]]]]]];
  If[flagged =!= <||>, AppendTo[reasons, "HighPLThenNewHosts"]];
  opaque = Count[recent, r_ /; Lookup[r, "Class", ""] === "Opaque"];
  If[Length[recent] >= 10 && opaque/Length[recent] > 0.5, AppendTo[reasons, "OpaqueRatioHigh"]];
  byDay = Counts[Floor[(now - #["Abs"])/86400] & /@ rows];
  today = Lookup[byDay, 0, 0];
  With[{base = Lookup[byDay, Range[1, 29], 0]},
    If[Count[base, _?Positive] >= 8, med = Median[base]; mad = Median[Abs[base - med]];
      If[(today - med)/Max[1, 1.4826 mad] > 3.5, AppendTo[reasons, "VolumeOutlier"]]]];
  If[reasons =!= {}, iSVIFinding["Egress", "EgressPattern", "Medium", "Degraded", "Targets" -> reasons,
    "Detail" -> <|"Sessions" -> Length[flagged], "NewHosts" -> Length[newHosts]|>, "Publish" -> False]];
  <|"Health" -> If[reasons =!= {}, "Degraded", "OK"], "ReasonCode" -> If[reasons =!= {}, First[reasons], "EgressPatternOK"],
    "Counts" -> <|"Rows" -> Length[rows], "Recent" -> Length[recent], "NewHosts" -> Length[newHosts], "FlaggedSessions" -> Length[flagged],
      "OpaqueRecent" -> opaque, "Reasons" -> reasons|>|>];

(* ---- PublishUnusable (毎回、増分): 公開の入力に隔離中・Unknown の版。Finding が公開より前なら関所の破れ (Critical) ---- *)
(* 2026-11-11 (F04): 公開の意図 (Outcome Approved) のうち、送信・コミットが失敗した (SourceVaultIntegrityPublishOutcome の Failed、所有者・service の
   記録だけ、来歴側が Result に入れる) ものは公開されていないので数えない。結果の記録そのもの (IntentActivity を持つ行) も数えない *)
iSVICheckPublishUnusable[s0_Association] := Module[{s = s0, pa, breach = {}, later = 0},
  pa = iSVIProvRows["iProvPublishActivities", Lookup[s["Seqs"], "Publish", 0]];
  If[! AssociationQ[pa], Return[{s, <|"Health" -> "OK", "ReasonCode" -> "IndexUnavailable"|>}]];
  Scan[Function[a, If[a["Outcome"] =!= "Blocked" && ! StringQ[Lookup[a, "IntentActivity", Null]] && Lookup[a, "Result", Null] =!= "Failed",
      Scan[Function[in, Which[
          in["Usability"] === "Quarantined" && AnyTrue[in["FindingSeqs"], # < a["Seq"] &], AppendTo[breach, a["ActivityId"]],
          in["Usability"] === "Quarantined", later++,
          in["Usability"] === "Unknown", AppendTo[breach, a["ActivityId"]],
          True, Null]], a["Inputs"]]]], pa["Rows"]];
  s["Seqs", "Publish"] = pa["IndexSeq"];
  breach = DeleteDuplicates[breach];
  If[breach =!= {}, iSVIFinding["Egress", "UnusablePublished", "Critical", "Failing", "Targets" -> breach]];
  {s, <|"Health" -> If[breach =!= {}, "Failing", If[later > 0, "Degraded", "OK"]],
    "ReasonCode" -> Which[breach =!= {}, "UnusablePublished", later > 0, "PublishedThenQuarantined", True, "PublishOK"],
    "Counts" -> <|"Checked" -> Length[pa["Rows"]], "Breaches" -> Length[breach], "OpenPublications" -> later|>|>}];

(* ---- 公開の関所 (9.2 節、6.2 節の Inc 4 の記録点)。Inc1〜Inc4 は最後に確定した索引で隔離中・Unknown の版を含むときだけ止め、
   索引が使えない・24 時間より古いときは記録して通す (D-27) ---- *)
(* 2026-11-11 (レビュー 20261111 F03 / F04): 索引の状態は検索フィルタ・LoadVerify と同じ判定 (iSVIExtrasState。再構築中・連鎖の破損も
   使えない扱いで、以前は表が残っていれば Allow になった)。名指しの版 (EntityId) が確定して Usable でなければ NotCommitted で止める。
   公開の記録は意図 (Outcome Approved / Blocked) とし、書けなければ ProvenanceUnavailable で止める。実際の成否は呼び出し側が
   SourceVaultIntegrityPublishOutcome で別に残す (以前は送信の前に Succeeded を書いていた)。来歴のモジュールが無いカーネルは ProvenanceAbsent
   (警告、fail-closed なら止める)。呼び出し側は SourceVaultIntegrityPublishBlockedQ で止めるかを決める (関所の例外・Failure も含む) *)
$iSVIPublishDenyReasons = {"Quarantined", "UnknownDerived", "NotCommitted", "InstructionWithUncheckedIndex", "FailClosed", "ProvenanceUnavailable"};
Options[SourceVaultIntegrityPublishGate] = {"Channel" -> "Unknown", "Record" -> True};
SourceVaultIntegrityPublishGate[items_List, destination_String, OptionsPattern[]] := Module[
  {xs, avail, x, qE, qL, qB, acc, uL, uB, now = AbsoluteTime[], verdicts = {}, reasons = {}, decision, eids = {}, meta, ingestAge, act = Null, dd, instrItems,
   recordQ = TrueQ[OptionValue["Record"]], usabQ = Length[DownValues[SourceVault`SourceVaultProvUsability]] > 0, outcome = Null},
  xs = iSVIExtrasState[];
  avail = xs["State"] === "OK";
  meta = iSVIProvRows["iProvReadMeta"];
  ingestAge = If[AssociationQ[meta], With[{a = iSVIIsoToAbs[ToString @ Lookup[meta, "LastIngestAtUTC", ""]]}, If[NumberQ[a], now - a, Infinity]], Infinity];
  If[! avail, AppendTo[reasons, "FilterUnavailable"];
    If[MemberQ[{"IndexRebuilding", "LedgerChainDamaged"}, xs["State"]], AppendTo[reasons, xs["State"]]]];
  If[avail && ingestAge > 86400, AppendTo[reasons, "IndexStale"]];
  If[avail,
    x = xs["Extras"]; qE = x["Quarantine"]["ByEntity"]; qL = x["Quarantine"]["ByLogical"]; qB = x["Quarantine"]["ByBlob"];
    acc = Lookup[x, "Accepted", <||>]; uL = x["UnknownDerived"]["ByLogical"]; uB = x["UnknownDerived"]["ByBlob"];
    MapIndexed[Function[{it0, pos}, Module[{it, bids = {}, lrs = {}, ids = {}, fids, active, unk, pend},
        it = Which[AssociationQ[it0], it0, StringQ[it0] && FileExistsQ[it0], <|"Path" -> it0|>, StringQ[it0], <|"Text" -> it0|>, True, <||>];
        If[StringQ[Lookup[it, "Path", None]], With[{b = iSVIFileBlobId[iSVICanonPath[it["Path"]]]}, If[StringQ[b], AppendTo[bids, b]]]];
        If[StringQ[Lookup[it, "Text", None]] && Length[DownValues[SourceVault`SourceVaultProvBlobId]] > 0,
          With[{b = Quiet @ Check[SourceVault`SourceVaultProvBlobId[it["Text"], "Kind" -> "Text"], $Failed]}, If[AssociationQ[b], AppendTo[bids, b["BlobId"]]]]];
        If[StringQ[Lookup[it, "BlobId", None]], AppendTo[bids, it["BlobId"]]];
        If[StringQ[Lookup[it, "LogicalRef", None]], AppendTo[lrs, it["LogicalRef"]]];
        If[StringQ[Lookup[it, "EntityId", None]], AppendTo[ids, it["EntityId"]]; AppendTo[eids, it["EntityId"]]];
        fids = Union[Flatten[Lookup[qE, ids, {}]], Flatten[Lookup[qL, lrs, {}]], Flatten[Lookup[qB, bids, {}]]];
        active = Select[fids, Function[f, With[{a = Lookup[acc, f, None]},
          ! (AssociationQ[a] && MemberQ[Lookup[a, "Purposes", {}], "Publish"] && NumberQ[Lookup[a, "ExpiresAbs", Null]] && a["ExpiresAbs"] > now)]]];
        unk = AnyTrue[lrs, KeyExistsQ[uL, #] &] || AnyTrue[bids, KeyExistsQ[uB, #] &];
        (* 2026-11-11 (F04): 名指しの版は確定して Usable (隔離は上の表で見る) でなければ公開の入力にしない (確定前 Pending・Unknown) *)
        pend = If[usabQ && ids =!= {}, With[{u = Quiet @ SourceVault`SourceVaultProvUsability[ids]},
          Select[ids, ! (AssociationQ[u] && MemberQ[{"Usable", "Quarantined"}, Lookup[Lookup[u, #, <||>], "Usability", "Unknown"]]) &]], {}];
        AppendTo[verdicts, <|"Index" -> pos[[1]], "Verdict" -> Which[active =!= {}, "Quarantined", unk, "UnknownDerived", pend =!= {}, "NotCommitted", True, "OK"],
          "FindingIds" -> active, "BlobIds" -> bids,
          (* V9 (文書 12 の 4.6 節): 外部で未確認の版を公開しようとしている。止めない (警告) *)
          "Grounding" -> With[{gx = Replace[Lookup[x, "Grounding", <||>], Except[_Association] -> <||>]},
            If[AnyTrue[bids, KeyExistsQ[Replace[Lookup[gx, "UngroundedByBlob", <||>], Except[_Association] -> <||>], #] &] ||
                AnyTrue[lrs, KeyExistsQ[Replace[Lookup[gx, "UngroundedByLogical", <||>], Except[_Association] -> <||>], #] &], "Ungrounded", Null]]|>]]], items]];
  (* V9: 文章そのものからも引き当てる (台帳に版の記録が無くても、回答の SHA-256 が裏付けの記録にあるか、先頭に「外部で未確認」の印がある)。
     索引が使えないときも効く *)
  If[Length[DownValues[SourceVault`SourceVaultGroundingOfText]] > 0,
    MapIndexed[Function[{it0, pos}, With[{txt = Which[AssociationQ[it0], Lookup[it0, "Text", None], StringQ[it0] && ! FileExistsQ[it0], it0, True, None]},
        If[StringQ[txt] && Lookup[Quiet @ Check[SourceVault`SourceVaultGroundingOfText[txt], <||>], "Grounding", ""] === "Ungrounded",
          With[{i = FirstPosition[verdicts, v_ /; AssociationQ[v] && Lookup[v, "Index", 0] === pos[[1]], None, {1}]},
            If[ListQ[i], verdicts[[First[i]]] = Append[verdicts[[First[i]]], "Grounding" -> "Ungrounded"],
              AppendTo[verdicts, <|"Index" -> pos[[1]], "Verdict" -> "OK", "FindingIds" -> {}, "BlobIds" -> {}, "Grounding" -> "Ungrounded"|>]]]]]], items]];
  If[AnyTrue[verdicts, Lookup[#, "Grounding", Null] === "Ungrounded" &], AppendTo[reasons, "UngroundedContent"]];
  If[AnyTrue[verdicts, #["Verdict"] === "Quarantined" &], AppendTo[reasons, "Quarantined"]];
  If[AnyTrue[verdicts, #["Verdict"] === "UnknownDerived" &], AppendTo[reasons, "UnknownDerived"]];
  If[AnyTrue[verdicts, #["Verdict"] === "NotCommitted" &], AppendTo[reasons, "NotCommitted"]];
  (* Inc5 (9.2 段階的な規則、Y-07): 索引が使えない・古いとき、Instruction 系 (ワークフロー・TurnWiki・Directives 等) を含む公開は止める。
     含まない公開は Inc1〜Inc4 の規則で警告して通す。$SourceVaultIntegrityPublishFailClosed (Inc5 の完全な fail-closed) なら全部止める *)
  instrItems = Select[items, Function[it, With[{p = Which[AssociationQ[it], Lookup[it, "Path", None], StringQ[it] && FileExistsQ[it], it, True, None]},
    StringQ[p] && iSVIClassifyPath[iSVICanonPath[p]] =!= None]]];
  (* 台帳がまだ一度も取り込んでいない (来歴の運用が始まっていない) 間は、Instruction 系を含んでも警告して通す (fail-closed を除く) *)
  If[! (AssociationQ[meta] && Lookup[meta, "DurableSeq", 0] > 0), AppendTo[reasons, "ProvenanceNotDeployed"]];
  If[(MemberQ[reasons, "FilterUnavailable"] || MemberQ[reasons, "IndexStale"]) && instrItems =!= {} && ! MemberQ[reasons, "ProvenanceNotDeployed"],
    AppendTo[reasons, "InstructionWithUncheckedIndex"]];
  If[recordQ && ! iSVIProvQ[], AppendTo[reasons, "ProvenanceAbsent"]];
  If[(MemberQ[reasons, "FilterUnavailable"] || MemberQ[reasons, "IndexStale"] || MemberQ[reasons, "ProvenanceAbsent"]) && TrueQ[$SourceVaultIntegrityPublishFailClosed],
    AppendTo[reasons, "FailClosed"]];
  decision = Which[IntersectingQ[reasons, $iSVIPublishDenyReasons], "Deny", reasons =!= {}, "Warn", True, "Allow"];
  (* 公開の意図の記録 (Publish Activity): 入力は記録のある版、宛先は鍵付き digest。止めたものは Blocked、通すものは Approved
     (実際の成否は SourceVaultIntegrityPublishOutcome)。通すはずの公開の記録が書けなければ止める (6.2 節、ProvenanceUnavailable) *)
  If[recordQ && iSVIProvQ[],
    eids = DeleteDuplicates @ Join[eids, Flatten[Function[b, With[{r = Quiet @ Check[SourceVault`SourceVaultProvResolve[b], <||>]},
      If[AssociationQ[r] && Lookup[r, "Status", ""] === "Found", {r["Latest"]}, {}]]] /@ DeleteDuplicates[Flatten[Lookup[verdicts, "BlobIds", {}]]]]];
    dd = iSVIDigestOrNull["ExternalRef", destination];
    outcome = If[decision === "Deny", "Blocked", "Approved"];
    act = Quiet @ Catch[SourceVault`SourceVaultProvActivity[<|"Kind" -> "Publish", "Inputs" -> (<|"EntityId" -> #, "Role" -> "Context"|> & /@ eids), "Outputs" -> {},
      "Outcome" -> outcome, "InputsCompleteness" -> If[Length[eids] >= Length[items], "Complete", "Partial"],
      "ExternalRefs" -> <|"Channel" -> ToString @ OptionValue["Channel"], "DestinationDigest" -> If[StringQ[dd], dd, ""]|>,
      "Detail" -> <|"Decision" -> decision, "Reasons" -> reasons, "Items" -> Length[items], "Recorded" -> Length[eids], "Stage" -> "Intent"|>|>]];
    If[! (AssociationQ[act] && StringQ[Lookup[act, "ActivityId", None]] && Lookup[act, "Status", ""] === "Spooled"),
      act = Null;
      If[decision =!= "Deny", AppendTo[reasons, "ProvenanceUnavailable"]; decision = "Deny"; outcome = Null]]];
  If[decision =!= "Allow", iSVIFinding["Egress", "PublishGate:" <> decision, If[decision === "Deny", "High", "Medium"], If[decision === "Deny", "Degraded", "OK"],
    "Targets" -> reasons, "Detail" -> <|"Channel" -> ToString @ OptionValue["Channel"], "Items" -> Length[items]|>, "Publish" -> False]];
  <|"Decision" -> decision, "Reasons" -> reasons, "Items" -> (KeyDrop[#, "BlobIds"] & /@ verdicts), "Recorded" -> Length[eids],
    "ActivityId" -> If[AssociationQ[act], act["ActivityId"], Null], "Outcome" -> outcome, "IndexState" -> xs["State"]|>];
SourceVaultIntegrityPublishGate[___] := Failure["BadArguments", <|"MessageTemplate" -> "SourceVaultIntegrityPublishGate[items_List, destination_String, opts]"|>];

(* 呼び出し側の判定 (2026-11-11、F03): Deny は止める、Allow / Warn は通す、それ以外 (関所が無い・例外・Failure・None) は fail-closed の設定に従う *)
SourceVaultIntegrityPublishBlockedQ[g_] := Which[
  AssociationQ[g] && Lookup[g, "Decision", None] === "Deny", True,
  AssociationQ[g] && MemberQ[{"Allow", "Warn"}, Lookup[g, "Decision", None]], False,
  True, TrueQ[$SourceVaultIntegrityPublishFailClosed]];

(* 実際の公開の結果 (2026-11-11、F04)。意図の ActivityId に結び付けた Publish Activity (入力なし、ExternalRefs IntentActivity) *)
If[! AssociationQ[$iSVIPublishOutcomeStats], $iSVIPublishOutcomeStats = <|"Recorded" -> 0, "Failed" -> 0|>];
Options[SourceVaultIntegrityPublishOutcome] = {"Channel" -> "Unknown"};
SourceVaultIntegrityPublishOutcome[aid_String, outcome_String, OptionsPattern[]] := Module[{r},
  If[! MemberQ[{"Succeeded", "Failed"}, outcome],
    Return[Failure["BadOutcome", <|"Outcome" -> outcome, "Allowed" -> {"Succeeded", "Failed"}|>]]];
  If[! iSVIProvQ[], Return[<|"Status" -> "Skipped", "Reason" -> "ProvenanceAbsent", "IntentActivity" -> aid|>]];
  r = Quiet @ Catch[SourceVault`SourceVaultProvActivity[<|"Kind" -> "Publish", "Inputs" -> {}, "Outputs" -> {}, "Outcome" -> outcome,
    "ExternalRefs" -> <|"Channel" -> ToString @ OptionValue["Channel"], "IntentActivity" -> aid|>,
    "Detail" -> <|"Stage" -> "Outcome", "IntentActivity" -> aid|>|>]];
  If[AssociationQ[r] && Lookup[r, "Status", ""] === "Spooled",
    $iSVIPublishOutcomeStats["Recorded"]++;
    <|"Status" -> "Recorded", "ActivityId" -> r["ActivityId"], "IntentActivity" -> aid, "Outcome" -> outcome|>,
    $iSVIPublishOutcomeStats["Failed"]++;
    iSVIFinding["Egress", "PublishOutcomeUnrecorded", "Medium", "Degraded", "Targets" -> {aid},
      "Detail" -> <|"Outcome" -> outcome, "Channel" -> ToString @ OptionValue["Channel"]|>, "Publish" -> False];
    Failure["ProvenanceUnavailable", <|"IntentActivity" -> aid, "Outcome" -> outcome,
      "MessageTemplate" -> "The publication outcome could not be recorded."|>]]];
SourceVaultIntegrityPublishOutcome[Null | None, ___] := <|"Status" -> "Skipped", "Reason" -> "NoIntent"|>;
SourceVaultIntegrityPublishOutcome[___] := Failure["BadArguments", <|"MessageTemplate" -> "SourceVaultIntegrityPublishOutcome[activityId_String, \"Succeeded\" | \"Failed\", opts]"|>];

(* ---- Inc4 の検証器をまとめて回す (Verifiers から)。周期: Injection / Code / Publish は毎回 (増分)、Models 10 分 (Manifest 1 時間)、
   Citation / Drift / Egress は日次。予算は残りの時間 ---- *)
iSVIRunInc4Checks[force_, budget_] := Module[{s = iSVIProbeStateLoad[], t0 = AbsoluteTime[], res = <||>, rem, run},
  rem[] := Max[0.5, budget - (AbsoluteTime[] - t0)];
  run = Function[{name, interval, f}, If[iSVIDue[s, name, interval, force],
    With[{o = Quiet @ Check[f[], $Failed]},
      If[ListQ[o] && Length[o] === 2 && AssociationQ[o[[1]]], s = o[[1]]; res[name] = o[[2]],
        res[name] = If[AssociationQ[o], o, <|"Health" -> "Degraded", "ReasonCode" -> name <> "CheckFailed"|>]];
      s["LastRun", name] = AbsoluteTime[]; s["Last", name] = res[name]],
    res[name] = Lookup[Lookup[s, "Last", <||>], name, <|"Health" -> "OK", "ReasonCode" -> "NotYetRun"|>]]];
  run["InjectionResidue", 0, Function[iSVICheckInjectionResidue[s, rem[]/3]]];
  run["GeneratedCodeHealth", 0, Function[iSVICheckGeneratedCode[s, rem[]/3]]];
  run["PublishUnusable", 0, Function[iSVICheckPublishUnusable[s]]];
  run["LMStudioMCPScope", 600, Function[iSVICheckLMStudioScope[]]];
  run["ModelManifest", 3600, Function[iSVICheckModelManifest[]]];
  run["CitationIntegrity", 86400, Function[iSVICheckCitationIntegrity[s, rem[]/2]]];
  run["EntityDrift", 86400, Function[iSVICheckEntityDrift[s, rem[]/2]]];
  run["EgressPattern", 86400, Function[iSVICheckEgressPattern[]]];
  (* Inc5: KnowledgeHealth (Ingest ごと) と Finding → Issue *)
  run["KnowledgeHealth", 0, Function[iSVICheckKnowledgeHealth[s]]];
  run["FindingIssues", 0, Function[iSVIFindingIssues[s]]];
  iSVIProbeStateSave[s];
  res];
iSVIComponentOf[name_String, checks_Association] := With[{h = iSVIWorst[Lookup[Values[checks], "Health", "OK"]]},
  <|"Health" -> h, "ReasonCode" -> If[h === "OK", name <> "OK", Lookup[SelectFirst[Values[checks], Lookup[#, "Health", "OK"] === h &, <||>], "ReasonCode", "?"]],
    "Message" -> name <> ": " <> StringRiffle[KeyValueMap[#1 <> " " <> ToString @ Lookup[#2, "Health", "?"] &, checks], ", "],
    "Counts" -> Map[Lookup[#, "Counts", <||>] &, checks], "Checks" -> checks|>];

(* ============================================================
   Inc5 (03 v0.4 §7.1 KnowledgeHealth / §8.3〜8.5 / §9.1〜9.3 / §11.2、2026-11-10):
   健全性の指標と KnowledgeHealth 部品、Finding → Issue、Issue を閉じるときの検査、公開の関所の fail-closed
   ============================================================ *)
If[! BooleanQ[$SourceVaultIntegrityPublishFailClosed], $SourceVaultIntegrityPublishFailClosed = False];
If[! IntegerQ[$SourceVaultIntegrityReviewDebtLimit], $SourceVaultIntegrityReviewDebtLimit = 10];
$iSVIFindingComponent = <|"InjectionResidue" -> "Integrity", "CitationIntegrity" -> "Integrity", "GeneratedCodeHealth" -> "Integrity", "EntityDrift" -> "Integrity"|>;

(* ---- KnowledgeHealth (Ingest ごと): Contamination・FeedbackLoop・ReviewDebt・Indicators (表 8.1 の規則。KHI は参考値で判定に使わない) ---- *)
iSVICheckKnowledgeHealth[s0_Association] := Module[{s = s0, ind, cu, autoQ, nonAutoQ, unk, now = AbsoluteTime[], hits, checks = <||>, cyc},
  ind = iSVIProvRows["iProvIndicators"];
  If[! AssociationQ[ind], Return[{s, <|"Health" -> "OK", "ReasonCode" -> "IndexUnavailable", "Checks" -> <||>|>}]];
  cu = iSVIProvRows["iProvContaminatedUses", Lookup[s["Seqs"], "Contamination", 0]];
  If[AssociationQ[cu],
    autoQ = Select[cu["Quarantined"], TrueQ[#["Automatic"]] &]; nonAutoQ = Select[cu["Quarantined"], ! TrueQ[#["Automatic"]] &]; unk = cu["Unknown"];
    s["Seqs", "Contamination"] = cu["IndexSeq"];
    If[autoQ =!= {}, s["Hits", "AutoQuarantined"] = now; iSVIFinding["KnowledgeHealth", "QuarantinedAutoUse", "Critical", "Failing",
      "Targets" -> DeleteDuplicates[#["ActivityId"] & /@ autoQ], "Detail" -> <|"Kinds" -> Tally[#["Kind"] & /@ autoQ]|>]];
    If[unk =!= {}, s["Hits", "UnknownUse"] = now],
    autoQ = {}; nonAutoQ = {}; unk = {}];
  hits = Lookup[s, "Hits", <||>];
  (* 24 時間以内に自動の利用があれば Failing のまま (1 回で戻らない) *)
  checks["Contamination"] = With[{recent = NumberQ[Lookup[hits, "AutoQuarantined", Null]] && now - hits["AutoQuarantined"] < 86400},
    <|"Health" -> If[recent, "Failing", If[NumberQ[Lookup[hits, "UnknownUse", Null]] && now - hits["UnknownUse"] < 86400, "Degraded", "OK"]],
      "ReasonCode" -> Which[recent, "QuarantinedAutoUse", NumberQ[Lookup[hits, "UnknownUse", Null]] && now - hits["UnknownUse"] < 86400, "UnknownUsedAutomatically", True, "ContaminationOK"],
      "Counts" -> <|"AutoQuarantinedNow" -> Length[autoQ], "OtherQuarantinedNow" -> Length[nonAutoQ], "UnknownNow" -> Length[unk]|>|>];
  cyc = ind["Cycles"];
  checks["FeedbackLoop"] = <|"Health" -> If[cyc > Lookup[s, "KnownCycles", 0], "Degraded", "OK"],
    "ReasonCode" -> If[cyc > Lookup[s, "KnownCycles", 0], "FeedbackLoop", "FeedbackLoopOK"], "Counts" -> <|"Cycles" -> cyc|>|>;
  If[cyc > Lookup[s, "KnownCycles", 0], iSVIFinding["KnowledgeHealth", "FeedbackLoop", "Medium", "Degraded", "Targets" -> {ToString[cyc]}, "Publish" -> False]];
  s["KnownCycles"] = cyc;
  checks["ReviewDebt"] = With[{d = ind["ReviewDebt"]}, <|"Health" -> If[d["Top"] >= $SourceVaultIntegrityReviewDebtLimit && d["OldestDays"] >= 7, "Degraded", "OK"],
    "ReasonCode" -> If[d["Top"] >= $SourceVaultIntegrityReviewDebtLimit && d["OldestDays"] >= 7, "ReviewDebt", "ReviewDebtOK"], "Counts" -> d|>];
  checks["Indicators"] = Module[{u = ind["UnresolvedSevere"], fr = ind["Freshness"], low},
    low = Keys[Select[ind["CompletenessByKind"], #["Total"] >= 10 && #["Ratio"] < 0.9 &]];
    <|"Health" -> Which[u["Instruction"] > 0, "Failing", u["Count"] > 0 || low =!= {} || Lookup[fr, "Lag", 0] > 5000 || TrueQ[Lookup[fr, "CarryOver", False]], "Degraded", True, "OK"],
      "ReasonCode" -> Which[u["Instruction"] > 0, "UnresolvedSevereInstruction", u["Count"] > 0, "UnresolvedSevereFinding", low =!= {}, "CompletenessLow",
        Lookup[fr, "Lag", 0] > 5000 || TrueQ[Lookup[fr, "CarryOver", False]], "IndexLagging", True, "IndicatorsOK"],
      "Counts" -> <|"UnresolvedSevere" -> u["Count"], "UnresolvedInstruction" -> u["Instruction"], "OldestDays" -> u["OldestDays"], "CompletenessLow" -> low,
        "Freshness" -> fr, "RecoveryHoursMedian" -> ind["RecoveryHoursMedian"], "KHIReference" -> ind["KHI"], "ActiveVersions" -> ind["ActiveVersions"]|>|>];
  {s, Join[iSVIComponentOf["KnowledgeHealth", checks], <|"Indicators" -> KeyTake[ind, {"ActiveVersions", "CompletenessByKind", "UnresolvedSevere",
    "RecoveryHoursMedian", "KHI", "Distribution", "QuarantinedByKind", "ReviewDebt", "Freshness", "Cycles"}]|>]}];

(* ---- Finding → Issue (9.3): High 以上は 1 件ずつ、Medium は部品・種類ごとに集約、Low / Info は View だけ。AcceptedRisk の期限切れで再び ---- *)
iSVIFindingEvent[f_Association, extra_Association] := Module[{fid = f["FindingId"], br = iSVIProvRows["iProvBlastRadius", f["FindingId"]], comp},
  comp = Lookup[$iSVIFindingComponent, f["Kind"], "KnowledgeHealth"];
  iSVIDiagPublish[Join[<|"Type" -> "DiagnosticsEvent", "EventId" -> CreateUUID[], "EventClass" -> "IntegrityFinding", "Producer" -> "integrity",
    "Component" -> comp, "ReasonCode" -> f["Kind"], "Severity" -> f["Severity"], "Health" -> If[f["Severity"] === "Critical" || f["Severity"] === "High", "Failing", "Degraded"],
    "IssueRequested" -> True, "IssueClass" -> "security", "PrivacyLevel" -> Max[$iSVIFindingPLFloor, Lookup[f, "MaxPL", $iSVIFindingPLFloor]],
    "SubjectRef" -> <|"Kind" -> "Finding", "Key" -> fid|>,
    "EvidenceRefs" -> {<|"FindingId" -> fid, "BlastRadius" -> If[AssociationQ[br], KeyTake[br, {"Targets", "Descendants", "ByKind", "IncludesInstruction", "Published"}], <||>]|>},
    (* 本文はメタデータだけ (ID・件数・部品名・種類) *)
    "Summary" -> comp <> ": " <> f["Kind"] <> " (" <> f["Severity"] <> ", finding " <> fid <> ", " <>
      ToString[If[AssociationQ[br], br["Descendants"], 0]] <> " descendant(s))" <> ToString[Lookup[extra, "SummaryNote", ""]]|>, KeyDrop[extra, "SummaryNote"]]]];
iSVIFindingIssues[s0_Association] := Module[{s = s0, rows, med = <||>, n = 0, exp = 0, now = AbsoluteTime[]},
  rows = iSVIProvRows["iProvFindingsSince", Lookup[s["Seqs"], "FindingIssue", 0]];
  If[! AssociationQ[rows], Return[{s, <|"Published" -> 0|>}]];
  Scan[Function[f, Switch[f["Severity"],
      "High" | "Critical", If[f["Resolution"] === "Open" || f["Resolution"] === "Acknowledged", iSVIFindingEvent[f, <||>]; n++],
      "Medium", If[f["Resolution"] === "Open", med[f["Kind"]] = Lookup[med, f["Kind"], 0] + 1],
      _, Null]], rows["Rows"]];
  KeyValueMap[Function[{k, c}, n++; iSVIDiagPublish[<|"Type" -> "DiagnosticsEvent", "EventId" -> CreateUUID[], "EventClass" -> "IntegrityFinding", "Producer" -> "integrity",
      "Component" -> Lookup[$iSVIFindingComponent, k, "KnowledgeHealth"], "ReasonCode" -> k, "Severity" -> "Medium", "Health" -> "Degraded",
      "IssueRequested" -> True, "IssueClass" -> "security", "PrivacyLevel" -> $iSVIFindingPLFloor,
      "SubjectRef" -> <|"Kind" -> "Component", "Key" -> "IntegrityFindings:" <> k|>,
      "Summary" -> "Integrity: " <> ToString[c] <> " new Medium finding(s) of kind " <> k|>]], med];
  s["Seqs", "FindingIssue"] = rows["IndexSeq"];
  (* AcceptedRisk の期限切れ: Finding は Open に戻ったとみなし、同じ SubjectRef で再び signal (Resolved の Issue は再び開く) *)
  KeyValueMap[Function[{fid, r}, If[r["Kind"] === "AcceptedRisk" && NumberQ[Lookup[r, "ExpiresAbs", Null]] && r["ExpiresAbs"] < now &&
        ! KeyExistsQ[Lookup[s, "Expired", <||>], fid],
      With[{br = iSVIProvRows["iProvBlastRadius", fid]},
        If[AssociationQ[br], exp++;
          (* ReasonCode は Finding の種類のまま (Issue の IncidentKey が同じ = 同じ事案として Resolved の Issue が開き直る)。期限切れは要約の注記で *)
          iSVIFindingEvent[<|"FindingId" -> fid, "Kind" -> br["Kind"], "Severity" -> br["Severity"], "MaxPL" -> $iSVIFindingPLFloor|>, <|"SummaryNote" -> " -- AcceptedRisk expired"|>];
          s["Expired", fid] = iSVINowIso[]]]]], rows["AllResolutions"]];
  {s, <|"Published" -> n, "Expired" -> exp|>}];

(* ---- Issue を閉じるときの検査 (9.3): Finding がすべて解決 (誤検知・訂正・受容、Acknowledged は除く) してから。訂正は OpenPublications = 0 が前提 (ResolveFinding が強制) ---- *)
iSVIIssueResolveGuard[rec_Association, meta_] := Module[{ds = Lookup[rec, "DoctorState", <||>], sub, ex, st, open},
  sub = If[AssociationQ[ds], Lookup[ds, "SubjectRef", <||>], <||>];
  If[! AssociationQ[sub] || ! MemberQ[{"Finding", "Component"}, Lookup[sub, "Kind", ""]], Return[True]];
  If[Lookup[sub, "Kind", ""] === "Component" && ! StringStartsQ[ToString @ Lookup[sub, "Key", ""], "IntegrityFindings:"], Return[True]];
  ex = If[Length[DownValues[SourceVault`ProvenancePrivate`iProvUsabilityExtrasCached]] > 0, Quiet @ Check[SourceVault`ProvenancePrivate`iProvUsabilityExtrasCached[], $Failed], $Failed];
  If[! AssociationQ[ex] || ! AssociationQ[ex["Extras"]],
    Return[Failure["FindingStatusUnavailable", <|"MessageTemplate" -> "The finding status cannot be read (provenance index unavailable); the issue stays open (03 v0.4 9.3)."|>]]];
  st = Lookup[ex["Extras"], "FindingStatus", <||>];
  open = If[sub["Kind"] === "Finding",
    Select[{sub["Key"]}, MemberQ[{"Open", "Acknowledged"}, Lookup[Lookup[st, #, <||>], "Status", "Open"]] &],
    Keys[Select[st, #["Kind"] === StringDrop[sub["Key"], StringLength["IntegrityFindings:"]] && MemberQ[{"Open", "Acknowledged"}, #["Status"]] &]]];
  If[open === {}, True,
    Failure["FindingUnresolved", <|"FindingIds" -> Take[open, UpTo[20]],
      "MessageTemplate" -> "The integrity finding(s) are not resolved yet; resolve them (FalsePositive / Remediated / AcceptedRisk) before closing the issue (03 v0.4 9.3)."|>]]];
iSVIRegisterIssueGuard[] := If[ListQ[SourceVault`$SourceVaultIssueResolveGuards] && ! MemberQ[SourceVault`$SourceVaultIssueResolveGuards, iSVIIssueResolveGuard],
  AppendTo[SourceVault`$SourceVaultIssueResolveGuards, iSVIIssueResolveGuard]; True, False];
Quiet @ iSVIRegisterIssueGuard[];

(* ---- 公開の関所の fail-closed に切り替えてよいか (D-27: 索引の鮮度が運用で確かめられてから) ---- *)
SourceVaultIntegrityFailClosedReadiness[] := Module[{st = iSVIProvStatus[], meta, age, key, tick, s = SourceVaultIntegrityState[], reasons = {}},
  meta = Lookup[st, "Meta", <||>]; If[! AssociationQ[meta], meta = <||>];
  age = With[{a = iSVIIsoToAbs[ToString @ Lookup[meta, "LastIngestAtUTC", ""]]}, If[NumberQ[a], AbsoluteTime[] - a, Infinity]];
  key = Lookup[st, "LedgerMacKeyAvailable", False];
  tick = If[AssociationQ[s], With[{a = iSVIIsoToAbs[ToString @ Lookup[s, "ComputedAtUTC", ""]]}, If[NumberQ[a], AbsoluteTime[] - a, Infinity]], Infinity];
  If[! TrueQ[key], AppendTo[reasons, "LedgerMacKeyUnavailable"]];
  If[age > 3600, AppendTo[reasons, "IngestStale"]];
  If[tick > 900, AppendTo[reasons, "ServiceTickStale"]];
  If[Lookup[meta, "ChainState", "OK"] =!= "OK", AppendTo[reasons, "ChainDamaged"]];
  <|"Ready" -> reasons === {}, "Reasons" -> reasons, "IngestAgeSeconds" -> If[age === Infinity, Null, Round[age]],
    "StateAgeSeconds" -> If[tick === Infinity, Null, Round[tick]],
    "PublishFailClosed" -> $SourceVaultIntegrityPublishFailClosed, "FilterFailClosed" -> $SourceVaultIntegrityFilterFailClosed,
    "Advice" -> If[reasons === {}, "The index is fresh; the owner may set $SourceVaultIntegrityPublishFailClosed = True (and $SourceVaultIntegrityFilterFailClosed = True) after a few days of this state.",
      "Keep the fail-closed switches False until these are resolved: " <> StringRiffle[reasons, ", "]]|>];

(* ---- 所有者操作を FE から 1 回で (確認 → ticket のダイアログ → ticket つきで実行)。View のボタンが置く式テンプレートが使う ---- *)
SetAttributes[SourceVaultIntegrityOwnerAction, HoldFirst];
SourceVaultIntegrityOwnerAction[call_] := Module[{own = <|"Kind" -> "OwnerCode", "Channel" -> "SourceVaultIntegrityOwnerAction"|>, r, t},
  r = Block[{SourceVault`$SourceVaultPrincipal = own}, call];
  If[! (AssociationQ[r] && Lookup[r, "Status", ""] === "ReviewRequired"), Return[r]];
  If[Length[DownValues[SourceVault`SourceVaultOwnerTicketDialog]] === 0, Return[Failure["ProvTicketUnavailable", <||>]]];
  t = SourceVault`SourceVaultOwnerTicketDialog[<|"Action" -> r["TicketAction"], "Subject" -> <||>, "Display" -> r["BindDisplay"],
    "Bind" -> KeyDrop[r["Bind"], "Display"]|>];
  If[! AssociationQ[t], Return[t]];
  Block[{SourceVault`$SourceVaultPrincipal = own},
    ReleaseHold[Hold[call] /. HoldPattern[Hold[h_[a___]]] :> Hold[h[a, "Ticket" -> t]]]]];

(* ---- 公開 API (11.2 節) ---- *)
SourceVaultKnowledgeHealth[] := Module[{s = SourceVaultIntegrityState[]},
  If[! AssociationQ[s], Return[Missing["NotFound"]]];
  <|"ComputedAtUTC" -> Lookup[s, "ComputedAtUTC", Null],
    "Components" -> Map[KeyTake[#, {"Health", "ReasonCode", "Message", "Counts"}] &, Lookup[s, "Components", <||>]],
    "Indicators" -> Lookup[Lookup[Lookup[s, "Components", <||>], "KnowledgeHealth", <||>], "Indicators", <||>],
    "KHINote" -> "KHI is an empirical reference value that moves with the mix of origins; health is judged by table 8.1 only (03 v0.4 8.5)."|>];
SourceVaultIntegrityBlastRadius[fid_String] := Module[{r},
  If[! iSVIProvQ[], Return[Missing["ProvenanceUnavailable"]]];
  r = iSVIProvRows["iProvBlastRadius", fid];
  If[AssociationQ[r] && MemberQ[{"Model", "MCP"}, iSVIPrincipalKind[]], KeyTake[r, {"FindingId", "Severity", "Descendants", "Published"}], r]];
SourceVaultIntegrityBlastRadius[___] := Missing["BadArguments"];

(* ============================================================
   approval heads / policy variables (02 v1.2 A-4 + 03 v0.4 §11.5 + I-02 / I-08 + Inc1a + Inc2)
   ============================================================ *)
If[! ListQ[$SourceVaultApprovalHeads],
  $SourceVaultApprovalHeads = {
    (* 02 v1.2 §7.1 A-4: 方針と出口の API *)
    "SourceVaultMailSend", "SourceVaultWebGuardResolveRequest",
    "SourceVaultSetImmutableSnapshotPrivacyLevel", "SourceVaultSetSnapshotPrivacyLevel",
    "SourceVaultTodoSetPrivacyLevel", "SourceVaultResetEvaluationPrivacy",
    "SourceVaultExportKeyBundle", "SourceVaultDecryptRecord", "SourceVaultMCPRegisterTools",
    (* 03 v0.4 §11.5 所有者専用 *)
    "SourceVaultIntegrityRecordOwnerReview", "SourceVaultIntegrityAuthorizeInstruction",
    "SourceVaultIntegrityRevokeAuthorization", "SourceVaultIntegrityQuarantine", "SourceVaultIntegrityRelease",
    "SourceVaultIntegrityResolveFinding", "SourceVaultIntegrityAcceptBaseline",
    "SourceVaultIntegrityRegisterVerifier", "SourceVaultRederiveApprove",
    (* 所有者 ticket の発行 (I-02) と SecurityProfile 検査の登録 (I-08) *)
    "SourceVaultOwnerTicketDialog", "SourceVaultOwnerTicketMint", "SourceVaultRegisterSecurityProfileCheck",
    (* 03 v0.4 Inc1a (2026-11-09 第 3 週): 来歴台帳の状態を変える公開関数 (表 11.1 で Owner / Service のみ。service の単一書き手と
       所有者の ticket 操作以外、提案コードからは承認制) *)
    "SourceVaultProvIngestSpool", "SourceVaultProvIngestAdapters", "SourceVaultProvRebuildIndex", "SourceVaultProvCheckpoint",
    "SourceVaultProvChainRestart", "SourceVaultProvRotateKey", "SourceVaultProvRegisterAdapter", "SourceVaultIntegrityServiceTick",
    (* 03 v0.4 Inc2 (2026-11-10 第 4 週): 基準の初期化・backfill・結合・drift・検証器 (所有者 / service のみ) *)
    "SourceVaultIntegrityInitializeInstructions", "SourceVaultIntegrityBackfill", "SourceVaultProvJoinLLMCalls",
    "SourceVaultIntegrityInstructionDrift", "SourceVaultIntegrityVerifiers",
    (* 03 v0.4 Inc1b (2026-11-10): feeds の書き出しと他機の照合 (Owner / Service) *)
    "SourceVaultProvSyncFeeds",
    (* 03 v0.4 Inc5 (2026-11-10): 所有者操作を 1 回で (主体の束縛と ticket のダイアログ) *)
    "SourceVaultIntegrityOwnerAction",
    (* 文書 12 の V7 (2026-11-13): 方針の提案への回答と、ホストの許可・遮断 (関所の方針を変える。提案コードからは承認制) *)
    "SourceVaultPolicyProposalResolve", "SourceVaultWebHostSetAccess", "SourceVaultWebHostBlock",
    (* 文書 12 の V8 (2026-11-13): 緩めた設定の再確認の記録 (所有者だけ。提案コードが「見直した」と記録できないようにする) *)
    "SourceVaultOwnerDecisionReconfirm",
    (* 文書 12 の V9 (2026-11-13): 裏付けの記録を書く口 (提案コードが「Grounded」の記録を作れないようにする) *)
    "SourceVaultGroundingNote"}];

If[! ListQ[$SourceVaultApprovalSetSymbols],
  $SourceVaultApprovalSetSymbols = {
    "$SourceVaultPrincipal", "$SourceVaultSecurityProfile",
    "$SourceVaultOwnerTicketKeyRef", "$SourceVaultOwnerTicketDevelopmentKeyRef", "$SourceVaultOwnerTicketStore",
    "$SourceVaultAutoTriggerPermitKeyRef", "$SourceVaultAutoTriggerEnforcePermit",
    "$SourceVaultSummaryEndpoint", "$SourceVaultSummaryAllowedEndpoints",
    "$SourceVaultWebGuardPrompter", "$SourceVaultWebGuardEnabled",
    "$SourceVaultWebGuardRequired", "$SourceVaultWebGuardPolicy",
    (* Inc1a (2026-11-09): 来歴の鍵と spool の置き場 *)
    "$SourceVaultProvKeyRefs", "$SourceVaultProvRetiredKeyRefs", "$SourceVaultProvSpoolRoot",
    (* Inc2 (2026-11-10): Instruction 群の root と LoadVerify の強制 *)
    "$SourceVaultInstructionRoots", "$SourceVaultIntegrityLoadVerifyEnforce",
    (* Inc1b (2026-11-10): checkpoint の頻度・feeds の保持・SyncDigest を許す種類 (緩めると検知と保護が弱まる) *)
    "$SourceVaultProvCheckpointLines", "$SourceVaultProvCheckpointIntervalSeconds", "$SourceVaultProvFeedRetentionDays", "$SourceVaultProvSyncDigestKinds",
    (* Inc3 (2026-11-10): 検索フィルタが使えないときの扱い・基準ハッシュを認可の代わりに認める移行期間 (緩めると隔離と認可が弱まる) *)
    "$SourceVaultIntegrityFilterFailClosed", "$SourceVaultIntegrityBaselineAsAuthorization",
    (* Inc4 (2026-11-10): 既知の脆弱性表と LM Studio の設定の置き場 (書き換えると検査を外せる) *)
    "$SourceVaultModelRuntimeAdvisories", "$SourceVaultLMStudioRoot", "$SourceVaultLMStudioInstallDir",
    (* Inc5 (2026-11-10): 公開の関所の fail-closed (緩める向きの代入も締める向きの代入も所有者の判断) *)
    "$SourceVaultIntegrityPublishFailClosed", "$SourceVaultIssueResolveGuards"}];

SourceVaultRegisterApprovalHeadsWithNBAccess[] :=
  If[Length[DownValues[NBAccess`NBRegisterApprovalHeads]] > 0 &&
     Length[DownValues[NBAccess`NBRegisterApprovalSetSymbols]] > 0,
    <|"Status" -> "Registered",
      "ApprovalHeads" -> Quiet @ NBAccess`NBRegisterApprovalHeads[$SourceVaultApprovalHeads],
      "ApprovalSetSymbols" -> Quiet @ NBAccess`NBRegisterApprovalSetSymbols[$SourceVaultApprovalSetSymbols]|>,
    <|"Status" -> "NBAccessAbsent"|>];

$iSVIRegisterResult = Quiet @ Check[SourceVaultRegisterApprovalHeadsWithNBAccess[],
  <|"Status" -> "Failed"|>];
$iSVIProbeRegisterResult = Quiet @ Check[SourceVaultIntegrityRegisterProbes[], <|"Status" -> "Failed"|>];
(* NBAccess の読取フック (NBAccess は SourceVault に依存しないので、登録はこちらから NBRegisterFileReadHook で行う。NBAccess が後から
   ロードされた場合は FE の probe (SourceVaultIntegrityProbe、60 秒ごと) が登録し直す) *)
If[! BooleanQ[$iSVINBHookRegistered], $iSVINBHookRegistered = False];
iSVIRegisterNBAccessHook[] := If[TrueQ[$iSVINBHookRegistered], True,
  $iSVINBHookRegistered = Length[DownValues[NBAccess`NBRegisterFileReadHook]] > 0 &&
    IntegerQ[Quiet @ Check[NBAccess`NBRegisterFileReadHook[SourceVault`SourceVaultProvRecordNBRead], $Failed]]];
iSVIRegisterNBAccessHook[];

iSVIRegisterPrivacyContracts[] := Quiet @ Check[
  If[Length[DownValues[SourceVault`SourceVaultRegisterPrivacyContract]] > 0,
    Scan[SourceVault`SourceVaultRegisterPrivacyContract[First[#],
        <|"Class" -> "Internal", "Module" -> "SourceVault_integrity.wl", "NoDataFlow" -> Last[#]|>] &,
      {{"SourceVaultInstructionFiles", "Lists instruction file paths and classes on this machine; no content."},
       {"SourceVaultIntegrityAcceptBaseline", "Owner + ticket: hashes instruction files into Instruction entities and writes the baseline (ids and digests only)."},
       {"SourceVaultIntegrityInitializeInstructions", "Same as AcceptBaseline, first run only."},
       {"SourceVaultIntegrityInstructionDrift", "Rehashes instruction files and compares with the baseline; returns counts and relative paths."},
       {"SourceVaultIntegrityLoadVerify", "Compares one file's digest with the baseline; returns a decision and digests."},
       {"SourceVaultIntegrityVerifiers", "Writes health/state.json (health, reason codes, counts); no record content."},
       {"SourceVaultIntegrityState", "Reads health/state.json."},
       {"SourceVaultIntegrityProbe", "SystemDoctor probe over state.json; health and counts only."},
       {"SourceVaultIntegrityFindings", "Returns finding metadata (ids, components, reason codes, counts)."},
       {"SourceVaultIntegrityBackfill", "Owner only: records existing snapshots / runs / graphs as Backfilled provenance records (ids and digests)."},
       {"SourceVaultProvRecordToolCall", "Spools an Execute activity with keyed argument digest and result digest (withheld for PL >= 0.5)."},
       {"SourceVaultProvRecordWebIngest", "Spools an Ingest activity and a PrimarySource entity (content hash, keyed URL digest, pre-scan verdict)."},
       {"SourceVaultProvRecordNBRead", "Spools a ServedToContext record for a file read (digest, path reference, PL)."},
       {"SourceVaultProvRecordTurnWikiMaintain", "Spools trace and pattern entities (digests) and an LLMGenerate activity; returns ids."},
       (* Inc3 (2026-11-10) *)
       {"SourceVaultIntegrityAuthorizeInstruction", "Owner + ticket: spools an authorization record (entity id, blob id, purpose)."},
       {"SourceVaultIntegrityRevokeAuthorization", "Owner + ticket: spools a revocation record."},
       {"SourceVaultIntegrityQuarantine", "Owner + ticket: spools a High finding on entity / blob ids."},
       {"SourceVaultIntegrityRelease", "Owner + ticket: spools a release record (finding id, entity id, ground)."},
       {"SourceVaultIntegrityResolveFinding", "Owner + ticket: spools a finding resolution (kind, scope, expiry, replacement ids)."},
       {"SourceVaultIntegrityRecordOwnerReview", "Owner + ticket: spools an OwnerReviewed claim (ids, scope text)."},
       {"SourceVaultIntegrityRegisterVerifier", "Owner + ticket: spools a verifier registration (name, kind, properties, implementation digest)."},
       {"SourceVaultIntegrityLabel", "Returns the effective label of a version; Model / MCP get a PL-projected view."},
       {"SourceVaultIntegrityRetrievalFilter", "Drops quarantined / unknown-derived candidates for automatic use; logs counts only."},
       {"SourceVaultIntegrityPolicySnapshot", "Returns per-item digests of security settings (no values)."},
       (* Inc4 (2026-11-10) *)
       {"SourceVaultIntegrityPublishGate", "Checks items to publish against the quarantine tables; spools a Publish activity with a keyed destination digest."},
       {"SourceVaultModelManifest", "Reads LM Studio model ids, sizes, template digests and runtime version from local config files; no secrets."},
       {"SourceVaultModelManifestDiff", "Compares the model manifest with the accepted baseline (ids and digests)."},
       (* Inc5 (2026-11-10) *)
       {"SourceVaultKnowledgeHealth", "Returns component health and table 8.1 indicators from state.json (counts only)."},
       {"SourceVaultIntegrityBlastRadius", "Returns descendant counts of a finding; Model / MCP get counts only."},
       {"SourceVaultIntegrityFailClosedReadiness", "Reports index freshness for the fail-closed switch (ages and reason codes)."}}]];
  Null, Null];
iSVIRegisterPrivacyContracts[];

End[]  (* `IntegrityPrivate` *)

EndPackage[]  (* SourceVault` *)
