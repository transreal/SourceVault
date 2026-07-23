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

(* ============================================================
   1. KeyRing (仕様 §5.5.1)
   NBAccess の MAC KeyRef 機構に乗る。鍵材料はこのモジュールに現れない。
   ============================================================ *)

iSVAKeySpecs[] := {
  {$SourceVaultAnonymizeIdentityKeyRef, "anonymize identity/entity HMAC (namespaceKey)"},
  {$SourceVaultAnonymizeLineageKeyRef,  "anonymize lineage unit HMAC (lineageKey)"}};

iSVAKeyExistsQ[keyRef_String] :=
  iSVANBCryptoQ[] && !MissingQ[Quiet @ Check[NBAccess`NBKeyStatus[keyRef], Missing["Error"]]];

SourceVaultAnonymizeInitializeKeys[] := Module[{specs, existing, missing, created},
  If[!iSVANBCryptoQ[],
    Return[<|"Status" -> "Failed", "Reason" -> "NBAccessCryptoUnavailable"|>]];
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
iSVAEnc[a_Association] := Module[{keys, pairs},
  keys = Keys[a];
  If[!AllTrue[keys, StringQ], Return[$Failed]];
  keys = SortBy[keys, ToCharacterCode[#, "Unicode"] &];
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
  If[!iSVAKeyExistsQ[keyRef], Return[$Failed]];
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
    NumericQ[pl], <|"PrivacyLevel" -> N[pl], "PrivacyLevelSource" -> "SnapshotSidecar"|>,
    AssociationQ[pl] && NumericQ[Lookup[pl, "PrivacyLevel"]],
    <|"PrivacyLevel" -> N[pl["PrivacyLevel"]], "PrivacyLevelSource" -> "SnapshotSidecar"|>,
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
    records = MapIndexed[
      iSVAPlanOriginRecord[#1, If[First[#2] == 1, "primary", "origin-" <> ToString[First[#2]]]] &,
      origRefs];
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
       SourceVault`SourceVaultAnonymizationPlan}],
    Null]];

EndPackage[]
