# SourceVault Routine Mail Agenda (R9) 仕様 v0.1

日付: 2026-07-16
状態: ドラフト(レビュー待ち)。routine attention 仕様 v0.4 の残増分 R9 (mail) の具体化。
対象: SourceVault_mailagenda.wl (新規) + SourceVault_routineplan.wl (アジェンダ統合) + NBAccess.wl (whitelist 1 語追加) + SourceVault_maildb.wl (変更なし・既存 API 再利用)

## 0. 要求 (オーナー要件 R9-1〜R9-6)

- **R9-1** 返事が必要なメール・仕事/出席の依頼メールを SourceVaultRoutineAgendaView に含めて列挙する。
- **R9-2** サマリーを計算し、SPAM・無関係メールを確実に除外する。
- **R9-3** オーナー宛て判定: identity のオーナーアドレス (k.imai@fukuyama-u.ac.jp) または所属組織アドレス (fuip@fukuyama-u.ac.jp) 宛て。疑わしい場合は本文中の「今井」宛て言及で確度を上げる。**オーナーに対する依頼でなければリストしない。**
- **R9-4** リスト項目のクリックでメール読み書きノートブックを開き、そこで「返信する / ノートブックを作成」を明確に指示する (作業のし忘れ防止)。
- **R9-5** 解決状態機械: 返信した or ノートブックを作成した → Done → リストから消える。確認だけで返信して終了なら Done。何もしなければ次回の AgendaView でも同じままリストされる。
- **R9-6** 継承: 作業が必要なタスクは作業用ノートブックを作成することでそのメールを継承する。メールセッションと継承ノートブックは強い関係を持ち、**ノートブックからそのメールやその後の返事を直接呼び出せる**。この連携はマイニングレイヤーと協調して実装する。

## 1. 設計原則

1. **既存基盤の再利用を最優先**。maildb には要約/カテゴリ/優先度/〆切の LLM 派生 (SourceVaultInferMailDerivedBatch)、返信 UI (SourceVaultMailOpenReplyNotebook: 送信時に interaction.json へ RepliedAt を自動記録)、スレッド表示 (SourceVaultMailThreadNotebook)、軽量索引 (SourceVaultMailSearchIndex: ToRaw/FromRaw/Category/Priority/Deadline/Summary を本文非ロードで返す) が既にある。R9 はこれらを組み立てる薄い層である。
2. **決定論 first / LLM second**(schedule-noescalate の教訓)。アジェンダ描画パスで LLM を呼ばない。LLM 派生は既存の外部バッチ (SourceVaultMailAddSummaries、サービス/外部 WolframScript ジョブ) が事前計算した Derived を索引から読むだけ。
3. **FE 非ブロック**(mailfetch freeze の教訓)。アジェンダは IMAP fetch をしない。索引 sidecar 走査のみ (シャード本体も原則ロードしない)。
4. **本文はローカルのみ・内容最小化 (I-13)**。解決記録・リンク記録に件名/本文を書かない (RecordId のみ)。クラウド LLM は既存 maildb のポリシー (PrivacyLevel ゲート) に従い、mailagenda 自身は LLM を直接呼ばない。

## 2. 候補パイプライン (SourceVaultMailAgendaItems)

入力: 索引行 (SourceVaultMailSearchIndex、"Mails" オプションで注入可)。既定窓: 直近 45 日 (設定可)。

```
stage 0  窓フィルタ: Date >= Now - Window
stage 1  カテゴリゲート (要対応):
           Category ∈ {"TaskRequest","AttendanceRequest","Confirmation"}
           または Deadline が非 Missing (〆切が推定されたメール)
           Category Missing["NotGenerated"] は「派生未計算」として保留バケツへ (§2.4)
stage 2  SPAM/無関係の除外:
           Priority < $SourceVaultMailAgendaMinPriority (既定 0.5) を除外
           (既存 LLM Priority は SPAM=0.0-0.1、一斉配信=0.2-0.4、
            オーナー業務関連=0.5+ を出すよう設計済み)
stage 3  オーナー宛て判定 DirectionScore (決定論):
           ToRaw ∋ OwnerEmails (identity SourceVaultOwnerEmails[])      → 1.0 "DirectTo"
           ToRaw ∋ OrgAddresses ($SourceVaultMailAgendaOrgAddresses)    → 0.6 "OrgTo"
           どちらでもない                                                → 0.0
           0 < score < $SourceVaultMailAgendaDirectionThreshold (既定 0.7) の場合のみ
           遅延本文確認 (§2.3): 本文に宛名パターン (「今井」既定) → +0.3 "BodyAddressee"
           最終 score >= threshold のものだけ通す
stage 4  解決フィルタ (§4): Done (Replied/NotebookCreated/Dismissed) を除外
stage 5  出力: 新しい順。各項目
           <|"RecordId","Subject","From","Date","Category","Priority","Deadline",
             "Summary","DirectionScore","DirectionEvidence","MBox"|>
```

### 2.1 オーナー/組織アドレス

- OwnerEmails: identity 層 `SourceVaultOwnerEmails[]` から取得 (弱結合、無ければ `$SourceVaultMailAgendaOwnerAddresses` フォールバック)。
- OrgAddresses: `$SourceVaultMailAgendaOrgAddresses` (既定 {})。オーナー環境では `{"fuip@fukuyama-u.ac.jp"}` を設定 (コードに個人アドレスを焼き込まない。PrivateVault/config/mailagenda.json があれば自動ロード)。

### 2.2 宛名パターン

`$SourceVaultMailAgendaAddresseePatterns` (既定 `{"今井"}`)。本文先頭 ~400 文字に StringContainsQ で照合 (宛名は冒頭に現れる)。設定はコードに焼き込まず config から上書き可。

### 2.3 遅延本文確認

索引には本文が無い (暗号化)。stage 3 で必要になった項目のみ `SourceVaultMailSnapshotGet` + `SourceVaultMailSnapshotDecryptBody` で個別復号する。stage 1-2 通過後は件数が少ないので実用速度。結果は RecordId キーで agenda sidecar (§4) にキャッシュし再復号しない。

### 2.4 派生未計算メールの扱い

Category/Priority が Missing["NotGenerated"] の窓内メールは判定不能。除外はせず (見逃し防止)、`"Pending"` として件数のみバンド末尾に表示: 「(未分類 N 件 — サマリー計算を実行)」。クリックで `SourceVaultMailAddSummaries[mbox]` の実行手順を提示 (自動実行はしない: LLM ジョブは明示起動)。

## 3. アジェンダ統合 (routineplan)

- `SourceVaultRoutineAgendaData` に `"Mail" -> {items}` を追加。弱結合: `SourceVaultMailAgendaItems` が定義されていれば Quiet 呼び出し、無ければ {}。オプション `"IncludeMail"` (既定 Automatic=あれば含む)、`"MailWindow"`。
- `SourceVaultRoutineAgendaView` に「✉ 要対応メール」バンドを追加 (期限超過バンドの直後)。各行:
  `【依頼】/【出席】/【確認】/【〆切▸日付】 件名 — 差出人 (n日前)` + Summary 1 行 (小さく)。
- 行クリック → `SourceVaultMailAgendaOpen[recordId]` (§5)。AgendaView は SystemOpen 教訓どおり素の Button。
- メールバンドは AccessLevel 1.0 (ローカル FE) 前提。AgendaData の PrivacySpec が 1.0 未満なら件数のみ。

## 4. 解決状態機械と永続化

状態: `Pending → Done(Replied | NotebookCreated | Dismissed)`。

| 遷移 | 記録 | 検出 |
|---|---|---|
| 返信した | 既存: 返信ノートブックの送信で interaction.json に RepliedAt (自動) | RepliedAt が項目 Date より新しい → Done |
| ノートブック作成 | 新規: agenda sidecar に NotebookCreated + NotebookPath | sidecar 参照 |
| 確認のみ・対応不要 | 新規: agenda sidecar に Dismissed | sidecar 参照 |
| 何もしない | 記録なし | Pending のまま次回も列挙 (R9-5) |

- agenda sidecar: `<mailStoreRoot>/agenda.json` (interaction.json と同居、Dropbox 共有、読み書きは load-merge-save)。スキーマ: `RecordId -> <|"State","At","NotebookPath"(opt),"BodyAddressee"(cache)|>`。件名・本文は書かない (I-13)。
- 公開 API: `SourceVaultMailAgendaResolve[recordId, "Dismissed"|"NotebookCreated", opts]`、`SourceVaultMailAgendaResolutions[]`、取り消し `SourceVaultMailAgendaReopen[recordId]`。

## 5. アクション UI (SourceVaultMailAgendaOpen)

`SourceVaultMailAgendaOpen[recordId]` は既存 `SourceVaultMailThreadNotebook` (スレッド全体のアウトライン表示) を開き、先頭にアクションバーを付ける:

```
[↩ 返信する]  [📓 ノートブックを作成して継承]  [✓ 確認のみ・対応済みにする]
```

- **返信する** → 既存 `SourceVaultMailOpenReplyNotebook[recordId]`。送信すれば RepliedAt が記録され自動 Done (外部メーラで返信した場合も、返信が maildb に ingest されれば将来検出可能だが v0.1 は interaction.json 経由のみ)。
- **ノートブックを作成** → `SourceVaultMailAgendaInherit[recordId]` (§6)。
- **対応済み** → `SourceVaultMailAgendaResolve[recordId, "Dismissed"]`。

## 6. 継承ノートブックとマイニング連携 (R9-6)

`SourceVaultMailAgendaInherit[recordId, opts]`:

1. `$onWork` 直下に `yyyymmdd-<件名短縮>.nb` を作成。先頭セルは既存 newNote 規約 (ExpressionCell[Defer[<|...|>], "Input", InitializationCell->True]):
   `<|"Title"-><件名>, "Keywords"->{"mail"}, "Status"->"Todo", "Deadline"-><派生〆切あれば>, "MailRecordId"-><rid>|>`
2. agenda sidecar に `NotebookCreated` + NotebookPath を記録 (→ Done、アジェンダから消える)。
3. **双方向リンク**:
   - ノート→メール: メタデータ `MailRecordId`。`SourceVaultMailForNotebook[nbPathOrNb]` がこれを読んで `SourceVaultMailThreadNotebook` を開く (その後の返事もスレッドに含まれるので「後続の返信も直接呼び出せる」)。ノート内に「✉ 元メールを開く」ボタンセルも挿入。
   - メール→ノート: sidecar の NotebookPath。アジェンダや thread ノートから「継承ノートを開く」ボタン。
4. **マイニングレイヤー連携** (弱結合 emit, rule 11): 継承イベント
   `<|"Type"->"MailInheritedByNotebook","RecordId"->rid,"NotebookPath"->path,"At"->ts|>`
   を identity/mining の event log へ emit する seam を呼ぶ (`SourceVaultIdentityRecordEvent` 等が定義済みなら Quiet 呼び出し、無ければ skip)。ownership 再計算 (SourceVaultRecomputeOwnershipLinks) やマイニング層はこのイベントを関係強化に使える。
5. NBAccess: `$iNBOnwWhitelist` に `"MailRecordId"` を追加 (1 語)。これで NBOnWorkTasks / アジェンダのタスク項目からもメール逆参照が可能になる。

## 7. 増分計画

- **Inc1 (core)**: SourceVault_mailagenda.wl 新規 = パイプライン (§2, 注入シーム付き) + sidecar 解決 (§4) + Replied 連動 + AgendaData/View 統合 (§3)。headless テスト (索引行/interaction/解決の注入)。
- **Inc2 (actions)**: AgendaOpen アクションバー (§5) + Inherit (§6.1-3) + NBAccess whitelist + SourceVaultMailForNotebook。FE 実機検証 (result*.nb)。
- **Inc3 (mining/精度)**: mining event emit 結線 (§6.4)、宛名確認キャッシュ最適化、実運用での閾値調整、未分類メールの定期バッチ運用 (service への組み込み)。

## 8. 設定一覧

| 変数 | 既定 | 意味 |
|---|---|---|
| $SourceVaultMailAgendaWindow | 45 (日) | 候補走査窓 |
| $SourceVaultMailAgendaMinPriority | 0.5 | SPAM/無関係の除外閾値 |
| $SourceVaultMailAgendaDirectionThreshold | 0.7 | オーナー宛て判定閾値 |
| $SourceVaultMailAgendaOrgAddresses | {} | 組織アドレス (環境設定) |
| $SourceVaultMailAgendaOwnerAddresses | {} | identity 不在時のフォールバック |
| $SourceVaultMailAgendaAddresseePatterns | {"今井"} | 本文宛名パターン (環境設定) |
| $SourceVaultMailAgendaCategories | {TaskRequest, AttendanceRequest, Confirmation} | 要対応カテゴリ |

設定は PrivateVault/config/mailagenda.json があればロード時に上書き適用 (個人情報をコードに焼き込まない)。
