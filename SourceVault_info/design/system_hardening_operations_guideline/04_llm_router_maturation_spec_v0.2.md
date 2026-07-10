# LLM Router 成熟化 実装仕様案 v0.2 — preflight / ティア表 / 会計 / 履歴圧縮

> **✅ 実装完了（2026-07-09）**。実物: `claudecode.wl`。Inc1（`ClaudeBackendAvailableQ` preflight + `$ClaudeLMStudioBaseURL` + 未ロードは 0.2s で即エラー）/ Inc2（`$ClaudeLLMTierTable` + TaskClass 属性 + query 系 `"TaskClass"` 配線 + 未ロード Automatic を実モデル名に具体化）/ Inc3（escalate 1 回 + validator 純関数契約 + securityjudge 非昇格）/ Inc4（`LLMCall` emit + `ClaudeUsageReport`、CLI/API/LM Studio の usage 抽出）/ Inc5（`$ClaudeSpendLimit` 執行 + `SpendLimitHit`）/ Inc6=P1-3（`$ClaudeAutoCompactThresholdTokens` + `ConversationCompacted` emit）。LM Studio ライブ E2E green。**重要バグ修正: tier の {"lmstudio", Automatic} が既定モデル(CLI)へ静かに転落していた**。詳細は auto-memory 参照。

目的: クラウド・ローカル LLM を「宣言的なティア表 + 呼び出し前 preflight + 使用量会計」で統合し、ローカルの 20 分タイムアウト待ち・履歴無制限成長・コスト不可視を解消する。

指針対応: P1-2（LM Studio preflight）、P1-3（ConversationState 成長）、P1-6（fallback バックオフ）、P2-1（会計）、P2-2（ティアリング）。

変更履歴:
- v0.2: レビュー r1 反映。**(P2-1)** TaskClass 語彙を未解決事項から v0.2 固定表に昇格し、class ごとに AllowEscalation / RequiresValidator / MaxCostClass / DefaultTimeout を定義（§2.1）。validator 契約を「純関数、contracts schema は promptrouter 側でコンパイルして渡す」と確定（§4.1）— Inc 3 の前提条件に。securityjudge を独立 class 化し escalation 禁止を明記。

## 1. 全体像

```
呼び出し元（ClaudeEval / mining / mailsuggest / autotrigger / orchestrator）
  │  TaskClass を申告（省略時 "general"）
  ▼
ティア解決（$ClaudeLLMTierTable: TaskClass → backend 候補列）
  ▼
preflight（ClaudeBackendAvailableQ: 候補を上から検査、落ちたら次へ）
  ▼
予算ゲート（$ClaudeSpendLimit 超過 → cloud 有償候補を除外）
  ▼
実行（既存の iClaudeQuery* / iQueryLMStudioChat / AwaitingLLM）
  ▼
会計記録（usage → 05 SIEM: LLMCall イベント）＋ 失敗時 escalate（TaskClass が許す場合のみ 1 回）
```

既存の provider fallback 連鎖（claudecode → anthropic → openai → lmstudio、監査時点 claudecode.wl:2929-2939）と `$ClaudeFallbackModels` は残し、ティア解決はその**上流**に置く（後方互換: TaskClass 未申告 + ティア表未設定なら従来動作と完全一致）。

## 2. ティア表

```wolfram
$ClaudeLLMTierTable = <|
  (* TaskClass -> 優先順の backend 候補（既存 model tuple 形式を踏襲） *)
  "extract"       -> {{"lmstudio", Automatic}, {"claudecode", "haiku"}},
  "classify"      -> {{"lmstudio", Automatic}, {"claudecode", "haiku"}},
  "summarize"     -> {{"lmstudio", Automatic}, {"claudecode", "sonnet"}},
  "securityjudge" -> {{"lmstudio", Automatic}},                          (* escalation 禁止 §2.1 *)
  "mailtriage"    -> {{"lmstudio", Automatic}, {"claudecode", "sonnet"}},
  "code"          -> {{"claudecode", "opus"}, {"anthropic", "claude-opus-4-8"}},
  "design"        -> {{"claudecode", "opus"}},
  "general"       -> Automatic  (* 従来経路そのまま *)
|>;
```

- `{"lmstudio", Automatic}` はロード済みモデルから解決（`/api/v0/models` の `state`。/api/v1 には state が無い — 既知知見）。
- 配置: 表と解決関数は `claudecode.wl`（SourceVault 非依存）。SourceVault_promptrouter.wl は自分の呼び出しに TaskClass を付けるだけ。
- `ClaudeEval` 系に `"TaskClass"` オプションを追加。orchestrator の AwaitingLLM ジョブ spec にも同名キーを追加。

### 2.1 TaskClass 属性表（v0.2 固定・P2-1）

| TaskClass | 用途（呼び出し元） | AllowEscalation | RequiresValidator | MaxCostClass | DefaultTimeout(s) |
|---|---|---|---|---|---|
| extract | mining 情報抽出 | True | **True**（JSON schema） | cheap | 120 |
| classify | mining 分類 / identity tag | True | True（ラベル集合） | cheap | 60 |
| summarize | mail/web 要約, compaction | True | False | cheap | 180 |
| securityjudge | mining rev6 isolated judge | **False**（隔離判定を経路変更で汚さない。tool-less/local 固定） | True（verdict schema） | local-only | 120 |
| mailtriage | mailsuggest / autotrigger の要対応判定 | True | True（判定 schema） | cheap | 120 |
| code | コード生成・修正 | —（最初から cloud） | False | premium | 1200 |
| design | 設計・レビュー | — | False | premium | 1200 |
| general | 未申告・対話 | False（従来 fallback 連鎖に委譲） | False | premium | $ClaudeTimeout |

- `MaxCostClass`: `local-only < cheap < premium`。予算ゲートとの合成: SpendLimit 超過時は premium class のタスクも cheap/local 候補までに制限。
- `DefaultTimeout`: backend HTTP timeout の既定（呼び出し側で明示指定があれば優先）。ローカル 20 分待ちの根絶は preflight（§3）とこの短い既定の двух段構え。
- **新しい TaskClass の追加はこの表への追記が先**（05 のイベントクラス追加規約と同じ運用）。呼び出し元が未知の class を申告した場合は "general" 扱い + warn emit。

## 3. preflight（ClaudeBackendAvailableQ）

```wolfram
ClaudeBackendAvailableQ[{"lmstudio", model_, url_:"$auto"}] :=
  (* GET <base>/api/v0/models, timeout 3s, 結果 60s キャッシュ *)
  (* → <|"Available"->True|False, "Reason"->"NotRunning"|"ModelNotLoaded"|"OK", "LoadedModels"->{...}|> *)

ClaudeBackendAvailableQ[{"claudecode", _}] :=
  (* ClaudeRateLimitStatus[] が Exhausted でない + CLI 存在（既存 PATH probe 結果を再利用） *)

ClaudeBackendAvailableQ[{"anthropic"|"openai", _}] :=
  (* API key 解決可能か（NBAccess 経由、値は読むだけで保持しない） *)
```

規約:
- **unavailable な backend へは POST しない**（「未ロードで 20 分 timeout」の根絶）。
- preflight 失敗は `PreflightFailed` を emit（Backend / Reason / TaskClass）。
- LM Studio base URL: per-model tuple の URL 指定（既存形式）を最優先、無ければ新設 `$ClaudeLMStudioBaseURL`（既定 "http://127.0.0.1:1234"）。リテラル散在（監査時点 304, 518, 1389-1390, 6929-6939）をこの変数参照に置換。
- キャッシュ 60s は `"Refresh"->True` で無効化可（パレット ↻ ボタンと共用）。

## 4. escalate（失敗時の 1 回昇格）

**§2.1 の `AllowEscalation` が True の class のみ**、応答が次のいずれかのとき同 class の次候補（通常 cloud-cheap）で 1 回だけ再実行:
1. 出力 validator 検証失敗（§4.1）
2. 同一署名ループ検出（既存 iResponseSignature 機構の発火）
3. preflight は通ったが HTTP エラー / timeout

- 昇格は `LLMEscalated` を emit（From / To / Reason / TaskClass）。**昇格の連鎖は禁止**（最大 1 段）。
- `securityjudge` は昇格しない: 隔離判定（tool-less / local / data-boundary）の実行環境を失敗時に変えることは、判定の前提（外部テキストを cloud に送らない・経路を固定して比較可能にする）を崩すため。失敗は Failure として quarantine 側に倒す。
- 既存の MaxContinuations=2（lmstudio/qwen 系）は維持。escalate は continuation と独立のカウンタ。
- fallback 試行間バックオフ（P1-6）: `iStartFallbackAsync`（監査時点 10203-10398）の候補間に 1s→2s→4s。async 文脈で Pause 禁止のため、**tick 経由の遅延再試行**（nextAttemptAt を見て発火）で実装。

### 4.1 validator 契約（v0.2 確定・P2-1）

- **ルータが受け取る validator は純関数 1 種類に固定**: `validator[responseString] → True | Failure[tag, <|"Reason"->...|>]`。
- claudecode core はこの Function 契約だけを知る（SourceVault 非依存を維持）。
- contracts 層の schema 資産（SourceVault_contracts の Validate/Normalize）を使いたい呼び出し元（mining / promptrouter）は、**自側で schema → 純関数にコンパイルして渡す**（`SourceVaultContractsCompileValidator[schema]` を promptrouter に追加）。ルータに schema 形式を教えない。
- `RequiresValidator->True` の class で validator が渡されなかった場合: 実行は許すが warn emit（移行期）。Inc 3 完了後は Failure に強化するかを実測で判断。
- **本契約の確定は Inc 3（escalate）の前提**。Inc 2 の TaskClass 配線時点から option として受け付ける。

## 5. 会計（usage / spend）

### 5.1 記録

- cloud（claudecode CLI）: stream-json の result 行から usage（input/output tokens、あれば costUSD）を抽出。既存 parser（iExtractResultFromStreamJson 周辺）に usage 取り出しを追加。
- anthropic/openai API: レスポンス JSON の usage フィールド。lmstudio: tokens が返れば記録、cost は 0。
- 各呼び出しで `LLMCall` を emit（05 経由: Provider, Model, TaskClass, InTokens, OutTokens, CostUSD, DurationMs, Outcome）。**記録フックは ClaudeRunTurn 層**（LLM 記録の層境界方針: claudecode レガシー経路は自前 emit、ClaudeRuntime 経由は RunTurn で普遍化）。

### 5.2 集計と上限

```wolfram
ClaudeUsageReport[]            → 当日/当月の provider×TaskClass 集計 Dataset
ClaudeUsageReport["Days"->7]   → 期間指定
$ClaudeSpendLimit = <|"DailyUSD" -> 5.0|>   (* 既定 None = 無効 *)
```

- 集計ソース: 正準 diagnostics-log + 自マシン未 ingest spool の LLMCall（05 §5.1 と同じ読み方。クロスマシンは既存 rollup 経由）。
- 執行点: ティア解決の直後。当日 CostUSD 合計が DailyUSD 超過 → **cloud 有償候補（anthropic/openai）を除外**（claudecode CLI 定額と lmstudio は除外しない）。全滅なら `Failure["SpendLimitExceeded", <|"Deferred"->True|>]` + `SpendLimitHit` emit。
- kill-switch であって精密会計ではない（コスト欠損は tokens×概算単価で見積り `"Estimated"->True` を付す）。

## 6. ConversationState 自動圧縮（P1-3）

- 既存 `ClaudeCompactHistory`（手動）を自動化:
```wolfram
$ClaudeAutoCompactThresholdTokens = 60000;   (* 概算: StringLength/3.5 *)
```
- 発火点: ターン終了時（RunTurn の後処理）に Messages の概算 token を測り、閾値超過なら **次ターン開始前に**圧縮（tick 内では行わない — LLM 呼び出しを伴うため rule 95 に抵触）。
- 圧縮方式: 直近 N ターン（既定 6）は原文保持、古い部分を「要約 1 メッセージ + 重要 tool 結果の抜粋」に置換（要約は TaskClass="summarize" → ローカル優先でコスト 0 に）。
- `ConversationCompacted` を emit（Before/After tokens）。

## 7. 増分実装計画

- **Inc 1**: preflight（lmstudio /api/v0/models + claudecode rate-limit + key 存在）+ URL 変数化 + PreflightFailed emit。wolframscript: LM Studio 停止状態で `ClaudeBackendAvailableQ` が 3s 以内に False / POST 不発。
- **Inc 2**: ティア表 + TaskClass 属性表 + `"TaskClass"`/`"Validator"` オプション（ClaudeEval / promptrouter 呼び出し元 3 箇所）+ 未知 class の general 降格 warn。後方互換テスト: TaskClass 無しで従来経路と同一挙動。
- **Inc 3**: escalate（AllowEscalation 準拠 + validator 契約 + securityjudge 非昇格）+ fallback バックオフ（tick 遅延方式）。**前提: §4.1 契約 + promptrouter 側 CompileValidator が Inc 2 で入っていること**。
- **Inc 4**: usage 抽出 + LLMCall emit + ClaudeUsageReport（05 Inc 6 と同時）。
- **Inc 5**: $ClaudeSpendLimit 執行 + SpendLimitHit。
- **Inc 6**: 自動 compaction。**NB 検証必須**（実会話で圧縮後に文脈が壊れないこと）。

## 8. 検証レシピ

```wolfram
Get["claudecode.wl"];
(* Inc1: LM Studio を止めた状態で *)
AbsoluteTiming[ClaudeBackendAvailableQ[{"lmstudio", "qwen3.6-27b"}]]
  (* → {<3s, <|"Available"->False, "Reason"->"NotRunning"|>} *)

(* Inc2: ティア解決と属性 *)
iClaudeResolveTier["extract"]        (* lmstudio ロード済みなら local が先頭 *)
iClaudeTaskClassAttrs["securityjudge"]  (* AllowEscalation->False *)
iClaudeResolveTier["未知クラス"]      (* → general 降格 + warn が spool に *)

(* Inc3: escalate。lmstudio に validator 必ず失敗の関数を渡す *)
ClaudeEval["...", "TaskClass"->"extract", "Validator"->(Failure["schema", <||>] &)]
(* → cloud-cheap へ 1 回昇格、LLMEscalated が記録され、2 段目昇格は起きない *)
(* securityjudge で同じことをする → 昇格せず Failure *)

(* Inc4 以降 *)
ClaudeUsageReport[]
$ClaudeSpendLimit = <|"DailyUSD" -> 0.001|>;
ClaudeEval["...", "TaskClass"->"code"]  (* anthropic 除外、SpendLimitHit が log に *)
```

## 9. 未解決事項

- 概算 token 係数（日本語混在で /3.5 は粗い。実測でフィット）。
- `RequiresValidator` 違反を warn から Failure に強化する時期（Inc 3 後の運用実測で判断）。
- 定額 CLI（claudecode）の「コスト」表示（0 表示 or 参考値）。
- mailtriage と mailsuggest 既存実装の突き合わせ（既存呼び出しがどの class に落ちるかの棚卸しは Inc 2 で実施）。
