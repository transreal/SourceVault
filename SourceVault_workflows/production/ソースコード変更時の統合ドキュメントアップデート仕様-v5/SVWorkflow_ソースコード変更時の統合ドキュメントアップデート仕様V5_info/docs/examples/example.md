# ソースコード変更時の統合ドキュメントアップデート仕様-v5 — 使用例

このワークフローは、対象パッケージ（システム: `NBAccess`, `claudecode`, `ClaudeRuntime`, `ClaudeOrchestrator`, `SourceVault` / 補助: `github`, `ClaudeTestKit`, `PDFIndex`, `documentation`）の **ソースコード変更を検出** し、変更があったパッケージについて `ClaudeUpdateDocumentation` を実行して `docs/api.md` `docs/user_manual.md` `docs/README.md` `docs/examples/example.md`（必要に応じて `docs/setup.md`）を一貫更新します。

変更判定は、可能な場合は `ClaudeUpdatePackage` が残す更新記録・変更ファイル一覧（パッケージの `_info` 配下の history / updates / backups）を参照し、無い場合はソースとドキュメントの更新時刻比較にフォールバックします。Git 差分だけには依存しません。

## 読み込み

```wl
Needs["SourceVault`"]; SourceVault`SourceVaultLoadWorkflow["ソースコード変更時の統合ドキュメントアップデート仕様-v5"]
```

## メタ情報の確認

```wl
WorkflowInfo[]
(* => <|
     "Slug"    -> "ソースコード変更時の統合ドキュメントアップデート仕様-v5",
     "Name"    -> "ソースコード変更時の統合ドキュメントアップデート仕様",
     "Version" -> "5.0.0",
     "Context" -> "SourceVaultWorkflow`ソースコード変更時の統合ドキュメントアップデート仕様V5`",
     "Launch"  -> "IntegratedDocUpdateWorkflow",
     "Routes"  -> {} |> *)
```

## 1. ドライラン（副作用なしの検出レポート）

引数なしの起動フォームは安全なレポートです。対象パッケージのうちソース変更が検出され
ドキュメント更新が必要なものを `"Pending"` に列挙して返します。ファイルの書き換えは行いません。

```wl
IntegratedDocUpdateWorkflow[]
(* => <|"Mode" -> "Report", "Pending" -> {...}, "Detections" -> {<|"Package"->..., "Changed"->..., "Reason"->...|>, ...}|> *)
```

特定パッケージだけを検査する場合:

```wl
IntegratedDocUpdateWorkflow["NBAccess"]
IntegratedDocUpdateWorkflow[{"claudecode", "SourceVault"}]
```

各 `Detections` 要素には `SourceModified` / `DocsModified` / `UpdateRecord` / `Reason`（`"source newer than docs"`, `"ClaudeUpdatePackage record newer than docs"`, `"documentation missing"`, `"docs up to date"` など）が含まれます。

## 2. 実行（ClaudeUpdateDocumentation を呼ぶ）

検出されたパッケージについて実際にドキュメント更新を実行するには、明示フォームとして
`"Execute" -> True` を渡します。各対象に対し `ClaudeUpdateDocumentation[パッケージ名, 更新指示]` を実行します。

```wl
IntegratedDocUpdateWorkflow[All, "Execute" -> True]
(* => <|"Mode" -> "Execute", "Pending" -> {...}, "Results" -> <|"NBAccess" -> ..., ...|>|> *)
```

単一パッケージを、変更検出に関わらず強制更新:

```wl
IntegratedDocUpdateWorkflow["claudecode", "Execute" -> True, "Force" -> True]
```

更新指示を上書きしたい場合:

```wl
IntegratedDocUpdateWorkflow["SourceVault", "Execute" -> True,
  "Instruction" -> "api.md と example.md のみ、追加された公開関数に合わせて更新する。"]
```