# SourceVault SearXNG / MCP / WolframScript Service 仕様 v6

作成日: 2026-06-15  
v5 レビュー反映版

## 0. v6 で確定した追加修正

v6 では、v5 レビューで指摘された X1–X4 を反映し、root 解決層の移設に伴うロード順序問題を明示的に解決する。

1. **root 解決層の移設方式は「bootstrap 分離」を採用する。**  
   `SourceVault.wl` の自己ロード中に `$SourceVaultRoots` を初期化する必要があるため、最小 root bootstrap は `SourceVault.wl` の初期部に残す。  
   `SourceVault_core.wl` は service kernel 用の正規 root API を提供し、main kernel ではロード後に bootstrap 結果を core API と整合させる。

2. **`SourceVault_core.wl` を root 初期化より前に前倒し `Get` する案は、Phase 0 の代替案に留める。**  
   既存ロード順序への影響を最小化するため、初期実装では core の前倒しロードを必須にしない。

3. **依存監査は推移閉包で行う。**  
   `iFetchURL` / `iIngestURL` が直接呼ぶ関数だけでなく、それらがさらに依存する privacy / trust / storage tier / logging / snapshot helper まで列挙する。

4. **core へ流入する symbol 一覧を Phase 0 の成果物にする。**  
   root / storage helper を core へ移す範囲が膨らみすぎないよう、`SourceVaultInternal*` 形式の internal API で境界を作る。

5. **injected roots は service start 時点の snapshot と明記する。**  
   main kernel 側で root 設定を変更しても、稼働中 service には自動反映されない。反映には service restart または explicit reload command が必要である。

6. **root hash / root config version を health check に追加する。**  
   main kernel の current roots と service kernel の injected roots が食い違う場合は warning を出す。

7. **`SourceVaultSetRoot` はデータ移行を行わない。**  
   root 設定を変更しても既存データは旧パスに残る。移行が必要な場合は別途 migration command を使う。

8. **仕様レビューは v6 で概ね収束とし、次は Phase 0 の実コード依存監査に移る。**  
   追加の机上仕様変更よりも、`iFetchURL` / `iIngestURL` の呼び出し閉包抽出と小規模 prototype の情報価値を優先する。

---

## 1. ## 1. 目的

SourceVault から SearXNG を呼び出し、Web 検索結果を単なる URL 一覧ではなく、既存 SourceVault ingest / Evidence / Snapshot / SearchIndex に接続する。

また、LM Studio などのローカル LLM から remote MCP 経由で SourceVault の検索・Evidence・要約情報を取得できるようにする。

基本方針は次の通り。

```text
SearXNG = 候補 URL 発見
SourceVault_core.wl = root registry / immutable snapshot / common storage foundation
SourceVault_webingest.wl = service-loadable Web ingest / SearXNG / HTML clean-text layer
SourceVault_mcp.wl = MCP tool schema / validation / provenance helper
Python proxy = HTTP API + minimal remote MCP endpoint
WolframScript service kernel = command queue consumer + job executor
LocalState root = hot logs / jobs / token / importance cache
```

---

## 2. 全体構成

HTTP / MCP 端点は WolframScript kernel ではなく、既存 Python proxy 側に置く。

```text
LM Studio
  ↓ remote MCP over HTTP JSON-RPC
SourceVault Python proxy
  ↓ file command queue
SourceVault WolframScript service kernel
  ↓ SourceVault_core / searchindex / servicemanager / webingest / mcp helper
SearXNG Search API
  ↓
外部検索エンジン群
```

メイン Mathematica kernel / FrontEnd は長時間処理を直接実行しない。  
メイン kernel は `SourceVaultStartService`、`SourceVaultServiceStatus`、`SourceVaultSendServiceCommand` などの既存管理 API を使う。

---

## 3. root registry と storage 基盤の service-loadable 化

### 3.1 背景

既存 `iFetchURL` / `iIngestURL` は、単独関数ではなく以下に依存している。

```text
$SourceVaultRoots
iResolveRoots
iResolveDropboxRoot
iRawDir / iMetaDir / iParsedDir / iAttachmentsDir / iCompiledDir
$SourceVaultRoots["Tmp"]
storage tier
ContentHash / dedup
TrustLevel / PrivacyLevel
```

これらの多くは `SourceVault.wl` 本体にあり、service kernel には読み込まれていない。  
そのため、Web ingest を service kernel で実行するには、root / storage 基盤を service-loadable にする必要がある。

ただし、既存 `SourceVault.wl` では `$SourceVaultRoots` が本体ロード中の早い段階で初期化され、その後に `SourceVault_core.wl` がロードされる。  
したがって、root resolver を単純に core へ移すと、自己ロード中に未定義 symbol を参照する危険がある。

### 3.2 採用方針: bootstrap 分離

v6 では、root 移設方式として **bootstrap 分離**を採用する。

```text
SourceVault.wl 初期部:
  最小 root bootstrap を保持する。
  SourceVault 自身のロード中に必要な $SourceVaultRoots 初期化だけを担う。

SourceVault_core.wl:
  service kernel でも使える正規 root API を提供する。
  SourceVaultResolveRoots / SourceVaultRoot / SourceVaultRootAssociation などを定義する。

SourceVault.wl ロード完了後:
  bootstrap で得た roots と core API の roots を整合・検証する。
```

これにより、既存ロード順序を大きく壊さず、service kernel からも同じ root 解決規則を利用できるようにする。

### 3.3 bootstrap に残す最小範囲

`SourceVault.wl` 初期部に残すものは、自己ロードに必要な最小限に限定する。

```text
iResolveDropboxRootBootstrap
iResolveRootsBootstrap
$SourceVaultRoots 初期化
```

例：

```wolfram
If[! AssociationQ[$SourceVaultRoots],
  $SourceVaultRoots = iResolveRootsBootstrap[]
]
```

これは互換性維持のための bootstrap であり、正規 API ではない。  
新規コードは、可能な限り core 側 API を使う。

### 3.4 core 側 root API

`SourceVault_core.wl` は、main kernel / service kernel の両方で使える root API を提供する。

```wolfram
SourceVaultResolveRoots[]
SourceVaultRoot[key_String]
SourceVaultRootAssociation[]
SourceVaultSetRoot[key_String, path_String]
SourceVaultRootConfigHash[]
SourceVaultStorageDir[class_String]
```

既存 private API は互換 wrapper とする。

```wolfram
iResolveRoots[] := SourceVaultResolveRoots[]
iRawDir[] := SourceVaultStorageDir["Raw"]
iMetaDir[] := SourceVaultStorageDir["Meta"]
```

### 3.5 root key

`$SourceVaultRoots` は少なくとも以下を持つ。

```text
PrivateVault
CloudMirror
Tmp
AttachmentMirror
ExternalOwned
LocalState
```

`LocalState` は v5 以降で追加する。  
これは Dropbox 非同期の hot state 用 root である。

### 3.6 LocalState の既定解決

`LocalState` の既定候補：

```text
Windows:
  %LOCALAPPDATA%/SourceVault/

macOS:
  ~/Library/Application Support/SourceVault/

Linux:
  ~/.local/state/sourcevault/
```

ただし、設定で明示指定されている場合はそれを優先する。

### 3.7 service kernel への注入

`iGenRunWls` が生成する `run.wls` は、`SourceVaultCoreRoot` と同様に、解決済み `SourceVaultRoots` または少なくとも `LocalState` を service kernel に注入する。

```wolfram
$SourceVaultCoreRoot = "...";
$SourceVaultInjectedRoots = <|
  "PrivateVault" -> "...",
  "Tmp" -> "...",
  "LocalState" -> "..."
|>;
$SourceVaultInjectedRootHash = "...";
```

service kernel 側では、注入値があればそれを優先する。  
これにより、main kernel と service kernel の root 解決の分裂を防ぐ。

### 3.8 injected roots は start-time snapshot

`$SourceVaultInjectedRoots` は service 起動時の snapshot である。  
main kernel 側で `SourceVaultSetRoot[...]` を実行して root 設定を変更しても、稼働中 service には自動反映されない。

root 変更を service に反映する方法は次のいずれかとする。

```text
SourceVaultRestartService[]
  service を再起動し、run.wls に新しい roots を注入する。

SourceVaultReloadRoots[]
  将来導入する explicit reload command。
  MVP では必須にしない。
```

health check では、main kernel の current root hash と service kernel の injected root hash を比較し、不一致なら warning を出す。

### 3.9 SourceVaultSetRoot の意味

`SourceVaultSetRoot[key, path]` は root 設定を変更するだけであり、既存データの移動は行わない。

```text
SourceVaultSetRoot["PrivateVault", newPath]
  root 設定を変更する。
  旧 PrivateVault 配下のデータは自動移動しない。
```

データ移行が必要な場合は、別途 migration command を用意する。

### 3.10 scheduled task user の検証

Windows Task Scheduler により起動される service kernel が、main kernel と同じユーザ権限で動作していることを確認する。

health check に以下を含める。

```text
service user name
main user name
LocalState path
CoreRoot path
root config hash
LocalState path writable
LocalState path matches expected configured path
```

異なるユーザとして動いている場合、`%LOCALAPPDATA%` が分裂する可能性があるため、warning を出す。

---

## 4. ## 4. package 構成とローダ

### 4.1 追加ファイル

v5 では、次の例外的な追加ファイルを認める。

```text
SourceVault_webingest.wl
  Web search / URL ingest / SearXNG / HTML clean-text / SearchRun overlay

SourceVault_mcp.wl
  MCP tool schema / validation / provenance / command payload helper
```

`SourceVault_webingest.wl` は「薄い wrapper」ではなく、root / storage 層の service-loadable 化を伴うリファクタ対象である。

### 4.2 Phase 0 の依存監査

`SourceVault_webingest.wl` を作る前に、`iFetchURL` / `iIngestURL` の呼び出し閉包を列挙する。

この監査は 1 段の直接依存だけでなく、**推移閉包**として行う。  
たとえば、`iFetchURL` が呼ぶ helper がさらに privacy / trust / storage tier / event logging / snapshot helper に依存する場合、それらも一覧に含める。

分類：

```text
A. SourceVault_core.wl へ移すもの
   root registry
   root resolver
   common storage helpers
   hashing / atomic write / lock primitives

B. SourceVault_webingest.wl に置くもの
   SearXNG client
   URL fetch adapter
   HTML clean-text extraction
   SearchRun overlay
   Web provenance
   Web initial priority inference

C. SourceVault.wl 本体に残すもの
   Notebook / FrontEnd / UI 依存
   legacy high-level wrappers
   backward-compatible aliases
```

監査結果には、次を含める。

```text
直接依存 symbol 一覧
推移依存 symbol 一覧
core に移すと連鎖的に流入する symbol 一覧
webingest に置く symbol 一覧
本体に残す symbol 一覧
SourceVaultInternal* API に昇格させる候補
```

core に入る範囲が膨らみすぎる場合は、`SourceVaultInternal*` 形式の internal API を境界として設ける。

### 4.3 既存 ingest 回帰テスト

切り出し前に、既存 URL / arXiv ingest の回帰テストを固定する。

```text
test codes/SourceVaultSources_smoke.wls
URL ingest smoke test
arXiv ingest smoke test
ContentHash / dedup regression
redirect handling regression
storage tier regression
```

切り出し後も同じテストが通ることを Phase 1 exit 条件にする。

### 4.4 context 設計

`SourceVault_webingest.wl` と `SourceVault_mcp.wl` は、既存 private 関数と衝突しないように、原則として同じ package context 構造を使う。

```wolfram
BeginPackage["SourceVault`"]
...
Begin["`Private`"]
...
End[]
EndPackage[]
```

クロスファイル private symbol を使う場合は、同一 context に置く。  
必要に応じて private helper ではなく `SourceVaultInternal...` 形式の internal API に昇格させる。

### 4.5 メインローダ

`SourceVault.wl` 末尾の明示 `Get[]` リストに、必要に応じて次を追加する。

```wolfram
Get[FileNameJoin[{$packageDirectory, "SourceVault_webingest.wl"}]]
Get[FileNameJoin[{$packageDirectory, "SourceVault_mcp.wl"}]]
```

glob scan は実ロード機構ではない。

### 4.6 service kernel ローダ

`iGenRunWls` が生成する `run.wls` の service package list も必ず更新する。

service kernel の読み込み対象：

```text
SourceVault_core.wl
SourceVault_searchindex.wl
SourceVault_servicemanager.wl
SourceVault_webingest.wl
SourceVault_mcp.wl
```

原則として、service kernel に `SourceVault.wl` 本体は読ませない。

---

## 5. SearXNG 連携

### 5.1 SearXNG の役割

SearXNG は候補 URL 発見のみを担当する。

```text
query
→ SearXNG Search API
→ title / url / snippet / engine / category / rank
```

本文取得、dedup、ContentHash、Evidence、要約、provenance は SourceVault 側で処理する。

### 5.2 セットアップ前提

SearXNG はローカル専用で運用する。  
bind は `127.0.0.1` とし、`0.0.0.0` での公開を前提にしない。

```yaml
search:
  formats:
    - html
    - json

server:
  bind_address: "127.0.0.1"
  secret_key: "<random-secret>"
```

ローカル専用の場合のみ、必要に応じて limiter を緩める。

```yaml
server:
  limiter: false
```

ただし、SearXNG が LAN / public に公開される場合は `limiter: false` を禁止する。

新しめの SearXNG では `limiter` とは別に bot detection が JSON API 呼び出しを 403/429 にする場合がある。SourceVault 側の疎通テストでは、`format=json` が実際に返ることを確認する。

---

## 6. HTTP API と service 実行モデル

### 6.1 WolframScript は直接 HTTP listen しない

HTTP API は既存 Python proxy が提供し、WL service kernel とは file command queue で通信する。

```text
HTTP / MCP request
  ↓
Python ThreadingHTTPServer proxy
  ↓ commands/*.json
WL service kernel single command loop
  ↓ done/*.json
Python proxy response
```

### 6.2 単一 WL kernel・直列処理

WL service kernel は単一 kernel であり、commands を直列に消費する。  
ネットワーク I/O を伴う処理を同期実行して command loop を長時間塞いではならない。

SearXNG 検索、URL fetch、HTML clean-text、要約生成などは job として登録し、必要に応じて kernel 内 `SessionSubmit` 等で非同期化する。

---

## 7. command と job の二層モデル

### 7.1 command

command は file command queue 上の即応 request/response である。

```text
Ping
Health
WebSearchSubmit
WebJobStatus
WebJobResult
AddReferenceEvent
```

command は `CommandId` を持つ。  
`SourceVaultServiceCommandResult[CommandId]` が返すのは、command の応答である。

### 7.2 job

job は長時間処理であり、service kernel 側の job state store で管理する。

job は `JobId` を持つ。

```text
WebSearchJob
WebFetchJob
WebIngestJob
WebSummarizeJob
WebHighlightJob
IndexUpdateJob
```

状態：

```text
Queued
Running
Succeeded
Failed
Cancelled
PartiallySucceeded
```

### 7.3 submit / status / result

`WebSearchSubmit` command は job を開始し、JobId を即返す。

```wolfram
cmd = SourceVaultSendServiceCommand[
  "WebSearchSubmit",
  <|
    "Query" -> "SearXNG LM Studio MCP",
    "FetchPages" -> True,
    "MakeSummary" -> True,
    "MakeHighlights" -> True
  |>
];

submit = SourceVaultServiceCommandResult[cmd["CommandId"]];
jobId = submit["JobId"];
```

状態確認：

```wolfram
statusCmd = SourceVaultSendServiceCommand[
  "WebJobStatus",
  <|"JobId" -> jobId|>
];

status = SourceVaultServiceCommandResult[statusCmd["CommandId"]];
```

結果取得：

```wolfram
resultCmd = SourceVaultSendServiceCommand[
  "WebJobResult",
  <|"JobId" -> jobId|>
];

result = SourceVaultServiceCommandResult[resultCmd["CommandId"]];
```

### 7.4 job staleness recovery

service 起動時に、LocalState に残る stale job を掃く。

対象：

```text
Running のまま service restart を跨いだ job
heartbeat より古い Running job
worker task id が存在しない job
異常終了した SessionSubmit job
```

処理：

```text
Running → Failed
または
Running → Cancelled
```

`FailureReason` には `ServiceRestarted` / `WorkerLost` / `StaleJobRecovered` などを記録する。

---

## 8. LocalState / runtime / sidecar 配置

### 8.1 既存 runtime

既存 service runtime は CoreRoot 配下にある。

```text
<CoreRoot>/runtime/services/<serviceId>/
```

これは GitHub package directory 外であり、配布対象ではない。  
ただし CoreRoot が Dropbox 配下の場合、heartbeat / commands / done による同期 churn が発生し得る。

### 8.2 LocalState root

v5 では、高頻度 append / update が発生する新規データについて、Dropbox 非同期の `LocalState` root を使う。

```wolfram
SourceVaultRoot["LocalState"]
```

standalone `$SourceVaultLocalStateRoot` を正本にはしない。  
必要なら互換 alias としてのみ提供する。

```wolfram
$SourceVaultLocalStateRoot := SourceVaultRoot["LocalState"]
```

### 8.3 hot sidecar の配置

ReferenceEvents、job progress、importance cache、MCP token などは、原則として LocalState に置く。

```text
<LocalState>/
  hotlog/
    reference_events/
      2026-06.jsonl
  jobs/
    job-....json
  importance_cache/
    web.jsonl
  secrets/
    sourcevault-mcp-token.json
  locks/
```

Dropbox / PrivateVault に同期するのは、必要な低頻度 rollup のみとする。

```text
<CoreRoot>/mutable_metadata_rollups/
  reference_events/
    2026-06-summary.json
  importance/
    web-priority-rollup.json
```

### 8.4 runtime の扱い

既存 runtime をすぐ移動しない場合でも、以下を Directives に明記する。

```text
runtime は GitHub upload 禁止
runtime は Dropbox 同期 churn の原因になり得る
可能なら Dropbox 選択同期から除外する
新規 hot log は LocalState に置く
```

---

## 9. Web ingest と既存 Source / Snapshot の統合

### 9.1 WebDocument は overlay とする

`WebDocument` という新しい並列ストアは作らない。  
Web / URL 由来データは、既存 Source / Snapshot ingest に対する overlay metadata として扱う。

既存 ingest が持つもの：

```text
URL
redirect chain
ContentHash
FetchedAt
ContentType
ByteCount
storage tier
dedup
snapshot digest
```

v5 で追加するもの：

```text
SearchRun metadata
IngestProvenance
Priority sidecar
ReferenceEvents sidecar
CleanTextRef
Chunk / Evidence refs
DerivedArtifact refs
```

### 9.2 SourceVault_webingest.wl

`SourceVault_webingest.wl` は、service-loadable な Web ingest 層である。

```text
SourceVaultSearXNGSearch
SourceVaultWebSearch
WebSearchSubmit command handler
WebJobStatus / WebJobResult helper
URL fetch / ingest adapter
HTML clean-text extraction
SearchRun overlay 保存
Provenance 作成
Priority 初期推定
EvidenceGap 登録
```

既存 `iIngestURL` / `iFetchURL` / URL 正規化 / ContentHash / dedup は、依存監査後に core / webingest へ移して再利用する。

### 9.3 EvidenceGap

Web fetch 失敗、HTML clean-text 失敗、PDF 抽出失敗などは、既存 `$svEvidenceGaps` を拡張して記録する。

新しい EvidenceGap store は作らない。

---

## 10. Provenance

### 10.1 最小 provenance schema

Phase 1 では、provenance は Web / URL 由来データに限定して導入する。

```wolfram
<|
  "ProvenanceId" -> "prov-...",
  "InitiationType" -> "UserPromptURL" | "UserPromptSearch" | "LLMAutoIngest" | "MCPIngest" | "ScheduledIngest" | "RefreshIngest" | "RepairIngest" | "ManualAdminIngest" | "SystemInternalIngest",
  "RequestChannel" -> "Notebook" | "MCP" | "HTTPAPI" | "Scheduler" | "SourceVaultAgent" | "InternalWorkflow",
  "UrlOrigin" -> "UserSpecified" | "SearchResult" | "LLMGenerated" | "MCPProvided" | "ExistingDocument" | "ScheduledRefresh" | "RepairCandidate" | "ManualAdmin",
  "UserSpecifiedUrl" -> True | False | "Unknown",
  "Actor" -> <|"Type" -> "HumanUser" | "LLM" | "MCPClient" | "Scheduler" | "AdminTool"|>,
  "PromptRef" -> _,
  "ParentJobId" -> _,
  "ParentSearchRunId" -> _,
  "CreatedAt" -> DateObject[]
|>
```

`InitiatedBy` は原則使わず、`Actor.Type` に統一する。

### 10.2 MCP 経由 provenance

MCP 経由の場合は、proxy または `SourceVault_mcp.wl` 補助関数が次を補う。

```wolfram
<|
  "RequestChannel" -> "MCP",
  "Actor" -> <|"Type" -> "MCPClient", "ClientName" -> "LM Studio"|>,
  "MCPClient" -> "LM Studio",
  "MCPToolName" -> "...",
  "MCPToolCallId" -> "..." | "Unknown",
  "UserSpecifiedUrl" -> "Unknown",
  "UrlOrigin" -> "MCPProvided"
|>
```

---

## 11. Mutable sidecar for Priority / ReferenceEvents / Importance

### 11.1 不変スナップショットには入れない

`Priority`、`ReferenceEvents`、`CurrentImportance`、`HistoricalImportance`、`LastReferencedAt` などの可変情報は、content-addressed immutable snapshot 本体には入れない。

### 11.2 sidecar store

可変メタ情報は record id をキーにした sidecar store に置く。  
hot append-only data は LocalState に置く。

```text
<LocalState>/
  hotlog/reference_events/YYYY-MM.jsonl
  importance_cache/*.jsonl
  jobs/*.json
```

同期が必要なものだけを低頻度 rollup として CoreRoot に出力する。

### 11.3 ReferenceEvents

参照イベントは本体 record を書き換えず、append-only log に追記する。

```json
{
  "recordId": "source-...",
  "recordClass": "WebSource",
  "at": "2026-06-15T...",
  "eventType": "UsedInAnswer",
  "channel": "MCP",
  "weight": 1.0,
  "parentJobId": "job-..."
}
```

`RefCount` は派生値であり、整数カウンタを正本にしない。

### 11.4 書き手の一本化

ReferenceEvents の書き手は service kernel に一本化する。

```text
Notebook main kernel
  → AddReferenceEvent command
  → service kernel
  → append-only log

MCP / proxy
  → AddReferenceEvent command
  → service kernel
  → append-only log
```

main kernel / proxy / MCP endpoint が直接 jsonl に追記してはならない。

### 11.5 lock と derived cache

複数 service instance や異常終了に備え、append / rollup / cache 更新には core の atomic directory lock を流用する。

検索 ranking で大量レコードに対して ReferenceEvents を毎回全走査しない。  
派生カウント・最近参照スコア・importance cache を持つ。

```text
正本:
  ReferenceEvents append-only log

派生:
  RefCount cache
  LastReferencedAt cache
  CurrentImportance cache
```

---

## 12. Priority

### 12.1 Mail priority との整合

Web priority は mail priority の設計に合わせる。

```text
Derived.Priority
Derived.PriorityComponents
```

ただし、可変更新される priority は snapshot 本体ではなく sidecar 側に保持する。  
snapshot に入れる場合は初期推定値など不変情報に限る。

### 12.2 初期 priority 推定

標準初期値：

```text
UserPromptURL:       0.8 - 1.0
UserPromptSearch:    0.5 - 0.7
ManualAdminIngest:   0.6 - 0.9
LLMAutoIngest:       0.3 - 0.6
MCPIngest:           0.1 - 0.4
MCPBulkIngest:       0.0 - 0.1
Scheduled/Refresh:   継承 or 0.1 - 0.3
RepairIngest:        親の priority を継承
```

MCP bulk ingest は、ユーザが個別に選んだとは限らないため低い初期値にする。

---

## 13. Recency-aware importance

`CurrentImportance` / `HistoricalImportance` / 時間減衰は Phase 4 以降で導入する。  
Phase 1 では実装しない。

参照イベントは時間とともに減衰させる。

```wolfram
ReferenceDecayWeight[eventTime_, now_, halfLifeDays_] :=
  2^(-QuantityMagnitude[DateDifference[eventTime, now, "Day"]] / halfLifeDays)
```

過去に集中して参照されたが最近参照されていないものは、HistoricalImportance は高くても CurrentImportance は下がる。

---

## 14. MCP 設計

### 14.1 remote MCP over HTTP

LM Studio の API 駆動経路では remote MCP を使う。

```text
LM Studio /api/v1/chat integrations
  ↓ remote MCP server_url
SourceVault Python proxy MCP endpoint
  ↓ file command queue
WL service kernel
```

stdio MCP は、本プロジェクトの API 駆動経路では採用しない。

### 14.2 MVP transport

Phase 5 MVP では、SSE-free の request/response JSON-RPC を優先する。

MVP interop spike で確認すること：

```text
LM Studio から endpoint に接続できる
initialize が通る
tools/list が取得できる
ダミー tools/call が通る
```

この interop spike が通ってから、実 tool を実装する。

SSE / progress streaming は Phase 5 後半または Phase 6 以降に回す。  
長時間処理は Submit → Status → Result で扱うため、SSE は MVP 必須ではない。

### 14.3 Python proxy の実装方針

Phase 5 MVP では、既存 proxy の原則を維持する。

```text
stdlib-only
SHA256 pin
fail-closed
SourceVaultPublishProxyCodeSnapshot による再 publish
MaterializeProxyCode による検証
```

MCP SDK など 3rd-party dependency は初期 MVP では導入しない。  
SDK 採用は将来の選択肢として残すが、その場合は proxy の trust model と配布方法を別途見直す。

### 14.4 実装対象 MCP subset

MVP では最小 subset を実装する。

```text
initialize
tools/list
tools/call
request/response JSON-RPC over HTTP
```

tool は async submit / poll を既定にする。

```text
sourcevault_submit_web_search
sourcevault_job_status
sourcevault_job_result
sourcevault_search_evidence
sourcevault_get_document
```

同期 tool は `fetchPages -> false` の軽量検索に限る。

### 14.5 timeout

proxy→service command の短 timeout で長時間 job 結果を待たない。

```text
tools/call sourcevault_submit_web_search:
  command は JobId を即返す

tools/call sourcevault_job_status:
  command は job state を即返す

tools/call sourcevault_job_result:
  完了済みなら結果を返す
  未完了なら Running / NotReady を返す
```

### 14.6 SourceVault_mcp.wl の役割

`SourceVault_mcp.wl` は MCP protocol endpoint ではない。  
WL 側補助ライブラリである。

```text
tool schema 定義補助
argument validation
provenance 付与補助
command payload 整形
result 整形
```

実際の JSON-RPC / HTTP protocol handling は Python proxy 側に置く。

### 14.7 認証 token

HTTP API / MCP endpoint には local shared-secret token を導入する。

```text
127.0.0.1 bind は必須
加えて X-SourceVault-Token などの shared-secret を検証する
```

token は LocalState 配下に置く。

```text
<LocalState>/secrets/sourcevault-mcp-token.json
```

GitHub package directory や `SourceVault_info/` 配下には置かない。

LM Studio 側では `mcp.json` の `headers` で渡す。

```json
{
  "mcpServers": {
    "sourcevault": {
      "url": "http://127.0.0.1:9123/mcp",
      "headers": {
        "X-SourceVault-Token": "<local-token>"
      }
    }
  }
}
```

token を `mcp.json` に書く場合、そのファイル自体も GitHub upload 対象にしない。

---

## 15. exa から SourceVault MCP への移行

現行 web 検索は LM Studio 側の `mcp/exa` integration に依存している。  
Wolfram 側に Exa クライアントは存在しない。

### 15.1 LM Studio mcp.json 登録

移行 Phase A の最初に、LM Studio の `mcp.json` に SourceVault remote MCP を登録する。

例：

```json
{
  "mcpServers": {
    "sourcevault": {
      "url": "http://127.0.0.1:9123/mcp",
      "headers": {
        "X-SourceVault-Token": "<local-token>"
      }
    }
  }
}
```

`url` は Python proxy の MCP endpoint を指す。  
`headers` には LocalState に保存した token を設定する。

### 15.2 feature flag による段階移行

移行は feature flag で段階的に行う。

```text
Phase A:
  mcp/exa を継続利用しつつ SourceVault MCP を併用

Phase B:
  同一 query で exa と SourceVault の結果を比較

Phase C:
  SourceVault MCP を既定にする

Phase D:
  integrations から mcp/exa を外し、ToolNudge 文言を更新

Rollback:
  feature flag で mcp/exa に戻す
```

更新対象：

```text
$ClaudeLMStudioIntegrations
$ClaudeLMStudioToolNudge
LM Studio mcp.json
関連 config / directives
```

---

## 16. HTML clean-text 抽出

既存 URL ingest は fetch / ContentHash / dedup を持つが、HTML readability 相当の clean-text 抽出は新規工数である。

Phase 3 の主要実装対象：

```text
HTML boilerplate 除去
title / headings 抽出
main text 推定
code block 保持
table の扱い
language detection
failed extraction の EvidenceGap 記録
```

---

## 17. upload_manifest.json

### 17.1 実フォーマット

manifest は実フォーマットに合わせる。

```json
{
  "packageName": "SourceVault",
  "files": [
    "SourceVault.wl",
    "SourceVault_core.wl",
    "SourceVault_searchindex.wl",
    "SourceVault_servicemanager.wl",
    "SourceVault_webingest.wl",
    "SourceVault_mcp.wl",
    "SourceVault_info/wolframscript/SourceVaultService.wls"
  ],
  "directories": [
    "SourceVault_info"
  ],
  "excludePatterns": [
    "SourceVault_info/runtime/",
    "SourceVault_info/cache/",
    "SourceVault_info/local/",
    "SourceVault_info/secrets/"
  ]
}
```

`include` / `exclude` glob 形式は採用しない。

### 17.2 実配置との整合

runtime、hot logs、job state、token は package directory 外に置くため、通常は `SourceVault_info/` 配下の excludePatterns に依存しない。

ただし、誤配置への guard として、以下を残す。

```text
SourceVault_info/runtime/
SourceVault_info/cache/
SourceVault_info/local/
SourceVault_info/secrets/
```

既存 `github.wl` が `history/` と `references/` を default exclude として merge する点も Directives に明記する。

### 17.3 .wls の配布

WolframScript entry point は GitHub 配布に含めるが、`$packageDirectory` 直下には置かない。

配置：

```text
SourceVault_info/wolframscript/SourceVaultService.wls
```

`.wls` は既存自動追記の対象外であるため、`files[]` に明示的に追加する。

### 17.4 manifest 検証関数

`SourceVaultValidateUploadManifest[]` は、manifest tooling がある `github.wl` 側に置く。  
SourceVault 側から使う場合は thin wrapper を用意する。

検査項目：

```text
files[] に必須 .wl がある
files[] に SourceVault_info/wolframscript/SourceVaultService.wls がある
SourceVault_webingest.wl / SourceVault_mcp.wl が files[] にある
excludePatterns[] に guard path がある
SourceVault_info/runtime/ が upload 対象にならない
secret/token/API key が含まれない
```

---

## 18. WolframScript entry point 配置

`*.wls` は以下に配置する。

```text
SourceVault_info/wolframscript/
```

例：

```text
SourceVault_info/wolframscript/SourceVaultService.wls
```

`SourceVaultService.wls` は entry point であり、主要ロジックを持たない。

許可：

```text
package 読み込み
config 読み込み
service main 呼び出し
error logging
```

禁止：

```text
Web ingest 本体
SearXNG 本体
Evidence 更新本体
Job Queue 本体
MCP protocol 本体
```

---

## 19. Claude Directives への反映

Claude Directives に以下を追加する。

```text
SourceVault*.wl は package/library として $packageDirectory 直下に置く。
SourceVault*.wls は $packageDirectory 直下に置かない。
WolframScript entry point は SourceVault_info/wolframscript/ に置く。
*.wls は Get / Needs の対象にしない。
*.wls は自動 package scan の対象にしない。
SourceVaultService.wls は entry point と初期化処理に限定する。
SourceVault の主要ロジックを .wls に置かない。
```

service kernel loader 更新義務：

```text
SourceVault_webingest.wl または SourceVault_mcp.wl を追加・改名した場合、
メインローダだけでなく iGenRunWls の service package list も更新する。
```

root / LocalState：

```text
$SourceVaultRoots["LocalState"] を hot state 用 root として使う。
ReferenceEvents、job progress、importance cache、token など高頻度更新データは
Dropbox 同期対象ではなく LocalState に置く。
```

token：

```text
SourceVault MCP token は LocalState/secrets/ に保存する。
SourceVault_info/ 配下や GitHub upload 対象に置かない。
LM Studio mcp.json に token header を設定する場合、mcp.json も upload しない。
```

manifest 更新義務：

```text
新しい SourceVault*.wl を追加した場合
SourceVault_info/wolframscript/*.wls を追加・削除・改名した場合
GitHub 配布対象 docs / config template を追加した場合
runtime / cache / local data の配置を変更した場合
```

runtime / secret upload 禁止：

```text
PID、log、heartbeat、local cache、local evidence store、secret、token、API key は upload_manifest.json に含めてはならない。
```

---

## 20. 修正版フェーズ計画

### Phase 0: 設計確定・依存監査

```text
root 移設方式は bootstrap 分離を採用する
SourceVault.wl 自己ロード中に roots を使う箇所を棚卸し
iFetchURL / iIngestURL の呼び出し閉包を推移的に列挙
core へ流入する symbol 一覧を出力
root resolver / storage helper の core API 境界を確定
$SourceVaultRoots["LocalState"] を追加
run.wls への resolved roots 注入方針を確定
root config hash / injected root hash の health check を定義
root 変更は service restart または reload command で反映と明記
SourceVaultSetRoot はデータ移行を伴わないと明記
scheduled task user と LocalState 一致の health check を定義
SourceVault_webingest.wl への切り出し範囲を確定
既存 URL/arXiv ingest 回帰テストを固定
MCP MVP は SSE-free request/response JSON-RPC に確定
shared-secret token の保存場所を LocalState/secrets/ に確定
command と job の二層モデルを確定
```

### Phase 1: root / webingest 基盤

```text
SourceVault.wl 初期部に root bootstrap を残す
SourceVault_core.wl に正規 root API / LocalState / root hash を追加
main kernel ロード後に bootstrap roots と core roots を整合確認
SourceVault_webingest.wl 新設
service-loadable directory helper を整備
iGenRunWls の service package list 更新
run.wls へ resolved roots / root hash を注入
メインローダ更新
SourceVaultSetRoot の usage に「データ移行なし」を明記
既存 ingest 回帰テストを通す
```

### Phase 2: SearXNG 取り込み MVP

```text
SearXNG セットアップ・疎通テスト
SourceVaultSearXNGSearch
SourceVaultWebSearch
SearchRun overlay 保存
最小 provenance のみ導入
Web レコード限定
既存関数名・config に整合
```

### Phase 3: service / job 状態管理

```text
既存 SourceVaultStartService を再利用
Python proxy / file command queue に新 command verb を追加
WebSearchSubmit / WebJobStatus / WebJobResult を実装
job state store を LocalState に配置
service 起動時の stale Running job recovery
ReferenceEvents 書き手を service kernel に一本化
```

### Phase 4: 本文取得・clean text

```text
既存 iIngestURL / iFetchURL / ContentHash / dedup を service-loadable 化して再利用
HTML clean-text 抽出を新規実装
既存 EvidenceGap store を拡張
CleanTextRef / Chunk / Evidence refs を保存
```

### Phase 5: 要約・ハイライト・importance

```text
query dependent highlight
page summary
search run summary
ReferenceEvents append-only sidecar
derived RefCount / LastReferencedAt / CurrentImportance cache
mail priority と整合した Web priority recompute
Dropbox 同期用低頻度 rollup
```

### Phase 6: MCP 連携

```text
MCP interop spike: initialize / tools/list / dummy tools/call
Python proxy に stdlib-only minimal remote MCP endpoint を実装
SourceVault_mcp.wl を WL 側補助ライブラリとして実装
proxy code snapshot を再 publish / SHA256 pin 更新
local token 認証
LM Studio mcp.json に url + headers を登録
async submit / poll tools を既定にする
SSE progress は後回し
exa と併用 → 検証 → 撤去
```

### Phase 7: 配布・Directives

```text
upload_manifest.json を実フォーマットで更新
SourceVault_webingest.wl / SourceVault_mcp.wl を files[] に追加
SourceVault_info/wolframscript/SourceVaultService.wls を files[] に明示追加
guard excludePatterns を確認
SourceVaultValidateUploadManifest[] を github.wl 側に実装
Claude Directives 更新
```

---

## 21. 到達目標

メイン kernel からは、command/job 二層で操作する。

```wolfram
SourceVaultStartService[];

submitCmd = SourceVaultSendServiceCommand[
  "WebSearchSubmit",
  <|
    "Query" -> "SearXNG LM Studio MCP",
    "FetchPages" -> True,
    "MakeSummary" -> True,
    "MakeHighlights" -> True
  |>
];

submit = SourceVaultServiceCommandResult[submitCmd["CommandId"]];
jobId = submit["JobId"];

statusCmd = SourceVaultSendServiceCommand[
  "WebJobStatus",
  <|"JobId" -> jobId|>
];

status = SourceVaultServiceCommandResult[statusCmd["CommandId"]];

resultCmd = SourceVaultSendServiceCommand[
  "WebJobResult",
  <|"JobId" -> jobId|>
];

result = SourceVaultServiceCommandResult[resultCmd["CommandId"]];
```

LM Studio からは remote MCP endpoint 経由で呼ぶ。

```text
LM Studio
→ sourcevault_submit_web_search
→ sourcevault_job_status
→ sourcevault_job_result
```

---

## 22. 結論

v6 の最重要修正は、次の4点である。

```text
1. root 解決層の移設は bootstrap 分離で行い、SourceVault.wl の自己ロード順序を壊さない。
2. 依存監査は推移閉包で行い、core へ流入する symbol 一覧を Phase 0 の成果物にする。
3. injected roots は service start 時点の snapshot とし、root 変更は service restart / reload で反映する。
4. SourceVaultSetRoot はデータ移行を行わない設定変更 API として明示する。
```

これにより、v5 の方針を維持しつつ、root resolver を core へ移す際のロード順序衝突、依存範囲の過小評価、service 稼働中の root 設定不一致、root 変更時のデータ移行誤解を防ぐ。

仕様レビュー上の主要論点は v6 でほぼ収束した。  
次の作業は、追加の机上仕様変更ではなく、Phase 0 の実コード依存監査と小規模 prototype である。
