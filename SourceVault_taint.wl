(* ::Package:: *)

(* ============================================================
   SourceVault_taint.wl -- Cane Phase 1H-S: taint 伝播 / InputTrustAssessment / RunIntegrityState
   This file is encoded in UTF-8.

   仕様: sourcevault_cane_knowledge_home_mining_spec_v0_7.md
     §4.17  InputTrustAssessment(SecurityPreScan の正準化・拡張)
     §4.17b/4.17c CrossObjectRisk の source graph 合成 / taint 伝播 edge 表(content-carrying のみ)
     §4.18/4.18b RunIntegrityState / RunIntegrityTransitioned(step 単位)
     I-14  taint 非降下(LLM/reducer/多数決で解除不可。解除は owner か決定的 sanitizer の明示 decision のみ)

   原則:
     - taint は PropagationEdge を経由し、CarriesContent=True かつ寄与 span のある content-carrying
       edge のみ伝播(Cites/RelatedTo/SameTopic は伝播しない)。派生物は source の SafetyState/taint を継承。
     - CrossObjectRisk は source graph(mail body→attachment→extracted→summary→claim 等)から合成
       (0 固定を廃止)。container は「一部 tainted」と「全体 quarantined」を区別。
     - 決定的・LLM 不使用。純関数(SecurityPreScan の結果を入力に取る)。
   ============================================================ *)

BeginPackage["SourceVault`"];

SourceVaultAssessInputTrust::usage =
  "SourceVaultAssessInputTrust[input] は §4.17 InputTrustAssessment を返す(SecurityPreScan の正準化)。" <>
  "input: <|InputRef, Text, (SourceKind), (OriginRef), (InstructionAuthority)|> または生 text。" <>
  "戻り値 <|InputRef, SourceKind, InstructionAuthority(既定 UntrustedData), AdversarialSignals, " <>
  "PromptInjectionScore, ToolMisuseScore, ExfiltrationScore, ObfuscationSignals, SafetyState, " <>
  "RequiredIsolationProfile, MatchedRules|>。InstructionAuthority は content の自己申告で昇格しない。";
SourceVaultTaintEdgeCarriesContentQ::usage =
  "SourceVaultTaintEdgeCarriesContentQ[edgeKind] は §4.17c 表で taint を伝播する content-carrying edge か。" <>
  "DerivedFrom/Contains/ExtractedFrom/SummarizedFrom/QuotedFrom/AttachmentOf = True、" <>
  "Cites/RelatedTo/SameTopic/OwnerReviewed = False。";
SourceVaultComposeCrossObjectRisk::usage =
  "SourceVaultComposeCrossObjectRisk[targetRef, edges, assessments] は source graph 上で target へ到達する" <>
  "content-carrying edge 経由の risk を合成する(§4.17b。0 固定を廃止)。edges: {PropagationEdge...}、" <>
  "assessments: <|ref -> InputTrustAssessment|>。戻り値 <|CrossObjectRisk, ContributingSpanRefs, TaintPath, " <>
  "InheritedSafetyState, PartialTaint(一部) vs WholeQuarantined(全体)|>。";
SourceVaultPropagateTaint::usage =
  "SourceVaultPropagateTaint[derivedRef, sourceRefs, edgeKind, assessments, opts] は派生物へ source の " <>
  "taint/SafetyState を継承する(I-14 非降下)。content-carrying でない edge は伝播しない。" <>
  "戻り値 PropagationEdge + 継承 SafetyState。opts \"ContributingSpanRefs\"、\"TransformRef\"、\"Direction\"。";
SourceVaultTaintDeclassify::usage =
  "SourceVaultTaintDeclassify[targetRef, decision, opts] は taint 解除を試みる。owner の明示 decision か " <>
  "決定的 sanitizer(\"SanitizerResult\"->True)のみ許可(I-14: LLM/多数決では解除不可)。それ以外は Failure。";
SourceVaultTransitionRunIntegrity::usage =
  "SourceVaultTransitionRunIntegrity[runRef, toState, opts] は §4.18b RunIntegrityTransitioned(step 単位)を" <>
  "記録する。toState: Clean|Uncertain|CompromiseSuspected|Contained。opts \"StepRef\"、\"TriggerObservationRefs\"、" <>
  "\"AffectedArtifactRefs\"、\"Persist\"(True)。Clean は「既知 signal なし+gate 通過」の限定的意味(証明でない)。";
SourceVaultRunIntegrityState::usage =
  "SourceVaultRunIntegrityState[runRef] は transition の replay で現在の IntegrityState と TaintLabels を返す。";

Begin["`Private`"];

iTaintULID[] := Module[{ms = Round[(AbsoluteTime[] - AbsoluteTime[{1970, 1, 1, 0, 0, 0}, TimeZone -> 0])*1000],
   rnd = FromDigits[StringTake[StringDelete[CreateUUID[], "-"], 20], 16],
   cs = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"], f},
  f = Function[{n, len}, StringJoin@Module[{d = {}, x = n},
    Do[PrependTo[d, cs[[Mod[x, 32] + 1]]]; x = Quotient[x, 32], {len}]; d]];
  f[ms, 10] <> f[Mod[rnd, 32^16], 16]];
iTaintNow[] := DateString[Now, {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"},
  TimeZone -> 0];

(* content-carrying edge 表(§4.17c) *)
$svTaintCarry = <|"DerivedFrom" -> True, "Contains" -> True, "ExtractedFrom" -> True,
  "SummarizedFrom" -> True, "QuotedFrom" -> True, "AttachmentOf" -> True,
  "Cites" -> False, "RelatedTo" -> False, "SameTopic" -> False, "OwnerReviewed" -> False|>;
SourceVaultTaintEdgeCarriesContentQ[edgeKind_String] := TrueQ[Lookup[$svTaintCarry, edgeKind, False]];

(* ---- InputTrustAssessment(§4.17): SecurityPreScan を正準化 ---- *)
SourceVaultAssessInputTrust[input_] := Module[{text, ref, ps, rv, obf},
  {text, ref} = If[AssociationQ[input],
    {ToString@Lookup[input, "Text", ""], Lookup[input, "InputRef", "svinput:" <> iTaintULID[]]},
    {ToString[input], "svinput:" <> iTaintULID[]}];
  ps = If[Length[DownValues[SourceVaultSecurityPreScan]] > 0,
    Quiet@Check[SourceVaultSecurityPreScan[text], Missing["PreScanFailed"]],
    Missing["MiningNotLoaded"]];
  rv = If[AssociationQ[ps], Lookup[ps, "RiskVector", <||>], <||>];
  obf = If[AssociationQ[ps],
    Select[Lookup[ps, "MatchedRules", {}], StringContainsQ[ToString[#], "Hidden" | "Obfusc" | "Base64" | "Unicode"] &], {}];
  <|"ObjectClass" -> "SourceVaultInputTrustAssessment", "InputRef" -> ref,
    "SourceKind" -> If[AssociationQ[input], Lookup[input, "SourceKind", "Unknown"], "Unknown"],
    "OriginRef" -> If[AssociationQ[input], Lookup[input, "OriginRef", Missing[]], Missing[]],
    (* InstructionAuthority は content の自己申告で昇格しない(I-14)。System/OwnerInstruction への
       昇格は out-of-band の TrustedAttestation->True(信頼できる呼び出し経路)がある時のみ。
       データ連想が直接主張しても UntrustedData に落とす。 *)
    "InstructionAuthority" -> If[AssociationQ[input] && TrueQ[Lookup[input, "TrustedAttestation", False]],
      Replace[Lookup[input, "InstructionAuthority", "UntrustedData"],
        Except["System" | "OwnerInstruction"] -> "UntrustedData"],
      "UntrustedData"],
    "PromptInjectionScore" -> Lookup[rv, "PromptInjection", 0.0],
    "ToolMisuseScore" -> Lookup[rv, "ToolMisuse", 0.0],
    "ExfiltrationScore" -> Lookup[rv, "CredentialExfiltration", 0.0],
    "ObfuscationSignals" -> obf,
    "AdversarialSignals" -> If[AssociationQ[ps], Lookup[ps, "MatchedRules", {}], {}],
    "SafetyState" -> If[AssociationQ[ps], Lookup[ps, "SafetyState", "unknown"], "unknown"],
    "RequiredIsolationProfile" -> If[AssociationQ[ps] && TrueQ[Lookup[ps, "RequiresLLMIsolation", False]],
      "IsolatedLocal", Missing["NotRequired"]],
    "MatchedRules" -> If[AssociationQ[ps], Lookup[ps, "MatchedRules", {}], {}],
    "PreScanAvailable" -> AssociationQ[ps]|>];

(* SafetyState の順序(強い方を継承) *)
iTaintStateRank[s_] := Lookup[<|"active" -> 0, "unknown" -> 1, "warning" -> 2, "quarantined" -> 3|>, s, 1];
iTaintMaxState[states_List] := If[states === {}, "active",
  First[MaximalBy[states, iTaintStateRank]]];
iTaintScoreOf[a_Association] := Max[Lookup[a, "PromptInjectionScore", 0.], Lookup[a, "ToolMisuseScore", 0.],
  Lookup[a, "ExfiltrationScore", 0.]];

(* ---- source graph 合成(§4.17b): target へ content-carrying edge で到達する risk ---- *)
SourceVaultComposeCrossObjectRisk[targetRef_String, edges_List, assessments_Association] := Module[
  {carry, incoming, contributors, spanRefs, states, risk, path},
  carry = Select[edges, TrueQ[Lookup[$svTaintCarry, Lookup[#, "EdgeKind", ""], False]] &&
    TrueQ[Lookup[#, "CarriesContent", True]] && Lookup[#, "ContributingSpanRefs", {}] =!= {} &];
  (* target を終点とする content-carrying edge を BFS 逆探索(source 側の assessment を集約) *)
  path = iTaintUpstream[targetRef, carry, {}, {}];
  contributors = DeleteDuplicates[path];
  spanRefs = DeleteDuplicates@Flatten[
    Lookup[#, "ContributingSpanRefs", {}] & /@ Select[carry, MemberQ[contributors, Lookup[#, "FromRef", ""]] &]];
  states = iTaintStateRank /@ (Lookup[Lookup[assessments, #, <||>], "SafetyState", "active"] & /@ contributors);
  risk = If[contributors === {}, 0.,
    Max[iTaintScoreOf[Lookup[assessments, #, <||>]] & /@ contributors]];
  <|"TargetRef" -> targetRef, "CrossObjectRisk" -> risk,
    "ContributingSpanRefs" -> spanRefs, "TaintPath" -> contributors,
    "InheritedSafetyState" -> iTaintMaxState[
      Lookup[Lookup[assessments, #, <||>], "SafetyState", "active"] & /@ contributors],
    (* container: 一部 span 由来か(PartialTaint)、全体 quarantined か *)
    "PartialTaint" -> (contributors =!= {} && ! AnyTrue[contributors,
      Lookup[Lookup[assessments, #, <||>], "SafetyState", ""] === "quarantined" &]),
    "WholeQuarantined" -> AnyTrue[contributors,
      Lookup[Lookup[assessments, #, <||>], "SafetyState", ""] === "quarantined" &]|>];

(* target を終点とする content-carrying edge を逆にたどり source refs を集める *)
iTaintUpstream[node_, carry_, acc_, seen_] := Module[{ins, srcs, newSeen},
  If[MemberQ[seen, node], Return[acc]];
  newSeen = Append[seen, node];
  ins = Select[carry, Lookup[#, "ToRef", ""] === node &];
  srcs = DeleteDuplicates[Lookup[#, "FromRef", ""] & /@ ins];
  Fold[iTaintUpstream[#2, carry, Append[#1, #2], newSeen] &, acc, srcs]];

(* ---- 派生物への taint 継承(I-14 非降下)---- *)
Options[SourceVaultPropagateTaint] = {"ContributingSpanRefs" -> Automatic, "TransformRef" -> Missing[],
  "Direction" -> "SourceToDerived"};
SourceVaultPropagateTaint[derivedRef_String, sourceRefs_List, edgeKind_String, assessments_Association,
  OptionsPattern[]] := Module[{carries, spans, states, inherited},
  carries = SourceVaultTaintEdgeCarriesContentQ[edgeKind];
  spans = OptionValue["ContributingSpanRefs"] /. Automatic :> sourceRefs;
  If[! carries || spans === {},
    (* 非 content-carrying: 伝播しない(edge は記録するが taint 継承なし) *)
    Return[<|"ObjectClass" -> "SourceVaultPropagationEdge", "FromRefs" -> sourceRefs, "ToRef" -> derivedRef,
      "EdgeKind" -> edgeKind, "CarriesContent" -> carries, "Propagated" -> False,
      "InheritedSafetyState" -> "active"|>]];
  states = Lookup[Lookup[assessments, #, <||>], "SafetyState", "active"] & /@ sourceRefs;
  inherited = iTaintMaxState[states];
  <|"ObjectClass" -> "SourceVaultPropagationEdge", "FromRefs" -> sourceRefs, "ToRef" -> derivedRef,
    "EdgeKind" -> edgeKind, "CarriesContent" -> True, "Propagated" -> True,
    "ContributingSpanRefs" -> spans, "TransformRef" -> OptionValue["TransformRef"],
    "Direction" -> OptionValue["Direction"],
    "InheritedSafetyState" -> inherited,           (* source の最強 state を継承(非降下) *)
    "InheritedTaint" -> (iTaintStateRank[inherited] >= iTaintStateRank["warning"])|>];

SourceVaultTaintDeclassify[targetRef_String, decision_Association, OptionsPattern[]] := Module[{by},
  by = Lookup[decision, "By", "Unknown"];
  Which[
    by === "Owner" && StringQ[Lookup[decision, "OwnerConfirmation", Missing[]]],
      <|"TargetRef" -> targetRef, "Declassified" -> True, "By" -> "Owner",
        "NewSafetyState" -> "active", "DecidedAtUTC" -> iTaintNow[]|>,
    by === "DeterministicSanitizer" && TrueQ[Lookup[decision, "SanitizerResult", False]],
      <|"TargetRef" -> targetRef, "Declassified" -> True, "By" -> "DeterministicSanitizer",
        "NewSafetyState" -> "active", "SanitizerRef" -> Lookup[decision, "SanitizerRef", Missing[]],
        "DecidedAtUTC" -> iTaintNow[]|>,
    True,
      Failure["DeclassifyDenied", <|"MessageTemplate" ->
        "taint 解除は owner の明示確認か決定的 sanitizer のみ(LLM/reducer/多数決では解除不可=I-14)。"|>]]];

(* ---- RunIntegrityState(§4.18b): step 単位 transition を event 化 ---- *)
$svTaintIntegrityStates = {"Clean", "Uncertain", "CompromiseSuspected", "Contained"};
Options[SourceVaultTransitionRunIntegrity] = {"StepRef" -> Missing[], "TriggerObservationRefs" -> {},
  "AffectedArtifactRefs" -> {}, "TaintLabels" -> {}, "Persist" -> True};
SourceVaultTransitionRunIntegrity[runRef_String, toState_String, OptionsPattern[]] := Module[{from, ev},
  If[! MemberQ[$svTaintIntegrityStates, toState],
    Return[Failure["BadIntegrityState", <|"State" -> toState|>]]];
  from = Lookup[SourceVaultRunIntegrityState[runRef], "IntegrityState", "Clean"];
  ev = <|"EventClass" -> "RunIntegrityTransitioned", "RunRef" -> runRef,
    "StepRef" -> OptionValue["StepRef"], "FromState" -> from, "ToState" -> toState,
    "TriggerObservationRefs" -> OptionValue["TriggerObservationRefs"],
    "AffectedArtifactRefs" -> OptionValue["AffectedArtifactRefs"],
    "TaintLabels" -> OptionValue["TaintLabels"],
    "EffectiveFromUTC" -> iTaintNow[], "PolicyVersion" -> "runintegrity-v0"|>;
  If[TrueQ[OptionValue["Persist"]], Quiet@Check[SourceVaultAppendEvent[ev], Null]];
  ev];

SourceVaultRunIntegrityState[runRef_String] := Module[{evs, trans, last},
  evs = Quiet@Check[SourceVaultTransactionLog["Limit" -> 5000], {}];
  If[! ListQ[evs], evs = {}];
  trans = Select[evs, Lookup[#, "EventClass", ""] === "RunIntegrityTransitioned" &&
    Lookup[#, "RunRef", ""] === runRef &];
  (* TransactionLog は新しい順 → 先頭が最新 *)
  last = If[trans === {}, Missing[], First[trans]];
  <|"RunRef" -> runRef,
    "IntegrityState" -> If[MissingQ[last], "Clean", last["ToState"]],
    "TaintLabels" -> If[MissingQ[last], {}, Lookup[last, "TaintLabels", {}]],
    "AffectedArtifactRefs" -> If[MissingQ[last], {}, Lookup[last, "AffectedArtifactRefs", {}]],
    "TransitionCount" -> Length[trans]|>];

End[];

EndPackage[];
