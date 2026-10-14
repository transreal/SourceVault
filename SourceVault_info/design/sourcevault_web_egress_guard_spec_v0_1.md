# SourceVault Web Egress Guard 仕様 v0.1

作成: 2026-10-14
対象ファイル: `SourceVault_webguard.wl` (新設), `SourceVault_webingest.wl`, `SourceVault_mcp.wl`,
`SourceVault_diagnostics.wl`, `SourceVault_servicemanager.wl`, `SourceVault.wl`, `claudecode.wl`
関連仕様: sourcevault_searxng_mcp_spec_v6.md (§9 provenance / §11 reference events),
sourcevault_self_organizing_mining_identity_tag_spec_v0_1.md (identity 2 層),
memory `llm-egress-route6-web-future-task` (経路 6 の課題記録)

---

## 1. 目的と背景

SourceVault はローカル LLM (LM Studio / llama.cpp) からの直接 Web アクセスを禁止し、
`sourcevault_web_search` / `sourcevault_get_document` (SearXNG 中継・URL 取得) を
MCP プラグインまたはクライアント側ツールループ経由でのみ許している。

しかしこの構成でも **出力面** の情報流出は防げない。LLM が URL 文字列やクエリ文字列に
データを埋め込めば (例: `https://x.example/a/<base64(成績表)>`)、GET/POST の区別や
URL の検証だけでは止まらない。一方、ハッシュ状文字列を一律に禁止すると YouTube の
動画ページ (`watch?v=dQw4w9WgXcQ`) すら開けなくなる。

本仕様は次を定める。

1. **関所 (guard)**: SearXNG へ中継する前・URL を取得する前に、URL/クエリの不審度と
   「LLM に渡っているデータのプライバシーレベル (文脈 PL)」を照合し、明らかにおかしい
   アクセスはオーナーに **許可/不許可を問い合わせる**。問い合わせは必要最小限にする。
2. **URL の identity 管理**: 外部アクセス先ホストを `SourceVault_identity` と同じ
   識別子体系 (IdentifierId 決定的・PrivateVault/identity 配下) で管理し、メールアドレスの
   ContactAccessProfile と同様に **AccessLevel を割り当て、使用実績から推定して更新**する。
3. **id 紐づけログ**: 誰 (どのモデル / オーナー) が、どのホストを、どの文脈 PL で、
   何回呼び出したかを追える append-only ログを残す。
4. **可視化 View**: 期間・主体・ホスト・判定で絞り込める core/View 関数対。
5. **定期サーベイの強制**: SystemDoctor が月に一度サマリーログの参照を促し、
   レビュー記録が無い限り警告を続ける (ログは見返されなければ価値が薄い)。

## 2. 脅威モデル (対象/非対象)

| | 内容 | 本仕様 |
|---|---|---|
| T1 | LLM が URL パス/クエリにデータを符号化して外部へ GET | **対象** (不審度 + 文脈 PL) |
| T2 | LLM が検索クエリ文字列に秘匿データ (氏名・学籠番号・メール等) を載せる | **対象** (クエリ不審度 + PII ヒント) |
| T3 | DNS 経由 (長い高エントロピーなサブドメインラベル) | **対象** |
| T4 | 未知ホスト・IP 直打ち・userinfo 付き・非標準ポート | **対象** (加点) |
| T5 | POST / フォーム送信 | SourceVault の web 経路は GET のみ。POST は存在しない (変更しない) |
| T6 | LLM 提案コードが WL の `URLRead` を直接呼ぶ (mathematica_eval 経路) | **非対象** (コード承認ゲートの責務) |
| T7 | 承認後の正規ホストへ平文で少量ずつ漏らす (low-and-slow) | **部分対象** (ログ集計と月次レビューで事後検知) |

静的検査だけで漏洩を証明することはできない。本仕様は「明らかにおかしい形を止め、
疑わしいものはオーナーに見せ、すべてを記録して定期的に見返す」ことを狙う。

## 3. 用語

- **文脈 PL (ContextPL)**: 当該 LLM 呼び出しに渡っているデータの PrivacyLevel の最大値。
  claudecode が送信直前に申告する (`SourceVaultWebGuardDeclareContext`)。
- **主体 (Actor)**: アクセスを起こした者。`Owner` (オーナーのノートブック操作) /
  `Model` (provider/model が分かる LLM) / `MCPClient` (クライアント名しか分からない LLM)。
- **ホスト profile**: ホスト (ドメイン) ごとの AccessLevel / TrustStatus / 実績。
- **AccessLevel (ホスト)**: 「この文脈 PL 以下ならオーナーに聞かずにアクセスしてよい」上限。
  メールの `MaxPlaintextPL` に対応する。
- **不審度 (Suspicion)**: URL またはクエリの形から決定的に計算する 0..1 のスコアと
  Class (`Plain` / `Opaque` / `Exfil`)。

## 4. アーキテクチャ

```
LM Studio ──MCP──▶ service kernel ─┐
llama.cpp ◀─toolloop─ main kernel ─┤  SourceVaultMCPCallTool
notebook (owner) ──────────────────┤
                                   ▼
                webingest: SourceVaultWebSearch / SourceVaultWebFetch
                                   │  (SearXNG へ投げる前 / URL を取る前)
                                   ▼
                SourceVault_webguard: SourceVaultWebGuardCheck[request]
                   ├ 文脈 PL 解決 (申告 + 評価スコープ透かし)
                   ├ URL/クエリ不審度
                   ├ ホスト profile (PrivateVault/identity/webhosts.jsonl)
                   ├ 判定表 → Allow / Ask / Deny
                   ├ Ask → prompter (FE ダイアログ | 承認 queue)
                   └ ログ (LocalState/hotlog/web_access) + 実績更新
```

- 関所は **webingest の 2 関数** に置く。MCP (service kernel)・ツールループ (main kernel)・
  web job (サブカーネル) のすべてがここを通る。
- `SourceVault_webguard.wl` は **service-loadable** (core のみ依存。FE/NBAccess/identity/
  privacy/diagnostics/claudecode はすべて弱結合)。service manifest・サブカーネル init・
  main kernel の 3 か所で webingest の直後にロードする。
- **fail-closed**: guard モジュールが未ロードで主体が LLM (MCPClient/Model) の場合は
  Deny (`GuardUnavailable`)。主体が Owner なら素通し (`$SourceVaultWebGuardRequired` で変更可)。

## 5. 文脈 PL の解決

1. request に `ContextPL` が数値で明示されていればそれ。
2. 主体が Owner なら文脈 PL は判定に使わない (常に Allow、ログのみ)。
3. 申告 (`SourceVaultWebGuardDeclareContext`) のうち TTL (`$SourceVaultWebGuardContextTTLSeconds`,
   既定 900 秒) 内のものの PL の **最大値**。申告はメモリと
   `LocalState/webguard/context/<provider>.json` の両方に置く (service kernel は file を読む。
   MCP service と FE は同一マシン前提: spec mcp D1 と同じ)。
4. main kernel では `SourceVaultEvaluationPrivacy[]` (privacy 層の評価スコープ透かし) も Max に入れる。
5. 何も分からなければ `$SourceVaultWebGuardUnknownContextPL` (既定 **0.5**)。
   パスワード・成績は必ず 0.5 以上という運用に合わせ、未知は「私的データあり」側に倒す。
   LM Studio を claudecode 経由でなく直接使う場合もこれになる (新規ホストは一度だけ聞かれる)。

claudecode の申告点 (3 か所、いずれも弱結合 1 行):
`iQueryViaAPI` のローカル provider 分岐 (同期)、`iToolLoopStart` (非同期ツールループ)、
`iPrepareLMStudioMCPPS1` (LM Studio MCP 非同期)。申告 PL = Max[セル PL
`$iClaudeEvalPromptPrivacyLevel`, 要求 PL `$iClaudeRequestPrivacyLevel` (ClaudeQuerySync/Async の
PrivacyLevel オプション), 評価スコープ透かし]。
TTL 内の最大値を採るので、直前に高 PL の呼び出しがあれば以後 15 分は高めに判定される
(安全側の近似。誤って低く見ることはない)。

## 6. URL / クエリの不審度 (決定的・LLM 不使用)

### 6.1 URL (`SourceVaultWebGuardAnalyzeURL[url]`)

加点要素 (合計を 1 で clip):

| 要素 | 加点 | 理由 |
|---|---|---|
| scheme が http/https 以外 | 1.0 | 中継対象外 |
| userinfo (`user:pass@`) | 0.5 | 認証情報持ち出し/偽装 |
| IP リテラルホスト | 0.3 | 名前解決を避けた直接送信 |
| 非標準ポート | 0.2 | |
| punycode (`xn--`) | 0.2 | 同形異義 |
| 長い高エントロピーのサブドメインラベル (≥16 字) | 0.5 | DNS 経路の符号化 (T3) |
| ラベル数 > 5 | 0.2 | |
| opaque トークン 1 個 | 0.4 (Opaque) | |
| opaque 総文字数 ≥ 128 | +0.4 (→ Exfil) | 符号化データの量 |
| URL 長 > 1500 | 0.4 | |
| クエリ引数 > 10 | 0.2 | |
| パーセントエンコードの塊 (≥40 字でエスケープ率 ≥20%) | 0.3 | |

**opaque トークン** = パス区切り/クエリ値/フラグメントから `[A-Za-z0-9+/=_-]{16,}` を取り、
次のいずれか: hex のみで 32 字以上 / 20 字以上でシャノンエントロピー ≥ 3.5 bit かつ英数混在 /
40 字以上。UUID (8-4-4-4-12) は opaque とみなさず 0.15 のみ加点 (API に頻出)。
YouTube の 11 字 id は閾値未満で Plain。Google Docs の 44 字 id は Opaque (未知ホストなら Ask、
既知ホストなら文脈 PL が低ければ Allow)。

Class: score ≥ 0.8 → `Exfil`、≥ 0.4 → `Opaque`、それ以外 `Plain`。
Reasons には一致箇所の抜粋 (先頭 12 字 + 長さ) を残し、ダイアログで赤く示す。

### 6.2 クエリ (`SourceVaultWebGuardAnalyzeQuery[query]`)

opaque トークン (6.1 と同じ判定) 1 個 0.5、長さ > 300 字 0.3、改行 3 行以上 0.2。
別枠で **PIIHints**: メールアドレス / 8 桁以上の連続数字 (学籍番号・電話) / `password`・
`パスワード`・`token` の語。PII は score には足さず、文脈 PL ≥ PrivatePL のとき Ask の根拠になる。

## 7. ホスト identity と AccessLevel

### 7.1 レコード (`PrivateVault/identity/webhosts.jsonl`, Dropbox 同期)

```
<|Type -> "SourceVaultWebHostProfile", SchemaVersion -> 1,
  Host -> "docs.python.org", IdentifierId -> "idf-webhost-<sha256 16hex>",
  AccessLevel -> 0.5, TrustStatus -> "Observed"|"Approved"|"Blocked"|"Verified",
  PolicySource -> "Default"|"Builtin"|"Estimated"|"Owner", Confidence -> 0..1,
  FirstSeen, LastSeen, UpdatedAt,
  StatsByMachine -> <|machineTag -> <|AccessCount, Days -> {..}, Suspicious, Denied, Approved,
                                    ByActor -> <|actorId -> count|>|>|>,
  Note|>
```

- `IdentifierId` は identity 層の `iSVIDId["WebHost", host]` と同じ式 (`idf-webhost-` +
  SHA256("WebHost:" <> host) 先頭 16 hex) で、identity が未ロードの service kernel でも同じ id になる。
  identity がロードされていれば `SourceVaultObserveIdentifier["WebHost", host]` も呼び、
  識別子レジストリに登録する (実体 = 組織へのリンクは identity の既存 API で可能)。
- **主体 (モデル) も識別子**: `idf-model-<hash>` (値 = `provider/model` 小文字)。
  オーナーは `ent-1`。MCP クライアント名しか無いときは `idf-mcpclient-<hash>`。

### 7.2 実績 (machine-local hot) と Dropbox 書き込み量

アクセスごとの計数は `LocalState/webguard/hoststats.json` (機械ローカル) に書く。
PrivateVault の profile は **オーナー決定 (Approved/Blocked) と推定の再計算時のみ** 書き換える
(Dropbox 同期の churn 回避)。再計算 (`SourceVaultWebHostRecomputeProfiles`) が
`StatsByMachine[<自機>]` を上書きするので複数 PC の実績が合算される。

### 7.3 AccessLevel の初期値と推定

| 状態 | AccessLevel | PolicySource |
|---|---|---|
| 未見ホスト | `Policy["DefaultHostLevel"]` = **0.2** | Default |
| 組み込み公知ホスト (`$SourceVaultWebGuardBuiltinHosts`: wikipedia / arxiv / 公式 docs / github / youtube 等、サフィックス一致) | 0.5 | Builtin |
| 実績十分 (累計 ≥ 20 回・3 日以上・不審 0・拒否 0) | 0.5 | Estimated |
| オーナーが「このホストを許可」 | Max[文脈 PL, 0.5] (上限 1.0) | Owner (TrustStatus Approved) |
| オーナーが「遮断」 | 0.0 + TrustStatus Blocked | Owner |

推定は `SourceVaultWebHostEstimateAccess[host]` (純関数) で与え、判定時にも
`Max[profile.AccessLevel, 推定]` をその場で使う (再計算待ちにしない)。
Owner 設定は推定で下げない/上げない (メールの「loosening は認証必須」と同じ非対称: 自動は
0.5 までしか上げない)。

## 8. 判定表 (`SourceVaultWebGuardDecide`, 純関数)

`Policy = $SourceVaultWebGuardPolicy` 既定: LowRiskPL 0.2 / PrivatePL 0.5 / DefaultHostLevel 0.2 /
EstablishedCount 20 / EstablishedDays 3 / OpaqueScore 0.4 / ExfilScore 0.8。

### 8.1 Fetch (URL 取得)

```
TrustStatus == Blocked                       → Deny  (HostBlocked)
Class == Exfil                               → Ask   (ExfilShapedURL)      文脈 PL に関係なく
level = Max[AccessLevel, 推定]
ctxPL <= level:
    Class == Opaque && 未見ホスト            → Ask   (OpaqueOnNewHost)     「初見のサイトに長いハッシュ」
    それ以外                                 → Allow
ctxPL >  level:
    未見ホスト                               → Ask   (NewHostWithPrivateContext)
    Class == Opaque                          → Ask   (OpaqueWithPrivateContext)
    実績不十分 (established でない)          → Ask   (UnestablishedHostWithPrivateContext)
    実績十分かつ Plain                       → Allow (AboveLevelEstablished を Reasons に記録)
```

### 8.2 Search (SearXNG 中継クエリ)

```
Class == Exfil                               → Ask   (ExfilShapedQuery)
ctxPL <= LowRiskPL                           → Allow
Class == Opaque                              → Ask   (OpaqueQueryWithContext)
ctxPL >= PrivatePL && PIIHints != {}         → Ask   (PIIInQueryWithPrivateContext)
それ以外                                     → Allow
```

Owner 主体はどちらも Allow (ログのみ)。

## 9. 問い合わせ (Ask) の実行

### 9.1 prompter シーム

`$SourceVaultWebGuardPrompter`: `Automatic` (FE があれば ChoiceDialog、無ければ queue) /
`"Queue"` / `"Deny"` / 関数 `f[request] → "AllowOnce"|"AllowHost"|"Deny"|"BlockHost"`。
テストはモック関数を差す。

### 9.2 FE ダイアログ (main kernel)

表示: 主体 (モデル名)・文脈 PL・種別 (検索/取得)・ホスト (太字)・URL/クエリ (不審箇所を赤)・
理由・ホスト実績 (回数/初回/最終/現在のレベル)。
ボタン: 「今回だけ許可」「このホストを許可 (PL ≤ x)」「拒否」「このホストを遮断」
(検索は「今回だけ許可」「拒否」のみ)。閉じる = 拒否 (一回限り)。

**pending-first**: ダイアログを出す前に必ず pending request を書く。ツールループの
`TimeConstrained` (既定 60 秒) でダイアログが打ち切られても request は残り、
pending watch が再提示し、モデルの再呼び出しで ticket が消費される。

### 9.3 承認 queue (service kernel / サブカーネル)

- `LocalState/webguard/pending/<id>.json` に request (署名 = Hash[Kind, 対象, 主体]) を書き、
  モデルには `Decision -> "Pending"` と文面
  「Web access to <host> requires owner approval (request <id>). The owner has been asked;
  retry this exact call in a minute, or use a different source.」を返す。
  同じ署名の pending が TTL (10 分) 内にあれば二重に作らない。
- FE main kernel は `SourceVaultWebGuardProcessPending[]` を claudecode の共有 polling tick
  (`ClaudeRegisterPollingTick`, key `sourcevault-webguard-pending`, 10 秒) で回し、
  ダイアログで決定 → `LocalState/webguard/decisions/<id>.json` (ticket) と profile 更新。
  ロード時に FE なら自動登録 (opt-out `Global`$SourceVaultWebGuardDisableAutoWatch`)。
- 再呼び出し時 `SourceVaultWebGuardCheck` は署名一致の未消費 ticket (TTL 10 分) を先に探し、
  AllowOnce は消費して Allow、Deny は消費して Deny。AllowHost/BlockHost は profile に反映済み
  なので判定表で決まる。

## 10. ログ

`LocalState/hotlog/web_access/YYYY-MM.jsonl` に 1 行/アクセス (append-only, UTF-8 bytes):

```
At(UTC ISO), EventId, Kind(Search|Fetch), Url, Host, Query(先頭 500 字), HostIdentifierId,
ActorId, ActorKind(Owner|Model|MCPClient), Provider, Model, ClientName, Channel(MCP|Notebook|Job),
ContextPL, ContextSource(Declared|Evaluation|Explicit|Unknown|Owner),
Suspicion, Class, Reasons, PIIHints, HostAccessLevel, HostAccessCount(判定前),
Decision(Allow|Deny|Pending), DecisionBy(Policy|Owner|Ticket|Queue), DecisionDetail(AllowOnce|...),
RequestId, SessionId, Machine
```

Pending の後にオーナーが決めた内容は decisions ticket と、再呼び出し時の行 (DecisionBy Ticket) で追える。

## 11. core / View

- `SourceVaultWebAccessLog[opts]` → List[Association]。opts: "Days" (既定 30) / "Since" / "Until" /
  "Actor" (ActorId または表示名部分一致) / "Host" / "Kind" / "Decision" / "MinSuspicion" / "Limit"。
- `SourceVaultWebAccessLogView[opts]` → Pane[Dataset]。`$SourceVaultWebAccessViewMaxRows` (200) で描画制限。
  行の ContextPL 最大が 0.5 以上なら `SourceVaultPrivateView` (弱結合) で赤枠 + PL バッジ。
- `SourceVaultWebAccessSummary[opts]` → <|Period, Total, ByKind, ByDecision, ByActor, ByHost,
  NewHosts, Suspicious, Pending, ReviewStatus|>。
- `SourceVaultWebAccessSummaryView[opts]` → 見出し統計 + ホスト別/主体別 Dataset +
  「レビュー済みにする」ボタン (`SourceVaultWebAccessMarkReviewed[]`)。
- `SourceVaultWebHostProfiles[]` / `SourceVaultWebHostProfilesView[]`。
- `SourceVaultWebGuardPendingRequests[]` / `SourceVaultWebGuardResolveRequest[id, decision]`。

## 12. SystemDoctor 月次レビュー

- probe `"WebAccessReview"` (`SourceVaultWebAccessReviewProbe`) を diagnostics に弱結合登録。
  - `PrivateVault/identity/webaccess_review.json` の `LastReviewedAt` から `ReviewIntervalDays` (30) 超、
    かつその間に 1 件以上のアクセス → `Degraded` / `WebAccessReviewDue`。
    Message: 「LLM の Web アクセス記録のレビューが 1 か月以上ありません: 直近 N 日 n 件
    (検索 a / 取得 b、不審 s、拒否 d、新規ホスト h)。SourceVaultWebAccessSummaryView[] で確認し、
    SourceVaultWebAccessMarkReviewed[] で記録してください。」
  - 2 分以上放置された pending request があれば `Degraded` / `WebAccessApprovalPending`。
  - それ以外 `OK` / `WebAccessReviewOK` (次回期限を Detail に出す)。
- `$iSVDiagWatchedComponents` に `"WebAccessReview"` を加える → tick が 24 時間に 1 回
  FE 通知 + Escalate (issue)。レビューを記録するまで毎日 1 回促される。
- `SourceVaultWebAccessMarkReviewed[]` は時刻・件数・機械名を記録し、profile 再計算
  (`SourceVaultWebHostRecomputeProfiles`) と identity 保存も行う。

## 13. 設定変数 (既定)

| 変数 | 既定 | 意味 |
|---|---|---|
| `$SourceVaultWebGuardEnabled` | True | False で関所を素通し (ログは残す) |
| `$SourceVaultWebGuardRequired` | True | guard 未ロード時に LLM 主体を Deny |
| `$SourceVaultWebGuardPolicy` | §8 | 閾値表 |
| `$SourceVaultWebGuardUnknownContextPL` | 0.5 | 文脈不明時の PL |
| `$SourceVaultWebGuardContextTTLSeconds` | 900 | 申告の有効時間 |
| `$SourceVaultWebGuardPendingTTLSeconds` | 600 | pending / ticket の有効時間 |
| `$SourceVaultWebGuardPrompter` | Automatic | §9.1 |
| `$SourceVaultWebGuardBuiltinHosts` | 公知ホスト表 | サフィックス一致 → AccessLevel |
| `$SourceVaultWebAccessViewMaxRows` | 200 | View の描画行数 |
| `$SourceVaultWebHostRoot` | Automatic | profile 保存先の上書き (テスト) |

## 14. 既知の限界と今後

- 文脈 PL は申告ベース。TTL 内最大値を採るため、連続する低 PL 作業でも直前の高 PL 呼び出しの
  影に入る (安全側)。MCP の observed-read (mcp_calls hotlog) との Max 合成は将来。
- 不審度は形の検査。自然文に埋めた少量の漏洩 (T7) は止められない → ログと月次レビューが受け皿。
- 承認ダイアログはツールループの `TimeConstrained` 内で出るため 60 秒で打ち切られうる
  (pending-first で救済)。長く考えるなら `$ClaudeLocalToolLoopToolTimeoutSeconds` を延ばす。
- web job (fetchPages) 内の Ask はサブカーネルで queue になるので、その job の該当ページは
  本文なしで返る。モデルは承認後に `sourcevault_get_document` で取り直せる。
- ホスト単位の identity であり、同一ホスト内のパス単位の信頼は持たない。

## 15. テスト

`test codes/SourceVault_webguard_test.wls` (ASCII のみ、temp root、ネットワーク無し、
wolfram.exe -script で実行):
解析 (YouTube Plain / Google Docs Opaque / hex 塊 Exfil / DNS ラベル / IP / userinfo)、
判定表 (§8 の各枝)、文脈申告 TTL、pending → ticket 消費、ログ/集計/フィルタ、
ホスト推定、Approve/Block の profile 反映、レビュー状態と probe、
webingest 結線 (Search/Fetch の Deny/Pending/Allow)、MCP 文面。

## 16. 変更ファイル一覧

| ファイル | 変更 |
|---|---|
| `SourceVault_webguard.wl` | 新設 (本仕様の本体) |
| `SourceVault_webingest.wl` | Search/Fetch 入口に `iWebGuardGate`、サブカーネル init に webguard の Get |
| `SourceVault_mcp.wl` | Failure["WebAccessGuard"] / ExtractionStatus Denied・Pending の文面、submit 前の query 関所 |
| `SourceVault_diagnostics.wl` | `$iSVDiagWatchedComponents` に WebAccessReview |
| `SourceVault_servicemanager.wl` | manifest Packages と run.wls に webguard |
| `SourceVault.wl` | main kernel ロード一覧に webguard |
| `claudecode.wl` | `iWebGuardDeclareContext` + 3 申告点 + `$iClaudeRequestPrivacyLevel` |
| `SourceVault_info/privacy/privacy_reviewed.m` | 新規 public シンボルのレビュー登録 |
