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
