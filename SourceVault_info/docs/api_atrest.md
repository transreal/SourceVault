# SourceVault_atrest API リファレンス

## 概要
パッケージ: SourceVault_atrest (https://github.com/transreal/SourceVault_atrest)。コンテキストは `SourceVault``。依存は NBAccess、NBAccess_crypto、SourceVault_crypto、SourceVault_core。これらを先に読み込んでおく。
学生・成績などを保存時に暗号化する。段 (Tier) ごとに扱いを変える。
読み込み: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_atrest.wl"]]`
設計: 計画は 2026-11-14 に所有者が承認した。

段 (Tier)
- 1: PL >= 0.95。多要素認証が必須。今は鍵を SystemCredential に暫定で置く。svfido の PRF ができたら鍵だけ包み直す。データは暗号化し直さない。
- 2: AL < PL < 0.95。SystemCredential の鍵で暗号化する。AL は保管先の AccessLevel。
- 3: PL <= AL。平文でよい。

鍵
- 鍵の組 (KeyGroup) ごとに enc (AES-256-CBC) と mac (HMAC-SHA256) を 1 組持つ。
- KeyRef は `"SourceVault:dek:v1:<group>:enc"` と `":mac"`。作るのは 1 度だけ (NBStoreCredentialKey の CreateOnly)。
- 台帳 svkeyring.json は PrivateVault/keyring と LocalState/keyring の 2 か所に置く。世代つきで MAC つき。
- 台帳には受取人 (OSCredential = 機ごとの鍵ストア / Recovery = 紙の回復 / 後で PRF) と鍵の指紋を記録する。
- 世代の下限を LocalState/atrest/keyring.floor.json に MAC つきで覚える。これより古い台帳は使わない。

紙の回復 (SVR1)
- 回復の秘密 R は 32 バイトの暗号用乱数。Crockford Base32 の 4 行 + 検査文字 + CHK + QR で印刷する。QR の文字列は `SVR1:<52 文字>:<CHK>`。
- R から包む鍵と MAC 鍵を導き、回復の RSA-3072 の秘密鍵を包んで台帳に置く。
- 分類の鍵と台帳の MAC 鍵は回復の公開鍵 (OAEP) で包む。R が手元に無くても、新しい鍵を回復の受取人に足せる。
- R はファイルに書かず、戻り値にも出さない。保存しない FE の窓に出して印刷するだけ。
- 入力は FE の伏せ字の窓から行う。

形式 SVEF v1 (ファイルの暗号化)
- 構造: `"SVEF" 01 00 | uint32 hlen | header (正準 JSON) | uint32 clen | ciphertext | HMAC-SHA256 (32 バイト)`
- MAC = HMAC(mac 鍵, 前置き 10 バイト ‖ header ‖ uint32 clen ‖ SHA256(ciphertext))
- header に平文のハッシュや学生の情報を入れない。LogicalPath (保管先の根からの相対パス) を MAC で縛る。
- header の主なキー: SVEF, KeyGroup, ClassId, PL, EncKeyRef, MacKeyRef, KeyFingerprint, PlaintextLength, CiphertextLength, CreatedAtUTC, LogicalPath。
- 鍵の名前は header の値を信じず、鍵の組と版から導いた名前と一致することを確かめる。
- 中身は元のバイト列そのまま (往復でバイト一致)。暗号化したファイルの名前は「元の名前 + .sve」。

読み手の規則
- .sve があれば優先する。検証に失敗したら Failure を返す。黙って平文に戻らない。
- 平文だけなら平文を読む (LegacyPlaintext を数える)。
- 両方あり平文の方が新しければ SplitBrain の Failure。

保管先と AccessLevel (既定)
- PrivateVault と WebReports は 0.5。LocalState は 0.94。

書き込みの準備 (Ready)
- 今の版の鍵がこの機にあり、指紋が台帳と一致する。
- 今の版と退役した版がすべて今の紙で戻せる。
- 今の版を作った後に SourceVaultRecoveryDrill に合格している。

Failure の主な tag
- KeyringMissing, KeyringInvalid, KeyMissing, KeyUnavailable
- SVEFBadFormat, SVEFTruncated, SVEFBadHeader, SVEFUnknownKeyGroup, SVEFKeyRefMismatch, SVEFMacMismatch, SVEFPathMismatch
- SplitBrain, AtRestReadFailed, NotEncrypted, AtRestNotReady
- RecoveryKeyExists, RecoveryReplaceNeedsOldPaper, RecoveryReplaceCancelled, RecoveryDrillFailed, RecoverFailed
- RecoveryCodeLength, RecoveryCodeInvalid, RecoveryCodeChecksum, RecoveryCodeShape, RecoveryCodeLine
- NoFrontEnd, RunInFrontEnd, UnknownClass, StoreLocked, NotOwner
- BackupMissing, BackupUnreadable, BackupManifestTampered, ViewWriteFailed

NBAccess の承認の対象に次のヘッドを登録している。モデルが書いたコードから呼ぶと承認を求める。
- SourceVaultCreateRecoveryKey, SourceVaultRecoverKeys, SourceVaultRecoveryDrill, SourceVaultEnsureClassKey
- SourceVaultAtRestSetup, SourceVaultAtRestDeleteFile, SourceVaultRotateClassKey, SourceVaultAtRestReencryptFile ほか
- 機密を生むヘッドの表 (NBAccess) にも登録する。

## 変数
### $SourceVaultClassPrivacyRegistry
型: Association, 初期値: 下記の分類表
分類 (snapshot の class 名や保管場所の名前) → `<|PL, Provenance, KeyGroup, Category, DecidedAt, DecidedBy|>` の表。2026-11-14 に所有者が決めた。Provenance は "Declared"、DecidedBy は "Owner"。
- grades (PL 0.98): ZelkovaGradeSnapshot, CerezoExamRun, CerezoExamScoreSummary, CerezoFinalGradeReview, ExamGrading, CourseGradebook, CourseSummaryGrades
- pseudonym (PL 0.98): PseudonymMap, AnnotationBinding
- submissions (PL 0.98): CerezoCollectionRun, CerezoCollectionSubmissionVersion, CerezoCollectionCatalog, CerezoGradingProjection, Blob
- roster (PL 0.98): CourseEnrollment, CourseRoster, WebReport
- derived (PL 0.9): AnnotationContent, AnonymizationPlan, CloudTransportResult, DerivedArtifact, DeclassificationPublication

### $SourceVaultKeyGroups
型: Association, 初期値: 下記の 5 組
鍵の組 → `<|Tier, Category|>`。
- "grades": Tier 1, 成績・採点
- "pseudonym": Tier 1, 匿名化を戻す対応表
- "submissions": Tier 1, 提出物・採点の投影
- "roster": Tier 1, 名簿・履修者・レポート
- "derived": Tier 2, 匿名化済み・派生

### $SourceVaultStoreAccessLevels
型: Automatic | List, 初期値: Automatic
保管先の AccessLevel の上書き。Automatic なら PrivateVault・WebReports = 0.5、LocalState = 0.94 を根から求める。上書きするときは `{<|"Store", "Root", "AccessLevel"|>..}`。
例: `$SourceVaultStoreAccessLevels = {<|"Store" -> "PrivateVault", "Root" -> "C:\\pv", "AccessLevel" -> 0.5|>}`

### $SourceVaultAtRestEnforce
型: List, 初期値: {}
このカーネルで暗号化を強制する鍵の組の一覧。移行のときに分類の組ごとに足す。入っている組の分類は、書き手が平文を書かずに SVEF で書く。台帳の EnforcedGroups (全機・service に効く) は SourceVaultAtRestSetEnforced で変える。

### $SourceVaultAtRestRecoveryCodeSink
型: Function | 未設定, 初期値: 未設定
試験専用。`NBAccess`$NBCredentialBackend === "Memory"` のときだけ、紙の回復キーを FE の窓の代わりにこの関数へ渡す。本番では使わない。

### $SourceVaultAtRestViewTTL
型: 数値 (秒), 初期値: 1800
表示用の平文のファイルを残す秒数。

## 分類・段・保管先
### SourceVaultAtRestClassInfo[classId] → Association
分類の PL・出どころ・鍵の組・段を返す。
登録済みは表の項目に `"ClassId"`, `"Registered" -> True`, `"Tier"` を足したもの。
表に無い分類は `<|"ClassId", "Registered" -> False, "PL" -> 1.0, "Provenance" -> "Unknown", "KeyGroup" -> Missing["Unclassified"], "Tier" -> 1|>`。

### SourceVaultAtRestTier[pl, accessLevel] → 1 | 2 | 3
pl >= 0.95 なら 1、pl <= accessLevel なら 3、他は 2。

### SourceVaultAtRestStoreOf[path] → Association
path が属する保管先を `<|"Store", "Root", "AccessLevel", "LogicalPath"|>` で返す。
Store は PrivateVault / WebReports / LocalState / Unknown。Unknown は AccessLevel 0、Root は Missing。
最長一致の根を採る。LogicalPath は小文字化して "/" 区切りにする。

### SourceVaultAtRestShouldEncryptQ[path, classId] → True | False
その分類の鍵の組が強制されていて、段が 1 か 2 のとき True。書き手はこれが True なら平文を書かずに SourceVaultAtRestWriteBytes を使う。
- 未登録の分類は False。
- 段 3 は False。
- 他のカーネルが MAINTENANCE.json を持っているときは True。
- それ以外は、鍵の組が強制の組に入っているかで決まる。

### SourceVaultAtRestClassOfPath[path] → String | Missing
保管先の中の位置から分類を返す。分類表に無いもの・LocalState・不明な場所は Missing。
- coursereports/gradebook → CourseGradebook
- coursereports/summarygrades → CourseSummaryGrades
- coursereports/enrollment → CourseEnrollment
- coursereports/rosters → CourseRoster
- exercises/exams の `-grading.wxf` と `-scans/` → ExamGrading
- snapshots/<class>/... → その class 名
- blobs → Blob
- webreports → WebReport

## 台帳・鍵・紙の回復
### SourceVaultAtRestKeyring[] → Association | Failure
台帳 (svkeyring.json) の有効な最新の世代を返す。暗号文と公開情報だけを含む。

### SourceVaultAtRestStatus[] → Association | Failure
台帳・紙の回復・鍵の組ごとの状態を返す。秘密は含まない。
- "Keyring": Status, Generation, Floor, Copies
- "Recovery": KeyId, CreatedAt, CreatedOn, DrillPassedAt, DrillPassedOn, Replaced, ReplacedWithoutOldPaper。無ければ "Missing"
- "KeyGroups": 鍵の組ごとに Tier, InKeyring, KeyVersion, RetiredVersions, KeysOnThisMachine, Assurance, Ready, Enforced
- "AssuranceNote": 段 1 の鍵が暫定で SystemCredential にある間は、同じ Windows 利用者のプロセスが復号できることを書く。そうでなければ None
- "EnforcedGroups": 台帳の強制の組
- "EnforcedInThisKernel": `$SourceVaultAtRestEnforce`
- "Maintenance": 作業のロックの情報

Assurance の値: "OSCredentialTemporary" (暫定) | "PRF" | "OSCredential"。

### SourceVaultEnsureClassKey[group] → Association | Failure
鍵の組の鍵を 1 度だけ作り、紙の回復の公開鍵で包んで台帳に記録する。作ったときは Status が "Created"。台帳にある組は作り直さない。鍵が無ければ KeyMissing を返し、SourceVaultRecoverKeys を案内する。

### SourceVaultAtRestSetup[] → Association | Failure
台帳の MAC 鍵・紙の回復キー (無ければ作って印刷)・全部の鍵の組の鍵を用意する。
戻り値は `<|"Status" -> "KeysReady", "Created", "Ready", "Next"|>`。
最後に SourceVaultRecoveryDrill[] で訓練に合格するまで、暗号化の書き込みは動かない。

### SourceVaultCreateRecoveryKey[opts]
紙の回復キー (SVR1) を作り、保存しない FE の窓に出して印刷させる。回復キーそのものはファイルに書かず、戻り値にも出さない。既にあれば作らない。FE が必要 (試験の sink を除く)。
→ Association | Failure
Options: "Replace" -> False (True で作り直す。古い紙は使えなくなる), "OldCode" -> Automatic (作り直しのとき、古い紙の回復キーの文字列。Automatic なら窓で入力させる), "OldPaperLost" -> False (True なら古い紙なしで作り直す。確認の窓が出る。作り直した後に全部の鍵の組を SourceVaultRotateClassKey で交代させること)
作り直しは Replaced の履歴に残る。台帳の MAC 鍵と既存の鍵の組 (今の版と退役した版) は新しい公開鍵で包み直す。
例: `SourceVaultCreateRecoveryKey["Replace" -> True, "OldPaperLost" -> True]`

### SourceVaultRecoveryDrill[opts]
紙の回復キーを入力させ (FE の伏せ字の窓)、全部の鍵の組の鍵が紙から戻せることを、鍵の指紋の照合で確かめる。鍵ストアは変えない。合格を台帳に記録する (DrillPassedAt と、組ごとの DrillVerifiedVersion)。
→ `<|"Status" -> "Passed", "KeyId", "KeysChecked", "DrillPassedAt"|>` | Failure (RecoveryDrillFailed)
Options: "Code" -> Automatic (回復キーの文字列。Automatic なら窓で入力)

### SourceVaultRecoverKeys[opts]
紙の回復キーを入力させ、台帳の鍵をこの機の鍵ストアに戻す。既にある鍵は上書きしない。壊滅的なクラッシュの後や新しい機で使う。台帳の MAC 鍵が戻った後、この機を OSCredential の受取人に加えて台帳を書き直す。
→ `<|"Status" -> "Recovered" | "RecoveredWithConflicts", "Counts", "Conflicts", "Next"|>` | Failure
Options: "Code" -> Automatic (回復キーの文字列。Automatic なら窓で入力)

### SourceVaultAtRestReadyQ[group] → True | False
その鍵の組の鍵がこの機にあり、紙の回復の受取人があり、訓練に合格しているとき True。

### SourceVaultRotateClassKey[group] → Association | Failure
鍵の組の鍵を交代させる。新しい版を作って紙の回復で包み、今の版を Retired に移す。既存の暗号文は古い版で読める。訓練に合格した後、SourceVaultAtRestReencryptFile で新しい版に書き直す。
段 1 の鍵を PRF に移すときと、紙が漏れたおそれがあるときに使う。

## 暗号化の読み書き
### SourceVaultAtRestWriteBytes[path, bytes, classId, opts]
bytes を SVEF で暗号化して `path <> ".sve"` に書く。手順は次のとおり。
1. 一時ファイルに書く。
2. 読み直して MAC・復号・バイト一致を確かめる。
3. 改名する。
4. 平文の path を消す。

準備ができていなければ Failure を返し、平文には戻らない。
→ Association (KeyVersion を含む) | Failure
Options: "PL" -> Automatic (PL を明示する。Automatic なら分類表の値), "DeletePlaintext" -> True (書いた後に平文の path を消す)
例: `SourceVaultAtRestWriteBytes[FileNameJoin[{root, "snapshots", "ZelkovaGradeSnapshot", "a.json"}], ba, "ZelkovaGradeSnapshot"]`

### SourceVaultAtRestReadBytes[path] → ByteArray | Missing["NotFound"] | Failure
path (平文の名前) のデータを返す。`path <> ".sve"` があれば検証して復号する。無ければ平文を読む。
- 検証に失敗したら Failure。
- 平文と .sve の両方があり平文の方が新しければ SplitBrain の Failure。

### SourceVaultAtRestFileExistsQ[path] → True | False
平文か .sve のどちらかがあれば True。

### SourceVaultAtRestFileNames[pattern, dir, levels] → List
FileNames と同じだが、.sve を外した論理名で返す。平文と暗号文の両方を 1 つにまとめる。一時ファイル (.tmp.) は含めない。levels の既定は 1。

### SourceVaultAtRestDeleteFile[path] → True | False
平文と .sve の両方を消す。

### SourceVaultAtRestReencryptFile[path] → Association | Failure
古い版の鍵で暗号化したファイルを、今の版の鍵で書き直す (中身は同じ)。
- 今の版なら `<|"Status" -> "Current", "KeyVersion"|>`。
- 書き直したら `<|"Status" -> "Reencrypted", "From", "To"|>`。
- .sve が無ければ NotEncrypted の Failure。

### SourceVaultAtRestViewFile[bytes, name] → String | Failure
暗号化したデータを閲覧ソフトで開くための平文のファイルを、Dropbox の外 (LocalState/atrest/view) に作ってパスを返す。`$SourceVaultAtRestViewTTL` 秒を過ぎたものは次の呼び出しで消す。name は安全な文字だけに置き換える。

### SourceVaultAtRestSweepViewFiles[] → Association
期限を過ぎた表示用の平文のファイルを消す。戻り値は `<|"Deleted", "Locked", "Remaining"|>`。

## 移行・点検
### SourceVaultMigrateToEncrypted[opts]
保管先の学生・成績のファイル (平文) を 1 件ずつ暗号化する。既定は試し ("DryRun" -> True) で、分類ごとの件数と理由のコードだけを返す。
- 本番は FE で行う (Memory の鍵ストアか "AllowScript" -> True なら FE 外でも可)。
- 本番では移す組を台帳の強制 (EnforcedGroups) に入れる。作業中は MAINTENANCE.json で他のカーネルの書き込みを止める。
- 対象の組が準備未了なら AtRestNotReady の Failure。
- 途中で止まってもやり直せる。細目は LocalState/atrest/migration の日誌 (jsonl)。
- 段 1 と 2 の分類が対象。

→ `<|"Status" -> "DryRun" | "Done", "RunId", "Classes", "Items", "Counts", "Totals", "Backup", "EnforcedGroups", "Flags", "Next"|>` | Failure

Options: "Classes" -> All (All か分類名の一覧), "DryRun" -> True, "MaxFiles" -> Infinity (最大件数), "BackupManifest" -> Automatic (Automatic = BackupRoot の最新の MANIFEST.sha256), "BackupRoot" -> "D:\\SourceVaultBackup", "RequireBackup" -> True (平文の SHA-256 がバックアップの目録と一致するファイルだけを移す), "AllowScript" -> False (FE 以外から本番を行うことを許す)

結果コードに NotInBackup と ChangedSinceBackup があり、これらは移さない。Flags は MigrationProtectsCloudHistory -> False, EventsNotMigrated -> True, FilenameLeaks, GCPaused -> True。
例: `SourceVaultMigrateToEncrypted["Classes" -> {"CourseGradebook"}, "MaxFiles" -> 10]` (試し)
例: `SourceVaultMigrateToEncrypted["DryRun" -> False]` (FE で本番)

### SourceVaultAtRestVerifyMigration[opts]
暗号化したファイルを復号し、平文の SHA-256 をバックアップの目録と比べる。分類ごとの件数だけを返す。
→ Association
件数の項目: MatchesBackup / DiffersFromBackup / NotInBackup / StillPlaintext / Both / Unreadable
Options: "Classes" -> All, "BackupManifest" -> Automatic, "BackupRoot" -> "D:\\SourceVaultBackup", "RequireBackup" -> True

### SourceVaultDecryptStoreToPlaintext[opts]
暗号化したファイルを平文に戻す (バイト一致、元に戻す道具)。既定は試し。
→ Association | Failure
Options: "Unenforce" -> False (True で、範囲に全部の分類が入る組の強制を外す)。分類の範囲や試しの指定は SourceVaultMigrateToEncrypted と同じ形 ("Classes", "DryRun" など)。

### SourceVaultAtRestSetEnforced[groups, "Mode" -> mode]
台帳の EnforcedGroups を変える。全部の機と service で、新しい書き込みを暗号化する組が変わる。足す組は準備 (訓練の合格) が要る。
→ Association (EnforcedGroups を含む) | Failure
Options: "Mode" -> "Add" ("Add" | "Remove" | "Set")
例: `SourceVaultAtRestSetEnforced[{"grades"}, "Mode" -> "Add"]`

### SourceVaultAtRestEndMaintenance[opts]
移行の作業のロック (MAINTENANCE.json) を外す。別のカーネルが残したロックは "Force" -> True で外す。
→ `<|"Status" -> "Unlocked" | "NotLocked"|>` | Failure (NotOwner)
Options: "Force" -> False

### SourceVaultAtRestInventory[] → Association
学生・成績の保管場所を走査し、分類ごとの件数 (平文・暗号文・両方・一時) とバイト数、段、鍵の組、強制の有無だけを返す。パスやハッシュは出さない。

### SourceVaultAtRestResidualInventory[] → Association
本文以外に残る平文の件数だけを返す。
- PrivateVaultMaterialized, LocalStateMaterialized, ViewFiles, CourseTempFiles
- WebReportsPlainFiles, WebReportsIdNamedPDFs (学籍番号の名前の PDF)
- AnonymizeConfigFiles
- EventsWithStudentToken (events の `student:`。Core が未読み込みなら Missing["CoreNotLoaded"])
- NotChecked: まだ調べていない場所の一覧
- ManualSteps: 手で消す作業の一覧 (Dropbox の版の履歴と削除済み、D: のバックアップ)

## 運用の流れ
1. `SourceVaultAtRestSetup[]` を実行する。
2. 紙の回復キーを印刷して保管する。
3. `SourceVaultRecoveryDrill[]` に合格する。
4. `SourceVaultMigrateToEncrypted[]` で試す。
5. `SourceVaultMigrateToEncrypted["DryRun" -> False]` を FE で行う。
6. `SourceVaultAtRestVerifyMigration[]` で照合する。
7. Dropbox の版の履歴と削除済みを、Dropbox の web で消す。

アプリ側 (書き手・読み手) の書き方:
- 書き手: `If[SourceVaultAtRestShouldEncryptQ[path, cls], SourceVaultAtRestWriteBytes[path, bytes, cls], <平文で書く>]`
- 読み手: `SourceVaultAtRestReadBytes[path]`。Failure を握りつぶさない。
- 一覧: `SourceVaultAtRestFileNames`。存在確認: `SourceVaultAtRestFileExistsQ`。削除: `SourceVaultAtRestDeleteFile`。

新しい機や鍵ストアの喪失の後: 台帳を D: のバックアップか他の機から戻し、`SourceVaultRecoverKeys[]` で紙から鍵を戻す。

確かさ (Assurance): 段 1 の鍵は PRF に移すまで SystemCredential にある。その間は同じ Windows 利用者のプロセス (service・MCP のカーネル・エージェントのシェルを含む) が復号できる。防げるのは Dropbox 社・同期先の機・写し (バックアップや版の履歴を除く) からの読み取りまで。

関連パッケージ: NBAccess (https://github.com/transreal/NBAccess)、NBAccess_crypto (https://github.com/transreal/NBAccess_crypto)、SourceVault_crypto (https://github.com/transreal/SourceVault_crypto)、SourceVault_core (https://github.com/transreal/SourceVault_core)。