# SourceVault 保管先連動 at-rest 暗号化 (閾値 0.95 / Notebook セル・ファイル暗号化) 方策 v0.1

status: 調査完了・方策ドラフト (レビュー r0)。実装未着手。
date: 2026-07-24
親仕様: `sourceVault_encryption_sharing_spec_v18.md` (暗号化正典、以下 v18)。本書は v18 §10「保管先連動の Notebook / SourceVault 保護ポリシー」の**具体化・パラメタ確定・増分計画**であり、暗号プリミティブ・record schema・migration の枠組みは v18 を正とする。

---

## 0. 結論 (実現可能性判定)

**安全に実装可能。ファイル破損リスクは低く抑えられる。最大の実リスクは破損ではなく鍵喪失 (= 可用性) であり、これは前提条件ゲートで遮断する。**

- .nb 構文破損の観点: セル置換は FE 経由 (`NotebookWrite[CellObject, cellExpr]`) で行い、ファイル直列化は FE に任せる。headless 書換えは既存の `iNBFileSaveExpr` (Export→atomic rename→outline cache 正規化, NBAccess.wl:10327-10370) と修復 API 群 (`NBRepairNotebookCache*`) が既に破損対策済み。暗号化 placeholder は正当な `Cell[...]` 式なので、**鍵が無い環境でもノートブックは普通に開ける** (置物セルとして表示されるだけ)。
- データ喪失の観点: 「平文セルは、暗号文の round-trip 検証 (encrypt→decrypt→正準比較) が成功するまで破壊しない」を全経路の不変条件にする。鍵喪失事故は実績が 2 件 (2026-07-13 cognition shard / 2026-07-23 anonymize 鍵、いずれも真因は index blob silent 失敗と Memory backend) あり、対策 (SystemCredential 必須ゲート・fingerprint pin・`~/.nbaccess/key-index.wxf.b64`・`NBRebuildKeyIndexFromCredentials`・keybundle export) は導入済み。本機能はこれらを**暗号化実行の前提条件**として強制する。
- 平文露出の観点: Save menu hook は v18 §10.6 の通り **security boundary にしない** (全保存経路を捕捉できない)。主経路は明示的 SecureSave、hook は補助 UX、**常時 scanner + SIEM が backstop** という三層で担保する。

### 既存 NotebookExtensions.wl 実装の評価

参考にはするが**流用しない**。同型のフロー (encryptCell / decryptSelectedOneCell / "needs encrypted" CellTag / reEncryptAllCells) が存在するものの、以下の欠陥がある:

1. 鍵が旧式単一グローバル (`ToExpression@SystemCredential["enckey-20200118"]`)。鍵材料を平文文字列で取り回し、NBAccess_crypto の keyRef 隔離設計と正反対。
2. `SelectionMove`+`Paste` ベースでセルを置換 (選択状態依存・ユーザー操作と競合・置換先誤り得る)。
3. `decryptSelectedOneCell` は復元セル位置を**位置算術**で推定してタグ付け (セル数計算がずれると誤タグ)。
4. `encryptFile`/`decryptFile` は `EncryptFile`→`DeleteFile` が非アトミック (暗号化失敗検証なしで平文削除の恐れ)。
5. 再暗号化の起動役 `commitTask`/`touchTask` が**未定義** (ボタンを押すとエラー、フロー自体が配線されていない)。
6. `reEncryptAllCells` は修正有無を見ず無差別再暗号化 (毎保存で暗号文が変わり Dropbox diff が荒れる)。
7. `decryptCell` 系に `(* 作成中 *)` コメント、グローバル変数リーク (`decrepteddata`, `dec`, `poss`)。

再利用する資産: EncryptedObject をノートブック内に置いても長年壊れなかったという**形式安全性の実績**、CellTags ヘルパー (`taggedQ`/`addTag`/`deleteTag`)、docked bar のボタン UI 慣行。

---

## 1. ポリシーの正準化 (数値と意味論)

### 1.1 新定数

```wl
$SourceVaultAtRestEncryptThreshold = 0.95;   (* 同期ストレージ at-rest 暗号化義務の閾値 (>= で発動) *)
$SourceVaultConfidentialStandardMax = 0.9;   (* セル Confidential の標準最大値 *)
```

- **at-rest 規則**: Dropbox / OneDrive / Google Drive / iCloud Drive 等の同期フォルダ (`SourceVaultCloudSyncPathQ`) 配下では、`PL >= 0.95` のデータの平文保存を禁止。格納時に暗号化 (encrypted cell placeholder / EncryptedVault record / .nbenc envelope) されなければならない。
- 境界値は **0.95 を含む** (>=)。ユーザー文言「0.95 とし、それ以上」に従う。
- この閾値は **at-rest (保管) の軸**であり、cloud LLM 送信可否の release gate (0.5 / cloud 閾値) やマーク閾値 (`$SourceVaultPrivacyMarkThreshold = 0.5`) とは独立の軸。既存の release gate は変更しない。

### 1.2 既定 PL の変更 (1.0 → 0.9)

| 対象 | 現状 | 変更 | 実装箇所 |
|---|---|---|---|
| Eagle ライブラリ既定 PL | `$SourceVaultEaglePrivacyLevel = 1.0` | **0.9** | SourceVault_eagle.wl:3637-3638 |
| セル Confidential 既定 level | `NBMarkCellConfidential` 無引数 = 1.0 | **0.9** | NBAccess.wl:2593-2611 |
| ノート全体 Private 宣言時のセル PL | `NBSetNotebookPrivate` → 全セル 1.0 | **0.9** (明示 1.0 指定 API を別途追加) | NBAccess.wl:1946-1951 |
| 汎用 snapshot 未指定既定 | 0.85 | **変更なし** (既に閾値未満) | SourceVault_core.wl:626 |
| Eagle View/PL probe の失敗 fallback 1.0 群 | 1.0 | **変更なし** (fail-closed 維持) | eagle 3653/3671/3690/3728/3744 |
| NBAccess artifact/snapshot PL 欠落 fail-closed | 1.0 | **変更なし** | NBAccess.wl:2640-2641, 2702-2706 |

調査による前提の訂正: 「未指定は 1.0」は実は限定的で、汎用オブジェクト/スナップショット未指定既定は **0.85**、通常セルは **0.0** である。1.0 は (a) Eagle ライブラリ既定、(b) ノート全体 Private 宣言、(c) fail-closed 経路の 3 箇所。**変更するのは (a)(b) の「宣言既定」だけ**とし、(c) の fail-closed 1.0 は維持する。新閾値の下では fail-closed 1.0 の意味論が「PL 不明なデータは同期ストレージには**暗号化しないと保存できない**」に自動的に強化される — これは望ましい安全側の帰結であり、緩めない。

### 1.3 明示 PL 1.0 の義務

- 明示的に PL 1.0 を宣言したノートブックは、同期フォルダ配下では **ファイル全体暗号化 (.nbenc、§3.5)** を義務とする。
- 明示的に PL >= 0.95 のセル (例: 成績データ参照計算の Out セル) は、保存時に**セル暗号化** (§3.2) を義務とする。
- セル表示規則: `0.5 < PL < 0.95` は赤枠マークのみ (従来運用)。`PL >= 0.95` は暗号化セル + 復号表示時も赤枠。

### 1.4 v18 StorageProfile との整合 (要決定)

v18 §10.2 の既定案は `CloudStorage -> MaxPlaintextPL 0.65` であり、本ポリシーの 0.95 は**それより緩い**。二者の関係を次のように整理する (推奨案):

- 一般の Dropbox/OneDrive 同期フォルダ (agent 非可読): `MaxPlaintextPL -> 0.95` (本ポリシーで確定、v18 の 0.65 案を改訂)。
- Claude Code / 外部 agent が workspace として読む path (MyPackages 等): 従来通り低い方を採用し `MaxPlaintextPL -> 0.45` 相当 (v18 §10.3 の AgentReadable 降格規則を維持)。
- つまり 0.95 は「同期ストレージ一般」の閾値であり、agent 可読 path はより厳しいままにする。

→ **[DECISION-1]** この二段構成でよいか、それとも同期フォルダ一律 0.95 か。

---

## 2. 現状資産の調査結果 (要約)

### 2.1 揃っている部品

| 部品 | 実装 | 状態 |
|---|---|---|
| keyRef 隔離暗号 (鍵材料を外に出さない) | `NBEncryptWithKeyRef`/`NBDecryptWithKeyRef` (NBAccess_crypto.wl:250-267) | 実装済・headless 可 |
| encrypt-then-MAC record (AES256-CBC + HMAC-SHA256, schema v3) | `SourceVaultEncryptedPut`/`SourceVaultDecryptRecord` (SourceVault_crypto.wl:634-774) | 実装済 (mail 本文で実運用中) |
| 鍵永続・事故対策 | SystemCredential backend + `~/.nbaccess/key-index.wxf.b64` + fingerprint pin + `NBRebuildKeyIndexFromCredentials` + keybundle (scrypt) | 実装済・実事故 2 件の教訓反映済 |
| 破損しない .nb 書換え | `iNBFileSaveExpr` (tmp→atomic rename→cache 正規化) + `NBRepairNotebookCache*` | 実装済 |
| アトミック書込の正統パターン | `iTmpName`+`iCommitCreateOnly` (SourceVault_core.wl:428-442) | 実装済 |
| 修正検知 | `CellChangeTimes` 直読 (documentation.wl:617) / 揮発メタ除外の正準ハッシュ (`SourceVaultNotebookSemanticHash`, SourceVault.wl:9478-9494, 9569) | 実装済・暗号化フロー未接続 |
| 赤枠セル表示 | `$specCellOpts` 型 CellFrame+Dingbat (claudecode.wl:16555、赤枠版は bak に前例) / `NBMarkCellConfidential` | 実装済 |
| 出力 PL 継承 | 評価スコープ透かし (`SourceVaultNotePrivacy`/`SourceVaultWithPrivacyScope`, SourceVault_privacy.wl) + `SourceVaultEstimateOutputPrivacy` (MaxObservedInput, SourceVault_mcp.wl:847-904) | 実装済 |
| 監査・適合テスト・コミットゲート | SourceVault_privacy.wl (P4/P5) | 実装済 |
| stray stream 掃除 (Dropbox 競合コピー対策) | `SourceVaultFileStreams`/`SourceVaultReleaseFileStreams` | 実装済 |

### 2.2 存在しないもの (新規実装が必要)

- v18 §10 の Notebook 保護 API 群 (`SourceVaultStorageProfile`, `SourceVaultProtectNotebookForStorage`, `SourceVaultEncryptedCell` placeholder, `SourceVaultStorageDoctor` 等) は**仕様のみで未実装** (grep 全滅を確認。identity.wl の `MaxPlaintextPL` は受信者 profile 用の別物)。
- ノートブックの「開いた時 / 保存する時」の自動トリガは repo 全体に**一つも存在しない** (NBAccess.wl:10386 の `NotebookEventActions` 操作は dirty 化トリックであり、イベント登録ではない)。
- 0.95 という閾値定数はコードベースに存在しない (crypto 系の既存 PL 閾値は index/digest 抑制用の `$SourceVaultPrivateThreshold = 0.75` のみ)。

### 2.3 暗号化されるべき既存データの所在

- **Cerezo 生データ (PL 1.0)**: `<Dropbox>\udb\sourcevault\snapshots\CerezoCollectionRun\<xx>\<hex>.json` — **平文 JSON が Dropbox 同期下にある**。snapshot 保存経路 (SourceVault_core.wl:694-710) は現状 `"Encrypted" -> False` を書いている。→ §3.6 で暗号化 + migration。
- メール本文: `SourceVaultEncryptedPut` で暗号化済み (整合、変更不要)。
- 成績 xlsx (`CerezoGradeReport` 出力) 等の派生ファイル: 保存先ゲート対象 (§3.6)。

---

## 3. アーキテクチャ方策

### 3.1 全体構成 (三層防御)

```text
第1層 (主経路)   : 明示的 SecureSave / SecureOpen (docked bar + palette)
第2層 (補助 UX)  : Save menu hook ({"MenuCommand","Save"}, "WindowClose") — capability probe 済み環境のみ
第3層 (backstop) : 常時 scanner (StorageDoctor) + SIEM event + 自動再保護
```

v18 §10.6 の判断 (hook は security boundary にしない) を踏襲。ユーザー要望の「開いたら自動復号・保存時に自動再暗号化」は第 1+2 層の UX として実現し、hook が効かない経路 (NotebookSave 直呼び、autosave、クラッシュ復元、外部コピー) は第 3 層が拾う。

### 3.2 セル暗号化の正準表現 (v18 §10.4 準拠 + 拡張)

**保管時 (placeholder セル)**:

```wl
Cell[
  BoxData @ ToBoxes @ SourceVaultEncryptedCell[<|
    "SchemaVersion" -> 1,
    "CellUUID" -> uuid,                (* 安定 ID。位置算術は使わない *)
    "OriginalCellStyle" -> style,
    "PrivacyLevel" -> pl,
    "ProtectionMode" -> "InlineEncryptedCell",   (* 既定。巨大 output は "SidecarEncryptedRecord" *)
    "KeyRef" -> "SourceVault:nbcell:atrest:v1",
    "Payload" -> encryptedRecord,      (* v18 schema v3 EtM record (inline 時)。sidecar 時は RecordId *)
    "CreatedAt" -> utcIso
  |>],
  "SourceVaultEncrypted",
  CellTags -> {"SourceVaultEncrypted"}
]
```

- 暗号 payload には元の `Cell[...]` 式全体 (CellGroupData も可) を BinarySerialize して入れる。方式は既存 `SourceVaultEncryptedPut` の EtM (AES256-CBC + HMAC-SHA256) をそのまま使う。
- ciphertext は placeholder の**式の中の Base64 文字列**として保持する (TaggingRules でも式でも .nb 上は同じテキスト。式にしておくと `SourceVaultEncryptedCell` の表示定義で 🔒 + PL バッジの置物レンダリングができる)。
- 鍵は専用 keyRef `SourceVault:nbcell:atrest:v1` を新設 (master:atrest と rotation を独立させる)。MAC は既存 `SourceVault:master:mac:v1`。
- **Inline を既定**とする (Dropbox 可搬・sidecar 紛失リスク回避、v18 §10.8-4 と同判断)。payload が閾値サイズ (例 2MB) を超えるセルのみ sidecar。
- 平文由来のメタ (`PublicSummary`/`SearchTokens`/PlaintextDigest) は既定 `Missing` (v18 §7.1 の suppress 規則、PL>=0.75 で既に同様)。

**復号表示時 (赤枠セル)**: 元のセル式を復元し、以下を付与:

```wl
CellFrame -> {{3,3},{1,1}}, CellFrameColor -> RGBColor[0.75,0.15,0.15],
CellDingbat -> "\[WarningSign]",  (* + PL バッジ *)
TaggingRules -> {"SourceVault" -> {"NBEnc" -> <|
    "CellUUID" -> uuid, "PrivacyLevel" -> pl, "KeyRef" -> keyRef,
    "RetainedCiphertext" -> encryptedRecord,   (* 元の暗号 record をそのまま保持 *)
    "UnlockedAt" -> utcIso
|>}}
```

`RetainedCiphertext` が「未修正なら元の暗号化セルのまま」を実現する鍵 (次節)。

### 3.3 未修正セルの暗号文安定性 (要望の核)

SecureSave 時、復号中セルごとに:

1. **前置フィルタ**: `CurrentValue[cell, CellChangeTimes]` の Max が `UnlockedAt` 以前なら未修正と即断 → RetainedCiphertext をそのまま placeholder に戻す。
2. 変更疑い時: RetainedCiphertext を復号 (ローカル AES、高速) し、現セル式と**正準比較** (`SourceVaultNotebookSemanticHash` の揮発メタ除外規則をセル単位適用: CellChangeTimes / ExpressionUUID / CellID / 赤枠 opts / NBEnc TaggingRules を除外)。一致 → 元暗号文を再利用。不一致 → 新規 Encrypt (新 IV) → **round-trip 検証** → 新 placeholder。

- 平文由来ハッシュを placeholder に**保存しない** (復号比較方式なのでメタ漏洩ゼロ。keyed digest 保存は最適化オプションに留める)。
- 効果: 未修正セルは暗号文バイトが不変 → Dropbox diff 安定・IV 再利用なし・「触っていないのに変わる」churn なし (UpcomingSchedule churn 修正と同じ設計思想)。

### 3.4 開封時: SecureOpen (自動復号→赤枠)

- **配線**: NBAccess 管理の docked cell「セキュリティバー」を、`SourceVaultEncrypted` セルを含むノートブックに導入 (`newNote[]` の docked bar 慣行を踏襲)。バーは 施錠状態 / 🔓Unlock / 🔒Lock / SecureSave / 診断 を表示。
- **自動復号**: docked bar 内 Dynamic の once-guard で、開封直後に unlock を発火 (ノートブック TaggingRules `"AutoUnlock" -> True` の opt-in)。鍵が無い・backend 不備のマシンでは placeholder のまま (エラーにせず施錠表示 = fail-closed で、かつファイルは無傷)。
- **復号はメモリ内のみ**: unlock は開いている FE 上のセル置換 (`NotebookWrite[cellObj, ...]`) であり、ファイルには書かない。ノートブックは dirty になるが、保存は SecureSave / hook / scanner が守る。
- 全セル暗号化ではなく該当セルのみ。復号後のセルはその場で普通に編集できる (ユーザー要望どおり)。

### 3.5 ファイル全体暗号化 (.nbenc) — 明示 PL 1.0 ノートブック

- envelope = v18 schema v3 の EncryptedVault record (JSON) に .nb ファイルのバイト列を payload として格納。拡張子 `.nbenc`。低 PL メタ (Title/PL/更新時刻のみ) を sidecar `_meta.json` に置き、onwork スキャナ / searchindex はそれだけを読む (復号不要)。
- **開く**: 復号 → `%LOCALAPPDATA%` 配下の非同期 workdir に平文 .nb を展開 → `NotebookOpen`。ポリシーは保管場所スコープなので、非同期ローカル一時領域の平文は許容 (FE crash recovery が AppData に書くのと同格)。
- **保存/閉じる**: workdir の .nb を再暗号化 → `iCommitCreateOnly` 型 atomic 差替で .nbenc 更新 → round-trip 検証成功後に workdir を掃除。検証失敗時は workdir を残して警告 (平文は消さない)。
- legacy `EncryptFile`+enckey-20200118 の .mx は**読み取り互換のみ** (migration コマンドで .nbenc へ変換)。

### 3.6 snapshot / record / 派生出力 (Cerezo 経路)

- `SourceVaultSaveImmutableSnapshot` (SourceVault_core.wl:694-710 周辺) に挿入: `PL >= $SourceVaultAtRestEncryptThreshold` かつ保存先が同期配下なら payload を `SourceVaultEncryptedPut` で包み、`"Encrypted" -> True` を記録。`SourceVaultLoadImmutableSnapshot` は透過復号。既存呼び出し側 (Cerezo 含む) は無改修で動く。
- **migration**: v18 §11 `SourceVaultMigrateToEncrypted` の対象 kind に immutable snapshot を追加し、既存 `CerezoCollectionRun` (PL 1.0、Dropbox 配下平文 JSON) を DryRun → 実行。Dropbox 版数履歴は回収不能 (`MigrationProtectsCloudHistory -> False`) を報告に明示 (v18 §11.2-10)。
- 派生ファイル出力 (GradeReport xlsx 等): `NBAccessAuthorizeStorageWrite` ゲートを実装し、PL >= 0.95 データの同期配下平文書出を拒否 (代替: 非同期ローカル出力 or 暗号 store 経由)。

### 3.7 出力 PL 継承 (0.95 超データを参照した計算結果)

- ノートブック内評価: 既存の評価スコープ透かし (`SourceVaultNotePrivacy` Max 伝搬 + `NBInstallConfidentialEpilog`) をそのまま使い、評価スコープ最大 PL >= 0.95 の Out セルを「要暗号化」状態 (赤枠 + NBEnc pending タグ) にする。SecureSave がこれを新規暗号化対象として拾う。
- MCP / ジョブ経路: `SourceVaultEstimateOutputPrivacy` (MaxObservedInput 継承) が既にこの意味論。閾値照合を保存側ゲートに追加するだけ。

### 3.8 Eagle の扱い

Eagle ライブラリは外部アプリ管理でありファイル/オブジェクト暗号化は不可能。よって:

- 既定 PL 1.0→0.9 変更 (§1.2) により通常運用は閾値未満に収まる。
- **ポリシー**: `record PL >= 0.95` の item を Eagle に置くことを禁止し、StorageDoctor の検査項目にする (検出時 SIEM warning。自動修復はしない — Eagle DB を外から書き換えない)。本体は SourceVault encrypted store に置き、Eagle には参照のみとする運用を将来課題として記録。

### 3.9 Save hook (第 2 層) の実装条件

v18 §10.6 の 5 条件に従う: notebook-level hook 限定 / `{"MenuCommand","Save"}`・`{"MenuCommand","SaveRename"}`・`"WindowClose"` を `SourceVaultSaveHookCapabilityReport[]` で実機 probe / 再帰防止 flag `$SourceVaultProtectedSaveInProgress` / hook 失敗時に平文保存へ silent fallback せず warning + palette 誘導。`NotebookEventActions` の直接 SetOptions は claudecode lint (28326) が禁止しているため、**NBAccess API (`NBInstallProtectedSaveHook` 等) 経由**で一元管理する。hook はノートブックオプションとしてファイルに永続するため、hook 式は自己完結の薄い起動子 (パッケージ関数呼び出しのみ) とし、パッケージ不在環境では無害に失敗するよう Quiet ガードを入れる。

### 3.10 Scanner / SIEM (第 3 層)

- `SourceVaultScanNotebookStorageRisk` / `SourceVaultStorageDoctor` (v18 §10.7) を実装し、同期 root 配下の .nb / snapshot / .nbenc を検査: 高 PL 平文セル残存、placeholder の HMAC 不整合、sidecar 欠落、Encrypted->False の高 PL record。
- diagnostics の SIEM producer 規約 (rule11: probe 実体は producer 所有、sink 存在時のみ弱結合 emit) に従い登録。service loop / FE tick に組込み (mailagenda / Cane と同型)。検出時: 安全に再保護できるもの (閉じているファイル) は headless 再保護 + event、開いているものは docked bar に警告表示。

---

## 4. 破損・喪失リスク評価と不変条件

| リスク | 評価 | 対策 (不変条件) |
|---|---|---|
| .nb 構文破損 | **低** | 開いている NB は FE 経由セル置換のみ。headless は `iNBFileSaveExpr` (atomic) + cache 正規化限定。placeholder は正当な Cell 式。 |
| 平文喪失 (暗号化事故) | **中 → 低** | I-1: 暗号化成功 + round-trip 復号検証 + 正準一致まで平文セル/ファイルを破壊しない。I-2: ファイル差替は tmp+rename、検証失敗時は原本無傷。 |
| 鍵喪失 (最大リスク) | **中 → 低** | I-3: `$SourceVaultNBEncAllowVolatileKeys = False` 型ガード — backend が SystemCredential でなければ暗号化を fail-closed 拒否 (anonymize と同型)。I-4: fingerprint pin 照合。I-5: keybundle export (scrypt) が存在しない場合、初回暗号化時に作成を強制。 |
| hook 迂回の平文保存 | **中 (残存窓あり)** | 三層防御。残存窓は「保存〜次回 scan」の分オーダー。SIEM event で可視化。Dropbox 版数履歴に残った平文は回収不能である旨を Doctor が明示。 |
| マルチマシン | 中 | 鍵は同期しない (Dropbox に鍵を置くと壊れる — 学習済み)。keybundle import を各マシンのセットアップ手順に。鍵無しマシンでは施錠表示のまま閲覧・非機密セル編集が可能 (graceful degradation)。 |
| undo / NB history / crash recovery の平文残存 | 低 (非同期領域) | AppData 側は保管場所スコープ外で許容。in-place 施錠時に undo stack へ平文が残る点は v18 §10.8-1 の通り warning 表示。autosave (`NotebookAutoSave`) は保護 NB では強制 False。 |
| ノートブック肥大 / diff churn | 低 | Base64 で約 4/3 倍。未修正セルの暗号文安定性 (§3.3) で churn ゼロ。巨大 output は sidecar。 |
| 検索性喪失 | 仕様通り | 暗号化セルは index 対象外 (PL>=0.75 の digest suppress 前例に整合)。低 PL メタ sidecar で所在のみ検索可。 |

---

## 5. 実装増分計画

各 Inc にテストハードゲート (green 必須)。FE 依存部は NB 実機検証 (verify-loop: result*.nb) を伴う。

- **Inc0 — Phase 0 実機検証スパイク** (§6)。go/no-go: save hook の発火確実性は問わない (三層設計なので)。placeholder round-trip と docked Dynamic 開封発火が go 条件。
- **Inc1 — 定数と方針の正準化**: `$SourceVaultAtRestEncryptThreshold` / `$SourceVaultConfidentialStandardMax` / StorageProfile 最小実装 (`SourceVaultCloudSyncPathQ` + 二段閾値 [DECISION-1])。privacy.wl 適合テストに閾値ケース追加。
- **Inc2 — nbcell 暗号層 (headless core)**: keyRef 新設・`SourceVaultEncryptedCell` 表現・Cell式⇄placeholder 変換・round-trip 検証・正準セル比較。新規 `SourceVault_nbprotect.wl` (core/View 分離原則に従い FE 非依存)。
- **Inc3 — headless 保護保存 + scanner**: `SourceVaultProtectNotebookForStorage` (閉ファイル対象、`iNBFileSaveExpr` 経由) / `SourceVaultNotebookProtectionReport` / `SourceVaultScanNotebookStorageRisk` / SIEM 接続。
- **Inc4 — FE UX**: NBAccess 側 unlock/lock/SecureSave/docked セキュリティバー/赤枠表示/AutoUnlock opt-in。§3.3 の暗号文安定性。
- **Inc5 — Save hook 補助層**: capability report + `NBInstallProtectedSaveHook` (5 条件遵守)。
- **Inc6 — snapshot 層暗号化 + Cerezo migration**: core 挿入・透過復号・`SourceVaultMigrateToEncrypted` 拡張・CerezoCollectionRun backfill・派生出力ゲート。
- **Inc7 — .nbenc envelope**: 明示 PL1.0 ノートブック用。workdir 運用・meta sidecar・legacy .mx migration。
- **Inc8 — PL 既定変更**: Eagle 0.9 / Confidential 0.9 / NBSetNotebookPrivate 0.9 + 明示 1.0 API。既存データへの影響レポート (Eagle record PL >= 0.95 の残存 item 一覧) を添えて切替。

依存: Inc6 は Inc1-2 のみに依存し FE 不要なので、**Cerezo 平文 snapshot の解消を先行させたい場合は Inc3 の後に前倒し可能** (現在進行中の暴露なので優先度高)。

## 6. Phase 0 検証項目 (NB 実機)

1. placeholder round-trip: 数百 KB の Base64 を含む `SourceVaultEncryptedCell` セルを NotebookWrite → 保存 → 再読込 → 復号一致。FE 表示・サイズ上限・保存速度。
2. docked bar Dynamic の開封時発火 (once-guard 動作、鍵無しカーネルでの無害性)。
3. `{"MenuCommand","Save"}` / `"WindowClose"` hook: 発火有無・既定保存の抑止可否・`FrontEndTokenExecute["Save"]` 再入 guard (Windows FE 実バージョンで)。
4. セル正準比較の安定性: 編集なしで保存/再開封を繰り返してもハッシュ不変 (CellChangeTimes 等の除外が効くこと)。
5. `NotebookWrite[CellObject]` 置換の undo 挙動と、置換直後の CellObject 再取得 (CellUUID で再解決できること)。
6. FE crash recovery / autosave の書出先が同期フォルダ外であることの確認 (`NotebookAutoSave` 既定値含む)。
7. 鍵前提ゲート: Memory backend カーネルで暗号化要求 → fail-closed 拒否メッセージ (MCP 共有カーネル汚染の罠に注意: fresh session で検証)。

## 7. 未決定事項

- **[DECISION-1]** 同期フォルダの MaxPlaintextPL 二段構成 (一般 0.95 / agent 可読 0.45) か一律 0.95 か (§1.4)。→ 推奨: 二段。
- **[DECISION-2]** AutoUnlock の既定: opt-in (推奨) か、鍵があれば常に自動復号か。
- **[DECISION-3]** SecureSave 後のセル状態: 平文表示のまま継続 (既定案、閉じるときに施錠) か、保存の度に placeholder へ戻す (lock-on-save) か。
- **[DECISION-4]** Cerezo snapshot 暗号化 (Inc6) の前倒し実施 — 現在 PL 1.0 平文が Dropbox 同期下にあるため、本体より先に単独で走らせる価値がある。
- **[DECISION-5]** 閾値ちょうど 0.95 の扱いは「>= で暗号化」を採用済み (§1.1) — 異議があれば指摘。
