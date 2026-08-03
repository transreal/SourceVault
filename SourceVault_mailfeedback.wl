(* :Title: SourceVault_mailfeedback.wl *)
(* :Context: SourceVault` *)
(* :Summary: mail classification feedback -- user corrections of the derived
   fields (Priority / PrivacyLevel / Category / WorkRequest, plus sender
   importance) are recorded in an append-only ledger, applied immediately to
   the corrected mail as a hard per-mail override, and generalised into FUTURE
   classification by a two-layer learner:

     L1  rule layer          deterministic address / recipient / subject-word
                             rules. Instant, fully explainable, authored by the
                             user (scope "Sender" / "Rule") or promoted from L2
                             evidence AFTER explicit confirmation.
     L2  hierarchical Bayes  Dirichlet-multinomial posterior over Category
                             given features (sender / domain / recipient list /
                             subject terms) shrunk toward the parent level
                             (sender -> domain -> global), and Normal-Normal
                             shrunk residuals for the continuous fields
                             (Priority / PrivacyLevel).

   The LLM inference stays the prior. L2 only moves away from it when the
   posterior margin exceeds a gate ($SourceVaultMailFeedbackSwitchMargin), and
   every move it makes is reported in Derived.FeedbackAdjustment, so a wrong
   correction can always be traced and undone.

   Why hierarchical Bayes rather than plain naive Bayes: the correction stream
   is TINY and lopsided (a handful of events, most features seen once). Plain
   naive Bayes over-commits on a single observation and multiplies correlated
   subject tokens; the shrinkage prior (alpha) plus per-family AVERAGING (not
   summing) of log-odds gives graceful behaviour at n=1 and converges to the
   empirical rate as evidence accumulates.

   Layering rule: explicit user override > L1 rules > L2 posterior > LLM prior.
   The deterministic recipient privacy floor of maildb still binds the LEARNED
   privacy value (defense in depth); only an explicit human override may go
   below it, and that fact is written to the ledger.

   Coupling: weak (rule 11). maildb calls this module through the documented
   seam $SourceVaultMailDerivedAdjuster only when it is loaded; nothing here is
   required for maildb to work. Content-minimised: the ledger stores addresses,
   subject-derived terms and numbers -- never the body.
*)

BeginPackage["SourceVault`"];

SourceVaultMailCorrect::usage =
  "SourceVaultMailCorrect[recordId, updates_Association, opts] records a user \
correction of the derived fields of one mail and applies it immediately. \
updates keys: \"Priority\" (0-1), \"PrivacyLevel\" (0-1), \"Category\" (token or \
Japanese label), \"WorkRequest\" (0-1), \"Deadline\" (ISO string or Missing). \
The values are stored as a HARD per-mail override (Derived.UserOverride) that \
survives re-inference and priority recomputation, the snapshot and the sidecar \
index are rewritten so every view updates, and a correction event (features + \
old/new values, no body) is appended to the ledger. \
Options: \"Scope\" -> \"Mail\" (default: this mail only, plus L2 evidence) | \
\"Sender\" (also create an L1 rule keyed on the sender address) | \"Rule\" \
(create an L1 rule from \"Match\") | \"None\" (no learning at all), \
\"Match\" (explicit rule match spec for Scope -> \"Rule\"), \
\"Learn\" -> True (feed the L2 model), \"Reason\" -> \"\" (free text, ledger only), \
\"Persist\" -> True, \"Snapshot\" -> Automatic (test seam), \
\"Reapply\" -> False (True also re-scores the other mails of the same sender). \
Returns <|Status, RecordId, Old, New, Scope, RuleId, Learned|>.";

SourceVaultMailSetSenderWeight::usage =
  "SourceVaultMailSetSenderWeight[recordIdOrEmail, weight, opts] sets the \
importance of a SENDER (0-1, the base term of the structural priority). When the \
identity layer knows the sender it writes PriorityWeight on the entity (the \
canonical place, shared by every mail of that entity); otherwise it falls back \
to an L1 rule on the address so the effect is the same. \
Options: \"Reapply\" -> True re-scores the already stored mails of that sender, \
\"Persist\" -> True. Returns <|Status, Email, Weight, Via, Reapplied|>.";

SourceVaultMailCorrections::usage =
  "SourceVaultMailCorrections[opts] returns the recorded correction events \
(newest first). Options: \"RecordId\", \"Field\", \"Limit\" (default 200).";

SourceVaultMailFeedbackView::usage =
  "SourceVaultMailFeedbackView[opts] is the View version of \
SourceVaultMailCorrections: a Dataset of the correction ledger (date / field / \
old -> new / scope / sender / subject).";

SourceVaultMailAddRule::usage =
  "SourceVaultMailAddRule[spec_Association, opts] registers an L1 rule. \
spec: <|\"Match\" -> <|\"From\", \"Domain\", \"To\", \"Subject\" -> {terms...}, \
\"Category\"|>, \"Action\" -> <|\"SetCategory\", \"SetWorkRequest\", \
\"PriorityAdjust\", \"PriorityMin\", \"PrivacyAdjust\", \"PrivacyMin\"|>, \
\"Note\", \"Enabled\", \"Source\"|>. Every Match key given must hold (AND); \
\"Subject\" requires ALL listed terms. The RuleId is a hash of Match+Action, so \
re-adding the same rule is idempotent. Returns the stored rule.";

SourceVaultMailRules::usage =
  "SourceVaultMailRules[] returns the registered L1 rules (list of associations).";

SourceVaultMailRemoveRule::usage =
  "SourceVaultMailRemoveRule[ruleId] deletes an L1 rule.";

SourceVaultMailSetRuleEnabled::usage =
  "SourceVaultMailSetRuleEnabled[ruleId, True|False] enables/disables an L1 rule \
without deleting it.";

SourceVaultMailRulesView::usage =
  "SourceVaultMailRulesView[] shows the L1 rules as a Dataset with enable/delete \
buttons (front end).";

SourceVaultMailRuleProposals::usage =
  "SourceVaultMailRuleProposals[opts] returns L2 evidence that is strong and \
consistent enough to be promoted to a deterministic L1 rule (>= \
$SourceVaultMailFeedbackPromoteCount corrections on one feature agreeing on one \
category, or a large consistent residual), excluding what an enabled rule \
already covers. Proposals are NEVER auto-applied: \
SourceVaultMailAcceptRuleProposal[proposal] is the confirmation gate.";

SourceVaultMailAcceptRuleProposal::usage =
  "SourceVaultMailAcceptRuleProposal[proposalOrId] promotes a proposal from \
SourceVaultMailRuleProposals to an enabled L1 rule (Source -> \"Promoted\").";

SourceVaultMailFeedbackModel::usage =
  "SourceVaultMailFeedbackModel[] returns the L2 model: per-feature category \
counts and per-feature residual sufficient statistics (N / Sum) for Priority and \
PrivacyLevel, plus the global category counts. Derived data: it can always be \
rebuilt from the ledger with SourceVaultMailFeedbackRebuildModel[].";

SourceVaultMailFeedbackRebuildModel::usage =
  "SourceVaultMailFeedbackRebuildModel[] rebuilds the L2 model from the \
correction ledger (the ledger is the source of truth). Use after editing or \
pruning the ledger, or when the model file is lost.";

SourceVaultMailFeedbackFeatures::usage =
  "SourceVaultMailFeedbackFeatures[recordIdOrRowOrSnapshot] returns the feature \
list used by the learner: <|\"From\" -> {...}, \"Dom\" -> {...}, \"To\" -> {...}, \
\"Subj\" -> {...}|> (addresses lowercased, subject reduced to ASCII words, \
bracketed tags and 2/3-grams of kanji/katakana runs).";

SourceVaultMailFeedbackAdjust::usage =
  "SourceVaultMailFeedbackAdjust[snapshot, derived] applies the feedback layers \
to a derived association and returns the adjusted one, with the audit trail in \
\"FeedbackAdjustment\" (<|RuleIds, CategoryFrom/To, CategoryMargin, \
PriorityAdjust, PrivacyAdjust, Explain|>). This is the function maildb calls \
through $SourceVaultMailDerivedAdjuster; it is pure (no store writes) and never \
touches a field pinned by Derived.UserOverride.";

SourceVaultMailFeedbackExplain::usage =
  "SourceVaultMailFeedbackExplain[recordId] explains how the current values of a \
mail were reached: LLM prior, matched L1 rules, L2 posterior per category, \
residual adjustments and the user override, as an association.";

SourceVaultMailFeedbackReapply::usage =
  "SourceVaultMailFeedbackReapply[opts] re-scores the mails already in the store \
with the CURRENT rules and model (no LLM call): structural priority from the \
stored WorkRequest/Category, then L1 + L2, then the user override. \
Options: \"From\" (only this sender address), \"MBox\", \"RecordIds\", \
\"Persist\" -> True, \"DryRun\" -> False. Returns <|Status, Scanned, Changed|>.";

SourceVaultMailFeedbackPanel::usage =
  "SourceVaultMailFeedbackPanel[recordId] is the correction control shown under \
the reply buttons of the mail window: importance and secrecy steppers, a \
category picker, a sender-importance picker and the learning scope selector \
(this mail / this sender / word rule). Applying calls SourceVaultMailCorrect.";

SourceVaultMailFeedbackWindow::usage =
  "SourceVaultMailFeedbackWindow[recordId] opens the correction panel of one mail \
in its own window (front end), for use from list views.";

SourceVaultMailFeedbackRoot::usage =
  "SourceVaultMailFeedbackRoot[] is the directory holding the correction ledger, \
the L1 rules and the L2 model (<mail store root>/feedback).";

$SourceVaultMailFeedbackEnabled::usage =
  "$SourceVaultMailFeedbackEnabled (default True) switches the L1+L2 layers off \
globally. Explicit per-mail overrides keep working.";
$SourceVaultMailFeedbackAlpha::usage =
  "$SourceVaultMailFeedbackAlpha (default 3.0) is the Dirichlet shrinkage of the \
category posterior toward the parent level. Larger = more conservative.";
$SourceVaultMailFeedbackKappa::usage =
  "$SourceVaultMailFeedbackKappa (default 2.0) is the Normal-Normal shrinkage of \
the Priority/PrivacyLevel residuals toward 0.";
$SourceVaultMailFeedbackSwitchMargin::usage =
  "$SourceVaultMailFeedbackSwitchMargin (default 1.2) is the log-odds margin the \
posterior must beat the LLM category by before L2 overrides it.";
$SourceVaultMailFeedbackMaxAdjust::usage =
  "$SourceVaultMailFeedbackMaxAdjust (default 0.4) caps the absolute value of a \
learned Priority/PrivacyLevel adjustment, so no amount of evidence lets L2 take \
full control away from the structural model.";
$SourceVaultMailFeedbackFamilyWeights::usage =
  "$SourceVaultMailFeedbackFamilyWeights (default <|From->1.0, Dom->0.5, \
To->0.7, Subj->0.4|>) weights the feature families. Within a family the matched \
features are AVERAGED, never summed, so correlated subject n-grams cannot \
dominate.";
$SourceVaultMailFeedbackPromoteCount::usage =
  "$SourceVaultMailFeedbackPromoteCount (default 3) is the number of consistent \
corrections on one feature after which SourceVaultMailRuleProposals offers to \
promote it to a deterministic L1 rule.";
$SourceVaultMailFeedbackLLMPrior::usage =
  "$SourceVaultMailFeedbackLLMPrior (default 1.0) is the log-odds bonus given to \
the category the LLM inferred.";
$SourceVaultMailFeedbackMaxSubjectTerms::usage =
  "$SourceVaultMailFeedbackMaxSubjectTerms (default 32) caps the subject terms \
extracted per mail. The terms are collected round-robin over the kanji/katakana \
runs, most specific first, so the cap trims noise rather than the topic word.";

Begin["`MailFeedbackPrivate`"];

(* ---------------- configuration ---------------- *)

If[! MatchQ[$SourceVaultMailFeedbackEnabled, True | False],
  $SourceVaultMailFeedbackEnabled = True];
If[! NumberQ[$SourceVaultMailFeedbackAlpha], $SourceVaultMailFeedbackAlpha = 3.0];
If[! NumberQ[$SourceVaultMailFeedbackKappa], $SourceVaultMailFeedbackKappa = 2.0];
(* 1.2 is calibrated, not guessed: with alpha = 3 one correction moves only
   mails that match the sender AND the recipient list AND the subject terms
   (margin ~1.8); a second correction on the same sender is what flips that
   sender's unrelated mail (margin ~1.4). Lower it and one click generalises
   too far, raise it and the layer stops being useful. *)
If[! NumberQ[$SourceVaultMailFeedbackSwitchMargin],
  $SourceVaultMailFeedbackSwitchMargin = 1.2];
If[! NumberQ[$SourceVaultMailFeedbackMaxAdjust],
  $SourceVaultMailFeedbackMaxAdjust = 0.4];
If[! AssociationQ[$SourceVaultMailFeedbackFamilyWeights],
  $SourceVaultMailFeedbackFamilyWeights =
    <|"From" -> 1.0, "Dom" -> 0.5, "To" -> 0.7, "Subj" -> 0.4|>];
If[! IntegerQ[$SourceVaultMailFeedbackPromoteCount],
  $SourceVaultMailFeedbackPromoteCount = 3];
If[! NumberQ[$SourceVaultMailFeedbackLLMPrior], $SourceVaultMailFeedbackLLMPrior = 1.0];
If[! IntegerQ[$SourceVaultMailFeedbackMaxSubjectTerms],
  $SourceVaultMailFeedbackMaxSubjectTerms = 32];

$iSVFBFields = {"Priority", "PrivacyLevel", "Category", "WorkRequest", "Deadline"};
$iSVFBNumericFields = {"Priority", "PrivacyLevel", "WorkRequest"};
$iSVFBResidualFields = {"Priority", "PrivacyLevel"};
$iSVFBFamilies = {"From", "Dom", "To", "Subj"};

(* ---------------- small helpers ---------------- *)

iSVFBNum[x_?NumericQ, _] := N[x];
iSVFBNum[_, d_] := d;

iSVFBNow[] := DateString["ISODateTime"];

iSVFBCats[] :=
  With[{c = Quiet@Check[SourceVault`$SourceVaultMailCategories, $Failed]},
    If[ListQ[c] && c =!= {}, c,
      {"InfoProvision", "AttendanceRequest", "TaskRequest", "Confirmation",
       "Report", "Notice", "Other"}]];

(* category token <-> Japanese label. The synonym table mirrors maildb's private
   one so a Japanese value typed by a human (or produced by the UI popup) is
   accepted everywhere. *)
$iSVFBCatLabel = <|
  "InfoProvision" -> "\:60c5\:5831", "AttendanceRequest" -> "\:51fa\:5e2d",
  "TaskRequest" -> "\:4f9d\:983c", "Confirmation" -> "\:78ba\:8a8d", "Report" -> "\:5831\:544a",
  "Notice" -> "\:901a\:77e5", "Other" -> "\:305d\:306e\:4ed6"|>;

$iSVFBCatSynonyms = <|
  "\:60c5\:5831\:63d0\:4f9b" -> "InfoProvision", "\:60c5\:5831" -> "InfoProvision", "\:6848\:5185" -> "InfoProvision",
  "\:51fa\:5e2d\:4f9d\:983c" -> "AttendanceRequest", "\:4f1a\:8b70\:51fa\:5e2d\:4f9d\:983c" -> "AttendanceRequest",
  "\:51fa\:5e2d" -> "AttendanceRequest", "\:65e5\:7a0b\:8abf\:6574" -> "AttendanceRequest",
  "\:4f5c\:696d\:4f9d\:983c" -> "TaskRequest", "\:4ed5\:4e8b\:4f9d\:983c" -> "TaskRequest", "\:4ed5\:4e8b\:306e\:4f9d\:983c" -> "TaskRequest",
  "\:4f5c\:696d\:306e\:4f9d\:983c" -> "TaskRequest", "\:4f9d\:983c" -> "TaskRequest", "\:4f5c\:696d" -> "TaskRequest",
  "\:78ba\:8a8d" -> "Confirmation", "\:627f\:8a8d" -> "Confirmation", "\:78ba\:8a8d\:4f9d\:983c" -> "Confirmation",
  "\:5831\:544a" -> "Report", "\:901a\:77e5" -> "Notice", "\:4e00\:6589\:914d\:4fe1" -> "Notice", "\:5e83\:544a" -> "Notice",
  "\:305d\:306e\:4ed6" -> "Other", "\:4ed6" -> "Other"|>;

iSVFBNormCat[s_String] :=
  Module[{t = StringTrim[s], hit},
    If[t === "", Return[Missing["UnknownCategory"]]];
    hit = SelectFirst[iSVFBCats[], StringMatchQ[t, #, IgnoreCase -> True] &, Missing[]];
    If[StringQ[hit], Return[hit]];
    Lookup[$iSVFBCatSynonyms, t, Missing["UnknownCategory"]]];
iSVFBNormCat[_] := Missing["UnknownCategory"];

iSVFBCatLabel[c_String] := Lookup[$iSVFBCatLabel, c, c];
iSVFBCatLabel[_] := "-";

(* ---------------- storage ---------------- *)

iSVFBStoreRoot[] :=
  Quiet@Check[
    If[Length[DownValues[SourceVault`SourceVaultMailStoreRoot]] > 0,
      SourceVault`SourceVaultMailStoreRoot[], $Failed], $Failed];

SourceVaultMailFeedbackRoot[] :=
  With[{r = iSVFBStoreRoot[]},
    If[StringQ[r], FileNameJoin[{r, "feedback"}],
      FileNameJoin[{$TemporaryDirectory, "sourcevault-mailfeedback"}]]];

iSVFBEnsureDir[] :=
  With[{d = SourceVaultMailFeedbackRoot[]},
    If[! DirectoryQ[d], Quiet@CreateDirectory[d, CreateIntermediateDirectories -> True]];
    d];

iSVFBLedgerPath[] :=
  FileNameJoin[{SourceVaultMailFeedbackRoot[],
     "corrections-" <> DateString[{"Year", "Month"}] <> ".jsonl"}];

iSVFBLedgerFiles[] :=
  With[{d = SourceVaultMailFeedbackRoot[]},
    If[DirectoryQ[d], Sort@FileNames["corrections-*.jsonl", d], {}]];

iSVFBRulesPath[] := FileNameJoin[{SourceVaultMailFeedbackRoot[], "rules.jsonl"}];
iSVFBModelPath[] := FileNameJoin[{SourceVaultMailFeedbackRoot[], "model.json"}];

(* JSON-safe projection: Missing/DateObject/symbols would make RawJSON fail and
   silently lose the whole event, so normalise first (rule: never write a record
   the reader cannot read back). *)
iSVFBJSONSafe[x_Association] := Association[KeyValueMap[ToString[#1] -> iSVFBJSONSafe[#2] &, x]];
iSVFBJSONSafe[x_List] := iSVFBJSONSafe /@ x;
iSVFBJSONSafe[x_String] := x;
iSVFBJSONSafe[x_?NumericQ] := N[x];
iSVFBJSONSafe[True] := True;
iSVFBJSONSafe[False] := False;
iSVFBJSONSafe[Null] := Null;
iSVFBJSONSafe[x_?MissingQ] := Null;
iSVFBJSONSafe[x_] := ToString[x];

(* append one JSONL line. Single encode via ExportByteArray (ExportString would
   double-encode Japanese, see the mcp JSONL fix), stream always closed. *)
iSVFBAppendJSONL[path_String, assoc_Association] :=
  Module[{bytes, dir = DirectoryName[path]},
    If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    bytes = Quiet@Check[
      ExportByteArray[iSVFBJSONSafe[assoc], "RawJSON", "Compact" -> True], $Failed];
    If[! ByteArrayQ[bytes], Return[$Failed]];
    If[Length[DownValues[SourceVault`SourceVaultReleaseFileStreams]] > 0,
      Quiet@SourceVault`SourceVaultReleaseFileStreams[path]];
    Quiet@Check[
      Module[{strm = OpenAppend[path, BinaryFormat -> True]},
        If[Head[strm] =!= OutputStream, $Failed,
          WithCleanup[
            BinaryWrite[strm, bytes];
            BinaryWrite[strm, StringToByteArray["\n", "ASCII"]];
            True,
            Quiet@Close[strm]]]],
      $Failed]];

iSVFBReadJSONL[path_String] :=
  Module[{raw, lines},
    If[! FileExistsQ[path], Return[{}]];
    raw = Quiet@Check[ByteArrayToString[ReadByteArray[path], "UTF-8"], ""];
    If[! StringQ[raw], Return[{}]];
    lines = Select[StringSplit[raw, "\n"], StringTrim[#] =!= "" &];
    Select[
      Quiet@Check[Developer`ReadRawJSONString[StringTrim[#]], Nothing] & /@ lines,
      AssociationQ]];

iSVFBWriteJSONLAll[path_String, rows_List] :=
  Module[{bytes, dir = DirectoryName[path]},
    If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    If[rows === {}, If[FileExistsQ[path], Quiet@DeleteFile[path]]; Return[0]];
    bytes = Quiet@Check[
      ExportByteArray[
        StringRiffle[
          (ByteArrayToString[
             ExportByteArray[iSVFBJSONSafe[#], "RawJSON", "Compact" -> True], "UTF-8"] &) /@ rows,
          "\n"] <> "\n", "Text", CharacterEncoding -> "UTF-8"], $Failed];
    If[! ByteArrayQ[bytes], Return[$Failed]];
    If[Length[DownValues[SourceVault`SourceVaultReleaseFileStreams]] > 0,
      Quiet@SourceVault`SourceVaultReleaseFileStreams[path]];
    Quiet@Check[
      Module[{strm = OpenWrite[path, BinaryFormat -> True]},
        If[Head[strm] =!= OutputStream, $Failed,
          WithCleanup[BinaryWrite[strm, bytes]; Length[rows], Quiet@Close[strm]]]],
      $Failed]];

iSVFBWriteJSON[path_String, assoc_Association] :=
  Module[{bytes, dir = DirectoryName[path]},
    If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    bytes = Quiet@Check[ExportByteArray[iSVFBJSONSafe[assoc], "RawJSON"], $Failed];
    If[! ByteArrayQ[bytes], Return[$Failed]];
    If[Length[DownValues[SourceVault`SourceVaultReleaseFileStreams]] > 0,
      Quiet@SourceVault`SourceVaultReleaseFileStreams[path]];
    Quiet@Check[
      Module[{strm = OpenWrite[path, BinaryFormat -> True]},
        If[Head[strm] =!= OutputStream, $Failed,
          WithCleanup[BinaryWrite[strm, bytes]; True, Quiet@Close[strm]]]],
      $Failed]];

iSVFBReadJSON[path_String] :=
  If[! FileExistsQ[path], <||>,
    With[{j = Quiet@Check[
        Developer`ReadRawJSONString[ByteArrayToString[ReadByteArray[path], "UTF-8"]], $Failed]},
      If[AssociationQ[j], j, <||>]]];

(* ---------------- feature extraction ---------------- *)

iSVFBParseEmails[s_] :=
  If[! StringQ[s], {},
    ToLowerCase /@ Quiet@Check[
      If[Length[DownValues[SourceVault`SourceVaultMailParseEmails]] > 0,
        SourceVault`SourceVaultMailParseEmails[s],
        StringCases[s, RegularExpression["[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+"]]],
      {}]];

iSVFBDomain[email_String] :=
  With[{p = StringSplit[email, "@"]}, If[Length[p] >= 2, ToLowerCase@Last[p], ""]];

(* kanji / katakana / iteration mark: the tokens that carry topic meaning in a
   Japanese subject line. Hiragana is left out on purpose (particles). *)
iSVFBJPCharQ[c_String] :=
  With[{n = Quiet@Check[First[ToCharacterCode[c, "Unicode"]], 0]},
    (19968 <= n <= 40959) || (12448 <= n <= 12543) || n === 12293 || (65382 <= n <= 65439)];

iSVFBJPRuns[s_String] :=
  Module[{chs = Characters[s], groups},
    groups = Split[chs, iSVFBJPCharQ[#1] === iSVFBJPCharQ[#2] &];
    StringJoin /@ Select[groups, iSVFBJPCharQ[First[#]] && Length[#] >= 2 &]];

(* most specific first: the whole run, then 3-grams, then 2-grams. The order
   matters because the term list is capped. *)
iSVFBGrams[run_String] :=
  Module[{L = StringLength[run], out = {}},
    If[L <= 6, out = {run}];
    If[L >= 3, out = Join[out, StringTake[run, {#, # + 2}] & /@ Range[L - 2]]];
    If[L >= 2, out = Join[out, StringTake[run, {#, # + 1}] & /@ Range[L - 1]]];
    DeleteDuplicates[out]];

(* round robin over the runs, so one long leading run (a bracketed office
   boilerplate, say) cannot eat the whole budget and push the words that
   actually identify the topic past the cap *)
iSVFBInterleave[lists_List] :=
  Module[{n = Max[Append[Length /@ lists, 0]]},
    If[n === 0, {},
      DeleteDuplicates@Flatten@
        Table[(If[Length[#] >= i, #[[i]], Nothing] &) /@ lists, {i, n}]]];

iSVFBSubjectTerms[subj_] :=
  Module[{s, brackets, ascii, jp},
    If[! StringQ[subj] || StringTrim[subj] === "", Return[{}]];
    s = StringReplace[subj,
      {RegularExpression["(?i)^\\s*(re|fwd|fw)\\s*:\\s*"] -> " ",
       RegularExpression["(?i)\\s(re|fwd|fw)\\s*:\\s*"] -> " "}];
    brackets = StringTrim /@ Flatten[{
       StringCases[s, "\:3010" ~~ x : Except["\:3011"] .. ~~ "\:3011" :> x],
       StringCases[s, "[" ~~ x : Except["]"] .. ~~ "]" :> x]}];
    brackets = Select[brackets, StringLength[#] >= 2 && StringLength[#] <= 12 &];
    ascii = DeleteDuplicates@Select[
       StringCases[ToLowerCase[s], RegularExpression["[a-z][a-z0-9_-]{2,}"]],
       StringLength[#] >= 3 &];
    jp = iSVFBInterleave[iSVFBGrams /@ iSVFBJPRuns[s]];
    Take[DeleteDuplicates[Join[brackets, ascii, jp]],
      UpTo[$SourceVaultMailFeedbackMaxSubjectTerms]]];

(* one mail -> the flat facts the rules and the learner see. Accepts a snapshot,
   a sidecar index row, or a RecordId (resolved through the store, then the
   index, without decrypting anything). *)
iSVFBFacts[a_Association] :=
  If[KeyExistsQ[a, "MailMetadataPublic"],
    Module[{md = Lookup[a, "MailMetadataPublic", <||>]},
      <|"RecordId" -> ToString@Lookup[a, "RecordId", ""],
        "MBox" -> ToString@Lookup[Lookup[a, "MailSource", <||>], "MBox", ""],
        "From" -> ToString@Lookup[md, "From", ""],
        "To" -> ToString@Lookup[md, "To", ""],
        "Cc" -> ToString@Lookup[md, "Cc", ""],
        "Subject" -> ToString@Lookup[md, "Subject", ""],
        "Date" -> ToString@Lookup[md, "Date", ""]|>],
    <|"RecordId" -> ToString@Lookup[a, "RecordId", ""],
      "MBox" -> ToString@Lookup[a, "MBox", ""],
      "From" -> ToString@Lookup[a, "FromRaw", Lookup[a, "From", ""]],
      "To" -> ToString@Lookup[a, "ToRaw", Lookup[a, "To", ""]],
      "Cc" -> ToString@Lookup[a, "Cc", ""],
      "Subject" -> ToString@Lookup[a, "Subject", ""],
      "Date" -> ToString@Lookup[a, "Date", ""]|>];

iSVFBFacts[rid_String] :=
  Module[{snap, row},
    snap = Quiet@Check[SourceVault`SourceVaultMailSnapshotGet[rid], Missing[]];
    If[AssociationQ[snap], Return[iSVFBFacts[snap]]];
    row = Quiet@Check[SourceVault`SourceVaultMailIndexGet[rid], Missing[]];
    If[AssociationQ[row], Return[iSVFBFacts[row]]];
    <|"RecordId" -> rid, "MBox" -> "", "From" -> "", "To" -> "", "Cc" -> "",
      "Subject" -> "", "Date" -> ""|>];
iSVFBFacts[_] := <|"RecordId" -> "", "MBox" -> "", "From" -> "", "To" -> "",
   "Cc" -> "", "Subject" -> "", "Date" -> ""|>;

iSVFBFeatureSets[facts_Association] :=
  Module[{fromE, toE},
    fromE = iSVFBParseEmails[Lookup[facts, "From", ""]];
    toE = DeleteDuplicates@Join[
       iSVFBParseEmails[Lookup[facts, "To", ""]],
       iSVFBParseEmails[Lookup[facts, "Cc", ""]]];
    <|"From" -> Take[fromE, UpTo[2]],
      "Dom" -> DeleteDuplicates@Select[iSVFBDomain /@ Take[fromE, UpTo[2]], # =!= "" &],
      "To" -> Take[toE, UpTo[8]],
      "Subj" -> iSVFBSubjectTerms[Lookup[facts, "Subject", ""]]|>];

SourceVaultMailFeedbackFeatures[x_] := iSVFBFeatureSets[iSVFBFacts[x]];

iSVFBKey[family_String, f_String] := family <> ":" <> f;

iSVFBAllKeys[sets_Association] :=
  Flatten[(Function[fam, iSVFBKey[fam, #] & /@ Lookup[sets, fam, {}]]) /@ $iSVFBFamilies];

(* ---------------- L1: rule layer ---------------- *)

If[! ValueQ[$iSVFBRules], $iSVFBRules = {}];
If[! ValueQ[$iSVFBRulesLoaded], $iSVFBRulesLoaded = False];
If[! ValueQ[$iSVFBRulesRoot], $iSVFBRulesRoot = ""];

iSVFBRulesLoad[] :=
  ($iSVFBRules = Select[iSVFBReadJSONL[iSVFBRulesPath[]], AssociationQ];
   $iSVFBRulesLoaded = True;
   $iSVFBRulesRoot = SourceVaultMailFeedbackRoot[];
   $iSVFBRules);

(* reload when the mail store root moved under us (vault switch, test seam):
   in-memory rules belong to one store, never to the kernel *)
iSVFBRulesEnsure[] :=
  If[! TrueQ[$iSVFBRulesLoaded] || $iSVFBRulesRoot =!= SourceVaultMailFeedbackRoot[],
    iSVFBRulesLoad[]];
iSVFBRulesSave[] := iSVFBWriteJSONLAll[iSVFBRulesPath[], $iSVFBRules];

SourceVaultMailRules[] := (iSVFBRulesEnsure[]; $iSVFBRules);

iSVFBRuleId[match_, action_] :=
  "R" <> ToUpperCase@IntegerString[Hash[{match, action}, "SHA256"], 36, 8];

iSVFBNormMatch[m_Association] :=
  Module[{o = <||>, subj},
    If[StringQ[m["From"]] && m["From"] =!= "", o["From"] = ToLowerCase@StringTrim@m["From"]];
    If[StringQ[m["Domain"]] && m["Domain"] =!= "",
      o["Domain"] = ToLowerCase@StringTrim@m["Domain"]];
    If[StringQ[m["To"]] && m["To"] =!= "", o["To"] = ToLowerCase@StringTrim@m["To"]];
    If[StringQ[m["Category"]] && m["Category"] =!= "",
      With[{c = iSVFBNormCat[m["Category"]]}, If[StringQ[c], o["Category"] = c]]];
    subj = m["Subject"];
    subj = Which[StringQ[subj], {subj}, ListQ[subj], Select[subj, StringQ], True, {}];
    subj = StringTrim /@ Select[subj, StringTrim[#] =!= "" &];
    If[subj =!= {}, o["Subject"] = subj];
    o];
iSVFBNormMatch[_] := <||>;

iSVFBNormAction[a_Association] :=
  Module[{o = <||>},
    If[StringQ[a["SetCategory"]],
      With[{c = iSVFBNormCat[a["SetCategory"]]}, If[StringQ[c], o["SetCategory"] = c]]];
    Scan[
      Function[k,
        If[NumericQ[a[k]], o[k] = N@Clip[a[k], {0., 1.}]]],
      {"SetWorkRequest", "PriorityMin", "PrivacyMin", "PriorityMax", "PrivacyMax"}];
    Scan[
      Function[k, If[NumericQ[a[k]], o[k] = N@Clip[a[k], {-1., 1.}]]],
      {"PriorityAdjust", "PrivacyAdjust"}];
    o];
iSVFBNormAction[_] := <||>;

Options[SourceVaultMailAddRule] = {"Persist" -> True};
SourceVaultMailAddRule[spec_Association, OptionsPattern[]] :=
  Module[{match, action, id, rule},
    iSVFBRulesEnsure[];
    match = iSVFBNormMatch[Lookup[spec, "Match", <||>]];
    action = iSVFBNormAction[Lookup[spec, "Action", <||>]];
    If[match === <||> || action === <||>,
      Return[<|"Status" -> "Error", "Reason" -> "EmptyMatchOrAction"|>]];
    id = iSVFBRuleId[match, action];
    rule = <|"RuleId" -> id, "Enabled" -> (Lookup[spec, "Enabled", True] =!= False),
      "Match" -> match, "Action" -> action,
      "Note" -> ToString@Lookup[spec, "Note", ""],
      "Source" -> ToString@Lookup[spec, "Source", "User"],
      "CreatedAt" -> iSVFBNow[]|>;
    $iSVFBRules = Append[DeleteCases[$iSVFBRules, r_ /; Lookup[r, "RuleId", ""] === id], rule];
    If[TrueQ[OptionValue["Persist"]], iSVFBRulesSave[]];
    rule];

SourceVaultMailRemoveRule[id_String] :=
  (iSVFBRulesEnsure[];
   $iSVFBRules = DeleteCases[$iSVFBRules, r_ /; Lookup[r, "RuleId", ""] === id];
   iSVFBRulesSave[];
   <|"Status" -> "Removed", "RuleId" -> id, "Count" -> Length[$iSVFBRules]|>);

SourceVaultMailSetRuleEnabled[id_String, on_] :=
  (iSVFBRulesEnsure[];
   $iSVFBRules = (If[Lookup[#, "RuleId", ""] === id, Append[#, "Enabled" -> TrueQ[on]], #] &) /@
      $iSVFBRules;
   iSVFBRulesSave[];
   <|"Status" -> "Updated", "RuleId" -> id, "Enabled" -> TrueQ[on]|>);

iSVFBRuleMatchQ[rule_Association, facts_Association, sets_Association, cat_] :=
  Module[{m = Lookup[rule, "Match", <||>], ok = True, subj},
    If[! AssociationQ[m] || m === <||>, Return[False]];
    If[KeyExistsQ[m, "From"], ok = ok && MemberQ[Lookup[sets, "From", {}], m["From"]]];
    If[ok && KeyExistsQ[m, "Domain"], ok = MemberQ[Lookup[sets, "Dom", {}], m["Domain"]]];
    If[ok && KeyExistsQ[m, "To"], ok = MemberQ[Lookup[sets, "To", {}], m["To"]]];
    If[ok && KeyExistsQ[m, "Category"], ok = (cat === m["Category"])];
    If[ok && KeyExistsQ[m, "Subject"],
      subj = ToLowerCase@Lookup[facts, "Subject", ""];
      ok = AllTrue[m["Subject"], StringContainsQ[subj, ToLowerCase[#]] &]];
    TrueQ[ok]];

(* ---------------- L2: hierarchical Bayes ---------------- *)

If[! ValueQ[$iSVFBModel], $iSVFBModel = <||>];
If[! ValueQ[$iSVFBModelLoaded], $iSVFBModelLoaded = False];
If[! ValueQ[$iSVFBModelRoot], $iSVFBModelRoot = ""];

iSVFBEmptyModel[] :=
  <|"Cat" -> <||>, "Res" -> <|"Priority" -> <||>, "PrivacyLevel" -> <||>|>,
    "Global" -> <||>, "Events" -> 0, "UpdatedAt" -> iSVFBNow[]|>;

iSVFBModelNormalize[m_] :=
  Module[{o = If[AssociationQ[m], m, <||>], res},
    If[! AssociationQ[Lookup[o, "Cat", Null]], o["Cat"] = <||>];
    res = Lookup[o, "Res", <||>];
    If[! AssociationQ[res], res = <||>];
    If[! AssociationQ[Lookup[res, "Priority", Null]], res["Priority"] = <||>];
    If[! AssociationQ[Lookup[res, "PrivacyLevel", Null]], res["PrivacyLevel"] = <||>];
    o["Res"] = res;
    If[! AssociationQ[Lookup[o, "Global", Null]], o["Global"] = <||>];
    If[! NumericQ[Lookup[o, "Events", Null]], o["Events"] = 0];
    o];

iSVFBModelLoad[] :=
  ($iSVFBModel = iSVFBModelNormalize[iSVFBReadJSON[iSVFBModelPath[]]];
   $iSVFBModelLoaded = True;
   $iSVFBModelRoot = SourceVaultMailFeedbackRoot[];
   $iSVFBModel);

iSVFBModelEnsure[] :=
  If[! TrueQ[$iSVFBModelLoaded] || $iSVFBModelRoot =!= SourceVaultMailFeedbackRoot[],
    iSVFBModelLoad[]];
iSVFBModelSave[] := ($iSVFBModel["UpdatedAt"] = iSVFBNow[];
   iSVFBWriteJSON[iSVFBModelPath[], $iSVFBModel]);

SourceVaultMailFeedbackModel[] := (iSVFBModelEnsure[]; $iSVFBModel);

(* global category distribution with add-one smoothing *)
iSVFBGlobalProbs[model_] :=
  Module[{cats = iSVFBCats[], g, tot},
    g = Lookup[model, "Global", <||>];
    If[! AssociationQ[g], g = <||>];
    tot = Total[iSVFBNum[Lookup[g, #, 0], 0] & /@ cats];
    AssociationMap[(iSVFBNum[Lookup[g, #, 0], 0] + 1.) / (tot + Length[cats]) &, cats]];

iSVFBCatCounts[model_, key_String] :=
  With[{c = Lookup[Lookup[model, "Cat", <||>], key, <||>]},
    If[AssociationQ[c], c, <||>]];

(* posterior predictive p(category | feature), shrunk toward the parent
   distribution with strength alpha. n = 0 gives exactly the parent. *)
iSVFBCatPost[model_, key_String, parent_Association] :=
  Module[{cats = iSVFBCats[], n, tot, a = $SourceVaultMailFeedbackAlpha},
    n = iSVFBCatCounts[model, key];
    tot = Total[iSVFBNum[Lookup[n, #, 0], 0] & /@ cats];
    AssociationMap[
      (iSVFBNum[Lookup[n, #, 0], 0] + a*Lookup[parent, #, 0.]) / (tot + a) &, cats]];

iSVFBCatEvidence[model_, key_String] :=
  Total[iSVFBNum[#, 0] & /@ Values[iSVFBCatCounts[model, key]]];

(* per-family log-odds contribution: features INSIDE a family are averaged, not
   summed, so ten correlated subject n-grams weigh as much as one term. *)
iSVFBFamilyTerm[model_, family_String, feats_List, sets_Association, p0_Association] :=
  Module[{cats = iSVFBCats[], keys, parent, terms},
    keys = Select[iSVFBKey[family, #] & /@ feats, iSVFBCatEvidence[model, #] > 0 &];
    If[keys === {}, Return[Missing["NoEvidence"]]];
    parent = If[family === "From",
      (* sender shrinks toward its own domain, the domain toward global *)
      With[{dom = Lookup[sets, "Dom", {}]},
        If[dom === {}, p0, iSVFBCatPost[model, iSVFBKey["Dom", First[dom]], p0]]],
      p0];
    terms = (iSVFBCatPost[model, #, parent] &) /@ keys;
    AssociationMap[
      Function[c,
        Clip[Mean[(Log[Max[Lookup[#, c, 1.*^-6], 1.*^-6] / Max[Lookup[p0, c, 1.*^-6], 1.*^-6]] &) /@ terms],
          {-2., 2.}]],
      cats]];

iSVFBCatScores[model_, sets_Association, llmCat_] :=
  Module[{cats = iSVFBCats[], p0, contrib, scores, detail = <||>},
    p0 = iSVFBGlobalProbs[model];
    contrib = <||>;
    Scan[
      Function[fam,
        Module[{t = iSVFBFamilyTerm[model, fam, Lookup[sets, fam, {}], sets, p0],
            w = iSVFBNum[Lookup[$SourceVaultMailFeedbackFamilyWeights, fam, 0.], 0.]},
          If[AssociationQ[t],
            contrib[fam] = (w*# &) /@ t;
            detail[fam] = <|"Weight" -> w, "Term" -> t|>]]],
      $iSVFBFamilies];
    scores = AssociationMap[
      Function[c,
        $SourceVaultMailFeedbackLLMPrior*Boole[StringQ[llmCat] && c === llmCat] +
          Total[(iSVFBNum[Lookup[#, c, 0.], 0.] &) /@ Values[contrib]]],
      cats];
    <|"Scores" -> scores, "Detail" -> detail, "Global" -> p0|>];

(* residual posterior mean for a continuous field, shrunk toward 0 *)
iSVFBResidualTerm[model_, field_String, family_String, feats_List] :=
  Module[{stats, keys, mus, k = $SourceVaultMailFeedbackKappa},
    stats = Lookup[Lookup[model, "Res", <||>], field, <||>];
    If[! AssociationQ[stats], Return[Missing["NoEvidence"]]];
    keys = Select[iSVFBKey[family, #] & /@ feats,
       AssociationQ[Lookup[stats, #, Null]] &&
         iSVFBNum[Lookup[Lookup[stats, #, <||>], "N", 0], 0] > 0 &];
    If[keys === {}, Return[Missing["NoEvidence"]]];
    mus = (With[{s = stats[#]},
        iSVFBNum[Lookup[s, "Sum", 0], 0.] / (iSVFBNum[Lookup[s, "N", 0], 0.] + k)] &) /@ keys;
    Mean[mus]];

iSVFBResidualAdjust[model_, field_String, sets_Association] :=
  Module[{tot = 0., detail = <||>},
    Scan[
      Function[fam,
        Module[{t = iSVFBResidualTerm[model, field, fam, Lookup[sets, fam, {}]],
            w = iSVFBNum[Lookup[$SourceVaultMailFeedbackFamilyWeights, fam, 0.], 0.]},
          If[NumericQ[t], tot += w*t; detail[fam] = <|"Weight" -> w, "Mu" -> t|>]]],
      $iSVFBFamilies];
    <|"Adjust" -> N@Clip[tot, {-$SourceVaultMailFeedbackMaxAdjust,
         $SourceVaultMailFeedbackMaxAdjust}],
      "Detail" -> detail|>];

(* ---------------- the adjuster (what maildb calls) ---------------- *)

iSVFBOverrideOf[d_Association] :=
  With[{o = Lookup[d, "UserOverride", <||>]}, If[AssociationQ[o], o, <||>]];

SourceVaultMailFeedbackAdjust[snap_, d0_Association] :=
  Module[{d = d0, facts, sets, ov, cat, llmCat, rules, ruleIds = {},
      catFrom, catTo = Missing[], margin = 0., prioAdj = 0., privAdj = 0.,
      model, sc, best, explain = <||>, setCat = Missing[], ruleP = 0., ruleV = 0.,
      pMin = Missing[], vMin = Missing[], wrSet = Missing[]},
    If[! TrueQ[$SourceVaultMailFeedbackEnabled], Return[d0]];
    ov = iSVFBOverrideOf[d0];
    facts = iSVFBFacts[If[AssociationQ[snap], snap, ToString[snap]]];
    sets = iSVFBFeatureSets[facts];
    cat = With[{c = Lookup[d, "Category", Missing[]]}, If[StringQ[c], c, Missing[]]];
    llmCat = cat;
    catFrom = cat;

    (* --- L1: deterministic rules --- *)
    iSVFBRulesEnsure[];
    rules = Select[$iSVFBRules,
       AssociationQ[#] && Lookup[#, "Enabled", True] =!= False &];
    Scan[
      Function[r,
        If[iSVFBRuleMatchQ[r, facts, sets, cat],
          Module[{a = Lookup[r, "Action", <||>]},
            AppendTo[ruleIds, Lookup[r, "RuleId", ""]];
            If[StringQ[a["SetCategory"]], setCat = a["SetCategory"]];
            If[NumericQ[a["SetWorkRequest"]], wrSet = N[a["SetWorkRequest"]]];
            If[NumericQ[a["PriorityAdjust"]], ruleP += N[a["PriorityAdjust"]]];
            If[NumericQ[a["PrivacyAdjust"]], ruleV += N[a["PrivacyAdjust"]]];
            If[NumericQ[a["PriorityMin"]],
              pMin = If[NumericQ[pMin], Max[pMin, N[a["PriorityMin"]]], N[a["PriorityMin"]]]];
            If[NumericQ[a["PrivacyMin"]],
              vMin = If[NumericQ[vMin], Max[vMin, N[a["PrivacyMin"]]], N[a["PrivacyMin"]]]]]]],
      rules];

    (* --- L2: posterior, only where L1 and the user said nothing --- *)
    iSVFBModelEnsure[];
    model = $iSVFBModel;
    If[! KeyExistsQ[ov, "Category"] && ! StringQ[setCat],
      sc = iSVFBCatScores[model, sets, llmCat];
      If[AssociationQ[sc["Scores"]] && sc["Scores"] =!= <||>,
        best = First@Keys@ReverseSort[sc["Scores"]];
        margin = sc["Scores"][best] -
           If[StringQ[llmCat], Lookup[sc["Scores"], llmCat, 0.], 0.];
        explain["CategoryScores"] = sc["Scores"];
        explain["CategoryDetail"] = sc["Detail"];
        If[StringQ[best] && best =!= llmCat && margin >= $SourceVaultMailFeedbackSwitchMargin,
          catTo = best]]];

    If[! KeyExistsQ[ov, "Priority"],
      With[{r = iSVFBResidualAdjust[model, "Priority", sets]},
        prioAdj = r["Adjust"]; explain["PriorityResidual"] = r["Detail"]]];
    If[! KeyExistsQ[ov, "PrivacyLevel"],
      With[{r = iSVFBResidualAdjust[model, "PrivacyLevel", sets]},
        privAdj = r["Adjust"]; explain["PrivacyResidual"] = r["Detail"]]];

    (* --- apply, in layer order --- *)
    If[StringQ[setCat] && ! KeyExistsQ[ov, "Category"], d["Category"] = setCat; catTo = setCat];
    If[StringQ[catTo] && ! KeyExistsQ[ov, "Category"], d["Category"] = catTo];
    If[NumericQ[wrSet] && ! KeyExistsQ[ov, "WorkRequest"], d["WorkRequest"] = wrSet];

    (* a rule or the posterior changed the category => the structural priority
       must be recomputed, because maildb's category term feeds into it *)
    If[(StringQ[setCat] || StringQ[catTo]) && ! KeyExistsQ[ov, "Priority"] &&
        Length[DownValues[SourceVault`SourceVaultMailComputePriority]] > 0 &&
        AssociationQ[snap],
      With[{cp = Quiet@Check[
          SourceVault`SourceVaultMailComputePriority[snap,
            Lookup[d, "WorkRequest", Missing[]],
            With[{c = Lookup[d, "Category", Missing[]]}, If[StringQ[c], c, Missing[]]]],
          $Failed]},
        If[AssociationQ[cp],
          d["Priority"] = cp["Priority"]; d["PriorityComponents"] = cp["Components"]]]];

    If[! KeyExistsQ[ov, "Priority"] && NumericQ[Lookup[d, "Priority", Missing[]]],
      d["Priority"] = N@Round[Clip[d["Priority"] + prioAdj + ruleP, {0., 1.}], 0.01];
      If[NumericQ[pMin], d["Priority"] = N@Round[Max[d["Priority"], pMin], 0.01]]];
    If[! KeyExistsQ[ov, "PrivacyLevel"] && NumericQ[Lookup[d, "PrivacyLevel", Missing[]]],
      d["PrivacyLevel"] = N@Round[Clip[d["PrivacyLevel"] + privAdj + ruleV, {0., 1.}], 0.01];
      If[NumericQ[vMin], d["PrivacyLevel"] = N@Round[Max[d["PrivacyLevel"], vMin], 0.01]]];

    d["FeedbackAdjustment"] = <|
      "RuleIds" -> ruleIds,
      "CategoryFrom" -> catFrom,
      "CategoryTo" -> If[StringQ[catTo], catTo, Missing["NoChange"]],
      "CategoryMargin" -> N@Round[margin, 0.001],
      "PriorityAdjust" -> N@Round[prioAdj + ruleP, 0.001],
      "PrivacyAdjust" -> N@Round[privAdj + ruleV, 0.001],
      "Explain" -> explain,
      "At" -> iSVFBNow[]|>;
    d];
SourceVaultMailFeedbackAdjust[_, d_] := d;

(* ---------------- ledger + learning ---------------- *)

iSVFBLedgerAll[] :=
  With[{fs = iSVFBLedgerFiles[]},
    If[fs === {}, {}, Join @@ (iSVFBReadJSONL /@ fs)]];

Options[SourceVaultMailCorrections] =
  {"RecordId" -> Automatic, "Field" -> Automatic, "Limit" -> 200};
SourceVaultMailCorrections[OptionsPattern[]] :=
  Module[{all, rid, fld, lim, out, pl},
    all = iSVFBLedgerAll[];
    rid = OptionValue["RecordId"]; fld = OptionValue["Field"];
    lim = OptionValue["Limit"];
    out = Select[all,
      (rid === Automatic || Lookup[#, "RecordId", ""] === rid) &&
        (fld === Automatic || MemberQ[Keys@Lookup[#, "New", <||>], fld]) &];
    out = Reverse@SortBy[out, Lookup[#, "At", ""] &];
    If[IntegerQ[lim], out = Take[out, UpTo[lim]]];
    pl = Max[Append[iSVFBNum[Lookup[#, "PrivacyLevel", 0], 0.] & /@ out, 0.]];
    If[Length[DownValues[SourceVault`SourceVaultPrivateResult]] > 0,
      SourceVault`SourceVaultPrivateResult[out, pl], out]];

iSVFBModelBump[model0_, ev_Association] :=
  Module[{model = iSVFBModelNormalize[model0], sets, keys, cat, base, new,
      catStore, glob, resStore},
    sets = Lookup[ev, "Features", <||>];
    If[! AssociationQ[sets], Return[model]];
    keys = iSVFBAllKeys[sets];
    cat = Lookup[Lookup[ev, "New", <||>], "Category", Missing[]];
    If[StringQ[cat],
      catStore = Lookup[model, "Cat", <||>];
      Scan[
        Function[k,
          Module[{c = Lookup[catStore, k, <||>]},
            If[! AssociationQ[c], c = <||>];
            c[cat] = iSVFBNum[Lookup[c, cat, 0], 0] + 1;
            catStore[k] = c]],
        keys];
      model["Cat"] = catStore;
      glob = Lookup[model, "Global", <||>];
      glob[cat] = iSVFBNum[Lookup[glob, cat, 0], 0] + 1;
      model["Global"] = glob];
    resStore = Lookup[model, "Res", <||>];
    Scan[
      Function[field,
        base = Lookup[Lookup[ev, "Model", <||>], field, Missing[]];
        new = Lookup[Lookup[ev, "New", <||>], field, Missing[]];
        If[NumericQ[base] && NumericQ[new],
          Module[{delta = N[new - base], fieldStore = Lookup[resStore, field, <||>]},
            If[! AssociationQ[fieldStore], fieldStore = <||>];
            Scan[
              Function[k,
                Module[{s = Lookup[fieldStore, k, <||>]},
                  If[! AssociationQ[s], s = <||>];
                  s["N"] = iSVFBNum[Lookup[s, "N", 0], 0] + 1;
                  s["Sum"] = iSVFBNum[Lookup[s, "Sum", 0], 0.] + delta;
                  fieldStore[k] = s]],
              keys];
            resStore[field] = fieldStore]]],
      $iSVFBResidualFields];
    model["Res"] = resStore;
    model["Events"] = iSVFBNum[Lookup[model, "Events", 0], 0] + 1;
    model];

SourceVaultMailFeedbackRebuildModel[] :=
  Module[{evs, model = iSVFBEmptyModel[]},
    evs = SortBy[iSVFBLedgerAll[], Lookup[#, "At", ""] &];
    evs = Select[evs, Lookup[#, "Learn", True] =!= False &];
    Scan[(model = iSVFBModelBump[model, #]) &, evs];
    $iSVFBModel = model; $iSVFBModelLoaded = True;
    iSVFBModelSave[];
    <|"Status" -> "Rebuilt", "Events" -> Length[evs],
      "Features" -> Length[Lookup[model, "Cat", <||>]]|>];

(* ---------------- the correction entry point ---------------- *)

iSVFBEnsureSnapshot[rid_String] :=
  Module[{snap, row},
    snap = Quiet@Check[SourceVault`SourceVaultMailSnapshotGet[rid], Missing[]];
    If[AssociationQ[snap], Return[snap]];
    row = Quiet@Check[SourceVault`SourceVaultMailIndexGet[rid], Missing[]];
    If[AssociationQ[row] && StringQ[row["ShardKey"]],
      Quiet@Check[SourceVault`SourceVaultMailLoadShard[row["ShardKey"]], Null];
      snap = Quiet@Check[SourceVault`SourceVaultMailSnapshotGet[rid], Missing[]]];
    snap];

iSVFBCleanUpdates[u_Association] :=
  Module[{o = <||>},
    Scan[
      Function[k,
        If[KeyExistsQ[u, k] && NumericQ[u[k]], o[k] = N@Round[Clip[u[k], {0., 1.}], 0.01]]],
      $iSVFBNumericFields];
    If[KeyExistsQ[u, "Category"],
      With[{c = iSVFBNormCat[ToString[u["Category"]]]}, If[StringQ[c], o["Category"] = c]]];
    If[KeyExistsQ[u, "Deadline"],
      o["Deadline"] = If[StringQ[u["Deadline"]] && StringTrim[u["Deadline"]] =!= "",
        StringTrim[u["Deadline"]], Missing["None"]]];
    o];

Options[SourceVaultMailCorrect] =
  {"Scope" -> "Mail", "Match" -> Automatic, "Learn" -> True, "Reason" -> "",
   "Persist" -> True, "Snapshot" -> Automatic, "Reapply" -> False};
SourceVaultMailCorrect[rid_String, updates_Association, OptionsPattern[]] :=
  Module[{snap, d, upd, old = <||>, modelBase = <||>, ov, pre, facts, sets, ev,
      scope, ruleId = Missing[], learn, cp, cat, wr, res},
    upd = iSVFBCleanUpdates[updates];
    If[upd === <||>, Return[<|"Status" -> "Error", "Reason" -> "NoUsableUpdates"|>]];
    scope = ToString@OptionValue["Scope"];
    learn = TrueQ[OptionValue["Learn"]] && scope =!= "None";
    snap = With[{s = OptionValue["Snapshot"]},
       If[AssociationQ[s], s, iSVFBEnsureSnapshot[rid]]];
    If[! AssociationQ[snap],
      Return[<|"Status" -> "Error", "Reason" -> "SnapshotNotFound", "RecordId" -> rid|>]];
    d = Lookup[snap, "Derived", <||>];
    If[! AssociationQ[d], d = <||>];

    (* the value the MODEL (LLM + structure + rules + posterior) would produce
       today: the residual we learn from is user - model, not user - previous
       user value, so repeated corrections do not compound. *)
    Scan[
      Function[k,
        old[k] = Lookup[d, k, Missing[]];
        modelBase[k] = Lookup[d, k, Missing[]]],
      $iSVFBFields];

    ov = iSVFBOverrideOf[d];
    pre = Lookup[d, "PreOverride", <||>];
    If[! AssociationQ[pre], pre = <||>];
    (* residual base must exclude an earlier override of the same field, else
       repeated corrections would learn from their own previous output *)
    Scan[
      Function[k,
        If[KeyExistsQ[ov, k] && KeyExistsQ[pre, k], modelBase[k] = pre[k]]],
      $iSVFBResidualFields];
    (* remember the pre-override model value once per field *)
    Scan[
      Function[k, If[! KeyExistsQ[pre, k], pre[k] = Lookup[d, k, Missing[]]]],
      Keys[upd]];
    d["PreOverride"] = pre;

    ov = Join[ov, upd];
    d["UserOverride"] = ov;
    d["UserOverrideAt"] = iSVFBNow[];
    Scan[Function[k, d[k] = upd[k]], Keys[upd]];

    (* category / workrequest changes must flow into the structural priority
       unless the user pinned the priority explicitly *)
    If[(KeyExistsQ[upd, "Category"] || KeyExistsQ[upd, "WorkRequest"]) &&
        ! KeyExistsQ[ov, "Priority"] &&
        Length[DownValues[SourceVault`SourceVaultMailComputePriority]] > 0,
      cat = With[{c = Lookup[d, "Category", Missing[]]}, If[StringQ[c], c, Missing[]]];
      wr = Lookup[d, "WorkRequest", Missing[]];
      cp = Quiet@Check[SourceVault`SourceVaultMailComputePriority[snap, wr, cat], $Failed];
      If[AssociationQ[cp],
        d["Priority"] = cp["Priority"]; d["PriorityComponents"] = cp["Components"]]];

    (* persist the snapshot: this also rewrites the sidecar index row, so the
       list views show the corrected values without a rebuild *)
    Module[{s2 = snap},
      s2["Derived"] = d;
      Quiet@Check[SourceVault`SourceVaultMailSnapshotPut[s2, "Persist" -> False], Null];
      If[TrueQ[OptionValue["Persist"]],
        Quiet@Check[SourceVault`SourceVaultMailStoreSave["All" -> False], Null]]];

    (* ledger *)
    facts = iSVFBFacts[snap];
    sets = iSVFBFeatureSets[facts];
    ev = <|"EventId" -> "C" <> ToUpperCase@IntegerString[
         Hash[{rid, upd, iSVFBNow[]}, "SHA256"], 36, 10],
      "At" -> iSVFBNow[], "RecordId" -> rid, "MBox" -> Lookup[facts, "MBox", ""],
      "Subject" -> Lookup[facts, "Subject", ""],
      "From" -> Lookup[facts, "From", ""],
      "Old" -> KeyTake[old, Keys[upd]], "New" -> upd,
      "Model" -> KeyTake[modelBase, Keys[upd]],
      "Scope" -> scope, "Learn" -> learn,
      "Reason" -> ToString@OptionValue["Reason"],
      "PrivacyLevel" -> iSVFBNum[Lookup[d, "PrivacyLevel", 0], 0.],
      "Features" -> sets|>;
    iSVFBAppendJSONL[iSVFBLedgerPath[], ev];

    (* L2 *)
    If[learn,
      iSVFBModelEnsure[];
      $iSVFBModel = iSVFBModelBump[$iSVFBModel, ev];
      iSVFBModelSave[]];

    (* L1: explicit generalisation chosen by the user *)
    Which[
      scope === "Sender",
        With[{r = iSVFBRuleFromCorrection[facts, sets, upd, "From"]},
          If[AssociationQ[r], ruleId = Lookup[r, "RuleId", Missing[]]]],
      scope === "Rule",
        With[{m = OptionValue["Match"]},
          With[{r = If[AssociationQ[m],
              SourceVaultMailAddRule[<|"Match" -> m,
                "Action" -> iSVFBActionFromUpdates[upd], "Source" -> "User",
                "Note" -> "from correction " <> rid|>],
              iSVFBRuleFromCorrection[facts, sets, upd, "Subject"]]},
            If[AssociationQ[r], ruleId = Lookup[r, "RuleId", Missing[]]]]]];

    res = <|"Status" -> "Corrected", "RecordId" -> rid, "Old" -> KeyTake[old, Keys[upd]],
      "New" -> upd, "Scope" -> scope, "RuleId" -> ruleId, "Learned" -> learn,
      "Priority" -> Lookup[d, "Priority", Missing[]],
      "PrivacyLevel" -> Lookup[d, "PrivacyLevel", Missing[]],
      "Category" -> Lookup[d, "Category", Missing[]]|>;

    If[TrueQ[OptionValue["Reapply"]],
      With[{fromE = First[Append[Lookup[sets, "From", {}], ""]]},
        If[fromE =!= "",
          res["Reapplied"] = SourceVaultMailFeedbackReapply["From" -> fromE,
            "Persist" -> TrueQ[OptionValue["Persist"]]]]]];
    res];

SourceVaultMailCorrect[rid_String, field_String, value_, opts : OptionsPattern[]] :=
  SourceVaultMailCorrect[rid, <|field -> value|>, opts];

iSVFBActionFromUpdates[upd_Association] :=
  Module[{a = <||>},
    If[StringQ[upd["Category"]], a["SetCategory"] = upd["Category"]];
    If[NumericQ[upd["WorkRequest"]], a["SetWorkRequest"] = upd["WorkRequest"]];
    If[NumericQ[upd["Priority"]], a["PriorityMin"] = upd["Priority"]];
    If[NumericQ[upd["PrivacyLevel"]], a["PrivacyMin"] = upd["PrivacyLevel"]];
    a];

iSVFBRuleFromCorrection[facts_Association, sets_Association, upd_Association, kind_String] :=
  Module[{match = <||>, action = iSVFBActionFromUpdates[upd], from, terms},
    If[action === <||>, Return[Missing["NoAction"]]];
    from = First[Append[Lookup[sets, "From", {}], ""]];
    Which[
      kind === "From",
        If[from === "", Return[Missing["NoSender"]]];
        match["From"] = from,
      kind === "Subject",
        terms = Take[Select[Lookup[sets, "Subj", {}], StringLength[#] >= 3 &], UpTo[1]];
        If[terms === {}, Return[Missing["NoTerm"]]];
        match["Subject"] = terms;
        If[from =!= "", match["Domain"] = iSVFBDomain[from]]];
    SourceVaultMailAddRule[<|"Match" -> match, "Action" -> action,
      "Source" -> "User", "Note" -> "scope=" <> kind|>]];

(* ---------------- sender importance ---------------- *)

iSVFBResolveEntity[email_String] :=
  Quiet@Check[
    If[Length[DownValues[SourceVault`SourceVaultFindIdentifier]] === 0, Missing["NoIdentity"],
      Module[{f, idf, ent},
        f = SourceVault`SourceVaultFindIdentifier["Email", email];
        If[! AssociationQ[f], Return[Missing["NoIdentifier"], Module]];
        idf = SourceVault`SourceVaultGetIdentifier[Lookup[f, "IdentifierId", ""]];
        If[! AssociationQ[idf], Return[Missing["NoIdentifier"], Module]];
        ent = Lookup[idf, "EntityRef", Missing[]];
        If[! StringQ[ent], Return[Missing["Unlinked"], Module]];
        SourceVault`SourceVaultGetEntity[ent]]],
    Missing["NoIdentity"]];

Options[SourceVaultMailSetSenderWeight] = {"Reapply" -> True, "Persist" -> True};
SourceVaultMailSetSenderWeight[target_String, weight_?NumericQ, OptionsPattern[]] :=
  Module[{email, ent, w = N@Clip[weight, {0., 1.}], via = "Rule", ok, res},
    email = If[StringContainsQ[target, "@"], ToLowerCase@StringTrim[target],
      First[Append[Lookup[iSVFBFeatureSets[iSVFBFacts[target]], "From", {}], ""]]];
    If[email === "",
      Return[<|"Status" -> "Error", "Reason" -> "NoSenderAddress", "Target" -> target|>]];
    ent = iSVFBResolveEntity[email];
    If[AssociationQ[ent] && StringQ[Lookup[ent, "EntityId", Missing[]]] &&
        Length[DownValues[SourceVault`SourceVaultUpdateEntity]] > 0,
      ok = Quiet@Check[
        SourceVault`SourceVaultUpdateEntity[ent["EntityId"], <|"PriorityWeight" -> w|>,
          "Persist" -> TrueQ[OptionValue["Persist"]]], $Failed];
      If[ok =!= $Failed, via = "Entity"]];
    If[via === "Rule",
      (* no linked entity: an L1 rule on the address reproduces the same shift
         (relative to maildb's default sender weight 0.4) *)
      SourceVaultMailAddRule[<|
        "Match" -> <|"From" -> email|>,
        "Action" -> <|"PriorityAdjust" -> N@Round[w - 0.4, 0.01]|>,
        "Source" -> "User", "Note" -> "sender weight " <> ToString[w]|>]];
    res = <|"Status" -> "Ok", "Email" -> email, "Weight" -> w, "Via" -> via|>;
    If[TrueQ[OptionValue["Reapply"]],
      res["Reapplied"] = SourceVaultMailFeedbackReapply["From" -> email,
         "Persist" -> TrueQ[OptionValue["Persist"]]]];
    res];

(* ---------------- reapply to stored mails ---------------- *)

Options[SourceVaultMailFeedbackReapply] =
  {"From" -> Automatic, "MBox" -> Automatic, "RecordIds" -> Automatic,
   "Persist" -> True, "DryRun" -> False};
SourceVaultMailFeedbackReapply[OptionsPattern[]] :=
  Module[{snaps, from, mbox, rids, scanned = 0, changed = 0, dry},
    If[Length[DownValues[SourceVault`SourceVaultMailSnapshotList]] === 0,
      Return[<|"Status" -> "Skipped", "Reason" -> "MaildbUnavailable"|>]];
    dry = TrueQ[OptionValue["DryRun"]];
    from = OptionValue["From"]; mbox = OptionValue["MBox"];
    rids = OptionValue["RecordIds"];
    snaps = Quiet@Check[SourceVault`SourceVaultMailSnapshotList[], {}];
    Do[
      Module[{facts, sets, d, d0, cp, s2, cat, wr},
        If[! AssociationQ[snap], Continue[]];
        d0 = Lookup[snap, "Derived", <||>];
        If[! AssociationQ[d0] || ! KeyExistsQ[d0, "PriorityComponents"], Continue[]];
        facts = iSVFBFacts[snap];
        If[ListQ[rids] && ! MemberQ[rids, Lookup[facts, "RecordId", ""]], Continue[]];
        If[StringQ[mbox] && Lookup[facts, "MBox", ""] =!= mbox, Continue[]];
        sets = iSVFBFeatureSets[facts];
        If[StringQ[from] && from =!= "" && ! MemberQ[Lookup[sets, "From", {}], ToLowerCase[from]],
          Continue[]];
        scanned++;
        cat = With[{c = Lookup[d0, "Category", Missing[]]}, If[StringQ[c], c, Missing[]]];
        wr = Lookup[d0, "WorkRequest", Missing[]];
        cp = Quiet@Check[SourceVault`SourceVaultMailComputePriority[snap, wr, cat], $Failed];
        d = d0;
        If[AssociationQ[cp],
          d["Priority"] = cp["Priority"]; d["PriorityComponents"] = cp["Components"]];
        d = SourceVaultMailFeedbackAdjust[snap, d];
        d = iSVFBApplyOverrideLocal[snap, d];
        If[KeyDrop[d, {"FeedbackAdjustment"}] =!= KeyDrop[d0, {"FeedbackAdjustment"}],
          changed++;
          If[! dry,
            s2 = snap; s2["Derived"] = d;
            Quiet@Check[SourceVault`SourceVaultMailSnapshotPut[s2, "Persist" -> False], Null]]]],
      {snap, snaps}];
    If[! dry && changed > 0 && TrueQ[OptionValue["Persist"]],
      Quiet@Check[SourceVault`SourceVaultMailStoreSave["All" -> False], Null]];
    <|"Status" -> "Ok", "Scanned" -> scanned, "Changed" -> changed,
      "Total" -> Length[snaps], "DryRun" -> dry|>];

(* local copy of maildb's override enforcement, so Reapply behaves identically
   even if an older maildb (without the seam) is loaded *)
iSVFBApplyOverrideLocal[snap_, d0_Association] :=
  Module[{d = d0, ov = iSVFBOverrideOf[d0]},
    If[ov === <||>, Return[d0]];
    Scan[
      Function[k, If[KeyExistsQ[ov, k], d[k] = ov[k]]],
      $iSVFBFields];
    d];

(* ---------------- proposals (L2 -> L1 promotion) ---------------- *)

Options[SourceVaultMailRuleProposals] = {"MinCount" -> Automatic};
SourceVaultMailRuleProposals[OptionsPattern[]] :=
  Module[{model, minN, cats, out = {}, covered},
    iSVFBModelEnsure[]; iSVFBRulesEnsure[];
    model = $iSVFBModel;
    minN = With[{m = OptionValue["MinCount"]},
       If[IntegerQ[m], m, $SourceVaultMailFeedbackPromoteCount]];
    cats = iSVFBCats[];
    covered = Association[
      (Lookup[#, "Match", <||>] -> True &) /@
        Select[$iSVFBRules, Lookup[#, "Enabled", True] =!= False &]];
    KeyValueMap[
      Function[{key, counts},
        Module[{tot, best, match, fam, feat, action},
          If[! AssociationQ[counts], Return[Null, Module]];
          tot = Total[iSVFBNum[#, 0] & /@ Values[counts]];
          If[tot < minN, Return[Null, Module]];
          best = First@Keys@ReverseSort[counts];
          If[iSVFBNum[counts[best], 0] < minN, Return[Null, Module]];
          (* consistency: the dominant category must hold at least 80% *)
          If[iSVFBNum[counts[best], 0] < 0.8*tot, Return[Null, Module]];
          {fam, feat} = With[{p = StringSplit[key, ":", 2]},
             If[Length[p] === 2, p, {"", key}]];
          match = Switch[fam,
            "From", <|"From" -> feat|>, "Dom", <|"Domain" -> feat|>,
            "To", <|"To" -> feat|>, "Subj", <|"Subject" -> {feat}|>, _, <||>];
          If[match === <||>, Return[Null, Module]];
          If[TrueQ[Lookup[covered, match, False]], Return[Null, Module]];
          action = <|"SetCategory" -> best|>;
          AppendTo[out, <|
            "ProposalId" -> iSVFBRuleId[match, action],
            "Feature" -> key, "Family" -> fam, "Count" -> tot,
            "Category" -> best, "Confidence" -> N@Round[counts[best]/tot, 0.01],
            "Match" -> match, "Action" -> action,
            "Note" -> "promoted from " <> ToString[Round[tot]] <> " corrections"|>]]],
      Lookup[model, "Cat", <||>]];
    ReverseSortBy[out, Lookup[#, "Count", 0] &]];

SourceVaultMailAcceptRuleProposal[p_Association] :=
  SourceVaultMailAddRule[<|"Match" -> Lookup[p, "Match", <||>],
    "Action" -> Lookup[p, "Action", <||>], "Source" -> "Promoted",
    "Note" -> ToString@Lookup[p, "Note", ""]|>];
SourceVaultMailAcceptRuleProposal[id_String] :=
  With[{p = SelectFirst[SourceVaultMailRuleProposals[],
      Lookup[#, "ProposalId", ""] === id &, Missing["NotFound"]]},
    If[AssociationQ[p], SourceVaultMailAcceptRuleProposal[p],
      <|"Status" -> "Error", "Reason" -> "ProposalNotFound", "ProposalId" -> id|>]];

(* ---------------- explanation ---------------- *)

SourceVaultMailFeedbackExplain[rid_String] :=
  Module[{snap, d, facts, sets, model, sc, out},
    snap = iSVFBEnsureSnapshot[rid];
    If[! AssociationQ[snap],
      Return[<|"Status" -> "Error", "Reason" -> "SnapshotNotFound"|>]];
    d = Lookup[snap, "Derived", <||>];
    facts = iSVFBFacts[snap]; sets = iSVFBFeatureSets[facts];
    iSVFBModelEnsure[]; model = $iSVFBModel;
    sc = iSVFBCatScores[model, sets,
       With[{c = Lookup[d, "Category", Missing[]]}, If[StringQ[c], c, Missing[]]]];
    out = <|"Status" -> "Ok", "RecordId" -> rid,
      "Category" -> Lookup[d, "Category", Missing[]],
      "Priority" -> Lookup[d, "Priority", Missing[]],
      "PrivacyLevel" -> Lookup[d, "PrivacyLevel", Missing[]],
      "WorkRequest" -> Lookup[d, "WorkRequest", Missing[]],
      "PriorityComponents" -> Lookup[d, "PriorityComponents", <||>],
      "UserOverride" -> iSVFBOverrideOf[d],
      "FeedbackAdjustment" -> Lookup[d, "FeedbackAdjustment", <||>],
      "Features" -> sets,
      "CategoryScores" -> sc["Scores"],
      "MatchedRules" -> Select[SourceVaultMailRules[],
         Lookup[#, "Enabled", True] =!= False &&
           iSVFBRuleMatchQ[#, facts, sets,
             With[{c = Lookup[d, "Category", Missing[]]}, If[StringQ[c], c, Missing[]]]] &]|>;
    If[Length[DownValues[SourceVault`SourceVaultPrivateResult]] > 0,
      SourceVault`SourceVaultPrivateResult[out, iSVFBNum[Lookup[d, "PrivacyLevel", 0], 0.]],
      out]];

(* ---------------- views ---------------- *)

Options[SourceVaultMailFeedbackView] = Options[SourceVaultMailCorrections];
SourceVaultMailFeedbackView[opts : OptionsPattern[]] :=
  Module[{evs, rows, pl, ds},
    evs = iSVFBLedgerAll[];
    evs = Reverse@SortBy[evs, Lookup[#, "At", ""] &];
    With[{lim = OptionValue["Limit"]},
      If[IntegerQ[lim], evs = Take[evs, UpTo[lim]]]];
    pl = Max[Append[iSVFBNum[Lookup[#, "PrivacyLevel", 0], 0.] & /@ evs, 0.]];
    rows = Function[e,
       <|"\:65e5\:6642" -> StringReplace[ToString@Lookup[e, "At", ""], "T" -> " "],
         "\:4ef6\:540d" -> StringTake[ToString@Lookup[e, "Subject", ""], UpTo[36]],
         "\:5dee\:51fa\:4eba" -> StringTake[ToString@Lookup[e, "From", ""], UpTo[28]],
         "\:5909\:66f4" -> StringRiffle[
            KeyValueMap[
              Function[{k, v},
                k <> ": " <> iSVFBFmt[Lookup[Lookup[e, "Old", <||>], k, Missing[]]] <>
                  " -> " <> iSVFBFmt[v]],
              Lookup[e, "New", <||>]], ", "],
         "\:7bc4\:56f2" -> ToString@Lookup[e, "Scope", ""],
         "\:5b66\:7fd2" -> If[Lookup[e, "Learn", True] =!= False, "\[Checkmark]", ""]|>] /@ evs;
    ds = Dataset[rows];
    If[Length[DownValues[SourceVault`SourceVaultPrivateView]] > 0,
      SourceVault`SourceVaultPrivateView[ds, pl], ds]];

iSVFBFmt[x_] := Which[
   MissingQ[x] || x === Null, "-",
   NumericQ[x], ToString@NumberForm[N@Round[x, 0.01], {3, 2}],
   StringQ[x] && KeyExistsQ[$iSVFBCatLabel, x], iSVFBCatLabel[x],
   StringQ[x], x,
   True, ToString[x]];

SourceVaultMailRulesView[] :=
  Module[{rules = SourceVaultMailRules[], rows},
    rows = Function[r,
      <|"" -> Row[{
           Button[If[Lookup[r, "Enabled", True] =!= False, "\[Checkmark]", "\[EmptySquare]"],
             SourceVaultMailSetRuleEnabled[Lookup[r, "RuleId", ""],
               ! (Lookup[r, "Enabled", True] =!= False)],
             Appearance -> "Frameless", Method -> "Queued"],
           Spacer[4],
           Button["\[Times]", SourceVaultMailRemoveRule[Lookup[r, "RuleId", ""]],
             Appearance -> "Frameless", Method -> "Queued"]}],
        "\:6761\:4ef6" -> iSVFBMatchLabel[Lookup[r, "Match", <||>]],
        "\:52b9\:679c" -> iSVFBActionLabel[Lookup[r, "Action", <||>]],
        "\:7531\:6765" -> ToString@Lookup[r, "Source", ""],
        "\:4f5c\:6210" -> StringTake[ToString@Lookup[r, "CreatedAt", ""], UpTo[10]],
        "ID" -> ToString@Lookup[r, "RuleId", ""]|>] /@ rules;
    If[Length[DownValues[SourceVault`SourceVaultPrivateView]] > 0,
      SourceVault`SourceVaultPrivateView[Dataset[rows], 0.6], Dataset[rows]]];

iSVFBMatchLabel[m_Association] :=
  StringRiffle[
    DeleteCases[{
      If[KeyExistsQ[m, "From"], "\:5dee\:51fa\:4eba=" <> m["From"], Nothing],
      If[KeyExistsQ[m, "Domain"], "\:30c9\:30e1\:30a4\:30f3=" <> m["Domain"], Nothing],
      If[KeyExistsQ[m, "To"], "\:5b9b\:5148=" <> m["To"], Nothing],
      If[KeyExistsQ[m, "Subject"], "\:8a9e=" <> StringRiffle[m["Subject"], "+"], Nothing],
      If[KeyExistsQ[m, "Category"], "\:5206\:985e=" <> iSVFBCatLabel[m["Category"]], Nothing]},
      Nothing], " & "];
iSVFBMatchLabel[_] := "";

iSVFBActionLabel[a_Association] :=
  StringRiffle[
    DeleteCases[{
      If[KeyExistsQ[a, "SetCategory"], "\:5206\:985e\:2192" <> iSVFBCatLabel[a["SetCategory"]], Nothing],
      If[KeyExistsQ[a, "SetWorkRequest"], "\:4f9d\:983c\:5ea6=" <> iSVFBFmt[a["SetWorkRequest"]], Nothing],
      If[KeyExistsQ[a, "PriorityMin"], "\:91cd\:8981\:5ea6\:2267" <> iSVFBFmt[a["PriorityMin"]], Nothing],
      If[KeyExistsQ[a, "PriorityAdjust"], "\:91cd\:8981\:5ea6" <>
         If[a["PriorityAdjust"] >= 0, "+", ""] <> iSVFBFmt[a["PriorityAdjust"]], Nothing],
      If[KeyExistsQ[a, "PrivacyMin"], "\:79d8\:533f\:2267" <> iSVFBFmt[a["PrivacyMin"]], Nothing],
      If[KeyExistsQ[a, "PrivacyAdjust"], "\:79d8\:533f" <>
         If[a["PrivacyAdjust"] >= 0, "+", ""] <> iSVFBFmt[a["PrivacyAdjust"]], Nothing]},
      Nothing], ", "];
iSVFBActionLabel[_] := "";

(* ---------------- correction panel (front end) ---------------- *)

iSVFBPanelFont[] :=
  With[{f = Quiet@Check[ClaudeCode`$ClaudeStandardFont, $Failed]},
    If[StringQ[f] && f =!= "", f, "Yu Gothic UI"]];

iSVFBStep[v_, dv_] := N@Round[Clip[v + dv, {0., 1.}], 0.01];

iSVFBCurrent[rid_String] :=
  Module[{snap = iSVFBEnsureSnapshot[rid], d, row},
    If[AssociationQ[snap],
      d = Lookup[snap, "Derived", <||>];
      Return[<|"Priority" -> iSVFBNum[Lookup[d, "Priority", 0], 0.],
        "PrivacyLevel" -> iSVFBNum[Lookup[d, "PrivacyLevel", 0], 0.],
        "Category" -> With[{c = Lookup[d, "Category", Missing[]]},
           If[StringQ[c], c, "Other"]]|>]];
    row = Quiet@Check[SourceVault`SourceVaultMailIndexGet[rid], Missing[]];
    If[AssociationQ[row],
      Return[<|"Priority" -> iSVFBNum[Lookup[row, "Priority", 0], 0.],
        "PrivacyLevel" -> iSVFBNum[Lookup[row, "PrivacyLevel", 0], 0.],
        "Category" -> With[{c = Lookup[row, "Category", Missing[]]},
           If[StringQ[c], c, "Other"]]|>]];
    <|"Priority" -> 0., "PrivacyLevel" -> 0., "Category" -> "Other"|>];

iSVFBSenderWeightNow[rid_String] :=
  Module[{email, ent},
    email = First[Append[Lookup[iSVFBFeatureSets[iSVFBFacts[rid]], "From", {}], ""]];
    If[email === "", Return[Missing["NoSender"]]];
    ent = iSVFBResolveEntity[email];
    If[AssociationQ[ent] && NumericQ[Lookup[ent, "PriorityWeight", Missing[]]],
      N@ent["PriorityWeight"], Missing["NotSet"]]];

SourceVaultMailFeedbackPanel[rid_String] :=
  Module[{cur = iSVFBCurrent[rid], sw = iSVFBSenderWeightNow[rid], ff = iSVFBPanelFont[],
      cats = iSVFBCats[]},
    DynamicModule[{
        pri = cur["Priority"], sec = cur["PrivacyLevel"], cat = cur["Category"],
        senderW = If[NumericQ[sw], sw, 0.4], scope = "Mail", busy = False,
        status = "", touched = False},
      Panel[
        Column[{
          Row[{
            Style["\:91cd\:8981\:5ea6 ", "Text", FontFamily -> ff],
            Button["\[EmptyDownTriangle]", (pri = iSVFBStep[pri, -0.1]; touched = True),
              Appearance -> "Palette", ImageSize -> {24, 20}],
            Pane[Dynamic@Style[iSVFBFmt[pri], "Text", Bold, FontFamily -> ff], {40, Automatic},
              Alignment -> Center],
            Button["\[EmptyUpTriangle]", (pri = iSVFBStep[pri, +0.1]; touched = True),
              Appearance -> "Palette", ImageSize -> {24, 20}],
            Spacer[12],
            Style["\:79d8\:533f ", "Text", FontFamily -> ff],
            Button["\[EmptyDownTriangle]", (sec = iSVFBStep[sec, -0.1]; touched = True),
              Appearance -> "Palette", ImageSize -> {24, 20}],
            Pane[Dynamic@Style[iSVFBFmt[sec], "Text", Bold, FontFamily -> ff], {40, Automatic},
              Alignment -> Center],
            Button["\[EmptyUpTriangle]", (sec = iSVFBStep[sec, +0.1]; touched = True),
              Appearance -> "Palette", ImageSize -> {24, 20}],
            Spacer[12],
            Style["\:5206\:985e ", "Text", FontFamily -> ff],
            PopupMenu[Dynamic[cat, (cat = #; touched = True) &],
              (# -> iSVFBCatLabel[#] &) /@ cats, MenuStyle -> {FontFamily -> ff}],
            Spacer[12],
            Style["\:5dee\:51fa\:4eba\:91cd\:8981\:5ea6 ", "Text", FontFamily -> ff],
            PopupMenu[Dynamic[senderW],
              {0. -> "0.0 \:7121\:8996", 0.2 -> "0.2 \:4f4e", 0.4 -> "0.4 \:65e2\:5b9a", 0.6 -> "0.6 \:9ad8",
               0.8 -> "0.8 \:91cd\:8981", 1.0 -> "1.0 \:6700\:91cd\:8981"}, MenuStyle -> {FontFamily -> ff}],
            Spacer[6],
            Button["\:5dee\:51fa\:4eba\:3078\:9069\:7528",
              (busy = True;
               With[{r = SourceVaultMailSetSenderWeight[rid, senderW]},
                 status = If[Lookup[r, "Status", ""] === "Ok",
                   Style["\[Checkmark] \:5dee\:51fa\:4eba\:91cd\:8981\:5ea6 " <> iSVFBFmt[senderW] <> " (" <>
                     ToString@Lookup[r, "Via", ""] <> ")", Darker@Green],
                   Style["\[Times] " <> ToString@Lookup[r, "Reason", ""], Red]]];
               busy = False), Method -> "Queued"]},
            BaselinePosition -> Center],
          Row[{
            Style["\:5b66\:7fd2\:306e\:7bc4\:56f2 ", "Text", FontFamily -> ff],
            PopupMenu[Dynamic[scope],
              {"Mail" -> "\:3053\:306e1\:901a\:306e\:307f", "Sender" -> "\:3053\:306e\:5dee\:51fa\:4eba\:306b\:3082\:9069\:7528",
               "Rule" -> "\:4ef6\:540d\:306e\:8a9e\:3067\:30eb\:30fc\:30eb\:5316", "None" -> "\:5b66\:7fd2\:3057\:306a\:3044"},
              MenuStyle -> {FontFamily -> ff}],
            Spacer[12],
            Button[Style["\:53cd\:6620", Bold],
              (busy = True;
               Module[{upd = <||>, base = iSVFBCurrent[rid], r},
                 If[Abs[pri - base["Priority"]] > 0.004, upd["Priority"] = pri];
                 If[Abs[sec - base["PrivacyLevel"]] > 0.004, upd["PrivacyLevel"] = sec];
                 If[cat =!= base["Category"], upd["Category"] = cat];
                 If[upd === <||>,
                   status = Style["\:5909\:66f4\:304c\:3042\:308a\:307e\:305b\:3093", Gray],
                   r = SourceVaultMailCorrect[rid, upd, "Scope" -> scope,
                      "Learn" -> (scope =!= "None"), "Reapply" -> (scope === "Sender")];
                   status = If[Lookup[r, "Status", ""] === "Corrected",
                     Style["\[Checkmark] \:53cd\:6620\:3057\:307e\:3057\:305f (\:91cd\:8981\:5ea6 " <>
                       iSVFBFmt[Lookup[r, "Priority", pri]] <> " / \:79d8\:533f " <>
                       iSVFBFmt[Lookup[r, "PrivacyLevel", sec]] <> " / " <>
                       iSVFBCatLabel[Lookup[r, "Category", cat]] <> ")", Darker@Green],
                     Style["\[Times] " <> ToString@Lookup[r, "Reason", "Error"], Red]];
                   touched = False]];
               busy = False), Method -> "Queued"],
            Spacer[6],
            Button["\:5185\:8a33",
              CreateDocument[
                ExpressionCell[SourceVaultMailFeedbackExplain[rid], "Output"],
                WindowTitle -> "\:5224\:5b9a\:306e\:5185\:8a33"], Method -> "Queued"],
            Spacer[8],
            Dynamic[If[busy, ProgressIndicator[Appearance -> "Necklace"], ""]],
            Spacer[6], Dynamic[status]},
            BaselinePosition -> Center]},
          Spacing -> 0.6],
        Style["\:5206\:985e\:306e\:8a02\:6b63", "Text", FontFamily -> ff]]]];
SourceVaultMailFeedbackPanel[snap_Association] :=
  SourceVaultMailFeedbackPanel[ToString@Lookup[snap, "RecordId", ""]];
SourceVaultMailFeedbackPanel[___] := "";

SourceVaultMailFeedbackWindow[rid_String] :=
  Quiet@Check[
    CreateDocument[
      ExpressionCell[SourceVaultMailFeedbackPanel[rid], "Output",
        CellMargins -> {{15, 15}, {12, 12}}],
      WindowTitle -> "\:5206\:985e\:306e\:8a02\:6b63: " <> StringTake[rid, UpTo[24]],
      WindowSize -> {880, 220}], $Failed];
SourceVaultMailFeedbackWindow[snap_Association] :=
  SourceVaultMailFeedbackWindow[ToString@Lookup[snap, "RecordId", ""]];

(* ---------------- wiring: register the adjuster with maildb ---------------- *)

iSVFBWire[] :=
  Quiet@Check[
    (SourceVault`$SourceVaultMailDerivedAdjuster =
       Function[{s, d}, SourceVault`SourceVaultMailFeedbackAdjust[s, d]];
     <|"Status" -> "Wired"|>),
    <|"Status" -> "Failed"|>];
$iSVFBWireResult = iSVFBWire[];

(* ---------------- privacy contracts (self registration) ---------------- *)

iSVFBRegisterPrivacyContracts[] :=
  Quiet@Check[
    If[Length[DownValues[SourceVault`SourceVaultRegisterPrivacyContract]] > 0,
      Scan[
        SourceVault`SourceVaultRegisterPrivacyContract[First[#],
          Join[<|"Module" -> "SourceVault_mailfeedback.wl", "Sources" -> {"mail"}|>,
            If[Last[#] === "Internal",
              <|"Class" -> "Internal",
                "NoDataFlow" -> "\:8a02\:6b63\:306e\:9069\:7528/\:5b66\:7fd2\:30d1\:30a4\:30d7\:30e9\:30a4\:30f3\:3002\:8fd4\:308a\:5024\:306f\:4ef6\:6570\:3068\:72b6\:614b\:306e\:307f\:3002"|>,
              <|"Class" -> "Private", "Exit" -> Last[#]|>]]] &,
        {{"SourceVaultMailCorrections", "Result"},
         {"SourceVaultMailFeedbackExplain", "Result"},
         {"SourceVaultMailFeedbackFeatures", "Result"},
         {"SourceVaultMailFeedbackModel", "Result"},
         {"SourceVaultMailRules", "Result"},
         {"SourceVaultMailRuleProposals", "Result"},
         {"SourceVaultMailFeedbackView", "View"},
         {"SourceVaultMailRulesView", "View"},
         {"SourceVaultMailFeedbackPanel", "View"},
         {"SourceVaultMailFeedbackWindow", "Head"},
         {"SourceVaultMailCorrect", "Internal"},
         {"SourceVaultMailSetSenderWeight", "Internal"},
         {"SourceVaultMailFeedbackReapply", "Internal"},
         {"SourceVaultMailFeedbackRebuildModel", "Internal"}}]];
    Null, Null];
iSVFBRegisterPrivacyContracts[];

End[];

EndPackage[];
