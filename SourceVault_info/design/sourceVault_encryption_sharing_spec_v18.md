# ClawCode 比較再評価と SourceVault 暗号化・共有・保管先連動保護・MailDB 連携・基礎ポリシー完全性 実装仕様 v18

作成日: 2026-06-04  
対象: NBAccess / ClaudeRuntime / ClaudeOrchestrator / SourceVault / SourceVault PromptRouter / Claude Directives / NotebookExtensions.wl  
前版: `ClawCode_reassessment_SourceVault_encryption_sharing_spec.md`  
本版の位置づけ: v17 を基礎として、送信者認証における Authentication-Results の信頼境界、authserv-id pinning、fetch 時認証確定、required authentication policy、ARC/forwarder/list 対応、GraphAggregatePL の生成・単調性、AddressBook field policy の provisional/re-seal 遷移を補強した実装前修正版

---

## 0. 結論

`ClawCode_comparison_recommendations.md` の大枠は依然として妥当である。ただし、最新コードと仕様を前提にすると、次のように重点を置き直す。

1. **NBAccess / Runtime / Orchestrator の実行境界は改善済みであり、次は ticket / nonce / replay 防止と Doctor 可視化が主課題である。**
2. **SourceVault 暗号化は、単に `Encrypt` を呼ぶだけでは不十分である。認証付き暗号または encrypt-then-MAC、鍵を返さない NBAccess crypto API、canonical 化、bootstrap、migration、record-level policy enforcement を最初から仕様に入れる。**
3. **共有 capsule は機密性だけでなく、送信者認証と改ざん検出を v1 から扱う。少なくとも署名対象を v1 で固定し、可能なら署名も同時実装する。**
4. **NotebookExtensions.wl のセル暗号化実装は「SystemCredential に鍵をハードコードしない」という方向性では参考になるが、`ToExpression@SystemCredential[...]` 型の復元は SourceVault では踏襲しない。鍵オブジェクトは `BinarySerialize` / `BinaryDeserialize` 等で評価なしに直列化する。**
5. **Notebook や SourceVault record の保存は「メモリ上 PL=1.0 の平文を、より低いアクセスレベルの保管先へ移動する操作」として扱う。保存先の `MaxPlaintextPL` を超えるセルは、分離保存ではなく、同一 Notebook 内または sidecar SourceVault record として暗号化・封印してから保存する。**
6. **MailDB は独立 DB ではなく、SourceVault の一時ソース / snapshot source として取り込み、返信生成時には受信者の numeric PL と tag-based policy を照合して、平文送信・公開鍵 capsule 添付・redaction を自動計画する。**
7. **メール取り込みでは SourceVault AddressBook を基礎データとして使い、email address / contact uid / group / domain / spam・direct-mail category / SourceVault user identity を解決して、PL 推定、summary 生成、recipient release profile、検索 select、UI 表示に反映する。**
8. **AddressBook はメール連絡先に限定しない。** IMAP、GitHub、arXiv、blog、PDF、将来の X / Discord などの ingest から人物・著者・アカウント・組織 affiliation を `IdentityObservation` として抽出し、確信度に応じて ContactRecord へ自動追加、既存 contact へ alias / handle / evidence を追加、または `IdentityUncertain` 候補として保留する。

本 Phase を **SV-E3: SourceVault Authenticated Encryption and Interoperable Sharing Phase** と呼ぶ。本書 v18 は SV-E3 の仕様収束版と SV-E4 の保管先連動 Notebook 保護を維持しつつ、MailDB 融合に向けた **SV-E5: Mail Snapshot and Recipient-Bound Release Planning** を、実際の `maildb.wl` のデータモデルと漏洩面に合わせて補強し、さらに **SV-E6: SourceVault AddressBook and Contact-Aware Mail Policy** を追加する版である。v13 では per-record policy loosening の承認ゲートと authenticated policy delta log を追加し、v14 ではその delta log の rollback / truncation 保護を policy head manifest で補強した。v15 では、この基盤の上に AddressBook / Group / DomainPolicy / CategoryPolicy を authenticated record として追加し、MailSnapshot の PL 推定、検索 select、RecipientAccessProfile 生成、MessageReleasePlan、SourceVault_promptrouter のメール UI へ接続する。 v16 ではさらに、AddressBook を **SV-E7: SourceVault Identity Graph and Author Database** として拡張し、メール・web・論文・コード・SNS キャッシュを横断する provenance 付き著者データベースとして扱う。v17 では、この identity graph を PL 推定と release planning に使う際の安全条件として、メール送信者認証(DKIM/SPF/DMARC/ARC)、AddressBook token 鍵 bootstrap、PII の StorageProfile 連動保護、可逆 merge、observation-only 自動登録、lazy reevaluation を追加する。v18 では、Authentication-Results ヘッダ自体の偽装可能性を踏まえ、authserv-id pinning / local DKIM verification / required authentication policy / trusted ARC sealer / fetch-time attestation を導入し、GraphAggregatePL と AddressBook field policy の生成・単調性・re-seal 規則を補強する。

---

## 1. 前版からの修正点

| 前版の記述 | 問題 | v2 以降での修正 |
|---|---|---|
| `CiphertextHash` を改ざん検出・rotation 判定に使う | 非鍵 SHA256 は MAC ではなく、能動的攻撃に無力 | `CiphertextChecksum` は偶発破損検出のみ。完全性は `CiphertextHMAC` / signature / 実測済み AEAD で保証する。 |
| `PlaintextHash -> sha256OfCanonicalPlaintext` | 低エントロピー prompt / memo の辞書照合漏洩 | 既定は keyed HMAC。高 privacy では `PlaintextDigest -> Missing["Suppressed"]` を許す。 |
| `NBResolveCredentialKey -> key` | 鍵材料が SourceVault 側へ出る | 主 API を `NBEncryptWithKeyRef` / `NBDecryptWithKeyRef` / `NBMacWithKeyRef` / `NBSignWithKeyRef` に変更し、鍵を NBAccess 外へ返さない。 |
| `ToExpression` による鍵復元も許容 | credential 汚染時に評価リスク | SourceVault では禁止。Base64 化した `BinarySerialize` / `BinaryDeserialize` 等を使う。 |
| `SourceVaultGenerateUserKeyPair[recipientId]` | 他者の private key を生成してしまう読み方が可能 | 自分用生成は `SourceVaultGenerateSelfKeyPair[]` のみ。他者は公開鍵登録のみ。 |
| capsule `Signature -> Missing["NotImplemented"]` | 共有時の真正性がない | v1 から `Signature` schema と署名対象を固定し、署名検証を import 前提にする。 |
| migration が Doctor だけ | 既存平文 JSONL をどう処理するか不明 | `SourceVaultMigrateToEncrypted[]` を P0 として追加。dry-run 既定、排他ロック、世代ファイル、原子的置換、best-effort secure delete を規定。 |
| PromptRouter status の Notes 依存 | 自由文が stale になる | boolean capability fields を真実源にし、Notes は生成物にする。 |
| `Policy.CloudSendAllowed` を schema に置くだけ | 強制経路に配線しなければ助言的安全機構になる | cloud route 直前の唯一経路で `CloudSendAllowed` / `RequiresLocalDecrypt` / `DeclassifyRequired` を必ず評価する。 |

### 1.1 v2 レビューからの v3 修正

| v2 の残課題 | v3 での修正 |
|---|---|
| WL の GCM / AEAD 対応を前提にし過ぎている | **encrypt-then-MAC を既定 primary** とする。AEAD は `SourceVaultCryptoCapabilityReport[]` で実測して利用可能な場合だけ opt-in / future path とする。 |
| MAC 鍵が at-rest 暗号鍵と兼用され得る | `SourceVault:master:mac:v1` を標準 KeyRef とし、暗号鍵と MAC 鍵を必ず分離する。HKDF 派生を採用する場合も目的別 `info` を固定する。 |
| MAC 対象が ciphertext のみ | `Algorithm` / `IntegrityMode` / `KeyRef` / `PayloadCanonicalization` / `IV` / `Nonce` / `ContentType` などの暗号メタデータを **associated data** として MAC 対象に含める。 |
| capsule 署名対象や公開鍵直列化が WL バージョン依存 | 共有・署名・公開鍵 registry は **canonical JSON UTF-8 + Base64** を標準にする。`BinarySerialize` は local at-rest 用の内部 payload に限定し、共有署名対象には直接使わない。 |
| 公開鍵 record が 1 鍵しか表せない | capsule 側では暗号用 fingerprint と署名用 fingerprint を分離する。v4 では record schema 自体も二鍵化する。 |
| Dropbox / OneDrive 配下の既存平文履歴 | migration はローカル store の将来保護であり、クラウド同期済み履歴の回収を保証しない。Doctor は同期フォルダを検出して警告する。 |

### 1.2 v3 レビューからの v4 修正

v3 レビューでは、仕様は実装可能な水準だが、共有 capsule の成立条件に関わる局所的な不整合が残っていると評価された。v4 では次を修正する。

| v3 の残課題 | v4 での修正 |
|---|---|
| capsule payload の MAC を送信者ローカル固定鍵 `SourceVault:capsule:mac:v1` で計算する設計 | 共有 payload の MAC は **per-capsule の payload key から HKDF 派生**した `payloadMacKey` で検証する。固定 KeyRef は共有 payload には使わない。 |
| §11.3 public key record が公開鍵 1 本のまま | record schema を `EncryptionPublicKey` / `SigningPublicKey` の **二鍵モデル**に更新し、`SourceVaultGenerateSelfKeyPair[]` は暗号用 keypair と署名用 keypair の 2 組を生成する。 |
| at-rest record の `Canonicalization` が payload 用 Internal と AAD 用 JSON を混同 | `PayloadCanonicalization` と `AuthenticatedBytesCanonicalization` を分離し、`PayloadSerializationFormat` を record に残す。 |
| 署名方式が未確定 | 既定を `RSA-PSS-SHA256` とし、利用可否を `SourceVaultCryptoCapabilityReport[]` に含める。未対応環境では capsule 署名を実装済み扱いにしない。 |
| `SourceVaultAssertNoPlaintextLeak` の定義不足 | JSONL / registry / log の serialized bytes に raw prompt / sensitive field / canonical plaintext bytes が部分一致しないことを検査する防御的テストとして定義する。 |
| v2 ラベル・§6.4 参照切れ・旧 canonical 名 | 本文の版数・参照・実装順序名を v4 / SV-E3 に揃える。 |

### 1.3 v4 からの v5 修正: 保管先連動の Notebook 保護

添付のプライバシーレベル整理では、再学習利用ありクラウド LLM、再学習しないクラウド LLM、Dropbox / OneDrive 等のクラウドストレージ、監査済みローカルドライブの代表値をそれぞれ `0.20`, `0.45`, `0.65`, `0.90` 程度に置き、PL だけでなく `TrainingUse`, `ExternalStorage`, `RetentionRisk`, `HumanReviewRisk`, `LocalSecurity` を併用する方針が示されている。v5 ではこの考え方を SourceVault の storage policy として採用する。

| v4 までの前提 | 問題 | v5 での修正 |
|---|---|---|
| 高 PL セルはクラウド保存対象から分離する建前 | Notebook をセル単位に物理分割する運用は不便で、分離ミス・sidecar 紛失・復号不能化の危険がある | Notebook 全体を保存してよいが、保存先の `MaxPlaintextPL` を超えるセルは暗号化セル placeholder に置換する |
| Dropbox 等への保存は単なるファイル保存として扱う | クラウドストレージ事業者・同期端末・共有リンクから見える範囲では、ファイル内容がその保存先のアクセスレベルで露出する | `SourceVaultStorageProfile[path]` で保存先アクセスレベルを評価し、平文保存可否を判定する |
| Claude Code / cloud agent readable な `$packageDirectory` はローカルパスとして扱われがち | agent が読むなら、そのファイルは cloud LLM 入力または agent workspace と同等の低い境界に置かれる | `AgentReadableWorkspace` を storage observer として扱い、destination effective PL を下げる |
| Save メニューを通常保存として使う | ユーザーが高 PL セルを含む Notebook を誤って同期フォルダへ保存し得る | `SourceVaultSaveProtectedNotebook` を主経路にし、Save hook は capability probe 済み環境でのみ補助経路にする。次善策として ClaudeCode palette に「保護して保存」ボタンを置く |


### 1.4 v5 からの v6 修正: MailDB / IMAP 一時ソースと受信者別 release planning

現状の `maildb.wl` は SourceVault とは独立しているが、次の設計要素を既に持つため、SourceVault へ融合する価値が高い。

- mbox 名から IMAP account / credential key / server を解決する設定層。
- IMAP から月次単位でメールを取得し、`.wl` 形式の月次 DB と添付ファイルディレクトリへ保存する処理。
- `MailDBObject` として `dataset` / `nearest` / `nearestST` / `mails` / `files` をまとめるロード形式。
- `summary`, `priority`, `privacy`, `embedding`, `summarytagembedding` を持つメール record。
- `mailSearchForLLM` による semantic search と、`NBGetProviderMaxAccessLevel["claudecode"]` に基づく public/private 分割。
- `mailAskLLM` による public mail → cloud LLM、private mail → local LLM の二経路処理。
- Notebook 上で返信 cell を作り、`sendReply` / `sendReplyTr` / `confirmSendReplyTr` で送信する UX。

v6 では、これをそのまま取り込むのではなく、次のように SourceVault 化する。

| maildb の現状 | SourceVault 統合後 |
|---|---|
| IMAP 取得結果を月次 `.wl` DB と添付フォルダに保存 | IMAP は一時ソース、SourceVault は snapshot / metadata / attachment record を保持 |
| `privacy` 数値で public/private 分割 | numeric PL + tag-based policy + recipient profile で release plan を生成 |
| provider threshold 以下を cloud LLM へ送る | cloud route だけでなく、email recipient / transport / public key capability を加味して materialization を判定 |
| private mail は local LLM に要約させる | private source は local planning のみ。外部送信前に MessageReleasePlan を必ず通す |
| `sendReply` は notebook cell の本文を SendMail する | `SourceVaultComposeMailDraft` → release audit → human confirmation → send の順にする |
| 添付ファイルは mbox/yearmonth 下に保存 | attachment は SourceVault attachment snapshot として保存し、高 PL なら暗号化、送信時は recipient policy で個別判定 |

この追加により、例えば次のような指示を、単なる RAG ではなく release-controlled workflow として扱える。

```wl
ClaudeEval[
  "xxxx@example.org からの最新メールに関して肯定的に返信を送ってほしい。
   そのとき、関連する yyyy のノートの内容を含めてほしい。"
]
```

この場合、SourceVault はメールと Notebook の両方を source material として集めるが、外部メール送信前に次を自動判定する。

1. 受信者が同じ SourceVault 系システムを使っており、公開鍵 registry に登録済みか。
2. 受信者の `RecipientAccessProfile` が、該当 Notebook cell / mail snapshot / attachment の PL と privacy tags を読む権限を持つか。
3. 通常メール本文として平文送信できる `TransportProfile.MaxPlaintextPL` 以下か。
4. 平文メール本文には高すぎるが、受信者のアクセス権以下であり、かつ公開鍵がある material は capsule として暗号化添付できるか。
5. 受信者のアクセス権を超える material、または tag policy に失敗する material は、本文にも capsule にも含めず redaction するか。


### 1.5 v6 レビューからの v7 修正: MailDB 漏洩面と release policy の具体化

v6 レビューでは、暗号コアと SV-E4 は収束している一方、MailDB 統合ではメール固有の漏洩面を実装前に閉じる必要があると評価された。v7 では次を修正する。

| v6 の残課題 | v7 での修正 |
|---|---|
| MailSnapshot が `Subject` / `From` / `To` / `Cc` / `MessageID` を平文 metadata に置く | 高 PL mail では header を encrypted payload 側へ移し、平文側には keyed HMAC token と最小限の低漏洩 metadata だけを残す。`RecordId` も `HMAC(mbox, MessageID)` から導出する。 |
| summary / embedding を保存時の漏洩源としてしか扱っていない | **派生フィールド生成そのものを materialization** と定義し、private mail の summary / embedding は local model / local embedding のみで生成する。既存 cloud-generated embedding は provenance と Doctor warning を残す。 |
| 既存 maildb が Dropbox 配下へ平文 DB / 添付 / embedding を書き続け得る | migration の step 0 として、maildb の直接 ingest / scheduled task / `$dropbox/udb/mails` 書き込みを停止または SourceVault 経由へ切替える。新 mail store は同期パス外を既定にする。 |
| maildb の 2 値 `privacy` を PL の真実源にしかねない | `privacy` は「過去の LLM 推定」provenance として扱い、release / cloud 判定の真実源にしない。import は fail-safe に高 PL / encrypted-only を既定にする。 |
| `SourceVaultTagPolicyEvaluate` の意味論が未定義 | Deny-wins、階層 tag、wildcard、未知 tag の fail-closed、例外 override の二重承認を仕様化する。 |
| 未知受信者の既定 `MaxPlaintextPL -> 0.45` が fail-open | 未登録 / 未検証受信者は `MaxPlaintextPL -> 0.0`、`MaxEncryptedReadablePL -> 0.0`、`TrustStatus -> "Unverified"` を既定にする。 |
| 暗号化 embedding と検索の両立が未定義 | private embedding は at-rest encrypted、検索時だけ NBAccess gate 下で復号して memory-only KDTree / nearest index を構築し、平文 vector を永続化しない。 |


### 1.6 v7 レビューからの v8 修正: Mail HMAC 鍵と実装順序の収束

v7 最終レビューでは、設計全体は実装着手可能だが、メール用 HMAC 鍵の標準化、実装順序、AAD 改ざんテスト、版数ラベルに局所修正が必要と評価された。v8 では次を修正する。

| v7 の残課題 | v8 での修正 |
|---|---|
| MailSnapshot の `RecordId` / header token 用 HMAC 鍵が標準 KeyRef と bootstrap に無い | `SourceVault:mailid:mac:v1` を標準 KeyRef に追加し、`SourceVaultInitializeEncryption[]` の生成対象に含める。通常 rotation から除外し、token / dedup の安定性を守る。 |
| §17 実装順序の番号重複と依存順序逆転 | public key registry / hybrid capsule を recipient bootstrap / MessageReleasePlan より前へ移し、番号を通し直す。 |
| AAD に追加した canonicalization 系フィールドの改ざんテスト漏れ | `PayloadCanonicalization` / `PayloadSerializationFormat` / `AuthenticatedBytesCanonicalization` も tampered metadata テスト対象に含める。 |
| capability report の重複キー、v6 / v2 ラベル残り | `RSAPSSSignatureAvailable` 重複を削除し、まとめと比較表の版数表記を v8 に更新する。 |
| SubjectPreview / ThreadID / memory-only index / mail body 暗号化の明示不足 | 高 PL mail の `SubjectPreview` 抑制、既存 maildb では ThreadID 取得不能、memory-only embedding index の寿命、mail body は保存先 PL に関わらず既定 encrypted であることを明記する。 |


### 1.7 v8 レビューからの v9 修正: ヘッダ閾値と増分 derived batch

v8 レビューでは、暗号コア・保管先連動保護・MailDB release planning は実装着手可能な水準だが、メール運用上の利便性と長時間処理の再開性に関して、次の 2 点を仕様に入れるべきと評価された。v9 では次を修正する。

| v8 の残課題 | v9 での修正 |
|---|---|
| 高 PL mail では件名・送受信者を一律 encrypted header にする二分モデル | メールヘッダにも SV-E4 の `StorageProfile.MaxPlaintextPL` モデルを適用する。`headerPL <= HeaderPlaintextThreshold` なら subject などを平文保存可能、閾値超なら encrypted header + HMAC token とする。 |
| 件名は検索性のため平文にしたいが、To/Cc は社会的関係グラフとして別扱いしたい | `HeaderFieldPolicy` を導入し、`Subject` / `From` / `ToCc` / `MessageID` を per-field に判定できるようにする。最低限は subject 平文、address は token の混在運用を許す。 |
| PL 推定がローカル LLM になり長時間化するが、既存 `addMailProperty` は全件再処理・一括保存で中断に弱い | `SourceVaultInferMailDerivedBatch` を追加し、未処理 snapshot だけを処理し、1 通または N 通ごとに checkpoint JSONL へ append して再開可能にする。 |
| ヘッダ平文化は PL に依存するが、PL は後から推定される | import 時は fail-closed の provisional encrypted header とし、derived batch が `PrivacyLevel` / `PrivacyConfidence` を確定した後、閾値以下なら local re-seal により plain header へダウングレードできる遷移を定義する。 |



### 1.8 v10 レビューからの v11 修正: HeaderPL 生成経路と Trusted Baseline Registry

v10 レビューでは、ヘッダ閾値と増分 checkpoint batch は本文へ統合済みだが、`HeaderPL` の生成主体が未定義であるため、re-seal が発動できないという本文内不整合が指摘された。また、今回の追加要望として、IMAP / Dropbox / OneDrive / iCloud / cloud store / LLM endpoint の access level など、ポリシー判定の根になる基礎データを SourceVault に保存する場合、それ自体の改ざんがセキュリティ基盤を崩すという点を仕様化する。

| v10 の残課題 / 追加要望 | v11 での修正 |
|---|---|
| `HeaderPL` が schema と re-seal 条件にあるが、derived batch の `Fields` に含まれない | `SourceVaultInferMailDerivedBatch` の既定 `Fields` に `HeaderPL` / `HeaderConfidence` を追加し、ローカル LLM または保守的 heuristic で生成する。`HeaderPL` が無い場合は `PrivacyLevel` に fallback できるが、confidence が不足する場合は平文化しない。 |
| `MinConfidence` の既定と `Missing` 時の扱いが未定義 | `$SourceVaultMailHeaderMinConfidence = 0.70` を既定とし、`Missing` / 非数値 confidence は fail-closed、すなわち encrypted header を維持する。 |
| re-seal が batch 完了後一括に読める | 各 record の checkpoint commit 直後に、その record だけ `SourceVaultReclassifyMailHeaderRecord` を実行する。中断しても完了分は検索可能になる。一括 reclassify は保存先変更時の再評価用に残す。 |
| cloud store / LLM route / IMAP account の access level を SourceVault に置くと、改ざんで policy が崩れる | `SourceVaultTrustedBaselineRegistry` を導入する。StorageProfile、CloudStoreProfile、LLMRouteProfile、IMAPAccountProfile、Recipient defaults、PL threshold などを signed/MACed baseline manifest として保存し、実行時に検証失敗なら fail-closed とする。 |
| 非鍵 hash だけでは policy config の真正性を保証できない | baseline record は canonical JSON digest に加え、local baseline MAC と owner signature を持つ。署名検証用 root fingerprint は SourceVault の通常 writable store だけに置かず、NBAccess / OS credential / out-of-band fingerprint に pin する。 |
| baseline の古い版への rollback で access level を下げられる | baseline manifest は monotonic revision、previous digest chain、activation timestamp を持つ。Doctor は rollback / fork / unsigned edit / stale revision を検出する。 |


### 1.9 v11 レビューからの v12 修正: per-record policy 完全性と baseline enforcement の補強

v11 レビューでは、Trusted Baseline Registry は global policy root の改ざん検証として妥当だが、release / cloud-send / storage 判定が直接読む **record 単位の policy metadata** が未認証のまま残ると指摘された。v12 では次を修正する。

| v11 の残課題 | v12 での修正 |
|---|---|
| `Policy.CloudSendAllowed` / `Derived.PrivacyLevel` / `AccessTags` / `HeaderPL` 等が AAD に入っておらず、store 書換えで判定を反転できる | at-rest record の `AuthenticatedAssociatedDataFields` を `Policy` / `Derived` / mail header policy / release policy まで拡張し、改ざん時は HMAC mismatch / AEAD auth failure で fail-closed とする。 |
| Derived batch が `PrivacyLevel` / `HeaderPL` / `AccessTags` を後から更新するが、その際の HMAC 再計算契約がない | `SourceVaultUpdateAuthenticatedRecordPolicy` を追加し、record lock + generation rewrite + AAD 再計算 + HMAC 再署名を必須化する。derived batch / header re-seal はこの経路だけを使う。 |
| baseline が存在しない初期状態の扱いが未定義 | active baseline 不在・pinned revision 不一致・baseline 削除は検証失敗と同じ `SourceVaultBaselineRecoveryMode` とし、cloud / mail send / plaintext downgrade を禁止する。 |
| baseline は設定の真正性を保証するが、平文 HTTP の local LLM endpoint の真正性までは保証しない | trusted local server entry に `TransportSecurity` / certificate or public-key pin を持たせ、TLS + pinning を推奨する。plain HTTP LAN は明示 risk acceptance と Doctor warning を要求する。 |
| baseline activation の user confirmation が agent の action space 内にあると prompt-injection で偽装され得る | final activation は agent が直接実行できない OS credential / external dialog / out-of-band fingerprint 入力等の経路に置く。agent は Pending baseline の diff 作成までに制限する。 |
| baseline 検証を hot path で毎回 RSA-PSS 検証すると重い | session/load 単位で verified baseline cache を作り、pinned revision / digest / TTL / file watcher によって invalidation する。 |
| `EffectiveAccess` が `CanonicalProfile` と食い違って署名される可能性 | `EffectiveAccess` は `CanonicalProfile` からの純関数で導出し、sign 時・verify 時に再導出して一致を検査する。 |


### 1.10 v12 レビューからの v13 修正: 正規 policy 緩和の承認・相手側 record 完全性・更新性能

v12 レビューでは、AAD/HMAC により file-level 改ざんは閉じたが、正規 API で policy を緩める経路、release 判定の相手側 record、更新性能に残課題があると評価された。v13 では次を修正する。

| v12 の残課題 | v13 での修正 |
|---|---|
| `SourceVaultUpdateAuthenticatedRecordPolicy` が正規に呼ばれると、HMAC を正しく再計算した policy downgrade が成立する | policy update を **tightening / loosening** に分類し、PL downgrade、`CloudSendAllowed -> True`、declassify、AccessTags 追加、DenyTags 削除などの loosening は baseline activation と同格の agent 外・人間承認 + audit を必須にする。 |
| import 時 high PL から derived batch が低 PL を付ける操作は実質的な loosening | `PrivacyLevel` / `HeaderPL` の初期付与にも confidence gate を適用し、閾値未満または Missing なら high PL を維持する。 |
| snapshot record 側は認証されても、`RecipientAccessProfile` / `SourceVaultPublicKeyRecord` が改ざんされると release 判定が通る | recipient profile と public key record も authenticated record とし、trust 昇格・MaxPlaintextPL 引上げ・DenyTags 削除などは loosening 承認対象にする。 |
| checkpoint 毎に generation file を全 rewrite すると O(N^2) になり得る | mutable policy は既定で **append-only authenticated policy delta log** に追記し、latest valid state を chain 検証して解決する。checkpoint は安価な進捗 append、policy commit は delta log append、compaction は別処理に分離する。 |
| AAD field を個別キー列挙すると新しい security field の足し忘れが起きる | `Policy` / `Derived` / `MailMetadataPublic.DecisionState` / `ReleasePolicy` / `RecipientPolicy` など、判定駆動サブ association 全体を canonical 認証する。 |
| legacy migration の初回 authenticated write と既存 authenticated record update が未区別 | 初回確立は `SourceVaultEncryptedPut` / `SourceVaultEstablishAuthenticatedRecord`、既存 update は current auth 検証必須の `SourceVaultUpdateAuthenticatedRecordPolicy` として分離する。 |


### 1.10 v13 レビューからの v14 修正: policy delta log の rollback 保護と承認束縛

v13 レビューでは、append-only authenticated policy delta log は file 改ざんや偽 delta 挿入には強いが、末尾 delta を削る truncation / rollback には弱いと指摘された。valid chain の prefix も valid chain であるため、HMAC chain だけでは freshness を保証できない。v14 では、baseline registry と同様に **policy head manifest** を導入し、per-record policy head の最新性を rollback protected な root に pin する。

| v13 の残課題 | v14 での修正 |
|---|---|
| policy delta log の末尾 truncation / record 削除 / rollback を検出する head pin がない | `SourceVaultPolicyHeadManifest` を追加し、`RecordId -> {LatestPolicyRevision, HeadStateDigest}` を signed/MACed manifest に集約する。manifest 自体は global monotonic revision と pinned digest で rollback 保護する。 |
| `SourceVaultClassifyPolicyUpdate` の未知 field / 混在変更の扱いが未定義 | classifier は conservative とし、既知の tightening / 明白な neutral 以外は **Loosening** として agent 外承認を要求する。loosening 成分を含む mixed delta も全体として Loosening とする。 |
| approval token が承認対象の変更内容に束縛されていない | approval token は `recordId`、`PolicyRevision`、canonical delta digest、active baseline digest、nonce、期限、actor を含む approval challenge に署名/MAC する single-use token とする。別 delta への流用は拒否する。 |
| compaction の正当性と rollback 保護が未定義 | compaction は `resolve(before) == resolve(after)` を検証し、head manifest revision を進める。state を緩める compaction は拒否し、compaction artifact も manifest chain に含める。 |
| 古い baseline 下で承認済みの loosening が、新 baseline の tightening に反する可能性 | delta の `BaselineDigest` が current active baseline と異なる場合は `RequiresReevaluation` とし、current baseline 下で再評価または再承認する。 |
| delta chain resolve が hot path で重い | verified policy state cache を追加し、head manifest digest / recordId / revision を cache key とする。manifest 変更・delta append・TTL で invalidation する。 |


### 1.11 v14 からの v15 修正: SourceVault AddressBook と contact-aware mail policy

MailDB を SourceVault に取り込む際、メールアドレスを単なる文字列として扱うと、同一人物の複数アドレス、学内グループ、メーリングリスト、SPAM / direct-mail category、SourceVault 利用者としての公開鍵・nickname が release planning に反映できない。v15 では次を追加する。

| 追加要件 | v15 での修正 |
|---|---|
| 個人が複数 email / GitHub / X / SourceVault nickname / 公開鍵を持つ | `SourceVaultAddressBook` に `ContactRecord` を導入し、local serial `uid`、stable `ContactId`、`Emails`、`Handles`、`SystemUserIdentities`、`SourceVaultUserNames` を保持する。nickname は環境を一意に識別しない alias として扱う。 |
| 受信者・送信者ごとの access level 推定値が必要 | `ContactAccessProfile` を address book entry に持たせ、`MaxPlaintextPL` / `MaxEncryptedReadablePL` / `AccessTags` / `DenyTags` / `PurposeAllowed` を recipient profile 生成の入力にする。policy loosening は agent 外承認を要求する。 |
| 情報工学科教員などの group address / group membership で tag-based access が変わる | `ContactGroupRecord` を導入し、member contact / member email / group address / domain rule / dynamic selector を持たせる。group 宛メールは group profile と各 member policy の conservative intersection で評価する。 |
| `fukuyama-u.ac.jp` など domain ごとの access level / tag policy が必要 | `AddressDomainPolicyRecord` を導入し、domain ごとに trust category、default PL ceiling、access tag overlays、deny tags、mailing-list / external / free-mail / unknown-domain policy を定義する。 |
| SPAM / direct mail / newsletter 等も privacy と summary 生成に影響する | `AddressCategoryPolicyRecord` を導入し、`SpamLikely`, `DirectMarketing`, `Newsletter`, `AutomatedNotification`, `NoReply`, `SensitiveBusiness` などの category を PL 推定・summary・search select に渡す。 |
| アドレス帳も policy 判定を駆動するため改ざんに弱い | AddressBook / Group / DomainPolicy / CategoryPolicy は authenticated record とし、policy head manifest / delta log / loosening approval の対象にする。 |
| maildb の `showMails` UI を SourceVault_promptrouter で利用したい | `SourceVaultMailView` / `SourceVaultMailSearchPanel` / `SourceVaultAddressBookPanel` / `SourceVaultPromptRouterMailPanel` を追加し、mail cards、reply draft、release audit、address filters を定型表示として扱う。 |


### 1.12 v15 からの v16 修正: SourceVault Identity Graph / Author Database

v15 の AddressBook は MailDB 取り込みと受信者別 release planning のための連絡先台帳であった。v16 ではこれを、メール・web・論文・コード・SNS キャッシュを横断する **identity graph / author database** に拡張する。

| 追加要件 | v16 での修正 |
|---|---|
| IMAP からメールを取り込むたびに未知の送受信者を追加したい | `SourceVaultAutoRegisterMailParticipants` を追加し、From / To / Cc / Reply-To / group address を AddressBook へ照合する。存在しなければ fail-closed access profile で ContactRecord または ContactCandidate を作成する。 |
| GitHub / arXiv / blog / PDF 取り込み時に著者・ユーザをアドレス帳へ登録したい | `SourceVaultIngestIdentityObservations` と `SourceVaultExtractSourceIdentities` を追加し、source type ごとの extractor が author / owner / committer / contributor / blog author / PDF metadata author / ORCID / GitHub handle 等を `IdentityObservationRecord` として保存する。 |
| 確信が持てる場合は既存 contact に追加、確信が持てない場合はタグ付け候補にしたい | identity resolution を `Confirmed` / `Likely` / `Ambiguous` / `Unresolved` に分ける。`Confirmed` は contact へ自動追加可能、`Likely` は `IdentityCandidate` として `NeedsReview`、`Ambiguous` は複数候補に evidence を付けて保留、`Unresolved` は観測 record のみにする。 |
| 自動追加でアクセス権が緩みすぎるのを避けたい | 自動作成 contact は `TrustStatus -> "Observed" | "Unverified"`、`MaxPlaintextPL -> 0.0` を既定とし、access を緩める変更は v13 以降の loosening approval を要求する。identity merge は連絡先統合であり、release permission の自動昇格ではない。 |
| 取り込んだ source と著者データを紐づけたい | すべての SourceVault source record に `AuthorRefs` / `ContributorRefs` / `IdentityObservationRefs` / `AttributionConfidence` を持たせ、ContactRecord 側にも `EvidenceRefs` を保持する。 |
| 将来 X / Discord / SNS cache も統合したい | `SocialIdentityObservation` / `SourceVaultSocialSnapshot` を将来拡張 point として定義し、handle / display name / platform id / server id / channel id を ContactRecord の handles / observations に接続できるようにする。 |
| 検索で人物・著者・出典に基づく select をしたい | `SourceVaultSearchSources` / `SourceVaultSearchMailSnapshots` / `SourceVaultSearchIdentityGraph` に `AuthorContact`, `GitHubHandle`, `ORCID`, `ObservedInSourceType`, `Affiliation`, `IdentityConfidence` などの select を追加する。 |

v16 の方針は、**AddressBook を「手入力の住所録」ではなく、provenance 付きで成長する identity graph として扱う**ことである。ただし、identity resolution は security boundary ではなく推定であるため、release permission や `MaxPlaintextPL` の緩和には使わない。identity resolution ができることと、その相手に高 PL 情報を送ってよいことは別である。



### 1.11 v17 レビューからの v18 修正: 送信者認証の信頼境界と AddressBook 集約 PL の確定

v17 レビューでは、AddressBook / Identity Graph の設計は妥当だが、新設した送信者認証メカニズムを安全に使うには、`Authentication-Results` ヘッダそのものの偽装可能性、IMAP 取得時の生メッセージ依存、required authentication policy、メーリングリスト / 転送の ARC、GraphAggregatePL の単調性を明示すべきと指摘された。v18 では次を修正する。

| v17 の残課題 | v18 での修正 |
|---|---|
| `Authentication-Results` ヘッダを素朴に信じると、攻撃者が偽 `dkim=pass` を挿入できる | IMAP account / baseline に `TrustedAuthservIds` を pin し、信頼 authserv-id が付けた A-R のみ採用する。untrusted A-R は loosening に使わない。 |
| DKIM / SPF / DMARC を保存済み snapshot から後で再検証できるように読める | `SenderAuthentication` は IMAP fetch 時に raw MIME / 生ヘッダで確定する attested fact とし、既存 maildb 移行分は `Missing` として sender-based loosening 不可にする。 |
| `requiredPolicy` が未定義 | 既定を `DMARC=Pass`、または `DKIM=Pass` かつ From domain aligned とする。SPF pass 単独は loosening 根拠にしない。 |
| メーリングリスト / 転送で DKIM/SPF が壊れる | 信頼済み ARC sealer / forwarder を baseline に pin し、ARC chain が pass の場合だけ loosening を許す。未登録 ML/forward は fail-safe。 |
| `GraphAggregatePL` の生成・単調性・下げる操作が未定義 | identity batch が生成し、cross-source link の追加では非減少とし、下げる操作は policy loosening として agent 外承認を要求する。未生成時は provisional high PL。 |
| AddressBook field policy の PL 未確定時既定が不明 | mail header と同じく provisional encrypted/tokenized とし、PL 確定後に StorageProfile 閾値以下なら record 単位 re-seal で平文化できる。 |


## 2. 脅威モデルと設計原則

### 2.1 想定する脅威

この Phase では少なくとも次を想定する。

| 脅威 | 対応 |
|---|---|
| SourceVault の JSONL / registry / capsule ファイルを第三者が読む | at-rest encryption、平文 index 抑制、metadata 最小化 |
| SourceVault の JSONL / registry / capsule ファイルを第三者が改ざんする | encrypt-then-MAC、署名、Doctor 検査。AEAD は実測で利用可能な場合のみ採用 |
| authenticated policy delta log の末尾を削って古い valid prefix に戻す | rollback protected policy head manifest、global monotonic manifest revision、pinned head digest / Merkle root、head mismatch 時 fail-closed |
| StorageProfile / CloudStoreProfile / LLMRouteProfile / IMAPAccountProfile などの基礎ポリシーデータが改ざんされる | Trusted Baseline Registry による署名・MAC・revision chain・root fingerprint pinning。検証失敗時は fail-closed。 |
| private prompt が誤って cloud LLM に送られる | record-level policy enforcement、NBAccess authorization、Declassify 要求 |
| OS credential store から鍵を直接列挙できない | 鍵材料を含まない KeyRef index を別途維持 |
| Dropbox / OneDrive / Google Drive 等に既存平文が同期済み | migration の限界を Doctor と運用 directive に明示し、新規 private prompt は初回から平文をディスクに書かない |
| ログ・例外・debug output に鍵や復号済み payload が混ざる | NBAccess 内部 crypto、secret redaction test、戻り値契約 |
| 共有 capsule が第三者に差し替えられる | capsule signature、public key fingerprint、TrustOnImport |
| 高 PL セルを含む Notebook が Dropbox / OneDrive / Claude Code readable workspace に平文保存される | storage profile に基づく protected save、暗号化セル placeholder、Doctor warning、palette button |
| Save menu / autosave / external copy が保護経路を迂回する | Save hook は補助扱い。主境界は protected save API、storage write authorization、定期 scanner、Doctor |
| IMAP から取得したメール本文・添付・embedding DB が低 PL 保存先に平文で残る | MailDB を一時ソース化し、SourceVault snapshot record と encrypted attachment record に変換する。旧 `.wl` DB は migration / quarantine 対象にする。 |
| private mail の件名・送受信者・Message-ID が平文 metadata として残る | 高 PL mail では header を encrypted payload 側へ移し、平文側は HMAC token と最小限 metadata にする。 |
| private mail の summary / embedding 生成時に cloud API へ本文が送られる | 派生フィールド生成も materialization とし、private mail は local model / local embedding のみで生成する。 |
| 既存 maildb が migration 中も Dropbox 配下へ平文を書き続ける | migration step 0 で direct ingest / scheduled task / legacy writer を停止または SourceVault ingest に切替える。 |
| メール返信に Notebook の高 PL セルや mail snapshot が過剰に含まれる | MessageReleasePlan が recipient profile / transport profile / tag policy を評価し、plaintext / encrypted capsule / redacted を強制分岐する。 |
| 同じメール受信者でも、プロジェクト・役割・契約・タグにより読める情報が異なる | PL 数値だけでなく `AccessTags`, `DenyTags`, `Purpose`, `Relationship`, `TrustStatus` を含む tag-based privacy を導入する。 |
| 同一人物が複数メールアドレス・複数端末・複数 SourceVault nickname を持つ | AddressBook の `ContactId` / `uid` / aliases / sourcevault identities で正規化し、nickname は環境一意識別子として扱わない。 |
| group address / domain / spam category の改ざんで release 判定が変わる | AddressBook / Group / DomainPolicy / CategoryPolicy を authenticated record とし、loosening は agent 外承認、delta rollback は policy head manifest で検出する。 |
| web / GitHub / arXiv / PDF 由来の著者同定を誤って既存 contact と merge する | IdentityObservation と ContactCandidate を分離し、confidence / evidence / source record を保持する。曖昧な merge は `IdentityUncertain` / `NeedsReview` として保留し、access loosening は絶対に自動化しない。 |
| prompt-injected web content が著者・連絡先・公開鍵情報を偽装する | extractor は source metadata と本文主張を区別し、verified domain / signature / ORCID / GitHub API 等の evidence class を記録する。本文内の自己主張だけでは confirmed contact にしない。 |
| 受信者が SourceVault 系システムを使っていない | 公開鍵 capsule を復号できないため、高 PL material は本文へ入れず、明示承認された低 PL 要約または redaction のみ送る。 |

### 2.2 設計原則

1. **鍵は NBAccess の外へ返さない。** SourceVault は `KeyRef` と暗号済み blob を扱い、暗号操作は NBAccess crypto API に委譲する。
2. **非鍵 hash を security boundary にしない。** SHA256 checksum は偶発破損検出だけに使う。改ざん検出には HMAC / signature を使う。AEAD は実行環境で検証済みの場合だけ追加選択肢にする。
3. **平文同一性も漏洩対象である。** `PlaintextHash` の生 SHA256 は使わない。既定は HMAC、private では抑制可能にする。
4. **暗号化した record の policy は助言ではなく強制である。** cloud route、export、share、decrypt は必ず NBAccess と record policy を通る。
5. **既存平文データの移行までを Phase の一部とする。** 新規保存だけ暗号化しても過去の prompt-runs.jsonl が残れば安全にならない。
6. **共有は confidentiality と authenticity を分けて扱う。** capsule の payload 暗号化と capsule 署名は別の目的であり、暗号用鍵と署名用鍵も分ける。
7. **共有データは Wolfram バージョン非依存にする。** capsule 署名対象、公開鍵 record、envelope は canonical JSON UTF-8 + Base64 で表現する。
8. **保存先はアクセス境界である。** Notebook / record を Dropbox 等へ置くことは、その保存先の `StorageProfile` が許す観測者にファイルを見せることと同等に扱う。
9. **連絡先は policy root に近い。** AddressBook は検索補助ではなく、sender / recipient / group / domain に基づく PL 推定と release planning の入力であるため、認証付き record として扱い、緩和更新は承認を要求する。
10. **identity observation と access permission を分離する。** GitHub handle、arXiv author、PDF author、blog author、SNS account を同一 contact に結びつけることは、相手に高 PL 情報を送ってよいことを意味しない。identity merge は provenance / confidence 付きで行い、access loosening は別の承認対象にする。
9. **高 PL 平文を低 PL 保管先へ書かない。** `dataPL > destination.MaxPlaintextPL` なら、平文保存を拒否するか、保存前に暗号化・封印する。暗号文の metadata 漏洩も別途評価する。
10. **Save hook は安全境界ではなく UX 補助である。** Front end の Save menu hook が利用できても、外部コピー・kernel 直接保存・同期クライアント・クラッシュ復元を完全には捕捉できない。必須境界は protected save API と Doctor / scanner とする。


### 1.13 v16 レビューからの v17 修正: AddressBook / Identity Graph の送信者認証・PII 保護・自動登録制御

v16 の AddressBook / Identity Graph は、データ作成者を provenance 付きで明確化し、PL 推定・要約生成・release planning・検索 select に使う方向として妥当である。一方、メールの `From` や web/PDF 中の著者表記は偽装・誤同定・過剰集約のリスクを持つ。v17 では次を追加する。

| 指摘 | v17 での修正 |
|---|---|
| メールの `From` は認証なしには信用できず、sender category で PL を下げると spoofing に弱い | `SenderAuthentication` を MailSnapshot の authenticated decision state に追加し、DKIM / SPF / DMARC / ARC の pass / fail / none / unknown を保存する。From / domain / category による **loosening** は authentication pass の場合だけ許す。tightening は未認証でも可。 |
| `SourceVault:addressbook:mac:v1` が KeyRef 標準・bootstrap・Doctor に無い | AddressBook equality token 用の rotation-stable HMAC 鍵として `SourceVault:addressbook:mac:v1` を標準 KeyRef / bootstrap / Doctor / hardcoded-secret scan に追加する。 |
| identity graph は氏名・所属・handle・source linkage を集約するため、それ自体が PII dossier になる | ContactRecord の PII fields を `AddressBookFieldPolicy` で StorageProfile 連動の encrypted / tokenized / plaintext-threshold 管理にする。identity graph 全体に `GraphAggregatePL` を持たせ、cloud materialization / export では最小化する。 |
| contact merge は access を広げなくても誤 attribution を生む | merge / promote は reversible / audited とし、`VerifiedOutOfBand` でない merge をまたいで高 PL material を cross-attribution しない。draft / answer では `Candidate` / `Ambiguous` と明示する。 |
| IMAP 取り込み時の自動 contact 登録で newsletter / no-reply / list address が大量に contact 化される | 自動 ContactRecord 化は person-like participant に限定し、newsletter / no-reply / automated / mailing-list は既定で observation-only とする。candidate / observation には TTL / compaction / per-source cap を設ける。 |
| DomainPolicy / GroupPolicy 変更時に全メール再評価が発生し得る | `RequiresPolicyReevaluation` は lazy / incremental / priority queue で処理し、検索・返信・release 時に触れた record から再評価する。 |
| `EstimatedAccessPL` が release gate に使われる恐れ | `EstimatedAccessPL` は advisory と明記し、release gate は `MaxPlaintextPL` / `MaxEncryptedReadablePL` / tags / confidence / approval state のみを見る。 |

---

### 1.8 v10 実更新確認版での整理

前回出力で更新が反映されていないように見える問題を避けるため、本版では v8 レビューの 2 つの実質要件を仕様本文の正規要件として明示し直す。

1. **メールヘッダは一律暗号化ではなく、StorageProfile 連動の materialization とする。** 未推定 mail は `ProvisionalEncryptedHeader` で保存し、PL 推定後に `headerPL <= HeaderPlaintextThreshold` かつ confidence / tag policy を満たす場合だけ `PlainHeaderAllowed` または `MixedHeader` へ再封印できる。
2. **ローカル LLM による PL / summary / embedding 推定は、再開可能な増分 checkpoint batch とする。** `SourceVaultInferMailDerivedBatch` は未処理 record だけを処理し、RecordId 単位で checkpoint を append し、完了済み record を再処理しない。
3. **import と PL 推定は分離する。** `SourceVaultImportMailSnapshot` は本文・添付・未確定ヘッダを暗号化して即時 snapshot 化し、PL 推定とヘッダ再封印は後続の resumable batch として行う。
4. **Doctor / PARITY は上記 2 要件を検査対象に含める。** PL 未確定 mail の plain header、checkpoint 未対応 batch、完了済み record の再処理、保存先変更後の header threshold 超過を失敗または warning として報告する。

---

## 3. Claw Code 比較再評価

| 元提言 | 最新状態 | 最新再評価 | 次アクション |
|---|---|---|---|
| NBAccess を強制的実行境界にする | `NBExecuteHeldExpr` が実行前に再検証する構造へ進展 | 大幅改善。ただし承認 option を capability ticket 化する必要がある | `NBIssueExecutionTicket` / `NBVerifyExecutionTicket` を追加 |
| permission mode の製品化 | 独自 mode は存在 | UX と Doctor 表示が不足 | `ClaudePermissionModeStatus[]` と Claw Code 対応表 |
| Workflow / StateGraph 移行 | snapshot / restore / async workflow 系が実装方向 | 検証・PARITY 表示が必要 | `WorkflowParityReport[]`、旧 API warning |
| SourceVault 暗号化 | PromptRouter `Encrypt -> True` は未実装 | 依然 P0。v2 では crypto 正確性を先に固定 | SV-E3 全体を実装 |
| PromptRouter status | 自由文 Notes 依存 | P0.5。status を安全判断に使うには機械可読化が必要 | boolean fields を真実源化 |
| Doctor / Init / CLI | 統合入口は不足 | P1 | `ClaudeSystemDoctor[]`、`SourceVaultDoctor[]` |
| Directives / skills | corpus は充実 | 暗号化・共有 directive が不足 | rule / skill 追加 |
| CI / PARITY | ClaudeTestKit はあるが外部可視性不足 | P1 | `PARITY_SOURCEVAULT.md` |
| Git / diff / PR workflow | Notebook 中心 | P2 | 安全基盤後に拡張 |
| MCP / LSP / tool registry | 中核ではない | P2 | crypto / Doctor 後 |

---

## 4. Phase SV-E3 全体構成

### Phase SV-E3.0: Directive と安全境界の固定

追加ファイル案:

```text
Claude Directives/rules/105-sourcevault-authenticated-encryption.md
Claude Directives/rules/106-sourcevault-keyref-and-credential-boundary.md
Claude Directives/rules/107-sourcevault-capsule-sharing.md
Claude Directives/rules/108-sourcevault-storage-boundary.md
Claude Directives/skills/sourcevault-key-management/SKILL.md
Claude Directives/skills/sourcevault-encrypted-prompt-router/SKILL.md
Claude Directives/skills/sourcevault-capsule-sharing/SKILL.md
Claude Directives/skills/sourcevault-protected-notebook-save/SKILL.md
```

必須ルール:

1. パスワード、API key、symmetric key、private key、復号済み payload はソース・manifest・log・prompt history に保存しない。
2. SourceVault record に保存してよいのは `KeyRef`、公開鍵、fingerprint、暗号文、checksum、HMAC、署名、metadata のみである。
3. `CiphertextChecksum` は MAC ではない。完全性保証には encrypt-then-MAC または signature を使う。AEAD は環境検証済みの場合だけ許可する。
4. `PlaintextDigest` は既定で keyed HMAC とし、生 SHA256 を既定にしない。
5. 鍵は `ToExpression` で復元しない。credential には Base64 化した評価不要の直列化形式を入れる。
6. SourceVault は鍵材料を受け取らない。暗号化・復号・MAC・署名は NBAccess API 経由で行う。
7. encrypted/private record の cloud 送信は record policy と NBAccess の両方で許可された場合だけ可能である。
8. private record の plaintext index は既定で作らない。
9. capsule は署名対象 canonical JSON bytes を固定し、署名未検証の import は `UntrustedUntilReviewed` のままとする。
10. SourceVault の鍵用途は分離する。at-rest 暗号鍵、at-rest MAC 鍵、plaintext digest HMAC 鍵、local capsule quarantine MAC 鍵、envelope 復号鍵、署名鍵を混用しない。
11. 共有 capsule payload の MAC は送信者ローカル固定鍵で計算しない。payload key から HKDF で `payloadEncKey` / `payloadMacKey` を派生する。
12. Notebook / SourceVault record の保存先は `StorageProfile` として評価し、保存先 `MaxPlaintextPL` を超えるセル・payload を平文で保存してはならない。
13. Dropbox / OneDrive / Google Drive / iCloud Drive / Claude Code readable workspace / cloud agent workspace は、ローカルパスであっても低い保存先境界として扱う。
14. Save menu hook は実装できる場合でも補助機構に留め、`SourceVaultSaveProtectedNotebook` と ClaudeCode palette の「保護して保存」ボタンを主 UX とする。
15. メールヘッダは本文より安全とは見なさない。`Subject`, `From`, `To`, `Cc`, `MessageID`, 添付ファイル名は高 PL mail では encrypted payload または HMAC token として扱う。
16. summary / embedding / tag inference / priority inference は単なるローカル計算ではなく materialization である。入力を cloud provider へ送る場合は cloud route と同じ NBAccess / SourceVault policy を通す。
17. maildb 由来の `privacy` は信頼済み PL ではなく provenance である。明示 declassify なしに release / cloud-send の許可根拠にしない。
18. 受信者 profile と tag policy は fail-closed を既定にする。未知受信者・未知 tag・期限切れ profile・未検証公開鍵は許可ではなく redaction / draft-only に倒す。
19. StorageProfile / CloudStoreProfile / LLMRouteProfile / IMAPAccountProfile / default PL threshold は通常 record ではなく Trusted Baseline Registry の signed/MACed entry として扱う。
20. baseline の非鍵 hash は identity / diff 用であり、真正性根拠ではない。真正性は baseline MAC / owner signature / pinned root fingerprint で検証する。
21. baseline 検証に失敗した場合、cloud route / storage materialization / mail import / protected save は fail-closed とし、低い既定値へ自動 fallback しない。
22. baseline update は diff 表示・明示承認・署名・monotonic revision 更新を伴う。エージェントは user confirmation なしに active baseline を書き換えない。

---

## 5. NBAccess crypto 層

### 5.1 主 API

`NBResolveCredentialKey[keyRef] -> key` を公開主 API にしない。主 API は次とする。

```wl
NBInitializeCredentialKey[keyRef_String, purpose_String, opts___]
NBStoreCredentialKey[keyRef_String, serializedSecret_String, metadata_Association, opts___]
NBKeyStatus[keyRef_String, opts___]
NBListCredentialKeyRefs[pattern_: "SourceVault:*", opts___]
NBDeleteCredentialKey[keyRef_String, opts___]

NBEncryptWithKeyRef[keyRef_String, plaintextBytes_ByteArray, purpose_String, accessSpec_: Automatic, opts___]
NBDecryptWithKeyRef[keyRef_String, encrypted_, purpose_String, accessSpec_: Automatic, opts___]
NBMacWithKeyRef[keyRef_String, authenticatedBytes_ByteArray, purpose_String, accessSpec_: Automatic, opts___]
NBVerifyMacWithKeyRef[keyRef_String, authenticatedBytes_ByteArray, mac_, purpose_String, accessSpec_: Automatic, opts___]
NBSignWithKeyRef[keyRef_String, bytes_ByteArray, purpose_String, accessSpec_: Automatic, opts___]
NBDecryptEnvelopeWithKeyRef[keyRef_String, wrappedKey_, purpose_String, accessSpec_: Automatic, opts___]
```

公開鍵による検証や envelope 作成は公開情報を使うため SourceVault 側でもよいが、private key を使う操作は NBAccess に閉じ込める。

```wl
SourceVaultVerifySignature[publicKeyRecord_, bytes_ByteArray, signature_]
SourceVaultWrapPayloadKey[encryptionPublicKeyRecord_, payloadKeyBytes_ByteArray]
```

### 5.2 鍵材料の保存形式

`SystemCredential` は KeyRef ごとの秘密値を持つが、列挙・検索・監査には使いにくい。そのため、次の二層構造にする。

| 層 | 保存内容 | 鍵材料を含むか |
|---|---|---|
| OS credential store / `SystemCredential` | Base64 化した serialized key material | 含む |
| SourceVault KeyRef index | KeyRef、purpose、algorithm、fingerprint、created/rotated status、credential name | 含まない |

秘密鍵・対称鍵など、ローカル credential store 内に閉じる鍵オブジェクトの保存は次の形式に限定する。

```text
key object -> BinarySerialize -> ByteArray -> Base64 string -> SystemCredential[keyRef]
```

復元は次に限定する。

```text
SystemCredential[keyRef] -> Base64 decode -> BinaryDeserialize
```

`ToExpression` は SourceVault key material の復元に使わない。NotebookExtensions.wl の既存パターンは「SystemCredential を使う」という発想だけを参考にし、`ToExpression@SystemCredential[...]` は踏襲しない。

共有対象の public key / capsule / envelope では `BinarySerialize` を署名対象に直接使わない。これらは §6.1 の Interoperable JSON profile、すなわち canonical JSON + Base64 形式で保存する。

### 5.3 KeyRef 命名規則

BNF 風に次を標準とする。

```text
KeyRef        ::= "SourceVault:" Scope ":" Role ":v" Version
Scope         ::= "master" | "pthmac" | "mailid" | "capsule" | "baseline" | "self" | "signing" | "test" | CustomScope
Role          ::= "atrest" | "mac" | "digest" | "private" | "public" | "sign" | "verify" | "payload" | "quarantine-mac" | "policy-mac" | "policy-sign" | CustomRole
Version       ::= PositiveInteger
CustomScope   ::= Letter (Letter | Digit | "-" | "_")*
CustomRole    ::= Letter (Letter | Digit | "-" | "_")*
```

標準 KeyRef:

```wl
$SourceVaultDefaultAtRestKeyRef       = "SourceVault:master:atrest:v1";
$SourceVaultDefaultAtRestMACKeyRef     = "SourceVault:master:mac:v1";
$SourceVaultDefaultPlaintextHMACKeyRef = "SourceVault:pthmac:digest:v1";
$SourceVaultDefaultMailIdentityHMACKeyRef = "SourceVault:mailid:mac:v1";  (* RecordId / mail header token 用。rotation-stable *)
$SourceVaultDefaultBaselineMACKeyRef     = "SourceVault:baseline:policy-mac:v1";   (* Trusted Baseline local integrity 用 *)
$SourceVaultDefaultBaselineSigningKeyRef = "SourceVault:baseline:policy-sign:v1";  (* Trusted Baseline owner signature 用 *)
$SourceVaultDefaultCapsuleQuarantineMACKeyRef = "SourceVault:capsule:quarantine-mac:v1";  (* local at-rest quarantine only; shared payload MAC には使わない *)
$SourceVaultDefaultSelfPrivateKeyRef   = "SourceVault:self:private:v1";
$SourceVaultDefaultSelfSigningKeyRef   = "SourceVault:signing:sign:v1";
```

### 5.4 bootstrap

初回鍵生成手順を明示する。

```wl
SourceVaultInitializeEncryption[opts___]
```

既定挙動:

1. 既存の at-rest encryption KeyRef / at-rest MAC KeyRef / plaintext HMAC KeyRef / mail identity/token HMAC KeyRef / Trusted Baseline MAC KeyRef / Trusted Baseline signing KeyRef / local capsule quarantine MAC KeyRef / self envelope private key / self signing key の有無を確認する。
2. 既存鍵がある場合は再生成しない。
3. 欠落している鍵だけを NBAccess 承認付きで生成する。
4. 鍵材料は credential store にだけ保存する。
5. KeyRef index には鍵材料を含めず、fingerprint / purpose / algorithm / created time / status だけを保存する。
6. 生成された secret は戻り値・ログ・例外・SourceVault record に出さない。
7. `SourceVault:mailid:mac:v1` は `RecordId` / mail header token の安定性に関わるため、通常の at-rest key rotation では置換しない。置換する場合は token 再計算、dedup index 再構築、旧 record との対応表作成を含む明示 migration として扱う。
8. `SourceVault:baseline:policy-mac:v1` / `SourceVault:baseline:policy-sign:v1` は SourceVault の access-level 判定そのものを守る root に近い鍵であるため、通常 record の rotation とは別に、root fingerprint pinning と recovery 手順を伴う明示 migration として扱う。

戻り値例:

```wl
<|
  "Status" -> "Initialized" | "AlreadyInitialized" | "Partial" | "Failed",
  "CreatedKeyRefs" -> {...},
  "ExistingKeyRefs" -> {...},
  "MissingKeyRefs" -> {...},
  "KeyMaterialReturned" -> False,
  "RequiresUserApproval" -> True | False
|>
```

---

## 6. canonical bytes と暗号プリミティブ

### 6.1 canonicalization の二層化

v4 では canonical bytes を用途別に二層化する。

| 用途 | 標準 | 理由 |
|---|---|---|
| local at-rest record の内部 payload | `SourceVaultCanonicalBytes/Internal/v1` | WL 式を含む private data をローカルで安全に roundtrip するため。`BinarySerialize` を使ってよいが、record に serialization version を残す。 |
| capsule / public key registry / signature / envelope | `SourceVaultCanonicalJSON/v1` | 異マシン・異 Wolfram バージョン間で署名検証できるようにするため。canonical JSON UTF-8 + Base64 を使う。 |

```wl
SourceVaultCanonicalize[expr_, profile_: "Internal"]
SourceVaultCanonicalBytes[expr_, profile_: "Internal"]  (* -> ByteArray *)
SourceVaultCanonicalJSONBytes[expr_]                    (* -> ByteArray[UTF8] *)
```

#### Internal profile

1. Association は再帰的に `KeySort` する。
2. List は順序を意味として保持する。
3. Date / Path / URL 等は metadata schema 側で文字列化形式を固定する。
4. WL 式を含む場合は `BinarySerialize` を使ってよい。ただし `SerializationFormat` と `$VersionNumber` 相当の互換情報を metadata に残す。
5. `InputForm` 文字列には依存しない。

#### Interoperable JSON profile

1. Association の key は UTF-8 文字列に限定し、昇順で出力する。
2. バイナリ値は Base64 文字列として表現する。
3. 時刻は UTC の ISO 8601、例 `2026-06-04T00:00:00Z` に固定する。
4. 整数は 10 進表記、実数は原則として共有署名対象に入れない。必要な場合は decimal string として schema 側で明示する。
5. `Missing[...]` は schema ごとの固定文字列または明示 association へ変換する。
6. WL 固有 expression は共有 payload の署名対象に直接置かない。必要な場合は payload 内に `"Encoding" -> "WXF/Base64"` として入れ、その Base64 文字列を JSON 署名対象に含める。

標準値:

```wl
"Canonicalization" -> "SourceVaultCanonicalBytes/Internal/v1"
"SharedCanonicalization" -> "SourceVaultCanonicalJSON/v1"
```

### 6.2 暗号方式と実行環境検証

v4 では **encrypt-then-MAC を既定 primary** とする。Wolfram Language の `Encrypt` が GCM / AEAD を実際にサポートするかは環境依存であるため、AEAD は実測で利用可能と確認できた場合だけ使う。

```wl
SourceVaultCryptoCapabilityReport[]
```

戻り値例:

```wl
<|
  "WolframVersion" -> $Version,
  "AEADGCMAvailable" -> True | False,
  "RSAPSSSignatureAvailable" -> True | False,
  "DefaultSignatureAlgorithm" -> "RSA-PSS-SHA256",
  "DefaultIntegrityMode" -> "EncryptThenMAC",
  "EffectiveIntegrityMode" -> "EncryptThenMAC" | "AuthenticatedEncryption",
  "AEADProbe" -> <|"Status" -> "Pass" | "Fail", "Message" -> ...|>
|>
```

実装前または Doctor 内で、少なくとも次を試験する。

```wl
GenerateSymmetricKey[<|"Cipher" -> "AES256", "BlockMode" -> "GCM"|>]
```

この probe が失敗する環境では silently AEAD を使ったことにしてはならない。同様に RSA-PSS 署名の probe が失敗する環境では、capsule signature を実装済みとして扱わない。

#### 既定: encrypt-then-MAC

暗号化後の serialized ciphertext と暗号メタデータを合わせた authenticated bytes に HMAC を付与する。

```wl
"IntegrityMode" -> "EncryptThenMAC"
"CiphertextHMAC" -> <|
  "Algorithm" -> "HMAC-SHA256",
  "KeyRef" -> "SourceVault:master:mac:v1",
  "AuthenticatedBytes" -> "SourceVaultAtRestAuthenticatedBytes/v1",
  "AuthenticatedAssociatedDataFields" -> {
    "Type", "SchemaVersion", "RecordId", "ContentType",
    "Encryption.Backend", "Encryption.Mode", "Encryption.KeyRef",
    "Encryption.PayloadCanonicalization", "Encryption.PayloadSerializationFormat",
    "Encryption.AuthenticatedBytesCanonicalization", "Encryption.Algorithm",
    "Encryption.IntegrityMode", "Encryption.IV", "Encryption.Nonce",

    (* 判定駆動 metadata。個別キー列挙ではなく、サブ association 全体を認証する。 *)
    "Policy",
    "Derived",
    "MailMetadataPublic.DecisionState",
    "ReleasePolicy",
    "RecipientPolicyRef",
    "RecipientPolicy",
    "PublicKeyTrustState"
  },
  "Value" -> hmacHex
|>
```

MAC 鍵は暗号鍵と必ず分離する。`SourceVault:master:atrest:v1` を HMAC 鍵として流用してはならない。HKDF 派生を採用する場合は、少なくとも次のように用途別 `info` を固定する。

```text
HKDF(master, info="SourceVault at-rest encryption v1")
HKDF(master, info="SourceVault at-rest MAC v1")
HKDF(master, info="SourceVault plaintext digest HMAC v1")
```

ただし v4 の at-rest 実装既定は、実装単純性と監査性を優先して dedicated KeyRef とする。

```wl
$SourceVaultDefaultAtRestKeyRef    = "SourceVault:master:atrest:v1";
$SourceVaultDefaultAtRestMACKeyRef = "SourceVault:master:mac:v1";
```

`SourceVaultAtRestAuthenticatedBytes[v1]` は次を結合した canonical JSON bytes とする。

1. AAD association
2. IV / nonce / salt 等の暗号パラメータ
3. serialized ciphertext bytes の Base64 表現

これにより `Algorithm` / `IntegrityMode` / `KeyRef` / `PayloadCanonicalization` / `PayloadSerializationFormat` / `AuthenticatedBytesCanonicalization` / `IV` / `Nonce` の改ざんも HMAC mismatch として検出する。

同じ理由で、release / cloud-send / storage 判定を駆動する平文 metadata も AAD に含める。たとえば `Policy.CloudSendAllowed` を `False -> True` に反転する、`Derived.PrivacyLevel` を下げる、`AccessTags` を追加・削除する、`HeaderPL` を下げて平文ヘッダ化を誘発する、などの store-level 改ざんは、暗号 payload を壊さなくても判定を破壊する。

v13 では、将来 field の足し忘れを避けるため、`Policy.CloudSendAllowed` のような個別 path を列挙するのではなく、`Policy` / `Derived` / `MailMetadataPublic.DecisionState` / `ReleasePolicy` / `RecipientPolicy` / `PublicKeyTrustState` など **判定駆動サブ association 全体**を canonical JSON 化して AAD に入れる。新しい security-relevant field は、これらのサブ木に入れる限り自動的に認証対象になる。AAD に含められない field は enforcement の入力として信用してはならない。

#### optional: 認証付き暗号

AEAD / GCM が実測で利用可能な場合だけ、次を許す。

```wl
"IntegrityMode" -> "AuthenticatedEncryption"
"Algorithm" -> <|
  "Cipher" -> "AES256",
  "BlockMode" -> "GCM",
  "Resolved" -> True
|>
```

この場合も AAD には上記の暗号メタデータを渡す。AEAD の tag と AAD の保存形式は `SourceVaultCryptoCapabilityReport[]` に出す。

`CiphertextChecksum` は保存してよいが、意味は偶発破損検出に限定する。

```wl
"CiphertextChecksum" -> <|
  "Algorithm" -> "SHA256",
  "Value" -> checksumHex,
  "SecurityMeaning" -> "AccidentalCorruptionOnly"
|>
```

### 6.3 PlaintextDigest

生 SHA256 の `PlaintextHash` は使わない。代わりに `PlaintextDigest` とする。

```wl
"PlaintextDigest" -> <|
  "Mode" -> "HMAC-SHA256" | "Suppressed",
  "KeyRef" -> "SourceVault:pthmac:digest:v1" | Missing["Suppressed"],
  "Value" -> digestHex | Missing["Suppressed"],
  "StableAcrossKeyRotation" -> True | Missing["Suppressed"]
|>
```

高 privacy record では既定で抑制してよい。

```wl
"PlaintextDigest" -> <|
  "Mode" -> "Suppressed",
  "Reason" -> "HighPrivacyLowEntropyContent"
|>
```

rotation 検証は digest 依存にしない。digest がない場合は roundtrip 比較で検証する。

---

## 7. EncryptedVault record schema v3

最小 schema:

```wl
<|
  "Type" -> "SourceVaultEncryptedRecord",
  "SchemaVersion" -> 3,
  "RecordId" -> recordId,
  "CreatedAt" -> utcIsoDateTime,
  "UpdatedAt" -> utcIsoDateTime,
  "ContentType" -> "PromptRoute" | "NotebookCell" | "EvidenceBundle" | "Generic",

  "Encryption" -> <|
    "Backend" -> "WolframLanguageNative",
    "Mode" -> "SymmetricAtRest",
    "KeyRef" -> "SourceVault:master:atrest:v1",

    (* payload 自体の正規化。WL 式を含むローカル at-rest payload は Internal profile。 *)
    "PayloadCanonicalization" -> "SourceVaultCanonicalBytes/Internal/v1",
    "PayloadSerializationFormat" -> <|
      "Format" -> "WXF" | "BinarySerialize",
      "WolframVersion" -> wolframVersionString,
      "CompatibilityScope" -> "LocalAtRestOnly"
    |>,

    (* HMAC / AEAD の AAD 用 canonical bytes。これは JSON profile で固定。 *)
    "AuthenticatedBytesCanonicalization" -> "SourceVaultAtRestAuthenticatedBytes/v1",
    "SharedCanonicalization" -> Missing["NotShared"] | "SourceVaultCanonicalJSON/v1",

    "Algorithm" -> resolvedAlgorithmAssociation,
    "IntegrityMode" -> "EncryptThenMAC" | "AuthenticatedEncryption",
    "IV" -> ivOrMissing,
    "Nonce" -> nonceOrMissing,
    "Ciphertext" -> encryptedObjectOrSerializedCiphertext,
    "CiphertextEncoding" -> "Base64" | "EncryptedObject",
    "AuthenticatedAssociatedData" -> aadAssociation,
    "CiphertextChecksum" -> checksumAssociation,
    "CiphertextHMAC" -> hmacAssociation | Missing["ProvidedByAEAD"],
    "PlaintextDigest" -> plaintextDigestAssociation
  |>,

  "PlaintextIndex" -> <|
    "IndexPolicy" -> "Suppressed" | "PublicOnly" | "SafeTokensOnly",
    "PublicSummary" -> summaryOrMissing,
    "SearchTokens" -> tokensOrMissing,
    "SensitiveFields" -> {"Prompt", "Memo", "TargetExprString", "ResolvedMaterial"}
  |>,

  "Policy" -> <|
    "PrivacyLevel" -> privacyLevel,
    "CloudSendAllowed" -> False,
    "RequiresLocalDecrypt" -> True,
    "DeclassifyRequired" -> True,
    "ExportRequiresApproval" -> True,
    "ShareRequiresApproval" -> True
  |>,

  "Provenance" -> <|
    "Source" -> sanitizedSourceOrMissing,
    "RouteId" -> routeIdOrMissing,
    "CreatedBy" -> "SourceVaultEncryptedPut" | other
  |>,

  "MetadataLeakage" -> <|
    "PlaintextMetadataFields" -> {"RecordId", "CreatedAt", "ContentType", "Policy.PrivacyLevel"},
    "PotentiallySensitiveMetadataSuppressed" -> True | False
  |>
|>
```

`PayloadCanonicalization` と `AuthenticatedBytesCanonicalization` は別物である。前者は復号後に元 object を戻すための local payload encoding、後者は HMAC / AEAD の AAD を安定化するための JSON-based encoding である。1 つの `Canonicalization` field に両者を押し込めない。

### 7.1 metadata 漏洩境界

暗号化しても次の metadata は平文に残り得る。

- `RecordId`
- `CreatedAt` / `UpdatedAt`
- `ContentType`
- `PrivacyLevel`
- KeyRef 名
- public key fingerprint
- capsule recipient count

次は private record では既定で抑制する。

- notebook / file の完全パス
- prompt の語彙から作った search tokens
- public summary
- route memo
- target expression string
- collaborator memo

### 7.2 PlaintextIndex policy

```wl
SourceVaultPlaintextIndexPolicy[privacyLevel_, contentType_] :=
  "Suppressed" | "PublicOnly" | "SafeTokensOnly"
```

既定:

| 条件 | IndexPolicy |
|---|---|
| `PrivacyLevel >= $SourceVaultPrivateThreshold` | `"Suppressed"` |
| prompt / memo / target expression | `"Suppressed"` |
| public evidence bundle summary | `"PublicOnly"` |
| explicit declassified content | `"SafeTokensOnly"` |

---

## 8. SourceVaultEncryptedPut / Get

### 8.1 API

```wl
SourceVaultEncryptedPut[obj_, opts___]
SourceVaultEncryptedGet[recordId_String, opts___]
SourceVaultEncryptedRecordQ[record_]
SourceVaultDecryptRecord[record_, opts___]
```

主オプション:

```wl
"KeyRef" -> Automatic
"PlaintextDigest" -> Automatic | "Suppress" | "HMAC"
"PlaintextIndex" -> Automatic | "Suppress" | spec
"PrivacyLevel" -> Automatic
"ContentType" -> "Generic"
"AccessSpec" -> Automatic
"Purpose" -> "SourceVaultAtRestEncryption"
```

### 8.2 Put 手順

1. `SourceVaultCanonicalBytes[obj, "Internal"]` を得る。併せて `PayloadCanonicalization` と `PayloadSerializationFormat` を record に記録する。
2. record policy と判定駆動 metadata (`Policy`, `Derived`, mail header policy, release policy など)を決定する。これらは平文 metadata として保存する場合でも AAD に含める。
3. plaintext digest policy を決定する。
4. NBAccess に `NBEncryptWithKeyRef` を依頼する。
5. 暗号メタデータ、`PayloadCanonicalization`、`PayloadSerializationFormat`、`AuthenticatedBytesCanonicalization`、判定駆動 metadata、IV/nonce、ciphertext から `SourceVaultAtRestAuthenticatedBytes[v1]` を作る。
6. 既定では `NBMacWithKeyRef[$SourceVaultDefaultAtRestMACKeyRef, authenticatedBytes, ...]` で HMAC を付ける。AEAD 利用時も AAD を渡す。
7. `CiphertextChecksum` を計算する。ただし security decision に使わない。
8. private record では plaintext index を抑制する。
9. JSONL / registry / log へ append する前に、平文 payload が含まれていないことを `SourceVaultAssertNoPlaintextLeak` で検査する。

### 8.3 Get 手順

1. record schema と version を確認する。
2. `CiphertextHMAC` がある場合は、AAD association（暗号メタデータ + 判定駆動 metadata）+ IV/nonce + ciphertext を再 canonical 化して復号前に検証する。
3. AEAD の場合は復号時の認証失敗を `$Failed` として扱い、plaintext を返さない。
4. 復号 bytes を canonical object へ戻す。
5. 必要なら plaintext digest を再検証する。
6. 戻り値は呼び出し元の purpose に応じて制限する。cloud route 用の materialization は通常の Get では行わない。

### 8.4 失敗時の契約

- wrong key
- HMAC mismatch
- AEAD authentication failure
- schema version mismatch
- policy rejection

これらの場合、関数は plaintext を返さない。戻り値は次の形式にする。

```wl
<|
  "Status" -> "Error",
  "Reason" -> "AuthenticationFailed" | "WrongKey" | "PolicyDenied" | "UnsupportedVersion",
  "PlaintextReturned" -> False
|>
```


### 8.5 SourceVaultAssertNoPlaintextLeak

```wl
SourceVaultAssertNoPlaintextLeak[serializedRecordBytes_, plaintextObj_, sensitiveFields_List, opts___]
```

最低限の検査内容:

1. `Prompt`, `Memo`, `TargetExprString`, `ResolvedMaterial` など `sensitiveFields` に含まれる文字列値が、serialized JSONL / registry / log bytes に部分一致しない。
2. `SourceVaultCanonicalBytes[plaintextObj, "Internal"]` の Base64 表現、またはその主要部分が record の平文 field に現れない。
3. private prompt の場合、`PlaintextIndex.SearchTokens` と `PlaintextIndex.PublicSummary` が `Missing` または抑制済みである。
4. 検査に失敗した場合は record を append せず、`PlaintextPersisted -> False`, `Reason -> "PlaintextLeakDetected"` を返す。

この検査は暗号そのものの代替ではなく、実装ミスによる二重保存・debug 出力混入を防ぐ防御的二重化である。


### 8.6 判定駆動 metadata の更新契約

`Policy` / `Derived` / `MailMetadataPublic.DecisionState` / `ReleasePolicy` / `RecipientPolicy` / `PublicKeyTrustState` のような field は、record の encrypted payload そのものではない場合でも、cloud-send / storage / mail release の判定を直接変える。したがって、これらを後から更新する処理は通常の JSONL patch ではなく、認証付き record update として扱う。

```wl
SourceVaultUpdateAuthenticatedRecordPolicy[recordId_, changes_Association, opts___]
SourceVaultVerifyRecordPolicyIntegrity[record_, opts___]
SourceVaultClassifyPolicyUpdate[current_, proposed_]  (* "Tightening" | "Loosening" | "Neutral" *)
```

#### update の方向分類

`SourceVaultUpdateAuthenticatedRecordPolicy` は、まず変更を **tightening / loosening / neutral** に分類する。分類器は conservative でなければならない。既知の tightening または明白な neutral 以外、未知 field の追加・削除、意味論未定義の tag 変更、tightening と loosening の混在 delta は、すべて **Loosening** として扱う。

```text
Tightening examples:
  PrivacyLevel を上げる
  HeaderPL を上げる
  CloudSendAllowed を False にする
  RequiresLocalDecrypt を True にする
  DeclassifyRequired を True にする
  AccessTags を削除する
  DenyTags を追加する
  Recipient MaxPlaintextPL / MaxEncryptedReadablePL を下げる
  PublicKey TrustStatus を Verified から TOFU / Unverified / Revoked に下げる

Loosening examples:
  PrivacyLevel / HeaderPL を下げる
  CloudSendAllowed を True にする
  RequiresLocalDecrypt / DeclassifyRequired を False にする
  AccessTags を追加する
  DenyTags を削除する
  HeaderPolicy を EncryptedHeader から PlainHeaderAllowed / MixedHeader に下げる
  Recipient MaxPlaintextPL / MaxEncryptedReadablePL を上げる
  PublicKey TrustStatus を Verified / VerifiedOutOfBand に上げる
  manual declassification を確定する
```

Tightening は agent が自動実行してよい。Loosening は、baseline activation と同じく **agent の action space 外の人間承認 + audit** を必須にする。prompt-injection された agent が正規 API 経由で `PrivacyLevel -> 0.1` や `CloudSendAllowed -> True` を適用しようとしても、承認 artifact が無ければ pending state に留め、active policy として採用してはならない。

```wl
SourceVaultRequestRecordPolicyLoosening[recordId_, proposedChanges_, reason_, opts___]
SourceVaultApproveRecordPolicyLoosening[pendingId_, approvalToken_, opts___]
SourceVaultRejectRecordPolicyLoosening[pendingId_, reason_, opts___]
```

`approvalToken` は agent が生成・改ざんできる Notebook cell だけで完結してはならない。OS credential prompt、別プロセス確認、out-of-band fingerprint 入力、または NBAccess の user-presence gate など、agent の通常 tool / expression 実行空間から到達できない経路を使う。

approval token は承認対象の変更に暗号的に束縛する。承認 challenge は少なくとも次を canonical JSON で含め、OS credential / user-presence gate 側で署名または MAC する。token は single-use であり、期限切れ・nonce 再利用・baseline mismatch・delta digest mismatch の場合は拒否する。

```wl
<|
  "Type" -> "SourceVaultRecordPolicyLooseningApprovalChallenge",
  "RecordId" -> recordId,
  "TargetPolicyRevision" -> proposedRevision,
  "CanonicalDeltaDigest" -> digestOfCanonicalProposedDelta,
  "CurrentPolicyHeadDigest" -> currentHeadDigest,
  "ActiveBaselineDigest" -> activeBaselineDigest,
  "Nonce" -> nonce,
  "ExpiresAt" -> utcIsoDateTime,
  "RequestedBy" -> actorDescriptor,
  "Reason" -> reason
|>
```

`ApprovalRef` はこの challenge digest と token id を参照し、別の delta・別の record・別の baseline へ流用できない。

#### 更新 commit 方式

v12 では、derived batch が 1 通ごとに HMAC 再計算と generation rewrite を行う読み方が可能だった。これは checkpoint 毎通と組み合わさると O(N^2) I/O になり得る。v13 の既定は、mutable policy を **append-only authenticated policy delta log** として扱う。

```wl
SourceVaultAppendAuthenticatedPolicyDelta[recordId_, delta_Association, opts___]
SourceVaultResolveAuthenticatedPolicyState[recordId_, opts___]
SourceVaultCompactAuthenticatedPolicyState[recordId_, opts___]
```

policy delta entry は次を持つ。

```wl
<|
  "Type" -> "SourceVaultPolicyDelta",
  "SchemaVersion" -> 1,
  "RecordId" -> recordId,
  "PolicyRevision" -> n,
  "PreviousPolicyStateDigest" -> prevDigest,
  "BaselineDigest" -> activeBaselineDigest,
  "UpdateClass" -> "Tightening" | "Loosening" | "Neutral",
  "ApprovalRef" -> approvalRef | Missing["NotRequired"],
  "ChangedSubtrees" -> {"Policy", "Derived", "MailMetadataPublic.DecisionState", ...},
  "CanonicalDecisionState" -> canonicalDecisionStateDigest,
  "CreatedAt" -> utcIsoDateTime,
  "Actor" -> actorDescriptor,
  "CanonicalDeltaDigest" -> digestOfCanonicalDelta,
  "ApprovalChallengeDigest" -> approvalChallengeDigest | Missing["NotRequired"],
  "Nonce" -> nonce,
  "HMAC" -> hmacOverDeltaAndPreviousDigest
|>
```

`SourceVaultResolveAuthenticatedPolicyState` は、base record の初期 decision state と delta log chain を検証し、単調 `PolicyRevision` と `PreviousPolicyStateDigest` を確認した上で最新 state を返す。chain 破損、rollback、missing delta、承認無し loosening は fail-closed とする。

monolithic JSONL generation rewrite は、初回確立・payload 変更・periodic compaction・migration では使ってよいが、derived batch の通常 commit では既定にしない。checkpoint は進捗 append、policy delta は認証済み状態 append、compaction は別処理に分離する。


#### compaction の安全条件

`SourceVaultCompactAuthenticatedPolicyState` は delta chain を短くする最適化であり、policy を変更するための API ではない。compaction は次をすべて満たす場合だけ成功する。

1. `SourceVaultResolveAuthenticatedPolicyState[recordId, "BeforeCompaction"]` と compaction 後の resolved state が完全に一致する。
2. compaction artifact は authenticated record として HMAC / signature を持つ。
3. policy head manifest の `ManifestRevision` を進め、対象 record の `LatestPolicyRevision` / `HeadStateDigest` を compaction 後 head に更新する。
4. compaction によって `UpdateClass` が Loosening になる場合は拒否する。compaction が state を緩めることはない。
5. compaction 前の delta chain を quarantine / audit へ移す場合も、削除済み delta による rollback が起きないよう manifest head を先に更新し、検証済み cache を invalidation する。

#### stale baseline 下の delta 再評価

policy delta entry は `BaselineDigest` を持つ。current active baseline digest と delta の `BaselineDigest` が異なる場合、`SourceVaultResolveAuthenticatedPolicyState` はその state をそのまま trusted とせず、`RequiresReevaluation -> True` を返す。特に古い baseline 下で承認された Loosening は、current baseline 下で再評価し、必要なら再承認を要求する。baseline が tightening された場合、古い Loosening が自動的に維持されてはならない。

#### verified policy state cache

release / cloud / storage 判定の hot path では delta chain 全体を毎回検証しない。`SourceVaultResolveAuthenticatedPolicyState` は、`{RecordId, PolicyRevision, HeadStateDigest, PolicyHeadManifestDigest, BaselineDigest}` を key とする verified in-memory cache を使ってよい。新しい delta append、head manifest update、baseline update、TTL 経過、file watcher invalidation により cache を破棄する。cache hit であっても、manifest digest / baseline digest が pinned value と一致しない場合は fail-closed とする。

#### 初回 write と update の区別

legacy maildb migration 直後や初回 import では、まだ authenticated record が存在しない。この場合は `SourceVaultEncryptedPut` / `SourceVaultEstablishAuthenticatedRecord` が初回の HMAC / initial policy state を確立する。既存 authenticated record の update は、必ず current record / current policy chain の検証を通してから delta を append する。

```wl
SourceVaultEstablishAuthenticatedRecord[obj_, opts___]
SourceVaultUpdateAuthenticatedRecordPolicy[recordId_, changes_, opts___]
```

前者は新規確立、後者は検証済み record の更新であり、migration が「現行 HMAC が無いから update できない」状態で詰まらないよう分離する。

#### enforcement 契約

`SourceVaultInferMailDerivedBatch`、`SourceVaultReclassifyMailHeaderRecord`、tag policy migration、manual declassification、recipient profile 更新、public key trust 更新はすべてこの経路を通す。prompt-injection された agent が JSONL を直接編集して `CloudSendAllowed -> True` や `PrivacyLevel -> 0.1` へ変更しても HMAC mismatch で fail-closed し、正規 API で同じ loosening を試みても agent 外承認がなければ active state にならない。

---

## 9. PromptRouter `Encrypt -> True`

### 9.1 新しい挙動

```wl
SourceVaultSaveLastPrompt[..., "Encrypt" -> True, "KeyRef" -> Automatic]
```

処理:

1. prompt route の保存対象を canonical association にまとめる。
2. `Prompt`, `Memo`, `TargetExprString`, `ResolvedMaterial` などの機密 field を encrypted payload に移す。
3. record metadata には非機密の route ID、created time、storage class、policy だけを保存する。
4. `PromptStorageClass -> "Encrypted"` を設定する。
5. private prompt で `Encrypt -> False` の場合、既定で拒否する。互換 mode では明示承認付き warning とする。
6. `SaveLastPrompt` の戻り値に `PlaintextPersisted -> False` を含める。

### 9.2 追加 API

```wl
SourceVaultDecryptPromptRoute[routeId_String, opts___]
SourceVaultMaterializePromptRoute[routeId_String, targetRoute_, opts___]
SourceVaultSearchEncryptedPromptRoutes[query_, opts___]
```

### 9.3 cloud 送信経路の強制配線

cloud LLM へ plaintext を渡す唯一経路で、次を必ず評価する。

```wl
SourceVaultAuthorizeRecordMaterialization[record_, targetRoute_, purpose_, accessSpec_: Automatic]
```

判定条件:

1. `record["Policy", "CloudSendAllowed"] === True`
2. cloud route の場合は `record["Policy", "RequiresLocalDecrypt"] =!= True` である
3. privacy level が cloud threshold 以下
4. `Declassify` または明示承認 ticket がある
5. NBAccess の `NBAuthorize` が Permit を返す

上記のいずれかに失敗した場合、PromptRouter は cloud route に plaintext を渡してはならない。

---


## 10. 保管先連動の Notebook / SourceVault 保護ポリシー

### 10.1 基本モデル

Notebook front end 上の未保存・復号済みセルは、原則として `MemoryPlaintextPL -> 1.00` の環境にあるとみなす。ファイル保存、SourceVault record 化、Dropbox 同期フォルダへのコピー、Claude Code readable workspace への配置は、すべて **メモリ上の高 PL 平文を、保存先の低いアクセス境界へ移動する操作**として扱う。

したがって、保存判定は次の形に統一する。

```text
For each payload or cell:
  dataPL = SourceVaultDataPrivacyLevel[payload]
  dest = SourceVaultStorageProfile[targetPathOrRoute]
  If dataPL <= dest.MaxPlaintextPL:
      plaintext write may be allowed
  Else:
      plaintext write is forbidden
      write encrypted placeholder / encrypted record instead
```

このモデルでは、Notebook をセル単位に別ファイルへ分離する必要はない。高 PL セルは、同じ Notebook 内で encrypted cell placeholder に置換して保存するか、sidecar SourceVault record に暗号化保存し、Notebook には復号に必要な `RecordId` / `KeyRef` / `Digest` / metadata のみを残す。

### 10.2 StorageProfile

保存先は単なる path ではなく、観測者・外部同期・agent readable 性を含む profile として扱う。

```wl
SourceVaultStorageProfile[pathOrRoute_, opts___] := <|
  "Path" -> absolutePathOrRoute,
  "StorageClass" -> "Memory" | "LocalAudited" | "LocalUnchecked" | "CloudStorage" | "CloudLLMNoTraining" | "CloudLLMTrainingAllowed" | "AgentReadableWorkspace" | "PackageDirectory",
  "BasePL" -> 1.00 | 0.90 | 0.75 | 0.65 | 0.45 | 0.20,
  "MaxPlaintextPL" -> effectivePlaintextThreshold,
  "ExternalStorage" -> "None" | "CloudStorage" | "CloudProcessor" | "AgentWorkspace",
  "TrainingUse" -> "None" | "Disabled" | "ContractuallyDenied" | "Allowed" | "Unknown",
  "RetentionRisk" -> "Low" | "Medium" | "High",
  "HumanReviewRisk" -> "Low" | "Medium" | "High",
  "LocalSecurity" -> "Audited" | "Checked" | "Unchecked",
  "Observers" -> {...},
  "CloudSyncDetected" -> True | False,
  "AgentReadable" -> True | False,
  "RequiresProtectedWrite" -> True | False,
  "Reason" -> {...}
|>
```

代表値は次を既定値にする。

```wl
$SourceVaultDefaultStoragePL = <|
  "CloudLLMTrainingAllowed" -> 0.20,
  "CloudLLMNoTraining" -> 0.45,
  "CloudStorage" -> 0.65,
  "LocalUnchecked" -> 0.75,
  "LocalAudited" -> 0.90,
  "Memory" -> 1.00
|>;
```

`EffectivePL` は単純な path 種別だけで決めない。例えば Dropbox 配下かつ Claude Code / cloud agent が workspace として読む path なら、`CloudStorage -> 0.65` と `CloudLLMNoTraining -> 0.45` の低い方を採用し、`MaxPlaintextPL -> 0.45` とする。

### 10.3 path / route 判定

最低限、次を検出する。

```wl
SourceVaultCloudSyncPathQ[path_]      (* Dropbox / OneDrive / Google Drive / iCloud Drive 等 *)
SourceVaultPackageDirectoryQ[path_]   (* $packageDirectory または登録済み package dir *)
SourceVaultAgentReadablePathQ[path_]  (* Claude Code / Codex / external agent readable workspace *)
SourceVaultAuditedLocalPathQ[path_]   (* 明示的に監査済み local vault *)
```

`$packageDirectory` が Claude Code から読み書き可能である場合、ローカルディレクトリであっても `AgentReadableWorkspace` とみなし、平文保存 threshold を cloud LLM route 相当に下げる。これにより、「ローカル path だから安全」という誤判定を避ける。

### 10.4 protected Notebook 表現

高 PL セルを含む Notebook を低 PL 保存先へ置く場合、保護方式は次の 2 種類を許す。

| 方式 | 内容 | 用途 |
|---|---|---|
| `InlineEncryptedCell` | 暗号化された `Cell[...]` payload を Notebook 内 placeholder に直接埋め込む | Dropbox 等で notebook 単体を持ち運びたい場合 |
| `SidecarEncryptedRecord` | 暗号化 payload は SourceVault record に置き、Notebook には `RecordId` と復号 metadata のみを残す | SourceVault 管理下の研究 notebook / 大容量 output |

placeholder の例:

```wl
Cell[
  BoxData @ ToBoxes @ SourceVaultEncryptedCell[
    <|
      "RecordId" -> recordId,
      "CellUUID" -> cellUUID,
      "OriginalCellStyle" -> style,
      "PrivacyLevel" -> cellPL,
      "ProtectionMode" -> "InlineEncryptedCell" | "SidecarEncryptedRecord",
      "PayloadDigest" -> digest,
      "KeyRef" -> keyRef,
      "CreatedAt" -> utcIsoDateTime
    |>
  ],
  "SourceVaultEncrypted",
  CellTags -> {"SourceVaultEncrypted", "PL:" <> ToString[cellPL]}
]
```

暗号化 payload には、元の `Cell[...]` 全体を入れる。ただし placeholder 側に残す metadata は最小化し、`PublicSummary` や `SearchTokens` は private cell では既定 `Missing` とする。

### 10.5 保護保存 API

主 API は Save menu hook ではなく、明示的な protected save とする。

```wl
SourceVaultProtectionPlan[nb_NotebookObject | notebookExpr_, targetPath_String, opts___]
SourceVaultProtectNotebookForStorage[nb_NotebookObject | notebookExpr_, targetPath_String, opts___]
SourceVaultSaveProtectedNotebook[nb_NotebookObject, targetPath_: Automatic, opts___]
SourceVaultUnprotectNotebook[nb_NotebookObject, opts___]
SourceVaultNotebookProtectionReport[nb_NotebookObject | file_String, opts___]
NBAccessAuthorizeStorageWrite[payloadOrPlan_, storageProfile_Association, opts___]
```

`SourceVaultSaveProtectedNotebook` は既定で `ProtectedCopy` mode とする。

1. 現在の Notebook expression を取得する。
2. 保存先 `StorageProfile` を計算する。
3. cell ごとに PL と destination threshold を比較する。
4. threshold を超える cell を encrypted placeholder に置換した protected expression を作る。
5. 元の編集中 Notebook はメモリ上で平文のまま維持する。
6. protected expression から不可視一時 notebook を作り、指定 path へ保存する。
7. 一時 notebook を閉じる。
8. 保存結果に対して `SourceVaultAssertNoPlaintextLeak` を走らせる。

この `ProtectedCopy` mode では、ユーザーの編集中 Notebook を破壊しない。ただし保存先の `.nb` は保護済み表現になる。

必要に応じて、現在の Notebook 自体を encrypted placeholder に置換する `InPlaceSeal` mode も提供できるが、これは操作ミス時の可逆性・Undo stack・Notebook history の問題があるため既定にしない。

### 10.6 Save menu hook の扱い

Wolfram front end には `NotebookEventActions` / `FrontEndEventActions` によるイベント処理と、`FrontEndToken["Save"]` による File > Save 相当の操作がある。したがって、実装候補としては次を考えられる。

```wl
SourceVaultSaveHookCapabilityReport[]
SourceVaultInstallProtectedSaveHook[nb_NotebookObject, opts___]
SourceVaultUninstallProtectedSaveHook[nb_NotebookObject]
```

ただし、Save menu hook は次の理由で **security boundary にはしない**。

- NotebookEventActions / FrontEndEventActions は front end event を扱う UX 機構であり、すべての保存経路を保証するものではない。
- `NotebookSave[nb, file]`、外部ファイルコピー、同期クライアント、クラッシュ復元、autosave、別プロセスによる書き込みを捕捉できない可能性がある。
- Save As は target path が UI dialog 後に決まるため、hook 側で保存前 profile を確実に評価しにくい。
- global FrontEndEventActions は他 notebook に副作用を及ぼしやすい。

したがって、hook は capability probe 済み環境でのみ **補助 UX** として使う。仕様上の主経路は次である。

```text
ClaudeCode palette button:
  - 保護して保存
  - 保護コピーを別名保存
  - 現在の保存先の StorageProfile を診断
  - Notebook 内の高 PL 平文セルを検査
```

hook を実装する場合の条件:

1. notebook-level hook を優先し、global hook は既定禁止。
2. `{"MenuCommand", "Save"}` / `{"MenuCommand", "SaveRename"}` / `"WindowClose"` を capability test で確認する。
3. `PassEventsDown -> False` 相当で通常保存を一度止め、protected save 成功後にのみ通常保存または protected copy save を行う。
4. recursion 防止 flag (`$SourceVaultProtectedSaveInProgress`) を使う。
5. hook 失敗時に平文保存へ silent fallback しない。必ず warning / abort / palette 誘導にする。

### 10.7 自動 scanner と Doctor

Save hook だけに依存しないため、定期 scanner / Doctor を追加する。

```wl
SourceVaultScanNotebookStorageRisk[roots_: Automatic, opts___]
SourceVaultFindPlaintextHighPLNotebooks[roots_, opts___]
SourceVaultStorageDoctor[]
```

検査項目:

- Dropbox / OneDrive / Google Drive / iCloud Drive / `$packageDirectory` / agent workspace 配下にある `.nb` を列挙する。
- Notebook expression を読み、PL option / CellTags / SourceVault metadata から高 PL セルを検出する。
- `dataPL > StorageProfile.MaxPlaintextPL` なのに plaintext cell が残る file を warning / fail にする。
- encrypted placeholder は HMAC / signature / digest を検証する。
- protected notebook の sidecar record が存在し、復号可能かを検査する。
- Undo / NotebookHistory / CellChangeTimes / cached output など、平文残存の可能性がある領域を warning として出す。

### 10.8 実装上の注意

1. **Notebook history / undo / cache**: protected copy mode は元 notebook の undo stack を保存先へ持ち込まないようにする。in-place mode では undo stack や Notebook history に平文が残る可能性があるため、既定禁止または強い warning とする。
2. **Output cell**: 秘密計算結果が output cell に出ている場合、input cell だけでなく output cell も PL 判定対象にする。
3. **CellChangeTimes / metadata**: timestamp や file path も漏洩になり得る。高 PL cell の metadata は必要最小限にする。
4. **sidecar 紛失**: sidecar mode では notebook 単体では復号できない。Dropbox へ送る用途では inline mode を既定にする。
5. **multi-user 共有**: 他者と notebook を共有する場合は、protected notebook 内の encrypted cell を capsule に変換し、受信者 public key で開けるようにする。
6. **Claude Code readable workspace**: agent が読む可能性のある path では、単なる cloud storage より低い `MaxPlaintextPL` を適用する。


### 10.9 将来拡張: MailDB / IMAP 一時ソースと SourceVault snapshot

#### 10.9.1 方針

`maildb.wl` は当面は独立パッケージとして残してよい。ただし SourceVault 側には compatibility adapter を置き、maildb の月次 DB / IMAP 取得結果 / 添付ファイル / embedding index を **SourceVault source snapshot** として扱う。

重要なのは、IMAP server を永続的な SourceVault store と見なさないことである。IMAP は変化する外部一時ソースであり、SourceVault は次を保持する。

- いつ、どの mbox から、どの UID / Message-ID / thread を観測したか。
- その時点の header / body / attachment / derived summary / embedding の snapshot。
- どの LLM / embedding model / prompt / privacy policy により `summary`, `priority`, `privacy`, `tags` が生成されたか。
- 元メール本文や添付を平文で保持するか、暗号化保持するか、metadata のみ保持するか。

#### 10.9.2 Mail source record schema

SourceVault 側では、既存 maildb record を次の schema に正規化する。重要な変更点は、**メールヘッダも保存先 access boundary に対する materialization として扱う**ことである。Subject / From / To / Cc / MessageID は本文と同程度、または本文以上に機密になり得るが、Dropbox 等の CloudStorage 境界では通常メールの件名を常に暗号化すると検索性を失う。したがって、未分類時は fail-closed に encrypted header とし、PL 推定後は `StorageProfile.MaxPlaintextPL` 由来の `HeaderPlaintextThreshold` 以下のヘッダだけを平文化できる。閾値超、低 confidence、tag deny の場合は encrypted payload 側へ移し、平文側には keyed HMAC token と低漏洩 metadata だけを置く。

```wl
<|
  "Type" -> "SourceVaultMailSnapshot",
  "SchemaVersion" -> 2,
  "RecordId" -> hmacRecordId,              (* HMAC[mailIdentityKey, {mbox, MessageID}] *)

  "MailSource" -> <|
    "Kind" -> "IMAP" | "MaildbMonthlyFile",
    "MBox" -> mbox,
    "AccountRef" -> accountRef,
    "CredentialKeyRef" -> credentialKeyRef,
    "ServerHostDigest" -> keyedHostDigest,
    "UIDValidity" -> uidValidity | Missing["Unavailable"],
    "UID" -> uid | Missing["Unavailable"],
    "MessageIDToken" -> keyedMessageIdToken,
    "ThreadID" -> threadId | Missing["SourceHeaderUnavailable"] | Missing["NotParsed"],
    "FetchedAt" -> utcIsoDateTime,
    "SnapshotRange" -> {startUTC, endUTC},
    "RawMIMEStatus" -> "NotStored" | "Encrypted" | "UnavailableFromMaildb"
  |>,

  "MailMetadataPublic" -> <|
    "Date" -> dateUTC | Missing["Unknown"],
    "HeaderPolicy" -> "ProvisionalEncryptedHeader" | "EncryptedHeader" | "PlainHeaderAllowed" | "MixedHeader",
    "HeaderPlaintextThreshold" -> headerThreshold,
    "HeaderPlaintextRationale" -> "StorageThreshold" | "ManualOverride" | Missing["NotAllowed"],
    "HeaderPL" -> headerPL | Missing["NotGenerated"],
    "HeaderConfidence" -> confidence | Missing["Unknown"],
    "HeaderFieldPolicy" -> <|
      "Subject" -> "Plain" | "Encrypted" | "TokenOnly",
      "From" -> "Plain" | "Encrypted" | "TokenOnly",
      "ToCc" -> "Plain" | "Encrypted" | "TokenOnly",
      "MessageID" -> "TokenOnly" | "Encrypted"
    |>,
    "PlainHeader" -> <|
      "Subject" -> subject | Missing["Encrypted"],
      "From" -> fromAddress | Missing["Encrypted"],
      "To" -> toAddresses | Missing["Encrypted"],
      "Cc" -> ccAddresses | Missing["Encrypted"]
    |>,
    "FromToken" -> keyedAddressToken | Missing["Suppressed"],
    "ToTokens" -> {keyedAddressToken ...} | Missing["Suppressed"],
    "CcTokens" -> {keyedAddressToken ...} | Missing["Suppressed"],
    "SubjectToken" -> keyedSubjectToken | Missing["Suppressed"],
    "SubjectPreview" -> publicSubjectPreview | Missing["Suppressed"],  (* 高 PL mail では必ず Suppressed *)
    "AttachmentCount" -> n,
    "HasBody" -> True | False
  |>,

  "EncryptedHeaderRef" -> encryptedHeaderRecordRef | Missing["PlainHeaderAllowed"],

  "Derived" -> <|
    "SummaryRef" -> encryptedSummaryRef | plaintextSummaryRef | Missing["NotGenerated"],
    "Priority" -> priority | Missing["NotGenerated"],
    "PrivacyLevel" -> importedOrInferredPL,
    "PrivacyConfidence" -> confidence | Missing["Unknown"],
    "AccessTags" -> tags,
    "SummaryEmbeddingRef" -> encryptedEmbeddingRef | memoryOnlyIndexRef | Missing["Suppressed"],
    "BodyEmbeddingRef" -> encryptedEmbeddingRef | memoryOnlyIndexRef | Missing["Suppressed"],
    "DerivedFieldPolicy" -> <|
      "SummaryGenerationRoute" -> "LocalOnly" | "CloudGeneratedHistorical" | "NotGenerated",
      "EmbeddingGenerationRoute" -> "LocalOnly" | "CloudGeneratedHistorical" | "NotGenerated",
      "CloudGeneratedBeforeSourceVault" -> True | False
    |>
  |>,

  "PayloadRefs" -> <|
    "Body" -> encryptedBodyRecordRef | redactedBodyRef | Missing["NotStored"],
    "RawMIME" -> encryptedMimeRecordRef | Missing["NotStored"],
    "Attachments" -> {attachmentRecordRef ...}
  |>,

  "Policy" -> <|
    "CloudSendAllowed" -> False,
    "RequiresLocalDecrypt" -> True,
    "ReleaseRequiresPlan" -> True,
    "DefaultPlaintextBodyAllowed" -> False,
    "HeaderPlaintextPolicy" -> "StorageThreshold",
    "HeaderPlaintextDefault" -> "ProvisionalEncryptedUntilPLKnown",
    "HeaderTokenization" -> "HMAC-SHA256",
    "MetadataLeakageClass" -> "MailHeaderSensitive",
    "MaildbPrivacyIsAuthoritative" -> False
  |>,

  "Provenance" -> <|
    "ImportedBy" -> "MaildbAdapter" | "IMAPAdapter",
    "OriginalMaildbFields" -> {"id","date","subject","from","to","body","summary","priority","privacy","embedding","summarytagembedding","attachment"},
    "OriginalMaildbPrivacy" -> 0 | 1 | Missing["Unknown"],
    "MaildbPackageVersion" -> version | Missing["Unknown"],
    "BodyTruncatedByMaildb" -> True | False | Missing["Unknown"],
    "CloudDerivedFieldsPresent" -> True | False,
    "CloudDerivedProvider" -> provider | Missing["Unknown"]
  |>
|>
```

`maildb.wl` の既存 DB から import する場合、`UID` / `UIDValidity` / `ThreadID` / `RawMIME` は原則として取得できない。したがって、既存 maildb import では **Message-ID token を正準 identity** とする。既存 DB は `In-Reply-To` / `References` を保持していないため、`ThreadID` は単なる未解析ではなく `Missing["SourceHeaderUnavailable"]` とし、補完には新規 IMAP fetch が必要である。`RawMIME` の忠実な snapshot が必要な場合も、SourceVault 側で新規 IMAP fetch ロジックを実装する。

PL 未確定 mail では `HeaderPolicy -> "ProvisionalEncryptedHeader"` とし、`SubjectPreview` を `Missing["Suppressed"]` に固定する。PL 推定後、`headerPL <= HeaderPlaintextThreshold` かつ `PrivacyConfidence` が十分で、tag policy が header plaintext を拒否しない場合だけ、`PlainHeaderAllowed` または `MixedHeader` として subject 等の平文 index を許す。閾値超、低 confidence、`NoEmail` / `NoExternal` / `StudentPrivate` 等の deny tag がある場合は encrypted header を維持する。

具体的なメールアドレス、IMAP password、app password、credential value は record に保存しない。既存 maildb の mbox 設定に含まれる credential key 名も、SourceVault では `KeyRef` / `CredentialKeyRef` として扱い、Doctor では「鍵材料ではない参照名」として検査する。

`RecordId` と header token は `SourceVault:mailid:mac:v1` による keyed HMAC で生成する。この鍵は equality search / dedup の安定性に関わるため rotation-stable とし、通常の鍵 rotation から除外する。鍵漏洩時は token 辞書照合リスクがあるため、鍵材料は credential store のみに置き、record / JSONL / 同期フォルダには絶対に保存しない。

#### 10.9.3 添付ファイル、summary、embedding の扱い

添付ファイル、メールヘッダ、summary、embedding は本文と別の漏洩面を持つ。特に **summary / embedding の生成そのものが materialization** である。private mail の本文を cloud embedding API や cloud summarizer に送ることは、保存前に既に外部送信したことを意味する。

| 対象 | 既定 |
|---|---|
| header (`Subject` / `From` / `To` / `Cc` / `MessageID`) | import 時は provisional encrypted。PL 推定後に `headerPL <= HeaderPlaintextThreshold` なら subject 等を平文化可能。閾値超・低 confidence・deny tag では encrypted header + HMAC token を維持 |
| raw body | 高 PL なら `SourceVaultEncryptedPut`。低 PL でも cloud route 直前で再評価 |
| raw MIME | 既定 `NotStored` または encrypted only。既存 maildb からは復元不能な場合がある |
| attachment | encrypted attachment record。filename も HMAC / redacted。既存平文 filename は migration / quarantine / rename 対象 |
| summary | body より低 PL とは限らない。summary も独立に PL / tags を持つ。private summary 生成は local only |
| embedding | 内容の近似漏洩源であり、生成も materialization。private mail の embedding は local embedding のみ、at-rest encrypted、検索時だけ memory index |
| summarytagembedding | 固有名詞を含むため `PlaintextIndex` policy の対象。既存 cloud-generated vector は provenance と warning を残す |

既存 maildb に保存済みの cloud-generated embedding / summary は、SourceVault へ取り込んでも遡及的に安全にはならない。import 時には `CloudGeneratedBeforeSourceVault -> True` を記録し、Doctor は private mail の cloud-derived field を warning する。可能なら次で local 再生成する。

```wl
SourceVaultMigrateMaildbToSourceVault[
  mbox,
  "RegenerateSummaries" -> "LocalOnly",
  "RegenerateEmbeddings" -> "LocalOnly",
  "DropCloudGeneratedEmbeddings" -> True
]
```

private embedding の検索は、maildb の in-memory KDTree パターンを踏襲してよい。ただし、平文 vector は永続化しない。

```wl
SourceVaultBuildMailEmbeddingIndex[
  mbox,
  "DecryptUnderNBAccess" -> True,
  "Persistence" -> "MemoryOnly",
  "CacheLifetime" -> "Session",
  "AllowSwapPersistence" -> False
]
```

復号済み embedding index は NBAccess gate 下のメモリ上 cache としてだけ保持し、明示的な破棄 API を持つ。長期 cache や disk-backed nearest index は既定禁止とし、性能上必要な場合も OS swap / temp file / crash dump への漏洩を Doctor が警告する。

mail body / header / attachment は `DefaultImportedMailPL -> 0.85` であっても、保存先 PL に関わらず既定では encrypted record として import する。監査済みローカル保存先だから平文保存してよい、という例外を mail 本文には既定で設けない。

#### 10.9.4 StorageProfile 連動のヘッダ policy と再封印

メールヘッダの平文保存可否は、本文の private threshold だけでなく、保存先 `StorageProfile` の access boundary に連動させる。

```wl
SourceVaultMailHeaderProtectionPlan[snapshot_, mailStoreRoot_, opts___]
SourceVaultReclassifyMailHeaders[mbox_String, opts___]
SourceVaultMailHeaderPlaintextThreshold[mailStoreRoot_, opts___]
```

既定判定は次である。

```text
store = SourceVaultStorageProfile[mailStoreRoot]
headerThreshold = Min[
  store.MaxPlaintextPL,
  OptionValue["MaxHeaderPlaintextPL"] /. Automatic -> store.MaxPlaintextPL
]

If Derived.PrivacyLevel is Missing:
    HeaderPolicy = "ProvisionalEncryptedHeader"
Else if EffectiveHeaderPL <= headerThreshold
        and NumericQ[HeaderConfidence]
        and HeaderConfidence >= $SourceVaultMailHeaderMinConfidence
        and SourceVaultTagPolicyEvaluate[..., Purpose -> "HeaderPlaintext"] passes:
    HeaderPolicy = "PlainHeaderAllowed" or "MixedHeader"
Else:
    HeaderPolicy = "EncryptedHeader"
```

`EffectiveHeaderPL` は、`HeaderPL` が生成済みならそれを使い、未生成で `PrivacyLevel` が十分な confidence 付きで生成済みなら保守的に `PrivacyLevel` を使ってよい。ただし `HeaderConfidence` が `Missing`、非数値、または `$SourceVaultMailHeaderMinConfidence` 未満の場合は fail-closed とし、平文化しない。既定は次である。

```wl
$SourceVaultMailHeaderMinConfidence = 0.70;
```

`HeaderPL` は本文 PL とは別に生成する。件名・送受信者・MessageID・添付ファイル名など header だけを入力にした軽量 local inference を優先し、これが利用できない場合だけ `PrivacyLevel` への fallback を許す。

Dropbox / OneDrive のような `CloudStorage` profile では、既定 `MaxPlaintextPL` をおおむね `0.65` とみなし、通常メールの件名は平文検索できる余地を残す。一方、Claude Code readable workspace、agent temporary workspace、cloud LLM input cache のような低い境界では threshold が下がり、同じ mail snapshot でも再封印が必要になる。

`HeaderFieldPolicy` は per-field にしてよい。最低限の既定は次である。

| Field | 既定 |
|---|---|
| `Subject` | `headerPL <= threshold` なら plain 可。検索性を優先する主対象。 |
| `From` | domain / address が低 PL なら plain 可。慎重設定では token のみ。 |
| `To` / `Cc` | 社会的関係グラフを露出するため、既定は token。明示設定で plain 可。 |
| `MessageID` | 既定 token only。平文 Message-ID は保存しない。 |

平文許可は「Dropbox 等の保存先を一定程度信頼した risk acceptance」として監査対象にする。record には `HeaderPlaintextThreshold`、`HeaderPlaintextRationale`、`StorageProfileId`、`HeaderPolicyHistory` を残す。保存先がより低い境界へ移動した場合、Doctor は threshold 超過の plain header を検出し、`SourceVaultReclassifyMailHeaders` による再封印を促す。

PL が後から確定するため、header policy は次の遷移を持つ。

```text
Import:
  PrivacyLevel = Missing["NotGenerated"]
  HeaderPolicy = "ProvisionalEncryptedHeader"
  PlainHeader = all Missing["Encrypted"]
  Tokens = generated with SourceVault:mailid:mac:v1

Derived batch commits one record:
  PrivacyLevel / HeaderPL / HeaderConfidence / PrivacyConfidence are written to encrypted refs + checkpoint

Per-record re-seal immediately after checkpoint commit:
  if threshold pass: decrypt local header under NBAccess, write allowed plain fields, keep tokens
  else: keep encrypted header

Audit:
  no header with PrivacyLevel Missing may be plain
  every downgrade from encrypted to plain is recorded in HeaderPolicyHistory
```

この re-seal は local operation であり、cloud LLM / cloud embedding API に header 本文を渡してはならない。record の書き換えを伴うため、§11.3 の排他ロック・世代ファイル・原子的置換を通す。保存先がより高い境界に移動しても自動平文化は行わず、明示 reclassify または user approval を要求する。

#### 10.9.5 PL / summary / embedding 推定の増分バッチと checkpoint

`maildb.wl` の `addMailProperty` は、既存設計では月内全件を毎回処理し、完了分を逐次保存しない。SourceVault 統合では、PL 推定・summary・tag・embedding 生成を import 本体から分離し、未処理分だけを処理する再開可能な増分 batch とする。

```wl
SourceVaultInferMailDerivedBatch[mbox_String, opts___]
SourceVaultMailDerivedCheckpointStatus[mbox_String]
SourceVaultResumeMailDerivedBatch[mbox_String, opts___]
SourceVaultCancelMailDerivedBatch[mbox_String]
```

主オプションは次とする。

```wl
Options[SourceVaultInferMailDerivedBatch] = {
  "OnlyUnprocessed" -> True,
  "Fields" -> {"PrivacyLevel", "HeaderPL", "HeaderConfidence", "Summary", "Tags", "Embedding"},
  "LocalModelOnly" -> True,
  "CheckpointEvery" -> 1,
  "MaxMessages" -> Automatic,
  "Order" -> "NewestFirst",
  "Resumable" -> True,
  "OnInterrupt" -> "CommitCompleted",
  "Force" -> False,
  "AfterPrivacyInference" -> "ReclassifyHeaders"
};
```

`HeaderPL` / `HeaderConfidence` は header re-seal の直接入力であるため、既定 `Fields` に必ず含める。`HeaderPL` は header-only local inference で生成する。既存 maildb からの移行直後などで header-only inference が未実装の場合、`HeaderPL -> PrivacyLevel` とする fallback は許すが、confidence が低い場合は平文化しない。

本文 `PrivacyLevel` も fail-safe に扱う。import 時の `DefaultImportedMailPL -> 0.85` から、derived batch がより低い PL を付けることは実質的な policy loosening である。したがって `PrivacyConfidence < $SourceVaultMailPrivacyMinConfidence`、または confidence が `Missing` / 非数値の場合は、本文 `PrivacyLevel` を下げず、保守的既定を維持する。既定値は次とする。

```wl
$SourceVaultMailPrivacyMinConfidence = 0.70;
```

`PrivacyLevel` の低下がこの confidence gate を通っても、外部送信・cloud materialization 直前には `SourceVaultAuthorizeRecordMaterialization` と tag policy を再評価する。confidence gate は分類器の under-classification を silent loosening にしないための第一段階であり、release approval の代替ではない。

未処理判定は record-level で行う。

```text
Unprocessed(record, field) iff
  Derived[field] is Missing["NotGenerated"]
  or DerivedFieldPolicy[field].Status != "Done"
  or legacy maildb privacy == -1 and no SourceVault PrivacyLevel exists
```

checkpoint は平文 derived content を含めず、安定 `RecordId` と暗号化 record ref だけを append する。

```wl
<|
  "Type" -> "SourceVaultMailDerivedCheckpoint",
  "SchemaVersion" -> 1,
  "MBox" -> mbox,
  "RecordId" -> recordId,
  "Fields" -> {"PrivacyLevel", "HeaderPL", "HeaderConfidence", "Summary", "Tags", "Embedding"},
  "Status" -> "Done" | "Error" | "Skipped",
  "DerivedRefs" -> <|
    "SummaryRef" -> encryptedSummaryRef | Missing["NotGenerated"],
    "EmbeddingRef" -> encryptedEmbeddingRef | Missing["NotGenerated"]
  |>,
  "Model" -> localModelId,
  "Route" -> "LocalOnly",
  "DerivedAt" -> utcIsoDateTime,
  "ErrorClass" -> error | Missing["None"]
|>
```

`CheckpointEvery -> 1` を既定にし、1 通完了ごとに append / flush する。I/O を減らす場合も、失われる最大量は最後の flush 以降に限定される。`Status -> "Done"` の `RecordId` は再実行時に skip し、LLM に二重投入しない。`Status -> "Error"` は次回再試行対象にする。

checkpoint は進捗ログであり、active policy state ではない。`PrivacyLevel` / `HeaderPL` / `HeaderConfidence` / `AccessTags` / `HeaderPolicy` のような判定駆動 field は、`SourceVaultAppendAuthenticatedPolicyDelta` または `SourceVaultUpdateAuthenticatedRecordPolicy` によって authenticated policy state へ commit された時点で有効になる。checkpoint だけを書いて policy delta を commit していない record は `Status -> "DerivedButNotCommitted"` とし、release / cloud-send 判定には使わない。

checkpoint commit が成功し、かつ policy delta commit も成功した record については、直後に `SourceVaultReclassifyMailHeaderRecord[recordId]` を実行する。これにより、batch 全体が中断しても完了した record は header re-seal まで終わり、件名検索性が段階的に回復する。delta log 方式を既定にするため、1 通ごとに monolithic generation file 全体を書き換えてはならない。

private mail の summary / embedding / tag inference は、`SourceVaultAuthorizeRecordMaterialization` を通し、`LocalModelOnly -> True` を既定とする。cloud-generated historical field を import した場合は `CloudGeneratedBeforeSourceVault -> True` の provenance を残し、local regeneration によって置換できる。

`$maildbTaskStatus` は UI progress と cancel flag に流用してよいが、真実源は checkpoint store とする。強制終了、kernel abort、ユーザー cancel のいずれでも、すでに checkpoint された completed records は保持され、再開時に未処理集合だけが処理される。

既存 maildb 側の `addMailProperty` / `batchUpdateMaildb` を互換 layer として残す場合も、既定は「未処理のみ + checkpoint 逐次保存」とし、全再生成は明示的な `"Force" -> True` のときだけ許す。

任意の高速前処理として、LLM を呼ばずに明白な低 PL ヘッダを検出する `SourceVaultMailHeaderHeuristicClassify` を導入してよい。例: newsletter / no-reply / List-Id / bulk mail / 明示 allowlisted domain は、保存先 threshold 内で subject を即時 plain にできる。ただし曖昧なもの、個人名・成績・健康・懲戒・NDA などの語を含むもの、未知 domain は provisional encrypted のまま local inference に回す。

#### 10.9.6 maildb adapter API

```wl
SourceVaultRegisterMailAccount[mbox_String, spec_Association]
SourceVaultDisableLegacyMaildbWriter[mbox_String, opts___]
SourceVaultImportMailSnapshot[mbox_String, opts___]
SourceVaultImportMaildbFile[file_, opts___]
SourceVaultMailEnsureLoaded[mbox_String, period_:Automatic]
SourceVaultSearchMailSnapshots[query_String, opts___]
SourceVaultMailSourceStatus[mbox_String]
SourceVaultMigrateMaildbToSourceVault[mbox_String, opts___]
SourceVaultBuildMailEmbeddingIndex[mbox_String, opts___]
SourceVaultInferMailDerivedBatch[mbox_String, opts___]
SourceVaultMailDerivedCheckpointStatus[mbox_String]
SourceVaultReclassifyMailHeaders[mbox_String, opts___]
```

`SourceVaultImportMailSnapshot` は、IMAP へ直接接続する場合も、既存 maildb の月次 `.wl` DB を読む場合も、同じ `SourceVaultMailSnapshot` schema へ変換する。既存 maildb の `mailEnsureLoaded` / `mailSearchForLLM` は、移行期間中は adapter から呼んでよいが、最終的には SourceVault の search / materialization / release planning を通す。

移行開始後は、legacy maildb が `$dropbox/udb/mails` などへ新規平文を書き込む経路を止めるか、SourceVault encrypted ingest に切替える。migration 中に平文 fallback してはならない。


#### 10.9.7 SourceVault AddressBook / Group / DomainPolicy

MailDB 取り込みでは、email address は単なる string ではなく、SourceVault の release planning を駆動する identity source である。したがって AddressBook は「検索補助」ではなく、MailSnapshot、RecipientAccessProfile、tag policy、PublicKey registry と結びつく authenticated record 群として扱う。

##### ContactRecord

```wl
SourceVaultContactRecord = <|
  "Type" -> "SourceVaultContactRecord",
  "SchemaVersion" -> 1,
  "ContactId" -> stableOpaqueId,
  "Uid" -> localSerialInteger,
  "Nicknames" -> {"nconc", ...},
  "DisplayName" -> "Katsunobu Imai",
  "Names" -> <|"Full" -> ..., "Kana" -> ..., "SortKey" -> ...|>,
  "Emails" -> {
    <|"Address" -> "k.imai@fukuyama-u.ac.jp", "Kind" -> "Business", "Primary" -> True, "Verified" -> True|>,
    <|"Address" -> "katsunobu.imai@gmail.com", "Kind" -> "Private", "Primary" -> False, "Verified" -> True|>
  },
  "BusinessEmail" -> email | Missing["NotSet"],
  "PrivateEmail" -> email | Missing["NotSet"],
  "Handles" -> <|"GitHub" -> handle | Missing[], "X" -> handle | Missing[], "ORCID" -> id | Missing[]|>,
  "SystemUserIdentities" -> {
    <|"System" -> "SourceVault", "Nickname" -> "nconc", "MachineId" -> machineId | Missing["Unknown"], "PublicKeyRecordRef" -> ref | Missing[]|>
  },
  "ContactAccessProfile" -> <|
    "EstimatedAccessPL" -> 0.0 .. 1.0,
    "MaxPlaintextPL" -> pl,
    "MaxEncryptedReadablePL" -> pl,
    "AccessTags" -> {"Org:FukuyamaU", "Department:InformationEngineering"},
    "DenyTags" -> {"NoExternal" ...},
    "PurposeAllowed" -> {"Reply", "Collaboration", "Review"},
    "TrustStatus" -> "Verified" | "TOFU" | "Unverified" | "Revoked",
    "Confidence" -> confidence
  |>,
  "Categories" -> {"Person", "Faculty", "Collaborator"},
  "NotesRef" -> encryptedNoteRef | Missing["None"],
  "PolicySource" -> "Manual" | "ImportedContacts" | "MailObserved" | "DirectorySync",
  "UpdatedAt" -> utcIsoDateTime
|>;
```

`Uid` はローカル UI の serial number であり、複数端末間の唯一 identity としては使わない。同期・共有・重複解消には `ContactId` と verified email / public key fingerprint を用いる。`Nicknames` はユーザーが同じ SourceVault 系システムで使う表示名・alias であり、同一 nickname が複数 PC / 複数環境に存在し得るため、一意識別子ではない。

メールアドレス、private handle、notes はそれ自体が個人情報である。AddressBook の平文 index は StorageProfile / AddressBookPolicy に従い、必要に応じて HMAC token 化する。少なくとも email equality search 用には `SourceVault:addressbook:mac:v1` で keyed token を作り、raw email が不要な index には置かない。

##### Group record

```wl
SourceVaultContactGroupRecord = <|
  "Type" -> "SourceVaultContactGroupRecord",
  "SchemaVersion" -> 1,
  "GroupId" -> stableGroupId,
  "Name" -> "情報工学科教員",
  "GroupAddresses" -> {"ie-faculty@fukuyama-u.ac.jp" ...},
  "Members" -> {
    <|"ContactId" -> contactId, "Role" -> "Member"|>,
    <|"Email" -> address, "Role" -> "ExternalMember"|>
  },
  "DynamicSelectors" -> {
    <|"Type" -> "Domain", "Pattern" -> "fukuyama-u.ac.jp"|>,
    <|"Type" -> "Tag", "Required" -> {"Department:InformationEngineering", "Role:Faculty"}|>
  },
  "AccessOverlay" -> <|
    "MaxPlaintextPLDelta" -> 0 | negativeDelta,
    "AccessTagsAdd" -> {"Department:InformationEngineering"},
    "DenyTagsAdd" -> {},
    "PurposeAllowedAdd" -> {"DepartmentNotice"}
  |>,
  "ReleaseMode" -> "ConservativeIntersection" | "GroupAddressOnly" | "VerifiedMembersOnly",
  "PolicySource" -> "Manual" | "DirectorySync" | "MailObserved",
  "UpdatedAt" -> utcIsoDateTime
|>;
```

group address が送受信者に含まれる場合、group の access overlay を contact / domain policy と合成する。group は多人数に展開される可能性があるため、既定は **conservative intersection** とする。すなわち、group 宛ての返信本文に平文で含められる PL は、group profile、transport profile、既知 members の profile、unknown member risk の最小値で制限する。member 展開ができない group address は、個人宛てより低い `MaxPlaintextPL` を既定とする。

##### DomainPolicy / CategoryPolicy

```wl
SourceVaultAddressDomainPolicyRecord = <|
  "Type" -> "SourceVaultAddressDomainPolicyRecord",
  "SchemaVersion" -> 1,
  "Domain" -> "fukuyama-u.ac.jp",
  "DomainClass" -> "Institution" | "FreeMail" | "Company" | "Unknown" | "Disposable" | "Suspicious",
  "DefaultAccessPL" -> pl,
  "DefaultMaxPlaintextPL" -> pl,
  "DefaultMaxEncryptedReadablePL" -> pl,
  "AccessTagsAdd" -> {"Org:FukuyamaU"},
  "DenyTagsAdd" -> {},
  "PurposeAllowed" -> {"Reply", "AdministrativeContact"},
  "HeaderPlaintextBias" -> delta,
  "SummaryPolicy" -> "LocalOnly" | "CloudAllowedBelowThreshold" | "NoSummary",
  "PolicySource" -> "Manual" | "Baseline" | "Imported" | "Observed"
|>;

SourceVaultAddressCategoryPolicyRecord = <|
  "Type" -> "SourceVaultAddressCategoryPolicyRecord",
  "SchemaVersion" -> 1,
  "Category" -> "SpamLikely" | "DirectMarketing" | "Newsletter" | "AutomatedNotification" | "NoReply" | "SensitiveBusiness",
  "Selector" -> selectorSpec,
  "AccessEffect" -> <|
    "MaxPlaintextPLCeiling" -> pl,
    "DenyTagsAdd" -> {...},
    "SummaryPolicy" -> "Skip" | "LocalOnly" | "AllowLowPL",
    "PriorityBias" -> delta,
    "TrustStatus" -> "Low" | "Normal" | "High"
  |>
|>;
```

DomainPolicy は baseline と address book の中間に位置づける。`fukuyama-u.ac.jp` のような組織 domain は通常の free-mail domain より高い trust を持ち得るが、それだけで `StudentPrivate` や `NoEmail` を解除してはならない。`SpamLikely` / `DirectMarketing` / `Newsletter` / `AutomatedNotification` は「低 PL だから安全」ではなく、誤送信・リンク・追跡・要約不要の観点で別 category として扱う。

##### resolve / evaluation API

```wl
SourceVaultAddressBookPutContact[contact_Association, opts___]
SourceVaultAddressBookGetContact[contactIdOrUid_]
SourceVaultAddressBookFindByEmail[email_String]
SourceVaultAddressBookResolveIdentity[addressOrHandle_]
SourceVaultAddressBookMergeContacts[contactIds_, opts___]
SourceVaultAddressBookPutGroup[group_Association, opts___]
SourceVaultAddressBookPutDomainPolicy[policy_Association, opts___]
SourceVaultAddressBookPutCategoryPolicy[policy_Association, opts___]
SourceVaultAddressBookEvaluateAccess[participants_, purpose_, context_, opts___]
SourceVaultAddressBookSelect[query_Association, opts___]
SourceVaultAddressBookDoctor[]
```

`SourceVaultAddressBookEvaluateAccess` は、exact email、verified ContactRecord、group membership、domain policy、category policy、unknown-recipient default をこの順で解決し、複数候補がある場合は Deny-wins / conservative minimum を適用する。より specific な rule は access を強める方向では利用できるが、access を緩める場合は authenticated policy loosening として agent 外承認を要求する。

##### MailSnapshot との連携

IMAP 取り込み時、SourceVault は `From` / `To` / `Cc` / `Reply-To` / group address / domain を AddressBook に照合し、MailSnapshot に次のような低漏洩 metadata を追加する。

```wl
"AddressBookRefs" -> <|
  "FromContact" -> contactId | Missing["Unknown"],
  "ToContacts" -> {contactId ...},
  "CcContacts" -> {contactId ...},
  "Groups" -> {groupId ...},
  "Domains" -> {domainPolicyRef ...},
  "Categories" -> {"Newsletter", "AutomatedNotification" ...},
  "ResolutionConfidence" -> confidence,
  "ResolutionPolicyRevision" -> policyHeadRevision
|>
```

この情報は `HeaderPL` / `PrivacyLevel` / `Priority` / `SummaryPolicy` / `MessageReleasePlan` の入力にする。たとえば、送信者が verified contact であり、受信者が `情報工学科教員` group address である場合、`Department:InformationEngineering` tag を追加できる。一方、`NoReply` / `DirectMarketing` / `SpamLikely` category は summary を省略または local-only とし、返信 workflow を既定無効にする。

AddressBookRefs は policy 判定を駆動するため、MailSnapshot の authenticated decision state に含める。AddressBook 側の contact / group / domain policy が更新された場合、関連 MailSnapshot は `RequiresPolicyReevaluation -> True` となり、検索 index と release plan を再評価する。

##### 検索 select との連携

SourceVault mail search は本文検索や semantic search だけでなく、AddressBook 解決結果で select できるようにする。

```wl
SourceVaultSearchMailSnapshots[
  "yyyy の会議",
  SelectBy -> <|
    "FromContact" -> uid | contactId,
    "ToGroup" -> "情報工学科教員",
    "Domain" -> "fukuyama-u.ac.jp",
    "Category" -> Except["SpamLikely"],
    "HasAttachment" -> True,
    "PrivacyRange" -> {0.0, 0.65},
    "AccessTagsContains" -> {"Project:yyyy"}
  |>,
  Period -> Quantity[3, "Month"]
]
```

raw email で select する場合も、内部では HMAC token に変換して照合する。検索 UI では contact display name / group name を表示できるが、encrypted header の raw address を復号するには NBAccess gate を通す。

##### UI / PromptRouter 連携

`maildb.wl` の `showMails` / `openMailNotebook` / attachment menu / Reply / ReplyAll / ReplyTr / progress panel の UX は、SourceVault_promptrouter 側では次の定型表示に移行する。

```wl
SourceVaultMailView[queryOrRecords_, opts___]
SourceVaultMailSearchPanel[opts___]
SourceVaultMailCard[mailSnapshot_, opts___]
SourceVaultOpenMailNotebook[recordId_, opts___]
SourceVaultAddressBookPanel[opts___]
SourceVaultContactCard[contactId_, opts___]
SourceVaultPromptRouterMailPanel[opts___]
SourceVaultComposeReplyDraft[recordId_, mode_, opts___]
SourceVaultShowMessageReleaseAudit[draftId_]
```

`SourceVaultMailView` は `showMails` の列構成を引き継ぎ、checkbox、添付 count、HTML / signature indicator、JST date、priority、privacy/header policy、subject、from/contact、summary を表示する。ただし Reply / ReplyAll / ReplyTr ボタンは直接送信せず、`SourceVaultComposeReplyDraft` → `MessageReleasePlan` → release audit → human confirmation に接続する。添付を開く操作は NBAccess gate を通し、暗号化添付は memory-only に復号して一時 viewer へ渡す。

AddressBook UI は contact merge、email alias 追加、group membership 編集、domain policy 登録、public key / SourceVault nickname 表示、policy loosening approval request の確認を扱う。特に `MaxPlaintextPL` 引上げ、group による access tag 付与、domain trust 引上げ、public key trust 昇格は loosening であり、agent が自動確定してはならない。

##### Doctor / PARITY

| Test | 期待 |
|---|---|
| address token no raw leakage | raw email / private handle が HMAC token index 以外に平文で出ない。 |
| contact uid not global identity | `Uid` 衝突時も `ContactId` と verified email / key fingerprint で解決する。 |
| group conservative release | group address 宛てでは unknown member risk を含めて `MaxPlaintextPL` が conservative に下がる。 |
| domain trust loosening approval | domain policy の `DefaultMaxPlaintextPL` 引上げは agent 外承認なしに active にならない。 |
| spam/direct-mail category | `SpamLikely` / `DirectMarketing` は summary / reply workflow を制限する。 |
| addressbook policy rollback | contact / group / domain policy の delta truncation は policy head manifest mismatch で fail-closed。 |
| mail search select by contact | `FromContact` / `ToGroup` / `Domain` / `Category` select が token index と authenticated refs で動く。 |
| prompt router mail panel safe actions | UI の Reply ボタンは直接 SendMail せず draft + release audit に入る。 |


##### 自動 identity discovery と SourceVault Author Database

AddressBook は手入力だけでなく、SourceVault ingest pipeline から継続的に成長する。対象はメールに限らず、GitHub repository / issue / commit、arXiv paper、blog page、PDF、web page、将来の X / Discord / SNS cache を含む。

基本原則は次である。

1. **すべての人物抽出を observation として保存する。** いきなり ContactRecord に merge せず、まず `IdentityObservationRecord` に source、抽出方法、evidence、confidence を保存する。
2. **確信度に応じて処理を分ける。** verified email / ORCID / GitHub API owner などの高確信 evidence がある場合のみ contact への自動追加を許す。曖昧な場合は `IdentityCandidate` として review 待ちにする。
3. **identity merge は access loosening ではない。** 新しい email / handle / affiliation を既存 contact に追加しても、`MaxPlaintextPL` や `TrustStatus` を上げてはならない。access を緩める変更は policy loosening approval を通す。
4. **source と著者の紐付けを双方向に保持する。** source record には `AuthorRefs` / `ContributorRefs`、contact には `EvidenceRefs` を保存し、どの source からその identity を観測したか追跡できる。

###### IdentityObservationRecord

```wl
SourceVaultIdentityObservationRecord = <|
  "Type" -> "SourceVaultIdentityObservationRecord",
  "SchemaVersion" -> 1,
  "ObservationId" -> stableObservationId,
  "SourceRecordRef" -> sourceRecordRef,
  "SourceType" -> "IMAPMail" | "GitHub" | "ArXiv" | "Blog" | "PDF" | "WebPage" | "X" | "Discord" | "Other",
  "ObservedAt" -> utcIsoDateTime,
  "ObservedIdentity" -> <|
    "DisplayName" -> string | Missing[],
    "Emails" -> {email ...},
    "Handles" -> <|"GitHub" -> handle, "X" -> handle, "Discord" -> id, "ORCID" -> id|>,
    "Affiliations" -> {string ...},
    "Roles" -> {"Author", "Owner", "Committer", "Contributor", "Sender", "Recipient", "Mentioned"},
    "URLs" -> {url ...}
  |>,
  "Evidence" -> {
    <|"Kind" -> "VerifiedEmailHeader" | "GitHubAPI" | "ArXivMetadata" | "PDFMetadata" | "HTMLAuthorMeta" | "ORCID" | "TextClaim" | "Heuristic",
      "Value" -> evidenceValue,
      "Confidence" -> confidence,
      "SpanRef" -> spanRef | Missing[]|>
  },
  "Resolution" -> <|
    "Status" -> "Confirmed" | "Likely" | "Ambiguous" | "Unresolved" | "Rejected",
    "ContactId" -> contactId | Missing[],
    "CandidateContactIds" -> {contactId ...},
    "Reason" -> string,
    "ResolvedBy" -> "Automatic" | "Human" | "ImportedDirectory",
    "ResolutionConfidence" -> confidence
  |>,
  "Policy" -> <|
    "MayCreateContact" -> True | False,
    "MayMergeAutomatically" -> True | False,
    "AccessLooseningAllowed" -> False
  |>
|>;
```

`TextClaim` は低信頼 evidence とする。たとえば blog 本文に「私は〇〇である」と書かれていても、それだけでは verified identity としない。GitHub API、arXiv metadata、ORCID、メールヘッダ、既存 contact の verified email など、source type ごとの evidence class を区別する。

###### ContactCandidateRecord

```wl
SourceVaultContactCandidateRecord = <|
  "Type" -> "SourceVaultContactCandidateRecord",
  "SchemaVersion" -> 1,
  "CandidateId" -> candidateId,
  "ObservationRefs" -> {observationId ...},
  "ProposedContact" -> partialContactAssociation,
  "ProposedMergeTargets" -> {contactId ...},
  "Tags" -> {"IdentityUncertain", "NeedsReview"},
  "Confidence" -> confidence,
  "CreatedAt" -> utcIsoDateTime,
  "ReviewStatus" -> "Pending" | "Accepted" | "Rejected" | "Merged",
  "ReviewNotesRef" -> encryptedNoteRef | Missing[]
|>;
```

候補 record は検索可能にするが、release planning では verified contact と同じ扱いにしない。`ReviewStatus -> "Accepted"` または human merge が行われるまで、`MaxPlaintextPL` は unknown recipient と同じ fail-closed profile を使う。

###### 自動登録ルール

```text
IMAP:
  From / To / Cc / Reply-To に email があり、既存 contact に email token が一致
      -> 既存 contact に observation evidence を追加。
  一致がなく、email domain が許容 domain で、display name が存在
      -> 新規 ContactRecord を Observed/Unverified で作成。MaxPlaintextPL は 0.0。
  group address / mailing list らしい場合
      -> ContactGroupRecord または CategoryPolicy candidate を作る。

GitHub:
  API から owner / author / committer / contributor login が得られる
      -> GitHub handle observation。verified email がなければ contact candidate。
  commit email が既存 contact email と一致
      -> handle を alias candidate として追加。自動 merge は confidence threshold 以上のみ。

arXiv:
  author name / affiliation / ORCID が得られる
      -> author observation。ORCID 一致なら confirmed link、名前だけなら candidate。

blog / web page:
  rel=author, schema.org Person, h-card, meta author, RSS author などを抽出
      -> evidence class を付けて observation。本文 claim だけなら low confidence。

PDF:
  PDF metadata Author、論文表紙、DOI metadata、arXiv ID などを分離して observation。
  PDF 内テキスト抽出由来の著者は confidence を低めにする。

X / Discord 将来拡張:
  platform id / handle / display name / server id / channel id を observation とし、verified email が無ければ contact candidate に留める。
```

###### API

```wl
SourceVaultIngestIdentityObservations[sourceRecordRef_, opts___]
SourceVaultExtractSourceIdentities[sourceRecordRef_, opts___]
SourceVaultResolveIdentityObservation[observationId_, opts___]
SourceVaultPromoteIdentityCandidate[candidateId_, opts___]
SourceVaultRejectIdentityCandidate[candidateId_, reason_]
SourceVaultLinkSourceToContact[sourceRecordRef_, contactId_, role_, opts___]
SourceVaultFindContactEvidence[contactId_]
SourceVaultSearchIdentityGraph[query_, opts___]
SourceVaultAuthorDatabaseDoctor[]
```

`SourceVaultPromoteIdentityCandidate` は、単に contact を作る / merge する操作であっても authenticated policy update である。ContactRecord の `AccessProfile` を緩める変更を含む場合は、`Loosening` として agent 外承認を要求する。contact の alias / handle 追加が release planning に影響し得る場合、Doctor は pending reevaluation を出す。

###### Source record との紐付け

GitHub / arXiv / blog / PDF / web ingest record は、次の attribution metadata を持つ。

```wl
"Attribution" -> <|
  "AuthorRefs" -> {contactId ...},
  "ContributorRefs" -> {contactId ...},
  "IdentityObservationRefs" -> {observationId ...},
  "UnresolvedIdentityRefs" -> {candidateId ...},
  "AttributionConfidence" -> confidence,
  "AttributionPolicyRevision" -> policyHeadRevision
|>
```

この attribution は source search と prompt materialization に使う。たとえば「A 氏の GitHub issue と arXiv 論文をまとめる」場合、SourceVault は ContactId を軸に GitHub / arXiv / blog / PDF の record を横断検索できる。ただし、candidate / ambiguous attribution は、回答中に「未確認の同一人物候補」として扱い、verified contact と断定しない。

###### 検索 select

```wl
SourceVaultSearchSources[
  query,
  SelectBy -> <|
    "AuthorContact" -> contactId,
    "AuthorName" -> namePattern,
    "GitHubHandle" -> handle,
    "ORCID" -> orcid,
    "Affiliation" -> "Fukuyama University",
    "SourceType" -> {"GitHub", "ArXiv", "PDF"},
    "IdentityConfidence" -> GreaterEqualThan[0.8],
    "IncludeCandidates" -> False
  |>
]
```

検索結果は ContactRecord / Observation / SourceRecord の三者を分けて表示する。候補 identity を含む場合は UI 上で `Unverified` / `Candidate` / `Ambiguous` を明示する。

###### Doctor / PARITY

| Test | 期待 |
|---|---|
| imap auto contact create fail-closed | 未知 sender が ContactRecord に追加されても MaxPlaintextPL は 0.0 で、release permission は広がらない。 |
| github author observation no blind merge | GitHub handle だけでは既存 contact に自動 merge しない。verified email / explicit human review が必要。 |
| arxiv orcid confirmed link | ORCID が既存 contact と一致する場合のみ confirmed author link になる。 |
| blog text claim low confidence | blog 本文中の自己主張だけでは confirmed contact にならず ContactCandidate になる。 |
| source attribution search | AuthorContact select で GitHub / arXiv / PDF source を横断検索できる。 |
| ambiguous identity materialization | ambiguous candidate を verified author として prompt に出さず、「未確認候補」として扱う。 |
| identity merge loosening approval | merge により recipient access が緩む場合、agent 外承認なしには active にならない。 |
| attribution policy reevaluation | ContactRecord / Candidate resolution 更新時、関連 source record に RequiresPolicyReevaluation が立つ。 |



#### 10.9.8 RecipientAccessProfile

メール送信や capsule 共有の受信者は、AddressBook の contact / group / domain / category 解決結果から生成される `RecipientAccessProfile` で表す。直接 email から作るのではなく、まず `SourceVaultAddressBookEvaluateAccess` を通す。

```wl
<|
  "Type" -> "SourceVaultRecipientAccessProfile",
  "SchemaVersion" -> 2,
  "RecipientId" -> recipientId,
  "Email" -> email,
  "DisplayName" -> name | Missing["Unknown"],
  "UsesSourceVault" -> True | False | Unknown,
  "PublicKeyRecordRef" -> publicKeyRecordRef | Missing["NotRegistered"],
  "TrustStatus" -> "Verified" | "VerifiedOutOfBand" | "TOFU" | "Unverified" | "Revoked",
  "MaxPlaintextPL" -> maxPlaintextPL,
  "MaxEncryptedReadablePL" -> maxEncryptedReadablePL,
  "AccessTags" -> {"Project:yyyy", "Role:Collaborator", "NDA:Signed"},
  "DenyTags" -> {"NoEmail", "NoExternal", "StudentPrivate", "Personal"},
  "PurposeAllowed" -> {"Reply", "Collaboration", "Review"},
  "ExpiresAt" -> date | Missing["NoExpiry"],
  "PolicySource" -> "Manual" | "ImportedContact" | "DomainDefault" | "MailThreadPolicy" | "UnknownDefault"
|>
```

未登録・未検証・`UsesSourceVault -> Unknown` の受信者は fail-closed とする。

```wl
SourceVaultDefaultUnknownRecipientProfile[email_] := <|
  "TrustStatus" -> "Unverified",
  "UsesSourceVault" -> Unknown,
  "PublicKeyRecordRef" -> Missing["NotRegistered"],
  "MaxPlaintextPL" -> 0.0,
  "MaxEncryptedReadablePL" -> 0.0,
  "AccessTags" -> {},
  "DenyTags" -> {"NoEmailUnlessDeclassified"},
  "PurposeAllowed" -> {},
  "PolicySource" -> "UnknownDefault"
|>
```

`MaxPlaintextPL` は「普通のメール本文に平文で入れてよい上限」であり、`MaxEncryptedReadablePL` は「同じシステムを使い、公開鍵で暗号化すれば渡してよい上限」である。後者は必ず `UsesSourceVault -> True` かつ `PublicKeyRecordRef` が verified である場合だけ有効にする。TOFU のままの公開鍵は `VerifiedOutOfBand` より低い `MaxEncryptedReadablePL` を適用する。

`SourceVaultRecipientAccessProfile` は release 判定の相手側 policy であるため、通常 record ではなく authenticated record として保存する。`MaxPlaintextPL` / `MaxEncryptedReadablePL` の引上げ、`AccessTags` 追加、`DenyTags` 削除、`TrustStatus` 昇格、`PurposeAllowed` 追加は policy loosening であり、`SourceVaultUpdateAuthenticatedRecordPolicy` の agent 外承認を必須にする。攻撃者が snapshot record を触らなくても recipient profile 側を書き換えれば release 判定が変わるため、Doctor は recipient profile の HMAC / policy delta chain を必ず検証する。

公開鍵 bootstrap は最小限次を仕様化する。

1. 自分の signed public-key capsule を初回メールに添付または別送する。
2. 受信した public-key capsule は `SourceVaultRegisterPublicKey[..., "TrustStatus" -> "TOFU"]` で登録する。
3. fingerprint を別経路で確認した後だけ `VerifiedOutOfBand` に昇格する。
4. `TOFU` のままでは高 PL capsule を許さず、低〜中 PL の明示許可範囲に制限する。

#### 10.9.9 Tag-based privacy と `SourceVaultTagPolicyEvaluate`

PL 数値だけでは不十分である。SourceVault record / Notebook cell / mail snapshot / attachment には次のようなタグを持たせる。

```wl
"AccessTags" -> {
  "Project:yyyy",
  "Source:Notebook",
  "Source:Mail",
  "Course:2026-A",
  "Role:SupervisorOnly",
  "Person:Student:<opaque-id>",
  "NoExternal",
  "NoEmail",
  "RequiresNDA"
}
```

タグ文法は次を基本とする。

```text
Tag        ::= Atom | Atom ":" Tag
Atom       ::= letter_or_digit_or_dash_or_underscore+
Wildcard   ::= "*"
PatternTag ::= Atom ":" "*" | Atom ":" Atom ":" "*" | ...
```

`Project:*` は `Project:yyyy` を満たすが、逆は満たさない。未知タグは fail-closed とする。評価順序は必ず次に固定する。

1. **Deny-wins**: material tag が recipient の `DenyTags` または system deny pattern に一致すれば即 deny。`NoEmail` / `NoExternal` / `StudentPrivate` は allow tag で上書きしない。
2. **Purpose check**: `purpose` が `recipient.PurposeAllowed` に含まれ、profile が期限切れでないこと。
3. **Required tag check**: material の `RequiredTags[material, purpose]` が recipient の `AccessTags` で階層・wildcard 込みで満たされること。
4. **Exception check**: `RequiresNDA` 等は `NDA:Signed` のような明示 allow tag で満たす。ただし Deny-wins は覆さない。
5. **Override check**: `NoEmail` / `NoExternal` を覆す場合は `DualApprovalToken` と audit reason を必須にし、既定では禁止。

```wl
SourceVaultTagPolicyEvaluate[material_, recipientProfile_, purpose_, opts___] :=
  <|
    "Decision" -> "Allow" | "Deny" | "NeedsDualApproval",
    "ReasonClass" -> "TagDenied" | "MissingRequiredTag" | "PurposeDenied" | "ExpiredProfile" | "UnknownTag" | "OverrideRequired" | "OK",
    "PublicReason" -> generalizedReason,
    "PrivateAudit" -> detailedTagTrace
  |>
```

外部向け redaction reason では、タグ名そのものが漏洩する場合があるため、`PublicReason` は一般化する。 AddressBook の group / domain / category 由来の tag overlay も同じ evaluator に通し、unknown tag や未検証 contact 由来の allow は fail-closed とする。

#### 10.9.10 MessageReleasePlan

外部メール送信は、保存と同じく release boundary である。`ClaudeEval` が返信送信を要求した場合、直接 `SendMail` せず、まず release plan を作る。

```wl
SourceVaultPlanMessageRelease[
  <|
    "Recipients" -> {email1, email2, ...},
    "Purpose" -> "Reply",
    "Transport" -> "Email",
    "RequestedAction" -> "DraftReply" | "SendReply",
    "SourceMaterials" -> {mailSnapshotRef, notebookCellRef, sourceVaultRecordRef, attachmentRef, ...},
    "UserPrompt" -> prompt
  |>
]
```

戻り値は次の形にする。

```wl
<|
  "Decision" -> "DraftOnly" | "ReadyForUserReview" | "Blocked",
  "PlaintextMaterials" -> {materialRef ...},
  "EncryptedCapsules" -> {
    <|"Recipient" -> email, "CapsuleRef" -> capsuleRef, "Materials" -> {...}|>
  },
  "RedactedMaterials" -> {
    <|"Material" -> ref, "Reason" -> "AboveRecipientAccess" | "TagDenied" | "NoPublicKey" | "NoEmailTag" | "UnknownRecipient"|>
  },
  "LLMRoutes" -> <|
    "CloudAllowedPrompt" -> text,
    "LocalOnlyPrompt" -> text,
    "NoLLM" -> {materialRef ...}
  |>,
  "Audit" -> <|
    "TransportMaxPlaintextPL" -> 0.45,
    "RecipientProfiles" -> {...},
    "TagPolicyVersion" -> "SourceVaultTagPolicy/v1",
    "RequiresHumanConfirmation" -> True
  |>
|>
```

判定規則は次である。

| 条件 | 処理 |
|---|---|
| `material.PL <= Min[TransportProfile.MaxPlaintextPL, recipient.MaxPlaintextPL]` かつ `SourceVaultTagPolicyEvaluate[...] -> Allow` | メール本文に平文で含めてよい |
| `TransportProfile.MaxPlaintextPL < material.PL <= recipient.MaxEncryptedReadablePL` かつ tag policy pass かつ verified public key あり | 本文には入れず、recipient public key で capsule 暗号化して添付またはリンク化 |
| `material.PL > recipient.MaxEncryptedReadablePL` | 含めない。必要なら「権限外のため省略」とだけ記録 |
| tag policy fail | 含めない。タグ名自体が漏洩する場合は redaction reason も一般化 |
| recipient public key なし / unverified / TOFU 上限超過 | 高 PL material は送らない。明示 declassify がない限り要約も不可 |
| `NoEmail` / `NoExternal` tag | plaintext / encrypted capsule ともに既定禁止。明示 override には二重承認を要求 |

#### 10.9.11 返信生成ワークフロー

例:

```wl
ClaudeEval[
  "xxxx@example.org からの最新メールに関して肯定的に返信を送ってほしい。
   そのとき、関連する yyyy のノートの内容を含めてほしい。"
]
```

この指示は次の workflow に展開する。

1. `SourceVaultResolveRecipient["xxxx@example.org"]` で recipient profile と public key status を取得。未知受信者は fail-closed profile にする。
2. `SourceVaultSearchMailSnapshots[FromToken -> ..., Sort -> "Newest"]` で最新メール snapshot を取得。必要なら NBAccess gate 下で encrypted header を復号する。
3. `SourceVaultSearchNotebooks["yyyy", ...]` で関連 Notebook cell / SourceVault record を取得。
4. 各 material に `PrivacyLevel`, `AccessTags`, `SourceKind`, `ReleasePolicy` を付与。
5. `SourceVaultPlanMessageRelease[...]` で plaintext / encrypted capsule / redacted を分類。
6. LLM に渡す prompt を plan から生成する。
   - cloud LLM には `PlaintextMaterials` のうち cloud/sendable なものだけを渡す。
   - private material を使う draft planning と最終合成器は local LLM または rule-based composer に閉じる。
   - encrypted capsule に入れる原文は LLM に渡さず、SourceVault が直接 capsule 化する。
7. `SourceVaultComposeMailDraft[...]` で draft を作成する。
8. 合成後の draft 全体を再び `SourceVaultPlanMessageRelease` / release audit に通し、生成文に private fact が混入していないか確認する。
9. `SourceVaultShowReleaseAudit[...]` で「本文に含める情報」「暗号化添付する情報」「省略する情報」を表示する。
10. ユーザー確認後のみ `SourceVaultSendMailDraft[...]` を実行する。

`RequestedAction -> "SendReply"` が自然言語に含まれていても、既定は `DraftOnly` または `ReadyForUserReview` とする。自動送信は、recipient policy・material policy・ユーザーの明示承認・mail transport 設定がすべて揃う場合だけ許可する。

#### 10.9.12 既存 maildb からの migration

既存 maildb の月次 `.wl` DB と添付フォルダは、次の理由でそのまま SourceVault の信頼済み store にしてはいけない。

- `$dropbox` 配下などの cloud sync folder に平文 body / summary / attachment / embedding が保存されている可能性がある。
- `privacy` は 0/1 の過去推定値であり、recipient-specific tag policy や連続 PL を表さない。
- embedding vector や summarytagembedding は、private content の近似漏洩源であり、生成時に cloud API へ送られている可能性がある。
- `sendReply` 系は notebook cell 本文をそのまま SendMail するため、release audit を通らない。

移行は **step 0: 平文の蛇口を止める** から始める。

```wl
SourceVaultMigrateMaildbToSourceVault[
  mbox,
  "DryRun" -> True,
  "Step0" -> "DisableLegacyPlaintextIngest",
  "ImportBodies" -> "EncryptedOnly",
  "ImportHeaders" -> "EncryptedOrTokenized",
  "ImportAttachments" -> "EncryptedOnly",
  "ImportEmbeddings" -> "LocalEncryptedIndex",
  "RegenerateEmbeddings" -> "LocalOnly",
  "InferTags" -> True,
  "TreatMaildbPrivacyAs" -> "HistoricalClassifierOutput",
  "DefaultImportedMailPL" -> 0.85,
  "PreserveMaildbCompatibility" -> True
]
```

step 0 の要件:

1. `checkNewMail` / `batchUpdateMaildb` / `updateMonthlyMaildb` / ScheduledTask が legacy path へ新規平文を書かない状態にする。
2. 新しい SourceVault mail store は Dropbox / OneDrive / Google Drive / iCloud Drive 配下を既定拒否する。同期パスに置く場合は encrypted-only を強制する。
3. 既存 `$dropbox/udb/mails` の月次 `.wl` と attachment folder は quarantine / read-only import 対象とし、実行中に更新しない。
4. migration 中の lock timeout / failure 時に平文 fallback してはならない。

既存 maildb の `privacy=0` は「public 候補」として provenance に残すだけで、release / cloud 判定の根拠にはしない。dry-run report は、月次 DB 件数、添付件数、平文 body の残存、cloud sync path、既存 `privacy` 値の分布、`privacy=0` だが添付あり / 高機密 tag 推定ありの件数、cloud-derived embedding 件数、推定 tags、SourceVault record への変換件数を表示する。実行後も、クラウド同期済み履歴の回収は保証しない。

添付ファイル名も漏洩面である。migration は既存 filename を HMAC token / redacted display name へ置換するか、encrypted attachment record に格納し、旧 attachment folder は quarantine / rename / best-effort secure delete の対象にする。HTML→PDF 変換や `.p7s` 等の派生添付も attachment policy の対象にし、外部 CSS / 画像取得は既定無効にする。

#### 10.9.13 Doctor / PARITY 追加項目

`SourceVaultDoctor[]` は次を検査する。

- maildb compatibility adapter が導入済みか。
- legacy maildb writer / scheduled task が SourceVault migration 中に平文を書き続けていないか。
- IMAP credential が KeyRef / SystemCredential 経由で参照され、値が record / log に出ていないか。
- mail snapshot raw body / header / attachment が高 PL の場合に encrypted record 化または HMAC token 化されているか。
- `Subject` / `From` / `To` / `Cc` / `MessageID` / attachment filename が、`HeaderPlaintextThreshold` を超える mail、PL 未確定 mail、低 confidence mail、deny-tag mail で平文 metadata に残っていないか。
- 閾値以下の plain header が `StorageProfileId` / `HeaderPlaintextThreshold` / `HeaderPlaintextRationale` / `HeaderPolicyHistory` を持ち、保存先変更時に再封印対象として検出できるか。
- maildb の月次 `.wl` DB / attachment folder が cloud sync path にあり、高 PL 平文が残っていないか。
- summary / embedding / summarytagembedding が private content の平文 index として残っていないか。
- private mail の cloud-generated summary / embedding provenance が warning され、local regeneration option があるか。
- `SourceVaultInferMailDerivedBatch` が未処理のみを対象にし、completed checkpoint を持つ record を再処理せず、中断後に再開できるか。
- PL 未確定 record の header が provisional encrypted のままで、derived batch 完了後に threshold 以下だけが local re-seal で平文化されるか。
- maildb の `privacy` が PL の真実源として使われていないか。
- recipient profile に fail-closed default、`MaxPlaintextPL` / `MaxEncryptedReadablePL` / tags / public key status があるか。
- `SourceVaultTagPolicyEvaluate` が Deny-wins / wildcard / hierarchy / unknown-tag deny を満たすか。
- `MessageReleasePlan` が plaintext / capsule / redaction を区別しているか。
- `SendMail` 相当の実行が release audit と human confirmation を通るか。
- 同じシステムを使わない受信者へ、高 PL material が plaintext fallback されないか。
- cloud / local LLM 合成後の draft が release audit に再投入されるか。

PARITY lane には次を追加する。

| Lane | Status | Tests | Mock/Real | Risk |
|---|---|---|---|---|
| MailDB legacy writer disabled | Pass/Partial/Fail | ... | Real | High |
| MailDB snapshot import | Pass/Partial/Fail | ... | Real/Mock IMAP | High |
| Mail header tokenization / encryption | Pass/Partial/Fail | ... | Real | High |
| Mail header storage-threshold policy | Pass/Partial/Fail | ... | Real | High |
| Mail header provisional-to-plain reseal | Pass/Partial/Fail | ... | Real | High |
| Mail attachment encrypted import | Pass/Partial/Fail | ... | Real | High |
| Private summary / embedding local-only generation | Pass/Partial/Fail | ... | Real/Mock | High |
| Resumable mail derived batch checkpoint | Pass/Partial/Fail | ... | Real/Mock | High |
| Cloud-generated embedding provenance warning | Pass/Partial/Fail | ... | Real | High |
| RecipientAccessProfile fail-closed default | Pass/Partial/Fail | ... | Real | High |
| Tag policy Deny-wins / hierarchy | Pass/Partial/Fail | ... | Real | High |
| MessageReleasePlan plaintext/capsule/redaction | Pass/Partial/Fail | ... | Real | High |
| Mail reply draft audit | Pass/Partial/Fail | ... | Real | High |
| Non-SourceVault recipient redaction | Pass/Partial/Fail | ... | Real | High |



AddressBook / UI 関連の追加 Doctor / PARITY は次を含める。

| Test | 期待 |
|---|---|
| addressbook authenticated records | Contact / Group / DomainPolicy / CategoryPolicy が authenticated record として検証される。 |
| addressbook raw email leakage | private email / handles が search index / JSONL / debug log に平文で残らない。 |
| group/domain select works | `SourceVaultSearchMailSnapshots` の `SelectBy -> <|"ToGroup" -> ..., "Domain" -> ...|>` が HMAC token / authenticated refs で動作する。 |
| release uses addressbook profile | MessageReleasePlan が raw recipient string ではなく AddressBook 解決済み RecipientAccessProfile を使う。 |
| prompt router mail UI | SourceVault_promptrouter の mail panel は direct send ではなく draft + release audit 経路を使う。 |


## 11. 既存平文データ migration

### 11.1 API

```wl
SourceVaultMigrateToEncrypted[opts___]
```

主オプション:

```wl
"DryRun" -> True
"PrivacyThreshold" -> Automatic
"IncludePromptRouterRuns" -> True
"IncludePrivateVault" -> True
"Backup" -> True
"SecureDelete" -> "BestEffort" | "QuarantineEncrypted" | "None"
"LockTimeout" -> 30
"ReportFile" -> Automatic
```

### 11.2 手順

1. SourceVault store に排他ロックを取得する。
2. prompt-runs.jsonl / registry / private vault を scan する。
3. private と判定される平文 record を列挙する。
4. dry-run では書き換えず、件数・リスク・対象ファイルを報告する。
5. 実行 mode では generation file に暗号化済み record を書き出す。
6. 書き出し後に roundtrip と HMAC/AEAD 検証を行う。
7. 原子的 rename で store を差し替える。
8. 旧平文ファイルは encrypted quarantine に移すか best-effort delete する。
9. SSD / journaling filesystem では secure delete が保証できないため、Doctor はその旨を warning として出す。
10. store path が `Dropbox` / `OneDrive` / `Google Drive` / `iCloud Drive` 等の同期フォルダ配下にある場合、`MigrationProtectsCloudHistory -> False` を report に明示する。クラウド側の過去版・削除済みファイル履歴はローカル migration では回収できない。

### 11.3 append-only との整合

PromptRouter の現行 append-only JSONL と rotation/migration は衝突し得る。SV-E3 では次を必須とする。

```wl
SourceVaultWithExclusiveStoreLock[expr_]
SourceVaultRewriteJSONLGeneration[file_, transform_, opts___]
SourceVaultAtomicReplaceStoreFile[tempFile_, targetFile_]
```

migration / rotation 中の writer は待機または失敗させる。`LockTimeout` を超えた場合も、平文一時保存へフォールバックしてはならない。戻り値は `Status -> "StoreLocked"`, `PlaintextPersisted -> False` とする。

---

## 12. 公開鍵 registry

### 12.1 方針

- 自分の keypair 生成だけを提供する。
- 自分用には **暗号用 keypair** と **署名用 keypair** の 2 組を生成する。
- 他者の private key は生成しないし保存しない。
- 他者については encryption public key / signing public key の登録・検証・失効だけを提供する。
- SourceVault record に保存できる秘密鍵情報は `EncryptionPrivateKeyRef` / `SigningKeyRef` という KeyRef だけである。

### 12.2 API

```wl
SourceVaultGenerateSelfKeyPair[opts___]
SourceVaultRegisterPublicKey[recipientId_String, publicKeys_Association, opts___]
SourceVaultGetPublicKey[recipientId_String, usage_: Automatic, opts___]
SourceVaultListPublicKeys[opts___]
SourceVaultRevokePublicKey[recipientId_String, fingerprint_String, opts___]
SourceVaultPublicKeyFingerprint[publicKey_, usage_: "Encryption" | "Signing"]
SourceVaultVerifyPublicKeyFingerprint[publicKeyRecord_, usage_: Automatic]
```

`SourceVaultGenerateSelfKeyPair[]` は既定で次の 2 組を生成する。

| 用途 | KeyRef | Public record field | Fingerprint field |
|---|---|---|---|
| envelope 復号 / payload key unwrap | `SourceVault:self:private:v1` | `EncryptionPublicKey` | `EncryptionFingerprint` |
| capsule 署名 | `SourceVault:signing:sign:v1` | `SigningPublicKey` | `SigningFingerprint` |

旧案の `SourceVaultGenerateUserKeyPair[recipientId]` は導入しない。互換用に残す場合は `recipientId` が self を指す場合だけ許可し、それ以外は拒否する。

署名方式の既定は `RSA-PSS-SHA256`、envelope wrapping は `RSA-OAEP` とする。最小鍵長は 2048 bit、推奨は 3072 bit 以上とする。環境が RSA-PSS を利用できない場合、Doctor は `CapsuleSignatureImplemented -> False` とし、署名済み capsule を作成したことにしてはならない。

### 12.3 public key record schema

```wl
<|
  "Type" -> "SourceVaultPublicKeyRecord",
  "SchemaVersion" -> 2,
  "RecipientId" -> recipientId,
  "DisplayName" -> displayName,
  "OwnerKind" -> "Self" | "VaultUser" | "ExternalCollaborator",

  "EncryptionPublicKey" -> serializedEncPubKeyJSONBase64,
  "EncryptionFingerprint" -> encFingerprint,
  "EncryptionPrivateKeyRef" -> Missing["NotStored"] | "SourceVault:self:private:v1",
  "EncryptionAllowedUse" -> {"CapsuleEnvelope"},

  "SigningPublicKey" -> serializedSignPubKeyJSONBase64 | Missing["NotProvided"],
  "SigningFingerprint" -> signFingerprint | Missing["NotProvided"],
  "SigningKeyRef" -> Missing["NotStored"] | "SourceVault:signing:sign:v1",
  "SigningAllowedUse" -> {"SignatureVerify"},

  "TrustStatus" -> "Unverified" | "VerifiedLocal" | "VerifiedOutOfBand" | "Revoked",
  "CreatedAt" -> utcIsoDateTime,
  "RevokedAt" -> Missing["NotRevoked"],
  "Notes" -> notes
|>
```

公開鍵の serialized 表現は `SourceVaultCanonicalJSON/v1` で定義した canonical JSON + Base64 とする。`EncryptionFingerprint` と `SigningFingerprint` は互いに別の値であり、capsule の envelope 選択では encryption fingerprint、署名検証では signing fingerprint を使う。

`SourceVaultPublicKeyRecord` も authenticated record とする。`TrustStatus` の `Unverified` / `TOFU` から `VerifiedLocal` / `VerifiedOutOfBand` への昇格、`AllowedUse` の追加、fingerprint 差し替え、revocation 解除は policy loosening であり、agent 外承認と out-of-band fingerprint 確認を要求する。`Revoked` への変更や allowed use の削除は tightening として自動適用してよい。release 判定時は snapshot record だけでなく、参照された public key record の HMAC / policy delta chain も検証する。

## 13. Hybrid capsule sharing

### 13.1 capsule 方針

他ユーザとの共有では、payload 本体は capsule ごとに新規生成した random `payloadKey` から派生した対称鍵で暗号化し、その `payloadKey` を各受信者の encryption public key で包む。capsule 全体には送信者の signing private key による署名を付与する。

共有 capsule の payload MAC には送信者ローカル固定 KeyRef を使わない。受信者が envelope を開いて得る `payloadKey` から同じ `payloadMacKey` を HKDF 派生できる必要がある。

```text
payloadEncKey = HKDF(payloadKey, info="SourceVault capsule payload enc v1")
payloadMacKey = HKDF(payloadKey, info="SourceVault capsule payload mac v1")
```

したがって capsule payload の完全性は次の 2 系統で担保する。

1. capsule signature: 送信者の signing public key で、payload ciphertext / manifest / envelopes を含む署名対象を検証する。
2. payload-key-bound authentication: envelope を開けた受信者だけが `payloadKey` から `payloadMacKey` を派生し、payload HMAC / AEAD tag を検証する。

### 13.2 capsule schema

```wl
<|
  "Type" -> "SourceVaultCapsule",
  "CapsuleVersion" -> 1,
  "CapsuleId" -> capsuleId,
  "CreatedAt" -> utcIsoDateTime,

  "Payload" -> <|
    "Canonicalization" -> "SourceVaultCanonicalJSON/v1",
    "EncryptionMode" -> "HybridPayloadSymmetric",
    "KeyDerivation" -> <|
      "Mode" -> "HKDF-from-PayloadKey/v1",
      "EncInfo" -> "SourceVault capsule payload enc v1",
      "MacInfo" -> "SourceVault capsule payload mac v1",
      "Salt" -> base64SaltOrMissing
    |>,
    "Algorithm" -> resolvedPayloadAlgorithm,
    "IntegrityMode" -> "EncryptThenMAC" | "AuthenticatedEncryption",
    "Ciphertext" -> encryptedPayload,
    "CiphertextChecksum" -> checksumAssociation,
    "CiphertextHMAC" -> <|
      "Algorithm" -> "HMAC-SHA256",
      "KeySource" -> "PayloadKeyDerived",
      "KeyDerivation" -> "HKDF-from-PayloadKey/v1",
      "AuthenticatedBytes" -> "SourceVaultCapsulePayloadAuthenticatedBytes/v1",
      "Value" -> hmacHex
    |> | Missing["ProvidedByAEAD"],
    "PlaintextDigest" -> plaintextDigestAssociation | Missing["Suppressed"],
    "ContentType" -> contentType
  |>,

  "Envelopes" -> {
    <|
      "RecipientId" -> recipientId,
      "RecipientEncryptionFingerprint" -> encryptionFingerprint,
      "WrappedPayloadKey" -> base64EncryptedPayloadKey,
      "EnvelopeMode" -> "PublicKeyWrappedSymmetricKey",
      "Algorithm" -> <|"PublicKeyCipher" -> "RSA", "Padding" -> "OAEP", "MinimumKeyBits" -> 2048|>
    |>
  },

  "Manifest" -> <|
    "SourceVaultVersion" -> version,
    "SenderId" -> senderId,
    "SenderSigningFingerprint" -> senderSigningFingerprint,
    "Policy" -> policy,
    "TrustOnImport" -> "UntrustedUntilReviewed",
    "MetadataLeakage" -> metadataLeakageAssociation
  |>,

  "Signature" -> <|
    "Status" -> "Present",
    "Algorithm" -> <|"Scheme" -> "RSA-PSS", "Hash" -> "SHA256", "MinimumKeyBits" -> 2048|>,
    "SignerId" -> senderId,
    "SignerSigningFingerprint" -> senderSigningFingerprint,
    "SignedBytesCanonicalization" -> "SourceVaultCapsuleSignedJSONBytes/v1",
    "Value" -> signatureBytesOrString
  |>
|>
```

`SourceVault:capsule:quarantine-mac:v1` のようなローカル固定 KeyRef は、受信済み capsule を自分の vault に quarantine 保存するときの at-rest 用途に限る。共有 payload の `CiphertextHMAC` には使わない。

### 13.3 署名対象

署名対象は WL バージョン非依存の canonical JSON bytes とする。

```wl
SourceVaultCapsuleSignedJSONBytes[capsuleWithoutSignature_]
```

含めるもの:

- `Type`
- `CapsuleVersion`
- `CapsuleId`
- `CreatedAt`
- `Payload` の ciphertext / integrity metadata / content type / payload AAD / key derivation metadata
- `Envelopes` の recipient ID / **recipient encryption fingerprint** / wrapped payload key / RSA-OAEP metadata
- `Manifest` の sender ID / **sender signing fingerprint** / policy / trust metadata

含めないもの:

- `Signature` 自身
- import 後に付く local review metadata

署名検証に失敗した capsule は import してはならない。ただし互換検証用に `"AllowUnsignedCapsule" -> False` を既定とし、true にしても `TrustOnImport -> "UntrustedUntilReviewed"` から昇格させない。

recipient 側は任意で `CreatedAt` が極端な未来や古過ぎる時刻でないかを検査し、必要なら `Reason -> "SuspiciousTimestamp"` として review 待ちにできる。

### 13.4 API

```wl
SourceVaultCreateCapsule[data_, recipients_List, opts___]
SourceVaultOpenCapsule[capsule_, opts___]
SourceVaultImportCapsule[capsule_, opts___]
SourceVaultVerifyCapsuleSignature[capsule_, opts___]
SourceVaultSelectEnvelopeForSelf[capsule_, opts___]
SourceVaultConvertEncryption[id_, targetSpec_, opts___]
```

### 13.5 envelope 選択

`SourceVaultOpenCapsule` は次の順で envelope を選ぶ。

1. local KeyRef index から self envelope private key に対応する encryption fingerprint を列挙する。
2. `capsule["Envelopes"]` の `RecipientEncryptionFingerprint` と突合する。
3. 一致がなければ `Reason -> "NotARecipient"` で plaintext を返さない。
4. 一致した envelope の `WrappedPayloadKey` を `NBDecryptEnvelopeWithKeyRef` で開き、`payloadKey` を得る。
5. `payloadKey` から HKDF で `payloadEncKey` / `payloadMacKey` を派生する。
6. `payloadMacKey` による payload HMAC、または AEAD tag を検証する。
7. `SenderSigningFingerprint` に対応する signing public key で capsule signature を検証する。
8. payload HMAC / AEAD と capsule signature の両方が成功した場合だけ payload を復号する。

### 13.6 conversion

- symmetric at-rest record → capsule: ローカルで復号し、新しい `payloadKey` を生成し、HKDF 派生した payload 鍵で再暗号化し、`payloadKey` を受信者 encryption public key で包み、送信者 signing private key で署名する。
- capsule → local encrypted vault: 自分の private key で `payloadKey` を復号し、payload HMAC / signature を検査し、ローカル master key で再暗号化して保存する。
- public-key encrypted payload → symmetric record への直接変換は、復号権限を持つユーザのローカル環境でのみ可能。

## 14. key rotation

### 14.1 API

```wl
SourceVaultRotateKey[oldKeyRef_String, newKeyRef_String, opts___]
SourceVaultReencryptRecord[recordId_String, newKeyRef_String, opts___]
SourceVaultKeyRotationReport[opts___]
```

### 14.2 正しい不変条件

rotation test は `ciphertext hash が変わる` を根拠にしない。正しい不変条件は次である。

1. rotation 前の plaintext と rotation 後に新鍵で復号した plaintext が一致する。
2. old key で新 record は復号できない、または old key は retired として解決拒否される。
3. record の `KeyRef` が new KeyRef を指す。
4. `PlaintextDigest` が HMAC かつ rotation-stable digest key を使う場合のみ digest 一致を補助条件にする。
5. `CiphertextChecksum` の変化は security 判定に使わない。

### 14.3 old key の扱い

old key は即削除せず、まず `Retired` にする。

```wl
"Status" -> "Active" | "Retired" | "Revoked" | "Destroyed"
```

`Retired` key は復旧目的の読み取りだけ許すか、policy により完全拒否する。少なくとも新規 encryption には使わない。

`NBDeleteCredentialKey` / key destruction の前には、対象 KeyRef を参照する live record / capsule / quarantine が残っていないことを検査する。参照が残る場合は既定で拒否し、force 実行時も「永久に復号不能になる」ことを明示承認させる。

---

## 15. SourceVaultPromptRouterStatus / Doctor / PARITY

### 15.1 PromptRouter status

`Notes` を真実源にしない。boolean capability fields を真実源にする。

```wl
SourceVaultPromptRouterStatus[] := <|
  "Phase" -> "SV-E3",
  "ResolveImplemented" -> True | False,
  "ExecuteImplemented" -> True | False,
  "RegistryWritable" -> True | False,
  "EncryptionImplemented" -> True | False,
  "EffectiveIntegrityMode" -> "EncryptThenMAC" | "AuthenticatedEncryption" | "Unavailable",
  "AEADGCMAvailable" -> True | False,
  "RSAPSSSignatureAvailable" -> True | False,
  "EncryptedSaveLastPromptImplemented" -> True | False,
  "PrivatePromptPlaintextPolicy" -> "Refuse" | "WarnWithApproval" | "Allow",
  "SafeForPrivatePrompts" -> True | False,
  "RecordPolicyEnforcedOnCloudRoutes" -> True | False,
  "PublicKeyRegistryImplemented" -> True | False,
  "PublicKeyRegistrySchemaVersion" -> 2 | Missing["NotImplemented"],
  "CapsuleSharingImplemented" -> True | False,
  "CapsuleSignatureImplemented" -> True | False,
  "MigrationToolImplemented" -> True | False,
  "StorageProfileImplemented" -> True | False,
  "ProtectedNotebookSaveImplemented" -> True | False,
  "SaveHookCapability" -> "Unsupported" | "SupportedNotebookLevel" | "SupportedFrontEndLevel" | "Untested",
  "PaletteProtectedSaveImplemented" -> True | False,
  "TrustedBaselineRegistryImplemented" -> True | False,
  "TrustedBaselineVerified" -> True | False,
  "TrustedBaselineRevision" -> _Integer | Missing["Unavailable"],
  "MailSnapshotImplemented" -> True | False,
  "MaildbCompatibilityAdapterImplemented" -> True | False,
  "RecipientAccessProfileImplemented" -> True | False,
  "MessageReleasePlanImplemented" -> True | False,
  "MailSendReleaseAuditEnforced" -> True | False,
  "StatusSource" -> "ComputedFromCapabilities",
  "Notes" -> generatedNotes
|>
```

Resolve / Execute がまだスケルトンの場合は、`ResolveImplemented -> False`, `ExecuteImplemented -> False` を明示し、暗号化 prompt の再利用がどの範囲まで可能かを status に出す。

### 15.2 SourceVaultDoctor

```wl
SourceVaultDoctor[]
```

検査項目:

- `SourceVaultInitializeEncryption[]` が済んでいるか。
- active Trusted Baseline manifest が存在し、署名 / MAC / revision chain / pinned root fingerprint の検証に成功するか。
- StorageProfile / CloudStoreProfile / LLMRouteProfile / IMAPAccountProfile が unsigned JSONL や手書き association から直接読まれていないか。
- baseline に rollback / fork / stale revision / unapproved edit がないか。
- default at-rest encryption KeyRef が存在するか。
- default at-rest MAC KeyRef が存在するか。
- plaintext HMAC KeyRef が存在するか。
- mail identity / header token HMAC KeyRef (`SourceVault:mailid:mac:v1`) が存在し、rotation-stable として登録されているか。
- local capsule quarantine MAC KeyRef が存在するか。共有 payload MAC に固定 KeyRef が使われていないか。
- self envelope private key / self signing key が必要に応じて存在するか。
- KeyRef index に鍵材料が含まれていないか。
- mail token / RecordId 用 HMAC 鍵の鍵材料が record / JSONL / 同期フォルダ / log に出ていないか。
- mail header re-seal が `HeaderPL` / `HeaderConfidence` を生成済み record で record 単位に実行され、`HeaderPL` missing のまま plain header に降格していないか。
- credential 復元に `ToExpression` が使われていないか。
- private key が SourceVault record に保存されていないか。
- public key registry が二鍵 schema であり、encryption public key fingerprint / signing public key fingerprint が再計算値と一致するか。
- `PromptStorageClass -> "Plaintext"` の private prompt が残っていないか。
- `Encrypt -> True` の roundtrip が成功するか。
- effective integrity mode が `EncryptThenMAC` か、実測済みの `AuthenticatedEncryption` か。
- wrong key / tampered ciphertext / tampered HMAC / tampered AAD で plaintext を返さないか。
- `Policy.CloudSendAllowed` / `Derived.PrivacyLevel` / `AccessTags` / `HeaderPL` / `HeaderPolicy` などの判定駆動 metadata を手書き変更した record が HMAC mismatch で拒否されるか。
- record policy が cloud route で強制されるか。
- migration が dry-run で対象を正しく列挙するか。
- capsule payload HMAC が payload key から HKDF 派生された MAC 鍵で検証されるか。
- capsule signature の検証が失敗時に import を拒否するか。
- RSA-PSS 署名 capability が検査され、未対応環境で署名済み扱いにならないか。
- unsupported capsule version を拒否するか。
- store path が Dropbox / OneDrive / Google Drive / iCloud Drive 等の同期フォルダ配下でないか。該当時は `MigrationProtectsCloudHistory -> False` を warning する。
- Notebook / `$packageDirectory` / agent workspace の `StorageProfile` が正しく計算されるか。
- high PL plaintext cell が `MaxPlaintextPL` の低い保存先に残っていないか。
- protected notebook の encrypted cell placeholder が復号可能で、raw plaintext が file bytes に含まれないか。
- Save hook capability が検査済みか。未対応なら palette button が利用可能か。
- MailDB / IMAP adapter が plaintext body / attachment / credential を SourceVault record / log に漏らしていないか。
- mail snapshot の body / attachment / embedding が PL と tag policy に応じて encrypted / suppressed されているか。
- RecipientAccessProfile と public key registry が一致し、same-system recipient だけが encrypted capsule を受け取れるか。
- MessageReleasePlan が plaintext / encrypted capsule / redaction を正しく分け、SendMail 前に release audit と human confirmation を要求するか。
- destroyed / retired key を参照する live record が残っていないか。
- status boolean と実装 capability が一致するか。

追加 Doctor checks:

```wl
"RecordPolicyLooseningGate" -> "Pass" | "Fail",
"RecipientProfilesAuthenticated" -> "Pass" | "Fail",
"PublicKeyRecordsAuthenticated" -> "Pass" | "Fail",
"PolicyDeltaLogChainValid" -> "Pass" | "Fail",
"UnauthorizedLooseningPendingOnly" -> "Pass" | "Fail"
```

Doctor は、承認無し loosening が active state に入っていないこと、recipient profile / public key record が authenticated record として検証可能であること、policy delta log の digest chain と revision monotonicity が保たれていることを検査する。

### 15.3 PARITY_SOURCEVAULT.md

最低限の lane:

| Lane | Status | Tests | Mock/Real | Risk |
|---|---|---|---|---|
| KeyRef bootstrap | Pass/Partial/Fail | ... | Real | High |
| NBAccess crypto no-key-return | Pass/Partial/Fail | ... | Real | High |
| Encrypt-then-MAC primary mode | Pass/Partial/Fail | ... | Real | High |
| AEAD capability probe | Pass/Partial/Fail | ... | Real | Medium |
| AAD metadata authentication | Pass/Partial/Fail | ... | Real | High |
| Plaintext HMAC / suppression | Pass/Partial/Fail | ... | Real | High |
| PromptRouter Encrypt -> True | Pass/Partial/Fail | ... | Real | High |
| Plaintext migration | Pass/Partial/Fail | ... | Real | High |
| CloudSendAllowed enforcement | Pass/Partial/Fail | ... | Real | High |
| PublicKey registry two-key model | Pass/Partial/Fail | ... | Real | Medium |
| Capsule payload HKDF MAC | Pass/Partial/Fail | ... | Real | High |
| Capsule signature | Pass/Partial/Fail | ... | Real | High |
| StorageProfile classification | Pass/Partial/Fail | ... | Real | High |
| Protected notebook save | Pass/Partial/Fail | ... | Real | High |
| MailDB snapshot import | Pass/Partial/Fail | ... | Real/Mock IMAP | High |
| RecipientAccessProfile tag policy | Pass/Partial/Fail | ... | Real | High |
| MessageReleasePlan plaintext/capsule/redaction | Pass/Partial/Fail | ... | Real | High |
| Mail reply release audit | Pass/Partial/Fail | ... | Real | High |
| Save hook / palette fallback | Pass/Partial/Fail | ... | Real | Medium |
| Rotation invariants | Pass/Partial/Fail | ... | Real | High |
| Doctor status freshness | Pass/Partial/Fail | ... | Real | Medium |

---

## 16. テスト仕様

### 16.1 P0 テスト

| Test | Expected |
|---|---|
| hardcoded secret grep | 実 key / password / API key / private key の直書きは失敗。`SystemCredential[keyRef]` 参照は許可。ただし固定 key name の乱用は warning。 |
| no `ToExpression` credential restore | SourceVault key material 復元経路に `ToExpression` が存在しない。 |
| NBAccess no-key-return | SourceVault public API から key material が返らない。ログ・例外にも出ない。 |
| bootstrap idempotency | `SourceVaultInitializeEncryption[]` の二回目実行で既存鍵を破壊しない。 |
| encrypt-then-MAC roundtrip | `SourceVaultEncryptedPut` → `SourceVaultEncryptedGet` で一致し、effective mode が `EncryptThenMAC`。 |
| AEAD probe | GCM 利用可否を実測し、不可なら AEAD を使ったと偽装しない。 |
| tampered ciphertext | HMAC/AEAD 検証に失敗し plaintext を返さない。 |
| tampered crypto metadata | `Algorithm` / `IntegrityMode` / `KeyRef` / `IV` / `Nonce` / `PayloadCanonicalization` / `PayloadSerializationFormat` / `AuthenticatedBytesCanonicalization` の改ざんで HMAC/AEAD 検証に失敗する。 |
| wrong key decrypt | 復号失敗し plaintext を返さない。 |
| raw prompt leak scan | `SaveLastPrompt[..., "Encrypt" -> True]` 後に JSONL / registry / log に raw prompt が残らない。 |
| private prompt plaintext policy | privacy threshold 以上で `Encrypt -> False` は拒否または承認待ち。 |
| record cloud policy | `CloudSendAllowed -> False` の encrypted/private record が cloud route に materialize されない。 |
| migration dry-run | 既存平文 private prompt を検出し、書き換えず report を出す。 |
| migration execute | 対象平文 prompt を暗号 record に変換し、旧 store を generation replace する。 |
| public key registry two-key model | `EncryptionPublicKey` / `SigningPublicKey` が別 field として保存され、encryption fingerprint と signing fingerprint の再計算が一致。private key は record に存在しない。 |
| self-only keypair generation | 他者 recipientId に対する private key 生成を拒否する。 |
| capsule payload HKDF MAC | 受信者が envelope から得た `payloadKey` で `payloadMacKey` を HKDF 派生して payload HMAC を検証できる。送信者ローカル固定 MAC KeyRef は不要。 |
| capsule two recipients | 2 受信者がそれぞれ自分の private key で開ける。第三者は開けない。 |
| capsule signature tamper | manifest / envelope / payload / signing fingerprint 改ざん時に署名検証失敗で import 拒否。 |
| signature capability probe | RSA-PSS 署名が使えない環境では `CapsuleSignatureImplemented -> False` になり、署名済み capsule を作成しない。 |
| capsule unsupported version | 未対応 `CapsuleVersion` を拒否する。 |
| key rotation | 新鍵 roundtrip 成功、旧鍵不可、record KeyRef 更新。ciphertext checksum 変化は判定条件にしない。 |
| key deletion reference check | live record が参照する KeyRef の削除を既定拒否する。 |
| cloud sync migration warning | Dropbox / OneDrive 等の同期パスでは `MigrationProtectsCloudHistory -> False` を出す。 |
| StorageProfile threshold | Dropbox / OneDrive / `$packageDirectory` / agent workspace で `MaxPlaintextPL` が期待値以下になる。agent readable workspace は cloud LLM route 相当に下げる。 |
| protected notebook save | `dataPL > MaxPlaintextPL` の cell が encrypted placeholder に置換された protected copy だけが保存され、元 notebook は破壊されない。 |
| protected notebook leak scan | 保存済み `.nb` bytes に raw high PL cell content / canonical plaintext bytes が含まれない。 |
| sidecar missing detection | sidecar encrypted record がない protected notebook を Doctor が warning / fail にする。 |
| Save hook failure safe | Save hook が未対応・失敗・再帰検出した場合、平文保存へ silent fallback せず、abort または palette 誘導になる。 |
| mail HMAC key bootstrap | `SourceVault:mailid:mac:v1` が bootstrap され、RecordId / header token の生成に使われるが、鍵材料は record / JSONL / log / 同期フォルダに出ない。 |
| maildb credential no-leak | IMAP password / app password / credential value が SourceVault record / JSONL / log に出ない。credential key 名だけを KeyRef として扱う。 |
| mail snapshot encrypted import | 高 PL の mail body / attachment が encrypted record として import され、旧 maildb 平文 DB は migration report に列挙される。 |
| recipient tag policy deny | PL は足りていても `NoEmail` / `NoExternal` / tag mismatch の material は MessageReleasePlan で redacted になる。 |
| tag policy semantics | Deny-wins、階層 wildcard、未知 tag deny、purpose denied、期限切れ profile を検査する。 |
| unknown recipient fail-closed | 未登録受信者は `MaxPlaintextPL -> 0.0` / `MaxEncryptedReadablePL -> 0.0` となり、高 PL だけでなく中 PL も自動で出ない。 |
| same-system encrypted capsule | 受信者が verified public key を持つ場合、メール本文には入れられないが受信者権限内の material は encrypted capsule に入る。 |
| non-system recipient no fallback | 公開鍵未登録の受信者に対し、高 PL material が平文要約として fallback されない。 |
| mail send requires audit | `SendReply` 相当の操作は MessageReleasePlan と human confirmation を通らない限り実行されない。 |

追加 P0 テスト:

- **policy loosening requires external approval**: `PrivacyLevel` downgrade、`CloudSendAllowed -> True`、`AccessTags` 追加、`DenyTags` 削除、recipient `MaxPlaintextPL` 引上げ、public key `TrustStatus` 昇格は、agent 外承認が無い限り pending に留まり active state へ入らない。
- **derived under-classification fail-closed**: local LLM が低 PL を返しても `PrivacyConfidence` が閾値未満または Missing の場合、import 時 high PL を維持する。
- **recipient/public-key authenticated**: recipient profile または public key record の JSONL 直接改ざんにより `MaxPlaintextPL` や `TrustStatus` を上げても、HMAC mismatch / delta chain failure で release が拒否される。
- **policy delta log integrity**: `PreviousPolicyStateDigest` の改ざん、delta 欠落、revision rollback、承認無し loosening は fail-closed になる。
- **initial write vs update**: legacy migration の初回 authenticated write は成功し、既存 authenticated record update は current auth 検証失敗時に拒否される。

### 16.2 P1 テスト

| Test | Expected |
|---|---|
| PlaintextIndex suppression | private prompt で `SearchTokens` / `PublicSummary` が `Missing`。 |
| metadata leakage report | Doctor が平文 metadata の残存範囲を表示する。 |
| canonical JSON interop | capsule signed bytes と public key record が WL バージョン非依存 canonical JSON + Base64 で生成される。 |
| at-rest canonicalization fields | encrypted record が `PayloadCanonicalization` / `PayloadSerializationFormat` / `AuthenticatedBytesCanonicalization` を別 field として持つ。 |
| RSA-OAEP envelope | payload key wrapping が RSA-OAEP で、鍵長要件を満たさない鍵を拒否する。 |
| PromptRouter status freshness | status boolean が実装状態と一致し、Notes は生成物。 |
| Resolve/Execute dependency | Resolve/Execute がスケルトンなら、暗号化 prompt reuse の未完範囲を status に出す。 |
| Directive verification | 新規 encryption / sharing directive が hash / provenance 付きで検証される。 |
| PARITY report | `PARITY_SOURCEVAULT.md` に lane / status / tests / risk が出る。 |
| protected save UI | ClaudeCode palette に「保護して保存」「保護コピーを別名保存」「保存先診断」が表示される。 |
| maildb compatibility search | 既存 `mailSearchForLLM` 相当の検索結果を SourceVault snapshot search で再現し、privacy/tag/release plan に接続できる。 |

---

## 17. 実装順序 v18

1. **Directive 追加**: `CiphertextChecksum は MAC ではない`、`PlaintextDigest は既定 HMAC`、`鍵は ToExpression で復元しない`、`CloudSendAllowed は強制`、`共有 capsule payload MAC は payloadKey 派生`、`mail header は StorageProfile 閾値連動`、`mail derived fields は checkpoint 可能`、`baseline policy は signed/MACed manifest で検証する`ことを明記する。
2. **crypto capability probe**: AEAD/GCM と RSA-PSS 署名の利用可否を `SourceVaultCryptoCapabilityReport[]` で実測する。
3. **NBAccess crypto 層**: `NBEncryptWithKeyRef` / `NBDecryptWithKeyRef` / `NBMacWithKeyRef` / `NBSignWithKeyRef` / `NBDecryptEnvelopeWithKeyRef` を主 API にし、鍵を SourceVault へ返さない。
4. **master / digest / mail token / baseline 鍵 bootstrap**: `SourceVaultInitializeEncryption[]` を Put/Get より前に実装する。at-rest MAC、plaintext digest HMAC、`SourceVault:mailid:mac:v1`、`SourceVault:baseline:policy-mac:v1`、`SourceVault:baseline:policy-sign:v1`、local capsule quarantine MAC、self envelope private key、self signing key を生成対象にする。`SourceVault:mailid:mac:v1` と baseline root keys は通常 rotation から分離する。
5. **Trusted Baseline Registry**: `SourceVaultInitializeTrustedBaseline` / `SourceVaultRegisterBaselineEntry` / `SourceVaultVerifyBaseline` / `SourceVaultActivateBaseline` を実装し、StorageProfile / CloudStoreProfile / LLMRouteProfile / IMAPAccountProfile を signed/MACed baseline に移す。
6. **record-level policy AAD + delta log**: `Policy` / `Derived` / `MailMetadataPublic.DecisionState` / `ReleasePolicy` / `RecipientPolicy` / `PublicKeyTrustState` のサブ association 全体を AAD に含め、`SourceVaultAppendAuthenticatedPolicyDelta` / `SourceVaultResolveAuthenticatedPolicyState` / `SourceVaultUpdateAuthenticatedRecordPolicy` を実装する。derived batch / re-seal / declassify は delta log 経由で active state を更新する。
7. **policy loosening approval gate**: `SourceVaultClassifyPolicyUpdate` / `SourceVaultRequestRecordPolicyLoosening` / `SourceVaultApproveRecordPolicyLoosening` を実装し、PL downgrade、CloudSendAllowed true、tag 緩和、recipient access 引上げ、public key trust 昇格を agent 外承認必須にする。
8. **baseline enforcement wiring**: `SourceVaultStorageProfile` / `SourceVaultResolveTrustedLocalServer` / `SourceVaultResolveIMAPAccount` / `SourceVaultLLMRouteProfile` が active baseline 検証を通らなければ fail-closed になるようにする。
9. **canonical bytes + authenticated encryption**: `SourceVaultCanonicalBytes/Internal/v1`、`SourceVaultCanonicalJSON/v1`、`SourceVaultAtRestAuthenticatedBytes/v1` を実装し、encrypt-then-MAC を既定にする。
10. **EncryptedVault record schema**: `PayloadCanonicalization` / `PayloadSerializationFormat` / `AuthenticatedBytesCanonicalization` を分離した `SourceVaultEncryptedPut/Get` の最小 roundtrip を作る。
11. **SourceVaultAssertNoPlaintextLeak**: JSONL / registry / log への append 前検査を実装する。
12. **PromptRouter `Encrypt -> True`**: private prompt を安全に保存できるようにする。
13. **PromptRouter status の boolean 真実源化**: Resolve/Execute 未完との依存も明記する。
14. **cloud route policy enforcement**: `SourceVaultAuthorizeRecordMaterialization` を cloud 送信経路に配線する。LLM route profile は Trusted Baseline から解決する。
15. **StorageProfile と保存先判定**: `SourceVaultStorageProfile` / `SourceVaultCloudSyncPathQ` / `SourceVaultAgentReadablePathQ` を実装する。StorageProfile は Trusted Baseline entry として管理する。
16. **protected notebook save**: `SourceVaultProtectionPlan` / `SourceVaultSaveProtectedNotebook` / `SourceVaultNotebookProtectionReport` を実装する。
17. **CladeCode palette button**: 「保護して保存」「保護コピーを別名保存」「保存先診断」を追加する。
18. **Save hook capability probe**: `SourceVaultSaveHookCapabilityReport` を作り、対応環境でのみ notebook-level hook を補助的に有効化する。
19. **PublicKey registry 二鍵 schema**: self keypair 生成と他者 public key 登録を、暗号用 / 署名用の 2 鍵モデルで実装する。
20. **Hybrid capsule + signature**: payload MAC は HKDF-from-payloadKey、envelope は RSA-OAEP、signature は RSA-PSS-SHA256 を既定にする。
21. **Public-key bootstrap for recipients**: signed public-key capsule / TOFU / out-of-band verification / TOFU 上限を実装する。
22. **MailDB step0**: legacy maildb writer / scheduled task を止め、同期パスへの新規平文書き込みを遮断する。
23. **MailDB compatibility adapter**: `SourceVaultImportMaildbFile` / `SourceVaultImportMailSnapshot` / `SourceVaultMigrateMaildbToSourceVault` を dry-run 既定で追加する。
24. **Mail header StorageProfile policy**: `SourceVaultMailHeaderProtectionPlan` / `SourceVaultMailHeaderPlaintextThreshold` を実装し、import 時は provisional encrypted、PL 確定後は threshold 以下だけ plain / mixed header に re-seal できるようにする。
25. **Mail HeaderPL inference**: `SourceVaultInferMailDerivedBatch` の既定 fields に `HeaderPL` / `HeaderConfidence` を含め、header-only local inference または conservative fallback を実装する。`$SourceVaultMailHeaderMinConfidence` 未満または Missing は fail-closed とする。
26. **Mail header tokenization / encrypted import**: `Subject` / `From` / `To` / `Cc` / `MessageID` / attachment filename を encrypted header または HMAC token にする。`SubjectPreview` は閾値超・PL 未確定・低 confidence で必ず抑制する。
27. **Mail derived-field checkpoint batch**: `SourceVaultInferMailDerivedBatch` / `SourceVaultMailDerivedCheckpointStatus` を実装し、未処理のみ、1 通ごと checkpoint、再開可能、`LocalModelOnly -> True` を既定にする。
28. **Per-record header re-seal hook**: checkpoint commit 直後に同じ record を locked re-seal し、中断しても完了済み record の検索性を回復する。batch 完了後一括 reclassify は保存先変更時の再評価用に残す。
29. **Mail derived-field materialization**: private summary / embedding / tag inference を local-only にし、既存 cloud-derived fields は provenance + Doctor warning にする。
30. **Mail embedding search**: encrypted vector store と memory-only KDTree / nearest index を実装し、disk-backed persistence を禁止する。
31. **SourceVault AddressBook**: ContactRecord / GroupRecord / DomainPolicy / CategoryPolicy を authenticated record として実装し、email tokenization、uid / ContactId 管理、SourceVault nickname / public key 連携を作る。
32. **AddressBook-based mail resolution**: IMAP import 時に From / To / Cc / Reply-To / group address / domain / category を解決し、MailSnapshot の AddressBookRefs と policy reevaluation flag に反映する。
33. **RecipientAccessProfile + tag policy**: AddressBook 解決結果から RecipientAccessProfile を生成し、Deny-wins、階層 tag、unknown fail-closed、purpose check、二重承認 override を実装する。
34. **MessageReleasePlan**: plaintext / encrypted capsule / redacted の分類を実装し、未知受信者・未検証 key では高 PL material を平文 fallback しない。
35. **Mail UI / PromptRouter panels**: `SourceVaultMailView` / `SourceVaultMailSearchPanel` / `SourceVaultAddressBookPanel` / `SourceVaultPromptRouterMailPanel` を作り、`showMails` 相当の表示と draft + release audit actions を提供する。
36. **Mail draft integration**: ClaudeEval からの返信指示は draft-only で作り、release audit と human confirmation を経て SendMail する。
37. **既存平文 migration**: prompt-runs / notebook protected copies / maildb `.wl` / attachments / embedding / baseline drafts を dry-run 既定で migration し、同期履歴の限界を明示する。
38. **SourceVaultDoctor / PARITY**: baseline signature/MAC/rollback、mail HeaderPL、checkpoint、storage sync、cloud-generated embedding、protected notebook、capsule、PromptRouter を CI / Doctor に載せる。
39. **Git/diff/MCP/LSP workflow**: 安全基盤が閉じてから外骨格を拡張する。
## 18. 改訂後の優先順位

| 優先度 | 項目 | 理由 |
|---|---|---|
| P0 | NBAccess crypto no-key-return | 鍵材料を SourceVault やログへ出さない根本境界。 |
| P0 | Encrypt-then-MAC primary + AAD | WL の AEAD 可否に依存せず、暗号文・暗号メタデータ改ざんを検出するため。 |
| P0 | PlaintextDigest HMAC / suppression | private prompt の低エントロピー漏洩を避けるため。 |
| P0 | SourceVaultInitializeEncryption | at-rest 暗号鍵、MAC 鍵、digest 鍵、mail identity/token HMAC 鍵、baseline policy MAC / signing 鍵、capsule 鍵、署名鍵の初回生成がないと Doctor だけでは運用できない。 |
| P0 | policy loosening approval gate | AAD/HMAC は file 改ざんを止めるが、正規 API 経由の PL downgrade / declassify は承認ゲートがないと成立してしまうため。 |
| P0 | Recipient/PublicKey authenticated records | release 判定は相手側 profile と public key trust も読むため、これらも authenticated + loosening-gated でなければならない。 |
| P0 | Trusted Baseline Registry | StorageProfile / CloudStoreProfile / LLMRouteProfile / IMAPAccountProfile の改ざんは、暗号化済み record 以前に policy 判定を破壊するため。署名・MAC・rollback 防止を必須にする。 |
| P0 | record-level policy AAD | `PrivacyLevel` / `CloudSendAllowed` / `AccessTags` / `HeaderPL` の平文 metadata 改ざんだけで release 判定が壊れるため、AAD/HMAC で認証する。 |
| P0 | SourceVaultEncryptedPut/Get | at-rest encryption の最小中核。 |
| P0 | PromptRouter `Encrypt -> True` | private prompt reuse の安全保存の中核。 |
| P0 | SourceVaultMigrateToEncrypted | 既存平文 JSONL が残ると安全化が完了しない。 |
| P0 | StorageProfile / protected notebook save | Notebook 保存先が低 PL 境界の場合、高 PL セルを平文保存しないため。 |
| P0 | ClaudeCode palette protected save | Save hook が不完全でもユーザーが安直に安全保存できる主 UX を確保するため。 |
| P0 | record-level cloud policy enforcement | `CloudSendAllowed` を助言で終わらせないため。 |
| P0 | MailDB snapshot encrypted import | メール本文・添付・embedding を SourceVault の一時ソース snapshot として安全に取り込むため。 |
| P0 | Mail header StorageProfile threshold | Dropbox 等では通常メールの件名検索性を残しつつ、閾値超・未分類・低 confidence のヘッダは encrypted header に保つため。 |
| P0 | Resumable mail derived batch | ローカル LLM による PL / summary / embedding 推定を長時間実行しても、強制終了後に完了分を失わず再開するため。 |
| P0 | SourceVault AddressBook / Group / DomainPolicy | mail sender / recipient / domain / group / spam category が PL 推定と release planning を左右するため。AddressBook 自体も authenticated record とし、loosening は承認対象にする。 |
| P0 | RecipientAccessProfile + tag policy | 受信者ごとの PL とタグ権限に基づき、送信可否を数値だけでなく文脈で判定するため。未知受信者は fail-closed とし、Deny-wins を固定する。 |
| P0 | MessageReleasePlan | メール本文に平文で入れる情報、公開鍵 capsule に入れる情報、省略する情報を送信前に強制分離するため。 |
| P0 | Mail send audit / human confirmation | 自動返信生成が release boundary を越えるため、SendMail 前の監査と確認を必須にするため。 |
| P0 | capsule payload HKDF MAC | 受信者が検証できない送信者ローカル固定 MAC を共有 payload に使わないため。 |
| P0 | capsule signature + two-key public registry | 共有時の送信者認証・改ざん検出と envelope 選択を混同しないため。 |
| P0.5 | NBAccess ticket / replay 防止 | 実行前再検証は改善済み。承認 capability の堅牢化が残る。 |
| P1 | SourceVaultDoctor / PARITY | 安全状態を人間と CI が確認できるようにする。 |
| P1 | Save hook capability probe | NotebookEventActions / FrontEndEventActions を使える環境では通常 Save の補助保護を行うため。ただし安全境界にはしない。 |
| P1 | PublicKey registry UX | 共有運用・検証・失効を管理するため。 |
| P2 | Git/diff/PR workflow | 安全基盤完成後でよい。 |
| P2 | MCP/LSP/tool registry | 汎用 coding agent 化には必要だが、暗号化より後。 |

---


## 19. Trusted Baseline Registry: 基礎ポリシーデータの改ざん検証

### 19.1 位置づけ

IMAP account、Dropbox / OneDrive / iCloud / Google Drive などの cloud store、Claude Code readable workspace、LM Studio / Ollama / local OpenAI-compatible server、cloud LLM provider、mail transport、default PL threshold は、SourceVault の通常データではなく **policy root に近い基礎データ**である。

これらが改ざんされると、暗号化済み record 自体は守られていても、次のような誤判定が起こる。

- Dropbox を `AuditedEncryptedLocalStorage` 相当として扱い、高 PL セルを平文保存する。
- cloud LLM endpoint を local trusted server と偽り、private prompt を送信する。
- IMAP account の `MaxPlaintextPL` を高くし、private mail header を平文化する。
- unknown recipient の既定 profile を fail-open に変更する。
- `NoEmail` / `NoExternal` tag の deny rule を無効化する。

したがって、baseline は confidentiality だけでなく **integrity / authenticity / rollback resistance** が主目的である。非鍵 SHA256 は同一性確認や diff には使えるが、攻撃者が manifest と hash を同時に書き換えられるため真正性根拠にはならない。

### 19.2 Trusted Baseline に含める entry

```wl
SourceVaultTrustedBaselineEntry = <|
  "Type" -> "SourceVaultTrustedBaselineEntry",
  "SchemaVersion" -> 1,
  "EntryId" -> entryId,
  "EntryKind" ->
      "StorageProfile" |
      "CloudStoreProfile" |
      "LLMRouteProfile" |
      "TrustedLocalServer" |
      "IMAPAccountProfile" |
      "MailTransportProfile" |
      "RecipientDefaultPolicy" |
      "PLThresholdPolicy" |
      "TagPolicyRoot",
  "CanonicalProfile" -> canonicalJSONAssociation,
  "EffectiveAccess" -> <|
    "MaxPlaintextPL" -> value,
    "MaxEncryptedReadablePL" -> value | Missing["NotApplicable"],
    "TrainingUse" -> "Allowed" | "Disabled" | "ContractuallyDenied" | Missing["NotApplicable"],
    "ExternalStorage" -> "None" | "CloudStorage" | "CloudProcessor" | "MailTransport",
    "RetentionRisk" -> "Low" | "Medium" | "High",
    "HumanReviewRisk" -> "Low" | "Medium" | "High",
    "LocalSecurity" -> "Unchecked" | "Checked" | "Audited" | Missing["NotLocal"]
  |>,
  "AllowedPurposes" -> {"Storage", "Inference", "Embedding", "MailImport", "MailSend", "NotebookSave"},
  "CreatedAt" -> utcIsoDateTime,
  "UpdatedAt" -> utcIsoDateTime,
  "Status" -> "Active" | "Pending" | "Retired" | "Revoked",
  "HumanApproved" -> True | False,
  "ApprovalRecordRef" -> approvalRef | Missing["NotApproved"]
|>;
```


`EffectiveAccess` は `CanonicalProfile` から導出される純関数の結果であり、手入力の任意 cache として扱ってはならない。baseline signing 時と verify 時に `SourceVaultDeriveEffectiveAccess[CanonicalProfile]` を再計算し、保存された `EffectiveAccess` と一致することを確認する。不一致なら baseline は invalid とする。

例として、`NBAccess` の trusted local server 登録は次のような baseline entry に正規化して保存する。

```wl
NBAccess`NBRegisterTrustedLocalServer[
  <|"MachineName" -> "phoenix",
    "Subnet" -> "192.168.2",
    "Provider" -> "lmstudio",
    "URL" -> "http://192.168.2.110:1234"|>
]
```

これは `EntryKind -> "TrustedLocalServer"`、`ExternalStorage -> "CloudProcessor"` ではなく local network processor、`TrainingUse -> "Disabled"`、`LocalSecurity -> "Checked" | "Audited"` のような profile として扱う。ただし同じ LAN 内であっても、baseline 検証に失敗した場合や `MachineName` / `Subnet` / `URL` が署名済み entry と一致しない場合は trusted route として使わない。

ただし baseline は **設定値の完全性**を保証するだけで、実際にその `URL` の応答者が本物の local LLM server であることや、LAN 上の盗聴・ARP spoofing から守ることは保証しない。trusted local server entry には次を持たせる。

```wl
"TransportSecurity" -> "TLSWithPinnedCertificate" | "TLSWithPinnedPublicKey" | "PlainHTTPLANTrusted",
"PinnedServerFingerprint" -> fingerprint | Missing["NotPinned"],
"RiskAcceptance" -> riskAcceptanceRef | Missing["NotRequired"]
```

既定推奨は TLS + certificate / public-key pinning である。`http://...` の plain LAN endpoint を使う場合は `TransportSecurity -> "PlainHTTPLANTrusted"` として明示 risk acceptance を baseline に含め、Doctor は warning を出す。private mail / private prompt を送る route では、baseline 完全性と endpoint 認証を別々に判定する。

### 19.3 baseline manifest schema

複数 entry は、active baseline manifest として canonical JSON 化し、MAC と署名を付ける。

```wl
SourceVaultTrustedBaselineManifest = <|
  "Type" -> "SourceVaultTrustedBaselineManifest",
  "SchemaVersion" -> 1,
  "BaselineId" -> baselineId,
  "Revision" -> positiveInteger,
  "PreviousBaselineDigest" -> digest | Missing["Initial"],
  "Entries" -> {SourceVaultTrustedBaselineEntry ...},
  "Canonicalization" -> "SourceVaultCanonicalJSON/v1",
  "Digest" -> digestOfCanonicalManifestForIdentity,
  "Integrity" -> <|
    "MAC" -> <|
      "Algorithm" -> "HMAC-SHA256",
      "KeyRef" -> "SourceVault:baseline:policy-mac:v1",
      "Value" -> mac
    |>,
    "Signature" -> <|
      "Algorithm" -> "RSA-PSS-SHA256",
      "SigningKeyRef" -> "SourceVault:baseline:policy-sign:v1",
      "SigningFingerprint" -> pinnedBaselineSigningFingerprint,
      "Value" -> signature
    |>
  |>,
  "ActivatedAt" -> utcIsoDateTime,
  "ActivatedBy" -> userOrMachineId,
  "Status" -> "Active" | "Superseded" | "Revoked"
|>;
```

`Digest` は identity / diff / chain 用であり、真正性根拠ではない。検証は `MAC` と `Signature` の両方、または少なくとも local-only 運用では `MAC`、共有・移行・複数端末運用では `Signature` を必須とする。

### 19.4 root of trust と pinning

署名検証用 public key や fingerprint まで SourceVault の通常 writable store にだけ置くと、攻撃者が baseline と verification key を同時に差し替えられる。したがって root は次のいずれかに pin する。

1. OS credential / NBAccess protected local config に `BaselineSigningFingerprint` を保存する。
2. 初回 bootstrap 時に fingerprint をユーザーへ表示し、紙・別端末・管理者メモ等で out-of-band 確認する。
3. 複数端末では TOFU だけで Active にせず、`VerifiedOutOfBand` までは低い trust ceiling を適用する。
4. baseline signing public key の変更は、旧 key による cross-sign または user approval + out-of-band confirmation を要求する。

### 19.5 API

```wl
SourceVaultInitializeTrustedBaseline[opts___]
SourceVaultRegisterBaselineEntry[entry_Association, opts___]
SourceVaultProposeBaselineUpdate[changes_, opts___]
SourceVaultSignBaseline[baseline_, opts___]
SourceVaultVerifyBaseline[baseline_:Automatic, opts___]
SourceVaultActivateBaseline[baseline_, opts___]
SourceVaultTrustedBaselineStatus[]
SourceVaultBaselineDoctor[]
SourceVaultExportBaselineBundle[opts___]
SourceVaultImportBaselineBundle[bundle_, opts___]
```

`SourceVaultRegisterBaselineEntry` は active baseline を直接変更しない。まず `Pending` baseline を作り、diff を表示し、人間の承認を経て署名・revision increment・activation を行う。

baseline activation の最終承認は、agent が直接作成・実行できる notebook cell や通常の `ClaudeEval` action space の内側に置いてはならない。最終承認は OS credential 書込み、別プロセスの確認ダイアログ、out-of-band fingerprint 入力、管理者署名など、agent が偽造しにくい経路で行う。agent は `Pending` baseline の作成、差分表示、リスク説明までを行ってよいが、user confirmation の最終確定と active 化は別境界に置く。

### 19.6 強制配線

次の関数は、profile を使う直前に必ず active baseline を検証する。

```wl
SourceVaultStorageProfile[path_]
SourceVaultCloudStoreProfile[name_]
SourceVaultLLMRouteProfile[providerOrRoute_]
SourceVaultResolveTrustedLocalServer[spec_]
SourceVaultResolveIMAPAccount[mbox_]
SourceVaultMailTransportProfile[recipientOrDomain_]
SourceVaultRecipientDefaultPolicy[]
SourceVaultTagPolicyEvaluate[...]
```

active baseline が存在しない、pinned revision と突合できない、manifest が削除されている、または検証に失敗した場合は、すべて同じ fail-closed とする。baseline 不在を permissive な初期状態として扱ってはならない。検証に失敗した場合は、より高い access level へ fallback しない。既定は次である。

```text
Baseline missing or verification failed:
  cloud route: denied
  local trusted server route: denied unless explicitly re-approved
  storage profile: MaxPlaintextPL = 0.0 or ProtectedSaveRequired
  mail import: encrypted-only, no plain header downgrade
  mail send: draft-only + release audit required
  SourceVaultBaselineRecoveryMode: enabled
```

性能上、RSA-PSS 署名検証を hot path の各判定で毎回実行する必要はない。session / load 単位で `SourceVaultVerifiedBaselineCache` を作り、pinned revision、manifest digest、verified signing fingerprint、verified at time、TTL を保存する。cache は file watcher、revision 変更、TTL 失効、OS credential の pinned revision 変更で invalidation する。cache が無効な場合は再検証し、再検証できない場合は上記 fail-closed に戻す。

### 19.7 rollback / fork / stale baseline 対策

- `Revision` は単調増加とし、`PreviousBaselineDigest` で hash chain を作る。
- active baseline revision は OS credential / NBAccess protected config にも保存する。
- SourceVault store 上の manifest が、pinned active revision より古い場合は rollback として拒否する。
- 同じ revision に異なる digest がある場合は fork として拒否する。
- `Pending` baseline は policy enforcement には使わない。
- active baseline が存在しない初期状態も `SourceVaultBaselineRecoveryMode` とし、`SourceVaultInitializeTrustedBaseline` が完了して pinned revision を確立するまで、cloud / mail send / plaintext downgrade を禁止する。
- emergency recovery は `SourceVaultBaselineRecoveryMode` とし、cloud / mail send / plaintext downgrade をすべて禁止した状態でのみ起動する。

### 19.8 Doctor / PARITY 追加項目

| Test | 期待 |
|---|---|
| baseline signature valid | active manifest の RSA-PSS 署名が pinned fingerprint と一致する。 |
| baseline MAC valid | local baseline MAC が一致する。 |
| baseline rollback rejected | 古い revision の manifest を active にできない。 |
| baseline fork rejected | 同一 revision / 異 digest を検出して fail-closed。 |
| unsigned StorageProfile rejected | 署名なし手書き StorageProfile を policy enforcement が使わない。 |
| tampered LLMRouteProfile rejected | trusted local server URL / subnet / provider 改ざんで route が denied になる。 |
| cloud store downgrade rejected | Dropbox profile を AuditedLocal 相当に改ざんしても protected save が許可されない。 |
| baseline missing is fail-closed | active manifest を削除しても permissive fallback せず、recovery mode に入る。 |
| trusted local endpoint warning | `PlainHTTPLANTrusted` route は Doctor warning を出し、private route では明示承認を要求する。 |
| effective access recomputed | `CanonicalProfile` と `EffectiveAccess` が不一致なら baseline verify が失敗する。 |
| baseline activation outside agent | agent-only action では active baseline を確定できない。 |
| baseline root key not in SourceVault | baseline signing private key / MAC key が JSONL / log / synced folder に出ない。 |
| tampered record privacy rejected | `Derived.PrivacyLevel` / `AccessTags` / `CloudSendAllowed` / `HeaderPL` を手書き改ざんすると record HMAC mismatch で拒否される。 |

## 20. まとめ

この v15 では、v3 以降の「encrypt-then-MAC を既定にし、共有を canonical JSON + Base64 に寄せる」という方向性を維持しつつ、共有 capsule、public key registry、MailDB release planning、mail identity/token HMAC 鍵の内部不整合を解消したうえで、メールヘッダの過剰暗号化と PL 推定バッチの再開不能性を解消した。

重要な変更は次である。

- `CiphertextHash` を完全性保証に使わず、encrypt-then-MAC を既定にする。
- `PlaintextHash` を生 SHA256 にせず、HMAC または抑制にする。
- `NBResolveCredentialKey -> key` ではなく、NBAccess 内部 crypto API を主にする。
- `ToExpression@SystemCredential[...]` は SourceVault では禁止する。
- 初回鍵生成 bootstrap と既存平文 migration を P0 に上げる。
- capsule は v1 から canonical JSON 署名対象を固定し、暗号用 fingerprint と署名用 fingerprint を分離する。
- capsule payload MAC は per-capsule `payloadKey` から HKDF 派生し、送信者ローカル固定 MAC KeyRef を共有 payload に使わない。
- public key record は `EncryptionPublicKey` / `SigningPublicKey` の二鍵 schema にする。
- at-rest record は payload canonicalization と authenticated bytes canonicalization を分離する。
- メールヘッダは一律暗号化ではなく、PL 未確定時は provisional encrypted、PL 確定後は `StorageProfile.MaxPlaintextPL` 由来の threshold 以下だけ plain / mixed header へ再封印できる。
- ローカル LLM による mail PL / HeaderPL / summary / embedding 推定は、未処理のみ・checkpoint append・再開可能・local-only を既定にする。
- `HeaderPL` / `HeaderConfidence` は header re-seal の必須入力とし、confidence が missing または閾値未満なら平文化しない。
- StorageProfile / CloudStoreProfile / LLMRouteProfile / IMAPAccountProfile などの基礎ポリシーデータは、Trusted Baseline Registry の signed/MACed manifest として保存し、検証失敗時は fail-closed とする。
- Trusted Baseline が存在しない初期状態、削除、rollback、fork、pinned revision 不一致はすべて検証失敗と同じ fail-closed とする。
- `Policy` / `Derived.PrivacyLevel` / `AccessTags` / `HeaderPL` / `HeaderPolicy` などの record-level policy metadata は AAD/HMAC で認証し、後続更新時は HMAC を再計算する。
- trusted local server は baseline 設定の完全性だけでなく、TLS + certificate/public-key pinning を推奨し、plain HTTP LAN route は明示 risk acceptance と Doctor warning を要求する。
- Dropbox / OneDrive 等の同期履歴は migration では回収できないことを Doctor で明示する。
- `Policy.CloudSendAllowed` を cloud route で強制する。
- Notebook / SourceVault record の保存は、保存先の `StorageProfile` へ高 PL 平文を移動する操作として扱う。
- Dropbox / OneDrive / Claude Code readable `$packageDirectory` など、保存先 `MaxPlaintextPL` が低い場所では、高 PL セルを encrypted placeholder または sidecar encrypted record にして保存する。
- Save menu hook は補助 UX とし、主経路は `SourceVaultSaveProtectedNotebook` と CladeCode palette の「保護して保存」ボタンにする。
- MailDB は SourceVault の IMAP 一時ソース / snapshot source として扱い、月次 `.wl` DB・添付ファイル・embedding index の平文残存を migration / Doctor 対象にする。
- メール返信・共有・export は `MessageReleasePlan` を通し、受信者の numeric PL、tag policy、public key status、mail transport の MaxPlaintextPL に基づいて plaintext / encrypted capsule / redaction を決める。
- 同じ SourceVault 系システムを使う受信者には verified public key による capsule を使い、使わない受信者には高 PL material を平文 fallback しない。

これにより、Phase SV-E3 / SV-E4 / SV-E5 は「暗号化したつもり」の仕様ではなく、SourceVault を private prompt / notebook knowledge / mail snapshot / shared capsule / recipient-bound reply workflow の安全基盤として使える設計になる。特に v15 では、Trusted Baseline Registry と record-level AAD/HMAC に加えて、AddressBook / Group / DomainPolicy / CategoryPolicy を authenticated policy graph として扱う。v16 ではさらに、IMAP / GitHub / arXiv / blog / PDF / 将来の SNS cache から identity observation を取り込み、AddressBook を provenance 付き Author Database として成長させる。これにより、攻撃者や prompt-injected agent が JSONL の平文 metadata だけでなく、contact / group / domain / recipient profile を改ざんして cloud 送信・平文化・過剰共有を誘発する経路も fail-closed にできる。


## 20. v14 追加テスト / Doctor 項目

以下を `PARITY_SOURCEVAULT.md` と `SourceVaultDoctor[]` の P0 テストに追加する。

| Test | 期待結果 |
|---|---|
| policy delta tail truncation | delta chain prefix 自体が HMAC-valid でも、policy head manifest の head revision / digest と一致しないため fail-closed |
| record deletion under head manifest | manifest に head がある record が store から消えていれば fail-closed |
| stale head manifest rollback | pinned manifest digest / revision より古い manifest を提示した場合 fail-closed |
| unknown policy field update | classifier が Loosening と判定し、agent 外承認なしには pending のまま |
| mixed tightening + loosening delta | 全体として Loosening と判定 |
| approval replay | 別 record / 別 delta digest / 別 baseline / nonce 再利用 / 期限切れ token は拒否 |
| compaction state preservation | compaction 前後の resolved state が一致し、head manifest が前進している場合のみ成功 |
| stale baseline loosening | 古い baseline digest 下の Loosening は current baseline 下で `RequiresReevaluation` |
| verified policy cache invalidation | delta append / manifest update / baseline update / TTL 経過で cache が無効化される |

これにより、field 改ざん、正規 API 経由の policy loosening、delta log rollback / truncation の三方向をすべて fail-closed にできる。


## 21. v15 追加テスト / Doctor 項目

| Test | 期待 |
|---|---|
| contact record authenticated | ContactRecord の email / access profile 改ざんは HMAC / policy head manifest mismatch で拒否される。 |
| group policy conservative | group address 宛て release は group / member / unknown member risk の conservative minimum で評価される。 |
| domain policy affects PL but cannot override deny | domain trust が高くても `NoEmail` / `StudentPrivate` / explicit DenyTags は覆せない。 |
| address category influences summary | `SpamLikely` / `DirectMarketing` は local summary skip または低 priority として扱われる。 |
| search select addressbook | FromContact / ToGroup / Domain / Category select が raw email 復号なしで動作する。 |
| prompt router mail UI safe | Reply / ReplyAll / ReplyTr 相当の UI action は direct send せず draft + release audit に入る。 |



## 22. v16 追加テスト / Doctor 項目

| Test | 期待 |
|---|---|
| imap participant auto-register | IMAP 取り込み時に未知 sender / recipient が ContactRecord または ContactCandidate として作成され、SourceVaultMailSnapshot に AddressBookRefs が付く。 |
| auto contact fail-closed access | 自動作成 contact は `TrustStatus -> Observed/Unverified`、`MaxPlaintextPL -> 0.0` であり、release permission を自動的に広げない。 |
| source identity observation provenance | GitHub / arXiv / blog / PDF ingest で IdentityObservationRecord が source record、evidence class、confidence と共に保存される。 |
| high-confidence add alias | verified email / ORCID / GitHub API 等の高信頼 evidence の場合だけ、既存 contact に alias / handle を自動追加できる。 |
| uncertain identity tagged | confidence 不足・複数候補・名前だけ一致の場合は `IdentityUncertain` / `NeedsReview` の ContactCandidate に留まる。 |
| author source linkage | SourceRecord の `Attribution.AuthorRefs` と ContactRecord の `EvidenceRefs` が相互に辿れる。 |
| identity graph select | AuthorContact / GitHubHandle / ORCID / Affiliation / SourceType による横断検索ができる。 |
| candidate not materialized as verified | prompt materialization で Candidate / Ambiguous identity を verified author と断定しない。 |
| identity merge rollback | ContactCandidate promotion / merge の delta truncation は policy head manifest mismatch で fail-closed。 |
| social extension placeholder | X / Discord 由来 observation は platform id / handle / server/channel context を保存し、verified contact とは分離される。 |



## 23. v17 追加: AddressBook / Identity Graph の送信者認証・PII 保護・自動登録制御

### 23.1 送信者 identity は、PL を下げる根拠にする前に認証する

メールの `From` / display name / reply-to は、認証なしには security boundary ではない。AddressBook や DomainPolicy は PL 推定・summary・triage に有用だが、**sender identity / category を使って PL を下げる、平文ヘッダ化する、DenyTag を外す、cloud summary を許す、といった loosening には送信者認証が必要**である。

MailSnapshot には次の authenticated decision state を追加する。

```wl
"SenderAuthentication" -> <|
  "Source" -> "Authentication-Results" | "LocalVerification" | "Missing",
  "DKIM" -> "Pass" | "Fail" | "Neutral" | "None" | "Unknown",
  "SPF" -> "Pass" | "Fail" | "Neutral" | "None" | "Unknown",
  "DMARC" -> "Pass" | "Fail" | "None" | "Unknown",
  "ARC" -> "Pass" | "Fail" | "None" | "Unknown",
  "AlignedFromDomain" -> domain | Missing["NotVerified"],
  "AuthenticatedIdentity" -> contactId | domain | Missing["Unverified"],
  "AuthenticationConfidence" -> 0.0 .. 1.0,
  "ParsedAt" -> utcIsoDateTime
|>
```

`SenderAuthentication` は `MailMetadataPublic.DecisionState` / authenticated record AAD に含める。IMAP import ではまず `Authentication-Results` ヘッダを解析する。可能であれば DKIM / SPF / DMARC / ARC の再検証も行うが、少なくとも provider が付与した `Authentication-Results` の provenance を記録する。

評価規則は非対称にする。

```text
sender / domain / category を使って PL を上げる、DenyTag を足す、summary を抑制する:
  認証なしでも可。spoof されても過剰防御に倒れる。

sender / domain / category を使って PL を下げる、PlainHeaderAllowed にする、cloud summary を許す、DenyTag を外す:
  DKIM/SPF/DMARC/ARC のうち policy が要求する条件が pass し、From domain alignment が確認できる場合のみ可。
  fail / none / unknown / missing の場合は loosening に使わない。
```

`SourceVaultAddressBookEvaluateAccess` と `SourceVaultInferMailDerivedBatch` は、sender 由来 feature を次のように扱う。

```wl
SourceVaultSenderFeatureUseQ[mail_, "Loosening"] :=
  SourceVaultSenderAuthenticatedQ[mail["SenderAuthentication"], requiredPolicy]

SourceVaultSenderFeatureUseQ[mail_, "Tightening"] := True
```

この規則により、spoofed `From: trusted-newsletter@example.org` によって PL が下がることを防ぐ。Doctor / PARITY には「spoofed From category does not downgrade PL」「auth fail domain policy can tighten but not loosen」を追加する。

### 23.2 AddressBook token 鍵

AddressBook の email equality token、handle token、cross-source identity token には専用の rotation-stable HMAC 鍵を使う。

```text
$SourceVaultDefaultAddressBookMACKeyRef = "SourceVault:addressbook:mac:v1"
```

この KeyRef を次に追加する。

```text
KeyRef BNF role: addressbook:mac
SourceVaultInitializeEncryption[] bootstrap target
SourceVaultKeyStatus[] / SourceVaultDoctor[]
hardcoded-secret grep allowlist: SystemCredential / NBAccess key reference only
rotation policy: normally not rotated; rotation requires token recomputation + dedup rebuild
```

`SourceVault:addressbook:mac:v1` は email / handle という低エントロピー値の equality token に使われるため、record / JSONL / synced store に鍵材料を絶対に出さない。漏洩時には辞書照合が可能になるため、Doctor は鍵材料らしき文字列が SourceVault store に現れていないか検査する。

### 23.3 Identity graph の PII 保護

Identity graph は、氏名・所属・email・GitHub handle・ORCID・blog author・PDF author・source linkage を集約するため、個々の source より高い機微性を持ち得る。ContactRecord / IdentityObservationRecord には field-level policy を持たせる。

```wl
"AddressBookFieldPolicy" -> <|
  "DisplayName" -> "PlainIfPLAtMostThreshold" | "Encrypted",
  "Names" -> "Encrypted" | "PlainIfPLAtMostThreshold",
  "Affiliations" -> "EncryptedOrTokenized",
  "Emails" -> "TokenizedIndexAndEncryptedValue",
  "Handles" -> "TokenizedIndexAndEncryptedValue",
  "CrossSourceLinks" -> "Encrypted",
  "EvidenceRefs" -> "EncryptedOrOpaqueRef",
  "Notes" -> "EncryptedOnly"
|>,
"GraphAggregatePL" -> estimatedAggregatePL,
"StorageProfileId" -> storageProfileId,
"PIIHandling" -> <|
  "DataMinimization" -> True,
  "ConsentRequiredForExport" -> True | False,
  "StudentOrThirdPartySensitive" -> True | False
|>
```

平文表示・検索は StorageProfile と `GraphAggregatePL` に従う。Dropbox / OneDrive / iCloud 等の同期 store では、email・private handle・student relation・cross-source linkage は既定で tokenized/encrypted とする。検索性が必要な field は keyed token を使い、raw PII を index に置かない。

SourceVault から cloud LLM へ identity graph を materialize する場合は、個別 record の PL だけでなく `GraphAggregatePL` を評価する。たとえば「ある学生が複数 source でどのように現れたか」という cross-source link は、source 単体より高 PL として扱う。

### 23.4 merge / promote は可逆・監査付きにする

identity resolution は security boundary ではない。ContactCandidate を ContactRecord に merge / promote する操作は、access policy を広げない場合でも誤 attribution のリスクを持つ。そのため次を規定する。

```text
1. merge / promote は authenticated policy delta log に記録する。
2. merge は reversible であり、SourceVaultUnmergeContactCandidates[] で履歴を辿って戻せる。
3. VerifiedOutOfBand でない merge をまたいで、高 PL material を cross-attribution しない。
4. Ambiguous / Candidate identity は prompt output / draft / release audit で断定的に表示しない。
5. merge によって MaxPlaintextPL / AccessTags / public key trust が広がる場合は Loosening として agent 外承認が必要。
```

たとえば arXiv author `K. Imai` とメール sender `k.imai@...` が候補一致しても、evidence が弱い場合は `Candidate` のまま保持する。検索では候補として表示できるが、返信文に「同一人物」として高 PL 情報を混ぜ込まない。

### 23.5 自動登録は person-like participant に限定する

IMAP import 時に unknown participant を見つけた場合、すべてを ContactRecord にするのではなく、分類して扱う。

```text
PersonLike:
  ContactCandidate または Observed ContactRecord を作成してよい。

Newsletter / NoReply / AutomatedNotification / DirectMarketing / MailingList / SpamLikely:
  既定では IdentityObservationRecord のみ。ContactRecord は作らない。

GroupAddress:
  ContactGroupRecord candidate として扱い、member 展開が確認されるまで conservative profile。
```

自動登録は増分バッチに載せる。

```wl
SourceVaultAutoRegisterIdentityBatch[opts___] := <|
  "OnlyUnprocessed" -> True,
  "ObservationOnlyCategories" -> {"Newsletter", "NoReply", "AutomatedNotification", "DirectMarketing", "MailingList", "SpamLikely"},
  "MaxCandidatesPerSource" -> 50,
  "CandidateTTL" -> Quantity[180, "Days"],
  "CheckpointEvery" -> 100
|>
```

candidate / observation には TTL / compaction / per-source cap を持たせ、policy head manifest の肥大を抑える。大量 ML の宛先は per-message contact 化せず、group / domain / category observation としてまとめる。

### 23.6 policy reevaluation は lazy / incremental にする

DomainPolicy / GroupPolicy / CategoryPolicy / AddressBook merge が変わると、関連 MailSnapshot / SourceRecord に `RequiresPolicyReevaluation` を立てる。ただし、広い domain policy の変更で全メールを即再計算すると実用性を損なうため、次の方針とする。

```text
- 変更時には affected selector と baseline digest を記録し、対象 record を lazy-invalidated 状態にする。
- 検索・閲覧・返信・release planning・cloud materialization の直前に、触れた record から再評価する。
- background job は priority queue で新しいメール・高リスクメール・送信候補を優先する。
- 再評価前の record は、release では fail-closed または旧 policy の tightening 側を採用する。
```

`SourceVaultReevaluateAddressPolicyQueue[]` と `SourceVaultAddressPolicyReevaluationStatus[]` を追加し、Doctor は stale reevaluation backlog を警告する。

### 23.7 EstimatedAccessPL の位置づけ

`EstimatedAccessPL` は UI 表示・候補 ranking・PL 推定 feature のための advisory 値であり、release gate の権威値ではない。release / materialization は次だけを見る。

```text
MaxPlaintextPL
MaxEncryptedReadablePL
AccessTags / DenyTags
PurposeAllowed
TrustStatus / PublicKeyStatus
SenderAuthentication
Confidence floor
Loosening approval state
```

`EstimatedAccessPL` が高いだけでは、平文送信・capsule 共有・cloud materialization を許さない。`MaxPlaintextPL` / `MaxEncryptedReadablePL` を引き上げる変更は policy loosening として agent 外承認を要求する。

### 23.8 v17 追加 Doctor / PARITY テスト

| Test | 期待 |
|---|---|
| spoofed From no downgrade | `From` が trusted domain に見えても DKIM/SPF/DMARC が fail/unknown なら PL downgrade / PlainHeaderAllowed / cloud summary が起きない。 |
| unauthenticated sender can tighten | 認証なし sender category が `SpamLikely` / `NoReply` 等の場合、summary 抑制・PL 引上げなど tightening は適用できる。 |
| addressbook mac key exists | `SourceVault:addressbook:mac:v1` が bootstrap 済みで、record / JSONL / synced store に鍵材料が出ていない。 |
| addressbook pii protected | email / handle / affiliation / cross-source link は StorageProfile に応じて encrypted/tokenized され、raw PII が不要な index に出ない。 |
| graph aggregate PL | ContactRecord 単体では低 PL でも cross-source identity graph export は `GraphAggregatePL` で制限される。 |
| unverified merge no high PL attribution | Candidate merge が VerifiedOutOfBand でない場合、高 PL material を cross-attribution しない。 |
| observation-only categories | Newsletter / no-reply / automated sender は既定で ContactRecord 化されず observation-only になる。 |
| candidate TTL compaction | 古い candidate / observation が TTL / compaction policy で整理され、head manifest が肥大化し続けない。 |
| lazy reevaluation fail-safe | DomainPolicy 変更後、未再評価 record は release で fail-closed または tightening 側に倒れる。 |
| estimated access advisory | `EstimatedAccessPL` だけを高くしても release permission は広がらない。 |




## 24. v18 追加: 送信者認証の信頼境界と AddressBook 集約 PL の補強

### 24.1 Authentication-Results は authserv-id pinning で信頼境界を確定する

`Authentication-Results` ヘッダは、送信者が任意に挿入できる通常のメールヘッダでもある。そのため、単にメール中の `Authentication-Results: dkim=pass` を見つけただけでは送信者認証の根拠にしてはならない。

各 IMAP account / mail transport profile には、受信側が信頼する authserv-id を baseline 管理の設定として登録する。

```wl
"TrustedAuthservIds" -> {
  "mx.google.com",
  "fukuyama-u.ac.jp",
  "mail.fukuyama-u.ac.jp"
},
"AuthenticationResultsPolicy" -> <|
  "TrustOnlyPinnedAuthservId" -> True,
  "IgnoreUntrustedAuthenticationResults" -> True,
  "PreferLocalDKIMVerification" -> True,
  "UntrustedARAllowsLoosening" -> False
|>
```

この設定は `IMAPAccountProfile` / `MailTransportProfile` / Trusted Baseline Registry に含め、改ざんされていないことを baseline signature / MAC / pinned digest で検証する。

`SourceVaultParseAuthenticationResults` は複数の A-R ヘッダを次のように分類する。

```wl
"AuthenticationResultsEvidence" -> {
  <|
    "HeaderIndex" -> i,
    "AuthservId" -> authservId,
    "Trust" -> "TrustedPinnedAuthservId" | "UntrustedAuthservId" | "Malformed" | "SelfAsserted",
    "DKIM" -> ...,
    "SPF" -> ...,
    "DMARC" -> ...,
    "ARC" -> ...,
    "RawHeaderRef" -> encryptedOrOpaqueRef
  |>
}
```

送信者由来 feature を **loosening** に使えるのは、`Trust -> "TrustedPinnedAuthservId"` の A-R、または fetch 時に local verification で得られた結果に限る。`UntrustedAuthservId` / `SelfAsserted` / `Malformed` / `Missing` は loosening には使わず、`Missing` と同等に扱う。

可能な場合、DKIM は raw MIME と DNS 公開鍵でローカル再検証する。SPF / DMARC は受信時の接続 IP や envelope 情報が必要であり、後日 snapshot からは再検証できないことが多いため、信頼 authserv-id が付与した A-R に依存する。

Doctor / PARITY には次を追加する。

```text
forged inline Authentication-Results ignored:
  攻撃者が本文ヘッダとして dkim=pass を挿入しても、authserv-id が pinned list に無ければ PL downgrade / PlainHeaderAllowed / cloud summary は起きない。
```

### 24.2 SenderAuthentication は IMAP fetch 時の attested fact として保存する

DKIM は特定の raw header set と body hash に対する署名である。既存 `maildb.wl` は本文を 50KB に切り詰め、HTML を PDF 化し、Raw MIME を保持しないため、既存 `.wl` DB から移行した snapshot だけでは DKIM を再検証できない。

したがって、`SenderAuthentication` は IMAP fetch 時に生メッセージ / raw MIME / provider 付与 A-R から確定し、attested metadata として保存する。

```wl
"SenderAuthentication" -> <|
  "Source" -> "LocalDKIMVerification" | "TrustedAuthenticationResults" | "TrustedARC" | "Missing" | "UnavailableFromLegacyMaildb",
  "CapturedAtFetch" -> True | False,
  "RawMIMEAvailableForVerification" -> True | False,
  "TrustedAuthservId" -> authservId | Missing["NotApplicable"],
  "DKIM" -> "Pass" | "Fail" | "None" | "Unknown",
  "SPF" -> "Pass" | "Fail" | "None" | "Unknown",
  "DMARC" -> "Pass" | "Fail" | "None" | "Unknown",
  "ARC" -> "Pass" | "Fail" | "None" | "Unknown",
  "AlignedFromDomain" -> domain | Missing["NotVerified"],
  "AuthenticatedIdentity" -> contactId | domain | Missing["Unverified"],
  "AuthenticationConfidence" -> 0.0 .. 1.0,
  "EvidenceRefs" -> {...}
|>
```

既存 `maildb.wl` 由来の migration record は、原則として

```wl
"Source" -> "UnavailableFromLegacyMaildb"
```

または `"Missing"` とし、sender-based loosening を禁止する。From / domain / category は tightening、triage、observation には使えるが、PL を下げたり平文ヘッダ化したり cloud summary を許す根拠にはしない。

### 24.3 sender-based loosening の required policy

`SourceVaultSenderAuthenticatedQ[auth, requiredPolicy]` の既定 policy を明示する。

```wl
$SourceVaultDefaultSenderLooseningAuthPolicy = <|
  "Accept" -> {
    <|"DMARC" -> "Pass"|>,
    <|"DKIM" -> "Pass", "FromAlignment" -> "Aligned"|>,
    <|"ARC" -> "Pass", "TrustedARCSealer" -> True, "OriginalAuthentication" -> "Pass"|>
  },
  "Reject" -> {
    "SPFOnlyPass",
    "UnalignedDKIMPass",
    "UntrustedAuthenticationResults",
    "MissingAuthentication",
    "LegacyMaildbUnavailable"
  }
|>
```

`SPF=Pass` 単独は、envelope-from と header `From` が異なることが多いため、PL downgrade / PlainHeaderAllowed / cloud summary の根拠にしない。SPF は DMARC pass の一部として alignment が確認できる場合にだけ loosening へ寄与する。

From alignment は relaxed / strict を policy で選べるが、既定は DMARC relaxed alignment とし、baseline で明示する。

### 24.4 メーリングリスト・転送・ARC の扱い

正規のメーリングリストや転送では DKIM / SPF が壊れることがある。そのため、すべてを `Missing` と同等に扱うと安全だが、通常メールの件名検索性が大きく落ちる。

v18 では、ARC を条件付きで採用する。

```wl
"TrustedARCSealers" -> {
  <|"Domain" -> "groups.google.com", "TrustStatus" -> "VerifiedOutOfBand"|>,
  <|"Domain" -> "mailman.fukuyama-u.ac.jp", "TrustStatus" -> "VerifiedOutOfBand"|>
},
"ARCPolicy" -> <|
  "AllowLooseningIfTrustedARCChainPasses" -> True,
  "RequireSealerPinnedInBaseline" -> True,
  "UntrustedARCAllowsLoosening" -> False
|>
```

ARC chain が pass し、かつ ARC sealer が baseline で pin された trusted forwarder / list provider である場合に限り、元の sender authentication を loosening 根拠として使える。それ以外の ML / forward は fail-safe に倒し、sender category による tightening だけを許す。

この UX trade-off を明記する。

```text
認証が壊れた mailing list / forward は、正規メールであっても、trusted ARC sealer が無い限り sender-based loosening できない。
その場合、件名平文化・cloud summary の回復は user review / explicit declassify / manual AddressBook policy によって行う。
```

### 24.5 GraphAggregatePL の生成・単調性・承認

`GraphAggregatePL` は identity graph の集約機微性を表す。個別の email / GitHub handle / arXiv author name が低 PL でも、それらが同一人物として横断リンクされること自体が高い機微性を持ち得る。

生成経路を次のように定義する。

```wl
SourceVaultComputeGraphAggregatePL[contactOrCandidate_] := Module[..., pl]
```

入力は次を含む。

```text
PII フィールドの最大 PL
cross-source link の数と種類
student / third-party / private relation tag
unverified merge の有無
sensitive source との linkage
GraphPolicy baseline
```

原則として、cross-source link や evidence が増える更新で `GraphAggregatePL` は**非減少**とする。`GraphAggregatePL` を下げる変更は policy loosening として扱い、agent の action space 外の人間承認を必須にする。

未生成の場合は次の provisional state にする。

```wl
"GraphAggregatePL" -> Missing["NotGenerated"],
"GraphAggregatePolicy" -> "ProvisionalHighPL",
"GraphMaterializationAllowed" -> False
```

この状態では、identity graph の cloud materialization / export / low-storage plaintext は fail-closed とする。

### 24.6 AddressBook field policy の provisional / re-seal 遷移

AddressBook field policy も mail header と同じ遷移を持つ。

```text
1. import / observation 直後:
   PL / GraphAggregatePL 未確定なので PII field は provisional encrypted/tokenized。

2. identity batch / GraphAggregatePL 計算後:
   StorageProfile.MaxPlaintextPL と field policy threshold を照合。

3. re-seal:
   threshold 以下で、confidence が十分で、deny tag が無い field だけ plain / tokenized index に降格できる。
   threshold 超・low confidence・sensitive relation は encrypted 維持。

4. 保存先降格:
   Dropbox から agent-readable workspace 等へ移る場合は、Doctor が再封印を要求する。
```

`SourceVaultReclassifyAddressBookFields[]` を追加し、re-seal は authenticated policy delta log / policy head manifest を通る。merge / unmerge は過去 log を書き換えず、forward delta として記録する。

### 24.7 v18 追加 Doctor / PARITY テスト

| Test | 期待 |
|---|---|
| forged Authentication-Results ignored | 攻撃者が偽 `Authentication-Results: dkim=pass` を挿入しても、authserv-id が pinned list に無ければ loosening に使われない。 |
| trusted authserv-id accepted | baseline に登録された authserv-id の A-R のみ、sender-based loosening の候補になる。 |
| local DKIM verification preferred | raw MIME がある場合は A-R より local DKIM verification を優先できる。 |
| legacy maildb auth missing | 既存 maildb `.wl` 由来 snapshot は `SenderAuthentication -> Missing/UnavailableFromLegacyMaildb` となり、sender-based loosening できない。 |
| SPF-only no loosening | SPF pass 単独では PL downgrade / PlainHeaderAllowed が起きない。 |
| DMARC or aligned DKIM permits loosening | DMARC pass または From-aligned DKIM pass の場合のみ sender category による loosening が可能。 |
| trusted ARC sealer permits forwarded loosening | pinned trusted ARC sealer の ARC pass では、forward/list 経由でも loosening が可能。 |
| untrusted ARC no loosening | 未登録 ARC sealer や ARC fail は loosening に使われない。 |
| GraphAggregatePL monotonic | cross-source link 追加で GraphAggregatePL は下がらない。下げる変更は loosening 承認が必要。 |
| graph provisional high PL | GraphAggregatePL 未生成の contact graph は export / cloud materialization 不可。 |
| addressbook provisional reseal | PII field は初期 encrypted/tokenized、PL 確定後に閾値以下のみ plain/tokenized index へ re-seal 可能。 |
| unmerge forward delta | merge/unmerge は過去 log を書き換えず forward delta として記録され、head manifest が前進する。 |
