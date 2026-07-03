(* ::Package:: *)

(* ============================================================
   SourceVault_wiring.wl -- typed binding / URI coercion / port adapter 層

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_wiring.wl"]]

   仕様書: sourcevault_function_contract_wiring_spec_v0_3.md
     §4.3 URI envelope (ObjectKind/DomainKind/MediaKind taxonomy)
     §4.4 ValueEnvelope (Value 入力も privacy label、0 扱い廃止)
     §4.5 PortBindingRef (URI/VariableRef/FileRef/LiteralValue/...)
     §6.3 URI coercion / Port adapter registry + cost 付き経路探索
     §6.6 privacy 事前見積の Max 伝搬 (binding 部分)

   実装 increment: Inc δ (F3 typed binding)
     - envelope:   SourceVaultURIEnvelopeQ / SourceVaultNormalizeURIEnvelope
                   SourceVaultMakeValueEnvelope / SourceVaultValueEnvelopeQ
     - binding:    SourceVaultBindingFromURI / FromValue / FromVariable / FromFile
                   (NotebookCellRef / PromptRunRef は §7 NB 境界 = 次 increment)
     - coercion:   SourceVaultCoerceToURI / SourceVaultCoerceFromURI
                   (deposit は SourceVaultSaveDerivedArtifact / CommitBlob を再利用)
     - adapter:    SourceVaultRegisterPortAdapter / SourceVaultFindAdapterPath /
                   SourceVaultApplyAdapterPath (AdapterPolicy: MaxDepth/MaxCost/
                   AllowLossy/RequireUniquePath、複数 path は AmbiguousAdapterPath)
     - privacy:    SourceVaultBindingPrivacyMax (Max 伝搬、欠落は 0.85 fail-closed)

   設計原則:
     - W3: 参照渡しの正準形は typed handle。本文は envelope に持たない。
     - W5: privacy は Max 伝搬で事前見積、egress gate は別層で必ず再評価。
     - VariableRef の正は「その時点の値 snapshot URI」(名前 live 解決は明示時のみ)。
     - FileRef の既定は path identity のみ (本文は CopyToArtifact 明示時のみ)。
     - CoerceFromURI の ToExpression 解釈は自前 deposit (ArtifactType
       "WiringValue") のみ。他 artifact は Text のまま返す (コード実行防止)。

   非衝突方針: private helper は SourceVault`WiringPrivate` 文脈。
   ============================================================ *)

BeginPackage["SourceVault`"]

(* ---- URI envelope (§4.3) ---- *)
SourceVaultURIEnvelopeQ::usage =
  "SourceVaultURIEnvelopeQ[x] は x が URI envelope (Status/URI/PrivacyLevel 必須) か判定する。";

SourceVaultNormalizeURIEnvelope::usage =
  "SourceVaultNormalizeURIEnvelope[x] は URI envelope / \"sv://...\" 文字列を正準 envelope に正規化する。\n" <>
  "PrivacyLevel 欠落は既定 0.85 (fail-closed)。本文は含めない。解釈不能は Failure。";

(* ---- ValueEnvelope (§4.4) ---- *)
SourceVaultValueEnvelopeQ::usage =
  "SourceVaultValueEnvelopeQ[x] は x が ValueEnvelope (PortType->\"Value\"+PrivacyLevel) か判定する。";

SourceVaultMakeValueEnvelope::usage =
  "SourceVaultMakeValueEnvelope[value, opts] は値を privacy label 付き ValueEnvelope に包む (§4.4)。\n" <>
  "オプション: \"Source\" -> \"UserTyped\"(既定)|\"VariableSnapshot\"|\"FileContent\"|\"StepOutput\"|\"NotebookCell\"、\n" <>
  "\"PrivacyLevel\" -> Automatic (Source 別既定: UserTyped=0.0、他=0.85 fail-closed) | 数値。";

(* ---- PortBindingRef (§4.5) ---- *)
SourceVaultPortBindingRefQ::usage =
  "SourceVaultPortBindingRefQ[x] は x が PortBindingRef か判定する。";

SourceVaultBindingFromURI::usage =
  "SourceVaultBindingFromURI[uriOrEnvelope] は URI/envelope から BindingKind->\"URI\" の PortBindingRef を作る。";

SourceVaultBindingFromValue::usage =
  "SourceVaultBindingFromValue[value, opts] は literal 値から BindingKind->\"LiteralValue\" の\n" <>
  "PortBindingRef を作る (ValueEnvelope を内包)。opts は SourceVaultMakeValueEnvelope と同じ。";

SourceVaultBindingFromVariable::usage =
  "SourceVaultBindingFromVariable[symbolName, opts] は変数から PortBindingRef を作る (§4.5)。\n" <>
  "既定 \"SnapshotPolicy\"->\"SnapshotNow\": 現在値を snapshot artifact 化し URI を正とする\n" <>
  "(変数名は kernel session と時刻に依存し危険なため)。\"LiveAtExecution\" は明示時のみ (URI なし)。\n" <>
  "\"PrivacyLevel\" -> Automatic(=0.85 fail-closed) | 数値。";

SourceVaultBindingFromFile::usage =
  "SourceVaultBindingFromFile[path, opts] はファイルから PortBindingRef を作る (§4.5)。\n" <>
  "\"Mode\" -> \"ReferenceOnly\"(既定、path identity のみ) | \"HashOnly\"(+content hash) |\n" <>
  "\"CopyToArtifact\"(内容を snapshot artifact 化して URI 付与)。\n" <>
  "\"PrivacyLevel\" -> Automatic(=0.85) | 数値 (CopyToArtifact/HashOnly 時の内容 privacy)。";

(* ---- coercion (§6.3) ---- *)
SourceVaultCoerceToURI::usage =
  "SourceVaultCoerceToURI[x, opts] は値/ValueEnvelope/PortBindingRef/URI を URI envelope へ正規化する。\n" <>
  "生値は ArtifactType \"WiringValue\" の DerivedArtifact として deposit される (InputForm text)。\n" <>
  "既に URI/envelope なら正規化のみ (冪等)。戻り値 URI envelope | Failure。";

SourceVaultCoerceFromURI::usage =
  "SourceVaultCoerceFromURI[envelopeOrUri, opts] は URI を解決して値を返す。\n" <>
  "自前 deposit (ArtifactType \"WiringValue\") のみ ToExpression で WL 値に解釈し、\n" <>
  "それ以外の artifact は Text のまま返す (\"Interpret\"->Automatic 既定。False で常に Text)。\n" <>
  "戻り値 <|\"Status\", \"Value\"|\"Text\", \"MediaKind\", \"PrivacyLevel\"|> | Failure。";

(* ---- port adapter (§6.3) ---- *)
SourceVaultRegisterPortAdapter::usage =
  "SourceVaultRegisterPortAdapter[from, to, f, meta] は from->to の port adapter を登録する。\n" <>
  "from/to: PortType ラベル文字列 (\"Value\"/\"URI\"/\"FileRef\"/\"VariableRef\" 等)。\n" <>
  "meta: <|\"Cost\"->1, \"Lossy\"->False|> (既定)。f は 1 引数関数。";

SourceVaultPortAdapters::usage =
  "SourceVaultPortAdapters[] は登録済み adapter 一覧を返す。";

SourceVaultFindAdapterPath::usage =
  "SourceVaultFindAdapterPath[from, to, opts] は adapter 経路を cost 付きで探索する (§6.3)。\n" <>
  "\"AdapterPolicy\" -> <|\"MaxDepth\"->2, \"MaxCost\"->3, \"AllowLossy\"->False,\n" <>
  "\"RequireUniquePath\"->True|> (既定)。一意経路 <|\"Status\"->\"OK\",\"Path\"->{...},\"Cost\"->n|>、\n" <>
  "複数候補は Failure[\"AmbiguousAdapterPath\"] (候補列挙)、無ければ Failure[\"NoAdapterPath\"]。";

SourceVaultApplyAdapterPath::usage =
  "SourceVaultApplyAdapterPath[pathResult, input] は FindAdapterPath の経路を順に適用する。";

(* ---- privacy (§6.6 binding 部分) ---- *)
SourceVaultBindingPrivacyMax::usage =
  "SourceVaultBindingPrivacyMax[bindings] は envelope/ValueEnvelope/PortBindingRef のリストから\n" <>
  "PrivacyLevel の Max を返す (§6.6 Max 伝搬)。判定不能要素は 0.85 (fail-closed)。";

(* ---- 関数選定 (§6.2) ---- *)
SourceVaultSelectFunctionsForTask::usage =
  "SourceVaultSelectFunctionsForTask[task, opts] は task (文字列または TaskSpec) に適合する契約付き関数を\n" <>
  "決定的に選定する (§6.2)。v1 の scoring は lexical (シンボル名一致/CapabilityTags/IntentExamples の\n" <>
  "文字 bigram 重なり) + RecommendedEntrypoint/UserFacing boost。Internal は既定除外。\n" <>
  "NegativeExamples/DoNotUseWhen 一致は Rejected (理由付き=負の情報)。閾値未満は候補 0 件を許す。\n" <>
  "戻り値 <|\"Candidates\"->{<|Symbol,Score,Reasons|>..}, \"Rejected\"->{<|Symbol,Reason|>..},\n" <>
  "        \"Clarifications\"->{...}|>。LLM に渡す場合は Candidates 内からの enum 選択のみ (W4)。";

(* ---- wiring planner (§6.4 / §6.7 propose-validate-execute) ---- *)
SourceVaultProposeWiringPlan::usage =
  "SourceVaultProposeWiringPlan[taskSpec, opts] は TaskSpec から WiringPlan (純データ・未実行) を作る (§6.7)。\n" <>
  "taskSpec: <|\"Task\"->_, \"Inputs\"->{PortBindingRef(+\"Name\") ..}, \"Steps\"->{symbol..}|Automatic|>。\n" <>
  "束縛は決定的規則を優先順に適用 (§6.4): ①ポート名一致 ②DomainKind ③MediaKind ④WLType 一意\n" <>
  "⑤adapter 一意経路。曖昧 (複数候補) は推測せず Unresolved に積む。\n" <>
  "戻り値 WiringPlan: <|\"Status\"->\"OK\"|\"Incomplete\", \"Steps\", \"Unresolved\", \"PrivacyEstimate\"|>。";

SourceVaultValidateWiringPlan::usage =
  "SourceVaultValidateWiringPlan[plan] は WiringPlan を検証する (§6.7): 各 step の生成式が\n" <>
  "SourceVaultValidateCallExpression を通るか、InitPlan が解決可能か、Unresolved が無いか。\n" <>
  "戻り値 <|\"Status\"->\"OK\"|\"Incomplete\"|\"Failed\", \"Failures\"->{...}|>。";

SourceVaultWiringPlanExpression::usage =
  "SourceVaultWiringPlanExpression[plan] は plan 全体を未評価 WL 式に整形する (§6.7)。\n" <>
  "EnsureInitialized 前置き + step 列。ClaudeEval / Runtime の提案式としてそのまま流せる。\n" <>
  "戻り値 <|\"Code\"->_String, \"HeldExpr\"->HoldComplete[...]|>。";

(* ---- LLM wiring (§6.5 Hybrid の残余埋め) ---- *)
$SourceVaultWiringLLM::usage =
  "$SourceVaultWiringLLM は LLM wiring (§6.5) のエンジン (prompt_String -> response_String)。\n" <>
  "None (既定) のときは ClaudeCode`ClaudeQuerySync を PrivacyLevel 1.0 (ローカルモデル) で\n" <>
  "弱結合利用する。テストでは mock 関数を設定する。";

SourceVaultFillUnresolvedWithLLM::usage =
  "SourceVaultFillUnresolvedWithLLM[plan, opts] は WiringPlan の Unresolved (Ambiguous のみ) を\n" <>
  "LLM で埋める (§6.5)。LLM には候補の identity (From/Kind/DomainKind/Preview、Redacted は除外) のみを\n" <>
  "渡し、データ本文は渡さない。出力は固定 JSON schema (候補 From からの enum 選択のみ)。\n" <>
  "validate-then-accept: 候補外の選択・不正 JSON は破棄して Unresolved のまま (Warnings に記録)。\n" <>
  "採用 binding は FilledBy->\"LLM\"。ProposeWiringPlan は TaskSpec \"WiringMode\"->\"Hybrid\" (既定) で\n" <>
  "これを自動適用する (\"Deterministic\" 指定で無効)。";

(* ---- confidential 伝搬 ---- *)
$SourceVaultConfidentialPrivacyLevel::usage =
  "$SourceVaultConfidentialPrivacyLevel は confidential 伝搬時に deposit へ適用する PrivacyLevel 下限\n" <>
  "(既定 1.0 = NBMarkCellConfidential の既定と同じ、クラウド禁止)。";

SourceVaultConfidentialContextQ::usage =
  "SourceVaultConfidentialContextQ[nb] は現在の評価文脈が confidential か判定する:\n" <>
  "  1. 評価セルが confidential (NBCellPrivacyLevel > 0.5) → True (必ず伝搬)\n" <>
  "  2. セル非機密 かつ notebook が CloudPublishable=True → False\n" <>
  "  3. notebook が CloudPublishable=False (クラウド公開不可) → True (セルに関わらず伝搬)\n" <>
  "  4. どちらも未設定 → False\n" <>
  "RunWorkflow / SubmitWorkflowInput が \"Confidential\"->Automatic のとき使う。\n" <>
  "True のとき、ワークフローが SourceVault に格納する全出力 (step 出力の WiringValue /\n" <>
  "InputBundle) は PrivacyLevel ≥ $SourceVaultConfidentialPrivacyLevel の\n" <>
  "秘密依存データ (Provenance ConfidentialDependent->True) として保存される。";

(* ---- workflow 起動シーケンス (§7.4) ---- *)
SourceVaultRegisterWiringWorkflow::usage =
  "SourceVaultRegisterWiringWorkflow[name, taskSpec] は名前付き workflow (TaskSpec) を登録する。\n" <>
  "SourceVaultRunWorkflow[name] で起動できる。";

SourceVaultRunWorkflow::usage =
  "SourceVaultRunWorkflow[nameOrSpecOrPlan, opts] は notebook-facing の起動関数 (§7.4.1)。\n" <>
  "起動式自体が式提案の対象 (W9: 隠れ実行入口を作らない)。propose -> validate -> 実行。\n" <>
  "required input 未充足なら実行せず WorkflowInputBlock を notebook に挿入して\n" <>
  "<|\"Status\"->\"AwaitingInput\", \"InputBlockId\"->...|> を返す (FE 不在時は InputBlockSpec 返却に degrade)。\n" <>
  "再評価 idempotency: 同一 PlanHash の未提出 block があれば再利用し、schema 変更時は旧 block を\n" <>
  "Superseded にする (G-ui-3/4)。Options: \"OnMissingInput\"->\"InsertWorkflowInputBlock\"|\"Return\"、\n" <>
  "\"AllowEffects\"->True (ユーザーが起動式を明示評価するため既定許可)、\"Notebook\"->Automatic。";

SourceVaultCollectWorkflowInput::usage =
  "SourceVaultCollectWorkflowInput[nb, inputBlockId] は WorkflowInputBlock のセル群を読み\n" <>
  "InputDraft (未検証の PortBindingRef 列) を返す (§7.4.2)。永続化しない。";

SourceVaultValidateWorkflowInput::usage =
  "SourceVaultValidateWorkflowInput[inputDraft, plan] は draft を plan に適用して再 propose し\n" <>
  "検証 report を返す (§7.4.2)。green でも永続化しない。戻り値に \"ResolvedPlan\" を含む。";

SourceVaultCreateInputBundle::usage =
  "SourceVaultCreateInputBundle[inputDraft, plan] は検証 green の draft を不変 InputBundle として\n" <>
  "deposit する (§7.4.2)。BundleKind->\"WorkflowInput\" subtype 必須 (EvidenceBundle と混同させない)。\n" <>
  "戻り値 URI envelope (+\"InputBundleRecord\")。";

SourceVaultSubmitWorkflowInput::usage =
  "SourceVaultSubmitWorkflowInput[inputBlockId, <|port -> value, ...|>] は入力を連想で与えて\n" <>
  "Validate -> CreateInputBundle -> 実行の再開シーケンスを行う (§7.4.1 step 5-6)。\n" <>
  "挿入ブロックのテンプレート式の \"\" を値に書き換えて評価するだけでよい (単一セル・WL の直観に合う形)。\n" <>
  "value は 生値 / \"sv://...\" 文字列 / PortBindingRef。\"\" と Missing は未記入扱い。\n" <>
  "SourceVaultSubmitWorkflowInput[inputBlockId] (連想なし) は旧式の入力セル記入方式 (後方互換)。\n" <>
  "検証 NG なら実行せず Failures を返す。成功時は block を Submitted にし InputBundle URI を紐づける。";

(* ---- NB 境界 (§7.1 / §7.2) ---- *)
SourceVaultCellInput::usage =
  "SourceVaultCellInput[nb, opts] は選択セル (または \"Cells\"->{CellObject..}) を\n" <>
  "NotebookCellRef の PortBindingRef 列にする (§7.1 初段)。選択が無ければ\n" <>
  "評価セルの直前のセルを既定入力とする (上のセルを入力に、下で評価する自然な操作)。\n" <>
  "既定 SnapshotNow: セル本文を artifact 化し、cell UUID + content hash + notebook ref を\n" <>
  "Identity に持つ。PrivacyLevel 既定 0.85 (fail-closed。セルを 0 にしない)。\n" <>
  "FE 不在は Failure[\"NoFrontEnd\"]。";

SourceVaultCellOutput::usage =
  "SourceVaultCellOutput[x, nb, opts] は URI envelope / ExecuteWiringPlan 結果 / 生値を\n" <>
  "MediaKind 別にノートブックへ書き出す (§7.2 最終段)。Text は ClaudeWriteResponse\n" <>
  "(markdown 対応、弱結合) か NBWriteText、Image は画像セル、他は要約+URI リンク。\n" <>
  "戻り値 <|\"Status\", \"Written\"|>。claudecode hook $ClaudeCellInput/OutputProvider へ\n" <>
  "ロード時に弱結合登録される (§7.3)。";

SourceVaultExecuteWiringPlan::usage =
  "SourceVaultExecuteWiringPlan[plan, opts] は manual / tests / 承認済み workflow 用の実行層 (§6.7)。\n" <>
  "required input 未充足時の既定は \"OnMissingInput\"->\"Return\": 実行せず\n" <>
  "<|\"Status\"->\"AwaitingInput\", \"InputBlockSpec\"->...|> を返し notebook には触らない (r2 責務分離)。\n" <>
  "各 step: EnsureInitialized -> 束縛解決 -> 実行 -> 出力を契約に従い URI envelope 化。\n" <>
  "Effects (NotebookWrite/FileWrite/Network/LLMCall) を持つ step は既定拒否 (\"AllowEffects\"->True で許可)。\n" <>
  "途中失敗は Failure + そこまでの StepResults。ClaudeEval 経路はこれを呼ばず WiringPlanExpression を使う (W9)。";

Begin["`WiringPrivate`"]

$svWDefaultPL = 0.85;   (* fail-closed 既定 (core の $SourceVaultDefaultObjectPrivacyLevel と同値) *)

(* confidential 伝搬の動的下限。RunWorkflow/Submit が Block で束縛し、
   その内側の全 deposit (WiringValue/InputBundle/blob) に適用される。 *)
If[!ValueQ[$svWConfidentialFloor], $svWConfidentialFloor = None];
If[!ValueQ[SourceVault`$SourceVaultConfidentialPrivacyLevel],
  SourceVault`$SourceVaultConfidentialPrivacyLevel = 1.0];

iSVWConfidentialFloorQ[] := NumberQ[$svWConfidentialFloor];

iSVWApplyConfidentialFloor[pl_] :=
  If[iSVWConfidentialFloorQ[],
    Max[If[NumberQ[pl], pl, $svWDefaultPL], $svWConfidentialFloor],
    pl];

(* 判定表 (2026-07-02 ユーザー指定):
   セル confidential (PL>0.5)      -> True  (必ず伝搬)
   非機密セル + CloudPublishable=True  -> False
   CloudPublishable=False             -> True  (セルに関わらず伝搬)
   どちらも未設定                     -> False *)
iSVWConfidentialDecision[cellPL_, cloudPub_] :=
  Which[
    NumberQ[cellPL] && cellPL > 0.5, True,
    cloudPub === False, True,
    True, False];

SourceVault`SourceVaultConfidentialContextQ[nb_] :=
  Module[{cellPL = Missing[], cloudPub = Missing[], ec, idx},
    If[$FrontEnd =!= Null && MatchQ[nb, _NotebookObject],
      ec = Quiet @ Check[EvaluationCell[], $Failed];
      If[MatchQ[ec, _CellObject],
        idx = Quiet @ Check[
          First @ FirstPosition[Cells[nb], ec, {$Failed}], $Failed];
        If[IntegerQ[idx],
          cellPL = Quiet @ Check[
            NBAccess`NBCellPrivacyLevel[nb, idx], Missing[]]]];
      (* live TaggingRules 優先。無ければファイル宣言 (NBGetCloudPublishable、
         NBSetCloudPublishable はファイル書き換え方式のため開いたままでは
         live に反映されない) へ fallback *)
      cloudPub = Quiet @ Check[
        Replace[CurrentValue[nb,
          {TaggingRules, "SourceVault", "CloudPublishable"}],
          Inherited -> Missing[]], Missing[]];
      If[MissingQ[cloudPub],
        cloudPub = Quiet @ Check[
          With[{p = NotebookFileName[nb]},
            If[StringQ[p],
              Replace[NBAccess`NBGetCloudPublishable[p],
                Except[True | False] -> Missing[]],
              Missing[]]],
          Missing[]]]];
    iSVWConfidentialDecision[cellPL, cloudPub]
  ];

(* ============================================================
   1. URI envelope (§4.3)
   ============================================================ *)

SourceVault`SourceVaultURIEnvelopeQ[x_] :=
  AssociationQ[x] && StringQ[Lookup[x, "URI"]] &&
  StringStartsQ[Lookup[x, "URI"], "sv://"] &&
  KeyExistsQ[x, "PrivacyLevel"] && KeyExistsQ[x, "Status"];

iSVWObjectKindOf[uri_String] :=
  Module[{seg = StringSplit[StringDrop[uri, 5], "/"]},
    If[seg === {}, "Object",
      Switch[First[seg],
        "artifact", "Artifact", "hash", "Artifact",
        "chunk", "Chunk", "record", "Record", _, "Object"]]];

SourceVault`SourceVaultNormalizeURIEnvelope[x_] :=
  Which[
    SourceVault`SourceVaultURIEnvelopeQ[x],
      Join[<|"ObjectKind" -> iSVWObjectKindOf[x["URI"]],
             "Marked" -> False|>, x],
    StringQ[x] && StringStartsQ[x, "sv://"],
      <|"Status" -> "OK", "URI" -> x,
        "ObjectKind" -> iSVWObjectKindOf[x],
        "PrivacyLevel" -> $svWDefaultPL,   (* 欠落は fail-closed (§4.3) *)
        "Marked" -> False|>,
    True,
      Failure["InvalidURIEnvelope",
        <|"MessageTemplate" -> "SourceVault wiring: InvalidURIEnvelope",
          "Detail" -> Head[x]|>]];

(* ============================================================
   2. ValueEnvelope (§4.4)
   ============================================================ *)

SourceVault`SourceVaultValueEnvelopeQ[x_] :=
  AssociationQ[x] && Lookup[x, "PortType"] === "Value" &&
  KeyExistsQ[x, "Value"] && KeyExistsQ[x, "PrivacyLevel"];

iSVWSourcePLDefault["UserTyped"] = 0.;   (* task 文字列と同じ扱い (§4.4 表) *)
iSVWSourcePLDefault[_] = $svWDefaultPL;  (* 他は fail-closed *)

iSVWContentHash[value_] :=
  Quiet @ Check[
    StringPadLeft[IntegerString[
      Hash[ToString[value, InputForm], "SHA256"], 16], 64, "0"],
    Missing["HashFailed"]];

iSVWWLTypeOf[value_] :=
  Which[
    StringQ[value], "String",
    IntegerQ[value], "Integer",
    NumberQ[value], "Real",
    BooleanQ[value], "Boolean",
    AssociationQ[value], "Association",
    ListQ[value], "List",
    ImageQ[value], "Image",
    True, ToString[Head[value]]];

Options[SourceVault`SourceVaultMakeValueEnvelope] =
  {"Source" -> "UserTyped", "PrivacyLevel" -> Automatic};

SourceVault`SourceVaultMakeValueEnvelope[value_, OptionsPattern[]] :=
  Module[{src = OptionValue["Source"], pl = OptionValue["PrivacyLevel"]},
    If[pl === Automatic, pl = iSVWSourcePLDefault[src]];
    <|"PortType" -> "Value", "Value" -> value,
      "WLType" -> iSVWWLTypeOf[value],
      "PrivacyLevel" -> pl, "Source" -> src,
      "ContentHash" -> iSVWContentHash[value]|>
  ];

(* 裸の値を envelope 化 (既に envelope ならそのまま) *)
iSVWToValueEnvelope[x_, src_: "UserTyped"] :=
  If[SourceVault`SourceVaultValueEnvelopeQ[x], x,
    SourceVault`SourceVaultMakeValueEnvelope[x, "Source" -> src]];

(* ============================================================
   3. PortBindingRef (§4.5)
   ============================================================ *)

SourceVault`SourceVaultPortBindingRefQ[x_] :=
  AssociationQ[x] &&
  Lookup[x, "ObjectClass"] === "SourceVaultPortBindingRef" &&
  StringQ[Lookup[x, "BindingKind"]];

iSVWBindingBase[kind_String] :=
  <|"ObjectClass" -> "SourceVaultPortBindingRef",
    "BindingKind" -> kind, "URI" -> Missing[],
    "SnapshotPolicy" -> "SnapshotNow",
    "Identity" -> <||>, "Preview" -> <||>,
    "PrivacyLevel" -> $svWDefaultPL, "Provenance" -> <||>|>;

SourceVault`SourceVaultBindingFromURI[x_] :=
  Module[{env = SourceVault`SourceVaultNormalizeURIEnvelope[x]},
    If[FailureQ[env], Return[env]];
    Join[iSVWBindingBase["URI"],
      <|"URI" -> env["URI"], "SnapshotPolicy" -> "PinnedSnapshot",
        "Identity" -> <|"CanonicalURI" -> env["URI"]|>,
        "PrivacyLevel" -> env["PrivacyLevel"]|>]
  ];

Options[SourceVault`SourceVaultBindingFromValue] =
  Options[SourceVault`SourceVaultMakeValueEnvelope];

SourceVault`SourceVaultBindingFromValue[value_, opts : OptionsPattern[]] :=
  Module[{ve = SourceVault`SourceVaultMakeValueEnvelope[value,
      "Source" -> OptionValue["Source"],
      "PrivacyLevel" -> OptionValue["PrivacyLevel"]]},
    Join[iSVWBindingBase["LiteralValue"],
      <|"Identity" -> <|"ContentHash" -> ve["ContentHash"]|>,
        "Preview" -> <|"Text" -> StringTake[
            ToString[value, InputForm], UpTo[80]], "Redacted" -> False|>,
        "PrivacyLevel" -> ve["PrivacyLevel"],
        "ValueEnvelope" -> ve|>]
  ];

Options[SourceVault`SourceVaultBindingFromVariable] =
  {"SnapshotPolicy" -> "SnapshotNow", "PrivacyLevel" -> Automatic};

SourceVault`SourceVaultBindingFromVariable[name_String, OptionsPattern[]] :=
  Module[{policy = OptionValue["SnapshotPolicy"], pl, val, env, base},
    pl = OptionValue["PrivacyLevel"];
    If[pl === Automatic, pl = $svWDefaultPL];
    base = Join[iSVWBindingBase["VariableRef"],
      <|"SnapshotPolicy" -> policy,
        "Identity" -> <|"SymbolName" -> name,
          "KernelSessionId" -> ToString[$SessionID]|>,
        "PrivacyLevel" -> pl|>];
    Which[
      policy === "LiveAtExecution",
        (* 明示時のみ: 名前の遅延解決。URI なし (§4.5) *)
        base,
      Names[name] === {},
        Failure["UnresolvedBinding",
          <|"MessageTemplate" -> "SourceVault wiring: UnresolvedBinding",
            "Detail" -> <|"SymbolName" -> name,
              "Reason" -> "SymbolNotFound"|>|>],
      True,
        (* 既定 SnapshotNow: 現在値を snapshot artifact 化 (§4.5 表) *)
        val = Symbol[name];
        env = SourceVault`SourceVaultCoerceToURI[
          SourceVault`SourceVaultMakeValueEnvelope[val,
            "Source" -> "VariableSnapshot", "PrivacyLevel" -> pl]];
        If[FailureQ[env], Return[env]];
        Join[base,
          <|"URI" -> env["URI"],
            "Identity" -> Join[base["Identity"],
              <|"ContentHash" -> Lookup[env, "ContentHash", Missing[]]|>],
            "Preview" -> <|"Text" -> StringTake[
                ToString[val, InputForm], UpTo[80]], "Redacted" -> False|>|>]]
  ];

(* ファイル名のみの指定は NotebookDirectory[] 基準で解決する (プロジェクト規約)。
   FE 不在 (headless) や未保存 NB では入力のまま。 *)
iSVWResolveFilePath[path_String] :=
  Which[
    FileExistsQ[path], path,
    FileNameDepth[path] === 1,
      Module[{nb = Quiet @ Check[NotebookDirectory[], $Failed], cand},
        cand = If[StringQ[nb], FileNameJoin[{nb, path}], path];
        If[FileExistsQ[cand], cand, path]],
    True, path];

Options[SourceVault`SourceVaultBindingFromFile] =
  {"Mode" -> "ReferenceOnly", "PrivacyLevel" -> Automatic};

SourceVault`SourceVaultBindingFromFile[pathIn_String, OptionsPattern[]] :=
  Module[{mode = OptionValue["Mode"], pl, base, bytes, hash, env, path},
    pl = OptionValue["PrivacyLevel"];
    If[pl === Automatic, pl = $svWDefaultPL];
    path = iSVWResolveFilePath[pathIn];
    If[!FileExistsQ[path],
      Return[Failure["UnresolvedBinding",
        <|"MessageTemplate" -> "SourceVault wiring: UnresolvedBinding",
          "Detail" -> <|"Path" -> pathIn, "Resolved" -> path,
            "Reason" -> "FileNotFound"|>|>]]];
    base = Join[iSVWBindingBase["FileRef"],
      <|"SnapshotPolicy" -> Switch[mode,
          "ReferenceOnly", "LiveAtExecution", _, "SnapshotNow"],
        "Identity" -> <|"Path" -> ExpandFileName[path],
          "FileByteCount" -> Quiet @ Check[FileByteCount[path], Missing[]],
          "ModificationDate" -> Quiet @ Check[
            DateString[FileDate[path], "ISODateTime"], Missing[]]|>,
        "PrivacyLevel" -> pl|>];
    Switch[mode,
      "ReferenceOnly",
        base,   (* path identity のみ。本文は読まない (§4.5 表) *)
      "HashOnly",
        hash = Quiet @ Check[
          StringPadLeft[IntegerString[Hash[File[path], "SHA256"], 16], 64, "0"],
          Missing["HashFailed"]];
        Join[base, <|"Identity" -> Join[base["Identity"],
          <|"ContentHash" -> hash|>]|>],
      "CopyToArtifact",
        bytes = Quiet @ Check[ReadByteArray[path], $Failed];
        If[bytes === $Failed || bytes === EndOfFile,
          Return[Failure["UnresolvedBinding",
            <|"MessageTemplate" -> "SourceVault wiring: UnresolvedBinding",
              "Detail" -> <|"Path" -> path, "Reason" -> "ReadFailed"|>|>]]];
        env = iSVWDepositBytes[bytes, path, pl];
        If[FailureQ[env], Return[env]];
        Join[base,
          <|"URI" -> env["URI"],
            "Identity" -> Join[base["Identity"],
              <|"ContentHash" -> Lookup[env, "ContentHash", Missing[]]|>]|>],
      _,
        Failure["InvalidBindingMode",
          <|"MessageTemplate" -> "SourceVault wiring: InvalidBindingMode",
            "Detail" -> mode|>]]
  ];

(* ============================================================
   4. deposit (SourceVaultSaveDerivedArtifact / CommitBlob 再利用)
   ============================================================ *)

iSVWDepositAvailableQ[] :=
  Names["SourceVault`SourceVaultSaveDerivedArtifact"] =!= {} &&
  Length[DownValues[SourceVault`SourceVaultSaveDerivedArtifact]] > 0;

(* ValueEnvelope -> WiringValue DerivedArtifact -> URI envelope *)
iSVWDepositValue[ve_?SourceVault`SourceVaultValueEnvelopeQ] :=
  Module[{text, res, uri, pl},
    If[!iSVWDepositAvailableQ[],
      Return[Failure["DepositUnavailable",
        <|"MessageTemplate" -> "SourceVault wiring: DepositUnavailable",
          "Detail" -> "SourceVaultSaveDerivedArtifact not loaded"|>]]];
    (* confidential 文脈では PL 下限を適用し秘密依存データとして保存 *)
    pl = iSVWApplyConfidentialFloor[ve["PrivacyLevel"]];
    text = ToString[ve["Value"], InputForm];
    res = Quiet @ Check[
      SourceVault`SourceVaultSaveDerivedArtifact[<|
        "Text" -> text, "ArtifactType" -> "WiringValue",
        "Provenance" -> Join[<|
          "RequestChannel" -> "Wiring",
          "WLType" -> ve["WLType"], "ValueSource" -> ve["Source"],
          "ContentSHA256" -> ve["ContentHash"],
          "EffectivePolicy" -> <|"PrivacyLevel" -> pl|>|>,
          If[iSVWConfidentialFloorQ[],
            <|"ConfidentialDependent" -> True|>, <||>]]|>],
      $Failed];
    If[!AssociationQ[res] || Lookup[res, "Status", ""] =!= "OK",
      Return[Failure["DepositFailed",
        <|"MessageTemplate" -> "SourceVault wiring: DepositFailed",
          "Detail" -> res|>]]];
    uri = "sv://artifact/" <> ToString[Lookup[res, "ArtifactId", ""]];
    <|"Status" -> "OK", "URI" -> uri,
      "ObjectKind" -> "Artifact", "DomainKind" -> "WiringValue",
      "MediaKind" -> "Text",
      "PrivacyLevel" -> pl,
      "Marked" -> iSVWConfidentialFloorQ[],
      "ContentHash" -> ve["ContentHash"],
      "DerivedArtifactRef" -> Lookup[res, "Ref", Missing[]]|>
  ];

(* バイト列 -> content-addressed blob -> URI envelope (FileRef CopyToArtifact 用) *)
iSVWDepositBytes[bytes_ByteArray, path_String, pl_] :=
  Module[{res, hex},
    If[Names["SourceVault`SourceVaultCommitBlob"] === {},
      Return[Failure["DepositUnavailable",
        <|"MessageTemplate" -> "SourceVault wiring: DepositUnavailable",
          "Detail" -> "SourceVaultCommitBlob not loaded"|>]]];
    res = Quiet @ Check[
      SourceVault`SourceVaultCommitBlob[bytes,
        "Meta" -> <|"Filename" -> FileNameTake[path],
          "Channel" -> "Wiring"|>], $Failed];
    If[!AssociationQ[res] || !StringQ[Lookup[res, "BlobRef", Null]],
      Return[Failure["DepositFailed",
        <|"MessageTemplate" -> "SourceVault wiring: DepositFailed",
          "Detail" -> res|>]]];
    hex = ToString @ Lookup[res, "Hash", ""];
    <|"Status" -> "OK", "URI" -> "sv://hash/sha256/" <> hex,
      "ObjectKind" -> "Artifact", "DomainKind" -> "File",
      "MediaKind" -> "Binary",
      "PrivacyLevel" -> iSVWApplyConfidentialFloor[pl],
      "Marked" -> iSVWConfidentialFloorQ[],
      "ContentHash" -> hex, "BlobRef" -> res["BlobRef"]|>
  ];

(* ============================================================
   5. coercion (§6.3)
   ============================================================ *)

Options[SourceVault`SourceVaultCoerceToURI] =
  {"Source" -> "UserTyped", "PrivacyLevel" -> Automatic};

SourceVault`SourceVaultCoerceToURI[x_, opts : OptionsPattern[]] :=
  Which[
    (* 冪等: 既に envelope / sv:// 文字列 *)
    SourceVault`SourceVaultURIEnvelopeQ[x] ||
      (StringQ[x] && StringStartsQ[x, "sv://"]),
      SourceVault`SourceVaultNormalizeURIEnvelope[x],
    (* ValueEnvelope -> deposit *)
    SourceVault`SourceVaultValueEnvelopeQ[x],
      iSVWDepositValue[x],
    (* PortBindingRef -> kind 別 *)
    SourceVault`SourceVaultPortBindingRefQ[x],
      Which[
        StringQ[Lookup[x, "URI"]],
          SourceVault`SourceVaultNormalizeURIEnvelope[
            <|"Status" -> "OK", "URI" -> x["URI"],
              "PrivacyLevel" -> Lookup[x, "PrivacyLevel", $svWDefaultPL]|>],
        Lookup[x, "BindingKind"] === "LiteralValue" &&
          SourceVault`SourceVaultValueEnvelopeQ[Lookup[x, "ValueEnvelope"]],
          iSVWDepositValue[x["ValueEnvelope"]],
        True,
          Failure["UnresolvedBinding",
            <|"MessageTemplate" -> "SourceVault wiring: UnresolvedBinding",
              "Detail" -> <|"BindingKind" -> Lookup[x, "BindingKind"],
                "Reason" -> "NoURIAndNotDepositable"|>|>]],
    (* 生値 -> ValueEnvelope -> deposit *)
    True,
      iSVWDepositValue[SourceVault`SourceVaultMakeValueEnvelope[x,
        "Source" -> OptionValue["Source"],
        "PrivacyLevel" -> OptionValue["PrivacyLevel"]]]
  ];

Options[SourceVault`SourceVaultCoerceFromURI] = {"Interpret" -> Automatic};

SourceVault`SourceVaultCoerceFromURI[x_, OptionsPattern[]] :=
  Module[{env, res, interpret, isWiringValue, dar},
    env = SourceVault`SourceVaultNormalizeURIEnvelope[x];
    If[FailureQ[env], Return[env]];
    If[Names["SourceVault`SourceVaultResolveArtifactContent"] === {},
      Return[Failure["ResolveUnavailable",
        <|"MessageTemplate" -> "SourceVault wiring: ResolveUnavailable"|>]]];
    res = Quiet @ Check[
      SourceVault`SourceVaultResolveArtifactContent[env["URI"]], $Failed];
    If[!AssociationQ[res] || Lookup[res, "Status", ""] =!= "OK",
      Return[Failure["ResolveFailed",
        <|"MessageTemplate" -> "SourceVault wiring: ResolveFailed",
          "Detail" -> res|>]]];
    interpret = OptionValue["Interpret"];
    (* 自前 deposit (WiringValue) のみ ToExpression 解釈 (コード実行防止) *)
    isWiringValue = Quiet @ Check[
      Module[{ref = Lookup[res, "Ref", Missing[]]},
        StringQ[ref] &&
        Names["SourceVault`SourceVaultDerivedArtifact"] =!= {} &&
        With[{a = SourceVault`SourceVaultDerivedArtifact[ref]},
          AssociationQ[a] &&
          Lookup[a, "ArtifactType", ""] === "WiringValue"]],
      False];
    If[isWiringValue && interpret =!= False &&
       StringQ[Lookup[res, "Text", Null]],
      <|"Status" -> "OK",
        "Value" -> Quiet @ Check[ToExpression[res["Text"]], $Failed],
        "MediaKind" -> Lookup[res, "MediaKind", "Text"],
        "PrivacyLevel" -> Lookup[res, "PrivacyLevel", $svWDefaultPL]|>,
      <|"Status" -> "OK",
        "Text" -> Lookup[res, "Text", Missing[]],
        "Bytes" -> Lookup[res, "Bytes", Missing[]],
        "MediaKind" -> Lookup[res, "MediaKind", Missing[]],
        "PrivacyLevel" -> Lookup[res, "PrivacyLevel", $svWDefaultPL]|>]
  ];

(* ============================================================
   6. port adapter registry + cost 付き経路探索 (§6.3)
   ============================================================ *)

If[!AssociationQ[$svWAdapters], $svWAdapters = <||>];

SourceVault`SourceVaultRegisterPortAdapter[
    from_String, to_String, f_, meta_: <||>] :=
  ($svWAdapters[from <> "->" <> to] =
    <|"From" -> from, "To" -> to, "Function" -> f,
      "Cost" -> Lookup[meta, "Cost", 1],
      "Lossy" -> TrueQ[Lookup[meta, "Lossy", False]]|>;
   <|"Status" -> "OK", "Edge" -> from <> "->" <> to|>);

SourceVault`SourceVaultPortAdapters[] := Values[$svWAdapters];

$svWDefaultAdapterPolicy =
  <|"MaxDepth" -> 2, "MaxCost" -> 3,
    "AllowLossy" -> False, "RequireUniquePath" -> True|>;

Options[SourceVault`SourceVaultFindAdapterPath] =
  {"AdapterPolicy" -> Automatic};

SourceVault`SourceVaultFindAdapterPath[
    from_String, to_String, OptionsPattern[]] :=
  Module[{policy, edges, paths, extend},
    policy = OptionValue["AdapterPolicy"];
    If[!AssociationQ[policy], policy = $svWDefaultAdapterPolicy,
      policy = Join[$svWDefaultAdapterPolicy, policy]];
    If[from === to,
      Return[<|"Status" -> "OK", "Path" -> {}, "Cost" -> 0|>]];
    edges = Values[$svWAdapters];
    If[TrueQ[!policy["AllowLossy"]],
      edges = Select[edges, !TrueQ[#["Lossy"]] &]];
    (* 全経路列挙 (深さ・cost 上限、ノード再訪なし) *)
    extend[path_List] :=
      Module[{cur = If[path === {}, from, Last[path]["To"]],
              cost = Total[Lookup[path, "Cost", 0]]},
        Flatten[
          Map[
            Function[e,
              Which[
                cost + e["Cost"] > policy["MaxCost"], {},
                MemberQ[Lookup[path, "From", {}], e["To"]] || e["To"] === from, {},
                e["From"] =!= cur, {},
                e["To"] === to, {Append[path, e]},
                Length[path] + 1 >= policy["MaxDepth"], {},
                True, extend[Append[path, e]]]],
            edges], 1]];
    paths = extend[{}];
    Which[
      paths === {},
        Failure["NoAdapterPath",
          <|"MessageTemplate" -> "SourceVault wiring: NoAdapterPath",
            "Detail" -> <|"From" -> from, "To" -> to|>|>],
      Length[paths] > 1 && TrueQ[policy["RequireUniquePath"]],
        Failure["AmbiguousAdapterPath",
          <|"MessageTemplate" -> "SourceVault wiring: AmbiguousAdapterPath",
            "Detail" -> <|"From" -> from, "To" -> to,
              "Candidates" -> Map[
                StringRiffle[Join[{#[[1]]["From"]}, Lookup[#, "To"]], " -> "] &,
                paths]|>|>],
      True,
        With[{best = First[SortBy[paths, Total[Lookup[#, "Cost", 0]] &]]},
          <|"Status" -> "OK", "Path" -> best,
            "Cost" -> Total[Lookup[best, "Cost", 0]]|>]]
  ];

SourceVault`SourceVaultApplyAdapterPath[pathResult_Association, input_] :=
  Fold[Function[{acc, edge},
      If[FailureQ[acc], acc, edge["Function"][acc]]],
    input, Lookup[pathResult, "Path", {}]];

(* 組み込み adapter (§6.3 初期セット) *)
SourceVault`SourceVaultRegisterPortAdapter["Value", "URI",
  SourceVault`SourceVaultCoerceToURI, <|"Cost" -> 1|>];
SourceVault`SourceVaultRegisterPortAdapter["URI", "Value",
  SourceVault`SourceVaultCoerceFromURI, <|"Cost" -> 1|>];
SourceVault`SourceVaultRegisterPortAdapter["VariableRef", "URI",
  SourceVault`SourceVaultCoerceToURI, <|"Cost" -> 1|>];
SourceVault`SourceVaultRegisterPortAdapter["FileRef", "URI",
  SourceVault`SourceVaultCoerceToURI, <|"Cost" -> 2|>];
SourceVault`SourceVaultRegisterPortAdapter["LiteralValue", "URI",
  SourceVault`SourceVaultCoerceToURI, <|"Cost" -> 1|>];

(* ============================================================
   7. privacy Max 伝搬 (§6.6 binding 部分)
   ============================================================ *)

iSVWPLOf[x_] :=
  Which[
    SourceVault`SourceVaultURIEnvelopeQ[x] ||
      SourceVault`SourceVaultValueEnvelopeQ[x] ||
      SourceVault`SourceVaultPortBindingRefQ[x],
      With[{pl = Lookup[x, "PrivacyLevel", $svWDefaultPL]},
        If[NumberQ[pl], pl, $svWDefaultPL]],
    StringQ[x] && StringStartsQ[x, "sv://"],
      $svWDefaultPL,      (* metadata 不明の生 URI は fail-closed *)
    True,
      $svWDefaultPL];     (* 判定不能は fail-closed (§6.6) *)

SourceVault`SourceVaultBindingPrivacyMax[bindings_List] :=
  If[bindings === {}, 0., Max[iSVWPLOf /@ bindings]];

(* ============================================================
   8. 関数選定 (§6.2・Inc ε)
      v1 scoring は lexical (BM25 統合は search foundation 後)。
   ============================================================ *)

iSVWContractsAvailableQ[] :=
  Names["SourceVault`SourceVaultFunctionContracts"] =!= {} &&
  Length[DownValues[SourceVault`SourceVaultFunctionContracts]] > 0;

iSVWBigrams[s_String] :=
  With[{t = ToLowerCase[s]},
    If[StringLength[t] < 2, {t},
      Table[StringTake[t, {i, i + 1}], {i, StringLength[t] - 1}]]];

iSVWOverlap[a_String, b_String] :=
  Length[Intersection[iSVWBigrams[a], iSVWBigrams[b]]];

Options[SourceVault`SourceVaultSelectFunctionsForTask] =
  {"IncludeInternal" -> False, "MinScore" -> 1.};

SourceVault`SourceVaultSelectFunctionsForTask[
    taskIn_, OptionsPattern[]] :=
  Module[{task, contracts, cands = {}, rejected = {}, clar = {}},
    task = Which[
      StringQ[taskIn], taskIn,
      AssociationQ[taskIn], Lookup[taskIn, "Task", ""],
      True, ""];
    If[!iSVWContractsAvailableQ[],
      Return[Failure["ContractsUnavailable",
        <|"MessageTemplate" -> "SourceVault wiring: ContractsUnavailable"|>]]];
    contracts = Select[SourceVault`SourceVaultFunctionContracts[],
      Lookup[#, "Kind"] === "Function" &];
    Scan[
      Function[c,
        Module[{sym = c["Symbol"], score = 0., reasons = {}, neg, dnu},
          (* Internal は既定除外 (§6.2 規則 3) *)
          If[Lookup[c, "AbstractionLevel"] === "Internal" &&
             !TrueQ[OptionValue["IncludeInternal"]],
            AppendTo[rejected, <|"Symbol" -> sym,
              "Reason" -> "AbstractionLevel Internal (明示指定時のみ)"|>];
            Return[Null, Module]];
          (* NegativeExamples / DoNotUseWhen 一致 -> Rejected (負の情報) *)
          neg = SelectFirst[Lookup[c, "NegativeExamples", {}],
            Function[n, AssociationQ[n] && StringQ[Lookup[n, "Task"]] &&
              (StringContainsQ[task, n["Task"]] ||
               iSVWOverlap[task, n["Task"]] >= 6)]];
          If[AssociationQ[neg],
            AppendTo[rejected, <|"Symbol" -> sym,
              "Reason" -> Lookup[neg, "Reason", "NegativeExample 一致"]|>];
            Return[Null, Module]];
          dnu = SelectFirst[Lookup[c, "DoNotUseWhen", {}],
            StringQ[#] && StringLength[#] >= 3 &&
              StringContainsQ[task, #] &];
          If[StringQ[dnu],
            AppendTo[rejected, <|"Symbol" -> sym,
              "Reason" -> "DoNotUseWhen: " <> dnu|>];
            Return[Null, Module]];
          (* scoring *)
          If[StringContainsQ[ToLowerCase[task], ToLowerCase[sym]],
            score += 5.; AppendTo[reasons, "SymbolNameInTask"]];
          Scan[
            Function[tag,
              If[AnyTrue[StringSplit[tag, "."],
                  StringLength[#] >= 3 &&
                    StringContainsQ[ToLowerCase[task], ToLowerCase[#]] &],
                score += 1.; AppendTo[reasons, "CapabilityTag: " <> tag]]],
            Lookup[c, "CapabilityTags", {}]];
          With[{ov = Max[0,
              Max[iSVWOverlap[task, #] & /@
                Append[Lookup[c, "IntentExamples", {}], ""]]]},
            If[ov >= 3,
              score += Min[3., ov/3.];
              AppendTo[reasons,
                "IntentExample overlap (" <> ToString[ov] <> ")"]]];
          If[TrueQ[Lookup[c, "RecommendedEntrypoint", False]] && score > 0,
            score += 2.; AppendTo[reasons, "RecommendedEntrypoint"]];
          If[Lookup[c, "AbstractionLevel"] === "UserFacing" && score > 0,
            score += 1.; AppendTo[reasons, "UserFacing"]];
          If[score >= OptionValue["MinScore"],
            AppendTo[cands, <|"Symbol" -> sym, "Score" -> score,
              "Reasons" -> reasons|>]]]],
      contracts];
    cands = Reverse @ SortBy[cands, Lookup[#, "Score"] &];
    If[cands === {},
      AppendTo[clar,
        "該当する契約付き関数が見つからない。task をより具体的にするか、対象関数名を明示してほしい。"]];
    <|"Candidates" -> cands, "Rejected" -> rejected,
      "Clarifications" -> clar|>
  ];

(* ============================================================
   9. wiring planner (§6.4 決定的束縛 / §6.7 三層・Inc ε)
   ============================================================ *)

iSVWCtxOf[c_Association] :=
  Lookup[c, "Context", Lookup[c, "Package", "SourceVault"] <> "`"];

(* binding 候補レコードへ正規化。TaskSpec Inputs の要素:
   PortBindingRef (+任意 "Name") | <|"Name"->_, "Binding"->ref|> | 生値 *)
iSVWNormalizeTaskInput[x_, idx_Integer] :=
  Which[
    AssociationQ[x] && KeyExistsQ[x, "Binding"],
      iSVWCandRecord[Lookup[x, "Name", Missing[]], x["Binding"],
        "TaskInput:" <> ToString[Lookup[x, "Name", idx]]],
    SourceVault`SourceVaultPortBindingRefQ[x],
      iSVWCandRecord[Lookup[x, "Name", Missing[]], x,
        "TaskInput:" <> ToString[Lookup[x, "Name", idx]]],
    True,
      iSVWCandRecord[Missing[],
        SourceVault`SourceVaultBindingFromValue[x],
        "TaskInput:" <> ToString[idx]]];

iSVWCandRecord[name_, binding_, from_String] :=
  Module[{ve = Lookup[binding, "ValueEnvelope", <||>]},
    <|"Name" -> name, "From" -> from, "Binding" -> binding,
      "Label" -> Which[
        StringQ[Lookup[binding, "URI"]], "URI",
        Lookup[binding, "BindingKind"] === "LiteralValue", "Value",
        True, Lookup[binding, "BindingKind", "Value"]],
      "DomainKind" -> Lookup[binding, "DomainKind", Missing[]],
      "MediaKind" -> Lookup[binding, "MediaKind", Missing[]],
      "WLType" -> Lookup[ve, "WLType", Missing[]],
      "PrivacyLevel" -> Lookup[binding, "PrivacyLevel", $svWDefaultPL]|>];

(* 決定的束縛規則 (§6.4、優先順固定・上から)。
   一意 -> Match、複数 -> Ambiguous (推測しない)、0 -> 次規則。 *)
iSVWMatchPort[port_Association, cands_List] :=
  Module[{try},
    try[matches_, rule_] :=
      Which[
        Length[matches] === 1,
          Throw[<|"Match" -> First[matches], "Rule" -> rule|>, "svwMatch"],
        Length[matches] > 1,
          Throw[<|"Ambiguous" -> matches, "Rule" -> rule|>, "svwMatch"]];
    Catch[
      (* 1. ポート名完全一致 *)
      try[Select[cands, Lookup[#, "Name"] === port["Name"] &], "NameExact"];
      (* 2. DomainKind 一致 *)
      If[StringQ[Lookup[port, "DomainKind"]],
        try[Select[cands,
          Lookup[#, "DomainKind"] === port["DomainKind"] &], "DomainKind"]];
      (* 3. MediaKind 一致 *)
      If[StringQ[Lookup[port, "MediaKind"]],
        try[Select[cands,
          Lookup[#, "MediaKind"] === port["MediaKind"] &], "MediaKind"]];
      (* 4. WLType 一意一致 (Value ポートのみ) *)
      If[Lookup[port, "PortType"] === "Value" &&
         StringQ[Lookup[port, "WLType"]] &&
         !StringContainsQ[Lookup[port, "WLType"], "|"],
        try[Select[cands,
          Lookup[#, "WLType"] === port["WLType"] &], "WLTypeUnique"]];
      (* 5. adapter 一意経路で成立 *)
      try[Select[cands,
        Function[cnd,
          With[{p = SourceVault`SourceVaultFindAdapterPath[
              cnd["Label"], Lookup[port, "PortType", "Value"]]},
            !FailureQ[p] && p["Path"] =!= {}]]], "AdapterPath"];
      <|"NoMatch" -> True|>,
      "svwMatch"]
  ];

Options[SourceVault`SourceVaultProposeWiringPlan] = {};

SourceVault`SourceVaultProposeWiringPlan[
    taskSpec_Association, OptionsPattern[]] :=
  Module[{task, steps, taskInputs, stepOutputs = {}, planSteps = {},
          unresolved = {}, usedPLs = {}, sel},
    If[!iSVWContractsAvailableQ[],
      Return[Failure["ContractsUnavailable",
        <|"MessageTemplate" -> "SourceVault wiring: ContractsUnavailable"|>]]];
    task = Lookup[taskSpec, "Task", ""];
    steps = Lookup[taskSpec, "Steps", Automatic];
    If[steps === Automatic,
      sel = SourceVault`SourceVaultSelectFunctionsForTask[taskSpec];
      steps = If[!FailureQ[sel] && sel["Candidates"] =!= {},
        {First[sel["Candidates"]]["Symbol"]}, {}]];
    taskInputs = MapIndexed[
      iSVWNormalizeTaskInput[#1, First[#2]] &,
      Lookup[taskSpec, "Inputs", {}]];

    Scan[
      Function[sym,
        Module[{c = SourceVault`SourceVaultFunctionContract[sym],
                bindings = {}, cands},
          If[MissingQ[c],
            AppendTo[unresolved, <|"Step" -> sym, "Port" -> All,
              "Reason" -> "NoContract", "Candidates" -> {}|>];
            Return[Null, Module]];
          cands = Join[taskInputs, stepOutputs];
          Scan[
            Function[port,
              Module[{m = iSVWMatchPort[port, cands]},
                Which[
                  KeyExistsQ[m, "Match"],
                    AppendTo[usedPLs,
                      Lookup[m["Match"], "PrivacyLevel", $svWDefaultPL]];
                    If[NumberQ[Lookup[port, "PrivacyFloor"]],
                      AppendTo[usedPLs, port["PrivacyFloor"]]];
                    AppendTo[bindings,
                      <|"To" -> port["Name"],
                        "From" -> m["Match"]["From"],
                        "Binding" -> m["Match"]["Binding"],
                        "MatchedBy" -> m["Rule"],
                        "FilledBy" -> "Deterministic"|>],
                  KeyExistsQ[m, "Ambiguous"],
                    AppendTo[unresolved,
                      <|"Step" -> sym, "Port" -> port["Name"],
                        "Reason" -> "Ambiguous",
                        "Rule" -> m["Rule"],
                        "Candidates" -> Lookup[m["Ambiguous"], "From"],
                        "CandidateRecords" -> m["Ambiguous"],
                        "PortDecl" -> port|>],
                  TrueQ[Lookup[port, "Required", True]],
                    AppendTo[unresolved,
                      <|"Step" -> sym, "Port" -> port["Name"],
                        "Reason" -> "NoCandidates", "Candidates" -> {}|>]
                  (* optional 未束縛は黙って省略 *)]]],
            Lookup[c, "Inputs", {}]];
          AppendTo[planSteps, <|"Symbol" -> sym, "Bindings" -> bindings|>];
          (* この step の出力を後続の候補プールへ *)
          Scan[
            Function[out,
              AppendTo[stepOutputs,
                <|"Name" -> out["Name"],
                  "From" -> "StepOutput:" <> sym <> ":" <> out["Name"],
                  "Binding" -> <|"ObjectClass" -> "SourceVaultPortBindingRef",
                    "BindingKind" -> "StepOutput",
                    "Step" -> sym, "Port" -> out["Name"],
                    "PrivacyLevel" -> $svWDefaultPL|>,
                  "Label" -> If[Lookup[out, "PortType"] === "URI",
                    "URI", "Value"],
                  "DomainKind" -> Lookup[out, "DomainKind", Missing[]],
                  "MediaKind" -> Lookup[out, "MediaKind", Missing[]],
                  "WLType" -> Lookup[out, "WLType", Missing[]],
                  "PrivacyLevel" -> $svWDefaultPL|>]],
            Lookup[c, "Outputs", {}]]]],
      steps];

    Module[{plan},
      plan = <|"ObjectClass" -> "SourceVaultWiringPlan",
        "Task" -> task, "TaskSpec" -> taskSpec,
        "Steps" -> planSteps,
        "Unresolved" -> unresolved,
        "PrivacyEstimate" -> <|
          "PrivacyLevel" -> If[usedPLs === {}, 0., Max[usedPLs]],
          "Confidence" -> "High"|>,
        "Mode" -> "Deterministic", "Warnings" -> {},
        "Status" -> If[unresolved === {}, "OK", "Incomplete"]|>;
      (* Hybrid (TaskSpec 既定、spec §4.7): Ambiguous 残余のみ LLM で埋める (W4) *)
      If[Lookup[taskSpec, "WiringMode", "Hybrid"] === "Hybrid" &&
         unresolved =!= {},
        plan = SourceVault`SourceVaultFillUnresolvedWithLLM[plan]];
      plan]
  ];

(* ============================================================
   9.5 LLM wiring (§6.5・Inc η): Hybrid の残余埋め
   ============================================================ *)

If[!ValueQ[SourceVault`$SourceVaultWiringLLM],
  SourceVault`$SourceVaultWiringLLM = None];

(* エンジン解決: 明示設定 > ClaudeQuerySync (弱結合、ローカルモデル強制) > None *)
iSVWResolveLLMEngine[] :=
  Which[
    SourceVault`$SourceVaultWiringLLM =!= None,
      SourceVault`$SourceVaultWiringLLM,
    Names["ClaudeCode`ClaudeQuerySync"] =!= {} &&
      Length[DownValues[Evaluate @ Symbol["ClaudeCode`ClaudeQuerySync"]]] > 0,
      With[{f = Symbol["ClaudeCode`ClaudeQuerySync"],
            plOpt = Symbol["ClaudeCode`PrivacyLevel"]},
        Function[prompt, f[prompt, plOpt -> 1.0]]],
    True, None];

(* 候補 1 件を LLM 提示用 1 行に (identity のみ、本文なし、Redacted 除外 §6.5) *)
iSVWCandLine[i_Integer, rec_Association] :=
  ToString[i] <> ". From \"" <> rec["From"] <> "\" (" <>
  ToString[Lookup[rec["Binding"], "BindingKind", "?"]] <>
  With[{dk = Lookup[rec, "DomainKind"]},
    If[StringQ[dk], ", DomainKind " <> dk, ""]] <>
  With[{wt = Lookup[rec, "WLType"]},
    If[StringQ[wt], ", WLType " <> wt, ""]] <>
  With[{pv = Lookup[Lookup[rec["Binding"], "Preview", <||>], "Text"],
        red = Lookup[Lookup[rec["Binding"], "Preview", <||>],
          "Redacted", True]},
    If[StringQ[pv] && !TrueQ[red], ", preview: \"" <> pv <> "\"", ""]] <>
  ")";

iSVWStripJSONFences[s_String] :=
  StringTrim @ StringReplace[s,
    {StartOfString ~~ "```" ~~ Shortest[___] ~~ "\n" -> "",
     "```" ~~ EndOfString -> ""}];

Options[SourceVault`SourceVaultFillUnresolvedWithLLM] = {};

SourceVault`SourceVaultFillUnresolvedWithLLM[
    plan_Association, OptionsPattern[]] :=
  Module[{engine, ambiguous, prompt, resp, json, choices,
          steps, unresolved, warnings, filled = 0, filledPLs = {}},
    engine = iSVWResolveLLMEngine[];
    ambiguous = Select[Lookup[plan, "Unresolved", {}],
      Lookup[#, "Reason"] === "Ambiguous" &&
        KeyExistsQ[#, "CandidateRecords"] &];
    If[engine === None || ambiguous === {},
      Return[If[engine === None && ambiguous =!= {},
        Append[plan, "Warnings" -> Append[Lookup[plan, "Warnings", {}],
          "LLMEngineUnavailable: Ambiguous ports left unresolved"]],
        plan]]];

    prompt = StringRiffle[Join[
      {"You are resolving data bindings for a function-call plan.",
       "Task: " <> Lookup[plan, "Task", ""],
       "For each unresolved port below, choose exactly ONE candidate by its From ref.",
       "Respond with ONLY this JSON, no prose, no code fences:",
       "{\"bindings\":[{\"step\":\"<symbol>\",\"port\":\"<port>\",\"chosen\":\"<From ref>\"}]}",
       "", "Unresolved ports:"},
      Flatten @ Map[
        Function[u,
          Join[
            {"- step " <> u["Step"] <> ", port " <> u["Port"] <>
             With[{pd = Lookup[u, "PortDecl", <||>]},
               " (PortType " <> ToString[Lookup[pd, "PortType", "?"]] <>
               With[{dk = Lookup[pd, "DomainKind"]},
                 If[StringQ[dk], ", DomainKind " <> dk, ""]] <> ")"],
             "  candidates:"},
            MapIndexed[
              "  " <> iSVWCandLine[First[#2], #1] &,
              u["CandidateRecords"]]]],
        ambiguous]], "\n"];

    resp = Quiet @ Check[TimeConstrained[engine[prompt], 120, $Failed],
      $Failed];
    If[!StringQ[resp],
      Return[Append[plan, "Warnings" -> Append[
        Lookup[plan, "Warnings", {}], "LLMCallFailed"]]]];
    json = Quiet @ Check[
      ImportString[iSVWStripJSONFences[resp], "RawJSON"], $Failed];
    choices = If[AssociationQ[json], Lookup[json, "bindings", {}], $Failed];
    If[!ListQ[choices],
      Return[Append[plan, "Warnings" -> Append[
        Lookup[plan, "Warnings", {}], "LLMResponseUnparsable"]]]];

    steps = plan["Steps"];
    unresolved = plan["Unresolved"];
    warnings = Lookup[plan, "Warnings", {}];
    Scan[
      Function[ch,
        Module[{stepSym, portName, chosen, u, rec},
          If[!AssociationQ[ch], Return[Null, Module]];
          stepSym  = Lookup[ch, "step"];
          portName = Lookup[ch, "port"];
          chosen   = Lookup[ch, "chosen"];
          u = SelectFirst[unresolved,
            Lookup[#, "Step"] === stepSym &&
              Lookup[#, "Port"] === portName &&
              Lookup[#, "Reason"] === "Ambiguous" &];
          If[!AssociationQ[u], Return[Null, Module]];
          (* validate-then-accept (W4): 候補 enum 外の選択は破棄 *)
          rec = SelectFirst[u["CandidateRecords"],
            Lookup[#, "From"] === chosen &];
          If[!AssociationQ[rec],
            AppendTo[warnings, "LLMChoiceRejected: " <> stepSym <> "/" <>
              ToString[portName] <> " -> " <> ToString[chosen]];
            Return[Null, Module]];
          steps = Map[
            Function[s,
              If[s["Symbol"] === stepSym,
                Append[s, "Bindings" -> Append[s["Bindings"],
                  <|"To" -> portName, "From" -> rec["From"],
                    "Binding" -> rec["Binding"],
                    "MatchedBy" -> "LLM", "FilledBy" -> "LLM"|>]],
                s]],
            steps];
          AppendTo[filledPLs,
            Lookup[rec, "PrivacyLevel", $svWDefaultPL]];
          unresolved = DeleteCases[unresolved,
            x_ /; Lookup[x, "Step"] === stepSym &&
                  Lookup[x, "Port"] === portName];
          filled++]],
      choices];

    Join[plan, <|
      "Steps" -> steps, "Unresolved" -> unresolved,
      "Warnings" -> warnings,
      "PrivacyEstimate" -> <|
        "PrivacyLevel" -> Max[Join[
          {Lookup[Lookup[plan, "PrivacyEstimate", <||>],
            "PrivacyLevel", 0.]}, filledPLs]],
        "Confidence" -> If[filled > 0, "Medium", "High"]|>,
      "Mode" -> If[filled > 0,
        "Hybrid(LLM-filled: " <> ToString[filled] <> ")", plan["Mode"]],
      "Status" -> If[unresolved === {}, "OK", "Incomplete"]|>]
  ];

(* --- step -> code 文字列 (§6.7 WiringPlanExpression) --- *)

iSVWVarName[i_Integer] := "svwOut" <> ToString[i];

iSVWArgCode[bindingRec_, port_, stepVars_Association] :=
  Module[{b = bindingRec["Binding"], from = bindingRec["From"], uri},
    Which[
      StringStartsQ[from, "StepOutput:"],
        With[{var = Lookup[stepVars, StringDrop[from, 11], "$Failed"]},
          If[Lookup[port, "PortType"] === "Value" &&
             StringQ[var] && var =!= "$Failed",
            var, var]],
      Lookup[b, "BindingKind"] === "LiteralValue",
        If[Lookup[port, "PortType"] === "URI",
          "SourceVault`SourceVaultCoerceToURI[" <>
            ToString[b["ValueEnvelope"]["Value"], InputForm] <> "]",
          ToString[b["ValueEnvelope"]["Value"], InputForm]],
      StringQ[Lookup[b, "URI"]],
        uri = b["URI"];
        If[Lookup[port, "PortType"] === "URI",
          "\"" <> uri <> "\"",
          "SourceVault`SourceVaultCoerceFromURI[\"" <> uri <>
            "\"][\"Value\"]"],
      True, "$Failed"]
  ];

iSVWStepCode[step_Association, stepVars_Association] :=
  Module[{c = SourceVault`SourceVaultFunctionContract[step["Symbol"]],
          form, args, portOf, bindingOf},
    If[MissingQ[c], Return[$Failed]];
    form = SelectFirst[Lookup[c, "CallForms", {}],
      TrueQ[Lookup[#, "UseForClaudeEval", True]] &];
    If[!AssociationQ[form], Return[$Failed]];
    portOf[pname_] := SelectFirst[Lookup[c, "Inputs", {}],
      Lookup[#, "Name"] === pname &];
    bindingOf[pname_] := SelectFirst[step["Bindings"],
      Lookup[#, "To"] === pname &];
    args = Map[
      Function[a,
        Which[
          Lookup[a, "Kind"] === "OptionsPattern", Nothing,
          StringQ[Lookup[a, "MapsToPort"]],
            With[{br = bindingOf[a["MapsToPort"]],
                  p = portOf[a["MapsToPort"]]},
              If[AssociationQ[br] && AssociationQ[p],
                iSVWArgCode[br, p, stepVars],
                If[TrueQ[Lookup[a, "Required", True]], "$Failed", Nothing]]],
          True, Nothing]],
      Lookup[form, "Arguments", {}]];
    iSVWCtxOf[c] <> step["Symbol"] <> "[" <> StringRiffle[args, ", "] <> "]"
  ];

SourceVault`SourceVaultWiringPlanExpression[plan_Association] :=
  Module[{stepVars = <||>, lines = {}, vars = {}, code, held},
    MapIndexed[
      Function[{step, idx},
        Module[{i = First[idx], var, c},
          var = iSVWVarName[i];
          AppendTo[vars, var];
          c = SourceVault`SourceVaultFunctionContract[step["Symbol"]];
          (* この step の出力を変数名に対応づけ *)
          If[!MissingQ[c],
            Scan[
              Function[out,
                stepVars[step["Symbol"] <> ":" <> out["Name"]] = var],
              Lookup[c, "Outputs", {}]]];
          AppendTo[lines,
            "SourceVault`SourceVaultEnsureInitialized[\"" <>
              step["Symbol"] <> "\"]"];
          AppendTo[lines,
            var <> " = " <> iSVWStepCode[step, stepVars]]]],
      plan["Steps"]];
    code = "Module[{" <> StringRiffle[vars, ", "] <> "}, " <>
      StringRiffle[lines, "; "] <> "; " <> Last[vars, "Null"] <> "]";
    held = Quiet @ Check[ToExpression[code, InputForm, HoldComplete], $Failed];
    <|"Code" -> code, "HeldExpr" -> held|>
  ];

SourceVault`SourceVaultValidateWiringPlan[plan_Association] :=
  Module[{fails = {}, stepVars = <||>},
    If[plan["Status"] === "Incomplete",
      Scan[
        AppendTo[fails, Failure["UnresolvedBinding",
          <|"MessageTemplate" -> "SourceVault wiring: UnresolvedBinding",
            "Detail" -> #|>]] &,
        plan["Unresolved"]];
      Return[<|"Status" -> "Incomplete", "Failures" -> fails|>]];
    MapIndexed[
      Function[{step, idx},
        Module[{c = SourceVault`SourceVaultFunctionContract[step["Symbol"]],
                codeStr, vr, ip},
          If[!MissingQ[c],
            Scan[Function[out,
                stepVars[step["Symbol"] <> ":" <> out["Name"]] =
                  iSVWVarName[First[idx]]],
              Lookup[c, "Outputs", {}]]];
          codeStr = iSVWStepCode[step, stepVars];
          If[codeStr === $Failed || StringContainsQ[codeStr, "$Failed"],
            AppendTo[fails, Failure["UnresolvedBinding",
              <|"MessageTemplate" -> "SourceVault wiring: UnresolvedBinding",
                "Detail" -> <|"Step" -> step["Symbol"],
                  "Reason" -> "CodeGenerationFailed"|>|>]],
            vr = SourceVault`SourceVaultValidateCallExpression[codeStr];
            If[AssociationQ[vr] && vr["Status"] === "Failed",
              fails = Join[fails, vr["Failures"]]]];
          ip = SourceVault`SourceVaultInitPlan[step["Symbol"]];
          If[FailureQ[ip], AppendTo[fails, ip]]]],
      plan["Steps"]];
    <|"Status" -> If[fails === {}, "OK", "Failed"], "Failures" -> fails|>
  ];

(* --- 実行層 (§6.7、manual / tests / 承認済み workflow 用) --- *)

$svWEffectHeads = {"NotebookWrite", "FileWrite", "Network", "LLMCall"};

iSVWArgValue[bindingRec_, port_, env_Association] :=
  Module[{b = bindingRec["Binding"], from = bindingRec["From"], v},
    Which[
      StringStartsQ[from, "StepOutput:"],
        v = Lookup[env, StringDrop[from, 11], $Failed];
        If[Lookup[port, "PortType"] === "Value" &&
           SourceVault`SourceVaultURIEnvelopeQ[v],
          Lookup[SourceVault`SourceVaultCoerceFromURI[v], "Value", $Failed],
          v],
      Lookup[b, "BindingKind"] === "LiteralValue",
        If[Lookup[port, "PortType"] === "URI",
          SourceVault`SourceVaultCoerceToURI[b["ValueEnvelope"]],
          b["ValueEnvelope"]["Value"]],
      StringQ[Lookup[b, "URI"]],
        If[Lookup[port, "PortType"] === "URI",
          SourceVault`SourceVaultNormalizeURIEnvelope[b["URI"]],
          Lookup[SourceVault`SourceVaultCoerceFromURI[b["URI"]],
            "Value", $Failed]],
      True, $Failed]
  ];

Options[SourceVault`SourceVaultExecuteWiringPlan] =
  {"OnMissingInput" -> "Return", "AllowEffects" -> False};

SourceVault`SourceVaultExecuteWiringPlan[
    plan_Association, OptionsPattern[]] :=
  Module[{env = <||>, results = <||>, lastRes = Null},
    (* required input 未充足: 実行せず AwaitingInput を返すだけ。
       notebook 挿入は notebook-facing wrapper の責務 (r2 §6.7 責務分離) *)
    If[plan["Status"] === "Incomplete",
      Return[<|"Status" -> "AwaitingInput",
        "InputBlockSpec" -> plan["Unresolved"]|>]];
    Catch[
      Scan[
        Function[step,
          Module[{sym = step["Symbol"],
                  c = SourceVault`SourceVaultFunctionContract[step["Symbol"]],
                  effects, f, argVals, res, portOf},
            If[MissingQ[c],
              Throw[Failure["UnresolvedBinding",
                <|"MessageTemplate" ->
                    "SourceVault wiring: UnresolvedBinding",
                  "Detail" -> <|"Step" -> sym, "Reason" -> "NoContract"|>,
                  "StepResults" -> results|>], "svwExec"]];
            (* Effects gate (§6.7): 副作用 step は既定拒否 *)
            effects = Intersection[Lookup[c, "Effects", {}], $svWEffectHeads];
            If[effects =!= {} && !TrueQ[OptionValue["AllowEffects"]],
              Throw[Failure["EffectsApprovalRequired",
                <|"MessageTemplate" ->
                    "SourceVault wiring: EffectsApprovalRequired",
                  "Detail" -> <|"Step" -> sym, "Effects" -> effects|>,
                  "StepResults" -> results|>], "svwExec"]];
            SourceVault`SourceVaultEnsureInitialized[sym];
            portOf[pname_] := SelectFirst[Lookup[c, "Inputs", {}],
              Lookup[#, "Name"] === pname &];
            argVals = Map[
              Function[a,
                Which[
                  Lookup[a, "Kind"] === "OptionsPattern", Nothing,
                  StringQ[Lookup[a, "MapsToPort"]],
                    With[{br = SelectFirst[step["Bindings"],
                        Lookup[#, "To"] === a["MapsToPort"] &]},
                      If[AssociationQ[br],
                        iSVWArgValue[br, portOf[a["MapsToPort"]], env],
                        Nothing]],
                  True, Nothing]],
              Lookup[SelectFirst[Lookup[c, "CallForms", {}],
                  TrueQ[Lookup[#, "UseForClaudeEval", True]] &, <||>],
                "Arguments", {}]];
            f = iSVWResolveHeadSymbol[iSVWCtxOf[c] <> sym];
            If[f === $Failed,
              Throw[Failure["UnresolvedBinding",
                <|"MessageTemplate" ->
                    "SourceVault wiring: UnresolvedBinding",
                  "Detail" -> <|"Step" -> sym,
                    "Reason" -> "HeadUnresolved"|>,
                  "StepResults" -> results|>], "svwExec"]];
            res = Quiet @ Check[f @@ argVals, $Failed];
            If[res === $Failed || FailureQ[res],
              Throw[Failure["StepFailed",
                <|"MessageTemplate" -> "SourceVault wiring: StepFailed",
                  "Detail" -> <|"Step" -> sym, "Result" -> res|>,
                  "StepResults" -> results|>], "svwExec"]];
            (* 出力の URI 正規化 (W3): 契約が URI 宣言なのに生値ならここで包む *)
            Scan[
              Function[out,
                Module[{stored = res},
                  If[Lookup[out, "PortType"] === "URI" &&
                     !SourceVault`SourceVaultURIEnvelopeQ[stored] &&
                     !(StringQ[stored] && StringStartsQ[stored, "sv://"]),
                    stored = SourceVault`SourceVaultCoerceToURI[stored,
                      "Source" -> "StepOutput"]];
                  env[sym <> ":" <> out["Name"]] =
                    If[StringQ[stored] && StringStartsQ[stored, "sv://"],
                      SourceVault`SourceVaultNormalizeURIEnvelope[stored],
                      stored];
                  results[sym] = env[sym <> ":" <> out["Name"]]]],
              Lookup[c, "Outputs", {}]];
            If[Lookup[c, "Outputs", {}] === {}, results[sym] = res];
            lastRes = Lookup[results, sym, res]]],
        plan["Steps"]];
      <|"Status" -> "OK", "StepResults" -> results, "Result" -> lastRes|>,
      "svwExec"]
  ];

iSVWResolveHeadSymbol[fq_String] :=
  If[Names[fq] =!= {}, Symbol[fq], $Failed];

(* ============================================================
   10. NB 境界 (§7.1 / §7.2 / §7.3・Inc ζ)
   ============================================================ *)

iSVWCellPlainText[cellExpr_] :=
  Quiet @ Check[
    First @ FrontEndExecute[
      FrontEnd`ExportPacket[cellExpr, "PlainText"]],
    $Failed];

Options[SourceVault`SourceVaultCellInput] =
  {"Cells" -> Automatic, "PrivacyLevel" -> Automatic};

SourceVault`SourceVaultCellInput[nb_NotebookObject, OptionsPattern[]] :=
  Module[{cells = OptionValue["Cells"], pl, nbRef, out = {}},
    If[$FrontEnd === Null,
      Return[Failure["NoFrontEnd",
        <|"MessageTemplate" -> "SourceVault wiring: NoFrontEnd"|>]]];
    pl = OptionValue["PrivacyLevel"];
    If[pl === Automatic, pl = $svWDefaultPL];   (* セルを 0 にしない (§7.1) *)
    If[cells === Automatic,
      cells = Quiet @ Check[SelectedCells[nb], {}];
      (* Shift+Enter 評価では選択が評価セル直下の挿入点に移り SelectedCells が
         空になる。その場合は「評価セルの直前のセル」を既定入力にする
         (ノートブックの自然な操作: 上のセルを入力として下で評価する)。 *)
      If[cells === {},
        With[{ec = Quiet @ Check[EvaluationCell[], $Failed]},
          If[MatchQ[ec, _CellObject],
            With[{pc = Quiet @ Check[PreviousCell[ec], $Failed]},
              If[MatchQ[pc, _CellObject], cells = {pc}]]]]]];
    If[!ListQ[cells] || cells === {},
      Return[Failure["NoCellsSelected",
        <|"MessageTemplate" -> "SourceVault wiring: NoCellsSelected"|>]]];
    nbRef = Quiet @ Check[NotebookFileName[nb], ToString[nb]];
    Scan[
      Function[cell,
        Module[{uuid, txt, env, binding},
          uuid = Quiet @ Check[
            CurrentValue[cell, ExpressionUUID], Missing["NoUUID"]];
          txt = iSVWCellPlainText[NotebookRead[cell]];
          If[!StringQ[txt], txt = ""];
          (* SnapshotNow: セル本文を artifact 化 (§4.5 表) *)
          env = SourceVault`SourceVaultCoerceToURI[
            SourceVault`SourceVaultMakeValueEnvelope[txt,
              "Source" -> "NotebookCell", "PrivacyLevel" -> pl]];
          binding = Join[iSVWBindingBase["NotebookCellRef"],
            <|"URI" -> If[FailureQ[env], Missing[], env["URI"]],
              "SnapshotPolicy" -> "SnapshotNow",
              "Identity" -> <|"NotebookRef" -> nbRef, "CellUUID" -> uuid,
                "ContentHash" -> If[FailureQ[env], Missing[],
                  Lookup[env, "ContentHash", Missing[]]]|>,
              "Preview" -> <|"Text" -> StringTake[txt, UpTo[80]],
                "Redacted" -> (pl >= 0.5)|>,
              "PrivacyLevel" -> pl,
              "Provenance" -> <|"NotebookRef" -> nbRef,
                "CellUUID" -> uuid|>|>];
          AppendTo[out, binding]]],
      cells];
    out
  ];

(* Text 書き出し: markdown 対応の ClaudeWriteResponse を弱結合で優先、
   無ければ NBAccess`NBWriteText (rule 11: Names 検査のみ、Needs しない) *)
iSVWWriteText[nb_, text_String] :=
  If[Names["ClaudeCode`ClaudeWriteResponse"] =!= {},
    Quiet @ Check[
      Symbol["ClaudeCode`ClaudeWriteResponse"][nb, text]; True, False],
    Quiet @ Check[
      NBAccess`NBWriteText[nb, text, "Text"]; True, False]];

iSVWWriteEnvelope[nb_, env_Association] :=
  Module[{r, img},
    r = SourceVault`SourceVaultCoerceFromURI[env, "Interpret" -> False];
    Which[
      FailureQ[r],
        iSVWWriteText[nb,
          "[SourceVault] " <> Lookup[env, "URI", "?"] <> " (unresolvable)"],
      Lookup[env, "MediaKind"] === "Image" &&
        ByteArrayQ[Lookup[r, "Bytes", Null]],
        img = Quiet @ Check[ImportByteArray[r["Bytes"]], $Failed];
        If[ImageQ[img],
          Quiet @ Check[
            NBAccess`NBWriteCell[nb,
              Cell[BoxData[ToBoxes[img]], "Output"]]; True, False],
          iSVWWriteText[nb, "[SourceVault image] " <> env["URI"]]],
      StringQ[Lookup[r, "Text", Null]],
        iSVWWriteText[nb, r["Text"]],
      True,
        iSVWWriteText[nb,
          "[SourceVault] " <> Lookup[env, "URI", "?"] <>
          " (MediaKind: " <> ToString[Lookup[env, "MediaKind", "?"]] <>
          ", PrivacyLevel: " <>
          ToString[Lookup[env, "PrivacyLevel", "?"]] <> ")"]]
  ];

Options[SourceVault`SourceVaultCellOutput] = {};

SourceVault`SourceVaultCellOutput[x_, nb_NotebookObject,
    OptionsPattern[]] :=
  Module[{items, written = 0},
    items = Which[
      SourceVault`SourceVaultURIEnvelopeQ[x], {x},
      (* ExecuteWiringPlan の戻り値: Result を書き出す *)
      AssociationQ[x] && KeyExistsQ[x, "StepResults"],
        {Lookup[x, "Result", Missing[]]},
      ListQ[x], x,
      True, {x}];
    Scan[
      Function[item,
        Module[{ok},
          ok = Which[
            SourceVault`SourceVaultURIEnvelopeQ[item],
              iSVWWriteEnvelope[nb, item],
            StringQ[item] && StringStartsQ[item, "sv://"],
              iSVWWriteEnvelope[nb,
                SourceVault`SourceVaultNormalizeURIEnvelope[item]],
            StringQ[item],
              iSVWWriteText[nb, item],
            MissingQ[item], False,
            True,
              Quiet @ Check[
                NBAccess`NBWriteCell[nb,
                  Cell[BoxData[ToBoxes[item]], "Output"]]; True, False]];
          If[TrueQ[ok], written++]]],
      items];
    <|"Status" -> If[written > 0, "OK", "NothingWritten"],
      "Written" -> written|>
  ];

SourceVault`SourceVaultCellOutput[x_, Except[_NotebookObject], ___] :=
  Failure["InvalidNotebook",
    <|"MessageTemplate" -> "SourceVault wiring: InvalidNotebook"|>];

(* --- §7.3: claudecode hook への弱結合登録 (両側 handshake、Inc γ と同型) --- *)
iSVWWireCellHooks[] :=
  Scan[
    Function[pair,
      With[{hook = pair[[1]], fn = pair[[2]]},
        If[Names[hook] =!= {},
          With[{cur = Quiet @ Check[Symbol[hook], $Failed]},
            If[cur === None,
              ToExpression[hook <> " = " <> fn]]]]]],
    {{"ClaudeCode`$ClaudeCellInputProvider",
      "SourceVault`SourceVaultCellInput"},
     {"ClaudeCode`$ClaudeCellOutputProvider",
      "SourceVault`SourceVaultCellOutput"}}];

Quiet @ Check[iSVWWireCellHooks[], Null];

(* ============================================================
   11. workflow 起動シーケンス (§7.4・Inc θ)
       正本は notebook 上の WorkflowInputBlock。起動は式評価に一本化 (W9)。
   ============================================================ *)

If[!AssociationQ[$svWWorkflowRegistry], $svWWorkflowRegistry = <||>];

SourceVault`SourceVaultRegisterWiringWorkflow[
    name_String, taskSpec_Association] :=
  ($svWWorkflowRegistry[name] = taskSpec;
   <|"Status" -> "OK", "Name" -> name|>);

(* PlanHash: 同一 workflow + 同一未充足 schema の判定鍵 (§7.4.2) *)
iSVWPlanHash[plan_Association] :=
  StringPadLeft[IntegerString[Hash[{
    Lookup[plan, "Task", ""],
    Lookup[#, "Symbol"] & /@ Lookup[plan, "Steps", {}]},
    "SHA256"], 16], 64, "0"];

iSVWInputSchemaHash[plan_Association] :=
  StringPadLeft[IntegerString[Hash[
    Sort[{Lookup[#, "Step"], Lookup[#, "Port"]} & /@
      Lookup[plan, "Unresolved", {}]], "SHA256"], 16], 64, "0"];

(* block-level metadata の read/write (notebook TaggingRules が正、§7.4.2) *)
iSVWGetBlocks[nb_NotebookObject] :=
  With[{v = Quiet @ Check[
      CurrentValue[nb, {TaggingRules, "SourceVault", "WorkflowInputBlocks"}],
      Inherited]},
    Which[
      AssociationQ[v], v,
      MatchQ[v, {___Rule}], Association[v],
      True, <||>]];

(* merge-safe 書き込み: SourceVault 連想全体を読み出し WorkflowInputBlocks だけ
   更新して書き戻す。深いパス代入の FE マージ挙動に依存せず、CloudPublishable 等の
   兄弟キーを潰さない。 *)
iSVWSetBlock[nb_NotebookObject, blockId_String, meta_Association] :=
  Quiet @ Check[
    Module[{sv, blocks},
      sv = Replace[
        CurrentValue[nb, {TaggingRules, "SourceVault"}],
        {a_Association :> a, r : {___Rule} :> Association[r], _ -> <||>}];
      blocks = Replace[Lookup[sv, "WorkflowInputBlocks", <||>],
        {a_Association :> a, r : {___Rule} :> Association[r], _ -> <||>}];
      blocks[blockId] = meta;
      sv["WorkflowInputBlocks"] = blocks;
      CurrentValue[nb, {TaggingRules, "SourceVault"}] = sv];
    True, False];

(* 未充足 port 1 件の説明行 (header 用) *)
iSVWPortDescLine[u_Association] :=
  Module[{pd = Lookup[u, "PortDecl", <||>]},
    "  " <> ToString[u["Port"]] <> " : " <> u["Step"] <>
    " (" <> ToString[Lookup[pd, "PortType", "Value"]] <>
    With[{dk = Lookup[pd, "DomainKind"]},
      If[StringQ[dk], ", DomainKind " <> dk, ""]] <>
    With[{wt = Lookup[pd, "WLType"]},
      If[StringQ[wt], ", " <> wt, ""]] <> ")" <>
    With[{cands = Lookup[u, "Candidates", {}]},
      If[cands =!= {},
        "  candidates: " <> StringRiffle[ToString /@ cands, " | "], ""]]];

(* Submit テンプレート式 (単一セル・連想引数。WL の直観に合う形) *)
iSVWSubmitTemplate[blockId_String, plan_Association] :=
  "SourceVaultSubmitWorkflowInput[\"" <> blockId <> "\",\n <|" <>
  StringRiffle[
    Map["\"" <> ToString[Lookup[#, "Port"]] <> "\" -> \"\"" &,
      Lookup[plan, "Unresolved", {}]], ",\n   "] <> "|>]";

(* WorkflowInputBlock 挿入 (§7.4.2 改・2026-07-02 ユーザー決定):
   複数セルのフォーム記入は Mathematica の直観に反するため、
   header + 記入済みテンプレート式 1 セル (連想引数) に変更。 *)
iSVWInsertInputBlock[nb_NotebookObject, plan_Association, wfId_String] :=
  Module[{blockId, cellUUIDs = {}, headerUUID, submitUUID, meta},
    blockId = "wib-" <> StringTake[CreateUUID[], 8];
    headerUUID = CreateUUID[]; submitUUID = CreateUUID[];
    (* header: port 説明つき *)
    NBAccess`NBWriteCell[nb,
      Cell["WorkflowInputBlock " <> blockId <> " — " <>
        Lookup[plan, "Task", ""] <>
        "\n下の式の連想の \"\" を値に書き換えて評価してください。" <>
        "値・\"sv://...\" 文字列・PortBindingRef が使えます。\n" <>
        StringRiffle[iSVWPortDescLine /@ Lookup[plan, "Unresolved", {}],
          "\n"],
        "Text", ExpressionUUID -> headerUUID]];
    (* テンプレート式セル (これも式評価 = 隠れ実行入口を作らない §7.4.1) *)
    NBAccess`NBWriteCell[nb,
      Cell[iSVWSubmitTemplate[blockId, plan],
        "Input", ExpressionUUID -> submitUUID]];
    (* block-level metadata (§7.4.2) *)
    meta = <|"ObjectClass" -> "WorkflowInputBlock",
      "InputBlockId" -> blockId, "WorkflowId" -> wfId,
      "PlanHash" -> iSVWPlanHash[plan],
      "InputSchemaHash" -> iSVWInputSchemaHash[plan],
      "Status" -> "Draft",
      "CellUUIDs" -> cellUUIDs,
      "HeaderUUID" -> headerUUID, "SubmitUUID" -> submitUUID,
      "LastInputBundleURI" -> Missing[],
      "Plan" -> plan,
      "CreatedAt" -> DateString["ISODateTime"],
      "UpdatedAt" -> DateString["ISODateTime"]|>;
    iSVWSetBlock[nb, blockId, meta];
    blockId
  ];

(* ---- RunWorkflow (§7.4.1、notebook-facing wrapper。r2 責務分離) ---- *)

Options[SourceVault`SourceVaultRunWorkflow] =
  {"OnMissingInput" -> "InsertWorkflowInputBlock",
   "AllowEffects" -> True, "Notebook" -> Automatic,
   "Confidential" -> Automatic};

(* confidential 判定 (Automatic = 評価セル/notebook 指定から判定表で決定) *)
iSVWResolveConfidential[optVal_, nbOpt_] :=
  Switch[optVal,
    True, True,
    False, False,
    _, SourceVault`SourceVaultConfidentialContextQ[
      If[nbOpt === Automatic,
        Quiet @ Check[EvaluationNotebook[], $Failed], nbOpt]]];

SourceVault`SourceVaultRunWorkflow[input_, OptionsPattern[]] :=
  Module[{taskSpec, plan, wfId, nb, blocks, existing, blockId, val, confFlr},
    confFlr = If[iSVWResolveConfidential[
        OptionValue["Confidential"], OptionValue["Notebook"]],
      SourceVault`$SourceVaultConfidentialPrivacyLevel, None];
    (* 1. name / TaskSpec / plan の解決 *)
    Which[
      StringQ[input] && KeyExistsQ[$svWWorkflowRegistry, input],
        taskSpec = $svWWorkflowRegistry[input]; wfId = input;
        plan = SourceVault`SourceVaultProposeWiringPlan[taskSpec],
      StringQ[input],
        Return[Failure["UnknownWorkflow",
          <|"MessageTemplate" -> "SourceVault wiring: UnknownWorkflow",
            "Detail" -> <|"Name" -> input,
              "Registered" -> Keys[$svWWorkflowRegistry],
              "Hint" -> "registry はカーネルセッション内 (in-memory)。" <>
                "SourceVaultRegisterWiringWorkflow[name, taskSpec] で登録してから起動する"|>|>]],
      AssociationQ[input] &&
        Lookup[input, "ObjectClass"] === "SourceVaultWiringPlan",
        plan = input;
        wfId = "task:" <> StringTake[iSVWPlanHash[plan], 12],
      AssociationQ[input],
        taskSpec = input;
        wfId = "task:" <> StringTake[
          StringPadLeft[IntegerString[
            Hash[Lookup[input, "Task", ""], "SHA256"], 16], 64, "0"], 12];
        plan = SourceVault`SourceVaultProposeWiringPlan[taskSpec],
      True,
        Return[Failure["InvalidWorkflowSpec",
          <|"MessageTemplate" -> "SourceVault wiring: InvalidWorkflowSpec"|>]]];
    If[FailureQ[plan], Return[plan]];

    (* 2. 充足していれば validate -> 実行 (confidential 文脈は動的 floor で
       Execute 内の全 deposit に伝搬) *)
    If[plan["Status"] === "OK",
      val = SourceVault`SourceVaultValidateWiringPlan[plan];
      If[val["Status"] =!= "OK",
        Return[<|"Status" -> "ValidationFailed",
          "Failures" -> val["Failures"]|>]];
      Return[Block[{$svWConfidentialFloor = confFlr},
        With[{r = SourceVault`SourceVaultExecuteWiringPlan[plan,
            "AllowEffects" -> OptionValue["AllowEffects"]]},
          If[AssociationQ[r],
            Append[r, "Confidential" -> NumberQ[confFlr]], r]]]]];

    (* 3. required 未充足: InputBlock へ (FE 不在 / "Return" は spec 返却に degrade) *)
    If[OptionValue["OnMissingInput"] =!= "InsertWorkflowInputBlock" ||
       $FrontEnd === Null,
      Return[<|"Status" -> "AwaitingInput",
        "InputBlockSpec" -> plan["Unresolved"]|>]];
    nb = OptionValue["Notebook"];
    If[nb === Automatic, nb = Quiet @ Check[EvaluationNotebook[], $Failed]];
    If[!MatchQ[nb, _NotebookObject],
      Return[<|"Status" -> "AwaitingInput",
        "InputBlockSpec" -> plan["Unresolved"]|>]];

    (* 3a. 再評価 idempotency (§7.4.1 step 3, G-ui-3/4) *)
    blocks = iSVWGetBlocks[nb];
    existing = SelectFirst[Values[blocks],
      AssociationQ[#] && Lookup[#, "WorkflowId"] === wfId &&
        Lookup[#, "Status"] === "Draft" &];
    Which[
      AssociationQ[existing] &&
        existing["InputSchemaHash"] === iSVWInputSchemaHash[plan],
        (* 同一 schema の未提出 block を再利用 *)
        Return[<|"Status" -> "AwaitingInput",
          "InputBlockId" -> existing["InputBlockId"],
          "Reused" -> True|>],
      AssociationQ[existing],
        (* schema 変更: 旧 block を Superseded にして新規挿入 (G-ui-4) *)
        iSVWSetBlock[nb, existing["InputBlockId"],
          Join[existing, <|"Status" -> "Superseded",
            "UpdatedAt" -> DateString["ISODateTime"]|>]]];
    blockId = iSVWInsertInputBlock[nb, plan, wfId];
    <|"Status" -> "AwaitingInput", "InputBlockId" -> blockId,
      "Reused" -> False|>
  ];

(* ---- Collect / Validate / CreateInputBundle / Submit (§7.4.2) ---- *)

(* 入力値 -> PortBindingRef (Submit 連想引数と入力セルの共通変換) *)
iSVWValueToBinding[val_] :=
  Which[
    val === $Failed || val === "" || val === Null || MissingQ[val],
      Missing["Unfilled"],
    SourceVault`SourceVaultPortBindingRefQ[val], val,
    StringQ[val] && StringStartsQ[val, "sv://"],
      SourceVault`SourceVaultBindingFromURI[val],
    True,
      SourceVault`SourceVaultBindingFromValue[val,
        "Source" -> "NotebookCell",
        "PrivacyLevel" -> $svWDefaultPL]];

(* draft 構築: 連想引数を最優先、無い port は旧式の入力セルへ fallback *)
iSVWBuildDraft[nb_, blockId_String, plan_Association,
    inputs_Association] :=
  Module[{ports, cellDraft, cellB, bindings},
    ports = DeleteDuplicates[
      ToString[Lookup[#, "Port"]] & /@ Lookup[plan, "Unresolved", {}]];
    cellDraft = Quiet @ Check[
      SourceVault`SourceVaultCollectWorkflowInput[nb, blockId], $Failed];
    cellB = If[AssociationQ[cellDraft],
      Association[(#["Name"] -> #["Binding"]) & /@
        Lookup[cellDraft, "Bindings", {}]], <||>];
    bindings = Map[
      Function[p,
        Module[{v = Lookup[inputs, p, Missing["NotProvided"]], b},
          b = If[!MissingQ[v] && v =!= "" && v =!= Null,
            iSVWValueToBinding[v],
            Lookup[cellB, p, Missing["Unfilled"]]];
          If[MissingQ[b], b = Missing["Unfilled"]];
          <|"Name" -> p, "Binding" -> b|>]],
      ports];
    <|"ObjectClass" -> "SourceVaultWorkflowInputDraft",
      "InputBlockId" -> blockId, "Bindings" -> bindings|>
  ];

iSVWFindBlockCells[nb_NotebookObject, blockId_String] :=
  Select[Quiet @ Check[Cells[nb], {}],
    Function[c,
      Quiet @ Check[
        CurrentValue[c,
          {TaggingRules, "SourceVault", "InputBlockId"}] === blockId,
        False]]];

iSVWCellValue[cellObj_CellObject] :=
  Module[{cell = Quiet @ Check[NotebookRead[cellObj], $Failed], content},
    If[cell === $Failed, Return[$Failed]];
    content = Replace[cell,
      {Cell[s_String, ___] :> s,
       Cell[BoxData[b_], ___] :> b,
       _ :> $Failed}];
    Which[
      StringQ[content],
        Quiet @ Check[ToExpression[content, InputForm], $Failed],
      content =!= $Failed,
        Quiet @ Check[ToExpression[content, StandardForm], $Failed],
      True, $Failed]
  ];

SourceVault`SourceVaultCollectWorkflowInput[
    nb_NotebookObject, blockId_String] :=
  Module[{cells = iSVWFindBlockCells[nb, blockId], bindings = {}},
    If[cells === {},
      Return[Failure["InputBlockNotFound",
        <|"MessageTemplate" -> "SourceVault wiring: InputBlockNotFound",
          "Detail" -> blockId|>]]];
    Scan[
      Function[c,
        Module[{port, val, binding},
          port = Quiet @ Check[CurrentValue[c,
            {TaggingRules, "SourceVault", "PortName"}], $Failed];
          If[!StringQ[port], Return[Null, Module]];
          val = iSVWCellValue[c];
          binding = iSVWValueToBinding[val];
          AppendTo[bindings,
            <|"Name" -> port, "Binding" -> binding|>]]],
      cells];
    <|"ObjectClass" -> "SourceVaultWorkflowInputDraft",
      "InputBlockId" -> blockId, "Bindings" -> bindings|>
  ];

SourceVault`SourceVaultValidateWorkflowInput[
    draft_Association, plan_Association] :=
  Module[{unfilled, taskSpec, spec2, plan2, val},
    unfilled = Select[Lookup[draft, "Bindings", {}],
      MissingQ[Lookup[#, "Binding"]] &];
    If[unfilled =!= {},
      Return[<|"Status" -> "Incomplete",
        "Failures" -> Map[
          Failure["UnresolvedBinding",
            <|"MessageTemplate" ->
                "SourceVault wiring: UnresolvedBinding",
              "Detail" -> <|"Port" -> #["Name"],
                "Reason" -> "Unfilled"|>|>] &, unfilled]|>]];
    (* draft を元 TaskSpec に注入して決定的に再 propose (名前一致で束縛される) *)
    taskSpec = Lookup[plan, "TaskSpec", <|"Task" -> plan["Task"],
      "Steps" -> (Lookup[#, "Symbol"] & /@ plan["Steps"]), "Inputs" -> {}|>];
    spec2 = Join[taskSpec, <|
      "Inputs" -> Join[Lookup[taskSpec, "Inputs", {}],
        Select[Lookup[draft, "Bindings", {}],
          !MissingQ[Lookup[#, "Binding"]] &]],
      "WiringMode" -> "Deterministic"|>];
    plan2 = SourceVault`SourceVaultProposeWiringPlan[spec2];
    If[FailureQ[plan2],
      Return[<|"Status" -> "Failed", "Failures" -> {plan2}|>]];
    val = SourceVault`SourceVaultValidateWiringPlan[plan2];
    Join[val, <|"ResolvedPlan" -> plan2|>]
  ];

SourceVault`SourceVaultCreateInputBundle[
    draft_Association, plan_Association] :=
  Module[{record, ve, env},
    record = <|"ObjectClass" -> "SourceVaultInputBundle",
      "BundleKind" -> "WorkflowInput",           (* 必須 subtype (r2 P1-2) *)
      "DomainKind" -> "WorkflowInput",
      "TargetWorkflowId" -> Lookup[plan, "Task", ""],
      "PlanHash" -> iSVWPlanHash[plan],
      "InputBlockId" -> Lookup[draft, "InputBlockId", Missing[]],
      "InputPorts" -> Lookup[draft, "Bindings", {}]|>;
    ve = SourceVault`SourceVaultMakeValueEnvelope[record,
      "Source" -> "StepOutput",
      "PrivacyLevel" -> SourceVault`SourceVaultBindingPrivacyMax[
        Lookup[#, "Binding"] & /@ Lookup[draft, "Bindings", {}]]];
    env = iSVWDepositValue[ve];
    If[FailureQ[env], env,
      Join[env, <|"DomainKind" -> "WorkflowInput",
        "InputBundleRecord" -> record|>]]
  ];

Options[SourceVault`SourceVaultSubmitWorkflowInput] =
  {"Notebook" -> Automatic, "AllowEffects" -> True,
   "Confidential" -> Automatic};

(* 旧式 (入力セル記入方式) は連想なし呼びとして後方互換維持 *)
SourceVault`SourceVaultSubmitWorkflowInput[
    blockId_String, opts : OptionsPattern[]] :=
  SourceVault`SourceVaultSubmitWorkflowInput[blockId, <||>, opts];

SourceVault`SourceVaultSubmitWorkflowInput[
    blockId_String, inputs_Association, OptionsPattern[]] :=
  Module[{nb, blocks, meta, plan, draft, val, bundle, result},
    nb = OptionValue["Notebook"];
    If[nb === Automatic, nb = Quiet @ Check[EvaluationNotebook[], $Failed]];
    If[!MatchQ[nb, _NotebookObject],
      Return[Failure["NoFrontEnd",
        <|"MessageTemplate" -> "SourceVault wiring: NoFrontEnd"|>]]];
    blocks = iSVWGetBlocks[nb];
    meta = Lookup[blocks, blockId, Missing[]];
    (* TaggingRules は入れ子 rule 化されることがあるので正規化 *)
    If[MatchQ[meta, {___Rule}], meta = Association[meta]];
    If[!AssociationQ[meta],
      Return[Failure["InputBlockNotFound",
        <|"MessageTemplate" -> "SourceVault wiring: InputBlockNotFound",
          "Detail" -> blockId|>]]];
    plan = Lookup[meta, "Plan"];
    If[MatchQ[plan, {___Rule}], plan = Association[plan]];
    If[!AssociationQ[plan],
      Return[Failure["InputBlockNotFound",
        <|"MessageTemplate" -> "SourceVault wiring: InputBlockNotFound",
          "Detail" -> <|"InputBlockId" -> blockId,
            "Reason" -> "PlanMissing"|>|>]]];
    (* 連想引数優先 + 旧式セル fallback -> Validate (green まで永続化しない §7.4.2) *)
    draft = iSVWBuildDraft[nb, blockId, plan, inputs];
    If[FailureQ[draft], Return[draft]];
    val = SourceVault`SourceVaultValidateWorkflowInput[draft, plan];
    If[val["Status"] =!= "OK",
      Return[<|"Status" -> val["Status"],
        "Failures" -> Lookup[val, "Failures", {}]|>]];
    (* CreateInputBundle -> 実行 -> block 更新。
       confidential 文脈 (評価セル機密 / notebook クラウド公開不可) では
       動的 floor で bundle と全 step 出力 deposit を秘密依存データ化 *)
    Module[{confFlr},
      confFlr = If[iSVWResolveConfidential[
          OptionValue["Confidential"], nb],
        SourceVault`$SourceVaultConfidentialPrivacyLevel, None];
      Block[{$svWConfidentialFloor = confFlr},
        bundle = SourceVault`SourceVaultCreateInputBundle[draft, plan];
        If[FailureQ[bundle], Return[bundle]];
        result = SourceVault`SourceVaultExecuteWiringPlan[
          val["ResolvedPlan"],
          "AllowEffects" -> OptionValue["AllowEffects"]]];
      iSVWSetBlock[nb, blockId,
        Join[meta, <|"Status" -> "Submitted",
          "LastInputBundleURI" -> bundle["URI"],
          "UpdatedAt" -> DateString["ISODateTime"]|>]];
      If[FailureQ[result], result,
        Join[result, <|"InputBundle" -> bundle["URI"],
          "Confidential" -> NumberQ[confFlr]|>]]]
  ];

(* ---- 自身の pilot 契約 (r2 P1-3、§10 F2) ---- *)
Quiet @ Check[
  If[Names["SourceVault`SourceVaultRegisterFunctionContract"] =!= {} &&
     Length[DownValues[SourceVault`SourceVaultRegisterFunctionContract]] > 0,
    SourceVault`SourceVaultRegisterFunctionContract[<|
      "Symbol" -> "SourceVaultRunWorkflow", "Package" -> "SourceVault",
      "Kind" -> "Function",
      "RecommendedEntrypoint" -> True,
      "AbstractionLevel" -> "UserFacing",
      "CapabilityTags" -> {"workflow.run"},
      "IntentExamples" -> {"保存済みワークフローを実行"},
      "Effects" -> {"NotebookWrite", "WorkflowRun"},
      "Outputs" -> {
        <|"Name" -> "result", "PortType" -> "Value",
          "WLType" -> "Association"|>},
      "CallForms" -> {<|
        "FormId" -> "main", "ExpressionHead" -> "SourceVaultRunWorkflow",
        "Arguments" -> {
          <|"Name" -> "workflow", "Kind" -> "Positional",
            "WLType" -> "String|Association", "Required" -> True|>,
          <|"Name" -> "opts", "Kind" -> "OptionsPattern",
            "Required" -> False|>},
        "Recommended" -> True, "UseForClaudeEval" -> True|>},
      "OptionContracts" -> {
        <|"Name" -> "OnMissingInput",
          "Default" -> "InsertWorkflowInputBlock",
          "AllowedValues" -> {"InsertWorkflowInputBlock", "Return"}|>,
        <|"Name" -> "AllowEffects", "Default" -> True,
          "AllowedValues" -> {True, False}|>,
        <|"Name" -> "Notebook", "Default" -> Automatic|>,
        <|"Name" -> "Confidential", "Default" -> Automatic,
          "AllowedValues" -> {True, False, Automatic}|>},
      "UnknownOptionPolicy" -> "Reject",
      "Idempotent" -> False, "CostClass" -> "Kernel"|>];
    SourceVault`SourceVaultRegisterFunctionContract[<|
      "Symbol" -> "SourceVaultSubmitWorkflowInput",
      "Package" -> "SourceVault", "Kind" -> "Function",
      "RecommendedEntrypoint" -> False,
      "AbstractionLevel" -> "UserFacing",
      "CapabilityTags" -> {"workflow.submit"},
      "Effects" -> {"NotebookWrite", "WorkflowRun"},
      "Outputs" -> {
        <|"Name" -> "result", "PortType" -> "Value",
          "WLType" -> "Association"|>},
      "CallForms" -> {<|
        "FormId" -> "main",
        "ExpressionHead" -> "SourceVaultSubmitWorkflowInput",
        "Arguments" -> {
          <|"Name" -> "inputBlockId", "Kind" -> "Positional",
            "WLType" -> "String", "Required" -> True|>,
          <|"Name" -> "inputs", "Kind" -> "OptionalPositional",
            "WLType" -> "Association", "Required" -> False|>,
          <|"Name" -> "opts", "Kind" -> "OptionsPattern",
            "Required" -> False|>},
        "Recommended" -> True, "UseForClaudeEval" -> True|>},
      "OptionContracts" -> {
        <|"Name" -> "Notebook", "Default" -> Automatic|>,
        <|"Name" -> "AllowEffects", "Default" -> True,
          "AllowedValues" -> {True, False}|>,
        <|"Name" -> "Confidential", "Default" -> Automatic,
          "AllowedValues" -> {True, False, Automatic}|>},
      "UnknownOptionPolicy" -> "Reject",
      "Idempotent" -> False, "CostClass" -> "Kernel"|>]],
  Null];

End[] (* `WiringPrivate` *)

EndPackage[]
