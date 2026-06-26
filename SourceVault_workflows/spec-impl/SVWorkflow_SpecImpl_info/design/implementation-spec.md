# 実装仕様: SourceVault ワークフロー策定パイプライン (spec-review + spec-impl)

> 対象: ノートブックの要件から **設計仕様を合意 (spec-review)** し、承認仕様を
> **コード化ワークフローとして実装 (spec-impl)** する 2 機能の実装仕様。
> 本書は両機能で共有する設計・契約・不変条件 (ガード) を定義する正典。
> spec-review 固有の補足は `spec-review/.../_info/design/implementation-spec.md`。
> 最終更新 2026-06-23。

---

## 1. 目的とスコープ

- **spec-review**: ノートブックの要件テキストから、起案モデルと検証モデルの
  往復 (consensus) で Wolfram 設計仕様 (Markdown) を作り、Approved まで収束させる。
- **spec-impl**: 承認済み設計仕様を、`SourceVault_workflows/testing/<slug>/` 配下の
  ロード可能な `SVWorkflow_<Canon>` ミニパッケージとして実装し、検証して登録する。
- 両者は **FE カーネルを固めない**ため、重い LLM ループを**背景 wolframscript**
  プロセスで実行し、FE は結果ファイルをポーリングして書き戻す。

非スコープ: 生成された個別ワークフローの機能仕様 (それは各ワークフローの spec)。

---

## 2. エンドツーエンド・パイプライン

```
ノートブック要件
   │  iRunOrchConsensusFromCells (パレット「仕様生成」)
   ▼
spec-review (consensus drafting)  ── SourceVault: orch/<project>/{requirements,spec,review}
   │  起案↔レビューを Approved まで反復、承認 spec を snapshot 保存
   ▼
承認済み設計仕様 (sv://snapshot/OrchSpec/...)
   │  iRunSpecImplFromCells (パレット「仕様実装」)
   ▼
spec-impl (implement↔verify)      ── SourceVault: impl/<slug>/{plan,planreview,artifact,verify}
   │  Plan → (AuxReview) → Implement → Verify(gates) → Approve/Revise/GiveUp
   ▼
testing/<slug>/ の SVWorkflow_<Canon> パッケージ + Workflow Catalog 登録
```

---

## 3. コンポーネント構成

| 機能 | ワークフロー本体 (背景) | 背景ドライバ | FE 側 (claudecode.wl) |
|---|---|---|---|
| spec-review | `spec-review/SVWorkflow_SpecReview.wl` (`ClaudeOrchestrator`Workflow`) | `spec-review/palette_driver.wls` | `iRunOrchConsensusFromCells` / `iOrchConsensusTick` / `iOrchConsensusWriteBack` / `$iOrchConsensusJobs` |
| spec-impl | `spec-impl/SVWorkflow_SpecImpl.wl` (公開 `RunSpecImpl`/`BuildNet`) | `spec-impl/palette_impl_driver.wls` | `CreateImplementationWorkflow` / `iSpecImplTick` / `iSpecImplWriteBack` / `$iSpecImplJobs` |

公開ファクトリ: `ClaudeCode`CreateImplementationWorkflow[name, approvedSpec, opts]`。
両ワークフローは **on-demand** ロード (`SourceVault`SourceVaultLoadWorkflow["spec-impl"|"spec-review"]`)。

---

## 4. 実行アーキテクチャ (FE ↔ 背景ドライバ)

1. FE (パレットボタン) が runDir を作り `config.wl` を `Put`、`StartProcess[wolframscript -file <driver> <config>]` で背景起動。FE はブロックしない。
2. 背景ドライバ (別 wolframscript カーネル) が SourceVault と当該ワークフローを fresh ロードし、`RunSpecImpl` 等を同期実行。重い claude/codex 呼び出しはここで起こる。
3. ドライバは遷移ごとに `progress.wl` を更新し、**最後に** `result.wl` を書く (= 完了シグナル)。
4. FE は共有ポーリング tick (3.0s, `ClaudeRegisterPollingTick`) で runDir を監視し、`progress.wl`→WindowStatusArea、`result.wl` 出現→ノートブックへ書き戻し。

**不変条件**: 背景ドライバが毎回ファイルから fresh ロードするので、`SVWorkflow_*.wl` の
プロンプト・ロジック修正は**再ロード不要で次回実行に即反映**される。FE 側 (claudecode.wl) の
修正だけはカーネル再読込が必要。

---

## 5. データ契約 (SourceVault チェーン)

すべて `SourceVaultSaveImmutableSnapshot` + `SourceVaultAtomicUpdatePointer` + `SourceVaultAppendEvent`。

- spec-review: pointer `orch/<project>/{requirements,spec,review}`、snapshot class `OrchSpec`/`OrchReview`。承認レビューは `TargetSpecRef` で承認 spec を指す。
- spec-impl: pointer `impl/<slug>/{plan,planreview,artifact,verify}`、snapshot class `ImplPlan`/`ImplPlanReview`/`ImplArtifact`/`ImplVerify`。
- これらは**失敗時も vault に残る** → 失敗書き戻しで過程テーブルを再構成できる (§10 参照)。
- 承認 spec の解決: review チェーンで Verdict=Approved のものの `TargetSpecRef` を優先、無ければ spec pointer の最新 (`iSpecImplApprovedSpec`)。

---

## 6. ファイルプロトコル (runDir)

`$TemporaryDirectory/specimpl_<uuid>/` (または `orchcons_`/`specrev_`)。

| ファイル | 書き手 | 意味 |
|---|---|---|
| `config.wl` | FE | ドライバ入力 (Name/SpecRef/Models/Progress・Result パス/PackageRoot/TargetDir/Language 等)。UTF-8。 |
| `notes.txt` | FE | 実装ノート (UTF-8 bytes)。 |
| `progress.wl` | ドライバ | ライブ進捗 (Phase/Role/Model/Round/Message/UpdatedAtUTC)。tick が読む。 |
| `result.wl` | ドライバ | **最後に書く完了シグナル**。Status=Done/Error、FinalStatus、各 chain/URI。 |

FE は `result.wl` 出現で成功/失敗を判定。**`result.wl` が無いまま driver プロセスが終了 = 異常終了**。

---

## 7. モデル役割と呼び出し

- 実装/起案 = `ClaudeCode`$ClaudeModel` (implementer)、検証/レビュー = `ClaudeCode`$ClaudeAdvisaryModel` (verifier)。
- 統一窓口 `iOrchQuery[model, prompt]`: provider が `chatgptcodex` なら `iOrchCodex` (codex CLI)、それ以外は `ClaudeCode`ClaudeQuerySync` (claude/anthropic/openai/lmstudio)。
- `iOrchCodex` は `codex exec -o <file> -` で最終メッセージを UTF-8 ファイル捕捉。
- 背景ドライバは config の `Language`/`LanguageInstruction` で FE の `$Language` を継承 (出力言語一致)。

---

## 8. 命名・コンテキスト規則 (必須)

- フォルダ slug は自由 (日付始まり可)。
- **canonical leaf** = slug を単語分割 → `Capitalize` 連結。3 つのミラー関数が**同一**でなければならない:
  `SourceVault_workflowregistry.wl iSVWFCanonicalSlug` (authoritative) / `SVWorkflow_SpecImpl.wl iCanonicalName` / `claudecode.wl iSpecImplCanonName`。
- **WL の context/symbol leaf は数字で始められない** → leaf が数字始まりなら **`W` を前置** (3 関数で同一ガード)。日本語 leaf は有効。
  違反すると実ロード時 `BeginPackage::cxt`。詳細: skills `wolfram-syntax-pitfalls` 罠 #64。
- 生成 BeginPackage の context は `SourceVaultWorkflowContext[slug]` と完全一致が必須 (不一致 = LoadFailed)。

---

## 9. 検証ゲート (spec-impl の Verify 段; `iVerifyHandler`)

順に適用。前段が落ちたら後段はスキップ。

1. **静的 smoke** (`iSmokeTestPackage`, ネット/カーネル不要): 主 `.wl` がパースし、BeginPackage が空 needed-list でなく期待 context 一致、`WorkflowInfo` 定義あり。失敗→NeedsRevision。
2. **動的ロード+launch (ハードゲート, `iDynHarnessLoad`)**: 新規 wolframscript で実 `SourceVaultLoadWorkflow`→`WorkflowInfo[]`→**無引数 launch 実行**。Status≠Loaded / 未 callable / launch が `$Failed`/`Missing`/未評価 → NeedsRevision。`Ran=False` (wolframscript 起動不可) は inconclusive でブロックしない。
3. **生成テスト実行 (アドバイザリ, `iRunGenTest`)**: `test_*.wls` を新規 wolframscript で実行し、結果を LLM 検証コンテキストに `=== EXECUTED TEST RESULT ===` として注入。テスト自体の脆さで誤ブロックしないため**ハードにしない**。
4. **LLM 検証 (`iRealVerify`)**: 仕様適合のみ判定。命名/構文/ロードは決定論ゲートが所有済みなので蒸し返さない。executed-test の core/spec 失敗は blocker、test 脆性は無視。

スイッチ: `$iDynTest` (既定 True)、`$iWolframScript`、`$iDynTestTimeLimit`。

---

## 10. 堅牢性の不変条件 (ガード一覧)

| # | 不変条件 | 実装 | 背景 (踏んだ不具合) |
|---|---|---|---|
| G1 | FE timeout は**壁時計秒**で測る (tick 数でない) | `$iSpecImplMaxSeconds`=2700 / `$iOrchConsensusMaxSeconds`=1500、job に `StartedAt` | tick 発火数判定は orphaned/burst で実時間前に誤発火→誤 "Timeout" |
| G2 | FE backstop は driver の MaxWait より**大きい** | 2700s > 2400s | 小さいと driver 完走前に FE が諦め result.wl を拾わない |
| G3 | driver プロセス即死 (result 無し) を**~6s で fast-fail** | `iSpecImplTick`/`iOrchConsensusTick` の procFinished+grace → `iSpecImplDeadProcResult` (ExitCode+stderr) | 起動失敗 (license/seat 等) で「starting…」のまま 45 分 hang |
| G4 | 失敗 (Timeout/Error) 時も**過程を出力** | writeback 失敗枝で plan/artifact/verify テーブル+stop 時 progress+生成物パス (spec-impl) / 起案過程 (spec-review) | 失敗時に何が起きたか追えなかった |
| G5 | codex 呼び出しに**壁時計上限** | `iOrchCodex` を `TimeConstrained[..,$iOrchCallTimeLimit=900,"TimedOut"]`。**`RunProcess` の `ProcessTimeLimit` は無効** | 上限無しで codex ハング→driver 無限ブロック |
| G6 | 実装が**空応答**なら fast give-up + 明示理由 | `iImplementHandler` の emptyImpl: Round→MaxRounds、stub 文言記録 | 空応答が "no .wl generated"→3周却下に化け誤誘導 |
| G7 | プランナーは **single-stage 強優先**・skeleton/stub 分割禁止 | `iRealPlan` プロンプト | 過剰分割→stage2 本体を `NotImplementedInStage1` で放置 |
| G8 | 実装は in-scope を **stub で残さない**・組み込みの戻り値型を**ドキュメント確認** | `iRealImplement` プロンプト (例 FinancialData→TimeSeries) | 戻り値型の思い込みで `ListQ` ゲートが TimeSeries を弾きプロット空 |
| G9 | 検証は**レジストリ由来の命名を蒸し返さない** | `iRealVerify`/`iRealPlanReview` プロンプトに期待 ctx 実値+ASCII 要求禁止 | codex が ASCII context を要求し続け収束せず (実装が正しい) |
| G10 | 検証ルールは**モデル非依存のプロンプト**に書く | iRealVerify 等 | codex は使い捨て temp 実行で AGENTS.md/skills を読まない |

---

## 11. 設定ノブ

| 変数 | 既定 | 場所 | 用途 |
|---|---|---|---|
| `$iSpecImplMaxSeconds` | 2700 | claudecode.wl | spec-impl FE backstop (壁時計) |
| `$iOrchConsensusMaxSeconds` | 1500 | claudecode.wl | spec-review FE backstop (壁時計) |
| `$iSpecImplMaxRounds` | 3 | claudecode.wl | implement↔verify 最大ラウンド |
| `$iOrchCallTimeLimit` | 900 | 各 SVWorkflow_*.wl | codex 1 コールの壁時計上限 (driver は config `CallTimeLimitSeconds` で上書き可) |
| `$iDynTest` / `$iDynTestTimeLimit` / `$iWolframScript` | True / 240 / "wolframscript" | SVWorkflow_SpecImpl.wl | 動的ゲート |
| RunSpecImpl `MaxWait` | 2400s | SVWorkflow_SpecImpl.wl | ネット実行ループの上限 |

---

## 12. 既知の限界 / 今後

- **データ経路の不具合** (例 `Launch["plot"]`→`Missing["NoData"]`) は無引数 safe report では出ないため、動的ハードゲートでは捕捉できない。**ネット非依存ユニットテスト** (サンプル TimeSeries を食わせる) を生成テストに書かせ、advisory 経路で LLM に判断させる。
- `MaxWait` はトランジション handler 内の同期 `RunProcess` を中断できない (G5 の per-call 上限で担保)。
- デプロイ済 CLI skills は curated subset で canonical からドリフトしうる (別管理)。

---

## 13. 変更履歴 (本セッションの堅牢化, 2026-06-22〜23)

G1〜G10 を spec-impl に導入、G1〜G5 + G4(起案過程) を spec-review に横展開。canonical 命名の `W` 接頭辞ガードを
3 ミラーに追加。FinancialData→TimeSeries の生成バグを修正し実装プロンプトにドキュメント確認方針を明記。
動的実行ゲート (load+launch ハード / test アドバイザリ) を spec-impl Verify に新設。
