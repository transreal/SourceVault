# SourceVault`MailBrowse API Reference
パッケージ: `SourceVault_mailbrowse` (SourceVault.wl auto-load / context `SourceVault``)
依存: SourceVault_mailstructure (必須), SourceVault_maildb (実データ), SourceVault_searchindex (索引), SourceVault_oopsseed (本文 [ns id] リンク時のみ任意), SourceVault_crosslink (⇄ 関連ボタン時のみ任意)

## 概要

汎用 mbox (univ 等・今後追加される mbox すべて) のメールを、OOPS アーカイブブラウザ
(SourceVaultOOPS*View) と同等のハイパーテキストで閲覧する層。
`SourceVaultStructureMail` の出力 (relation graph / session / 段落 topic / topic graph)
から逆引き索引 (mailRef→session、edge 両方向、topic→時間順メール列、label→topic ref)
を構築し、以下のリンクを提供する:

- **引用・被引用**: relation edge (From=citing → To=cited) をメールビューから両方向に辿る
- **topic item**: [label](prev/next) チップで**スレッドを超えて時間順に**前後メールへ移動、
  label クリックで topic を含むスレッド一覧
- **歴史参照**: session の CrossSessionReferences (EvidenceCitation/AnnualEventReuse 等) を
  スレッドビューに露出、対象メール/スレッドへ遷移
- **DB 横断**: 各ビューの「⇄ 関連」ボタン → `SourceVaultCrossLinksView` (api_crosslink.md)

core/View 分離 (rule): core は連想リストを返し、View がボタン付きセルを出力
(表示上限 `$SourceVaultMailBrowseViewMaxRows`)。ボタンには文字列リテラルのみ焼き込む。

## 検索レシピ (最重要)

```wl
SourceVaultMailBrowseEnsureLoaded["univ", "Period" -> "202606"]  (* 初回のみ。All で全期間 *)
SourceVaultMailBrowseSearchThreadsView["Zoom"]        (* スレッド検索 → Subject クリックで ThreadView *)
SourceVaultMailBrowseThreadList[]                     (* スレッド一覧 *)
SourceVaultMailBrowseMailView["<RecordId or sv://mail/...>"]  (* 1 通全文 + 全リンク *)
SourceVaultMailBrowseTopicThreadList["Zoom"]          (* topic label → スレッド一覧 *)
```

## state

### SourceVaultMailBrowseEnsureLoaded[mbox, opts] → Association
mbox をロード→StructureMail→索引構築 (冪等)。state は `$svMailBrowseState[mbox]`。
**永続キャッシュ**: 構築結果 (Structure+IndexInfo) を SourceVaultSealPayload で封印した WXF
としてマシンローカル (`$SourceVaultMailBrowseCacheDir`、既定 LOCALAPPDATA\SourceVault\
mailbrowse-cache) に保存する。鮮度は対象 period の shard ファイル (key,サイズ,mtime) 指紋で
判定し、一致すれば maildb ロード/復号/StructureMail を全部スキップして数秒で復元する
(warm start)。**封印できない環境 (crypto 鍵未初期化) では書かない** (平文 fallback なし)。
shard が変わった period (=当月) だけ再構築される。閉じた月は永久に warm。
戻り値には "CacheHit" / "CacheWrite" ("Written"|"Skipped...") / "Timings" (Fingerprint/
CacheRead/IndexLoad/SetState または MaildbLoad/Records/Structure/Index/CacheWrite の秒数) が付く。
**Period は厳密に効く**: SourceVaultMailSnapshotList はカーネルに載っている全 shard を返すため、
record 側から所属 shard (MBox+Date 年月 = maildb iSVMDShardKey と同一規則) を再計算し、
要求 period の shard のメールだけを構造化する (agenda 等が先にロードした他月メールの混入防止)。
採用 shard は戻り値/Status の "PeriodShards" で確認できる。
Options: "Period" -> Automatic (maildb period: "YYYYMM"|{from,to}|All|n), "Limit" -> All,
"Force" -> False, "Seed" -> None (OOPS dict 等), "VocabOptions" -> {},
"ReleaseContext" -> "mailstruct-local", "QuotePass" -> "Full",
"Records" -> Automatic (generic record list 注入=maildb 不要・テスト用。注入時はキャッシュ/期間フィルタ不使用),
"BuildIndex" -> True, "Cache" -> True, "RefreshCache" -> False (True で強制再構築+書き直し)

### SourceVaultMailBrowseSetState[mbox, structure, indexInfo] → Association
StructureMail の結果から state を直接構築 (注入用)。

### SourceVaultMailBrowseStatus[mbox] → Association
`<|Loaded, MBox, MailCount, SessionCount, TopicCount, RelationEdges, VocabSize, IndexId|>`

## core (連想を返す)

全関数共通 Option: "MBox" -> Automatic (既定 `$SourceVaultMailBrowseDefaultMBox`="univ"、
ロード済みが 1 つならそれ)。

### SourceVaultMailBrowseSessions[opts] → {Association...}
`<|Session, Subject, SessionKind, MailCount, FirstDate, LastDate|>`。"MinMails", "Limit" -> 30。

### SourceVaultMailBrowseSearchThreads[query, opts] → {Association...}
BM25 スレッド検索。`<|Session, Subject, Score, Snippet, MailCount|>`。"Limit" -> 10,
"MinScore" -> Automatic (= Max[2.0, 0.4×最高スコア] 未満の弱一致=bigram 部分一致ノイズを除外。
数値で絶対下限、None で全件)。現 state に無い session への hit は常に除外 (stale index 防御)。

### SourceVaultMailBrowseThread[sessionId, opts] → Association
`<|Session, Subject, SessionKind, MailRefs(日付順), MailCount, Digest(CurrentDigest),
HistoricalReferences, CrossSessionReferences, Topics, TopicRefs, TopicLabels, QuoteEdges(スレッド内), Released|>`

### SourceVaultMailBrowseMail[mailRef, opts] → Association
メール 1 通のハイパーテキストノード。record 全フィールド +
`<|Session, TopicRefs, TopicLabels, Cites(このメールが引用する edge 列), CitedBy(被引用 edge 列)|>`。
mailRef は RecordId でも可 (sv://mail/ を自動補完)。

### SourceVaultMailBrowseTopicMails[topic, opts] → Association
topic (topic ref または label文字列) を含むメールの時間順列。`<|TopicRef, Label, MailRefs|>`。

### SourceVaultMailBrowseTopicSessions[topic, opts] → {Association...}
`<|Session, Subject, MailCount, MatchingMailRefs|>` (初出順)。

### SourceVaultMailBrowseTopicStep[topic, mailRef, dir, opts] → String | Missing
時間順列上の直前 (dir=-1)/直後 (dir=1) の mailRef (スレッド超え)。

### SourceVaultMailBrowseTopicRelated[topic, opts] → {Association...}
topic graph (ObservedRelationGraph) の隣接 topic。
`<|Topic, Label, Kind(QuoteTransition|HistoricalReferenceTransition|TemplateReuseTransition|CoParagraph), Weight, Direction|>`。"Limit" -> 10。

## View (リンク付きセル出力)

### SourceVaultMailBrowseSearchThreadsView[query, opts] / SourceVaultMailBrowseThreadList[opts]
Subject ボタン (→ThreadView) 付き Grid。

### SourceVaultMailBrowseThreadView[sessionId, opts]
メール一覧ボタン (→MailView, cap 40) / topic チップ / 歴史参照リンク (From→To メール +
→スレッド) / 要約 / ⇄ 関連。

### SourceVaultMailBrowseMailView[mailRef, opts]
1 通全文。スレッド+他メールボタン / topic チップ [label](prev/next) / 引用・参照先 /
被引用 / ⇄ 関連 / 本文 (URL は Hyperlink、[ns id] は OOPS topic スレッド一覧ボタン=OOPS
ロード済み時)。**PL > 0.5 は機密セル** (NBAccess TaggingRules claudecode
{privacyLevel, confidential} + $NBConfidentialCellOpts。ボタン経路・インライン評価両対応)。

### SourceVaultMailBrowseTopicThreadList[topic, opts]
topic を含むスレッド一覧 Grid (該当メール時間順ボタン付き)。

### SourceVaultMailBrowseOpenMail[mailRef, mbox]
メールを新規ノートブックで開く (I/O、機密セル対応)。crosslink 等の外部遷移入口。

## 変数

- `$svMailBrowseState` — mbox → ブラウズ state (Structure/RecordByRef/SessionById/
  SessionOfMail/EdgesFrom/EdgesTo/TopicMailIndex/RefLabel/TopicLabelIndex/IndexInfo)
- `$SourceVaultMailBrowseDefaultMBox` (既定 "univ") / `$SourceVaultMailBrowseViewMaxRows` (既定 40)
- `$SourceVaultMailBrowseCacheDir` — 永続キャッシュ保存先 override (既定 Automatic =
  LOCALAPPDATA\SourceVault\mailbrowse-cache。マシンローカル・Dropbox 非同期)

## 内部実装メモ (LLM 向け)

- private context は `SourceVault`MailBrowsePrivate``。他パッケージ private
  (MailStructPrivate 等) には依存しない。後ロードの `SourceVaultCrossLinksView` /
  `SourceVaultOOPSTopicThreadList` は完全修飾+DownValues ガードで参照。
- テスト: `test codes/SourceVault_mailbrowse_crosslink_tests.wls` (46/46。合成 7 通を
  "Records" 注入、maildb/暗号鍵非依存。headless カーネルは CoreRoot 未解決なら temp に向ける)。
