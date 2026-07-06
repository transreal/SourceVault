# SourceVault_mailsuggest API リファレンス

## 概要
状況テキスト(自然文 prompt)から近いメールセッション(スレッド)候補を返す、検索基盤を総動員したメールマイニング関数群。3 仕様の合流点として設計されている:検索基盤 (session chunk + KeywordBM25V1)、一般メール構造化 (MailStruct 経路)、自己組織化マイニング (TagAssertion / Authorship / Identity 二層)。

corpus 解決の分岐:
- `mbox = "oops"` → OOPS-ml 過去ログ (`$svOOPSState` / oopsseed 経路、`SourceVaultOOPSSearchThreads` を再利用)。返信不可。
- それ以外 (`"univ"` 等) → IMAP maildb → `SourceVaultStructureMail` → BM25 index (mailstructure 経路)。返信可。

core/View 分離: `SourceVaultMailSessionSuggest` が連想を返す core、`SourceVaultMailSessionSuggestView` が Dataset + 表示件数制限の View。閲覧は `SourceVaultMailThreadWindow` (front end) / `SourceVaultMailThreadPanel` (FE 非依存 panel) / `SourceVaultMailThreadStructure` (純構造)。返信ドラフトは `SourceVaultMailReplyDraft`。

依存 ([SourceVault_oopsseed](https://github.com/transreal/SourceVault_oopsseed) / [SourceVault_mailstructure](https://github.com/transreal/SourceVault_mailstructure) / [SourceVault_lexical](https://github.com/transreal/SourceVault_lexical) / [SourceVault_searchindex](https://github.com/transreal/SourceVault_searchindex) / [SourceVault_mining](https://github.com/transreal/SourceVault_mining) / [SourceVault_identity](https://github.com/transreal/SourceVault_identity) / [SourceVault_core](https://github.com/transreal/SourceVault_core)) はいずれも弱結合。未ロード成分は該当機能だけ degrade する(mining 層が無ければ IdentityTags スコアは 0 になるが失敗しない)。corpus は `(mbox, period, ctx, loadLimit)` 単位でキャッシュされ、同 opts の suggest / window 呼び出しは即時。

## スコアリング
最終 Score は有効成分だけで正規化した加重和。`total = (wP·PromptScore + wK·KeywordScore + wI·IdentityScore) / (wP+wK+wI)`。
- wP: query(prompt+keywords)が非空なら Weights の "Prompt"、空なら 0。
- wK: Keywords が非空なら "Keywords"、空なら 0。
- wI: IdentityTags profile があれば "Identity"、無ければ 0。
- PromptScore = BM25 hit score / pool 内最大 score (0..1)。
- KeywordScore = 一致キーワード数 / キーワード数 (本文正規化テキストへの部分一致)。
- IdentityScore = 各 profile 寄与 (0..1) の平均。寄与は MailRefs 直接一致=1.0 / アドレス一致=0.8 / タグ完全一致=0.7 / TagStrings 交差=0.5 / 本文語一致=0.4。

query が空の場合は全 session を通数(MailCount)降順で MaxCandidates 件までプールし、PromptScore=0 として Keywords/Identity のみで順位付け。

## 公開関数

### SourceVaultMailSessionSuggest[mbox, prompt, opts]
状況テキスト prompt に近いメールセッション候補を返す core 関数。mbox は maildb の mbox 名 or "oops"。prompt は自然文(省略時 "")。
→ Association `<|"MBox", "Prompt", "Query", "CandidatePool", "FilteredCount", "Candidates", "Corpus", "Weights"|>`。corpus 解決失敗時は Failure を返す。
Candidates は各 `<|"Session", "Subject", "Kind", "Mails"(通数), "LastDate", "Score", "PromptScore", "KeywordScore", "IdentityScore", "MatchedKeywords", "MatchedIdentityTags", "Snippet", "MailRefs"|>` を Score→LastDate 降順で Limit 件。Corpus は `<|"Kind", "SessionCount", "MailCount", "CloudSafe"|>`。
Options:
- "Period" -> All (絞込。`All`/`None`/`Automatic`/`"Latest"`/`""`=無し, `"YYYYMM"`, `{from,to}`(DateObject/"YYYYMM"/日付文字列), 正整数 n=直近 n ヶ月)
- "Keywords" -> {} (topic item 準拠キーワード列。本文一致率でスコア。文字列単体も可)
- "From" -> {} (差出人フィルタ。満たすメールを含む session だけ残す。要素は メールアドレス / 表示名 / `ent-` entity / `idf-` identifier。小文字部分一致)
- "To" -> {} (宛先 To+Cc フィルタ。From と同形式)
- "IdentityTags" -> {} (`sv://...` オブジェクト / `ent-` / `idf-` / メールアドレス / タグ文字列のリスト。TagAssertion・Authorship・identity 層経由で関連 session を boost)
- "Limit" -> 10 (返す候補数)
- "MaxCandidates" -> 50 (BM25 検索プールサイズ)
- "CloudSafe" -> False (True で cloud release context gate。DenyTags = {"NoCloudLLM","NoPublicExport","PrivateML","ThirdPartyContent"})
- "Weights" -> Automatic (`Automatic` = `<|"Prompt"->0.6,"Keywords"->0.2,"Identity"->0.2|>` を有効成分で正規化)
- "EventLimit" -> 5000 (identity 解決の TransactionLog 取得上限)
- "Rebuild" -> False (corpus キャッシュを無視して再構築)
- "LoadLimit" -> 400 (mailstruct 構造化対象メール上限)
例: `SourceVaultMailSessionSuggest["univ", "検索エンジンについて議論が盛り上がったスレッド", "Keywords"->{"BM25","索引"}, "From"->{"ent-123"}, "Period"->6]`
例(oops 全期間 identity boost): `SourceVaultMailSessionSuggest["oops", "", "IdentityTags"->{"alice@example.com","sv://tag/topic-x"}, "Limit"->20]`

### SourceVaultMailSessionSuggestView[mbox, prompt, opts]
`SourceVaultMailSessionSuggest` の View 版。候補行を Dataset で返す。opts は core と同一。
→ Dataset (候補無しは `Dataset[{}]`、失敗は Failure/元 Association)
各行は `<|"Open"(スレッドを開く Button), "Session", "Subject", "Kind", "Mails", "LastDate", "Score", "MatchedKeywords", "MatchedIdentityTags", "Snippet"|>`。表示行数は `$SourceVaultMailSuggestViewMaxRows` で MaxItems 制限。Open ボタンは同キャッシュ opts で `SourceVaultMailThreadWindow` を開く。

### $SourceVaultMailSuggestViewMaxRows
型: Integer, 初期値: 25
`SourceVaultMailSessionSuggestView` が一度に表示する最大行数。

### SourceVaultMailThreadWindow[mbox, sessionId, opts]
1 スレッド(session)の閲覧ウィンドウを新規ノートブックで開く (front end)。上段にメール一覧(クリックで下段の該当メールへジャンプ)、下段に TabView で各メール本文 + 引用/返信ハイパーリンク。mbox が "oops" 以外(maildb)なら各メール・スレッド末尾に返信ボタン (`SourceVaultMailOpenReplyNotebook`) を出す。corpus は suggest と同キャッシュを共有(同 opts なら即時)。
→ NotebookObject (corpus/panel 解決失敗時は Failure)
Options:
- "Period" -> All (corpus 解決用、suggest と同義)
- "CloudSafe" -> False
- "Rebuild" -> False
- "LoadLimit" -> 400
- "MaxBodyChars" -> 20000 (本文表示上限)
- "WindowTitle" -> Automatic (`Automatic` = "✉ " + 件名)

### SourceVaultMailThreadPanel[corpus, sessionId, opts]
`SourceVaultMailThreadWindow` が表示する panel 式 (DynamicModule) を返す(FE 非依存に構築可)。corpus は iSVSug*Corpus / suggest 内部が作る corpus 連想。
→ DynamicModule 式 (session 不在/空スレッドは Failure)
Options:
- "MaxBodyChars" -> 20000
- "OnOpenSession" -> Automatic (別 session を開く関数 `sid |-> _`。`Automatic` は同 corpus で新規ウィンドウを CreateDocument)
- "CanReply" -> Automatic (`Automatic` = corpus の "CanReply" 由来。True/False で明示上書き)

### SourceVaultMailThreadStructure[corpus, sessionId] → Association | Failure
1 スレッドの純構造を返す(FE 非依存、panel の描画元、テスト可能)。session 不在は `Failure["SessionNotFound"]`、メール無しは `Failure["EmptyThread"]`。
戻り値 `<|"SessionId", "Subject", "MBox", "CanReply", "Mails"(日付順), "OrderedRefs", "Links", "CrossRefs"|>`。Links は `mailRef -> <|"Parents"(引用元/親), "Children"(被引用/返信)|>`(スレッド内 edge のみ)。CrossRefs は別スレッド参照 `{<|"Role", "ToSession", "ToSubject"|>...}`。

### SourceVaultMailReplyDraft[mbox, sessionId, opts]
maildb スレッド末尾メールへの返信ドラフトを返す(`SourceVaultMailComposeReply` に委譲、FE 非依存)。mbox="oops" は `Failure["ReplyNotSupported"]`。session 不在/空スレッド/RecordId 不明は各 Failure。
→ Association `<|"To","Cc","Subject","InReplyToToken","Quoted","Body",...|>`
Options:
- "Period" -> All (corpus 解決用)
- "CloudSafe" -> False
- "Rebuild" -> False
- "LoadLimit" -> 400
- "ReplyToRef" -> Automatic (スレッド内特定メールの MailRef を指定して返信。`Automatic` は末尾メール)
- "ReplyAll" -> False (True で Cc 含む全員返信)