# SourceVault 保管先連動 at-rest 暗号化 (閾値 0.95 / Notebook セル・ファイル暗号化) 方策 v0.2

status: 方策ドラフト (r1: FE フリーズ/クラッシュ耐性を組込)。実装未着手。
date: 2026-07-24
親仕様: `sourceVault_encryption_sharing_spec_v18.md` (暗号化正典、以下 v18)。本書は v18 §10「保管先連動の Notebook / SourceVault 保護ポリシー」の**具体化・パラメタ確定・増分計画**であり、暗号プリミティブ・record schema・migration の枠組みは v18 を正とする。

変更履歴:
- **v0.2** (2026-07-24): FE フリーズ耐性を仕様化 — 開封の既定を**表示モード**とする二段構え (§3.4)、FE 応答性 R 規則 (§3.11)、クラッシュ/フリーズ耐性の書込プロトコル W 規則 (§4.1)、Phase 0 にストレス/強制終了試験 (§6-8〜10)。DECISION-2/3 を二段構え案で更新。
- v0.1 (2026-07-24): 初版 (調査+方策)。→ `sourcevault_notebook_atrest_encryption_spec_v0_1.md`

---

## 0. 結論 (実現可能性判定)

**安全に実装可能。ファイル破損リスクは低く抑えられる。最大の実リスクは破損ではなく鍵喪失 (= 可用性) であり、これは前提条件ゲートで遮断する。**

- .nb 構文破損の観点: セル置換は FE 経由 (`NotebookWrite[CellObject, cellExpr]`) で行い、ファイル直列化は FE に任せる。headless 書換えは既存の `iNBFileSaveExpr` (Export→atomic rename→outline cache 正規化, NBAccess.wl:10327-10370) と修復 API 群 (`NBRepairNotebookCache*`) が既に破損対策済み。暗号化 placeholder は正当な `Cell[...]` 式なので、**鍵が無い環境でもノートブックは普通に開ける** (置物セルとして表示されるだけ)。
- データ喪失の観点: 「平文セルは、暗号文の round-trip 検証 (encrypt→decrypt→正準比較) が成功するまで破壊しない」を全経路の不変条件にする。鍵喪失事故は実績が 2 件 (2026-07-13 cognition shard / 2026-07-23 anonymize 鍵、いずれも真因は index blob silent 失敗と Memory backend) あり、対策 (SystemCredential 必須ゲート・fingerprint pin・`~/.nbaccess/key-index.wxf.b64`・`NBRebuildKeyIndexFromCredentials`・keybundle export) は導入済み。本機能はこれらを**暗号化実行の前提条件**として強制する。
- 平文露出の観点: Save menu hook は v18 §10.6 の通り **security boundary にしない** (全保存経路を捕捉できない)。主経路は明示的 SecureSave、hook は補助 UX、**常時 scanner + SIEM が backstop** という三層で担保する。
- **FE 応答性の観点** (v0.2): 既知のフリーズ事故 2 型 — (i) preemptive 文脈からの FE 書換えデッドロック (schedule 照会フリーズの真因と同型)、(ii) 主リンク占有による Dynamic 停止 (メール fetch 120s 型) — を踏まえ、R 規則 (§3.11) でデッドロック要因を**構造的に排除**し、混雑時の挙動を「施錠表示の継続・保存のキュー遅延」という安全側の遅延に限定する。開封時の既定は**表示モード** (§3.4: セル内容は暗号文のまま表示だけ復号) とし、FE 書換えそのものを最小化する。
- **クラッシュ/巻き込まれフリーズの観点** (v0.2): FE/カーネルが**任意の時点で**無応答・強制終了・スリープ・電源断になり得るという故障モデルを置き、「ディスク上のファイルは常に旧完全版か新完全版のどちらか」を全書込経路の不変条件とする W 規則 (§4.1) を必須制約にする。

### 既存 NotebookExtensions.wl 実装の評価

参考にはするが**流用しない**。同型のフロー (encryptCell / decryptSelectedOneCell / "needs encrypted" CellTag / reEncryptAllCells) が存在するものの、以下の欠陥がある:

1. 鍵が旧式単一グローバル (`ToExpression@SystemCredential["enckey-20200118"]`)。鍵材料を平文文字列で取り回し、NBAccess_crypto の keyRef 隔離設計と正反対。
2. `SelectionMove`+`Paste` ベースでセルを置換 (選択状態依存・ユーザー操作と競合・置換先誤り得る)。
3. `decryptSelectedOneCell` は復元セル位置を**位置算術**で推定してタグ付け (セル数計算がずれると誤タグ)。
4. `encryptFile`/`decryptFile` は `EncryptFile`→`DeleteFile` が非アトミック (暗号化失敗検証なしで平文削除の恐れ)。
5. 再暗号化の起動役 `commitTask`/`touchTask` が**未定義** (ボタンを押すとエラー、フロー自体が配線されていない)。
6. `reEncryptAllCells` は修正有無を見ず無差別再暗号化 (毎保存で暗号文が変わり Dropbox diff が荒れる)。
7. `decryptCell` 系に `(* 作成中 *)` コメント、グローバル変数リーク (`decrepteddata`, `dec`, `poss`)。
8. (v0.2 追記) ボタン群が `Method->"Queued"` 未指定 — Button の既定は preemptive 評価で**約 5 秒で無言中断**されるため、FE 書換えを含む処理では中断・デッドロックの温床。

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

v18 §10.6 の判断 (hook は security boundary にしない) を踏襲。「開いたら読める・Ctrl+S で自動再暗号化」という標準操作の UX は第 1+2 層で実現し、hook が効かない経路 (NotebookSave 直呼び、autosave、クラッシュ復元、外部コピー) は第 3 層が拾う。

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
- ciphertext は placeholder の**式の中の Base64 文字列**として保持する (`SourceVaultEncryptedCell` の表示定義で 🔒 + PL バッジ + 表示モードレンダリング (§3.4) ができる)。
- 鍵は専用 keyRef `SourceVault:nbcell:atrest:v1` を新設 (master:atrest と rotation を独立させる)。MAC は既存 `SourceVault:master:mac:v1`。
- **Inline を既定**とする (Dropbox 可搬・sidecar 紛失リスク回避、v18 §10.8-4 と同判断)。payload が閾値サイズ (例 2MB) を超えるセルのみ sidecar。
- 平文由来のメタ (`PublicSummary`/`SearchTokens`/PlaintextDigest) は既定 `Missing` (v18 §7.1 の suppress 規則、PL>=0.75 で既に同様)。

**編集 Unlock 時 (赤枠実体セル)**: 表示モード (§3.4) では placeholder のまま表示だけが変わる。以下の実体セル化は**編集 Unlock 時のみ**行う。元のセル式を復元し、以下を付与:

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

SecureSave 時、Unlock 中セルごとに:

1. **前置フィルタ**: `CurrentValue[cell, CellChangeTimes]` の Max が `UnlockedAt` 以前なら未修正と即断 → RetainedCiphertext をそのまま placeholder に戻す。
2. 変更疑い時: RetainedCiphertext を復号 (ローカル AES、高速) し、現セル式と**正準比較** (`SourceVaultNotebookSemanticHash` の揮発メタ除外規則をセル単位適用: CellChangeTimes / ExpressionUUID / CellID / 赤枠 opts / NBEnc TaggingRules を除外)。一致 → 元暗号文を再利用。不一致 → 新規 Encrypt (新 IV) → **round-trip 検証** → 新 placeholder。

- 平文由来ハッシュを placeholder に**保存しない** (復号比較方式なのでメタ漏洩ゼロ。keyed digest 保存は最適化オプションに留める)。
- 効果: 未修正セルは暗号文バイトが不変 → Dropbox diff 安定・IV 再利用なし・「触っていないのに変わる」churn なし。表示モードのみで閲覧した場合はセル置換自体が起きないため、**開いて読んで閉じるだけならファイルは 1 バイトも変わらない**。

### 3.4 開封時: 二段構え (表示モード既定 + 編集 Unlock) — v0.2 で確定方針

**表示モード (既定)**: `SourceVaultEncryptedCell` の表示定義に Dynamic を持たせ、鍵が使えるカーネルでは**セル内容は暗号文のまま、表示だけ復号して赤枠レンダリング**する。

- ダブルクリックで開くだけで内容が読める (パスワード入力なし — 鍵は SystemCredential 常駐)。
- セル置換をしないため: (a) ノートブックが dirty にならず、閉じるときの保存確認も出ない。(b) ファイルに平文が書かれる可能性が**構造的にゼロ** (保存フックの信頼性に依存しない)。(c) R1 (§3.11) により FE 書換えゼロ = デッドロック要因ゼロ。
- 鍵無しマシン / backend 不備 / カーネル占有中は施錠表示のまま (安全に劣化。ノートブックは普通に操作できる)。
- 復号結果はカーネル側にキャッシュし、2 回目以降の描画は即時 (preemptive 時間制限 ~5s 内に収める)。

**編集 Unlock**: 編集・再評価したいセルだけ、赤枠セルのクリック (または docked バーの Unlock) で in-place 実体セル化 (§3.2 後半)。実行は R2 に従い主リンクの queued 評価。以降は普通のセルとして編集でき、SecureSave (§3.3) が差分だけ再暗号化する。

**施錠**: docked バーの Lock / WindowClose フックで placeholder に戻す (未保存修正があれば SecureSave を先行)。

**docked セキュリティバー**: 施錠状態・鍵状態・**保存キュー状態** (R4) を常時表示し、Unlock / Lock / SecureSave / 診断ボタンを持つ。ボタンは全て `Method->"Queued"` 明示。

### 3.5 ファイル全体暗号化 (.nbenc) — 明示 PL 1.0 ノートブック

- envelope = v18 schema v3 の EncryptedVault record (JSON) に .nb ファイルのバイト列を payload として格納。拡張子 `.nbenc`。低 PL メタ (Title/PL/更新時刻のみ) を sidecar `_meta.json` に置き、onwork スキャナ / searchindex はそれだけを読む (復号不要)。
- **開く**: 復号 → `%LOCALAPPDATA%` 配下の非同期 workdir に平文 .nb を展開 → `NotebookOpen`。ポリシーは保管場所スコープなので、非同期ローカル一時領域の平文は許容 (FE crash recovery が AppData に書くのと同格)。
- **保存/閉じる**: workdir の .nb を再暗号化 → `iCommitCreateOnly` 型 atomic 差替で .nbenc 更新 → round-trip 検証成功後に workdir を掃除。検証失敗時は workdir を残して警告 (平文は消さない)。開閉サイクルは intent journal (W6) で保護。
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

(v0.2) さらに R3 (§3.11) を必須とする: **hook 本体はフラグ設定と主リンクへのキュー投入のみ**。暗号化・`NotebookSave`・セル置換を hook 内で直接実行してはならない (preemptive 文脈からの FE 書換えはデッドロック要因)。

### 3.10 Scanner / SIEM (第 3 層)

- `SourceVaultScanNotebookStorageRisk` / `SourceVaultStorageDoctor` (v18 §10.7) を実装し、同期 root 配下の .nb / snapshot / .nbenc を検査: 高 PL 平文セル残存、placeholder の HMAC 不整合、sidecar 欠落、Encrypted->False の高 PL record。
- diagnostics の SIEM producer 規約 (rule11) に従い登録。service loop / FE tick に組込み。検出時: 安全に再保護できるもの (閉じている・lock 非保持のファイル、W5) は headless 再保護 + event、開いているものは docked bar に警告表示。

### 3.11 FE 応答性設計原則 (R 規則) — フリーズの構造的排除 (v0.2 新設)

既知事故を故障モデルとして明記する: (i) poll-tick (preemptive) 内 `NotebookWrite` × Dynamic の相互待ちデッドロック (schedule 照会フリーズの真因)、(ii) 主リンクのネイティブブロッキング占有で Dynamic が停止 (メール fetch 120s 型 — ClaudeEval の LLM 呼び出しも同類)、(iii) preemptive 評価の約 5 秒制限による無言中断。以下を**必須制約**とし、実装レビュー観点に含める。

- **R1 — Dynamic / preemptive 文脈からの FE 書換え禁止**: `NotebookWrite` / `SetOptions[NotebookObject|CellObject,...]` / `NotebookSave` 等を Dynamic・NotebookEventActions・ScheduledTask (preemptive) の中から呼ばない。表示モードの Dynamic は純計算+描画のみ。`TrackedSymbols->{}` 必須、本体は `Quiet/Check` + `TimeConstrained` で包み (失敗の無限再評価防止)、復号結果はカーネル側 cache。
- **R2 — セル置換は主リンクの queued 評価のみ**: unlock / relock / SecureSave の実体は `SessionSubmit` 型 one-shot タスクとして主リンクに投入。Button は `Method->"Queued"` 明示必須 (既定は preemptive・約 5 秒中断)。主リンク占有中は**待機するだけ** — 施錠表示が続く/保存が遅れるだけで、FE は操作可能なまま。
- **R3 — hook 本体は最小**: 再帰防止フラグ + キュー投入のみ (§3.9)。
- **R4 — 遅延の可視化**: SecureSave がキュー待ちの間は docked バーに「保存キュー中…」を表示。WindowClose 時は完了待ち (または明示警告)。遅延中もディスクは暗号文のままで**安全性は不変**、失われ得るのは編集の鮮度のみ。
- **R5 — 表示モードの時間予算**: 1 セルの復号+描画は preemptive 制限内 (目標 <1s、cache hit は ms 級)。大 payload は初回のみ「復号中…」表示で queued 復号に落とし、cache 完了後に描画。

帰結: フリーズは「素朴実装なら起こる (既知事故と同型)」が、R1-R5 の下では**デッドロックは構造的にゼロ**、主リンク混雑の影響は安全側の遅延 (施錠表示継続・保存キュー) に限定される。

---

## 4. 破損・喪失リスク評価と不変条件

| リスク | 評価 | 対策 (不変条件) |
|---|---|---|
| .nb 構文破損 | **低** | 開いている NB は FE 経由セル置換のみ。headless は `iNBFileSaveExpr` (atomic) + cache 正規化限定。placeholder は正当な Cell 式。 |
| **FE/カーネルのフリーズ・強制終了・電源断に巻き込まれた書込** | **低** | W 規則 (§4.1): 唯一書込経路 = tmp 全体書出→検証→atomic rename。任意時点で死んでも旧完全版が残る。unlock はメモリのみ (W2) なのでフリーズ中の強制終了でもディスク無傷。 |
| 平文喪失 (暗号化事故) | **中 → 低** | W3/W4: 暗号化成功 + round-trip 復号検証 + 正準一致まで平文セル/ファイルを破壊しない。検証失敗時は原本無傷+警告。 |
| 鍵喪失 (最大リスク) | **中 → 低** | `$SourceVaultNBEncAllowVolatileKeys = False` 型ガード (SystemCredential 必須、fail-closed)・fingerprint pin・keybundle export 存在確認を暗号化実行の前提条件に。 |
| FE デッドロック (Dynamic×FE 書換え) | **構造的にゼロ** | R1-R3 (§3.11)。表示モード既定で FE 書換え頻度自体を最小化。 |
| 主リンク占有時の体感フリーズ | 遅延に格下げ | R2/R4/R5: 施錠表示の継続・保存キュー表示。FE は無応答にならない。 |
| hook 迂回の平文保存 | **中 (残存窓あり)** | 三層防御。表示モード既定なら閲覧のみの利用では平文がメモリ外に出ない。残存窓は「Unlock 中の native 保存〜次回 scan」の分オーダー。SIEM event で可視化。 |
| 同時書込 (FE と scanner の競合) | 低 | W5: ファイル単位 lock。scanner は live lock を書き換えない。 |
| マルチマシン | 中 | 鍵は同期しない。keybundle import を各マシンのセットアップ手順に。鍵無しマシンでは施錠表示のまま閲覧・非機密セル編集が可能。マシン間同時編集は Dropbox conflict copy 意味論のまま (双方暗号文なので**conflict copy も安全**)。 |
| undo / NB history / crash recovery の平文残存 | 低 (非同期領域) | AppData 側は保管場所スコープ外で許容。Unlock 時に undo stack へ平文が残る点は v18 §10.8-1 の通り warning。autosave (`NotebookAutoSave`) は保護 NB では強制 False。 |
| ノートブック肥大 / diff churn | 低 | Base64 で約 4/3 倍。§3.3 の暗号文安定性で churn ゼロ。表示モードのみの閲覧はファイル不変。巨大 output は sidecar。 |
| 検索性喪失 | 仕様通り | 暗号化セルは index 対象外 (PL>=0.75 の digest suppress 前例に整合)。低 PL メタ sidecar で所在のみ検索可。 |

### 4.1 クラッシュ/フリーズ耐性の書込プロトコル (W 規則) (v0.2 新設)

**故障モデル**: FE / カーネル / マシンは、他プロセスのフリーズへの巻き込まれ・ユーザーによる強制終了・スリープ・電源断により、**任意の時点で**実行を停止し得る。この下で「保護対象ファイルは常に旧完全版か新完全版のどちらかであり、平文が同期 root に現れない」ことを保証する。

- **W1 — 単一許可書込経路**: 保護対象ファイル (.nb protected / .nbenc / snapshot record) への書込は「同一ボリューム上の tmp へ**全体**書出 → close → 検証 (W4) → atomic rename」のみ。in-place 書込・追記・部分書換は禁止。書込プリミティブは既存 `iNBFileSaveExpr` / `iCommitCreateOnly` (+ overwrite 変種) に一本化する。
- **W2 — ディスク正本は常に暗号文**: Unlock はメモリ内の FE セル置換のみでディスクに触れない。Unlock 中・表示モード中にどの時点で死んでも、ディスク上のファイルは施錠済みのまま無傷。
- **W3 — 生成→検証→破壊の順序**: 平文を消す操作 (初回保護・migration・.nbenc 化) は、新 artifact の完全生成 + 検証成功の**後**にのみ旧を破壊する。逆順・並行は禁止。
- **W4 — rename 前検証**: tmp を再読込し、(a) notebook/record 式としてパース可能、(b) 全 placeholder の HMAC 検証 + 復号 round-trip がメモリ平文と正準一致、(c) PL >= 閾値の平文セルが残っていない (`SourceVaultAssertNoPlaintextLeak`)、の 3 点合格後にのみ rename。不合格なら tmp を破棄し原本無傷のまま警告。
- **W5 — 単一 writer 調整**: ファイル単位 mutex は `%LOCALAPPDATA%` 側の atomic directory lock (path ハッシュキー、PID + heartbeat、stale 期限つき — core の lock 慣行に従う)。FE は Unlock 中 lock を保持し、scanner (§3.10) は live lock のファイルを書き換えず SIEM warning に留める。lock/tmp/journal を同期 root に置かない (Dropbox 経由の lock は既知の壊れ方をするため)。マシン間排他はしない (Dropbox conflict copy 意味論に委ねる — 双方暗号文なので安全)。
- **W6 — 多段操作の intent journal**: .nbenc の開閉・migration のような複数ファイル操作は、開始前に `%LOCALAPPDATA%` の journal (append JSONL) へ intent を記録し、完了で mark する。未完 entry は Doctor が検出して回復手順を提示。**平文 workdir は envelope 検証成功が journal に記録されるまで自動削除しない**。
- **W7 — 初回保護時の backup**: 既存平文 .nb を初めて保護形式へ変換する際は、原本コピーを暗号化 quarantine (または LOCALAPPDATA backup) に保持 (v18 §11 `Backup->True` と同型)。保持期間経過 + 検証済みで掃除。
- **W8 — セル独立性 (部分適用耐性)**: unlock / relock はセル (CellUUID) ごとに独立・冪等で、セル間トランザクション不変条件を持たない。中断で一部セルだけ Unlock された混在状態になっても、SecureSave は placeholder を素通し・Unlock セルのみ処理で正しく動く。再実行はいつでも安全。
- **W9 — stream 衛生**: 全 `OpenWrite` は `WithCleanup` で包み、保護書込の前後に `SourceVaultReleaseFileStreams` を実行 (Abort/フリーズ残留ハンドルによる Dropbox 同期停止・conflicted copy の既知対策)。
- **W10 — tmp にも平文を書かない**: 同期 root 配下に書く tmp は保護済み表現のみ (平文バイトは tmp にすら書かない)。.nbenc の平文 workdir・lock・journal・backup は LOCALAPPDATA 固定。

**SecureSave の書込経路に関する補足**: 書込は kernel 側で完結させる (`NotebookGet` で現状態を読取 → 保護表現へ変換 → W1 経路で書出)。FE が必要なのは**読取だけ**なので、FE がフリーズした場合は書込開始前に停止するだけであり、部分書込は構造的に起きない。v18 §10.5 の「不可視一時 notebook 経由の保存」を使う場合も、保存先は必ず tmp path とし、rename はカーネル側ファイル操作で行う。

---

## 5. 実装増分計画

各 Inc にテストハードゲート (green 必須)。FE 依存部は NB 実機検証 (verify-loop: result*.nb) を伴う。**R 規則 (§3.11)・W 規則 (§4.1) への適合を全 Inc の実装レビュー観点に含める。**

- **Inc0 — Phase 0 実機検証スパイク** (§6)。go/no-go: save hook の発火確実性は問わない (三層設計なので)。placeholder round-trip と表示モード Dynamic の開封時描画が go 条件。
- **Inc1 — 定数と方針の正準化**: `$SourceVaultAtRestEncryptThreshold` / `$SourceVaultConfidentialStandardMax` / StorageProfile 最小実装 (`SourceVaultCloudSyncPathQ` + 二段閾値 [DECISION-1])。privacy.wl 適合テストに閾値ケース追加。
- **Inc2 — nbcell 暗号層 (headless core)**: keyRef 新設・`SourceVaultEncryptedCell` 表現・Cell式⇄placeholder 変換・round-trip 検証・正準セル比較。新規 `SourceVault_nbprotect.wl` (core/View 分離原則に従い FE 非依存)。W1-W4/W8 をこの層の契約として実装+テスト。
- **Inc3 — headless 保護保存 + scanner**: `SourceVaultProtectNotebookForStorage` (閉ファイル対象、`iNBFileSaveExpr` 経由) / `SourceVaultNotebookProtectionReport` / `SourceVaultScanNotebookStorageRisk` / SIEM 接続。W5 lock 調整・W6 journal・W7 backup を含む。強制終了試験 (§6-9) はこの Inc のハードゲート。
- **Inc4 — FE UX**: 表示モード (スタイル定義 Dynamic + 復号キャッシュ、R1/R5)、編集 Unlock / Lock / SecureSave / docked セキュリティバー (R2/R4、`Method->"Queued"` 明示)、赤枠表示。§3.3 の暗号文安定性。
- **Inc5 — Save hook 補助層**: capability report + `NBInstallProtectedSaveHook` (v18 5 条件 + R3)。
- **Inc6 — snapshot 層暗号化 + Cerezo migration**: core 挿入・透過復号・`SourceVaultMigrateToEncrypted` 拡張・CerezoCollectionRun backfill・派生出力ゲート。
- **Inc7 — .nbenc envelope**: 明示 PL1.0 ノートブック用。workdir 運用 (W6)・meta sidecar・legacy .mx migration。
- **Inc8 — PL 既定変更**: Eagle 0.9 / Confidential 0.9 / NBSetNotebookPrivate 0.9 + 明示 1.0 API。既存データへの影響レポート (Eagle record PL >= 0.95 の残存 item 一覧) を添えて切替。

依存: Inc6 は Inc1-2 のみに依存し FE 不要なので、**Cerezo 平文 snapshot の解消を先行させたい場合は Inc3 の後に前倒し可能** (現在進行中の暴露なので優先度高)。

## 6. Phase 0 検証項目 (NB 実機)

1. placeholder round-trip: 数百 KB の Base64 を含む `SourceVaultEncryptedCell` セルを NotebookWrite → 保存 → 再読込 → 復号一致。FE 表示・サイズ上限・保存速度。
2. 表示モード Dynamic: 開封時に自動描画されること、`TrackedSymbols->{}` で再評価嵐が起きないこと、鍵無しカーネルで施錠表示に安全に劣化すること。
3. `{"MenuCommand","Save"}` / `"WindowClose"` hook: 発火有無・既定保存の抑止可否・`FrontEndTokenExecute["Save"]` 再入 guard (Windows FE 実バージョンで)。
4. セル正準比較の安定性: 編集なしで保存/再開封を繰り返してもハッシュ不変 (CellChangeTimes 等の除外が効くこと)。
5. `NotebookWrite[CellObject]` 置換の undo 挙動と、置換直後の CellObject 再取得 (CellUUID で再解決できること)。
6. FE crash recovery / autosave の書出先が同期フォルダ外であることの確認 (`NotebookAutoSave` 既定値含む)。
7. 鍵前提ゲート: Memory backend カーネルで暗号化要求 → fail-closed 拒否メッセージ (MCP 共有カーネル汚染の罠に注意: fresh session で検証)。
8. **主リンク占有ストレス試験** (v0.2): 主リンクを意図的に 60 秒占有した状態で (a) 暗号化 NB を開く — 施錠/表示待ち表示のまま FE が操作可能なこと、(b) Ctrl+S — 「保存キュー中」表示→占有解除後に書込完了すること、(c) 表示モード描画 — 占有解除後に復号表示されること。いずれの間も FE が無応答にならないこと。
9. **強制終了試験** (v0.2): SecureSave / .nbenc 差替の各段階 (tmp 書出中・検証中・rename 直前・rename 直後) でカーネル/FE を強制終了し、(a) 原本が旧完全版のまま無傷 (または新完全版のみ)、(b) 平文が同期 root に残らない、(c) journal/Doctor が未完了を検出、を確認。スリープ→復帰でも同様。
10. **preemptive 制限の確認** (v0.2): 表示モード復号が preemptive 時間制限 (~5s) 内に収まること (大セルは queued 復号+cache 落とし込み、R5)。`Method->"Queued"` の効き。FE の「バックアップファイルを作成」設定 (.nb~) が暗号文版のみを複製することの確認。

## 7. 未決定事項

- **[DECISION-1]** 同期フォルダの MaxPlaintextPL 二段構成 (一般 0.95 / agent 可読 0.45) か一律 0.95 か (§1.4)。→ 推奨: 二段。
- **[DECISION-2]** (v0.2 更新) 開封時の既定は**表示モード**を採用案とする (自動セル置換は行わない — dirty 化回避と R1 の帰結)。残る選択肢は、編集 Unlock の起動を「赤枠セルのクリック」まで許すか、docked バーのボタンに限定するか。
- **[DECISION-3]** (v0.2 更新) SecureSave 後は Unlock 状態を維持し、WindowClose で施錠 (未修正なら RetainedCiphertext 書き戻しで即時) を既定案とする。lock-on-save (保存の度に placeholder へ戻す) は opt-in。
- **[DECISION-4]** Cerezo snapshot 暗号化 (Inc6) の前倒し実施 — 現在 PL 1.0 平文が Dropbox 同期下にあるため、本体より先に単独で走らせる価値がある。
- **[DECISION-5]** 閾値ちょうど 0.95 の扱いは「>= で暗号化」を採用済み (§1.1) — 異議があれば指摘。
