# SourceVault_integrityview API リファレンス

パッケージ: SourceVault_integrityview (https://github.com/transreal/SourceVault_integrityview)
コンテキスト: `SourceVault``。Private: `SourceVault`IntegrityViewPrivate``
読み込み: `Block[{$CharacterEncoding = "UTF-8"}, Get["SourceVault_integrityview.wl"]]`

## 概要
知識ネットワーク健全性監視 (03 SystemDoctor 拡張仕様 v0.4) の View (10 章)。FE カーネル専用。
core 関数 (SourceVault_integrity.wl / SourceVault_provenance.wl) が返す Association を表示するだけ (core/View 分離)。
表示するのは ID・件数・ラベル・LogicalRef まで。Entity の本文は出さない。
行の操作は記入済みの式テンプレートを下のセルに置く (式中心の UI)。ボタンは評価せず Input セルを挿入するだけ。
所有者操作は `SourceVaultIntegrityOwnerAction[...]` で包む。評価すると確認 → ticket のダイアログ → 実行になる。
Dataset のボタンは 1 列目のタグ + ItemDisplayFunction (maildb の正準の規約)。
セル操作は NBAccess の API のみ使用 (NBInsertInputTemplate, NBParentNotebookOfCurrentCell, NBCurrentCellIndex, NBMoveAfterCell)。セル番号が取れないときは入力ノートの選択位置に書く。
依存: SourceVault_integrity (SourceVaultKnowledgeHealth, SourceVaultIntegrityState, SourceVaultInstructionFiles, SourceVaultModelManifest, SourceVaultModelManifestDiff, SourceVaultIntegrity* の所有者操作), SourceVault_provenance (SourceVaultProvResolve, ProvenancePrivate の索引), NBAccess (https://github.com/transreal/NBAccess)。
core が使えない場合は Panel に日本語のメッセージを返す (state.json 無し・索引が読めない・版が見つからない等)。

## 公開関数

### SourceVaultKnowledgeHealthView[] → Panel
知識ネットワークの健全性ダッシュボード (§10.1)。FE 専用。
表示内容:
- 状態の時刻と経過秒数
- 未解決の重大 Finding の件数 (うち Instruction 系)
- 来歴の充足率 (活性な版、Instruction を除く総率。Instruction の基準の充足は別に併記)
- 隔離中の版の数とレビュー債務
- KHI (参考値、判定に使わない)
- 部品別の状態 (Health・ReasonCode)。各行の「Finding」ボタンは `SourceVaultIntegrityFindingsView["Component" -> name]` のテンプレートを置く
- Kind × 出自の区分 (OwnerOnly / ModelOverOwner / ExternalDerived / Unknown) の活性な版の数と隔離中の数
state.json が無いときは「service の検証器がまだ動いていません」の Panel を返す。

### SourceVaultIntegrityFindingsView[opts]
Entity の Finding の一覧 (§10.3)。重大度・部品・種類・対象・影響範囲・状態。
→ Dataset (該当なし/索引不可のときは Panel)
Options: "Status" -> "Open" ("Open" なら Resolution が Open/Acknowledged のみ、All で全件), "Component" -> All (部品名の文字列で絞る。Kind から部品を引く: InjectionResidue / CitationIntegrity / GeneratedCodeHealth / EntityDrift は "Integrity"、その他は "KnowledgeHealth"), "Limit" -> 100 (重大度順 Critical>High>Medium>Low>Info、同順位は Seq の新しい順に先頭から)
Dataset の列: 操作, 重大度, 部品, 種類, 理由, 対象, 子孫, 公開済み, 状態, FindingId。
「操作」列のボタン (式テンプレートを挿入):
- 系譜: `SourceVaultLineageView[target]`
- 確認: `SourceVaultIntegrityOwnerAction[SourceVaultIntegrityRecordOwnerReview[target, "範囲を書く", "メモ"]]`
- 隔離: `SourceVaultIntegrityOwnerAction[SourceVaultIntegrityQuarantine[target, "理由を書く"]]`
- 解決: `SourceVaultIntegrityOwnerAction[SourceVaultIntegrityResolveFinding[fid, <|"Kind" -> "FalsePositive", "Reason" -> "理由を書く"|>]]`
対象 (Targets の先頭が文字列) が無い行は系譜/確認/隔離ボタンを出さない。
例: SourceVaultIntegrityFindingsView["Status" -> All, "Component" -> "Integrity", "Limit" -> 50]

### SourceVaultLineageView[ref_String, opts]
版の系譜 (§10.2)。ref は SourceVaultProvResolve で解決される。FE 専用。
→ Panel (Graph + 凡例)。解決できないとき・索引が読めないときは Panel のメッセージ。
Options: "Direction" -> "Both" ("Up" | "Down" | "Both"), "Depth" -> 3 (辿る段数), "Kinds" -> All (Kind のリストで絞る。起点は常に残す)
表示規約:
- 頂点の色は利用可否: Usable 緑 / Pending 灰青 / Quarantined 赤 / Unknown 灰 (Recorded は薄灰)
- 頂点のラベルは Kind と出自の区分 (OriginClass)
- 起点の頂点は大きく描く
- Cite の辺は点線 (隔離を伝えない)。先が Quarantined の辺は赤。carry 辺で隔離は伝わり、段数で弱まらない
- Up は親 (ParentsX)、Down は carry/cite の子を辿る。レイアウトは LayeredDigraphEmbedding
例: SourceVaultLineageView["sv://...", "Direction" -> "Up", "Depth" -> 2]

### SourceVaultInstructionsView[] → Dataset
Instruction 系ファイルの一覧 (§10.3)。FE 専用。ファイルが無いときは Panel のメッセージ。
Dataset の列: 操作, 群 ("モデルが書き得る" / "手編集"), 種別, ファイル, 基準 ("未受入" / "一致" / "変更あり"), 認可 (用途名 or "-")。
「操作」列のボタン:
- 認可: `SourceVaultIntegrityOwnerAction[SourceVaultIntegrityAuthorizeInstruction[path, purpose]]`
- 基準: `SourceVaultIntegrityOwnerAction[SourceVaultIntegrityAcceptBaseline["Instructions"]]` (基準の一括受入)

### SourceVaultModelManifestView[] → Panel
LM Studio のモデル manifest (§10.3)。FE 専用。
ヘッダ: Runtime バージョン・IdentityEvidence・重みの全体ハッシュ時刻 (未計算なら「未計算」)。
基準との差: 新規 / テンプレート変化 / 脆弱性表の該当の件数。基準が無いときは「基準を受け入れる」ボタン (`SourceVaultIntegrityOwnerAction[SourceVaultIntegrityAcceptBaseline["ModelManifest"]]`)。
Dataset の列: モデル, 種類, 形式, 大きさ (MB), テンプレート (digest の先頭), 変化 ("テンプレート" / "新規" / "")。
manifest が取れない (LM Studio の機ではない) ときはその旨の Panel を返す。

### SourceVaultProvenanceCoverageView[] → Panel
記録点ごとの来歴の充足率 (§10.3、Kind 別の Complete の割合) と記録の無い LLMCall の件数。FE 専用。
7 日分の Provenance 部品 Coverage チェックの Health・ReasonCode と、Kind ごとの 派生 / Complete / 割合 の表、`UnrecordedLLMDerivations` 件数を表示する。
state.json が無いときは Panel のメッセージ。活動が無いときは「(活動がありません)」。

## 内部規約 (Private、参考)
- `iSVIVButton[label, expr]`: 式 expr を評価せずテンプレートとして下のセルに挿入するボタン (Method -> "Queued", Frameless)。NBAccess が無い/セル不明なら $Failed。
- `iSVIVProv[name, args]`: `SourceVault`ProvenancePrivate`name` を呼ぶ。未定義・失敗は $Failed。
- 色: 部品 Health は OK 緑 / Degraded 橙 / Failing 赤。利用可否色は `$iSVIVUsabilityColor`。
- Dataset のボタンは `iSVIVFindingAct[fid, target]` / `iSVIVInstrAct[path, purpose]` のタグを ItemDisplayFunction で Row[ボタン] に置換する。