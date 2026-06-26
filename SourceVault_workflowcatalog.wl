(* ::Package:: *)

(* ============================================================
   SourceVault_workflowcatalog.wl -- 仕様生成と実装を束ねる
   "Workflow Catalog" オブジェクト + テスト中/運用中の stage 管理 +
   横断検索 provider + 一覧 UI。

   This file is encoded in UTF-8.
   Load: SourceVault.wl の auto-load から SourceVault_workflowregistry.wl の
   直後に Get される (registry の公開 API に依存する)。

   背景:
   仕様生成 (orch/<project>/{requirements,spec,review}) と実装
   (impl/<slug>/{plan,artifact,verify} + SourceVault_workflows/<slug>/) は
   従来別々の pointer チェーンに分散し、両者を束ねる単一オブジェクトが無かった。
   本ファイルはそれを束ねる "Workflow Catalog Record" を SourceVault の
   immutable snapshot (class "WorkflowCatalog", pointer workflow/<slug>/catalog)
   として追加し、Status (testing|production)・Summary・キーワード・仕様 URI・
   仕様策定/実装時の $ClaudeModel/$ClaudeAdvisaryModel ペアを保持する。

   stage の真実源はフォルダ位置 (registry の testing/<slug> | production/<slug>)。
   Status を切り替えるとフォルダを移動する (slug はグローバル一意)。

   公開関数:
     SourceVaultWorkflowStatus[slug]                 -- "system"|"testing"|"production"
     SourceVaultSetWorkflowStatus[slug, stage]       -- フォルダ移動 + レコード更新
     SourceVaultPromoteWorkflow[slug]                -- -> production
     SourceVaultDemoteWorkflow[slug]                 -- -> testing
     SourceVaultWorkflowCatalogRecord[slug]          -- 束ねレコードを読む
     SourceVaultRegisterWorkflowCatalog[slug, assoc] -- 束ねレコードを保存/更新
     SourceVaultWorkflowCatalog[]                    -- 束ねオブジェクト一覧 (Dataset)
     SourceVaultWorkflowSummarize[slug]              -- 仕様から Summary 生成しレコードへ保存
     SourceVaultWorkflowSummarizeText[spec, m1, m2]  -- 仕様テキスト+モデルペアから要約 (純関数)
     SourceVaultWorkflowPanel[]                      -- 一覧+起動+stage切替+検索 UI
     SourceVaultMigrateWorkflowsToStages[]           -- 既存ルート直下を testing/production へ移行
   ============================================================ *)

BeginPackage["SourceVault`"]

SourceVaultWorkflowStatus::usage =
  "SourceVaultWorkflowStatus[slug] は slug の現在 stage (\"system\" | \"testing\" | \"production\" | \"archive\") を \
フォルダ位置から返す (見つからなければ Missing)。";

SourceVaultSetWorkflowStatus::usage =
  "SourceVaultSetWorkflowStatus[slug, stage] は生成ワークフロー slug を stage \
(\"testing\" | \"production\" | \"archive\") のフォルダへ移動し、束ねレコードの Status を更新する。\
slug がシステムワークフロー (root) の場合は移動しない。archive は通常一覧・横断検索に現れない。";

SourceVaultPromoteWorkflow::usage =
  "SourceVaultPromoteWorkflow[slug] は slug を運用中 (production) へ昇格させる \
(= SourceVaultSetWorkflowStatus[slug, \"production\"])。";

SourceVaultDemoteWorkflow::usage =
  "SourceVaultDemoteWorkflow[slug] は slug をテスト中 (testing) へ戻す \
(= SourceVaultSetWorkflowStatus[slug, \"testing\"])。";

SourceVaultWorkflowCatalogRecord::usage =
  "SourceVaultWorkflowCatalogRecord[slug] は slug の束ねレコード (Workflow Catalog) を返す \
(無ければ Missing[\"NoCatalog\"])。";

SourceVaultRegisterWorkflowCatalog::usage =
  "SourceVaultRegisterWorkflowCatalog[slug, assoc] は slug の束ねレコードを assoc で更新 \
(既存とマージ) し immutable snapshot + pointer workflow/<slug>/catalog として保存する。";

SourceVaultWorkflowCatalog::usage =
  "SourceVaultWorkflowCatalog[] は生成ワークフロー (testing/production) を束ねるカタログ一覧を \
Dataset で返す (Slug/Stage/Name/Summary/Keywords/Project/SpecURI/SpecModels/ImplModels/...)。";

SourceVaultWorkflowSummarize::usage =
  "SourceVaultWorkflowSummarize[slug] は slug の仕様 (または生成物) から短い Summary + キーワードを \
生成して束ねレコードへ保存する。仕様策定/実装時のモデルペアが両方ローカルならローカル LLM、\
そうでなければクラウドで策定する (モデル未記録時はローカル既定)。";

SourceVaultWorkflowSummarizeText::usage =
  "SourceVaultWorkflowSummarizeText[specText, claudeModel, advisaryModel] は仕様テキストと \
モデルペアから <|\"Summary\",\"Keywords\",\"Method\"|> を返す純関数。両モデルがローカル \
(lmstudio) ならローカル LLM、そうでなければクラウド (ClaudeQueryBg) → ローカル → 機械抽出の順。";

SourceVaultWorkflowPanel::usage =
  "SourceVaultWorkflowPanel[] は収納済みワークフロー (archive を除く) を一覧し、起動・\
テスト/運用切替・アーカイブ送り・キーワード/サマリー検索ができる UI を返す \
(手動更新・FE フリーズ回避)。検索行の右端「アーカイブ」ボタンで \
SourceVaultWorkflowArchivePanel を別ウインドウに開く。";

SourceVaultWorkflowArchivePanel::usage =
  "SourceVaultWorkflowArchivePanel[] はアーカイブされたワークフローのみを \
SourceVaultWorkflowPanel と同じ体裁で一覧する UI を返す。切替列のボタンは \
「testingへ戻す」(SourceVaultSetWorkflowStatus[slug, \"testing\"]) になる。";

SourceVaultMigrateWorkflowsToStages::usage =
  "SourceVaultMigrateWorkflowsToStages[opts] は SourceVault_workflows/ のルート直下にある \
生成ワークフロー (システムワークフローを除く) を testing/production サブフォルダへ移行する。\
Options: \"Production\"->{slug...}, \"Testing\"->{slug...}, \"Default\"->\"testing\", \
\"SystemSlugs\"->{\"spec-review\",\"spec-impl\"}, \"Summarize\"->False。";

SourceVaultRegisterSourceNotebook::usage =
  "SourceVaultRegisterSourceNotebook[path] は notebook のメタ情報 (タイトル + PC 間移植可能な \
シンボリックパス) を SourceVault の immutable snapshot として保存し、その URI を返す \
(ファイルのパス名そのものを仕様/カタログオブジェクトに書かず URI 参照にするため)。\
保存できない (未保存等) ときは \"\" を返す。";

SourceVaultSourceNotebookPath::usage =
  "SourceVaultSourceNotebookPath[uri] は SourceVaultRegisterSourceNotebook が返した URI を \
現 PC の絶対パスへ解決して返す (見つからなければ Missing)。";

SourceVaultOpenSourceNotebook::usage =
  "SourceVaultOpenSourceNotebook[uri] は URI が指す元 notebook を開く (既に開いていれば前面化)。\
ファイルが見つからない/移動された場合は通知する。";

Begin["`WorkflowCatalogPrivate`"]

(* ============================================================
   低レベルユーティリティ
   ============================================================ *)

iSVWFReadUTF8[path_String] :=
  Quiet @ Check[ByteArrayToString[ReadByteArray[path], "UTF-8"], ""];

(* JSON は rule 30 に従い ExportByteArray/ImportByteArray 経由 (二重エンコード回避) *)
iSVWFJSONBytes[assoc_] :=
  Quiet @ Check[ExportByteArray[assoc, "RawJSON"], $Failed];

iSVWFParseJSONBytes[bytes_] :=
  Quiet @ Check[ImportByteArray[bytes, "RawJSON"], $Failed];

iSVWFNowUTC[] :=
  Quiet @ Check[
    DateString[TimeZoneConvert[Now, 0], "ISODateTime"] <> "Z",
    DateString["ISODateTime"]];

(* ---- 正準 URI <-> snapshot ref ---- *)
iSVWFURIToRef[s_String] := Which[
  StringStartsQ[s, "snapshot:"], s,
  StringStartsQ[s, "sv://snapshot/"],
    Module[{body = StringDrop[s, StringLength["sv://snapshot/"]], p},
      p = StringSplit[body, {"/", ":"}];
      If[Length[p] >= 2, "snapshot:" <> p[[1]] <> ":" <> Last[p], s]],
  True, s];
iSVWFURIToRef[x_] := x;

iSVWFRefToURI[ref_String] := Module[{p},
  p = StringSplit[ref, ":"];
  If[Length[p] >= 3 && p[[1]] === "snapshot",
    "sv://snapshot/" <> p[[2]] <> "/" <> p[[3]], ref]];
iSVWFRefToURI[x_] := ToString[x];

(* ============================================================
   元 notebook のメタ情報オブジェクト (PC 間移植可能なシンボリックパスで保存)
   仕様/カタログオブジェクトには path でなくこの URI を記録する。
   ============================================================ *)

(* SourceVault`Private` の移植パスヘルパを安全に呼ぶ (未ロードなら絶対パス fallback) *)
iSVWFSymbolicPath[path_String] :=
  If[Length[DownValues[SourceVault`Private`iSVSymbolicPath]] > 0,
    Quiet @ Check[SourceVault`Private`iSVSymbolicPath[path], {"<ABS>", path}],
    {"<ABS>", path}];

iSVWFResolveSymbolicPath[sym_] :=
  If[Length[DownValues[SourceVault`Private`iSVResolvePath]] > 0,
    Quiet @ Check[SourceVault`Private`iSVResolvePath[sym], Missing["Unresolved"]],
    If[ListQ[sym] && Length[sym] >= 2 && First[sym] === "<ABS>", sym[[2]], Missing["Unresolved"]]];

SourceVaultRegisterSourceNotebook[path_String] := Module[{abs, snap},
  abs = Quiet @ Check[ExpandFileName[path], path];
  If[! (StringQ[abs] && FileExistsQ[abs]), Return[""]];
  snap = Quiet @ Check[
    SourceVaultSaveImmutableSnapshot["WorkflowSourceNotebook",
      <|"Type" -> "WorkflowSourceNotebook",
        "Title" -> FileBaseName[abs],
        "SymbolicPath" -> iSVWFSymbolicPath[abs],
        "RegisteredAtUTC" -> iSVWFNowUTC[]|>],
    $Failed];
  If[AssociationQ[snap] && KeyExistsQ[snap, "Ref"], iSVWFRefToURI[snap["Ref"]], ""]];
SourceVaultRegisterSourceNotebook[_] := "";

SourceVaultSourceNotebookPath[uri_String] := Module[{rec, sym, p},
  If[StringTrim[uri] === "", Return[Missing["NoURI"]]];
  rec = Quiet @ Check[SourceVaultLoadImmutableSnapshot[iSVWFURIToRef[uri]], $Failed];
  If[! AssociationQ[rec], Return[Missing["Unresolved"]]];
  sym = Lookup[rec, "SymbolicPath", Missing[]];
  p = iSVWFResolveSymbolicPath[sym];
  If[StringQ[p], p, Missing["Unresolved"]]];
SourceVaultSourceNotebookPath[_] := Missing["NoURI"];

SourceVaultOpenSourceNotebook[uri_String] := Module[{p},
  p = SourceVaultSourceNotebookPath[uri];
  Which[
    ! StringQ[p],
      MessageDialog[
        "\:5143\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:306e\:5834\:6240\:3092\:89e3\:6c7a\:3067\:304d\:307e\:305b\:3093\:3067\:3057\:305f (\:672a\:8a18\:9332\:307e\:305f\:306f\:5225 PC)\:3002"];
      $Failed,
    ! FileExistsQ[p],
      MessageDialog[
        "\:5143\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:30d5\:30a1\:30a4\:30eb\:304c\:898b\:3064\:304b\:308a\:307e\:305b\:3093 (\:79fb\:52d5/\:524a\:9664\:3055\:308c\:305f\:53ef\:80fd\:6027)\:3002"];
      $Failed,
    True,
      Quiet @ Check[NotebookOpen[p, Visible -> True], $Failed]]];
SourceVaultOpenSourceNotebook[_] := $Failed;

(* ============================================================
   モデル分類 (ローカル / クラウド)
   ローカル provider は lmstudio (NBAccess の access-level 1.0)。
   ============================================================ *)

iSVWFProvider[m_] := Which[
  ListQ[m] && Length[m] >= 1 && StringQ[m[[1]]], ToLowerCase[StringTrim[m[[1]]]],
  StringQ[m],
    With[{p = Quiet @ Check[NBAccess`NBModelProviderName[m], ""]},
      If[StringQ[p], ToLowerCase[StringTrim[p]], ""]],
  True, ""];

iSVWFModelLocalQ[m_] := iSVWFProvider[m] === "lmstudio";

iSVWFModelName[m_] :=
  If[ListQ[m] && Length[m] >= 2 && StringQ[m[[2]]], m[[2]], ""];

iSVWFModelURL[m_] := Module[{u},
  u = If[ListQ[m] && Length[m] >= 3 && StringQ[m[[3]]] && m[[3]] =!= "",
    m[[3]], "http://127.0.0.1:1234"];
  Which[
    StringEndsQ[u, "/v1/chat/completions"], u,
    StringEndsQ[u, "/"], u <> "v1/chat/completions",
    True, u <> "/v1/chat/completions"]];

iSVWFLocalKey[url_String] := Module[{k},
  k = Quiet @ Check[
    If[Length[Names["NBAccess`NBGetLocalLLMAPIKey"]] > 0,
      NBAccess`NBGetLocalLLMAPIKey["lmstudio", url,
        NBAccess`PrivacySpec -> <|"AccessLevel" -> 1.0|>], $Failed], $Failed];
  If[StringQ[k] && k =!= "", k, "lm-studio"]];

(* ============================================================
   LLM 問い合わせ (ローカル LM Studio / クラウド)
   ============================================================ *)

iSVWFQueryLocal[prompt_String, modelSpec_, timeout_] :=
  Module[{url, model, reqData, bodyBytes, resp, json, content},
    url = iSVWFModelURL[modelSpec];
    model = iSVWFModelName[modelSpec];
    reqData = Join[
      <|"messages" -> {<|"role" -> "user", "content" -> prompt|>},
        "temperature" -> 0.2, "max_tokens" -> 800, "stream" -> False,
        "chat_template_kwargs" -> <|"enable_thinking" -> False|>|>,
      If[model =!= "", <|"model" -> model|>, <||>]];
    bodyBytes = iSVWFJSONBytes[reqData];
    If[bodyBytes === $Failed, Return[""]];
    resp = Quiet @ Check[URLRead[HTTPRequest[url, <|
        "Method" -> "POST",
        "Headers" -> {"Content-Type" -> "application/json; charset=utf-8",
          "Authorization" -> "Bearer " <> iSVWFLocalKey[url]},
        "Body" -> bodyBytes|>], TimeConstraint -> timeout], $Failed];
    If[! MatchQ[resp, _HTTPResponse] || resp["StatusCode"] =!= 200, Return[""]];
    json = iSVWFParseJSONBytes[Quiet @ Check[resp["BodyByteArray"], $Failed]];
    If[! AssociationQ[json], Return[""]];
    content = Quiet @ Check[json["choices"][[1]]["message"]["content"], ""];
    If[! (StringQ[content] && StringTrim[content] =!= ""),
      content = Quiet @ Check[json["choices"][[1]]["message"]["reasoning_content"], ""]];
    If[StringQ[content], StringTrim[content], ""]];

(* クラウド: claudecode の ClaudeQueryBg があれば使用、無ければローカル既定へ退避。 *)
iSVWFQueryCloudOrLocal[prompt_String, timeout_] := Module[{r},
  If[Length[Names["ClaudeCode`ClaudeQueryBg"]] > 0,
    r = Quiet @ Check[
      ClaudeCode`ClaudeQueryBg[prompt, "NonBlocking" -> True, "Timeout" -> timeout],
      $Failed];
    If[StringQ[r] && StringTrim[r] =!= "" && ! iSVWFLooksLikeLLMError[r],
      Return[StringTrim[r]]]];
  (* クラウド経路が使えない (背景カーネル等) -> ローカル既定で要約 *)
  iSVWFQueryLocal[prompt, {"lmstudio", "", "http://127.0.0.1:1234"}, timeout]];

(* LLM がエラー/利用制限本文を「正常応答」として返したのを検出 (要約として保存しない)。
   SourceVault_eagle.wl iSVEGLooksLikeLLMError と同じゲート。 *)
iSVWFLooksLikeLLMError[s_String] := Module[{head},
  head = StringTake[s, UpTo[200]];
  Or[
    StringStartsQ[StringTrim[head], "Error:"],
    StringStartsQ[StringTrim[head], "Error "],
    StringContainsQ[head, "StatusCode=" ~~ DigitCharacter ..],
    StringContainsQ[head, RegularExpression["\"error\"\\s*:\\s*\\{"]],
    StringContainsQ[head, "Model unloaded"],
    StringContainsQ[head, "internal_error"],
    StringContainsQ[head, "hit your" ~~ Shortest[___] ~~ "limit", IgnoreCase -> True],
    StringContainsQ[head, "session limit", IgnoreCase -> True],
    StringContainsQ[head, "usage limit", IgnoreCase -> True]]];
iSVWFLooksLikeLLMError[_] := False;

(* ============================================================
   要約生成 (純関数)
   ============================================================ *)

iSVWFResolveLang[lang_] := Which[
  StringQ[lang] && lang =!= "" && lang =!= "Automatic", lang,
  ListQ[$Language] && $Language =!= {} && StringQ[First[$Language]], First[$Language],
  StringQ[$Language] && $Language =!= "", $Language,
  True, "Japanese"];

iSVWFSummaryPrompt[specText_String, lang_String] :=
  "あなたはソフトウェア仕様の要約者です。次の「仕様/ワークフロー説明」を読み、検索インデックス用に\n" <>
  "(1) 2〜3 文の簡潔な要約 (このワークフローが何をするか・入力/出力・主な効果)、\n" <>
  "(2) 検索用キーワード 5〜10 個 (カンマ区切り、固有名詞・機能語中心) を作成してください。\n" <>
  "必ず " <> lang <> " で書き、他言語では書かないこと。装飾やコードは出力しないこと。\n" <>
  "出力は次の区切り形式を厳守してください:\n" <>
  "<<<SUMMARY>>>\n(ここに要約)\n<<<KEYWORDS>>>\nkw1, kw2, kw3\n<<<END>>>\n\n" <>
  "=== 仕様/説明 ===\n" <> StringTake[specText, UpTo[12000]];

iSVWFParseSummary[raw_String] := Module[{sm, kw, sPart, kPart},
  sPart = Quiet @ Check[
    First @ StringCases[raw,
      "<<<SUMMARY>>>" ~~ s___ ~~ "<<<KEYWORDS>>>" :> s, 1], ""];
  kPart = Quiet @ Check[
    First @ StringCases[raw,
      "<<<KEYWORDS>>>" ~~ k___ ~~ "<<<END>>>" :> k, 1],
    Quiet @ Check[
      First @ StringCases[raw, "<<<KEYWORDS>>>" ~~ k___ :> k, 1], ""]];
  (* 区切りが無いモデル応答へのフォールバック: 全文を要約とみなす *)
  sm = StringTrim[If[StringQ[sPart] && StringTrim[sPart] =!= "", sPart, raw]];
  sm = StringTake[sm, UpTo[1200]];
  kw = If[StringQ[kPart],
    Select[StringTrim /@ StringSplit[kPart, {",", "、", "\n"}], # =!= "" &], {}];
  kw = Take[DeleteDuplicates[kw], UpTo[12]];
  <|"Summary" -> sm, "Keywords" -> kw|>];

(* LLM 不可時の機械抽出フォールバック (H1 見出し + 冒頭本文 + 頻出語) *)
iSVWFMechanicalSummary[specText_String] := Module[{lines, h1, body, words, kw},
  lines = Select[StringTrim /@ StringSplit[specText, "\n"], # =!= "" &];
  h1 = SelectFirst[lines, StringStartsQ[#, "#"] &, ""];
  h1 = StringTrim @ StringReplace[h1, StartOfString ~~ "#" .. ~~ Whitespace... -> ""];
  body = StringTake[StringRiffle[Take[lines, UpTo[6]], " "], UpTo[300]];
  words = Select[StringSplit[specText, Except[WordCharacter] ..],
    StringLength[#] >= 2 &];
  kw = Take[Keys @ ReverseSort @ Counts[words], UpTo[8]];
  <|"Summary" -> StringTrim[If[h1 =!= "", h1 <> " — ", ""] <> body],
    "Keywords" -> kw, "Method" -> "Extract"|>];

Options[SourceVaultWorkflowSummarizeText] = {"Language" -> Automatic, "Timeout" -> 180};

SourceVaultWorkflowSummarizeText[specText_String, claudeModel_, advisaryModel_,
    opts:OptionsPattern[]] := Module[{lang, timeout, bothLocal, prompt, raw, parsed},
  If[StringTrim[specText] === "", Return[<|"Summary" -> "", "Keywords" -> {}, "Method" -> "Empty"|>]];
  lang = iSVWFResolveLang[OptionValue["Language"]];
  timeout = OptionValue["Timeout"];
  bothLocal = iSVWFModelLocalQ[claudeModel] && iSVWFModelLocalQ[advisaryModel];
  prompt = iSVWFSummaryPrompt[specText, lang];
  raw = If[bothLocal,
    iSVWFQueryLocal[prompt, claudeModel, timeout],
    iSVWFQueryCloudOrLocal[prompt, timeout]];
  If[! StringQ[raw] || StringTrim[raw] === "" || iSVWFLooksLikeLLMError[raw],
    Return[iSVWFMechanicalSummary[specText]]];
  parsed = iSVWFParseSummary[raw];
  <|"Summary" -> parsed["Summary"], "Keywords" -> parsed["Keywords"],
    "Method" -> If[bothLocal, "Local", "Cloud"]|>];

(* ============================================================
   束ねレコード (Workflow Catalog) の CRUD
   ============================================================ *)

iSVWFCatalogPointer[slug_String] := "workflow/" <> slug <> "/catalog";

(* 最新版は PointerReplay (最大 Sequence の検証済み値・cache replay) で解決する。
   "Version" は pointer の atomic な Sequence をそのまま使う (読んで +1 する方式は
   同一秒内の連続書込で read-after-write が不安定=版が重複しうるため不可)。 *)
SourceVaultWorkflowCatalogRecord[slug_String] := Module[{rep, ref, ver, rec},
  rep = Quiet @ Check[SourceVaultPointerReplay[iSVWFCatalogPointer[slug]], $Failed];
  ref = If[AssociationQ[rep], Lookup[rep, "Value", Missing[]], Missing[]];
  If[! StringQ[ref], Return[Missing["NoCatalog"]]];
  ver = If[AssociationQ[rep], Lookup[rep, "Sequence", 1], 1];
  rec = Quiet @ Check[SourceVaultLoadImmutableSnapshot[ref], $Failed];
  If[! AssociationQ[rec], Return[Missing["NoCatalog"]]];
  Append[KeyDrop[rec, {"SnapshotClass", "Digest", "StoredAtUTC", "Version"}],
    "Version" -> ver]];

SourceVaultRegisterWorkflowCatalog[slug_String, assoc_Association] :=
  Module[{prev, merged, snap, ref, upd, ver},
    prev = SourceVaultWorkflowCatalogRecord[slug];
    (* Version は snapshot に焼かず pointer Sequence 由来にする (前版の Version は捨てる) *)
    prev = If[AssociationQ[prev], KeyDrop[prev, "Version"], <||>];
    merged = Join[prev, assoc,
      <|"Slug" -> slug, "UpdatedAtUTC" -> iSVWFNowUTC[]|>];
    If[! KeyExistsQ[merged, "CreatedAtUTC"],
      merged["CreatedAtUTC"] = merged["UpdatedAtUTC"]];
    snap = Quiet @ Check[SourceVaultSaveImmutableSnapshot["WorkflowCatalog", merged], $Failed];
    If[! AssociationQ[snap] || ! KeyExistsQ[snap, "Ref"],
      Return[<|"Status" -> "SaveFailed", "Slug" -> slug|>]];
    ref = snap["Ref"];
    upd = Quiet @ Check[SourceVaultAtomicUpdatePointer[iSVWFCatalogPointer[slug], ref], $Failed];
    ver = If[AssociationQ[upd], Lookup[upd, "Sequence", 1], 1];
    Append[merged, {"Ref" -> ref, "Version" -> ver}]];

(* レコードの Status だけ更新 (無ければ最小レコードを作る) *)
iSVWFEnsureRecord[slug_String, stage_String] := Module[{rec},
  rec = SourceVaultWorkflowCatalogRecord[slug];
  SourceVaultRegisterWorkflowCatalog[slug,
    <|"Status" -> stage,
      "Name" -> If[AssociationQ[rec], Lookup[rec, "Name", slug], slug]|>]];

(* ============================================================
   stage (テスト中 / 運用中) の取得・切替
   ============================================================ *)

SourceVaultWorkflowStatus[slug_String] := Module[{folder, parentLeaf},
  folder = SourceVaultWorkflowFolder[slug];
  If[MissingQ[folder], Return[Missing["NotFound"]]];
  parentLeaf = FileNameTake[DirectoryName[folder]];
  If[MemberQ[$SourceVaultWorkflowStages, parentLeaf], parentLeaf, "system"]];

(* ディレクトリ移動 (RenameDirectory、失敗時 Copy+Delete フォールバック) *)
iSVWFMoveDir[src_String, dest_String] := Module[{r},
  r = Quiet @ Check[RenameDirectory[src, dest], $Failed];
  If[r =!= $Failed && DirectoryQ[dest], Return[True]];
  r = Quiet @ Check[
    (CopyDirectory[src, dest];
     If[DirectoryQ[dest], DeleteDirectory[src, DeleteContents -> True]; True, False]),
    $Failed];
  TrueQ[r]];

SourceVaultSetWorkflowStatus[slug_String, stage_String] := Module[
  {cur, srcFolder, destDir, destFolder, moved},
  If[! MemberQ[$SourceVaultWorkflowStages, stage],
    Return[<|"Status" -> "BadStage", "Slug" -> slug, "Requested" -> stage,
      "Allowed" -> $SourceVaultWorkflowStages|>]];
  cur = SourceVaultWorkflowStatus[slug];
  If[MissingQ[cur], Return[<|"Status" -> "NotFound", "Slug" -> slug|>]];
  If[cur === "system",
    Return[<|"Status" -> "SystemWorkflow", "Slug" -> slug,
      "Detail" -> "システムワークフロー (root) は testing/production 分類対象外"|>]];
  srcFolder = SourceVaultWorkflowFolder[slug];
  If[cur === stage,
    iSVWFEnsureRecord[slug, stage];
    Return[<|"Status" -> "Unchanged", "Slug" -> slug, "Stage" -> stage, "Path" -> srcFolder|>]];
  destDir = SourceVaultWorkflowStageDirectory[stage];
  Quiet @ CreateDirectory[destDir, CreateIntermediateDirectories -> True];
  destFolder = FileNameJoin[{destDir, slug}];
  If[DirectoryQ[destFolder],
    Return[<|"Status" -> "DestExists", "Slug" -> slug, "Path" -> destFolder|>]];
  moved = iSVWFMoveDir[srcFolder, destFolder];
  If[! moved,
    Return[<|"Status" -> "MoveFailed", "Slug" -> slug, "From" -> srcFolder, "To" -> destFolder|>]];
  iSVWFEnsureRecord[slug, stage];
  <|"Status" -> "Moved", "Slug" -> slug, "Stage" -> stage,
    "From" -> srcFolder, "To" -> destFolder|>];

SourceVaultPromoteWorkflow[slug_String] := SourceVaultSetWorkflowStatus[slug, "production"];
SourceVaultDemoteWorkflow[slug_String]  := SourceVaultSetWorkflowStatus[slug, "testing"];

(* ============================================================
   一覧 (束ねオブジェクトの Dataset)
   ============================================================ *)

iSVWFCatalogRow[wfRow_Association] := Module[{slug, rec},
  slug = wfRow["Slug"];
  rec = SourceVaultWorkflowCatalogRecord[slug];
  rec = If[AssociationQ[rec], rec, <||>];
  <|"Slug" -> slug,
    "Stage" -> Lookup[wfRow, "Stage", "system"],
    "Name" -> Lookup[rec, "Name", slug],
    "Summary" -> Lookup[rec, "Summary", ""],
    "Keywords" -> Lookup[rec, "Keywords", {}],
    "Project" -> Lookup[rec, "Project", ""],
    "SpecURI" -> Lookup[rec, "SpecURI", ""],
    "SpecModels" -> Lookup[rec, "SpecModels", <||>],
    "ImplModels" -> Lookup[rec, "ImplModels", <||>],
    "SummaryMethod" -> Lookup[rec, "SummaryMethod", ""],
    "SourceNotebookURI" -> Lookup[rec, "SourceNotebookURI", ""],
    "Loaded" -> Lookup[wfRow, "Loaded", False],
    "Context" -> Lookup[wfRow, "Context", ""],
    "Path" -> Lookup[wfRow, "Path", ""],
    "UpdatedAtUTC" -> Lookup[rec, "UpdatedAtUTC", ""]|>];

(* 生成ワークフロー (system 以外) の束ねレコード一覧 (assoc list) *)
iSVWFCatalogList[] := Module[{rows},
  rows = Quiet @ Check[SourceVaultWorkflows[], {}];
  rows = Select[rows, Lookup[#, "Stage", "system"] =!= "system" &];
  iSVWFCatalogRow /@ rows];

SourceVaultWorkflowCatalog[] := Dataset[iSVWFCatalogList[]];

(* ============================================================
   仕様から要約してレコードへ保存 (バックフィル / 再生成)
   ============================================================ *)

(* 要約対象テキスト: 仕様 snapshot 優先、無ければ生成物 (example.md + コード冒頭) *)
iSVWFFolderDigestText[folder_String] := Module[{ex, md, wl, code},
  ex = FileNames["example.md", folder, Infinity];
  md = If[ex =!= {}, iSVWFReadUTF8[First[ex]], ""];
  wl = FileNames["*.wl", folder];
  code = If[wl =!= {}, StringTake[iSVWFReadUTF8[First[Sort[wl]]], UpTo[2500]], ""];
  StringRiffle[Select[{md, code}, StringQ[#] && StringTrim[#] =!= "" &], "\n\n"]];

iSVWFSpecTextFor[slug_String, rec_] := Module[{uri, t, folder},
  uri = If[AssociationQ[rec], Lookup[rec, "SpecURI", ""], ""];
  If[StringQ[uri] && uri =!= "",
    t = Quiet @ Check[
      Lookup[SourceVaultLoadImmutableSnapshot[iSVWFURIToRef[uri]], "Text", ""], ""];
    If[StringQ[t] && StringTrim[t] =!= "", Return[t]]];
  folder = SourceVaultWorkflowFolder[slug];
  If[MissingQ[folder], Return[""]];
  iSVWFFolderDigestText[folder]];

(* モデルペア決定: ImplModels > SpecModels > (未記録ならローカル既定) *)
iSVWFModelPairFor[rec_] := Module[{im, sm, localDefault},
  localDefault = {"lmstudio", "", "http://127.0.0.1:1234"};
  im = If[AssociationQ[rec], Lookup[rec, "ImplModels", <||>], <||>];
  sm = If[AssociationQ[rec], Lookup[rec, "SpecModels", <||>], <||>];
  Which[
    AssociationQ[im] && KeyExistsQ[im, "ClaudeModel"],
      {im["ClaudeModel"], Lookup[im, "AdvisaryModel", im["ClaudeModel"]]},
    AssociationQ[sm] && KeyExistsQ[sm, "ClaudeModel"],
      {sm["ClaudeModel"], Lookup[sm, "AdvisaryModel", sm["ClaudeModel"]]},
    (* 既存バックフィル既定はローカル LLM (ユーザー指定) *)
    True, {localDefault, localDefault}]];

Options[SourceVaultWorkflowSummarize] = {"Language" -> Automatic, "Timeout" -> 180};

SourceVaultWorkflowSummarize[slug_String, opts:OptionsPattern[]] :=
  Module[{rec, specText, pair, res},
    rec = SourceVaultWorkflowCatalogRecord[slug];
    specText = iSVWFSpecTextFor[slug, rec];
    If[! StringQ[specText] || StringTrim[specText] === "",
      Return[<|"Status" -> "NoSpec", "Slug" -> slug|>]];
    pair = iSVWFModelPairFor[rec];
    res = SourceVaultWorkflowSummarizeText[specText, pair[[1]], pair[[2]],
      "Language" -> OptionValue["Language"], "Timeout" -> OptionValue["Timeout"]];
    SourceVaultRegisterWorkflowCatalog[slug,
      <|"Summary" -> res["Summary"], "Keywords" -> res["Keywords"],
        "SummaryMethod" -> res["Method"]|>];
    <|"Status" -> "Done", "Slug" -> slug, "Method" -> res["Method"],
      "Summary" -> res["Summary"], "Keywords" -> res["Keywords"]|>];

(* ============================================================
   横断検索 provider ("workflow" Kind) -- Eagle/mail と同じ共通行スキーマ
   ============================================================ *)

iSVWFRowMatchCat[c_Association, q_String] := Module[{hay},
  hay = ToLowerCase @ StringRiffle[Flatten[{
    ToString @ Lookup[c, "Name", ""], ToString @ Lookup[c, "Summary", ""],
    ToString @ Lookup[c, "Slug", ""], ToString /@ Lookup[c, "Keywords", {}]}], " "];
  StringContainsQ[hay, q]];

iSVWFCommonRow[c_Association] := <|
  "Kind" -> "workflow",
  "Id" -> Lookup[c, "Slug", ""],
  "URI" -> "sv://workflow/" <> Lookup[c, "Slug", ""],
  "Title" -> Lookup[c, "Name", Lookup[c, "Slug", ""]],
  "Authors" -> "",
  "Published" -> "",
  "Summary" -> Lookup[c, "Summary", ""],
  "URL" -> "",
  "File" -> Lookup[c, "Path", ""],
  "Date" -> Lookup[c, "UpdatedAtUTC", ""],
  "PrivacyLevel" -> 0.0,
  "Stage" -> Lookup[c, "Stage", ""]|>;

iSVWFSummaryRows[query_String, optsAssoc_:<||>] := Module[{cat, q, sel},
  (* archive stage は横断検索にも出さない *)
  cat = Select[iSVWFCatalogList[], Lookup[#, "Stage", ""] =!= "archive" &];
  q = ToLowerCase @ StringTrim[query];
  sel = If[q === "", cat, Select[cat, iSVWFRowMatchCat[#, q] &]];
  iSVWFCommonRow /@ sel];

(* ============================================================
   行アクション (横断検索 Grid から)
   ============================================================ *)

iSVWFOpenFolder[slug_String] := Module[{folder},
  folder = SourceVaultWorkflowFolder[slug];
  If[! MissingQ[folder], Quiet @ SystemOpen[folder]]];

iSVWFShowInfo[slug_String] := Module[{rec},
  rec = SourceVaultWorkflowCatalogRecord[slug];
  MessageDialog @ Column[{
    Style["ワークフロー: " <> slug, Bold],
    Row[{"stage: ", SourceVaultWorkflowStatus[slug]}],
    If[AssociationQ[rec],
      Column[{
        Row[{"name: ", Lookup[rec, "Name", slug]}],
        Row[{"summary: ", Lookup[rec, "Summary", "(なし)"]}],
        Row[{"keywords: ", StringRiffle[Lookup[rec, "Keywords", {}], ", "]}]}],
      "(束ねレコードなし)"]}]];

(* ============================================================
   一覧 UI (手動更新・FE フリーズ回避: UpdateInterval を使わず TrackedSymbols のみ)
   ============================================================ *)

iSVWFPanelRows[query_String, archiveQ_:False] := Module[{cat, q},
  cat = iSVWFCatalogList[];
  (* archiveQ=True ならアーカイブのみ、False なら archive を除く *)
  cat = If[TrueQ[archiveQ],
    Select[cat, Lookup[#, "Stage", ""] === "archive" &],
    Select[cat, Lookup[#, "Stage", ""] =!= "archive" &]];
  q = ToLowerCase @ StringTrim[query];
  If[q === "", cat, Select[cat, iSVWFRowMatchCat[#, q] &]]];

iSVWFStageBadge[stage_String] := Framed[
  Style[stage, White, FontSize -> 10, Bold],
  Background -> Switch[stage, "production", RGBColor[0.16, 0.55, 0.30],
    "testing", RGBColor[0.85, 0.50, 0.10],
    "archive", RGBColor[0.45, 0.45, 0.5], _, Gray],
  FrameStyle -> None, RoundingRadius -> 4,
  FrameMargins -> {{6, 6}, {2, 2}}];

iSVWFTruncate[s_, n_Integer] := With[{t = ToString[s]},
  If[StringLength[t] > n, StringTake[t, n] <> "…", t]];

(* 名前クリック = 元にしたノートブックを開く (URI 経由。フォルダは別ボタン) *)
iSVWFOpenNotebook[c_Association] := With[{uri = Lookup[c, "SourceNotebookURI", ""]},
  If[StringQ[uri] && uri =!= "",
    SourceVaultOpenSourceNotebook[uri],
    MessageDialog[
      "\:3053\:306e\:30ef\:30fc\:30af\:30d5\:30ed\:30fc\:306b\:306f\:5143\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:304c\:8a18\:9332\:3055\:308c\:3066\:3044\:307e\:305b\:3093 " <>
      "(\:4ed5\:69d8\:751f\:6210/\:5b9f\:88c5\:6642\:306b\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:304c\:4fdd\:5b58\:3055\:308c\:3066\:3044\:308b\:3068\:8a18\:9332\:3055\:308c\:307e\:3059)\:3002"]]];

iSVWFNameCell[c_Association] := Module[{name = Lookup[c, "Name", ""], sm, hasNb},
  sm = Lookup[c, "Summary", ""];
  hasNb = StringQ[Lookup[c, "SourceNotebookURI", ""]] && Lookup[c, "SourceNotebookURI", ""] =!= "";
  Column[{
    Tooltip[
      Button[Style[name, Bold, If[hasNb, RGBColor[0.15, 0.35, 0.65], Black]],
        iSVWFOpenNotebook[c], Appearance -> "Frameless", BaseStyle -> {}, Method -> "Queued"],
      If[hasNb, "\:5143\:306b\:3057\:305f\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:3092\:958b\:304f", "\:5143\:30ce\:30fc\:30c8\:30d6\:30c3\:30af\:672a\:8a18\:9332"]],
    If[StringQ[sm] && sm =!= "",
      Tooltip[Style[iSVWFTruncate[sm, 90], Gray, FontSize -> 10], sm],
      Style["(要約なし)", Gray, FontSize -> 10]]},
    Alignment -> Left, Spacings -> 0.2]];

iSVWFLaunchDialog[slug_String] := Module[{load, ctx, info, launch, res},
  load = Quiet @ Check[SourceVaultLoadWorkflow[slug], $Failed];
  ctx = If[AssociationQ[load], Lookup[load, "Context", SourceVaultWorkflowContext[slug]],
    SourceVaultWorkflowContext[slug]];
  info = Quiet @ Check[Symbol[ctx <> "WorkflowInfo"][], <||>];
  launch = If[AssociationQ[info], Lookup[info, "Launch", ""], ""];
  res = If[StringQ[launch] && launch =!= "",
    Quiet @ Check[Symbol[ctx <> launch][], $Failed], $Failed];
  MessageDialog @ Column[{
    Style["起動 (引数なし = 副作用なし報告): " <> slug, Bold],
    Row[{"launch entry: ", launch}],
    Style["実体実行は LaunchImplementationWorkflow[\"" <> slug <> "\", args] / 生成 example を参照", Gray, FontSize -> 10],
    If[res === $Failed, Style["(報告を取得できませんでした)", Gray], Pane[res, {500, 300}, Scrollbars -> True]]}]];

(* ---- 起動 = 生成物の example.md を「実行可能セル」として新規ノートに展開する ----
   引数なし launch は副作用なしの報告に過ぎないので、起動ボタンは代わりに使用例を
   レンダリングし、ユーザーがその場で引数付きフォーム ("Execute"->True / セル・変数指定 等)
   を実行できるようにする ([[spec-impl-workflow]] の書き戻しと同方針)。 *)
iSVWFExampleFile[slug_String] := Module[{folder, exs},
  folder = SourceVaultWorkflowFolder[slug];
  If[MissingQ[folder], Return[Missing["NoFolder"]]];
  exs = FileNames["example.md", folder, Infinity];
  If[exs === {}, Missing["NoExample"], First[exs]]];

(* 明示的に wl/wolfram/mathematica と記された fence のみ Input (実行可能) にする。
   言語無指定の bare ``` は安全側に倒して Program (非実行) にする。 *)
iSVWFCodeLangInputQ[lang_String] :=
  MemberQ[{"wl", "wolfram", "mathematica", "wolframlanguage"}, ToLowerCase[StringTrim[lang]]];

(* markdown (example.md) -> notebook セル列。見出し->Subsection/Subsubsection、
   ```wl/wolfram/mathematica``` -> Input セル (実行可能・自動評価しない)、他コード->Program、
   本文->Text。 *)
iSVWFMarkdownToCells[md_String] := Module[
  {lines, cells = {}, inCode = False, codeBuf = {}, lang = "", textBuf = {}, flush},
  flush[] := (
    If[textBuf =!= {},
      With[{t = StringTrim[StringRiffle[textBuf, "\n"]]},
        If[t =!= "", AppendTo[cells, Cell[t, "Text"]]]]];
    textBuf = {});
  lines = StringCases[md <> "\n", Shortest[l___] ~~ "\n" :> l];
  Scan[
    Function[ln, Module[{t = StringTrim[ln]},
      Which[
        StringStartsQ[t, "```"],
          If[! inCode,
            flush[]; inCode = True; lang = StringTrim @ StringDrop[t, 3]; codeBuf = {},
            With[{code = StringRiffle[codeBuf, "\n"]},
              AppendTo[cells, Cell[code,
                If[iSVWFCodeLangInputQ[lang], "Input", "Program"]]]];
            inCode = False; codeBuf = {}; lang = ""],
        inCode, AppendTo[codeBuf, ln],
        StringStartsQ[t, "### "], flush[]; AppendTo[cells, Cell[StringDrop[t, 4], "Subsubsection"]],
        StringStartsQ[t, "## "],  flush[]; AppendTo[cells, Cell[StringDrop[t, 3], "Subsubsection"]],
        StringStartsQ[t, "# "],   flush[]; AppendTo[cells, Cell[StringDrop[t, 2], "Subsection"]],
        t === "", flush[],
        True, AppendTo[textBuf, ln]]]],
    lines];
  If[inCode && codeBuf =!= {},
    AppendTo[cells, Cell[StringRiffle[codeBuf, "\n"], "Program"]]];
  flush[];
  cells];

iSVWFInsertExample[slug_String] := Module[{exf, md, cells},
  Quiet @ Check[SourceVaultLoadWorkflow[slug], $Failed];
  exf = iSVWFExampleFile[slug];
  (* 使用例が無ければ従来の引数なし報告にフォールバック *)
  If[MissingQ[exf], Return[iSVWFLaunchDialog[slug]]];
  md = iSVWFReadUTF8[exf];
  If[! StringQ[md] || StringTrim[md] === "", Return[iSVWFLaunchDialog[slug]]];
  cells = iSVWFMarkdownToCells[md];
  CreateDocument[
    Prepend[cells, Cell["SourceVault ワークフロー使用例: " <> slug, "Subsection"]],
    WindowTitle -> "Workflow example: " <> slug]];

iSVWFToggle[slug_String, cur_String] :=
  SourceVaultSetWorkflowStatus[slug, If[cur === "testing", "production", "testing"]];

(* アーカイブ一覧を別ウインドウで開く (パネル内の「アーカイブ」ボタンから) *)
iSVWFOpenArchivePanel[] := CreateDocument[
  ExpressionCell[SourceVaultWorkflowArchivePanel[], "Output"],
  WindowTitle -> "SourceVault Workflows (Archive)"];

(* 一覧パネル本体。archiveQ=False: 通常一覧 (archive を除く)、
   True: アーカイブ一覧 (切替列は「testingへ戻す」)。 *)
iSVWFMakePanel[archiveQ_] := DynamicModule[{rows, query = ""},
  rows = iSVWFPanelRows["", archiveQ];
  Panel[Column[{
    Style[If[TrueQ[archiveQ],
        "SourceVault ワークフロー (アーカイブ)",
        "SourceVault ワークフロー一覧"], Bold, 15],
    Row[{
      InputField[Dynamic[query], String, FieldHint -> "キーワード/サマリー検索",
        ImageSize -> 320],
      Spacer[6],
      Button["検索", rows = iSVWFPanelRows[query, archiveQ]],
      Spacer[4],
      Button["全件", query = ""; rows = iSVWFPanelRows["", archiveQ]],
      (* 通常一覧の右端のみ: アーカイブ一覧を開くボタン *)
      If[TrueQ[archiveQ], Nothing, Spacer[20]],
      If[TrueQ[archiveQ], Nothing,
        Tooltip[
          Button["アーカイブ", iSVWFOpenArchivePanel[], Method -> "Queued"],
          "アーカイブしたワークフローの一覧を開く"]]}],
    Dynamic[
      If[rows === {},
        Style[If[TrueQ[archiveQ],
            "(アーカイブされたワークフローはありません)",
            "(該当ワークフローなし。仕様実装で生成すると testing に入ります)"], Gray],
        Grid[
          Prepend[
            Function[c,
              With[{slug = Lookup[c, "Slug", ""], stage = Lookup[c, "Stage", "testing"]},
                {iSVWFStageBadge[stage],
                 iSVWFNameCell[c],
                 Tooltip[
                   Button["起動", iSVWFInsertExample[slug], Method -> "Queued"],
                   "使用例 (example.md) を実行可能セルとして新規ノートに展開します。" <>
                   "引数なし launch は副作用なしの報告のみなので、実走は展開された引数付き" <>
                   "フォーム (\"Execute\"->True / セル・変数指定 等) を評価してください。"],
                 If[TrueQ[archiveQ],
                   (* アーカイブ一覧: testing へ戻す *)
                   Tooltip[
                     Button["testingへ戻す",
                       (SourceVaultSetWorkflowStatus[slug, "testing"];
                        rows = iSVWFPanelRows[query, archiveQ]),
                       Method -> "Queued"],
                     "アーカイブから testing に戻す"],
                   (* 通常一覧: testing/production 切替 + アーカイブ送り *)
                   Column[{
                     Button[If[stage === "testing", "→運用", "→テスト"],
                       (iSVWFToggle[slug, stage]; rows = iSVWFPanelRows[query, archiveQ]),
                       Method -> "Queued"],
                     Tooltip[
                       Button["アーカイブ",
                         (SourceVaultSetWorkflowStatus[slug, "archive"];
                          rows = iSVWFPanelRows[query, archiveQ]),
                         Method -> "Queued"],
                       "このワークフローをアーカイブ (一覧から隠す)"]
                   }, Spacings -> 0.2]],
                 Button["要約更新",
                   (SourceVaultWorkflowSummarize[slug]; rows = iSVWFPanelRows[query, archiveQ]),
                   Method -> "Queued"],
                 Tooltip[
                   Button["フォルダ", iSVWFOpenFolder[slug], Method -> "Queued"],
                   "ワークフローの格納フォルダを開く"]}]] /@ rows,
            {Style["stage", Bold], Style["名前 / サマリー", Bold],
             Style["起動", Bold],
             Style[If[TrueQ[archiveQ], "復帰", "切替/保管"], Bold],
             Style["要約", Bold], Style["フォルダ", Bold]}],
          Alignment -> {Left, Center}, Frame -> All,
          FrameStyle -> GrayLevel[0.8], Background -> {None, {GrayLevel[0.93]}},
          Spacings -> {1, 0.6}]],
      TrackedSymbols :> {rows}]}],
    ImageMargins -> 4]];

SourceVaultWorkflowPanel[] := iSVWFMakePanel[False];
SourceVaultWorkflowArchivePanel[] := iSVWFMakePanel[True];

(* ============================================================
   既存ルート直下ワークフローの stage 移行 (一回限り、冪等)
   ============================================================ *)

(* slug 一致は Unicode 正規化差に寛容にする: 仮名の濁点/半濁点が NFD (結合文字
   U+3099 / U+309A) と NFC (合成済み) でズレると、リテラル slug がファイルシステム上の
   slug と一致しないことがある (Dropbox 同期フォルダで観測)。結合濁点を落として比較する。 *)
iSVWFSlugFold[s_String] := StringDelete[s, {"\:3099", "\:309a"}];
iSVWFSlugEquivQ[a_String, b_String] := a === b || iSVWFSlugFold[a] === iSVWFSlugFold[b];

Options[SourceVaultMigrateWorkflowsToStages] = {
  "Production" -> {}, "Testing" -> {}, "Default" -> "testing",
  "SystemSlugs" -> {"spec-review", "spec-impl"}, "Summarize" -> False};

SourceVaultMigrateWorkflowsToStages[opts:OptionsPattern[]] := Module[
  {root, prodList, testList, default, sysSlugs, doSummary, dirs, results},
  root = SourceVaultWorkflowDirectory[];
  If[! DirectoryQ[root], Return[<|"Status" -> "NoRoot", "Path" -> root|>]];
  prodList = Flatten[{OptionValue["Production"]}];
  testList = Flatten[{OptionValue["Testing"]}];
  default = OptionValue["Default"];
  sysSlugs = Flatten[{OptionValue["SystemSlugs"]}];
  doSummary = TrueQ[OptionValue["Summarize"]];
  dirs = Select[FileNames["*", root],
    DirectoryQ[#] &&
      ! MemberQ[$SourceVaultWorkflowStages, FileNameTake[#]] &&
      ! MemberQ[sysSlugs, FileNameTake[#]] &];
  results = Function[folder,
    Module[{slug = FileNameTake[folder], stage, destDir, dest, moved},
      stage = Which[
        AnyTrue[prodList, iSVWFSlugEquivQ[ToString[#], slug] &], "production",
        AnyTrue[testList, iSVWFSlugEquivQ[ToString[#], slug] &], "testing",
        True, default];
      destDir = SourceVaultWorkflowStageDirectory[stage];
      dest = FileNameJoin[{destDir, slug}];
      If[DirectoryQ[dest],
        <|"Slug" -> slug, "Stage" -> stage, "Status" -> "DestExists"|>,
        Quiet @ CreateDirectory[destDir, CreateIntermediateDirectories -> True];
        moved = iSVWFMoveDir[folder, dest];
        If[moved,
          iSVWFEnsureRecord[slug, stage];
          If[doSummary, Quiet @ SourceVaultWorkflowSummarize[slug]];
          <|"Slug" -> slug, "Stage" -> stage, "Status" -> "Moved"|>,
          <|"Slug" -> slug, "Stage" -> stage, "Status" -> "MoveFailed"|>]]]] /@ dirs;
  Dataset[results]];

(* ============================================================
   登録: 横断検索 provider + 行アクション (ロード時)
   ============================================================ *)

If[Length[Names["SourceVault`SourceVaultRegisterSummaryProvider"]] > 0,
  Quiet @ SourceVaultRegisterSummaryProvider["workflow", iSVWFSummaryRows]];

If[AssociationQ[SourceVault`Private`$iSVRowTitleActions],
  SourceVault`Private`$iSVRowTitleActions["workflow"] = iSVWFShowInfo];
If[AssociationQ[SourceVault`Private`$iSVRowOpenActions],
  SourceVault`Private`$iSVRowOpenActions["workflow"] = iSVWFOpenFolder];

End[]  (* `WorkflowCatalogPrivate` *)

EndPackage[]
