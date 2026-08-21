# SourceVault_vision API Reference

## Overview
Local (credential-free) vision model assets layer: resolves and installs MediaPipe person-detection / pose-landmark ONNX models (OpenCV Model Zoo, Apache-2.0). Load order: SourceVault.wl -> SourceVault_core.wl -> SourceVault_vision.wl. This file only resolves which model file to use — it does NOT run inference (preprocessing/anchors/NMS live in the consuming OpenCV DNN code, e.g. Python). Scope rationale: person detection / pose estimation is generic reusable local-inference tooling, not owned by any single app (e.g. VRChat integration), and the "frames never leave the machine" requirement matches SourceVault's privacy contract.
Assets live under `$packageDirectory/SourceVault_vision/<model-dir>/<model>.onnx` (+ NOTICE.md). Models are bundled in-repo when present; if missing, `SourceVaultInstallVisionModel` fetches them from source with SHA256 verification.

## Variables
### $SourceVaultVisionRoot
型: String | None, 初期値: None
Override for the local vision-model asset root directory. Set before use to redirect search/install away from defaults.

### $SourceVaultVisionModelCatalog
型: Association (name -> Association)
Catalog of known vision models. Keys currently: "PersonDetector", "PoseEstimator". Each entry: <|"Task", "Directory", "File", "URL", "SHA256", "License", "Source"|>. "Task" is a Japanese description string; "License" is "Apache-2.0"; "Source"/"URL" point to the OpenCV Model Zoo GitHub repo.

## Functions
### SourceVaultVisionSearchPath[] → List[String]
Ordered root directories searched for vision models (deduplicated), in priority: `$SourceVaultVisionRoot` override, then env var `SOURCEVAULT_VISION_ROOT`, then `<packageDirectory>/SourceVault_vision`, then `<LOCALAPPDATA or ~/.local/share>/SourceVault/vision`.

### SourceVaultVisionRoot[] → String
First existing directory among `SourceVaultVisionSearchPath[]`; falls back to the first candidate (possibly non-existent) if none exist; returns "" if the search path is empty.

### SourceVaultVisionModels[] → List[Association]
One entry per catalog model: <|"Name", "Task", "Path" (absolute file path or None), "Present" (Boolean), "License", "Source"|>. "Path"/"Present" reflect whether the file is actually found on any search-path root.

### SourceVaultVisionModel[name_String] → String | Failure
Absolute path to the ONNX file for `name` (a key of `$SourceVaultVisionModelCatalog`, e.g. "PersonDetector"). Returns `Failure["SourceVaultVisionUnknownModel", ...]` if `name` is not in the catalog, or `Failure["SourceVaultVisionModelUnavailable", <|"MessageTemplate", "Hint", "SearchPath"|>]` if not installed.

### SourceVaultVisionStatus[] → Association
Overall status: <|"Status" ("OK" | "Incomplete"), "Missing" (list of model names), "Root", "SearchPath", "Models" (= `SourceVaultVisionModels[]`), "Hint" (None or install instructions string)|>.

### SourceVaultVisionView[] → Column
Displays `SourceVaultVisionStatus[]` as a Grid (status/missing/root) plus a Dataset of models (Name, Task, Present, License, Path) and, if incomplete, a hint block. Notebook-display only.

### SourceVaultInstallVisionModel[name_String] → Association
Downloads and installs one model from its catalog URL with SHA256 verification. Returns <|"Status" -> "OK", "Reason" -> "AlreadyInstalled" | "Installed", "Name", "Path", "License"|> on success, or <|"Status" -> "Error", "Reason" -> "UnknownModel" | "TargetDirectoryUnavailable" | "DownloadFailed" | "ChecksumMismatch" | "InstallFailed", ...|> on failure. Writes into the first entry of `SourceVaultVisionSearchPath[]`.

### SourceVaultInstallVisionModel[] → Association
Installs every catalog model that is not yet present. Returns <|"Status" -> "OK", "Reason" -> "AlreadyInstalled", "Installed" -> {}|> if nothing was missing, else <|"Status" -> "OK", "Results" -> (list of per-model results as above)|>.