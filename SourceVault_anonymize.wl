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

iSVAMapLoadByRef[ref_String] :=
  If[Names["SourceVault`SourceVaultLoadImmutableSnapshot"] === {}, $Failed,
    Quiet @ Check[SourceVault`SourceVaultLoadImmutableSnapshot[ref], $Failed]];

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

(* 登録済みポリシー一覧 (A0 実装までは空。存在すれば PolicyId のみ列挙) *)
iSVAAvailablePolicies[] :=
  If[Names["SourceVault`SourceVaultAnonymizationPolicies"] =!= {} &&
     DownValues[SourceVault`SourceVaultAnonymizationPolicies] =!= {},
    Quiet @ Check[
      Lookup[#, "PolicyId", Nothing] & /@ SourceVault`SourceVaultAnonymizationPolicies[],
      {}],
    {}];

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
       SourceVault`SourceVaultRotateReleaseHandle}];
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
       SourceVault`SourceVaultAnonymizePseudonymMap}];
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
