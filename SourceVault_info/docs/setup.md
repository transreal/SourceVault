---

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

- `SourceVault_core.wl` — コア基盤（排他制御・不変 snapshot・event log・blob・pointer）
- `SourceVault_contracts.wl` — サブシステム間のコントラクト（型・不変条件）定義
- `SourceVault_wiring.wl` — サブシステム間の配線・初期化
- `SourceVault_simrun.wl` — シミュレーション実行との連携
- `SourceVault_searchindex.wl` — 検索インデックス・公開ポリシー
- `SourceVault_searchview.wl` — 検索結果ビュー
- `SourceVault_knowledgehome.wl` — ナレッジホーム（登録済み知識の集約・ホーム表示）
- `SourceVault_cognition.wl` — 認知レイヤー（cognition）処理
- `SourceVault_adjudication.wl` — 裁定・判定（adjudication）処理
- `SourceVault_capbroker.wl` — Capability broker（機能可用性の仲介。境界観測の自動適用などが参照する）
- `SourceVault_taint.wl` — taint 追跡（機密度・伝播管理）
- `SourceVault_anomaly.wl` — 異常検知（anomaly detection）
- `SourceVault_routine.wl` — ルーティン管理
- `SourceVault_routineplan.wl` — ルーティン計画（routine plan）
- `SourceVault_mailagenda.wl` — メールアジェンダ（オーナー宛ての要対応メールを routine アジェンダへ供給する薄い層。maildb の既存派生 (Summary/Category/Priority/Deadline) を索引だけで読み、LLM/IMAP/シャード本体はロードしない。routineplan の日別カレンダー・「✉ 要対応メール」バンドに統合される）
- `SourceVault_servicemanager.wl` — サービス管理・Python proxy・headless dispatch
- `SourceVault_webingest.wl` — SearXNG クライアント・Web 検索・本文取得
- `SourceVault_mcp.wl` — MCP tool schema / dispatch ＋ sv:// オブジェクト解決
- `SourceVault_llmlog.wl` — Claude Code セッションログの取り込み・検索・共有（llmlog）
- `SourceVault_workflowregistry.wl` — コード化ワークフローのオンデマンドローダ
- `SourceVault_autotrigger.wl` — 自動トリガスケジューラ（対話 FE カーネルで自動起動）
- `SourceVault_promptrouter.wl` — PromptRouter 拡張

リポジトリに同梱されている場合は同時に取得されます。別ファイルとして配布されている場合は、同じ要領で `$packageDirectory` へ配置してください。暗号化・メールを使う場合は `SourceVault_crypto.wl` / `SourceVault_identity.wl` / `SourceVault_maildb.wl` / `SourceVault_mailstructure.wl` / `SourceVault_mailsuggest.wl` も、Eagle 統合を使う場合は `SourceVault_eagle.wl`（手動ロード）も同様に配置します（メール系サブファイルは各 Mail 関数の初回呼び出し時にオンデマンドで読み込まれます）。

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
  SourceVault_core.wl            ← コア基盤（本体ロード時に自動ロード）
  SourceVault_contracts.wl       ← コントラクト定義（本体ロード時に自動ロード）
  SourceVault_wiring.wl          ← 配線・初期化（本体ロード時に自動ロード）
  SourceVault_simrun.wl          ← シミュレーション実行連携（本体ロード時に自動ロード）
  SourceVault_searchindex.wl     ← 検索インデックス（本体ロード時に自動ロード）
  SourceVault_searchview.wl      ← 検索結果ビュー（本体ロード時に自動ロード）
  SourceVault_knowledgehome.wl   ← ナレッジホーム（本体ロード時に自動ロード）
  SourceVault_cognition.wl       ← 認知レイヤー（本体ロード時に自動ロード）
  SourceVault_adjudication.wl    ← 裁定・判定（本体ロード時に自動ロード）
  SourceVault_capbroker.wl       ← Capability broker（本体ロード時に自動ロード）
  SourceVault_taint.wl           ← taint 追跡（本体ロード時に自動ロード）
  SourceVault_anomaly.wl         ← 異常検知（本体ロード時に自動ロード）
  SourceVault_routine.wl         ← ルーティン管理（本体ロード時に自動ロード）
  SourceVault_routineplan.wl     ← ルーティン計画（本体ロード時に自動ロード）
  SourceVault_mailagenda.wl      ← メールアジェンダ（本体ロード時に自動ロード）
  SourceVault_servicemanager.wl  ← サービス管理・headless dispatch（本体ロード時に自動ロード）
  SourceVault_webingest.wl       ← SearXNG/Web 検索（本体ロード時に自動ロード）
  SourceVault_mcp.wl             ← MCP + sv:// オブジェクト解決（本体ロード時に自動ロード）
  SourceVault_llmlog.wl          ← Claude Code セッションログ（本体ロード時に自動ロード）
  SourceVault_workflowregistry.wl ← ワークフローレジストリ（本体ロード時に自動ロード）
  SourceVault_autotrigger.wl     ← 自動トリガスケジューラ（本体ロード時に自動ロード）
  SourceVault_promptrouter.wl    ← PromptRouter 拡張
  NBAccess.wl
  claudecode.wl
  ...
```

> サブフォルダには配置しないでください（コード化ワークフローを置く `SourceVault_workflows/` のみ例外で、これは本体が自動で解決します）。
>
> 上記の `SourceVault_*.wl` はいずれも `SourceVault.wl` のロード時に同じディレクトリから自動的に読み込まれます（旧 `SourceVault_objectview.wl` は `mcp`/`eagle` に統合され廃止）。メール系サブファイル（`SourceVault_maildb.wl` / `SourceVault_mailstructure.wl` / `SourceVault_mailsuggest.wl` など）は、メール関数の初回呼び出し時にオンデマンドでロードされます。

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

- 既定値は `Automatic` で、`Global`$onWork`` に解決し、未定義の場合は `$packageDirectory` にフォールバックします。
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

## 自動トリガスケジューラの自動起動（対話 FE カーネルのみ）

SourceVault は、他 PC からの依頼を含むジョブ（llmlog・docs・MCP など各種タスク）を自動的に拾い上げてトリガする **自動トリガスケジューラ** を備えています。`SourceVault_autotrigger.wl` は本体ロード時に自動的に読み込まれ、SourceVault の (再)ロード時にスケジューラが自動起動します。

- スケジューラは **1 マシンにつき 1 か所だけ**で動く必要があるため、自動起動は**対話フロントエンド（FE）のメインカーネル（`$FrontEnd =!= Null`）に限定**されます。headless カーネル（`$FrontEnd === Null`。並列サブカーネルの親・SourceVault サービスカーネル・MCP ゲートウェイカーネル・外部ジョブの wolframscript プロセス等）では起動しません。各 headless カーネルがそれぞれスケジューラを立ち上げると、Wolfram ライセンス席の浪費とディスパッチの多重化を招くためです。
- 冪等です。すでに起動済みの場合は同じ tick を再登録するだけの no-op として振る舞います。スケジューラは claudecode の共有ポーリング tick に相乗りします（claudecode がまだロードされていない場合、`SourceVaultAutoTriggerStartScheduler` は `ClaudeCodeAbsent` を返す安価な no-op となり、次回 SourceVault (再)ロード時に自動起動します）。
- 自動起動の結果は `SourceVault`Private`$iSVAutoTriggerSchedulerAutoStartResult` に記録されます。`Status` は次のいずれかです。
  - スケジューラを起動した（`Started` 等）
  - `Skipped`（`Reason`: `AutoTriggerUnavailable` / `DisabledByUser` / `NotFrontEndKernel`）
  - `Failed`（`Reason`: `AutoStartException`）

自動起動を無効にしたい場合は、SourceVault ロード前に次を設定します（例: このマシンではスケジューラを動かしたくない場合）。

```mathematica
SourceVault`Private`$iSVDisableAutoTriggerScheduler = True;
```

スケジューラを手動で起動したい場合は次を使います（冪等）。

```mathematica
SourceVault`SourceVaultAutoTriggerStartScheduler[]
```

### FE レス compute ノードでの headless dispatch（任意）

対話 FE を一切持たない compute 専用ノード（例: GPU 演算専用機など）は、上記の自動起動スケジューラの対象外です（`$FrontEnd === Null` のため `NotFrontEndKernel` として自動的に skip されます）。このようなマシンでもジョブ dispatch だけを拾わせたい場合は、`SourceVault_servicemanager.wl` が提供する **headless dispatch モード**（スケジューラ本体ではなく dispatch のみを行う軽量モード）をマシンごとに opt-in できます。

```mathematica
SourceVault`SourceVaultEnableHeadlessDispatch[]
```

- 既定は無効（opt-in）です。対話 FE 側のスケジューラ（1 マシン 1 か所）とは役割が異なり、こちらは dispatch 専用でスケジューラ自体は起動しません。
- 同一マシンで対話 FE のスケジューラと headless dispatch が同時に存在しても、スロット単位の atomic dispatch claim（内部的に `SourceVaultAutoTriggerDispatchCatalogRuns` が二重実行を防止）により、同じジョブが二重にディスパッチされることはありません。

---

## 境界観測 (Boundary Observation) の自動適用（任意）

SourceVault は、LLM 呼び出しの境界を監視する **境界観測 (Boundary Observation)** の設定（LLM boundary shadow / 1G ClaudeEval shadow recorder 等の観測記録）を持ちます。オーナーが `SourceVaultSetBoundaryObservation` で設定を一度永続化しておくと、以降は SourceVault の (再)ロードのたびに `SourceVaultApplyBoundaryObservation[]` が内部的に呼ばれ、**全カーネル（対話 FE / service / headless）** へ自動的に適用されます。

- 観測のみ (observe-only) の設定であれば挙動は変わりません。設定が無ければ `NoConfig` として何もしない no-op です。
- enforce 系の設定（Mode / EnforceList）はロード時の自動適用では反映されません。安全のため、enforce はセッション内でオーナーが明示的に設定した場合のみ有効になります。
- capbroker（`SourceVault_capbroker.wl` が提供する capability broker）が利用できない環境では、境界観測の自動適用は `CapBrokerUnavailable` として fail-open します（適用せず既存動作を継続）。
- 適用結果は `SourceVault`Private`$iSVBoundaryObsApplyResult` に記録されます。`Status` は次のいずれかです。
  - `OK`（適用成功）
  - `Skipped`（`Reason`: `CapBrokerUnavailable`）
  - `Failed`（`Reason`: `ApplyException`。または、要約 LLM 呼び出し等（例: `sourcevault:iCallSummaryLLM`）が境界観測の self-gate によって拒否された場合は `LLMBoundaryRefused`）

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

実装は `SourceVault_webingest.wl`（SearXNG クライアント・本文取得・job・参照イベント・importance・要約）と `SourceVault_mcp.wl`（MCP tool schema / dispatch）に分かれ、`SourceVault.wl` ロード時に自動で読み込まれます。MCP の HTTP/JSON-RPC endpoint 自体は `SourceVault_servicemanager.wl` が起動する Python proxy 側にあります。

### 構成（どこで何が動くか）

このゲートウェイは **Mathematica 単体では完結せず**、複数のコンポーネントが連携します。下表の順に設定します。

| コンポーネント | 役割 | 動かす場所 | 設定する場所 |
|---|---|---|---|
| **SearXNG** | メタ検索エンジン | Docker コンテナ（`127.0.0.1:8888`） | `settings.yml`（手順 1） |
| **WL service kernel** | MCP dispatch（検索・本文取得の実体） | headless wolframscript（`SourceVaultStartMCP[]` が起動） | Mathematica（手順 2〜3） |
| **Python proxy** | `POST /sv/mcp` の HTTP/JSON-RPC endpoint | `SourceVaultStartMCP[]` が同時起動（`127.0.0.1:8731`） | 自動（手順 3） |
| **MCP クライアント** | Claude Code / Codex / LM Studio | 各クライアント | `claude mcp add` / `config.toml` / `mcp.json`（手順 4） |

```text
Claude Code / Codex / LM Studio
        |  remote MCP over HTTP (POST /sv/mcp, JSON-RPC)
        v
Python proxy (127.0.0.1:8731) --file command queue--> WL service kernel
                                                          | SourceVaultMCPDispatch
                                                          v
                                                 SourceVaultWebSearch / WebFetch
                                                          |
                                                          v
                                                 SearXNG (127.0.0.1:8888)
```

要するに **(手順 1) Docker で SearXNG を立てる → (手順 2) Mathematica から到達確認 → (手順 3) `SourceVaultStartMCP[]` で WL service + Python proxy を起動 → (手順 4) 各 MCP クライアント（Claude Code / Codex / LM Studio）を `/sv/mcp` に向ける → (手順 7) 動作確認** という流れです。Python proxy の実行には Python（`$SourceVaultPython`）が必要です。

### 1. SearXNG のインストール（Docker）

SourceVault が必要とするのは **ローカルの SearXNG JSON API** だけです。Caddy や公開ホスト名は不要なので、**SearXNG 単体コンテナ**を立てるのが最も簡単・確実です（Windows でも host networking の問題を避けられます）。

> ⚠️ 旧来の `searxng-docker` リポジトリ（`git clone .../searxng-docker`）は **deprecated** になり、`master` から compose ファイルが削除されました。clone しても `docker-compose.yaml` が無く、`docker compose up -d` が `no configuration file provided: not found` になります。下記の単体構成を使ってください。

任意の作業フォルダ（例 `searxng-local`）に次の 2 ファイルを置きます。

`docker-compose.yaml`:

```yaml
services:
  searxng:
    image: docker.io/searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "127.0.0.1:8888:8080"        # ホスト 8888 → コンテナ 8080。SourceVault 既定が 8888
    volumes:
      - ./searxng:/etc/searxng:rw
    environment:
      - SEARXNG_BASE_URL=http://localhost:8888/
```

`searxng/settings.yml`（**JSON API を有効化**。SourceVault は JSON 形式を使うため必須）:

```yaml
use_default_settings: true
server:
  secret_key: "<ランダムな秘密鍵に置換>"
  limiter: false        # ローカル単独利用ならボット検出を緩める
  image_proxy: false
search:
  formats:
    - html
    - json              # ← これが無いと SourceVault からの検索が 403 になる
```

起動して JSON API の応答を確認します。

```bash
docker compose up -d
curl "http://127.0.0.1:8888/search?q=test&format=json"   # JSON が返れば OK
```

> `settings.yml` を編集したら `docker compose restart` で反映します。SearXNG が `403` / 空結果を返す場合は、`search.formats` に `json` が含まれているか、`limiter`/`botdetection` がローカルアクセスをブロックしていないかを確認してください（`SourceVaultSearXNGSearch` のエラーメッセージにもヒントが出ます）。
>
> 公式の新しい導入手順（compose instancing）は [SearXNG ドキュメント](https://docs.searxng.org/admin/installation-docker.html) を参照。どうしても旧 `searxng-docker` の compose を使いたい場合は deprecated 直前の commit を checkout します（`git checkout 0c7875a`）。ただし既定では SearXNG が `127.0.0.1:8080` 公開・Caddy 同梱なので、`$SourceVaultSearXNGEndpoint` を `:8080` にするか、`docker-compose.yaml` の `searxng` のポートを `127.0.0.1:8888:8080` に変更してください。

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
- ポート・トークンは `$SourceVaultMCPPort` / `$SourceVaultMCPToken`（既定 `Automatic` = 既存 `proxy.config.json` から解決、無ければ **8731** / 認証なし）。明示するなら `SourceVaultStartMCP["Port" -> 8731, "MCPToken" -> "○○○"]`。
  - **正規ポートは 8731 です。** 全クライアント（Claude Code / Codex / LM Studio）の登録 URL を 8731 に揃えてください。過去に `9700` を使っていた設定が残っていると `ECONNREFUSED` になります（`9700` は旧テスト用 serviceId の名残で、現行 `sourcevault` サービスでは使いません）。
- 既定は `127.0.0.1` バインドの localhost 限定。トークン未設定なら認証なし（localhost のみ）。
- **`.wl` を更新したら稼働中サービスには反映されません。** `SourceVaultRestartService["sourcevault"]`（または `SourceVaultStopMCP[]` → `SourceVaultStartMCP[]`）で再起動します。

`ShowClaudePalette[]`（claudecode）のプライバシー直下にも **MCP 起動/停止トグル**が出ます（SourceVault がロードされている場合）。ラベルは実状態に追従します。

> **ボタンの状態判定について（2026-06）**: パレットの「実行中／停止中」は `SourceVaultMCPRunningQ[]` に追従し、これは単に proxy ポートが listen しているかではなく **`/health` の `healthState=="OK"`（背後の WL サービスカーネルが心拍を打っているか）** で判定します。これにより「proxy だけ生きていてサービスカーネルが死んでいる」状態を「実行中」と誤表示しません（誤表示するとトグルが逆に Stop してしまうため）。

#### ログオン時の自動起動（任意・推奨）

毎回 Mathematica を開いてトグルを押す手間を省き、再起動後も自動で MCP を上げるには、**Startup フォルダ**（`shell:startup`）に proxy と service の hidden ランチャへのショートカットを置きます。各ランチャは `SourceVaultStartMCP[]` が生成済みの `runtime\<machine>\{proxies,services}\sourcevault\launch_hidden.vbs` です（一度 `SourceVaultStartMCP[]` を実行して生成しておくこと）。

```powershell
$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell
foreach($p in @(
    @("SourceVaultProxy.lnk",   "...\runtime\<machine>\proxies\sourcevault\launch_hidden.vbs"),
    @("SourceVaultService.lnk", "...\runtime\<machine>\services\sourcevault\launch_hidden.vbs"))){
  $lnk = $ws.CreateShortcut((Join-Path $startup $p[0]))
  $lnk.TargetPath = "C:\Windows\System32\wscript.exe"
  $lnk.Arguments  = ('//B //Nologo "{0}"' -f $p[1]); $lnk.WindowStyle = 7; $lnk.Save()
}
```

proxy（Python）と service（WL カーネル）はファイルコマンドキュー連携で起動順に依存しないため、両方を独立に Startup 起動して構いません。service は launch_hidden.vbs が生成済み `run.wls`（注入 root/hash 入り）を使うため、root 構成が安定している限りそのまま動きます。**サービスカーネルは Wolfram ライセンスの同時メインカーネル席を 1 つ使います**（席が枯渇していると `unregistered` で即死します。次の「ライセンス席」の項を参照）。

停止は:

```mathematica
SourceVault`SourceVaultStopMCP[]                    (* proxy + service を停止 *)
```

### 4. MCP クライアントの登録（Claude Code / Codex / LM Studio）

`SourceVaultMCPStatus[]` が返す `Url`（既定 `http://127.0.0.1:8731/sv/mcp`、`proxy.config.json` に既存値があればそれ）を、各クライアントに **remote MCP（streamable HTTP）** として登録します。トークンを設定した場合のみヘッダ `X-SourceVault-Token` を付けます（未設定なら localhost 限定で認証なし）。提供ツールは `sourcevault_web_search` / `sourcevault_submit_web_search` / `sourcevault_job_status` / `sourcevault_job_result` / `sourcevault_get_document` の 5 つです。

> いずれのクライアントも、登録前に手順 3 で MCP サーバが起動済みである必要があります（`SourceVaultMCPRunningQ[]` が `True`）。ポートは必ず `SourceVaultMCPStatus[]` の `Url` に合わせてください。

#### 4-a. Claude Code

CLI で追加します（`--transport` / `--header` / `--scope` はサーバ名より前に置きます）。

```bash
# 全プロジェクトで使う (user スコープ)
claude mcp add --transport http --scope user sourcevault http://127.0.0.1:8731/sv/mcp

# トークンを設定している場合
claude mcp add --transport http --scope user sourcevault http://127.0.0.1:8731/sv/mcp \
  --header "X-SourceVault-Token: <token>"
```

プロジェクト単位で共有するなら `--scope project`（リポジトリ直下の `.mcp.json` に書かれ、git に commit できます）。

**検証:**

```bash
claude mcp list            # sourcevault が ✓ Connected と表示されれば OK
claude mcp get sourcevault # URL / 状態の詳細
```

Claude Code セッション内では `/mcp` でも接続状態とツール一覧を確認できます。

#### 4-b. Codex（OpenAI Codex CLI）

`~/.codex/config.toml`（プロジェクト限定なら `.codex/config.toml`）に streamable HTTP サーバとして追記します。`url` があると HTTP サーバとして扱われます。

```toml
[mcp_servers.sourcevault]
url = "http://127.0.0.1:8731/sv/mcp"
# トークンを設定している場合のみ（静的ヘッダ）
# http_headers = { "X-SourceVault-Token" = "<token>" }
```

**検証:**

```bash
codex mcp list             # sourcevault が一覧に出れば OK
```

接続できない場合は `url` のポートが `SourceVaultMCPStatus[]` の `Url` と一致しているか、proxy が起動しているか（`SourceVaultMCPRunningQ[]`）を確認します。

#### 4-c. LM Studio

LM Studio の MCP 設定（`mcp.json`、「Program」→ Edit mcp.json から編集）に、SourceVault を **remote MCP（URL）** として登録します。`SourceVaultMCPStatus[]` が返す `Url` をそのまま使います。

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

ポートは実際の公開ポート（既定解決なら 8731、`proxy.config.json` に既存値があればそれ）に合わせてください。LM Studio はこの MCP が提供するツールを使って検索・本文取得を行います。

**検証:** LM Studio のチャットで Web 検索を促し、`sourcevault_web_search` が呼ばれること、および Mathematica 側で `SourceVaultWebSearchRunList[]` の監査記録が増えること（手順 7）を確認します。

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

> `SourceVaultIngest` の戻り値には、content-addressed な正準 URI `"URI" -> sv://snapshot/sha256/<hex>` が含まれます。これは `SourceVaultSources` の行や MCP の `SourceVaultParseURI` と共通の join / 参照キーで、絶対パスや内部 Id より machine / provider 非依存です。

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

> 巨大なファイル（`$SourceVaultMaxFileSizeMB` 超）は index 時に `"SkipReason" -> "FileTooLarge"` の skip 済み (`snap-toolarge-*`) snapshot として扱われ、Header/Todos は保持されません（サイズ判定のための軽量な `SourceSize` フィールドを持つ最新形式の snapshot に自動アップグレードされます）。

### ソース一覧・横断検索の動作確認（SourceVaultSources / SourceVaultArXiv / SourceVaultSummaries）

登録済みのすべてのソースを一覧表示する `SourceVaultSources`、arXiv ソースだけを表示する `SourceVaultArXiv`、Eagle 保存済みサマリー等の登録プロバイダ横断で検索・統合表示する `SourceVaultSummaries` が利用できます。arXiv 論文ソースについては、タイトル・著者・出版日が arXiv API（export.arxiv.org）から自動取得され、メタデータとしてキャッシュされます。ingest 時には arXiv アブストラクトを取得して `$Language` へ翻訳したものが Summary として自動付与されます。各行には URL リンク（▶ URL）と、ingest 済みファイルを現在の PC で開くリンク（▶ 開く）が付きます。

```mathematica
(* 登録済みソースの一覧を Grid で表示 *)
SourceVaultSources[]

(* 部分一致で絞り込み（Title/Authors/Summary/URL/Id 等） *)
SourceVaultSources["transformer"]

(* arXiv だけを、今日 ingest した分に絞って表示 *)
SourceVaultSources["", "Kind" -> "arxiv", "On" -> Today]

(* 登録プロバイダ横断でサマリー等を検索し統合表で表示 *)
SourceVaultSummaries["可逆計算",
  "FetchMetadata" -> Automatic,   (* Automatic: 未取得のみ取得 | False: ネットワーク不使用 | True: 強制再取得 *)
  "Format" -> "Grid"              (* "Grid"（既定）| "Dataset" | "Rows" *)
]
```

`SourceVaultSources` の主なオプション:

| オプション | 既定値 | 説明 |
|-----------|--------|------|
| `"Limit"` | `Automatic` | 表示件数の上限（`Automatic` / 整数） |
| `"Kind"` | `All` | 種別フィルタ。`All` / `"arxiv"` / `"web"` / `"local"` |
| `"FetchMetadata"` | `Automatic` | `Automatic`: 未取得のみ取得 / `False`: ネットワーク不使用 / `True`: 強制再取得 |
| `"Since"` / `"Until"` / `"On"` | 未指定 | ingest 日での絞り込み。日付文字列 `"yyyy-mm-dd"` / `Today` / `DateObject`。`"On"` は単日、`"Since"` / `"Until"` は範囲（両端含む） |
| `"Author"` | 未指定 | 著者名の部分一致 |
| `"Format"` | `"Grid"` | `"Grid"`: テーブル表示 / `"Dataset"`: Dataset として返す / `"Rows"`: 行リスト |

`SourceVaultArXiv` は `SourceVaultSources[query, "Kind" -> "arxiv", ...]` の薄いラッパで、オプションは `SourceVaultSources` と同じです。Eagle の `SourceVaultEagleSummaries` やメールの `SourceVaultMailSearchSummary` と同じ種別専用ビューで、横断検索 `SourceVaultSummaries` にも相乗りします。

```mathematica
(* arXiv ソースだけを共通スキーマ表で表示 *)
SourceVaultArXiv["", "On" -> Today]
SourceVaultArXiv["reversible", "Author" -> "Bennett"]
```

`SourceVaultSummaries` の主なオプション:

| オプション | 既定値 | 説明 |
|-----------|--------|------|
| `"Providers"` | `All` | 横断する provider。`All` / `{"sources", "eagle", ...}` |
| `"Limit"` | `Automatic` | 表示件数の上限 |
| `"Kind"` | `All` | 種別フィルタ |
| `"FetchMetadata"` | `Automatic` | `Automatic`: 未取得のみ取得 / `False`: ネットワーク不使用 / `True`: 強制再取得 |
| `"Since"` / `"Until"` / `"On"` | 未指定 | 登録 / 生成日での絞り込み |
| `"Author"` | 未指定 | 著者名の部分一致 |
| `"Format"` | `"Grid"` | `"Grid"`: テーブル表示 / `"Dataset"`: Dataset として返す / `"Rows"`: 行リスト |

> 横断検索 provider を自分で増やす場合は `SourceVaultRegisterSummaryProvider[name, fn]` で登録します。`fn[query_String, opts_Association]` は共通スキーマ行（`SourceVaultSourceRow` 参照）のリストを返してください。`SourceVaultSourceRow[sourceId]` が返す行は `<|"Kind", "Id", "URI", "Title", "Authors", "Published", "Summary", "URL", "File", "Date", "PrivacyLevel"|>` のキーを持ち、`"URI"` は正準 `sv://snapshot/..`（混在データセットの join / 参照キー）です。登録済み provider は `$SourceVaultSummaryProviders` で確認できます。

表でタイトルまたはサマリーをクリックすると、`SourceVaultShowSourceSummary` が呼ばれ、そのソース（arXiv / web / local 共通）のサマリーが**編集可能なノートブックで開きます**。保存済みのユーザー追記版があればそれが開き（追記が正本）、無ければ Title・著者・出版・URL・要約から生成されます。ノート内の「このノートを保存する」ボタンを押すと `<PrivateVault>/sources/summary-notes/` に保存され、以後はその保存版が開きます。`"Fresh" -> True` を渡すと保存版を無視し、record から新規生成して開きます。開くノートのスタイルは `$SourceVaultSummaryNotebookStyle`(既定 `"SourceVault default.nb"`) で変更できます。

「▶ 開く」リンクは `SourceVaultOpenSourceFile` の実体で、保存時の絶対パスではなく ContentHash から現在の PC の vault パスを再算出して開くため、別 PC（Dropbox 同期）でも開けます。

#### arXiv アブストラクトの一括付与（backfill）

既存の arXiv ソースのうち Summary が未設定（または過去の LLM エラー本文）のものに、arXiv アブストラクトを取得し `$Language` へ翻訳して Summary として付与できます（ingest 時の自動付与と同じ処理）。なお ingest 時の自動付与は新規 ingest / RebuiltMetadata で実行され、既に Summary を持つ既存ソース（AlreadyCurrent）は対象外のため、過去分の補完にはこの backfill を使います。

```mathematica
SourceVault`SourceVaultBackfillArXivSummaries[]
(* → <|"Candidates", "Updated", "AlreadyPresent", "NoAbstract", "Failed", "Results"|> *)
```

> 翻訳はクラウド LLM を使います（arXiv は公開データなので PrivacyLevel 0.0）。日本語に訳すには `$Language` が `"Japanese"` のセッションで実行してください（headless では英語原文のまま格納されます）。`"Force" -> True` で既存 Summary も再生成、`"Limit" -> n` で処理件数を制限できます。LLM の利用制限・エラー本文は弾かれるため、それらが要約として保存されることはありません。

#### 公開ソースの PrivacyLevel 是正

ingest 済みの公開 origin ソース（arXiv / 公開 URL）で、PrivacyLevel が機密閾値 0.5 以上に誤設定されているものを、本来の公開既定値（OfficialDocs / OfficialAPI = 0.0、PublicWeb = 0.4）に一括是正できます。旧版が arXiv 等の公開データを機密扱いしていた件の修復用（冪等）です。

```mathematica
SourceVault`SourceVaultReclassifyPublicPrivacy[]
(* → <|"Status", "Count", "Changed" -> {<|SourceId, From, To|>...}|> *)
```

> arXiv・wikipedia・公式 docs 等の公開 web データは PrivacyLevel 0.0（クラウド LLM 可・機密閾値 0.5 未満）として扱われます。一覧（`SourceVaultSources["", "Kind" -> "arxiv"]` 等）の公開 arxiv セルが Max PL 1.0 と誤判定され機密化される不具合は修正済みで、本関数で過去分を是正できます。

### Claude Code セッションログ（llmlog）の動作確認

`SourceVault_llmlog.wl`（本体ロード時に自動ロード）は、Claude Code のセッションログ（実行ログ・作業ログ）を PrivateVault に取り込み、検索・共有するサブシステムです。「Claude Code のログ」を GitHub のコミット履歴（`GitHubCommitLog`）や GitHub リポジトリ検索と混同させないよう、専用のルーティングキーワード（`"Claude Code"` / `"セッションログ"` / `"実行ログ"` / `"作業ログ"` / `"過去のセッション"` / `"svcclog"` 等）で扱われます（過剰マッチを避けるため、単独の「ログ」だけではルーティングされません）。

```mathematica
(* Claude Code のセッションログを PrivateVault に取り込む *)
SourceVault`SourceVaultIngestClaudeCodeLogs[]

(* 取り込んだセッションログを検索・閲覧する *)
SourceVault`SourceVaultClaudeCode["検索語"]
```

> セッションログの取り込みは、前述の「自動トリガスケジューラ」からも自動的にトリガされ得ます（`claudecode_sessions` タスク）。対話 FE を持たない compute ノードでは、前述の headless dispatch（`SourceVaultEnableHeadlessDispatch[]`）を opt-in しておくと、そのマシン上でも取り込みタスクが拾われます。

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

### メールアジェンダ（要対応メール）の動作確認

`SourceVault_mailagenda.wl`（本体ロード時に自動ロード）は、maildb の既存派生（Summary/Category/Priority/Deadline、`SourceVaultInferMailDerivedBatch` で事前計算）を索引だけで読み、**オーナー宛ての要対応メール**（返信が必要・作業/出席依頼）を routine アジェンダへ供給する薄い層です。アジェンダ経路では LLM / IMAP / メールシャード本体をロードしません。

```mathematica
(* 要対応メール候補を取得 *)
SourceVault`SourceVaultMailAgendaItems[]
(* → <|"Items" -> {item...}, "PendingCount" -> n|> *)

(* 解決（返信済み以外の対応済みマーク: Dismissed | NotebookCreated） *)
SourceVault`SourceVaultMailAgendaResolve[recordId, "Dismissed"]

(* 対応ウィンドウを開く（返信する / ノートブックを作成して継承 / 確認のみ） *)
SourceVault`SourceVaultMailAgendaOpen[recordId]

(* 作業ノートブックを作成してメールを継承する *)
SourceVault`SourceVaultMailAgendaInherit[recordId]
```

> 同一スレッド（Re/Fwd を剥いだ正規化件名 + MBox）は 1 項目に集約され、代表はオーナー宛て条件を満たす最新メールです。解決状態は `Pending → Done`（返信 / ノートブック作成 / 明示的な Dismissed）の一方向遷移で、返信は既存 maildb の返信送信時に自動記録されます。`SourceVaultRoutineAgendaData` に `"IncludeMail"` / `"MailItems"` / `"MailMaxPrivacyLevel"` オプションが追加され、`SourceVaultRoutineAgendaView` の表示に日別カレンダーの `"MailDeadline"` 種別および「✉ 要対応メール」バンドとして統合されます。PrivacyLevel ≥ 0.5 のメールを含む View 出力は既存 maildb と同じ機密規約（`ClaudeCode`Confidential`）でラップされます。個人アドレス（オーナー/組織アドレス・宛名パターン）はコードに焼き込まず `PrivateVault/config/mailagenda.json` で設定します。

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
| `SourceVaultNotebookSummary` 等の LLM 呼び出しが `LLMBoundaryRefused` で失敗する | 境界観測 (Boundary Observation) の self-gate により、その呼び出し元（例: `sourcevault:iCallSummaryLLM`）が拒否されています。`SourceVault`Private`$iSVBoundaryObsApplyResult` と `SourceVaultSetBoundaryObservation` の設定を確認してください |
| 大きい notebook（`SkipReason` -> `"FileTooLarge"`）の Header/Todo が再 index しても復元されない | skip 済み (too-large) snapshot は Header/Todos を保持しない仕様（再生成不可）。旧形式 (`SourceSize` フィールド無しの `snap-toolarge-*`) は最新形式へ自動アップグレードされ、以後は毎回ではなく 1 度だけ ForceReindex すれば済みます |
| `SourceVaultMailFetchNew` が失敗する | IMAP アカウント (`SourceVaultRegisterMailAccount`) と `SystemCredential[CredKey]` のパスワードが設定済みか、`$NBCredentialBackend = "SystemCredential"` でロードしているか確認 |
| `SourceVaultMailAgendaItems[]` が要対応メールを返さない・見逃す | Category/Priority/Deadline は `SourceVaultInferMailDerivedBatch[]` の事前計算に依存（未計算メールは除外せず `PendingCount` に計上されるだけ）。まず `SourceVaultMailAddSummaries[mbox]` で派生を計算する。オーナー宛て判定は `$SourceVaultMailAgendaDirectionThreshold`（既定 0.7）未満だと候補から外れるため、`PrivateVault/config/mailagenda.json` の OwnerAddresses/OrgAddresses/AddresseePatterns を確認 |
| `SourceVaultMailAgendaResolve` したのに次回また表示される | スレッド集約に対応。解決後により新しい Re: が届くと再浮上する仕様（意図した挙動）。個別メールの取り消しは `SourceVaultMailAgendaReopen[recordId]` |
| `ReadList` が空配列を返す | 罠 #20 (Windows JSONL/UTF-8)。`ReadByteArray` + `ByteArrayToString` + `StringSplit` 経路を使うこと |
| パッケージロード時に `Syntax::stresc` が大量に出る | 罠 #11 (`\uXXXX` エスケープ混入)。`\:XXXX` に書き直す必要あり |
| `$SourceVaultDefaultNotebookFolder` が正しいフォルダを返さない | `Global`$onWork`` が未定義で `$packageDirectory` にフォールバックしていないか確認。絶対パスを直接代入することで固定できます |
| `SourceVaultSources` / `SourceVaultArXiv` が arXiv メタデータを取得しない | ネットワーク接続を確認するか、`"FetchMetadata" -> True` を明示して強制再取得してください |
| arXiv ソースの Summary が空・英語のまま | `SourceVaultBackfillArXivSummaries[]` を `$Language = "Japanese"` のセッションで実行。LLM エラー本文が残っている場合は `"Force" -> True` で再生成 |
| 公開 arXiv / Web ソースが機密扱い（PrivacyLevel 0.5 以上）になっている | 旧版の誤タグの名残。`SourceVaultReclassifyPublicPrivacy[]` で公開既定値（0.0 / 0.4）に是正（冪等） |
| モデルのバージョン比較が誤る（新メジャー版に旧マイナー付き版が負ける） | `iSVParseModelVersion` の数値キーを固定幅パディング方式（base-100000・width 6）に修正済み。旧実装は指数に桁数 `Length` を使っていたため、桁数の異なるバージョン間（例: `claude-sonnet-4-6` の `{4,6}` と `claude-sonnet-5` の `{5}`）で、桁数の多い `{4,6}`（`4*1000+6=4006`）が桁数の少ない `{5}`（`5`）を誤って上回っていました。SourceVault を最新版に更新すれば、固定幅パディングにより `{5}`（新メジャー版）が `{4,6}` を正しく上回ります。日付らしき数値は `iSVParseModelVersion` で事前に除外されるため（10000 未満のみ通す）、固定幅パディング（base-100000・width 6）と衝突して桁上がりすることはありません。2026-07-06 に、この不具合で LM Studio モデルが誤ルートした実例が確認され対処済みです。 |
| `SourceVaultShowSourceSummary` がいつも自動生成版を開く（追記が反映されない） | ノート内の「このノートを保存する」ボタンを押して `<PrivateVault>/sources/summary-notes/` に保存したか確認。保存版が正本として優先されます。逆に保存版を無視して record から作り直したい場合は `"Fresh" -> True` |
| `SourceVaultWebSearch` / `SourceVaultSearXNGAvailableQ` が失敗・空を返す | SearXNG が `127.0.0.1:8888`（`$SourceVaultSearXNGEndpoint`）で稼働しているか、`settings.yml` の `search.formats` に `json` が含まれるか、`limiter`/`botdetection` がローカルアクセスをブロックしていないか確認 |
| MCP トグル/検索を変更したのに反映されない | detached service は起動時コードを保持。`SourceVaultRestartService["sourcevault"]`（または `SourceVaultStopMCP[]`→`SourceVaultStartMCP[]`）で再起動する |
| MCP クライアント（Claude Code / Codex / LM Studio）から検索できない・ツールが見えない | `SourceVaultMCPRunningQ[]` が `True` か、登録 URL のポートが `SourceVaultMCPStatus[]` の `Url` と一致するか、`claude mcp list` / `codex mcp list` に `sourcevault` が出るか確認。proxy 未起動なら `SourceVaultStartMCP[]`。`.wl` 変更後は `SourceVaultRestartService["sourcevault"]` |
| MCP クライアントから `/sv/mcp` が `401` | トークン設定時のみ。`X-SourceVault-Token` が `$SourceVaultMCPToken`（または `proxy.config.json` の値）と一致するか確認（Claude Code: `--header`、Codex: `http_headers`、LM Studio: `headers`）。トークン未設定なら認証不要（localhost のみ） |
| `SourceVaultStartHTTPProxy` が `Pending` を返す | Python（`$SourceVaultPython`）が解決できているか、ポートが他プロセスと衝突していないか確認 |
| クライアントが `ECONNREFUSED 127.0.0.1:<port>` | 登録 URL のポートが proxy と不一致（典型は **9700 の残骸**）。正規は **8731**。`SourceVaultMCPStatus[]` の `Url` に全クライアントを合わせる。proxy 自体が落ちていれば `SourceVaultStartMCP[]` |
| **再起動後**、クライアントが `MCP error -32001: Request timed out`（proxy は到達するが応答しない） | proxy は上がっているが**背後の WL サービスカーネルが死んでいる/起動していない**。`SourceVaultMCPStatus[]` で `healthState` が `Stale`/`Unknown`、`heartbeatAgeSeconds` が大きい/`null` なら確定。復旧 = `SourceVaultStartMCP["RestartService" -> True]`、または service の `launch_hidden.vbs` を `wscript //B //Nologo` で直接起動。恒久対策は上の「ログオン時の自動起動」 |
| サービスカーネルが起動直後に消える（`stdout.log` 末尾に *"The product exited because an error occurred … unregistered"*） | **Wolfram ライセンスの同時メインカーネル席の枯渇**。FE＋並列 subkernel の親＋ネイティブ Wolfram MCP（Claude Code がセッション毎に起動）＋wolframscript ジョブが席を食うと、detached サービスカーネルが弾かれる。`/health` は proxy 生存で緑のままなので気づきにくい。対策 = 余分な Wolfram メインカーネルを減らす（ネイティブ Wolfram MCP を単一共有カーネルの HTTP ゲートウェイに集約 / claudecode の前置並列カーネルを `$ClaudeParallelKernelCount` で削減 / Claude Code の余分セッションを閉じる） |
| パレットの「実行中／停止中」が実態と食い違う | 旧実装は proxy 到達性のみで判定していた。`healthState=="OK"` 判定に修正済み（2026-06）。稼働中カーネルで `Get["SourceVault_servicemanager.wl"]` 再読込すると反映される |
| パレットの「MCP実行」を押したのに起動しない／`SourceVaultSvc_<id>` タスクが消えている | 上記の状態誤判定で、トグルが「実行中」と誤認して逆に Stop（Svc タスク削除）した名残。RunningQ 修正で再発防止済み。当座は service の `launch_hidden.vbs` を直接起動するか `SourceVaultStartMCP[]` を再実行（タスクは再生成される） |
| 自動トリガスケジューラが動かない／二重に動く | 自動起動は対話 FE カーネル（`$FrontEnd =!= Null`）に限定。`SourceVault`Private`$iSVAutoTriggerSchedulerAutoStartResult` の `Status`/`Reason` を確認（`NotFrontEndKernel` = headless、`DisabledByUser` = `$iSVDisableAutoTriggerScheduler` が `True`、`AutoTriggerUnavailable` = claudecode 未ロード）。手動起動は `SourceVaultAutoTriggerStartScheduler[]`（冪等）。無効化は SourceVault ロード前に `SourceVault`Private`$iSVDisableAutoTriggerScheduler = True` |
| FE レス compute ノード（対話 FE なし）でジョブが自動的に拾われない | 対話 FE 限定の自動トリガスケジューラの対象外（`NotFrontEndKernel`）。そのマシン上だけでジョブ dispatch を拾わせたい場合は `SourceVaultEnableHeadlessDispatch[]` で headless dispatch を opt-in する。対話 FE のスケジューラと併用しても atomic dispatch claim により二重実行はされない |
| 「Claude Code のログ」検索が GitHub コミット履歴やリポジトリ検索に誤ルートする | llmlog 専用キーワード（`"セッションログ"` / `"実行ログ"` / `"svcclog"` 等）を使う。取り込みは `SourceVaultIngestClaudeCodeLogs[]`、検索は `SourceVaultClaudeCode[...]`。`SourceVault_llmlog.wl` がロードされているか確認 |

---

## 関連リンク

- [SourceVault リポジトリ](https://github.com/transreal/SourceVault)
- [SearXNG](https://docs.searxng.org/) — ローカル Web 検索メタサーチ（MCP ゲートウェイのバックエンド）
- [NBAccess](https://github.com/transreal/NBAccess)
- [claudecode](https://github.com/transreal/claudecode)
- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime)
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)
- [github](https://github.com/transreal/github)