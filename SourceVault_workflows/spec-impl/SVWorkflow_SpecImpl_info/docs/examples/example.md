# spec-impl — example

Implement an approved design spec AS a codified SVWorkflow_<Name> package
(context `SourceVaultWorkflow`SpecImpl``). Loaded on demand through the
SourceVault workflow registry.

Roles (inverse of spec-review):
- implementer (plan / implement) → `ClaudeCode`$ClaudeModel`
- verifier (review / verify)      → `ClaudeCode`$ClaudeAdvisaryModel`

```wolfram
Needs["SourceVault`"]                              (* registry is auto-loaded with SourceVault *)
SourceVault`SourceVaultLoadWorkflow["spec-impl"]   (* on-demand load (self-bootstraps deps) *)

SourceVaultWorkflow`SpecImpl`WorkflowInfo[]        (* metadata: slug / launch entry / routes *)

(* implement an approved spec (given as an sv:// URI) into a new workflow named "MyTool" *)
SourceVaultWorkflow`SpecImpl`RunSpecImpl["MyTool",
  "Spec" -> "sv://snapshot/OrchSpec/<hex>",        (* sv:// URI, snapshot ref, or raw spec text *)
  "Notes" -> "Keep the public API minimal; reuse NBAccess for cell IO.",
  "MaxRounds" -> 3]
```

The loop: Plan (single vs multi-stage; if multi, draft a split-implementation
auxiliary spec) → AuxReview (verifier reviews the plan to consensus) → Implement
(implementer writes files) → Verify (verifier checks against the spec) →
{NextStage | Revise} → Approved / Failed.

## Visualize the orchestration net (Petri net)

`BuildNet[name]` builds and registers the ClaudeOrchestrator WorkflowNet and returns
its wid, which `plotPetriNetDetail` / `ClaudeNetPlot` render directly. (The name only
labels the net; the structure is the same — 7 places, 9 transitions.)

```wolfram
Needs["SourceVault`"]
SourceVault`SourceVaultLoadWorkflow["spec-impl"]

(* one-liner: build the net and plot it *)
plotPetriNetDetail[SourceVaultWorkflow`SpecImpl`BuildNet["preview"]]
ClaudeNetPlot[SourceVaultWorkflow`SpecImpl`BuildNet["preview"]]   (* dispatcher; same result *)
```

Use the corresponding builder for the drafting workflow:
`plotPetriNetDetail[SourceVaultWorkflow`SpecReview`BuildNet["preview"]]`
(after `SourceVaultLoadWorkflow["spec-review"]`). The old `OrchWorkflow`OrchBuildSpecReviewNet`
name is migrated and no longer registers a plottable wid.

Output: a new codified package under `SourceVault_workflows/MyTool/`:
`SVWorkflow_MyTool.wl` plus `SVWorkflow_MyTool_info/docs/examples/example.md`
(extra subfiles, if any, are `SVWorkflow_MyTool_<sub>.wl`). It can then be loaded
with `SourceVault`SourceVaultLoadWorkflow["MyTool"]`.

Artifacts/version chains live in SourceVault, exchanged as `sv://` URIs:
`impl/<name>/plan`, `impl/<name>/planreview`, `impl/<name>/artifact`,
`impl/<name>/verify`.

## Palette / factory entry (claudecode)

From the Claude palette, "仕様実装" (Impl) identifies the latest *approved* spec
for the current notebook, derives a workflow name, collects implementation notes
from the selected cell and its neighbours, and launches this workflow in a
background driver. The FE shows the running model and phase in the
WindowStatusArea. On completion it registers the generated workflow's launch
function (session registry + promptrouter route) and writes a summary with a
"launch" button back to the notebook.

```wolfram
ClaudeCode`CreateImplementationWorkflow["MyTool", "sv://snapshot/OrchSpec/<hex>",
  "Notes" -> "..."]                                (* create + register + launch (background) *)
ClaudeCode`LaunchImplementationWorkflow["MyTool"]  (* relaunch a registered workflow *)
```
