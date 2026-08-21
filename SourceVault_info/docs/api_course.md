## Overview

- Exercise store per subject: ingest from problem notebooks (held-expression structural decomposition, no cell evaluation, no FE required), field/unit(syllabus-aligned)/difficulty/exam-history metadata.
- Exam composition (`SourceVaultExamCompose`) → question-paper PDF + answer-sheet PDF. Answer-sheet layout is stored as data on the exam record and shared with scanned-answer cropping (grading) — same geometry both places.
- LLM-generated similar problems (Draft → owner approval via `SourceVaultExerciseApproveDraft`). Figure problems (automaton/binary-relation/set-algebra/stack-queue/binary-tree/expr-tree/float-format/graph-algo/sort-trace/venn-diagram/regex-automaton/predicate-logic recipes) generate structure only and are machine-verified; text problems are optionally re-verified for a unique correct answer.
- Scanned-answer ingest / header verification / roster matching (owner visually verifies, or `SourceVaultExamProposeMatches` proposes from ID-crop recognition) / answer recognition / scoring / item analysis / re-weighting.
- Per-lecture enrollment registry and gradebook (履修者 / 成績簿) — separate from the exercise store, keyed by lecture code; supports importing `SourceVaultExamScore` results, Cerezo quiz totals, and Web summary-assignment totals as weighted grading items, each with a per-submission base score, a raw-to-100 conversion curve, and a per-Kind cap/weight.
- Web レポート取込: collected report folders (manifest + PDFs) are joined with the enrollment roster into a Cerezo-schema-compatible snapshot; submitted-summary PDFs can then be vision-graded against an owner-authored policy plus a handout excerpt (`SourceVaultCourseSummaryGrade`), with late-submission scoring handled separately.
- Privacy: exercise records carry no personal info → default PrivacyLevel 0.3 (cloud-eligible). Scans, matching, grading results, enrollment, and gradebook data are PL 1.0 (local only). Only answer-cell crops (and, if explicitly allowed, student-ID crops) go to cloud LLM; ID/name recognition and matching defaults to owner visual check unless a recognizer is explicitly enabled. Summary-grading vision calls go through Cerezo's anonymization seam (declared-region redaction + pseudonymization) before reaching the LLM.
- Held-expression idiom: notebook cells are parsed via `ToExpression[..., Hold]` without evaluating, then decomposed with `Hold[{a,b,...}] -> {Hold[a], Hold[b], ...}` so images/graphics/math never get rasterized or evaluated during ingest.
- Public-package defaults are environment-agnostic: `$SourceVaultExamInstructor` defaults to `""`, header/ID-crop rectangles use generic form coordinates, `SourceVaultCourseWebReportIngest`'s `"IgnoreIDs"` excludes nothing by default, and `$SourceVaultCourseSummaryLateFactor` defaults to 1.0 (no late penalty). A private extension, loaded automatically alongside this package if present, can supply real-world values for these.

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
型: String, 初期値: ""
Instructor name printed on exam papers. Public-package default is empty (environment-specific; set by the user or a private extension).

### $SourceVaultExamTemplatePDF
型: Automatic | String | None, 初期値: Automatic
Path to the official blank "試験問題・解答用紙" PDF. Automatic uses `<exercises root>/templates/試験問題・解答用紙.pdf`, falling back to a built-in drawn header if absent. None always forces the built-in drawing.

### $SourceVaultExamAllowCloudIDRecognition
型: Boolean, 初期値: False
Permission flag to send student-ID crop images to cloud vision (personal info, PL 1.0) for `SourceVaultExamProposeMatches`. Not required if a "RecognizerFn" is supplied explicitly.

### $SourceVaultCourseWebReportRoot
型: Automatic | String, 初期値: Automatic
Web レポート回収フォルダの root override。Automatic なら `<udb>/webreports` (udb = PrivateVault の親)。

### $SourceVaultCourseWebStoreRoot
型: Automatic | String, 初期値: Automatic
course 用ストア (名簿レジストリ等) の root override。Automatic なら `<PrivateVault>/coursereports`。

### $SourceVaultCourseWebPdfTextFn
型: Automatic | Function, 初期値: Automatic
PDF 本文抽出のシーム `fn[bytes]->String`。Automatic は `ImportByteArray[..., {"PDF","Plaintext"}]`。

### $SourceVaultCourseSummaryPolicyId
型: String, 初期値: "courseweb-summary-v1"
Web サマリー採点の匿名化ポリシー id (SourceVault_anonymize へ登録される)。

### $SourceVaultCourseSummaryRedactRegions
型: {Association...}, 初期値: `{<|"x1"->0., "y1"->0.90, "x2"->1., "y2"->1.|>}`
ページ画像の宣言黒塗り領域 (正規化座標・下原点)。既定は上端バンド (氏名・学籍番号の記入位置)。

### $SourceVaultCourseSummaryScoreRange
型: {Integer, Integer}, 初期値: {0, 20}
採点レンジ (10点満点+超過許容+白紙0を許容する範囲)。

### $SourceVaultCourseSummaryHandoutSpec
型: Association, 初期値: `<|"dms"-><|"Folder"->"dms","Base"->"DiscreteMathematics-"|>, "ald"-><|"Folder"->"ald","Base"->"DataStructure-and-algorithm-"|>|>`
科目接頭辞 (lecture の先頭3文字) -> `<|"Folder", "Base"|>` (Eagle の配布資料フォルダとファイル名接頭辞)。

### $SourceVaultCourseSummaryUnitOffset
型: Integer, 初期値: 0
desc の章番号 -> 授業回/配布資料番号の補正 (既定 0 = chapter がそのまま回番号。実データ: 0801 = 第8回)。

### $SourceVaultCourseSummaryLateFactor
型: Real, 初期値: 1.0
遅延提出サマリーの既定減点率 (実効点 = 素点 × 減点率)。公開版の既定は 1.0 (減点なし)。減点する場合は運用側 (私設拡張) で設定するか、`SourceVaultCourseSummarySetLateScores` の "Factor" で個別に指定する。

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
Options: "LLMFn" (test seam), "Overwrite" -> False, "MaxItems" -> All, "BatchSize" -> 15

### SourceVaultExerciseUnitAuditView[subject]
Dataset pairing syllabus topic vs. problem headlines per unit, to spot unit drift.

## Notebook Ingest

### SourceVaultExerciseIngestNotebook[nbPath, subject, opts] → report Association
Structurally ingests a problem notebook (no cell evaluation, no FE). Decomposes `excercise*={...}` assignments under "第N回" Subsubsection headers, held, into problem records. Also re-parses the syllabus text found in the notebook and (re-)registers the subject (keeping existing Title/UnitMap unless overridden).
Options: "UnitMap" -> Automatic, "SubjectTitle" -> Automatic, "DryRun" -> False, "Status" -> "Active"
→ keys: "Status", "Subject", "Notebook", "Parsed", "Ingested", "Existed", "SkippedUnparsed", "DryRun", "Units", "SyllabusUnits", "Ids".

## Similar Problem Generation

### SourceVaultExerciseGenerateSimilar[id, n, opts] → report
Generates `n` similar problems from a base problem via LLM, saved as Draft. For figure problems the LLM (or a deterministic recipe) generates structure only — recipes: Automaton, RegexAutomaton, Relation (binary relation), SetAlgebra, VennDiagram, StackQueue, BinaryTree, ExprTree, GraphAlgo, SortTrace, FloatFormat, PredicateLogic — and this package draws the figure and machine-verifies the answer (e.g. automaton = acceptance simulation via NFAPlot, binary relation = law-satisfaction check via Graph, set operation = exhaustive Venn-region tautology check). Generations that fail verification are discarded. Text (non-figure) problems can additionally be re-verified via LLM for a unique correct answer ("VerifyText"). Approve via `SourceVaultExerciseApproveDraft`.
Options: "LLMFn" -> Automatic (test seam), "AvoidSpecs" -> {} (dedup fingerprints to avoid re-generating, e.g. automaton languages), "AvoidForms" -> {}, "Variant" -> Automatic (recipe-specific task variant, e.g. "regex" forces Automaton->RegexAutomaton), "UseRecipes" -> Automatic (None = never use a figure recipe; All = force a recipe even for non-figure problems), "VerifyText" -> True, "PerChoice" -> False (per-choice vs. once-per-problem verification when VerifyText is on)

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
Options: "Units" -> All, "PerUnit" -> 2, "Difficulty" -> All (or {min,max}), "RandomSeed" -> Automatic, "Exclude" -> {}, "Status" -> "Active", "SkipIncomplete" -> True (excludes candidates with missing question/choices/answer)

### SourceVaultExamSetPoints[examId, weights] → <|...,"Total"|>
Re-sets point weights. `weights` is `<|"g-n" -> points|>` or a flat list in question order.

### SourceVaultExamAnswerKey[examId] → <|"問1-1"->"3",...|>
Model-answer association (compatible with 模範解答.wl format).

### SourceVaultExamAnswerKeyView[examId, opts]
Dataset view of the answer key: question number / slot / correct answer / points / unit / whether original or generated / headline. No personal info.
Options: "Export" -> path.xlsx

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
Options: "OnlyFailures" -> False (True for NG rows only)

### SourceVaultExamVerifyText[examId, opts] → {Association...}
For text-choice problems, independently re-asks the LLM "does this choice work as the answer?" per choice, and checks that exactly one choice qualifies.
→ keys: "Slot", "Id", "Answer", "Reported", "OK", "Negative" (whether it's a "which is NOT appropriate"-style negative question), "Notes" (per-choice rationale — verifier can be wrong; owner makes the final call), "Headline". Problems that can't be judged from text alone are skipped as Missing[reason] ("NeedsFigure" | "NotTextChoices" | "NoQuestionText" | "NoAnswer" | "NotFound") — figure problems are handled by `SourceVaultExamValidateFigures`.
Options: "LLMFn" -> Automatic, "Slots" -> Automatic, "PerChoice" -> True (False asks once per problem — faster, but misses some cases)

### SourceVaultExamVerifyTextView[examId]
Dataset view of `SourceVaultExamVerifyText`.
Options: "LLMFn" -> Automatic, "Slots" -> Automatic, "PerChoice" -> True, "OnlyFailures" -> True (default: NG rows only, e.g. multiple valid answers; False for all)

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
Generates LLM similar problems for each exam problem (saved as Draft) and swaps a given fraction of slots for them. Points and answer-sheet layout are preserved; the original composition is saved to the exam record's PreviousGroups. Targets: no-image choice problems + figure-recipe problems (structure generation + machine-verified answers, per the recipe set described under `SourceVaultExerciseGenerateSimilar`). Other figure problems and written-response problems stay as originals.
Options: "Fraction" -> 0.7 (0 = no LLM call, exam stays original), "RandomSeed" -> Automatic, "LLMFn" -> Automatic, "GenerateForAll" -> True (also generate Draft stock for slots outside the swap target; only effective when Fraction>0), "Slots" -> All | {"1-26",...} (limit target slots), "UseRecipes" -> Automatic, "VerifyText" -> True, "PerChoice" -> False, "DuplicateThreshold" -> 0.6 (a generation matching another slot's form (recipe+task) or with too-similar body text is rejected and the original kept; reason recorded in FailureReasons as DuplicateForm/DuplicateText — figure problems are distinguished by figure not body text so text similarity doesn't reject them; automatons are deduped via language fingerprint (AvoidSpecs) instead, exempt from this threshold), "Variant" -> Automatic (owner-specified task variant: SortTrace: swaps|insertion|selection|quick / BinaryTree: preorder|inorder|postorder / GraphAlgo: shortest|mst|bfs|dfs / StackQueue: Stack|Queue — forces the variant unconditionally even if already used, so combine with "Slots")

### SourceVaultExamPaperPDF[examId, outPath, opts] → report
Generates the question-paper PDF (【g-n】 two-column layout, FE required). Header overlays `$SourceVaultExamTemplatePDF` (official blank). Multi-page export goes through Notebook printing, falling back to per-page files on failure (reported via "ExportMode").
Options: "Resolution" -> 300, "ColumnWidth" -> 25, "WideSlots" -> None (force specific slots to full-width layout), "WideThreshold" -> 700 (natural content width above which a slot auto-switches to wide), "FillWide" -> True, "Explanation" -> "以下の選択問題を解き、解答用紙の回答欄に番号を記入しなさい。"

### SourceVaultExamProblemPreview[examId, slot]
Renders a single slot exactly as it will appear on the question paper (layout check).
Options: "Wide" -> False (True for full-width, non-column layout), "Resolution" -> 300, "FillWide" -> True

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
Ingests and saves collected answer sheets (multi-page PDF or image list; also accepts `sv://object/eagle-<id>`). PL 1.0, local only.
Options: "Roster" -> Automatic, "ImageWidth" -> 2200, "Lecture" -> Automatic, "VerifyHeader" -> True (runs `SourceVaultExamSheetVerify` before ingest), "DiffX" -> 0, "DiffY" -> 0

### SourceVaultExamSheetVerify[examId, pdfOrImages, opts] → {Association...}
Checks whether collected answer sheets' headers (subject/duration/date-time-period print) match the sheet generated for this exam. Ranks against every candidate exam, so answer sheets belonging to a different exam trigger `Mismatch` (checked per page, so a stray sheet mixed into the bundle is still caught). Student-ID/name regions are excluded from the compared area (print-only).
Options: "Pages" -> All | {n...}, "DiffX" -> 0, "DiffY" -> 0, "Candidates" -> Automatic, "MinScore" -> 0.4, "Tolerance" -> 0.02, "ImageWidth" -> 1200

### SourceVaultExamSheetVerifyView[examId, pdfOrImages, opts]
Owner-verification display of `SourceVaultExamSheetVerify` (expected header / actual scanned header / candidate ranking, side-by-side).
Options: same as `SourceVaultExamSheetVerify`.

### SourceVaultExamSheetIdentify[pdfOrImages, opts] → {Association...}
Ranks a scanned sheet's header against all candidate exams to identify which exam it belongs to (for resolving mixed-up bundles).
Options: same as `SourceVaultExamSheetVerify`.

### SourceVaultExamSyncRoster[examId, opts] → report
Refreshes the roster snapshot carried by already-ingested answer sheets against the current enrollment registry (use after re-distributing an enrollment CSV). Matching is keyed by student ID, so existing assignments are preserved; sheets assigned to a student no longer enrolled are listed under "UnenrolledAssignments".
Options: "Lecture" -> Automatic, "DryRun" -> False

### SourceVaultExamMatches[examId, opts] → {{number, {idImage, nameImage}, roster}...}
Core answer-sheet-to-roster match data.
Options: "DiffX" -> 0, "DiffY" -> 0 (crop calibration)

### SourceVaultExamMatchView[examId, opts]
Owner-verification view of the matching (scanned ID/name images side-by-side with roster). Always visually confirm before proceeding.
Options: same as `SourceVaultExamMatches`.

### SourceVaultExamSetMatch[examId, <|scanNumber -> rosterNumber|>] → <|...|>
Corrects a match assignment. Value can be a student ID or a roster row number; `None` clears the assignment.

### SourceVaultExamProposeMatches[examId, opts] → report
Reads each sheet's student-ID region and proposes match candidates, applying them by default (final check still via visual inspection, e.g. `SourceVaultExamAssignView`). Recognized text is fuzzy-matched to roster student IDs by edit distance; assignments are confirmed one-student-one-sheet in confidence order — conflicts, unreadable reads, or large edit distances are left unassigned in "Uncertain". Default recognizer is cloud vision (sends only the student-ID crop, never name/answer regions) and requires `$SourceVaultExamAllowCloudIDRecognition` -> True; not required if "RecognizerFn" is supplied.
Options: "RecognizerFn" -> Automatic (seam: fn[{crop...}]->{String...}), "Scans" -> All | {i...}, "Apply" -> True, "Overwrite" -> False, "BatchSize" -> 8, "MaxDistance" -> 2, "DiffX" -> 0, "DiffY" -> 0

### SourceVaultExamMatchStatus[examId] → Association
Matching progress: assigned/unassigned answer sheets, duplicate assignments, roster students with no sheet, and assignments not present in the roster.

### SourceVaultExamAssignView[examId, opts]
FE view for assigning answer sheets to roster entries by clicking, next to the scanned student-ID/name crops. Sheets arrive in submission order (not roster order), so each is confirmed by eye; already-assigned students drop out of the candidate list, and duplicates/unassigned surface at the top.
Options: "DiffX" -> 0, "DiffY" -> 0, "Unassigned" -> False (True for unassigned only), "Uncertain" -> False (True for rows where the recognized read didn't exactly match), "MaxRows" -> 60

### SourceVaultExamRecognize[examId, opts] → report
Reads answers from each sheet's answer-cell regions (personal-info regions excluded by crop). Default recognizer is cloud vision (ClaudeQueryBg).
Options: "RecognizerFn" -> Automatic (test seam; `fn[crop, keys] -> Association`), "Scans" -> All | {i...}

### SourceVaultExamSetAnswer[examId, scanIdx, key, value] → <|...|>
Manually corrects a recognized answer (key like "1-1").

### SourceVaultExamSetMark[examId, scanIdx, key, mark] → <|...|>
Manually sets a grading mark (○/△/×/?), overriding auto-judgment. Pass `None` to clear the manual override and fall back to auto-judgment.

### SourceVaultExamUnresolved[examId, opts] → {Association...}
Core: lists questions whose grading mark is not yet settled (?) — a blank/unrecognized answer cell, or a missing model answer. Each row: scan number, student, slot, printed number, recognized value, model answer, points.
Options: "Filter" -> "Unresolved" (default) | "Wrong" (also include ×) | All, "Scans" -> All

### SourceVaultExamResolveView[examId, opts]
FE view for settling unresolved questions by clicking, next to each answer-cell crop. Picking a value re-checks it against the model answer to set ○/×; ○/△/× can also be set directly (△ = `Ceiling[points/2]`).
Options: "Filter" -> "Unresolved", "Scans" -> All, "MaxRows" -> 40, "DiffX" -> 0, "DiffY" -> 0

### SourceVaultExamItemAnalysis[examId, opts] → {Association...}
Core per-question correct-rate, wrong-answer-spread, and discrimination analysis (PL 1.0 — question-level aggregates only, no per-student data).
→ each row: Slot, Printed, Unit, Headline, Generated, Recipe, Points, Answered, Correct, CorrectRate, Blank, WrongCounts, WrongSpread, EffectiveChoices, TopDistractor, TopShare, Discrimination. WrongSpread is the normalized entropy of the wrong-answer distribution (1 = evenly spread / guessing, 0 = concentrated on one distractor); EffectiveChoices is the corresponding "effective number of distractors" implied by that entropy. Discrimination is the point-biserial correlation between correctness on this item and total score.
Options: "Scans" -> All, "Assigned" -> True (assigned sheets only)

### SourceVaultExamItemAnalysisView[examId, opts]
Dataset view of `SourceVaultExamItemAnalysis` (Japanese headings).
Options: "SortBy" -> "Rate" (ascending correct rate, default) | "Slot" | "Discrimination", "Export" -> path.xlsx

### SourceVaultExamScore[examId, opts] → {Association...}
Core scoring from match + recognition + answer key + points. ○ = full points, △ = `Ceiling[points/2]`, ×/unmarked = 0.

### SourceVaultExamScoreView[examId, opts]
Dataset view of `SourceVaultExamScore`.

### SourceVaultExamScoreReport[examId, opts]
Score report (Dataset).
Options: "Export" -> None (path.xlsx for local export)

### SourceVaultExamAnswers[examId, opts] → {Association...}
Core: per-scan read-out (PL 1.0). Each row: Scan, StudentID, Name, Answers (slot -> recognized value), Marks, Total, Unresolved.
Options: "Scans" -> All | {i...}, "Assigned" -> False (True for matched sheets only)

### SourceVaultExamAnswersView[examId, opts]
Dataset view (rows=student, columns=question number, values=recognized answer).
Options: "Marks" -> False (True to show ○/△/×/? grading marks instead), "Assigned" -> False, "Scans" -> All, "Export" -> path.xlsx

## Enrollment (履修者)

Per-lecture enrollment registry, independent of the exercise store. All data here is PL 1.0 (personal info).

### SourceVaultCourseEnrollmentRegister[lecture, sources, opts] → report
Registers course enrollment (PL 1.0, local). `sources`: csv/xls(x) path, `sv://object/eagle-<id>` (csv inside Eagle), `{{studentId,name}...}`, `<|id->name|>`, or a list of these (multiple files merge into one roster). CSV defaults to column 1 = student ID, column 2 = name; header/blank rows are auto-detected (override with "HeaderRows"). Default "Mode"->"Replace" treats the given set as the complete roster and marks students not included as Withdrawn (not deleted; re-registering restores them). "Reset"->True discards all prior registrations first (for cleaning up after registering the wrong course's roster by mistake; history is preserved).
Options: "IDColumn" -> 1, "NameColumn" -> 2, "HeaderRows" -> Automatic, "Encoding" -> Automatic, "Mode" -> "Replace" | "Add", "DryRun" -> False, "Reset" -> False

### SourceVaultCourseEnrollment[lecture, opts] → {Association...}
Core: enrollment rows `<|"StudentID","StudentName","Status",...|>`.
Options: "Status" -> "Enrolled" (default) | "Withdrawn" | All

### SourceVaultCourseEnrollmentView[lecture, opts]
Dataset view of `SourceVaultCourseEnrollment`.
Options: same as `SourceVaultCourseEnrollment`.

### SourceVaultCourseEnrollmentRecord[lecture] → Association | Missing
Full enrollment record (Students / Version / History).

### SourceVaultCourseEnrollmentHistory[lecture] → {Association...}
Registration history (per-version Added / Removed / Restored / Sources).

### SourceVaultCourseEnrollmentHistoryView[lecture]
Dataset view of `SourceVaultCourseEnrollmentHistory`.

### SourceVaultCourseEnrollments[] → {Association...}
Lectures with a registered enrollment (count, version, last update).

### SourceVaultCourseSetEnrollmentStatus[lecture, idOrIds, status] → <|...|>
Manually corrects enrollment status. `status`: "Enrolled" | "Withdrawn".

### SourceVaultCourseStudent[lecture, id] → Association | Missing
Looks up an enrollment record by student ID (normalizes notation variants).

## Gradebook (成績簿)

### SourceVaultCourseAssessmentRegister[lecture, itemId, spec] → Association
Registers a grading item (final exam, report, quiz, etc.). Re-registering an existing itemId updates its spec while keeping any scores already entered.
Spec keys: "Title", "Kind" -> "Exam" | "Report" | "Quiz" | "Other", "MaxScore", "Weight", "Source", "Note"

### SourceVaultCourseAssessments[lecture] → {Association...}
Registered grading items (max score, weight, number of scores entered).

### SourceVaultCourseAssessmentsView[lecture]
Dataset view of `SourceVaultCourseAssessments`.

### SourceVaultCourseAssessmentRemove[lecture, itemId] → <|...|>
Deletes a grading item along with its entered scores.

### SourceVaultCourseSetScores[lecture, itemId, scores, opts] → report
Enters raw scores. `scores`: `<|studentId->score|>` or `{{studentId,score}...}`. Students not in the roster are reported under "Unknown" and not entered.
Options: "Mode" -> "Merge" (default, overlays onto existing) | "Replace" (replaces the whole set), "Counts" -> Automatic (`<|studentId->submission count|>`, entered under the same Mode; feeds Gradebook's per-submission "BaseScore")

### SourceVaultCourseImportExamScores[lecture, examId, opts] → report
Imports `SourceVaultExamScore` results as a grading item (item id defaults to `examId`, Kind "Exam", MaxScore defaults to the exam's total points; each graded student's submission count is 1, used by Gradebook's per-Kind "BaseScore"). Scans without a confirmed match are skipped and listed under "Unassigned".
Options: "ItemId" -> Automatic, "Title" -> Automatic, "Weight" -> Automatic, "MaxScore" -> Automatic, "Mode" -> "Replace"

### SourceVaultCourseImportCerezoQuizScores[lecture, opts] → report
Imports CerezoExamIngest-processed quiz totals as a grading item (Kind "Quiz"; student total = sum of each quiz's Total across all rounds, unattempted rounds count as 0; also imports each student's submission count = number of rounds with a numeric score, used by Gradebook's "BaseScore"). MaxScore defaults to the sum of each quiz's max total. Cerezo.wl required (weak coupling).
Options: "Selector" -> Automatic (default = the lecture name), "ItemId" -> "cerezoquiz", "Title" -> "小テスト", "Weight" -> Automatic, "MaxScore" -> Automatic, "Mode" -> "Replace"

### SourceVaultCourseImportSummaryScores[lecture, opts] → report
Imports Web-summary assignment totals (from `SourceVaultCourseSummaryScores`, late-effective scores included) and each student's submission count as a grading item (Kind "Report"). MaxScore defaults to `10 * (number of graded rounds)`. Combine with `SourceVaultCourseImportExamScores` via `SourceVaultCourseGradebookView` / `SourceVaultCourseSetWeights`.
Options: "ItemId" -> "websummary", "Title" -> "サマリー課題", "Weight" -> Automatic, "MaxScore" -> Automatic, "Mode" -> "Replace", "Descs" -> Automatic

### SourceVaultCourseWeights[lecture] → Association
Overall-grade weight association `<|itemId->weight|>` (auto-generated from registered items; unset items default to 1). Edit and pass to `SourceVaultCourseSetWeights` to update.

### SourceVaultCourseSetWeights[lecture, weights] → <|...|>
Updates overall-grade weights. `weights`: `<|itemId->weight|>` (a partial update is fine). An unknown itemId is rejected. Scores are untouched, so weights can be revised repeatedly once all grades are in.

### SourceVaultCourseGradebook[lecture, opts] → {Association...}
Core: score table across all grading items plus the overall grade (PL 1.0). List-valued options are given per Kind in order {Exam, Summary, Quiz} (a 4th entry covers Other; a single scalar applies to all Kinds).
Formula: `Adjusted_i = Score_i + Counts_i * BaseScore_k` (Counts = the item's registered submission count; an Exam item counts 1 per graded student). `Converted_i = Clip[Curve_k[Adjusted_i], {0, 100*Cap_k}]`. `Contribution_i = Weight_i/ΣWeight * Converted_i`. Kind component (test/summary/quiz[/other]) = `TotalScale * (sum of that Kind's contributions)`. `Total = Min[TotalCap, TotalScale*ΣContribution_i + TotalBaseScore]`.
"Curve" semantics: None = `100*Adjusted/MaxScore` (default); a number s = linear ×s; a list of `{score,converted}` points = least-squares fit (a line for 2 points, quadratic `NonlinearModelFit[pts, p x^2+q x+r, {p,q,r}, x]` for 3+); a FittedModel / pure function / InterpolatingFunction / single-variable expression (e.g. a `Fit[]` result) is applied directly as the 0-100 value (not divided by MaxScore).
Rows: Scores (raw), Counts (submission counts), Adjusted (raw+base), Converted (0-100), Contributions, Components (`<|test,summary,quiz[,other]|>`), MissingItems, WeightUsed, Total.
Options: "BaseScore" -> {0,0,0} (per-submission base points, per Kind), "Curve" -> None (per Kind, see above), "Cap" -> {1,1,1} (per-Kind Converted-score cap = 100×value; None = no cap; floor 0), "Weight" -> Automatic (per-Kind balance {wE,wS,wQ}, normalized to sum 1; Automatic = `SourceVaultCourseSetWeights` item weights, split by max-score ratio within a Kind), "TotalBaseScore" -> 0, "TotalScale" -> 1, "TotalCap" -> 100 (None = no cap), "Missing" -> "Zero" (default; ungraded item scores 0 and keeps its weight) | "Exclude" (drops that item's weight instead), "Status" -> "Enrolled" (default) | All, "Round" -> 1

### SourceVaultCourseGradebookView[lecture, opts]
Dataset view of `SourceVaultCourseGradebook` (PL 1.0). Columns: StudentID, StudentName, Status, each item's raw score (pre-conversion), test/summary/quiz (Kind-level converted contribution × TotalScale; an "other" column is added if an Other-kind item exists), Total (= test+summary+quiz(+other) + TotalBaseScore, clipped by TotalCap). Rows whose rounded Total is below "FailBelow" get "FailBackground". Default `MaxItems`->{All,All} shows every row/column without scrolling. Excel export of the same table: `SourceVaultCourseGradebookExport`.
Options: same as `SourceVaultCourseGradebook`, plus "TotalRound" -> 0 (round-half-up digit count for the Total column; None = unrounded core value), "FailBelow" -> None (no highlighting), "FailBackground" -> LightRed, "MaxItems" -> {All, All}

### SourceVaultCourseGradebookExport[lecture, path, opts] → <|"Status","Exported","Rows","Columns","FailRows"|>
Exports the same table/columns/rounding as `SourceVaultCourseGradebookView` to Excel (format inferred from the extension). Row 1 = column headers; cell background colors are not exported. PL 1.0.
Options: same as `SourceVaultCourseGradebookView`

### SourceVaultCourseGradeReport[lecture, opts]
Grade report (Dataset, Japanese headings): each item's raw score + test/summary/quiz post-conversion contributions + missing items + overall grade.
Options: "Export" -> None (path.xlsx for local export), plus options shared with `SourceVaultCourseGradebook`

### SourceVaultCourseStudentScoreView[lecture, studentId, opts]
Per-student report card: Web-summary rounds (with late effective scores), Cerezo quiz rounds (raw/max, weak coupling), gradebook items (raw score / submission count / adjusted / max / converted / weight / contribution — non-default BaseScore/Curve/Cap/Weight/Total settings are shown in the header), and the weighted overall grade. PL 1.0.
Options: same as `SourceVaultCourseGradebook` ("BaseScore"/"Curve"/"Cap"/"Weight" as {Exam, Summary, Quiz} lists, "TotalBaseScore"/"TotalScale"/"TotalCap", "Missing", "Round")

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
回収フォルダを名簿と結合して Cerezo と同一形式の SourceVault スナップショット (PL 1.0) へ取り込む。名簿結合は履修取消 (Withdrawn) も含む全登録履歴で行う (成績 View/成績簿は Enrolled のみ)。除外対象アカウントは "Ignored" に報告する。除外条件は "IgnoreIDs" で指定する (公開版の既定 Automatic は除外なし; 具体的な除外パターンは運用側または非公開拡張が設定する)。再実行は内容が変わった学生だけ新バージョンを作る。
Options: "ReportDescs" -> All | {"0801"...}, "Chapters" -> All, "ReportOptions" -> All, "Roster" -> Automatic, "AssignmentName" -> Automatic, "AllowMissingNames" -> False (True で名簿外提出者を氏名なしで取込), "IgnoreIDs" -> Automatic | None | {id...} | predicate, "Folder" -> Automatic

### SourceVaultCourseWebReportRuns[] / SourceVaultCourseWebReportRuns[lecture] → {Association...}
取込済み Web レポート run の一覧 (正準 `sv://` URI 付き) を返す。PL 1.0。

### SourceVaultCourseWebReportLatestRun[lecture, reportDesc] → Association
最新 run スナップショットを返す (SnapshotRef / URI 付き)。PL 1.0。

### SourceVaultCourseWebReportView[lecture, reportDesc] / [svURI]
提出状況を表示する。[Cerezo](https://github.com/transreal/Cerezo) がロード済みなら `CerezoCollectionView` へ委譲 (同一形式)。PL 1.0。

### SourceVaultCourseWebReportGrade[lecture, reportDesc, rubric, opts] / [svURI, rubric, opts] → report
匿名化採点 (`CerezoAnonymizedSubmissions` → `CerezoGradeSubmissions`) を実行する。[Cerezo](https://github.com/transreal/Cerezo) 必須 (弱結合)。結果の `"GradeAnnotationRef"` を `CerezoAttachGrades` / `CerezoGradeReport` へ渡す。
Options: "Policy" -> Automatic, "MissingPages" -> "Fail", "TargetLevel" -> Automatic, "GrantRef" -> None, "Force" -> False, "LLMFn" -> Automatic (すべて Cerezo 側へ透過)

### SourceVaultCourseWebReportOpenSubmission[lecture, reportDesc, studentId, opts] → path
取込済み提出レポート (blob) を一時ファイルへ復元して SystemOpen で開き、パスを返す。PL 1.0。
Options: "Open" -> True (False なら復元のみで開かない)

## Web サマリー課題の匿名化 vision 採点

取込済み Web レポート run (Cerezo 同一形式) を、評価ポリシー (`SourceVaultCourseSummaryPolicyRegister` で登録した sv:// snapshot) + 配布資料サマリー (Eagle, 弱結合) を組んだ rubric で匿名化採点する。PDF はページ画像化 + 宣言領域黒塗り (プロンプト注入対策として本文テキストは LLM へ渡さず、画像の vision OCR で採点させる)。Cerezo.wl の匿名化採点シームへ弱結合委譲。遅延提出は別記録 (`SourceVaultCourseSummarySetLateScores`) で扱い、通常採点より優先される。

### SourceVaultCourseSummaryDefaultPolicyText[] → String
既定の評価ポリシー本文 (10点満点・白紙/単元違い打ち切り・スキャン品質2点・充実度5〜10点)。

### SourceVaultCourseSummaryPolicyRegister[policyText, opts] → report
評価ポリシーを不変 snapshot (class `CourseSummaryGradingPolicy`, alias latest, PL 0.3) として登録し sv:// URI を返す。`policyText` 省略時 (Automatic) は既定文 (`SourceVaultCourseSummaryDefaultPolicyText[]`)。
Options: "MaxScore" -> 10, "ScoreRange" -> Automatic (falls back to `$SourceVaultCourseSummaryScoreRange`)

### SourceVaultCourseSummaryPolicy[] / SourceVaultCourseSummaryPolicy[svURI] → Association
登録済み評価ポリシー (省略形は latest) を URI 付きで返す。

### SourceVaultCourseSummaryGrade[lecture, reportDesc, opts] → report
取込済み run を匿名化 vision 採点する (Cerezo.wl 必須)。rubric = 評価ポリシー + 該当回の配布資料サマリー (Eagle)。"GrantRef"->Automatic (既定) なら plan->承認要求->ApproveDeclassification を自動実行して grant を発行する (Approve は FE 対話限定 = オーナーの実行が承認意思。headless では拒否)。結果 (GradeAnnotationRef) は registry に保存され View が参照する。
Options: "PolicyURI" -> Automatic, "MissingPages" -> "Fail" | "Skip", "LLMFn" -> Automatic, "Force" -> False, "HandoutText" -> Automatic, "GrantRef" -> Automatic | grant, "MaxExecuteUses" -> 10

### SourceVaultCourseSummaryGradeAll[lecture, opts] → report
取込済み全回を順に採点する。skip されるのは全員パース成功済みの回のみで、途中失敗 (usage limit 等で ParsedCount < ItemCount) や全滅の回は再実行時に自動でやり直す (回単位の冪等。学生単位の途中再開はしない)。
Options: `SourceVaultCourseSummaryGrade` のオプション全部, "Regrade" -> False (True で全回再採点)

### SourceVaultCourseSummaryGrades[lecture] → Association
採点 registry (`<|reportDesc-><|AnnotationRef,GradedAtUTC,ItemCount,ParsedCount,..|>|>`) を返す。

### SourceVaultCourseSummarySetLateScores[lecture, studentId, scores, opts] → report
遅延提出サマリーの点数を記録する (`scores` のキーは回番号 3 または desc "0301")。実効点 = 素点 × 減点率で View/合計/成績簿取込に反映され、通常採点より優先。値 `None` でその回の記録を削除。PL 1.0。
Options: "Factor" -> Automatic (falls back to `$SourceVaultCourseSummaryLateFactor`, 既定は減点なしの 1.0), "Note" -> ""

### SourceVaultCourseSummaryLateScores[lecture] → Association
遅延提出の記録 (`<|学籍番号キー-><|desc-><|Score,Factor,Effective,Note,RecordedAtUTC|>|>|>`) を返す。PL 1.0。

### SourceVaultCourseSummaryScores[lecture, opts] → {Association...}
履修者×各回の点数表 (core, PL 1.0) を返す。未提出・未採点回は 0。遅延記録があればその実効点を優先。行に SubmittedDescs (提出のあった回 = 取込 run で Submitted / 採点行あり / 遅延記録あり) と Submitted (件数) を含む。
Options: "Descs" -> Automatic (既定は採点済み+遅延記録済みの全回)

### SourceVaultCourseSummaryScoreView[lecture, reportDesc]
各回サマリー課題の Dataset 表示 (学籍番号/氏名/提出/点数/採点根拠。PL 1.0)。提出/遅延セルは保存済み提出物があればリンクになり、クリックで PDF を一時復元して開く。

### SourceVaultCourseSummaryTotalsView[lecture, opts]
全回の点数と合計の Dataset 表示 (採点根拠なし。PL 1.0)。
Options: "Descs" -> Automatic

Configuration notes for this section: `$SourceVaultCourseSummaryPolicyId`, `$SourceVaultCourseSummaryRedactRegions`, `$SourceVaultCourseSummaryScoreRange`, `$SourceVaultCourseSummaryHandoutSpec`, `$SourceVaultCourseSummaryUnitOffset`, `$SourceVaultCourseSummaryLateFactor` (see Config Variables above).