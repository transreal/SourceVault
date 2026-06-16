# SourceVault_mcp API Reference

パッケージ: `SourceVault`` | リポジトリ: https://github.com/transreal/SourceVault_mcp

MCP JSON-RPC のスキーマ定義・ディスパッチ・provenance 付与を担う WL 側補助ライブラリ。HTTP/JSON-RPC transport は Python proxy 側が担い、proxy はファイルコマンドキュー経由で service kernel に渡し、service が `SourceVaultMCPDispatch` を呼ぶ。FrontEnd/Notebook/NBAccess 非依存。結果は JSON 安全 (string/assoc-of-string/list/bool)。

## 公開シンボル

### $SourceVaultMCPProtocolVersion
型: String, 初期値: "2024-11-05"
`initialize` レスポンスで返す MCP プロトコルバージョン。未設定時のみ初期値を代入する。

### SourceVaultMCPServerInfo[] → Association
`<|"name" -> "sourcevault", "version" -> "0.1.0"|>` を返す。

### SourceVaultMCPTools[] → List
MCP tool 定義 (name/description/inputSchema) の Association リストを返す。登録ツール: `sourcevault_web_search`, `sourcevault_submit_web_search`, `sourcevault_job_status`, `sourcevault_job_result`, `sourcevault_get_document`。

### SourceVaultMCPCallTool[name, args] → Association
tool を実行し MCP result `<|"content" -> {<|"type" -> "text", "text" -> "..."|>}, "isError" -> Bool|>` を返す。`name`: ツール名 (String)、`args`: 引数 Association。未知 tool は `"isError" -> True`。内部で `iMCPProvenance[args]` を生成し各 SourceVault 関数に provenance を渡す。`args["_mcpClient"]` をクライアント名に使用 (デフォルト `"LM Studio"`)。

### SourceVaultMCPDispatch[method, params] → Association
MCP JSON-RPC method を処理し JSON-RPC result 相当 Association を返す。`SourceVaultMCPDispatch[method]` は `params = <||>` として処理する。未知 method は `Failure["MCPMethodNotFound", <|"Method" -> method|>]` を返す (proxy が JSON-RPC error に変換する)。

method 対応表:
- `"initialize"` → `<|"protocolVersion" -> $SourceVaultMCPProtocolVersion, "capabilities" -> <|"tools" -> <||>|>, "serverInfo" -> SourceVaultMCPServerInfo[]|>`
- `"tools/list"` → `<|"tools" -> SourceVaultMCPTools[]|>`
- `"tools/call"` → `params["name"]` と `params["arguments"]` を取り出し `SourceVaultMCPCallTool` を呼ぶ。`arguments` が非 Association の場合は `<||>` を使う
- `"ping"` → `<||>`
- `"notifications/initialized"` → `<||>`

例: `SourceVaultMCPDispatch["tools/call", <|"name" -> "sourcevault_web_search", "arguments" -> <|"query" -> "Mathematica", "maxResults" -> 5|>|>]`

## MCP ツール仕様

`SourceVaultMCPCallTool` が dispatch する各ツールの引数・デフォルト・内部呼び出し。

### sourcevault_web_search
同期 Web 検索 (SearXNG 経由)。ページ本文は取得しない。
引数: `query` (String, 必須), `maxResults` (Integer, デフォルト 10)
内部: `SourceVaultWebSearch[query, "MaxResults"->maxResults, "RequestChannel"->"MCP", "InitiationType"->"MCPIngest", "Actor"->...]`
戻り値: 成功時 `"isError"->False`、テキストに件数と番号付きリスト (title/url/snippet 最大 200 文字)。失敗時 `"isError"->True`。

### sourcevault_submit_web_search
非同期 Web 検索ジョブを投入し `jobId` を返す。
引数: `query` (String, 必須), `maxResults` (Integer, デフォルト 10), `fetchPages` (Boolean, デフォルト false), `maxFetch` (Integer, デフォルト 3)
`fetchPages=true` の場合、上位ページを取得してクリーンテキスト化する。`maxFetch` は fetch するページ数上限。
内部: `SourceVaultWebSearchSubmit[<|"Query"->..., "MaxResults"->..., "FetchPages"->..., "MaxFetch"->..., "RequestChannel"->"MCP", "InitiationType"->"MCPIngest", "Actor"->..., "Provenance"->iMCPProvenance[args]|>]`
戻り値: `jobId` と初期ステータスを含むテキスト。結果は `sourcevault_job_result` で取得する。

### sourcevault_job_status
Web 検索ジョブのステータス確認。
引数: `jobId` (String, 必須)
内部: `SourceVaultWebJobStatus[jobId]`
戻り値: `"Job <jobId>: <status>"` テキスト (Queued/Running/Succeeded/Failed)。

### sourcevault_job_result
完了済みジョブの結果取得。
引数: `jobId` (String, 必須)
内部: `SourceVaultWebJobResult[jobId]`
戻り値: `Ready=False` の場合はステータスのみ。`Status="Failed"` の場合は `"isError"->True`。成功時は件数・番号付き結果リスト、`fetchPages` 使用時はドキュメントリスト (title/ExtractionStatus/CleanTextLength) を含むテキスト。

### sourcevault_get_document
スナップショット ref で保存済み WebDocument を取得。
引数: `snapshotRef` (String, 必須)
内部: `SourceVaultLoadImmutableSnapshot[snapshotRef]`
戻り値: 成功時 Url/Title/ContentHash/CleanTextLength/ExtractionStatus を含むテキスト。未発見時 `"isError"->True`。

## 内部ヘルパー (非公開)

`SourceVault``MCPPrivate`` コンテキスト内に定義される。直接呼び出し不可。

- `iMCPText[s]` — `<|"content"->{<|"type"->"text","text"->s|>},"isError"->False|>` を返す
- `iMCPError[s]` — 同形で `"isError"->True` を返す
- `iMCPFormatResults[results]` — 検索結果 Association リストを `"1. title\n   url\n   snippet"` 形式のテキストに整形
- `iMCPProvenance[args]` — `<|"InitiationType"->"MCPIngest","RequestChannel"->"MCP","UrlOrigin"->"SearchResult","UserSpecifiedUrl"->"Unknown","Actor"-><|"Type"->"MCPClient","ClientName"->args["_mcpClient"]|>|>` を生成。`_mcpClient` 未指定時は `"LM Studio"`