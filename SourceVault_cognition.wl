(* ::Package:: *)

(* ============================================================
   SourceVault_cognition.wl -- Cane Phase 0: SensitiveLocalVault 契約
   (認知系データの保存境界・暗号化・crypto-shredding 消去)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault.wl"]]

   仕様: SourceVault_info/design/sourcevault_cane_knowledge_home_mining_spec_v0_7.md
     §2 I-1   保存境界(人間 subject の認知系は SensitiveLocalVault のみ。Dropbox/CoreRoot/PrivateVault 禁止)
     §2 I-3b  retention と消去(物理削除・replay で復活しない)
     §2 I-9   bitemporal(OccurredAtUTC / ObservedAtUTC 必須)
     §4.11    実装契約(暗号化・鍵・除外・crypto-shredding・削除 manifest・削除後検査)
   decision record: SourceVault_info/design/sourcevault_cane_phase0_decisions_v1.md

   設計(Phase 0 decision):
     - 鍵: NBAccess KeyRef(backend SystemCredential = Windows DPAPI)。subject×月 の shard 毎に
       AES256 鍵を発行し、消去 = 鍵削除(crypto-shredding)+ファイル削除+削除後検査。
     - 鍵喪失 = 当該データ復元不能(仕様上明示)。マルチデバイス同期はしない(I-1)。
     - 正準: <LocalState>/sensitive/cognition/ 配下のみ。書込みは本モジュールの専用 API のみが行う。
       汎用 SourceVaultAppendEvent を認知系に使わない。
     - Memory backend はテスト専用("AllowMemoryBackend" 明示時のみ。鍵がカーネル終了で消える)。
   ============================================================ *)

BeginPackage["SourceVault`"];

$SourceVaultCognitionEnabled::usage =
  "$SourceVaultCognitionEnabled は認知系ストアのマスタースイッチ(既定 True)。False で全書込みを拒否" <>
  "(owner の「全推定を停止」の実体。§2 I-6)。";
$SourceVaultCognitionRetentionDays::usage =
  "$SourceVaultCognitionRetentionDays は認知系 event の retention 上限日数(既定 730)。" <>
  "SourceVaultCognitionPruneExpired が超過 shard を消去する(§2 I-3b)。";

SourceVaultCognitionInitialize::usage =
  "SourceVaultCognitionInitialize[opts] は SensitiveLocalVault(<LocalState>/sensitive/cognition)を初期化する(冪等)。" <>
  "sink guard: 解決パスが PrivateVault/CoreRoot 配下なら Failure(fail-closed)。鍵 backend が SystemCredential " <>
  "でなければ Failure(\"AllowMemoryBackend\"->True はテスト専用)。除外チェックリスト README を書く。" <>
  "オプション \"Root\"(Automatic)、\"AllowMemoryBackend\"(False)。";
SourceVaultCognitionStatus::usage =
  "SourceVaultCognitionStatus[] は <|Initialized, Root, Backend, Enabled, SubjectCount, ShardCount|> を返す。";
SourceVaultCognitionAppendEvent::usage =
  "SourceVaultCognitionAppendEvent[event, opts] は認知系 event を SensitiveLocalVault に暗号化追記する(専用 API。I-1)。" <>
  "必須: \"SubjectRef\"、\"OccurredAtUTC\"(bitemporal, I-9)。\"ObservedAtUTC\"/\"EventId\" は自動補完。" <>
  "shard = subject×月、shard 毎の AES256 KeyRef で行単位暗号化。無効時/未初期化/検証失敗は Failure(fail-closed)。" <>
  "オプション \"Root\"(Automatic)。戻り値は EventId 付き event。";
SourceVaultCognitionEvents::usage =
  "SourceVaultCognitionEvents[subjectRef, opts] は subject の event を復号して返す(OccurredAtUTC 昇順)。" <>
  "crypto-shred 済み shard は読めず Notes に \"Shredded\" として報告(復活しない)。" <>
  "オプション \"Period\"(All | \"yyyy-mm\")、\"Root\"。戻り値 <|Events, Notes|>。";
SourceVaultCognitionSubjects::usage =
  "SourceVaultCognitionSubjects[opts] は shard index にある subject ref 一覧を返す(local のみ)。";
SourceVaultCognitionErase::usage =
  "SourceVaultCognitionErase[subjectRef|All, opts] は認知系データを物理消去する(§4.11 crypto-shredding)。" <>
  "手順: 削除 manifest(全 shard ファイル+KeyRef 列挙)→(実行時)鍵削除+ファイル削除+index 更新→削除後検査" <>
  "(ファイル不存在+鍵 Missing+読み戻し空)→metadata のみの監査行。**既定 \"DryRun\"->True**(=impact report のみ)。" <>
  "オプション \"Period\"(All | \"yyyy-mm\")、\"DryRun\"(True)、\"Root\"。戻り値 <|Manifest, Executed, Inspection, BestEffortNote|>。";
SourceVaultCognitionPruneExpired::usage =
  "SourceVaultCognitionPruneExpired[opts] は retention($SourceVaultCognitionRetentionDays)超過の shard を消去する。" <>
  "オプション \"DryRun\"(True)、\"Root\"。";
SourceVaultCognitionSetEnabled::usage =
  "SourceVaultCognitionSetEnabled[True|False] はマスタースイッチを切り替える(即時)。";

(* ---- Phase 1D: OperationalSupportSignal v0(観測専用 shadow。§4.5.2) ---- *)
$SourceVaultCognitionMinBaselineDays::usage =
  "$SourceVaultCognitionMinBaselineDays は SupportNeedTier 算出に必要な最小ベースライン日数(既定 14)。" <>
  "未満は Missing[\"InsufficientBaseline\"] で tier を出さない(cold start 不変条件)。";
SourceVaultOperationalSignalEstimate::usage =
  "SourceVaultOperationalSignalEstimate[opts] は Claude Code セッション digest から owner の操作支援 signal を" <>
  "決定的に推定する(**観測専用 shadow**。LLM prompt/下流 action へ接続しない=I-13。返信遅延・締切は入力に使わない=循環回避)。" <>
  "日次特徴: Sessions / UserMessages / LateHourRate(深夜開始率) / RetrySimilarityRate(連続プロンプト類似率=やり直し proxy)。" <>
  "個人内ベースライン(median+MAD)からの偏差で SupportNeedTier(Low|Medium|High=支援必要度。能力ではない)。" <>
  "ベースライン不足は Missing[\"InsufficientBaseline\"]。日次 sample を SensitiveLocalVault に冪等追記(当日は partial のため永続しない)。" <>
  "オプション \"Digests\"(Automatic=SourceVaultClaudeCodeSessions[])、\"Subject\"(\"ent-owner\")、\"WindowDays\"(30)、" <>
  "\"TimeZoneOffsetHours\"(9)、\"Persist\"(True)、\"Root\"。戻り値 <|Days, PersistedDates, Baseline, Status|>。";
SourceVaultHumanSupportProfile::usage =
  "SourceVaultHumanSupportProfile[subjectRef, opts] は保存済み OperationalSignalSampled + CognitiveSelfReported から" <>
  "typed projection(§4.5.2)を返す: <|ObservableSignalsLatest, SupportNeedEstimate(<|SupportNeedTier, Confidence->\"Low\"|>" <>
  "| Missing[\"InsufficientBaseline\"]), SelfReports, Window, BaselineVersion, ShadowOnly->True|>。" <>
  "共通 Tier は存在しない(SupportNeedTier のみ。ExecutionRiskTier と相互変換しない)。オプション \"WindowDays\"(90)、\"Root\"。";
SourceVaultRecordCognitiveSelfReport::usage =
  "SourceVaultRecordCognitiveSelfReport[score, opts] は owner の自己申告(1..5)を SensitiveLocalVault に記録する" <>
  "(shadow 比較のアンカー。資料 p15 'Just ask me directly!')。オプション \"Subject\"、\"OccurredAtUTC\"(Automatic)、\"Note\"、\"Root\"。";
SourceVaultCognitionCompareView::usage =
  "SourceVaultCognitionCompareView[opts] は日次の signal 偏差と自己申告を並べる local 専用 Dataset(shadow 評価面。" <>
  "SensitiveLocalVault 外へ出さない)。オプション \"Subject\"、\"WindowDays\"(30)、\"Root\"。";

(* ---- Phase 1E(第一増分): action risk taxonomy + Guard shadow(§5.7) ---- *)
SourceVaultActionRiskClassify::usage =
  "SourceVaultActionRiskClassify[actionSpec] は action の客観リスクを決定的に分類する(§5.7 taxonomy。Guard の主入力)。" <>
  "actionSpec: <|ActionKind, Reversibility(Draft|Undoable|Irreversible), Reach(Self|KnownRecipients|Organization|Public), " <>
  "SensitivityGap(content PL−宛先許可 PL。既定 0), ImpactDomains({Financial,Legal,Health,Safety}), TimeConstraint, RecipientCount|>。" <>
  "戻り値 <|RiskLevel(Low|Medium|High), Taxonomy, ReasonCodes|>。認知系推定は入力に含まれない(1D 昇格前)。";
SourceVaultGuardEvaluate::usage =
  "SourceVaultGuardEvaluate[actionSpec, opts] は Guard の **shadow 評価**: risk 分類から decision class " <>
  "(Standard|Confirm|TimedDefer)の推奨を計算し、内容最小化した GuardDecisionRecorded(ShadowMode->True)を通常 event store に" <>
  "記録するだけで**一切 enforce しない**(1E shadow。昇格は §8 評価ゲート後)。認知系単独 Deny は存在しない(I-2)。" <>
  "オプション \"Persist\"(True)。戻り値 <|Decision, RiskLevel, ReasonCodes, ShadowMode->True|>。";

(* ---- Phase 1E(第二増分): Commitment 最小 + shadow 並走記録(§4.8/§5.7) ---- *)
SourceVaultCommitmentObserve::usage =
  "SourceVaultCommitmentObserve[spec] は Commitment(返信すべきメール/締切/準備)を観測記録する(§4.8。" <>
  "**cognition の特徴量には使わない=循環回避**。本人支援と Guard 評価の ground truth 用)。" <>
  "spec: <|Kind(MailReply|Todo|EventPreparation|Deadline|Recurring), SourceRefs, Deadline, DetectionBasis|>。" <>
  "CommitmentId(ULID)/Status->Open を補完し CommitmentObserved を通常 store に記録。";
SourceVaultCommitmentSetStatus::usage =
  "SourceVaultCommitmentSetStatus[commitmentId, status, opts] は状態遷移を記録する。" <>
  "status: Done|NotNeeded|HandledElsewhere|Delegated|Snoozed|Open。\"OwnerCorrection\"(owner 訂正=ground truth)、" <>
  "\"FalseAlarm\"(検出誤り)。CommitmentStatusChanged を記録。";
SourceVaultCommitments::usage =
  "SourceVaultCommitments[opts] は event replay で Commitment 一覧(最新状態)を返す。" <>
  "オプション \"Status\"(All|_String)、\"Limit\"(既定 200)。";
SourceVaultGuardRecordParallel::usage =
  "SourceVaultGuardRecordParallel[gateResult, actionSpec, opts] は既存 gate の判定と Guard shadow 推奨を" <>
  "**並走記録**する(1E: 既存 gate の結果と並行して decision を記録するだけ。enforce しない)。" <>
  "gateResult: 既存 release/action gate の戻り(Decision 等)。内容最小化 GuardParallelRecorded を通常 store へ。" <>
  "戻り値 <|GateDecision, ShadowDecision, RiskLevel, Agreement|>。";
SourceVaultGuardShadowStats::usage =
  "SourceVaultGuardShadowStats[opts] は記録済み GuardDecisionRecorded/GuardParallelRecorded/GuardMailParallelRecorded を集計し、" <>
  "action class 別の decision 分布・gate/shadow 一致率・メール送信の caution alignment(false intervention 評価の材料。§8)を返す。" <>
  "オプション \"Limit\"(既定 2000)。";
SourceVaultPlanMessageReleaseWithGuardShadow::usage =
  "SourceVaultPlanMessageReleaseWithGuardShadow[spec, opts] は既存 SourceVaultPlanMessageRelease(正準ゲート)を" <>
  "**一切変えずに**呼び、同じ action に対する Guard shadow 推奨を並走記録する(1E: shadow mode。enforce しない)。" <>
  "既存 plan に \"GuardShadow\" キーを additive に付けて返す(既存 caller は無影響)。GuardMailParallelRecorded を" <>
  "内容最小化して通常 store に記録。Aligned=ゲートと shadow がともに慎重か(mail は常に確認要=Medium+)。オプション \"Persist\"(True)。";

(* ---- Phase 1G: owner 入力支援(§4.15/4.16/§5.12。決定的・SupportNeedTier 不使用=I-12) ---- *)
SourceVaultOwnerInputRiskAssess::usage =
  "SourceVaultOwnerInputRiskAssess[input] は owner 入力の **input 固有** リスクを決定的に評価する(§4.15。" <>
  "SupportNeedTier は使わない=I-12: 状態から prompt error を推定しない)。InputSegments(OwnerInstruction|QuotedData=" <>
  "引用/貼付は untrusted data、v0.5 authority 分離)、AmbiguitySignals(指示語)、MissingArgumentSignals(宛先未指定等)、" <>
  "IrreversibleActionRequested、PrivacyMismatch(QuotedData+送信/公開)。" <>
  "戻り値 <|InputSegments, Signals, PromptInterpretationRisk(Low|Medium|High), IrreversibleActionRequested, OriginalPromptDigest|>。";
SourceVaultAssistOwnerInput::usage =
  "SourceVaultAssistOwnerInput[input, opts] は支援 case(§4.16)を開く: 評価→AssistanceMode " <>
  "(Normal|ReviewEnhanced|DraftOnly|ConfirmBeforeCommit。不可逆は常に commit 前 owner 確認=権限は広がらない)を決定し、" <>
  "必要なら**結果を分ける最小の一問**(ClarificationQuestion)を付ける。case は SensitiveLocalVault に永続" <>
  "(original prompt は immutable=I-12)。**ModelFacingPolicy には mode のみ**(支援状態・理由を LLM に渡さない=I-13)。" <>
  "オプション \"Persist\"(True)、\"Root\"、\"Subject\"(\"ent-owner\")。";
SourceVaultAssistanceRecordOutcome::usage =
  "SourceVaultAssistanceRecordOutcome[assistanceCaseId, outcome, opts] は ChosenIntentRef/OwnerCorrection/" <>
  "IntentPreserved(True|False)を記録する(intent preservation 測定=§8)。SensitiveLocalVault。";

Begin["`Private`"];

If[! BooleanQ[SourceVault`$SourceVaultCognitionEnabled], SourceVault`$SourceVaultCognitionEnabled = True];
If[! IntegerQ[SourceVault`$SourceVaultCognitionRetentionDays], SourceVault`$SourceVaultCognitionRetentionDays = 730];

(* ---- 小道具(knowledgehome と独立にロード可能なよう自前定義) ---- *)
$svCogCrockford = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"];
iCogCrock[n_Integer, len_Integer] := Module[{d = {}, x = n},
  Do[PrependTo[d, $svCogCrockford[[Mod[x, 32] + 1]]]; x = Quotient[x, 32], {len}]; StringJoin[d]];
iCogULID[] := Module[{ms = Round[(AbsoluteTime[] - AbsoluteTime[{1970, 1, 1, 0, 0, 0}, TimeZone -> 0])*1000],
  rnd = FromDigits[StringTake[StringDelete[CreateUUID[], "-"], 20], 16]},
  iCogCrock[ms, 10] <> iCogCrock[Mod[rnd, 32^16], 16]];
iCogNowUTC[] := DateString[Now, {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"},
  TimeZone -> 0];
iCogJSON[x_] := ExportByteArray[x /. m_Missing :> Null, "RawJSON", "Compact" -> True];
iCogSubjectToken[s_String] := IntegerString[Hash[s, "SHA256"], 36];

(* ---- root 解決と sink guard(I-1: PrivateVault/CoreRoot 配下を拒否) ---- *)
iCogCanonical[p_String] := ToLowerCase[StringReplace[ExpandFileName[p], "\\" -> "/"]];
iCogUnderQ[child_String, parent_] := StringQ[parent] && StringLength[parent] > 0 &&
  StringStartsQ[iCogCanonical[child], iCogCanonical[parent]];

iCogRoot[rootOpt_] := Module[{ls},
  rootOpt /. Automatic :> (
    ls = SourceVaultRoot["LocalState"];
    If[! StringQ[ls], Missing["LocalStateUnresolved"],
      FileNameJoin[{ls, "sensitive", "cognition"}]])];

iCogSinkGuard[root_] := Module[{pv, cr},
  pv = Quiet@Check[SourceVaultRoot["PrivateVault"], Missing[]];
  cr = Quiet@Check[SourceVaultCoreRoot[], Missing[]];
  Which[
    ! StringQ[root], Failure["CognitionRootUnresolved",
      <|"MessageTemplate" -> "SensitiveLocalVault root を解決できません(LocalState 未設定)。fail-closed。"|>],
    iCogUnderQ[root, pv], Failure["CognitionSinkViolation",
      <|"MessageTemplate" -> "認知系 root が PrivateVault(Dropbox 同期)配下です。I-1 違反のため拒否。"|>],
    iCogUnderQ[root, cr], Failure["CognitionSinkViolation",
      <|"MessageTemplate" -> "認知系 root が CoreRoot(クロスマシン共有)配下です。I-1 違反のため拒否。"|>],
    True, root]];

iCogBackendOK[allowMemory_] := Module[{be = NBAccess`$NBCredentialBackend},
  Which[
    be === "SystemCredential", True,
    TrueQ[allowMemory], True,  (* テスト専用: 鍵はカーネル終了で消える *)
    True, Failure["CognitionKeyBackend",
      <|"MessageTemplate" -> "鍵 backend が SystemCredential ではありません(現在: " <> ToString[be] <>
        ")。NBAccess`$NBCredentialBackend = \"SystemCredential\" を設定してください(Memory はテスト専用)。"|>]]];

$svCogInitialized = <||>;  (* root -> True *)

iCogIndexPath[root_] := FileNameJoin[{root, "shard-index.json"}];
iCogAuditPath[root_] := FileNameJoin[{root, "erase-audit.jsonl"}];
iCogShardDir[root_] := FileNameJoin[{root, "shards"}];
iCogLockName[root_] := "svcog-" <> IntegerString[Hash[root], 16, 8];

iCogReadIndex[root_] := Module[{p = iCogIndexPath[root], j},
  If[! FileExistsQ[p], Return[<|"Version" -> 1, "Subjects" -> <||>|>]];
  j = Quiet@Check[ImportByteArray[ByteArray[BinaryReadList[p, "Byte"]], "RawJSON"], $Failed];
  If[AssociationQ[j], j, <|"Version" -> 1, "Subjects" -> <||>|>]];
iCogWriteIndex[root_, idx_] := Module[{p = iCogIndexPath[root], tmp = iCogIndexPath[root] <> ".tmp"},
  BinaryWrite[tmp, Normal[iCogJSON[idx]]]; Close[tmp];
  Quiet@DeleteFile[p]; RenameFile[tmp, p]];

$svCogExclusionReadme = StringRiffle[{
  "SensitiveLocalVault (cognition) -- exclusion checklist (Phase 0 decision, spec v0.7 4.11)",
  "",
  "This directory holds ENCRYPTED cognitive-state events (crypto-shredding via per-shard keys",
  "in Windows Credential Manager / DPAPI). Keep it OUT of every sync/backup/index path:",
  "  [ ] Dropbox / OneDrive / any cloud sync: this dir must stay under LocalState (never move it).",
  "  [ ] Windows Search indexing: exclude this folder (Settings > Searching Windows > Excluded folders).",
  "  [ ] Antivirus cloud sample submission: exclude this folder if the product supports it.",
  "  [ ] OS backup (File History / third-party): exclude this folder.",
  "  [ ] Crash dumps / swap may still hold plaintext transiently (best-effort limit; documented).",
  "Key loss = data unrecoverable BY DESIGN. Erasure = key deletion + file deletion + inspection.",
  ""}, "\n"];

Options[SourceVaultCognitionInitialize] = {"Root" -> Automatic, "AllowMemoryBackend" -> False};
SourceVaultCognitionInitialize[OptionsPattern[]] := Module[{root, guard, bk},
  root = iCogRoot[OptionValue["Root"]];
  guard = iCogSinkGuard[root];
  If[FailureQ[guard], Return[guard]];
  bk = iCogBackendOK[OptionValue["AllowMemoryBackend"]];
  If[FailureQ[bk], Return[bk]];
  If[! DirectoryQ[iCogShardDir[root]],
    CreateDirectory[iCogShardDir[root], CreateIntermediateDirectories -> True]];
  Module[{rp = FileNameJoin[{root, "README-EXCLUSIONS.txt"}]},
    If[! FileExistsQ[rp], Export[rp, $svCogExclusionReadme, "Text"]]];
  $svCogInitialized[root] = True;
  <|"Status" -> "Initialized", "Root" -> root,
    "Backend" -> NBAccess`$NBCredentialBackend,
    "MemoryBackendAllowed" -> TrueQ[OptionValue["AllowMemoryBackend"]]|>];

Options[SourceVaultCognitionStatus] = {"Root" -> Automatic};
SourceVaultCognitionStatus[OptionsPattern[]] := Module[{root = iCogRoot[OptionValue["Root"]], idx},
  If[! StringQ[root] || ! TrueQ[$svCogInitialized[root]],
    Return[<|"Initialized" -> False, "Root" -> root, "Enabled" -> TrueQ[SourceVault`$SourceVaultCognitionEnabled]|>]];
  idx = iCogReadIndex[root];
  <|"Initialized" -> True, "Root" -> root, "Backend" -> NBAccess`$NBCredentialBackend,
    "Enabled" -> TrueQ[SourceVault`$SourceVaultCognitionEnabled],
    "SubjectCount" -> Length[idx["Subjects"]],
    "ShardCount" -> Total[Length[Lookup[#, "Shards", {}]] & /@ Values[idx["Subjects"]]]|>];

SourceVaultCognitionSetEnabled[b : True | False] := (SourceVault`$SourceVaultCognitionEnabled = b;
  <|"Enabled" -> b|>);

(* ---- append(専用 API。fail-closed) ---- *)
iCogPeriodOf[occ_String] := If[StringMatchQ[occ, DigitCharacter ~~ DigitCharacter ~~ DigitCharacter ~~
    DigitCharacter ~~ "-" ~~ DigitCharacter ~~ DigitCharacter ~~ ___],
  StringTake[occ, 7], Missing["BadOccurredAt"]];

iCogShardKeyRef[token_String, period_String] := "svcog:" <> token <> ":" <> period;

Options[SourceVaultCognitionAppendEvent] = {"Root" -> Automatic};
SourceVaultCognitionAppendEvent[event_Association, OptionsPattern[]] := Module[
  {root, guard, subj, occ, period, token, keyRef, ev, idx, subjRec, shardFile, enc, line},
  If[! TrueQ[SourceVault`$SourceVaultCognitionEnabled],
    Return[Failure["CognitionDisabled", <|"MessageTemplate" -> "認知系ストアは停止中です($SourceVaultCognitionEnabled=False)。"|>]]];
  root = iCogRoot[OptionValue["Root"]];
  guard = iCogSinkGuard[root]; If[FailureQ[guard], Return[guard]];
  If[! TrueQ[$svCogInitialized[root]],
    Return[Failure["CognitionNotInitialized", <|"MessageTemplate" -> "SourceVaultCognitionInitialize[] を先に実行してください。"|>]]];
  subj = Lookup[event, "SubjectRef", Missing[]];
  If[! StringQ[subj] || StringLength[subj] === 0,
    Return[Failure["CognitionBadEvent", <|"MessageTemplate" -> "SubjectRef(String)が必要です。"|>]]];
  occ = Lookup[event, "OccurredAtUTC", Missing[]];
  If[! StringQ[occ],
    Return[Failure["CognitionBadEvent", <|"MessageTemplate" -> "OccurredAtUTC が必要です(bitemporal, I-9)。"|>]]];
  period = iCogPeriodOf[occ];
  If[MissingQ[period],
    Return[Failure["CognitionBadEvent", <|"MessageTemplate" -> "OccurredAtUTC は yyyy-mm-.. 形式で指定してください。"|>]]];
  token = iCogSubjectToken[subj];
  keyRef = iCogShardKeyRef[token, period];
  ev = Join[<|"EventId" -> "cogev:" <> iCogULID[], "ObservedAtUTC" -> iCogNowUTC[]|>, event];
  SourceVaultWithLock[iCogLockName[root],
    Module[{},
      idx = iCogReadIndex[root];
      subjRec = Lookup[idx["Subjects"], subj, <|"Token" -> token, "Shards" -> {}|>];
      If[! MemberQ[Lookup[#, "Period", ""] & /@ subjRec["Shards"], period],
        (* 新 shard: 鍵を発行(crypto-shred の単位) *)
        If[! TrueQ[NBAccess`NBKeyMaterialExistsQ[keyRef]],
          NBAccess`NBGenerateSymmetricKeyRef[keyRef, <|"Purpose" -> "SVCognitionShard"|>]];
        subjRec["Shards"] = Append[subjRec["Shards"],
          <|"Period" -> period, "File" -> token <> "-" <> period <> ".cogx",
            "KeyRef" -> keyRef, "CreatedAtUTC" -> iCogNowUTC[]|>];
        idx["Subjects"] = Append[idx["Subjects"], subj -> subjRec];
        iCogWriteIndex[root, idx],
        idx["Subjects"] = Append[idx["Subjects"], subj -> subjRec]];
      shardFile = FileNameJoin[{iCogShardDir[root], token <> "-" <> period <> ".cogx"}];
      enc = NBAccess`NBEncryptWithKeyRef[keyRef, iCogJSON[ev], "SVCognitionEvent"];
      If[! AssociationQ[enc] || Lookup[enc, "Status", ""] =!= "Ok",
        Failure["CognitionEncryptFailed", <|"MessageTemplate" -> "event の暗号化に失敗しました。"|>],
        line = iCogJSON[<|"C" -> enc["CiphertextB64"]|>];
        Module[{strm = OpenAppend[shardFile, BinaryFormat -> True]},
          BinaryWrite[strm, Normal[line]]; BinaryWrite[strm, {10}]; Close[strm]];
        ev]]]];

(* ---- read(復号。shred 済みは復活しない) ---- *)
Options[SourceVaultCognitionEvents] = {"Root" -> Automatic, "Period" -> All};
SourceVaultCognitionEvents[subj_String, OptionsPattern[]] := Module[
  {root, idx, shards, notes = {}, events = {}},
  root = iCogRoot[OptionValue["Root"]];
  If[! StringQ[root] || ! DirectoryQ[iCogShardDir[root]], Return[<|"Events" -> {}, "Notes" -> {"NotInitialized"}|>]];
  idx = iCogReadIndex[root];
  shards = Lookup[Lookup[idx["Subjects"], subj, <||>], "Shards", {}];
  If[OptionValue["Period"] =!= All,
    shards = Select[shards, #["Period"] === OptionValue["Period"] &]];
  Scan[Function[sh,
    Module[{f = FileNameJoin[{iCogShardDir[root], sh["File"]}], lines, dec},
      Which[
        ! FileExistsQ[f], AppendTo[notes, "MissingFile:" <> sh["Period"]],
        ! TrueQ[NBAccess`NBKeyMaterialExistsQ[sh["KeyRef"]]], AppendTo[notes, "Shredded:" <> sh["Period"]],
        True,
        lines = Select[SequenceSplit[BinaryReadList[f, "Byte"], {10}], # =!= {} &];
        Scan[Function[lb,
          Module[{rec = Quiet@Check[ImportByteArray[ByteArray[lb], "RawJSON"], $Failed], pt},
            If[AssociationQ[rec] && KeyExistsQ[rec, "C"],
              pt = NBAccess`NBDecryptWithKeyRef[sh["KeyRef"], rec["C"], "SVCognitionEvent"];
              If[MatchQ[pt, _ByteArray],
                Module[{evd = Quiet@Check[ImportByteArray[pt, "RawJSON"], $Failed]},
                  If[AssociationQ[evd], AppendTo[events, evd]]]]]]],
          lines]]]],
    shards];
  <|"Events" -> SortBy[events, Lookup[#, "OccurredAtUTC", ""] &], "Notes" -> notes|>];

Options[SourceVaultCognitionSubjects] = {"Root" -> Automatic};
SourceVaultCognitionSubjects[OptionsPattern[]] :=
  Keys[Lookup[iCogReadIndex[iCogRoot[OptionValue["Root"]]], "Subjects", <||>]];

(* ---- erase(crypto-shredding。manifest -> 実行 -> 削除後検査 -> metadata 監査) ---- *)
Options[SourceVaultCognitionErase] = {"Root" -> Automatic, "Period" -> All, "DryRun" -> True};
SourceVaultCognitionErase[subjOrAll_, OptionsPattern[]] := Module[
  {root, idx, targets, manifest, executed = False, inspection = Missing["DryRun"], auditLine},
  root = iCogRoot[OptionValue["Root"]];
  If[! StringQ[root], Return[Failure["CognitionRootUnresolved", <||>]]];
  idx = iCogReadIndex[root];
  targets = If[subjOrAll === All, Normal[idx["Subjects"]],
    {subjOrAll -> Lookup[idx["Subjects"], subjOrAll, <|"Token" -> "", "Shards" -> {}|>]}];
  (* 削除 manifest: 全派生物(shard file / KeyRef / index entry)を列挙(r5 P1-02) *)
  manifest = Flatten@Map[Function[kv,
    Module[{subj = kv[[1]], shards = Lookup[kv[[2]], "Shards", {}]},
      If[OptionValue["Period"] =!= All, shards = Select[shards, #["Period"] === OptionValue["Period"] &]];
      Map[<|"SubjectRef" -> subj, "Period" -> #["Period"],
        "File" -> FileNameJoin[{iCogShardDir[root], #["File"]}],
        "KeyRef" -> #["KeyRef"],
        "Bytes" -> If[FileExistsQ[FileNameJoin[{iCogShardDir[root], #["File"]}]],
          FileByteCount[FileNameJoin[{iCogShardDir[root], #["File"]}]], 0]|> &, shards]]],
    targets];
  If[! TrueQ[OptionValue["DryRun"]] && manifest =!= {},
    SourceVaultWithLock[iCogLockName[root],
      Module[{},
        (* 1) crypto-shred: 鍵削除が先(ファイル残骸があっても復号不能に) *)
        Scan[NBAccess`NBDeleteCredentialKey[#["KeyRef"]] &, manifest];
        (* 2) ファイル削除 *)
        Scan[If[FileExistsQ[#["File"]], DeleteFile[#["File"]]] &, manifest];
        (* 3) index 更新 *)
        idx = iCogReadIndex[root];
        Scan[Function[kv,
          Module[{subj = kv[[1]], rec = Lookup[idx["Subjects"], kv[[1]], Missing[]]},
            If[! MissingQ[rec],
              rec["Shards"] = Select[rec["Shards"],
                Function[sh, ! AnyTrue[manifest, #["SubjectRef"] === subj && #["Period"] === sh["Period"] &]]];
              If[rec["Shards"] === {}, idx["Subjects"] = KeyDrop[idx["Subjects"], subj],
                idx["Subjects"] = Append[idx["Subjects"], subj -> rec]]]]],
          targets];
        iCogWriteIndex[root, idx]]];
    executed = True;
    (* 4) 削除後検査(r5 P1-02: manifest 全項目の不存在確認) *)
    inspection = <|
      "FilesGone" -> AllTrue[manifest, ! FileExistsQ[#["File"]] &],
      "KeysGone" -> AllTrue[manifest, ! TrueQ[NBAccess`NBKeyMaterialExistsQ[#["KeyRef"]]] &],
      "ReplayEmpty" -> AllTrue[DeleteDuplicates[#["SubjectRef"] & /@ manifest],
        Function[s, Module[{r = SourceVaultCognitionEvents[s, "Root" -> root,
            "Period" -> OptionValue["Period"]]},
          If[OptionValue["Period"] === All, r["Events"] === {},
            ! MemberQ[iCogPeriodOf /@ Lookup[r["Events"], "OccurredAtUTC", ""], OptionValue["Period"]]]]]]|>;
    inspection["Passed"] = AllTrue[Values[inspection], TrueQ];
    (* 5) metadata のみの監査行(値・subject 平文は含めない) *)
    auditLine = iCogJSON[<|"ErasedAtUTC" -> iCogNowUTC[],
      "SubjectTokens" -> DeleteDuplicates[iCogSubjectToken[#["SubjectRef"]] & /@ manifest],
      "ShardCount" -> Length[manifest], "Bytes" -> Total[Lookup[manifest, "Bytes", 0]],
      "InspectionPassed" -> inspection["Passed"]|>];
    Module[{strm = OpenAppend[iCogAuditPath[root], BinaryFormat -> True]},
      BinaryWrite[strm, Normal[auditLine]]; BinaryWrite[strm, {10}]; Close[strm]]];
  <|"Manifest" -> manifest, "Executed" -> executed, "Inspection" -> inspection,
    "BestEffortNote" -> "OS レベルの複製(crash dump/swap/過去の手動コピー)は消去対象外(best-effort 限界。README 参照)。"|>];

(* ---- retention(I-3b) ---- *)
Options[SourceVaultCognitionPruneExpired] = {"Root" -> Automatic, "DryRun" -> True};
SourceVaultCognitionPruneExpired[OptionsPattern[]] := Module[
  {root, idx, cutoff, expired, results = {}},
  root = iCogRoot[OptionValue["Root"]];
  If[! StringQ[root], Return[Failure["CognitionRootUnresolved", <||>]]];
  cutoff = DateString[DatePlus[Now, -SourceVault`$SourceVaultCognitionRetentionDays],
    {"Year", "-", "Month"}];
  idx = iCogReadIndex[root];
  expired = Flatten[KeyValueMap[Function[{subj, rec},
    Map[{subj, #["Period"]} &,
      Select[Lookup[rec, "Shards", {}], Order[#["Period"], cutoff] === 1 &]]],  (* Period < cutoff *)
    Lookup[idx, "Subjects", <||>]], 1];  (* level 1: {subj, period} ペアを保つ *)
  Scan[Function[pair,
    AppendTo[results, SourceVaultCognitionErase[pair[[1]], "Root" -> root,
      "Period" -> pair[[2]], "DryRun" -> OptionValue["DryRun"]]]],
    expired];
  <|"Cutoff" -> cutoff, "ExpiredShards" -> Length[expired], "Results" -> results|>];

(* ============================================================
   Phase 1D: OperationalSupportSignal v0(観測専用 shadow)
   決定的・LLM 不使用。入力は Claude Code digest のみ(返信遅延/締切は使わない=循環回避 P0-04)。
   出力は SensitiveLocalVault のみ。下流(prompt/action/authorization)へ接続しない(I-12/I-13)。
   ============================================================ *)

If[! IntegerQ[SourceVault`$SourceVaultCognitionMinBaselineDays],
  SourceVault`$SourceVaultCognitionMinBaselineDays = 14];

$svCogSignalMethod = "opsig-v0";
$svCogISOFmt = {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second"};

(* UTC ISO -> {localDay "yyyy-mm-dd", localHour, weekday}。offset 演算は同一 $TimeZone 解釈内で厳密。
   非 String(旧スキーマの Null 等)は Missing(未評価で Part されると Day->Null 汚染行になるため
   catch-all 必須。result7.nb で実データ検出)。 *)
iCogLocalDayHour[utc_String, offH_] := Module[{s, dl, la, ldl},
  s = StringDelete[utc, "Z"];
  s = StringReplace[s, "." ~~ DigitCharacter .. -> ""];  (* 実 digest はミリ秒付き ISO(result7 実データ) *)
  dl = Quiet@Check[DateList[{s, $svCogISOFmt}], $Failed];
  If[dl === $Failed, Return[Missing["BadTime"]]];
  la = AbsoluteTime[dl] + offH*3600;
  ldl = DateList[la];
  {DateString[ldl, {"Year", "-", "Month", "-", "Day"}], ldl[[4]],
   DateString[ldl, {"DayName"}]}];
iCogLocalDayHour[_, _] := Missing["BadTime"];

(* digest の活動 timestamp: StartedAtUTC -> LastAtUTC。DigestAtUTC(=ingest 時刻)は使わない
   (活動履歴が ingest 日に潰れるため)。両方 Null/欠落の digest は skip。 *)
iCogDigestTime[d_Association] := SelectFirst[
  {Lookup[d, "StartedAtUTC", Missing[]], Lookup[d, "LastAtUTC", Missing[]]},
  StringQ, Missing["NoTime"]];

iCogSimilarity[a_String, b_String] := Module[{m = Max[StringLength[a], StringLength[b]]},
  If[m === 0, 0., 1. - EditDistance[a, b]/m]];

(* 1 セッションの「やり直し proxy」: 連続 user preview の高類似ペア率 *)
iCogRetryPairs[previews_List] := Module[{ps, pairs},
  ps = Select[Cases[previews, _String], StringLength[#] >= 8 &];
  If[Length[ps] < 2, Return[{0, 0}]];
  pairs = Partition[ps, 2, 1];
  {Count[pairs, p_ /; iCogSimilarity[p[[1]], p[[2]]] > 0.6], Length[pairs]}];

(* digests -> 日次特徴(local day 毎)。決定的 *)
iCogDailyFeatures[digests_List, offH_] := Module[{rows},
  rows = DeleteCases[Map[Function[d,
    Module[{dh = iCogLocalDayHour[iCogDigestTime[d], offH], rp},
      If[MissingQ[dh], Nothing,
        rp = iCogRetryPairs[Lookup[d, "UserPreviews", {}]];
        <|"Day" -> dh[[1]], "Hour" -> dh[[2]], "Weekday" -> dh[[3]],
          "UserMessages" -> Lookup[d, "UserMessageCount", 0],
          "RetryHits" -> rp[[1]], "RetryPairs" -> rp[[2]]|>]]],
    digests], Nothing];
  Association@Map[Function[grp,
    grp[[1, "Day"]] -> <|
      "Sessions" -> Length[grp],
      "UserMessages" -> Total[Lookup[grp, "UserMessages", 0]],
      "LateHourRate" -> N[Count[grp, r_ /; r["Hour"] < 6]/Length[grp]],
      "RetrySimilarityRate" -> Module[{h = Total[Lookup[grp, "RetryHits", 0]],
          p = Total[Lookup[grp, "RetryPairs", 0]]}, If[p === 0, 0., N[h/p]]],
      "Weekday" -> grp[[1, "Weekday"]]|>],
    GatherBy[rows, #["Day"] &]]];

iCogRobustZ[x_, vals_List] := Module[{med, mad},
  If[Length[vals] < 2, Return[0.]];
  med = Median[vals]; mad = Median[Abs[vals - med]];
  Clip[(x - med)/(1.4826*mad + 0.05), {-4., 4.}]];

(* 偏差スコア: 深夜率/やり直し率は「悪化方向のみ」、量は絶対偏差(重み 0.5) *)
iCogDeviationScore[f_Association, baseline_Association] := Module[{zLate, zRetry, zVol},
  zLate = Max[0., iCogRobustZ[f["LateHourRate"], baseline["LateHourRate"]]];
  zRetry = Max[0., iCogRobustZ[f["RetrySimilarityRate"], baseline["RetrySimilarityRate"]]];
  zVol = Abs[iCogRobustZ[f["UserMessages"], baseline["UserMessages"]]];
  Round[Mean[{zLate, zRetry, 0.5*zVol}], 0.001]];

iCogTierOf[score_?NumberQ] := Which[score < 0.8, "Low", score < 1.6, "Medium", True, "High"];

Options[SourceVaultOperationalSignalEstimate] = {"Digests" -> Automatic, "Subject" -> "ent-owner",
  "WindowDays" -> 30, "TimeZoneOffsetHours" -> 9, "Persist" -> True, "Root" -> Automatic};
SourceVaultOperationalSignalEstimate[OptionsPattern[]] := Module[
  {digests, subj, offH, daily, days, todayLocal, existing, existingDates, results = {}, persisted = {},
   baselineOf, minDays = SourceVault`$SourceVaultCognitionMinBaselineDays},
  digests = OptionValue["Digests"] /. Automatic :>
    Quiet@Check[SourceVault`SourceVaultClaudeCodeSessions[], {}];
  If[! ListQ[digests], digests = {}];
  subj = OptionValue["Subject"]; offH = OptionValue["TimeZoneOffsetHours"];
  daily = iCogDailyFeatures[digests, offH];
  days = Sort[Keys[daily]];
  If[Length[days] > OptionValue["WindowDays"] + minDays,
    days = Take[days, -(OptionValue["WindowDays"] + minDays)]];
  todayLocal = First[iCogLocalDayHour[iCogNowUTC[], offH]];
  (* 冪等: 既存 sample 日はスキップ *)
  existing = If[TrueQ[OptionValue["Persist"]],
    Select[SourceVaultCognitionEvents[subj, "Root" -> OptionValue["Root"]]["Events"],
      Lookup[#, "EventClass", ""] === "OperationalSignalSampled" &], {}];
  existingDates = If[existing === {}, {},
    DeleteDuplicates[DeleteCases[Lookup[existing, "SignalDate", Nothing], Nothing]]];
  baselineOf = Function[day,
    Module[{prior = Select[days, Order[#, day] === 1 &]},
      If[Length[prior] < minDays, Missing["InsufficientBaseline"],
        Association@Map[# -> Lookup[Lookup[daily, prior], #, 0] &,
          {"LateHourRate", "RetrySimilarityRate", "UserMessages"}]]]];
  Scan[Function[day,
    Module[{f = daily[day], bl = baselineOf[day], score, tier, sample},
      If[MissingQ[bl],
        score = Missing["InsufficientBaseline"]; tier = Missing["InsufficientBaseline"],
        score = iCogDeviationScore[f, bl]; tier = iCogTierOf[score]];
      sample = <|"Day" -> day, "Features" -> KeyDrop[f, "Weekday"],
        "Covariates" -> <|"Weekday" -> f["Weekday"]|>,
        "DeviationScore" -> score, "SupportNeedTier" -> tier,
        "Partial" -> (day === todayLocal)|>;
      AppendTo[results, sample];
      (* 当日は partial のため永続しない。既存日もスキップ(冪等) *)
      If[TrueQ[OptionValue["Persist"]] && day =!= todayLocal && ! MemberQ[existingDates, day] &&
          ! MissingQ[bl],
        Module[{ev = SourceVaultCognitionAppendEvent[<|
            "EventClass" -> "OperationalSignalSampled", "SubjectRef" -> subj,
            "OccurredAtUTC" -> day <> "T00:00:00Z", "SignalDate" -> day,
            "Features" -> KeyDrop[f, "Weekday"], "Covariates" -> <|"Weekday" -> f["Weekday"]|>,
            "DeviationScore" -> score, "SupportNeedTier" -> tier,
            "Method" -> $svCogSignalMethod, "BaselineDays" -> Length[Select[days, Order[#, day] === 1 &]],
            "ShadowOnly" -> True|>, "Root" -> OptionValue["Root"]]},
          If[AssociationQ[ev], AppendTo[persisted, day]]]]]],
    days];
  <|"Days" -> results, "PersistedDates" -> persisted,
    "MinBaselineDays" -> minDays, "Method" -> $svCogSignalMethod,
    "Status" -> If[digests === {}, "NoDigests", "OK"]|>];

Options[SourceVaultHumanSupportProfile] = {"WindowDays" -> 90, "Root" -> Automatic};
SourceVaultHumanSupportProfile[subj_String, OptionsPattern[]] := Module[
  {evs, sigs, reports, latest, est},
  evs = SourceVaultCognitionEvents[subj, "Root" -> OptionValue["Root"]]["Events"];
  sigs = Select[evs, Lookup[#, "EventClass", ""] === "OperationalSignalSampled" &];
  reports = Select[evs, Lookup[#, "EventClass", ""] === "CognitiveSelfReported" &];
  latest = If[sigs === {}, Missing["NoSignals"], Last[SortBy[sigs, Lookup[#, "SignalDate", ""] &]]];
  est = Which[
    MissingQ[latest], Missing["NoSignals"],
    ! StringQ[Lookup[latest, "SupportNeedTier", Missing[]]], Missing["InsufficientBaseline"],
    True, <|"SupportNeedTier" -> latest["SupportNeedTier"], "Confidence" -> "Low",
      "AsOfDate" -> Lookup[latest, "SignalDate", ""]|>];
  <|"SubjectRef" -> subj,
    "ObservableSignalsLatest" -> If[MissingQ[latest], Missing[], Lookup[latest, "Features", <||>]],
    "SupportNeedEstimate" -> est,
    "SelfReports" -> Length[reports], "SignalSamples" -> Length[sigs],
    "Window" -> OptionValue["WindowDays"], "BaselineVersion" -> $svCogSignalMethod,
    "ShadowOnly" -> True|>];  (* 下流接続禁止(I-12/I-13)。表示は local のみ *)

Options[SourceVaultRecordCognitiveSelfReport] = {"Subject" -> "ent-owner",
  "OccurredAtUTC" -> Automatic, "Note" -> "", "Root" -> Automatic};
SourceVaultRecordCognitiveSelfReport[score_Integer /; 1 <= score <= 5, OptionsPattern[]] :=
  SourceVaultCognitionAppendEvent[<|"EventClass" -> "CognitiveSelfReported",
    "SubjectRef" -> OptionValue["Subject"],
    "OccurredAtUTC" -> (OptionValue["OccurredAtUTC"] /. Automatic :> iCogNowUTC[]),
    "Score" -> score, "Note" -> OptionValue["Note"]|>, "Root" -> OptionValue["Root"]];

Options[SourceVaultCognitionCompareView] = {"Subject" -> "ent-owner", "WindowDays" -> 30,
  "Root" -> Automatic};
SourceVaultCognitionCompareView[OptionsPattern[]] := Module[
  {evs, sigs, reports, byDay},
  evs = SourceVaultCognitionEvents[OptionValue["Subject"], "Root" -> OptionValue["Root"]]["Events"];
  sigs = Select[evs, Lookup[#, "EventClass", ""] === "OperationalSignalSampled" &];
  reports = Select[evs, Lookup[#, "EventClass", ""] === "CognitiveSelfReported" &];
  byDay = Association@Map[Function[r,
    StringTake[ToString@Lookup[r, "OccurredAtUTC", ""], UpTo[10]] -> Lookup[r, "Score", Missing[]]],
    reports];
  Dataset[Map[Function[s,
    <|"Date" -> Lookup[s, "SignalDate", ""],
      "DeviationScore" -> Lookup[s, "DeviationScore", Missing[]],
      "SupportNeedTier" -> Lookup[s, "SupportNeedTier", Missing[]],
      "SelfReport" -> Lookup[byDay, Lookup[s, "SignalDate", ""], Missing[]]|>],
    Take[SortBy[sigs, Lookup[#, "SignalDate", ""] &], -Min[OptionValue["WindowDays"], Length[sigs]]]]]];

(* ============================================================
   Phase 1E(第一増分): action risk taxonomy + Guard shadow
   決定的。認知系入力なし(1D 昇格前)。enforce しない(記録のみ)。
   ============================================================ *)

SourceVaultActionRiskClassify[spec_Association] := Module[
  {rev, reach, gap, domains, reasons = {}, level},
  rev = Lookup[spec, "Reversibility", "Undoable"];
  reach = Lookup[spec, "Reach", "Self"];
  gap = Lookup[spec, "SensitivityGap", 0.];
  domains = Lookup[spec, "ImpactDomains", {}];
  If[rev === "Irreversible", AppendTo[reasons, "Irreversible"]];
  If[MemberQ[{"Organization", "Public"}, reach], AppendTo[reasons, "WideReach:" <> reach]];
  If[gap > 0., AppendTo[reasons, "PrivacyDowngrade"]];  (* content PL > 宛先許可 = privacy 降下 *)
  If[domains =!= {}, AppendTo[reasons, "Impact:" <> StringRiffle[ToString /@ domains, ","]]];
  level = Which[
    (* High: 不可逆×(広い到達 or privacy 降下 or 重大領域) *)
    rev === "Irreversible" && (MemberQ[{"Organization", "Public"}, reach] || gap > 0. || domains =!= {}), "High",
    gap > 0. || rev === "Irreversible" || MemberQ[{"Organization", "Public"}, reach] || domains =!= {}, "Medium",
    True, "Low"];
  <|"RiskLevel" -> level, "Taxonomy" -> KeyTake[spec,
      {"ActionKind", "Reversibility", "Reach", "SensitivityGap", "ImpactDomains",
       "TimeConstraint", "RecipientCount"}],
    "ReasonCodes" -> reasons|>];

Options[SourceVaultGuardEvaluate] = {"Persist" -> True};
SourceVaultGuardEvaluate[spec_Association, OptionsPattern[]] := Module[
  {cls, decision, out},
  cls = SourceVaultActionRiskClassify[spec];
  decision = Switch[cls["RiskLevel"],
    "High", "TimedDefer",     (* 推奨のみ。期限+即時override+緊急経路は enforcement 実装(昇格後)の契約 *)
    "Medium", "Confirm",
    _, "Standard"];
  out = <|"Decision" -> decision, "RiskLevel" -> cls["RiskLevel"],
    "ReasonCodes" -> cls["ReasonCodes"], "ShadowMode" -> True|>;
  If[TrueQ[OptionValue["Persist"]],
    (* 内容最小化: action の本文・宛先・認知数値は含めない(I-3b) *)
    Quiet@Check[SourceVaultAppendEvent[<|"EventClass" -> "GuardDecisionRecorded",
      "ActionKind" -> Lookup[spec, "ActionKind", "Unknown"],
      "RiskLevel" -> cls["RiskLevel"], "Decision" -> decision,
      "ReasonCodes" -> cls["ReasonCodes"], "ShadowMode" -> True,
      "PolicyVersion" -> "guard-shadow-v0"|>], Null]];
  out];

(* ============================================================
   Phase 1E(第二増分): Commitment 最小 + shadow 並走記録
   Commitment は認知推定の入力に使わない(P0-04 循環回避)。通常 event store(内容最小・本文なし)。
   ============================================================ *)

SourceVaultCommitmentObserve[spec_Association] := Module[{ev},
  ev = Join[<|"CommitmentId" -> "svcommit:" <> iCogULID[], "Status" -> "Open",
    "ObservedAtUTC" -> iCogNowUTC[]|>, KeyTake[spec,
    {"Kind", "SourceRefs", "Deadline", "ReminderAt", "PreparationLeadTime",
     "GracePeriod", "DetectionBasis", "Title"}]];
  Quiet@Check[SourceVaultAppendEvent[Append[ev, "EventClass" -> "CommitmentObserved"]], Null];
  ev];

Options[SourceVaultCommitmentSetStatus] = {"OwnerCorrection" -> Missing[], "FalseAlarm" -> False};
SourceVaultCommitmentSetStatus[cid_String, status_String, OptionsPattern[]] := Module[{ev},
  ev = <|"EventClass" -> "CommitmentStatusChanged", "CommitmentId" -> cid,
    "Status" -> status, "OwnerCorrection" -> OptionValue["OwnerCorrection"],
    "FalseAlarm" -> TrueQ[OptionValue["FalseAlarm"]], "ChangedAtUTC" -> iCogNowUTC[]|>;
  Quiet@Check[SourceVaultAppendEvent[ev], Null];
  ev];

Options[SourceVaultCommitments] = {"Status" -> All, "Limit" -> 200};
SourceVaultCommitments[OptionsPattern[]] := Module[{evs, base, changes, merged},
  evs = Quiet@Check[SourceVaultTransactionLog["Limit" -> 5000], {}];
  If[! ListQ[evs], evs = {}];
  base = Association@Map[(#["CommitmentId"] -> #) &,
    Select[evs, Lookup[#, "EventClass", ""] === "CommitmentObserved" &]];
  changes = Select[evs, Lookup[#, "EventClass", ""] === "CommitmentStatusChanged" &];
  (* TransactionLog は新しい順 → 逆順で適用し最新状態に *)
  Scan[Function[ch, Module[{cid = Lookup[ch, "CommitmentId", ""]},
    If[KeyExistsQ[base, cid],
      base[cid] = Join[base[cid], KeyTake[ch, {"Status", "OwnerCorrection", "FalseAlarm"}]]]]],
    Reverse[changes]];
  merged = Values[base];
  If[OptionValue["Status"] =!= All,
    merged = Select[merged, Lookup[#, "Status", ""] === OptionValue["Status"] &]];
  Take[merged, UpTo[OptionValue["Limit"]]]];

Options[SourceVaultGuardRecordParallel] = {"Persist" -> True};
SourceVaultGuardRecordParallel[gateResult_, actionSpec_Association, OptionsPattern[]] := Module[
  {shadow, gateDec, out},
  shadow = SourceVaultGuardEvaluate[actionSpec, "Persist" -> False];
  gateDec = Which[
    AssociationQ[gateResult], ToString@Lookup[gateResult, "Decision", "Unknown"],
    StringQ[gateResult], gateResult, True, ToString[gateResult]];
  out = <|"GateDecision" -> gateDec, "ShadowDecision" -> shadow["Decision"],
    "RiskLevel" -> shadow["RiskLevel"],
    "Agreement" -> ((gateDec === "Permit" && shadow["Decision"] === "Standard") ||
      (gateDec === "Deny" && shadow["Decision"] =!= "Standard"))|>;
  If[TrueQ[OptionValue["Persist"]],
    Quiet@Check[SourceVaultAppendEvent[<|"EventClass" -> "GuardParallelRecorded",
      "ActionKind" -> Lookup[actionSpec, "ActionKind", "Unknown"],
      "GateDecision" -> gateDec, "ShadowDecision" -> shadow["Decision"],
      "RiskLevel" -> shadow["RiskLevel"], "ReasonCodes" -> shadow["ReasonCodes"],
      "ShadowMode" -> True, "PolicyVersion" -> "guard-shadow-v0"|>], Null]];
  out];

Options[SourceVaultGuardShadowStats] = {"Limit" -> 2000};
SourceVaultGuardShadowStats[OptionsPattern[]] := Module[{evs, shadowEvs, parEvs, mailEvs},
  evs = Quiet@Check[SourceVaultTransactionLog["Limit" -> OptionValue["Limit"]], {}];
  If[! ListQ[evs], evs = {}];
  shadowEvs = Select[evs, Lookup[#, "EventClass", ""] === "GuardDecisionRecorded" &];
  parEvs = Select[evs, Lookup[#, "EventClass", ""] === "GuardParallelRecorded" &];
  mailEvs = Select[evs, Lookup[#, "EventClass", ""] === "GuardMailParallelRecorded" &];
  <|"ShadowCount" -> Length[shadowEvs],
    "DecisionByAction" -> If[shadowEvs === {}, <||>,
      GroupBy[shadowEvs, Lookup[#, "ActionKind", "?"] &,
        Tally[Lookup[#, "Decision", "?"] & /@ #] &]],
    "ParallelCount" -> Length[parEvs],
    "ParallelAgreementRate" -> If[parEvs === {}, Missing["NoData"],
      N[Count[parEvs, e_ /; (Lookup[e, "GateDecision", ""] === "Permit" &&
            Lookup[e, "ShadowDecision", ""] === "Standard") ||
          (Lookup[e, "GateDecision", ""] === "Deny" &&
            Lookup[e, "ShadowDecision", ""] =!= "Standard")]/Length[parEvs]]],
    "ParallelDisagreements" -> If[parEvs === {}, {},
      Take[Select[parEvs, ! ((Lookup[#, "GateDecision", ""] === "Permit" &&
            Lookup[#, "ShadowDecision", ""] === "Standard") ||
          (Lookup[#, "GateDecision", ""] === "Deny" &&
            Lookup[#, "ShadowDecision", ""] =!= "Standard")) &], UpTo[20]]],
    (* mail release parallel(caution alignment): gate は常に確認要、shadow が Standard=非慎重なら不一致 *)
    "MailParallelCount" -> Length[mailEvs],
    "MailAlignmentRate" -> If[mailEvs === {}, Missing["NoData"],
      N[Count[mailEvs, e_ /; TrueQ[Lookup[e, "Aligned", False]]]/Length[mailEvs]]],
    "MailMisaligned" -> If[mailEvs === {}, {},
      Take[Select[mailEvs, ! TrueQ[Lookup[#, "Aligned", False]] &], UpTo[20]]]|>];

(* ---- 実送信経路への shadow 並走結線(1E 結線。既存 gate は不変・enforce しない) ---- *)
(* release plan と spec から action risk taxonomy を導く *)
iGuardActionFromRelease[spec_Association, plan_Association] := Module[{recips, redacted, capsules, reach, gap},
  recips = Lookup[spec, "Recipients", {}];
  redacted = Lookup[plan, "RedactedMaterials", {}];
  capsules = Lookup[plan, "EncryptedCapsules", {}];
  (* list-like 宛先(ml/announce 等)があれば Organization、それ以外は KnownRecipients *)
  reach = If[AnyTrue[recips, StringQ[#] && StringContainsQ[#,
      RegularExpression["(?i)(^|[._\\-])(ml|mailing|list|announce|all|team|staff)([._\\-]|@)"]] &],
    "Organization", "KnownRecipients"];
  (* redaction/capsule 発生 = content PL が宛先許可を超えた=privacy 降下の緊張が表面化 *)
  gap = If[redacted =!= {} || (capsules =!= {} && AnyTrue[capsules, Lookup[#, "Materials", {}] =!= {} &]), 0.3, 0.];
  <|"ActionKind" -> "MailSend", "Reversibility" -> "Irreversible", "Reach" -> reach,
    "SensitivityGap" -> gap, "ImpactDomains" -> {}, "RecipientCount" -> Length[recips]|>];

Options[SourceVaultPlanMessageReleaseWithGuardShadow] = {"Persist" -> True};
SourceVaultPlanMessageReleaseWithGuardShadow[spec_Association, OptionsPattern[]] := Module[
  {plan, actionSpec, shadow, gateCautious, shadowCautious, aligned},
  plan = SourceVaultPlanMessageRelease[spec];   (* 正準ゲート。一切変更しない *)
  If[! AssociationQ[plan], Return[plan]];
  actionSpec = iGuardActionFromRelease[spec, plan];
  shadow = SourceVaultGuardEvaluate[actionSpec, "Persist" -> False];
  (* ゲートは常に DraftOnly/AutoSend False=慎重。shadow が Standard(非慎重)なら不一致=要注目 *)
  gateCautious = (! TrueQ[Lookup[Lookup[plan, "Audit", <||>], "AutoSendAllowed", False]]) ||
    Lookup[plan, "RedactedMaterials", {}] =!= {};
  shadowCautious = shadow["Decision"] =!= "Standard";
  aligned = (gateCautious === shadowCautious);
  If[TrueQ[OptionValue["Persist"]],
    Quiet@Check[SourceVaultAppendEvent[<|"EventClass" -> "GuardMailParallelRecorded",
      "GateDecision" -> Lookup[plan, "Decision", "?"],
      "GateAutoSend" -> Lookup[Lookup[plan, "Audit", <||>], "AutoSendAllowed", False],
      "GateRedactedCount" -> Length[Lookup[plan, "RedactedMaterials", {}]],
      "ShadowDecision" -> shadow["Decision"], "RiskLevel" -> shadow["RiskLevel"],
      "Reach" -> actionSpec["Reach"], "RecipientCount" -> actionSpec["RecipientCount"],
      "Aligned" -> aligned, "ShadowMode" -> True, "PolicyVersion" -> "guard-shadow-v0"|>], Null]];
  (* 既存 plan に additive にだけ付与(既存 caller は無影響) *)
  Append[plan, "GuardShadow" -> <|"Decision" -> shadow["Decision"], "RiskLevel" -> shadow["RiskLevel"],
    "ReasonCodes" -> shadow["ReasonCodes"], "Aligned" -> aligned, "ShadowMode" -> True|>]];

(* ============================================================
   Phase 1G: owner 入力支援(決定的コア。LLM 不使用)
   I-12: SupportNeedTier を入力に使わない/authorization は広がらない/original 不変。
   I-13: ModelFacingPolicy に支援状態・理由を含めない。
   ============================================================ *)

$svAsstIrreversibleWords = {"送信", "送って", "メールして", "send ", "公開", "publish",
  "削除", "delete", "支払", "pay ", "デプロイ", "deploy"};
$svAsstDemonstratives = {"あれ", "それを", "例の", "いつもの", "that thing", "the usual", "those ones"};

iAsstSegments[input_String] := Module[{blocks},
  blocks = Select[StringTrim /@ StringSplit[StringReplace[input, "\r" -> "\n"],
    RegularExpression["\\n[ \\t]*\\n+"]], # =!= "" &];
  Map[Function[b,
    <|"Text" -> b, "Role" -> If[
      StringStartsQ[b, ">"] || StringContainsQ[b, "-*- Quote"] ||
        StringContainsQ[b, RegularExpression["(?m)^(From|Subject|To|Date):"]] ||
        StringMatchQ[b, RegularExpression["https?://\\S+"]],
      "QuotedData", "OwnerInstruction"]|>], blocks]];

SourceVaultOwnerInputRiskAssess[input_String] := Module[
  {segs, instr, signals = {}, irrevQ, risk},
  segs = iAsstSegments[input];
  instr = StringRiffle[Lookup[Select[segs, #["Role"] === "OwnerInstruction" &], "Text", {}], "\n"];
  irrevQ = AnyTrue[$svAsstIrreversibleWords, StringContainsQ[instr, #, IgnoreCase -> True] &];
  If[AnyTrue[$svAsstDemonstratives, StringContainsQ[instr, #, IgnoreCase -> True] &],
    AppendTo[signals, "AmbiguousReferent"]];
  If[irrevQ && ! StringContainsQ[instr, "@"] &&
      StringContainsQ[instr, RegularExpression["送信|送って|メールして|send "], IgnoreCase -> True],
    AppendTo[signals, "RecipientUnspecified"]];
  If[irrevQ && AnyTrue[segs, #["Role"] === "QuotedData" &],
    AppendTo[signals, "PotentialQuotedDataRelease"]];  (* 貼付 data を外へ出す可能性 *)
  If[irrevQ, AppendTo[signals, "IrreversibleActionRequested"]];
  risk = Which[
    Length[DeleteCases[signals, "IrreversibleActionRequested"]] >= 2, "High",
    Length[DeleteCases[signals, "IrreversibleActionRequested"]] >= 1, "Medium",
    True, "Low"];
  <|"InputSegments" -> segs, "Signals" -> signals,
    "PromptInterpretationRisk" -> risk, "IrreversibleActionRequested" -> irrevQ,
    "OriginalPromptDigest" -> IntegerString[Hash[input], 36]|>];

iAsstQuestion[signals_List] := Which[
  MemberQ[signals, "RecipientUnspecified"],
    "確認(1問): 宛先が未指定です。A: 下書きのまま保存 / B: 宛先を指定して続行 — どちらにしますか。",
  MemberQ[signals, "AmbiguousReferent"],
    "確認(1問): 対象(『あれ/例の…』)が特定できません。A: 直近の作業対象 / B: 別途指定 — どちらですか。",
  MemberQ[signals, "PotentialQuotedDataRelease"],
    "確認(1問): 貼付内容を外部へ送る可能性があります。A: 送らず要約のみ / B: 送信を続行 — どちらですか。",
  True, Missing["NoQuestion"]];

Options[SourceVaultAssistOwnerInput] = {"Persist" -> True, "Root" -> Automatic,
  "Subject" -> "ent-owner"};
SourceVaultAssistOwnerInput[input_String, OptionsPattern[]] := Module[
  {assess, mode, q, caseId, ev},
  assess = SourceVaultOwnerInputRiskAssess[input];
  mode = Which[
    assess["IrreversibleActionRequested"] && assess["PromptInterpretationRisk"] === "High", "DraftOnly",
    assess["IrreversibleActionRequested"], "ConfirmBeforeCommit",  (* 不可逆は常に owner 確認(I-12) *)
    assess["PromptInterpretationRisk"] =!= "Low", "ReviewEnhanced",
    True, "Normal"];
  q = If[mode === "Normal", Missing["NoQuestion"], iAsstQuestion[assess["Signals"]]];
  caseId = "svassist:" <> iCogULID[];
  ev = <|"EventClass" -> "OwnerInputAssistanceCase", "SubjectRef" -> OptionValue["Subject"],
    "OccurredAtUTC" -> iCogNowUTC[], "AssistanceCaseId" -> caseId,
    "OriginalInput" -> input,  (* immutable(I-12)。SensitiveLocalVault のみ *)
    "InputRiskAssessment" -> KeyDrop[assess, "InputSegments"],
    "AssistanceMode" -> mode, "ClarificationQuestion" -> q|>;
  If[TrueQ[OptionValue["Persist"]],
    Quiet@Check[SourceVaultCognitionAppendEvent[ev, "Root" -> OptionValue["Root"]], Null]];
  <|"AssistanceCaseId" -> caseId, "AssistanceMode" -> mode,
    "ClarificationQuestion" -> q, "Assessment" -> assess,
    (* I-13: LLM/実行系に渡してよいのは mode 指示のみ。理由・signal・支援状態は含めない *)
    "ModelFacingPolicy" -> <|"Mode" -> mode,
      "CommitRequiresOwnerConfirm" -> assess["IrreversibleActionRequested"]|>|>];

Options[SourceVaultAssistanceRecordOutcome] = {"Root" -> Automatic, "Subject" -> "ent-owner"};
SourceVaultAssistanceRecordOutcome[caseId_String, outcome_Association, OptionsPattern[]] :=
  SourceVaultCognitionAppendEvent[<|"EventClass" -> "OwnerInputAssistanceOutcome",
    "SubjectRef" -> OptionValue["Subject"], "OccurredAtUTC" -> iCogNowUTC[],
    "AssistanceCaseId" -> caseId,
    "ChosenIntentRef" -> Lookup[outcome, "ChosenIntentRef", Missing[]],
    "OwnerCorrection" -> Lookup[outcome, "OwnerCorrection", Missing[]],
    "IntentPreserved" -> Lookup[outcome, "IntentPreserved", Missing[]]|>,
    "Root" -> OptionValue["Root"]];

End[];

EndPackage[];
