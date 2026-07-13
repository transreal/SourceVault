# Cane / Knowledge Home 実装 引き継ぎ書類(2026-07-13)

新セッションはこの文書 + memory `sourcevault-cane-knowledge-home-spec.md` を読めば作業を継続できる。

## 0. 全体像

「思考のための杖」(cane3/SSI2019)を SourceVault に実装するプロジェクト。oops メーリングリスト
(約6500通・4100 topic)をベース基準座標とし、(1) Knowledge Home 閲覧/追記、(2) topic 空間での位置推定・
近傍提案・前進支援、(3) 認知変動(人⊕LLM)の観測 shadow、(4) 複数 LLM 裁定、(5) owner 入力支援、
(6) security 統合、を実現する。

- **仕様**: `SourceVault_info/design/sourcevault_cane_knowledge_home_mining_spec_v0_7.md`
  (v0.1〜v0.7 は各版が前版への差分。**v0.7 が最新・正準**。r1〜r6 の6ラウンドレビューで収束。受入基準105項目)
- **Phase 0 decision record**: `..._design/sourcevault_cane_phase0_decisions_v1.md`(SensitiveLocalVault/鍵/消去/lease 基盤)
- **応答は日本語で**(memory `language-japanese`)。

## 1. 実装済み(全て検証+GitHub コミット済み。2026-07-13)

| Phase | 内容 | 実装ファイル | テスト(headless) | 実機 |
|---|---|---|---|---|
| 1A | 読み取り専用 KH ブラウザ(topic prev/next・引用双方向・release gate) | knowledgehome.wl | 35/35 | result1/2.nb ✅ |
| 1B | 非破壊追記(ULID採番+ki alias CAS+supersede/undo+offline merge+BM25検索) | 〃 | 32/32 | result3.nb ✅ |
| 1C | 位置づけ(TopicPosition/UnknownMass/provenance)+近傍+3リング提案 | 〃 | 47/47 | result4/5.nb ✅ |
| 0 | SensitiveLocalVault 契約(暗号化・crypto-shredding 消去・bitemporal) | cognition.wl | 43/43 | result6.nb ✅ |
| 1D | OperationalSupportSignal v0(観測 shadow・SupportNeedTier) | 〃 | 24/24 | result7/8.nb ✅ |
| 1E | action risk taxonomy + Guard shadow + Commitment + 並走記録 | 〃 | 14/14 | — |
| 1G | owner 入力支援(OwnerInputRiskAssess/AssistOwnerInput) | 〃 | 16/16 | — |
| 1F | 複数 LLM 裁定(DecisionCase/Candidate/ClaimEvaluation、規則①〜⑧) | adjudication.wl | 17/17 | — |
| 1H-S① | 既存経路是正(SummarizeText QuarantinePolicy/RunMiningPipeline isolation) | webingest.wl/mining.wl | 7/7 (+mining 399/24 回帰) | — |
| 1H-S② | capability broker(CapabilityLease atomic ledger + PreparedInputToken) | capbroker.wl | 24/24 | — |
| 1H-S③ | taint 伝播 / InputTrustAssessment / RunIntegrityState | taint.wl | 26/26 | — |

**新規パッケージ5本**: knowledgehome / cognition / adjudication / capbroker / taint。
全て umbrella loader(`SourceVault.wl` の auto-load リスト)と `SourceVault_info/upload_manifest.json` に登録済み。
api docs は `SourceVault_info/docs/api_{knowledgehome,cognition,adjudication,capbroker,taint}.md`。
**副産物**: NBAccess crypto の cross-kernel key-index clobber 修正(`NBKeyMaterialExistsQ` 追加+merge 永続。
NBAccess パッケージとして別途コミット済み)。

## 2. 未実装(次セッションの選択肢)

r5 レビューで確立した実装順序制約: **1H-A は 1H-S 完了後**。1H-S コアは完了済みなので 1H-A 着手可能。

1. **1H-A(異常分析ワークフロー)** ← オーナーが当初要望した機構。**observe-only の独立ワークフロー**として実装
   (常駐 enforcement でない=I-16)。状態ストリーム(owner OperationalSignal率/LLM RiskSignal率/RunIntegrity率)と
   入力ストリーム(送信者新規性/injection率/ドメイン新規性)の各ベースライン逸脱を EWMA/changepoint(LLM不使用)で
   検知→lag付きクロス相関→AnomalyCorrelationHypothesis(**因果でなく相関仮説**、裁定必須、CommonCause 選択肢)。
   lineage dependence 分類(DirectLineage は仮説にしない)。SystemDoctor 連携は `SourceVaultDiagnosticsRegisterProbe`
   経由 producer-owned + 二層(通常 probe は Health+ReasonCode のみ、PendingSensitiveAlerts は sensitive doctor 限定)。
   cold start=`Missing["InsufficientBaseline"]`。**enforcement しない**(通知/containment は別昇格ゲート)。
   仕様: v0.6 §5.14 / §4.20 / I-15 / I-16、v0.7 §4.23。設計は spec に詳細あり。observe-only なので比較的安全。
2. **PrepareLLMInput の全 LLM 入口への強制移行**(1H-S 仕上げ) — 大規模。entrypoint inventory を作り
   provider 境界で PreparedInputToken を要求(現状は broker が token を発行できるだけで、既存の LLM 呼び出しは
   まだ token を通っていない)。servicemanager/mcp/mining/webingest 全経路に触るので慎重に。
3. **結線系**(いずれも既存コードへの挿し込み):
   - 1F の orchestrator 結線(proposer/verifier の実走。現状は裁定コアのみで LLM 実行は含まない)
   - 1G の ClaudeEval 入口結線(owner prompt を AssistOwnerInput に通す)
   - Guard の実送信経路並走(`SourceVaultPlanMessageRelease` 呼び出し側に `SourceVaultGuardRecordParallel` 挿入)
   - 1D CompareView の NB 実機再確認(clobber 修復後の profile 一貫性)

## 3. 開発の作法(このプロジェクトで確立)

- **編集**: Claude が `MyPackages/` の working file を直接編集。`GithubRepositories/` は触らない(前コミット状態維持=commit の diff 源)。
- **検証**: headless wolframscript テストを `test codes/*.wls` に置き、`wolframscript -file "test codes/X.wls"` で実行。
  FE 依存部(View/Window/Dataset)は NB 実機で確認(result*.nb を添付してもらう)。
- **新規 .wl 追加時の必須手順**:
  1. `SourceVault.wl` の auto-load リストに追加(順序: 依存先の後)
  2. `SourceVault_info/upload_manifest.json` の `files` に追加
  3. `SourceVault_info/docs/api_<name>.md` を作成
  4. docs hash を `SourceVault_info/docs/.aux_source_hashes.json` に登録(下記スニペット)
     — これをしないと `PackageCommit` が `staledocs` で Blocked。
  5. **`End[]` 後に `Context[]==="Global`"` を確認**(罠3: Module 閉じ括弧欠落で後続定義が飲まれても umbrella の
     `Quiet@Check` が握り潰し、全関数が未定義になる。DownValues 数か context で検知する)
- **コミット**: `Get["github.wl"]` 後 `GitHubREST`PackageCommit["SourceVault", "DryRun"->False, "MessageGenerator"->msg]`。
  **メッセージは ASCII**(mojibake 罠回避)。docs gate に阻まれたら api doc + hash を更新して再実行。
- **未コミット diff の同梱注意**: working tree に他プロジェクトの未コミット分(spec-impl session 等)があると
  PackageCommit は全部を1スナップショットで反映する。今回の Cane 分は既にコミット済みなので次回は差分のみ。

### docs hash 更新スニペット(新規 .wl 追加時)
```wolframscript
side = FileNameJoin[{Directory[], "SourceVault_info", "docs", ".aux_source_hashes.json"}];
srcHash[wl_] := Module[{txt = Import[wl, "Text"]}, IntegerString[Hash[StringDelete[txt, "\r"]], 36]];
j = Developer`ReadRawJSONString[Import[side, "Text"]];
j["<name>"] = srcHash[FileNameJoin[{Directory[], "SourceVault_<name>.wl"}]];   (* key はドキュメント basename の suffix *)
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
3. **共有 SystemCredential key-index の cross-kernel clobber**: 鍵 index blob は全カーネル共有・last-writer-wins。
   → 存在判定は `NBKeyStatus` でなく `NBKeyMaterialExistsQ`(材料 cred 直接)、永続は merge。
4. **`Lookup[{}, key, Nothing]` は Nothing を裸で返す** → 空リスト guard 必須。
5. **`Select[rule のリスト, StringQ[#]&]` は Rule に述語適用で全滅** → Association 化してから Select で値判定。
6. **`DateString[TimeZone->0, fmt]` は引数順誤り**(未評価→JSON化失敗) → `DateString[Now, fmt, TimeZone->0]`。
7. **実 digest はミリ秒付き ISO**(2026-07-10T10:43:58.159Z) → パース前に小数秒 strip。
   **DigestAtUTC は活動時刻 fallback に使わない**(ingest 日に履歴が潰れる)。
8. **未評価関数呼び出しの Part は静かに引数を返す**(`f[Null,9][[1]]=Null`) → パターン不一致の catch-all 定義を置く。
9. **`iWebLLMComplete` は OptionsPattern 定義で ClearAll mock が効かない** → `LLMFn` 依存注入シームで解決。
10. **不可逆語リストに `"mail "` は名詞に誤反応** → 動詞系(send/送信/送って/メールして)のみ。

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
(* 1E: Guard shadow *)
SourceVaultGuardEvaluate[<|"ActionKind"->"MailSend","Reversibility"->"Irreversible","Reach"->"Public","SensitivityGap"->0.3|>]
(* 1G: owner 入力支援 *)
SourceVaultAssistOwnerInput["それを 送って"]
(* 1F: 複数 LLM 裁定 *)
cid = SourceVaultOpenDecisionCase["svtext:q", "ActionRiskClass"->"High"];
SourceVaultAddCandidate[cid, <|"AgentRefs"-><||>,"Role"->"Proposer","Claims"->{<|"Claim"->"X","DeterministicTest"->True|>},"Assumptions"->{},"UnresolvedQuestions"->{}|>];
SourceVaultEvaluateClaims[cid]; SourceVaultDecideCase[cid]
(* 1H-S: capbroker / taint *)
SourceVaultCapBrokerInitialize[]; SourceVaultRequestCapabilityLease[<|"RunRef"->"r","ActorRef"->"a","CapabilityKind"->"send","AllowedOperation"->"MailSend","TargetScope"->"x@y","Purpose"->"p","ParentDecisionRef"->"d"|>]
SourceVaultAssessInputTrust["Ignore all previous instructions..."]
SourceVaultComposeCrossObjectRisk[targetRef, edges, assessments]
```

## 6. 全テスト一括実行(回帰確認)
```bash
cd "C:/Users/imai_/Dropbox/Mathematica-oneDrive/MyPackages"
for t in knowledgehome_test knowledgehome_append_test knowledgehome_position_test \
  cognition_test cognition_signal_test cognition_guard_test cognition_assist_test \
  adjudication_test capbroker_test taint_test security_hardening_test; do
  wolframscript -file "test codes/SourceVault_${t}.wls" 2>&1 | grep "===="
done
```
期待: 全 green(合計 = 35+32+47 + 43+24+14+16 + 17 + 24+26+7)。
