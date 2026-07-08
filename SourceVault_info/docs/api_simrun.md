# SourceVault_simrun API Reference

パッケージ: `SourceVault`` (context; `SourceVault.wl` から自動ロード)
ファイル: `SourceVault_simrun.wl`
依存: `SourceVault_core.wl` (root 解決 / snapshot / pointer / event)。FrontEnd/NBAccess 非依存 (service-loadable)。

シミュレーション実行クラス (ExecutionClass = "simulation") の共通基盤。3つの柱:

1. **マシンプロファイル共有** — 各 PC のスペック (コア数/メモリ/GPU/nvcc) を実測して Dropbox 共有ストアに記録。仕様生成 (spec-review) はこの表をプロンプトに注入し、「rapterlake4t で CUDA」のようなマシン指定つき仕様を書ける。
2. **参照ベース出力 (SimulationRun)** — バルク出力は `<Dropbox>/udb/simruns/<yyyymmddHHmm>-<machine>-<slug>/` へ書き、SourceVault にはメタデータのみを immutable snapshot (class `"SimulationRun"`) として保存。`sv://snapshot/SimulationRun/<hex>` URI で参照する。pointer は `simrun/<slug>/latest`。
3. **サブカーネル burst / CUDA ゲート** — 「全サブカーネル起動 → 実行 → 停止」と、Nvidia GPU 前提の graceful ゲート + nvcc コンパイル。

## 出力クラス分けの原則 (reference vs inline)

- **reference (このモジュールを使う)**: 数値シミュレーション / パラメータスイープ / GPU ジョブ / 動画・画像バッチ生成 (ComfyUI 等) / 数 MB 超・多数ファイルの出力。バルクは udb 参照フォルダ、vault はメタのみ。戻り値は sv:// URI + 小さな要約。
- **inline (従来どおり)**: 仕様・レビュー・レポート・ノートブック・小さいデータ/プロット。既存の snapshot / deposit 経路をそのまま使う。
- 常に **二層出力**: パラメータと要約は必ず snapshot に (検索可能)、バルクは必ずフォルダに。

## マシンプロファイル

### SourceVaultMachineProfile[opts] → Association
現在のマシンの実測プロファイル (セッション内 memoize)。キー: `MachineName`, `MachineTag`, `OS`, `ProcessorCount`, `MemoryGB`, `WolframVersion`, `GPUs` (`{<|Name, MemoryMB|>...}`; nvidia-smi 実測), `GPUAvailable`, `NvccPath`, `NvccAvailable`, `SubkernelTarget`, `ProbedAtUTC`。
Options: `"Refresh" -> False` (True で再実測)。

### SourceVaultMachineProfileRefresh[] → Association
再実測して共有ストア `<PrivateVault>/machines/<tag>.wl` (Dropbox 同期) に書き込む。**各 PC で一度実行しておくこと** (これが「各PCのスペック共有」の実体)。

### SourceVaultMachineSpecs[] → Association
共有ストアの全マシンプロファイル `<|tag -> profile...|>` (自分は常にライブ実測で上書き)。

### SourceVaultMachineSpecsView[] → Dataset
一覧表示版 (Machine / OS / Cores / MemGB / GPU / GPUMemMB / nvcc / Subkernels / ProbedAtUTC)。

### SourceVaultMachineSpecsText[] → String
仕様生成プロンプト注入用の compact テキスト表。spec-review が自動で使う。

## GPU / CUDA

### SourceVaultGPUAvailableQ[] → True | False
nvidia-smi 実測 (memoize)。

### SourceVaultNvccPath[] → String | Missing["NotFound"]
nvcc を PATH → CUDA_PATH → 既定インストール場所の順で探索 (memoize)。

### SourceVaultCUDARequire[] → Association | Failure
CUDA 実行ゲート。GPU があれば `<|"OK" -> True, "GPUs" -> ...|>`、無ければ `Failure["NoNvidiaGPU", ...]` (メッセージに GPU を持つ既知マシン一覧)。**CUDA ワークフローは "run" の冒頭でこれを呼び、Failure ならそのまま返す。**

### SourceVaultCUDACompile[cuFile, opts] → String | Failure
nvcc -O3 でコンパイルし実行ファイルパスを返す。出力は `<LocalState>/cudabin/<name>-<srchash8>.exe` (ソース内容ハッシュでキャッシュ)。Failure タグ: `"NvccUnavailable"` | `"CompileFailed"` (stderr 抜粋つき)。
Options: `"ExtraArgs" -> {}`, `"Force" -> False`。

## サブカーネル burst

### $SourceVaultSubkernelMax (既定 16)
ライセンスの subkernel 席実測に基づく上限。

### SourceVaultSubkernelTarget[] → Integer
`Min[$ProcessorCount, $SourceVaultSubkernelMax]`。

### SourceVaultWithSubkernels[body] / SourceVaultWithSubkernels[n, body] → body の値
HoldAll。目標数 (既定 = SourceVaultSubkernelTarget[]) までサブカーネルを起動して body を評価し、**body 実行中に増えたカーネル (自分の launch + ParallelMap の暗黙起動を含む) を必ず停止**して license 席を standby に返す。元からあったカーネルは残す。body 内では `ParallelMap` / `ParallelTable` / `DistributeDefinitions` / `ParallelEvaluate` がそのまま使える。

```mathematica
rows = SourceVaultWithSubkernels[
  ParallelMap[worker, paramList, Method -> "FinestGrained"]];
```

## 参照ベース実行フォルダ (SimulationRun)

### $SourceVaultSimRunRoot (既定 Automatic)
Automatic で `<Dropbox>/udb/simruns` (= PrivateVault の親 udb 直下)。テストでは temp パスに上書きする。

### SourceVaultSimRunRoot[] → String

### SourceVaultSimRunCreate[slug] / [slug, params] → Association
`<root>/<yyyymmddHHmm>-<machinetag>-<slug>/` を作成し `<|"RunId", "Folder", "Slug", "Machine", "Params", "StartedAtUTC"|>` を返す (フォルダ内 `run.wl` にも記録)。**バルク出力はすべて `Folder` 配下に書く。**

### SourceVaultSimRunFinalize[run] / [run, extra] → Association | Failure
フォルダのファイル一覧 (相対パス+バイト数) を採取し、メタデータのみを snapshot 化して `<|"Status", "URI", "Ref", "RunId", "Folder", "Files", "TotalBytes"|>` を返す。`extra` は小さな要約のみ (`"Status" -> "Done"|"Failed"`, `"Summary" -> <小assoc>`)。**バルクデータ・画像を extra に入れない。**

### SourceVaultSimRunRecord[uriOrRef] → Association | Missing
SimulationRun snapshot を読む (Params / Files / Machine / FolderSymbolic ...)。

### SourceVaultSimRunFolder[uriOrRefOrRunId] → String | Missing
実行フォルダを現在のマシンの絶対パスへ解決 (udb 相対 `FolderSymbolic` を各 PC の Dropbox root で復元)。未同期なら `Missing["NotSynced", path]`。

### SourceVaultSimRuns[slug] → {uri...}
slug の実行履歴 (新しい順)。

## 典型フロー (ワークフロー "run" 実装の contract)

```mathematica
run = SourceVaultSimRunCreate["my-sim", <|"L" -> 64, "T" -> Range[1.5, 3.5, 0.1]|>];
rows = SourceVaultWithSubkernels[ParallelMap[worker, params]];   (* CPU 並列 *)
(* CUDA なら: gate = SourceVaultCUDARequire[]; If[FailureQ[gate], Return[gate]];
   exe = SourceVaultCUDACompile[cuFile]; ... RunProcess + バイナリI/O ... *)
Export[FileNameJoin[{run["Folder"], "results.wxf"}], rows];      (* バルクはフォルダへ *)
fin = SourceVaultSimRunFinalize[run, <|"Status" -> "Done", "Summary" -> <|"Tc" -> 2.3|>|>];
fin["URI"]   (* -> "sv://snapshot/SimulationRun/..." を戻り値に含める *)
```

見本ワークフロー (SourceVault_workflows/testing/): `sim-ising-parallel`, `sim-randommatrix-parallel` (CPU並列) / `sim-mandelbrot-cuda`, `sim-nbody-cuda` (CUDA) / `turtle-tiling-cpu`, `turtle-tiling-cuda` (TurtleTiling のワークフロー化)。
