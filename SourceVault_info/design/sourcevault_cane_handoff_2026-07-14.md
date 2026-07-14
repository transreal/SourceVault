# Cane / Knowledge Home 実装 引き継ぎ書類(2026-07-14)

新セッションはこの文書 + memory `sourcevault-cane-knowledge-home-spec.md` を読めば作業を継続できる。
本書は `sourcevault_cane_handoff_2026-07-13.md` を継承し、その後の **1H-A(異常分析ワークフロー)**
および **結線第一弾(Guard 実送信 shadow 並走 / 1F runnable driver)** を反映した最新版。旧書は歴史参照用。

## 0. 全体像

「思考のための杖」(cane3/SSI2019)を SourceVault に実装するプロジェクト。oops メーリングリスト
(約6500通・4100 topic)をベース基準座標とし、(1) Knowledge Home 閲覧/追記、(2) topic 空間での位置推定・
近傍提案・前進支援、(3) 認知変動(人⊕LLM)の観測 shadow、(4) 複数 LLM 裁定、(5) owner 入力支援、
(6) security 統合、(7) 統計的異常検知×SystemDoctor 連携、を実現する。

- **仕様**: `SourceVault_info/design/sourcevault_cane_knowledge_home_mining_spec_v0_7.md`
  (v0.1〜v0.7 は各版が前版への差分。**v0.7 が最新・正準**。r1〜r6 の6ラウンドレビューで収束。受入基準105項目)
- **Phase 0 decision record**: `..._design/sourcevault_cane_phase0_decisions_v1.md`(SensitiveLocalVault/鍵/消去/lease 基盤)
- **応答は日本語で**(memory `language-japanese`)。

### 貫く設計原則(全 Phase 共通・逸脱禁止)
- **認知データはクラウド不可**: SupportNeedTier/DeviationScore/self-report 等の認知系数値は SensitiveLocalVault
  (`<LocalState>/sensitive/cognition/`、同期対象外)にのみ・暗号化して保存。LLM prompt / 下流 action /
  authorization / 監査平文へ一切流さない(ShadowOnly)。
- **人と LLM を同一枠組みで**: 忘却・思い込み・ループは subject(人/モデル)横断で同じ event 型で観測。
- **決定的コア + injectable シーム**: 各機能の中核は LLM 非依存の決定的コアで実装し、LLM は必ず注入シーム
  (`LLMFn` / `proposerFns` / `VerifierFn` / `ExtractorFn`)経由。テストは mock で完結、driver 自体は LLM を呼ばない。
- **enforce しない(shadow first)**: Guard/異常検知は当面「判定を記録するだけ」。通知・containment は別の昇格ゲートで
  段階的に有効化する(常駐 enforcement を作らない=I-16)。`Deny` という decision class は存在しない(I-2)。

## 1. 実装済み(全て検証+GitHub コミット済み)

| Phase | 内容 | 実装ファイル | テスト(headless) | 実機 |
|---|---|---|---|---|
| 1A | 読み取り専用 KH ブラウザ(topic prev/next・引用双方向・release gate) | knowledgehome.wl | 35/35 | result1/2.nb ✅ |
| 1B | 非破壊追記(ULID採番+ki alias CAS+supersede/undo+offline merge+BM25検索) | 〃 | 32/32 | result3.nb ✅ |
| 1C | 位置づけ(TopicPosition/UnknownMass/provenance)+近傍+3リング提案 | 〃 | 47/47 | result4/5.nb ✅ |
| 0 | SensitiveLocalVault 契約(暗号化・crypto-shredding 消去・bitemporal) | cognition.wl | 43/43 | result6.nb ✅ |
| 1D | OperationalSupportSignal v0(観測 shadow・SupportNeedTier) | 〃 | 24/24 | result7/8.nb ✅ |
| 1E | action risk taxonomy + Guard shadow + Commitment + 並走記録 | 〃 | 14/14 | — |
| 1E' | **Guard 実送信経路 shadow 並走**(`...WithGuardShadow`) | 〃 | 21/21 | — |
| 1G | owner 入力支援(OwnerInputRiskAssess/AssistOwnerInput) | 〃 | 16/16 | — |
| 1F | 複数 LLM 裁定コア(DecisionCase/Candidate/ClaimEvaluation、規則①〜⑧) | adjudication.wl | 17/17 | — |
| 1F' | **runnable driver**(`RunMultiModelDecision`、proposer/verifier シーム) | 〃 | 24/24 | — |
| 1H-S① | 既存経路是正(SummarizeText QuarantinePolicy/RunMiningPipeline isolation) | webingest.wl/mining.wl | 7/7 (+mining 回帰) | — |
| 1H-S② | capability broker(CapabilityLease atomic ledger + PreparedInputToken) | capbroker.wl | 24/24 | — |
| 1H-S③ | taint 伝播 / InputTrustAssessment / RunIntegrityState | taint.wl | 26/26 | — |
| 1H-A | 異常分析ワークフロー(observe-only・状態×入力ストリーム相関仮説) | anomaly.wl | 73/73 | — |
| 1H-S④ | **PrepareLLMInput 移行第一段=LLM boundary shadow**(全18入口 inventory+観測フック) | capbroker.wl+11ファイル | 35/35 | — |

**新規パッケージ6本**: knowledgehome / cognition / adjudication / capbroker / taint / anomaly。
全て umbrella loader(`SourceVault.wl` の auto-load リスト)と `SourceVault_info/upload_manifest.json` に登録済み。
api docs は `SourceVault_info/docs/api_{knowledgehome,cognition,adjudication,capbroker,taint,anomaly}.md`。
**副産物**: NBAccess crypto の cross-kernel key-index clobber 修正(`NBKeyMaterialExistsQ` 追加+merge 永続。
NBAccess パッケージとして別途コミット済み。cognition ストアの実データ消失バグを診断・修復し14 event 復旧)。

### 1.9 結線第一弾の要点(2026-07-14 追加分)

- **`SourceVaultPlanMessageReleaseWithGuardShadow[spec, opts]`**(cognition.wl / api_cognition.md §1G)
  既存の正準ゲート `SourceVaultPlanMessageRelease`(identity.wl)を **一切変えずに** 呼び、同じメール送信 action の
  Guard shadow 推奨(action risk taxonomy)を並走記録する。既存 plan に `"GuardShadow"` キーを **additive** に付与
  するだけなので既存 caller は完全無影響(`PlanMessageRelease` の DownValues は 1 のまま=定義不変を検証済み)。
  `GuardMailParallelRecorded`(内容最小)を記録し、`SourceVaultGuardShadowStats` に MailParallelCount /
  MailAlignmentRate / MailMisaligned を追加(false intervention 評価=§8 昇格材料)。これが 1E の
  「shadow mode で判定だけ記録・enforce しない」の実体。
- **`SourceVaultRunMultiModelDecision[inputRef, proposerFns, opts]`**(adjudication.wl / api_adjudication.md)
  1F を「裁定コア」から「実行可能ドライバ」へ完成させたもの。open→候補登録→claim評価→裁定を end-to-end 実行。
  **proposer/verifier の LLM 実走は injectable シーム**(VerifierFn は blind-judge として VerifierVerdicts に注入)。
  driver 自体は LLM を呼ばず mock でフルにテスト可能。欠落/不正候補は `ExcludedProposers` に記録。
  返り値に decision + ExcludedProposers + CandidateCount。**これが orchestrator の結線点**(実 proposer を後で供給)。

### 1.10 PrepareLLMInput 移行第一段: LLM boundary shadow(2026-07-14 追加分)

旧 §2-1「PrepareLLMInput の全 LLM 入口への強制移行」の **shadow 段(第一段)を実装完了**。

- **entrypoint inventory(全数調査で確定・計18)**: capbroker.wl の `$svLLMEntrypointStaticInventory` が正準。
  直接 HTTP 8(webingest iWebLLMComplete / servicemanager iWebChatLocal・iWebChatBilledAPI / mining 同期
  SourceVaultQueryLocalLLM+**非同期 iSVMSubmitLLMAsync(URLSubmit。同期と別経路)** / maildb iSVQueryLMStudio /
  eagle iSVEGQueryLocalLLMMessages(text+vision) / searchindex iSVHTTPEmbed(embeddings egress))+
  claudecode 委譲 8(servicemanager iWebChatCloud / eagle iSVEGQueryClaude・iSVEGQueryCodex / workflowcatalog
  iSVWFQueryCloudOrLocal / SourceVault.wl iCallSummaryLLM(maildb・llmlog の共有ハブ) / llmlog
  iSVLLCallSummaryModel / wiring FillUnresolvedWithLLM / promptrouter iSVPRExtractSlotValues)+
  seam 2(webingest SummarizeText:LLMFn / workflowcatalog iSVWFQueryLocal)。mcp.wl は LLM 送信境界を持たない
  (ルーター+出力 gate のみ)。Wolfram 組み込み LLM(LLMSynthesize 等)は不使用と確認。
- **capbroker.wl 新 API**: `$SourceVaultLLMBoundaryShadow`(トグル。**既定 False=opt-in**)、
  `SourceVaultRegisterLLMEntrypoint` / `SourceVaultLLMEntrypointInventory`、
  `SourceVaultLLMBoundaryShadowCheck[epId, env, (token)]`(**非消費** verify。決して送信をブロックしない)、
  `SourceVaultLLMBoundaryShadowStats`(NoToken/Verified/Mismatch/coverage 集計=昇格判断材料)。
- **全18境界に同型フック挿入済み**(`If[TrueQ[toggle], Quiet@Check[...ShadowCheck[...], Null]]` の
  observe-only 形。off 時は TrueQ 1回=ゼロコスト)。event は `LLMBoundaryShadowRecorded`(内容最小化:
  prompt 本文・token/MAC を記録しない。digest/provider/model/文字数のみ=I-14)。
- テスト: `test codes/SourceVault_llmshadow_test.wls` 35/35 green + 正準12本回帰 green +
  searchindex 29/29・servicemanager 22/22・workflowcatalog 36/36・maildb ALL PASS。
  servicemanager_phase2(detached service 実起動)は 4/12 だが**前コミット版でも同一の 8 fail=既存の
  環境要因**(席/schtasks)で本変更と無関係。headless の単発「The product exited for an unknown reason」
  は並走カーネルとの席競合フレーク(再実行で green)。
- 次段(warn → enforce)は §2-1 参照。

## 2. 未実装(次セッションの選択肢。優先度順)

いずれも「決定的コアは完成済み、残るは既存ホットパスへの挿し込み or 大規模移行」であり、着手前に方針
(トグル付き・opt-in か等)を owner に確認するのが安全。r5 の順序制約(1H-A は 1H-S 後)は既に充足済み。

1. **PrepareLLMInput 移行の第二段以降(warn → enforce)**(1H-S 仕上げ)
   shadow 段(§1.10)は完了。残るは (a) shadow を実運用で on にして `SourceVaultLLMBoundaryShadowStats` で
   coverage/mismatch データを収集、(b) 各呼び出し元(request 組み立て点)で `SourceVaultPrepareLLMInput` により
   token を発行し境界まで通す配線(webingest iWebLLMComplete には "PreparedToken"/"ShadowEntrypoint"
   オプションを追加済み=先行例)、(c) warn(不一致を明示ログ)→ enforce(token 必須・不一致拒否)への昇格
   ゲート。enforce は破壊的変更なので owner 判断で。
2. **1G の ClaudeEval 入口結線**(owner prompt を `AssistOwnerInput` に通す)
   ClaudeEval は claudecode.wl の **課金・対話ホットパス**で回帰リスクが高い(memory: schedule freeze /
   mail fetch 同期ブロックの前科)。**直接改変は見送り推奨**。やるなら webingest の LLMFn と同じく
   トグル付き・非侵襲な shadow recorder として、既存経路に影響しない形で。
3. **1F の実 proposer 供給**(orchestrator 結線)
   `RunMultiModelDecision` の proposerFns/VerifierFn シームに ClaudeOrchestrator からの実 LLM 呼び出しを配線。
   driver 側は完成済みなので、これは orchestrator 側での結線作業。非同期 LLM ジョブは skill
   `.claude/skills/orchestrator-async-llm` のパターンを使う。
4. **anomaly ワークフローの schedule 実配線**
   `RunCaneAnomalyWorkflow` は idempotent・observe-only(Enforcement→"ObserveOnly"、通知/containment なし)で
   実装済みだが、OS スケジュールタスクは設計上まだ作っていない。定期実行するなら ScheduleSpec を定義し
   service 低頻度 hook か schtasks に載せる(バッテリー運用の DisallowStartIfOnBatteries 罠に注意=memory
   `sourcevault-mcp-stale-elevated-task`)。
5. **1D CompareView の NB 実機再確認**(clobber 修復後の profile 一貫性の最終確認)。
6. **長期(Phase 2/3)**: encode 表示 / item 圧縮 / me'(自己モデル) / biometrics / family sharing /
   camouflage 倫理。仕様 v0.7 に記述あり。当面着手しない。

## 3. 開発の作法(このプロジェクトで確立)

- **編集**: Claude が `MyPackages/` の working file を直接編集。`GithubRepositories/` は触らない
  (前コミット状態=commit の diff 源。ただし PackageCommit 実行後は最新スナップショットに更新される)。
- **検証**: headless wolframscript テストを `test codes/*.wls` に置き、`wolframscript -file "test codes/X.wls"` で実行。
  FE 依存部(View/Window/Dataset)は NB 実機で確認(result*.nb を添付してもらう=verify-loop workflow)。
- **新規 .wl 追加時の必須手順**:
  1. `SourceVault.wl` の auto-load リストに追加(順序: 依存先の後)
  2. `SourceVault_info/upload_manifest.json` の `files` に追加
  3. `SourceVault_info/docs/api_<name>.md` を作成
  4. docs hash を `SourceVault_info/docs/.aux_source_hashes.json` に登録(下記スニペット)
     — これをしないと `PackageCommit` が `staledocs` で Blocked。**既存 .wl を編集して API を増やした場合も
     該当 api doc を更新し hash を再登録する。**
  5. **`End[]` 後に `Context[]==="Global`"` を確認**(罠3: Module 閉じ括弧欠落で後続定義が飲まれても umbrella の
     `Quiet@Check` が握り潰し、全関数が未定義になる。DownValues 数か context で検知する)
- **コミット**: `Get["github.wl"]` 後 `GitHubREST`PackageCommit["SourceVault", "DryRun"->False, "MessageGenerator"->msg]`。
  **メッセージは ASCII**(mojibake 罠回避)。docs gate に阻まれたら api doc + hash を更新して再実行。
- **未コミット diff の同梱注意**: working tree に他プロジェクトの未コミット分(spec-impl session 等)があると
  PackageCommit は全部を1スナップショットで反映する。Cane 分は既にコミット済みなので次回は差分のみ。

### docs hash 更新スニペット(新規/改変 .wl)
```wolframscript
side = FileNameJoin[{Directory[], "SourceVault_info", "docs", ".aux_source_hashes.json"}];
srcHash[wl_] := Module[{txt = Import[wl, "Text"]}, IntegerString[Hash[StringDelete[txt, "\r"]], 36]];
j = Developer`ReadRawJSONString[Import[side, "Text"]];
j["<name>"] = srcHash[FileNameJoin[{Directory[], "SourceVault_<name>.wl"}]];   (* key は doc basename の suffix *)
j["@main"] = srcHash[FileNameJoin[{Directory[], "SourceVault.wl"}]];           (* umbrella 変更時 *)
Export[side, Developer`WriteRawJSONString[j], "Text"];
```

## 4. 踏んだ罠(再発防止。全て memory にも記録済み)

1. **wolframscript -file の CP1252 読み**: Windows で .wls ソースを CP1252 で読むため `◎`/日本語リテラルが化ける。
   → テストは **pure ASCII** に保ち、topic マーカーや日本語は `FromCharacterCode[16^^25CE]` 等で構築。
   パッケージ本体は `Block[{$CharacterEncoding="UTF-8"}, Get[...]]` でロードされるので日本語 OK。
2. **NTFS 代替データストリーム(ADS)**: ファイル名にコロン `:` があると Windows で ADS を作り、
   正確パス read は通るが `FileNames` に出ず `RenameFile` も失敗。→ ID→ファイル名は
   `StringReplace[id, Except[WordCharacter|"-"]->"_"]` でサニタイズ(正準 ID は不変)。
3. **`End[]` 後の Context 確認**: Module 閉じ括弧欠落で後続定義が飲まれても umbrella の `Quiet@Check` が
   握り潰し、全関数が未定義になる(1A→1B で実際に踏んだ)。→ ロード後 `Context[]`/DownValues 数で検知。
4. **共有 SystemCredential key-index の cross-kernel clobber**: 鍵 index blob は全カーネル共有・last-writer-wins。
   → 存在判定は `NBKeyStatus` でなく `NBKeyMaterialExistsQ`(材料 cred 直接)、永続は merge。**認知ストアの
   実データ消失を招いた実バグ**。修正で 14 event 復旧。
5. **`Lookup[{}, key, Nothing]` は Nothing を裸で返す** → 空リスト guard 必須。`Flatten` の KeyValueMap は level 1 指定。
6. **`Select[rule のリスト, StringQ[#]&]` は Rule に述語適用で全滅** → Association 化してから Select で値判定。
   空文字 CanonicalLabel は key-exists-but-empty で seed が refLabel を shadow する(Lookup 既定値が効かない)→
   空文字は fall-through させる。
7. **`DateString[TimeZone->0, fmt]` は引数順誤り**(未評価→JSON化失敗→空ファイル) → `DateString[Now, fmt, TimeZone->0]`。
8. **実 digest はミリ秒付き ISO**(2026-07-10T10:43:58.159Z) → パース前に小数秒 strip。
   **DigestAtUTC は活動時刻 fallback に使わない**(ingest 日に履歴が潰れる)。catch-all `iCogLocalDayHour[_,_]:=Missing` を置く。
9. **未評価関数呼び出しの Part は静かに引数を返す**(`f[Null,9][[1]]=Null`) → パターン不一致の catch-all 定義を置く。
10. **`iWebLLMComplete` は OptionsPattern 定義で ClearAll mock が効かない** → `LLMFn` 依存注入シームで解決。
11. **不可逆語リストに `"mail "` は名詞に誤反応** → 動詞系(send/送信/送って/メールして)のみ。
12. **初回 full-corpus build は ~54min**(index 生成)。→ TopicAssign Gold mode(mail-to-item.index)+gold 自動ロードで
    ~57s に短縮済み。当日 partial の日次 sample は永続しない(冪等)。

## 5. 主要 API の入口(新セッションで触るとき)

```wolframscript
Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault.wl"]];
(* 1A/1B/1C: Knowledge Home *)
SourceVaultKnowledgeHomeEnsureLoaded[]                        (* 全 corpus 初回 ~57s、gold で高速化済み *)
SourceVaultKnowledgeHomeView[2672]                            (* 閲覧(FE) *)
SourceVaultKnowledgeHomeSuggestView["ハイパーテキストの整理"]  (* 3リング提案 or empty-explain *)
SourceVaultKnowledgeHomeAppend["◎ ラベル[ki N]\n\n本文", "Root"->dir]
(* 0/1D: cognition (SystemCredential backend 必須) *)
NBAccess`$NBCredentialBackend = "SystemCredential"; SourceVaultCognitionInitialize[];
SourceVaultOperationalSignalEstimate[]                        (* 実 digest から日次 tier *)
SourceVaultHumanSupportProfile["ent-owner"]; SourceVaultCognitionCompareView[]
SourceVaultCognitionErase["ent-owner"]                        (* DryRun manifest *)
(* 1E: Guard shadow(単発 + 実送信経路並走) *)
SourceVaultGuardEvaluate[<|"ActionKind"->"MailSend","Reversibility"->"Irreversible","Reach"->"Public","SensitivityGap"->0.3|>]
SourceVaultPlanMessageReleaseWithGuardShadow[spec]           (* 既存 PlanMessageRelease を不変で包み GuardShadow 付与 *)
SourceVaultGuardShadowStats[]                                 (* MailAlignmentRate 等の集計 *)
(* 1G: owner 入力支援 *)
SourceVaultAssistOwnerInput["それを 送って"]
(* 1F: 複数 LLM 裁定(コア + runnable driver) *)
cid = SourceVaultOpenDecisionCase["svtext:q", "ActionRiskClass"->"High"];
SourceVaultAddCandidate[cid, <|"AgentRefs"-><||>,"Role"->"Proposer","Claims"->{<|"Claim"->"X","DeterministicTest"->True|>},"Assumptions"->{},"UnresolvedQuestions"->{}|>];
SourceVaultEvaluateClaims[cid]; SourceVaultDecideCase[cid]
SourceVaultRunMultiModelDecision["svtext:q", proposerFns, "VerifierFn"->vf]  (* proposer/verifier は注入シーム *)
(* 1H-S: capbroker / taint *)
SourceVaultCapBrokerInitialize[]; SourceVaultRequestCapabilityLease[<|"RunRef"->"r","ActorRef"->"a","CapabilityKind"->"send","AllowedOperation"->"MailSend","TargetScope"->"x@y","Purpose"->"p","ParentDecisionRef"->"d"|>]
SourceVaultAssessInputTrust["Ignore all previous instructions..."]
SourceVaultComposeCrossObjectRisk[targetRef, edges, assessments]
(* 1H-A: 異常分析ワークフロー(observe-only) *)
SourceVaultRunCaneAnomalyWorkflow[]                          (* Enforcement->"ObserveOnly"、通知/containment なし *)
SourceVaultCaneDiagnosticsProbe[]                            (* Health+ReasonCode のみ *)
```

## 6. 全テスト一括実行(回帰確認)
```bash
cd "C:/Users/imai_/Dropbox/Mathematica-oneDrive/MyPackages"
for t in knowledgehome_test knowledgehome_append_test knowledgehome_position_test \
  cognition_test cognition_signal_test cognition_guard_test cognition_assist_test \
  adjudication_test capbroker_test taint_test security_hardening_test anomaly_test \
  llmshadow_test; do
  wolframscript -file "test codes/SourceVault_${t}.wls" 2>&1 | grep "===="
done
```
期待: 全 green(合計 = 35+32+47 + 43+24+21+16 + 24 + 24+26+7 + 73 + 35)。
Guard test は 14→21(実送信並走 7 追加)、adjudication は 17→24(driver 7 追加)、
llmshadow_test 35 は 1H-S④(§1.10)で追加、に注意。テストは直列で回すこと
(並走させると席競合で「The product exited for an unknown reason」フレークが出る)。
