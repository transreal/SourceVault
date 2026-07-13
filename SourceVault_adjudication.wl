(* ::Package:: *)

(* ============================================================
   SourceVault_adjudication.wl -- Cane Phase 1F: 複数 LLM 案件裁定(決定的コア)
   This file is encoded in UTF-8.

   仕様: sourcevault_cane_knowledge_home_mining_spec_v0_4.md §4.12-4.14 / §5.11 / I-11
   (v0.5 §4.13補足の security fields は受け皿のみ。enforcement は 1H-S)

   原則(I-11 多数決非依存):
     優先順位 = 決定的テスト > provenance 付き evidence > claim verifier > calibrated 履歴 > モデル間一致。
     同一 correlation group は独立票に数えない。abstain(NeedMoreEvidence 等)は正規の裁定結果。
     conflict は reducer で消さない(ConflictSet/UnresolvedClaims/ExcludedCandidates を final に保持)。
     high-risk は consensus だけで commit しない(owner 確認 or 既存 gate)。
   ============================================================ *)

BeginPackage["SourceVault`"];

SourceVaultOpenDecisionCase::usage =
  "SourceVaultOpenDecisionCase[inputRef, opts] は複数 LLM 裁定の案件(§4.12)を開く。" <>
  "オプション \"TaskDomain\"、\"ActionRiskClass\"(Low|Medium|High, 既定 Low)、\"RequiredEvidencePolicy\"。" <>
  "戻り値 DecisionCaseId(ULID)。case はメモリ registry($svDecisionCases)、最終判定のみ event 化。";
SourceVaultAddCandidate::usage =
  "SourceVaultAddCandidate[caseId, candidate] は候補(§4.13)を登録する。**必須**: AgentRefs, Role, " <>
  "Claims({<|Claim, (DeterministicTest), (EvidenceRefs)|>...}), Assumptions, UnresolvedQuestions" <>
  "(欠落候補は裁定に参加できない=受入31。Failure)。任意: CorrelationGroup(family/retrieval/prompt 共有の群。" <>
  "未指定は自 group)、EvidenceVisibility, Authorized(既定 True), SelfReportedConfidence(参考値。主根拠にしない)。";
SourceVaultEvaluateClaims::usage =
  "SourceVaultEvaluateClaims[caseId, opts] は claim 単位評価(§4.14)。NormalizedClaim で候補横断に突合し、" <>
  "Verdict = DeterministicTest(True→Supported/False→Refuted) > \"VerifierVerdicts\"(opts 注入: claim→Supported|Refuted) > " <>
  "EvidenceRefs あり→Supported(弱) > Unresolved。候補間で矛盾(同一 claim の Supported/Refuted 衝突や " <>
  "\"Contradicts\" 宣言)は Conflicting。戻り値 {ClaimEvaluation...}(case にも保存)。";
SourceVaultDecideCase::usage =
  "SourceVaultDecideCase[caseId, opts] は裁定規則①〜⑧(§5.11/I-11)で最終判定する。" <>
  "①refuted claim を持つ候補は不採用 ②Authorized->False は品質に関係なく不採用 ③supported claim のみ final へ " <>
  "④unresolved/conflicting は明示保持(必要なら NeedOwnerClarification) ⑤\"RiskPriors\"(候補→ExecutionRiskTier)は" <>
  "並び重みのみ(evidence を上書きしない) ⑥tier Missing は重み無し ⑦同一 CorrelationGroup は独立票に数えない " <>
  "⑧ActionRiskClass=High は consensus だけで Accept しない(\"OwnerConfirmed\"->True が無ければ SafeDraftOnly 止まり)。" <>
  "戻り値 <|Decision(Accept|Merge|NeedMoreEvidence|NeedOwnerClarification|SafeDraftOnly|Reject|NoCommit), " <>
  "FinalClaims, ConflictSet, UnresolvedClaims, ExcludedCandidates, DecisionBasis, IndependentGroups|>。" <>
  "最終判定は MultiModelDecisionRecorded(内容最小化)として event 化(\"Persist\"->True 既定)。";
SourceVaultDecisionCase::usage =
  "SourceVaultDecisionCase[caseId] は case の現在状態(Candidates/ClaimEvaluations/Decision)を返す。";
SourceVaultRunMultiModelDecision::usage =
  "SourceVaultRunMultiModelDecision[inputRef, proposerFns, opts] は裁定を end-to-end 実行する runnable driver。" <>
  "proposerFns: {fn...}(各 fn: inputRef -> candidate assoc。**proposer/verifier LLM の実走はここに注入**=" <>
  "orchestrator 結線点。mock も可)。opts \"VerifierFn\"(claim(assoc)->\"Supported\"|\"Refuted\"|Missing。独立検証。" <>
  "各 claim を blind に判定)、\"TaskDomain\"、\"ActionRiskClass\"(Low)、\"OwnerConfirmed\"(False)、\"RiskPriors\"、\"Persist\"(True)。" <>
  "open→addCandidate(欠落候補は除外し ExcludedProposers に記録)→evaluateClaims(VerifierFn を VerifierVerdicts に注入)→" <>
  "decideCase を実行。戻り値 <|DecisionCaseId, Decision, ...decision fields, ExcludedProposers|>。" <>
  "**本 driver は LLM を直接呼ばない**(proposerFns/VerifierFn が実行主体)。";

Begin["`Private`"];

If[! AssociationQ[SourceVault`$svDecisionCases], SourceVault`$svDecisionCases = <||>];

iAdjULID[] := Module[{ms = Round[(AbsoluteTime[] - AbsoluteTime[{1970, 1, 1, 0, 0, 0}, TimeZone -> 0])*1000],
   rnd = FromDigits[StringTake[StringDelete[CreateUUID[], "-"], 20], 16],
   cs = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"], f},
  f = Function[{n, len}, StringJoin@Module[{d = {}, x = n},
    Do[PrependTo[d, cs[[Mod[x, 32] + 1]]]; x = Quotient[x, 32], {len}]; d]];
  f[ms, 10] <> f[Mod[rnd, 32^16], 16]];
iAdjNorm[s_String] := StringTrim[ToLowerCase[StringReplace[s, Whitespace .. -> " "]]];

Options[SourceVaultOpenDecisionCase] = {"TaskDomain" -> "General", "ActionRiskClass" -> "Low",
  "RequiredEvidencePolicy" -> Automatic};
SourceVaultOpenDecisionCase[inputRef_, OptionsPattern[]] := Module[{cid = "svcase:" <> iAdjULID[]},
  SourceVault`$svDecisionCases[cid] = <|"DecisionCaseId" -> cid, "InputRef" -> inputRef,
    "TaskDomain" -> OptionValue["TaskDomain"], "ActionRiskClass" -> OptionValue["ActionRiskClass"],
    "RequiredEvidencePolicy" -> OptionValue["RequiredEvidencePolicy"],
    "Candidates" -> {}, "ClaimEvaluations" -> {}, "Decision" -> Missing["NotDecided"]|>;
  cid];

SourceVaultAddCandidate[cid_String, cand_Association] := Module[{case, c},
  case = Lookup[SourceVault`$svDecisionCases, cid, Missing["NoSuchCase"]];
  If[MissingQ[case], Return[case]];
  (* 受入31: claim/assumptions/unresolved 欠落候補は参加不可 *)
  If[! (KeyExistsQ[cand, "AgentRefs"] && KeyExistsQ[cand, "Role"] &&
        MatchQ[Lookup[cand, "Claims", Missing[]], {__Association}] &&
        KeyExistsQ[cand, "Assumptions"] && KeyExistsQ[cand, "UnresolvedQuestions"]),
    Return[Failure["CandidateIncomplete", <|"MessageTemplate" ->
      "候補には AgentRefs/Role/Claims(非空)/Assumptions/UnresolvedQuestions が必須です(受入31)。"|>]]];
  c = Join[<|"CandidateRef" -> "svcand:" <> iAdjULID[], "Authorized" -> True,
    "CorrelationGroup" -> Automatic, "EvidenceVisibility" -> Missing[]|>, cand];
  If[c["CorrelationGroup"] === Automatic, c["CorrelationGroup"] = c["CandidateRef"]];  (* 自 group *)
  case["Candidates"] = Append[case["Candidates"], c];
  SourceVault`$svDecisionCases[cid] = case;
  c["CandidateRef"]];

Options[SourceVaultEvaluateClaims] = {"VerifierVerdicts" -> <||>};
SourceVaultEvaluateClaims[cid_String, OptionsPattern[]] := Module[
  {case, vv = OptionValue["VerifierVerdicts"], rows, byClaim, evals},
  case = Lookup[SourceVault`$svDecisionCases, cid, Missing["NoSuchCase"]];
  If[MissingQ[case], Return[case]];
  rows = Flatten@Map[Function[cand, Map[Function[cl,
      <|"CandidateRef" -> cand["CandidateRef"], "Claim" -> Lookup[cl, "Claim", ""],
        "Norm" -> iAdjNorm[Lookup[cl, "Claim", ""]],
        "DeterministicTest" -> Lookup[cl, "DeterministicTest", Missing[]],
        "EvidenceRefs" -> Lookup[cl, "EvidenceRefs", {}],
        "Contradicts" -> Lookup[cl, "Contradicts", Missing[]]|>],
      cand["Claims"]]], case["Candidates"]];
  byClaim = GroupBy[rows, #["Norm"] &];
  evals = KeyValueMap[Function[{norm, grp}, Module[
      {det, verdict, contra},
      det = DeleteMissing[Lookup[grp, "DeterministicTest", Missing[]]];
      contra = DeleteMissing[Lookup[grp, "Contradicts", Missing[]]];
      verdict = Which[
        MemberQ[det, False], "Refuted",                     (* 優先1: 決定的テスト *)
        MemberQ[det, True], "Supported",
        KeyExistsQ[vv, norm], vv[norm],                     (* 優先2: verifier 判定(注入) *)
        contra =!= {}, "Conflicting",                       (* 候補が矛盾を宣言 *)
        AnyTrue[grp, Lookup[#, "EvidenceRefs", {}] =!= {} &], "Supported",  (* 弱: evidence あり *)
        True, "Unresolved"];
      <|"ClaimRef" -> "svclaim:" <> IntegerString[Hash[norm], 36],
        "NormalizedClaim" -> norm, "Claim" -> grp[[1, "Claim"]],
        "Verdict" -> verdict,
        "EvidenceRefs" -> DeleteDuplicates[Flatten[Lookup[grp, "EvidenceRefs", {}]]],
        "CandidateRefs" -> DeleteDuplicates[Lookup[grp, "CandidateRef", ""]],
        "EvidenceConfidence" -> Switch[verdict,
          "Refuted" | "Supported", If[det =!= {}, "High", "Medium"], _, "Low"]|>]],
    byClaim];
  case["ClaimEvaluations"] = evals;
  SourceVault`$svDecisionCases[cid] = case;
  evals];

Options[SourceVaultDecideCase] = {"RiskPriors" -> <||>, "OwnerConfirmed" -> False, "Persist" -> True};
SourceVaultDecideCase[cid_String, OptionsPattern[]] := Module[
  {case, evals, cands, excluded = {}, active, refutedNorms, supported, conflicting, unresolved,
   groups, decision, basis = {}, final},
  case = Lookup[SourceVault`$svDecisionCases, cid, Missing["NoSuchCase"]];
  If[MissingQ[case], Return[case]];
  evals = case["ClaimEvaluations"];
  If[evals === {}, evals = SourceVaultEvaluateClaims[cid]; case = SourceVault`$svDecisionCases[cid]];
  cands = case["Candidates"];
  refutedNorms = Lookup[Select[evals, #["Verdict"] === "Refuted" &], "NormalizedClaim", {}];
  (* ②authorization ①refuted claim 保持候補の除外(理由つきで保持=conflict を隠さない) *)
  active = {};
  Scan[Function[c, Which[
      ! TrueQ[c["Authorized"]],
        AppendTo[excluded, <|"CandidateRef" -> c["CandidateRef"], "Reason" -> "NotAuthorized"|>],
      AnyTrue[c["Claims"], MemberQ[refutedNorms, iAdjNorm[Lookup[#, "Claim", ""]]] &],
        AppendTo[excluded, <|"CandidateRef" -> c["CandidateRef"], "Reason" -> "RefutedClaim"|>],
      True, AppendTo[active, c]]],
    cands];
  supported = Select[evals, #["Verdict"] === "Supported" &&
    ! MemberQ[Lookup[excluded, "CandidateRef", {}], Alternatives @@ #["CandidateRefs"]] &];
  (* ↑ supported でも担い手が全滅していれば落ちる(担い手 1 人でも active なら残す) *)
  supported = Select[evals, #["Verdict"] === "Supported" &&
    IntersectingQ[#["CandidateRefs"], Lookup[active, "CandidateRef", {}]] &];
  conflicting = Select[evals, #["Verdict"] === "Conflicting" &];
  unresolved = Select[evals, #["Verdict"] === "Unresolved" &];
  (* ⑦独立 group 数(active のみ)。多数決には使わず、DecisionBasis の参考のみ *)
  groups = DeleteDuplicates[Lookup[active, "CorrelationGroup", {}]];
  decision = Which[
    active === {}, AppendTo[basis, "AllCandidatesExcluded"]; "Reject",
    supported === {} && (conflicting =!= {} || unresolved =!= {}),
      AppendTo[basis, "NoSupportedClaims"];
      If[conflicting =!= {}, "NeedOwnerClarification", "NeedMoreEvidence"],
    supported === {}, AppendTo[basis, "NothingToCommit"]; "NeedMoreEvidence",
    conflicting =!= {}, AppendTo[basis, "SupportedPlusConflicts"]; "NeedOwnerClarification",
    (* ⑧high-risk は consensus だけで Accept しない *)
    case["ActionRiskClass"] === "High" && ! TrueQ[OptionValue["OwnerConfirmed"]],
      AppendTo[basis, "HighRiskNoOwnerConfirm"]; "SafeDraftOnly",
    unresolved =!= {}, AppendTo[basis, "SupportedWithUnresolved"]; "Merge",
    True, AppendTo[basis, "AllSupported"]; "Accept"];
  final = <|"Decision" -> decision,
    "FinalClaims" -> Lookup[supported, "Claim", {}],          (* ③supported のみ *)
    "ConflictSet" -> Lookup[conflicting, "Claim", {}],        (* conflict を隠さない *)
    "UnresolvedClaims" -> Lookup[unresolved, "Claim", {}],
    "ExcludedCandidates" -> excluded,
    "IndependentGroups" -> Length[groups],
    "DecisionBasis" -> basis|>;
  case["Decision"] = final; SourceVault`$svDecisionCases[cid] = case;
  If[TrueQ[OptionValue["Persist"]],
    Quiet@Check[SourceVaultAppendEvent[<|"EventClass" -> "MultiModelDecisionRecorded",
      "DecisionCaseId" -> cid, "TaskDomain" -> case["TaskDomain"],
      "ActionRiskClass" -> case["ActionRiskClass"], "Decision" -> decision,
      "CandidateCount" -> Length[cands], "ExcludedCount" -> Length[excluded],
      "SupportedCount" -> Length[supported], "ConflictCount" -> Length[conflicting],
      "IndependentGroups" -> Length[groups], "DecisionBasis" -> basis,
      "PolicyVersion" -> "adjudicate-v0"|>], Null]];
  final];

SourceVaultDecisionCase[cid_String] := Lookup[SourceVault`$svDecisionCases, cid, Missing["NoSuchCase"]];

(* ---- runnable driver(orchestrator 結線点。proposer/verifier は injectable)---- *)
Options[SourceVaultRunMultiModelDecision] = {"VerifierFn" -> None, "TaskDomain" -> "General",
  "ActionRiskClass" -> "Low", "OwnerConfirmed" -> False, "RiskPriors" -> <||>, "Persist" -> True};
SourceVaultRunMultiModelDecision[inputRef_, proposerFns_List, OptionsPattern[]] := Module[
  {cid, excludedProposers = {}, cand, added, evals, vv = <||>, decision},
  cid = SourceVaultOpenDecisionCase[inputRef, "TaskDomain" -> OptionValue["TaskDomain"],
    "ActionRiskClass" -> OptionValue["ActionRiskClass"]];
  (* 各 proposer を実行して候補登録(欠落候補は driver で除外・記録) *)
  MapIndexed[Function[{fn, ix},
    Module[{c = Quiet@Check[fn[inputRef], $Failed]},
      If[! AssociationQ[c],
        AppendTo[excludedProposers, <|"ProposerIndex" -> ix[[1]], "Reason" -> "ProposerFailed"|>],
        added = SourceVaultAddCandidate[cid, c];
        If[FailureQ[added],
          AppendTo[excludedProposers, <|"ProposerIndex" -> ix[[1]], "Reason" -> "CandidateIncomplete"|>]]]]],
    proposerFns];
  (* verifier(independent。各 claim を blind に判定)を VerifierVerdicts へ *)
  If[OptionValue["VerifierFn"] =!= None,
    evals = SourceVaultEvaluateClaims[cid];  (* まず claim 群を得る *)
    vv = Association@DeleteCases[Map[Function[e,
        Module[{v = Quiet@Check[OptionValue["VerifierFn"][e], Missing[]]},
          If[MemberQ[{"Supported", "Refuted"}, v], e["NormalizedClaim"] -> v, Nothing]]],
        evals], Nothing]];
  evals = SourceVaultEvaluateClaims[cid, "VerifierVerdicts" -> vv];
  decision = SourceVaultDecideCase[cid, "RiskPriors" -> OptionValue["RiskPriors"],
    "OwnerConfirmed" -> OptionValue["OwnerConfirmed"], "Persist" -> OptionValue["Persist"]];
  Join[<|"DecisionCaseId" -> cid, "ExcludedProposers" -> excludedProposers,
    "CandidateCount" -> Length[SourceVaultDecisionCase[cid]["Candidates"]]|>, decision]];

End[];

EndPackage[];
