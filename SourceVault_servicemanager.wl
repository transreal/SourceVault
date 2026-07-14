(* ::Package:: *)

(* ============================================================
   SourceVault_servicemanager.wl -- SourceVault 検索拡張 (control / channel plane)

   This file is encoded in UTF-8.
   Load via: Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_servicemanager.wl"]]

   仕様書: sourcevault_websearch_extension_spec_v0_10.md

   load order (§2.4): SourceVault.wl -> SourceVault_core.wl
                      -> SourceVault_searchindex.wl -> SourceVault_servicemanager.wl
   依存: SourceVault_core.wl, SourceVault_searchindex.wl。

   本ファイルが担当する範囲 (段階実装。今回の増分 = Phase 1 control 側):
     - private local init 読み込み (§5.2, §5.3)
     - service / endpoint / credential profile registry (§5.3, §9.x, §16.8)
     - personal config doctor (§5.5)
   後続増分 (Phase 2+): detached WolframScript service 起動・停止・監視、
            manifest、heartbeat、command queue、WebServer route、channel adapter、
            ActionGate、ServiceVersionSnapshot active pointer、version switch / rollback。

   非衝突方針: private helper は SourceVault`ServiceManagerPrivate` 文脈に置く。
   ============================================================ *)

BeginPackage["SourceVault`"]

(* ---- local init / config (§5.2, §5.3) ---- *)
SourceVaultLocalConfigRoot::usage =
  "SourceVaultLocalConfigRoot[] は private local config directory (<PrivateVault>/config/local) を返す。";
SourceVaultLoadLocalInit::usage =
  "SourceVaultLoadLocalInit[opts] は <PrivateVault>/config/local/SourceVaultLocalInit.wl を読み込む。\n" <>
  "存在しなければ fail-closed せず NotFound を返す (推測 fallback はしない)。\n" <>
  "オプション: \"Path\" -> 明示パス。";
SourceVaultLocalConfigStatus::usage =
  "SourceVaultLocalConfigStatus[] は local init の有無と登録済み profile の summary を返す。";
SourceVaultLocalConfigDoctor::usage =
  "SourceVaultLocalConfigDoctor[opts] は必須 registry (release context / backend / endpoint) が\n" <>
  "登録済みかを点検し、不足を報告する。";

(* ---- service / endpoint / channel registry (§5.3, §9.x, §16.8) ---- *)
SourceVaultRegisterWebServiceEndpoint::usage =
  "SourceVaultRegisterWebServiceEndpoint[name, spec] は WebService endpoint を登録する。\n" <>
  "spec 必須: \"BindAddress\", \"Port\"。";
SourceVaultResolveWebServiceEndpoint::usage =
  "SourceVaultResolveWebServiceEndpoint[name] は endpoint を解決する。未登録なら fail-closed。";
SourceVaultRegisterChannelEndpoint::usage =
  "SourceVaultRegisterChannelEndpoint[name, spec] は mail/Discord 等の channel endpoint を登録する。";
SourceVaultRegisterVoiceBackend::usage =
  "SourceVaultRegisterVoiceBackend[name, spec] は STT/TTS/realtime voice backend を登録する。";
SourceVaultRegisterVRSNSAdapter::usage =
  "SourceVaultRegisterVRSNSAdapter[name, spec] は VRSNS adapter を登録する。";
SourceVaultRegisterCapabilityProfile::usage =
  "SourceVaultRegisterCapabilityProfile[name, spec] は avatar/world capability profile を登録する。";
SourceVaultRegisterLLMBackend::usage =
  "SourceVaultRegisterLLMBackend[name, spec] は headless LLM backend を登録する (§16.9.1)。\n" <>
  "既定は API 直叩き / trusted local server。CLI は HeadlessSafe test 合格時のみ。";
SourceVaultRegisterCaptureSource::usage =
  "SourceVaultRegisterCaptureSource[name, spec] は audio/camera/screen capture source を登録する (§17.3)。\n" <>
  "DeviceRef / WindowRef は symbolic ref とし、実デバイス名は private local init で解決する。";
SourceVaultRegisterOutputAdapter::usage =
  "SourceVaultRegisterOutputAdapter[name, spec] は Discord 等の output adapter を登録する (§17.9)。";
SourceVaultResolveServiceProfile::usage =
  "SourceVaultResolveServiceProfile[kind, name] は ServiceManager registry の profile を解決する。\n" <>
  "kind: \"WebServiceEndpoint\"/\"ChannelEndpoint\"/\"VoiceBackend\"/\"VRSNSAdapter\"/\"CapabilityProfile\"/\"LLMBackend\"/\"CaptureSource\"/\"OutputAdapter\"。";
SourceVaultListServiceProfiles::usage =
  "SourceVaultListServiceProfiles[] は ServiceManager registry の summary を返す。kind 指定で名前リスト。";
SourceVaultClearServiceRegistry::usage =
  "SourceVaultClearServiceRegistry[] は ServiceManager registry を消去する (test / 再 init 用)。";

(* ---- personal config doctor (§5.5) ---- *)
SourceVaultNoPersonalConfigDoctor::usage =
  "SourceVaultNoPersonalConfigDoctor[filesOrDirs, opts] は repository / 配布対象に個人情報・環境依存値が\n" <>
  "混入していないか検査する。検出: IPv4 literal (octet 検証), localhost:port, Windows/macOS user path,\n" <>
  "credential らしき token, 実 mail address, private vault root。\n" <>
  "オプション: \"MailAllowlist\" -> {...}, \"Extensions\" -> {\".wl\",...}, \"Mask\" -> True。\n" <>
  "ファイル先頭付近に doctor:private-design-doc マーカーがある file は検査対象外。\n" <>
  "戻り値 <|\"Status\" -> \"OK\"|\"FindingsFound\", \"Findings\" -> {...}, \"FilesScanned\"|>。";

(* ---- detached service lifecycle (§9.3-9.6, §17.8。Phase 2) ---- *)
SourceVaultStartService::usage =
  "SourceVaultStartService[serviceId, opts] は detached WolframScript service を起動する。\n" <>
  "メイン Mathematica を終了しても service process は heartbeat を更新し続ける。\n" <>
  "オプション: \"Kind\" -> \"heartbeat\" (既定), \"HeartbeatIntervalSeconds\" -> 1, \"PackageRoot\" -> Automatic。\n" <>
  "戻り値 <|\"Status\", \"ServiceId\", \"PID\", \"RuntimeDir\"|>。";
SourceVaultStopService::usage =
  "SourceVaultStopService[serviceId, opts] は Stop command を queue に入れ、必要なら pid 検証後に kill する。";
SourceVaultRestartService::usage =
  "SourceVaultRestartService[serviceId, opts] は stop してから同 profile で start する。";
SourceVaultServiceStatus::usage =
  "SourceVaultServiceStatus[serviceId] は pid.json / status.json / heartbeat.json から状態 association を返す。";
SourceVaultServiceHealth::usage =
  "SourceVaultServiceHealth[serviceId] は heartbeat の鮮度から OK/Degraded/Failing を返す。";
$SourceVaultHealthThresholds::usage =
  "$SourceVaultHealthThresholds は health 判定閾値の単一定義 (hardening 02: スタック全体で統一)。\n" <>
  "<|\"OKSeconds\"->15, \"DegradedSeconds\"->60, \"WatchdogStaleSeconds\"->90, ...|>。\n" <>
  "WL 側 (SourceVaultServiceStatus/Health)・watchdog PS1・Python proxy health() の全てが\n" <>
  "この値から生成/参照される。生成物 (watchdog.ps1 / proxy config.json) への反映には\n" <>
  "watchdog 再インストール / proxy 再起動が必要。";
SourceVaultInstallWatchdog::usage =
  "SourceVaultInstallWatchdog[serviceId, opts] は軽量 PowerShell ウォッチドッグを常駐起動する。\n" <>
  "wscript の hidden launcher 経由で一度だけ起動し、以後は PowerShell 内の while ループで自前 sleep し\n" <>
  "終了せず常駐する (周期 scheduled task をやめたのでコンソール窓が前面に出るフリッカは発生しない)。\n" <>
  "WL カーネルを spawn せず (ライセンス/電力配慮)、heartbeat 失効 (既定 90s) or crash を検知すると、wedge ログを\n" <>
  "stdout.wedge-*.log へ退避し pid を kill して既存サービスタスクを再実行 (run.wls 再利用=root 再注入なし) する。\n" <>
  "意図停止 (status.State=Stopped) は復活させない。多重常駐は named mutex で 1 本に抑止する。\n" <>
  "オプション \"StaleSeconds\" -> 90 (失効秒), \"IntervalMinutes\" -> 2 (ループの巡回間隔)。";
SourceVaultUninstallWatchdog::usage =
  "SourceVaultUninstallWatchdog[serviceId] は watchdog scheduled task を削除し、常駐 PowerShell プロセスも kill する。";
SourceVaultWatchdogStatus::usage =
  "SourceVaultWatchdogStatus[serviceId] は watchdog task 登録の有無・常駐プロセスの生存 (ProcessAlive)・" <>
  "watchdog.log.jsonl の再起動履歴を返す。";
SourceVaultServiceRootHealth::usage =
  "SourceVaultServiceRootHealth[serviceId] は service の root/ユーザが main kernel と整合しているかを返す\n" <>
  "(spec v6 §3.6/§3.10)。<|RootHashMatch, MainRootHash, ServiceRootHash, UserMatch, MainUser,\n" <>
  "ServiceUser, LocalStatePath, LocalStateWritable, CoreRootPath, Warnings, Healthy|>。\n" <>
  "RootHashMismatch は root 変更後の未再起動、UserMismatch は %LOCALAPPDATA% 分裂の恐れを示す。";
SourceVaultServicePing::usage =
  "SourceVaultServicePing[serviceId, opts] は Ping command を送り、command queue 経由で Pong を待つ。";

SourceVaultServiceHealthDetail::usage =
  "SourceVaultServiceHealthDetail[serviceId] は health の判定内訳を返す (hardening 02 Inc3)。\n" <>
  "<|\"Health\", \"Layer\"->\"L2\"|\"L3\"|\"L1\", \"Ping\"-><|\"L2\",\"RTTms\"...|>, \"Base\"|>。\n" <>
  "L2 = command queue が実際に応答 (真の生存証明)。L3 = heartbeat 進行のみ。\n" <>
  "ping は " <> "PingIntervalSeconds キャッシュ (health 連打で queue を叩かない)。";

$SourceVaultHealthRequireL2::usage =
  "$SourceVaultHealthRequireL2 (既定 False) — True にすると SourceVaultServiceHealth の \"OK\" は\n" <>
  "L2 (Ping 応答) 必須になる。heartbeat が進むのに queue 不応答 (busy/wedge) は \"Degraded\"。\n" <>
  "移行期は False で L3 OK を許す (spec 02 §3.2)。";
SourceVaultListServices::usage =
  "SourceVaultListServices[] は runtime/services 配下の service とその状態を返す。";
SourceVaultListRuntimeMachines::usage =
  "SourceVaultListRuntimeMachines[] は、この共有 vault を実際に使っている PC の machine tag 一覧を返す。\n" <>
  "根拠は runtime/ ツリー: 各 PC は services/proxies を runtime/<machineTag>/ 配下に namespacing するため、\n" <>
  "runtime/ 直下のサブディレクトリのうち共有/レガシー予約名 (locks / proxies / services) を除いたものが実 PC。\n" <>
  "自機 tag は runtime dir が未生成でも必ず含める。手動レジストリ (diagnostics/machines) ではなく実在の\n" <>
  "runtime を正本とするので、登録漏れや古いテストエントリ (実在しない PC 名) を返さない。\n" <>
  "オプション \"Details\" -> True で <|MachineTag, IsSelf, HasServices, HasProxies|> の一覧を返す。";
SourceVaultServiceLogs::usage =
  "SourceVaultServiceLogs[serviceId, opts] は service.log.jsonl の event を返す。オプション \"Limit\"。";
SourceVaultTailServiceLog::usage =
  "SourceVaultTailServiceLog[serviceId, n:20] は service.log.jsonl の末尾 n 件を返す。";
SourceVaultSendServiceCommand::usage =
  "SourceVaultSendServiceCommand[serviceId, command] は command (Association, \"Command\" key 必須) を queue に書く。\n" <>
  "戻り値 <|\"Status\", \"CommandId\"|>。";
SourceVaultServiceCommandResult::usage =
  "SourceVaultServiceCommandResult[serviceId, commandId] は処理済み command の結果を返す (未処理なら Pending)。";
SourceVaultRecoverServices::usage =
  "SourceVaultRecoverServices[opts] は status Running だが pid が死んでいる孤児 service を Crashed に更新する。\n" <>
  "オプション \"Kill\" -> True で pid 同一性確認後に kill。";
SourceVaultServiceDoctor::usage =
  "SourceVaultServiceDoctor[serviceId] は runtime dir / pid / heartbeat / status の整合を点検する。";
SourceVaultServiceMain::usage =
  "SourceVaultServiceMain[kind, serviceId, opts] は detached service process 側の runner entrypoint。\n" <>
  "generated run.wls から呼ばれる。pid/status/heartbeat を書き、command queue を処理し、Stop で終了する。\n" <>
  "メインカーネルからは直接呼ばない (StartService 経由)。";
SourceVaultServiceRuntimeDir::usage =
  "SourceVaultServiceRuntimeDir[serviceId] は service の runtime directory を返す。";

(* ---- Python HTTP リバースプロキシ (SocketListen が headless で不可なための edge)。
   proxy code は SourceVault data として保存し、起動時に working へ materialize + digest 検証して実行する ---- *)
$SourceVaultPython::usage =
  "$SourceVaultPython は python 実行ファイルの override。Automatic で PATH 上の python3/python を解決する。";
SourceVaultPublishProxyCodeSnapshot::usage =
  "SourceVaultPublishProxyCodeSnapshot[opts] は組込みの proxy Python ソースを immutable snapshot (SourceVaultProxyCode) として vault に保存する。\n" <>
  "戻り値 <|\"Status\", \"Ref\", \"Digest\", \"CodeSHA256\"|>。alias \"sv-http-proxy\"。";
SourceVaultMaterializeProxyCode::usage =
  "SourceVaultMaterializeProxyCode[targetDir, opts] は proxy code を targetDir/proxy.py へ出力する。\n" <>
  "opts \"CodeRef\" -> snapshot ref | Automatic (組込みソース)。出力後に SHA256 を検証し不一致なら fail-closed。";
SourceVaultStartHTTPProxy::usage =
  "SourceVaultStartHTTPProxy[serviceId, opts] は serviceId の WL service を front する Python HTTP proxy を detached 起動する。\n" <>
  "proxy.py を vault data から materialize+digest検証し、stdlib のみで /sv/health /sv/search /sv/admin/status を提供する。\n" <>
  "必須 opts \"Port\" (または \"EndpointProfile\")。任意 \"RoutePrefix\"(既定/sv) \"ReleaseContext\" \"PDFIndexProfile\" \"Bind\"(既定127.0.0.1) \"CodeRef\"。\n" <>
  "gate は WL service 側。proxy は status/heartbeat の直読みと command queue 中継のみで raw vault を公開しない。";
SourceVaultStopHTTPProxy::usage =
  "SourceVaultStopHTTPProxy[serviceId] は Python proxy を停止し scheduled task を削除する。";
SourceVaultHTTPProxyStatus::usage =
  "SourceVaultHTTPProxyStatus[serviceId] は proxy の pid / 生存 / port を返す。";
SourceVaultProxyRuntimeDir::usage =
  "SourceVaultProxyRuntimeDir[serviceId] は proxy の runtime directory を返す。";

(* ---- MCP サーバ起動/停止の便利ラッパー (WL service + HTTP/MCP proxy を一括制御) ---- *)
SourceVaultStartMCP::usage =
  "SourceVaultStartMCP[opts] は MCP サーバ (WL service + HTTP/MCP proxy) を一括起動する。\n" <>
  "WL service を確保し、/sv/mcp を公開する Python proxy を起動する。\n" <>
  "オプション \"ServiceId\"(既定 $SourceVaultMCPServiceId)/\"Port\"/\"MCPToken\"/\"RestartService\"(既定 False)。\n" <>
  "Port/MCPToken は Automatic なら既存サービスの proxy.config.json から自動解決 (env 依存値を直書きしない)。\n" <>
  "戻り値 <|Status, ServiceId, Port, Url, Service, Proxy|>。";
SourceVaultStopMCP::usage =
  "SourceVaultStopMCP[opts] は MCP の proxy と WL service を停止する。オプション \"ServiceId\"。";
SourceVaultMCPRunningQ::usage =
  "SourceVaultMCPRunningQ[opts] は MCP proxy が実際に到達可能か (proxy の /health へ HTTP 接続成功) を\n" <>
  "True/False で返す。pid 生存だけに頼らないので stale/再利用 pid でも誤検知しない。オプション \"ServiceId\"。";
SourceVaultMCPStatus::usage =
  "SourceVaultMCPStatus[opts] は MCP の状態と公開 URL を返す。\"Running\" は実到達性 (/health 接続成功)、\n" <>
  "\"ProxyState\"/\"ProxyPidAlive\" は pid ベース。両者が食い違う (PidAlive だが Running 偽) なら stale/再利用 pid。\n" <>
  "オプション \"ServiceId\"。";
$SourceVaultMCPServiceId::usage =
  "$SourceVaultMCPServiceId は MCP サーバの既定 serviceId (既定 \"sourcevault\")。";
$SourceVaultMCPPort::usage =
  "$SourceVaultMCPPort は MCP proxy の既定ポート (既定 Automatic=既存 proxy.config.json から解決、無ければ 8731)。\n" <>
  "整数を設定すれば固定。SearXNG(8888)/LM Studio(1234) と衝突しない値にする。";
$SourceVaultMCPToken::usage =
  "$SourceVaultMCPToken は /sv/mcp の既定トークン (既定 Automatic=既存設定から解決、無ければ None=localhost 無認証)。\n" <>
  "文字列なら X-SourceVault-Token で要求する。";
$SourceVaultServiceWLMCPEnabled::usage =
  "$SourceVaultServiceWLMCPEnabled は Wolfram AgentTools MCP (/wl/mcp) を SourceVault サービスに\n" <>
  "集約する機能のトグル。Automatic (既定) = serviceId \"sourcevault\" のみ有効 / True = 常に / False = 無効。\n" <>
  "有効時、サービスは起動時に永続サブカーネル (サブプロセス枠。プロセス席を消費しない) を温め、\n" <>
  "proxy の /wl/mcp への JSON-RPC を AgentTools handleMethod で処理する (旧 wlmcp-gateway の\n" <>
  "専用 StartMCPServer カーネル = 独立プロセス 1 席を置換)。評価はサブカーネル内 (非ブロッキング・\n" <>
  "資格情報カーネルから隔離)。状態確認は command \"WLMCPStatus\"。";

(* ---- channel pipeline / mail / Discord / OutputGate (§9.8, §13 Phase 6, §17.9) ---- *)
SourceVaultMakeQuestionEnvelope::usage =
  "SourceVaultMakeQuestionEnvelope[channel, inputText, opts] は統一入力 QuestionEnvelope を作る (§9.8)。\n" <>
  "channel: \"Web\"|\"Mail\"|\"Discord\"|\"Voice\"|\"VRSNS\"。必須 opts \"ReleaseContext\"。\n" <>
  "任意 \"Audience\" \"LatencyProfile\" \"AllowedIndexes\"->{...} \"PDFIndexProfile\" \"Requester\"。";
SourceVaultAnswerChannelQuery::usage =
  "SourceVaultAnswerChannelQuery[envelope, opts] は envelope を検索→evidence draft 化する。\n" <>
  "gate 済み SourceVaultSearch を使い、Mail は NeedsHumanReview (draft のみ)、Discord は低 risk のみ Answered。\n" <>
  "LLM は呼ばない (evidence ベース)。戻り値 <|\"Decision\", \"AnswerDraft\", \"Evidence\", \"Citations\", ...|>。";
SourceVaultMakeMailReplyDraft::usage =
  "SourceVaultMakeMailReplyDraft[envelope, opts] は mail 返信 draft を作る。自動送信は一切しない (§13 Phase 6)。";
SourceVaultEvaluateOutputGate::usage =
  "SourceVaultEvaluateOutputGate[draft, outputAdapter, opts] は出力可否を判定する (§17.9)。\n" <>
  "戻り値 Decision: \"Permit\"|\"NeedsApproval\"|\"Deny\"|\"RedactRequired\"。\n" <>
  "判定: adapter の PrivacyMax / ReleaseContextRequired / AllowedEventKinds / RequireApproval / raw media。";
SourceVaultDispatchOutput::usage =
  "SourceVaultDispatchOutput[draft, outputAdapter, opts] は OutputGate を通してから出力する。\n" <>
  "mail は送信せず draft を返す。Discord は gate Permit かつ opts \"Approved\"->True かつ \"ReallySend\"->True の時のみ webhook 送信。\n" <>
  "既定は送信せず Prepared / NeedsApproval を返す (fail-safe)。";

(* ---- ActionDraft / ActionGate (VRSNS avatar・world action 安全制御, §9.9, §16.2) ---- *)
SourceVaultMakeActionDraft::usage =
  "SourceVaultMakeActionDraft[kind, payload, opts] は ActionDraft を作る (§9.9)。\n" <>
  "kind: \"Speak\"|\"Gesture\"|\"Expression\"|\"Move\"|\"ShowPanel\"|\"CallTool\"。\n" <>
  "opts \"CapabilityProfile\", \"Audience\", \"ReleaseContext\", \"Target\", \"EvidenceRefs\"。";
SourceVaultEvaluateActionGate::usage =
  "SourceVaultEvaluateActionGate[actionDraft, opts] は capability profile に基づき action 可否を判定する (§9.9)。\n" <>
  "戻り値 Decision: \"Permit\"|\"RequiresApproval\"|\"Deny\"。world 変更 (Move/CallTool) は AllowWorldControl が無ければ Deny。";
SourceVaultListCaptureSources::usage = "SourceVaultListCaptureSources[] は登録済み capture source を返す。";
SourceVaultTestCaptureSource::usage =
  "SourceVaultTestCaptureSource[name] は capture source profile の解決可否を fail-closed で点検する (実 capture はしない)。";

(* ---- マルチモーダル ingest / live session / multimodal service (§17。Phase 7b) ---- *)
SourceVaultIngestCapturedMedia::usage =
  "SourceVaultIngestCapturedMedia[sessionId, kind, data, opts] は capture 由来データを vault に取り込む (§17.4, §17.11)。\n" <>
  "data が ByteArray なら content-addressed blob に commit (PersistRaw->True 時)、String なら Text として記録。\n" <>
  "MultimodalEvent を append。実 ffmpeg/ASR driver はこの関数を呼ぶ (device 非依存の取込点)。\n" <>
  "opts \"PersistRaw\"(既定True), \"SourceRef\", \"Tags\", \"State\", \"PrivacyLevel\"。";
SourceVaultUpdateLiveSummary::usage =
  "SourceVaultUpdateLiveSummary[sessionId, summary] は live summary pointer を更新し SystemSummary event を残す (§17.6)。";
SourceVaultGetLiveSummary::usage = "SourceVaultGetLiveSummary[sessionId] は現在の live summary を返す。";
SourceVaultGetLiveEvents::usage = "SourceVaultGetLiveEvents[sessionId, opts] は session の MultimodalEvent を返す (§17.7)。";
SourceVaultGetLiveTranscript::usage = "SourceVaultGetLiveTranscript[sessionId] は session の ASR transcript を連結して返す。";
SourceVaultAskLiveSession::usage =
  "SourceVaultAskLiveSession[sessionId, question, opts] は UserQuestion を記録し command を enqueue する (§17.7)。\n" <>
  "メインカーネルは LLM を直接呼ばず、service 側が処理する。";
SourceVaultRegisterMultimodalWorkflow::usage =
  "SourceVaultRegisterMultimodalWorkflow[name, spec] は multimodal workflow (PresentationListenerCompat 等) を登録する (§17.6)。";
SourceVaultListMultimodalWorkflows::usage = "SourceVaultListMultimodalWorkflows[] は登録済み multimodal workflow を返す。";
SourceVaultSchedulePostprocess::usage =
  "SourceVaultSchedulePostprocess[sessionId, spec] は後処理 (ASRImprove/Summary/PurposeIndexBuild 等) を予約 event として記録する (§17.11)。";

(* ---- ServiceVersionSnapshot / version switching (§8.6-8.7, §8.14。Phase 4) ---- *)
SourceVaultCreateServiceVersionSnapshot::usage =
  "SourceVaultCreateServiceVersionSnapshot[serviceId, spec] は ServiceVersionSnapshot を immutable 保存する (§8.6)。\n" <>
  "spec は WorkflowSnapshotRef / CorpusSnapshotRef / IndexSnapshotRefs / ReleaseContextRef 等を持つ。\n" <>
  "credential / 実 path / IP を含めてはならない (profile ref のみ)。";
SourceVaultListServiceVersions::usage =
  "SourceVaultListServiceVersions[serviceId] は作成済み service version の {Version, Ref, CreatedAtUTC} を返す。";
SourceVaultServiceVersionInfo::usage =
  "SourceVaultServiceVersionInfo[serviceId, version] は指定 version の snapshot を返す (version 省略で active)。";
SourceVaultActivateServiceVersion::usage =
  "SourceVaultActivateServiceVersion[serviceId, versionOrRef, opts] は active service version を切り替える (§8.7)。\n" <>
  "digest 検証 + IndexSnapshotRefs の解決可能性を確認し、fail-closed。active pointer を pointer event で更新する。";
SourceVaultActiveServiceVersion::usage =
  "SourceVaultActiveServiceVersion[serviceId] は現在 active な service version ref を返す (pointer replay)。";
SourceVaultRollbackServiceVersion::usage =
  "SourceVaultRollbackServiceVersion[serviceId, opts] は一つ前の active version へ戻し、rollback log を残す。opts \"Reason\"。";
SourceVaultCompareServiceVersions::usage =
  "SourceVaultCompareServiceVersions[serviceId, v1, v2] は二つの service version snapshot の主要 ref 差分を返す。";

Begin["`ServiceManagerPrivate`"]

(* ============================================================
   local config root
   ============================================================ *)

iPrivateVaultRoot[] := Module[{r},
  r = SourceVault`$SourceVaultCoreRoot;
  If[! StringQ[r] || StringLength[r] == 0,
    r = Quiet @ SourceVault`$SourceVaultRoots["PrivateVault"]];
  If[StringQ[r] && StringLength[r] > 0, r, $Failed]
];

SourceVaultLocalConfigRoot[] := Module[{r = iPrivateVaultRoot[]},
  If[r === $Failed,
    Failure["PrivateVaultUnresolved", <|
      "MessageTemplate" -> "PrivateVault root が未解決です。"|>],
    FileNameJoin[{r, "config", "local"}]]
];

Options[SourceVaultLoadLocalInit] = {"Path" -> Automatic};
SourceVaultLoadLocalInit[OptionsPattern[]] := Module[{path, root},
  path = OptionValue["Path"];
  If[path === Automatic,
    root = SourceVaultLocalConfigRoot[];
    If[FailureQ[root], Return[root]];
    path = FileNameJoin[{root, "SourceVaultLocalInit.wl"}]];
  If[! FileExistsQ[path],
    Return[<|"Status" -> "NotFound", "Path" -> path,
      "Note" -> "private local init が無いため何も登録しません (fail-closed)。"|>]];
  Block[{$CharacterEncoding = "UTF-8"},
    Quiet[Check[Get[path],
      Return[<|"Status" -> "LoadError", "Path" -> path|>]]]];
  <|"Status" -> "Loaded", "Path" -> path|>
];

SourceVaultLocalConfigStatus[] := Module[{root, path, exists},
  root = SourceVaultLocalConfigRoot[];
  path = If[FailureQ[root], Missing[], FileNameJoin[{root, "SourceVaultLocalInit.wl"}]];
  exists = StringQ[path] && FileExistsQ[path];
  <|"Status" -> "OK", "LocalConfigRoot" -> root, "LocalInitPath" -> path,
    "LocalInitExists" -> exists,
    "SearchProfiles" -> Quiet @ SourceVault`SourceVaultListProfiles[],
    "ServiceProfiles" -> SourceVaultListServiceProfiles[]|>
];

(* ============================================================
   ServiceManager registry
   ============================================================ *)

If[! AssociationQ[$smRegistries], $smRegistries = <||>];

iSMKinds = {"WebServiceEndpoint", "ChannelEndpoint", "VoiceBackend", "VRSNSAdapter",
   "CapabilityProfile", "LLMBackend", "CaptureSource", "OutputAdapter"};

iSMRegister[kind_String, name_String, spec_Association] := (
  If[! KeyExistsQ[$smRegistries, kind], $smRegistries[kind] = <||>];
  $smRegistries[kind] = Append[$smRegistries[kind], name -> spec];
  <|"Status" -> "OK", "Kind" -> kind, "Name" -> name|>
);

iSMResolve[kind_String, name_String] := Module[{m = Lookup[$smRegistries, kind, <||>]},
  If[KeyExistsQ[m, name], m[name],
    Failure["UnregisteredProfile", <|
      "MessageTemplate" -> "`1` `2` は未登録です (fail-closed)。private local init で登録してください。",
      "MessageParameters" -> {kind, name}, "Kind" -> kind, "Name" -> name|>]]
];

iSMRequire[spec_Association, keys_List, kind_String, name_String] := Module[{missing},
  missing = Select[keys, ! KeyExistsQ[spec, #] &];
  If[missing === {}, Null,
    Failure["InvalidSpec", <|
      "MessageTemplate" -> "`1` `2`: 必須 field `3` が不足。",
      "Kind" -> kind, "Name" -> name, "Field" -> missing|>]]
];

SourceVaultRegisterWebServiceEndpoint[name_String, spec_Association] := Module[{chk},
  chk = iSMRequire[spec, {"BindAddress", "Port"}, "WebServiceEndpoint", name];
  If[FailureQ[chk], Return[chk]];
  iSMRegister["WebServiceEndpoint", name, spec]
];
SourceVaultResolveWebServiceEndpoint[name_String, opts___] :=
  iSMResolve["WebServiceEndpoint", name];

(* === §19: PDFGroupSearchProfile (configuration-as-data) ===
   ある PDF グループの検索 service 設定を一つの data object に束ねる。コードにドメイン固有を
   焼かず、profile を差し替えるだけで別 PDF グループの app を立ち上げられる。
   MVP では sub-profile (QueryScopeResolver/EvidencePolicy/AnswerPolicy 等) を inline field
   として持つ (§19.5.6 の「ref の束＋差分」。将来は別 object 参照 + version snapshot 化)。 *)
SourceVault`SourceVaultCreatePDFGroupSearchProfile[groupAlias_String, spec_Association, opts___] :=
  iSMRegister["PDFGroupSearchProfile", groupAlias,
    Join[<|"GroupAlias" -> groupAlias|>, spec]];
SourceVault`SourceVaultResolvePDFGroupSearchProfile[groupAlias_String, opts___] :=
  iSMResolve["PDFGroupSearchProfile", groupAlias];
SourceVault`SourceVaultListPDFGroupSearchProfiles[opts___] :=
  Keys @ Lookup[$smRegistries, "PDFGroupSearchProfile", <||>];
SourceVault`SourceVaultClonePDFGroupSearchProfile[srcAlias_String, newAlias_String, overrides_Association : <||>, opts___] :=
  Module[{src = iSMResolve["PDFGroupSearchProfile", srcAlias]},
    If[FailureQ[src], src,
      iSMRegister["PDFGroupSearchProfile", newAlias,
        Join[src, <|"GroupAlias" -> newAlias|>, overrides]]]];

SourceVaultRegisterChannelEndpoint[name_String, spec_Association] :=
  iSMRegister["ChannelEndpoint", name, spec];
SourceVaultRegisterVoiceBackend[name_String, spec_Association] :=
  iSMRegister["VoiceBackend", name, spec];
SourceVaultRegisterVRSNSAdapter[name_String, spec_Association] :=
  iSMRegister["VRSNSAdapter", name, spec];
SourceVaultRegisterCapabilityProfile[name_String, spec_Association] :=
  iSMRegister["CapabilityProfile", name, spec];
SourceVaultRegisterLLMBackend[name_String, spec_Association] :=
  iSMRegister["LLMBackend", name, spec];
SourceVaultRegisterCaptureSource[name_String, spec_Association] :=
  iSMRegister["CaptureSource", name, spec];
SourceVaultRegisterOutputAdapter[name_String, spec_Association] :=
  iSMRegister["OutputAdapter", name, spec];

SourceVaultResolveServiceProfile[kind_String, name_String, opts___] := iSMResolve[kind, name];

SourceVaultListServiceProfiles[kind_String] := Keys @ Lookup[$smRegistries, kind, <||>];
SourceVaultListServiceProfiles[] :=
  Association @ Map[# -> Keys[Lookup[$smRegistries, #, <||>]] &, iSMKinds];

SourceVaultClearServiceRegistry[] := ($smRegistries = <||>; <|"Status" -> "OK"|>);

SourceVaultLocalConfigDoctor[opts___] := Module[{webEps, backends, contexts, missing = {}},
  contexts = Quiet @ SourceVault`SourceVaultListReleaseContexts[];
  backends = Quiet @ SourceVault`SourceVaultListProfiles["SearchBackend"];
  webEps = SourceVaultListServiceProfiles["WebServiceEndpoint"];
  If[contexts === {} || ! ListQ[contexts], AppendTo[missing, "ReleaseContext"]];
  If[backends === {} || ! ListQ[backends], AppendTo[missing, "SearchBackend"]];
  If[webEps === {}, AppendTo[missing, "WebServiceEndpoint"]];
  <|"Status" -> If[missing === {}, "OK", "Incomplete"], "Missing" -> missing,
    "ReleaseContexts" -> contexts, "SearchBackends" -> backends,
    "WebServiceEndpoints" -> webEps|>
];

(* ============================================================
   §5.5 personal config doctor
   ============================================================ *)

$bs = FromCharacterCode[92];  (* バックスラッシュ。regex の 4 重 escape を避ける *)

(* 文字列を mask: 先頭 2 文字 + *** *)
iMask[s_String] := If[StringLength[s] <= 2, "***",
  StringTake[s, 2] <> StringRepeat["*", Min[8, StringLength[s] - 2]]];

(* IPv4: 4 octet を抽出し各 octet <= 255 のものだけ採用。
   0.0.0.0 / 255.255.255.255 は個人・環境情報ではない wildcard / broadcast なので除外。 *)
$ignoreIPv4 = {"0.0.0.0", "255.255.255.255"};
iFindIPv4[line_String] := Module[{cands},
  cands = StringCases[line, RegularExpression["\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}"]];
  Select[cands, Function[c,
    AllTrue[ToExpression /@ StringSplit[c, "."], # <= 255 &] && ! MemberQ[$ignoreIPv4, c]]]
];

iFindLocalhostPort[line_String] :=
  StringCases[line, RegularExpression["(?:localhost|127\\.0\\.0\\.1):\\d+"]];

(* credential らしき: sk-..., Bearer ..., (api key|secret|token|password) = ... *)
iFindCredential[line_String] := Join[
  StringCases[line, RegularExpression["sk-[A-Za-z0-9]{12,}"]],
  StringCases[line, RegularExpression["(?i)bearer\\s+[A-Za-z0-9._-]{12,}"]],
  StringCases[line, RegularExpression[
    "(?i)(?:api[_-]?key|secret|token|password|webhook)\\s*[:=]\\s*[\"']?[A-Za-z0-9._/-]{8,}"]]
];

iFindEmail[line_String, allow_List] := Module[{ems},
  ems = StringCases[line, RegularExpression["[\\w.+-]+@[\\w-]+\\.[\\w.-]+"]];
  Select[ems, ! MemberQ[allow, #] &]
];

(* Windows/macOS user path: 正規表現の literal backslash を避けるため substring 判定 *)
iFindUserPath[line_String] := Module[{lc = ToLowerCase[line], hits = {}},
  If[StringContainsQ[lc, "users" <> $bs], AppendTo[hits, "WindowsUserPath"]];
  (* needle を分割して書き、doctor 自身のソースが self-detect されないようにする *)
  If[StringContainsQ[lc, "/" <> "users" <> "/"], AppendTo[hits, "macOSUserPath"]];
  If[StringContainsQ[lc, $bs <> "users" <> $bs], AppendTo[hits, "WindowsUserPath"]];
  DeleteDuplicates[hits]
];

$docExtensions = {".wl", ".wls", ".m", ".md", ".json", ".toml", ".yaml", ".yml"};

iExpandFiles[spec_, exts_List] := Module[{items},
  items = Flatten[{spec}];
  Flatten[Map[
    Which[
      DirectoryQ[#], Select[FileNames["*", #, Infinity],
        FileExistsQ[#] && MemberQ[exts, "." <> ToLowerCase@FileExtension[#]] &],
      FileExistsQ[#], {#},
      True, {}] &, items]]
];

(* private design doc マーカー (先頭 40 行以内) があれば検査対象外 *)
iIsPrivateDesignDoc[text_String] :=
  StringContainsQ[StringTake[text, UpTo[4000]], "doctor:private-design-doc"];

Options[SourceVaultNoPersonalConfigDoctor] = {
  "MailAllowlist" -> {}, "Extensions" -> Automatic, "Mask" -> True};
SourceVaultNoPersonalConfigDoctor[filesOrDirs_, OptionsPattern[]] := Module[
  {exts, files, allow, mask, findings = {}, skipped = {}},
  exts = OptionValue["Extensions"] /. Automatic -> $docExtensions;
  allow = OptionValue["MailAllowlist"];
  mask = TrueQ[OptionValue["Mask"]];
  files = iExpandFiles[filesOrDirs, exts];
  Do[
    Module[{text, lines, lineHits},
      text = Quiet @ Import[file, "Text"];
      If[! StringQ[text], Continue[]];
      If[iIsPrivateDesignDoc[text], AppendTo[skipped, file]; Continue[]];
      lines = StringSplit[text, {"\r\n", "\n", "\r"}];
      MapIndexed[
        Function[{line, idx},
          lineHits = Join[
            {"IPv4", #} & /@ iFindIPv4[line],
            {"LocalhostPort", #} & /@ iFindLocalhostPort[line],
            {"Credential", #} & /@ iFindCredential[line],
            {"Email", #} & /@ iFindEmail[line, allow],
            {#, "(path)"} & /@ iFindUserPath[line]
          ];
          Do[
            AppendTo[findings, <|
              "File" -> file, "Line" -> idx[[1]], "Kind" -> hit[[1]],
              "Match" -> If[mask, iMask[ToString[hit[[2]]]], hit[[2]]]|>],
            {hit, lineHits}]
        ],
        lines]
    ],
    {file, files}];
  <|"Status" -> If[findings === {}, "OK", "FindingsFound"],
    "Findings" -> findings, "FilesScanned" -> Length[files],
    "Skipped" -> skipped, "FindingCount" -> Length[findings]|>
];

(* ============================================================
   §9.3-9.6, §17.8  detached service lifecycle (Phase 2)
   排他制御 / event log は core (SourceVault_core.wl) に乗る。
   service runtime dir 配下の status/heartbeat/pid は single-writer の
   mutable cache なので直接 overwrite で扱う (正本ではない)。
   ============================================================ *)

(* このファイルのある package root (subkernel から再 Get する) *)
$smFile = Replace[$InputFileName, Except[_String?(StringLength[#] > 0 &)] :> Missing["Unknown"]];
iPackageRoot[] := If[StringQ[$smFile], DirectoryName[$smFile], Directory[]];

iSMEnsureDir[d_String] := (If[! DirectoryQ[d], Quiet @ CreateDirectory[d, CreateIntermediateDirectories -> True]]; d);

iSMUTCNow[] := Module[{u = TimeZoneConvert[Now, 0]},
  DateString[u, {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"}]];

(* RawJSON が encode できない None/Missing/DateObject を Null/文字列に落とす *)
iSMJSONSafe[x_] := Which[
  x === None, Null,
  Head[x] === Missing, Null,
  Head[x] === DateObject, iSMUTCNow[],
  AssociationQ[x], Association @ KeyValueMap[#1 -> iSMJSONSafe[#2] &, x],
  ListQ[x], iSMJSONSafe /@ x,
  True, x];
(* RawJSON はバイト列で書く。ExportString[...,"RawJSON"] は $CharacterEncoding が
   ShiftJIS 等(日本語 Windows 既定)のとき日本語を「UTF-8 バイト→Latin-1 codepoint」に
   展開し、後段の StringToByteArray["UTF-8"] が二重 UTF-8 化してしまう。
   ExportByteArray はエンコーディング非依存で常に正しい UTF-8 を返す。 *)
(* hardening 02 Inc1 (2026-07-07): 状態 JSON は temp-rename で書く。
   直接 OpenWrite だと書きかけを watchdog/proxy が読み、age=null が
   『健康』に化ける事故 (green-but-dead) の温床になる。rename が
   共有違反等で失敗した場合 (Windows で読者が FILE_SHARE_DELETE 無しで
   open 中など) は 1 回だけ retry し、それでも駄目なら旧来の直接書きに
   fallback (heartbeat の可用性 > 原子性)。 *)
iSMWriteJSON[path_String, assoc_] := Module[{strm, ba, tmp, renamed},
  ba = Quiet @ ExportByteArray[iSMJSONSafe[assoc], "RawJSON", "Compact" -> True];
  If[! ByteArrayQ[ba], Return[$Failed]];
  iSMEnsureDir[DirectoryName[path]];
  tmp = path <> ".tmp-" <> ToString[$ProcessID];
  strm = Quiet @ OpenWrite[tmp, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  BinaryWrite[strm, ba]; Close[strm];
  renamed = Quiet @ Check[
    RenameFile[tmp, path, OverwriteTarget -> True]; True, False];
  If[! TrueQ[renamed],
    Pause[0.05];
    renamed = Quiet @ Check[
      RenameFile[tmp, path, OverwriteTarget -> True]; True, False]];
  If[! TrueQ[renamed],
    (* fallback: 直接書き (旧挙動) *)
    strm = Quiet @ OpenWrite[path, BinaryFormat -> True];
    If[Head[strm] =!= OutputStream, Quiet @ DeleteFile[tmp]; Return[$Failed]];
    BinaryWrite[strm, ba]; Close[strm];
    Quiet @ DeleteFile[tmp]];
  path];

(* RawJSON はバイト列から直接解析する。ImportString[ByteArrayToString[...],"RawJSON"]
   は生 UTF-8 (非 ASCII。例: Python json.dump(ensure_ascii=False) が書く日本語) を
   再エンコードで壊して "Invalid token" になるため、ImportByteArray を使う。 *)
iSMParseRawJSON[b_ByteArray] := Module[{r = Quiet @ ImportByteArray[b, "RawJSON"]},
  If[AssociationQ[r] || ListQ[r], r,
    Quiet @ ImportString[ByteArrayToString[b, "UTF-8"], "RawJSON"]]];
iSMReadJSON[path_String] := Module[{b},
  If[! FileExistsQ[path], Return[Missing["NoFile"]]];
  b = Quiet @ ReadByteArray[path];
  If[! ByteArrayQ[b], Return[Missing["Empty"]]];
  iSMParseRawJSON[b]];

(* hardening 02 Inc1: health 閾値の単一定義 (spec 02 §2)。
   WL 判定・watchdog PS1 生成・proxy config.json 生成の全てがここを参照する。 *)
If[! AssociationQ[$SourceVaultHealthThresholds],
  $SourceVaultHealthThresholds = <|
    "OKSeconds" -> 15,
    "DegradedSeconds" -> 60,
    "WatchdogStaleSeconds" -> 90,
    "EvalTimeoutSeconds" -> 5,
    "EvalCacheSeconds" -> 30,
    "PingTimeoutSeconds" -> 10,
    "PingIntervalSeconds" -> 60|>];
iSMHealthThreshold[k_String, def_] := With[{a = $SourceVaultHealthThresholds},
  If[AssociationQ[a] && NumericQ[Lookup[a, k]], a[k], def]];

iSMAppendJSONL[path_String, assoc_] := Module[{strm, ba},
  ba = Quiet @ ExportByteArray[iSMJSONSafe[assoc], "RawJSON", "Compact" -> True];
  If[! ByteArrayQ[ba], Return[$Failed]];
  iSMEnsureDir[DirectoryName[path]];
  strm = Quiet @ OpenAppend[path, BinaryFormat -> True];
  If[Head[strm] =!= OutputStream, Return[$Failed]];
  BinaryWrite[strm, ba]; BinaryWrite[strm, StringToByteArray["\n", "UTF-8"]]; Close[strm]; path];

iSMReadJSONL[path_String] := Module[{b, lines},
  If[! FileExistsQ[path], Return[{}]];
  b = Quiet @ ReadByteArray[path];
  If[! ByteArrayQ[b], Return[{}]];
  lines = Select[StringSplit[ByteArrayToString[b, "UTF-8"], "\n"], StringLength[StringTrim[#]] > 0 &];
  Select[Quiet[iSMParseRawJSON[StringToByteArray[#, "UTF-8"]]] & /@ lines, AssociationQ]];

(* runtime dir。services / proxies は「マシン固有」状態 (その PC で動くカーネル/proxy の
   pid / heartbeat / log)。Dropbox 共有 vault でも別マシンと衝突 (競合コピー) しないよう、
   runtime 直下に $MachineName の層を挟んで namespacing する。
   locks (core の runtime/locks) はクロスマシン排他のため共有のまま (ここでは触らない)。 *)
iRuntimeMachineTag[] :=
  StringReplace[ToString[$MachineName], Except[LetterCharacter | DigitCharacter | "-" | "_"] .. -> "-"];
iRuntimeMachineRoot[root_String] := FileNameJoin[{root, "runtime", iRuntimeMachineTag[]}];
iServiceRuntimeDir[serviceId_String] := Module[{root = SourceVault`SourceVaultCoreRoot[]},
  If[FailureQ[root], root, FileNameJoin[{iRuntimeMachineRoot[root], "services", serviceId}]]];
SourceVaultServiceRuntimeDir[serviceId_String] := iServiceRuntimeDir[serviceId];

iServiceLog[dir_String, eventClass_String, data_Association: <||>] :=
  iSMAppendJSONL[FileNameJoin[{dir, "service.log.jsonl"}],
    Join[<|"EventClass" -> eventClass, "AtUTC" -> iSMUTCNow[]|>, data]];

(* ---- wolframscript 解決 (ClaudeRuntime と同じ優先順を自前実装、依存を持たない) ---- *)
iResolveWolframScript[] := Module[{cands, exe},
  cands = {
    If[StringQ[SourceVault`$SourceVaultWolframScript], SourceVault`$SourceVaultWolframScript, Nothing],
    Replace[Environment["WOLFRAMSCRIPT"], Except[_String] -> Nothing],
    FileNameJoin[{$InstallationDirectory, "wolframscript.exe"}],
    FileNameJoin[{$InstallationDirectory, "wolframscript"}]};
  exe = SelectFirst[cands, StringQ[#] && FileExistsQ[#] &, Missing[]];
  If[MissingQ[exe], "wolframscript", exe]];

(* ---- pid 検証 / kill (Windows 中心、PID 再利用での誤 kill 防止) ---- *)
iPidAlive[pid_Integer] := Module[{out},
  out = Quiet @ RunProcess[{"tasklist", "/FI", "PID eq " <> ToString[pid], "/NH"}];
  AssociationQ[out] && StringContainsQ[Lookup[out, "StandardOutput", ""], ToString[pid]]];

(* detached service の image は WolframKernel.exe (wolframscript が起動する kernel)。
   wolframscript / WolframKernel どちらも Wolfram プロセスとして受理する。 *)
iPidIsWolframProcess[pid_Integer] := Module[{out},
  out = Quiet @ RunProcess[{"tasklist", "/FI", "PID eq " <> ToString[pid], "/NH"}];
  AssociationQ[out] && StringContainsQ[ToLowerCase @ Lookup[out, "StandardOutput", ""], "wolfram"]];

(* watchdog の常駐プロセスは powershell。pid 再利用での誤 kill を避けるため image を確認する。 *)
iPidIsPowerShell[pid_Integer] := Module[{out},
  out = Quiet @ RunProcess[{"tasklist", "/FI", "PID eq " <> ToString[pid], "/NH"}];
  AssociationQ[out] && StringContainsQ[ToLowerCase @ Lookup[out, "StandardOutput", ""], "powershell"]];

iKillPid[pid_Integer] :=
  Lookup[Quiet @ RunProcess[{"taskkill", "/PID", ToString[pid], "/F"}], "ExitCode", 1] === 0;

(* ============================================================
   runner entrypoint (子 process 側)
   ============================================================ *)

(* ============================================================
   §Web UI: HTTP リクエストを service 側で処理する。WebServer.wl の
   見た目(CSS)を再利用しつつ、検索は必ず gate 越し(SourceVaultSearch)。
   proxy は汎用中継で {StatusCode, ContentType, Body} を受け取り emit する。
   すべて charset=utf-8。リンク/フォームは RoutePrefix(base) を前置する。
   ページ画像は Rasterize(FrontEnd 必須) のため headless では生成不可 →
   gate 済み本文を表示し画像は degrade する。
   ============================================================ *)

(* esc/parse は自前実装に固定。WebServer`Private` シンボルはコード参照で生成され
   Names 判定が当てにならないため依存しない。CSS のみ実定義があれば再利用する。 *)
iWebEsc[s_] := Module[{str = If[StringQ[s], s, ToString[s]]},
  StringReplace[str, {"&" -> "&amp;", "<" -> "&lt;", ">" -> "&gt;", "\"" -> "&quot;"}]];

iWebCssFallback = "body{font-family:sans-serif;background:#1a1a2e;color:#e0e0e0;max-width:900px;margin:0 auto;padding:24px;line-height:1.6}\n" <>
  "a{color:#88aaff}\nh1{color:#cfe0ff}\n" <>
  ".btn,.btn-run{background:#2d4a8a;color:#fff;border:0;border-radius:6px;padding:8px 16px;cursor:pointer;font-size:1em}\n" <>
  ".query-form{margin:16px 0}\n.form-footer{margin-top:8px}\n" <>
  ".form-textarea{width:100%;box-sizing:border-box;background:#22223a;color:#e0e0e0;border:1px solid #3a3a5a;border-radius:6px;padding:8px;font-size:1em}";
iWebCss[] := Module[{c = Quiet @ WebServer`Private`iCSS[]}, If[StringQ[c], c, iWebCssFallback]];

iWebParseQuery[qs_String] := Association @ Cases[StringSplit[qs, "&"],
  s_String /; StringLength[s] > 0 :> Module[{kv = StringSplit[s, "=", 2]},
    If[Length[kv] == 2,
      URLDecode[StringReplace[kv[[1]], "+" -> " "]] -> URLDecode[StringReplace[kv[[2]], "+" -> " "]],
      URLDecode[StringReplace[First[kv], "+" -> " "]] -> ""]]];

iWebPage[base_String, title_String, bodyHtml_String] := StringJoin[
  "<!DOCTYPE html>\n<html lang='ja'><head><meta charset='utf-8'>",
  "<meta name='viewport' content='width=device-width, initial-scale=1'>",
  "<title>", iWebEsc[title], "</title>",
  "<link rel='stylesheet' href='", base, "/style.css'></head><body>",
  bodyHtml,
  "<hr style='border-color:#3a3a5a;margin-top:32px'>",
  "<p style='opacity:.5;font-size:.8em'>SourceVault gated web (release-context enforced)</p>",
  "</body></html>"];

iWebNav[base_String] := StringJoin[
  "<p style='opacity:.8'>",
  "<a href='", base, "/pdfsearch' style='color:#88aaff'>検索</a> | ",
  "<a href='", base, "/pdfask' style='color:#88aaff'>質問応答</a> | ",
  "<a href='", base, "/pdfpage' style='color:#88aaff'>ページ本文</a></p>"];

iWebSearchForm[base_String, q_String, action_String, label_String] := StringJoin[
  "<form class='query-form' method='get' action='", base, action, "'>",
  "<input name='q' class='form-textarea' style='height:42px' placeholder='", label, "' value='",
  iWebEsc[q], "' autofocus>",
  "<div class='form-footer' style='margin-top:8px'><button type='submit' class='btn btn-run'>", label, "</button></div>",
  "</form>"];

(* gated 結果 (SourceVaultSearch の出力 = association のリスト) をカード描画 *)
iWebRenderResults[base_String, q_String, results_List] := Module[{cards},
  cards = StringJoin @ MapIndexed[Function[{r, idx},
    Module[{cit = Lookup[r, "Citation", <||>], title, page, snip, score, chunk, dec},
      title = iWebEsc @ Lookup[cit, "Title", "(無題)"];
      page = Lookup[cit, "Page", "?"];
      snip = iWebEsc @ StringTake[ToString @ Lookup[r, "Snippet", ""], UpTo[320]];
      score = Lookup[r, "Score", ""];
      chunk = Lookup[r, "ChunkId", ""];
      dec = iWebEsc @ ToString @ Lookup[r, "ReleaseDecision", "?"];
      StringJoin[
        "<div style='border:1px solid #3a3a5a;border-radius:8px;margin:10px 0;padding:14px;background:#22223a'>",
        "<h3 style='margin:0 0 6px;color:#cfe0ff'>#", ToString[First[idx]], " ", title,
        " <span style='opacity:.6;font-weight:normal;font-size:.85em'>(p.", ToString[page],
        ", score ", ToString[score], ")</span></h3>",
        "<p style='color:#b8c0e0;font-size:.92em;line-height:1.6;white-space:pre-wrap'>", snip, " …</p>",
        "<p style='font-size:.8em;opacity:.7'>",
        "<a href='", base, "/pdfpage?p=", ToString[page],
          "&doc=", URLEncode[ToString @ Lookup[cit, "DocId", Lookup[cit, "Title", ""]]],
          "' style='color:#88aaff'>このページを画像表示</a>",
        " · chunk ", ToString[chunk], " · ", dec, "</p>",
        "</div>"]]],
    results];
  StringJoin[
    "<h1 style='color:#cfe0ff'>検索結果: ", iWebEsc[q], "</h1>",
    iWebNav[base],
    "<p style='opacity:.7'>", ToString[Length[results]], " 件 (release gate 通過)</p>",
    If[Length[results] === 0,
      "<p>該当する公開チャンクはありませんでした。</p>", cards]]];

iWebErr[base_String, msg_String] :=
  <|"StatusCode" -> 200, "ContentType" -> "text/html; charset=utf-8",
    "Body" -> iWebPage[base, "エラー", "<h2>エラー</h2><p>" <> iWebEsc[msg] <> "</p>" <> iWebNav[base]]|>;

iWebHtml[base_String, title_String, body_String] :=
  <|"StatusCode" -> 200, "ContentType" -> "text/html; charset=utf-8",
    "Body" -> iWebPage[base, title, body]|>;

(* gated 検索を1回実行 (HTML/JSON 共用)。{ok, results} or {error, reason} *)
iWebGatedSearch[q_String, rc_, profile_, limit_ : 20] := Module[{r},
  If[! StringQ[rc], Return[<|"ok" -> False, "reason" -> "ReleaseContextRequired (fail-closed)"|>]];
  r = SourceVault`SourceVaultSearch[q, "ReleaseContext" -> rc,
    "PDFIndexProfile" -> profile, "Limit" -> limit];
  If[FailureQ[r],
    <|"ok" -> False, "reason" -> iWebFailureReason[r]|>,
    <|"ok" -> True, "results" -> r|>]];

(* Failure を画面表示用のクリーンな日本語文に。未登録系は種別/名前を明示。 *)
iWebFailureReason[r_] := Module[{k = Quiet @ r["Kind"], n = Quiet @ r["Name"]},
  If[StringQ[k] && StringQ[n],
    k <> " \"" <> n <> "\" がサービスに未登録です (fail-closed)。" <>
      "service の prelude / private local init で登録してください。",
    Module[{msg = Quiet @ Check[r["Message"], ""]},
      If[StringQ[msg] && StringLength[msg] > 0 && ! StringContainsQ[msg, "TagBox"],
        msg, "検索に失敗しました (fail-closed)。設定登録を確認してください。"]]]];

(* doc を docId または title で解決 (docId 優先・fail-closed)。複数年度の便覧が混在するため
   title は URL 往復 (全角空白/エンコード等) に弱く、不一致だと別 PDF の無関係ページを描画してしまう。
   安定 ID の docId を主キーにし、解決できなければ $Failed を返す (誤った先頭 doc に
   フォールバックしない=別 PDF を絶対に出さない)。 *)
iWebResolveDoc[collection_String, ref_String] := Module[{raw, recs, hit, p},
  (* iLoadCollectionDocs は Association のリストを返す。Normal すると rule-list 化して
     AssociationQ が False になり誤判定するので Normal しない (これが旧 iWebDocPath の
     「常に先頭 doc にフォールバック」バグの原因だった)。 *)
  raw = Quiet @ Check[PDFIndex`Private`iLoadCollectionDocs[collection], $Failed];
  recs = Which[AssociationQ[raw], Values[raw], ListQ[raw], raw, True, {}];
  hit = Which[
    (* doc 未指定 = 素のページ閲覧 → 先頭 doc を既定表示 (title を出すので誤認しない) *)
    StringTrim[ref] === "", FirstCase[recs, _?AssociationQ, Missing[]],
    (* 特定文書指定 = docId 優先 → title。見つからなければ fail-closed (別 PDF を出さない) *)
    True, Module[{h = SelectFirst[recs, AssociationQ[#] && Lookup[#, "docId", ""] === ref &, Missing[]]},
      If[MissingQ[h], h = SelectFirst[recs, AssociationQ[#] && Lookup[#, "title", ""] === ref &, Missing[]]]; h]];
  If[! AssociationQ[hit], Return[$Failed]];
  p = Quiet @ PDFIndex`Private`iResolveSourcePath[Lookup[hit, "sourcePath", ""]];
  If[StringQ[p] && FileExistsQ[p],
    <|"path" -> p, "title" -> ToString @ Lookup[hit, "title", ""],
      "docId" -> ToString @ Lookup[hit, "docId", ""]|>, $Failed]];

(* PDF 1ページを画像化 → base64 JPEG。{"PageImages",n} は headless でも Image を返す
   (Rasterize/FrontEnd 不要)。ExportByteArray でバイト化。 *)
iWebPageImgB64[path_String, pageNum_Integer] := Module[{img = $Failed, ba, try},
  (* PDF importer は初回(コールド)に $Failed を返すことがあるためリトライする。 *)
  Do[
    img = Quiet @ Check[Import[path, {"PageImages", pageNum}], $Failed];
    If[ListQ[img] && Length[img] > 0, img = First[img]];
    If[Head[img] === Image, Break[]];
    Pause[0.3],
    {try, 3}];
  If[Head[img] =!= Image, Return[None]];
  ba = Quiet @ Check[ExportByteArray[img, "JPEG"], $Failed];
  If[ByteArrayQ[ba], BaseEncode[ba], None]];

iWebRenderPageView[base_String, collection_String, pageNum_Integer, docRef_String] :=
  Module[{resolved, path, title, b64, docParam, nav, imgHtml},
    resolved = iWebResolveDoc[collection, docRef];
    (* 文書を特定できないときは別 PDF を出さず明示エラー (誤ページ防止) *)
    If[! AssociationQ[resolved],
      Return[iWebHtml[base, "ページ p." <> ToString[pageNum],
        "<h1 style='color:#cfe0ff'>ページ表示</h1>" <> iWebNav[base] <>
        "<div style='background:#2a2a1a;border:1px solid #6a5a2a;border-radius:6px;padding:10px'>" <>
        "指定された文書を特定できませんでした。検索結果の「このページを画像表示」リンクから開いてください。</div>"]]];
    path = resolved["path"]; title = resolved["title"];
    b64 = If[StringQ[path] && FileExistsQ[path] && pageNum >= 1,
      iWebPageImgB64[path, pageNum], None];
    docParam = "&doc=" <> URLEncode[docRef];   (* docId を保持 (安定) *)
    nav = StringJoin[
      "<p style='margin:10px 0'>",
      If[pageNum > 1,
        "<a class='btn' href='" <> base <> "/pdfpage?p=" <> ToString[pageNum - 1] <> docParam <> "'>&#8592; 前のページ</a> ", ""],
      "<span style='opacity:.7;margin:0 8px'>p." <> ToString[pageNum] <> " / " <> iWebEsc[title] <> "</span>",
      "<a class='btn' href='" <> base <> "/pdfpage?p=" <> ToString[pageNum + 1] <> docParam <> "'>次のページ &#8594;</a>",
      "</p>"];
    imgHtml = If[StringQ[b64],
      "<img src='data:image/jpeg;base64," <> b64 <> "' style='max-width:100%;border:1px solid #3a3a5a;border-radius:6px;display:block'>",
      "<div style='background:#2a2a1a;border:1px solid #6a5a2a;border-radius:6px;padding:10px'>ページ画像を生成できませんでした (ページ範囲外)。</div>"];
    iWebHtml[base, "ページ p." <> ToString[pageNum],
      "<h1 style='color:#cfe0ff'>ページ表示</h1>" <> iWebNav[base] <> nav <> imgHtml <> nav]];

(* ローカル LLM (LM Studio) チャット呼び出し。/pdfask の回答合成に使う。
   gate 済み evidence のみを prompt に渡し、生 vault は触らせない。endpoint/model/key は
   ハードコードせず変数・NBAccess・/v1/models 自動検出で解決。 *)
If[! ValueQ[SourceVault`$SourceVaultWebLLMBase], SourceVault`$SourceVaultWebLLMBase = "http://localhost:1234"];
If[! ValueQ[SourceVault`$SourceVaultWebChatModel], SourceVault`$SourceVaultWebChatModel = Automatic];

(* === LLM ライセンス/課金ポリシー ===
   ClaudeCode / Codex (サブスク CLI) は契約者本人のみ利用可。よって他者が使う web サービスで
   ClaudeCode/Codex を呼んではならない。リクエスト元 IP がオーナー PC のときだけサブスクを許可する。
     - オーナー PC          → ClaudeCode/Codex ("cloud") 可
     - 非オーナー + 課金禁止 → LM Studio (ローカル LLM) 一択
     - 非オーナー + 課金OK   → 課金API ("api") か LM Studio
   client IP は proxy が実 TCP peer から付与する (X-Forwarded-For は詐称可能なので採用しない)。 *)
If[! ValueQ[SourceVault`$SourceVaultOwnerIPs], SourceVault`$SourceVaultOwnerIPs = {"127.0.0.1", "::1", "localhost"}];
If[! ValueQ[SourceVault`$SourceVaultBillingAllowed], SourceVault`$SourceVaultBillingAllowed = False];
If[! ValueQ[SourceVault`$SourceVaultWebBilledModel], SourceVault`$SourceVaultWebBilledModel = "claude-sonnet-4-6"];

SourceVault`SourceVaultRegisterOwnerIP[ip_String] := (
  If[! MemberQ[SourceVault`$SourceVaultOwnerIPs, ip],
    SourceVault`$SourceVaultOwnerIPs = Append[SourceVault`$SourceVaultOwnerIPs, ip]];
  SourceVault`$SourceVaultOwnerIPs);
SourceVault`SourceVaultSetBillingAllowed[b : (True | False)] := (SourceVault`$SourceVaultBillingAllowed = b);

(* client IP がオーナー PC か。IP 不明 (proxy を介さない直接 iServiceHttpRender 呼び出し
   = オーナー自身のカーネル) はオーナー扱い。proxy 経由は必ず IP が載るので他者 IP は非オーナー。 *)
iWebIsOwnerIP[clientIP_, ownerIPs_List] :=
  ! StringQ[clientIP] || clientIP === "" || MemberQ[ownerIPs, clientIP];

iWebLLMAPIKey[] := Module[{k},
  k = Quiet @ Check[NBAccess`NBGetLocalLLMAPIKey["lmstudio", SourceVault`$SourceVaultWebLLMBase,
    PrivacySpec -> <|"AccessLevel" -> 1.0|>], Null];
  If[StringQ[k] && k =!= "", k, "lm-studio"]];

iWebChatModel[override_:Automatic] := Module[
  {m = If[StringQ[override] && override =!= "", override, SourceVault`$SourceVaultWebChatModel],
   r, j, models, loaded, nonthink, pick, ids},
  If[StringQ[m], Return[m]];
  (* LM Studio 拡張 API /api/v0/models は state(loaded) と type を返す。
     未ロードモデルを選ぶと JIT ロードで数分かかり timeout するため、必ず loaded を選ぶ。
     type=llm (非 vlm/embeddings) かつ非 thinking を優先 (thinking は遅い)。 *)
  r = Quiet @ Check[URLRead[HTTPRequest[SourceVault`$SourceVaultWebLLMBase <> "/api/v0/models",
    <|"Headers" -> {"Authorization" -> "Bearer " <> iWebLLMAPIKey[]}|>], "Body"], $Failed];
  j = Quiet @ Developer`ReadRawJSONString[r];
  models = If[AssociationQ[j], Lookup[j, "data", {}], {}];
  If[ListQ[models] && models =!= {},
    loaded = Select[models, Lookup[#, "state", ""] === "loaded" &&
      MemberQ[{"llm", "vlm"}, Lookup[#, "type", ""]] &];
    nonthink = Select[loaded, ! StringContainsQ[Lookup[#, "id", ""], "think", IgnoreCase -> True] &];
    pick = SelectFirst[nonthink, Lookup[#, "type", ""] === "llm" &, Missing[]];
    If[! AssociationQ[pick] && nonthink =!= {}, pick = First[nonthink]];
    If[! AssociationQ[pick] && loaded =!= {}, pick = First[loaded]];
    If[AssociationQ[pick], Return[Lookup[pick, "id", "local-model"]]]];
  (* fallback: /v1/models (state 不明) → 非embed・非thinking の instruct を優先 *)
  ids = Select[Quiet @ Lookup[
    Quiet @ Developer`ReadRawJSONString[Quiet @ Check[URLRead[HTTPRequest[
      SourceVault`$SourceVaultWebLLMBase <> "/v1/models",
      <|"Headers" -> {"Authorization" -> "Bearer " <> iWebLLMAPIKey[]}|>], "Body"], "{}"]],
    "data", {}], AssociationQ];
  ids = Select[Lookup[#, "id", ""] & /@ ids,
    StringQ[#] && # =!= "" && ! StringContainsQ[#, "embed" | "think", IgnoreCase -> True] &];
  Module[{instr = Select[ids, StringContainsQ[#, "instruct", IgnoreCase -> True] && ! StringContainsQ[#, "coder", IgnoreCase -> True] &]},
    Which[instr =!= {}, First[instr], ids =!= {}, First[ids], True, "local-model"]]];

(* クラウド LLM (ClaudeQueryBg, 同期・コンテキスト安全)。公開コンテンツ用に高速。
   model="" で既定モデル、それ以外は $ClaudeModel を一時切替。 *)
iWebChatCloud[prompt_String, model_String] := Module[{r},
  If[Length[Names["ClaudeCode`ClaudeQueryBg"]] === 0, Return[$Failed]];
  (* 1H-S shadow: LLM boundary shadow(observe-only。トグル off 時ゼロコスト) *)
  If[TrueQ[SourceVault`$SourceVaultLLMBoundaryShadow],
    Quiet @ Check[SourceVault`SourceVaultLLMBoundaryShadowCheck["servicemanager:iWebChatCloud",
      <|"Provider" -> "claudecode", "Model" -> If[model === "", Missing["Default"], model],
        "Messages" -> {<|"role" -> "user", "content" -> prompt|>}|>], Null]];
  r = Quiet @ Check[
    If[model === "", ClaudeCode`ClaudeQueryBg[prompt],
      Block[{ClaudeCode`$ClaudeModel = model}, ClaudeCode`ClaudeQueryBg[prompt]]],
    $Failed];
  If[StringQ[r] && StringTrim[r] =!= "" && ! StringStartsQ[r, "Error"], r, $Failed]];

(* 課金API (Anthropic Messages API, 従量課金=サービス提供可)。サブスク CLI とは別ライセンス。
   鍵は NBAccess`NBGetAPIKey 経由 (直接 SystemCredential は使わない)。 *)
iWebChatBilledAPI[prompt_String, model_String] := Module[{key, m, body, resp, j, content},
  key = Quiet @ Check[NBAccess`NBGetAPIKey["anthropic"], $Failed];
  If[! (StringQ[key] && key =!= ""), Return[$Failed]];
  m = If[model === "", SourceVault`$SourceVaultWebBilledModel, model];
  body = ExportByteArray[<|"model" -> m, "max_tokens" -> 1500,
    "messages" -> {<|"role" -> "user", "content" -> prompt|>}|>, "RawJSON"];
  (* 1H-S shadow: LLM boundary shadow(observe-only。鍵は envelope に含めない) *)
  If[TrueQ[SourceVault`$SourceVaultLLMBoundaryShadow],
    Quiet @ Check[SourceVault`SourceVaultLLMBoundaryShadowCheck["servicemanager:iWebChatBilledAPI",
      <|"Provider" -> "anthropic", "Model" -> m,
        "Deployment" -> "https://api.anthropic.com/v1/messages",
        "Messages" -> {<|"role" -> "user", "content" -> prompt|>}|>], Null]];
  resp = Quiet @ Check[URLRead[HTTPRequest["https://api.anthropic.com/v1/messages",
    <|"Method" -> "POST", "Headers" -> {"x-api-key" -> key,
       "anthropic-version" -> "2023-06-01", "content-type" -> "application/json"},
     "Body" -> body|>], TimeConstraint -> 200], $Failed];
  If[Head[resp] =!= HTTPResponse || resp["StatusCode"] =!= 200, Return[$Failed]];
  j = Quiet @ Developer`ReadRawJSONString[ByteArrayToString[resp["BodyByteArray"], "UTF-8"]];
  If[! AssociationQ[j], Return[$Failed]];
  content = Lookup[j, "content", {}];
  Module[{t = If[ListQ[content] && content =!= {}, Lookup[First[content], "text", $Failed], $Failed]},
    If[StringQ[t] && StringTrim[t] =!= "", t, $Failed]]];

(* ローカル LLM (LM Studio, OpenAI 互換)。誰でも利用可 (ローカル処理=課金もライセンスも無関係)。 *)
iWebChatLocal[prompt_String, modelOverride_] := Module[{key, model, body, resp, j},
  key = iWebLLMAPIKey[]; model = iWebChatModel[modelOverride];
  body = ExportByteArray[<|"model" -> model,
    "messages" -> {<|"role" -> "user", "content" -> prompt|>},
    "temperature" -> 0.2, "stream" -> False, "max_tokens" -> 1500|>, "RawJSON"];
  (* 1H-S shadow: LLM boundary shadow(observe-only) *)
  If[TrueQ[SourceVault`$SourceVaultLLMBoundaryShadow],
    Quiet @ Check[SourceVault`SourceVaultLLMBoundaryShadowCheck["servicemanager:iWebChatLocal",
      <|"Provider" -> "openai-compat", "Model" -> model,
        "Deployment" -> SourceVault`$SourceVaultWebLLMBase <> "/v1/chat/completions",
        "Messages" -> {<|"role" -> "user", "content" -> prompt|>}|>], Null]];
  (* chat モデルが未ロードだと JIT で長時間ハングしコマンドループを塞ぐので、短めの
     TimeConstraint で早期失敗させる (失敗時は /pdfask が evidence のみへ degrade)。 *)
  resp = Quiet @ Check[URLRead[HTTPRequest[SourceVault`$SourceVaultWebLLMBase <> "/v1/chat/completions",
    <|"Method" -> "POST", "Headers" -> {"Content-Type" -> "application/json",
      "Authorization" -> "Bearer " <> key}, "Body" -> body|>], TimeConstraint -> 90], $Failed];
  If[Head[resp] =!= HTTPResponse || resp["StatusCode"] =!= 200, Return[$Failed]];
  j = Quiet @ Developer`ReadRawJSONString[ByteArrayToString[resp["BodyByteArray"], "UTF-8"]];
  If[! AssociationQ[j], Return[$Failed]];
  Module[{c = Quiet @ Lookup[Lookup[First[Lookup[j, "choices", {<||>}]], "message", <||>], "content", $Failed]},
    If[StringQ[c] && StringLength[StringTrim[c]] > 0, c, $Failed]]];

(* ライセンス/課金ポリシーに従い、要求された ChatModel spec と policy(IP/owner/billing) から
   実際に使うバックエンドを決める。これが「ClaudeCode はオーナーのみ」を強制する中核。 *)
iWebResolveChatPlan[spec_, policy_Association] := Module[{isOwner, billingOK, subOK, s},
  isOwner = iWebIsOwnerIP[Lookup[policy, "ClientIP", None],
    Lookup[policy, "OwnerIPs", SourceVault`$SourceVaultOwnerIPs]];
  billingOK = TrueQ[Lookup[policy, "BillingAllowed", SourceVault`$SourceVaultBillingAllowed]];
  (* サブスク (ClaudeCode/Codex) を使える条件 = オーナー かつ 明示許可。
     proxy は「AllowOwnerSubscription かつ ローカルバインド」のときだけ SubscriptionAllowed=True を渡す。
     既定 (公開バインド・未指定) は False=不使用。policy にキーが無い直接呼び出し
     (オーナー自身のカーネルで対話的に使う) のみ True 既定で従来どおり。 *)
  subOK = isOwner && TrueQ[Lookup[policy, "SubscriptionAllowed", True]];
  s = If[StringQ[spec] && spec =!= "", spec, SourceVault`$SourceVaultWebChatModel];
  Which[
    (* ClaudeCode/Codex (サブスク) 要求: subOK のみ。それ以外は課金API/ローカルへ降格。 *)
    StringQ[s] && (s === "cloud" || StringStartsQ[s, "cloud:"]),
      Which[
        subOK, <|"Backend" -> "subscription",
          "Model" -> If[s === "cloud", "", StringDrop[s, StringLength["cloud:"]]], "Label" -> "ClaudeCode(owner)"|>,
        billingOK, <|"Backend" -> "api", "Model" -> "", "Label" -> "課金API"|>,
        True, <|"Backend" -> "local", "Model" -> Automatic, "Label" -> "LM Studio"|>],
    (* 課金API 要求: 課金OK か オーナーなら使う。課金禁止の非オーナーはローカルへ。 *)
    StringQ[s] && (s === "api" || StringStartsQ[s, "api:"]),
      If[billingOK || isOwner,
        <|"Backend" -> "api", "Model" -> If[s === "api", "", StringDrop[s, StringLength["api:"]]], "Label" -> "課金API"|>,
        <|"Backend" -> "local", "Model" -> Automatic, "Label" -> "LM Studio"|>],
    (* それ以外 = ローカルモデル名 / Automatic: 常に LM Studio *)
    True, <|"Backend" -> "local", "Model" -> s, "Label" -> "LM Studio"|>]];

(* /pdfask の回答合成 LLM。policy(ClientIP/OwnerIPs/BillingAllowed) でバックエンドを gate。
   policy 省略 (直接呼び出し=オーナー自身) は従来どおりオーナー扱い。 *)
iWebChat[prompt_String, modelOverride_ : Automatic, policy_ : <||>] := Module[{plan, r},
  plan = iWebResolveChatPlan[modelOverride, If[AssociationQ[policy], policy, <||>]];
  r = Switch[Lookup[plan, "Backend"],
    "subscription", iWebChatCloud[prompt, Lookup[plan, "Model", ""]],
    "api", iWebChatBilledAPI[prompt, Lookup[plan, "Model", ""]],
    _, iWebChatLocal[prompt, Lookup[plan, "Model", Automatic]]];
  (* サブスク/課金API が失敗したら LM Studio へフォールバック (回答を出すため)。
     フォールバック先は常に local=非オーナーがサブスクに昇格することはない。 *)
  If[! StringQ[r] && MemberQ[{"subscription", "api"}, Lookup[plan, "Backend"]],
    r = iWebChatLocal[prompt, Automatic]];
  r];

(* gate 済み結果から LLM 用の根拠テキストを組む (上位 n 件, raw path 非露出)。
   pdfSearch の context は短い (~90字, 表ヘッダのみ) ため、gate を通過した ChunkId の
   フル本文を PDFIndex`pdfGetChunk で取得して渡す (取得不可なら Snippet にフォールバック)。
   渡すのは Permit 済みチャンクのみ = gate は維持。 *)
(* 西暦 (タイトル中の 20xx) から「令和N年度版」ラベルを作る。LLM が「R7/令和7」と
   「学生便覧 2025」を結び付けられるようにするため (年度指定クエリの取りこぼし対策)。 *)
iWebEraLabel[title_String] := Module[{ys, yr},
  ys = StringCases[title, RegularExpression["20[0-9][0-9]"]];
  yr = If[ys =!= {}, Quiet @ Check[ToExpression[First[ys]], 0], 0];
  If[IntegerQ[yr] && yr >= 2019 && yr <= 2100,
    " [令和" <> ToString[yr - 2018] <> "年度版]", ""]];

(* クエリから西暦年を抽出 (20xx / 令和N / RN)。年度指定の取りこぼし対策。 *)
iWebQueryYears[q_String] := DeleteDuplicates @ Select[Flatten @ {
    Quiet @ Check[ToExpression /@ StringCases[q, RegularExpression["20[0-9][0-9]"]], {}],
    Quiet @ Check[(2018 + ToExpression[#]) & /@
      StringCases[q, RegularExpression["令和\\s*([0-9]{1,2})"] -> "$1"], {}],
    Quiet @ Check[(2018 + ToExpression[#]) & /@
      StringCases[q, RegularExpression["[RＲ]\\s*([0-9]{1,2})"] -> "$1"], {}]},
  IntegerQ];

(* 年度がクエリに含まれる場合、該当年度の doc を結果の先頭へ安定再ランク。 *)
iWebRerankByYear[results_List, years_List] := If[years === {} || results === {}, results,
  Module[{matchQ},
    matchQ[res_] := AnyTrue[years, StringContainsQ[
      ToString @ Lookup[Lookup[res, "Citation", <||>], "Title", ""], ToString[#]] &];
    Join[Select[results, matchQ], Select[results, ! matchQ[#] &]]]];

(* クエリから固有語 (科目名等) を抽出。漢字2字以上 / カタカナ3字以上 / 英数字コードを拾い、
   汎用な問い語 (配当年次・一覧 等) を除く。locale 依存語はコードに焼かず設定値。 *)
If[! ListQ[$svQueryStopwords],
  $svQueryStopwords = {"配当年次", "配当", "年次", "一覧", "単位", "科目", "年度",
    "入学", "入学者", "入学生", "授業", "教えて", "について", "場合", "対象", "何年次"}];
iWebQueryKeywords[q_String] := DeleteDuplicates @ Select[
  Flatten @ {
    StringCases[q, RegularExpression["[\\p{Han}]{2,}"]],
    StringCases[q, RegularExpression["[\\p{Katakana}ー]{3,}"]],
    StringCases[q, RegularExpression["[A-Za-z][A-Za-z0-9]{2,}"]]},
  StringLength[#] >= 2 && ! MemberQ[$svQueryStopwords, #] &];

(* 根拠の複合再ランク: クエリ固有語を literal に含むチャンクを最優先、次に年度一致、次に元順。
   埋め込み類似度だけだと大きな表ダンプ中の特定科目 (例「離散数学」) が薄まり上位に来ないため、
   キーワード一致を強い信号として加える。各候補のフル本文を取得し FullText に載せて二重取得を防ぐ。 *)
iWebRerankEvidence[results_List, q_String, collection_String] := Module[{kws, years, scored},
  kws = iWebQueryKeywords[q]; years = iWebQueryYears[q];
  If[(kws === {} && years === {}) || results === {}, Return[results]];
  scored = MapIndexed[Function[{r, i}, Module[{cid, c, full, kc, ym, title},
    cid = Lookup[r, "ChunkId", ""];
    c = Quiet @ Check[ToExpression[cid], $Failed];
    full = If[IntegerQ[c], Quiet @ Check[PDFIndex`pdfGetChunk[c, collection], $Failed], $Failed];
    If[! (StringQ[full] && StringLength[StringTrim[full]] > 0),
      full = ToString @ Lookup[r, "Snippet", ""]];
    kc = If[kws === {}, 0, Count[kws, kw_ /; StringContainsQ[full, kw]]];
    title = ToString @ Lookup[Lookup[r, "Citation", <||>], "Title", ""];
    ym = If[years =!= {} && AnyTrue[years, StringContainsQ[title, ToString[#]] &], 1, 0];
    <|"r" -> Append[r, "FullText" -> full], "kc" -> kc, "ym" -> ym, "i" -> First[i]|>]],
    results];
  Lookup[SortBy[scored, {-#["kc"] &, -#["ym"] &, #["i"] &}], "r"]];

iWebEvidenceText[results_List, n_Integer, collection_String : "default"] :=
  StringJoin @ MapIndexed[Function[{r, i},
    Module[{cit = Lookup[r, "Citation", <||>], cid = Lookup[r, "ChunkId", ""], full, c, title},
      title = ToString @ Lookup[cit, "Title", ""];
      (* 再ランクで取得済みなら FullText を再利用 (二重取得回避)、無ければ取得 *)
      full = Lookup[r, "FullText", $Failed];
      If[! (StringQ[full] && StringLength[StringTrim[full]] > 0),
        c = Quiet @ Check[ToExpression[cid], $Failed];
        full = If[IntegerQ[c],
          Quiet @ Check[PDFIndex`pdfGetChunk[c, collection], $Failed], $Failed]];
      If[! (StringQ[full] && StringLength[StringTrim[full]] > 0),
        full = ToString @ Lookup[r, "Snippet", ""]];
      "[" <> ToString[First[i]] <> "] (p." <> ToString[Lookup[cit, "Page", "?"]] <> " " <>
        title <> iWebEraLabel[title] <> ")\n" <> StringTake[full, UpTo[1500]] <> "\n\n"]],
    Take[results, UpTo[n]]];

(* PDFIndexProfile から pdfGetChunk 用の collection 名を解決 (既定 default)。
   legacy search が Collection->CollectionRoot で検索するので chunk 取得も同じ名前に揃える。 *)
iWebProfileCollection[profile_] := Module[{p, cr},
  If[! StringQ[profile], Return["default"]];
  p = Quiet @ Check[SourceVault`SearchIndexPrivate`iResolve["PDFIndexProfile", profile], $Failed];
  If[! AssociationQ[p], Return["default"]];
  cr = Lookup[p, "CollectionRoot", Automatic];
  If[StringQ[cr] && cr =!= "", cr, "default"]];

(* ドメイン中立の既定。アプリ固有 (表題・assistant persona) は endpoint profile /
   Http command で外部から差し込む。SourceVault のコードには固有名を残さない。 *)
$svWebAppTitleDefault = "SourceVault \:691c\:7d22";
$svWebAskPromptDefault = StringJoin[
  "提供された【根拠】(release gate 通過済みの検索結果)から【質問】に関連する情報を日本語でまとめて答えてください。",
  "該当する一覧・表があれば項目をできるだけ列挙してください。複数年度・複数版が含まれる場合は",
  "年度(令和N年度/西暦)を明記し、質問の年度に最も近いものを優先してください。",
  "表やOCRが読み取りにくい場合も、推測と断定は避けつつ可能な範囲で抽出してください。",
  "各事実の末尾に (p.ページ番号) を付けてください。根拠に全く該当が無い場合のみ「記載が見つかりません」と述べてください。"];

(* 非同期 /pdfask: 回答はバックグラウンド (SessionSubmit, HoldFirst で一回限り非同期) で
   生成し、ブラウザは JS ポーリングで差し込む。遅いモデルでも proxy が timeout しない。
   回答はクエリ単位でキャッシュ ($svAskCache)。 *)
If[! AssociationQ[$svAskCache], $svAskCache = <||>];

iWebAskKey[q_String, rc_, profile_, model_] :=
  IntegerString[Hash[{q, ToString[rc], ToString[profile], ToString[model]}, "SHA256"], 16];

(* curated 補足知識を根拠の上に別枠で表示 (HumanReviewed・出典明示) *)
iWebRenderCurated[curated_List] := If[curated === {}, "",
  "<h3 style='color:#cfe0ff;margin-top:20px'>補足知識 (人手レビュー済み)</h3>" <>
  StringJoin @ Map[Function[it,
    "<div style='background:#1b2330;border:1px solid #3a5a8a;border-radius:6px;padding:10px;margin:8px 0;font-size:.92em'>" <>
      iWebEsc[ToString @ Lookup[it, "Text", ""]] <>
      "<div style='opacity:.55;font-size:.8em;margin-top:6px'>HumanReviewed / EvidenceOnly" <>
      If[Lookup[it, "Years", {}] =!= {}, " / 年度: " <> iWebEsc[ToString @ Lookup[it, "Years", {}]], ""] <>
      "</div></div>"], curated]];

iWebRenderAskPage[base_String, q_String, results_List, curated_List, state_String, answer_, modelLabel_String] :=
  Module[{box, poll},
    box = Switch[state,
      "ready",
        "<div style='background:#1c2c1c;border:1px solid #3a6a3a;border-radius:8px;padding:16px;margin:12px 0;white-space:pre-wrap;line-height:1.7'>" <>
          iWebEsc[ToString[answer]] <> "</div><p style='opacity:.6;font-size:.8em'>LLM 合成回答 (モデル: " <>
          iWebEsc[modelLabel] <> ")。根拠は下記 gate 済みチャンクのみ。</p>",
      "generating",
        "<div style='background:#1c2435;border:1px solid #3a5a8a;border-radius:8px;padding:16px;margin:12px 0'>" <>
          "&#9203; 回答を生成中… (モデル: " <> iWebEsc[modelLabel] <> ")。このページは自動で更新されます。</div>",
      _,
        "<div style='background:#2a2a1a;border:1px solid #6a5a2a;border-radius:6px;padding:10px;margin:12px 0;font-size:.9em'>" <>
          "LLM 回答を生成できませんでした (該当根拠なし / LLM 利用不可)。gate 済みの根拠のみ表示します。</div>"];
    poll = If[state === "generating",
      "<script>setTimeout(function(){location.replace('" <> base <> "/pdfask?a=1&q=" <>
        URLEncode[q] <> "')},2500);</script>", ""];
    iWebHtml[base, "質問応答: " <> q,
      "<h1 style='color:#cfe0ff'>質問応答: " <> iWebEsc[q] <> "</h1>" <> iWebNav[base] <>
      iWebSearchForm[base, q, "/pdfask", "再質問"] <> box <> poll <>
      iWebRenderCurated[curated] <>
      "<h3 style='color:#cfe0ff;margin-top:20px'>根拠 (gate 済み)</h3>" <>
      iWebRenderResults[base, q, results]]];

(* バックグラウンドで LLM 回答を生成し $svAskCache[key] を ready/error に更新する。
   pending を即セットしてから SessionSubmit (HoldFirst, 一回限り非同期) で投げる。 *)
iWebKickAskJob[key_String, results_List, curated_List, prompt_String, model_, policy_ : <||>] := (
  $svAskCache[key] = <|"Status" -> "pending", "Results" -> results, "Curated" -> curated,
    "Answer" -> Null, "StartedAt" -> AbsoluteTime[]|>;
  With[{kk = key, rr = results, cc = curated, pp = prompt, mm = model, pol = policy},
    SessionSubmit[
      Module[{a = iWebChat[pp, mm, pol]},
        $svAskCache[kk] = <|"Status" -> If[StringQ[a], "ready", "error"], "Results" -> rr,
          "Curated" -> cc, "Answer" -> If[StringQ[a], a, Null], "StartedAt" -> AbsoluteTime[]|>]]];);

(* === MVP-A: curated supplemental knowledge (§18.5/§18.6.1 の最小実装) ===
   人手レビュー済みの clean text を release context / 年度 scope で限定し、gated 検索結果に
   後段マージして LLM へ「根拠」として渡す (命令ではない=EvidenceOnly)。崩れた PDF 表や
   PDF に無い凡例・慣例を補うための層。将来は §18.5 SurveyCorpus subtype + snapshot 化。 *)
If[! AssociationQ[$svCuratedKnowledge], $svCuratedKnowledge = <||>];

(* 永続化: <CoreRoot>/curated/curated_knowledge.wl。register が書き、resolve/list が最新を読む。
   これにより別プロセス (detached service) でも登録が反映され、再起動でも消えない。
   将来は §18.5 SurveyCorpus subtype + immutable snapshot store へ移行。 *)
iCuratedFile[] := Module[{r = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed]},
  If[StringQ[r], FileNameJoin[{r, "curated", "curated_knowledge.wl"}], $Failed]];

iSaveCurated[] := Module[{f = iCuratedFile[]},
  If[StringQ[f],
    Quiet @ If[! DirectoryQ[DirectoryName[f]],
      CreateDirectory[DirectoryName[f], CreateIntermediateDirectories -> True]];
    Block[{$CharacterEncoding = "UTF-8"}, Quiet @ Put[$svCuratedKnowledge, f]]; True,
    False]];

iLoadCurated[] := Module[{f = iCuratedFile[], r},
  If[StringQ[f] && FileExistsQ[f],
    r = Block[{$CharacterEncoding = "UTF-8"}, Quiet @ Check[Get[f], $Failed]];
    If[AssociationQ[r], $svCuratedKnowledge = r]];
  $svCuratedKnowledge];

SourceVault`SourceVaultRegisterCuratedKnowledge[id_String, spec_Association] := (
  iLoadCurated[];   (* 既存 (他カーネル登録含む) を読んでから追加し、上書き喪失を防ぐ *)
  $svCuratedKnowledge[id] = Join[<|
    "Years" -> {}, "Unit" -> All, "QuestionClasses" -> All,
    "ReleaseContexts" -> {}, "ReviewState" -> "HumanReviewed",
    "AllowedUse" -> "EvidenceOnly", "SourceRefs" -> {}, "Text" -> ""|>, spec];
  <|"Status" -> "OK", "Id" -> id, "Persisted" -> iSaveCurated[]|>);

SourceVault`SourceVaultListCuratedKnowledge[opts___] := (iLoadCurated[]; Normal[$svCuratedKnowledge]);

(* #4: 崩れ表 curated 転記支援 (§18.10 ChunkCorrection / §18.6.7 human editing assist)。
   OCR で構造が崩れた表チャンクを LLM で clean に「転記」し、人手レビュー前提のドラフト
   curated 項目として返す。自動登録しない (ReviewState=NeedsHumanReview)。
   人手で内容確認・修正後に SourceVaultRegisterCuratedKnowledge[..., ReviewState->"HumanReviewed"] する。 *)
Options[SourceVault`SourceVaultDraftCuratedTranscription] = {
  "Collection" -> "default", "ChunkIds" -> Automatic, "Limit" -> 4,
  "ChatModel" -> "cloud", "Years" -> {}, "Unit" -> All, "ReleaseContexts" -> {}};
SourceVault`SourceVaultDraftCuratedTranscription[query_String, OptionsPattern[]] := Module[
  {coll, chunkIds, rawTexts, prompt, clean},
  coll = OptionValue["Collection"];
  chunkIds = OptionValue["ChunkIds"];
  If[chunkIds === Automatic,
    Module[{r = Quiet @ Check[PDFIndex`pdfSearch[query, OptionValue["Limit"]], $Failed], rows},
      rows = Which[Head[r] === Dataset, Normal[r], ListQ[r], r, True, {}];
      chunkIds = Select[Lookup[#, "chunkIdx", Missing[]] & /@ rows, IntegerQ]]];
  If[! (ListQ[chunkIds] && chunkIds =!= {}),
    Return[Failure["NoSourceChunks", <|
      "MessageTemplate" -> "転記元チャンクが見つかりません (ChunkIds か query を確認)。"|>]]];
  rawTexts = Table[ToString @ Quiet @ Check[PDFIndex`pdfGetChunk[c, coll], ""], {c, chunkIds}];
  prompt = StringJoin[
    "以下は PDF から OCR 抽出された、構造が崩れた表の生テキストです。",
    "元の表構造(行・列・科目名・科目コード・記号)をできるだけ保ったまま、人が読める clean な箇条書き/表に転記してください。\n",
    "重要: 原文にない内容を推測で追加しないこと。読み取れない箇所は (判読不可) と記すこと。",
    "記号(②△●等)はそのまま残すこと。年度・学科などの見出しがあれば明記すること。\n\n",
    "【生テキスト】\n", StringRiffle[rawTexts, "\n---\n"], "\n\n【clean 転記】"];
  clean = iWebChat[prompt, OptionValue["ChatModel"]];
  If[! StringQ[clean],
    Return[Failure["TranscriptionFailed", <|
      "MessageTemplate" -> "LLM 転記に失敗しました (ChatModel / LM Studio / cloud 認証を確認)。"|>]]];
  <|"Status" -> "OK", "CleanText" -> clean, "SourceChunkIds" -> chunkIds,
    "ReviewState" -> "NeedsHumanReview",
    "Note" -> "LLM による転記ドラフト。内容を人手で確認・修正してから " <>
      "SourceVaultRegisterCuratedKnowledge で ReviewState->\"HumanReviewed\" として登録すること。",
    "ProposedCuratedSpec" -> <|
      "Text" -> clean, "Years" -> OptionValue["Years"], "Unit" -> OptionValue["Unit"],
      "ReleaseContexts" -> OptionValue["ReleaseContexts"],
      "SourceRefs" -> ("chunk:" <> coll <> ":" <> ToString[#] & /@ chunkIds),
      "SourceRelation" -> "Corrects", "ReviewState" -> "NeedsHumanReview"|>|>];

(* release context が一致 (gate) し、年度 scope が一致する HumanReviewed curated を上位 n 件。
   score 非依存で常時採用 (§18.6.1 CuratedEvidencePolicyProfile.MergeOrder 相当)。 *)
iWebResolveCurated[q_String, rc_, n_Integer : 3] := Module[{years, items},
  iLoadCurated[];   (* 別カーネル/再起動後も最新を反映 *)
  years = iWebQueryYears[q];
  items = Select[Values[$svCuratedKnowledge],
    Lookup[#, "ReviewState", ""] === "HumanReviewed" &&
    Lookup[#, "AllowedUse", "EvidenceOnly"] =!= "PromptInstructionCandidate" &&
    StringQ[rc] && MemberQ[Lookup[#, "ReleaseContexts", {}], rc] &&
    (Lookup[#, "Years", {}] === {} || years === {} ||
       IntersectingQ[Lookup[#, "Years", {}], years]) &];
  Take[items, UpTo[n]]];

iWebCuratedText[items_List] := If[items === {}, "",
  StringJoin @ MapIndexed[Function[{it, i},
    "[C" <> ToString[First[i]] <> " 人手レビュー済み補足] " <>
      ToString @ Lookup[it, "Text", ""] <> "\n\n"], items]];

(* === MVP-B: EvidenceGap + AnswerGrounding 「列挙OK・分類断定NG」(§18.2/§18.3/§18.17) ===
   凡例(LegendMap)が無い分類質問では、候補列挙は許すが必修/選択の断定はさせず、
   EvidenceGap を記録する。凡例を curated に登録すると分類が解禁される。
   locale 依存語は設定値 (コードに焼かない)。private profile から上書き可。 *)
If[! AssociationQ[$svEvidenceGaps], $svEvidenceGaps = <||>];
If[! ListQ[$svClassificationIntentPhrases],
  $svClassificationIntentPhrases = {"必修", "選択必修", "選択科目", "分類"}];

(* curated に LegendMap / ProvidesLegend があれば凡例利用可 (= classification 解禁条件) *)
iWebLegendAvailable[curated_List] := AnyTrue[curated, Function[it,
  TrueQ[Lookup[it, "ProvidesLegend", False]] ||
  (AssociationQ[Lookup[it, "LegendMap", None]] && Lookup[it, "LegendMap"] =!= <||>)]];

iWebIsClassificationQuery[q_String] :=
  AnyTrue[$svClassificationIntentPhrases, StringContainsQ[q, #] &];

iWebGroundingPolicyText[legendAvail_, classQuery_] := Which[
  ! TrueQ[classQuery], "",
  TrueQ[legendAvail],
    "\n\n【判定方針】補足知識に凡例(LegendMap)があるので、必修/選択の分類を凡例に従って示してよい。各分類に凡例の出典を明記すること。",
  True,
    "\n\n【判定方針】凡例(必修記号の意味)が未確認なので、該当する候補科目は列挙してよいが、必修/選択の分類は断定しないこと。「凡例未確認のため必修/選択は未確定」と明記し、推測で必修と断定しないこと。"];

(* EvidenceGap 永続化 (<CoreRoot>/curated/evidence_gaps.wl, GapId キー) *)
iEvidenceGapFile[] := Module[{r = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], $Failed]},
  If[StringQ[r], FileNameJoin[{r, "curated", "evidence_gaps.wl"}], $Failed]];
iLoadGaps[] := Module[{f = iEvidenceGapFile[], r},
  If[StringQ[f] && FileExistsQ[f],
    r = Block[{$CharacterEncoding = "UTF-8"}, Quiet @ Check[Get[f], $Failed]];
    If[AssociationQ[r], $svEvidenceGaps = r]]; $svEvidenceGaps];
iSaveGaps[] := Module[{f = iEvidenceGapFile[]},
  If[StringQ[f],
    Quiet @ If[! DirectoryQ[DirectoryName[f]],
      CreateDirectory[DirectoryName[f], CreateIntermediateDirectories -> True]];
    Block[{$CharacterEncoding = "UTF-8"}, Quiet @ Put[$svEvidenceGaps, f]]; True, False]];
iRecordEvidenceGap[gap_Association] := Module[{gid},
  iLoadGaps[];
  gid = "gap:" <> IntegerString[Hash[{Lookup[gap, "GapKind", ""], Lookup[gap, "Question", ""],
    Lookup[gap, "ReleaseContext", ""]}, "SHA256"], 16, 12];
  If[! KeyExistsQ[$svEvidenceGaps, gid] || Lookup[$svEvidenceGaps[gid], "State", "Open"] === "Closed",
    $svEvidenceGaps[gid] = Join[<|"GapId" -> gid, "State" -> "Open",
      "CreatedAtUTC" -> iSMUTCNow[]|>, gap]; iSaveGaps[]];
  gid];
(* 公開記録 API (他サブモジュール=webingest の fetch 失敗等から EvidenceGap を記録するため。
   private iRecordEvidenceGap への薄いラッパー。dedup は {GapKind, Question, ReleaseContext}。 *)
SourceVault`SourceVaultRecordEvidenceGap::usage =
  "SourceVaultRecordEvidenceGap[gap] は EvidenceGap を記録し GapId を返す。\n" <>
  "gap は <|\"GapKind\", \"Question\", ...|>。同一 {GapKind, Question, ReleaseContext} は dedup される。";
SourceVault`SourceVaultRecordEvidenceGap[gap_Association] := iRecordEvidenceGap[gap];

SourceVault`SourceVaultListEvidenceGaps[opts___] := (iLoadGaps[]; Normal[$svEvidenceGaps]);
SourceVault`SourceVaultCloseEvidenceGap[gapId_String, opts___] := (iLoadGaps[];
  If[KeyExistsQ[$svEvidenceGaps, gapId],
    $svEvidenceGaps[gapId] = Append[$svEvidenceGaps[gapId], "State" -> "Closed"]; iSaveGaps[];
    <|"Status" -> "OK", "GapId" -> gapId|>, <|"Status" -> "NotFound", "GapId" -> gapId|>]);

iServiceHttpRender[cmd_Association] := Module[
  {method, path, qs, query, base, rc, profile, body, appTitle, askPrompt, chatModel},
  method = ToUpperCase @ ToString @ Lookup[cmd, "Method", "GET"];
  path = ToString @ Lookup[cmd, "Path", "/"];
  qs = ToString @ Lookup[cmd, "Query", ""];
  base = ToString @ Lookup[cmd, "RoutePrefix", "/sv"];
  rc = Lookup[cmd, "ReleaseContext"];
  profile = Lookup[cmd, "PDFIndexProfile", None];
  body = ToString @ Lookup[cmd, "Body", ""];
  query = iWebParseQuery[qs];
  appTitle = Lookup[cmd, "AppTitle", Null];
  appTitle = If[StringQ[appTitle] && appTitle =!= "", appTitle, $svWebAppTitleDefault];
  askPrompt = Lookup[cmd, "AskPrompt", Null];
  askPrompt = If[StringQ[askPrompt] && askPrompt =!= "", askPrompt, $svWebAskPromptDefault];
  chatModel = Lookup[cmd, "ChatModel", Null];  (* 文字列でなければ Automatic 扱い *)
  Which[
    path === "/style.css",
      <|"StatusCode" -> 200, "ContentType" -> "text/css; charset=utf-8", "Body" -> iWebCss[]|>,

    path === "/" || path === "",
      iWebHtml[base, appTitle,
        "<h1 style='color:#cfe0ff'>" <> iWebEsc[appTitle] <> "</h1>" <> iWebNav[base] <>
        iWebSearchForm[base, "", "/pdfsearch", "検索"]],

    path === "/pdfsearch" || path === "/search",
      Module[{q = ToString @ Lookup[query, "q", ""], sr, rr},
        If[StringTrim[q] === "",
          iWebHtml[base, appTitle,
            "<h1 style='color:#cfe0ff'>" <> iWebEsc[appTitle] <> "</h1>" <> iWebNav[base] <>
            iWebSearchForm[base, "", "/pdfsearch", "検索"]],
          sr = iWebGatedSearch[q, rc, profile, 40];
          If[! TrueQ[sr["ok"]], iWebErr[base, sr["reason"]],
            (* /pdfask と同じくクエリ固有語+年度で再ランクし上位 20 を表示 *)
            rr = Take[iWebRerankEvidence[sr["results"], q, iWebProfileCollection[profile]], UpTo[20]];
            iWebHtml[base, "検索結果: " <> q, iWebRenderResults[base, q, rr]]]]],

    path === "/pdfsearch/api" || path === "/search.json",
      Module[{q, sr, payload},
        q = If[method === "POST" && StringLength[StringTrim[body]] > 0,
          ToString @ Lookup[Quiet @ iSMParseRawJSON[StringToByteArray[body, "UTF-8"]], "query",
            ToString @ Lookup[query, "q", ""]],
          ToString @ Lookup[query, "q", ""]];
        sr = iWebGatedSearch[q, rc, profile];
        payload = If[TrueQ[sr["ok"]],
          <|"Status" -> "OK", "Query" -> q, "Count" -> Length[sr["results"]], "Results" -> sr["results"]|>,
          <|"Status" -> "Error", "Reason" -> sr["reason"]|>];
        <|"StatusCode" -> 200, "ContentType" -> "application/json; charset=utf-8",
          "Body" -> Quiet @ ExportString[iSMJSONSafe[payload], "RawJSON"]|>],

    (* 質問応答 (非同期): 初回は gated 検索→根拠を即時表示し、回答は SessionSubmit で
       バックグラウンド生成。ブラウザは ?a=1 へ JS ポーリングして回答を差し込む。
       LLM が遅くても proxy は待たない (各リクエストは即応)。gate 済み根拠のみ LLM に渡す。 *)
    path === "/pdfask",
      Module[{q = ToString @ Lookup[query, "q", ""], key, entry, sr, rr, coll, modelLabel,
              curated, legendAvail, classQuery, policy},
        If[method === "POST" && StringLength[StringTrim[body]] > 0,
          q = ToString @ Lookup[iWebParseQuery[body], "q", q]];
        (* リクエスト元 IP とライセンス/課金ポリシー: ClaudeCode はオーナーのみ *)
        policy = <|"ClientIP" -> Lookup[cmd, "ClientIP", None],
          "OwnerIPs" -> Lookup[cmd, "OwnerIPs", SourceVault`$SourceVaultOwnerIPs],
          "BillingAllowed" -> Lookup[cmd, "BillingAllowed", SourceVault`$SourceVaultBillingAllowed],
          (* web 経路はサブスクを既定で不使用 (proxy が許可条件を満たす時のみ True) *)
          "SubscriptionAllowed" -> Lookup[cmd, "SubscriptionAllowed", False]|>;
        modelLabel = Lookup[iWebResolveChatPlan[chatModel, policy], "Label", "LM Studio"];
        If[StringTrim[q] === "",
          iWebHtml[base, "質問応答",
            "<h1 style='color:#cfe0ff'>質問応答 <span style='font-size:.5em;opacity:.6'>(LLM 回答合成・非同期)</span></h1>" <>
            iWebNav[base] <> iWebSearchForm[base, "", "/pdfask", "質問する"]],
          key = iWebAskKey[q, rc, profile, chatModel];
          entry = Lookup[$svAskCache, key, None];
          Which[
            AssociationQ[entry] && entry["Status"] === "ready",
              iWebRenderAskPage[base, q, entry["Results"], Lookup[entry, "Curated", {}], "ready", entry["Answer"], modelLabel],
            AssociationQ[entry] && entry["Status"] === "error",
              iWebRenderAskPage[base, q, entry["Results"], Lookup[entry, "Curated", {}], "error", Null, modelLabel],
            AssociationQ[entry] && entry["Status"] === "pending",
              (* ハング保険: 240 秒超の pending は error 扱い *)
              If[AbsoluteTime[] - Lookup[entry, "StartedAt", AbsoluteTime[]] > 240,
                ($svAskCache[key] = Append[entry, "Status" -> "error"];
                 iWebRenderAskPage[base, q, entry["Results"], Lookup[entry, "Curated", {}], "error", Null, modelLabel]),
                iWebRenderAskPage[base, q, entry["Results"], Lookup[entry, "Curated", {}], "generating", Null, modelLabel]],
            True,
              (* 初回: gated 検索 (候補多め) → クエリ固有語+年度で複合再ランク → 背景生成起動。
                 固有語 (例「離散数学」) を含むチャンクを根拠上位へ押し上げて取りこぼしを防ぐ。 *)
              sr = iWebGatedSearch[q, rc, profile, 40];
              If[! TrueQ[sr["ok"]],
                iWebErr[base, sr["reason"]],
                coll = iWebProfileCollection[profile];
                rr = Take[iWebRerankEvidence[sr["results"], q, coll], UpTo[15]];
                curated = iWebResolveCurated[q, rc];   (* 人手レビュー済み補足を scope/RC で解決 *)
                legendAvail = iWebLegendAvailable[curated];
                classQuery = iWebIsClassificationQuery[q];
                (* 凡例なしの分類質問は EvidenceGap として記録 (列挙は許可・分類は抑制) *)
                If[classQuery && ! legendAvail && StringQ[rc],
                  iRecordEvidenceGap[<|"GapKind" -> "TableLegendMissing", "Question" -> q,
                    "ReleaseContext" -> rc, "MissingEvidenceKinds" -> {"LegendMap"},
                    "AllowedAnswerMode" -> "EnumerateWithoutClassification"|>]];
                If[rr === {} && curated === {},
                  ($svAskCache[key] = <|"Status" -> "error", "Results" -> {}, "Answer" -> Null,
                     "StartedAt" -> AbsoluteTime[]|>;
                   iWebRenderAskPage[base, q, {}, {}, "error", Null, modelLabel]),
                  (iWebKickAskJob[key, rr, curated,
                     StringJoin[askPrompt, "\n\n【質問】", q,
                       If[curated =!= {},
                         "\n\n【補足知識(人手レビュー済み・最優先で参照)】\n" <> iWebCuratedText[curated], ""],
                       "\n\n【根拠(PDF)】\n", iWebEvidenceText[rr, 12, coll],
                       iWebGroundingPolicyText[legendAvail, classQuery], "\n【回答】"], chatModel, policy];
                   iWebRenderAskPage[base, q, rr, curated, "generating", Null, modelLabel])]]
          ]]],

    (* ページ画像表示: {"PageImages",n} で headless レンダリング (FrontEnd 不要)。
       ?p=N で物理ページ直接、?q=... で gated 検索→上位ヒットのページ。?doc= で年度指定。 *)
    path === "/pdfpage",
      Module[{collection = "default", p = StringTrim @ ToString @ Lookup[query, "p", ""],
              q = ToString @ Lookup[query, "q", ""], docTitle = ToString @ Lookup[query, "doc", ""],
              pageNum, sr, top, cit, pg},
        Which[
          p =!= "" && IntegerQ[Quiet @ ToExpression[p]],
            iWebRenderPageView[base, collection, ToExpression[p], docTitle],
          StringTrim[q] =!= "",
            sr = iWebGatedSearch[q, rc, profile];
            If[! TrueQ[sr["ok"]], iWebErr[base, sr["reason"]],
              If[sr["results"] === {},
                iWebHtml[base, "ページ表示",
                  "<h1 style='color:#cfe0ff'>ページ表示</h1>" <> iWebNav[base] <>
                  "<p>該当ページが見つかりませんでした。</p>" <> iWebSearchForm[base, q, "/pdfpage", "ページ検索"]],
                top = First[sr["results"]]; cit = Lookup[top, "Citation", <||>];
                pg = Lookup[cit, "Page", 1]; If[! IntegerQ[pg], pg = Quiet @ ToExpression @ ToString[pg]];
                If[! IntegerQ[pg], pg = 1];
                iWebRenderPageView[base, collection, pg, ToString @ Lookup[cit, "DocId", Lookup[cit, "Title", ""]]]]],
          True,
            iWebHtml[base, "ページ表示",
              "<h1 style='color:#cfe0ff'>ページ表示</h1>" <> iWebNav[base] <>
              "<p style='opacity:.7'>ページ番号(p=) または 検索語(q=) を指定してください。</p>" <>
              iWebSearchForm[base, "", "/pdfpage", "ページ検索"]]]],

    path === "/pdfimgdata",
      <|"StatusCode" -> 200, "ContentType" -> "text/plain; charset=utf-8",
        "Body" -> ""|>,

    True,
      <|"StatusCode" -> 404, "ContentType" -> "text/html; charset=utf-8",
        "Body" -> iWebPage[base, "404", "<h2>404 Not Found</h2><p>" <> iWebEsc[path] <> "</p>" <> iWebNav[base]]|>]];

(* ============================================================
   WLMCP: Wolfram AgentTools MCP を SourceVault サービスカーネルに集約する
   (旧 wlmcp-gateway の専用 StartMCPServer カーネル = 独立プロセス枠 1 席を回収)。

   設計 (席 3->2 統合・案B サブカーネル隔離):
   - 実行体はサービスカーネルが抱える永続サブカーネル (サブプロセス枠 16 側。
     プロセス席を消費しない)。AgentTools の startMCPServer は「init 部」と
     「stdio While ループ」が分離可能で、リクエスト処理の実体 handleMethod は
     stdio に触れない純関数 (paclet 2.1.21 実測)。init をサブカーネル内で再現し、
     JSON-RPC メッセージごとに handleMethod を呼ぶ。
   - 非ブロッキング: WLMCP command は ParallelSubmit で投げて即 return
     (done を書かない=deferred)。tick の poll が結果ファイル (WXF) を検出して
     done を書く。長い評価中もサービスの heartbeat / sv MCP は生き続ける。
   - 隔離: 任意コード評価は資格情報を持つサービスカーネルでなくサブカーネルで
     走る。評価が wedge したら subkernel を kill/relaunch (サービス本体は無傷)。
   - 有効条件: $SourceVaultServiceWLMCPEnabled (Automatic = serviceId が
     "sourcevault" のときのみ)。init 失敗時は Ready=False で各リクエストに
     明示エラーを返す (無言タイムアウトにしない)。旧 gateway 構成は fallback
     として残せる。
   ============================================================ *)

If[! ValueQ[$SourceVaultServiceWLMCPEnabled],
  $SourceVaultServiceWLMCPEnabled = Automatic];
If[! ValueQ[$iSMWLMCPKernels], $iSMWLMCPKernels = {}];
If[! AssociationQ[$iSMWLMCPPending], $iSMWLMCPPending = <||>];
If[! ValueQ[$iSMWLMCPReady], $iSMWLMCPReady = False];
If[! ValueQ[$iSMWLMCPInitResult], $iSMWLMCPInitResult = <|"Status" -> "NotAttempted"|>];
$iSMWLMCPServerName = "WolframLanguage";
$iSMWLMCPHardTTLSeconds = 240;   (* これを超えた pending は wedge 扱い -> kernel 再生成 *)

iSMWLMCPEnabledQ[serviceId_String] := Which[
  TrueQ[$SourceVaultServiceWLMCPEnabled], True,
  $SourceVaultServiceWLMCPEnabled === Automatic, serviceId === "sourcevault",
  True, False];

(* サブカーネル内に定義するドライバ。AgentTools private 実装への参照はすべて
   完全修飾 (Begin トリックは別コンテキスト由来ヘルパ catchAlways 等に新規空
   シンボルを intern してしまい未評価連鎖になる: 実測)。init は startMCPServer
   本体 (StartMCPServer.wl) の再現から stdio 部分を除いたもの。paclet 更新で
   private シンボル名が変わったら Init が失敗し Ready=False に落ちる (fail-soft)。 *)
$iSMWLMCPDriverSource = "
SourceVault`WLMCPChild`Init[name_String] := Module[
  {obj, llmTools, toolList, promptList, promptLookup, logFile},
  Needs[\"Wolfram`AgentTools`\"];
  obj = Wolfram`AgentTools`Common`ensureMCPServerExists @
    Wolfram`AgentTools`MCPServerObject[name];
  obj = Wolfram`AgentTools`StartMCPServer`Private`ensurePacletsForStart @ obj;
  Wolfram`AgentTools`StartMCPServer`Private`runServerInitialization @ obj;
  llmTools = Wolfram`AgentTools`StartMCPServer`Private`disambiguateToolNames @
    obj[\"Tools\"];
  Wolfram`AgentTools`StartMCPServer`Private`runToolInitialization @ Values @ llmTools;
  toolList = KeyValueMap[
    Wolfram`AgentTools`StartMCPServer`Private`createMCPToolData, llmTools];
  promptList = Wolfram`AgentTools`StartMCPServer`Private`makePromptData @
    obj[\"PromptData\"];
  promptLookup = Wolfram`AgentTools`StartMCPServer`Private`makePromptLookup @
    obj[\"PromptData\"];
  Wolfram`AgentTools`Common`initializeUIResources[];
  Wolfram`AgentTools`Common`$toolOptions =
    Wolfram`AgentTools`StartMCPServer`Private`parseToolOptions @
      Environment[\"MCP_TOOL_OPTIONS\"];
  logFile = Quiet @ Check[
    Wolfram`AgentTools`Common`ensureFilePath @
      Wolfram`AgentTools`Common`mcpServerLogFile @ obj,
    FileNameJoin[{$TemporaryDirectory, \"svwlmcp.log\"}]];
  Wolfram`AgentTools`StartMCPServer`Private`$toolList = toolList;
  Wolfram`AgentTools`StartMCPServer`Private`$llmTools = llmTools;
  Wolfram`AgentTools`StartMCPServer`Private`$promptList = promptList;
  Wolfram`AgentTools`StartMCPServer`Private`$promptLookup = promptLookup;
  Wolfram`AgentTools`StartMCPServer`Private`$logFile = logFile;
  Wolfram`AgentTools`StartMCPServer`Private`$currentMCPServer = obj;
  Wolfram`AgentTools`Common`$mcpEvaluation = True;
  SourceVault`WLMCPChild`$Ready =
    AssociationQ[llmTools] && ListQ[toolList] && Length[toolList] > 0;
  <|\"Status\" -> If[TrueQ[SourceVault`WLMCPChild`$Ready], \"Initialized\", \"InitFailed\"],
    \"Tools\" -> If[ListQ[toolList], Length[toolList], -1]|>];
SourceVault`WLMCPChild`Handle[msg_Association] := Module[{method, id, req, resp},
  method = Lookup[msg, \"method\", None];
  id = Lookup[msg, \"id\", Null];
  req = <|\"jsonrpc\" -> \"2.0\", \"id\" -> id|>;
  resp = Wolfram`AgentTools`Common`catchAlways @
    Wolfram`AgentTools`StartMCPServer`Private`handleMethod[method, msg, req];
  If[! AssociationQ[resp],
    <|req, \"error\" -> <|\"code\" -> -32603, \"message\" -> \"Internal error\"|>|>,
    resp]];
";

iSMWLMCPEnsure[dir_String] := Module[{init},
  If[TrueQ[$iSMWLMCPReady] && $iSMWLMCPKernels =!= {}, Return[True]];
  $iSMWLMCPKernels = Quiet @ Check[
    Select[Flatten[{$iSMWLMCPKernels}], MemberQ[Kernels[], #] &], {}];
  If[$iSMWLMCPKernels === {},
    $iSMWLMCPKernels = Quiet @ Check[LaunchKernels[1], $Failed];
    If[! ListQ[$iSMWLMCPKernels] || $iSMWLMCPKernels === {},
      $iSMWLMCPKernels = {}; $iSMWLMCPReady = False;
      $iSMWLMCPInitResult = <|"Status" -> "LaunchFailed"|>;
      iServiceLog[dir, "WLMCPInitFailed", <|"Reason" -> "LaunchFailed"|>];
      Return[False]]];
  init = With[{drv = $iSMWLMCPDriverSource, srv = $iSMWLMCPServerName},
    Quiet @ Check[
      ParallelEvaluate[
        ToExpression[drv];
        Quiet @ SourceVault`WLMCPChild`Init[srv],
        First[$iSMWLMCPKernels]],
      $Failed]];
  $iSMWLMCPInitResult = If[AssociationQ[init], init, <|"Status" -> "InitException"|>];
  $iSMWLMCPReady = AssociationQ[init] &&
    Lookup[init, "Status", ""] === "Initialized";
  iServiceLog[dir, If[$iSMWLMCPReady, "WLMCPInitialized", "WLMCPInitFailed"],
    $iSMWLMCPInitResult];
  $iSMWLMCPReady];

iSMWLMCPResultFile[dir_String, doneName_String] :=
  FileNameJoin[{dir, "wlmcp", doneName <> ".wxf"}];

(* JSON-RPC error 応答つき done を即書き (backend 不可時の明示エラー) *)
iSMWLMCPFailDone[dir_String, doneName_String, cmd_Association, msgStr_String] :=
  iSMWriteJSON[FileNameJoin[{dir, "commands", "done", doneName}],
    Join[cmd, <|"Result" -> <|"Status" -> "OK",
      "WLMCP" -> <|"jsonrpc" -> "2.0",
        "id" -> Lookup[Lookup[cmd, "Message", <||>], "id", Null],
        "error" -> <|"code" -> -32000, "message" -> msgStr|>|>|>,
      "ProcessedAtUTC" -> iSMUTCNow[]|>]];

(* WLMCP command 受付: サブカーネルへ submit し done は書かない (deferred)。
   poll (iSMWLMCPPoll) が結果ファイルを検出して done を書く。 *)
iSMWLMCPAccept[dir_String, doneName_String, cmd_Association] := Module[
  {msg = Lookup[cmd, "Message", <||>], rf, eo},
  If[! AssociationQ[msg],
    iSMWLMCPFailDone[dir, doneName, cmd, "WLMCP: Message missing"]; Return[Null]];
  If[! iSMWLMCPEnsure[dir],
    iSMWLMCPFailDone[dir, doneName, cmd,
      "WLMCP backend unavailable: " <>
        ToString[Lookup[$iSMWLMCPInitResult, "Status", "?"]]];
    Return[Null]];
  rf = iSMWLMCPResultFile[dir, doneName];
  iSMEnsureDir[DirectoryName[rf]];
  If[FileExistsQ[rf], Quiet @ DeleteFile[rf]];
  (* 外側 With で値をサブカーネル評価式に焼き込む (ParallelSubmit は HoldFirst)。
     ドライバ再定義ガード入り = kernel 再生成後も自己修復。 *)
  eo = With[{msgv = msg, rfv = rf, drv = $iSMWLMCPDriverSource,
       srv = $iSMWLMCPServerName},
    ParallelSubmit[
      Module[{resp},
        If[! TrueQ[SourceVault`WLMCPChild`$Ready],
          ToExpression[drv];
          Quiet @ SourceVault`WLMCPChild`Init[srv]];
        resp = Quiet @ SourceVault`WLMCPChild`Handle[msgv];
        Export[rfv, resp, "WXF"]]]];
  Quiet @ Check[Parallel`Developer`QueueRun[], Null];
  $iSMWLMCPPending[doneName] = <|"EO" -> eo, "ResultFile" -> rf,
    "Cmd" -> cmd, "SubmittedAbs" -> AbsoluteTime[]|>;
  Null];

(* pending の結果ファイルを検出して done を書く。waitSeconds > 0 なら
   pending が残っている間その秒数まで短周期で追いポーリング (速い評価を
   同一 tick 内で返してレイテンシを ~0.1s に抑える)。TTL 超過は wedge 扱い:
   タイムアウトエラーを done に書き、subkernel を作り直す。 *)
iSMWLMCPPoll[dir_String, waitSeconds_: 0] := Module[{t0 = AbsoluteTime[], finalized},
  If[$iSMWLMCPPending === <||>, Return[Null]];
  While[True,
    Quiet @ Check[Parallel`Developer`QueueRun[], Null];
    finalized = {};
    KeyValueMap[
      Function[{doneName, info},
        Module[{rf = info["ResultFile"], resp, age},
          age = AbsoluteTime[] - info["SubmittedAbs"];
          Which[
            FileExistsQ[rf],
              resp = Quiet @ Check[Import[rf, "WXF"], $Failed];
              Quiet @ Check[WaitNext[{info["EO"]}], Null];
              Quiet @ DeleteFile[rf];
              iSMWriteJSON[FileNameJoin[{dir, "commands", "done", doneName}],
                Join[info["Cmd"], <|"Result" -> <|"Status" -> "OK",
                  "WLMCP" -> If[AssociationQ[resp], resp,
                    <|"jsonrpc" -> "2.0",
                      "id" -> Lookup[Lookup[info["Cmd"], "Message", <||>], "id", Null],
                      "error" -> <|"code" -> -32603,
                        "message" -> "WLMCP: result unreadable"|>|>]|>,
                  "ProcessedAtUTC" -> iSMUTCNow[]|>]];
              AppendTo[finalized, doneName],
            age > $iSMWLMCPHardTTLSeconds,
              (* wedge: タイムアウトを返し、kernel を作り直す *)
              iSMWLMCPFailDone[dir, doneName, info["Cmd"],
                "WLMCP: evaluation exceeded " <>
                  ToString[$iSMWLMCPHardTTLSeconds] <> "s (kernel recycled)"];
              Quiet @ Check[CloseKernels[$iSMWLMCPKernels], Null];
              $iSMWLMCPKernels = {}; $iSMWLMCPReady = False;
              iServiceLog[dir, "WLMCPKernelRecycled", <|"DoneName" -> doneName|>];
              AppendTo[finalized, doneName],
            True, Null]]],
      $iSMWLMCPPending];
    Scan[($iSMWLMCPPending = KeyDrop[$iSMWLMCPPending, #]) &, finalized];
    If[$iSMWLMCPPending === <||> ||
       (AbsoluteTime[] - t0) >= waitSeconds, Break[]];
    Pause[0.05]];
  Null];

iDispatchServiceCommand[cmd_Association] := Switch[Lookup[cmd, "Command"],
  "Ping", <|"Status" -> "OK", "Pong" -> True, "AtUTC" -> iSMUTCNow[]|>,
  "WLMCPStatus",
    <|"Status" -> "OK", "Ready" -> TrueQ[$iSMWLMCPReady],
      "Init" -> $iSMWLMCPInitResult,
      "Pending" -> Length[$iSMWLMCPPending],
      "Kernels" -> Length[$iSMWLMCPKernels], "AtUTC" -> iSMUTCNow[]|>,
  "Http",
    Module[{r = Quiet @ iServiceHttpRender[cmd]},
      If[AssociationQ[r] && KeyExistsQ[r, "Body"],
        Join[<|"Status" -> "OK"|>, r],
        <|"Status" -> "OK", "StatusCode" -> 500,
          "ContentType" -> "text/html; charset=utf-8",
          "Body" -> "<!DOCTYPE html><html><head><meta charset='utf-8'></head><body><h2>500</h2><p>render error</p></body></html>"|>]],
  "Stop", <|"Status" -> "OK", "Stop" -> True|>,
  "Echo", <|"Status" -> "OK", "Echo" -> Lookup[cmd, "Payload"]|>,
  (* D2 検証: service kernel で grant crypto が使えるか実地に確認する。
     ensure key -> mint(短命) -> verify を service 側で実行。crypto が service loader に
     入っていれば CryptoLoaded/MintOK/VerifyValid が True になる。 *)
  "MCPGrantSelfTest",
    Module[{cryptoLoaded, grantFn, ek, g, v},
      cryptoLoaded = Length[DownValues[SourceVault`SourceVaultHMACSHA256Hex]] > 0;
      grantFn = Length[DownValues[SourceVault`SourceVaultMCPVerifyAccessGrant]] > 0;
      ek = If[grantFn, Quiet @ SourceVault`SourceVaultMCPEnsureGrantKey[], $Failed];
      g = If[grantFn,
        Quiet @ SourceVault`SourceVaultMCPMintAccessGrant[<|"AllowedKinds" -> {"mail"}, "TTLSeconds" -> 60|>],
        $Failed];
      v = If[AssociationQ[g],
        Quiet @ SourceVault`SourceVaultMCPVerifyAccessGrant[g], <|"Valid" -> False|>];
      <|"Status" -> "OK", "CryptoLoaded" -> cryptoLoaded, "GrantFnLoaded" -> grantFn,
        "KeyEnsured" -> (AssociationQ[ek] && ! FailureQ[ek]),
        "MintOK" -> AssociationQ[g],
        "VerifyValid" -> TrueQ[Lookup[v, "Valid", False]], "AtUTC" -> iSMUTCNow[]|>],
  "Search",
    (* gate は SourceVaultSearch (SearchIndex) が request-time に行う。
       ReleaseContext / PDFIndexProfile は command に含めて proxy から渡す。 *)
    Module[{rc = Lookup[cmd, "ReleaseContext"], res},
      If[! StringQ[rc],
        <|"Status" -> "Error", "Reason" -> "ReleaseContextRequired"|>,
        res = SourceVault`SourceVaultSearch[Lookup[cmd, "Query", ""],
          "ReleaseContext" -> rc,
          "PDFIndexProfile" -> Lookup[cmd, "PDFIndexProfile", None],
          "Limit" -> Lookup[cmd, "Limit", 20]];
        If[FailureQ[res],
          <|"Status" -> "Error", "Reason" -> ToString[res]|>,
          <|"Status" -> "OK", "Results" -> res, "Count" -> Length[res]|>]]],
  (* ---- Web ingest job 二層 (spec v6 §7) ----
     job 側の "Status" (Succeeded 等) と command envelope の "Status" (OK/Error) が
     衝突しないよう、handler 結果は "Web" 配下にネストする。 *)
  "WebSearchSubmit",
    Module[{r = Quiet @ Check[
        SourceVault`SourceVaultWebSearchSubmit[
          KeyDrop[cmd, {"Command", "CommandId", "CreatedAtUTC"}]], $Failed]},
      If[AssociationQ[r], <|"Status" -> "OK", "Web" -> r|>,
        <|"Status" -> "Error", "Reason" -> "WebSearchSubmitFailed", "Detail" -> ToString[r]|>]],
  "WebJobStatus",
    Module[{jid = Lookup[cmd, "JobId"]},
      If[! StringQ[jid], <|"Status" -> "Error", "Reason" -> "JobIdRequired"|>,
        <|"Status" -> "OK", "Web" -> SourceVault`SourceVaultWebJobStatus[jid]|>]],
  "WebJobResult",
    Module[{jid = Lookup[cmd, "JobId"]},
      If[! StringQ[jid], <|"Status" -> "Error", "Reason" -> "JobIdRequired"|>,
        <|"Status" -> "OK", "Web" -> SourceVault`SourceVaultWebJobResult[jid]|>]],
  "AddReferenceEvent",
    Module[{r = Quiet @ Check[
        SourceVault`SourceVaultAddReferenceEvent[
          KeyDrop[cmd, {"Command", "CommandId", "CreatedAtUTC"}]], $Failed]},
      If[AssociationQ[r], <|"Status" -> "OK", "Web" -> r|>,
        <|"Status" -> "Error", "Reason" -> "AddReferenceEventFailed", "Detail" -> ToString[r]|>]],
  (* ---- MCP JSON-RPC dispatch (spec v6 §13) ----
     proxy が HTTP POST /mcp で受けた JSON-RPC {method, params} をこの command で渡す。
     result は "MCP" 配下 (Failure は "MCPError" 配下、proxy が JSON-RPC error に変換)。 *)
  "MCP",
    Module[{method = Lookup[cmd, "Method"], params = Lookup[cmd, "Params", <||>], r},
      If[! StringQ[method], <|"Status" -> "Error", "Reason" -> "MethodRequired"|>,
        r = Quiet @ Check[SourceVault`SourceVaultMCPDispatch[method,
              If[AssociationQ[params], params, <||>]], $Failed];
        If[FailureQ[r] || r === $Failed,
          <|"Status" -> "OK", "MCPError" -> <|"code" -> -32601,
            "message" -> If[FailureQ[r], ToString[r[[1]]], "InternalError"]|>|>,
          <|"Status" -> "OK", "MCP" -> r|>]]],
  _, <|"Status" -> "UnknownCommand", "Command" -> Lookup[cmd, "Command", Missing[]]|>];

(* pending command を処理。done/ へ結果付きで移し、Stop 要求の有無を返す。
   WLMCP command だけは deferred: サブカーネルへ submit して done を書かずに
   戻る (iSMWLMCPPoll が完了時に done を書く)。 *)
iProcessServiceCommands[dir_String] := Module[{cmdDir, doneDir, files, stop = False},
  cmdDir = FileNameJoin[{dir, "commands"}];
  doneDir = FileNameJoin[{dir, "commands", "done"}];
  iSMEnsureDir[doneDir];
  files = If[DirectoryQ[cmdDir], FileNames["*.json", cmdDir], {}];  (* done/ は再帰しないので含まない *)
  Do[Module[{cmd = iSMReadJSON[f], result},
      If[AssociationQ[cmd],
        If[Lookup[cmd, "Command"] === "WLMCP",
          iSMWLMCPAccept[dir, FileNameTake[f], cmd];
          iServiceLog[dir, "CommandDeferred",
            <|"Command" -> "WLMCP", "CommandId" -> Lookup[cmd, "CommandId"]|>],
          result = iDispatchServiceCommand[cmd];
          If[TrueQ[Lookup[result, "Stop"]], stop = True];
          iSMWriteJSON[FileNameJoin[{doneDir, FileNameTake[f]}],
            Join[cmd, <|"Result" -> result, "ProcessedAtUTC" -> iSMUTCNow[]|>]];
          iServiceLog[dir, "CommandProcessed", <|"Command" -> Lookup[cmd, "Command"], "CommandId" -> Lookup[cmd, "CommandId"]|>]]];
      Quiet @ DeleteFile[f]],
    {f, files}];
  stop];

Options[SourceVaultServiceMain] = {"HeartbeatIntervalSeconds" -> 1, "MaxSeconds" -> Automatic};
SourceVaultServiceMain[kind_String, serviceId_String, OptionsPattern[]] := Module[
  {dir, interval, maxSec, counter = 0, stop = False, startAbs, statusPath, hbPath,
   lastRollupAbs, lastCCIngestAbs, lastDiagIngestAbs,
   lastDispatchAbs = 0, dispatchCounter = 0, dispatchState = None},
  dir = iServiceRuntimeDir[serviceId];
  If[FailureQ[dir], Return[dir]];
  iSMEnsureDir[dir];
  (* spec v6 §7.4: 起動時に stale な Running/Queued job を Failed に掃く (webingest があれば) *)
  If[Length[DownValues[SourceVault`SourceVaultWebRecoverStaleJobs]] > 0,
    Quiet @ Check[SourceVault`SourceVaultWebRecoverStaleJobs[], Null]];
  (* #2: 起動時に参照イベント hot ログを CoreRoot(Dropbox) へ rollup (webingest があれば) *)
  If[Length[DownValues[SourceVault`SourceVaultRollupReferenceEvents]] > 0,
    Quiet @ Check[SourceVault`SourceVaultRollupReferenceEvents[], Null]];
  (* llmlog: 起動時に Claude Code セッションログのダイジェストを CoreRoot へ ingest
     (llmlog があれば)。初回バックログは MaxSessionsPerRun で刻み、tick 毎に消化する。 *)
  If[Length[DownValues[SourceVault`SourceVaultIngestClaudeCodeLogs]] > 0,
    Quiet @ TimeConstrained[
      Check[SourceVault`SourceVaultIngestClaudeCodeLogs["MaxSessionsPerRun" -> 40], Null], 120, Null]];
  (* WLMCP: AgentTools MCP 用サブカーネルを起動時に温める (初回リクエストを
     待たせない)。失敗しても fail-soft (Ready=False で明示エラー応答)。 *)
  If[iSMWLMCPEnabledQ[serviceId],
    Quiet @ TimeConstrained[Check[iSMWLMCPEnsure[dir], Null], 300, Null]];
  (* headless dispatch (配車専用モード): opt-in マシンでは実行 stack
     (workflowregistry + ClaudeOrchestrator workflow engine) を起動時に温める。
     ループ内での初回長時間 Get は heartbeat を止め watchdog の誤再起動を招く
     ので、WLMCP warm と同じ「ループ前の安全地帯」で行う。fail-soft。 *)
  If[Length[DownValues[SourceVault`SourceVaultAutoTriggerHeadlessDispatchTick]] > 0 &&
     TrueQ[Quiet @ Check[SourceVault`SourceVaultHeadlessDispatchEnabledQ[], False]],
    Module[{stackR},
      stackR = Quiet @ TimeConstrained[
        Check[SourceVault`Private`iSVATEnsureHeadlessExecStack[], $Failed],
        300, $Failed];
      iServiceLog[dir, "HeadlessDispatchStackPreload",
        <|"Result" -> If[AssociationQ[stackR],
            Lookup[stackR, "Status", "?"], ToString[stackR]]|>]]];
  lastRollupAbs = AbsoluteTime[];
  lastCCIngestAbs = AbsoluteTime[];
  lastDiagIngestAbs = 0;   (* hardening 05 Inc2: 初回 tick で即 ingest *)
  interval = OptionValue["HeartbeatIntervalSeconds"];
  maxSec = OptionValue["MaxSeconds"];  (* 安全弁: Automatic なら無制限 *)
  statusPath = FileNameJoin[{dir, "status.json"}];
  hbPath = FileNameJoin[{dir, "heartbeat.json"}];
  startAbs = AbsoluteTime[];
  (* runner が自身の PID を pid.json に self-report (detached 起動のため launcher は PID を知らない) *)
  iSMWriteJSON[FileNameJoin[{dir, "pid.json"}],
    <|"PID" -> $ProcessID, "Host" -> $MachineName, "Executable" -> "WolframKernel",
      "User" -> $UserName,
      "InjectedRootHash" -> With[{h = SourceVault`$SourceVaultInjectedRootHash}, If[StringQ[h], h, Null]],
      "LaunchedAtUTC" -> iSMUTCNow[]|>];
  iSMWriteJSON[statusPath, <|"ServiceId" -> serviceId, "Kind" -> kind,
    "State" -> "Running", "PID" -> $ProcessID, "Host" -> $MachineName,
    "StartedAtUTC" -> iSMUTCNow[]|>];
  iServiceLog[dir, "ServiceStarted", <|"Kind" -> kind, "PID" -> $ProcessID|>];
  CheckAbort[
    While[! stop,
      counter++;
      (* liveness: 配車専用モードの tick 記録を heartbeat に同乗させる (要件:
         「配車が死んだ」を health で検知可能に)。Dispatch.LastTickAtUTC の
         鮮度を SourceVaultServiceStatus が判定する。 *)
      iSMWriteJSON[hbPath, Join[
        <|"Counter" -> counter, "UpdatedAtUTC" -> iSMUTCNow[], "PID" -> $ProcessID|>,
        If[AssociationQ[dispatchState], <|"Dispatch" -> dispatchState|>, <||>]]];
      stop = iProcessServiceCommands[dir];
      If[stop, Break[]];
      (* WLMCP: サブカーネルの完了結果を回収して done を書く。pending がある間は
         0.8s まで短周期で追いポーリング (速い評価を同一 tick で返す)。 *)
      Quiet @ Check[iSMWLMCPPoll[dir, 0.8], Null];
      (* #2: 低頻度で参照イベントを CoreRoot に rollup (per-event 同期を避ける; バッテリーノート配慮)。
         反映には service 再起動が必要 (rule105 §8)。 *)
      If[Length[DownValues[SourceVault`SourceVaultRollupReferenceEvents]] > 0 &&
         NumericQ[SourceVault`$SourceVaultRollupIntervalSeconds] &&
         (AbsoluteTime[] - lastRollupAbs) > SourceVault`$SourceVaultRollupIntervalSeconds,
        (* #3: rollup をループ内で無制限ブロックさせない。Dropbox I/O ハング等は
           TimeConstrained で打ち切り (Abort)、サービスループは次反復へ進める。 *)
        Quiet @ TimeConstrained[
          Check[SourceVault`SourceVaultRollupReferenceEvents[], Null], 30, Null];
        lastRollupAbs = AbsoluteTime[]];
      (* llmlog: 低頻度で Claude Code セッションログを増分 ingest (watermark 冪等・
         変更セッションのみ digest)。rollup と同じく TimeConstrained で打ち切る。 *)
      If[Length[DownValues[SourceVault`SourceVaultIngestClaudeCodeLogs]] > 0 &&
         NumericQ[SourceVault`$SourceVaultClaudeCodeIngestIntervalSeconds] &&
         (AbsoluteTime[] - lastCCIngestAbs) > SourceVault`$SourceVaultClaudeCodeIngestIntervalSeconds,
        Quiet @ TimeConstrained[
          Check[SourceVault`SourceVaultIngestClaudeCodeLogs["MaxSessionsPerRun" -> 40], Null],
          120, Null];
        lastCCIngestAbs = AbsoluteTime[]];
      (* hardening 05 Inc2: producer per-process spool の診断イベントを
         正準 diagnostics-log へ ingest (単一書き手=この service kernel。
         EventId dedup で冪等)。rollup と同じく TimeConstrained で打ち切る。 *)
      If[Length[DownValues[SourceVault`SourceVaultDiagnosticsIngestSpool]] > 0 &&
         (AbsoluteTime[] - lastDiagIngestAbs) >
           If[NumericQ[SourceVault`$SourceVaultDiagIngestIntervalSeconds],
             SourceVault`$SourceVaultDiagIngestIntervalSeconds, 60],
        Quiet @ TimeConstrained[
          Check[SourceVault`SourceVaultDiagnosticsIngestSpool[], Null], 30, Null];
        lastDiagIngestAbs = AbsoluteTime[]];
      (* headless dispatch (配車専用): opt-in マシンでのみ、enqueue された
         CatalogWorkflow ジョブを拾い SourceVaultRunWorkflowAsync (外部プロセス)
         へ委譲する。サブカーネルプールなし・トリガー評価なし。opt-in 判定は
         tick 側 (SourceVaultHeadlessDispatchEnabledQ) が毎回行うので、共有 vault
         のフラグ変更が再起動なしで効く (無効時 tick は即 "Disabled" を返す)。
         TimeConstrained 120s: 通常は数秒 (jsonl 読取+StartProcess)。実行 stack
         未ロード時の初回 Get だけ長いが、それは起動時 preload 済みが正常経路。 *)
      If[Length[DownValues[SourceVault`SourceVaultAutoTriggerHeadlessDispatchTick]] > 0 &&
         (AbsoluteTime[] - lastDispatchAbs) >
           If[NumericQ[SourceVault`$SourceVaultHeadlessDispatchIntervalSeconds],
             SourceVault`$SourceVaultHeadlessDispatchIntervalSeconds, 60],
        Module[{tickR},
          tickR = Quiet @ TimeConstrained[
            Check[SourceVault`SourceVaultAutoTriggerHeadlessDispatchTick[],
              <|"Status" -> "Error"|>],
            120, <|"Status" -> "TimedOut"|>];
          lastDispatchAbs = AbsoluteTime[];
          If[AssociationQ[tickR] && Lookup[tickR, "Status", ""] =!= "Disabled",
            dispatchCounter++;
            dispatchState = <|
              "Enabled" -> True,
              "LastTickAtUTC" -> iSMUTCNow[],
              "Counter" -> dispatchCounter,
              "IntervalSeconds" ->
                If[NumericQ[SourceVault`$SourceVaultHeadlessDispatchIntervalSeconds],
                  SourceVault`$SourceVaultHeadlessDispatchIntervalSeconds, 60],
              "LastStatus" -> Lookup[tickR, "Status", "?"],
              "EligibleJobs" -> Lookup[tickR, "EligibleJobs", 0]|>;
            If[MemberQ[{"Error", "TimedOut", "ExecStackUnavailable"},
                Lookup[tickR, "Status", ""]] ||
               Lookup[tickR, "EligibleJobs", 0] > 0,
              iServiceLog[dir, "HeadlessDispatchTick",
                <|"Result" -> Quiet @ Check[
                    ToString[KeyTake[tickR,
                      {"Status", "EligibleJobs", "ExecStack", "Dispatch"}],
                      InputForm], "?"]|>]],
            (* opt-in が外れた: heartbeat から Dispatch を落とす (stall 誤検知防止) *)
            dispatchState = None]]];
      If[NumericQ[maxSec] && (AbsoluteTime[] - startAbs) > maxSec, stop = True; Break[]];
      Pause[interval]],
    stop = True];
  iSMWriteJSON[statusPath, <|"ServiceId" -> serviceId, "Kind" -> kind,
    "State" -> "Stopped", "PID" -> $ProcessID, "StoppedAtUTC" -> iSMUTCNow[],
    "HeartbeatCounter" -> counter|>];
  iServiceLog[dir, "ServiceStopped", <|"HeartbeatCounter" -> counter|>];
  <|"Status" -> "Stopped", "ServiceId" -> serviceId, "HeartbeatCounter" -> counter|>];

(* ============================================================
   管理 API (親 = メインカーネル側)
   ============================================================ *)

iGenRunWls[dir_String, kind_String, serviceId_String, root_String, pkgRoot_String,
   interval_, prelude_String] :=
  Module[{q, path, rootsAssoc, rootHash},
    q[s_] := ToString[s, InputForm];  (* Windows path も含め正しく escape *)
    path = FileNameJoin[{dir, "run.wls"}];
    (* spec v6 §3.7: main kernel の current roots を service kernel へ注入する snapshot。
       core 側の薄いアクセサ (SourceVaultRootAssociation) が注入値を最優先する。 *)
    rootsAssoc = SourceVault`$SourceVaultRoots;
    If[! AssociationQ[rootsAssoc], rootsAssoc = <||>];
    rootHash = Quiet @ Check[SourceVault`SourceVaultRootConfigHash[], ""];
    iSMWriteJSON[FileNameJoin[{dir, "manifest.resolved.wl"}],
      <|"ServiceId" -> serviceId, "Kind" -> kind, "PackageRoot" -> pkgRoot,
        "CoreRoot" -> root, "HeartbeatIntervalSeconds" -> interval,
        "Packages" -> {"SourceVault_core.wl", "SourceVault_crypto.wl", "SourceVault_searchindex.wl",
          "SourceVault_servicemanager.wl", "SourceVault_webingest.wl",
          "SourceVault_contracts.wl", "SourceVault_packageapi.wl", "SourceVault_mcp.wl",
          "SourceVault_llmlog.wl", "SourceVault_autotrigger.wl"},
        "InjectedRootHash" -> rootHash,
        "HasPrelude" -> (StringLength[prelude] > 0), "CreatedAtUTC" -> iSMUTCNow[]|>];
    Module[{strm = OpenWrite[path, BinaryFormat -> True], text},
      text = StringJoin[
        "Block[{$CharacterEncoding = \"UTF-8\"},\n",
        "  Get[FileNameJoin[{", q[pkgRoot], ", \"SourceVault_core.wl\"}]];\n",
        (* crypto は grant 検証 (sourcevault_get / D3 本文解放) に必要。core 後・他より前に
           load。存在ガードで fail-soft (欠落時 grant 検証は CryptoUnavailable で安全側)。 *)
        "  With[{cpath = FileNameJoin[{", q[pkgRoot], ", \"SourceVault_crypto.wl\"}]}, If[FileExistsQ[cpath], Get[cpath]]];\n",
        "  Get[FileNameJoin[{", q[pkgRoot], ", \"SourceVault_searchindex.wl\"}]];\n",
        "  Get[FileNameJoin[{", q[pkgRoot], ", \"SourceVault_servicemanager.wl\"}]];\n",
        (* webingest / mcp は存在する場合のみ load (spec v6 §4.6)。未作成段階でも安全。 *)
        "  With[{wpath = FileNameJoin[{", q[pkgRoot], ", \"SourceVault_webingest.wl\"}]}, If[FileExistsQ[wpath], Get[wpath]]];\n",
        (* packageapi (+依存 contracts) を mcp より前に load して、detached service
           kernel 単独でも packageapi adapter を available にする。存在ガードで
           fail-soft (packageapi は core のみ必須、contracts は alias 解決用で任意)。 *)
        "  With[{kpath = FileNameJoin[{", q[pkgRoot], ", \"SourceVault_contracts.wl\"}]}, If[FileExistsQ[kpath], Get[kpath]]];\n",
        "  With[{apath = FileNameJoin[{", q[pkgRoot], ", \"SourceVault_packageapi.wl\"}]}, If[FileExistsQ[apath], Get[apath]]];\n",
        "  With[{mpath = FileNameJoin[{", q[pkgRoot], ", \"SourceVault_mcp.wl\"}]}, If[FileExistsQ[mpath], Get[mpath]]];\n",
        (* llmlog は mcp より後に load (adapter 登録が mcp の registry を要するため)。
           存在ガードで fail-soft。 *)
        "  With[{lpath = FileNameJoin[{", q[pkgRoot], ", \"SourceVault_llmlog.wl\"}]}, If[FileExistsQ[lpath], Get[lpath]]];\n",
        (* autotrigger: headless dispatch mode (配車専用) の tick 本体。ロード自体は
           side-effect free (レジストリ基盤のみ; scheduler auto-start は SourceVault.wl
           の FE ガード側にあり service kernel では走らない)。存在ガードで fail-soft。
           実行 stack (workflowregistry/engine) は opt-in マシンでのみ遅延ロードされる。 *)
        "  With[{tpath = FileNameJoin[{", q[pkgRoot], ", \"SourceVault_autotrigger.wl\"}]}, If[FileExistsQ[tpath], Get[tpath]]];\n",
        "];\n",
        "SourceVault`$SourceVaultCoreRoot = ", q[root], ";\n",
        (* root snapshot 注入 (spec v6 §3.7): service kernel は注入値を最優先する。
           main kernel の current roots を start-time snapshot として焼き込む。 *)
        "SourceVault`$SourceVaultInjectedRoots = ", q[rootsAssoc], ";\n",
        "SourceVault`$SourceVaultInjectedRootHash = ", q[rootHash], ";\n",
        (* service kernel 用の任意 prelude (backend / config 設定など) *)
        If[StringLength[prelude] > 0, prelude <> "\n", ""],
        "SourceVault`SourceVaultServiceMain[", q[kind], ", ", q[serviceId],
          ", \"HeartbeatIntervalSeconds\" -> ", ToString[interval], "];\n"];
      BinaryWrite[strm, StringToByteArray[text, "UTF-8"]]; Close[strm]];
    path];

(* #1: stdout.log を再起動で truncate せず世代退避 (.1..keep) する。
   launch 前に呼ぶことで、前回 (wedge を含む) 実行の stdout を保全し post-mortem を可能にする。 *)
iRotateLog[logPath_String] := iRotateLog[logPath, 5];
iRotateLog[logPath_String, keep_Integer] := (
  If[FileExistsQ[logPath],
    Do[
      With[{src = If[i == 0, logPath, logPath <> "." <> ToString[i]],
            dst = logPath <> "." <> ToString[i + 1]},
        If[FileExistsQ[src],
          Quiet @ Check[If[FileExistsQ[dst], DeleteFile[dst]]; RenameFile[src, dst], Null]]],
      {i, keep - 1, 0, -1}]];
  Null);

(* 起動用 .bat を生成。Task Scheduler が detachment 境界になるので start は不要。
   stdout/stderr は runtime dir のログへ redirect。path の空白は二重引用符で囲う。
   #1: 既存 stdout.log は launch 前に世代退避し、前回実行のログを残す。 *)
iGenLaunchBat[dir_String, exe_String, runWls_String] := Module[{path, text, q, strm},
  q[s_] := "\"" <> s <> "\"";
  iRotateLog[FileNameJoin[{dir, "stdout.log"}]];
  path = FileNameJoin[{dir, "launch.bat"}];
  text = "@echo off\r\n" <> q[exe] <> " -file " <> q[runWls] <>
    " > " <> q[FileNameJoin[{dir, "stdout.log"}]] <> " 2>&1\r\n";
  strm = OpenWrite[path, BinaryFormat -> True];
  BinaryWrite[strm, StringToByteArray[text, "UTF-8"]]; Close[strm];
  path];

(* task/file 安全名 (core の iSafeLockName は CorePrivate 文脈なのでローカルに定義)。
   task 名・ファイル名に使えない : \ / * ? < > | 空白 を _ にする。 *)
iSafeName[s_String] := StringReplace[s,
  {":" -> "__", FromCharacterCode[92] -> "_", "/" -> "_", "*" -> "_",
   "?" -> "_", "<" -> "_", ">" -> "_", "|" -> "_", " " -> "_"}];

(* service 用 scheduled task 名 (serviceId を file/task 安全名に) *)
iServiceTaskName[serviceId_String] := "SourceVaultSvc_" <> iSafeName[serviceId];

Options[SourceVaultStartService] = {
  "Kind" -> "heartbeat", "HeartbeatIntervalSeconds" -> 1, "PackageRoot" -> Automatic,
  "PreludeCode" -> ""};
SourceVaultStartService[serviceId_String, OptionsPattern[]] := Module[
  {dir, root, pkgRoot, kind, interval, runWls, exe, batPath, task, runRes, pid,
   existing, pidPath, deadline, pidRec, prelude, seat, seatTok},
  root = SourceVault`SourceVaultCoreRoot[];
  If[FailureQ[root], Return[root]];
  kind = OptionValue["Kind"];
  interval = OptionValue["HeartbeatIntervalSeconds"];
  prelude = OptionValue["PreludeCode"];
  pkgRoot = OptionValue["PackageRoot"] /. Automatic -> iPackageRoot[];
  dir = iServiceRuntimeDir[serviceId];
  iSMEnsureDir[dir]; iSMEnsureDir[FileNameJoin[{dir, "commands", "done"}]];
  (* 既に Running なら二重起動しない *)
  existing = SourceVaultServiceStatus[serviceId];
  If[AssociationQ[existing] && Lookup[existing, "State"] === "Running" &&
      TrueQ[Lookup[existing, "PidAlive"]],
    Return[<|"Status" -> "AlreadyRunning", "ServiceId" -> serviceId,
      "PID" -> Lookup[existing, "PID"], "RuntimeDir" -> dir|>]];
  (* 前インスタンスが残っていれば kill する (orphan service 累積防止)。
     pid.json を上書きする前に旧 pid を始末しないと、同じ commands/ を読む
     ゾンビが溜まって競合し、コマンドが done を書かれず Pending 化する。 *)
  Module[{oldRec = iSMReadJSON[FileNameJoin[{dir, "pid.json"}]], oldPid},
    oldPid = If[AssociationQ[oldRec], Lookup[oldRec, "PID"], Missing[]];
    If[IntegerQ[oldPid] && iPidAlive[oldPid] && iPidIsWolframProcess[oldPid],
      iKillPid[oldPid]]];
  (* 起動前に未処理コマンドを掃除する。特に前回 StopService が残した stale "Stop" を
     新 service が起動直後に拾って即停止する事故を防ぐ (heartbeat 1 で Stopped になる)。 *)
  Quiet[DeleteFile /@ FileNames["*.json", FileNameJoin[{dir, "commands"}]]];
  runWls = iGenRunWls[dir, kind, serviceId, root, pkgRoot, interval, prelude];
  exe = iResolveWolframScript[];
  batPath = iGenLaunchBat[dir, exe, runWls];
  task = iServiceTaskName[serviceId];
  iSMWriteJSON[FileNameJoin[{dir, "status.json"}],
    <|"ServiceId" -> serviceId, "Kind" -> kind, "State" -> "Starting",
      "StartedAtUTC" -> iSMUTCNow[]|>];
  (* detached 起動 (§14.3: メイン kernel 終了後も生存)。
     WL の StartProcess 子は kernel の job object (kill-on-close) で道連れに kill
     されるため、Windows Task Scheduler を detachment 境界として使う。
     PID は runner が自身の $ProcessID を pid.json に self-report する。
     【窓非表示】bat を直接 /TR にすると Task Scheduler が対話セッションで
     wolframscript のコンソール窓を表示し続ける。wscript の hidden launcher
     (cmd /c bat を vbHide で起動) 経由にして窓を出さない (stdout リダイレクトは bat 側で維持)。 *)
  (* hardening 01 Inc2: 席ゲート (SeatBroker ロード済み環境のみ)。
     service は常駐だが seat は boot 窓 (pid.json 出現まで) のみ保持し、
     起動確認後に返却する — 以後は license 実測側に本体が現れる。
     枯渇時は黙って Queued/即死させず Failure で可視化する (spec 01 §6)。 *)
  seat = If[Length[DownValues[ClaudeRuntime`ClaudeSeatAcquire]] > 0,
    ClaudeRuntime`ClaudeSeatAcquire["SourceVaultService", "Priority" -> 60,
      "TTLSeconds" -> 180, "JobId" -> serviceId],
    <|"Token" -> None|>];
  If[FailureQ[seat],
    Return[Failure["NoSeat", <|"ServiceId" -> serviceId, "Deferred" -> True,
      "Detail" -> "ライセンス席が不足しています。SourceVaultSystemDoctor[] で回収候補 (放置 wolframscript / 重複 MCP) を確認してください。"|>]]];
  seatTok = Lookup[seat, "Token", None];
  Quiet @ RunProcess[{"schtasks", "/Create", "/TN", task, "/TR", iWriteHiddenLauncher[dir, batPath]["TR"],
    "/SC", "ONCE", "/ST", "23:59", "/F"}];
  iClearTaskBatteryRestriction[task];  (* バッテリー運用でも起動できるよう電源条件を解除 *)
  runRes = Quiet @ RunProcess[{"schtasks", "/Run", "/TN", task}];
  If[! (AssociationQ[runRes] && Lookup[runRes, "ExitCode"] === 0),
    If[StringQ[seatTok], Quiet @ ClaudeRuntime`ClaudeSeatRelease[seatTok]];
    iSMWriteJSON[FileNameJoin[{dir, "status.json"}],
      <|"State" -> "Crashed", "Reason" -> "ScheduledTaskRunFailed"|>];
    Return[Failure["ScheduledTaskRunFailed", <|"ServiceId" -> serviceId, "Task" -> task,
      "Detail" -> If[AssociationQ[runRes], Lookup[runRes, "StandardError"], runRes]|>]]];
  (* runner が pid.json を書くのを待つ。scheduler 下の kernel boot は遅い (~10-20s)。 *)
  pidPath = FileNameJoin[{dir, "pid.json"}];
  deadline = AbsoluteTime[] + 60;
  While[AbsoluteTime[] < deadline && ! FileExistsQ[pidPath], Pause[0.5]];
  pidRec = iSMReadJSON[pidPath];
  pid = If[AssociationQ[pidRec], Lookup[pidRec, "PID"], Missing["Pending"]];
  (* boot 窓終了 → 席返却 (成否問わず。以後は実測が本体を数える) *)
  If[StringQ[seatTok], Quiet @ ClaudeRuntime`ClaudeSeatRelease[seatTok]];
  iServiceLog[dir, "ServiceLaunched", <|"PID" -> pid, "Kind" -> kind, "Task" -> task|>];
  <|"Status" -> "Started", "ServiceId" -> serviceId, "PID" -> pid,
    "RuntimeDir" -> dir, "Task" -> task|>];

iHeartbeatAgeSeconds[dir_String] := Module[{hb = iSMReadJSON[FileNameJoin[{dir, "heartbeat.json"}]], t},
  If[! AssociationQ[hb], Return[Missing["NoHeartbeat"]]];
  t = Quiet @ DateObject[Lookup[hb, "UpdatedAtUTC", ""], TimeZone -> 0];
  If[Head[t] =!= DateObject, Return[Missing["BadTimestamp"]]];
  QuantityMagnitude[DateDifference[t, Now, "Second"]]];

SourceVaultServiceStatus[serviceId_String, opts___] := Module[
  {dir, status, hb, pidRec, pid, alive, age, health,
   dispatch, dispatchAge, dispatchStalled = False},
  dir = iServiceRuntimeDir[serviceId];
  If[FailureQ[dir], Return[dir]];
  If[! DirectoryQ[dir], Return[<|"ServiceId" -> serviceId, "State" -> "Unknown", "Exists" -> False|>]];
  status = iSMReadJSON[FileNameJoin[{dir, "status.json"}]];
  hb = iSMReadJSON[FileNameJoin[{dir, "heartbeat.json"}]];
  pidRec = iSMReadJSON[FileNameJoin[{dir, "pid.json"}]];
  pid = If[AssociationQ[pidRec], Lookup[pidRec, "PID"], Missing[]];
  alive = If[IntegerQ[pid], iPidAlive[pid], False];
  age = iHeartbeatAgeSeconds[dir];
  (* hardening 02 Inc1: 閾値を $SourceVaultHealthThresholds に統一
     (旧 5/15s は Python proxy の 15/60s と食い違っていた)。
     age が読めない (Missing = heartbeat 欠損/壊れ) は従来どおり Failing
     (『読めない=健康』にしない)。 *)
  health = Which[
    ! TrueQ[alive], "Failing",
    NumericQ[age] && age <= iSMHealthThreshold["OKSeconds", 15], "OK",
    NumericQ[age] && age <= iSMHealthThreshold["DegradedSeconds", 60], "Degraded",
    True, "Failing"];
  (* headless dispatch liveness: heartbeat が進んでいても配車 tick が止まって
     いれば (LastTickAtUTC が interval x3+30s より古い / 直近 tick が Error 系)
     「緑のまま配車死亡」なので Degraded に落とす。Dispatch field が無い =
     配車無効サービスは従来どおり (影響なし)。 *)
  dispatch = If[AssociationQ[hb], Lookup[hb, "Dispatch", Missing[]], Missing[]];
  dispatchAge = If[AssociationQ[dispatch],
    Module[{t = Quiet @ DateObject[Lookup[dispatch, "LastTickAtUTC", ""], TimeZone -> 0]},
      If[Head[t] =!= DateObject, Missing["BadTimestamp"],
        QuantityMagnitude[DateDifference[t, Now, "Second"]]]],
    Missing[]];
  If[AssociationQ[dispatch] && TrueQ[Lookup[dispatch, "Enabled", False]],
    Module[{iv = Lookup[dispatch, "IntervalSeconds", 60]},
      If[! NumericQ[iv], iv = 60];
      dispatchStalled =
        ! NumericQ[dispatchAge] || dispatchAge > 3 iv + 30 ||
          MemberQ[{"Error", "TimedOut", "ExecStackUnavailable"},
            Lookup[dispatch, "LastStatus", ""]];
      If[dispatchStalled && health === "OK", health = "Degraded"]]];
  <|"ServiceId" -> serviceId,
    "State" -> If[AssociationQ[status], Lookup[status, "State", "Unknown"], "Unknown"],
    "PID" -> pid, "PidAlive" -> alive,
    "HeartbeatCounter" -> If[AssociationQ[hb], Lookup[hb, "Counter"], Missing[]],
    "HeartbeatAgeSeconds" -> age, "Health" -> health,
    "Dispatch" -> dispatch, "DispatchTickAgeSeconds" -> dispatchAge,
    "DispatchStalled" -> dispatchStalled,
    "RuntimeDir" -> dir, "Exists" -> True|>];

(* hardening 02 Inc3 (2026-07-08): L2 (command queue 応答) を health に統合。
   heartbeat counter の進行は「メインループ生存」しか証明しない (L3)。
   Ping が done/ に落ちてくること = 公開処理系そのものの生存証明 (L2)。
   ping はキャッシュ (PingIntervalSeconds) 経由で、health 連打でも
   queue を 1 分に 1 回しか叩かない。 *)
If[! ValueQ[$SourceVaultHealthRequireL2], $SourceVaultHealthRequireL2 = False];
If[! AssociationQ[$iSMPingCache], $iSMPingCache = <||>];

iSMPingCached[serviceId_String] := Module[
  {now = AbsoluteTime[], c, interval, timeout, r, t0},
  interval = iSMHealthThreshold["PingIntervalSeconds", 60];
  timeout = iSMHealthThreshold["PingTimeoutSeconds", 10];
  c = Lookup[$iSMPingCache, serviceId, Missing[]];
  If[AssociationQ[c] && now - Lookup[c, "t", 0] < interval,
    Return[c["r"], Module]];
  t0 = AbsoluteTime[];
  r = Quiet @ Check[
    SourceVaultServicePing[serviceId, "TimeoutSeconds" -> timeout], $Failed];
  r = If[AssociationQ[r] && TrueQ[Lookup[r, "Pong"]],
    <|"L2" -> True, "RTTms" -> Round[1000 (AbsoluteTime[] - t0)]|>,
    <|"L2" -> False,
      "Detail" -> If[FailureQ[r], First[r, "?"], "NoPong"]|>];
  $iSMPingCache[serviceId] = <|"t" -> now, "r" -> r|>;
  r];

SourceVaultServiceHealthDetail[serviceId_String] := Module[
  {st, base, ping},
  st = SourceVaultServiceStatus[serviceId];
  base = Lookup[st, "Health", "Unknown"];
  (* L1/L3 の時点で非 OK なら queue はカーネルごと死んでいる: ping 不要 *)
  If[base =!= "OK",
    Return[<|"Health" -> base, "Layer" -> "L1", "Base" -> base|>]];
  ping = iSMPingCached[serviceId];
  Which[
    TrueQ[ping["L2"]],
      <|"Health" -> "OK", "Layer" -> "L2", "Ping" -> ping, "Base" -> base|>,
    TrueQ[$SourceVaultHealthRequireL2],
      (* heartbeat は進むのに queue 不応答 = busy (長時間ジョブ) か wedge *)
      <|"Health" -> "Degraded", "Layer" -> "L3", "Ping" -> ping,
        "Base" -> base, "Note" -> "QueueUnresponsive"|>,
    True,
      (* 移行期: L3 OK を許すが Layer で識別可能にする *)
      <|"Health" -> "OK", "Layer" -> "L3", "Ping" -> ping, "Base" -> base|>]];

SourceVaultServiceHealth[serviceId_String, opts___] :=
  Lookup[SourceVaultServiceHealthDetail[serviceId], "Health", "Unknown"];

(* spec v6 §3.6/§3.10: service kernel の root/ユーザが main kernel と整合しているか検証する。
   - RootHashMismatch: service の injected root hash ≠ main の現在 hash → root 変更後に未再起動。
   - UserMismatch: service 実行ユーザ ≠ main → %LOCALAPPDATA%/書込み権限が分裂する恐れ。 *)
iLocalStateWritableQ[ls_] := If[! StringQ[ls], False,
  Module[{t, s},
    Quiet[iSMEnsureDir[ls]];
    t = FileNameJoin[{ls, ".sv-health-probe-" <> ToString[$ProcessID]}];
    TrueQ @ Quiet @ Check[
      s = OpenWrite[t, BinaryFormat -> True]; BinaryWrite[s, StringToByteArray["x", "UTF-8"]];
      Close[s]; DeleteFile[t]; True, $Failed]]];

SourceVaultServiceRootHealth[serviceId_String, opts___] := Module[
  {dir, pid, manifest, svcHash, svcUser, mainHash, mainUser, mainLS, coreRoot, lsWritable, warnings = {}, hashMatch, userMatch},
  dir = iServiceRuntimeDir[serviceId];
  If[FailureQ[dir] || ! DirectoryQ[dir],
    Return[<|"ServiceId" -> serviceId, "Exists" -> False|>]];
  pid = iSMReadJSON[FileNameJoin[{dir, "pid.json"}]];
  manifest = iSMReadJSON[FileNameJoin[{dir, "manifest.resolved.wl"}]];
  svcUser = If[AssociationQ[pid], Lookup[pid, "User", Missing[]], Missing[]];
  svcHash = Which[
    AssociationQ[pid] && StringQ[Lookup[pid, "InjectedRootHash", Null]], pid["InjectedRootHash"],
    AssociationQ[manifest] && StringQ[Lookup[manifest, "InjectedRootHash", Null]], manifest["InjectedRootHash"],
    True, Missing[]];
  mainHash = Quiet @ Check[SourceVault`SourceVaultRootConfigHash[], Missing[]];
  mainUser = $UserName;
  mainLS = Quiet @ Check[SourceVault`SourceVaultRoot["LocalState"], Missing[]];
  coreRoot = Quiet @ Check[SourceVault`SourceVaultCoreRoot[], Missing[]];
  lsWritable = iLocalStateWritableQ[mainLS];
  hashMatch = StringQ[svcHash] && StringQ[mainHash] && svcHash === mainHash;
  userMatch = ! StringQ[svcUser] || svcUser === mainUser;
  If[StringQ[svcHash] && StringQ[mainHash] && ! hashMatch,
    AppendTo[warnings,
      "RootHashMismatch: service の root が main の現在値と異なる。SourceVaultRestartService で再注入してください。"]];
  If[StringQ[svcUser] && svcUser =!= mainUser,
    AppendTo[warnings,
      "UserMismatch: service 実行ユーザ (" <> svcUser <> ") が main (" <> mainUser <>
      ") と異なる。%LOCALAPPDATA% / 書込み権限が分裂する恐れ。"]];
  If[StringQ[mainLS] && ! lsWritable,
    AppendTo[warnings, "LocalStateNotWritable: " <> mainLS]];
  <|"ServiceId" -> serviceId, "Exists" -> True,
    "MainUser" -> mainUser, "ServiceUser" -> svcUser, "UserMatch" -> userMatch,
    "MainRootHash" -> mainHash, "ServiceRootHash" -> svcHash, "RootHashMatch" -> hashMatch,
    "LocalStatePath" -> mainLS, "LocalStateWritable" -> lsWritable,
    "CoreRootPath" -> coreRoot,
    "Warnings" -> warnings, "Healthy" -> (warnings === {})|>];

SourceVaultSendServiceCommand[serviceId_String, command_Association, opts___] := Module[
  {dir, cmdId, cmd, path},
  dir = iServiceRuntimeDir[serviceId];
  If[FailureQ[dir], Return[dir]];
  cmdId = "cmd:" <> CreateUUID[];
  cmd = Join[<|"CommandId" -> cmdId, "CreatedAtUTC" -> iSMUTCNow[]|>, command];
  path = FileNameJoin[{dir, "commands", StringReplace[cmdId, ":" -> "_"] <> ".json"}];
  If[iSMWriteJSON[path, cmd] === $Failed, Return[Failure["CommandWriteFailed", <|"ServiceId" -> serviceId|>]]];
  <|"Status" -> "Queued", "CommandId" -> cmdId, "ServiceId" -> serviceId|>];

SourceVaultServiceCommandResult[serviceId_String, commandId_String, opts___] := Module[{dir, donePath, rec},
  dir = iServiceRuntimeDir[serviceId];
  donePath = FileNameJoin[{dir, "commands", "done", StringReplace[commandId, ":" -> "_"] <> ".json"}];
  rec = iSMReadJSON[donePath];
  If[AssociationQ[rec], <|"Status" -> "Done", "Result" -> Lookup[rec, "Result"]|>,
    <|"Status" -> "Pending"|>]];

Options[SourceVaultServicePing] = {"TimeoutSeconds" -> 10};
SourceVaultServicePing[serviceId_String, OptionsPattern[]] := Module[
  {sent, cmdId, deadline, res},
  sent = SourceVaultSendServiceCommand[serviceId, <|"Command" -> "Ping"|>];
  If[FailureQ[sent], Return[sent]];
  cmdId = Lookup[sent, "CommandId"];
  deadline = AbsoluteTime[] + OptionValue["TimeoutSeconds"];
  While[AbsoluteTime[] < deadline,
    res = SourceVaultServiceCommandResult[serviceId, cmdId];
    If[Lookup[res, "Status"] === "Done",
      Return[<|"Status" -> "OK", "Pong" -> True, "Result" -> Lookup[res, "Result"]|>]];
    Pause[0.2]];
  Failure["PingTimeout", <|"ServiceId" -> serviceId|>]];

Options[SourceVaultStopService] = {"TimeoutSeconds" -> 10, "Force" -> True};
SourceVaultStopService[serviceId_String, OptionsPattern[]] := Module[
  {dir, sent, deadline, st, pidRec, pid, killed = False},
  dir = iServiceRuntimeDir[serviceId];
  If[FailureQ[dir], Return[dir]];
  sent = SourceVaultSendServiceCommand[serviceId, <|"Command" -> "Stop"|>];
  deadline = AbsoluteTime[] + OptionValue["TimeoutSeconds"];
  While[AbsoluteTime[] < deadline,
    st = SourceVaultServiceStatus[serviceId];
    If[Lookup[st, "State"] === "Stopped" || ! TrueQ[Lookup[st, "PidAlive"]], Break[]];
    Pause[0.3]];
  st = SourceVaultServiceStatus[serviceId];
  (* graceful 失敗時は pid 同一性確認のうえ kill *)
  If[TrueQ[OptionValue["Force"]] && TrueQ[Lookup[st, "PidAlive"]],
    pidRec = iSMReadJSON[FileNameJoin[{dir, "pid.json"}]];
    pid = If[AssociationQ[pidRec], Lookup[pidRec, "PID"], Missing[]];
    If[IntegerQ[pid] && iPidIsWolframProcess[pid], killed = iKillPid[pid];
      iSMWriteJSON[FileNameJoin[{dir, "status.json"}],
        <|"ServiceId" -> serviceId, "State" -> "Stopped", "StoppedAtUTC" -> iSMUTCNow[], "Killed" -> True|>]]];
  (* detachment 用の scheduled task を削除 (残しても 23:59 に再実行されるため) *)
  Quiet @ RunProcess[{"schtasks", "/Delete", "/TN", iServiceTaskName[serviceId], "/F"}];
  iServiceLog[dir, "ServiceStopRequested", <|"Killed" -> killed|>];
  <|"Status" -> "Stopped", "ServiceId" -> serviceId, "Killed" -> killed,
    "FinalState" -> Lookup[SourceVaultServiceStatus[serviceId], "State"]|>];

SourceVaultRestartService[serviceId_String, opts___] := Module[{stopRes, manifest, dir, kind, interval},
  dir = iServiceRuntimeDir[serviceId];
  manifest = iSMReadJSON[FileNameJoin[{dir, "manifest.resolved.wl"}]];
  kind = If[AssociationQ[manifest], Lookup[manifest, "Kind", "heartbeat"], "heartbeat"];
  interval = If[AssociationQ[manifest], Lookup[manifest, "HeartbeatIntervalSeconds", 1], 1];
  stopRes = SourceVaultStopService[serviceId];
  Pause[0.5];
  SourceVaultStartService[serviceId, "Kind" -> kind, "HeartbeatIntervalSeconds" -> interval]];

(* ============================================================
   ウォッチドッグ (軽量 PowerShell。wedge/crash 検知 → 既存 run.wls 再利用で自動再起動)
   - WL カーネルを spawn しない (バッテリーノート + Wolfram ライセンス同時起動数への配慮)。
   - 再起動は kill + stdout 退避 + schtasks /Run で既存サービスタスクを再実行 → root 再注入なし。
   - 意図停止 (status.State=Stopped) は復活させない。kill は wolfram プロセスのみ (pid 再利用誤爆回避)。
   - 【常駐化 (window フリッカ対策)】以前は scheduled task を /SC MINUTE で周期実行していたため、
     数分おきにコンソール窓が前面に出てフォア作業を妨げた。現在は「一度だけ起動 → PowerShell 内の
     while ループで自前 sleep → 終了させず常駐」に変更。起動は wscript の hidden launcher 経由なので
     窓は一切出ない。多重起動は named mutex で 1 本に抑止し、停止は pid 記録から kill する。
   ============================================================ *)
iWatchdogTaskName[serviceId_String] := "SourceVaultWatchdog_" <> iSafeName[serviceId];
iWatchdogMutexName[svcTask_String] := "SourceVaultWatchdog_" <> svcTask;
iWatchdogPidPath[svcDir_String] := FileNameJoin[{svcDir, "watchdog.pid.json"}];
iWatchdogPidValue[svcDir_String] := Module[{rec = iSMReadJSON[iWatchdogPidPath[svcDir]]},
  If[AssociationQ[rec], Lookup[rec, "PID", Missing[]], Missing[]]];

iWriteTextFileUTF8[path_String, text_String] := Module[{strm = OpenWrite[path, BinaryFormat -> True]},
  BinaryWrite[strm, StringToByteArray[text, "UTF-8"]]; Close[strm]; path];

(* PowerShell 監視スクリプト本体。svcDir/svcTask/staleSec/intervalSec を焼き込む。
   バックスラッシュ・二重引用符を含めない (WL 文字列エスケープ回避; パスは単一引用符で埋め込む)。
   常駐ループ: 1 回チェック → intervalSec 秒 sleep を繰り返す。終了は外部 kill (uninstall) のみ。 *)
iWatchdogPS1[svcDir_String, svcTask_String, staleSec_, intervalSec_] := StringJoin[
  "param([switch]$Once)\n",   (* hardening 02 Inc2: 単発実行 (テスト/運用診断用) *)
  "$ErrorActionPreference = 'SilentlyContinue'\n",
  "$svc = '", svcDir, "'\n",
  "$task = '", svcTask, "'\n",
  "$staleSec = ", ToString[staleSec], "\n",
  "$intervalSec = ", ToString[intervalSec], "\n",
  "$pidFile = Join-Path $svc 'watchdog.pid.json'\n",
  "$stateFile = Join-Path $svc 'restart_state.json'\n",
  (* 二重起動防止: 既に常駐 watchdog がいれば mutex を取れず即終了する。
     hardening 02 Inc2 (P0-8): New-Object の .NET 例外は SilentlyContinue でも
     script を殺すため try/catch (多重 watchdog を作らない側に倒す)。 *)
  "$createdNew = $false\n",
  "$mtx = $null\n",
  "try { $mtx = New-Object System.Threading.Mutex($true, '", iWatchdogMutexName[svcTask], "', [ref]$createdNew) } catch { if($Once){ Write-Output 'mutex-error' }; exit 0 }\n",
  (* -Once 診断は常駐と併走させない (二重 restart 防止) が、黙って空を
     返さず 'resident-active' を出力する (result8 知見)。 *)
  "if(-not $createdNew){ if($Once){ Write-Output 'resident-active' }; exit 0 }\n",
  (* 自 PID を記録 (uninstall が確実に止められるように)。 *)
  "try{ [IO.File]::WriteAllText($pidFile, ('{\"PID\":' + $PID + ',\"StartedAtUTC\":\"' + ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) + '\"}')) }catch{}\n",
  "function RJ($p){ if(Test-Path $p){ try{ Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json }catch{ $null } } else { $null } }\n",
  (* hardening 02 Inc2: restart 状態 (backoff/GivenUp) とログのヘルパ。 *)
  "function RState { $s = RJ $stateFile; if($null -eq $s){ [pscustomobject]@{ ConsecutiveFailures=0; LastRestartAtUTC=$null; GivenUp=$false } } else { $s } }\n",
  "function WState($f,$l,$g){ try{ [IO.File]::WriteAllText($stateFile, (([ordered]@{ConsecutiveFailures=$f;LastRestartAtUTC=$l;GivenUp=$g}) | ConvertTo-Json -Compress)) }catch{} }\n",
  "function WLog($obj){ try{ [IO.File]::AppendAllText((Join-Path $svc 'watchdog.log.jsonl'), ($obj | ConvertTo-Json -Compress)+[Environment]::NewLine) }catch{} }\n",
  "function NowUTC { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }\n",
  (* 健康確認できたら失敗カウンタを解除 (人手復旧後の GivenUp 自動解除を含む)。 *)
  "function MarkOk { $s0 = RState; if(([int]$s0.ConsecutiveFailures -gt 0) -or [bool]$s0.GivenUp){ WState 0 $s0.LastRestartAtUTC $false } }\n",
  (* --- 1 周期分の健全性チェック。'ok'/'idle'/'restarted'/'backoff'/'givenup'/'restartfailed' を返す。 --- *)
  "function Invoke-WatchdogCheck {\n",
  "$status = RJ (Join-Path $svc 'status.json')\n",
  "if($null -eq $status -or $status.State -ne 'Running'){ return 'idle' }\n",
  "$hb = RJ (Join-Path $svc 'heartbeat.json')\n",
  "$c1 = if($hb){ $hb.Counter } else { $null }\n",
  "$age = $null\n",
  "if($hb -and $hb.UpdatedAtUTC){ try{ $dto=[DateTimeOffset]::Parse([string]$hb.UpdatedAtUTC,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal); $age=([DateTimeOffset]::UtcNow-$dto).TotalSeconds }catch{ $age=$null } }\n",
  "$pr = RJ (Join-Path $svc 'pid.json')\n",
  "$svpid = if($pr){ [int]$pr.PID } else { 0 }\n",
  "$proc = if($svpid -gt 0){ Get-Process -Id $svpid -ErrorAction SilentlyContinue } else { $null }\n",
  "$alive = ($null -ne $proc) -and ($proc.ProcessName -match 'wolfram')\n",
  "if($alive -and $null -ne $age -and $age -le $staleSec){ MarkOk; return 'ok' }\n",
  (* hardening 02 Inc1: age が読めない (null = heartbeat 欠損/壊れ) を『健康』
     扱いしない (旧: null -> 即 ok = green-but-dead の穴)。counter の進行
     (5s 二重読み) だけを生存証拠とする。c1 が null でも c2 が読めれば
     『いま書き始めた』ので ok (起動直後: status=Running 直後〜初回 heartbeat
     の隙間で誤 restart しないため)。二重読みでも読めない/凍結なら restart へ。 *)
  "if($alive){ Start-Sleep -Seconds 5; $hb2 = RJ (Join-Path $svc 'heartbeat.json'); $c2 = if($hb2){ $hb2.Counter } else { $null }; if(($null -ne $c2) -and (($null -eq $c1) -or ($c1 -ne $c2))){ MarkOk; return 'ok' } }\n",
  (* hardening 02 Inc2 (P0-8): restart storm 抑制。
     GivenUp なら再起動しない (人手で service を直せば MarkOk が解除)。
     直近の restart から指数バックオフ (interval*2^failures, 上限 3600s)
     経過前は再起動しない。 *)
  "$state = RState\n",
  "if([bool]$state.GivenUp){ return 'givenup' }\n",
  "$backoff = [math]::Min($intervalSec * [math]::Pow(2, [int]$state.ConsecutiveFailures), 3600)\n",
  "if($state.LastRestartAtUTC){ try{ $lr=[DateTimeOffset]::Parse([string]$state.LastRestartAtUTC,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal); if((([DateTimeOffset]::UtcNow)-$lr).TotalSeconds -lt $backoff){ return 'backoff' } }catch{} }\n",
  "$stdout = Join-Path $svc 'stdout.log'\n",
  "if(Test-Path $stdout){ $st=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'); Copy-Item $stdout (Join-Path $svc ('stdout.wedge-'+$st+'.log')) -Force }\n",
  "if($alive){ Stop-Process -Id $svpid -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }\n",
  (* hardening 02 Inc2: /Run の exit code を捨てず、成功判定は実体で行う:
     60s 以内に「新 PID の heartbeat」が書かれ始めたら成功
     (schtasks は ExitCode 0 でも Queued 固着で実体が起きないことがある)。 *)
  "schtasks /Run /TN $task | Out-Null\n",
  "$rc = $LASTEXITCODE\n",
  "$ok2 = $false; $newpid = 0\n",
  "for($i=0; $i -lt 30; $i++){ Start-Sleep -Seconds 2; $pr2 = RJ (Join-Path $svc 'pid.json'); $newpid = if($pr2){ [int]$pr2.PID } else { 0 }; if(($newpid -gt 0) -and ($newpid -ne $svpid)){ $p2 = Get-Process -Id $newpid -ErrorAction SilentlyContinue; if($null -ne $p2){ $hb3 = RJ (Join-Path $svc 'heartbeat.json'); if($hb3 -and ([int]$hb3.PID -eq $newpid)){ $ok2 = $true; break } } } }\n",
  "if($ok2){ WState 0 (NowUTC) $false } else { $nf = [int]$state.ConsecutiveFailures + 1; $gu = ($nf -ge 5); WState $nf (NowUTC) $gu; if($gu){ WLog ([ordered]@{ Type='DiagnosticsEvent'; EventId=[guid]::NewGuid().ToString(); EventClass='ServiceRestartGivenUp'; AtUTC=(NowUTC); Producer='watchdog'; Severity='critical'; Payload=@{ Failures=$nf; Task=$task } }) } }\n",
  "WLog ([ordered]@{ Type='DiagnosticsEvent'; EventId=[guid]::NewGuid().ToString(); EventClass='ServiceRestarted'; AtUTC=(NowUTC); Producer='watchdog'; Severity=$(if($ok2){'warn'}else{'error'}); Payload=@{ Success=$ok2; NewPid=$newpid; OldPid=$svpid; SchtasksExit=$rc; HeartbeatAgeSeconds=$age; PidWasAlive=$alive; ConsecutiveFailures=$(if($ok2){0}else{[int]$state.ConsecutiveFailures + 1}) } })\n",
  "if($ok2){ return 'restarted' } else { return 'restartfailed' }\n",
  "}\n",
  (* --- 常駐ループ: チェック → sleep を繰り返す。窓を出さず終了もしない。
     -Once なら 1 回だけ実行して結果を出力 (テスト/診断用)。 --- *)
  "if($Once){ $r = 'ok'; try{ $r = Invoke-WatchdogCheck }catch{ $r = 'error' }; Write-Output $r; exit 0 }\n",
  "while($true){\n",
  "  $r = 'ok'\n",
  "  try{ $r = Invoke-WatchdogCheck }catch{ $r = 'ok' }\n",
  "  Start-Sleep -Seconds $intervalSec\n",
  "}\n"];

(* wscript 経由の hidden launcher。wscript は GUI サブシステムなのでコンソール窓を一切持たず、
   Run の第2引数 0 (vbHide) で起動する powershell も最初から非表示。これで窓フリッカが出ない。 *)
iWatchdogLauncherVBS[ps1Path_String] := StringJoin[
  "Set sh = CreateObject(\"WScript.Shell\")\r\n",
  "sh.Run \"powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"\"",
  ps1Path, "\"\"\", 0, False\r\n"];

iResolveWScriptExe[] := With[{sr = Environment["SystemRoot"]},
  If[StringQ[sr], FileNameJoin[{sr, "System32", "wscript.exe"}], "wscript.exe"]];

(* 既存の launch.bat を窓を出さずに起動する VBS。cmd /c 経由なので bat 内の stdout リダイレクトは
   そのまま効く。第2引数 0 (vbHide) でコンソールを最初から非表示にする。 *)
iHiddenBatLauncherVBS[batPath_String] := StringJoin[
  "Set sh = CreateObject(\"WScript.Shell\")\r\n",
  "sh.Run \"cmd /c \"\"", batPath, "\"\"\", 0, False\r\n"];

(* schtasks /TR 用の文字列。program / script path を個別に quote する。schtasks は /TR 値を
   verbatim 保存し、起動時に CreateProcess が quote 込みで program/args を分解する。 *)
iWScriptTR[vbsPath_String] := "\"" <> iResolveWScriptExe[] <> "\" //B //Nologo \"" <> vbsPath <> "\"";

(* bat を hidden launcher 化して runtime dir に vbs を書き、/TR 文字列を返す共通処理。 *)
iWriteHiddenLauncher[dir_String, batPath_String] := Module[{vbsPath = FileNameJoin[{dir, "launch_hidden.vbs"}]},
  iWriteTextFileUTF8[vbsPath, iHiddenBatLauncherVBS[batPath]];
  <|"VBS" -> vbsPath, "TR" -> iWScriptTR[vbsPath]|>];

(* schtasks /Create で作られるタスクは Windows 既定で
   DisallowStartIfOnBatteries=True / StopIfGoingOnBatteries=True になる。
   ノート PC がバッテリー運用中だと Task Scheduler が「AC 電源時のみ」条件で弾き、
   /Run しても State=Queued のまま起動せず、サービス/プロキシが上がらない
   (関数は "Started" を返すのに実体は無く、パレットは「MCP 停止中」)。schtasks CLI に
   このフラグを外すオプションが無いため、作成直後に PowerShell の Set-ScheduledTask で
   解除する。RunLevel=Limited (非昇格) タスクなので UAC 不要。best-effort: 失敗しても
   起動処理は続行する (電源連動が要件のノート機でも常駐サービスは電源に依らず動かす)。 *)
iClearTaskBatteryRestriction[task_String] := Quiet @ RunProcess[{
  "powershell", "-NoProfile", "-NonInteractive", "-Command",
  StringJoin[
    "try { $t = Get-ScheduledTask -TaskName '", task, "' -ErrorAction Stop; ",
    "$t.Settings.DisallowStartIfOnBatteries = $false; ",
    "$t.Settings.StopIfGoingOnBatteries = $false; ",
    "Set-ScheduledTask -TaskName '", task, "' -Settings $t.Settings | Out-Null } catch {}"]}];

Options[SourceVaultInstallWatchdog] = {"StaleSeconds" -> Automatic, "IntervalMinutes" -> 2};
SourceVaultInstallWatchdog[serviceId_String, OptionsPattern[]] := Module[
  {svcDir, svcTask, wdTask, staleSec, interval, intervalSec, ps1Path, vbsPath,
   trStr, oldPid, cre, runRes, deadline, wdPid},
  svcDir = iServiceRuntimeDir[serviceId];
  If[FailureQ[svcDir], Return[svcDir]];
  If[! DirectoryQ[svcDir], Return[Failure["ServiceNotInstalled", <|"ServiceId" -> serviceId|>]]];
  svcTask = iServiceTaskName[serviceId];
  wdTask = iWatchdogTaskName[serviceId];
  staleSec = OptionValue["StaleSeconds"] /.
    Automatic -> iSMHealthThreshold["WatchdogStaleSeconds", 90];
  interval = OptionValue["IntervalMinutes"];
  intervalSec = Max[5, Round[interval*60]];
  (* 旧 watchdog が常駐していれば先に止める (interval 変更を反映 / 二重常駐回避)。 *)
  oldPid = iWatchdogPidValue[svcDir];
  If[IntegerQ[oldPid] && iPidAlive[oldPid] && iPidIsPowerShell[oldPid], iKillPid[oldPid]; Pause[0.3]];
  Quiet @ If[FileExistsQ[iWatchdogPidPath[svcDir]], DeleteFile[iWatchdogPidPath[svcDir]]];
  ps1Path = FileNameJoin[{svcDir, "watchdog.ps1"}];
  vbsPath = FileNameJoin[{svcDir, "watchdog_launch.vbs"}];
  iWriteTextFileUTF8[ps1Path, iWatchdogPS1[svcDir, svcTask, staleSec, intervalSec]];
  iWriteTextFileUTF8[vbsPath, iWatchdogLauncherVBS[ps1Path]];
  (* 旧版が残した watchdog.bat は使わない。混乱回避のため削除する。 *)
  Quiet @ With[{old = FileNameJoin[{svcDir, "watchdog.bat"}]}, If[FileExistsQ[old], DeleteFile[old]]];
  trStr = iWScriptTR[vbsPath];
  (* 周期実行 (/SC MINUTE) はやめ、ONCE で一度だけ起動 → 以後は PS 常駐ループが面倒を見る。
     scheduled task は detachment 境界 (メインカーネル終了後も生存) として残す。 *)
  cre = Quiet @ RunProcess[{"schtasks", "/Create", "/TN", wdTask, "/TR", trStr,
    "/SC", "ONCE", "/ST", "23:59", "/F"}];
  iClearTaskBatteryRestriction[wdTask];  (* バッテリー運用でも起動できるよう電源条件を解除 *)
  runRes = Quiet @ RunProcess[{"schtasks", "/Run", "/TN", wdTask}];
  (* 常駐起動の確認: watchdog.pid.json を最大 ~8s 待つ (best-effort)。 *)
  deadline = AbsoluteTime[] + 8;
  While[AbsoluteTime[] < deadline && ! FileExistsQ[iWatchdogPidPath[svcDir]], Pause[0.3]];
  wdPid = iWatchdogPidValue[svcDir];
  <|"Status" -> If[AssociationQ[cre] && Lookup[cre, "ExitCode", 1] === 0 &&
      AssociationQ[runRes] && Lookup[runRes, "ExitCode", 1] === 0, "Installed", "Error"],
    "ServiceId" -> serviceId, "Task" -> wdTask, "ServiceTask" -> svcTask,
    "StaleSeconds" -> staleSec, "IntervalMinutes" -> interval, "IntervalSeconds" -> intervalSec,
    "Resident" -> True, "WatchdogPID" -> wdPid, "PS1" -> ps1Path, "Launcher" -> vbsPath,
    "ExitCode" -> If[AssociationQ[cre], Lookup[cre, "ExitCode"], Missing[]]|>];

SourceVaultUninstallWatchdog[serviceId_String] := Module[
  {wdTask = iWatchdogTaskName[serviceId], svcDir, wdPid, killed = False},
  svcDir = iServiceRuntimeDir[serviceId];
  (* scheduled task を消すだけでは常駐 PowerShell は止まらない。pid 記録から kill する。 *)
  If[! FailureQ[svcDir],
    wdPid = iWatchdogPidValue[svcDir];
    If[IntegerQ[wdPid] && iPidAlive[wdPid] && iPidIsPowerShell[wdPid], killed = iKillPid[wdPid]];
    Quiet @ If[FileExistsQ[iWatchdogPidPath[svcDir]], DeleteFile[iWatchdogPidPath[svcDir]]]];
  Quiet @ RunProcess[{"schtasks", "/Delete", "/TN", wdTask, "/F"}];
  <|"Status" -> "Uninstalled", "ServiceId" -> serviceId, "Task" -> wdTask, "Killed" -> killed|>];

SourceVaultWatchdogStatus[serviceId_String] := Module[
  {svcDir, wdTask, q, installed, logPath, evs, wdPid, alive},
  svcDir = iServiceRuntimeDir[serviceId];
  If[FailureQ[svcDir], Return[svcDir]];
  wdTask = iWatchdogTaskName[serviceId];
  q = Quiet @ RunProcess[{"schtasks", "/Query", "/TN", wdTask}];
  installed = AssociationQ[q] && Lookup[q, "ExitCode", 1] === 0;
  (* 常駐プロセスの実生存 (task 登録の有無とは別) *)
  wdPid = iWatchdogPidValue[svcDir];
  alive = IntegerQ[wdPid] && iPidAlive[wdPid] && iPidIsPowerShell[wdPid];
  logPath = FileNameJoin[{svcDir, "watchdog.log.jsonl"}];
  evs = If[FileExistsQ[logPath], iSMReadJSONL[logPath], {}];
  <|"ServiceId" -> serviceId, "Task" -> wdTask, "Installed" -> installed,
    "Resident" -> True, "ProcessAlive" -> alive,
    "WatchdogPID" -> If[IntegerQ[wdPid], wdPid, Missing[]],
    "RestartCount" -> Length[evs],
    "LastRestarts" -> If[evs === {}, {}, Take[evs, -Min[5, Length[evs]]]]|>];

SourceVaultListServices[opts___] := Module[{base, dirs},
  base = Module[{r = SourceVault`SourceVaultCoreRoot[]},
    If[FailureQ[r], Return[{}], FileNameJoin[{iRuntimeMachineRoot[r], "services"}]]];
  If[! DirectoryQ[base], Return[{}]];
  dirs = Select[FileNames["*", base], DirectoryQ];
  SourceVaultServiceStatus[FileNameTake[#]] & /@ dirs];

(* runtime/ 直下の共有/レガシー予約名 (実 PC ではない)。machine tag は $MachineName 由来なので
   これらと衝突しない。旧構成では proxies/services が runtime 直下に置かれていた名残も除外する。 *)
$iSMRuntimeReservedDirs = {"locks", "proxies", "services"};

Options[SourceVaultListRuntimeMachines] = {"Details" -> False};
SourceVaultListRuntimeMachines[OptionsPattern[]] := Module[
  {root, base, dirs, tags, self},
  root = SourceVault`SourceVaultCoreRoot[];
  self = iRuntimeMachineTag[];
  If[FailureQ[root], Return[If[TrueQ[OptionValue["Details"]],
    {<|"MachineTag" -> self, "IsSelf" -> True, "HasServices" -> False,
       "HasProxies" -> False|>}, {self}]]];
  base = FileNameJoin[{root, "runtime"}];
  dirs = If[DirectoryQ[base], Select[FileNames["*", base], DirectoryQ], {}];
  tags = Select[FileNameTake /@ dirs,
    ! MemberQ[$iSMRuntimeReservedDirs, ToLowerCase[#]] &];
  (* 自機は runtime dir が無くても sharing なので必ず含める *)
  tags = Sort[DeleteDuplicates[Append[tags, self]]];
  If[! TrueQ[OptionValue["Details"]], Return[tags]];
  Map[
    Function[tag,
      Module[{md = FileNameJoin[{base, tag}]},
        <|"MachineTag" -> tag,
          "IsSelf" -> (tag === self),
          "HasServices" -> DirectoryQ[FileNameJoin[{md, "services"}]],
          "HasProxies" -> DirectoryQ[FileNameJoin[{md, "proxies"}]]|>]],
    tags]];

Options[SourceVaultServiceLogs] = {"Limit" -> 100};
SourceVaultServiceLogs[serviceId_String, OptionsPattern[]] := Module[{dir, evs, lim},
  dir = iServiceRuntimeDir[serviceId]; lim = OptionValue["Limit"];
  evs = iSMReadJSONL[FileNameJoin[{dir, "service.log.jsonl"}]];
  If[IntegerQ[lim], Take[evs, UpTo[lim]], evs]];

SourceVaultTailServiceLog[serviceId_String, n_Integer: 20, opts___] := Module[{dir, evs},
  dir = iServiceRuntimeDir[serviceId];
  evs = iSMReadJSONL[FileNameJoin[{dir, "service.log.jsonl"}]];
  Take[evs, -Min[n, Length[evs]]]];

Options[SourceVaultRecoverServices] = {"Kill" -> False};
SourceVaultRecoverServices[OptionsPattern[]] := Module[{services, recovered = {}},
  services = SourceVaultListServices[];
  Do[
    If[Lookup[s, "State"] === "Running" && ! TrueQ[Lookup[s, "PidAlive"]],
      Module[{dir = Lookup[s, "RuntimeDir"]},
        iSMWriteJSON[FileNameJoin[{dir, "status.json"}],
          <|"ServiceId" -> Lookup[s, "ServiceId"], "State" -> "Crashed",
            "RecoveredAtUTC" -> iSMUTCNow[]|>];
        iServiceLog[dir, "ServiceRecovered", <|"Reason" -> "RunningButPidDead"|>];
        AppendTo[recovered, Lookup[s, "ServiceId"]]]],
    {s, services}];
  <|"Status" -> "OK", "Recovered" -> recovered|>];

SourceVaultServiceDoctor[serviceId_String, opts___] := Module[{dir, issues = {}, exists},
  dir = iServiceRuntimeDir[serviceId];
  exists = StringQ[dir] && DirectoryQ[dir];
  If[! exists, AppendTo[issues, "RuntimeDirMissing"]];
  If[exists,
    If[! FileExistsQ[FileNameJoin[{dir, "manifest.resolved.wl"}]], AppendTo[issues, "ManifestMissing"]];
    If[! FileExistsQ[FileNameJoin[{dir, "run.wls"}]], AppendTo[issues, "RunWlsMissing"]]];
  <|"Status" -> If[issues === {}, "OK", "Issues"], "ServiceId" -> serviceId,
    "Issues" -> issues, "Detail" -> If[exists, SourceVaultServiceStatus[serviceId], Missing[]]|>];

(* ============================================================
   §8.6-8.7  ServiceVersionSnapshot / version switching (Phase 4)
   active pointer は core の pointer event (AtomicUpdatePointer/PointerReplay) を使う。
   pointer 名は dir 名になるためコロン不可 -> iSafeName で安全化。
   ============================================================ *)

iActiveVersionPointer[serviceId_String] := "active-service-version-" <> iSafeName[serviceId];

SourceVaultCreateServiceVersionSnapshot[serviceId_String, spec_Association, opts___] := Module[{rec, saved},
  rec = Join[<|"ObjectClass" -> "SourceVaultServiceVersionSnapshot",
    "ServiceId" -> serviceId|>, spec];
  saved = SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultServiceVersionSnapshot", rec];
  If[FailureQ[saved], Return[saved]];
  (* 一覧用に作成 event を記録 *)
  SourceVault`SourceVaultAppendEvent[<|"EventClass" -> "ServiceVersionCreated",
    "ServiceId" -> serviceId, "Ref" -> Lookup[saved, "Ref"],
    "Version" -> Lookup[spec, "ServiceVersion", Lookup[saved, "Digest"]]|>];
  saved];

SourceVaultListServiceVersions[serviceId_String, opts___] := Module[{evs},
  evs = Select[SourceVault`SourceVaultTransactionLog["Limit" -> All],
    Lookup[#, "EventClass"] === "ServiceVersionCreated" && Lookup[#, "ServiceId"] === serviceId &];
  SortBy[<|"Version" -> Lookup[#, "Version"], "Ref" -> Lookup[#, "Ref"],
    "CreatedAtUTC" -> Lookup[#, "CreatedAtUTC"]|> & /@ evs, Lookup[#, "CreatedAtUTC"] &]];

iResolveVersionRef[serviceId_String, versionOrRef_String] :=
  If[StringMatchQ[versionOrRef, "snapshot:" ~~ __],
    versionOrRef,
    Module[{match = SelectFirst[SourceVaultListServiceVersions[serviceId],
        Lookup[#, "Version"] === versionOrRef &, Missing[]]},
      If[AssociationQ[match], Lookup[match, "Ref"], $Failed]]];

SourceVaultServiceVersionInfo[serviceId_String, version_: Automatic, opts___] := Module[{ref},
  ref = If[version === Automatic,
    Lookup[SourceVaultActiveServiceVersion[serviceId], "Value", $Failed],
    iResolveVersionRef[serviceId, version]];
  If[ref === $Failed || ! StringQ[ref], Return[Failure["VersionNotFound", <|"ServiceId" -> serviceId, "Version" -> version|>]]];
  SourceVault`SourceVaultLoadImmutableSnapshot[ref]];

SourceVaultActiveServiceVersion[serviceId_String, opts___] :=
  SourceVault`SourceVaultPointerReplay[iActiveVersionPointer[serviceId]];

Options[SourceVaultActivateServiceVersion] = {"VerifyArtifacts" -> True};
SourceVaultActivateServiceVersion[serviceId_String, versionOrRef_String, OptionsPattern[]] := Module[
  {ref, snap, ver, idxRefs, unresolved, ptrRes},
  ref = iResolveVersionRef[serviceId, versionOrRef];
  If[ref === $Failed || ! StringQ[ref],
    Return[Failure["VersionNotFound", <|"ServiceId" -> serviceId, "Version" -> versionOrRef|>]]];
  (* 1. digest 検証 *)
  ver = SourceVault`SourceVaultVerifyImmutableSnapshot[ref];
  If[! TrueQ[Lookup[ver, "Valid"]],
    Return[Failure["ServiceVersionDigestMismatch", <|"Ref" -> ref, "Verify" -> ver|>]]];
  snap = SourceVault`SourceVaultLoadImmutableSnapshot[ref];
  (* 2. IndexSnapshotRefs が解決できなければ fail-closed (§8.7-4) *)
  If[TrueQ[OptionValue["VerifyArtifacts"]],
    idxRefs = Lookup[snap, "IndexSnapshotRefs", {}];
    unresolved = Select[idxRefs, FailureQ[SourceVault`SourceVaultLoadImmutableSnapshot[#]] &];
    If[unresolved =!= {},
      Return[Failure["IndexArtifactsUnresolved", <|"ServiceId" -> serviceId,
        "Unresolved" -> unresolved|>]]]];
  (* 3. active pointer を pointer event で更新 *)
  ptrRes = SourceVault`SourceVaultAtomicUpdatePointer[iActiveVersionPointer[serviceId], ref];
  If[FailureQ[ptrRes], Return[ptrRes]];
  SourceVault`SourceVaultAppendEvent[<|"EventClass" -> "ServiceVersionActivated",
    "ServiceId" -> serviceId, "Ref" -> ref, "Sequence" -> Lookup[ptrRes, "Sequence"]|>];
  <|"Status" -> "Activated", "ServiceId" -> serviceId, "Ref" -> ref,
    "Sequence" -> Lookup[ptrRes, "Sequence"]|>];

Options[SourceVaultRollbackServiceVersion] = {"Reason" -> ""};
SourceVaultRollbackServiceVersion[serviceId_String, OptionsPattern[]] := Module[
  {hist, prev, ptrRes},
  hist = SourceVault`SourceVaultPointerHistory[iActiveVersionPointer[serviceId]];
  If[Length[hist] < 2,
    Return[Failure["NoPreviousVersion", <|"ServiceId" -> serviceId,
      "MessageTemplate" -> "戻せる前版がありません。"|>]]];
  prev = Lookup[hist[[-2]], "Value"];
  ptrRes = SourceVault`SourceVaultAtomicUpdatePointer[iActiveVersionPointer[serviceId], prev];
  If[FailureQ[ptrRes], Return[ptrRes]];
  SourceVault`SourceVaultAppendEvent[<|"EventClass" -> "ServiceVersionRolledBack",
    "ServiceId" -> serviceId, "Ref" -> prev, "Reason" -> OptionValue["Reason"],
    "Sequence" -> Lookup[ptrRes, "Sequence"]|>];
  <|"Status" -> "RolledBack", "ServiceId" -> serviceId, "Ref" -> prev,
    "Reason" -> OptionValue["Reason"]|>];

SourceVaultCompareServiceVersions[serviceId_String, v1_String, v2_String, opts___] := Module[
  {s1, s2, keys},
  s1 = SourceVaultServiceVersionInfo[serviceId, v1];
  s2 = SourceVaultServiceVersionInfo[serviceId, v2];
  If[FailureQ[s1], Return[s1]]; If[FailureQ[s2], Return[s2]];
  keys = {"WorkflowSnapshotRef", "CorpusSnapshotRef", "IndexSnapshotRefs",
    "ReleaseContextRef", "LatencyProfile"};
  <|"ServiceId" -> serviceId,
    "Diff" -> Association @ Map[
      # -> <|"V1" -> Lookup[s1, #, Missing[]], "V2" -> Lookup[s2, #, Missing[]],
        "Changed" -> (Lookup[s1, #, Null] =!= Lookup[s2, #, Null])|> &, keys]|>];

(* ============================================================
   Python HTTP リバースプロキシ (SocketListen が headless wolframscript で
   機能しないため、HTTP edge は stdlib Python に委ねる)。
   proxy code は vault data (immutable snapshot) として保存し、起動時に
   working へ materialize + SHA256 検証して実行する (ポータブル化)。
   gate は WL service 側。proxy は status/heartbeat 直読みと command queue
   中継のみで raw vault を公開しない。
   ============================================================ *)

If[! ValueQ[SourceVault`$SourceVaultPython], SourceVault`$SourceVaultPython = Automatic];

(* python 実行ファイル解決。WindowsApps の stub は避け実体を優先。 *)
iResolvePython[] := Module[{o, lines = {}, real},
  o = SourceVault`$SourceVaultPython;
  If[StringQ[o] && FileExistsQ[o], Return[o]];
  Do[Module[{r = Quiet @ RunProcess[{"where", c}]},
      If[AssociationQ[r] && Lookup[r, "ExitCode"] === 0,
        lines = Join[lines, Select[StringTrim /@ StringSplit[Lookup[r, "StandardOutput", ""], "\n"],
          StringLength[#] > 0 &]]]],
    {c, {"python3", "python"}}];
  lines = DeleteDuplicates[lines];
  real = SelectFirst[lines, ! StringContainsQ[#, "WindowsApps"] &, Missing[]];
  Which[StringQ[real], real, lines =!= {}, First[lines], True, "python"]];

iSHA256Str[s_String] := ToLowerCase @ Hash[StringToByteArray[s, "UTF-8"], "SHA256", "HexString"];

(* proxy Python ソース。シングルクォートのみ・バックスラッシュ無し
   (WL 文字列へのエスケープを避けるため)。stdlib のみ。 *)
$proxyPySource = "import sys, os, json, time, uuid, calendar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

CFG = json.load(open(sys.argv[1], encoding='utf-8'))
SVC = CFG['svcDir']
PREFIX = CFG.get('routePrefix', '/sv')
RC = CFG.get('releaseContext')
PROFILE = CFG.get('pdfIndexProfile')
APPTITLE = CFG.get('appTitle')
ASKPROMPT = CFG.get('askPrompt')
CHATMODEL = CFG.get('chatModel')
OWNERIPS = CFG.get('ownerIPs', ['127.0.0.1'])
BILLING = CFG.get('billingAllowed', False)
SUBALLOW = CFG.get('subscriptionAllowed', False)
TIMEOUT = CFG.get('searchTimeoutMs', 8000) / 1000.0
MCPTOKEN = CFG.get('mcpToken')
MCPTIMEOUT = CFG.get('mcpTimeoutMs', 60000) / 1000.0
HOK = CFG.get('healthOkSeconds', 15)
HDEG = CFG.get('healthDegradedSeconds', 60)
RUNTIME = os.path.dirname(os.path.abspath(sys.argv[1]))

def rj(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}

PINGIV = CFG.get('pingIntervalSeconds', 60)
PINGTO = CFG.get('pingTimeoutSeconds', 10)
REQL2 = bool(CFG.get('requireL2', False))
_ping_cache = {'t': 0.0, 'ok': None, 'rtt': None}

# hardening 02 Inc3b: queue ping (L2)。heartbeat は「ループ生存」しか
# 証明しないため、Ping command が done/ に落ちること (=公開処理系の生存)
# を確認する。PINGIV キャッシュで /health 連打でも queue は 1 分に 1 回。
def queue_ping():
    now = time.time()
    if _ping_cache['ok'] is not None and now - _ping_cache['t'] < PINGIV:
        return _ping_cache
    t0 = time.time()
    r = None
    try:
        r = run_cmd({'CommandId': 'ping:' + str(uuid.uuid4()),
                     'Command': 'Ping'}, timeout=PINGTO)
    except Exception:
        r = None
    _ping_cache['t'] = now
    _ping_cache['ok'] = bool(r and r.get('Pong'))
    _ping_cache['rtt'] = (round((time.time() - t0) * 1000)
                          if _ping_cache['ok'] else None)
    return _ping_cache

def health():
    st = rj(os.path.join(SVC, 'status.json'))
    hb = rj(os.path.join(SVC, 'heartbeat.json'))
    age = None
    ts = hb.get('UpdatedAtUTC')
    if ts:
        try:
            age = max(0.0, time.time() - calendar.timegm(time.strptime(ts, '%Y-%m-%dT%H:%M:%SZ')))
        except Exception:
            age = None
    if age is None:
        hstate = 'Unknown'
    elif age <= HOK:
        hstate = 'OK'
    elif age <= HDEG:
        hstate = 'Degraded'
    else:
        hstate = 'Stale'
    ping = None
    layer = 'L1'
    if hstate in ('OK', 'Degraded') and st.get('State') == 'Running':
        p = queue_ping()
        ping = {'l2': p['ok'], 'rttMs': p['rtt']}
        if p['ok']:
            layer = 'L2'
        else:
            layer = 'L3'
            # requireL2: heartbeat が進むのに queue 不応答 → OK を剥奪
            # (healthState=='OK' を見る MCPRunningQ が False になり、
            #  パレットの誤「実行中」→逆 Stop 連鎖を防ぐ)
            if REQL2 and hstate == 'OK':
                hstate = 'Degraded'
    return {'ok': hstate in ('OK', 'Degraded'), 'service': st.get('ServiceId'), 'state': st.get('State'),
            'pid': st.get('PID'), 'heartbeatCounter': hb.get('Counter'),
            'heartbeatAgeSeconds': (round(age, 1) if age is not None else None),
            'healthState': hstate, 'layer': layer, 'ping': ping,
            'atUTC': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}

def run_cmd(cmd, timeout=None):
    to = TIMEOUT if timeout is None else timeout
    cid = cmd['CommandId']
    fn = cid.replace(':', '_') + '.json'
    cdir = os.path.join(SVC, 'commands')
    os.makedirs(os.path.join(cdir, 'done'), exist_ok=True)
    tmp = os.path.join(cdir, fn + '.tmp')
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(cmd, f, ensure_ascii=False)
    os.replace(tmp, os.path.join(cdir, fn))
    done = os.path.join(cdir, 'done', fn)
    end = time.time() + to
    while time.time() < end:
        if os.path.exists(done):
            return rj(done).get('Result', {})
        time.sleep(0.15)
    return None

def http_cmd(method, path, query, body, client_ip):
    cid = 'cmd:' + str(uuid.uuid4())
    cmd = {'CommandId': cid, 'Command': 'Http', 'Method': method,
           'Path': path, 'Query': query, 'Body': body,
           'ReleaseContext': RC, 'PDFIndexProfile': PROFILE, 'RoutePrefix': PREFIX,
           'AppTitle': APPTITLE, 'AskPrompt': ASKPROMPT, 'ChatModel': CHATMODEL,
           'ClientIP': client_ip, 'OwnerIPs': OWNERIPS, 'BillingAllowed': BILLING,
           'SubscriptionAllowed': SUBALLOW}
    return run_cmd(cmd)

class H(BaseHTTPRequestHandler):
    def emit(self, code, ctype, body_str):
        body = body_str.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        self.wfile.write(body)
    def app_path(self, p):
        if p == PREFIX or p == PREFIX + '/':
            return '/'
        if p.startswith(PREFIX):
            return p[len(PREFIX):] or '/'
        return p
    def handle_req(self, method):
        u = urlparse(self.path)
        if u.path == PREFIX + '/health':
            self.emit(200, 'application/json; charset=utf-8',
                      json.dumps(health(), ensure_ascii=False))
            return
        if u.path == PREFIX + '/mcp':
            self.handle_mcp(method)
            return
        # Wolfram AgentTools MCP (service kernel + subkernel; replaces wlmcp-gateway)
        if u.path == '/wl/mcp':
            self.handle_wlmcp(method)
            return
        if u.path == '/wl/health':
            self.emit(200, 'application/json; charset=utf-8',
                      json.dumps(health(), ensure_ascii=False))
            return
        body = ''
        if method == 'POST':
            ln = int(self.headers.get('Content-Length', 0) or 0)
            if ln > 0:
                body = self.rfile.read(ln).decode('utf-8', 'replace')
        res = http_cmd(method, self.app_path(u.path), u.query, body, self.client_address[0])
        if not isinstance(res, dict) or 'Body' not in res:
            self.emit(504, 'text/plain; charset=utf-8', 'service timeout')
            return
        self.emit(int(res.get('StatusCode', 200)),
                  res.get('ContentType', 'text/html; charset=utf-8'),
                  res.get('Body', ''))
    def handle_wlmcp(self, method):
        if MCPTOKEN:
            if self.headers.get('X-SourceVault-Token', '') != MCPTOKEN:
                self.emit(401, 'application/json; charset=utf-8',
                          json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32001, 'message': 'Unauthorized'}}))
                return
        if method != 'POST':
            self.emit(405, 'application/json; charset=utf-8',
                      json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'Use POST'}}))
            return
        ln = int(self.headers.get('Content-Length', 0) or 0)
        raw = self.rfile.read(ln).decode('utf-8', 'replace') if ln > 0 else ''
        try:
            req = json.loads(raw)
        except Exception:
            self.emit(400, 'application/json; charset=utf-8',
                      json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error'}}))
            return
        rid = req.get('id')
        rmethod = req.get('method', '')
        if rid is None and isinstance(rmethod, str) and rmethod.startswith('notifications/'):
            self.emit(202, 'application/json; charset=utf-8', '')
            return
        cid = 'cmd:' + str(uuid.uuid4())
        cmd = {'CommandId': cid, 'Command': 'WLMCP', 'Message': req, 'ClientIP': self.client_address[0]}
        res = run_cmd(cmd, MCPTIMEOUT)
        if not isinstance(res, dict):
            self.emit(504, 'application/json; charset=utf-8',
                      json.dumps({'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32000, 'message': 'service timeout'}}))
            return
        out = res.get('WLMCP')
        if not isinstance(out, dict):
            out = {'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32603, 'message': 'Internal error'}}
        self.emit(200, 'application/json; charset=utf-8', json.dumps(out, ensure_ascii=False))
    def handle_mcp(self, method):
        if MCPTOKEN:
            if self.headers.get('X-SourceVault-Token', '') != MCPTOKEN:
                self.emit(401, 'application/json; charset=utf-8',
                          json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32001, 'message': 'Unauthorized'}}))
                return
        if method != 'POST':
            self.emit(405, 'application/json; charset=utf-8',
                      json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32600, 'message': 'Use POST'}}))
            return
        ln = int(self.headers.get('Content-Length', 0) or 0)
        raw = self.rfile.read(ln).decode('utf-8', 'replace') if ln > 0 else ''
        try:
            req = json.loads(raw)
        except Exception:
            self.emit(400, 'application/json; charset=utf-8',
                      json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error'}}))
            return
        rid = req.get('id')
        rmethod = req.get('method', '')
        params = req.get('params', {})
        if not isinstance(params, dict):
            params = {}
        if rid is None and isinstance(rmethod, str) and rmethod.startswith('notifications/'):
            self.emit(202, 'application/json; charset=utf-8', '')
            return
        cid = 'cmd:' + str(uuid.uuid4())
        cmd = {'CommandId': cid, 'Command': 'MCP', 'Method': rmethod, 'Params': params, 'ClientIP': self.client_address[0]}
        res = run_cmd(cmd, MCPTIMEOUT)
        if not isinstance(res, dict):
            self.emit(504, 'application/json; charset=utf-8',
                      json.dumps({'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32000, 'message': 'service timeout'}}))
            return
        if 'MCP' in res:
            out = {'jsonrpc': '2.0', 'id': rid, 'result': res['MCP']}
        elif 'MCPError' in res:
            out = {'jsonrpc': '2.0', 'id': rid, 'error': res['MCPError']}
        else:
            out = {'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32603, 'message': 'Internal error'}}
        self.emit(200, 'application/json; charset=utf-8', json.dumps(out, ensure_ascii=False))
    def do_GET(self):
        self.handle_req('GET')
    def do_POST(self):
        self.handle_req('POST')
    def log_message(self, *a):
        return

class SVServer(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True

srv = SVServer((CFG.get('bind', '127.0.0.1'), int(CFG['port'])), H)
with open(os.path.join(RUNTIME, 'proxy.pid'), 'w') as f:
    f.write(str(os.getpid()))
srv.serve_forever()
";

iProxyRuntimeDir[serviceId_String] := Module[{root = SourceVault`SourceVaultCoreRoot[]},
  If[FailureQ[root], root, FileNameJoin[{iRuntimeMachineRoot[root], "proxies", serviceId}]]];
SourceVaultProxyRuntimeDir[serviceId_String] := iProxyRuntimeDir[serviceId];
iProxyTaskName[serviceId_String] := "SourceVaultProxy_" <> iSafeName[serviceId];

SourceVaultPublishProxyCodeSnapshot[opts___] := Module[{rec, saved},
  rec = <|"ObjectClass" -> "SourceVaultProxyCode", "Language" -> "Python",
    "Name" -> "sv-http-proxy", "Code" -> $proxyPySource,
    "CodeSHA256" -> iSHA256Str[$proxyPySource]|>;
  saved = SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultProxyCode", rec,
    "Alias" -> "sv-http-proxy"];
  If[FailureQ[saved], saved, Append[saved, "CodeSHA256" -> rec["CodeSHA256"]]]];

Options[SourceVaultMaterializeProxyCode] = {"CodeRef" -> Automatic};
SourceVaultMaterializeProxyCode[targetDir_String, OptionsPattern[]] := Module[
  {ref, code, sha, path, strm, actual},
  ref = OptionValue["CodeRef"];
  If[ref === Automatic,
    code = $proxyPySource; sha = iSHA256Str[$proxyPySource],
    Module[{r = SourceVault`SourceVaultLoadImmutableSnapshot[ref]},
      If[FailureQ[r], Return[r]];
      code = Lookup[r, "Code"]; sha = Lookup[r, "CodeSHA256"]]];
  If[! StringQ[code], Return[Failure["ProxyCodeMissing", <|"Ref" -> ref|>]]];
  iSMEnsureDir[targetDir];
  path = FileNameJoin[{targetDir, "proxy.py"}];
  strm = OpenWrite[path, BinaryFormat -> True];
  BinaryWrite[strm, StringToByteArray[code, "UTF-8"]]; Close[strm];
  (* 出力後に SHA256 を検証 (改竄/破損検知, fail-closed) *)
  actual = ToLowerCase @ Hash[ReadByteArray[path], "SHA256", "HexString"];
  If[actual =!= sha,
    Return[Failure["ProxyCodeDigestMismatch", <|"Path" -> path, "Expected" -> sha, "Actual" -> actual|>]]];
  <|"Status" -> "OK", "Path" -> path, "CodeSHA256" -> sha|>];

Options[SourceVaultStartHTTPProxy] = {
  "Port" -> None, "EndpointProfile" -> None, "RoutePrefix" -> "/sv",
  "ReleaseContext" -> None, "PDFIndexProfile" -> None, "Bind" -> "127.0.0.1",
  "CodeRef" -> Automatic, "SearchTimeoutMs" -> 8000,
  "AppTitle" -> Automatic, "AskPrompt" -> Automatic, "ChatModel" -> Automatic,
  "PDFGroupProfile" -> None, "OwnerIPs" -> Automatic, "BillingAllowed" -> Automatic,
  "AllowOwnerSubscription" -> False, "MCPToken" -> None, "MCPTimeoutMs" -> 60000};
SourceVaultStartHTTPProxy[serviceId_String, OptionsPattern[]] := Module[
  {proxyDir, svcDir, port, prefix, mat, cfgPath, py, batPath, task, runRes,
   pidPath, deadline, pid, ep, epName, bind, releaseCtx, pdfProfile, appTitle, askPrompt, chatModel,
   fromEP, grpName, grp, fromG, ownerIPs, billingAllowed, subscriptionAllowed},
  proxyDir = iProxyRuntimeDir[serviceId];
  If[FailureQ[proxyDir], Return[proxyDir]];
  svcDir = iServiceRuntimeDir[serviceId];
  port = OptionValue["Port"]; prefix = OptionValue["RoutePrefix"]; bind = OptionValue["Bind"];
  releaseCtx = OptionValue["ReleaseContext"]; pdfProfile = OptionValue["PDFIndexProfile"];
  appTitle = OptionValue["AppTitle"]; askPrompt = OptionValue["AskPrompt"]; chatModel = OptionValue["ChatModel"];
  epName = OptionValue["EndpointProfile"];
  (* endpoint profile が Web アプリ設定 (AppTitle/AskPrompt/ChatModel 等) の本体。
     アプリ固有値は profile (private local init) に置く。直接オプションが優先、無ければ profile から。 *)
  If[StringQ[epName],
    ep = SourceVaultResolveWebServiceEndpoint[epName];
    If[FailureQ[ep], Return[ep]];
    port = Lookup[ep, "Port", port]; prefix = Lookup[ep, "RoutePrefix", prefix];
    bind = Lookup[ep, "BindAddress", bind];
    fromEP[opt_, key_, none_] := If[opt === none, Lookup[ep, key, none], opt];
    releaseCtx = fromEP[releaseCtx, "ReleaseContext", None];
    pdfProfile = fromEP[pdfProfile, "PDFIndexProfile", None];
    appTitle = fromEP[appTitle, "AppTitle", Automatic];
    askPrompt = fromEP[askPrompt, "AskPrompt", Automatic];
    chatModel = fromEP[chatModel, "ChatModel", Automatic]];
  (* §19: PDFGroupSearchProfile が未設定の項目を埋める (直接 > endpoint > group > 既定)。
     これ一つで PDF グループ app の設定を供給でき、横展開は profile 追加だけで済む。 *)
  grpName = OptionValue["PDFGroupProfile"];
  If[StringQ[grpName],
    grp = SourceVault`SourceVaultResolvePDFGroupSearchProfile[grpName];
    If[FailureQ[grp], Return[grp]];
    fromG[opt_, key_, none_] := If[opt === none, Lookup[grp, key, none], opt];
    port = If[IntegerQ[port], port, Lookup[grp, "Port", port]];
    releaseCtx = fromG[releaseCtx, "ReleaseContext", None];
    pdfProfile = fromG[pdfProfile, "PDFIndexProfile", None];
    appTitle = fromG[appTitle, "AppTitle", Automatic];
    askPrompt = fromG[askPrompt, "AskPrompt", Automatic];
    chatModel = fromG[chatModel, "ChatModel", Automatic]];
  If[! IntegerQ[port],
    Return[Failure["ProxyPortRequired", <|
      "MessageTemplate" -> "Port または EndpointProfile が必要です。"|>]]];
  iSMEnsureDir[proxyDir];
  (* 旧 proxy が残っていれば kill してから起動 (Windows の多重バインド/ゾンビ累積防止)。
     proxy.pid は起動成功時のみ書かれるので、生きていれば前インスタンス。 *)
  Module[{oldPidPath = FileNameJoin[{proxyDir, "proxy.pid"}], oldPid},
    oldPid = If[FileExistsQ[oldPidPath],
      Quiet @ ToExpression @ StringTrim @ ByteArrayToString[ReadByteArray[oldPidPath], "UTF-8"],
      Missing[]];
    If[IntegerQ[oldPid] && iPidAlive[oldPid], iKillPid[oldPid]; Pause[0.5]];
    Quiet @ If[FileExistsQ[oldPidPath], DeleteFile[oldPidPath]]];
  mat = SourceVaultMaterializeProxyCode[proxyDir, "CodeRef" -> OptionValue["CodeRef"]];
  If[FailureQ[mat], Return[mat]];
  cfgPath = FileNameJoin[{proxyDir, "proxy.config.json"}];
  (* ライセンス/課金ポリシー: Automatic はカーネル既定 (オーナーIP={127.0.0.1...}, 課金禁止) を採用 *)
  ownerIPs = OptionValue["OwnerIPs"] /. Automatic -> SourceVault`$SourceVaultOwnerIPs;
  billingAllowed = TrueQ[OptionValue["BillingAllowed"] /. Automatic -> SourceVault`$SourceVaultBillingAllowed];
  (* サブスク (ClaudeCode/Codex) は保守的に既定で不使用。明示許可 かつ ローカルバインド時のみ可。
     公開バインド (127.0.0.1/::1/localhost 以外) ではオーナー宛でもサブスクを使わない。 *)
  subscriptionAllowed = TrueQ[OptionValue["AllowOwnerSubscription"]] &&
    MemberQ[{"127.0.0.1", "::1", "localhost"}, bind];
  iSMWriteJSON[cfgPath, <|"svcDir" -> svcDir, "port" -> port, "routePrefix" -> prefix,
    "ownerIPs" -> ownerIPs, "billingAllowed" -> billingAllowed,
    "subscriptionAllowed" -> subscriptionAllowed,
    "bind" -> bind, "releaseContext" -> releaseCtx, "pdfIndexProfile" -> pdfProfile,
    "appTitle" -> (appTitle /. Automatic -> Null),
    "askPrompt" -> (askPrompt /. Automatic -> Null),
    "chatModel" -> (chatModel /. Automatic -> Null),
    "searchTimeoutMs" -> OptionValue["SearchTimeoutMs"],
    "mcpToken" -> (OptionValue["MCPToken"] /. (None | Automatic) -> Null),
    "mcpTimeoutMs" -> OptionValue["MCPTimeoutMs"],
    "healthOkSeconds" -> iSMHealthThreshold["OKSeconds", 15],
    "healthDegradedSeconds" -> iSMHealthThreshold["DegradedSeconds", 60],
    (* hardening 02 Inc3b: /health の queue ping (L2) 設定 *)
    "pingIntervalSeconds" -> iSMHealthThreshold["PingIntervalSeconds", 60],
    "pingTimeoutSeconds" -> iSMHealthThreshold["PingTimeoutSeconds", 10],
    "requireL2" -> TrueQ[$SourceVaultHealthRequireL2]|>];
  py = iResolvePython[];
  batPath = FileNameJoin[{proxyDir, "launch.bat"}];
  iRotateLog[FileNameJoin[{proxyDir, "stdout.log"}]];  (* #1: proxy ログも世代退避 *)
  Module[{strm = OpenWrite[batPath, BinaryFormat -> True], q},
    q[s_] := "\"" <> s <> "\"";
    BinaryWrite[strm, StringToByteArray[
      "@echo off\r\n" <> q[py] <> " " <> q[FileNameJoin[{proxyDir, "proxy.py"}]] <>
        " " <> q[cfgPath] <> " > " <> q[FileNameJoin[{proxyDir, "stdout.log"}]] <> " 2>&1\r\n",
      "UTF-8"]]; Close[strm]];
  task = iProxyTaskName[serviceId];
  (* 【窓非表示】service と同じく wscript hidden launcher 経由で起動し、python の
     コンソール窓を出さない (stdout リダイレクトは bat 側で維持)。 *)
  Quiet @ RunProcess[{"schtasks", "/Create", "/TN", task, "/TR", iWriteHiddenLauncher[proxyDir, batPath]["TR"],
    "/SC", "ONCE", "/ST", "23:59", "/F"}];
  iClearTaskBatteryRestriction[task];  (* バッテリー運用でも起動できるよう電源条件を解除 *)
  runRes = Quiet @ RunProcess[{"schtasks", "/Run", "/TN", task}];
  If[! (AssociationQ[runRes] && Lookup[runRes, "ExitCode"] === 0),
    Return[Failure["ProxyTaskRunFailed", <|"ServiceId" -> serviceId, "Task" -> task|>]]];
  pidPath = FileNameJoin[{proxyDir, "proxy.pid"}];
  deadline = AbsoluteTime[] + 30;
  While[AbsoluteTime[] < deadline && ! FileExistsQ[pidPath], Pause[0.4]];
  pid = If[FileExistsQ[pidPath],
    Quiet @ ToExpression @ StringTrim @ ByteArrayToString[ReadByteArray[pidPath], "UTF-8"],
    Missing["Pending"]];
  <|"Status" -> "Started", "ServiceId" -> serviceId, "PID" -> pid, "Port" -> port,
    "ProxyDir" -> proxyDir, "Python" -> py, "CodeSHA256" -> Lookup[mat, "CodeSHA256"],
    "HealthURL" -> "http://" <> bind <> ":" <> ToString[port] <> prefix <> "/health"|>];

SourceVaultHTTPProxyStatus[serviceId_String, opts___] := Module[{proxyDir, pidPath, pid, alive, cfg},
  proxyDir = iProxyRuntimeDir[serviceId];
  If[FailureQ[proxyDir] || ! DirectoryQ[proxyDir],
    Return[<|"ServiceId" -> serviceId, "State" -> "Unknown", "Exists" -> False|>]];
  pidPath = FileNameJoin[{proxyDir, "proxy.pid"}];
  pid = If[FileExistsQ[pidPath],
    Quiet @ ToExpression @ StringTrim @ ByteArrayToString[ReadByteArray[pidPath], "UTF-8"], Missing[]];
  alive = If[IntegerQ[pid], iPidAlive[pid], False];
  cfg = iSMReadJSON[FileNameJoin[{proxyDir, "proxy.config.json"}]];
  <|"ServiceId" -> serviceId, "PID" -> pid, "PidAlive" -> alive,
    "State" -> If[TrueQ[alive], "Running", "Stopped"],
    "Port" -> If[AssociationQ[cfg], Lookup[cfg, "port"], Missing[]],
    "RoutePrefix" -> If[AssociationQ[cfg], Lookup[cfg, "routePrefix", "/sv"], "/sv"],
    "ProxyDir" -> proxyDir, "Exists" -> True|>];

SourceVaultStopHTTPProxy[serviceId_String, opts___] := Module[{proxyDir, pidPath, pid, killed = False},
  proxyDir = iProxyRuntimeDir[serviceId];
  If[FailureQ[proxyDir], Return[proxyDir]];
  pidPath = FileNameJoin[{proxyDir, "proxy.pid"}];
  pid = If[FileExistsQ[pidPath],
    Quiet @ ToExpression @ StringTrim @ ByteArrayToString[ReadByteArray[pidPath], "UTF-8"], Missing[]];
  If[IntegerQ[pid] && iPidAlive[pid], killed = iKillPid[pid]];
  (* config の port を握る残党 (proxy.pid 上書きで取り逃した zombie) もポート基準で kill。 *)
  Module[{cfg = iSMReadJSON[FileNameJoin[{proxyDir, "proxy.config.json"}]], port, lines},
    port = If[AssociationQ[cfg], Lookup[cfg, "port"], Missing[]];
    If[IntegerQ[port],
      lines = Select[
        StringSplit[Quiet @ RunProcess[{"netstat", "-ano"}]["StandardOutput"], "\n"],
        StringContainsQ[#, ":" <> ToString[port] <> " "] && StringContainsQ[#, "LISTENING"] &];
      Do[Module[{p = Last[StringSplit[ln]]},
          If[StringMatchQ[p, NumberString] && p =!= "0",
            Quiet @ RunProcess[{"taskkill", "/PID", p, "/F"}]; killed = True]],
        {ln, lines}]]];
  Quiet @ RunProcess[{"schtasks", "/Delete", "/TN", iProxyTaskName[serviceId], "/F"}];
  Quiet @ If[FileExistsQ[pidPath], DeleteFile[pidPath]];
  <|"Status" -> "Stopped", "ServiceId" -> serviceId, "Killed" -> killed|>];

(* ============================================================
   MCP サーバ起動/停止の便利ラッパー + claudecode パレットへの登録
   ------------------------------------------------------------
   WL service (カーネル) + HTTP/MCP proxy (Python) の二段を一括制御する。
   パレットへは claudecode の package-neutral レジストリ経由で登録する
   (rule 11: claudecode は SourceVault に依存しない; 弱参照のみ)。
   ============================================================ *)
(* serviceId はパッケージ名由来の汎用既定。port/token は環境依存値なのでソースに直書きせず
   (rule03)、既存サービスの proxy.config.json から自動解決する (Automatic)。 *)
If[! StringQ[SourceVault`$SourceVaultMCPServiceId], SourceVault`$SourceVaultMCPServiceId = "sourcevault"];
If[! ValueQ[SourceVault`$SourceVaultMCPPort], SourceVault`$SourceVaultMCPPort = Automatic];
If[! ValueQ[SourceVault`$SourceVaultMCPToken], SourceVault`$SourceVaultMCPToken = Automatic];

iMCPServiceId[Automatic] := SourceVault`$SourceVaultMCPServiceId;
iMCPServiceId[s_String] := s;
iMCPServiceId[_] := SourceVault`$SourceVaultMCPServiceId;

(* 既存 proxy.config.json から port/token を読む (env 依存値をソースに置かない)。
   既存サービスがあればその port を引き継ぎ、無ければ汎用 fallback (8731)。 *)
iMCPProxyConfig[sid_String] := Module[{pd = Quiet @ Check[iProxyRuntimeDir[sid], $Failed]},
  If[StringQ[pd], iSMReadJSON[FileNameJoin[{pd, "proxy.config.json"}]], $Failed]];
iMCPResolvePort[Automatic, sid_String] := Module[{cfg = iMCPProxyConfig[sid], p},
  p = If[AssociationQ[cfg], Lookup[cfg, "port", Missing[]], Missing[]];
  If[IntegerQ[p], p, 8731]];
iMCPResolvePort[n_Integer, _] := n;
iMCPResolvePort[_, sid_String] := iMCPResolvePort[Automatic, sid];
iMCPResolveToken[Automatic, sid_String] := Module[{cfg = iMCPProxyConfig[sid], t},
  t = If[AssociationQ[cfg], Lookup[cfg, "mcpToken", Null], Null];
  If[StringQ[t] && t =!= "", t, None]];
iMCPResolveToken[t_, _] := t;

(* proxy の /health へ実 HTTP 接続して到達性を確認する。任意の HTTP 応答 (200/401/404 等) が
   返れば port は listen 中 = 到達可能。接続拒否 (ECONNREFUSED) は $Failed → 到達不可。
   pid 生存だけでは stale/再利用 pid を「Running」と誤検知するため、実到達性で判定する。 *)
iMCPHealthUrl[st_] := Module[{port, prefix},
  If[! AssociationQ[st], Return[Missing[]]];
  port = Lookup[st, "Port", Missing[]];
  If[! IntegerQ[port], Return[Missing[]]];
  prefix = With[{p = Lookup[st, "RoutePrefix", "/sv"]}, If[StringQ[p], p, "/sv"]];
  "http://127.0.0.1:" <> ToString[port] <> prefix <> "/health"];
iMCPReachableQ[st_] := Module[{url, r},
  url = iMCPHealthUrl[st];
  If[! StringQ[url], Return[False]];
  r = Quiet @ TimeConstrained[
    URLRead[HTTPRequest[url, <|"Method" -> "GET"|>], "StatusCode"], 6, $Failed];
  IntegerQ[r]];

(* /health の本文を読み、WL サービスカーネルが「真に健全」か (healthState=="OK") を判定する。
   proxy が listen しているだけ (= iMCPReachableQ True) でも背後の service kernel が死んで
   いれば healthState は "Stale"/"Unknown" になり、本関数は False を返す。
   これによりパレットのトグルが「proxy 生存 = 実行中」と誤認して逆に Stop する事故を防ぐ。
   pid 用の RunProcess[tasklist] は使わず HTTP GET + JSON パースのみ (窓フリッカ対策は維持)。 *)
iMCPHealthyQ[st_] := Module[{url, body, j},
  url = iMCPHealthUrl[st];
  If[! StringQ[url], Return[False]];
  body = Quiet @ TimeConstrained[
    URLRead[HTTPRequest[url, <|"Method" -> "GET"|>], "Body"], 6, $Failed];
  If[! StringQ[body], Return[False]];
  j = Quiet @ Check[ImportString[body, "RawJSON"], $Failed];
  If[! AssociationQ[j], Return[False]];
  TrueQ[Lookup[j, "ok", False]] && Lookup[j, "healthState", Missing[]] === "OK"];

Options[SourceVaultMCPRunningQ] = {"ServiceId" -> Automatic};
SourceVaultMCPRunningQ[OptionsPattern[]] := Module[{sid, cfg, st},
  sid = iMCPServiceId[OptionValue["ServiceId"]];
  (* 「Running」= proxy が listen しているだけでなく、背後の WL サービスカーネルが健全
     (/health の healthState=="OK")。proxy だけ上がって service kernel が死んでいる状態
     (再起動直後など) を「実行中」と誤判定すると、パレットのトグルが逆に Stop して Svc タスク
     ごと消す事故になるため、真の health を見る。port/prefix は proxy.config.json から直接読む。
     【窓フリッカ対策】pid 用 RunProcess[tasklist] は使わず HTTP GET + JSON パースのみ
     (本関数はパレットが UpdateInterval->15 で定期呼びするため、端末窓を出さないことが重要)。 *)
  cfg = iMCPProxyConfig[sid];
  st = If[AssociationQ[cfg],
    <|"Port" -> Lookup[cfg, "port", Missing[]],
      "RoutePrefix" -> Lookup[cfg, "routePrefix", "/sv"]|>,
    Missing[]];
  iMCPHealthyQ[st]];

Options[SourceVaultStartMCP] = {
  "ServiceId" -> Automatic, "Port" -> Automatic, "MCPToken" -> Automatic, "RestartService" -> False};
SourceVaultStartMCP[OptionsPattern[]] := Module[{sid, port, tok, svcRunning, svc, prox},
  sid  = iMCPServiceId[OptionValue["ServiceId"]];
  port = iMCPResolvePort[Replace[OptionValue["Port"], Automatic -> SourceVault`$SourceVaultMCPPort], sid];
  tok  = iMCPResolveToken[Replace[OptionValue["MCPToken"], Automatic -> SourceVault`$SourceVaultMCPToken], sid];
  (* WL service を確保。RestartService 指定時は再注入のため restart。
     「Running」判定は status.json の State 文字列だけでなく実 pid 生存 (PidAlive) も要求する。
     カーネルが crash すると自分で status を Crashed に書けず "Running" のまま残るため、
     State だけ見ると死んだカーネルを AlreadyRunning と誤認して再起動せず、proxy は上がるが
     /health が Stale のまま (= MCPRunningQ False) になり、パレットが「停止中」のまま
     クリックしても復帰しない (StartService は PidAlive を見るので、ここで偽 Running を弾けば
     下の True 分岐で正しく起動し直す)。 *)
  svcRunning = With[{s = Quiet @ Check[SourceVaultServiceStatus[sid], $Failed]},
    AssociationQ[s] && Lookup[s, "State", ""] === "Running" &&
      TrueQ[Lookup[s, "PidAlive", False]]];
  svc = Which[
    TrueQ[OptionValue["RestartService"]] && svcRunning, SourceVaultRestartService[sid],
    svcRunning, <|"Status" -> "AlreadyRunning", "ServiceId" -> sid|>,
    True, SourceVaultStartService[sid]];
  (* /sv/mcp を公開する proxy を起動。token があれば認証付き。 *)
  prox = SourceVaultStartHTTPProxy[sid, "Port" -> port,
    Sequence @@ If[StringQ[tok] && tok =!= "", {"MCPToken" -> tok}, {}]];
  <|"Status" -> "Started", "ServiceId" -> sid, "Port" -> port,
    "Url" -> "http://127.0.0.1:" <> ToString[port] <> "/sv/mcp",
    "TokenRequired" -> (StringQ[tok] && tok =!= ""),
    "Service" -> svc, "Proxy" -> prox|>];

Options[SourceVaultStopMCP] = {"ServiceId" -> Automatic};
SourceVaultStopMCP[OptionsPattern[]] := Module[{sid, p, s},
  sid = iMCPServiceId[OptionValue["ServiceId"]];
  p = Quiet @ Check[SourceVaultStopHTTPProxy[sid], $Failed];
  s = Quiet @ Check[SourceVaultStopService[sid], $Failed];
  <|"Status" -> "Stopped", "ServiceId" -> sid, "Proxy" -> p, "Service" -> s|>];

Options[SourceVaultMCPStatus] = {"ServiceId" -> Automatic};
SourceVaultMCPStatus[OptionsPattern[]] := Module[{sid, svc, prox, port},
  sid = iMCPServiceId[OptionValue["ServiceId"]];
  svc  = Quiet @ Check[SourceVaultServiceStatus[sid], $Failed];
  prox = Quiet @ Check[SourceVaultHTTPProxyStatus[sid], $Failed];
  port = If[AssociationQ[prox], Lookup[prox, "Port", Missing[]], Missing[]];
  <|"ServiceId" -> sid,
    (* "Running" は実到達性 (/health への HTTP 接続成功)。pid 生存とは別の真の状態。 *)
    "Running" -> SourceVaultMCPRunningQ["ServiceId" -> sid],
    "ServiceState" -> If[AssociationQ[svc], Lookup[svc, "State", Missing[]], Missing[]],
    (* ProxyState/ProxyPidAlive は pid ベース (stale/再利用 pid だと Running でも到達不可になり得る) *)
    "ProxyState" -> If[AssociationQ[prox], Lookup[prox, "State", Missing[]], Missing[]],
    "ProxyPidAlive" -> If[AssociationQ[prox], TrueQ[Lookup[prox, "PidAlive", False]], False],
    "Port" -> port,
    "Url" -> If[IntegerQ[port], "http://127.0.0.1:" <> ToString[port] <> "/sv/mcp", Missing[]]|>];

(* claudecode パレットへ package-neutral に登録 (claudecode が無くても安全; soft-probe)。
   ラベル文字列・コールバックは SourceVault 側が供給し、claudecode は SourceVault を一切参照しない。 *)
iRegisterMCPPaletteControl[] := If[
  Length[Names["ClaudeCode`ClaudeRegisterPaletteServiceControl"]] > 0,
  Quiet @ Check[
    ClaudeCode`ClaudeRegisterPaletteServiceControl[<|
      "Id" -> "sourcevault-mcp",
      "RunningQ" -> Function[SourceVault`SourceVaultMCPRunningQ[]],
      "Start"    -> Function[SourceVault`SourceVaultStartMCP[]],
      "Stop"     -> Function[SourceVault`SourceVaultStopMCP[]],
      (* labels as 0-arg functions so they re-evaluate at palette render time and
         follow $Language (a plain iL string would freeze at SourceVault load).
         状態を明示 (実行中/停止中)。クリックで起動/停止をトグルする (動作は claudecode の
         サービストグルが RunningQ を見て Start/Stop を切り替える)。 *)
      "RunningLabel" -> Function[If[$Language === "Japanese",
        "\[FilledCircle] MCP 実行中", "\[FilledCircle] MCP Running"]],
      "StoppedLabel" -> Function[If[$Language === "Japanese",
        "\[EmptyCircle] MCP 停止中", "\[EmptyCircle] MCP Stopped"]],
      "UnknownLabel" -> Function[If[$Language === "Japanese",
        "\[EmptyCircle] MCP (\:4e0d\:660e)", "\[EmptyCircle] MCP (unknown)"]],
      "RunningColor" -> RGBColor[0.2, 0.55, 0.35],
      "StoppedColor" -> RGBColor[0.55, 0.35, 0.3]|>],
    $Failed],
  Missing["NoClaudeCode"]];
iRegisterMCPPaletteControl[];

(* ============================================================
   headless claude CLI への MCP 配線 (2026-07-04)
   claudecode の queryProvider / ClaudeQueryBg (--print モード) は対話承認
   できないため、MCP サーバは --mcp-config + --allowedTools の明示指定でのみ
   使える。ここで SourceVault MCP を claudecode の CLI MCP レジストリへ
   自己登録する (claudecode は SourceVault を一切参照しない; palette control
   と同じ package-neutral 方針)。
   - ConfigFn: MCP が実到達 (SourceVaultMCPRunningQ) のときだけ proxy の /sv/mcp
     URL と (token があれば) 認証ヘッダを返す。停止中は None → CLI は MCP なし。
   - AllowedTools: read-only な情報取得 tool を pre-allow (--print は承認不可)。
     deposit/workflow_write 等の書き込み系は載せない。
   - PromptDirective: 「本システムに関する情報はまず MCP 経由で解決し、
     見つからなければ次の方策へ」という解決順序方針を prompt に注入する。
   ============================================================ *)
iRegisterSourceVaultCLIMCP[] := If[
  Length[Names["ClaudeCode`ClaudeRegisterCLIMCPServer"]] > 0,
  Quiet @ Check[
    ClaudeCode`ClaudeRegisterCLIMCPServer["sourcevault", <|
      "ConfigFn" -> Function[
        Module[{running, st, port, tok},
          running = TrueQ[Quiet @ Check[SourceVault`SourceVaultMCPRunningQ[], False]];
          If[! running, Return[None, Module]];
          st = Quiet @ Check[SourceVault`SourceVaultMCPStatus[], $Failed];
          port = If[AssociationQ[st], Lookup[st, "Port", Missing[]], Missing[]];
          If[! IntegerQ[port], Return[None, Module]];
          tok = Quiet @ Check[iMCPResolveToken[Automatic, iMCPServiceId[Automatic]], None];
          <|"Url" -> "http://127.0.0.1:" <> ToString[port] <> "/sv/mcp",
            "Headers" -> If[StringQ[tok] && tok =!= "",
              <|"X-SourceVault-Token" -> tok|>, <||>]|>]],
      (* read-only 情報取得 tool のみ pre-allow (書き込み/deposit は除外) *)
      "AllowedTools" -> {
        "sourcevault_catalog", "sourcevault_search", "sourcevault_get",
        "sourcevault_commit_log", "sourcevault_directives",
        "sourcevault_fs_list", "sourcevault_fs_read",
        "sourcevault_web_search",
        "sourcevault_oops_status", "sourcevault_oops_search_threads",
        "sourcevault_oops_thread",
        "sourcevault_mail_status", "sourcevault_mail_search_threads",
        "sourcevault_mail_thread"},
      "PromptDirective" -> Function[
        If[$Language === "Japanese",
          "本システム (SourceVault / claudecode / github / NBAccess 等の\n" <>
          "パッケージ群、およびそのデータ・履歴・ドキュメント) に関する情報は、\n" <>
          "まず SourceVault MCP tool (mcp__sourcevault__*) 経由で解決を図ること。\n" <>
          "MCP はプライバシーレベルを考慮して安全に情報を返し、$packageDirectory へ\n" <>
          "直接アクセスできない環境でも利用できる。解決順序:\n" <>
          "  1. mcp__sourcevault__sourcevault_catalog で利用可能なデータ源を把握。\n" <>
          "  2. コミット履歴・更新履歴・changelog の質問 → sourcevault_commit_log\n" <>
          "     (git を自分で実行しない。ミラーは .git を持たない)。\n" <>
          "  3. パッケージ API / ドキュメント / ディレクティブ → sourcevault_directives\n" <>
          "     / sourcevault_fs_read、横断検索 → sourcevault_search / sourcevault_get。\n" <>
          "  4. MCP で見つからない場合に限り、次の方策 (Read/Glob 等のファイルアクセス\n" <>
          "     や一般知識) に切り替える。",
          "For information about THIS SYSTEM (the SourceVault / claudecode / github /\n" <>
          "NBAccess packages and their data, history and documentation), FIRST try to\n" <>
          "resolve it through the SourceVault MCP tools (mcp__sourcevault__*). MCP\n" <>
          "returns information with privacy levels enforced and works even where\n" <>
          "$packageDirectory is not directly accessible. Resolution order:\n" <>
          "  1. mcp__sourcevault__sourcevault_catalog to discover available data.\n" <>
          "  2. commit history / update history / changelog questions -> sourcevault_commit_log\n" <>
          "     (do NOT run git yourself; the mirror has no .git).\n" <>
          "  3. package APIs / docs / directives -> sourcevault_directives / sourcevault_fs_read,\n" <>
          "     cross-cutting search -> sourcevault_search / sourcevault_get.\n" <>
          "  4. ONLY if MCP does not have it, fall back to the next method (file access\n" <>
          "     via Read/Glob, or general knowledge)."]]|>],
    Null],
  Missing["NoClaudeCode"]];
iRegisterSourceVaultCLIMCP[];

(* ============================================================
   §9.8 channel pipeline / §13 Phase 6 mail・Discord / §17.9 OutputGate
   mail は draft のみ (自動送信しない)、Discord は承認必須。
   gate 済み SourceVaultSearch を使い、LLM は呼ばない (evidence ベース)。
   ============================================================ *)

SourceVault`ServiceManagerPrivate`iChannels = {"Web", "Mail", "Discord", "Voice", "VRSNS"};

Options[SourceVaultMakeQuestionEnvelope] = {
  "ReleaseContext" -> None, "Audience" -> Missing["Anonymous"], "LatencyProfile" -> Automatic,
  "AllowedIndexes" -> {}, "PDFIndexProfile" -> None, "Requester" -> Missing["Anonymous"]};
SourceVaultMakeQuestionEnvelope[channel_String, inputText_String, OptionsPattern[]] := Module[{rc, lat},
  rc = OptionValue["ReleaseContext"];
  If[! StringQ[rc],
    Return[Failure["ReleaseContextRequired", <|
      "MessageTemplate" -> "QuestionEnvelope には \"ReleaseContext\" が必須です。"|>]]];
  lat = OptionValue["LatencyProfile"] /. Automatic -> Switch[channel,
    "Web", "RealtimeWeb", "Mail", "MailReplyDraft", "Discord", "ChatReply",
    "Voice", "VoiceUltraLowLatency", "VRSNS", "VRSNSRealtime", _, "RealtimeWeb"];
  <|"EnvelopeId" -> "env:" <> CreateUUID[], "InterfaceVersion" -> "QuestionEnvelope/1",
    "Channel" -> channel, "InputText" -> inputText,
    "Requester" -> OptionValue["Requester"], "Audience" -> OptionValue["Audience"],
    "ReleaseContextRef" -> rc, "LatencyProfile" -> lat,
    "AllowedIndexes" -> OptionValue["AllowedIndexes"],
    "PDFIndexProfile" -> OptionValue["PDFIndexProfile"],
    "CreatedAtUTC" -> iSMUTCNow[]|>];

(* evidence draft 化。Mail は draft のみ。 *)
Options[SourceVaultAnswerChannelQuery] = {"Limit" -> 10};
SourceVaultAnswerChannelQuery[envelope_Association, OptionsPattern[]] := Module[
  {rc, channel, query, idx, profile, results, citations, decision, draftText, n},
  rc = Lookup[envelope, "ReleaseContextRef"];
  channel = Lookup[envelope, "Channel", "Web"];
  query = Lookup[envelope, "InputText", ""];
  If[! StringQ[rc], Return[Failure["BadEnvelope", <|"Reason" -> "NoReleaseContext"|>]]];
  idx = FirstCase[Lookup[envelope, "AllowedIndexes", {}], _String, None];
  profile = Lookup[envelope, "PDFIndexProfile", None];
  results = Which[
    StringQ[idx], SourceVault`SourceVaultSearch[query, "ReleaseContext" -> rc, "Index" -> idx, "Limit" -> OptionValue["Limit"]],
    StringQ[profile], SourceVault`SourceVaultSearch[query, "ReleaseContext" -> rc, "PDFIndexProfile" -> profile, "Limit" -> OptionValue["Limit"]],
    True, Failure["NoSearchTarget", <|"MessageTemplate" -> "AllowedIndexes か PDFIndexProfile が必要です。"|>]];
  If[FailureQ[results], Return[results]];
  n = Length[results];
  citations = Lookup[#, "Citation", <||>] & /@ results;
  (* evidence ベースの draft (LLM 無し)。本文生成は latency profile に応じ後続で LLM 化可能。 *)
  draftText = If[n === 0,
    "該当する情報が見つかりませんでした。",
    "関連する情報が " <> ToString[n] <> " 件見つかりました。根拠: " <>
      StringRiffle[Lookup[#, "Title", "?"] & /@ citations, ", "]];
  decision = Switch[channel,
    "Mail", "NeedsHumanReview",            (* mail は必ず draft *)
    "Discord", If[n > 0, "Answered", "NoAnswer"],
    _, If[n > 0, "Answered", "NoAnswer"]];
  <|"Decision" -> decision, "Channel" -> channel, "ReleaseContextRef" -> rc,
    "AnswerDraft" -> <|"Text" -> draftText, "RequiresHumanReview" -> (channel === "Mail"),
      "Generator" -> "EvidenceTemplate", "LLMUsed" -> False|>,
    "Evidence" -> results, "Citations" -> citations, "ResultCount" -> n,
    "EnvelopeId" -> Lookup[envelope, "EnvelopeId"]|>];

SourceVaultMakeMailReplyDraft[envelope_Association, opts___] := Module[{env, res},
  env = Append[envelope, "Channel" -> "Mail"];
  res = SourceVaultAnswerChannelQuery[env, opts];
  If[FailureQ[res], Return[res]];
  Append[res, "AutoSend" -> False]];

(* §17.9 OutputGate *)
Options[SourceVaultEvaluateOutputGate] = {"EventKind" -> "ResponseDraft", "HasRawMedia" -> False};
SourceVaultEvaluateOutputGate[draft_Association, adapterName_String, OptionsPattern[]] := Module[
  {adapter, why = {}, decision, pl, rcs, reqRC, privMax, allowedKinds, eventKind, rawMedia},
  adapter = iSMResolve["OutputAdapter", adapterName];
  If[FailureQ[adapter], Return[adapter]];
  eventKind = OptionValue["EventKind"];
  rawMedia = TrueQ[OptionValue["HasRawMedia"]];
  pl = Lookup[draft, "PrivacyLevel", 0.];
  rcs = Lookup[draft, "ReleaseContexts", {Lookup[draft, "ReleaseContextRef", Nothing]}];
  reqRC = Lookup[adapter, "ReleaseContextRequired", {}];
  privMax = Lookup[adapter, "PrivacyMax", 0.5];
  allowedKinds = Lookup[adapter, "AllowedEventKinds", All];
  (* event kind allowlist *)
  If[allowedKinds =!= All && ! MemberQ[allowedKinds, eventKind],
    AppendTo[why, "EventKindNotAllowed(" <> eventKind <> ")"]];
  (* privacy *)
  If[! (NumericQ[pl] && pl <= privMax), AppendTo[why, "PrivacyExceedsMax"]];
  (* release context required ⊆ draft contexts *)
  If[! SubsetQ[rcs, reqRC], AppendTo[why, "MissingRequiredReleaseContext"]];
  (* raw media: 既定で外部送信禁止 (§17.9)。AllowRawVisualExport が無い限り redact *)
  decision = Which[
    why =!= {}, "Deny",
    rawMedia && ! TrueQ[Lookup[adapter, "AllowRawVisualExport", False]], "RedactRequired",
    TrueQ[Lookup[adapter, "RequireApproval", False]], "NeedsApproval",
    True, "Permit"];
  <|"Decision" -> decision, "Why" -> why, "Adapter" -> adapterName, "EventKind" -> eventKind|>];

Options[SourceVaultDispatchOutput] = {"Approved" -> False, "ReallySend" -> False,
  "EventKind" -> "ResponseDraft", "HasRawMedia" -> False};
SourceVaultDispatchOutput[draft_Association, adapterName_String, OptionsPattern[]] := Module[
  {adapter, gate, kind, approved, reallySend, webhookRef, sendRes},
  adapter = iSMResolve["OutputAdapter", adapterName];
  If[FailureQ[adapter], Return[adapter]];
  gate = SourceVaultEvaluateOutputGate[draft, adapterName,
    "EventKind" -> OptionValue["EventKind"], "HasRawMedia" -> OptionValue["HasRawMedia"]];
  kind = Lookup[adapter, "Kind", ""];
  approved = TrueQ[OptionValue["Approved"]];
  reallySend = TrueQ[OptionValue["ReallySend"]];
  Which[
    Lookup[gate, "Decision"] === "Deny",
      <|"Status" -> "Denied", "Sent" -> False, "Gate" -> gate|>,
    Lookup[gate, "Decision"] === "RedactRequired",
      <|"Status" -> "RedactRequired", "Sent" -> False, "Gate" -> gate|>,
    (* mail は OutputAdapter であっても自動送信しない (§13 Phase 6) *)
    kind === "Mail" || kind === "MailDraft",
      <|"Status" -> "DraftOnly", "Sent" -> False, "Draft" -> draft, "Gate" -> gate|>,
    Lookup[gate, "Decision"] === "NeedsApproval" && ! approved,
      <|"Status" -> "NeedsApproval", "Sent" -> False, "Gate" -> gate|>,
    (* Permit (または承認済み) かつ明示 ReallySend のときだけ実送信 *)
    (Lookup[gate, "Decision"] === "Permit" || approved) && reallySend &&
        kind === "DiscordWebhook",
      webhookRef = Lookup[adapter, "WebhookURL", Lookup[adapter, "WebhookRef", None]];
      If[! (StringQ[webhookRef] && StringStartsQ[webhookRef, "http"]),
        <|"Status" -> "NoWebhookURL", "Sent" -> False, "Gate" -> gate|>,
        sendRes = Quiet @ URLRead[HTTPRequest[webhookRef, <|"Method" -> "POST",
          "Body" -> ExportString[<|"content" -> Lookup[draft, "Text",
            Lookup[Lookup[draft, "AnswerDraft", <||>], "Text", ""]]|>, "RawJSON"],
          "ContentType" -> "application/json"|>], TimeoutConstraint -> 8];
        <|"Status" -> If[Head[sendRes] === HTTPResponse && sendRes["StatusCode"] < 300, "Sent", "SendFailed"],
          "Sent" -> (Head[sendRes] === HTTPResponse && sendRes["StatusCode"] < 300), "Gate" -> gate|>],
    True,
      <|"Status" -> "Prepared", "Sent" -> False, "Gate" -> gate|>]];

(* ============================================================
   §9.9 ActionDraft / ActionGate (VRSNS avatar・world action 安全制御)
   §17.3 CaptureSource 補助 (device 非依存。実体解決は private local init)
   ============================================================ *)

$worldMutatingActions = {"Move", "CallTool", "WorldControl"};

Options[SourceVaultMakeActionDraft] = {
  "CapabilityProfile" -> None, "Audience" -> Missing["Anonymous"], "ReleaseContext" -> None,
  "Target" -> <||>, "EvidenceRefs" -> {}};
SourceVaultMakeActionDraft[kind_String, payload_, OptionsPattern[]] :=
  <|"ActionId" -> "act:" <> CreateUUID[], "Kind" -> kind, "Payload" -> payload,
    "Target" -> OptionValue["Target"], "Audience" -> OptionValue["Audience"],
    "ReleaseContextRef" -> OptionValue["ReleaseContext"],
    "CapabilityProfileRef" -> OptionValue["CapabilityProfile"],
    "EvidenceRefs" -> OptionValue["EvidenceRefs"],
    "RequiresApproval" -> MemberQ[$worldMutatingActions, kind],
    "CreatedAtUTC" -> iSMUTCNow[]|>;

SourceVaultEvaluateActionGate[actionDraft_Association, opts___] := Module[
  {kind, capName, cap, allowed, why = {}, decision, worldMut, requireGate},
  kind = Lookup[actionDraft, "Kind", ""];
  capName = Lookup[actionDraft, "CapabilityProfileRef", None];
  If[! StringQ[capName],
    Return[<|"Decision" -> "Deny", "Why" -> {"NoCapabilityProfile"}, "ActionId" -> Lookup[actionDraft, "ActionId"]|>]];
  cap = iSMResolve["CapabilityProfile", capName];
  If[FailureQ[cap], Return[cap]];
  allowed = Lookup[cap, "AllowedActions", {}];
  worldMut = MemberQ[$worldMutatingActions, kind];
  requireGate = TrueQ[Lookup[cap, "RequireActionGate", True]];
  If[! MemberQ[allowed, kind], AppendTo[why, "ActionNotAllowed(" <> kind <> ")"]];
  If[worldMut && ! TrueQ[Lookup[cap, "AllowWorldControl", False]],
    AppendTo[why, "WorldControlNotAllowed"]];
  decision = Which[
    why =!= {}, "Deny",
    (* Speak は他者に聞こえるが capability 上許可なら Permit。world 変更や ShowPanel/CallTool は承認 *)
    worldMut || (requireGate && kind =!= "Speak"), "RequiresApproval",
    True, "Permit"];
  <|"Decision" -> decision, "Why" -> why, "Kind" -> kind,
    "ActionId" -> Lookup[actionDraft, "ActionId"], "CapabilityProfileRef" -> capName|>];

SourceVaultListCaptureSources[opts___] := SourceVaultListServiceProfiles["CaptureSource"];
SourceVaultTestCaptureSource[name_String, opts___] := Module[{spec},
  spec = iSMResolve["CaptureSource", name];
  If[FailureQ[spec], Return[spec]];
  (* 実 capture はせず、profile の必須項目と device ref が symbolic か (実 device 名を直書きしていないか) を点検 *)
  <|"Status" -> "OK", "Name" -> name, "Kind" -> Lookup[spec, "Kind", Missing[]],
    "HasSymbolicDeviceRef" -> (StringQ[Lookup[spec, "DeviceRef", Lookup[spec, "WindowRef", ""]]]),
    "Note" -> "実 capture はしない。device 実体は private local init で解決。"|>];

(* ============================================================
   §17 マルチモーダル ingest / live session / workflow / postprocess
   capture driver (ffmpeg/ASR/realtime) はこれらを呼ぶ薄い層。device 非依存。
   ============================================================ *)

If[! AssociationQ[$multimodalWorkflows], $multimodalWorkflows = <||>];
(* PresentationListenerCompat を既定登録 (§17.6) *)
$multimodalWorkflows["PresentationListenerCompat-v1"] = <|
  "Input" -> <|"Audio" -> "SegmentedWhisper", "Visual" -> "PeriodicFrameWithChangeDetection"|>,
  "TranscriptPostprocess" -> "ASRCorrection",
  "Output" -> {"SourceVaultEvent", "NotebookSummary"}, "LatencyProfile" -> "PresentationSummary"|>;

Options[SourceVaultIngestCapturedMedia] = {
  "PersistRaw" -> True, "SourceRef" -> None, "Tags" -> {}, "State" -> "Captured",
  "PrivacyLevel" -> Automatic};
SourceVaultIngestCapturedMedia[sessionId_String, kind_String, data_, OptionsPattern[]] := Module[
  {ev, blobRes, pl},
  pl = OptionValue["PrivacyLevel"] /. Automatic -> SourceVault`SourceVaultMediaPrivacyDefault[kind];
  ev = <|"SessionID" -> sessionId, "Kind" -> kind, "PrivacyLevel" -> pl,
    "Tags" -> OptionValue["Tags"], "State" -> OptionValue["State"],
    "SourceRef" -> OptionValue["SourceRef"]|>;
  Which[
    ByteArrayQ[data],
      If[TrueQ[OptionValue["PersistRaw"]],
        blobRes = SourceVault`SourceVaultCommitBlob[data,
          "Meta" -> <|"SessionID" -> sessionId, "Kind" -> kind|>];
        If[FailureQ[blobRes], Return[blobRes]];
        ev = Join[ev, <|"BlobRef" -> Lookup[blobRes, "BlobRef"], "MediaHash" -> Lookup[blobRes, "Hash"]|>],
        ev = Join[ev, <|"BlobRef" -> Missing["NotPersisted"]|>]],
    StringQ[data], ev = Join[ev, <|"Text" -> data|>],
    True, Return[Failure["UnsupportedMediaData", <|"Kind" -> kind|>]]];
  SourceVault`SourceVaultAppendMultimodalEvent[ev]];

iLiveSummaryPointer[sessionId_String] := "live-summary-" <> iSafeName[sessionId];

SourceVaultUpdateLiveSummary[sessionId_String, summary_String, opts___] := Module[{p},
  p = SourceVault`SourceVaultAtomicUpdatePointer[iLiveSummaryPointer[sessionId],
    <|"Summary" -> summary, "UpdatedAtUTC" -> iSMUTCNow[]|>];
  If[FailureQ[p], Return[p]];
  SourceVault`SourceVaultAppendMultimodalEvent[<|"SessionID" -> sessionId,
    "Kind" -> "SystemSummary", "Text" -> summary|>];
  <|"Status" -> "OK", "SessionID" -> sessionId, "Sequence" -> Lookup[p, "Sequence"]|>];

SourceVaultGetLiveSummary[sessionId_String, opts___] := Module[{r},
  r = SourceVault`SourceVaultPointerReplay[iLiveSummaryPointer[sessionId]];
  If[Lookup[r, "Status"] === "Empty", <|"SessionID" -> sessionId, "Summary" -> Missing["NoSummary"]|>,
    <|"SessionID" -> sessionId, "Summary" -> Lookup[Lookup[r, "Value", <||>], "Summary"],
      "Sequence" -> Lookup[r, "Sequence"]|>]];

SourceVaultGetLiveEvents[sessionId_String, opts___] := SourceVault`SourceVaultSessionEvents[sessionId, opts];
SourceVaultGetLiveTranscript[sessionId_String, opts___] := Module[{evs},
  evs = SourceVault`SourceVaultSessionEvents[sessionId, "Kind" -> "ASRTranscript"];
  StringRiffle[Lookup[#, "Text", ""] & /@ evs, " "]];

Options[SourceVaultAskLiveSession] = {"ReplyTarget" -> "MainKernelQueue", "UseRecentSeconds" -> 600};
SourceVaultAskLiveSession[sessionId_String, question_String, OptionsPattern[]] := Module[{q, cmd},
  (* メインカーネルは LLM を呼ばない。UserQuestion を記録し command を enqueue する。 *)
  SourceVault`SourceVaultAppendMultimodalEvent[<|"SessionID" -> sessionId,
    "Kind" -> "UserQuestion", "Text" -> question|>];
  cmd = SourceVault`SourceVaultAppendEvent[<|"EventClass" -> "SessionCommand",
    "Type" -> "AskSessionQuestion", "SessionID" -> sessionId, "Question" -> question,
    "ReplyTarget" -> OptionValue["ReplyTarget"], "UseRecentSeconds" -> OptionValue["UseRecentSeconds"]|>];
  <|"Status" -> "Queued", "SessionID" -> sessionId, "CommandRef" -> Lookup[cmd, "Ref"]|>];

SourceVaultRegisterMultimodalWorkflow[name_String, spec_Association, opts___] :=
  ($multimodalWorkflows[name] = spec; <|"Status" -> "OK", "Name" -> name|>);
SourceVaultListMultimodalWorkflows[opts___] := Keys[$multimodalWorkflows];

SourceVaultSchedulePostprocess[sessionId_String, spec_Association, opts___] :=
  SourceVault`SourceVaultAppendEvent[Join[<|"EventClass" -> "PostprocessScheduled",
    "SessionID" -> sessionId, "Priority" -> "Batch"|>, spec]];

(* ============================================================
   §10.1 Latency baseline snapshot / §10.2 deadline-driven cascade
   deadlineMs は固定断定値でなく実測 baseline から導く budget hint。
   ============================================================ *)

iLatUTCNow[] := DateString[
  {"Year", "-", "Month", "-", "Day", "T", "Hour", ":", "Minute", ":", "Second", "Z"}, TimeZone -> 0];
(* 個人情報を含めない host fingerprint (非識別の system 値を hash) *)
iHostFingerprint[] := "hostfp:" <> StringTake[
  ToLowerCase @ Hash[{$SystemID, $ProcessorCount, $OperatingSystem}, "SHA256", "HexString"], 16];

(* probe 値は (a) 事前計測 ms のリスト or (b) 0引数関数。後者は Repeats 回 time する。 *)
iLatSamples[probe_, reps_Integer] := Which[
  ListQ[probe] && AllTrue[probe, NumericQ], N[probe],
  True, Table[Module[{t0 = AbsoluteTime[]}, probe[]; (AbsoluteTime[] - t0)*1000.], reps]];
iLatP[samples_, q_] := If[samples === {} || ! ListQ[samples], Missing["NotMeasured"],
  Round[Quantile[N[samples], q]]];

Options[SourceVault`SourceVaultMeasureServiceLatency] = {"Probes" -> <||>, "Repeats" -> 7};
SourceVault`SourceVaultMeasureServiceLatency[serviceId_String, OptionsPattern[]] := Module[
  {probes, reps, status, meas = <||>, raw = <||>},
  probes = OptionValue["Probes"]; reps = OptionValue["Repeats"];
  If[! AssociationQ[probes], probes = <||>];
  (* 既定 IPC probe: service 稼働時のみ実 Ping 往復を計測 *)
  If[! KeyExistsQ[probes, "IPC"],
    status = SourceVaultServiceStatus[serviceId];
    If[AssociationQ[status] && Lookup[status, "State"] === "Running" && TrueQ[Lookup[status, "PidAlive"]],
      probes = Append[probes, "IPC" -> Function[Module[{c = SourceVaultSendServiceCommand[serviceId, <|"Command" -> "Ping"|>], dl},
        dl = AbsoluteTime[] + 5;
        While[Lookup[SourceVaultServiceCommandResult[serviceId, Lookup[c, "CommandId"]], "Status"] =!= "Done" && AbsoluteTime[] < dl, Pause[0.02]]]]]]];
  KeyValueMap[Function[{name, probe}, Module[{s = iLatSamples[probe, reps]},
    raw[name] = s;
    meas[name <> ".P50Ms"] = iLatP[s, 0.5];
    meas[name <> ".P95Ms"] = iLatP[s, 0.95]]], probes];
  <|"Status" -> "OK", "ServiceId" -> serviceId, "Measurements" -> meas, "RawSamples" -> raw,
    "HostFingerprint" -> iHostFingerprint[]|>];

(* 実測 P95 から budget hint を導く。fast path = IPC+TPOGate+HotFAQ。 *)
SourceVault`SourceVaultLatencyBaselineReport[serviceId_String, measurements_Association, opts___] := Module[
  {g, num, ipc, tpo, faq, vec, llm, fast, vecB, llmB},
  g[k_] := Lookup[measurements, k <> ".P95Ms", Missing["NotMeasured"]];
  num[x_, d_] := If[NumericQ[x], x, d];
  ipc = g["IPC"]; tpo = g["TPOGate"]; faq = g["HotFAQ"]; vec = g["Vector"]; llm = g["LLM"];
  fast = num[ipc, 0] + num[tpo, 0] + num[faq, 0];
  vecB = fast + num[vec, 0];
  llmB = vecB + num[llm, 0];
  <|"SnapshotKind" -> "LatencyBaselineSnapshot", "ServiceId" -> serviceId,
    "HostFingerprint" -> iHostFingerprint[],
    "Measurements" -> measurements,
    "RecommendedBudgets" -> <|
      "FastPathDeadlineMs" -> Ceiling[fast],
      "AllowVectorBeforeMs" -> Ceiling[vecB],
      "AllowLLMBeforeMs" -> Ceiling[llmB]|>,
    "VectorMeasured" -> NumericQ[vec], "LLMMeasured" -> NumericQ[llm],
    "CreatedAtUTC" -> iLatUTCNow[]|>];

iLatBaselinePointer[serviceId_] := "latency-baseline-" <> iSafeName[serviceId];
SourceVault`SourceVaultSaveLatencyBaselineSnapshot[serviceId_String, report_Association, opts___] := Module[{rec, saved},
  rec = Join[<|"ObjectClass" -> "SourceVaultLatencyBaselineSnapshot"|>, report];
  saved = SourceVault`SourceVaultSaveImmutableSnapshot["SourceVaultLatencyBaselineSnapshot", rec,
    "Alias" -> "svlatency:" <> serviceId];
  If[FailureQ[saved], Return[saved]];
  SourceVault`SourceVaultAtomicUpdatePointer[iLatBaselinePointer[serviceId], Lookup[saved, "Ref"]];
  <|"Status" -> "OK", "ObjectRef" -> Lookup[saved, "Ref"], "Digest" -> Lookup[saved, "Digest"],
    "RecommendedBudgets" -> Lookup[report, "RecommendedBudgets"]|>];
SourceVault`SourceVaultLatencyBaseline[serviceId_String, opts___] := Module[{ptr},
  ptr = SourceVault`SourceVaultPointerReplay[iLatBaselinePointer[serviceId]];
  If[AssociationQ[ptr] && StringQ[Lookup[ptr, "Value"]],
    SourceVault`SourceVaultLoadImmutableSnapshot[Lookup[ptr, "Value"]],
    Failure["NoLatencyBaseline", <|"ServiceId" -> serviceId|>]]];

(* §10.2: 残り budget からどの段階まで許可するか。baseline 無しは HotFAQ/fallback に制限。 *)
SourceVault`SourceVaultDeadlineDecision[remainingMs_?NumericQ, budgets_Association, opts___] := Module[{fp, av, al},
  fp = Lookup[budgets, "FastPathDeadlineMs", 0];
  av = Lookup[budgets, "AllowVectorBeforeMs", Infinity];
  al = Lookup[budgets, "AllowLLMBeforeMs", Infinity];
  Which[
    remainingMs < fp, <|"Allowed" -> "SafeFallback", "SkippedByDeadline" -> {"HotFAQ", "Vector", "LLM"}|>,
    remainingMs < av, <|"Allowed" -> "HotFAQ", "SkippedByDeadline" -> {"Vector", "LLM"}|>,
    remainingMs < al, <|"Allowed" -> "Vector", "SkippedByDeadline" -> {"LLM"}|>,
    True, <|"Allowed" -> "LLM", "SkippedByDeadline" -> {}|>]];

End[]  (* `ServiceManagerPrivate` *)

EndPackage[]  (* SourceVault` *)
(* ロード時ヘルプは削除。API 一覧は SourceVault_info/docs を参照。 *)
