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
        If[MissingQ[NBAccess`NBKeyStatus[keyRef]],
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
        MissingQ[NBAccess`NBKeyStatus[sh["KeyRef"]]], AppendTo[notes, "Shredded:" <> sh["Period"]],
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
      "KeysGone" -> AllTrue[manifest, MissingQ[NBAccess`NBKeyStatus[#["KeyRef"]]] &],
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

End[];

EndPackage[];
