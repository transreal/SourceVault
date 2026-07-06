# SourceVault_webingest API リファレンス

## 概要
SourceVault_webingest.wl は SearXNG 連携・Web 検索・URL fetch / HTML clean-text 抽出を担う service-loadable な薄層。context は `SourceVault`。main kernel / service kernel の両方から読める (FrontEnd / Notebook / NBAccess / UI に依存しない)。SourceVault.wl 本体を service kernel に読み込まずに Web ingest を行うための分離ファイル (spec v6 §3.1)。root 解決は core の `SourceVaultRoot[...]` / `SourceVaultCoreRoot[]` / content-addressed store (`SourceVaultCommitBlob` / `SourceVaultSaveImmutableSnapshot`) を再利用する。

読み込みは UTF-8 明示: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_webingest.wl"]]`。

設計の要点:
- 不変事実 (url / hash / clean-text ref / provenance) は content-addressed の不変 snapshot に置く。可変メタ (Priority / reference events) は LocalState sidecar に置く (rule105 §3)。
- command / job 二層 (spec v6 §7): 検索は job として submit し、既定で非同期 (SessionSubmit) 実行、poll で結果取得。proxy の短 timeout を長時間 fetch が跨いでもブロックしない。
- 参照イベントは append-only log (LocalState hotlog) に記録し、低頻度バッチで CoreRoot(Dropbox) に rollup してクロスマシン集約・耐久化する。
- Priority は mail の `SourceVaultMailComputePriority` に対応する Web 版。provenance の構造シグナル (ドメイン重み + 検索ランク + スコア + ユーザ明示 + 抽出品質) から LLM なしで決定的に計算する。
- 要約はローカル LLM (LM Studio / OpenAI 互換) を使う。MCP 経路からは自動で呼ばない (再入回避)。

## SearXNG 検索

### SourceVaultSearXNGSearch[query, opts]
SearXNG の JSON API (`<endpoint>/search`) を叩き候補 URL を正規化した Association を返す。
→ Association `<|Provider, Endpoint, Query, Language, ResultCount, TotalAvailable, Results, Suggestions, UnresponsiveEngines, FetchedAt, Status|>` または Failure。
Results は `{<|"Title","Url","Snippet","Engine","Category","Score","Rank","PublishedDate"|>...}`。
Options: "Endpoint" -> Automatic (Automatic 時 `$SourceVaultSearXNGEndpoint`), "MaxResults" -> 10 (0 以下で無制限), "Language" -> "ja", "SafeSearch" -> 1, "TimeoutSeconds" -> 20, "Categories" -> Automatic (String 指定で SearXNG categories), "PageNo" -> Automatic (Integer 指定で pageno)
失敗種別: Failure["SearXNGTimeout"|"SearXNGRequestFailed"|"SearXNGHTTPError"|"SearXNGJSONParseFailed"]

### SourceVaultWebSearch[query, opts]
`SourceVaultSearXNGSearch` の戻りに最小 provenance と RunId を付けた SearchRun Association を返す。既定で WebSearchRun として core に永続化し ReferenceEvent (Searched) を append する (誰がいつ何を検索したか辿れる)。
→ Association (run に `RunId`, `IngestProvenance`, `FetchPages`, `SearchRunRef` を追加) または Failure。
Options: (`SourceVaultSearXNGSearch` の全オプション) に加え "FetchPages" -> False (True の本文取得は job 経路で有効), "MaxFetch" -> 3, "StoreSearchRun" -> True, "RequestChannel" -> "Notebook", "InitiationType" -> "UserPromptSearch", "Actor" -> Automatic (Automatic で `<|"Type"->"HumanUser"|>`), "PromptRef" -> None

### $SourceVaultSearXNGEndpoint
型: String, 初期値: "http://127.0.0.1:8888"
SearXNG の既定エンドポイント。`SourceVaultSearXNGSearch` の "Endpoint" -> Automatic 時に使われる。

## command / job 二層 (spec v6 §7)

### SourceVaultWebSearchSubmit[input] / SourceVaultWebSearchSubmit[query, opts]
WebSearch job を作成する。job state は LocalState/jobs/<jobId>.json に保存。`$SourceVaultWebSearchAsync` (既定 True) なら SessionSubmit で非同期実行し即 Status->"Running" を返す。結果は `SourceVaultWebJobResult[jobId]` で取得 (完了まで Ready->False)。
→ `<|"JobId", "Status", "Async"|>` または Failure["JobCreateFailed"]。
input は Association (`"Query"` 必須、`"Provenance"`、その他 `SourceVaultWebSearch` オプションキー)。query 形式は opts に `SourceVaultWebSearch` のオプションを取る。FetchPages -> True 指定時は上位 MaxFetch 件を `SourceVaultWebFetch` で本文取得し (per-result provenance rank/score/engine/domain を付与) `Documents`/`FetchedPageCount` を結果に付す。

### $SourceVaultWebSearchAsync
型: True|False, 初期値: True
`SourceVaultWebSearchSubmit` を非同期 (SessionSubmit) で実行するか。True なら submit は即 Running を返し呼び出し側を塞がない。False なら inline 実行 (テスト/デバッグ用)。

### SourceVaultWebJobStatus[jobId] → Association
job の状態を返す `<|JobId, Status, JobType, CreatedAt, UpdatedAt, FailureReason|>`。未存在なら Status->"NotFound"。Status は Queued/Running/Succeeded/Failed 等。

### SourceVaultWebJobResult[jobId] → Association
完了 job の結果を返す。Succeeded なら `<|JobId, Status, Ready->True, Result|>`、Failed なら `<|JobId, Status, Ready->True, FailureReason|>`、未完了なら `<|JobId, Status, Ready->False|>`。

### SourceVaultWebJobList[] → List
LocalState 上の全 job レコード (Association) のリストを返す。

### SourceVaultWebRecoverStaleJobs[] → Association
service 起動時に残った Running/Queued job を Failed (StaleJobRecovered:ServiceRestarted) に掃く (spec v6 §7.4)。
→ `<|"Recovered", "Scanned"|>`

## URL fetch / WebDocument

### SourceVaultWebFetch[url, opts]
URL 本文を取得し HTML clean-text 抽出 + ContentHash を行い、WebDocument を core の content-addressed store (CommitBlob + 不変 snapshot) に保存する。非 2xx (401/403/404/5xx) は本文扱いせず ExtractionStatus="FetchFailed" とし、body は監査用に保存する。抽出成功 & snapshot 保存成功時のみ ReferenceEvent (Ingested) を emit。provenance ベース構造 Priority を LocalState sidecar に記録。
→ WebDocument 概要 Association (`Url, CanonicalUrl, StatusCode, ContentType, ByteCount, ContentHash, RawBlobRef, CleanTextRef, CleanTextLength, Title, ExtractionStatus, ExtractionQuality, ExtractionReason, FetchedAt, IngestProvenance, CleanTextPreview, SnapshotRef, SnapshotStatus, Priority, IngestHooks`)。fetch 失敗時は `<|Url, ExtractionStatus->"FetchFailed", Reason, FetchedAt|>` 等の簡略形。
Options: "TimeoutSeconds" -> 30, "StoreEvidence" -> True (不変 snapshot 保存), "Provenance" -> <||>, "RecordGap" -> True (fetch/抽出失敗を EvidenceGap に記録)
ExtractionStatus: Succeeded / Failed / Skipped (PDF 等) / FetchFailed。ExtractionQuality: Good(>=1500字) / Fair(>=200) / Poor(<200)。

### SourceVaultRegisterWebIngestHook[name, f] → Association
`SourceVaultWebFetch` 完了時に呼ぶフック f[ctx] を登録する (取り込み後の著者/タグ抽出を webingest 非依存で結線する拡張点)。ctx=`<|Result, Url|>`。失敗しても fetch を壊さない。→ `<|Status->"Registered", Name|>`

### SourceVaultUnregisterWebIngestHook[name] → Association
登録フックを解除する。→ `<|Status->"Unregistered", Name|>`

### SourceVaultWebIngestHooks[] → List
登録済み web ingest フック名のリストを返す。

### SourceVaultWebSearchRunList[] → List
保存済み WebSearchRun (検索の監査記録 Association) のリストを返す。CoreRoot/snapshots/WebSearchRun から読む。

## 参照イベント / importance (spec v6 §11, §36-38)

### SourceVaultAddReferenceEvent[event] → Association
参照イベントを append-only log (LocalState/hotlog/reference_events/YYYY-MM.jsonl) に追記する。event に `At`/`EventId`/`Weight` を補完。event は `recordId`/`recordClass`/`eventType`/`channel` 等のキーを持つ Association。
→ `<|Status->"Appended", RecordId, Shard|>` または Failure["NoLocalState"|"JSONEncodeFailed"|"AppendFailed"]。

### SourceVaultRefCount[recordId] → Integer
recordId の参照イベント数を返す (local hot ログ ∪ CoreRoot rollup を dedup して算出)。

### SourceVaultRecordImportance[recordId, opts]
参照イベントから recency-aware な重要度を計算する。正本は append-only log、派生値は毎回算出。
→ `<|RecordId, RefCount, FirstReferencedAt, LastReferencedAt, RecentReferenceScore, HistoricalImportance, CurrentImportance|>`
Options: "HalfLifeDays" -> 90, "BasePriority" -> 0.0
CurrentImportance = BasePriority + RecentReferenceScore (時間減衰した重み合計)。

### $SourceVaultRefEventWeights
型: Association, 初期値: `<|Displayed->0.2, Retrieved->0.3, Searched->0.3, Selected->0.5, Ingested->0.5, Summarized->0.7, Exported->0.8, UsedInAnswer->1.0, Cited->1.5, UserPinned->2.0, Deposited->0.1|>`
参照イベント eventType -> 重みの対応 (spec v6 §37)。Deposited は自己申告 SourceRefs 用の低 weight。

## 参照イベント rollup (CoreRoot/Dropbox 集約)

### SourceVaultRollupReferenceEvents[opts]
LocalState の参照イベント hot ログ (machine-local) の未集約分を CoreRoot/rollup/reference_events/<host>/<shard>.jsonl へ追記する。watermark で増分管理し追記のみ (非破壊)。低頻度バッチで呼ぶ前提。
→ `<|Status, Host, Shards, NewEvents, RolledShards, PerShard, RollupDir|>`
Options: "DryRun" -> False

### SourceVaultReferenceEventStoreStatus[] → Association
参照イベントストアの可観測性情報を返す。
→ `<|LocalShards, LocalTotal, UnrolledEvents, RollupByHost, RollupTotal, Host, Watermark, LocalDir, RollupDir|>`

### SourceVaultPruneRolledReferenceEvents[opts]
CoreRoot rollup に集約済みの古い local shard を削除して hot ログの肥大を抑える。rollup に同数以上のイベントが在ることを確認した shard のみ削除 (importance は rollup から読めるため欠損しない)。破壊的なので既定 DryRun (rule103)。
→ `<|Status, Host, PrunedCount, Pruned, Kept|>`
Options: "DryRun" -> True, "KeepMonths" -> 2 (最新分は残す)

### $SourceVaultRollupIntervalSeconds
型: Number(秒), 初期値: 21600 (6h)
service heartbeat ループが `SourceVaultRollupReferenceEvents` を自動実行する最小間隔。低頻度に保ちバッテリーノートの Dropbox 同期負荷を抑える。反映には service 再起動が必要 (rule105 §8)。

## 構造 Priority (provenance ベース)

### SourceVaultWebComputePriority[prov] / SourceVaultWebComputePriority[prov, doc]
WebDocument の構造的重要度 0.0-1.0 を決定的に計算する (mail 版に対応、LLM 不要)。シグナル: ソースドメイン重み + 検索ランク + SearXNG スコア + ユーザ明示 URL + 抽出品質。
→ `<|"Priority", "Components"|>`
Priority = Clip[DomainWeight + RankAdj + ScoreAdj + DirectAdj + QualAdj, {0,1}]。RankAdj は上位ほど指数減衰加点 (最大 0.20)、ScoreAdj は SearXNG スコアを 0-5 にクリップし最大 0.10 加点、DirectAdj は UserSpecifiedUrl で +0.15、QualAdj は Good +0.05 / Poor -0.10 / FetchFailed·Failed -0.20。

### SourceVaultWebPriority[recordId] → Association
recordId (snapshot Ref) の保存済み構造 Priority sidecar を返す (LocalState/derived/web_priority)。
→ `<|RecordId, Priority, Components, Url, ComputedAt|>` または Missing["NoPriority"|"NoLocalState"]。

### SourceVaultWebImportance[recordId, opts]
構造 Priority (provenance 初期推定) と使用ベース CurrentImportance (参照イベント) を統合して返す。
→ `<|RecordId, Priority, PriorityComponents, RefCount, RecentReferenceScore, CurrentImportance, LastReferencedAt, CombinedScore|>`
Options: "PriorityWeight" -> 0.5, "HalfLifeDays" -> 90
CombinedScore = PriorityWeight*Priority + (1-PriorityWeight)*Clip[CurrentImportance]。

### SourceVaultWebRecomputePriorities[opts]
保存済み WebDocument snapshot の IngestProvenance と現行ドメイン重みから構造 Priority を LLM なしで再計算し sidecar を更新する (優先度式・ドメイン重みの変更を既取込レコードへ反映)。recordId は `"snapshot:WebDocument:<basename>"`。
→ `<|Status, Scanned, Updated, Failed, SnapshotFiles|>`
Options: "Limit" -> Automatic (全件)

## ドメイン重み registry

### SourceVaultSetWebDomainWeight[domain, weight, opts]
ソースドメインの重み (0.0-1.0) を登録し vault config (PrivateVault/config/web_domain_weights.json) に保存する。"www." は無視、サブドメインは親ドメイン重みを継承する。weight は Clip[_, {0,1}] で丸める。
→ `<|Status, Domain, Weight|>` (空ドメインは `<|Status->"Error", Reason->"EmptyDomain"|>`)
Options: "Persist" -> True

### SourceVaultWebDomainWeights[] → Association
登録済みドメイン重みの Association を返す (未ロードなら自動ロード)。

### SourceVaultWebDomainWeightFor[domain] → Real
ドメイン (またはサブドメイン) に適用される重みを返す。完全一致 → 親ドメイン継承の順で解決し、未登録なら既定値 0.4 を返す。

### SourceVaultWebDomainWeightsLoad[] → Association
ドメイン重み config を再読み込みする。→ `<|Status, Count|>`

## highlights / 要約

### SourceVaultWebHighlights[text, query, opts]
text からクエリ関連の文を抽出して返す (LLM 不要、TextSentences 文分割 × クエリ語重なりスコア)。
→ `<|"Query", "Highlights" -> {文...}, "Count"|>`
Options: "MaxHighlights" -> 5, "MinChars" -> 20

### SourceVaultSummarizeText[text, opts]
ローカル LLM (LM Studio) で text を要約する。MCP 経路からは自動で呼ばない (再入回避)。
→ `<|"Summary", "Model", "Status"|>` (Persist 時 "ArtifactRef" 付き) または Failure。
Options: "Instruction", "MaxTokens", "Temperature", "Endpoint" -> `$SourceVaultSummaryEndpoint`, "Model" -> `$SourceVaultSummaryModel`, "TimeoutSeconds", "Persist" -> False (True で Succeeded 時のみ DerivedArtifact 不変 snapshot 保存; 空/失敗は保存しない), "SourceRefs", "SourceUrls", "Query", "Provenance"

### SourceVaultSummarizeResults[run, query]
検索結果 (run の Results: title/url/snippet) をローカル LLM で要約する。run は `SourceVaultWebSearch` の戻り値または Results リスト。Persist -> True なら SearchRunRef / Documents の SnapshotRef / 結果 URL を SourceRefs/SourceUrls として自動付与し DerivedArtifact を保存する。
→ `SourceVaultSummarizeText` と同形の Association。

### SourceVaultSaveDerivedArtifact[artifact] → Association
派生成果物 (要約等) を ObjectClass "DerivedArtifact" の不変 snapshot として content-addressed store に保存する。artifact は `<|"ArtifactType", "Text"|>` 必須、`"SourceRefs"`/`"SourceUrls"`/`"Query"`/`"Model"`/`"Provenance"` 任意。ArtifactType=Summary 時 SourceRefs の各レコードに "Summarized" 参照イベントを emit し importance に反映する。
→ `<|Status, Ref, ArtifactId, ...|>`

### SourceVaultDerivedArtifact[ref] → Association
DerivedArtifact snapshot を ref から読み出す (薄い load ラッパー)。

### SourceVaultDerivedArtifactList[opts] → List
保存済み DerivedArtifact の一覧 (各 assoc に "Ref" を付与) を返す。
Options: "ArtifactType" -> All (種別で絞る)

### SourceVaultDerivedArtifactsForSource[recordId] → List
SourceRefs に recordId を含む DerivedArtifact を返す (「この source から作られた要約は?」の逆引き)。

### $SourceVaultSummaryEndpoint
型: String, 初期値: "http://localhost:1234/v1/chat/completions"
要約に使う LLM の chat completions エンドポイント (LM Studio OpenAI 互換)。

### $SourceVaultSummaryModel
型: String|Automatic, 初期値: Automatic
要約に使うモデル id。Automatic なら /v1/models から解決する (モデル名をハードコードしない, rule 02)。

### $SourceVaultSummaryToken
型: String|Automatic, 初期値: Automatic
LM Studio API token。Automatic なら `ClaudeCode`$ClaudeLMStudioAPIToken` / NBAccess / LocalState/secrets から解決する (ハードコードしない, rule 20)。

### SourceVaultStoreSummaryToken[opts] → Association
main kernel で解決した LM Studio token を LocalState/secrets/sourcevault-summary-token.json (非 Dropbox) に保存する。これにより service kernel (NBAccess 不在) でも要約用 token を解決できる (spec v6 §13.6)。戻り値に token 文字列は含めない (rule 20)。
Options: "Token" -> 明示指定

## backend 切替 (exa ⇄ SearXNG フォールバック)

### SourceVaultSearXNGAvailableQ[opts] → True|False
SearXNG (`$SourceVaultSearXNGEndpoint`) が到達可能かを返す (結果は既定 60 秒キャッシュ)。
Options: "CacheSeconds", "TimeoutSeconds"

### SourceVaultSwapWebSearchBackend[integrations] → List
integrations 中の web 検索 backend を SearXNG 可用時は SourceVault MCP に、不可時は exa にそろえる (後方互換)。string ID と `<|"id"->...|>` 形式の両方に対応。web 検索以外の要素は不変。

### SourceVaultWebSearchIntegration[] → List
現在使うべき web 検索 integration リストを返す。SearXNG 可用なら `{$SourceVaultWebSearchIntegrationId}`、不可なら `{$SourceVaultExaFallbackIntegrationId}`。
例: `ClaudeCode`$ClaudeLMStudioIntegrations := SourceVaultWebSearchIntegration[]` で全 ClaudeEval に適用。

### $SourceVaultWebSearchIntegrationId
型: String, 初期値: "mcp/sourcevault"
SearXNG 可用時に使う LM Studio integration ID。

### $SourceVaultExaFallbackIntegrationId
型: String, 初期値: "mcp/exa"
SearXNG 不可時の後方互換 integration ID。