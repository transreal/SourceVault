# SourceVault_webingest API リファレンス

パッケージ: `SourceVault_webingest` ([GitHub](https://github.com/transreal/SourceVault_webingest))
依存: [SourceVault_core](https://github.com/transreal/SourceVault_core) の `SourceVaultRoot`, `SourceVaultCoreRoot`, `SourceVaultCommitBlob`, `SourceVaultSaveImmutableSnapshot`
名前空間: `SourceVault``
ロード: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_webingest.wl"]]`

## 設定変数

### $SourceVaultSearXNGEndpoint
型: String, 初期値: `"http://127.0.0.1:8888"`
SearXNG の既定エンドポイント。`SourceVaultSearXNGSearch` の `"Endpoint" -> Automatic` 時に参照される。既存値がある場合は上書きしない。

### $SourceVaultWebSearchAsync
型: Boolean, 初期値: `True`
`SourceVaultWebSearchSubmit` を非同期 (`SessionSubmit`) で実行するか。`False` なら inline 実行 (テスト用)。

### $SourceVaultRollupIntervalSeconds
型: Number, 初期値: `21600` (6h)
service heartbeat ループが `SourceVaultRollupReferenceEvents` を自動実行する最小間隔 (秒)。変更反映には service 再起動が必要。

### $SourceVaultRefEventWeights
型: Association, 初期値: `<|"Displayed"->0.2, "Retrieved"->0.3, "Searched"->0.3, "Selected"->0.5, "Ingested"->0.5, "Summarized"->0.7, "Exported"->0.8, "UsedInAnswer"->1.0, "Cited"->1.5, "UserPinned"->2.0|>`
参照イベント eventType → 重みの対応。`SourceVaultRecordImportance` の重み付き集計に使う。

### $SourceVaultSummaryEndpoint
型: String, 初期値: `"http://localhost:1234/v1/chat/completions"`
要約用 LLM (LM Studio OpenAI 互換) の chat completions エンドポイント。

### $SourceVaultSummaryModel
型: String | Automatic, 初期値: `Automatic`
要約用モデル ID。`Automatic` なら `/v1/models` から動的解決する (モデル名をハードコードしない)。

### $SourceVaultSummaryToken
型: String | Automatic, 初期値: `Automatic`
LM Studio API token。`Automatic` なら `ClaudeCode``$ClaudeLMStudioAPIToken` / NBAccess / `LocalState/secrets/sourcevault-summary-token.json` の順で解決する。

### $SourceVaultWebSearchIntegrationId
型: String, 初期値: `"mcp/sourcevault"`
SearXNG 可用時に使う LM Studio integration ID。

### $SourceVaultExaFallbackIntegrationId
型: String, 初期値: `"mcp/exa"`
SearXNG 不可時の後方互換 fallback integration ID。

## SearXNG 検索

### SourceVaultSearXNGSearch[query, opts]
SearXNG JSON API を叩き候補 URL を正規化した Association を返す。
→ `<|"Provider", "Endpoint", "Query", "Language", "ResultCount", "TotalAvailable", "Results", "Suggestions", "UnresponsiveEngines", "FetchedAt", "Status"|>` または `Failure`
Results の各要素: `<|"Title", "Url", "Snippet", "Engine", "Category", "Score", "Rank", "PublishedDate"|>`
Options: `"Endpoint" -> Automatic` (既定は `$SourceVaultSearXNGEndpoint`), `"MaxResults" -> 10`, `"Language" -> "ja"`, `"SafeSearch" -> 1` (0=off/1=mod/2=strict), `"TimeoutSeconds" -> 20`, `"Categories" -> Automatic` (SearXNG カテゴリ文字列), `"PageNo" -> Automatic`
失敗時: `Failure["SearXNGTimeout"|"SearXNGRequestFailed"|"SearXNGHTTPError"|"SearXNGJSONParseFailed", ...]`

### SourceVaultWebSearch[query, opts]
`SourceVaultSearXNGSearch` に最小 provenance と RunId を付けた SearchRun Association を返す。検索の監査記録 (WebSearchRun) を core に永続化し参照イベント (Searched) も append する。
→ SearXNGSearch の戻り値に `<|"RunId", "IngestProvenance", "FetchPages", "SearchRunRef"|>` を追加した Association または `Failure`
Options: `SourceVaultSearXNGSearch` の全オプションに加え、`"FetchPages" -> False` (True なら上位 MaxFetch 件を `SourceVaultWebFetch` で取得), `"MaxFetch" -> 3`, `"StoreSearchRun" -> True` (WebSearchRun 永続化), `"RequestChannel" -> "Notebook"`, `"InitiationType" -> "UserPromptSearch"`, `"Actor" -> Automatic` (`<|"Type"->"HumanUser"|>` に解決), `"PromptRef" -> None`
例: `SourceVaultWebSearch["Wolfram Language tutorial", "FetchPages" -> True, "MaxFetch" -> 5]`

## ジョブ管理 (非同期二層)

### SourceVaultWebSearchSubmit[input]
### SourceVaultWebSearchSubmit[query, opts]
WebSearch job を作成し `$SourceVaultWebSearchAsync` に従い実行する。job 状態は `LocalState/jobs/<jobId>.json` に保存。
→ `<|"JobId", "Status" -> "Running"|"Unknown", "Async" -> True|False|>` または `Failure["JobCreateFailed", ...]`
`$SourceVaultWebSearchAsync = True` (既定) なら `SessionSubmit` で非同期実行し即 `Status -> "Running"` を返す。結果は `SourceVaultWebJobResult[jobId]` でポーリング取得する。
Association 形式の input は `"Query"`, `"Provenance"`, `SourceVaultWebSearch` の任意オプションを含める。

### SourceVaultWebJobStatus[jobId] → Association
job の状態 Association を返す。
→ `<|"JobId", "Status" -> "Queued"|"Running"|"Succeeded"|"Failed"|"NotFound", "JobType", "CreatedAt", "UpdatedAt", "FailureReason"|>`

### SourceVaultWebJobResult[jobId] → Association
完了 job の結果を返す。`"Ready" -> False` なら未完了。
→ Succeeded: `<|"JobId", "Status"->"Succeeded", "Ready"->True, "Result"->...|>`
→ Failed: `<|"JobId", "Status"->"Failed", "Ready"->True, "FailureReason"->...|>`
→ その他: `<|"JobId", "Status"->st, "Ready"->False|>`

### SourceVaultWebJobList[] → List
`LocalState/jobs/` 上の全 job レコード Association のリストを返す。

### SourceVaultWebRecoverStaleJobs[] → Association
service 起動時に残った `Running`/`Queued` 状態の job を `Failed` (`StaleJobRecovered:ServiceRestarted`) に更新する。
→ `<|"Recovered" -> n, "Scanned" -> total|>`

## URL フェッチ / WebDocument

### SourceVaultWebFetch[url, opts]
URL 本文を取得し HTML clean-text 抽出 + ContentHash を行い、WebDocument を content-addressed store (不変 snapshot) に保存する。`ExtractionStatus = "Succeeded"` かつ snapshot 保存成功時のみ `Ingested` 参照イベントを append し、Priority sidecar を `LocalState/derived/web_priority/<recordId>.json` に書く。非 2xx は `FetchFailed` として EvidenceGap に記録し snapshot を作成しない。
→ `<|"ObjectClass"->"WebDocument", "Url", "CanonicalUrl", "StatusCode", "ContentType", "ByteCount", "ContentHash", "RawBlobRef", "CleanTextRef", "CleanTextLength", "Title", "ExtractionStatus", "ExtractionQuality", "ExtractionReason", "FetchedAt", "IngestProvenance", "CleanTextPreview", "SnapshotRef", "SnapshotStatus", "Priority"|>`
Options: `"TimeoutSeconds" -> 30`, `"StoreEvidence" -> True` (False なら snapshot を作成しない), `"Provenance" -> <||>` (IngestProvenance として埋め込む Association), `"RecordGap" -> True` (失敗時 EvidenceGap 記録)
`ExtractionStatus` 値: `"Succeeded"` / `"Failed"` / `"FetchFailed"` / `"Skipped"` (PDF 等)
`ExtractionQuality` 値: `"Good"` (≥1500 chars) / `"Fair"` (≥200) / `"Poor"` (<200)

### SourceVaultWebSearchRunList[] → List
CoreRoot の `snapshots/WebSearchRun/` から保存済み WebSearchRun レコード一覧を返す。

## 参照イベントログ

### SourceVaultAddReferenceEvent[event] → Association
参照イベントを `LocalState/hotlog/reference_events/YYYY-MM.jsonl` に追記する (append-only)。`EventId` (UUID 12文字) と `Weight -> 1.0` を自動付与し dedup キーとして使う。
→ `<|"Status"->"Appended", "RecordId", "Shard"|>` または `Failure`
event は `<|"recordId"->..., "recordClass"->..., "eventType"->..., "channel"->...|>` の形式。eventType は `$SourceVaultRefEventWeights` のキーが有効。

### SourceVaultRefCount[recordId] → Integer
recordId の参照イベント数をローカルホットログ ∪ CoreRoot rollup から算出して返す。

### SourceVaultRecordImportance[recordId, opts]
参照イベントから recency-aware な重要度を計算する。ローカルホットログ ∪ CoreRoot rollup (全 host) を読み EventId で dedup する。
→ `<|"RecordId", "RefCount", "FirstReferencedAt", "LastReferencedAt", "RecentReferenceScore", "HistoricalImportance", "CurrentImportance"|>`
Options: `"HalfLifeDays" -> 90` (指数減衰の半減期), `"BasePriority" -> 0.0` (CurrentImportance に加算)

## 参照イベント Rollup / 集約

### SourceVaultRollupReferenceEvents[opts]
LocalState の hot ログ未集約分を `CoreRoot/rollup/reference_events/<host>/<shard>.jsonl` へ追記する。watermark で増分管理し追記のみ (非破壊)。低頻度バッチで呼ぶ前提。
→ `<|"Status"->"OK"|"DryRun"|"NoLocalEvents"|"Error", "Host", "Shards", "NewEvents", "RolledShards", "PerShard", "RollupDir"|>`
Options: `"DryRun" -> False`

### SourceVaultReferenceEventStoreStatus[] → Association
参照イベントストアの可観測性情報を返す。
→ `<|"LocalShards", "LocalTotal", "UnrolledEvents", "RollupByHost", "RollupTotal", "Host", "Watermark", "LocalDir", "RollupDir"|>`

### SourceVaultPruneRolledReferenceEvents[opts]
CoreRoot rollup に集約済みの古い local shard を削除して hot ログの肥大を抑える。rollup に同数以上のイベントが存在することを確認した shard のみ削除する。破壊的操作のため既定 `DryRun -> True`。
→ `<|"Status"->"DryRun"|"OK"|"NoLocalEvents", "Host", "PrunedCount", "Pruned", "Kept"|>`
Options: `"DryRun" -> True`, `"KeepMonths" -> 2` (最新 N ヶ月分は削除対象外)

## 構造 Priority / 重要度

### SourceVaultWebComputePriority[provenance] → Association
### SourceVaultWebComputePriority[provenance, doc] → Association
WebDocument の構造的重要度 0.0–1.0 を決定的に計算する (LLM 不要)。シグナル: ドメイン重み + 検索ランク (指数減衰 `0.20 * 2^(-(rank-1)/4)`) + SearXNG スコア (0.10) + ユーザ明示 URL (+0.15) + 抽出品質 (Good:+0.05 / Poor:-0.10 / FetchFailed:-0.20)。
→ `<|"Priority", "Components" -> <|"DomainWeight", "Domain", "Rank", "RankAdj", "Score", "ScoreAdj", "UserSpecifiedUrl", "DirectAdj", "ExtractionQuality", "QualityAdj"|>|>`
provenance は `SourceVaultWebSearch` / `SourceVaultWebFetch` の `"IngestProvenance"` または `iWebResultProvenance` が作る Association。

### SourceVaultWebPriority[recordId] → Association | Missing
recordId (snapshot Ref) の保存済み Priority sidecar (`LocalState/derived/web_priority/`) を返す。
→ `<|"RecordId", "Priority", "Components", "Url", "ComputedAt"|>` または `Missing["NoPriority"]`

### SourceVaultWebImportance[recordId, opts]
構造 Priority (provenance 初期推定) と使用ベース CurrentImportance (参照イベント) を統合した順位スコアを返す。
→ `<|"RecordId", "Priority", "PriorityComponents", "RefCount", "RecentReferenceScore", "CurrentImportance", "LastReferencedAt", "CombinedScore"|>`
CombinedScore = `Clip[PriorityWeight * Priority + (1-PriorityWeight) * Clip[CurrentImportance], {0,1}]`
Options: `"PriorityWeight" -> 0.5`, `"HalfLifeDays" -> 90`

### SourceVaultWebRecomputePriorities[opts]
保存済み WebDocument snapshot の `IngestProvenance` + 現行ドメイン重みから構造 Priority を再計算し sidecar を更新する。LLM 不要・高速。
→ `<|"Status", "Scanned", "Updated", "Failed", "SnapshotFiles"|>`
Options: `"Limit" -> Automatic` (Automatic = 全件, Integer で件数制限)

## ドメイン重み

### SourceVaultSetWebDomainWeight[domain, weight, opts]
ソースドメインの重み (0.0–1.0) を登録し `PrivateVault/config/web_domain_weights.json` に保存する。`"www."` は無視し正規化。サブドメインは親ドメイン重みを継承する。
→ `<|"Status"->"Set"|"Error", "Domain", "Weight"|>`
Options: `"Persist" -> True`

### SourceVaultWebDomainWeights[] → Association
登録済みドメイン重みの `domain -> weight` Association を返す (未ロードなら自動ロード)。

### SourceVaultWebDomainWeightFor[domain] → Real
ドメイン (またはサブドメイン) に適用される重みを返す。完全一致 → 親ドメイン継承の順で解決し、未登録なら既定値 `0.4` を返す。

### SourceVaultWebDomainWeightsLoad[] → Association
`PrivateVault/config/web_domain_weights.json` からドメイン重み config を再読み込みする。
→ `<|"Status"->"Loaded"|"NoRoot", "Count"|>`

## ハイライト抽出

### SourceVaultWebHighlights[text, query, opts]
text を文に分割しクエリ語との重なりでスコアして上位を返す (LLM 不要)。
→ `<|"Query", "Highlights" -> {文...}, "Count"|>`
Options: `"MaxHighlights" -> 5`, `"MinChars" -> 20` (最短文字数フィルタ)

## LLM 要約

### SourceVaultSummarizeText[text, opts]
ローカル LLM (LM Studio) で text を要約する。MCP 経路から自動で呼ばない (再入回避)。`"Persist" -> True` なら要約を DerivedArtifact 不変 snapshot として保存し戻り値に `"ArtifactRef"` を付ける (Succeeded 時のみ)。
→ `<|"Summary", "Model", "Status"|>` または `Failure`
Options: `"Instruction" -> Automatic`, `"MaxTokens" -> Automatic`, `"Temperature" -> Automatic`, `"Endpoint" -> Automatic` (`$SourceVaultSummaryEndpoint` 使用), `"Model" -> Automatic`, `"TimeoutSeconds" -> Automatic`, `"Persist" -> False`, `"SourceRefs" -> {}`, `"SourceUrls" -> {}`, `"Query" -> None`, `"Provenance" -> <||>`

### SourceVaultSummarizeResults[run, query]
検索結果 (run の Results: title/url/snippet) をローカル LLM で要約する。run は `SourceVaultWebSearch` の戻り値または Results リスト。`"Persist" -> True` なら run の `SearchRunRef` / Documents の `SnapshotRef` / 結果 URL を `SourceRefs`/`SourceUrls` として自動付与し DerivedArtifact を保存する。
→ `SourceVaultSummarizeText` と同形式

### SourceVaultStoreSummaryToken[opts]
main kernel で解決した LM Studio token を `LocalState/secrets/sourcevault-summary-token.json` (非 Dropbox) に保存する。service kernel (NBAccess 不在) でも token を解決できるようにする。戻り値に token 文字列は含めない。
→ `<|"Status"->"Stored"|"Error", "Path", "TokenLength"|>`
Options: `"Token" -> Automatic` (Automatic なら live 解決を試みる)

## DerivedArtifact

### SourceVaultSaveDerivedArtifact[artifact]
派生成果物を `ObjectClass "DerivedArtifact"` の不変 snapshot として content-addressed store に保存する。`ArtifactType = "Summary"` の場合、`SourceRefs` の各レコードに `"Summarized"` 参照イベントを emit する。
→ `<|"Status", "Ref", "ArtifactId", ...|>`
artifact 必須キー: `"ArtifactType"` (例: `"Summary"`), `"Text"`
任意キー: `"SourceRefs"`, `"SourceUrls"`, `"Query"`, `"Model"`, `"Provenance"`

### SourceVaultDerivedArtifact[ref] → Association
DerivedArtifact snapshot を ref から読み出す。

### SourceVaultDerivedArtifactList[opts]
保存済み DerivedArtifact の一覧 (各 assoc に `"Ref"` を付与) を返す。
→ List
Options: `"ArtifactType" -> All` (種別フィルタ; 例: `"ArtifactType" -> "Summary"`)

### SourceVaultDerivedArtifactsForSource[recordId] → List
`SourceRefs` に recordId を含む DerivedArtifact を返す (逆引き: 「この source から作られた要約」)。

## SearXNG 可用性 / Backend 切替

### SourceVaultSearXNGAvailableQ[opts]
`$SourceVaultSearXNGEndpoint` が到達可能かを返す。結果は既定 60 秒キャッシュ。
→ `True | False`
Options: `"CacheSeconds" -> 60`, `"TimeoutSeconds" -> Automatic`

### SourceVaultSwapWebSearchBackend[integrations]
integrations 中の web 検索 backend を SearXNG 可用時は SourceVault MCP に、不可時は exa に統一する。string ID と `<|"id"->...|>` 形式の両方に対応。web 検索以外の要素は不変。
→ integrations と同形式の List

### SourceVaultWebSearchIntegration[] → List
現在使うべき web 検索 integration リストを返す。SearXNG 可用なら `{$SourceVaultWebSearchIntegrationId}`、不可なら `{$SourceVaultExaFallbackIntegrationId}`。
例: `ClaudeCode``$ClaudeLMStudioIntegrations := SourceVaultWebSearchIntegration[]`

## データ構造

IngestProvenance (最小): `<|"ProvenanceId", "InitiationType", "RequestChannel", "UrlOrigin", "UserSpecifiedUrl", "UserSpecifiedQuery", "Actor", "PromptRef", "CreatedAt"|>`
ResultProvenance (fetch 用): IngestProvenance + `<|"Url", "SourceDomain", "SearchRank", "SearchScore", "SearchEngine"|>`
WebDocument snapshot キー: `"ObjectClass"->"WebDocument"`, `"Url"`, `"ContentHash"`, `"RawBlobRef"`, `"CleanTextRef"`, `"ExtractionStatus"`, `"IngestProvenance"` ほか
job 状態遷移: `"Queued"` → `"Running"` → `"Succeeded"` | `"Failed"` (service 再起動時は `SourceVaultWebRecoverStaleJobs` で `"Failed"` に掃く)