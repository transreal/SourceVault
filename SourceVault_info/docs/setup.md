# SourceVault インストール手順書

macOS/Linux ではパス区切りやシェルコマンドを適宜読み替えてください。

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

PromptRouter 拡張 `SourceVault_promptrouter.wl` は `SourceVault.wl` と同じディレクトリに必要です。リポジトリに同梱されている場合は同時に取得されます。別ファイルとして配布されている場合は、同じ要領で `$packageDirectory` へ配置してください。

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

リポジトリから `SourceVault.wl` を入手し、**`$packageDirectory` 直下**に配置します。

```
$packageDirectory\
  SourceVault.wl                 ← 本体
  SourceVault_promptrouter.wl    ← PromptRouter 拡張 (本体ロード時に自動ロード)
  NBAccess.wl
  claudecode.wl
  ...
```

> サブフォルダには配置しないでください。
>
> PromptRouter 拡張 `SourceVault_promptrouter.wl` を使う場合は、`SourceVault.wl` と同じディレクトリに配置します。`SourceVault.wl` のロード時に自動的に読み込まれます。

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
| ReadList が空配列を返す | 罠 #20 (Windows JSONL/UTF-8)。`ReadByteArray` + `ByteArrayToString` + `StringSplit` 経路を使うこと |
| パッケージロード時に `Syntax::stresc` が大量に出る | 罠 #11 (`\uXXXX` エスケープ混入)。`\:XXXX` に書き直す必要あり |

---

## 関連リンク

- [SourceVault リポジトリ](https://github.com/transreal/SourceVault)
- [NBAccess](https://github.com/transreal/NBAccess)
- [claudecode](https://github.com/transreal/claudecode)
- [ClaudeRuntime](https://github.com/transreal/ClaudeRuntime)
- [ClaudeOrchestrator](https://github.com/transreal/ClaudeOrchestrator)
- [github](https://github.com/transreal/github)
