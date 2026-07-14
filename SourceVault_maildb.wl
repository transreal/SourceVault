(* ::Package:: *)

(* ============================================================
   SourceVault_maildb.wl -- MailDB -> SourceVault snapshot adapter (Phase SV-E5)

   This file is encoded in UTF-8.
   Load order: ... -> SourceVault_encryptedstore.wl -> SourceVault_keys.wl
               -> SourceVault_addressbook.wl -> SourceVault_maildb.wl

   \:65e7 maildb (maildb_legacy.wl) \:306e\:6708\:6b21 .wl record \:3092 SourceVaultMailSnapshot \:306b\:6b63\:898f\:5316\:3059\:308b\:3002
   \:7b2c\:4e00\:30b9\:30e9\:30a4\:30b9:
     - RecordId / MessageIDToken \:306f SourceVault:mailid:mac:v1 \:306e keyed HMAC
     - body \:306f SourceVaultEncryptedPut \:3067\:6697\:53f7\:5316 (inline)\:3002PL \:306f fail-safe (\:65e2\:5b9a 0.85)
     - maildb privacy(0/1) \:306f provenance \:306e\:307f\:3002release/cloud \:5224\:5b9a\:306e\:771f\:5b9f\:6e90\:306b\:3057\:306a\:3044
     - From/To/Cc \:3092 AddressBook \:306b\:7167\:5408 (AddressBookRefs)
     - header (subject/from/to) \:306f\:65e2\:5b9a\:3067\:5e73\:6587 + token (Dropbox \:524d\:63d0)\:3002EncryptHeaders->True \:3067\:6697\:53f7\:5316
     - \:6dfb\:4ed8\:306f\:4ef6\:6570\:306e\:307f\:3002embedding \:306f\:672a\:53d6\:308a\:8fbc\:307f (provenance \:306b cloud \:7531\:6765\:30d5\:30e9\:30b0)
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultMailSnapshotFromMaildb::usage = "SourceVaultMailSnapshotFromMaildb[record_Association, mbox_String, opts] \:306f\:65e7 maildb record \:3092 SourceVaultMailSnapshot \:306b\:5909\:63db\:3059\:308b\:3002body \:306f\:6697\:53f7\:5316\:3001PL \:306f fail-safe\:3002";
SourceVaultImportMaildbFile::usage = "SourceVaultImportMaildbFile[file_String, mbox_String, opts] \:306f\:65e7 maildb \:6708\:6b21 .wl \:3092\:8aad\:307f\:3001\:5404 record \:3092 MailSnapshot \:306b\:5909\:63db\:3059\:308b\:3002Persist->True \:3067 snapshot store \:306b\:4fdd\:5b58\:3002";
SourceVaultMailSnapshotPut::usage = "SourceVaultMailSnapshotPut[snapshot, opts] \:306f snapshot \:3092 RecordId \:3092\:30ad\:30fc\:306b store \:3078\:4fdd\:5b58 (\:51aa\:7b49)\:3002";
SourceVaultBackfillMailBodies::usage = "SourceVaultBackfillMailBodies[opts] \:306f\:30ed\:30fc\:30c9\:6e08\:307f snapshot \:306e\:3046\:3061\:672c\:6587\:304c HTML \:306e\:65e7 record \:3092\:3001\:8aad\:3081\:308b\:5e73\:6587\:3078\:5909\:63db\:3057\:3066\:518d\:683c\:7d0d\:3059\:308b (\:539f\:6587\:306f BodyRaw \:306b\:6e29\:5b58\:3001MailMetadataPublic[\"BodyWasHTML\"]->True)\:3002ingest \:6642 HTML \:30c6\:30ad\:30b9\:30c8\:5316\:3092\:5c0e\:5165\:3059\:308b\:524d\:306e\:30e1\:30fc\:30eb\:7528 backfill\:3002opts: \"Limit\"(\:65e2\:5b9a Infinity), \"DryRun\"->True(\:4ef6\:6570\:3060\:3051\:6570\:3048\:66f8\:8fbc\:307e\:306a\:3044), \"Persist\"(\:65e2\:5b9a True), \"CheckpointEvery\"(\:65e2\:5b9a 20)\:3002\:8981\:7d04\:3082\:4f5c\:308a\:76f4\:3059\:306b\:306f\:5225\:9014 SourceVaultInferMailDerivedBatch[\"Refresh\"->...] \:3092\:5b9f\:884c\:3059\:308b\:3002";
SourceVaultMailSnapshotGet::usage = "SourceVaultMailSnapshotGet[recordId] \:306f\:4fdd\:5b58\:6e08\:307f snapshot \:3092\:8fd4\:3059\:3002";
SourceVaultMailSnapshotList::usage = "SourceVaultMailSnapshotList[] \:306f\:4fdd\:5b58\:6e08\:307f snapshot \:3092\:8fd4\:3059\:3002";
SourceVaultIdentityBackfillFromMail::usage = "SourceVaultIdentityBackfillFromMail[] \:306f\:73fe\:5728\:30ed\:30fc\:30c9\:6e08\:307f\:306e snapshot \:306e\:5e73\:6587 From/To/Cc \:3092\:8d70\:67fb\:3057\:3066\:8b58\:5225\:5b50(2\:5c64\:30a2\:30c9\:30ec\:30b9\:5e33)\:3092\:4e00\:62ec\:751f\:6210\:3059\:308b\:3002\:518d\:53d6\:8fbc\:4e0d\:8981\:3002\:30b9\:30b3\:30fc\:30d7\:306f\:5148\:306b SourceVaultMailEnsureLoaded \:3067\:6c7a\:3081\:308b\:3002";
SourceVaultSearchMailSnapshots::usage = "SourceVaultSearchMailSnapshots[query_String:\"\", opts] \:306f subject/summary \:90e8\:5206\:4e00\:81f4 + From / To / FromContact / MBox / DateFrom / DateTo / HasAttachment / Category / HasDeadline / DeadlineFrom / DeadlineTo \:3067\:691c\:7d22\:3057\:3001Newest(\:65e2\:5b9a True)\:3067\:65e5\:4ed8\:964d\:9806\:3001Limit \:3067\:4ef6\:6570\:5236\:9650\:3059\:308b\:3002Category \:306f $SourceVaultMailCategories \:306e\:30c8\:30fc\:30af\:30f3(\:65e5\:672c\:8a9e\:540d \"\:4f5c\:696d\:4f9d\:983c\" \:7b49\:3067\:3082\:53ef)\:3002DeadlineFrom/DeadlineTo \:306f\:3006\:5207\:65e5\:3092\:65e5\:5358\:4f4d\:5305\:542b\:3067\:7bc4\:56f2\:6307\:5b9a(\:4f8b: \:4eca\:9031\:3006\:5207\:306e\:4f5c\:696d\:4f9d\:983c = \"Category\"->\"TaskRequest\", \"DeadlineFrom\"->\:4eca\:65e5, \"DeadlineTo\"->\:9031\:672b)\:3002SortBy \:306f \"Date\"|\"Priority\"|\"PrivacyLevel\"|\"Deadline\"\:3002";
SourceVaultMailSummaryRow::usage = "SourceVaultMailSummaryRow[snapshot] \:306f\:4e00\:89a7\:8868\:793a\:7528\:306e\:4f4e\:6f0f\:6d29\:884c <|Date, From, Subject, Category, Deadline, Attach, MBox, RecordId, BodyEncrypted|> \:3092\:8fd4\:3059\:3002From \:306f AddressBook \:89e3\:6c7a\:6642\:306f\:8868\:793a\:540d\:3002Category \:306f\:4f9d\:983c\:30ab\:30c6\:30b4\:30ea\:30c8\:30fc\:30af\:30f3\:3001Deadline \:306f\:3006\:5207\:306e ISO \:6587\:5b57\:5217 (\:7121\:3051\:308c\:3070 Missing)\:3002";
$SourceVaultMailCategories::usage = "\:30e1\:30fc\:30eb\:6d3e\:751f\:30ab\:30c6\:30b4\:30ea\:306e\:8a9e\:5f59: InfoProvision=\:60c5\:5831\:63d0\:4f9b, AttendanceRequest=(\:4f1a\:8b70\:7b49\:3078\:306e)\:51fa\:5e2d\:4f9d\:983c, TaskRequest=\:4f5c\:696d\:30fb\:4ed5\:4e8b\:306e\:4f9d\:983c, Confirmation=\:78ba\:8a8d\:30fb\:627f\:8a8d\:4f9d\:983c, Report=\:5831\:544a, Notice=\:901a\:77e5\:30fb\:4e00\:6589\:914d\:4fe1, Other=\:305d\:306e\:4ed6\:3002Derived.Category \:3068\:691c\:7d22\:30aa\:30d7\:30b7\:30e7\:30f3 \"Category\" \:3067\:4f7f\:3046\:3002";
SourceVaultMailSearchSummary::usage = "SourceVaultMailSearchSummary[query_String:\"\", opts] \:306f\:691c\:7d22\:7d50\:679c\:3092 SummaryRow \:306e\:30ea\:30b9\:30c8(\:65b0\:7740\:9806\:30fbLimit \:9069\:7528)\:3067\:8fd4\:3059\:3002";
SourceVaultMailDataset::usage = "SourceVaultMailDataset[query_String:\"\", opts] \:306f\:691c\:7d22\:7d50\:679c\:3092\:7d20\:306e Dataset \:3067\:8fd4\:3059(\:5217\:30bd\:30fc\:30c8\:7528\:3001\:30dc\:30bf\:30f3\:7121\:3057)\:3002";
SourceVaultMailStoreSave::usage = "SourceVaultMailStoreSave[\"All\"->False] \:306f\:5909\:66f4\:306e\:3042\:3063\:305f\:6708\:6b21\:30b7\:30e3\:30fc\:30c9\:306e\:307f (All->True \:3067\:5168\:30b7\:30e3\:30fc\:30c9) \:3092 byte-exact \:4fdd\:5b58\:3059\:308b\:3002";
SourceVaultMailStoreLoad::usage = "SourceVaultMailStoreLoad[] \:306f\:5168\:30b7\:30e3\:30fc\:30c9\:3092\:8aad\:307f\:8fbc\:3080(\:91cd\:3044)\:3002\:901a\:5e38\:306f SourceVaultMailEnsureLoaded \:3067\:5fc5\:8981\:5206\:3060\:3051\:9045\:5ef6\:30ed\:30fc\:30c9\:3059\:308b\:3002";
SourceVaultMailAvailableShards::usage = "SourceVaultMailAvailableShards[mbox_:All] \:306f\:30c7\:30a3\:30b9\:30af\:4e0a\:306e\:30b7\:30e3\:30fc\:30c9 {mbox, yyyymm} \:306e\:4e00\:89a7\:3092\:30ed\:30fc\:30c9\:305b\:305a\:306b\:8fd4\:3059\:3002";
SourceVaultMailEnsureLoaded::usage = "SourceVaultMailEnsureLoaded[mbox_String, period_:Automatic] \:306f\:6307\:5b9a mbox \:306e\:671f\:9593\:5206\:30b7\:30e3\:30fc\:30c9\:3060\:3051\:3092\:30e1\:30e2\:30ea\:3078\:9045\:5ef6\:30ed\:30fc\:30c9\:3059\:308b\:3002period: \"YYYYMM\" | {from,to} | \"Latest\"/Automatic | n(\:76f4\:8fd1n\:6708) | All\:3002\:65e2\:30ed\:30fc\:30c9\:306f\:518d\:8aad\:8fbc\:3057\:306a\:3044\:3002";
SourceVaultMailLoadShard::usage = "SourceVaultMailLoadShard[\"mbox/yyyymm\"] \:306f1\:30b7\:30e3\:30fc\:30c9\:3092\:30ed\:30fc\:30c9\:3059\:308b\:3002";
SourceVaultMailUnloadAll::usage = "SourceVaultMailUnloadAll[] \:306f\:30e1\:30e2\:30ea\:4e0a\:306e snapshot \:3092\:89e3\:653e\:3059\:308b\:3002";
SourceVaultMailLoadedCount::usage = "SourceVaultMailLoadedCount[] \:306f\:73fe\:5728\:30e1\:30e2\:30ea\:306b\:3042\:308b snapshot \:6570\:3092\:8fd4\:3059\:3002";
SourceVaultMailStoreRoot::usage = "SourceVaultMailStoreRoot[] \:306f snapshot store \:306e\:30eb\:30fc\:30c8\:3092\:8fd4\:3059\:3002";
SourceVaultMailShardPath::usage = "SourceVaultMailShardPath[\"mbox/yyyymm\"] \:306f\:6708\:6b21\:30b7\:30e3\:30fc\:30c9\:306e\:30d1\:30b9\:3092\:8fd4\:3059\:3002";
SourceVaultMailMigrateToShards::usage = "SourceVaultMailMigrateToShards[] \:306f\:65e7\:5358\:4e00\:30d5\:30a1\:30a4\:30eb snapshots.svmail \:3092 mbox\[Times]\:6708\:306e\:30b7\:30e3\:30fc\:30c9\:306b\:79fb\:884c\:3057\:3001\:65e7\:30d5\:30a1\:30a4\:30eb\:3092 .bak \:306b\:3059\:308b\:3002";
SourceVaultMailStorePath::usage = "SourceVaultMailStorePath[] \:306f\:65e7\:5358\:4e00\:30d5\:30a1\:30a4\:30eb (\:79fb\:884c\:7528) \:306e\:30d1\:30b9\:3092\:8fd4\:3059\:3002";
$SourceVaultMailStoreRoot::usage = "mail snapshot store \:306e\:30eb\:30fc\:30c8 (\:65e2\:5b9a PrivateVault/mail/snapshots)\:3002\:30c6\:30b9\:30c8\:3067\:4e0a\:66f8\:304d\:53ef\:3002";
SourceVaultMailInteractionStats::usage = "SourceVaultMailInteractionStats[recordId] \:306f\:305d\:306e\:30e1\:30fc\:30eb\:306e\:64cd\:4f5c\:8a18\:9332 <|\"OpenCount\",\"LastOpened\",\"RepliedCount\",\"RepliedAt\"|> \:3092\:8fd4\:3059 (\:672c\:6587\:8868\:793a\:3067\:958b\:5c01\:56de\:6570\:3001\:8fd4\:4fe1\:9001\:4fe1\:3067\:8fd4\:4fe1\:6e08\:3092\:8a18\:9332)\:3002SourceVaultMailInteractionStats[] \:306f\:5168\:4ef6 (RecordId \:30ad\:30fc) \:3092\:8fd4\:3059\:3002\:8a18\:9332\:306f <storeRoot>/interaction.json (Dropbox \:5171\:6709)\:3002";
SourceVaultMailSearchIndex::usage = "SourceVaultMailSearchIndex[query_String:\"\", opts] \:306f\:30c7\:30a3\:30b9\:30af\:4e0a\:306e\:8efd\:91cf\:30e1\:30bf\:30c7\:30fc\:30bf\:7d22\:5f15 (\:5404 shard \:306e .svmailidx sidecar) \:3060\:3051\:3092\:8d70\:67fb\:3057\:3001snapshot \:672c\:4f53 (\:672c\:6587\:6697\:53f7\:6587) \:3092\:30e1\:30e2\:30ea\:3078\:30ed\:30fc\:30c9\:305b\:305a\:306b\:4f4e\:6f0f\:6d29\:30e1\:30bf/\:30b5\:30de\:30ea\:30fc\:884c (SummaryRow \:5f62 + Summary) \:3092\:8fd4\:3059\:3002opts \:306f SourceVaultSearchMailSnapshots \:3068\:540c\:3058 (To/Cc/FromContact \:7b49 index \:975e\:4fdd\:6301\:306e\:9805\:76ee\:306f\:7121\:8996)\:3002\:5e74\:5358\:4f4d\:306e\:5168\:30e1\:30fc\:30eb\:3092\:30ed\:30fc\:30c9\:3057\:7d9a\:3051\:306a\:304f\:3066\:3082\:691c\:7d22\:3067\:304d\:308b\:3002\:7d22\:5f15\:306f SourceVaultMailStoreSave \:6642\:306b\:81ea\:52d5\:66f4\:65b0\:3055\:308c\:3001\:65e2\:5b58\:30c7\:30fc\:30bf\:306b\:306f SourceVaultMailRebuildMetadataIndex \:3067\:4e00\:62ec\:751f\:6210\:3059\:308b\:3002";
SourceVaultMailRebuildMetadataIndex::usage = "SourceVaultMailRebuildMetadataIndex[mbox_:All] \:306f\:30c7\:30a3\:30b9\:30af\:4e0a\:306e\:5404 shard \:3092\:4e00\:6642\:7684\:306b\:8aad\:307f\:3001\:4f4e\:6f0f\:6d29\:30e1\:30bf\:30c7\:30fc\:30bf\:7d22\:5f15 sidecar (.svmailidx) \:3092\:518d\:751f\:6210\:3059\:308b ($iSVMDStore \:306f\:5909\:66f4\:3057\:306a\:3044)\:3002\:65e2\:5b58 .svmail \:304b\:3089\:7d22\:5f15\:3092\:521d\:56de\:69cb\:7bc9/\:518d\:69cb\:7bc9\:3059\:308b\:306e\:306b\:4f7f\:3046\:3002";
SourceVaultMailIndexedCount::usage = "SourceVaultMailIndexedCount[mbox_:All] \:306f\:30c7\:30a3\:30b9\:30af\:4e0a\:306e\:7d22\:5f15 sidecar \:306b\:542b\:307e\:308c\:308b\:884c\:6570 (\:7d22\:5f15\:6e08\:307f\:30e1\:30fc\:30eb\:6570) \:3092\:8fd4\:3059\:3002";
SourceVaultMailIndexGet::usage = "SourceVaultMailIndexGet[recordId_String] \:306f\:7d22\:5f15 sidecar \:304b\:3089\:8a72\:5f53 RecordId \:306e\:4f4e\:6f0f\:6d29\:30e1\:30bf/\:30b5\:30de\:30ea\:30fc\:884c\:30921\:4ef6\:8fd4\:3059 (snapshot \:672c\:4f53\:306f\:30ed\:30fc\:30c9\:3057\:306a\:3044)\:3002\:7121\:3051\:308c\:3070 Missing[\"NotFound\"]\:3002MCP \:306e\:5358\:4e00 URI \:89e3\:6c7a (sourcevault_get) \:7528\:3002";
SourceVaultMailSnapshotDecryptBody::usage = "SourceVaultMailSnapshotDecryptBody[snapshot] \:306f snapshot \:306e\:6697\:53f7\:5316 body \:3092\:5fa9\:53f7\:3057\:3066\:8fd4\:3059 (MAC \:691c\:8a3c\:7d4c\:7531)\:3002";
SourceVaultMailParseEmails::usage = "SourceVaultMailParseEmails[headerValue_String] \:306f\:30d8\:30c3\:30c0\:6587\:5b57\:5217\:304b\:3089\:30e1\:30fc\:30eb\:30a2\:30c9\:30ec\:30b9\:3092\:62bd\:51fa\:3059\:308b\:3002";
$SourceVaultDefaultImportedMailPL::usage = "import \:6642\:306e\:30e1\:30fc\:30eb\:672c\:6587 PL \:65e2\:5b9a (fail-safe, \:65e2\:5b9a 0.85)\:3002maildb privacy \:306f\:4fe1\:7528\:3057\:306a\:3044\:3002";
$SourceVaultMailPersonalPrivacyFloor::usage = "\:500b\:4eba\:5b9b\:30e1\:30fc\:30eb(\:30aa\:30fc\:30ca\:30fc\:304c\:76f4\:63a5\:306e To/Cc\:30fb\:975e bulk\:30fb\:5c11\:6570\:5b9b)\:306e\:6d3e\:751f PrivacyLevel \:4e0b\:9650 (\:65e2\:5b9a 0.6)\:3002LLM \:63a8\:8ad6\:304c\:500b\:4eba\:30e1\:30fc\:30eb\:306e privacy \:3092\:4e0b\:3052\:904e\:304e\:308b\:306e\:3092\:9632\:3050\:6c7a\:5b9a\:7684 defense-in-depth\:30020.0 \:3067\:7121\:52b9\:5316\:3002";

Begin["`Private`"];

If[! ValueQ[$SourceVaultDefaultImportedMailPL], $SourceVaultDefaultImportedMailPL = 0.85];
If[! ValueQ[$SourceVaultMailPersonalPrivacyFloor], $SourceVaultMailPersonalPrivacyFloor = 0.6];
$iSVMDPersonalRecipientMax = 4;  (* \:3053\:306e\:6570\:4ee5\:4e0b\:306e\:53d7\:4fe1\:8005=\:500b\:4eba/\:5c0f\:30b0\:30eb\:30fc\:30d7\:901a\:4fe1\:3068\:307f\:306a\:3059 *)

$iSVMDEmailPattern = RegularExpression["[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}"];

SourceVaultMailParseEmails[s_String] :=
  DeleteDuplicates[ToLowerCase /@ StringCases[s, $iSVMDEmailPattern]];
SourceVaultMailParseEmails[_] := {};

iSVMDFirstEmail[s_] := With[{es = SourceVaultMailParseEmails[s]}, If[es === {}, Missing["NoEmail"], First[es]]];

(* keyed HMAC token (mailid \:9375)\:3002\:9375\:304c\:7121\:3051\:308c\:3070 Missing\:3002 *)
iSVMDMailToken[str_String] :=
  Module[{k},
    k = Quiet@Check[NBAccess`NBKeyStatus[SourceVault`$SourceVaultDefaultMailIdentityHMACKeyRef], Missing[]];
    If[! AssociationQ[k], Return[Missing["NoKey"]]];
    Quiet@Check[
      NBAccess`NBMacWithKeyRef[SourceVault`$SourceVaultDefaultMailIdentityHMACKeyRef,
        StringToByteArray[str, "UTF-8"], "MailIdentityToken"], Missing["TokenFailed"]]];

(* RecordId = SHA256(canonical {mbox, MessageID})[:24]\:3002\:9375\:306b\:4f9d\:5b58\:3057\:306a\:3044\:6c7a\:5b9a\:7684 ID\:3002
   \:518d import / IMAP \:5897\:5206\:3067\:6052\:4e45\:7684\:306b\:51aa\:7b49 (\:9375\:306e\:6709\:7121\:30fb\:30ed\:30fc\:30c6\:30fc\:30b7\:30e7\:30f3\:3067\:5024\:304c\:5909\:308f\:3089\:306a\:3044)\:3002
   \:9023\:7d50\:9632\:6b62\:304c\:8981\:308b\:7b87\:6240\:306f\:5225\:9014\:30ad\:30fc\:4ed8\:304d MessageIDToken/FromToken/SubjectToken \:3092\:4f7f\:3046\:3002 *)
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

(* \:53d6\:8fbc\:6642\:306b From/To/Cc \:3092\:8b58\:5225\:5b50(2\:5c64\:30a2\:30c9\:30ec\:30b9\:5e33)\:3078\:81ea\:52d5\:767b\:9332\:3002identity \:672a\:30ed\:30fc\:30c9\:3067\:3082\:5b89\:5168\:3002 *)
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

(* ============================================================ *)
(* \:672c\:6587\:3092\:300c\:8aad\:3081\:308b\:5e73\:6587\:300d\:306b\:6b63\:898f\:5316\:3059\:308b\:30b3\:30a2\:30d8\:30eb\:30d1 (ingest / \:6d3e\:751f / \:8868\:793a / \:5f15\:7528 / \:7ffb\:8a33\:3067\:5171\:7528)
   (1) \:6539\:884c\:30b3\:30fc\:30c9\:3092 LF \:306b\:7d71\:4e00 (\r\n / \r \:7531\:6765\:306e\:4e8c\:91cd\:6539\:884c\:3092\:9632\:3050\:3002SMTP \:518d\:6b63\:898f\:5316\:3067
       \r \:304c\:6b8b\:308b\:3068 \r\r\n \:306b\:306a\:308a\:53d7\:4fe1\:5074\:3067\:7a7a\:884c\:304c\:5165\:308b \[HorizontalLine]\[HorizontalLine] \:65e7 maildb replyMail \:8e0f\:8972)\:3002
   (2) \:672c\:6587\:304c HTML \:306a\:3089\:30d7\:30ec\:30fc\:30f3\:30c6\:30ad\:30b9\:30c8\:3078\:5909\:63db (HTML \:30e1\:30fc\:30eb\:3092\:8aad\:3081\:308b\:3088\:3046\:306b)\:3002
   FE \:975e\:4f9d\:5b58\:306a\:306e\:3067 headless \:3067\:3082\:52d5\:304f\:3002 *)
(* ============================================================ *)
iSVUINormalizeNewlines[s_String] := StringReplace[s, {"\r\n" -> "\n", "\r" -> "\n"}];
iSVUINormalizeNewlines[_] := "";

iSVUILooksLikeHTML[s_String] :=
  StringContainsQ[s,
    {"<!doctype html", "<html", "<body", "<div", "<table", "<p>", "<br", "<span", "<meta "},
    IgnoreCase -> True];
iSVUILooksLikeHTML[_] := False;

(* HTML -> \:30d7\:30ec\:30fc\:30f3\:30c6\:30ad\:30b9\:30c8\:3002FE \:975e\:4f9d\:5b58\:306e ImportString \:3092\:512a\:5148\:3057\:3001\:5931\:6557\:6642\:306f\:30bf\:30b0\:9664\:53bb\:3067\:4ee3\:66ff\:3002 *)
iSVUIHtmlToText[s_String] :=
  Module[{t},
    t = TimeConstrained[
      Quiet@Check[ImportString[s, {"HTML", "Plaintext"}], $Failed], 15, $Failed];
    If[! StringQ[t] || StringTrim[t] === "",
      (* \:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af: script/style \:9664\:53bb -> \:30bf\:30b0\:9664\:53bb -> \:4e3b\:8981\:30a8\:30f3\:30c6\:30a3\:30c6\:30a3\:5fa9\:5143 *)
      t = StringReplace[s, {
        RegularExpression["(?is)<(script|style)[^>]*>.*?</\\1>"] -> " ",
        RegularExpression["(?s)<[^>]+>"] -> ""}];
      t = StringReplace[t, {
        "&nbsp;" -> " ", "&amp;" -> "&", "&lt;" -> "<", "&gt;" -> ">",
        "&quot;" -> "\"", "&#39;" -> "'", "&apos;" -> "'"}]];
    (* \:9023\:7d9a\:3059\:308b\:7a7a\:884c\:3092\:6700\:59271\:3064\:306b\:5727\:7e2e (HTML \:5909\:63db\:306f\:7a7a\:884c\:3092\:91cf\:7523\:3057\:304c\:3061) *)
    StringTrim@StringReplace[iSVUINormalizeNewlines[t], RegularExpression["\\n{3,}"] -> "\n\n"]];

(* \:8868\:793a\:30fb\:5f15\:7528\:30fb\:7ffb\:8a33\:30fb\:6d3e\:751f\:306b\:4f7f\:3046\:8aad\:3081\:308b\:672c\:6587 *)
iSVUIReadableBody[s_String] :=
  With[{t = iSVUINormalizeNewlines[s]},
    If[iSVUILooksLikeHTML[t], iSVUIHtmlToText[t], t]];
iSVUIReadableBody[_] := "";

Options[SourceVaultMailSnapshotFromMaildb] = {
  "PrivacyLevel" -> Automatic, "EncryptHeaders" -> False, "StoreBody" -> "Encrypted"};

SourceVaultMailSnapshotFromMaildb[record_Association, mbox_String, OptionsPattern[]] :=
  Module[{msgId, recId, pl, subject, from, to, cc, body, bodyStored, bodyWasHTML,
     encHeaders, bodyRef, headerEnc, mdPrivacy, mailDelivery, snapshot},
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

    (* \:672c\:6587\:3092 ingest \:6642\:306b\:300c\:8aad\:3081\:308b\:5e73\:6587\:300d\:3078\:3002HTML \:30e1\:30fc\:30eb\:306f\:3053\:3053\:3067\:30c6\:30ad\:30b9\:30c8\:5316\:3057\:3066\:683c\:7d0d\:3057\:3001
       \:8868\:793a\:30fb\:691c\:7d22\:30fb\:8981\:7d04\:3092\:30af\:30ea\:30fc\:30f3\:306b\:3059\:308b\:3002HTML \:3060\:3063\:305f\:5834\:5408\:306e\:307f\:539f\:6587\:3092 BodyRaw \:3068\:3057\:3066\:6e29\:5b58
       (URL \:7b49\:306e\:6b20\:843d\:306b\:5099\:3048\:308b)\:3002\:5e73\:6587\:306f LF \:6b63\:898f\:5316\:306e\:307f\:3002\:30d8\:30eb\:30d1\:672a\:30ed\:30fc\:30c9\:6642\:306f\:7d20\:901a\:308a\:3002 *)
    {bodyStored, bodyWasHTML} = If[
       StringQ[body] && Length[DownValues[iSVUIHtmlToText]] > 0,
       With[{norm = iSVUINormalizeNewlines[body]},
         If[iSVUILooksLikeHTML[norm], {iSVUIHtmlToText[body], True}, {norm, False}]],
       {body, False}];

    (* \:914d\:9001 feature (\[Section]8.1.1, \:914d\:7dda(b)): raw header \:3092 fetch \:6642\:306b parse \:3057 coarse feature \:3060\:3051\:4fdd\:5b58\:3002
       raw header \:672c\:4f53\:306f snapshot \:306b\:8f09\:305b\:306a\:3044 (privacy)\:3002mining \:672a\:30ed\:30fc\:30c9/raw header \:7121\:3057\:306f Missing\:3002 *)
    mailDelivery = With[{rh = Lookup[record, "rawheader", Missing[]]},
      If[StringQ[rh] && rh =!= "" &&
         Length[Names["SourceVault`SourceVaultMiningMailHeaderObservation"]] > 0 &&
         Length[DownValues[SourceVault`SourceVaultMiningMailHeaderObservation]] > 0,
        Quiet@Check[
          Lookup[SourceVault`SourceVaultMiningMailHeaderObservation[rh, "SourceID" -> recId],
            "SnapshotFeatures", Missing["NoFeatures"]], Missing["DeliveryParseFailed"]],
        Missing["NoRawHeader"]]];

    (* body: \:65e2\:5b9a\:3067\:6697\:53f7\:5316 (PL fail-safe)\:3002inline EncryptedPayload record\:3002
       Body=\:8aad\:3081\:308b\:5e73\:6587\:3002HTML \:3060\:3063\:305f\:5834\:5408\:306f\:539f\:6587\:3092 BodyRaw \:3068\:3057\:3066\:4f75\:305b\:3066\:6697\:53f7\:5316\:6e29\:5b58\:3002 *)
    bodyRef = If[StringQ[body] && OptionValue["StoreBody"] === "Encrypted",
       With[{put = SourceVault`SourceVaultEncryptedPut[
            If[TrueQ[bodyWasHTML],
              <|"Body" -> bodyStored, "BodyRaw" -> body|>,
              <|"Body" -> bodyStored|>],
            "PrivacyLevel" -> pl, "ContentType" -> "MailBody", "Persist" -> False,
            "SensitiveFields" -> If[TrueQ[bodyWasHTML], {"Body", "BodyRaw"}, {"Body"}]]},
         If[Lookup[put, "Status", ""] === "Stored", put["Record"], Missing["EncryptFailed"]]],
       If[StringQ[body], Missing["NotStored"], Missing["NoBody"]]];

    (* header: \:65e2\:5b9a\:5e73\:6587 + token\:3002EncryptHeaders->True \:3067\:6697\:53f7\:5316 record \:306b\:79fb\:3059\:3002 *)
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
      (* \:9001\:4fe1\:8005\:8a8d\:8a3c (\:4fe1\:983c authserv-id \:306e A-R \:306e\:307f\:63a1\:7528)\:3002legacy maildb \:306f A-R \:7121\:3057
         -> Source "Missing" -> sender-based loosening \:4e0d\:53ef\:3002 *)
      "SenderAuthentication" -> SourceVault`SourceVaultSenderAuthentication[record],
      (* \:914d\:9001 coarse feature (raw header \:306f\:8f09\:305b\:306a\:3044\:3001\[Section]8.1.1)\:3002delivery anomaly\[RightArrow]metacog conflict \:5165\:529b\:3002 *)
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
         "HasBody" -> StringQ[body],
         (* \:672c\:6587\:304c HTML \:7531\:6765\:304b (ingest \:6642\:306b\:30c6\:30ad\:30b9\:30c8\:5316\:3057\:305f)\:3002\:539f\:6587\:306f PayloadRefs.Body \:306e
            BodyRaw \:306b\:6697\:53f7\:5316\:6e29\:5b58\:3002format \:30d5\:30e9\:30b0\:306a\:306e\:3067\:975e\:6a5f\:5bc6 (\:516c\:958b\:30e1\:30bf)\:3002 *)
         "BodyWasHTML" -> TrueQ[bodyWasHTML]|>,
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
         (* \:30ab\:30c6\:30b4\:30ea ($SourceVaultMailCategories \:30c8\:30fc\:30af\:30f3) \:3068 \:3006\:5207 (ISO \:6587\:5b57\:5217\:3001\:30ed\:30fc\:30ab\:30eb\:6642\:523b\:610f\:56f3)\:3002
            \:65e7 maildb record \:306b\:306f\:7121\:3044\:306e\:3067 LLM \:6d3e\:751f (iSVApplyDerived) \:3067\:57cb\:307e\:308b\:3002 *)
         "Category" -> Missing["NotGenerated"],
         "Deadline" -> Missing["NotGenerated"],
         "Priority" -> Lookup[record, "priority", Missing["NotGenerated"]],
         (* \:6d3e\:751f\:30d5\:30a3\:30fc\:30eb\:30c9 (PL/Priority/Summary) \:304c LLM \:7b49\:3067\:78ba\:5b9a\:6e08\:307f\:304b\:3002
            \:672a\:78ba\:5b9a (\:65b0\:898f IMAP \:53d6\:8fbc\:3067\:672a\:51e6\:7406) \:306f "Pending" -> \:5f8c\:304b\:3089\:5897\:5206\:30d0\:30c3\:30c1\:3067\:51e6\:7406\:3002 *)
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
   \:6c38\:7d9a\:5316\:306f mbox x \:6708\:3067\:30b7\:30e3\:30fc\:30c9\:5206\:5272: <root>/<mbox>/<yyyymm>.svmail
   \:65b0\:7740\:30e1\:30fc\:30eb\:8ffd\:52a0\:306f\:305d\:306e\:6708\:306e\:30b7\:30e3\:30fc\:30c9(\:5c0f)\:3060\:3051\:66f8\:304d\:63db\:3048 -> Dropbox \:306f\:5909\:66f4\:5206\:306e\:307f\:540c\:671f\:3002
   \:5358\:4e00\:30d5\:30a1\:30a4\:30eb\:3060\:3068 1 \:901a\:8ffd\:52a0\:3067\:5168\:4f53(\:6570\:767eMB)\:518d\:540c\:671f\:306b\:306a\:308a\:7834\:7dbb\:3059\:308b\:3002 *)
If[! AssociationQ[$iSVMDStore], $iSVMDStore = <||>];          (* RecordId -> snapshot *)
If[! AssociationQ[$iSVMDShardMembers], $iSVMDShardMembers = <||>]; (* "mbox/yyyymm" -> {RecordId..} *)
If[! AssociationQ[$iSVMDDirtyShards], $iSVMDDirtyShards = <||>];   (* "mbox/yyyymm" -> True *)

(* shard key = mbox + \:5e74\:6708 (mail Date \:306e UTC ISO \:304b\:3089)\:3002Date \:4e0d\:660e\:306f "unknown"\:3002 *)
iSVMDShardKey[snapshot_] :=
  Module[{mbox, d, ym},
    mbox = Quiet@Check[snapshot["MailSource", "MBox"], "unknown"];
    If[! StringQ[mbox], mbox = "unknown"];
    d = Quiet@Check[snapshot["MailMetadataPublic", "Date"], Missing[]];
    ym = If[StringQ[d] && StringLength[d] >= 7,
       StringTake[d, 4] <> StringTake[d, {6, 7}], "unknown"];
    mbox <> "/" <> ym];

(* IMAP \:306e\:751f\:30e1\:30c3\:30bb\:30fc\:30b8 (\:30ad\:30fc "date") \:304b\:3089\:3001\:305d\:308c\:304c\:683c\:7d0d\:3055\:308c\:308b shard key \:3092\:3001
   \:5b9f\:969b\:306e snapshot ([[iSVMDShardKey]]) \:3068\:540c\:4e00\:30ed\:30b8\:30c3\:30af\:3067\:7b97\:51fa\:3059\:308b\:3002
   fetch \:524d\:306b\:5bfe\:8c61\:6708\:30b7\:30e3\:30fc\:30c9\:3092\:5148\:8aad\:307f\:3059\:308b\:305f\:3081\:306b\:4f7f\:3046 (Date \:6b63\:898f\:5316\:306f iSVMDToUTC \:3067\:4e00\:81f4)\:3002 *)
iSVMDShardKeyForMsg[mbox_String, m_Association] :=
  iSVMDShardKey[<|
     "MailSource" -> <|"MBox" -> mbox|>,
     "MailMetadataPublic" -> <|
        "Date" -> iSVMDToUTC[Lookup[m, "date", Missing["Unknown"]]]|>|>];

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

(* DateObject / \:65e5\:4ed8\:6587\:5b57\:5217 / {y,m,d} / Automatic \:3092 {\:5e74,\:6708,\:65e5} \:6574\:6570\:30ea\:30b9\:30c8\:306b\:6b63\:898f\:5316\:3059\:308b\:3002
   \:30d5\:30a3\:30eb\:30bf\:5883\:754c (\:30e6\:30fc\:30b6\:6307\:5b9a\:3002\:30ed\:30fc\:30ab\:30eb\:610f\:56f3) \:7528\:3002\:5931\:6557\:6642\:306f $Failed\:3001Automatic \:306f\:305d\:306e\:307e\:307e\:8fd4\:3059\:3002 *)
iSVMDDayListOf[Automatic] := Automatic;
iSVMDDayListOf[x_] := Quiet@Check[DateValue[x, {"Year", "Month", "Day"}], $Failed];

(* \:30e1\:30fc\:30eb\:4fdd\:5b58\:65e5\:6642 (UTC ISO8601 \:6587\:5b57\:5217) \:3092\:30ed\:30fc\:30ab\:30eb TZ ($TimeZone) \:306e {\:5e74,\:6708,\:65e5} \:306b\:5909\:63db\:3059\:308b\:3002
   \:4fdd\:5b58\:306f UTC \:3060\:304c\:8868\:793a\:30fb\:30e6\:30fc\:30b6\:306e\:30d5\:30a3\:30eb\:30bf\:306f\:30ed\:30fc\:30ab\:30eb\:306a\:306e\:3067\:3001\:65e9\:671d\:30e1\:30fc\:30eb\:304c UTC \:3067\:306f\:524d\:65e5\:6271\:3044\:306b
   \:306a\:3063\:3066\:53d6\:308a\:3053\:307c\:3055\:308c\:308b\:306e\:3092\:9632\:3050\:3002\:5931\:6557\:6642\:306f\:7d20\:306e DateValue \:306b\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3002 *)
iSVMDMailDay[d_] :=
  Module[{do, r},
    do = Quiet@Check[DateObject[d], $Failed];
    r = If[Head[do] === DateObject,
      Quiet@Check[
        DateValue[TimeZoneConvert[do, $TimeZone], {"Year", "Month", "Day"}], $Failed],
      $Failed];
    If[MatchQ[r, {_Integer, _Integer, _Integer}], r, iSVMDDayListOf[d]]];

(* \:65e5\:4ed8\:30d5\:30a3\:30eb\:30bf\:3002fromDay/toDay \:306f iSVMDDayListOf \:3067\:6b63\:898f\:5316\:6e08\:307f\:306e {y,m,d} \:307e\:305f\:306f Automatic\:3002
   \:65e5\:5358\:4f4d\:306e\:5305\:542b\:6bd4\:8f03\:306a\:306e\:3067 DateFrom=DateTo=DateObject[{2026,1,10}] \:3067\:3082\:5f53\:65e5\:306e\:30e1\:30fc\:30eb\:304c\:4e00\:81f4\:3059\:308b\:3002
   \:65e7\:5b9f\:88c5\:306f DateObject \:3068 ISO \:6587\:5b57\:5217\:3092 OrderedQ \:3067\:76f4\:63a5\:6bd4\:8f03\:3057\:3001\:578b\:4e0d\:4e00\:81f4\:3067\:5e38\:306b\:7a7a\:306b\:306a\:3063\:3066\:3044\:305f
   (\:3055\:3089\:306b DateTo \:3092\:65e5\:4ed8\:306e\:307f\:6307\:5b9a\:3059\:308b\:3068\:5f53\:65e5\:306e\:6642\:523b\:4ed8\:304d\:30e1\:30fc\:30eb\:304c\:9664\:5916\:3055\:308c\:308b\:5305\:542b\:30d0\:30b0\:3082\:3042\:3063\:305f)\:3002 *)
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

(* ---- \:6d3e\:751f\:30ab\:30c6\:30b4\:30ea\:8a9e\:5f59 (schema \:30ad\:30fc\:306f\:82f1\:8a9e\:56fa\:5b9a\:3001\:65e5\:672c\:8a9e\:306f\:8868\:793a\:30fb\:5165\:529b\:540c\:7fa9\:8a9e) ---- *)
$SourceVaultMailCategories = {"InfoProvision", "AttendanceRequest", "TaskRequest",
   "Confirmation", "Report", "Notice", "Other"};

(* \:5165\:529b (LLM \:51fa\:529b\:3084\:691c\:7d22\:30aa\:30d7\:30b7\:30e7\:30f3) \:3092\:30c8\:30fc\:30af\:30f3\:3078\:6b63\:898f\:5316\:3059\:308b\:3002\:65e5\:672c\:8a9e\:540c\:7fa9\:8a9e\:3082\:53d7\:3051\:308b\:3002
   \:672a\:77e5\:306e\:5024\:306f Missing["UnknownCategory"]\:3002 *)
$iSVMDCategorySynonyms = <|
   "\:60c5\:5831\:63d0\:4f9b" -> "InfoProvision", "\:60c5\:5831" -> "InfoProvision", "\:6848\:5185" -> "InfoProvision",
   "\:51fa\:5e2d\:4f9d\:983c" -> "AttendanceRequest", "\:4f1a\:8b70\:51fa\:5e2d\:4f9d\:983c" -> "AttendanceRequest",
   "\:51fa\:5e2d" -> "AttendanceRequest", "\:65e5\:7a0b\:8abf\:6574" -> "AttendanceRequest",
   "\:4f5c\:696d\:4f9d\:983c" -> "TaskRequest", "\:4ed5\:4e8b\:4f9d\:983c" -> "TaskRequest", "\:4ed5\:4e8b\:306e\:4f9d\:983c" -> "TaskRequest",
   "\:4f5c\:696d\:306e\:4f9d\:983c" -> "TaskRequest", "\:4f9d\:983c" -> "TaskRequest", "\:4f5c\:696d" -> "TaskRequest",
   "\:78ba\:8a8d" -> "Confirmation", "\:627f\:8a8d" -> "Confirmation", "\:78ba\:8a8d\:4f9d\:983c" -> "Confirmation",
   "\:5831\:544a" -> "Report", "\:901a\:77e5" -> "Notice", "\:4e00\:6589\:914d\:4fe1" -> "Notice", "\:5e83\:544a" -> "Notice",
   "\:305d\:306e\:4ed6" -> "Other"|>;

iSVMDNormalizeCategory[s_String] :=
  Module[{t = StringTrim[s], hit},
    If[t === "", Return[Missing["UnknownCategory"]]];
    hit = SelectFirst[$SourceVaultMailCategories,
       StringMatchQ[t, #, IgnoreCase -> True] &, Missing[]];
    If[StringQ[hit], Return[hit]];
    Lookup[$iSVMDCategorySynonyms, t, Missing["UnknownCategory"]]];
iSVMDNormalizeCategory[_] := Missing["UnknownCategory"];

(* \:3006\:5207\:6587\:5b57\:5217\:306e\:6b63\:898f\:5316: "2026-06-19" / "2026-06-19 17:00" / "2026\:5e746\:670819\:65e5 17\:6642" \:7b49\:3092
   ISO \:98a8 "YYYY-MM-DD" \:307e\:305f\:306f "YYYY-MM-DDTHH:MM:00" (\:30ed\:30fc\:30ab\:30eb\:6642\:523b\:610f\:56f3, TZ \:306a\:3057) \:306b\:3002
   \:306a\:3057/\:89e3\:91c8\:4e0d\:80fd\:306f Missing\:3002 *)
iSVMDNormalizeDeadline[s_String] :=
  Module[{t = StringTrim[s], m, y, mo, d, h, mi, pad},
    If[t === "" || StringMatchQ[t, "none" | "null" | "n/a" | "-", IgnoreCase -> True] ||
       StringContainsQ[t, "\:306a\:3057"] || StringContainsQ[t, "\:7121\:3057"],
      Return[Missing["None"]]];
    m = StringCases[t,
       RegularExpression["(\\d{4})[-/](\\d{1,2})[-/](\\d{1,2})(?:[T\\s]+(\\d{1,2}):(\\d{2}))?"] :>
         {"$1", "$2", "$3", "$4", "$5"}];
    If[m === {},
      m = StringCases[t,
         RegularExpression["(\\d{4})\:5e74\\s*(\\d{1,2})\:6708\\s*(\\d{1,2})\:65e5(?:\\s*(\\d{1,2})[:\:6642](\\d{1,2})?\:5206?)?"] :>
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

(* \:3006\:5207\:306e\:65e5\:4ed8\:7bc4\:56f2 (\:65e5\:5358\:4f4d\:5305\:542b)\:3002\:3006\:5207\:306f\:30ed\:30fc\:30ab\:30eb\:6642\:523b\:610f\:56f3\:306e\:7d20\:306e ISO \:6587\:5b57\:5217\:306a\:306e\:3067
   \:30e1\:30fc\:30eb Date \:3068\:9055\:3044 TZ \:5909\:63db\:3057\:306a\:3044\:3002\:3006\:5207\:306a\:3057\:306f\:7bc4\:56f2\:6307\:5b9a\:6642\:306b\:4e0d\:4e00\:81f4\:3002 *)
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
  (* \:3006\:5207\:306a\:3057\:306f\:6607\:9806\:3067\:672b\:5c3e\:306b\:6765\:308b\:3088\:3046\:756a\:5175\:5024 *)
  "Deadline", With[{dl = iSVMDDeadlineOf[s]}, If[StringQ[dl], dl, "9999-12-31T23:59:59"]],
  _, iSVMDSnapDate[s]];

SourceVaultSearchMailSnapshots[query_String : "", OptionsPattern[]] :=
  Module[{q, fc, fr, toQ, mb, df, dt, ha, cat, hd, ddf, ddt, hits, lim,
      minP, maxP, minPr, maxPr, by, ord},
    q = StringTrim[query]; fc = OptionValue["FromContact"]; fr = OptionValue["From"];
    toQ = OptionValue["To"]; mb = OptionValue["MBox"];
    df = iSVMDDayListOf[OptionValue["DateFrom"]]; dt = iSVMDDayListOf[OptionValue["DateTo"]];
    ha = OptionValue["HasAttachment"];
    (* Category \:306f\:65e5\:672c\:8a9e\:540d\:3067\:3082\:53d7\:3051\:3001\:4fdd\:5b58\:30c8\:30fc\:30af\:30f3\:3078\:6b63\:898f\:5316\:3057\:3066\:304b\:3089\:6bd4\:8f03 *)
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
         (* \:5b9b\:5148\:30d5\:30a3\:30eb\:30bf: To \:30d8\:30c3\:30c0\:90e8\:5206\:4e00\:81f4 (\:30aa\:30fc\:30ca\:30fc\:4ee5\:5916\:306e\:7279\:5b9a\:500b\:4eba\:5b9b\:306e\:4f9d\:983c\:3092\:9078\:3079\:308b\:3088\:3046\:306b) *)
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

(* \:4e00\:89a7\:884c (\:4f4e\:6f0f\:6d29)\:3002From \:306f AddressBook \:89e3\:6c7a\:6642\:306f\:8868\:793a\:540d *)
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

(* View \:7d50\:679c\:304c\:6a5f\:5bc6\:6271\:3044\:304b: PL >= 0.5 \:306e\:30e1\:30fc\:30eb\:3092 1 \:901a\:3067\:3082\:542b\:3081\:3070\:6a5f\:5bc6
   (\:30d5\:30a7\:30a4\:30eb\:30bb\:30fc\:30d5: PL \:6b20\:843d\:306f 1.0 \:6271\:3044)\:3002\:5168\:4ef6 PL < 0.5 \:306a\:3089\:5e73\:6587\:6271\:3044\:3002 *)
iSVMDConfidentialQ[snaps_List] :=
  snaps =!= {} && TrueQ[Max[iSVMailProbePL /@ snaps] >= 0.5];

(* \:8868\:793a\:6642\:306e\:5373\:6642\:6a5f\:5bc6\:30de\:30fc\:30af (ClaudeCode \:4e0d\:5728\:6642\:306e\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af):
   View \:8a55\:4fa1\:306e\:51fa\:529b\:30bb\:30eb\:306f\:8a55\:4fa1\:4e2d\:306f\:307e\:3060\:5b58\:5728\:3057\:306a\:3044\:305f\:3081\:3001\:30ef\:30f3\:30b7\:30e7\:30c3\:30c8\:306e
   \:30b9\:30b1\:30b8\:30e5\:30fc\:30eb\:30bf\:30b9\:30af (kernel idle \:5f8c\:306b\:5b9f\:884c) \:3067\:8a55\:4fa1\:5b8c\:4e86\:76f4\:5f8c\:306b
   SourceVaultMarkConfidentialViewCells \:3092\:8d70\:3089\:305b\:308b (FE \:304c\:3042\:308b\:6642\:306e\:307f)\:3002
   ClaudeEval \:76f4\:524d\:306e NBMakeContextPacket \:30d5\:30c3\:30af\:306f\:6700\:7d42\:9632\:885b\:7dda\:3068\:3057\:3066\:6b8b\:308b\:3002 *)
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

(* View \:5024\:306e\:6a5f\:5bc6\:5316 (\:30e6\:30fc\:30b6\:30fc\:65b9\:91dd: View \:306f\:6a5f\:5bc6\:5024\:3092\:8fd4\:3059\:95a2\:6570\:3068\:3057\:3066\:632f\:308b\:821e\:3046)\:3002
   PL >= 0.5 \:306e\:30e1\:30fc\:30eb\:3092\:542b\:3080\:7d50\:679c\:306f ClaudeCode`Confidential \:3092\:901a\:3057\:3066\:8fd4\:3059:
   \:5165\:529b\:30bb\:30eb\:306e\:6a5f\:5bc6\:30de\:30fc\:30af + \:51fa\:529b\:30bb\:30eb\:306e\:9045\:5ef6\:30de\:30fc\:30af + \:4ee3\:5165\:5148\:5909\:6570 (mails \:7b49) \:306e
   \:79d8\:5bc6\:5909\:6570\:767b\:9332 + CellEpilog \:88c5\:7740\:307e\:3067\:3084\:3063\:3066\:304f\:308c\:308b\:306e\:3067\:3001mails[[1]][[1]] \:306e
   \:3088\:3046\:306a\:6d3e\:751f\:5024\:306e\:30bb\:30eb\:3082\:8a55\:4fa1\:6642\:306b\:4f9d\:5b58\:79d8\:5bc6\:3068\:3057\:3066\:81ea\:52d5\:30de\:30fc\:30af\:3055\:308c\:308b\:3002
   ClaudeCode \:672a\:30ed\:30fc\:30c9\:6642\:306f\:30bb\:30eb\:30de\:30fc\:30af\:306e\:307f\:306e\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3002
   (\:5c06\:6765\:7684\:306b\:306f\:5024\:81ea\:4f53\:304c Confidential \:30d7\:30ed\:30d1\:30c6\:30a3\:3092\:904b\:3076\:591a\:5024\:5316\:304c\:7b4b\:3060\:304c\:5f53\:5ea7\:306f\:3053\:308c) *)
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

(* byte-exact \:6c38\:7d9a\:5316: snapshot \:306f\:6697\:53f7 body record \:3092\:542b\:3080\:306e\:3067\:3001\:5fa9\:53f7 round-trip \:4fdd\:8a3c\:306e\:305f\:3081
   BinarySerialize+Base64 \:306e 1 \:884c/snapshot\:3002\:30b7\:30e3\:30fc\:30c9 = <root>/<mbox>/<yyyymm>.svmail\:3002 *)
SourceVaultMailStoreRoot[] :=
  If[StringQ[$SourceVaultMailStoreRoot], $SourceVaultMailStoreRoot,
     FileNameJoin[{Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $TemporaryDirectory],
        "mail", "snapshots"}]];

(* shard key "mbox/yyyymm" -> file path *)
SourceVaultMailShardPath[shardKey_String] :=
  FileNameJoin[{SourceVaultMailStoreRoot[],
     Sequence @@ (StringSplit[shardKey, "/"] /. {m_, y_} :> {m, y <> ".svmail"})}];

(* \:65e7\:5358\:4e00\:30d5\:30a1\:30a4\:30eb (\:79fb\:884c\:7528\:306b\:691c\:51fa) *)
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
    (* \:8efd\:91cf\:30e1\:30bf\:30c7\:30fc\:30bf\:7d22\:5f15 sidecar \:3082\:540c\:6642\:66f4\:65b0 (\:672c\:6587\:3092\:30ed\:30fc\:30c9\:305b\:305a\:691c\:7d22\:3059\:308b\:305f\:3081) *)
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
   \:30e1\:30fc\:30eb\:64cd\:4f5c\:306e\:8a18\:9332 (\:958b\:5c01\:56de\:6570 / \:8fd4\:4fe1\:6e08) \[HorizontalLine]\[HorizontalLine] RecordId \:30ad\:30fc\:306e\:30b5\:30a4\:30c9\:30ab\:30fc JSON\:3002
   \:6697\:53f7\:30b7\:30e3\:30fc\:30c9\:3092\:6bce\:56de\:66f8\:304d\:63db\:3048\:306a\:3044 (\:958b\:5c01\:306f\:9ad8\:983b\:5ea6)\:3002<root>/interaction.json\:3002
   Dropbox \:5171\:6709\:306a\:306e\:3067\:8907\:6570 PC \:3067\:3082\:7d2f\:7a4d\:3059\:308b (\:66f8\:8fbc\:524d\:306b\:518d\:8aad\:8fbc\:3057\:3066\:30de\:30fc\:30b8)\:3002
   \:672c\:6587\:30fb\:30d8\:30c3\:30c0\:306f\:4e00\:5207\:542b\:3081\:306a\:3044 (RecordId \:3068\:56de\:6570\:30fb\:65e5\:6642\:306e\:307f)\:3002
   ============================================================ *)
If[! ValueQ[$iSVMDInteraction], $iSVMDInteraction = <||>];
If[! ValueQ[$iSVMDInteractionLoaded], $iSVMDInteractionLoaded = False];

iSVMDInteractionPath[] := FileNameJoin[{SourceVaultMailStoreRoot[], "interaction.json"}];

iSVMDInteractionLoad[] :=
  Module[{path = iSVMDInteractionPath[], data},
    data = If[FileExistsQ[path],
      Quiet@Check[ImportByteArray[ReadByteArray[path], "RawJSON"], <||>], <||>];
    $iSVMDInteraction = If[AssociationQ[data], data, <||>];
    $iSVMDInteractionLoaded = True;
    $iSVMDInteraction];

iSVMDInteractionEnsureLoaded[] :=
  If[! TrueQ[$iSVMDInteractionLoaded], iSVMDInteractionLoad[]];

iSVMDInteractionSave[] :=
  Module[{path = iSVMDInteractionPath[], dir, bytes},
    dir = DirectoryName[path];
    If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    bytes = Quiet@Check[ExportByteArray[$iSVMDInteraction, "RawJSON"], $Failed];
    If[ByteArrayQ[bytes],
      Quiet@Check[
        With[{strm = OpenWrite[path, BinaryFormat -> True]},
          BinaryWrite[strm, bytes]; Close[strm]; True], $Failed]]];

iSVMDInteractionGet[rid_String] :=
  (iSVMDInteractionEnsureLoaded[];
   With[{e = Lookup[$iSVMDInteraction, rid, <||>]}, If[AssociationQ[e], e, <||>]]);

iSVMDOpenCountOf[rid_String] :=
  With[{c = Lookup[iSVMDInteractionGet[rid], "OpenCount", 0]}, If[IntegerQ[c], c, 0]];
iSVMDOpenCountOf[_] := 0;

iSVMDRepliedCountOf[rid_String] :=
  With[{c = Lookup[iSVMDInteractionGet[rid], "RepliedCount", 0]}, If[IntegerQ[c], c, 0]];
iSVMDRepliedCountOf[_] := 0;

iSVMDRepliedAtOf[rid_String] :=
  With[{a = Lookup[iSVMDInteractionGet[rid], "RepliedAt", ""]}, If[StringQ[a], a, ""]];

(* \:958b\:5c01\:3092\:8a18\:9332 (\:66f8\:8fbc\:524d\:306b\:518d\:8aad\:8fbc\:3057\:3066\:4ed6\:30bb\:30c3\:30b7\:30e7\:30f3\:306e\:5024\:3068\:30de\:30fc\:30b8)\:3002\:8fd4\:308a\:5024: \:66f4\:65b0\:5f8c\:306e\:56de\:6570 *)
iSVMDRecordOpen[rid_String] /; rid =!= "" :=
  (iSVMDInteractionLoad[];
   Module[{e = iSVMDInteractionGet[rid], n},
     n = iSVMDOpenCountOf[rid] + 1;
     $iSVMDInteraction[rid] =
       Append[e, {"OpenCount" -> n, "LastOpened" -> DateString["ISODateTime"]}];
     iSVMDInteractionSave[]; n]);
iSVMDRecordOpen[_] := 0;

(* \:8fd4\:4fe1\:9001\:4fe1\:3092\:8a18\:9332\:3002\:8fd4\:308a\:5024: \:66f4\:65b0\:5f8c\:306e\:8fd4\:4fe1\:56de\:6570 *)
iSVMDRecordReplied[rid_String] /; rid =!= "" :=
  (iSVMDInteractionLoad[];
   Module[{e = iSVMDInteractionGet[rid], n},
     n = iSVMDRepliedCountOf[rid] + 1;
     $iSVMDInteraction[rid] =
       Append[e, {"RepliedCount" -> n, "RepliedAt" -> DateString["ISODateTime"]}];
     iSVMDInteractionSave[]; n]);
iSVMDRecordReplied[_] := 0;

SourceVaultMailInteractionStats[rid_String] := iSVMDInteractionGet[rid];
SourceVaultMailInteractionStats[] := (iSVMDInteractionLoad[]; $iSVMDInteraction);

(* ============================================================
   \:8efd\:91cf\:30e1\:30bf\:30c7\:30fc\:30bf\:7d22\:5f15 (sidecar/shard) \[HorizontalLine]\[HorizontalLine] \:672c\:6587\:6697\:53f7\:6587\:3092\:30ed\:30fc\:30c9\:305b\:305a\:691c\:7d22\:3059\:308b\:3002
   \:5404 shard <root>/<mbox>/<yyyymm>.svmail \:3068\:4e26\:3079\:3066
   <root>/<mbox>/<yyyymm>.svmailidx \:3092\:6301\:3064\:30021 \:884c = BinarySerialize \:3057\:305f\:7d22\:5f15\:884c
   (SummaryRow \:5f62 + Summary + FromRaw/ToRaw/FromContact/AttachmentCount/ShardKey)\:3002
   PayloadRefs (\:672c\:6587\:30fb\:30d8\:30c3\:30c0\:6697\:53f7\:6587) \:306f\:4e00\:5207\:542b\:3081\:306a\:3044 \[HorizontalLine]\[HorizontalLine] \:7d22\:5f15\:306b\:5165\:308b\:306e\:306f\:65e2\:306b shard \:5185\:3067
   at-rest \:5e73\:6587\:306e\:30e1\:30bf/\:30b5\:30de\:30ea\:30fc\:306e\:307f\:306a\:306e\:3067\:65b0\:305f\:306a\:9732\:51fa\:533a\:5206\:306f\:5897\:3048\:306a\:3044\:3002release gate \:306f
   \:5404\:884c\:306e PrivacyLevel \:306b\:3088\:308a MCP \:5c64 (B3) \:304c\:5f93\:6765\:3069\:304a\:308a cloud \:5b9b\:3092 gate \:3059\:308b\:3002
   shard \:5358\:4f4d\:306a\:306e\:3067 Dropbox \:540c\:671f\:3082\:65b0\:7740\:306e\:3042\:3063\:305f\:6708\:306e sidecar \:3060\:3051\:3067\:6e08\:3080\:3002
   ============================================================ *)

iSVMDIndexExt = ".svmailidx";

iSVMDIndexPath[shardKey_String] :=
  FileNameJoin[{SourceVaultMailStoreRoot[],
     Sequence @@ (StringSplit[shardKey, "/"] /. {m_, y_} :> {m, y <> iSVMDIndexExt})}];

iSVMDIndexFiles[mbox_ : All] :=
  Module[{root = SourceVaultMailStoreRoot[], files},
    files = If[DirectoryQ[root], FileNames["*" <> iSVMDIndexExt, root, 2], {}];
    If[mbox === All, files, Select[files, FileNameTake[DirectoryName[#]] === mbox &]]];

(* \:7d22\:5f15\:884c: snapshot \:304b\:3089\:4f4e\:6f0f\:6d29\:6295\:5f71\:3002\:672c\:6587/\:6697\:53f7\:6587 (PayloadRefs) \:306f\:542b\:3081\:306a\:3044\:3002 *)
iSVMDIndexRow[snap_Association] :=
  Module[{md = Lookup[snap, "MailMetadataPublic", <||>], dv = Lookup[snap, "Derived", <||>]},
    Join[SourceVaultMailSummaryRow[snap], <|
      "Summary" -> Lookup[dv, "Summary", Missing["NotGenerated"]],
      (* \:8a8d\:8a3c\:6e08\:307f (SourceVault \:7ba1\:7406 Derived) AccessTags \:3092\:7d22\:5f15\:3078 surface \:3057 MCP scope gate \:306b\:4f7f\:3046\:3002
         \:672c\:6587\:3092\:8aad\:307e\:305a\:306b\:7d22\:5f15\:3060\:3051\:3067 scope filter \:3067\:304d\:308b\:3002\:65e2\:5b9a {} (= untagged)\:3002 *)
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

(* RecordId 1 \:4ef6\:3092\:7d22\:5f15\:304b\:3089\:5f15\:304f (\:672c\:4f53\:30ed\:30fc\:30c9\:306a\:3057)\:3002\:7d22\:5f15\:30d5\:30a1\:30a4\:30eb\:3092\:9806\:6b21\:8d70\:67fb\:3002 *)
SourceVaultMailIndexGet[recordId_String] :=
  Module[{files = iSVMDIndexFiles[], hit = Missing["NotFound"], i = 1, r},
    While[i <= Length[files] && MissingQ[hit],
      r = SelectFirst[iSVMDReadIndexFile[files[[i]]],
         Lookup[#, "RecordId", ""] === recordId &, Missing[]];
      If[AssociationQ[r], hit = r];
      i++];
    hit];

(* \:7d22\:5f15\:518d\:751f\:6210: \:5404 shard \:3092\:4e00\:6642\:7684\:306b\:8aad\:307f\:8fbc\:3093\:3067\:7d22\:5f15 sidecar \:3092\:66f8\:304f ($iSVMDStore \:306f\:4e0d\:5909)\:3002
   \:65e2\:5b58 .svmail \:304b\:3089\:306e\:521d\:56de\:69cb\:7bc9\:30fb\:518d\:69cb\:7bc9\:306b\:4f7f\:3046\:3002 *)
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

(* ---- \:7d22\:5f15\:884c\:30d9\:30fc\:30b9 (flat row) \:306e\:8ff0\:8a9e/\:30bd\:30fc\:30c8: snapshot \:8ff0\:8a9e\:306e index \:7248 ---- *)
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
    (* RecordId \:306f\:4e3b\:30ad\:30fc: \:540c\:4e00\:30e1\:30fc\:30eb\:304c\:8907\:6570 sidecar \:884c\:306b\:91cd\:8907\:3057\:3066\:3044\:3066\:3082 1 \:884c\:306b
       (\:518d\:53d6\:8fbc\:3067\:65e5\:4ed8\:30d0\:30b1\:30c4\:304c\:5909\:308f\:308a\:5225 shard \:306e sidecar \:306b\:65e7\:884c\:304c\:6b8b\:308b\:30b1\:30fc\:30b9\:7b49) *)
    hits = DeleteDuplicatesBy[hits, Lookup[#, "RecordId", Missing[]] &];
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
    (* \:30b7\:30e3\:30fc\:30c9\:306f root/mbox/<yyyymm>.svmail\:3002\:65e7\:5358\:4e00\:30d5\:30a1\:30a4\:30eb snapshots.svmail \:306f\:9664\:5916 (\:79fb\:884c\:5bfe\:8c61)\:3002 *)
    files = Select[files, FileNameTake[#] =!= "snapshots.svmail" &];
    all = Join @@ (iSVMDReadShardFile /@ files);
    Scan[iSVMDIndexSnapshot, all];
    Scan[AssociateTo[$iSVMDLoadedShards, iSVMDPathToShardKey[#] -> True] &, files];
    <|"Status" -> "Loaded", "Root" -> root, "Shards" -> Length[files],
      "Count" -> Length[$iSVMDStore]|>];

(* ---- \:30a4\:30f3\:30af\:30ea\:30e1\:30f3\:30bf\:30eb(\:9045\:5ef6)\:30ed\:30fc\:30c9 ---- *)
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

(* \:65e7\:5358\:4e00\:30d5\:30a1\:30a4\:30eb -> \:6708\:6b21\:30b7\:30e3\:30fc\:30c9\:3078\:79fb\:884c\:3002\:5b8c\:4e86\:5f8c\:306f\:65e7\:30d5\:30a1\:30a4\:30eb\:3092 .bak \:306b\:30ea\:30cd\:30fc\:30e0\:3002 *)
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
    iSVMDIdentityEnsureLoaded[];  (* \:8b58\:5225\:5b50\:306e\:65e2\:5b58\:3092\:4e0a\:66f8\:304d\:3057\:306a\:3044\:3088\:3046\:5148\:306b load *)
    snaps = SourceVaultMailSnapshotFromMaildb[#, mbox, Sequence @@ fromOpts] & /@ records;
    (* \:5e38\:306b in-kernel store \:3078 put (\:51aa\:7b49)\:3002Persist \:306f\:30c7\:30a3\:30b9\:30af\:4fdd\:5b58\:306e\:307f\:5236\:5fa1\:3002 *)
    (SourceVaultMailSnapshotPut[#, "Persist" -> False] &) /@ snaps;
    If[TrueQ[OptionValue["Persist"]], SourceVaultMailStoreSave[]; iSVMDIdentitySaveSafe[]];
    <|"Status" -> "Ok", "MBox" -> mbox, "Count" -> Length[snaps],
      "Stored" -> Length[$iSVMDStore],
      "Persisted" -> TrueQ[OptionValue["Persist"]], "Snapshots" -> snaps|>];

(* \:65e2\:5b58 snapshot \:306e\:5e73\:6587 From/To/Cc \:304b\:3089\:8b58\:5225\:5b50\:3092\:4e00\:62ec\:751f\:6210 (\:518d\:53d6\:8fbc\:4e0d\:8981)\:3002 *)
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
   SourceVaultSummaries \:6a2a\:65ad\:691c\:7d22 provider (mail)
   \:30c7\:30a3\:30b9\:30af\:7d22\:5f15 (.svmailidx) \:306e\:307f\:3092\:8d70\:67fb\:3057\:672c\:6587\:6697\:53f7\:6587\:3092\:30ed\:30fc\:30c9\:305b\:305a\:5171\:901a\:30b9\:30ad\:30fc\:30de\:884c\:3092\:8fd4\:3059\:3002
   eagle/sources \:3068\:540c\:3058\:5171\:901a\:30b9\:30ad\:30fc\:30de <|Kind,Id,URI,Title,Authors,Published,Summary,
   URL,File,Date,PrivacyLevel|> \:306b\:63c3\:3048\:3001JoinAcross / \:7dcf\:691c\:7d22\:3067\:6df7\:5728\:691c\:7d22\:3067\:304d\:308b\:3088\:3046\:306b\:3059\:308b\:3002
   \:985e\:4f3c\:9805\:76ee\:306f\:540c\:540d (Title=\:4ef6\:540d, Summary=\:8981\:7d04, Date, PrivacyLevel, URI)\:3001\:30e1\:30fc\:30eb\:56fa\:6709\:5024\:306f
   \:5225 API \:306b\:6b8b\:3059\:3002\:884c\:3054\:3068\:306b PrivacyLevel \:3092\:51fa\:3059\:306e\:3067 SourceVaultSummaries \:306e\:51fa\:529b\:30bb\:30eb\:306f
   iSVCatalogCellMaxPLFromText \:306b\:3088\:308a\:6700\:5927 PL \:3067\:30de\:30fc\:30af\:3055\:308c\:3001\:9ad8 PL \:30e1\:30fc\:30eb\:3092\:542b\:3080\:7d50\:679c\:306f
   cloud \:3078\:51fa\:306a\:3044 (fail-safe: PL \:6b20\:843d = 1.0)\:3002
   ============================================================ *)

(* mail \:306e\:6b63\:6e96 SourceVault URI (sv://record/svmail-<id>\:3002mcp \:306e iSVMailOwnsURIQ /
   iSVMailAdapterResolve \:304c\:89e3\:6c7a\:3059\:308b\:5f62)\:3002RecordId \:306f\:65e2\:306b "svmail-" \:63a5\:982d\:8f9e\:4ed8\:304d\:3002 *)
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
            (* fail-safe: PL \:6b20\:843d\:306f 1.0 (cloud \:975e\:9001\:4fe1\:5074\:306b\:5012\:3059) *)
            "PrivacyLevel" -> If[NumericQ[pl], N[pl], 1.0]|>]],
      Select[rows, AssociationQ]]];
iSVMDCommonRows[query_String] := iSVMDCommonRows[query, <||>];

(* \:6a2a\:65ad\:691c\:7d22 Grid \:306e mail \:884c\:30bf\:30a4\:30c8\:30eb\:30af\:30ea\:30c3\:30af: \:4f4e\:6f0f\:6d29\:30d8\:30c3\:30c0 + URI \:3092\:30a6\:30a4\:30f3\:30c9\:30a6\:8868\:793a
   (\:672c\:6587\:30fb\:6697\:53f7\:6587\:306f\:8aad\:307e\:306a\:3044)\:3002\:5168\:6587/\:30b5\:30de\:30ea\:30fc\:306f mail \:5c02\:7528 API (\:6a5f\:5bc6\:30e9\:30c3\:30d7\:4ed8\:304d) \:3092\:4f7f\:3046\:3002 *)
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

(* provider / \:884c\:30a2\:30af\:30b7\:30e7\:30f3\:767b\:9332 (eagle \:3068\:540c\:3058\:67a0\:7d44\:307f\:30fbAssociation \:30ac\:30fc\:30c9\:4ed8\:304d\:3002
   SourceVault.wl \:672a\:30ed\:30fc\:30c9\:306e maildb \:5358\:4f53\:30ed\:30fc\:30c9\:3067\:3082\:843d\:3061\:306a\:3044)\:3002 *)
If[! AssociationQ[$SourceVaultSummaryProviders], $SourceVaultSummaryProviders = <||>];
$SourceVaultSummaryProviders["mail"] = iSVMDCommonRows;
If[! AssociationQ[$iSVRowTitleActions], $iSVRowTitleActions = <||>];
$iSVRowTitleActions["mail"] = iSVMDShowMailInfo;

End[];
EndPackage[];


(* ::Package:: *)
(**)


(* ============================================================
   SourceVault_imap.wl -- IMAP \:65b0\:7740\:53d6\:5f97 + \:6d3e\:751f (PL/\:512a\:5148\:5ea6/\:6982\:8981) \:306e\:5f8c\:51e6\:7406
   This file is encoded in UTF-8.

   \:8a2d\:8a08\:306e\:67f1 (\:30e6\:30fc\:30b6\:30fc\:8981\:671b):
   - \:53d6\:308a\:8fbc\:307f (IMAP) \:3068 \:6d3e\:751f\:51e6\:7406 (\:30ed\:30fc\:30ab\:30eb LLM) \:3092\:5b8c\:5168\:5206\:96e2\:3002
     \:65e2\:5b9a\:3067\:306f\:53d6\:308a\:8fbc\:307f\:6642\:306b LLM \:3092\:56de\:3055\:305a\:9ad8\:901f\:306b\:4fdd\:5b58\:3057\:3001\:6d3e\:751f\:306f\:5f8c\:304b\:3089\:5897\:5206\:30d0\:30c3\:30c1\:3002
   - \:4e2d\:65ad\:8010\:6027: \:30d0\:30c3\:30c1\:306f CheckpointEvery \:4ef6\:3054\:3068\:306b dirty \:30b7\:30e3\:30fc\:30c9\:3092\:4fdd\:5b58\:3002
     \:5f37\:5236\:7d42\:4e86\:3057\:3066\:3082 "Processed" \:6e08\:307f\:306f pending \:306b\:623b\:3089\:305a\:518d\:51e6\:7406\:3055\:308c\:306a\:3044\:3002
   - \:5916\:90e8\:4f9d\:5b58 (IMAP / LLM) \:306f\:6ce8\:5165\:53ef\:80fd ("MessageSource" / "Inferencer")\:3002
     \:65e2\:5b9a\:306f\:5b9f Python imaplib / \:5b9f LM Studio\:3002\:30c6\:30b9\:30c8\:306f fake \:3092\:6ce8\:5165\:3057\:3066 headless \:691c\:8a3c\:3002
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultMailFetchNew::usage =
  "SourceVaultMailFetchNew[mbox, opts] \:306f IMAP \:304b\:3089\:65b0\:7740\:306e\:307f\:53d6\:5f97\:3057 snapshot \:5316\:3057\:3066 store \:306b\:4fdd\:5b58\:3059\:308b\:3002\:65e2\:5b9a\:306f LLM \:51e6\:7406\:306a\:3057\:3002opts: \"Period\"(\"Latest\"|n\:65e5|{from,to}|\"YYYYMM\"), \"Process\"(\:65e2\:5b9aFalse), \"MessageSource\"(\:65e2\:5b9a=\:5b9fIMAP, \:6ce8\:5165\:53ef), \"Inferencer\", \"Persist\"(\:65e2\:5b9aTrue), \"MaxEmails\"\:3002RecordId \:3067\:65e2\:5b58\:3068\:91cd\:8907\:6392\:9664\:3002";
SourceVaultMailDerivedPending::usage =
  "SourceVaultMailDerivedPending[opts] \:306f\:30ed\:30fc\:30c9\:6e08\:307f store \:306e\:4e2d\:3067\:6d3e\:751f (PL/\:512a\:5148\:5ea6/\:6982\:8981) \:672a\:51e6\:7406\:306e snapshot \:3092\:8fd4\:3059\:3002opts: \"MBox\"(\:65e2\:5b9a Automatic\:3002\:6587\:5b57\:5217\:3067\:305d\:306e mbox \:306b\:9650\:5b9a), \"DateFrom\"/\"DateTo\"(\:65e2\:5b9a Automatic\:3002DateObject/\:6587\:5b57\:5217/{y,m,d} \:3067\:65e5\:4ed8\:7bc4\:56f2\:306b\:9650\:5b9a\:3001\:65e5\:5358\:4f4d\:5305\:542b)\:3002";
SourceVaultMailDerivedPendingQ::usage =
  "SourceVaultMailDerivedPendingQ[snapshot] \:306f\:6d3e\:751f\:304c\:672a\:51e6\:7406 (\"Pending\") \:306a\:3089 True\:3002";
SourceVaultInferMailDerivedBatch::usage =
  "SourceVaultInferMailDerivedBatch[opts] \:306f\:672a\:51e6\:7406 snapshot \:306e\:6d3e\:751f\:3092\:30ed\:30fc\:30ab\:30eb LLM \:3067\:5897\:5206\:751f\:6210\:3057 in-place \:66f4\:65b0\:3059\:308b\:3002\:4e2d\:65ad\:8010\:6027 (CheckpointEvery \:4ef6\:3054\:3068\:306b\:4fdd\:5b58)\:3002\:7279\:5b9a mbox \:306e\:6307\:5b9a\:671f\:9593\:30e1\:30fc\:30eb\:306b\:30b5\:30de\:30ea\:30fc\:3092\:4ed8\:3051\:308b\:7528\:9014\:306f SourceVaultMailAddSummaries[mbox, period] \:304c\:6b63\:6e96 (EnsureLoaded \:3092\:5185\:5305\:3057\:5916\:90e8\:30b8\:30e7\:30d6\:3067\:3082\:81ea\:5df1\:5b8c\:7d50)\:3002opts: \"MBox\"(\:65e2\:5b9a Automatic\:3002\:6587\:5b57\:5217\:3092\:4e0e\:3048\:308b\:3068\:5bfe\:8c61 snapshot \:3092\:305d\:306e mbox \:306b\:9650\:5b9a\:3002Automatic=\:30ed\:30fc\:30c9\:6e08\:307f\:5168 mbox), \"Limit\"(\:65e2\:5b9a50\:3001\:30d5\:30a3\:30eb\:30bf\:5f8c\:306e\:4ef6\:6570\:4e0a\:9650\:3002\:7bc4\:56f2\:5185\:3059\:3079\:3066\:306a\:3089 Infinity), \"DateFrom\"/\"DateTo\"(\:65e2\:5b9a Automatic\:3002DateObject/\:6587\:5b57\:5217/{y,m,d} \:3067\:5bfe\:8c61\:30e1\:30fc\:30eb\:3092\:65e5\:4ed8\:7bc4\:56f2\:306b\:9650\:5b9a\:3001\:65e5\:5358\:4f4d\:5305\:542b), \"Refresh\"(\:65e2\:5b9a None=Pending \:306e\:307f\:3002\"MissingCategory\"=Category \:672a\:751f\:6210\:306e\:51e6\:7406\:6e08\:307f\:65e7 snapshot \:3082\:518d\:51e6\:7406, All=\:5168\:4ef6\:518d\:51e6\:7406, Function=\:8ff0\:8a9e\:306b\:4e00\:81f4\:3059\:308b snapshot \:3092\:518d\:51e6\:7406\:3002\:4f8b: \"Refresh\"->Function[s, StringContainsQ[ToString@s[\"MailMetadataPublic\"][\"Subject\"], \"Cerezo\"]]), \"Inferencer\"(\:65e2\:5b9a=\:5b9fLLM, \:6ce8\:5165\:53ef), \"CheckpointEvery\"(\:65e2\:5b9a20), \"Persist\"(\:65e2\:5b9aTrue)\:3002";
SourceVaultMailInferDerived::usage =
  "SourceVaultMailInferDerived[mailspec] \:306f mailspec(date/subject/from/to/cc/body)\:304b\:3089\:30ed\:30fc\:30ab\:30eb LLM \:3067 <|WorkRequest, PrivacyLevel, Category, Deadline, Summary, Status|> \:3092\:8fd4\:3059(\:512a\:5148\:5ea6\:306f\:69cb\:9020\:7684\:306b\:5225\:8a08\:7b97)\:3002Category \:306f $SourceVaultMailCategories \:306e\:30c8\:30fc\:30af\:30f3\:3001Deadline \:306f ISO \:6587\:5b57\:5217\:307e\:305f\:306f Missing[\"None\"]\:3002";
SourceVaultMailAddSummaries::usage =
  "SourceVaultMailAddSummaries[mbox_String, period_:\"Latest\", opts] \:306f mbox \:306e\:6307\:5b9a\:671f\:9593\:306e\:30e1\:30fc\:30eb\:3092 SourceVaultMailEnsureLoaded \:3067\:30ed\:30fc\:30c9\:3057\:3066\:304b\:3089\:3001\:305d\:306e mbox \:306e\:672a\:51e6\:7406 snapshot \:306e\:6d3e\:751f(\:6982\:8981/\:30ab\:30c6\:30b4\:30ea/\:512a\:5148\:5ea6/\:3006\:5207)\:3092 SourceVaultInferMailDerivedBatch \:3067\:4e00\:62ec\:751f\:6210\:30fb\:4fdd\:5b58\:3059\:308b\:3002\:300c<mbox>\:306e\:65b0\:7740\:30e1\:30fc\:30eb\:306b\:30b5\:30de\:30ea\:30fc\:3092\:8ffd\:52a0\:300d\:306e\:6b63\:6e96\:30a8\:30f3\:30c8\:30ea\:30dd\:30a4\:30f3\:30c8(EnsureLoaded \:3068\:30d0\:30c3\:30c1\:30921\:95a2\:6570\:306b\:5185\:5305\:3059\:308b\:306e\:3067\:3001\:5916\:90e8 WolframScript \:30b8\:30e7\:30d6\:3078\:9000\:907f\:3055\:308c\:3066\:3082\:30ed\:30fc\:30c9\:304b\:3089\:81ea\:5df1\:5b8c\:7d50\:3057\:3001\:7a7a\:30b9\:30c8\:30a2\:30670\:4ef6\:51e6\:7406\:306b\:306a\:308b\:5931\:6557\:3092\:9632\:3050)\:3002opts: \"Limit\"(\:65e2\:5b9a Infinity=\:65b0\:7740\:5168\:4ef6), \"Persist\"(\:65e2\:5b9a True)\:3002\:8fd4\:308a\:5024 <|Status, MBox, Period, Loaded, Batch|>\:3002";
SourceVaultRegisterMailspecEnricher::usage =
  "SourceVaultRegisterMailspecEnricher[name, f] \:306f\:6d3e\:751f(\:30b5\:30de\:30ea\:30fc\:4f5c\:6210)\:6642\:306b LLM \:3078\:6e21\:3059 mailspec \:3092\:62e1\:5f35\:3059\:308b enricher \:3092\:767b\:9332\:3059\:308b(Cerezo.wl \:7b49\:306e\:62e1\:5f35\:7528)\:3002f[mailspec, snapshot] \:304c\:5909\:66f4\:5f8c\:306e mailspec(Association)\:3092\:8fd4\:3059\:3068\:305d\:308c\:304c LLM \:5165\:529b\:306b\:4f7f\:308f\:308c\:3001Derived.DerivedEnrichment \:306b\:540d\:524d\:304c\:8a18\:9332\:3055\:308c\:308b\:3002\:975e\:8a72\:5f53/\:5931\:6557\:6642\:306f mailspec \:3092\:305d\:306e\:307e\:307e\:8fd4\:3059\:3002\:53d6\:308a\:8fbc\:307f\:30fb\:4fdd\:5b58\:30ec\:30b3\:30fc\:30c9\:5f62\:5f0f\:306b\:306f\:5f71\:97ff\:305b\:305a\:3001\:672a\:767b\:9332\:306a\:3089\:5b8c\:5168\:7d20\:901a\:3057\:3002";
SourceVaultUnregisterMailspecEnricher::usage =
  "SourceVaultUnregisterMailspecEnricher[name] \:306f mailspec enricher \:306e\:767b\:9332\:3092\:89e3\:9664\:3059\:308b\:3002";
SourceVaultMailspecEnrichers::usage =
  "SourceVaultMailspecEnrichers[] \:306f\:767b\:9332\:6e08\:307f mailspec enricher \:540d\:306e\:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002";
SourceVaultRegisterPostFetchHook::usage =
  "SourceVaultRegisterPostFetchHook[name, f] \:306f SourceVaultMailFetchNew \:306e\:53d6\:308a\:8fbc\:307f\:5b8c\:4e86\:6642\:306b\:547c\:3076\:30d5\:30c3\:30af f[mbox, fetchResult] \:3092\:767b\:9332\:3059\:308b\:3002" <>
  "\:53d6\:308a\:8fbc\:307f\:5f8c\:306e\:6d3e\:751f(mining \:306e\:8457\:8005\:62bd\:51fa\:306a\:3069)\:3092 maildb \:306b\:4f9d\:5b58\:3055\:305b\:305a\:306b\:7d50\:7dda\:3059\:308b\:62e1\:5f35\:70b9\:3002\:30d5\:30c3\:30af\:306e\:5931\:6557\:306f fetch \:3092\:58ca\:3055\:306a\:3044\:3002\:672a\:767b\:9332\:306a\:3089\:5b8c\:5168\:7d20\:901a\:3057\:3002";
SourceVaultUnregisterPostFetchHook::usage =
  "SourceVaultUnregisterPostFetchHook[name] \:306f post-fetch \:30d5\:30c3\:30af\:306e\:767b\:9332\:3092\:89e3\:9664\:3059\:308b\:3002";
SourceVaultPostFetchHooks::usage =
  "SourceVaultPostFetchHooks[] \:306f\:767b\:9332\:6e08\:307f post-fetch \:30d5\:30c3\:30af\:540d\:306e\:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002";
SourceVaultMailComputePriority::usage =
  "SourceVaultMailComputePriority[snapshot, workRequest, category] \:306f\:69cb\:9020\:30b7\:30b0\:30ca\:30eb(\:9001\:4fe1\:8005\:30b0\:30eb\:30fc\:30d7\:91cd\:307f + To/Cc \:4f4d\:7f6e + ML\:5224\:5b9a + LLM \:4f9d\:983c\:5ea6 + LLM \:30ab\:30c6\:30b4\:30ea)\:304b\:3089\:91cd\:8981\:5ea6 0.0-1.0 \:3092\:6c7a\:5b9a\:7684\:306b\:8a08\:7b97\:3059\:308b\:3002category \:304c \"Notice\"(\:901a\:77e5\:30fb\:4e00\:6589\:914d\:4fe1\:30fb\:5e83\:544a)\:306a\:3089 -0.30 \:6e1b\:70b9\:3002<|Priority, Components|> \:3092\:8fd4\:3059\:3002";
SourceVaultMailExplainPriority::usage =
  "SourceVaultMailExplainPriority[snapshot] \:306f snapshot \:306e\:4fdd\:5b58\:6e08\:307f WorkRequest/Category \:3092\:4f7f\:3063\:3066\:91cd\:8981\:5ea6\:306e\:5185\:8a33(Components)\:3092\:8fd4\:3059\:3002";
SourceVaultMailRecomputePriorities::usage =
  "SourceVaultMailRecomputePriorities[opts] \:306f\:30ed\:30fc\:30c9\:6e08\:307f snapshot \:306e\:3046\:3061\:69cb\:9020\:8a08\:7b97\:6e08\:307f (PriorityComponents \:3042\:308a) \:306e\:3082\:306e\:306b\:3064\:3044\:3066\:3001\:4fdd\:5b58\:6e08\:307f WorkRequest/Category \:304b\:3089 Priority \:3092 LLM \:306a\:3057\:3067\:518d\:8a08\:7b97\:3057 in-place \:66f4\:65b0\:3059\:308b\:3002\:512a\:5148\:5ea6\:5f0f\:306e\:5909\:66f4\:3092\:65e2\:51e6\:7406\:30e1\:30fc\:30eb\:3078\:53cd\:6620\:3059\:308b\:305f\:3081\:306b\:4f7f\:3046 (legacy maildb \:7531\:6765\:306e Priority \:306f\:89e6\:3089\:306a\:3044)\:3002opts: \"Persist\"(\:65e2\:5b9aTrue)\:3002";
SourceVaultSetPriorityGroupWeight::usage =
  "SourceVaultSetPriorityGroupWeight[group, weight] \:306f\:30b0\:30eb\:30fc\:30d7\:306e\:91cd\:307f(0.0-1.0)\:3092\:767b\:9332\:3057 vault config \:306b\:4fdd\:5b58\:3059\:308b\:3002\:5b9f\:4f53\:306e Group \:304c\:3053\:308c\:306b\:89e3\:6c7a\:3055\:308c\:308b\:3002";
SourceVaultPriorityGroupWeights::usage = "SourceVaultPriorityGroupWeights[] \:306f\:767b\:9332\:6e08\:307f\:30b0\:30eb\:30fc\:30d7\:91cd\:307f\:3092\:8fd4\:3059\:3002";
SourceVaultGroupWeightFor::usage = "SourceVaultGroupWeightFor[group] \:306f\:30b0\:30eb\:30fc\:30d7\:306e\:91cd\:307f\:3092\:8fd4\:3059\:3002\:7121\:3051\:308c\:3070 Missing\:3002";
SourceVaultPriorityGroupsLoad::usage = "SourceVaultPriorityGroupsLoad[] \:306f\:30b0\:30eb\:30fc\:30d7\:91cd\:307f config \:3092\:8aad\:307f\:8fbc\:3080\:3002";
SourceVaultRegisterMailAccount::usage =
  "SourceVaultRegisterMailAccount[<|\"MBox\",\"User\",\"Email\",\"CredKey\",\"Server\",\"Port\"|>, opts] \:306f IMAP \:30a2\:30ab\:30a6\:30f3\:30c8\:8a2d\:5b9a\:3092\:767b\:9332\:3057 vault config \:306b\:4fdd\:5b58\:3059\:308b\:3002\:30d1\:30b9\:30ef\:30fc\:30c9\:306f\:4fdd\:5b58\:305b\:305a CredKey(SystemCredential \:540d)\:306e\:307f\:3002\:540c\:4e00 MBox \:306f\:4e0a\:66f8\:304d\:3002NBRegisterTrustedLocalServer \:3068\:540c\:69d8\:3001\:79c1\:7684\:30c7\:30fc\:30bf\:306f\:30bd\:30fc\:30b9\:306b\:7f6e\:304b\:305a\:3053\:3053\:3067\:767b\:9332\:3059\:308b\:3002";
SourceVaultMailAccounts::usage = "SourceVaultMailAccounts[] \:306f\:767b\:9332\:6e08\:307f IMAP \:30a2\:30ab\:30a6\:30f3\:30c8\:8a2d\:5b9a\:3092 Dataset \:3067\:8fd4\:3059(\:30d1\:30b9\:30ef\:30fc\:30c9\:306f\:542b\:307e\:306a\:3044)\:3002";
SourceVaultGetMailAccount::usage = "SourceVaultGetMailAccount[mbox] \:306f\:767b\:9332\:6e08\:307f\:30a2\:30ab\:30a6\:30f3\:30c8\:8a2d\:5b9a\:3092\:8fd4\:3059\:3002\:7121\:3051\:308c\:3070 Missing\:3002";
SourceVaultRemoveMailAccount::usage = "SourceVaultRemoveMailAccount[mbox] \:306f\:767b\:9332\:3092\:524a\:9664\:3059\:308b\:3002";
SourceVaultMailAccountsLoad::usage = "SourceVaultMailAccountsLoad[] \:306f vault config \:304b\:3089\:30a2\:30ab\:30a6\:30f3\:30c8\:8a2d\:5b9a\:3092\:8aad\:307f\:8fbc\:3080\:3002";
$SourceVaultMailConfigRoot::usage = "IMAP \:30a2\:30ab\:30a6\:30f3\:30c8\:8a2d\:5b9a\:306e\:4fdd\:5b58\:30eb\:30fc\:30c8(\:65e2\:5b9a PrivateVault/config)\:3002\:30c6\:30b9\:30c8\:3067\:4e0a\:66f8\:304d\:53ef\:3002";

Begin["`Private`"];

(* \:30a2\:30ab\:30a6\:30f3\:30c8\:8a2d\:5b9a\:306f\:7a7a\:3067\:521d\:671f\:5316\:3057\:3001SourceVaultRegisterMailAccount \:3067\:767b\:9332 -> vault config
   \:3078\:6c38\:7d9a\:5316\:3059\:308b\:3002\:79c1\:7684\:30ed\:30b0\:30a4\:30f3\:306f\:30bd\:30fc\:30b9\:30b3\:30fc\:30c9\:306b\:30cf\:30fc\:30c9\:30b3\:30fc\:30c9\:3057\:306a\:3044\:3002 *)
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

(* ---- \:6d3e\:751f pending \:5224\:5b9a ---- *)
SourceVaultMailDerivedPendingQ[snap_Association] :=
  Module[{d = Lookup[snap, "Derived", <||>], st, sm},
    st = Lookup[d, "DerivedStatus", Missing[]];
    sm = Lookup[d, "Summary", Missing[]];
    Which[
      st === "Pending", True,
      st === "Processed", False,
      (* DerivedStatus \:7121\:3057\:306e\:65e7 snapshot: summary \:304c\:7a7a\:306a\:3089 pending *)
      True, ! (StringQ[sm] && StringTrim[sm] =!= "")]];

(* \:65e2\:5b9a (\:5f15\:6570\:306a\:3057) \:306f\:30ed\:30fc\:30c9\:6e08\:307f\:5168 pending\:3002"MBox"/"DateFrom"/"DateTo" \:3092\:6e21\:3059\:3068\:7d5e\:308a\:8fbc\:3080\:3002
   \:30aa\:30d7\:30b7\:30e7\:30f3\:4ed8\:304d\:3067\:3082\:5fc5\:305a\:8a55\:4fa1\:3055\:308c\:308b\:306e\:3067\:3001Length[...] \:304c\:300c\:672a\:8a55\:4fa1\:5f0f\:306e\:5f15\:6570\:6570\:300d\:306b\:5316\:3051\:3066
   \:507d\:306e\:4ef6\:6570\:3092\:8fd4\:3059\:4e8b\:6545 (\:4f8b: "MBox"->... \:3092\:6e21\:3057\:3066\:5e38\:306b 3) \:304c\:8d77\:304d\:306a\:3044\:3002 *)
Options[SourceVaultMailDerivedPending] =
  {"MBox" -> Automatic, "DateFrom" -> Automatic, "DateTo" -> Automatic};
SourceVaultMailDerivedPending[OptionsPattern[]] :=
  Module[{mb = OptionValue["MBox"], df, dt, pend},
    df = iSVMDDayListOf[OptionValue["DateFrom"]];
    dt = iSVMDDayListOf[OptionValue["DateTo"]];
    pend = Select[SourceVaultMailSnapshotList[], SourceVaultMailDerivedPendingQ];
    If[StringQ[mb], pend = Select[pend, Lookup[#["MailSource"], "MBox", Null] === mb &]];
    If[df =!= Automatic || dt =!= Automatic, pend = Select[pend, iSVMDDateInRange[#, df, dt] &]];
    pend];

(* ---- \:30ed\:30fc\:30ab\:30eb LLM (LM Studio, OpenAI \:4e92\:63db) ----
   maildb \:306e iQueryLMStudioDirect \:3092\:8e0f\:8972: Headers \:306b Content-Type + Authorization\:3001
   Body \:306f UTF-8 ByteArray (Export RawJSON \:3092\:30d5\:30a1\:30a4\:30eb\:7d4c\:7531\:3067\:30d0\:30a4\:30c8\:5316)\:3001
   \:5fdc\:7b54\:3082\:30d5\:30a1\:30a4\:30eb\:7d4c\:7531 Import \:3067 encoding-safe \:306b\:3002 *)
(* \:30ed\:30fc\:30ab\:30eb LLM \:5c02\:7528 credential \:3092 AccessLevel 1.0 \:3067\:53d6\:5f97\:3059\:308b\:3002
   url \:306f scheme://host:port \:306b\:6b63\:898f\:5316\:3055\:308c\:3066\:30de\:30c3\:30d4\:30f3\:30b0\:7167\:5408\:3055\:308c\:308b (path \:306f\:7121\:8996)\:3002
   \:30ad\:30fc\:672a\:767b\:9332/\:672a\:4fdd\:5b58\:306a\:3089\:8a8d\:8a3c\:30aa\:30d5\:904b\:7528\:5411\:3051\:306b "lm-studio" \:3078\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3002 *)
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
    (* \:3053\:306e\:30bf\:30b9\:30af\:306f\:5206\:985e\:62bd\:51fa\:306a\:306e\:3067\:63a8\:8ad6 (thinking) \:306f\:4e0d\:8981\:3002Qwen3 \:7cfb\:306e
       reasoning \:30e2\:30c7\:30eb\:306f\:601d\:8003\:3092 reasoning_content \:306b\:5ef6\:3005\:3068\:51fa\:529b\:3057\:3001\:9577\:6587\:30e1\:30fc\:30eb\:3067
       TimeConstraint \:5185\:306b\:6700\:7d42 content \:3092\:51fa\:305b\:305a\:7a7a\:5fdc\:7b54\[RightArrow]FailedLLM \:306b\:306a\:308b\:3002
       enable_thinking:False \:3067\:601d\:8003\:3092\:6291\:6b62\:3057\:3001\:76f4\:63a5 3 \:884c\:3092\:51fa\:529b\:3055\:305b\:308b\:3002 *)
    reqData = <|"messages" -> {<|"role" -> "user", "content" -> prompt|>},
       "stream" -> False, "temperature" -> 0.2,
       "chat_template_kwargs" -> <|"enable_thinking" -> False|>|> ~Join~
       If[model =!= "", <|"model" -> model|>, <||>];
    reqFile = iSVTmpJSON["req"];
    Quiet@Check[Export[reqFile, reqData, "RawJSON"], Return[""]];
    bodyBytes = Quiet@Check[ByteArray[BinaryReadList[reqFile]], $Failed];
    Quiet@DeleteFile[reqFile];
    If[Head[bodyBytes] =!= ByteArray, Return[""]];
    (* 1H-S boundary gate (Shadow=record / Warn=Message / Enforce=refuse; fail-open without capbroker) *)
    If[TrueQ[SourceVault`SourceVaultLLMBoundaryGateRefusedQ["maildb:iSVQueryLMStudio",
        <|"Provider" -> "openai-compat", "Model" -> If[model === "", Missing["AutoDetect"], model],
          "Deployment" -> url, "Messages" -> reqData["messages"]|>]],
      Return[""]];
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
    (* thinking \:30e2\:30c7\:30eb\:304c content \:3092\:7a7a\:306b\:3057\:3066 reasoning_content \:306b\:51fa\:3057\:305f\:5834\:5408\:306e\:4fdd\:967a *)
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

(* \:6240\:6709\:8005\:60c5\:5831\:306f SourceVault \:8b58\:5225\:5b50\:5c64 #1 \:304b\:3089\:53d6\:5f97 (identity \:672a\:30ed\:30fc\:30c9\:3067\:3082\:5b89\:5168) *)
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
    ownerRef = If[StringQ[pmail] && pmail =!= "", pmail, "\:30aa\:30fc\:30ca\:30fc"];
    recvLine = "\:53d7\:4fe1\:8005(\:30aa\:30fc\:30ca\:30fc)\:306f " <> ownerRef <>
       If[ListQ[owners] && owners =!= {},
         "(\:30aa\:30fc\:30ca\:30fc\:306e\:30a2\:30c9\:30ec\:30b9: " <> StringRiffle[owners, ", "] <> ")", ""] <>
       If[StringQ[prof] && prof =!= "", "\:3002\:30d7\:30ed\:30d5\:30a3\:30fc\:30eb: " <> prof, ""] <> "\:3002\n" <>
       "to/cc \:304c\:30aa\:30fc\:30ca\:30fc\:500b\:4eba\:306e\:30a2\:30c9\:30ec\:30b9\:3067\:306a\:304f\:3066\:3082\:3001\:30aa\:30fc\:30ca\:30fc\:306e\:6240\:5c5e\:3059\:308b\:30b0\:30eb\:30fc\:30d7\:30fb\:90e8\:7f72\:30fb\:30e1\:30fc\:30ea\:30f3\:30b0\:30ea\:30b9\:30c8\:5b9b\:3067\:3042\:308c\:3070\:3001\:305d\:306e\:4f9d\:983c\:306f\:30aa\:30fc\:30ca\:30fc\:3078\:306e\:4f9d\:983c\:3068\:3057\:3066\:6271\:3046\:3002\n\n";
    "\:4ee5\:4e0b\:306e[\:30e1\:30fc\:30eb]\:306b\:3064\:3044\:3066\:3001WORKREQUEST\:3001PRIVACY\:3001CATEGORY\:3001DEADLINE\:3001SUMMARY \:306e5\:3064\:3092\:63a8\:5b9a\:305b\:3088\:3002\n" <>
    "\:5404\:884c\:306e\:30d5\:30a9\:30fc\:30de\:30c3\:30c8\:306b\:5f93\:3044\:3001\:4f59\:8a08\:306a\:8aac\:660e\:306f\:4e00\:5207\:4e0d\:8981\:3002\n\n" <>
    recvLine <>
    "== WORKREQUEST ==\n\:4f9d\:983c\:5ea6\:3092 0.0\:301c1.0 \:306e\:6570\:5024\:30671\:3064\:51fa\:529b\:3002\:3053\:308c\:306f\:300c\:3053\:306e\:30e1\:30fc\:30eb\:304c\:30aa\:30fc\:30ca\:30fc\:500b\:4eba\:3078\:306e\:76f4\:63a5\:306e\:4f9d\:983c\:30fb\:8981\:8acb\:30fb\:30bf\:30b9\:30af(\:8fd4\:4fe1\:3084\:5bfe\:5fdc\:304c\:5fc5\:8981)\:3067\:3042\:308b\:5ea6\:5408\:3044\:300d(\:512a\:5148\:5ea6\:306f\:30b7\:30b9\:30c6\:30e0\:304c\:5225\:9014\:8a08\:7b97\:3059\:308b\:306e\:3067\:3001\:5185\:5bb9\:3068\:3057\:3066\:306e\:4f9d\:983c\:5ea6\:306e\:307f\:3092\:8a55\:4fa1\:305b\:3088)\:3002\n" <>
    "1.0=\:660e\:78ba\:306b\:30aa\:30fc\:30ca\:30fc\:500b\:4eba\:5b9b\:306e\:76f4\:63a5\:4f9d\:983c/\:8981\:8acb(\:8b1b\:6f14\:4f9d\:983c\:3001\:67fb\:8aad\:4f9d\:983c\:3001\:4f1a\:8b70\:65e5\:7a0b\:8abf\:6574\:3001\:6295\:7a3f\:4f9d\:983c\:3001\:8cea\:554f\:306a\:3069)\:30010.7=\:5bfe\:5fdc\:30fb\:8fd4\:4fe1\:304c\:671b\:307e\:3057\:3044\:9023\:7d61\:30010.4=\:78ba\:8a8d/\:627f\:8a8d\:3092\:6c42\:3081\:308b\:9023\:7d61\:30010.2=\:60c5\:5831\:5171\:6709\:30fb\:5831\:544a\:3067\:5bfe\:5fdc\:4e0d\:8981\:30010.0=\:4e00\:6589\:914d\:4fe1/\:5e83\:544a/\:901a\:77e5/SPAM\:3002\n\n" <>
    "== PRIVACY ==\n\:79d8\:533f\:5ea6\:3092 0.0\:301c1.0 \:306e\:6570\:5024\:30671\:3064\:51fa\:529b\:3002\:3053\:308c\:306f\:30af\:30e9\:30a6\:30c9LLM\:3067\:51e6\:7406\:3057\:3066\:3088\:3044\:304b\:306e\:6307\:6a19\:3002" <>
    "0.5\:4ee5\:4e0b\:306a\:3089\:30af\:30e9\:30a6\:30c9\:53ef\:30021.0=\:4eba\:4e8b/\:6210\:7e3e/\:500b\:4eba\:60c5\:5831\:30010.8=\:7d44\:7e54\:5185\:90e8\:306e\:5185\:90e8\:9023\:7d61\:30010.5=\:7d44\:7e54\:5185\:53ef\:8996\:3067\:554f\:984c\:306a\:3057\:3001" <>
    "0.4=\:5916\:90e8\:306e\:77e5\:4eba\:304c\:898b\:3066\:3082\:554f\:984c\:306a\:3044\:30010.0=\:3069\:3053\:306b\:958b\:793a\:3057\:3066\:3082\:554f\:984c\:306a\:3044\:65e2\:77e5\:306e\:5185\:5bb9\:3002\n\n" <>
    "== CATEGORY ==\nfrom \:304b\:3089 to \:3078\:306e\:4f1d\:9054\:306e\:7a2e\:985e\:3092\:3001\:6b21\:306e\:30c8\:30fc\:30af\:30f3\:304b\:30891\:3064\:3060\:3051\:51fa\:529b\:3002\n" <>
    "TaskRequest=\:4f5c\:696d\:30fb\:4ed5\:4e8b\:306e\:4f9d\:983c(\:67fb\:8aad\:3001\:539f\:7a3f\:30fb\:66f8\:985e\:306e\:63d0\:51fa\:3001\:8abf\:67fb\:30fb\:5bfe\:5fdc\:306e\:4f9d\:983c\:306a\:3069)\:3001" <>
    "AttendanceRequest=\:4f1a\:8b70\:30fb\:884c\:4e8b\:7b49\:3078\:306e\:51fa\:5e2d\:4f9d\:983c/\:65e5\:7a0b\:8abf\:6574\:3001" <>
    "Confirmation=\:78ba\:8a8d\:30fb\:627f\:8a8d\:3092\:6c42\:3081\:308b\:9023\:7d61\:3001" <>
    "InfoProvision=\:60c5\:5831\:63d0\:4f9b\:30fb\:6848\:5185\:3001Report=\:7d50\:679c\:30fb\:72b6\:6cc1\:306e\:5831\:544a\:3001" <>
    "Notice=\:6a5f\:68b0\:7684\:306a\:901a\:77e5\:30fb\:4e00\:6589\:914d\:4fe1\:30fb\:5e83\:544a\:3001Other=\:305d\:306e\:4ed6\:3002\n" <>
    "\:5b9b\:5148\:304c\:30aa\:30fc\:30ca\:30fc\:306e\:6240\:5c5e\:30b0\:30eb\:30fc\:30d7(\:90e8\:7f72ML\:7b49)\:3067\:3042\:3063\:3066\:3082\:3001\:5185\:5bb9\:304c\:4f9d\:983c\:306a\:3089 TaskRequest \:307e\:305f\:306f AttendanceRequest \:3068\:5224\:5b9a\:3059\:308b\:3002\n\n" <>
    "== DEADLINE ==\n\:3006\:5207\:30fb\:671f\:9650(\:63d0\:51fa\:671f\:9650\:3001\:56de\:7b54\:671f\:9650\:3001\:7533\:8fbc\:671f\:9650\:3001\:51fa\:6b20\:56de\:7b54\:671f\:9650\:306a\:3069)\:304c\:672c\:6587\:306b\:3042\:308c\:3070\:3001" <>
    "\:30e1\:30fc\:30eb\:306e date \:3092\:57fa\:6e96\:306b\:300c\:6765\:9031\:6708\:66dc\:300d\:7b49\:306e\:76f8\:5bfe\:8868\:73fe\:3082\:7d76\:5bfe\:65e5\:6642\:3078\:5909\:63db\:3057\:3066\:3001YYYY-MM-DD \:307e\:305f\:306f YYYY-MM-DD HH:MM \:306e\:5f62\:5f0f\:3067\:51fa\:529b\:3002" <>
    "\:3006\:5207\:304c\:7121\:3051\:308c\:3070 NONE \:3068\:3060\:3051\:51fa\:529b\:3002\:4f1a\:8b70\:958b\:50ac\:65e5\:6642\:305d\:306e\:3082\:306e\:306f\:3006\:5207\:3067\:306f\:306a\:3044\:304c\:3001\:51fa\:6b20\:56de\:7b54\:671f\:9650\:306f\:3006\:5207\:3067\:3042\:308b\:3002\n\n" <>
    "== SUMMARY ==\n\:8981\:7d04\:30921\:884c\:3067\:51fa\:529b\:3002\:5f62\:5f0f\:300c\:3014\:30ab\:30c6\:30b4\:30ea\:3015\:5185\:5bb9\:306e\:8981\:7d04\:3014\:95a2\:4fc2\:8005\:3015\:300d\:3002" <>
    "\:30ab\:30c6\:30b4\:30ea\:306f \:4f9d\:983c/\:78ba\:8a8d/\:5831\:544a/\:60c5\:5831/\:96d1\:52d9/\:3006\:5207 \:304b\:3089\:6700\:9069\:306a\:3082\:306e\:3092\:9078\:3076\:3002\n\n" <>
    "== \:51fa\:529b\:5f62\:5f0f ==\n\:4ee5\:4e0b\:306e5\:884c\:306e\:307f\:3092\:51fa\:529b\:3002\:4ed6\:306e\:30c6\:30ad\:30b9\:30c8\:306f\:4e00\:5207\:4e0d\:8981\:3002\n" <>
    "WORKREQUEST: <\:6570\:5024>\nPRIVACY: <\:6570\:5024>\nCATEGORY: <\:30c8\:30fc\:30af\:30f3>\nDEADLINE: <YYYY-MM-DD[ HH:MM] \:307e\:305f\:306f NONE>\nSUMMARY: <\:8981\:7d04\:6587>\n\n[\:30e1\:30fc\:30eb]\n" <> fld];

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

(* ---- \:91cd\:8981\:5ea6\:306e\:69cb\:9020\:7684\:8a08\:7b97: \:30b0\:30eb\:30fc\:30d7\:91cd\:307f config + To/Cc \:4f4d\:7f6e + ML \:5224\:5b9a + LLM \:4f9d\:983c\:5ea6 ---- *)
(* \:30b0\:30eb\:30fc\:30d7\:91cd\:307f config (\:6c38\:7d9a\:5316\:3001\:30e1\:30fc\:30eb\:30a2\:30ab\:30a6\:30f3\:30c8\:3068\:540c\:3058 vault config \:65b9\:5f0f) *)
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

(* \:69cb\:9020\:30b7\:30b0\:30ca\:30eb *)
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

(* \:53d7\:4fe1\:8005\:30d9\:30fc\:30b9\:306e\:6c7a\:5b9a\:7684 privacy \:30d5\:30ed\:30a2 (defense-in-depth)\:3002\:30aa\:30fc\:30ca\:30fc\:304c\:76f4\:63a5\:306e To/Cc \:53d7\:4fe1\:8005\:3067\:3001
   \:975e bulk\:30fb\:5c11\:6570\:5b9b\:306e\:30e1\:30fc\:30eb = \:500b\:4eba/\:5c0f\:30b0\:30eb\:30fc\:30d7\:901a\:4fe1\:3068\:307f\:306a\:3057 PrivacyLevel \:306e\:4e0b\:9650\:3092\:4fdd\:8a3c\:3059\:308b\:3002
   LLM \:63a8\:8ad6\:304c\:500b\:4eba\:30e1\:30fc\:30eb\:306e privacy \:3092\:4e0b\:3052\:904e\:304e\:3066\:3082 gate \:5074 (cloud) \:306b\:6f0f\:308c\:306b\:304f\:304f\:3059\:308b\:3002
   ML/\:4e00\:6589\:914d\:4fe1\:306f\:30aa\:30fc\:30ca\:30fc\:304c To/Cc \:306b\:5165\:3089\:305a position="Bulk" \:306b\:306a\:308b\:306e\:3067 floor \:5bfe\:8c61\:5916\:3002
   owner \:672a\:8a2d\:5b9a (position="Unknown") \:3084 bulk\:30fb\:591a\:6570\:5b9b\:306f 0.0 (floor \:306a\:3057)\:3002 *)
iSVMDRecipientPrivacyFloor[snap_Association] :=
  Module[{md, pos, nRecip},
    If[$SourceVaultMailPersonalPrivacyFloor <= 0. || iSVMDBulkQ[snap], Return[0.]];
    pos = iSVMDOwnerPosition[snap];
    If[! MemberQ[{"To", "Cc"}, pos], Return[0.]];
    md = Lookup[snap, "MailMetadataPublic", <||>];
    nRecip = Length[SourceVaultMailParseEmails[ToString@Lookup[md, "To", ""]]] +
       Length[SourceVaultMailParseEmails[ToString@Lookup[md, "Cc", ""]]];
    If[1 <= nRecip <= $iSVMDPersonalRecipientMax, N@$SourceVaultMailPersonalPrivacyFloor, 0.]];

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
    (* LLM \:30ab\:30c6\:30b4\:30ea Notice (\:6a5f\:68b0\:7684\:901a\:77e5\:30fb\:4e00\:6589\:914d\:4fe1\:30fb\:5e83\:544a) \:306f\:5f37\:3044\:6e1b\:70b9\:3002
       DM \:306f\:30aa\:30fc\:30ca\:30fc\:500b\:4eba\:304c To \:306b\:5165\:308b\:305f\:3081 posAdj +0.15 \:304c\:5e83\:544a\:3092\:6301\:3061\:4e0a\:3052\:3066\:3057\:307e\:3046
       (\:672a\:77e5\:9001\:4fe1\:8005 0.4 + To 0.15 = 0.55)\:3002Notice -0.30 \:3067 0.25 \:306b\:843d\:3068\:3059\:3002
       \:4ed6\:30ab\:30c6\:30b4\:30ea\:306f WorkRequest \:304c\:65e2\:306b\:53cd\:6620\:3059\:308b\:306e\:3067\:52a0\:6e1b\:70b9\:3057\:306a\:3044\:3002 *)
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

(* \:512a\:5148\:5ea6\:5f0f\:306e\:5909\:66f4\:3092\:65e2\:51e6\:7406 snapshot \:306b\:53cd\:6620\:3059\:308b (LLM \:4e0d\:8981\:30fb\:9ad8\:901f)\:3002
   \:5bfe\:8c61\:306f PriorityComponents \:3092\:6301\:3064\:3082\:306e = \:904e\:53bb\:306b\:69cb\:9020\:8a08\:7b97\:3067 Priority \:3092\:51fa\:3057\:305f\:3082\:306e\:3002
   legacy maildb \:7531\:6765\:306e Priority (PriorityComponents \:7121\:3057) \:306f\:6709\:610f\:306a\:5225\:30bd\:30fc\:30b9\:306a\:306e\:3067\:89e6\:3089\:306a\:3044\:3002 *)
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

(* snapshot \:306b\:6d3e\:751f\:7d50\:679c\:3092\:9069\:7528\:3002\:512a\:5148\:5ea6\:306f\:69cb\:9020\:7684\:306b\:8a08\:7b97(LLM \:306f WorkRequest \:306e\:307f)\:3002 *)
iSVApplyDerived[snap_Association, res_Association] :=
  Module[{d = Lookup[snap, "Derived", <||>], s2 = snap, wr, cp, ct},
    (* \:65e7 LLM \:306e Priority \:306f WorkRequest \:306e\:4ee3\:7406\:3068\:3057\:3066\:6271\:3046(\:5f8c\:65b9\:4e92\:63db) *)
    wr = Lookup[res, "WorkRequest", Lookup[res, "Priority", Missing[]]];
    (* \:30ab\:30c6\:30b4\:30ea\:306f\:8a9e\:5f59\:3078\:6b63\:898f\:5316\:3057\:3066\:4fdd\:5b58 (\:6ce8\:5165 Inferencer \:306e\:65e5\:672c\:8a9e\:5024\:3082\:53d7\:3051\:308b)\:3002
       \:512a\:5148\:5ea6\:8a08\:7b97\:306b\:3082\:6e21\:3059 (Notice = DM/\:4e00\:6589\:914d\:4fe1 \:306f\:6e1b\:70b9)\:3002 *)
    ct = iSVMDNormalizeCategory[Lookup[res, "Category", Missing[]]];
    cp = SourceVaultMailComputePriority[snap, wr, If[StringQ[ct], ct, Missing[]]];
    d["Priority"] = cp["Priority"];
    d["PriorityComponents"] = cp["Components"];
    If[NumericQ[wr], d["WorkRequest"] = N@Clip[wr, {0., 1.}]];
    (* LLM \:63a8\:8ad6 PL \:306b\:53d7\:4fe1\:8005\:30d9\:30fc\:30b9\:306e\:6c7a\:5b9a\:7684\:30d5\:30ed\:30a2\:3092 additive(Max)\:9069\:7528=\:500b\:4eba\:30e1\:30fc\:30eb\:306e\:904e\:5c0f privacy \:3092\:9632\:3050 *)
    If[NumericQ[res["PrivacyLevel"]],
      d["PrivacyLevel"] = Max[res["PrivacyLevel"], iSVMDRecipientPrivacyFloor[snap]]];
    If[StringQ[ct], d["Category"] = ct];
    (* \:3006\:5207\:306f\:30ad\:30fc\:304c\:5728\:308b\:3068\:304d\:3060\:3051\:66f4\:65b0: \:518d\:51e6\:7406\:3067\:300c\:3006\:5207\:306a\:3057\:300d\:306b\:306a\:308c\:3070 Missing \:3067\:4e0a\:66f8\:304d\:3001
       Deadline \:975e\:5bfe\:5fdc\:306e\:65e7 Inferencer \:3067\:306f\:65e2\:5b58\:5024\:3092\:4fdd\:6301\:3002 *)
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

(* ---- mailspec enricher \:767b\:9332 (\:62e1\:5f35\:30dd\:30a4\:30f3\:30c8) ----
   \:30b5\:30de\:30ea\:30fc\:4f5c\:6210 (\:6d3e\:751f) \:306e\:3068\:304d\:3060\:3051\:547c\:3070\:308c\:308b\:3002\:767b\:9332\:304c\:7121\:3051\:308c\:3070\:5b8c\:5168\:7d20\:901a\:3057\:3067
   SourceVault \:5358\:4f53\:306e\:52d5\:4f5c\:306f\:5909\:308f\:3089\:306a\:3044\:3002enricher \:304c\:672c\:6587\:3092\:62e1\:5f35\:3057\:3066\:3082\:4fdd\:5b58
   \:30ec\:30b3\:30fc\:30c9\:306f\:6a19\:6e96\:5f62\:5f0f\:306e\:307e\:307e (Derived.DerivedEnrichment \:306b\:540d\:524d\:304c\:4ed8\:304f\:306e\:307f\:3002
   \:6697\:53f7\:5316\:6e08\:307f body \:306f\:5909\:66f4\:3057\:306a\:3044)\:3002 *)
If[! AssociationQ[$iSVMDMailspecEnrichers], $iSVMDMailspecEnrichers = <||>];

SourceVaultRegisterMailspecEnricher[name_String, f_] :=
  (AssociateTo[$iSVMDMailspecEnrichers, name -> f];
   <|"Status" -> "Registered", "Name" -> name|>);
SourceVaultUnregisterMailspecEnricher[name_String] :=
  ($iSVMDMailspecEnrichers = KeyDrop[$iSVMDMailspecEnrichers, name];
   <|"Status" -> "Unregistered", "Name" -> name|>);
SourceVaultMailspecEnrichers[] := Keys[$iSVMDMailspecEnrichers];

(* --- post-fetch hook: SourceVaultMailFetchNew \:5b8c\:4e86\:6642\:306b f[mbox, fetchResult] \:3092\:547c\:3076\:3002
   \:53d6\:308a\:8fbc\:307f\:5f8c\:306e\:6d3e\:751f\:51e6\:7406 (mining \:306e\:8457\:8005\:62bd\:51fa\:306a\:3069) \:3092 maildb \:306b\:4f9d\:5b58\:3055\:305b\:305a\:306b\:7d50\:7dda\:3059\:308b\:305f\:3081\:306e\:62e1\:5f35\:70b9\:3002
   hook \:306e\:5931\:6557\:306f fetch \:3092\:58ca\:3055\:306a\:3044 (Quiet@Check)\:3002\:672a\:767b\:9332\:306a\:3089\:5b8c\:5168\:7d20\:901a\:3057\:3002 *)
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

(* \:6d3e\:751f\:30ec\:30b3\:30fc\:30c9\:306b enrichment \:540d\:3092\:8a18\:9332 (\:900f\:660e\:6027\:306e\:305f\:3081\:306e\:8ffd\:52a0\:30ad\:30fc\:306e\:307f) *)
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
      (* \:8981\:7d04\:30fb\:30ab\:30c6\:30b4\:30ea\:30fb\:3006\:5207\:306a\:3069\:306e\:6d3e\:751f\:306f\:8aad\:3081\:308b\:5e73\:6587\:304b\:3089 (\:65e7 snapshot \:306e\:751f HTML \:5bfe\:7b56\:3002
         \:65b0 ingest \:306f\:65e2\:306b readable \:306a\:306e\:3067\:51aa\:7b49)\:3002 *)
      "body" -> If[Lookup[bodyR, "Status", ""] === "Ok", iSVUIReadableBody[bodyR["Body"]], ""],
      "_bodyStatus" -> Lookup[bodyR, "Status", "Error"]|>;
    iSVMDEnrichMailspec[spec, snap]];

Options[SourceVaultInferMailDerivedBatch] = {
   "MBox" -> Automatic, "Limit" -> 50, "DateFrom" -> Automatic, "DateTo" -> Automatic,
   "Refresh" -> None,
   "Inferencer" -> Automatic, "CheckpointEvery" -> 20, "Persist" -> True};

SourceVaultInferMailDerivedBatch[OptionsPattern[]] :=
  Module[{infer, lim, ck, persist, pendBefore, batch, pend, df, dt, ref, mb,
      done = 0, failBody = 0, failLLM = 0, sinceCk = 0},
    infer = OptionValue["Inferencer"] /. Automatic -> SourceVaultMailInferDerived;
    lim = OptionValue["Limit"]; ck = OptionValue["CheckpointEvery"];
    persist = TrueQ[OptionValue["Persist"]];
    mb = OptionValue["MBox"];
    (* \:65e5\:4ed8\:7bc4\:56f2\:30d5\:30a3\:30eb\:30bf (\:4efb\:610f)\:3002SourceVaultSearchMailSnapshots \:3068\:540c\:3058
       iSVMDDayListOf / iSVMDDateInRange \:3092\:4f7f\:3044\:3001DateObject/\:6587\:5b57\:5217/{y,m,d} \:3092
       \:65e5\:5358\:4f4d\:3067\:5305\:542b\:6bd4\:8f03\:3059\:308b\:3002Limit \:306f\:30d5\:30a3\:30eb\:30bf\:5f8c\:306b\:9069\:7528\:3055\:308c\:308b\:4ef6\:6570\:4e0a\:9650\:3002
       \:7bc4\:56f2\:5185\:3059\:3079\:3066\:3092\:51e6\:7406\:3059\:308b\:306b\:306f "Limit" -> Infinity \:3092\:6307\:5b9a\:3059\:308b\:3002 *)
    df = iSVMDDayListOf[OptionValue["DateFrom"]];
    dt = iSVMDDayListOf[OptionValue["DateTo"]];
    (* "Refresh": None=Pending \:306e\:307f (\:65e2\:5b9a)\:3002"MissingCategory"=Category \:672a\:751f\:6210\:306e
       Processed \:3082\:5bfe\:8c61 (Category/Deadline \:5c0e\:5165\:524d\:306b\:51e6\:7406\:6e08\:307f\:306e\:65e7 snapshot \:306e\:5f8c\:57cb\:3081\:7528)\:3002
       All=\:30ed\:30fc\:30c9\:6e08\:307f\:5168\:4ef6\:3092\:518d\:51e6\:7406\:3002Function=\:8ff0\:8a9e\:306b\:4e00\:81f4\:3059\:308b snapshot \:3092\:518d\:51e6\:7406
       (\:4f8b: Cerezo \:901a\:77e5\:3060\:3051\:30ea\:30f3\:30af\:5148\:8fbc\:307f\:3067\:518d\:6d3e\:751f)\:3002 *)
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
    (* "MBox": \:6587\:5b57\:5217\:306a\:3089\:305d\:306e mbox \:306e snapshot \:306b\:9650\:5b9a (Refresh \:3067\:9078\:3093\:3060\:96c6\:5408\:3078\:306e\:76f4\:4ea4\:5f8c\:30d5\:30a3\:30eb\:30bf)\:3002
       SourceVaultSearchMailSnapshots \:3068\:540c\:3058 #["MailSource"]["MBox"] \:30d1\:30b9\:3067\:5224\:5b9a\:3059\:308b\:3002 *)
    If[StringQ[mb], pend = Select[pend, Lookup[#["MailSource"], "MBox", Null] === mb &]];
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
      "RemainingPending" -> Length[
        If[StringQ[mb], SourceVaultMailDerivedPending["MBox" -> mb],
           SourceVaultMailDerivedPending[]]]|>];

(* ---- \:65e2\:5b58 snapshot \:306e HTML \:672c\:6587\:3092\:8aad\:3081\:308b\:5e73\:6587\:3078 backfill ----
   ingest \:6642\:30c6\:30ad\:30b9\:30c8\:5316\:3092\:5c0e\:5165\:3059\:308b\:524d\:306b\:53d6\:308a\:8fbc\:3093\:3060\:30e1\:30fc\:30eb\:304c\:5bfe\:8c61\:3002\:672c\:6587\:3092\:5fa9\:53f7\:3057\:3001HTML \:306a\:3089
   \:30c6\:30ad\:30b9\:30c8\:5316\:3057\:3066\:518d\:6697\:53f7\:5316\:683c\:7d0d (\:539f\:6587\:306f BodyRaw \:306b\:6e29\:5b58)\:3001BodyWasHTML \:30d5\:30e9\:30b0\:3092\:7acb\:3066\:308b\:3002
   \:5e73\:6587\:30e1\:30fc\:30eb\:306f\:89e6\:3089\:306a\:3044\:3002\:51aa\:7b49 (BodyWasHTML \:6e08\:307f / \:5e73\:6587\:306f skip)\:3002 *)
Options[SourceVaultBackfillMailBodies] =
  {"Limit" -> Infinity, "DryRun" -> False, "Persist" -> True, "CheckpointEvery" -> 20};
SourceVaultBackfillMailBodies[OptionsPattern[]] :=
  Module[{lim, dry, persist, ck, all, candidates, batch,
      done = 0, failBody = 0, failEnc = 0, skipped = 0, sinceCk = 0},
    lim = OptionValue["Limit"]; dry = TrueQ[OptionValue["DryRun"]];
    persist = TrueQ[OptionValue["Persist"]]; ck = OptionValue["CheckpointEvery"];
    all = SourceVaultMailSnapshotList[];
    (* \:65e2\:306b BodyWasHTML \:6e08\:307f\:306f\:5bfe\:8c61\:5916 *)
    candidates = Select[all,
      ! TrueQ[Lookup[Lookup[#, "MailMetadataPublic", <||>], "BodyWasHTML", False]] &];
    batch = If[IntegerQ[lim] && lim >= 0, Take[candidates, UpTo[lim]], candidates];
    Do[
      Module[{bodyR, raw, readable, pl, put, snap2, pr, md},
        bodyR = SourceVaultMailSnapshotDecryptBody[snap];
        If[Lookup[bodyR, "Status", ""] =!= "Ok", failBody++; Continue[]];
        raw = bodyR["Body"];
        (* \:5e73\:6587\:30e1\:30fc\:30eb\:306f\:5909\:63db\:4e0d\:8981 (\:89e6\:3089\:306a\:3044) *)
        If[! iSVUILooksLikeHTML[iSVUINormalizeNewlines[raw]], skipped++; Continue[]];
        If[dry, done++; Continue[]];
        readable = iSVUIHtmlToText[raw];
        pl = With[{p = Lookup[Lookup[snap, "Derived", <||>], "PrivacyLevel", Automatic]},
          If[NumericQ[p], p, $SourceVaultDefaultImportedMailPL]];
        put = SourceVault`SourceVaultEncryptedPut[
          <|"Body" -> readable, "BodyRaw" -> raw|>,
          "PrivacyLevel" -> pl, "ContentType" -> "MailBody", "Persist" -> False,
          "SensitiveFields" -> {"Body", "BodyRaw"}];
        If[Lookup[put, "Status", ""] =!= "Stored", failEnc++; Continue[]];
        snap2 = snap;
        pr = snap2["PayloadRefs"]; pr["Body"] = put["Record"]; snap2["PayloadRefs"] = pr;
        md = snap2["MailMetadataPublic"]; md["BodyWasHTML"] = True;
        snap2["MailMetadataPublic"] = md;
        SourceVaultMailSnapshotPut[snap2, "Persist" -> False];
        done++; sinceCk++;
        If[persist && sinceCk >= ck, SourceVaultMailStoreSave["All" -> False]; sinceCk = 0]],
      {snap, batch}];
    If[! dry && persist && sinceCk > 0, SourceVaultMailStoreSave["All" -> False]];
    <|"Status" -> "Ok", "Candidates" -> Length[candidates], "Selected" -> Length[batch],
      "Converted" -> done, "SkippedPlain" -> skipped,
      "FailedBodyDecrypt" -> failBody, "FailedEncrypt" -> failEnc, "DryRun" -> dry|>];

(* \:300c<mbox>\:306e\:65b0\:7740\:30e1\:30fc\:30eb\:306b\:30b5\:30de\:30ea\:30fc\:3092\:8ffd\:52a0\:300d\:306e\:6b63\:6e961\:95a2\:6570\:3002EnsureLoaded(\:30b9\:30b3\:30fc\:30d7\:78ba\:5b9a)\[RightArrow]
   \:305d\:306e mbox \:306e\:672a\:51e6\:7406\:3060\:3051\:3092\:30d0\:30c3\:30c1\:8981\:7d04\:30fb\:6c38\:7d9a\:5316\:3001\:3092\:5185\:5305\:3059\:308b\:3002
   \:91cd\:8981: \:5916\:90e8 WolframScript \:30b8\:30e7\:30d6\:3078\:9000\:907f\:3055\:308c\:305f\:3068\:304d\:3001\:5b50\:30d7\:30ed\:30bb\:30b9\:306f\:30e1\:30fc\:30eb\:30b9\:30c8\:30a2\:304c\:7a7a
   \:304b\:3089\:59cb\:307e\:308b (SourceVaultMailDerivedPending[]=0)\:3002EnsureLoaded \:3092\:5f0f\:306e\:5916\:3067\:6e08\:307e\:305b\:3066
   \:30d0\:30c3\:30c1\:3060\:3051\:3092\:5916\:90e8\:5316\:3059\:308b\:3068 0 \:4ef6\:51e6\:7406\:3067\:7d42\:308f\:308b\:3002\:672c\:95a2\:6570\:306f\:4e21\:8005\:30921\:5f0f\:306b\:9589\:3058\:8fbc\:3081\:308b\:306e\:3067\:3001
   \:63d0\:6848\:304c `SourceVaultMailAddSummaries["univ","Latest"]` \:5358\:4f53\:3067\:3082\:5916\:90e8\:30d7\:30ed\:30bb\:30b9\:3067
   \:81ea\:5df1\:5b8c\:7d50\:3057\:3066\:30ed\:30fc\:30c9\[RightArrow]\:8981\:7d04\:307e\:3067\:8d70\:308b\:3002mbox \:7d5e\:308a\:306f\:6b63\:3057\:3044\:30d1\:30b9 #["MailSource"]["MBox"] \:3092\:4f7f\:3046\:3002 *)
Options[SourceVaultMailAddSummaries] =
  {"Limit" -> Infinity, "Persist" -> True, "CheckpointEvery" -> 3};
SourceVaultMailAddSummaries[mbox_String, period_ : "Latest",
    OptionsPattern[]] :=
  Module[{ensured, result},
    ensured = SourceVaultMailEnsureLoaded[mbox, period];
    result = SourceVaultInferMailDerivedBatch[
      (* \:65e2\:5b9a Refresh=None (=Pending \:306e\:307f) \:3092 mbox \:3067\:7d5e\:308b\:3002MBox \:5f8c\:30d5\:30a3\:30eb\:30bf\:306f
         #["MailSource"]["MBox"] \:3067\:5224\:5b9a\:3057\:3001\:4ed6 mbox \:306e\:672a\:51e6\:7406\:3092\:5dfb\:304d\:8fbc\:307e\:306a\:3044\:3002 *)
      "MBox"    -> mbox,
      "Limit"   -> OptionValue["Limit"],
      "Persist" -> OptionValue["Persist"],
      (* \:540c\:671f\:5b9f\:884c\:304c\:6253\:3061\:5207\:3089\:308c\:3066\:3082\:9032\:6357\:304c\:6b8b\:308b\:3088\:3046\:983b\:7e41\:306b\:4fdd\:5b58 (\:65e2\:5b9a 3 \:4ef6\:3054\:3068)\:3002 *)
      "CheckpointEvery" -> OptionValue["CheckpointEvery"]];
    <|"Status" -> "Ok", "MBox" -> mbox, "Period" -> period,
      "Loaded" -> ensured, "Batch" -> result|>];

(* ---- \:5b9f IMAP source (Python imaplib \:7d4c\:7531) ---- *)
(* Period \:53d7\:7406\:5f62\:5f0f:
   "Latest"(\:76f4\:8fd114\:65e5) / n(\:76f4\:8fd1n\:65e5, \:6574\:6570) /
   {\:5e74, \:6708}(\:305d\:306e\:6708) / {\:5e74, \:6708, \:65e5}(\:305d\:306e\:65e5) / {from, to}(\:660e\:793a ISO \:7bc4\:56f2) /
   "YYYYMM"(\:305d\:306e\:6708) / "YYYY"(\:305d\:306e\:5e74) *)
iSVIMAPFmt[d_] := DateString[d, {"Year", "-", "Month", "-", "Day"}];
iSVIMAPDateRange[period_] :=
  Module[{today = DateObject[Take[DateList[], 3]]},
    Which[
      period === "Latest", {iSVIMAPFmt[DatePlus[today, {-14, "Day"}]], iSVIMAPFmt[DatePlus[today, {1, "Day"}]]},
      IntegerQ[period], {iSVIMAPFmt[DatePlus[today, {-period, "Day"}]], iSVIMAPFmt[DatePlus[today, {1, "Day"}]]},
      MatchQ[period, {_Integer, _Integer}],   (* {\:5e74, \:6708} -> \:305d\:306e\:6708 *)
        With[{s = DateObject[{period[[1]], period[[2]], 1}]},
          {iSVIMAPFmt[s], iSVIMAPFmt[DatePlus[s, {1, "Month"}]]}],
      MatchQ[period, {_Integer, _Integer, _Integer}],  (* {\:5e74, \:6708, \:65e5} -> \:305d\:306e\:65e5 *)
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

(* \:6dfb\:4ed8\:306e\:89aa\:30eb\:30fc\:30c8 ($SourceVaultLegacyMailRoot \:306f\:65e2\:5b9a\:5024\:306a\:3057\:306e\:7d20\:30b7\:30f3\:30dc\:30eb\:306a\:306e\:3067
   \:6587\:5b57\:5217\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af\:3092\:81ea\:524d\:3067\:6301\:3064\:3002mailui \:306e iSVUILegacyRoot \:3068\:540c\:30ed\:30b8\:30c3\:30af)\:3002 *)
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
         " \[LongDash] SourceVaultRegisterMailAccount \:3067\:767b\:9332\:3057\:3066\:304f\:3060\:3055\:3044"|>}]];
    pw = Quiet@Check[ToString[SystemCredential[acct["CredKey"]]], "$Failed"];
    If[pw === "" || pw === "Null" || pw === "$Failed" || StringContainsQ[pw, "Missing"],
      Return[{<|"_error" -> "NoCredential: SystemCredential[\"" <> acct["CredKey"] <> "\"] \:672a\:8a2d\:5b9a"|>}]];
    range = iSVIMAPDateRange[Lookup[srcOpts, "Period", "Latest"]];
    attBase = FileNameJoin[{iSVIMAPLegacyRoot[], mbox}];
    If[! StringQ[attBase], Return[{<|"_error" -> "AttachmentRootUnresolved"|>}]];
    session = Quiet@Check[StartExternalSession["Python"], $Failed];
    If[Head[session] =!= ExternalSessionObject,
      Return[{<|"_error" -> "PythonSessionFailed: ExternalEvaluate[\"Python\"] \:4e0d\:53ef (Python \:767b\:9332\:8981\:78ba\:8a8d)"|>}]];
    code = iSVBuildPython[acct["Server"], acct["Port"], acct["User"], pw,
       range[[1]], range[[2]], attBase, Lookup[srcOpts, "MaxEmails", Automatic]];
    res = Quiet@Check[ExternalEvaluate[session, code], $Failed];
    Quiet@DeleteObject[session];
    If[! ListQ[res], Return[{<|"_error" -> "PythonEvalFailed"|>}]];
    (* python \:306f dict \:306e\:30ea\:30b9\:30c8\:3092\:8fd4\:3059 -> WL Association \:5316\:3001\:30ad\:30fc\:540d\:306f maildb \:4e92\:63db *)
    (Association[#] & /@ Select[res, AssociationQ]) /.
       r_Association :> KeyMap[ToString, r]];

iSVBuildPython[server_, port_, user_, pw_, since_, before_, attBase_, maxN_] :=
  Module[{maxLine},
    (* try \:30d6\:30ed\:30c3\:30af\:5185 (4\:30b9\:30da\:30fc\:30b9) \:306b\:633f\:5165\:3055\:308c\:308b\:306e\:3067 4\:30b9\:30da\:30fc\:30b9\:5b57\:4e0b\:3052\:30028\:30b9\:30da\:30fc\:30b9\:3060\:3068 IndentationError \:3067 script \:5168\:4f53\:304c PythonEvalFailed \:306b\:306a\:308b *)
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

(* ---- fetch \:30a8\:30f3\:30c8\:30ea ---- *)
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
    iSVMDIdentityEnsureLoaded[];  (* \:8b58\:5225\:5b50\:3092\:4e0a\:66f8\:304d\:3057\:306a\:3044\:3088\:3046\:5148\:306b load *)
    (* \:53d6\:308a\:8fbc\:307f\:5bfe\:8c61\:6708\:306e\:65e2\:5b58\:30b7\:30e3\:30fc\:30c9\:3092\:5148\:306b\:30ed\:30fc\:30c9\:3059\:308b\:3002
       \:672a\:30ed\:30fc\:30c9\:306e\:307e\:307e put -> save \:3059\:308b\:3068 iSVMDWriteShard \:306f in-memory \:306e
       $iSVMDShardMembers (=\:65b0\:7740\:306e\:307f) \:3067\:305d\:306e\:6708\:306e\:30b7\:30e3\:30fc\:30c9\:30d5\:30a1\:30a4\:30eb\:5168\:4f53\:3092\:518d\:751f\:6210\:3057\:3001
       \:65e2\:5b58\:30e1\:30fc\:30eb\:306e\:8981\:7d04 (Derived) \:3054\:3068\:4e0a\:66f8\:304d\:6d88\:5931\:3055\:305b\:3066\:3057\:307e\:3046\:3002\:5148\:8aad\:307f\:3057\:3066\:304a\:3051\:3070
       \:65e2\:5b58\:30e1\:30fc\:30eb\:304c store/members \:306b\:4e57\:308a\:3001\:30b7\:30e3\:30fc\:30c9\:66f8\:304d\:623b\:3057\:3067\:4fdd\:5168\:3055\:308c\:308b\:3002
       (\:5b58\:5728\:3057\:306a\:3044\:6708/unknown \:306f\:30d5\:30a1\:30a4\:30eb\:304c\:7121\:3044\:306e\:3067 no-op\:3002) *)
    Module[{shardKeys},
      shardKeys = DeleteDuplicates[iSVMDShardKeyForMsg[mbox, #] & /@ msgs];
      Scan[
        Function[sk,
          If[! TrueQ[Lookup[$iSVMDLoadedShards, sk, False]],
            Quiet@Check[SourceVaultMailLoadShard[sk], 0]]],
        shardKeys]];
    overwrite = TrueQ[OptionValue["Overwrite"]];
    existsQ = ! MissingQ[SourceVaultMailSnapshotGet[
       iSVMDRecordId[mbox, ToString[Lookup[#, "id", "unknown"]]]]] &;
    newMsgs = Select[msgs, ! existsQ[#] &];
    (* Overwrite->True \:306a\:3089\:65e2\:5b58(\:540c\:4e00 RecordId)\:3082\:518d\:4fdd\:5b58\:3057\:3066\:4fee\:5fa9/\:66f4\:65b0\:3059\:308b *)
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
    (* \:53d6\:308a\:8fbc\:307f\:5b8c\:4e86\:5f8c\:30d5\:30c3\:30af (mining \:306e\:8457\:8005\:62bd\:51fa\:306a\:3069)\:3002\:5931\:6557\:3057\:3066\:3082 fetch \:306f\:6210\:529f\:6271\:3044\:3002
       \:7d50\:679c\:3092\:89b3\:6e2c\:3067\:304d\:308b\:3088\:3046 PostFetchHooks \:306b\:5404\:30d5\:30c3\:30af\:306e\:623b\:308a\:5024\:3092\:8f09\:305b\:308b (\:30d5\:30c3\:30af\:306f\:57fa\:5e95 result \:3092\:53d7\:3051\:53d6\:308b)\:3002 *)
    Append[result, "PostFetchHooks" -> iSVMDRunPostFetchHooks[mbox, result]]];

End[];
EndPackage[];


(* ::Package:: *)
(**)


(* ============================================================
   SourceVault_mailui.wl -- mail FE \:64cd\:4f5c (\:672c\:6587/\:6dfb\:4ed8/\:8fd4\:4fe1) -- \:65e7 maildb \:8e0f\:8972

   This file is encoded in UTF-8.
   Load order: ... -> SourceVault_maildb.wl -> SourceVault_messagerelease.wl
               -> SourceVault_mailui.wl

   \:30ed\:30b8\:30c3\:30af (\:672c\:6587\:5fa9\:53f7 / \:6dfb\:4ed8\:30d1\:30b9\:89e3\:6c7a / \:8fd4\:4fe1\:30c9\:30e9\:30d5\:30c8\:751f\:6210) \:306f headless \:3067\:30c6\:30b9\:30c8\:53ef\:80fd\:3002
   FE \:30e9\:30c3\:30d1 (ShowBody / OpenReplyNotebook / OpenAttachment) \:306f front end \:304c\:8981\:308b\:3002
   \:6dfb\:4ed8\:306f\:65e7 maildb \:306e <legacyRoot>/<mbox>/<yyyymm>_attachment/<name> \:306b\:5728\:308b\:3002
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultMailGetBody::usage = "SourceVaultMailGetBody[recordId] \:306f snapshot \:306e\:6697\:53f7\:5316\:672c\:6587\:3092\:5fa9\:53f7\:3057\:3066\:6587\:5b57\:5217\:3067\:8fd4\:3059\:3002";
SourceVaultMailShowBody::usage = "SourceVaultMailShowBody[recordId] \:306f\:672c\:6587\:3092\:65b0\:898f\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3067\:8868\:793a\:3059\:308b (front end)\:3002";
SourceVaultMailAttachmentDir::usage = "SourceVaultMailAttachmentDir[mbox, yyyymm] \:306f\:65e7 maildb \:6dfb\:4ed8\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:306e\:30d1\:30b9\:3092\:8fd4\:3059\:3002";
SourceVaultMailAttachments::usage = "SourceVaultMailAttachments[recordId] \:306f\:6dfb\:4ed8 {Name, Path, Exists} \:306e\:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:3002";
SourceVaultMailOpenAttachment::usage = "SourceVaultMailOpenAttachment[recordId, name] \:306f\:6dfb\:4ed8\:30d5\:30a1\:30a4\:30eb\:3092\:958b\:304f (front end / SystemOpen)\:3002";
SourceVaultMailComposeReply::usage = "SourceVaultMailComposeReply[recordId, opts] \:306f\:8fd4\:4fe1\:30c9\:30e9\:30d5\:30c8 <|To,Cc,Subject,InReplyToToken,Quoted,Body|> \:3092\:751f\:6210\:3059\:308b\:3002\"ReplyAll\"->True \:3067 Cc \:542b\:3080\:3002";
SourceVaultMailOpenReplyNotebook::usage = "SourceVaultMailOpenReplyNotebook[recordId, opts] \:306f\:8fd4\:4fe1\:7528\:30a6\:30a4\:30f3\:30c9\:30a6 (To/Cc/\:4ef6\:540d/\:672c\:6587\:7de8\:96c6\:30fb\:30d5\:30a1\:30a4\:30eb\:6dfb\:4ed8\:30fb\:78ba\:8a8d\:4ed8\:304d\:9001\:4fe1) \:3092\:958b\:304f (front end)\:3002opts: \"ReplyAll\"->True \:3067\:5168\:54e1\:306b\:8fd4\:4fe1\:3001\"Translate\"->True \:3067\:65e5\:672c\:8a9e\:3067\:66f8\:3044\:3066\:5143\:30e1\:30fc\:30eb\:306e\:8a00\:8a9e\:306b\:7ffb\:8a33\:3057\:3066\:9001\:308b (\:65e7 maildb replyMailTr \:8e0f\:8972)\:3002";
SourceVaultMailView::usage = "SourceVaultMailView[query_String:\"\", opts] \:306f\:691c\:7d22\:7d50\:679c\:3092\:3001\:884c\:3054\:3068\:306b \:672c\:6587\:8868\:793a(\:2709)/\:6dfb\:4ed8\:30dd\:30c3\:30d7\:30a2\:30c3\:30d7(\|01f4ce)/\:8fd4\:4fe1(\:21a9) \:306e\:30af\:30ea\:30c3\:30af\:64cd\:4f5c\:3092\:5099\:3048\:305f\:8868 (Dataset) \:3067\:8fd4\:3059\:3002\:65e7 maildb showMails \:8e0f\:8972\:3002";
SourceVaultMailSearchIndexView::usage = "SourceVaultMailSearchIndexView[query_String:\"\", opts] \:306f SourceVaultMailSearchIndex (sidecar \:7d22\:5f15\:691c\:7d22\:3001\:30b7\:30e3\:30fc\:30c9\:975e\:30ed\:30fc\:30c9) \:306e View \:7248\:3002\:9023\:60f3\:30ea\:30b9\:30c8\:3092 Dataset+UI \:5316\:3057\:3001\:884c\:3054\:3068\:306b \:672c\:6587(\:2709: \:5fc5\:8981\:30b7\:30e3\:30fc\:30c9\:3092\:9045\:5ef6\:30ed\:30fc\:30c9\:3057\:3066\:8868\:793a)/\:30b9\:30ec\:30c3\:30c9(\:2630: \:30a2\:30a6\:30c8\:30e9\:30a4\:30f3\:7a93) \:30dc\:30bf\:30f3\:3092\:5099\:3048\:308b\:3002\:8868\:793a\:4ef6\:6570\:306f $SourceVaultMailViewMaxRows \:3067\:5236\:9650\:3002SourceVaultMailEnsureLoaded \:4e0d\:8981 (\:7d22\:5f15 sidecar \:5fc5\:9808: \:7121\:3051\:308c\:3070 SourceVaultMailRebuildMetadataIndex[] \:3067\:69cb\:7bc9)\:3002opts \:306f SourceVaultMailSearchIndex \:3068\:540c\:3058\:3002";
SourceVaultMailThreadNotebook::usage = "SourceVaultMailThreadNotebook[recordIdOrRow, opts] \:306f\:30b9\:30ec\:30c3\:30c9\:5168\:4f53 (\:540c\:4e00\:6b63\:898f\:5316\:4ef6\:540d\:30fb\:540c\:4e00 MBox) \:3092 1 \:3064\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:7a93\:306b\:30a2\:30a6\:30c8\:30e9\:30a4\:30f3\:8868\:793a\:3059\:308b (front end)\:3002\:5404\:30e1\:30fc\:30eb = Section \:30bb\:30eb (\:65e5\:4ed8+\:5dee\:51fa\:4eba) + \:672c\:6587 Text \:30bb\:30eb\:306e\:30bb\:30eb\:30b0\:30eb\:30fc\:30d7=\:6298\:308a\:305f\:305f\:307f/\:30a2\:30a6\:30c8\:30e9\:30a4\:30f3\:64cd\:4f5c\:53ef\:3002\:7d22\:5f15 sidecar \:3067\:30e1\:30f3\:30d0\:30fc\:3092\:7279\:5b9a\:3057\:3001\:5fc5\:8981\:30b7\:30e3\:30fc\:30c9\:3060\:3051\:9045\:5ef6\:30ed\:30fc\:30c9\:3057\:3066\:672c\:6587\:5fa9\:53f7\:3002\:30bb\:30eb\:306f\:6700\:5927 PrivacyLevel \:3067\:6a5f\:5bc6\:30de\:30fc\:30af\:3002opts: \"MaxMails\"(50)\:3002\:623b\:308a\:5024 <|Status, Mails, PrivacyLevel, LoadedShards|>\:3002";
SourceVaultMailRowActions::usage = "SourceVaultMailRowActions[snapshot] \:306f1\:884c\:5206\:306e\:30a2\:30af\:30b7\:30e7\:30f3 (Body/Attachments/Reply \:30dc\:30bf\:30f3) \:3092\:8fd4\:3059\:3002";
SourceVaultMailSend::usage = "SourceVaultMailSend[spec] \:306f\:30e1\:30fc\:30eb\:3092\:9001\:4fe1\:3059\:308b\:3002spec=<|\"To\",\"Cc\",\"Bcc\",\"Subject\",\"Body\",\"Attachments\"->{\:30d1\:30b9...}|>\:3002Bcc \:3092\:7701\:7565\:3059\:308b\:3068 $SourceVaultMailSendBccSelf \:304c True \:306e\:3068\:304d\:30aa\:30fc\:30ca\:30fc\:306e\:4e3b\:30a2\:30c9\:30ec\:30b9\:5b9b\:306b\:81ea\:5206\:306e\:63a7\:3048\:3092\:9001\:308b\:3002$SourceVaultMailSignature \:304c\:975e\:7a7a\:306a\:3089\:672c\:6587\:672b\:5c3e\:306b\:7f72\:540d\:3092\:4ed8\:52a0\:3059\:308b\:3002\:8fd4\:308a\:5024 <|\"Status\"->\"Sent\"|...|> / \:5931\:6557\:6642 <|\"Status\"->\"Error\",\"Reason\"->...|>\:3002Mathematica \:306e SendMail \:8a2d\:5b9a (Preferences > Internet Connectivity > Mail Settings) \:304c\:5fc5\:8981\:3002";
SourceVaultMailTranslateBody::usage = "SourceVaultMailTranslateBody[recordId] \:306f\:30e1\:30fc\:30eb\:672c\:6587\:3092 $Language (\:8868\:793a\:8a00\:8a9e) \:306b\:7ffb\:8a33\:3057\:3066\:8fd4\:3059 (LLM, headless \:30c6\:30b9\:30c8\:53ef)\:3002\:8fd4\:308a\:5024 <|\"Status\"->\"Ok\",\"Text\"->\:8a33\:6587,\"Translated\"->True,\"Lang\"->...|>\:3002";
$SourceVaultMailSignature::usage = "$SourceVaultMailSignature \:306f\:9001\:4fe1\:30e1\:30fc\:30eb\:672c\:6587\:306e\:672b\:5c3e\:306b\:4ed8\:52a0\:3059\:308b\:7f72\:540d\:6587\:5b57\:5217\:3002\:65e2\:5b9a \"\" (\:4ed8\:52a0\:3057\:306a\:3044)\:3002";
$SourceVaultMailSendBccSelf::usage = "$SourceVaultMailSendBccSelf \:304c True (\:65e2\:5b9a) \:306e\:3068\:304d\:3001SourceVaultMailSend \:306f Bcc \:7701\:7565\:6642\:306b\:30aa\:30fc\:30ca\:30fc\:306e\:4e3b\:30e1\:30fc\:30eb\:30a2\:30c9\:30ec\:30b9\:3092 Bcc \:306b\:5165\:308c\:3001\:81ea\:5206\:306b\:63a7\:3048\:3092\:9001\:308b\:3002";
SourceVaultAddressBookView::usage = "SourceVaultAddressBookView[] \:306f\:9023\:7d61\:5148\:3092\:6574\:5f62\:8868 (Dataset) \:3067\:8868\:793a\:3059\:308b\:3002Uid/\:8868\:793a\:540d/\:304b\:306a/\:30e1\:30fc\:30eb/\:5206\:985e/\:4fe1\:983c/MaxPL/AccessTags\:3002";
SourceVaultIdentityLinkUI::usage = "SourceVaultIdentityLinkUI[opts] \:306f\:8b58\:5225\:5b50\:3092\:5b9f\:4f53\:306b\:7d10\:4ed8\:3051\:308b\:7de8\:96c6\:8868(front end)\:3002\:5404\:884c\:3067 \:65b0\:898f(\:30d8\:30c3\:30c0\:7d99\:627f\:3067\:5b9f\:4f53\:4f5c\:6210)/\:30de\:30fc\:30b8(\:65e2\:5b58\:5b9f\:4f53\:306b\:30a2\:30c9\:30ec\:30b9\:8ffd\:52a0)\:3002opts: \"ShowLinked\"(\:65e2\:5b9aFalse=\:672a\:30ea\:30f3\:30af\:306e\:307f), \"Limit\"(\:65e2\:5b9a200)\:3002";
SourceVaultEntityView::usage = "SourceVaultEntityView[] \:306f\:5b9f\:4f53(\:4eba/\:7d44\:7e54/Bot/ML)\:306e\:4e00\:89a7\:8868(Dataset)\:3002\:5404\:884c\:306b\:7de8\:96c6\:30dc\:30bf\:30f3\:3002Uid/\:7a2e\:5225/\:8868\:793a\:540d/\:304b\:306a/\:8b58\:5225\:5b50\:6570/\:30b0\:30eb\:30fc\:30d7/\:91cd\:307f/\:4fe1\:983c\:3002";
SourceVaultEntityEditUI::usage = "SourceVaultEntityEditUI[entityIdOrUid] \:306f\:5b9f\:4f531\:4ef6\:306e\:7de8\:96c6\:30d5\:30a9\:30fc\:30e0(front end)\:3002\:8868\:793a\:540d/\:7a2e\:5225/\:6f22\:5b57/\:30ed\:30fc\:30de\:5b57/\:304b\:306a/\:5206\:985e/\:30b0\:30eb\:30fc\:30d7/\:91cd\:307f/\:6240\:5c5e/\:4fe1\:983c \:3092\:7de8\:96c6\:3057\:4fdd\:5b58\:3002";
$SourceVaultLegacyMailRoot::usage = "\:65e7 maildb \:306e\:30e1\:30fc\:30eb\:30eb\:30fc\:30c8 (\:6dfb\:4ed8\:30c7\:30a3\:30ec\:30af\:30c8\:30ea\:306e\:89aa)\:3002\:65e2\:5b9a\:306f PrivateVault \:3068\:540c\:968e\:5c64\:306e udb/mails\:3002";
$SourceVaultMailNotebookStyle::usage = "\:672c\:6587\:8868\:793a\:30fb\:8fd4\:4fe1\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e StyleDefinitions\:3002\:65e2\:5b9a \"SourceVault default.nb\"\:3002";
$SourceVaultMailViewMaxRows::usage = "$SourceVaultMailViewMaxRows \:306f\:30e1\:30fc\:30eb\:4e00\:89a7 Dataset (SourceVaultMailView \:7b49) \:304c\:4e00\:5ea6\:306b\:63cf\:753b\:3059\:308b\:6700\:5927\:884c\:6570\:3002Windows \:7248 FrontEnd \:306f\:9805\:76ee\:6570\:306e\:591a\:3044 Dataset \:306e\:63cf\:753b\:304c\:91cd\:3044\:305f\:3081\:65e2\:5b9a 25 (Pane \:30b9\:30af\:30ed\:30fc\:30eb + Dataset \:30da\:30fc\:30b8\:30f3\:30b0\:524d\:63d0)\:3002All \:3067\:7121\:5236\:9650\:3002\:6574\:6570\:3092\:8a2d\:5b9a\:3059\:308b\:3068\:5373\:53cd\:6620\:3002";
SourceVaultMarkConfidentialViewCells::usage = "SourceVaultMarkConfidentialViewCells[nb] \:306f notebook \:5185\:306e\:300c\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:751f\:30c7\:30fc\:30bf\:3092\:8868\:793a\:3059\:308b\:51fa\:529b\:30bb\:30eb\:300d(\:30e1\:30fc\:30eb View=SourceVaultMailView/MailDataset/MailSearchSummary\:3001Todo \:751f\:30c6\:30ad\:30b9\:30c8=SourceVaultFindTodos) \:3092\:3001\:542b\:307e\:308c\:308b\:9805\:76ee\:306e\:6700\:5927\:30d7\:30e9\:30a4\:30d0\:30b7\:30fc\:3067\:6a5f\:5bc6\:30de\:30fc\:30af\:3059\:308b\:3002\:30e1\:30fc\:30eb\:306f Derived.PrivacyLevel\:3001Todo \:306f\:30bd\:30fc\:30b9\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e Publishable (\:5168 Public \:306a\:3089 0.0=\:30de\:30fc\:30af\:305b\:305a\:30011 \:3064\:3067\:3082\:975e Public \:306a\:3089 1.0)\:3002\:30af\:30e9\:30a6\:30c9 LLM (\:95be\:50240.5) \:3078\:306f\:30b9\:30ad\:30fc\:30de\:306e\:307f\:3001\:30ed\:30fc\:30ab\:30eb LLM (\:95be\:50241.0) \:3078\:306f\:5168\:6587\:3002\:30b5\:30de\:30ea\:30fc/\:4e88\:5b9a\:8868 (SourceVaultUpcomingSchedule \:7b49) \:306f\:30af\:30e9\:30a6\:30c9\:5b89\:5168\:306a\:306e\:3067\:5bfe\:8c61\:5916\:3002\:691c\:51fa\:5bfe\:8c61\:306f\:5171\:6709\:30ec\:30b8\:30b9\:30c8\:30ea\:3067\:62e1\:5f35\:3055\:308c\:308b (SourceVault_eagle.wl \:30ed\:30fc\:30c9\:6642\:306f Eagle View/Dataset/Search/GeoView \:3082\:5bfe\:8c61)\:3002nb \:7701\:7565\:6642\:306f EvaluationNotebook[]\:3002\:8fd4\:308a\:5024: {<|\"Cell\"->idx,\"PrivacyLevel\"->pl|>...}\:3002";
SourceVaultMailMarkViewCells::usage = "SourceVaultMailMarkViewCells[nb] \:306f SourceVaultMarkConfidentialViewCells \:306e\:5225\:540d (\:5f8c\:65b9\:4e92\:63db)\:3002\:30e1\:30fc\:30eb\:30fbTodo \:306a\:3069\:751f\:30c7\:30fc\:30bf\:51fa\:529b\:30bb\:30eb\:3092\:6a5f\:5bc6\:30de\:30fc\:30af\:3059\:308b\:3002";
SourceVaultMailEnableAutoConfidential::usage = "SourceVaultMailEnableAutoConfidential[] \:306f NBAccess`NBMakeContextPacket \:306b\:30d5\:30c3\:30af\:3092\:88c5\:7740\:3057\:3001ClaudeEval/ClaudeQuery \:306e\:6587\:8108\:69cb\:7bc9\:76f4\:524d\:306b SourceVaultMarkConfidentialViewCells \:3067\:751f\:30c7\:30fc\:30bf\:51fa\:529b\:30bb\:30eb (\:30e1\:30fc\:30eb View / Todo \:751f\:30c6\:30ad\:30b9\:30c8) \:3092\:81ea\:52d5\:6a5f\:5bc6\:30de\:30fc\:30af\:3059\:308b\:3002\:51aa\:7b49\:3002SourceVaultMailDisableAutoConfidential[] \:3067\:89e3\:9664\:3002";
SourceVaultMailDisableAutoConfidential::usage = "SourceVaultMailDisableAutoConfidential[] \:306f SourceVaultMailEnableAutoConfidential[] \:3067\:88c5\:7740\:3057\:305f\:30d5\:30c3\:30af\:3092\:89e3\:9664\:3057\:3001NBMakeContextPacket \:3092\:5143\:306b\:623b\:3059\:3002";

Begin["`Private`"];

If[! ValueQ[$SourceVaultMailNotebookStyle],
  $SourceVaultMailNotebookStyle = "SourceVault default.nb"];

(* Windows \:7248 FrontEnd \:306f\:9805\:76ee\:6570\:306e\:591a\:3044 Dataset \:306e\:63cf\:753b\:304c\:91cd\:3044\:3002\:30e1\:30fc\:30eb\:4e00\:89a7\:306e
   \:4e00\:5ea6\:306b\:63cf\:753b\:3059\:308b\:884c\:6570\:3092\:65e2\:5b9a 25 \:306b\:6291\:3048\:3001Pane \:30b9\:30af\:30ed\:30fc\:30eb + Dataset \:30da\:30fc\:30b8\:30f3\:30b0
   \:524d\:63d0\:306b\:3059\:308b\:3002All \:3067\:7121\:5236\:9650\:3002 *)
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
         "Hint" -> "\:518d import \:3059\:308b\:3068\:6dfb\:4ed8\:30d5\:30a1\:30a4\:30eb\:540d\:304c snapshot \:306b\:5165\:308b (SourceVaultImportMaildbFile)\:3002",
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

(* ---- \:8fd4\:4fe1\:30c9\:30e9\:30d5\:30c8 (\:30ed\:30b8\:30c3\:30af) ---- *)
iSVUIFromEmail[snap_] :=
  Module[{f = Lookup[snap["MailMetadataPublic"], "From", ""], em},
    em = If[StringQ[f], SourceVault`SourceVaultMailParseEmails[f], {}];
    If[em === {}, Missing["NoFrom"], First[em]]];

iSVUIReplyAddresses[snap_] :=
  Module[{to, cc},
    to = SourceVault`SourceVaultMailParseEmails[ToString@Lookup[snap["MailMetadataPublic"], "To", ""]];
    cc = SourceVault`SourceVaultMailParseEmails[ToString@Lookup[snap["MailMetadataPublic"], "Cc", ""]];
    {to, cc}];

(* \:672c\:6587 readable \:5316\:30d8\:30eb\:30d1 (iSVUINormalizeNewlines/iSVUILooksLikeHTML/iSVUIHtmlToText/
   iSVUIReadableBody) \:306f\:30b3\:30a2 (\:7b2c1\:30d6\:30ed\:30c3\:30af\:3001ingest \:3082\:4f7f\:3046) \:306b\:5b9a\:7fa9\:6e08\:307f\:3002 *)
iSVUIQuote[from_, date_, body_] :=
  With[{b = iSVUIReadableBody[body]},
    StringJoin[
      If[StringQ[date], date <> " ", ""], If[StringQ[from], from, ""], " wrote:\n",
      (* \:5168\:884c (\:7a7a\:884c\:542b\:3080) \:306b "> " \:3092\:4ed8\:3051\:308b\:3002StringSplit \:306f\:7a7a\:884c\:3092\:843d\:3068\:3057\:6bb5\:843d\:304c\:6f70\:308c\:308b\:305f\:3081
         \:6539\:884c\:3092 "\n> " \:7f6e\:63db\:306b\:3059\:308b (\:6a19\:6e96\:7684\:306a\:30e1\:30fc\:30eb\:5f15\:7528)\:3002 *)
      "> " <> StringReplace[b, "\n" -> "\n> "]]];

Options[SourceVaultMailComposeReply] = {"ReplyAll" -> False, "Body" -> ""};
SourceVaultMailComposeReply[record_, OptionsPattern[]] :=
  Module[{snap = iSVUISnap[record], subject, fromEmail, bodyR, body, to, cc, selfEmail},
    If[! AssociationQ[snap], Return[<|"Status" -> "Error", "Reason" -> "NotFound"|>]];
    subject = ToString@Lookup[snap["MailMetadataPublic"], "Subject", ""];
    If[! StringQ[subject], subject = ""];
    fromEmail = iSVUIFromEmail[snap];
    bodyR = SourceVaultMailGetBody[snap];
    body = If[Lookup[bodyR, "Status", ""] === "Ok", bodyR["Body"],
       (* \:5fa9\:53f7\:5931\:6557\:3092\:9ed9\:3063\:3066\:7a7a\:306b\:305b\:305a\:3001\:7406\:7531\:3092\:660e\:793a\:3059\:308b (\:9375 backend \:306e\:53d6\:308a\:9055\:3048\:691c\:77e5) *)
       "[\:672c\:6587\:3092\:5fa9\:53f7\:3067\:304d\:307e\:305b\:3093\:3067\:3057\:305f: " <>
         ToString@Lookup[bodyR, "Reason", Lookup[bodyR, "Status", "Unknown"]] <>
         " \[LongDash] NBAccess`$NBCredentialBackend = \"SystemCredential\" \:3092\:78ba\:8a8d\:3057\:3066\:304f\:3060\:3055\:3044]"];
    {to, cc} = iSVUIReplyAddresses[snap];
    (* \:81ea\:5206(\:30aa\:30fc\:30ca\:30fc)\:5b9b\:306f cc \:304b\:3089\:9664\:5916 (ReplyAll \:7528)\:3002\:30aa\:30fc\:30ca\:30fc\:306e\:30e1\:30fc\:30eb\:306f\:8b58\:5225\:5b50\:5c64 #1 \:304b\:3089\:3002 *)
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

(* ============================================================ *)
(* \:7ffb\:8a33 / \:9001\:4fe1 / \:8fd4\:4fe1\:30d1\:30cd\:30eb -- \:65e7 maildb replyMail/replyMailTr/sendReply \:8e0f\:8972
   \:30ed\:30b8\:30c3\:30af (\:7ffb\:8a33\:30fb\:9001\:4fe1) \:306f headless \:30c6\:30b9\:30c8\:53ef\:80fd\:3002\:30d1\:30cd\:30eb\:306f front end \:304c\:8981\:308b\:3002 *)
(* ============================================================ *)

If[! ValueQ[$SourceVaultMailSignature], $SourceVaultMailSignature = ""];
If[! ValueQ[$SourceVaultMailSendBccSelf], $SourceVaultMailSendBccSelf = True];

(* LLM \:547c\:3073\:51fa\:3057: \:672c\:6587\:306f\:6a5f\:5bc6\:305f\:308a\:3046\:308b\:306e\:3067 privacyLevel=1.0 (private/local \:512a\:5148)\:3002
   iCallSummaryLLM / iSVLooksLikeLLMError \:306f\:540c\:4e00 SourceVault`Private` \:6587\:8108\:306e
   \:672c\:4f53\:5b9a\:7fa9\:3092\:518d\:5229\:7528\:3059\:308b (\:90e8\:5206\:30ed\:30fc\:30c9\:3067\:672a\:5b9a\:7fa9\:3067\:3082 AssociationQ \:30ac\:30fc\:30c9\:3067\:5b89\:5168\:306b $Failed)\:3002 *)
iSVUILLM[prompt_String] :=
  Module[{r = Quiet@Check[iCallSummaryLLM[prompt, Automatic, 1.0], $Failed]},
    If[AssociationQ[r] && Lookup[r, "Status", ""] === "OK" &&
        StringQ[Lookup[r, "Response", Null]] &&
        ! TrueQ@Quiet@Check[iSVLooksLikeLLMError[r["Response"]], False] &&
        StringTrim[r["Response"]] =!= "",
      StringTrim[r["Response"]], $Failed]];

(* \:8868\:793a\:8a00\:8a9e (\:8fd4\:4fe1\:7ffb\:8a33\:30fb\:672c\:6587\:7ffb\:8a33\:306e\:65e2\:5b9a\:30bf\:30fc\:30b2\:30c3\:30c8\:8aad\:307f\:624b\:8a00\:8a9e) *)
iSVUIReadingLang[] := If[$Language === "Japanese", "\:65e5\:672c\:8a9e", ToString[$Language]];

(* \:5916\:56fd\:8a9e\:30e1\:30fc\:30eb\:672c\:6587\:3092\:8aad\:307f\:624b\:8a00\:8a9e\:3078\:7ffb\:8a33 (\:8aad\:3080\:305f\:3081)\:3002HTML/\:6539\:884c\:306f readable \:5316\:3057\:3066\:304b\:3089\:3002 *)
iSVUITranslateBodyToReading[body_String] :=
  Module[{lang = iSVUIReadingLang[], readable = iSVUIReadableBody[body]},
    If[StringTrim[readable] === "", Return[""]];
    iSVUILLM[
      "\:6b21\:306e\:30e1\:30fc\:30eb\:672c\:6587\:3092" <> lang <> "\:306b\:7ffb\:8a33\:305b\:3088\:3002\:7ffb\:8a33\:7d50\:679c\:306e\:307f\:3092\:51fa\:529b\:3057\:3001" <>
      "\:8aac\:660e\:30fb\:898b\:51fa\:3057\:30fb\:6ce8\:8a18\:306f\:4e00\:5207\:4ed8\:3051\:306a\:3044\:3002\:4eba\:540d\:30fb\:56e3\:4f53\:540d\:30fb\:56fa\:6709\:540d\:8a5e\:306f\:539f\:6587\:306e\:8868\:8a18\:306e\:307e\:307e\:6b8b\:3059\:3002\n\n" <> readable]];

(* \:516c\:958b: \:672c\:6587\:7ffb\:8a33 (headless) *)
SourceVaultMailTranslateBody[record_] :=
  Module[{r = SourceVaultMailGetBody[record], tr, lang = iSVUIReadingLang[]},
    If[Lookup[r, "Status", ""] =!= "Ok",
      Return[<|"Status" -> "Error",
        "Reason" -> Lookup[r, "Reason", Lookup[r, "Status", "Unknown"]]|>]];
    tr = iSVUITranslateBodyToReading[r["Body"]];
    If[StringQ[tr],
      <|"Status" -> "Ok", "Text" -> tr, "Translated" -> True, "Lang" -> lang|>,
      <|"Status" -> "Error", "Reason" -> "TranslateFailed", "Lang" -> lang|>]];

(* \:5143\:30e1\:30fc\:30eb\:306e\:8a00\:8a9e\:30fb\:30d5\:30a9\:30fc\:30de\:30eb\:5ea6\:3092\:5224\:5b9a (\:8fd4\:4fe1\:7ffb\:8a33\:306e\:305f\:3081) *)
iSVUIDetectLangFormality[body_String] :=
  Module[{snippet = StringTake[body, UpTo[2000]], lang, form},
    lang = iSVUILLM[
      "\:6b21\:306e\:30e1\:30fc\:30eb\:672c\:6587\:306e\:8a00\:8a9e\:3092\:82f1\:8a9e\:3067\:4e00\:8a9e\:3067\:7b54\:3048\:3088 (English, Chinese, Korean, French \:306a\:3069)\:3002" <>
      "\:65e5\:672c\:8a9e\:306a\:3089 Japanese\:3002\n\n" <> snippet];
    form = iSVUILLM[
      "\:6b21\:306e\:30e1\:30fc\:30eb\:306e\:30d5\:30a9\:30fc\:30de\:30eb\:5ea6\:3092\:4e00\:8a9e\:3067\:7b54\:3048\:3088\:3002formal / semi-formal / informal \:306e\:3044\:305a\:308c\:304b\:306e\:307f\:3002\n\n" <> snippet];
    {If[StringQ[lang], lang, "English"], If[StringQ[form], form, "semi-formal"]}];

iSVUIReplyDetect[record_] :=
  Module[{r = SourceVaultMailGetBody[record]},
    If[Lookup[r, "Status", ""] === "Ok",
      iSVUIDetectLangFormality[r["Body"]], {"English", "semi-formal"}]];

(* \:8fd4\:4fe1\:6587 (\:65e5\:672c\:8a9e) \:306e\:656c\:4f53/\:5e38\:4f53\:3092\:7c21\:6613\:5224\:5b9a (\:6b63\:898f\:8868\:73fe\:306e\:4e8c\:91cd\:30a8\:30b9\:30b1\:30fc\:30d7\:3092\:907f\:3051 literal \:3067) *)
iSVUIDetectReplyStyle[replyText_String] :=
  If[StringContainsQ[replyText,
      {"\:307e\:3059\:3002", "\:307e\:3059\:3001", "\:307e\:3059 ", "\:307e\:3059\n", "\:3067\:3059\:3002", "\:3067\:3059\:3001", "\:3067\:3059 ", "\:3067\:3059\n",
       "\:304f\:3060\:3055\:3044", "\:3044\:305f\:3057\:307e\:3059", "\:3054\:3056\:3044\:307e\:3059", "\:3067\:3057\:3087\:3046\:304b", "\:9858\:3044\:307e\:3059"}],
    "keigo", "casual"];

(* \:65e5\:672c\:8a9e\:8fd4\:4fe1\:3092\:5143\:30e1\:30fc\:30eb\:306e\:8a00\:8a9e\:3078\:7ffb\:8a33 (\:65e7 maildb sendReplyTr \:8e0f\:8972) *)
iSVUITranslateReply[replyText_String, targetLang_String, origFormality_String] :=
  Module[{style = iSVUIDetectReplyStyle[replyText], instr},
    instr = "\:76f8\:624b\:306e\:5143\:30e1\:30fc\:30eb\:306e\:30d5\:30a9\:30fc\:30de\:30eb\:5ea6\:306f " <> origFormality <> " \:3067\:3042\:308b\:3002" <>
      If[style === "keigo",
        "\:8fd4\:4fe1\:8005\:306f\:4e01\:5be7\:306a\:6587\:4f53\:3067\:66f8\:3044\:3066\:3044\:308b\:306e\:3067\:3001\:5143\:30e1\:30fc\:30eb\:3088\:308a\:5c11\:3057\:30d5\:30a9\:30fc\:30de\:30eb\:306b\:7ffb\:8a33\:305b\:3088\:3002",
        "\:8fd4\:4fe1\:8005\:306f\:30ab\:30b8\:30e5\:30a2\:30eb\:306a\:6587\:4f53\:3067\:66f8\:3044\:3066\:3044\:308b\:306e\:3067\:3001\:5143\:30e1\:30fc\:30eb\:3088\:308a\:5c11\:3057\:30a4\:30f3\:30d5\:30a9\:30fc\:30de\:30eb\:306b\:7ffb\:8a33\:305b\:3088\:3002"];
    iSVUILLM[
      "\:6b21\:306e\:65e5\:672c\:8a9e\:306e\:30e1\:30fc\:30eb\:8fd4\:4fe1\:3092" <> targetLang <> "\:306b\:7ffb\:8a33\:305b\:3088\:3002\n" <> instr <> "\n" <>
      "\:4eba\:540d\:30fb\:30a4\:30cb\:30b7\:30e3\:30eb\:30fb\:56e3\:4f53\:540d\:306f\:7ffb\:8a33\:305b\:305a\:539f\:6587\:306e\:30a2\:30eb\:30d5\:30a1\:30d9\:30c3\:30c8\:8868\:8a18\:306e\:307e\:307e\:6b8b\:3059\:3002\n" <>
      "\:3067\:304d\:308b\:3060\:3051\:7c21\:6f54\:306a\:6587\:7ae0\:3068\:3057\:3066\:7ffb\:8a33\:3057\:3001\:7ffb\:8a33\:7d50\:679c\:306e\:307f\:3092\:51fa\:529b\:305b\:3088\:3002\n\n" <> replyText]];

(* ---- \:9001\:4fe1 (SendMail) ---- *)
iSVUIOwnerPrimaryEmail[] :=
  With[{e = iSVMDOwnerPrimaryEmail[]}, If[StringQ[e] && e =!= "", e, Missing[]]];

SourceVaultMailSend[spec_Association] :=
  Module[{to, cc, bcc, subject, body, atts, mailSpec, result, sig, self, rawAtts},
    to = StringTrim@ToString@Lookup[spec, "To", ""];
    If[to === "", Return[<|"Status" -> "Error", "Reason" -> "NoRecipient"|>]];
    cc = StringTrim@ToString@Lookup[spec, "Cc", ""];
    subject = ToString@Lookup[spec, "Subject", ""];
    body = ToString@Lookup[spec, "Body", ""];
    sig = If[StringQ[$SourceVaultMailSignature] && StringTrim[$SourceVaultMailSignature] =!= "",
      "\n\n" <> $SourceVaultMailSignature, ""];
    body = body <> sig;
    (* \:6539\:884c\:3092 LF \:306b\:7d71\:4e00\:3002\r \:304c\:6b8b\:308b\:3068 SMTP \:306e \n->\r\n \:6b63\:898f\:5316\:3067 \r\r\n \:306b\:306a\:308a
       \:53d7\:4fe1\:5074\:3067\:4e8c\:91cd\:6539\:884c\:306b\:306a\:308b (\:65e7 maildb \:3068\:540c\:3058\:5bfe\:7b56)\:3002 *)
    body = iSVUINormalizeNewlines[body];
    rawAtts = Lookup[spec, "Attachments", {}];
    rawAtts = If[ListQ[rawAtts], rawAtts, {rawAtts}];
    atts = Select[rawAtts, StringQ[#] && FileExistsQ[#] &];
    (* \:6307\:5b9a\:3055\:308c\:305f\:304c\:5b58\:5728\:3057\:306a\:3044\:6dfb\:4ed8\:306f\:9001\:4fe1\:524d\:306b\:5f3e\:304f (\:9ed9\:3063\:3066\:6b20\:843d\:3055\:305b\:306a\:3044) *)
    With[{missing = Select[rawAtts, StringQ[#] && ! FileExistsQ[#] &]},
      If[missing =!= {},
        Return[<|"Status" -> "Error", "Reason" -> "AttachmentNotFound",
          "Missing" -> missing|>]]];
    bcc = Lookup[spec, "Bcc", Automatic];
    self = iSVUIOwnerPrimaryEmail[];
    bcc = If[bcc === Automatic,
      If[TrueQ[$SourceVaultMailSendBccSelf] && StringQ[self], self, ""],
      StringTrim@ToString[bcc]];
    mailSpec = <|"To" -> to, "Subject" -> subject, "Body" -> body|>;
    If[cc =!= "", mailSpec["Cc"] = cc];
    If[StringQ[bcc] && bcc =!= "", mailSpec["Bcc"] = bcc];
    If[atts =!= {}, mailSpec["Attachments"] = atts];
    result = Quiet@Check[SendMail[mailSpec], $Failed];
    If[FailureQ[result] || result === $Failed,
      <|"Status" -> "Error", "Reason" -> "SendMailFailed",
        "Detail" -> ToString[result], "To" -> to, "Subject" -> subject|>,
      <|"Status" -> "Sent", "To" -> to, "Cc" -> cc, "Bcc" -> bcc,
        "Subject" -> subject, "Attachments" -> atts|>]];

(* \:9001\:4fe1\:524d\:306e\:78ba\:8a8d\:30c0\:30a4\:30a2\:30ed\:30b0 (\:5916\:5411\:304d\:306e\:4e0d\:53ef\:9006\:64cd\:4f5c\:306a\:306e\:3067\:660e\:793a\:78ba\:8a8d\:3059\:308b) *)
iSVUISendConfirm[spec_Association] :=
  Module[{to = ToString@Lookup[spec, "To", ""], subj = ToString@Lookup[spec, "Subject", ""],
      cc = StringTrim@ToString@Lookup[spec, "Cc", ""],
      natt = Length@Select[Lookup[spec, "Attachments", {}], StringQ]},
    ChoiceDialog[
      Column[{
        Style["\:3053\:306e\:30e1\:30fc\:30eb\:3092\:9001\:4fe1\:3057\:307e\:3059\:304b\:ff1f", "Subsection"],
        Row[{Style["To: ", Bold], to}],
        If[cc =!= "", Row[{Style["Cc: ", Bold], cc}], Nothing],
        Row[{Style["\:4ef6\:540d: ", Bold], subj}],
        Row[{Style["\:6dfb\:4ed8: ", Bold], ToString[natt] <> " \:4ef6"}]}],
      {"\:9001\:4fe1\:3059\:308b" -> True, "\:30ad\:30e3\:30f3\:30bb\:30eb" -> False}, WindowTitle -> "\:9001\:4fe1\:78ba\:8a8d"]];

(* ---- \:6dfb\:4ed8\:30c1\:30c3\:30d7 (\:524a\:9664\:30dc\:30bf\:30f3\:4ed8\:304d) ---- *)
iSVUIAttachChips[attachments_, removeFn_] :=
  If[attachments === {}, Style["(\:6dfb\:4ed8\:306a\:3057)", Gray],
    Row[Riffle[
      (With[{ff = #},
         Framed[Row[{
           Tooltip[Style[FileNameTake[ff], "Text"], ff], Spacer[3],
           Button[Style["\[Times]", Red, Bold], removeFn[ff],
             Appearance -> "Frameless"]}],
           RoundingRadius -> 4, FrameStyle -> GrayLevel[0.75],
           Background -> GrayLevel[0.96]]] & /@ attachments),
      Spacer[5]]]];

(* ---- \:8fd4\:4fe1\:7528\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:30bb\:30eb\:8aad\:307f\:66f8\:304d ----
   \:8fd4\:4fe1\:672c\:6587\:306f\:300c\:666e\:901a\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:30bb\:30eb\:300d(CellTags \:4ed8\:304d Text \:30bb\:30eb) \:306b\:3059\:308b\:3002
   \:3053\:3046\:3059\:308b\:3068 documentation.wl (DocExpandIdea/DocRefine/DocPolish/DocTranslate/
   ShowDocPalette \:7b49) \:304c\:5bfe\:8c61\:30bb\:30eb\:3068\:3057\:3066\:305d\:306e\:307e\:307e\:4f7f\:3048\:308b\:3002
   \:5236\:5fa1\:30d1\:30cd\:30eb (To/Cc/\:4ef6\:540d/\:6dfb\:4ed8/\:9001\:4fe1) \:3060\:3051 DynamicModule\:3001\:672c\:6587/\:7ffb\:8a33/\:5f15\:7528\:306f\:30bb\:30eb\:3002 *)

(* \:30bb\:30eb\:5f0f -> \:5e73\:6587\:3002FE \:306e PlainText \:30a8\:30af\:30b9\:30dd\:30fc\:30c8\:3092\:4f7f\:3044\:3001\:7a00\:306b\:6b8b\:308b \:XXXX \:3092\:5b9f\:6587\:5b57\:3078\:3002 *)
iSVUICellPlainText[cellExpr_] :=
  Module[{txt},
    txt = Quiet@Check[
      First@FrontEndExecute[FrontEnd`ExportPacket[cellExpr, "PlainText"]], $Failed];
    If[! StringQ[txt], Return[$Failed]];
    (* FE \:306f \r\n \:3092\:8fd4\:3057\:3046\:308b\:3002LF \:306b\:7d71\:4e00\:3057\:3066\:304b\:3089 \:XXXX \:3092\:5b9f\:6587\:5b57\:3078\:3002 *)
    txt = iSVUINormalizeNewlines[txt];
    StringReplace[txt,
      RegularExpression["\\\\:([0-9a-fA-F]{4})"] :> FromCharacterCode[FromDigits["$1", 16]]]];

(* CellTags \:3067\:30bb\:30eb\:3092\:63a2\:3057\:5e73\:6587\:3092\:8fd4\:3059\:3002\:7121\:3051\:308c\:3070 Missing["NoCell"]\:3002 *)
iSVUIReadTaggedCell[nb_, tag_String] :=
  Module[{cells = Quiet@Check[Cells[nb, CellTags -> tag], {}]},
    If[! ListQ[cells] || cells === {}, Return[Missing["NoCell"]]];
    iSVUICellPlainText[NotebookRead[First[cells]]]];

(* \:7ffb\:8a33\:7d50\:679c\:3092\:672c\:6587\:30bb\:30eb\:76f4\:5f8c\:306e\:300c\:666e\:901a\:306e\:7de8\:96c6\:53ef\:80fd\:30bb\:30eb\:300d(svReplyTranslated) \:3068\:3057\:3066\:66f8\:304f\:3002
   \:518d\:30d7\:30ec\:30d3\:30e5\:30fc\:3067\:306f\:65e7\:30bb\:30eb\:3092\:6d88\:3057\:3066\:304b\:3089\:66f8\:304f (\:91cd\:8907\:9632\:6b62)\:3002\:66f8\:8fbc\:5f8c\:306b\:5143\:30e1\:30fc\:30eb PL \:3092\:518d\:4ed8\:4e0e\:3002
   \:8fd4\:308a\:5024: \:7ffb\:8a33\:30bb\:30eb\:3002 *)
iSVUIWriteTranslatedCell[nb_, text_String, pl_ : 1.0] :=
  Module[{bodyCells, tc},
    Quiet@Scan[NotebookDelete, Cells[nb, CellTags -> "svReplyTranslated"]];
    bodyCells = Quiet@Check[Cells[nb, CellTags -> "svReplyBody"], {}];
    If[! ListQ[bodyCells] || bodyCells === {}, Return[$Failed]];
    SelectionMove[First[bodyCells], After, Cell];
    NotebookWrite[nb,
      Cell[text, "Text", CellTags -> {"svReplyTranslated"},
        CellFrameMargins -> 6]];
    tc = First[Cells[nb, CellTags -> "svReplyTranslated"], $Failed];
    (* \:65b0\:898f\:7ffb\:8a33\:30bb\:30eb\:306b\:3082\:5143\:30e1\:30fc\:30eb\:306e PrivacyLevel \:3092\:4ed8\:4e0e (\:5168\:30bb\:30eb\:518d\:30de\:30fc\:30af\:3067\:51aa\:7b49) *)
    iSVUIMarkCellsConfidential[nb, pl];
    tc];

(* ---- \:6a5f\:5bc6\:4fdd\:6301: \:30e1\:30fc\:30eb\:30a6\:30a4\:30f3\:30c9\:30a6\:306e\:5168\:30bb\:30eb\:3092\:5143\:30e1\:30fc\:30eb\:306e PrivacyLevel \:3067\:30de\:30fc\:30af ----
   \:8868\:793a\:30fb\:8fd4\:4fe1\:30a6\:30a4\:30f3\:30c9\:30a6\:306e\:672c\:6587/\:5f15\:7528/\:7ffb\:8a33\:306a\:3069\:306e\:30bb\:30eb\:304c\:5143\:30e1\:30fc\:30eb\:306e PL \:3092\:4fdd\:6301\:3057\:3001\:305d\:306e
   \:30a6\:30a4\:30f3\:30c9\:30a6\:304b\:3089\:306e LLM \:547c\:3073\:51fa\:3057 (documentation.wl / ClaudeEval \:7b49) \:306e\:6587\:8108\:69cb\:7bc9\:6642\:306b
   NBMakeContextPacket \:304c\:9ad8 PL \:30bb\:30eb\:3092\:30af\:30e9\:30a6\:30c9\:3078\:9001\:3089\:306a\:3044 (\:30af\:30e9\:30a6\:30c9\:95be\:5024 0.5 / \:30ed\:30fc\:30ab\:30eb 1.0)\:3002
   PL < 0.5 (\:516c\:958b\:30e1\:30fc\:30eb) \:306f\:30de\:30fc\:30af\:3057\:306a\:3044 (\:30af\:30e9\:30a6\:30c9\:53ef)\:3002\:30de\:30fc\:30af\:306f NBAccess \:516c\:958b API \:7d4c\:7531\:3002 *)
iSVUIMailWindowPL[snap_] :=
  With[{p = Quiet@Check[iSVMailProbePL[snap], 1.0]}, If[NumericQ[p], N[p], 1.0]];

iSVUIMarkCellsConfidential[nb_, pl_] :=
  If[Head[nb] === NotebookObject && NumericQ[pl] && pl >= 0.5,
    Module[{n},
      Quiet@Check[NBAccess`NBInvalidateCellsCache[nb], Null];
      n = Quiet@Check[NBAccess`NBCellCount[nb], 0];
      If[IntegerQ[n] && n > 0,
        Do[Quiet@Check[NBAccess`NBMarkCellConfidential[nb, i, N[pl]], Null], {i, n}]]],
    Null];

(* ---- \:8fd4\:4fe1\:5236\:5fa1\:30d1\:30cd\:30eb (DynamicModule) ----
   \:672c\:6587\:30bb\:30eb (svReplyBody)\:30fb\:7ffb\:8a33\:30bb\:30eb (svReplyTranslated)\:30fb\:5f15\:7528\:30bb\:30eb (svReplyQuote) \:306f
   \:3053\:306e\:30d1\:30cd\:30eb\:3068\:540c\:3058\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306b\:3042\:308b\:3002\:30dc\:30bf\:30f3\:306f EvaluationNotebook[] \:3067\:305d\:308c\:3089\:3092\:8aad\:3080\:3002 *)
iSVUIReplyControl[draft_Association, translateMode_, pl_ : 1.0] :=
  DynamicModule[{
      to = ToString@Lookup[draft, "To", ""],
      cc = StringRiffle[Cases[Lookup[draft, "Cc", {}], _String], ", "],
      subject = ToString@Lookup[draft, "Subject", ""],
      rid = ToString@Lookup[draft, "RecordId", ""],
      origLang = "", origFormality = "",
      attachments = {}, includeQuote = True, busy = False, status = "",
      tr = TrueQ[translateMode]},
    Panel@Column[{
      Style[If[tr, "\:8fd4\:4fe1 (\:65e5\:672c\:8a9e\:3067\:66f8\:3044\:3066\:7ffb\:8a33\:3057\:3066\:9001\:4fe1)", "\:8fd4\:4fe1"], "Subtitle"],
      Grid[{
        {"To:", InputField[Dynamic[to], String, FieldSize -> {45, 1}]},
        {"Cc:", InputField[Dynamic[cc], String, FieldSize -> {45, 1}]},
        {"\:4ef6\:540d:", InputField[Dynamic[subject], String, FieldSize -> {45, 1}]}},
        Alignment -> {{Right, Left}, Center}],
      Row[{
        Button["\:30d5\:30a1\:30a4\:30eb\:6dfb\:4ed8",
          With[{f = SystemDialogInput["FileOpen", WindowTitle -> "\:6dfb\:4ed8\:30d5\:30a1\:30a4\:30eb\:3092\:9078\:629e"]},
            If[StringQ[f], attachments = DeleteDuplicates@Append[attachments, f]]],
          Method -> "Queued"],
        Spacer[8],
        Dynamic[iSVUIAttachChips[attachments,
          Function[ff, attachments = DeleteCases[attachments, ff]]]]}],
      Row[{Checkbox[Dynamic[includeQuote]], Spacer[4], "\:5f15\:7528\:5143\:3092\:542b\:3081\:3066\:9001\:4fe1\:3059\:308b"}],
      If[tr,
        Row[{
          Button["\:7ffb\:8a33\:30d7\:30ec\:30d3\:30e5\:30fc",
            Module[{nb = EvaluationNotebook[], bodyTxt, t},
              busy = True;
              bodyTxt = iSVUIReadTaggedCell[nb, "svReplyBody"];
              If[! StringQ[bodyTxt] || StringTrim[bodyTxt] === "",
                status = Style["\:8fd4\:4fe1\:672c\:6587\:30bb\:30eb\:306b\:65e5\:672c\:8a9e\:3092\:5165\:529b\:3057\:3066\:304f\:3060\:3055\:3044", Red]; busy = False,
                If[origLang === "",
                  With[{lf = iSVUIReplyDetect[rid]},
                    origLang = lf[[1]]; origFormality = lf[[2]]]];
                t = iSVUITranslateReply[StringTrim[bodyTxt], origLang, origFormality];
                iSVUIWriteTranslatedCell[nb, If[StringQ[t], t, "[\:7ffb\:8a33\:306b\:5931\:6557\:3057\:307e\:3057\:305f]"], pl];
                status = Style["\:7ffb\:8a33\:7d50\:679c\:30bb\:30eb\:3092\:78ba\:8a8d\:30fb\:7de8\:96c6\:3057\:3066\:304b\:3089\:9001\:4fe1\:3057\:3066\:304f\:3060\:3055\:3044", Gray];
                busy = False]],
            Method -> "Queued"],
          Spacer[6], Dynamic[If[busy, ProgressIndicator[Appearance -> "Necklace"], ""]],
          Spacer[6], Dynamic[If[origLang === "", "",
            Style["\[RightArrow] " <> origLang <> " (" <> origFormality <> ")", Gray]]]}],
        Nothing],
      Row[{
        Button[Style["\:9001\:4fe1", Bold],
          Module[{nb = EvaluationNotebook[], mainTxt, finalBody, q, spec, ok},
            mainTxt = If[tr,
              iSVUIReadTaggedCell[nb, "svReplyTranslated"],
              iSVUIReadTaggedCell[nb, "svReplyBody"]];
            Which[
              tr && ! StringQ[mainTxt],
                status = Style["\:5148\:306b\:300c\:7ffb\:8a33\:30d7\:30ec\:30d3\:30e5\:30fc\:300d\:3092\:62bc\:3057\:3066\:304f\:3060\:3055\:3044", Red],
              ! StringQ[mainTxt] || StringTrim[mainTxt] === "",
                status = Style["\:672c\:6587\:304c\:7a7a\:3067\:3059", Red],
              True,
                finalBody = StringTrim[mainTxt];
                If[TrueQ[includeQuote],
                  q = iSVUIReadTaggedCell[nb, "svReplyQuote"];
                  If[StringQ[q] && StringTrim[q] =!= "",
                    finalBody = finalBody <> "\n\n" <> StringTrim[q]]];
                spec = <|"To" -> to, "Cc" -> cc, "Subject" -> subject,
                   "Body" -> finalBody, "Attachments" -> attachments|>;
                ok = iSVUISendConfirm[spec];
                If[TrueQ[ok],
                  busy = True;
                  With[{res = SourceVaultMailSend[spec]},
                    If[Lookup[res, "Status", ""] === "Sent",
                      (* \:8fd4\:4fe1\:6e08\:3092\:8a18\:9332 (\:5143\:30e1\:30fc\:30eb\:306e RecordId) *)
                      Quiet@Check[iSVMDRecordReplied[rid], Null]];
                    status = If[Lookup[res, "Status", ""] === "Sent",
                      Style["\[Checkmark] \:9001\:4fe1\:3057\:307e\:3057\:305f", Bold, Darker@Green],
                      Style["\:2717 \:9001\:4fe1\:5931\:6557: " <> ToString@Lookup[res, "Reason", ""], Red]]];
                  busy = False]]],
          Method -> "Queued"],
        Spacer[10], Dynamic[status]}]
    }, Spacer[8]]];

(* ---- front end \:30e9\:30c3\:30d1 (GUI \:304c\:8981\:308b) ---- *)
(* \:30e1\:30fc\:30eb\:672c\:6587\:30d8\:30c3\:30c0 (\:5dee\:51fa\:4eba/\:5b9b\:5148/\:65e5\:4ed8) *)
iSVUIBodyHeader[snap_] :=
  Module[{md = Lookup[snap, "MailMetadataPublic", <||>], ff = iSVUIFont[]},
    Style[Column[{
      Row[{Style["From: ", Bold], iSVUIShow@Lookup[md, "From", ""]}],
      Row[{Style["To: ", Bold], iSVUIShow@Lookup[md, "To", ""]}],
      If[StringTrim[ToString@Lookup[md, "Cc", ""]] =!= "",
        Row[{Style["Cc: ", Bold], Lookup[md, "Cc", ""]}], Nothing],
      Row[{Style["Date: ", Bold], iSVUIFormatDateJST@Lookup[md, "Date", Missing[]]}]},
      Spacing -> 0.3], "Text", Gray, FontFamily -> ff]];

(* \:672c\:6587\:8868\:793a\:30d1\:30cd\:30eb: \:8fd4\:4fe1/\:5168\:54e1\:306b\:8fd4\:4fe1/\:7ffb\:8a33\:3057\:3066\:8fd4\:4fe1/\:7ffb\:8a33\:8868\:793a/\:6dfb\:4ed8 \:30dc\:30bf\:30f3\:4ed8\:304d\:3002
   \:7ffb\:8a33\:8868\:793a\:306f\:672c\:6587\:3092\:30a4\:30f3\:30e9\:30a4\:30f3\:306b $Language \:8a33\:3067\:8ffd\:8a18\:3059\:308b\:3002 *)
iSVUIBodyPanel[snap_, subj_, body_, htmlQ_ : False] :=
  DynamicModule[{trans = "", busy = False, r = ToString@Lookup[snap, "RecordId", ""]},
    Panel@Column[{
      Style[subj, "Subtitle"],
      iSVUIBodyHeader[snap],
      Row[{
        Button["\:8fd4\:4fe1", SourceVaultMailOpenReplyNotebook[r], Method -> "Queued"],
        Button["\:5168\:54e1\:306b\:8fd4\:4fe1", SourceVaultMailOpenReplyNotebook[r, "ReplyAll" -> True],
          Method -> "Queued"],
        Button["\:7ffb\:8a33\:3057\:3066\:8fd4\:4fe1",
          SourceVaultMailOpenReplyNotebook[r, "ReplyAll" -> True, "Translate" -> True],
          Method -> "Queued"],
        iSVUIAttachMenu[snap],
        Button["\:7ffb\:8a33\:8868\:793a",
          busy = True;
          With[{t = iSVUITranslateBodyToReading[body]},
            trans = If[StringQ[t], t, "[\:7ffb\:8a33\:306b\:5931\:6557\:3057\:307e\:3057\:305f]"]];
          busy = False, Method -> "Queued"],
        Spacer[6], Dynamic[If[busy, ProgressIndicator[Appearance -> "Necklace"], ""]]},
        Spacer[6]],
      If[TrueQ[htmlQ],
        Style["(HTML \:30e1\:30fc\:30eb\:3092\:30c6\:30ad\:30b9\:30c8\:306b\:5909\:63db\:3057\:3066\:8868\:793a\:3057\:3066\:3044\:307e\:3059)", "Text", Gray, FontSlant -> Italic],
        Nothing],
      Pane[Style[body, "Text"], {Full, UpTo[460]}, Scrollbars -> Automatic],
      Dynamic[If[trans === "", "",
        Column[{
          Style["\:3010" <> iSVUIReadingLang[] <> "\:8a33\:3011", "Text", Bold],
          Pane[Style[trans, "Text"], {Full, UpTo[360]}, Scrollbars -> Automatic]}]]]
    }, Spacer[8]]];

SourceVaultMailShowBody[record_] :=
  Module[{snap = iSVUISnap[record], r, subj, raw, readable, htmlQ, nb, pl},
    r = SourceVaultMailGetBody[snap];
    If[Lookup[r, "Status", ""] =!= "Ok",
      (* GUI button \:306f\:30ea\:30bf\:30fc\:30f3\:5024\:3092\:6368\:3066\:308b\:306e\:3067\:3001\:5931\:6557\:7406\:7531\:3092\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306b\:51fa\:3059 *)
      Quiet@Check[
        CreateDocument[{
          Cell[iSVL["DecryptFailTitle"], "Subtitle"],
          Cell["Reason: " <> ToString@Lookup[r, "Reason", Lookup[r, "Status", "Unknown"]], "Text"],
          Cell[iSVL["DecryptFailHint"], "Text"]},
          WindowTitle -> iSVL["DecryptFailTitle"],
          StyleDefinitions -> $SourceVaultMailNotebookStyle], $Failed];
      Return[r]];
    subj = ToString@Lookup[snap["MailMetadataPublic"], "Subject", "(no subject)"];
    raw = r["Body"];
    htmlQ = iSVUILooksLikeHTML[iSVUINormalizeNewlines[raw]];
    readable = iSVUIReadableBody[raw];
    pl = iSVUIMailWindowPL[snap];
    nb = Quiet@Check[
      CreateDocument[
        ExpressionCell[iSVUIBodyPanel[snap, subj, readable, htmlQ], "Output",
          CellMargins -> {{15, 15}, {12, 12}}],
        WindowTitle -> subj,
        StyleDefinitions -> $SourceVaultMailNotebookStyle], $Failed];
    (* \:672c\:6587\:30bb\:30eb\:306b\:5143\:30e1\:30fc\:30eb\:306e PrivacyLevel \:3092\:4ed8\:4e0e: \:3053\:306e\:7a93\:304b\:3089\:306e LLM \:547c\:3073\:51fa\:3057\:3067
       \:9ad8 PL \:306a\:3089 \:30af\:30e9\:30a6\:30c9\:3078\:9001\:3089\:308c\:306a\:3044 (NBMakeContextPacket \:95be\:5024 0.5)\:3002 *)
    iSVUIMarkCellsConfidential[nb, pl];
    (* \:958b\:5c01\:56de\:6570\:3092\:8a18\:9332 (\:672c\:6587\:8868\:793a\:306b\:6210\:529f\:3057\:305f\:3068\:304d\:306e\:307f) *)
    Quiet@Check[iSVMDRecordOpen[ToString@Lookup[snap, "RecordId", ""]], Null];
    <|"Status" -> "Shown", "PrivacyLevel" -> pl|>];

Options[SourceVaultMailOpenReplyNotebook] = {"ReplyAll" -> False, "Translate" -> False};
SourceVaultMailOpenReplyNotebook[record_, opts : OptionsPattern[]] :=
  Module[{draft, translate = TrueQ[OptionValue["Translate"]], subj, quoted, instr, nb,
      snap, pl},
    draft = SourceVaultMailComposeReply[record, "ReplyAll" -> TrueQ[OptionValue["ReplyAll"]]];
    If[Lookup[draft, "Status", ""] =!= "Draft", Return[draft]];
    snap = iSVUISnap[record];
    pl = iSVUIMailWindowPL[snap];
    subj = ToString@Lookup[draft, "Subject", "Re:"];
    quoted = ToString@Lookup[draft, "Quoted", ""];
    instr = If[translate,
      "\[DownArrow] \:3053\:306e\:30bb\:30eb\:306b\:65e5\:672c\:8a9e\:3067\:8fd4\:4fe1\:3092\:5165\:529b\:3057\:3001\:4e0a\:306e\:300c\:7ffb\:8a33\:30d7\:30ec\:30d3\:30e5\:30fc\:300d\:3092\:62bc\:3057\:3066\:304f\:3060\:3055\:3044\:3002\:672c\:6587\:306f\:901a\:5e38\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:30bb\:30eb\:306a\:306e\:3067\:6587\:7ae0\:4f5c\:6210\:30d1\:30ec\:30c3\:30c8 (ShowDocPalette \:7b49) \:304c\:4f7f\:3048\:307e\:3059\:3002",
      "\[DownArrow] \:3053\:306e\:30bb\:30eb\:306b\:8fd4\:4fe1\:672c\:6587\:3092\:5165\:529b\:3057\:3066\:304f\:3060\:3055\:3044\:3002\:672c\:6587\:306f\:901a\:5e38\:306e\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:30bb\:30eb\:306a\:306e\:3067\:6587\:7ae0\:4f5c\:6210\:30d1\:30ec\:30c3\:30c8 (ShowDocPalette \:7b49) \:304c\:4f7f\:3048\:307e\:3059\:3002"];
    (* \:5236\:5fa1\:30d1\:30cd\:30eb (Output) + \:6848\:5185 + \:672c\:6587\:30bb\:30eb + \:5f15\:7528\:30bb\:30eb\:3002\:672c\:6587/\:5f15\:7528/\:7ffb\:8a33\:306f\:666e\:901a\:306e\:7de8\:96c6\:53ef\:80fd\:30bb\:30eb\:3002 *)
    nb = Quiet@Check[
      CreateDocument[{
        ExpressionCell[iSVUIReplyControl[draft, translate, pl], "Output",
          CellMargins -> {{15, 15}, {12, 8}}],
        Cell[instr, "Text", FontColor -> Gray, FontSlant -> Italic],
        Cell["", "Text", CellTags -> {"svReplyBody"}],
        Cell[quoted, "Text", FontColor -> GrayLevel[0.55], CellTags -> {"svReplyQuote"}]},
        WindowTitle -> subj,
        StyleDefinitions -> $SourceVaultMailNotebookStyle], $Failed];
    (* \:5f15\:7528(\:5143\:30e1\:30fc\:30eb)\:30fb\:672c\:6587\:30fb\:7ffb\:8a33\:30bb\:30eb\:306b\:5143\:30e1\:30fc\:30eb\:306e PrivacyLevel \:3092\:4ed8\:4e0e: \:3053\:306e\:7a93\:304b\:3089\:306e
       LLM \:547c\:3073\:51fa\:3057 (documentation.wl / ClaudeEval) \:3067\:9ad8 PL \:306a\:3089 \:30af\:30e9\:30a6\:30c9\:3078\:9001\:3089\:308c\:306a\:3044\:3002 *)
    iSVUIMarkCellsConfidential[nb, pl];
    (* \:30ab\:30fc\:30bd\:30eb\:3092\:672c\:6587\:30bb\:30eb\:306b\:7f6e\:304d\:3001\:3059\:3050\:5165\:529b\:30fb\:30d1\:30ec\:30c3\:30c8\:64cd\:4f5c\:3067\:304d\:308b\:3088\:3046\:306b\:3059\:308b *)
    Quiet@Check[
      With[{bc = Cells[nb, CellTags -> "svReplyBody"]},
        If[ListQ[bc] && bc =!= {}, SelectionMove[First[bc], Before, CellContents]]], Null];
    <|"Status" -> "ReplyNotebookOpened", "Draft" -> draft,
      "Translate" -> translate, "PrivacyLevel" -> pl|>];

(* ---- \:30a4\:30f3\:30bf\:30e9\:30af\:30c6\:30a3\:30d6\:8868 (\:65e7 maildb showMails \:8e0f\:8972) ---- *)
(* \:65e5\:4ed8: JST \:306b\:5909\:63db\:3057\:30b3\:30f3\:30d1\:30af\:30c8\:8868\:793a "2026/06/05 \:6728 14:53" (maildb formatDateJST \:8e0f\:8972) *)
iSVUIJstDay = <|"Monday" -> "\:6708", "Tuesday" -> "\:706b", "Wednesday" -> "\:6c34",
   "Thursday" -> "\:6728", "Friday" -> "\:91d1", "Saturday" -> "\:571f", "Sunday" -> "\:65e5"|>;
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

(* \:6dfb\:4ed8 ActionMenu: \:540d\:524d\:3054\:3068\:306b\:958b\:304f Popup\:3002\:540d\:524d\:304c\:7121\:3044\:65e7 snapshot \:306f\:518d import \:3092\:4fc3\:3059\:3002 *)
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

(* \:8868\:30c6\:30ad\:30b9\:30c8\:30d5\:30a9\:30f3\:30c8 (ClaudeCode`$ClaudeStandardFont\:3001\:672a\:30ed\:30fc\:30c9\:6642\:30d5\:30a9\:30fc\:30eb\:30d0\:30c3\:30af) *)
iSVUIFont[] :=
  With[{f = Quiet@Check[ClaudeCode`$ClaudeStandardFont, $Failed]},
    If[StringQ[f] && f =!= "", f, "Yu Gothic UI"]];

(* identity \:30b9\:30c8\:30a2\:306e\:81ea\:52d5\:30ed\:30fc\:30c9 (UI \:3092\:958b\:3044\:305f\:3068\:304d\:672a\:30ed\:30fc\:30c9\:3067\:3082\:52d5\:304f\:3088\:3046\:306b)\:3002\:672a\:30ed\:30fc\:30c9\:306a\:3089 safe\:3002 *)
iSVUIIdentityEnsureLoaded[] :=
  Quiet@Check[If[Length[DownValues[SourceVault`SourceVaultIdentityEnsureLoaded]] > 0,
     SourceVault`SourceVaultIdentityEnsureLoaded[], Null], Null];

(* ---- i18n: \:82f1\:8a9e\:30ad\:30fc -> $Language \:3067\:65e5\:82f1\:30e9\:30d9\:30eb\:306b\:89e3\:6c7a (iL\:5316\:5bfe\:5fdc) ----
   \:30b3\:30fc\:30c9/\:30b9\:30ad\:30fc\:30de\:306e\:30ad\:30fc\:306f\:82f1\:8a9e\:56fa\:5b9a\:3002\:8868\:793a\:30e9\:30d9\:30eb\:3060\:3051 $Language \:3067\:5207\:66ff\:3002 *)
$iSVUILabels = <|
  "Att" -> <|"Japanese" -> "\:6dfb\:4ed8", "English" -> "Att"|>,
  "Reply" -> <|"Japanese" -> "\:8fd4\:4fe1", "English" -> "Reply"|>,
  "Opens" -> <|"Japanese" -> "\:958b\:5c01", "English" -> "Opens"|>,
  "Replied" -> <|"Japanese" -> "\:8fd4\:4fe1\:6e08", "English" -> "Replied"|>,
  "Date" -> <|"Japanese" -> "\:65e5\:4ed8", "English" -> "Date"|>,
  "Pri" -> <|"Japanese" -> "\:91cd\:8981", "English" -> "Pri"|>,
  "Sec" -> <|"Japanese" -> "\:79d8\:533f", "English" -> "Sec"|>,
  "Subject" -> <|"Japanese" -> "\:4ef6\:540d", "English" -> "Subject"|>,
  "From" -> <|"Japanese" -> "\:5dee\:51fa\:4eba", "English" -> "From"|>,
  "Summary" -> <|"Japanese" -> "\:6982\:8981", "English" -> "Summary"|>,
  "Cat" -> <|"Japanese" -> "\:5206\:985e", "English" -> "Cat"|>,
  "Deadline" -> <|"Japanese" -> "\:3006\:5207", "English" -> "Due"|>,
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

(* \:5de6\:5bc4\:305b\:30fb\:5168\:6587 Tooltip \:3064\:304d\:30c6\:30ad\:30b9\:30c8\:30bb\:30eb (\:5148\:982d\:304c\:5207\:308c\:306a\:3044\:3088\:3046\:306b) *)
iSVUITextCell[s_] :=
  With[{t = If[StringQ[s], s, ToString[s]], ff = iSVUIFont[]},
    Item[Tooltip[Style[t, "Text", FontFamily -> ff], t], Alignment -> Left]];

(* Missing/Null \:306f\:7a7a\:6587\:5b57\:306b *)
iSVUIShow[x_] := Which[MissingQ[x] || x === Null, "", StringQ[x], x, True, ToString[x]];

(* \:30ab\:30c6\:30b4\:30ea\:30c8\:30fc\:30af\:30f3 -> \:77ed\:3044\:8868\:793a\:30e9\:30d9\:30eb (\:5217\:5e45\:7bc0\:7d04)\:3002Tooltip \:306b\:30c8\:30fc\:30af\:30f3\:540d *)
$iSVUICategoryShort = <|
  "InfoProvision" -> <|"Japanese" -> "\:60c5\:5831", "English" -> "Info"|>,
  "AttendanceRequest" -> <|"Japanese" -> "\:51fa\:5e2d", "English" -> "Attend"|>,
  "TaskRequest" -> <|"Japanese" -> "\:4f5c\:696d", "English" -> "Task"|>,
  "Confirmation" -> <|"Japanese" -> "\:78ba\:8a8d", "English" -> "Confirm"|>,
  "Report" -> <|"Japanese" -> "\:5831\:544a", "English" -> "Report"|>,
  "Notice" -> <|"Japanese" -> "\:901a\:77e5", "English" -> "Notice"|>,
  "Other" -> <|"Japanese" -> "\:4ed6", "English" -> "Other"|>|>;

iSVUICategoryCell[c_, ff_] :=
  Module[{e, lang, lbl},
    If[! StringQ[c], Return[""]];
    e = Lookup[$iSVUICategoryShort, c, <||>];
    lang = If[$Language === "Japanese", "Japanese", "English"];
    lbl = Lookup[e, lang, Lookup[e, "English", c]];
    (* \:4ef6\:540d\:30bb\:30eb (iSVUITextCell) \:3068\:540c\:4e00\:69cb\:9020\:306b\:3059\:308b\:3002Tooltip \:5185\:306e\:7d20\:306e Style[\:6587\:5b57\:5217] \:306f
       Dataset \:30bb\:30eb\:3067 ShowStringCharacters \:304c\:52b9\:304d "\:901a\:77e5" \:3068\:5f15\:7528\:7b26\:4ed8\:304d\:3067\:8868\:793a\:3055\:308c\:308b
       (\:30e6\:30fc\:30b6\:30fc\:5831\:544a)\:3002"Text" \:30b9\:30bf\:30a4\:30eb (ShowStringCharacters->False) + Item \:3067\:6291\:6b62\:3002
       Tooltip \:306b\:306f\:30ab\:30c6\:30b4\:30ea\:30c8\:30fc\:30af\:30f3\:540d\:3092\:51fa\:3059\:3002 *)
    Item[Tooltip[Style[lbl, "Text", FontFamily -> ff], c], Alignment -> Left]];

(* \:3006\:5207 ISO \:6587\:5b57\:5217 -> "2026/06/19 17:00" / "2026/06/19" \:306e\:30b3\:30f3\:30d1\:30af\:30c8\:8868\:793a *)
iSVUIFormatDeadline[dl_] :=
  If[! StringQ[dl], "",
    StringReplace[If[StringLength[dl] >= 16, StringTake[dl, 16], dl],
      {"-" -> "/", "T" -> " "}]];

Options[SourceVaultMailView] = Options[SourceVault`SourceVaultSearchMailSnapshots];
(* \:8fd4\:4fe1\:6e08\:30bb\:30eb: \:8fd4\:4fe1\:56de\:6570>0 \:306a\:3089\:7dd1\:30c1\:30a7\:30c3\:30af (Tooltip \:306b\:65e5\:6642\:30fb\:56de\:6570)\:3001\:306a\:3051\:308c\:3070\:7a7a\:3002
   Dataset \:30bb\:30eb\:3067\:306f ShowStringCharacters \:304c\:52b9\:304d\:7d20\:306e\:6587\:5b57\:5217\:306b\:5f15\:7528\:7b26\:304c\:4ed8\:304f\:305f\:3081\:660e\:793a False\:3002 *)
iSVUIRepliedCell[rid_, ff_] :=
  With[{n = iSVMDRepliedCountOf[rid], at = iSVMDRepliedAtOf[rid]},
    If[IntegerQ[n] && n > 0,
      Tooltip[
        Style["\[Checkmark]", Darker@Green, Bold, FontFamily -> ff, ShowStringCharacters -> False],
        "\:8fd4\:4fe1\:6e08: " <> at <> If[n > 1, " (" <> ToString[n] <> "\:56de)", ""]],
      ""]];

(* \:958b\:5c01\:56de\:6570\:30bb\:30eb: 0 \:306f\:7a7a\:3001>0 \:306f\:56de\:6570 (\:5f15\:7528\:7b26\:6291\:6b62) *)
iSVUIOpensCell[rid_, ff_] :=
  With[{n = iSVMDOpenCountOf[rid]},
    If[IntegerQ[n] && n > 0,
      Style[ToString[n], FontFamily -> ff, ShowStringCharacters -> False], ""]];

SourceVaultMailView[query_String : "", opts : OptionsPattern[]] :=
  Module[{snaps, rows, ff = iSVUIFont[]},
    snaps = SourceVault`SourceVaultSearchMailSnapshots[query, opts];
    (* \:958b\:5c01\:56de\:6570\:30fb\:8fd4\:4fe1\:6e08\:306f\:6700\:65b0\:3092\:30c7\:30a3\:30b9\:30af\:304b\:3089\:8aad\:3080 (\:4ed6\:30bb\:30c3\:30b7\:30e7\:30f3/\:5225 PC \:53cd\:6620) *)
    iSVMDInteractionLoad[];
    (* \:30a2\:30af\:30b7\:30e7\:30f3\:306f maildb \:540c\:69d8\:306b\:5217\:3092\:5206\:3051\:308b (1 \:30bb\:30eb\:306b\:8a70\:3081\:308b\:3068\:5e45\:8d85\:904e\:3067 "..." \:306b\:306a\:308b)\:3002
       \:30d5\:30a9\:30f3\:30c8\:306f Dataset \:306e BaseStyle \:304c\:7121\:3044\:306e\:3067\:30bb\:30eb\:3054\:3068\:306b\:9069\:7528\:3059\:308b\:3002 *)
    rows = Function[s,
       With[{r = Lookup[s, "RecordId", ""], md = s["MailMetadataPublic"], dv = s["Derived"]},
         <|"" -> Button["\:2709", SourceVaultMailShowBody[r],
              Appearance -> "Frameless", Method -> "Queued"],
           iSVL["Att"] -> iSVUIAttachMenu[s],
           iSVL["Reply"] -> Button["\:21a9", SourceVaultMailOpenReplyNotebook[r],
              Appearance -> "Frameless", Method -> "Queued"],
           iSVL["Opens"] -> iSVUIOpensCell[r, ff],
           iSVL["Replied"] -> iSVUIRepliedCell[r, ff],
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
    (* PL >= 0.5 \:306e\:30e1\:30fc\:30eb\:3092\:542b\:3080\:5834\:5408\:306f Confidential \:5024\:3068\:3057\:3066\:8fd4\:3059
       (\:4ee3\:5165\:5148\:5909\:6570\:3082\:79d8\:5bc6\:767b\:9332\:3055\:308c\:3001\:6d3e\:751f\:5024\:306e\:30bb\:30eb\:306b\:3082\:4f1d\:64ad\:3059\:308b) *)
    iSVMDWrapConfidential[
      Pane[
        Dataset[rows,
          (* \:26a0\:fe0f\:3053\:306e ItemSize \:5f62\:5f0f\:306f Dataset \:5185\:30dc\:30bf\:30f3\:306e\:5f53\:305f\:308a\:9818\:57df\:3092\:63cf\:753b\:3068\:30ba\:30e9\:3059\:526f\:4f5c\:7528\:304c\:3042\:308a\:3001
             SourceVaultMailSearchIndexView \:3067\:306f2\:5217\:76ee\:4ee5\:964d\:304c\:62bc\:305b\:306a\:304f\:306a\:3063\:305f\:305f\:3081\:64a4\:53bb\:3057\:305f\:3002
             MailView \:306f\:73fe\:884c\:306e\:5217\:5e45\:3067\:5076\:7136\:30af\:30ea\:30c3\:30af\:53ef\:80fd\:306a\:305f\:3081\:636e\:3048\:7f6e\:304d (\:5909\:66f4\:6642\:306f\:8981\:30af\:30ea\:30c3\:30af\:78ba\:8a8d) *)
          ItemSize -> {2, {3, 4, 3, 4, 4, 15, 3, 3, 5, 12, 28, 14, 40}},
          Alignment -> {Left, Center},
          (* MaxItems -> {\:6700\:5927\:884c\:6570, \:6700\:5927\:5217\:6570}\:3002\:7b2c2\:8981\:7d20\:3092\:884c\:6570\:306b\:7e1b\:308b\:3068
             \:5c11\:4ef6\:6570\:6642\:306b\:5217\:304c\:96a0\:308c\:308b\:306e\:3067 All (\:5168\:5217\:30fb\:5168\:884c) \:306b\:3059\:308b\:3002 *)
          MaxItems -> {$SourceVaultMailViewMaxRows, All}],
        ImageSize -> Full],
      snaps]];

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   \:7d22\:5f15\:884c View + \:30b9\:30ec\:30c3\:30c9 \:30a2\:30a6\:30c8\:30e9\:30a4\:30f3\:7a93 (\:30b7\:30e3\:30fc\:30c9\:975e\:30ed\:30fc\:30c9\:691c\:7d22\:306e\:8868\:793a\:5c64)
   \:65b9\:91dd (\:5168 SourceVault \:5171\:901a): \:691c\:7d22/\:30d5\:30a3\:30eb\:30bf\:306e core \:306f\:9023\:60f3\:30ea\:30b9\:30c8\:3092\:8fd4\:3059\:7d14\:30c7\:30fc\:30bf
   \:95a2\:6570 (\:5f8c\:6bb5\:51e6\:7406\:3067\:9023\:9396\:53ef)\:3002\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:51fa\:529b\:306f View \:95a2\:6570\:304c Dataset+UI \:5316\:3057\:3001
   \:4e00\:5ea6\:306b\:8868\:793a\:3059\:308b\:4ef6\:6570\:306e\:5236\:9650\:3082 View \:5c64\:3067\:884c\:3046 ($SourceVaultMailViewMaxRows)\:3002
   \:7d22\:5f15\:306f .svmailidx sidecar (\:4f4e\:6f0f\:6d29\:30e1\:30bf) \:306a\:306e\:3067\:672c\:6587\:30b7\:30e3\:30fc\:30c9\:3092\:4e00\:5207\:30ed\:30fc\:30c9\:305b\:305a
   \:691c\:7d22\:3067\:304d\:3001\:2709/\:2630 \:30af\:30ea\:30c3\:30af\:6642\:306b\:5fc5\:8981\:30b7\:30e3\:30fc\:30c9\:3060\:3051\:9045\:5ef6\:30ed\:30fc\:30c9\:3059\:308b\:3002
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550 *)

(* \:7d22\:5f15\:884c (flat) \:306e PL: \:30d5\:30a7\:30a4\:30eb\:30bb\:30fc\:30d5\:3067\:6b20\:843d\:306f 1.0 (\:79d8\:533f) \:6271\:3044 *)
iSVMDIxProbePL[row_] := With[{p = Lookup[row, "PrivacyLevel", Missing[]]},
  If[NumericQ[p], N[p], 1.0]];
iSVMDIxConfidentialQ[rows_List] := rows =!= {} && TrueQ[Max[iSVMDIxProbePL /@ rows] >= 0.5];
iSVMDIxWrapConfidential[result_, rows_List] :=
  Which[
    ! iSVMDIxConfidentialQ[rows], result,
    Length[DownValues[ClaudeCode`Confidential]] > 0, ClaudeCode`Confidential[result],
    True,
    (Quiet@Check[
       If[TrueQ[$Notebooks],
         With[{nb = EvaluationNotebook[]},
           If[Head[nb] === NotebookObject,
             SessionSubmit[ScheduledTask[
               Quiet@Check[SourceVault`SourceVaultMarkConfidentialViewCells[nb], Null], {1.0}]]]]],
       Null];
     result)];

(* record \:306e shard \:3092\:5fc5\:8981\:6642\:306e\:307f\:9045\:5ef6\:30ed\:30fc\:30c9\:3057\:3066 snapshot \:3092\:8fd4\:3059 (\:7d22\:5f15\:884c\:306e ShardKey \:7d4c\:7531) *)
iSVMDIxEnsureLoaded[recordId_String, shardKey_] :=
  Module[{snap = SourceVaultMailSnapshotGet[recordId]},
    If[! MissingQ[snap], Return[snap]];
    If[StringQ[shardKey] && ! TrueQ[Lookup[$iSVMDLoadedShards, shardKey, False]],
      Quiet@Check[SourceVaultMailLoadShard[shardKey], 0]];
    SourceVaultMailSnapshotGet[recordId]];

iSVMDIxShowBody[recordId_String, shardKey_] :=
  Module[{snap = iSVMDIxEnsureLoaded[recordId, shardKey]},
    If[MissingQ[snap],
      Quiet@Check[CreateDocument[{
          Cell[iSVL["DecryptFailTitle"], "Subtitle"],
          Cell["Shard not loadable: " <> ToString[shardKey], "Text"]},
          StyleDefinitions -> $SourceVaultMailNotebookStyle], $Failed],
      SourceVaultMailShowBody[recordId]]];

Options[SourceVaultMailSearchIndexView] = Options[SourceVaultMailSearchIndex];
SourceVaultMailSearchIndexView[query_String : "", opts : OptionsPattern[]] :=
  Module[{rows, ff = iSVUIFont[], urows},
    rows = SourceVaultMailSearchIndex[query, opts];
    If[rows === {}, Return[Style[iSVL["NoMail"], "Text"]]];
    urows = Function[r,
       With[{rid = ToString@Lookup[r, "RecordId", ""], sk = Lookup[r, "ShardKey", Missing[]]},
         <|"" -> Button["\:2709", iSVMDIxShowBody[rid, sk],
              Appearance -> "Frameless", Method -> "Queued"],
           (* action \:306b\:306f\:5c0f\:3055\:3044\:30ea\:30c6\:30e9\:30eb\:3060\:3051\:3092\:57cb\:3081\:8fbc\:3080 (\:884c\:306e\:9023\:60f3\:3092\:57cb\:3081\:8fbc\:3080\:3068
              Dataset \:304c\:30bb\:30eb\:3092\:5927\:304d\:3059\:304e\:308b\:5f0f\:3068\:3057\:3066 "..." \:306b\:7701\:7565\:3057\:30dc\:30bf\:30f3\:304c\:62bc\:305b\:306a\:3044)\:3002
              \:30b3\:30f3\:30c8\:30ed\:30fc\:30eb\:306f MailView \:306e \:2709/\:21a9 \:3068\:540c\:3058\:300c\:7d20\:306e Frameless + \:6587\:5b57\:5217\:30e9\:30d9\:30eb\:300d\:3002
              \:203b2\:5217\:76ee\:4ee5\:964d\:304c\:62bc\:305b\:306a\:3044\:5834\:5408\:306e\:771f\:56e0\:306f Dataset \:306e\:4e0d\:6b63 ItemSize (\:4e0b\:8a18) *)
           "\:30b9\:30ec" -> Button["\:30b9\:30ec", SourceVaultMailThreadNotebook[rid],
              Appearance -> "Frameless", Method -> "Queued"],
           iSVL["Date"] -> Style[iSVUIFormatDateJST[Lookup[r, "Date", Missing[]]], FontFamily -> ff],
           iSVL["Pri"] -> Style[iSVUINumCell[Lookup[r, "Priority", Missing[]]], FontFamily -> ff],
           iSVL["Sec"] -> Style[iSVUINumCell[Lookup[r, "PrivacyLevel", Missing[]]], FontFamily -> ff],
           iSVL["Cat"] -> iSVUICategoryCell[Lookup[r, "Category", Missing[]], ff],
           iSVL["Deadline"] -> Style[iSVUIFormatDeadline[Lookup[r, "Deadline", Missing[]]],
              FontFamily -> ff],
           iSVL["Subject"] -> iSVUITextCell[ToString@Lookup[r, "Subject", ""]],
           iSVL["From"] -> iSVUITextCell[ToString@Lookup[r, "From", Lookup[r, "FromRaw", ""]]],
           iSVL["Summary"] -> iSVUITextCell[With[{sm = Lookup[r, "Summary", ""]},
              If[StringQ[sm], sm, ""]]]|>]] /@ rows;
    (* \:5217\:5e45\:306f MailView \:3068\:540c\:3058\:5024\:3067\:3001\:26a0\:fe0f\:6b63\:898f\:306e Grid \:6587\:6cd5 {{\:5217\:5e45\:30ea\:30b9\:30c8}, Automatic} \:3092\:4f7f\:3046\:3002
       MailView \:7531\:6765\:306e {2, {\:5217\:5e45\:30ea\:30b9\:30c8}} \:5f62\:5f0f\:306f\:4e0d\:6b63\:6587\:6cd5\:3067\:3001\:63cf\:753b\:306f\:305d\:308c\:3089\:3057\:304f\:51fa\:308b\:304c
       2\:5217\:76ee\:4ee5\:964d\:306e\:57cb\:3081\:8fbc\:307f\:30dc\:30bf\:30f3\:306e\:5f53\:305f\:308a\:5224\:5b9a\:304c\:58ca\:308c\:308b (\:5e45\:3092 6 \:306b\:5e83\:3052\:3066\:3082\:6b7b\:306c\:3001\:3092\:5b9f\:6e2c\:78ba\:5b9a)\:3002
       \:5217\:69cb\:6210\:3092\:5909\:3048\:305f\:3089\:5fc5\:305a\:30b9\:30ec/\:2709 \:306e\:30af\:30ea\:30c3\:30af\:3092\:5b9f\:6a5f\:78ba\:8a8d\:3059\:308b\:3053\:3068 *)
    iSVMDIxWrapConfidential[
      Pane[
        Dataset[urows,
          ItemSize -> {{3, 6, 15, 3, 3, 5, 12, 28, 14, 40}, Automatic},
          Alignment -> {Left, Center},
          MaxItems -> {$SourceVaultMailViewMaxRows, All}],
        ImageSize -> Full],
      rows]];

(* Re:/Fwd: \:7b49\:3092\:5265\:304c\:3057\:305f\:6b63\:898f\:5316\:4ef6\:540d = \:30b9\:30ec\:30c3\:30c9 key (\:7d22\:5f15\:884c\:3060\:3051\:3067\:5224\:5b9a\:3067\:304d\:308b) *)
iSVMDIxNormSubject[s_] := If[! StringQ[s], "",
  Module[{t = ToLowerCase@StringTrim[s]},
    t = FixedPoint[StringTrim@StringReplace[#,
       StartOfString ~~ RegularExpression["(re|fwd|fw)\\s*[:\:ff1a]\\s*"] -> ""] &, t];
    StringReplace[t, RegularExpression["\\s+"] -> " "]]];

Options[SourceVaultMailThreadNotebook] = {"MaxMails" -> 50};
SourceVaultMailThreadNotebook[record_, OptionsPattern[]] :=
  Module[{seed, mbox, subjN, rows, thread, shardKeys, cells, maxPL, nb,
      maxMails = OptionValue["MaxMails"]},
    seed = Which[
      AssociationQ[record], record,
      StringQ[record], SourceVaultMailIndexGet[record],
      True, Missing["BadArg"]];
    If[! AssociationQ[seed],
      Return[<|"Status" -> "Error", "Reason" -> "RecordNotFoundInIndex"|>]];
    mbox = Lookup[seed, "MBox", Automatic];
    subjN = iSVMDIxNormSubject[Lookup[seed, "Subject", ""]];
    (* \:30e1\:30f3\:30d0\:30fc\:7279\:5b9a\:306f\:7d22\:5f15 sidecar \:306e\:307f (\:30b7\:30e3\:30fc\:30c9\:975e\:30ed\:30fc\:30c9)\:3002\:7a7a\:4ef6\:540d\:306f\:5358\:72ec\:30b9\:30ec\:30c3\:30c9\:6271\:3044 *)
    thread = If[subjN === "", {seed},
      Select[SourceVaultMailSearchIndex["", "MBox" -> If[StringQ[mbox], mbox, Automatic]],
        iSVMDIxNormSubject[Lookup[#, "Subject", ""]] === subjN &]];
    If[thread === {}, thread = {seed}];
    thread = Take[SortBy[thread, Lookup[#, "Date", ""] &], UpTo[maxMails]];
    (* \:672c\:6587\:8868\:793a\:306b\:5fc5\:8981\:306a\:30b7\:30e3\:30fc\:30c9\:3060\:3051\:9045\:5ef6\:30ed\:30fc\:30c9 *)
    shardKeys = DeleteDuplicates@Select[Lookup[#, "ShardKey", Missing[]] & /@ thread, StringQ];
    Scan[If[! TrueQ[Lookup[$iSVMDLoadedShards, #, False]],
        Quiet@Check[SourceVaultMailLoadShard[#], 0]] &, shardKeys];
    maxPL = Max[iSVMDIxProbePL /@ thread];
    (* \:30a2\:30a6\:30c8\:30e9\:30a4\:30f3: Title=\:4ef6\:540d\:3001\:5404\:30e1\:30fc\:30eb = Section(\:65e5\:4ed8+\:5dee\:51fa\:4eba)+\:672c\:6587 Text\:3002
       Section \:30bb\:30eb\:306f\:5f8c\:7d9a\:30bb\:30eb\:3092\:81ea\:52d5\:30b0\:30eb\:30fc\:30d7\:5316\:3059\:308b\:306e\:3067\:6298\:308a\:305f\:305f\:307f/\:30a2\:30a6\:30c8\:30e9\:30a4\:30f3\:304c\:52b9\:304f *)
    cells = Join[
      {Cell[ToString@Lookup[seed, "Subject", If[subjN === "", "(no subject)", subjN]], "Title"],
       Cell[ToString[Length[thread]] <> " mails / " <> ToString[mbox], "Subtitle"]},
      Flatten@Map[Function[r, Module[{rid = ToString@Lookup[r, "RecordId", ""], snap, bodyR, body},
         snap = SourceVaultMailSnapshotGet[rid];
         bodyR = If[AssociationQ[snap], SourceVaultMailGetBody[snap],
            <|"Status" -> "Error", "Reason" -> "SnapshotNotLoaded"|>];
         body = If[Lookup[bodyR, "Status", ""] === "Ok", iSVUIReadableBody[bodyR["Body"]],
            "[" <> ToString@Lookup[bodyR, "Reason", Lookup[bodyR, "Status", "Unknown"]] <> "]"];
         {Cell[ToString@iSVUIFormatDateJST[Lookup[r, "Date", Missing[]]] <> "   " <>
             ToString@Lookup[r, "From", Lookup[r, "FromRaw", ""]], "Section"],
          Cell[ToString@Lookup[r, "Subject", ""], "Subsection"],
          Cell[body, "Text"]}]], thread]];
    nb = Quiet@Check[
      CreateDocument[cells,
        WindowTitle -> "Thread: " <> ToString@Lookup[seed, "Subject", subjN],
        StyleDefinitions -> $SourceVaultMailNotebookStyle], $Failed];
    (* \:5168\:30bb\:30eb\:306b\:30b9\:30ec\:30c3\:30c9\:6700\:5927 PL \:3092\:4ed8\:4e0e (\:3053\:306e\:7a93\:304b\:3089\:306e LLM \:547c\:3073\:51fa\:3057\:3067 cloud gate \:304c\:52b9\:304f) *)
    iSVUIMarkCellsConfidential[nb, maxPL];
    Scan[Quiet@Check[iSVMDRecordOpen[ToString@Lookup[#, "RecordId", ""]], Null] &, thread];
    <|"Status" -> If[Head[nb] === NotebookObject, "Shown", "NoFrontEnd"],
      "Mails" -> Length[thread], "PrivacyLevel" -> maxPL, "LoadedShards" -> shardKeys|>];

(* From \:8868\:793a (AddressBook \:89e3\:6c7a) -- maildb \:306e SummaryRow \:3068\:540c\:3058\:898f\:5247 *)
iSVUIFromDisplayUI[s_] :=
  Module[{fc, c},
    fc = Lookup[s["AddressBookRefs"], "FromContact", Missing[]];
    If[StringQ[fc],
      c = Quiet@Check[SourceVault`SourceVaultAddressBookGetContact[fc], Missing[]];
      If[AssociationQ[c] && StringQ[Lookup[c, "DisplayName", Null]], Return[c["DisplayName"]]]];
    With[{raw = Lookup[s["MailMetadataPublic"], "From", Missing[]]},
      If[StringQ[raw], raw, Missing["Unknown"]]]];

(* ---- \:30a2\:30c9\:30ec\:30b9\:5e33 \:8868\:793a ---- *)
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

(* ---- \:8b58\:5225\:5b50 -> \:5b9f\:4f53 \:30ea\:30f3\:30af\:7de8\:96c6 UI (\:65b0\:898f\:4f5c\:6210 / \:65e2\:5b58\:30de\:30fc\:30b8) ---- *)
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
             (* \:30a2\:30af\:30b7\:30e7\:30f3\:306f\:5225\:5217\:306b (1 \:30bb\:30eb\:306b\:8a70\:3081\:308b\:3068\:5e45\:8d85\:904e\:3067 "..." \:306b\:306a\:308b) *)
             <|"" -> Button[iSVL["New"],
                  SourceVault`SourceVaultIdentifierCreateEntity[id]; refresh++,
                  Method -> "Queued"],
               iSVL["Merge"] -> ActionMenu[iSVL["Merge"],
                  Append[iSVUIEntityMenuItems[id, ents] /.
                     (lab_ :> act_) :> (lab :> (act; refresh++)),
                    "\[LongDash]"],
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

(* ---- \:5b9f\:4f53 \:4e00\:89a7 + \:7de8\:96c6 ---- *)
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

(* \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550
   \:30e1\:30fc\:30eb View \:51fa\:529b\:30bb\:30eb\:306e\:81ea\:52d5\:6a5f\:5bc6\:30de\:30fc\:30af (2026-06)
   \[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]\[HorizontalLine]
   \:65b9\:91dd: \:30e1\:30fc\:30eb View \:8868\:306f\:300c\:751f\:30c7\:30fc\:30bf\:300d\:306a\:306e\:3067\:3001\:8868\:793a\:30e1\:30fc\:30eb\:306e\:6700\:5927 Derived.PrivacyLevel
   \:3092\:305d\:306e\:30bb\:30eb\:306e PrivacyLevel \:3068\:3057\:3066\:6a5f\:5bc6\:30de\:30fc\:30af\:3059\:308b\:3002NBMakeContextPacket \:306e\:95be\:5024
   (\:30af\:30e9\:30a6\:30c9 0.5 / \:30ed\:30fc\:30ab\:30eb lmstudio 1.0) \:3068\:7d44\:307f\:5408\:308f\:3055\:308a\:3001\:30af\:30e9\:30a6\:30c9\:8a55\:4fa1\:3067\:306f
   \:30b9\:30ad\:30fc\:30de\:306e\:307f\:3001\:30ed\:30fc\:30ab\:30eb\:8a55\:4fa1\:3067\:306f\:5168\:6587\:304c\:9001\:3089\:308c\:308b\:3002\:516c\:958b\:30e1\:30fc\:30eb\:306e\:307f (\:6700\:5927PL<=0.5)
   \:306e\:8868\:306f\:30de\:30fc\:30af\:3057\:306a\:3044 (\:30af\:30e9\:30a6\:30c9\:3067\:3082\:5168\:6587\:53ef)\:3002
   \:4f9d\:5b58\:65b9\:5411 (SourceVault -> NBAccess) \:3092\:5b88\:308a\:3001\:30d5\:30c3\:30af\:306f SourceVault \:5074\:304b\:3089
   NBAccess`NBMakeContextPacket \:306b\:300c\:518d\:5165\:30ac\:30fc\:30c9\:4ed8\:304d\:306e\:9ad8\:512a\:5148 DownValue \:8ffd\:52a0\:300d\:3067
   \:88c5\:7740\:3059\:308b (\:672c\:4f53\:5b9a\:7fa9\:30fbOptions \:306f\:58ca\:3055\:306a\:3044)\:3002
   \:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550\:2550 *)

(* \:5165\:529b\:30c6\:30ad\:30b9\:30c8\:304c\:30e1\:30fc\:30eb View \:7cfb\:547c\:3073\:51fa\:3057\:3092\:542b\:3080\:304b *)
iSVMailViewInputQ[text_String] :=
  StringContainsQ[text,
    RegularExpression["SourceVaultMail(View|Dataset|SearchSummary|SearchIndexView)\\s*\\["]];
iSVMailViewInputQ[_] := False;

(* \:6a5f\:5bc6\:5224\:5b9a\:7528 PL \:30a2\:30af\:30bb\:30b5: \:30d5\:30a7\:30a4\:30eb\:30bb\:30fc\:30d5\:3067 PrivacyLevel \:6b20\:843d\:306f 1.0 (\:79d8\:533f) \:6271\:3044\:3002
   (\:691c\:7d22\:30d5\:30a3\:30eb\:30bf\:7528 iSVMDPrivacy \:306f\:6b20\:843d\:3092 0 \:306b\:3059\:308b\:306e\:3067\:6a5f\:5bc6\:5224\:5b9a\:306b\:306f\:4f7f\:308f\:306a\:3044) *)
iSVMailProbePL[s_] :=
  With[{p = Quiet@Check[Lookup[Lookup[s, "Derived", <||>], "PrivacyLevel", Missing[]], Missing[]]},
    If[NumericQ[p], N[p], 1.0]];

(* View/Dataset/SearchSummary \:3092 read-only \:306b\:5dee\:3057\:66ff\:3048\:308b\:30d7\:30ed\:30fc\:30d6: \:540c\:3058\:30af\:30a8\:30ea\:3067
   \:30e1\:30e2\:30ea\:5185 snapshot \:3092\:691c\:7d22\:3057\:3001\:8868\:793a\:30e1\:30fc\:30eb\:306e\:6700\:5927 PrivacyLevel \:3092\:8fd4\:3059\:3002 *)
iSVMailPLProbe[query_String : "", opts : OptionsPattern[SourceVaultSearchMailSnapshots]] :=
  Module[{snaps},
    snaps = Quiet@Check[SourceVaultSearchMailSnapshots[query, opts], {}];
    If[ListQ[snaps] && Length[snaps] > 0, Max[iSVMailProbePL /@ snaps], 0.0]];
iSVMailPLProbe[___] := 1.0;

(* SearchIndexView \:7528 probe: sidecar \:7d22\:5f15\:3060\:3051\:518d\:691c\:7d22\:3057\:3066\:6700\:5927 PL (\:30b7\:30e3\:30fc\:30c9\:975e\:30ed\:30fc\:30c9) *)
iSVMailIxPLProbe[query_String : "", opts : OptionsPattern[SourceVaultMailSearchIndex]] :=
  Module[{rows},
    rows = Quiet@Check[SourceVaultMailSearchIndex[query, opts], {}];
    If[ListQ[rows] && Length[rows] > 0, Max[iSVMDIxProbePL /@ rows], 0.0]];
iSVMailIxPLProbe[___] := 1.0;

(* \:5165\:529b\:30c6\:30ad\:30b9\:30c8\:304b\:3089 View \:547c\:3073\:51fa\:3057\:3060\:3051\:3092\:629c\:304d\:51fa\:3057\:3066\:30d7\:30ed\:30fc\:30d6\:8a55\:4fa1\:3057\:3001\:6700\:5927 PL \:3092\:5f97\:308b\:3002
   \:5165\:529b\:5168\:4f53\:306f\:518d\:8a55\:4fa1\:3057\:306a\:3044 (EnsureLoaded \:7b49\:306e\:526f\:4f5c\:7528\:3092\:518d\:5b9f\:884c\:3057\:306a\:3044)\:3002\:5931\:6557\:6642\:306f\:5b89\:5168\:5074 1.0\:3002 *)
iSVMailCellMaxPLFromText[text_String] :=
  Module[{held, vals},
    held = Quiet@Check[ToExpression[text, InputForm, HoldComplete], $Failed];
    If[held === $Failed, Return[1.0]];
    vals = Quiet@Check[
      Cases[held,
        {HoldPattern[(SourceVaultMailView | SourceVaultMailDataset |
             SourceVaultMailSearchSummary)[a___]] :> iSVMailPLProbe[a],
         HoldPattern[SourceVaultMailSearchIndexView[a___]] :> iSVMailIxPLProbe[a]},
        {0, Infinity}], {}];
    If[ListQ[vals] && Length[vals] > 0 && AllTrue[vals, NumericQ], Max[vals], 1.0]];
iSVMailCellMaxPLFromText[_] := 1.0;

(* \[HorizontalLine]\[HorizontalLine] Todo (\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:672c\:4f53\:30bb\:30eb\:306e\:751f\:30c6\:30ad\:30b9\:30c8) \:7528 \[HorizontalLine]\[HorizontalLine]
   SourceVaultUpcomingSchedule / FormatNotebookList \:306e\:8868 (Summary \:5217) \:306f
   \:30af\:30e9\:30a6\:30c9\:5b89\:5168\:306b\:751f\:6210\:3055\:308c\:308b\:306e\:3067\:5bfe\:8c61\:5916\:3002SourceVaultFindTodos \:306f TodoText \:306b
   \:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:672c\:4f53\:306e\:751f\:30bb\:30eb\:3092\:542b\:3080\:305f\:3081\:3001\:30bd\:30fc\:30b9 NB \:304c Public \:3067\:306a\:3044\:9650\:308a\:79d8\:533f\:3059\:308b\:3002 *)
iSVTodoViewInputQ[text_String] :=
  StringContainsQ[text, RegularExpression["SourceVaultFindTodos\\s*\\["]];
iSVTodoViewInputQ[_] := False;

(* FindTodos \:3092 read-only \:518d\:5b9f\:884c\:3057\:3001\:30bd\:30fc\:30b9 NB \:306e Publishable \:3092\:898b\:308b\:3002
   \:5168\:30bd\:30fc\:30b9 NB \:304c CloudPublishable===True (Public) \:306a\:3089 0.0 (\:30af\:30e9\:30a6\:30c9\:53ef)\:3001
   1 \:3064\:3067\:3082\:975e Public (Unspecified/False) \:304c\:3042\:308c\:3070 1.0 (\:79d8\:533f)\:3002 *)
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

(* \:6a5f\:5bc6\:5bfe\:8c61 View \:306e\:4ed5\:69d8: {\:5165\:529b\:5224\:5b9a(text->bool), \:6700\:5927PL\:7b97\:51fa(text->pl)} \:306e\:30ea\:30b9\:30c8\:3002
   \:30e1\:30fc\:30eb (Derived.PrivacyLevel) \:3068 Todo \:751f\:30c6\:30ad\:30b9\:30c8 (\:30bd\:30fc\:30b9 NB \:306e Publishable) \:3092\:767b\:9332\:3002
   \:30b5\:30de\:30ea\:30fc/\:4e88\:5b9a\:8868 (SourceVaultUpcomingSchedule/FormatNotebookList) \:306f
   \:30af\:30e9\:30a6\:30c9\:5b89\:5168\:306b\:751f\:6210\:3055\:308c\:308b\:306e\:3067\:767b\:9332\:3057\:306a\:3044\:3002\:65b0\:305f\:306a\:300c\:751f\:30bb\:30eb\:5185\:5bb9\:3092\:51fa\:3059 View\:300d\:306f
   \:3053\:3053\:306b spec \:3092\:8ffd\:52a0\:3059\:308b\:304b\:3001\:4ed6\:30a2\:30c0\:30d7\:30bf\:306e\:30ed\:30fc\:30c9\:6642\:306b\:5171\:6709\:30ec\:30b8\:30b9\:30c8\:30ea
   $iSVConfidentialViewSpecRegistry (SourceVault`Private`\:3001\:30ed\:30fc\:30c9\:9806\:4e0d\:554f) \:3078
   {\:5224\:5b9a, PL\:7b97\:51fa} \:3092\:767b\:9332\:3059\:308b (SourceVault_eagle.wl \:304c Eagle View \:7528 spec \:3092\:767b\:9332)\:3002 *)
iSVConfidentialViewSpecs[] := Join[
  {{iSVMailViewInputQ, iSVMailCellMaxPLFromText},
   {iSVTodoViewInputQ, iSVTodoCellMaxPLFromText}},
  If[ListQ[$iSVConfidentialViewSpecRegistry], $iSVConfidentialViewSpecRegistry, {}]];

(* \:65e2\:5b58\:306e\:6a5f\:5bc6/\:975e\:6a5f\:5bc6\:30bf\:30b0 (True/False) \:304c\:3042\:308c\:3070\:5c0a\:91cd\:3057\:518d\:30de\:30fc\:30af\:3057\:306a\:3044\:3002\:672a\:5224\:5b9a\:306e\:307f\:5bfe\:8c61\:3002 *)
iSVMailCellTaggedQ[nb_, i_] :=
  With[{t = Quiet@Check[NBAccess`NBGetConfidentialTag[nb, i], Missing[]]},
    t === True || t === False];

SourceVaultMarkConfidentialViewCells[nb_NotebookObject] :=
  Module[{n, lastIn = 0, lastInText = "", marked = {}},
    (* $iCellsCache \:306f sticky (NBInvalidateCellsCache \:307e\:3067\:66f4\:65b0\:3055\:308c\:306a\:3044)\:3002
       \:30bb\:30c3\:30b7\:30e7\:30f3\:4e2d\:306b\:53e4\:3044\:4ef6\:6570\:3067\:30ad\:30e3\:30c3\:30b7\:30e5\:3055\:308c\:3066\:3044\:308b\:3068\:65b0\:898f\:30bb\:30eb\:3092\:898b\:843d\:3068\:3059\:305f\:3081\:3001
       \:8d70\:67fb\:524d\:306b\:5fc5\:305a\:7121\:52b9\:5316\:3057\:3066\:6700\:65b0\:306e\:30bb\:30eb\:4e00\:89a7\:3092\:8aad\:3080\:3002 *)
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
              (* \:8907\:6570 spec \:304c\:540c\:4e00\:30bb\:30eb\:306b\:5408\:81f4\:3059\:308b\:5834\:5408 (\:30e1\:30fc\:30eb+Eagle \:6df7\:5728\:7b49) \:306f\:6700\:5927\:3092\:63a1\:308b *)
              pls = (Quiet@Check[Last[#][lastInText], 1.0] &) /@
                Select[iSVConfidentialViewSpecs[], First[#][lastInText] &];
              pl = If[pls =!= {} && AllTrue[pls, NumericQ], Max[pls], 1.0];
              (* \:6700\:5927PL < 0.5 (\:516c\:958b\:30e1\:30fc\:30eb / \:5168\:30bd\:30fc\:30b9NB\:304c Public \:306a Todo) \:306f\:30de\:30fc\:30af\:3057\:306a\:3044\:3002
                 0.5 \:3061\:3087\:3046\:3069\:306f\:5b89\:5168\:5074\:3067\:30de\:30fc\:30af\:3059\:308b (\:30e6\:30fc\:30b6\:30fc\:6307\:5b9a: 0.5 \:4ee5\:4e0a=\:6a5f\:5bc6\:3002
                 cloud gate \:306e\:8a31\:53ef\:5883\:754c PL<=0.5 \:3088\:308a\:4fdd\:5b88\:7684) *)
              If[pl >= 0.5,
                Quiet@Check[NBAccess`NBMarkCellConfidential[nb, i, pl], Null];
                AppendTo[marked, <|"Cell" -> i, "PrivacyLevel" -> pl|>]]],
          True, Null]],
      {i, n}];
    marked];
SourceVaultMarkConfidentialViewCells[] :=
  With[{nb = Quiet@Check[EvaluationNotebook[], $Failed]},
    If[Head[nb] === NotebookObject, SourceVaultMarkConfidentialViewCells[nb], {}]];

(* \:5f8c\:65b9\:4e92\:63db\:306e\:5225\:540d (Enable \:30d5\:30c3\:30af\:304c\:547c\:3076\:540d\:524d\:3082\:542b\:3080) *)
SourceVaultMailMarkViewCells[args___] := SourceVaultMarkConfidentialViewCells[args];

(* \[HorizontalLine]\[HorizontalLine] NBMakeContextPacket \:30d5\:30c3\:30af (\:65e2\:5b9a\:3067\:6709\:52b9\:3001\:518d\:5165\:30ac\:30fc\:30c9\:4ed8\:304d\:9ad8\:512a\:5148 DownValue) \[HorizontalLine]\[HorizontalLine]
   \:88c5\:7740\:5224\:5b9a\:306f\:30d5\:30e9\:30b0\:3067\:306a\:304f DownValues \:306e\:69cb\:9020\:691c\:67fb\:3067\:884c\:3046: NBAccess \:3092\:518d\:30ed\:30fc\:30c9\:3059\:308b\:3068
   NBMakeContextPacket \:306e\:5b9a\:7fa9\:3054\:3068\:30d5\:30c3\:30af\:304c\:6d88\:3048\:308b\:305f\:3081\:3001\:30d5\:30e9\:30b0\:983c\:307f\:3060\:3068\:300c\:88c5\:7740\:6e08\:307f\:306e
   \:3064\:3082\:308a\:3067\:5b9f\:306f\:7121\:9632\:5099\:300d\:306b\:306a\:308b\:3002Enable \:306f\:4e0d\:5728\:306a\:3089\:5e38\:306b\:518d\:88c5\:7740\:3059\:308b (\:51aa\:7b49)\:3002 *)
If[! ValueQ[$iSVMailCtxHookInstalled], $iSVMailCtxHookInstalled = False];

iSVMailCtxHookPresentQ[] :=
  AnyTrue[DownValues[NBAccess`NBMakeContextPacket],
    ! FreeQ[#, $iSVMailCtxReentry] &];

SourceVaultMailEnableAutoConfidential[] :=
  (If[! iSVMailCtxHookPresentQ[],
     (* nb_NotebookObject \:306f\:672c\:4f53\:306e nb_ \:3088\:308a\:7279\:5316\:306a\:306e\:3067\:5148\:306b\:8a66\:3055\:308c\:308b\:3002
        $iSVMailCtxReentry \:3067\:672c\:4f53\:547c\:3073\:51fa\:3057\:6642\:306f\:3053\:306e\:898f\:5247\:3092\:7d20\:901a\:308a\:3055\:305b\:308b\:3002 *)
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

(* \:30ed\:30fc\:30c9\:6642\:306b\:81ea\:52d5\:6709\:52b9\:5316 (\:30e6\:30fc\:30b6\:30fc\:6307\:6458: PL>0.5 \:306e\:30e1\:30fc\:30eb\:3092\:542b\:3080 View \:51fa\:529b\:306f
   ClaudeEval \:306e\:6587\:8108\:69cb\:7bc9\:524d\:306b\:5fc5\:305a\:6a5f\:5bc6\:30de\:30fc\:30af\:3055\:308c\:3066\:3044\:306a\:3051\:308c\:3070\:306a\:3089\:306a\:3044)\:3002
   \:89e3\:9664\:3057\:305f\:3044\:5834\:5408\:306f SourceVaultMailDisableAutoConfidential[]\:3002
   \:30d8\:30c3\:30c9\:30ec\:30b9/\:90e8\:5206\:30ed\:30fc\:30c9\:74b0\:5883\:3067\:306f NBMakeContextPacket \:304c\:547c\:3070\:308c\:306a\:3044\:3060\:3051\:3067\:7121\:5bb3\:3002 *)
SourceVaultMailEnableAutoConfidential[];

(* \:6a5f\:5bc6\:751f\:6210\:30d8\:30c3\:30c9\:767b\:9332: \:300c\:8fd4\:308a\:5024\:304c\:6a5f\:5bc6\:305f\:308a\:5f97\:308b\:300d\:95a2\:6570\:3092 NBAccess \:30ec\:30b8\:30b9\:30c8\:30ea\:3078\:5ba3\:8a00\:3002
   claudecode \:304c (a) LLM \:751f\:6210\:30b3\:30fc\:30c9/\:5fdc\:7b54\:3092\:66f8\:304d\:8fbc\:3093\:3060\:30bb\:30eb\:306e\:81ea\:52d5\:6a5f\:5bc6\:30de\:30fc\:30af\:3001
   (b) CellEpilog \:306e\:4f9d\:5b58\:79d8\:5bc6\:5224\:5b9a (snaps = SourceVaultSearch...[..] \:7b49) \:306b\:4f7f\:3046\:3002
   \:95a2\:6570\:672c\:4f53\:306e\:5909\:66f4\:306f\:4e0d\:8981 (View 3 \:95a2\:6570\:306e\:5b9f PL \:5224\:5b9a self-wrap \:306f\:7cbe\:5bc6\:5c64\:3068\:3057\:3066\:4f75\:5b58)\:3002
   NBAccess full (NBAccess.wl) \:672a\:30ed\:30fc\:30c9\:306e\:90e8\:5206\:74b0\:5883\:3067\:306f skip\:3002 *)
iSVMDRegisterConfidentialHeads[] :=
  Quiet@Check[
    If[Length[DownValues[NBAccess`NBRegisterConfidentialHead]] > 0,
      Scan[NBAccess`NBRegisterConfidentialHead[First[#], Last[#]] &,
        {{"SourceVaultMailGetBody", 1.0},
         {"SourceVaultMailSnapshotDecryptBody", 1.0},
         {"SourceVaultMailComposeReply", 1.0},
         {"SourceVaultMailTranslateBody", 1.0},
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
