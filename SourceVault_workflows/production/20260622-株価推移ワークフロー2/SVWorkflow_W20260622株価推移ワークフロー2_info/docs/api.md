# Workflow API: 20260622-株価推移ワークフロー2 株価相対指数ノートブック生成

Slug: `20260622-株価推移ワークフロー2`

## 呼び出し方法

ロードしてから Launch 関数を呼ぶ:

```wl
Needs["SourceVault`"]; SourceVault`SourceVaultLoadWorkflow["20260622-株価推移ワークフロー2"]
SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch[...]
```

## 概要

2016年1月1日を100とした主要テック・半導体株・S&P500の相対指数推移ノートブックを生成するワークフロー(完全実装)。context先頭の数字を避けるためWプレフィックス付きcontext。AdjustedClose優先・Close fallback、補間なし。FinancialDataのTimeSeries返却形状をasPairs(DatePath→Path)で吸収し、Quantity値を剥がして{date,value}対へ正規化(パッケージ本体・生成ノートブックの両方で同一の coercion)。generateで6セル(補助表・対数スケール切替含む)を生成。

## 使用例

# 20260622-株価推移ワークフロー2 使用例

オンデマンドレジストリ経由でワークフローを読み込む（スラッグから context を導出してロード）:

```wl
Needs["SourceVault`"]; SourceVault`SourceVaultLoadWorkflow["20260622-株価推移ワークフロー2"]
```

> 命名メモ: context のリーフが数字（`20260622…`）で始まると Wolfram のシンボルとして無効になる。
> レジストリは数字始まりのとき `W` を前置するため、本ワークフローの context は
> `SourceVaultWorkflow`W20260622株価推移ワークフロー2`` となる。Launch シンボル
> `株価推移ワークフロー2Launch` は文字（株）で始まるため W 前置は不要（末尾の `2` は有効）。

メタデータを確認する:

```wl
SourceVaultWorkflow`W20260622株価推移ワークフロー2`WorkflowInfo[]
```

副作用のない安全なレポート（`Status -> "Ready"`、対象 12 銘柄・表示名・基準化方針・識別子表・補助表の列定義・データ形状方針）:

```wl
SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch[]
```

実際に処理を行う明示形 — 6 セルのノートブックを生成する（先頭は仕様指定の Text セル、続いてパラメータ / データ取得 / 正規化 / 可視化 / 補助表＋注記の Input セル）:

```wl
res = SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch["generate"];
res["CellCount"]    (* 6 *)
res["CellStyles"]   (* {"Text","Input","Input","Input","Input","Input"} *)
res["Title"]        (* "Maginiticent 7とNvidia, TSMC, Samsung, マイクロン、キオクシアとS&P500インデックスの2016/1/1を100として現在までの推移の可視化" *)
res["PlotTitle"]    (* "2016年1月1日を100とした主要テック・半導体関連銘柄とS&P 500の推移" *)
res["Notebook"]     (* 6 セルからなる Notebook 式（先頭 Text セルが仕様指定の文言） *)
```

`.nb` ファイルへ書き出す:

```wl
SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch[
  "generate", "Export" -> FileNameJoin[{$HomeDirectory, "kabu2.nb"}]]
```

正規化ロジック（純粋・ネットワーク不要・最初の有効値を 100 に基準化、補間なし）:

```wl
SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch[
  "normalize", {{{2016, 1, 1}, 50}, {{2016, 1, 2}, 75}, {{2016, 1, 4}, 100}}]
(* {{{2016,1,1}, 100.}, {{2016,1,2}, 150.}, {{2016,1,4}, 200.}} *)
```

`FinancialData` は TimeSeries を返すため、TimeSeries も同じく受け付ける（`DatePath`→`Path` で `{日付, 値}` 対に変換し、`ListQ` だけで落とさない）。値が `Quantity`（通貨）でも `QuantityMagnitude` で剥がして基準化する:

```wl
ts = TimeSeries[{{{2016, 1, 1}, 50.}, {{2016, 1, 2}, 75.}, {{2016, 1, 4}, 100.}}];
SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch["normalize", ts]
(* 3 点が残り、先頭が 100. に基準化される *)

tsQ = TimeSeries[{{{2016, 1, 1}, Quantity[40., "KRW"]}, {{2016, 1, 3}, Quantity[120., "KRW"]}}];
SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch["normalize", tsQ]
(* {{_,100.}, {_,300.}} 通貨単位を剥がして基準化 *)
```

補助表 1 行分のサマリ（銘柄名 / ティッカー / 基準日 / 基準価格 / 最新日 / 最新指数値）:

```wl
SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch[
  "summary", "アップル", "AAPL", "AdjustedClose",
  {{{2016, 1, 1}, 50}, {{2016, 1, 5}, 200}}]
(* <|"Display"->"アップル", ..., "BasePrice"->50, "LastIndex"->400.|> *)
```

最新データを取得して相対指数・補助表を計算する（ネットワーク必要）:

```wl
SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch["data"]
```

全系列を 1 枚の折れ線グラフに描画する（ネットワーク必要、`"Log" -> True` で縦軸対数、グラフタイトルは「2016年1月1日を100とした主要テック・半導体関連銘柄とS&P 500の推移」）:

```wl
SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch["plot"]
SourceVaultWorkflow`W20260622株価推移ワークフロー2`株価推移ワークフロー2Launch["plot", "Log" -> True]
```
