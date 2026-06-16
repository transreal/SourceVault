(* ::Package:: *)

(* ============================================================
   SourceVault_searchindex.wl -- SourceVault 検索拡張 (data plane)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_searchindex.wl"]]

   仕様書: sourcevault_websearch_extension_spec_v0_10.md

   load order (§2.4): SourceVault.wl -> SourceVault_core.wl
                      -> SourceVault_searchindex.wl -> SourceVault_servicemanager.wl
   依存: SourceVault_core.wl (digest / event log / snapshot store)。

   本ファイルが担当する範囲 (段階実装。今回の増分):
     - 検索系 local profile registry (§5.3, §7.3)
       release context / search index profile / PDF index profile /
       search backend / OCR backend の登録・検証・解決 (fail-closed §5.4)
     - release context policy 評価 (§6.1-6.3)
     - 個別 object revocation / tombstone (§6.3.1)
   後続増分: chunking / embedding / projection index / retrieval / RAG /
            PDFIndex legacy adapter / snapshot 各種 / evaluation。

   非衝突方針: private helper は SourceVault`SearchIndexPrivate` 文脈に置く。
   ============================================================ *)

BeginPackage["SourceVault`"]

(* ---- profile registry (§5.3, §7.3) ---- *)
SourceVaultRegisterReleaseContext::usage =
  "SourceVaultRegisterReleaseContext[name, spec] は release context を登録する。\n" <>
  "spec 必須: \"MaxPrivacyLevel\" (_Real)。任意: RequiredTags / DenyTags / ReleaseContextTag /\n" <>
  "Sink / DisplayName / RequireCitation / AllowAnswerGeneration / AllowRawPageImage /\n" <>
  "AllowDownloadOriginal / DefaultLatencyProfile。boolean の既定は安全側 (False)。";
SourceVaultReleaseContextSpec::usage =
  "SourceVaultReleaseContextSpec[name] は登録済み release context spec を返す。未登録なら Failure。";
SourceVaultListReleaseContexts::usage =
  "SourceVaultListReleaseContexts[] は登録済み release context 名のリストを返す。";

SourceVaultRegisterSearchIndexProfile::usage =
  "SourceVaultRegisterSearchIndexProfile[name, spec] は search index profile を登録する。";
SourceVaultRegisterPDFIndexProfile::usage =
  "SourceVaultRegisterPDFIndexProfile[name, spec] は PDFIndex profile を登録する。";
SourceVaultRegisterSearchBackend::usage =
  "SourceVaultRegisterSearchBackend[name, spec] は embedding / keyword backend を登録する。";
SourceVaultRegisterOCRBackend::usage =
  "SourceVaultRegisterOCRBackend[name, spec] は OCR backend を登録する。";

SourceVaultResolveSearchIndexProfile::usage =
  "SourceVaultResolveSearchIndexProfile[name] は search index profile を解決する。未登録なら fail-closed (Failure)。";
SourceVaultResolvePDFIndexProfile::usage =
  "SourceVaultResolvePDFIndexProfile[name] は PDFIndex profile を解決する。未登録なら fail-closed。";
SourceVaultResolveSearchBackend::usage =
  "SourceVaultResolveSearchBackend[name] は search backend を解決する。未登録なら fail-closed。";
SourceVaultResolveOCRBackend::usage =
  "SourceVaultResolveOCRBackend[name] は OCR backend を解決する。未登録なら fail-closed。";

SourceVaultListProfiles::usage =
  "SourceVaultListProfiles[kind] は指定 kind (\"ReleaseContext\"/\"SearchIndexProfile\"/\"PDFIndexProfile\"/\"SearchBackend\"/\"OCRBackend\") の登録名を返す。kind 省略で全 kind の summary。";
SourceVaultClearRegistry::usage =
  "SourceVaultClearRegistry[kind] は registry を消去する (test / 再 init 用)。kind 省略で全消去。";

(* ---- release policy 評価 (§6.1-6.3) ---- *)
SourceVaultEvaluateReleasePolicy::usage =
  "SourceVaultEvaluateReleasePolicy[source, context] は source (object/chunk) が release context で公開可能か評価する。\n" <>
  "判定: PrivacyLevel <= MaxPrivacyLevel かつ RequiredTags ⊆ Tags かつ Tags ∩ DenyTags = {} かつ\n" <>
  "State ∈ {Approved,Published,Released} かつ NotExpired。\n" <>
  "戻り値 <|\"Decision\" -> \"Permit\"|\"Deny\"|\"NeedsReview\", \"Why\" -> {...}, \"PolicyDigest\", \"Context\"|>。";

(* ---- 個別 object revocation / tombstone (§6.3.1) ---- *)
SourceVaultRevokeObject::usage =
  "SourceVaultRevokeObject[objectId, opts] は ObjectRevoked event を append-only event log に記録する。\n" <>
  "オプション: \"Reason\" -> _String, \"ObjectSnapshotRef\" -> _String (省略時は全 snapshot 対象),\n" <>
  "\"EffectiveAtUTC\" -> _String, \"State\" -> \"Revoked\"|\"Archived\"|\"Deleted\" (既定 \"Revoked\")。";
SourceVaultObjectRevocationStatus::usage =
  "SourceVaultObjectRevocationStatus[objectId, opts] は object の revocation 状態を返す。\n" <>
  "戻り値 <|\"Revoked\" -> True|False, \"State\", \"Reason\", \"EffectiveAtUTC\", \"Epoch\"|>。";
SourceVaultBuildRevocationSet::usage =
  "SourceVaultBuildRevocationSet[opts] は revocation 系 event を replay して HotRevocationSet と Epoch を作る。\n" <>
  "戻り値 <|\"HotRevocationSet\" -> <|objectId -> info...|>, \"Epoch\" -> _Integer, \"BuiltAtUTC\"|>。\n" <>
  "Epoch は replay 済み revocation 系 event log の high-water mark (単調増加, §6.3.1-4)。";
SourceVaultRevocationEpoch::usage =
  "SourceVaultRevocationEpoch[] は現在の revocation epoch (high-water mark) を返す。";
SourceVaultCompactRevocationTombstone::usage =
  "SourceVaultCompactRevocationTombstone[objectId, opts] は object の tombstone を圧縮する (§6.3.1-9)。\n" <>
  "RevocationTombstoneCompacted event を記録する。呼び出し側は全 active projection からの除外を保証すること。";

(* ---- versioned snapshot (§8.3-8.5, §8.14。Phase 4) ---- *)
SourceVaultRegisterRetrievalWorkflowKind::usage =
  "SourceVaultRegisterRetrievalWorkflowKind[kind, spec] は retrieval workflow kind を登録する。\n" <>
  "kind 例: DirectIndexAnswer / KeywordFTS / VectorRAG / HybridRAG / AgenticKeywordSearch / Cascade。";
SourceVaultListRetrievalWorkflowKinds::usage =
  "SourceVaultListRetrievalWorkflowKinds[] は登録済み workflow kind を返す。";
SourceVaultSaveRetrievalWorkflowSnapshot::usage =
  "SourceVaultSaveRetrievalWorkflowSnapshot[name, spec, opts] は WorkflowSnapshot を immutable 保存する (§8.3)。\n" <>
  "spec に WorkflowKind が必須。credential / 実 path / IP を含めてはならない (profile ref のみ)。\n" <>
  "戻り値 <|\"Status\", \"Ref\", \"Digest\", ...|>。opts \"Alias\"。";
SourceVaultLoadRetrievalWorkflowSnapshot::usage =
  "SourceVaultLoadRetrievalWorkflowSnapshot[ref] は WorkflowSnapshot を読む。";
SourceVaultFreezeCorpusSnapshot::usage =
  "SourceVaultFreezeCorpusSnapshot[corpusId, opts] は検索対象集合を immutable CorpusSnapshot に固定する (§8.4)。\n" <>
  "opts \"Items\" -> {<|SourceVaultObjectId, ContentHash, ...|>...} (必須), \"ReleaseContextRef\", \"Version\", \"Alias\"。";
SourceVaultCorpusSnapshotInfo::usage =
  "SourceVaultCorpusSnapshotInfo[ref] は CorpusSnapshot の概要 (item 数 / digest / release context) を返す。";
SourceVaultDiffCorpusSnapshots::usage =
  "SourceVaultDiffCorpusSnapshots[a, b] は二つの CorpusSnapshot の item 差分 (Added/Removed/Changed) を返す。";
SourceVaultBuildIndexSnapshot::usage =
  "SourceVaultBuildIndexSnapshot[indexId, corpusRef, workflowRef, opts] は IndexSnapshot を作る (§8.5)。\n" <>
  "corpusRef / workflowRef は実在する snapshot ref でなければ fail-closed。opts \"Artifacts\", \"IndexKinds\", \"Version\", \"Alias\"。";
SourceVaultIndexSnapshotInfo::usage =
  "SourceVaultIndexSnapshotInfo[ref] は IndexSnapshot の概要を返す。";
SourceVaultValidateIndexSnapshot::usage =
  "SourceVaultValidateIndexSnapshot[ref] は IndexSnapshot の digest と corpus/workflow ref の解決可能性を検証する。";

(* ---- retrieval / PDFIndex legacy adapter (§7.4, §7.4.1。Phase 3) ---- *)
$SourceVaultPDFLegacySearchFunction::usage =
  "$SourceVaultPDFLegacySearchFunction は legacy 検索関数の override。Automatic で PDFIndex`pdfSearch を使う。\n" <>
  "fn[query, n, collection] が pdfSearch 互換の Dataset / 連想リストを返すこと。test 差し替え用。";
SourceVaultSearch::usage =
  "SourceVaultSearch[query, opts] は release context gate 付きで検索し SearchResult のリストを返す (§7.4)。\n" <>
  "必須 opts \"ReleaseContext\"。任意 \"PDFIndexProfile\" / \"Collection\" / \"Limit\" (既定 20)。\n" <>
  "各結果に request-time release gate を再評価し Permit のみ返す。raw local path は返さない。";
SourceVaultPDFIndexLegacySearch::usage =
  "SourceVaultPDFIndexLegacySearch[query, opts] は legacy PDFIndex を呼び、正規化前の生結果リストを返す。\n" <>
  "pdfAskLLM は呼ばず Notebook も書かない。";
SourceVaultPDFIndexLegacyResultToSearchResult::usage =
  "SourceVaultPDFIndexLegacyResultToSearchResult[row, opts] は legacy 1 行を SearchResult schema に正規化する (raw path 非含)。";
SourceVaultRegisterPDFIndexMigrationRule::usage =
  "SourceVaultRegisterPDFIndexMigrationRule[profile, rule] は legacy privacy flag から release context への移行 rule を登録する (§7.4.1)。\n" <>
  "rule 例: <|\"AssignReleaseContexts\"->{...}, \"AssignTags\"->{...}, \"AssignPrivacyLevel\"->0.3, \"AssignState\"->\"Published\", \"RequireHumanReviewed\"->True|>。\n" <>
  "rule 未登録なら projection は空になる (fail-closed の期待挙動)。";
SourceVaultPreviewPDFIndexMigration::usage =
  "SourceVaultPreviewPDFIndexMigration[profile, opts] は sample 行に rule を適用し、付与 release メタと gate 判定を返す (副作用なし)。\n" <>
  "opts \"SampleResults\" -> {row...}, \"ReleaseContext\"。";
SourceVaultPDFIndexMigrationReport::usage =
  "SourceVaultPDFIndexMigrationReport[profile] は登録済み migration rule と human-review 要否を返す。";

(* ---- native projection index (PDFIndex 非依存。§6.3, §7.6。Phase 5) ---- *)
SourceVaultBuildProjectionIndex::usage =
  "SourceVaultBuildProjectionIndex[context, opts] は chunk 群に build-time release gate を適用し、\n" <>
  "Permit のみの endpoint-specific projection index を作る (§6.3)。\n" <>
  "必須 opts \"Chunks\" -> {chunk(§7.2)...}。任意 \"IndexId\" (既定 context+timestamp)。\n" <>
  "戻り値 <|\"Status\", \"IndexId\", \"Ref\", \"ChunkCount\", \"ExcludedCount\"|>。";
SourceVaultLoadSearchIndex::usage =
  "SourceVaultLoadSearchIndex[indexIdOrRef, opts] は projection index を memory に読み込む。";
SourceVaultUnloadSearchIndex::usage =
  "SourceVaultUnloadSearchIndex[indexId] は読み込んだ index を解放する。";
SourceVaultSearchIndexStatus::usage =
  "SourceVaultSearchIndexStatus[indexId] は index の読込状態 / chunk 数 / context を返す。";
SourceVaultReloadSearchIndex::usage =
  "SourceVaultReloadSearchIndex[indexId, opts] は index を読み直す。";
SourceVaultListSearchIndexes::usage =
  "SourceVaultListSearchIndexes[] は memory に読み込み済みの index id を返す。";

(* ---- TPO 制約 / 目的別 index / 低遅延 interaction (§16。Phase 7) ---- *)
SourceVaultRegisterTPOProfile::usage =
  "SourceVaultRegisterTPOProfile[tpoId, spec] は TPOProfile (場所/イベント/役割/許可話題/回答長/遅延) を登録する (§16.2)。\n" <>
  "spec 必須: \"AllowedScope\" (TopicTags を含む)。任意: \"TopicKeywords\", \"OutOfScopeKeywords\",\n" <>
  "\"ChannelProfile\"(MaxAnswerCharacters 等), \"OutOfScopePolicy\", \"ReleaseContextRefs\"。";
SourceVaultTPOProfile::usage = "SourceVaultTPOProfile[tpoId] は登録済み TPOProfile を返す (未登録 fail-closed)。";
SourceVaultListTPOProfiles::usage = "SourceVaultListTPOProfiles[] は登録済み TPO id を返す。";
SourceVaultValidateTPOProfile::usage = "SourceVaultValidateTPOProfile[spec] は TPOProfile spec の必須項目を検査する。";
SourceVaultClassifyQuestionTPO::usage =
  "SourceVaultClassifyQuestionTPO[question, tpoId] は質問が TPO に即すか分類し QueryScopeDecision を返す (§16.5)。\n" <>
  "Decision: InScope | OutOfScope | NeedsClarification | Blocked。rule + keyword (LLM 非依存)。";
SourceVaultEvaluateTPOGate::usage = "SourceVaultEvaluateTPOGate[question, tpoId] は SourceVaultClassifyQuestionTPO の別名。";
SourceVaultBuildPurposeIndex::usage =
  "SourceVaultBuildPurposeIndex[indexId, tpoId, opts] は TPO 制約 (許可 topic tags + release context) で\n" <>
  "chunk を絞り projection index を作る (§16.4)。必須 opts \"Chunks\"。";
SourceVaultAnswerForInteraction::usage =
  "SourceVaultAnswerForInteraction[question, tpoId, opts] は低遅延 cascade で対話応答を作る (§16.10)。\n" <>
  "TPOGate → PurposeIndex 検索 → 短答 / fallback。回答長は TPO の ChannelProfile に従う。\n" <>
  "opts \"Index\"(必須), \"ReleaseContext\", \"DeadlineMs\"。戻り値 <|\"Decision\"->Speak|Clarify|Refuse|NoAnswer|RouteToHuman, \"AnswerText\", \"EvidenceRefs\", \"WorkflowUsed\", \"ElapsedMs\", \"DeadlineMet\", \"TPOGateDecision\"|>。";

(* ---- マルチモーダル event 正規化 / media index (§17.4, §17.10, §17.14。Phase 7b) ---- *)
SourceVaultMediaPrivacyDefault::usage =
  "SourceVaultMediaPrivacyDefault[kind] は media kind ごとの既定 PrivacyLevel を返す (§17.13。raw は >=1.0)。";
SourceVaultAppendMultimodalEvent::usage =
  "SourceVaultAppendMultimodalEvent[event] は MultimodalEvent を正規化し append-only event log に記録する (§17.4)。\n" <>
  "必須: \"SessionID\", \"Kind\"。PrivacyLevel 未指定なら kind 既定 (raw media は 1.0)。";
SourceVaultSessionEvents::usage =
  "SourceVaultSessionEvents[sessionId, opts] は session の MultimodalEvent を時刻順に返す。opts \"Kind\"。";
SourceVaultBuildRealtimeContext::usage =
  "SourceVaultBuildRealtimeContext[sessionId, opts] は直近 transcript + visual を ObservationEnvelope にまとめる (§17.10)。\n" <>
  "opts \"TranscriptWindowSeconds\"(既定20), \"VisualWindowSeconds\"(既定5), \"MaxFrames\"(既定3)。";
SourceVaultBuildMediaIndex::usage =
  "SourceVaultBuildMediaIndex[sessionId, opts] は media 由来 (transcript/caption/OCR/summary) を release gate して projection index 化する (§17.14)。\n" <>
  "raw audio/frame は入れない。必須 opts \"ReleaseContext\"。任意 \"IndexId\", \"Modalities\"。";

Begin["`SearchIndexPrivate`"]

(* ============================================================
   registry (in-memory。実値は private local init / Register* で投入)
   ============================================================ *)

If[! AssociationQ[$registries], $registries = <||>];

iRevClasses = {"ObjectRevoked", "ObjectStateChanged", "RevocationTombstoneCompacted"};

iRegKinds = {"ReleaseContext", "SearchIndexProfile", "PDFIndexProfile",
   "SearchBackend", "OCRBackend"};

iEnsureKind[kind_String] :=
  If[! KeyExistsQ[$registries, kind], $registries[kind] = <||>];

iDoRegister[kind_String, name_String, spec_Association] := (
  iEnsureKind[kind];
  $registries[kind] = Append[$registries[kind], name -> spec];
  <|"Status" -> "OK", "Kind" -> kind, "Name" -> name|>
);

iResolve[kind_String, name_String] := Module[{m},
  m = Lookup[$registries, kind, <||>];
  If[KeyExistsQ[m, name], m[name],
    Failure["UnregisteredProfile", <|
      "MessageTemplate" -> "`1` `2` は未登録です (fail-closed)。private local init で登録してください。",
      "MessageParameters" -> {kind, name}, "Kind" -> kind, "Name" -> name|>]]
];

(* schema 検証ヘルパ: 必須 key と型を確認 *)
iRequire[spec_Association, key_String, test_, kind_String, name_String] :=
  If[KeyExistsQ[spec, key] && test[spec[key]], Null,
    Failure["InvalidSpec", <|
      "MessageTemplate" -> "`1` `2`: 必須 field `3` が無いか型不正です。",
      "Kind" -> kind, "Name" -> name, "Field" -> key|>]];

iRealQ[x_] := NumericQ[x] && Element[x, Reals];
iListQ[x_] := ListQ[x];

(* ---- release context ---- *)
SourceVaultRegisterReleaseContext[name_String, spec_Association] := Module[{chk, norm},
  chk = iRequire[spec, "MaxPrivacyLevel", iRealQ, "ReleaseContext", name];
  If[FailureQ[chk], Return[chk]];
  (* 安全側 default を補う *)
  norm = Join[<|
    "RequiredTags" -> {}, "DenyTags" -> {},
    "RequireCitation" -> True,
    "AllowAnswerGeneration" -> False,
    "AllowRawPageImage" -> False,
    "AllowDownloadOriginal" -> False|>, spec];
  iDoRegister["ReleaseContext", name, norm]
];
SourceVaultReleaseContextSpec[name_String] := iResolve["ReleaseContext", name];
SourceVaultListReleaseContexts[] := Keys @ Lookup[$registries, "ReleaseContext", <||>];

(* ---- search index profile ---- *)
SourceVaultRegisterSearchIndexProfile[name_String, spec_Association] :=
  iDoRegister["SearchIndexProfile", name, spec];
SourceVaultResolveSearchIndexProfile[name_String, opts___] :=
  iResolve["SearchIndexProfile", name];

(* ---- PDF index profile ---- *)
SourceVaultRegisterPDFIndexProfile[name_String, spec_Association] :=
  iDoRegister["PDFIndexProfile", name, spec];
SourceVaultResolvePDFIndexProfile[name_String, opts___] :=
  iResolve["PDFIndexProfile", name];

(* ---- search backend ---- *)
SourceVaultRegisterSearchBackend[name_String, spec_Association] := Module[{chk},
  chk = iRequire[spec, "Kind", StringQ, "SearchBackend", name];
  If[FailureQ[chk], Return[chk]];
  iDoRegister["SearchBackend", name, spec]
];
SourceVaultResolveSearchBackend[name_String, opts___] :=
  iResolve["SearchBackend", name];

(* ---- OCR backend ---- *)
SourceVaultRegisterOCRBackend[name_String, spec_Association] :=
  iDoRegister["OCRBackend", name, spec];
SourceVaultResolveOCRBackend[name_String, opts___] :=
  iResolve["OCRBackend", name];

(* ---- registry 管理 ---- *)
SourceVaultListProfiles[kind_String] := Keys @ Lookup[$registries, kind, <||>];
SourceVaultListProfiles[] :=
  Association @ Map[# -> Keys[Lookup[$registries, #, <||>]] &, iRegKinds];

SourceVaultClearRegistry[kind_String] := ($registries[kind] = <||>; <|"Status" -> "OK", "Kind" -> kind|>);
SourceVaultClearRegistry[] := ($registries = <||>; <|"Status" -> "OK", "Cleared" -> "All"|>);

(* ============================================================
   §6.1-6.3 release policy 評価
   ============================================================ *)

iParseDate[x_] := Which[
  Head[x] === DateObject, x,
  StringQ[x], Quiet @ DateObject[x, TimeZone -> 0],
  True, Missing["Unspecified"]
];

iNotExpired[source_Association] := Module[{vf, vu, now = Now, okFrom, okUntil},
  vf = iParseDate @ Lookup[source, "ValidFrom", Missing["Unspecified"]];
  vu = iParseDate @ Lookup[source, "ValidUntil", Missing["Unspecified"]];
  okFrom = If[Head[vf] === DateObject, now >= vf, True];
  okUntil = If[Head[vu] === DateObject, now <= vu, True];
  {okFrom && okUntil, okFrom, okUntil}
];

$validStates = {"Approved", "Published", "Released"};

SourceVaultEvaluateReleasePolicy[source_Association, contextName_String, opts___] := Module[
  {ctx, why = {}, decision, tags, reqTags, denyTags, maxPL, pl, state, expChk, notExpired,
   policyDigest},
  ctx = iResolve["ReleaseContext", contextName];
  If[FailureQ[ctx], Return[ctx]];
  policyDigest = SourceVault`SourceVaultSnapshotDigest[ctx];
  tags = Lookup[source, "Tags", {}];
  reqTags = Lookup[ctx, "RequiredTags", {}];
  denyTags = Lookup[ctx, "DenyTags", {}];
  maxPL = Lookup[ctx, "MaxPrivacyLevel", 0.];
  pl = Lookup[source, "PrivacyLevel", Missing["Unknown"]];
  state = Lookup[source, "State", Missing["Unknown"]];

  (* PrivacyLevel *)
  If[! (iRealQ[pl] && pl <= maxPL),
    AppendTo[why, "PrivacyLevelExceedsMax(" <> ToString[pl] <> ">" <> ToString[maxPL] <> ")"]];
  (* RequiredTags ⊆ Tags *)
  If[! SubsetQ[tags, reqTags],
    AppendTo[why, "MissingRequiredTags(" <> ToString[Complement[reqTags, tags]] <> ")"]];
  (* Tags ∩ DenyTags = {} *)
  With[{hit = Intersection[tags, denyTags]},
    If[hit =!= {}, AppendTo[why, "HasDenyTag(" <> ToString[hit] <> ")"]]];
  (* State *)
  If[! MemberQ[$validStates, state],
    AppendTo[why, "StateNotReleasable(" <> ToString[state] <> ")"]];
  (* NotExpired *)
  expChk = iNotExpired[source];
  notExpired = expChk[[1]];
  If[! notExpired, AppendTo[why, "Expired(from=" <> ToString[expChk[[2]]] <>
    ",until=" <> ToString[expChk[[3]]] <> ")"]];

  decision = If[why === {}, "Permit", "Deny"];
  <|"Decision" -> decision, "Why" -> why, "PolicyDigest" -> policyDigest,
    "Context" -> contextName|>
];

(* ============================================================
   §6.3.1 個別 object revocation / tombstone
   ============================================================ *)

Options[SourceVaultRevokeObject] = {
  "Reason" -> "", "ObjectSnapshotRef" -> All, "EffectiveAtUTC" -> Automatic, "State" -> "Revoked"};
SourceVaultRevokeObject[objectId_String, OptionsPattern[]] := Module[{ev, snapRef, eff},
  snapRef = OptionValue["ObjectSnapshotRef"];
  eff = OptionValue["EffectiveAtUTC"];
  ev = <|"EventClass" -> "ObjectRevoked", "ObjectId" -> objectId,
    "ObjectSnapshotRef" -> If[snapRef === All, "AllSnapshots", snapRef],
    "State" -> OptionValue["State"],
    "Reason" -> OptionValue["Reason"],
    "EffectiveAtUTC" -> If[eff === Automatic, Null, eff]|>;
  (* EffectiveAtUTC は AppendEvent が CreatedAtUTC を補うのでそちらに合わせる *)
  If[eff === Automatic, ev = KeyDrop[ev, "EffectiveAtUTC"]];
  SourceVault`SourceVaultAppendEvent[ev]
];

(* revocation 系 event を全件取得 (新しい順は気にしない) *)
iRevocationEvents[] := Module[{evs},
  evs = SourceVault`SourceVaultTransactionLog["Limit" -> All];
  Select[evs, MemberQ[iRevClasses, Lookup[#, "EventClass"]] &]
];

Options[SourceVaultBuildRevocationSet] = {};
SourceVaultBuildRevocationSet[opts___] := Module[{evs, set = <||>, epoch, compacted},
  evs = iRevocationEvents[];
  epoch = Length[evs];  (* high-water mark: revocation 系 event 数 (§6.3.1-4) *)
  (* effective 時刻順に適用 (CreatedAtUTC で安定ソート) *)
  evs = SortBy[evs, Lookup[#, "CreatedAtUTC", ""] &];
  Do[
    Switch[Lookup[ev, "EventClass"],
      "ObjectRevoked" | "ObjectStateChanged",
        set[Lookup[ev, "ObjectId"]] = <|
          "State" -> Lookup[ev, "State", "Revoked"],
          "Reason" -> Lookup[ev, "Reason", ""],
          "EffectiveAtUTC" -> Lookup[ev, "EffectiveAtUTC", Lookup[ev, "CreatedAtUTC"]],
          "ObjectSnapshotRef" -> Lookup[ev, "ObjectSnapshotRef", "AllSnapshots"]|>,
      "RevocationTombstoneCompacted",
        set = KeyDrop[set, Lookup[ev, "ObjectId"]]
    ],
    {ev, evs}];
  <|"HotRevocationSet" -> set, "Epoch" -> epoch, "BuiltAtUTC" -> DateString[Now, "ISODateTime"]|>
];

SourceVaultRevocationEpoch[opts___] := Length[iRevocationEvents[]];

Options[SourceVaultObjectRevocationStatus] = {};
SourceVaultObjectRevocationStatus[objectId_String, opts___] := Module[{built, set, info},
  built = SourceVaultBuildRevocationSet[];
  set = Lookup[built, "HotRevocationSet", <||>];
  If[KeyExistsQ[set, objectId],
    info = set[objectId];
    <|"Revoked" -> True, "State" -> Lookup[info, "State"],
      "Reason" -> Lookup[info, "Reason"], "EffectiveAtUTC" -> Lookup[info, "EffectiveAtUTC"],
      "Epoch" -> Lookup[built, "Epoch"]|>,
    <|"Revoked" -> False, "State" -> Missing["NotRevoked"],
      "Epoch" -> Lookup[built, "Epoch"]|>]
];

Options[SourceVaultCompactRevocationTombstone] = {"Reason" -> "compacted"};
SourceVaultCompactRevocationTombstone[objectId_String, OptionsPattern[]] :=
  SourceVault`SourceVaultAppendEvent[<|
    "EventClass" -> "RevocationTombstoneCompacted", "ObjectId" -> objectId,
    "Reason" -> OptionValue["Reason"]|>];

(* ============================================================
   §8.3-8.5 versioned snapshot (Phase 4)
   core の immutable snapshot store (SourceVaultSaveImmutableSnapshot) に乗る。
   ============================================================ *)

If[! AssociationQ[$workflowKinds], $workflowKinds = <||>];
$builtinWorkflowKinds = {"DirectIndexAnswer", "KeywordFTS", "VectorRAG", "HybridRAG",
   "AgenticKeywordSearch", "DirectCorpusInteraction", "Cascade", "ManualReviewDraft"};

SourceVaultRegisterRetrievalWorkflowKind[kind_String, spec_Association] :=
  ($workflowKinds[kind] = spec; <|"Status" -> "OK", "Kind" -> kind|>);
SourceVaultListRetrievalWorkflowKinds[] :=
  Union[$builtinWorkflowKinds, Keys[$workflowKinds]];

(* WorkflowSnapshot *)
Options[SourceVaultSaveRetrievalWorkflowSnapshot] = {"Alias" -> None};
SourceVaultSaveRetrievalWorkflowSnapshot[name_String, spec_Association, OptionsPattern[]] := Module[
  {kind, rec},
  kind = Lookup[spec, "WorkflowKind", Missing[]];
  If[! StringQ[kind],
    Return[Failure["InvalidWorkflowSpec", <|
      "MessageTemplate" -> "WorkflowSnapshot には WorkflowKind (文字列) が必須です。", "Name" -> name|>]]];
  If[! MemberQ[SourceVaultListRetrievalWorkflowKinds[], kind],
    Return[Failure["UnknownWorkflowKind", <|"Kind" -> kind,
      "Known" -> SourceVaultListRetrievalWorkflowKinds[]|>]]];
  rec = Join[<|"ObjectClass" -> "SourceVaultRetrievalWorkflowSnapshot",
    "WorkflowId" -> name, "InterfaceVersion" -> "SVRetrievalWorkflow/1"|>, spec];
  SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultRetrievalWorkflowSnapshot", rec,
    "Alias" -> OptionValue["Alias"]]
];
SourceVaultLoadRetrievalWorkflowSnapshot[ref_String, opts___] :=
  SourceVault`SourceVaultLoadImmutableSnapshot[ref];

(* §8.10 PromptSnapshot store: prompt を code に埋め込まず immutable snapshot 化。 *)
SourceVault`SourceVaultSavePromptSnapshot[name_String, prompt_String, metadata_Association : <||>] := Module[
  {rec, alias},
  alias = Lookup[metadata, "Alias", None];
  rec = Join[<|"ObjectClass" -> "PromptSnapshot", "PromptName" -> name, "Prompt" -> prompt,
    "InterfaceVersion" -> "SVPrompt/1"|>, KeyDrop[metadata, "Alias"]];
  SourceVault`SourceVaultSaveImmutableSnapshot["PromptSnapshot", rec, "Alias" -> alias]];
SourceVault`SourceVaultLoadPromptSnapshot[ref_String, opts___] :=
  SourceVault`SourceVaultLoadImmutableSnapshot[ref];

(* CorpusSnapshot *)
Options[SourceVaultFreezeCorpusSnapshot] = {
  "Items" -> None, "ReleaseContextRef" -> None, "Version" -> Automatic, "Alias" -> None};
SourceVaultFreezeCorpusSnapshot[corpusId_String, OptionsPattern[]] := Module[{items, rec},
  items = OptionValue["Items"];
  If[! ListQ[items],
    Return[Failure["CorpusItemsRequired", <|
      "MessageTemplate" -> "CorpusSnapshot には \"Items\" (リスト) が必須です。directory scan は別途。",
      "CorpusId" -> corpusId|>]]];
  rec = <|"ObjectClass" -> "SourceVaultCorpusSnapshot", "CorpusId" -> corpusId,
    "CorpusVersion" -> Replace[OptionValue["Version"], Automatic -> "auto"],
    "ReleaseContextRef" -> OptionValue["ReleaseContextRef"],
    "Items" -> items, "ItemCount" -> Length[items], "Immutable" -> True|>;
  SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultCorpusSnapshot", rec,
    "Alias" -> OptionValue["Alias"]]
];
SourceVaultCorpusSnapshotInfo[ref_String, opts___] := Module[{rec},
  rec = SourceVault`SourceVaultLoadImmutableSnapshot[ref];
  If[FailureQ[rec], Return[rec]];
  <|"CorpusId" -> Lookup[rec, "CorpusId"], "ItemCount" -> Lookup[rec, "ItemCount"],
    "ReleaseContextRef" -> Lookup[rec, "ReleaseContextRef"],
    "Digest" -> Lookup[rec, "Digest"]|>
];
iCorpusItemKey[item_] := Lookup[item, "SourceVaultObjectId", Lookup[item, "ContentHash", item]];
SourceVaultDiffCorpusSnapshots[aRef_String, bRef_String, opts___] := Module[{a, b, ai, bi, ak, bk},
  a = SourceVault`SourceVaultLoadImmutableSnapshot[aRef];
  b = SourceVault`SourceVaultLoadImmutableSnapshot[bRef];
  If[FailureQ[a], Return[a]]; If[FailureQ[b], Return[b]];
  ai = Lookup[a, "Items", {}]; bi = Lookup[b, "Items", {}];
  ak = iCorpusItemKey /@ ai; bk = iCorpusItemKey /@ bi;
  <|"Added" -> Complement[bk, ak], "Removed" -> Complement[ak, bk],
    "Common" -> Length[Intersection[ak, bk]]|>
];

(* IndexSnapshot *)
Options[SourceVaultBuildIndexSnapshot] = {
  "Artifacts" -> <||>, "IndexKinds" -> {"KeywordFTS"}, "Version" -> Automatic, "Alias" -> None};
SourceVaultBuildIndexSnapshot[indexId_String, corpusRef_String, workflowRef_String, OptionsPattern[]] := Module[
  {corpus, workflow, rec},
  (* corpus / workflow ref が実在しなければ fail-closed (§8.7) *)
  corpus = SourceVault`SourceVaultLoadImmutableSnapshot[corpusRef];
  If[FailureQ[corpus], Return[Failure["CorpusRefUnresolved", <|"CorpusRef" -> corpusRef|>]]];
  workflow = SourceVault`SourceVaultLoadImmutableSnapshot[workflowRef];
  If[FailureQ[workflow], Return[Failure["WorkflowRefUnresolved", <|"WorkflowRef" -> workflowRef|>]]];
  rec = <|"ObjectClass" -> "SourceVaultIndexSnapshot", "IndexId" -> indexId,
    "IndexVersion" -> Replace[OptionValue["Version"], Automatic -> "auto"],
    "CorpusSnapshotRef" -> corpusRef, "WorkflowSnapshotRef" -> workflowRef,
    "IndexKinds" -> OptionValue["IndexKinds"], "Artifacts" -> OptionValue["Artifacts"],
    "Immutable" -> True|>;
  SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultIndexSnapshot", rec,
    "Alias" -> OptionValue["Alias"]]
];
SourceVaultIndexSnapshotInfo[ref_String, opts___] := Module[{rec},
  rec = SourceVault`SourceVaultLoadImmutableSnapshot[ref];
  If[FailureQ[rec], Return[rec]];
  <|"IndexId" -> Lookup[rec, "IndexId"], "IndexKinds" -> Lookup[rec, "IndexKinds"],
    "CorpusSnapshotRef" -> Lookup[rec, "CorpusSnapshotRef"],
    "WorkflowSnapshotRef" -> Lookup[rec, "WorkflowSnapshotRef"], "Digest" -> Lookup[rec, "Digest"]|>
];
SourceVaultValidateIndexSnapshot[ref_String, opts___] := Module[{rec, ver, corpusOk, wfOk},
  rec = SourceVault`SourceVaultLoadImmutableSnapshot[ref];
  If[FailureQ[rec], Return[rec]];
  ver = SourceVault`SourceVaultVerifyImmutableSnapshot[ref];
  corpusOk = ! FailureQ[SourceVault`SourceVaultLoadImmutableSnapshot[Lookup[rec, "CorpusSnapshotRef", ""]]];
  wfOk = ! FailureQ[SourceVault`SourceVaultLoadImmutableSnapshot[Lookup[rec, "WorkflowSnapshotRef", ""]]];
  <|"Status" -> If[TrueQ[Lookup[ver, "Valid"]] && corpusOk && wfOk, "Valid", "Invalid"],
    "DigestValid" -> Lookup[ver, "Valid"], "CorpusResolvable" -> corpusOk,
    "WorkflowResolvable" -> wfOk, "Ref" -> ref|>
];

(* ============================================================
   §7.4 PDFIndex legacy adapter + request-time release gate (Phase 3)
   検索結果は release context gate を必ず通し、raw local path を返さない。
   実 PDFIndex が無い環境では $SourceVaultPDFLegacySearchFunction を差し替え可能。
   ============================================================ *)

If[! ValueQ[SourceVault`$SourceVaultPDFLegacySearchFunction],
  SourceVault`$SourceVaultPDFLegacySearchFunction = Automatic];
If[! AssociationQ[$pdfMigrationRules], $pdfMigrationRules = <||>];

(* legacy tags 文字列 (カンマ/空白区切り) を list に *)
iParseLegacyTags[row_Association] := Module[{t = Lookup[row, "tags", Lookup[row, "Tags", ""]]},
  Which[
    ListQ[t], t,
    StringQ[t] && StringLength[StringTrim[t]] > 0,
      StringTrim /@ StringSplit[t, {",", ";", " "}],
    True, {}]];

(* raw 行を SearchResult schema へ (raw path は持ち込まない) *)
SourceVaultPDFIndexLegacyResultToSearchResult[row_Association, opts___] :=
  <|"ResultId" -> "res:" <> CreateUUID[],
    "ChunkId" -> ToString @ Lookup[row, "chunkIdx", Lookup[row, "globalIdx", "?"]],
    "Score" -> N @ Lookup[row, "score", 0.],
    "ScoreBreakdown" -> <|"Embedding" -> Missing["NotProvided"], "Keyword" -> Missing["NotProvided"]|>,
    "Snippet" -> Lookup[row, "context", Lookup[row, "summary", ""]],
    "EvidenceRef" -> "evid:" <> ToString @ Lookup[row, "chunkIdx", Lookup[row, "globalIdx", "?"]],
    "Citation" -> <|"Title" -> Lookup[row, "docTitle", ""], "Page" -> Lookup[row, "page", Missing["Unknown"]],
      "DocId" -> ToString @ Lookup[row, "docId", ""]|>,
    "LegacyTags" -> iParseLegacyTags[row]|>;

(* legacy 検索 (raw 行のリストを返す)。pdfAskLLM は呼ばない・Notebook も書かない。 *)
Options[SourceVaultPDFIndexLegacySearch] = {"Collection" -> Automatic, "Limit" -> 20};
SourceVaultPDFIndexLegacySearch[query_String, OptionsPattern[]] := Module[
  {fn, n, collection, raw},
  n = OptionValue["Limit"]; collection = OptionValue["Collection"];
  fn = SourceVault`$SourceVaultPDFLegacySearchFunction;
  If[fn === Automatic,
    If[Quiet[Length[DownValues[PDFIndex`pdfSearch]] > 0],
      fn = Function[{q, k, col}, If[col === Automatic,
        PDFIndex`pdfSearch[q, k], PDFIndex`pdfSearch[q, k, PDFIndex`Collection -> col]]],
      Return[Failure["PDFIndexUnavailable", <|
        "MessageTemplate" -> "PDFIndex`pdfSearch が無く、$SourceVaultPDFLegacySearchFunction も未設定です。"|>]]]];
  raw = fn[query, n, collection];
  raw = Which[Head[raw] === Dataset, Normal[raw], ListQ[raw], raw, True, {}];
  Select[raw, AssociationQ]
];

(* migration rule (§7.4.1) *)
SourceVaultRegisterPDFIndexMigrationRule[profile_String, rule_Association] :=
  ($pdfMigrationRules[profile] = rule; <|"Status" -> "OK", "Profile" -> profile|>);

(* rule を 1 行に適用し release 判定用 source 連想を作る。
   rule 未登録なら release context を与えず State も Draft = gate で Deny (fail-closed §7.4.1-4)。 *)
iLegacySourceFromRow[profile_String, row_Association] := Module[{rule, baseTags},
  rule = Lookup[$pdfMigrationRules, profile, Missing[]];
  baseTags = iParseLegacyTags[row];
  If[! AssociationQ[rule],
    Return[<|"PrivacyLevel" -> 1.0, "Tags" -> baseTags, "State" -> "Draft",
      "ReleaseContexts" -> {}|>]];
  <|"PrivacyLevel" -> Lookup[rule, "AssignPrivacyLevel", 1.0],
    "Tags" -> Union[baseTags, Lookup[rule, "AssignTags", {}],
      Lookup[rule, "AssignReleaseContexts", {}]],
    "State" -> Lookup[rule, "AssignState", "Draft"],
    "ReleaseContexts" -> Lookup[rule, "AssignReleaseContexts", {}],
    "ValidFrom" -> Lookup[rule, "AssignValidFrom", Missing["Unspecified"]],
    "ValidUntil" -> Lookup[rule, "AssignValidUntil", Missing["Unspecified"]]|>
];

(* メイン検索 API: legacy → 正規化 → migration rule → request-time gate → Permit のみ *)
Options[SourceVaultSearch] = {
  "ReleaseContext" -> None, "PDFIndexProfile" -> None, "Collection" -> Automatic,
  "Limit" -> 20, "Index" -> None};
SourceVaultSearch[query_String, OptionsPattern[]] := Module[
  {ctxName, profileName, collection, rawRows, results, ctxSpec, profile, indexId},
  ctxName = OptionValue["ReleaseContext"];
  If[! StringQ[ctxName],
    Return[Failure["ReleaseContextRequired", <|
      "MessageTemplate" -> "SourceVaultSearch には \"ReleaseContext\" が必須です (fail-closed)。"|>]]];
  ctxSpec = iResolve["ReleaseContext", ctxName];
  If[FailureQ[ctxSpec], Return[ctxSpec]];
  (* native projection index 指定時はそちらを使う (PDFIndex 非依存) *)
  indexId = OptionValue["Index"];
  If[StringQ[indexId],
    Return[iNativeSearch[query, ctxName, indexId, OptionValue["Limit"]]]];
  profileName = OptionValue["PDFIndexProfile"];
  collection = OptionValue["Collection"];
  (* profile 指定時は CollectionRoot を解決 (fail-closed) *)
  If[StringQ[profileName],
    profile = iResolve["PDFIndexProfile", profileName];
    If[FailureQ[profile], Return[profile]];
    If[collection === Automatic, collection = Lookup[profile, "CollectionRoot", Automatic]]];
  rawRows = SourceVaultPDFIndexLegacySearch[query,
    "Collection" -> collection, "Limit" -> OptionValue["Limit"]];
  If[FailureQ[rawRows], Return[rawRows]];
  results = Map[
    Function[row, Module[{sr, src, gate},
      sr = SourceVaultPDFIndexLegacyResultToSearchResult[row];
      src = iLegacySourceFromRow[If[StringQ[profileName], profileName, "?"], row];
      gate = SourceVaultEvaluateReleasePolicy[src, ctxName];
      Join[KeyDrop[sr, "LegacyTags"], <|
        "ReleaseDecision" -> Lookup[gate, "Decision", "Deny"],
        "RequestTimeGateReevaluated" -> True,
        "PolicyDigestAtRequest" -> Lookup[gate, "PolicyDigest", Missing[]],
        "Why" -> Lookup[gate, "Why", {}]|>]]],
    rawRows];
  (* Permit のみ返す。raw path は元から含まれない。 *)
  Select[results, Lookup[#, "ReleaseDecision"] === "Permit" &]
];

Options[SourceVaultPreviewPDFIndexMigration] = {"SampleResults" -> {}, "ReleaseContext" -> None};
SourceVaultPreviewPDFIndexMigration[profile_String, OptionsPattern[]] := Module[
  {rows, ctxName, ctx},
  rows = OptionValue["SampleResults"];
  ctxName = OptionValue["ReleaseContext"];
  If[! StringQ[ctxName],
    ctxName = Lookup[Lookup[$pdfMigrationRules, profile, <||>], "DefaultReleaseContextRef", None]];
  Map[Function[row, Module[{src, gate},
      src = iLegacySourceFromRow[profile, row];
      gate = If[StringQ[ctxName], SourceVaultEvaluateReleasePolicy[src, ctxName],
        <|"Decision" -> "NoContext"|>];
      <|"Title" -> Lookup[row, "docTitle", ""], "AssignedSource" -> src,
        "Decision" -> Lookup[gate, "Decision"], "Why" -> Lookup[gate, "Why", {}]|>]],
    rows]
];

SourceVaultPDFIndexMigrationReport[profile_String, opts___] := Module[{rule},
  rule = Lookup[$pdfMigrationRules, profile, Missing[]];
  If[! AssociationQ[rule],
    <|"Status" -> "NoRule", "Profile" -> profile,
      "Note" -> "rule 未登録: projection は空 (fail-closed)。"|>,
    <|"Status" -> "OK", "Profile" -> profile, "Rule" -> rule,
      "RequireHumanReviewed" -> Lookup[rule, "RequireHumanReviewed", True]|>]
];

(* ============================================================
   §6.3, §7.6 native projection index (PDFIndex 非依存。Phase 5)
   build 時に release gate を適用し Permit のみ収録。検索時は request-time
   gate 再評価 + revocation 照合 (§6.3.1) を行う。keyword + 日本語 bigram スコア
   (embedding backend 依存を避ける)。
   ============================================================ *)

If[! AssociationQ[$loadedProjections], $loadedProjections = <||>];

(* tokenize: 空白/句読点で分割。日本語単一トークンは bigram で補う *)
iTokenize[q_String] := DeleteCases[
  StringSplit[q, RegularExpression["[\\s\\p{P}\\p{Z}]+"]], ""];
iBigrams[s_String] := If[StringLength[s] < 2, {s},
  StringJoin /@ Partition[Characters[s], 2, 1]];
iKeywordScore[normText_String, q_String] := Module[{toks = iTokenize[q], bg, whole},
  bg = iBigrams[StringReplace[q, RegularExpression["[\\s\\p{P}\\p{Z}]+"] -> ""]];
  whole = If[StringLength[q] > 0 && StringContainsQ[normText, q], 3.0, 0.];
  whole + 1.0 * Total[Boole[StringContainsQ[normText, #]] & /@ toks] +
    0.25 * If[bg === {}, 0, Total[Boole[StringContainsQ[normText, #]] & /@ bg]]];

(* KWIC snippet *)
iSnippet[text_String, q_String, maxLen_: 160] := Module[{toks = iTokenize[q], pos, start},
  pos = SelectFirst[StringPosition[text, #] & /@ Prepend[toks, q], # =!= {} &, {}];
  If[pos === {}, StringTake[text, UpTo[maxLen]],
    start = Max[1, pos[[1, 1]] - 40];
    StringTake[text, {start, Min[StringLength[text], start + maxLen]}]]];

Options[SourceVaultBuildProjectionIndex] = {"Chunks" -> None, "IndexId" -> Automatic};
SourceVaultBuildProjectionIndex[contextName_String, OptionsPattern[]] := Module[
  {ctx, chunks, permitted, excluded, indexId, rec, saved},
  ctx = iResolve["ReleaseContext", contextName];
  If[FailureQ[ctx], Return[ctx]];
  chunks = OptionValue["Chunks"];
  If[! ListQ[chunks],
    Return[Failure["ChunksRequired", <|
      "MessageTemplate" -> "BuildProjectionIndex には \"Chunks\" (§7.2 chunk のリスト) が必須です。"|>]]];
  (* build-time gate: Permit のみ収録 (§6.3) *)
  permitted = Select[chunks,
    Lookup[SourceVaultEvaluateReleasePolicy[#, contextName], "Decision"] === "Permit" &];
  excluded = Length[chunks] - Length[permitted];
  indexId = OptionValue["IndexId"] /. Automatic -> (contextName <> "-proj");
  rec = <|"ObjectClass" -> "SourceVaultProjectionIndex", "IndexId" -> indexId,
    "ReleaseContextRef" -> contextName, "PolicyDigest" -> SourceVault`SourceVaultSnapshotDigest[ctx],
    "Chunks" -> permitted, "ChunkCount" -> Length[permitted], "ExcludedCount" -> excluded,
    "IndexKind" -> "KeywordBigram", "BuiltAtUTC" -> DateString[Now, "ISODateTime"]|>;
  saved = SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultProjectionIndex", rec,
    "Alias" -> indexId];
  If[FailureQ[saved], Return[saved]];
  <|"Status" -> "OK", "IndexId" -> indexId, "Ref" -> Lookup[saved, "Ref"],
    "ChunkCount" -> Length[permitted], "ExcludedCount" -> excluded|>
];

SourceVaultLoadSearchIndex[indexIdOrRef_String, opts___] := Module[{rec, id},
  rec = If[StringMatchQ[indexIdOrRef, "snapshot:" ~~ __],
    SourceVault`SourceVaultLoadImmutableSnapshot[indexIdOrRef],
    SourceVault`SourceVaultLoadImmutableSnapshot["SourceVaultProjectionIndex/" <> indexIdOrRef]];
  If[FailureQ[rec], Return[rec]];
  id = Lookup[rec, "IndexId", indexIdOrRef];
  $loadedProjections[id] = rec;
  <|"Status" -> "Loaded", "IndexId" -> id, "ChunkCount" -> Lookup[rec, "ChunkCount"],
    "ReleaseContextRef" -> Lookup[rec, "ReleaseContextRef"]|>
];

SourceVaultUnloadSearchIndex[indexId_String, opts___] :=
  ($loadedProjections = KeyDrop[$loadedProjections, indexId]; <|"Status" -> "Unloaded", "IndexId" -> indexId|>);

SourceVaultReloadSearchIndex[indexId_String, opts___] :=
  (SourceVaultUnloadSearchIndex[indexId]; SourceVaultLoadSearchIndex[indexId]);

SourceVaultListSearchIndexes[opts___] := Keys[$loadedProjections];

SourceVaultSearchIndexStatus[indexId_String, opts___] := Module[{rec = Lookup[$loadedProjections, indexId, Missing[]]},
  If[! AssociationQ[rec],
    <|"IndexId" -> indexId, "Loaded" -> False|>,
    <|"IndexId" -> indexId, "Loaded" -> True, "ChunkCount" -> Lookup[rec, "ChunkCount"],
      "ReleaseContextRef" -> Lookup[rec, "ReleaseContextRef"], "IndexKind" -> Lookup[rec, "IndexKind"]|>]
];

(* native 検索: load 済み projection を keyword スコア → request-time gate 再評価
   + revocation 照合 (§6.3.1) → Permit のみ top-N *)
iNativeSearch[query_String, ctxName_String, indexId_String, limit_] := Module[
  {rec, chunks, revSet, scored, top, results},
  rec = Lookup[$loadedProjections, indexId, Missing[]];
  If[! AssociationQ[rec],
    Module[{ld = SourceVaultLoadSearchIndex[indexId]},
      If[FailureQ[ld], Return[Failure["IndexNotLoaded", <|"IndexId" -> indexId|>]]];
      rec = Lookup[$loadedProjections, indexId]]];
  chunks = Lookup[rec, "Chunks", {}];
  revSet = Lookup[SourceVault`SourceVaultBuildRevocationSet[], "HotRevocationSet", <||>];
  scored = Map[Function[ch,
    <|"Chunk" -> ch, "Score" -> iKeywordScore[
      Lookup[ch, "NormalizedText", Lookup[ch, "Text", ""]], query]|>], chunks];
  scored = Select[scored, Lookup[#, "Score"] > 0 &];
  top = Take[ReverseSortBy[scored, Lookup[#, "Score"] &], UpTo[limit]];
  results = Map[Function[sc, Module[{ch = Lookup[sc, "Chunk"], gate, objId, revoked, sr},
      (* request-time gate 再評価 (ValidUntil/State/tags/privacy を NOW で) *)
      gate = SourceVaultEvaluateReleasePolicy[ch, ctxName];
      objId = Lookup[ch, "SourceVaultObjectId", Missing[]];
      revoked = StringQ[objId] && KeyExistsQ[revSet, objId];
      sr = <|"ResultId" -> "res:" <> CreateUUID[],
        "ChunkId" -> Lookup[ch, "ChunkId", "?"],
        "Score" -> Lookup[sc, "Score"],
        "Snippet" -> iSnippet[Lookup[ch, "NormalizedText", Lookup[ch, "Text", ""]], query],
        "EvidenceRef" -> "evid:" <> ToString @ Lookup[ch, "ChunkId", "?"],
        "Citation" -> <|"Title" -> Lookup[Lookup[ch, "SourceRef", <||>], "Title",
            Lookup[ch, "SourceVaultObjectId", ""]], "Page" -> Lookup[ch, "Page", Missing["Unknown"]]|>,
        "SourceVaultObjectId" -> objId,
        "ReleaseDecision" -> If[revoked, "Deny", Lookup[gate, "Decision", "Deny"]],
        "Revoked" -> revoked,
        "RequestTimeGateReevaluated" -> True,
        "PolicyDigestAtRequest" -> Lookup[gate, "PolicyDigest", Missing[]],
        "Why" -> If[revoked, Append[Lookup[gate, "Why", {}], "ObjectRevoked"], Lookup[gate, "Why", {}]]|>;
      sr]], top];
  (* raw path は元から持ち込まない。Permit かつ非 revoked のみ。 *)
  Select[results, Lookup[#, "ReleaseDecision"] === "Permit" &]
];

(* ============================================================
   §16 TPO 制約 / 目的別 index / 低遅延 interaction (Phase 7。device 非依存)
   ============================================================ *)

If[! AssociationQ[$tpoProfiles], $tpoProfiles = <||>];

SourceVaultValidateTPOProfile[spec_Association, opts___] := Module[{issues = {}, scope},
  scope = Lookup[spec, "AllowedScope", Missing[]];
  If[! AssociationQ[scope], AppendTo[issues, "AllowedScope missing"],
    If[! ListQ[Lookup[scope, "TopicTags", Missing[]]], AppendTo[issues, "AllowedScope.TopicTags missing"]]];
  <|"Status" -> If[issues === {}, "OK", "Invalid"], "Issues" -> issues|>];

SourceVaultRegisterTPOProfile[tpoId_String, spec_Association, opts___] := Module[{chk, norm},
  chk = SourceVaultValidateTPOProfile[spec];
  If[Lookup[chk, "Status"] =!= "OK", Return[Failure["InvalidTPOProfile", chk]]];
  norm = Join[<|"ObjectClass" -> "SourceVaultTPOProfile", "TPOId" -> tpoId,
    "TopicKeywords" -> <||>, "OutOfScopeKeywords" -> {},
    "ChannelProfile" -> <|"MaxAnswerCharacters" -> 120, "MaxAnswerSentences" -> 2|>,
    "OutOfScopePolicy" -> <||>|>, spec];
  $tpoProfiles[tpoId] = norm;
  <|"Status" -> "OK", "TPOId" -> tpoId|>];
SourceVaultTPOProfile[tpoId_String, opts___] := Lookup[$tpoProfiles, tpoId,
  Failure["UnregisteredTPOProfile", <|"TPOId" -> tpoId|>]];
SourceVaultListTPOProfiles[opts___] := Keys[$tpoProfiles];

(* question に含まれる keyword から topic を判定 (rule + keyword, LLM 非依存) *)
iMatchTopics[question_String, topicKw_Association] :=
  Keys @ Select[topicKw, Function[kws, AnyTrue[kws, StringContainsQ[question, #] &]]];

SourceVaultClassifyQuestionTPO[question_String, tpoId_String, opts___] := Module[
  {tpo, allowed, topicKw, oosKw, matchedOOS, matchedTopics, decision, reason, conf},
  tpo = SourceVaultTPOProfile[tpoId];
  If[FailureQ[tpo], Return[tpo]];
  allowed = Lookup[Lookup[tpo, "AllowedScope", <||>], "TopicTags", {}];
  topicKw = Lookup[tpo, "TopicKeywords", <||>];
  oosKw = Lookup[tpo, "OutOfScopeKeywords", {}];
  matchedOOS = Select[oosKw, StringContainsQ[question, #] &];
  matchedTopics = Intersection[iMatchTopics[question, topicKw], allowed];
  {decision, reason, conf} = Which[
    matchedOOS =!= {}, {"OutOfScope", "OutOfScopeKeyword(" <> StringRiffle[matchedOOS, ","] <> ")", 0.9},
    matchedTopics =!= {}, {"InScope", "TopicMatch", 0.9},
    True, {"NeedsClarification", "NoTopicMatch", 0.5}];
  <|"ObjectClass" -> "SourceVaultQueryScopeDecision", "Decision" -> decision,
    "TPOProfileRef" -> tpoId, "MatchedTopicTags" -> matchedTopics,
    "ReleaseContextRefs" -> Lookup[Lookup[tpo, "AllowedScope", <||>], "ReleaseContextRefs",
      Lookup[tpo, "ReleaseContextRefs", {}]],
    "Reason" -> reason, "Confidence" -> conf|>];
SourceVaultEvaluateTPOGate[question_String, tpoId_String, opts___] :=
  SourceVaultClassifyQuestionTPO[question, tpoId, opts];

(* TPO 制約で chunk を絞って projection index を作る *)
Options[SourceVaultBuildPurposeIndex] = {"Chunks" -> None, "ReleaseContext" -> Automatic};
SourceVaultBuildPurposeIndex[indexId_String, tpoId_String, OptionsPattern[]] := Module[
  {tpo, allowed, rc, chunks, filtered},
  tpo = SourceVaultTPOProfile[tpoId];
  If[FailureQ[tpo], Return[tpo]];
  chunks = OptionValue["Chunks"];
  If[! ListQ[chunks], Return[Failure["ChunksRequired", <|"IndexId" -> indexId|>]]];
  allowed = Lookup[Lookup[tpo, "AllowedScope", <||>], "TopicTags", {}];
  rc = OptionValue["ReleaseContext"] /. Automatic ->
    FirstCase[Lookup[Lookup[tpo, "AllowedScope", <||>], "ReleaseContextRefs",
      Lookup[tpo, "ReleaseContextRefs", {}]], _String, None];
  If[! StringQ[rc], Return[Failure["NoReleaseContextForTPO", <|"TPOId" -> tpoId|>]]];
  (* allowed topic tags と交わる chunk のみ (build-time gate は BuildProjectionIndex が行う) *)
  filtered = Select[chunks, Intersection[Lookup[#, "Tags", {}], allowed] =!= {} &];
  SourceVaultBuildProjectionIndex[rc, "Chunks" -> filtered, "IndexId" -> indexId]];

(* 回答長制約 (§16.2 ChannelProfile) を適用 *)
iEnforceAnswerLength[text_String, tpo_Association] := Module[{maxC},
  maxC = Lookup[Lookup[tpo, "ChannelProfile", <||>], "MaxAnswerCharacters", 120];
  If[StringLength[text] <= maxC, text, StringTake[text, maxC - 1] <> "\:2026"]];

Options[SourceVaultAnswerForInteraction] = {
  "Index" -> None, "ReleaseContext" -> Automatic, "DeadlineMs" -> 3000};
SourceVaultAnswerForInteraction[question_String, tpoId_String, OptionsPattern[]] := Module[
  {tpo, t0, scope, idx, rc, results, elapsed, deadlineMet, decision, answer, evRefs, wf, fallback},
  t0 = AbsoluteTime[];
  tpo = SourceVaultTPOProfile[tpoId];
  If[FailureQ[tpo], Return[tpo]];
  idx = OptionValue["Index"];
  rc = OptionValue["ReleaseContext"] /. Automatic ->
    FirstCase[Lookup[Lookup[tpo, "AllowedScope", <||>], "ReleaseContextRefs",
      Lookup[tpo, "ReleaseContextRefs", {}]], _String, None];
  fallback = iEnforceAnswerLength["申し訳ありません、その質問にはお答えできません。", tpo];
  scope = SourceVaultClassifyQuestionTPO[question, tpoId];
  decision = "NoAnswer"; answer = fallback; evRefs = {}; wf = "Fallback";
  Which[
    MemberQ[{"OutOfScope", "Blocked"}, Lookup[scope, "Decision"]],
      decision = "Refuse"; wf = "TPOGate";
      answer = iEnforceAnswerLength["その内容についてはお答えできません。", tpo],
    Lookup[scope, "Decision"] === "NeedsClarification",
      decision = "Clarify"; wf = "TPOGate";
      answer = iEnforceAnswerLength["もう少し詳しく教えていただけますか？", tpo],
    Lookup[scope, "Decision"] === "InScope" && StringQ[idx] && StringQ[rc],
      results = SourceVaultSearch[question, "ReleaseContext" -> rc, "Index" -> idx, "Limit" -> 3];
      elapsed = (AbsoluteTime[] - t0) * 1000.;
      If[! FailureQ[results] && Length[results] > 0 &&
          elapsed <= OptionValue["DeadlineMs"],
        decision = "Speak"; wf = "PurposeIndex";
        answer = iEnforceAnswerLength[Lookup[First[results], "Snippet", ""], tpo];
        evRefs = Lookup[#, "EvidenceRef"] & /@ results,
        decision = "NoAnswer"; wf = "Fallback";
        answer = iEnforceAnswerLength["該当する情報が見つかりませんでした。", tpo]],
    True, decision = "NoAnswer"];
  elapsed = (AbsoluteTime[] - t0) * 1000.;
  deadlineMet = elapsed <= OptionValue["DeadlineMs"];
  <|"Decision" -> decision, "AnswerText" -> answer, "EvidenceRefs" -> evRefs,
    "WorkflowUsed" -> wf, "ElapsedMs" -> Round[elapsed], "DeadlineMet" -> deadlineMet,
    "TPOGateDecision" -> scope|>];

(* ============================================================
   §17.4/§17.10/§17.13/§17.14 マルチモーダル event 正規化 / media index
   ============================================================ *)

$rawMediaKinds = {"AudioSegment", "CameraFrame", "ScreenSnapshot", "VRSNSEvent"};
$derivedMediaKinds = {"ASRTranscript", "VisualCaption", "OCR", "SystemSummary", "FAQCandidate", "RedactedTranscript"};

SourceVaultMediaPrivacyDefault[kind_String] := Switch[kind,
  "AudioSegment" | "CameraFrame" | "ScreenSnapshot", 1.0,
  "ASRTranscript", 0.8,
  "UserQuestion", 0.7,
  "SystemSummary" | "ResponseDraft" | "VisualCaption" | "OCR" | "FAQCandidate" | "RedactedTranscript", 0.5,
  _, 1.0];

SourceVaultAppendMultimodalEvent[event_Association, opts___] := Module[{sid, kind, ev},
  sid = Lookup[event, "SessionID", Missing[]];
  kind = Lookup[event, "Kind", Missing[]];
  If[! StringQ[sid] || ! StringQ[kind],
    Return[Failure["BadMultimodalEvent", <|
      "MessageTemplate" -> "MultimodalEvent には SessionID と Kind が必須です。"|>]]];
  ev = Join[<|"EventClass" -> "MultimodalEvent",
    "PrivacyLevel" -> SourceVaultMediaPrivacyDefault[kind]|>, event];
  SourceVault`SourceVaultAppendEvent[ev]];

Options[SourceVaultSessionEvents] = {"Kind" -> All};
SourceVaultSessionEvents[sessionId_String, OptionsPattern[]] := Module[{evs, kind},
  kind = OptionValue["Kind"];
  evs = Select[SourceVault`SourceVaultTransactionLog["Limit" -> All],
    Lookup[#, "EventClass"] === "MultimodalEvent" && Lookup[#, "SessionID"] === sessionId &];
  If[kind =!= All, evs = Select[evs, Lookup[#, "Kind"] === kind &]];
  SortBy[evs, Lookup[#, "CreatedAtUTC", ""] &]];

Options[SourceVaultBuildRealtimeContext] = {
  "TranscriptWindowSeconds" -> 20, "VisualWindowSeconds" -> 5, "MaxFrames" -> 3};
SourceVaultBuildRealtimeContext[sessionId_String, OptionsPattern[]] := Module[
  {evs, transcripts, visuals, question},
  evs = SourceVaultSessionEvents[sessionId];
  transcripts = Select[evs, Lookup[#, "Kind"] === "ASRTranscript" &];
  visuals = Select[evs, MemberQ[{"VisualCaption", "OCR", "CameraFrame", "ScreenSnapshot"}, Lookup[#, "Kind"]] &];
  question = With[{qs = Select[evs, Lookup[#, "Kind"] === "UserQuestion" &]},
    If[qs === {}, Missing["NoQuestion"], Lookup[Last[qs], "Text"]]];
  <|"ObjectClass" -> "SourceVaultObservationEnvelope", "EnvelopeID" -> "obs:" <> CreateUUID[],
    "SessionID" -> sessionId,
    "TranscriptText" -> StringRiffle[Lookup[#, "Text", ""] & /@ Take[transcripts, -Min[Length[transcripts], 8]], " "],
    "TranscriptEvents" -> Lookup[#, "EventID"] & /@ transcripts,
    "VisualEvents" -> Lookup[#, "EventID"] & /@ Take[visuals, -Min[Length[visuals], OptionValue["MaxFrames"]]],
    "UserQuestion" -> question, "CreatedAtUTC" -> DateString[Now, "ISODateTime"]|>];

(* media 由来 (derived) のみを chunk 化し projection index 化。raw media は入れない (§17.13)。 *)
Options[SourceVaultBuildMediaIndex] = {
  "ReleaseContext" -> None, "IndexId" -> Automatic,
  "Modalities" -> {"ASRTranscript", "VisualCaption", "OCR", "SystemSummary"}};
SourceVaultBuildMediaIndex[sessionId_String, OptionsPattern[]] := Module[
  {rc, mods, evs, chunks, indexId},
  rc = OptionValue["ReleaseContext"];
  If[! StringQ[rc], Return[Failure["ReleaseContextRequired", <|"Session" -> sessionId|>]]];
  mods = Intersection[OptionValue["Modalities"], $derivedMediaKinds];  (* raw は除外 *)
  evs = Select[SourceVaultSessionEvents[sessionId], MemberQ[mods, Lookup[#, "Kind"]] &];
  (* MultimodalEvent → chunk schema (§7.2) に変換 *)
  chunks = MapIndexed[Function[{e, i},
    <|"ChunkId" -> "mc-" <> sessionId <> "-" <> ToString[i[[1]]],
      "SourceVaultObjectId" -> Lookup[e, "EventID", "?"],
      "Text" -> Lookup[e, "Text", ""], "NormalizedText" -> Lookup[e, "Text", ""],
      "Page" -> Missing["NotPageBased"],
      "Tags" -> Lookup[e, "ReleaseContextTags", Lookup[e, "Tags", {}]],
      "PrivacyLevel" -> Lookup[e, "PrivacyLevel", SourceVaultMediaPrivacyDefault[Lookup[e, "Kind", ""]]],
      "State" -> Lookup[e, "State", "Published"],
      "SourceRef" -> <|"Title" -> Lookup[e, "Kind", "media"]|>|>], evs];
  indexId = OptionValue["IndexId"] /. Automatic -> (sessionId <> "-media");
  SourceVaultBuildProjectionIndex[rc, "Chunks" -> chunks, "IndexId" -> indexId]];

(* ============================================================
   §16.3 / §16.7 SurveyCorpus / SurveyIngestPlan
   サーベイ結果を IngestPolicy 越し(fail-closed)に取り込み、TPO 目的別 index 用の
   再現可能な corpus として束ねる。すべて core の event + immutable snapshot に乗る。
   ============================================================ *)

iSurveyUTCNow[] := DateString[
  {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"},
  TimeZone -> 0];
iSurveyPlanAlias[surveyId_, ver_] := "svsurveyplan:" <> surveyId <> ":" <> ver;
iSurveyCorpusAlias[corpusId_, ver_] := "svsurveycorpus:" <> corpusId <> ":" <> ver;

Options[SourceVault`SourceVaultCreateSurveyIngestPlan] = {"SurveyVersion" -> Automatic};
SourceVault`SourceVaultCreateSurveyIngestPlan[surveyId_String, spec_Association, OptionsPattern[]] := Module[
  {ver, rec, saved},
  If[! ListQ[Lookup[spec, "SourceQueries", Missing[]]],
    Return[Failure["SurveyPlanInvalid", <|
      "MessageTemplate" -> "SurveyIngestPlan には SourceQueries (リスト) が必須です。", "SurveyId" -> surveyId|>]]];
  If[! AssociationQ[Lookup[spec, "IngestPolicy", Missing[]]],
    Return[Failure["SurveyPlanInvalid", <|
      "MessageTemplate" -> "SurveyIngestPlan には IngestPolicy (Association) が必須です。", "SurveyId" -> surveyId|>]]];
  ver = OptionValue["SurveyVersion"] /. Automatic -> Lookup[spec, "SurveyVersion", "auto"];
  rec = Join[<|"ObjectClass" -> "SourceVaultSurveyIngestPlan",
    "SurveyId" -> surveyId, "SurveyVersion" -> ver|>, spec];
  saved = SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultSurveyIngestPlan", rec,
    "Alias" -> iSurveyPlanAlias[surveyId, ver]];
  If[FailureQ[saved], Return[saved]];
  <|"Status" -> "OK", "ObjectRef" -> Lookup[saved, "Ref"], "SnapshotRef" -> Lookup[saved, "Ref"],
    "Digest" -> Lookup[saved, "Digest"], "SurveyId" -> surveyId, "SurveyVersion" -> ver, "Warnings" -> {}|>];

SourceVault`SourceVaultIngestSurveyResult[planRef_String, source_Association, opts___] := Module[
  {plan, policy, prov, rcs, priv, maxPriv, content, blobRef, itemId, ev, review},
  plan = SourceVault`SourceVaultLoadImmutableSnapshot[planRef];
  If[FailureQ[plan], Return[plan]];
  policy = Lookup[plan, "IngestPolicy", <||>];
  prov = Lookup[source, "ProvenanceRef", Missing[]];
  rcs = Lookup[source, "ReleaseContextRefs", {}];
  priv = Lookup[source, "PrivacyLevel", 0.5];
  maxPriv = Lookup[policy, "MaxPrivacyLevel", 1.0];
  If[TrueQ[Lookup[policy, "RequireProvenance", False]] && ! StringQ[prov],
    Return[Failure["ProvenanceRequired", <|
      "MessageTemplate" -> "IngestPolicy.RequireProvenance: ProvenanceRef が必要です (fail-closed)。", "PlanRef" -> planRef|>]]];
  If[TrueQ[Lookup[policy, "RequireReleaseContext", False]] && (! ListQ[rcs] || rcs === {}),
    Return[Failure["ReleaseContextRequired", <|
      "MessageTemplate" -> "IngestPolicy.RequireReleaseContext: ReleaseContextRefs が必要です (fail-closed)。", "PlanRef" -> planRef|>]]];
  If[NumericQ[priv] && NumericQ[maxPriv] && priv > maxPriv,
    Return[Failure["PrivacyLevelExceeded", <|
      "MessageTemplate" -> "PrivacyLevel が IngestPolicy.MaxPrivacyLevel を超過 (fail-closed)。",
      "PrivacyLevel" -> priv, "MaxPrivacyLevel" -> maxPriv|>]]];
  content = Lookup[source, "Content", Missing[]];
  blobRef = Lookup[source, "BlobRef", Missing[]];
  If[(StringQ[content] || ByteArrayQ[content]) && ! StringQ[blobRef],
    blobRef = Lookup[SourceVault`SourceVaultCommitBlob[content], "BlobRef", Missing[]]];
  review = Lookup[source, "ReviewState", Lookup[policy, "DefaultReviewState", "NeedsHumanReview"]];
  itemId = "svitem:" <> CreateUUID[];
  ev = <|"EventClass" -> "SurveyItemIngested", "SurveyId" -> Lookup[plan, "SurveyId"], "PlanRef" -> planRef,
    "ItemId" -> itemId, "BlobRef" -> blobRef, "ProvenanceRef" -> prov, "ReleaseContextRefs" -> rcs,
    "Text" -> If[StringQ[content], content, Missing[]],
    "TopicTags" -> Lookup[source, "TopicTags", {}], "PrivacyLevel" -> priv, "ReviewState" -> review,
    "StalenessClass" -> Lookup[source, "StalenessClass", Missing[]],
    "ValidFrom" -> Lookup[source, "ValidFrom", Missing[]], "ValidUntil" -> Lookup[source, "ValidUntil", Missing[]],
    "Title" -> Lookup[source, "Title", Missing[]]|>;
  SourceVault`SourceVaultAppendEvent[ev];
  <|"Status" -> "OK", "ItemRef" -> itemId, "BlobRef" -> blobRef, "ReviewState" -> review, "Warnings" -> {}|>];

SourceVault`SourceVaultReviewSurveyItem[itemRef_String, decision_String, opts___] := (
  SourceVault`SourceVaultAppendEvent[<|"EventClass" -> "SurveyItemReviewed",
    "ItemId" -> itemRef, "ReviewState" -> decision, "ReviewedAtUTC" -> iSurveyUTCNow[]|>];
  <|"Status" -> "OK", "ItemRef" -> itemRef, "ReviewState" -> decision|>);

SourceVault`SourceVaultMarkSurveyItemStale[itemRef_String, reason_String, opts___] := (
  SourceVault`SourceVaultAppendEvent[<|"EventClass" -> "SurveyItemStale",
    "ItemId" -> itemRef, "Reason" -> reason, "MarkedAtUTC" -> iSurveyUTCNow[]|>];
  <|"Status" -> "OK", "ItemRef" -> itemRef, "Stale" -> True|>);

(* event replay → 現在の survey item 状態 (最新 review を fold, stale フラグ付与) *)
iSurveyItems[surveyId_String] := Module[{evs, ingested, reviews, stales},
  evs = SourceVault`SourceVaultTransactionLog["Limit" -> All];
  ingested = Select[evs, Lookup[#, "EventClass"] === "SurveyItemIngested" && Lookup[#, "SurveyId"] === surveyId &];
  reviews = Select[evs, Lookup[#, "EventClass"] === "SurveyItemReviewed" &];
  stales = Select[evs, Lookup[#, "EventClass"] === "SurveyItemStale" &];
  Map[Function[ev, Module[{id = Lookup[ev, "ItemId"], rvs, rv, st},
    rvs = Select[reviews, Lookup[#, "ItemId"] === id &];
    rv = If[rvs === {}, Missing[], Last[SortBy[rvs, Lookup[#, "CreatedAtUTC", ""] &]]];
    st = AnyTrue[stales, Lookup[#, "ItemId"] === id &];
    <|"ItemId" -> id, "BlobRef" -> Lookup[ev, "BlobRef"], "ProvenanceRef" -> Lookup[ev, "ProvenanceRef"],
      "Text" -> Lookup[ev, "Text"],
      "TopicTags" -> Lookup[ev, "TopicTags", {}], "ReleaseContextRefs" -> Lookup[ev, "ReleaseContextRefs", {}],
      "PrivacyLevel" -> Lookup[ev, "PrivacyLevel"], "Title" -> Lookup[ev, "Title"],
      "StalenessClass" -> Lookup[ev, "StalenessClass"],
      "ValidFrom" -> Lookup[ev, "ValidFrom"], "ValidUntil" -> Lookup[ev, "ValidUntil"],
      "ReviewState" -> If[AssociationQ[rv], Lookup[rv, "ReviewState"], Lookup[ev, "ReviewState", "NeedsHumanReview"]],
      "Stale" -> st|>]], ingested]];

SourceVault`SourceVaultBuildSurveyCorpus[surveyId_String, opts___] := Module[{items},
  items = iSurveyItems[surveyId];
  <|"Status" -> "OK", "ObjectClass" -> "SourceVaultSurveyCorpus", "SurveyId" -> surveyId,
    "Items" -> items, "ItemCount" -> Length[items],
    "Reviewed" -> Count[items, _?(Lookup[#, "ReviewState"] === "HumanReviewed" &)],
    "Stale" -> Count[items, _?(TrueQ[Lookup[#, "Stale"]] &)]|>];

Options[SourceVault`SourceVaultFreezeSurveyCorpus] = {
  "SurveyId" -> Automatic, "Items" -> Automatic, "Version" -> Automatic, "PlanRef" -> None};
SourceVault`SourceVaultFreezeSurveyCorpus[corpusId_String, OptionsPattern[]] := Module[{items, ver, rec, saved, sid},
  items = OptionValue["Items"];
  If[items === Automatic,
    sid = OptionValue["SurveyId"];
    If[! StringQ[sid],
      Return[Failure["SurveyCorpusItemsRequired", <|
        "MessageTemplate" -> "Items または SurveyId が必要です。", "CorpusId" -> corpusId|>]]];
    items = iSurveyItems[sid]];
  ver = OptionValue["Version"] /. Automatic -> "auto";
  rec = <|"ObjectClass" -> "SourceVaultSurveyCorpus", "SurveyCorpusId" -> corpusId, "SurveyCorpusVersion" -> ver,
    "SurveyIngestPlanRef" -> OptionValue["PlanRef"], "Items" -> items, "ItemCount" -> Length[items],
    "FrozenAtUTC" -> iSurveyUTCNow[], "Immutable" -> True|>;
  saved = SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultSurveyCorpus", rec,
    "Alias" -> iSurveyCorpusAlias[corpusId, ver]];
  If[FailureQ[saved], Return[saved]];
  <|"Status" -> "OK", "ObjectRef" -> Lookup[saved, "Ref"], "SnapshotRef" -> Lookup[saved, "Ref"],
    "Digest" -> Lookup[saved, "Digest"], "ItemCount" -> Length[items], "Warnings" -> {}|>];

SourceVault`SourceVaultSurveyCorpusStatus[corpusId_String, opts___] := Module[{rec, items},
  rec = SourceVault`SourceVaultLoadImmutableSnapshot[corpusId];
  If[AssociationQ[rec] && ! FailureQ[rec] && Lookup[rec, "ObjectClass"] === "SourceVaultSurveyCorpus",
    items = Lookup[rec, "Items", {}];
    <|"Status" -> "OK", "Frozen" -> True, "ItemCount" -> Length[items], "Digest" -> Lookup[rec, "Digest"],
      "Reviewed" -> Count[items, _?(Lookup[#, "ReviewState"] === "HumanReviewed" &)],
      "Stale" -> Count[items, _?(TrueQ[Lookup[#, "Stale"]] &)]|>,
    items = iSurveyItems[corpusId];
    <|"Status" -> "OK", "Frozen" -> False, "ItemCount" -> Length[items],
      "Reviewed" -> Count[items, _?(Lookup[#, "ReviewState"] === "HumanReviewed" &)],
      "Stale" -> Count[items, _?(TrueQ[Lookup[#, "Stale"]] &)]|>]];

(* ============================================================
   §16.4 / §16.7 PurposeIndexSpec / PurposeIndexSnapshot
   SurveyCorpus を選択ソースに TPO/SelectionPolicy で目的別 index を build →
   immutable snapshot。promote/rollback は core pointer。検索は projection index。
   ============================================================ *)

If[! AssociationQ[$purposeIndexSpecs], $purposeIndexSpecs = <||>];
iPISafe[s_String] := StringReplace[s, {":" -> "__", "/" -> "_"}];
iPIActivePointer[indexId_] := "active-purpose-index-" <> iPISafe[indexId];
iPIStagedPointer[indexId_] := "staged-purpose-index-" <> iPISafe[indexId];
(* PointerReplay は未設定でも assoc(Value->Missing) を返すので文字列のみ採用 *)
iPIPointerValue[r_] := Module[{v = If[AssociationQ[r], Lookup[r, "Value"], None]},
  If[StringQ[v], v, None]];

SourceVault`SourceVaultCreatePurposeIndexSpec[indexId_String, spec_Association, opts___] := Module[{rec, saved, ver},
  If[! StringQ[Lookup[spec, "TPOProfileRef", Missing[]]],
    Return[Failure["PurposeIndexSpecInvalid", <|
      "MessageTemplate" -> "PurposeIndexSpec には TPOProfileRef が必須です。", "IndexId" -> indexId|>]]];
  If[! AssociationQ[Lookup[spec, "SelectionPolicy", Missing[]]],
    Return[Failure["PurposeIndexSpecInvalid", <|
      "MessageTemplate" -> "PurposeIndexSpec には SelectionPolicy が必須です。", "IndexId" -> indexId|>]]];
  ver = Lookup[spec, "PurposeIndexVersion", "auto"];
  rec = Join[<|"ObjectClass" -> "SourceVaultPurposeIndexSpec",
    "PurposeIndexId" -> indexId, "PurposeIndexVersion" -> ver|>, spec];
  saved = SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultPurposeIndexSpec", rec,
    "Alias" -> "svpurposeindexspec:" <> indexId <> ":" <> ver];
  If[FailureQ[saved], Return[saved]];
  $purposeIndexSpecs[indexId] = Join[rec, <|"SpecRef" -> Lookup[saved, "Ref"]|>];
  <|"Status" -> "OK", "ObjectRef" -> Lookup[saved, "Ref"], "SnapshotRef" -> Lookup[saved, "Ref"],
    "Digest" -> Lookup[saved, "Digest"], "Warnings" -> {}|>];

SourceVault`SourceVaultListPurposeIndexes[opts___] := Keys[$purposeIndexSpecs];

iSelectCorpusItems[items_List, sel_Association] := Module[{inc, exc, reqRev, maxP},
  inc = Lookup[sel, "IncludeTopicTags", {}];
  exc = Lookup[sel, "ExcludeTopicTags", {}];
  reqRev = Lookup[sel, "RequireReviewState", Missing[]];
  maxP = Lookup[sel, "MaxPrivacyLevel", 1.0];
  Select[items, Function[it,
    (! TrueQ[Lookup[it, "Stale"]]) &&
    (inc === {} || Intersection[Lookup[it, "TopicTags", {}], inc] =!= {}) &&
    (Intersection[Lookup[it, "TopicTags", {}], exc] === {}) &&
    (! StringQ[reqRev] || Lookup[it, "ReviewState"] === reqRev) &&
    (! NumericQ[Lookup[it, "PrivacyLevel"]] || Lookup[it, "PrivacyLevel"] <= maxP)]]];

iItemsToChunks[items_List] := MapIndexed[Function[{it, i},
  <|"ChunkId" -> "pi-" <> ToString[i[[1]]] <> "-" <> StringTake[Lookup[it, "ItemId", "x"] <> "00000000", -8],
    "SourceVaultObjectId" -> Lookup[it, "ItemId", "?"],
    "Text" -> Lookup[it, "Text", ""], "NormalizedText" -> Lookup[it, "Text", ""],
    "Page" -> Missing["NotPageBased"],
    "Tags" -> Join[Lookup[it, "TopicTags", {}], Lookup[it, "ReleaseContextRefs", {}]],
    "PrivacyLevel" -> Lookup[it, "PrivacyLevel", 0.5],
    "State" -> If[Lookup[it, "ReviewState"] === "HumanReviewed", "Published", "Draft"],
    "SourceRef" -> <|"Title" -> Lookup[it, "Title", "survey-item"]|>|>], items];

SourceVault`SourceVaultBuildPurposeIndex[indexId_String, OptionsPattern[]] := Module[
  {spec, corpusRef, corpus, items, sel, selected, chunks, rc, projId, proj, ver, rec, saved},
  spec = Lookup[$purposeIndexSpecs, indexId, Missing[]];
  If[! AssociationQ[spec],
    Return[Failure["PurposeIndexSpecNotFound", <|
      "MessageTemplate" -> "先に CreatePurposeIndexSpec が必要です。", "IndexId" -> indexId|>]]];
  corpusRef = Lookup[spec, "SurveyCorpusRef", Missing[]];
  If[! StringQ[corpusRef], Return[Failure["SurveyCorpusRefRequired", <|"IndexId" -> indexId|>]]];
  corpus = SourceVault`SourceVaultLoadImmutableSnapshot[corpusRef];
  If[FailureQ[corpus], Return[corpus]];
  items = Lookup[corpus, "Items", {}];
  sel = Lookup[spec, "SelectionPolicy", <||>];
  selected = iSelectCorpusItems[items, sel];
  chunks = iItemsToChunks[selected];
  rc = FirstCase[Lookup[spec, "ReleaseContextRefs", {}], _String, None];
  If[! StringQ[rc], Return[Failure["NoReleaseContextForPurposeIndex", <|"IndexId" -> indexId|>]]];
  projId = indexId <> "-proj";
  proj = SourceVaultBuildProjectionIndex[rc, "Chunks" -> chunks, "IndexId" -> projId];
  If[FailureQ[proj], Return[proj]];
  SourceVaultLoadSearchIndex[projId];
  ver = Lookup[spec, "PurposeIndexVersion", "auto"];
  rec = <|"ObjectClass" -> "SourceVaultPurposeIndexSnapshot", "PurposeIndexId" -> indexId,
    "PurposeIndexVersion" -> ver, "PurposeIndexSpecRef" -> Lookup[spec, "SpecRef"],
    "TPOProfileRef" -> Lookup[spec, "TPOProfileRef"], "SurveyCorpusRef" -> corpusRef,
    "ProjectionIndexId" -> projId,
    "IndexSnapshotRefs" -> {Lookup[proj, "Ref", Lookup[proj, "SnapshotRef", projId]]},
    "ItemsSelected" -> Length[selected], "PromotionState" -> "Staged",
    "BuiltAtUTC" -> iSurveyUTCNow[], "Immutable" -> True|>;
  saved = SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultPurposeIndexSnapshot", rec,
    "Alias" -> "svpurposeindex:" <> indexId <> ":" <> ver];
  If[FailureQ[saved], Return[saved]];
  SourceVault`SourceVaultAtomicUpdatePointer[iPIStagedPointer[indexId], Lookup[saved, "Ref"]];
  <|"Status" -> "OK", "SnapshotRef" -> Lookup[saved, "Ref"], "Digest" -> Lookup[saved, "Digest"],
    "ProjectionIndexId" -> projId, "ItemsSelected" -> Length[selected],
    "PromotionState" -> "Staged", "Warnings" -> {}|>];

SourceVault`SourceVaultPurposeIndexStatus[indexId_String, opts___] := Module[{spec, staged, active},
  spec = Lookup[$purposeIndexSpecs, indexId, Missing[]];
  If[! AssociationQ[spec], Return[<|"Status" -> "NotFound", "IndexId" -> indexId|>]];
  staged = SourceVault`SourceVaultPointerReplay[iPIStagedPointer[indexId]];
  active = SourceVault`SourceVaultPointerReplay[iPIActivePointer[indexId]];
  <|"Status" -> "OK", "IndexId" -> indexId, "TPOProfileRef" -> Lookup[spec, "TPOProfileRef"],
    "SurveyCorpusRef" -> Lookup[spec, "SurveyCorpusRef"], "ProjectionIndexId" -> indexId <> "-proj",
    "StagedRef" -> iPIPointerValue[staged], "ActiveRef" -> iPIPointerValue[active]|>];

SourceVault`SourceVaultPromotePurposeIndex[indexId_String, opts___] := Module[{staged, ref},
  staged = SourceVault`SourceVaultPointerReplay[iPIStagedPointer[indexId]];
  ref = If[AssociationQ[staged], Lookup[staged, "Value"], None];
  If[! StringQ[ref], Return[Failure["NoStagedPurposeIndex", <|"IndexId" -> indexId|>]]];
  SourceVault`SourceVaultAtomicUpdatePointer[iPIActivePointer[indexId], ref];
  <|"Status" -> "OK", "IndexId" -> indexId, "ActiveRef" -> ref, "PromotionState" -> "Production"|>];

SourceVault`SourceVaultRollbackPurposeIndex[indexId_String, opts___] := Module[{hist, prev},
  hist = SourceVault`SourceVaultPointerHistory[iPIActivePointer[indexId]];
  If[! ListQ[hist] || Length[hist] < 2,
    Return[Failure["NoPreviousPurposeIndex", <|
      "MessageTemplate" -> "rollback 先の履歴がありません。", "IndexId" -> indexId|>]]];
  prev = Lookup[hist[[-2]], "Value"];
  SourceVault`SourceVaultAtomicUpdatePointer[iPIActivePointer[indexId], prev];
  <|"Status" -> "OK", "IndexId" -> indexId, "ActiveRef" -> prev, "RolledBack" -> True|>];

Options[SourceVault`SourceVaultEvaluatePurposeIndex] = {"ReleaseContext" -> Automatic};
SourceVault`SourceVaultEvaluatePurposeIndex[indexId_String, evalSet_List, OptionsPattern[]] := Module[
  {spec, projId, rc, results, hits, qof},
  spec = Lookup[$purposeIndexSpecs, indexId, Missing[]];
  If[! AssociationQ[spec], Return[Failure["PurposeIndexSpecNotFound", <|"IndexId" -> indexId|>]]];
  projId = indexId <> "-proj";
  rc = OptionValue["ReleaseContext"] /. Automatic ->
    FirstCase[Lookup[spec, "ReleaseContextRefs", {}], _String, None];
  qof[q_] := If[AssociationQ[q], Lookup[q, "Question", ""], ToString[q]];
  results = Map[Function[q, Module[{r = SourceVaultSearch[qof[q],
       "ReleaseContext" -> rc, "Index" -> projId, "Limit" -> 3]},
    <|"Question" -> qof[q], "HitCount" -> If[ListQ[r], Length[r], 0]|>]], evalSet];
  hits = Count[results, _?(Lookup[#, "HitCount"] > 0 &)];
  <|"Status" -> "OK", "IndexId" -> indexId, "Total" -> Length[evalSet], "Hit" -> hits,
    "PassRate" -> If[evalSet === {}, 0., N[hits/Length[evalSet]]], "Results" -> results|>];

(* §16.7 TPO gate 補助 *)
SourceVault`SourceVaultSelectPurposeIndex[tpoRef_String, question_String, opts___] := Module[{cands, active},
  cands = Select[Keys[$purposeIndexSpecs],
    Lookup[$purposeIndexSpecs[#], "TPOProfileRef"] === tpoRef &];
  cands = Select[cands, Module[{a = SourceVault`SourceVaultPointerReplay[iPIActivePointer[#]]},
    AssociationQ[a] && StringQ[Lookup[a, "Value"]]] &];
  If[cands === {}, <|"Status" -> "NoActivePurposeIndex", "TPOProfileRef" -> tpoRef|>,
    active = SourceVault`SourceVaultPointerReplay[iPIActivePointer[First[cands]]];
    <|"Status" -> "OK", "PurposeIndexId" -> First[cands],
      "ProjectionIndexId" -> First[cands] <> "-proj", "ActiveRef" -> Lookup[active, "Value"]|>]];

SourceVault`SourceVaultExplainTPOGateDecision[decision_Association, opts___] := StringJoin[
  "Decision: ", ToString[Lookup[decision, "Decision", "?"]], "\n",
  "Matched topic tags: ", ToString[Lookup[decision, "MatchedTopicTags", {}]], "\n",
  "Rejected topic tags: ", ToString[Lookup[decision, "RejectedTopicTags", {}]], "\n",
  "Workflow hint: ", ToString[Lookup[decision, "WorkflowHint", Lookup[decision, "WorkflowUsed", "-"]]], "\n",
  "Reason: ", ToString[Lookup[decision, "Reason", ""]]];

SourceVault`SourceVaultSnapshotTPOProfile[tpoId_String, opts___] := Module[{tpo, saved},
  tpo = SourceVaultTPOProfile[tpoId];
  If[FailureQ[tpo], Return[tpo]];
  saved = SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultTPOProfileSnapshot",
    Join[<|"ObjectClass" -> "SourceVaultTPOProfileSnapshot", "TPOProfileId" -> tpoId|>, tpo],
    "Alias" -> "svtpo:" <> tpoId];
  If[FailureQ[saved], Return[saved]];
  <|"Status" -> "OK", "ObjectRef" -> Lookup[saved, "Ref"], "Digest" -> Lookup[saved, "Digest"]|>];

(* ============================================================
   §16.6 knowledge.txt から SourceVault object への移行 (prototype)
   生成物は全て DRAFT (NeedsHumanReview)。本番 promote 前に human review 必須。
   ============================================================ *)

iKReadUTF8[path_] := If[FileExistsQ[path],
  Quiet @ Check[ByteArrayToString[ReadByteArray[path], "UTF-8"], $Failed], $Failed];

(* "=== TYPE === subtitle" 区切りで section 分割 *)
iKParseSections[text_String] := Module[{lines, sections = {}, cur = {}, curHdr = None, flush},
  lines = StringSplit[text, "\n"];
  flush[] := If[curHdr =!= None,
    AppendTo[sections, <|"Header" -> curHdr, "Body" -> StringTrim[StringRiffle[cur, "\n"]]|>]];
  Do[If[StringStartsQ[StringTrim[ln], "==="],
      flush[]; curHdr = StringTrim[ln]; cur = {},
      AppendTo[cur, ln]], {ln, lines}];
  flush[];
  sections];

iKSectionType[hdr_String] := Which[
  StringContainsQ[hdr, "INSTRUCTION", IgnoreCase -> True], "INSTRUCTIONS",
  StringContainsQ[hdr, "FACT", IgnoreCase -> True], "FACTS",
  True, "OTHER"];

iKSubtitle[hdr_String] := StringTrim[StringReplace[hdr, {"===" -> "", "INSTRUCTIONS" -> "", "FACTS" -> ""}]];

(* subtitle / 本文キーワード → TopicTags (日本語/英語) *)
iKTopicTags[s_String] := Module[{t},
  t = DeleteDuplicates @ Flatten[{
    If[StringContainsQ[s, "スケジュール" | "イベント" | "日程" | "schedule" | "event", IgnoreCase -> True],
      {"Schedule", "OpenCampus"}, {}],
    If[StringContainsQ[s, "場所" | "施設" | "案内" | "トイレ" | "食堂" | "facilit" | "navigation" | "map" | "restroom" | "cafeteria", IgnoreCase -> True],
      {"Facilities", "Navigation"}, {}],
    If[StringContainsQ[s, "教員" | "教授" | "先生" | "faculty" | "professor", IgnoreCase -> True],
      {"FacultyPublicProfile"}, {}]}];
  If[t === {}, {"General"}, t]];

SourceVault`SourceVaultKnowledgeTxtToTPOProfile[path_String, opts___] := Module[
  {text, secs, instr, oos, spec},
  text = iKReadUTF8[path];
  If[! StringQ[text], Return[Failure["KnowledgeTxtNotReadable", <|"Path" -> path|>]]];
  secs = iKParseSections[text];
  instr = SelectFirst[secs, iKSectionType[Lookup[#, "Header", ""]] === "INSTRUCTIONS" &, <||>];
  (* "...以外はわからない" 行 → OutOfScopePolicy *)
  oos = SelectFirst[StringSplit[text, "\n"],
    StringContainsQ[#, "以外はわからない" | "以外は分からない" | "only answer", IgnoreCase -> True] &, ""];
  spec = <|"ObjectClass" -> "SourceVaultTPOProfile",
    "AllowedScope" -> <|"TopicTags" -> {"OpenCampus", "Schedule", "Facilities", "FacultyPublicProfile", "Navigation"},
      "ReleaseContextRefs" -> {}|>,
    "ChannelProfile" -> <|"MaxAnswerCharacters" -> 120, "MaxSentences" -> 2|>,
    "OutOfScopePolicy" -> <|"Statement" -> StringTrim[oos], "Behavior" -> "ShortRefuse"|>,
    "AnswerStyleNote" -> Lookup[instr, "Body", ""],
    "ReviewState" -> "NeedsHumanReview"|>;
  <|"Status" -> "OK", "TPOProfileSpec" -> spec, "ReviewState" -> "NeedsHumanReview",
    "Warnings" -> {"prototype: human review required before RegisterTPOProfile"}|>];

SourceVault`SourceVaultKnowledgeTxtToSurveyCorpus[path_String, opts___] := Module[
  {text, secs, factSecs, items},
  text = iKReadUTF8[path];
  If[! StringQ[text], Return[Failure["KnowledgeTxtNotReadable", <|"Path" -> path|>]]];
  secs = iKParseSections[text];
  factSecs = Select[secs, iKSectionType[Lookup[#, "Header", ""]] === "FACTS" &];
  items = Flatten @ Map[Function[sec, Module[{sub, tags, paras},
    sub = iKSubtitle[Lookup[sec, "Header", ""]];
    tags = iKTopicTags[sub <> " " <> Lookup[sec, "Body", ""]];
    (* 空行区切りの段落を1 item に *)
    paras = Select[StringTrim /@ StringSplit[Lookup[sec, "Body", ""], "\n\n"], StringLength[#] > 0 &];
    If[paras === {}, paras = If[StringLength[StringTrim[Lookup[sec, "Body", ""]]] > 0, {StringTrim[Lookup[sec, "Body", ""]]}, {}]];
    Map[<|"Text" -> #, "TopicTags" -> tags, "ReviewState" -> "NeedsHumanReview",
      "Provenance" -> <|"Source" -> "knowledge.txt", "Section" -> sub|>|> &, paras]]], factSecs];
  <|"Status" -> "OK", "Items" -> items, "ItemCount" -> Length[items],
    "ReviewState" -> "NeedsHumanReview",
    "Warnings" -> {"prototype: human review required before IngestSurveyResult"}|>];

SourceVault`SourceVaultKnowledgeTxtToPurposeIndexSpec[path_String, opts___] := Module[
  {corpus, tags},
  corpus = SourceVault`SourceVaultKnowledgeTxtToSurveyCorpus[path];
  If[FailureQ[corpus], Return[corpus]];
  tags = DeleteDuplicates @ Flatten[Lookup[#, "TopicTags", {}] & /@ Lookup[corpus, "Items", {}]];
  <|"Status" -> "OK",
    "PurposeIndexSpec" -> <|"ObjectClass" -> "SourceVaultPurposeIndexSpec",
      "TPOProfileRef" -> "<fill: svtpo:...>", "SurveyCorpusRef" -> "<fill: svsurveycorpus:...>",
      "ReleaseContextRefs" -> {},
      "SelectionPolicy" -> <|"IncludeTopicTags" -> tags, "ExcludeTopicTags" -> {"InternalOnly", "Unreviewed"},
        "RequireReviewState" -> "HumanReviewed", "MaxPrivacyLevel" -> 0.5|>,
      "IndexPlan" -> <|"IndexKinds" -> {"KeywordFTS", "HotFAQ"}, "AnswerLengthPolicy" -> <|"MaxCharacters" -> 120|>|>|>,
    "ReviewState" -> "NeedsHumanReview",
    "Warnings" -> {"prototype: fill TPOProfileRef / SurveyCorpusRef / ReleaseContextRefs then human review"}|>];

SourceVault`SourceVaultImportKnowledgeTxt[path_String, opts___] := Module[{tpo, corpus, pidx},
  If[! FileExistsQ[path], Return[Failure["KnowledgeTxtNotFound", <|"Path" -> path|>]]];
  tpo = SourceVault`SourceVaultKnowledgeTxtToTPOProfile[path];
  corpus = SourceVault`SourceVaultKnowledgeTxtToSurveyCorpus[path];
  pidx = SourceVault`SourceVaultKnowledgeTxtToPurposeIndexSpec[path];
  <|"Status" -> "OK", "Path" -> path,
    "TPOProfile" -> tpo, "SurveyCorpus" -> corpus, "PurposeIndexSpec" -> pidx,
    "ReviewState" -> "NeedsHumanReview",
    "Warnings" -> {"prototype: 全 draft。human review 後に Register/Ingest/Build へ手動投入する。"}|>];

(* ============================================================
   §8.11 評価セット / retrieval workflow の評価・比較・段階的切替
   ReleasePolicyViolationCount と RawPathLeakCount が 0 でなければ promote 禁止。
   ============================================================ *)
If[! AssociationQ[$evaluationSets], $evaluationSets = <||>];

iEvalMean[l_List] := If[l === {}, 0., N[Mean[l]]];
iEvalP[l_List, q_] := If[l === {}, 0, Round[Quantile[N[l], q]]];
(* raw path leak: 結果中の文字列に絶対パスらしき形 (drive:バックスラッシュ, unix home 配下) を検出。
   path リテラルは StringJoin で組み立てる (config doctor の userpath 誤検出回避)。 *)
iEvalRawPathLeakQ[r_] := Module[{strs, bs = FromCharacterCode[92], up, hp},
  up = "/" <> "Users" <> "/"; hp = "/" <> "home" <> "/";
  strs = Cases[r, _String, Infinity];
  AnyTrue[strs, StringContainsQ[#, ":" <> bs] || StringContainsQ[#, up] ||
    StringContainsQ[#, hp] &]];

iEvalDefaultRun[idx_String, rc_String] := Function[q, Module[{t0 = AbsoluteTime[], r},
  r = SourceVaultSearch[q, "ReleaseContext" -> rc, "Index" -> idx, "Limit" -> 3];
  If[FailureQ[r], r = {}];
  <|"Answer" -> If[r =!= {}, Lookup[First[r], "Snippet", ""], ""],
    "Evidence" -> DeleteMissing[Lookup[#, "EvidenceRef", Missing[]] & /@ r],
    "Citations" -> (Lookup[#, "Citation", <||>] & /@ r),
    "NoAnswer" -> (r === {}), "LatencyMs" -> (AbsoluteTime[] - t0)*1000.,
    "LLMCalls" -> 0, "ToolCalls" -> 0, "TokenCost" -> 0,
    "ReleasePolicyViolations" -> 0, "RawPathLeaks" -> Count[r, _?iEvalRawPathLeakQ]|>]];

iEvalCorrect[it_Association, res_Association] := Module[
  {exp = Lookup[it, "ExpectedAnswerContains", Missing[]], inScope = Lookup[it, "ExpectInScope", True]},
  Which[
    inScope === False, TrueQ[Lookup[res, "NoAnswer"]],
    StringQ[exp], ! TrueQ[Lookup[res, "NoAnswer"]] && StringContainsQ[Lookup[res, "Answer", ""], exp],
    True, ! TrueQ[Lookup[res, "NoAnswer"]]]];

SourceVault`SourceVaultRegisterEvaluationSet[evalId_String, spec_Association, opts___] := Module[{items, rec, saved},
  items = Lookup[spec, "Items", Missing[]];
  If[! ListQ[items],
    Return[Failure["EvaluationSetInvalid", <|
      "MessageTemplate" -> "EvaluationSet には Items (リスト) が必須です。", "EvalId" -> evalId|>]]];
  rec = Join[<|"ObjectClass" -> "SourceVaultEvaluationSet", "EvalId" -> evalId|>, spec];
  saved = SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultEvaluationSet", rec, "Alias" -> "sveval:" <> evalId];
  $evaluationSets[evalId] = rec;
  <|"Status" -> "OK", "ObjectRef" -> Lookup[saved, "Ref"], "Digest" -> Lookup[saved, "Digest"],
    "ItemCount" -> Length[items]|>];

Options[SourceVault`SourceVaultEvaluateRetrievalWorkflow] = {
  "RunFunction" -> Automatic, "Index" -> None, "ReleaseContext" -> None};
SourceVault`SourceVaultEvaluateRetrievalWorkflow[workflowRef_String, evalId_String, OptionsPattern[]] := Module[
  {evset, items, run, perItem, lats, answered, expNo, sumK},
  evset = Lookup[$evaluationSets, evalId, Missing[]];
  If[! AssociationQ[evset], evset = SourceVault`SourceVaultLoadImmutableSnapshot[evalId]];
  If[! AssociationQ[evset] || FailureQ[evset],
    Return[Failure["EvaluationSetNotFound", <|"EvalId" -> evalId|>]]];
  items = Lookup[evset, "Items", {}];
  run = OptionValue["RunFunction"];
  If[run === Automatic,
    If[! StringQ[OptionValue["Index"]] || ! StringQ[OptionValue["ReleaseContext"]],
      Return[Failure["RunFunctionOrIndexRequired", <|
        "MessageTemplate" -> "RunFunction か (Index と ReleaseContext) が必要です。"|>]]];
    run = iEvalDefaultRun[OptionValue["Index"], OptionValue["ReleaseContext"]]];
  perItem = Map[Function[it, Module[{q = Lookup[it, "Question", ""], res},
    res = run[q];
    If[! AssociationQ[res], res = <|"NoAnswer" -> True, "LatencyMs" -> 0.|>];
    Join[<|"Question" -> q|>, res,
      <|"Correct" -> iEvalCorrect[it, res], "ExpectNoAnswer" -> (Lookup[it, "ExpectInScope", True] === False)|>]]], items];
  lats = Lookup[#, "LatencyMs", 0.] & /@ perItem;
  answered = Select[perItem, ! TrueQ[Lookup[#, "NoAnswer"]] &];
  expNo = Select[perItem, TrueQ[Lookup[#, "ExpectNoAnswer"]] &];
  sumK[k_] := Total[Lookup[#, k, 0] & /@ perItem];
  <|"Status" -> "OK", "WorkflowRef" -> workflowRef, "EvalId" -> evalId, "ItemCount" -> Length[items],
    "Metrics" -> <|
      "AnswerCorrectness" -> iEvalMean[Boole[TrueQ[Lookup[#, "Correct"]]] & /@ perItem],
      "FaithfulnessToEvidence" -> iEvalMean[Boole[Lookup[#, "Evidence", {}] =!= {}] & /@ answered],
      "CitationCoverage" -> iEvalMean[Boole[Lookup[#, "Citations", {}] =!= {}] & /@ answered],
      "NoAnswerAppropriateness" -> If[expNo === {}, 1.0, iEvalMean[Boole[TrueQ[Lookup[#, "NoAnswer"]]] & /@ expNo]],
      "LatencyP50Ms" -> iEvalP[lats, 0.5], "LatencyP95Ms" -> iEvalP[lats, 0.95],
      "LLMCallCount" -> sumK["LLMCalls"], "TokenCost" -> sumK["TokenCost"],
      "ToolCallCount" -> sumK["ToolCalls"],
      "ReleasePolicyViolationCount" -> sumK["ReleasePolicyViolations"],
      "RawPathLeakCount" -> sumK["RawPathLeaks"]|>,
    "PerItem" -> perItem|>];

SourceVault`SourceVaultCompareRetrievalWorkflows[workflowRefs_List, evalId_String, opts___] := Module[
  {reports, eligible, winner},
  reports = Map[SourceVault`SourceVaultEvaluateRetrievalWorkflow[#, evalId, opts] &, workflowRefs];
  reports = Select[reports, AssociationQ[#] && Lookup[#, "Status"] === "OK" &];
  eligible = Select[reports, Lookup[Lookup[#, "Metrics"], "ReleasePolicyViolationCount"] === 0 &&
    Lookup[Lookup[#, "Metrics"], "RawPathLeakCount"] === 0 &];
  winner = MaximalBy[eligible, Lookup[Lookup[#, "Metrics"], "AnswerCorrectness"] &, 1];
  <|"Status" -> "OK", "EvalId" -> evalId,
    "Reports" -> (<|"WorkflowRef" -> Lookup[#, "WorkflowRef"], "Metrics" -> Lookup[#, "Metrics"]|> & /@ reports),
    "RecommendedWorkflowRef" -> If[winner === {}, None, Lookup[First[winner], "WorkflowRef"]]|>];

iEvalWFPointer[serviceId_] := "active-workflow-" <> iPISafe[serviceId];
Options[SourceVault`SourceVaultPromoteWorkflowCandidate] = {
  "EvaluationReport" -> None, "EvalId" -> None, "Index" -> None, "ReleaseContext" -> None};
SourceVault`SourceVaultPromoteWorkflowCandidate[serviceId_String, workflowRef_String, OptionsPattern[]] := Module[
  {rep, m, viol, leak},
  rep = OptionValue["EvaluationReport"];
  If[! AssociationQ[rep] && StringQ[OptionValue["EvalId"]],
    rep = SourceVault`SourceVaultEvaluateRetrievalWorkflow[workflowRef, OptionValue["EvalId"],
      "Index" -> OptionValue["Index"], "ReleaseContext" -> OptionValue["ReleaseContext"]]];
  If[! AssociationQ[rep] || Lookup[rep, "Status"] =!= "OK",
    Return[Failure["NoEvaluationReport", <|
      "MessageTemplate" -> "EvaluationReport か (EvalId と Index/ReleaseContext) が必要です。"|>]]];
  m = Lookup[rep, "Metrics", <||>];
  viol = Lookup[m, "ReleasePolicyViolationCount", 1]; leak = Lookup[m, "RawPathLeakCount", 1];
  If[viol =!= 0 || leak =!= 0,
    Return[Failure["PromotionBlockedByPolicyViolation", <|
      "MessageTemplate" -> "ReleasePolicyViolationCount/RawPathLeakCount が 0 でないため promote 禁止 (§8.11)。",
      "ReleasePolicyViolationCount" -> viol, "RawPathLeakCount" -> leak|>]]];
  SourceVault`SourceVaultAtomicUpdatePointer[iEvalWFPointer[serviceId], workflowRef];
  SourceVault`SourceVaultAppendEvent[<|"EventClass" -> "WorkflowPromoted", "ServiceId" -> serviceId,
    "WorkflowRef" -> workflowRef, "AnswerCorrectness" -> Lookup[m, "AnswerCorrectness"]|>];
  <|"Status" -> "OK", "ServiceId" -> serviceId, "WorkflowRef" -> workflowRef, "Promoted" -> True,
    "AnswerCorrectness" -> Lookup[m, "AnswerCorrectness"]|>];

SourceVault`SourceVaultActiveWorkflow[serviceId_String, opts___] := Module[{ptr},
  ptr = SourceVault`SourceVaultPointerReplay[iEvalWFPointer[serviceId]];
  If[AssociationQ[ptr] && StringQ[Lookup[ptr, "Value"]], Lookup[ptr, "Value"], None]];

End[]  (* `SearchIndexPrivate` *)

EndPackage[]  (* SourceVault` *)
(* ロード時ヘルプは削除。API 一覧は SourceVault_info/docs を参照。 *)
