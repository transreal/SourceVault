# SourceVault_course API Reference

Exercise database, exam paper generation, and grading support, organized by subject (科目). Auto-loaded from SourceVault.wl (no load banner). Public symbols live in context `SourceVault\``.

## Overview

- Exercise store per subject: ingest from problem notebooks (held-expression structural decomposition, no cell evaluation, no FE required), field/unit(syllabus-aligned)/difficulty/exam-history metadata.
- Exam composition (`SourceVaultExamCompose`) → question-paper PDF + answer-sheet PDF. Answer-sheet layout is stored as data on the exam record and shared with scanned-answer cropping (grading) — same geometry both places.
- LLM-generated similar problems (Draft → owner approval via `SourceVaultExerciseApproveDraft`).
- Scanned-answer ingest / roster matching (owner visually verifies) / recognition / scoring / re-weighting.
- Privacy: exercise records carry no personal info → default PrivacyLevel 0.3 (cloud-eligible). Scans, matching, and grading results are PL 1.0 (local only). Only answer-cell crops go to cloud LLM (student-ID/name regions excluded by geometry); ID/name recognition and matching is done by owner visual check, never automated.
- Held-expression idiom: notebook cells are parsed via `ToExpression[..., Hold]` without evaluating, then decomposed with `Hold[{a,b,...}] -> {Hold[a], Hold[b], ...}` so images/graphics/math never get rasterized or evaluated during ingest.

## Config Variables

### $SourceVaultExercisesRoot
型: Automatic | String, 初期値: Automatic
Exercise-store root override. When Automatic, resolves to `<PrivateVault>/exercises`.

### $SourceVaultExerciseDefaultPrivacyLevel
型: Real, 初期値: 0.3
Default privacy level for exercise records (no personal info assumed).

### $SourceVaultExercisesViewLimit
型: Integer, 初期値: 50
Default row cap for `*View` Dataset displays.

### $SourceVaultExamFontFamily
型: Automatic | String, 初期値: Automatic
Font for exam-paper rendering. Automatic picks by OS (Windows: "Yu Gothic").

### $SourceVaultExamInstructor
型: String, 初期値: "今井 勝喜"
Instructor name printed on exam papers.

### $SourceVaultExamTemplatePDF
型: Automatic | String | None, 初期値: Automatic
Path to the official blank "試験問題・解答用紙" PDF. Automatic uses `<exercises root>/templates/試験問題・解答用紙.pdf`, falling back to a built-in drawn header if absent. None always forces the built-in drawing.

### $SourceVaultCourseWebReportRoot
型: Automatic | String, 初期値: Automatic
Web レポート回収フォルダの root override。Automatic なら `<udb>/webreports` (udb = PrivateVault の親)。

### $SourceVaultCourseWebStoreRoot
型: Automatic | String, 初期値: Automatic
course 用ストア (名簿レジストリ等) の root override。Automatic なら `<PrivateVault>/coursereports`。

### $SourceVaultCourseWebPdfTextFn
型: Automatic | Function, 初期値: Automatic
PDF 本文抽出のシーム `fn[bytes]->String`。Automatic は `ImportByteArray[..., {"PDF","Plaintext"}]`。

## Subject Management

### SourceVaultExerciseRegisterSubject[code, spec] → Association
Registers/updates a subject.
Spec keys: "Title", "Syllabus" (`<|n -> <|"Topic","Field"|>|>` or raw syllabus text, auto-parsed via `SourceVaultExerciseParseSyllabus`), "UnitMap" (`<|rawUnit -> correctedUnit|>`), "LectureHeader". Returns the stored entry (includes "Registered"/"Modified" timestamps).

### SourceVaultExerciseSubjects[] → {String...}
Registered subject codes.

### SourceVaultExerciseSubjectInfo[code] → Association | Missing["NotRegistered"]
Subject config association.

### SourceVaultExerciseParseSyllabus[text] → Association
Extracts `<|n -> <|"Topic","Field"|>|>` from syllabus body text by scanning "第N回" markers.

## Problem CRUD / Query

### SourceVaultExerciseAdd[subject, assoc] → <|"Id","Existed"|>
Adds a problem record; id is content-hash-derived (`"<subject>-<hash12>"`), so re-adding identical content is idempotent (returns `"Existed"->True`, and merges a differing `RawUnit` into `AltUnits`).
assoc keys: "Question" | "QuestionHeld" (held form for figures/math), "Choices", "Answer", "Source", "Explanation", "Unit", "Field", "Difficulty", "Status", plus optional "ModelAnswer", "BaseId", "Origin", "FigureSpec", "PrivacyLevel".

### SourceVaultExerciseGet[id] → Association | Missing
Full problem record (see `SourceVaultExerciseAdd` for stored keys).

### SourceVaultExerciseUpdate[id, changes] → <|"Status","Id","Updated","Headline"|>
Merges `changes` into the record. "Headline" is recomputed automatically when "Question"/"QuestionHeld" changes.
Adjustment-only fields (do not alter the source problem): "HideChoices"->True (suppress choice list when content lives in the question body/table/figure), "QuestionNote"->"..." (append a note after the question), "QuestionOverride"->"..." (replace question text while keeping any figure — for corrupted source text).

### SourceVaultExerciseRetire[id] → <|...|>
Sets Status->"Retired" (no deletion). Thin wrapper over `SourceVaultExerciseUpdate`.

### SourceVaultExercises[subject, opts] → {Association...}
Core index query.
Options: "Unit" -> All, "Field" -> All, "Format" -> All, "Status" -> "Active", "MaxItems" -> All
Results sorted by Unit, then Created, then Id.

### SourceVaultExercisesView[subject, opts]
Dataset view of `SourceVaultExercises`, capped at `$SourceVaultExercisesViewLimit`, columns: Id, Unit, Field, Format, Status, Difficulty, HasImage, Headline, Source.
Options: same as `SourceVaultExercises`.

### SourceVaultExerciseSearch[subject, query, opts] → {Association...}
Substring search (case-insensitive) over question text, choices, source, explanation, headline.
Options: "Status" -> All, "MaxItems" -> All

### SourceVaultExerciseSearchView[subject, query, opts]
Dataset view of `SourceVaultExerciseSearch`; adds a "Kind" column ("テキスト" | "テキスト+図" | "図のみ" | "空") to flag duplicate text-vs-image-only entries.
Options: same as `SourceVaultExerciseSearch`.

### SourceVaultExerciseStructure[id] → Association
Diagnostic: internal shape of a record (whether the question is string vs. held, the element sequence inside the held form, choice element types). Use to debug layout breakage.
→ keys: "QuestionKind", "QuestionPreview", "ContentHead", "PartCount", "Parts" (list of `<|"Head","Preview"|>`), "ChoiceHeads".

### SourceVaultExerciseStructureView[id]
Dataset view of `SourceVaultExerciseStructure`.

### SourceVaultExerciseView[id]
Renders one problem with formatting (may require FE). Not for LLM consumption — human inspection only.

### SourceVaultExerciseStats[subject] → Association
Counts by unit/field/format/difficulty/status.
→ keys: "Total", "ByStatus", "ByUnit", "ByField", "ByFormat", "ByDifficulty".

### SourceVaultExerciseSetDifficulty[id, d, opts] → <|...|>
Sets estimated difficulty (1..5).
Options: "DifficultySource" -> "owner"

### SourceVaultExerciseAssignUnit[ids, unit] → {Id...}
Bulk-corrects the unit for one id or a list of ids (also updates "Field" via the syllabus map). Accepts a single String id too.

### SourceVaultExerciseEstimateDifficulty[subject, opts] → report
Bulk LLM difficulty estimation for problems without a difficulty set (1=easy .. 5=hard, sets DifficultySource->"llm").
Options: "LLMFn" (test seam), "Overwrite" -> False, "MaxItems" -> All

### SourceVaultExerciseUnitAuditView[subject]
Dataset pairing syllabus topic vs. problem headlines per unit, to spot unit drift.

## Notebook Ingest

### SourceVaultExerciseIngestNotebook[nbPath, subject, opts] → report Association
Structurally ingests a problem notebook (no cell evaluation, no FE). Decomposes `excercise*={...}` assignments under "第N回" Subsubsection headers, held, into problem records. Also re-parses the syllabus text found in the notebook and (re-)registers the subject (keeping existing Title/UnitMap unless overridden).
Options: "UnitMap" -> Automatic, "SubjectTitle" -> Automatic, "DryRun" -> False, "Status" -> "Active"
→ keys: "Status", "Subject", "Notebook", "Parsed", "Ingested", "Existed", "SkippedUnparsed", "DryRun", "Units", "SyllabusUnits", "Ids".

## Similar Problem Generation

### SourceVaultExerciseGenerateSimilar[id, n, opts] → report
Generates `n` similar problems from a base problem via LLM, saved as Draft. For figure problems the LLM generates structure only (state-transition / edge-set / set expression as JSON); this package draws the figure and machine-verifies the answer: automaton = acceptance simulation (NFAPlot), binary relation = law-satisfaction check (Graph), set operation = exhaustive Venn-region tautology check. Generations that fail verification are discarded. Approve via `SourceVaultExerciseApproveDraft`.
Options: "LLMFn" (test seam)

### SourceVaultExerciseRebuildFigure[id] → report
Rebuilds the figure of a problem that has a FigureSpec, using the current builder (no LLM re-call) — for bulk re-render after layout tweaks. Fails with `NoFigureSpec` if absent (safe to `Scan` over a list).

### SourceVaultExerciseDrafts[subject] → {Association...}
Index of Draft-status problems.

### SourceVaultExerciseDraftsView[subject]
Dataset view of `SourceVaultExerciseDrafts`.

### SourceVaultExerciseApproveDraft[id] → <|...|>
Promotes a Draft to Active.

### SourceVaultExerciseDiscardDraft[id] → <|...|>
Discards (deletes the file of) a Draft.

## Exam Composition

### SourceVaultExamCompose[subject, spec] → exam record
Composes an exam and saves the exam record; the answer-sheet layout is fixed and stored at the same time.
Spec keys: "ExamId", "Title", "ExamName" (e.g. 中間テスト/定期考査), "Year", "DateSpec" -> {y,m,d,"曜",period}, "Groups" -> {{id...}...}, "Points", "DefaultPoints", "Duration", "Allowed".

### SourceVaultExamGet[examId] → Association
Exam record.

### SourceVaultExamList[] / SourceVaultExamList[subject] → {Association...}
Exam list, all subjects or one.

### SourceVaultExamFind[query, opts] → Association
自然言語クエリ (例: "2026年度のデータ構造とアルゴリズムの試験") から試験レコードを1件解決する。ExamId 完全一致が最優先。既定では Archived の試験 (控え・旧版) を除外し、候補が複数なら `AmbiguousExam` で失敗する。
Options: "IncludeArchived" -> False

### SourceVaultExamSetStatus[examId, status] → <|...|>
試験の状態を設定する。`status` は "Active" | "Archived"。控えの試験 (…-orig 等) を "Archived" にすると `SourceVaultExamFind` の既定検索から外れ、最終版だけが返るようになる。

### SourceVaultExamOverview[examId | query] → {Association...}
出題一覧を返す。query は `SourceVaultExamFind` で解決する。
→ keys: "Printed", "Slot", "Unit", "Field", "Headline", "Points", "Answer", "Generated", "Id".

### SourceVaultExamOverviewView[examId | query]
`SourceVaultExamOverview` の Dataset 表示 (試験名と ExamId の見出しつき)。

### SourceVaultExamSelectProblems[subject, opts] → {Id...}
Chooses candidate problem ids for composing an exam.
Options: "Units", "PerUnit", "Difficulty" -> {min,max}, "RandomSeed", "Exclude"

### SourceVaultExamSetPoints[examId, weights] → <|...,"Total"|>
Re-sets point weights. `weights` is `<|"g-n" -> points|>` or a flat list in question order.

### SourceVaultExamAnswerKey[examId] → <|"問1-1"->"3",...|>
Model-answer association (compatible with 模範解答.wl format).

### SourceVaultExamRecordHistory[examId] → report
Marks the exam as administered: stamps each problem's ExamHistory with year/exam name/question number/points.

### SourceVaultExamSlots[examId] → <|"1-1"->Id,...|>
Slot number → problem Id lookup (avoids hand-typing ids).

### SourceVaultExamRepairSlots[examId, opts] → report
Replaces slots flagged by `SourceVaultExamAudit` (missing question/choices/answer, missing record) with an unused, healthy problem from the same subject. Point values and layout keys are unchanged.
Options: "Slots" -> Automatic | {"1-21",...}

### SourceVaultExamAudit[examId] → {Association...}
Per-slot check for missing question/choices/answer.
→ keys: "Slot", "Id", "Issues" ("NoQuestion" | "NoChoices" | "NoAnswer" | "NotFound"), "Headline".

### SourceVaultExamAuditView[examId]
Dataset view of `SourceVaultExamAudit`.
Options: "OnlyIssues" -> True (only problem slots; False for all rows)

### SourceVaultExamValidateFigures[examId] → {Association...}
Re-verifies generated (FigureSpec-bearing) problems currently in the exam.
→ keys: "Slot", "Id", "Recipe", "OK", "Reason", "Hits" (machine-computed correct choice numbers regardless of pass/fail — useful for cross-checking against a hand-read answer sheet). Use after strengthening the verifier to re-check existing problems.

### SourceVaultExamValidateFiguresView[examId]
Dataset view of `SourceVaultExamValidateFigures`.
Options: "OnlyFailures" -> True (NG rows only)

### SourceVaultExamVerifyText[examId, opts] → {Association...}
For text-choice problems, independently re-asks the LLM "does this choice work as the answer?" per choice, and checks that exactly one choice qualifies.
→ keys: "Slot", "Id", "Answer", "Reported", "OK", "Negative" (whether it's a "which is NOT appropriate"-style negative question), "Notes" (per-choice rationale — verifier can be wrong; owner makes the final call), "Headline". Problems that can't be judged from text alone are skipped as Missing[reason] ("NeedsFigure" | "NotTextChoices" | "NoQuestionText" | "NoAnswer" | "NotFound") — figure problems are handled by `SourceVaultExamValidateFigures`.
Options: "LLMFn", "Slots", "PerChoice" -> True (False asks once per problem — faster, but misses some cases)

### SourceVaultExamVerifyTextView[examId]
Dataset view of `SourceVaultExamVerifyText`.
Options: "OnlyFailures" -> True (default: NG rows only, e.g. multiple valid answers; False for all)

### SourceVaultExamSimilarPairs[examId, opts] → {Association...}
Finds pairs of problems that are too similar within an exam (no LLM). Matches on (1) fingerprint (recipe+task) equality and (2) character-bigram Jaccard similarity of body+choices.
→ keys: "SlotA", "SlotB", "Score", "SameForm", "Signature", "HeadlineA", "HeadlineB".
Options: "Threshold" -> 0.6

### SourceVaultExamSimilarPairsView[examId]
Dataset view of `SourceVaultExamSimilarPairs`.

### SourceVaultExamDedupeSlots[examId, opts] → report
Groups too-similar problems into connected components, keeps one per group, and reverts the rest to their original problems (diversity is restored since originals are spread across all syllabus units).
Options: "Threshold" -> 0.6, "Apply" -> True (False: report affected slots without reverting)

### SourceVaultExamSetSlot[examId, slot, id] → <|...|>
Manually replaces the problem at a slot (e.g. "2-2") with any problem id in the DB. Point values and answer-sheet layout keys unchanged — for swapping out a flawed original problem.

### SourceVaultExamRevertSlots[examId, slots] → report
Reverts given slots (list like {"1-26",...}, or `All`) to their PreviousGroups original problem. Points/layout keys unchanged. Draft records of the reverted similar problems remain (discard separately via `SourceVaultExerciseDiscardDraft`).

### SourceVaultExamReplaceWithSimilar[examId, opts] → report
Generates LLM similar problems for each exam problem (saved as Draft) and swaps a given fraction of slots for them. Points and answer-sheet layout are preserved; the original composition is saved to the exam record's PreviousGroups. Targets: no-image choice problems + figure-recipe problems (automaton/binary-relation graphs get structure generation + NFAPlot/Graph drawing + machine-verified answers). Other figure problems and written-response problems stay as originals.
Options: "Fraction" -> 0.7 (0 = no LLM call, exam stays original), "RandomSeed", "Slots" -> All | {"1-26",...} (limit target slots), "LLMFn", "GenerateForAll" (True = also generate Draft stock for slots outside the swap target; only effective when Fraction>0), "DuplicateThreshold" -> 0.6 (a generation matching another slot's form (recipe+task) or with too-similar body text is rejected and the original kept; reason recorded in FailureReasons as DuplicateForm/DuplicateText — figure problems are distinguished by figure not body text so text similarity doesn't reject them; automatons are deduped via language fingerprint (AvoidSpecs) instead, exempt from this threshold), "Variant" (owner-specified task variant: SortTrace: swaps|insertion|selection|quick / BinaryTree: preorder|inorder|postorder / GraphAlgo: shortest|mst|bfs|dfs / StackQueue: Stack|Queue — forces the variant unconditionally even if already used, so combine with "Slots")

### SourceVaultExamPaperPDF[examId, outPath, opts] → report
Generates the question-paper PDF (【g-n】 two-column layout, FE required). Header overlays `$SourceVaultExamTemplatePDF` (official blank). Multi-page export goes through Notebook printing, falling back to per-page files on failure (reported via "ExportMode").
Options: "Resolution", "ColumnWidth", "Explanation"

### SourceVaultExamProblemPreview[examId, slot]
Renders a single slot exactly as it will appear on the question paper (layout check).
Options: "Wide" -> False (True for full-width, non-column layout)

### SourceVaultExamAnswerSheetPDF[examId, outPath, opts] → report
Generates the answer-sheet PDF. Header overlays `$SourceVaultExamTemplatePDF`. Layout matches the exam record's SheetLayout exactly (shared with grading crop-out).
Options: "GroupLabels" -> Automatic (Automatic: omit group labels [1][2] when numbering is continuous; True/False force show/hide)

### SourceVaultExamSetNumbering[examId, "Continuous" | "Group"] → <|...|>
Sets how question numbers are printed. "Continuous" = one running sequence 1..N across all groups (affects both papers); "Group" = per-group (question paper 1-4 / answer sheet 4, the legacy scheme). Internal slot keys, points, answer key, and grading crop coordinates never change.

### SourceVaultExamNumbering[examId] → {Association...}
Slot key ↔ printed number mapping.
→ keys: "Slot", "Printed", "Points".

### SourceVaultExamNumberingView[examId]
Dataset view of `SourceVaultExamNumbering`.

### SourceVaultExamSheetLayout[examId] → Association
Answer-sheet layout (PageSize, answer-cell rectangles, student-ID/name rectangles).

## Grading

### SourceVaultExamRosterImport[path, opts] → {{studentId, name}...}
Reads a roster (xls/xlsx).
Options: "HeaderRows" -> 6, "IDColumn" -> 2, "NameColumn" -> 3

### SourceVaultExamSheetIngest[examId, pdfPathOrImages, opts] → report
Ingests and saves collected answer sheets (multi-page PDF or image list). PL 1.0, local only.
Options: "Roster", "ImageWidth" -> 2200

### SourceVaultExamMatches[examId, opts] → {{number, {idImage, nameImage}, roster}...}
Core answer-sheet-to-roster match data.
Options: "DiffX", "DiffY" (crop calibration)

### SourceVaultExamMatchView[examId, opts]
Owner-verification view of the matching (scanned ID/name images side-by-side with roster). Always visually confirm before proceeding.
Options: same as `SourceVaultExamMatches`.

### SourceVaultExamSetMatch[examId, <|scanNumber -> rosterNumber|>] → <|...|>
Corrects a match assignment.

### SourceVaultExamRecognize[examId, opts] → report
Reads answers from each sheet's answer-cell regions (personal-info regions excluded by crop). Default recognizer is cloud vision (ClaudeQueryBg).
Options: "RecognizerFn" (test seam; `fn[crop, keys] -> Association`), "Scans" -> All | {i...}

### SourceVaultExamSetAnswer[examId, scanIdx, key, value] → <|...|>
Manually corrects a recognized answer (key like "1-1").

### SourceVaultExamSetMark[examId, scanIdx, key, mark] → <|...|>
Manually sets a grading mark (○/△/×/?), overriding auto-judgment.

### SourceVaultExamScore[examId, opts] → {Association...}
Core scoring from match + recognition + answer key + points. ○ = full points, △ = `Ceiling[points/2]`, ×/unmarked = 0.

### SourceVaultExamScoreView[examId, opts]
Dataset view of `SourceVaultExamScore`.

### SourceVaultExamScoreReport[examId, opts]
Score report (Dataset).
Options: "Export" -> path.xlsx (local export)

## Web レポート取込

`<udb>/webreports/<講義>/` に置かれた回収フォルダ (manifest.wxf + PDF 群) を、登録名簿と結合して [Cerezo](https://github.com/transreal/Cerezo) と同一スキーマの SourceVault スナップショット (PL 1.0) へ取り込む。取込後は `CerezoCollectionView` / `CerezoAnonymizedSubmissions` / `CerezoGradeSubmissions` / `CerezoAttachGrades` / `CerezoGradeReport` が run の `sv://` URI に対してそのまま使える。

### SourceVaultCourseRosterRegister[lecture, roster, opts] → report
講義 (例 `"ald-2026"`) の名簿を登録する (PL 1.0 ローカル保存)。`roster` は `{{学籍番号,氏名}..}` / `<|id->name..|>` / xls(x) パス (opts は `SourceVaultExamRosterImport` と同じ)。学籍番号は小文字化してクラウド uid と突合する。

### SourceVaultCourseRoster[lecture] → Association | Missing
登録済み名簿レコードを返す (未登録なら Missing)。PL 1.0。

### SourceVaultCourseRosters[] → {String...}
名簿登録済みの講義一覧を返す。

### SourceVaultCourseWebReportFolders[] → {Association...}
`<udb>/webreports` 配下の回収フォルダ (manifest.wxf) 一覧を返す。

### SourceVaultCourseWebReportIngest[lecture, opts] → report
回収フォルダを名簿と結合して Cerezo と同一形式の SourceVault スナップショット (PL 1.0) へ取り込む。再実行は内容が変わった学生だけ新バージョンを作る。
Options: "ReportDescs" -> All | {"0801"...}, "Chapters" -> All, "ReportOptions" -> All, "Roster" -> Automatic, "AssignmentName" -> Automatic, "AllowMissingNames" -> False, "Folder" -> Automatic

### SourceVaultCourseWebReportRuns[] / SourceVaultCourseWebReportRuns[lecture] → {Association...}
取込済み Web レポート run の一覧 (正準 `sv://` URI 付き) を返す。PL 1.0。

### SourceVaultCourseWebReportLatestRun[lecture, reportDesc] → Association
最新 run スナップショットを返す (SnapshotRef / URI 付き)。PL 1.0。

### SourceVaultCourseWebReportView[lecture, reportDesc] / [svURI]
提出状況を表示する。[Cerezo](https://github.com/transreal/Cerezo) がロード済みなら `CerezoCollectionView` へ委譲 (同一形式)。PL 1.0。

### SourceVaultCourseWebReportGrade[lecture, reportDesc, rubric, opts] / [svURI, rubric, opts] → report
匿名化採点 (`CerezoAnonymizedSubmissions` → `CerezoGradeSubmissions`) を実行する。[Cerezo](https://github.com/transreal/Cerezo) 必須 (弱結合)。結果の `"GradeAnnotationRef"` を `CerezoAttachGrades` / `CerezoGradeReport` へ渡す。
Options: "Policy", "MissingPages", "LLMFn" 等は Cerezo 側へ透過。