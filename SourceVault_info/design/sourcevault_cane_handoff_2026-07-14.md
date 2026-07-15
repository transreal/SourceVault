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
| 1H-S④ | **PrepareLLMInput 移行第一段=LLM boundary shadow**(全18入口 inventory+観測フック) | capbroker.wl+11ファイル | 35/35 | result.nb ✅ |
| 1H-S⑤ | **移行第二段=warn/enforce 段階ゲート**(mode+EnforceList+token 配線パイロット) | capbroker.wl+12ファイル | 60/60 | result2.nb ✅ |
| 1F'' | **実 proposer 供給**(MakeLLMProposer/Verifier+非同期 SubmitMultiModelDecision) | adjudication.wl | 28/28 | result2.nb ✅ |
| 1H-A' | **anomaly schedule 配線**(ScheduleTick+service 低頻度 hook 結線・既定 off) | anomaly.wl+servicemanager.wl | 14/14 | result2.nb ✅ |
| 1H-S⑥ | **全18入口 self-prepare token 配線+mining thinking 抑止**(§1.12) | capbroker.wl+13ファイル | 64/64 | result3.nb ✅ |
| 1H-S⑦ | **/pdfask 上流 mint**(iWebChat=plan 確定後 mint→backend へ caller token)(§1.13) | capbroker.wl+servicemanager.wl | 67/67 | — |
| 1G' | **ClaudeEval 入口 shadow recorder**(非侵襲 hook・opt-in)(§1.13) | cognition.wl | 26/26 | result4.nb ✅ |
| 観測常時化 | **永続観測設定+ロード時自動適用**(§1.14) | capbroker.wl+SourceVault.wl | 73/73 | — |

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
**GitHub コミット済み(ae0e2bd、blob 15)+ NB 実機済み(result.nb: inventory Dataset /
shadow on で SummarizeText LLMFn シームから NoToken event 記録・Stats 集計を FE で確認)**。

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
- 次段(warn → enforce)は §2-1 参照 → **§1.11 で実装済み**。

### 1.11 移行第二段(warn/enforce)+1F 結線+anomaly schedule(2026-07-14 後半)

**GitHub コミット済み(e789eb0、blob 21)+ NB 実機済み(result2.nb)**: enforce パイロット=無 token で
::refused+Failure、自動 mint で実 LM Studio 要約成功 / 1F 非同期=submit 即 Running(Steps 0)→Await で
Completed、実 qwen3 で 3 proposer 中 2 が JSON 不遵守で ExcludedProposers 落ち・1 claim Unresolved →
NeedMoreEvidence(I-11 どおりの abstain。**ローカル reasoning モデルの JSON 遵守率が実運用課題**=
proposer prompt 強化 or mining async 経路の enable_thinking 抑止が改善候補)/ anomaly schedule=owner 登録+
手動 tick "Ran"(service 常駐分は再起動後に有効)。

**(1) warn/enforce 段階ゲート(1H-S⑤)**: capbroker.wl に `$SourceVaultLLMBoundaryMode`
("Shadow"(既定)|"Warn"|"Enforce")+`$SourceVaultLLMBoundaryEnforceList`(entrypoint 単位の段階昇格=
**token 配線済み入口から個別に enforce する推奨経路**)+`SourceVaultLLMBoundaryGate`(Warn=Message+続行/
Enforce=非 Verified 拒否。enforce のみ one-shot consume、shadow/warn は非消費。token の RunRef/StepRef を
env へ補完=呼び出し元 mint token を境界で照合可能)+`SourceVaultLLMBoundaryGateRefusedQ`(hook 用述語。
**Quiet/Check で包むと Warn の Message が抑止されるので素呼び**)+`SourceVaultLLMBoundaryActiveQ`。
18 境界の hook は全て gate 経由に更新(拒否は各関数の失敗慣例: Failure/$Failed/""/Missing/Status->Failed。
workflowcatalog cloud は拒否時 local へ退避)。**token 配線パイロット**: SummarizeText に
"PrepareToken"(Automatic=active 時のみ mint)/"RunRef" を追加、model 先解決で envelope を確定して
iWebLLMComplete へ PreparedToken を渡す(死にポート実 HTTP で end-to-end 検証済み)。
event=`LLMBoundaryGateRecorded`、Stats に RefusedCount/ByMode 追加。llmshadow_test 35→**60/60**。

**(2) 1F 実 proposer 供給(1F'')**: adjudication.wl に `SourceVaultMakeLLMProposer/Verifier`
(QueryFn 注入シーム。既定=gate 済み経路(SourceVaultQueryLocalLLM/iCallSummaryLLM)。JSON claims 応答を
パース、失敗は $Failed=ExcludedProposers。同一 AgentLabel=同一 CorrelationGroup=I-11)+
`SourceVaultSubmitMultiModelDecision[inputRef, k, opts]`(**AwaitingLLM 非同期 net**: ToPropose→Propose
(k fan-out/fan-in)→Decide(driver 実行)→Decided。SubmitFn 既定=mining iSVMSubmitLLMAsync)+
DecisionJobStatus/JobResult/AwaitDecisionJob(mining 流儀=marking 完了判定・await 中は tick しない)。
skill orchestrator-async-llm 準拠(deferred-mock+pump で headless 検証)。新テスト
`SourceVault_adjudication_orch_test.wls` **28/28**(実 orchestrator 使用)。

**(3) anomaly schedule 配線(1H-A')**: anomaly.wl に `SourceVaultCaneAnomalyScheduleTick`
(due 判定=profile ScheduleSpec×pipeline-status watermark。catch-up は 1 回のみ。**Reused でも liveness
touch**=空 streams の縮退で probe が偽 PipelineStale にならない。RunFn 注入シーム)を追加し、
servicemanager の service ループに弱結合ブロックで結線($SourceVaultCaneAnomalyTickIntervalSeconds
既定 600s・TimeConstrained 300s・Disabled/NotDue は log しない)。**既定 off**: owner が
`SourceVaultRegisterCaneAnomalySchedule[<|"IntervalSeconds"->86400|>, "OwnerAuthorization"->True]` 後、
service 再起動で有効化。新テスト `SourceVault_anomaly_schedule_test.wls` **14/14**。
回帰: anomaly 73/73・servicemanager 22/22・capbroker 24/24・security 7/7・adjudication 24/24 green。

### 1.12 全入口 token 配線(self-prepare)+mining thinking 抑止(2026-07-14 追補)

**GitHub コミット済み(f1b0fb0、blob 16)+ NB 実機済み(result3.nb)**: shadow on で SummarizeText →
上流 mint 経路が iWebLLMComplete で **Verified** 記録、Stats がセッション横断の永続 event を正しく集計
(Coverage 0.5=旧 NoToken 込み/RefusedCount 1/ByMode Shadow+Enforce/Registered 18)。
**1F 再実験済み(2026-07-15 FE 実機)**: thinking 抑止後、`ExcludedProposers -> {}`・`CandidateCount -> 3`
(抑止前は 2/3 落ち)=**候補化率 3/3 に改善**。3 claim は文言差("word/term"・"(jikken)" 有無)で
NormalizedClaim が別扱い→各 Unresolved→NeedMoreEvidence(仕様どおりの abstain。VerifierFn を付ければ
blind 判定で Supported へ解決される形。同一 label=IndependentGroups 1 も I-11 どおり)。

- **全 18 入口が token-carrying に**: capbroker に `SourceVaultLLMBoundarySelfGateRefusedQ[epId, env]`
  (boundary active 時のみ envelope を self-mint(RunRef="svrun:boundary:<epId>" で event から識別可)して
  gate に通す。**mint 失敗=NoToken=Enforce では fail-close**。非 active はゼロコスト)を追加し、
  iWebLLMComplete(上流 mint 済み=SummarizeText パイロット)以外の **17 入口を全て self-gate に置換**。
  これで任意の入口を `$SourceVaultLLMBoundaryEnforceList` に入れて個別 enforce 可能(コード変更不要)。
  上流 mint はより早い束縛点なので、実運用で重要な chain から順に caller 配線へ置き換えるのが理想
  (self-prepare はその踏み台)。注: shadow/warn は非消費 verify のため prepared ledger に issued
  レコードが残る(将来の prune 対象・容量小)。
- **mining thinking 抑止**: SourceVaultQueryLocalLLM(同期)+iSVMBuildLLMHTTPRequest(非同期)の request に
  `chat_template_kwargs: enable_thinking->False` を追加(maildb/eagle と同じ)。result2.nb で観察した
  「1F 実 LLM proposer 2/3 が JSON 不遵守で落ちる」の主因対策(Qwen3 系 reasoning モデルの思考が
  reasoning_content に流れ content が空/不遵守になる)。
- テスト: llmshadow_test 60→**64/64**(seam self-mint で enforce 通過/broker 破損 fail-close/
  self-prepare の RunRef マーカー/直接 HTTP 境界の e2e)。回帰 green(§6)。

### 1.13 /pdfask 上流 mint+1G ClaudeEval shadow recorder(2026-07-15)

**GitHub コミット済み(cd310a6、blob 8)+ 1G' は NB 実機済み(result4.nb)**: Enable →
`ClaudeEval["それを 送って"]` が**本物のホットパスで通常動作**(LLM は commit 再実行と解釈し claudecode
既存の承認ゲートが通常発火=hook の非干渉を実証)、Stats は DraftOnly/High/{AmbiguousReferent,
RecipientUnspecified, IrreversibleActionRequested}=1G 想定どおり、Disable で復元。**shadow 判定
(DraftOnly=慎重)と実パイプラインの承認ゲート発火が一致=alignment データ収集の実例**。
/pdfask 上流 mint の実機(実 LM Studio 経由の /pdfask)は未(headless e2e は G8 で検証済み)。

**(1) /pdfask 上流 mint(1H-S⑦)**: `SourceVaultLLMBoundarySelfGateRefusedQ` に 3 引数形(caller token
優先・無ければ self-prepare)を追加。servicemanager の iWebChat が **backend plan 確定後・dispatch 前**に
最終 envelope を確定して mint(active 時のみ。RunRef "svrun:pdfask:iWebChat")し、
iWebChatLocal/BilledAPI/Cloud(いずれも第 3 引数 token を追加。既存 2 引数呼びは既定 Missing で不変)へ
渡す。local は model を先解決して渡す(iWebChatModel は解決済み文字列を素通し=二重解決なし)。
**envelope は各 backend の gate env と一致必須**(不一致=RequestMismatch)。fallback local は backend が
変わるため上流 token 対象外=self-prepare に委ねる。外部公開経路(非 owner IP 可)の plan→dispatch 間
改変が検出対象になった。llmshadow_test 64→**67/67**(G8=死にポート e2e で Verified+RunRef マーカー確認)。

**(2) 1G ClaudeEval 入口 shadow recorder(1G')**: cognition.wl に
`SourceVaultEnableOwnerInputShadow[opts]` / `Disable` / `Status` / `Stats`。skill
package-hook-installation-patterns の「DownValues swap+CheckAbort」テンプレ準拠で ClaudeCode`ClaudeEval に
非侵襲 hook(claudecode.wl 無改変・**opt-in=自動 enable しない**・Enable/Disable 冪等・非 String 形は
素通し)。hook は AssistOwnerInput("Persist"->False=決定的・LLM 不使用)で評価し、内容最小化 event
`OwnerInputShadowRecorded`(mode/risk/signal 名/文字数/digest。**prompt 本文なし**=I-13)を記録してから
必ず原本を無変更引数で呼ぶ(TimeConstrained 2s+Quiet)。enforce なし。新テスト
`SourceVault_cognition_ownershadow_test.wls` **26/26**(依存 gate/結果不変/非 String 素通し/復元/統計。
**罠21: umbrella は claudecode をロードするので test は実 ClaudeEval の DV を退避→ClearAll→stub 化**)。
有効化(owner・FE): `SourceVaultEnableOwnerInputShadow[]` → `SourceVaultOwnerInputShadowStats[]` で観測。
1F 再実験も §1.12 に記録済み(thinking 抑止で候補化 3/3)。
回帰: servicemanager 22/22・cognition 4 suites・capbroker 24/24 green。

### 1.14 観測の常時化(2026-07-15)

`SourceVaultSetBoundaryObservation[<|"Shadow"->True, "OwnerInputShadow"->True|>]`(owner 1 回)で
観測設定を `<LocalState>/capbroker/config/observation.json` に永続化し、**SourceVault ロード末尾の
auto-apply(SourceVault.wl 末尾ブロック)が全カーネル(FE/service/headless)へ適用**する。
`SourceVaultApplyBoundaryObservation[]`(設定が正=双方向)/`SourceVaultBoundaryObservationConfig[]`
(Config+Live 照会)。**観測のみ永続化**(Mode/EnforceList は改ざん耐性=trusted config が要るため
セッション内 owner 明示のみ)。設定なしは NoConfig=完全無変更(fresh kernel で実機確認済み)。
**テスト作法**: 観測 config を持つ機械でもテストが決定的に走るよう、llmshadow/ownershadow テスト冒頭に
リセットガード(toggle off+hook Disable)を追加済み。他 suite は observe-only 性質により結果不変。
llmshadow_test 67→**73/73**(O 節=NoConfig 無変更/set 即適用/fresh-kernel 適用/config 経由 hook on/off)。

## 2. 未実装(次セッションの選択肢。優先度順)

(旧 1=warn/enforce は §1.11(1)、旧 3=1F 結線は §1.11(2)、旧 4=anomaly schedule は §1.11(3)、
残り入口の token 配線は §1.12(self-prepare)+§1.13(上流 mint 2 chain)、1G 入口結線(shadow)は
§1.13(2)、観測の常時化は §1.14 で実装済み)

1. **boundary の実運用昇格(運用タスク・owner 判断)**
   (a) 観測の常時化=`SourceVaultSetBoundaryObservation[<|"Shadow"->True, "OwnerInputShadow"->True|>]`
   を owner が 1 回実行(§1.14。以後全カーネルに自動適用)→ `SourceVaultLLMBoundaryShadowStats` /
   `SourceVaultOwnerInputShadowStats` でデータ収集。(b) 任意の入口を `$SourceVaultLLMBoundaryEnforceList`
   に追加して個別 enforce(§1.12 で全入口が昇格可能)。全体 `$SourceVaultLLMBoundaryMode="Enforce"` は
   運用実績を見て owner 判断。(c) enforce 設定の永続化(trusted config=MAC 署名)は必要になったら別増分。
2. **1G の ClaudeEval 入口結線**(owner prompt を `AssistOwnerInput` に通す)
   ClaudeEval は claudecode.wl の **課金・対話ホットパス**で回帰リスクが高い(memory: schedule freeze /
   mail fetch 同期ブロックの前科)。**直接改変は見送り推奨**。やるなら webingest の LLMFn と同じく
   トグル付き・非侵襲な shadow recorder として、既存経路に影響しない形で。
3. **1F 裁定の実運用**(owner 操作)
   実 LM Studio で `SourceVaultSubmitMultiModelDecision["svtext:...", 3]`(SubmitFn Automatic=ローカル LLM
   ×3 sample)や、異種モデル proposer(`SourceVaultMakeLLMProposer[{"claudecode",""}, ...]` 等を
   RunMultiModelDecision へ)のライブ確認。機構は §1.11(2) で完成済み。
4. **anomaly schedule の実運用有効化**(owner 操作)
   `SourceVaultRegisterCaneAnomalySchedule[<|"IntervalSeconds"->86400|>, "OwnerAuthorization"->True]` →
   service 再起動。実 stream 供給(現状は空 streams=liveness のみ)を繋ぐのは別増分。
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
  adjudication_test adjudication_orch_test capbroker_test taint_test \
  security_hardening_test anomaly_test anomaly_schedule_test llmshadow_test; do
  wolframscript -file "test codes/SourceVault_${t}.wls" 2>&1 | grep "===="
done
```
期待: 全 green(合計 = 35+32+47 + 43+24+21+16 + 24+28 + 24+26+7 + 73+14 + 60)。
Guard test は 14→21(実送信並走 7 追加)、adjudication は 17→24(driver 7 追加)、
llmshadow_test は 35→60(§1.11 の warn/enforce gate 25 追加)、adjudication_orch_test 28(§1.11(2))と
anomaly_schedule_test 14(§1.11(3))は新規、に注意。テストは直列で回すこと
(並走させると席競合で「The product exited for an unknown reason」フレークが出る)。
