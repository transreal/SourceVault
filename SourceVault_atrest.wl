(* ::Package:: *)

(* ============================================================
   SourceVault_atrest.wl -- 保存時の暗号化 (学生・成績などを段 1 / 段 2 に分けて暗号化する)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_atrest.wl"]]
   (前提: NBAccess_crypto.wl・SourceVault_crypto.wl・SourceVault_core.wl が読み込み済み)

   計画: ~/.claude/plans/dynamic-splashing-island.md (2026-11-14 所有者が承認)
   文書: ドキュメント/LLM防御サーベイとリスク評価_20261108/13_YubiKeyによる所有者認証と鍵保護_サーベイと移行案_20261113.md

   段 (Tier)
     1 = PL >= 0.95       : 多要素認証必須。今は鍵を SystemCredential に暫定で置き、svfido の PRF ができたら
                            鍵だけ包み直して SystemCredential から消す (データは暗号化し直さない)。
     2 = AL < PL < 0.95   : SystemCredential の鍵で暗号化 (AL = 保管先の AccessLevel)。
     3 = PL <= AL         : 平文でよい。
   鍵
     鍵の組 (KeyGroup) ごとに enc (AES-256-CBC) と mac (HMAC-SHA256)。KeyRef は
     "SourceVault:dek:v1:<group>:enc" / ":mac"。作るのは 1 度だけ (NBStoreCredentialKey の CreateOnly)。
     台帳 svkeyring.json (PrivateVault/keyring と LocalState/keyring の 2 か所、世代つき、MAC つき) に
     受取人 (OSCredential = 機ごとの鍵ストア / Recovery = 紙の回復 / 後で PRF) と鍵の指紋を記録する。
   紙の回復 (SVR1)
     回復の秘密 R (32 バイト、暗号用の乱数) を Crockford Base32 の 4 行 + 検査文字 + CHK + QR で印刷する。
     R から包む鍵と MAC 鍵を導き、回復の RSA-3072 の秘密鍵を包んで台帳に置く。分類の鍵と台帳の MAC 鍵は
     回復の公開鍵 (OAEP) で包むので、R が手元に無くても新しい鍵を回復の受取人に足せる。
     R はファイルに書かず、戻り値にも出さない (保存しない FE の窓に出して印刷するだけ)。
   形式 SVEF v1 (ファイルの暗号化)
     "SVEF" 01 00 | uint32 hlen | header (正準 JSON) | uint32 clen | ciphertext | HMAC-SHA256 (32 バイト)
     MAC = HMAC(mac 鍵, 前置き 10 バイト ‖ header ‖ uint32 clen ‖ SHA256(ciphertext))
     header に平文のハッシュや学生の情報を入れない。LogicalPath (保管先の根からの相対パス) を MAC で縛る。
     中身は元のバイト列そのまま (往復でバイト一致)。暗号化したファイルの名前は「元の名前 + .sve」。
   読み手の規則
     .sve があれば優先し、検証に失敗したら Failure (黙って平文に戻らない)。平文だけなら平文を読む
     (LegacyPlaintext を数える)。両方あり平文の方が新しければ SplitBrain の Failure。
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

$SourceVaultClassPrivacyRegistry::usage =
  "$SourceVaultClassPrivacyRegistry は分類 (snapshot の class 名や保管場所の名前) → <|PL, Provenance, KeyGroup, Category, DecidedAt, DecidedBy|> の表。2026-11-14 に所有者が決めた学生・成績の 4 分類 (段 1) と匿名化済み・派生 (段 2)。";
$SourceVaultKeyGroups::usage =
  "$SourceVaultKeyGroups は鍵の組 → <|Tier, Category|>。鍵の組ごとに enc と mac の鍵を 1 組持つ。";
$SourceVaultStoreAccessLevels::usage =
  "$SourceVaultStoreAccessLevels は保管先の AccessLevel の上書き。Automatic (既定) なら PrivateVault・webreports = 0.5、LocalState = 0.94 を根から求める。上書きするときは {<|\"Store\", \"Root\", \"AccessLevel\"|>..}。";
$SourceVaultAtRestEnforce::usage =
  "$SourceVaultAtRestEnforce は暗号化を強制する鍵の組の一覧 (既定 {})。移行のときに分類の組ごとに足す。入っている組の分類は、書き手が平文を書かずに SVEF で書く。";
$SourceVaultAtRestRecoveryCodeSink::usage =
  "$SourceVaultAtRestRecoveryCodeSink は試験専用。Memory の鍵ストアのときだけ、紙の回復キーを FE の窓の代わりにこの関数へ渡す。本番では使わない。";

SourceVaultAtRestClassInfo::usage =
  "SourceVaultAtRestClassInfo[classId] は分類の PL・出どころ・鍵の組・段を返す。表に無い分類は PL 1.0 / Unknown / 鍵の組なし。";
SourceVaultAtRestTier::usage =
  "SourceVaultAtRestTier[pl, accessLevel] は段 (1 / 2 / 3) を返す。pl >= 0.95 なら 1、pl <= accessLevel なら 3、他は 2。";
SourceVaultAtRestStoreOf::usage =
  "SourceVaultAtRestStoreOf[path] は path が属する保管先 (Store・Root・AccessLevel・LogicalPath) を返す。";
SourceVaultAtRestShouldEncryptQ::usage =
  "SourceVaultAtRestShouldEncryptQ[path, classId] は、その分類の鍵の組が強制されていて、段が 1 か 2 のとき True。書き手はこれが True なら平文を書かずに SourceVaultAtRestWriteBytes を使う。";

SourceVaultAtRestKeyring::usage =
  "SourceVaultAtRestKeyring[] は台帳 (svkeyring.json) の有効な最新の世代を返す (暗号文と公開情報だけ)。";
SourceVaultAtRestStatus::usage =
  "SourceVaultAtRestStatus[] は台帳 (世代と下限)・紙の回復 (作り直しの回数)・鍵の組ごとの版・準備・確かさ (Assurance) を返す (秘密は含まない)。段 1 の鍵が暫定で SystemCredential にある間は AssuranceNote に、同じ Windows 利用者のプロセスが復号できることを書く。";
SourceVaultEnsureClassKey::usage =
  "SourceVaultEnsureClassKey[group] は鍵の組の鍵を 1 度だけ作り、紙の回復の公開鍵で包んで台帳に記録する。台帳にある組は作り直さない (鍵が無ければ KeyMissing を返し、SourceVaultRecoverKeys を案内する)。";
SourceVaultAtRestSetup::usage =
  "SourceVaultAtRestSetup[] は台帳の MAC 鍵・紙の回復キー (無ければ作って印刷)・全部の鍵の組の鍵を用意する。最後に SourceVaultRecoveryDrill[] で訓練に合格するまで、暗号化の書き込みは動かない。";
SourceVaultCreateRecoveryKey::usage =
  "SourceVaultCreateRecoveryKey[] は紙の回復キー (SVR1) を作り、保存しない FE の窓に出して印刷させる。回復キーそのものはファイルに書かず、戻り値にも出さない。既にあれば作らない (\"Replace\" -> True で作り直す)。";
SourceVaultRecoveryDrill::usage =
  "SourceVaultRecoveryDrill[] は紙の回復キーを入力させ (FE の伏せ字の窓)、全部の鍵の組の鍵が紙から戻せることを、鍵の指紋の照合で確かめる。鍵ストアは変えない。合格を台帳に記録する。";
SourceVaultRecoverKeys::usage =
  "SourceVaultRecoverKeys[] は紙の回復キーを入力させ、台帳の鍵をこの機の鍵ストアに戻す (既にある鍵は上書きしない)。壊滅的なクラッシュの後や新しい機で使う。";
SourceVaultAtRestReadyQ::usage =
  "SourceVaultAtRestReadyQ[group] は、その鍵の組の鍵がこの機にあり、紙の回復の受取人があり、訓練に合格しているとき True。";

SourceVaultAtRestWriteBytes::usage =
  "SourceVaultAtRestWriteBytes[path, bytes, classId, opts] は bytes を SVEF で暗号化して path <> \".sve\" に書く (一時ファイル → 読み直して MAC・復号・バイト一致を確かめる → 改名 → 平文の path を消す)。opts: \"PL\" -> Automatic, \"DeletePlaintext\" -> True。準備ができていなければ Failure (平文に戻らない)。";
SourceVaultAtRestReadBytes::usage =
  "SourceVaultAtRestReadBytes[path] は path (平文の名前) のデータを返す。path <> \".sve\" があれば検証して復号、無ければ平文を読む。無ければ Missing[\"NotFound\"]、検証に失敗したら Failure。";
SourceVaultAtRestFileExistsQ::usage =
  "SourceVaultAtRestFileExistsQ[path] は平文か .sve のどちらかがあれば True。";
SourceVaultMigrateToEncrypted::usage =
  "SourceVaultMigrateToEncrypted[opts] は保管先の学生・成績のファイル (平文) を 1 件ずつ暗号化する (段 5)。既定は試し (\"DryRun\" -> True) で、分類ごとの件数と理由のコードだけを返す。opts: \"Classes\" (All か分類名の一覧)、\"MaxFiles\"、\"BackupManifest\" (Automatic = D:\\SourceVaultBackup の最新)、\"RequireBackup\" (True: 平文の SHA-256 がバックアップの目録と一致するファイルだけを移す)。本番は FE で、移す組を台帳の強制 (EnforcedGroups) に入れ、作業中は MAINTENANCE.json で他のカーネルの書き込みを止める。途中で止まってもやり直せる。細目は LocalState/atrest/migration の日誌。";
SourceVaultAtRestVerifyMigration::usage =
  "SourceVaultAtRestVerifyMigration[opts] は暗号化したファイルを復号し、平文の SHA-256 をバックアップの目録と比べて、分類ごとの件数 (MatchesBackup / DiffersFromBackup / NotInBackup / StillPlaintext / Both / Unreadable) だけを返す。";
SourceVaultDecryptStoreToPlaintext::usage =
  "SourceVaultDecryptStoreToPlaintext[opts] は暗号化したファイルを平文に戻す (バイト一致、元に戻す道具)。既定は試し。\"Unenforce\" -> True で、範囲に全部の分類が入る組の強制を外す。";
SourceVaultAtRestSetEnforced::usage =
  "SourceVaultAtRestSetEnforced[groups, \"Mode\" -> \"Add\" | \"Remove\" | \"Set\"] は台帳の EnforcedGroups (全部の機と service で、新しい書き込みを暗号化する組) を変える。足す組は準備 (訓練の合格) が要る。";
SourceVaultAtRestEndMaintenance::usage =
  "SourceVaultAtRestEndMaintenance[\"Force\" -> False] は移行の作業のロック (MAINTENANCE.json) を外す。別のカーネルが残したロックは \"Force\" -> True で外す。";
SourceVaultRotateClassKey::usage =
  "SourceVaultRotateClassKey[group] は鍵の組の鍵を交代させる (新しい版を作って紙の回復で包み、今の版を Retired に移す)。既存の暗号文は古い版で読める。訓練に合格した後、SourceVaultAtRestReencryptFile で新しい版に書き直す。段 1 の鍵を PRF に移すときと、紙が漏れたおそれがあるときに使う。";
SourceVaultAtRestReencryptFile::usage =
  "SourceVaultAtRestReencryptFile[path] は古い版の鍵で暗号化したファイルを、今の版の鍵で書き直す (中身は同じ)。今の版なら Current。";
SourceVaultAtRestViewFile::usage =
  "SourceVaultAtRestViewFile[bytes, name] は暗号化したデータを閲覧ソフトで開くための平文のファイルを、Dropbox の外 (LocalState/atrest/view) に作ってパスを返す。$SourceVaultAtRestViewTTL 秒 (既定 1800) を過ぎたものは次の呼び出しで消す。";
SourceVaultAtRestSweepViewFiles::usage =
  "SourceVaultAtRestSweepViewFiles[] は期限を過ぎた表示用の平文のファイルを消し、件数を返す。";
$SourceVaultAtRestViewTTL::usage =
  "$SourceVaultAtRestViewTTL は表示用の平文のファイルを残す秒数 (既定 1800)。";
SourceVaultAtRestResidualInventory::usage =
  "SourceVaultAtRestResidualInventory[] は本文以外に残る平文 (表示用・一時ファイル・webreports の学籍番号の名前・events の student: ・anonymize の config など) の件数だけを返す。まだ調べていない場所と、手で消す作業の一覧も添える。";
SourceVaultAtRestClassOfPath::usage =
  "SourceVaultAtRestClassOfPath[path] は保管先の中の位置から分類 (例 coursereports/gradebook → CourseGradebook、exams の -grading.wxf → ExamGrading、webreports → WebReport) を返す。分類表に無いもの・LocalState・不明な場所は Missing。";
SourceVaultAtRestFileNames::usage =
  "SourceVaultAtRestFileNames[pattern, dir, levels] は FileNames と同じだが、.sve を外した論理名で返す (平文と暗号文の両方を 1 つに)。一時ファイルは含めない。";
SourceVaultAtRestDeleteFile::usage =
  "SourceVaultAtRestDeleteFile[path] は平文と .sve の両方を消す。";
SourceVaultAtRestInventory::usage =
  "SourceVaultAtRestInventory[] は学生・成績の保管場所を走査し、分類ごとの件数 (平文・暗号文・両方・一時) とバイト数、段、鍵の組、強制の有無だけを返す (パスやハッシュは出さない)。";

Begin["`AtRestPrivate`"];

(* ------------------------------------------------------------
   分類表 (2026-11-14 所有者の決定)
   ------------------------------------------------------------ *)
$iATDecided = "2026-11-14";
iATEntry[pl_, group_, cat_] := <|"PL" -> pl, "Provenance" -> "Declared", "KeyGroup" -> group,
  "Category" -> cat, "DecidedAt" -> $iATDecided, "DecidedBy" -> "Owner"|>;

If[! AssociationQ[$SourceVaultKeyGroups],
  $SourceVaultKeyGroups = <|
    "grades" -> <|"Tier" -> 1, "Category" -> "成績・採点"|>,
    "pseudonym" -> <|"Tier" -> 1, "Category" -> "匿名化を戻す対応表"|>,
    "submissions" -> <|"Tier" -> 1, "Category" -> "提出物・採点の投影"|>,
    "roster" -> <|"Tier" -> 1, "Category" -> "名簿・履修者・レポート"|>,
    "derived" -> <|"Tier" -> 2, "Category" -> "匿名化済み・派生"|>|>];

If[! AssociationQ[$SourceVaultClassPrivacyRegistry],
  $SourceVaultClassPrivacyRegistry = Join[
    AssociationMap[iATEntry[0.98, "grades", "成績・採点"] &,
      {"ZelkovaGradeSnapshot", "CerezoExamRun", "CerezoExamScoreSummary", "CerezoFinalGradeReview",
       "ExamGrading", "CourseGradebook", "CourseSummaryGrades"}],
    AssociationMap[iATEntry[0.98, "pseudonym", "匿名化を戻す対応表"] &,
      {"PseudonymMap", "AnnotationBinding"}],
    AssociationMap[iATEntry[0.98, "submissions", "提出物・採点の投影"] &,
      {"CerezoCollectionRun", "CerezoCollectionSubmissionVersion", "CerezoCollectionCatalog",
       "CerezoGradingProjection", "Blob"}],
    AssociationMap[iATEntry[0.98, "roster", "名簿・履修者・レポート"] &,
      {"CourseEnrollment", "CourseRoster", "WebReport"}],
    AssociationMap[iATEntry[0.9, "derived", "匿名化済み・派生"] &,
      {"AnnotationContent", "AnonymizationPlan", "CloudTransportResult", "DerivedArtifact",
       "DeclassificationPublication"}]]];

If[! MatchQ[$SourceVaultStoreAccessLevels, _List], $SourceVaultStoreAccessLevels = Automatic];
If[! ListQ[$SourceVaultAtRestEnforce], $SourceVaultAtRestEnforce = {}];

SourceVaultAtRestClassInfo[classId_String] := Module[{e = Lookup[$SourceVaultClassPrivacyRegistry, classId, Missing[]]},
  If[AssociationQ[e],
    Join[e, <|"ClassId" -> classId, "Registered" -> True,
      "Tier" -> Lookup[Lookup[$SourceVaultKeyGroups, e["KeyGroup"], <||>], "Tier", Missing[]]|>],
    <|"ClassId" -> classId, "Registered" -> False, "PL" -> 1.0, "Provenance" -> "Unknown",
      "KeyGroup" -> Missing["Unclassified"], "Tier" -> 1|>]];

SourceVaultAtRestTier[pl_?NumericQ, al_?NumericQ] := Which[pl >= 0.95, 1, pl <= al, 3, True, 2];

(* ------------------------------------------------------------
   保管先と AccessLevel
   ------------------------------------------------------------ *)
iATNorm[p_String] := ToLowerCase[StringTrim[StringReplace[p, "/" -> "\\"], "\\"]];

iATRootValue[key_String] := Module[{v = Quiet @ Check[SourceVault`SourceVaultRoot[key], $Failed]},
  If[StringQ[v] && v =!= "", v, Missing[]]];

iATStores[] := Module[{core, pv, ls, out = {}},
  If[ListQ[$SourceVaultStoreAccessLevels], Return[$SourceVaultStoreAccessLevels]];
  core = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed];
  pv = iATRootValue["PrivateVault"];
  ls = iATRootValue["LocalState"];
  If[StringQ[core], AppendTo[out, <|"Store" -> "PrivateVault", "Root" -> core, "AccessLevel" -> 0.5|>]];
  If[StringQ[pv] && (! StringQ[core] || iATNorm[pv] =!= iATNorm[core]),
    AppendTo[out, <|"Store" -> "PrivateVault", "Root" -> pv, "AccessLevel" -> 0.5|>]];
  With[{base = If[StringQ[pv], pv, core]},
    If[StringQ[base],
      AppendTo[out, <|"Store" -> "WebReports", "Root" -> FileNameJoin[{DirectoryName[base], "webreports"}], "AccessLevel" -> 0.5|>]]];
  If[StringQ[ls], AppendTo[out, <|"Store" -> "LocalState", "Root" -> ls, "AccessLevel" -> 0.94|>]];
  out];

SourceVaultAtRestStoreOf[path_String] := Module[{np = iATNorm[path], hits},
  hits = Select[iATStores[], StringStartsQ[np, iATNorm[#Root] <> "\\"] &];
  If[hits === {},
    <|"Store" -> "Unknown", "Root" -> Missing[], "AccessLevel" -> 0, "LogicalPath" -> StringReplace[np, "\\" -> "/"]|>,
    With[{h = Last[SortBy[hits, StringLength[#Root] &]]},
      (* 照合は小文字で、論理パスは元の大文字・小文字のまま (分類名が CamelCase のため) *)
      Join[h, <|"LogicalPath" -> StringReplace[
        StringDrop[StringTrim[StringReplace[path, "/" -> "\\"], "\\"], StringLength[iATNorm[h["Root"]]] + 1], "\\" -> "/"]|>]]]];

(* 強制する鍵の組 (2026-11-14、段 5) = $SourceVaultAtRestEnforce (このカーネルだけ) ∪ 台帳の EnforcedGroups
   (台帳は Dropbox で同期するので、全部の機と service に効く)。台帳の写しはあるのに検証できない・巻き戻された・消えたときは、
   分類表の全部の組を強制とみなす (鍵の無い機が平文を書かないように)。読むのは 10 秒に 1 回まで。 *)
If[! ListQ[$iATEnforcedCache], $iATEnforcedCache = {0, Null, {}}];
iATEnforcedGroups[] := Module[{now = AbsoluteTime[], macQ = NBAccess`NBKeyMaterialExistsQ[$iATKeyringMacRef], rd, g},
  If[now - $iATEnforcedCache[[1]] < 10 && $iATEnforcedCache[[2]] === macQ,
    Return[Union[$SourceVaultAtRestEnforce, $iATEnforcedCache[[3]]]]];
  rd = iATReadKeyring[];
  g = Which[
    (* 鍵の無い機 (台帳の MAC を確かめられない): 写しに書かれた強制の組を検証なしで使う。台帳を作っただけ (移行の前) なら
       空なので、その機の今の書き込みは止まらない。移行した組は、その機で SourceVaultRecoverKeys を済ませるまで書けない。 *)
    FailureQ[rd] && rd[[1]] === "KeyringInvalid",
      Union @@ Append[Lookup[Lookup[#, "Ring", <||>], "EnforcedGroups", {}] & /@ (iATReadRingFile /@ Select[iATKeyringPaths[], FileExistsQ]), {}],
    FailureQ[rd], Keys[$SourceVaultKeyGroups],   (* 巻き戻し・消失: 全部の組を強制 *)
    rd["Status"] === "Empty", {},
    True, Lookup[rd["Ring"], "EnforcedGroups", {}]];
  If[! ListQ[g] || ! AllTrue[g, StringQ], g = Keys[$SourceVaultKeyGroups]];
  $iATEnforcedCache = {now, macQ, g};
  Union[$SourceVaultAtRestEnforce, g]];
iATResetEnforcedCache[] := ($iATEnforcedCache = {0, Null, {}});

(* 移行中のロック (段 5): PrivateVault/atrest/MAINTENANCE.json (Dropbox で他の機にも見える)。
   ロックを持たないカーネルからの分類表の分類の書き込みは、暗号化の書き込みへ回して StoreLocked で止める。 *)
If[! ValueQ[$iATMaintenanceRun], $iATMaintenanceRun = None];
iATMaintPath[] := Module[{pv = iATRootValue["PrivateVault"], core = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed], base},
  base = Which[StringQ[pv], pv, StringQ[core], core, True, Missing[]];
  If[StringQ[base], FileNameJoin[{base, "atrest", "MAINTENANCE.json"}], Missing[]]];
iATMaintenanceInfo[] := Module[{p = iATMaintPath[]},
  If[StringQ[p] && FileExistsQ[p],
    With[{a = Quiet @ Check[ImportByteArray[iATReadFile[p], "RawJSON"], $Failed]}, If[AssociationQ[a], a, <|"RunId" -> "unreadable"|>]],
    None]];
iATMaintenanceForeignQ[] := With[{m = iATMaintenanceInfo[]}, AssociationQ[m] && Lookup[m, "RunId", ""] =!= $iATMaintenanceRun];

SourceVaultAtRestShouldEncryptQ[path_String, classId_String] := Module[{ci = SourceVaultAtRestClassInfo[classId], st},
  If[! TrueQ[ci["Registered"]], Return[False]];
  st = SourceVaultAtRestStoreOf[path];
  If[SourceVaultAtRestTier[ci["PL"], st["AccessLevel"]] >= 3, Return[False]];
  If[iATMaintenanceForeignQ[], Return[True]];
  MemberQ[iATEnforcedGroups[], ci["KeyGroup"]]];

(* ------------------------------------------------------------
   小さな部品
   ------------------------------------------------------------ *)
iATNowIso[] := DateString[TimeZoneConvert[Now, 0], {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"}];
iATU32[n_Integer] := ByteArray[IntegerDigits[n, 256, 4]];
iATReadU32[ba_ByteArray, i_Integer] := FromDigits[Normal[ba[[i ;; i + 3]]], 256];
iATHexToBytes[h_String] := ByteArray[FromDigits[#, 16] & /@ StringPartition[h, 2]];
iATBytesToHex[b_ByteArray] := StringJoin[IntegerString[#, 16, 2] & /@ Normal[b]];
iATSha256[b_ByteArray] := Hash[b, "SHA256", "ByteArray"];
iATHmac[key_ByteArray, msg_String] := iATHexToBytes[SourceVault`SourceVaultHMACSHA256Hex[key, StringToByteArray[msg, "UTF-8"]]];
iATCJson[a_] := SourceVault`SourceVaultCanonicalJSONBytes[a];
iATMachine[] := ToLowerCase[ToString[$MachineName]];
iATFail[tag_String, msg_String, extra_Association : <||>] :=
  Failure[tag, Join[<|"MessageTemplate" -> msg|>, extra]];

iATLocalStateDir[] := Module[{ls = iATRootValue["LocalState"]},
  If[StringQ[ls], ls, FileNameJoin[{$TemporaryDirectory, "SourceVault-LocalState"}]]];
iATEnsureDir[d_String] := If[! DirectoryQ[d], Quiet @ CreateDirectory[d, CreateIntermediateDirectories -> True]];

iATWriteBytesFile[path_String, bytes_ByteArray] := Module[{s},
  s = OpenWrite[path, BinaryFormat -> True];
  If[Head[s] =!= OutputStream, Return[$Failed]];
  WithCleanup[BinaryWrite[s, bytes], Close[s]];
  path];

(* ファイルの読み込みは、毎回新しく開いたストリームで行い、大きさが FileByteCount と一致するかを確かめる (2026-11-14)。
   ReadByteArray[パス] は、同じファイルを開いたままのストリームがカーネルにあると、それを使い回して今の位置から読む
   (再現: 100 バイトのうち 70 バイト)。所有者の FE の移行の試しで、1 件の snapshot が欠けて読まれ、目録と合わずに止まった。 *)
iATReadFile[p_String] := Module[{s, b, n},
  s = Quiet @ Check[OpenRead[p, BinaryFormat -> True], $Failed];
  If[Head[s] =!= InputStream, Return[$Failed]];
  b = WithCleanup[Quiet @ ReadByteArray[s], Close[s]];
  If[b === EndOfFile, b = StringToByteArray["", "UTF-8"]];
  n = Quiet @ Check[FileByteCount[p], -1];
  If[ByteArrayQ[b] && Length[b] === n, b, $Failed]];

(* Windows では、書いた直後のファイルを Dropbox・Defender・検索の索引などが開いていて、置き換え (改名) や削除が一時的に
   断られることがある (2026-11-14 の本番の SourceVaultAtRestSetup[] で、台帳の Dropbox 側の写しの置き換えが 1 回断られ、
   KeyringWriteFailed で止まった)。0.25 秒ずつ待って最大 20 回 (約 5 秒) 試す。 *)
iATRenameRetry[src_String, dst_String] := Module[{ok = False, i = 0},
  While[! ok && i < 20,
    ok = TrueQ[Quiet @ Check[RenameFile[src, dst, OverwriteTarget -> True]; True, False]];
    If[! ok, i++; Pause[0.25]]];
  ok];
iATDeleteRetry[p_String] := Module[{i = 0},
  While[FileExistsQ[p] && i < 20,
    Quiet @ Check[DeleteFile[p], Null];
    If[FileExistsQ[p], i++; Pause[0.25]]];
  ! FileExistsQ[p]];

(* 一時ファイル (同じフォルダ) → 読み直して一致 → 改名。中身は呼び出し側の責任 (台帳・SVEF は暗号文か公開情報だけ)。 *)
iATAtomicWrite[path_String, bytes_ByteArray] := Module[{tmp, back},
  iATEnsureDir[DirectoryName[path]];
  tmp = path <> ".tmp." <> IntegerString[RandomInteger[{0, 36^8 - 1}], 36, 8];
  If[iATWriteBytesFile[tmp, bytes] === $Failed, Return[$Failed]];
  back = Quiet @ Check[iATReadFile[tmp], $Failed];
  If[back =!= bytes, Quiet @ DeleteFile[tmp]; Return[$Failed]];
  If[! iATRenameRetry[tmp, path], iATDeleteRetry[tmp]; Return[$Failed]];
  path];

(* ファイルごとのロック (LocalState、ディレクトリの作成は原子的)。120 秒より古いロックは捨てる。 *)
SetAttributes[iATWithLock, HoldRest];
iATWithLock[path_String, body_] := Module[{dir, lock, got = False, i = 0, r},
  dir = FileNameJoin[{iATLocalStateDir[], "atrest", "locks"}]; iATEnsureDir[dir];
  lock = FileNameJoin[{dir, StringTake[Hash[iATNorm[path], "SHA256", "HexString"], 24] <> ".lock"}];
  While[! got && i < 200,
    got = Quiet @ Check[CreateDirectory[lock]; True, False];
    If[! got,
      With[{age = Quiet @ Check[AbsoluteTime[] - AbsoluteTime[FileDate[lock, "Modification"]], 0]},
        If[NumericQ[age] && age > 120, Quiet @ DeleteDirectory[lock]]];
      Pause[0.05]; i++]];
  If[! got, Return[iATFail["AtRestLockUnavailable", "暗号化の書き込みのロックを取れませんでした。少し待ってからやり直してください。"]]];
  (* 中断されてもロックは外す。中のメッセージは握りつぶさない (失敗は Failure で返る)。 *)
  r = WithCleanup[body, Quiet @ DeleteDirectory[lock]];
  If[r === $Failed, iATFail["AtRestWriteFailed", "暗号化の書き込みに失敗しました。元のファイルはそのままです。"], r]];

(* ------------------------------------------------------------
   鍵の台帳 (svkeyring.json)
   ------------------------------------------------------------ *)
$iATKeyringMacRef = "SourceVault:keyring:mac:v1";
(* 鍵の名前は版つき (2026-11-14 の比較レビュー 5 章の 5 を受けて): 鍵を交代させたら v2, v3, .. を作り、
   古い版は台帳の Retired に残す (古い版で暗号化したファイルを書き直し終えるまで要る)。 *)
iATKeyRefs[group_String, v_Integer : 1] := <|"Enc" -> "SourceVault:dek:v" <> ToString[v] <> ":" <> group <> ":enc",
  "Mac" -> "SourceVault:dek:v" <> ToString[v] <> ":" <> group <> ":mac"|>;
iATEntryVersion[e_Association] := Lookup[e, "KeyVersion", 1];
iATEntryRefs[e_Association] := <|"Enc" -> e["EncKeyRef"], "Mac" -> e["MacKeyRef"]|>;
(* 台帳の組の項目 → 今の版と退役した版の鍵の組の一覧 *)
iATEntryKeySets[e_Association] := Join[
  {<|"Version" -> iATEntryVersion[e], "Refs" -> iATEntryRefs[e], "EncFingerprint" -> e["EncFingerprint"],
     "MacFingerprint" -> e["MacFingerprint"], "Recovery" -> Lookup[Lookup[e, "Recipients", <||>], "Recovery", Null], "Current" -> True|>},
  Function[r, <|"Version" -> r["KeyVersion"], "Refs" -> <|"Enc" -> r["EncKeyRef"], "Mac" -> r["MacKeyRef"]|>,
     "EncFingerprint" -> r["EncFingerprint"], "MacFingerprint" -> r["MacFingerprint"],
     "Recovery" -> Lookup[r, "Recovery", Null], "Current" -> False|>] /@ Lookup[e, "Retired", {}]];
(* 鍵の操作の試し直し (2026-11-14): SystemCredential からの鍵の読み出しは、まれに一時的に失敗する
   (本番の移行で 7,169 件中 1 件が SVEFEncryptFailed。同じ鍵で前後のファイルは暗号化できていた)。
   読み出しの失敗を「MAC が合わない (改ざん)」と取り違えないよう、$Failed / Missing のときだけ 0.2 秒おいて 3 回まで試す。 *)
iATKeyRetry[f_] := Module[{r = $Failed, i = 0},
  While[i < 3,
    r = f[];
    If[r =!= $Failed && ! MissingQ[r], Break[]];
    i++; Pause[0.2]];
  r];
iATFp[ref_String] := iATKeyRetry[NBAccess`NBKeyMaterialFingerprint[ref] &];
iATMacHex[ref_String, bytes_ByteArray] := iATKeyRetry[NBAccess`NBMacWithKeyRef[ref, bytes] &];

iATKeySetPresentQ[ks_Association] :=
  iATFp[ks["Refs"]["Enc"]] === ks["EncFingerprint"] &&
  iATFp[ks["Refs"]["Mac"]] === ks["MacFingerprint"];

iATKeyringDirs[] := Module[{core = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed], pv = iATRootValue["PrivateVault"], ls = iATRootValue["LocalState"]},
  DeleteDuplicatesBy[Select[{
      If[StringQ[pv], FileNameJoin[{pv, "keyring"}], If[StringQ[core], FileNameJoin[{core, "keyring"}], Missing[]]],
      If[StringQ[ls], FileNameJoin[{ls, "keyring"}], Missing[]]}, StringQ], iATNorm]];
iATKeyringPaths[] := FileNameJoin[{#, "svkeyring.json"}] & /@ iATKeyringDirs[];

iATRingMac[ring_Association] := iATMacHex[$iATKeyringMacRef, iATCJson[KeyDrop[ring, "Mac"]]];

(* 1 つの写しを読む: <|Ring, Valid (True | False | "Unverified"), Path|> *)
iATReadRingFile[path_String] := Module[{bytes, ring, mac},
  bytes = Quiet @ Check[iATReadFile[path], $Failed];
  If[Head[bytes] =!= ByteArray, Return[<|"Path" -> path, "Valid" -> False, "Reason" -> "Unreadable"|>]];
  ring = Quiet @ Check[ImportByteArray[bytes, "RawJSON"], $Failed];
  If[! AssociationQ[ring] || Lookup[ring, "Type", ""] =!= "SourceVaultKeyring",
    Return[<|"Path" -> path, "Valid" -> False, "Reason" -> "NotAKeyring"|>]];
  If[! NBAccess`NBKeyMaterialExistsQ[$iATKeyringMacRef],
    Return[<|"Path" -> path, "Ring" -> ring, "Valid" -> "Unverified", "Reason" -> "KeyringMacKeyMissing"|>]];
  mac = iATRingMac[ring];
  If[StringQ[mac] && StringQ[Lookup[ring, "Mac", Null]] && SourceVault`SourceVaultConstantTimeEqualQ[mac, ring["Mac"]],
    <|"Path" -> path, "Ring" -> ring, "Valid" -> True|>,
    <|"Path" -> path, "Ring" -> ring, "Valid" -> False, "Reason" -> "MacMismatch"|>]];

(* 世代の下限 (2026-11-14、比較レビュー 6 章の「旧バックアップ復元」を受けて):
   この機で見た最大の世代を LocalState (Dropbox の外) に、台帳の MAC 鍵の MAC つきで覚える。
   それより古い台帳は使わない。台帳を古い正当な版に戻されると、作り直す前の (漏れたかもしれない) 紙の回復の
   公開鍵で新しい鍵を包んでしまうため。台帳の MAC 鍵が無い機 (新しい機・回復の前) では下限を確かめられない。 *)
iATFloorPath[] := FileNameJoin[{iATLocalStateDir[], "atrest", "keyring.floor.json"}];
iATFloorMac[g_Integer] := iATMacHex[$iATKeyringMacRef, iATCJson[<|"Purpose" -> "keyring floor", "Generation" -> g|>]];
iATReadFloor[] := Module[{p = iATFloorPath[], a, mac},
  If[! FileExistsQ[p] || ! NBAccess`NBKeyMaterialExistsQ[$iATKeyringMacRef], Return[0]];
  a = Quiet @ Check[ImportByteArray[iATReadFile[p], "RawJSON"], $Failed];
  If[! AssociationQ[a] || ! IntegerQ[Lookup[a, "Generation", Null]], Return[0]];
  mac = iATFloorMac[a["Generation"]];
  If[StringQ[mac] && StringQ[Lookup[a, "Mac", Null]] && SourceVault`SourceVaultConstantTimeEqualQ[mac, a["Mac"]], a["Generation"], 0]];
iATWriteFloor[g_Integer] := Module[{mac},
  If[g <= iATReadFloor[], Return[Null]];
  mac = iATFloorMac[g];
  If[StringQ[mac],
    iATAtomicWrite[iATFloorPath[], ExportByteArray[<|"Generation" -> g, "Machine" -> iATMachine[], "UpdatedAt" -> iATNowIso[], "Mac" -> mac|>, "RawJSON"]]]];

(* 有効な写しのうち最大の世代。allowUnverified は回復のときだけ (鍵ストアに台帳の MAC 鍵がまだ無い)。 *)
iATReadKeyring[allowUnverified_ : False] := Module[{reads, ok, floor},
  reads = iATReadRingFile /@ Select[iATKeyringPaths[], FileExistsQ];
  floor = iATReadFloor[];
  If[reads === {},
    If[floor > 0,
      Return[iATFail["KeyringMissing",
        "鍵の台帳 (svkeyring.json) がどこにもありません。この機は世代 " <> ToString[floor] <> " の台帳を見ています。新しく作らずに、D: のバックアップか他の機から台帳を戻してください。"]]];
    Return[<|"Status" -> "Empty", "Ring" -> iATNewRing[], "Copies" -> {}|>]];
  ok = Select[reads, (#Valid === True || (TrueQ[allowUnverified] && #Valid === "Unverified")) &];
  If[ok === {},
    Return[iATFail["KeyringInvalid",
      "鍵の台帳 (svkeyring.json) の写しがどれも検証できません。改ざんか、この機に台帳の MAC 鍵がありません。新しい機なら SourceVaultRecoverKeys[] で紙の回復キーから戻してください。",
      <|"Copies" -> (KeyTake[#, {"Valid", "Reason"}] & /@ reads)|>]]];
  With[{best = Last[SortBy[ok, Lookup[#Ring, "Generation", 0] &]]},
    If[best["Valid"] === True,
      If[Lookup[best["Ring"], "Generation", 0] < floor,
        Return[iATFail["KeyringRollback",
          "鍵の台帳が古い版に戻されています (世代 " <> ToString[Lookup[best["Ring"], "Generation", 0]] <> " < この機で見た世代 " <> ToString[floor] <> ")。使いません。最新の台帳を D: のバックアップか他の機から戻してください。"]]];
      iATWriteFloor[Lookup[best["Ring"], "Generation", 0]]];
    <|"Status" -> If[best["Valid"] === True, "OK", "Unverified"], "Ring" -> best["Ring"],
      "Copies" -> (KeyTake[#, {"Valid", "Reason"}] & /@ reads)|>]];

iATNewRing[] := <|"Type" -> "SourceVaultKeyring", "Version" -> 1, "Generation" -> 0,
  "CreatedAt" -> iATNowIso[], "UpdatedAt" -> iATNowIso[], "Recovery" -> Null, "KeyGroups" -> <||>|>;

iATWriteKeyring[ring0_Association] := Module[{ring, bytes, paths, res},
  iATResetEnforcedCache[];
  NBAccess`NBGenerateMacKeyRef[$iATKeyringMacRef, <|"Purpose" -> "keyring MAC", "Owner" -> "SourceVault"|>, "CreateOnly" -> True];
  ring = Join[ring0, <|"Generation" -> Lookup[ring0, "Generation", 0] + 1, "UpdatedAt" -> iATNowIso[]|>];
  ring = KeyDrop[ring, "Mac"];
  ring["Mac"] = iATRingMac[ring];
  If[! StringQ[ring["Mac"]], Return[iATFail["KeyringMacFailed", "台帳の MAC を計算できませんでした。"]]];
  bytes = ExportByteArray[ring, "RawJSON"];
  paths = iATKeyringPaths[];
  If[paths === {}, Return[iATFail["KeyringNoLocation", "台帳の置き場所 (PrivateVault・LocalState) が解決できません。"]]];
  res = iATAtomicWrite[#, bytes] & /@ paths;
  If[MemberQ[res, $Failed], Return[iATFail["KeyringWriteFailed", "台帳の写しの一部を書けませんでした。", <|"Written" -> Count[res, _String], "Total" -> Length[paths]|>]]];
  (* 読み直して検証 *)
  With[{back = iATReadKeyring[]},
    If[FailureQ[back] || back["Status"] =!= "OK" || back["Ring"]["Generation"] =!= ring["Generation"],
      Return[iATFail["KeyringVerifyFailed", "書いた台帳を読み直して検証できませんでした。"]]]];
  ring];

SourceVaultAtRestKeyring[] := Module[{r = iATReadKeyring[]}, If[FailureQ[r], r, r["Ring"]]];

(* ------------------------------------------------------------
   紙の回復キー (SVR1)
   ------------------------------------------------------------ *)
$iATCrock = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ"];
$iATCheckSyms = Characters["0123456789ABCDEFGHJKMNPQRSTVWXYZ*~$=U"];

iATDerive[r_ByteArray] := <|
  "WrapKey" -> SymmetricKey[<|"Cipher" -> "AES256", "BlockMode" -> "CBC", "Key" -> iATHmac[r, "SVR1 wrap"]|>],
  "MacKey" -> iATHmac[r, "SVR1 mac"],
  "KeyId" -> StringTake[iATBytesToHex[iATHmac[r, "SVR1 id"]], 8]|>;

iATLineCheck[digits_List, lineNo_Integer] := $iATCheckSyms[[Mod[FromDigits[digits, 32] + 7 lineNo, 37] + 1]];

(* R (32 バイト) → <|Lines -> {"XXXX XXXX XXXX XXXX c", ..}, CHK, QR|> *)
iATEncodeCode[r_ByteArray] := Module[{digits, lines, chk},
  digits = IntegerDigits[FromDigits[Normal[r], 256]*16, 32, 52];
  lines = MapIndexed[
    Function[{ds, idx}, StringRiffle[StringJoin /@ Partition[$iATCrock[[ds + 1]], 4], " "] <> "  " <> iATLineCheck[ds, idx[[1]]]],
    {digits[[1 ;; 16]], digits[[17 ;; 32]], digits[[33 ;; 48]], digits[[49 ;; 52]]}];
  chk = StringJoin[$iATCrock[[IntegerDigits[Quotient[FromDigits[Normal[iATSha256[r][[1 ;; 3]]], 256], 16], 32, 4] + 1]]];
  <|"Lines" -> lines, "CHK" -> chk,
    "QR" -> "SVR1:" <> StringJoin[$iATCrock[[digits + 1]]] <> ":" <> chk|>];

iATNormChars[s_String] := StringReplace[ToUpperCase[s], {"O" -> "0", "I" -> "1", "L" -> "1", "-" -> "", "\[ThinSpace]" -> ""}];

iATDigitsOf[s_String] := Module[{cs = Characters[s]},
  If[! SubsetQ[$iATCrock, cs], Return[$Failed]];
  Flatten[Position[$iATCrock, #] & /@ cs] - 1];

iATCodeToBytes[digits_List, chk_String] := Module[{n, r},
  If[Length[digits] =!= 52, Return[iATFail["RecoveryCodeLength", "回復キーの文字数が合いません (52 文字)。"]]];
  n = FromDigits[digits, 32];
  If[Mod[n, 16] =!= 0, Return[iATFail["RecoveryCodeInvalid", "回復キーの最後の文字が正しくありません。4 行目を確かめてください。"]]];
  r = ByteArray[IntegerDigits[Quotient[n, 16], 256, 32]];
  If[iATEncodeCode[r]["CHK"] =!= chk,
    Return[iATFail["RecoveryCodeChecksum", "全体の検査値 (CHK) が合いません。入力の誤りか、別の回復キーです。"]]];
  r];

(* 紙の 4 行 + CHK、または QR の文字列 "SVR1:<52>:<CHK>" を解く *)
iATParseCode[text_String] := Module[{t = text, m, lines, chkLine, bad = {}, digits = {}},
  m = StringCases[iATNormChars[StringDelete[t, Whitespace]], "SVR1:" ~~ x : Repeated[WordCharacter, {52}] ~~ ":" ~~ c : Repeated[WordCharacter, {4}] :> {x, c}];
  If[m =!= {},
    With[{d = iATDigitsOf[m[[1, 1]]]},
      Return[If[d === $Failed, iATFail["RecoveryCodeInvalid", "QR の文字列に使えない文字があります。"], iATCodeToBytes[d, m[[1, 2]]]]]]];
  lines = Select[StringTrim /@ StringSplit[t, {"\r\n", "\n", "\r"}], # =!= "" &];
  chkLine = SelectFirst[lines, StringStartsQ[ToUpperCase[#], "CHK"] &, Missing[]];
  lines = DeleteCases[lines, chkLine];
  If[MissingQ[chkLine] || Length[lines] =!= 4,
    Return[iATFail["RecoveryCodeShape", "回復キーは 4 行と CHK の行を入力してください。"]]];
  Do[
    Module[{ln = StringReplace[lines[[i]], StartOfString ~~ Whitespace ... ~~ DigitCharacter .. ~~ Whitespace ... ~~ (":" | ".") -> ""], s, data, ck, ds},
      (* 空白の有無にかかわらず、最後の 1 文字を検査文字、残りをデータとして読む *)
      s = StringDelete[iATNormChars[ln], Whitespace];
      If[StringLength[s] < 2, AppendTo[bad, i]; Continue[]];
      ck = StringTake[s, -1]; data = StringDrop[s, -1];
      ds = iATDigitsOf[data];
      If[ds === $Failed || Length[ds] =!= If[i === 4, 4, 16] || iATLineCheck[ds, i] =!= ck,
        AppendTo[bad, i], digits = Join[digits, ds]]],
    {i, 4}];
  If[bad =!= {},
    Return[iATFail["RecoveryCodeLine", "回復キーの次の行が正しくありません (行末の検査文字が合わない): " <> StringRiffle[ToString /@ bad, ", "], <|"Lines" -> bad|>]]];
  iATCodeToBytes[digits, StringTrim[StringDrop[iATNormChars[StringDelete[chkLine, Whitespace]], 3], ":"]]];

iATAskCode[title_String] := Module[{r},
  If[! TrueQ[$Notebooks], Return[iATFail["NoFrontEnd", "紙の回復キーの入力には FE が要ります。"]]];
  r = DialogInput[DynamicModule[{l1 = "", l2 = "", l3 = "", l4 = "", ck = ""},
      Column[{Style[title, Bold, 14],
        "紙の回復キーの各行を、行末の検査文字も含めて入力してください (空白はあってもなくても構いません)。",
        Grid[{{"1:", InputField[Dynamic[l1], String, FieldMasked -> True, FieldSize -> 32]},
              {"2:", InputField[Dynamic[l2], String, FieldMasked -> True, FieldSize -> 32]},
              {"3:", InputField[Dynamic[l3], String, FieldMasked -> True, FieldSize -> 32]},
              {"4:", InputField[Dynamic[l4], String, FieldMasked -> True, FieldSize -> 32]},
              {"CHK:", InputField[Dynamic[ck], String, FieldMasked -> True, FieldSize -> 8]}}, Alignment -> Left],
        Row[{DefaultButton["確認", DialogReturn[StringRiffle[{"1: " <> l1, "2: " <> l2, "3: " <> l3, "4: " <> l4, "CHK " <> ck}, "\n"]]],
          Spacer[10], CancelButton["取消", DialogReturn[$Canceled]]}]}, Spacings -> 1]],
    WindowTitle -> "SourceVault 回復キーの入力"];
  If[StringQ[r], r, iATFail["RecoveryCancelled", "回復キーの入力が取り消されました。"]]];

iATShowSheet[code_Association, keyId_String, dirs_List] := CreateDocument[{
    TextCell["SourceVault 回復キー (SVR1)", "Title"],
    TextCell["鍵 ID: " <> keyId <> "    作成: " <> iATNowIso[] <> "    機: " <> iATMachine[], "Text"],
    TextCell["この紙だけで、SourceVault が暗号化した学生・成績などの鍵をすべて戻せます。2 部印刷し、別々の安全な場所に保管してください。写真を撮ったり、ファイルに保存したり、画面を共有したりしないでください。", "Text"],
    ExpressionCell[Column[Style[#, FontFamily -> "Consolas", FontSize -> 22] & /@ Append[code["Lines"], "CHK " <> code["CHK"]], Spacings -> 1.2], "Output"],
    ExpressionCell[Show[BarcodeImage[code["QR"], "QR"], ImageSize -> 220], "Output"],
    TextCell["各行の最後の 1 文字は検査文字です。O は 0、I と L は 1 として読みます。", "Text"],
    TextCell["台帳 (svkeyring.json) の置き場所: " <> StringRiffle[dirs, "  /  "], "Text"],
    TextCell["戻すとき: SourceVaultRecoverKeys[] を評価し、この紙の 4 行と CHK を入力します。訓練: SourceVaultRecoveryDrill[]。", "Text"],
    ExpressionCell[Row[{
        Button["印刷する", FrontEndTokenExecute[ButtonNotebook[], "PrintDialog"], Method -> "Queued"], Spacer[20],
        Button["閉じる (保存しない)", NotebookClose[ButtonNotebook[]], Method -> "Queued"]}], "Output"]},
  Saveable -> False, WindowTitle -> "SourceVault 回復キー (保存しないでください)", ShowCellBracket -> False,
  Editable -> False];

(* 作り直し ("Replace" -> True) は古い紙の入力を求める (2026-11-14、比較レビューを受けて)。
   古い紙なしで作り直せると、所有者の紙を無効にし、新しい鍵を別の紙に包ませられてしまう。
   紙を失くしたときだけ "OldPaperLost" -> True (FE の確認の窓つき、台帳に記録)。その場合は全部の鍵の組の交代を勧める。 *)
Options[SourceVaultCreateRecoveryKey] = {"Replace" -> False, "OldCode" -> Automatic, "OldPaperLost" -> False};
SourceVaultCreateRecoveryKey[OptionsPattern[]] := Module[
  {rd, ring, r, d, kp, privCt, privCtBytes, pubB64, rec, groups, wrapped, sink, useSink, dirs, out, oldRec, oldPk, withOld = Null},
  (* 試験の受け口は Memory の鍵ストアのときだけ (本番の鍵ストアでは必ず FE の窓に出す) *)
  sink = $SourceVaultAtRestRecoveryCodeSink;
  useSink = MatchQ[sink, _Function] && NBAccess`$NBCredentialBackend === "Memory";
  If[! TrueQ[$Notebooks] && ! useSink,
    Return[iATFail["NoFrontEnd", "紙の回復キーは FE の窓に出して印刷します。FE のノートブックで評価してください。"]]];
  rd = iATReadKeyring[]; If[FailureQ[rd], Return[rd]];
  ring = rd["Ring"]; oldRec = ring["Recovery"];
  If[AssociationQ[oldRec] && ! TrueQ[OptionValue["Replace"]],
    Return[iATFail["RecoveryKeyExists", "紙の回復キーは既にあります (鍵 ID " <> oldRec["KeyId"] <> ")。作り直すときは \"Replace\" -> True を付けてください。古い紙は使えなくなります。"]]];
  If[AssociationQ[oldRec],
    If[TrueQ[OptionValue["OldPaperLost"]],
      If[! useSink && ! TrueQ[ChoiceDialog[
          "古い紙の回復キー (鍵 ID " <> oldRec["KeyId"] <> ") なしで作り直します。古い紙を他の人が持っているおそれがあるときは、作り直した後に全部の鍵の組を交代させてください (SourceVaultRotateClassKey)。続けますか？",
          {"作り直す" -> True, "やめる" -> False}, WindowTitle -> "SourceVault 回復キーの作り直し"]],
        Return[iATFail["RecoveryReplaceCancelled", "作り直しを取り消しました。"]]];
      withOld = False,
      oldPk = iATRecoveryPrivateKey[ring, OptionValue["OldCode"]];
      If[FailureQ[oldPk],
        Return[iATFail["RecoveryReplaceNeedsOldPaper",
          "作り直すには古い紙の回復キーの入力が要ります (失くしたときは \"OldPaperLost\" -> True)。", <|"Reason" -> oldPk[[1]]|>]]];
      ClearAll[oldPk]; withOld = True]];
  r = GenerateSymmetricKey[]["Key"];
  d = iATDerive[r];
  kp = GenerateAsymmetricKeyPair[Method -> <|"Type" -> "RSA", "KeySize" -> 3072|>];
  privCt = Encrypt[d["WrapKey"], BinarySerialize[kp["PrivateKey"]]];
  privCtBytes = BinarySerialize[privCt];
  pubB64 = BaseEncode[BinarySerialize[kp["PublicKey"]]];
  rec = <|"Format" -> "SVR1", "KeyId" -> d["KeyId"], "PublicKeyB64" -> pubB64,
    "WrappedPrivateKeyB64" -> BaseEncode[privCtBytes],
    "PrivateKeyMac" -> SourceVault`SourceVaultHMACSHA256Hex[d["MacKey"], privCtBytes],
    "CreatedAt" -> iATNowIso[], "CreatedOn" -> iATMachine[], "DrillPassedAt" -> Null,
    "Replaced" -> If[AssociationQ[oldRec],
      Append[Lookup[oldRec, "Replaced", {}], <|"KeyId" -> oldRec["KeyId"], "ReplacedAt" -> iATNowIso[], "WithOldPaper" -> withOld|>],
      {}]|>;
  (* 台帳の MAC 鍵と既存の鍵の組 (今の版と退役した版) を新しい回復の公開鍵で包み直す *)
  NBAccess`NBGenerateMacKeyRef[$iATKeyringMacRef, <|"Purpose" -> "keyring MAC", "Owner" -> "SourceVault"|>, "CreateOnly" -> True];
  wrapped = NBAccess`NBWrapKeyRefsForPublicKey[{$iATKeyringMacRef}, kp["PublicKey"]];
  If[! KeyExistsQ[wrapped, $iATKeyringMacRef], Return[iATFail["RecoveryWrapFailed", "台帳の MAC 鍵を回復の公開鍵で包めませんでした。"]]];
  rec["KeyringMacWrappedB64"] = BaseEncode[BinarySerialize[wrapped[$iATKeyringMacRef]["Ciphertext"]]];
  rec["KeyringMacFingerprint"] = wrapped[$iATKeyringMacRef]["Fingerprint"];
  ring["Recovery"] = rec;
  groups = Lookup[ring, "KeyGroups", <||>];
  wrapped = Catch[
    KeyValueMap[Function[{g, e}, Module[{w},
        w = iATWrapGroupForRecovery[g, iATEntryRefs[e], kp["PublicKey"], d["KeyId"]];
        If[FailureQ[w], Throw[w, "atWrap"]];
        ring["KeyGroups", g, "Recipients", "Recovery"] = w;
        If[Lookup[e, "Retired", {}] =!= {},
          ring["KeyGroups", g, "Retired"] = Map[Function[rt, Module[{w2},
              w2 = iATWrapGroupForRecovery[g <> " v" <> ToString[rt["KeyVersion"]],
                <|"Enc" -> rt["EncKeyRef"], "Mac" -> rt["MacKeyRef"]|>, kp["PublicKey"], d["KeyId"]];
              If[FailureQ[w2], Throw[w2, "atWrap"]];
              Join[rt, <|"Recovery" -> w2|>]]], e["Retired"]]]]],
      groups];
    Null, "atWrap"];
  If[FailureQ[wrapped], Return[wrapped]];
  ring = iATWriteKeyring[ring];
  If[FailureQ[ring], Return[ring]];
  dirs = iATKeyringDirs[];
  out = iATEncodeCode[r];
  If[useSink, sink[Join[out, <|"KeyId" -> d["KeyId"]|>]], iATShowSheet[out, d["KeyId"], dirs]];
  ClearAll[r, d, kp, out];
  <|"Status" -> "Created", "KeyId" -> ring["Recovery"]["KeyId"], "KeyringGeneration" -> ring["Generation"],
    "ReplacedWithoutOldPaper" -> (withOld === False),
    "Next" -> If[withOld === False,
      "紙を 2 部印刷して保管し、SourceVaultRecoveryDrill[] で確かめてください。古い紙が他の人の手にあるおそれがあれば、SourceVaultRotateClassKey で全部の鍵の組を交代させ、古い版の暗号文を書き直してください。",
      "紙を 2 部印刷して別々の場所に保管し、SourceVaultRecoveryDrill[] で紙から戻せることを確かめてください。"]|>];

(* 鍵 (enc / mac の組) を回復の公開鍵で包む → 台帳の Recovery の形 *)
iATWrapGroupForRecovery[label_String, refs_Association, pub_PublicKey, keyId_String] := Module[{w},
  w = NBAccess`NBWrapKeyRefsForPublicKey[Values[refs], pub];
  If[! AssociationQ[w] || ! AllTrue[Values[refs], KeyExistsQ[w, #] &],
    Return[iATFail["RecoveryWrapFailed", "鍵の組 " <> label <> " の鍵を回復の公開鍵で包めませんでした (鍵ストアに鍵がありません)。"]]];
  <|"KeyId" -> keyId,
    "EncWrappedB64" -> BaseEncode[BinarySerialize[w[refs["Enc"]]["Ciphertext"]]],
    "MacWrappedB64" -> BaseEncode[BinarySerialize[w[refs["Mac"]]["Ciphertext"]]],
    "WrappedAt" -> iATNowIso[]|>];

(* 紙から回復の秘密鍵を取り出す (検証つき)。戻り値の秘密鍵は呼び出し側の Module の中だけで使う。 *)
iATRecoveryPrivateKey[ring_Association, code_] := Module[{text, r, d, rec, ctBytes, ct, pk},
  rec = Lookup[ring, "Recovery", Null];
  If[! AssociationQ[rec], Return[iATFail["RecoveryKeyMissing", "台帳に紙の回復キーがありません。"]]];
  text = Which[StringQ[code], code, ListQ[code], StringRiffle[code, "\n"],
    True, iATAskCode["SourceVault 回復キー (鍵 ID " <> rec["KeyId"] <> ")"]];
  If[FailureQ[text], Return[text]];
  r = iATParseCode[text]; If[FailureQ[r], Return[r]];
  d = iATDerive[r];
  If[d["KeyId"] =!= rec["KeyId"],
    Return[iATFail["RecoveryKeyIdMismatch", "入力した回復キーは、この台帳の回復キー (鍵 ID " <> rec["KeyId"] <> ") と違います。"]]];
  ctBytes = BaseDecode[rec["WrappedPrivateKeyB64"]];
  If[! SourceVault`SourceVaultConstantTimeEqualQ[SourceVault`SourceVaultHMACSHA256Hex[d["MacKey"], ctBytes], rec["PrivateKeyMac"]],
    Return[iATFail["RecoveryPrivateKeyTampered", "台帳の回復の秘密鍵の MAC が合いません (台帳の改ざんか破損)。別の写しを試してください。"]]];
  ct = BinaryDeserialize[ctBytes];
  pk = Quiet @ Check[BinaryDeserialize[Decrypt[d["WrapKey"], ct]], $Failed];
  If[Head[pk] =!= PrivateKey, Return[iATFail["RecoveryDecryptFailed", "回復の秘密鍵を復号できませんでした。"]]];
  pk];

(* 台帳から「回復の受取人」の包みを NBUnwrapKeyRefsWithPrivateKey の形に *)
iATRecoveryWrapped[ring_Association] := Module[{out = <||>, rec = ring["Recovery"]},
  If[StringQ[Lookup[rec, "KeyringMacWrappedB64", Null]],
    out[$iATKeyringMacRef] = <|"Ciphertext" -> BinaryDeserialize[BaseDecode[rec["KeyringMacWrappedB64"]]],
      "Fingerprint" -> Lookup[rec, "KeyringMacFingerprint", Missing[]]|>];
  (* 今の版と退役した版の両方 (古い版の暗号文が残っている間は、その鍵も紙から戻せる必要がある) *)
  Scan[Function[e, Scan[Function[ks, Module[{rr = ks["Recovery"]},
        If[AssociationQ[rr] && rr["KeyId"] === rec["KeyId"],
          out[ks["Refs"]["Enc"]] = <|"Ciphertext" -> BinaryDeserialize[BaseDecode[rr["EncWrappedB64"]]], "Fingerprint" -> ks["EncFingerprint"]|>;
          out[ks["Refs"]["Mac"]] = <|"Ciphertext" -> BinaryDeserialize[BaseDecode[rr["MacWrappedB64"]]], "Fingerprint" -> ks["MacFingerprint"]|>]]],
      iATEntryKeySets[e]]],
    Values[Lookup[ring, "KeyGroups", <||>]]];
  out];

Options[SourceVaultRecoveryDrill] = {"Code" -> Automatic};
SourceVaultRecoveryDrill[OptionsPattern[]] := Module[{rd, ring, pk, wrapped, res, ok, missing},
  rd = iATReadKeyring[]; If[FailureQ[rd], Return[rd]];
  ring = rd["Ring"];
  pk = iATRecoveryPrivateKey[ring, OptionValue["Code"]]; If[FailureQ[pk], Return[pk]];
  wrapped = iATRecoveryWrapped[ring];
  res = NBAccess`NBUnwrapKeyRefsWithPrivateKey[wrapped, pk, "Verify"];
  ClearAll[pk];
  missing = Keys[Select[Lookup[ring, "KeyGroups", <||>], ! AllTrue[iATEntryKeySets[#], KeyExistsQ[wrapped, #["Refs"]["Enc"]] &] &]];
  ok = AssociationQ[res] && AllTrue[Values[res], #Status === "Verified" && #MatchesStore =!= False &] && missing === {};
  If[! ok,
    Return[iATFail["RecoveryDrillFailed",
      "訓練に失敗しました。紙から戻せない鍵があります。紙の回復キーを作り直す (SourceVaultCreateRecoveryKey[\"Replace\" -> True]) か、鍵の組を包み直してください。",
      <|"Results" -> If[AssociationQ[res], #Status & /@ res, res], "GroupsWithoutRecovery" -> missing|>]]];
  ring["Recovery", "DrillPassedAt"] = iATNowIso[];
  ring["Recovery", "DrillPassedOn"] = iATMachine[];
  (* 訓練で確かめた版を組ごとに記録する (時刻の比較は秒の精度で同じになりうるので使わない) *)
  Scan[(ring["KeyGroups", #, "DrillVerifiedVersion"] = iATEntryVersion[ring["KeyGroups", #]]) &, Keys[Lookup[ring, "KeyGroups", <||>]]];
  ring = iATWriteKeyring[ring];
  If[FailureQ[ring], Return[ring]];
  <|"Status" -> "Passed", "KeyId" -> ring["Recovery"]["KeyId"], "KeysChecked" -> Length[res],
    "DrillPassedAt" -> ring["Recovery"]["DrillPassedAt"]|>];

Options[SourceVaultRecoverKeys] = {"Code" -> Automatic};
SourceVaultRecoverKeys[OptionsPattern[]] := Module[{rd, ring, pk, wrapped, res, conflicts},
  rd = iATReadKeyring[True]; If[FailureQ[rd], Return[rd]];
  ring = rd["Ring"];
  pk = iATRecoveryPrivateKey[ring, OptionValue["Code"]]; If[FailureQ[pk], Return[pk]];
  wrapped = iATRecoveryWrapped[ring];
  res = NBAccess`NBUnwrapKeyRefsWithPrivateKey[wrapped, pk, "Import"];
  ClearAll[pk];
  If[! AssociationQ[res], Return[iATFail["RecoverFailed", "鍵を戻せませんでした。"]]];
  conflicts = Keys[Select[res, MemberQ[{"Conflict", "FingerprintMismatch", "DecryptFailed", "ImportFailed"}, #Status] &]];
  (* 台帳の MAC 鍵が戻ったので、検証できる形で書き直し、この機を OSCredential の受取人に加える *)
  If[conflicts === {},
    KeyValueMap[Function[{g, e},
        ring["KeyGroups", g, "Recipients", "OSCredential", "Machines"] =
          Union[Lookup[Lookup[Lookup[e, "Recipients", <||>], "OSCredential", <||>], "Machines", {}], {iATMachine[]}]],
      Lookup[ring, "KeyGroups", <||>]];
    ring = iATWriteKeyring[ring];
    If[FailureQ[ring], Return[ring]]];
  <|"Status" -> If[conflicts === {}, "Recovered", "RecoveredWithConflicts"],
    "Counts" -> Counts[Values[#Status & /@ res]], "Conflicts" -> Length[conflicts],
    "Next" -> If[conflicts === {}, "この機で暗号化したデータを読めます。", "鍵ストアに別の鍵がある鍵があり、上書きしていません。所有者が確かめてください。"]|>];

(* ------------------------------------------------------------
   鍵の組の鍵
   ------------------------------------------------------------ *)
SourceVaultEnsureClassKey[group_String] := Module[{rd, ring, refs, e, pub, w, encFp, macFp, rEnc, rMac, meta},
  If[! KeyExistsQ[$SourceVaultKeyGroups, group], Return[iATFail["UnknownKeyGroup", "鍵の組 " <> group <> " は表にありません。"]]];
  rd = iATReadKeyring[]; If[FailureQ[rd], Return[rd]];
  ring = rd["Ring"];
  e = Lookup[Lookup[ring, "KeyGroups", <||>], group, Null];
  refs = If[AssociationQ[e], iATEntryRefs[e], iATKeyRefs[group, 1]];
  If[AssociationQ[e],
    If[! (NBAccess`NBKeyMaterialExistsQ[refs["Enc"]] && NBAccess`NBKeyMaterialExistsQ[refs["Mac"]]),
      Return[iATFail["KeyMissing", "鍵の組 " <> group <> " は台帳にありますが、この機の鍵ストアに鍵がありません。作り直さずに、SourceVaultRecoverKeys[] で紙の回復キーから戻してください。"]]];
    If[iATFp[refs["Enc"]] =!= e["EncFingerprint"] || iATFp[refs["Mac"]] =!= e["MacFingerprint"],
      Return[iATFail["KeyFingerprintMismatch", "鍵の組 " <> group <> " の鍵の指紋が台帳と違います。鍵が別の値に置き換わっています。所有者が確かめてください。"]]];
    Return[<|"Status" -> "Exists", "KeyGroup" -> group|>]];
  If[! AssociationQ[ring["Recovery"]],
    Return[iATFail["RecoveryKeyMissing", "紙の回復キーがまだありません。先に SourceVaultCreateRecoveryKey[] (または SourceVaultAtRestSetup[]) で作ってください。回復の受取人が無い鍵は作りません。"]]];
  meta = <|"Owner" -> "SourceVault", "KeyGroup" -> group, "Tier" -> $SourceVaultKeyGroups[group]["Tier"]|>;
  rEnc = NBAccess`NBGenerateSymmetricKeyRef[refs["Enc"], Join[meta, <|"Purpose" -> "at-rest enc " <> group|>], "CreateOnly" -> True];
  rMac = NBAccess`NBGenerateMacKeyRef[refs["Mac"], Join[meta, <|"Purpose" -> "at-rest mac " <> group|>], "CreateOnly" -> True];
  If[! (NBAccess`NBKeyMaterialExistsQ[refs["Enc"]] && NBAccess`NBKeyMaterialExistsQ[refs["Mac"]]),
    Return[iATFail["KeyCreateFailed", "鍵の組 " <> group <> " の鍵を鍵ストアに書けませんでした。"]]];
  pub = BinaryDeserialize[BaseDecode[ring["Recovery"]["PublicKeyB64"]]];
  w = iATWrapGroupForRecovery[group, refs, pub, ring["Recovery"]["KeyId"]];
  If[FailureQ[w], Return[w]];
  encFp = iATFp[refs["Enc"]]; macFp = iATFp[refs["Mac"]];
  ring["KeyGroups", group] = <|"Tier" -> $SourceVaultKeyGroups[group]["Tier"], "KeyVersion" -> 1, "Retired" -> {},
    "EncKeyRef" -> refs["Enc"], "MacKeyRef" -> refs["Mac"], "EncFingerprint" -> encFp, "MacFingerprint" -> macFp,
    "CreatedAt" -> iATNowIso[], "CreatedOn" -> iATMachine[],
    "AdoptedExisting" -> (Lookup[rEnc, "Status", ""] === "Exists" || Lookup[rMac, "Status", ""] === "Exists"),
    "Recipients" -> <|"OSCredential" -> <|"Machines" -> {iATMachine[]}, "Temporary" -> ($SourceVaultKeyGroups[group]["Tier"] === 1)|>,
      "Recovery" -> w|>|>;
  ring = iATWriteKeyring[ring];
  If[FailureQ[ring], Return[ring]];
  <|"Status" -> "Created", "KeyGroup" -> group, "Tier" -> $SourceVaultKeyGroups[group]["Tier"],
    "Next" -> "紙の回復の訓練 (SourceVaultRecoveryDrill[]) に合格するまで、この鍵の組での暗号化の書き込みは動きません。"|>];

SourceVaultAtRestSetup[] := Module[{rd, ring, created = {}, rec},
  rd = iATReadKeyring[]; If[FailureQ[rd], Return[rd]];
  ring = rd["Ring"];
  If[! AssociationQ[ring["Recovery"]],
    rec = SourceVaultCreateRecoveryKey[];
    If[FailureQ[rec], Return[rec]]];
  Do[With[{r = SourceVaultEnsureClassKey[g]},
      If[FailureQ[r], Return[r, Module]];
      If[r["Status"] === "Created", AppendTo[created, g]]],
    {g, Keys[$SourceVaultKeyGroups]}];
  <|"Status" -> "KeysReady", "Created" -> created, "Ready" -> AllTrue[Keys[$SourceVaultKeyGroups], SourceVaultAtRestReadyQ],
    "Next" -> If[AllTrue[Keys[$SourceVaultKeyGroups], SourceVaultAtRestReadyQ], "準備は済んでいます。",
      "紙の回復キーを印刷・保管したら、SourceVaultRecoveryDrill[] で紙から戻せることを確かめてください。"]|>];

(* 書き込みの準備: 今の版の鍵がこの機にあり指紋が台帳と一致、今の版と退役した版がすべて今の紙で戻せ、
   今の版を作った後に訓練に合格している。<|Ready, Refs (今の版), Version|> *)
iATGroupState[group_String] := Module[{rd = iATReadKeyring[], ring, rec, e, sets},
  If[FailureQ[rd] || rd["Status"] =!= "OK", Return[<|"Ready" -> False, "Refs" -> Missing[], "Version" -> Missing[]|>]];
  ring = rd["Ring"]; rec = ring["Recovery"]; e = Lookup[Lookup[ring, "KeyGroups", <||>], group, Null];
  If[! AssociationQ[e], Return[<|"Ready" -> False, "Refs" -> Missing[], "Version" -> Missing[]|>]];
  sets = iATEntryKeySets[e];
  <|"Ready" -> TrueQ[AssociationQ[rec] && StringQ[Lookup[rec, "DrillPassedAt", Null]] &&
      AllTrue[sets, AssociationQ[#Recovery] && #Recovery["KeyId"] === rec["KeyId"] &] &&
      Lookup[e, "DrillVerifiedVersion", 0] === iATEntryVersion[e] && iATKeySetPresentQ[First[sets]]],
    "Refs" -> iATEntryRefs[e], "Version" -> iATEntryVersion[e]|>];

SourceVaultAtRestReadyQ[group_String] := TrueQ[iATGroupState[group]["Ready"]];

(* 確かさ (2026-11-14、比較レビュー 5 章の 1・4 を受けて): 段 1 の鍵は PRF に移すまで暫定で SystemCredential にある。
   その間は同じ Windows 利用者で動くプロセス (service・MCP のカーネル・エージェントのシェルを含む) が復号できる。
   今の暗号化が防ぐのは、Dropbox 社・同期先の機・写し (バックアップや版の履歴を除く) からの読み取りまで。 *)
$iATAssuranceNote = "段 1 の鍵は暫定で SystemCredential にあります (PRF に移すまで)。同じ Windows 利用者で動くプロセスは復号できます。防げるのは Dropbox 社・同期先・写しからの読み取りです。";
iATAssurance[e_Association] := Which[
  TrueQ[Lookup[Lookup[Lookup[e, "Recipients", <||>], "OSCredential", <||>], "Temporary", False]], "OSCredentialTemporary",
  KeyExistsQ[Lookup[e, "Recipients", <||>], "PRF"], "PRF",
  True, "OSCredential"];

SourceVaultAtRestStatus[] := Module[{rd = iATReadKeyring[], ring, rec, groups},
  If[FailureQ[rd], Return[rd]];
  ring = rd["Ring"]; rec = ring["Recovery"]; groups = Lookup[ring, "KeyGroups", <||>];
  <|"Keyring" -> <|"Status" -> rd["Status"], "Generation" -> ring["Generation"], "Floor" -> iATReadFloor[], "Copies" -> rd["Copies"]|>,
    "Recovery" -> If[AssociationQ[rec],
      Join[KeyTake[rec, {"KeyId", "CreatedAt", "CreatedOn", "DrillPassedAt", "DrillPassedOn"}],
        <|"Replaced" -> Length[Lookup[rec, "Replaced", {}]],
          "ReplacedWithoutOldPaper" -> Count[Lookup[rec, "Replaced", {}], _?(#["WithOldPaper"] === False &)]|>], "Missing"],
    "KeyGroups" -> Association[Function[g, Module[{e = Lookup[groups, g, Null]},
        g -> <|"Tier" -> $SourceVaultKeyGroups[g]["Tier"], "InKeyring" -> AssociationQ[e],
          "KeyVersion" -> If[AssociationQ[e], iATEntryVersion[e], Missing[]],
          "RetiredVersions" -> If[AssociationQ[e], Length[Lookup[e, "Retired", {}]], 0],
          "KeysOnThisMachine" -> (AssociationQ[e] && AllTrue[iATEntryKeySets[e], iATKeySetPresentQ]),
          "Assurance" -> If[AssociationQ[e], iATAssurance[e], Missing[]],
          "Ready" -> SourceVaultAtRestReadyQ[g], "Enforced" -> MemberQ[iATEnforcedGroups[], g]|>]] /@ Keys[$SourceVaultKeyGroups]],
    "AssuranceNote" -> If[AnyTrue[Values[groups], iATAssurance[#] === "OSCredentialTemporary" &], $iATAssuranceNote, None],
    "EnforcedGroups" -> Lookup[ring, "EnforcedGroups", {}], "EnforcedInThisKernel" -> $SourceVaultAtRestEnforce,
    "Maintenance" -> With[{m = iATMaintenanceInfo[]}, If[AssociationQ[m],
      <|"Machine" -> Lookup[m, "Machine", Missing[]], "StartedAt" -> Lookup[m, "StartedAt", Missing[]], "OwnedByThisKernel" -> (Lookup[m, "RunId", ""] === $iATMaintenanceRun)|>, None]],
    "Machine" -> iATMachine[]|>];

(* 鍵の交代 (2026-11-14): 新しい版の鍵を作って紙の回復で包み、今の版を Retired に移す。
   既存の暗号文は古い版のまま読める。SourceVaultAtRestReencryptFile で新しい版に書き直し、全部書き直したら
   古い版を外す (外す関数は後の段)。新しい版は訓練に合格するまで書き込みに使わない。
   使う場面: 段 1 の鍵を PRF に移すとき (SystemCredential に置いていた間の写しを無効にする)、紙が漏れたおそれがあるとき。 *)
SourceVaultRotateClassKey[group_String] := Module[{rd, ring, e, v, nv, refs, meta, pub, w, rEnc, rMac},
  If[! KeyExistsQ[$SourceVaultKeyGroups, group], Return[iATFail["UnknownKeyGroup", "鍵の組 " <> group <> " は表にありません。"]]];
  rd = iATReadKeyring[]; If[FailureQ[rd], Return[rd]];
  ring = rd["Ring"]; e = Lookup[Lookup[ring, "KeyGroups", <||>], group, Null];
  If[! AssociationQ[e], Return[iATFail["KeyGroupMissing", "鍵の組 " <> group <> " は台帳にありません。先に SourceVaultEnsureClassKey で作ってください。"]]];
  If[! AssociationQ[ring["Recovery"]], Return[iATFail["RecoveryKeyMissing", "紙の回復キーがありません。"]]];
  If[! AllTrue[iATEntryKeySets[e], iATKeySetPresentQ],
    Return[iATFail["KeyMissing", "鍵の組 " <> group <> " の今の版か退役した版の鍵が、この機に無いか指紋が違います。交代の前に SourceVaultRecoverKeys[] で戻してください。"]]];
  v = iATEntryVersion[e]; nv = Max[Append[Lookup[Lookup[e, "Retired", {}], "KeyVersion", {}], v]] + 1;
  refs = iATKeyRefs[group, nv];
  meta = <|"Owner" -> "SourceVault", "KeyGroup" -> group, "Tier" -> $SourceVaultKeyGroups[group]["Tier"], "KeyVersion" -> nv|>;
  rEnc = NBAccess`NBGenerateSymmetricKeyRef[refs["Enc"], Join[meta, <|"Purpose" -> "at-rest enc " <> group|>], "CreateOnly" -> True];
  rMac = NBAccess`NBGenerateMacKeyRef[refs["Mac"], Join[meta, <|"Purpose" -> "at-rest mac " <> group|>], "CreateOnly" -> True];
  If[! (NBAccess`NBKeyMaterialExistsQ[refs["Enc"]] && NBAccess`NBKeyMaterialExistsQ[refs["Mac"]]),
    Return[iATFail["KeyCreateFailed", "新しい版の鍵を鍵ストアに書けませんでした。"]]];
  pub = BinaryDeserialize[BaseDecode[ring["Recovery"]["PublicKeyB64"]]];
  w = iATWrapGroupForRecovery[group <> " v" <> ToString[nv], refs, pub, ring["Recovery"]["KeyId"]];
  If[FailureQ[w], Return[w]];
  ring["KeyGroups", group] = Join[e, <|
    "KeyVersion" -> nv, "EncKeyRef" -> refs["Enc"], "MacKeyRef" -> refs["Mac"],
    "EncFingerprint" -> iATFp[refs["Enc"]], "MacFingerprint" -> iATFp[refs["Mac"]],
    "CreatedAt" -> iATNowIso[], "CreatedOn" -> iATMachine[],
    "AdoptedExisting" -> (Lookup[rEnc, "Status", ""] === "Exists" || Lookup[rMac, "Status", ""] === "Exists"),
    "Recipients" -> Join[Lookup[e, "Recipients", <||>], <|"Recovery" -> w,
      "OSCredential" -> <|"Machines" -> {iATMachine[]}, "Temporary" -> ($SourceVaultKeyGroups[group]["Tier"] === 1)|>|>],
    "Retired" -> Append[Lookup[e, "Retired", {}], <|"KeyVersion" -> v, "EncKeyRef" -> e["EncKeyRef"], "MacKeyRef" -> e["MacKeyRef"],
      "EncFingerprint" -> e["EncFingerprint"], "MacFingerprint" -> e["MacFingerprint"],
      "Recovery" -> Lookup[Lookup[e, "Recipients", <||>], "Recovery", Null], "CreatedAt" -> e["CreatedAt"], "RetiredAt" -> iATNowIso[]|>]|>];
  ring = iATWriteKeyring[ring];
  If[FailureQ[ring], Return[ring]];
  <|"Status" -> "Rotated", "KeyGroup" -> group, "KeyVersion" -> nv, "RetiredVersion" -> v,
    "Next" -> "SourceVaultRecoveryDrill[] に合格すると新しい版で書けるようになります。その後、古い版の暗号文を SourceVaultAtRestReencryptFile で書き直してください。"|>];

(* ------------------------------------------------------------
   SVEF v1
   ------------------------------------------------------------ *)
$iATMagic = ByteArray[{83, 86, 69, 70, 1, 0}];   (* "SVEF" 01 00 *)

iATMediaType[path_String] := Switch[ToLowerCase[FileExtension[path]],
  "json", "application/json", "wxf", "application/vnd.wolfram.wxf", "png", "image/png", "pdf", "application/pdf",
  "jsonl", "application/jsonl", "blob", "application/octet-stream", _, "application/octet-stream"];

iATEncodeSVEF[plain_ByteArray, header0_Association, encRef_String, macRef_String] := Module[{enc, ct, header, hb, pre, macIn, mac},
  enc = iATKeyRetry[NBAccess`NBEncryptWithKeyRef[encRef, plain] &];
  If[! AssociationQ[enc] || ! StringQ[enc["CiphertextB64"]], Return[iATFail["SVEFEncryptFailed", "暗号化に失敗しました (鍵がありません)。"]]];
  ct = BaseDecode[enc["CiphertextB64"]];
  header = Join[header0, <|"SVEF" -> 1, "EncKeyRef" -> encRef, "MacKeyRef" -> macRef,
    "KeyFingerprint" -> iATFp[encRef],
    "PlaintextLength" -> Length[plain], "CiphertextLength" -> Length[ct], "CreatedAtUTC" -> iATNowIso[]|>];
  hb = iATCJson[header];
  pre = Join[$iATMagic, iATU32[Length[hb]]];
  macIn = Join[pre, hb, iATU32[Length[ct]], iATSha256[ct]];
  mac = iATMacHex[macRef, macIn];
  If[! StringQ[mac], Return[iATFail["SVEFMacFailed", "MAC を計算できませんでした (鍵がありません)。"]]];
  Join[pre, hb, iATU32[Length[ct]], ct, iATHexToBytes[mac]]];

(* bytes → <|Header, Bytes|> または Failure。expectedLogical が文字列なら LogicalPath と照合する。 *)
(* decrypt -> False は MAC と論理パスの検証だけ (上書きの前の確認用、復号しない) *)
iATDecodeSVEF[bytes_ByteArray, expectedLogical_, decrypt_ : True] := Module[{n = Length[bytes], hlen, hb, header, clen, ctStart, ct, mac, macIn, group, refs, plain, ver},
  If[n < 46 || bytes[[1 ;; 6]] =!= $iATMagic, Return[iATFail["SVEFBadFormat", "SVEF の形式ではありません。"]]];
  hlen = iATReadU32[bytes, 7];
  If[10 + hlen + 4 + 32 > n, Return[iATFail["SVEFTruncated", "SVEF のファイルが途中で切れています。"]]];
  hb = bytes[[11 ;; 10 + hlen]];
  header = Quiet @ Check[ImportByteArray[hb, "RawJSON"], $Failed];
  If[! AssociationQ[header], Return[iATFail["SVEFBadHeader", "SVEF の見出しを読めません。"]]];
  clen = iATReadU32[bytes, 11 + hlen];
  ctStart = 15 + hlen;
  If[ctStart + clen - 1 + 32 =!= n, Return[iATFail["SVEFTruncated", "SVEF のファイルの長さが合いません。"]]];
  ct = bytes[[ctStart ;; ctStart + clen - 1]];
  mac = bytes[[n - 31 ;; n]];
  (* 鍵の名前は見出しの値をそのまま信じず、分類表の鍵の組から導いた名前と一致することを確かめる *)
  group = Lookup[header, "KeyGroup", Null];
  If[! StringQ[group] || ! KeyExistsQ[$SourceVaultKeyGroups, group], Return[iATFail["SVEFUnknownKeyGroup", "SVEF の鍵の組が表にありません。"]]];
  (* 版は見出しの鍵の名前から読むが、名前は鍵の組と版から導いた形と完全に一致しなければならない (別の組の鍵は使わない) *)
  ver = StringCases[ToString[Lookup[header, "EncKeyRef", ""]],
    StartOfString ~~ "SourceVault:dek:v" ~~ d : DigitCharacter .. ~~ ":" ~~ group ~~ ":enc" ~~ EndOfString :> FromDigits[d]];
  If[ver === {}, Return[iATFail["SVEFKeyRefMismatch", "SVEF の鍵の名前が鍵の組と一致しません。"]]];
  refs = iATKeyRefs[group, First[ver]];
  If[header["EncKeyRef"] =!= refs["Enc"] || header["MacKeyRef"] =!= refs["Mac"], Return[iATFail["SVEFKeyRefMismatch", "SVEF の鍵の名前が鍵の組と一致しません。"]]];
  If[iATKeyRetry[If[NBAccess`NBKeyMaterialExistsQ[refs["Mac"]], True, $Failed] &] =!= True,
    Return[iATFail["KeyUnavailable", "この機に鍵の組 " <> group <> " (版 " <> ToString[First[ver]] <> ") の鍵がありません。SourceVaultRecoverKeys[] で戻すか、鍵のある機で読んでください。"]]];
  macIn = Join[bytes[[1 ;; 10]], hb, iATU32[clen], iATSha256[ct]];
  (* 鍵が読み出せないとき (一時的な失敗) は KeyUnavailable、読めて合わないときだけ MacMismatch *)
  With[{calc = iATMacHex[refs["Mac"], macIn]},
    If[! StringQ[calc],
      Return[iATFail["KeyUnavailable", "鍵の組 " <> group <> " の MAC 鍵を読み出せませんでした (一時的な失敗のおそれ)。少し待ってからやり直してください。"]]];
    If[! SourceVault`SourceVaultConstantTimeEqualQ[calc, iATBytesToHex[mac]], Return[iATFail["SVEFMacMismatch", "SVEF の MAC が合いません (改ざんか破損、または別の鍵)。"]]]];
  If[StringQ[expectedLogical] && ToLowerCase[Lookup[header, "LogicalPath", ""]] =!= ToLowerCase[expectedLogical],
    Return[iATFail["SVEFPathMismatch", "SVEF の論理パスが置き場所と一致しません (ファイルの入れ替え)。"]]];
  If[! TrueQ[decrypt], Return[<|"Header" -> header, "KeyVersion" -> First[ver]|>]];
  plain = iATKeyRetry[NBAccess`NBDecryptWithKeyRef[refs["Enc"], BaseEncode[ct]] &];
  If[Head[plain] =!= ByteArray || Length[plain] =!= Lookup[header, "PlaintextLength", -1],
    Return[iATFail["SVEFDecryptFailed", "SVEF を復号できませんでした。"]]];
  <|"Header" -> header, "Bytes" -> plain, "KeyVersion" -> First[ver]|>];

(* ------------------------------------------------------------
   保護した読み書き
   ------------------------------------------------------------ *)
iATSve[path_String] := path <> ".sve";
If[! IntegerQ[$iATLegacyReads], $iATLegacyReads = 0];

iATPlainNewerQ[path_String] := FileExistsQ[path] && FileExistsQ[iATSve[path]] &&
  TrueQ[Quiet @ Check[AbsoluteTime[FileDate[path, "Modification"]] > AbsoluteTime[FileDate[iATSve[path], "Modification"]], False]];

(* 上書きされるファイル (course の WXF など) を守る規則 (2026-11-14):
   - 既にある暗号文が検証できない (鍵が無い・改ざん・別の鍵) なら上書きしない (ExistingUnverifiable)。
     読めなかった内容を「空」とみなして書き戻す事故を防ぐ。
   - 平文の方が新しい (SplitBrain) なら書かない。どちらが正しいか所有者が決める。
   移行の道具だけが "AllowSplitBrain" / "OverwriteUnverifiable" を使う。 *)
Options[SourceVaultAtRestWriteBytes] = {"PL" -> Automatic, "DeletePlaintext" -> True,
  "AllowSplitBrain" -> False, "OverwriteUnverifiable" -> False};
SourceVaultAtRestWriteBytes[path_String, bytes_ByteArray, classId_String, OptionsPattern[]] := Module[
  {ci, st, pl, tier, group, refs, gs},
  ci = SourceVaultAtRestClassInfo[classId];
  If[! TrueQ[ci["Registered"]], Return[iATFail["UnclassifiedClass", "分類 " <> classId <> " は分類表にありません。暗号化の書き込みには分類表への登録が要ります。"]]];
  If[iATMaintenanceForeignQ[],
    Return[iATFail["StoreLocked", "移行の作業中 (MAINTENANCE.json) なので書きません。作業が終わってからやり直してください。"]]];
  group = ci["KeyGroup"];
  st = SourceVaultAtRestStoreOf[path];
  pl = Max[ci["PL"], If[NumericQ[OptionValue["PL"]], OptionValue["PL"], 0]];
  tier = SourceVaultAtRestTier[pl, st["AccessLevel"]];
  gs = iATGroupState[group];
  If[! TrueQ[gs["Ready"]],
    Return[iATFail["AtRestNotReady",
      "鍵の組 " <> group <> " の暗号化の準備ができていません (鍵・紙の回復・訓練のどれかが未了)。SourceVaultAtRestStatus[] で確かめ、SourceVaultAtRestSetup[] と SourceVaultRecoveryDrill[] を済ませてください。平文では書きません。"]]];
  refs = gs["Refs"];  (* 今の版の鍵で書く *)
  iATWithLock[path,
    Module[{target = iATSve[path], tmp, enc, back, dec, cur},
      If[iATPlainNewerQ[path] && ! TrueQ[OptionValue["AllowSplitBrain"]],
        Return[iATFail["SplitBrain", "平文と暗号文の両方があり、平文の方が新しいので書きません。どちらが正しいか所有者が確かめてください。"], Module]];
      If[FileExistsQ[target] && ! TrueQ[OptionValue["OverwriteUnverifiable"]],
        cur = Quiet @ Check[iATReadFile[target], $Failed];
        cur = If[ByteArrayQ[cur], iATDecodeSVEF[cur, st["LogicalPath"], False], iATFail["AtRestReadFailed", "既存の暗号文を読めません。"]];
        If[FailureQ[cur],
          Return[iATFail["ExistingUnverifiable",
            "既にある暗号文を検証できないので上書きしません (この機に鍵が無い・改ざん・別の鍵)。元のファイルはそのままです。",
            <|"Reason" -> cur[[1]]|>], Module]]];
      enc = iATEncodeSVEF[bytes,
        <|"Store" -> st["Store"], "LogicalPath" -> st["LogicalPath"], "ClassId" -> classId, "KeyGroup" -> group,
          "Tier" -> tier, "PL" -> ToString[pl], "PLProvenance" -> ci["Provenance"], "MediaType" -> iATMediaType[path]|>,
        refs["Enc"], refs["Mac"]];
      If[FailureQ[enc], Return[enc, Module]];
      iATEnsureDir[DirectoryName[target]];
      tmp = target <> ".tmp." <> IntegerString[RandomInteger[{0, 36^8 - 1}], 36, 8];
      If[iATWriteBytesFile[tmp, enc] === $Failed, Return[iATFail["AtRestWriteFailed", "一時ファイルを書けませんでした。"], Module]];
      back = Quiet @ Check[iATReadFile[tmp], $Failed];
      dec = If[Head[back] === ByteArray, iATDecodeSVEF[back, st["LogicalPath"]], $Failed];
      If[! AssociationQ[dec] || dec["Bytes"] =!= bytes,
        Quiet @ DeleteFile[tmp];
        Return[iATFail["AtRestVerifyFailed", "書いた暗号文を読み直して検証できませんでした。元のファイルはそのままです。"], Module]];
      If[! iATRenameRetry[tmp, target],
        Quiet @ DeleteFile[tmp];
        Return[iATFail["AtRestRenameFailed", "暗号文を置き換えられませんでした。元のファイルはそのままです。"], Module]];
      If[TrueQ[OptionValue["DeletePlaintext"]] && FileExistsQ[path], Quiet @ DeleteFile[path]];
      <|"Status" -> "Encrypted", "Tier" -> tier, "KeyGroup" -> group, "KeyVersion" -> gs["Version"], "Bytes" -> Length[bytes],
        "PlaintextRemains" -> FileExistsQ[path]|>]]];

(* 古い版の鍵で暗号化したファイルを今の版で書き直す (鍵の交代の後)。中身は変えない。 *)
SourceVaultAtRestReencryptFile[path_String] := Module[{sve = iATSve[path], bytes, dec, hdr, gs, w},
  If[! FileExistsQ[sve], Return[iATFail["NotEncrypted", "暗号化したファイル (.sve) がありません。"]]];
  bytes = Quiet @ Check[iATReadFile[sve], $Failed];
  If[! ByteArrayQ[bytes], Return[iATFail["AtRestReadFailed", "暗号文を読めませんでした。"]]];
  dec = iATDecodeSVEF[bytes, SourceVaultAtRestStoreOf[path]["LogicalPath"]];
  If[FailureQ[dec], Return[dec]];
  hdr = dec["Header"];
  gs = iATGroupState[hdr["KeyGroup"]];
  If[gs["Version"] === dec["KeyVersion"], Return[<|"Status" -> "Current", "KeyVersion" -> dec["KeyVersion"]|>]];
  w = SourceVaultAtRestWriteBytes[path, dec["Bytes"], hdr["ClassId"],
    "PL" -> With[{v = Quiet @ Check[ImportString[ToString[Lookup[hdr, "PL", ""]], "RawJSON"], $Failed]}, If[NumericQ[v], v, Automatic]]];
  If[FailureQ[w], w, <|"Status" -> "Reencrypted", "From" -> dec["KeyVersion"], "To" -> w["KeyVersion"]|>]];

SourceVaultAtRestReadBytes[path_String] := Module[{sve = iATSve[path], pE, eE, bytes, st, dec},
  pE = FileExistsQ[path]; eE = FileExistsQ[sve];
  Which[
    eE,
      If[pE && Quiet @ Check[AbsoluteTime[FileDate[path, "Modification"]] > AbsoluteTime[FileDate[sve, "Modification"]], False],
        Return[iATFail["SplitBrain", "平文と暗号文の両方があり、平文の方が新しいです。どちらが正しいか所有者が確かめてください (移行の途中か、古いコードが平文を書いた)。"]]];
      bytes = Quiet @ Check[iATReadFile[sve], $Failed];
      If[Head[bytes] =!= ByteArray, Return[iATFail["AtRestReadFailed", "暗号文を読めませんでした。"]]];
      st = SourceVaultAtRestStoreOf[path];
      dec = iATDecodeSVEF[bytes, st["LogicalPath"]];
      If[FailureQ[dec], dec, dec["Bytes"]],
    pE,
      $iATLegacyReads++;
      Quiet @ Check[iATReadFile[path], $Failed],
    True, Missing["NotFound"]]];

SourceVaultAtRestFileExistsQ[path_String] := FileExistsQ[path] || FileExistsQ[iATSve[path]];

(* パス → 分類 (分類表にあるものだけ)。LocalState と不明な場所は Missing。 *)
SourceVaultAtRestClassOfPath[path_String] := Module[{st = SourceVaultAtRestStoreOf[path], cls},
  If[MemberQ[{"Unknown", "LocalState"}, st["Store"]], Return[Missing["NotInStore"]]];
  cls = iATClassOfFile[st["Store"], StringReplace[st["LogicalPath"], RegularExpression["\\.sve$"] -> ""]];
  If[StringQ[cls] && KeyExistsQ[$SourceVaultClassPrivacyRegistry, cls], cls, Missing["Unclassified"]]];

SourceVaultAtRestFileNames[pattern_, dir_, levels_ : 1] := Module[{fs},
  fs = Join[FileNames[pattern, dir, levels], FileNames[If[StringQ[pattern], pattern <> ".sve", pattern ~~ ".sve"], dir, levels]];
  fs = Select[fs, ! StringContainsQ[FileNameTake[#], ".tmp."] &];
  DeleteDuplicates[StringReplace[#, RegularExpression["\\.sve$"] -> ""] & /@ fs]];

SourceVaultAtRestDeleteFile[path_String] := Module[{r = {}},
  If[FileExistsQ[path], AppendTo[r, Quiet @ Check[DeleteFile[path]; True, False]]];
  If[FileExistsQ[iATSve[path]], AppendTo[r, Quiet @ Check[DeleteFile[iATSve[path]]; True, False]]];
  AllTrue[r, TrueQ]];

(* ------------------------------------------------------------
   試しの集計 (件数だけ)
   ------------------------------------------------------------ *)
iATClassOfFile[store_String, logical_String] := Module[{parts = StringSplit[logical, "/"]},
  Which[
    store === "WebReports", "WebReport",
    Length[parts] >= 2 && parts[[1]] === "snapshots", parts[[2]],
    Length[parts] >= 1 && parts[[1]] === "blobs", "Blob",
    Length[parts] >= 2 && parts[[1 ;; 2]] === {"exercises", "exams"},
      If[StringContainsQ[logical, "-grading.wxf"] || StringContainsQ[logical, "-scans/"], "ExamGrading", "ExerciseOther"],
    Length[parts] >= 2 && parts[[1]] === "coursereports",
      Switch[parts[[2]], "gradebook", "CourseGradebook", "summarygrades", "CourseSummaryGrades",
        "enrollment", "CourseEnrollment", "rosters", "CourseRoster", _, "CourseOther"],
    True, Missing[]]];

(* 保管先 (PrivateVault の snapshots・blobs・exercises/exams・coursereports と webreports) のファイルを、論理名 (.sve を外した名前) ごとに
   <|Path, Class, Store, Plain, Encrypted, PlainBytes, EncryptedBytes|> にまとめる。一時ファイル (.tmp.) は別に数える。 *)
iATItems[] := Module[{stores, files, tmp, rest, groups},
  stores = Select[iATStores[], #Store =!= "LocalState" &];
  files = DeleteDuplicates @ Flatten @ Map[Function[s,
      Map[Function[d, If[DirectoryQ[d], Select[FileNames["*", d, Infinity], ! DirectoryQ[#] &], {}]],
        If[s["Store"] === "WebReports", {s["Root"]},
          FileNameJoin[{s["Root"], #}] & /@ {"snapshots", "blobs", FileNameJoin[{"exercises", "exams"}], "coursereports"}]]],
    stores];
  tmp = Select[files, StringContainsQ[FileNameTake[#], ".tmp."] &];
  rest = Complement[files, tmp];
  groups = GroupBy[rest, StringReplace[#, RegularExpression["\\.sve$"] -> ""] &];
  {KeyValueMap[Function[{lp, fs}, Module[{st = SourceVaultAtRestStoreOf[lp]},
      <|"Path" -> lp, "Class" -> iATClassOfFile[st["Store"], st["LogicalPath"]], "Store" -> st["Store"],
        "Plain" -> MemberQ[fs, lp], "Encrypted" -> MemberQ[fs, lp <> ".sve"],
        "PlainBytes" -> If[MemberQ[fs, lp], Quiet @ Check[FileByteCount[lp], 0], 0],
        "EncryptedBytes" -> If[MemberQ[fs, lp <> ".sve"], Quiet @ Check[FileByteCount[lp <> ".sve"], 0], 0]|>]], groups],
   Map[Function[f, With[{st = SourceVaultAtRestStoreOf[StringReplace[f, RegularExpression["\\.(sve\\.)?tmp\\..*$"] -> ""]]},
       iATClassOfFile[st["Store"], st["LogicalPath"]]]], tmp]}];

SourceVaultAtRestInventory[] := Module[{items, tmpClasses, enforced = iATEnforcedGroups[]},
  {items, tmpClasses} = iATItems[];
  items = Select[items, StringQ[#Class] &];
  Association[KeyValueMap[Function[{cls, its}, Module[{ci = SourceVaultAtRestClassInfo[cls]},
      cls -> <|"Plain" -> Count[its, _?(#Plain &)], "Encrypted" -> Count[its, _?(#Encrypted &)],
        "Both" -> Count[its, _?(#Plain && #Encrypted &)], "Tmp" -> Count[tmpClasses, cls],
        "PlainBytes" -> Total[its[[All, "PlainBytes"]]], "EncryptedBytes" -> Total[its[[All, "EncryptedBytes"]]],
        "Registered" -> ci["Registered"], "KeyGroup" -> ci["KeyGroup"], "PL" -> ci["PL"],
        "Tier" -> SourceVaultAtRestTier[ci["PL"], 0.5],
        "Enforced" -> (StringQ[ci["KeyGroup"]] && MemberQ[enforced, ci["KeyGroup"]])|>]],
    GroupBy[items, #Class &]]]];

(* ------------------------------------------------------------
   段 5: 移行 (2026-11-14)
   - 既定は試し (DryRun)。件数と理由のコードだけを返し、パスやハッシュは返さない (細目は LocalState の日誌だけ)。
   - 本番の前提: 鍵の組の準備 (訓練の合格)、D: のバックアップの目録 (自己ハッシュの一致)、FE で実行。
   - 平文を暗号化する前に、平文の SHA-256 がバックアップの目録と一致することを確かめる (戻す道を持たないファイルは移さない)。
   - 1 件ずつディスクの状態で決めるので、途中で止まっても同じ呼び出しをやり直せばよい。
   - 移行中は MAINTENANCE.json で他のカーネルの書き込みを止め、移す組を台帳の EnforcedGroups に入れて新しい書き込みも暗号化させる。
   - 鍵はどこでも消さない。
   ------------------------------------------------------------ *)
iATBackupKey[p_String, udbRoot_String] := With[{r = StringTrim[udbRoot, "\\"]},
  If[StringStartsQ[ToLowerCase[p], ToLowerCase[r] <> "\\"], ToLowerCase["udb\\" <> StringDrop[p, StringLength[r] + 1]], Missing[]]];

iATUdbRoot[] := Module[{pv = iATRootValue["PrivateVault"], core = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed], base},
  base = Which[StringQ[pv], pv, StringQ[core], core, True, Missing[]];
  If[StringQ[base], StringTrim[DirectoryName[StringTrim[base, "\\"]], "\\"], Missing[]]];

(* D: のバックアップの目録 (sv_backup.ps1 の MANIFEST.sha256) を読む。学生・成績の場所の行だけを <|小文字の相対パス -> sha256|> に。 *)
iATLoadBackup[mf0_, root_String] := Module[{mf = mf0, dirs, bytes, selfFile, selfOk, lines, keep, man},
  If[mf === Automatic,
    dirs = If[DirectoryQ[root], Select[FileNames["*", root], DirectoryQ[#] && FileExistsQ[FileNameJoin[{#, "MANIFEST.sha256"}]] &], {}];
    If[dirs === {}, Return[iATFail["BackupMissing", "バックアップの目録 (MANIFEST.sha256) が見つかりません。D: を挿して解錠してください。"]]];
    mf = FileNameJoin[{Last[Sort[dirs]], "MANIFEST.sha256"}]];
  If[! StringQ[mf] || ! FileExistsQ[mf], Return[iATFail["BackupMissing", "バックアップの目録が見つかりません。"]]];
  bytes = Quiet @ Check[iATReadFile[mf], $Failed];
  If[! ByteArrayQ[bytes], Return[iATFail["BackupUnreadable", "バックアップの目録を読めません。"]]];
  selfFile = mf <> ".sha256";
  selfOk = FileExistsQ[selfFile] && ToLowerCase[StringTrim[ByteArrayToString[iATReadFile[selfFile], "ISO8859-1"]]] === ToLowerCase[Hash[bytes, "SHA256", "HexString"]];
  If[! selfOk, Return[iATFail["BackupManifestTampered", "バックアップの目録の自己ハッシュが合いません。目録が書き換えられたか、壊れています。"]]];
  lines = StringSplit[ByteArrayToString[bytes, "UTF-8"], {"\r\n", "\n"}];
  keep = Select[lines, StringLength[#] > 66 && StringStartsQ[StringDrop[#, 66], "udb\\"] &&
      StringContainsQ[#, {"\\snapshots\\", "\\blobs\\", "\\exercises\\exams\\", "\\coursereports\\", "udb\\webreports\\"}] &];
  man = Association[ToLowerCase[StringDrop[#, 66]] -> ToLowerCase[StringTake[#, 64]] & /@ keep];
  <|"Stamp" -> FileNameTake[DirectoryName[mf]], "Entries" -> Length[lines], "Relevant" -> Length[man], "SelfHashOK" -> True, "Map" -> man|>];

iATSha256Hex[b_ByteArray] := ToLowerCase[Hash[b, "SHA256", "HexString"]];

iATBeginMaintenance[runId_String, what_] := Module[{p = iATMaintPath[], cur = iATMaintenanceInfo[]},
  If[! StringQ[p], Return[iATFail["KeyringNoLocation", "PrivateVault が解決できません。"]]];
  If[AssociationQ[cur] && Lookup[cur, "RunId", ""] =!= runId,
    Return[iATFail["StoreLocked", "別の移行の作業 (MAINTENANCE.json) が残っています。終わっていなければ待ち、残骸なら SourceVaultAtRestEndMaintenance[\"Force\" -> True] で外してください。"]]];
  If[iATAtomicWrite[p, ExportByteArray[<|"RunId" -> runId, "Machine" -> iATMachine[], "ProcessID" -> $ProcessID,
      "StartedAt" -> iATNowIso[], "Work" -> what|>, "RawJSON"]] === $Failed,
    Return[iATFail["MaintenanceWriteFailed", "MAINTENANCE.json を書けませんでした。"]]];
  $iATMaintenanceRun = runId;
  runId];

iATEndMaintenance[runId_String] := Module[{p = iATMaintPath[], cur = iATMaintenanceInfo[]},
  If[StringQ[p] && AssociationQ[cur] && Lookup[cur, "RunId", ""] === runId, Quiet @ DeleteFile[p]];
  $iATMaintenanceRun = None;];

Options[SourceVaultAtRestEndMaintenance] = {"Force" -> False};
SourceVaultAtRestEndMaintenance[OptionsPattern[]] := Module[{p = iATMaintPath[], cur = iATMaintenanceInfo[]},
  If[! AssociationQ[cur], Return[<|"Status" -> "NotLocked"|>]];
  If[Lookup[cur, "RunId", ""] =!= $iATMaintenanceRun && ! TrueQ[OptionValue["Force"]],
    Return[iATFail["NotOwner", "このカーネルが始めた作業ではありません。残骸と確かめたら \"Force\" -> True を付けてください。",
      <|"Machine" -> Lookup[cur, "Machine", Missing[]], "StartedAt" -> Lookup[cur, "StartedAt", Missing[]]|>]]];
  Quiet @ DeleteFile[p]; $iATMaintenanceRun = None;
  <|"Status" -> "Unlocked"|>];

(* 台帳の EnforcedGroups を変える (全部の機と service に効く)。足す組は準備 (訓練の合格) が済んでいること。 *)
Options[SourceVaultAtRestSetEnforced] = {"Mode" -> "Add"};
SourceVaultAtRestSetEnforced[groups_List, OptionsPattern[]] := Module[{rd, ring, cur, new, bad, notReady},
  bad = Complement[groups, Keys[$SourceVaultKeyGroups]];
  If[bad =!= {}, Return[iATFail["UnknownKeyGroup", "表に無い鍵の組があります: " <> StringRiffle[bad, ", "]]]];
  rd = iATReadKeyring[]; If[FailureQ[rd], Return[rd]];
  ring = rd["Ring"]; cur = Lookup[ring, "EnforcedGroups", {}];
  new = Switch[OptionValue["Mode"], "Add", Union[cur, groups], "Remove", Complement[cur, groups], "Set", Union[groups],
    _, Return[iATFail["BadMode", "Mode は Add / Remove / Set です。"]]];
  notReady = Select[Complement[new, cur], ! SourceVaultAtRestReadyQ[#] &];
  If[notReady =!= {},
    Return[iATFail["AtRestNotReady", "準備 (鍵・紙の回復・訓練) が済んでいない組は強制にできません: " <> StringRiffle[notReady, ", "]]]];
  If[new =!= cur,
    ring["EnforcedGroups"] = new;
    ring = iATWriteKeyring[ring];
    If[FailureQ[ring], Return[ring]]];
  iATResetEnforcedCache[];
  <|"Status" -> "OK", "EnforcedGroups" -> new|>];

iATJournal[path_String, rec_Association] := Quiet @ Check[
  Module[{s}, iATEnsureDir[DirectoryName[path]];
    s = OpenAppend[path, CharacterEncoding -> "UTF-8"];
    WithCleanup[WriteString[s, ExportString[rec, "RawJSON", "Compact" -> True] <> "\n"], Close[s]]], Null];

iATQuarantine[sve_String, runId_String] := Module[{d = FileNameJoin[{iATLocalStateDir[], "atrest", "quarantine", runId}], dst},
  iATEnsureDir[d];
  dst = FileNameJoin[{d, StringTake[Hash[sve, "SHA256", "HexString"], 24] <> ".sve"}];
  If[iATRenameRetry[sve, dst], dst, $Failed]];

(* 1 件の移行。戻り値は理由のコード (文字列) *)
iATMigrateOne[it_Association, man_, dry_, runId_String, udbRoot_] := Module[{p = it["Path"], sve = it["Path"] <> ".sve", pE, eE, bytes, h, key, info0, w, dec, plain, q},
  pE = FileExistsQ[p]; eE = FileExistsQ[sve];
  Which[
    pE && eE,
      dec = With[{b = Quiet @ Check[iATReadFile[sve], $Failed]},
        If[ByteArrayQ[b], iATDecodeSVEF[b, SourceVaultAtRestStoreOf[p]["LogicalPath"]], iATFail["AtRestReadFailed", ""]]];
      plain = Quiet @ Check[iATReadFile[p], $Failed];
      Which[
        ! ByteArrayQ[plain], "Unreadable",
        FailureQ[dec] && dec[[1]] === "KeyUnavailable", "KeyUnavailable",   (* 鍵が読めないだけなら隔離しない *)
        FailureQ[dec],
          If[dry, Return["WouldQuarantineAndEncrypt", Module]];
          q = iATQuarantine[sve, runId];
          If[q === $Failed, Return["QuarantineFailed", Module]];
          iATMigrateOne[it, man, dry, runId, udbRoot] /. s_String :> "Quarantined+" <> s,
        dec["Bytes"] === plain, If[dry, "WouldCleanDuplicate", If[iATDeleteRetry[p], "CleanedDuplicate", "DeleteFailed"]],
        iATPlainNewerQ[p], "SplitBrain",
        True, "BothDiffer"],
    pE && Quiet @ Check[FileByteCount[p], -1] === 0, "EmptyFile",
    pE,
      bytes = Quiet @ Check[iATReadFile[p], $Failed];
      If[! ByteArrayQ[bytes], Return["Unreadable", Module]];
      If[AssociationQ[man],
        key = If[StringQ[udbRoot], iATBackupKey[p, udbRoot], Missing[]];
        h = Lookup[man["Map"], key, Missing[]];
        If[! StringQ[h], Return["NotInBackup", Module]];
        If[h =!= iATSha256Hex[bytes], Return["ChangedSinceBackup", Module]]];
      If[dry, Return["WouldEncrypt", Module]];
      info0 = {FileByteCount[p], FileDate[p, "Modification"]};
      w = SourceVaultAtRestWriteBytes[p, bytes, it["Class"], "DeletePlaintext" -> False];
      If[FailureQ[w], Return["WriteFailed:" <> ToString[w[[1]]], Module]];
      If[{FileByteCount[p], FileDate[p, "Modification"]} === info0 && Quiet @ Check[iATReadFile[p], $Failed] === bytes,
        If[iATDeleteRetry[p], "Encrypted", "EncryptedPlainNotDeleted"],
        Quiet @ DeleteFile[sve]; "PlainChangedDuringMigration"],
    eE,
      dec = With[{b = Quiet @ Check[iATReadFile[sve], $Failed]},
        If[ByteArrayQ[b], iATDecodeSVEF[b, SourceVaultAtRestStoreOf[p]["LogicalPath"]], iATFail["AtRestReadFailed", ""]]];
      If[FailureQ[dec], "EncryptedInvalid:" <> ToString[dec[[1]]], "AlreadyEncrypted"],
    True, "Vanished"]];

iATRunId[] := DateString[TimeZoneConvert[Now, 0], {"Year", "Month", "Day", "-", "Hour", "Minute", "Second"}] <> "Z-" <> StringTake[CreateUUID[], 6];

iATScopeClasses[cls_] := Module[{c = Replace[cls, All :> Keys[$SourceVaultClassPrivacyRegistry]]},
  If[StringQ[c], c = {c}];
  If[! ListQ[c] || ! SubsetQ[Keys[$SourceVaultClassPrivacyRegistry], c], $Failed, c]];

Options[SourceVaultMigrateToEncrypted] = {"Classes" -> All, "DryRun" -> True, "MaxFiles" -> Infinity,
  "BackupManifest" -> Automatic, "BackupRoot" -> "D:\\SourceVaultBackup", "RequireBackup" -> True, "AllowScript" -> False};
SourceVaultMigrateToEncrypted[OptionsPattern[]] := Module[
  {dry, classes, items, groups, notReady, man, udbRoot, runId, journal, results, en, maint, counts, leaks, n},
  dry = TrueQ[OptionValue["DryRun"]];
  classes = iATScopeClasses[OptionValue["Classes"]];
  If[classes === $Failed, Return[iATFail["UnknownClass", "分類表に無い分類が指定されています。"]]];
  If[! dry && ! TrueQ[$Notebooks] && ! TrueQ[OptionValue["AllowScript"]] && NBAccess`$NBCredentialBackend =!= "Memory",
    Return[iATFail["RunInFrontEnd", "本番の移行は所有者の FE のノートブックで評価してください。"]]];
  items = SortBy[Select[First[iATItems[]], MemberQ[classes, #Class] &], #Path &];
  n = OptionValue["MaxFiles"];
  If[IntegerQ[n] && n >= 0, items = Take[items, UpTo[n]]];
  groups = Union[$SourceVaultClassPrivacyRegistry[#]["KeyGroup"] & /@ classes];
  notReady = Select[groups, ! SourceVaultAtRestReadyQ[#] &];
  If[! dry && notReady =!= {},
    Return[iATFail["AtRestNotReady", "準備 (鍵・紙の回復・訓練) が済んでいない組があります: " <> StringRiffle[notReady, ", "]]]];
  udbRoot = iATUdbRoot[];
  man = If[TrueQ[OptionValue["RequireBackup"]], iATLoadBackup[OptionValue["BackupManifest"], OptionValue["BackupRoot"]], None];
  If[FailureQ[man], Return[man]];
  runId = iATRunId[];
  journal = FileNameJoin[{iATLocalStateDir[], "atrest", "migration", runId <> If[dry, "-dryrun", ""] <> ".jsonl"}];
  If[! dry,
    maint = iATBeginMaintenance[runId, <|"Kind" -> "MigrateToEncrypted", "Classes" -> classes|>];
    If[FailureQ[maint], Return[maint]];
    en = SourceVaultAtRestSetEnforced[groups, "Mode" -> "Add"];
    If[FailureQ[en], iATEndMaintenance[runId]; Return[en]]];
  results = WithCleanup[
    Map[Function[it, With[{r = iATMigrateOne[it, man, dry, runId, udbRoot]},
        iATJournal[journal, <|"At" -> iATNowIso[], "Class" -> it["Class"], "Store" -> it["Store"], "Path" -> it["Path"], "Result" -> r|>];
        <|"Class" -> it["Class"], "Result" -> r|>]], items],
    If[! dry, iATEndMaintenance[runId]]];
  counts = GroupBy[results, #Class &, Counts[#[[All, "Result"]]] &];
  leaks = Count[First[iATItems[]], _?(#Class === "WebReport" && StringMatchQ[ToLowerCase[FileNameTake[#Path]], ___ ~~ ".pdf"] &&
      ! StringStartsQ[FileNameTake[#Path], "f-"] &)];
  <|"Status" -> If[dry, "DryRun", "Done"], "RunId" -> runId, "Classes" -> classes, "Items" -> Length[items],
    "Counts" -> counts, "Totals" -> Counts[results[[All, "Result"]]],
    "Backup" -> If[AssociationQ[man], KeyTake[man, {"Stamp", "Entries", "Relevant", "SelfHashOK"}], "NotRequired"],
    "EnforcedGroups" -> If[dry, Missing["DryRun"], en["EnforcedGroups"]],
    "Flags" -> <|"MigrationProtectsCloudHistory" -> False, "EventsNotMigrated" -> True, "FilenameLeaks" -> leaks, "GCPaused" -> True|>,
    "Next" -> If[dry,
      "結果を確かめてから \"DryRun\" -> False で本番を行います。NotInBackup・ChangedSinceBackup は移しません (バックアップを取り直すか、所有者が判断)。",
      "アプリの経路 (Cerezo・Zelkova・course) で読めることを確かめ、SourceVaultAtRestVerifyMigration で照合してください。Dropbox の版の履歴と削除済みには平文が残るので、Dropbox の web で消してください。"]|>];

(* 移行後の照合: 暗号文を復号し、平文の SHA-256 をバックアップの目録と比べる (件数だけ) *)
Options[SourceVaultAtRestVerifyMigration] = {"Classes" -> All, "BackupManifest" -> Automatic, "BackupRoot" -> "D:\\SourceVaultBackup", "RequireBackup" -> True};
SourceVaultAtRestVerifyMigration[OptionsPattern[]] := Module[{classes, items, man, udbRoot, res},
  classes = iATScopeClasses[OptionValue["Classes"]];
  If[classes === $Failed, Return[iATFail["UnknownClass", "分類表に無い分類が指定されています。"]]];
  man = If[TrueQ[OptionValue["RequireBackup"]], iATLoadBackup[OptionValue["BackupManifest"], OptionValue["BackupRoot"]], None];
  If[FailureQ[man], Return[man]];
  udbRoot = iATUdbRoot[];
  items = Select[First[iATItems[]], MemberQ[classes, #Class] &];
  res = Map[Function[it, it["Class"] -> Which[
      it["Plain"] && it["Encrypted"], "Both",
      it["Plain"], "StillPlaintext",
      True, With[{b = SourceVaultAtRestReadBytes[it["Path"]]},
        Which[
          FailureQ[b], "Unreadable:" <> ToString[b[[1]]],
          ! AssociationQ[man], "Readable",
          True, With[{h = Lookup[man["Map"], If[StringQ[udbRoot], iATBackupKey[it["Path"], udbRoot], Missing[]], Missing[]]},
            Which[! StringQ[h], "NotInBackup", h === iATSha256Hex[b], "MatchesBackup", True, "DiffersFromBackup"]]]]]],
    items];
  <|"Status" -> "Verified", "Items" -> Length[items],
    "Counts" -> GroupBy[res, First -> Last, Counts], "Totals" -> Counts[res[[All, 2]]],
    "Backup" -> If[AssociationQ[man], KeyTake[man, {"Stamp", "SelfHashOK"}], "NotRequired"]|>];

(* 元に戻す: 暗号文を復号して平文に戻す (バイト一致)。移す組の強制も外す。既定は試し。 *)
Options[SourceVaultDecryptStoreToPlaintext] = {"Classes" -> All, "DryRun" -> True, "Unenforce" -> True, "AllowScript" -> False};
SourceVaultDecryptStoreToPlaintext[OptionsPattern[]] := Module[{dry, classes, items, groups, fullGroups, runId, journal, maint, results},
  dry = TrueQ[OptionValue["DryRun"]];
  classes = iATScopeClasses[OptionValue["Classes"]];
  If[classes === $Failed, Return[iATFail["UnknownClass", "分類表に無い分類が指定されています。"]]];
  If[! dry && ! TrueQ[$Notebooks] && ! TrueQ[OptionValue["AllowScript"]] && NBAccess`$NBCredentialBackend =!= "Memory",
    Return[iATFail["RunInFrontEnd", "平文に戻す作業は所有者の FE のノートブックで評価してください。"]]];
  items = SortBy[Select[First[iATItems[]], MemberQ[classes, #Class] && #Encrypted &], #Path &];
  groups = Union[$SourceVaultClassPrivacyRegistry[#]["KeyGroup"] & /@ classes];
  (* 組の全部の分類が範囲に入っているときだけ、その組の強制を外す *)
  fullGroups = Select[groups, SubsetQ[classes, Keys[Select[$SourceVaultClassPrivacyRegistry, Function[e, e["KeyGroup"] === #]]]] &];
  runId = iATRunId[];
  journal = FileNameJoin[{iATLocalStateDir[], "atrest", "migration", runId <> "-decrypt" <> If[dry, "-dryrun", ""] <> ".jsonl"}];
  If[! dry,
    maint = iATBeginMaintenance[runId, <|"Kind" -> "DecryptToPlaintext", "Classes" -> classes|>];
    If[FailureQ[maint], Return[maint]];
    If[TrueQ[OptionValue["Unenforce"]] && fullGroups =!= {},
      With[{r = SourceVaultAtRestSetEnforced[fullGroups, "Mode" -> "Remove"]}, If[FailureQ[r], iATEndMaintenance[runId]; Return[r]]]]];
  results = WithCleanup[
    Map[Function[it, Module[{p = it["Path"], b, r},
        b = SourceVaultAtRestReadBytes[p];
        r = Which[
          it["Plain"], With[{pl = Quiet @ Check[iATReadFile[p], $Failed]},
            Which[FailureQ[b] || ! ByteArrayQ[pl], "Unreadable", b === pl, If[dry, "WouldRemoveDuplicateSve", Quiet @ DeleteFile[p <> ".sve"]; "RemovedDuplicateSve"], True, "BothDiffer"]],
          FailureQ[b], "Unreadable:" <> ToString[b[[1]]],
          dry, "WouldDecrypt",
          iATAtomicWrite[p, b] === $Failed, "WriteFailed",
          Quiet @ Check[iATReadFile[p], $Failed] =!= b, "VerifyFailed",
          True, Quiet @ DeleteFile[p <> ".sve"]; "Decrypted"];
        iATJournal[journal, <|"At" -> iATNowIso[], "Class" -> it["Class"], "Path" -> p, "Result" -> r|>];
        <|"Class" -> it["Class"], "Result" -> r|>]], items],
    If[! dry, iATEndMaintenance[runId]]];
  <|"Status" -> If[dry, "DryRun", "Done"], "RunId" -> runId, "Items" -> Length[items],
    "Counts" -> GroupBy[results, #Class &, Counts[#[[All, "Result"]]] &], "Totals" -> Counts[results[[All, "Result"]]],
    "Unenforced" -> If[dry || ! TrueQ[OptionValue["Unenforce"]], {}, fullGroups]|>];

(* ------------------------------------------------------------
   表示用の平文 (2026-11-14、比較レビュー 5 章の 6 を受けて)
   暗号化したデータを OS の閲覧ソフトで開くには平文のファイルが要る。Dropbox の外 (LocalState/atrest/view) に置き、
   $SourceVaultAtRestViewTTL 秒 (既定 30 分) を過ぎたら次の呼び出しで消す。開いたままで消せないものは次に回す。
   ------------------------------------------------------------ *)
If[! NumericQ[$SourceVaultAtRestViewTTL], $SourceVaultAtRestViewTTL = 1800];
iATViewRoot[] := FileNameJoin[{iATLocalStateDir[], "atrest", "view"}];

SourceVaultAtRestSweepViewFiles[] := Module[{root = iATViewRoot[], now = AbsoluteTime[], files, old, deleted = 0, locked = 0},
  If[! DirectoryQ[root], Return[<|"Deleted" -> 0, "Locked" -> 0, "Remaining" -> 0|>]];
  files = Select[FileNames["*", root, Infinity], ! DirectoryQ[#] &];
  old = Select[files, TrueQ[Quiet @ Check[now - AbsoluteTime[FileDate[#, "Modification"]] > $SourceVaultAtRestViewTTL, False]] &];
  Scan[If[TrueQ[Quiet @ Check[DeleteFile[#]; True, False]], deleted++, locked++] &, old];
  Scan[Quiet @ If[DirectoryQ[#] && FileNames["*", #, Infinity] === {}, DeleteDirectory[#]] &, Select[FileNames["*", root], DirectoryQ]];
  <|"Deleted" -> deleted, "Locked" -> locked, "Remaining" -> Length[files] - deleted|>];

SourceVaultAtRestViewFile[bytes_ByteArray, name_String] := Module[{dir, safe, p},
  SourceVaultAtRestSweepViewFiles[];
  dir = FileNameJoin[{iATViewRoot[], StringTake[CreateUUID[], 8]}]; iATEnsureDir[dir];
  safe = StringReplace[FileNameTake[name], Except[WordCharacter | "." | "-" | "_"] -> "_"];
  If[safe === "", safe = "view.bin"];
  p = FileNameJoin[{dir, safe}];
  If[iATWriteBytesFile[p, bytes] === $Failed, Return[iATFail["ViewWriteFailed", "表示用のファイルを書けませんでした。"]]];
  p];

(* ------------------------------------------------------------
   本文以外に残る平文の一覧 (件数だけ。2026-11-14、比較レビュー 5 章の 6 を受けて)
   ------------------------------------------------------------ *)
SourceVaultAtRestResidualInventory[] := Module[{pv = iATRootValue["PrivateVault"], ls = iATRootValue["LocalState"], core, base, wr, cnt, files, out = <||>},
  core = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed];
  base = Which[StringQ[pv], pv, StringQ[core], core, True, Missing[]];
  cnt[d_] := If[StringQ[d] && DirectoryQ[d], Length[Select[FileNames["*", d, Infinity], ! DirectoryQ[#] &]], 0];
  wr = If[StringQ[base], FileNameJoin[{DirectoryName[base], "webreports"}], Missing[]];
  out["PrivateVaultMaterialized"] = If[StringQ[base], cnt[FileNameJoin[{base, "materialized"}]], 0];
  out["LocalStateMaterialized"] = If[StringQ[ls], cnt[FileNameJoin[{ls, "materialized"}]], 0];
  out["ViewFiles"] = cnt[iATViewRoot[]];
  out["CourseTempFiles"] = cnt[FileNameJoin[{$TemporaryDirectory, "svcourse-submissions"}]];
  files = If[StringQ[wr] && DirectoryQ[wr], Select[FileNames["*", wr, Infinity], ! DirectoryQ[#] && ! StringContainsQ[FileNameTake[#], ".tmp."] &], {}];
  out["WebReportsPlainFiles"] = Count[files, f_ /; ! StringEndsQ[f, ".sve"]];
  out["WebReportsIdNamedPDFs"] = Count[files, f_ /; StringMatchQ[ToLowerCase[FileNameTake[f]], ___ ~~ (".pdf" | ".pdf.sve")] && ! StringStartsQ[FileNameTake[f], "f-"]];
  out["AnonymizeConfigFiles"] = If[StringQ[base] && DirectoryQ[FileNameJoin[{base, "config"}]],
    Count[FileNames["*", FileNameJoin[{base, "config"}], Infinity], f_ /; ! DirectoryQ[f] && StringContainsQ[f, "anonymize-"]], 0];
  out["EventsWithStudentToken"] = If[Length[DownValues[SourceVault`CorePrivate`iAllEventFiles]] > 0,
    Count[SourceVault`CorePrivate`iAllEventFiles[], f_ /; With[{s = Quiet @ Check[ReadString[f], ""]}, StringQ[s] && StringContainsQ[s, "student:"]]],
    Missing["CoreNotLoaded"]];
  out["NotChecked"] = {"検索の索引・KB", "LLM の呼び出しの記録 (llmlog)", "来歴の spool", "SystemDoctor の診断", "On Work のノートブックと Excel"};
  out["ManualSteps"] = {"Dropbox の版の履歴と削除済みのファイルに平文が残る (Dropbox の web で消す)",
    "D: のバックアップは平文 (BitLocker で守る。意図どおり)"};
  out];

(* ------------------------------------------------------------
   NBAccess の承認の対象 (モデルが書いたコードから呼ぶと承認を求める)
   ------------------------------------------------------------ *)
Quiet @ Check[
  NBAccess`NBRegisterApprovalHeads[{"SourceVaultCreateRecoveryKey", "SourceVaultRecoverKeys", "SourceVaultRecoveryDrill",
    "SourceVaultEnsureClassKey", "SourceVaultAtRestSetup", "SourceVaultAtRestDeleteFile",
    "SourceVaultRotateClassKey", "SourceVaultAtRestReencryptFile",
    "SourceVaultMigrateToEncrypted", "SourceVaultDecryptStoreToPlaintext", "SourceVaultAtRestSetEnforced", "SourceVaultAtRestEndMaintenance",
    (* 任意のパスの暗号文を復号して返す / 書く / 平文の表示用ファイルを作る口。
       SourceVault の中からの呼び出しは承認の対象外 (関所はモデルの提案コードだけを見る) *)
    "SourceVaultAtRestReadBytes", "SourceVaultAtRestWriteBytes", "SourceVaultAtRestViewFile"}];
  NBAccess`NBRegisterApprovalSetSymbols[{"$SourceVaultAtRestEnforce", "$SourceVaultClassPrivacyRegistry",
    "$SourceVaultKeyGroups", "$SourceVaultStoreAccessLevels", "$SourceVaultAtRestRecoveryCodeSink", "$SourceVaultAtRestViewTTL"}],
  Null];

(* ------------------------------------------------------------
   privacy の契約 (SourceVault_privacy.wl の宣言の表。手本は SourceVault_maildb.wl の iSVMDRegisterPrivacyContracts)
   2026-11-18: このモジュールの公開記号は、学生・成績の保管先 (snapshots・blobs・exercises/exams・coursereports・webreports) と
   鍵の台帳・鍵ストアに届く。戻り値に何が載るかを 1 つずつ読んで分けた。
   Internal + NoDataFlow = 戻り値は設定値・真偽・状態・件数・理由のコード・版の番号だけ。復号した中身、平文の鍵、紙の回復キー、
   保管先から拾ったファイル名は載らない (理由を 1 つずつ書く。理由の無い宣言は監査が落とす)。
   Private + Head = 戻り値に私的なデータが載る 2 つ (復号したバイト列を返す SourceVaultAtRestReadBytes と、保管先のファイル名を返す
   SourceVaultAtRestFileNames)。出口は NBAccess の機密ヘッド表への登録だけにする (2026-11-18 所有者の決定。
   SourceVaultMailSnapshotDecryptBody と同じ扱い)。本体は透かしを記録しない: core の snapshot・blob と course の読み出しが
   1 件ごとにここを通るので、ここで記録すると FE では 1 件ごとに FE との往復が増え、FE の無いカーネルでは透かしが上がったままになる。
   透かしの記録は、これを呼ぶ側の公開関数の出口が受け持つ (course は iEXExitApply)。core の SourceVaultLoadImmutableSnapshot と
   SourceVaultReadBlob は今は記録を通らない。ここで記録する形 (Result) に替えるなら、FE での遅れを測ってから別の変更にする。
   privacy 層が無い環境 (このモジュールだけを読む単体の試験など) では何もしない。
   ------------------------------------------------------------ *)
$iATPrivateHeads = {
  (* 見出しの PL は分類表の値 (今は 0.98 まで)。表に無い分類は 1.0 とみなすので、ヘッド表には 1.0 で載せる *)
  {"SourceVaultAtRestReadBytes", 1.0, "path の .sve を検証して復号したバイト列 (.sve が無ければ平文のバイト列) をそのまま返す。"},
  {"SourceVaultAtRestFileNames", 1.0, "保管先のフォルダにあるファイルの名前を返す。webreports や答案のスキャンには、学籍番号を含む名前がある。"}};

iATRegisterPrivacyContracts[] := Quiet @ Check[
  If[Length[DownValues[SourceVault`SourceVaultRegisterPrivacyContract]] > 0,
    Scan[SourceVault`SourceVaultRegisterPrivacyContract[First[#],
        <|"Class" -> "Private", "Exit" -> "Head", "Sources" -> {"atrest"}, "Module" -> "SourceVault_atrest.wl", "Note" -> Last[#]|>] &,
      $iATPrivateHeads];
    Scan[SourceVault`SourceVaultRegisterPrivacyContract[First[#],
        <|"Class" -> "Internal", "Module" -> "SourceVault_atrest.wl", "NoDataFlow" -> Last[#]|>] &,
      {(* 設定値 *)
       {"$SourceVaultClassPrivacyRegistry", "設定値。分類の名前 → PL・出どころ・鍵の組・区分・決めた日の表で、学生や成績のデータは入らない。"},
       {"$SourceVaultKeyGroups", "設定値。鍵の組の名前 → 段と区分。鍵は入らない。"},
       {"$SourceVaultStoreAccessLevels", "設定値。保管先の名前・根のフォルダ・AccessLevel の上書き (既定は Automatic)。"},
       {"$SourceVaultAtRestEnforce", "設定値。暗号化を強制する鍵の組の名前の一覧。"},
       {"$SourceVaultAtRestRecoveryCodeSink", "試験専用の設定値。値は受け口の関数で、紙の回復キーではない。Memory の鍵ストアのときだけ呼ばれ、本番の鍵ストアでは使われない。"},
       {"$SourceVaultAtRestViewTTL", "設定値。表示用の平文のファイルを残す秒数。"},
       (* 分類表・保管先・段 (ファイルを読まない) *)
       {"SourceVaultAtRestClassInfo", "分類表を引くだけ。分類の名前に対する PL・出どころ・鍵の組・段を返し、保管先は読まない。"},
       {"SourceVaultAtRestTier", "数値 2 つから段 (1 / 2 / 3) を求める計算だけ。"},
       {"SourceVaultAtRestStoreOf", "呼び出し側が渡したパスの文字列と保管先の根から、保管先の名前・根・AccessLevel・相対パスを求める。ファイルは読まず、返すパスは渡されたパスの言い換えだけ。"},
       {"SourceVaultAtRestClassOfPath", "呼び出し側が渡したパスの位置から分類の名前を求める。ファイルは読まない。"},
       {"SourceVaultAtRestShouldEncryptQ", "分類表・台帳の強制の組・作業のロックを見て、真偽だけを返す。"},
       {"SourceVaultAtRestFileExistsQ", "平文か .sve があるかの真偽だけを返す。中身は読まない。"},
       (* 台帳・鍵・紙の回復 (平文の鍵と回復キーは戻り値に出ない) *)
       {"SourceVaultAtRestKeyring", "台帳 (svkeyring.json) の中身を返す。回復の公開鍵で包んだ鍵、紙の回復キーから導いた鍵で包んだ回復の秘密鍵、公開鍵、鍵の指紋と名前、機の名前、世代、MAC だけで、平文の鍵・紙の回復キー・学生や成績のデータは無い (台帳は Dropbox に平文で置く前提のファイル)。"},
       {"SourceVaultAtRestStatus", "台帳の世代と下限、写しの検証の結果、紙の回復の鍵 ID と日時、鍵の組ごとの版・準備・確かさ、機の名前を返す。鍵、包んだ鍵、回復キー、学生や成績のデータは載らない。"},
       {"SourceVaultAtRestReadyQ", "台帳と鍵の指紋を確かめて、真偽だけを返す。"},
       {"SourceVaultEnsureClassKey", "鍵を鍵ストアに作り、紙の回復の公開鍵で包んで台帳に記録する。返すのは状態・鍵の組の名前・段だけで、鍵は戻り値に出ない。"},
       {"SourceVaultRotateClassKey", "新しい版の鍵を鍵ストアに作って台帳に記録する。返すのは状態・鍵の組の名前・版の番号だけで、鍵は戻り値に出ない。"},
       {"SourceVaultAtRestSetup", "台帳の MAC 鍵・紙の回復キー・鍵の組の鍵を用意する。返すのは状態、作った鍵の組の名前、準備の真偽だけ。回復キーは保存しない FE の窓 (Memory の鍵ストアの試験では受け口) にだけ出る。"},
       {"SourceVaultCreateRecoveryKey", "紙の回復キーは保存しない FE の窓 (Memory の鍵ストアの試験では受け口) にだけ出し、ファイルにも戻り値にも書かない。返すのは状態・鍵 ID・台帳の世代だけ。"},
       {"SourceVaultRecoveryDrill", "紙の回復キーは伏せ字の窓で受け取り、鍵の指紋の照合にだけ使う。返すのは合否・鍵 ID・確かめた鍵の数・日時 (失敗のときは鍵の名前ごとの状態) だけ。"},
       {"SourceVaultRecoverKeys", "紙の回復キーは伏せ字の窓で受け取り、台帳の鍵をこの機の鍵ストアに戻す。返すのは状態と件数だけで、鍵は戻り値に出ない。"},
       {"SourceVaultAtRestSetEnforced", "台帳の強制の組を書き換える。返すのは状態と鍵の組の名前の一覧だけ。"},
       {"SourceVaultAtRestEndMaintenance", "移行の作業のロックを外す。返すのは状態 (断るときは、ロックを置いた機の名前と時刻) だけ。"},
       (* 書く・移す・消す (中身は戻り値に出ない) *)
       {"SourceVaultAtRestWriteBytes", "呼び出し側が渡したバイト列を暗号化して書く。返すのは状態・段・鍵の組・鍵の版・バイト数だけで、中身は戻り値に出ない。"},
       {"SourceVaultAtRestReencryptFile", "1 件を復号して今の版の鍵で書き直す。返すのは状態と版の番号だけで、中身は戻り値に出ない。"},
       {"SourceVaultAtRestDeleteFile", "平文と .sve を消し、真偽だけを返す。"},
       {"SourceVaultMigrateToEncrypted", "保管先の平文を読んで暗号化するが、返すのは分類ごとの件数・理由のコード・作業の ID・バックアップの目録の件数だけ。パスとハッシュは LocalState の日誌にだけ書く。"},
       {"SourceVaultAtRestVerifyMigration", "暗号文を復号して SHA-256 をバックアップの目録と比べるが、返すのは分類ごとの件数だけ。復号した中身・パス・ハッシュは戻り値に出ない。"},
       {"SourceVaultDecryptStoreToPlaintext", "暗号文を復号して平文のファイルに戻す (元に戻す道具)。返すのは分類ごとの件数と、強制を外した鍵の組の名前だけ。"},
       (* 件数の集計・表示用のファイル *)
       {"SourceVaultAtRestInventory", "保管先を走査して、分類ごとの件数・バイト数・段・鍵の組・強制の有無だけを返す (パスやハッシュは出さない)。"},
       {"SourceVaultAtRestResidualInventory", "残っている平文の件数だけを数えて返す (ファイル名や中身は返さない)。添える一覧は固定の文言。"},
       {"SourceVaultAtRestSweepViewFiles", "期限を過ぎた表示用のファイルを消し、件数だけを返す。"},
       {"SourceVaultAtRestViewFile", "呼び出し側が渡したバイト列を、Dropbox の外の期限つきの置き場に書いてパスを返す。保管先は読まない。パスは乱数のフォルダ名と、呼び出し側が渡した名前 (記号を置き換えたもの) だけでできている。"}}]],
  Null];
iATRegisterPrivacyContracts[];

(* 機密を生むヘッドの表 (NBAccess)。claudecode は、セルの入力や提案コードがこの名前を使っているかで機密の印を決める。
   契約 (Private + Head) と同じ表から作るので、足したときに登録が漏れない。NBAccess.wl が無いカーネル (service など) では何もしない。 *)
iATRegisterConfidentialHeads[] := Quiet @ Check[
  If[Length[DownValues[NBAccess`NBRegisterConfidentialHead]] > 0,
    Scan[NBAccess`NBRegisterConfidentialHead[#[[1]], #[[2]]] &, $iATPrivateHeads]],
  Null];
iATRegisterConfidentialHeads[];

End[];
EndPackage[];
