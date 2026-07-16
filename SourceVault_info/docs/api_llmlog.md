# SourceVault_llmlog API リファレンス

パッケージ: `SourceVault`` (コンテキスト: `SourceVault`PrivateLLMLog`` に実装)
ロード: `SourceVault.wl` が自動ロード (mcp の後)。service kernel でも run.wls が mcp の後に load。
仕様書: `ドキュメント/sourcevault_llm_execution_log_ingest_mcp_spec_v0_1.md` (Claude Code セッションログ対象の縦 slice)
役割: 各 PC ローカルの Claude Code 実行ログ (`~/.claude/projects/*/*.jsonl`) をセッション毎のダイジェスト (メタデータ + bounded preview + ツール統計) に抽出し、`<CoreRoot>/rollup/claudecode_sessions/<MachineTag>/YYYY-MM.jsonl` へ append-only で集約する。Dropbox 同期により全マシンで共有され、MCP data adapter "llmlog" (`sourcevault_search kinds=["llmlog"]` / `sourcevault_get sv://record/svcclog-<sessionId>`) から検索・参照できる。生 transcript は同期しない。

**タスク→関数 (重要・混同注意)**: 「Claude Code のログ」「過去のセッション/実装/作業ログ」を探すタスクは **`SourceVaultClaudeCodeSessionSearchView[query]`** (表示) / `SourceVaultClaudeCodeSessionSearch[query]` (データ) を使う。これは **git のコミット履歴ではない** — コミット履歴は `GitHubCommitLog` (github.wl) / MCP `sourcevault_commit_log` の担当。GitHub リポジトリ検索とも無関係。例: 「Claude Codeのログでgithub.wl関連のもの」→ `SourceVaultClaudeCodeSessionSearchView["github.wl"]`。特定マシンに絞るなら `"MachineTag" -> "rapterlake4t"`。

## ingest / rollup (各マシンで実行)

### SourceVaultIngestClaudeCodeLogs[opts]
ローカルセッションログを走査し、新規/更新セッション (watermark の Bytes と現サイズの差分で検出) だけダイジェスト化して自マシンの rollup shard へ追記する。append-only・冪等・非破壊。既定で生 transcript の Dropbox ミラー (`SourceVaultMirrorClaudeCodeLogs`) も相乗り実行する。service heartbeat が起動時 + `$SourceVaultClaudeCodeIngestIntervalSeconds` 間隔で自動実行する。
→ `<|"Status"->"OK"|"DryRun"|"Error", "MachineTag", "Scanned", "Changed", "Ingested", "Skipped", "Deferred", "RollupDir", "PerSession", "Mirror"(SourceVaultMirrorClaudeCodeLogs の結果; MirrorRaw->False なら Missing["Disabled"])|>`
Options: `"DryRun"` -> False, `"MaxSessionsPerRun"` -> Automatic (整数で 1 回の処理数を制限; 残りは Deferred で次回へ), `"MaxAgeDays"` -> 180 (All で全期間), `"MaxFileMB"` -> 200 (超過 transcript は skip), `"ForceRefresh"` -> False (True で watermark を無視し全再 digest — digest スキーマ更新後に各マシンで 1 回実行する), `"MirrorRaw"` -> True (生ログの Dropbox ミラーを同時実行するか)

### SourceVaultClaudeCodeLogStatus[]
ローカル走査対象と rollup 集約状況・生ログミラー状況。
→ `<|"MachineTag", "LocalSessions", "UningestedSessions", "WatermarkedSessions", "RollupByMachine", "RollupTotal", "LogRoots", "RollupDir", "WatermarkPath", "MirrorRoot", "MirrorByMachine"|>`

### SourceVaultClaudeCodeSessionDigest[jsonlPath, opts]
1 セッション transcript からダイジェストを作る (純関数寄り; 保存しない)。ユーザー発話 preview は 400 字 x 最大 12 件 (先頭 8 + 末尾 4)、秘密らしき token (sk-/bearer 等) はマスク、system-reminder は除去。harness (ClaudeEval 等のワンショット呼び出し) の boilerplate プロンプトはタスク本文抽出に置換される。privacy は cwd が MyPackages 下なら 0.4、それ以外は fail-closed 0.75。
→ `<|"ObjectClass"->"ClaudeCodeSessionDigest", "SchemaVersion"->2, "SessionId", "MachineTag", "Project", "SessionKind"->"interactive"|"harness", "Cwd", "GitBranch", "ClientVersion", "StartedAtUTC", "LastAtUTC", "Models", "LineCount", "SkippedLines", "UserMessageCount", "AssistantMessageCount", "ToolCounts", "FilesTouched", "Title", "Summaries", "UserPreviews", "AssistantTail", "EffectivePrivacyLevel", "DigestAtUTC"|>`
Options: `"MachineTag"` -> Automatic (省略時 `SourceVaultMachineTag[]`)

### $SourceVaultClaudeCodeLogRoots
型: List, 既定 `{~/.claude/projects}`。走査 root。存在しない root は無視。

### $SourceVaultClaudeCodeIngestIntervalSeconds
型: 数値, 既定 3600 (1h)。service heartbeat の自動 ingest 最小間隔。

### SourceVaultMachineTag[]
rollup namespace 用の正準 machine tag (`$MachineName` を path-safe 化)。
→ String

## 読み・検索 (全マシン横断)

読み手は全マシンの rollup shard を読み、SessionId 毎に最新 digest へ dedup する (rollup の signature キャッシュ付き)。

### SourceVaultClaudeCodeSessions[opts]
dedup 済みダイジェストのリスト (LastAtUTC 新しい順)。
→ List of Association
Options: `"MachineTag"` -> All | _String, `"Project"` -> All | _String (部分一致), `"Limit"` -> All, `"Kind"` -> All | "interactive" | "harness"

**SessionKind**: `"harness"` = Claude Working の一時 project で走るワンショット自動呼び出し (ClaudeEval コード生成・doc 更新等。実測で全体の 9 割超)、`"interactive"` = 対話セッション。harness のプロンプト boilerplate ("You are an expert ..." / "## Project guidelines ...") は digest 時にタスク本文 (`=== TASK OVERVIEW ===` ブロック / 末尾 `Task:`) へ置換され、Title/preview/検索を汚さない。

### SourceVaultClaudeCodeSessionSearch[query, opts]
トークン単位 OR スコアリング (Title 3 / Summaries・SummaryLLM 2.5 / UserPreviews・FilesTouched 2 / ...) + 決定論 tie-break (Score 降順 → LastAtUTC 降順 → SessionId)。score 0 は返さない。core 版 (Association リスト)。
→ List of Association (各 "Score" 付き)
Options: `"Limit"` -> 20, `"MachineTag"` -> All, `"Project"` -> All, `"Kind"` -> All | "interactive" | "harness"

### SourceVaultClaudeCodeSessionSearchView[query, opts]
上記の Dataset 表示版。列 = Score / Machine / Last / **Kind / Title / 概要** / SessionId。概要は LLM 要約 (キャッシュ) があればそれ、無ければ先頭発話 + "…(要約未生成)"。digest が要約後に伸びていれば "(追記あり・要約は旧版)" を付す。
Options: 検索と同じ (Limit/MachineTag/Project/Kind) + `"Summarize"` -> False (True で表示行の未生成分をその場で LLM 生成; 1 件数秒〜数十秒の同期実行), `"MaxRows"` -> 25

## 生 transcript の Dropbox ミラー + 全文閲覧

生ログ一式は `<CoreRoot の親>/claudecodelogs/<MachineTag>/` (例 `Dropbox/udb/claudecodelogs/`) へ**プレーンなフォルダ**として増分ミラーされる (udb/mails と同格)。SourceVault store の外なので、肥大化したらフォルダごとオフライン化してよく、その場合も digest/要約/検索は無傷で、閲覧が digest フォールバックに切り替わるだけ。マシンごとに自 subtree のみ書くため書き込み衝突なし。**MCP には露出しない** (MCP は privacy ゲート済み digest のみ。ログの privacy ~0.4 なので Z.ai 等 0.25 閾値のモデルは body 不可)。

### SourceVaultMirrorClaudeCodeLogs[opts]
ローカル `~/.claude/projects` 全体 (session jsonl + subagents + tool-results + memory) をサイズ差分で増分コピー (tmp+rename)。`SourceVaultIngestClaudeCodeLogs` が既定で相乗り実行する (`"MirrorRaw"` -> True) ので、service の定期 ingest で常時最新に保たれる。実測: 初回 562 ファイル/347MB ≈ 10 秒、以後は変更分のみ。
→ `<|"Status", "MachineTag", "Scanned", "Copied", "CopiedBytes", "Skipped", "Deferred", "MirrorDir"|>`
Options: `"DryRun"` -> False, `"MaxFilesPerRun"` -> Automatic

### $SourceVaultClaudeCodeRawMirrorRoot
既定 Automatic = `<CoreRoot の親>/claudecodelogs`。文字列で上書き可。

### SourceVaultClaudeCodeSessionTranscript[sessionId, opts]
全文 transcript (core 版)。生ログを **local → mirror (他マシン分) → digest** の順で解決。
→ `<|"SessionId", "Source"->"local"|"mirror"|"digest", "Path", "Turns"->{<|"Role","At","Text","Tools"|>..}|>`
Options: `"IncludeMeta"` -> False (True で system-reminder 等も残す)

### SourceVaultClaudeCodeSessionView[sessionId, opts]
全文の表示版。ヘッダ (Title/マシン/期間/LLM 要約) + user/assistant 対話を Panel 列で整形。
Options: `"MaxTurns"` -> 80, `"MaxCharsPerTurn"` -> 2000

## LLM 要約 (notebook summary と同型)

要約は共有 sidecar `<CoreRoot>/rollup/claudecode_sessions/_summaries/<sessionId>.json` に保存され全マシンで共有。生成は main kernel のみ (service kernel では LLMRouteUnavailable)。

**モデルルーティング**: digest の privacy <= 0.49 (通常のコード作業 = 0.4) は **`$ClaudeDocModel`** (doc 生成用・安価高品質、例 Sonnet) を主経路で直接呼ぶ。失敗時 (オフライン/API 不通) のみ notebook summary と同じ local-first ladder (`iCallSummaryLLMWithFallback`) へフォールバック。privacy > 0.49 のセッションは従来どおり local-first のみ (既定 cloud Deny)。

### SourceVaultClaudeCodeSessionSummary[sessionId, opts]
1 セッションを 2〜3 文に LLM 要約しキャッシュする。Current (保存時 SourceLineCount = 現 LineCount) なら再生成しない。
→ `<|"Status"->"OK"|"Failed", "Summary", "Cached", "GeneratedBy", "GeneratedAtUTC", "GeneratedOn", ...|>`
Options: `"ForceRefresh"` -> False, `"MaxLength"` -> 300, `"Model"` -> Automatic (明示指定で主経路を上書き), `"FallbackToCloud"` -> "Deny" (ladder 内の cloud fallback 可否)

### SourceVaultClaudeCodeSummarizeSessions[opts]
未生成/stale のセッションを新しい順にまとめて要約 (同期)。発話ゼロのセッションは対象外。失敗は PerSession の `Reason` で診断できる。
→ `<|"Requested", "Generated", "Cached", "Failed", "PerSession" (各 <|Status, Reason, Cached, Title|>)|>`
Options: `"Limit"` -> 10, `"Query"` -> None (文字列なら検索ヒットのみ), `"MachineTag"` -> All, `"Kind"` -> "interactive" (既定; harness ワンショットは大量なので除外。含めるなら All) + 上記オプション

読み API (`SourceVaultClaudeCodeSessions` / `SessionSearch` / `SessionGet`) は要約を自動 join し、`"SummaryLLM"` / `"SummaryStale"` を付す。MCP 行の Summary/body にも先頭に載る。

### SourceVaultClaudeCodeSessionGet[sessionId]
sessionId のダイジェスト全体。
→ Association | Missing["NotFound"]

## MCP 露出

### SourceVaultRegisterLLMLogMCPAdapter[]
data adapter "llmlog" を登録 (冪等; 本ファイルロード時に自動試行)。kinds: `llmlog` / `claudecode`。URI は record namespace を間借り: `sv://record/svcclog-<sessionId>` (mail の svmail- と同型; URI namespace table 変更不要)。
- search 行: URI / Title / Summary (LLM 要約があれば先頭 + machine|project|期間|件数) / Snippet (先頭 preview 500 字) / PrivacyLevel / PrivacyClass ("CodeWork" if privacy<=0.4, else "Unclassified") / Metadata (SessionId, SessionKind, MachineTag, Project, GitBranch, StartedAtUTC, LastAtUTC, Models, UserMessageCount, AssistantMessageCount, TopTools, FilesTouched)
- filters: `machineTag`, `project`, `kind` ("interactive" で harness 除外)
- body (digest 全文の整形テキスト) は grant 必須 (`RequireGrantFor` body/raw)。生 transcript は MCP に出さない。

## 運用ノート

- 各マシンの SourceVault service が自動 ingest する (反映には service 再起動が必要 — rule105 §8)。手動なら `SourceVaultIngestClaudeCodeLogs[]` を任意カーネルで実行。
- 初回はバックログが大きいので service は `MaxSessionsPerRun -> 40` で刻む。手動一括なら `SourceVaultIngestClaudeCodeLogs["MaxAgeDays" -> All]`。
- セッションが続くと digest 行が複数追記される (append-only)。読み手が SessionId で最新を採るので重複は無害。shard の prune は未実装 (行は小さく増分も緩やか)。