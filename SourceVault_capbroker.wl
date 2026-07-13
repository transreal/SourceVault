(* ::Package:: *)

(* ============================================================
   SourceVault_capbroker.wl -- Cane Phase 1H-S: capability broker
   (CapabilityLease atomic ledger + PreparedInputToken)

   This file is encoded in UTF-8.
   仕様: sourcevault_cane_knowledge_home_mining_spec_v0_7.md §4.21/4.21b/4.22/4.22b、
         Phase 0 decision D-5(層合成: Grant→ActionGate→mint→**atomic consume+dispatch のみ本 broker**。
         authorization は再実装しない=ParentDecisionRef で上流 decision を参照)。

   原則(I-14 実行契約):
     - ledger が正準(token 内 RemainingUses を判定に使わない)。consume は lock 下の read-modify-write
       (単一 writer)で原子的。同一 LeaseId の replay 拒否。
     - consume と dispatch の間の TOCTOU は「consume と同一 transaction で one-time ExecutionTicket を
       発行し、実行系は ticket redeem(one-shot)後にのみ実行」で排除。crash 等で redeem されなければ
       ticket は短 TTL で失効し、action は再実行されない(indeterminate 非再実行)。
     - mint は内部関数のみ(public は Request/Verify/Consume/Redeem/Revoke)。IssuerRef は broker が付与。
     - capability kind(read|write|network|secret|send|publish|delete)は 1 lease に 1 つ。
     - token/MAC を prompt・ログへ出さない(本モジュールは値を print しない)。
     - PreparedInputToken は request envelope 全体の canonical digest に bind し、送信直前に再計算検証+
       one-shot consume(replay 防止)。
   ledger 物理: <LocalState>/capbroker/(機械ローカル・非同期)。鍵: NBAccess MAC KeyRef。
   ============================================================ *)

BeginPackage["SourceVault`"];

SourceVaultCapBrokerInitialize::usage =
  "SourceVaultCapBrokerInitialize[opts] は broker(ledger dir + MAC 鍵)を初期化する(冪等)。" <>
  "オプション \"Root\"(Automatic=<LocalState>/capbroker)。";
SourceVaultRequestCapabilityLease::usage =
  "SourceVaultRequestCapabilityLease[request] は lease を申請する(public 面。mint は内部)。" <>
  "必須: RunRef, ActorRef, CapabilityKind(read|write|network|secret|send|publish|delete の 1 つ), " <>
  "AllowedOperation, TargetScope, Purpose, **ParentDecisionRef**(上流 Grant/ActionGate decision。" <>
  "broker は authorization を再実装しない=D-5)。任意: TTLSeconds(120), MaxUses(1=one-shot), " <>
  "MaxPrivacyLevel, DenyTags。IssuerRef は呼び出し引数から受け取らず broker が付与。戻り値 = MAC 付き lease token。";
SourceVaultVerifyCapabilityLease::usage =
  "SourceVaultVerifyCapabilityLease[token, action] は MAC・ledger 状態(issued)・期限(broker 時刻)・" <>
  "action の bind(CapabilityKind/AllowedOperation/TargetScope)を検証する(consume しない)。";
SourceVaultConsumeCapabilityLease::usage =
  "SourceVaultConsumeCapabilityLease[token, action] は lock 下で ledger を原子的に consume し、" <>
  "**同一 transaction で one-time ExecutionTicket**(短 TTL)を発行する(TOCTOU 排除)。" <>
  "同一 lease の再 consume は Failure(replay 拒否)。戻り値 <|Status, ExecutionTicket|>。";
SourceVaultRedeemExecutionTicket::usage =
  "SourceVaultRedeemExecutionTicket[ticket] は実行直前の one-shot redeem。二重 redeem・期限切れは Failure" <>
  "(crash 後の再実行防止=indeterminate 非再実行)。";
SourceVaultRevokeCapabilityLeases::usage =
  "SourceVaultRevokeCapabilityLeases[runRef|All] は run の未消費 lease を一括失効する(containment)。";
SourceVaultCapabilityLeaseLedger::usage =
  "SourceVaultCapabilityLeaseLedger[leaseId] は ledger record(state/UsesConsumed 等。鍵材料なし)を返す。";

SourceVaultPrepareLLMInput::usage =
  "SourceVaultPrepareLLMInput[envelope, opts] は LLM request envelope 全体(model/deployment/messages/" <>
  "tool schemas/retrieval refs/isolation profile/privacy decision/capability ceiling/output schema)の" <>
  "canonical digest に bind した one-shot token を発行する(§4.22b PreparedRequestDigest)。" <>
  "オプション \"TTLSeconds\"(300)。envelope には RunRef/StepRef/Provider を含めること。";
SourceVaultVerifyPreparedRequest::usage =
  "SourceVaultVerifyPreparedRequest[token, envelope] は送信直前に digest を再計算して照合し(prepare 後の" <>
  "差し替え=model/messages/tool schema/endpoint 等の変更を拒否)、MAC・期限を検証して one-shot consume する。" <>
  "再 verify(replay)は Failure。";

Begin["`Private`"];

$svCapMacKeyRef = "svcap:mac:v1";

iCapULID[] := Module[{ms = Round[(AbsoluteTime[] - AbsoluteTime[{1970, 1, 1, 0, 0, 0}, TimeZone -> 0])*1000],
   rnd = FromDigits[StringTake[StringDelete[CreateUUID[], "-"], 20], 16],
   cs = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"], f},
  f = Function[{n, len}, StringJoin@Module[{d = {}, x = n},
    Do[PrependTo[d, cs[[Mod[x, 32] + 1]]]; x = Quotient[x, 32], {len}]; d]];
  f[ms, 10] <> f[Mod[rnd, 32^16], 16]];
iCapNow[] := AbsoluteTime[];   (* broker 時刻(単一機械)。expiry 判定はこれのみ *)

iCapRoot[rootOpt_] := Module[{ls},
  rootOpt /. Automatic :> (ls = SourceVaultRoot["LocalState"];
    If[! StringQ[ls], Missing["LocalStateUnresolved"], FileNameJoin[{ls, "capbroker"}]])];
$svCapRoot = Automatic;

iCapDir[sub_] := Module[{r = iCapRoot[$svCapRoot], d},
  If[! StringQ[r], Return[$Failed]];
  d = FileNameJoin[{r, sub}];
  If[! DirectoryQ[d], Quiet@CreateDirectory[d, CreateIntermediateDirectories -> True]]; d];

(* ID のコロンは Windows で NTFS ADS を作る → ファイル名だけ sanitize(正準 ID は不変) *)
iCapFile[dir_, id_] := FileNameJoin[{dir, StringReplace[id, Except[WordCharacter | "-"] -> "_"] <> ".json"}];

iCapJSON[x_] := ExportByteArray[x /. m_Missing :> Null, "RawJSON", "Compact" -> True];
(* 上書き write。ledger record は 1 ファイル= 現在状態。Export の直接上書きで十分(WithLock 下で排他)。 *)
iCapWrite[path_, assoc_] := Module[{strm},
  strm = OpenWrite[path, BinaryFormat -> True];
  BinaryWrite[strm, Normal[iCapJSON[assoc]]];
  Close[strm]];
iCapRead[path_] := If[! FileExistsQ[path], Missing["NotFound"],
  Quiet@Check[ImportByteArray[ByteArray[BinaryReadList[path, "Byte"]], "RawJSON"], Missing["Corrupt"]]];

(* canonical digest: crypto の canonical JSON を優先、無ければ WL Hash fallback *)
iCapDigest[expr_] := If[Length[DownValues[SourceVaultCanonicalJSONBytes]] > 0,
  IntegerString[Hash[Normal[Quiet@Check[SourceVaultCanonicalJSONBytes[expr /. m_Missing :> Null],
    BinarySerialize[expr]]]], 36],
  IntegerString[Hash[expr], 36]];

iCapEnsureKeys[] := If[! TrueQ[Quiet@Check[NBAccess`NBKeyMaterialExistsQ[$svCapMacKeyRef], False]],
  NBAccess`NBGenerateMacKeyRef[$svCapMacKeyRef, <|"Purpose" -> "SVCapBrokerMAC"|>]];
iCapMac[payload_Association] := Quiet@Check[
  NBAccess`NBMacWithKeyRef[$svCapMacKeyRef, iCapJSON[payload], "SVCapToken"], $Failed];
iCapMacOK[token_Association] := Module[{mac = Lookup[token, "MAC", ""], calc},
  calc = iCapMac[KeyDrop[token, "MAC"]];
  StringQ[calc] && calc === mac];

Options[SourceVaultCapBrokerInitialize] = {"Root" -> Automatic};
SourceVaultCapBrokerInitialize[OptionsPattern[]] := Module[{},
  $svCapRoot = OptionValue["Root"];
  If[iCapDir["leases"] === $Failed, Return[Failure["CapRootUnresolved", <||>]]];
  iCapDir["prepared"]; iCapEnsureKeys[];
  <|"Status" -> "Initialized", "Root" -> iCapRoot[$svCapRoot]|>];

$svCapKinds = {"read", "write", "network", "secret", "send", "publish", "delete"};

(* ---- lease: request(mint は内部)---- *)
SourceVaultRequestCapabilityLease[req_Association] := Module[
  {kind, lease, ledger, dir, exp},
  If[iCapDir["leases"] === $Failed, Return[Failure["CapRootUnresolved", <||>]]];
  iCapEnsureKeys[];
  kind = Lookup[req, "CapabilityKind", Missing[]];
  Which[
    ! MemberQ[$svCapKinds, kind],
      Failure["BadCapabilityKind", <|"MessageTemplate" -> "CapabilityKind は 1 種(read|write|network|secret|send|publish|delete)。"|>],
    ! AllTrue[{"RunRef", "ActorRef", "AllowedOperation", "TargetScope", "Purpose"},
        StringQ[Lookup[req, #, Missing[]]] &],
      Failure["BadLeaseRequest", <|"MessageTemplate" -> "RunRef/ActorRef/AllowedOperation/TargetScope/Purpose が必要です。"|>],
    MissingQ[Lookup[req, "ParentDecisionRef", Missing[]]],
      Failure["NoParentDecision", <|"MessageTemplate" ->
        "ParentDecisionRef(上流 Grant/ActionGate decision)が必要です(D-5: broker は authorization を再実装しない)。"|>],
    True,
    exp = iCapNow[] + Lookup[req, "TTLSeconds", 120];
    lease = <|"LeaseId" -> "svlease:" <> iCapULID[],
      "IssuerRef" -> "svbroker:" <> ToString[$MachineName],   (* 呼び出し側の IssuerRef は無視 *)
      "RunRef" -> req["RunRef"], "ActorRef" -> req["ActorRef"],
      "CapabilityKind" -> kind, "AllowedOperation" -> req["AllowedOperation"],
      "TargetScope" -> req["TargetScope"], "Purpose" -> req["Purpose"],
      "MaxPrivacyLevel" -> Lookup[req, "MaxPrivacyLevel", 0.5],
      "DenyTags" -> Lookup[req, "DenyTags", {}],
      "ExpiresAt" -> exp, "MaxUses" -> Lookup[req, "MaxUses", 1],
      "ParentDecisionRef" -> req["ParentDecisionRef"], "KeyId" -> $svCapMacKeyRef|>;
    lease["MAC"] = iCapMac[lease];
    ledger = <|"LeaseId" -> lease["LeaseId"], "State" -> "issued", "UsesConsumed" -> 0,
      "RunRef" -> lease["RunRef"], "CapabilityKind" -> kind,
      "AllowedOperation" -> lease["AllowedOperation"], "TargetScope" -> lease["TargetScope"],
      "ExpiresAt" -> exp, "MaxUses" -> lease["MaxUses"],
      "LastConsumeAttemptAt" -> Missing[], "ConsumedByRunRef" -> Missing[],
      "TicketId" -> Missing[], "TicketExpiresAt" -> Missing[], "TicketRedeemed" -> False,
      "Version" -> 1|>;
    SourceVaultWithLock["svcapledger",
      iCapWrite[iCapFile[iCapDir["leases"], lease["LeaseId"]], ledger]];
    lease]];

iCapActionBindOK[rec_Association, action_Association] :=
  Lookup[action, "CapabilityKind", ""] === rec["CapabilityKind"] &&
  Lookup[action, "Operation", ""] === rec["AllowedOperation"] &&
  StringQ[Lookup[action, "Target", Missing[]]] &&
  StringMatchQ[action["Target"], rec["TargetScope"]];   (* TargetScope は string pattern *)

SourceVaultCapabilityLeaseLedger[leaseId_String] :=
  iCapRead[iCapFile[iCapDir["leases"], leaseId]];

SourceVaultVerifyCapabilityLease[token_Association, action_Association] := Module[{rec},
  Which[
    ! iCapMacOK[token], Failure["BadMAC", <||>],
    True,
    rec = SourceVaultCapabilityLeaseLedger[token["LeaseId"]];
    Which[
      ! AssociationQ[rec], Failure["NoLedgerRecord", <||>],
      rec["State"] =!= "issued", Failure["LeaseNotIssued", <|"State" -> rec["State"]|>],
      iCapNow[] > rec["ExpiresAt"], Failure["LeaseExpired", <||>],
      ! iCapActionBindOK[rec, action], Failure["ActionBindMismatch", <||>],
      True, <|"Status" -> "Valid", "LeaseId" -> token["LeaseId"]|>]]];

SourceVaultConsumeCapabilityLease[token_Association, action_Association] := Module[{v},
  v = SourceVaultVerifyCapabilityLease[token, action];
  If[FailureQ[v], Return[v]];
  SourceVaultWithLock["svcapledger",
    Module[{path = iCapFile[iCapDir["leases"], token["LeaseId"]], rec, ticket},
      rec = iCapRead[path];   (* lock 下で再読(CAS 相当) *)
      Which[
        ! AssociationQ[rec], Failure["NoLedgerRecord", <||>],
        rec["State"] =!= "issued", Failure["LeaseAlreadyConsumed", <|"State" -> rec["State"]|>],
        iCapNow[] > rec["ExpiresAt"], Failure["LeaseExpired", <||>],
        True,
        ticket = <|"TicketId" -> "svticket:" <> iCapULID[], "LeaseId" -> token["LeaseId"],
          "ActionDigest" -> iCapDigest[action], "ExpiresAt" -> iCapNow[] + 30,
          "KeyId" -> $svCapMacKeyRef|>;
        ticket["MAC"] = iCapMac[ticket];
        rec = Join[rec, <|"State" -> If[rec["UsesConsumed"] + 1 >= rec["MaxUses"], "consumed", "issued"],
          "UsesConsumed" -> rec["UsesConsumed"] + 1,
          "LastConsumeAttemptAt" -> iCapNow[], "ConsumedByRunRef" -> Lookup[action, "RunRef", Missing[]],
          "TicketId" -> ticket["TicketId"], "TicketExpiresAt" -> ticket["ExpiresAt"],
          "TicketRedeemed" -> False, "Version" -> rec["Version"] + 1|>];
        iCapWrite[path, rec];
        <|"Status" -> "Consumed", "ExecutionTicket" -> ticket|>]]]];

SourceVaultRedeemExecutionTicket[ticket_Association] := Module[{},
  If[! iCapMacOK[ticket], Return[Failure["BadMAC", <||>]]];
  SourceVaultWithLock["svcapledger",
    Module[{path = iCapFile[iCapDir["leases"], ticket["LeaseId"]], rec},
      rec = iCapRead[path];
      Which[
        ! AssociationQ[rec], Failure["NoLedgerRecord", <||>],
        rec["TicketId"] =!= ticket["TicketId"], Failure["UnknownTicket", <||>],
        TrueQ[rec["TicketRedeemed"]], Failure["TicketAlreadyRedeemed", <||>],
        iCapNow[] > rec["TicketExpiresAt"], Failure["TicketExpired", <||>],
        True,
        iCapWrite[path, Join[rec, <|"TicketRedeemed" -> True, "Version" -> rec["Version"] + 1|>]];
        <|"Status" -> "Redeemed", "TicketId" -> ticket["TicketId"]|>]]]];

SourceVaultRevokeCapabilityLeases[runRefOrAll_] :=
  SourceVaultWithLock["svcapledger",
    Module[{dir = iCapDir["leases"], files, n = 0},
      files = FileNames["*.json", dir];
      Scan[Function[f, Module[{rec = iCapRead[f]},
        If[AssociationQ[rec] && rec["State"] === "issued" &&
            (runRefOrAll === All || rec["RunRef"] === runRefOrAll),
          iCapWrite[f, Join[rec, <|"State" -> "revoked", "Version" -> rec["Version"] + 1|>]]; n++]]],
        files];
      <|"Revoked" -> n|>]];

(* ---- PreparedInputToken(§4.22/4.22b)---- *)
$svCapEnvelopeKeys = {"Provider", "Model", "Deployment", "Messages", "ToolSchemas",
  "RetrievalRefs", "IsolationProfile", "PrivacyDecisionRef", "CapabilityCeiling",
  "OutputSchema", "RunRef", "StepRef"};

iCapEnvelopeDigest[env_Association] := iCapDigest[KeyTake[env, $svCapEnvelopeKeys]];

Options[SourceVaultPrepareLLMInput] = {"TTLSeconds" -> 300};
SourceVaultPrepareLLMInput[env_Association, OptionsPattern[]] := Module[{tok, dir},
  dir = iCapDir["prepared"]; If[dir === $Failed, Return[Failure["CapRootUnresolved", <||>]]];
  iCapEnsureKeys[];
  If[! StringQ[Lookup[env, "RunRef", Missing[]]],
    Return[Failure["BadEnvelope", <|"MessageTemplate" -> "envelope に RunRef が必要です。"|>]]];
  tok = <|"PreparedInputId" -> "svprep:" <> iCapULID[],
    "PreparedRequestDigest" -> iCapEnvelopeDigest[env],
    "RunRef" -> env["RunRef"], "StepRef" -> Lookup[env, "StepRef", Missing[]],
    "Provider" -> Lookup[env, "Provider", Missing[]],
    "ExpiresAt" -> iCapNow[] + OptionValue["TTLSeconds"], "KeyId" -> $svCapMacKeyRef|>;
  tok["MAC"] = iCapMac[tok];
  SourceVaultWithLock["svcapledger",
    iCapWrite[iCapFile[dir, tok["PreparedInputId"]],
      <|"PreparedInputId" -> tok["PreparedInputId"], "State" -> "issued",
        "ExpiresAt" -> tok["ExpiresAt"]|>]];
  tok];

SourceVaultVerifyPreparedRequest[token_Association, env_Association] := Module[{},
  Which[
    ! iCapMacOK[token], Failure["BadMAC", <||>],
    iCapNow[] > Lookup[token, "ExpiresAt", 0], Failure["TokenExpired", <||>],
    iCapEnvelopeDigest[env] =!= token["PreparedRequestDigest"],
      Failure["RequestMismatch", <|"MessageTemplate" ->
        "prepare 後に request envelope が変更されています(model/messages/tool schema/endpoint 等)。送信拒否。"|>],
    True,
    SourceVaultWithLock["svcapledger",
      Module[{path = iCapFile[iCapDir["prepared"], token["PreparedInputId"]], rec},
        rec = iCapRead[path];
        Which[
          ! AssociationQ[rec], Failure["NoLedgerRecord", <||>],
          rec["State"] =!= "issued", Failure["TokenAlreadyUsed", <||>],  (* one-shot: replay 拒否 *)
          True,
          iCapWrite[path, Join[rec, <|"State" -> "consumed"|>]];
          <|"Status" -> "Verified", "PreparedInputId" -> token["PreparedInputId"]|>]]]]];

End[];

EndPackage[];
