# SourceVault ServiceManager 使用例 — gate 付き Web 検索/質問応答サービス

このドキュメントは `SourceVault_servicemanager.wl` が提供する **detached Web サービス**（release gate 付きの検索・質問応答・PDF ページ表示を HTTP で公開する）の初期設定と起動手順を、**学生便覧 web サービス**を題材に説明します。

設計方針は次の通りです。

- **SourceVault のコードはドメイン非依存（汎用）**。アプリ固有値（表題・assistant prompt・対象 index・gate 設定・LLM モデル）は**コードに焼かず、private local init の設定オブジェクト（endpoint profile）として記述**します。これが「アプリのワークフロー定義」になります。
- 検索の本体は `PDFIndex` の `pdfSearch`（hybrid: embedding + keyword）を **legacy adapter** 経由で gate 越しに呼びます。SourceVault は PDFIndex を差し替え可能な検索バックエンドとして扱います（依存は一方向・実行時・任意）。
- HTTP は headless WolframScript では `SocketListen` が使えないため、**stdlib Python の reverse proxy** がエッジを担い、WL service へ file ベースの command/response queue で中継します。**gate は必ず WL 側**で、生ファイルパスは外に出ません。

---

## 1. 前提

| 項目 | 内容 |
|---|---|
| WolframScript | `wolframscript`（FE なし headless で常駐サービスを動かす） |
| PDF index | 対象コレクションが `pdfIndex` 済みであること（本例は既定 collection `default` に学生便覧が登録済み） |
| LM Studio | OpenAI 互換サーバが起動し、**埋め込みモデル `text-embedding-baai-bge-m3-568m`**（8192トークン/1024次元・多言語。表末尾の年度ヘッダや長い表も切らず embedding 可）と、**chat モデル**（非 thinking の instruct 推奨）または **クラウド LLM**（`ChatModel->"cloud"`）が利用可能なこと |
| LLM トークン | LM Studio が Bearer 認証必須の場合、`NBAccess` の local LLM credential に登録（後述） |

> 注: 埋め込み・chat の endpoint/model/token は**ハードコードしません**。token は `NBAccess`\`NBGetLocalLLMAPIKey` から取得します。
>
> 埋め込みモデルを変更したら（次元/空間が変わるため）`PDFIndex\`pdfReembed["default"]` で全 chunk を再 embedding してください。`PDFIndex\`Private\`$embeddingModel`（既定 `text-embedding-baai-bge-m3-568m`）/ `$embeddingTextWindow`（既定 6000 字）で上書き可。512 トークン上限のモデルに戻す場合は窓も ~400 に下げること。

---

## 2. ロード

`SourceVault.wl` を読むだけで補助サブファイル（`SourceVault_core` / `_searchindex` / `_servicemanager` / `_mcp` / `_objectview`）も自動でロードされます。

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]];
```

アプリ（学生便覧）が使う検索バックエンドと UI 資産は**サービスの prelude**でロードします（後述）。メインカーネルでは endpoint profile を解決するために local init を読みます。

---

## 3. LM Studio トークンの登録（必要な場合のみ）

LM Studio が `401 Unauthorized` を返す場合、ローカル LLM 用 credential に token を登録します（クラウド用の `NBGetAPIKey` ではなく **local LLM 専用 API**を使う点に注意）。

```mathematica
NBAccess`NBStoreLocalLLMAPIKey["lmstudio", "http://127.0.0.1:1234", "LMSTUDIO_API_KEY", "<token>"];
(* 取得確認 (AccessLevel 1.0 を明示) *)
NBAccess`NBGetLocalLLMAPIKey["lmstudio", "http://127.0.0.1:1234",
  PrivacySpec -> <|"AccessLevel" -> 1.0|>]
```

`PDFIndex` の埋め込み呼び出しと servicemanager の chat 呼び出しは、この token を `Authorization: Bearer` で自動付与します。

---

## 4. 重要 — 登録は「サービスカーネル」に届ける

> **よくある失敗**: release context や profile の登録を**ノートブック/REPL（メインカーネル）で実行しただけ**だと、`/pdfsearch` が
> 「`ReleaseContext "campus-handbook-web" がサービスに未登録です (fail-closed)`」
> というエラーになります。**サービスは別プロセス**で動くため、メインカーネルの登録は伝わりません。

登録の届け先は 2 通りあり、**いずれもサービスカーネルで登録が実行されること**が要点です。

- **方式A（推奨・本書の手順）**: 登録をサービスの **prelude** に含める。prelude はサービスカーネルで実行されるので確実。
- **方式B（本番向け）**: `<PrivateVault>/config/local/SourceVaultLocalInit.wl` に登録を書き、prelude と main の両方で `SourceVaultLoadLocalInit[]` を呼ぶ（§4b）。**REPL で打つだけでは不可**。

登録する設定（学生便覧ワークフロー）は次の 3 つです（release context / PDFIndex profile / migration rule）。アプリ固有の表題・質問応答 prompt・chat モデルは **`StartHTTPProxy` のオプション**で渡します（§5-3）。

---

## 5. 起動手順（方式A・self-contained）

```mathematica
(* 5-1. 検索バックエンド・token・CSS をサービスカーネルに読み込み、
        学生便覧の登録 (RC/profile/rule) を prelude 内で実行し、index を pre-warm する。
        ※ RC/profile/rule の登録をここに含めるのが肝心 (サービスカーネルに届く)。 *)
pkgDir = DirectoryName[FindFile["SourceVault_servicemanager.wl"]];
prelude = StringJoin[
  "Block[{$CharacterEncoding=\"UTF-8\"}, Get[", ToString[FileNameJoin[{pkgDir, "NBAccess.wl"}], InputForm], "]];\n",
  "Block[{$CharacterEncoding=\"UTF-8\"}, Get[", ToString[FileNameJoin[{pkgDir, "PDFIndex.wl"}], InputForm], "]];\n",
  "Block[{$CharacterEncoding=\"UTF-8\"}, Get[", ToString[FileNameJoin[{pkgDir, "WebServer.wl"}], InputForm], "]];\n",
  "SourceVault`SourceVaultRegisterReleaseContext[\"campus-handbook-web\", <|",
  "\"MaxPrivacyLevel\"->0.5, \"RequiredTags\"->{\"ReleaseContext:Campus:Handbook:Web\"}, ",
  "\"DenyTags\"->{\"NoWeb\",\"Draft\",\"Personal\"}|>];\n",
  "SourceVault`SourceVaultRegisterPDFIndexProfile[\"student-handbook\", <||>];\n",
  "SourceVault`SourceVaultRegisterPDFIndexMigrationRule[\"student-handbook\", <|",
  "\"AssignReleaseContexts\"->{\"ReleaseContext:Campus:Handbook:Web\"}, ",
  "\"AssignPrivacyLevel\"->0.1, \"AssignState\"->\"Published\"|>];\n",  (* 公開資料なので低privacy *)
  "PDFIndex`pdfLoadIndex[\"default\"];\n"];

(* 5-2. detached サービス起動 (メイン終了後も生存) *)
SourceVaultStartService["handbook-web-svc",
  "Kind" -> "websearch", "HeartbeatIntervalSeconds" -> 1, "PreludeCode" -> prelude];
TimeConstrained[
  While[Lookup[SourceVaultServiceStatus["handbook-web-svc"], "State"] =!= "Running", Pause[2]], 120];

(* 5-3. Python HTTP proxy 起動。アプリ固有値 (表題/質問応答prompt/モデル/対象/gate) を
        直接オプションで渡す (EndpointProfile を使わないので main 側の登録は不要)。
        SearchTimeoutMs は LLM 合成の所要時間に合わせる (kimi ~17s なら 60000)。 *)
SourceVaultStartHTTPProxy["handbook-web-svc",
  "Port" -> 8080, "RoutePrefix" -> "/sv",
  "ReleaseContext" -> "campus-handbook-web", "PDFIndexProfile" -> "student-handbook",
  "AppTitle" -> "学生便覧 検索",
  "AskPrompt" ->   (* 抽出型: 一覧を列挙し年度を明記。厳格すぎると OCR が崩れた表で「見つかりません」を返しがち *)
    "あなたは大学の学生便覧アシスタントです。提供された【根拠】(release gate 通過済みの検索結果)から" <>
    "【質問】に関連する情報を日本語でまとめ、該当する科目一覧・表があれば項目をできるだけ列挙してください。" <>
    "複数年度の表がある場合は年度(令和N年度/西暦)を明記し、質問の年度に最も近いものを優先。" <>
    "表やOCRが読み取りにくい場合も推測と断定は避けつつ可能な範囲で抽出し、各事実の末尾に (p.ページ番号) を付けてください。" <>
    "根拠に全く該当が無い場合のみ「便覧に記載が見つかりません」と述べてください。",
  "ChatModel" -> "cloud",  (* 公開資料なのでクラウド LLM (ClaudeQueryBg) を使用=高速。
                              ローカルなら "kimi-linear-48b-a3b-instruct" 等、省略/Automatic で loaded・非thinking 自動選択 *)
  "SearchTimeoutMs" -> 30000]  (* /pdfask は非同期 (回答は背景生成) なので検索分で足りる *)
```

> **モデルの選び方**: `ChatModel -> "cloud"` は公開コンテンツ向け（クラウド LLM = `ClaudeCode\`ClaudeQueryBg`、~数秒で高速）。`"cloud:<model>"` でモデル指定可。クラウドへ渡るのは **release gate を通過した公開チャンクのみ**（生 vault は非露出）。機密コレクションでは `"cloud"` を使わずローカルモデル名にすること。

---

## 4b. （任意・本番）private local init ファイルに設定を置く方式B

複数サービスで共有したい・起動コードを短くしたい場合は、登録をファイルに書きます。配置先は `SourceVaultLocalConfigRoot[]`（= `<PrivateVault>/config/local`）。

```mathematica
(* SourceVaultLocalConfigRoot[] が示すディレクトリに SourceVaultLocalInit.wl を作成し、
   §5-1 と同じ 3 登録 + 必要なら endpoint profile を書く。例: *)
SourceVault`SourceVaultRegisterWebServiceEndpoint["handbook-web", <|
  "BindAddress" -> "127.0.0.1", "Port" -> 8080, "RoutePrefix" -> "/sv",
  "ReleaseContext" -> "campus-handbook-web", "PDFIndexProfile" -> "student-handbook",
  "AppTitle" -> "学生便覧 検索", "AskPrompt" -> "あなたは大学の学生便覧アシスタント…",
  "ChatModel" -> "kimi-linear-48b-a3b-instruct"|>];
```

この方式では prelude を `"...; SourceVault\`SourceVaultLoadLocalInit[]; PDFIndex\`pdfLoadIndex[\"default\"];"` とし、main でも `SourceVaultLoadLocalInit[]` を呼んでから `SourceVaultStartHTTPProxy["handbook-web-svc", "EndpointProfile"->"handbook-web", "SearchTimeoutMs"->60000]` で起動します。**登録が確実にロードされたか** `SourceVaultLocalConfigStatus[]` で確認できます（`Status->NotFound` ならファイル未作成）。

> 別アプリを公開するときは、endpoint profile（または §5-1 の登録 + §5-3 のオプション）を別名で増やすだけ。SourceVault のコードは一切変更しません。

---

## 6. アクセス

| URL | 内容 |
|---|---|
| `http://127.0.0.1:8080/sv/` | 検索ホーム（フォーム。表題は `AppTitle`） |
| `http://127.0.0.1:8080/sv/pdfsearch?q=履修登録` | **gate 済み検索結果（LLM 非使用・即時）** |
| `http://127.0.0.1:8080/sv/pdfsearch/api?q=履修登録` | 同上の JSON |
| `http://127.0.0.1:8080/sv/pdfask?q=卒業に必要な単位` | **gate 済み根拠を LLM が合成した回答** ＋ 根拠一覧 |
| `http://127.0.0.1:8080/sv/pdfpage?p=22` | PDF ページ画像（前/次ナビ付き） |
| `http://127.0.0.1:8080/sv/health` | 稼働状態（status/heartbeat 直読み・即時） |
| `http://127.0.0.1:8080/sv/style.css` | CSS |

- `/pdfsearch` は **index から LLM 非使用**で根拠一覧を返す（速い）。表示はチャンクの短いスニペット。
- `/pdfask` は **同じ gate 済み根拠だけ**を LLM に渡して回答を合成する（生 vault は LLM に見せない）。LLM 不可時は根拠のみに degrade。
  - LLM へは **gate を通過した上位チャンクのフル本文**（`PDFIndex\`pdfGetChunk` で取得）を渡す。pdfSearch の context は ~90 字（表ヘッダのみ）と短く、これだけだと LLM が「記載が見つかりません」を返しやすいため。Permit 済みチャンクのみ渡すので gate は維持。
  - **非同期**: `/pdfask` は初回に **gated 検索の根拠を即時表示**し、回答は**バックグラウンド生成**（`SessionSubmit`）。ブラウザは JS で `?a=1` へポーリングして回答を差し込む。**各リクエストが即応するので、遅いモデルでも `service timeout` にならない**。回答はクエリ単位でサーバ側キャッシュ。
  - **年度配慮**: 質問に年度（R7 / 令和7 / 2025 等）が含まれると、その年度の文書を根拠の上位へ**再ランク**してから上位 12 件を LLM に渡す（年度指定の取りこぼし対策）。各根拠には「[令和N年度版]」ラベルを付与。
  - **補足知識**: 後述 §6b の人手レビュー済み補足知識（凡例・崩れ表の転記）があれば、PDF 根拠の前に最優先で LLM に渡し、回答下部の「補足知識（人手レビュー済み）」セクションに出典付きで表示する。
  - **注意（OCR/検索精度）**: 表が複数チャンク・複数ページにまたがる、または OCR が崩れていると、特定年度の必修区分（②/●）を断定できないことがある。その場合は §6b の補足知識（凡例＋転記）で補う。

---

## 6b. 補足知識・凡例・崩れ表の転記支援 (curated knowledge)

OCR で崩れた表（縦羅列・年度ヘッダ欠落）や、PDF に明記されない凡例（②＝必修 などの慣例）は、検索だけでは拾えない/判定できないことがあります。これらを **人手レビュー済みの補足知識** として登録すると、PDF 根拠と一緒に LLM へ「根拠」として渡せます（命令ではなく `EvidenceOnly`）。補足知識は `<CoreRoot>/curated/curated_knowledge.wl` に**永続化**され、別プロセスの service からも読まれます（登録は任意のカーネルで1回でよい）。

### 凡例の登録（必修/選択の分類を解禁する）

```mathematica
SourceVaultRegisterCuratedKnowledge["handbook-legend", <|
  "Text" -> "福山大学便覧の凡例: ②=必修科目, △N=選択必修, 通常数字=選択科目, ●=配当年次",
  "LegendMap" -> <|"②" -> "必修", "△" -> "選択必修", "●" -> "配当年次"|>,
  "ProvidesLegend" -> True,                     (* ← これで「必修/選択の分類断定」が解禁される *)
  "Years" -> {2024, 2025},                      (* 適用年度 (空 {} なら全年度) *)
  "ReleaseContexts" -> {"campus-handbook-web"}, (* ← 一致しないと gate で使われない *)
  "ReviewState" -> "HumanReviewed"|>];          (* ← HumanReviewed 以外は使われない *)
```

### 崩れた表を LLM で clean に転記 → 確認 → 補足知識として登録

`SourceVaultDraftCuratedTranscription` は、OCR で崩れた表チャンクのフル本文を LLM で読める形に**転記**し、**自動登録せず `NeedsHumanReview` ドラフト**を返します（捏造せず、判読不可は「(判読不可)」と記す）。内容を人手で確認・修正してから登録します。

```mathematica
PDFIndex`pdfLoadIndex["default"];
draft = SourceVaultDraftCuratedTranscription["情報工学科",
  "ChunkIds" -> Automatic,   (* Automatic は query 検索の上位を転記。明示リストも可 *)
  "Limit" -> 4,
  "Years" -> {2025}, "ReleaseContexts" -> {"campus-handbook-web"}];

(* draft["CleanText"] を確認・必要なら必修を明記して編集 → 承認して登録 *)
SourceVaultRegisterCuratedKnowledge["handbook-r7-joho",
  Append[draft["ProposedCuratedSpec"], "ReviewState" -> "HumanReviewed"]];
```

### 一覧

```mathematica
SourceVaultListCuratedKnowledge[]   (* {"id" -> spec, ...} *)
```

> 採用条件: **release context 一致（gate）＋ 年度 scope 一致 ＋ `ReviewState->"HumanReviewed"`**。満たすものを **score 非依存で上位（既定3件）** 採用し、`/pdfask` の「補足知識（人手レビュー済み）」に出典表示します。`AllowedUse->"EvidenceOnly"`（既定）は命令ではなく根拠として渡されます。

---

## 6c. 「列挙OK・分類断定NG」と Evidence Gap

質問が必修/選択などの**分類**を問う場合（既定で「必修」「選択必修」「選択科目」「分類」を含む質問）、凡例（`LegendMap`）が無いと **候補の列挙は許可、必修/選択の断定は抑制**します（推測で必修と断定しない＝honest）。§6b の凡例 curated（`ProvidesLegend->True`）を登録すると分類が解禁されます。

凡例なしで分類質問が来ると **Evidence Gap** が記録され、「この質問には凡例が必要」と追跡できます。

```mathematica
SourceVaultListEvidenceGaps[]            (* 開いている gap 一覧 (GapId -> gap) *)
SourceVaultCloseEvidenceGap["gap:..."]   (* 対応済みにする *)
```

凡例 curated を登録すれば、以後その scope の同種質問では gap は開かず、分類して回答します。

> 分類意図の判定語は設定値です。コードに焼かず `SourceVault\`ServiceManagerPrivate\`$svClassificationIntentPhrases`（既定 `{"必修","選択必修","選択科目","分類"}`）で上書きできます。

---

## 6d. PDFGroupSearchProfile — 設定をデータ化して横展開

学生便覧は一例です。任意の PDF グループ（規程・シラバス・研究資料…）を、**コードを変えず設定オブジェクト1つ**で立ち上げられます（configuration-as-data）。

```mathematica
SourceVaultCreatePDFGroupSearchProfile["handbook-web", <|
  "AppTitle" -> "学生便覧 検索",
  "ReleaseContext" -> "campus-handbook-web",
  "PDFIndexProfile" -> "student-handbook",
  "ChatModel" -> "cloud"|>];

(* StartHTTPProxy に渡すと、未指定項目をこの profile から供給 *)
SourceVaultStartHTTPProxy["handbook-web-svc",
  "PDFGroupProfile" -> "handbook-web", "Port" -> 8080, "SearchTimeoutMs" -> 30000];

(* 別グループは clone + override で横展開 (コード変更ゼロ) *)
SourceVaultClonePDFGroupSearchProfile["handbook-web", "rules-web",
  <|"AppTitle" -> "学内規程 検索", "ReleaseContext" -> "rc-rules", "PDFIndexProfile" -> "rules"|>];
SourceVaultListPDFGroupSearchProfiles[]   (* {handbook-web, rules-web} *)
```

> 設定の優先順位は **直接オプション > EndpointProfile > PDFGroupProfile > 既定**。`SourceVaultResolvePDFGroupSearchProfile[alias]` で解決（未登録は fail-closed）。

---

## 6e. LLM ライセンス/課金ポリシー（重要）

**ClaudeCode / Codex（サブスク CLI）は契約者本人しか使えません。** よって、**他者が使う web サービスの `/pdfask` で ClaudeCode/Codex を呼んではいけません**（ライセンス違反）。`/pdfsearch`（索引のみ・LLM 非使用）は誰が使っても問題ありません。

本サービスは **既定で ClaudeCode/Codex（サブスク）を一切使いません**（保守的）。サブスクを使うには、**明示許可（`AllowOwnerSubscription->True`）かつ ローカルバインド（`127.0.0.1`）かつ オーナー IP からのリクエスト**の3条件すべてが必要です。公開バインド（`0.0.0.0`）では、オーナー宛でもサブスクは使いません。

| 条件 | 使う LLM |
|---|---|
| オーナー + ローカルバインド + `AllowOwnerSubscription->True` | `cloud`=**ClaudeCode/Codex**（＝自分が対話的に使う場合のみ） |
| 上記以外（公開バインド・未許可・他者） + 課金禁止 | **LM Studio（ローカル）一択** |
| 上記以外 + 課金OK | **課金API**（従量 API キー）または LM Studio |

→ **他者のリクエストが ClaudeCode/Codex に到達することは決してありません。** さらに公開サービスでは、オーナー宛でも既定でサブスクを使わないので、ライセンス的に安全側に倒しています。

### A. 公開サービス（他者が使う）— 推奨

```mathematica
SourceVaultStartHTTPProxy["handbook-web-svc",
  "Port" -> 8080, "Bind" -> "0.0.0.0",                  (* 公開 *)
  "BillingAllowed" -> False,                            (* 課金禁止 → 全員 LM Studio *)
  "ChatModel" -> "api"];                                (* 課金OKなら "api"(従量課金) を使う *)
(* AllowOwnerSubscription は指定しない(=False)。公開バインドなのでどのみちサブスクは使われない。 *)
```

公開時は **`"api"`（従量課金 API）か LM Studio** を使うのがライセンス的にクリーンです（API はアプリ/サービス用のライセンス）。`"BillingAllowed"->True` のとき `"api"` が有効になります。

### B. 自分専用（ローカルで自分が対話的に使う）

```mathematica
SourceVaultStartHTTPProxy["handbook-web-svc",
  "Port" -> 8080, "Bind" -> "127.0.0.1",                (* ローカルのみ *)
  "AllowOwnerSubscription" -> True,                     (* 明示的に許可したときだけサブスク可 *)
  "ChatModel" -> "cloud"];                              (* 自分の ClaudeCode を使う *)
```

### 補足

- 既定は `$SourceVaultOwnerIPs = {"127.0.0.1", "::1", "localhost"}`、`$SourceVaultBillingAllowed = False`、`AllowOwnerSubscription = False`（すべて最も安全側）。
- `ChatModel`: `"cloud"`/`"cloud:<model>"`=ClaudeCode/Codex（上の3条件を満たす時のみ。満たさなければ自動で `api`/ローカルへ降格）、`"api"`/`"api:<model>"`=従量課金 API（`NBGetAPIKey["anthropic"]`、既定モデル `$SourceVaultWebBilledModel`）、その他=ローカルモデル名または登録済み LLM バックエンド名。
- **クライアント IP は proxy が実 TCP 接続元から取得します（`X-Forwarded-For` はなりすまし可能なので採用しません）。**
- **運用規律（コードでは防げない部分）**: ClaudeCode で答えてよいのは「自分自身の質問」だけ。他者の質問をオーナー PC からまとめて代理投入してはいけません（実質的なライセンス違反になります）。

> 直接 `iServiceHttpRender` を呼ぶ（proxy を介さない＝オーナー自身のカーネルで対話的に使う）場合は IP 不明＝オーナー扱い・サブスク既定許可です。**公開は必ず proxy 経由**で行ってください。
>
> 本節は規約の一般的整理であり法的助言ではありません。業務公開時は現行の Claude Code / Anthropic 利用規約（Codex 側は OpenAI 規約）を一次情報で確認してください。

---

## 6f. arXiv ソース一覧・サマリー管理

ingest 済みの arXiv ソースは `SourceVaultArXiv` で一覧表示できます。表示中のタイトルまたはサマリーをクリックすると `SourceVaultShowSourceSummary` が呼ばれ、**編集可能なサマリーノートブック**が開きます（保存済みの追記版があればそれを正本として開きます）。

```mathematica
(* arXiv ソースのみ一覧 (SourceVaultSources["", "Kind"->"arxiv"] の薄ラッパ) *)
SourceVaultArXiv["可逆計算"]                                   (* クエリ部分一致 *)
SourceVaultArXiv["", "On" -> Today]                            (* 今日 ingest したもの *)
SourceVaultArXiv["", "Author" -> "Bennett", "Since" -> "2025-01-01"]  (* 著者・期間絞り込み *)
```

arXiv ソースは ingest 時にアブストラクトを取得し、`$Language` へ翻訳して Summary に自動格納します。既存ソースで Summary が未設定（または過去の LLM エラー本文）の場合は `SourceVaultBackfillArXivSummaries` で一括補完できます。

```mathematica
(* 未設定/エラー本文のあるソースに一括バックフィル *)
SourceVaultBackfillArXivSummaries[]
(* => <|"Candidates"->N, "Updated"->N, "AlreadyPresent"->N, "NoAbstract"->N, "Failed"->N, "Results"->{...}|> *)

(* Force->True で既存 Summary も再生成、Limit で処理件数を制限 *)
SourceVaultBackfillArXivSummaries["Force" -> True, "Limit" -> 10]
```

> **注意**: 翻訳は cloud LLM を使用します（arXiv は公開データなので PrivacyLevel 0.0）。`$Language` が `Japanese` のセッションで実行してください。headless 環境では英語原文のまま格納されます。

### プライバシーレベルの誤設定修正

旧版では arXiv などの `OfficialDocs` が PrivacyLevel 0.6 と誤タグされる不具合がありました（公開 arXiv が機密扱いになり `SourceVaultArXiv` 等に出ない原因でした）。現行版では正しい既定値（`OfficialDocs`/`OfficialAPI` = 0.0、`PublicWeb` = 0.4）が使われますが、旧版で ingest 済みのレコードが残っている場合は `SourceVaultReclassifyPublicPrivacy` で一括修正できます。

```mathematica
(* 公開ソース (arXiv / 公開 URL) の PrivacyLevel を正値に修正 *)
SourceVaultReclassifyPublicPrivacy[]
(* => <|"Status", "Count", "Changed" -> {<|SourceId, From, To|>...}|> *)
```

また `SourceVaultSources` / `SourceVaultArXiv` / `SourceVaultSummaries` の表で**タイトルまたはサマリーをクリック**すると `SourceVaultShowSourceSummary` が開きます。`SourceVaultOpenSourceFile` を使うと raw ファイルを直接開くことができます。

```mathematica
(* ソースのサマリーノートブックを開く (表のクリックと同じ) *)
SourceVaultShowSourceSummary["sv-src-XXXXXXXX"]

(* ingest 済みソースの raw ファイルを現 PC で解決して開く *)
SourceVaultOpenSourceFile["sv-src-XXXXXXXX"]

(* 1 ソースの共通スキーマ行を取得 ("URI" フィールド = sv://snapshot/sha256/<hex> を含む) *)
SourceVaultSourceRow["sv-src-XXXXXXXX"]
```

---

## 7. 停止・再起動

```mathematica
SourceVaultStopHTTPProxy["handbook-web-svc"];   (* proxy 停止 (port もポート基準で確実に解放) *)
SourceVaultStopService["handbook-web-svc"];      (* service 停止 (task 削除 + pid kill) *)
```

コード更新後は **`Quit[]` → 再ロード → 再起動**が安全です（サブファイル単独 `Get` は SourceVault\` シンボルを壊すため、必ず `Get["SourceVault.wl"]` でまとめてロード）。

---

## 8. メンテナンス・トラブルシュート

| 症状 | 原因 / 対処 |
|---|---|
| `… がサービスに未登録です (fail-closed)` | release context / profile の登録が**サービスカーネルに届いていない**（REPL で登録しただけ、等）。§4・§5-1 の通り **prelude に登録を含める**か、方式B のファイルを作って prelude/main で `LoadLocalInit`。エラー文面の種別・名前が未登録対象。 |
| `service timeout`（/pdfask） | 非同期化済みのため通常は出ない。出る場合は **gated 検索自体**が `SearchTimeoutMs` 超過（embedding 等）。`SearchTimeoutMs` を 30000 程度に。`ChatModel->"cloud"` で回答も高速。古い同期版が残っているなら `Quit[]`→再ロード→サービス再起動。 |
| 回答が出ず「生成中…」のまま | バックグラウンド生成が失敗（クラウド未認証 / モデル未ロード）。`ChatModel->"cloud"` ならクラウド API キー（`NBGetAPIKey`）を確認。240 秒で自動的に「生成不可」表示に切替。 |
| 検索が keyword のみ / 意味検索が効かない | LM Studio に埋め込みモデルが未ロード、または token 未設定（401）。§3 を確認。 |
| 既存 index の embedding が壊れている | 索引時にエンコード不整合があった場合、`PDFIndex\`pdfReembed["default"]` で保存済みテキストから embedding のみ再生成（PDF 再抽出・LLM 再要約なしの軽量処理）。 |
| `/pdfask` と `/pdfsearch` が同じ結果 | `ChatModel` 未解決で LLM が呼べず degrade している。loaded な chat モデルを確認。 |
| 必修/選択が断定されず候補列挙だけになる | 凡例 (LegendMap) が未登録。§6b で `ProvidesLegend->True` の凡例 curated を該当 release context・年度で登録すれば分類が解禁される。`SourceVaultListEvidenceGaps[]` で「凡例が要る質問」を確認できる。 |
| 崩れた表が検索に出ない / 内容が拾えない | bge-m3＋窓拡大で `PDFIndex\`pdfReembed["default"]`。それでも不足なら §6b の `SourceVaultDraftCuratedTranscription` で転記→確認→ curated 登録（clean text は検索で上位に来る）。 |
| arXiv ソースが一覧に出ない / 機密扱いになる | 旧版の PrivacyLevel 誤設定バグ（OfficialDocs が 0.6 になっていた）。`SourceVaultReclassifyPublicPrivacy[]` で一括修正し、その後 `SourceVaultArXiv[]` で確認する。 |
| arXiv サマリーが空または LLM エラー文になっている | ingest 時の自動翻訳が失敗したか旧版で登録された。`SourceVaultBackfillArXivSummaries[]` で再生成（`$Language = "Japanese"` のセッションで実行すること）。 |
| `path::shdw` 警告 | PDFIndex の `$pdfPythonPath` が原因（修正済み）。最新の PDFIndex.wl を再ロード、またはセッションの `Global\`path` を `Remove`。 |
| 起動直後に即停止（heartbeat 1） | 古い `Stop` コマンド残留。修正版 `StartService` は起動前に `commands/` を purge する。再起動で解消。 |
| 文字化け | 旧版の二重エンコードバグ。現行は JSON の書き込み（`iSMWriteJSON`）・読み込み（`iSMParseRawJSON`）ともに `ExportByteArray`/`ImportByteArray` 経路で解消済み（`ExportString` は ShiftJIS 環境で二重 UTF-8 化するため不使用）。サービス再起動で反映。 |

ロード済みモデルと状態は LM Studio 拡張 API で確認できます。

```mathematica
Import["http://127.0.0.1:1234/api/v0/models", "Text"]   (* state=loaded, type=llm/vlm/embeddings *)
```

---

## 9. セキュリティ要点

- **release gate は必ず WL 側**で評価され、`Permit` のチャンクのみ返る（build 時・request 時の二重評価＋失効照合）。
- HTTP レスポンスに **raw local path を出さない**（citation は doc タイトル＋ページのみ）。
- `/pdfask` の LLM には **gate 済み根拠だけ**を渡す（生 vault 非露出）。
- **content-addressed 不変スナップショット**（ID が `snapshot:class:hex` または `sv://snapshot/...` 形式）は本体ファイルが書き換わらないため、プライバシーレベルの変更はサイドレコードへ委譲されます（§10 参照）。スナップショット ID はコロンを含む形式のため、通常の colon-path ファイルパスより**先に pattern で判定**されます。`SourceVaultSourceRow` が返す `"URI"` フィールド（`sv://snapshot/sha256/<hex>`）はこの正準 URI であり、横断データセットの join/参照キーとして使用できます。
- **ClaudeCode/Codex（サブスク）はオーナー PC の IP からのリクエストのみ**（§6e）。他者には絶対に使わせない（ライセンス遵守）。クライアント IP は実 TCP 接続元から取得し、`X-Forwarded-For` は信用しない。
- mail = draft のみ（自動送信しない）、Discord = 承認必須（`DispatchOutput`）。
- アプリ固有の実 path / endpoint / token は **private local init と NBAccess credential** に置き、リポジトリには残さない。

---

## 10. 主な公開 API（本書で使うもの）

| 用途 | API |
|---|---|
| 設定登録 | `SourceVaultRegisterReleaseContext` / `RegisterPDFIndexProfile` / `RegisterPDFIndexMigrationRule` / `RegisterWebServiceEndpoint` / `RegisterLLMBackend`（`"Class"->"Light-Cloud"` / `"Capabilities"->{"Reasoning"}` 等のフィールドをサポート。バッテリー節約・LM Studio 未起動時の代替 LLM をデータとして登録できる） |
| サービス | `SourceVaultStartService` / `StopService` / `ServiceStatus` / `SendServiceCommand` |
| プロキシ | `SourceVaultStartHTTPProxy`（`PDFGroupProfile`/`EndpointProfile`/`AppTitle`/`AskPrompt`/`ChatModel`/`ReleaseContext`/`PDFIndexProfile`/`SearchTimeoutMs`） / `StopHTTPProxy` / `HTTPProxyStatus` |
| ソース一覧・閲覧 | `SourceVaultSources`（`"Kind"`/`"Author"`/`"Since"`/`"Until"`/`"On"` で絞り込み） / `SourceVaultArXiv`（arXiv 専用ビュー・`SourceVaultSources["", "Kind"->"arxiv", ...]` の薄ラッパ） / `SourceVaultSummaries`（横断検索） / `SourceVaultBackfillArXivSummaries`（既存 arXiv ソースにアブストラクト翻訳を Summary としてバックフィル） / `SourceVaultShowSourceSummary`（タイトル/サマリークリックで編集可能ノートを開く） / `SourceVaultOpenSourceFile`（raw ファイルを現 PC で解決して開く） / `SourceVaultSourceRow`（共通スキーマ行取得・`"URI"` フィールド `sv://snapshot/sha256/<hex>` を含む） |
| 補足知識 | `SourceVaultRegisterCuratedKnowledge` / `ListCuratedKnowledge` / `DraftCuratedTranscription`（崩れ表の LLM 転記ドラフト） |
| Evidence Gap | `SourceVaultListEvidenceGaps` / `CloseEvidenceGap` |
| PDF グループ設定 | `SourceVaultCreatePDFGroupSearchProfile` / `ResolvePDFGroupSearchProfile` / `ListPDFGroupSearchProfiles` / `ClonePDFGroupSearchProfile` |
| 索引（PDFIndex） | `PDFIndex\`pdfLoadIndex` / `pdfReembed`（モデル変更時の再 embed） / `pdfGetChunk` |
| 不変スナップショット | `SourceVaultImmutableSnapshotExistsQ[snapshotId]`（存在確認）/ `SourceVaultSetImmutableSnapshotPrivacyLevel[snapshotId, lv]`（プライバシーレベル変更。本体不変・サイドレコードへ委譲） |
| 修復ユーティリティ | `SourceVaultReclassifyPublicPrivacy`（公開ソースの PrivacyLevel 誤設定を一括修正。`OfficialDocs`/`OfficialAPI` = 0.0、`PublicWeb` = 0.4 に是正） |

### LLM バックエンド登録例（バッテリー節約・LM Studio 未起動時の代替）

ローカル LLM が使えない環境向けに、`SourceVaultRegisterLLMBackend` で軽量クラウドモデルをデータとして登録しておくと、`ChatModel` の解決時に自動的に代替として利用できます。

```mathematica
(* "Light-Cloud" クラスのバックエンドを登録 (コードに固有名をハードコードしない) *)
SourceVaultRegisterLLMBackend["light-cloud-fallback", <|
  "Class" -> "Light-Cloud",
  "Capabilities" -> {"Reasoning"},
  "Note" -> "バッテリー節約・ローカル LLM 未起動時の代替"|>];
```

`"Class" -> "Light-Cloud"` は軽量クラウドモデルを示す分類フィールドです。`"Capabilities" -> {"Reasoning"}` を指定すると推論能力が必要なクエリでこのバックエンドが優先的に選択されます。バックエンドはデータとして登録するため、コードを変えずに切り替えが可能です。

### content-addressed 不変スナップショット

SnapshotId が `snapshot:class:hex` または `sv://snapshot/...` 形式のレコードは **content-addressed 不変スナップショット**として扱われます。本体ファイルは書き換えが禁止されているため、プライバシーレベルの変更は専用のサイドレコードへ委譲されます。

```mathematica
(* スナップショットの存在確認 *)
SourceVaultImmutableSnapshotExistsQ["snapshot:pdf:a1b2c3..."]
(* => True / False *)

(* プライバシーレベルをサイドレコードに記録 (本体は変更されない) *)
SourceVaultSetImmutableSnapshotPrivacyLevel["snapshot:pdf:a1b2c3...", 0.5]
```

スナップショット ID はコロン（`:`）またはスキーム（`sv://`）を含むため、通常の vault パスの判定（`FileExistsQ` 等）より**先に pattern で照合**されます。通常の vault レコードと同じ gate・プライバシー評価を受けますが、本体の不変性が保証されます。

---

## 11. まとめ

- `Get["SourceVault.wl"]` で基盤一式（core / searchindex / servicemanager / mcp / objectview）がロードされます。
- アプリ（学生便覧）は **release context / profile / migration rule** をサービス prelude（方式A）または private local init（方式B）で登録するだけ。SourceVault コードはドメイン非依存です。
- 起動は **StartService(prelude) → StartHTTPProxy** の 2 ステップ（方式B は前に `LoadLocalInit`）。
- arXiv ソースは ingest 時にアブストラクトが自動翻訳されて Summary に格納されます。`SourceVaultArXiv` で種別専用一覧表示、`SourceVaultBackfillArXivSummaries` で既存ソースへの一括補完が可能です（§6f）。タイトル/サマリーのクリックは `SourceVaultShowSourceSummary` で編集可能ノートブックを開きます。
- 旧版で arXiv 等が PrivacyLevel 0.6 と誤タグされた場合は `SourceVaultReclassifyPublicPrivacy[]` で修正できます（§6f）。
- 崩れた表・凡例は **補足知識 (curated)** で補い（§6b）、凡例があれば必修/選択を**分類**、無ければ**列挙のみ＋Evidence Gap 記録**（§6c）。
- 別 PDF グループは **`PDFGroupSearchProfile` を clone+override** するだけで横展開できます（§6d）。コード変更は不要です。
- LLM バックエンドは `SourceVaultRegisterLLMBackend` でデータとして登録でき、`"Class"->"Light-Cloud"` / `"Capabilities"->{"Reasoning"}` によりバッテリー節約・LM Studio 未起動時の代替を設定として管理できます（§10）。
- **content-addressed 不変スナップショット**（`snapshot:class:hex` / `sv://snapshot/...` 形式）は本体不変。存在確認は `SourceVaultImmutableSnapshotExistsQ`、プライバシーレベル変更は `SourceVaultSetImmutableSnapshotPrivacyLevel`（サイドレコードへ委譲）で行います（§9・§10）。`SourceVaultSourceRow` の `"URI"` フィールドがこの正準 URI を提供します。
- 埋め込みは **bge-m3（8192）**、回答合成は **ローカル instruct or `ChatModel->"cloud"`**。`/pdfask` は**非同期**で遅いモデルでも timeout しません。JSON の読み書きは `ExportByteArray`/`ImportByteArray` 経路で文字化けを防いでいます。