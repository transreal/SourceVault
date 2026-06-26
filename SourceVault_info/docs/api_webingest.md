# SourceVault_webingest API リファレンス

パッケージ: `SourceVault_webingest`
GitHub: https://github.com/transreal/SourceVault_webingest
コンテキスト: `SourceVault`` コンテキスト内に定義される service-loadable な Web ingest / SearXNG 層。FrontEnd/Notebook/UI 依存なし。main kernel・service kernel 両方で動作する。

依存: [SourceVault_core](https://github.com/transreal/SourceVault_core) (`SourceVaultRoot`, `SourceVaultCoreRoot`, `SourceVaultStorageDir`, `SourceVaultCommitBlob`, `SourceVaultSaveImmutableSnapshot`)

## 検索

### SourceVaultSearXNGSearch[query_String, opts]
SearXNG JSON API を叩き、候補 URL を正規化した Association を返す。
→ `<|"Provider","Endpoint","Query","Language","ResultCount","TotalAvailable","Results","Suggestions","UnresponsiveEngines","FetchedAt","Status"|>` または `Failure`
Results 各要素: `<|"Title","Url","Snippet","Engine","Category","Score","Rank","PublishedDate"|>`
Options: "Endpoint" -> Automatic (未指定時は `$SourceVaultSearXNGEndpoint`), "MaxResults" -> 10, "Language" -> "ja", "SafeSearch" -> 1, "TimeoutSeconds" -> 20, "Categories" -> Automatic, "PageNo" -> Automatic

### SourceVaultWebSearch[query_String, opts]
`SourceVaultSearXNGSearch` に最小 provenance と RunId を付加した SearchRun Association を返す。`"StoreSearchRun" -> True` 時に WebSearchRun 不変 snapshot と参照イベント (Searched) を自動保存する。
→ `<|"Provider","Endpoint","Query","ResultCount","Results","RunId","IngestProvenance","FetchPages","SearchRunRef",...|>` または `Failure`
Options: `SourceVaultSearXNGSearch` の全オプション に加え、"FetchPages" -> False (True で本文取得; 後続 increment), "MaxFetch" -> 3, "StoreSearchRun" -> True, "RequestChannel" -> "Notebook", "InitiationType" -> "UserPromptSearch", "Actor" -> Automatic, "PromptRef" -> None

### SourceVaultWebSearchRunList[] → List
保存済み WebSearchRun (検索監査記録) の Association リストを返す。

## ジョブ管理 (command/job 二層)

### SourceVaultWebSearchSubmit[input_Association] → Association
### SourceVaultWebSearchSubmit[query_String, opts] → Association
WebSearch job を作成し即座に返す。`$SourceVaultWebSearchAsync` が True なら `SessionSubmit` で非同期実行し `Status -> "Running"` を即返す。False なら inline 実行 (テスト用)。job 状態は `LocalState/jobs/<jobId>.json` に保存。
→ `<|"JobId","Status","Async"|>`

### SourceVaultWebJobStatus[jobId_String] → Association
→ `<|"JobId","Status","JobType","CreatedAt","UpdatedAt","FailureReason"|>`。未存在なら `Status -> "NotFound"`。

### SourceVaultWebJobResult[jobId_String] → Association
完了 job の結果を返す。未完了なら `"Ready" -> False`。
→ 成功: `<|"JobId","Status" -> "Succeeded","Ready" -> True,"Result"|>`; 失敗: `<|...,"FailureReason"|>`; 未完了: `<|...,"Ready" -> False|>`

### SourceVaultWebJobList[] → List
LocalState 上の全 job Association リストを返す。

### SourceVaultWebRecoverStaleJobs[] → Association
service 起動時に残った Running/Queued job を `Failed (StaleJobRecovered:ServiceRestarted)` に掃く。
→ `<|"Recovered","Scanned"|>`

## URL 取得・WebDocument

### SourceVaultWebFetch[url_String, opts]
URL 本文を取得し HTML clean-text 抽出 + ContentHash を行い、WebDocument を content-addressed store に不変 snapshot として保存する。取得/抽出失敗は EvidenceGap に記録。抽出成功時のみ `Ingested` 参照イベントを emit。provenance ベース構造 Priority を LocalState sidecar に保存。登録済み IngestHook を完了後に実行。
→ `<|"ObjectClass" -> "WebDocument","Url","CanonicalUrl","StatusCode","ContentType","ByteCount","ContentHash","RawBlobRef","CleanTextRef","CleanTextLength","Title","ExtractionStatus","ExtractionQuality","ExtractionReason","FetchedAt","IngestProvenance","CleanTextPreview","SnapshotRef","SnapshotStatus","Priority","IngestHooks"|>`
Options: "TimeoutSeconds" -> 30, "StoreEvidence" -> True, "Provenance" -> `<||>`, "RecordGap" -> True
ExtractionStatus 値: "Succeeded" / "Failed" / "FetchFailed" / "Skipped"
ExtractionQuality 値: "Good" (≥1500文字) / "Fair" (200-1499) / "Poor" (<200)
例: `SourceVaultWebFetch["https://example.com", "Provenance" -> <|"UserSpecifiedUrl" -> True, "RequestChannel" -> "Notebook"|>]`

## Web Ingest フック

### SourceVaultRegisterWebIngestHook[name_String, f_] → Association
`SourceVaultWebFetch` 完了時に呼ぶフック `f[ctx]` を登録する拡張点。`ctx = <|"Result", "Url"|>`。hook 失敗は fetch を壊さない。
→ `<|"Status" -> "Registered","Name"|>`

### SourceVaultUnregisterWebIngestHook[name_String] → Association
登録フックを解除する。→ `<|"Status" -> "Unregistered","Name"|>`

### SourceVaultWebIngestHooks[] → List
登録済み web ingest フック名のリストを返す。

## 参照イベントログ

### SourceVaultAddReferenceEvent[event_Association] → Association
参照イベントを append-only log (`LocalState/hotlog/reference_events/YYYY-MM.jsonl`) に追記する。自動で `At`/`EventId`/`Weight -> 1.0` を付与。
→ `<|"Status" -> "Appended","RecordId","Shard"|>` または `Failure`
event 必須キー: `"recordId"`, `"recordClass"`, `"eventType"`
eventType の重みは `$SourceVaultRefEventWeights` 参照。

### SourceVaultRefCount[recordId_String] → Integer
recordId の参照イベント数を local hot ログ ∪ CoreRoot rollup から返す。

### SourceVaultRecordImportance[recordId_String, opts]
参照イベントから recency-aware な重要度を計算する (spec v6 §36-38)。local ∪ rollup を読み dedup して集計。
→ `<|"RecordId","RefCount","FirstReferencedAt","LastReferencedAt","RecentReferenceScore","HistoricalImportance","CurrentImportance"|>`
Options: "HalfLifeDays" -> 90, "BasePriority" -> 0.0

### $SourceVaultRefEventWeights
型: Association, 初期値: `<|"Displayed"->0.2,"Retrieved"->0.3,"Searched"->0.3,"Selected"->0.5,"Ingested"->0.5,"Summarized"->0.7,"Exported"->0.8,"UsedInAnswer"->1.0,"Cited"->1.5,"UserPinned"->2.0,"Deposited"->0.1|>`
eventType → 重み の対応表。`SourceVaultRecordImportance` / `SourceVaultWebImportance` で使用。

## 参照イベント Rollup (CoreRoot/Dropbox 集約)

### SourceVaultRollupReferenceEvents[opts]
LocalState の参照イベント hot ログ (machine-local) の未集約分を `CoreRoot/rollup/reference_events/<host>/<shard>.jsonl` に追記する。watermark で増分管理し追記のみ (非破壊)。低頻度バッチ用。
→ `<|"Status","Host","Shards","NewEvents","RolledShards","PerShard","RollupDir"|>`
Options: "DryRun" -> False

### SourceVaultReferenceEventStoreStatus[] → Association
参照イベントストアの可観測性情報を返す。
→ `<|"LocalShards","LocalTotal","UnrolledEvents","RollupByHost","RollupTotal","Host","Watermark","LocalDir","RollupDir"|>`

### SourceVaultPruneRolledReferenceEvents[opts]
CoreRoot rollup に集約済みの古い local shard を削除して hot ログ肥大を抑える。rollup に同数以上のイベントが存在する shard のみ削除。破壊的操作のため既定 DryRun -> True。
→ `<|"Status","Host","PrunedCount","Pruned","Kept"|>`
Options: "DryRun" -> True (rule103 により既定 safe), "KeepMonths" -> 2 (最新 N ヶ月分は残す)

### $SourceVaultRollupIntervalSeconds
型: Integer, 初期値: 21600 (6時間)
service heartbeat ループが `SourceVaultRollupReferenceEvents` を自動実行する最小間隔 (秒)。反映には service 再起動が必要。

## 構造 Priority (provenance ベース)

### SourceVaultWebComputePriority[provenance_Association] → Association
### SourceVaultWebComputePriority[provenance_Association, doc_Association] → Association
WebDocument の構造的重要度 0.0-1.0 を決定的に計算する (LLM 不要)。シグナル: ドメイン重み + 検索ランク (指数減衰) + SearXNG スコア + ユーザ明示 URL + 抽出品質。
→ `<|"Priority","Components" -> <|"DomainWeight","Domain","Rank","RankAdj","Score","ScoreAdj","UserSpecifiedUrl","DirectAdj","ExtractionQuality","QualityAdj"|>|>`
例: `SourceVaultWebComputePriority[<|"UserSpecifiedUrl"->True,"SearchRank"->1|>, <|"Url"->"https://arxiv.org/...", "ExtractionQuality"->"Good"|>]`

### SourceVaultWebPriority[recordId_String] → Association
recordId の保存済み構造 Priority sidecar を返す。Priority は可変メタのため `LocalState/derived/web_priority/<recordId>.json` に置く。
→ `<|"RecordId","Priority","Components","Url","ComputedAt"|>` または `Missing["NoPriority"]`

### SourceVaultWebImportance[recordId_String, opts]
構造 Priority (provenance 初期推定) と使用ベース CurrentImportance (参照イベント) を統合して返す。
→ `<|"RecordId","Priority","PriorityComponents","RefCount","RecentReferenceScore","CurrentImportance","LastReferencedAt","CombinedScore"|>`
CombinedScore = `PriorityWeight * Priority + (1 - PriorityWeight) * Clip[CurrentImportance]`
Options: "PriorityWeight" -> 0.5, "HalfLifeDays" -> 90

### SourceVaultWebRecomputePriorities[opts]
保存済み WebDocument snapshot の `IngestProvenance` と現行ドメイン重みから構造 Priority を LLM なしで再計算し sidecar を更新する。
→ `<|"Status","Scanned","Updated","Failed","SnapshotFiles"|>`
Options: "Limit" -> Automatic (Automatic = 全件)

## ドメイン重み

### SourceVaultSetWebDomainWeight[domain_String, weight_?NumericQ, opts]
ソースドメインの重み (0.0-1.0) を登録し `PrivateVault/config/web_domain_weights.json` に保存する。"www." は無視し正規化。
→ `<|"Status","Domain","Weight"|>`
Options: "Persist" -> True

### SourceVaultWebDomainWeights[] → Association
登録済みドメイン重みの全 Association (domain -> weight) を返す。

### SourceVaultWebDomainWeightFor[domain_String] → Real
ドメイン (またはサブドメイン) に適用される重みを返す。完全一致 → 親ドメイン継承の順で解決し、未登録なら既定値 0.4 を返す。

### SourceVaultWebDomainWeightsLoad[] → Association
ドメイン重み config を再読み込みする。→ `<|"Status","Count"|>`

## ハイライト・要約

### SourceVaultWebHighlights[text_String, query_String, opts]
text からクエリ関連の文を抽出して返す (LLM 不要・TextSentences ベース)。
→ `<|"Query","Highlights" -> {文...},"Count"|>`
Options: "MaxHighlights" -> 5, "MinChars" -> 20

### SourceVaultSummarizeText[text_String, opts]
ローカル LLM (LM Studio OpenAI 互換) で text を要約する。MCP 経路から自動では呼ばない (再入回避)。`"Persist" -> True` で Succeeded 時に DerivedArtifact 不変 snapshot を保存し `"ArtifactRef"` を戻り値に付加する。
→ `<|"Summary","Model","Status"|>` または `Failure`; Persist 時は `"ArtifactRef"` を追加
Options: "Instruction" -> (モデル既定), "MaxTokens" -> (モデル既定), "Temperature" -> (モデル既定), "Endpoint" -> Automatic, "Model" -> Automatic, "TimeoutSeconds" -> (既定), "Persist" -> False, "SourceRefs" -> {}, "SourceUrls" -> {}, "Query" -> None, "Provenance" -> `<||>`

### SourceVaultSummarizeResults[run, query_String, opts]
検索結果 (run の Results: title/url/snippet) をローカル LLM で要約する。run は `SourceVaultWebSearch` の戻り値または Results リスト。`"Persist" -> True` なら SearchRunRef / SnapshotRef / URL を SourceRefs/SourceUrls として自動付与し DerivedArtifact を保存する。
→ `SourceVaultSummarizeText` と同形

## DerivedArtifact

### SourceVaultSaveDerivedArtifact[artifact_Association] → Association
派生成果物 (要約等) を `ObjectClass "DerivedArtifact"` の不変 snapshot として content-addressed store に保存する。`ArtifactType = "Summary"` 時、SourceRefs の各レコードに `"Summarized"` 参照イベントを emit して importance に反映する。
artifact 必須キー: `"ArtifactType"`, `"Text"`; 任意: `"SourceRefs"`, `"SourceUrls"`, `"Query"`, `"Model"`, `"Provenance"`
→ `<|"Status","Ref","ArtifactId",...|>`

### SourceVaultDerivedArtifact[ref_String] → Association
DerivedArtifact snapshot を ref から読み出す薄いロードラッパー。

### SourceVaultDerivedArtifactList[opts] → List
保存済み DerivedArtifact の一覧 (各 assoc に `"Ref"` を付与) を返す。
Options: "ArtifactType" -> All

### SourceVaultDerivedArtifactsForSource[recordId_String] → List
`SourceRefs` に recordId を含む DerivedArtifact を返す (source → 派生成果物 の逆引き)。

## LLM 設定変数

### $SourceVaultSummaryEndpoint
型: String, 初期値: "http://localhost:1234/v1/chat/completions"
要約に使う LLM の chat completions エンドポイント (LM Studio OpenAI 互換)。

### $SourceVaultSummaryModel
型: String|Automatic, 初期値: Automatic
要約に使うモデル id。Automatic なら `/v1/models` から動的解決する (rule 02: ハードコードしない)。

### $SourceVaultSummaryToken
型: String|Automatic, 初期値: Automatic
LM Studio API token。Automatic なら `ClaudeCode`$ClaudeLMStudioAPIToken` / NBAccess / `LocalState/secrets/sourcevault-summary-token.json` の順で解決する (rule 20: ハードコードしない)。

### SourceVaultStoreSummaryToken[opts] → Association
main kernel で解決した LM Studio token を `LocalState/secrets/sourcevault-summary-token.json` (非 Dropbox) に保存する。service kernel (NBAccess 不在) での要約用 token 解決に使う。戻り値に token 文字列を含めない (rule 20)。
Options: "Token" -> Automatic (明示指定可)

## SearXNG 可用性・backend 切替

### SourceVaultSearXNGAvailableQ[opts] → True|False
SearXNG (`$SourceVaultSearXNGEndpoint`) が到達可能かを返す。結果はキャッシュされる。
Options: "CacheSeconds" -> 60, "TimeoutSeconds" -> (既定)

### SourceVaultSwapWebSearchBackend[integrations_List] → List
integrations 中の web 検索 backend を SearXNG 可用時は SourceVault MCP に、不可時は exa に差し替えて返す。string ID と `<|"id"->...|>` 形式の両方に対応。web 検索以外の要素は不変。

### SourceVaultWebSearchIntegration[] → List
現在使うべき web 検索 integration リストを返す。SearXNG 可用なら `{$SourceVaultWebSearchIntegrationId}`、不可なら `{$SourceVaultExaFallbackIntegrationId}`。
例: `ClaudeCode`$ClaudeLMStudioIntegrations := SourceVaultWebSearchIntegration[]`

## backend 切替変数

### $SourceVaultSearXNGEndpoint
型: String, 初期値: "http://127.0.0.1:8888"
SearXNG の既定エンドポイント。`SourceVaultSearXNGSearch` の `"Endpoint" -> Automatic` 時に使用。

### $SourceVaultWebSearchAsync
型: True|False, 初期値: True
`SourceVaultWebSearchSubmit` を非同期 (`SessionSubmit`) で実行するか。False なら inline 実行 (テスト/デバッグ用)。

### $SourceVaultWebSearchIntegrationId
型: String, 初期値: "mcp/sourcevault"
SearXNG 可用時に使う LM Studio integration ID。

### $SourceVaultExaFallbackIntegrationId
型: String, 初期値: "mcp/exa"
SearXNG 不可時の後方互換 integration ID。

## 戻り値キー早見表

| 関数 | 重要キー |
|---|---|
| SourceVaultSearXNGSearch | Provider / Results[]{Title,Url,Snippet,Rank} / Status |
| SourceVaultWebSearch | RunId / IngestProvenance / SearchRunRef / Results |
| SourceVaultWebSearchSubmit | JobId / Status / Async |
| SourceVaultWebJobResult | Ready / Result / FailureReason |
| SourceVaultWebFetch | SnapshotRef / ContentHash / CleanTextRef / ExtractionStatus / Priority |
| SourceVaultRecordImportance | RefCount / RecentReferenceScore / CurrentImportance |
| SourceVaultWebImportance | Priority / CombinedScore / CurrentImportance |
| SourceVaultWebComputePriority | Priority / Components{DomainWeight,RankAdj,ScoreAdj,DirectAdj,QualityAdj} |
| SourceVaultRollupReferenceEvents | NewEvents / RolledShards / PerShard |
| SourceVaultSaveDerivedArtifact | Status / Ref / ArtifactId |

## provenance 構造

`SourceVaultWebSearch` / `SourceVaultWebFetch` の `"Provenance"` オプションに渡す Association の主要キー:
`"InitiationType"` ("UserPromptSearch" 等), `"RequestChannel"` ("Notebook" 等), `"UrlOrigin"` ("SearchResult"/"UserSpecified"), `"UserSpecifiedUrl"` (True/False), `"UserSpecifiedQuery"` (True/False), `"Actor"` (`<|"Type"->"HumanUser"|>` 等), `"PromptRef"`, `"SearchRank"` (Integer), `"SearchScore"` (Real), `"SearchEngine"` (String), `"SourceDomain"` (String)