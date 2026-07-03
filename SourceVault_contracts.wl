(* ::Package:: *)

(* ============================================================
   SourceVault_contracts.wl -- Function Contract / Init-DAG 基盤

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_contracts.wl"]]

   仕様書: sourcevault_function_contract_wiring_spec_v0_3.md
     §4.1 FunctionContract schema (registry が正、api.md は描画)
     §4.2 InitContract (述語は symbol 名 ref、Hold 式を registry に置かない = W10)
     §4.8 共通 Failure schema (+RepairHints)
     §5   冪等初期化プロトコル (InitMode / EnsureInitialized / reentry guard)
     §6.1 call expression validation (本 increment は最小版:
          UnknownSymbol / DeprecatedAlias / ArgumentCount / UnknownOption /
          OptionValueType(AllowedValues のみ)。ValueType DSL(Q8)/Normalize/
          Repair/Explain/Audit は次 increment)

   実装 increment: Inc α (F1 完全 + F2 中核)
     - registry:   SourceVaultRegisterFunctionContract / SourceVaultFunctionContract(s)
                   / SourceVaultValidateFunctionContract / SourceVaultUnregisterFunctionContract
     - init:       SourceVaultEnsureInitialized / SourceVaultInitPlan
     - call check: SourceVaultValidateCallExpression
     - pilot 契約: SourceVaultInitialize (Init) / SourceVaultLookup /
                   SourceVaultFindNotebooks (SourceVault.wl ロード済みのときのみ登録)

   設計原則 (spec §2):
     W1  契約は外付け宣言。既存関数の挙動を変えない。契約なし関数は素通し。
     W2  冪等は切替式。直接呼びの既定は "Force"、DAG 経由は "Ensure"。
     W10 registry に評価可能コード (Hold 式) を置かない。述語・関数は
         symbol 名文字列 (ref) で持ち、解決は本ファイルの実行層だけが行う。

   非衝突方針:
     private helper は SourceVault`ContractsPrivate` 文脈に置き、
     SourceVault`Private` (iEnsureDir 等) と隔離する (core.wl と同方式)。
   ============================================================ *)

BeginPackage["SourceVault`"]

(* ---- 共通 Failure schema (§4.8) ---- *)
SourceVaultContractFailure::usage =
  "SourceVaultContractFailure[tag, detail] は契約系の標準 Failure を作る。\n" <>
  "tag: \"UnknownOption\"|\"UnknownSymbol\"|\"ArgumentCount\"|\"OptionValueType\"|\n" <>
  "     \"DeprecatedAlias\"|\"InitCycle\"|\"InitFailed\"|\"InvalidContract\" 等。\n" <>
  "detail (Association) は \"Symbol\"/\"Detail\"/\"RepairHints\"/\"SuggestedReplacement\" を持てる。";

(* ---- FunctionContract registry (§4.1) ---- *)
SourceVaultRegisterFunctionContract::usage =
  "SourceVaultRegisterFunctionContract[contract] は FunctionContract を検証して registry に登録する。\n" <>
  "戻り値 <|\"Status\"->\"OK\", \"Symbol\"->...|> または Failure。\n" <>
  "オプション: \"CheckSymbolExists\" -> True (Symbol 実在検査。standalone テストでは False に)。";

SourceVaultUnregisterFunctionContract::usage =
  "SourceVaultUnregisterFunctionContract[symbol] は契約を registry から外す (テスト/差替用)。";

SourceVaultFunctionContract::usage =
  "SourceVaultFunctionContract[symbol] は登録済み契約 (Association) を返す。\n" <>
  "無ければ Missing[\"NoContract\", symbol]。";

SourceVaultFunctionContracts::usage =
  "SourceVaultFunctionContracts[] は登録済み契約の一覧を返す。\n" <>
  "SourceVaultFunctionContracts[pkg] は Package が pkg のものに絞る。";

SourceVaultValidateFunctionContract::usage =
  "SourceVaultValidateFunctionContract[contract, opts] は契約 schema を検証する (純関数)。\n" <>
  "戻り値 <|\"Status\"->\"OK\"|\"Failed\", \"Failures\"->{Failure...}|>。";

SourceVaultContractAliasIndex::usage =
  "SourceVaultContractAliasIndex[] は deprecated alias -> canonical symbol の索引 (Association) を返す。\n" <>
  "契約の \"Supersedes\" から登録時に構築される。";

(* ---- 冪等初期化プロトコル (§5) ---- *)
SourceVaultInitPlan::usage =
  "SourceVaultInitPlan[symbol] は symbol の実行に必要な Init 契約をトポロジカル順で返す (dry-run)。\n" <>
  "戻り値 <|\"Status\"->\"OK\", \"Order\"->{initSymbol...}, \"Missing\"->{契約未登録の Requires...}|>。\n" <>
  "循環依存は Failure[\"InitCycle\", <|\"Path\"->...|>]。";

SourceVaultEnsureInitialized::usage =
  "SourceVaultEnsureInitialized[symbol] は symbol の Requires DAG をトポロジカル順に冪等実行する。\n" <>
  "各 Init は InitializedQRef 述語が True なら副作用ゼロで skip、未初期化なら 1 回だけ実行する。\n" <>
  "何回呼んでも安全 (spec §5.3)。戻り値 <|\"Status\", \"Executed\", \"Skipped\", \"Failed\"|>。\n" <>
  "失敗した Init に依存する後続は実行せず Failed(DependencyFailed) に積む (fail-fast)。";

$SourceVaultInitInProgress::usage =
  "$SourceVaultInitInProgress は実行中 Init の in-progress marker (Association)。\n" <>
  "同一 kernel 内の再入 (Dynamic/scheduled task 等) で同じ Init が二重実行されない (spec §5.3 reentry guard)。";

(* ---- call expression validation / normalization / repair (§6.1) ---- *)
SourceVaultValidateCallExpression::usage =
  "SourceVaultValidateCallExpression[heldExpr, opts] は提案式を実行前に決定的検証する (純関数・評価しない)。\n" <>
  "heldExpr: HoldComplete[f[args...]] / Hold[...] / 式文字列。\n" <>
  "検査: head 契約有無 / deprecated alias / 引数個数 (CallForms) / option 実在 (OptionContracts) /\n" <>
  "      option 値 (AllowedValues、リテラルのみ)。\n" <>
  "戻り値 <|\"Status\"->\"OK\"|\"Failed\", \"Symbol\"->_, \"Coverage\"->\"Contract\"|\"NoContract\",\n" <>
  "        \"Failures\"->{Failure...}|>。\n" <>
  "オプション: \"UnknownSymbolPolicy\" -> \"Pass\" (契約外関数は素通し) | \"Reject\"。";

SourceVaultNormalizeCallExpression::usage =
  "SourceVaultNormalizeCallExpression[heldExpr] は alias→canonical の決定的書き換えのみ行う (§6.1)。\n" <>
  "対象: deprecated symbol alias (Supersedes) の head 置換、option alias の正準化 (トップレベルのみ)。\n" <>
  "意味を変える修復はしない。書き換えは \"Rewrites\" に記録する。\n" <>
  "戻り値 <|\"Status\", \"Expression\"->HoldComplete[...], \"Rewrites\"->{<|Action,From,To|>...}|>。";

SourceVaultRepairCallExpression::usage =
  "SourceVaultRepairCallExpression[heldExpr, opts] は Normalize + RepairHints の適用を行う (§6.1)。\n" <>
  "unknown option → 最近傍 allowed option の置換は既定 SuggestOnly (提案のみ)。\n" <>
  "\"ApplySuggestions\" -> True で自動置換 (opt-in)。\n" <>
  "戻り値 <|\"Status\", \"Expression\", \"Applied\"->{rewrites...}, \"Remaining\"->{Failure...}|>。";

SourceVaultExplainCallContract::usage =
  "SourceVaultExplainCallContract[symbol] は契約 (CallForms/Options/Requires/入出力) を\n" <>
  "人間・LLM 可読な文字列に整形する。契約が無ければ Missing[\"NoContract\", symbol]。";

SourceVaultCallContractValidatorHook::usage =
  "SourceVaultCallContractValidatorHook[heldExpr] は ClaudeRuntime の提案検証 hook 実体 (§6.1)。\n" <>
  "提案式全体を深くスキャンし、契約登録済み head (deprecated alias 含む) の呼び出しを\n" <>
  "すべて SourceVaultValidateCallExpression で検証する (Module/CompoundExpression 内も対象)。\n" <>
  "契約外関数は素通し (fail-open)。違反時は LLM 向け修復指示 RepairText を返す。\n" <>
  "戻り値 <|\"Status\"->\"OK\"|\"Failed\", \"Checked\"->n, \"RepairText\"->_, \"Failures\"->{...}|>。\n" <>
  "ClaudeRuntime`$ClaudeCallContractValidator へロード時に弱結合登録される (rule 11)。";

(* ---- 契約 audit (§8.4) ---- *)
SourceVaultAuditFunctionContracts::usage =
  "SourceVaultAuditFunctionContracts[pkg|All] は registry と実装の乖離を検査する (§8.4)。\n" <>
  "検査: Symbol 実在 / Options[sym] と OptionContracts の差分 (双方向) /\n" <>
  "      Requires の全 init が Kind->\"Init\" 契約として登録済み /\n" <>
  "      InitializedQRef・EnsureFunction の解決可能性 (rename drift 検出)。\n" <>
  "戻り値 <|\"Status\", \"Checked\", \"OKCount\", \"FailedCount\", \"PerSymbol\"-><|sym->report|>|>。";

Begin["`ContractsPrivate`"]

(* ============================================================
   0. 内部状態
   ============================================================ *)

If[!AssociationQ[$svContractRegistry],   $svContractRegistry = <||>];
If[!AssociationQ[$svContractAliasIndex], $svContractAliasIndex = <||>];
If[!AssociationQ[SourceVault`$SourceVaultInitInProgress],
  SourceVault`$SourceVaultInitInProgress = <||>];

$svContractKinds = {"Function", "Init", "Adapter", "CellInterface"};

(* ============================================================
   1. 共通 Failure schema (§4.8)
   ============================================================ *)

SourceVault`SourceVaultContractFailure[tag_String, detail_Association] :=
  Failure[tag,
    Join[
      <|"MessageTemplate" -> ("SourceVault contract: " <> tag),
        "MessageParameters" -> <||>|>,
      detail]];

(* ============================================================
   2. 契約 schema 検証 (§4.1 / §4.2)
   ============================================================ *)

iSVStringListQ[x_] := ListQ[x] && AllTrue[x, StringQ];

iSVPortListQ[x_] :=
  ListQ[x] && AllTrue[x,
    AssociationQ[#] && StringQ[Lookup[#, "Name"]] &&
      StringQ[Lookup[#, "PortType"]] &];

iSVCallFormsQ[x_] :=
  ListQ[x] && AllTrue[x,
    AssociationQ[#] && StringQ[Lookup[#, "ExpressionHead"]] &&
      ListQ[Lookup[#, "Arguments", {}]] &];

iSVOptionContractsQ[x_] :=
  ListQ[x] && AllTrue[x,
    AssociationQ[#] && StringQ[Lookup[#, "Name"]] &];

Options[SourceVault`SourceVaultValidateFunctionContract] =
  {"CheckSymbolExists" -> False};

SourceVault`SourceVaultValidateFunctionContract[
    contract_, OptionsPattern[]] :=
  Module[{fails = {}, sym, pkg, kind, ctx, addFail},
    addFail[tag_, det_] :=
      AppendTo[fails, SourceVault`SourceVaultContractFailure[tag, det]];

    If[!AssociationQ[contract],
      Return[<|"Status" -> "Failed",
        "Failures" -> {SourceVault`SourceVaultContractFailure[
          "InvalidContract", <|"Detail" -> "NotAnAssociation"|>]}|>]];

    sym  = Lookup[contract, "Symbol"];
    pkg  = Lookup[contract, "Package"];
    kind = Lookup[contract, "Kind"];

    If[!StringQ[sym],
      addFail["InvalidContract", <|"Detail" -> "SymbolMissing"|>]];
    If[!StringQ[pkg],
      addFail["InvalidContract",
        <|"Symbol" -> sym, "Detail" -> "PackageMissing"|>]];
    If[!MemberQ[$svContractKinds, kind],
      addFail["InvalidContract",
        <|"Symbol" -> sym,
          "Detail" -> <|"Kind" -> kind, "Allowed" -> $svContractKinds|>|>]];

    (* Kind->"Init" の必須フィールド (§4.2、W10: ref は文字列) *)
    If[kind === "Init",
      If[!StringQ[Lookup[contract, "InitializedQRef"]],
        addFail["InvalidContract",
          <|"Symbol" -> sym, "Detail" -> "InitializedQRefMissing"|>]];
      If[!iSVStringListQ[Lookup[contract, "Provides", {}]],
        addFail["InvalidContract",
          <|"Symbol" -> sym, "Detail" -> "ProvidesNotStringList"|>]]];

    (* 任意フィールドの型検査 *)
    Scan[
      Function[key,
        With[{v = Lookup[contract, key]},
          If[!MissingQ[v] && !iSVStringListQ[v],
            addFail["InvalidContract",
              <|"Symbol" -> sym, "Detail" -> (key <> "NotStringList")|>]]]],
      {"Requires", "Reads", "Writes", "Supersedes", "CapabilityTags"}];
    With[{v = Lookup[contract, "Inputs"]},
      If[!MissingQ[v] && !iSVPortListQ[v],
        addFail["InvalidContract",
          <|"Symbol" -> sym, "Detail" -> "InputsNotPortList"|>]]];
    With[{v = Lookup[contract, "Outputs"]},
      If[!MissingQ[v] && !iSVPortListQ[v],
        addFail["InvalidContract",
          <|"Symbol" -> sym, "Detail" -> "OutputsNotPortList"|>]]];
    With[{v = Lookup[contract, "CallForms"]},
      If[!MissingQ[v] && !iSVCallFormsQ[v],
        addFail["InvalidContract",
          <|"Symbol" -> sym, "Detail" -> "CallFormsInvalid"|>]]];
    With[{v = Lookup[contract, "OptionContracts"]},
      If[!MissingQ[v] && !iSVOptionContractsQ[v],
        addFail["InvalidContract",
          <|"Symbol" -> sym, "Detail" -> "OptionContractsInvalid"|>]]];

    (* Symbol 実在検査 (opt-in。audit で本格化) *)
    If[TrueQ[OptionValue["CheckSymbolExists"]] && StringQ[sym] && StringQ[pkg],
      ctx = Lookup[contract, "Context", pkg <> "`"];
      If[Names[ctx <> sym] === {},
        addFail["UnknownSymbol",
          <|"Symbol" -> sym, "Detail" -> <|"Context" -> ctx|>|>]]];

    If[fails === {},
      <|"Status" -> "OK", "Failures" -> {}|>,
      <|"Status" -> "Failed", "Failures" -> fails|>]
  ];

(* ============================================================
   3. registry (§4.1)
   ============================================================ *)

Options[SourceVault`SourceVaultRegisterFunctionContract] =
  {"CheckSymbolExists" -> False};

SourceVault`SourceVaultRegisterFunctionContract[
    contract_, opts : OptionsPattern[]] :=
  Module[{vr, sym},
    vr = SourceVault`SourceVaultValidateFunctionContract[contract,
      "CheckSymbolExists" -> OptionValue["CheckSymbolExists"]];
    If[vr["Status"] =!= "OK",
      Return[SourceVault`SourceVaultContractFailure["InvalidContract",
        <|"Symbol" -> Lookup[contract, "Symbol", Missing["Unknown"]],
          "Detail" -> vr["Failures"]|>]]];
    sym = contract["Symbol"];
    $svContractRegistry[sym] = contract;
    (* Supersedes -> alias 索引 (deprecated alias -> canonical) *)
    Scan[
      Function[alias, $svContractAliasIndex[alias] = sym],
      Lookup[contract, "Supersedes", {}]];
    <|"Status" -> "OK", "Symbol" -> sym|>
  ];

SourceVault`SourceVaultUnregisterFunctionContract[sym_String] :=
  Module[{},
    KeyDropFrom[$svContractRegistry, sym];
    $svContractAliasIndex =
      Select[$svContractAliasIndex, # =!= sym &];
    <|"Status" -> "OK", "Symbol" -> sym|>
  ];

SourceVault`SourceVaultFunctionContract[sym_String] :=
  Lookup[$svContractRegistry, sym, Missing["NoContract", sym]];

SourceVault`SourceVaultFunctionContracts[] := Values[$svContractRegistry];

SourceVault`SourceVaultFunctionContracts[pkg_String] :=
  Select[Values[$svContractRegistry], Lookup[#, "Package"] === pkg &];

SourceVault`SourceVaultContractAliasIndex[] := $svContractAliasIndex;

(* ============================================================
   4. symbol 名 ref の解決 (W10: 解決は実行層のみ)
   ============================================================ *)

(* 名前 (文脈付き/なし) から評価可能な Symbol を返す。無ければ $Failed。
   Names で実在確認してから Symbol[] するので、裸の Symbol 生成をしない。 *)
iSVResolveSymbolRef[name_String] :=
  Which[
    StringContainsQ[name, "`"] && Names[name] =!= {}, Symbol[name],
    Names["SourceVault`" <> name] =!= {}, Symbol["SourceVault`" <> name],
    Names[name] =!= {}, Symbol[name],
    True, $Failed];

(* 述語 ref を安全に評価。True / False / Indeterminate(解決不能) *)
iSVEvalInitializedQ[ref_String] :=
  Module[{f = iSVResolveSymbolRef[ref], r},
    If[f === $Failed, Return[Indeterminate]];
    r = Quiet @ Check[f[], Indeterminate];
    If[BooleanQ[r], r, Indeterminate]
  ];

(* ============================================================
   5. Init DAG (§5.3)
   ============================================================ *)

(* symbol の Requires 閉包を DFS で辿り、post-order (=トポロジカル順) を返す。
   循環は Throw。契約未登録の Requires は missing に積む (実行不能だが致命ではない)。 *)
iSVInitClosure[startSym_String] :=
  Module[{order = {}, visited = <||>, missing = {}, visit},
    visit[sym_String, path_List] :=
      Module[{c, reqs},
        Which[
          MemberQ[path, sym],
            Throw[Append[path, sym], "SVInitCycle"],
          KeyExistsQ[visited, sym], Null,
          True,
            c = Lookup[$svContractRegistry, sym];
            If[MissingQ[c],
              If[!MemberQ[missing, sym], AppendTo[missing, sym]];
              visited[sym] = True,
              (* else: 依存を先に *)
              reqs = Lookup[c, "Requires", {}];
              Scan[visit[#, Append[path, sym]] &, reqs];
              visited[sym] = True;
              If[Lookup[c, "Kind"] === "Init", AppendTo[order, sym]]]]];
    visit[startSym, {}];
    <|"Order" -> order, "Missing" -> missing|>
  ];

SourceVault`SourceVaultInitPlan[sym_String] :=
  Module[{res},
    res = Catch[iSVInitClosure[sym], "SVInitCycle"];
    If[ListQ[res],
      Return[SourceVault`SourceVaultContractFailure["InitCycle",
        <|"Symbol" -> sym, "Detail" -> <|"Path" -> res|>|>]]];
    <|"Status" -> "OK", "Order" -> res["Order"], "Missing" -> res["Missing"]|>
  ];

SourceVault`SourceVaultInitPlan[syms_List] :=
  Module[{plans, fails, order = {}, missing = {}},
    plans = SourceVault`SourceVaultInitPlan /@ syms;
    fails = Select[plans, FailureQ];
    If[fails =!= {}, Return[First[fails]]];
    Scan[
      Function[p,
        Scan[If[!MemberQ[order, #], AppendTo[order, #]] &, p["Order"]];
        Scan[If[!MemberQ[missing, #], AppendTo[missing, #]] &, p["Missing"]]],
      plans];
    <|"Status" -> "OK", "Order" -> order, "Missing" -> missing|>
  ];

(* ============================================================
   6. SourceVaultEnsureInitialized (§5.3)
   ============================================================ *)

(* 単一 Init の Ensure 実行。戻り値: "Executed"|"AlreadyInitialized"|"InProgress"|Failure *)
iSVEnsureOne[initSym_String] :=
  Module[{c, qref, state, fname, f, optNames, res},
    c = Lookup[$svContractRegistry, initSym];
    If[MissingQ[c],
      Return[SourceVault`SourceVaultContractFailure["InitFailed",
        <|"Symbol" -> initSym, "Detail" -> "NoContract"|>]]];

    (* 1. 述語で初期化済み判定 (副作用ゼロで skip) *)
    qref  = Lookup[c, "InitializedQRef"];
    state = If[StringQ[qref], iSVEvalInitializedQ[qref], Indeterminate];
    If[state === True, Return["AlreadyInitialized"]];

    (* 2. reentry guard: 実行中なら skip (二重実行防止, G-init-1) *)
    If[TrueQ[SourceVault`$SourceVaultInitInProgress[initSym]],
      Return["InProgress"]];

    (* 3. 本来の初期化を 1 回だけ実行。"InitMode" を持つ関数には "Ensure" を渡す *)
    fname = Lookup[c, "EnsureFunction", initSym];
    f = iSVResolveSymbolRef[fname];
    If[f === $Failed,
      Return[SourceVault`SourceVaultContractFailure["InitFailed",
        <|"Symbol" -> initSym,
          "Detail" -> <|"Reason" -> "EnsureFunctionUnresolved",
                        "EnsureFunction" -> fname|>|>]]];
    optNames = Quiet @ Check[Keys[Association @@ {Options[f]}], {}];

    SourceVault`$SourceVaultInitInProgress[initSym] = True;
    res = Quiet @ Check[
      If[MemberQ[optNames, "InitMode"],
        f["InitMode" -> "Ensure"],
        f[]],
      $Failed];
    KeyDropFrom[SourceVault`$SourceVaultInitInProgress, initSym];

    Which[
      res === $Failed || FailureQ[res] ||
        (AssociationQ[res] && Lookup[res, "Status"] === "Failed"),
        SourceVault`SourceVaultContractFailure["InitFailed",
          <|"Symbol" -> initSym, "Detail" -> <|"Result" -> res|>|>],
      True, "Executed"]
  ];

SourceVault`SourceVaultEnsureInitialized[sym_String, OptionsPattern[]] :=
  Module[{plan, executed = {}, skipped = {}, failed = {}, failedSet = {},
          depFailedQ},
    plan = SourceVault`SourceVaultInitPlan[sym];
    If[FailureQ[plan], Return[plan]];

    (* 契約未登録の Requires は skip として報告 (audit 対象) *)
    Scan[
      AppendTo[skipped, <|"Symbol" -> #, "Reason" -> "NoInitContract"|>] &,
      plan["Missing"]];

    (* init の (transitive) Requires に失敗が含まれるか *)
    depFailedQ[initSym_] :=
      Module[{c = Lookup[$svContractRegistry, initSym], reqs},
        reqs = If[MissingQ[c], {}, Lookup[c, "Requires", {}]];
        AnyTrue[reqs,
          Function[r, MemberQ[failedSet, r] || depFailedQ[r]]]];

    Scan[
      Function[initSym,
        Module[{r},
          If[depFailedQ[initSym],
            AppendTo[failed,
              <|"Symbol" -> initSym, "Reason" -> "DependencyFailed"|>];
            AppendTo[failedSet, initSym],
            (* else *)
            r = iSVEnsureOne[initSym];
            Which[
              r === "Executed",
                AppendTo[executed, initSym],
              r === "AlreadyInitialized" || r === "InProgress",
                AppendTo[skipped, <|"Symbol" -> initSym, "Reason" -> r|>],
              FailureQ[r],
                AppendTo[failed,
                  <|"Symbol" -> initSym, "Reason" -> "InitFailed",
                    "Failure" -> r|>];
                AppendTo[failedSet, initSym]]]]],
      plan["Order"]];

    <|"Status" -> If[failed === {}, "OK", "Failed"],
      "Executed" -> executed, "Skipped" -> skipped, "Failed" -> failed|>
  ];

(* ============================================================
   7. call expression validation (§6.1 最小版)
   ============================================================ *)

(* held 式から head 名 (文脈なし) を取り出す。評価しない。 *)
iSVHeldHeadName[hc_HoldComplete] :=
  Replace[hc,
    {HoldComplete[(h_Symbol)[___]] :>
       Last[StringSplit[ToString[HoldForm[h]], "`"]],
     _ :> $Failed}];

(* held 式から引数列を HoldComplete 個包装のリストで取り出す *)
iSVHeldArgs[hc_HoldComplete] :=
  Replace[hc,
    {HoldComplete[_[args___]] :>
       (List @@ (HoldComplete /@ Unevaluated[{args}])),
     _ :> {}}];

(* held 引数が option (Rule/RuleDelayed) なら option 名を返す。違えば $Failed *)
iSVHeldOptionName[argHC_HoldComplete] :=
  Replace[argHC,
    {HoldComplete[(Rule | RuleDelayed)[k_String, _]] :> k,
     HoldComplete[(Rule | RuleDelayed)[k_Symbol, _]] :>
       Last[StringSplit[ToString[HoldForm[k]], "`"]],
     _ :> $Failed}];

(* held option 値がリテラルなら安全に取り出す。違えば Missing["NonLiteral"] *)
iSVHeldOptionLiteral[argHC_HoldComplete] :=
  Replace[argHC,
    {HoldComplete[(Rule | RuleDelayed)[_,
        v : (_String | _Integer | _Real | True | False |
             None | Automatic | _Missing)]] :> v,
     _ :> Missing["NonLiteral"]}];

(* 入力正規化: HoldComplete / Hold / 文字列 -> HoldComplete *)
iSVToHeldCall[input_HoldComplete] := input;
iSVToHeldCall[Hold[e___]] := HoldComplete[e];
iSVToHeldCall[s_String] :=
  If[SyntaxQ[s],
    Quiet @ Check[ToExpression[s, InputForm, HoldComplete], $Failed],
    $Failed];
iSVToHeldCall[___] := $Failed;

(* option 名候補との最近傍提案 *)
iSVNearestOption[bad_String, allowed_List] :=
  If[allowed === {}, Missing["NoCandidate"],
    First[Nearest[allowed, bad, DistanceFunction -> EditDistance]]];

Options[SourceVault`SourceVaultValidateCallExpression] =
  {"UnknownSymbolPolicy" -> "Pass",
   "RequireClaudeEvalForm" -> False};

SourceVault`SourceVaultValidateCallExpression[
    input_, OptionsPattern[]] :=
  Module[{hc, headName, contract, fails = {}, argHCs, optArgs, posArgs,
          forms, arityOK, optionContracts, allowedNames, aliasMap,
          canonical, addFail},
    addFail[tag_, det_] :=
      AppendTo[fails, SourceVault`SourceVaultContractFailure[tag, det]];

    hc = iSVToHeldCall[input];
    If[hc === $Failed,
      Return[<|"Status" -> "Failed", "Symbol" -> Missing["Unparsable"],
        "Coverage" -> "NoContract",
        "Failures" -> {SourceVault`SourceVaultContractFailure[
          "InvalidExpression", <|"Detail" -> "CannotParse"|>]}|>]];

    headName = iSVHeldHeadName[hc];
    If[headName === $Failed,
      Return[<|"Status" -> "Failed", "Symbol" -> Missing["NoSymbolHead"],
        "Coverage" -> "NoContract",
        "Failures" -> {SourceVault`SourceVaultContractFailure[
          "InvalidExpression", <|"Detail" -> "HeadNotSymbol"|>]}|>]];

    (* deprecated symbol alias (G-call-2 検出側) *)
    canonical = Lookup[$svContractAliasIndex, headName];
    If[StringQ[canonical],
      addFail["DeprecatedAlias",
        <|"Symbol" -> headName,
          "SuggestedReplacement" -> canonical,
          "RepairHints" -> {
            <|"Action" -> "ReplaceHead", "From" -> headName,
              "To" -> canonical, "Confidence" -> "High"|>}|>];
      Return[<|"Status" -> "Failed", "Symbol" -> headName,
        "Coverage" -> "Contract", "Failures" -> fails|>]];

    contract = Lookup[$svContractRegistry, headName];
    If[MissingQ[contract],
      If[OptionValue["UnknownSymbolPolicy"] === "Reject",
        Return[<|"Status" -> "Failed", "Symbol" -> headName,
          "Coverage" -> "NoContract",
          "Failures" -> {SourceVault`SourceVaultContractFailure[
            "UnknownSymbol", <|"Symbol" -> headName|>]}|>],
        (* Pass: 契約外関数は素通し (W1) *)
        Return[<|"Status" -> "OK", "Symbol" -> headName,
          "Coverage" -> "NoContract", "Failures" -> {}|>]]];

    argHCs  = iSVHeldArgs[hc];
    optArgs = Select[argHCs, iSVHeldOptionName[#] =!= $Failed &];
    posArgs = Select[argHCs, iSVHeldOptionName[#] === $Failed &];

    (* --- 引数個数 (CallForms) --- *)
    forms = Lookup[contract, "CallForms", {}];
    If[TrueQ[OptionValue["RequireClaudeEvalForm"]],
      forms = Select[forms, TrueQ[Lookup[#, "UseForClaudeEval", True]] &]];
    If[forms =!= {},
      arityOK = AnyTrue[forms,
        Function[form,
          Module[{args = Lookup[form, "Arguments", {}], reqN, maxN},
            reqN = Count[args,
              a_ /; Lookup[a, "Kind"] === "Positional" &&
                    !TrueQ[!Lookup[a, "Required", True]]];
            maxN = Count[args,
              a_ /; MemberQ[{"Positional", "OptionalPositional"},
                            Lookup[a, "Kind"]]];
            reqN <= Length[posArgs] <= maxN]]];
      If[!arityOK,
        addFail["ArgumentCount",
          <|"Symbol" -> headName,
            "Detail" -> <|
              "Got" -> Length[posArgs],
              "Expected" -> Map[
                Function[form,
                  Module[{args = Lookup[form, "Arguments", {}]},
                    <|"Required" -> Count[args,
                        a_ /; Lookup[a, "Kind"] === "Positional" &&
                              !TrueQ[!Lookup[a, "Required", True]]],
                      "Max" -> Count[args,
                        a_ /; MemberQ[{"Positional", "OptionalPositional"},
                                      Lookup[a, "Kind"]]]|>]],
                forms]|>|>]]];

    (* --- option 検査 (OptionContracts) --- *)
    optionContracts = Lookup[contract, "OptionContracts", {}];
    If[optionContracts =!= {},
      allowedNames = Lookup[#, "Name"] & /@ optionContracts;
      aliasMap = Association @@ Flatten @ Map[
        Function[oc,
          Map[# -> oc["Name"] &,
            Join[Lookup[oc, "Aliases", {}],
                 Lookup[oc, "DeprecatedAliases", {}]]]],
        optionContracts];
      Scan[
        Function[argHC,
          Module[{oname = iSVHeldOptionName[argHC], oc, allowedVals, lit},
            Which[
              MemberQ[allowedNames, oname],
                (* 値検査: AllowedValues が明示リストでリテラル値のときのみ *)
                oc = SelectFirst[optionContracts,
                  Lookup[#, "Name"] === oname &];
                allowedVals = Lookup[oc, "AllowedValues", Automatic];
                lit = iSVHeldOptionLiteral[argHC];
                If[ListQ[allowedVals] && !MatchQ[lit, Missing["NonLiteral"]] &&
                   !MemberQ[allowedVals, lit],
                  addFail["OptionValueType",
                    <|"Symbol" -> headName,
                      "Detail" -> <|"Option" -> oname, "Value" -> lit,
                                    "AllowedValues" -> allowedVals|>|>]],
              KeyExistsQ[aliasMap, oname],
                addFail["DeprecatedAlias",
                  <|"Symbol" -> headName,
                    "Detail" -> <|"Option" -> oname|>,
                    "SuggestedReplacement" -> aliasMap[oname],
                    "RepairHints" -> {
                      <|"Action" -> "ReplaceOption", "From" -> oname,
                        "To" -> aliasMap[oname],
                        "Confidence" -> "High"|>}|>],
              True,
                (* unknown option (G-call-1): UnknownOptionPolicy 既定 Reject *)
                If[Lookup[contract, "UnknownOptionPolicy", "Reject"] === "Reject",
                  addFail["UnknownOption",
                    <|"Symbol" -> headName,
                      "Detail" -> <|"Option" -> oname,
                                    "AllowedOptions" -> allowedNames|>,
                      "SuggestedReplacement" ->
                        iSVNearestOption[oname, allowedNames],
                      "RepairHints" -> {
                        <|"Action" -> "ReplaceOption", "From" -> oname,
                          "To" -> iSVNearestOption[oname, allowedNames],
                          "Confidence" -> "Medium"|>}|>]]]]],
        optArgs]];

    <|"Status" -> If[fails === {}, "OK", "Failed"],
      "Symbol" -> headName, "Coverage" -> "Contract",
      "Failures" -> fails|>
  ];

(* ============================================================
   7.5 normalize / repair / explain (§6.1・Inc β)
   ============================================================ *)

(* head を canonical symbol に差し替える (held のまま)。解決不能なら $Failed *)
iSVRewriteHead[hc_HoldComplete, newName_String] :=
  Module[{c = Lookup[$svContractRegistry, newName], ctx, new},
    ctx = If[AssociationQ[c],
      Lookup[c, "Context", Lookup[c, "Package", "SourceVault"] <> "`"],
      "SourceVault`"];
    new = Which[
      Names[ctx <> newName] =!= {}, Symbol[ctx <> newName],
      Names[newName] =!= {}, Symbol[newName],
      Names["Global`" <> newName] =!= {}, Symbol["Global`" <> newName],
      True, $Failed];
    If[new === $Failed, $Failed,
      With[{ns = new},
        Replace[hc, HoldComplete[_[args___]] :> HoldComplete[ns[args]]]]]
  ];

(* トップレベル option 名 from -> to の書き換え (held のまま、値は評価しない)。
   ネストした引数値内の Rule は触らない (トップレベル限定)。 *)
iSVRewriteTopLevelOption[hc_HoldComplete, from_String, to_String] :=
  FixedPoint[
    Replace[#, {
      HoldComplete[hd_[pre___, Rule[k_String, v_], post___]] /; k === from :>
        HoldComplete[hd[pre, Rule[to, v], post]],
      HoldComplete[hd_[pre___, RuleDelayed[k_String, v_], post___]] /; k === from :>
        HoldComplete[hd[pre, RuleDelayed[to, v], post]],
      HoldComplete[hd_[pre___, Rule[k_Symbol, v_], post___]] /;
          Last[StringSplit[ToString[HoldForm[k]], "`"]] === from :>
        HoldComplete[hd[pre, Rule[to, v], post]],
      HoldComplete[hd_[pre___, RuleDelayed[k_Symbol, v_], post___]] /;
          Last[StringSplit[ToString[HoldForm[k]], "`"]] === from :>
        HoldComplete[hd[pre, RuleDelayed[to, v], post]]}] &,
    hc];

SourceVault`SourceVaultNormalizeCallExpression[input_] :=
  Module[{hc, headName, rewrites = {}, canonical, contract, aliasMap, hc2},
    hc = iSVToHeldCall[input];
    If[hc === $Failed,
      Return[<|"Status" -> "Failed", "Expression" -> input,
        "Rewrites" -> {},
        "Failures" -> {SourceVault`SourceVaultContractFailure[
          "InvalidExpression", <|"Detail" -> "CannotParse"|>]}|>]];
    headName = iSVHeldHeadName[hc];
    If[headName === $Failed,
      Return[<|"Status" -> "OK", "Expression" -> hc, "Rewrites" -> {}|>]];

    (* 1. deprecated symbol alias -> canonical head (G-call-2) *)
    canonical = Lookup[$svContractAliasIndex, headName];
    If[StringQ[canonical],
      hc2 = iSVRewriteHead[hc, canonical];
      If[hc2 =!= $Failed,
        AppendTo[rewrites,
          <|"Action" -> "ReplaceHead",
            "From" -> headName, "To" -> canonical|>];
        hc = hc2;
        headName = canonical]];

    (* 2. option alias -> canonical option 名 (G-call-3) *)
    contract = Lookup[$svContractRegistry, headName];
    If[AssociationQ[contract],
      aliasMap = Association @@ Flatten @ Map[
        Function[oc,
          Map[# -> oc["Name"] &,
            Join[Lookup[oc, "Aliases", {}],
                 Lookup[oc, "DeprecatedAliases", {}]]]],
        Lookup[contract, "OptionContracts", {}]];
      KeyValueMap[
        Function[{from, to},
          Module[{hc3 = iSVRewriteTopLevelOption[hc, from, to]},
            If[hc3 =!= hc,
              hc = hc3;
              AppendTo[rewrites,
                <|"Action" -> "ReplaceOption",
                  "From" -> from, "To" -> to|>]]]],
        aliasMap]];

    <|"Status" -> "OK", "Expression" -> hc, "Rewrites" -> rewrites|>
  ];

Options[SourceVault`SourceVaultRepairCallExpression] =
  {"ApplySuggestions" -> False, "UnknownSymbolPolicy" -> "Pass"};

SourceVault`SourceVaultRepairCallExpression[input_, OptionsPattern[]] :=
  Module[{norm, hc, applied, val, sugg},
    norm = SourceVault`SourceVaultNormalizeCallExpression[input];
    If[norm["Status"] =!= "OK",
      Return[<|"Status" -> "Failed", "Expression" -> input,
        "Applied" -> {}, "Remaining" -> Lookup[norm, "Failures", {}]|>]];
    hc = norm["Expression"];
    applied = norm["Rewrites"];
    val = SourceVault`SourceVaultValidateCallExpression[hc,
      "UnknownSymbolPolicy" -> OptionValue["UnknownSymbolPolicy"]];

    (* opt-in: unknown option の最近傍提案を適用して再検証 *)
    If[TrueQ[OptionValue["ApplySuggestions"]] && val["Status"] === "Failed",
      Scan[
        Function[f,
          If[f[[1]] === "UnknownOption" &&
             StringQ[sugg = f["SuggestedReplacement"]],
            hc = iSVRewriteTopLevelOption[hc,
              f["Detail"]["Option"], sugg];
            AppendTo[applied,
              <|"Action" -> "ReplaceOption",
                "From" -> f["Detail"]["Option"], "To" -> sugg,
                "Source" -> "Suggestion"|>]]],
        val["Failures"]];
      val = SourceVault`SourceVaultValidateCallExpression[hc,
        "UnknownSymbolPolicy" -> OptionValue["UnknownSymbolPolicy"]]];

    <|"Status" -> val["Status"], "Expression" -> hc,
      "Applied" -> applied, "Remaining" -> val["Failures"]|>
  ];

SourceVault`SourceVaultExplainCallContract[sym_String] :=
  Module[{c = Lookup[$svContractRegistry, sym], lines = {}, form, argStr},
    If[MissingQ[c], Return[Missing["NoContract", sym]]];
    AppendTo[lines, "Symbol: " <> sym <>
      " (" <> Lookup[c, "Package", "?"] <> ", " <> Lookup[c, "Kind", "?"] <>
      If[StringQ[Lookup[c, "AbstractionLevel"]],
        ", " <> c["AbstractionLevel"], ""] <> ")"];
    form = SelectFirst[Lookup[c, "CallForms", {}],
      TrueQ[Lookup[#, "Recommended", True]] &];
    If[AssociationQ[form],
      argStr = StringRiffle[
        Map[
          Function[a,
            Which[
              Lookup[a, "Kind"] === "OptionsPattern", "opts",
              True, Lookup[a, "Name", "arg"] <>
                If[StringQ[Lookup[a, "WLType"]], ":" <> a["WLType"], ""] <>
                If[TrueQ[!Lookup[a, "Required", True]], " (optional)", ""]]],
          Lookup[form, "Arguments", {}]], ", "];
      AppendTo[lines, "Signature: " <> form["ExpressionHead"] <>
        "[" <> argStr <> "]"]];
    With[{ocs = Lookup[c, "OptionContracts", {}]},
      If[ocs =!= {},
        AppendTo[lines, "Options (these are the ONLY valid options):"];
        Scan[
          Function[oc,
            AppendTo[lines, "  " <> oc["Name"] <>
              If[!MissingQ[Lookup[oc, "Default"]],
                " (default: " <> ToString[oc["Default"], InputForm] <> ")", ""] <>
              With[{av = Lookup[oc, "AllowedValues", Automatic]},
                If[ListQ[av],
                  " allowed: " <> ToString[av, InputForm], ""]] <>
              With[{al = Lookup[oc, "Aliases", {}]},
                If[al =!= {},
                  " (alias: " <> StringRiffle[al, ", "] <> ")", ""]]]],
          ocs]]];
    With[{req = Lookup[c, "Requires", {}]},
      If[req =!= {},
        AppendTo[lines,
          "Requires (run SourceVaultEnsureInitialized[\"" <> sym <>
          "\"] first): " <> StringRiffle[req, ", "]]]];
    With[{sup = Lookup[c, "Supersedes", {}]},
      If[sup =!= {},
        AppendTo[lines, "Supersedes (do NOT use): " <>
          StringRiffle[sup, ", "]]]];
    With[{dnu = Lookup[c, "DoNotUseWhen", {}]},
      If[dnu =!= {},
        AppendTo[lines, "Do not use when: " <> StringRiffle[dnu, "; "]]]];
    StringRiffle[lines, "\n"]
  ];

(* ============================================================
   7.55 ClaudeRuntime 向け validator hook (§6.1・Inc γ)
   ============================================================ *)

(* held 式の中から契約登録済み head (deprecated alias 含む) の呼び出しを
   すべて拾う (深いスキャン)。Module/CompoundExpression に包まれた提案でも
   内側の契約付き呼び出しを検証できる。評価はしない。 *)
iSVContractedCallsIn[hc_HoldComplete] :=
  Module[{keys},
    keys = Join[Keys[$svContractRegistry], Keys[$svContractAliasIndex]];
    If[keys === {}, Return[{}]];
    DeleteDuplicates @ Cases[hc,
      (s_Symbol)[args___] /;
        MemberQ[keys, Last[StringSplit[ToString[HoldForm[s]], "`"]]] :>
        HoldComplete[s[args]],
      {0, Infinity}]
  ];

(* 1 failure -> LLM 向け修復指示 1 行 *)
iSVRepairLine[f_Failure] :=
  Module[{tag = f[[1]], sym, det},
    sym = Quiet @ Check[f["Symbol"], "?"];
    det = Quiet @ Check[f["Detail"], <||>];
    If[!AssociationQ[det], det = <||>];
    Switch[tag,
      "UnknownOption",
        "- " <> sym <> ": option \"" <> Lookup[det, "Option", "?"] <>
        "\" does not exist." <>
        With[{s = Quiet @ Check[f["SuggestedReplacement"], Missing[]]},
          If[StringQ[s], " Did you mean \"" <> s <> "\"?", ""]] <>
        " Allowed options: " <>
        StringRiffle[Lookup[det, "AllowedOptions", {}], ", "],
      "DeprecatedAlias",
        If[KeyExistsQ[det, "Option"],
          "- " <> sym <> ": option \"" <> det["Option"] <>
          "\" is a deprecated alias. Use \"" <>
          Quiet @ Check[f["SuggestedReplacement"], "?"] <> "\" instead.",
          "- \"" <> sym <> "\" is deprecated. Use " <>
          Quiet @ Check[f["SuggestedReplacement"], "?"] <> "[...] instead."],
      "ArgumentCount",
        "- " <> sym <> ": wrong number of positional arguments (got " <>
        ToString[Lookup[det, "Got", "?"]] <> "; expected " <>
        ToString[Lookup[det, "Expected", "?"], InputForm] <> ").",
      "OptionValueType",
        "- " <> sym <> ": option \"" <> Lookup[det, "Option", "?"] <>
        "\" value " <> ToString[Lookup[det, "Value", "?"], InputForm] <>
        " is not allowed. Allowed values: " <>
        ToString[Lookup[det, "AllowedValues", {}], InputForm],
      _,
        "- " <> sym <> ": " <> tag]
  ];

SourceVault`SourceVaultCallContractValidatorHook[heldExpr_] :=
  Module[{hc, calls, results, failedResults, allFails, lines},
    hc = iSVToHeldCall[heldExpr];
    If[hc === $Failed,
      Return[<|"Status" -> "OK", "Checked" -> 0|>]];    (* fail-open *)
    calls = Quiet @ Check[iSVContractedCallsIn[hc], {}];
    If[calls === {},
      Return[<|"Status" -> "OK", "Checked" -> 0|>]];
    results = Map[
      SourceVault`SourceVaultValidateCallExpression[#,
        "UnknownSymbolPolicy" -> "Pass"] &, calls];
    failedResults = Select[results, #["Status"] === "Failed" &];
    If[failedResults === {},
      Return[<|"Status" -> "OK", "Checked" -> Length[calls]|>]];
    allFails = Flatten[#["Failures"] & /@ failedResults];
    lines = iSVRepairLine /@ allFails;
    <|"Status" -> "Failed",
      "Checked" -> Length[calls],
      "FailureTags" -> DeleteDuplicates[First /@ allFails],
      "Failures" -> allFails,
      "RepairText" -> StringRiffle[
        Join[
          {"Call contract violation. Fix the expression as follows and propose it again:"},
          lines,
          {"Use ONLY documented options and canonical function names; do not invent option names."}],
        "\n"]|>
  ];

(* ============================================================
   7.6 契約 audit (§8.4・Inc β)
   ============================================================ *)

iSVOptionNameString[name_String] := name;
iSVOptionNameString[name_Symbol] :=
  Last[StringSplit[ToString[HoldForm[name]], "`"]];
iSVOptionNameString[_] := $Failed;

iSVAuditOne[contract_Association] :=
  Module[{sym, ctx, fails = {}, realOpts, realNames, contractNames,
          implOnly, contractOnly, addFail},
    addFail[tag_, det_] :=
      AppendTo[fails, SourceVault`SourceVaultContractFailure[tag, det]];
    sym = contract["Symbol"];
    ctx = Lookup[contract, "Context",
      Lookup[contract, "Package", "SourceVault"] <> "`"];

    (* 1. Symbol 実在 *)
    If[Names[ctx <> sym] === {},
      addFail["UnknownSymbol",
        <|"Symbol" -> sym, "Detail" -> <|"Context" -> ctx|>|>],
      (* 2. Options[sym] と OptionContracts の双方向差分 *)
      With[{ocs = Lookup[contract, "OptionContracts"]},
        If[!MissingQ[ocs],
          realOpts = Quiet @ Check[Options[Symbol[ctx <> sym]], {}];
          realNames = DeleteCases[
            iSVOptionNameString[First[#]] & /@ realOpts, $Failed];
          contractNames = Lookup[#, "Name"] & /@ ocs;
          implOnly = Complement[realNames, contractNames];
          contractOnly = Complement[contractNames, realNames];
          If[contractOnly =!= {},
            addFail["OptionsMismatch",
              <|"Symbol" -> sym,
                "Detail" -> <|"ContractOnly" -> contractOnly,
                  "Reason" -> "ContractClaimsNonexistentOptions"|>|>]];
          If[implOnly =!= {},
            addFail["OptionsMismatch",
              <|"Symbol" -> sym,
                "Detail" -> <|"ImplementationOnly" -> implOnly,
                  "Reason" -> "ContractMissingOptions"|>|>]]]]];

    (* 3. Requires の全 init が Kind->"Init" 契約として登録済み *)
    Scan[
      Function[req,
        With[{rc = Lookup[$svContractRegistry, req]},
          If[MissingQ[rc] || Lookup[rc, "Kind"] =!= "Init",
            addFail["RequiresUnregistered",
              <|"Symbol" -> sym,
                "Detail" -> <|"Requires" -> req,
                  "Registered" -> !MissingQ[rc]|>|>]]]],
      Lookup[contract, "Requires", {}]];

    (* 4. Init 契約の ref 解決可能性 (rename drift 検出) *)
    If[Lookup[contract, "Kind"] === "Init",
      Scan[
        Function[key,
          With[{ref = Lookup[contract, key]},
            If[StringQ[ref] && iSVResolveSymbolRef[ref] === $Failed,
              addFail["UnresolvedRef",
                <|"Symbol" -> sym,
                  "Detail" -> <|"Field" -> key, "Ref" -> ref|>|>]]]],
        {"InitializedQRef", "EnsureFunction", "ForceFunction"}]];

    <|"AuditStatus" -> If[fails === {}, "OK", "Failed"],
      "Failures" -> fails|>
  ];

SourceVault`SourceVaultAuditFunctionContracts[] :=
  SourceVault`SourceVaultAuditFunctionContracts[All];

SourceVault`SourceVaultAuditFunctionContracts[pkgOrAll_] :=
  Module[{contracts, per, nFail},
    contracts = If[pkgOrAll === All,
      Values[$svContractRegistry],
      Select[Values[$svContractRegistry],
        Lookup[#, "Package"] === pkgOrAll &]];
    per = Association @@ Map[
      Function[c, c["Symbol"] -> iSVAuditOne[c]], contracts];
    nFail = Count[Values[per], a_ /; a["AuditStatus"] === "Failed"];
    <|"Status" -> If[nFail === 0, "OK", "Failed"],
      "Checked" -> Length[contracts],
      "OKCount" -> Length[contracts] - nFail,
      "FailedCount" -> nFail,
      "PerSymbol" -> per|>
  ];

(* ============================================================
   8. pilot 契約の登録 (SourceVault.wl ロード済みのときのみ)
      spec §5.2 / §10 F2。実在しない環境 (standalone テスト) では登録しない。
   ============================================================ *)

iSVRegisterPilotContracts[] :=
  Module[{},
    If[Names["SourceVault`SourceVaultInitialize"] === {}, Return[Null]];

    (* --- Init: SourceVaultInitialize (§4.2) --- *)
    SourceVault`SourceVaultRegisterFunctionContract[<|
      "ObjectClass" -> "SourceVaultFunctionContract",
      "ContractVersion" -> 2,
      "Symbol" -> "SourceVaultInitialize",
      "Package" -> "SourceVault",
      "Kind" -> "Init",
      "Provides" -> {"$SourceVaultRoots"},
      "InitializedQRef" -> "SourceVault`Private`iSVRootsReadyQ",
      "EnsureFunction" -> "SourceVaultInitialize",
      "ForceFunction" -> "SourceVaultInitialize",
      "DefaultInitModeForDirectCall" -> "Force",
      "DefaultInitModeForWiring" -> "Ensure",
      "InitCost" -> "Cheap", "ReinitSafe" -> True,
      "RecommendedEntrypoint" -> False,
      "AbstractionLevel" -> "UserFacing",
      "Writes" -> {"$SourceVaultRoots"},
      "CallForms" -> {<|
        "FormId" -> "main", "ExpressionHead" -> "SourceVaultInitialize",
        "Arguments" -> {<|"Name" -> "opts", "Kind" -> "OptionsPattern",
                          "Required" -> False|>},
        "Recommended" -> True, "UseForClaudeEval" -> True|>},
      "OptionContracts" -> {
        <|"Name" -> "Roots", "Default" -> Automatic|>,
        <|"Name" -> "Force", "Default" -> False,
          "AllowedValues" -> {True, False}|>,
        <|"Name" -> "InitMode", "Default" -> "Force",
          "AllowedValues" -> {"Force", "Ensure"}|>},
      "UnknownOptionPolicy" -> "Reject",
      "Effects" -> {"FileWrite"}, "Idempotent" -> True,
      "CostClass" -> "Cheap"|>];

    (* --- Function: SourceVaultLookup --- *)
    SourceVault`SourceVaultRegisterFunctionContract[<|
      "ObjectClass" -> "SourceVaultFunctionContract",
      "ContractVersion" -> 2,
      "Symbol" -> "SourceVaultLookup",
      "Package" -> "SourceVault",
      "Kind" -> "Function",
      "Requires" -> {"SourceVaultInitialize"},
      "Reads" -> {"$SourceVaultRoots"},
      "RecommendedEntrypoint" -> True,
      "AbstractionLevel" -> "UserFacing",
      "CapabilityTags" -> {"registry.lookup"},
      "Inputs" -> {
        <|"Name" -> "topic", "PortType" -> "Value",
          "WLType" -> "String", "Required" -> True|>,
        <|"Name" -> "key", "PortType" -> "Value",
          "WLType" -> "Any", "Required" -> True|>},
      "Outputs" -> {
        <|"Name" -> "result", "PortType" -> "Value",
          "WLType" -> "Association"|>},
      "CallForms" -> {<|
        "FormId" -> "main", "ExpressionHead" -> "SourceVaultLookup",
        "Arguments" -> {
          <|"Name" -> "topic", "Kind" -> "Positional",
            "WLType" -> "String", "Required" -> True,
            "MapsToPort" -> "topic"|>,
          <|"Name" -> "key", "Kind" -> "Positional",
            "WLType" -> "Any", "Required" -> True,
            "MapsToPort" -> "key"|>,
          <|"Name" -> "opts", "Kind" -> "OptionsPattern",
            "Required" -> False|>},
        "Recommended" -> True, "UseForClaudeEval" -> True|>},
      "OptionContracts" -> {
        <|"Name" -> "Channel", "Default" -> "public",
          "AllowedValues" -> {"public", "private"}|>,
        <|"Name" -> "AllowSeed", "Default" -> True,
          "AllowedValues" -> {True, False}|>},
      "UnknownOptionPolicy" -> "Reject",
      "Effects" -> {}, "Idempotent" -> True, "CostClass" -> "Cheap"|>];

    (* --- Function: SourceVaultFindNotebooks --- *)
    SourceVault`SourceVaultRegisterFunctionContract[<|
      "ObjectClass" -> "SourceVaultFunctionContract",
      "ContractVersion" -> 2,
      "Symbol" -> "SourceVaultFindNotebooks",
      "Package" -> "SourceVault",
      "Kind" -> "Function",
      "Requires" -> {"SourceVaultInitialize"},
      "Reads" -> {"$SourceVaultRoots"},
      "RecommendedEntrypoint" -> True,
      "AbstractionLevel" -> "UserFacing",
      "CapabilityTags" -> {"notebook.search", "todo.filter"},
      "IntentExamples" -> {
        "Todo が残っているノートブックを探す",
        "レビュー予定のノートブック一覧"},
      "Outputs" -> {
        <|"Name" -> "records", "PortType" -> "Value",
          "WLType" -> "List"|>},
      "CallForms" -> {<|
        "FormId" -> "main", "ExpressionHead" -> "SourceVaultFindNotebooks",
        "Arguments" -> {<|"Name" -> "opts", "Kind" -> "OptionsPattern",
                          "Required" -> False|>},
        "Recommended" -> True, "UseForClaudeEval" -> True|>},
      "OptionContracts" -> {
        <|"Name" -> "OpenTodos"|>, <|"Name" -> "NextReview"|>,
        <|"Name" -> "Deadline"|>, <|"Name" -> "Keywords"|>,
        <|"Name" -> "Title"|>, <|"Name" -> "Status"|>,
        <|"Name" -> "Scope"|>,
        <|"Name" -> "ForceReindex", "Default" -> False,
          "AllowedValues" -> {True, False}|>,
        <|"Name" -> "Format", "Default" -> False,
          "AllowedValues" -> {True, False}|>},
      "UnknownOptionPolicy" -> "Reject",
      "Effects" -> {}, "Idempotent" -> True, "CostClass" -> "Kernel"|>];

    (* --- Function: SourceVaultUpcomingSchedule --- *)
    SourceVault`SourceVaultRegisterFunctionContract[<|
      "ObjectClass" -> "SourceVaultFunctionContract",
      "ContractVersion" -> 2,
      "Symbol" -> "SourceVaultUpcomingSchedule",
      "Package" -> "SourceVault",
      "Kind" -> "Function",
      "Requires" -> {"SourceVaultInitialize"},
      "Reads" -> {"$SourceVaultRoots",
        "SourceVault`Private`$iSVIndexCache"},
      "RecommendedEntrypoint" -> True,
      "AbstractionLevel" -> "UserFacing",
      "CapabilityTags" -> {"schedule.review", "todo.filter",
        "notebook.search"},
      "IntentExamples" -> {
        "今日から7日間の予定を表示",
        "締切とレビュー予定の一覧",
        "Todo が残っている予定を見せて"},
      "UseInsteadOf" -> {
        "SourceVaultFindNotebooks" -> "期日ベースのスケジュール表示が目的の場合"},
      "Outputs" -> {
        <|"Name" -> "schedule", "PortType" -> "Value",
          "WLType" -> "Dataset|List"|>},
      "CallForms" -> {<|
        "FormId" -> "main",
        "ExpressionHead" -> "SourceVaultUpcomingSchedule",
        "Arguments" -> {<|"Name" -> "opts", "Kind" -> "OptionsPattern",
                          "Required" -> False|>},
        "Recommended" -> True, "UseForClaudeEval" -> True|>},
      "OptionContracts" -> {
        <|"Name" -> "Scope", "Default" -> Automatic|>,
        <|"Name" -> "Period", "Default" -> Quantity[7, "Days"]|>,
        <|"Name" -> "IncludeOverdue", "Default" -> True,
          "AllowedValues" -> {True, False}|>,
        <|"Name" -> "Recursive", "Default" -> True,
          "AllowedValues" -> {True, False}|>,
        <|"Name" -> "Refresh", "Default" -> "Never",
          "AllowedValues" -> {"Never", "IfStale", "Force"}|>,
        <|"Name" -> "FallbackToCloud", "Default" -> "Ask",
          "AllowedValues" -> {"Ask", "Allow", "Deny"}|>,
        <|"Name" -> "StatusFilter", "Default" -> {"Todo"}|>,
        <|"Name" -> "UseCache", "Default" -> True,
          "AllowedValues" -> {True, False}|>,
        <|"Name" -> "OpenTodos", "Default" -> Missing[]|>,
        <|"Name" -> "DateField", "Default" -> "Both",
          "AllowedValues" -> {"Both", "Deadline", "NextReview"}|>,
        <|"Name" -> "FilterSpec", "Default" -> Missing[]|>,
        <|"Name" -> "OutputFormat", "Default" -> "Dataset",
          "AllowedValues" -> {"Dataset", "Rows", "Records"}|>},
      "UnknownOptionPolicy" -> "Reject",
      "Effects" -> {}, "Idempotent" -> True, "CostClass" -> "Kernel"|>];

    (* --- Function: SourceVaultResolve --- *)
    SourceVault`SourceVaultRegisterFunctionContract[<|
      "ObjectClass" -> "SourceVaultFunctionContract",
      "ContractVersion" -> 2,
      "Symbol" -> "SourceVaultResolve",
      "Package" -> "SourceVault",
      "Kind" -> "Function",
      "Requires" -> {"SourceVaultInitialize"},
      "Reads" -> {"$SourceVaultRoots"},
      "RecommendedEntrypoint" -> True,
      "AbstractionLevel" -> "UserFacing",
      "CapabilityTags" -> {"registry.resolve", "model.resolve"},
      "IntentExamples" -> {"用途に合うモデルを解決する"},
      "Inputs" -> {
        <|"Name" -> "kind", "PortType" -> "Value",
          "WLType" -> "String", "Required" -> True|>,
        <|"Name" -> "query", "PortType" -> "Value",
          "WLType" -> "Association", "Required" -> True|>},
      "Outputs" -> {
        <|"Name" -> "result", "PortType" -> "Value",
          "WLType" -> "Association"|>},
      "CallForms" -> {<|
        "FormId" -> "main", "ExpressionHead" -> "SourceVaultResolve",
        "Arguments" -> {
          <|"Name" -> "kind", "Kind" -> "Positional",
            "WLType" -> "String", "Required" -> True,
            "MapsToPort" -> "kind"|>,
          <|"Name" -> "query", "Kind" -> "Positional",
            "WLType" -> "Association", "Required" -> True,
            "MapsToPort" -> "query"|>,
          <|"Name" -> "opts", "Kind" -> "OptionsPattern",
            "Required" -> False|>},
        "Recommended" -> True, "UseForClaudeEval" -> True|>},
      "OptionContracts" -> {
        <|"Name" -> "Channel", "Default" -> "public",
          "AllowedValues" -> {"public", "private"}|>,
        <|"Name" -> "AllowSeed", "Default" -> True,
          "AllowedValues" -> {True, False}|>,
        <|"Name" -> "Topic", "Default" -> Automatic|>},
      "UnknownOptionPolicy" -> "Reject",
      "Effects" -> {}, "Idempotent" -> True, "CostClass" -> "Cheap"|>];

    Null
  ];

Quiet @ Check[iSVRegisterPilotContracts[], Null];

(* ── ClaudeRuntime hook への弱結合登録 (rule 11、§6.1) ──
   ClaudeRuntime が先にロード済みならここで接続する。逆順 (contracts が先) の
   場合は ClaudeRuntime.wl ロード末尾の対称コードが接続する (両側 handshake)。
   既にユーザーが別 validator を設定していれば上書きしない。 *)
iSVWireRuntimeValidator[] :=
  If[Names["ClaudeRuntime`$ClaudeCallContractValidator"] =!= {},
    With[{cur = Quiet @ Check[
        Symbol["ClaudeRuntime`$ClaudeCallContractValidator"], $Failed]},
      If[cur === None,
        ToExpression[
          "ClaudeRuntime`$ClaudeCallContractValidator = " <>
          "SourceVault`SourceVaultCallContractValidatorHook"]]]];

Quiet @ Check[iSVWireRuntimeValidator[], Null];

End[] (* `ContractsPrivate` *)

EndPackage[]
