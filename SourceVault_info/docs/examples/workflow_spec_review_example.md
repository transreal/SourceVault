# SourceVault ワークフロー使用例 — spec-review

SourceVault のコード化ワークフローを **オンデマンドでロードして実行**する流れを、同梱の `spec-review`（Codex↔Claude 仕様レビュー・改訂ループ、旧 `OrchWorkflow`）を題材に示します。

このドキュメントの大半は **MOCK executor**（クラウド・codex を呼ばないダミー関数）を使うので、API キーやネットワークなしでそのまま実行できます。実 LLM での実行とパレット連携は最後の節で説明します。

ワークフローの位置づけ・収納規約は [`user_manual.md` の「SourceVault ワークフロー」](../user_manual.md) を参照してください。

---

## 事前準備

```mathematica
Block[{$CharacterEncoding = "UTF-8"},
  Get[FileNameJoin[{$packageDirectory, "ClaudeOrchestrator.wl"}]];
  Get[FileNameJoin[{$packageDirectory, "SourceVault.wl"}]]];

(* レジストリは SourceVault と一緒に自動ロードされる *)
Names["SourceVault`SourceVaultLoadWorkflow"]
```

**期待される出力例:** `{"SourceVaultLoadWorkflow"}`

> `SourceVaultLoadWorkflow` がワークフロー本体をロードする際に `ClaudeOrchestrator`Workflow`` を自己ブートストラップするため、最低限 `SourceVault.wl` だけでも動きます（上では明示的に ClaudeOrchestrator も先にロードしています）。

> **補足（対話 FE カーネルでの自動トリガ起動）**: `SourceVault.wl` を対話フロントエンド（FE）カーネルでロードすると、この PC がジョブを常に拾えるよう自動トリガのスケジューラが自動起動されます（`SourceVaultAutoTriggerStartScheduler` を内部で呼びます）。この起動は **FE メインカーネル（`$FrontEnd =!= Null`）でのみ**行われ、ヘッドレスカーネル・サブカーネル・外部ジョブの wolframscript プロセスなどは除外されます（各カーネルが自前スケジューラを立てるとライセンスシートやディスパッチが多重化するため、機械あたり 1 か所＝対話 FE に限定しています）。起動は冪等で、結果は `SourceVault`Private`$iSVAutoTriggerSchedulerAutoStartResult` に記録されます。無効化したい場合はロード前に `SourceVault`Private`$iSVDisableAutoTriggerScheduler = True` を設定してください（このとき自動起動は `Status -> "Skipped"`, `Reason -> "DisabledByUser"` を返します）。spec-review ワークフローを手元で試すだけであれば、この挙動を意識する必要はありません。

---

## 例 1: レジストリで収納済みワークフローを発見

```mathematica
SourceVault`SourceVaultWorkflowDirectory[]
```

**期待される出力例:**

```
"...\\MyPackages\\SourceVault_workflows"
```

```mathematica
SourceVault`SourceVaultWorkflows[]
```

**期待される出力例:**

```
{<|"Slug"     -> "spec-review",
   "Path"     -> "...\\SourceVault_workflows\\spec-review",
   "MainFile" -> "...\\SVWorkflow_SpecReview.wl",
   "Context"  -> "SourceVaultWorkflow`SpecReview`",
   "Loaded"   -> False|>}
```

`Loaded -> False` は、ワークフローがまだロードされていない（context が `$Packages` に無い）ことを示します。slug `spec-review` はフォルダ名そのもので、context は `SourceVaultWorkflowContext` が正規化します。

```mathematica
SourceVault`SourceVaultWorkflowContext["spec-review"]
```

**期待される出力例:** `"SourceVaultWorkflow`SpecReview`"`

---

## 例 2: オンデマンドロードと WorkflowInfo

```mathematica
res = SourceVault`SourceVaultLoadWorkflow["spec-review"];
res["Status"]
```

**期待される出力例:** `"Loaded"`

```mathematica
res
```

**期待される出力例:**

```
<|"Status"  -> "Loaded",
  "Slug"    -> "spec-review",
  "Context" -> "SourceVaultWorkflow`SpecReview`",
  "Path"    -> "...\\SVWorkflow_SpecReview.wl"|>
```

ロードは冪等です。もう一度呼ぶと再ロードせずスキップします。

```mathematica
SourceVault`SourceVaultLoadWorkflow["spec-review"]["Status"]
```

**期待される出力例:** `"AlreadyLoaded"`

ワークフローのメタデータ（起動関数名・ルート定義など）は `WorkflowInfo[]` で取得します。

```mathematica
SourceVaultWorkflow`SpecReview`WorkflowInfo[]
```

**期待される出力例:**

```
<|"Slug"        -> "spec-review",
  "Name"        -> "Codex<->Claude Spec Review",
  "Version"     -> "1.0",
  "Context"     -> "SourceVaultWorkflow`SpecReview`",
  "Launch"      -> "RunSpecReview",
  "Description" -> "Codex drafts a spec, Claude reviews; revise/approve loop ...",
  "Routes"      -> {}|>
```

---

## 例 3: MOCK executor でレビュー・改訂ループを実行（クラウド不要）

`RunSpecReview` は `"DraftFunction"` / `"ReviewFunction"` を差し替えられます。ここでは「ラウンド 2 で Approved になる」決定的なダミー関数を渡し、ループの遷移だけを確かめます。

```mathematica
mockDraft = Function[{model, pl},
  <|"SpecText" -> "# MOCK SPEC v" <> ToString[Lookup[pl, "Round", 1]] <>
     " (" <> Lookup[pl, "Project", ""] <> ")"|>];

mockReview = Function[{model, pl, specText},
  <|"Verdict"    -> If[Lookup[pl, "Round", 1] >= 2, "Approved", "NeedsRevision"],
    "Findings"   -> "[]",
    "ReviewText" -> "mock review round " <> ToString[Lookup[pl, "Round", 1]]|>];

summary = SourceVaultWorkflow`SpecReview`RunSpecReview["WFExample",
  "DraftPrompt"     -> "(mock)",
  "DraftFunction"   -> mockDraft,
  "ReviewFunction"  -> mockReview,
  "CodegenFunction" -> None,
  "MaxRounds"       -> 3];

KeyTake[summary, {"FinalStatus", "Rounds", "FinalVerdict"}]
```

**期待される出力例:**

```
<|"FinalStatus" -> "Approved", "Rounds" -> 2, "FinalVerdict" -> "Approved"|>
```

ラウンド 1 は `NeedsRevision` で改訂に戻り、ラウンド 2 で `Approved` となって承認遷移に入ります。遷移の流れは:

```
NeedDraft --Draft--> Drafted --Review[NeedsRevision]--> Reviewed
  --Revise(round=2)--> NeedDraft --Draft--> Drafted --Review[Approved]--> Reviewed --Approve--> Approved
```

---

## 例 4: SourceVault 版管理チェーン（sv:// URI）を確認

各ラウンドの spec / review は SourceVault に不変スナップショット + version pointer + handoff イベントとして保存され、`summary` には `sv://` URI の鎖が入ります。

```mathematica
summary["SpecChain"]
```

**期待される出力例:**

```
{"sv://snapshot/OrchSpec/....", "sv://snapshot/OrchSpec/...."}   (* 2 ラウンド分 *)
```

```mathematica
summary["ReviewChain"]
{summary["ApprovedSpecURI"], summary["ApprovedReviewURI"]}
```

**期待される出力例:**

```
{"sv://snapshot/OrchReview/....", "sv://snapshot/OrchReview/...."}

{"sv://snapshot/OrchSpec/....", "sv://snapshot/OrchReview/...."}
```

ポインタ履歴は SourceVault の標準 API でも辿れます。

```mathematica
SourceVault`SourceVaultPointerHistory["orch/WFExample/spec"]   // Length
SourceVault`SourceVaultPointerHistory["orch/WFExample/review"] // Length
```

**期待される出力例:** `2` と `2`

承認済み spec の本文は `summary` から直接取り出せます。

```mathematica
summary["FinalPayload"]["SpecText"]
```

`sv://` URI には二種類の形式があります。

- **クラス別形式**（ワークフロー成果物）: `sv://snapshot/OrchSpec/<hex>`、`sv://snapshot/OrchReview/<hex>` のように種別クラスを示すパスを持ちます。
- **コンテンツアドレス形式**（ingest 済みソース）: `SourceVaultIngest` の戻り値の `"URI"` キーは `sv://snapshot/sha256/<hex>` 形式の content-addressed URI になります。`SourceVaultSourceRow` も同じ `"URI"` フィールドを共通スキーマ行の join キーとして返します。

どちらの形式も `SourceVault`SourceVaultParseURI` で ref（`snapshot:<class>:<hex>` 形式）を得てから `SourceVault`SourceVaultLoadImmutableSnapshot` に渡すことで不変スナップショットを解決できます。

---

## 例 5: 実 LLM 実行とパレット連携

MOCK を外して `"DraftFunction"` / `"ReviewFunction"` を省略（既定 `Automatic`）すると、Codex 役（`ClaudeCode`$ClaudeAdvisaryModel`）と Claude 役（`ClaudeCode`$ClaudeModel`）が実際に呼ばれます。承認済み spec を `.wl` へ自動生成するには `"CodegenFunction" -> Automatic` を指定します。

```mathematica
(* 実 LLM 実行（モデルが設定済みであること。時間がかかる） *)
SourceVaultWorkflow`SpecReview`RunSpecReview["RealProject",
  "DraftPrompt" -> "Write a small Wolfram Language design spec for a retry-with-backoff utility.",
  "MaxRounds"   -> 3,
  "CodegenFunction" -> Automatic]
```

ノートブックから使う場合は、**パレットの「仕様生成」ボタン**が同じループをバックグラウンドで実行します（SourceVault と ClaudeOrchestrator が両方ロードされている場合）。FE カーネルは重いループを直接実行せず、`SourceVault_workflows/spec-review/palette_driver.wls` を別 wolframscript プロセスで起動し、`SourceVaultLoadWorkflow["spec-review"]` でオンデマンドロードして走らせ、完了後に合意 spec と `sv://` 鎖をノートブックへ追記します。状態は `ClaudeSpecStatus[]` で確認できます。

> **補足（モデル解決の版比較について）**: 実 LLM 実行で使われる Codex/Claude 役のモデルは `SourceVaultResolve["Model", ...]` を通じて選択されます。内部の版比較キー算出（`SortBy` 用の数値キー）は、バージョン各桁を**固定幅で右パディングしてから一定の基数で重み付けする**方式に更新されました（現行実装では `width = 6`, `base = 100000`。バージョン列を上位から幅 6 に `PadRight` してゼロ埋めし、各桁に `base^(width - 位置)` を掛けて単調値化します）。旧実装は指数に列長 `Length[v]` を使っていたため、桁数の異なるバージョン間で不整合が生じ、`{4,6} -> 4006` が `{5} -> 5` を上回って `claude-sonnet-4-6` が `claude-sonnet-5` に誤って勝つ（＝桁数の少ない新メジャー版が昇格されない）逆転が起きていました。新方式ではこの逆転が解消され、`claude-sonnet-4-6` と `claude-sonnet-5` のように桁数の異なる版でも意図どおり新しい版が優先されます。なお日付要素は `iSVParseModelVersion` の段階で除外済みのため桁上がりには影響しません。この挙動はワークフロー利用側から明示的に触れる API ではなく、モデル解決の結果が正しく最新版を返すことを保証する内部改善です。

---

## クリーンアップ

例で作成した version pointer / snapshot は SourceVault に永続化されます。テスト用プロジェクトの痕跡を消す場合は、SourceVault の管理 API（`SourceVaultRoot` 配下の `meta/` / `events/`）から該当 `orch/WFExample/*` を手動で扱ってください（通常は残しておいて問題ありません）。