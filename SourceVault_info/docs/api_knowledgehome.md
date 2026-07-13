# SourceVault_knowledgehome.wl API

Cane / Knowledge Home 認知支援マイニングレイヤー(oops メーリングリストをベース基準座標とする Knowledge Home)。
仕様: `SourceVault_info/design/sourcevault_cane_knowledge_home_mining_spec_v0_7.md`(v0.1〜v0.7 統合)。
本モジュールは Phase 1A(読み取り専用ブラウザ)と Phase 1B(非破壊追記)を実装する。L0 のベース基準座標は
`SourceVault_oopsseed.wl`(read-only)、gate は既存 `SourceVaultEvaluateReleasePolicy` + release context
(oops-corpus / oops-corpus-cloud)を経由する(認知系推定は gate を緩めない)。

## Phase 1A: 読み取り専用 Knowledge Home ブラウザ

### SourceVaultKnowledgeHomeEnsureLoaded[opts]
`SourceVaultOOPSEnsureLoaded` を呼び、mail/topic/quote の閲覧インデックス(TopicTimeline / MailTopics /
QuoteOut / QuoteIn)を `$svKHState` に構築する(冪等)。KH 拡張(kh-events.jsonl の replay projection)を合流し、
閲覧用 release context(oops-corpus / oops-corpus-cloud)を冪等登録する。
→ `SourceVaultKnowledgeHomeStatus[]`
Options: `"Force"` -> False、`"MailFiles"` / `"TableDir"` / `"MailDir"`(`SourceVaultOOPSEnsureLoaded` へ委譲)。

### SourceVaultKnowledgeHomeStatus[]
`$svKHState` の要約 → `<|Loaded, MailCount, TopicCount, QuoteEdgeCount|>`。

### SourceVaultKnowledgeHomeBuildState[mails, opts]
mail 連想リストから KH 閲覧状態を構築する純関数(archive 非依存・状態注入可能=test / 合成データ用)。
→ Association(`Loaded, MailByCounter, Counters, TopicTimeline, TopicLabel, MailTopics, QuoteOut, QuoteIn, TopicKHTimeline` 等)
Options: `"SurfaceIndex"`(None)、`"RefLabel"`(<||>)、`"QuoteEdges"`(Automatic=`SourceVaultBuildMailQuoteEdges[mails]`)、
`"Extension"`(None。KH 拡張 projection を合流)。

### SourceVaultKnowledgeHomeTopicField[opts]
topic item field(資料 p11 の topic item 空間)を返す。gate で deny された mail のみに現れる topic は除外する
(private topic label 漏洩防止, §2 I-4)。
→ `{<|TopicItemRef, CanonicalLabel, MailCount, KHCount, TotalCount, FirstCounter, LastCounter|>...}`(TotalCount 降順)
Options: `"ReleaseContext"`("oops-corpus")、`"Limit"`(200)、`"MinMails"`(1)、`"State"`(Automatic)、`"AsDataset"`(False)。

### SourceVaultKnowledgeHomeParagraphs[topicRef, opts]
topic を担う mail の時系列(Counter 昇順)+ KH 追記パラグラフ(gate 経由)を返す。prev/next の基盤。
deny 時は `Released -> False` + `Why` で本文/話題を出さない。
→ `{<|MailCounter|ParagraphRef, Subject, From, Date, Released, (Paragraphs|Body|Why)|>...}`
Options: `"ReleaseContext"`("oops-corpus")、`"State"`(Automatic)、`"IncludeParagraphs"`(True)。

### SourceVaultKnowledgeHomeMail[counter, opts]
1 mail の閲覧 core(資料 p3 の [prev]/[index]/[next] と引用双方向)。QuotesOut/QuotedBy は双方向リンク
(citing→cited)。deny 時は本文/話題/引用先ラベルを出さない。counter は整数または `"sv://mail/N"`。
→ `<|MailCounter, Subject, From, To, Date, MlName, Released, PrevCounter, NextCounter, (Paragraphs, TopicRefs, TopicLabels, QuotesOut, QuotedBy | Why)|>` / `Missing["MailNotFound"]`
Options: `"ReleaseContext"`("oops-corpus")、`"State"`(Automatic)。

### SourceVaultKnowledgeHomeFollowLink[ref, opts]
KH 内リンク(`svtopic:...` / `sv://mail/N` / `svmailpara:...`)を解決して遷移先 core を返す(View click ハンドラの基盤)。

### SourceVaultKnowledgeHomeView[entry, opts]
entry(topic ref | mail Counter | `"sv://mail/N"` | svmailpara:)を NB ハイパーテキストとして描画する
(core/View/Window の View 層)。topic item はボタン化、click で時系列へ。引用は双方向リンク。gate 未許可 node は
low-leak placeholder。
Options: `"ReleaseContext"`("oops-corpus")、`"Window"`(False。True で CreateDocument)、
`"RecordInteraction"`(False。opt-in。§6.8 行動ログ)、`"State"`(Automatic)。

## Phase 1B: 非破壊追記(ULID / ki alias / CAS / supersede / undo / offline merge)

正準ストア: `<PrivateVault>/knowledgehome/kh-events.jsonl`(append-only、UTF-8 バイト JSONL で二重エンコード回避)。
alias counter: `<PrivateVault>/knowledgehome/kh-alias.counter`。oops 原本(item-name.index 等)は read-only(§2 I-3)。

### SourceVaultKnowledgeHomeMintItem[label, opts]
Knowledge Home 拡張の topic item を採番する(§4.2)。正準 ID は衝突しない ULID(`"svtopic:kh:<ULID>"`)、
表示 alias は `"ki <n>"`(KH ローカル counter を `.lockdir` + compare-and-swap で発番)。alias 履歴を保持。
KnowledgeHomeTopicItemMinted を kh-events.jsonl に追記する。
→ minted entry(`TopicItemRef, CanonicalLabel, Alias, AliasKi, AliasHistory, PrivacyLevel, CreatedAtUTC, DeviceID` 等)
Options: `"Root"`(Automatic=`<PrivateVault>/knowledgehome`)、`"OwnerRef"`、`"PrivacyLevel"`(0.6)、`"AliasBase"`(10000)、
`"NoAlias"`(False)、`"DeviceID"`、`"CreatedAtUTC"`、`"Persist"`(True)。

### SourceVaultKnowledgeHomeAppend[body, opts]
oops 文法の追記パラグラフを非破壊に追加する(§5.2)。`ParagraphRef = "svkhpara:<ULID>"`、明示マーカー
(◎○・[ns id])と引用マーカー(-*- Quote (from N) -*-)を検証・抽出。mint 済 alias(`[ki N]`)は本文参照形から
正準 ULID へ解決して焼き込む(alias は merge で振り直され得るため安定な正準を保持)。
→ KnowledgeHomeParagraphAdded event(`ParagraphRef, Body, TopicRefs, QuoteRefs, ExplicitTopics, PrivacyLevel, Tags, Author, CognitiveContextRef, SupersedesRef, CreatedAtUTC, DeviceID`)
Options: `"Topics"`、`"Quotes"`、`"PrivacyLevel"`(0.6)、`"Tags"`、`"Author"`、`"CognitiveContextRef"`(§4.3 の
local-only 参照 ID。既定 Missing)、`"Root"`、`"DeviceID"`、`"CreatedAtUTC"`、`"SupersedesRef"`、`"Extension"`(Automatic)、`"Persist"`(True)。

### SourceVaultKnowledgeHomeAppendTemplate[]
追記用の「引数入り式テンプレート 1 セル」(Defer 式)を返す(フォーム的セル編集でなく評価可能式テンプレートを正とする)。

### SourceVaultKnowledgeHomeSupersede[paragraphRef, newBody, opts]
既存 KH パラグラフを訂正する(非破壊)。新パラグラフを追記し旧を Superseded にする(旧は log に残る)。
→ `<|OldRef, NewRef, Event|>`。opts は Append と同じ。

### SourceVaultKnowledgeHomeUndoLast[opts]
直近の(自分の)追記を supersede で取り消す(Retracted。非破壊)。
→ `<|RetractedRef, Event|>` / `Missing["NothingToUndo"]`
Options: `"Author"`(owner)、`"Root"`、`"DeviceID"`、`"Persist"`(True)。

### SourceVaultKnowledgeHomeExtension[opts]
kh-events.jsonl を replay して拡張 projection を返す(再生成可能)。
→ `<|Paragraphs(active), Topics(minted map), AliasMap(alias->ref), TopicKHTimeline(topicRef->{para...}), EventCount|>`
Options: `"Root"`(Automatic)、`"Events"`(明示注入=disk 非依存。test 用)。

### SourceVaultKnowledgeHomeMergeExtensions[eventLists, opts]
複数デバイスの event 列を合流して replay する(offline merge)。正準 ULID は衝突しないので paragraph は無傷。
alias(ki n)衝突は正準 ID を保ったまま alias を振り直し AliasHistory に記録する。
→ `<|Projection, AliasReassignments|>`
Options: `"AliasBase"`(10000)。

### SourceVaultKnowledgeHomeSearch[query, opts]
追記済 KH パラグラフを BM25(`SourceVaultBuildLexicalStats` / `SourceVaultLexicalRank`)で検索する。
ReleaseContext gate を経由し deny パラグラフは返さない(「追記→検索」の往復)。
→ `{<|ParagraphRef, Score, Snippet, TopicRefs|>...}`
Options: `"ReleaseContext"`("oops-corpus")、`"Extension"`(Automatic)、`"Root"`、`"Limit"`(10)。

## 不変条件(実装で担保)

- I-3 ベース不変: oops 原本 read-only。拡張は event + projection(kh-events.jsonl replay)。何も削除しない
  (訂正=Supersede、取り消し=Retracted。旧は log に残る)。
- I-4 gate 全経由: 全 read/search API は `ReleaseContext` を明示引数に持ち gate を経由する。未登録 context は
  fail-closed(全 deny)。private topic label は cloud context の出力に漏らさない。
- I-7 可搬性: 正準は UTF-8 JSONL。ULID 正準 ID + `ki` 表示 alias(alias は振替可能・正準は安定)。
