# NBAccess / claudecode / SourceVault: ChatGPT Codex + ClaudeDirectives 管理 実装仕様（第五次レビュー軽微修正版）

作成日: 2026-05-25  
対象: `NBAccess.wl`, `claudecode.wl`, `claudecode_directives.wl`, `SourceVault.wl`, `SourceVault_promptrouter.wl`  
状態: 実装前仕様 / fifth-review-polished draft

---

## 0. この版で修正した最重要点

添付レビューの指摘を受け、前版から次を修正する。

1. **既存の directive 機構が二重であることを前提にする。**
   - 既存の `claudecode_directives.wl` は `Claude Directives/` を読み、`ClaudeResolveDirectiveBundle` + `ClaudeProjectDirectives` で **prompt 用文字列**を作る。
   - 既存の `claudecode.wl` の `iPrepareClaudeProjectDirectory` は `$ClaudeWorkingDirectory/.claude/` を temp project にコピーし、Claude Code CLI 用 harness を作る。
   - これらは現状では別経路であり、前版のように「`.claude/*` は必ず `Claude Directives/` から生成されている」と仮定してはいけない。

2. **`Claude Directives/` を正本にするが、既存 Claude CLI 経路はすぐには置換しない。**
   - ユーザー方針として、正本は `Claude Directives/` とする。
   - ただし MVP では Claude CLI 側の既定は既存互換の `"Direct"`、すなわち `$ClaudeWorkingDirectory/.claude/` コピーを維持する。
   - Codex 新規経路のみ、正本 `Claude Directives/` から harness を materialize する方式を既定にする。

3. **用語を分離する。**
   - 既存の `ClaudeProjectDirectives` は **prompt projection** の意味で維持する。
   - ファイルシステム上に `AGENTS.md`, `.agents/skills`, `.claude/*` を作る処理には `Project` / `Projection` という語を使わず、**Harness Materialization** と呼ぶ。
   - 新規関数名は `ClaudeDirectiveMaterialize...` / `ClaudeEmit...Harness...` 系にする。

4. **`AGENTS.md` へ rules 全結合は禁止する。**
   - 実測では `CLAUDE.md` 単体が 36,466 bytes で、Codex の既定 `project_doc_max_bytes` 32KiB を超える。
   - `rules/*.md` は 30 ファイル合計 218,346 bytes、`skills/*/SKILL.md` は 47 個存在する。
   - したがって `AGENTS.md` は compact bootstrap / index とし、rules / skills は `.agents/skills` や generated rule skill として遅延参照させる。

5. **`$packageDirectory` は write 可能にしない。**
   - Codex の `--add-dir` は追加 root を writable にする前提で説明されているため、`$packageDirectory` や `$ChatgptAccessibleDirs` には原則使わない。
   - write 可能なのは temp project root のみ。
   - `$packageDirectory`, `$ChatgptWorkingDirectory` の参照元、`$ChatgptAccessibleDirs`, NBAccess accessible dirs は read-only として permission profile に明示する。

6. **SourceVault では canonical snapshot と runtime environment を分離する。**
   - `Claude Directives/` の変更は `CanonicalDirectiveSnapshotStale`。
   - permission profile, temp dir, attachments, effective accessible dirs の変更は `RuntimeEnvironmentChanged`。
   - 後者だけで canonical snapshot を stale にしない。

7. **read-only 絶対パス配下の deny rule も明示する。**
   - `:workspace_roots` 配下の deny glob は temp project root などの effective workspace root にだけ相対適用される。
   - `$packageDirectory` や `$ChatgptAccessibleDirs` を absolute path rule で read 許可する場合、その配下の `.env`, `*secret*`, `*credential*`, `*token*` 等も absolute path 側の deny として明示する。
   - `glob_scan_max_depth` は read 許可ディレクトリの深さに合わせて生成し、深い秘密ファイルは `NBAuditCodexAccessibleDirs` で必ず検出する。

8. **Phase 0 を「実装順序の最初」ではなく、移行診断ゲートとして再定義する。**
   - inventory / manifest / hash は Phase 1.0 に実装する。
   - SourceVault の `DirectiveRepository` source kind は Phase 2 に実装する。
   - 旧 `.claude/` と canonical `Claude Directives/` の差分診断は、Phase 1.0 + Phase 2 完了後に Phase 2.5 として実行する。

9. **Codex accessible dirs audit は実行前必須 gate とする。**
   - 既定挙動は `Failure` 停止。
   - deny rule 自動追加は opt-in の補助策であり、危険ファイル検出時に silently 続行しない。

10. **Codex model は固定しない。**
    - `$ChatgptCodexModel = Automatic` を既定にする。
    - `Automatic` の場合、`config.toml` に `model = ...` を書かず、Codex CLI 側の既定に従う。

11. **`rules/*.md` の metadata 実態を仕様に反映する。**
    - 既存 rule は Claude Code 用 `paths:` frontmatter を主に持ち、`description` / `summary` / `trigger` は canonical 側に存在しない前提で扱う。
    - Codex 用 `description` / `trigger` / `summary` は、`paths:` と Markdown 見出しから決定論的に派生する。LLM 要約を既定にしない。
    - rule の always-on / task-specific / large / command-policy 分類は、`paths:` の広さ、byte 数、明示 override に基づく実装契約として定義する。

12. **第五次レビューの軽微な曖昧さを解消する。**
    - `AGENTS.md` overflow は、まず selected rule summary の縮退を尽くし、それでも hard max を超えた場合だけ `FailOnAgentsMdOverflow` に従う。
    - Codex harness の生成順序を、skills → hashes → index → AGENTS.md → provenance として固定する。
    - `ClaudeDirectiveHarnessPlan` の `Index.Entries` は §6.4 の `directive-index.json` entries と同一スキーマにする。
    - Phase 1.1 は Codex harness materialization の pure function を実装対象とし、Claude CLI Generated harness は Phase 4 の opt-in 実装対象とする。

---

## 1. 目的

本仕様の目的は、現状の `claudecode` / `ClaudeRuntime` / `ClaudeOrchestrator` に、ChatGPT Codex CLI を Claude Code CLI と可能な限り同じ運用モデルで追加しつつ、directive / rules / skills の正本管理と派生 harness の版管理を SourceVault に統合することである。

### 1.1 主要要件

- Codex を `openai` API provider ではなく、Claude Code CLI と並ぶ **cloud-backed CLI provider** として扱う。
- Codex は `chatgptcodex` provider 名で識別する。
- Codex のファイルアクセスは最小権限にする。
  - temp project root: read/write
  - `$packageDirectory`: read-only
  - `$ChatgptWorkingDirectory`: 原則 read-only。ただし temp project と同一の場合のみ write
  - `$ChatgptAccessibleDirs`: read-only
  - NBAccess accessible dirs: read-only
  - secrets / `.env` / credential-like files: deny
- `Claude Directives/` を canonical directive repository として SourceVault で snapshot 管理する。
- Codex 用 `AGENTS.md`, `.agents/skills/*`, Codex `config.toml` などは canonical ではなく generated harness artifacts として SourceVault bundle 管理する。
- Claude CLI 用 `.claude/*` も将来的には canonical から materialize 可能にするが、MVP では既存 `Direct` 経路を保つ。

### 1.2 非目的

- `AGENTS.md` や `.agents/skills` から `Claude Directives/` へ逆同期する機能は作らない。
- Codex を private / local LLM として扱わない。
- `ClaudeRuntime` / `ClaudeOrchestrator` に Codex 固有の実行分岐を MVP で直接入れない。
- 既存 Claude CLI 経路を Phase 0 で破壊的に置換しない。
- MVP では `$packageDirectory` 全体を read-only で公開する運用を許容するが、これは privacy 上の含みを持つ。将来課題として、対象ファイルだけを temp project にコピーして Codex に見せる **scoped-source mode** を追加する。

---

## 2. 用語定義

| 用語 | 意味 |
|---|---|
| Directive Repository | canonical な `Claude Directives/` ディレクトリ。`CLAUDE.md`, `rules/*.md`, `skills/*/SKILL.md` を含む。 |
| Prompt Projection | 既存 `ClaudeProjectDirectives[bundle]` が行う、directive bundle から prompt 用文字列への変換。 |
| Harness Materialization | directive repository または既存 `.claude/` から、CLI が実際に読むファイル群を生成する処理。 |
| Harness Files | CLI 用の生成・コピー対象ファイル群。Claude CLI では `.claude/*`、Codex では `AGENTS.md`, `.agents/skills/*`, `CODEX_HOME/config.toml` 等。 |
| Directive Snapshot | SourceVault が保持する canonical `Claude Directives/` の immutable snapshot。 |
| Harness Bundle | SourceVault が保持する harness materialization の生成物 bundle。どの snapshot から生成されたかを provenance として持つ。 |
| Direct Mode | 既存互換。`$ClaudeWorkingDirectory/.claude/` を temp project にコピーする Claude CLI 方式。 |
| Generated Mode | canonical `Claude Directives/` から harness files を materialize する方式。Codex は MVP でこちらを既定にする。 |

### 2.1 命名規則

既存の `ClaudeProjectDirectives` は prompt projection 専用に残す。

禁止する新規名:

```mathematica
ClaudeProjectDirectivesForCodex
ClaudeProjectDirectivesForClaudeCLI
$ClaudeDirectiveProjectionMode = "HybridSkills"
```

採用する新規名:

```mathematica
ClaudeDirectiveMaterializeHarness
ClaudeDirectiveMaterializeCodexHarness
ClaudeDirectiveMaterializeClaudeHarness
ClaudeDirectiveHarnessManifest
ClaudeDirectiveHarnessHash
$ClaudeDirectiveHarnessMaterializationMode
```

---

## 3. 現状の二重 directive 機構

### 3.1 既存機構 A: prompt injection / prompt projection

担当: `claudecode_directives.wl`

主な関数:

```mathematica
ClaudeFindDirectiveRoots[]
ClaudeResolveDirectiveBundle[opts]
ClaudeProjectDirectives[bundle]
ClaudeProjectDirectives[bundle, mode]
```

意味:

- `Claude Directives/` を読む。
- role / task / model / mode に応じて bundle を作る。
- bundle を prompt 用文字列に変換する。

この経路は Runtime / Orchestrator の prompt injection に近い。

### 3.2 既存機構 B: Claude Code CLI harness

担当: `claudecode.wl`

主な関数:

```mathematica
iPrepareClaudeProjectDirectory[]
iInjectSettingsPermissions[settingsFile, dirs]
iCollectAccessibleDirs[]
```

意味:

- `$ClaudeWorkingDirectory/.claude/` を temp project にコピーする。
- `.claude/settings.json` に accessible dirs の read permission を注入する。
- Claude Code CLI に temp project を渡す。

この経路は現状では `claudecode_directives.wl` を参照していない。

### 3.3 この二重構造への対応

MVP では次のように扱う。

| 経路 | 既定 | 理由 |
|---|---|---|
| Claude CLI | `Direct` | 既存安定動作を壊さない。`.claude/` コピー経路を維持する。 |
| Codex CLI | `Generated` | 新規導入なので canonical `Claude Directives/` から materialize する。 |
| Prompt injection | 既存維持 | `ClaudeResolveDirectiveBundle` + `ClaudeProjectDirectives` を壊さない。 |

将来 Phase 4 で Claude CLI も `Generated` に移行できるが、それには Phase 2.5 の migration gate を通す。

---

## 4. Phase 2.5: canonical 確定後の移行診断ゲート

ユーザー方針として `Claude Directives/` を正本にする。ただし、既存 `$ClaudeWorkingDirectory/.claude/` に手編集差分がある可能性があるため、Claude CLI を `Generated` mode に切り替える前に移行診断を必須にする。

この工程は「最初に実装する Phase 0」ではない。`ClaudeDirectiveRepositoryInventory` / `ClaudeDirectiveRepositoryManifest` / `ClaudeDirectiveRepositoryHash` は Phase 1.0 で実装し、SourceVault の `DirectiveRepository` は Phase 2 で実装する。その後に本節の migration gate を実行する。

### 4.1 追加 API

```mathematica
ClaudeDirectiveRepositoryInventory[root_String, opts___]
ClaudeDirectiveRepositoryManifest[root_String, opts___]
ClaudeDirectiveRepositoryHash[root_String, opts___]
ClaudeDirectiveMigrationReport[directiveRoot_String, claudeDir_String, opts___]
ClaudeDirectiveCompareCanonicalAndClaudeHarness[directiveRoot_String, claudeDir_String]
```

### 4.2 `ClaudeDirectiveMigrationReport` の出力

```mathematica
<|
  "CanonicalRoot" -> directiveRoot,
  "LegacyClaudeDir" -> claudeDir,
  "CanonicalHash" -> "sha256-...",
  "LegacyHarnessHash" -> "sha256-...",
  "Status" -> "Equivalent" | "Diverged" | "LegacyOnly" | "CanonicalOnly",
  "FilesOnlyInCanonical" -> {...},
  "FilesOnlyInLegacy" -> {...},
  "FilesChanged" -> {...},
  "LegacyHarnessOnlyFiles" -> {...},
  "RecommendedAction" -> "KeepDirect" | "ManualReview" | "CanSwitchClaudeToGenerated"
|>
```

`CanonicalHash` と `LegacyHarnessHash` は、生のディレクトリ構造をそのまま hash して比較しない。比較前に正規化する。

正規化規則:

- `Claude Directives/CLAUDE.md` と `$ClaudeWorkingDirectory/.claude/CLAUDE.md` を対応付ける。
- `Claude Directives/rules/<name>.md` と `$ClaudeWorkingDirectory/.claude/rules/<name>.md` を対応付ける。
- `Claude Directives/skills/<name>/SKILL.md` と `$ClaudeWorkingDirectory/.claude/skills/<name>/SKILL.md` を対応付ける。
- `.claude/settings.json`, `.claude/settings.local.json`, `.claude/commands/*` など harness 固有ファイルは canonical equivalence hash から除外し、別欄 `LegacyHarnessOnlyFiles` に記録する。
- `FilesOnlyInCanonical`, `FilesOnlyInLegacy`, `FilesChanged` は正規化後の logical path に基づいて出す。

Status 判定規則:

| 条件 | `Status` | `RecommendedAction` |
|---|---|---|
| canonical logical files と legacy logical files が両方存在し、`FilesOnlyInCanonical == {}`, `FilesOnlyInLegacy == {}`, `FilesChanged == {}` | `"Equivalent"` | `"CanSwitchClaudeToGenerated"` |
| canonical logical files と legacy logical files が両方存在し、差分が1件以上ある | `"Diverged"` | `"ManualReview"` |
| canonical logical files が存在せず、legacy logical files だけが存在する | `"LegacyOnly"` | `"ManualReview"` |
| canonical logical files が存在し、legacy logical files が存在しない | `"CanonicalOnly"` | `"CanSwitchClaudeToGenerated"` または初回移行なら `"ManualReview"` |

`LegacyHarnessOnlyFiles` は `Status` 判定には使わない。ただし SourceVault evidence として保存し、`settings.json` などの運用差分を後から確認できるようにする。

### 4.3 移行規則

- `Claude Directives/` が canonical。
- `.claude/` 側から canonical へ自動逆同期しない。
- 差分がある場合は、SourceVault に `LegacyClaudeHarnessSnapshot` として保存し、手動で canonical へ反映する。
- `Claude CLI Generated` への切替は、`ClaudeDirectiveMigrationReport` が `Equivalent` または手動承認済みになってから行う。

---

## 5. `claudecode_directives.wl` の変更仕様

### 5.1 依存関係

`claudecode_directives.wl` は SourceVault に依存しない。

理由:

- directive 読み込み・bundle 解決・prompt projection は軽量な基盤機能として独立させる。
- SourceVault 依存をここへ入れると循環依存が起きやすい。
- SourceVault は公開 pure function を呼んで snapshot 化する。

### 5.2 追加する pure function

```mathematica
ClaudeDirectiveFileInventory[root_String, opts___]
ClaudeDirectiveRepositoryManifest[root_String, opts___]
ClaudeDirectiveRepositoryHash[root_String, opts___]
ClaudeDirectiveRuleDerivedMetadata[ruleRecord_Association, opts___]
ClaudeDirectiveClassifyRule[ruleRecord_Association, opts___]
ClaudeDirectiveHarnessPlan[bundle_Association, target_String, opts___]
ClaudeDirectiveMaterializeHarness[bundle_Association, target_String, targetDir_String, opts___]
ClaudeDirectiveMaterializeCodexHarness[bundle_Association, targetDir_String, opts___]
ClaudeDirectiveMaterializeClaudeHarness[bundle_Association, targetDir_String, opts___]
ClaudeDirectiveHarnessProvenanceHeader[meta_Association]
```

`ClaudeDirectiveFileInventory` / `ClaudeDirectiveRepositoryManifest` の inventory record は Phase 1.0 の実装契約として次のスキーマに固定する。

```mathematica
<|
  "Role" -> "RootInstruction" | "Rule" | "Skill" | "HarnessOnly" | "Other",
  "RelativePath" -> "rules/10-nbaccess.md",
  "LogicalPath" -> "rules/10-nbaccess.md",
  "AbsolutePath" -> "F:/.../Claude Directives/rules/10-nbaccess.md",
  "ContentHash" -> "sha256-...",
  "ByteCount" -> 12345,
  "LineCount" -> 321,
  "Name" -> "10-nbaccess" | Missing["NotApplicable"],
  "Title" -> "NBAccess separation and notebook access rules" | Missing["NotAvailable"],
  "Description" -> "..." | Missing["NotAvailable"],
  "FrontMatter" -> <|...|>,
  "Paths" -> {"**/{NBAccess,claudecode}*.{wl,wls,m,nb}"} | {},
  "TokenEstimate" -> n,
  "ModifiedTime" -> date
|>
```

必須フィールドは `Role`, `RelativePath`, `LogicalPath`, `AbsolutePath`, `ContentHash`, `ByteCount`, `LineCount`, `Name`, `FrontMatter`, `Paths` である。`TokenEstimate` と `ModifiedTime` は表示・診断用であり、`ManifestHash` の入力に入れない。`directive-index.json` の `source_hash` はこの `ContentHash` と同一値を使う。

`Description` は canonical skill frontmatter に存在する場合だけその値を使う。`rules/*.md` では canonical 側に `description` / `summary` / `trigger` が無いことを前提にし、Codex harness 用の説明文は `ClaudeDirectiveRuleDerivedMetadata` が別途決定論的に派生する。

`LogicalPath` は migration report 用の正規化パスである。例えば canonical 側の `rules/X.md` と legacy harness 側の `.claude/rules/X.md` は同じ `LogicalPath -> "rules/X.md"` に正規化する。`settings.json` など canonical に対応しない harness 固有ファイルは `Role -> "HarnessOnly"` とし、canonical equivalence hash から除外する。

`ClaudeDirectiveHarnessPlan` は materialization の dry-run 計画を返す。ファイルを書かずに「何を、どこへ、どの分類で、どの budget 内に生成するか」を決めるための関数であり、`ClaudeDirectiveMaterializeCodexHarness` は原則としてこの plan を実行する薄い wrapper にする。

`ClaudeDirectiveHarnessPlan` の返り値スキーマ:

```mathematica
<|
  "Target" -> "Codex" | "ClaudeCLI",
  "HarnessMaterializationMode" -> "BootstrapIndexSkills" | "InlineMinimal" | "DirectLegacy" | "FullGenerated",
  "DirectiveRepositoryManifestHash" -> "sha256-...",
  "SourceVaultSnapshotId" -> "snap-..." | Missing["NotRegistered"],
  "AgentsMd" -> <|
    "TargetRelativePath" -> "AGENTS.md",
    "EstimatedByteCount" -> n,
    "InlineRuleNames" -> {...},
    "OmittedRuleNames" -> {...},
    "HardMaxBytes" -> 30000
  |>,
  "Index" -> <|
    "TargetRelativePath" -> ".agents/directive-index.json",
    "Entries" -> {...}
  |>,
  "GeneratedSkills" -> {
    <|
      "Kind" -> "rule" | "skill",
      "Name" -> "rule-10-nbaccess",
      "SourceRelativePath" -> "rules/10-nbaccess.md",
      "TargetRelativePath" -> ".agents/skills/rule-10-nbaccess/SKILL.md",
      "Classification" -> <|...|>,
      "DerivedMetadata" -> <|...|>
    |>
  },
  "CommandPolicyRules" -> {},
  "ProvenanceFiles" -> {...},
  "Warnings" -> {...}
|>
```

`ClaudeDirectiveMaterializeCodexHarness` の主要オプション:

```mathematica
"HarnessMaterializationMode" -> "BootstrapIndexSkills"
"SourceVaultSnapshotId" -> Missing["NotRegistered"]
"DirectiveRepositoryManifestHash" -> Automatic
"GenerateDirectiveIndex" -> True
"GenerateProvenance" -> True
"AgentsMdTargetMaxBytes" -> 20000
"AgentsMdHardMaxBytes" -> 30000
"RuleLargeByteThreshold" -> 8192
"AlwaysOnRules" -> Automatic
"RuleMetadataOverrides" -> <||>
"CommandPolicyMaterialization" -> "Disabled"
"DryRun" -> False
"FailOnAgentsMdOverflow" -> True
```

`AlwaysOnRules -> Automatic` は、既存 `$ClaudeAlwaysOnRules` が値を持つ場合はそれを使い、未定義または空なら `paths:` の広さと rule 名から候補を決める。`RuleMetadataOverrides` は canonical を変更せず一時的に `description` / `trigger` / `classification` を補うための opt-in である。既定では LLM 要約や非決定的な分類を行わない。

`ClaudeDirectiveRuleDerivedMetadata[ruleRecord]` と `ClaudeDirectiveClassifyRule[ruleRecord]` の `ruleRecord` は、`ClaudeDirectiveFileInventory` / `ClaudeDirectiveRepositoryInventory` が返す inventory record のうち `Role -> "Rule"` の association と同一スキーマである。したがって `RelativePath`, `ContentHash`, `ByteCount`, `Title`, `FrontMatter`, `Paths` を直接参照できる。`Paths` が空の場合は fallback trigger を生成し、plan の `Warnings` に記録する。

`ClaudeDirectiveHarnessPlan` の `Index["Entries"]` は、§6.4 の `.agents/directive-index.json` の `entries` と同一スキーマにする。`ClaudeDirectiveMaterializeCodexHarness` は、plan の `Index["Entries"]` に `materialized_hash` など生成後に確定する hash を埋めたうえで、そのまま `directive-index.json` に書き出す。

`ClaudeDirectiveMaterializeClaudeHarness` は Phase 4 の opt-in 実装対象である。Phase 1.1 では関数名・共通抽象・plan schema は予約してよいが、必須実装は Codex harness materialization (`ClaudeDirectiveHarnessPlan[..., "Codex", ...]` と `ClaudeDirectiveMaterializeCodexHarness`) に限定する。

### 5.3 `ClaudeFindDirectiveRoots` の再利用

新規に `iResolveClaudeDirectiveRoot` を作らず、既存の `ClaudeFindDirectiveRoots` / `$ClaudeDirectiveRoot = Automatic` 解決を使う。

必要なら薄い wrapper のみ追加する。

```mathematica
ClaudeResolveDirectiveRoot[Automatic] := Module[{roots = ClaudeFindDirectiveRoots[]},
  If[roots === {},
    Failure["DirectiveRootNotFound", <|"Message" -> "No Claude Directives repository was found."|>],
    First[roots]
  ]
]
ClaudeResolveDirectiveRoot[root_String] := If[DirectoryQ[root], root,
  Failure["DirectiveRootNotFound", <|"Root" -> root|>]
]
```

`First @ ClaudeFindDirectiveRoots[]` のように空リストで落ちる実装は禁止する。

### 5.4 `ClaudeResolveDirectiveBundle` の後方互換拡張

既存 usage の `Role`, `Model`, `Mode`, `TaskHint`, `TokenBudget`, `MaxSkills` は維持する。

追加オプション:

```mathematica
"Provider" -> Automatic
"Target" -> "Prompt"       (* "Prompt" | "CodexHarness" | "ClaudeHarness" *)
"HarnessMaterializationMode" -> Automatic
```

ただし、`"Target" -> "Prompt"` のときは既存動作と完全互換にする。

`"Target" -> "CodexHarness"` のときは、bundle に materialization 用メタデータを追加するだけで、`ClaudeProjectDirectives` の意味を変えない。

返り値への追加フィールド:

```mathematica
<|
  ...,
  "ProjectionMode" -> "Summary" | "Full" | "Index" | "Lazy",
  "HarnessTarget" -> "Codex" | "ClaudeCLI" | None,
  "HarnessMaterializationMode" -> "BootstrapIndexSkills" | "InlineMinimal" | "DirectLegacy" | "FullGenerated",
  "DirectiveRepositoryManifestHash" -> "sha256-..."
|>
```

### 5.5 ProjectionMode と HarnessMaterializationMode の分離

既存 `ProjectionMode` は prompt projection の値域を維持する。

```mathematica
"Full" | "Summary" | "Index" | "Lazy" | Automatic
```

新規 `HarnessMaterializationMode` は別軸にする。

```mathematica
"BootstrapIndexSkills"   (* Codex 既定。AGENTS.md は小さく、rules/skills は遅延参照 *)
"InlineMinimal"          (* 最小 always-on rule summary のみ inline *)
"DirectLegacy"           (* 既存 .claude/ コピー。Claude CLI 既定 *)
"FullGenerated"          (* 実験的。全生成。サイズ超過リスクあり、既定にしない *)
```

`"HybridSkills"` という値は採用しない。

Target 別の有効性:

| `Target` | `ProjectionMode` | `HarnessMaterializationMode` | 備考 |
|---|---|---|---|
| `"Prompt"` | 有効。既存 `ClaudeProjectDirectives` の mode として使う。 | `None` または `Missing["NotApplicable"]` | 後方互換最優先。harness file は生成しない。 |
| `"CodexHarness"` | bundle selection / index 作成の参考値として保持してよいが、prompt 文字列化はしない。 | 有効。既定 `"BootstrapIndexSkills"`。 | `ClaudeDirectiveHarnessPlan` → `ClaudeDirectiveMaterializeCodexHarness` の経路。 |
| `"ClaudeHarness"` | 同上。 | 有効。MVP 既定は `"DirectLegacy"`、Generated は opt-in。 | 既存 Claude CLI 経路を壊さない。 |

`ClaudeResolveDirectiveBundle[..., "Target" -> "CodexHarness"]` は、prompt 用文字列を返す API ではない。返り値は harness planning に必要な source inventory / selected rule / selected skill / manifest hash を含む association とする。

## 6. Codex harness materialization

### 6.1 基本方針

Codex 用 harness は canonical `Claude Directives/` から生成する。

生成先は temp project root であり、起動前に完了させる。

```text
<tempProject>/
  AGENTS.md
  .agents/
    skills/
      <existing-skill>/SKILL.md
      rule-<rule-name>/SKILL.md
    directive-index.json
    sourcevault-provenance.json
```

`CODEX_HOME` は temp project 内に置かない。

Codex harness の内部生成順序は、依存関係を固定するため次の順にする。

1. existing skill files と generated rule skill files を生成する。
2. 各 materialized `SKILL.md` の `materialized_hash` を計算する。
3. `directive-index.json` の `entries` を確定し、`directive-index.json` を生成する。
4. `directive-index.json` の hash を計算する。
5. `AGENTS.md` を、確定済み index path/hash を参照して生成する。
6. `.agents/sourcevault-provenance.json` と個別 `.sourcevault.json` を生成する。

`<tempBase>` は `$ChatgptWorkingDirectory` の解決結果である。`$ChatgptWorkingDirectory = Automatic` の場合は、`$TemporaryDirectory/claudecode-chatgpt-codex` 相当の専用一時ベースを作る。`codex_home_*` と `codex_project_*` は同じ temp base 配下の兄弟ディレクトリにする。

```text
<tempBase>/
  codex_home_<uuid>/
    config.toml
    AGENTS.md               # 必要なら global bootstrap。通常は最小または空。
  codex_project_<uuid>/
    AGENTS.md
    .agents/skills/...
```

### 6.2 `AGENTS.md` サイズ方針

Codex の `project_doc_max_bytes` は `AGENTS.md` 読み込み上限である。既定 32KiB を超えないよう、`AGENTS.md` は **compact bootstrap** にする。

目標値:

```mathematica
$CodexAgentsMdTargetMaxBytes = 20000
$CodexAgentsMdHardMaxBytes = 30000
```

`config.toml` では次を設定してよいが、これに依存しない。

```toml
project_doc_max_bytes = 65536
```

理由:

- 既存 `CLAUDE.md` 単体が 36,466 bytes で既定 32KiB を超える。
- rules 全結合では約 250KB となり truncation される。
- 上限を 64KiB に上げても、全結合は成立しない。

### 6.3 `AGENTS.md` の内容

`AGENTS.md` には以下のみ入れる。

1. generated file warning
2. SourceVault provenance summary
3. 最小の universal safety rules summary
4. `Claude Directives/` が canonical であること
5. 詳細 rules / skills は `.agents/skills` にあること
6. NBAccess / claudecode の絶対禁止事項の短い要約
7. ファイルアクセス境界の説明

例:

```markdown
<!-- Generated harness file. DO NOT EDIT. Canonical source: Claude Directives/. -->

# Codex Harness Instructions

This file is generated from the canonical Claude Directives repository.
Do not edit AGENTS.md or .agents/skills directly.

## Critical boundaries

- Never bypass NBAccess for notebook cells, session history, or credentials.
- Treat ChatGPT Codex as a cloud-backed CLI provider, not a private/local model.
- Write only inside the generated temp project. Treat package and accessible directories as read-only unless explicitly instructed by the harness.
- Do not read secret-looking files even if the sandbox would allow it.

## Directive index

Detailed rules and skills are materialized under .agents/skills and indexed in .agents/directive-index.json.
```

### 6.4 `.agents/directive-index.json` のスキーマ

`directive-index.json` は Codex が読める人間可読寄りの JSON とし、SourceVault の完全 record の代替ではなく、harness 内の索引として扱う。

重要な前提として、canonical `rules/*.md` の frontmatter は Claude Code 用の `paths:` を主データ源とする。`description` / `summary` / `trigger` は canonical rule 側に無いものとして扱う。したがって rule entry の `description` / `trigger` は canonical 値ではなく、`paths:` と Markdown 見出しから決定論的に派生した値である。

必須スキーマ:

```json
{
  "schema_version": 1,
  "canonical_format": "ClaudeDirectives",
  "directive_repository": {
    "root_label": "Claude Directives",
    "manifest_hash": "sha256-...",
    "sourcevault_snapshot_id": "snap-..."
  },
  "materialization": {
    "target": "Codex",
    "mode": "BootstrapIndexSkills",
    "generated_at": "2026-05-25T00:00:00Z"
  },
  "entries": [
    {
      "kind": "rule",
      "name": "10-nbaccess",
      "title": "NBAccess separation and notebook access rules",
      "description": "Use when editing files matched by the canonical rule paths for NBAccess and claudecode.",
      "trigger": "Use when editing paths matching **/{NBAccess,claudecode,NotebookExtensions,PresentationListener}*.{wl,wls,m,nb}.",
      "description_source": "derived-from-paths-and-heading",
      "paths": ["**/{NBAccess,claudecode,NotebookExtensions,PresentationListener}*.{wl,wls,m,nb}"],
      "classification": {
        "scope": "task-specific",
        "size_class": "small",
        "inline_summary_in_agents_md": true,
        "command_policy" : false
      },
      "source_relative_path": "rules/10-nbaccess.md",
      "source_hash": "sha256-...",
      "materialized_path": ".agents/skills/rule-10-nbaccess/SKILL.md",
      "materialized_hash": "sha256-..."
    },
    {
      "kind": "skill",
      "name": "nbaccess-notebook-access",
      "description": "Use when working with NBAccess notebook access functions.",
      "description_source": "skill-frontmatter",
      "trigger": "Implicit matching via Codex skill description; explicit reference allowed by skill name.",
      "source_relative_path": "skills/nbaccess-notebook-access/SKILL.md",
      "source_hash": "sha256-...",
      "materialized_path": ".agents/skills/nbaccess-notebook-access/SKILL.md",
      "materialized_hash": "sha256-..."
    }
  ]
}
```

`entries[*].description` と `entries[*].trigger` は Codex が参照できるよう短く書く。SourceVault の内部 bundle record と重複する `hash` / `snapshot_id` は、harness 単体から provenance を読めるようにするための冗長コピーである。

### 6.5 rules の扱い

`rules/*.md` は `AGENTS.md` へ全結合しない。

#### 6.5.1 canonical rule metadata の前提

既存 rule の frontmatter は主に次の形である。

```yaml
---
paths:
  - "**/{NBAccess,claudecode,NotebookExtensions,PresentationListener}*.{wl,wls,m,nb}"
---
```

`description`, `summary`, `trigger` は rule canonical source に存在する前提にしない。存在しない metadata を手で補ったかのように扱う実装は禁止する。Codex harness に必要な `description` / `trigger` / `summary` は次の決定論的規則で生成する。

#### 6.5.2 derived metadata 生成規則

`ClaudeDirectiveRuleDerivedMetadata[ruleRecord]` は次を返す。

```mathematica
<|
  "Title" -> title,
  "Summary" -> summary,
  "Description" -> description,
  "Trigger" -> trigger,
  "DescriptionSource" -> "derived-from-paths-and-heading" | "override" | "fallback",
  "Paths" -> paths
|>
```

生成規則:

1. `Title` は frontmatter 後の最初の Markdown heading から抽出する。見つからない場合は file stem を人間可読化する。
2. `Summary` は `Title` を 120 文字程度に短縮したものにする。rule 本文の長文要約を既定では行わない。
3. `Trigger` は `paths:` から機械生成する。
   - `paths` が `**/*.{wl,wls,m,nb}` や `**/*` のように広い場合: `Use for general Wolfram Language, package, and notebook work matched by this rule.`
   - `paths` が `{NBAccess,claudecode}` など特定名を含む場合: `Use when editing NBAccess or claudecode related files matched by this rule.`
   - `paths` が directory / extension glob のみの場合: `Use when editing paths matching <compact glob list>.`
   - `paths` が無い場合: `Use when the task appears related to <file-stem/title>; no path trigger was declared in the canonical rule.`
4. `Description` は `Trigger` を Codex skill frontmatter 向けに一文へ整形したものにする。
5. LLM 要約は既定では使わない。人手で補いたい場合は `RuleMetadataOverrides` を使い、SourceVault run metadata に override 使用を記録する。

#### 6.5.3 rule 分類規則

`ClaudeDirectiveClassifyRule[ruleRecord]` は次を返す。

```mathematica
<|
  "Scope" -> "always-on" | "task-specific",
  "SizeClass" -> "small" | "large",
  "CommandPolicy" -> True | False,
  "InlineSummaryInAgentsMd" -> True | False,
  "Reason" -> {...}
|>
```

既定値:

```mathematica
$CodexRuleLargeByteThreshold = 8192;
```

分類規則:

| 分類軸 | 既定判定 |
|---|---|
| `SizeClass` | `ByteCount > $CodexRuleLargeByteThreshold` なら `"large"`、それ以外は `"small"`。 |
| `Scope -> "always-on"` | `AlwaysOnRules` option または既存 `$ClaudeAlwaysOnRules` に含まれる rule。これが空の場合は、`paths:` が `**/*` または `**/*.{wl,wls,m,nb}` など全ソース対象に近い rule を候補にする。 |
| `Scope -> "task-specific"` | 上記 always-on でなく、`paths:` が特定ファイル名・特定 package・特定 directory を指す rule。 |
| `CommandPolicy -> True` | 既定では `False`。`.rules` へ変換するには `RuleMetadataOverrides` 等で明示的に `CommandPolicy -> True` を指定する。自然言語 rule から自動推定しない。 |
| `InlineSummaryInAgentsMd` | `Scope == "always-on" && SizeClass == "small"` かつ `AGENTS.md` budget 内の場合のみ `True`。large rule は always-on でも一行参照に留める。 |

`$ClaudeAlwaysOnRules` は usage 宣言だけで値が無い可能性があるため、それに依存し切ってはいけない。未定義または空の場合でも、`paths:` の広さと file name prefix（例: `00-`）から候補を決められるようにする。ただし、候補化は inline full text を意味しない。inline するのは常に短い summary だけである。

#### 6.5.4 `AGENTS.md` 用最小 safety summary

`AGENTS.md` の safety summary は、次の決定論的な固定テンプレート + selected rule summary で作る。

- 固定テンプレート: NBAccess を迂回しない、secret-looking files を読まない、Codex は cloud-backed provider、write は temp project のみ、generated harness を編集しない。
- selected rule summary: `InlineSummaryInAgentsMd -> True` の rule について `Rule: <name> — <Summary>` を1行ずつ加える。
- rule 本文の長文抜粋は入れない。
- `AgentsMdHardMaxBytes` を超える場合は、selected rule summary を減らし、最後に `See .agents/directive-index.json` を残す。
- 縮退を尽くしても固定テンプレート + 最小 provenance + `directive-index.json` 参照が `AgentsMdHardMaxBytes` を超える場合だけ、`FailOnAgentsMdOverflow` の値に従う。既定 `True` では `Failure["AgentsMdOverflow", ...]` を返して materialization を停止する。`False` の場合でも warning を plan と provenance に記録する。

Materialization policy:

| rule 種別 | 生成方法 |
|---|---|
| always-on critical small rule | `AGENTS.md` に短い要約のみ inline。全文は generated rule skill。 |
| large rule | `.agents/skills/rule-<name>/SKILL.md` として materialize。 |
| task-specific rule | generated rule skill として materialize。`description` / `trigger` は `paths:` から派生する。 |
| command policy rule | 明示 override がある場合のみ Codex `.rules` に別途変換。自然言語 rule とは分離する。 |

大きい rule の例は実装時の診断表示には出してよいが、テストには特定 byte 数を固定しない。

### 6.6 generated rule skill 形式

`rules/10-nbaccess.md` は例えば次へ変換する。

```text
.agents/skills/rule-10-nbaccess/SKILL.md
```

内容:

```markdown
---
name: rule-10-nbaccess
description: Use when editing files matched by **/{NBAccess,claudecode,NotebookExtensions,PresentationListener}*.{wl,wls,m,nb}; derived from canonical rule paths.
summary: NBAccess separation and notebook access rules.
source: rules/10-nbaccess.md
source_hash: sha256-...
paths:
  - "**/{NBAccess,claudecode,NotebookExtensions,PresentationListener}*.{wl,wls,m,nb}"
description_source: derived-from-paths-and-heading
---

# Rule: 10-nbaccess

<original rule body>
```

`SKILL.md` に generated frontmatter を足すが、canonical file は変更しない。`summary` / `description` は canonical frontmatter 由来ではなく、§6.5.2 の決定論的派生値である。

### 6.7 existing skills の扱い

`skills/*/SKILL.md` は、既存 frontmatter を保って `.agents/skills/<name>/SKILL.md` にコピーする。

派生先には次のいずれかを付ける。

- 先頭に generated provenance comment を追加する。
- または隣に `.sourcevault.json` を置く。

元の canonical `SKILL.md` は汚さない。

### 6.8 provenance の役割分担

provenance は3層に分ける。

| 場所 | 役割 | SourceVault bundle との関係 |
|---|---|---|
| `AGENTS.md` 冒頭 comment | 人間と Codex に「生成物であり編集禁止」と伝える最小 header。 | bundle id / snapshot id の要約だけを置く。 |
| `.agents/sourcevault-provenance.json` | harness 全体の provenance。 | `HarnessMaterialization` bundle record の軽量コピー。オフライン確認用。 |
| `.agents/skills/<name>/.sourcevault.json` | 個別 skill / rule skill の source 対応。 | 個別ファイルの source path/hash を置く。bundle record の補助索引。 |

正本は SourceVault の `HarnessMaterialization` bundle record であり、harness 内 provenance は再構築・監査を容易にするための冗長 evidence とする。

### 6.9 `.agents` の保護

Codex は `.agents/skills` を skill 探索パスとして読む。生成は Codex 起動前に完了させる。

- `.agents/` は harness artifact として扱う。
- Codex に `.agents/` を編集させない。
- permission profile の deny/write rules で `.agents` を read-only にする。
- `.agents/skills` が実際に Codex CLI の skill 探索対象として読まれることは実機テスト項目にする。

---

## 7. Claude CLI harness materialization

### 7.1 MVP 既定は `Direct`

既存 Claude CLI の既定は変えない。

```mathematica
$ClaudeCLIHarnessMode = "Direct";
```

`"Direct"` は既存 `iPrepareClaudeProjectDirectory[]` の動作を維持する。

- `$ClaudeWorkingDirectory/.claude/` を temp project にコピーする。
- `iInjectSettingsPermissions` で `.claude/settings.json` に read permission を注入する。
- `Claude Directives/` はこの経路に自動注入しない。

### 7.2 Generated Claude harness は opt-in

将来の opt-in:

```mathematica
$ClaudeCLIHarnessMode = "Generated";
```

この場合に限り、canonical `Claude Directives/` から `.claude/CLAUDE.md`, `.claude/rules/*`, `.claude/skills/*`, `.claude/settings.json` を materialize する。

切替条件:

- `ClaudeDirectiveMigrationReport` が `Equivalent` または承認済み。
- 216 + 111 など既存 workflow test が通る。
- SourceVault に materialized Claude harness bundle が登録される。

### 7.3 既存 `.claude/` の SourceVault 管理

`Direct` mode でも、実行時にコピーされた `.claude/` は SourceVault に harness evidence として登録できる。登録 API は §11.3 の `SourceVaultRegisterHarnessMaterialization` に統一する。旧名 `SourceVaultRegisterHarnessBundle` を作る場合は互換 alias に留める。

```mathematica
SourceVaultRegisterHarnessMaterialization[
  "ClaudeCLI",
  copiedFiles,
  <|
    "HarnessMode" -> "Direct",
    "SourceKind" -> "LegacyClaudeDotClaude",
    "SourceRoot" -> FileNameJoin[{$ClaudeWorkingDirectory, ".claude"}],
    "DirectiveRepositorySnapshotId" -> Missing["NotUsedInDirectMode"],
    "DirectiveRepositoryManifestHash" -> Missing["NotUsedInDirectMode"]
  |>
]
```

`Direct` mode の record は「canonical から生成された bundle」ではなく、「legacy harness を実行時 evidence として登録した record」である。`Generated` mode の record と同じ `HarnessMaterialization` kind に入れるが、`HarnessMode` と `SourceKind` で区別する。

これにより、既存 Claude CLI の挙動を壊さず、版管理の入口を作れる。

---

## 8. Codex permission / sandbox 仕様

### 8.1 基本判断

初期選択としては `workspace-write` 相当でよいが、実装では legacy `sandbox_mode = "workspace-write"` を主設定にしない。

Codex permission profiles を使う。

理由:

- `workspace-write` だけでは read 範囲を十分に制御できない。
- permission profiles では filesystem / network rule を分けられる。
- permission profiles と legacy sandbox settings は併用しない。

### 8.2 writable / readable roots

| パス | 権限 | 備考 |
|---|---|---|
| temp project root | write | Codex が編集してよい唯一の root。 |
| `$packageDirectory` | read | 正本パッケージ群。Codex から直接書き換えさせない。 |
| `$ChatgptWorkingDirectory` | 直接公開しない | `codex_home_*` / `codex_project_*` の親 temp base。Codex に渡す writable root は `--cd <codex_project_*>` のみ。 |
| `$ChatgptAccessibleDirs` | read | 追加許可ディレクトリ。Claude CLI の read permission 方針と揃える。 |
| NBAccess accessible dirs | read | notebook 由来の許可ディレクトリ。 |
| attachment dirs | read | 必要な場合のみ。session ごとの runtime environment。 |
| `.env`, credentials, SSH keys 等 | deny | glob / explicit rules で deny。 |

### 8.3 `--add-dir` は原則使わない

Codex CLI の `--add-dir` は追加 root を writable にする用途として説明されている。したがって、`$packageDirectory` や `$ChatgptAccessibleDirs` を read-only にしたい本設計では原則使わない。

必要な read-only path は permission profile の explicit filesystem rules に入れる。

### 8.4 permission profile 例

`CODEX_HOME/config.toml` に生成する。

```toml
# model は $ChatgptCodexModel = Automatic の場合は書かない。
# $ChatgptCodexModel が文字列の場合のみ、例: model = "gpt-5-codex"
default_permissions = "nbaccess-codex"
project_doc_max_bytes = 65536
approval_policy = "never"

[permissions.nbaccess-codex.filesystem]
":minimal" = "read"
# 実装時は read-only root の実階層に応じて生成する。6 は例示値。
glob_scan_max_depth = 6

# Read-only absolute roots. これらは workspace_roots ではない。
"F:/Dropbox/Mathematica-oneDrive/MyPackages" = "read"
"F:/Some/Allowed/ReadOnlyDir" = "read"
"F:/Some/Notebook/AttachmentDir" = "read"

# deny は read 許可した absolute root 配下にも明示する。
"F:/Dropbox/Mathematica-oneDrive/MyPackages/**/*.env" = "deny"
"F:/Dropbox/Mathematica-oneDrive/MyPackages/**/*secret*" = "deny"
"F:/Dropbox/Mathematica-oneDrive/MyPackages/**/*credential*" = "deny"
"F:/Dropbox/Mathematica-oneDrive/MyPackages/**/*token*" = "deny"
"F:/Some/Allowed/ReadOnlyDir/**/*.env" = "deny"
"F:/Some/Allowed/ReadOnlyDir/**/*secret*" = "deny"
"F:/Some/Allowed/ReadOnlyDir/**/*credential*" = "deny"
"F:/Some/Allowed/ReadOnlyDir/**/*token*" = "deny"

[permissions.nbaccess-codex.filesystem.":workspace_roots"]
"." = "write"
".agents" = "read"
".agents/**" = "read"
".codex" = "read"
".codex/**" = "read"
"**/*.env" = "deny"
"**/*secret*" = "deny"
"**/*credential*" = "deny"
"**/*token*" = "deny"

[permissions.nbaccess-codex.network]
enabled = false
```

重要:

- `:workspace_roots` ルールは `--cd <tempProject>` で指定した runtime workspace root に適用される。profile 内で明示した workspace root がある場合はそれにも適用される。
- `workspace_roots` には read-only にしたい package dir を入れない。absolute read-only root は `[permissions.<name>.filesystem]` に個別に置く。
- runtime workspace root は `--cd <tempProject>` に限定する。
- `--permissions-profile nbaccess-codex` を明示指定する。
- `default_permissions` は fallback としても設定する。
- `glob_scan_max_depth` は固定値ではなく、公開する read-only root の実際の深さを見て生成する。permission profile の glob 展開で漏れうる深い秘密ファイルは `NBAuditCodexAccessibleDirs` の深さ制限なしスキャンで検出する。

### 8.5 source exposure mode

MVP では `$packageDirectory` 全体を read-only として Codex に公開する。ただしこれは privacy 上の妥協であり、Codex が未公開研究コードを自律的に読み、内容が cloud LLM に送られ得ることを明示する。

将来追加する制御軸:

```mathematica
$ChatgptCodexSourceExposureMode = "PackageReadOnly" | "ScopedCopy"
```

| mode | 意味 | MVP |
|---|---|---|
| `"PackageReadOnly"` | `$packageDirectory` 等を read-only root として公開する。 | 既定 |
| `"ScopedCopy"` | 対象ファイルだけを temp project にコピーし、元 package tree は公開しない。 | 将来課題 |

`ScopedCopy` はコードレビュー対象が数ファイルに限定できる場合に privacy 的に望ましい。

### 8.6 起動コマンドの概念

```text
CODEX_HOME=<tempBase>/codex_home_<uuid> \
codex exec \
  --cd <tempProject> \
  --permissions-profile nbaccess-codex \
  --ask-for-approval never \
  < prompt.txt
```

または、Codex CLI が stdin prompt を受け取れない版では一時 prompt file を使う。

Windows ではコマンドライン長制限があるため、長い prompt をコマンドライン引数で渡さない。

### 8.7 approval policy

MVP では非対話安定性を優先する。

既定:

```toml
approval_policy = "never"
```

または CLI:

```text
--ask-for-approval never
```

理由:

- `codex exec` の非対話実行で `on-request` が発生した場合の挙動は実機確認が必要。
- approval が必要な操作は fail-closed させる。
- `on-request` は Phase 3 の実機検証後に opt-in とする。

実機検証後、次を追加できる。

```mathematica
$ChatgptCodexApprovalPolicy = "never" | "on-request"
```

### 8.8 `CODEX_HOME` の場所

`CODEX_HOME` は temp project root の外に置く。

理由:

- project-local `.codex/` と global `CODEX_HOME` の役割を混同しないため。
- temp project の writable root 内に config を置くと Codex 自身が変更できる余地が生まれるため。

---

## 9. `claudecode.wl` の変更仕様

### 9.1 provider 名

```mathematica
"chatgptcodex"
"chatgpt-codex"
"codex"
"gptcodex"
```

を正規化して内部 provider は `"chatgptcodex"` にする。

`"chatgpt"` 単独は曖昧なので、MVP では `"openai"` API provider に寄せるか、明示エラーにする。推奨は明示エラー:

```mathematica
"chatgpt" -> Failure["AmbiguousProvider", ...]
```

### 9.2 追加グローバル変数

```mathematica
$ChatgptCodexExe = Automatic;
$ChatgptWorkingDirectory = Automatic;
$ChatgptAccessibleDirs = {};
$ChatgptCodexHomeDirectory = Automatic;
$ChatgptCodexPermissionProfile = "nbaccess-codex";
$ChatgptCodexApprovalPolicy = "never";
$ChatgptCodexModel = Automatic;
$ChatgptCodexHarnessMode = "Generated";
$ChatgptCodexRetainTempProjects = False;
$ChatgptCodexSourceExposureMode = "PackageReadOnly";
```

`$ChatgptWorkingDirectory = Automatic` の場合、`$TemporaryDirectory/claudecode-chatgpt-codex` 配下を temp base として使う。`$ChatgptCodexModel = Automatic` の場合、`config.toml` に `model = ...` を出力せず、Codex CLI の既定モデルに従う。

### 9.3 既存 Claude 変数との対応

| Codex 側 | Claude CLI 側 | 実装方針 |
|---|---|---|
| `$ChatgptWorkingDirectory` | `$ClaudeWorkingDirectory` | 可能なら共通 helper へ抽出。 |
| `$ChatgptAccessibleDirs` | `$ClaudeAccessibleDirs` | 収集ロジックは共通化。ただし Codex は read-only。 |
| `iPrepareChatgptProjectDirectory` | `iPrepareClaudeProjectDirectory` | 名前は分けるが内部 helper を共有。 |
| `iCodexPermissionConfigText` | `iInjectSettingsPermissions` | どちらも harness permission 生成の薄い wrapper とする。 |
| `ClaudeDirectiveMaterializeCodexHarness` | 将来 `ClaudeDirectiveMaterializeClaudeHarness` | file materialization と prompt projection を混同しない。 |

### 9.4 accessible dirs 収集の修正

既存 `iCollectAccessibleDirs[]` は `EvaluationNotebook[]` に依存する箇所がある。Codex runner 新設時に、Claude CLI 経路も含めて次へ改修する。

```mathematica
iCollectAccessibleDirs[nb_: Automatic] := Module[{resolvedNB, nbDirs, attDirs, baseDirs}, ...]
```

ただし `nb_: Automatic` は同期・対話実行時の後方互換 fallback に限定する。非同期化・`ScheduledTask` 化・外部 process 起動の前には、呼び出し側で必ず notebook object を捕捉し、launch spec / project spec に保持する。

Codex 経路:

```mathematica
nb = EvaluationNotebook[];
launchSpec = iBuildCodexLaunchSpec[..., "Notebook" -> nb];
(* worker 側 *)
dirs = iCollectAccessibleDirs[launchSpec["Notebook"]];
```

Claude CLI 経路も同じ方針に揃える。既存 `iPrepareClaudeProjectDirectory` は `iCollectAccessibleDirs[]` を引数なしで呼び続けてはいけない。`ClaudeQueryBg` / Runtime adapter / Orchestrator から Claude CLI harness を準備する時点で notebook を捕捉し、次のように明示的に渡す。

```mathematica
nb = EvaluationNotebook[];
projectSpec = iBuildClaudeLaunchSpec[..., "Notebook" -> nb];
iPrepareClaudeProjectDirectory[..., "Notebook" -> projectSpec["Notebook"]]
```

非同期 worker 側では、Codex / Claude CLI のどちらの経路でも `EvaluationNotebook[]` を再評価しない。これにより、async / `ScheduledTask` 経路で NBAccess accessible dirs が silent に空になる問題を防ぐ。

実装タスクとして、`claudecode.wl` 内の `iPrepareClaudeProjectDirectory[]` 全呼び出し元を洗い出し、`"Notebook" -> nb` を渡すよう改修する。後方互換のため `iPrepareClaudeProjectDirectory[]` 自体は引数なしでも動かしてよいが、その場合は同期・対話実行専用 fallback とし、非同期 / Runtime / Orchestrator 経路では使用しない。

### 9.5 attachment dirs

存在しない `iCurrentSessionAttachmentDirs[]` は使わない。

既存変数 `$iCurrentSessionAttachments` を使う。

```mathematica
iCurrentSessionAttachmentDirs[] := DeleteDuplicates @ Select[
  DirectoryName /@ Select[$iCurrentSessionAttachments, StringQ],
  DirectoryQ
]
```

この helper を新設する場合でも、実体は既存変数を参照するだけにする。

### 9.6 Codex runner

追加関数の概念:

```mathematica
iPrepareChatgptCodexProjectDirectory[opts___]
iPrepareChatgptCodexHomeDirectory[opts___]
iCodexPermissionConfigText[spec_Association]
iBuildCodexExecCommand[spec_Association]
iRunChatgptCodexCLI[prompt_String, opts___]
```

`iRunChatgptCodexCLI` は次を行う。

1. notebook object を捕捉する。
2. accessible dirs を read-only として収集する。
3. `NBAccess`NBAuditCodexAccessibleDirs` で公開予定ディレクトリを監査する。
4. audit が危険ファイルを検出した場合、既定では `Failure` で停止する。明示 opt-in の場合のみ deny rule 自動追加を許す。
5. canonical directive snapshot を SourceVault に登録または取得する。
6. Codex harness を temp project に materialize する。
7. audit 結果を反映した permission profile を作り、`CODEX_HOME/config.toml` を生成する。
8. prompt を file または stdin 経由で渡す。
9. 実行結果と harness bundle id を返す。

返り値例:

```mathematica
<|
  "Provider" -> "chatgptcodex",
  "Model" -> resolvedModel,              (* Automatic の場合は Codex CLI の実行時既定 *)
  "Output" -> text,
  "Raw" -> raw,
  "ExitCode" -> 0,
  "TempProject" -> tempProject,
  "CodexHome" -> codexHome,
  "DirectiveSnapshotId" -> snapId,
  "HarnessBundleId" -> bundleId,
  "RuntimeEnvironmentHash" -> envHash
|>
```

---

## 10. NBAccess の変更仕様

### 10.1 provider max access の正本

provider max access level の正本は NBAccess のみ。

`claudecode` 側 provider registry に `"MaxAccessLevel" -> 0.5` を重複定義しない。

NBAccess 側に追加:

```mathematica
$iProviderMaxAccessLevel["chatgptcodex"] = 0.5;
$iProviderMaxAccessLevel["codex"] = 0.5;
```

または公開 API 経由:

```mathematica
NBAccess`NBSetProviderMaxAccessLevel["chatgptcodex", 0.5]
```

### 10.2 Codex は cloud-backed CLI

Codex は local filesystem sandbox を持つが、LLM 推論は cloud である。

分類:

```mathematica
<|
  "Provider" -> "chatgptcodex",
  "ProviderKind" -> "CLI",
  "NetworkedLLM" -> True,
  "FilesystemSandbox" -> True,
  "TrustDomain" -> "Cloud"
|>
```

PrivacyLevel が cloud 上限を超えるデータは Codex に送らない。

### 10.3 cell privacy と file access の粒度ギャップ

NBAccess は cell / notebook / expression 由来 privacy を扱う。Codex は file 単位で自律的に読む。

したがって以下を仕様上の invariant とする。

```text
Accessible dirs exposed to Codex must not contain files whose contents exceed Codex provider max access level.
```

補助機能:

```mathematica
NBAccess`NBAuditCodexAccessibleDirs[dirs_List, opts___]
```

初期実装では heuristic scan でよい。

- `.env`
- `*secret*`
- `*credential*`
- `*token*`
- API key らしい正規表現
- Mathematica credential store の export file らしきもの

`NBAuditCodexAccessibleDirs` は permission profile 生成前の必須 gate とする。既定動作は `Failure` 停止であり、危険ファイルを見つけた状態で Codex を起動しない。deny rule 自動追加は opt-in の補助動作に限る。自動 deny で続行する場合も、監査結果と追加 deny rule を run metadata / SourceVault bundle に記録する。

この audit は permission profile の `glob_scan_max_depth` に依存せず、既定では深さ制限なしで公開予定 root を走査する。大規模 tree では上限を設けてもよいが、その場合は「未走査範囲あり」として fail-closed にする。

---

## 11. SourceVault 仕様

### 11.1 新 source kind: `DirectiveRepository`

追加 API:

```mathematica
SourceVaultRegisterDirectiveRepository[root_String, opts___]
SourceVaultIndexDirectiveRepository[root_String, opts___]
SourceVaultDirectiveRepositoryStatus[root_String, opts___]
SourceVaultCurrentDirectiveSnapshot[root_String, opts___]
SourceVaultDiffDirectiveSnapshots[old_, new_, opts___]
```

source record:

```mathematica
<|
  "Kind" -> "DirectiveRepository",
  "CanonicalFormat" -> "ClaudeDirectives",
  "Root" -> root,
  "Files" -> fileInventory,
  "ManifestHash" -> manifestHash,
  "SnapshotId" -> snapshotId,
  "CreatedAt" -> DateObject[],
  "Tool" -> "claudecode_directives"
|>
```

### 11.2 ManifestHash 入力規則

`ManifestHash` は以下だけから計算する。

```mathematica
SortBy[
  fileInventory[[All, {"RelativePath", "ContentHash"}]],
  #RelativePath &
]
```

含めないもの:

- absolute path
- modified time
- file size
- token estimate
- role inference
- selected/unused status

理由:

- token estimate は実装変更で揺れる。
- modified time は内容不変でも変わる。
- absolute path は環境依存。

### 11.3 新 bundle kind: `HarnessMaterialization`

`DirectiveProjection` ではなく `HarnessMaterialization` と呼ぶ。

```mathematica
SourceVaultRegisterHarnessMaterialization[target_String, files_List, meta_Association]
```

内部的には `SourceVaultBundleCreate` を呼んでよい。

bundle record:

```mathematica
<|
  "Kind" -> "HarnessMaterialization",
  "Target" -> "Codex" | "ClaudeCLI",
  "HarnessMode" -> "Generated" | "Direct",
  "GeneratedFiles" -> files,
  "DirectiveRepositorySnapshotId" -> snapId,
  "DirectiveRepositoryManifestHash" -> manifestHash,
  "RuntimeEnvironmentHash" -> envHash,
  "PermissionProfileHash" -> permHash,
  "Generator" -> <|
    "Package" -> "claudecode_directives",
    "Function" -> "ClaudeDirectiveMaterializeCodexHarness",
    "HarnessMaterializationMode" -> mode
  |>
|>
```

### 11.4 stale 判定の分離

```mathematica
SourceVaultDirectiveSnapshotStaleQ[bundle_]
SourceVaultHarnessRuntimeEnvironmentChangedQ[bundle_, currentEnv_]
```

| 変化 | 判定 | 必要対応 |
|---|---|---|
| `Claude Directives/` 内容 hash 変化 | `CanonicalDirectiveSnapshotStale` | harness 再生成。 |
| permission profile 変化 | `RuntimeEnvironmentChanged` | `config.toml` 再生成。canonical snapshot は stale にしない。 |
| temp project path 変化 | `RuntimeEnvironmentChanged` | harness bundle は別 run artifact。canonical snapshot は stale にしない。 |
| attachments 変化 | `RuntimeEnvironmentChanged` | read-only dirs / deny rules 再計算。 |

---

## 12. SourceVault prompt router / trust domain

### 12.1 既存語彙を尊重する

既存 `SourceVault_promptrouter.wl` は `AllowedTrustDomains -> {"Local", "Private"}` のような語彙を使う。

前版の `"LocalLLM"`, `"PrivateLLM"`, `"CloudLLM"` を `AllowedTrustDomains` に直接入れない。

### 12.2 対応表

| Route / Provider Label | TrustDomain | 備考 |
|---|---|---|
| `CloudLLM` | `Cloud` | Anthropic / OpenAI API 等。 |
| `ClaudeCodeCLI` | `Cloud` | ファイル sandbox は local でも LLM は cloud。 |
| `ChatGPTCodexCLI` / `chatgptcodex` | `Cloud` | Codex CLI。 |
| `PrivateLLM` | `Private` | ローカルまたは契約上 private とみなす LLM。 |
| `LocalOnly` | `Local` | 完全ローカル処理。 |
| `LocalOpenAICompatible` | `Local` または `Private` | LMStudio 等。設定依存。 |
| `ExternalAPI` | `Cloud` または `External` | API 性質に応じる。 |

### 12.3 privacy >= 0.5 の扱い

既存方針に合わせる。

```mathematica
If[privacyLevel >= 0.5 && !MemberQ[{"Local", "Private"}, resolvedDomain],
  NeedsPrivateModel,
  Permit
]
```

Codex は `resolvedDomain = "Cloud"` なので、privacy >= 0.5 では自動選択しない。

---

## 13. Runtime / Orchestrator の扱い

### 13.1 MVP では必須変更なし

Codex 実行は `claudecode.wl` 側で provider runner として吸収する。

`ClaudeRuntime` / `ClaudeOrchestrator` は model spec を渡すだけでよい。

```mathematica
ClaudeCode`ClaudeBuildRuntimeAdapter[
  "Model" -> {"chatgptcodex", Automatic}
]
```

### 13.2 後続改修

必要になったら次を追加する。

`ClaudeRuntime.wl`:

```mathematica
"DecodeProviderResult" -> Function[{raw, meta}, ...]
```

`ClaudeOrchestrator.wl`:

- trace に `ProviderKind -> "ChatGPTCodexCLI"`
- `HarnessBundleId`
- `DirectiveSnapshotId`
- `RuntimeEnvironmentHash`
- UI 表示名 `ChatGPT Codex`

---

## 14. 実装フェーズ

### Phase 1.0: `claudecode_directives.wl` の inventory / manifest / hash

- `ClaudeDirectiveFileInventory`。
- `ClaudeDirectiveRepositoryManifest`。
- `ClaudeDirectiveRepositoryHash`。
- manifest hash は `{RelativePath, ContentHash}` の正規化済みソート列だけから計算する。
- この subphase は SourceVault に依存しない。

### Phase 1.1: `claudecode_directives.wl` の Codex harness materialization pure function

この Phase の必須実装対象は Codex 系 pure function に限定する。Claude CLI Generated harness は Phase 4 の opt-in 対象であり、ここでは共通抽象・関数名の予約に留めてよい。

- `HarnessMaterializationMode` の追加。
- `ClaudeDirectiveRuleDerivedMetadata`。
- `ClaudeDirectiveClassifyRule`。
- `ClaudeDirectiveHarnessPlan[..., "Codex", ...]`。
- `ClaudeDirectiveMaterializeCodexHarness`。
- `paths:` frontmatter から description / trigger / classification を決定論的に派生する。
- `directive-index.json` 生成。
- provenance header / sidecar 生成。
- `AGENTS.md` overflow は縮退後にのみ `FailOnAgentsMdOverflow` を適用する。
- `ClaudeProjectDirectives` の意味は変更しない。

### Phase 2: SourceVault integration

- `DirectiveRepository` source kind。
- `HarnessMaterialization` bundle kind。
- stale / runtime environment changed の分離。

### Phase 2.1: NBAccess provider / audit support

- `chatgptcodex` の provider max access を NBAccess 側に追加。
- `NBAuditCodexAccessibleDirs` を追加。
- notebook object を明示的に受け取る accessible dirs 収集に対応する。

### Phase 2.2: SourceVault prompt router classification

- `chatgptcodex` を cloud-backed CLI provider として分類する。
- 既存 trust domain 語彙 `{ "Local", "Private" }` と route label の対応を崩さない。

### Phase 2.5: migration gate / canonical 確定後診断

- `ClaudeDirectiveMigrationReport` を実装または有効化。
- `Claude Directives/` と `$ClaudeWorkingDirectory/.claude/` の差分を、正規化済み logical path で出す。
- `Claude Directives/` を canonical として SourceVault に登録済みであることを確認する。
- Claude CLI 既定は `Direct` のまま。
- Claude CLI を `Generated` に切り替えるのは、この gate が `Equivalent` または手動承認済みになってからにする。

### Phase 3: Codex runner

- `chatgptcodex` provider 正規化。
- temp project / CODEX_HOME 生成。
- permission profile 生成。
- prompt file / stdin 渡し。
- result + provenance を返す。

### Phase 4: Claude CLI Generated harness opt-in

- `.claude/*` を canonical から materialize する実験経路。
- `ClaudeDirectiveMaterializeClaudeHarness` の実装。
- `ClaudeDirectiveHarnessPlan[..., "ClaudeCLI", ...]` の Generated mode 対応。
- 既存 tests 通過後に opt-in。
- 既定化はしない。

### Phase 5: Runtime / Orchestrator trace 強化

- provider decoder。
- trace metadata。
- workflow visualization。

---

## 15. 受け入れテスト

### 15.1 directive inventory

- `ClaudeDirectiveFileInventory[root]` が、実ファイルの `ByteCount` と一致する byte count を記録する。
- `rules/*.md` の件数が、実際に列挙した `rules/` 配下の Markdown ファイル数と一致する。
- `skills/*/SKILL.md` の件数が、実際に列挙した skill file 数と一致する。
- `RelativePath`, `LogicalPath`, `ContentHash`, `ByteCount`, `LineCount`, `Role` が全 inventory record に存在する。
- `ManifestHash` が modified time 変更で変化しない。
- `ManifestHash` が token estimate ロジック変更で変化しない。

### 15.2 AGENTS.md materialization

- `AGENTS.md` が `$CodexAgentsMdHardMaxBytes` 未満。
- rules 全文が `AGENTS.md` に入らない。
- large rules が generated rule skill になる。
- rule canonical source に `description` / `summary` / `trigger` が無くても、`paths:` と Markdown heading から derived metadata が生成される。
- `paths:` が無い rule でも fallback trigger が生成され、materialization が失敗しない。ただし warning を plan に記録する。
- `ClaudeDirectiveHarnessPlan[..., "Codex"]` が、書き込みなしで `GeneratedSkills`, `Index`, `AgentsMd`, `Warnings` を返す。
- `ClaudeDirectiveHarnessPlan[..., "Codex"]["Index", "Entries"]` と `.agents/directive-index.json` の `entries` が同一スキーマである。
- `.agents/directive-index.json` に全 rules / skills の source hash と materialized path が入る。
- generated skill 生成後に `materialized_hash` が確定し、その hash が `directive-index.json` に反映される。
- `AGENTS.md` が hard max を超えそうな場合、selected rule summary が縮退し、縮退後も超える場合にだけ `FailOnAgentsMdOverflow` に従って停止する。

### 15.3 permission profile

- temp project root は write 可能。
- `$packageDirectory` は read-only。
- `$ChatgptAccessibleDirs` は read-only。
- `.env` は read 不可。
- `.agents` は read-only。
- `--add-dir` が `$packageDirectory` に使われていない。

### 15.4 NBAccess / privacy

- `NBAccess` provider max access の正本が1箇所。
- `chatgptcodex` の max access が 0.5。
- privacy >= 0.5 の prompt で Codex が自動選択されない。
- Codex 経路と Claude CLI 経路の両方で、async / ScheduledTask でも notebook accessible dirs が silent に消えない。

### 15.5 SourceVault

- canonical change で `CanonicalDirectiveSnapshotStale`。
- attachment dir change では `RuntimeEnvironmentChanged` のみ。
- Codex run record から `DirectiveSnapshotId` と `HarnessBundleId` を追跡できる。

### 15.6 Codex CLI 実機確認 gate

Codex CLI の version 依存項目は §19 に集約する。Phase 3 acceptance test では、§19 の各項目を実機確認し、確認結果を run metadata または実装メモに記録する。

---

## 16. 主要不変条件

```text
Invariant 1:
Claude Directives/ is the only canonical editable directive repository.

Invariant 2:
ClaudeProjectDirectives means prompt-string projection only.
It must not be reused for filesystem harness generation.

Invariant 3:
Codex AGENTS.md, .agents/skills, CODEX_HOME/config.toml, and generated .claude/* are harness artifacts, not canonical sources.

Invariant 4:
No reverse synchronization from generated harness files to Claude Directives/ is permitted.

Invariant 5:
Codex is a cloud-backed CLI provider. Filesystem sandboxing does not make it Local or Private.

Invariant 6:
Codex may write only to the generated temp project root by default.
$packageDirectory and user-accessible directories are read-only unless a separate explicit approval path is added.

Invariant 7:
Canonical directive snapshot staleness and runtime permission/environment changes are distinct.

Invariant 8:
Deny rules must be generated for both :workspace_roots and every absolute read-only root exposed to Codex.

Invariant 9:
$packageDirectory read-only exposure is an MVP compromise. For privacy-sensitive review, prefer future ScopedCopy mode that exposes only task-relevant files.

Invariant 10:
approval_policy = "never" is acceptable only together with fail-closed audit, disabled sandbox network, and temp-project-only writes.
```

---

## 17. 仕様から削除・置換した前版要素

| 前版要素 | 処理 |
|---|---|
| `ClaudeProjectDirectivesForCodex` | 削除。`ClaudeDirectiveMaterializeCodexHarness` に置換。 |
| `$ClaudeDirectiveProjectionMode = "HybridSkills"` | 削除。`$ClaudeDirectiveHarnessMaterializationMode` に置換。 |
| `rules/*.md` を `AGENTS.md` に全結合 | 禁止。bootstrap + generated skills に変更。 |
| `$packageDirectory` を `--add-dir` / workspace write root に入れる | 禁止。read-only explicit filesystem rule に変更。 |
| Claude CLI の既定を `Generated` に変更 | 禁止。MVP 既定は `Direct`。 |
| `iCurrentSessionAttachmentDirs[]` 前提 | 削除。既存 `$iCurrentSessionAttachments` から helper を作る。 |
| provider registry の `MaxAccessLevel` 二重管理 | 禁止。NBAccess を正本にする。 |
| `AllowedTrustDomains -> {"LocalLLM", ...}` | 既存 `{ "Local", "Private" }` 語彙に合わせる。 |

---

## 18. 実装開始順序

最初に着手する順序は次が安全である。

1. `claudecode_directives.wl` Phase 1.0
   - inventory / manifest / hash
   - `ClaudeProjectDirectives` には触らない

2. `claudecode_directives.wl` Phase 1.1
   - rule derived metadata / classification
   - harness plan の純粋関数
   - harness materialization の純粋関数
   - `directive-index.json` schema 出力
   - provenance sidecar 出力

3. `SourceVault.wl`（Phase 2）
   - `DirectiveRepository`
   - `HarnessMaterialization`
   - stale/runtime environment changed 分離

4. `NBAccess.wl`（Phase 2.1）
   - `chatgptcodex` provider max access
   - Codex accessible dirs audit helper
   - explicit notebook capture に対応した accessible dirs API

5. `SourceVault_promptrouter.wl`（Phase 2.2）
   - Codex cloud-backed CLI classification

6. `claudecode.wl`（Phase 3）
   - `chatgptcodex` runner
   - Codex temp project / CODEX_HOME / config generation
   - explicit notebook capture

7. Phase 2.5 migration gate
   - `ClaudeDirectiveMigrationReport`
   - 正規化済み `.claude/` 差分診断

8. Optional
   - Claude CLI `Generated` harness opt-in
   - Runtime / Orchestrator trace metadata

---

## 19. 未確定事項 / Codex CLI 実機確認項目

実機確認項目はこの節に集約する。§15.6 は acceptance gate として本節を参照する。

以下は実装前または Phase 3 中に実機確認する。

1. Codex CLI version。
2. `codex exec` の stdin / prompt file 対応。
3. `--permissions-profile` が現行 CLI で使用可能か。
4. `default_permissions` だけで profile が選ばれるか、CLI で明示指定が必要か。
5. `.agents/skills` の探索範囲。
6. native Windows で permission profile の absolute path read-only rule が期待通り enforced されるか。
7. `on-request` approval の非対話挙動。

これらは仕様のブロッカーではなく、Phase 3 の acceptance test として扱う。



---

## 20. 四次レビュー反映の要約

四次レビューで追加指摘された rule metadata / harness planning / registry 名の問題を含め、次のように仕様へ反映した。

| 指摘 | 反映 |
|---|---|
| §20 では反映済みと書かれていたが、Claude CLI 経路の `EvaluationNotebook[]` 依存が本文未修正 | §9.4 を修正し、`iPrepareClaudeProjectDirectory` を含む Claude CLI 経路でも notebook を事前捕捉して `iCollectAccessibleDirs[nb]` に明示的に渡す方針にした。 |
| §15.1 に固定 byte 数・件数が残っていた | §15.1 を性質テストに変更し、実ファイル列挙結果と inventory の一致を検証する形にした。 |
| §14 に NBAccess / prompt router の phase がなかった | §14 に Phase 2.1 / 2.2 を追加し、§18 の実装順序にも phase 対応を明記した。 |
| §10.3 の audit 既定動作が曖昧だった | §10.3 を §9.6 と同じく、既定 `Failure` 停止、deny 自動追加は opt-in に統一した。 |
| inventory record のフィールド名が未確定だった | §5.2 に `ClaudeDirectiveFileInventory` / repository manifest の record schema を定義し、`source_hash = ContentHash` と明記した。 |
| `$ChatgptWorkingDirectory` が read root のように見えた | §8.2 を修正し、`$ChatgptWorkingDirectory` は temp base であり Codex に直接公開しないと明記した。 |
| `glob_scan_max_depth` が固定値に見えた | §8.4 に「実際の read-only root 深さに応じて生成」と明記し、§10.3 で audit は深さ制限なし・fail-closed とした。 |
| §15.6 と §19 の重複 | §19 に実機確認項目を集約し、§15.6 は acceptance gate として §19 を参照する形にした。 |

| `rules/*.md` の canonical frontmatter に `description` / `summary` / `trigger` が無く、`paths:` が主データ源である | §5.2 / §6.4 / §6.5 / §6.6 を修正し、`paths:` と Markdown heading から Codex 用 metadata を決定論的に派生する仕様にした。 |
| rule 分類規則が未定義だった | §6.5.3 に `SizeClass`, `Scope`, `CommandPolicy`, `InlineSummaryInAgentsMd` の判定規則と 8KiB threshold を定義した。 |
| `ClaudeDirectiveHarnessPlan` の役割が未定義だった | §5.2 に dry-run plan と返り値 schema を追加した。 |
| `ClaudeDirectiveMaterializeCodexHarness` の opts が未定義だった | §5.2 に主要 option 一覧を追加した。 |
| `ClaudeDirectiveMigrationReport` の status 判定規則がなかった | §4.2 に `Equivalent` / `Diverged` / `LegacyOnly` / `CanonicalOnly` の判定表を追加した。 |
| `ProjectionMode` と `HarnessMaterializationMode` の Target 別有効性が曖昧だった | §5.5 に Target × mode の表を追加した。 |
| `SourceVaultRegisterHarnessBundle` と `SourceVaultRegisterHarnessMaterialization` が併存していた | §7.3 を修正し、登録 API を `SourceVaultRegisterHarnessMaterialization` に統一した。 |
| `iPrepareClaudeProjectDirectory` のシグネチャ変更に伴う呼び出し元改修が明記されていなかった | §9.4 に全呼び出し元を洗い出して `"Notebook" -> nb` を渡す実装タスクを追記した。 |
