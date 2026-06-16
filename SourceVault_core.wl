(* ::Package:: *)

(* ============================================================
   SourceVault_core.wl -- SourceVault 検索拡張 Phase 0 core 基盤

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_core.wl"]]

   仕様書: sourcevault_websearch_extension_spec_v0_10.md
     §8.2a  Immutable snapshot store 基盤
     §17.12 SourceVault 排他制御 / transaction 仕様

   位置づけ:
     仕様 §2.4 / §8.13 が指定する「既存 SourceVault.wl の core extension」を、
     既存ファイルを書き換えず新規ファイルとして SourceVault` 文脈へ追加する。
     SourceVault_searchindex.wl / SourceVault_servicemanager.wl はこの core helper
     を利用する。load order: SourceVault.wl -> SourceVault_core.wl
                            -> SourceVault_searchindex.wl -> SourceVault_servicemanager.wl

   設計原則 (§17.12.1):
     1. LLM / ASR / TTS / OCR / HTTP / Discord / shell 実行中は data lock を保持しない。
     2. 書き込みは append-only event directory (one-event-one-file)。
     3. blob は content-addressed storage に create-only で書く。
     4. 既存 object の破壊的更新禁止。active pointer は pointer event の追加で表現。
     5. lock 取得は atomic directory creation (advisory file lock に依存しない)。
     6. WL に明示 fsync が無い前提。一貫性は checksum 検証 + replay + idempotent ID。
     7. CommandID / EventID は CreateUUID[] を既定。
     8. 既定は同一 host 上の複数 process。異 host stale lock は operator review。

   識別子フォーマット:
     event id      "evt:" <> CreateUUID[]
     blob ref      "blob:sha256:" <> <hex64>
     snapshot ref  "snapshot:" <> <class> <> ":" <> <hex64>
     digest        "sha256:" <> <hex64>

   非衝突方針:
     private helper は SourceVault`CorePrivate` 文脈に置き、既存 SourceVault`Private`
     (iEnsureDir / iHexHash 等) と隔離する。
   ============================================================ *)

BeginPackage["SourceVault`"]

(* ---- root ---- *)
$SourceVaultCoreRoot::usage =
  "$SourceVaultCoreRoot は core storage の root directory override。\n" <>
  "未設定 (Automatic) の場合は SourceVault`$SourceVaultRoots[\"PrivateVault\"] を使う。\n" <>
  "どちらも解決できない場合、core API は fail-closed する (推測 fallback しない)。";

SourceVaultCoreRoot::usage =
  "SourceVaultCoreRoot[] は core storage root の絶対パスを返す。解決できなければ Failure を返す。";

(* ---- root registry / resolver (spec v6 §3.4: service-loadable root API) ----
   core は root 解決ロジックを複製せず、注入値 (service kernel) か bootstrap が
   設定済みの SourceVault`$SourceVaultRoots (main kernel) を読む薄いアクセサとする。 *)
SourceVaultRootAssociation::usage =
  "SourceVaultRootAssociation[] は現在有効な root 解決結果 (Association) を返す。\n" <>
  "service kernel に $SourceVaultInjectedRoots が注入されていればそれを最優先し、\n" <>
  "次に main kernel で bootstrap が設定した SourceVault`$SourceVaultRoots を読む。";

SourceVaultResolveRoots::usage =
  "SourceVaultResolveRoots[] は SourceVaultRootAssociation[] の別名。";

SourceVaultRoot::usage =
  "SourceVaultRoot[key] は root key (\"PrivateVault\"/\"Tmp\"/\"LocalState\" 等) のパスを返す。\n" <>
  "未解決なら Missing[\"NotResolved\", key]。";

SourceVaultSetRoot::usage =
  "SourceVaultSetRoot[key, path] は root 設定を変更する (SourceVault`$SourceVaultRoots を更新)。\n" <>
  "設定変更のみで既存データの移動は行わない (spec v6 §3.9)。移行は別 migration command を使う。";

SourceVaultRootConfigHash::usage =
  "SourceVaultRootConfigHash[] は現在の root 構成の SHA256 hex を返す。\n" <>
  "main kernel と service kernel の root 一致検証 (health check) に使う。";

SourceVaultStorageDir::usage =
  "SourceVaultStorageDir[class] は storage class (\"Raw\"/\"Meta\"/\"Parsed\"/\"Attachments\"/\"Compiled\"/\"LocalState\") の絶対パスを返す。";

$SourceVaultInjectedRoots::usage =
  "$SourceVaultInjectedRoots は service kernel 起動時に run.wls から注入される root snapshot (Association)。\n" <>
  "main kernel では通常未設定。設定時は root 解決で最優先される (start-time snapshot, spec v6 §3.8)。";

$SourceVaultInjectedRootHash::usage =
  "$SourceVaultInjectedRootHash は注入された root 構成の hash。health check で main kernel と比較する。";

(* ---- digest / snapshot store (§8.2a) ---- *)
SourceVaultCanonicalizeForDigest::usage =
  "SourceVaultCanonicalizeForDigest[assoc, opts] は assoc を digest 用 canonical JSON 文字列に正規化する。\n" <>
  "Association の key を再帰 sort し、DateObject を UTC ISO-8601 文字列化し、揮発 field を除く。\n" <>
  "オプション: \"DropFields\" -> {追加除外 key...}。";

SourceVaultSnapshotDigest::usage =
  "SourceVaultSnapshotDigest[assoc, opts] は canonical JSON の UTF-8 bytes の SHA256 を \"sha256:<hex>\" で返す。";

SourceVaultSaveImmutableSnapshot::usage =
  "SourceVaultSaveImmutableSnapshot[class, assoc, opts] は assoc を immutable snapshot として保存する。\n" <>
  "戻り値 <|\"Status\", \"Ref\", \"Digest\", \"Path\", \"Class\", \"Existed\"|>。\n" <>
  "オプション: \"Alias\" -> aliasName (alias 割当)。同一内容の再保存は idempotent。";

SourceVaultLoadImmutableSnapshot::usage =
  "SourceVaultLoadImmutableSnapshot[ref] は snapshot ref または \"class/alias\" を読み、検証済み assoc を返す。";

SourceVaultReadSnapshot::usage =
  "SourceVaultReadSnapshot[id] は SourceVaultLoadImmutableSnapshot の別名。";

SourceVaultVerifyImmutableSnapshot::usage =
  "SourceVaultVerifyImmutableSnapshot[ref] は保存済み snapshot の digest を再計算して整合を返す。";

SourceVaultAllocateSnapshotAlias::usage =
  "SourceVaultAllocateSnapshotAlias[class, alias, ref, opts] は alias -> ref を割り当てる。\n" <>
  "同 alias に異なる ref を割り当てようとすると NameCollision で拒否する (idempotent)。";

(* ---- lock primitive (§17.12.2) ---- *)
SourceVaultTryLock::usage =
  "SourceVaultTryLock[lockName, opts] は atomic directory creation で lock を一度だけ試みる。\n" <>
  "戻り値 <|\"Acquired\" -> True|False, \"Handle\", \"Reason\", ...|>。\n" <>
  "オプション: \"TTLSeconds\" (既定 30)。同一 host の期限切れ lock は自動回収する。";

SourceVaultWithLock::usage =
  "SourceVaultWithLock[lockName, body, opts] は lock を取得して body を評価し、必ず lock を解放する。\n" <>
  "取得できなければ Failure[\"LockTimeout\", ...] を返す。body は lock 取得まで評価されない。\n" <>
  "オプション: \"TimeoutSeconds\" (既定 5), \"TTLSeconds\" (既定 30)。";

SourceVaultReleaseLock::usage =
  "SourceVaultReleaseLock[handle] は SourceVaultTryLock が返した lock handle を解放する。";

SourceVaultRecoverLocks::usage =
  "SourceVaultRecoverLocks[opts] は同一 host の期限切れ (stale) lock を回収する。\n" <>
  "異 host の lock は回収せず NeedsOperatorRecovery として報告する。";

(* ---- event log (§17.12.5) ---- *)
SourceVaultAppendEvent::usage =
  "SourceVaultAppendEvent[event, opts] は event を append-only event directory に one-event-one-file で commit する。\n" <>
  "EventID が無ければ \"evt:\"<>CreateUUID[] を付与し、Digest と CreatedAtUTC を補う。\n" <>
  "同一 EventID の再 commit は digest 一致なら idempotent 成功、不一致なら EventIdCollision。";

SourceVaultTransactionLog::usage =
  "SourceVaultTransactionLog[opts] は event directory の event を新しい順に返す。\n" <>
  "オプション: \"Limit\" (既定 100), \"EventClass\" -> filter。";

(* ---- blob commit (§17.12.6) ---- *)
SourceVaultCommitBlob::usage =
  "SourceVaultCommitBlob[data, opts] は ByteArray / String を content-addressed blob として create-only で保存する。\n" <>
  "戻り値 <|\"Status\", \"Hash\", \"BlobRef\", \"Path\", \"Existed\"|>。hash 不一致の既存 blob は Corruption で fail-closed。\n" <>
  "オプション: \"Meta\" -> assoc (meta.json に保存)。";

SourceVaultBlobRefs::usage =
  "SourceVaultBlobRefs[hash, opts] は blob hash を参照する snapshot / event を走査して参照元を返す。";

(* ---- pointer (§17.12.7) ---- *)
SourceVaultAtomicUpdatePointer::usage =
  "SourceVaultAtomicUpdatePointer[name, value, opts] は pointer を更新する。\n" <>
  "内部では active-pointer lock の下で pointer event を追加し、active.json cache を更新する。\n" <>
  "戻り値 <|\"Status\", \"Name\", \"Sequence\", \"Value\", \"EventRef\"|>。";

SourceVaultPointerReplay::usage =
  "SourceVaultPointerReplay[name, opts] は pointer event を replay し、最大 Sequence の検証済み値を返す。\n" <>
  "戻り値 <|\"Status\", \"Value\", \"Sequence\", \"EventCount\", \"CacheConsistent\"|>。";

SourceVaultPointerHistory::usage =
  "SourceVaultPointerHistory[name] は pointer の検証済み event 履歴を Sequence 昇順で返す。\n" <>
  "各要素 <|\"Sequence\", \"Value\", \"CreatedAtUTC\"|>。rollback 等で前版を辿るのに使う。";

(* ---- GC / retention (§17.12.10) ---- *)
SourceVaultGCGracePeriod::usage =
  "SourceVaultGCGracePeriod[] は in-flight blob 保護の既定 grace period (秒) を返す。";

SourceVaultGCDryRun::usage =
  "SourceVaultGCDryRun[opts] は削除せずに GC 候補 blob を報告する。SourceVaultRunGC[\"ConfirmDelete\"->False] と同じ。";

SourceVaultRunGC::usage =
  "SourceVaultRunGC[opts] は未参照かつ retention 期限切れの blob を回収する。\n" <>
  "既定は dry-run。実削除には \"ConfirmDelete\" -> True が必要。\n" <>
  "grace period 内の blob / in-flight write / replay 失敗 vault は削除しない (fail-closed)。";

SourceVaultRetentionPlan::usage =
  "SourceVaultRetentionPlan[scope, opts] は blob 群の参照状態と retention 判定の計画を返す (削除しない)。";

(* ---- consistency / test (§17.12.11) ---- *)
SourceVaultCheckVaultConsistency::usage =
  "SourceVaultCheckVaultConsistency[opts] は vault の不変条件を検査し報告を返す。\n" <>
  "検査: event digest 一致 / EventID 一意 / pointer sequence 単調 / cache 整合 / blob hash 整合 / orphan tmp / stale lock。";

SourceVaultConcurrentWriteTest::usage =
  "SourceVaultConcurrentWriteTest[opts] は append / blob / pointer の並行書込と idempotency / collision 検出を検証する。\n" <>
  "オプション: \"Processes\" (既定 2), \"PerProcessEvents\" (既定 100), \"Parallel\" -> True|False。\n" <>
  "戻り値に Passed と不変条件チェック結果を含む。";

Begin["`CorePrivate`"]

(* このファイルの絶対パス (subkernel から再 Get するため) *)
$coreFile = Replace[$InputFileName, Except[_String?(StringLength[#] > 0 &)] :> Missing["Unknown"]];

(* ============================================================
   基本ヘルパ
   ============================================================ *)

iEnsureDir[d_String] := (
  If[! DirectoryQ[d], Quiet @ CreateDirectory[d, CreateIntermediateDirectories -> True]];
  d
);

(* 文字列を UTF-8 bytes として書く (BOM / encoding 事故回避) *)
iWriteStringUTF8[path_String, str_String] := Module[{strm},
  iEnsureDir[DirectoryName[path]];
  strm = Quiet @ OpenWrite[path, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  BinaryWrite[strm, StringToByteArray[str, "UTF-8"]];
  Close[strm];
  path
];

iReadStringUTF8[path_String] := Module[{b},
  b = Quiet @ ReadByteArray[path];
  If[ByteArrayQ[b], ByteArrayToString[b, "UTF-8"], $Failed]
];

(* SHA256 hex (modern standard form) *)
iSHA256Hex[ba_ByteArray] := ToLowerCase @ Hash[ba, "SHA256", "HexString"];
iSHA256Hex[s_String] := iSHA256Hex[StringToByteArray[s, "UTF-8"]];

(* DateObject -> UTC ISO-8601 文字列 *)
iUTCString[d_DateObject] := Module[{u},
  u = Quiet @ TimeZoneConvert[d, 0];
  If[Head[u] =!= DateObject, u = d];
  DateString[u, {"Year", "-", "Month", "-", "Day", "T",
     "Hour", ":", "Minute", ":", "Second", "Z"}]
];
iUTCNow[] := iUTCString[Now];

(* UTC 文字列を path 用に安全化 (: を - に) *)
iSafeStamp[s_String] := StringReplace[s, {":" -> "-"}];

(* JSON encode / decode。canonical 用に必ず使う。
   RawJSON が encode できない None / Missing / DateObject を安全化する
   (option 既定値の None などが record に紛れても落ちないように)。 *)
iJSONSafe[x_] := Which[
  x === None, Null,
  Head[x] === Missing, Null,
  Head[x] === DateObject, iUTCString[x],
  AssociationQ[x], Association @ KeyValueMap[#1 -> iJSONSafe[#2] &, x],
  ListQ[x], iJSONSafe /@ x,
  True, x];
(* utf8fix: ExportString["RawJSON"] の戻り値は UTF-8 byte の Latin-1 表現
   (1 byte = 1 文字) なので、そのまま iWriteStringUTF8 へ渡すと二重 encode で
   file が文字化けする。ExportByteArray / ImportByteArray 経由にして
   iToJSON は常に「本物の文字を持つ WL 文字列」を返す。
   digest (iSHA256Hex) もこの文字列基準 = 素の UTF-8 bytes 基準になる。 *)
iToJSON[expr_] := Quiet @ Check[
  ByteArrayToString[
    ExportByteArray[iJSONSafe[expr], "RawJSON", "Compact" -> True], "UTF-8"],
  $Failed];
iFromJSON[str_String] := Quiet @ Check[
  ImportByteArray[StringToByteArray[str, "UTF-8"], "RawJSON"], $Failed];

(* root 解決 (§5.4 fail-closed: 推測 fallback しない) *)
iResolveRoot[] := Module[{r},
  r = SourceVault`$SourceVaultCoreRoot;
  If[! StringQ[r] || StringLength[r] == 0,
    r = Quiet @ SourceVault`$SourceVaultRoots["PrivateVault"]];
  If[! StringQ[r] || StringLength[r] == 0,
    Return[Failure["SourceVaultCoreRootUnresolved", <|
      "MessageTemplate" -> "core storage root が未解決です。$SourceVaultCoreRoot を設定するか SourceVaultInitialize を実行してください。"
    |>]]];
  iEnsureDir[r];
  r
];

(* public accessor *)
SourceVaultCoreRoot[] := iResolveRoot[];

(* ---- root registry / resolver (spec v6 §3.4) ----
   薄いアクセサ: 注入値 (service kernel) を最優先し、無ければ bootstrap が
   設定した SourceVault`$SourceVaultRoots (main kernel) を読む。core 自身は
   dropbox 解決ロジックを持たないため、main/service で同一規則になり drift しない。
   どちらも未設定なら空 association を返す (fail-soft; 呼び出し側で Missing 扱い)。 *)
SourceVaultRootAssociation[] := Module[{inj, boot},
  inj = SourceVault`$SourceVaultInjectedRoots;
  If[AssociationQ[inj], Return[inj]];
  boot = SourceVault`$SourceVaultRoots;
  If[AssociationQ[boot], Return[boot]];
  <||>
];

SourceVaultResolveRoots[] := SourceVaultRootAssociation[];

SourceVaultRoot[key_String] :=
  Lookup[SourceVaultRootAssociation[], key, Missing["NotResolved", key]];

(* 設定変更のみ。データ移行は行わない (spec v6 §3.9)。注入値がある service kernel では
   restart / reload まで反映されない点に注意 (spec v6 §3.8)。 *)
SourceVaultSetRoot[key_String, path_String] := Module[{cur},
  cur = SourceVault`$SourceVaultRoots;
  If[! AssociationQ[cur], cur = <||>];
  SourceVault`$SourceVaultRoots = Append[cur, key -> path];
  path
];

SourceVaultRootConfigHash[] := Module[{a = SourceVaultRootAssociation[]},
  If[! AssociationQ[a] || Length[a] == 0,
    "",
    Hash[KeySort[a], "SHA256", "HexString"]]
];

SourceVaultStorageDir[class_String] := Module[{pv},
  If[class === "LocalState", Return[SourceVaultRoot["LocalState"]]];
  pv = SourceVaultRoot["PrivateVault"];
  If[! StringQ[pv],
    Return[Failure["SourceVaultRootUnresolved", <|"Key" -> "PrivateVault"|>]]];
  Switch[class,
    "Raw",         FileNameJoin[{pv, "raw", "by-hash"}],
    "Meta",        FileNameJoin[{pv, "raw", "meta"}],
    "Parsed",      FileNameJoin[{pv, "parsed"}],
    "Attachments", FileNameJoin[{pv, "attachments"}],
    "Compiled",    FileNameJoin[{pv, "compiled", "public"}],
    _,             Failure["SourceVaultUnknownStorageClass", <|"Class" -> class|>]
  ]
];

iSub[parts__] := Module[{r = iResolveRoot[]},
  If[FailureQ[r], r, FileNameJoin[{r, parts}]]
];

iTmpName[target_String] :=
  target <> ".tmp." <> ToString[$ProcessID] <> "." <> StringTake[CreateUUID[], 8];

(* create-only commit: target が無ければ rename、有れば既存とみなす。
   Windows の RenameFile は宛先存在時に失敗する (= create-only セマンティクスに合致, §17.12.6) *)
iCommitCreateOnly[tmp_String, target_String] := Module[{r},
  iEnsureDir[DirectoryName[target]];
  If[FileExistsQ[target], Return["Exists"]];
  r = Quiet @ RenameFile[tmp, target, OverwriteTarget -> False];
  Which[
    StringQ[r] || r === target, "Created",
    FileExistsQ[target], "Exists",  (* race: 別 process が先に作った *)
    True, "Failed"
  ]
];

$pid := $ProcessID;
$host := $MachineName;

(* ============================================================
   §8.2a  Digest / Canonicalization
   ============================================================ *)

$volatileFields = {
  "CreatedAtUTC", "StoredAtUTC", "CreatedBy", "BuildHost",
  "RuntimeResolved", "LocalPath", "ResolvedCredential",
  "ProcessID", "LastAccessedAtUTC", "Digest"
};

iCanonical[x_, drop_List] := Which[
  AssociationQ[x],
    KeySort @ Association @ KeyValueMap[
      Function[{k, v}, k -> iCanonical[v, drop]],
      KeyDrop[x, drop]],
  ListQ[x],
    Function[e, iCanonical[e, drop]] /@ x,
  Head[x] === DateObject,
    iUTCString[x],
  True, x
];

Options[SourceVaultCanonicalizeForDigest] = {"DropFields" -> {}};
SourceVaultCanonicalizeForDigest[assoc_Association, OptionsPattern[]] := Module[
  {drop, canon, json},
  drop = Union[$volatileFields, OptionValue["DropFields"]];
  canon = iCanonical[assoc, drop];
  json = iToJSON[canon];
  If[! StringQ[json],
    Return[Failure["CanonicalizeFailed", <|
      "MessageTemplate" -> "canonical JSON への変換に失敗しました。"|>]]];
  json
];

Options[SourceVaultSnapshotDigest] = Options[SourceVaultCanonicalizeForDigest];
SourceVaultSnapshotDigest[assoc_Association, opts:OptionsPattern[]] := Module[{json},
  json = SourceVaultCanonicalizeForDigest[assoc, opts];
  If[FailureQ[json], Return[json]];
  "sha256:" <> iSHA256Hex[json]
];

iBareDigest[d_String] := StringReplace[d, "sha256:" -> ""];

(* ============================================================
   §8.2a  Immutable snapshot store
   ============================================================ *)

iSnapshotPath[class_String, digestHex_String] :=
  iSub["snapshots", class, StringTake[digestHex, 2], digestHex <> ".json"];

iAliasPath[class_String, alias_String] :=
  iSub["snapshot-alias", class, alias <> ".ref.json"];

Options[SourceVaultSaveImmutableSnapshot] = {"Alias" -> None};
SourceVaultSaveImmutableSnapshot[class_String, assoc_Association, OptionsPattern[]] := Module[
  {digest, hex, path, ref, stored, json, status, aliasName, aliasRes},
  digest = SourceVaultSnapshotDigest[assoc];
  If[FailureQ[digest], Return[digest]];
  hex = iBareDigest[digest];
  path = iSnapshotPath[class, hex];
  If[FailureQ[path], Return[path]];
  ref = "snapshot:" <> class <> ":" <> hex;
  (* 保存内容: 元 assoc に SnapshotClass / Digest / StoredAtUTC を付与する。
     これらは digest 計算対象外 (verify 時に KeyDrop して元 assoc を復元できる)。
     元 assoc の key は一切書き換えない (ObjectClass 等は assoc 側が持つ)。 *)
  stored = Join[assoc, <|
    "SnapshotClass" -> class,
    "Digest" -> digest,
    "StoredAtUTC" -> iUTCNow[]|>];
  If[FileExistsQ[path],
    status = "Existed",
    json = iToJSON[stored];
    If[! StringQ[json], Return[Failure["JSONEncodeFailed", <|"Class" -> class|>]]];
    Module[{tmp = iTmpName[path], c},
      If[FailureQ[iWriteStringUTF8[tmp, json]],
        Return[Failure["WriteFailed", <|"Path" -> tmp|>]]];
      c = iCommitCreateOnly[tmp, path];
      Quiet @ If[FileExistsQ[tmp], DeleteFile[tmp]];
      status = If[c === "Failed", Return[Failure["CommitFailed", <|"Path" -> path|>]], "Created"]
    ]
  ];
  aliasName = OptionValue["Alias"];
  If[StringQ[aliasName],
    aliasRes = SourceVaultAllocateSnapshotAlias[class, aliasName, ref];
    If[FailureQ[aliasRes], Return[aliasRes]]
  ];
  <|"Status" -> "OK", "Ref" -> ref, "Digest" -> digest, "Path" -> path,
    "Class" -> class, "Existed" -> (status === "Existed")|>
];

SourceVaultAllocateSnapshotAlias[class_String, alias_String, ref_String, opts___] := Module[
  {path, existing, rec, json},
  path = iAliasPath[class, alias];
  If[FailureQ[path], Return[path]];
  If[FileExistsQ[path],
    existing = iFromJSON[iReadStringUTF8[path]];
    If[AssociationQ[existing] && Lookup[existing, "Ref"] === ref,
      Return[<|"Status" -> "OK", "Alias" -> alias, "Ref" -> ref, "Existed" -> True|>],
      Return[Failure["NameCollision", <|
        "MessageTemplate" -> "alias `1` は既に別 ref に割り当て済みです。",
        "Alias" -> alias, "Existing" -> Lookup[existing, "Ref"], "Requested" -> ref|>]]]
  ];
  rec = <|"Alias" -> alias, "Class" -> class, "Ref" -> ref, "CreatedAtUTC" -> iUTCNow[]|>;
  json = iToJSON[rec];
  Module[{tmp = iTmpName[path]},
    iWriteStringUTF8[tmp, json];
    iCommitCreateOnly[tmp, path];
    Quiet @ If[FileExistsQ[tmp], DeleteFile[tmp]]
  ];
  <|"Status" -> "OK", "Alias" -> alias, "Ref" -> ref, "Existed" -> False|>
];

iResolveRef[ref_String] := Module[{class, hex, aliasPath, rec},
  Which[
    StringMatchQ[ref, "snapshot:" ~~ __ ~~ ":" ~~ __],
      Module[{rest = StringDrop[ref, StringLength["snapshot:"]], p},
        p = StringPosition[rest, ":"][[-1, 1]];
        class = StringTake[rest, p - 1];
        hex = StringDrop[rest, p];
        {class, hex}],
    StringContainsQ[ref, "/"],  (* class/alias *)
      Module[{parts = StringSplit[ref, "/"]},
        class = parts[[1]]; aliasPath = iAliasPath[class, parts[[2]]];
        If[! FileExistsQ[aliasPath], Return[$Failed]];
        rec = iFromJSON[iReadStringUTF8[aliasPath]];
        If[! AssociationQ[rec], Return[$Failed]];
        iResolveRef[Lookup[rec, "Ref"]]],
    True, $Failed
  ]
];

SourceVaultLoadImmutableSnapshot[ref_String, opts___] := Module[{r, class, hex, path, str, rec},
  r = iResolveRef[ref];
  If[r === $Failed, Return[Failure["SnapshotRefUnresolved", <|"Ref" -> ref|>]]];
  {class, hex} = r;
  path = iSnapshotPath[class, hex];
  If[FailureQ[path], Return[path]];
  If[! FileExistsQ[path], Return[Failure["SnapshotNotFound", <|"Ref" -> ref, "Path" -> path|>]]];
  str = iReadStringUTF8[path];
  rec = iFromJSON[str];
  If[! AssociationQ[rec], Return[Failure["SnapshotCorrupt", <|"Ref" -> ref|>]]];
  rec
];

SourceVaultReadSnapshot[id_String, opts___] := SourceVaultLoadImmutableSnapshot[id, opts];

SourceVaultVerifyImmutableSnapshot[ref_String, opts___] := Module[
  {rec, storedDigest, recomputed, payload},
  rec = SourceVaultLoadImmutableSnapshot[ref];
  If[FailureQ[rec], Return[rec]];
  storedDigest = Lookup[rec, "Digest", Missing[]];
  (* digest は保存時付与 field を除いた元内容で再計算する *)
  payload = KeyDrop[rec, {"Digest", "StoredAtUTC", "SnapshotClass"}];
  recomputed = SourceVaultSnapshotDigest[payload];
  <|"Status" -> If[recomputed === storedDigest, "Valid", "Mismatch"],
    "Ref" -> ref, "StoredDigest" -> storedDigest, "Recomputed" -> recomputed,
    "Valid" -> (recomputed === storedDigest)|>
];

(* ============================================================
   §17.12.2  Lock primitive (atomic directory creation)
   ============================================================ *)

(* lock 名は "active-pointer:<id>" 等コロンを含む。Windows はディレクトリ名に
   : < > " / \ | ? * を使えないため安全化する。名前衝突を避けるため : は二重 _ にする。 *)
iSafeLockName[name_String] :=
  StringReplace[name, {":" -> "__", "<" -> "_", ">" -> "_", "\"" -> "_",
    "/" -> "_", "\\" -> "_", "|" -> "_", "?" -> "_", "*" -> "_"}];
iLockDir[name_String] := iSub["runtime", "locks", iSafeLockName[name] <> ".lockdir"];

iWriteLockMeta[lockDir_String, ttl_] := Module[{now, owner, hb},
  now = Now;
  owner = <|"LockName" -> FileBaseName[lockDir], "Owner" -> CreateUUID[],
    "PID" -> $pid, "Host" -> $host,
    "AcquiredAtUTC" -> iUTCString[now],
    "ExpiresAtUTC" -> iUTCString[now + Quantity[ttl, "Seconds"]],
    "TTLSeconds" -> ttl|>;
  hb = <|"HeartbeatCounter" -> 0, "UpdatedAtUTC" -> iUTCString[now]|>;
  iWriteStringUTF8[FileNameJoin[{lockDir, "owner.json"}], iToJSON[owner]];
  iWriteStringUTF8[FileNameJoin[{lockDir, "heartbeat.json"}], iToJSON[hb]];
  owner
];

iReadLockOwner[lockDir_String] := Module[{p = FileNameJoin[{lockDir, "owner.json"}]},
  If[FileExistsQ[p], iFromJSON[iReadStringUTF8[p]], Missing["NoOwner"]]
];

(* 同一 host かつ ExpiresAtUTC を過ぎていれば stale *)
iLockStaleQ[owner_] := Module[{exp},
  If[! AssociationQ[owner], Return[True]];  (* owner.json 無し/壊れ = 回収可 *)
  If[Lookup[owner, "Host"] =!= $host, Return[False]];  (* 異 host は自動回収しない *)
  exp = Quiet @ DateObject[Lookup[owner, "ExpiresAtUTC", ""], TimeZone -> 0];
  If[Head[exp] =!= DateObject, Return[True]];
  Now > exp
];

iForceReleaseLockDir[lockDir_String] :=
  Quiet @ If[DirectoryQ[lockDir], DeleteDirectory[lockDir, DeleteContents -> True]];

Options[SourceVaultTryLock] = {"TTLSeconds" -> 30};
SourceVaultTryLock[name_String, OptionsPattern[]] := Module[
  {ttl, lockDir, created, owner, existing},
  ttl = OptionValue["TTLSeconds"];
  lockDir = iLockDir[name];
  If[FailureQ[lockDir], Return[lockDir]];
  iEnsureDir[DirectoryName[lockDir]];  (* locks/ 親を非 atomic に確保 (race は無害) *)
  created = Quiet @ CreateDirectory[lockDir, CreateIntermediateDirectories -> False];
  If[StringQ[created],
    owner = iWriteLockMeta[lockDir, ttl];
    Return[<|"Acquired" -> True,
      "Handle" -> <|"LockName" -> name, "LockDir" -> lockDir,
        "Owner" -> Lookup[owner, "Owner"], "PID" -> $pid, "Host" -> $host|>,
      "Reason" -> "Created"|>]
  ];
  (* 取得失敗: stale 判定 *)
  existing = iReadLockOwner[lockDir];
  If[AssociationQ[existing] && Lookup[existing, "Host"] =!= $host,
    Return[<|"Acquired" -> False, "Reason" -> "NeedsOperatorRecovery",
      "Owner" -> existing|>]];
  If[iLockStaleQ[existing],
    iForceReleaseLockDir[lockDir];
    created = Quiet @ CreateDirectory[lockDir, CreateIntermediateDirectories -> False];
    If[StringQ[created],
      owner = iWriteLockMeta[lockDir, ttl];
      Return[<|"Acquired" -> True,
        "Handle" -> <|"LockName" -> name, "LockDir" -> lockDir,
          "Owner" -> Lookup[owner, "Owner"], "PID" -> $pid, "Host" -> $host|>,
        "Reason" -> "RecoveredStale"|>]]
  ];
  <|"Acquired" -> False, "Reason" -> "Held", "Owner" -> existing|>
];

SourceVaultReleaseLock[handle_Association] := Module[{lockDir, owner},
  lockDir = Lookup[handle, "LockDir", Missing[]];
  If[! StringQ[lockDir], Return[Failure["BadLockHandle", <|"Handle" -> handle|>]]];
  (* owner 同一性を確認してから解放 (他者の lock を消さない) *)
  owner = iReadLockOwner[lockDir];
  If[AssociationQ[owner] && Lookup[owner, "Owner"] =!= Lookup[handle, "Owner"],
    Return[<|"Status" -> "NotOwner", "LockDir" -> lockDir|>]];
  iForceReleaseLockDir[lockDir];
  <|"Status" -> "Released", "LockName" -> Lookup[handle, "LockName"]|>
];
SourceVaultReleaseLock[_] := Failure["BadLockHandle", <||>];

(* 指数 backoff つき取得 *)
iAcquireWithTimeout[name_String, timeout_, ttl_] := Module[
  {deadline, waitMs = 25, res},
  deadline = AbsoluteTime[] + timeout;
  While[True,
    res = SourceVaultTryLock[name, "TTLSeconds" -> ttl];
    If[FailureQ[res], Return[res]];
    If[TrueQ[Lookup[res, "Acquired"]], Return[res]];
    If[Lookup[res, "Reason"] === "NeedsOperatorRecovery",
      Return[Failure["LockNeedsOperatorRecovery", <|"LockName" -> name, "Owner" -> Lookup[res, "Owner"]|>]]];
    If[AbsoluteTime[] >= deadline,
      Return[Failure["LockTimeout", <|
        "MessageTemplate" -> "lock `1` を `2` 秒以内に取得できませんでした。",
        "LockName" -> name, "TimeoutSeconds" -> timeout|>]]];
    Pause[Min[waitMs, 500]/1000.];
    waitMs = Min[waitMs*2, 500];
  ]
];

SetAttributes[SourceVaultWithLock, HoldRest];
SourceVaultWithLock[name_String, body_, opts___] := Module[
  {o, timeout, ttl, acq, handle, res, aborted = False},
  o = Association @ Cases[Flatten[{opts}], _Rule];
  timeout = Lookup[o, "TimeoutSeconds", 5];
  ttl = Lookup[o, "TTLSeconds", 30];
  acq = iAcquireWithTimeout[name, timeout, ttl];
  If[FailureQ[acq], Return[acq]];
  handle = Lookup[acq, "Handle"];
  res = CheckAbort[
    Check[body, $Failed],
    aborted = True; $Aborted
  ];
  SourceVaultReleaseLock[handle];
  If[aborted, Abort[]];
  res
];

Options[SourceVaultRecoverLocks] = {};
SourceVaultRecoverLocks[opts___] := Module[{dir, lockDirs, recovered = {}, needsOp = {}, owner},
  dir = iSub["runtime", "locks"];
  If[FailureQ[dir], Return[dir]];
  If[! DirectoryQ[dir], Return[<|"Status" -> "OK", "Recovered" -> {}, "NeedsOperatorRecovery" -> {}|>]];
  lockDirs = Select[FileNames["*.lockdir", dir], DirectoryQ];
  Do[
    owner = iReadLockOwner[ld];
    Which[
      AssociationQ[owner] && Lookup[owner, "Host"] =!= $host,
        AppendTo[needsOp, <|"LockDir" -> ld, "Owner" -> owner|>],
      iLockStaleQ[owner],
        iForceReleaseLockDir[ld]; AppendTo[recovered, FileBaseName[ld]]
    ],
    {ld, lockDirs}];
  <|"Status" -> "OK", "Recovered" -> recovered, "NeedsOperatorRecovery" -> needsOp|>
];

(* ============================================================
   §17.12.5  Event log (one-event-one-file)
   ============================================================ *)

iEventDir[utcStr_String] := Module[{d},
  (* utcStr = YYYY-MM-DDThh:mm:ssZ *)
  d = DateList[DateObject[utcStr, TimeZone -> 0]];
  iSub["events", IntegerString[d[[1]], 10, 4],
    IntegerString[d[[2]], 10, 2], IntegerString[d[[3]], 10, 2]]
];

SourceVaultAppendEvent[event_Association, opts___] := Module[
  {ev, eid, createdUTC, payload, digest, dir, base, target, sidecar, str, c, lockRes},
  eid = Lookup[event, "EventID", "evt:" <> CreateUUID[]];
  createdUTC = Lookup[event, "CreatedAtUTC", iUTCNow[]];
  ev = Join[event, <|"EventID" -> eid, "CreatedAtUTC" -> createdUTC|>];
  (* digest は Digest field を除いた内容で算出 *)
  digest = SourceVaultSnapshotDigest[KeyDrop[ev, "Digest"]];
  If[FailureQ[digest], Return[digest]];
  ev = Join[ev, <|"Digest" -> digest|>];
  dir = iEventDir[createdUTC];
  If[FailureQ[dir], Return[dir]];
  base = StringReplace[eid, ":" -> "_"];
  target = FileNameJoin[{dir, base <> ".json"}];
  sidecar = FileNameJoin[{dir, base <> ".sha256"}];
  str = iToJSON[ev];
  If[! StringQ[str], Return[Failure["JSONEncodeFailed", <|"EventID" -> eid|>]]];
  lockRes = SourceVaultWithLock["vault-write-event",
    Module[{tmp, commit, existing},
      If[FileExistsQ[target],
        (* idempotency: 同 EventID の既存 event と digest 比較 *)
        existing = iFromJSON[iReadStringUTF8[target]];
        If[AssociationQ[existing] && Lookup[existing, "Digest"] === digest,
          <|"Status" -> "OK", "EventID" -> eid, "Digest" -> digest,
            "Path" -> target, "Idempotent" -> True, "Ref" -> "event:" <> eid|>,
          <|"Status" -> "EventIdCollision", "EventID" -> eid,
            "Existing" -> Lookup[existing, "Digest"], "New" -> digest|>],
        (* 新規 commit *)
        tmp = iTmpName[target];
        iWriteStringUTF8[tmp, str];
        commit = iCommitCreateOnly[tmp, target];
        Quiet @ If[FileExistsQ[tmp], DeleteFile[tmp]];
        If[commit === "Failed",
          <|"Status" -> "CommitFailed", "EventID" -> eid|>,
          iWriteStringUTF8[sidecar, digest];
          <|"Status" -> "OK", "EventID" -> eid, "Digest" -> digest,
            "Path" -> target, "Idempotent" -> False, "Ref" -> "event:" <> eid|>]
      ]],
    "TimeoutSeconds" -> 5];
  If[FailureQ[lockRes], Return[lockRes]];
  lockRes
];

iAllEventFiles[] := Module[{dir = iSub["events"]},
  If[FailureQ[dir] || ! DirectoryQ[dir], {},
    FileNames["*.json", dir, Infinity]]
];

Options[SourceVaultTransactionLog] = {"Limit" -> 100, "EventClass" -> All};
SourceVaultTransactionLog[OptionsPattern[]] := Module[{files, evs, limit, cls},
  limit = OptionValue["Limit"]; cls = OptionValue["EventClass"];
  files = iAllEventFiles[];
  evs = Select[iFromJSON[iReadStringUTF8[#]] & /@ files, AssociationQ];
  If[cls =!= All, evs = Select[evs, Lookup[#, "EventClass"] === cls &]];
  evs = ReverseSortBy[evs, Lookup[#, "CreatedAtUTC", ""] &];
  If[IntegerQ[limit], Take[evs, UpTo[limit]], evs]
];

(* ============================================================
   §17.12.6  Blob commit (content-addressed)
   ============================================================ *)

iBlobPath[hex_String] :=
  iSub["blobs", "sha256", StringTake[hex, 2], StringTake[hex, {3, 4}], hex <> ".blob"];

iToBytes[data_ByteArray] := data;
iToBytes[data_String] := StringToByteArray[data, "UTF-8"];
iToBytes[_] := $Failed;

Options[SourceVaultCommitBlob] = {"Meta" -> <||>};
SourceVaultCommitBlob[data_, OptionsPattern[]] := Module[
  {bytes, hex, path, metaPath, existed, tmp, commit, existingHex, meta},
  bytes = iToBytes[data];
  If[bytes === $Failed,
    Return[Failure["UnsupportedBlobData", <|
      "MessageTemplate" -> "blob data は ByteArray または String を指定してください。"|>]]];
  hex = iSHA256Hex[bytes];
  path = iBlobPath[hex];
  If[FailureQ[path], Return[path]];
  metaPath = StringReplace[path, ".blob" -> ".meta.json"];
  If[FileExistsQ[path],
    (* hash 整合確認 (§17.12.6-4,5) *)
    existingHex = iSHA256Hex[ReadByteArray[path]];
    If[existingHex =!= hex,
      Return[Failure["BlobCorruption", <|
        "MessageTemplate" -> "既存 blob の hash が path と一致しません (vault corruption)。",
        "Path" -> path|>]]];
    existed = True,
    (* 新規 *)
    tmp = iTmpName[path];
    iEnsureDir[DirectoryName[path]];
    Module[{strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True]},
      If[Head[strm] =!= OutputStream, Return[Failure["BlobWriteFailed", <|"Path" -> tmp|>]]];
      BinaryWrite[strm, bytes]; Close[strm]];
    commit = iCommitCreateOnly[tmp, path];
    Quiet @ If[FileExistsQ[tmp], DeleteFile[tmp]];
    If[commit === "Failed", Return[Failure["BlobCommitFailed", <|"Path" -> path|>]]];
    existed = False
  ];
  meta = Join[<|"Hash" -> hex, "Bytes" -> Length[bytes], "CreatedAtUTC" -> iUTCNow[]|>,
    OptionValue["Meta"]];
  If[! FileExistsQ[metaPath], iWriteStringUTF8[metaPath, iToJSON[meta]]];
  <|"Status" -> "OK", "Hash" -> hex, "BlobRef" -> "blob:sha256:" <> hex,
    "Path" -> path, "Existed" -> existed|>
];

SourceVaultBlobRefs[hash_String, opts___] := Module[{hex, refs = {}, files, str},
  hex = iBareDigest[StringReplace[hash, "blob:sha256:" -> ""]];
  (* snapshot / event JSON 中に hash 文字列が現れる箇所を参照とみなす (保守的) *)
  files = Join[
    Module[{d = iSub["snapshots"]}, If[DirectoryQ[d], FileNames["*.json", d, Infinity], {}]],
    iAllEventFiles[]];
  Do[
    str = iReadStringUTF8[f];
    If[StringQ[str] && StringContainsQ[str, hex], AppendTo[refs, f]],
    {f, files}];
  <|"Hash" -> hex, "RefCount" -> Length[refs], "Refs" -> refs|>
];

(* ============================================================
   §17.12.7  Pointer (event-sourced, no overwrite-rename)
   ============================================================ *)

iPointerEventDir[name_String] := iSub["pointers", name, "events"];
iPointerCachePath[name_String] := iSub["pointers", name, "active.json"];

iPointerEvents[name_String] := Module[{dir = iPointerEventDir[name], files},
  If[FailureQ[dir] || ! DirectoryQ[dir], Return[{}]];
  files = FileNames["*.json", dir];
  Select[iFromJSON[iReadStringUTF8[#]] & /@ files, AssociationQ]
];

SourceVaultAtomicUpdatePointer[name_String, value_, opts___] := Module[{lockRes},
  lockRes = SourceVaultWithLock["active-pointer:" <> name,
    Module[{evs, seq, ev, digest, stamp, dir, target, tmp, cacheRec},
      evs = iPointerEvents[name];
      seq = If[evs === {}, 1, Max[Lookup[#, "Sequence", 0] & /@ evs] + 1];
      ev = <|"EventClass" -> "PointerUpdated", "EventID" -> "evt:" <> CreateUUID[],
        "PointerName" -> name, "Sequence" -> seq, "Value" -> value,
        "CreatedAtUTC" -> iUTCNow[]|>;
      digest = SourceVaultSnapshotDigest[ev];
      ev = Join[ev, <|"Digest" -> digest|>];
      stamp = iSafeStamp[Lookup[ev, "CreatedAtUTC"]] <> "-" <> StringTake[CreateUUID[], 8];
      dir = iPointerEventDir[name];
      target = FileNameJoin[{dir, stamp <> ".json"}];
      tmp = iTmpName[target];
      iWriteStringUTF8[tmp, iToJSON[ev]];
      iCommitCreateOnly[tmp, target];
      Quiet @ If[FileExistsQ[tmp], DeleteFile[tmp]];
      (* active.json cache (正本ではない。reader は digest 検証し失敗時 replay) *)
      cacheRec = <|"PointerName" -> name, "Sequence" -> seq, "Value" -> value,
        "Digest" -> digest, "UpdatedAtUTC" -> iUTCNow[]|>;
      iWriteStringUTF8[iPointerCachePath[name], iToJSON[cacheRec]];
      <|"Status" -> "OK", "Name" -> name, "Sequence" -> seq, "Value" -> value,
        "EventRef" -> Lookup[ev, "EventID"]|>
    ], "TimeoutSeconds" -> 5];
  lockRes
];

SourceVaultPointerReplay[name_String, opts___] := Module[
  {evs, valid, top, cachePath, cache, cacheConsistent, seqs},
  evs = iPointerEvents[name];
  If[evs === {}, Return[<|"Status" -> "Empty", "Value" -> Missing["NoPointer"],
    "Sequence" -> 0, "EventCount" -> 0, "CacheConsistent" -> True|>]];
  (* digest 検証 *)
  valid = Select[evs, Function[e,
    SourceVaultSnapshotDigest[KeyDrop[e, "Digest"]] === Lookup[e, "Digest"]]];
  If[valid === {}, Return[Failure["PointerAllEventsCorrupt", <|"Name" -> name|>]]];
  seqs = Lookup[#, "Sequence", 0] & /@ valid;
  top = First @ MaximalBy[valid, Lookup[#, "Sequence", 0] &];
  (* cache 整合 *)
  cachePath = iPointerCachePath[name];
  cache = If[FileExistsQ[cachePath], iFromJSON[iReadStringUTF8[cachePath]], Missing[]];
  cacheConsistent = AssociationQ[cache] && Lookup[cache, "Sequence"] === Lookup[top, "Sequence"];
  <|"Status" -> "OK", "Value" -> Lookup[top, "Value"],
    "Sequence" -> Lookup[top, "Sequence"], "EventCount" -> Length[evs],
    "ValidCount" -> Length[valid], "CacheConsistent" -> cacheConsistent,
    "SequenceDuplicated" -> (Length[seqs] =!= Length[DeleteDuplicates[seqs]])|>
];

SourceVaultPointerHistory[name_String, opts___] := Module[{evs, valid},
  evs = iPointerEvents[name];
  valid = Select[evs, Function[e,
    SourceVaultSnapshotDigest[KeyDrop[e, "Digest"]] === Lookup[e, "Digest"]]];
  SortBy[
    <|"Sequence" -> Lookup[#, "Sequence"], "Value" -> Lookup[#, "Value"],
      "CreatedAtUTC" -> Lookup[#, "CreatedAtUTC"]|> & /@ valid,
    Lookup[#, "Sequence"] &]
];

(* ============================================================
   §17.12.10  GC / retention
   ============================================================ *)

$gcGraceSeconds = 24*3600;
SourceVaultGCGracePeriod[] := $gcGraceSeconds;

iAllBlobFiles[] := Module[{d = iSub["blobs"]},
  If[FailureQ[d] || ! DirectoryQ[d], {}, FileNames["*.blob", d, Infinity]]
];

Options[SourceVaultRunGC] = {"ConfirmDelete" -> False, "GraceSeconds" -> Automatic};
SourceVaultRunGC[OptionsPattern[]] := Module[
  {grace, confirm, consistency, blobs, now, candidates = {}, protected = {}, deleted = {},
   hex, refs, ageSec},
  confirm = TrueQ[OptionValue["ConfirmDelete"]];
  grace = OptionValue["GraceSeconds"] /. Automatic -> $gcGraceSeconds;
  (* replay 失敗 vault では GC しない (§17.12.10 fail-closed) *)
  consistency = SourceVaultCheckVaultConsistency["Quick" -> True];
  If[! TrueQ[Lookup[consistency, "Healthy"]],
    Return[<|"Status" -> "Skipped", "Reason" -> "VaultNotHealthy",
      "Consistency" -> consistency|>]];
  blobs = iAllBlobFiles[];
  now = AbsoluteTime[];
  Do[
    hex = FileBaseName[bf];
    ageSec = now - AbsoluteTime[FileDate[bf, "Modification"]];
    refs = SourceVaultBlobRefs[hex];
    Which[
      Lookup[refs, "RefCount"] > 0, Null,  (* 参照あり: 保持 *)
      ageSec < grace, AppendTo[protected, <|"Hash" -> hex, "Reason" -> "GracePeriod",
        "AgeSeconds" -> Round[ageSec]|>],
      True, AppendTo[candidates, <|"Hash" -> hex, "Path" -> bf,
        "AgeSeconds" -> Round[ageSec]|>]
    ],
    {bf, blobs}];
  If[confirm,
    Do[Quiet @ DeleteFile[Lookup[c, "Path"]];
       Quiet @ DeleteFile[StringReplace[Lookup[c, "Path"], ".blob" -> ".meta.json"]];
       AppendTo[deleted, Lookup[c, "Hash"]],
      {c, candidates}]];
  <|"Status" -> If[confirm, "Deleted", "DryRun"],
    "Candidates" -> candidates, "Deleted" -> deleted,
    "ProtectedByInFlightWrite" -> protected,
    "GraceSeconds" -> grace, "Confirmed" -> confirm|>
];

SourceVaultGCDryRun[opts___] := SourceVaultRunGC["ConfirmDelete" -> False, opts];

SourceVaultRetentionPlan[scope_:All, opts___] := Module[{blobs, plan},
  blobs = iAllBlobFiles[];
  plan = Function[bf, Module[{hex = FileBaseName[bf], refs},
    refs = SourceVaultBlobRefs[hex];
    <|"Hash" -> hex, "RefCount" -> Lookup[refs, "RefCount"],
      "Referenced" -> (Lookup[refs, "RefCount"] > 0),
      "AgeSeconds" -> Round[AbsoluteTime[] - AbsoluteTime[FileDate[bf, "Modification"]]]|>]] /@ blobs;
  <|"Status" -> "OK", "Scope" -> scope, "BlobCount" -> Length[plan], "Plan" -> plan|>
];

(* ============================================================
   §17.12.11  Consistency check / concurrent write test
   ============================================================ *)

Options[SourceVaultCheckVaultConsistency] = {"Quick" -> False};
SourceVaultCheckVaultConsistency[OptionsPattern[]] := Module[
  {quick, eventFiles, evChecks, ids, idUnique, idCollisions = {}, digestMismatches = {},
   sidecarMissing = {}, blobMismatches = {}, orphanTmps = {}, staleLocks = {},
   ptrIssues = {}, pointerNames, blobs, now, healthy, ev, sidecar, hexExp,
   tmpFiles, ld, owner},
  quick = TrueQ[OptionValue["Quick"]];

  (* 1,2: event digest 一致 + EventID 一意 *)
  eventFiles = iAllEventFiles[];
  ids = {};
  Do[
    ev = iFromJSON[iReadStringUTF8[ef]];
    If[AssociationQ[ev],
      AppendTo[ids, Lookup[ev, "EventID"]];
      If[SourceVaultSnapshotDigest[KeyDrop[ev, "Digest"]] =!= Lookup[ev, "Digest"],
        AppendTo[digestMismatches, ef]];
      sidecar = StringReplace[ef, ".json" -> ".sha256"];
      If[! FileExistsQ[sidecar], AppendTo[sidecarMissing, ef]]
    ],
    {ef, eventFiles}];
  (* 同一 EventID で digest が異なる場合のみ collision (path は eventId 由来で本来一意) *)
  idUnique = Length[ids] === Length[DeleteDuplicates[ids]];

  (* 3,4: pointer sequence 単調 + cache 整合 *)
  pointerNames = Module[{d = iSub["pointers"]},
    If[DirectoryQ[d], FileBaseName /@ Select[FileNames["*", d], DirectoryQ], {}]];
  Do[
    Module[{rep = SourceVaultPointerReplay[pn]},
      If[FailureQ[rep], AppendTo[ptrIssues, <|"Pointer" -> pn, "Issue" -> "ReplayFailed"|>]];
      If[AssociationQ[rep] && TrueQ[Lookup[rep, "SequenceDuplicated"]],
        AppendTo[ptrIssues, <|"Pointer" -> pn, "Issue" -> "SequenceDuplicated"|>]];
      If[AssociationQ[rep] && ! TrueQ[Lookup[rep, "CacheConsistent"]],
        AppendTo[ptrIssues, <|"Pointer" -> pn, "Issue" -> "CacheInconsistent"|>]]
    ],
    {pn, pointerNames}];

  (* 5: blob hash 整合 (quick では skip) *)
  If[! quick,
    blobs = iAllBlobFiles[];
    Do[hexExp = FileBaseName[bf];
      If[iSHA256Hex[ReadByteArray[bf]] =!= hexExp, AppendTo[blobMismatches, bf]],
      {bf, blobs}]];

  (* 7: orphan tmp (grace 超過) *)
  now = AbsoluteTime[];
  tmpFiles = Module[{r = iResolveRoot[]},
    If[StringQ[r], FileNames["*.tmp.*", r, Infinity], {}]];
  orphanTmps = Select[tmpFiles,
    (now - AbsoluteTime[FileDate[#, "Modification"]]) > $gcGraceSeconds &];

  (* 8: stale lock *)
  Module[{d = iSub["runtime", "locks"]},
    If[DirectoryQ[d],
      Do[owner = iReadLockOwner[ld];
        If[iLockStaleQ[owner], AppendTo[staleLocks, FileBaseName[ld]]],
        {ld, Select[FileNames["*.lockdir", d], DirectoryQ]}]]];

  healthy = idUnique && digestMismatches === {} && idCollisions === {} &&
    blobMismatches === {} && ptrIssues === {};

  <|"Status" -> "OK", "Healthy" -> healthy,
    "EventCount" -> Length[eventFiles],
    "EventIdUnique" -> idUnique,
    "EventDigestMismatches" -> digestMismatches,
    "EventIdCollisions" -> idCollisions,
    "SidecarMissing" -> sidecarMissing,
    "PointerIssues" -> ptrIssues,
    "BlobHashMismatches" -> blobMismatches,
    "OrphanTmp" -> orphanTmps,
    "StaleLocks" -> staleLocks,
    "Quick" -> quick|>
];

(* 単一 kernel での逐次/並行 write 検証 + idempotency / collision 検出 *)
Options[SourceVaultConcurrentWriteTest] = {
  "Processes" -> 2, "PerProcessEvents" -> 100, "Parallel" -> False};
SourceVaultConcurrentWriteTest[OptionsPattern[]] := Module[
  {nProc, perProc, parallel, root, writer, results, allEvents, consistency,
   idemId, idemA, idemB, collId, collA, collB, blobR, blobR2, ptrR, passed, criteria},
  nProc = OptionValue["Processes"];
  perProc = OptionValue["PerProcessEvents"];
  parallel = TrueQ[OptionValue["Parallel"]];
  root = iResolveRoot[];
  If[FailureQ[root], Return[root]];

  writer = Function[{procIdx},
    Table[
      SourceVaultAppendEvent[<|"EventClass" -> "ConcurrentWriteTest",
        "Proc" -> procIdx, "N" -> k, "Payload" -> CreateUUID[]|>],
      {k, perProc}]];

  results =
    If[parallel && Length[Quiet @ Kernels[]] > 0 && StringQ[$coreFile],
      Quiet @ Check[
        ParallelEvaluate[Block[{$CharacterEncoding = "UTF-8"}, Get[$coreFile]];];
        ParallelTable[writer[p], {p, nProc}],
        writer /@ Range[nProc]],
      writer /@ Range[nProc]];

  allEvents = Flatten[results];

  (* idempotency: 同 EventID を 2 回 append → 2 回目 Idempotent True *)
  idemId = "evt:" <> CreateUUID[];
  idemA = SourceVaultAppendEvent[<|"EventID" -> idemId, "EventClass" -> "IdemTest", "V" -> 1|>];
  idemB = SourceVaultAppendEvent[<|"EventID" -> idemId, "EventClass" -> "IdemTest", "V" -> 1|>];

  (* collision: 同 EventID で内容違い → EventIdCollision *)
  collId = "evt:" <> CreateUUID[];
  collA = SourceVaultAppendEvent[<|"EventID" -> collId, "EventClass" -> "CollTest", "V" -> 1|>];
  collB = SourceVaultAppendEvent[<|"EventID" -> collId, "EventClass" -> "CollTest", "V" -> 2|>];

  (* blob idempotency *)
  blobR = SourceVaultCommitBlob["concurrent-test-payload"];
  blobR2 = SourceVaultCommitBlob["concurrent-test-payload"];

  (* pointer *)
  Do[SourceVaultAtomicUpdatePointer["concurrent-test-pointer", k], {k, 5}];
  ptrR = SourceVaultPointerReplay["concurrent-test-pointer"];

  consistency = SourceVaultCheckVaultConsistency[];

  criteria = <|
    "NoEventIdCollisionInBulk" -> AllTrue[allEvents, Lookup[#, "Status"] === "OK" &],
    "IdempotentRetry" -> (Lookup[idemB, "Idempotent"] === True &&
      Lookup[idemA, "Digest"] === Lookup[idemB, "Digest"]),
    "CollisionDetected" -> (Lookup[collA, "Status"] === "OK" &&
      Lookup[collB, "Status"] === "EventIdCollision"),
    "BlobIdempotent" -> (Lookup[blobR, "Hash"] === Lookup[blobR2, "Hash"] &&
      Lookup[blobR2, "Existed"] === True),
    "PointerSequenceOK" -> (Lookup[ptrR, "Sequence"] >= 5 &&
      ! TrueQ[Lookup[ptrR, "SequenceDuplicated"]]),
    "ConsistencyHealthy" -> TrueQ[Lookup[consistency, "Healthy"]]
  |>;
  passed = AllTrue[Values[criteria], TrueQ];

  <|"Status" -> "OK", "Passed" -> passed, "Criteria" -> criteria,
    "Processes" -> nProc, "PerProcessEvents" -> perProc, "Parallel" -> parallel,
    "BulkEventsWritten" -> Length[allEvents],
    "Consistency" -> consistency|>
];

End[]  (* `CorePrivate` *)

EndPackage[]  (* SourceVault` *)
(* ロード時ヘルプは削除。API 一覧は SourceVault_info/docs を参照。 *)
