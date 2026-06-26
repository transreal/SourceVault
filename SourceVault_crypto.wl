(* ::Package:: *)

(* ============================================================
   SourceVault_crypto.wl -- SourceVault 暗号基盤 (Phase SV-E3 step 2-5)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_crypto.wl"]]

   仕様: ClaudeEval_..._SourceVault_encryption_sharing_spec_v18.md
         + ClaudeCode_SourceVault_encryption_spec_v18_review.md

   このファイルは仕様 §17 実装順序の最初のフェーズだけを実装する:
     step 2  SourceVaultCryptoCapabilityReport[]   (AEAD/GCM・RSA-PSS の実測)
     step 5  canonical bytes (Internal / Interoperable JSON profile)
     step 5  encrypt-then-MAC primitive + 最小 roundtrip

   実測 (WL 14.3, 2026-06-04):
     - GCM/AEAD は GenerateSymmetricKey で利用不可 -> EncryptThenMAC を既定 primary とする
     - 組み込み HMAC は無い -> RFC 2104 HMAC-SHA256 を自前構成する
     - GenerateDigitalSignature の RSA-PSS Method 指定は不可 -> capability report で False を返す

   鍵隔離境界について:
     仕様では鍵材料は NBAccess の外に出さない (NBEncryptWithKeyRef 等)。
     本ファイルの鍵を引数に取る関数 (iSV 接頭辞) は内部 primitive であり、
     次フェーズの NBAccess crypto 層 / bootstrap がこれらを呼び出す。
     公開シンボルは capability report・canonical bytes・self-test に限る。
   ============================================================ *)

BeginPackage["SourceVault`"];

SourceVaultCryptoCapabilityReport::usage =
  "SourceVaultCryptoCapabilityReport[] はこの Wolfram 環境の暗号能力 (AEAD/GCM, RSA-PSS, HMAC) を実測し、既定 IntegrityMode を含む Association を返す。";

SourceVaultCanonicalJSONBytes::usage =
  "SourceVaultCanonicalJSONBytes[expr] は expr を再帰的に KeySort した canonical JSON (UTF-8) の ByteArray を返す。共有・署名・MAC の安定 bytes に使う (Interoperable JSON profile)。";

SourceVaultCanonicalBytes::usage =
  "SourceVaultCanonicalBytes[expr, profile_:\"Internal\"] は canonical bytes を返す。profile=\"Internal\" は BinarySerialize (ローカル at-rest payload 用)、\"JSON\" は SourceVaultCanonicalJSONBytes に委譲する。";

SourceVaultCryptoSelfTest::usage =
  "SourceVaultCryptoSelfTest[] は capability probe・canonical 決定性・encrypt-then-MAC roundtrip・改ざん検出を検査し、結果 Association を返す。";

SourceVaultHMACSHA256Hex::usage =
  "SourceVaultHMACSHA256Hex[keyBA_ByteArray, msgBA_ByteArray] は RFC2104 HMAC-SHA256 を hex 文字列で返す。AccessGrant 署名等の MAC に使う公開ラッパー。";

SourceVaultConstantTimeEqualQ::usage =
  "SourceVaultConstantTimeEqualQ[a_String, b_String] は2つの hex/文字列を best-effort 定数時間で比較する (署名検証用)。";

Begin["`Private`"];

(* ------------------------------------------------------------
   HMAC-SHA256 (RFC 2104) -- WL に組み込み HMAC が無いため自前構成
   ------------------------------------------------------------ *)

$iSVHashBlockSize = 64;  (* SHA-256 block size in bytes *)

(* Hash の ByteArray 出力。環境差を吸収するため HexString からも復元できるようにする。 *)
iSVSha256Bytes[ba_ByteArray] :=
  Module[{r},
    r = Quiet@Check[Hash[ba, "SHA256", "ByteArray"], $Failed];
    If[Head[r] === ByteArray, Return[r]];
    (* fallback: HexString -> ByteArray *)
    ByteArray[
      IntegerDigits[Hash[ba, "SHA256"], 256, 32]
    ]
  ];

iSVByteJoin[a_ByteArray, b_ByteArray] := ByteArray[Join[Normal[a], Normal[b]]];

iSVHMACSHA256[keyBA_ByteArray, msgBA_ByteArray] :=
  Module[{k0, kpad, ipad, opad, inner},
    k0 = If[Length[keyBA] > $iSVHashBlockSize, iSVSha256Bytes[keyBA], keyBA];
    kpad = PadRight[Normal[k0], $iSVHashBlockSize, 0];
    ipad = ByteArray[BitXor[#, 54] & /@ kpad];   (* 0x36 *)
    opad = ByteArray[BitXor[#, 92] & /@ kpad];   (* 0x5c *)
    inner = iSVSha256Bytes[iSVByteJoin[ipad, msgBA]];
    iSVSha256Bytes[iSVByteJoin[opad, inner]]
  ];

iSVHMACSHA256Hex[keyBA_ByteArray, msgBA_ByteArray] :=
  StringJoin[IntegerString[#, 16, 2] & /@ Normal[iSVHMACSHA256[keyBA, msgBA]]];

(* best-effort constant-time 比較 (長さ一致前提で全 byte を XOR-OR) *)
iSVConstantTimeEqual[a_String, b_String] :=
  StringLength[a] === StringLength[b] &&
   Module[{ca, cb},
     ca = ToCharacterCode[a]; cb = ToCharacterCode[b];
     BitOr @@ MapThread[BitXor, {ca, cb}] === 0
   ];

(* 公開ラッパー: grant 署名/検証など crypto 層外から使う *)
SourceVaultHMACSHA256Hex[keyBA_ByteArray, msgBA_ByteArray] := iSVHMACSHA256Hex[keyBA, msgBA];
SourceVaultConstantTimeEqualQ[a_String, b_String] := TrueQ[iSVConstantTimeEqual[a, b]];

(* ------------------------------------------------------------
   canonical bytes
   ------------------------------------------------------------ *)

(* 再帰的に Association を KeySort し、Missing 等を固定文字列化する。 *)
iSVCanonicalize[a_Association] :=
  KeySort[Association[KeyValueMap[#1 -> iSVCanonicalize[#2] &, a]]];
iSVCanonicalize[l_List] := iSVCanonicalize /@ l;
iSVCanonicalize[Missing[tag___]] := "__Missing__" <> ToString[{tag}];
iSVCanonicalize[s_String] := s;
iSVCanonicalize[i_Integer] := i;
iSVCanonicalize[b_ByteArray] := <|"__Bytes64__" -> BaseEncode[b]|>;
iSVCanonicalize[True] := True;
iSVCanonicalize[False] := False;
iSVCanonicalize[Null] := "__Null__";
iSVCanonicalize[r_Real] := <|"__Decimal__" -> ToString[r, InputForm]|>;
iSVCanonicalize[x_] := <|"__WXF64__" -> BaseEncode[BinarySerialize[x]]|>;

SourceVaultCanonicalJSONBytes[expr_] :=
  StringToByteArray[
    ExportString[iSVCanonicalize[expr], "RawJSON", "Compact" -> True],
    "UTF-8"
  ];

SourceVaultCanonicalBytes[expr_, profile_: "Internal"] :=
  Switch[profile,
    "Internal", BinarySerialize[expr],
    "JSON" | "Interoperable", SourceVaultCanonicalJSONBytes[expr],
    _, BinarySerialize[expr]
  ];

iSVPayloadSerializationFormat[] :=
  <|"Format" -> "WXF", "WolframVersion" -> $VersionNumber,
    "CompatibilityScope" -> "LocalAtRestOnly"|>;

(* ------------------------------------------------------------
   capability report
   ------------------------------------------------------------ *)

iSVProbeGCM[] :=
  Module[{k, enc, dec},
    k = Quiet@Check[
       GenerateSymmetricKey[<|"Cipher" -> "AES256", "BlockMode" -> "GCM"|>], $Failed];
    If[Head[k] =!= SymmetricKey, Return[<|"Status" -> "Fail", "Message" -> "GCM key generation unavailable"|>]];
    enc = Quiet@Check[Encrypt[k, "probe"], $Failed];
    dec = If[Head[enc] === EncryptedObject, Quiet@Check[Decrypt[k, enc], $Failed], $Failed];
    If[dec === "probe",
      <|"Status" -> "Pass", "Message" -> "GCM roundtrip ok"|>,
      <|"Status" -> "Fail", "Message" -> "GCM encrypt/decrypt failed"|>]
  ];

iSVProbeRSAPSS[] :=
  Module[{kp, sig},
    kp = Quiet@Check[GenerateAsymmetricKeyPair[], $Failed];
    If[! AssociationQ[kp], Return[False]];
    sig = Quiet@Check[
       GenerateDigitalSignature["probe", kp["PrivateKey"],
        Method -> <|"Type" -> "RSASSA-PSS", "HashType" -> "SHA256"|>], $Failed];
    Head[sig] === DigitalSignature
  ];

iSVProbeDefaultSignature[] :=
  Module[{kp, sig, ver},
    kp = Quiet@Check[GenerateAsymmetricKeyPair[], $Failed];
    If[! AssociationQ[kp], Return[False]];
    sig = Quiet@Check[GenerateDigitalSignature["probe", kp["PrivateKey"]], $Failed];
    If[Head[sig] =!= DigitalSignature, Return[False]];
    ver = Quiet@Check[VerifyDigitalSignature[{"probe", sig}, kp["PublicKey"]], $Failed];
    ver === True
  ];

iSVProbeHMAC[] :=
  Module[{mac},
    mac = Quiet@Check[
       iSVHMACSHA256Hex[
        StringToByteArray["k", "UTF-8"], StringToByteArray["m", "UTF-8"]], $Failed];
    StringQ[mac] && StringLength[mac] === 64
  ];

SourceVaultCryptoCapabilityReport[] :=
  Module[{gcm, pss, defSig, hmac},
    gcm = iSVProbeGCM[];
    pss = iSVProbeRSAPSS[];
    defSig = iSVProbeDefaultSignature[];
    hmac = iSVProbeHMAC[];
    <|
      "Type" -> "SourceVaultCryptoCapabilityReport",
      "WolframVersion" -> $Version,
      "VersionNumber" -> $VersionNumber,
      "AEADGCMAvailable" -> (gcm["Status"] === "Pass"),
      "AEADProbe" -> gcm,
      "HMACSHA256Available" -> hmac,
      "RSAPSSSignatureAvailable" -> pss,
      "DefaultSignatureAvailable" -> defSig,
      "DefaultSignatureAlgorithm" ->
        If[pss, "RSA-PSS-SHA256", If[defSig, "RSA-PKCS1v1_5-default", "Unavailable"]],
      "CapsuleSignatureImplementable" -> (pss || defSig),
      "DefaultIntegrityMode" -> "EncryptThenMAC",
      "EffectiveIntegrityMode" ->
        If[gcm["Status"] === "Pass", "AuthenticatedEncryption", "EncryptThenMAC"],
      "Notes" ->
        "encrypt-then-MAC is primary. AEAD/GCM is opt-in only when AEADGCMAvailable is True. " <>
        "RSA-PSS is used for capsule signatures only when RSAPSSSignatureAvailable is True; " <>
        "otherwise capsule signing must not be reported as implemented."
    |>
  ];

(* ------------------------------------------------------------
   encrypt-then-MAC primitive (内部 -- 鍵を引数に取る)

   encKey : SymmetricKey (at-rest 暗号鍵)
   macKey : ByteArray    (at-rest MAC 鍵。encKey とは別物であること)
   aad    : Association  (認証対象の暗号メタデータ + 判定駆動 metadata)
   ------------------------------------------------------------ *)

(* authenticated bytes = canonical JSON of {AAD, IV, Ciphertext} (AAD/IV/暗号文すべてを認証) *)
iSVAuthenticatedBytes[aad_Association, ivB64_, ctB64_String] :=
  SourceVaultCanonicalJSONBytes[
    <|"AuthenticatedAssociatedData" -> aad, "IV" -> ivB64, "Ciphertext" -> ctB64|>];

iSVEtMEncrypt[encKey_, macKey_ByteArray, plaintextExpr_, aad_Association] :=
  Module[{payloadBytes, enc, ctBytes, ctB64, ivB64, authBytes, mac, checksum},
    payloadBytes = SourceVaultCanonicalBytes[plaintextExpr, "Internal"];
    enc = Encrypt[encKey, payloadBytes];
    If[Head[enc] =!= EncryptedObject,
      Return[<|"Status" -> "Error", "Reason" -> "EncryptFailed", "PlaintextReturned" -> False|>]];
    ctBytes = BinarySerialize[enc];
    ctB64 = BaseEncode[ctBytes];
    ivB64 = Quiet@Check[BaseEncode[enc[[1]]["InitializationVector"]], Missing["NoIV"]];
    authBytes = iSVAuthenticatedBytes[aad, ivB64, ctB64];
    mac = iSVHMACSHA256Hex[macKey, authBytes];
    checksum = StringJoin[IntegerString[#, 16, 2] & /@ Normal[iSVSha256Bytes[ctBytes]]];
    <|
      "Type" -> "SourceVaultEncryptedPayload",
      "SchemaVersion" -> 3,
      "Encryption" -> <|
        "Backend" -> "WolframLanguageNative",
        "Mode" -> "SymmetricAtRest",
        "PayloadCanonicalization" -> "SourceVaultCanonicalBytes/Internal/v1",
        "PayloadSerializationFormat" -> iSVPayloadSerializationFormat[],
        "AuthenticatedBytesCanonicalization" -> "SourceVaultAtRestAuthenticatedBytes/v1",
        "Algorithm" -> <|"Cipher" -> "AES256", "BlockMode" -> "CBC", "Resolved" -> True|>,
        "IntegrityMode" -> "EncryptThenMAC",
        "IV" -> ivB64,
        "Ciphertext" -> ctB64,
        "CiphertextEncoding" -> "Base64",
        "AuthenticatedAssociatedData" -> aad,
        "CiphertextChecksum" -> <|
          "Algorithm" -> "SHA256", "Value" -> checksum,
          "SecurityMeaning" -> "AccidentalCorruptionOnly"|>,
        "CiphertextHMAC" -> <|
          "Algorithm" -> "HMAC-SHA256",
          "AuthenticatedBytes" -> "SourceVaultAtRestAuthenticatedBytes/v1",
          "Value" -> mac|>
      |>
    |>
  ];

iSVEtMDecrypt[encKey_, macKey_ByteArray, record_Association] :=
  Module[{e, aad, ivB64, ctB64, authBytes, expectMac, gotMac, ctBytes, enc, payloadBytes},
    e = Lookup[record, "Encryption", $Failed];
    If[! AssociationQ[e],
      Return[<|"Status" -> "Error", "Reason" -> "UnsupportedVersion", "PlaintextReturned" -> False|>]];
    aad = Lookup[e, "AuthenticatedAssociatedData", <||>];
    ivB64 = Lookup[e, "IV", Missing["NoIV"]];
    ctB64 = Lookup[e, "Ciphertext", $Failed];
    expectMac = Lookup[e["CiphertextHMAC"], "Value", $Failed];
    If[! StringQ[ctB64] || ! StringQ[expectMac],
      Return[<|"Status" -> "Error", "Reason" -> "MalformedRecord", "PlaintextReturned" -> False|>]];
    (* 復号前に MAC を検証する (AAD + IV + 暗号文すべて) *)
    authBytes = iSVAuthenticatedBytes[aad, ivB64, ctB64];
    gotMac = iSVHMACSHA256Hex[macKey, authBytes];
    If[! iSVConstantTimeEqual[gotMac, expectMac],
      Return[<|"Status" -> "Error", "Reason" -> "AuthenticationFailed", "PlaintextReturned" -> False|>]];
    ctBytes = Quiet@Check[BaseDecode[ctB64], $Failed];
    enc = Quiet@Check[BinaryDeserialize[ctBytes], $Failed];
    If[Head[enc] =!= EncryptedObject,
      Return[<|"Status" -> "Error", "Reason" -> "MalformedCiphertext", "PlaintextReturned" -> False|>]];
    payloadBytes = Quiet@Check[Decrypt[encKey, enc], $Failed];
    If[Head[payloadBytes] =!= ByteArray,
      Return[<|"Status" -> "Error", "Reason" -> "WrongKey", "PlaintextReturned" -> False|>]];
    <|"Status" -> "Ok", "PlaintextReturned" -> True,
      "Plaintext" -> BinaryDeserialize[payloadBytes]|>
  ];

(* ------------------------------------------------------------
   self test
   ------------------------------------------------------------ *)

SourceVaultCryptoSelfTest[] :=
  Module[{cap, results, encKey, macKey, macKey2, aad, plaintext, rec, dec,
    tamperedCt, tamperedAad, wrongMac, c1, c2},
    cap = SourceVaultCryptoCapabilityReport[];
    encKey = GenerateSymmetricKey[];
    macKey = ByteArray[RandomInteger[{0, 255}, 32]];
    macKey2 = ByteArray[RandomInteger[{0, 255}, 32]];
    aad = <|"RecordId" -> "rec-1", "Policy" -> <|"CloudSendAllowed" -> False, "PrivacyLevel" -> 0.9|>,
      "ContentType" -> "PromptRoute"|>;
    plaintext = <|"Prompt" -> "秘密のプロンプト", "Memo" -> "private", "n" -> 42|>;
    rec = iSVEtMEncrypt[encKey, macKey, plaintext, aad];

    (* canonical 決定性: キー順が違っても同一 bytes *)
    c1 = SourceVaultCanonicalJSONBytes[<|"b" -> 1, "a" -> 2|>];
    c2 = SourceVaultCanonicalJSONBytes[<|"a" -> 2, "b" -> 1|>];

    dec = iSVEtMDecrypt[encKey, macKey, rec];

    (* 改ざん: ciphertext 1 文字書換え *)
    tamperedCt = rec;
    tamperedCt["Encryption", "Ciphertext"] =
      StringReplacePart[rec["Encryption"]["Ciphertext"],
        If[StringTake[rec["Encryption"]["Ciphertext"], {1}] === "A", "B", "A"], {1, 1}];

    (* 改ざん: AAD の Policy を緩める (CloudSendAllowed True) -- MAC が AAD を含むので失敗すべき *)
    tamperedAad = rec;
    tamperedAad["Encryption", "AuthenticatedAssociatedData", "Policy", "CloudSendAllowed"] = True;

    results = <|
      "CapabilityReport" -> cap,
      "GCMUnavailableAsExpected" -> (cap["AEADGCMAvailable"] === False),
      "HMACAvailable" -> (cap["HMACSHA256Available"] === True),
      "CanonicalDeterministic" -> (c1 === c2),
      "EtMRoundtrip" -> (dec["Status"] === "Ok" && dec["Plaintext"] === plaintext),
      "WrongMacKeyRejected" ->
        (iSVEtMDecrypt[encKey, macKey2, rec]["Status"] === "Error"),
      "TamperedCiphertextRejected" ->
        (iSVEtMDecrypt[encKey, macKey, tamperedCt]["Status"] === "Error"),
      "TamperedAADPolicyRejected" ->
        (iSVEtMDecrypt[encKey, macKey, tamperedAad]["Status"] === "Error")
    |>;
    results["AllPassed"] = AllTrue[
      {results["GCMUnavailableAsExpected"], results["HMACAvailable"],
       results["CanonicalDeterministic"], results["EtMRoundtrip"],
       results["WrongMacKeyRejected"], results["TamperedCiphertextRejected"],
       results["TamperedAADPolicyRejected"]}, TrueQ];
    results
  ];

End[];
EndPackage[];


(* ::Package:: *)

(* ============================================================
   SourceVault_keys.wl -- SourceVault 鍵 bootstrap (Phase SV-E3 step 4)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"},
               Get["NBAccess_crypto.wl"]; Get["SourceVault_keys.wl"]]

   仕様: SourceVault encryption spec v18 §5.3 / §5.4

   標準 KeyRef を定義し、SourceVaultInitializeEncryption[] で欠落鍵だけを
   NBAccess crypto 層 (NBAccess_crypto.wl) 経由で生成する。冪等。
   鍵材料は戻り値・ログ・record に出さない。
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

$SourceVaultDefaultAtRestKeyRef::usage = "at-rest 暗号鍵 KeyRef。";
$SourceVaultDefaultAtRestMACKeyRef::usage = "at-rest MAC 鍵 KeyRef (暗号鍵とは別)。";
$SourceVaultDefaultPlaintextHMACKeyRef::usage = "plaintext digest HMAC 鍵 KeyRef (rotation-stable)。";
$SourceVaultDefaultMailIdentityHMACKeyRef::usage = "mail RecordId / header token HMAC 鍵 KeyRef (rotation-stable)。";
$SourceVaultDefaultAddressBookMACKeyRef::usage = "AddressBook email/handle token HMAC 鍵 KeyRef (rotation-stable)。";
$SourceVaultDefaultCapsuleQuarantineMACKeyRef::usage = "受信 capsule の local at-rest quarantine MAC 鍵 KeyRef。";
$SourceVaultDefaultBaselineMACKeyRef::usage = "Trusted Baseline local MAC 鍵 KeyRef。";
$SourceVaultDefaultBaselineSigningKeyRef::usage = "Trusted Baseline owner 署名鍵 KeyRef。";
$SourceVaultDefaultSelfPrivateKeyRef::usage = "自分の envelope 復号 (capsule) 用秘密鍵 KeyRef。";
$SourceVaultDefaultSelfSigningKeyRef::usage = "自分の capsule 署名鍵 KeyRef。";

SourceVaultInitializeEncryption::usage =
  "SourceVaultInitializeEncryption[opts] は欠落している標準鍵だけを生成する冪等 bootstrap。鍵材料は返さない。既存鍵は破壊しない。";
SourceVaultEncryptionKeyStatus::usage =
  "SourceVaultEncryptionKeyStatus[] は標準 KeyRef の存在状況 (鍵材料なし) を返す。";

Begin["`Private`"];

$SourceVaultDefaultAtRestKeyRef            = "SourceVault:master:atrest:v1";
$SourceVaultDefaultAtRestMACKeyRef         = "SourceVault:master:mac:v1";
$SourceVaultDefaultPlaintextHMACKeyRef     = "SourceVault:pthmac:digest:v1";
$SourceVaultDefaultMailIdentityHMACKeyRef  = "SourceVault:mailid:mac:v1";
$SourceVaultDefaultAddressBookMACKeyRef    = "SourceVault:addressbook:mac:v1";
$SourceVaultDefaultCapsuleQuarantineMACKeyRef = "SourceVault:capsule:quarantine-mac:v1";
$SourceVaultDefaultBaselineMACKeyRef       = "SourceVault:baseline:policy-mac:v1";
$SourceVaultDefaultBaselineSigningKeyRef   = "SourceVault:baseline:policy-sign:v1";
$SourceVaultDefaultSelfPrivateKeyRef       = "SourceVault:self:private:v1";
$SourceVaultDefaultSelfSigningKeyRef       = "SourceVault:signing:sign:v1";

(* {keyRef, kind, rotationStable, purpose} *)
iSVKStandardKeySpecs[] := {
  {$SourceVaultDefaultAtRestKeyRef, "Symmetric", False, "at-rest encryption"},
  {$SourceVaultDefaultAtRestMACKeyRef, "Mac", False, "at-rest MAC"},
  {$SourceVaultDefaultPlaintextHMACKeyRef, "Mac", True, "plaintext digest HMAC"},
  {$SourceVaultDefaultMailIdentityHMACKeyRef, "Mac", True, "mail identity/token HMAC"},
  {$SourceVaultDefaultAddressBookMACKeyRef, "Mac", True, "addressbook token HMAC"},
  {$SourceVaultDefaultCapsuleQuarantineMACKeyRef, "Mac", False, "capsule quarantine MAC"},
  {$SourceVaultDefaultBaselineMACKeyRef, "Mac", False, "baseline policy MAC"},
  {$SourceVaultDefaultBaselineSigningKeyRef, "Asymmetric", False, "baseline policy signing"},
  {$SourceVaultDefaultSelfPrivateKeyRef, "Asymmetric", False, "self envelope private"},
  {$SourceVaultDefaultSelfSigningKeyRef, "Asymmetric", False, "self signing"}
};

iSVKExistsQ[keyRef_] := ! MissingQ[NBAccess`NBKeyStatus[keyRef]];

iSVKGenerate[keyRef_, kind_, rotationStable_, purpose_] :=
  Module[{md = <|"Purpose" -> purpose, "RotationStable" -> rotationStable,
      "Owner" -> "SourceVault"|>},
    Switch[kind,
      "Symmetric", NBAccess`NBGenerateSymmetricKeyRef[keyRef, md],
      "Mac", NBAccess`NBGenerateMacKeyRef[keyRef, md],
      "Asymmetric", NBAccess`NBGenerateAsymmetricKeyRefPair[keyRef, md]]];

Options[SourceVaultInitializeEncryption] = {"DryRun" -> False};

SourceVaultInitializeEncryption[OptionsPattern[]] :=
  Module[{specs, existing, missing, created, dry},
    dry = TrueQ[OptionValue["DryRun"]];
    specs = iSVKStandardKeySpecs[];
    existing = Select[specs, iSVKExistsQ[#[[1]]] &][[All, 1]];
    missing = Select[specs, ! iSVKExistsQ[#[[1]]] &];
    created = If[dry, {},
      (iSVKGenerate @@ # &) /@ missing; missing[[All, 1]]];
    <|
      "Type" -> "SourceVaultInitializeEncryptionResult",
      "Status" -> Which[
         dry && Length[missing] > 0, "Partial",
         Length[missing] === 0, "AlreadyInitialized",
         True, "Initialized"],
      "DryRun" -> dry,
      "CreatedKeyRefs" -> created,
      "ExistingKeyRefs" -> existing,
      "MissingKeyRefs" -> missing[[All, 1]],
      "KeyMaterialReturned" -> False,
      "RequiresUserApproval" -> False
    |>];

SourceVaultEncryptionKeyStatus[] :=
  Association[(#[[1]] -> <|
       "Exists" -> iSVKExistsQ[#[[1]]],
       "Kind" -> #[[2]], "RotationStable" -> #[[3]], "Purpose" -> #[[4]],
       "Fingerprint" ->
         If[iSVKExistsQ[#[[1]]], NBAccess`NBKeyStatus[#[[1]]]["Fingerprint"], Missing["NotGenerated"]]
       |>) & /@ iSVKStandardKeySpecs[]];

End[];
EndPackage[];


(* ::Package:: *)

(* ============================================================
   SourceVault_keybundle.wl -- 可搬・パスフレーズ保護の鍵バンドル
   (マルチ環境/災害復旧用。鍵は Dropbox に載せない運用が既定)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"},
               Get["NBAccess_crypto.wl"]; Get["SourceVault_crypto.wl"];
               Get["SourceVault_keys.wl"]; Get["SourceVault_keybundle.wl"]]

   設計:
   - passphrase から scrypt (メモリ困難 KDF, WL 既定) で 64B 派生。
     先頭32B=AES256 ラップ鍵, 末尾32B=HMAC-SHA256 MAC 鍵。salt はランダム生成し保存。
   - 各マスター鍵は NBExportWrappedKeys で wrapKey 暗号化 (平文鍵材料は出ない)。
   - bundle 全体を encrypt-then-MAC: 誤 passphrase / 改ざんは MAC 検証で fail-closed。
   - bundle は既定で Dropbox の外 (ホーム直下) に書く。USB/PW マネージャへ退避し、
     各マシンで SourceVaultImportKeyBundle して SystemCredential に書き戻す。
   - 鍵材料は戻り値・ログに出さない。復元は BinaryDeserialize のみ (ToExpression 不使用)。
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultExportKeyBundle::usage =
  "SourceVaultExportKeyBundle[passphrase, opts] は標準マスター鍵を passphrase で包んだ可搬バンドルをファイルに書く。opts: \"Path\"(既定ホーム直下・非Dropbox), \"KeyRefs\"(既定=標準鍵), \"ScryptN\"(既定131072), \"Force\"(弱 passphrase 許可)。鍵材料は返さない。";
SourceVaultImportKeyBundle::usage =
  "SourceVaultImportKeyBundle[passphrase, opts] はバンドルを passphrase で解錠し、各鍵を現マシンの credential store に書き戻す。opts: \"Path\"。誤 passphrase/改ざんは MAC 検証で拒否。";
SourceVaultKeyBundleInfo::usage =
  "SourceVaultKeyBundleInfo[path] は passphrase 無しで読める非秘密メタ (Version/CreatedAt/KeyRefs/KDF) を返す。";
$SourceVaultKeyBundleDefaultPath::usage =
  "鍵バンドルの既定パス (Dropbox 外)。";

Begin["`Private`"];

$SourceVaultKeyBundleVersion = 1;
$SourceVaultKeyBundleScryptN = 131072;   (* 2^17, ~128MB メモリ困難 *)

$SourceVaultKeyBundleDefaultPath :=
  FileNameJoin[{$HomeDirectory, "SourceVault_keybundle.svkeys"}];

(* 標準鍵 (SourceVault_keys.wl と一致) *)
iSVKBStandardKeyRefs[] := iSVKStandardKeySpecs[][[All, 1]];

(* passphrase + (salt|Automatic) -> <|Salt, WrapKey, MacKey, N|> *)
iSVKBDerive[passphrase_String, salt_, n_Integer] :=
  Module[{method, dk, bytes},
    method = <|"Function" -> "scrypt",
       "FunctionParameters" -> <|"KeySize" -> 64, "N" -> n, "r" -> 8, "p" -> 1|>|>;
    dk = If[salt === Automatic,
       GenerateDerivedKey[passphrase, Method -> method],
       GenerateDerivedKey[passphrase, salt, Method -> method]];
    If[Head[dk] =!= DerivedKey, Return[$Failed]];
    bytes = dk["DerivedKey"];
    If[Head[bytes] =!= ByteArray || Length[bytes] < 64, Return[$Failed]];
    <|"Salt" -> dk["Salt"], "N" -> n,
      "WrapKey" -> SymmetricKey[<|"Cipher" -> "AES256", "BlockMode" -> "CBC",
          "Key" -> Take[bytes, 32]|>],
      "MacKey" -> Take[bytes, {33, 64}]|>];

(* MAC は bundle core (MAC 以外) の BinarySerialize に対する HMAC-SHA256 *)
iSVKBMac[macKey_ByteArray, core_Association] :=
  iSVHMACSHA256[macKey, BinarySerialize[core]];

iSVKBWeakPassphraseQ[p_String] := StringLength[p] < 12;

iSVKBSyncFolderQ[path_String] :=
  StringContainsQ[path, "Dropbox" | "OneDrive" | "Google Drive" | "GoogleDrive" |
     "iCloud" | "iCloudDrive", IgnoreCase -> True];

Options[SourceVaultExportKeyBundle] = {
   "Path" -> Automatic, "KeyRefs" -> Automatic,
   "ScryptN" -> Automatic, "Force" -> False};

SourceVaultExportKeyBundle[passphrase_String, OptionsPattern[]] :=
  Module[{path, keyRefs, n, der, wrapped, core, mac, bundle, b64, refsPresent},
    If[iSVKBWeakPassphraseQ[passphrase] && ! TrueQ[OptionValue["Force"]],
      Return[<|"Status" -> "Error", "Reason" -> "WeakPassphrase",
        "Hint" -> "12文字以上を推奨 (diceware 6語等)。\"Force\"->True で強制可。"|>]];
    path = OptionValue["Path"] /. Automatic -> $SourceVaultKeyBundleDefaultPath;
    keyRefs = OptionValue["KeyRefs"] /. Automatic -> iSVKBStandardKeyRefs[];
    n = OptionValue["ScryptN"] /. Automatic -> $SourceVaultKeyBundleScryptN;
    (* 実在する鍵だけを対象に *)
    refsPresent = Select[keyRefs, ! MissingQ[NBAccess`NBKeyStatus[#]] &];
    If[refsPresent === {},
      Return[<|"Status" -> "Error", "Reason" -> "NoKeysFound",
        "Hint" -> "先に SourceVaultInitializeEncryption[] で鍵を用意するか、解錠してください。"|>]];
    der = iSVKBDerive[passphrase, Automatic, n];
    If[der === $Failed, Return[<|"Status" -> "Error", "Reason" -> "KDFFailed"|>]];
    wrapped = NBAccess`NBExportWrappedKeys[refsPresent, der["WrapKey"]];
    If[! AssociationQ[wrapped] || Length[wrapped] === 0,
      Return[<|"Status" -> "Error", "Reason" -> "WrapFailed"|>]];
    core = <|
      "Type" -> "SourceVaultKeyBundle", "Version" -> $SourceVaultKeyBundleVersion,
      "CreatedAt" -> DateString["ISODateTime"],
      "KDF" -> <|"Function" -> "scrypt", "Salt" -> der["Salt"],
         "FunctionParameters" -> <|"KeySize" -> 64, "N" -> der["N"], "r" -> 8, "p" -> 1|>|>,
      "KeyRefs" -> Keys[wrapped], "Keys" -> wrapped|>;
    mac = iSVKBMac[der["MacKey"], core];
    bundle = Append[core, "MAC" -> mac];
    b64 = BaseEncode[BinarySerialize[bundle]];
    Quiet@Check[
      If[! DirectoryQ[DirectoryName[path]],
        CreateDirectory[DirectoryName[path], CreateIntermediateDirectories -> True]];
      Export[path, b64, "Text"], $Failed];
    <|"Status" -> "Exported", "Path" -> path,
      "KeyRefs" -> Keys[wrapped], "KeyCount" -> Length[wrapped],
      "Fingerprints" -> Association[(# -> NBAccess`NBKeyStatus[#]["Fingerprint"]) & /@ Keys[wrapped]],
      "KDF" -> <|"Function" -> "scrypt", "N" -> der["N"]|>,
      "CreatedAt" -> core["CreatedAt"],
      "OnSyncFolderWarning" -> iSVKBSyncFolderQ[path],
      "KeyMaterialReturned" -> False|>];

iSVKBReadBundle[path_String] :=
  Module[{txt, bytes, bundle},
    If[! FileExistsQ[path], Return[$Failed]];
    txt = Quiet@Check[Import[path, "Text"], $Failed];
    If[! StringQ[txt], Return[$Failed]];
    bytes = Quiet@Check[BaseDecode[StringTrim[txt]], $Failed];
    If[Head[bytes] =!= ByteArray, Return[$Failed]];
    bundle = Quiet@Check[BinaryDeserialize[bytes], $Failed];
    If[! AssociationQ[bundle] || Lookup[bundle, "Type", ""] =!= "SourceVaultKeyBundle",
      Return[$Failed]];
    bundle];

SourceVaultKeyBundleInfo[path_String : Automatic] :=
  Module[{p = path /. Automatic -> $SourceVaultKeyBundleDefaultPath, bundle},
    bundle = iSVKBReadBundle[p];
    If[bundle === $Failed,
      Return[<|"Status" -> "Error", "Reason" -> "UnreadableOrMissing", "Path" -> p|>]];
    <|"Status" -> "Ok", "Path" -> p,
      "Version" -> Lookup[bundle, "Version", Missing[]],
      "CreatedAt" -> Lookup[bundle, "CreatedAt", Missing[]],
      "KeyRefs" -> Lookup[bundle, "KeyRefs", {}],
      "KeyCount" -> Length[Lookup[bundle, "KeyRefs", {}]],
      "KDF" -> Lookup[bundle, "KDF", <||>]|>];

Options[SourceVaultImportKeyBundle] = {"Path" -> Automatic};

SourceVaultImportKeyBundle[passphrase_String, OptionsPattern[]] :=
  Module[{path, bundle, kdf, salt, n, der, core, expectMac, gotMac, restored},
    path = OptionValue["Path"] /. Automatic -> $SourceVaultKeyBundleDefaultPath;
    bundle = iSVKBReadBundle[path];
    If[bundle === $Failed,
      Return[<|"Status" -> "Error", "Reason" -> "UnreadableOrMissing", "Path" -> path|>]];
    kdf = Lookup[bundle, "KDF", <||>];
    salt = Lookup[kdf, "Salt", $Failed];
    n = Lookup[Lookup[kdf, "FunctionParameters", <||>], "N", $SourceVaultKeyBundleScryptN];
    If[Head[salt] =!= ByteArray,
      Return[<|"Status" -> "Error", "Reason" -> "BadKDFParams"|>]];
    der = iSVKBDerive[passphrase, salt, n];
    If[der === $Failed, Return[<|"Status" -> "Error", "Reason" -> "KDFFailed"|>]];
    (* MAC 検証 (誤 passphrase / 改ざん検出)。MAC 以外を再構成して照合。 *)
    core = KeyDrop[bundle, "MAC"];
    expectMac = Lookup[bundle, "MAC", $Failed];
    gotMac = iSVKBMac[der["MacKey"], core];
    If[Head[expectMac] =!= ByteArray || gotMac =!= expectMac,
      Return[<|"Status" -> "Error", "Reason" -> "BadPassphraseOrTampered",
        "Hint" -> "passphrase が違うか、バンドルが破損/改ざんされています。"|>]];
    restored = NBAccess`NBImportWrappedKeys[Lookup[bundle, "Keys", <||>], der["WrapKey"]];
    <|"Status" -> "Imported", "Path" -> path,
      "RestoredKeyRefs" -> restored, "RestoredCount" -> Length[restored],
      "Backend" -> NBAccess`$NBCredentialBackend,
      "Fingerprints" -> Association[(# -> NBAccess`NBKeyStatus[#]["Fingerprint"]) & /@ restored]|>];

End[];
EndPackage[];


(* ::Package:: *)

(* ============================================================
   SourceVault_encryptedstore.wl -- at-rest encrypted record (Phase SV-E3 step 5-7)

   This file is encoded in UTF-8.
   Load order: NBAccess_crypto.wl -> SourceVault_crypto.wl -> SourceVault_keys.wl
               -> SourceVault_encryptedstore.wl

   仕様: SourceVault encryption spec v18 §7 (record schema v3) / §8 (Put/Get) / §6.3

   - encrypt-then-MAC を NBAccess keyRef 経由で行う (鍵は SourceVault に出さない)。
   - AAD に Policy / Derived など判定駆動 metadata を含め、改ざんを HMAC で検出する
     (v11/v12 review: per-record policy 完全性)。
   - 失敗時 (wrong key / MAC mismatch / 改ざん) は plaintext を返さない。
   - SourceVaultAssertNoPlaintextLeak で append 前に二重保存・漏洩を検査。

   本フェーズの record store は in-kernel ($iSVEncStore)。JSONL 永続化は後フェーズ。
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultEncryptedPut::usage = "SourceVaultEncryptedPut[obj, opts] は obj を encrypt-then-MAC した record を作り (既定で in-kernel store に保存)、結果 Association を返す。plaintext は保存しない。";
SourceVaultEncryptedGet::usage = "SourceVaultEncryptedGet[recordId] は保存済み暗号 record を返す (plaintext は返さない)。";
SourceVaultDecryptRecord::usage = "SourceVaultDecryptRecord[record] は MAC 検証後に復号し、plaintext を返す。失敗時は Status->Error。";
SourceVaultEncryptedRecordQ::usage = "SourceVaultEncryptedRecordQ[record] は SourceVault 暗号 record か判定する。";
SourceVaultAssertNoPlaintextLeak::usage = "SourceVaultAssertNoPlaintextLeak[record, plaintextObj, sensitiveFields] は serialized record に機密平文が現れないか検査する。";
$SourceVaultPrivateThreshold::usage = "private 判定の PL 閾値 (既定 0.75)。これ以上で plaintext index / digest を抑制する。";
SourceVaultSealPayload::usage = "SourceVaultSealPayload[expr, opts] は任意の WL 式を <|\"Payload\"->expr|> として encrypt-then-MAC で封印した record (Status->Stored, Record->...) を返す。ClaudeRuntime のジョブ I/O 等、式単位の at-rest 封印に使う。既定で in-kernel store には保存しない (\"Persist\"->False)。";
SourceVaultUnsealPayload::usage = "SourceVaultUnsealPayload[record] は SourceVaultSealPayload の record を MAC 検証後に復号し <|\"Status\"->\"Ok\", \"Payload\"->expr|> を返す。改ざん・wrong key 時は Status->Error で plaintext を返さない。";

Begin["`Private`"];

If[! ValueQ[$SourceVaultPrivateThreshold], $SourceVaultPrivateThreshold = 0.75];
If[! AssociationQ[$iSVEncStore], $iSVEncStore = <||>];

iSVEncRecordId[] := "svrec-" <> StringDelete[CreateUUID[], "-"];

(* AAD = 判定駆動 metadata。改ざんすると MAC 不一致になる。 *)
iSVBuildAAD[recordId_, contentType_, policy_, derived_, encMeta_] :=
  <|
    "Type" -> "SourceVaultEncryptedRecord", "SchemaVersion" -> 3,
    "RecordId" -> recordId, "ContentType" -> contentType,
    "Encryption" -> KeyTake[encMeta,
       {"KeyRef", "Mode", "PayloadCanonicalization", "IntegrityMode"}],
    "Policy" -> policy, "Derived" -> derived
  |>;

iSVAuthBytes[aad_, ivB64_, ctB64_] :=
  SourceVault`SourceVaultCanonicalJSONBytes[
    <|"AuthenticatedAssociatedData" -> aad, "IV" -> ivB64, "Ciphertext" -> ctB64|>];

Options[SourceVaultEncryptedPut] = {
  "KeyRef" -> Automatic, "MACKeyRef" -> Automatic,
  "ContentType" -> "Generic", "PrivacyLevel" -> Automatic,
  "AccessTags" -> {}, "SensitiveFields" -> {"Prompt", "Memo", "TargetExprString", "ResolvedMaterial"},
  "CloudSendAllowed" -> False, "Persist" -> True,
  "PlaintextDigest" -> Automatic, "PlaintextIndex" -> Automatic};

SourceVaultEncryptedPut[obj_, OptionsPattern[]] :=
  Module[{encRef, macRef, pthRef, recordId, contentType, pl, tags, sensitive,
     payloadBytes, encR, ctB64, ivB64, encMeta, policy, derived, aad, authBytes,
     mac, checksum, ptDigest, ptIndex, record, leak},
    encRef = OptionValue["KeyRef"] /. Automatic -> SourceVault`$SourceVaultDefaultAtRestKeyRef;
    macRef = OptionValue["MACKeyRef"] /. Automatic -> SourceVault`$SourceVaultDefaultAtRestMACKeyRef;
    pthRef = SourceVault`$SourceVaultDefaultPlaintextHMACKeyRef;
    contentType = OptionValue["ContentType"];
    pl = OptionValue["PrivacyLevel"] /. Automatic -> $SourceVaultPrivateThreshold;
    tags = OptionValue["AccessTags"];
    sensitive = OptionValue["SensitiveFields"];

    If[MissingQ[NBAccess`NBKeyStatus[encRef]] || MissingQ[NBAccess`NBKeyStatus[macRef]],
      Return[<|"Status" -> "Error", "Reason" -> "KeysNotInitialized",
        "Hint" -> "Run SourceVaultInitializeEncryption[] first.", "PlaintextReturned" -> False|>]];

    payloadBytes = SourceVault`SourceVaultCanonicalBytes[obj, "Internal"];
    encR = NBAccess`NBEncryptWithKeyRef[encRef, payloadBytes, "SourceVaultAtRestEncryption"];
    If[! AssociationQ[encR],
      Return[<|"Status" -> "Error", "Reason" -> "EncryptFailed", "PlaintextReturned" -> False|>]];
    ctB64 = encR["CiphertextB64"]; ivB64 = encR["IV"];
    recordId = iSVEncRecordId[];

    encMeta = <|
      "Backend" -> "WolframLanguageNative", "Mode" -> "SymmetricAtRest",
      "KeyRef" -> encRef, "MACKeyRef" -> macRef,
      "PayloadCanonicalization" -> "SourceVaultCanonicalBytes/Internal/v1",
      "AuthenticatedBytesCanonicalization" -> "SourceVaultAtRestAuthenticatedBytes/v1",
      "Algorithm" -> <|"Cipher" -> "AES256", "BlockMode" -> "CBC"|>,
      "IntegrityMode" -> "EncryptThenMAC", "IV" -> ivB64,
      "Ciphertext" -> ctB64, "CiphertextEncoding" -> "Base64"|>;
    policy = <|"PrivacyLevel" -> pl, "CloudSendAllowed" -> TrueQ[OptionValue["CloudSendAllowed"]],
       "RequiresLocalDecrypt" -> True, "DeclassifyRequired" -> True|>;
    derived = <|"PrivacyLevel" -> pl, "AccessTags" -> tags, "DenyTags" -> {}|>;
    aad = iSVBuildAAD[recordId, contentType, policy, derived, encMeta];

    authBytes = iSVAuthBytes[aad, ivB64, ctB64];
    mac = NBAccess`NBMacWithKeyRef[macRef, authBytes, "SourceVaultAtRestMAC"];
    checksum = StringJoin[IntegerString[#, 16, 2] & /@
       Normal[Hash[BaseDecode[ctB64], "SHA256", "ByteArray"]]];

    (* PlaintextDigest: 高 privacy では抑制、低 privacy は keyed HMAC *)
    ptDigest = If[pl >= $SourceVaultPrivateThreshold,
       <|"Mode" -> "Suppressed", "Reason" -> "HighPrivacyLowEntropyContent"|>,
       <|"Mode" -> "HMAC-SHA256", "KeyRef" -> pthRef,
         "Value" -> NBAccess`NBMacWithKeyRef[pthRef,
            SourceVault`SourceVaultCanonicalJSONBytes[obj], "SourceVaultPlaintextDigest"],
         "StableAcrossKeyRotation" -> True|>];
    ptIndex = If[pl >= $SourceVaultPrivateThreshold,
       <|"IndexPolicy" -> "Suppressed", "PublicSummary" -> Missing["Suppressed"],
         "SearchTokens" -> Missing["Suppressed"]|>,
       <|"IndexPolicy" -> "PublicOnly", "PublicSummary" -> Missing["NotProvided"],
         "SearchTokens" -> Missing["NotProvided"]|>];

    record = <|
      "Type" -> "SourceVaultEncryptedRecord", "SchemaVersion" -> 3,
      "RecordId" -> recordId, "ContentType" -> contentType,
      "CreatedAt" -> DateString["ISODateTime"],
      "Encryption" -> Join[encMeta, <|
         "AuthenticatedAssociatedData" -> aad,
         "CiphertextChecksum" -> <|"Algorithm" -> "SHA256", "Value" -> checksum,
            "SecurityMeaning" -> "AccidentalCorruptionOnly"|>,
         "CiphertextHMAC" -> <|"Algorithm" -> "HMAC-SHA256",
            "AuthenticatedBytes" -> "SourceVaultAtRestAuthenticatedBytes/v1", "Value" -> mac|>,
         "PlaintextDigest" -> ptDigest|>],
      "PlaintextIndex" -> ptIndex,
      "Policy" -> policy, "Derived" -> derived,
      "Provenance" -> <|"CreatedBy" -> "SourceVaultEncryptedPut"|>|>;

    leak = SourceVaultAssertNoPlaintextLeak[record, obj, sensitive];
    If[! leak["NoLeak"],
      Return[<|"Status" -> "Error", "Reason" -> "PlaintextLeakDetected",
        "Leaked" -> leak["Leaked"], "PlaintextPersisted" -> False, "PlaintextReturned" -> False|>]];

    If[TrueQ[OptionValue["Persist"]], AssociateTo[$iSVEncStore, recordId -> record]];
    <|"Status" -> "Stored", "RecordId" -> recordId, "Record" -> record,
      "PlaintextPersisted" -> False, "PlaintextReturned" -> False|>];

SourceVaultEncryptedRecordQ[record_] :=
  AssociationQ[record] && record["Type"] === "SourceVaultEncryptedRecord" &&
   AssociationQ[record["Encryption"]] && StringQ[record["Encryption"]["Ciphertext"]];

SourceVaultEncryptedGet[recordId_String] :=
  Lookup[$iSVEncStore, recordId, Missing["NotFound"]];

SourceVaultDecryptRecord[record_, opts : OptionsPattern[]] :=
  Module[{e, aad, ivB64, ctB64, macRef, encRef, expectMac, authBytes, ok, pt},
    If[! SourceVaultEncryptedRecordQ[record],
      Return[<|"Status" -> "Error", "Reason" -> "UnsupportedVersion", "PlaintextReturned" -> False|>]];
    e = record["Encryption"];
    aad = e["AuthenticatedAssociatedData"]; ivB64 = e["IV"]; ctB64 = e["Ciphertext"];
    macRef = e["MACKeyRef"]; encRef = e["KeyRef"];
    expectMac = e["CiphertextHMAC"]["Value"];
    If[! StringQ[expectMac],
      Return[<|"Status" -> "Error", "Reason" -> "MalformedRecord", "PlaintextReturned" -> False|>]];
    authBytes = iSVAuthBytes[aad, ivB64, ctB64];
    ok = NBAccess`NBVerifyMacWithKeyRef[macRef, authBytes, expectMac, "SourceVaultAtRestMAC"];
    If[! TrueQ[ok],
      Return[<|"Status" -> "Error", "Reason" -> "AuthenticationFailed", "PlaintextReturned" -> False|>]];
    pt = NBAccess`NBDecryptWithKeyRef[encRef, ctB64, "SourceVaultAtRestDecrypt"];
    If[Head[pt] =!= ByteArray,
      Return[<|"Status" -> "Error", "Reason" -> "WrongKey", "PlaintextReturned" -> False|>]];
    <|"Status" -> "Ok", "PlaintextReturned" -> True,
      "Plaintext" -> BinaryDeserialize[pt]|>];

SourceVaultAssertNoPlaintextLeak[record_, plaintextObj_, sensitiveFields_List] :=
  Module[{recStr, leaked, vals},
    recStr = ToString[record, InputForm];
    vals = If[AssociationQ[plaintextObj],
      Select[Lookup[plaintextObj, sensitiveFields, Nothing], StringQ[#] && StringLength[#] > 0 &],
      {}];
    leaked = Select[vals, StringContainsQ[recStr, #] &];
    <|"NoLeak" -> (Length[leaked] === 0), "Leaked" -> leaked|>];

(* ─── 式単位の封印/開封 (ジョブ I/O など。任意 WL 式を 1 record に閉じ込める) ─── *)
SourceVaultSealPayload[expr_, opts : OptionsPattern[SourceVaultEncryptedPut]] :=
  SourceVaultEncryptedPut[<|"Payload" -> expr|>,
    opts, "Persist" -> False, "ContentType" -> "RuntimePayload",
    "SensitiveFields" -> {"Payload"}];

SourceVaultUnsealPayload[record_] :=
  Module[{d},
    If[! SourceVaultEncryptedRecordQ[record],
      Return[<|"Status" -> "Error", "Reason" -> "NotEncryptedRecord",
        "PlaintextReturned" -> False|>]];
    d = SourceVaultDecryptRecord[record];
    If[Lookup[d, "Status", "Error"] =!= "Ok", Return[d]];
    <|"Status" -> "Ok", "PlaintextReturned" -> True,
      "Payload" -> Lookup[d["Plaintext"], "Payload", Missing["NoPayload"]]|>];

End[];
EndPackage[];


(* ::Package:: *)

(* ============================================================
   SourceVault_release.wl -- cloud materialization 強制ゲート (Phase SV-E3 / spec v18 §9.3)

   This file is encoded in UTF-8.
   Load order: ... -> SourceVault_encryptedstore.wl -> SourceVault_release.wl

   暗号化/private record を cloud route へ materialize (= 平文化して送信) する唯一経路で
   必ず通すゲート。fail-closed: 条件が満たせない・不明・PL 欠落は Deny。

   §9.3 判定 (cloud route の場合、すべて必要):
     1. record Policy CloudSendAllowed === True
     2. RequiresLocalDecrypt =!= True
     3. PrivacyLevel <= cloud threshold
     4. Declassify または明示承認 ticket がある
     5. (任意強制) NBAuthorize が Permit
   local route は対象外 (ローカル復号は RequiresLocalDecrypt と矛盾しない)。
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultAuthorizeRecordMaterialization::usage =
  "SourceVaultAuthorizeRecordMaterialization[record, targetRoute, purpose_:\"Materialize\", opts] は record を targetRoute (\"cloud\"|\"local\"|assoc) へ平文化してよいか判定する。cloud route では CloudSendAllowed / RequiresLocalDecrypt / PrivacyLevel / Declassify / (任意)NBAuthorize を fail-closed で評価し、<|Decision->\"Allow\"|\"Deny\", Reasons->{...}, CloudRoute->_|> を返す。";
SourceVaultMaterializeRecord::usage =
  "SourceVaultMaterializeRecord[record, targetRoute, purpose_:\"Materialize\", opts] は materialization を認可した場合のみ復号 plaintext を返す。拒否時は plaintext を返さない。";
$SourceVaultCloudThreshold::usage =
  "cloud route に平文を出してよい PrivacyLevel 上限 (既定 0.5)。";

Begin["`Private`"];

If[! ValueQ[$SourceVaultCloudThreshold], $SourceVaultCloudThreshold = 0.5];

iSVCloudRouteQ[targetRoute_] :=
  Which[
    StringQ[targetRoute],
      StringContainsQ[ToLowerCase[targetRoute], "cloud"],
    AssociationQ[targetRoute],
      Module[{k = ToLowerCase[ToString[Lookup[targetRoute, "Kind",
          Lookup[targetRoute, "Route", ""]]]]},
        StringContainsQ[k, "cloud"]],
    True, False];

(* PrivacyLevel は Policy / Derived の最大。欠落は fail-safe で 1.0 (最高) とみなす。 *)
iSVRecordPL[record_] :=
  Module[{vals},
    vals = Select[{
       Quiet@Check[record["Policy", "PrivacyLevel"], Missing[]],
       Quiet@Check[record["Derived", "PrivacyLevel"], Missing[]]}, NumericQ];
    If[vals === {}, 1.0, Max[vals]]];

Options[SourceVaultAuthorizeRecordMaterialization] = {
  "Declassify" -> False, "ApprovalTicket" -> None,
  "CloudThreshold" -> Automatic,
  "RequireNBAuthorize" -> False, "NBAuthorizeDecision" -> Automatic};

SourceVaultAuthorizeRecordMaterialization[record_, targetRoute_,
   purpose_String : "Materialize", OptionsPattern[]] :=
  Module[{cloudQ, policy, cloudAllowed, requiresLocal, pl, threshold,
     declassify, ticket, reasons, nbReq, nbDec, decision},
    cloudQ = iSVCloudRouteQ[targetRoute];
    If[! AssociationQ[record],
      Return[<|"Decision" -> "Deny", "Reasons" -> {"MalformedRecord"},
        "CloudRoute" -> cloudQ|>]];

    (* local route: ローカル復号は許可 (RequiresLocalDecrypt を満たす) *)
    If[! cloudQ,
      Return[<|"Decision" -> "Allow", "Reasons" -> {"LocalRoute"},
        "CloudRoute" -> False|>]];

    policy = Lookup[record, "Policy", <||>];
    cloudAllowed = TrueQ[Lookup[policy, "CloudSendAllowed", False]];
    requiresLocal = TrueQ[Lookup[policy, "RequiresLocalDecrypt", True]];
    pl = iSVRecordPL[record];
    threshold = OptionValue["CloudThreshold"] /. Automatic -> $SourceVaultCloudThreshold;
    ticket = OptionValue["ApprovalTicket"];
    declassify = TrueQ[OptionValue["Declassify"]] || (ticket =!= None && ticket =!= False);
    nbReq = TrueQ[OptionValue["RequireNBAuthorize"]];
    nbDec = OptionValue["NBAuthorizeDecision"];

    reasons = {};
    If[! cloudAllowed, AppendTo[reasons, "CloudSendNotAllowed"]];
    If[requiresLocal, AppendTo[reasons, "RequiresLocalDecrypt"]];
    If[! (NumericQ[pl] && pl <= threshold), AppendTo[reasons, "AbovePrivacyThreshold"]];
    If[! declassify, AppendTo[reasons, "NoDeclassifyOrApproval"]];
    (* NBAuthorize: 既定は veto 層。RequireNBAuthorize->True で Permit 必須。 *)
    If[nbReq && nbDec =!= "Permit", AppendTo[reasons, "NBAuthorizeNotPermitted"]];
    If[nbDec === "Deny", AppendTo[reasons, "NBAuthorizeDenied"]];

    decision = If[reasons === {}, "Allow", "Deny"];
    <|"Decision" -> decision, "Reasons" -> reasons, "CloudRoute" -> True,
      "PrivacyLevel" -> pl, "Threshold" -> threshold|>];

Options[SourceVaultMaterializeRecord] = Options[SourceVaultAuthorizeRecordMaterialization];

SourceVaultMaterializeRecord[record_, targetRoute_,
   purpose_String : "Materialize", opts : OptionsPattern[]] :=
  Module[{auth, dec},
    auth = SourceVaultAuthorizeRecordMaterialization[record, targetRoute, purpose, opts];
    If[auth["Decision"] =!= "Allow",
      Return[<|"Status" -> "Denied", "Reasons" -> auth["Reasons"],
        "CloudRoute" -> auth["CloudRoute"], "PlaintextReturned" -> False|>]];
    dec = SourceVault`SourceVaultDecryptRecord[record];
    If[Lookup[dec, "Status", ""] =!= "Ok",
      Return[<|"Status" -> "Error", "Reason" -> Lookup[dec, "Reason", "DecryptFailed"],
        "PlaintextReturned" -> False|>]];
    <|"Status" -> "Ok", "PlaintextReturned" -> True,
      "Plaintext" -> dec["Plaintext"], "CloudRoute" -> auth["CloudRoute"]|>];

End[];
EndPackage[];
