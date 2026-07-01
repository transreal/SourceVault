(* ::Package:: *)

(* SourceVault_mailstructure.wl
   一般メール構造化 (§6.5 の seed-optional 拡張)。
   仕様: SourceVault_info/design/sourcevault_general_mail_structuring_spec_v0_1.md (r3)
   OOPS 以外の一般メール(maildb)を、返信 session / 段落 topic item / topic item graph に
   構造化する。中核は TopicVocabulary 抽象で、OOPS seed の有無を吸収する。
   依存: SourceVault_oopsseed (段落/抽出/session/graph の primitive),
         SourceVault_lexical (NormalizeSearchText/BuildSurfaceIndex), SourceVault_maildb (adapter, Inc2+)。
   本ファイル Inc1: TopicVocabulary (seed-optional 語彙) の pass A (mail-level, r3)。 *)

BeginPackage["SourceVault`"]

(* ---- Inc 1: TopicVocabulary (seed-optional) ---- *)
SourceVaultNewTopicVocabulary::usage =
  "SourceVaultNewTopicVocabulary[opts] は空の TopicVocabulary を返す (seed 無しブートストラップ用)。" <>
  "opts \"OwnerRef\", \"PrivacyScope\"。";
SourceVaultTopicVocabularyFromSeed::usage =
  "SourceVaultTopicVocabularyFromSeed[dict, opts] は OOPS seed dict (or 任意の owner-scoped 辞書) から " <>
  "TopicVocabulary を作る (既存 topic item を再利用)。opts \"SeedRelationGraph\"(既定 <||>), \"SeedSource\", \"PrivacyScope\"。";
SourceVaultGrowTopicVocabulary::usage =
  "SourceVaultGrowTopicVocabulary[vocab, mails, opts] はメールコーパスから語彙を成長させる (seed-optional の核, r3 pass A)。" <>
  "各メールを prose 段落に絞り (block filter で quote/signature/footer 除外)、候補トピックを抽出し、" <>
  "複合 support の salience gate (既定 DistinctMails >= DistinctMailMin) を満たす繰り返し語だけを " <>
  "deterministic ref (svtopic:auto:<owner>:<normLabelHash>) の AutoExtracted topic item 化して vocab に追加する。" <>
  "各 entry は SupportRefs/SupportPrivacyMax/SupportTags/SupportGroupingKind/VisibilityPolicy を持ち、" <>
  "現 PrivacyScope の MaxPrivacyLevel/DenyTags を越える候補は除外する (public/cloud vocab に private label を入れない)。" <>
  "純関数 (新 vocab を返す; vocab[\"GrowReport\"] に採用/却下候補を付す)。" <>
  "opts: \"PrivacyScope\", \"GroupingKind\"(Mail|PreliminaryThread|Session, 既定 Mail), \"Sessions\"(mailRef->sessionId), " <>
  "\"DistinctMailMin\"(2)/\"DistinctThreadMin\"(2)/\"DistinctSessionMin\"(2), \"MinSupport\"(閾値を一括上書き), " <>
  "\"MaxNewTopics\"(200), \"OwnerRef\", \"Rounds\"(1), \"PerMailLimit\"(40), " <>
  "\"CandidateBlockFilters\"(除外 Kind, 既定 {Quote,Signature,Footer}), \"ImportRunId\"。";

(* ---- Inc 2: maildb アダプタ (canonical gate source + fail-safe, r3) ---- *)
SourceVaultMailSnapshotReleaseSource::usage =
  "SourceVaultMailSnapshotReleaseSource[snap] は maildb snapshot を SourceVaultEvaluateReleasePolicy 用の " <>
  "canonical source <|PrivacyLevel, Tags, State|> に射影する。PrivacyLevel は Derived.PrivacyLevel が " <>
  "numeric ならそれ、欠落/未生成は 1.0 (fail-safe)。Tags は Derived.AccessTags/DenyTags ∪ recipient privacy tag。";
SourceVaultMailToGenericRecord::usage =
  "SourceVaultMailToGenericRecord[snap, opts] は maildb snapshot を §3.1 generic record に変換する。" <>
  "release gate (opts \"ReleaseContext\", 既定 \"mailstruct-local\") で Permit のみ。Deny は Missing[\"Gated\"]、" <>
  "本文復号失敗は Body -> Missing[\"BodyDecryptFailed\"] (低漏洩 metadata は残す)。" <>
  "ThreadHeaders は MessageIDToken/InReplyToToken/ReferencesTokens (maildb は MessageIDToken のみ保持 → degraded)。";
SourceVaultMailRecordsForStructuring::usage =
  "SourceVaultMailRecordsForStructuring[opts] はロード済み snapshot (既定 SourceVaultMailSnapshotList[]) を " <>
  "generic record 列に変換する (Gated は除外、復号失敗は低漏洩 metadata で残す)。" <>
  "opts \"Snapshots\"(明示指定), \"MBox\", \"DateFrom\"/\"DateTo\"(ISO), \"ReleaseContext\", \"Limit\"。";
SourceVaultMailStructEnsureReleaseContexts::usage =
  "SourceVaultMailStructEnsureReleaseContexts[] は一般メール構造化用 release context (mailstruct-local / mailstruct-cloud) を冪等登録する。";
SourceVaultMailStructHeaderAvailability::usage =
  "SourceVaultMailStructHeaderAvailability[snaps] は ThreadHeaders token (MessageID/InReplyTo/References) の保持率を報告し、" <>
  "InReplyTo 保持率が閾値未満なら HeaderPassMode -> \"Degraded\" を返す (§6b degraded mode, r3-P1)。opts \"Threshold\"(0.5)。";

(* ---- Inc 3: Mail relation graph mining (§6, r3) ---- *)
SourceVaultBuildQuoteFingerprintIndex::usage =
  "SourceVaultBuildQuoteFingerprintIndex[records, opts] は各メールを span (SourceProse/QuoteQuery/ForwardedBlock) に分け、" <>
  "PrivacyScope ごとの keyed (scope-salted) line hash / shingle signature を作る (§6e)。raw quote text は保存しない。" <>
  "戻り値 <|Scope, ProfileDigest, BuildId, Spans, LineHashIndex|>。opts \"PrivacyScope\", \"MinLineChars\"(6), \"MinQuoteChars\"(12)。";
SourceVaultBuildMailRelationGraph::usage =
  "SourceVaultBuildMailRelationGraph[records, opts] は header/quote/subject/participant edge を typed directed multi-edge の " <>
  "SourceVaultMailRelationGraph に統合する (§6)。edge 方向は citing(From)->cited(To)、EdgeId は EvidenceKey 込みで deterministic、" <>
  "RelationRole は §6c の v0.1 決定論ルール。opts \"QuotePass\"(LocalOnly|IndexBuildOnly|Full, 既定 LocalOnly)、" <>
  "\"QuoteIndex\"(既存 index 再利用)、\"MaxContinuationGapDays\"(30)、budget系 \"MaxGlobalCandidatesPerQuote\"(20)/" <>
  "\"MaxQuoteBlocksPerMail\"(40)/\"MaxAmbiguityForMerge\"(2)、\"PrivacyScope\"、\"ProfileDigest\"。";
SourceVaultMineMailSessions::usage =
  "SourceVaultMineMailSessions[relationGraph, opts] は relation graph を session に projection する (§6d)。" <>
  "ThreadContinuation の強 edge (ReplyHeader/ReferenceHeader/direct QuoteExact, 低 ambiguity) だけで merge し、" <>
  "EvidenceCitation/AnnualEventReuse/TemplateReuse は merge せず cross-session reference として残す。" <>
  "戻り値 {<|MailSessionId, MailRefs, SessionGraphRef, CrossSessionReferences, ...|>...}。opts \"MaxAmbiguityForMerge\"(2), \"MergeConfidenceMin\"(0.5)。";

(* ---- Inc 4: 段落 topic 付与 + topic graph + 統合 (§7-§9, r3) ---- *)
SourceVaultBuildMailTopicGraph::usage =
  "SourceVaultBuildMailTopicGraph[relationGraph, topicsByMail, vocab, opts] は relation graph 駆動で " <>
  "auto topic 間の ObservedRelationGraph を作る (§8)。RelationRole を topic transition に写像 " <>
  "(ThreadContinuation->QuoteTransition / EvidenceCitation・AnnualEventReuse->HistoricalReferenceTransition / " <>
  "TemplateReuse->TemplateReuseTransition)、同一メール内共起は CoParagraph。低 confidence 引用は bounded boost。" <>
  "各 transition に Weight/EvidenceRefs/PrivacyMax。戻り値 <|fromRef -> {<|To,Kind,Weight,EvidenceRefs,PrivacyMax|>...}|>。" <>
  "opts \"MaxTopicsPerMail\"(8), \"BoundedBoostCap\"(0.3)。";
SourceVaultStructureMail::usage =
  "SourceVaultStructureMail[mails, opts] は一般メール構造化の統合パイプライン (§2)。" <>
  "pass A 語彙 -> relation graph + sessions -> pass B (session-aware 語彙 refine) -> 段落 topic 付与 -> topic graph。" <>
  "戻り値 <|Vocabulary, RelationGraph, Sessions, TopicGraph, ParagraphTopics, Records, Report|>。" <>
  "opts \"Seed\"(dict|None), \"Grow\"(True), \"PassB\"(True), \"QuotePass\"(Full), \"PrivacyScope\", \"OwnerRef\", \"MaxTopicsPerMail\"(8)。";

(* ---- Inc 5: 検索 / primer 接続 (§9, r3) ---- *)
SourceVaultMailStructSessionChunks::usage =
  "SourceVaultMailStructSessionChunks[structResult, opts] は StructureMail の結果から session 単位の検索 chunk を作る。" <>
  "privacy は record の PrivacyLevel/Tags (Inc2 adapter 継承。OOPS list privacy は使わない)、topic は vocab で enrichment。" <>
  "opts \"MaxBodyChars\"(4000), \"ReleaseState\"(Published)。";
SourceVaultMailStructBuildSearchIndex::usage =
  "SourceVaultMailStructBuildSearchIndex[structResult, opts] は session chunk から KeywordBM25V1 projection index を作り load する。" <>
  "戻り値 <|IndexId, Context, ChunkCount|>。opts \"ReleaseContext\"(mailstruct-local), \"IndexId\", \"IndexKind\"(KeywordBM25V1)。";
SourceVaultMailStructSearch::usage =
  "SourceVaultMailStructSearch[query, indexInfo, opts] は BuildSearchIndex の結果 (or IndexId 文字列) で release-gate 付き検索する。" <>
  "opts \"ReleaseContext\", \"Limit\"(10)。";
SourceVaultMailStructSessionDigest::usage =
  "SourceVaultMailStructSessionDigest[session, structResult, opts] は current session の結論と historical reference を分離した digest を返す (§9)。" <>
  "戻り値 <|SessionId, Subject, MailCount, Topics, CurrentDigest, HistoricalReferences|>。" <>
  "ThreadContinuation の timeline を CurrentDigest に、CrossSessionReferences(EvidenceCitation/AnnualEventReuse/TemplateReuse) を HistoricalReferences に。opts \"ParaChars\"(120), \"MaxMails\"(8)。";

Begin["`MailStructPrivate`"]

(* ---- vocab コンストラクタ (r3: privacy scope / profile digest / build id 付き) ---- *)
$svMSDefaultScope := <|"ReleaseContext" -> "owner-only", "MaxPrivacyLevel" -> 1.0, "DenyTags" -> {}|>;

iSVMSResolveScope[scope_] := Which[
  AssociationQ[scope], <|
    "ReleaseContext" -> Lookup[scope, "ReleaseContext", "owner-only"],
    "MaxPrivacyLevel" -> Lookup[scope, "MaxPrivacyLevel", 1.0],
    "DenyTags" -> Lookup[scope, "DenyTags", {}]|>,
  True, $svMSDefaultScope];

iSVMSShortHash[expr_] := StringTake[IntegerString[Hash[expr, "SHA256"], 36], UpTo[12]];

(* vocab 派生フィールド(SurfaceIndex/RefLabel/BuildId)を Dictionary から再構築 *)
iSVMSBuildVocab[parts_Association] := Module[
  {dict = Lookup[parts, "Dictionary", <|"Entries" -> {}|>],
   entries, scope, profileDigest},
  entries = Lookup[dict, "Entries", {}];
  scope = iSVMSResolveScope[Lookup[parts, "PrivacyScope", Automatic]];
  profileDigest = Lookup[parts, "ProfileDigest", "seed"];
  <|
    "ObjectClass" -> "SourceVaultTopicVocabulary",
    "VocabularyBuildId" -> "svvocab:" <> iSVMSShortHash[{profileDigest, #["TopicItemRef"] & /@ entries}],
    "ProfileDigest" -> profileDigest,
    "PrivacyScope" -> scope,
    "Dictionary" -> dict,
    "SurfaceIndex" -> SourceVaultBuildSurfaceIndex[dict],
    "SeedRelationGraph" -> Lookup[parts, "SeedRelationGraph", <||>],
    "ObservedRelationGraph" -> Lookup[parts, "ObservedRelationGraph", <||>],
    "RefLabel" -> Association[(#["TopicItemRef"] -> #["CanonicalLabel"]) & /@ entries],
    "Provenance" -> <|
      "SeedSource" -> Lookup[parts, "SeedSource", None],
      "GrownCount" -> Lookup[parts, "GrownCount", 0],
      "ImportRunId" -> Lookup[parts, "ImportRunId", None]|>,
    "GrowReport" -> Lookup[parts, "GrowReport", Missing["NotGrown"]]|>];

Options[SourceVaultNewTopicVocabulary] = {"OwnerRef" -> None, "PrivacyScope" -> Automatic};
SourceVaultNewTopicVocabulary[OptionsPattern[]] :=
  iSVMSBuildVocab[<|"Dictionary" -> <|"Entries" -> {}|>,
     "PrivacyScope" -> OptionValue["PrivacyScope"], "SeedSource" -> None|>];

Options[SourceVaultTopicVocabularyFromSeed] =
  {"SeedRelationGraph" -> <||>, "SeedSource" -> "OOPSSeed", "PrivacyScope" -> Automatic};
SourceVaultTopicVocabularyFromSeed[dict_Association, OptionsPattern[]] :=
  iSVMSBuildVocab[<|
    "Dictionary" -> <|"Entries" -> Lookup[dict, "Entries", {}]|>,
    "SeedRelationGraph" -> OptionValue["SeedRelationGraph"],
    "SeedSource" -> OptionValue["SeedSource"],
    "PrivacyScope" -> OptionValue["PrivacyScope"]|>];

(* 正規化キー: lexical の公開正規化を使い SurfaceIndex/既知除外と一致させる *)
iSVMSNormKey[s_String] := SourceVaultNormalizeSearchText[s];

(* Subject を preliminary thread key に (Re:/Fwd: 等を剥がす。空なら "" を返し呼び側で mailRef 代替) *)
iSVMSNormThread[subj_String] := Module[{s = ToLowerCase@StringTrim@subj},
  s = FixedPoint[
    StringTrim@StringReplace[#,
      StartOfString ~~ RegularExpression["(re|fwd|fw)\\s*[:\\x{FF1A}]"] -> ""] &, s];
  StringReplace[StringTrim@s, RegularExpression["\\s+"] -> " "]];

(* PrivacyLevel を数値化 (欠落/非数値は 1.0 fail-safe。§5 と同思想) *)
iSVMSPrivacyLevel[m_Association] := With[{p = Lookup[m, "PrivacyLevel", Missing[]]},
  If[NumericQ[p], N[p], 1.0]];

(* mail の正準参照 *)
iSVMSMailRef[m_Association, idx_Integer] := Which[
  StringQ[Lookup[m, "MailRef", Null]], m["MailRef"],
  StringQ[Lookup[m, "RecordId", Null]], "sv://mail/" <> m["RecordId"],
  True, "mail:" <> ToString[idx]];

Options[SourceVaultGrowTopicVocabulary] = {"PrivacyScope" -> Automatic,
  "GroupingKind" -> "Mail", "Sessions" -> None,
  "DistinctMailMin" -> 2, "DistinctThreadMin" -> 2, "DistinctSessionMin" -> 2,
  "MinSupport" -> Automatic, "MaxNewTopics" -> 200, "OwnerRef" -> None,
  "Rounds" -> 1, "PerMailLimit" -> 40,
  "CandidateBlockFilters" -> {"Quote", "Signature", "Footer"}, "ImportRunId" -> Automatic};

SourceVaultGrowTopicVocabulary[vocab_Association, mails_List, OptionsPattern[]] := Module[
  {scope = iSVMSResolveScope[OptionValue["PrivacyScope"]],
   grouping = OptionValue["GroupingKind"], sessions = OptionValue["Sessions"],
   maxNew = OptionValue["MaxNewTopics"], owner = OptionValue["OwnerRef"],
   rounds = OptionValue["Rounds"], perLim = OptionValue["PerMailLimit"],
   blockFilters = OptionValue["CandidateBlockFilters"],
   minSupportOpt = OptionValue["MinSupport"],
   ownerslug, threshold, profileDigest, importRunId, cur, round, changed, lastReport},
  ownerslug = owner /. {None -> "owner", o_String :> Last[StringSplit[o, ":"]]};
  threshold = If[IntegerQ[minSupportOpt], minSupportOpt,
    Switch[grouping,
      "PreliminaryThread", OptionValue["DistinctThreadMin"],
      "Session", OptionValue["DistinctSessionMin"],
      _, OptionValue["DistinctMailMin"]]];
  profileDigest = "pd:" <> iSVMSShortHash[
    {"passA-v1", grouping, threshold, maxNew, Sort[blockFilters], scope["ReleaseContext"]}];
  importRunId = OptionValue["ImportRunId"] /. Automatic ->
    "run:" <> iSVMSShortHash[{profileDigest, Length[mails]}];
  cur = vocab; round = 0; changed = True; lastReport = Missing["NotGrown"];
  While[round < rounds && changed,
    round++;
    Module[{known = Lookup[cur, "SurfaceIndex", <||>], mailInfo, byKey, aggregated,
      accepted, rejected, newEntries, newRefs, keptEntries, mergedDict, prevGrown},
     (* 1. 各メール: block filter → prose 段落のみ → 候補 surface(メール内 dedup) *)
     mailInfo = MapIndexed[Function[{m, pos}, Module[
        {idx = pos[[1]], mref, sender, subj, threadKey, sess, pl, tags, paras, prose, body, cands},
        mref = iSVMSMailRef[m, idx];
        sender = Lookup[m, "From", ""];
        subj = Lookup[m, "Subject", ""];
        threadKey = With[{t = iSVMSNormThread[subj]}, If[t === "", mref, "thr:" <> t]];
        sess = If[AssociationQ[sessions], Lookup[sessions, mref, mref], mref];
        pl = iSVMSPrivacyLevel[m]; tags = Lookup[m, "Tags", {}];
        (* Body 復号失敗 (Missing) は段落無し。ParseMailParagraphs に非文字列を渡さない *)
        paras = With[{bd = Lookup[m, "Body", ""]},
           If[StringQ[bd], SourceVaultParseMailParagraphs[bd], {}]];
        prose = Select[paras, ! MemberQ[blockFilters, #["Kind"]] &];
        body = SourceVaultStripOOPSMarkers[StringRiffle[#["Text"] & /@ prose, "\n"]];
        cands = DeleteDuplicatesBy[
          SourceVaultExtractCandidateTopics[body, "KnownSurfaceIndex" -> known, "Limit" -> perLim],
          iSVMSNormKey[#["Surface"]] &];
        <|"MailRef" -> mref, "Sender" -> sender, "ThreadKey" -> threadKey, "Session" -> sess,
          "PrivacyLevel" -> pl, "Tags" -> tags, "Candidates" -> cands|>]], mails];
     (* 2. 候補 normkey ごとに support を集計 *)
     byKey = <||>;
     Do[Do[With[{k = iSVMSNormKey[c["Surface"]]},
         byKey[k] = Append[Lookup[byKey, k, {}], <|"Info" -> mi, "Cand" -> c|>]],
        {c, mi["Candidates"]}], {mi, mailInfo}];
     aggregated = KeyValueMap[Function[{k, hits}, Module[
        {infos = #["Info"] & /@ hits, cands = #["Cand"] & /@ hits, unit},
        unit = Switch[grouping, "PreliminaryThread", #["ThreadKey"] &,
          "Session", #["Session"] &, _, #["MailRef"] &];
        <|"NormKey" -> k,
          "Surface" -> First[Commonest[#["Surface"] & /@ cands]],
          "ExtractionKind" -> First[Commonest[Lookup[#, "ExtractionKind", "Latin"] & /@ cands]],
          "SupportRefs" -> DeleteDuplicates[#["MailRef"] & /@ infos],
          "DistinctMails" -> Length[DeleteDuplicates[#["MailRef"] & /@ infos]],
          "DistinctSenders" -> Length[DeleteDuplicates[#["Sender"] & /@ infos]],
          "DistinctPreliminaryThreads" -> Length[DeleteDuplicates[#["ThreadKey"] & /@ infos]],
          "DistinctSessions" -> If[AssociationQ[sessions],
             Length[DeleteDuplicates[#["Session"] & /@ infos]], Missing["NoSessions"]],
          "SupportUnitCount" -> Length[DeleteDuplicates[unit /@ infos]],
          "SupportPrivacyMax" -> Max[#["PrivacyLevel"] & /@ infos],
          "SupportTags" -> DeleteDuplicates[Flatten[#["Tags"] & /@ infos]]|>]],
        byKey];
     (* 3. salience gate + privacy 継承フィルタ *)
     accepted = Select[aggregated, Function[a,
        a["SupportUnitCount"] >= threshold &&
        a["SupportPrivacyMax"] <= scope["MaxPrivacyLevel"] &&
        Intersection[a["SupportTags"], scope["DenyTags"]] === {}]];
     rejected = Complement[aggregated, accepted];
     accepted = Take[ReverseSortBy[accepted, {#["SupportUnitCount"], StringLength[#["Surface"]]} &],
        UpTo[maxNew]];
     (* 4. deterministic entry 生成 *)
     newEntries = Function[a, With[
        {ref = "svtopic:auto:" <> ownerslug <> ":" <> iSVMSShortHash[a["NormKey"]],
         pmax = a["SupportPrivacyMax"]},
        <|"TopicItemRef" -> ref, "Namespace" -> "extracted",
          "CanonicalLabel" -> a["Surface"], "SurfaceForms" -> {a["Surface"]},
          "NamespaceKind" -> "Extracted", "OwnerRef" -> owner,
          "SupportRefs" -> a["SupportRefs"],
          "SupportPrivacyMax" -> pmax, "SupportTags" -> a["SupportTags"],
          "DistinctMails" -> a["DistinctMails"], "DistinctSenders" -> a["DistinctSenders"],
          "DistinctPreliminaryThreads" -> a["DistinctPreliminaryThreads"],
          "DistinctSessions" -> a["DistinctSessions"],
          "SupportGroupingKind" -> grouping,
          "ReviewState" -> "Candidate",
          "VisibilityPolicy" -> <|"MaxPrivacyLevel" -> pmax, "DenyTags" -> a["SupportTags"]|>,
          "SupersededBy" -> Missing[],
          "PrivacyLevel" -> pmax,
          "Provenance" -> <|"Source" -> "AutoExtracted", "ExtractionKind" -> a["ExtractionKind"],
            "ProfileDigest" -> profileDigest, "ImportRunId" -> importRunId|>|>]] /@ accepted;
     newRefs = #["TopicItemRef"] & /@ newEntries;
     (* 5. merge: 同 ref の既存 entry は再生成版で置換 (deterministic → 重複しない) *)
     keptEntries = Select[Lookup[Lookup[cur, "Dictionary", <||>], "Entries", {}],
        ! MemberQ[newRefs, #["TopicItemRef"]] &];
     mergedDict = <|"Entries" -> Join[keptEntries, newEntries]|>;
     prevGrown = Lookup[Lookup[cur, "Provenance", <||>], "GrownCount", 0];
     lastReport = <|"GroupingKind" -> grouping, "Threshold" -> threshold,
        "AcceptedCount" -> Length[newEntries], "CandidateCount" -> Length[aggregated],
        "RejectedTopCandidates" -> (
          <|"Surface" -> #["Surface"], "SupportUnitCount" -> #["SupportUnitCount"],
            "SupportPrivacyMax" -> #["SupportPrivacyMax"]|> & /@
          Take[ReverseSortBy[rejected, #["SupportUnitCount"] &], UpTo[15]]),
        "SupportGroupingKindDistribution" -> Counts[#["SupportGroupingKind"] & /@ newEntries],
        "ProfileDigest" -> profileDigest, "ImportRunId" -> importRunId|>;
     If[newEntries === {} && Length[keptEntries] ===
          Length[Lookup[Lookup[cur, "Dictionary", <||>], "Entries", {}]],
       changed = False];
     cur = iSVMSBuildVocab[<|
        "Dictionary" -> mergedDict,
        "SeedRelationGraph" -> Lookup[cur, "SeedRelationGraph", <||>],
        "ObservedRelationGraph" -> Lookup[cur, "ObservedRelationGraph", <||>],
        "PrivacyScope" -> scope, "ProfileDigest" -> profileDigest,
        "SeedSource" -> Lookup[Lookup[cur, "Provenance", <||>], "SeedSource", None],
        "GrownCount" -> prevGrown + Length[newEntries],
        "ImportRunId" -> importRunId, "GrowReport" -> lastReport|>];
     ]];
  cur];

(* ================= Inc 2: maildb アダプタ ================= *)

(* 一般メール構造化用 release context (冪等)。
   - mailstruct-local: MaxPL 1.0・DenyTags {} (local-only。全許可ではなく gate は通す。§5)
   - mailstruct-cloud: MaxPL 1.0・私的 tag を DenyTags で拒否 (cloud/export 到達 client 向け) *)
SourceVaultMailStructEnsureReleaseContexts[] := (
  If[! MemberQ[SourceVaultListReleaseContexts[], "mailstruct-local"],
    SourceVaultRegisterReleaseContext["mailstruct-local", <|"MaxPrivacyLevel" -> 1.0, "DenyTags" -> {}|>]];
  If[! MemberQ[SourceVaultListReleaseContexts[], "mailstruct-cloud"],
    SourceVaultRegisterReleaseContext["mailstruct-cloud",
      <|"MaxPrivacyLevel" -> 1.0,
        "DenyTags" -> {"NoCloudLLM", "NoPublicExport", "PrivateML", "ThirdPartyContent"}|>]];);

iSVMSStrOr[x_] := If[StringQ[x], x, ""];

SourceVaultMailSnapshotReleaseSource[snap_Association] := Module[
  {d, pl, accessTags, denyTags, meta, to, cc, rcpt, tags},
  d = Lookup[snap, "Derived", <||>];
  pl = With[{p = Lookup[d, "PrivacyLevel", Missing[]]}, If[NumericQ[p], N[p], 1.0]];
  accessTags = With[{t = Lookup[d, "AccessTags", {}]}, If[ListQ[t], t, {}]];
  denyTags = With[{t = Lookup[d, "DenyTags", {}]}, If[ListQ[t], t, {}]];
  meta = Lookup[snap, "MailMetadataPublic", <||>];
  to = iSVMSStrOr[Lookup[meta, "To", ""]]; cc = iSVMSStrOr[Lookup[meta, "Cc", ""]];
  (* recipient(To/Cc) privacy を defense-in-depth で union (公開ヘッダがある時のみ) *)
  rcpt = If[to =!= "" || cc =!= "",
     SourceVaultMailRecipientPrivacy[<|"To" -> to, "Cc" -> cc|>],
     <|"PrivacyLevel" -> 0.0, "Tags" -> {}|>];
  tags = DeleteDuplicates[Join[accessTags, denyTags, Lookup[rcpt, "Tags", {}]]];
  <|"PrivacyLevel" -> Max[pl, Lookup[rcpt, "PrivacyLevel", 0.0]],
    "Tags" -> tags, "State" -> "Published"|>];

(* LegacyCounterAlias: RecordId 由来の deterministic 整数 (旧 oopsseed 整数キー互換。内部専用) *)
iSVMSLegacyAlias[recordId_String] := Mod[Hash[recordId, "SHA256"], 1000000000];
iSVMSLegacyAlias[_] := 0;

Options[SourceVaultMailToGenericRecord] = {"ReleaseContext" -> "mailstruct-local"};
SourceVaultMailToGenericRecord[snap_Association, OptionsPattern[]] := Module[
  {ctx = OptionValue["ReleaseContext"], src, gate, decrypt, body, meta, ms, recId, thread},
  SourceVaultMailStructEnsureReleaseContexts[];
  src = SourceVaultMailSnapshotReleaseSource[snap];
  gate = SourceVaultEvaluateReleasePolicy[src, ctx];
  If[Lookup[gate, "Decision", "Deny"] =!= "Permit", Return[Missing["Gated"]]];
  (* release Permit 後にのみ復号 *)
  decrypt = SourceVaultMailSnapshotDecryptBody[snap];
  body = If[Lookup[decrypt, "Status", ""] === "Ok" && TrueQ[Lookup[decrypt, "PlaintextReturned", False]],
     Lookup[decrypt, "Body", Missing["BodyDecryptFailed"]], Missing["BodyDecryptFailed"]];
  meta = Lookup[snap, "MailMetadataPublic", <||>];
  ms = Lookup[snap, "MailSource", <||>];
  recId = Lookup[snap, "RecordId", Missing[]];
  thread = <|
    "MessageIDToken" -> Lookup[ms, "MessageIDToken", Missing[]],
    "InReplyToToken" -> Lookup[ms, "InReplyToToken", Missing[]],   (* maildb 未保持 → Missing (degraded) *)
    "ReferencesTokens" -> With[{r = Lookup[ms, "ReferencesTokens", {}]}, If[ListQ[r], r, {}]]|>;
  <|
    "MailRef" -> "sv://mail/" <> If[StringQ[recId], recId, "unknown"],
    "RecordId" -> recId,
    "Subject" -> iSVMSStrOr[Lookup[meta, "Subject", ""]],
    "From" -> iSVMSStrOr[Lookup[meta, "From", ""]],
    "To" -> iSVMSStrOr[Lookup[meta, "To", ""]],
    "Cc" -> iSVMSStrOr[Lookup[meta, "Cc", ""]],
    "Date" -> iSVMSStrOr[Lookup[meta, "Date", ""]],
    "Body" -> body,
    "BodyWasHTML" -> TrueQ[Lookup[meta, "BodyWasHTML", False]],
    "ThreadHeaders" -> thread,
    "ReplyToAddr" -> Missing[],   (* maildb は Reply-To を別保持しない。participant signal 専用 (§3.1) *)
    "PrivacyLevel" -> src["PrivacyLevel"], "Tags" -> src["Tags"],
    "LegacyCounterAlias" -> iSVMSLegacyAlias[recId],
    "SourceRef" -> <|"Kind" -> "MaildbSnapshot",
      "MBox" -> Lookup[ms, "MBox", Missing[]],
      "ShardKey" -> Lookup[snap, "ShardKey", Missing[]]|>|>];

(* ISO 日付を DateObject に (失敗は Missing) *)
iSVMSParseISO[s_] := If[StringQ[s] && StringLength[s] >= 7,
  Quiet@Check[DateObject[s], Missing["BadDate"]], Missing["NoDate"]];

Options[SourceVaultMailRecordsForStructuring] = {"Snapshots" -> Automatic, "MBox" -> All,
  "DateFrom" -> None, "DateTo" -> None, "ReleaseContext" -> "mailstruct-local", "Limit" -> All};
SourceVaultMailRecordsForStructuring[OptionsPattern[]] := Module[
  {snaps = OptionValue["Snapshots"], mbox = OptionValue["MBox"],
   df = OptionValue["DateFrom"], dt = OptionValue["DateTo"],
   ctx = OptionValue["ReleaseContext"], lim = OptionValue["Limit"],
   dfo, dto, filtered, records},
  If[snaps === Automatic, snaps = SourceVaultMailSnapshotList[]];
  If[! ListQ[snaps], snaps = {}];
  dfo = If[df === None, Missing[], iSVMSParseISO[df]];
  dto = If[dt === None, Missing[], iSVMSParseISO[dt]];
  filtered = Select[snaps, Function[s, Module[{sm = Lookup[s, "MailSource", <||>],
      meta = Lookup[s, "MailMetadataPublic", <||>], d},
     And[
       mbox === All || Lookup[sm, "MBox", Missing[]] === mbox,
       If[Head[dfo] === DateObject, With[{d2 = iSVMSParseISO[Lookup[meta, "Date", ""]]},
          Head[d2] =!= DateObject || d2 >= dfo], True],
       If[Head[dto] === DateObject, With[{d2 = iSVMSParseISO[Lookup[meta, "Date", ""]]},
          Head[d2] =!= DateObject || d2 <= dto], True]]]]];
  If[IntegerQ[lim], filtered = Take[filtered, UpTo[lim]]];
  records = SourceVaultMailToGenericRecord[#, "ReleaseContext" -> ctx] & /@ filtered;
  DeleteCases[records, Missing["Gated"]]];   (* 復号失敗は残す (低漏洩 metadata)。Gated のみ除外 *)

(* token は String または ByteArray なら「あり」(鍵あり環境では HMAC が ByteArray になり得る) *)
iSVMSTokenPresentQ[t_] := (StringQ[t] && t =!= "") || (ByteArrayQ[t] && Length[t] > 0);

Options[SourceVaultMailStructHeaderAvailability] = {"Threshold" -> 0.5};
SourceVaultMailStructHeaderAvailability[snaps_List, OptionsPattern[]] := Module[
  {n = Length[snaps], msgid, inreply, refs, thr = OptionValue["Threshold"], frac},
  If[n === 0, Return[<|"Total" -> 0, "HeaderPassMode" -> "NoData"|>]];
  msgid = Count[snaps, s_ /; iSVMSTokenPresentQ[Lookup[Lookup[s, "MailSource", <||>], "MessageIDToken", Missing[]]]];
  inreply = Count[snaps, s_ /; iSVMSTokenPresentQ[Lookup[Lookup[s, "MailSource", <||>], "InReplyToToken", Missing[]]]];
  refs = Count[snaps, s_ /; With[{r = Lookup[Lookup[s, "MailSource", <||>], "ReferencesTokens", Missing[]]},
     ListQ[r] && Length[r] > 0]];
  frac = N[inreply/n];
  <|"Total" -> n,
    "MessageIDToken" -> <|"Count" -> msgid, "Fraction" -> N[msgid/n]|>,
    "InReplyToToken" -> <|"Count" -> inreply, "Fraction" -> frac|>,
    "ReferencesTokens" -> <|"Count" -> refs, "Fraction" -> N[refs/n]|>,
    "Threshold" -> thr,
    "HeaderPassMode" -> If[frac < thr, "Degraded", "Full"],
    "Note" -> If[frac < thr,
      "InReplyTo/References token 保持率が閾値未満。Header pass は degraded: ReplyHeader recall を分離し " <>
      "SubjectFallback promotion を厳格化 (§6b)。新規 import は raw header から token 生成 hook を通すこと。",
      "Header pass full。"]|>];

(* ================= Inc 3: Mail relation graph mining ================= *)

(* scope-salted keyed hash (§6e。cross-scope 照合を防ぐため salt に ReleaseContext を混ぜる。
   本番の HMAC key/salt 管理・rotation は §13 open issue 10) *)
iSVMSScopeSalt[scope_Association] := "svqfp:v1:" <> ToString[Lookup[scope, "ReleaseContext", "owner-only"]];
iSVMSKeyedHash[salt_String, s_String] := Hash[salt <> "\[RightArrow]" <> s, "SHA256"];

(* quote マーカー先頭 (>, ＞, 全角空白) を剥がして正規化 *)
iSVMSNormLine[line_String] := SourceVaultNormalizeSearchText[
  StringTrim@StringReplace[line, StartOfString ~~ RegularExpression["[>\\x{FF1E}\\s]+"] -> ""]];

(* From/To/Cc の addr-spec 集合 *)
iSVMSAddrs[record_Association] := ToLowerCase /@ DeleteDuplicates@StringCases[
  StringRiffle[{Lookup[record, "From", ""], Lookup[record, "To", ""], Lookup[record, "Cc", ""]}, " "],
  RegularExpression["[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}"]];

iSVMSSpanRoleOf[kind_, raw_String] := Which[
  StringContainsQ[raw, RegularExpression[
    "(?i)-----\\s*original message|forwarded message|\\x{8EE2}\\x{9001}\\x{3055}\\x{308C}\\x{305F}"]], "ForwardedBlock",
  kind === "Quote", "QuoteQuery",
  kind === "Prose", "SourceProse",
  True, Null];   (* Signature/Footer は fingerprint 対象外 *)

(* span の keyed fingerprint。raw text は保持しない (§6e) *)
iSVMSSpanFingerprint[text_String, salt_String, minLine_Integer] := Module[
  {normLines, lineHashes, words, wordShingles, noSpace, charGrams, shingles},
  normLines = Select[iSVMSNormLine /@ StringSplit[text, "\n"], StringLength[#] >= minLine &];
  lineHashes = DeleteDuplicates[iSVMSKeyedHash[salt, #] & /@ normLines];
  words = Select[StringSplit[SourceVaultNormalizeSearchText[text], RegularExpression["\\s+"]], # =!= "" &];
  wordShingles = If[Length[words] >= 2,
     iSVMSKeyedHash[salt, #] & /@ (StringRiffle /@ Partition[words, 2, 1]), {}];
  noSpace = StringDelete[SourceVaultNormalizeSearchText[text], RegularExpression["\\s+"]];
  charGrams = If[StringLength[noSpace] >= 4,
     iSVMSKeyedHash[salt, StringJoin[#]] & /@ Partition[Characters[noSpace], 4, 1], {}];
  shingles = Take[DeleteDuplicates[Join[wordShingles, charGrams]], UpTo[400]];
  <|"LineHashes" -> lineHashes, "Shingles" -> shingles,
    "CharLen" -> StringLength[StringJoin[normLines]], "LineCount" -> Length[normLines]|>];

iSVMSSpansOfRecord[record_Association, idx_Integer, salt_String, minLine_Integer, minQuote_Integer] :=
 Module[{mref, body, date, paras},
  mref = Lookup[record, "MailRef", "mail:" <> ToString[idx]];
  body = Lookup[record, "Body", ""];
  If[! StringQ[body], Return[{}]];   (* 復号失敗 → span 無し *)
  date = Lookup[record, "Date", ""];
  paras = SourceVaultParseMailParagraphs[body];
  DeleteCases[MapIndexed[Function[{p, pos}, Module[{role, fp},
     role = iSVMSSpanRoleOf[p["Kind"], Lookup[p, "RawText", p["Text"]]];
     If[role === Null, Nothing,
       fp = iSVMSSpanFingerprint[p["Text"], salt, minLine];
       If[fp["CharLen"] < minQuote || fp["LineHashes"] === {}, Nothing,
         <|"SpanRef" -> mref <> "#p" <> ToString[pos[[1]]], "MailRef" -> mref,
           "Date" -> date, "SpanRole" -> role,
           "LineHashes" -> fp["LineHashes"], "Shingles" -> fp["Shingles"],
           "CharLen" -> fp["CharLen"], "LineCount" -> fp["LineCount"]|>]]]], paras], Nothing]];

Options[SourceVaultBuildQuoteFingerprintIndex] = {"PrivacyScope" -> Automatic,
  "MinLineChars" -> 6, "MinQuoteChars" -> 12,
  "CommonDocFreqFraction" -> 0.3, "CommonDocFreqMinCount" -> 8};
SourceVaultBuildQuoteFingerprintIndex[records_List, OptionsPattern[]] := Module[
  {scope = iSVMSResolveScope[OptionValue["PrivacyScope"]], salt,
   minLine = OptionValue["MinLineChars"], minQuote = OptionValue["MinQuoteChars"],
   commonFrac = OptionValue["CommonDocFreqFraction"], commonMin = OptionValue["CommonDocFreqMinCount"],
   spans, nMails, commonThresh, byHash, commonSet, commonQ,
   lineIndex = <||>, shingleIndex = <||>, profileDigest},
  salt = iSVMSScopeSalt[scope];
  profileDigest = "qfp:" <> iSVMSShortHash[{"qfpv1", scope["ReleaseContext"], minLine, minQuote, commonFrac, commonMin}];
  spans = Flatten[MapIndexed[iSVMSSpansOfRecord[#1, #2[[1]], salt, minLine, minQuote] &, records], 1];
  (* common line/shingle の DF フィルタ (IDF 的ストップワード): 多数メールに出る hash は挨拶/定型で
     candidate 生成のノイズ源 → 除外。distinct mail 数 >= threshold の hash を落とす *)
  nMails = Length[DeleteDuplicates[#["MailRef"] & /@ spans]];
  commonThresh = Max[commonMin, Ceiling[commonFrac * nMails]];
  byHash = GroupBy[Flatten[Function[sp,
     ({#, sp["MailRef"]} & /@ Join[sp["LineHashes"], sp["Shingles"]])] /@ spans, 1], First -> Last];
  commonSet = Keys@Select[byHash, Length[DeleteDuplicates[#]] >= commonThresh &];
  commonQ = AssociationThread[commonSet -> True];
  spans = DeleteCases[Function[sp, Module[{lh, sh},
     lh = Select[sp["LineHashes"], ! KeyExistsQ[commonQ, #] &];
     sh = Select[sp["Shingles"], ! KeyExistsQ[commonQ, #] &];
     If[lh === {} && sh === {}, Nothing,
       Append[sp, <|"LineHashes" -> lh, "Shingles" -> sh|>]]]] /@ spans, Nothing];
  Do[Do[lineIndex[h] = Append[Lookup[lineIndex, h, {}], sp["SpanRef"]], {h, sp["LineHashes"]}];
     Do[shingleIndex[h] = Append[Lookup[shingleIndex, h, {}], sp["SpanRef"]], {h, sp["Shingles"]}],
     {sp, spans}];
  <|"ObjectClass" -> "SourceVaultQuoteFingerprintIndex", "Scope" -> scope,
    "ProfileDigest" -> profileDigest,
    "BuildId" -> "svqfp:" <> iSVMSShortHash[{profileDigest, Length[spans]}],
    "CommonHashCount" -> Length[commonSet], "CommonDocFreqThreshold" -> commonThresh,
    "Spans" -> spans, "SpanByRef" -> Association[(#["SpanRef"] -> #) & /@ spans],
    "LineHashIndex" -> lineIndex, "ShingleIndex" -> shingleIndex|>];

(* span ペアの overlap score *)
iSVMSSpanScore[q_Association, s_Association] := Module[{sharedL, lj, sj},
  sharedL = Length[Intersection[q["LineHashes"], s["LineHashes"]]];
  lj = N[sharedL/Max[1, Length[Union[q["LineHashes"], s["LineHashes"]]]]];
  sj = With[{i = Length[Intersection[q["Shingles"], s["Shingles"]]],
             u = Max[1, Length[Union[q["Shingles"], s["Shingles"]]]]}, N[i/u]];
  <|"SharedLines" -> sharedL, "LineJaccard" -> lj, "ShingleJaccard" -> sj|>];

(* 日付差 (日)。片方不明は Missing *)
iSVMSDaysBetween[d1_, d2_] := Module[{a = iSVMSParseISO[d1], b = iSVMSParseISO[d2]},
  If[Head[a] === DateObject && Head[b] === DateObject,
    QuantityMagnitude[DateDifference[a, b, "Day"]], Missing[]]];

(* §6c v0.1 deterministic RelationRole。{role, confidence} を返す *)
iSVMSRelationRole[f_Association] := Module[
  {kind = f["EdgeKind"], td = f["AbsTemporalDays"], maxGap = f["MaxGap"],
   sameSubj = f["SameSubject"], pOv = f["ParticipantOverlap"],
   lineage = f["QuoteLineage"], sRole = f["SourceSpanRole"], amb = f["AmbiguityCount"],
   sameMbox = f["SameMbox"], yearly},
  yearly = IntegerQ[td] || NumericQ[td] && 300 <= td <= 430;
  Which[
   MemberQ[{"ReplyHeader", "ReferenceHeader"}, kind] && (MissingQ[td] || td <= maxGap),
     {"ThreadContinuation", 0.9},
   kind === "ForwardedMessage" || sRole === "ForwardedBlock", {"ForwardedContext", 0.6},
   (NumericQ[td] && 300 <= td <= 430) && MemberQ[{"QuoteExact", "QuoteFuzzy"}, kind],
     {"AnnualEventReuse", 0.6},
   (* 高 ambiguity は継続判定より先に弾く (定型文の誤マージ防止, DoD f) *)
   amb > f["MaxAmbiguityForMerge"], {"UnknownReference", 0.4},
   MemberQ[{"QuoteExact", "QuoteFuzzy"}, kind] && lineage === "Direct" && sRole === "SourceProse" &&
     Count[{sameSubj, pOv, (NumericQ[td] && td <= maxGap)}, True] >= 2, {"ThreadContinuation", 0.75},
   MemberQ[{"QuoteExact", "QuoteFuzzy"}, kind] &&
     (! (NumericQ[td] && td <= maxGap) || ! sameSubj || ! pOv), {"EvidenceCitation", 0.6},
   kind === "SubjectFallback" && sameMbox && pOv, {"ThreadContinuation", 0.55},
   True, {"UnknownReference", 0.4}]];

Options[SourceVaultBuildMailRelationGraph] = {"QuotePass" -> "LocalOnly", "QuoteIndex" -> Automatic,
  "PrivacyScope" -> Automatic, "ProfileDigest" -> Automatic, "MaxContinuationGapDays" -> 30,
  "MaxGlobalCandidatesPerQuote" -> 20, "MaxQuoteBlocksPerMail" -> 40, "MaxAmbiguityForMerge" -> 2,
  "MinLineJaccardExact" -> 0.6, "MinShingleJaccardFuzzy" -> 0.3, "LocalWindowDays" -> 14,
  "SubjectStoplist" -> Automatic};
$svMSSubjectStoplist = {"", "会議", "確認", "資料", "連絡", "お知らせ", "案内",
  "よろしくお願いします", "ご連絡", "報告", "質問", "hello", "hi", "test", "meeting", "fyi"};
SourceVaultBuildMailRelationGraph[records_List, OptionsPattern[]] := Module[
  {scope = iSVMSResolveScope[OptionValue["PrivacyScope"]], quotePass = OptionValue["QuotePass"],
   maxGap = OptionValue["MaxContinuationGapDays"], maxGlob = OptionValue["MaxGlobalCandidatesPerQuote"],
   maxBlocks = OptionValue["MaxQuoteBlocksPerMail"], maxAmb = OptionValue["MaxAmbiguityForMerge"],
   minExact = OptionValue["MinLineJaccardExact"], minFuzzy = OptionValue["MinShingleJaccardFuzzy"],
   localWin = OptionValue["LocalWindowDays"],
   stop = OptionValue["SubjectStoplist"] /. Automatic -> $svMSSubjectStoplist,
   profileDigest, qindex, byRef, info, msgTokenToRef, edges = {}, querySpans, spanByRef,
   mkEdge, addEdge, graphId, nodes},
  profileDigest = OptionValue["ProfileDigest"] /. Automatic ->
    ("mrg:" <> iSVMSShortHash[{"mrgv1", scope["ReleaseContext"], maxGap, quotePass}]);
  qindex = OptionValue["QuoteIndex"] /. Automatic ->
    SourceVaultBuildQuoteFingerprintIndex[records, "PrivacyScope" -> scope];
  spanByRef = qindex["SpanByRef"];
  (* 各メールの派生情報 *)
  info = Association@MapIndexed[Function[{r, pos}, With[
     {mref = Lookup[r, "MailRef", "mail:" <> ToString[pos[[1]]]]},
     mref -> <|"Record" -> r, "Addrs" -> iSVMSAddrs[r],
       "Subject" -> iSVMSNormThread[Lookup[r, "Subject", ""]],
       "Date" -> Lookup[r, "Date", ""],
       "MBox" -> Lookup[Lookup[r, "SourceRef", <||>], "MBox", Missing[]],
       "PL" -> With[{p = Lookup[r, "PrivacyLevel", 1.0]}, If[NumericQ[p], N[p], 1.0]],
       "Tags" -> Lookup[r, "Tags", {}],
       "MsgId" -> Lookup[Lookup[r, "ThreadHeaders", <||>], "MessageIDToken", Missing[]],
       "InReplyTo" -> Lookup[Lookup[r, "ThreadHeaders", <||>], "InReplyToToken", Missing[]],
       "Refs" -> Lookup[Lookup[r, "ThreadHeaders", <||>], "ReferencesTokens", {}]|>]], records];
  byRef = Keys[info]; nodes = byRef;
  msgTokenToRef = Association[
     Select[Function[k, info[k]["MsgId"] -> k] /@ byRef, iSVMSTokenPresentQ[First[#]] &]];
  (* edge builder: privacy 継承 + RelationRole + deterministic EdgeId *)
  mkEdge[from_, to_, kind_, evidenceKey_, feat_] := Module[{roleR, plF, plT, tagsF, tagsT},
    roleR = iSVMSRelationRole[Append[feat, <|"EdgeKind" -> kind, "MaxGap" -> maxGap,
       "MaxAmbiguityForMerge" -> maxAmb|>]];
    plF = info[from]["PL"]; plT = info[to]["PL"];
    tagsF = info[from]["Tags"]; tagsT = info[to]["Tags"];
    <|"ObjectClass" -> "SourceVaultMailRelationEdge",
      "EdgeId" -> "svrel:" <> iSVMSShortHash[{profileDigest, from, to, kind, evidenceKey}],
      "FromMailRef" -> from, "ToMailRef" -> to, "EdgeKind" -> kind, "EvidenceKey" -> evidenceKey,
      "RelationRole" -> roleR[[1]], "RoleConfidence" -> roleR[[2]], "RoleSource" -> "Deterministic",
      "Confidence" -> Lookup[feat, "Confidence", roleR[[2]]],
      "TemporalDistanceDays" -> Lookup[feat, "TemporalDays", Missing[]],
      "CandidateGenerationPass" -> Lookup[feat, "Pass", "Header"],
      "AmbiguityCount" -> Lookup[feat, "AmbiguityCount", 0],
      "SourceSpanRole" -> Lookup[feat, "SourceSpanRole", Missing[]],
      "QuoteLineage" -> Lookup[feat, "QuoteLineage", Missing[]],
      "FeatureScores" -> Lookup[feat, "FeatureScores", <||>],
      "MatchedSpanRefs" -> Lookup[feat, "MatchedSpanRefs", {}],
      "PrivacyLevel" -> Max[plF, plT], "Tags" -> DeleteDuplicates[Join[tagsF, tagsT]]|>];
  addEdge[e_] := AppendTo[edges, e];
  (* --- header edges (From=返信側 citing → To=親 cited) --- *)
  Do[Module[{r = info[k], irt, td},
    irt = r["InReplyTo"];
    If[iSVMSTokenPresentQ[irt] && KeyExistsQ[msgTokenToRef, irt] && msgTokenToRef[irt] =!= k,
      td = iSVMSDaysBetween[info[msgTokenToRef[irt]]["Date"], r["Date"]];
      addEdge[mkEdge[k, msgTokenToRef[irt], "ReplyHeader", "irt:" <> irt,
        <|"Confidence" -> 0.95, "TemporalDays" -> td, "AbsTemporalDays" -> If[NumericQ[td], Abs[td], td],
          "Pass" -> "Header", "SameSubject" -> True, "ParticipantOverlap" -> True,
          "SameMbox" -> True, "QuoteLineage" -> Missing[], "SourceSpanRole" -> Missing[],
          "AmbiguityCount" -> 0|>]]];
    Do[If[iSVMSTokenPresentQ[t] && KeyExistsQ[msgTokenToRef, t] && msgTokenToRef[t] =!= k,
      With[{td2 = iSVMSDaysBetween[info[msgTokenToRef[t]]["Date"], r["Date"]]},
        addEdge[mkEdge[k, msgTokenToRef[t], "ReferenceHeader", "ref:" <> t,
         <|"Confidence" -> 0.8, "TemporalDays" -> td2, "AbsTemporalDays" -> If[NumericQ[td2], Abs[td2], td2],
           "Pass" -> "Header", "SameSubject" -> True, "ParticipantOverlap" -> True, "SameMbox" -> True,
           "QuoteLineage" -> Missing[], "SourceSpanRole" -> Missing[], "AmbiguityCount" -> 0|>]]]],
      {t, If[ListQ[r["Refs"]], r["Refs"], {}]}]], {k, byRef}];
  (* --- quote edges (LocalCandidatePass ∪ GlobalQuoteIndexPass) --- *)
  If[quotePass =!= "IndexBuildOnly",
   querySpans = Select[qindex["Spans"], MemberQ[{"QuoteQuery", "ForwardedBlock"}, #["SpanRole"]] &];
   querySpans = Flatten[Take[#, UpTo[maxBlocks]] & /@ Values[GroupBy[querySpans, #["MailRef"] &]], 1];
   Do[Module[{q = qs, cand, cnt, byMail, ranked, fromRef = qs["MailRef"]},
     (* 候補生成: line-hash ∪ shingle 索引。共有 hash 数で prefilter (budget=200 span) *)
     cnt = Counts@Flatten[{Lookup[qindex["LineHashIndex"], q["LineHashes"], {}],
        Lookup[qindex["ShingleIndex"], q["Shingles"], {}]}];
     cnt = KeyDrop[cnt, q["SpanRef"]];
     cand = Take[Keys[ReverseSort[cnt]], UpTo[200]];
     (* source span 候補: 別メール *)
     cand = Select[spanByRef /@ cand, AssociationQ[#] && #["MailRef"] =!= fromRef &];
     byMail = GroupBy[cand, #["MailRef"] &];
     ranked = KeyValueMap[Function[{toRef, sspans}, Module[{best, sc, td},
        best = MaximalBy[sspans, Length[Intersection[q["LineHashes"], #["LineHashes"]]] &, 1][[1]];
        sc = iSVMSSpanScore[q, best];
        td = iSVMSDaysBetween[info[toRef]["Date"], info[fromRef]["Date"]];  (* to(source) → from(citing) *)
        <|"ToRef" -> toRef, "Best" -> best, "Score" -> sc, "TemporalDays" -> td|>]], byMail];
     (* 閾値: exact(lineJaccard) or fuzzy(shingle)。source が query より後(td<0)は除外(未来引用) *)
     ranked = Select[ranked, (#["Score"]["LineJaccard"] >= minExact || #["Score"]["ShingleJaccard"] >= minFuzzy) &&
        (MissingQ[#["TemporalDays"]] || #["TemporalDays"] >= 0) &];
     ranked = Take[ReverseSortBy[ranked, #["Score"]["LineJaccard"] + #["Score"]["ShingleJaccard"] &], UpTo[maxGlob]];
     With[{amb = Length[ranked]},
      Do[Module[{toRef = rk["ToRef"], sc = rk["Score"], td = rk["TemporalDays"], srole, kind, lineage, pass, absTd,
          sameSubj, pOv, sameMbox},
        srole = rk["Best"]["SpanRole"];
        kind = If[sc["LineJaccard"] >= minExact, "QuoteExact", "QuoteFuzzy"];
        lineage = If[srole === "QuoteQuery" || q["SpanRole"] === "ForwardedBlock", "ReQuote", "Direct"];
        absTd = If[NumericQ[td], Abs[td], td];
        sameSubj = info[fromRef]["Subject"] === info[toRef]["Subject"] && info[fromRef]["Subject"] =!= "";
        pOv = Intersection[info[fromRef]["Addrs"], info[toRef]["Addrs"]] =!= {};
        sameMbox = info[fromRef]["MBox"] === info[toRef]["MBox"];
        pass = If[(info[fromRef]["Subject"] === info[toRef]["Subject"] && info[fromRef]["Subject"] =!= "") ||
           (NumericQ[absTd] && absTd <= localWin), "Local", "GlobalQuoteIndex"];
        If[! (quotePass === "LocalOnly" && pass === "GlobalQuoteIndex"),
          addEdge[mkEdge[fromRef, toRef, kind, "q:" <> q["SpanRef"] <> "|s:" <> rk["Best"]["SpanRef"],
            <|"Confidence" -> Round[0.5 + 0.4*sc["LineJaccard"] + 0.1*sc["ShingleJaccard"], 0.01],
              "TemporalDays" -> td, "AbsTemporalDays" -> absTd, "Pass" -> pass,
              "SameSubject" -> sameSubj, "ParticipantOverlap" -> pOv, "SameMbox" -> sameMbox,
              "QuoteLineage" -> lineage, "SourceSpanRole" -> srole, "AmbiguityCount" -> amb,
              "FeatureScores" -> <|"TextOverlap" -> sc["ShingleJaccard"], "LineJaccard" -> sc["LineJaccard"],
                 "SharedLines" -> sc["SharedLines"], "QuoteDepth" -> 1|>,
              "MatchedSpanRefs" -> {q["SpanRef"], rk["Best"]["SpanRef"]}|>]]]], {rk, ranked}]]],
     {qs, querySpans}]];
  (* --- subject fallback (厳格。同一 subject 単独では連結しない) --- *)
  Module[{groups, linkedPairs},
    (* header/quote edge が既に張られた pair には SubjectFallback を重ねない *)
    linkedPairs = DeleteDuplicates[Sort[{#["FromMailRef"], #["ToMailRef"]}] & /@ edges];
    groups = GroupBy[Select[byRef, ! MemberQ[stop, info[#]["Subject"]] && info[#]["Subject"] =!= "" &],
       info[#]["Subject"] &];
    Do[With[{members = grp}, If[Length[members] >= 2,
       Do[Module[{a = members[[i]], b = members[[j]], td, pOv, sameMbox},
          td = iSVMSDaysBetween[info[a]["Date"], info[b]["Date"]];
          pOv = Intersection[info[a]["Addrs"], info[b]["Addrs"]] =!= {};
          sameMbox = info[a]["MBox"] === info[b]["MBox"];
          (* date window ∩ participant overlap を必須。既 linked pair は skip *)
          If[pOv && (NumericQ[td] && Abs[td] <= 14) && ! MemberQ[linkedPairs, Sort[{a, b}]],
            addEdge[mkEdge[b, a, "SubjectFallback", "subj:" <> info[a]["Subject"] <> "|" <>
               ToString[Quotient[If[NumericQ[td], Round[td], 0], 7]],
              <|"Confidence" -> 0.5, "TemporalDays" -> td, "AbsTemporalDays" -> Abs[td], "Pass" -> "Local",
                "SameSubject" -> True, "ParticipantOverlap" -> pOv, "SameMbox" -> sameMbox,
                "QuoteLineage" -> Missing[], "SourceSpanRole" -> Missing[], "AmbiguityCount" -> 0|>]]]],
         {i, Length[members]}, {j, i + 1, Length[members]}]]], {grp, Values[groups]}]];
  graphId = "svmailrel:" <> iSVMSShortHash[{profileDigest, Sort[nodes]}];
  (* 同一 (From,To,EdgeKind) の並行 edge を集約: 長いメールを多数の span で引用すると
     span ペアごとに edge が出て膨張するため、最良 confidence を代表に SpanPairCount を記録 *)
  edges = Values@GroupBy[DeleteDuplicatesBy[edges, #["EdgeId"] &],
     {#["FromMailRef"], #["ToMailRef"], #["EdgeKind"]} &,
     Function[grp, Append[MaximalBy[grp, #["Confidence"] &, 1][[1]],
        <|"SpanPairCount" -> Length[grp],
          "MatchedSpanRefs" -> Take[DeleteDuplicates[Flatten[#["MatchedSpanRefs"] & /@ grp]], UpTo[20]]|>]]];
  <|"ObjectClass" -> "SourceVaultMailRelationGraph", "GraphId" -> graphId,
    "BuildId" -> graphId, "ProfileDigest" -> profileDigest, "PrivacyScope" -> scope,
    "QuotePass" -> quotePass, "Nodes" -> nodes, "Edges" -> edges,
    "QuoteIndexBuildId" -> qindex["BuildId"]|>];

Options[SourceVaultMineMailSessions] = {"MaxAmbiguityForMerge" -> 2, "MergeConfidenceMin" -> 0.5};
SourceVaultMineMailSessions[graph_Association, OptionsPattern[]] := Module[
  {maxAmb = OptionValue["MaxAmbiguityForMerge"], confMin = OptionValue["MergeConfidenceMin"],
   edges = Lookup[graph, "Edges", {}], nodes = Lookup[graph, "Nodes", {}],
   strong, g, comps, sessOf, crossRoles = {"EvidenceCitation", "AnnualEventReuse", "TemplateReuse", "ForwardedContext"}},
  (* 強 edge = ThreadContinuation かつ低 ambiguity・高 confidence・merge 可能な種別 *)
  strong = Select[edges, Function[e,
     e["RelationRole"] === "ThreadContinuation" && Lookup[e, "AmbiguityCount", 0] <= maxAmb &&
     Lookup[e, "Confidence", 0] >= confMin &&
     (MemberQ[{"ReplyHeader", "ReferenceHeader"}, e["EdgeKind"]] ||
       (e["EdgeKind"] === "QuoteExact" && Lookup[e, "QuoteLineage", ""] === "Direct") ||
       e["EdgeKind"] === "SubjectFallback")]];
  g = Graph[nodes, UndirectedEdge @@@ ({#["FromMailRef"], #["ToMailRef"]} & /@ strong)];
  comps = ConnectedComponents[g];
  sessOf = Association@Flatten[MapIndexed[Function[{comp, i},
     (# -> i[[1]]) & /@ comp], comps]];
  MapIndexed[Function[{comp, i}, Module[{sid, crefs},
    sid = "svmailsess:" <> iSVMSShortHash[{graph["GraphId"], Sort[comp]}];
    (* cross-session reference = この session の mail が絡む historical reference edge (merge されなかった) *)
    crefs = DeleteDuplicatesBy[
       Select[edges, (MemberQ[comp, #["FromMailRef"]] || MemberQ[comp, #["ToMailRef"]]) &&
          MemberQ[crossRoles, #["RelationRole"]] &],
       {#["FromMailRef"], #["ToMailRef"], #["RelationRole"]} &];
    <|"MailSessionId" -> sid, "MailRefs" -> Sort[comp], "MailCount" -> Length[comp],
      "SessionGraphRef" -> graph["GraphId"],
      "CrossSessionReferences" -> (<|"EdgeId" -> #["EdgeId"], "From" -> #["FromMailRef"],
          "To" -> #["ToMailRef"], "Role" -> #["RelationRole"],
          "ToSession" -> Lookup[sessOf, #["ToMailRef"], Missing[]]|> & /@ crefs)|>]],
   comps]];

(* ================= Inc 4: 段落 topic 付与 + topic graph + 統合 ================= *)

(* 1 メールの段落 topic 付与 → <|MailRef, Assignments, TopicRefs|> *)
iSVMSAssignRecord[record_Association, vocab_Association, maxN_Integer] := Module[
  {mref = Lookup[record, "MailRef", Missing[]], body = Lookup[record, "Body", ""], paras, asg, refs},
  If[! StringQ[body], Return[<|"MailRef" -> mref, "Assignments" -> {}, "TopicRefs" -> {}|>]];
  paras = SourceVaultParseMailParagraphs[body];
  asg = SourceVaultAssignParagraphTopics[paras, Lookup[vocab, "SurfaceIndex", <||>],
     "RelationGraph" -> Lookup[vocab, "SeedRelationGraph", None], "RefLabel" -> Lookup[vocab, "RefLabel", None]];
  (* vocab match (SeedMatched) と明示 (ExplicitOOPS) の topic ref を distinct 抽出 *)
  refs = Take[DeleteDuplicates[#["TopicItemRef"] & /@ Select[
     Flatten[Lookup[#, "Assignments", {}] & /@ asg],
     MemberQ[{"SeedMatched", "ExplicitOOPS"}, Lookup[#, "AssignmentKind", ""]] &]], UpTo[maxN]];
  <|"MailRef" -> mref, "Assignments" -> asg, "TopicRefs" -> refs|>];

Options[SourceVaultBuildMailTopicGraph] = {"MaxTopicsPerMail" -> 8, "BoundedBoostCap" -> 0.3};
SourceVaultBuildMailTopicGraph[relationGraph_Association, topicsByMail_Association,
   vocab_Association, OptionsPattern[]] := Module[
  {cap = OptionValue["BoundedBoostCap"], trans = <||>, topicPriv, addT, kindOf},
  topicPriv = Association[(#["TopicItemRef"] -> Lookup[#, "SupportPrivacyMax", 0.]) & /@
     Lookup[Lookup[vocab, "Dictionary", <||>], "Entries", {}]];
  (* key は String (List キーは Lookup が複数キー照会と誤解するため) *)
  addT[a_, b_, kind_, w_, ev_] := With[{key = a <> "\[RightArrow]" <> b <> "\[RightArrow]" <> kind},
    trans[key] = With[{prev = Lookup[trans, key,
        <|"From" -> a, "To" -> b, "Kind" -> kind, "Weight" -> 0., "EvidenceRefs" -> {}, "PrivacyMax" -> 0.|>]},
      <|"From" -> a, "To" -> b, "Kind" -> kind, "Weight" -> prev["Weight"] + w,
        "EvidenceRefs" -> Take[DeleteDuplicates[Append[prev["EvidenceRefs"], ev]], UpTo[10]],
        "PrivacyMax" -> Max[prev["PrivacyMax"], Lookup[topicPriv, a, 0.], Lookup[topicPriv, b, 0.]]|>]];
  kindOf = Function[role, Switch[role,
     "ThreadContinuation", "QuoteTransition",
     "EvidenceCitation", "HistoricalReferenceTransition",
     "AnnualEventReuse", "HistoricalReferenceTransition",
     "TemplateReuse", "TemplateReuseTransition", _, Null]];
  (* relation-driven topic transition (bounded boost = Min[confidence, cap]) *)
  Do[With[{kind = kindOf[Lookup[e, "RelationRole", ""]],
      tf = Lookup[topicsByMail, e["FromMailRef"], {}], tt = Lookup[topicsByMail, e["ToMailRef"], {}]},
     If[kind =!= Null,
       Do[Do[If[a =!= b, addT[a, b, kind, Min[Lookup[e, "Confidence", 0.], cap], e["EdgeId"]]],
          {b, tt}], {a, tf}]]], {e, Lookup[relationGraph, "Edges", {}]}];
  (* CoParagraph: 同一メールの topic 共起 *)
  Do[With[{ts = topicsByMail[k]},
     Do[Do[If[i < j, addT[ts[[i]], ts[[j]], "CoParagraph", 0.1, "mail:" <> ToString[k]]],
        {j, Length[ts]}], {i, Length[ts]}]], {k, Keys[topicsByMail]}];
  GroupBy[(Append[#, "Weight" -> Round[#["Weight"], 0.01]] & /@ Values[trans]), #["From"] &]];

Options[SourceVaultStructureMail] = {"Seed" -> None, "Grow" -> True, "PassB" -> True,
  "QuotePass" -> "Full", "PrivacyScope" -> Automatic, "OwnerRef" -> None, "MaxTopicsPerMail" -> 8};
SourceVaultStructureMail[mails_List, OptionsPattern[]] := Module[
  {seed = OptionValue["Seed"], grow = TrueQ[OptionValue["Grow"]], passB = TrueQ[OptionValue["PassB"]],
   quotePass = OptionValue["QuotePass"], scope = OptionValue["PrivacyScope"],
   owner = OptionValue["OwnerRef"], maxTopics = OptionValue["MaxTopicsPerMail"],
   vocab0, vocabA, graph, sessions, sessionMap, vocabB, paraTopics, topicsByMail, topicGraph, vocabFinal, report},
  (* pass A 語彙 (mail-level) *)
  vocab0 = If[AssociationQ[seed],
     SourceVaultTopicVocabularyFromSeed[seed, "PrivacyScope" -> scope],
     SourceVaultNewTopicVocabulary["OwnerRef" -> owner, "PrivacyScope" -> scope]];
  vocabA = If[grow,
     SourceVaultGrowTopicVocabulary[vocab0, mails, "OwnerRef" -> owner, "PrivacyScope" -> scope], vocab0];
  (* relation graph + sessions *)
  graph = SourceVaultBuildMailRelationGraph[mails, "QuotePass" -> quotePass, "PrivacyScope" -> scope];
  sessions = SourceVaultMineMailSessions[graph];
  sessionMap = Association@Flatten[
     Function[s, (# -> s["MailSessionId"]) & /@ s["MailRefs"]] /@ sessions];
  (* pass B: session-aware 語彙 refine (循環依存を断つ 2-pass, §4.3) *)
  vocabB = If[passB && grow,
     SourceVaultGrowTopicVocabulary[vocabA, mails, "OwnerRef" -> owner, "PrivacyScope" -> scope,
        "Sessions" -> sessionMap, "GroupingKind" -> "Session"], vocabA];
  (* 段落 topic 付与 *)
  paraTopics = Association[(#["MailRef"] -> #) & /@ (iSVMSAssignRecord[#, vocabB, maxTopics] & /@ mails)];
  topicsByMail = #["TopicRefs"] & /@ paraTopics;
  (* topic graph (ObservedRelationGraph) *)
  topicGraph = SourceVaultBuildMailTopicGraph[graph, topicsByMail, vocabB, "MaxTopicsPerMail" -> maxTopics];
  vocabFinal = Append[vocabB, "ObservedRelationGraph" -> topicGraph];
  report = <|"MailCount" -> Length[mails],
     "VocabSize" -> Length[Lookup[Lookup[vocabB, "Dictionary", <||>], "Entries", {}]],
     "RelationEdges" -> Length[Lookup[graph, "Edges", {}]],
     "SessionCount" -> Length[sessions],
     "TopicGraphEdges" -> Total[Length /@ Values[topicGraph]],
     "AssignedMails" -> Count[Values[topicsByMail], t_ /; t =!= {}]|>;
  <|"Vocabulary" -> vocabFinal, "RelationGraph" -> graph, "Sessions" -> sessions,
    "TopicGraph" -> topicGraph, "ParagraphTopics" -> paraTopics, "Records" -> mails,
    "Report" -> report|>];

(* ================= Inc 5: 検索 / primer 接続 ================= *)

(* session mail 群の代表 subject (Re/Fwd 剥がし前の生 subject の最頻) *)
iSVMSSessionSubject[sm_List] := With[
  {subs = Select[Lookup[#, "Subject", ""] & /@ sm, StringQ[#] && StringTrim[#] =!= "" &]},
  If[subs === {}, "(件名なし)", First[Commonest[subs]]]];

Options[SourceVaultMailStructSessionChunks] = {"MaxBodyChars" -> 4000, "ReleaseState" -> "Published"};
SourceVaultMailStructSessionChunks[st_Association, OptionsPattern[]] := Module[
  {records = Lookup[st, "Records", {}], vocab = Lookup[st, "Vocabulary", <||>],
   maxBody = OptionValue["MaxBodyChars"], state = OptionValue["ReleaseState"],
   recByRef, sidx, refLabel, relGraph},
  recByRef = Association[(#["MailRef"] -> #) & /@ records];
  sidx = Lookup[vocab, "SurfaceIndex", <||>];
  refLabel = Lookup[vocab, "RefLabel", <||>];
  relGraph = Lookup[vocab, "SeedRelationGraph", <||>];
  DeleteCases[Map[Function[sess, Module[
     {sm, subject, combined, authors, priv, tags, topicsText},
     sm = DeleteMissing[Lookup[recByRef, Lookup[sess, "MailRefs", {}]]];
     If[sm === {}, Nothing,
       subject = iSVMSSessionSubject[sm];
       combined = StringTake[StringRiffle[
          Select[Lookup[#, "Body", ""] & /@ sm, StringQ], "\n\n"], UpTo[maxBody]];
       authors = DeleteDuplicates[Lookup[#, "From", ""] & /@ sm];
       (* privacy は record の PrivacyLevel/Tags を継承 (Inc2 adapter。OOPS list privacy は使わない) *)
       priv = Max[Append[iSVMSPrivacyLevel /@ sm, 0.]];
       tags = DeleteDuplicates@Flatten[Lookup[#, "Tags", {}] & /@ sm];
       topicsText = If[AssociationQ[sidx] && sidx =!= <||>,
          SourceVaultTopicEnrichment[combined, sidx, "RefLabel" -> refLabel,
             "RelationGraph" -> relGraph, "IncludeRelated" -> True]["TopicsFieldText"], ""];
       <|"ChunkId" -> sess["MailSessionId"], "SourceVaultObjectId" -> sess["MailSessionId"],
         "SearchFields" -> <|"title" -> subject, "body" -> combined, "author" -> authors, "topics" -> topicsText|>,
         "Text" -> combined, "NormalizedText" -> SourceVaultNormalizeSearchText[combined],
         "PrivacyLevel" -> priv, "State" -> state, "Tags" -> tags,
         "MailRefs" -> sess["MailRefs"], "MailCount" -> sess["MailCount"],
         "SourceRef" -> <|"Title" -> subject|>|>]]], Lookup[st, "Sessions", {}]], Nothing]];

Options[SourceVaultMailStructBuildSearchIndex] = {"ReleaseContext" -> "mailstruct-local",
  "IndexId" -> Automatic, "IndexKind" -> "KeywordBM25V1"};
SourceVaultMailStructBuildSearchIndex[st_Association, OptionsPattern[]] := Module[
  {chunks, ctx = OptionValue["ReleaseContext"], idx = OptionValue["IndexId"],
   kind = OptionValue["IndexKind"], res},
  SourceVaultMailStructEnsureReleaseContexts[];
  chunks = SourceVaultMailStructSessionChunks[st];
  idx = idx /. Automatic -> ("mailstruct-bm25-" <> iSVMSShortHash[{ctx, Length[chunks],
     Lookup[Lookup[st, "Vocabulary", <||>], "VocabularyBuildId", ""]}]);
  res = SourceVaultBuildProjectionIndex[ctx, "Chunks" -> chunks, "IndexKind" -> kind,
     "EntityDictionary" -> Lookup[Lookup[st, "Vocabulary", <||>], "Dictionary", <||>],
     "IndexId" -> idx, "Overwrite" -> True];
  If[! FailureQ[res] && Lookup[res, "Status", ""] =!= "Failed",
     Quiet@SourceVaultLoadSearchIndex[idx]];
  <|"IndexId" -> idx, "Context" -> ctx, "ChunkCount" -> Lookup[res, "ChunkCount", Length[chunks]],
    "ExcludedCount" -> Lookup[res, "ExcludedCount", 0], "BuildResult" -> res|>];

Options[SourceVaultMailStructSearch] = {"ReleaseContext" -> Automatic, "Limit" -> 10};
SourceVaultMailStructSearch[query_String, indexInfo_, OptionsPattern[]] := Module[
  {idx, ctx = OptionValue["ReleaseContext"], lim = OptionValue["Limit"]},
  idx = If[AssociationQ[indexInfo], Lookup[indexInfo, "IndexId", indexInfo], indexInfo];
  If[ctx === Automatic, ctx = If[AssociationQ[indexInfo], Lookup[indexInfo, "Context", "mailstruct-local"], "mailstruct-local"]];
  SourceVaultSearch[query, "ReleaseContext" -> ctx, "Index" -> idx, "Limit" -> lim]];

(* 1 メールの先頭 prose 抜粋 *)
iSVMSFirstProse[record_Association, chars_Integer] := Module[
  {body = Lookup[record, "Body", ""], ps},
  If[! StringQ[body], Return[""]];
  ps = Select[SourceVaultParseMailParagraphs[body], #["Kind"] === "Prose" &];
  If[ps === {}, "", StringTake[StringReplace[ps[[1]]["Text"], {"\n" -> " ", "\r" -> ""}], UpTo[chars]]]];

Options[SourceVaultMailStructSessionDigest] = {"ParaChars" -> 120, "MaxMails" -> 8};
SourceVaultMailStructSessionDigest[session_Association, st_Association, OptionsPattern[]] := Module[
  {records = Lookup[st, "Records", {}], vocab = Lookup[st, "Vocabulary", <||>],
   paraChars = OptionValue["ParaChars"], maxMails = OptionValue["MaxMails"],
   recByRef, sm, subject, topicLabels, timeline, historical},
  recByRef = Association[(#["MailRef"] -> #) & /@ records];
  sm = DeleteMissing[Lookup[recByRef, Lookup[session, "MailRefs", {}]]];
  subject = iSVMSSessionSubject[sm];
  topicLabels = If[AssociationQ[Lookup[vocab, "SurfaceIndex", <||>]],
     SourceVaultTopicEnrichment[
        StringRiffle[Select[Lookup[#, "Body", ""] & /@ sm, StringQ], " "],
        vocab["SurfaceIndex"], "RefLabel" -> Lookup[vocab, "RefLabel", <||>],
        "IncludeRelated" -> False]["TopicLabels"], {}];
  (* current: ThreadContinuation で結ばれた本 session の timeline *)
  timeline = Map[Function[m,
     StringReplace[Lookup[m, "From", ""], RegularExpression["\\s*<[^>]*>"] -> ""] <> ": " <>
        iSVMSFirstProse[m, paraChars]], Take[sm, UpTo[maxMails]]];
  (* historical: CrossSessionReferences (過去メール参照) を分離 *)
  historical = Map[Function[cr, With[{toRec = Lookup[recByRef, cr["To"], Missing[]]},
     <|"Role" -> cr["Role"], "ToMailRef" -> cr["To"],
       "Subject" -> If[AssociationQ[toRec], Lookup[toRec, "Subject", ""], ""],
       "Excerpt" -> If[AssociationQ[toRec], iSVMSFirstProse[toRec, paraChars], ""],
       "ToSession" -> Lookup[cr, "ToSession", Missing[]]|>]],
     Lookup[session, "CrossSessionReferences", {}]];
  <|"SessionId" -> Lookup[session, "MailSessionId", Missing[]], "Subject" -> subject,
    "MailCount" -> Lookup[session, "MailCount", Length[sm]], "Topics" -> topicLabels,
    "CurrentDigest" -> StringRiffle[Join[
       {"[スレッド] " <> subject <> " (" <> ToString[Lookup[session, "MailCount", Length[sm]]] <> "通)",
        If[topicLabels === {}, Nothing, "話題: " <> StringRiffle[topicLabels, ", "]]}, timeline], "\n"],
    "HistoricalReferences" -> historical|>];

End[]

EndPackage[]
