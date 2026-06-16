## 動作要件

| 項目 | 要件 |
|------|------|
| Mathematica | 13.2 以降（14.x 推奨） |
| OS | Windows 11（64-bit） |
| Anthropic API キー | 任意（LLM 要約・claim 抽出機能を使う場合のみ） |

---

## 依存パッケージ

SourceVault は以下のパッケージに依存しています。先にインストールしてください。

- **[NBAccess](https://github.com/transreal/NBAccess)** — ノートブックアクセス制御・semantic API。Notebook ヘッダ / Todo の読み書きはすべて NBAccess を経由します。`NBReadHeader` / `NBReadTodos` / `NBWriteTodoStatus` などの高レベル semantic API が必須です。
- **[claudecode](https://github.com/transreal/claudecode)** — LLMGraph DAG スケジューラ・`$Path` 自動設定・LLM プロバイダーへの問い合わせ経路。

### オプションパッケージ

- **[ClaudeRuntime](https://github.com/transreal/ClaudeRuntime)** — `SourceVaultNotebookSummary` などの LLM 要約機能を `ClaudeEval` 経由で実行する場合に必要です。SourceVault 単体では index・extract・lint・FindNotebooks クエリなど deterministic な機能のみ動作します。
- **[ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)** — 複数 notebook の一括処理を agentic に並列実行する場合に追加でロードしてください。SourceVault の NBAccess hook (P1〜P4) は ClaudeOrchestrator のフックポイントに接続できます。

---

## github パッケージによる簡単インストール

[github](https://github.com/transreal/github) パッケージがインストール済みの場合は、`GitHubInstallPackage` で SourceVault をリポジトリから `$packageDirectory` へ直接インストールできます。手動でファイルを配置する「インストール手順」の代わりに、こちらを使うと簡単です。

```mathematica
(* github パッケージをロード *)
Block[{$CharacterEncoding = "UTF-8"},
  Needs["GitHub`", "github.wl"]
]

(* SourceVault をリポジトリから $packageDirectory へインストール *)
GitHubInstallPackage["SourceVault",
  "https://github.com/transreal/SourceVault"]
```

`SourceVault.wl` のロード時には、同じディレクトリにある以下の補助サブファイルが自動的に読み込まれます。これらも `$packageDirectory` 直下に配置してください。

- `SourceVault_core.wl` — コアサブファイル
- `SourceVault_searchindex.wl` — 検索インデックス
- `SourceVault_servicemanager.wl` — サービスマネージャ
- `SourceVault_promptrouter.wl` — PromptRouter 拡張

リポジトリに同梱されている場合は同時に取得されます。別ファイルとして配布されている場合は、同じ要領で `$packageDirectory` へ配置してください。

依存パッケージも同様にインストールできます。

```mathematica
GitHubInstallPackage["NBAccess",
  "https://github.com/transreal/NBAccess"]
GitHubInstallPackage["claudecode",
  "https://github.com/transreal/claudecode"]
```

一度インストールしたパッケージは、`GitHubUpdatePackage` でリポジトリの最新版に更新できます。

```mathematica
(* パッケージ名だけで最新版に更新 *)
GitHubUpdatePackage["SourceVault"]
```

インストール後のロード手順は、後述の「インストール手順」の手順 3 以降（`$Path` の設定・パッケージのロード・PrivateVault の初期化）と同じです。

> github パッケージを使わない場合は、次の「インストール手順」に従って手動でファイルを配置してください。

---

## インストール手順（手動配置）

### 1. `$packageDirectory` の確認

Mathematica カーネルで以下を実行し、パッケージ格納ディレクトリを確認します。

```mathematica
$packageDirectory
```

出力例: `C:\Users\YourName\Dropbox\Mathematica\MyPackages`

### 2. パッケージファイルの配置

リポジトリから必要なファイルを入手し、**`$packageDirectory` 直下**に配置します。

```
$packageDirectory\
  SourceVault.wl                 ← 本体
  SourceVault_core.wl            ← コアサブファイル（本体ロード時に自動ロード）
  SourceVault_searchindex.wl     ← 検索インデックス（本体ロード時に自動ロード）
  SourceVault_servicemanager.wl  ← サービスマネージャ（本体ロード時に自動ロード）
  SourceVault_promptrouter.wl    ← PromptRouter 拡張（本体ロード時に自動ロード）
  NBAccess.wl
  claudecode.wl
  ...
```

> サブフォルダには配置しないでください。
>
> `SourceVault_core.wl`・`SourceVault_searchindex.wl`・`SourceVault_servicemanager.wl`・`SourceVault_promptrouter.wl` はいずれも `SourceVault.wl` のロード時に同じディレクトリから自動的に読み込まれます。

### 3. `$Path` の設定

claudecode を使用している場合、`$Path` は自動的に設定されます。手動で設定する場合は次のとおりです。

```mathematica
If[!MemberQ[$Path, $packageDirectory],
  AppendTo[$Path, $packageDirectory]
]
```

**正しい例**（`$packageDirectory` 自体を追加）:

```mathematica
AppendTo[$Path, $packageDirectory]
```

**誤った例**（サブディレクトリを追加しない）:

```mathematica
(* NG: AppendTo[$Path, "C:\\path\\to\\SourceVault"] *)
```

### 4. パッケージのロード

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["SourceVault`", "SourceVault.wl"]
]
```

依存パッケージも同様にロードしてください。

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",    "NBAccess.wl"];
  Needs["SourceVault`", "SourceVault.wl"]
]
```

LLM 要約・claim 抽出機能を使用する場合は、ClaudeRuntime もロードしてください。

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Needs["NBAccess`",      "NBAccess.wl"];
  Needs["ClaudeRuntime`", "ClaudeRuntime.wl"];
  Needs["SourceVault`",   "SourceVault.wl"]
]
```

### 5. PrivateVault ディレクトリの初期化

SourceVault は **PrivateVault** と呼ばれるローカルストレージに index・snapshot・claim・bundle などを保存します。初回ロード時に自動作成されます。

```mathematica
$SourceVaultRoots["PrivateVault"]
(* 出力例: "C:\\Users\\YourName\\Dropbox\\Mathematica\\PrivateVault" *)
```

PrivateVault のパスを変更したい場合は、SourceVault ロード前に `$SourceVaultRoots` を設定します。

```mathematica
$SourceVaultRoots = <|
  "PrivateVault" -> "C:\\path\\to\\custom\\vault"
|>;
Needs["SourceVault`", "SourceVault.wl"]
```

### 6. デフォルトノートブックフォルダの設定（任意）

`$SourceVaultDefaultNotebookFolder` は、SourceVault が管理するノートブックのデフォルト保存先フォルダを指定します。PresentationListener の保存先としても使用されます。

- 既定値は `Automatic` で、`Global`$onWork` に解決し、未定義の場合は `$packageDirectory` にフォールバックします。
- 絶対パスの文字列を設定すると、そのフォルダがデフォルトの Scope になります。

```mathematica
(* カスタムフォルダを指定する場合（SourceVault ロード前でも後でも設定可） *)
$SourceVaultDefaultNotebookFolder = "C:\\path\\to\\your\\notebooks";
```

```mathematica
(* 現在の解決先を確認する（Automatic のときは $onWork → $packageDirectory に解決される） *)
$SourceVaultDefaultNotebookFolder
```

---

## API キーの設定

LLM 要約・claim 抽出機能は ClaudeRuntime 経由で LLM を呼び出します。claudecode のキー設定手順に従って登録してください。

```mathematica
(* claudecode が提供するキー設定関数で登録する *)
ClaudeSetAPIKey["sk-ant-..."]
```

> キーは安全な場所に保管し、ノートブックにハードコードしないでください。  
> 詳細は [claudecode](https://github.com/transreal/claudecode) の `api-key-handling` ドキュメントを参照してください。

ローカル LLM（LM Studio など）を使用する場合は `$ClaudeModel` を切り替えることで API キーなしで運用できます。

```mathematica
$ClaudeModel = {"lmstudio", "qwen3-coder-30b-instruct"}
```

---

## ノートブック用スタイルシートとテンプレートの配置

SourceVault が管理するノートブックは、`NotebookStatus` スタイルのセルにヘッダ情報を、`TodoItem_x` スタイルのセルに Todo を保持します。これらを正しい見た目で表示するための専用スタイルシート **`SourceVault default.nb`** が、Mathematica のスタイルシートディレクトリに配置されています。

このスタイルシートを**新規ノートブックのテンプレート**として `Templates` フォルダにコピーしておくと、`ClaudeEval["新規ノートブックを"]` や `SourceVaultNewNotebook[]` でテンプレートをもとに新規ノートブックを生成できます。

```mathematica
(* Templates フォルダが無ければ先に作成 *)
If[!DirectoryQ[FileNameJoin[{$packageDirectory, "Templates"}]],
  CreateDirectory[FileNameJoin[{$packageDirectory, "Templates"}]]
];

(* スタイルシートをテンプレートとしてコピー *)
CopyFile[
 FileNameJoin[{$UserBaseDirectory, "SystemFiles", "FrontEnd",
   "StyleSheets", "SourceVault default.nb"}],
 FileNameJoin[$packageDirectory, "Templates",
  "SourceVault notebook template.nb"]]
```

コピー後、テンプレートの `NotebookStatus` セルが既定の書式になっていることを確認してください。

```mathematica
<|"Keywords" -> {"template"},
  "Deadline" -> DateObject[{2026, 1, 1}],
  "NextReview" -> Quantity[1, "Weeks"],
  "Status" -> "Todo"|>
```

`SourceVaultNewNotebook` は、この `Deadline` / `NextReview` を生成日（今日）に置換した未保存の新規ノートブックを開きます。以下のオプションを受け付けます。

| オプション | 既定値 | 説明 |
|-----------|--------|------|
| `"Keywords"` | `Automatic` | `NotebookStatus` の Keywords を置換する文字列または文字列リスト。`Automatic` はテンプレートの値（例: `{"template"}`）を維持します。 |
| `"SessionID"` | `Automatic` | capture session への逆リンク（SessionID）を `NotebookStatus` に埋め込む文字列。`Automatic` は追加しません。 |
| `"Date"` | `Automatic` | ノートブックの日付。`Automatic` はテンプレートの値を維持します。 |

```mathematica
(* Keywords を指定して新規ノートブックを作成 *)
SourceVaultNewNotebook[
  "Keywords" -> {"研究メモ", "2026"},
  "SessionID" -> "session-abc123"
]
```

ノートブックの書式・新規作成の詳細は user_manual の「Notebook Management」を参照してください。

---

## 初回セットアップ（暗号化・メール・アドレス帳）

SourceVault の暗号化・メール・2層アドレス帳サブシステムを使う前に、以下の初期設定を**一度だけ**行います。これらは個人ごとに異なる私的設定（メールログイン名・所属・氏名など）を含むため、**ソースコードや公開リポジトリには置かず**、各自のローカル起動ファイル（`init.m` や個人用の起動ノートブック。GitHub に上げない）にまとめて記述してください。

> **重要（安全）**
> - `NBAccess`$NBCredentialBackend = "SystemCredential"` を**必ず**設定する。`"Memory"`（既定）で暗号化すると鍵が揮発し、次回セッションで本文を復号できなくなります（データ消失・不可逆）。
> - `SystemCredential[...]` への代入（パスワード設定）と `SystemCredential` の使用は **手動実行のみ**（`AutoEvaluate -> True` で自動実行されるコードに含めない。`rules/00`）。
> - パスワードや API キー、私的な氏名・メールは公開しない。`RegisterMailAccount` に保存されるのは **CredKey（SystemCredential のキー名）だけ**で、パスワード本体は保存されません。

### 1. 鍵 backend を SystemCredential にしてパッケージをロード

```mathematica
NBAccess`$NBCredentialBackend = "SystemCredential";   (* 永続鍵ストア。最初に設定 *)
Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault.wl"]];
```

### 2. 暗号化の初期化と鍵バンドルのバックアップ

```mathematica
SourceVault`SourceVaultInitializeEncryption[];        (* 標準鍵を冪等に生成（既存は破壊しない） *)
SourceVault`SourceVaultEncryptionKeyStatus[]          (* 鍵の存在確認 *)
```

鍵はマシンローカル（SystemCredential / DPAPI）に保存され、**Dropbox には載りません**。別マシンへの移行・OS 再インストールからの復旧に備え、強いパスフレーズで鍵バンドルを **Dropbox の外**（USB・パスワードマネージャ等）に退避しておきます。

```mathematica
(* 出力先は既定で $HomeDirectory（非 Dropbox）。USB 等へコピーして保管 *)
SourceVault`SourceVaultExportKeyBundle["○○ 強いパスフレーズ ○○"]
(* 別マシンでの復元: SourceVault`SourceVaultImportKeyBundle["同じパスフレーズ", "Path" -> "<退避先>"] *)
```

### 3. オーナー（自分）をアドレス帳に登録

ユーザデータベースの **#1 がオーナー（自分）** です。氏名（日本人名は漢字＝正式・ローマ字・かな＝検索用の3表記）とメールをアドレス帳に登録し、`IdentityInitialize` でオーナー実体 #1 として確定します。

```mathematica
(* 自分をアドレス帳に登録（プレースホルダを自分の値に） *)
SourceVault`SourceVaultAddressBookRegisterSelf["you@example.org",
   "DisplayName" -> "山田 太郎",
   "Kanji"  -> "山田 太郎",
   "Romaji" -> "Taro Yamada",
   "Kana"   -> "やまだ たろう",
   "Persist" -> True];

(* identity 層を初期化 → アドレス帳 self を継承して オーナー実体 #1 を確保 *)
SourceVault`SourceVaultIdentityInitialize[];
```

オーナーの **LLMProfile**（メールの優先度/概要を推定する LLM プロンプトに渡す受信者説明）と**プライマリメール**を設定します。これらは派生処理や ReplyAll の自分除外に使われ、ソースにハードコードしません。

```mathematica
SourceVault`SourceVaultSetOwnerLLMProfile[
  "○○大学 ○○学科 ○○。専門: ○○, ○○"];          (* 所属・役職・専門分野 *)
SourceVault`SourceVaultSetOwnerPrimaryEmail["you@example.org"];

(* GUI で編集する場合（#1 を開いて 表示名/種別/グループ/重み/主メール/LLMProfile を編集） *)
SourceVault`SourceVaultEntityEditUI[1]
```

複数の自分アドレス（職場・個人など）がある場合は、`SourceVaultIdentityLinkUI[]` で各識別子をオーナー #1 にマージしておくと、ReplyAll の自分除外がすべてのアドレスに効きます。

### 4. ローカル LLM（LM Studio）の登録

機密メール（PrivacyLevel > 0.5）はローカル LLM で処理します。LM Studio のサーバを登録し、`$ClaudePrivateModel` を設定します。

```mathematica
NBAccess`NBRegisterTrustedLocalServer[<|
   "MachineName" -> "my-pc", "Subnet" -> "192.168.x",
   "Provider" -> "lmstudio", "URL" -> "http://192.168.x.x:1234"|>];

ClaudeCode`$ClaudePrivateModel = {"lmstudio", "your-local-model", "http://127.0.0.1:1234"};
```

### 5. IMAP アカウントの登録

まず IMAP パスワードを **SystemCredential に手動で**設定し（`CredKey` がその名前）、次にアカウント設定を登録します。登録は `PrivateVault/config/mailaccounts.jsonl` に永続化され、パスワード本体は保存されません。

```mathematica
(* パスワードを SystemCredential に設定（手動実行。値は公開しない） *)
SystemCredential["WORK_IMAP_PASSWORD"] = "○○○○";

(* アカウント設定を登録（mbox ごとに。CredKey は上の名前） *)
SourceVault`SourceVaultRegisterMailAccount[<|
   "MBox" -> "work", "User" -> "you@example.org", "Email" -> "you@example.org",
   "CredKey" -> "WORK_IMAP_PASSWORD", "Server" -> "imap.example.org", "Port" -> 993|>];

SourceVault`SourceVaultMailAccounts[]                 (* 登録確認（パスワードは含まれない） *)
```

### 6. メールサブシステムの読み込みと受信

メールサブシステム（旧 maildb キーワードの後継）の各操作関数は、必要時に遅延ロードされます。アカウント登録後、以下の関数で受信・閲覧・検索・返信を行います。

```mathematica
(* メールサブシステムを明示的にロード（初回のみ。各 Mail 関数も内部で自動ロード） *)
SourceVault`SourceVaultMailEnsureLoaded[];

(* IMAP から新着メールを取得して PrivateVault に snapshot 保存 *)
SourceVault`SourceVaultMailFetchNew["work"];

(* 受信メールを一覧表示（GUI ビュー） *)
SourceVault`SourceVaultMailView[];

(* メールを Dataset として取得（プログラム処理用） *)
SourceVault`SourceVaultMailDataset[];

(* 保存済みメール snapshot を検索 *)
SourceVault`SourceVaultSearchMailSnapshots["検索語"];

(* メールの派生情報（優先度・概要など）を一括推定 *)
SourceVault`SourceVaultInferMailDerivedBatch[];

(* 指定メールへの返信ドラフトを作成（自分除外の ReplyAll に対応） *)
SourceVault`SourceVaultMailComposeReply[mailRef];
```

> `SourceVaultMailComposeReply` は、オーナー #1 のプライマリメール・LLMProfile（手順 3）と派生情報（`SourceVaultInferMailDerivedBatch`）を利用します。返信ノートブックは `$SourceVaultMailNotebookStyle` のスタイルで開きます。

### 7. 重要度のグループ重みの設定（任意）

メールの重要度は「送信者のグループ重み ＋ To/Cc 位置 ＋ ML 判定 ＋ LLM 依頼度」で計算されます。自分の分類に合わせてグループ重みを定義します（実体の `Group` がこれに解決されます）。

```mathematica
SourceVault`SourceVaultSetPriorityGroupWeight["共同研究者", 0.85];
SourceVault`SourceVaultSetPriorityGroupWeight["学生", 0.6];
SourceVault`SourceVaultSetPriorityGroupWeight["事務", 0.5];
SourceVault`SourceVaultSetPriorityGroupWeight["業者", 0.2];
SourceVault`SourceVaultPriorityGroupWeights[]
```

各送信者の実体に `Group`（上記名）や個別 `PriorityWeight` を設定するには `SourceVaultEntityView[]` の各行の編集ボタン、または送信者を実体にまとめる `SourceVaultIdentityLinkUI[]` を使います。

### 8. スタイルシートの配置

上記「ノートブック用スタイルシートとテンプレートの配置」に従い、`SourceVault default.nb` をスタイルシートディレクトリに配置しておくと、メール本文表示・返信ノートブックがこのスタイルで開きます（`$SourceVaultMailNotebookStyle` で変更可）。

### 起動ファイルへのまとめ方

上記 1〜8 のうち、私的設定（メールアカウント・パスワード・氏名・所属・ローカルサーバ）を含む部分は、**各自のローカル起動ファイル**（例: `$UserBaseDirectory/Kernel/init.m`、または個人用の起動ノートブック）にまとめておくと、起動のたびに自動で設定されます。**このファイルは GitHub などに公開しないでください。** `RegisterMailAccount` / グループ重み / オーナープロフィールは一度実行すれば vault config に永続化されるため、2 回目以降は backend 設定とパッケージロード、`IdentityInitialize`、パスワードの `SystemCredential` 設定だけで動きます。

---

## SearXNG + MCP Web 検索ゲートウェイのセットアップ（任意）

LM Studio などのローカル LLM の Web 検索を、外部 API (Exa 等) ではなく **ローカル SearXNG → SourceVault → MCP** ゲートウェイ経由にする構成です。検索が SourceVault に監査記録され（誰が・いつ・何を検索したか、結果 URL、取得本文）、importance / 構造 Priority / クロスマシン集約と連携します。この節は任意で、使わない場合はスキップして構いません。

実装は `SourceVault_webingest.wl`（SearXNG クライアント・本文取得・job・参照イベント・importance・要約）と `SourceVault_mcp.wl`（MCP tool schema / dispatch）に分かれ、`SourceVault.wl` ロード時に自動で読み込まれます。

### 1. SearXNG のインストール

[SearXNG](https://docs.searxng.org/) をローカル（`127.0.0.1`）に立てます。Docker が手軽です。

```bash
# searxng-docker (推奨): https://github.com/searxng/searxng-docker
git clone https://github.com/searxng/searxng-docker.git
cd searxng-docker
# .env で SEARXNG_HOSTNAME=localhost、ポートを 8888 に調整
docker compose up -d
```

`searxng/settings.yml` で **JSON API を有効化**します（SourceVault は JSON 形式を使うため必須）。

```yaml
search:
  formats:
    - html
    - json          # ← これが無いと SourceVault からの検索が 403 になる
server:
  bind_address: "127.0.0.1"
  port: 8888
  secret_key: "<ランダムな秘密鍵>"
  limiter: false    # ローカル単独利用ならボット検出を緩める
```

> SearXNG が `403` / 空結果を返す場合は、`search.formats` に `json` が含まれているか、`limiter` / `botdetection` がローカルアクセスをブロックしていないかを確認してください（`SourceVaultSearXNGSearch` のエラーメッセージにもこのヒントが出ます）。

### 2. エンドポイント設定と可用確認

既定エンドポイントは `http://127.0.0.1:8888` です。別ポートなら設定します。

```mathematica
(* 既定と違う場合のみ *)
SourceVault`$SourceVaultSearXNGEndpoint = "http://127.0.0.1:8888";

(* 到達可能か確認（60 秒キャッシュ） *)
SourceVault`SourceVaultSearXNGAvailableQ[]          (* True なら OK *)

(* 直接検索してみる *)
SourceVault`SourceVaultWebSearch["Wolfram Language", "MaxResults" -> 5]
```

### 3. MCP サーバの起動

MCP サーバは **WL service（カーネル）＋ HTTP/MCP proxy（Python）** の二段構成で、`SourceVaultStartMCP[]` が一括起動します。`/sv/mcp` を公開します。

```mathematica
SourceVault`SourceVaultStartMCP[]                   (* service + proxy を起動 *)
SourceVault`SourceVaultMCPStatus[]                  (* <|Running, Port, Url, ...|> *)
SourceVault`SourceVaultMCPRunningQ[]                (* True / False *)
```

- 既定 serviceId は `$SourceVaultMCPServiceId`（既定 `"sourcevault"`）。
- ポート・トークンは `$SourceVaultMCPPort` / `$SourceVaultMCPToken`（既定 `Automatic` = 既存 `proxy.config.json` から解決、無ければ 8731 / 認証なし）。明示するなら `SourceVaultStartMCP["Port" -> 9700, "MCPToken" -> "○○○"]`。
- 既定は `127.0.0.1` バインドの localhost 限定。トークン未設定なら認証なし（localhost のみ）。
- **`.wl` を更新したら稼働中サービスには反映されません。** `SourceVaultRestartService["sourcevault"]`（または `SourceVaultStopMCP[]` → `SourceVaultStartMCP[]`）で再起動します。

`ShowClaudePalette[]`（claudecode）のプライバシー直下にも **MCP 起動/停止トグル**が出ます（SourceVault がロードされている場合）。ラベルは実状態に追従します。

停止は:

```mathematica
SourceVault`SourceVaultStopMCP[]                    (* proxy + service を停止 *)
```

### 4. LM Studio の mcp.json 設定

LM Studio の MCP 設定（`mcp.json`、LM Studio の「Program」→ Edit mcp.json から編集）に、SourceVault を **remote MCP（URL）** として登録します。`SourceVaultMCPStatus[]` が返す `Url` をそのまま使います。

```json
{
  "mcpServers": {
    "sourcevault": {
      "url": "http://127.0.0.1:8731/sv/mcp"
    }
  }
}
```

トークンを設定した場合は `headers` を追加します。

```json
{
  "mcpServers": {
    "sourcevault": {
      "url": "http://127.0.0.1:8731/sv/mcp",
      "headers": { "X-SourceVault-Token": "○○○" }
    }
  }
}
```

ポートは実際の公開ポート（既定解決なら 8731、`proxy.config.json` に既存値があればそれ）に合わせてください。LM Studio はこの MCP が提供する `sourcevault_web_search` / `sourcevault_submit_web_search` / `sourcevault_job_status` / `sourcevault_job_result` / `sourcevault_get_document` ツールを使って検索・本文取得を行います。

### 5. 要約トークンの保存（任意・サービス側要約を使う場合）

サービスカーネルは NBAccess を持たないため、LM Studio の API トークンを LocalState/secrets に永続化しておくと、サービス側からも要約 LLM を解決できます（トークン本体は戻り値・ログに出ません）。

```mathematica
SourceVault`SourceVaultStoreSummaryToken[]          (* main kernel でトークンを解決→保存 *)
```

### 6. exa への後方互換フォールバック（SearXNG が無い環境）

SearXNG が使えない環境では、claudecode を変更せずに Web 検索バックエンドを exa に戻せます（`SourceVaultModelIntegrations` 経由）。

```mathematica
(* SearXNG 可用なら mcp/sourcevault、不可なら mcp/exa を返す *)
SourceVault`SourceVaultWebSearchIntegration[]

(* 全 ClaudeEval に自動切替を適用したい場合 *)
ClaudeCode`$ClaudeLMStudioIntegrations := SourceVault`SourceVaultWebSearchIntegration[];
```

### 7. 動作確認

```mathematica
(* SearXNG 経由で検索 → 監査記録を確認 *)
SourceVault`SourceVaultWebSearch["arxiv transformer", "FetchPages" -> True, "MaxFetch" -> 3];
SourceVault`SourceVaultWebSearchRunList[]            (* WebSearchRun の監査記録が増える *)
```

詳しい使い方（importance / 構造 Priority / 参照イベント rollup / 要約 DerivedArtifact / MCP ツール）は user_manual.md の「Web 検索 / SearXNG / MCP ゲートウェイ」を参照してください。

---

## 動作確認

### バージョン確認

```mathematica
$SourceVaultVersion
(* 出力例: "2026-05-19-stage-9-p1-step8-nbreadheader-boxdata-filter" *)
```

### 最小動作テスト（テキストソース）

LLM や notebook がなくても、テキストファイルの ingest だけで動作確認できます。

```mathematica
(* 1. ダミーのテキストファイルを作成 *)
testPath = FileNameJoin[{$TemporaryDirectory, "sv-test.txt"}];
Export[testPath, "これは SourceVault の動作確認用メモです。", "Text"];

(* 2. ingest *)
result = SourceVaultIngest[testPath];
result["SnapshotId"]
(* "snap-sha256-..." が返れば成功 *)

(* 3. context 抽出 *)
SourceVaultContext[result["SnapshotId"], {1, 100}]
```

### Notebook ソースの動作確認

任意の `.nb` ファイルを first-class source として登録できます。

```mathematica
(* 1. notebook を index *)
nbPath = "C:\\path\\to\\your\\notebook.nb";
SourceVaultIndexNotebook[nbPath]
(* → <|"Status" -> "OK", "TodoCount" -> _, "OpenTodoCount" -> _, ...|> *)

(* 2. Header を読む *)
NBReadHeader[nbPath]
(* → <|"Status" -> "OK", "Keywords" -> {...}, "Source" -> "BoxData", ...|> *)

(* 3. Todo を読む *)
NBReadTodos[nbPath]
```

### ソース一覧・横断検索の動作確認（SourceVaultSources / SourceVaultSummaries）

登録済みのすべてのソースを一覧表示する `SourceVaultSources` と、Eagle 保存済みサマリー等の登録プロバイダ横断で検索・統合表示する `SourceVaultSummaries` が利用できます。arXiv 論文ソースについては、タイトル・著者・出版日が arXiv API（export.arxiv.org）から自動取得され、メタデータとしてキャッシュされます。

```mathematica
(* 登録済みソースの一覧を Grid で表示 *)
SourceVaultSources[]

(* 登録プロバイダ横断でサマリー等を検索し統合表で表示 *)
SourceVaultSummaries["検索語",
  "FetchMetadata" -> Automatic,   (* Automatic: 未取得のみ取得 | False: ネットワーク不使用 | True: 強制再取得 *)
  "Format" -> "Grid"              (* "Grid"（既定）| "Dataset" | "Rows" *)
]
```

`SourceVaultSummaries` の主なオプション:

| オプション | 既定値 | 説明 |
|-----------|--------|------|
| `"FetchMetadata"` | `Automatic` | `Automatic`: 未取得のみ取得 / `False`: ネットワーク不使用 / `True`: 強制再取得 |
| `"Format"` | `"Grid"` | `"Grid"`: テーブル表示 / `"Dataset"`: Dataset として返す / `"Rows"`: 行リスト |

タイトルをクリックすると、そのソースの全メタ情報が別ウインドウで表示されます。

### メールサブシステムの動作確認（IMAP アカウント登録済みが前提）

「初回セットアップ」の手順 1〜5 を済ませてある場合、メールの取得・閲覧を確認できます。

```mathematica
(* 1. メールサブシステムをロード *)
SourceVault`SourceVaultMailEnsureLoaded[]
(* → <|"Status" -> "OK", ...|> *)

(* 2. 新着メールを取得 *)
SourceVault`SourceVaultMailFetchNew["work"]

(* 3. 受信メールを一覧表示 *)
SourceVault`SourceVaultMailView[]
```

### LLM 要約の動作確認（ClaudeRuntime 必須）

```mathematica
SourceVaultNotebookSummary[nbPath]
(* → <|"Status" -> "OK", "Summary" -> "...", "Source" -> "LLM"|> *)
```

---

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| `Needs` でパッケージが見つからない | `$Path` に `$packageDirectory` が含まれているか確認 |
| 文字化けが発生する | `Block[{$CharacterEncoding = "UTF-8"}, ...]` でロードしているか確認 |
| `SourceVaultIngest` が `iSanitizeForJSON` で失敗する | 入力に `Missing[]` や `DateObject[]` が含まれている可能性。`iSanitizeForJSON` 経由になっているか確認 |
| `SourceVaultIndexNotebook` の戻り値の `CellCount` が 0 | 罠 #26 (CellGroupData ネスト) に該当。SourceVault のバージョンが `step8-cellcount-fix` 以降か確認 |
| `NBReadHeader` の `Source` が `"None"` になる | TodoItem cell の TaggingRules を Header と誤認していないか。`step8-nbreadheader-boxdata-filter` 以降では `iNBIsHeaderLikeAssoc` フィルタで解決済み |
| `iLoadJSONFromFile` が `Null` を返す | 罠 #28 (`ImportString[..., "RawJSON"]` が Windows path のバックスラッシュで失敗)。3 段階 fallback を使う実装か確認 |
| `SourceVaultNotebookSummary` が失敗する | ClaudeRuntime がロードされているか、API キーまたはローカル LLM が利用可能か確認 |
| `SourceVaultMailFetchNew` が失敗する | IMAP アカウント (`SourceVaultRegisterMailAccount`) と `SystemCredential[CredKey]` のパスワードが設定済みか、`$NBCredentialBackend = "SystemCredential"` でロードしているか確認 |
| `ReadList` が空配列を返す | 罠 #20 (Windows JSONL/UTF-8)。`ReadByteArray` + `ByteArrayToString` + `StringSplit` 経路を使うこと |
| パッケージロード時に `Syntax::stresc` が大量に出る | 罠 #11 (`\uXXXX` エスケープ混入)。`\:XXXX` に書き直す必要あり |
| `$SourceVaultDefaultNotebookFolder` が正しいフォルダを返さない | `Global`$onWork` が未定義で `$packageDirectory` にフォールバックしていないか確認。絶対パスを直接代入することで固定できます |
| `SourceVaultSummaries` が arXiv メタデータを取得しない | ネットワーク接続を確認するか、`"FetchMetadata" -> True` を明示して強制再取得してください |
| `SourceVaultWebSearch` / `SourceVaultSearXNGAvailableQ` が失敗・空を返す | SearXNG が `127.0.0.1:8888`（`$SourceVaultSearXNGEndpoint`）で稼働しているか、`settings.yml` の `search.formats` に `json` が含まれるか、`limiter`/`botdetection` がローカルアクセスをブロックしていないか確認 |
| MCP トグル/検索を変更したのに反映されない | detached service は起動時コードを保持。`SourceVaultRestartService["sourcevault"]`（または `SourceVaultStopMCP[]`→`SourceVaultStartMCP[]`）で再起動する |
| LM Studio から `/sv/mcp` が `401` | `mcp.json` の `headers` の `X-SourceVault-Token` が `$SourceVaultMCPToken`（または `proxy.config.json` の値）と一致しているか確認。トークン未設定なら `headers` は不要 |
| `SourceVaultStartHTTPProxy` が `Pending` を返す | Python（`$SourceVaultPython`）が解決できているか、ポートが他プロセスと衝突していないか確認 |

---

## 関連リンク

- [SourceVault リポジトリ](https://github.com/transreal/SourceVault)
- [SearXNG](https://docs.searxng.org/) / [searxng-docker](https://github.com/searxng/searxng-docker) — ローカル Web 検索メタサーチ（MCP ゲートウェイのバックエンド）
- [NBAccess](https://github.com/transreal/NBAccess)
- [claudecode](https://github.com/transreal/claudecode)
- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime)
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)
- [github](https://github.com/transreal/github)