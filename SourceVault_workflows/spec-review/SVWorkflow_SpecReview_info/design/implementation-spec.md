# 実装仕様: spec-review (consensus 設計仕様策定)

> 共有アーキテクチャ・データ契約・ファイルプロトコル・堅牢性ガードは正典
> `spec-impl/SVWorkflow_SpecImpl_info/design/implementation-spec.md` を参照。
> 本書は spec-review 固有部分のみ。最終更新 2026-06-23。

## 1. 役割

ノートブックの要件テキストから、起案モデル (`$ClaudeModel`) と検証モデル
(`$ClaudeAdvisaryModel`、既定 codex) の往復で **Wolfram 設計仕様 (Markdown)** を
Approved まで収束させる。出力は承認 spec の `sv://snapshot/OrchSpec/...` と
承認レビューの `sv://snapshot/OrchReview/...`。任意で `iRealCodegen` により承認仕様から
`.wl` パッケージも生成できる (主用途は spec のみ)。

## 2. 実行系 (ClaudeOrchestrator`Workflow` ネット)

- 本体 `SVWorkflow_SpecReview.wl`: 起案 `iRealDraft` → 検証 `iRealReview` → (NeedsRevision なら) 再起案、を `MaxRounds` まで。`iOrchQuery`/`iOrchCodex` でモデル呼び出し。
- 背景ドライバ `palette_driver.wls`。FE 側は claudecode.wl の `iRunOrchConsensusFromCells` / `iOrchConsensusTick` / `iOrchConsensusWriteBack` / `$iOrchConsensusJobs`。
- SourceVault: `orch/<project>/{requirements,spec,review}`、snapshot `OrchSpec`/`OrchReview`。

## 3. 適用済みの堅牢性ガード (正典 §10 と対応)

- **G1 壁時計 FE timeout**: `$iOrchConsensusMaxSeconds`=1500、job に `StartedAt`。旧 `$iOrchConsensusMaxTicks` (tick 数) は廃止。
- **G3 dead-proc fast-fail**: `iOrchConsensusTick` が driver プロセス死亡 (result 無し) を ~6s grace で検出し `iSpecImplDeadProcResult` (ExitCode/stderr) で書き戻し。
- **G4 失敗時の過程出力**: `iOrchConsensusWriteBack` の失敗枝でも `iSVConsensusProcessBoxes[project]` (spec/review チェーン) を出力。
- **G5 codex 壁時計上限**: `iOrchCodex` を `TimeConstrained[..,$iOrchCallTimeLimit=900,"TimedOut"]` 化。空応答は明示マーカーを返す。**`RunProcess` の `ProcessTimeLimit` は使わない (無効)**。
- **G6 空応答即 give-up**: 起案 (`iDraftHandler`) が空応答 (空文字 / codex の "produced no output" マーカー) を返したら `DraftEmpty` フラグを立て、ネットの guard で **GiveUp へ直行** (Approve は `! iDraftEmpty`、Revise も `! iDraftEmpty`、GiveUp は `iDraftEmpty || ...`)。`iReviewHandler` は空草案ならレビュー呼び出しを skip。`iGiveUpHandler` が理由 (`GiveUpReason`: 利用制限/過負荷の可能性、再実行を) を progress + payload に載せる。空応答を回し続けず・空 spec を誤 Approve しない。

## 4. spec-impl との差分 (適用しない/不要なもの)

- **動的ロード+launch / 生成テスト実行ゲート (正典 §9)** は spec-review の主出力が
  コードでなく **spec (Markdown)** のため非適用。`iRealCodegen` を使う場合のみ将来検討。
- 命名・context の `W` 接頭辞規則 (正典 §8) は生成パッケージ側 (spec-impl/codegen) の話。

## 5. 既知の限界

- **起案 (Draft)** の空応答は G6 で即 give-up する。**レビュー (Review)** 側の空応答は現状 NeedsRevision 既定に倒れて 1 ラウンド分回りうる (FE の壁時計 backstop + dead-proc fast-fail で最終的には止まる)。必要なら `iReviewHandler` にもレビュー空応答検出を足す。
- spec-impl の動的ロード+launch/生成テストゲート (正典 §9) は非適用 (主出力が spec=Markdown のため)。`iRealCodegen` で `.wl` を生成する場合のみ将来検討。
