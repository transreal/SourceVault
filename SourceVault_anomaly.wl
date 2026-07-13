(* ::Package:: *)

(* ============================================================
   SourceVault_anomaly.wl -- Cane Phase 1H-A: 異常分析ワークフロー(observe-only)

   This file is encoded in UTF-8.
   仕様: sourcevault_cane_knowledge_home_mining_spec_v0_7.md(v0.6 §5.14 全面改訂 / §4.20 /
         §4.23 CaneAnomalyWorkflowRun / §5.14 追補(初期 pair)/ §5.15 改訂(diagnostics 二層)、
         v0.5 §4.20 / §5.14 本体)、不変条件 I-15 / I-16。

   最重要原則(I-16。厳守):
     - これは「明示的に実行される観測専用ワークフロー」であり、enforcement(通知・Warning 昇格・
       isolation 変更・policy freeze・taint 変更・containment)を一切行わない。
       ワークフローの出力(event / hypothesis / report)は別の昇格ゲートが消費する。
       本モジュールは event/baseline を local-only store に書き、report を返すのみ。
     - 決定的バッチ(LLM 不使用)。純関数を核とし、合成データ注入で archive/rollup 非依存に検証可能。

   統計規律(I-15):
     - rate は分母(ExposureCount)・coverage・CI(Wilson)必須。collection 停止による rate 低下を
       「改善」と誤認しないよう liveness/coverage を同時評価。
     - lineage dependence 分類(DirectLineage は相関仮説にしない。SharedUpstream は AssociationSupported 上限)。
     - HypothesisStatus は association / causality を分離。owner 確認だけで CausalEvidenceSupported に到達しない。
     - cold start は不変条件: 最小サンプル未満は Missing["InsufficientBaseline"](通知しない)。
     - baseline 更新は候補/検証/有効化の三段階。無条件自動 activate なし。異常 window を除外(poisoning 対策)。

   信頼境界(I-16):
     - AnomalyWorkflowProfile は署名付き trusted config。owner のみ変更可(OwnerAuthorization 必須)。
       LLM/external content からの自動変更は不可(提案は PendingReview)。事前登録 pair のみ相関。
     - 初期 active pair は LLM 系 + system 系のみ。owner 状態を含む pair は research-only opt-in(§5.14 追補)。
     - 冪等: ProfileVersion x InputSnapshotDigest x Window の idempotency key で再実行の二重更新なし(§4.23)。

   diagnostics 二層(§5.15):
     - 通常 probe SourceVaultCaneDiagnosticsProbe は <|Health, ReasonCode|> のみ(pipeline liveness)。
       PendingSensitiveAlerts / owner 状態 / hypothesis id / SensitiveLocalVault ref を出さない。
     - owner 状態の詳細は SourceVaultCaneSensitiveDoctor(local UI 限定)のみが表示。

   store 物理: <LocalState>/cane/anomaly/(機械ローカル・非同期)。Dropbox 同期(PrivateVault)/
     クロスマシン共有(CoreRoot)配下は sink guard で拒否(I-1)。profile MAC は NBAccess KeyRef。
   ============================================================ *)

BeginPackage["SourceVault`"];

SourceVaultAnomalyInitialize::usage =
  "SourceVaultAnomalyInitialize[opts] は異常分析ワークフローの local-only store(runs/events/baselines/profile)と" <>
  "MAC 鍵を初期化する(冪等)。オプション \"Root\"(Automatic=<LocalState>/cane/anomaly)。" <>
  "PrivateVault/CoreRoot 配下は I-1 sink guard で拒否。";
SourceVaultAnomalyStatus::usage =
  "SourceVaultAnomalyStatus[opts] は store の状態(初期化・run 件数・active baseline 数・profile version)を返す。";

SourceVaultRunCaneAnomalyWorkflow::usage =
  "SourceVaultRunCaneAnomalyWorkflow[input, opts] は observe-only の異常分析ワークフローを 1 回実行する(I-16)。" <>
  "input=<|\"Streams\"-><|streamKind-><|\"Points\"->{<|WindowStart,WindowEnd,EventCount,ExposureCount," <>
  "MissingCount,(InputRefs),(RunRefs),(SourceGroups)|>...}|>...|>, (\"Window\"->{start,end})|>。" <>
  "段階: baseline 維持 -> stream 別逸脱検知(分母/coverage/CI 付き)-> lineage 分類 -> 事前登録 pair のみ相関 " <>
  "-> hypothesis 生成 -> report。**通知・containment・taint 変更は一切行わない**(enforcement 権限なし)。" <>
  "ProfileVersion x InputSnapshotDigest x Window で冪等(再実行は既存 run を再利用、二重更新なし)。" <>
  "戻り値 = CaneAnomalyWorkflowRun(EnforcementActions は常に {})。";
SourceVaultCaneAnomalyWorkflowRuns::usage =
  "SourceVaultCaneAnomalyWorkflowRuns[opts] は保存済み run record(新しい順)を返す。オプション \"Limit\"(20)。";

SourceVaultDetectStreamAnomalies::usage =
  "SourceVaultDetectStreamAnomalies[streamData, opts] は 1 stream の逸脱を決定的に検知する(observe-only)。" <>
  "streamData=<|\"StreamKind\",\"Points\"->{...}|>。opts \"Baseline\"(Automatic)、\"ReferenceCount\"(Automatic)、" <>
  "\"DeviationThreshold\"(3.0)、\"MinBaselineSamples\"(8)、\"Method\"(\"MADControl\"|\"EWMAControl\")。" <>
  "cold start(reference < MinBaselineSamples)は Missing[\"InsufficientBaseline\"] を返し何も通知しない(I-15)。" <>
  "各 window は rate=EventCount/ExposureCount・CoverageRatio・ConfidenceInterval(Wilson)・DataQualityFlags を持つ。";
SourceVaultClassifyLineageDependence::usage =
  "SourceVaultClassifyLineageDependence[eventA, eventB] は 2 異常間の provenance 依存を分類する(§4.20)。" <>
  "共有 InputRef/RunRef があれば DirectLineage(機械的共起=相関仮説にしない)、SourceGroup を共有すれば " <>
  "SharedUpstream、provenance 上独立なら IndependentStreams、参照不明なら UnknownDependence。";
SourceVaultCorrelateAnomalies::usage =
  "SourceVaultCorrelateAnomalies[pairSpec, evalA, evalB, opts] は事前登録 pair の lag 付きクロス相関から " <>
  "AnomalyCorrelationHypothesis を生成する(observe-only)。DirectLineage は Missing[\"MechanicallyCoupled\"] を返す" <>
  "(相関仮説にしない)。SharedUpstream は AssociationSupported を上限、CausalEvidenceSupported へは到達しない。" <>
  "RecommendedResponse は observe-only 語彙のみ(containment を返さない)。";
SourceVaultAdjudicateAnomalyHypothesis::usage =
  "SourceVaultAdjudicateAnomalyHypothesis[hypothesis, decision] は仮説の HypothesisStatus を裁定で更新する。" <>
  "decision=<|\"By\",\"Verdict\"->\"Coincidental\"|\"CommonCause\"|\"Association\"|\"Causal\",(\"CausalEvidence\")|>。" <>
  "Verdict Causal は CausalEvidence in {ControlledReplay,DeterministicAttackChain,IsolationStoppedRecurrence} かつ " <>
  "LineageDependence=IndependentStreams のときのみ CausalEvidenceSupported に到達(owner 確認単独では不可=I-15)。" <>
  "SharedUpstream は AssociationSupported を超えない。裁定を記録するのみで containment はしない。";

SourceVaultCaneBaselineCandidates::usage =
  "SourceVaultCaneBaselineCandidates[opts] は保存済み baseline 候補/検証済/有効を返す。オプション \"StreamKind\"、\"State\"。";
SourceVaultGenerateCaneBaselineCandidate::usage =
  "SourceVaultGenerateCaneBaselineCandidate[streamData, opts] は baseline 候補を生成する(三段階の第 1 段)。" <>
  "異常 window(既知 anomaly または robust z が閾値超)と suspected/pending window を除外して median/MAD を推定する" <>
  "(baseline poisoning 対策=I-15)。state は \"candidate\"。activate は別 API。";
SourceVaultValidateCaneBaseline::usage =
  "SourceVaultValidateCaneBaseline[candidateRef, opts] は候補を検証する(第 2 段: 更新前後 diff + holdout backtest)。" <>
  "オプション \"HoldoutPoints\"、\"MaxFalseAlarmRate\"(0.2)。backtest 劣化時は state を \"rejected\"、良好なら \"validated\"。";
SourceVaultActivateCaneBaseline::usage =
  "SourceVaultActivateCaneBaseline[candidateRef, opts] は検証済み候補のみ有効化する(第 3 段)。" <>
  "未検証(candidate/rejected)は Failure。無条件自動 activate はしない(I-16)。有効化で epoch を切替える。";
SourceVaultCaneActiveBaseline::usage =
  "SourceVaultCaneActiveBaseline[streamKind] は現在 active な baseline record を返す(無ければ Missing)。";

SourceVaultAnomalyWorkflowProfile::usage =
  "SourceVaultAnomalyWorkflowProfile[opts] は現在の署名付き AnomalyWorkflowProfile を返す(MAC 検証。改ざんは既定へ fail-closed)。";
SourceVaultSetAnomalyWorkflowProfile::usage =
  "SourceVaultSetAnomalyWorkflowProfile[profile, opts] は profile を owner 権限で更新する(trusted signed config)。" <>
  "opts \"OwnerAuthorization\"->True 必須(LLM/external content からは到達不可)。versioned + 旧版を history に保存(rollback 可)。" <>
  "MAC で署名し epoch を切替える。OwnerAuthorization 無しは Failure。";
SourceVaultProposeAnomalyProfileChange::usage =
  "SourceVaultProposeAnomalyProfileChange[proposal, opts] は external content 由来の profile 変更提案を " <>
  "PendingReview として保存する(自動適用しない=I-16)。owner が別途 SetAnomalyWorkflowProfile で承認する。";
SourceVaultRegisterCaneAnomalySchedule::usage =
  "SourceVaultRegisterCaneAnomalySchedule[spec, opts] は owner 登録の ScheduleSpec(分析権限のみ)を profile に保存する。" <>
  "spec=<|(\"Enabled\"),(\"Paused\"),(\"IntervalSeconds\"),(\"MaxCatchupWindows\")|>。opts \"OwnerAuthorization\"->True 必須。" <>
  "OS の ScheduledTask は作らない(rule 95)。schedule は enforcement 権限を持たない(I-16)。";

SourceVaultCaneDiagnosticsProbe::usage =
  "SourceVaultCaneDiagnosticsProbe[] は通常 SystemDoctor 向けの sanitized probe。<|Health, ReasonCode|> のみを返す" <>
  "(§5.15)。Health は検知 pipeline の liveness のみで決まり、sensitive alert の有無で変化しない。" <>
  "PendingSensitiveAlerts / owner 状態 / hypothesis id / SensitiveLocalVault ref を含めない。";
SourceVaultCaneSensitiveDoctor::usage =
  "SourceVaultCaneSensitiveDoctor[opts] は local UI 限定の詳細ビュー(直近逸脱・仮説・lineage 分類・分母/coverage・" <>
  "PendingSensitiveAlerts・推奨)。この情報は heartbeat/cloud/mail に出してはならない(§5.15)。";
SourceVaultRegisterCaneDiagnostics::usage =
  "SourceVaultRegisterCaneDiagnostics[] は SourceVaultCaneDiagnosticsProbe を diagnostics に弱く冪等に登録する" <>
  "(SourceVaultDiagnosticsRegisterProbe が無ければ no-op=rule 11)。";

Begin["`Private`"];

$svAnomModelVersion = "cane-anomaly-v0";
$svAnomMacKeyRef = "svanom:mac:v1";

(* ---- 小道具(ULID / UTC / JSON / digest) ---- *)
$svAnomCrock = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"];
iAnomCrock[n_Integer, len_Integer] := StringJoin@Module[{d = {}, x = n},
  Do[PrependTo[d, $svAnomCrock[[Mod[x, 32] + 1]]]; x = Quotient[x, 32], {len}]; d];
iAnomULID[] := Module[{ms = Round[(AbsoluteTime[] - AbsoluteTime[{1970, 1, 1, 0, 0, 0}, TimeZone -> 0])*1000],
   rnd = FromDigits[StringTake[StringDelete[CreateUUID[], "-"], 20], 16]},
  iAnomCrock[ms, 10] <> iAnomCrock[Mod[rnd, 32^16], 16]];
iAnomNow[] := DateString[Now, {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"},
  TimeZone -> 0];
iAnomEpoch[] := AbsoluteTime[];
iAnomJSON[x_] := ExportByteArray[x /. m_Missing :> Null, "RawJSON", "Compact" -> True];
(* canonical digest: crypto の canonical JSON を優先、無ければ WL Hash fallback(capbroker と同型) *)
iAnomDigest[expr_] := If[Length[DownValues[SourceVaultCanonicalJSONBytes]] > 0,
  IntegerString[Hash[Normal[Quiet@Check[SourceVaultCanonicalJSONBytes[expr /. m_Missing :> Null],
    BinarySerialize[expr /. m_Missing :> Null]]]], 36],
  IntegerString[Hash[expr /. m_Missing :> Null], 36]];

(* ---- root 解決と sink guard(I-1) ---- *)
iAnomCanonical[p_String] := ToLowerCase[StringReplace[ExpandFileName[p], "\\" -> "/"]];
iAnomUnderQ[child_String, parent_] := StringQ[parent] && StringLength[parent] > 0 &&
  StringStartsQ[iAnomCanonical[child], iAnomCanonical[parent]];

iAnomResolveRoot[rootOpt_] := rootOpt /. Automatic :> Module[{ls = SourceVaultRoot["LocalState"]},
  If[! StringQ[ls], Missing["LocalStateUnresolved"], FileNameJoin[{ls, "cane", "anomaly"}]]];
$svAnomRoot = Automatic;

iAnomSinkGuard[root_] := Module[{pv, cr},
  pv = Quiet@Check[SourceVaultRoot["PrivateVault"], Missing[]];
  cr = Quiet@Check[SourceVaultCoreRoot[], Missing[]];
  Which[
    ! StringQ[root], Failure["AnomalyRootUnresolved",
      <|"MessageTemplate" -> "local-only store の root を解決できません(LocalState 未設定)。fail-closed。"|>],
    iAnomUnderQ[root, pv], Failure["AnomalySinkViolation",
      <|"MessageTemplate" -> "異常分析 store が PrivateVault(Dropbox 同期)配下です。I-1 違反のため拒否。"|>],
    iAnomUnderQ[root, cr], Failure["AnomalySinkViolation",
      <|"MessageTemplate" -> "異常分析 store が CoreRoot(クロスマシン共有)配下です。I-1 違反のため拒否。"|>],
    True, root]];

iAnomRootNow[] := iAnomResolveRoot[$svAnomRoot];
iAnomDir[sub_] := Module[{r = iAnomRootNow[], d},
  If[! StringQ[r], Return[$Failed]];
  d = FileNameJoin[{r, sub}];
  If[! DirectoryQ[d], Quiet@CreateDirectory[d, CreateIntermediateDirectories -> True]]; d];
(* コロンは Windows で NTFS ADS を作る -> ファイル名だけ sanitize(正準 ID は不変) *)
iAnomFile[dir_, id_] := FileNameJoin[{dir, StringReplace[id, Except[WordCharacter | "-"] -> "_"] <> ".json"}];
iAnomWrite[path_, assoc_] := Module[{tmp = path <> ".tmp", strm},
  strm = OpenWrite[tmp, BinaryFormat -> True];
  BinaryWrite[strm, Normal[iAnomJSON[assoc]]]; Close[strm];
  Quiet@DeleteFile[path]; RenameFile[tmp, path]];
iAnomRead[path_] := If[! FileExistsQ[path], Missing["NotFound"],
  Quiet@Check[ImportByteArray[ByteArray[BinaryReadList[path, "Byte"]], "RawJSON"], Missing["Corrupt"]]];
iAnomLock = "svanomstore";

(* ---- MAC(profile 署名) ---- *)
iAnomEnsureKeys[] := If[! TrueQ[Quiet@Check[NBAccess`NBKeyMaterialExistsQ[$svAnomMacKeyRef], False]],
  NBAccess`NBGenerateMacKeyRef[$svAnomMacKeyRef, <|"Purpose" -> "SVAnomalyProfileMAC"|>]];
(* MAC 入力は JSON round-trip で正規化する(write->read の float 表記/Missing->Null 差で MAC が
   壊れないように、decode(encode(payload)) を bytes 化して署名する)。 *)
iAnomMacInput[payload_Association] := iAnomJSON[
  Quiet@Check[ImportByteArray[iAnomJSON[payload], "RawJSON"], payload]];
iAnomMac[payload_Association] := Quiet@Check[
  NBAccess`NBMacWithKeyRef[$svAnomMacKeyRef, iAnomMacInput[payload], "SVAnomProfile"], $Failed];
iAnomMacOK[obj_Association] := Module[{mac = Lookup[obj, "MAC", ""], calc},
  calc = iAnomMac[KeyDrop[obj, "MAC"]];
  StringQ[calc] && calc === mac];

(* ============================================================
   stream 分類(§4.20 / §5.14)
   ============================================================ *)
(* owner 状態(SensitiveLocalVault, research-only)ストリーム。これらを含む pair は
   OwnerStateOptIn 無しに読まない(§5.14 追補・受入 100)。 *)
$svAnomOwnerStateStreams = {"OwnerOperationalSignal", "CommitmentMissRate", "GuardOverrideRate", "LoopRate"};
$svAnomStateStreams = Join[$svAnomOwnerStateStreams, {"LLMRiskSignalRate", "RunIntegrityRate"}];
iAnomOwnerStateQ[kind_String] := MemberQ[$svAnomOwnerStateStreams, kind];
iAnomStreamClass[kind_String] := If[MemberQ[$svAnomStateStreams, kind], "State", "Input"];

(* ============================================================
   統計核(決定的・純関数)
   ============================================================ *)
iAnomRate[pt_Association] := Module[{n = Lookup[pt, "ExposureCount", 0], k = Lookup[pt, "EventCount", 0]},
  If[! (NumericQ[n] && n > 0), Missing["ZeroExposure"], N[k/n]]];
iAnomCoverage[pt_Association] := Module[{n = Lookup[pt, "ExposureCount", 0], m = Lookup[pt, "MissingCount", 0]},
  If[! (NumericQ[n] && NumericQ[m]) || n + m <= 0, 0., N[n/(n + m)]]];

(* Wilson score interval(k 件 / n 露出) *)
iAnomWilson[k_, n_, z_: 1.96] := If[! (NumericQ[n] && n > 0), {Missing[], Missing[]},
  Module[{p = k/n, denom, center, half},
    denom = 1 + z^2/n;
    center = (p + z^2/(2 n))/denom;
    half = (z/denom) Sqrt[p (1 - p)/n + z^2/(4 n^2)];
    {N[center - half], N[center + half]}]];

(* robust baseline: median + MAD(+ mean/SD fallback) *)
iAnomBaselineFromRates[rates_List] := Module[{r = Select[rates, NumericQ], med, mad},
  If[Length[r] === 0, Return[<|"Median" -> 0., "MAD" -> 0., "Mean" -> 0., "SD" -> 0., "N" -> 0|>]];
  med = N@Median[r]; mad = N@Median[Abs[r - med]];
  <|"Median" -> med, "MAD" -> mad, "Mean" -> N@Mean[r],
    "SD" -> If[Length[r] > 1, N@StandardDeviation[r], 0.], "N" -> Length[r]|>];

(* robust z(MAD スケール。分散 0 は SD fallback、両者 0 は 0) *)
iAnomRobustZ[rate_, base_Association] := Module[{madScale = 1.4826 Lookup[base, "MAD", 0.], sd = Lookup[base, "SD", 0.]},
  Which[
    ! NumericQ[rate], Missing["NoRate"],
    madScale > 0, N[(rate - base["Median"])/madScale],
    sd > 0, N[(rate - base["Mean"])/sd],
    True, 0.]];

(* EWMA 管制図: 逸脱スコアを EWMA 系列で置換(option) *)
iAnomEWMASeries[rates_List, base_Association, lambda_, L_] := Module[
  {tgt = Lookup[base, "Median", 0.], sd, e, out = {}, limit},
  sd = Which[1.4826 Lookup[base, "MAD", 0.] > 0, 1.4826 Lookup[base, "MAD", 0.],
    Lookup[base, "SD", 0.] > 0, Lookup[base, "SD", 0.], True, 0.];
  e = tgt;
  MapIndexed[Function[{rate, idx},
    Module[{i = First[idx], sigmaE},
      If[NumericQ[rate], e = lambda rate + (1 - lambda) e];
      sigmaE = If[sd > 0, sd Sqrt[(lambda/(2 - lambda)) (1 - (1 - lambda)^(2 i))], 0.];
      limit = If[sigmaE > 0, L sigmaE, 0.];
      AppendTo[out, If[! NumericQ[rate], Missing["NoRate"],
        If[limit > 0, N[(e - tgt)/(limit/L)], 0.]]]]], rates];
  out];

(* ---- SourceVaultDetectStreamAnomalies ---- *)
Options[SourceVaultDetectStreamAnomalies] = {"Baseline" -> Automatic, "ReferenceCount" -> Automatic,
  "DeviationThreshold" -> 3.0, "MinBaselineSamples" -> 8, "Method" -> "MADControl",
  "EWMALambda" -> 0.3, "EWMAL" -> 3.0, "LowCoverageThreshold" -> 0.8, "CoverageDropFactor" -> 0.5,
  "BaselineEpochRef" -> Missing[]};
SourceVaultDetectStreamAnomalies[streamData_Association, OptionsPattern[]] := Module[
  {kind, points, refCount, minB, thr, method, baseOpt, base, rates, refRates, evals, anomalies,
   baseCov, zseries, epochRef},
  kind = Lookup[streamData, "StreamKind", "Unknown"];
  points = Lookup[streamData, "Points", {}];
  If[! ListQ[points], points = {}];
  minB = OptionValue["MinBaselineSamples"];
  thr = OptionValue["DeviationThreshold"];
  method = OptionValue["Method"];
  baseOpt = OptionValue["Baseline"];
  epochRef = OptionValue["BaselineEpochRef"];
  rates = iAnomRate /@ points;
  (* baseline: 明示 record 優先。無ければ reference 部分から robust 推定 *)
  If[AssociationQ[baseOpt] && KeyExistsQ[baseOpt, "Median"],
    base = baseOpt; refCount = Lookup[baseOpt, "N", Count[rates, _?NumericQ]];
    epochRef = Lookup[baseOpt, "EpochRef", epochRef],
    (* else *)
    refCount = OptionValue["ReferenceCount"] /. Automatic :> Length[points];
    refRates = Take[rates, Min[refCount, Length[rates]]];
    base = iAnomBaselineFromRates[refRates]];
  baseCov = Module[{cv = iAnomCoverage /@ Take[points, Min[Max[refCount, 1], Length[points]]]},
    If[cv === {}, 1., N@Mean[cv]]];
  (* cold start(不変条件 I-15): reference sample 不足なら Missing["InsufficientBaseline"](通知しない) *)
  If[Lookup[base, "N", 0] < minB, Return[Missing["InsufficientBaseline"]]];
  (* 逸脱スコア系列 *)
  zseries = If[method === "EWMAControl",
    iAnomEWMASeries[rates, base, OptionValue["EWMALambda"], OptionValue["EWMAL"]],
    iAnomRobustZ[#, base] & /@ rates];
  evals = MapThread[Function[{pt, rate, z},
    Module[{cov = iAnomCoverage[pt], flags = {}, isAnom, dir, ci, k = Lookup[pt, "EventCount", 0],
        n = Lookup[pt, "ExposureCount", 0], covDrop},
      ci = iAnomWilson[k, n];
      covDrop = NumericQ[cov] && cov < baseCov OptionValue["CoverageDropFactor"];
      If[! NumericQ[rate], AppendTo[flags, "ZeroExposure"]];
      If[1.4826 Lookup[base, "MAD", 0.] <= 0 && Lookup[base, "SD", 0.] <= 0, AppendTo[flags, "ZeroDispersion"]];
      If[NumericQ[cov] && cov < OptionValue["LowCoverageThreshold"], AppendTo[flags, "LowCoverage"]];
      If[covDrop, AppendTo[flags, "CoverageDrop"]];
      isAnom = NumericQ[z] && Abs[z] >= thr;
      dir = Which[! NumericQ[z], "Unknown", z > 0, "Increase", True, "Decrease"];
      (* liveness: coverage 崩落を伴う rate 低下は「改善」でなく collection gap 疑い(受入: rate 低下の誤認防止) *)
      If[dir === "Decrease" && covDrop, AppendTo[flags, "PossibleCollectionGap"]];
      <|"WindowStart" -> Lookup[pt, "WindowStart", Missing[]], "WindowEnd" -> Lookup[pt, "WindowEnd", Missing[]],
        "Rate" -> rate, "DeviationScore" -> z, "ConfidenceInterval" -> ci, "CoverageRatio" -> cov,
        "EventCount" -> k, "ExposureCount" -> n, "MissingCount" -> Lookup[pt, "MissingCount", 0],
        "DataQualityFlags" -> flags, "IsAnomaly" -> isAnom, "Direction" -> dir,
        "InputRefs" -> Lookup[pt, "InputRefs", {}], "RunRefs" -> Lookup[pt, "RunRefs", {}],
        "SourceGroups" -> Lookup[pt, "SourceGroups", {}]|>]],
    {points, rates, zseries}];
  anomalies = iAnomBuildAnomalyEvents[kind, Select[evals, TrueQ[#["IsAnomaly"]] &], base, epochRef, method];
  <|"ObjectClass" -> "SourceVaultStreamAnomalyResult", "StreamKind" -> kind,
    "StreamKindClass" -> iAnomStreamClass[kind], "Method" -> method,
    "Baseline" -> base, "BaselineSampleCount" -> Lookup[base, "N", 0],
    "BaselineEpochRef" -> epochRef, "BaselineMeanCoverage" -> baseCov,
    "Evaluations" -> evals, "Anomalies" -> anomalies, "ModelVersion" -> $svAnomModelVersion|>];

iAnomBuildAnomalyEvents[kind_, anomEvals_List, base_, epochRef_, method_] := Module[{cls = iAnomStreamClass[kind]},
  Function[ev, <|
    "EventClass" -> If[cls === "State", "StateAnomalyDetected", "InputAnomalyDetected"],
    "EventId" -> "svanomev:" <> iAnomULID[], "StreamKind" -> kind, "StreamKindClass" -> cls,
    "Statistic" -> "Rate", "ObservedValue" -> ev["Rate"], "DeviationScore" -> ev["DeviationScore"],
    "Direction" -> ev["Direction"], "Method" -> method,
    "ExpectedRange" -> {Lookup[base, "Median", 0.] - 1.4826 Lookup[base, "MAD", 0.] 3.0,
      Lookup[base, "Median", 0.] + 1.4826 Lookup[base, "MAD", 0.] 3.0},
    "ExposureCount" -> ev["ExposureCount"], "EventCount" -> ev["EventCount"], "MissingCount" -> ev["MissingCount"],
    "CoverageRatio" -> ev["CoverageRatio"], "ConfidenceInterval" -> ev["ConfidenceInterval"],
    "BaselineSampleCount" -> Lookup[base, "N", 0], "BaselineEpochRef" -> epochRef,
    "DataQualityFlags" -> ev["DataQualityFlags"], "Covariates" -> <||>,
    "ContributingInputRefs" -> ev["InputRefs"], "ContributingRunRefs" -> ev["RunRefs"],
    "SourceGroups" -> ev["SourceGroups"],
    "WindowStart" -> ev["WindowStart"], "WindowEnd" -> ev["WindowEnd"],
    "DetectedAtUTC" -> iAnomNow[], "ModelVersion" -> $svAnomModelVersion|>] /@ anomEvals];

(* ============================================================
   lineage dependence 分類(§4.20。相関の前に必須)
   ============================================================ *)
iAnomRefsOf[ev_, keys_List] := DeleteDuplicates@Flatten[Lookup[ev, #, {}] & /@ keys];
SourceVaultClassifyLineageDependence[eventA_Association, eventB_Association] := Module[
  {inA, inB, runA, runB, grpA, grpB, sharedInstance, sharedGroup, haveRefs},
  inA = iAnomRefsOf[eventA, {"ContributingInputRefs", "InputRefs"}];
  inB = iAnomRefsOf[eventB, {"ContributingInputRefs", "InputRefs"}];
  runA = iAnomRefsOf[eventA, {"ContributingRunRefs", "RunRefs"}];
  runB = iAnomRefsOf[eventB, {"ContributingRunRefs", "RunRefs"}];
  grpA = iAnomRefsOf[eventA, {"SourceGroups"}];
  grpB = iAnomRefsOf[eventB, {"SourceGroups"}];
  sharedInstance = Intersection[inA, inB] =!= {} || Intersection[runA, runB] =!= {};
  sharedGroup = Intersection[grpA, grpB] =!= {};
  haveRefs = (inA =!= {} || runA =!= {}) && (inB =!= {} || runB =!= {});
  Which[
    sharedInstance, "DirectLineage",
    sharedGroup, "SharedUpstream",
    haveRefs, "IndependentStreams",
    True, "UnknownDependence"]];

(* ============================================================
   lag 付きクロス相関 -> AnomalyCorrelationHypothesis(observe-only)
   ============================================================ *)
iAnomZVec[eval_] := Replace[Lookup[#, "DeviationScore", 0.] & /@ Lookup[eval, "Evaluations", {}],
  x_ /; ! NumericQ[x] :> 0., {1}];
iAnomPearson[a_List, b_List] := Module[{n = Min[Length[a], Length[b]], x, y, sx, sy},
  If[n < 3, Return[0.]];
  x = Take[a, n]; y = Take[b, n];
  sx = StandardDeviation[x]; sy = StandardDeviation[y];
  If[! (NumericQ[sx] && NumericQ[sy]) || sx <= 0 || sy <= 0, 0., N@Correlation[x, y]]];
(* lag l: B を l だけずらして A と重ねる(l>0 は B が A に先行)。|l|>=重なり長は 0(Drop 安全) *)
iAnomLaggedCorr[za_List, zb_List, l_Integer] := Module[{a, b, n = Min[Length[za], Length[zb]]},
  If[Abs[l] >= n, Return[0.]];
  {a, b} = If[l == 0, {za, zb}, {Drop[za, l], Drop[zb, -l]}];
  iAnomPearson[a, b]];

(* 依存調整係数(lineage): IndependentStreams=1、SharedUpstream=0.5、Unknown=0.7 *)
iAnomDependenceAdj[lineage_] := Lookup[<|"IndependentStreams" -> 1.0, "SharedUpstream" -> 0.5,
  "UnknownDependence" -> 0.7, "DirectLineage" -> 0.0|>, lineage, 0.7];
$svAnomStatusRank = <|"AssociationRefuted" -> 0, "Hypothesized" -> 1, "MechanicallyCoupled" -> 1,
  "InsufficientEvidence" -> 1, "CommonCauseLikely" -> 2, "AssociationSupported" -> 3,
  "CausalEvidenceSupported" -> 4|>;
iAnomStatusRank[s_] := Lookup[$svAnomStatusRank, s, 1];

Options[SourceVaultCorrelateAnomalies] = {"MaxLagWindows" -> 3, "MinEffectSize" -> 0.5,
  "MinOverlapWindows" -> 5, "DeviationThreshold" -> 3.0};
SourceVaultCorrelateAnomalies[pairSpec_Association, evalA_Association, evalB_Association, OptionsPattern[]] := Module[
  {za, zb, maxLag, minEff, minOv, thr, lineage, best, bestLag, bestCorr, overlap, cooc, effN, depAdj,
   candCauseRefs, status, attribution, anomA, anomB},
  anomA = Lookup[evalA, "Anomalies", {}]; anomB = Lookup[evalB, "Anomalies", {}];
  (* lineage: 代表 anomaly(無ければ eval 全体の refs)で分類 *)
  lineage = SourceVaultClassifyLineageDependence[
    If[anomA =!= {}, iAnomMergeRefs[anomA], iAnomMergeRefs[Lookup[evalA, "Evaluations", {}]]],
    If[anomB =!= {}, iAnomMergeRefs[anomB], iAnomMergeRefs[Lookup[evalB, "Evaluations", {}]]]];
  (* DirectLineage は相関仮説にしない(§4.20・受入 73) *)
  If[lineage === "DirectLineage", Return[Missing["MechanicallyCoupled"]]];
  za = iAnomZVec[evalA]; zb = iAnomZVec[evalB];
  maxLag = OptionValue["MaxLagWindows"]; minEff = OptionValue["MinEffectSize"];
  minOv = OptionValue["MinOverlapWindows"]; thr = OptionValue["DeviationThreshold"];
  best = MaximalBy[Range[-maxLag, maxLag], Abs[iAnomLaggedCorr[za, zb, #]] &, 1];
  bestLag = If[best === {}, 0, First[best]];
  bestCorr = iAnomLaggedCorr[za, zb, bestLag];
  overlap = Min[Length[za], Length[zb]] - Abs[bestLag];
  depAdj = iAnomDependenceAdj[lineage];
  effN = N[Max[overlap, 0] depAdj];
  (* 共起 window(best lag で両側が閾値超) *)
  cooc = iAnomCooccurrence[za, zb, bestLag, thr];
  candCauseRefs = DeleteDuplicates@Flatten[{iAnomRefsOf[#, {"ContributingInputRefs", "SourceGroups"}] & /@ anomB}];
  attribution = N@Clip[Abs[bestCorr] Min[1., overlap/Max[minOv, 1]] depAdj, {0., 1.}];
  (* HypothesisStatus: association のみ。SharedUpstream は AssociationSupported 上限、
     CausalEvidenceSupported へは workflow から到達しない(裁定+causal evidence 必須) *)
  status = Which[
    Abs[bestCorr] >= minEff && overlap >= minOv && MemberQ[{"IndependentStreams", "SharedUpstream"}, lineage],
      "AssociationSupported",
    True, "Hypothesized"];
  <|"ObjectClass" -> "SourceVaultAnomalyCorrelationHypothesis",
    "HypothesisId" -> "svanomhyp:" <> iAnomULID[],
    "PairId" -> Lookup[pairSpec, "PairId", Missing[]],
    "StreamA" -> Lookup[evalA, "StreamKind", Lookup[pairSpec, "StreamA", Missing[]]],
    "StreamB" -> Lookup[evalB, "StreamKind", Lookup[pairSpec, "StreamB", Missing[]]],
    "StateAnomalyRefs" -> (Lookup[#, "EventId", Missing[]] & /@ Select[Join[anomA, anomB],
      Lookup[#, "StreamKindClass", ""] === "State" &]),
    "InputAnomalyRefs" -> (Lookup[#, "EventId", Missing[]] & /@ Select[Join[anomA, anomB],
      Lookup[#, "StreamKindClass", ""] === "Input" &]),
    "LineageDependence" -> lineage, "LagEstimate" -> bestLag, "CorrelationScore" -> bestCorr,
    "CooccurrenceWindows" -> cooc, "OverlapWindows" -> overlap,
    "EffectiveSampleSize" -> effN, "DependenceAdjustment" -> depAdj, "AttributionConfidence" -> attribution,
    "CandidateCauseRefs" -> candCauseRefs, "HypothesisStatus" -> status,
    (* observe-only 語彙のみ(containment を返さない=I-16) *)
    "RecommendedResponse" -> If[status === "AssociationSupported", "LocalReviewSuggested", "None"],
    "ResponseDecisionRefs" -> {}, "GeneratedAtUTC" -> iAnomNow[], "ModelVersion" -> $svAnomModelVersion|>];

iAnomMergeRefs[evs_List] := <|
  "ContributingInputRefs" -> DeleteDuplicates@Flatten[iAnomRefsOf[#, {"ContributingInputRefs", "InputRefs"}] & /@ evs],
  "ContributingRunRefs" -> DeleteDuplicates@Flatten[iAnomRefsOf[#, {"ContributingRunRefs", "RunRefs"}] & /@ evs],
  "SourceGroups" -> DeleteDuplicates@Flatten[iAnomRefsOf[#, {"SourceGroups"}] & /@ evs]|>;

iAnomCooccurrence[za_, zb_, lag_, thr_] := Module[{a, b, n = Min[Length[za], Length[zb]]},
  If[Abs[lag] >= n, Return[0]];
  {a, b} = If[lag == 0, {za, zb}, {Drop[za, lag], Drop[zb, -lag]}];
  n = Min[Length[a], Length[b]];
  If[n <= 0, 0, Count[Range[n], i_ /; Abs[a[[i]]] >= thr && Abs[b[[i]]] >= thr]]];

(* ============================================================
   裁定(association / causality 分離。I-15。containment はしない)
   ============================================================ *)
SourceVaultAdjudicateAnomalyHypothesis[hyp_Association, decision_Association] := Module[
  {verdict, evidence, lineage, status, by},
  by = Lookup[decision, "By", "Unknown"];
  verdict = Lookup[decision, "Verdict", Missing[]];
  evidence = Lookup[decision, "CausalEvidence", Missing[]];
  lineage = Lookup[hyp, "LineageDependence", "UnknownDependence"];
  status = Which[
    verdict === "Coincidental", "AssociationRefuted",
    verdict === "CommonCause", "CommonCauseLikely",
    verdict === "Association", "AssociationSupported",
    verdict === "Causal",
      If[MemberQ[{"ControlledReplay", "DeterministicAttackChain", "IsolationStoppedRecurrence"}, evidence] &&
          lineage === "IndependentStreams",
        "CausalEvidenceSupported",
        Return[Failure["InsufficientCausalEvidence", <|"MessageTemplate" ->
          "CausalEvidenceSupported へは controlled replay 等の因果根拠かつ IndependentStreams が必要です" <>
          "(owner 確認単独・SharedUpstream では到達不可=I-15)。", "Lineage" -> lineage, "Evidence" -> evidence|>]]],
    True, Return[Failure["UnknownVerdict", <|"Verdict" -> verdict|>]]];
  (* SharedUpstream は AssociationSupported を超えない(§4.20 追補・受入 101) *)
  If[lineage === "SharedUpstream" && iAnomStatusRank[status] > iAnomStatusRank["AssociationSupported"],
    status = "AssociationSupported"];
  Join[hyp, <|"HypothesisStatus" -> status,
    "ResponseDecisionRefs" -> Append[Lookup[hyp, "ResponseDecisionRefs", {}],
      <|"By" -> by, "Verdict" -> verdict, "DecidedAtUTC" -> iAnomNow[]|>],
    (* 裁定でも containment はしない。observe-only の推奨のみ *)
    "RecommendedResponse" -> Which[status === "CausalEvidenceSupported", "EscalateToSeparateGate",
      status === "AssociationSupported", "LocalReviewSuggested", True, "None"]|>]];

(* ============================================================
   baseline 三段階(candidate -> validate -> activate。I-16)
   ============================================================ *)
iAnomBaselineDir[] := iAnomDir["baselines"];
iAnomActiveIndexPath[] := FileNameJoin[{iAnomRootNow[], "baselines-active.json"}];

Options[SourceVaultGenerateCaneBaselineCandidate] = {"ExcludeThreshold" -> 3.0, "MinBaselineSamples" -> 8,
  "ExcludeWindows" -> {}};
SourceVaultGenerateCaneBaselineCandidate[streamData_Association, OptionsPattern[]] := Module[
  {kind, points, rates, prelim, keep, keepRates, base, exW, spanDays, id, rec, cls, times},
  If[iAnomBaselineDir[] === $Failed, Return[Failure["AnomalyRootUnresolved", <||>]]];
  kind = Lookup[streamData, "StreamKind", "Unknown"];
  points = Lookup[streamData, "Points", {}];
  rates = iAnomRate /@ points;
  (* 予備 robust baseline で異常 window を検出し、それと明示 exclude window を学習から除外(poisoning 対策) *)
  prelim = iAnomBaselineFromRates[Select[rates, NumericQ]];
  exW = OptionValue["ExcludeWindows"];
  keep = Select[Transpose[{points, rates}], Function[pr,
    Module[{pt = pr[[1]], rate = pr[[2]], z, susp},
      z = iAnomRobustZ[rate, prelim];
      susp = TrueQ[Lookup[pt, "Pending", False]] || TrueQ[Lookup[pt, "Suspected", False]] ||
        MemberQ[exW, Lookup[pt, "WindowStart", Null]];
      NumericQ[rate] && ! susp && (! NumericQ[z] || Abs[z] < OptionValue["ExcludeThreshold"])]]];
  keepRates = keep[[All, 2]];
  base = iAnomBaselineFromRates[keepRates];
  cls = iAnomStreamClass[kind];
  times = DeleteMissing[Quiet@Check[AbsoluteTime[Lookup[#[[1]], "WindowStart", Missing[]]], Missing[]] & /@ keep];
  spanDays = If[Length[times] >= 2, N[(Max[times] - Min[times])/86400.], 0.];
  id = "svanombase:" <> iAnomULID[];
  rec = <|"ObjectClass" -> "SourceVaultCaneBaseline", "BaselineId" -> id, "StreamKind" -> kind,
    "StreamKindClass" -> cls, "State" -> "candidate",
    "EpochRef" -> "svanomepoch:" <> iAnomULID[],
    "Median" -> base["Median"], "MAD" -> base["MAD"], "Mean" -> base["Mean"], "SD" -> base["SD"],
    "N" -> base["N"], "SampleCount" -> base["N"], "PeriodSpanDays" -> spanDays,
    "ExcludedWindowCount" -> Length[points] - Length[keep],
    "MinBaselineSamples" -> OptionValue["MinBaselineSamples"],
    "InsufficientBaseline" -> (base["N"] < OptionValue["MinBaselineSamples"]),
    "ValidationReport" -> Missing[], "CreatedAtUTC" -> iAnomNow[], "ModelVersion" -> $svAnomModelVersion|>;
  SourceVaultWithLock[iAnomLock, iAnomWrite[iAnomFile[iAnomBaselineDir[], id], rec]];
  rec];

Options[SourceVaultValidateCaneBaseline] = {"HoldoutPoints" -> {}, "MaxFalseAlarmRate" -> 0.2,
  "DeviationThreshold" -> 3.0};
SourceVaultValidateCaneBaseline[candidateRef_String, OptionsPattern[]] := Module[
  {path, rec, holdout, prev, faRate, report, newState, diff, det},
  If[iAnomBaselineDir[] === $Failed, Return[Failure["AnomalyRootUnresolved", <||>]]];
  path = iAnomFile[iAnomBaselineDir[], candidateRef];
  rec = iAnomRead[path];
  If[! AssociationQ[rec], Return[Failure["NoBaselineRecord", <|"BaselineId" -> candidateRef|>]]];
  If[rec["State"] =!= "candidate", Return[Failure["NotCandidate", <|"State" -> rec["State"]|>]]];
  holdout = OptionValue["HoldoutPoints"];
  (* backtest: 候補 baseline を holdout に当て false-alarm 率(異常率)を測る *)
  det = If[holdout === {}, Missing[],
    SourceVaultDetectStreamAnomalies[<|"StreamKind" -> rec["StreamKind"], "Points" -> holdout|>,
      "Baseline" -> rec, "DeviationThreshold" -> OptionValue["DeviationThreshold"],
      "MinBaselineSamples" -> 0]];
  faRate = If[AssociationQ[det] && Length[Lookup[det, "Evaluations", {}]] > 0,
    N[Count[det["Evaluations"], e_ /; TrueQ[e["IsAnomaly"]]]/Length[det["Evaluations"]]], 0.];
  (* 更新前後 diff(前 active との median/MAD 差) *)
  prev = iAnomActiveBaseline[rec["StreamKind"]];
  diff = If[AssociationQ[prev],
    <|"MedianDelta" -> rec["Median"] - Lookup[prev, "Median", 0.],
      "MADDelta" -> rec["MAD"] - Lookup[prev, "MAD", 0.]|>, <|"MedianDelta" -> Missing[], "MADDelta" -> Missing[]|>];
  newState = Which[
    TrueQ[rec["InsufficientBaseline"]], "rejected",
    faRate > OptionValue["MaxFalseAlarmRate"], "rejected",
    True, "validated"];
  report = <|"FalseAlarmRate" -> faRate, "MaxFalseAlarmRate" -> OptionValue["MaxFalseAlarmRate"],
    "HoldoutCount" -> Length[holdout], "Diff" -> diff, "Passed" -> (newState === "validated"),
    "ValidatedAtUTC" -> iAnomNow[]|>;
  rec = Join[rec, <|"State" -> newState, "ValidationReport" -> report|>];
  SourceVaultWithLock[iAnomLock, iAnomWrite[path, rec]];
  rec];

Options[SourceVaultActivateCaneBaseline] = {"RequireCoverage" -> True, "ConfigUnchanged" -> True};
SourceVaultActivateCaneBaseline[candidateRef_String, OptionsPattern[]] := Module[{path, rec, idx, autoOk},
  If[iAnomBaselineDir[] === $Failed, Return[Failure["AnomalyRootUnresolved", <||>]]];
  path = iAnomFile[iAnomBaselineDir[], candidateRef];
  rec = iAnomRead[path];
  If[! AssociationQ[rec], Return[Failure["NoBaselineRecord", <|"BaselineId" -> candidateRef|>]]];
  (* 未検証(candidate/rejected)は activate 不可(無条件自動 activate なし=I-16・受入 102) *)
  If[rec["State"] =!= "validated",
    Return[Failure["BaselineNotValidated", <|"MessageTemplate" ->
      "検証済み(validated)候補のみ有効化できます。現在: " <> ToString[rec["State"]] <>
      "。SourceVaultValidateCaneBaseline を先に通してください。", "State" -> rec["State"]|>]]];
  autoOk = TrueQ[OptionValue["ConfigUnchanged"]] && ! TrueQ[rec["InsufficientBaseline"]];
  If[! autoOk,
    Return[Failure["ActivationReviewRequired", <|"MessageTemplate" ->
      "coverage 不足 / config 変更のため自動 activate できません(review 待ち)。"|>]]];
  SourceVaultWithLock[iAnomLock, Module[{},
    rec = Join[rec, <|"State" -> "active", "ActivatedAtUTC" -> iAnomNow[]|>];
    iAnomWrite[path, rec];
    idx = iAnomRead[iAnomActiveIndexPath[]];
    If[! AssociationQ[idx], idx = <||>];
    (* 旧 active を superseded に *)
    Module[{oldId = Lookup[idx, rec["StreamKind"], Missing[]]},
      If[StringQ[oldId] && oldId =!= candidateRef,
        Module[{op = iAnomFile[iAnomBaselineDir[], oldId], orec = iAnomRead[iAnomFile[iAnomBaselineDir[], oldId]]},
          If[AssociationQ[orec], iAnomWrite[op, Join[orec, <|"State" -> "superseded"|>]]]]]];
    idx[rec["StreamKind"]] = candidateRef;
    iAnomWrite[iAnomActiveIndexPath[], idx]]];
  rec];

iAnomActiveBaseline[kind_String] := Module[{idx = iAnomRead[iAnomActiveIndexPath[]], id},
  If[! AssociationQ[idx], Return[Missing[]]];
  id = Lookup[idx, kind, Missing[]];
  If[! StringQ[id], Missing[], iAnomRead[iAnomFile[iAnomBaselineDir[], id]]]];
SourceVaultCaneActiveBaseline[kind_String] := iAnomActiveBaseline[kind];

Options[SourceVaultCaneBaselineCandidates] = {"StreamKind" -> All, "State" -> All};
SourceVaultCaneBaselineCandidates[OptionsPattern[]] := Module[{dir = iAnomBaselineDir[], files, recs},
  If[dir === $Failed, Return[{}]];
  files = FileNames["*.json", dir];
  recs = Select[iAnomRead /@ files, AssociationQ];
  If[OptionValue["StreamKind"] =!= All, recs = Select[recs, #["StreamKind"] === OptionValue["StreamKind"] &]];
  If[OptionValue["State"] =!= All, recs = Select[recs, #["State"] === OptionValue["State"] &]];
  ReverseSortBy[recs, Lookup[#, "CreatedAtUTC", ""] &]];

(* ============================================================
   AnomalyWorkflowProfile(署名付き trusted config。I-16)
   ============================================================ *)
iAnomProfilePath[] := FileNameJoin[{iAnomRootNow[], "profile.json"}];
iAnomProfileHistoryDir[] := iAnomDir["profile-history"];
iAnomPendingDir[] := iAnomDir["profile-pending"];

(* 既定 profile: 初期 active pair は LLM 系 + system 系のみ。owner 状態 pair は research-only(§5.14 追補) *)
iAnomDefaultProfile[] := <|"ObjectClass" -> "SourceVaultAnomalyWorkflowProfile",
  "ProfileId" -> "svanomprofile:default", "Version" -> 1, "SchemaVersion" -> "anomaly-profile-v0",
  "OwnerStateOptIn" -> False,
  "MinBaselineSamples" -> 8, "DeviationThreshold" -> 3.0, "FreshnessSeconds" -> 86400,
  "Pairs" -> {
    <|"PairId" -> "llm-injection-integrity", "StreamA" -> "InjectionSignalRate", "StreamB" -> "RunIntegrityRate",
      "MaxLagWindows" -> 3, "MinEffectSize" -> 0.5, "MinOverlapWindows" -> 5, "FDRFamily" -> "llm",
      "CooldownWindows" -> 3, "HoldoutWindows" -> 5, "Active" -> True, "ResearchOnly" -> False,
      "InvolvesOwnerState" -> False|>,
    <|"PairId" -> "system-prescan-tool", "StreamA" -> "PreScanFailureRate", "StreamB" -> "UnexpectedToolRequestRate",
      "MaxLagWindows" -> 3, "MinEffectSize" -> 0.5, "MinOverlapWindows" -> 5, "FDRFamily" -> "system",
      "CooldownWindows" -> 3, "HoldoutWindows" -> 5, "Active" -> True, "ResearchOnly" -> False,
      "InvolvesOwnerState" -> False|>,
    <|"PairId" -> "owner-mailnovelty-operational", "StreamA" -> "MailSenderNovelty", "StreamB" -> "OwnerOperationalSignal",
      "MaxLagWindows" -> 3, "MinEffectSize" -> 0.5, "MinOverlapWindows" -> 5, "FDRFamily" -> "owner",
      "CooldownWindows" -> 3, "HoldoutWindows" -> 5, "Active" -> False, "ResearchOnly" -> True,
      "InvolvesOwnerState" -> True|>},
  "Schedule" -> <|"Mode" -> "Manual", "Enabled" -> False, "Paused" -> False, "IntervalSeconds" -> 86400,
    "MaxCatchupWindows" -> 7, "NextRunAtUTC" -> Missing[]|>,
  "CreatedAtUTC" -> iAnomNow[]|>;

iAnomPairInvolvesOwnerState[pair_Association] := TrueQ[Lookup[pair, "InvolvesOwnerState", False]] ||
  iAnomOwnerStateQ[Lookup[pair, "StreamA", ""]] || iAnomOwnerStateQ[Lookup[pair, "StreamB", ""]];

Options[SourceVaultAnomalyWorkflowProfile] = {};
SourceVaultAnomalyWorkflowProfile[OptionsPattern[]] := Module[{rec},
  rec = iAnomRead[iAnomProfilePath[]];
  Which[
    ! AssociationQ[rec], iAnomDefaultProfile[],   (* 未設定は既定(署名不要の built-in) *)
    ! iAnomMacOK[rec],
      (* 改ざん検出: fail-closed。既定に落として tampered を明示 *)
      Append[iAnomDefaultProfile[], "ProfileIntegrity" -> "TamperedFellBackToDefault"],
    True, KeyDrop[rec, "MAC"]]];

Options[SourceVaultSetAnomalyWorkflowProfile] = {"OwnerAuthorization" -> False};
SourceVaultSetAnomalyWorkflowProfile[profile_Association, OptionsPattern[]] := Module[{cur, next, signed, hist},
  If[iAnomDir["baselines"] === $Failed, Return[Failure["AnomalyRootUnresolved", <||>]]];
  (* owner 権限必須。LLM/external content からは OwnerAuthorization に到達できない(コード経路のみ) *)
  If[! TrueQ[OptionValue["OwnerAuthorization"]],
    Return[Failure["OwnerAuthorizationRequired", <|"MessageTemplate" ->
      "profile は owner のみ変更可能です(OwnerAuthorization->True 必須)。LLM/external content からは変更不可=I-16。"|>]]];
  iAnomEnsureKeys[];
  cur = iAnomRead[iAnomProfilePath[]];
  next = Join[iAnomDefaultProfile[], KeyDrop[profile, {"MAC", "Version"}]];
  (* 既存 file があればその version を、無ければ built-in default(=incoming profile の version)を基準に +1 *)
  next["Version"] = If[AssociationQ[cur], Lookup[cur, "Version", 1], Lookup[profile, "Version", 1]] + 1;
  next["UpdatedAtUTC"] = iAnomNow[];
  next["BaselineEpoch"] = "svanomepoch:" <> iAnomULID[];   (* profile 変更後は baseline epoch 切替 *)
  signed = Append[next, "MAC" -> iAnomMac[next]];
  SourceVaultWithLock[iAnomLock, Module[{},
    (* 旧版を history へ(rollback 用) *)
    If[AssociationQ[cur],
      hist = iAnomProfileHistoryDir[];
      If[StringQ[hist], iAnomWrite[iAnomFile[hist, "v" <> ToString[Lookup[cur, "Version", 0]] <> "-" <> iAnomULID[]], cur]]];
    iAnomWrite[iAnomProfilePath[], signed]]];
  KeyDrop[signed, "MAC"]];

Options[SourceVaultProposeAnomalyProfileChange] = {"Source" -> "ExternalContent"};
SourceVaultProposeAnomalyProfileChange[proposal_Association, OptionsPattern[]] := Module[{dir, id, rec},
  dir = iAnomPendingDir[]; If[dir === $Failed, Return[Failure["AnomalyRootUnresolved", <||>]]];
  id = "svanompending:" <> iAnomULID[];
  rec = <|"ObjectClass" -> "SourceVaultAnomalyProfileProposal", "ProposalId" -> id,
    "Status" -> "PendingReview", "Source" -> OptionValue["Source"], "Proposal" -> proposal,
    "CreatedAtUTC" -> iAnomNow[], "Note" -> "自動適用しない(I-16)。owner が SetAnomalyWorkflowProfile で承認する。"|>;
  SourceVaultWithLock[iAnomLock, iAnomWrite[iAnomFile[dir, id], rec]];
  rec];

Options[SourceVaultRegisterCaneAnomalySchedule] = {"OwnerAuthorization" -> False};
SourceVaultRegisterCaneAnomalySchedule[spec_Association, OptionsPattern[]] := Module[{prof, sched},
  If[! TrueQ[OptionValue["OwnerAuthorization"]],
    Return[Failure["OwnerAuthorizationRequired", <|"MessageTemplate" ->
      "schedule は owner のみ登録可能です(OwnerAuthorization->True 必須)。schedule は分析権限のみ=I-16。"|>]]];
  prof = SourceVaultAnomalyWorkflowProfile[];
  sched = Join[<|"Mode" -> "Scheduled", "Enabled" -> True, "Paused" -> False, "IntervalSeconds" -> 86400,
    "MaxCatchupWindows" -> 7, "NextRunAtUTC" -> Missing[]|>, spec];
  (* enforcement 権限は付与しない: schedule は分析の起動のみ *)
  sched["EnforcementPermission"] = "None";
  SourceVaultSetAnomalyWorkflowProfile[Append[prof, "Schedule" -> sched], "OwnerAuthorization" -> True]];

(* ============================================================
   ワークフロー本体(observe-only。§4.23 冪等)
   ============================================================ *)
iAnomRunsDir[] := iAnomDir["runs"];
iAnomEventsDir[] := iAnomDir["events"];
iAnomRunIndexPath[] := FileNameJoin[{iAnomRootNow[], "runs-index.json"}];
iAnomPipelineStatusPath[] := FileNameJoin[{iAnomRootNow[], "pipeline-status.json"}];
iAnomSensitivePath[] := FileNameJoin[{iAnomRootNow[], "sensitive", "doctor-state.json"}];

iAnomWindowOf[streams_Association] := Module[{pts, starts, ends},
  pts = Flatten[Lookup[#, "Points", {}] & /@ Values[streams], 1];
  starts = DeleteMissing[Lookup[#, "WindowStart", Missing[]] & /@ pts];
  ends = DeleteMissing[Lookup[#, "WindowEnd", Missing[]] & /@ pts];
  {If[starts === {}, Missing[], First[Sort[starts]]],
   If[ends === {}, Missing[], Last[Sort[ends]]]}];

Options[SourceVaultRunCaneAnomalyWorkflow] = {"Window" -> Automatic, "Profile" -> Automatic};
SourceVaultRunCaneAnomalyWorkflow[input_Association, OptionsPattern[]] := Module[
  {streams, profile, profVer, snapDigest, window, idemKey, existing, runId, results, anomalies, hyps,
   mechanical, insufficient, ownerSkipped, activeStreams, pairs, runRec, eventRec, watermarks, optIn,
   processedStreams},
  If[iAnomRunsDir[] === $Failed, Return[Failure["AnomalyRootUnresolved", <||>]]];
  streams = Lookup[input, "Streams", <||>];
  If[! AssociationQ[streams], streams = <||>];
  profile = OptionValue["Profile"] /. Automatic :> SourceVaultAnomalyWorkflowProfile[];
  profVer = Lookup[profile, "Version", 1];
  optIn = TrueQ[Lookup[profile, "OwnerStateOptIn", False]];
  snapDigest = iAnomDigest[KeySort[streams]];
  window = OptionValue["Window"] /. Automatic :> iAnomWindowOf[streams];
  idemKey = iAnomDigest[{profVer, snapDigest, window}];
  (* --- 冪等: 同一 key の completed run は再利用(二重更新なし=§4.23・受入 96/97) --- *)
  existing = iAnomLookupRunByKey[idemKey];
  If[AssociationQ[existing] && existing["Status"] === "Completed",
    Return[Append[existing, "Reused" -> True]]];
  runId = "svanomrun:" <> iAnomULID[];
  (* owner 状態ストリームは opt-in 無しに読まない(受入 100) *)
  ownerSkipped = Select[Keys[streams], iAnomOwnerStateQ[#] && ! optIn &];
  activeStreams = KeySelect[streams, ! iAnomOwnerStateQ[#] || optIn &];
  processedStreams = {};
  (* --- stream 別逸脱検知(active baseline があれば使用) --- *)
  results = Association@KeyValueMap[Function[{kind, sd},
    Module[{base = iAnomActiveBaseline[kind], det},
      det = SourceVaultDetectStreamAnomalies[Append[sd, "StreamKind" -> kind],
        "Baseline" -> If[AssociationQ[base], base, Automatic],
        "DeviationThreshold" -> Lookup[profile, "DeviationThreshold", 3.0],
        "MinBaselineSamples" -> Lookup[profile, "MinBaselineSamples", 8]];
      kind -> det]], activeStreams];
  insufficient = Keys@Select[results, MatchQ[#, Missing["InsufficientBaseline"]] &];
  processedStreams = Keys@Select[results, AssociationQ];
  anomalies = Flatten[Lookup[#, "Anomalies", {}] & /@ Select[Values[results], AssociationQ]];
  (* --- 事前登録 pair のみ相関(active + owner-state は opt-in 時のみ) --- *)
  pairs = Select[Lookup[profile, "Pairs", {}], TrueQ[Lookup[#, "Active", False]] &&
    (! iAnomPairInvolvesOwnerState[#] || optIn) &];
  hyps = {}; mechanical = {};
  Scan[Function[pair,
    Module[{a = Lookup[results, pair["StreamA"], Missing[]], b = Lookup[results, pair["StreamB"], Missing[]], h},
      If[AssociationQ[a] && AssociationQ[b],
        h = SourceVaultCorrelateAnomalies[pair, a, b,
          "MaxLagWindows" -> Lookup[pair, "MaxLagWindows", 3],
          "MinEffectSize" -> Lookup[pair, "MinEffectSize", 0.5],
          "MinOverlapWindows" -> Lookup[pair, "MinOverlapWindows", 5],
          "DeviationThreshold" -> Lookup[profile, "DeviationThreshold", 3.0]];
        Which[
          MatchQ[h, Missing["MechanicallyCoupled"]],
            AppendTo[mechanical, <|"PairId" -> pair["PairId"], "StreamA" -> pair["StreamA"],
              "StreamB" -> pair["StreamB"], "LineageDependence" -> "DirectLineage"|>],
          AssociationQ[h], AppendTo[hyps, h]]]]], pairs];
  watermarks = Association@KeyValueMap[Function[{kind, det},
    kind -> Module[{evs = If[AssociationQ[det], Lookup[det, "Evaluations", {}], {}]},
      If[evs === {}, Missing[], Lookup[Last[evs], "WindowEnd", Missing[]]]]], results];
  (* --- event/report を local-only store に保存(enforcement なし) --- *)
  eventRec = <|"ObjectClass" -> "SourceVaultCaneAnomalyEvents", "WorkflowRunId" -> runId,
    "Anomalies" -> anomalies, "Hypotheses" -> hyps, "MechanicalCouplings" -> mechanical,
    "InsufficientBaselineStreams" -> insufficient|>;
  runRec = <|"ObjectClass" -> "SourceVaultCaneAnomalyWorkflowRun", "WorkflowRunId" -> runId,
    "ProfileRef" -> Lookup[profile, "ProfileId", Missing[]], "ProfileVersion" -> profVer,
    "InputSnapshotDigest" -> snapDigest, "IdempotencyKey" -> idemKey,
    "BaselineEpochRefs" -> DeleteMissing[Function[k, Module[{b = iAnomActiveBaseline[k]},
      If[AssociationQ[b], Lookup[b, "EpochRef", Missing[]], Missing[]]]] /@ processedStreams],
    "WindowStart" -> window[[1]], "WindowEnd" -> window[[2]], "Watermarks" -> watermarks,
    "ProcessedStreams" -> processedStreams, "SkippedOwnerStateStreams" -> ownerSkipped,
    "InsufficientBaselineStreams" -> insufficient,
    "OutputEventRefs" -> Join[Lookup[#, "EventId", Nothing] & /@ anomalies,
      Lookup[#, "HypothesisId", Nothing] & /@ hyps],
    "AnomalyCount" -> Length[anomalies], "HypothesisCount" -> Length[hyps],
    "MechanicalCouplingCount" -> Length[mechanical],
    (* observe-only 契約(I-16): enforcement は一切しない *)
    "Enforcement" -> "ObserveOnly", "EnforcementActions" -> {},
    "Status" -> "Completed", "StartedAt" -> iAnomNow[], "CompletedAt" -> iAnomNow[],
    "ModelVersion" -> $svAnomModelVersion|>;
  SourceVaultWithLock[iAnomLock, Module[{idx},
    iAnomWrite[iAnomFile[iAnomEventsDir[], runId], eventRec];
    iAnomWrite[iAnomFile[iAnomRunsDir[], runId], runRec];
    idx = iAnomRead[iAnomRunIndexPath[]]; If[! AssociationQ[idx], idx = <||>];
    idx[idemKey] = runId; iAnomWrite[iAnomRunIndexPath[], idx];
    (* pipeline liveness(通常 probe が読む。sensitive 情報は含めない) *)
    iAnomWrite[iAnomPipelineStatusPath[], <|"LastRunAtUTC" -> iAnomNow[], "LastRunEpoch" -> iAnomEpoch[],
      "LastRunStatus" -> "Completed", "LastRunId" -> runId|>];
    (* sensitive doctor 用の local-only 詳細(heartbeat/cloud/mail には絶対に出さない) *)
    iAnomWriteSensitive[<|"PendingSensitiveAlerts" -> AnyTrue[hyps, iAnomOwnerStateHypQ],
      "PendingSensitiveAlertCount" -> Count[hyps, _?iAnomOwnerStateHypQ],
      "RecentHypotheses" -> hyps, "RecentAnomalies" -> anomalies,
      "MechanicalCouplings" -> mechanical, "UpdatedAtUTC" -> iAnomNow[], "RunId" -> runId|>]]];
  runRec];

(* 入力なしの簡便形(空 streams。OptionsPattern と Association の曖昧回避のため bare 引数のみ) *)
SourceVaultRunCaneAnomalyWorkflow[] := SourceVaultRunCaneAnomalyWorkflow[<|"Streams" -> <||>|>];

iAnomOwnerStateHypQ[h_Association] := iAnomOwnerStateQ[Lookup[h, "StreamA", ""]] ||
  iAnomOwnerStateQ[Lookup[h, "StreamB", ""]];

iAnomLookupRunByKey[key_String] := Module[{idx = iAnomRead[iAnomRunIndexPath[]], id},
  If[! AssociationQ[idx], Return[Missing[]]];
  id = Lookup[idx, key, Missing[]];
  If[! StringQ[id], Missing[], iAnomRead[iAnomFile[iAnomRunsDir[], id]]]];

iAnomWriteSensitive[detail_Association] := Module[{dir = FileNameJoin[{iAnomRootNow[], "sensitive"}]},
  If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
  iAnomWrite[iAnomSensitivePath[], detail]];

Options[SourceVaultCaneAnomalyWorkflowRuns] = {"Limit" -> 20};
SourceVaultCaneAnomalyWorkflowRuns[OptionsPattern[]] := Module[{dir = iAnomRunsDir[], files, recs},
  If[dir === $Failed, Return[{}]];
  files = FileNames["*.json", dir];
  recs = Select[iAnomRead /@ files, AssociationQ];
  Take[ReverseSortBy[recs, Lookup[#, "CompletedAt", ""] &], UpTo[OptionValue["Limit"]]]];

(* ============================================================
   diagnostics 二層(§5.15)
   ============================================================ *)
(* 通常 probe: pipeline liveness のみ。<|Health, ReasonCode|>。
   sensitive alert の有無で Health を変えない。owner 状態 / hypothesis id / SLV ref を出さない。 *)
SourceVaultCaneDiagnosticsProbe[] := Module[{st, prof, sched, ageSec, fresh},
  st = iAnomRead[iAnomPipelineStatusPath[]];
  prof = Quiet@Check[SourceVaultAnomalyWorkflowProfile[], iAnomDefaultProfile[]];
  sched = Lookup[prof, "Schedule", <||>];
  fresh = Lookup[prof, "FreshnessSeconds", 86400];
  Which[
    ! AssociationQ[st],
      (* 未実行。schedule 有効なら stale、manual なら健全(何もすることが無い) *)
      If[TrueQ[Lookup[sched, "Enabled", False]] && ! TrueQ[Lookup[sched, "Paused", False]],
        <|"Health" -> "Degraded", "ReasonCode" -> "PipelineStale"|>,
        <|"Health" -> "OK", "ReasonCode" -> "PipelineHealthy"|>],
    Lookup[st, "LastRunStatus", ""] =!= "Completed",
      <|"Health" -> "Failing", "ReasonCode" -> "PipelineFailed"|>,
    True,
      ageSec = iAnomEpoch[] - Lookup[st, "LastRunEpoch", 0];
      If[TrueQ[Lookup[sched, "Enabled", False]] && ! TrueQ[Lookup[sched, "Paused", False]] && ageSec > fresh,
        <|"Health" -> "Degraded", "ReasonCode" -> "PipelineStale"|>,
        <|"Health" -> "OK", "ReasonCode" -> "PipelineHealthy"|>]]];

(* sensitive doctor: local UI 限定の詳細。heartbeat/cloud/mail には出さない。 *)
Options[SourceVaultCaneSensitiveDoctor] = {};
SourceVaultCaneSensitiveDoctor[OptionsPattern[]] := Module[{d = iAnomRead[iAnomSensitivePath[]]},
  If[! AssociationQ[d],
    Return[<|"ObjectClass" -> "SourceVaultCaneSensitiveDoctor", "PendingSensitiveAlerts" -> False,
      "PendingSensitiveAlertCount" -> 0, "RecentHypotheses" -> {}, "RecentAnomalies" -> {},
      "MechanicalCouplings" -> {}, "Note" -> "local UI 限定。この情報を heartbeat/cloud/mail に出してはならない。"|>]];
  Append[<|"ObjectClass" -> "SourceVaultCaneSensitiveDoctor"|>,
    Append[d, "Note" -> "local UI 限定。この情報を heartbeat/cloud/mail に出してはならない。"]]];

If[! ValueQ[$svAnomProbeRegistered], $svAnomProbeRegistered = False];
SourceVaultRegisterCaneDiagnostics[] := Quiet@Check[
  If[Names["SourceVault`SourceVaultDiagnosticsRegisterProbe"] =!= {} &&
     With[{sym = Symbol["SourceVault`SourceVaultDiagnosticsRegisterProbe"]}, Length[DownValues[sym]]] > 0,
    Symbol["SourceVault`SourceVaultDiagnosticsRegisterProbe"]["CaneAnomalyPipeline",
      Function[SourceVaultCaneDiagnosticsProbe[]]];
    $svAnomProbeRegistered = True;
    <|"Status" -> "Registered", "ProbeId" -> "CaneAnomalyPipeline"|>,
    <|"Status" -> "Skipped", "Reason" -> "DiagnosticsUnavailable"|>],
  <|"Status" -> "Skipped", "Reason" -> "RegisterException"|>];

(* ============================================================
   init / status
   ============================================================ *)
Options[SourceVaultAnomalyInitialize] = {"Root" -> Automatic};
SourceVaultAnomalyInitialize[OptionsPattern[]] := Module[{root, guard},
  $svAnomRoot = OptionValue["Root"];
  root = iAnomRootNow[];
  guard = iAnomSinkGuard[root]; If[FailureQ[guard], Return[guard]];
  If[iAnomDir["runs"] === $Failed, Return[Failure["AnomalyRootUnresolved", <||>]]];
  iAnomDir["events"]; iAnomDir["baselines"]; iAnomDir["profile-history"]; iAnomDir["profile-pending"];
  iAnomEnsureKeys[];
  SourceVaultRegisterCaneDiagnostics[];
  <|"Status" -> "Initialized", "Root" -> root, "ModelVersion" -> $svAnomModelVersion|>];

Options[SourceVaultAnomalyStatus] = {};
SourceVaultAnomalyStatus[OptionsPattern[]] := Module[{root = iAnomRootNow[], runs, actives, prof},
  If[! StringQ[root] || ! DirectoryQ[root],
    Return[<|"Initialized" -> False, "Root" -> root|>]];
  runs = FileNames["*.json", FileNameJoin[{root, "runs"}]];
  actives = iAnomRead[iAnomActiveIndexPath[]];
  prof = SourceVaultAnomalyWorkflowProfile[];
  <|"Initialized" -> True, "Root" -> root, "RunCount" -> Length[runs],
    "ActiveBaselineCount" -> If[AssociationQ[actives], Length[actives], 0],
    "ProfileVersion" -> Lookup[prof, "Version", 1],
    "OwnerStateOptIn" -> TrueQ[Lookup[prof, "OwnerStateOptIn", False]],
    "ActivePairs" -> Length@Select[Lookup[prof, "Pairs", {}], TrueQ[Lookup[#, "Active", False]] &],
    "ProbeRegistered" -> TrueQ[$svAnomProbeRegistered]|>];

(* ロード時に diagnostics へ弱く登録(rule 11。diagnostics 未ロードなら no-op) *)
SourceVaultRegisterCaneDiagnostics[];

(* catch-all: 未評価/誤引数呼び出しの Part が静かに引数を返す罠を塞ぐ(第 1 引数が Association 以外) *)
SourceVaultDetectStreamAnomalies[args___] := Failure["BadAnomalyArgs",
  <|"MessageTemplate" -> "SourceVaultDetectStreamAnomalies は streamData_Association を取ります。"|>] /;
  ! MatchQ[{args}, {_Association, ___}];

End[];

EndPackage[];
