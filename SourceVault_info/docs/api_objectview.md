# SourceVault ObjectView (sv:// オブジェクト解決) API Reference

パッケージ: `SourceVault`` (context)

> **2026-06-21 統合:** 独立ファイル `SourceVault_objectview.wl` は廃止され、機能は以下へ統合されました（公開関数名・シグネチャは不変）。
> - 解決系 `SourceVaultObjectPrivacyLevel` / `SourceVaultObjectData` / `SourceVaultObjectProperties` → **`SourceVault_mcp.wl`**（NBAccess 非依存。`SourceVault.wl` から自動ロード）
> - セル出力 `SourceVaultObjectToCell` → **`SourceVault_eagle.wl`**（NBAccess / FrontEnd 依存。eagle ロード時に有効）

## 概要

`sv://` オブジェクトの実データ取得・全プロパティ取得・privacy 継承付きノートブックセル出力を提供する。対応 namespace: `snapshot` / `object` (eagle) / `file`。eagle 拡張機能 (tags/Exif/ImageDimensions) は SourceVault_eagle がロードされている場合のみ有効 (best-effort)。

## 公開関数

### SourceVaultObjectPrivacyLevel[uri] → Real
`sv://` オブジェクトの privacy level (0.0–1.0) を返す。`uri` が不正な場合は `$SourceVaultDefaultObjectPrivacyLevel` を返す。namespace 別の挙動: `snapshot` → `SourceVaultSnapshotPrivacyLevel` に委譲 (既定 0.85); `object/eagle-<id>` → eagle item の PrivacyLevel; `file` → 0.0 (allow-list bridge); それ以外 → 既定 0.85。

### SourceVaultObjectData[uri] → expr | Failure
`sv://` URI が指す実オブジェクトデータを返す。
- `snapshot` namespace: `SourceVaultLoadImmutableSnapshot` で検証済み Association
- `object/eagle-<id>` (画像拡張子): `Image`; ファイルが読めない場合は `<|"FilePath"->..., "Item"->...|>`
- `object/eagle-<id>` (非画像): `<|"FilePath"->..., "Item"->...|>`
- `file` namespace: 画像拡張子なら `Image`、それ以外は文字列テキスト; 読み取り失敗時は `Missing["Unreadable"]`
- 解決不能の場合は `Failure` を返す (`"InvalidURI"` / `"EagleUnavailable"` / `"SnapshotNotFound"` 等)

### SourceVaultObjectProperties[uri] → Association
`sv://` オブジェクトの全プロパティを Association で返す。不正 URI の場合は `<|"Valid"->False, ...|>`。
共通キー: `URI`, `Namespace`, `Kind`, `PrivacyLevel`, `PrivacySource`。
namespace 別の追加キー:
- `snapshot`: `Ref`, `PrivacyRecord`, `Snapshot*` (スナップショット record 全フィールドに "Snapshot" プレフィックス付き)
- `object/eagle`: `Id`, `Name`, `Ext`, `Tags`, `Folders`, `Annotation`, `URL`, `Size`, `ModificationTime`, `FilePath`, `EagleRaw`; 画像の場合さらに `ImageDimensions`, `FileFormat`, `FileByteCount`, `Exif`
- `file`: `FilePath`, `FileByteCount`, `FileFormat`, `FileDate`; 画像ファイルの場合さらに `ImageDimensions`, `Exif`

### SourceVaultObjectToCell[uri, opts]
オブジェクトの内容・プロパティをノートブックセルに出力し、セルの PrivacyLevel をオブジェクトの privacy level に継承する。level > 0.5 なら `NBMarkCellConfidential` で confidential マークを付ける。
→ `Association`
Options: `"Notebook" -> Automatic` (Automatic = `InputNotebook[]`), `"Show" -> "Both"` (`"Data"` | `"Properties"` | `"Both"`)

戻り値キー (ノートブックあり): `<|"Status"->"OK", "URI"->..., "PrivacyLevel"->..., "Confidential"->bool, "Cells"->{<|"Part"->"props"|"data", "CellIndex"->i, "Tag"->...|>, ...}|>`
戻り値キー (headless / ノートブックなし): `<|"Status"->"NoNotebook", "URI"->..., "PrivacyLevel"->..., "Confidential"->bool, "Data"->..., "Properties"->...|>` ("Show" に応じて Data/Properties が Missing になる)
戻り値キー (引数エラー): `<|"Status"->"Failed", "Reason"->"BadArguments"|>`

例: `SourceVaultObjectToCell["sv://object/eagle-abc123", "Show" -> "Data"]`
例: `SourceVaultObjectToCell["sv://snapshot/MyClass/deadbeef", "Notebook" -> nb, "Show" -> "Properties"]`

## 内部実装メモ (LLM 向け)

セル出力には NBAccess の `NBWriteCell` / `NBCellIndicesByTag` / `NBMarkCellConfidential` のみを使う。eagle 拡張関数 (`SourceVaultEagleItem`, `SourceVaultEagleItemPath`, `SourceVaultEagleExif`, `SourceVaultEagleSummaryRow`) は `DownValues` の存在チェックで best-effort 呼び出しされる。画像拡張子判定対象: `jpg`, `jpeg`, `png`, `gif`, `bmp`, `tif`, `tiff`, `webp`, `heic`, `heif`。