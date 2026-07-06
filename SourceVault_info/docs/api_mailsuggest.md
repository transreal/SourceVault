# SourceVault_mailsuggest API リファレンス

## 概要
状況テキスト(自然文)からメールセッション(スレッド)候補を提案するモジュール。BM25 検索・identity/mining 層・mailstructure 層を総動員するメールマイニング機能。
mbox = "oops" は OOPS-ml 過去ログ($svOOPSState / oopsseed 経路)を検索対象にする。それ以外("univ" 等)は IMAP maildb -> SourceVaultStructureMail -> BM25 index という mailstructure 経路を通る。
core/View 分離: `SourceVaultMailSessionSuggest` が連想を返す core 関数、`SourceVaultMailSessionSuggestView` が Dataset + 表示件数制限を持つ View。
スレッド閲覧: `SourceVaultMailThreadWindow` が 1 スレッドを新規ノートブックで開く(front end)。上段にメール一覧、下段に TabView で本文を表示し、引用/返信 edge をハイパーリンクで辿れる。`SourceVaultMailThreadStructure`/`SourceVaultMailThreadPanel` はそれぞれ FE 非依存の構造抽出・panel 構築関数で、テストや代替 UI から呼べる。
返信: mbox が maildb (oops 以外) の場合のみ `SourceVaultMailReplyDraft` / window 内の返信ボタンで [SourceVault_maildb](https://github.com/transreal/SourceVault_maildb) 経由の返信ドラフトを作成できる。oops (ML アーカイブ)は返信非対応。

## 依存関係(いずれも弱結合、未ロード成分は該当機能のみ degrade)
- [SourceVault_oopsseed](https://github.com/transreal/SourceVault_oopsseed) — oops 過去ログ ($svOOPSState, SourceVaultOOPSSearchThreads)
- [SourceVault_mailstructure](https://github.com/transreal/SourceVault_mailstructure) — maildb レコード構造化 (SourceVaultStructureMail, SourceVaultMailStructBuildSearchIndex/Search)
- [SourceVault_lexical](https://github.com/transreal/SourceVault_lexical) — 検索テキスト正規化 (SourceVaultNormalizeSearchText)
- [SourceVault_searchindex](https://github.com/transreal/SourceVault_searchindex) — BM25 session index 基盤
- [SourceVault_mining](https://github.com/transreal/SourceVault_mining) — TagAssertion 再生 (SourceVaultReplayTagAssertions, SourceVaultTransactionLog)
- [SourceVault_identity](https://github.com/transreal/SourceVault_identity) — entity/identifier 解決 (SourceVaultGetEntity, SourceVaultGetIdentifier, SourceVaultIdentityEnsureLoaded)
- [SourceVault_core](https://github.com/transreal/SourceVault_core) — 基盤ユーティリティ
- [SourceVault_maildb](https://github.com/transreal/SourceVault_maildb) — 返信ドラフト作成 (SourceVaultMailComposeReply, SourceVaultMailOpenReplyNotebook)

## Core / View

### SourceVaultMailSessionSuggest[mbox, prompt, opts]
状況テキスト prompt に近いメールセッション(スレッド)候補を返す core 関数。mbox は IMAP maildb の mbox 名("univ" 等)、"oops" は OOPS-ml 過去ログ。prompt は自然文("検索エンジンについて議論が盛り上がったスレッド" 等)で BM25 session index を検索する。prompt が "" の場合は全 session を通数降順で候補プールにする。
→ Association
Options: "Period" -> All (All | "YYYYMM" | {from,to} | 正整数n=直近n月でフィルタ), "Keywords" -> {} (topic item 準拠キーワード列; 本文一致率でスコア), "From" -> {} (差出人フィルタ; アドレス/表示名/ent-/idf- 参照可、満たすメールを含む session だけ残す), "To" -> {} (宛先フィルタ; To/Cc を対象、同上), "IdentityTags" -> {} (sv://... オブジェクト/ent-/idf-/メールアドレス/タグ文字列のリスト; TagAssertion・Authorship・identity 層経由で関連 session を上位に boost), "Limit" -> 10 (返す候補数上限), "MaxCandidates" -> 50 (検索プールサイズ), "CloudSafe" -> False (True で cloud release context gate、$svSugCloudDenyTags = {"NoCloudLLM","NoPublicExport","PrivateML","ThirdPartyContent"} を適用), "Weights" -> Automatic (Automatic = Prompt 0.6/Keywords 0.2/Identity 0.2 を有効成分(prompt有無・keywords有無・identitytags有無)だけで正規化), "EventLimit" -> 5000 (TagAssertion 再生に読むイベント数上限), "Rebuild" -> False (True で corpus キャッシュを再構築), "LoadLimit" -> 400 (mailstruct 構造化対象メール数上限)。
戻り値: `<|"MBox", "Prompt", "Query"(prompt+keywordsを連結した実検索クエリ), "CandidatePool"(検索でヒットした件数), "FilteredCount"(Period/From/To フィルタ通過後の件数), "Candidates" -> {<|"Session", "Subject", "Kind", "Mails"(通数), "LastDate", "Score", "PromptScore", "KeywordScore", "IdentityScore", "MatchedKeywords", "MatchedIdentityTags", "Snippet", "MailRefs"|>...}, "Corpus" -> <|"Kind", "SessionCount", "MailCount", "CloudSafe"|>, "Weights" -> <|"Prompt", "Keywords", "Identity"|>|>`。
mbox="oops" の corpus 取得に失敗すると Failure["OOPSNotLoaded", ...] を、maildb 側でメールが取得できないと Failure["NoMailRecords", ...] を返す。
例: `SourceVaultMailSessionSuggest["univ", "検索エンジンについて議論が盛り上がったスレッド", "Period" -> 6, "Keywords" -> {"BM25", "索引"}, "Limit" -> 5]`

### SourceVaultMailSessionSuggestView[mbox, prompt, opts]
`SourceVaultMailSessionSuggest` の View 版。候補行を Dataset (表示件数は `$SourceVaultMailSuggestViewMaxRows` で制限) で返す。opts は core と同じ。
→ Dataset (候補が空なら Dataset[{}]、core が Failure を返した場合はその Failure をそのまま返す)
Options: `Options[SourceVaultMailSessionSuggest]` と同一。
各行は "Open"(ボタン; クリックで `SourceVaultMailThreadWindow` を同 corpus キャッシュで開く), "Session", "Subject", "Kind", "Mails", "LastDate", "Score", "MatchedKeywords", "MatchedIdentityTags", "Snippet" 列を持つ。

### $SourceVaultMailSuggestViewMaxRows
型: Integer, 初期値: 25
`SourceVaultMailSessionSuggestView` が一度に表示する最大行数(Dataset の MaxItems)。

## スレッド閲覧

### SourceVaultMailThreadWindow[mbox, sessionId, opts]
1 スレッド(session)の閲覧ウィンドウを新規ノートブックで開く(front end)。上段にそのスレッドのメール一覧(クリックで下段の該当メールへジャンプ)、下段に TabView で各メールを表示する。各メールには引用/返信 edge を辿るハイパーリンク(スレッド内は tab 切替、別スレッド参照は新規ウィンドウ)を備える。mbox が "oops" 以外(maildb)の場合は各メール・スレッド末尾に返信ボタン(`SourceVaultMailOpenReplyNotebook`)を出す。corpus は `SourceVaultMailSessionSuggest` と同じキャッシュを共有する(同 opts なら即時)。
→ NotebookObject (CreateDocument) | Failure
Options: "Period" -> All, "CloudSafe" -> False, "Rebuild" -> False, "LoadLimit" -> 400 (いずれも corpus 解決用、suggest と同義), "MaxBodyChars" -> 20000 (本文表示上限文字数), "WindowTitle" -> Automatic (Automatic ならスレッド件名から自動生成)。

### SourceVaultMailThreadPanel[corpus, sessionId, opts]
`SourceVaultMailThreadWindow` が表示する panel 式(DynamicModule)を返す(FE 非依存に構築可能)。corpus は `iSVSug*Corpus` / `SourceVaultMailSessionSuggest` 内部で作る corpus 連想。
→ Expression (DynamicModule) | Failure
Options: "MaxBodyChars" -> 20000 (本文表示上限文字数), "OnOpenSession" -> Automatic (別 session を開く関数 sid|->_ ; 既定は同 corpus で新規ウィンドウを作る), "CanReply" -> Automatic (Automatic なら corpus["CanReply"] 由来)。

### SourceVaultMailThreadStructure[corpus, sessionId] → Association | Failure
1 スレッドの純構造を返す(FE 非依存、panel の描画元)。`<|"SessionId", "Subject", "MBox", "CanReply", "Mails"(日付順のメールレコード列), "OrderedRefs"(MailRef の日付順リスト), "Links"(mailRef -> <|"Parents"(引用元/親), "Children"(被引用/返信)|>), "CrossRefs"(別スレッド参照; {<|"Role","ToSession","ToSubject"|>...})|>`。session が corpus に無い場合は Failure["SessionNotFound", ...]、スレッドにメールが無ければ Failure["EmptyThread", ...]。

## 返信

### SourceVaultMailReplyDraft[mbox, sessionId, opts]
maildb スレッド末尾メールへの返信ドラフトを返す(`SourceVaultMailComposeReply` へ委譲、FE 非依存)。mbox="oops" は返信非対応で Failure["ReplyNotSupported", ...] を返す。
→ Association (`<|"To","Cc","Subject","InReplyToToken","Quoted","Body",...|>`) | Failure
Options: "Period" -> All, "CloudSafe" -> False, "Rebuild" -> False, "LoadLimit" -> 400 (corpus 解決用), "ReplyToRef" -> Automatic (スレッド内の特定メール(MailRef)へ返信、既定はスレッド末尾メール), "ReplyAll" -> False (True で Cc を含める)。
session が corpus に無ければ Failure["SessionNotFound", ...]、スレッドが空なら Failure["EmptyThread", ...]、対象メールに RecordId が無ければ Failure["NoRecordId", ...]。