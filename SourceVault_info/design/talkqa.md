# 発表 QA (SourceVault_talkqa.wl) 仕様

2026-08-22 策定・実装。発表中に声で聞かれた質問へ、**数十 ms で・プライバシーを守って**
答えるための層。既存の層の上に足すだけで、どれも置き換えない。

## 1. 何を足したか

| 層 | 役割 | 状態 |
|---|---|---|
| `SourceVault_kb.wl` | Graph-RAG 本体 (slide/figure/topic ノード、BM25 + 伝播、release context ゲート) | 既存。2 関数を追加 |
| `SourceVault_talkqa.wl` | 想定質問の作り置き、即答、プライバシー経路、web への逃がし | **新規** |
| `SourceVault_realtime.wl` | gpt-realtime からの問い合わせ口 (`ask_sourcevault` tool) | 既存。ask 往復を追加 |
| `SourceVault_webingest.wl` | 足りないときの web 検索 | 既存。呼ぶだけ |
| `SourceVault_crosslink.wl` | 他の資料から発表資料へ辿る | 既存。provider を登録 |
| `SlideWorkflow.wl` | デッキ・原稿・再生 | 既存。現在ページを通知 |

KB への追加 2 関数:

- `SourceVaultKBNeighbors[kbId, seed, opts]` — スライドノードを種にした k-hop 近傍。
  「いま開いているページの周辺」を質問語なしで引く (補足説明用)。
- `SourceVaultKBIngestTexts[kbId, sourceId, items, opts]` — 任意テキストの取り込み。
  web で拾った本文を KB に入れて次回から即答にするために使う。

## 2. データの流れ

```
デッキ .nb ──ingest──> KB (slide/figure chunk, sv://kb/<kb>/<src>:s<n>)
原稿 _talk.md ─┘            │
                            ├─ build ─> chunk + グラフ + BM25  (release context = kb-local = 全部入り)
                            │
想定質問 (LLM) ──┐          │
                 └─ KBAnswer ─> 回答候補 (公開分 / 全部) + 出典 URI
                                        │
                                   QA パック (.wxf)
                                        │
     声の質問 ──> Ask ──(1) パック照合 (0 ms)
                      ──(2) KB Graph-RAG (数 ms〜十数 ms)
                      ──(3) NeedWeb ──承諾──> web 検索 ─> 回答 + KB へ ingest
```

想定質問の生成にどの LLM を使うかは、**ノートブック自身の公開宣言**で決める
(`NBGetCloudPublishable`, rules/61)。Public 宣言のあるデッキだけクラウド
(Claude Code CLI)、宣言なし (Unspecified) と Private はローカル固定。
取り込み時の `PrivacyLevel` では決めない — 宣言と PL は別のものだから。
`"QuestionModel" -> "Cloud" | "Local"` で上書きできる。
CLI が使えないときはローカル LLM、それも無ければ定型質問へ落ちる。
宣言の読み取りは 107 MB のデッキでも 1.6 秒 (FE を開かない)。

## 3. プライバシー規則 (この層の中心)

索引は **全部入り** (`kb-local`) で作る。build 時に非公開を捨てると Private モードでも
読めなくなるため。**公開してよいかは回答時に決める**。

回答候補は 2 系統を焼き込む:

- `PublicAnswer` — PL <= `$SourceVaultTalkQAPublicMax` (既定 0.35) の資料**だけ**で作った答え。
  ただし「公開でありさえすればよい」ではなく、上位得点の 50% 以上の関連度を要求する
  (無関係な公開文で誤魔化さないため)。
- `FullAnswer` — 全部を使った答え。

実行時:

| モード | 公開分で答えられる | 公開分では答えられない |
|---|---|---|
| `Presentation` (既定) | `PublicAnswer` を Route "Public" で返す | **Status "Blocked"**「非公開の資料が必要なのでお答えできません」 |
| `Private` | `FullAnswer`、PL によって Route "Public" / **"Local"** (tsukuyomi が読む) | 同左 |

発表モードでは *tsukuyomi が要る質問には答えない*。答えられないことを答えるより、
答えられないと言う方が事故が小さい。

関連度が低いヒットは採らない (`$SourceVaultTalkQAMinScore`、既定 BM25 2.0)。
下回れば「資料に無い」= NeedWeb とする。低くすると、無関係な質問にもそれらしい嘘を返す。

## 4. 使い方

```wl
(* 作り置き (発表前に 1 回) *)
SourceVaultTalkQABuild["...deck.nb", "KBId" -> "cn", "QuestionsPerSlide" -> 3]

(* 実行時 *)
SourceVaultTalkQAAsk["フレドキンゲートとは何ですか"]      (* -> 0 ms *)
SourceVaultTalkQANeighbors[7, "Hops" -> 2]               (* 7 枚目の周辺 *)
SourceVaultTalkQAWebAnswer[q]                            (* 承諾後の web *)
SourceVaultTalkQAView[]                                   (* 中身を Dataset で *)

(* モード *)
$SourceVaultTalkQAMode = "Presentation" | "Private"
$SourceVaultTalkQAPublicMax = 0.35
```

音声からは gpt-realtime が `ask_sourcevault{query, allow_web}` を呼ぶ。
worker は要求を state に置き、pump が `$SourceVaultRealtimeAskHandler`
(= `SourceVaultTalkQAHandler`) を呼び、結果を control で返す。
worker は資料そのものを見ない — 話してよい文だけを受け取る。

## 5. 答えの文の選び方

KB は「どの chunk か」までを決める。**どの文を話すか**はこの層が決める。
実デッキで順に潰した結果、次の 4 つを掛け合わせている:

1. **内容語 2-gram の F2 (再現率重視)** — ひらがなだけの 2-gram (助詞・語尾) を
   落としてから、質問と候補文の両側で見る。片側 (再現率だけ) だと全部入りの
   一覧行がどの質問にも勝ち、全 2-gram でやると「開かれますか」の文法的一致で
   短い文が勝つ。素の Dice は正解の長い文を不当に下げた
   (「Oculus Riftはいつ出たのですか」に、Oculus しか共有しない短い別の文が勝った)。
   質問側だけ、ごく小さな言い換え表を通す (由来↔出どころ・語源 など)。
   候補は**上位 2 件から**集める。3 件に広げたら、話題語だけを含む短い文が
   増えて悪化した。
2. **観点の一致** — 場所・日時・数・理由・方法・定義。場所を訊かれたら
   場所を含む文を選ぶ。固有名詞が ASCII (UCNC 2026) で説明文が日本語のときは
   内容語が 1 つも重ならないので、これが無いと先頭の文が返る。
3. **見出し行・URL 行・つなぎの文を外す** — 「〜を説明します」「見ていきましょう」は
   事実を含まない。見出しは質問語と最もよく重なるが答えではない。
4. **短文は減点、1 文が短ければ次の文も足す**。
5. **組み立てた答えが質問と内容語を 1 つも共有しないなら、答えではない**
   (`< 0.03` で NeedWeb へ)。BM25 は「大学」のような一般語で下限を超えるので、
   これが無いと「大学の学費はいくらですか」に光学素子の説明を返す。

作り置きを採るかどうかも、鍵の重なりだけでは足りない。同じ固有名詞を含む
別の質問 (「UCNC 2026 での発表内容は」) に当たるので、
**質問文の内容語の近さ** (`$SourceVaultTalkQAPackSimilarity`, 既定 0.3) と
**観点の一致**を確かめ、外れたら KB を引き直す (数十 ms なので実用上ただ)。

## 6. 実測 (2026-08-22)

テストデッキ (3 枚、公開 + 非公開):

- 発表モードで非公開質問 → Blocked (PL 0.8 を検出)
- Private モードで同じ質問 → Route "Local" + 非公開の本文
- 資料に無い質問 → NeedWeb

実デッキ「20260823-オープンキャンパス VRとメタバース」(25 枚、Public 宣言、原稿あり):

- パック作成: 25 枚 / 75 問 で **196 秒** (クラウド LLM)
- 12 問の抜き打ちで 10 問が的確 (バードバス・世界初の HMD・HoloLens 2 の視野角・
  Vision Pro の方式・Oculus Rift の登場年)、資料に無い質問 (学費) は NeedWeb
- 弱いのは「〜の由来は」「〜と言い出したのは誰」型。事実が別のスライドにあり、
  BM25 が話題語を含むスライドを先に返す。言い換え表を足しても、
  話題語だけを含む短い文のほうが点が高くなる場合がある

実デッキ「計算と自然 31」(16 枚、PL 0.1、原稿あり):

- パック作成: 16 枚 / 48 問 で **143 秒** (クラウド LLM)
- パック照合 **0-2 ms** / KB 経由 **30-55 ms**
- 12 問の抜き打ちで、会期・開催地・投稿締切・当日の内容とも原稿から正しく回答
- 資料に無い質問 (天気) → NeedWeb

## 6.5 ウェブに逃がすとき

- 検索語には**いま出ているページの固有名詞**を足す (最大 2 語)。頭字語は文脈がないと
  決まらない: Anduril のページで「IVAS とは」と訊いて、別分野の IVAS が返った (実測)。
  足した語で 2 件未満なら、元の質問だけで引き直す (絞りすぎない)。
- 要約プロンプトにも「このスライドを表示している場面」と書いて渡す。
- 現在ページは覚えている値ではなく  でフロントエンドに訊く。
  発表者は手でもスライドを送るので、覚えている値は古くなる。
- 要約は**クラウド** (ウェブの結果は PL 0.0)。ローカルは 43 秒かかり、
  worker の ask タイムアウトに間に合わない。実測 9-15 秒。
- 検索結果の鍵の綴りは提供元次第 (SearXNG 経路は  / )。
- 結果は KB に取り込むので、同じ話題の次の質問は数十 ms。

## 6.6 「答えられない」の言い分け

- **資料に無い** → NeedWeb (ウェブで調べてよいか尋ねる)
- **検索サービスが止まっている** → Status "Unavailable"。
  「ウェブ検索のサービス (SourceVault の MCP) が止まっているので調べられません」。
  承諾を求めない (叶わない約束をしない)。落ちているかは SearXNG の応答で判定し、
  60 秒だけ覚えておく。handler は `serviceDown -> True` を返す。
- **非公開資料が要る** → Blocked (§3)

デッキを先に引き、足りないときだけ取り込み済みのウェブ資料を見る。
ウェブ本文が KB に増えると、デッキの内容がそれに負けることがあった。

答えの妥当性は、**質問に出てくる語 (英数字語・カタカナ語・漢字語) を chunk が
含むか**で見る。2-gram だけだと "IVAS" が "Glass" と "as" で重なる。
判定は chunk 全体 (見出し込み) で行い、URL は除く
(出典行の "ivas-project" で「この資料は IVAS を扱っている」と誤認した)。

## 7. 落とし穴 (実測で踏んだもの)

1. **KB の `AnswerText` は「質問と最も重なる 1 文」**なので、見出し行が勝ちやすい
   (「フレドキンゲートとは」→ 見出し「フレドキンゲート」)。本文から 1〜2 文を組み立て直す。
2. **LLM のエラー本文が想定質問として保存される** (CLI の認証切れ)。応答は必ず
   エラーゲートに通す (SourceVault のサマリー層と同じ罠)。
3. **`SourceVaultKBBuild[kb]` を素で呼ぶと索引が kb-public に戻る**。TalkQA が使う KB を
   建て直すときは `"ReleaseContext" -> "kb-local"` を必ず渡す。
4. **日本語の 2-gram をそのまま鍵にすると助詞で誤爆する** (「東京の明日の天気は」が
   「可逆計算とは」に当たった)。ひらがなだけの 2-gram は鍵から外す。
5. **MaxPrivacyLevel は結果全体の最大**なので、1 件でも非公開が混ざると全部が
   非公開扱いになる。公開分だけの答えを別に作る。
6. **画像だけのスライドは chunk が見出し 1 行になる**。実デッキの 16 枚中 5 枚が
   これで、中身は原稿にしかなかった。原稿を `"SlideNotes"` で同じスライド chunk に
   入れる (ノード・URI・引用はそのまま、本文だけが充実する)。
7. **headless では SlideWorkflow が読まれていない**ので、原稿を黙って取りこぼす。
   `iTQTalkTexts` が必要なら `Needs` し、それでも駄目なら `<deck>_talk.md` を自前で読む。
   build の出力に「原稿 N 枚分」が出ることを毎回確かめる。
8. **テストを `wolframscript -file` で書くときは日本語を `\:xxxx` に**。
   非 ASCII リテラルはバイト列として読まれ、当たるはずの質問が NeedWeb になる
   (製品の不具合と見分けがつかない)。

## 8. まだやっていないこと

- 想定質問の網羅性を上げる (いまは 1 枚あたり n 問を 1 回生成するだけ)。
- 図キャプション (`SourceVaultKBCaptionFigures`) を使った図についての質問。
- web ingest の自動再構築のスケジューリング (いまは都度 build)。
- 字幕表示 (音声側の履歴からは作れる)。
- 「由来」「誰が」型の質問で、事実のあるスライドを先に出す (語の重みづけ / IDF)。
