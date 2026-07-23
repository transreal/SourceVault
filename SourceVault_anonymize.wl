(* ::Package:: *)

(* ============================================================
   SourceVault_anonymize.wl -- 匿名化 (declassification) 拡張
   仕様: ドキュメント/sourcevault_anonymization_spec_v1_0.md (v1.0 正準)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_anonymize.wl"]]

   実装済み増分:
     L0a: Canonicalization v1 / KeyRing (NBAccess MAC KeyRef 上) /
          衝突耐性 ID 式 (EntityID / SourceObjectID / SourceUnitID / DerivedUnitID) /
          役割別 token (Subject / Item / Job / ResultSlot) + ReleaseHandle (CSPRNG)
     G0a: schema-only SourceVaultAnonymizationPlan (本文非読)

   設計要点 (仕様 §2):
     P-A3  fail-closed: 判定不能・欠落キー・未知型は $Failed / Failure。
     P-A13 identity の独立性: SourceUnitID は SourceObjectID を含む
           (別人の同一内容提出でも衝突しない)。並び順に依存しない。
     P-A15 owner-authorized execution: 本モジュールの Plan は本文を読まない。
           高 PL 本文を読む Execute (SourceVaultAnonymize) は G0b の grant gate
           実装後に追加する (本ファイルでは未定義)。
     P-A19 record 束縛: Origins は ref+digest+role を同一 record に束縛し
           canonical sort + digest する。

   依存: NBAccess`NBMacWithKeyRef / NBGenerateMacKeyRef / NBKeyStatus (鍵材料非接触)。
   未ロード時は鍵依存 API が fail-closed で $Failed を返す (モジュール自体はロード可)。

   非衝突方針: private helper は SourceVault`AnonymizePrivate` 文脈、iSVA プレフィクス。
   ============================================================ *)

BeginPackage["SourceVault`"]

(* ---- 定数 ---- *)
$SourceVaultAnonymizeEngineVersion::usage =
  "$SourceVaultAnonymizeEngineVersion は匿名化パイプラインの実装版識別子 (cache identity の一成分)。";
$SourceVaultAnonymizeCanonicalizationVersion::usage =
  "$SourceVaultAnonymizeCanonicalizationVersion は CanonicalEncode 規則の版。ID 生成に焼き込まれる。";
$SourceVaultAnonymizeLineageSchemaVersion::usage =
  "$SourceVaultAnonymizeLineageSchemaVersion は LineageManifest schema の版。SourceUnitID に焼き込まれる。";
$SourceVaultAnonymizeIdentityKeyRef::usage =
  "$SourceVaultAnonymizeIdentityKeyRef は EntityID / SourceObjectID 用 HMAC 鍵の KeyRef (namespaceKey)。";
$SourceVaultAnonymizeLineageKeyRef::usage =
  "$SourceVaultAnonymizeLineageKeyRef は SourceUnitID / DerivedUnitID 用 HMAC 鍵の KeyRef (lineageKey)。";
$SourceVaultAnonymizeKeyId::usage =
  "$SourceVaultAnonymizeKeyId は現行の匿名化 ID 鍵世代識別子 (既定 \"idkey-1\")。ID に焼き込まれる。";
$SourceVaultAnonymizeTenantID::usage =
  "$SourceVaultAnonymizeTenantID は VaultOrTenantID (ID 名前空間)。既定 \"default\"。";

(* ---- KeyRing ---- *)
SourceVaultAnonymizeInitializeKeys::usage =
  "SourceVaultAnonymizeInitializeKeys[] は匿名化 ID 用 MAC 鍵 (identity/lineage) を冪等生成する。\n" <>
  "既存鍵は破壊しない。鍵材料は返さない。戻り値 <|Status, CreatedKeyRefs, ExistingKeyRefs|>。";
SourceVaultAnonymizeKeyStatus::usage =
  "SourceVaultAnonymizeKeyStatus[] は匿名化 ID 鍵の存在状況と Fingerprint (鍵材料なし) を返す。\n" <>
  "ノード間の fingerprint 検査 (仕様 §5.5.1: 不一致は停止) に使う。";

$SourceVaultAnonymizeFingerprintPinPath::usage =
  "$SourceVaultAnonymizeFingerprintPinPath は鍵 fingerprint pin ファイルの明示パス (テスト用上書き)。\n" <>
  "Automatic (既定) なら PrivateVault/config/anonymize-key-fingerprints.json。";

$SourceVaultAnonymizeAllowVolatileKeys::usage =
  "$SourceVaultAnonymizeAllowVolatileKeys (既定 False) が False のとき、揮発鍵バックエンド\n" <>
  "(NBAccess`$NBCredentialBackend =!= \"SystemCredential\") では鍵生成・ID 生成を拒否する。\n" <>
  "揮発鍵で発行した ID はカーネル再起動後に再現不能になるため (fail-closed)。\n" <>
  "True はテスト専用 (テンポラリ pin と併用)。";

SourceVaultAnonymizeVerifyKeyFingerprints::usage =
  "SourceVaultAnonymizeVerifyKeyFingerprints[] は現在の鍵 fingerprint を全ノード共有の pin と照合する\n" <>
  "(仕様 §5.5.1 / AC-053)。pin 未存在なら現鍵を pin して \"Pinned\"、一致は \"OK\"、\n" <>
  "不一致は \"Failed\" (KeyFingerprintMismatch — 以後の ID 生成は fail-closed で拒否される)。\n" <>
  "Memory バックエンドの使い捨て鍵カーネル (MCP 等) が誤って別 ID を発行する事故を防ぐ。";

(* ---- Canonicalization ---- *)
SourceVaultAnonymizeCanonicalEncode::usage =
  "SourceVaultAnonymizeCanonicalEncode[expr] は決定論的な正準文字列エンコード (v1) を返す。\n" <>
  "Association はキーをコードポイント順にソート、String は NFC 正規化 + JSON 風エスケープ、\n" <>
  "Integer/True/False/Null/ByteArray を受理。Real・未知型は fail-closed で $Failed\n" <>
  "(ID 計算に非決定論的な型を使わせない)。";
SourceVaultAnonymizeCanonicalDigest::usage =
  "SourceVaultAnonymizeCanonicalDigest[expr] は CanonicalEncode の UTF-8 バイト列の SHA-256 を\n" <>
  "64 桁小文字 hex で返す。エンコード不能なら $Failed。";

(* ---- ID 式 (仕様 §5.5.2) ---- *)
SourceVaultAnonymizeEntityID::usage =
  "SourceVaultAnonymizeEntityID[<|\"Institution\"->inst, \"CanonicalID\"->id|>] は\n" <>
  "実体の安定 ID \"ent:<hex>\" を返す (namespaced HMAC。生 ID の単純 hash は使わない)。\n" <>
  "必須キー欠落・鍵未初期化は $Failed。";
SourceVaultAnonymizeSourceObjectID::usage =
  "SourceVaultAnonymizeSourceObjectID[<|\"SourceSystem\"->sys, \"PrimaryKey\"->key|>] は\n" <>
  "論理オブジェクトの安定 ID \"sobj:<hex>\" を返す。authoritative key が無い場合は\n" <>
  "呼び出し側が ingest 時に発行した UUID を PrimaryKey として渡す (仕様 §5.5.2)。";
SourceVaultAnonymizeSourceUnitID::usage =
  "SourceVaultAnonymizeSourceUnitID[spec] は原本要素の ID \"sunit:<hex>\" を返す。\n" <>
  "必須キー: SourceObjectID, SourceVersionID, SourceUnitKind, CanonicalLocatorDigest,\n" <>
  "SourceContentDigest。VaultOrTenantID / CanonicalizationVersion / LineageSchemaVersion /\n" <>
  "KeyId は自動付与。欠落は $Failed (fail-closed)。別論理オブジェクトの同一内容とは衝突しない。";
SourceVaultAnonymizeDerivedUnitID::usage =
  "SourceVaultAnonymizeDerivedUnitID[spec] は派生要素の ID \"dunit:<hex>\" を返す。\n" <>
  "必須キー: ParentUnitIDs (非空リスト。内部でソートし順序非依存), RelationType,\n" <>
  "PolicyDigest, TransformDigest, DerivedLocatorDigest, DerivedContentDigest,\n" <>
  "OutputOrdinalOrRole。欠落は $Failed。";

(* ---- token (仕様 §5.5.3) ---- *)
SourceVaultAnonymizeGenerateToken::usage =
  "SourceVaultAnonymizeGenerateToken[type] は役割別 token を CSPRNG で生成する。\n" <>
  "type: \"Subject\"->\"S-XXXXXX-C\" / \"Item\"->\"I-...\" / \"Job\"->\"J-...\" / \"ResultSlot\"->\"R-...\"。\n" <>
  "Crockford base32 6 文字 + checksum 1 文字。非意味的 (元 ID・件数・順序を推測させない)。";
SourceVaultAnonymizeTokenValidQ::usage =
  "SourceVaultAnonymizeTokenValidQ[token] は token の形式と checksum を検証する (転記ミス検出)。";
SourceVaultAnonymizeGenerateReleaseHandle::usage =
  "SourceVaultAnonymizeGenerateReleaseHandle[] は低 PL 側 bearer 取得ハンドル\n" <>
  "\"sv://release/<64hex>\" を CSPRNG (256bit) で生成する。content から導出しない (仕様 §5.10)。";
SourceVaultAnonymizeReleaseHandleValidQ::usage =
  "SourceVaultAnonymizeReleaseHandleValidQ[h] は ReleaseHandle の形式を検証する。";

(* ---- L0b: LineageManifest graph (仕様 §5.4) ---- *)
SourceVaultAnonymizeBuildLineageManifest::usage =
  "SourceVaultAnonymizeBuildLineageManifest[spec] は node/edge graph の LineageManifest を構築する。\n" <>
  "spec: <|\"Origins\"->{record...}, \"PolicyRef\", \"MapRef\", \"SourceNodes\", \"DerivedNodes\",\n" <>
  "\"Edges\", \"Partitions\", \"Invariants\"|>。OriginSetDigest / MemberSetDigest / ManifestDigest を\n" <>
  "計算して焼き込み、構築後に SourceVaultValidateLineage で自己検証する (不合格は Failed)。\n" <>
  "N:1 / N:M の集約を Edges の Cardinality で正準表現する (入れ子複製を作らない)。";

SourceVaultValidateLineage::usage =
  "SourceVaultValidateLineage[manifest] は LineageManifest の graph/partition/token/digest 整合を\n" <>
  "機械検証する (仕様 §9.2 L1-L5 の構造部分 / AC-040/044/046)。\n" <>
  "戻り値 <|Status->\"OK\"|\"Failed\", Findings->{<|Check, Detail|>...}, Counts|>。\n" <>
  "報告には unit ID / 件数のみを含め、locator・Identity 等の PII は含めない。";

(* ---- G0b: DeclassificationGrant (仕様 §5.13, §8.1 段 0a, §10) ---- *)
SourceVaultRequestDeclassification::usage =
  "SourceVaultRequestDeclassification[plan, opts] は schema-only Plan から declassification の\n" <>
  "承認要求レコードを作る (本文非読のまま)。オーナーが選ぶ項目をオプションで固定:\n" <>
  "\"TargetLevel\"->\"0.45\"|\"0.2\", \"Purpose\", \"IntendedSink\"-><|\"Class\"->...|>,\n" <>
  "\"PolicyRef\", \"PublishMode\"->\"StageForOwnerReview\"(既定)|\"PublishIfVerified\",\n" <>
  "\"MaxExecuteUses\"->1, \"TTLSeconds\"->86400。戻り値は Request レコード。";

SourceVaultApproveDeclassification::usage =
  "SourceVaultApproveDeclassification[request] はオーナー対話環境 (FrontEnd) でのみ実行できる\n" <>
  "承認操作。exact な origin/policy/TargetLevel/purpose/sink/期限/uses を焼き込んだ\n" <>
  "DeclassificationGrant を発行し MAC 署名する (agent/LLM は自己承認できない —\n" <>
  "本ヘッドは NBAccess 承認ゲートに登録され、非対話環境では拒否される)。";

SourceVaultVerifyDeclassificationGrant::usage =
  "SourceVaultVerifyDeclassificationGrant[grant, request] は grant の MAC・digest・期限と、\n" <>
  "実行要求 (OriginSetDigest/TargetLevel/Purpose/SinkClass/PolicyDigest) の exact 一致を検証する\n" <>
  "(仕様 段 0a: 本文非読)。一項目でも不一致なら Failed (DeclassificationTargetMismatch 等)。";

SourceVaultConsumeDeclassificationGrantUse::usage =
  "SourceVaultConsumeDeclassificationGrantUse[grant, operationId] は grant の Execute use を\n" <>
  "lease として消費する。同一 operationId の再呼び出しは冪等に再開 (crash retry)、\n" <>
  "別 operationId で MaxUses 超過なら Failed (仕様 GrantExecutionLease / AC-088)。";

(* ---- L1: PseudonymMap (仕様 §5.3) ---- *)
SourceVaultAnonymizePseudonymMapId::usage =
  "SourceVaultAnonymizePseudonymMapId[<|\"EntityClass\"->cls, \"MapScope\"->scope|>] は\n" <>
  "論理 map ID \"map:<hex>\" を返す (tenant/EntityClass/scope/token scheme/KeyId/正規化版を包含)。\n" <>
  "scope が異なれば独立採番 (意図しないコース間リンク防止)。";

SourceVaultAnonymizeAssignSubjectTokens::usage =
  "SourceVaultAnonymizeAssignSubjectTokens[mapSpec, identities] は対応表へ実体を追記し\n" <>
  "SubjectToken を割り当てる (lock -> head 再読込 -> merge -> uniqueness 検査 ->\n" <>
  "新しい不変 MapVersion 保存 (PL 1.0) -> MapHead CAS。競合はリトライ)。\n" <>
  "同一実体 (EntityID) は常に既存 token を返す (採番安定)。identities の各要素:\n" <>
  "<|\"Institution\", \"CanonicalID\", \"Identity\"-><|...|>, \"KnownStrings\"->{...}|>。\n" <>
  "戻り値 <|Status, MapId, MapRef, MapVersion, Assignments|>。";

SourceVaultAnonymizePseudonymMap::usage =
  "SourceVaultAnonymizePseudonymMap[mapIdOrRef] は対応表を読み出す (PL 1.0 の透かし付き)。\n" <>
  "MapId なら MapHead の最新版、snapshot ref なら exact 版 (head が進んでも内容不変 = AC-029)。";

(* ---- L2a: ArtifactBinding + 逆引き (仕様 §5.6, §7.3) ---- *)
SourceVaultAnonymizedVariants::usage =
  "SourceVaultAnonymizedVariants[origRefOrURI] は元オブジェクトに紐づく匿名化成果物の\n" <>
  "一覧 (BindingRef/ArtifactRef/PolicyRef/MapRef) を返す。unlisted の唯一の一覧経路であり、\n" <>
  "逆引き index は origin ref の keyed HMAC をキーに引く (origin を知る principal だけが\n" <>
  "導出できる)。読み出しには PL 1.0 の透かしが付く。";

(* ---- A7: MCP projection / unlisted (仕様 §15.1, §15.3, §10.5) ---- *)
SourceVaultAnonymizeGetByHandle::usage =
  "SourceVaultAnonymizeGetByHandle[releaseHandle] は exact ReleaseHandle 経由で匿名化成果物を\n" <>
  "取得する唯一の無許可 Reuse 経路 (仕様 §10.5)。handle 解決 -> PublicationHead が Published か\n" <>
  "確認 -> 低 PL projection (Payload=ItemToken ベース行・TargetLevel・Format のみ。\n" <>
  "系譜参照 OriginRef/MapRef/BindingRef は一切含まない) を返す。Revoked/Expired は HandleInvalid。";

SourceVaultAnonymizeUnlistedClassQ::usage =
  "SourceVaultAnonymizeUnlistedClassQ[source] は source (snapshot record 等) が匿名化拡張の\n" <>
  "unlisted クラス (検索・カタログ・一覧に載せない) かを返す (仕様 §15.1)。\n" <>
  "Discoverability==\"Unlisted\" または匿名化 ObjectClass / DerivedArtifact(Anonymized) を True。\n" <>
  "検索索引の release policy から弱結合で呼ばれる。";

(* ---- L2b: Publication (仕様 §5.10, §8.2, §10.4) ---- *)
SourceVaultAnonymizePublicationStatus::usage =
  "SourceVaultAnonymizePublicationStatus[artifactRef] は公開状態の正本 (PublicationHead ->\n" <>
  "PublicationRecord) を解決し、record と artifact/binding の digest 一致・State・epoch を\n" <>
  "検証して返す (release 判定核。PL は record の TargetLevel を使う)。\n" <>
  "head が無ければ NotPublished (Staged/Draft は構造的に不可視 = AC-048)。";

SourceVaultRevokeDeclassifiedArtifact::usage =
  "SourceVaultRevokeDeclassifiedArtifact[artifactRef, reason] は公開を失効させる\n" <>
  "(オーナー対話環境限定)。新 PublicationRecord (State->Revoked) + head CAS +\n" <>
  "全 ReleaseHandle 失効 + PL sidecar を fail-closed 既定へ戻す。\n" <>
  "既に外部へ渡った copy は回収不能である (監査イベントに明記される)。";

(* ---- L3a/L3b: 評価 manifest + annotation + join (仕様 §5.9, §5.11, §13) ---- *)
SourceVaultAnonymizeBuildEvaluationPlan::usage =
  "SourceVaultAnonymizeBuildEvaluationPlan[spec] は送信前 EvaluationPlanManifest を構築・保存する\n" <>
  "(PL 1.0)。spec: <|\"TargetArtifactRef\", \"ArtifactBindingRef\", \"Units\" ->\n" <>
  "{<|\"ItemTokens\"->{...}, \"SubjectToken\"|>...}, \"RubricDigest\"|>。1 unit = 1 job = 1 受験者。\n" <>
  "結果帰属の正本となる JobID -> ItemToken の out-of-band binding を確定する。";

SourceVaultAnonymizeQuarantineIngress::usage =
  "SourceVaultAnonymizeQuarantineIngress[planRef, jobId, raw] は provider 生応答を受信 byte の\n" <>
  "時点から protected minimum PL (既定 1.0) の quarantine に隔離保存する (AC-086)。";

SourceVaultCreateDerivedAnnotations::usage =
  "SourceVaultCreateDerivedAnnotations[artifactRef, resultEnvelope] は評価結果を\n" <>
  "AnnotationContent (protected minimum PL) + AnnotationBinding (PL 1.0) として保存する。\n" <>
  "結果帰属の正本は EvaluationPlanManifest の JobID -> ItemToken (out-of-band binding) であり、\n" <>
  "応答が名乗る token は使わない。unknown/missing/duplicate な JobID はすべて全 batch Failed\n" <>
  "(部分成績を作らない = AC-026/033)。envelope: <|\"PlanRef\", \"Results\" ->\n" <>
  "{<|\"JobID\", \"Score\", \"Reason\"|>...}, \"ProtectedMinimum\" -> 1.0|>。";

SourceVaultValidateDerivedJoin::usage =
  "SourceVaultValidateDerivedJoin[annotationBindingRef] は join preview を実行する:\n" <>
  "binding digest -> Plan/lineage/map の exact pin 検証 -> annotation の全 ItemToken を\n" <>
  "ItemToken -> DerivedUnit -> SubjectToken -> Entity の経路で解決し、\n" <>
  "Matched/Missing/Unknown/Duplicate を機械可読で報告する (PII は含めない)。";

SourceVaultAttachDerivedResults::usage =
  "SourceVaultAttachDerivedResults[annotationBindingRef] は join preview 全合格時のみ、\n" <>
  "結果を実 Identity と結合して返す (PL 1.0 の透かし付き)。1 件でも不一致なら 0 件失敗\n" <>
  "(部分書き戻し禁止 = AC-025)。origin/map の引数上書きは受けない (annotation から自動解決)。";

(* ---- U0: ReleaseHandle mapping (仕様 §5.10, §10.5) ---- *)
SourceVaultResolveReleaseHandle::usage =
  "SourceVaultResolveReleaseHandle[handle] は bearer 取得ハンドル \"sv://release/...\" を\n" <>
  "publication へ解決する (無許可 Reuse の唯一の経路)。mapping には handle 平文を保存せず\n" <>
  "keyed HMAC digest で引く。Active かつ未期限のみ OK。Revoked/Expired/NotFound は\n" <>
  "区別せず HandleInvalid (存在 oracle 防止)。";
SourceVaultRevokeReleaseHandle::usage =
  "SourceVaultRevokeReleaseHandle[artifactRef] は artifact の全 ReleaseHandle を失効させる\n" <>
  "(オーナー対話環境限定の mutation)。content identity は変わらない。";
SourceVaultRotateReleaseHandle::usage =
  "SourceVaultRotateReleaseHandle[artifactRef] は旧 handle を全て失効させ新 handle を発行する\n" <>
  "(handle 漏洩対応。オーナー対話環境限定)。新 handle 平文は返り値でのみ渡される\n" <>
  "(mapping には digest しか残らない)。artifact の content identity は不変 (AC-085)。";

(* ---- G1: CompositionPolicy + ExposureLedger (仕様 §13.5, §5.14) ---- *)
SourceVaultAnonymizeComposedPrivacy::usage =
  "SourceVaultAnonymizeComposedPrivacy[spec] は集約・結合物の PrivacyLevel を返す (仕様 §13.5)。\n" <>
  "spec: <|\"AnnotationType\", \"DistinctSubjectCount\", \"IndividualValuesPresent\",\n" <>
  "\"InputPL\"|>。成績を含む/複数 subject の個別値を含む集約は PL 1.0 (単純 Max では判定しない)。";

SourceVaultAnonymizeRecordExposure::usage =
  "SourceVaultAnonymizeRecordExposure[event] は ExposureEvent を高 PL の append-only ledger へ\n" <>
  "durable 記録する (本文・実 token を含めない。ScopeID/SubjectSetDigest は owner-only HMAC)。\n" <>
  "EventClass: PublicationActivated / ContentReleased / CloudEgressed / CloudIngressReceived /\n" <>
  "AggregateCreated / ReleaseDenied / ReleaseIndeterminate。coverage 加算は release 系のみ。";

SourceVaultAnonymizeExposureGuard::usage =
  "SourceVaultAnonymizeExposureGuard[intent] は release/egress 直前に ExposureLedger rollup を\n" <>
  "評価し Permit / PermitAndReport / RequireOwnerApproval / Deny を返す (仕様 §15.2)。\n" <>
  "release 前に PreReleaseIntent を durable 記録 (これに失敗したら Deny = 無記録では通さない)。\n" <>
  "閾値未満の単発は自動 Permit、cohort coverage / distinct subject / variant 超過は停止。\n" <>
  "intent: <|\"ScopeID\", \"ProviderTrustDomain\", \"DistinctSubjects\", \"CohortSize\",\n" <>
  "\"VariantSetDigest\", \"RequestID\", \"ExposurePolicy\"|>。";

(* ---- G2: EvaluationDistributionPlan (仕様 §13.6) ---- *)
SourceVaultAnonymizeValidateDistribution::usage =
  "SourceVaultAnonymizeValidateDistribution[plan, assignment] は provider 分散が owner-approved\n" <>
  "DistributionPlan に適合するかを検査する (仕様 §13.6): 未許可 provider / provider あたり\n" <>
  "subject 上限超過 / 同一 subject の重複送信 (冗長採点は明示許可のみ) を拒否する。";

(* ---- G1c: System Doctor 連携 (仕様 §16.2) ---- *)
SourceVaultAnonymizeExposureProbe::usage =
  "SourceVaultAnonymizeExposureProbe[] は SystemDoctor 向けの sanitized probe。\n" <>
  "ExposureLedger を集計し Health / ReasonCode / 件数レンジのみを返す\n" <>
  "(artifact/provider/owner/scope の実値は出さない。alert 自体の漏洩防止 = 仕様 T41)。";
SourceVaultAnonymizeExposureSensitiveDoctor::usage =
  "SourceVaultAnonymizeExposureSensitiveDoctor[] はオーナー対話環境限定の詳細診断:\n" <>
  "provider trust domain 別 coverage・variant 数・該当 scope・推奨 remediation を返す。\n" <>
  "非オーナー環境では拒否 (OwnerOnly)。";
SourceVaultRegisterAnonymizeExposureDiagnostics::usage =
  "SourceVaultRegisterAnonymizeExposureDiagnostics[] は exposure probe を SourceVault\n" <>
  "diagnostics (SIEM) に登録する (弱結合。diagnostics 未ロードなら DiagnosticsUnavailable)。\n" <>
  "High/Critical は SourceVaultDiagnosticsEscalate へ cloud-safe summary で送られる。";
SourceVaultAnonymizeExposureEscalateIfNeeded::usage =
  "SourceVaultAnonymizeExposureEscalateIfNeeded[] は probe が High/Critical のとき\n" <>
  "cloud-safe な escalation event を SourceVaultDiagnosticsEscalate へ送る (弱結合)。";

(* ---- A6: フォーマット変換 (仕様 §6.6, §12) ---- *)
SourceVaultAnonymizeImageRedact::usage =
  "SourceVaultAnonymizeImageRedact[img, regions] は画像の指定領域を黒塗りして再エンコードした\n" <>
  "新しい Image を返す (仕様 §6.6)。regions: {<|\"x1\",\"y1\",\"x2\",\"y2\"|>...} 正規化座標 (0-1)。\n" <>
  "ラスタ上書き+再エンコードなので元のメタデータ・レイヤは残らない。";
SourceVaultAnonymizePDFPageImages::usage =
  "SourceVaultAnonymizePDFPageImages[pdfPages, opts] はマルチページ PDF (Image のリスト、または\n" <>
  "{Image} 化済み) の各ページを指定領域黒塗り+再エンコードした画像リストへ変換する。\n" <>
  "opts: \"Regions\"->{...}(全ページ共通の正規化矩形), \"DPI\"。Format \"PageImageList\" 相当。";
SourceVaultAnonymizeVerifyRedactedImage::usage =
  "SourceVaultAnonymizeVerifyRedactedImage[img, regions] は V5 (変換完全性) の独立検査を行う:\n" <>
  "各黒塗り領域のピクセルが単色 (分散≈0) であることを確認する (仕様 §6.8 / AC-020)。\n" <>
  "検出器と別系統の決定論チェック。";

SourceVaultAnonymizeMediaScan::usage =
  "SourceVaultAnonymizeMediaScan[img, opts] はローカル OCR/vision (注入シーム) で画像内の\n" <>
  "PII 領域を自動検出し、宣言 Regions と併せて黒塗りする (仕様 §6.8, 増分 A8)。\n" <>
  "opts: \"DeclaredRegions\"->{...}(必ず塗る), \"MediaScanFn\"->fn(img->{<|x1,y1,x2,y2,confidence|>...})\n" <>
  "  ローカル限定の検出器 (未指定は検出なし), \"ConfidenceThreshold\"->0.5,\n" <>
  "  \"IndependentVerifierFn\"->fn(img->{残存領域...})(V5 の独立検出器。redaction とは別系統)。\n" <>
  "戻り値 <|Status->\"OK\"|\"NeedsReview\", Image, Regions, Evidence|>。\n" <>
  "検出器不通・低 confidence のみで宣言 Regions もない・独立 verifier が残存検出 -> NeedsReview\n" <>
  "(fail-closed。自動 Publish しない)。検出証跡は PL 1.0 想定 (呼び出し側で保存)。";

(* ---- C4: 答案 PDF 採点 (仕様 §12.1, §12.2, §14.3) ---- *)
SourceVaultAnonymizeBuildPageUnits::usage =
  "SourceVaultAnonymizeBuildPageUnits[spec, opts] はスキャン PDF をページ単位の SourceUnit へ\n" <>
  "分解する (仕様 §12.1)。spec: <|\"SourceObjectID\", \"SourceVersionID\", \"PDFDigest\",\n" <>
  "\"Pages\"->{Image...}|>。各ページに SourceUnitID (PDF digest+physical page index+page image\n" <>
  "digest) と ContentUnitID (位置非依存) を与え、空白ページ・重複ページを検出する。\n" <>
  "ページ順入替に対しては ContentUnitID / PageUnitContentSetDigest が不変 (digest ベース)。";
SourceVaultAnonymizeRecordIdentityEvidence::usage =
  "SourceVaultAnonymizeRecordIdentityEvidence[candidates, opts] は OCR 由来の identity 候補を\n" <>
  "IdentityEvidence (PL 1.0 不変 snapshot) として記録する (仕様 §12.2)。OCR 出力を identity として\n" <>
  "即採用しない: fail-closed 条件 (LowConfidence / IDNotInRoster / RosterNameMismatch /\n" <>
  "NonContiguousPages / AmbiguousPageBoundary / SubjectCountMismatch / PageCountMismatch) の\n" <>
  "いずれかに触れた subject は NeedsAdjudication となり自動確定しない。\n" <>
  "opts: \"Roster\"->{<|StudentID, StudentName|>...}, \"ConfidenceThreshold\"->0.8,\n" <>
  "  \"ExpectedSubjectCount\"/\"ExpectedPageCount\"->Automatic, \"Engine\"/\"EngineVersion\"/\"Config\"。\n" <>
  "戻り値には実体 (氏名・学籍番号・raw text) を入れない (EvidenceRef と SubjectKey のみ)。";
SourceVaultAnonymizeAdjudicateIdentity::usage =
  "SourceVaultAnonymizeAdjudicateIdentity[evidenceRef, decision] は identity の目視確定を\n" <>
  "append-only の adjudication event として記録する (仕様 §12.2)。原本 EvidenceDigest と\n" <>
  "候補 digest を pin する。decision: <|\"SubjectKey\", \"Decision\"->\"Confirmed\"|\"Rejected\",\n" <>
  "\"Adjudicator\", \"Note\"|>。オーナー対話セッション必須 (非対話は拒否)。";
SourceVaultAnonymizeIdentityStatus::usage =
  "SourceVaultAnonymizeIdentityStatus[evidenceRef] は IdentityEvidence の初期状態に\n" <>
  "adjudication event を畳んで最終状態を返す。\n" <>
  "戻り値: <|State->\"Resolved\"|\"NeedsAdjudication\", ConfirmedSubjectKeys, PendingSubjectKeys,\n" <>
  "RejectedSubjectKeys, Subjects|>。未確定 subject が 1 つでもあれば NeedsAdjudication。";
SourceVaultAnonymizeAnswerSheetPages::usage =
  "SourceVaultAnonymizeAnswerSheetPages[pages, opts] は答案ページ画像を宣言 Regions +\n" <>
  "MediaScan (A8) で黒塗りし PageImageList 成果物を作る (仕様 §12, §14.3)。\n" <>
  "MediaScan が OK でないページは成果物に入れず ExcludedPages に落とす (fail-closed)。\n" <>
  "opts: \"DeclaredRegions\", \"MediaScanFn\", \"ConfidenceThreshold\", \"IndependentVerifierFn\"。\n" <>
  "PageReports には画像を含めない (証跡のみ)。";
SourceVaultAnonymizeAnswerSheetPlan::usage =
  "SourceVaultAnonymizeAnswerSheetPlan[spec, opts] は答案採点の EvaluationPlanManifest を作る\n" <>
  "(仕様 §14.3)。EvaluationUnit = 一受験者の全ページ、ResultSlot = 設問別。\n" <>
  "spec: <|\"TargetArtifactRef\", \"ArtifactBindingRef\", \"RubricDigest\",\n" <>
  "\"Subjects\"->{<|\"SubjectKey\", \"SubjectToken\", \"ItemTokens\", \"Slots\"|>...}|>。\n" <>
  "opts: \"IdentityEvidenceRef\"->ref (指定時は adjudication で Confirmed の subject のみ採点対象。\n" <>
  "残りは ExcludedUnits(IdentityNotConfirmed) — 別人への書き戻しを防ぐ fail-closed)。";

(* ---- A0: ポリシー登録 (仕様 §5.1, §6.1) ---- *)
SourceVaultRegisterAnonymizationPolicy::usage =
  "SourceVaultRegisterAnonymizationPolicy[policy] は匿名化ポリシーを不変 snapshot として登録する。\n" <>
  "必須: PolicyId / SchemaVersion / Tiers (TargetLevel 別の FieldRules/TextRules 等)。\n" <>
  "PolicyPrivacyLevel が snapshot sidecar に設定される。改訂は新 digest = 別 variant。";
SourceVaultAnonymizationPolicies::usage =
  "SourceVaultAnonymizationPolicies[] は登録済みポリシーの registry (PolicyId -> ref) を返す。";
SourceVaultAnonymizationPolicy::usage =
  "SourceVaultAnonymizationPolicy[idOrRef] はポリシーを解決してロードする (PolicyDigest 付き)。";

(* ---- A1-A3: 匿名化本体 (仕様 §7.1, §8) ---- *)
SourceVaultAnonymize::usage =
  "SourceVaultAnonymize[origRef, opts] はオーナー grant の下で匿名化を実行する (仕様 §8)。\n" <>
  "段 0a (grant 検証・本文非読) -> 0b (exact origin open) -> Pseudonymize -> FieldRules ->\n" <>
  "三層 TextRules (KnownValueScan / Patterns / PrivateModelScan シーム) -> lineage 構築 ->\n" <>
  "Verify (V1/V2/V3) -> artifact+binding 保存 -> publish (grant の PublishMode に従う)。\n" <>
  "opts: \"GrantRef\"->grant (必須。無しは NeedsOwnerApproval で本文に触れない)、\n" <>
  "\"TargetLevel\"->Automatic (= grant の ExactTargetLevel)、\"Policy\"->Automatic、\n" <>
  "\"PrivateModelScanFn\"/\"VerifyFn\" (ローカル LLM シーム。ポリシーが要求し未注入なら\n" <>
  "NeedsReview で保存しない)、\"Force\"->False。同一 identity の再呼び出しは CacheHit。";

(* ---- G0a: schema-only Plan (仕様 §7.1) ---- *)
SourceVaultAnonymizationPlan::usage =
  "SourceVaultAnonymizationPlan[origRef] は schema-only の匿名化計画を返す (本文非読)。\n" <>
  "origRef: sv:// URI / snapshot ref / それらのリスト。payload・blob・対応表・OCR・LLM には\n" <>
  "一切触れない (参照するのは ref 文字列と snapshot privacy sidecar のみ)。\n" <>
  "戻り値: <|Type, SchemaVersion, Origins (record 束縛), OriginSetDigest, TargetLevelChoices,\n" <>
  "SinkChoices, CandidatePolicies, PlanDigest, ...|>。\n" <>
  "オプション: \"Save\"->False (True で AnonymizationPlan snapshot として保存し Ref を含める)。";

Begin["`AnonymizePrivate`"]

(* ============================================================
   0. 定数
   ============================================================ *)

$SourceVaultAnonymizeEngineVersion = "anonymize-1";
$SourceVaultAnonymizeCanonicalizationVersion = 1;
$SourceVaultAnonymizeLineageSchemaVersion = 2;
$SourceVaultAnonymizeIdentityKeyRef = "SourceVault:anonid:identity:v1";
$SourceVaultAnonymizeLineageKeyRef  = "SourceVault:anonid:lineage:v1";
$SourceVaultAnonymizeKeyId = "idkey-1";
If[!ValueQ[$SourceVaultAnonymizeTenantID], $SourceVaultAnonymizeTenantID = "default"];

(* NBAccess crypto の可用性 (弱結合。無ければ鍵依存 API は fail-closed) *)
iSVANBCryptoQ[] :=
  Names["NBAccess`NBMacWithKeyRef"] =!= {} &&
  Names["NBAccess`NBGenerateMacKeyRef"] =!= {} &&
  Names["NBAccess`NBKeyStatus"] =!= {};

(* 永続鍵バックエンド要件 (実測 2026-07-23: 既定 "Memory" は揮発 -- FE 再起動で
   鍵消失 = KeysMissing。揮発鍵の ID は再現不能なので生成前に止める) *)
If[!ValueQ[$SourceVaultAnonymizeAllowVolatileKeys],
  $SourceVaultAnonymizeAllowVolatileKeys = False];

iSVABackendName[] := Quiet @ Check[NBAccess`$NBCredentialBackend, "Unknown"];
iSVABackendOKQ[] :=
  iSVABackendName[] === "SystemCredential" ||
  TrueQ[$SourceVaultAnonymizeAllowVolatileKeys];

iSVAVolatileBackendFailure[] :=
  <|"Status" -> "Failed", "Reason" -> "VolatileKeyBackend",
    "Backend" -> iSVABackendName[],
    "Hint" -> "Set NBAccess`$NBCredentialBackend = \"SystemCredential\" BEFORE key generation (see startup file template). Volatile keys would mint unreproducible ids."|>;

(* ============================================================
   1. KeyRing (仕様 §5.5.1)
   NBAccess の MAC KeyRef 機構に乗る。鍵材料はこのモジュールに現れない。
   ============================================================ *)

$iSVAGrantKeyRef = "SourceVault:anonid:grant:v1";

iSVAKeySpecs[] := {
  {$SourceVaultAnonymizeIdentityKeyRef, "anonymize identity/entity HMAC (namespaceKey)"},
  {$SourceVaultAnonymizeLineageKeyRef,  "anonymize lineage unit HMAC (lineageKey)"},
  {$iSVAGrantKeyRef, "anonymize declassification grant MAC"}};

iSVAKeyExistsQ[keyRef_String] :=
  iSVANBCryptoQ[] && !MissingQ[Quiet @ Check[NBAccess`NBKeyStatus[keyRef], Missing["Error"]]];

SourceVaultAnonymizeInitializeKeys[] := Module[{specs, existing, missing, created},
  If[!iSVANBCryptoQ[],
    Return[<|"Status" -> "Failed", "Reason" -> "NBAccessCryptoUnavailable"|>]];
  If[!iSVABackendOKQ[], Return[iSVAVolatileBackendFailure[]]];
  specs = iSVAKeySpecs[];
  existing = Select[specs, iSVAKeyExistsQ[#[[1]]] &][[All, 1]];
  missing = Select[specs, !iSVAKeyExistsQ[#[[1]]] &];
  created = (
     NBAccess`NBGenerateMacKeyRef[#[[1]],
       <|"Purpose" -> #[[2]], "RotationStable" -> True,
         "Owner" -> "SourceVault", "KeyId" -> $SourceVaultAnonymizeKeyId|>];
     #[[1]]) & /@ missing;
  <|"Status" -> If[created === {}, "AlreadyInitialized", "Initialized"],
    "CreatedKeyRefs" -> created,
    "ExistingKeyRefs" -> existing,
    "KeyId" -> $SourceVaultAnonymizeKeyId,
    "KeyMaterialReturned" -> False|>];

SourceVaultAnonymizeKeyStatus[] := Module[{},
  If[!iSVANBCryptoQ[],
    Return[<|"Status" -> "Failed", "Reason" -> "NBAccessCryptoUnavailable"|>]];
  Association[(#[[1]] -> Module[{st = Quiet @ Check[NBAccess`NBKeyStatus[#[[1]]], Missing["Error"]]},
       <|"Exists" -> !MissingQ[st],
         "Purpose" -> #[[2]],
         "KeyId" -> $SourceVaultAnonymizeKeyId,
         "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion,
         "Fingerprint" -> If[!MissingQ[st], Lookup[st, "Fingerprint", Missing["NoFingerprint"]],
            Missing["NotGenerated"]]|>]) & /@ iSVAKeySpecs[]]];

(* ---- fingerprint pin (仕様 §5.5.1 / AC-053) ----
   pin は全ノード共有の PrivateVault/config に置き、SystemCredential 正本鍵の
   fingerprint を固定する。Memory バックエンドのカーネル (例: MCP 共有カーネル、
   実測 2026-07-23: FE と別鍵を silent 生成) では照合が不一致となり、
   ID 生成が fail-closed で止まる (黙って別 ID を発行しない)。 *)

If[!ValueQ[$SourceVaultAnonymizeFingerprintPinPath],
  $SourceVaultAnonymizeFingerprintPinPath = Automatic];

iSVAPinPath[] := Which[
  StringQ[$SourceVaultAnonymizeFingerprintPinPath], $SourceVaultAnonymizeFingerprintPinPath,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r], FileNameJoin[{r, "config", "anonymize-key-fingerprints.json"}], $Failed]],
  True, $Failed];

iSVACurrentFingerprints[] := Module[{st = SourceVaultAnonymizeKeyStatus[]},
  If[!AssociationQ[st] || Lookup[st, "Status"] === "Failed", Return[$Failed]];
  If[!AllTrue[Values[st], TrueQ[#["Exists"]] && StringQ[#["Fingerprint"]] &], Return[$Failed]];
  Association[KeyValueMap[#1 -> #2["Fingerprint"] &, st]]];

SourceVaultAnonymizeVerifyKeyFingerprints[] := Module[{path, cur, pinned, rec, mismatches},
  path = iSVAPinPath[];
  cur = iSVACurrentFingerprints[];
  Which[
    !iSVABackendOKQ[],
    $iSVAFpVerdict = iSVAVolatileBackendFailure[],
    cur === $Failed,
    $iSVAFpVerdict = <|"Status" -> "Failed", "Reason" -> "KeysMissing",
      "Backend" -> iSVABackendName[],
      "Detail" -> SourceVaultAnonymizeKeyStatus[],
      "Hint" -> "Run SourceVaultAnonymizeInitializeKeys[] under the SystemCredential backend first."|>,
    path === $Failed,
    $iSVAFpVerdict = <|"Status" -> "Skipped", "Reason" -> "PinStoreUnavailable"|>,
    !FileExistsQ[path],
    Module[{},
      Quiet @ Check[
        (If[!DirectoryQ[DirectoryName[path]], CreateDirectory[DirectoryName[path]]];
         Export[path, <|"Fingerprints" -> cur,
           "KeyId" -> $SourceVaultAnonymizeKeyId,
           "PinnedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>, "RawJSON"]),
        Null];
      $iSVAFpVerdict = If[FileExistsQ[path],
        <|"Status" -> "Pinned", "Path" -> path|>,
        <|"Status" -> "Skipped", "Reason" -> "PinWriteFailed"|>]],
    True,
    Module[{},
      rec = Quiet @ Check[Import[path, "RawJSON"], $Failed];
      pinned = If[AssociationQ[rec], Lookup[rec, "Fingerprints", <||>], $Failed];
      If[!AssociationQ[pinned],
        (* 読めない pin は安全側: 検証不能として ID 生成を止める *)
        $iSVAFpVerdict = <|"Status" -> "Failed", "Reason" -> "PinUnreadable", "Path" -> path|>,
        mismatches = Select[Keys[cur],
          StringQ[Lookup[pinned, #]] && Lookup[pinned, #] =!= cur[#] &];
        $iSVAFpVerdict = If[mismatches === {},
          Module[{newKeys = Select[Keys[cur], !StringQ[Lookup[pinned, #]] &]},
            (* 新設鍵 (例: grant 鍵の追加) は既存 pin と矛盾しないので追記する *)
            If[newKeys =!= {},
              Quiet @ Check[Export[path,
                <|"Fingerprints" -> Join[pinned, KeyTake[cur, newKeys]],
                  "KeyId" -> $SourceVaultAnonymizeKeyId,
                  "PinnedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>,
                "RawJSON"], Null]];
            <|"Status" -> "OK", "Path" -> path,
              "NewlyPinnedKeyRefs" -> newKeys|>],
          <|"Status" -> "Failed", "Reason" -> "KeyFingerprintMismatch",
            "MismatchedKeyRefs" -> mismatches,
            "Expected" -> KeyTake[pinned, mismatches],
            "Actual" -> KeyTake[cur, mismatches], "Path" -> path|>]]]];
  $iSVAFpVerdict];

(* ============================================================
   2. CanonicalEncode v1 (仕様 §5.5.1)
   決定論・順序非依存 (Association キーはコードポイント順ソート)。
   fail-closed: Real / 未知型 / 非文字列キーは $Failed。
   ============================================================ *)

SourceVaultAnonymizeCanonicalEncode::badtype =
  "CanonicalEncode v1 cannot encode expression of head `1` (fail-closed). Use String/Integer/Boolean/ByteArray/List/Association.";

iSVAEscapeString[s_String] := Module[{nfc},
  nfc = Quiet @ Check[CharacterNormalize[s, "NFC"], s];
  StringJoin[
    Map[
      Function[c,
        With[{cc = First[ToCharacterCode[c, "Unicode"]]},
          Which[
            c === "\"", "\\\"",
            c === "\\", "\\\\",
            cc < 32, "\\u" <> IntegerString[cc, 16, 4],
            True, c]]],
      Characters[nfc]]]];

iSVAEnc[s_String] := "\"" <> iSVAEscapeString[s] <> "\"";
iSVAEnc[i_Integer] := ToString[i];
iSVAEnc[True] := "true";
iSVAEnc[False] := "false";
iSVAEnc[Null] := "null";
iSVAEnc[ba_ByteArray] :=
  "\"hex:" <> StringJoin[IntegerString[#, 16, 2] & /@ Normal[ba]] <> "\"";
iSVAEnc[l_List] := Module[{parts = iSVAEnc /@ l},
  If[MemberQ[parts, $Failed], $Failed, "[" <> StringRiffle[parts, ","] <> "]"]];

(* 厳密コードポイント辞書式比較。SortBy[ToCharacterCode] はリスト比較が
   長さ優先になるため使えない (["ba"] が ["l"] より後になる) *)
iSVACpLess[a_String, b_String] := Catch @ Module[
  {ca = ToCharacterCode[a, "Unicode"], cb = ToCharacterCode[b, "Unicode"], n},
  n = Min[Length[ca], Length[cb]];
  Do[If[ca[[i]] != cb[[i]], Throw[ca[[i]] < cb[[i]]]], {i, n}];
  Length[ca] < Length[cb]];

iSVAEnc[a_Association] := Module[{keys, pairs},
  keys = Keys[a];
  If[!AllTrue[keys, StringQ], Return[$Failed]];
  keys = Sort[keys, iSVACpLess];
  pairs = Map[
    Function[k, With[{v = iSVAEnc[a[k]]},
      If[v === $Failed, $Failed, iSVAEnc[k] <> ":" <> v]]], keys];
  If[MemberQ[pairs, $Failed], $Failed, "{" <> StringRiffle[pairs, ","] <> "}"]];
iSVAEnc[x_] := (Message[SourceVaultAnonymizeCanonicalEncode::badtype, Head[x]]; $Failed);

SourceVaultAnonymizeCanonicalEncode[expr_] := iSVAEnc[expr];

iSVASHA256Hex[s_String] :=
  IntegerString[Hash[StringToByteArray[s, "UTF-8"], "SHA256"], 16, 64];

SourceVaultAnonymizeCanonicalDigest[expr_] := Module[{enc = iSVAEnc[expr]},
  If[enc === $Failed, $Failed, iSVASHA256Hex[enc]]];

(* ============================================================
   3. ID 式 (仕様 §5.5.2)
   ID = prefix <> ":" <> HMAC(key, CanonicalEncode[payload])[;;40]
   payload は record (Association) -- 平行配列を作らない (P-A19)。
   ============================================================ *)

$iSVAIDHexLength = 40;  (* 160bit。KeyRing メタの TruncationLength に相当 *)

iSVAHmacHex[keyRef_String, payload_Association] := Module[{enc, mac},
  If[!iSVANBCryptoQ[], Return[$Failed]];
  If[!iSVABackendOKQ[], Return[$Failed]];  (* 揮発鍵での ID 発行禁止 *)
  If[!iSVAKeyExistsQ[keyRef], Return[$Failed]];
  (* fingerprint 検査 (プロセス内キャッシュ)。不一致 = 別鍵カーネル -> ID 生成拒否 *)
  If[!AssociationQ[$iSVAFpVerdict], SourceVaultAnonymizeVerifyKeyFingerprints[]];
  If[AssociationQ[$iSVAFpVerdict] && $iSVAFpVerdict["Status"] === "Failed",
    Return[$Failed]];
  enc = iSVAEnc[payload];
  If[enc === $Failed, Return[$Failed]];
  mac = Quiet @ Check[
    NBAccess`NBMacWithKeyRef[keyRef, StringToByteArray[enc, "UTF-8"], "anonymize-id"],
    $Failed];
  If[!StringQ[mac], Return[$Failed]];
  StringTake[ToLowerCase[mac], UpTo[$iSVAIDHexLength]]];

iSVAID[prefix_String, keyRef_String, payload_Association] :=
  Module[{h = iSVAHmacHex[keyRef, payload]},
    If[h === $Failed, $Failed, prefix <> ":" <> h]];

(* 必須キー検査 (fail-closed)。値は String 必須 (digest / kind / id はすべて文字列規約) *)
iSVARequire[spec_Association, keys_List] :=
  AllTrue[keys, StringQ[Lookup[spec, #, $Failed]] &];

SourceVaultAnonymizeEntityID[spec_Association] :=
  If[!iSVARequire[spec, {"Institution", "CanonicalID"}], $Failed,
    iSVAID["ent", $SourceVaultAnonymizeIdentityKeyRef,
      <|"VaultOrTenantID" -> $SourceVaultAnonymizeTenantID,
        "Institution" -> spec["Institution"],
        "CanonicalID" -> spec["CanonicalID"],
        "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion,
        "KeyId" -> $SourceVaultAnonymizeKeyId|>]];

SourceVaultAnonymizeSourceObjectID[spec_Association] :=
  If[!iSVARequire[spec, {"SourceSystem", "PrimaryKey"}], $Failed,
    iSVAID["sobj", $SourceVaultAnonymizeIdentityKeyRef,
      <|"VaultOrTenantID" -> $SourceVaultAnonymizeTenantID,
        "SourceSystem" -> spec["SourceSystem"],
        "PrimaryKey" -> spec["PrimaryKey"],
        "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion,
        "KeyId" -> $SourceVaultAnonymizeKeyId|>]];

SourceVaultAnonymizeSourceUnitID[spec_Association] :=
  If[!iSVARequire[spec,
      {"SourceObjectID", "SourceVersionID", "SourceUnitKind",
       "CanonicalLocatorDigest", "SourceContentDigest"}], $Failed,
    iSVAID["sunit", $SourceVaultAnonymizeLineageKeyRef,
      <|"VaultOrTenantID" -> $SourceVaultAnonymizeTenantID,
        "SourceObjectID" -> spec["SourceObjectID"],
        "SourceVersionID" -> spec["SourceVersionID"],
        "SourceUnitKind" -> spec["SourceUnitKind"],
        "CanonicalLocatorDigest" -> spec["CanonicalLocatorDigest"],
        "SourceContentDigest" -> spec["SourceContentDigest"],
        "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion,
        "LineageSchemaVersion" -> $SourceVaultAnonymizeLineageSchemaVersion,
        "KeyId" -> $SourceVaultAnonymizeKeyId|>]];

SourceVaultAnonymizeDerivedUnitID[spec_Association] := Module[{parents},
  parents = Lookup[spec, "ParentUnitIDs", $Failed];
  If[!(ListQ[parents] && Length[parents] >= 1 && AllTrue[parents, StringQ]),
    Return[$Failed]];
  If[!iSVARequire[spec,
      {"RelationType", "PolicyDigest", "TransformDigest",
       "DerivedLocatorDigest", "DerivedContentDigest", "OutputOrdinalOrRole"}],
    Return[$Failed]];
  iSVAID["dunit", $SourceVaultAnonymizeLineageKeyRef,
    <|"VaultOrTenantID" -> $SourceVaultAnonymizeTenantID,
      "SortedParentUnitIDs" -> Sort[parents],
      "RelationType" -> spec["RelationType"],
      "PolicyDigest" -> spec["PolicyDigest"],
      "TransformDigest" -> spec["TransformDigest"],
      "DerivedLocatorDigest" -> spec["DerivedLocatorDigest"],
      "DerivedContentDigest" -> spec["DerivedContentDigest"],
      "OutputOrdinalOrRole" -> spec["OutputOrdinalOrRole"],
      "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion,
      "KeyId" -> $SourceVaultAnonymizeKeyId|>]];

(* ============================================================
   4. token / ReleaseHandle (仕様 §5.5.3, §5.10)
   CSPRNG: GenerateSymmetricKey (暗号乱数) 由来。RandomInteger は使わない。
   ============================================================ *)

$iSVATokenAlphabet = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"]; (* Crockford base32 *)
$iSVATokenPrefixes = <|"Subject" -> "S", "Item" -> "I", "Job" -> "J", "ResultSlot" -> "R"|>;
$iSVATokenBodyLength = 6;

iSVARandomBytes[n_Integer?Positive] := Module[{out = {}},
  While[Length[out] < n,
    out = Join[out,
      Normal[Quiet @ Check[GenerateSymmetricKey[]["Key"], ByteArray[{}]]]];
    If[out === {}, Return[$Failed]]];
  Take[out, n]];

iSVAChecksumChar[bodyChars_List] :=
  $iSVATokenAlphabet[[
    Mod[Total[(First[FirstPosition[$iSVATokenAlphabet, #]] - 1) & /@ bodyChars], 32] + 1]];

SourceVaultAnonymizeGenerateToken[type_String] := Module[{prefix, bytes, body},
  prefix = Lookup[$iSVATokenPrefixes, type, $Failed];
  If[prefix === $Failed, Return[$Failed]];
  bytes = iSVARandomBytes[$iSVATokenBodyLength];
  If[bytes === $Failed, Return[$Failed]];
  body = $iSVATokenAlphabet[[Mod[#, 32] + 1]] & /@ bytes;
  prefix <> "-" <> StringJoin[body] <> "-" <> iSVAChecksumChar[body]];

SourceVaultAnonymizeTokenValidQ[token_String] := Module[{parts, prefix, body, chk},
  parts = StringSplit[token, "-"];
  If[Length[parts] =!= 3, Return[False]];
  {prefix, body, chk} = parts;
  If[!MemberQ[Values[$iSVATokenPrefixes], prefix], Return[False]];
  If[StringLength[body] =!= $iSVATokenBodyLength || StringLength[chk] =!= 1, Return[False]];
  If[!AllTrue[Characters[body], MemberQ[$iSVATokenAlphabet, #] &], Return[False]];
  chk === iSVAChecksumChar[Characters[body]]];
SourceVaultAnonymizeTokenValidQ[___] := False;

SourceVaultAnonymizeGenerateReleaseHandle[] := Module[{bytes},
  bytes = iSVARandomBytes[32];
  If[bytes === $Failed, Return[$Failed]];
  "sv://release/" <> StringJoin[IntegerString[#, 16, 2] & /@ bytes]];

SourceVaultAnonymizeReleaseHandleValidQ[h_String] :=
  StringMatchQ[h, "sv://release/" ~~ Repeated[HexadecimalCharacter, {64}]] &&
  ToLowerCase[StringDrop[h, 13]] === StringDrop[h, 13];
SourceVaultAnonymizeReleaseHandleValidQ[___] := False;

(* ============================================================
   4b. L0b: LineageManifest node/edge graph + validator (仕様 §5.4, §5.7, §9.2)
   多対一 (複数ページ -> 一答案) を Edges の Cardinality で正準表現する。
   低 PL 側に出るのは DerivedNodes の ItemToken のみという契約の正本。
   ============================================================ *)

iSVALinSetDigest[ids_List] := SourceVaultAnonymizeCanonicalDigest[Sort[ids]];
iSVALinOriginSetDigest[origins_List] :=
  SourceVaultAnonymizeCanonicalDigest[SortBy[origins, Lookup[#, "OriginRef", ""] &]];
iSVALinManifestDigest[m_Association] :=
  SourceVaultAnonymizeCanonicalDigest[KeyDrop[m, "ManifestDigest"]];

iSVALinFinding[check_String, detail_] := <|"Check" -> check, "Detail" -> detail|>;

SourceVaultAnonymizeBuildLineageManifest[spec_Association] :=
  Module[{origins, srcNodes, derNodes, edges, parts, inv, core, m, val},
    origins = Lookup[spec, "Origins", {}];
    srcNodes = Lookup[spec, "SourceNodes", {}];
    derNodes = Lookup[spec, "DerivedNodes", {}];
    edges = Lookup[spec, "Edges", {}];
    parts = Lookup[spec, "Partitions", {}];
    If[!(ListQ[origins] && origins =!= {} && AllTrue[origins, AssociationQ] &&
         ListQ[srcNodes] && ListQ[derNodes] && ListQ[edges] && ListQ[parts]),
      Return[<|"Status" -> "Failed", "Reason" -> "MalformedSpec"|>]];
    (* Edge の set digest と EdgeID、Partition の MemberSetDigest と PartitionID を計算 *)
    edges = Map[Function[e, Module[{e2 = e},
        e2["InputSetDigest"] = iSVALinSetDigest[Lookup[e, "FromUnitIDs", {}]];
        e2["OutputSetDigest"] = iSVALinSetDigest[Lookup[e, "ToUnitIDs", {}]];
        If[!StringQ[Lookup[e2, "EdgeID"]],
          e2["EdgeID"] = "edge:" <> StringTake[
            SourceVaultAnonymizeCanonicalDigest[KeyDrop[e2, "EdgeID"]], 16]];
        e2]], edges];
    parts = Map[Function[p, Module[{p2 = p},
        p2["MemberSetDigest"] = iSVALinSetDigest[Lookup[p, "MemberUnitIDs", {}]];
        If[!KeyExistsQ[p2, "Excluded"], p2["Excluded"] = {}];
        If[!StringQ[Lookup[p2, "PartitionID"]],
          p2["PartitionID"] = "part:" <> StringTake[
            SourceVaultAnonymizeCanonicalDigest[KeyDrop[p2, "PartitionID"]], 16]];
        p2]], parts];
    inv = Join[<|"DuplicatePolicy" -> "Reject", "OrderingIsIdentity" -> False,
        "ExpectedSourceNodeCount" -> Length[srcNodes],
        "ExpectedDerivedNodeCount" -> Length[derNodes]|>,
      Lookup[spec, "Invariants", <||>]];
    core = <|
      "ObjectClass" -> "LineageManifest",
      "SchemaVersion" -> 2,
      "Origins" -> origins,
      "OriginSetDigest" -> iSVALinOriginSetDigest[origins],
      "PolicyRef" -> Lookup[spec, "PolicyRef", "unspecified"],
      "MapRef" -> Lookup[spec, "MapRef", "unspecified"],
      "KeyId" -> $SourceVaultAnonymizeKeyId,
      "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion,
      "SourceNodes" -> srcNodes, "DerivedNodes" -> derNodes,
      "Edges" -> edges, "Partitions" -> parts,
      "Invariants" -> inv|>;
    With[{dg = SourceVaultAnonymizeCanonicalDigest[core]},
      If[!StringQ[dg],
        Return[<|"Status" -> "Failed", "Reason" -> "NonCanonicalContent"|>]];
      core["LineageSetID"] = "lin:" <> StringTake[dg, 32]];
    m = Append[core, "ManifestDigest" -> iSVALinManifestDigest[core]];
    val = SourceVaultValidateLineage[m];
    If[Lookup[val, "Status"] =!= "OK",
      Return[<|"Status" -> "Failed", "Reason" -> "SelfValidationFailed",
        "Findings" -> Lookup[val, "Findings", {}]|>]];
    Append[m, "Status" -> "OK"]];

SourceVaultValidateLineage[m_Association] :=
  Module[{fs = {}, srcNodes, derNodes, edges, parts, srcIDs, derIDs, allIDs,
      itemToks, dup, allMembers, covered, excludedAll, uncovered, expS, expD},
    If[Lookup[m, "SchemaVersion"] =!= 2,
      AppendTo[fs, iSVALinFinding["SchemaVersion", Lookup[m, "SchemaVersion", "missing"]]]];
    Scan[If[!KeyExistsQ[m, #], AppendTo[fs, iSVALinFinding["MissingKey", #]]] &,
      {"Origins", "OriginSetDigest", "SourceNodes", "DerivedNodes",
       "Edges", "Partitions", "Invariants", "ManifestDigest"}];
    If[fs =!= {}, Return[<|"Status" -> "Failed", "Findings" -> fs|>]];
    srcNodes = m["SourceNodes"]; derNodes = m["DerivedNodes"];
    edges = m["Edges"]; parts = m["Partitions"];
    srcIDs = Lookup[#, "UnitID", ""] & /@ srcNodes;
    derIDs = Lookup[#, "UnitID", ""] & /@ derNodes;
    allIDs = Join[srcIDs, derIDs];
    (* id 形式・一意性 *)
    If[!AllTrue[srcIDs, StringStartsQ[#, "sunit:"] &],
      AppendTo[fs, iSVALinFinding["BadSourceUnitIDPrefix",
        Select[srcIDs, !StringStartsQ[#, "sunit:"] &]]]];
    If[!AllTrue[derIDs, StringStartsQ[#, "dunit:"] &],
      AppendTo[fs, iSVALinFinding["BadDerivedUnitIDPrefix",
        Select[derIDs, !StringStartsQ[#, "dunit:"] &]]]];
    dup = Keys[Select[Counts[allIDs], # > 1 &]];
    If[dup =!= {}, AppendTo[fs, iSVALinFinding["DuplicateUnitID", dup]]];
    (* ItemToken: 全 derived に存在・一意・checksum 妥当 (L2 の正本 / AC-044 の基礎) *)
    itemToks = Lookup[#, "ItemToken", $Failed] & /@ derNodes;
    If[!AllTrue[itemToks, StringQ[#] && SourceVaultAnonymizeTokenValidQ[#] &&
          StringStartsQ[#, "I-"] &],
      AppendTo[fs, iSVALinFinding["InvalidItemToken",
        Length[Select[itemToks, !(StringQ[#] && SourceVaultAnonymizeTokenValidQ[#]) &]]]]];
    dup = Keys[Select[Counts[Select[itemToks, StringQ]], # > 1 &]];
    If[dup =!= {}, AppendTo[fs, iSVALinFinding["DuplicateItemToken", dup]]];
    (* Edges: unknown 参照・cardinality・set digest *)
    Scan[Function[e, Module[{from = Lookup[e, "FromUnitIDs", {}], to = Lookup[e, "ToUnitIDs", {}], card},
        Scan[If[!MemberQ[allIDs, #],
            AppendTo[fs, iSVALinFinding["UnknownUnitInEdge",
              <|"EdgeID" -> Lookup[e, "EdgeID", "?"], "UnitID" -> #|>]]] &,
          Join[from, to]];
        If[!MemberQ[derIDs, #] && MemberQ[to, #],
          Null] & /@ to;  (* To は derived のみ許可 *)
        Scan[If[!MemberQ[derIDs, #],
            AppendTo[fs, iSVALinFinding["EdgeTargetNotDerived",
              <|"EdgeID" -> Lookup[e, "EdgeID", "?"], "UnitID" -> #|>]]] &, to];
        card = Lookup[e, "Cardinality", "N:M"];
        If[!MatchQ[card, "1:1" | "1:N" | "N:1" | "N:M"],
          AppendTo[fs, iSVALinFinding["BadCardinality", card]]];
        If[(card === "1:1" && (Length[from] =!= 1 || Length[to] =!= 1)) ||
           (card === "1:N" && Length[from] =!= 1) ||
           (card === "N:1" && Length[to] =!= 1),
          AppendTo[fs, iSVALinFinding["CardinalityMismatch",
            <|"EdgeID" -> Lookup[e, "EdgeID", "?"], "Cardinality" -> card,
              "FromCount" -> Length[from], "ToCount" -> Length[to]|>]]];
        If[Lookup[e, "InputSetDigest"] =!= iSVALinSetDigest[from] ||
           Lookup[e, "OutputSetDigest"] =!= iSVALinSetDigest[to],
          AppendTo[fs, iSVALinFinding["EdgeSetDigestMismatch", Lookup[e, "EdgeID", "?"]]]]]],
      edges];
    (* Partitions: unknown member・member set digest・重複禁止・coverage *)
    allMembers = {};
    Scan[Function[p, Module[{mem = Lookup[p, "MemberUnitIDs", {}]},
        Scan[If[!MemberQ[allIDs, #],
            AppendTo[fs, iSVALinFinding["UnknownUnitInPartition",
              <|"PartitionID" -> Lookup[p, "PartitionID", "?"], "UnitID" -> #|>]]] &, mem];
        If[Lookup[p, "MemberSetDigest"] =!= iSVALinSetDigest[mem],
          AppendTo[fs, iSVALinFinding["MemberSetDigestMismatch",
            Lookup[p, "PartitionID", "?"]]]];
        If[Lookup[p, "Coverage", "DeclaredSubset"] === "Complete" &&
           Sort[Join[mem, Lookup[#, "UnitID", ""] & /@ Lookup[p, "Excluded", {}]]] =!=
             Sort[derIDs],
          AppendTo[fs, iSVALinFinding["IncompletePartitionCoverage",
            Lookup[p, "PartitionID", "?"]]]];
        allMembers = Join[allMembers, mem]]],
      parts];
    If[Lookup[m["Invariants"], "DuplicatePolicy", "Reject"] === "Reject",
      dup = Keys[Select[Counts[allMembers], # > 1 &]];
      If[dup =!= {}, AppendTo[fs, iSVALinFinding["DuplicatePartitionMember", dup]]]];
    (* 全体 coverage: 各 SourceNode は >=1 edge の From に現れるか、いずれかの Excluded *)
    covered = DeleteDuplicates[Flatten[Lookup[#, "FromUnitIDs", {}] & /@ edges]];
    excludedAll = DeleteDuplicates[Flatten[
      Map[Lookup[#, "UnitID", ""] &, Lookup[#, "Excluded", {}]] & /@ parts]];
    uncovered = Select[srcIDs, !MemberQ[covered, #] && !MemberQ[excludedAll, #] &];
    If[uncovered =!= {},
      AppendTo[fs, iSVALinFinding["UncoveredSourceUnit", uncovered]]];
    (* counts / digests *)
    expS = Lookup[m["Invariants"], "ExpectedSourceNodeCount", Length[srcNodes]];
    expD = Lookup[m["Invariants"], "ExpectedDerivedNodeCount", Length[derNodes]];
    If[expS =!= Length[srcNodes] || expD =!= Length[derNodes],
      AppendTo[fs, iSVALinFinding["NodeCountMismatch",
        <|"ExpectedSource" -> expS, "ActualSource" -> Length[srcNodes],
          "ExpectedDerived" -> expD, "ActualDerived" -> Length[derNodes]|>]]];
    If[m["OriginSetDigest"] =!= iSVALinOriginSetDigest[m["Origins"]],
      AppendTo[fs, iSVALinFinding["OriginSetDigestMismatch", "recompute differs"]]];
    If[m["ManifestDigest"] =!= iSVALinManifestDigest[KeyDrop[m, "Status"]],
      AppendTo[fs, iSVALinFinding["ManifestDigestMismatch", "recompute differs"]]];
    <|"Status" -> If[fs === {}, "OK", "Failed"], "Findings" -> fs,
      "Counts" -> <|"SourceNodes" -> Length[srcNodes],
        "DerivedNodes" -> Length[derNodes],
        "Edges" -> Length[edges], "Partitions" -> Length[parts]|>|>];

(* ============================================================
   5. G0a: schema-only AnonymizationPlan (仕様 §7.1, §8.1 段 0a の材料)
   本文非読の保証: 参照するのは (a) ref 文字列のパース、(b) snapshot privacy
   sidecar (SourceVaultSnapshotPrivacyLevel -- 本体と別ファイル) のみ。
   payload / blob / source meta / 対応表には一切触れない。
   ============================================================ *)

(* ref パーサ (自前・純関数)。SourceVaultParseURI (mcp.wl) 未ロードでも動く *)
iSVAParseRef[ref_String] := Module[{s = StringTrim[ref]},
  Which[
    StringMatchQ[s, "snapshot:" ~~ __ ~~ ":" ~~ __],
    Module[{parts = StringSplit[s, ":"]},
      If[Length[parts] == 3 && StringMatchQ[parts[[3]], Repeated[HexadecimalCharacter, {8, 128}]],
        <|"Valid" -> True, "RefForm" -> "SnapshotRef", "Namespace" -> "snapshot",
          "ObjectClass" -> parts[[2]], "Id" -> parts[[3]],
          "CanonicalRef" -> "snapshot:" <> parts[[2]] <> ":" <> ToLowerCase[parts[[3]]]|>,
        <|"Valid" -> False, "Reason" -> "MalformedSnapshotRef", "Input" -> s|>]],
    StringMatchQ[s, "sv://snapshot/" ~~ __ ~~ "/" ~~ __],
    Module[{parts = StringSplit[StringDrop[s, StringLength["sv://snapshot/"]], "/"]},
      If[Length[parts] == 2,
        iSVAParseRef["snapshot:" <> parts[[1]] <> ":" <> parts[[2]]],
        <|"Valid" -> False, "Reason" -> "MalformedSnapshotURI", "Input" -> s|>]],
    StringMatchQ[s, "sv://hash/sha256/" ~~ Repeated[HexadecimalCharacter, {64}]],
    <|"Valid" -> True, "RefForm" -> "HashURI", "Namespace" -> "hash",
      "ObjectClass" -> Missing["BinaryContent"],
      "Id" -> ToLowerCase[StringDrop[s, StringLength["sv://hash/sha256/"]]],
      "CanonicalRef" -> ToLowerCase[s]|>,
    StringMatchQ[s, "blob:sha256:" ~~ Repeated[HexadecimalCharacter, {64}]],
    iSVAParseRef["sv://hash/sha256/" <> StringDrop[s, StringLength["blob:sha256:"]]],
    StringMatchQ[s, "sv://" ~~ __ ~~ "/" ~~ __],
    Module[{rest = StringDrop[s, 5], parts},
      parts = StringSplit[rest, "/"];
      <|"Valid" -> True, "RefForm" -> "GenericURI", "Namespace" -> First[parts],
        "ObjectClass" -> Missing["SchemaOnly"],
        "Id" -> StringRiffle[Rest[parts], "/"], "CanonicalRef" -> s|>],
    True,
    <|"Valid" -> False, "Reason" -> "UnrecognizedRefForm", "Input" -> s|>]];

(* privacy sidecar のみ読む PL 取得 (本文非読)。取得不能は fail-closed 0.85 *)
iSVASchemaOnlyPL[parsed_Association] := Module[{ref, pl},
  If[Lookup[parsed, "RefForm", ""] =!= "SnapshotRef",
    Return[<|"PrivacyLevel" -> 0.85, "PrivacyLevelSource" -> "FailClosedDefault"|>]];
  ref = parsed["CanonicalRef"];
  pl = If[Names["SourceVault`SourceVaultSnapshotPrivacyLevel"] =!= {},
    Quiet @ Check[SourceVault`SourceVaultSnapshotPrivacyLevel[ref], $Failed],
    $Failed];
  Which[
    NumericQ[pl], <|"PrivacyLevel" -> N[pl], "PrivacyLevelSource" -> "SidecarOrDefault"|>,
    AssociationQ[pl] && NumericQ[Lookup[pl, "PrivacyLevel"]],
    <|"PrivacyLevel" -> N[pl["PrivacyLevel"]], "PrivacyLevelSource" -> "SidecarOrDefault"|>,
    True, <|"PrivacyLevel" -> 0.85, "PrivacyLevelSource" -> "FailClosedDefault"|>]];

iSVAPlanOriginRecord[ref_String, role_String] := Module[{parsed, plInfo},
  parsed = iSVAParseRef[ref];
  If[!TrueQ[parsed["Valid"]],
    Return[<|"Valid" -> False, "OriginRef" -> ref,
      "Reason" -> Lookup[parsed, "Reason", "ParseFailed"]|>]];
  plInfo = iSVASchemaOnlyPL[parsed];
  <|"Valid" -> True,
    "OriginRef" -> parsed["CanonicalRef"],
    "RefForm" -> parsed["RefForm"],
    "ObjectClass" -> Lookup[parsed, "ObjectClass", Missing["SchemaOnly"]],
    "Role" -> role,
    "PrivacyLevel" -> plInfo["PrivacyLevel"],
    "PrivacyLevelSource" -> plInfo["PrivacyLevelSource"]|>];

(* Origins の canonical sort + digest (P-A19)。Missing は encode 不能なので文字列化 *)
iSVAOriginDigestRecord[rec_Association] :=
  <|"OriginRef" -> rec["OriginRef"],
    "ObjectClass" -> If[StringQ[rec["ObjectClass"]], rec["ObjectClass"], "unknown"],
    "Role" -> rec["Role"]|>;

Options[SourceVaultAnonymizationPlan] = {"Save" -> False};

SourceVaultAnonymizationPlan[origRef_String, opts : OptionsPattern[]] :=
  SourceVaultAnonymizationPlan[{origRef}, opts];

SourceVaultAnonymizationPlan[origRefs_List, OptionsPattern[]] :=
  Module[{records, invalid, sortedDigestRecs, originSetDigest, core, planDigest, plan, saveRes},
    If[origRefs === {} || !AllTrue[origRefs, StringQ],
      Return[<|"Status" -> "Failed", "Reason" -> "EmptyOrNonStringOrigins"|>]];
    (* Role は位置から自動生成しない (位置依存 Role は set digest の順序不変性を壊す)。
       意味的 Role (submission-pdf / roster 等) は record 形式入力を受ける将来増分で束縛する *)
    records = iSVAPlanOriginRecord[#, "origin"] & /@ origRefs;
    invalid = Select[records, !TrueQ[#["Valid"]] &];
    If[invalid =!= {},
      Return[<|"Status" -> "Failed", "Reason" -> "InvalidOriginRef",
        "Invalid" -> invalid|>]];
    records = KeyDrop[#, "Valid"] & /@ records;
    sortedDigestRecs = SortBy[iSVAOriginDigestRecord /@ records, #["OriginRef"] &];
    originSetDigest = SourceVaultAnonymizeCanonicalDigest[sortedDigestRecs];
    core = <|
      "Type" -> "AnonymizationPlan",
      "SchemaVersion" -> 1,
      "SchemaOnly" -> True,
      "Origins" -> records,
      "OriginSetDigest" -> originSetDigest,
      "UnitCountRange" -> "SchemaOnly",
      "TargetLevelChoices" -> {"0.45", "0.2"},
      "SinkChoices" -> {"CloudLLM", "CloudLLM-LowTrust"},
      "CandidatePolicies" -> iSVAAvailablePolicies[],
      "CandidateProfiles" -> {},
      "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion,
      "EngineVersion" -> $SourceVaultAnonymizeEngineVersion|>;
    planDigest = SourceVaultAnonymizeCanonicalDigest[
      <|"Origins" -> sortedDigestRecs,
        "OriginSetDigest" -> originSetDigest,
        "SchemaVersion" -> 1,
        "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion,
        "EngineVersion" -> $SourceVaultAnonymizeEngineVersion|>];
    plan = Join[core,
      <|"Status" -> "OK",
        "PlanDigest" -> planDigest,
        "CreatedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>];
    If[TrueQ[OptionValue["Save"]],
      saveRes = If[Names["SourceVault`SourceVaultSaveImmutableSnapshot"] =!= {},
        Quiet @ Check[
          SourceVault`SourceVaultSaveImmutableSnapshot["AnonymizationPlan", plan],
          $Failed],
        $Failed];
      plan = Append[plan, "PlanRef" ->
        If[AssociationQ[saveRes], Lookup[saveRes, "Ref", Lookup[saveRes, "SnapshotRef", $Failed]],
          saveRes]]];
    plan];

(* ============================================================
   6. G0b: DeclassificationGrant + 承認 + execution lease
   (仕様 §5.13, §8.1 段 0a, §10 / AC-060〜064, AC-088)
   - 発行はオーナー対話環境 (FrontEnd) のみ。本ヘッドは NBAccess 承認ゲートにも
     登録され、agent/LLM 経由の評価は Hold -> Approve UI を通る (自己承認防止)。
   - grant は exact な origin/policy/target/purpose/sink/期限/uses を焼き込み、
     専用 MAC 鍵で封印する。検証は本文非読 (段 0a)。
   - use は lease ファイル (create-only) で消費し、同一 OperationID の retry は
     冪等に再開する。
   ============================================================ *)

If[!ValueQ[$iSVAGrantTestMode], $iSVAGrantTestMode = False];  (* テスト専用 (非公開) *)
If[!ValueQ[$iSVALeaseDirOverride], $iSVALeaseDirOverride = Automatic];

iSVAInteractiveOwnerQ[] :=
  TrueQ[$iSVAGrantTestMode] ||
  (! TrueQ[$CloudEvaluation] && Head[$FrontEnd] === FrontEndObject);

iSVARandomHex[nBytes_Integer] := Module[{b = iSVARandomBytes[nBytes]},
  If[b === $Failed, $Failed, StringJoin[IntegerString[#, 16, 2] & /@ b]]];

iSVALeaseDir[] := Which[
  StringQ[$iSVALeaseDirOverride], $iSVALeaseDirOverride,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r], FileNameJoin[{r, "config", "anonymize-leases"}], $Failed]],
  True, $Failed];

Options[SourceVaultRequestDeclassification] = {
  "TargetLevel" -> None, "Purpose" -> None, "IntendedSink" -> None,
  "PolicyRef" -> "unspecified", "PolicyDigest" -> "unspecified",
  "PublishMode" -> "StageForOwnerReview",
  "MaxExecuteUses" -> 1, "TTLSeconds" -> 86400};

SourceVaultRequestDeclassification[plan_Association, OptionsPattern[]] :=
  Module[{tl, purpose, sink},
    If[Lookup[plan, "Status"] =!= "OK" || Lookup[plan, "SchemaOnly"] =!= True ||
       !StringQ[Lookup[plan, "PlanDigest"]],
      Return[<|"Status" -> "Failed", "Reason" -> "InvalidPlan"|>]];
    tl = OptionValue["TargetLevel"]; purpose = OptionValue["Purpose"];
    sink = OptionValue["IntendedSink"];
    (* オーナーの exact 指定必須 -- システム既定を自動採用しない (仕様 §4.2/G2) *)
    If[!MemberQ[Lookup[plan, "TargetLevelChoices", {}], tl],
      Return[<|"Status" -> "Failed", "Reason" -> "TargetLevelNotChosen",
        "Choices" -> Lookup[plan, "TargetLevelChoices", {}]|>]];
    If[!StringQ[purpose],
      Return[<|"Status" -> "Failed", "Reason" -> "PurposeNotChosen"|>]];
    If[!(AssociationQ[sink] && StringQ[Lookup[sink, "Class"]]),
      Return[<|"Status" -> "Failed", "Reason" -> "IntendedSinkNotChosen"|>]];
    <|"ObjectClass" -> "DeclassificationRequest", "SchemaVersion" -> 1,
      "Status" -> "OK",
      "RequestID" -> "declass-req:" <> iSVARandomHex[8],
      "PlanDigest" -> plan["PlanDigest"],
      (* grant が pin するのは ref/class/role。数値 PL は canonical encode 不可
         (Real fail-closed) かつ informational なので落とす *)
      "Origins" -> (KeyDrop[#, {"PrivacyLevel", "PrivacyLevelSource"}] & /@
        Lookup[plan, "Origins", {}]),
      "OriginSetDigest" -> Lookup[plan, "OriginSetDigest", "missing"],
      "TargetLevel" -> tl, "Purpose" -> purpose, "IntendedSink" -> sink,
      "PolicyRef" -> OptionValue["PolicyRef"],
      "PolicyDigest" -> OptionValue["PolicyDigest"],
      "PublishMode" -> OptionValue["PublishMode"],
      "MaxExecuteUses" -> OptionValue["MaxExecuteUses"],
      "TTLSeconds" -> OptionValue["TTLSeconds"],
      "CreatedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>];

SourceVaultApproveDeclassification[request_Association] :=
  Module[{core, digest, mac, nonce},
    If[Lookup[request, "ObjectClass"] =!= "DeclassificationRequest" ||
       Lookup[request, "Status"] =!= "OK",
      Return[<|"Status" -> "Failed", "Reason" -> "InvalidRequest"|>]];
    If[!iSVAInteractiveOwnerQ[],
      Return[<|"Status" -> "Failed", "Reason" -> "NonInteractiveApprovalRefused",
        "Hint" -> "Approval must run in the owner's interactive FrontEnd session."|>]];
    If[!iSVABackendOKQ[], Return[iSVAVolatileBackendFailure[]]];
    If[!iSVAKeyExistsQ[$iSVAGrantKeyRef],
      Return[<|"Status" -> "Failed", "Reason" -> "GrantKeyMissing",
        "Hint" -> "Run SourceVaultAnonymizeInitializeKeys[] first."|>]];
    (* fingerprint gate: pin 不一致状態 (別鍵カーネル/鍵消失) では grant を発行しない *)
    With[{fp = SourceVaultAnonymizeVerifyKeyFingerprints[]},
      If[fp["Status"] === "Failed",
        Return[<|"Status" -> "Failed", "Reason" -> "KeyFingerprintGateFailed",
          "Detail" -> fp|>]]];
    nonce = iSVARandomHex[16];
    If[nonce === $Failed, Return[<|"Status" -> "Failed", "Reason" -> "RandomUnavailable"|>]];
    core = <|"ObjectClass" -> "DeclassificationGrant", "SchemaVersion" -> 1,
      "GrantID" -> "declass-grant:" <> iSVARandomHex[8],
      "OwnerPrincipal" -> ToString[$Username],
      "ApprovalReceipt" -> <|
        "Environment" -> If[TrueQ[$iSVAGrantTestMode], "TestMode", "FrontEnd"],
        "AtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>,
      "PlanDigest" -> request["PlanDigest"],
      "Origins" -> request["Origins"],
      "OriginSetDigest" -> request["OriginSetDigest"],
      "ExactTargetLevel" -> request["TargetLevel"],
      "Purpose" -> request["Purpose"],
      "IntendedSink" -> request["IntendedSink"],
      "PolicyRef" -> request["PolicyRef"], "PolicyDigest" -> request["PolicyDigest"],
      "PublishMode" -> request["PublishMode"],
      "MaxUses" -> <|"Execute" -> request["MaxExecuteUses"]|>,
      "ExpiresAtUnix" -> UnixTime[Now] + Lookup[request, "TTLSeconds", 86400],
      "Nonce" -> nonce,
      "KeyId" -> $SourceVaultAnonymizeKeyId,
      "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion|>;
    digest = SourceVaultAnonymizeCanonicalDigest[core];
    If[!StringQ[digest],
      Return[<|"Status" -> "Failed", "Reason" -> "NonCanonicalGrant"|>]];
    mac = Quiet @ Check[NBAccess`NBMacWithKeyRef[$iSVAGrantKeyRef,
      StringToByteArray[digest, "UTF-8"], "declass-grant"], $Failed];
    If[!StringQ[mac], Return[<|"Status" -> "Failed", "Reason" -> "MACFailed"|>]];
    Join[core, <|"GrantDigest" -> digest, "OwnerMAC" -> mac, "Status" -> "OK"|>]];

iSVAGrantMACValidQ[grant_Association] := Module[{core, digest, mac},
  core = KeyDrop[grant, {"GrantDigest", "OwnerMAC", "Status"}];
  digest = SourceVaultAnonymizeCanonicalDigest[core];
  If[!StringQ[digest] || digest =!= Lookup[grant, "GrantDigest"], Return[False]];
  mac = Quiet @ Check[NBAccess`NBMacWithKeyRef[$iSVAGrantKeyRef,
    StringToByteArray[digest, "UTF-8"], "declass-grant"], $Failed];
  If[!StringQ[mac], Return[False]];
  If[Names["SourceVault`SourceVaultConstantTimeEqualQ"] =!= {},
    TrueQ[SourceVault`SourceVaultConstantTimeEqualQ[mac, Lookup[grant, "OwnerMAC", ""]]],
    mac === Lookup[grant, "OwnerMAC", ""]]];

SourceVaultVerifyDeclassificationGrant[grant_Association, request_Association] :=
  Module[{},
    If[Lookup[grant, "ObjectClass"] =!= "DeclassificationGrant",
      Return[<|"Status" -> "Failed", "Reason" -> "NotAGrant"|>]];
    If[!iSVAGrantMACValidQ[grant],
      Return[<|"Status" -> "Failed", "Reason" -> "GrantMACInvalid"|>]];
    If[Lookup[grant, "ExpiresAtUnix", 0] < UnixTime[Now],
      Return[<|"Status" -> "Failed", "Reason" -> "GrantExpired"|>]];
    If[Lookup[request, "TargetLevel"] =!= Lookup[grant, "ExactTargetLevel"],
      Return[<|"Status" -> "Failed", "Reason" -> "DeclassificationTargetMismatch",
        "GrantLevel" -> grant["ExactTargetLevel"],
        "RequestedLevel" -> Lookup[request, "TargetLevel"]|>]];
    Module[{field = SelectFirst[
        {"OriginSetDigest", "Purpose", "PolicyDigest"},
        Lookup[request, #] =!= Lookup[grant, #] &, None]},
      If[field =!= None,
        Return[<|"Status" -> "Failed", "Reason" -> "GrantRequestMismatch",
          "Field" -> field|>]]];
    If[Lookup[Lookup[request, "IntendedSink", <||>], "Class"] =!=
       Lookup[Lookup[grant, "IntendedSink", <||>], "Class"],
      Return[<|"Status" -> "Failed", "Reason" -> "GrantRequestMismatch",
        "Field" -> "IntendedSink"|>]];
    <|"Status" -> "OK", "GrantID" -> grant["GrantID"],
      "PublishMode" -> grant["PublishMode"]|>];

SourceVaultConsumeDeclassificationGrantUse[grant_Association, operationId_String] :=
  Module[{dir, gdir, useFiles, existing, maxUses, path},
    With[{fp = If[AssociationQ[$iSVAFpVerdict], $iSVAFpVerdict,
        SourceVaultAnonymizeVerifyKeyFingerprints[]]},
      If[fp["Status"] === "Failed",
        Return[<|"Status" -> "Failed", "Reason" -> "KeyFingerprintGateFailed",
          "Detail" -> fp|>]]];
    If[!iSVAGrantMACValidQ[grant],
      Return[<|"Status" -> "Failed", "Reason" -> "GrantMACInvalid"|>]];
    If[Lookup[grant, "ExpiresAtUnix", 0] < UnixTime[Now],
      Return[<|"Status" -> "Failed", "Reason" -> "GrantExpired"|>]];
    dir = iSVALeaseDir[];
    If[dir === $Failed,
      Return[<|"Status" -> "Failed", "Reason" -> "LeaseStoreUnavailable"|>]];
    gdir = FileNameJoin[{dir, StringReplace[grant["GrantID"], ":" -> "_"]}];
    Quiet @ Check[If[!DirectoryQ[gdir], CreateDirectory[gdir]], Null];
    If[!DirectoryQ[gdir],
      Return[<|"Status" -> "Failed", "Reason" -> "LeaseStoreUnavailable"|>]];
    useFiles = FileNames["use-*.json", gdir];
    existing = SelectFirst[useFiles,
      Quiet @ Check[
        Lookup[Import[#, "RawJSON"], "OperationID", ""] === operationId, False] &,
      None];
    If[existing =!= None,
      Return[<|"Status" -> "OK", "Resumed" -> True,
        "GrantID" -> grant["GrantID"], "OperationID" -> operationId|>]];
    maxUses = Lookup[Lookup[grant, "MaxUses", <||>], "Execute", 1];
    If[Length[useFiles] >= maxUses,
      Return[<|"Status" -> "Failed", "Reason" -> "GrantUsesExhausted",
        "MaxUses" -> maxUses|>]];
    path = FileNameJoin[{gdir, "use-" <> iSVASHA256Hex[operationId] <> ".json"}];
    If[FileExistsQ[path],
      Return[<|"Status" -> "OK", "Resumed" -> True,
        "GrantID" -> grant["GrantID"], "OperationID" -> operationId|>]];
    Quiet @ Check[Export[path,
      <|"OperationID" -> operationId, "GrantID" -> grant["GrantID"],
        "ReservedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>,
      "RawJSON"], Null];
    If[!FileExistsQ[path],
      Return[<|"Status" -> "Failed", "Reason" -> "LeaseWriteFailed"|>]];
    <|"Status" -> "OK", "Resumed" -> False,
      "GrantID" -> grant["GrantID"], "OperationID" -> operationId|>];

(* ============================================================
   6b. L1: PseudonymMap -- MapId / 不変 MapVersion / MapHead CAS (仕様 §5.3)
   - MapVersion は core の不変 snapshot (class "PseudonymMap"、PL 1.0 sidecar)。
   - MapHead はファイル pointer (PrivateVault/config/anonymize-map-heads/)。
     更新は lock + compare-and-swap。競合はリトライ (二重割当 0 件 = AC-028)。
   - 成果物・annotation は exact MapRef を pin する (head が進んでも逆写像不変 = AC-029)。
   ============================================================ *)

$iSVATokenSchemeVersion = 1;
If[!ValueQ[$iSVAMapHeadDirOverride], $iSVAMapHeadDirOverride = Automatic];

iSVAMapHeadDir[] := Which[
  StringQ[$iSVAMapHeadDirOverride], $iSVAMapHeadDirOverride,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r], FileNameJoin[{r, "config", "anonymize-map-heads"}], $Failed]],
  True, $Failed];

SourceVaultAnonymizePseudonymMapId[spec_Association] :=
  If[!iSVARequire[spec, {"EntityClass", "MapScope"}], $Failed,
    With[{dg = SourceVaultAnonymizeCanonicalDigest[
        <|"VaultOrTenantID" -> $SourceVaultAnonymizeTenantID,
          "EntityClass" -> spec["EntityClass"],
          "NormalizedMapScope" -> spec["MapScope"],
          "TokenSchemeVersion" -> $iSVATokenSchemeVersion,
          "IdentityKeyId" -> $SourceVaultAnonymizeKeyId,
          "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion|>]},
      If[StringQ[dg], "map:" <> StringTake[dg, 32], $Failed]]];

iSVAMapIdFile[mapId_String] := With[{dir = iSVAMapHeadDir[]},
  If[dir === $Failed, $Failed,
    FileNameJoin[{dir, StringReplace[mapId, ":" -> "_"] <> ".json"}]]];

iSVAMapHeadRead[mapId_String] := Module[{path = iSVAMapIdFile[mapId], rec},
  If[path === $Failed || !FileExistsQ[path], Return[None]];
  rec = Quiet @ Check[Import[path, "RawJSON"], $Failed];
  If[AssociationQ[rec] && StringQ[Lookup[rec, "MapRef"]], rec["MapRef"], None]];

iSVAMapHeadCAS[mapId_String, expectedRef_, newRef_String] :=
  Module[{path = iSVAMapIdFile[mapId], cur},
    If[path === $Failed, Return[False]];
    cur = iSVAMapHeadRead[mapId];
    If[cur =!= expectedRef, Return[False]];
    Quiet @ Check[
      (If[!DirectoryQ[DirectoryName[path]], CreateDirectory[DirectoryName[path]]];
       Export[path, <|"MapId" -> mapId, "MapRef" -> newRef,
         "UpdatedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>,
        "RawJSON"]; True), False]];

(* 排他 lock (best-effort ファイルロック。stale 15s で奪取) *)
iSVAWithMapLock[mapId_String, body_] := Module[{dir, lockPath, got = False, r},
  dir = iSVAMapHeadDir[];
  If[dir === $Failed, Return[$Failed]];
  Quiet @ Check[If[!DirectoryQ[dir], CreateDirectory[dir]], Null];
  lockPath = FileNameJoin[{dir, StringReplace[mapId, ":" -> "_"] <> ".lock"}];
  Do[
    If[!FileExistsQ[lockPath] ||
       Quiet @ Check[
         UnixTime[Now] - UnixTime[FileDate[lockPath, "Modification"]] > 15, True],
      Quiet @ Check[Export[lockPath, <|"PID" -> $ProcessID|>, "RawJSON"], Null];
      got = True; Break[]];
    Pause[0.1], {20}];
  If[!got, Return[$Failed]];
  r = body[];
  Quiet @ Check[DeleteFile[lockPath], Null];
  r];

(* core のロードは管理フィールド (SnapshotClass/Digest/StoredAtUTC) を注入する。
   digest 再計算 (BindingDigest/ManifestDigest 検証) を壊すので一律 strip する *)
$iSVASnapshotAdminKeys = {"SnapshotClass", "Digest", "StoredAtUTC"};
iSVAMapLoadByRef[ref_String] :=
  If[Names["SourceVault`SourceVaultLoadImmutableSnapshot"] === {}, $Failed,
    With[{m = Quiet @ Check[SourceVault`SourceVaultLoadImmutableSnapshot[ref], $Failed]},
      If[AssociationQ[m], KeyDrop[m, $iSVASnapshotAdminKeys], m]]];

(* KnownStrings の決定論的表記ゆれ展開: 原文 / 空白除去 / 全角英数字の半角化 *)
iSVAHalfWidth[s_String] := StringJoin[Map[
  Function[c, With[{cc = First[ToCharacterCode[c, "Unicode"]]},
    Which[
      65296 <= cc <= 65305, FromCharacterCode[cc - 65248],  (* 0-9 *)
      65313 <= cc <= 65338, FromCharacterCode[cc - 65248],  (* A-Z *)
      65345 <= cc <= 65370, FromCharacterCode[cc - 65248],  (* a-z *)
      cc === 12288, " ",                                     (* 全角空白 *)
      True, c]]], Characters[s]]];

iSVAExpandKnownStrings[strs_List] := DeleteDuplicates[Flatten[Map[
  Function[s, Module[{nfc = Quiet @ Check[CharacterNormalize[s, "NFC"], s], hw},
    hw = iSVAHalfWidth[nfc];
    {nfc, hw, StringDelete[nfc, WhitespaceCharacter],
     StringDelete[hw, WhitespaceCharacter]}]],
  Select[strs, StringQ[#] && StringLength[#] > 0 &]]]];

iSVAMapSetPL[ref_String] :=
  If[Names["SourceVault`SourceVaultSetImmutableSnapshotPrivacyLevel"] =!= {},
    Quiet @ Check[
      SourceVault`SourceVaultSetImmutableSnapshotPrivacyLevel[ref, 1.0], Null], Null];

SourceVaultAnonymizeAssignSubjectTokens[mapSpec_Association, identities_List] :=
  Module[{mapId, result},
    mapId = SourceVaultAnonymizePseudonymMapId[mapSpec];
    If[mapId === $Failed,
      Return[<|"Status" -> "Failed", "Reason" -> "InvalidMapSpec"|>]];
    If[Names["SourceVault`SourceVaultSaveImmutableSnapshot"] === {},
      Return[<|"Status" -> "Failed", "Reason" -> "CoreUnavailable"|>]];
    If[identities === {} || !AllTrue[identities, AssociationQ],
      Return[<|"Status" -> "Failed", "Reason" -> "EmptyIdentities"|>]];
    (* NOTE: Do 内の Return は Do を抜けるだけで Module の後続が評価される
       (WL の既知の罠)。Break + 後判定で明示制御する *)
    result = $Failed;
    Do[
      result = iSVAWithMapLock[mapId, Function[iSVAAssignUnderLock[mapId, mapSpec, identities]]];
      If[result === $Failed || Lookup[result, "Status"] =!= "CASConflict", Break[]],
      {3}];
    Which[
      result === $Failed,
      <|"Status" -> "Failed", "Reason" -> "LockUnavailable"|>,
      Lookup[result, "Status"] === "CASConflict",
      <|"Status" -> "Failed", "Reason" -> "CASRetriesExhausted"|>,
      True, result]];

iSVAAssignUnderLock[mapId_String, mapSpec_Association, identities_List] :=
  Catch[iSVAAssignUnderLockBody[mapId, mapSpec, identities], "svaAssign"];

iSVAAssignUnderLockBody[mapId_String, mapSpec_Association, identities_List] :=
  Module[{headRef, prev, entries, byEntity, assignments = <||>, changed = False,
      rec, saved, newRef, version, usedTokens},
    headRef = iSVAMapHeadRead[mapId];
    prev = If[StringQ[headRef], iSVAMapLoadByRef[headRef], None];
    entries = If[AssociationQ[prev], Lookup[prev, "Entries", {}], {}];
    version = If[AssociationQ[prev], Lookup[prev, "MapVersion", 0], 0] + 1;
    byEntity = Association[(Lookup[#, "EntityID", ""] -> #) & /@ entries];
    usedTokens = Lookup[#, "SubjectToken", ""] & /@ entries;
    Scan[Function[ident, Module[{eid, entry, tok, label, known},
      eid = SourceVaultAnonymizeEntityID[
        KeyTake[ident, {"Institution", "CanonicalID"}]];
      If[eid === $Failed, Throw[<|"Status" -> "Failed",
        "Reason" -> "EntityIDFailed"|>, "svaAssign"]];
      known = iSVAExpandKnownStrings[Join[
        Lookup[ident, "KnownStrings", {}],
        Select[Values[Lookup[ident, "Identity", <||>]], StringQ]]];
      If[KeyExistsQ[byEntity, eid],
        entry = byEntity[eid];
        (* 既存実体: token 安定。KnownStrings は追記 merge *)
        With[{merged = DeleteDuplicates[Join[Lookup[entry, "KnownStrings", {}], known]]},
          If[merged =!= Lookup[entry, "KnownStrings", {}],
            byEntity[eid] = Append[entry, "KnownStrings" -> merged]; changed = True]];
        assignments[eid] = <|"SubjectToken" -> entry["SubjectToken"],
          "DisplayLabel" -> Lookup[entry, "DisplayLabel", ""], "New" -> False|>,
        (* 新実体: 採番 *)
        tok = SourceVaultAnonymizeGenerateToken["Subject"];
        If[tok === $Failed || MemberQ[usedTokens, tok],
          Throw[<|"Status" -> "Failed", "Reason" -> "TokenGenerationFailed"|>, "svaAssign"]];
        AppendTo[usedTokens, tok];
        label = "S-" <> IntegerString[Length[byEntity] + 1, 10, 3];
        byEntity[eid] = <|"EntityID" -> eid,
          "EntityClass" -> mapSpec["EntityClass"],
          "SubjectToken" -> tok, "DisplayLabel" -> label,
          "Identity" -> Lookup[ident, "Identity", <||>],
          "KnownStrings" -> known|>;
        changed = True;
        assignments[eid] = <|"SubjectToken" -> tok, "DisplayLabel" -> label,
          "New" -> True|>]]],
      identities];
    (* 変更なしなら新 version を作らない (冪等) *)
    If[!changed,
      Return[<|"Status" -> "OK", "MapId" -> mapId, "MapRef" -> headRef,
        "MapVersion" -> version - 1, "Assignments" -> assignments,
        "NewVersion" -> False|>]];
    entries = Values[byEntity];
    (* uniqueness 検査 (MapId, EntityID) / (MapId, SubjectToken) *)
    If[Length[DeleteDuplicates[Lookup[#, "EntityID"] & /@ entries]] =!= Length[entries] ||
       Length[DeleteDuplicates[Lookup[#, "SubjectToken"] & /@ entries]] =!= Length[entries],
      Return[<|"Status" -> "Failed", "Reason" -> "UniquenessViolation"|>]];
    rec = <|"ObjectClass" -> "PseudonymMap", "SchemaVersion" -> 1,
      "MapId" -> mapId, "MapVersion" -> version,
      "ParentMapRef" -> If[StringQ[headRef], headRef, "none"],
      "MapScope" -> mapSpec["MapScope"],
      "EntityClass" -> mapSpec["EntityClass"],
      "KeyId" -> $SourceVaultAnonymizeKeyId,
      "TokenSchemeVersion" -> $iSVATokenSchemeVersion,
      "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion,
      "CreatedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z",
      "Entries" -> entries|>;
    saved = Quiet @ Check[
      SourceVault`SourceVaultSaveImmutableSnapshot["PseudonymMap", rec], $Failed];
    newRef = If[AssociationQ[saved],
      Lookup[saved, "Ref", Lookup[saved, "SnapshotRef", $Failed]], $Failed];
    If[!StringQ[newRef],
      Return[<|"Status" -> "Failed", "Reason" -> "SnapshotSaveFailed"|>]];
    iSVAMapSetPL[newRef];
    If[!TrueQ[iSVAMapHeadCAS[mapId, headRef, newRef]],
      Return[<|"Status" -> "CASConflict"|>]];
    <|"Status" -> "OK", "MapId" -> mapId, "MapRef" -> newRef,
      "MapVersion" -> version, "Assignments" -> assignments, "NewVersion" -> True|>];

SourceVaultAnonymizePseudonymMap[mapIdOrRef_String] := Module[{ref, m},
  ref = If[StringStartsQ[mapIdOrRef, "map:"],
    iSVAMapHeadRead[mapIdOrRef], mapIdOrRef];
  If[!StringQ[ref],
    Return[<|"Status" -> "Failed", "Reason" -> "MapHeadNotFound"|>]];
  m = iSVAMapLoadByRef[ref];
  If[!AssociationQ[m],
    Return[<|"Status" -> "Failed", "Reason" -> "MapVersionUnreadable"|>]];
  (* PL 1.0 の透かし (privacy 層ロード時のみ。値は変えない) *)
  If[Names["SourceVault`SourceVaultNotePrivacy"] =!= {},
    Quiet @ Check[SourceVault`SourceVaultNotePrivacy[1.0], Null]];
  Append[m, "MapRef" -> ref]];

(* ============================================================
   6c. L2a: content-addressed builder + ArtifactBinding + 逆引き
   (仕様 §5.6, AC-047/049/051 の基盤)
   - builder: 成果物本体は volatile field (CreatedAtUTC 等) を含めない。
     core の content-addressed snapshot 保存により同一 content -> 同一 ref (冪等)。
     本体は公開状態 (Status) を持たない (正本は PublicationHead = L2b)。
   - ArtifactBinding: PL 1.0 の不変 snapshot。一方向 pin (binding -> artifact)。
   - 逆引き index: HMAC(origin ref) をファイル名キーに binding refs を append。
     origin を知る principal だけが導出できる (unlisted と整合)。
   ============================================================ *)

$iSVAVolatileArtifactKeys = {"CreatedAtUTC", "Status", "PublicationState", "ReleaseHandle"};
If[!ValueQ[$iSVABindingIndexDirOverride], $iSVABindingIndexDirOverride = Automatic];

iSVABindingIndexDir[] := Which[
  StringQ[$iSVABindingIndexDirOverride], $iSVABindingIndexDirOverride,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r], FileNameJoin[{r, "config", "anonymize-binding-index"}], $Failed]],
  True, $Failed];

(* 内部 builder (仕様 §16.1: Internal 非 export)。Publish パイプライン (L2b) が使う *)
iSVASaveContentAddressedDerivedArtifact[artifact_Association] := Module[{core, saved, ref},
  If[Names["SourceVault`SourceVaultSaveImmutableSnapshot"] === {},
    Return[<|"Status" -> "Failed", "Reason" -> "CoreUnavailable"|>]];
  (* volatile field は本体に含めない (同一 content -> 同一 ref を壊すため拒否) *)
  With[{bad = Intersection[Keys[artifact], $iSVAVolatileArtifactKeys]},
    If[bad =!= {},
      Return[<|"Status" -> "Failed", "Reason" -> "VolatileFieldInArtifact",
        "Fields" -> bad|>]]];
  If[!(KeyExistsQ[artifact, "Payload"] || KeyExistsQ[artifact, "Text"] ||
       StringQ[Lookup[Lookup[artifact, "Content", <||>], "BlobRef"]]),
    Return[<|"Status" -> "Failed", "Reason" -> "NoContent"|>]];
  If[!StringQ[Lookup[artifact, "PayloadDigest"]],
    Return[<|"Status" -> "Failed", "Reason" -> "PayloadDigestMissing"|>]];
  core = Join[<|"ObjectClass" -> "DerivedArtifact", "ArtifactType" -> "Anonymized",
    "ArtifactSchemaVersion" -> 2, "Discoverability" -> "Unlisted"|>, artifact];
  saved = Quiet @ Check[
    SourceVault`SourceVaultSaveImmutableSnapshot["DerivedArtifact", core], $Failed];
  ref = If[AssociationQ[saved],
    Lookup[saved, "Ref", Lookup[saved, "SnapshotRef", $Failed]], $Failed];
  If[!StringQ[ref], Return[<|"Status" -> "Failed", "Reason" -> "SnapshotSaveFailed"|>]];
  <|"Status" -> "OK", "ArtifactRef" -> ref,
    "ArtifactDigest" -> Last[StringSplit[ref, ":"]],
    "Existed" -> TrueQ[Lookup[saved, "Existed", False]]|>];

(* ArtifactBinding 保存 (PL 1.0)。一方向 pin: binding -> artifact のみ *)
iSVASaveArtifactBinding[artifactRef_String, spec_Association] :=
  Module[{origins, rec, dg, saved, ref, dgFull},
    origins = Lookup[spec, "Origins", {}];
    If[!(ListQ[origins] && origins =!= {} && AllTrue[origins, AssociationQ]),
      Return[<|"Status" -> "Failed", "Reason" -> "OriginsMissing"|>]];
    rec = <|"ObjectClass" -> "ArtifactBinding", "SchemaVersion" -> 1,
      "ArtifactRef" -> artifactRef,
      "ArtifactDigest" -> Last[StringSplit[artifactRef, ":"]],
      "Origins" -> origins,
      "OriginSetDigest" -> iSVALinOriginSetDigest[origins],
      "PolicyRef" -> Lookup[spec, "PolicyRef", "unspecified"],
      "MapRef" -> Lookup[spec, "MapRef", "unspecified"],
      "LineageManifestRef" -> Lookup[spec, "LineageManifestRef", "unspecified"],
      "ProfileRef" -> Lookup[spec, "ProfileRef", "unspecified"],
      "KeyId" -> $SourceVaultAnonymizeKeyId,
      "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion,
      "SourceRefs" -> (Lookup[#, "OriginRef", ""] & /@ origins)|>;
    dg = SourceVaultAnonymizeCanonicalDigest[rec];
    If[!StringQ[dg], Return[<|"Status" -> "Failed", "Reason" -> "NonCanonicalBinding"|>]];
    rec = Append[rec, "BindingDigest" -> dg];
    saved = Quiet @ Check[
      SourceVault`SourceVaultSaveImmutableSnapshot["ArtifactBinding", rec], $Failed];
    ref = If[AssociationQ[saved],
      Lookup[saved, "Ref", Lookup[saved, "SnapshotRef", $Failed]], $Failed];
    If[!StringQ[ref], Return[<|"Status" -> "Failed", "Reason" -> "SnapshotSaveFailed"|>]];
    iSVAMapSetPL[ref];
    (* origin 逆引き index へ append (キー = HMAC(canonical origin ref)) *)
    Scan[Function[org, iSVABindingIndexAppend[Lookup[org, "OriginRef", ""], ref]],
      origins];
    <|"Status" -> "OK", "BindingRef" -> ref, "BindingDigest" -> dg|>];

iSVABindingIndexAppend[originRef_String, bindingRef_String] := Module[{dir, key, path, cur},
  dir = iSVABindingIndexDir[];
  If[dir === $Failed || originRef === "", Return[Null]];
  key = iSVAHandleDigest[originRef];  (* keyed HMAC (grant 鍵) *)
  If[key === $Failed, Return[Null]];
  Quiet @ Check[If[!DirectoryQ[dir], CreateDirectory[dir]], Null];
  path = FileNameJoin[{dir, StringTake[key, 40] <> ".json"}];
  cur = If[FileExistsQ[path],
    Quiet @ Check[Import[path, "RawJSON"], {}], {}];
  If[!ListQ[cur], cur = {}];
  If[!MemberQ[cur, bindingRef],
    Quiet @ Check[Export[path, Append[cur, bindingRef], "RawJSON"], Null]];
  Null];

iSVAVerifyArtifactBinding[binding_Association] :=
  StringQ[Lookup[binding, "BindingDigest"]] &&
  SourceVaultAnonymizeCanonicalDigest[KeyDrop[binding, "BindingDigest"]] ===
    binding["BindingDigest"];

SourceVaultAnonymizedVariants[origRefOrURI_String] := Module[
    {parsed, canonical, dir, key, path, refs, out},
  parsed = iSVAParseRef[origRefOrURI];
  canonical = If[TrueQ[Lookup[parsed, "Valid", False]],
    parsed["CanonicalRef"], origRefOrURI];
  dir = iSVABindingIndexDir[];
  If[dir === $Failed,
    Return[<|"Status" -> "Failed", "Reason" -> "BindingIndexUnavailable"|>]];
  key = iSVAHandleDigest[canonical];
  If[key === $Failed,
    Return[<|"Status" -> "Failed", "Reason" -> "DigestUnavailable"|>]];
  path = FileNameJoin[{dir, StringTake[key, 40] <> ".json"}];
  refs = If[FileExistsQ[path],
    Quiet @ Check[Import[path, "RawJSON"], {}], {}];
  If[!ListQ[refs], refs = {}];
  out = Map[Function[bref, Module[{b = iSVAMapLoadByRef[bref]},
      If[!AssociationQ[b], Nothing,
        If[!iSVAVerifyArtifactBinding[b], Nothing,
          <|"BindingRef" -> bref, "ArtifactRef" -> b["ArtifactRef"],
            "PolicyRef" -> b["PolicyRef"], "MapRef" -> b["MapRef"],
            "LineageManifestRef" -> b["LineageManifestRef"]|>]]]],
    refs];
  If[Names["SourceVault`SourceVaultNotePrivacy"] =!= {},
    Quiet @ Check[SourceVault`SourceVaultNotePrivacy[1.0], Null]];
  <|"Status" -> "OK", "OriginRef" -> canonical, "Variants" -> out|>];

(* ============================================================
   6d. L2b: PublicationRecord / PublicationHead + 二相 publish
   (仕様 §5.10, §8.2, §10.4 / AC-030, AC-047, AC-048)
   - 公開状態の正本は PublicationHead ただ一つ。head 更新は CAS。
   - 順序: staged 検証 -> durable PublicationPrepared event -> head CAS ->
     PL sidecar 設定 -> best-effort Completed event -> ReleaseHandle 発行。
     どの点で crash しても観測状態は「未公開」または「公開済み+sidecar 未設定
     (= 既存 gate でも出ない安全側)」。再実行は冪等に再開する。
   - crash injection: $iSVAPublishCrashPoint (テスト専用) が各点で Throw する。
   ============================================================ *)

If[!ValueQ[$iSVAPubHeadDirOverride], $iSVAPubHeadDirOverride = Automatic];
If[!ValueQ[$iSVAPubEventPathOverride], $iSVAPubEventPathOverride = Automatic];
If[!ValueQ[$iSVAPublishCrashPoint], $iSVAPublishCrashPoint = None];

iSVAPubHeadDir[] := Which[
  StringQ[$iSVAPubHeadDirOverride], $iSVAPubHeadDirOverride,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r], FileNameJoin[{r, "config", "anonymize-publication-heads"}], $Failed]],
  True, $Failed];

iSVAPubEventPath[] := Which[
  StringQ[$iSVAPubEventPathOverride], $iSVAPubEventPathOverride,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r], FileNameJoin[{r, "config", "anonymize-publication-events.jsonl"}],
      $Failed]],
  True, $Failed];

(* durable event 追記 (自前 JSONL が正本。core イベントへは弱結合 emit)。
   追記できなければ False (publish は fail-closed で中断する) *)
iSVAPubEventAppend[ev_Association] := Module[{path = iSVAPubEventPath[], strm, ok = False},
  If[path === $Failed, Return[False]];
  Quiet @ Check[
    (If[!DirectoryQ[DirectoryName[path]], CreateDirectory[DirectoryName[path]]];
     strm = OpenAppend[path, BinaryFormat -> True];
     If[Head[strm] === OutputStream,
       BinaryWrite[strm, StringToByteArray[
         ExportString[ev, "RawJSON", "Compact" -> True] <> "\n", "UTF-8"]];
       Close[strm]; ok = True]), Null];
  If[ok && Names["SourceVault`SourceVaultAppendEvent"] =!= {},
    Quiet @ Check[SourceVault`SourceVaultAppendEvent[ev], Null]];
  ok];

iSVAPubHeadFile[artifactRef_String] := With[{dir = iSVAPubHeadDir[]},
  If[dir === $Failed, $Failed,
    FileNameJoin[{dir, StringTake[Last[StringSplit[artifactRef, ":"]], 40] <> ".json"}]]];

iSVAPubHeadRead[artifactRef_String] := Module[{path = iSVAPubHeadFile[artifactRef], rec},
  If[path === $Failed || !FileExistsQ[path], Return[None]];
  rec = Quiet @ Check[Import[path, "RawJSON"], $Failed];
  If[AssociationQ[rec] && StringQ[Lookup[rec, "PublicationRef"]],
    rec["PublicationRef"], None]];

iSVAPubHeadCAS[artifactRef_String, expectedRef_, newRef_String] :=
  Module[{path = iSVAPubHeadFile[artifactRef]},
    If[path === $Failed, Return[False]];
    If[iSVAPubHeadRead[artifactRef] =!= expectedRef, Return[False]];
    Quiet @ Check[
      (If[!DirectoryQ[DirectoryName[path]], CreateDirectory[DirectoryName[path]]];
       Export[path, <|"ArtifactRef" -> artifactRef, "PublicationRef" -> newRef,
         "UpdatedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>,
        "RawJSON"]; True), False]];

iSVACrash[point_String] :=
  If[$iSVAPublishCrashPoint === point,
    Throw[<|"Status" -> "Crashed", "At" -> point|>, "svaPublish"]];

(* 内部 publish (仕様 §10.3: 唯一の公開経路。非 export)。冪等再開可能 *)
iSVAPublishDeclassifiedArtifact[spec_Association] :=
  Catch[iSVAPublishBody[spec], "svaPublish"];

iSVAPublishBody[spec_Association] := Module[
    {artifactRef, bindingRef, binding, targetLevel, rec, saved, pubRef,
     prevHead, issued, tl},
  artifactRef = Lookup[spec, "ArtifactRef", $Failed];
  bindingRef = Lookup[spec, "BindingRef", $Failed];
  targetLevel = Lookup[spec, "TargetLevel", $Failed];
  If[!StringQ[artifactRef] || !StringQ[bindingRef] || !StringQ[targetLevel],
    Return[<|"Status" -> "Failed", "Reason" -> "MissingPublishFields"|>]];
  tl = Quiet @ Check[ToExpression[targetLevel], $Failed];
  If[!NumericQ[tl] || tl <= 0 || tl >= 1,
    Return[<|"Status" -> "Failed", "Reason" -> "BadTargetLevel"|>]];
  (* staged 検証: binding 実在・digest・artifact との一方向 pin 一致 *)
  binding = iSVAMapLoadByRef[bindingRef];
  If[!AssociationQ[binding] || !iSVAVerifyArtifactBinding[binding] ||
     binding["ArtifactRef"] =!= artifactRef,
    Return[<|"Status" -> "Failed", "Reason" -> "BindingIntegrityFailed"|>]];
  prevHead = iSVAPubHeadRead[artifactRef];
  (* 冪等再開: 既に Published なら sidecar 設定と handle 発行だけ確認する *)
  If[StringQ[prevHead],
    With[{prevRec = iSVAMapLoadByRef[prevHead]},
      If[AssociationQ[prevRec] && Lookup[prevRec, "State"] === "Published" &&
         Lookup[prevRec, "ArtifactRef"] === artifactRef,
        iSVAMapSetTargetPL[artifactRef, tl];
        Return[<|"Status" -> "OK", "PublicationRef" -> prevHead,
          "Resumed" -> True, "ArtifactRef" -> artifactRef|>]]]];
  rec = <|"ObjectClass" -> "DeclassificationPublication", "SchemaVersion" -> 1,
    "PublicationID" -> "pub:" <> iSVARandomHex[8],
    "ArtifactRef" -> artifactRef,
    "ArtifactDigest" -> Last[StringSplit[artifactRef, ":"]],
    "ArtifactBindingRef" -> bindingRef,
    "BindingDigest" -> binding["BindingDigest"],
    "VerifyReportDigest" -> Lookup[spec, "VerifyReportDigest", "unspecified"],
    "ProfileRef" -> Lookup[spec, "ProfileRef", "unspecified"],
    "ExecutionGrantID" -> Lookup[spec, "GrantID", "unspecified"],
    "TargetLevel" -> targetLevel,
    "Discoverability" -> "Unlisted",
    "State" -> "Published",
    "PreviousPublicationRef" -> If[StringQ[prevHead], prevHead, "none"],
    "RevocationEpoch" -> 0,
    "PublishedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>;
  saved = Quiet @ Check[
    SourceVault`SourceVaultSaveImmutableSnapshot["DeclassificationPublication", rec],
    $Failed];
  pubRef = If[AssociationQ[saved],
    Lookup[saved, "Ref", Lookup[saved, "SnapshotRef", $Failed]], $Failed];
  If[!StringQ[pubRef], Return[<|"Status" -> "Failed", "Reason" -> "RecordSaveFailed"|>]];
  iSVACrash["AfterRecordSave"];
  (* durable Prepared event -- 書けなければ publish しない (P-A7) *)
  If[!iSVAPubEventAppend[<|"EventClass" -> "AnonymizePublicationPrepared",
      "PublicationRef" -> pubRef, "ArtifactRefDigest" -> iSVAHandleDigest[artifactRef],
      "TargetLevel" -> targetLevel,
      "AtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>],
    Return[<|"Status" -> "Failed", "Reason" -> "AuditUnavailable"|>]];
  iSVACrash["AfterPrepared"];
  (* 公開の唯一の決定点: head CAS *)
  If[!TrueQ[iSVAPubHeadCAS[artifactRef, prevHead, pubRef]],
    Return[<|"Status" -> "Failed", "Reason" -> "HeadCASConflict"|>]];
  iSVACrash["AfterCAS"];
  (* PL sidecar は CAS 後 (crash しても「公開済み+高 PL のまま」= 安全側) *)
  iSVAMapSetTargetPL[artifactRef, tl];
  iSVACrash["AfterSidecar"];
  iSVAPubEventAppend[<|"EventClass" -> "AnonymizePublicationCompleted",
    "PublicationRef" -> pubRef,
    "AtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>];
  issued = iSVAIssueReleaseHandle[artifactRef, pubRef];
  <|"Status" -> "OK", "PublicationRef" -> pubRef, "Resumed" -> False,
    "ArtifactRef" -> artifactRef,
    "ReleaseHandle" -> If[issued["Status"] === "OK", issued["ReleaseHandle"],
      Missing["HandleIssueFailed"]]|>];

iSVAMapSetTargetPL[ref_String, lv_?NumericQ] :=
  If[Names["SourceVault`SourceVaultSetImmutableSnapshotPrivacyLevel"] =!= {},
    Quiet @ Check[
      SourceVault`SourceVaultSetImmutableSnapshotPrivacyLevel[ref, N[lv]], Null], Null];

$iSVAUnlistedClasses = {"AnnotationContent", "AnnotationBinding", "CloudTransportResult",
  "PseudonymMap", "LineageManifest", "ArtifactBinding", "DeclassificationPublication",
  "EvaluationPlanManifest", "EvaluationResultManifest", "CerezoGradingProjection",
  "AnonymizationPlan", "DeclassificationGrant"};

SourceVaultAnonymizeUnlistedClassQ[source_Association] :=
  Lookup[source, "Discoverability", ""] === "Unlisted" ||
  MemberQ[$iSVAUnlistedClasses, Lookup[source, "ObjectClass", ""]] ||
  (Lookup[source, "ObjectClass", ""] === "DerivedArtifact" &&
   Lookup[source, "ArtifactType", ""] === "Anonymized");
SourceVaultAnonymizeUnlistedClassQ[___] := False;

SourceVaultAnonymizeGetByHandle[releaseHandle_String] := Module[{res, st, art},
  res = SourceVaultResolveReleaseHandle[releaseHandle];
  If[Lookup[res, "Status"] =!= "OK",
    Return[<|"Status" -> "Failed", "Reason" -> "HandleInvalid"|>]];
  (* Published head の再確認 (Revoke 後は publication が Revoked だが handle 側も
     失効しているはず。二重防御で head も見る) *)
  st = SourceVaultAnonymizePublicationStatus[res["ArtifactRef"]];
  If[Lookup[st, "State"] =!= "Published",
    Return[<|"Status" -> "Failed", "Reason" -> "NotPublished"|>]];
  art = iSVAMapLoadByRef[res["ArtifactRef"]];
  If[!AssociationQ[art],
    Return[<|"Status" -> "Failed", "Reason" -> "ArtifactUnreadable"|>]];
  (* 低 PL projection: 系譜参照は artifact 本体に無い (一方向 pin)。Payload/Format/TL のみ *)
  <|"Status" -> "OK", "ArtifactRef" -> res["ArtifactRef"],
    "TargetLevel" -> Lookup[art, "TargetLevel", "?"],
    "Format" -> Lookup[art, "Format", "Records"],
    "Discoverability" -> "Unlisted",
    "Payload" -> Lookup[art, "Payload", {}]|>];

SourceVaultAnonymizePublicationStatus[artifactRef_String] := Module[{headRef, rec},
  headRef = iSVAPubHeadRead[artifactRef];
  If[!StringQ[headRef],
    Return[<|"Status" -> "NotPublished", "ArtifactRef" -> artifactRef|>]];
  rec = iSVAMapLoadByRef[headRef];
  If[!AssociationQ[rec] ||
     Lookup[rec, "ArtifactRef"] =!= artifactRef ||
     Lookup[rec, "ArtifactDigest"] =!= Last[StringSplit[artifactRef, ":"]],
    Return[<|"Status" -> "IntegrityFailed", "ArtifactRef" -> artifactRef|>]];
  <|"Status" -> "OK", "State" -> Lookup[rec, "State", "?"],
    "PublicationRef" -> headRef,
    "TargetLevel" -> Lookup[rec, "TargetLevel", "?"],
    "Discoverability" -> Lookup[rec, "Discoverability", "Unlisted"],
    "ArtifactRef" -> artifactRef|>];

SourceVaultRevokeDeclassifiedArtifact[artifactRef_String, reason_String] :=
  Module[{headRef, prev, rec, saved, pubRef},
    If[!iSVAInteractiveOwnerQ[],
      Return[<|"Status" -> "Failed", "Reason" -> "NonInteractiveMutationRefused"|>]];
    headRef = iSVAPubHeadRead[artifactRef];
    If[!StringQ[headRef],
      Return[<|"Status" -> "Failed", "Reason" -> "NotPublished"|>]];
    prev = iSVAMapLoadByRef[headRef];
    If[!AssociationQ[prev],
      Return[<|"Status" -> "Failed", "Reason" -> "RecordUnreadable"|>]];
    rec = Join[KeyDrop[prev, {"PublicationID", "PublishedAtUTC"}],
      <|"PublicationID" -> "pub:" <> iSVARandomHex[8],
        "State" -> "Revoked", "RevokeReason" -> reason,
        "PreviousPublicationRef" -> headRef,
        "RevocationEpoch" -> Lookup[prev, "RevocationEpoch", 0] + 1,
        "PublishedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>];
    saved = Quiet @ Check[
      SourceVault`SourceVaultSaveImmutableSnapshot["DeclassificationPublication", rec],
      $Failed];
    pubRef = If[AssociationQ[saved],
      Lookup[saved, "Ref", Lookup[saved, "SnapshotRef", $Failed]], $Failed];
    If[!StringQ[pubRef], Return[<|"Status" -> "Failed", "Reason" -> "RecordSaveFailed"|>]];
    If[!TrueQ[iSVAPubHeadCAS[artifactRef, headRef, pubRef]],
      Return[<|"Status" -> "Failed", "Reason" -> "HeadCASConflict"|>]];
    iSVARevokeHandlesFor[artifactRef];
    iSVAMapSetTargetPL[artifactRef, 0.85];  (* fail-closed 既定へ戻す (安全側) *)
    iSVAPubEventAppend[<|"EventClass" -> "AnonymizePublicationRevoked",
      "PublicationRef" -> pubRef, "Reason" -> reason,
      "Note" -> "copies already released externally cannot be recalled",
      "AtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>];
    <|"Status" -> "OK", "PublicationRef" -> pubRef, "State" -> "Revoked",
      "ArtifactRef" -> artifactRef|>];

(* ============================================================
   6e. L3a/L3b: EvaluationPlan/Result manifest + quarantine +
   AnnotationContent/Binding + join + 原子書き戻し
   (仕様 §5.9, §5.11, §13 / AC-025/026/033/050/078 の基盤)
   ============================================================ *)

iSVASaveSnapshotAs[class_String, rec_Association, pl_ : None] := Module[{saved, ref},
  saved = Quiet @ Check[
    SourceVault`SourceVaultSaveImmutableSnapshot[class, rec], $Failed];
  ref = If[AssociationQ[saved],
    Lookup[saved, "Ref", Lookup[saved, "SnapshotRef", $Failed]], $Failed];
  If[StringQ[ref] && NumericQ[pl], iSVAMapSetTargetPL[ref, pl]];
  ref];

(* L3a: 送信前 Plan (PL 1.0)。units: {<|"EvaluationUnitID"(省略可), "ItemTokens"->{...},
   "SubjectToken"(省略可)|>...}。1 unit = 1 job = 1 受験者 (仕様 §13.1-5) *)
iSVABuildEvaluationPlan[spec_Association] := Module[
    {artifactRef, bindingRef, units, jobs, rec, ref},
  artifactRef = Lookup[spec, "TargetArtifactRef", $Failed];
  bindingRef = Lookup[spec, "ArtifactBindingRef", $Failed];
  units = Lookup[spec, "Units", {}];
  If[!StringQ[artifactRef] || !StringQ[bindingRef] ||
     units === {} || !AllTrue[units, AssociationQ],
    Return[<|"Status" -> "Failed", "Reason" -> "MissingPlanFields"|>]];
  jobs = Map[Function[u, Module[{toks = Lookup[u, "ItemTokens", {}], slots, slotRecs},
      If[!(ListQ[toks] && toks =!= {} && AllTrue[toks, StringQ]),
        Throw[<|"Status" -> "Failed", "Reason" -> "BadUnitTokens"|>, "svaPlan"]];
      (* ResultSlot (複数結果 job = 設問別採点。仕様 §5.11)。
         slot は "Q1" のような文字列か <|SlotKey, TargetItemToken, ...|>。
         TargetItemToken は必ず当該 unit の ItemTokens 内 (別受験者への流し込みを防ぐ) *)
      slots = Lookup[u, "ResultSlots", {}];
      If[!ListQ[slots],
        Throw[<|"Status" -> "Failed", "Reason" -> "BadUnitSlots"|>, "svaPlan"]];
      slotRecs = Map[Function[s, Module[{sa, target},
          sa = If[StringQ[s], <|"SlotKey" -> s|>, s];
          If[!AssociationQ[sa],
            Throw[<|"Status" -> "Failed", "Reason" -> "BadUnitSlots"|>, "svaPlan"]];
          target = Lookup[sa, "TargetItemToken", First[toks]];
          If[!MemberQ[toks, target],
            Throw[<|"Status" -> "Failed", "Reason" -> "SlotTargetNotInUnit"|>, "svaPlan"]];
          <|"ResultSlotToken" -> SourceVaultAnonymizeGenerateToken["ResultSlot"],
            "SlotKey" -> ToString @ Lookup[sa, "SlotKey", "slot"],
            "TargetItemToken" -> target,
            "ExpectedOutputSchemaDigest" ->
              ToString @ Lookup[sa, "ExpectedOutputSchemaDigest", "unspecified"]|>]],
        slots];
      <|"JobID" -> "job:" <> iSVARandomHex[8],
        "JobToken" -> SourceVaultAnonymizeGenerateToken["Job"],
        "AttemptID" -> Lookup[u, "AttemptID", "attempt-1"],
        "RequestBindingNonceDigest" -> iSVASHA256Hex[iSVARandomHex[16]],
        "EvaluationUnitID" -> Lookup[u, "EvaluationUnitID",
          "eunit:" <> StringTake[iSVASHA256Hex[StringJoin[Sort[toks]]], 24]],
        "TargetItemTokens" -> toks,
        "SubjectToken" -> Lookup[u, "SubjectToken", "unspecified"],
        "ResultSlots" -> slotRecs,
        "ExpectedResultSlotMultisetDigest" ->
          iSVALinSetDigest[Lookup[#, "ResultSlotToken"] & /@ slotRecs],
        "ExpectedResultCardinality" -> Lookup[u, "ExpectedResultCardinality",
          Max[1, Length[slotRecs]]]|>]],
    units];
  rec = <|"ObjectClass" -> "EvaluationPlanManifest", "SchemaVersion" -> 1,
    "EvaluationBatchID" -> "batch:" <> iSVARandomHex[8],
    "TargetArtifactRef" -> artifactRef,
    "ArtifactBindingRef" -> bindingRef,
    "RequestDigest" -> Lookup[spec, "RequestDigest", "unspecified"],
    "RubricDigest" -> Lookup[spec, "RubricDigest", "unspecified"],
    "DistributionPlanRef" -> Lookup[spec, "DistributionPlanRef", "unspecified"],
    "Jobs" -> jobs,
    "ExpectedJobSetDigest" -> iSVALinSetDigest[Lookup[#, "JobID"] & /@ jobs],
    "CreatedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>;
  ref = iSVASaveSnapshotAs["EvaluationPlanManifest", rec, 1.0];
  If[!StringQ[ref], Return[<|"Status" -> "Failed", "Reason" -> "PlanSaveFailed"|>]];
  <|"Status" -> "OK", "PlanRef" -> ref, "Jobs" -> jobs,
    "EvaluationBatchID" -> rec["EvaluationBatchID"]|>];
iSVABuildEvaluationPlanSafe[spec_Association] :=
  Catch[iSVABuildEvaluationPlan[spec], "svaPlan"];
SourceVaultAnonymizeBuildEvaluationPlan[spec_Association] :=
  iSVABuildEvaluationPlanSafe[spec];
SourceVaultAnonymizeQuarantineIngress[planRef_String, jobId_String, raw_String] :=
  iSVAQuarantineIngress[planRef, jobId, raw];

(* quarantine: 受信 byte を最初から protected minimum PL で隔離保存 (仕様 §5.9 / AC-086) *)
iSVAQuarantineIngress[planRef_String, jobId_String, raw_String, pl_ : 1.0] :=
  Module[{ref},
    ref = iSVASaveSnapshotAs["CloudTransportResult",
      <|"ObjectClass" -> "CloudTransportResult", "SchemaVersion" -> 1,
        "PlanRef" -> planRef, "JobID" -> jobId,
        "RawResponse" -> raw,
        "ReceivedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>,
      N[pl]];
    If[StringQ[ref], <|"Status" -> "OK", "QuarantineRef" -> ref|>,
      <|"Status" -> "Failed", "Reason" -> "QuarantineSaveFailed"|>]];

(* join key: 設問別 (ResultSlot) 結果は同一 ItemToken を複数持つので SlotKey で分ける。
   slot 無し (従来) は ItemToken そのもの = 後方互換 *)
iSVAItemJoinKey[it_Association] := With[{sk = Lookup[it, "SlotKey", ""]},
  If[StringQ[sk] && sk =!= "",
    Lookup[it, "ItemToken", ""] <> "#" <> sk, Lookup[it, "ItemToken", ""]]];

(* L3b: annotation 生成。帰属の正本は Plan の JobID -> TargetItemTokens *)
SourceVaultCreateDerivedAnnotations[artifactRef_String, envelope_Association] :=
  Catch[iSVACreateDerivedAnnotationsBody[artifactRef, envelope], "svaAnn"];

iSVACreateDerivedAnnotationsBody[artifactRef_String, envelope_Association] :=
  Module[{planRef, plan, results, jobIndex, jobIds, resIds, missing, unknown, dup,
      items, protMin, resultRec, resultRef, contentRec, contentRef,
      bindingRec, bindingDigest, bindingRef2, itemTokens},
    planRef = Lookup[envelope, "PlanRef", $Failed];
    results = Lookup[envelope, "Results", $Failed];
    protMin = Lookup[envelope, "ProtectedMinimum", 1.0];
    If[!StringQ[planRef] || !ListQ[results] || !AllTrue[results, AssociationQ],
      Return[<|"Status" -> "Failed", "Reason" -> "MalformedEnvelope"|>]];
    plan = iSVAMapLoadByRef[planRef];
    If[!AssociationQ[plan] || Lookup[plan, "ObjectClass"] =!= "EvaluationPlanManifest",
      Return[<|"Status" -> "Failed", "Reason" -> "PlanUnreadable"|>]];
    If[plan["TargetArtifactRef"] =!= artifactRef,
      Return[<|"Status" -> "Failed", "Reason" -> "ArtifactMismatch"|>]];
    jobIndex = Association[(Lookup[#, "JobID"] -> #) & /@ plan["Jobs"]];
    jobIds = Keys[jobIndex];
    resIds = Lookup[#, "JobID", ""] & /@ results;
    dup = Keys[Select[Counts[resIds], # > 1 &]];
    unknown = Select[resIds, !MemberQ[jobIds, #] &];
    missing = Select[jobIds, !MemberQ[resIds, #] &];
    If[dup =!= {} || unknown =!= {} || missing =!= {},
      Return[<|"Status" -> "Failed", "Reason" -> "JobSetMismatch",
        "Missing" -> Length[missing], "Unknown" -> Length[unknown],
        "Duplicate" -> Length[dup]|>]];
    (* out-of-band binding: ItemToken は Plan から引く (応答由来の token は不使用) *)
    items = Flatten[Map[Function[r, Module[
        {job = jobIndex[r["JobID"]], slots, rslots, planTokens, respTokens},
        slots = Lookup[job, "ResultSlots", {}];
        rslots = Lookup[r, "Slots", None];
        If[ListQ[slots] && slots =!= {},
          (* 設問別 job: slot multiset を検証してから slot -> TargetItemToken (Plan 由来) *)
          If[!ListQ[rslots] || !AllTrue[rslots, AssociationQ],
            Throw[<|"Status" -> "Failed", "Reason" -> "MissingResultSlots",
              "JobID" -> r["JobID"]|>, "svaAnn"]];
          planTokens = Sort[Lookup[#, "ResultSlotToken"] & /@ slots];
          respTokens = Sort[ToString @ Lookup[#, "ResultSlotToken", ""] & /@ rslots];
          If[planTokens =!= respTokens,
            Throw[<|"Status" -> "Failed", "Reason" -> "ResultSlotSetMismatch",
              "JobID" -> r["JobID"]|>, "svaAnn"]];
          Map[Function[sl, Module[{rs},
            rs = SelectFirst[rslots,
              Lookup[#, "ResultSlotToken", ""] === sl["ResultSlotToken"] &, <||>];
            <|"ItemToken" -> sl["TargetItemToken"], "SlotKey" -> sl["SlotKey"],
              "SubjectToken" -> Lookup[job, "SubjectToken", "unspecified"],
              "Score" -> Lookup[rs, "Score", Null],
              "Reason" -> ToString[Lookup[rs, "Reason", ""]],
              "Attempt" -> 1, "Supersedes" -> "none"|>]], slots],
          (* 単一結果 job (従来) *)
          Map[Function[tok,
            <|"ItemToken" -> tok,
              "SubjectToken" -> Lookup[job, "SubjectToken", "unspecified"],
              "Score" -> Lookup[r, "Score", Null],
              "Reason" -> ToString[Lookup[r, "Reason", ""]],
              "Attempt" -> 1, "Supersedes" -> "none"|>],
            job["TargetItemTokens"]]]]], results]];
    itemTokens = iSVAItemJoinKey /@ items;
    resultRec = <|"ObjectClass" -> "EvaluationResultManifest", "SchemaVersion" -> 1,
      "PlanRef" -> planRef,
      "PlanBatchID" -> plan["EvaluationBatchID"],
      "Jobs" -> Map[<|"JobID" -> Lookup[#, "JobID"],
          "ResponseDigest" -> iSVASHA256Hex[ToString[Lookup[#, "Reason", ""]] <>
            ToString[Lookup[#, "Score", ""]]],
          "Status" -> "Completed"|> &, results],
      "ReceivedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>;
    resultRef = iSVASaveSnapshotAs["EvaluationResultManifest", resultRec, 1.0];
    If[!StringQ[resultRef],
      Return[<|"Status" -> "Failed", "Reason" -> "ResultManifestSaveFailed"|>]];
    contentRec = <|"ObjectClass" -> "AnnotationContent", "SchemaVersion" -> 1,
      "AnnotationType" -> Lookup[envelope, "AnnotationType", "Grade"],
      "Items" -> items,
      "ItemsDigest" -> iSVALinSetDigest[itemTokens]|>;
    contentRef = iSVASaveSnapshotAs["AnnotationContent", contentRec, N[protMin]];
    If[!StringQ[contentRef],
      Return[<|"Status" -> "Failed", "Reason" -> "ContentSaveFailed"|>]];
    bindingRec = <|"ObjectClass" -> "AnnotationBinding", "SchemaVersion" -> 1,
      "ContentRef" -> contentRef,
      "TargetArtifactRef" -> artifactRef,
      "ArtifactBindingRef" -> plan["ArtifactBindingRef"],
      "EvaluationPlanManifestRef" -> planRef,
      "EvaluationResultManifestRef" -> resultRef,
      "RubricDigest" -> Lookup[plan, "RubricDigest", "unspecified"],
      "ExpectedItemTokenSetDigest" -> iSVALinSetDigest[itemTokens],
      "KeyId" -> $SourceVaultAnonymizeKeyId|>;
    bindingDigest = SourceVaultAnonymizeCanonicalDigest[bindingRec];
    If[!StringQ[bindingDigest],
      Return[<|"Status" -> "Failed", "Reason" -> "NonCanonicalBinding"|>]];
    bindingRef2 = iSVASaveSnapshotAs["AnnotationBinding",
      Append[bindingRec, "BindingDigest" -> bindingDigest], 1.0];
    If[!StringQ[bindingRef2],
      Return[<|"Status" -> "Failed", "Reason" -> "BindingSaveFailed"|>]];
    <|"Status" -> "OK", "AnnotationBindingRef" -> bindingRef2,
      "AnnotationContentRef" -> contentRef,
      "ResultManifestRef" -> resultRef, "ItemCount" -> Length[items]|>];

iSVALoadAnnotationBundle[annBindingRef_String] := Module[
    {binding, content, artBinding, lineage, mapv},
  binding = iSVAMapLoadByRef[annBindingRef];
  If[!AssociationQ[binding] || Lookup[binding, "ObjectClass"] =!= "AnnotationBinding",
    Return[<|"Status" -> "Failed", "Reason" -> "AnnotationBindingUnreadable"|>]];
  If[SourceVaultAnonymizeCanonicalDigest[KeyDrop[binding, "BindingDigest"]] =!=
     Lookup[binding, "BindingDigest"],
    Return[<|"Status" -> "Failed", "Reason" -> "AnnotationBindingTampered"|>]];
  content = iSVAMapLoadByRef[binding["ContentRef"]];
  If[!AssociationQ[content],
    Return[<|"Status" -> "Failed", "Reason" -> "ContentUnreadable"|>]];
  artBinding = iSVAMapLoadByRef[binding["ArtifactBindingRef"]];
  If[!AssociationQ[artBinding] || !iSVAVerifyArtifactBinding[artBinding] ||
     artBinding["ArtifactRef"] =!= binding["TargetArtifactRef"],
    Return[<|"Status" -> "Failed", "Reason" -> "LineageMismatch"|>]];
  lineage = iSVAMapLoadByRef[artBinding["LineageManifestRef"]];
  If[!AssociationQ[lineage],
    Return[<|"Status" -> "Failed", "Reason" -> "LineageUnreadable"|>]];
  mapv = iSVAMapLoadByRef[artBinding["MapRef"]];
  If[!AssociationQ[mapv],
    Return[<|"Status" -> "Failed", "Reason" -> "MapUnreadable"|>]];
  <|"Status" -> "OK", "Binding" -> binding, "Content" -> content,
    "ArtifactBinding" -> artBinding, "Lineage" -> lineage, "Map" -> mapv|>];

SourceVaultValidateDerivedJoin[annBindingRef_String] := Module[
    {bundle, items, derivedByToken, entriesBySubj, expected, actual,
     unknown, missing, dup, unresolved},
  bundle = iSVALoadAnnotationBundle[annBindingRef];
  If[bundle["Status"] =!= "OK", Return[bundle]];
  items = Lookup[bundle["Content"], "Items", {}];
  derivedByToken = Association[
    (Lookup[#, "ItemToken", ""] -> #) & /@ Lookup[bundle["Lineage"], "DerivedNodes", {}]];
  entriesBySubj = Association[
    (Lookup[#, "SubjectToken", ""] -> #) & /@ Lookup[bundle["Map"], "Entries", {}]];
  (* dup/digest は join key (設問別は ItemToken#SlotKey)、lineage 照合は ItemToken *)
  actual = iSVAItemJoinKey /@ items;
  dup = Keys[Select[Counts[actual], # > 1 &]];
  unknown = Select[Lookup[#, "ItemToken", ""] & /@ items,
    !KeyExistsQ[derivedByToken, #] &];
  expected = If[StringQ[Lookup[bundle["Binding"], "ExpectedItemTokenSetDigest"]],
    Lookup[bundle["Binding"], "ExpectedItemTokenSetDigest"], "unspecified"];
  missing = If[expected =!= iSVALinSetDigest[actual], {"TokenSetDigestMismatch"}, {}];
  unresolved = Select[items, Module[{tok = Lookup[#, "ItemToken", ""], dn, subj},
      dn = Lookup[derivedByToken, tok, $Failed];
      If[dn === $Failed, True,
        subj = Lookup[dn, "SubjectToken", Lookup[#, "SubjectToken", ""]];
        !KeyExistsQ[entriesBySubj, subj]]] &];
  <|"Status" -> "OK",
    "AllMatched" -> (dup === {} && unknown === {} && missing === {} &&
       unresolved === {}),
    "Matched" -> Length[items] - Length[unknown] - Length[unresolved],
    "Unknown" -> Length[unknown], "Duplicate" -> Length[dup],
    "SetMismatch" -> missing =!= {},
    "UnresolvedSubject" -> Length[unresolved]|>];

SourceVaultAttachDerivedResults[annBindingRef_String] := Module[
    {preview, bundle, items, derivedByToken, entriesBySubj, rows},
  preview = SourceVaultValidateDerivedJoin[annBindingRef];
  If[Lookup[preview, "Status"] =!= "OK", Return[preview]];
  If[!TrueQ[preview["AllMatched"]],
    Return[<|"Status" -> "Failed", "Reason" -> "JoinPreviewFailed",
      "Preview" -> preview|>]];
  bundle = iSVALoadAnnotationBundle[annBindingRef];
  items = Lookup[bundle["Content"], "Items", {}];
  derivedByToken = Association[
    (Lookup[#, "ItemToken", ""] -> #) & /@ Lookup[bundle["Lineage"], "DerivedNodes", {}]];
  entriesBySubj = Association[
    (Lookup[#, "SubjectToken", ""] -> #) & /@ Lookup[bundle["Map"], "Entries", {}]];
  rows = Map[Function[it, Module[
      {dn = derivedByToken[it["ItemToken"]], subj, entry},
      subj = Lookup[dn, "SubjectToken", Lookup[it, "SubjectToken", ""]];
      entry = entriesBySubj[subj];
      <|"ItemToken" -> it["ItemToken"], "SubjectToken" -> subj,
        "EntityID" -> Lookup[entry, "EntityID", "?"],
        "Identity" -> Lookup[entry, "Identity", <||>],
        "DisplayLabel" -> Lookup[entry, "DisplayLabel", ""],
        "DerivedUnitID" -> Lookup[dn, "UnitID", "?"],
        "SlotKey" -> Lookup[it, "SlotKey", ""],
        "Score" -> Lookup[it, "Score", Null],
        "Reason" -> Lookup[it, "Reason", ""],
        "Attempt" -> Lookup[it, "Attempt", 1]|>]], items];
  If[Names["SourceVault`SourceVaultPrivateResult"] =!= {},
    SourceVault`SourceVaultPrivateResult[
      <|"Status" -> "OK", "Rows" -> rows, "RowCount" -> Length[rows]|>, 1.0],
    (If[Names["SourceVault`SourceVaultNotePrivacy"] =!= {},
       Quiet @ Check[SourceVault`SourceVaultNotePrivacy[1.0], Null]];
     <|"Status" -> "OK", "Rows" -> rows, "RowCount" -> Length[rows]|>)]];

(* ============================================================
   7. U0: ReleaseHandle mapping / revoke / rotate (仕様 §5.10, §10.5, AC-081..085)
   - 発行 (iSVAIssueReleaseHandle) は Publish パイプライン内部専用 (L2b が使う)。
   - mapping ストアには handle 平文を置かない: keyed HMAC digest -> record。
     record は <|ArtifactRef, PublicationRef, State, ExpiresAtUnix, IssuedAtUTC|>。
   - handle 平文は発行時の返り値でのみ渡る (bearer)。紛失時は rotate。
   ============================================================ *)

If[!ValueQ[$iSVAHandleStoreOverride], $iSVAHandleStoreOverride = Automatic];

iSVAHandleStorePath[] := Which[
  StringQ[$iSVAHandleStoreOverride], $iSVAHandleStoreOverride,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r], FileNameJoin[{r, "config", "anonymize-release-handles.json"}], $Failed]],
  True, $Failed];

iSVAHandleDigest[handle_String] := Module[{mac},
  mac = Quiet @ Check[NBAccess`NBMacWithKeyRef[$iSVAGrantKeyRef,
    StringToByteArray[handle, "UTF-8"], "release-handle"], $Failed];
  If[StringQ[mac], ToLowerCase[mac], $Failed]];

iSVAHandleStoreRead[] := Module[{path = iSVAHandleStorePath[], rec},
  If[path === $Failed, Return[$Failed]];
  If[!FileExistsQ[path], Return[<||>]];
  rec = Quiet @ Check[Import[path, "RawJSON"], $Failed];
  If[AssociationQ[rec], rec, $Failed]];

iSVAHandleStoreWrite[store_Association] := Module[{path = iSVAHandleStorePath[]},
  If[path === $Failed, Return[$Failed]];
  Quiet @ Check[
    (If[!DirectoryQ[DirectoryName[path]], CreateDirectory[DirectoryName[path]]];
     Export[path, store, "RawJSON"]; True), $Failed]];

(* 内部: Publish (L2b) が呼ぶ発行。expires: Automatic = 無期限 (0 扱いせず -1) *)
Options[iSVAIssueReleaseHandle] = {"TTLSeconds" -> Automatic};
iSVAIssueReleaseHandle[artifactRef_String, publicationRef_String,
    OptionsPattern[]] := Module[{handle, dg, store, exp},
  handle = SourceVaultAnonymizeGenerateReleaseHandle[];
  If[handle === $Failed, Return[<|"Status" -> "Failed", "Reason" -> "RandomUnavailable"|>]];
  dg = iSVAHandleDigest[handle];
  If[dg === $Failed, Return[<|"Status" -> "Failed", "Reason" -> "DigestUnavailable"|>]];
  store = iSVAHandleStoreRead[];
  If[store === $Failed, Return[<|"Status" -> "Failed", "Reason" -> "HandleStoreUnavailable"|>]];
  exp = With[{ttl = OptionValue["TTLSeconds"]},
    If[IntegerQ[ttl], UnixTime[Now] + ttl, -1]];
  store[dg] = <|"ArtifactRef" -> artifactRef, "PublicationRef" -> publicationRef,
    "State" -> "Active", "ExpiresAtUnix" -> exp,
    "IssuedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>;
  If[iSVAHandleStoreWrite[store] =!= True,
    Return[<|"Status" -> "Failed", "Reason" -> "HandleStoreWriteFailed"|>]];
  <|"Status" -> "OK", "ReleaseHandle" -> handle, "ArtifactRef" -> artifactRef|>];

SourceVaultResolveReleaseHandle[handle_String] := Module[{dg, store, rec},
  If[!SourceVaultAnonymizeReleaseHandleValidQ[handle],
    Return[<|"Status" -> "Failed", "Reason" -> "HandleInvalid"|>]];
  dg = iSVAHandleDigest[handle];
  store = iSVAHandleStoreRead[];
  If[dg === $Failed || store === $Failed,
    Return[<|"Status" -> "Failed", "Reason" -> "HandleStoreUnavailable"|>]];
  rec = Lookup[store, dg, Missing["NotFound"]];
  (* NotFound / Revoked / Expired を区別しない (存在 oracle 防止) *)
  If[MissingQ[rec] || Lookup[rec, "State"] =!= "Active" ||
     (Lookup[rec, "ExpiresAtUnix", -1] =!= -1 &&
      Lookup[rec, "ExpiresAtUnix", -1] < UnixTime[Now]),
    Return[<|"Status" -> "Failed", "Reason" -> "HandleInvalid"|>]];
  <|"Status" -> "OK", "ArtifactRef" -> rec["ArtifactRef"],
    "PublicationRef" -> rec["PublicationRef"]|>];

iSVARevokeHandlesFor[artifactRef_String] := Module[{store, hit = 0},
  store = iSVAHandleStoreRead[];
  If[store === $Failed, Return[$Failed]];
  store = Association @ KeyValueMap[
    Function[{k, v},
      If[Lookup[v, "ArtifactRef"] === artifactRef && Lookup[v, "State"] === "Active",
        hit++; k -> Append[v, "State" -> "Revoked"], k -> v]], store];
  If[iSVAHandleStoreWrite[store] =!= True, Return[$Failed]];
  hit];

SourceVaultRevokeReleaseHandle[artifactRef_String] := Module[{n},
  If[!iSVAInteractiveOwnerQ[],
    Return[<|"Status" -> "Failed", "Reason" -> "NonInteractiveMutationRefused"|>]];
  n = iSVARevokeHandlesFor[artifactRef];
  If[n === $Failed,
    <|"Status" -> "Failed", "Reason" -> "HandleStoreUnavailable"|>,
    <|"Status" -> "OK", "RevokedCount" -> n, "ArtifactRef" -> artifactRef|>]];

SourceVaultRotateReleaseHandle[artifactRef_String] := Module[{n, issued},
  If[!iSVAInteractiveOwnerQ[],
    Return[<|"Status" -> "Failed", "Reason" -> "NonInteractiveMutationRefused"|>]];
  n = iSVARevokeHandlesFor[artifactRef];
  If[n === $Failed,
    Return[<|"Status" -> "Failed", "Reason" -> "HandleStoreUnavailable"|>]];
  issued = iSVAIssueReleaseHandle[artifactRef, "rotation"];
  If[issued["Status"] =!= "OK", Return[issued]];
  <|"Status" -> "OK", "RevokedCount" -> n,
    "ReleaseHandle" -> issued["ReleaseHandle"], "ArtifactRef" -> artifactRef|>];

(* ============================================================
   7a. G1/G2: CompositionPolicy / ExposureLedger / Guard / DistributionPlan
   (仕様 §5.14, §13.5, §13.6, §15.2 / AC-069/070/073/074/094/095)
   ============================================================ *)

If[!ValueQ[$iSVAExposureLedgerOverride], $iSVAExposureLedgerOverride = Automatic];
$iSVAExposureScopeKeyRef = $iSVAGrantKeyRef;  (* owner-only keyed HMAC (grant 鍵を流用) *)

iSVAExposureLedgerPath[] := Which[
  StringQ[$iSVAExposureLedgerOverride], $iSVAExposureLedgerOverride,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r], FileNameJoin[{r, "config", "anonymize-exposure-ledger.jsonl"}],
      $Failed]],
  True, $Failed];

(* CompositionPolicy (§13.5): 単純 Max では判定しない *)
SourceVaultAnonymizeComposedPrivacy[spec_Association] := Module[
    {atype, distinct, indiv, inputPL, pl},
  atype = Lookup[spec, "AnnotationType", "None"];
  distinct = Lookup[spec, "DistinctSubjectCount", 1];
  indiv = TrueQ[Lookup[spec, "IndividualValuesPresent", False]];
  inputPL = Lookup[spec, "InputPL", 0.45];
  pl = Which[
    (* 成績を含む永続物 / 複数 subject の個別値を含む集約 -> PL 1.0 *)
    atype === "Grade" && indiv, 1.0,
    IntegerQ[distinct] && distinct >= 2 && indiv, 1.0,
    (* 統計のみ (個別値なし) は別 policy 必要 -> 保守的に高 PL *)
    IntegerQ[distinct] && distinct >= 2 && !indiv, 0.85,
    True, N[Max[inputPL, 0.0]]];
  <|"PrivacyLevel" -> pl,
    "Basis" -> Which[
      atype === "Grade" && indiv, "GradeWithIndividualValues",
      IntegerQ[distinct] && distinct >= 2 && indiv, "MultiSubjectAggregate",
      IntegerQ[distinct] && distinct >= 2, "AggregateStatisticsNeedsPolicy",
      True, "SingleItemInputPL"]|>];

iSVAExposureScopeHash[s_String] := Module[{mac},
  mac = Quiet @ Check[NBAccess`NBMacWithKeyRef[$iSVAExposureScopeKeyRef,
    StringToByteArray[s, "UTF-8"], "exposure-scope"], $Failed];
  If[StringQ[mac], StringTake[ToLowerCase[mac], 32], iSVASHA256Hex[s][[;; 32]]]];

$iSVACoverageEventClasses = {"ContentReleased", "CloudEgressed", "ReleaseIndeterminate"};

SourceVaultAnonymizeRecordExposure[event_Association] := Module[
    {path = iSVAExposureLedgerPath[], ec, ev, strm, ok = False},
  If[path === $Failed,
    Return[<|"Status" -> "Failed", "Reason" -> "LedgerUnavailable"|>]];
  ec = Lookup[event, "EventClass", "None"];
  ev = Join[<|"EventClass" -> ec,
      "ScopeID" -> iSVAExposureScopeHash[ToString@Lookup[event, "ScopeID", "none"]],
      "CoverageCounted" -> MemberQ[$iSVACoverageEventClasses, ec],
      "AtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>,
    KeyDrop[event, {"ScopeID"}]];
  Quiet @ Check[
    (If[!DirectoryQ[DirectoryName[path]], CreateDirectory[DirectoryName[path]]];
     strm = OpenAppend[path, BinaryFormat -> True];
     If[Head[strm] === OutputStream,
       BinaryWrite[strm, StringToByteArray[
         ExportString[ev, "RawJSON", "Compact" -> True] <> "\n", "UTF-8"]];
       Close[strm]; ok = True]), Null];
  If[!ok, Return[<|"Status" -> "Failed", "Reason" -> "LedgerWriteFailed"|>]];
  <|"Status" -> "OK", "EventClass" -> ec,
    "CoverageCounted" -> MemberQ[$iSVACoverageEventClasses, ec]|>];

(* ledger rollup: scope 内の coverage 加算イベントを読む *)
iSVAExposureRollup[scopeHash_String, windowSec_ : 86400] := Module[
    {path = iSVAExposureLedgerPath[], lines, evs, cutoff},
  If[path === $Failed || !FileExistsQ[path],
    Return[<|"DistinctSubjects" -> 0, "Variants" -> 0, "Releases" -> 0|>]];
  lines = Quiet @ Check[Import[path, {"Text", "Lines"}], {}];
  evs = Select[Map[Quiet @ Check[ImportString[#, "RawJSON"], $Failed] &, lines],
    AssociationQ[#] && Lookup[#, "ScopeID"] === scopeHash &&
      TrueQ[Lookup[#, "CoverageCounted"]] &];
  <|"DistinctSubjects" -> Total[Lookup[#, "DistinctSubjects", 0] & /@ evs],
    "Variants" -> Length[DeleteDuplicates[
      Lookup[#, "VariantSetDigest", ""] & /@ evs]],
    "Releases" -> Length[evs]|>];

SourceVaultAnonymizeExposureGuard[intent_Association] := Module[
    {scope, pol, rollup, coverage, cohort, projected, ratio, req, decision, reason},
  scope = iSVAExposureScopeHash[ToString@Lookup[intent, "ScopeID", "none"]];
  pol = Lookup[intent, "ExposurePolicy", <||>];
  req = ToString@Lookup[intent, "RequestID", CreateUUID[]];
  (* PreReleaseIntent を先に durable 記録。失敗したら Deny (無記録では通さない) *)
  If[SourceVaultAnonymizeRecordExposure[<|"EventClass" -> "PreReleaseIntent",
      "ScopeID" -> Lookup[intent, "ScopeID", "none"], "RequestID" -> req,
      "ProviderTrustDomain" -> Lookup[intent, "ProviderTrustDomain", "Unknown"],
      "DistinctSubjects" -> Lookup[intent, "DistinctSubjects", 0]|>]["Status"] =!= "OK",
    Return[<|"Decision" -> "Deny", "Reason" -> "PreReleaseIntentUnrecordable"|>]];
  rollup = iSVAExposureRollup[scope,
    Lookup[pol, "WindowSeconds", 86400]];
  coverage = rollup["DistinctSubjects"] + Lookup[intent, "DistinctSubjects", 0];
  cohort = Lookup[intent, "CohortSize", 0];
  ratio = If[IntegerQ[cohort] && cohort > 0, N[coverage/cohort], 0.];
  decision = Which[
    IntegerQ[Lookup[pol, "MaxDistinctSubjectsPerProviderPerWindow"]] &&
      coverage > pol["MaxDistinctSubjectsPerProviderPerWindow"],
    {"RequireOwnerApproval", "DistinctSubjectThresholdExceeded"},
    NumericQ[Lookup[pol, "MaxCohortCoveragePerProvider"]] &&
      ratio > pol["MaxCohortCoveragePerProvider"],
    {"RequireOwnerApproval", "CohortCoverageThresholdExceeded"},
    IntegerQ[Lookup[pol, "MaxVariantsPerOriginPerProvider"]] &&
      (rollup["Variants"] + 1) > pol["MaxVariantsPerOriginPerProvider"],
    {"RequireOwnerApproval", "RepeatedVariantExposure"},
    NumericQ[Lookup[pol, "AlertThreshold"]] && ratio > pol["AlertThreshold"],
    {"PermitAndReport", "AlertThreshold"},
    True, {"Permit", "BelowThresholds"}];
  {decision, reason} = {First[decision], Last[decision]};
  <|"Decision" -> decision, "Reason" -> reason,
    "CoverageAfter" -> coverage, "CohortRatio" -> ratio,
    "RequestID" -> req|>];

(* DistributionPlan (§13.6) *)
SourceVaultAnonymizeValidateDistribution[plan_Association, assignment_List] := Module[
    {allowed, maxPer, allowDup, perProvider, dupSubj, unauthorized, over},
  allowed = Lookup[plan, "AllowedProviders", {}];
  maxPer = Lookup[plan, "MaxSubjectsPerProvider", Infinity];
  allowDup = TrueQ[Lookup[plan, "AllowCrossProviderDuplicateSubject", False]];
  (* assignment: {<|"SubjectToken", "Provider"|>...} *)
  unauthorized = Select[assignment,
    !MemberQ[allowed, Lookup[#, "Provider"]] &];
  perProvider = Counts[Lookup[#, "Provider"] & /@ assignment];
  over = Select[Normal[perProvider], IntegerQ[maxPer] && #[[2]] > maxPer &];
  dupSubj = If[allowDup, {},
    Keys[Select[Counts[Lookup[#, "SubjectToken"] & /@ assignment], # > 1 &]]];
  <|"Status" -> If[unauthorized === {} && over === {} && dupSubj === {},
      "OK", "Failed"],
    "UnauthorizedProviders" -> Length[unauthorized],
    "OverLimitProviders" -> Length[over],
    "DuplicateSubjects" -> Length[dupSubj]|>];

(* --- G1c: System Doctor sanitized probe + owner-only doctor + escalation --- *)
If[!ValueQ[$iSVAExposureProbeConcentrationThreshold],
  $iSVAExposureProbeConcentrationThreshold = 50];

iSVAExposureRangeLabel[n_Integer] := Which[
  n <= 0, "0", n < 10, "1-9", n < 50, "10-49", n < 200, "50-199", True, "200+"];

iSVAReadExposureEvents[] := Module[{path = iSVAExposureLedgerPath[], lines},
  If[path === $Failed || !FileExistsQ[path], Return[{}]];
  lines = Quiet @ Check[Import[path, {"Text", "Lines"}], $Failed];
  If[!ListQ[lines], Return[$Failed]];
  Select[Map[Quiet @ Check[ImportString[#, "RawJSON"], $Failed] &, lines],
    AssociationQ[#] && TrueQ[Lookup[#, "CoverageCounted"]] &]];

SourceVaultAnonymizeExposureProbe[] := Module[{evs, byScope, maxRel, health, reason},
  evs = iSVAReadExposureEvents[];
  If[evs === $Failed,
    Return[<|"Health" -> "Warning", "ReasonCode" -> "ExposureLedgerUnavailable"|>]];
  byScope = If[evs === {}, <||>, Counts[Lookup[#, "ScopeID", ""] & /@ evs]];
  maxRel = If[byScope === <||>, 0, Max[Values[byScope]]];
  {health, reason} = Which[
    maxRel > $iSVAExposureProbeConcentrationThreshold,
    {"High", "AnonymizedArtifactConcentratedUse"},
    True, {"OK", "BelowThreshold"}];
  (* sanitized: 実 scope/provider は出さず件数レンジのみ *)
  <|"Health" -> health, "ReasonCode" -> reason,
    "ScopeCountRange" -> iSVAExposureRangeLabel[Length[byScope]],
    "MaxScopeReleaseRange" -> iSVAExposureRangeLabel[maxRel]|>];

SourceVaultAnonymizeExposureSensitiveDoctor[] := Module[{evs, byScope, byProvider},
  If[!iSVAInteractiveOwnerQ[],
    Return[<|"Status" -> "Failed", "Reason" -> "OwnerOnly"|>]];
  evs = iSVAReadExposureEvents[];
  If[evs === $Failed,
    Return[<|"Status" -> "Failed", "Reason" -> "ExposureLedgerUnavailable"|>]];
  byScope = GroupBy[evs, Lookup[#, "ScopeID", ""] &];
  byProvider = GroupBy[evs, Lookup[#, "ProviderTrustDomain", "Unknown"] &];
  <|"Status" -> "OK",
    "TotalReleases" -> Length[evs],
    "DistinctScopes" -> Length[byScope],
    "ByProviderTrustDomain" ->
      Association[KeyValueMap[#1 -> Length[#2] &, byProvider]],
    "TopScopes" -> Take[
      ReverseSortBy[KeyValueMap[<|"Scope" -> #1, "Releases" -> Length[#2],
        "Variants" -> Length[DeleteDuplicates[
          Lookup[#, "VariantSetDigest", ""] & /@ #2]]|> &, byScope],
        #["Releases"] &], UpTo[5]],
    "Remediation" -> If[Length[byScope] > 0 &&
        Max[Length /@ Values[byScope]] > $iSVAExposureProbeConcentrationThreshold,
      "Concentrated use detected. Review the top scope, consider provider sharding or owner reapproval.",
      "No concentration above threshold."]|>];

SourceVaultRegisterAnonymizeExposureDiagnostics[] := Module[{reg},
  If[Names["SourceVault`SourceVaultDiagnosticsRegisterProbe"] === {},
    Return[<|"Status" -> "DiagnosticsUnavailable"|>]];
  reg = Quiet @ Check[
    SourceVault`SourceVaultDiagnosticsRegisterProbe["anonymize-exposure",
      SourceVaultAnonymizeExposureProbe], $Failed];
  <|"Status" -> If[reg === $Failed, "Failed", "Registered"],
    "ProbeId" -> "anonymize-exposure"|>];

(* probe が High を返すとき cloud-safe な escalation event を送る (弱結合) *)
SourceVaultAnonymizeExposureEscalateIfNeeded[] := Module[{p},
  p = SourceVaultAnonymizeExposureProbe[];
  If[MemberQ[{"High", "Critical"}, Lookup[p, "Health"]] &&
     Names["SourceVault`SourceVaultDiagnosticsEscalate"] =!= {},
    Quiet @ Check[SourceVault`SourceVaultDiagnosticsEscalate[<|
      "EventClass" -> "AnonymizeExposureConcentration",
      "Severity" -> "High", "ReasonCode" -> p["ReasonCode"],
      "Component" -> "anonymize-exposure",
      "MaxScopeReleaseRange" -> p["MaxScopeReleaseRange"]|>], Null];
    <|"Status" -> "Escalated", "ReasonCode" -> p["ReasonCode"]|>,
    <|"Status" -> "NoEscalation", "Health" -> Lookup[p, "Health"]|>]];

(* ============================================================
   7b. A6: フォーマット変換 (仕様 §6.6, §12)
   原則: 黒塗りは必ずラスタ上書き + 再エンコード (見かけ黒塗り = テキスト層/
   メタデータ残存を構造的に排除)。V5 は独立の決定論チェック (検出器と別系統)。
   ============================================================ *)

(* 正規化矩形 (0-1) をピクセル座標へ写して黒塗り。ImageData を直接書き換えて
   新規 Image を作る (再エンコード = 元のメタ/レイヤは残らない) *)
iSVAImageRedactRaster[img_Image, regions_List] := Module[
    {data, w, h, ch},
  data = ImageData[img, "Byte"];
  {w, h} = ImageDimensions[img];
  ch = If[Length[Dimensions[data]] === 3, Last[Dimensions[data]], 1];
  Do[Module[{x1, y1, x2, y2, c1, r1, c2, r2},
    x1 = Clip[Lookup[r, "x1", 0.], {0, 1}]; x2 = Clip[Lookup[r, "x2", 0.], {0, 1}];
    y1 = Clip[Lookup[r, "y1", 0.], {0, 1}]; y2 = Clip[Lookup[r, "y2", 0.], {0, 1}];
    (* 画像行は上が index 1。正規化 y は下原点なので反転 *)
    c1 = Max[1, Ceiling[Min[x1, x2] w]]; c2 = Min[w, Floor[Max[x1, x2] w]];
    r1 = Max[1, Ceiling[(1 - Max[y1, y2]) h]]; r2 = Min[h, Floor[(1 - Min[y1, y2]) h]];
    If[c2 >= c1 && r2 >= r1,
      data[[r1 ;; r2, c1 ;; c2]] = If[ch === 1, 0, ConstantArray[0, {r2 - r1 + 1, c2 - c1 + 1, ch}]]]],
    {r, regions}];
  (* 新規 Image (再エンコード) *)
  Image[data, "Byte"]];

SourceVaultAnonymizeImageRedact[img_Image, regions_List] :=
  iSVAImageRedactRaster[img, regions];

Options[SourceVaultAnonymizePDFPageImages] = {"Regions" -> {}, "DPI" -> 150};
SourceVaultAnonymizePDFPageImages[pages_List, OptionsPattern[]] := Module[{regions},
  regions = OptionValue["Regions"];
  <|"Status" -> "OK", "Format" -> "PageImageList",
    "Pages" -> Map[If[Head[#] === Image,
      SourceVaultAnonymizeImageRedact[#, regions], #] &, pages]|>];

(* V5: 各領域が単色 (分散 0) かを独立検査 *)
SourceVaultAnonymizeVerifyRedactedImage[img_Image, regions_List] := Module[
    {data, w, h, fails},
  data = ImageData[img, "Byte"];
  {w, h} = ImageDimensions[img];
  fails = Select[regions, Function[r, Module[{x1, y1, x2, y2, c1, r1, c2, r2, patch},
    x1 = Clip[Lookup[r, "x1", 0.], {0, 1}]; x2 = Clip[Lookup[r, "x2", 0.], {0, 1}];
    y1 = Clip[Lookup[r, "y1", 0.], {0, 1}]; y2 = Clip[Lookup[r, "y2", 0.], {0, 1}];
    c1 = Max[1, Ceiling[Min[x1, x2] w]]; c2 = Min[w, Floor[Max[x1, x2] w]];
    r1 = Max[1, Ceiling[(1 - Max[y1, y2]) h]]; r2 = Min[h, Floor[(1 - Min[y1, y2]) h]];
    If[c2 < c1 || r2 < r1, True,
      patch = Flatten[data[[r1 ;; r2, c1 ;; c2]]];
      Max[patch] - Min[patch] > 0]]]];
  <|"Status" -> If[fails === {}, "OK", "Failed"],
    "NonSolidRegions" -> Length[fails]|>];

(* --- A8: MediaScan = ローカル OCR/vision による自動検出黒塗り (仕様 §6.8) --- *)
Options[SourceVaultAnonymizeMediaScan] = {
  "DeclaredRegions" -> {}, "MediaScanFn" -> None,
  "ConfidenceThreshold" -> 0.5, "IndependentVerifierFn" -> None};

SourceVaultAnonymizeMediaScan[img_Image, OptionsPattern[]] := Module[
    {declared, scanFn, thr, verFn, detected, kept, allRegions, redacted, v5,
     residual, evidence, status},
  declared = OptionValue["DeclaredRegions"];
  scanFn = OptionValue["MediaScanFn"];
  thr = OptionValue["ConfidenceThreshold"];
  verFn = OptionValue["IndependentVerifierFn"];
  (* 検出器はローカル限定。未指定なら検出なし *)
  detected = If[scanFn === None, {},
    Quiet @ Check[scanFn[img], $Failed]];
  If[detected === $Failed,
    (* 検出器不通: 宣言 Regions があればそれだけ塗り NeedsReview、無ければ NeedsReview *)
    Return[<|"Status" -> "NeedsReview", "Reason" -> "MediaScannerUnavailable",
      "Image" -> If[declared =!= {},
        SourceVaultAnonymizeImageRedact[img, declared], img],
      "Regions" -> declared,
      "Evidence" -> <|"Detector" -> "Unavailable"|>|>]];
  If[!ListQ[detected], detected = {}];
  (* confidence 閾値で採否。低 confidence 検出は「読めるが伏せきれない」兆候 *)
  kept = Select[detected, NumericQ[Lookup[#, "confidence", 1.]] &&
    Lookup[#, "confidence", 1.] >= thr &];
  (* 宣言 Regions は必ず塗る + 検出領域を追加 (排他でない) *)
  allRegions = Join[declared, kept];
  redacted = If[allRegions === {}, img,
    SourceVaultAnonymizeImageRedact[img, allRegions]];
  (* V5: redaction 検出器と別系統の独立 verifier で残存を確認 *)
  v5 = SourceVaultAnonymizeVerifyRedactedImage[redacted, allRegions];
  residual = If[verFn === None, {},
    Quiet @ Check[verFn[redacted], {}]];
  If[!ListQ[residual], residual = {}];
  evidence = <|"Detector" -> If[scanFn === None, "None", "Local"],
    "DetectedCount" -> Length[detected],
    "KeptCount" -> Length[kept],
    "LowConfidenceCount" -> Length[detected] - Length[kept],
    "DeclaredCount" -> Length[declared],
    "V5" -> Lookup[v5, "Status", "?"],
    "IndependentResidualCount" -> Length[residual]|>;
  (* fail-closed: (a) 検出も宣言も無い (画像に何もしていない) / (b) 低 confidence 検出が
     あった (伏せきれていない懸念) / (c) V5 不合格 / (d) 独立 verifier が残存検出 *)
  status = Which[
    allRegions === {}, "NeedsReview",
    Length[detected] > Length[kept], "NeedsReview",
    Lookup[v5, "Status"] =!= "OK", "NeedsReview",
    residual =!= {}, "NeedsReview",
    True, "OK"];
  <|"Status" -> status,
    "Reason" -> Which[
      status === "OK", "Redacted",
      Length[detected] > Length[kept], "LowConfidenceDetection",
      allRegions === {}, "NoRegionsToRedact",
      Lookup[v5, "Status"] =!= "OK", "V5CompletenessFailed",
      residual =!= {}, "IndependentVerifierFoundResidual",
      True, "NeedsReview"],
    "Image" -> redacted, "Regions" -> allRegions, "Evidence" -> evidence|>];

(* ============================================================
   7c. C4: 答案 PDF 採点 (仕様 §12.1, §12.2, §14.3)
   ページ SourceUnit 化 -> 宣言 Regions + MediaScan 黒塗り (A6/A8) ->
   IdentityEvidence + adjudication -> EvaluationUnit (一受験者 = 全ページ) +
   ResultSlot (設問別) の Plan。identity 未確定は採点対象外 (fail-closed)。
   ============================================================ *)

(* CanonicalEncode v1 は Real を fail-closed で拒否する (§5.2)。OCR confidence や
   bounding box は Real なので、digest を取る前に決定論的な整数表現へ落とす。
   保存される snapshot 側は元の値のまま (digest だけが正規化表現を見る) *)
iSVACanonSafe[l_List] := iSVACanonSafe /@ l;
iSVACanonSafe[a_Association] :=
  Association[KeyValueMap[ToString[#1] -> iSVACanonSafe[#2] &, a]];
iSVACanonSafe[x_] := Which[
  StringQ[x] || IntegerQ[x] || x === True || x === False || x === Null ||
    Head[x] === ByteArray, x,
  NumericQ[x], "num:" <> IntegerString[Round[N[x] 1000000]],
  True, ToString[x, InputForm]];

iSVAImageDigest[img_Image] :=
  Quiet @ Check[Hash[ImageData[img, "Byte"], "SHA256", "HexString"], $Failed];

iSVAImageSpread[img_Image] := Module[{d},
  d = Quiet @ Check[Flatten[ImageData[img, "Byte"]], $Failed];
  If[!ListQ[d] || d === {}, $Failed, Max[d] - Min[d]]];

Options[SourceVaultAnonymizeBuildPageUnits] = {"BlankTolerance" -> 0};
SourceVaultAnonymizeBuildPageUnits[spec_Association, OptionsPattern[]] := Module[
    {pages, pdfDigest, objId, verId, tol, digests, units, dups, blanks},
  pages = Lookup[spec, "Pages", $Failed];
  pdfDigest = Lookup[spec, "PDFDigest", $Failed];
  objId = Lookup[spec, "SourceObjectID", $Failed];
  verId = ToString @ Lookup[spec, "SourceVersionID", "v1"];
  tol = OptionValue["BlankTolerance"];
  If[!ListQ[pages] || pages === {} || !StringQ[pdfDigest] || !StringQ[objId],
    Return[<|"Status" -> "Failed", "Reason" -> "MalformedPageSpec"|>]];
  If[!AllTrue[pages, Head[#] === Image &],
    Return[<|"Status" -> "Failed", "Reason" -> "NonImagePage"|>]];
  digests = iSVAImageDigest /@ pages;
  If[MemberQ[digests, $Failed],
    Return[<|"Status" -> "Failed", "Reason" -> "PageDigestFailed"|>]];
  units = MapIndexed[Function[{img, pos}, Module[
      {i = First[pos], dg, locDigest, contentLoc, sunit, cunit, spread, firstPos},
    dg = digests[[i]];
    (* 正準 locator = PDF 全体 digest + physical page index (§12.1) *)
    locDigest = SourceVaultAnonymizeCanonicalDigest[
      <|"PDFDigest" -> pdfDigest, "PhysicalPageIndex" -> i|>];
    (* 位置非依存の content locator: ページ順入替に不変 (digest ベースの頑健性) *)
    contentLoc = SourceVaultAnonymizeCanonicalDigest[
      <|"PDFDigest" -> pdfDigest, "PageContentDigest" -> dg|>];
    sunit = SourceVaultAnonymizeSourceUnitID[<|
      "SourceObjectID" -> objId, "SourceVersionID" -> verId,
      "SourceUnitKind" -> "pdf-page",
      "CanonicalLocatorDigest" -> locDigest, "SourceContentDigest" -> dg|>];
    cunit = SourceVaultAnonymizeSourceUnitID[<|
      "SourceObjectID" -> objId, "SourceVersionID" -> verId,
      "SourceUnitKind" -> "pdf-page-content",
      "CanonicalLocatorDigest" -> contentLoc, "SourceContentDigest" -> dg|>];
    spread = iSVAImageSpread[img];
    firstPos = FirstPosition[digests, dg];
    <|"PageIndex" -> i, "SourceUnitID" -> sunit, "ContentUnitID" -> cunit,
      "PageImageDigest" -> dg, "CanonicalLocatorDigest" -> locDigest,
      "Blank" -> (NumericQ[spread] && spread <= tol),
      "DuplicateOf" -> If[ListQ[firstPos] && First[firstPos] < i,
        First[firstPos], None]|>]],
    pages];
  If[MemberQ[Flatten[Lookup[units, {"SourceUnitID", "ContentUnitID"}]], $Failed],
    Return[<|"Status" -> "Failed", "Reason" -> "SourceUnitIDFailed"|>]];
  dups = Select[units, Lookup[#, "DuplicateOf"] =!= None &];
  blanks = Select[units, TrueQ[Lookup[#, "Blank"]] &];
  <|"Status" -> "OK", "PDFDigest" -> pdfDigest, "PageUnits" -> units,
    "PageCount" -> Length[units],
    "DuplicatePageCount" -> Length[dups], "BlankPageCount" -> Length[blanks],
    "PageUnitSetDigest" -> iSVALinSetDigest[Lookup[units, "SourceUnitID"]],
    "PageUnitContentSetDigest" ->
      iSVALinSetDigest[DeleteDuplicates[Lookup[units, "ContentUnitID"]]]|>];

(* --- C4b: IdentityEvidence (仕様 §12.2) --- *)

iSVANormID[s_] := ToUpperCase[StringReplace[ToString[s], Except[WordCharacter] -> ""]];
iSVANormName[s_] := StringReplace[ToString[s],
  (WhitespaceCharacter | "\:3000") -> ""];
iSVASubjectKey[normId_String] :=
  "subj:" <> StringTake[iSVASHA256Hex[normId], UpTo[16]];

Options[SourceVaultAnonymizeRecordIdentityEvidence] = {
  "Roster" -> {}, "ConfidenceThreshold" -> 0.8,
  "ExpectedSubjectCount" -> Automatic, "ExpectedPageCount" -> Automatic,
  "Engine" -> "unspecified", "EngineVersion" -> "unspecified", "Config" -> <||>};

SourceVaultAnonymizeRecordIdentityEvidence[candidates_List, OptionsPattern[]] := Module[
    {roster, thr, expSubj, expPages, rosterIdx, perCand, byKey, subjects,
     globalReasons = {}, state, rec, digest, ref, summary},
  If[candidates === {} || !AllTrue[candidates, AssociationQ],
    Return[<|"Status" -> "Failed", "Reason" -> "MalformedCandidates"|>]];
  roster = OptionValue["Roster"]; thr = OptionValue["ConfidenceThreshold"];
  expSubj = OptionValue["ExpectedSubjectCount"];
  expPages = OptionValue["ExpectedPageCount"];
  rosterIdx = If[ListQ[roster] && AllTrue[roster, AssociationQ],
    Association[Map[iSVANormID[Lookup[#, "StudentID", ""]] ->
      iSVANormName[Lookup[#, "StudentName", ""]] &, roster]], <||>];
  (* 候補ごとの fail-closed 判定 (OCR 出力を identity として即採用しない) *)
  perCand = MapIndexed[Function[{c, pos}, Module[{id, nm, conf, rs = {}},
      id = iSVANormID[Lookup[c, "StudentIDCandidate", ""]];
      nm = iSVANormName[Lookup[c, "StudentNameCandidate", ""]];
      conf = Lookup[c, "Confidence", 0.];
      If[!NumericQ[conf] || conf < thr, AppendTo[rs, "LowConfidence"]];
      If[id === "", AppendTo[rs, "AmbiguousPageBoundary"]];
      If[rosterIdx =!= <||> && id =!= "",
        Which[
          !KeyExistsQ[rosterIdx, id], AppendTo[rs, "IDNotInRoster"],
          nm =!= "" && rosterIdx[id] =!= nm, AppendTo[rs, "RosterNameMismatch"]]];
      <|"PageIndex" -> Lookup[c, "PageIndex", First[pos]],
        "SubjectKey" -> If[id === "", "unassigned", iSVASubjectKey[id]],
        "Confidence" -> If[NumericQ[conf], N[conf], 0.],
        "Reasons" -> rs|>]],
    candidates];
  (* subject 単位: ページの連続性 (冊子が分断されていないか) を検査 *)
  byKey = GroupBy[Select[perCand, Lookup[#, "SubjectKey"] =!= "unassigned" &],
    Lookup[#, "SubjectKey"] &];
  subjects = KeyValueMap[Function[{k, cs}, Module[{idx, rs},
      idx = Sort[Lookup[cs, "PageIndex"]];
      rs = DeleteDuplicates[Flatten[Lookup[cs, "Reasons"]]];
      If[Length[idx] =!= Length[DeleteDuplicates[idx]],
        AppendTo[rs, "DuplicatePageIndex"]];
      If[Length[DeleteDuplicates[idx]] > 1 &&
         Max[idx] - Min[idx] + 1 =!= Length[DeleteDuplicates[idx]],
        AppendTo[rs, "NonContiguousPages"]];
      <|"SubjectKey" -> k, "PageIndices" -> idx, "PageCount" -> Length[idx],
        "Reasons" -> DeleteDuplicates[rs],
        "State" -> If[DeleteDuplicates[rs] === {},
          "AutoConfirmed", "NeedsAdjudication"]|>]],
    byKey];
  If[AnyTrue[perCand, Lookup[#, "SubjectKey"] === "unassigned" &],
    AppendTo[globalReasons, "AmbiguousPageBoundary"]];
  If[IntegerQ[expSubj] && Length[subjects] =!= expSubj,
    AppendTo[globalReasons, "SubjectCountMismatch"]];
  If[IntegerQ[expPages] && Length[candidates] =!= expPages,
    AppendTo[globalReasons, "PageCountMismatch"]];
  state = If[globalReasons === {} &&
    AllTrue[subjects, Lookup[#, "State"] === "AutoConfirmed" &],
    "AutoConfirmed", "NeedsAdjudication"];
  (* 実体 (raw text・氏名・学籍番号) は PL 1.0 snapshot 内にのみ置く *)
  rec = <|"ObjectClass" -> "IdentityEvidence", "SchemaVersion" -> 1,
    "Engine" -> ToString @ OptionValue["Engine"],
    "EngineVersion" -> ToString @ OptionValue["EngineVersion"],
    "Config" -> OptionValue["Config"],
    "ConfidenceThreshold" -> N[thr],
    "RosterSize" -> Length[rosterIdx],
    "Candidates" -> candidates,
    "PerCandidate" -> perCand,
    "Subjects" -> subjects,
    "GlobalReasons" -> globalReasons,
    "State" -> state,
    "CreatedAtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>;
  digest = SourceVaultAnonymizeCanonicalDigest[iSVACanonSafe[rec]];
  If[!StringQ[digest],
    Return[<|"Status" -> "Failed", "Reason" -> "NonCanonicalEvidence"|>]];
  ref = iSVASaveSnapshotAs["IdentityEvidence",
    Append[rec, "EvidenceDigest" -> digest], 1.0];
  If[!StringQ[ref],
    Return[<|"Status" -> "Failed", "Reason" -> "EvidenceSaveFailed"|>]];
  (* 戻り値は ref + SubjectKey + reason code のみ (§12.2: 実体を入れない) *)
  summary = Map[KeyTake[#, {"SubjectKey", "PageIndices", "PageCount",
    "Reasons", "State"}] &, subjects];
  <|"Status" -> "OK", "EvidenceRef" -> ref, "EvidenceDigest" -> digest,
    "State" -> state, "SubjectCount" -> Length[subjects],
    "Subjects" -> summary, "GlobalReasons" -> globalReasons,
    "NeedsAdjudicationKeys" ->
      Lookup[Select[subjects, Lookup[#, "State"] =!= "AutoConfirmed" &],
        "SubjectKey", {}]|>];

(* --- C4c: adjudication (append-only。原本 digest と候補を pin) --- *)

If[!ValueQ[$iSVAIdentityEventPathOverride], $iSVAIdentityEventPathOverride = Automatic];

iSVAIdentityEventPath[] := Which[
  StringQ[$iSVAIdentityEventPathOverride], $iSVAIdentityEventPathOverride,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r],
      FileNameJoin[{r, "config", "anonymize-identity-adjudications.jsonl"}], $Failed]],
  True, $Failed];

iSVAIdentityEventAppend[ev_Association] := Module[
    {path = iSVAIdentityEventPath[], strm, ok = False},
  If[path === $Failed, Return[False]];
  Quiet @ Check[
    (If[!DirectoryQ[DirectoryName[path]], CreateDirectory[DirectoryName[path]]];
     strm = OpenAppend[path, BinaryFormat -> True];
     If[Head[strm] === OutputStream,
       BinaryWrite[strm, StringToByteArray[
         ExportString[ev, "RawJSON", "Compact" -> True] <> "\n", "UTF-8"]];
       Close[strm]; ok = True]), Null];
  (* 監査系へは弱結合 emit (実体は入れず ref/SubjectKey のみ) *)
  If[ok, iSVAPubEventAppend[ev]];
  ok];

iSVAIdentityEventsFor[evidenceRef_String, evidenceDigest_String] := Module[
    {path = iSVAIdentityEventPath[], lines},
  If[path === $Failed || !FileExistsQ[path], Return[{}]];
  lines = Quiet @ Check[Import[path, {"Text", "Lines"}], {}];
  Select[Map[Quiet @ Check[ImportString[#, "RawJSON"], $Failed] &, lines],
    AssociationQ[#] &&
      Lookup[#, "EventClass"] === "AnonymizeIdentityAdjudicated" &&
      Lookup[#, "EvidenceRef"] === evidenceRef &&
      Lookup[#, "EvidenceDigest"] === evidenceDigest &]];

SourceVaultAnonymizeAdjudicateIdentity[evidenceRef_String, decision_Association] :=
  Module[{ev, subjKey, dec, subj, evDigest, event, evRef},
  If[!iSVAInteractiveOwnerQ[],
    Return[<|"Status" -> "Failed", "Reason" -> "NonInteractiveMutationRefused"|>]];
  ev = iSVAMapLoadByRef[evidenceRef];
  If[!AssociationQ[ev] || Lookup[ev, "ObjectClass"] =!= "IdentityEvidence",
    Return[<|"Status" -> "Failed", "Reason" -> "EvidenceUnreadable"|>]];
  evDigest = Lookup[ev, "EvidenceDigest", $Failed];
  If[!StringQ[evDigest],
    Return[<|"Status" -> "Failed", "Reason" -> "EvidenceDigestMissing"|>]];
  subjKey = Lookup[decision, "SubjectKey", $Failed];
  dec = Lookup[decision, "Decision", $Failed];
  If[!StringQ[subjKey] || !MemberQ[{"Confirmed", "Rejected"}, dec],
    Return[<|"Status" -> "Failed", "Reason" -> "MalformedDecision"|>]];
  subj = SelectFirst[Lookup[ev, "Subjects", {}],
    Lookup[#, "SubjectKey", ""] === subjKey &, $Failed];
  If[subj === $Failed,
    Return[<|"Status" -> "Failed", "Reason" -> "UnknownSubjectKey"|>]];
  event = <|"EventClass" -> "AnonymizeIdentityAdjudicated",
    "EvidenceRef" -> evidenceRef, "EvidenceDigest" -> evDigest,
    "SubjectKey" -> subjKey, "Decision" -> dec,
    "CandidateDigest" -> SourceVaultAnonymizeCanonicalDigest[iSVACanonSafe[subj]],
    "PriorState" -> Lookup[subj, "State", "?"],
    "Adjudicator" -> ToString @ Lookup[decision, "Adjudicator", "unspecified"],
    "Note" -> ToString @ Lookup[decision, "Note", ""],
    "AtUTC" -> DateString[Now, "ISODateTime", TimeZone -> 0] <> "Z"|>;
  If[!TrueQ[iSVAIdentityEventAppend[event]],
    Return[<|"Status" -> "Failed", "Reason" -> "AdjudicationLogWriteFailed"|>]];
  evRef = iSVASaveSnapshotAs["IdentityAdjudicationEvent",
    Join[<|"ObjectClass" -> "IdentityAdjudicationEvent", "SchemaVersion" -> 1|>,
      event], 1.0];
  <|"Status" -> "OK", "Decision" -> dec, "SubjectKey" -> subjKey,
    "EventRef" -> If[StringQ[evRef], evRef, "unsaved"],
    "EvidenceDigest" -> evDigest|>];

SourceVaultAnonymizeIdentityStatus[evidenceRef_String] := Module[
    {ev, evDigest, subjects, events, byKey, folded, pending, confirmed, rejected},
  ev = iSVAMapLoadByRef[evidenceRef];
  If[!AssociationQ[ev] || Lookup[ev, "ObjectClass"] =!= "IdentityEvidence",
    Return[<|"Status" -> "Failed", "Reason" -> "EvidenceUnreadable"|>]];
  evDigest = Lookup[ev, "EvidenceDigest", ""];
  subjects = Lookup[ev, "Subjects", {}];
  events = iSVAIdentityEventsFor[evidenceRef, evDigest];
  byKey = GroupBy[events, Lookup[#, "SubjectKey"] &];
  (* 全体理由 (員数不一致・ページ境界曖昧) はページ↔受験者の対応そのものを疑わせる。
     §12.2「自動確定しない」= 個々の subject の AutoConfirmed も無効化し、
     オーナーの明示 adjudication だけが確定手段になる (fail-closed) *)
  folded = Map[Function[s, Module[{k, evs, last, final},
      k = Lookup[s, "SubjectKey", ""];
      evs = Lookup[byKey, k, {}];
      last = If[evs === {}, None, Last[evs]];  (* append-only: 最後の決定が有効 *)
      final = Which[
        last =!= None && Lookup[last, "Decision"] === "Rejected", "Rejected",
        last =!= None && Lookup[last, "Decision"] === "Confirmed", "Confirmed",
        Lookup[s, "State"] === "AutoConfirmed" &&
          Lookup[ev, "GlobalReasons", {}] === {}, "Confirmed",
        True, "Pending"];
      <|"SubjectKey" -> k, "PageIndices" -> Lookup[s, "PageIndices", {}],
        "InitialState" -> Lookup[s, "State", "?"],
        "Reasons" -> Lookup[s, "Reasons", {}],
        "AdjudicationCount" -> Length[evs], "FinalState" -> final|>]],
    subjects];
  confirmed = Lookup[Select[folded, Lookup[#, "FinalState"] === "Confirmed" &],
    "SubjectKey", {}];
  pending = Lookup[Select[folded, Lookup[#, "FinalState"] === "Pending" &],
    "SubjectKey", {}];
  rejected = Lookup[Select[folded, Lookup[#, "FinalState"] === "Rejected" &],
    "SubjectKey", {}];
  (* 全体の未確定判定には evidence 全体の fail-closed 理由も含める *)
  <|"Status" -> "OK",
    "State" -> If[pending === {} && Lookup[ev, "GlobalReasons", {}] === {},
      "Resolved", "NeedsAdjudication"],
    "Subjects" -> folded, "ConfirmedSubjectKeys" -> confirmed,
    "PendingSubjectKeys" -> pending, "RejectedSubjectKeys" -> rejected,
    "GlobalReasons" -> Lookup[ev, "GlobalReasons", {}]|>];

(* --- C4d: 答案ページの黒塗り成果物 (A6 + A8) --- *)

Options[SourceVaultAnonymizeAnswerSheetPages] = {
  "DeclaredRegions" -> {}, "MediaScanFn" -> None,
  "ConfidenceThreshold" -> 0.5, "IndependentVerifierFn" -> None};

SourceVaultAnonymizeAnswerSheetPages[pages_List, OptionsPattern[]] := Module[
    {reports, okOnes, excluded},
  If[pages === {} || !AllTrue[pages, Head[#] === Image &],
    Return[<|"Status" -> "Failed", "Reason" -> "NonImagePage"|>]];
  reports = MapIndexed[Function[{img, pos}, Module[{r},
      r = SourceVaultAnonymizeMediaScan[img,
        "DeclaredRegions" -> OptionValue["DeclaredRegions"],
        "MediaScanFn" -> OptionValue["MediaScanFn"],
        "ConfidenceThreshold" -> OptionValue["ConfidenceThreshold"],
        "IndependentVerifierFn" -> OptionValue["IndependentVerifierFn"]];
      <|"PageIndex" -> First[pos], "Status" -> Lookup[r, "Status", "NeedsReview"],
        "Reason" -> Lookup[r, "Reason", "Unknown"],
        "Evidence" -> Lookup[r, "Evidence", <||>],
        "Image" -> Lookup[r, "Image", img]|>]],
    pages];
  okOnes = Select[reports, Lookup[#, "Status"] === "OK" &];
  excluded = Lookup[Select[reports, Lookup[#, "Status"] =!= "OK" &], "PageIndex", {}];
  <|"Status" -> If[excluded === {}, "OK", "NeedsReview"],
    "Format" -> "PageImageList",
    "Pages" -> Lookup[okOnes, "Image", {}],
    "PageIndices" -> Lookup[okOnes, "PageIndex", {}],
    "PageReports" -> Map[KeyDrop[#, "Image"] &, reports],
    "ExcludedPages" -> excluded|>];

(* --- C4e: 答案採点 Plan (EvaluationUnit = 一受験者の全ページ / ResultSlot = 設問別) --- *)

Options[SourceVaultAnonymizeAnswerSheetPlan] = {"IdentityEvidenceRef" -> None};

SourceVaultAnonymizeAnswerSheetPlan[spec_Association, OptionsPattern[]] := Module[
    {subjects, evRef, st, confirmed, included, excludedSubs, units, plan},
  subjects = Lookup[spec, "Subjects", $Failed];
  If[!ListQ[subjects] || subjects === {} || !AllTrue[subjects, AssociationQ],
    Return[<|"Status" -> "Failed", "Reason" -> "MalformedSubjects"|>]];
  evRef = OptionValue["IdentityEvidenceRef"];
  If[StringQ[evRef],
    st = SourceVaultAnonymizeIdentityStatus[evRef];
    If[Lookup[st, "Status"] =!= "OK", Return[st]];
    confirmed = Lookup[st, "ConfirmedSubjectKeys", {}],
    (* evidence 未指定 = identity 検証を経ていない。呼び出し側の責任で全件 *)
    confirmed = Automatic];
  included = If[confirmed === Automatic, subjects,
    Select[subjects, MemberQ[confirmed, Lookup[#, "SubjectKey", ""]] &]];
  excludedSubs = If[confirmed === Automatic, {},
    Select[subjects, !MemberQ[confirmed, Lookup[#, "SubjectKey", ""]] &]];
  If[included === {},
    Return[<|"Status" -> "Failed", "Reason" -> "NoConfirmedSubjects",
      "ExcludedUnits" -> Map[<|"SubjectKey" -> Lookup[#, "SubjectKey", "?"],
        "Reason" -> "IdentityNotConfirmed"|> &, excludedSubs]|>]];
  units = Map[Function[s, <|
      "ItemTokens" -> Lookup[s, "ItemTokens", {}],
      "SubjectToken" -> Lookup[s, "SubjectToken", "unspecified"],
      "ResultSlots" -> Lookup[s, "Slots", {}],
      "AttemptID" -> Lookup[s, "AttemptID", "attempt-1"]|>], included];
  plan = SourceVaultAnonymizeBuildEvaluationPlan[<|
    "TargetArtifactRef" -> Lookup[spec, "TargetArtifactRef", $Failed],
    "ArtifactBindingRef" -> Lookup[spec, "ArtifactBindingRef", $Failed],
    "RubricDigest" -> Lookup[spec, "RubricDigest", "unspecified"],
    "RequestDigest" -> Lookup[spec, "RequestDigest", "unspecified"],
    "DistributionPlanRef" -> Lookup[spec, "DistributionPlanRef", "unspecified"],
    "Units" -> units|>];
  If[Lookup[plan, "Status"] =!= "OK", Return[plan]];
  Join[plan, <|
    "IncludedSubjectCount" -> Length[included],
    "ExcludedUnits" -> Map[<|"SubjectKey" -> Lookup[#, "SubjectKey", "?"],
      "Reason" -> "IdentityNotConfirmed"|> &, excludedSubs],
    "IdentityEvidenceRef" -> If[StringQ[evRef], evRef, "none"]|>]];

(* ============================================================
   8. A0: ポリシー registry (仕様 §5.1, §6.1)
   ============================================================ *)

If[!ValueQ[$iSVAPolicyRegistryOverride], $iSVAPolicyRegistryOverride = Automatic];

iSVAPolicyRegistryPath[] := Which[
  StringQ[$iSVAPolicyRegistryOverride], $iSVAPolicyRegistryOverride,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r], FileNameJoin[{r, "config", "anonymize-policies.json"}], $Failed]],
  True, $Failed];

SourceVaultRegisterAnonymizationPolicy[policy_Association] := Module[
    {pid, tiers, ref, path, reg, pl},
  pid = Lookup[policy, "PolicyId", $Failed];
  tiers = Lookup[policy, "Tiers", $Failed];
  If[!StringQ[pid] || !AssociationQ[tiers] || tiers === <||>,
    Return[<|"Status" -> "Failed", "Reason" -> "MalformedPolicy"|>]];
  pl = Lookup[policy, "PolicyPrivacyLevel", 0.5];
  ref = iSVASaveSnapshotAs["AnonymizationPolicy",
    Join[<|"ObjectClass" -> "AnonymizationPolicy", "SchemaVersion" -> 1|>,
      KeyDrop[policy, "PolicyPrivacyLevel"]],
    N[pl]];
  If[!StringQ[ref], Return[<|"Status" -> "Failed", "Reason" -> "PolicySaveFailed"|>]];
  path = iSVAPolicyRegistryPath[];
  If[path === $Failed,
    Return[<|"Status" -> "Failed", "Reason" -> "RegistryUnavailable"|>]];
  reg = If[FileExistsQ[path], Quiet @ Check[Import[path, "RawJSON"], <||>], <||>];
  If[!AssociationQ[reg], reg = <||>];
  reg[pid] = ref;
  Quiet @ Check[
    (If[!DirectoryQ[DirectoryName[path]], CreateDirectory[DirectoryName[path]]];
     Export[path, reg, "RawJSON"]), Null];
  <|"Status" -> "OK", "PolicyId" -> pid, "PolicyRef" -> ref,
    "PolicyDigest" -> Last[StringSplit[ref, ":"]]|>];

SourceVaultAnonymizationPolicies[] := Module[{path = iSVAPolicyRegistryPath[], reg},
  If[path === $Failed || !FileExistsQ[path], Return[<||>]];
  reg = Quiet @ Check[Import[path, "RawJSON"], <||>];
  If[AssociationQ[reg], reg, <||>]];

SourceVaultAnonymizationPolicy[idOrRef_String] := Module[{ref, pol},
  ref = If[StringStartsQ[idOrRef, "snapshot:"] || StringStartsQ[idOrRef, "sv://"],
    idOrRef, Lookup[SourceVaultAnonymizationPolicies[], idOrRef, $Failed]];
  If[!StringQ[ref],
    Return[<|"Status" -> "Failed", "Reason" -> "PolicyNotRegistered"|>]];
  pol = iSVAMapLoadByRef[ref];
  If[!AssociationQ[pol],
    Return[<|"Status" -> "Failed", "Reason" -> "PolicyUnreadable"|>]];
  Join[pol, <|"Status" -> "OK", "PolicyRef" -> ref,
    "PolicyDigest" -> Last[StringSplit[ref, ":"]]|>]];

iSVAAvailablePolicies[] := Keys[SourceVaultAnonymizationPolicies[]];

(* ============================================================
   9. A1-A3: SourceVaultAnonymize 本体 (仕様 §8)
   Records dispatch (Association / list / <|"Rows"->...|>)。
   ============================================================ *)

If[!ValueQ[$iSVACacheDirOverride], $iSVACacheDirOverride = Automatic];
iSVACacheDir[] := Which[
  StringQ[$iSVACacheDirOverride], $iSVACacheDirOverride,
  Names["SourceVault`SourceVaultRoot"] =!= {},
  With[{r = Quiet @ Check[SourceVault`SourceVaultRoot["PrivateVault"], $Failed]},
    If[StringQ[r], FileNameJoin[{r, "config", "anonymize-cache"}], $Failed]],
  True, $Failed];

(* 一般化階層 5 種 (仕様 §6.5)。文字列前提。判定不能は元値 *)
iSVAApplyGeneralize[val_, "timestamp->date"] :=
  If[StringQ[val] && StringLength[val] >= 10, StringTake[val, 10], val];
iSVAApplyGeneralize[val_, "timestamp->week"] :=
  If[StringQ[val] && StringLength[val] >= 10,
    Quiet @ Check[DateString[DateObject[StringTake[val, 10]], "ISOWeekDate"] //
      (StringTake[#, 8] &), StringTake[val, 7]], val];
iSVAApplyGeneralize[val_, "date->month"] :=
  If[StringQ[val] && StringLength[val] >= 7, StringTake[val, 7], val];
iSVAApplyGeneralize[val_, "age->decade"] := Module[{n},
  n = Quiet @ Check[ToExpression[ToString[val]], $Failed];
  If[IntegerQ[n], ToString[10 Floor[n/10]] <> "s", val]];
iSVAApplyGeneralize[val_, "dept->faculty"] := val;  (* 既定は恒等 (階層は policy で拡張) *)
iSVAApplyGeneralize[val_, _] := val;

(* k 匿名性検査 (仕様 §6.5, §9.2 V4)。rows: 変換後の行 (Association list)。
   qids: 準識別子キー列。返り値: <|Status, Violations, Rows|>。
   OnFail: "Suppress"(違反行の qid を repl 化)/ "GeneralizeUp"(全 qid を 1 段粗く)/ "Fail" *)
iSVAKAnonymityCheck[rows_List, kspec_Association, repl_String] := Module[
    {k, qids, onFail, genUp, classes, violators, out},
  k = Lookup[kspec, "K", 1];
  qids = Lookup[kspec, "QuasiIdentifiers", {}];
  onFail = Lookup[kspec, "OnFail", "Suppress"];
  genUp = Lookup[kspec, "GeneralizeUp", <||>];
  If[!(IntegerQ[k] && k >= 2 && qids =!= {}),
    Return[<|"Status" -> "OK", "Rows" -> rows, "Violations" -> 0|>]];
  classes[rws_] := GatherBy[Range[Length[rws]],
    Function[i, Lookup[rws[[i]], qids, Missing[]]]];
  violators[rws_] := Flatten[Select[classes[rws], Length[#] < k &]];
  Which[
    violators[rows] === {},
    <|"Status" -> "OK", "Rows" -> rows, "Violations" -> 0|>,
    onFail === "Fail",
    <|"Status" -> "Failed", "Reason" -> "KAnonymityViolation",
      "Violations" -> Length[violators[rows]]|>,
    onFail === "GeneralizeUp",
    Module[{r2 = rows},
      r2 = Map[Function[row, Module[{r = row},
        KeyValueMap[Function[{attr, hier},
          If[MemberQ[qids, attr] && KeyExistsQ[r, attr],
            r[attr] = iSVAApplyGeneralize[r[attr], hier]]], genUp]; r]], r2];
      If[violators[r2] === {},
        <|"Status" -> "OK", "Rows" -> r2, "Violations" -> 0, "Generalized" -> True|>,
        (* まだ違反 -> Suppress にフォールバック *)
        out = MapIndexed[Function[{row, idx}, If[MemberQ[violators[r2], First[idx]],
          Module[{r = row}, Scan[(r[#] = repl) &, qids]; r], row]], r2];
        <|"Status" -> "OK", "Rows" -> out, "Violations" -> 0,
          "Suppressed" -> True|>]],
    True,  (* Suppress (既定) *)
    out = MapIndexed[Function[{row, idx}, If[MemberQ[violators[rows], First[idx]],
      Module[{r = row}, Scan[(r[#] = repl) &, qids]; r], row]], rows];
    <|"Status" -> "OK", "Rows" -> out, "Violations" -> 0, "Suppressed" -> True|>]];

(* KnownValueScan + Patterns。pairs: {knownString -> subjectToken...} (長い順) *)
iSVAApplyTextRules[s_String, pairs_List, patterns_List, repl_String] := Module[{t = s},
  t = StringReplace[t, pairs];
  t = Fold[StringReplace[#1, RegularExpression[#2] -> repl] &, t, patterns];
  t];

(* パスパターン照合 (L4)。"." 区切り。"*" は 1 セグメントの任意にマッチ。
   例: "Detail.Files.*.URL" は "Detail.Files.0.URL" 等にマッチ。 *)
iSVAPathMatchQ[pattern_String, path_String] := Module[{pp, ps},
  pp = StringSplit[pattern, "."]; ps = StringSplit[path, "."];
  Length[pp] === Length[ps] &&
    AllTrue[Transpose[{pp, ps}], (#[[1]] === "*" || #[[1]] === #[[2]]) &]];

(* path に最も具体的にマッチする FieldRule キー ("*" が少ないほど具体的) *)
iSVAMatchRuleKey[rules_Association, path_String] := Module[{hits},
  hits = Select[Keys[rules], iSVAPathMatchQ[#, path] &];
  If[hits === {}, Missing[], First[SortBy[hits, StringCount[#, "*"] &]]]];

iSVATextScan[v_, textPairs_, patterns_, repl_, scanFn_] :=
  If[StringQ[v],
    Module[{t = iSVAApplyTextRules[v, textPairs, patterns, repl]},
      If[scanFn =!= None,
        Module[{spans = Quiet @ Check[scanFn[t], {}]},
          If[ListQ[spans],
            Fold[StringReplace[#1, #2 -> repl] &, t, Select[spans, StringQ]], t]],
        t]], v];

(* 再帰 walk。value を path のルールで変換。Nothing は親から除去される。 *)
iSVAWalkNode[value_, path_String, rules_Association, defRule_String,
    tokenOf_Association, textPairs_List, patterns_List, repl_String, scanFn_] :=
  Module[{mk = iSVAMatchRuleKey[rules, path], rule},
    rule = If[MissingQ[mk], Missing[], rules[mk]];
    Which[
      (* 明示ルール: 中間ノード (Association/List) にも適用しサブツリーごと処理 *)
      rule === "Drop", Nothing,
      rule === "Redact", repl,
      rule === "KeepRaw", value,
      MatchQ[rule, {"Pseudonym", _, _}], Lookup[tokenOf, ToString[value], repl],
      MatchQ[rule, {"Generalize", _}], iSVAApplyGeneralize[value, rule[[2]]],
      (* Keep もしくは未指定 container: 再帰。子は個別ルール優先・無ければ default *)
      AssociationQ[value],
      DeleteCases[
        Association[KeyValueMap[Function[{k, v},
          k -> iSVAWalkNode[v, path <> "." <> ToString[k], rules, defRule,
            tokenOf, textPairs, patterns, repl, scanFn]], value]], Nothing],
      ListQ[value],
      DeleteCases[MapIndexed[
        iSVAWalkNode[#1, path <> "." <> ToString[First[#2] - 1], rules, defRule,
          tokenOf, textPairs, patterns, repl, scanFn] &, value], Nothing],
      (* leaf: Keep(明示) は text scan。未指定は default に従う *)
      rule === "Keep", iSVATextScan[value, textPairs, patterns, repl, scanFn],
      True, Switch[defRule,
        "Drop", Nothing, "KeepRaw", value,
        "Keep", iSVATextScan[value, textPairs, patterns, repl, scanFn],
        _, repl]]];

iSVAAnonymizeRow[row_Association, tier_Association, tokenOf_Association,
    textPairs_List, patterns_List, repl_String, scanFn_] := Module[{rules, defRule},
  rules = Lookup[tier, "FieldRules", <||>];
  defRule = Lookup[tier, "DefaultFieldRule", "Redact"];
  DeleteCases[
    Association[KeyValueMap[Function[{k, v},
      k -> iSVAWalkNode[v, ToString[k], rules, defRule,
        tokenOf, textPairs, patterns, repl, scanFn]], row]], Nothing]];

Options[SourceVaultAnonymize] = {
  "GrantRef" -> None, "TargetLevel" -> Automatic, "Policy" -> Automatic,
  "Purpose" -> None, "IntendedSink" -> None,
  "PrivateModelScanFn" -> None, "VerifyFn" -> None, "Force" -> False};

SourceVaultAnonymize[origRef_String, OptionsPattern[]] := Module[
    {grant, plan, tl, policy, tier, cacheId, cachePath, cached, request, gv, lease,
     origin, rows, pseudoFields, identities, mapSpec, asg, mapEntries, tokenOf,
     textPairs, patterns, repl, scanFn, verifyFn, needScan, anonRows, itemToks,
     srcNodes, derNodes, edges, manifest, mref, art, bind, pub, knownAll, vfail,
     policyId, subjOf, kres},
  grant = OptionValue["GrantRef"];
  (* --- 段 0a: 本文非読の認可 --- *)
  If[!AssociationQ[grant],
    Return[<|"Status" -> "Failed", "Reason" -> "NeedsOwnerApproval",
      "Hint" -> "Run SourceVaultAnonymizationPlan -> RequestDeclassification -> ApproveDeclassification first."|>]];
  plan = SourceVaultAnonymizationPlan[origRef];
  If[Lookup[plan, "Status"] =!= "OK",
    Return[<|"Status" -> "Failed", "Reason" -> "PlanFailed", "Detail" -> plan|>]];
  tl = OptionValue["TargetLevel"];
  If[tl === Automatic, tl = Lookup[grant, "ExactTargetLevel", $Failed]];
  request = <|"OriginSetDigest" -> plan["OriginSetDigest"],
    "TargetLevel" -> tl,
    "Purpose" -> If[OptionValue["Purpose"] === None,
      Lookup[grant, "Purpose"], OptionValue["Purpose"]],
    "IntendedSink" -> If[OptionValue["IntendedSink"] === None,
      Lookup[grant, "IntendedSink"], OptionValue["IntendedSink"]],
    "PolicyDigest" -> Lookup[grant, "PolicyDigest", "unspecified"]|>;
  gv = SourceVaultVerifyDeclassificationGrant[grant, request];
  If[gv["Status"] =!= "OK", Return[gv]];
  (* --- policy 解決 --- *)
  policyId = If[OptionValue["Policy"] === Automatic,
    Lookup[grant, "PolicyRef", "unspecified"], OptionValue["Policy"]];
  policy = SourceVaultAnonymizationPolicy[policyId];
  If[Lookup[policy, "Status"] =!= "OK", Return[policy]];
  tier = Lookup[Lookup[policy, "Tiers", <||>], tl, $Failed];
  If[!AssociationQ[tier],
    Return[<|"Status" -> "Failed", "Reason" -> "TierNotDefined",
      "TargetLevel" -> tl|>]];
  (* --- cache --- *)
  cacheId = SourceVaultAnonymizeCanonicalDigest[<|
    "OriginSetDigest" -> plan["OriginSetDigest"],
    "PolicyDigest" -> policy["PolicyDigest"], "TargetLevel" -> tl,
    "EngineVersion" -> $SourceVaultAnonymizeEngineVersion,
    "CanonicalizationVersion" -> $SourceVaultAnonymizeCanonicalizationVersion|>];
  cachePath = With[{d = iSVACacheDir[]},
    If[d === $Failed, $Failed, FileNameJoin[{d, StringTake[cacheId, 40] <> ".json"}]]];
  If[!TrueQ[OptionValue["Force"]] && cachePath =!= $Failed && FileExistsQ[cachePath],
    cached = Quiet @ Check[Import[cachePath, "RawJSON"], $Failed];
    If[AssociationQ[cached] && StringQ[Lookup[cached, "ArtifactRef"]],
      With[{st = SourceVaultAnonymizePublicationStatus[cached["ArtifactRef"]]},
        If[Lookup[st, "State", "?"] === "Published",
          Return[<|"Status" -> "OK", "ArtifactRef" -> cached["ArtifactRef"],
            "PublicationState" -> "Published", "CacheHit" -> True,
            "MapRef" -> Lookup[cached, "MapRef", "unspecified"]|>]]]]];
  (* --- lease (crash retry は同一 identity で冪等) --- *)
  lease = SourceVaultConsumeDeclassificationGrantUse[grant, "anonymize:" <> cacheId];
  If[lease["Status"] =!= "OK", Return[lease]];
  (* --- 段 0b: exact origin open --- *)
  origin = iSVAMapLoadByRef[First[plan["Origins"]]["OriginRef"]];
  If[!AssociationQ[origin],
    Return[<|"Status" -> "Failed", "Reason" -> "OriginUnreadable"|>]];
  rows = Which[
    KeyExistsQ[origin, "Rows"] && ListQ[origin["Rows"]], origin["Rows"],
    True, {origin}];
  rows = Select[rows, AssociationQ];
  If[rows === {}, Return[<|"Status" -> "Failed", "Reason" -> "NoRows"|>]];
  (* --- Pseudonymize: FieldRules の Pseudonym 指定から Identity 収集 --- *)
  pseudoFields = Select[Normal[Lookup[tier, "FieldRules", <||>]],
    MatchQ[#[[2]], {"Pseudonym", _, _}] &];
  identities = If[pseudoFields === {}, {},
    DeleteDuplicatesBy[Map[Function[row, Module[{idv, ident},
        ident = Association[Map[#[[2, 3]] -> ToString[Lookup[row, #[[1]], ""]] &,
          pseudoFields]];
        idv = Lookup[ident, "StudentID", First[Values[ident]]];
        <|"Institution" -> Lookup[Lookup[policy, "PseudonymRules", <||>],
            "Institution", "unspecified"],
          "CanonicalID" -> idv, "Identity" -> ident,
          "KnownStrings" -> Values[ident]|>]], rows],
      #["CanonicalID"] &]];
  mapSpec = Module[{pr = Lookup[policy, "PseudonymRules", <||>], scopeKey, scope},
    scopeKey = Lookup[pr, "MapScopeKey", None];
    scope = Which[
      StringQ[scopeKey] && rows =!= {} &&
        StringQ[Lookup[First[rows], scopeKey]],
      "scope:" <> Lookup[First[rows], scopeKey],
      StringQ[Lookup[pr, "MapScope"]], pr["MapScope"],
      True, "origin:" <> plan["OriginSetDigest"]];
    <|"EntityClass" -> Lookup[pr, "EntityClass", "Subject"], "MapScope" -> scope|>];
  asg = If[identities === {},
    <|"Status" -> "OK", "MapRef" -> "unspecified", "Assignments" -> <||>|>,
    SourceVaultAnonymizeAssignSubjectTokens[mapSpec, identities]];
  If[asg["Status"] =!= "OK", Return[asg]];
  (* token 対応表 (値 -> SubjectToken) と KnownStrings 置換 pairs *)
  mapEntries = If[asg["MapRef"] === "unspecified", {},
    Lookup[SourceVaultAnonymizePseudonymMap[asg["MapRef"]], "Entries", {}]];
  tokenOf = Association @ Flatten @ Map[Function[e,
    Map[# -> e["SubjectToken"] &,
      DeleteDuplicates[Join[Select[Values[Lookup[e, "Identity", <||>]], StringQ],
        Lookup[e, "KnownStrings", {}]]]]], mapEntries];
  textPairs = ReverseSortBy[Normal[tokenOf], StringLength[#[[1]]] &];
  knownAll = Keys[tokenOf];
  patterns = Lookup[Lookup[tier, "TextRules", <||>], "Patterns", {}];
  repl = Lookup[Lookup[tier, "TextRules", <||>], "Replacement", "[REDACTED]"];
  needScan = TrueQ[Lookup[Lookup[tier, "TextRules", <||>], "PrivateModelScan", False]];
  scanFn = OptionValue["PrivateModelScanFn"];
  verifyFn = OptionValue["VerifyFn"];
  If[needScan && (scanFn === None || verifyFn === None),
    Return[<|"Status" -> "NeedsReview", "Reason" -> "PrivateModelScanUnavailable",
      "Hint" -> "Policy requires local-LLM scan; inject PrivateModelScanFn and VerifyFn."|>]];
  (* --- 行変換 + ItemToken 採番 --- *)
  subjOf = Function[row, Module[{pf = If[pseudoFields === {}, None,
      First[pseudoFields]]},
    If[pf === None, "unspecified",
      Lookup[tokenOf, ToString[Lookup[row, pf[[1]], ""]], "unspecified"]]]];
  (* --- 行変換 (ItemToken 採番前) --- *)
  anonRows = iSVAAnonymizeRow[#, tier, tokenOf, textPairs, patterns, repl, scanFn] & /@ rows;
  (* --- k 匿名性 (V4)。qid の同値類が k 未満なら Suppress/GeneralizeUp/Fail --- *)
  kres = iSVAKAnonymityCheck[anonRows, Lookup[tier, "KAnonymity", <||>], repl];
  If[Lookup[kres, "Status"] =!= "OK",
    Return[<|"Status" -> "Failed",
      "Reason" -> Lookup[kres, "Reason", "KAnonymityViolation"]|>]];
  anonRows = kres["Rows"];
  (* --- ItemToken 採番 + lineage 構築 (k 匿名性適用後の行に対して) --- *)
  itemToks = {}; srcNodes = {}; derNodes = {}; edges = {};
  anonRows = MapIndexed[Function[{anon0, idx}, Module[
      {i = First[idx], row, anon = anon0, itok, sunit, dunit, subj},
    row = rows[[i]];
    itok = SourceVaultAnonymizeGenerateToken["Item"];
    subj = subjOf[row];
    anon["ItemToken"] = itok;
    If[subj =!= "unspecified", anon["SubjectToken"] = subj];
    sunit = "sunit:" <> StringTake[iSVASHA256Hex[
      plan["OriginSetDigest"] <> ToString[i]], 24];
    dunit = "dunit:" <> StringTake[iSVASHA256Hex[itok], 24];
    AppendTo[itemToks, itok];
    AppendTo[srcNodes, <|"UnitID" -> sunit,
      "ObjectID" -> "sobj:" <> StringTake[iSVASHA256Hex[ToString[i]], 16],
      "VersionID" -> plan["OriginSetDigest"],
      "Locator" -> <|"Kind" -> "AssociationRow", "CanonicalPath" -> {"Rows", i}|>,
      "ContentDigest" -> iSVASHA256Hex[ToString[Hash[row]]]|>];
    AppendTo[derNodes, <|"UnitID" -> dunit, "ItemToken" -> itok,
      "SubjectToken" -> subj, "Role" -> "RedactedRecord",
      "ContentDigest" -> iSVASHA256Hex[ToString[Hash[anon]]]|>];
    AppendTo[edges, <|"Relation" -> "Redacted", "FromUnitIDs" -> {sunit},
      "ToUnitIDs" -> {dunit}, "Cardinality" -> "1:1",
      "TransformDigest" -> policy["PolicyDigest"]|>];
    anon]], anonRows];
  (* --- Verify V1/V2/V3 ---
     KeepRaw フィールドと token (ItemToken/SubjectToken) は Verify 対象外:
     KeepRaw は「PII 混入なし」と宣言された値 (課題キー等が \d{7} に機械一致するのを
     PII リークと誤判定しないため)、token は非意味的識別子。 *)
  vfail = Module[{excludeKeys, strs},
    excludeKeys = Join[
      Keys[Select[Lookup[tier, "FieldRules", <||>], # === "KeepRaw" &]],
      {"ItemToken", "SubjectToken"}];
    strs = Flatten[Map[Function[row,
      KeyValueMap[If[StringQ[#2] && !MemberQ[excludeKeys, #1], #2, Nothing] &, row]],
      anonRows]];
    Which[
      AnyTrue[strs, Function[s, AnyTrue[knownAll, StringContainsQ[s, #] &]]],
      "V1KnownValueLeak",
      AnyTrue[strs, Function[s, AnyTrue[patterns,
        StringContainsQ[s, RegularExpression[#]] &]]],
      "V2PatternLeak",
      verifyFn =!= None &&
        AnyTrue[strs, Function[s, !TrueQ[Quiet @ Check[verifyFn[s], False]]]],
      "V3VerifierRejected",
      True, None]];
  If[vfail =!= None,
    Return[<|"Status" -> If[vfail === "V3VerifierRejected", "NeedsReview", "Failed"],
      "Reason" -> vfail|>]];
  (* --- Commit: lineage -> artifact -> binding -> publish -> cache --- *)
  manifest = SourceVaultAnonymizeBuildLineageManifest[<|
    "Origins" -> (KeyDrop[#, {"PrivacyLevel", "PrivacyLevelSource"}] & /@
      plan["Origins"]),
    "PolicyRef" -> policy["PolicyRef"], "MapRef" -> asg["MapRef"],
    "SourceNodes" -> srcNodes, "DerivedNodes" -> derNodes, "Edges" -> edges,
    "Partitions" -> {<|"Purpose" -> "CloudGrading", "MemberUnitIDs" ->
       (Lookup[#, "UnitID"] & /@ derNodes), "Coverage" -> "Complete"|>}|>];
  If[manifest["Status"] =!= "OK",
    Return[<|"Status" -> "Failed", "Reason" -> "LineageBuildFailed",
      "Detail" -> Lookup[manifest, "Findings", {}]|>]];
  mref = iSVASaveSnapshotAs["LineageManifest", KeyDrop[manifest, "Status"], 1.0];
  art = iSVASaveContentAddressedDerivedArtifact[<|
    "TargetLevel" -> tl, "Format" -> "Records", "Payload" -> anonRows,
    "PayloadDigest" -> iSVASHA256Hex[ToString[Hash[anonRows]]]|>];
  If[art["Status"] =!= "OK", Return[art]];
  bind = iSVASaveArtifactBinding[art["ArtifactRef"], <|
    "Origins" -> (KeyDrop[#, {"PrivacyLevel", "PrivacyLevelSource"}] & /@
      plan["Origins"]),
    "PolicyRef" -> policy["PolicyRef"], "MapRef" -> asg["MapRef"],
    "LineageManifestRef" -> mref|>];
  If[bind["Status"] =!= "OK", Return[bind]];
  pub = If[Lookup[grant, "PublishMode", "StageForOwnerReview"] === "PublishIfVerified",
    iSVAPublishDeclassifiedArtifact[<|"ArtifactRef" -> art["ArtifactRef"],
      "BindingRef" -> bind["BindingRef"], "TargetLevel" -> tl,
      "GrantID" -> Lookup[grant, "GrantID", "unspecified"]|>],
    <|"Status" -> "OK", "PublicationRef" -> "staged", "Staged" -> True|>];
  If[pub["Status"] =!= "OK", Return[pub]];
  If[cachePath =!= $Failed && !TrueQ[Lookup[pub, "Staged", False]],
    Quiet @ Check[
      (If[!DirectoryQ[DirectoryName[cachePath]],
         CreateDirectory[DirectoryName[cachePath]]];
       Export[cachePath, <|"ArtifactRef" -> art["ArtifactRef"],
         "MapRef" -> asg["MapRef"], "CacheIdentity" -> cacheId|>, "RawJSON"]), Null]];
  <|"Status" -> "OK", "ArtifactRef" -> art["ArtifactRef"],
    "ArtifactBindingRef" -> bind["BindingRef"],
    "LineageManifestRef" -> mref, "MapRef" -> asg["MapRef"],
    "PublicationState" -> If[TrueQ[Lookup[pub, "Staged", False]], "Staged", "Published"],
    "ReleaseHandle" -> Lookup[pub, "ReleaseHandle", Missing["Staged"]],
    "Payload" -> anonRows, "CacheHit" -> False,
    "Report" -> <|"Rows" -> Length[anonRows], "Entities" -> Length[mapEntries],
      "Verify" -> "Pass"|>|>];

End[]

(* ============================================================
   privacy 契約登録 (弱結合。SourceVault_privacy.wl ロード済みの場合のみ)。
   本モジュールの公開関数は私的ストア (mail/notebook/eagle/oops/llmlog) に
   到達しない純関数 + sidecar 読みのみ -> Class "Public"。
   ============================================================ *)
If[Names["SourceVault`SourceVaultRegisterPrivacyContract"] =!= {},
  Quiet @ Check[
    Scan[
      SourceVault`SourceVaultRegisterPrivacyContract[#,
        <|"Class" -> "Public", "Exit" -> "None",
          "NoDataFlow" -> "pure id/token derivation or schema-only sidecar read; no private store access"|>] &,
      {SourceVault`SourceVaultAnonymizeInitializeKeys,
       SourceVault`SourceVaultAnonymizeKeyStatus,
       SourceVault`SourceVaultAnonymizeVerifyKeyFingerprints,
       SourceVault`SourceVaultAnonymizeCanonicalEncode,
       SourceVault`SourceVaultAnonymizeCanonicalDigest,
       SourceVault`SourceVaultAnonymizeEntityID,
       SourceVault`SourceVaultAnonymizeSourceObjectID,
       SourceVault`SourceVaultAnonymizeSourceUnitID,
       SourceVault`SourceVaultAnonymizeDerivedUnitID,
       SourceVault`SourceVaultAnonymizeGenerateToken,
       SourceVault`SourceVaultAnonymizeTokenValidQ,
       SourceVault`SourceVaultAnonymizeGenerateReleaseHandle,
       SourceVault`SourceVaultAnonymizeReleaseHandleValidQ,
       SourceVault`SourceVaultAnonymizationPlan,
       SourceVault`SourceVaultRequestDeclassification,
       SourceVault`SourceVaultApproveDeclassification,
       SourceVault`SourceVaultVerifyDeclassificationGrant,
       SourceVault`SourceVaultConsumeDeclassificationGrantUse,
       SourceVault`SourceVaultRevokeReleaseHandle,
       SourceVault`SourceVaultRotateReleaseHandle,
       SourceVault`SourceVaultAnonymizePublicationStatus,
       SourceVault`SourceVaultRevokeDeclassifiedArtifact,
       SourceVault`SourceVaultAnonymizeGetByHandle,
       SourceVault`SourceVaultCreateDerivedAnnotations,
       SourceVault`SourceVaultValidateDerivedJoin,
       SourceVault`SourceVaultAttachDerivedResults,
       SourceVault`SourceVaultAnonymize,
       SourceVault`SourceVaultAnonymizeBuildEvaluationPlan,
       SourceVault`SourceVaultAnonymizeQuarantineIngress}];
    Scan[
      SourceVault`SourceVaultRegisterPrivacyContract[#,
        <|"Class" -> "Public", "Exit" -> "None",
          "NoDataFlow" -> "pure image raster transform/verify; no private store access"|>] &,
      {SourceVault`SourceVaultAnonymizeImageRedact,
       SourceVault`SourceVaultAnonymizePDFPageImages,
       SourceVault`SourceVaultAnonymizeVerifyRedactedImage,
       SourceVault`SourceVaultAnonymizeMediaScan,
       SourceVault`SourceVaultAnonymizeComposedPrivacy,
       SourceVault`SourceVaultAnonymizeRecordExposure,
       SourceVault`SourceVaultAnonymizeExposureGuard,
       SourceVault`SourceVaultAnonymizeValidateDistribution,
       SourceVault`SourceVaultAnonymizeUnlistedClassQ,
       SourceVault`SourceVaultAnonymizeExposureProbe,
       SourceVault`SourceVaultRegisterAnonymizeExposureDiagnostics,
       SourceVault`SourceVaultAnonymizeExposureEscalateIfNeeded}];
    (* sensitive doctor は owner-only で高感度メタデータを返す -> Private *)
    SourceVault`SourceVaultRegisterPrivacyContract[
      SourceVault`SourceVaultAnonymizeExposureSensitiveDoctor,
      <|"Class" -> "Private", "Exit" -> "Result",
        "NoDataFlow" -> "owner-only aggregate exposure metadata; no private store access"|>];
    Scan[
      SourceVault`SourceVaultRegisterPrivacyContract[#,
        <|"Class" -> "Public", "Exit" -> "None",
          "NoDataFlow" -> "policy registry only; no private store access"|>] &,
      {SourceVault`SourceVaultRegisterAnonymizationPolicy,
       SourceVault`SourceVaultAnonymizationPolicies,
       SourceVault`SourceVaultAnonymizationPolicy}];
    (* lineage builder/validator: 入力が高 PL の manifest になり得る (仕様 §16.1 Private)。
       validator の報告は unit ID / 件数のみ (PII 非含有、AC-040)。 *)
    Scan[
      SourceVault`SourceVaultRegisterPrivacyContract[#,
        <|"Class" -> "Private", "Exit" -> "Result",
          "NoDataFlow" -> "pure graph construction/validation on caller-provided data; no private store access"|>] &,
      {SourceVault`SourceVaultAnonymizeBuildLineageManifest,
       SourceVault`SourceVaultValidateLineage,
       SourceVault`SourceVaultResolveReleaseHandle,
       SourceVault`SourceVaultAnonymizeAssignSubjectTokens,
       SourceVault`SourceVaultAnonymizePseudonymMap,
       SourceVault`SourceVaultAnonymizedVariants}];
    SourceVault`SourceVaultRegisterPrivacyContract[
      SourceVault`SourceVaultAnonymizePseudonymMapId,
      <|"Class" -> "Public", "Exit" -> "None",
        "NoDataFlow" -> "pure id derivation; no private store access"|>],
    Null]];

(* NBAccess action registry: declassification effect class (仕様 §5.13 / G0b)。
   承認操作と (将来の) Execute ヘッドを承認ゲート対象に登録する。LLM/agent 経由の
   評価では Hold -> Approve UI を通る (自己承認防止)。ロード順・未ロード耐性のため弱結合。 *)
If[TrueQ[Quiet @ Check[ListQ[NBAccess`$NBApprovalHeads], False]],
  Scan[
    Function[h,
      If[!MemberQ[NBAccess`$NBApprovalHeads, h],
        NBAccess`$NBApprovalHeads = Append[NBAccess`$NBApprovalHeads, h]]],
    {"SourceVaultApproveDeclassification", "SourceVaultAnonymize"}]];

EndPackage[]
