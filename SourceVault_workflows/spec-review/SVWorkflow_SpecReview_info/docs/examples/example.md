# spec-review — example

Codex↔Claude spec review-and-revise workflow (context `SourceVaultWorkflow`SpecReview``).
Loaded on demand through the SourceVault workflow registry.

```wolfram
Needs["SourceVault`"]                              (* registry is auto-loaded with SourceVault *)
SourceVault`SourceVaultWorkflows[]                 (* discover codified workflows *)
SourceVault`SourceVaultLoadWorkflow["spec-review"] (* on-demand load (self-bootstraps deps) *)

SourceVaultWorkflow`SpecReview`WorkflowInfo[]      (* metadata: slug / launch entry / routes *)

(* run the review loop synchronously *)
SourceVaultWorkflow`SpecReview`RunSpecReview["myproject",
  "DraftPrompt" -> "Write a small Wolfram Language design spec.",
  "MaxRounds" -> 3]
```

Artifacts (spec/review snapshots + version pointer + handoff events) are stored in
SourceVault under `orch/<project>/spec` and `orch/<project>/review`, exchanged as `sv://` URIs.
