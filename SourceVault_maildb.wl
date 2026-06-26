(* ::Package:: *)

(* ============================================================
   SourceVault_maildb.wl -- MailDB -> SourceVault snapshot adapter (Phase SV-E5)

   This file is encoded in UTF-8.
   Load order: ... -> SourceVault_encryptedstore.wl -> SourceVault_keys.wl
               -> SourceVault_addressbook.wl -> SourceVault_maildb.wl

   旧 maildb (maildb_legacy.wl) の月次 .wl record を SourceVaultMailSnapshot に正規化する。
   第一スライス:
     - RecordId / MessageIDToken は SourceVault:mailid:mac:v1 の keyed HMAC
     - body は SourceVaultEncryptedPut で暗号化 (inline)。PL は fail-safe (既定 0.85)
     - maildb privacy(0/1) は provenance のみ。release/cloud 判定の真実源にしない
     - From/To/Cc を AddressBook に照合 (AddressBookRefs)
     - header (subject/from/to) は既定で平文 + token (Dropbox 前提)。EncryptHeaders->True で暗号化
     - 添付は件数のみ。embedding は未取り込み (provenance に cloud 由来フラグ)
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultMailSnapshotFromMaildb::usage = "SourceVaultMailSnapshotFromMaildb[record_Association, mbox_String, opts] は旧 maildb record を SourceVaultMailSnapshot に変換する。body は暗号化、PL は fail-safe。";
SourceVaultImportMaildbFile::usage = "SourceVaultImportMaildbFile[file_String, mbox_String, opts] は旧 maildb 月次 .wl を読み、各 record を MailSnapshot に変換する。Persist->True で snapshot store に保存。";
SourceVaultMailSnapshotPut::usage = "SourceVaultMailSnapshotPut[snapshot, opts] は snapshot を RecordId をキーに store へ保存 (冪等)。";
SourceVaultMailSnapshotGet::usage = "SourceVaultMailSnapshotGet[recordId] は保存済み snapshot を返す。";
SourceVaultMailSnapshotList::usage = "SourceVaultMailSnapshotList[] は保存済み snapshot を返す。";
SourceVaultIdentityBackfillFromMail::usage = "SourceVaultIdentityBackfillFromMail[] は現在ロード済みの snapshot の平文 From/To/Cc を走査して識別子(2層アドレス帳)を一括生成する。再取込不要。スコープは先に SourceVaultMailEnsureLoaded で決める。";
SourceVaultSearchMailSnapshots::usage = "SourceVaultSearchMailSnapshots[query_String:\"\", opts] は subject/summary 部分一致 + From / To / FromContact / MBox / DateFrom / DateTo / HasAttachment / Category / HasDeadline / DeadlineFrom / DeadlineTo で検索し、Newest(既定 True)で日付降順、Limit で件数制限する。Category は $SourceVaultMailCategories のトークン(日本語名 \"作業依頼\" 等でも可)。DeadlineFrom/DeadlineTo は〆切日を日単位包含で範囲指定(例: 今週〆切の作業依頼 = \"Category\"->\"TaskRequest\", \"DeadlineFrom\"->今日, \"DeadlineTo\"->週末)。SortBy は \"Date\"|\"Priority\"|\"PrivacyLevel\"|\"Deadline\"。";
SourceVaultMailSummaryRow::usage = "SourceVaultMailSummaryRow[snapshot] は一覧表示用の低漏洩行 <|Date, From, Subject, Category, Deadline, Attach, MBox, RecordId, BodyEncrypted|> を返す。From は AddressBook 解決時は表示名。Category は依頼カテゴリトークン、Deadline は〆切の ISO 文字列 (無ければ Missing)。";
$SourceVaultMailCategories::usage = "メール派生カテゴリの語彙: InfoProvision=情報提供, AttendanceRequest=(会議等への)出席依頼, TaskRequest=作業・仕事の依頼, Confirmation=確認・承認依頼, Report=報告, Notice=通知・一斉配信, Other=その他。Derived.Category と検索オプション \"Category\" で使う。";
SourceVaultMailSearchSummary::usage = "SourceVaultMailSearchSummary[query_String:\"\", opts] は検索結果を SummaryRow のリスト(新着順・Limit 適用)で返す。";
SourceVaultMailDataset::usage = "SourceVaultMailDataset[query_String:\"\", opts] は検索結果を素の Dataset で返す(列ソート用、ボタン無し)。";
SourceVaultMailStoreSave::usage = "SourceVaultMailStoreSave[\"All\"->False] は変更のあった月次シャードのみ (All->True で全シャード) を byte-exact 保存する。";
SourceVaultMailStoreLoad::usage = "SourceVaultMailStoreLoad[] は全シャードを読み込む(重い)。通常は SourceVaultMailEnsureLoaded で必要分だけ遅延ロードする。";
SourceVaultMailAvailableShards::usage = "SourceVaultMailAvailableShards[mbox_:All] はディスク上のシャード {mbox, yyyymm} の一覧をロードせずに返す。";
SourceVaultMailEnsureLoaded::usage = "SourceVaultMailEnsureLoaded[mbox_String, period_:Automatic] は指定 mbox の期間分シャードだけをメモリへ遅延ロードする。period: \"YYYYMM\" | {from,to} | \"Latest\"/Automatic | n(直近n月) | All。既ロードは再読込しない。";
SourceVaultMailLoadShard::usage = "SourceVaultMailLoadShard[\"mbox/yyyymm\"] は1シャードをロードする。";
SourceVaultMailUnloadAll::usage = "SourceVaultMailUnloadAll[] はメモリ上の snapshot を解放する。";
SourceVaultMailLoadedCount::usage = "SourceVaultMailLoadedCount[] は現在メモリにある snapshot 数を返す。";
SourceVaultMailStoreRoot::usage = "SourceVaultMailStoreRoot[] は snapshot store のルートを返す。";
SourceVaultMailShardPath::usage = "SourceVaultMailShardPath[\"mbox/yyyymm\"] は月次シャードのパスを返す。";
SourceVaultMailMigrateToShards::usage = "SourceVaultMailMigrateToShards[] は旧単一ファイル snapshots.svmail を mbox×月のシャードに移行し、旧ファイルを .bak にする。";
SourceVaultMailStorePath::usage = "SourceVaultMailStorePath[] は旧単一ファイル (移行用) のパスを返す。";
$SourceVaultMailStoreRoot::usage = "mail snapshot store のルート (既定 PrivateVault/mail/snapshots)。テストで上書き可。";
SourceVaultMailSearchIndex::usage = "SourceVaultMailSearchIndex[query_String:\"\", opts] はディスク上の軽量メタデータ索引 (各 shard の .svmailidx sidecar) だけを走査し、snapshot 本体 (本文暗号文) をメモリへロードせずに低漏洩メタ/サマリー行 (SummaryRow 形 + Summary) を返す。opts は SourceVaultSearchMailSnapshots と同じ (To/Cc/FromContact 等 index 非保持の項目は無視)。年単位の全メールをロードし続けなくても検索できる。索引は SourceVaultMailStoreSave 時に自動更新され、既存データには SourceVaultMailRebuildMetadataIndex で一括生成する。";
SourceVaultMailRebuildMetadataIndex::usage = "SourceVaultMailRebuildMetadataIndex[mbox_:All] はディスク上の各 shard を一時的に読み、低漏洩メタデータ索引 sidecar (.svmailidx) を再生成する ($iSVMDStore は変更しない)。既存 .svmail から索引を初回構築/再構築するのに使う。";
SourceVaultMailIndexedCount::usage = "SourceVaultMailIndexedCount[mbox_:All] はディスク上の索引 sidecar に含まれる行数 (索引済みメール数) を返す。";
SourceVaultMailIndexGet::usage = "SourceVaultMailIndexGet[recordId_String] は索引 sidecar から該当 RecordId の低漏洩メタ/サマリー行を1件返す (snapshot 本体はロードしない)。無ければ Missing[\"NotFound\"]。MCP の単一 URI 解決 (sourcevault_get) 用。";
SourceVaultMailSnapshotDecryptBody::usage = "SourceVaultMailSnapshotDecryptBody[snapshot] は snapshot の暗号化 body を復号して返す (MAC 検証経由)。";
SourceVaultMailParseEmails::usage = "SourceVaultMailParseEmails[headerValue_String] はヘッダ文字列からメールアドレスを抽出する。";
$SourceVaultDefaultImportedMailPL::usage = "import 時のメール本文 PL 既定 (fail-safe, 既定 0.85)。maildb privacy は信用しない。";

Begin["`Private`"];

If[! ValueQ[$SourceVaultDefaultImportedMailPL], $SourceVaultDefaultImportedMailPL = 0.85];

$iSVMDEmailPattern = RegularExpression["[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}"];

SourceVaultMailParseEmails[s_String] :=
  DeleteDuplicates[ToLowerCase /@ StringCases[s, $iSVMDEmailPattern]];
SourceVaultMailParseEmails[_] := {};

iSVMDFirstEmail[s_] := With[{es = SourceVaultMailParseEmails[s]}, If[es === {}, Missing["NoEmail"], First[es]]];

(* keyed HMAC token (mailid 鍵)。鍵が無ければ Missing。 *)
iSVMDMailToken[str_String] :=
  Module[{k},
    k = Quiet@Check[NBAccess`NBKeyStatus[SourceVault`$SourceVaultDefaultMailIdentityHMACKeyRef], Missing[]];
    If[! AssociationQ[k], Return[Missing["NoKey"]]];
    Quiet@Check[
      NBAccess`NBMacWithKeyRef[SourceVault`$SourceVaultDefaultMailIdentityHMACKeyRef,
        StringToByteArray[str, "UTF-8"], "MailIdentityToken"], Missing["TokenFailed"]]];

(* RecordId = SHA256(canonical {mbox, MessageID})[:24]。鍵に依存しない決定的 ID。
   再 import / IMAP 増分で恒久的に冪等 (鍵の有無・ローテーションで値が変わらない)。
   連結防止が要る箇所は別途キー付き MessageIDToken/FromToken/SubjectToken を使う。 *)
iSVMDRecordId[mbox_, msgId_] :=
  Module[{canon},
    canon = SourceVault`SourceVaultCanonicalJSONBytes[<|"MBox" -> mbox, "MessageID" -> msgId|>];
    "svmail-" <> StringTake[
       StringJoin[IntegerString[#, 16, 2] & /@ Normal[Hash[canon, "SHA256", "ByteArray"]]], 24]];

iSVMDToUTC[d_] :=
  Which[
    Head[d] === DateObject,
      Quiet@Check[DateString[TimeZoneConvert[d, 0], "ISODateTime"] <> "Z", Missing["BadDate"]],
    StringQ[d], d,
    True, Missing["Unknown"]];

iSVMDAttachmentNames[a_] :=
  Which[
    StringQ[a] && StringTrim[a] =!= "", Select[StringTrim /@ StringSplit[a, ","], # =!= "" &],
    ListQ[a], a, True, {}];
iSVMDAttachmentCount[a_] := Length[iSVMDAttachmentNames[a]];

iSVMDContactRefFor[emailHeader_] :=
  Module[{em, c},
    em = iSVMDFirstEmail[emailHeader];
    If[! StringQ[em], Return[Missing["Unknown"]]];
    c = Quiet@Check[SourceVault`SourceVaultAddressBookFindByEmail[em], Missing[]];
    If[AssociationQ[c], c["ContactId"], Missing["NotInAddressBook"]]];

iSVMDContactRefsFor[emailHeader_] :=
  Module[{ems},
    ems = SourceVaultMailParseEmails[If[StringQ[emailHeader], emailHeader, ""]];
    (Module[{c = Quiet@Check[SourceVault`SourceVaultAddressBookFindByEmail[#], Missing[]]},
        If[AssociationQ[c], c["ContactId"], Missing["NotInAddressBook"]]] &) /@ ems];

(* 取込時に From/To/Cc を識別子(2層アドレス帳)へ自動登録。identity 未ロードでも安全。 *)
iSVMDIngestIds[header_, mbox_] :=
  Quiet@Check[
    If[StringQ[header] && Length[DownValues[SourceVault`SourceVaultIngestAddressHeader]] > 0,
      SourceVault`SourceVaultIngestAddressHeader[header, "MBox" -> mbox], {}], {}];
iSVMDFirstId[ids_] := If[ListQ[ids] && ids =!= {}, First[ids], Missing["NoIdentifier"]];
iSVMDIdentityEnsureLoaded[] :=
  Quiet@Check[If[Length[DownValues[SourceVault`SourceVaultIdentityEnsureLoaded]] > 0,
     SourceVault`SourceVaultIdentityEnsureLoaded[], Null], Null];
iSVMDIdentitySaveSafe[] :=
  Quiet@Check[If[Length[DownValues[SourceVault`SourceVaultIdentitySave]] > 0,
     SourceVault`SourceVaultIdentitySave[], Null], Null];

Options[SourceVaultMailSnapshotFromMaildb] = {
  "PrivacyLevel" -> Automatic, "EncryptHeaders" -> False, "StoreBody" -> "Encrypted"};

SourceVaultMailSnapshotFromMaildb[record_Association, mbox_String, OptionsPattern[]] :=
  Module[{msgId, recId, pl, subject, from, to, cc, body, encHeaders,
     bodyRef, headerEnc, mdPrivacy, mailDelivery, snapshot},
    msgId = ToString[Lookup[record, "id", Lookup[record, "MessageID", "unknown"]]];
    recId = iSVMDRecordId[mbox, msgId];
    pl = OptionValue["PrivacyLevel"] /. Automatic -> $SourceVaultDefaultImportedMailPL;
    encHeaders = TrueQ[OptionValue["EncryptHeaders"]];
    subject = ToString[Lookup[record, "subject", ""]];
    from = ToString[Lookup[record, "from", ""]];
    to   = ToString[Lookup[record, "to", ""]];
    cc   = ToString[Lookup[record, "cc", ""]];
    body = Lookup[record, "body", Missing["NoBody"]];
    mdPrivacy = Lookup[record, "privacy", Missing["Unknown"]];

    (* 配送 feature (§8.1.1, 配線(b)): raw header を fetch 時に parse し coarse feature だけ保存。
       raw header 本体は snapshot に載せない (privacy)。mining 未ロード/raw header 無しは Missing。 *)
    mailDelivery = With[{rh = Lookup[record, "rawheader", Missing[]]},
      If[StringQ[rh] && rh =!= "" &&
         Length[Names["SourceVault`SourceVaultMiningMailHeaderObservation"]] > 0 &&
         Length[DownValues[SourceVault`SourceVaultMiningMailHeaderObservation]] > 0,
        Quiet@Check[
          Lookup[SourceVault`SourceVaultMiningMailHeaderObservation[rh, "SourceID" -> recId],
            "SnapshotFeatures", Missing["NoFeatures"]], Missing["DeliveryParseFailed"]],
        Missing["NoRawHeader"]]];

    (* body: 既定で暗号化 (PL fail-safe)。inline EncryptedPayload record。 *)
    bodyRef = If[StringQ[body] && OptionValue["StoreBody"] === "Encrypted",
       With[{put = SourceVault`SourceVaultEncryptedPut[<|"Body" -> body|>,
            "PrivacyLevel" -> pl, "ContentType" -> "MailBody", "Persist" -> False,
            "SensitiveFields" -> {"Body"}]},
         If[Lookup[put, "Status", ""] === "Stored", put["Record"], Missing["EncryptFailed"]]],
       If[StringQ[body], Missing["NotStored"], Missing["NoBody"]]];

    (* header: 既定平文 + token。EncryptHeaders->True で暗号化 record に移す。 *)
    headerEnc = If[encHeaders && (StringQ[subject] || StringQ[from]),
       With[{put = SourceVault`SourceVaultEncryptedPut[
            <|"Subject" -> subject, "From" -> from, "To" -> to, "Cc" -> cc|>,
            "PrivacyLevel" -> pl, "ContentType" -> "MailHeader", "Persist" -> False,
            "SensitiveFields" -> {"Subject", "From", "To", "Cc"}]},
         If[Lookup[put, "Status", ""] === "Stored", put["Record"], Missing["EncryptFailed"]]],
       Missing["PlainHeaderAllowed"]];

    snapshot = <|
      "Type" -> "SourceVaultMailSnapshot", "SchemaVersion" -> 1,
      "RecordId" -> recId,
      (* 送信者認証 (信頼 authserv-id の A-R のみ採用)。legacy maildb は A-R 無し
         -> Source "Missing" -> sender-based loosening 不可。 *)
      "SenderAuthentication" -> SourceVault`SourceVaultSenderAuthentication[record],
      (* 配送 coarse feature (raw header は載せない、§8.1.1)。delivery anomaly→metacog conflict 入力。 *)
      "MailDelivery" -> mailDelivery,
      "MailSource" -> <|
         "Kind" -> "MaildbMonthlyFile", "MBox" -> mbox,
         "MessageIDToken" -> iSVMDMailToken[msgId],
         "ThreadID" -> Missing["SourceHeaderUnavailable"],
         "FetchedAt" -> DateString["ISODateTime"],
         "RawMIMEStatus" -> "UnavailableFromMaildb"|>,
      "MailMetadataPublic" -> <|
         "Date" -> iSVMDToUTC[Lookup[record, "date", Missing["Unknown"]]],
         "HeaderPolicy" -> If[encHeaders, "EncryptedHeader", "PlainHeaderAllowed"],
         "Subject" -> If[encHeaders, Missing["Encrypted"], subject],
         "From" -> If[encHeaders, Missing["Encrypted"], from],
         "To" -> If[encHeaders, Missing["Encrypted"], to],
         "Cc" -> If[encHeaders, Missing["Encrypted"], cc],
         "FromToken" -> iSVMDMailToken[ToString[iSVMDFirstEmail[from]]],
         "SubjectToken" -> iSVMDMailToken[subject],
         "AttachmentCount" -> iSVMDAttachmentCount[Lookup[record, "attachment", ""]],
         "Attachments" -> iSVMDAttachmentNames[Lookup[record, "attachment", ""]],
         "HasBody" -> StringQ[body]|>,
      "AddressBookRefs" -> With[{
          fromIds = iSVMDIngestIds[from, mbox],
          toIds = iSVMDIngestIds[to, mbox],
          ccIds = iSVMDIngestIds[cc, mbox]},
        <|"FromContact" -> iSVMDContactRefFor[from],
          "ToContacts" -> iSVMDContactRefsFor[to],
          "CcContacts" -> iSVMDContactRefsFor[cc],
          "FromIdentifier" -> iSVMDFirstId[fromIds],
          "ToIdentifiers" -> toIds,
          "CcIdentifiers" -> ccIds|>],
      "Derived" -> <|
         "PrivacyLevel" -> pl,
         "AccessTags" -> {}, "DenyTags" -> {},
         "Summary" -> Lookup[record, "summary", Missing["NotGenerated"]],
         (* カテゴリ ($SourceVaultMailCategories トークン) と 〆切 (ISO 文字列、ローカル時刻意図)。
            旧 maildb record には無いので LLM 派生 (iSVApplyDerived) で埋まる。 *)
         "Category" -> Missing["NotGenerated"],
         "Deadline" -> Missing["NotGenerated"],
         "Priority" -> Lookup[record, "priority", Missing["NotGenerated"]],
         (* 派生フィールド (PL/Priority/Summary) が LLM 等で確定済みか。
            未確定 (新規 IMAP 取込で未処理) は "Pending" -> 後から増分バッチで処理。 *)
         "DerivedStatus" -> With[{sm = Lookup[record, "summary", Missing[]],
              pr = Lookup[record, "priority", Missing[]]},
            If[StringQ[sm] && StringTrim[sm] =!= "" && NumericQ[pr] && TrueQ[pr >= 0],
              "Processed", "Pending"]],
         "DerivedSource" -> If[KeyExistsQ[record, "summary"], "MaildbLegacy", Missing["NotGenerated"]],
         "DerivedFieldPolicy" -> <|
            "CloudGeneratedBeforeSourceVault" ->
              (KeyExistsQ[record, "embedding"] || KeyExistsQ[record, "summary"])|>|>,
      "PayloadRefs" -> <|
         "Body" -> bodyRef, "EncryptedHeader" -> headerEnc,
         "RawMIME" -> Missing["NotStored"], "Attachments" -> {}|>,
      "Policy" -> <|
         "CloudSendAllowed" -> False, "RequiresLocalDecrypt" -> True,
         "ReleaseRequiresPlan" -> True, "DefaultPlaintextBodyAllowed" -> False,
         "MaildbPrivacyIsAuthoritative" -> False|>,
      "Provenance" -> <|
         "ImportedBy" -> "MaildbAdapter",
         "OriginalMaildbPrivacy" -> mdPrivacy,
         "BodyTruncatedByMaildb" -> (StringQ[body] && StringLength[body] >= 50000)|>
    |>;
    snapshot];

SourceVaultMailSnapshotDecryptBody[snapshot_Association] :=
  Module[{rec},
    rec = Quiet@Check[snapshot["PayloadRefs", "Body"], Missing[]];
    If[! SourceVault`SourceVaultEncryptedRecordQ[rec],
      Return[<|"Status" -> "Error", "Reason" -> "NoEncryptedBody", "PlaintextReturned" -> False|>]];
    With[{d = SourceVault`SourceVaultDecryptRecord[rec]},
      If[Lookup[d, "Status", ""] === "Ok",
        <|"Status" -> "Ok", "Body" -> d["Plaintext"]["Body"], "PlaintextReturned" -> True|>,
        d]]];

(* ---- snapshot store + search + persistence ----
   永続化は mbox x 月でシャード分割: <root>/<mbox>/<yyyymm>.svmail
   新着メール追加はその月のシャード(小)だけ書き換え -> Dropbox は変更分のみ同期。
   単一ファイルだと 1 通追加で全体(数百MB)再同期になり破綻する。 *)
If[! AssociationQ[$iSVMDStore], $iSVMDStore = <||>];          (* RecordId -> snapshot *)
If[! AssociationQ[$iSVMDShardMembers], $iSVMDShardMembers = <||>]; (* "mbox/yyyymm" -> {RecordId..} *)
If[! AssociationQ[$iSVMDDirtyShards], $iSVMDDirtyShards = <||>];   (* "mbox/yyyymm" -> True *)

(* shard key = mbox + 年月 (mail Date の UTC ISO から)。Date 不明は "unknown"。 *)
iSVMDShardKey[snapshot_] :=
  Module[{mbox, d, ym},
    mbox = Quiet@Check[snapshot["MailSource", "MBox"], "unknown"];
    If[! StringQ[mbox], mbox = "unknown"];
    d = Quiet@Check[snapshot["MailMetadataPublic", "Date"], Missing[]];
    ym = If[StringQ[d] && StringLength[d] >= 7,
       StringTake[d, 4] <> StringTake[d, {6, 7}], "unknown"];
    mbox <> "/" <> ym];

Options[SourceVaultMailSnapshotPut] = {"Persist" -> True};
SourceVaultMailSnapshotPut[snapshot_Association, OptionsPattern[]] :=
  Module[{rid = Lookup[snapshot, "RecordId", Missing[]], sk},
    If[! StringQ[rid], Return[<|"Status" -> "Error", "Reason" -> "NoRecordId"|>]];
    sk = iSVMDShardKey[snapshot];
    AssociateTo[$iSVMDStore, rid -> snapshot];
    AssociateTo[$iSVMDShardMembers,
       sk -> DeleteDuplicates[Append[Lookup[$iSVMDShardMembers, sk, {}], rid]]];
    AssociateTo[$iSVMDDirtyShards, sk -> True];
    If[TrueQ[OptionValue["Persist"]], SourceVaultMailStoreSave[]];
    <|"Status" -> "Stored", "RecordId" -> rid, "Shard" -> sk|>];

SourceVaultMailSnapshotGet[recordId_String] := Lookup[$iSVMDStore, recordId, Missing["NotFound"]];
SourceVaultMailSnapshotList[] := Values[$iSVMDStore];

(* DateObject / 日付文字列 / {y,m,d} / Automatic を {年,月,日} 整数リストに正規化する。
   フィルタ境界 (ユーザ指定。ローカル意図) 用。失敗時は $Failed、Automatic はそのまま返す。 *)
iSVMDDayListOf[Automatic] := Automatic;
iSVMDDayListOf[x_] := Quiet@Check[DateValue[x, {"Year", "Month", "Day"}], $Failed];

(* メール保存日時 (UTC ISO8601 文字列) をローカル TZ ($TimeZone) の {年,月,日} に変換する。
   保存は UTC だが表示・ユーザのフィルタはローカルなので、早朝メールが UTC では前日扱いに
   なって取りこぼされるのを防ぐ。失敗時は素の DateValue にフォールバック。 *)
iSVMDMailDay[d_] :=
  Module[{do, r},
    do = Quiet@Check[DateObject[d], $Failed];
    r = If[Head[do] === DateObject,
      Quiet@Check[
        DateValue[TimeZoneConvert[do, $TimeZone], {"Year", "Month", "Day"}], $Failed],
      $Failed];
    If[MatchQ[r, {_Integer, _Integer, _Integer}], r, iSVMDDayListOf[d]]];

(* 日付フィルタ。fromDay/toDay は iSVMDDayListOf で正規化済みの {y,m,d} または Automatic。
   日単位の包含比較なので DateFrom=DateTo=DateObject[{2026,1,10}] でも当日のメールが一致する。
   旧実装は DateObject と ISO 文字列を OrderedQ で直接比較し、型不一致で常に空になっていた
   (さらに DateTo を日付のみ指定すると当日の時刻付きメールが除外される包含バグもあった)。 *)
iSVMDDateInRange[snap_, fromDay_, toDay_] :=
  Module[{d, dDay},
    If[fromDay === Automatic && toDay === Automatic, Return[True]];
    d = Quiet@Check[snap["MailMetadataPublic", "Date"], Missing[]];
    dDay = iSVMDMailDay[d];
    If[! MatchQ[dDay, {_Integer, _Integer, _Integer}], Return[False]];
    And[
      fromDay === Automatic || ! MatchQ[fromDay, {_Integer, _Integer, _Integer}] ||
        OrderedQ[{fromDay, dDay}],
      toDay === Automatic || ! MatchQ[toDay, {_Integer, _Integer, _Integer}] ||
        OrderedQ[{dDay, toDay}]]];

(* ---- 派生カテゴリ語彙 (schema キーは英語固定、日本語は表示・入力同義語) ---- *)
$SourceVaultMailCategories = {"InfoProvision", "AttendanceRequest", "TaskRequest",
   "Confirmation", "Report", "Notice", "Other"};

(* 入力 (LLM 出力や検索オプション) をトークンへ正規化する。日本語同義語も受ける。
   未知の値は Missing["UnknownCategory"]。 *)
$iSVMDCategorySynonyms = <|
   "情報提供" -> "InfoProvision", "情報" -> "InfoProvision", "案内" -> "InfoProvision",
   "出席依頼" -> "AttendanceRequest", "会議出席依頼" -> "AttendanceRequest",
   "出席" -> "AttendanceRequest", "日程調整" -> "AttendanceRequest",
   "作業依頼" -> "TaskRequest", "仕事依頼" -> "TaskRequest", "仕事の依頼" -> "TaskRequest",
   "作業の依頼" -> "TaskRequest", "依頼" -> "TaskRequest", "作業" -> "TaskRequest",
   "確認" -> "Confirmation", "承認" -> "Confirmation", "確認依頼" -> "Confirmation",
   "報告" -> "Report", "通知" -> "Notice", "一斉配信" -> "Notice", "広告" -> "Notice",
   "その他" -> "Other"|>;

iSVMDNormalizeCategory[s_String] :=
  Module[{t = StringTrim[s], hit},
    If[t === "", Return[Missing["UnknownCategory"]]];
    hit = SelectFirst[$SourceVaultMailCategories,
       StringMatchQ[t, #, IgnoreCase -> True] &, Missing[]];
    If[StringQ[hit], Return[hit]];
    Lookup[$iSVMDCategorySynonyms, t, Missing["UnknownCategory"]]];
iSVMDNormalizeCategory[_] := Missing["UnknownCategory"];

(* 〆切文字列の正規化: "2026-06-19" / "2026-06-19 17:00" / "2026年6月19日 17時" 等を
   ISO 風 "YYYY-MM-DD" または "YYYY-MM-DDTHH:MM:00" (ローカル時刻意図, TZ なし) に。
   なし/解釈不能は Missing。 *)
iSVMDNormalizeDeadline[s_String] :=
  Module[{t = StringTrim[s], m, y, mo, d, h, mi, pad},
    If[t === "" || StringMatchQ[t, "none" | "null" | "n/a" | "-", IgnoreCase -> True] ||
       StringContainsQ[t, "なし"] || StringContainsQ[t, "無し"],
      Return[Missing["None"]]];
    m = StringCases[t,
       RegularExpression["(\\d{4})[-/](\\d{1,2})[-/](\\d{1,2})(?:[T\\s]+(\\d{1,2}):(\\d{2}))?"] :>
         {"$1", "$2", "$3", "$4", "$5"}];
    If[m === {},
      m = StringCases[t,
         RegularExpression["(\\d{4})年\\s*(\\d{1,2})月\\s*(\\d{1,2})日(?:\\s*(\\d{1,2})[:時](\\d{1,2})?分?)?"] :>
           {"$1", "$2", "$3", "$4", "$5"}]];
    If[m === {}, Return[Missing["Unparsed"]]];
    {y, mo, d, h, mi} = First[m];
    {y, mo, d} = Quiet@Check[ToExpression /@ {y, mo, d}, {0, 0, 0}];
    If[! (IntegerQ[y] && 2000 <= y <= 2199 && IntegerQ[mo] && 1 <= mo <= 12 &&
          IntegerQ[d] && 1 <= d <= 31),
      Return[Missing["Unparsed"]]];
    pad = StringPadLeft[ToString[#], 2, "0"] &;
    If[h === "",
      StringJoin[ToString[y], "-", pad[mo], "-", pad[d]],
      Module[{hh = Quiet@Check[ToExpression[h], -1],
          mm = If[mi === "", 0, Quiet@Check[ToExpression[mi], -1]]},
        If[! (IntegerQ[hh] && 0 <= hh <= 23 && IntegerQ[mm] && 0 <= mm <= 59),
          StringJoin[ToString[y], "-", pad[mo], "-", pad[d]],
          StringJoin[ToString[y], "-", pad[mo], "-", pad[d], "T", pad[hh], ":", pad[mm], ":00"]]]]];
iSVMDNormalizeDeadline[_] := Missing["None"];

Options[SourceVaultSearchMailSnapshots] = {
  "FromContact" -> Automatic, "From" -> Automatic, "To" -> Automatic, "MBox" -> Automatic,
  "DateFrom" -> Automatic, "DateTo" -> Automatic, "HasAttachment" -> Automatic,
  "Category" -> Automatic, "HasDeadline" -> Automatic,
  "DeadlineFrom" -> Automatic, "DeadlineTo" -> Automatic,
  "MinPriority" -> Automatic, "MaxPriority" -> Automatic,
  "MinPrivacy" -> Automatic, "MaxPrivacy" -> Automatic,
  "SortBy" -> Automatic, "SortOrder" -> "Desc", "Newest" -> True, "Limit" -> Automatic};

iSVMDSnapDate[s_] := Lookup[s["MailMetadataPublic"], "Date", ""];
iSVMDNum[x_, default_] := If[NumericQ[x], x, default];
iSVMDPriority[s_] := iSVMDNum[Lookup[s["Derived"], "Priority", Missing[]], -Infinity];
iSVMDPrivacy[s_] := iSVMDNum[Lookup[s["Derived"], "PrivacyLevel", Missing[]], 0];
iSVMDCategoryOf[s_] := With[{c = Lookup[Lookup[s, "Derived", <||>], "Category", Missing[]]},
   If[StringQ[c], c, Missing["NoCategory"]]];
iSVMDDeadlineOf[s_] := With[{dl = Lookup[Lookup[s, "Derived", <||>], "Deadline", Missing[]]},
   If[StringQ[dl], dl, Missing["NoDeadline"]]];

(* 〆切の日付範囲 (日単位包含)。〆切はローカル時刻意図の素の ISO 文字列なので
   メール Date と違い TZ 変換しない。〆切なしは範囲指定時に不一致。 *)
iSVMDDeadlineInRange[s_, Automatic, Automatic] := True;
iSVMDDeadlineInRange[s_, fromDay_, toDay_] :=
  Module[{dl = iSVMDDeadlineOf[s], dDay},
    If[! StringQ[dl], Return[False]];
    dDay = iSVMDDayListOf[dl];
    If[! MatchQ[dDay, {_Integer, _Integer, _Integer}], Return[False]];
    And[
      fromDay === Automatic || ! MatchQ[fromDay, {_Integer, _Integer, _Integer}] ||
        OrderedQ[{fromDay, dDay}],
      toDay === Automatic || ! MatchQ[toDay, {_Integer, _Integer, _Integer}] ||
        OrderedQ[{dDay, toDay}]]];

iSVMDSortKey[by_][s_] := Switch[by,
  "Priority", iSVMDPriority[s], "PrivacyLevel" | "Privacy", iSVMDPrivacy[s],
  (* 〆切なしは昇順で末尾に来るよう番兵値 *)
  "Deadline", With[{dl = iSVMDDeadlineOf[s]}, If[StringQ[dl], dl, "9999-12-31T23:59:59"]],
  _, iSVMDSnapDate[s]];

SourceVaultSearchMailSnapshots[query_String : "", OptionsPattern[]] :=
  Module[{q, fc, fr, toQ, mb, df, dt, ha, cat, hd, ddf, ddt, hits, lim,
      minP, maxP, minPr, maxPr, by, ord},
    q = StringTrim[query]; fc = OptionValue["FromContact"]; fr = OptionValue["From"];
    toQ = OptionValue["To"]; mb = OptionValue["MBox"];
    df = iSVMDDayListOf[OptionValue["DateFrom"]]; dt = iSVMDDayListOf[OptionValue["DateTo"]];
    ha = OptionValue["HasAttachment"];
    (* Category は日本語名でも受け、保存トークンへ正規化してから比較 *)
    cat = With[{c = OptionValue["Category"]},
       If[c === Automatic || c === All, Automatic,
         With[{n = iSVMDNormalizeCategory[ToString[c]]}, If[StringQ[n], n, ToString[c]]]]];
    hd = OptionValue["HasDeadline"];
    ddf = iSVMDDayListOf[OptionValue["DeadlineFrom"]];
    ddt = iSVMDDayListOf[OptionValue["DeadlineTo"]];
    minP = OptionValue["MinPriority"]; maxP = OptionValue["MaxPriority"];
    minPr = OptionValue["MinPrivacy"]; maxPr = OptionValue["MaxPrivacy"];
    hits = Select[Values[$iSVMDStore], Function[s,
       And[
         q === "" ||
           AnyTrue[{Lookup[s["MailMetadataPublic"], "Subject", ""],
                    Lookup[s["Derived"], "Summary", ""]},
             StringQ[#] && StringContainsQ[#, q, IgnoreCase -> True] &],
         fr === Automatic || (StringQ[Lookup[s["MailMetadataPublic"], "From", ""]] &&
            StringContainsQ[s["MailMetadataPublic"]["From"], fr, IgnoreCase -> True]),
         (* 宛先フィルタ: To ヘッダ部分一致 (オーナー以外の特定個人宛の依頼を選べるように) *)
         toQ === Automatic || (StringQ[Lookup[s["MailMetadataPublic"], "To", ""]] &&
            StringContainsQ[s["MailMetadataPublic"]["To"], toQ, IgnoreCase -> True]),
         fc === Automatic || Lookup[s["AddressBookRefs"], "FromContact", Null] === fc,
         mb === Automatic || Lookup[s["MailSource"], "MBox", Null] === mb,
         ha === Automatic || TrueQ[Lookup[s["MailMetadataPublic"], "AttachmentCount", 0] > 0] === TrueQ[ha],
         cat === Automatic || iSVMDCategoryOf[s] === cat,
         hd === Automatic || StringQ[iSVMDDeadlineOf[s]] === TrueQ[hd],
         iSVMDDeadlineInRange[s, ddf, ddt],
         minP === Automatic || iSVMDPriority[s] >= minP, maxP === Automatic || iSVMDPriority[s] <= maxP,
         minPr === Automatic || iSVMDPrivacy[s] >= minPr, maxPr === Automatic || iSVMDPrivacy[s] <= maxPr,
         iSVMDDateInRange[s, df, dt]]]];
    by = OptionValue["SortBy"] /. Automatic -> If[TrueQ[OptionValue["Newest"]], "Date", None];
    If[by =!= None,
      ord = OptionValue["SortOrder"];
      hits = SortBy[hits, iSVMDSortKey[by]];
      If[ord === "Desc" || ord === Descending, hits = Reverse[hits]]];
    lim = OptionValue["Limit"];
    If[IntegerQ[lim] && lim >= 0, hits = Take[hits, UpTo[lim]]];
    hits];

(* 一覧行 (低漏洩)。From は AddressBook 解決時は表示名 *)
iSVMDFromDisplay[s_] :=
  Module[{fc, c, raw},
    fc = Lookup[s["AddressBookRefs"], "FromContact", Missing[]];
    If[StringQ[fc],
      c = Quiet@Check[SourceVault`SourceVaultAddressBookGetContact[fc], Missing[]];
      If[AssociationQ[c] && StringQ[Lookup[c, "DisplayName", Null]], Return[c["DisplayName"]]]];
    raw = Lookup[s["MailMetadataPublic"], "From", Missing[]];
    If[StringQ[raw], raw, Missing["Unknown"]]];

SourceVaultMailSummaryRow[s_Association] :=
  <|"Date" -> Lookup[s["MailMetadataPublic"], "Date", Missing[]],
    "From" -> iSVMDFromDisplay[s],
    "Subject" -> Lookup[s["MailMetadataPublic"], "Subject", Missing["Encrypted"]],
    "Category" -> iSVMDCategoryOf[s],
    "Deadline" -> iSVMDDeadlineOf[s],
    "Priority" -> Lookup[s["Derived"], "Priority", Missing["NotGenerated"]],
    "PrivacyLevel" -> Lookup[s["Derived"], "PrivacyLevel", Missing[]],
    "MaildbPrivacy" -> Lookup[s["Provenance"], "OriginalMaildbPrivacy", Missing[]],
    "Attach" -> Lookup[s["MailMetadataPublic"], "AttachmentCount", 0],
    "MBox" -> Lookup[s["MailSource"], "MBox", Missing[]],
    "RecordId" -> Lookup[s, "RecordId", Missing[]],
    "BodyEncrypted" ->
      SourceVault`SourceVaultEncryptedRecordQ[Lookup[s["PayloadRefs"], "Body", <||>]]|>;

(* View 結果が機密扱いか: PL >= 0.5 のメールを 1 通でも含めば機密
   (フェイルセーフ: PL 欠落は 1.0 扱い)。全件 PL < 0.5 なら平文扱い。 *)
iSVMDConfidentialQ[snaps_List] :=
  snaps =!= {} && TrueQ[Max[iSVMailProbePL /@ snaps] >= 0.5];

(* 表示時の即時機密マーク (ClaudeCode 不在時のフォールバック):
   View 評価の出力セルは評価中はまだ存在しないため、ワンショットの
   スケジュールタスク (kernel idle 後に実行) で評価完了直後に
   SourceVaultMarkConfidentialViewCells を走らせる (FE がある時のみ)。
   ClaudeEval 直前の NBMakeContextPacket フックは最終防衛線として残る。 *)
iSVMDScheduleConfidentialMark[snaps_List] :=
  Quiet@Check[
    If[TrueQ[$Notebooks] && iSVMDConfidentialQ[snaps],
      With[{nb = EvaluationNotebook[]},
        If[Head[nb] === NotebookObject,
          SessionSubmit[ScheduledTask[
            Quiet@Check[SourceVault`SourceVaultMarkConfidentialViewCells[nb], Null],
            {1.0}]]]]];
    Null,
    Null];

(* View 値の機密化 (ユーザー方針: View は機密値を返す関数として振る舞う)。
   PL >= 0.5 のメールを含む結果は ClaudeCode`Confidential を通して返す:
   入力セルの機密マーク + 出力セルの遅延マーク + 代入先変数 (mails 等) の
   秘密変数登録 + CellEpilog 装着までやってくれるので、mails[[1]][[1]] の
   ような派生値のセルも評価時に依存秘密として自動マークされる。
   ClaudeCode 未ロード時はセルマークのみのフォールバック。
   (将来的には値自体が Confidential プロパティを運ぶ多値化が筋だが当座はこれ) *)
iSVMDWrapConfidential[result_, snaps_List] :=
  Which[
    ! iSVMDConfidentialQ[snaps], result,
    Length[DownValues[ClaudeCode`Confidential]] > 0,
      ClaudeCode`Confidential[result],
    True, (iSVMDScheduleConfidentialMark[snaps]; result)];

Options[SourceVaultMailSearchSummary] = Options[SourceVaultSearchMailSnapshots];
SourceVaultMailSearchSummary[query_String : "", opts : OptionsPattern[]] :=
  With[{snaps = SourceVaultSearchMailSnapshots[query, opts]},
    iSVMDWrapConfidential[SourceVaultMailSummaryRow /@ snaps, snaps]];

Options[SourceVaultMailDataset] = Options[SourceVaultSearchMailSnapshots];
SourceVaultMailDataset[query_String : "", opts : OptionsPattern[]] :=
  Dataset[SourceVaultMailSearchSummary[query, opts]];

(* byte-exact 永続化: snapshot は暗号 body record を含むので、復号 round-trip 保証のため
   BinarySerialize+Base64 の 1 行/snapshot。シャード = <root>/<mbox>/<yyyymm>.svmail。 *)
SourceVaultMailStoreRoot[] :=
  If[StringQ[$SourceVaultMailStoreRoot], $SourceVaultMailStoreRoot,
     FileNameJoin[{Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $TemporaryDirectory],
        "mail", "snapshots"}]];

(* shard key "mbox/yyyymm" -> file path *)
SourceVaultMailShardPath[shardKey_String] :=
  FileNameJoin[{SourceVaultMailStoreRoot[],
     Sequence @@ (StringSplit[shardKey, "/"] /. {m_, y_} :> {m, y <> ".svmail"})}];

(* 旧単一ファイル (移行用に検出) *)
SourceVaultMailStorePath[] := FileNameJoin[{SourceVaultMailStoreRoot[], "snapshots.svmail"}];

iSVMDWriteShard[shardKey_String, rids_List] :=
  Module[{path = SourceVaultMailShardPath[shardKey], ipath = iSVMDIndexPath[shardKey],
      dir, lines, keep, res},
    dir = DirectoryName[path];
    If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    keep = Select[rids, KeyExistsQ[$iSVMDStore, #] &];
    If[keep === {},
      If[FileExistsQ[path], Quiet@DeleteFile[path]];
      If[FileExistsQ[ipath], Quiet@DeleteFile[ipath]];
      Return[0]];
    lines = (BaseEncode[BinarySerialize[$iSVMDStore[#]]] &) /@ keep;
    res = Quiet@Check[
      With[{strm = OpenWrite[path, BinaryFormat -> True]},
        Scan[BinaryWrite[strm, StringToByteArray[# <> "\n", "ASCII"]] &, lines];
        Close[strm]; Length[lines]],
      $Failed];
    (* 軽量メタデータ索引 sidecar も同時更新 (本文をロードせず検索するため) *)
    iSVMDWriteIndexFile[ipath, (iSVMDIndexRow[$iSVMDStore[#]] &) /@ keep];
    res];

Options[SourceVaultMailStoreSave] = {"All" -> False};
SourceVaultMailStoreSave[OptionsPattern[]] :=
  Module[{keys, written},
    keys = If[TrueQ[OptionValue["All"]], Keys[$iSVMDShardMembers], Keys[$iSVMDDirtyShards]];
    written = (iSVMDWriteShard[#, Lookup[$iSVMDShardMembers, #, {}]]) & /@ keys;
    $iSVMDDirtyShards = <||>;
    <|"Status" -> "Saved", "Shards" -> Length[keys], "Count" -> Total[Select[written, IntegerQ]]|>];

iSVMDReadShardFile[path_String] :=
  Module[{raw, lines, snaps},
    raw = Quiet@Check[ByteArrayToString[ReadByteArray[path], "ASCII"], ""];
    lines = Select[StringSplit[raw, "\n"], StringTrim[#] =!= "" &];
    snaps = Quiet@Check[BinaryDeserialize[BaseDecode[StringTrim[#]]], Nothing] & /@ lines;
    Select[snaps, AssociationQ]];

(* ============================================================
   軽量メタデータ索引 (sidecar/shard) ── 本文暗号文をロードせず検索する。
   各 shard <root>/<mbox>/<yyyymm>.svmail と並べて
   <root>/<mbox>/<yyyymm>.svmailidx を持つ。1 行 = BinarySerialize した索引行
   (SummaryRow 形 + Summary + FromRaw/ToRaw/FromContact/AttachmentCount/ShardKey)。
   PayloadRefs (本文・ヘッダ暗号文) は一切含めない ── 索引に入るのは既に shard 内で
   at-rest 平文のメタ/サマリーのみなので新たな露出区分は増えない。release gate は
   各行の PrivacyLevel により MCP 層 (B3) が従来どおり cloud 宛を gate する。
   shard 単位なので Dropbox 同期も新着のあった月の sidecar だけで済む。
   ============================================================ *)

iSVMDIndexExt = ".svmailidx";

iSVMDIndexPath[shardKey_String] :=
  FileNameJoin[{SourceVaultMailStoreRoot[],
     Sequence @@ (StringSplit[shardKey, "/"] /. {m_, y_} :> {m, y <> iSVMDIndexExt})}];

iSVMDIndexFiles[mbox_ : All] :=
  Module[{root = SourceVaultMailStoreRoot[], files},
    files = If[DirectoryQ[root], FileNames["*" <> iSVMDIndexExt, root, 2], {}];
    If[mbox === All, files, Select[files, FileNameTake[DirectoryName[#]] === mbox &]]];

(* 索引行: snapshot から低漏洩投影。本文/暗号文 (PayloadRefs) は含めない。 *)
iSVMDIndexRow[snap_Association] :=
  Module[{md = Lookup[snap, "MailMetadataPublic", <||>], dv = Lookup[snap, "Derived", <||>]},
    Join[SourceVaultMailSummaryRow[snap], <|
      "Summary" -> Lookup[dv, "Summary", Missing["NotGenerated"]],
      (* 認証済み (SourceVault 管理 Derived) AccessTags を索引へ surface し MCP scope gate に使う。
         本文を読まずに索引だけで scope filter できる。既定 {} (= untagged)。 *)
      "AccessTags" -> With[{at = Lookup[dv, "AccessTags", {}]}, If[ListQ[at], at, {}]],
      "FromRaw" -> Lookup[md, "From", Missing[]],
      "ToRaw" -> Lookup[md, "To", Missing[]],
      "FromContact" -> Lookup[Lookup[snap, "AddressBookRefs", <||>], "FromContact", Missing[]],
      "AttachmentCount" -> Lookup[md, "AttachmentCount", 0],
      "ShardKey" -> iSVMDShardKey[snap],
      "IndexSchemaVersion" -> 2|>]];

iSVMDWriteIndexFile[path_String, rows_List] :=
  Module[{dir = DirectoryName[path], lines},
    If[rows === {}, If[FileExistsQ[path], Quiet@DeleteFile[path]]; Return[0]];
    If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    lines = (BaseEncode[BinarySerialize[#]] &) /@ rows;
    Quiet@Check[
      With[{strm = OpenWrite[path, BinaryFormat -> True]},
        Scan[BinaryWrite[strm, StringToByteArray[# <> "\n", "ASCII"]] &, lines];
        Close[strm]; Length[lines]],
      $Failed]];

iSVMDReadIndexFile[path_String] :=
  Module[{raw, lines, rows},
    If[! FileExistsQ[path], Return[{}]];
    raw = Quiet@Check[ByteArrayToString[ReadByteArray[path], "ASCII"], ""];
    lines = Select[StringSplit[raw, "\n"], StringTrim[#] =!= "" &];
    rows = Quiet@Check[BinaryDeserialize[BaseDecode[StringTrim[#]]], Nothing] & /@ lines;
    Select[rows, AssociationQ]];

SourceVaultMailIndexedCount[mbox_ : All] :=
  Total[(Length[iSVMDReadIndexFile[#]]) & /@ iSVMDIndexFiles[mbox]];

(* RecordId 1 件を索引から引く (本体ロードなし)。索引ファイルを順次走査。 *)
SourceVaultMailIndexGet[recordId_String] :=
  Module[{files = iSVMDIndexFiles[], hit = Missing["NotFound"], i = 1, r},
    While[i <= Length[files] && MissingQ[hit],
      r = SelectFirst[iSVMDReadIndexFile[files[[i]]],
         Lookup[#, "RecordId", ""] === recordId &, Missing[]];
      If[AssociationQ[r], hit = r];
      i++];
    hit];

(* 索引再生成: 各 shard を一時的に読み込んで索引 sidecar を書く ($iSVMDStore は不変)。
   既存 .svmail からの初回構築・再構築に使う。 *)
SourceVaultMailRebuildMetadataIndex[mbox_ : All] :=
  Module[{shards, nShards = 0, total = 0},
    shards = SourceVaultMailAvailableShards[mbox];
    Scan[Function[pair,
      Module[{sk = pair[[1]] <> "/" <> pair[[2]], snaps, irows},
        snaps = iSVMDReadShardFile[SourceVaultMailShardPath[sk]];
        irows = iSVMDIndexRow /@ Select[snaps, AssociationQ];
        iSVMDWriteIndexFile[iSVMDIndexPath[sk], irows];
        nShards += 1; total += Length[irows]]],
      shards];
    <|"Status" -> "Rebuilt", "Shards" -> nShards, "Rows" -> total,
      "Root" -> SourceVaultMailStoreRoot[]|>];

(* ---- 索引行ベース (flat row) の述語/ソート: snapshot 述語の index 版 ---- *)
iSVMDIxPriority[row_] := iSVMDNum[Lookup[row, "Priority", Missing[]], -Infinity];
iSVMDIxPrivacy[row_] := iSVMDNum[Lookup[row, "PrivacyLevel", Missing[]], 0];
iSVMDIxDeadlineOf[row_] := With[{dl = Lookup[row, "Deadline", Missing[]]},
   If[StringQ[dl], dl, Missing["NoDeadline"]]];
iSVMDIxSnapDate[row_] := Lookup[row, "Date", ""];
iSVMDIxSortKey[by_][row_] := Switch[by,
  "Priority", iSVMDIxPriority[row], "PrivacyLevel" | "Privacy", iSVMDIxPrivacy[row],
  "Deadline", With[{dl = iSVMDIxDeadlineOf[row]}, If[StringQ[dl], dl, "9999-12-31T23:59:59"]],
  _, iSVMDIxSnapDate[row]];

iSVMDIxDateInRange[row_, fromDay_, toDay_] :=
  Module[{dDay},
    If[fromDay === Automatic && toDay === Automatic, Return[True]];
    dDay = iSVMDMailDay[Lookup[row, "Date", Missing[]]];
    If[! MatchQ[dDay, {_Integer, _Integer, _Integer}], Return[False]];
    And[
      fromDay === Automatic || ! MatchQ[fromDay, {_Integer, _Integer, _Integer}] || OrderedQ[{fromDay, dDay}],
      toDay === Automatic || ! MatchQ[toDay, {_Integer, _Integer, _Integer}] || OrderedQ[{dDay, toDay}]]];

iSVMDIxDeadlineInRange[row_, Automatic, Automatic] := True;
iSVMDIxDeadlineInRange[row_, fromDay_, toDay_] :=
  Module[{dl = iSVMDIxDeadlineOf[row], dDay},
    If[! StringQ[dl], Return[False]];
    dDay = iSVMDDayListOf[dl];
    If[! MatchQ[dDay, {_Integer, _Integer, _Integer}], Return[False]];
    And[
      fromDay === Automatic || ! MatchQ[fromDay, {_Integer, _Integer, _Integer}] || OrderedQ[{fromDay, dDay}],
      toDay === Automatic || ! MatchQ[toDay, {_Integer, _Integer, _Integer}] || OrderedQ[{dDay, toDay}]]];

Options[SourceVaultMailSearchIndex] = Options[SourceVaultSearchMailSnapshots];
SourceVaultMailSearchIndex[query_String : "", OptionsPattern[]] :=
  Module[{q, fr, toQ, fc, mb, df, dt, ha, cat, hd, ddf, ddt, minP, maxP, minPr, maxPr,
      by, ord, lim, rows, hits},
    q = StringTrim[query]; fr = OptionValue["From"]; toQ = OptionValue["To"];
    fc = OptionValue["FromContact"]; mb = OptionValue["MBox"];
    df = iSVMDDayListOf[OptionValue["DateFrom"]]; dt = iSVMDDayListOf[OptionValue["DateTo"]];
    ha = OptionValue["HasAttachment"];
    cat = With[{c = OptionValue["Category"]},
       If[c === Automatic || c === All, Automatic,
         With[{n = iSVMDNormalizeCategory[ToString[c]]}, If[StringQ[n], n, ToString[c]]]]];
    hd = OptionValue["HasDeadline"];
    ddf = iSVMDDayListOf[OptionValue["DeadlineFrom"]]; ddt = iSVMDDayListOf[OptionValue["DeadlineTo"]];
    minP = OptionValue["MinPriority"]; maxP = OptionValue["MaxPriority"];
    minPr = OptionValue["MinPrivacy"]; maxPr = OptionValue["MaxPrivacy"];
    rows = Join @@ (iSVMDReadIndexFile /@ iSVMDIndexFiles[If[StringQ[mb], mb, All]]);
    hits = Select[rows, Function[r,
       And[
         q === "" ||
           AnyTrue[{Lookup[r, "Subject", ""], Lookup[r, "Summary", ""]},
             StringQ[#] && StringContainsQ[#, q, IgnoreCase -> True] &],
         fr === Automatic || (StringQ[Lookup[r, "FromRaw", ""]] &&
            StringContainsQ[r["FromRaw"], fr, IgnoreCase -> True]),
         toQ === Automatic || (StringQ[Lookup[r, "ToRaw", ""]] &&
            StringContainsQ[r["ToRaw"], toQ, IgnoreCase -> True]),
         fc === Automatic || Lookup[r, "FromContact", Null] === fc,
         mb === Automatic || Lookup[r, "MBox", Null] === mb,
         ha === Automatic || TrueQ[Lookup[r, "AttachmentCount", 0] > 0] === TrueQ[ha],
         cat === Automatic || Lookup[r, "Category", Missing["NoCategory"]] === cat,
         hd === Automatic || StringQ[iSVMDIxDeadlineOf[r]] === TrueQ[hd],
         iSVMDIxDeadlineInRange[r, ddf, ddt],
         minP === Automatic || iSVMDIxPriority[r] >= minP, maxP === Automatic || iSVMDIxPriority[r] <= maxP,
         minPr === Automatic || iSVMDIxPrivacy[r] >= minPr, maxPr === Automatic || iSVMDIxPrivacy[r] <= maxPr,
         iSVMDIxDateInRange[r, df, dt]]]];
    by = OptionValue["SortBy"] /. Automatic -> If[TrueQ[OptionValue["Newest"]], "Date", None];
    If[by =!= None,
      ord = OptionValue["SortOrder"];
      hits = SortBy[hits, iSVMDIxSortKey[by]];
      If[ord === "Desc" || ord === Descending, hits = Reverse[hits]]];
    lim = OptionValue["Limit"];
    If[IntegerQ[lim] && lim >= 0, hits = Take[hits, UpTo[lim]]];
    hits];

iSVMDIndexSnapshot[snap_] :=
  Module[{rid = Lookup[snap, "RecordId", Missing[]], sk},
    If[! StringQ[rid], Return[]];
    sk = iSVMDShardKey[snap];
    AssociateTo[$iSVMDStore, rid -> snap];
    AssociateTo[$iSVMDShardMembers,
       sk -> DeleteDuplicates[Append[Lookup[$iSVMDShardMembers, sk, {}], rid]]]];

If[! AssociationQ[$iSVMDLoadedShards], $iSVMDLoadedShards = <||>];  (* "mbox/yyyymm" -> True *)

iSVMDPathToShardKey[path_String] :=
  FileNameTake[DirectoryName[path]] <> "/" <> StringDrop[FileNameTake[path], -StringLength[".svmail"]];

SourceVaultMailStoreLoad[] :=
  Module[{root, files, all},
    root = SourceVaultMailStoreRoot[];
    $iSVMDStore = <||>; $iSVMDShardMembers = <||>; $iSVMDDirtyShards = <||>; $iSVMDLoadedShards = <||>;
    files = If[DirectoryQ[root], FileNames["*.svmail", root, 2], {}];
    (* シャードは root/mbox/<yyyymm>.svmail。旧単一ファイル snapshots.svmail は除外 (移行対象)。 *)
    files = Select[files, FileNameTake[#] =!= "snapshots.svmail" &];
    all = Join @@ (iSVMDReadShardFile /@ files);
    Scan[iSVMDIndexSnapshot, all];
    Scan[AssociateTo[$iSVMDLoadedShards, iSVMDPathToShardKey[#] -> True] &, files];
    <|"Status" -> "Loaded", "Root" -> root, "Shards" -> Length[files],
      "Count" -> Length[$iSVMDStore]|>];

(* ---- インクリメンタル(遅延)ロード ---- *)
SourceVaultMailLoadedCount[] := Length[$iSVMDStore];

SourceVaultMailUnloadAll[] := (
  $iSVMDStore = <||>; $iSVMDShardMembers = <||>; $iSVMDDirtyShards = <||>; $iSVMDLoadedShards = <||>;
  <|"Status" -> "Unloaded"|>);

SourceVaultMailAvailableShards[mbox_ : All] :=
  Module[{root, files, parsed},
    root = SourceVaultMailStoreRoot[];
    files = If[DirectoryQ[root], FileNames["*.svmail", root, 2], {}];
    files = Select[files, FileNameTake[#] =!= "snapshots.svmail" &];
    parsed = {FileNameTake[DirectoryName[#]],
       StringDrop[FileNameTake[#], -StringLength[".svmail"]]} & /@ files;
    If[mbox === All, parsed, Select[parsed, First[#] === mbox &]]];

SourceVaultMailLoadShard[shardKey_String] :=
  Module[{path = SourceVaultMailShardPath[shardKey], snaps},
    If[! FileExistsQ[path], Return[0]];
    snaps = iSVMDReadShardFile[path];
    Scan[iSVMDIndexSnapshot, snaps];
    AssociateTo[$iSVMDLoadedShards, shardKey -> True];
    Length[snaps]];

iSVMDResolvePeriod[avail_List, period_] :=
  Module[{mbox, yms, sel},
    If[avail === {}, Return[{}]];
    mbox = avail[[1, 1]]; yms = Sort[DeleteDuplicates[avail[[All, 2]]]];
    sel = Which[
       period === All, yms,
       period === Automatic || period === "Latest", {Last[yms]},
       StringQ[period], Select[yms, # === period &],
       MatchQ[period, {_String, _String}],
         Select[yms, OrderedQ[{period[[1]], #}] && OrderedQ[{#, period[[2]]}] &],
       IntegerQ[period] && period > 0, Take[yms, -Min[period, Length[yms]]],
       True, {}];
    (mbox <> "/" <> #) & /@ sel];

SourceVaultMailEnsureLoaded[mbox_String, period_ : Automatic] :=
  Module[{avail, keys, newly},
    avail = SourceVaultMailAvailableShards[mbox];
    keys = iSVMDResolvePeriod[avail, period];
    newly = Total[(If[TrueQ[Lookup[$iSVMDLoadedShards, #, False]], 0,
         SourceVaultMailLoadShard[#]]) & /@ keys];
    <|"Status" -> "Ensured", "MBox" -> mbox, "Period" -> period,
      "Shards" -> Length[keys], "NewlyLoaded" -> newly, "InMemory" -> Length[$iSVMDStore]|>];

(* 旧単一ファイル -> 月次シャードへ移行。完了後は旧ファイルを .bak にリネーム。 *)
SourceVaultMailMigrateToShards[] :=
  Module[{old, snaps, sv},
    old = SourceVaultMailStorePath[];
    If[! FileExistsQ[old], Return[<|"Status" -> "NoLegacyFile", "Path" -> old|>]];
    $iSVMDStore = <||>; $iSVMDShardMembers = <||>; $iSVMDDirtyShards = <||>;
    snaps = iSVMDReadShardFile[old];
    Scan[iSVMDIndexSnapshot, snaps];
    sv = SourceVaultMailStoreSave["All" -> True];
    Quiet@RenameFile[old, old <> ".premigration.bak", OverwriteTarget -> True];
    <|"Status" -> "Migrated", "Snapshots" -> Length[$iSVMDStore],
      "Shards" -> sv["Shards"], "OldFile" -> old <> ".premigration.bak"|>];

Options[SourceVaultImportMaildbFile] = Join[Options[SourceVaultMailSnapshotFromMaildb], {"Persist" -> False}];

SourceVaultImportMaildbFile[file_String, mbox_String, opts : OptionsPattern[]] :=
  Module[{db, records, snaps, fromOpts},
    If[! FileExistsQ[file],
      Return[<|"Status" -> "Error", "Reason" -> "FileNotFound", "Path" -> file|>]];
    db = Quiet@Check[Block[{$CharacterEncoding = "UTF-8"}, Get[file]], $Failed];
    records = Which[
       Head[db] === Dataset, Normal[db],
       ListQ[db], db, AssociationQ[db], {db}, True, {}];
    records = Select[records, AssociationQ];
    fromOpts = FilterRules[{opts}, Options[SourceVaultMailSnapshotFromMaildb]];
    iSVMDIdentityEnsureLoaded[];  (* 識別子の既存を上書きしないよう先に load *)
    snaps = SourceVaultMailSnapshotFromMaildb[#, mbox, Sequence @@ fromOpts] & /@ records;
    (* 常に in-kernel store へ put (冪等)。Persist はディスク保存のみ制御。 *)
    (SourceVaultMailSnapshotPut[#, "Persist" -> False] &) /@ snaps;
    If[TrueQ[OptionValue["Persist"]], SourceVaultMailStoreSave[]; iSVMDIdentitySaveSafe[]];
    <|"Status" -> "Ok", "MBox" -> mbox, "Count" -> Length[snaps],
      "Stored" -> Length[$iSVMDStore],
      "Persisted" -> TrueQ[OptionValue["Persist"]], "Snapshots" -> snaps|>];

(* 既存 snapshot の平文 From/To/Cc から識別子を一括生成 (再取込不要)。 *)
Options[SourceVaultIdentityBackfillFromMail] = {"Persist" -> True};
SourceVaultIdentityBackfillFromMail[OptionsPattern[]] :=
  Module[{snaps, before, n = 0},
    iSVMDIdentityEnsureLoaded[];
    before = Quiet@Check[Length[SourceVault`SourceVaultListIdentifiers[]], 0];
    snaps = SourceVaultMailSnapshotList[];
    Do[
      Module[{md = Lookup[s, "MailMetadataPublic", <||>],
          mbox = Quiet@Check[s["MailSource"]["MBox"], Missing[]]},
        iSVMDIngestIds[ToString@Lookup[md, "From", ""], mbox];
        iSVMDIngestIds[ToString@Lookup[md, "To", ""], mbox];
        iSVMDIngestIds[ToString@Lookup[md, "Cc", ""], mbox];
        n++],
      {s, snaps}];
    If[TrueQ[OptionValue["Persist"]], iSVMDIdentitySaveSafe[]];
    <|"Status" -> "Ok", "SnapshotsScanned" -> n,
      "IdentifiersBefore" -> before,
      "IdentifiersAfter" -> Quiet@Check[Length[SourceVault`SourceVaultListIdentifiers[]], before],
      "Persisted" -> TrueQ[OptionValue["Persist"]]|>];

(* ============================================================
   SourceVaultSummaries 横断検索 provider (mail)
   ディスク索引 (.svmailidx) のみを走査し本文暗号文をロードせず共通スキーマ行を返す。
   eagle/sources と同じ共通スキーマ <|Kind,Id,URI,Title,Authors,Published,Summary,
   URL,File,Date,PrivacyLevel|> に揃え、JoinAcross / 総検索で混在検索できるようにする。
   類似項目は同名 (Title=件名, Summary=要約, Date, PrivacyLevel, URI)、メール固有値は
   別 API に残す。行ごとに PrivacyLevel を出すので SourceVaultSummaries の出力セルは
   iSVCatalogCellMaxPLFromText により最大 PL でマークされ、高 PL メールを含む結果は
   cloud へ出ない (fail-safe: PL 欠落 = 1.0)。
   ============================================================ *)

(* mail の正準 SourceVault URI (sv://record/svmail-<id>。mcp の iSVMailOwnsURIQ /
   iSVMailAdapterResolve が解決する形)。RecordId は既に "svmail-" 接頭辞付き。 *)
iSVMDMailURI[recordId_String] := "sv://record/" <> recordId;
iSVMDMailURI[_] := Missing["NoURI"];

iSVMDCommonRows[query_String, opts_Association] :=
  Module[{rows},
    rows = Quiet @ Check[SourceVaultMailSearchIndex[query], {}];
    If[! ListQ[rows], rows = {}];
    Map[
      Function[r,
        Module[{rid = ToString @ Lookup[r, "RecordId", ""],
            subj = Lookup[r, "Subject", Missing[]],
            summ = Lookup[r, "Summary", Missing[]],
            frm = Lookup[r, "From", Missing[]],
            date = Lookup[r, "Date", Missing[]],
            pl = Lookup[r, "PrivacyLevel", Missing[]]},
          <|"Kind" -> "mail",
            "Id" -> rid,
            "URI" -> iSVMDMailURI[rid],
            "Title" -> Which[
              StringQ[subj] && StringTrim[subj] =!= "", subj,
              MatchQ[subj, _Missing], "(\:4ef6\:540d\:7121\:3057\:30fb\:6697\:53f7\:5316)",
              True, "(\:4ef6\:540d\:7121\:3057)"],
            "Authors" -> If[StringQ[frm], frm, ""],
            "Published" -> "",
            "Summary" -> If[StringQ[summ], summ, ""],
            "URL" -> "",
            "File" -> "",
            "Date" -> If[StringQ[date], date, ToString[date]],
            (* fail-safe: PL 欠落は 1.0 (cloud 非送信側に倒す) *)
            "PrivacyLevel" -> If[NumericQ[pl], N[pl], 1.0]|>]],
      Select[rows, AssociationQ]]];
iSVMDCommonRows[query_String] := iSVMDCommonRows[query, <||>];

(* 横断検索 Grid の mail 行タイトルクリック: 低漏洩ヘッダ + URI をウインドウ表示
   (本文・暗号文は読まない)。全文/サマリーは mail 専用 API (機密ラップ付き) を使う。 *)
iSVMDShowMailInfo[recordId_String] :=
  Module[{r = SourceVaultMailIndexGet[recordId]},
    If[! AssociationQ[r],
      Return[<|"Status" -> "NotFound", "RecordId" -> recordId|>]];
    Quiet @ Check[
      CreateDocument[{
        Cell[ToString @ Lookup[r, "Subject", "(\:4ef6\:540d\:7121\:3057)"], "Subsection"],
        Cell["From: " <> ToString @ Lookup[r, "From", ""], "Text"],
        Cell["Date: " <> ToString @ Lookup[r, "Date", ""] <>
          "    PL: " <> ToString @ Lookup[r, "PrivacyLevel", ""], "Text"],
        Cell["URI: " <> iSVMDMailURI[recordId], "Text"],
        Cell["\:5168\:6587\:30fb\:30b5\:30de\:30ea\:30fc\:306f mail \:5c02\:7528 API (SourceVaultMailSearchSummary \:7b49\:3001\:6a5f\:5bc6\:30e9\:30c3\:30d7\:4ed8) \:3092\:4f7f\:3046\:3002", "Text"]},
        WindowTitle -> "Mail: " <> recordId],
      Null];
    <|"Status" -> "Opened", "RecordId" -> recordId|>];

(* provider / 行アクション登録 (eagle と同じ枠組み・Association ガード付き。
   SourceVault.wl 未ロードの maildb 単体ロードでも落ちない)。 *)
If[! AssociationQ[$SourceVaultSummaryProviders], $SourceVaultSummaryProviders = <||>];
$SourceVaultSummaryProviders["mail"] = iSVMDCommonRows;
If[! AssociationQ[$iSVRowTitleActions], $iSVRowTitleActions = <||>];
$iSVRowTitleActions["mail"] = iSVMDShowMailInfo;

End[];
EndPackage[];


(* ::Package:: *)

(* ============================================================
   SourceVault_imap.wl -- IMAP 新着取得 + 派生 (PL/優先度/概要) の後処理
   This file is encoded in UTF-8.

   設計の柱 (ユーザー要望):
   - 取り込み (IMAP) と 派生処理 (ローカル LLM) を完全分離。
     既定では取り込み時に LLM を回さず高速に保存し、派生は後から増分バッチ。
   - 中断耐性: バッチは CheckpointEvery 件ごとに dirty シャードを保存。
     強制終了しても "Processed" 済みは pending に戻らず再処理されない。
   - 外部依存 (IMAP / LLM) は注入可能 ("MessageSource" / "Inferencer")。
     既定は実 Python imaplib / 実 LM Studio。テストは fake を注入して headless 検証。
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultMailFetchNew::usage =
  "SourceVaultMailFetchNew[mbox, opts] は IMAP から新着のみ取得し snapshot 化して store に保存する。既定は LLM 処理なし。opts: \"Period\"(\"Latest\"|n日|{from,to}|\"YYYYMM\"), \"Process\"(既定False), \"MessageSource\"(既定=実IMAP, 注入可), \"Inferencer\", \"Persist\"(既定True), \"MaxEmails\"。RecordId で既存と重複排除。";
SourceVaultMailDerivedPending::usage =
  "SourceVaultMailDerivedPending[] はロード済み store の中で派生 (PL/優先度/概要) 未処理の snapshot を返す。";
SourceVaultMailDerivedPendingQ::usage =
  "SourceVaultMailDerivedPendingQ[snapshot] は派生が未処理 (\"Pending\") なら True。";
SourceVaultInferMailDerivedBatch::usage =
  "SourceVaultInferMailDerivedBatch[opts] は未処理 snapshot の派生をローカル LLM で増分生成し in-place 更新する。中断耐性 (CheckpointEvery 件ごとに保存)。opts: \"Limit\"(既定50、フィルタ後の件数上限。範囲内すべてなら Infinity), \"DateFrom\"/\"DateTo\"(既定 Automatic。DateObject/文字列/{y,m,d} で対象メールを日付範囲に限定、日単位包含), \"Refresh\"(既定 None=Pending のみ。\"MissingCategory\"=Category 未生成の処理済み旧 snapshot も再処理, All=全件再処理, Function=述語に一致する snapshot を再処理。例: \"Refresh\"->Function[s, StringContainsQ[ToString@s[\"MailMetadataPublic\"][\"Subject\"], \"Cerezo\"]]), \"Inferencer\"(既定=実LLM, 注入可), \"CheckpointEvery\"(既定20), \"Persist\"(既定True)。";
SourceVaultMailInferDerived::usage =
  "SourceVaultMailInferDerived[mailspec] は mailspec(date/subject/from/to/cc/body)からローカル LLM で <|WorkRequest, PrivacyLevel, Category, Deadline, Summary, Status|> を返す(優先度は構造的に別計算)。Category は $SourceVaultMailCategories のトークン、Deadline は ISO 文字列または Missing[\"None\"]。";
SourceVaultMailAddSummaries::usage =
  "SourceVaultMailAddSummaries[mbox_String, period_:\"Latest\", opts] は mbox の指定期間のメールを SourceVaultMailEnsureLoaded でロードしてから、その mbox の未処理 snapshot の派生(概要/カテゴリ/優先度/〆切)を SourceVaultInferMailDerivedBatch で一括生成・保存する。「<mbox>の新着メールにサマリーを追加」の正準エントリポイント(EnsureLoaded とバッチを1関数に内包するので、外部 WolframScript ジョブへ退避されてもロードから自己完結し、空ストアで0件処理になる失敗を防ぐ)。opts: \"Limit\"(既定 Infinity=新着全件), \"Persist\"(既定 True)。返り値 <|Status, MBox, Period, Loaded, Batch|>。";
SourceVaultRegisterMailspecEnricher::usage =
  "SourceVaultRegisterMailspecEnricher[name, f] は派生(サマリー作成)時に LLM へ渡す mailspec を拡張する enricher を登録する(Cerezo.wl 等の拡張用)。f[mailspec, snapshot] が変更後の mailspec(Association)を返すとそれが LLM 入力に使われ、Derived.DerivedEnrichment に名前が記録される。非該当/失敗時は mailspec をそのまま返す。取り込み・保存レコード形式には影響せず、未登録なら完全素通し。";
SourceVaultUnregisterMailspecEnricher::usage =
  "SourceVaultUnregisterMailspecEnricher[name] は mailspec enricher の登録を解除する。";
SourceVaultMailspecEnrichers::usage =
  "SourceVaultMailspecEnrichers[] は登録済み mailspec enricher 名のリストを返す。";
SourceVaultRegisterPostFetchHook::usage =
  "SourceVaultRegisterPostFetchHook[name, f] は SourceVaultMailFetchNew の取り込み完了時に呼ぶフック f[mbox, fetchResult] を登録する。" <>
  "取り込み後の派生(mining の著者抽出など)を maildb に依存させずに結線する拡張点。フックの失敗は fetch を壊さない。未登録なら完全素通し。";
SourceVaultUnregisterPostFetchHook::usage =
  "SourceVaultUnregisterPostFetchHook[name] は post-fetch フックの登録を解除する。";
SourceVaultPostFetchHooks::usage =
  "SourceVaultPostFetchHooks[] は登録済み post-fetch フック名のリストを返す。";
SourceVaultMailComputePriority::usage =
  "SourceVaultMailComputePriority[snapshot, workRequest, category] は構造シグナル(送信者グループ重み + To/Cc 位置 + ML判定 + LLM 依頼度 + LLM カテゴリ)から重要度 0.0-1.0 を決定的に計算する。category が \"Notice\"(通知・一斉配信・広告)なら -0.30 減点。<|Priority, Components|> を返す。";
SourceVaultMailExplainPriority::usage =
  "SourceVaultMailExplainPriority[snapshot] は snapshot の保存済み WorkRequest/Category を使って重要度の内訳(Components)を返す。";
SourceVaultMailRecomputePriorities::usage =
  "SourceVaultMailRecomputePriorities[opts] はロード済み snapshot のうち構造計算済み (PriorityComponents あり) のものについて、保存済み WorkRequest/Category から Priority を LLM なしで再計算し in-place 更新する。優先度式の変更を既処理メールへ反映するために使う (legacy maildb 由来の Priority は触らない)。opts: \"Persist\"(既定True)。";
SourceVaultSetPriorityGroupWeight::usage =
  "SourceVaultSetPriorityGroupWeight[group, weight] はグループの重み(0.0-1.0)を登録し vault config に保存する。実体の Group がこれに解決される。";
SourceVaultPriorityGroupWeights::usage = "SourceVaultPriorityGroupWeights[] は登録済みグループ重みを返す。";
SourceVaultGroupWeightFor::usage = "SourceVaultGroupWeightFor[group] はグループの重みを返す。無ければ Missing。";
SourceVaultPriorityGroupsLoad::usage = "SourceVaultPriorityGroupsLoad[] はグループ重み config を読み込む。";
SourceVaultRegisterMailAccount::usage =
  "SourceVaultRegisterMailAccount[<|\"MBox\",\"User\",\"Email\",\"CredKey\",\"Server\",\"Port\"|>, opts] は IMAP アカウント設定を登録し vault config に保存する。パスワードは保存せず CredKey(SystemCredential 名)のみ。同一 MBox は上書き。NBRegisterTrustedLocalServer と同様、私的データはソースに置かずここで登録する。";
SourceVaultMailAccounts::usage = "SourceVaultMailAccounts[] は登録済み IMAP アカウント設定を Dataset で返す(パスワードは含まない)。";
SourceVaultGetMailAccount::usage = "SourceVaultGetMailAccount[mbox] は登録済みアカウント設定を返す。無ければ Missing。";
SourceVaultRemoveMailAccount::usage = "SourceVaultRemoveMailAccount[mbox] は登録を削除する。";
SourceVaultMailAccountsLoad::usage = "SourceVaultMailAccountsLoad[] は vault config からアカウント設定を読み込む。";
$SourceVaultMailConfigRoot::usage = "IMAP アカウント設定の保存ルート(既定 PrivateVault/config)。テストで上書き可。";

Begin["`Private`"];

(* アカウント設定は空で初期化し、SourceVaultRegisterMailAccount で登録 -> vault config
   へ永続化する。私的ログインはソースコードにハードコードしない。 *)
If[! AssociationQ[$iSVMDMailAccounts], $iSVMDMailAccounts = <||>];
If[! ValueQ[$iSVMDMailAccountsLoaded], $iSVMDMailAccountsLoaded = False];

iSVMDMailConfigRoot[] :=
  If[StringQ[$SourceVaultMailConfigRoot], $SourceVaultMailConfigRoot,
     FileNameJoin[{Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $TemporaryDirectory],
        "config"}]];
iSVMDMailAccountsPath[] := FileNameJoin[{iSVMDMailConfigRoot[], "mailaccounts.jsonl"}];

SourceVaultMailAccountsLoad[] :=
  Module[{path = iSVMDMailAccountsPath[], txt, recs},
    txt = If[FileExistsQ[path],
       Quiet@Check[Import[path, "Text", CharacterEncoding -> "ISO8859-1"], ""], ""];
    recs = If[! StringQ[txt] || StringTrim[txt] === "", {},
       DeleteCases[(Quiet@Check[ImportString[#, "RawJSON"], $Failed] &) /@
          Select[StringSplit[txt, "\n"], StringTrim[#] =!= "" &], $Failed]];
    recs = Select[(If[AssociationQ[#], #, Quiet@Check[Association[#], $Failed]] &) /@ recs, AssociationQ];
    $iSVMDMailAccounts = Association[(ToString@Lookup[#, "MBox", CreateUUID[]] -> #) & /@ recs];
    $iSVMDMailAccountsLoaded = True;
    <|"Status" -> "Loaded", "Count" -> Length[$iSVMDMailAccounts]|>];

iSVMDMailAccountsSave[] :=
  Module[{path = iSVMDMailAccountsPath[], dir, lines},
    dir = DirectoryName[path];
    If[! DirectoryQ[dir], CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    lines = (ExportString[# /. (_Missing | $Failed) -> Null, "RawJSON", "Compact" -> True] &) /@
       Values[$iSVMDMailAccounts];
    Export[path, StringRiffle[lines, "\n"] <> If[lines === {}, "", "\n"], "Text",
      CharacterEncoding -> "ISO8859-1"];
    <|"Status" -> "Saved", "Count" -> Length[$iSVMDMailAccounts]|>];

iSVMDMailAccountsEnsureLoaded[] :=
  If[! TrueQ[$iSVMDMailAccountsLoaded], SourceVaultMailAccountsLoad[]];

Options[SourceVaultRegisterMailAccount] = {"Persist" -> True};
SourceVaultRegisterMailAccount[assoc_Association, OptionsPattern[]] :=
  Module[{mbox, entry},
    iSVMDMailAccountsEnsureLoaded[];
    mbox = ToString@Lookup[assoc, "MBox", Lookup[assoc, "mbox", ""]];
    If[mbox === "", Return[<|"Status" -> "Error", "Reason" -> "MissingMBox"|>]];
    entry = <|"MBox" -> mbox,
       "User" -> ToString@Lookup[assoc, "User", Lookup[assoc, "user", ""]],
       "Email" -> ToString@Lookup[assoc, "Email", Lookup[assoc, "email", ""]],
       "CredKey" -> ToString@Lookup[assoc, "CredKey", Lookup[assoc, "credKey", ""]],
       "Server" -> ToString@Lookup[assoc, "Server", Lookup[assoc, "server", ""]],
       "Port" -> Lookup[assoc, "Port", Lookup[assoc, "port", 993]]|>;
    If[entry["CredKey"] === "" || entry["Server"] === "",
      Return[<|"Status" -> "Error", "Reason" -> "MissingCredKeyOrServer"|>]];
    AssociateTo[$iSVMDMailAccounts, mbox -> entry];
    If[TrueQ[OptionValue["Persist"]], iSVMDMailAccountsSave[]];
    <|"Status" -> "Registered", "MBox" -> mbox|>];
SourceVaultRegisterMailAccount[___] := <|"Status" -> "Error", "Reason" -> "InvalidArguments"|>;

iSVMDGetMailAccount[mbox_] :=
  (iSVMDMailAccountsEnsureLoaded[]; Lookup[$iSVMDMailAccounts, mbox, Missing["NotRegistered"]]);
SourceVaultGetMailAccount[mbox_String] := iSVMDGetMailAccount[mbox];

SourceVaultMailAccounts[] :=
  (iSVMDMailAccountsEnsureLoaded[];
   If[$iSVMDMailAccounts === <||>, Dataset[{}], Dataset[Values[$iSVMDMailAccounts]]]);

Options[SourceVaultRemoveMailAccount] = {"Persist" -> True};
SourceVaultRemoveMailAccount[mbox_String, OptionsPattern[]] :=
  (iSVMDMailAccountsEnsureLoaded[];
   $iSVMDMailAccounts = KeyDrop[$iSVMDMailAccounts, mbox];
   If[TrueQ[OptionValue["Persist"]], iSVMDMailAccountsSave[]];
   <|"Status" -> "Removed", "MBox" -> mbox|>);

(* ---- 派生 pending 判定 ---- *)
SourceVaultMailDerivedPendingQ[snap_Association] :=
  Module[{d = Lookup[snap, "Derived", <||>], st, sm},
    st = Lookup[d, "DerivedStatus", Missing[]];
    sm = Lookup[d, "Summary", Missing[]];
    Which[
      st === "Pending", True,
      st === "Processed", False,
      (* DerivedStatus 無しの旧 snapshot: summary が空なら pending *)
      True, ! (StringQ[sm] && StringTrim[sm] =!= "")]];

SourceVaultMailDerivedPending[] :=
  Select[SourceVaultMailSnapshotList[], SourceVaultMailDerivedPendingQ];

(* ---- ローカル LLM (LM Studio, OpenAI 互換) ----
   maildb の iQueryLMStudioDirect を踏襲: Headers に Content-Type + Authorization、
   Body は UTF-8 ByteArray (Export RawJSON をファイル経由でバイト化)、
   応答もファイル経由 Import で encoding-safe に。 *)
(* ローカル LLM 専用 credential を AccessLevel 1.0 で取得する。
   url は scheme://host:port に正規化されてマッピング照合される (path は無視)。
   キー未登録/未保存なら認証オフ運用向けに "lm-studio" へフォールバック。 *)
iSVLMStudioAPIKey[url_String] :=
  Module[{k},
    k = Quiet@Check[
       NBAccess`NBGetLocalLLMAPIKey["lmstudio", url,
         PrivacySpec -> <|"AccessLevel" -> 1.0|>], $Failed];
    If[StringQ[k] && k =!= "", k, "lm-studio"]];
iSVLMStudioAPIKey[] := iSVLMStudioAPIKey["http://127.0.0.1:1234"];

iSVTmpJSON[tag_] := FileNameJoin[{$TemporaryDirectory,
   "sv_lm_" <> tag <> "_" <> IntegerString[$ProcessID] <> "_" <>
   IntegerString[RandomInteger[{0, 999999999}]] <> ".json"}];

iSVQueryLMStudio[prompt_String, url_String, model_String] :=
  Module[{reqData, reqFile, bodyBytes, resp, bytes, respFile, strm, json, content},
    (* このタスクは分類抽出なので推論 (thinking) は不要。Qwen3 系の
       reasoning モデルは思考を reasoning_content に延々と出力し、長文メールで
       TimeConstraint 内に最終 content を出せず空応答→FailedLLM になる。
       enable_thinking:False で思考を抑止し、直接 3 行を出力させる。 *)
    reqData = <|"messages" -> {<|"role" -> "user", "content" -> prompt|>},
       "stream" -> False, "temperature" -> 0.2,
       "chat_template_kwargs" -> <|"enable_thinking" -> False|>|> ~Join~
       If[model =!= "", <|"model" -> model|>, <||>];
    reqFile = iSVTmpJSON["req"];
    Quiet@Check[Export[reqFile, reqData, "RawJSON"], Return[""]];
    bodyBytes = Quiet@Check[ByteArray[BinaryReadList[reqFile]], $Failed];
    Quiet@DeleteFile[reqFile];
    If[Head[bodyBytes] =!= ByteArray, Return[""]];
    resp = Quiet@Check[URLRead[HTTPRequest[url, <|
        "Method" -> "POST",
        "Headers" -> {"Content-Type" -> "application/json; charset=utf-8",
           "Authorization" -> "Bearer " <> iSVLMStudioAPIKey[url]},
        "Body" -> bodyBytes|>], TimeConstraint -> 600], $Failed];
    If[! MatchQ[resp, _HTTPResponse] || resp["StatusCode"] =!= 200, Return[""]];
    bytes = Quiet@Check[resp["BodyByteArray"], $Failed];
    If[Head[bytes] =!= ByteArray, Return[""]];
    respFile = iSVTmpJSON["resp"];
    Quiet[strm = OpenWrite[respFile, BinaryFormat -> True];
      BinaryWrite[strm, Normal[bytes]]; Close[strm]];
    json = Quiet@Check[Import[respFile, "RawJSON"], $Failed];
    Quiet@DeleteFile[respFile];
    If[! AssociationQ[json], Return[""]];
    content = Quiet@Check[json["choices"][[1]]["message"]["content"], ""];
    (* thinking モデルが content を空にして reasoning_content に出した場合の保険 *)
    If[! (StringQ[content] && StringTrim[content] =!= ""),
      content = Quiet@Check[
        json["choices"][[1]]["message"]["reasoning_content"], ""]];
    If[StringQ[content], content, ""]];

iSVResolveLocalLLM[] :=
  Module[{model = "", url = "http://127.0.0.1:1234/v1/chat/completions", pm, models},
    pm = Quiet@Check[ClaudeCode`$ClaudePrivateModel, $Failed];
    If[ListQ[pm] && Length[pm] >= 2 && StringQ[pm[[2]]], model = pm[[2]]];
    If[ListQ[pm] && Length[pm] >= 3 && StringQ[pm[[3]]],
      url = With[{u = pm[[3]]},
        Which[StringEndsQ[u, "/v1/chat/completions"], u,
          StringEndsQ[u, "/"], u <> "v1/chat/completions",
          True, u <> "/v1/chat/completions"]]];
    If[model === "",
      Module[{base = StringReplace[url, "/v1/chat/completions" -> "/v1/models"], r, j},
        r = Quiet@Check[URLRead[HTTPRequest[base], TimeConstraint -> 10], $Failed];
        If[MatchQ[r, _HTTPResponse] && r["StatusCode"] === 200,
          j = Quiet@Check[ImportByteArray[r["BodyByteArray"], "RawJSON"], $Failed];
          If[AssociationQ[j] && ListQ[j["data"]] && Length[j["data"]] > 0,
            model = j["data"][[1]]["id"]; If[! StringQ[model], model = ""]]]]];
    <|"URL" -> url, "Model" -> model|>];

(* 所有者情報は SourceVault 識別子層 #1 から取得 (identity 未ロードでも安全) *)
iSVMDOwnerEmails[] := Quiet@Check[
   If[Length[DownValues[SourceVault`SourceVaultOwnerEmails]] > 0,
     SourceVault`SourceVaultOwnerEmails[], {}], {}];
iSVMDOwnerPrimaryEmail[] := Quiet@Check[
   If[Length[DownValues[SourceVault`SourceVaultOwnerPrimaryEmail]] > 0,
     SourceVault`SourceVaultOwnerPrimaryEmail[], Missing[]], Missing[]];
iSVMDOwnerLLMProfile[] := Quiet@Check[
   If[Length[DownValues[SourceVault`SourceVaultOwnerLLMProfile]] > 0,
     SourceVault`SourceVaultOwnerLLMProfile[], ""], ""];

iSVDerivePrompt[mailspec_Association] :=
  Module[{fld, pmail, prof, owners, ownerRef, recvLine},
    fld = StringJoin[KeyValueMap[
       #1 <> ": " <> Which[StringQ[#2], #2, ListQ[#2], StringRiffle[Select[#2, StringQ], ", "],
          True, ToString[#2]] <> "\n" &,
       KeyTake[mailspec, {"date", "subject", "from", "to", "cc", "body"}]]];
    pmail = iSVMDOwnerPrimaryEmail[];
    prof = iSVMDOwnerLLMProfile[];
    owners = iSVMDOwnerEmails[];
    ownerRef = If[StringQ[pmail] && pmail =!= "", pmail, "オーナー"];
    recvLine = "受信者(オーナー)は " <> ownerRef <>
       If[ListQ[owners] && owners =!= {},
         "(オーナーのアドレス: " <> StringRiffle[owners, ", "] <> ")", ""] <>
       If[StringQ[prof] && prof =!= "", "。プロフィール: " <> prof, ""] <> "。\n" <>
       "to/cc がオーナー個人のアドレスでなくても、オーナーの所属するグループ・部署・メーリングリスト宛であれば、その依頼はオーナーへの依頼として扱う。\n\n";
    "以下の[メール]について、WORKREQUEST、PRIVACY、CATEGORY、DEADLINE、SUMMARY の5つを推定せよ。\n" <>
    "各行のフォーマットに従い、余計な説明は一切不要。\n\n" <>
    recvLine <>
    "== WORKREQUEST ==\n依頼度を 0.0〜1.0 の数値で1つ出力。これは「このメールがオーナー個人への直接の依頼・要請・タスク(返信や対応が必要)である度合い」(優先度はシステムが別途計算するので、内容としての依頼度のみを評価せよ)。\n" <>
    "1.0=明確にオーナー個人宛の直接依頼/要請(講演依頼、査読依頼、会議日程調整、投稿依頼、質問など)、0.7=対応・返信が望ましい連絡、0.4=確認/承認を求める連絡、0.2=情報共有・報告で対応不要、0.0=一斉配信/広告/通知/SPAM。\n\n" <>
    "== PRIVACY ==\n秘匿度を 0.0〜1.0 の数値で1つ出力。これはクラウドLLMで処理してよいかの指標。" <>
    "0.5以下ならクラウド可。1.0=人事/成績/個人情報、0.8=組織内部の内部連絡、0.5=組織内可視で問題なし、" <>
    "0.4=外部の知人が見ても問題ない、0.0=どこに開示しても問題ない既知の内容。\n\n" <>
    "== CATEGORY ==\nfrom から to への伝達の種類を、次のトークンから1つだけ出力。\n" <>
    "TaskRequest=作業・仕事の依頼(査読、原稿・書類の提出、調査・対応の依頼など)、" <>
    "AttendanceRequest=会議・行事等への出席依頼/日程調整、" <>
    "Confirmation=確認・承認を求める連絡、" <>
    "InfoProvision=情報提供・案内、Report=結果・状況の報告、" <>
    "Notice=機械的な通知・一斉配信・広告、Other=その他。\n" <>
    "宛先がオーナーの所属グループ(部署ML等)であっても、内容が依頼なら TaskRequest または AttendanceRequest と判定する。\n\n" <>
    "== DEADLINE ==\n〆切・期限(提出期限、回答期限、申込期限、出欠回答期限など)が本文にあれば、" <>
    "メールの date を基準に「来週月曜」等の相対表現も絶対日時へ変換して、YYYY-MM-DD または YYYY-MM-DD HH:MM の形式で出力。" <>
    "〆切が無ければ NONE とだけ出力。会議開催日時そのものは〆切ではないが、出欠回答期限は〆切である。\n\n" <>
    "== SUMMARY ==\n要約を1行で出力。形式「〔カテゴリ〕内容の要約〔関係者〕」。" <>
    "カテゴリは 依頼/確認/報告/情報/雑務/〆切 から最適なものを選ぶ。\n\n" <>
    "== 出力形式 ==\n以下の5行のみを出力。他のテキストは一切不要。\n" <>
    "WORKREQUEST: <数値>\nPRIVACY: <数値>\nCATEGORY: <トークン>\nDEADLINE: <YYYY-MM-DD[ HH:MM] または NONE>\nSUMMARY: <要約文>\n\n[メール]\n" <> fld];

iSVParseDerived[raw_String] :=
  Module[{wr = Missing["NotParsed"], pv = Missing["NotParsed"],
      ct = Missing["NotParsed"], dl = Missing["NotParsed"], sm = "", m},
    m = StringCases[raw, ("WORKREQUEST:" | "PRIORITY:") ~~ Whitespace ~~ v : NumberString :> v];
    If[m =!= {} && StringLength[First[m]] <= 4, wr = Clip[ToExpression[First[m]], {0.0, 1.0}]];
    m = StringCases[raw, "PRIVACY:" ~~ Whitespace ~~ v : NumberString :> v];
    If[m =!= {} && StringLength[First[m]] <= 4, pv = Clip[ToExpression[First[m]], {0.0, 1.0}]];
    m = StringCases[raw, "CATEGORY:" ~~ Whitespace ~~ s__ /; ! StringContainsQ[s, "\n"] :> StringTrim[s]];
    If[m =!= {}, ct = iSVMDNormalizeCategory[First[m]]];
    m = StringCases[raw, "DEADLINE:" ~~ Whitespace ~~ s__ /; ! StringContainsQ[s, "\n"] :> StringTrim[s]];
    If[m =!= {}, dl = iSVMDNormalizeDeadline[First[m]]];
    m = StringCases[raw, "SUMMARY:" ~~ Whitespace ~~ s__ /; ! StringContainsQ[s, "\n"] :> StringTrim[s]];
    If[m =!= {}, sm = First[m]];
    <|"WorkRequest" -> wr, "PrivacyLevel" -> pv, "Category" -> ct, "Deadline" -> dl,
      "Summary" -> sm|>];

SourceVaultMailInferDerived[mailspec_Association] :=
  Module[{llm, raw, parsed},
    llm = iSVResolveLocalLLM[];
    raw = iSVQueryLMStudio[iSVDerivePrompt[mailspec], llm["URL"], llm["Model"]];
    If[! StringQ[raw] || raw === "",
      Return[<|"Status" -> "Error", "Reason" -> "LLMUnavailable",
        "WorkRequest" -> Missing["NotGenerated"], "PrivacyLevel" -> Missing["NotGenerated"],
        "Category" -> Missing["NotGenerated"], "Deadline" -> Missing["NotGenerated"],
        "Summary" -> Missing["NotGenerated"]|>]];
    parsed = iSVParseDerived[raw];
    Append[parsed, "Status" -> "Ok"]];

(* ---- 重要度の構造的計算: グループ重み config + To/Cc 位置 + ML 判定 + LLM 依頼度 ---- *)
(* グループ重み config (永続化、メールアカウントと同じ vault config 方式) *)
If[! AssociationQ[$iSVMDPriorityGroups], $iSVMDPriorityGroups = <||>];
If[! ValueQ[$iSVMDPriorityGroupsLoaded], $iSVMDPriorityGroupsLoaded = False];
iSVMDPriorityGroupsPath[] := FileNameJoin[{iSVMDMailConfigRoot[], "prioritygroups.jsonl"}];
SourceVaultPriorityGroupsLoad[] :=
  Module[{path = iSVMDPriorityGroupsPath[], txt, recs},
    txt = If[FileExistsQ[path], Quiet@Check[Import[path, "Text", CharacterEncoding -> "ISO8859-1"], ""], ""];
    recs = If[! StringQ[txt] || StringTrim[txt] === "", {},
       DeleteCases[(Quiet@Check[ImportString[#, "RawJSON"], $Failed] &) /@
          Select[StringSplit[txt, "\n"], StringTrim[#] =!= "" &], $Failed]];
    recs = Select[recs, AssociationQ];
    $iSVMDPriorityGroups = Association[
       (ToString@Lookup[#, "Group", ""] -> N@Lookup[#, "Weight", 0.4]) & /@ recs];
    $iSVMDPriorityGroupsLoaded = True;
    <|"Status" -> "Loaded", "Count" -> Length[$iSVMDPriorityGroups]|>];
iSVMDPriorityGroupsSave[] :=
  Module[{path = iSVMDPriorityGroupsPath[], dir, lines},
    dir = DirectoryName[path];
    If[! DirectoryQ[dir], CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    lines = (ExportString[<|"Group" -> #, "Weight" -> $iSVMDPriorityGroups[#]|>,
        "RawJSON", "Compact" -> True] &) /@ Keys[$iSVMDPriorityGroups];
    Export[path, StringRiffle[lines, "\n"] <> If[lines === {}, "", "\n"], "Text",
      CharacterEncoding -> "ISO8859-1"];
    <|"Status" -> "Saved", "Count" -> Length[$iSVMDPriorityGroups]|>];
iSVMDPriorityGroupsEnsureLoaded[] :=
  If[! TrueQ[$iSVMDPriorityGroupsLoaded], SourceVaultPriorityGroupsLoad[]];
Options[SourceVaultSetPriorityGroupWeight] = {"Persist" -> True};
SourceVaultSetPriorityGroupWeight[group_String, weight_?NumericQ, OptionsPattern[]] :=
  (iSVMDPriorityGroupsEnsureLoaded[];
   AssociateTo[$iSVMDPriorityGroups, group -> N@Clip[weight, {0., 1.}]];
   If[TrueQ[OptionValue["Persist"]], iSVMDPriorityGroupsSave[]];
   <|"Status" -> "Set", "Group" -> group, "Weight" -> N@Clip[weight, {0., 1.}]|>);
SourceVaultPriorityGroupWeights[] := (iSVMDPriorityGroupsEnsureLoaded[]; $iSVMDPriorityGroups);
SourceVaultGroupWeightFor[group_] :=
  (iSVMDPriorityGroupsEnsureLoaded[]; Lookup[$iSVMDPriorityGroups, group, Missing["NotSet"]]);

(* 構造シグナル *)
$iSVMDDefaultSenderWeight = 0.4;
$iSVMDBulkPatterns = {"no-reply", "noreply", "no_reply", "do-not-reply",
   "donotreply", "do_not_reply", "mailer-daemon", "mailerdaemon", "bounce",
   "notification", "notifications", "newsletter"};

iSVMDOwnerPosition[snap_Association] :=
  Module[{owner = iSVMDOwnerEmails[], md = Lookup[snap, "MailMetadataPublic", <||>], toE, ccE},
    If[owner === {}, Return["Unknown"]];
    toE = ToLowerCase /@ SourceVaultMailParseEmails[ToString@Lookup[md, "To", ""]];
    ccE = ToLowerCase /@ SourceVaultMailParseEmails[ToString@Lookup[md, "Cc", ""]];
    Which[IntersectingQ[owner, toE], "To", IntersectingQ[owner, ccE], "Cc", True, "Bulk"]];

iSVMDBulkQ[snap_Association] :=
  Module[{md = Lookup[snap, "MailMetadataPublic", <||>], from, nRecip},
    from = ToLowerCase@ToString@Lookup[md, "From", ""];
    nRecip = Length[SourceVaultMailParseEmails[ToString@Lookup[md, "To", ""]]] +
       Length[SourceVaultMailParseEmails[ToString@Lookup[md, "Cc", ""]]];
    StringContainsQ[from, Alternatives @@ $iSVMDBulkPatterns] || nRecip >= 8];

iSVMDSenderEntity[snap_Association] :=
  Quiet@Check[
    If[Length[DownValues[SourceVault`SourceVaultGetEntity]] === 0, Missing["NoIdentity"],
      Module[{fid = Lookup[Lookup[snap, "AddressBookRefs", <||>], "FromIdentifier", Missing[]],
          fromEmail, idf, ent},
        If[! StringQ[fid],
          fromEmail = First[Append[
             SourceVaultMailParseEmails[ToString@Lookup[snap["MailMetadataPublic"], "From", ""]], ""]];
          If[fromEmail =!= "",
            With[{f = SourceVault`SourceVaultFindIdentifier["Email", fromEmail]},
              If[AssociationQ[f], fid = f["IdentifierId"]]]]];
        If[! StringQ[fid], Return[Missing["NoSender"], Module]];
        idf = SourceVault`SourceVaultGetIdentifier[fid];
        If[! AssociationQ[idf], Return[Missing["NoSender"], Module]];
        ent = Lookup[idf, "EntityRef", Missing[]];
        If[StringQ[ent], SourceVault`SourceVaultGetEntity[ent], Missing["Unlinked"]]]],
    Missing["NoIdentity"]];

iSVMDSenderWeight[snap_Association] :=
  Module[{ent = iSVMDSenderEntity[snap], pw, grp, gw},
    If[! AssociationQ[ent], Return[$iSVMDDefaultSenderWeight]];
    pw = Lookup[ent, "PriorityWeight", Missing[]];
    If[NumericQ[pw], Return[N@Clip[pw, {0., 1.}]]];
    grp = Lookup[ent, "Group", Missing[]];
    If[StringQ[grp], gw = SourceVaultGroupWeightFor[grp];
      If[NumericQ[gw], Return[N@Clip[gw, {0., 1.}]]]];
    $iSVMDDefaultSenderWeight];

SourceVaultMailComputePriority[snap_Association, workRequest_: Missing[], category_: Missing[]] :=
  Module[{sw, pos, bulk, wr, posAdj, bulkAdj, catAdj, pri},
    sw = iSVMDSenderWeight[snap];
    pos = iSVMDOwnerPosition[snap];
    bulk = iSVMDBulkQ[snap];
    wr = If[NumericQ[workRequest], Clip[N[workRequest], {0., 1.}], 0.0];
    posAdj = Which[pos === "To", 0.15, pos === "Cc", 0.0, pos === "Bulk", -0.25, True, 0.0];
    bulkAdj = If[bulk, -0.15, 0.0];
    (* LLM カテゴリ Notice (機械的通知・一斉配信・広告) は強い減点。
       DM はオーナー個人が To に入るため posAdj +0.15 が広告を持ち上げてしまう
       (未知送信者 0.4 + To 0.15 = 0.55)。Notice -0.30 で 0.25 に落とす。
       他カテゴリは WorkRequest が既に反映するので加減点しない。 *)
    catAdj = If[category === "Notice", -0.30, 0.0];
    pri = Clip[sw + 0.30 wr + posAdj + bulkAdj + catAdj, {0.0, 1.0}];
    <|"Priority" -> Round[pri, 0.01],
      "Components" -> <|"SenderWeight" -> sw, "OwnerPosition" -> pos, "Bulk" -> bulk,
         "WorkRequest" -> wr, "Category" -> category,
         "PositionAdj" -> posAdj, "BulkAdj" -> bulkAdj, "CategoryAdj" -> catAdj|>|>];

SourceVaultMailExplainPriority[snap_Association] :=
  SourceVaultMailComputePriority[snap,
    Quiet@Check[snap["Derived"]["WorkRequest"], Missing[]],
    Quiet@Check[With[{c = snap["Derived"]["Category"]}, If[StringQ[c], c, Missing[]]], Missing[]]];

(* 優先度式の変更を既処理 snapshot に反映する (LLM 不要・高速)。
   対象は PriorityComponents を持つもの = 過去に構造計算で Priority を出したもの。
   legacy maildb 由来の Priority (PriorityComponents 無し) は有意な別ソースなので触らない。 *)
Options[SourceVaultMailRecomputePriorities] = {"Persist" -> True};
SourceVaultMailRecomputePriorities[OptionsPattern[]] :=
  Module[{snaps = SourceVaultMailSnapshotList[], n = 0, changed = 0},
    Do[
      Module[{d = Lookup[snap, "Derived", <||>], wr, ct, cp, s2},
        If[! KeyExistsQ[d, "PriorityComponents"], Continue[]];
        n++;
        wr = Lookup[d, "WorkRequest", Missing[]];
        ct = With[{c = Lookup[d, "Category", Missing[]]}, If[StringQ[c], c, Missing[]]];
        cp = SourceVaultMailComputePriority[snap, wr, ct];
        If[d["Priority"] =!= cp["Priority"] || d["PriorityComponents"] =!= cp["Components"],
          d["Priority"] = cp["Priority"];
          d["PriorityComponents"] = cp["Components"];
          s2 = snap; s2["Derived"] = d;
          SourceVaultMailSnapshotPut[s2, "Persist" -> False];
          changed++]],
      {snap, snaps}];
    If[TrueQ[OptionValue["Persist"]] && changed > 0, SourceVaultMailStoreSave["All" -> False]];
    <|"Status" -> "Ok", "Eligible" -> n, "Recomputed" -> changed,
      "Total" -> Length[snaps]|>];

(* snapshot に派生結果を適用。優先度は構造的に計算(LLM は WorkRequest のみ)。 *)
iSVApplyDerived[snap_Association, res_Association] :=
  Module[{d = Lookup[snap, "Derived", <||>], s2 = snap, wr, cp, ct},
    (* 旧 LLM の Priority は WorkRequest の代理として扱う(後方互換) *)
    wr = Lookup[res, "WorkRequest", Lookup[res, "Priority", Missing[]]];
    (* カテゴリは語彙へ正規化して保存 (注入 Inferencer の日本語値も受ける)。
       優先度計算にも渡す (Notice = DM/一斉配信 は減点)。 *)
    ct = iSVMDNormalizeCategory[Lookup[res, "Category", Missing[]]];
    cp = SourceVaultMailComputePriority[snap, wr, If[StringQ[ct], ct, Missing[]]];
    d["Priority"] = cp["Priority"];
    d["PriorityComponents"] = cp["Components"];
    If[NumericQ[wr], d["WorkRequest"] = N@Clip[wr, {0., 1.}]];
    If[NumericQ[res["PrivacyLevel"]], d["PrivacyLevel"] = res["PrivacyLevel"]];
    If[StringQ[ct], d["Category"] = ct];
    (* 〆切はキーが在るときだけ更新: 再処理で「〆切なし」になれば Missing で上書き、
       Deadline 非対応の旧 Inferencer では既存値を保持。 *)
    If[KeyExistsQ[res, "Deadline"],
      d["Deadline"] = With[{dl = res["Deadline"]},
         Which[
           StringQ[dl], With[{n = iSVMDNormalizeDeadline[dl]}, If[StringQ[n], n, dl]],
           MatchQ[dl, Missing["None"]], Missing["None"],
           True, Lookup[d, "Deadline", Missing["NotGenerated"]]]]];
    If[StringQ[res["Summary"]], d["Summary"] = res["Summary"]];
    d["DerivedStatus"] = "Processed";
    d["DerivedSource"] = "LocalLLM+Structured";
    s2["Derived"] = d; s2];

(* ---- mailspec enricher 登録 (拡張ポイント) ----
   サマリー作成 (派生) のときだけ呼ばれる。登録が無ければ完全素通しで
   SourceVault 単体の動作は変わらない。enricher が本文を拡張しても保存
   レコードは標準形式のまま (Derived.DerivedEnrichment に名前が付くのみ。
   暗号化済み body は変更しない)。 *)
If[! AssociationQ[$iSVMDMailspecEnrichers], $iSVMDMailspecEnrichers = <||>];

SourceVaultRegisterMailspecEnricher[name_String, f_] :=
  (AssociateTo[$iSVMDMailspecEnrichers, name -> f];
   <|"Status" -> "Registered", "Name" -> name|>);
SourceVaultUnregisterMailspecEnricher[name_String] :=
  ($iSVMDMailspecEnrichers = KeyDrop[$iSVMDMailspecEnrichers, name];
   <|"Status" -> "Unregistered", "Name" -> name|>);
SourceVaultMailspecEnrichers[] := Keys[$iSVMDMailspecEnrichers];

(* --- post-fetch hook: SourceVaultMailFetchNew 完了時に f[mbox, fetchResult] を呼ぶ。
   取り込み後の派生処理 (mining の著者抽出など) を maildb に依存させずに結線するための拡張点。
   hook の失敗は fetch を壊さない (Quiet@Check)。未登録なら完全素通し。 *)
If[! AssociationQ[$iSVMDPostFetchHooks], $iSVMDPostFetchHooks = <||>];
SourceVaultRegisterPostFetchHook[name_String, f_] :=
  (AssociateTo[$iSVMDPostFetchHooks, name -> f];
   <|"Status" -> "Registered", "Name" -> name|>);
SourceVaultUnregisterPostFetchHook[name_String] :=
  ($iSVMDPostFetchHooks = KeyDrop[$iSVMDPostFetchHooks, name];
   <|"Status" -> "Unregistered", "Name" -> name|>);
SourceVaultPostFetchHooks[] := Keys[$iSVMDPostFetchHooks];
iSVMDRunPostFetchHooks[mbox_String, result_Association] :=
  KeyValueMap[Function[{nm, f}, Quiet @ Check[f[mbox, result], $Failed]], $iSVMDPostFetchHooks];

iSVMDEnrichMailspec[spec_Association, snap_Association] :=
  Module[{s = spec, applied = {}},
    KeyValueMap[
      Function[{name, f},
        Module[{r = Quiet@Check[f[s, snap], $Failed]},
          If[AssociationQ[r] && r =!= s, applied = Append[applied, name]; s = r]]],
      $iSVMDMailspecEnrichers];
    If[applied =!= {}, s["_enrichedBy"] = applied];
    s];

(* 派生レコードに enrichment 名を記録 (透明性のための追加キーのみ) *)
iSVMDStampEnrichment[snap_Association, spec_Association] :=
  With[{names = Lookup[spec, "_enrichedBy", Missing[]]},
    If[! ListQ[names] || names === {}, snap,
      Module[{s2 = snap, d = Lookup[snap, "Derived", <||>]},
        d["DerivedEnrichment"] = names; s2["Derived"] = d; s2]]];

iSVSnapMailspec[snap_Association] :=
  Module[{md = Lookup[snap, "MailMetadataPublic", <||>], bodyR, spec},
    bodyR = SourceVaultMailSnapshotDecryptBody[snap];
    spec = <|"date" -> ToString@Lookup[md, "Date", ""],
      "subject" -> ToString@Lookup[md, "Subject", ""],
      "from" -> ToString@Lookup[md, "From", ""],
      "to" -> ToString@Lookup[md, "To", ""],
      "cc" -> ToString@Lookup[md, "Cc", ""],
      "body" -> If[Lookup[bodyR, "Status", ""] === "Ok", bodyR["Body"], ""],
      "_bodyStatus" -> Lookup[bodyR, "Status", "Error"]|>;
    iSVMDEnrichMailspec[spec, snap]];

Options[SourceVaultInferMailDerivedBatch] = {
   "Limit" -> 50, "DateFrom" -> Automatic, "DateTo" -> Automatic,
   "Refresh" -> None,
   "Inferencer" -> Automatic, "CheckpointEvery" -> 20, "Persist" -> True};

SourceVaultInferMailDerivedBatch[OptionsPattern[]] :=
  Module[{infer, lim, ck, persist, pendBefore, batch, pend, df, dt, ref,
      done = 0, failBody = 0, failLLM = 0, sinceCk = 0},
    infer = OptionValue["Inferencer"] /. Automatic -> SourceVaultMailInferDerived;
    lim = OptionValue["Limit"]; ck = OptionValue["CheckpointEvery"];
    persist = TrueQ[OptionValue["Persist"]];
    (* 日付範囲フィルタ (任意)。SourceVaultSearchMailSnapshots と同じ
       iSVMDDayListOf / iSVMDDateInRange を使い、DateObject/文字列/{y,m,d} を
       日単位で包含比較する。Limit はフィルタ後に適用される件数上限。
       範囲内すべてを処理するには "Limit" -> Infinity を指定する。 *)
    df = iSVMDDayListOf[OptionValue["DateFrom"]];
    dt = iSVMDDayListOf[OptionValue["DateTo"]];
    (* "Refresh": None=Pending のみ (既定)。"MissingCategory"=Category 未生成の
       Processed も対象 (Category/Deadline 導入前に処理済みの旧 snapshot の後埋め用)。
       All=ロード済み全件を再処理。Function=述語に一致する snapshot を再処理
       (例: Cerezo 通知だけリンク先込みで再派生)。 *)
    ref = OptionValue["Refresh"];
    pend = Which[
      ref === All || ref === "All", SourceVaultMailSnapshotList[],
      ref === "MissingCategory",
        Select[SourceVaultMailSnapshotList[],
          Function[s, SourceVaultMailDerivedPendingQ[s] ||
            ! StringQ[Lookup[Lookup[s, "Derived", <||>], "Category", Missing[]]]]],
      Head[ref] === Function,
        Select[SourceVaultMailSnapshotList[],
          TrueQ[Quiet@Check[ref[#], False]] &],
      True, SourceVaultMailDerivedPending[]];
    pendBefore = Length[pend];
    If[df =!= Automatic || dt =!= Automatic,
      pend = Select[pend, iSVMDDateInRange[#, df, dt] &]];
    batch = If[IntegerQ[lim] && lim >= 0, Take[pend, UpTo[lim]], pend];
    Do[
      Module[{spec, res, s2},
        spec = iSVSnapMailspec[snap];
        If[spec["_bodyStatus"] =!= "Ok", failBody++; Continue[]];
        res = infer[KeyDrop[spec, {"_bodyStatus", "_enrichedBy"}]];
        If[! AssociationQ[res] || Lookup[res, "Status", "Ok"] === "Error", failLLM++; Continue[]];
        s2 = iSVMDStampEnrichment[iSVApplyDerived[snap, res], spec];
        SourceVaultMailSnapshotPut[s2, "Persist" -> False];
        done++; sinceCk++;
        If[persist && sinceCk >= ck, SourceVaultMailStoreSave["All" -> False]; sinceCk = 0]],
      {snap, batch}];
    If[persist && sinceCk > 0, SourceVaultMailStoreSave["All" -> False]];
    <|"Status" -> "Ok", "PendingBefore" -> pendBefore,
      "InDateRange" -> Length[pend], "Selected" -> Length[batch],
      "Processed" -> done,
      "Failed" -> failBody + failLLM,
      "FailedBodyDecrypt" -> failBody, "FailedLLM" -> failLLM,
      "RemainingPending" -> Length[SourceVaultMailDerivedPending[]]|>];

(* 「<mbox>の新着メールにサマリーを追加」の正準1関数。EnsureLoaded(スコープ確定)→
   その mbox の未処理だけをバッチ要約・永続化、を内包する。
   重要: 外部 WolframScript ジョブへ退避されたとき、子プロセスはメールストアが空
   から始まる (SourceVaultMailDerivedPending[]=0)。EnsureLoaded を式の外で済ませて
   バッチだけを外部化すると 0 件処理で終わる。本関数は両者を1式に閉じ込めるので、
   提案が `SourceVaultMailAddSummaries["univ","Latest"]` 単体でも外部プロセスで
   自己完結してロード→要約まで走る。mbox 絞りは正しいパス #["MailSource"]["MBox"] を使う。 *)
Options[SourceVaultMailAddSummaries] =
  {"Limit" -> Infinity, "Persist" -> True, "CheckpointEvery" -> 3};
SourceVaultMailAddSummaries[mbox_String, period_ : "Latest",
    OptionsPattern[]] :=
  Module[{ensured, result},
    ensured = SourceVaultMailEnsureLoaded[mbox, period];
    result = SourceVaultInferMailDerivedBatch[
      "Refresh" -> Function[s,
        SourceVaultMailDerivedPendingQ[s] &&
          Quiet@Check[s["MailSource", "MBox"], Missing[]] === mbox],
      "Limit"   -> OptionValue["Limit"],
      "Persist" -> OptionValue["Persist"],
      (* 同期実行が打ち切られても進捗が残るよう頻繁に保存 (既定 3 件ごと)。 *)
      "CheckpointEvery" -> OptionValue["CheckpointEvery"]];
    <|"Status" -> "Ok", "MBox" -> mbox, "Period" -> period,
      "Loaded" -> ensured, "Batch" -> result|>];

(* ---- 実 IMAP source (Python imaplib 経由) ---- *)
(* Period 受理形式:
   "Latest"(直近14日) / n(直近n日, 整数) /
   {年, 月}(その月) / {年, 月, 日}(その日) / {from, to}(明示 ISO 範囲) /
   "YYYYMM"(その月) / "YYYY"(その年) *)
iSVIMAPFmt[d_] := DateString[d, {"Year", "-", "Month", "-", "Day"}];
iSVIMAPDateRange[period_] :=
  Module[{today = DateObject[Take[DateList[], 3]]},
    Which[
      period === "Latest", {iSVIMAPFmt[DatePlus[today, {-14, "Day"}]], iSVIMAPFmt[DatePlus[today, {1, "Day"}]]},
      IntegerQ[period], {iSVIMAPFmt[DatePlus[today, {-period, "Day"}]], iSVIMAPFmt[DatePlus[today, {1, "Day"}]]},
      MatchQ[period, {_Integer, _Integer}],   (* {年, 月} -> その月 *)
        With[{s = DateObject[{period[[1]], period[[2]], 1}]},
          {iSVIMAPFmt[s], iSVIMAPFmt[DatePlus[s, {1, "Month"}]]}],
      MatchQ[period, {_Integer, _Integer, _Integer}],  (* {年, 月, 日} -> その日 *)
        With[{s = DateObject[{period[[1]], period[[2]], period[[3]]}]},
          {iSVIMAPFmt[s], iSVIMAPFmt[DatePlus[s, {1, "Day"}]]}],
      MatchQ[period, {_, _}], {ToString[period[[1]]], ToString[period[[2]]]},
      StringQ[period] && StringLength[period] === 6 && StringMatchQ[period, DigitCharacter ..],
        With[{s = DateObject[{ToExpression@StringTake[period, 4], ToExpression@StringTake[period, {5, 6}], 1}]},
          {iSVIMAPFmt[s], iSVIMAPFmt[DatePlus[s, {1, "Month"}]]}],
      StringQ[period] && StringLength[period] === 4 && StringMatchQ[period, DigitCharacter ..],
        With[{s = DateObject[{ToExpression[period], 1, 1}]},
          {iSVIMAPFmt[s], iSVIMAPFmt[DatePlus[s, {1, "Year"}]]}],
      True, iSVIMAPDateRange["Latest"]]];

(* 添付の親ルート ($SourceVaultLegacyMailRoot は既定値なしの素シンボルなので
   文字列フォールバックを自前で持つ。mailui の iSVUILegacyRoot と同ロジック)。 *)
iSVIMAPLegacyRoot[] :=
  If[StringQ[SourceVault`$SourceVaultLegacyMailRoot],
    SourceVault`$SourceVaultLegacyMailRoot,
    FileNameJoin[{DirectoryName[
       Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $TemporaryDirectory]], "mails"}]];

iSVIMAPPythonSource[mbox_String, srcOpts_Association] :=
  Module[{acct, pw, range, attBase, session, code, res},
    acct = iSVMDGetMailAccount[mbox];
    If[! AssociationQ[acct],
      Return[{<|"_error" -> "UnregisteredMailbox: " <> mbox <>
         " — SourceVaultRegisterMailAccount で登録してください"|>}]];
    pw = Quiet@Check[ToString[SystemCredential[acct["CredKey"]]], "$Failed"];
    If[pw === "" || pw === "Null" || pw === "$Failed" || StringContainsQ[pw, "Missing"],
      Return[{<|"_error" -> "NoCredential: SystemCredential[\"" <> acct["CredKey"] <> "\"] 未設定"|>}]];
    range = iSVIMAPDateRange[Lookup[srcOpts, "Period", "Latest"]];
    attBase = FileNameJoin[{iSVIMAPLegacyRoot[], mbox}];
    If[! StringQ[attBase], Return[{<|"_error" -> "AttachmentRootUnresolved"|>}]];
    session = Quiet@Check[StartExternalSession["Python"], $Failed];
    If[Head[session] =!= ExternalSessionObject,
      Return[{<|"_error" -> "PythonSessionFailed: ExternalEvaluate[\"Python\"] 不可 (Python 登録要確認)"|>}]];
    code = iSVBuildPython[acct["Server"], acct["Port"], acct["User"], pw,
       range[[1]], range[[2]], attBase, Lookup[srcOpts, "MaxEmails", Automatic]];
    res = Quiet@Check[ExternalEvaluate[session, code], $Failed];
    Quiet@DeleteObject[session];
    If[! ListQ[res], Return[{<|"_error" -> "PythonEvalFailed"|>}]];
    (* python は dict のリストを返す -> WL Association 化、キー名は maildb 互換 *)
    (Association[#] & /@ Select[res, AssociationQ]) /.
       r_Association :> KeyMap[ToString, r]];

iSVBuildPython[server_, port_, user_, pw_, since_, before_, attBase_, maxN_] :=
  Module[{maxLine},
    (* try ブロック内 (4スペース) に挿入されるので 4スペース字下げ。8スペースだと IndentationError で script 全体が PythonEvalFailed になる *)
    maxLine = If[IntegerQ[maxN], "    email_ids = email_ids[-" <> ToString[maxN] <> ":]\n", ""];
    StringJoin[{
"import imaplib, email, os, json, re\n",
"from email.header import decode_header\n",
"from email.utils import parsedate_to_datetime\n",
"def _dec(s):\n",
"    if s is None: return ''\n",
"    out=''\n",
"    for t,enc in decode_header(s):\n",
"        if isinstance(t,bytes):\n",
"            try: out+=t.decode(enc or 'utf-8','ignore')\n",
"            except: out+=t.decode('utf-8','ignore')\n",
"        else: out+=t\n",
"    return out\n",
"def _body(m):\n",
"    if m.is_multipart():\n",
"        for p in m.walk():\n",
"            if p.get_content_type()=='text/plain' and 'attachment' not in str(p.get('Content-Disposition')):\n",
"                pl=p.get_payload(decode=True)\n",
"                if pl:\n",
"                    try: return pl.decode(p.get_content_charset() or 'utf-8','ignore')\n",
"                    except: return pl.decode('utf-8','ignore')\n",
"        return ''\n",
"    pl=m.get_payload(decode=True)\n",
"    if pl:\n",
"        try: return pl.decode(m.get_content_charset() or 'utf-8','ignore')\n",
"        except: return pl.decode('utf-8','ignore')\n",
"    return ''\n",
"_out=[]\n",
"try:\n",
"    c=imaplib.IMAP4_SSL('"<>server<>"',"<>ToString[port]<>")\n",
"    c.login('"<>user<>"','"<>StringReplace[pw,{"\\"->"\\\\","'"->"\\'"}]<>"')\n",
"    c.select('INBOX')\n",
"    typ,data=c.search(None,'(SINCE \""<>iSVImapDate[since]<>"\" BEFORE \""<>iSVImapDate[before]<>"\")')\n",
"    email_ids=data[0].split()\n",
maxLine,
"    for eid in email_ids:\n",
"        typ,md=c.fetch(eid,'(RFC822)')\n",
"        if not md or not md[0]: continue\n",
"        m=email.message_from_bytes(md[0][1])\n",
"        try: _rh='\\n'.join('%s: %s'%(k,v) for k,v in m.items())\n",
"        except: _rh=''\n",
"        try: dt=parsedate_to_datetime(m.get('Date'))\n",
"        except: dt=None\n",
"        ym=dt.strftime('%Y%m') if dt else '000000'\n",
"        attdir=os.path.join('"<>StringReplace[attBase,"\\"->"\\\\"]<>"',ym+'_attachment')\n",
"        names=[]\n",
"        for p in m.walk():\n",
"            fn=p.get_filename()\n",
"            if fn:\n",
"                fn=_dec(fn); names.append(fn)\n",
"                try:\n",
"                    os.makedirs(attdir,exist_ok=True)\n",
"                    with open(os.path.join(attdir,fn),'wb') as fh: fh.write(p.get_payload(decode=True) or b'')\n",
"                except: pass\n",
"        _out.append({'id':m.get('Message-ID') or _dec(m.get('Subject')),\n",
"          'date':dt.isoformat() if dt else '','subject':_dec(m.get('Subject')),\n",
"          'from':_dec(m.get('From')),'to':_dec(m.get('To')),'cc':_dec(m.get('Cc')) or '',\n",
"          'body':_body(m),'attachment':','.join(names),'rawheader':_rh})\n",
"    c.logout()\n",
"except Exception as e:\n",
"    _out=[{'_error':str(e)}]\n",
"_out\n"}]];

iSVImapDate[iso_String] :=
  Module[{d = Quiet@Check[DateObject[iso], $Failed]},
    If[Head[d] === DateObject, DateString[d, {"Day", "-", "MonthNameShort", "-", "Year"}], iso]];

(* ---- fetch エントリ ---- *)
Options[SourceVaultMailFetchNew] = {
   "Period" -> "Latest", "Process" -> False, "MessageSource" -> Automatic,
   "Inferencer" -> Automatic, "Persist" -> True, "MaxEmails" -> Automatic,
   "Overwrite" -> False};

SourceVaultMailFetchNew[mbox_String, OptionsPattern[]] :=
  Module[{src, msgs, errs, existsQ, newMsgs, toStore, infer, overwrite, result,
      processed = 0, stored = 0, overwritten = 0},
    src = OptionValue["MessageSource"] /. Automatic -> Function[so, iSVIMAPPythonSource[mbox, so]];
    msgs = src[<|"Period" -> OptionValue["Period"], "MaxEmails" -> OptionValue["MaxEmails"], "Mbox" -> mbox|>];
    If[! ListQ[msgs],
      Return[<|"Status" -> "Error", "Reason" -> "FetchFailed", "MBox" -> mbox|>]];
    errs = Select[msgs, AssociationQ[#] && KeyExistsQ[#, "_error"] &];
    If[errs =!= {},
      Return[<|"Status" -> "Error", "Reason" -> "IMAPError", "MBox" -> mbox,
        "Detail" -> Lookup[First[errs], "_error", ""]|>]];
    msgs = Select[msgs, AssociationQ];
    iSVMDIdentityEnsureLoaded[];  (* 識別子を上書きしないよう先に load *)
    overwrite = TrueQ[OptionValue["Overwrite"]];
    existsQ = ! MissingQ[SourceVaultMailSnapshotGet[
       iSVMDRecordId[mbox, ToString[Lookup[#, "id", "unknown"]]]]] &;
    newMsgs = Select[msgs, ! existsQ[#] &];
    (* Overwrite->True なら既存(同一 RecordId)も再保存して修復/更新する *)
    toStore = If[overwrite, msgs, newMsgs];
    overwritten = If[overwrite, Length[msgs] - Length[newMsgs], 0];
    infer = OptionValue["Inferencer"] /. Automatic -> SourceVaultMailInferDerived;
    Do[
      Module[{snap = SourceVaultMailSnapshotFromMaildb[m, mbox], spec, res},
        If[TrueQ[OptionValue["Process"]],
          spec = iSVSnapMailspec[snap];
          If[spec["_bodyStatus"] === "Ok",
            res = infer[KeyDrop[spec, {"_bodyStatus", "_enrichedBy"}]];
            If[AssociationQ[res] && Lookup[res, "Status", "Ok"] =!= "Error",
              snap = iSVMDStampEnrichment[iSVApplyDerived[snap, res], spec];
              processed++]]];
        SourceVaultMailSnapshotPut[snap, "Persist" -> False]; stored++],
      {m, toStore}];
    If[TrueQ[OptionValue["Persist"]], SourceVaultMailStoreSave["All" -> False]; iSVMDIdentitySaveSafe[]];
    result = <|"Status" -> "Ok", "MBox" -> mbox, "Fetched" -> Length[msgs],
      "New" -> Length[newMsgs], "Stored" -> stored,
      "Overwritten" -> overwritten,
      "Duplicates" -> If[overwrite, 0, Length[msgs] - Length[newMsgs]],
      "Processed" -> processed,
      "ProcessMode" -> If[TrueQ[OptionValue["Process"]], "Inline", "Deferred"]|>;
    (* 取り込み完了後フック (mining の著者抽出など)。失敗しても fetch は成功扱い。
       結果を観測できるよう PostFetchHooks に各フックの戻り値を載せる (フックは基底 result を受け取る)。 *)
    Append[result, "PostFetchHooks" -> iSVMDRunPostFetchHooks[mbox, result]]];

End[];
EndPackage[];


(* ::Package:: *)

(* ============================================================
   SourceVault_mailui.wl -- mail FE 操作 (本文/添付/返信) -- 旧 maildb 踏襲

   This file is encoded in UTF-8.
   Load order: ... -> SourceVault_maildb.wl -> SourceVault_messagerelease.wl
               -> SourceVault_mailui.wl

   ロジック (本文復号 / 添付パス解決 / 返信ドラフト生成) は headless でテスト可能。
   FE ラッパ (ShowBody / OpenReplyNotebook / OpenAttachment) は front end が要る。
   添付は旧 maildb の <legacyRoot>/<mbox>/<yyyymm>_attachment/<name> に在る。
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultMailGetBody::usage = "SourceVaultMailGetBody[recordId] は snapshot の暗号化本文を復号して文字列で返す。";
SourceVaultMailShowBody::usage = "SourceVaultMailShowBody[recordId] は本文を新規ノートブックで表示する (front end)。";
SourceVaultMailAttachmentDir::usage = "SourceVaultMailAttachmentDir[mbox, yyyymm] は旧 maildb 添付ディレクトリのパスを返す。";
SourceVaultMailAttachments::usage = "SourceVaultMailAttachments[recordId] は添付 {Name, Path, Exists} のリストを返す。";
SourceVaultMailOpenAttachment::usage = "SourceVaultMailOpenAttachment[recordId, name] は添付ファイルを開く (front end / SystemOpen)。";
SourceVaultMailComposeReply::usage = "SourceVaultMailComposeReply[recordId, opts] は返信ドラフト <|To,Cc,Subject,InReplyToToken,Quoted,Body|> を生成する。\"ReplyAll\"->True で Cc 含む。";
SourceVaultMailOpenReplyNotebook::usage = "SourceVaultMailOpenReplyNotebook[recordId, opts] は返信ドラフトのノートブックを開く (front end)。";
SourceVaultMailView::usage = "SourceVaultMailView[query_String:\"\", opts] は検索結果を、行ごとに 本文表示(✉)/添付ポップアップ(📎)/返信(↩) のクリック操作を備えた表 (Dataset) で返す。旧 maildb showMails 踏襲。";
SourceVaultMailRowActions::usage = "SourceVaultMailRowActions[snapshot] は1行分のアクション (Body/Attachments/Reply ボタン) を返す。";
SourceVaultAddressBookView::usage = "SourceVaultAddressBookView[] は連絡先を整形表 (Dataset) で表示する。Uid/表示名/かな/メール/分類/信頼/MaxPL/AccessTags。";
SourceVaultIdentityLinkUI::usage = "SourceVaultIdentityLinkUI[opts] は識別子を実体に紐付ける編集表(front end)。各行で 新規(ヘッダ継承で実体作成)/マージ(既存実体にアドレス追加)。opts: \"ShowLinked\"(既定False=未リンクのみ), \"Limit\"(既定200)。";
SourceVaultEntityView::usage = "SourceVaultEntityView[] は実体(人/組織/Bot/ML)の一覧表(Dataset)。各行に編集ボタン。Uid/種別/表示名/かな/識別子数/グループ/重み/信頼。";
SourceVaultEntityEditUI::usage = "SourceVaultEntityEditUI[entityIdOrUid] は実体1件の編集フォーム(front end)。表示名/種別/漢字/ローマ字/かな/分類/グループ/重み/所属/信頼 を編集し保存。";
$SourceVaultLegacyMailRoot::usage = "旧 maildb のメールルート (添付ディレクトリの親)。既定は PrivateVault と同階層の udb/mails。";
$SourceVaultMailNotebookStyle::usage = "本文表示・返信ノートブックの StyleDefinitions。既定 \"SourceVault default.nb\"。";
$SourceVaultMailViewMaxRows::usage = "$SourceVaultMailViewMaxRows はメール一覧 Dataset (SourceVaultMailView 等) が一度に描画する最大行数。Windows 版 FrontEnd は項目数の多い Dataset の描画が重いため既定 25 (Pane スクロール + Dataset ページング前提)。All で無制限。整数を設定すると即反映。";
SourceVaultMarkConfidentialViewCells::usage = "SourceVaultMarkConfidentialViewCells[nb] は notebook 内の「ノートブック生データを表示する出力セル」(メール View=SourceVaultMailView/MailDataset/MailSearchSummary、Todo 生テキスト=SourceVaultFindTodos) を、含まれる項目の最大プライバシーで機密マークする。メールは Derived.PrivacyLevel、Todo はソースノートブックの Publishable (全 Public なら 0.0=マークせず、1 つでも非 Public なら 1.0)。クラウド LLM (閾値0.5) へはスキーマのみ、ローカル LLM (閾値1.0) へは全文。サマリー/予定表 (SourceVaultUpcomingSchedule 等) はクラウド安全なので対象外。検出対象は共有レジストリで拡張される (SourceVault_eagle.wl ロード時は Eagle View/Dataset/Search/GeoView も対象)。nb 省略時は EvaluationNotebook[]。返り値: {<|\"Cell\"->idx,\"PrivacyLevel\"->pl|>...}。";
SourceVaultMailMarkViewCells::usage = "SourceVaultMailMarkViewCells[nb] は SourceVaultMarkConfidentialViewCells の別名 (後方互換)。メール・Todo など生データ出力セルを機密マークする。";
SourceVaultMailEnableAutoConfidential::usage = "SourceVaultMailEnableAutoConfidential[] は NBAccess`NBMakeContextPacket にフックを装着し、ClaudeEval/ClaudeQuery の文脈構築直前に SourceVaultMarkConfidentialViewCells で生データ出力セル (メール View / Todo 生テキスト) を自動機密マークする。冪等。SourceVaultMailDisableAutoConfidential[] で解除。";
SourceVaultMailDisableAutoConfidential::usage = "SourceVaultMailDisableAutoConfidential[] は SourceVaultMailEnableAutoConfidential[] で装着したフックを解除し、NBMakeContextPacket を元に戻す。";

Begin["`Private`"];

If[! ValueQ[$SourceVaultMailNotebookStyle],
  $SourceVaultMailNotebookStyle = "SourceVault default.nb"];

(* Windows 版 FrontEnd は項目数の多い Dataset の描画が重い。メール一覧の
   一度に描画する行数を既定 25 に抑え、Pane スクロール + Dataset ページング
   前提にする。All で無制限。 *)
If[! ValueQ[$SourceVaultMailViewMaxRows],
  $SourceVaultMailViewMaxRows = 25];

iSVUILegacyRoot[] :=
  If[StringQ[$SourceVaultLegacyMailRoot], $SourceVaultLegacyMailRoot,
     FileNameJoin[{DirectoryName[
        Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $TemporaryDirectory]], "mails"}]];

iSVUISnap[recordId_String] := SourceVault`SourceVaultMailSnapshotGet[recordId];
iSVUISnap[snap_Association] := snap;

iSVUIYearMonth[snap_] :=
  Module[{d = Quiet@Check[snap["MailMetadataPublic", "Date"], Missing[]]},
    If[StringQ[d] && StringLength[d] >= 7, StringTake[d, 4] <> StringTake[d, {6, 7}], Missing["NoDate"]]];

SourceVaultMailGetBody[record_] :=
  Module[{snap = iSVUISnap[record], r},
    If[! AssociationQ[snap], Return[<|"Status" -> "Error", "Reason" -> "NotFound"|>]];
    r = SourceVault`SourceVaultMailSnapshotDecryptBody[snap];
    r];

SourceVaultMailAttachmentDir[mbox_String, yyyymm_String] :=
  FileNameJoin[{iSVUILegacyRoot[], mbox, yyyymm <> "_attachment"}];

SourceVaultMailAttachments[record_] :=
  Module[{snap = iSVUISnap[record], mbox, ym, names, dir},
    If[! AssociationQ[snap], Return[{}]];
    mbox = Quiet@Check[snap["MailSource", "MBox"], Missing[]];
    ym = iSVUIYearMonth[snap];
    names = Lookup[snap["MailMetadataPublic"], "Attachments", Missing["NotInSnapshot"]];
    If[! ListQ[names],
      Return[{<|"Status" -> "AttachmentNamesNotInSnapshot",
         "Hint" -> "再 import すると添付ファイル名が snapshot に入る (SourceVaultImportMaildbFile)。",
         "Count" -> Lookup[snap["MailMetadataPublic"], "AttachmentCount", 0]|>}]];
    If[! StringQ[mbox] || ! StringQ[ym], Return[{}]];
    dir = SourceVaultMailAttachmentDir[mbox, ym];
    (With[{p = FileNameJoin[{dir, #}]},
       <|"Name" -> #, "Path" -> p, "Exists" -> FileExistsQ[p]|>] &) /@ names];

SourceVaultMailOpenAttachment[record_, name_String] :=
  Module[{atts = SourceVaultMailAttachments[record], hit},
    hit = SelectFirst[atts, Lookup[#, "Name", ""] === name &, Missing[]];
    If[! AssociationQ[hit] || ! TrueQ[hit["Exists"]],
      Return[<|"Status" -> "Error", "Reason" -> "AttachmentNotFound", "Name" -> name|>]];
    Quiet@Check[SystemOpen[hit["Path"]], Null];
    <|"Status" -> "Opened", "Path" -> hit["Path"]|>];

(* ---- 返信ドラフト (ロジック) ---- *)
iSVUIFromEmail[snap_] :=
  Module[{f = Lookup[snap["MailMetadataPublic"], "From", ""], em},
    em = If[StringQ[f], SourceVault`SourceVaultMailParseEmails[f], {}];
    If[em === {}, Missing["NoFrom"], First[em]]];

iSVUIReplyAddresses[snap_] :=
  Module[{to, cc},
    to = SourceVault`SourceVaultMailParseEmails[ToString@Lookup[snap["MailMetadataPublic"], "To", ""]];
    cc = SourceVault`SourceVaultMailParseEmails[ToString@Lookup[snap["MailMetadataPublic"], "Cc", ""]];
    {to, cc}];

iSVUIQuote[from_, date_, body_] :=
  StringJoin[
    If[StringQ[date], date <> " ", ""], If[StringQ[from], from, ""], " wrote:\n",
    StringRiffle["> " <> # & /@ StringSplit[If[StringQ[body], body, ""], "\n"], "\n"]];

Options[SourceVaultMailComposeReply] = {"ReplyAll" -> False, "Body" -> ""};
SourceVaultMailComposeReply[record_, OptionsPattern[]] :=
  Module[{snap = iSVUISnap[record], subject, fromEmail, bodyR, body, to, cc, selfEmail},
    If[! AssociationQ[snap], Return[<|"Status" -> "Error", "Reason" -> "NotFound"|>]];
    subject = ToString@Lookup[snap["MailMetadataPublic"], "Subject", ""];
    If[! StringQ[subject], subject = ""];
    fromEmail = iSVUIFromEmail[snap];
    bodyR = SourceVaultMailGetBody[snap];
    body = If[Lookup[bodyR, "Status", ""] === "Ok", bodyR["Body"],
       (* 復号失敗を黙って空にせず、理由を明示する (鍵 backend の取り違え検知) *)
       "[\:672c\:6587\:3092\:5fa9\:53f7\:3067\:304d\:307e\:305b\:3093\:3067\:3057\:305f: " <>
         ToString@Lookup[bodyR, "Reason", Lookup[bodyR, "Status", "Unknown"]] <>
         " \:2014 NBAccess`$NBCredentialBackend = \"SystemCredential\" \:3092\:78ba\:8a8d\:3057\:3066\:304f\:3060\:3055\:3044]"];
    {to, cc} = iSVUIReplyAddresses[snap];
    (* 自分(オーナー)宛は cc から除外 (ReplyAll 用)。オーナーのメールは識別子層 #1 から。 *)
    With[{ownerEmails = iSVMDOwnerEmails[]},
      cc = DeleteCases[Join[to, cc], _?(MemberQ[ownerEmails, ToLowerCase[#]] &)]];
    <|"Status" -> "Draft",
      "To" -> If[StringQ[fromEmail], fromEmail, Missing["NoRecipient"]],
      "Cc" -> If[TrueQ[OptionValue["ReplyAll"]], DeleteDuplicates@DeleteCases[cc, fromEmail], {}],
      "Subject" -> If[StringStartsQ[subject, "Re:", IgnoreCase -> True], subject, "Re: " <> subject],
      "InReplyToToken" -> Lookup[snap["MailSource"], "MessageIDToken", Missing[]],
      "Quoted" -> iSVUIQuote[fromEmail, Lookup[snap["MailMetadataPublic"], "Date", Missing[]], body],
      "Body" -> OptionValue["Body"],
      "RecordId" -> Lookup[snap, "RecordId", Missing[]]|>];

(* ---- front end ラッパ (GUI が要る) ---- *)
SourceVaultMailShowBody[record_] :=
  Module[{snap = iSVUISnap[record], r, subj},
    r = SourceVaultMailGetBody[snap];
    If[Lookup[r, "Status", ""] =!= "Ok",
      (* GUI button はリターン値を捨てるので、失敗理由をノートブックに出す *)
      Quiet@Check[
        CreateDocument[{
          Cell[iSVL["DecryptFailTitle"], "Subtitle"],
          Cell["Reason: " <> ToString@Lookup[r, "Reason", Lookup[r, "Status", "Unknown"]], "Text"],
          Cell[iSVL["DecryptFailHint"], "Text"]},
          WindowTitle -> iSVL["DecryptFailTitle"],
          StyleDefinitions -> $SourceVaultMailNotebookStyle], $Failed];
      Return[r]];
    subj = ToString@Lookup[snap["MailMetadataPublic"], "Subject", "(no subject)"];
    Quiet@Check[
      CreateDocument[{Cell[subj, "Subtitle"], Cell[r["Body"], "Text"]},
        WindowTitle -> subj,
        StyleDefinitions -> $SourceVaultMailNotebookStyle], $Failed];
    <|"Status" -> "Shown"|>];

SourceVaultMailOpenReplyNotebook[record_, opts : OptionsPattern[SourceVaultMailComposeReply]] :=
  Module[{draft = SourceVaultMailComposeReply[record, opts], header},
    If[Lookup[draft, "Status", ""] =!= "Draft", Return[draft]];
    header = "To: " <> ToString[draft["To"]] <>
       If[draft["Cc"] =!= {}, "\nCc: " <> StringRiffle[draft["Cc"], ", "], ""] <>
       "\nSubject: " <> draft["Subject"];
    Quiet@Check[
      CreateDocument[{
        Cell[header, "Text", FontColor -> GrayLevel[0.4]],
        Cell["", "Input"],
        Cell[draft["Quoted"], "Text", FontColor -> GrayLevel[0.55]]},
        WindowTitle -> draft["Subject"],
        StyleDefinitions -> $SourceVaultMailNotebookStyle], $Failed];
    <|"Status" -> "ReplyNotebookOpened", "Draft" -> draft|>];

(* ---- インタラクティブ表 (旧 maildb showMails 踏襲) ---- *)
(* 日付: JST に変換しコンパクト表示 "2026/06/05 木 14:53" (maildb formatDateJST 踏襲) *)
iSVUIJstDay = <|"Monday" -> "月", "Tuesday" -> "火", "Wednesday" -> "水",
   "Thursday" -> "木", "Friday" -> "金", "Saturday" -> "土", "Sunday" -> "日"|>;
iSVUIFormatDateJST[d_] :=
  Module[{obj, jst, dl},
    If[! StringQ[d] && Head[d] =!= DateObject, Return["-"]];
    obj = Quiet@Check[If[Head[d] === DateObject, d, DateObject[d]], $Failed];
    If[Head[obj] =!= DateObject, Return[If[StringQ[d], d, "-"]]];
    jst = Quiet@Check[TimeZoneConvert[obj, "Asia/Tokyo"], obj];
    dl = Quiet@Check[DateList[jst], $Failed];
    If[! ListQ[dl] || Length[dl] < 5, Return[If[StringQ[d], d, "-"]]];
    StringJoin[ToString[Round[dl[[1]]]], "/",
      StringPadLeft[ToString[Round[dl[[2]]]], 2, "0"], "/",
      StringPadLeft[ToString[Round[dl[[3]]]], 2, "0"], " ",
      Lookup[iSVUIJstDay, Quiet@Check[DateString[jst, "DayName"], ""], "?"], " ",
      StringPadLeft[ToString[Round[dl[[4]]]], 2, "0"], ":",
      StringPadLeft[ToString[Round[dl[[5]]]], 2, "0"]]];

iSVUINumCell[x_] := If[NumericQ[x], ToString@NumberForm[Round[N[x], 0.01], {3, 2}], ""];

(* 添付 ActionMenu: 名前ごとに開く Popup。名前が無い旧 snapshot は再 import を促す。 *)
iSVUIAttachMenu[snap_Association] :=
  Module[{rid = Lookup[snap, "RecordId", ""], names, cnt},
    names = Lookup[snap["MailMetadataPublic"], "Attachments", Missing[]];
    cnt = Lookup[snap["MailMetadataPublic"], "AttachmentCount", 0];
    Which[
      cnt === 0, "",
      ! ListQ[names],
        Tooltip["\[FilledSquare]" <> ToString[cnt], iSVL["AttachNamesHint"]],
      True,
        With[{r = rid},
          ActionMenu["\[FilledSquare]" <> ToString[cnt],
            (# :> SourceVaultMailOpenAttachment[r, #]) & /@ names,
            Appearance -> "Popup"]]]];

SourceVaultMailRowActions[snap_Association] :=
  With[{r = Lookup[snap, "RecordId", ""]},
    Row[{
      Button["\:2709", SourceVaultMailShowBody[r], Appearance -> "Frameless",
        Method -> "Queued"],
      Spacer[4], iSVUIAttachMenu[snap], Spacer[4],
      Button["\:21a9", SourceVaultMailOpenReplyNotebook[r], Appearance -> "Frameless",
        Method -> "Queued"]}, BaselinePosition -> Center]];

(* 表テキストフォント (ClaudeCode`$ClaudeStandardFont、未ロード時フォールバック) *)
iSVUIFont[] :=
  With[{f = Quiet@Check[ClaudeCode`$ClaudeStandardFont, $Failed]},
    If[StringQ[f] && f =!= "", f, "Yu Gothic UI"]];

(* identity ストアの自動ロード (UI を開いたとき未ロードでも動くように)。未ロードなら safe。 *)
iSVUIIdentityEnsureLoaded[] :=
  Quiet@Check[If[Length[DownValues[SourceVault`SourceVaultIdentityEnsureLoaded]] > 0,
     SourceVault`SourceVaultIdentityEnsureLoaded[], Null], Null];

(* ---- i18n: 英語キー -> $Language で日英ラベルに解決 (iL化対応) ----
   コード/スキーマのキーは英語固定。表示ラベルだけ $Language で切替。 *)
$iSVUILabels = <|
  "Att" -> <|"Japanese" -> "\:6dfb\:4ed8", "English" -> "Att"|>,
  "Reply" -> <|"Japanese" -> "\:8fd4\:4fe1", "English" -> "Reply"|>,
  "Date" -> <|"Japanese" -> "\:65e5\:4ed8", "English" -> "Date"|>,
  "Pri" -> <|"Japanese" -> "\:91cd\:8981", "English" -> "Pri"|>,
  "Sec" -> <|"Japanese" -> "\:79d8\:533f", "English" -> "Sec"|>,
  "Subject" -> <|"Japanese" -> "\:4ef6\:540d", "English" -> "Subject"|>,
  "From" -> <|"Japanese" -> "\:5dee\:51fa\:4eba", "English" -> "From"|>,
  "Summary" -> <|"Japanese" -> "\:6982\:8981", "English" -> "Summary"|>,
  "Cat" -> <|"Japanese" -> "分類", "English" -> "Cat"|>,
  "Deadline" -> <|"Japanese" -> "〆切", "English" -> "Due"|>,
  "NoMail" -> <|"Japanese" -> "\:8a72\:5f53\:3059\:308b\:30e1\:30fc\:30eb\:304c\:3042\:308a\:307e\:305b\:3093\:3002",
     "English" -> "No matching mail."|>,
  "Name" -> <|"Japanese" -> "\:8868\:793a\:540d", "English" -> "Name"|>,
  "Kana" -> <|"Japanese" -> "\:304b\:306a", "English" -> "Kana"|>,
  "Email" -> <|"Japanese" -> "\:30e1\:30fc\:30eb", "English" -> "Email"|>,
  "Category" -> <|"Japanese" -> "\:5206\:985e", "English" -> "Category"|>,
  "Trust" -> <|"Japanese" -> "\:4fe1\:983c", "English" -> "Trust"|>,
  "PL" -> <|"Japanese" -> "PL", "English" -> "PL"|>,
  "Tags" -> <|"Japanese" -> "AccessTags", "English" -> "AccessTags"|>,
  "Uid" -> <|"Japanese" -> "Uid", "English" -> "Uid"|>,
  "NoContact" -> <|"Japanese" -> "\:9023\:7d61\:5148\:304c\:3042\:308a\:307e\:305b\:3093\:3002",
     "English" -> "No contacts."|>,
  "DecryptFailTitle" -> <|"Japanese" -> "\:672c\:6587\:3092\:5fa9\:53f7\:3067\:304d\:307e\:305b\:3093\:3067\:3057\:305f",
     "English" -> "Could not decrypt body"|>,
  "DecryptFailHint" -> <|
     "Japanese" -> "NBAccess`$NBCredentialBackend = \"SystemCredential\" \:304b\:78ba\:8a8d\:3057\:3066\:304f\:3060\:3055\:3044\:3002",
     "English" -> "Check NBAccess`$NBCredentialBackend = \"SystemCredential\"."|>,
  "AttachNamesHint" -> <|"Japanese" -> "\:6dfb\:4ed8\:30d5\:30a1\:30a4\:30eb\:540d\:306f\:518d import \:3067\:6709\:52b9\:5316",
     "English" -> "Attachment names require re-import"|>,
  "New" -> <|"Japanese" -> "\:65b0\:898f", "English" -> "New"|>,
  "Merge" -> <|"Japanese" -> "\:30de\:30fc\:30b8", "English" -> "Merge"|>,
  "Unlink" -> <|"Japanese" -> "\:89e3\:9664", "English" -> "Unlink"|>,
  "Value" -> <|"Japanese" -> "\:30a2\:30c9\:30ec\:30b9", "English" -> "Address"|>,
  "ObservedNames" -> <|"Japanese" -> "\:89b3\:6e2c\:540d", "English" -> "Names"|>,
  "Count" -> <|"Japanese" -> "\:4ef6\:6570", "English" -> "Count"|>,
  "Entity" -> <|"Japanese" -> "\:5b9f\:4f53", "English" -> "Entity"|>,
  "Unlinked" -> <|"Japanese" -> "(\:672a\:30ea\:30f3\:30af)", "English" -> "(unlinked)"|>,
  "NoUnlinked" -> <|"Japanese" -> "\:672a\:30ea\:30f3\:30af\:306e\:8b58\:5225\:5b50\:306f\:3042\:308a\:307e\:305b\:3093\:3002",
     "English" -> "No unlinked identifiers."|>,
  "Edit" -> <|"Japanese" -> "\:7de8\:96c6", "English" -> "Edit"|>,
  "Save" -> <|"Japanese" -> "\:4fdd\:5b58", "English" -> "Save"|>,
  "Kind" -> <|"Japanese" -> "\:7a2e\:5225", "English" -> "Kind"|>,
  "Kanji" -> <|"Japanese" -> "\:6f22\:5b57", "English" -> "Kanji"|>,
  "Romaji" -> <|"Japanese" -> "\:30ed\:30fc\:30de\:5b57", "English" -> "Romaji"|>,
  "Group" -> <|"Japanese" -> "\:30b0\:30eb\:30fc\:30d7", "English" -> "Group"|>,
  "Weight" -> <|"Japanese" -> "\:91cd\:307f", "English" -> "Weight"|>,
  "MemberOf" -> <|"Japanese" -> "\:6240\:5c5e", "English" -> "MemberOf"|>,
  "Identifiers" -> <|"Japanese" -> "\:8b58\:5225\:5b50", "English" -> "Identifiers"|>,
  "TrustStatus" -> <|"Japanese" -> "\:4fe1\:983c", "English" -> "Trust"|>,
  "PrimaryEmail" -> <|"Japanese" -> "\:4e3b\:30e1\:30fc\:30eb", "English" -> "Primary email"|>,
  "LLMProfile" -> <|"Japanese" -> "LLM\:30d7\:30ed\:30d5\:30a3\:30fc\:30eb", "English" -> "LLM profile"|>,
  "None" -> <|"Japanese" -> "(\:306a\:3057)", "English" -> "(none)"|>,
  "Saved" -> <|"Japanese" -> "\:4fdd\:5b58\:3057\:307e\:3057\:305f", "English" -> "Saved"|>,
  "NoEntity" -> <|"Japanese" -> "\:5b9f\:4f53\:304c\:3042\:308a\:307e\:305b\:3093\:3002", "English" -> "No entities."|>,
  "EntityNotFound" -> <|"Japanese" -> "\:5b9f\:4f53\:304c\:898b\:3064\:304b\:308a\:307e\:305b\:3093\:3002", "English" -> "Entity not found."|>
|>;

iSVL[id_String] :=
  Module[{e = Lookup[$iSVUILabels, id, <||>], lang},
    lang = If[$Language === "Japanese", "Japanese", "English"];
    Lookup[e, lang, Lookup[e, "English", id]]];

(* 左寄せ・全文 Tooltip つきテキストセル (先頭が切れないように) *)
iSVUITextCell[s_] :=
  With[{t = If[StringQ[s], s, ToString[s]], ff = iSVUIFont[]},
    Item[Tooltip[Style[t, "Text", FontFamily -> ff], t], Alignment -> Left]];

(* Missing/Null は空文字に *)
iSVUIShow[x_] := Which[MissingQ[x] || x === Null, "", StringQ[x], x, True, ToString[x]];

(* カテゴリトークン -> 短い表示ラベル (列幅節約)。Tooltip にトークン名 *)
$iSVUICategoryShort = <|
  "InfoProvision" -> <|"Japanese" -> "情報", "English" -> "Info"|>,
  "AttendanceRequest" -> <|"Japanese" -> "出席", "English" -> "Attend"|>,
  "TaskRequest" -> <|"Japanese" -> "作業", "English" -> "Task"|>,
  "Confirmation" -> <|"Japanese" -> "確認", "English" -> "Confirm"|>,
  "Report" -> <|"Japanese" -> "報告", "English" -> "Report"|>,
  "Notice" -> <|"Japanese" -> "通知", "English" -> "Notice"|>,
  "Other" -> <|"Japanese" -> "他", "English" -> "Other"|>|>;

iSVUICategoryCell[c_, ff_] :=
  Module[{e, lang, lbl},
    If[! StringQ[c], Return[""]];
    e = Lookup[$iSVUICategoryShort, c, <||>];
    lang = If[$Language === "Japanese", "Japanese", "English"];
    lbl = Lookup[e, lang, Lookup[e, "English", c]];
    (* 件名セル (iSVUITextCell) と同一構造にする。Tooltip 内の素の Style[文字列] は
       Dataset セルで ShowStringCharacters が効き "通知" と引用符付きで表示される
       (ユーザー報告)。"Text" スタイル (ShowStringCharacters->False) + Item で抑止。
       Tooltip にはカテゴリトークン名を出す。 *)
    Item[Tooltip[Style[lbl, "Text", FontFamily -> ff], c], Alignment -> Left]];

(* 〆切 ISO 文字列 -> "2026/06/19 17:00" / "2026/06/19" のコンパクト表示 *)
iSVUIFormatDeadline[dl_] :=
  If[! StringQ[dl], "",
    StringReplace[If[StringLength[dl] >= 16, StringTake[dl, 16], dl],
      {"-" -> "/", "T" -> " "}]];

Options[SourceVaultMailView] = Options[SourceVault`SourceVaultSearchMailSnapshots];
SourceVaultMailView[query_String : "", opts : OptionsPattern[]] :=
  Module[{snaps, rows, ff = iSVUIFont[]},
    snaps = SourceVault`SourceVaultSearchMailSnapshots[query, opts];
    (* アクションは maildb 同様に列を分ける (1 セルに詰めると幅超過で "..." になる)。
       フォントは Dataset の BaseStyle が無いのでセルごとに適用する。 *)
    rows = Function[s,
       With[{r = Lookup[s, "RecordId", ""], md = s["MailMetadataPublic"], dv = s["Derived"]},
         <|"" -> Button["\:2709", SourceVaultMailShowBody[r],
              Appearance -> "Frameless", Method -> "Queued"],
           iSVL["Att"] -> iSVUIAttachMenu[s],
           iSVL["Reply"] -> Button["\:21a9", SourceVaultMailOpenReplyNotebook[r],
              Appearance -> "Frameless", Method -> "Queued"],
           iSVL["Date"] -> Style[iSVUIFormatDateJST[Lookup[md, "Date", Missing[]]], FontFamily -> ff],
           iSVL["Pri"] -> Style[iSVUINumCell[Lookup[dv, "Priority", Missing[]]], FontFamily -> ff],
           iSVL["Sec"] -> Style[iSVUINumCell[Lookup[dv, "PrivacyLevel", Missing[]]], FontFamily -> ff],
           iSVL["Cat"] -> iSVUICategoryCell[Lookup[dv, "Category", Missing[]], ff],
           iSVL["Deadline"] -> Style[iSVUIFormatDeadline[Lookup[dv, "Deadline", Missing[]]],
              FontFamily -> ff],
           iSVL["Subject"] -> iSVUITextCell[ToString@Lookup[md, "Subject", ""]],
           iSVL["From"] -> iSVUITextCell[iSVUIFromDisplayUI[s]],
           iSVL["Summary"] -> iSVUITextCell[With[{sm = Lookup[dv, "Summary", ""]},
              If[StringQ[sm], sm, ""]]]|>]] /@ snaps;
    If[rows === {}, Return[Style[iSVL["NoMail"], "Text"]]];
    (* PL >= 0.5 のメールを含む場合は Confidential 値として返す
       (代入先変数も秘密登録され、派生値のセルにも伝播する) *)
    iSVMDWrapConfidential[
      Pane[
        Dataset[rows,
          ItemSize -> {2, {3, 4, 3, 15, 3, 3, 5, 12, 28, 14, 40}},
          Alignment -> {Left, Center},
          (* MaxItems -> {最大行数, 最大列数}。第2要素を行数に縛ると
             少件数時に列が隠れるので All (全列・全行) にする。 *)
          MaxItems -> {$SourceVaultMailViewMaxRows, All}],
        ImageSize -> Full],
      snaps]];

(* From 表示 (AddressBook 解決) -- maildb の SummaryRow と同じ規則 *)
iSVUIFromDisplayUI[s_] :=
  Module[{fc, c},
    fc = Lookup[s["AddressBookRefs"], "FromContact", Missing[]];
    If[StringQ[fc],
      c = Quiet@Check[SourceVault`SourceVaultAddressBookGetContact[fc], Missing[]];
      If[AssociationQ[c] && StringQ[Lookup[c, "DisplayName", Null]], Return[c["DisplayName"]]]];
    With[{raw = Lookup[s["MailMetadataPublic"], "From", Missing[]]},
      If[StringQ[raw], raw, Missing["Unknown"]]]];

(* ---- アドレス帳 表示 ---- *)
iSVABPrimaryEmailUI[c_Association] :=
  Module[{ems = Lookup[c, "Emails", {}], hit},
    If[! ListQ[ems] || ems === {}, Return[""]];
    hit = SelectFirst[ems, TrueQ[Lookup[#, "Primary", False]] &, First[ems]];
    ToString@Lookup[hit, "Address", ""]];

iSVABListStr[x_] := If[ListQ[x], StringRiffle[ToString /@ x, ", "], ToString[x]];

SourceVaultAddressBookView[] :=
  Module[{contacts, ff = iSVUIFont[], rows},
    contacts = SourceVault`SourceVaultAddressBookListContacts[];
    rows = Function[c,
       With[{nm = Lookup[c, "Names", <||>], ap = Lookup[c, "ContactAccessProfile", <||>]},
         <|iSVL["Uid"] -> Style[ToString@Lookup[c, "Uid", ""], FontFamily -> ff],
           iSVL["Name"] -> iSVUITextCell[ToString@Lookup[c, "DisplayName", ""]],
           iSVL["Kana"] -> iSVUITextCell[ToString@Lookup[nm, "Kana", ""]],
           iSVL["Email"] -> iSVUITextCell[iSVABPrimaryEmailUI[c]],
           iSVL["Category"] -> iSVUITextCell[iSVABListStr[Lookup[c, "Categories", {}]]],
           iSVL["Trust"] -> Style[ToString@Lookup[ap, "TrustStatus", ""], FontFamily -> ff],
           iSVL["PL"] -> Style[ToString@Lookup[ap, "MaxPlaintextPL", ""], FontFamily -> ff],
           iSVL["Tags"] -> iSVUITextCell[iSVABListStr[Lookup[ap, "AccessTags", {}]]]|>]] /@ contacts;
    If[rows === {}, Return[Style[iSVL["NoContact"], "Text"]]];
    Pane[
      Dataset[rows,
        ItemSize -> {2, {4, 16, 14, 28, 14, 10, 5, 22}},
        Alignment -> {Left, Center},
        MaxItems -> {$SourceVaultMailViewMaxRows, All}],
      ImageSize -> Full]];

(* ---- 識別子 -> 実体 リンク編集 UI (新規作成 / 既存マージ) ---- *)
iSVUIEntityMenuItems[id_String, ents_List] :=
  (With[{ename = Lookup[#, "DisplayName", #["EntityId"]], eid = #["EntityId"],
       euid = Lookup[#, "EntityUid", ""]},
     Row[{ename, "  #", ToString[euid]}] :>
       (SourceVault`SourceVaultLinkIdentifierToEntity[id, eid])] & /@ ents);

Options[SourceVaultIdentityLinkUI] = {"ShowLinked" -> False, "Limit" -> 200};
SourceVaultIdentityLinkUI[OptionsPattern[]] :=
  Module[{showLinked = TrueQ[OptionValue["ShowLinked"]], lim = OptionValue["Limit"]},
    DynamicModule[{refresh = 0},
      Dynamic[refresh;
       Module[{idfs, ents, ff = iSVUIFont[], rows},
        iSVUIIdentityEnsureLoaded[];
        idfs = SourceVault`SourceVaultListIdentifiers[];
        If[! showLinked,
          idfs = Select[idfs, ! StringQ[Lookup[#, "EntityRef", Missing[]]] &]];
        idfs = Take[SortBy[idfs, -Lookup[#, "Count", 0] &], UpTo[lim]];
        ents = SourceVault`SourceVaultListEntities[];
        If[idfs === {}, Style[iSVL["NoUnlinked"], "Text"],
         rows = Function[idf,
            With[{id = idf["IdentifierId"]},
             (* アクションは別列に (1 セルに詰めると幅超過で "..." になる) *)
             <|"" -> Button[iSVL["New"],
                  SourceVault`SourceVaultIdentifierCreateEntity[id]; refresh++,
                  Method -> "Queued"],
               iSVL["Merge"] -> ActionMenu[iSVL["Merge"],
                  Append[iSVUIEntityMenuItems[id, ents] /.
                     (lab_ :> act_) :> (lab :> (act; refresh++)),
                    "\:2014"],
                  Appearance -> "Popup"],
               iSVL["Value"] -> iSVUITextCell[Lookup[idf, "Value", ""]],
               iSVL["ObservedNames"] -> iSVUITextCell[iSVABListStr[Lookup[idf, "ObservedNames", {}]]],
               iSVL["Count"] -> Style[ToString@Lookup[idf, "Count", 0], FontFamily -> ff],
               iSVL["Entity"] -> iSVUITextCell[
                  With[{er = Lookup[idf, "EntityRef", Missing[]]},
                    If[StringQ[er],
                      ToString@SourceVault`SourceVaultResolveIdentifierDisplay[id],
                      iSVL["Unlinked"]]]]|>]] /@ idfs;
         Pane[
           Dataset[rows, ItemSize -> {2, {5, 7, 26, 24, 4, 20}},
             Alignment -> {Left, Center}, MaxItems -> {$SourceVaultMailViewMaxRows, All}],
           ImageSize -> Full]]]]]];

(* ---- 実体 一覧 + 編集 ---- *)
iSVUINames[e_] := With[{n = Lookup[e, "Names", <||>]}, If[AssociationQ[n], n, <||>]];

SourceVaultEntityView[] :=
  (iSVUIIdentityEnsureLoaded[];
  Module[{ents = SourceVault`SourceVaultListEntities[], ff = iSVUIFont[], rows},
    If[ents === {}, Return[Style[iSVL["NoEntity"], "Text"]]];
    rows = Function[e,
       With[{uid = Lookup[e, "EntityUid", ""]},
        <|"" -> Button[iSVL["Edit"],
             CreateDialog[SourceVaultEntityEditUI[uid],
               WindowTitle -> ToString@Lookup[e, "DisplayName", ""]],
             Method -> "Queued"],
          iSVL["Uid"] -> Style[ToString[uid], FontFamily -> ff],
          iSVL["Kind"] -> Style[ToString@Lookup[e, "Kind", ""], FontFamily -> ff],
          iSVL["Name"] -> iSVUITextCell[iSVUIShow[Lookup[e, "DisplayName", ""]]],
          iSVL["Kana"] -> iSVUITextCell[iSVUIShow[Lookup[iSVUINames[e], "Kana", ""]]],
          iSVL["Identifiers"] -> Style[ToString@Length[Lookup[e, "Identifiers", {}]], FontFamily -> ff],
          iSVL["Group"] -> iSVUITextCell[iSVUIShow[Lookup[e, "Group", ""]]],
          iSVL["Weight"] -> Style[iSVUIShow[Lookup[e, "PriorityWeight", ""]], FontFamily -> ff],
          iSVL["TrustStatus"] -> Style[iSVUIShow[Lookup[e, "TrustStatus", ""]], FontFamily -> ff]|>]] /@ ents;
    Pane[
      Dataset[rows, ItemSize -> {2, {5, 4, 8, 20, 14, 5, 12, 6, 9}},
        Alignment -> {Left, Center}, MaxItems -> {$SourceVaultMailViewMaxRows, All}],
      ImageSize -> Full]]);

iSVUIFormRow[lab_, ctrl_] := {Style[lab, Bold], ctrl};

SourceVaultEntityEditUI[idOrUid_] :=
  (iSVUIIdentityEnsureLoaded[];
  Module[{e = SourceVault`SourceVaultGetEntity[idOrUid], ff = iSVUIFont[], nm, cap, orgs, orgChoices},
    If[! AssociationQ[e], Return[Style[iSVL["EntityNotFound"], "Text"]]];
    nm = iSVUINames[e]; cap = Lookup[e, "ContactAccessProfile", <||>];
    orgs = Select[SourceVault`SourceVaultListEntities[], Lookup[#, "Kind", ""] === "Organization" &];
    orgChoices = Join[{"" -> iSVL["None"]},
       (#["EntityId"] -> ToString@Lookup[#, "DisplayName", #["EntityId"]] & /@ orgs)];
    DynamicModule[{
       dn = iSVUIShow[Lookup[e, "DisplayName", ""]],
       kind = ToString@Lookup[e, "Kind", "Person"],
       kanji = iSVUIShow[Lookup[nm, "Kanji", ""]],
       romaji = iSVUIShow[Lookup[nm, "Romaji", ""]],
       kana = iSVUIShow[Lookup[nm, "Kana", ""]],
       cats = iSVABListStr[Lookup[e, "Categories", {}]],
       grp = iSVUIShow[Lookup[e, "Group", ""]],
       wt = iSVUIShow[Lookup[e, "PriorityWeight", ""]],
       memberOf = With[{m = Lookup[e, "MemberOf", Missing[]]}, If[StringQ[m], m, ""]],
       trust = ToString@Lookup[cap, "TrustStatus", Lookup[e, "TrustStatus", "Observed"]],
       primaryEmail = iSVUIShow[Lookup[e, "PrimaryEmail", ""]],
       llmProfile = iSVUIShow[Lookup[e, "LLMProfile", ""]],
       msg = ""},
     Panel[Column[{
        Style[iSVL["Edit"] <> "  #" <> ToString@Lookup[e, "EntityUid", ""], Bold, 14],
        Grid[{
          iSVUIFormRow[iSVL["Name"], InputField[Dynamic[dn], String, FieldSize -> 28]],
          iSVUIFormRow[iSVL["Kind"], PopupMenu[Dynamic[kind],
             {"Person", "Organization", "Bot", "MailingList", "Service"}]],
          iSVUIFormRow[iSVL["Kanji"], InputField[Dynamic[kanji], String, FieldSize -> 20]],
          iSVUIFormRow[iSVL["Romaji"], InputField[Dynamic[romaji], String, FieldSize -> 20]],
          iSVUIFormRow[iSVL["Kana"], InputField[Dynamic[kana], String, FieldSize -> 20]],
          iSVUIFormRow[iSVL["Category"], InputField[Dynamic[cats], String, FieldSize -> 28]],
          iSVUIFormRow[iSVL["Group"], InputField[Dynamic[grp], String, FieldSize -> 20]],
          iSVUIFormRow[iSVL["Weight"], InputField[Dynamic[wt], String, FieldSize -> 8]],
          iSVUIFormRow[iSVL["MemberOf"], PopupMenu[Dynamic[memberOf], orgChoices]],
          iSVUIFormRow[iSVL["TrustStatus"], PopupMenu[Dynamic[trust],
             {"Observed", "Verified", "Trusted", "Blocked"}]],
          iSVUIFormRow[iSVL["PrimaryEmail"], InputField[Dynamic[primaryEmail], String, FieldSize -> 28]],
          iSVUIFormRow[iSVL["LLMProfile"], InputField[Dynamic[llmProfile], String, FieldSize -> {40, 3}]]},
         Alignment -> {Left, Center}, Spacings -> {1, 0.8}],
        Row[{
          Button[iSVL["Save"],
            SourceVault`SourceVaultUpdateEntity[e["EntityId"],
              <|"DisplayName" -> If[StringTrim[dn] === "", Missing["NotSet"], dn],
                "Kind" -> kind,
                "Names" -> Association[
                   If[StringTrim[kanji] === "", Nothing, "Kanji" -> StringTrim[kanji]],
                   If[StringTrim[romaji] === "", Nothing, "Romaji" -> StringTrim[romaji]],
                   If[StringTrim[kana] === "", Nothing, "Kana" -> StringTrim[kana]]],
                "Categories" -> Select[StringTrim /@ StringSplit[cats, ","], # =!= "" &],
                "Group" -> If[StringTrim[grp] === "", Missing["NotSet"], StringTrim[grp]],
                "PriorityWeight" -> With[{v = Quiet@Check[ToExpression[StringTrim[wt]], $Failed]},
                   If[NumericQ[v], v, Missing["NotSet"]]],
                "MemberOf" -> If[memberOf === "" || memberOf === Null, Missing["NotSet"], memberOf],
                "PrimaryEmail" -> If[StringTrim[primaryEmail] === "", Missing["NotSet"], ToLowerCase[StringTrim[primaryEmail]]],
                "LLMProfile" -> If[StringTrim[llmProfile] === "", Missing["NotSet"], StringTrim[llmProfile]],
                "TrustStatus" -> trust,
                "ContactAccessProfile" -> Join[If[AssociationQ[cap], cap, <||>],
                   <|"TrustStatus" -> trust|>]|>];
            msg = iSVL["Saved"], Method -> "Queued"],
          Spacer[10], Style[Dynamic[msg], Darker[Green]]}]},
       Spacings -> 1], BaseStyle -> {FontFamily -> ff}]]]);

(* ════════════════════════════════════════════════════════
   メール View 出力セルの自動機密マーク (2026-06)
   ────────────────────────────────────────────────────────
   方針: メール View 表は「生データ」なので、表示メールの最大 Derived.PrivacyLevel
   をそのセルの PrivacyLevel として機密マークする。NBMakeContextPacket の閾値
   (クラウド 0.5 / ローカル lmstudio 1.0) と組み合わさり、クラウド評価では
   スキーマのみ、ローカル評価では全文が送られる。公開メールのみ (最大PL<=0.5)
   の表はマークしない (クラウドでも全文可)。
   依存方向 (SourceVault -> NBAccess) を守り、フックは SourceVault 側から
   NBAccess`NBMakeContextPacket に「再入ガード付きの高優先 DownValue 追加」で
   装着する (本体定義・Options は壊さない)。
   ════════════════════════════════════════════════════════ *)

(* 入力テキストがメール View 系呼び出しを含むか *)
iSVMailViewInputQ[text_String] :=
  StringContainsQ[text,
    RegularExpression["SourceVaultMail(View|Dataset|SearchSummary)\\s*\\["]];
iSVMailViewInputQ[_] := False;

(* 機密判定用 PL アクセサ: フェイルセーフで PrivacyLevel 欠落は 1.0 (秘匿) 扱い。
   (検索フィルタ用 iSVMDPrivacy は欠落を 0 にするので機密判定には使わない) *)
iSVMailProbePL[s_] :=
  With[{p = Quiet@Check[Lookup[Lookup[s, "Derived", <||>], "PrivacyLevel", Missing[]], Missing[]]},
    If[NumericQ[p], N[p], 1.0]];

(* View/Dataset/SearchSummary を read-only に差し替えるプローブ: 同じクエリで
   メモリ内 snapshot を検索し、表示メールの最大 PrivacyLevel を返す。 *)
iSVMailPLProbe[query_String : "", opts : OptionsPattern[SourceVaultSearchMailSnapshots]] :=
  Module[{snaps},
    snaps = Quiet@Check[SourceVaultSearchMailSnapshots[query, opts], {}];
    If[ListQ[snaps] && Length[snaps] > 0, Max[iSVMailProbePL /@ snaps], 0.0]];
iSVMailPLProbe[___] := 1.0;

(* 入力テキストから View 呼び出しだけを抜き出してプローブ評価し、最大 PL を得る。
   入力全体は再評価しない (EnsureLoaded 等の副作用を再実行しない)。失敗時は安全側 1.0。 *)
iSVMailCellMaxPLFromText[text_String] :=
  Module[{held, vals},
    held = Quiet@Check[ToExpression[text, InputForm, HoldComplete], $Failed];
    If[held === $Failed, Return[1.0]];
    vals = Quiet@Check[
      Cases[held,
        HoldPattern[(SourceVaultMailView | SourceVaultMailDataset |
            SourceVaultMailSearchSummary)[a___]] :> iSVMailPLProbe[a],
        {0, Infinity}], {}];
    If[ListQ[vals] && Length[vals] > 0 && AllTrue[vals, NumericQ], Max[vals], 1.0]];
iSVMailCellMaxPLFromText[_] := 1.0;

(* ── Todo (ノートブック本体セルの生テキスト) 用 ──
   SourceVaultUpcomingSchedule / FormatNotebookList の表 (Summary 列) は
   クラウド安全に生成されるので対象外。SourceVaultFindTodos は TodoText に
   ノートブック本体の生セルを含むため、ソース NB が Public でない限り秘匿する。 *)
iSVTodoViewInputQ[text_String] :=
  StringContainsQ[text, RegularExpression["SourceVaultFindTodos\\s*\\["]];
iSVTodoViewInputQ[_] := False;

(* FindTodos を read-only 再実行し、ソース NB の Publishable を見る。
   全ソース NB が CloudPublishable===True (Public) なら 0.0 (クラウド可)、
   1 つでも非 Public (Unspecified/False) があれば 1.0 (秘匿)。 *)
iSVTodoPLProbe[opts___] :=
  Module[{cleanOpts, rows, paths},
    cleanOpts = DeleteCases[Flatten[{opts}], (("Format" | Format) -> _)];
    rows = Quiet@Check[
      SourceVaultFindTodos[Sequence @@ cleanOpts, "Format" -> False], $Failed];
    If[! ListQ[rows], Return[1.0]];
    If[rows === {}, Return[0.0]];
    paths = Select[
      DeleteDuplicates@Cases[rows,
        a_Association :> Lookup[a, "Path", Lookup[a, "OriginalPath", Missing[]]]],
      StringQ];
    If[paths =!= {} &&
       AllTrue[paths,
         (Quiet@Check[NBAccess`NBGetCloudPublishable[#], Missing[]] === True) &],
      0.0, 1.0]];
iSVTodoPLProbe[___] := 1.0;

iSVTodoCellMaxPLFromText[text_String] :=
  Module[{held, vals},
    held = Quiet@Check[ToExpression[text, InputForm, HoldComplete], $Failed];
    If[held === $Failed, Return[1.0]];
    vals = Quiet@Check[
      Cases[held, HoldPattern[SourceVaultFindTodos[a___]] :> iSVTodoPLProbe[a],
        {0, Infinity}], {}];
    If[ListQ[vals] && Length[vals] > 0 && AllTrue[vals, NumericQ], Max[vals], 1.0]];
iSVTodoCellMaxPLFromText[_] := 1.0;

(* 機密対象 View の仕様: {入力判定(text->bool), 最大PL算出(text->pl)} のリスト。
   メール (Derived.PrivacyLevel) と Todo 生テキスト (ソース NB の Publishable) を登録。
   サマリー/予定表 (SourceVaultUpcomingSchedule/FormatNotebookList) は
   クラウド安全に生成されるので登録しない。新たな「生セル内容を出す View」は
   ここに spec を追加するか、他アダプタのロード時に共有レジストリ
   $iSVConfidentialViewSpecRegistry (SourceVault`Private`、ロード順不問) へ
   {判定, PL算出} を登録する (SourceVault_eagle.wl が Eagle View 用 spec を登録)。 *)
iSVConfidentialViewSpecs[] := Join[
  {{iSVMailViewInputQ, iSVMailCellMaxPLFromText},
   {iSVTodoViewInputQ, iSVTodoCellMaxPLFromText}},
  If[ListQ[$iSVConfidentialViewSpecRegistry], $iSVConfidentialViewSpecRegistry, {}]];

(* 既存の機密/非機密タグ (True/False) があれば尊重し再マークしない。未判定のみ対象。 *)
iSVMailCellTaggedQ[nb_, i_] :=
  With[{t = Quiet@Check[NBAccess`NBGetConfidentialTag[nb, i], Missing[]]},
    t === True || t === False];

SourceVaultMarkConfidentialViewCells[nb_NotebookObject] :=
  Module[{n, lastIn = 0, lastInText = "", marked = {}},
    (* $iCellsCache は sticky (NBInvalidateCellsCache まで更新されない)。
       セッション中に古い件数でキャッシュされていると新規セルを見落とすため、
       走査前に必ず無効化して最新のセル一覧を読む。 *)
    Quiet@Check[NBAccess`NBInvalidateCellsCache[nb], Null];
    n = Quiet@Check[NBAccess`NBCellCount[nb], 0];
    If[! IntegerQ[n] || n <= 0, Return[{}]];
    Do[
      Module[{style = Quiet@Check[NBAccess`NBCellStyle[nb, i], ""]},
        Which[
          MemberQ[{"Input", "Code"}, style],
            lastIn = i;
            lastInText = Quiet@Check[NBAccess`NBCellReadInputText[nb, i], ""],
          style === "Output" && lastIn > 0 && StringQ[lastInText] &&
            ! iSVMailCellTaggedQ[nb, i] &&
            AnyTrue[iSVConfidentialViewSpecs[], First[#][lastInText] &],
            Module[{pls, pl},
              (* 複数 spec が同一セルに合致する場合 (メール+Eagle 混在等) は最大を採る *)
              pls = (Quiet@Check[Last[#][lastInText], 1.0] &) /@
                Select[iSVConfidentialViewSpecs[], First[#][lastInText] &];
              pl = If[pls =!= {} && AllTrue[pls, NumericQ], Max[pls], 1.0];
              (* 最大PL < 0.5 (公開メール / 全ソースNBが Public な Todo) はマークしない。
                 0.5 ちょうどは安全側でマークする (ユーザー指定: 0.5 以上=機密。
                 cloud gate の許可境界 PL<=0.5 より保守的) *)
              If[pl >= 0.5,
                Quiet@Check[NBAccess`NBMarkCellConfidential[nb, i, pl], Null];
                AppendTo[marked, <|"Cell" -> i, "PrivacyLevel" -> pl|>]]],
          True, Null]],
      {i, n}];
    marked];
SourceVaultMarkConfidentialViewCells[] :=
  With[{nb = Quiet@Check[EvaluationNotebook[], $Failed]},
    If[Head[nb] === NotebookObject, SourceVaultMarkConfidentialViewCells[nb], {}]];

(* 後方互換の別名 (Enable フックが呼ぶ名前も含む) *)
SourceVaultMailMarkViewCells[args___] := SourceVaultMarkConfidentialViewCells[args];

(* ── NBMakeContextPacket フック (既定で有効、再入ガード付き高優先 DownValue) ──
   装着判定はフラグでなく DownValues の構造検査で行う: NBAccess を再ロードすると
   NBMakeContextPacket の定義ごとフックが消えるため、フラグ頼みだと「装着済みの
   つもりで実は無防備」になる。Enable は不在なら常に再装着する (冪等)。 *)
If[! ValueQ[$iSVMailCtxHookInstalled], $iSVMailCtxHookInstalled = False];

iSVMailCtxHookPresentQ[] :=
  AnyTrue[DownValues[NBAccess`NBMakeContextPacket],
    ! FreeQ[#, $iSVMailCtxReentry] &];

SourceVaultMailEnableAutoConfidential[] :=
  (If[! iSVMailCtxHookPresentQ[],
     (* nb_NotebookObject は本体の nb_ より特化なので先に試される。
        $iSVMailCtxReentry で本体呼び出し時はこの規則を素通りさせる。 *)
     NBAccess`NBMakeContextPacket[nb_NotebookObject, spec_Association,
         o : OptionsPattern[]] /; ! TrueQ[$iSVMailCtxReentry] :=
       Block[{$iSVMailCtxReentry = True},
         Quiet@Check[SourceVaultMarkConfidentialViewCells[nb], Null];
         NBAccess`NBMakeContextPacket[nb, spec, o]]];
   $iSVMailCtxHookInstalled = True;
   <|"Status" -> "Enabled", "Hook" -> "NBMakeContextPacket"|>);

SourceVaultMailDisableAutoConfidential[] :=
  (DownValues[NBAccess`NBMakeContextPacket] =
     DeleteCases[DownValues[NBAccess`NBMakeContextPacket],
       _?(! FreeQ[#, $iSVMailCtxReentry] &)];
   $iSVMailCtxHookInstalled = False;
   <|"Status" -> "Disabled"|>);

(* ロード時に自動有効化 (ユーザー指摘: PL>0.5 のメールを含む View 出力は
   ClaudeEval の文脈構築前に必ず機密マークされていなければならない)。
   解除したい場合は SourceVaultMailDisableAutoConfidential[]。
   ヘッドレス/部分ロード環境では NBMakeContextPacket が呼ばれないだけで無害。 *)
SourceVaultMailEnableAutoConfidential[];

(* 機密生成ヘッド登録: 「返り値が機密たり得る」関数を NBAccess レジストリへ宣言。
   claudecode が (a) LLM 生成コード/応答を書き込んだセルの自動機密マーク、
   (b) CellEpilog の依存秘密判定 (snaps = SourceVaultSearch...[..] 等) に使う。
   関数本体の変更は不要 (View 3 関数の実 PL 判定 self-wrap は精密層として併存)。
   NBAccess full (NBAccess.wl) 未ロードの部分環境では skip。 *)
iSVMDRegisterConfidentialHeads[] :=
  Quiet@Check[
    If[Length[DownValues[NBAccess`NBRegisterConfidentialHead]] > 0,
      Scan[NBAccess`NBRegisterConfidentialHead[First[#], Last[#]] &,
        {{"SourceVaultMailGetBody", 1.0},
         {"SourceVaultMailSnapshotDecryptBody", 1.0},
         {"SourceVaultMailComposeReply", 1.0},
         {"SourceVaultSearchMailSnapshots", 0.85},
         {"SourceVaultMailSnapshotGet", 0.85},
         {"SourceVaultMailSnapshotList", 0.85},
         {"SourceVaultMailDerivedPending", 0.85},
         {"SourceVaultMailSummaryRow", 0.85},
         {"SourceVaultMailSearchSummary", 0.85},
         {"SourceVaultMailDataset", 0.85},
         {"SourceVaultMailView", 0.85},
         {"SourceVaultMailAttachments", 0.85}}]];
    Null, Null];
iSVMDRegisterConfidentialHeads[];

End[];
EndPackage[];
