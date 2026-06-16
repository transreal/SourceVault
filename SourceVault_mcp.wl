(* ::Package:: *)

(* ============================================================
   SourceVault_mcp.wl -- MCP tool schema / dispatch / provenance helper

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_mcp.wl"]]

   仕様書: sourcevault_searxng_mcp_spec_v6.md §13, §14

   位置づけ (spec v6 §14.6):
     SourceVault_mcp.wl は MCP protocol endpoint ではない。WL 側補助ライブラリであり、
     - MCP tool schema 定義
     - tools/list / tools/call / initialize の dispatch
     - argument validation / provenance 付与
     を担う。実際の HTTP / JSON-RPC transport は Python proxy 側 (Increment 6b) に置く。
     proxy は HTTP POST /mcp で受けた JSON-RPC を file command queue 経由で
     service kernel に渡し、service が SourceVaultMCPDispatch を呼ぶ。

   service-loadable 制約: FrontEnd / Notebook / NBAccess 非依存。
   結果は JSON 安全 (string / assoc-of-string / list / bool) に保つ。
   ============================================================ *)

BeginPackage["SourceVault`"]

SourceVaultMCPDispatch::usage =
  "SourceVaultMCPDispatch[method, params] は MCP JSON-RPC の method (initialize/tools/list/\n" <>
  "tools/call/ping) を処理し、JSON-RPC result に相当する Association を返す。\n" <>
  "未知 method は Failure[\"MCPMethodNotFound\", ...] (proxy が JSON-RPC error に変換)。";

SourceVaultMCPTools::usage =
  "SourceVaultMCPTools[] は MCP tool 定義 (name/description/inputSchema) のリストを返す。";

SourceVaultMCPCallTool::usage =
  "SourceVaultMCPCallTool[name, args] は tool を実行し MCP result <|\"content\",\"isError\"|> を返す。";

SourceVaultMCPServerInfo::usage =
  "SourceVaultMCPServerInfo[] は MCP serverInfo (<|\"name\",\"version\"|>) を返す。";

$SourceVaultMCPProtocolVersion::usage =
  "$SourceVaultMCPProtocolVersion は initialize で返す MCP protocol version。";

Begin["`MCPPrivate`"]

If[! StringQ[SourceVault`$SourceVaultMCPProtocolVersion],
  SourceVault`$SourceVaultMCPProtocolVersion = "2024-11-05"];

SourceVaultMCPServerInfo[] := <|"name" -> "sourcevault", "version" -> "0.1.0"|>;

(* ---- tool 定義 (JSON Schema inputSchema) ---- *)
SourceVaultMCPTools[] := {
  <|"name" -> "sourcevault_web_search",
    "description" -> "Search the local web via SearXNG and return candidate results " <>
      "(title, url, snippet). Does NOT fetch page bodies. Use for quick lookups.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "query" -> <|"type" -> "string", "description" -> "Search query."|>,
        "maxResults" -> <|"type" -> "integer", "description" -> "Max results (default 10)."|>|>,
      "required" -> {"query"}|>|>,
  <|"name" -> "sourcevault_submit_web_search",
    "description" -> "Submit an asynchronous web search job. Optionally fetch and clean-text " <>
      "the top results (fetchPages). Returns a jobId; poll with sourcevault_job_status / " <>
      "sourcevault_job_result.",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|
        "query" -> <|"type" -> "string", "description" -> "Search query."|>,
        "maxResults" -> <|"type" -> "integer", "description" -> "Max search results (default 10)."|>,
        "fetchPages" -> <|"type" -> "boolean", "description" -> "Fetch & clean-text top pages (default false)."|>,
        "maxFetch" -> <|"type" -> "integer", "description" -> "Max pages to fetch when fetchPages (default 3)."|>|>,
      "required" -> {"query"}|>|>,
  <|"name" -> "sourcevault_job_status",
    "description" -> "Get the status of a web search job (Queued/Running/Succeeded/Failed).",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|"jobId" -> <|"type" -> "string", "description" -> "Job id from submit."|>|>,
      "required" -> {"jobId"}|>|>,
  <|"name" -> "sourcevault_job_result",
    "description" -> "Get the result of a completed web search job (results + fetched documents).",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|"jobId" -> <|"type" -> "string", "description" -> "Job id from submit."|>|>,
      "required" -> {"jobId"}|>|>,
  <|"name" -> "sourcevault_get_document",
    "description" -> "Load a stored WebDocument by snapshot ref (returns url, title, clean-text length, hash).",
    "inputSchema" -> <|"type" -> "object",
      "properties" -> <|"snapshotRef" -> <|"type" -> "string", "description" -> "WebDocument snapshot ref."|>|>,
      "required" -> {"snapshotRef"}|>|>
  };

(* ---- text content helper ---- *)
iMCPText[s_String] := <|"content" -> {<|"type" -> "text", "text" -> s|>}, "isError" -> False|>;
iMCPError[s_String] := <|"content" -> {<|"type" -> "text", "text" -> s|>}, "isError" -> True|>;

iMCPFormatResults[results_List] := StringRiffle[
  MapIndexed[Function[{r, i},
    ToString[First[i]] <> ". " <> ToString @ Lookup[r, "Title", ""] <> "\n   " <>
      ToString @ Lookup[r, "Url", ""] <> "\n   " <>
      StringTake[ToString @ Lookup[r, "Snippet", ""], UpTo[200]]],
    results], "\n"];

(* MCP 経由の最小 provenance (spec v6 §9.3) *)
iMCPProvenance[args_Association] := <|
  "InitiationType" -> "MCPIngest",
  "RequestChannel" -> "MCP",
  "UrlOrigin" -> "SearchResult",
  "UserSpecifiedUrl" -> "Unknown",
  "Actor" -> <|"Type" -> "MCPClient",
    "ClientName" -> Lookup[args, "_mcpClient", "LM Studio"]|>|>;

(* ---- tool 実行 ---- *)
SourceVaultMCPCallTool[name_String, args_Association] := Module[{prov, r},
  prov = iMCPProvenance[args];
  Switch[name,
    "sourcevault_web_search",
      r = SourceVault`SourceVaultWebSearch[Lookup[args, "query", ""],
        "MaxResults" -> Lookup[args, "maxResults", 10],
        "RequestChannel" -> "MCP", "InitiationType" -> "MCPIngest",
        (* SearchRun の監査記録に MCP クライアント識別を残す (Actor=MCPClient) *)
        "Actor" -> Lookup[prov, "Actor", Automatic]];
      If[FailureQ[r], iMCPError["Search failed: " <> ToString[r]],
        iMCPText["Found " <> ToString @ Lookup[r, "ResultCount", 0] <> " results for \"" <>
          Lookup[args, "query", ""] <> "\":\n\n" <> iMCPFormatResults[Lookup[r, "Results", {}]]]],
    "sourcevault_submit_web_search",
      r = SourceVault`SourceVaultWebSearchSubmit[<|
        "Query" -> Lookup[args, "query", ""],
        "MaxResults" -> Lookup[args, "maxResults", 10],
        "FetchPages" -> TrueQ[Lookup[args, "fetchPages", False]],
        "MaxFetch" -> Lookup[args, "maxFetch", 3],
        "RequestChannel" -> "MCP", "InitiationType" -> "MCPIngest",
        (* SearchRun にも MCP Actor を通す ("Actor" は SourceVaultWebSearch のオプションなので
           iWebRunSearchJob の FilterRules で SearchRun の provenance に乗る)。
           "Provenance" は文書 fetch (WebDocument) 側の provenance。 *)
        "Actor" -> Lookup[prov, "Actor", Automatic],
        "Provenance" -> prov|>];
      If[! AssociationQ[r], iMCPError["Submit failed: " <> ToString[r]],
        iMCPText["Submitted job " <> ToString @ Lookup[r, "JobId", "?"] <>
          " (status: " <> ToString @ Lookup[r, "Status", "?"] <>
          "). Use sourcevault_job_result with this jobId to get results."]],
    "sourcevault_job_status",
      r = SourceVault`SourceVaultWebJobStatus[Lookup[args, "jobId", ""]];
      iMCPText["Job " <> ToString @ Lookup[r, "JobId", "?"] <> ": " <> ToString @ Lookup[r, "Status", "?"]],
    "sourcevault_job_result",
      r = SourceVault`SourceVaultWebJobResult[Lookup[args, "jobId", ""]];
      Which[
        ! TrueQ[Lookup[r, "Ready", False]],
          iMCPText["Job not ready: " <> ToString @ Lookup[r, "Status", "?"]],
        Lookup[r, "Status", ""] === "Failed",
          iMCPError["Job failed: " <> ToString @ Lookup[r, "FailureReason", "?"]],
        True,
          Module[{res = Lookup[r, "Result", <||>], docs},
            docs = Lookup[res, "Documents", {}];
            iMCPText["Results (" <> ToString @ Lookup[res, "ResultCount", 0] <> "):\n\n" <>
              iMCPFormatResults[Lookup[res, "Results", {}]] <>
              If[docs =!= {},
                "\n\nFetched documents (" <> ToString[Length[docs]] <> "):\n" <>
                  StringRiffle[Function[d,
                    "- " <> ToString @ Lookup[d, "Title", Lookup[d, "Url", "?"]] <> " [" <>
                    ToString @ Lookup[d, "ExtractionStatus", "?"] <> ", " <>
                    ToString @ Lookup[d, "CleanTextLength", 0] <> " chars]"] /@ docs, "\n"],
                ""]]]],
    "sourcevault_get_document",
      r = SourceVault`SourceVaultLoadImmutableSnapshot[Lookup[args, "snapshotRef", ""]];
      If[! AssociationQ[r], iMCPError["Document not found: " <> ToString @ Lookup[args, "snapshotRef", ""]],
        iMCPText["WebDocument:\n  Url: " <> ToString @ Lookup[r, "Url", "?"] <>
          "\n  Title: " <> ToString @ Lookup[r, "Title", ""] <>
          "\n  ContentHash: " <> ToString @ Lookup[r, "ContentHash", "?"] <>
          "\n  CleanTextLength: " <> ToString @ Lookup[r, "CleanTextLength", 0] <>
          "\n  ExtractionStatus: " <> ToString @ Lookup[r, "ExtractionStatus", "?"]]],
    _,
      iMCPError["Unknown tool: " <> name]
  ]];

(* ---- JSON-RPC method dispatch ---- *)
SourceVaultMCPDispatch[method_String, params_Association] := Switch[method,
  "initialize",
    <|"protocolVersion" -> SourceVault`$SourceVaultMCPProtocolVersion,
      "capabilities" -> <|"tools" -> <||>|>,
      "serverInfo" -> SourceVaultMCPServerInfo[]|>,
  "tools/list",
    <|"tools" -> SourceVaultMCPTools[]|>,
  "tools/call",
    SourceVaultMCPCallTool[Lookup[params, "name", ""],
      With[{a = Lookup[params, "arguments", <||>]}, If[AssociationQ[a], a, <||>]]],
  "ping",
    <||>,
  "notifications/initialized",
    <||>,
  _,
    Failure["MCPMethodNotFound", <|"Method" -> method|>]
];
SourceVaultMCPDispatch[method_String] := SourceVaultMCPDispatch[method, <||>];

End[]  (* `MCPPrivate` *)

EndPackage[]  (* SourceVault` *)
