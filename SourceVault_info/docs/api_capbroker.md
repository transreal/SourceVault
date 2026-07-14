# SourceVault_capbroker.wl API

Cane Phase 1H-S: capability broker(CapabilityLease atomic ledger + PreparedInputToken)。
spec v0.7 §4.21/4.21b/4.22/4.22b、Phase 0 decision D-5(層合成: 上流 Grant/ActionGate の decision を
ParentDecisionRef で参照し、broker は authorization を再実装せず **atomic consume + dispatch のみ**担う)。

不変条件(I-14): ledger が正準(token 内 RemainingUses を判定に使わない)。consume は WithLock 下の
read-modify-write で原子的、同一 LeaseId の replay 拒否。consume と dispatch の TOCTOU は one-time
ExecutionTicket(consume と同一 transaction で発行、実行直前に one-shot redeem)で排除、crash 後は
ticket 短 TTL 失効で再実行しない。mint は内部関数のみ、IssuerRef は broker 付与。token/MAC は
prompt/ログに出さない。ledger 物理は `<LocalState>/capbroker/`(機械ローカル・非同期)、鍵は NBAccess MAC KeyRef。
罠: LeaseId のコロンは Windows で NTFS ADS を作るためファイル名だけ sanitize(正準 ID は不変)。

### SourceVaultCapBrokerInitialize[opts]
ledger dir + MAC 鍵を初期化(冪等)。Options: "Root"(Automatic)。

### SourceVaultRequestCapabilityLease[request]
lease 申請(mint は内部)。必須: RunRef/ActorRef/CapabilityKind(read|write|network|secret|send|
publish|delete の1つ)/AllowedOperation/TargetScope/Purpose/**ParentDecisionRef**。任意: TTLSeconds(120)、
MaxUses(1=one-shot)、MaxPrivacyLevel、DenyTags。→ MAC 付き lease token。

### SourceVaultVerifyCapabilityLease[token, action] / SourceVaultConsumeCapabilityLease[token, action]
verify: MAC・ledger 状態(issued)・期限(broker 時刻)・action bind(CapabilityKind/Operation/Target が
TargetScope パターンに一致)を検査(consume しない)。consume: 原子的に consume し ExecutionTicket 発行。
→ `<|Status, ExecutionTicket|>`。二重 consume は Failure。

### SourceVaultRedeemExecutionTicket[ticket]
実行直前の one-shot redeem。二重 redeem・期限切れは Failure(indeterminate 非再実行)。

### SourceVaultRevokeCapabilityLeases[runRef|All]
run の未消費 lease を一括失効(containment)。→ `<|Revoked|>`。

### SourceVaultCapabilityLeaseLedger[leaseId]
ledger record(state/UsesConsumed 等。鍵材料なし)。

### SourceVaultPrepareLLMInput[envelope, opts] / SourceVaultVerifyPreparedRequest[token, envelope]
prepare: request envelope 全体(Provider/Model/Deployment/Messages/ToolSchemas/RetrievalRefs/
IsolationProfile/PrivacyDecisionRef/CapabilityCeiling/OutputSchema/RunRef/StepRef)の canonical digest に
bind した one-shot token 発行。verify: 送信直前に digest 再計算照合(prepare 後の model/messages/tool
schema/endpoint 差し替えを拒否)+MAC/期限検証+one-shot consume(replay 拒否)。Options: "TTLSeconds"(300)。

## LLM boundary shadow(1H-S 移行第一段=observe-only。2026-07-14)

PrepareLLMInput 全入口移行(shadow → warn → enforce)の shadow 段。SourceVault 内の全 LLM 送信境界
(直接 HTTP=LM Studio/Anthropic/embeddings、claudecode 委譲=ClaudeQueryBg/ClaudeQuerySync/Codex、
注入シーム)計 18 箇所に観測フックが挿入済み。**enforce しない**: フックは決して送信をブロックせず、
Failure も返さない。event は内容最小化(prompt 本文・token/MAC を記録しない。digest/provider/model/
文字数のみ)。

### $SourceVaultLLMBoundaryShadow
トグル。**既定 False(opt-in)**。off 時は各境界で TrueQ 1 回のみ=ゼロコスト。True で
`LLMBoundaryShadowRecorded` event を記録(SourceVaultAppendEvent 経由、PrivateVault の event store)。

### SourceVaultRegisterLLMEntrypoint[descriptor] / SourceVaultLLMEntrypointInventory[]
LLM 入口 inventory。必須: EntrypointId。任意: Package/Function/Kind(HTTP|Delegate|Seam|Embedding)/
Description。冪等(同 Id は上書き)。正準 inventory は broker が静的登録(`$svLLMEntrypointStaticInventory`
18 entrypoint: webingest 2 / servicemanager 3 / mining 2 / maildb 1 / eagle 3 / workflowcatalog 2 /
searchindex 1 / sourcevault 本体 1 / llmlog 1 / wiring 1 / promptrouter 1)。新しい LLM 入口を作る際は
このテーブルに追記し、送信直前に SourceVaultLLMBoundaryShadowCheck を挿す。

### SourceVaultLLMBoundaryShadowCheck[entrypointId, envelope] / [entrypointId, envelope, token]
送信直前の shadow チェック。token 無し=Status "NoToken"、有り=**非消費** verify(digest/MAC/期限/ledger
照合。ledger を書かないので再 verify 可。one-shot consume は enforce 用 SourceVaultVerifyPreparedRequest
が担う)。戻り値 `<|Status, EntrypointId, HasToken, Registered, ShadowMode->True|>`。トグル off 時は即
`<|Status->"Disabled"|>`。未登録 entrypoint は Registered->False で記録(coverage gap 検出)。

### SourceVaultLLMBoundaryShadowStats[opts]
`LLMBoundaryShadowRecorded` の集計: CallCount/NoTokenCount/VerifiedCount/MismatchCount/
TokenCoverageRate/ByEntrypoint(Status tally)/UnregisteredSeen/RegisteredEntrypoints。
warn/enforce 昇格判断の材料(§8)。Options: "Limit"(2000)。
