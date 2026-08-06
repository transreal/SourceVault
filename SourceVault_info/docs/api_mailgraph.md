# SourceVault_mailgraph API リファレンス

## 概要
`SourceVault_mailgraph.wl` は、Microsoft Graph API 経由で Microsoft 365 / Exchange Online のメールボックスからメールを取得する source provider である。Exchange Online が基本認証 IMAP を恒久的に無効化したため、imaplib ベースの source を `outlook.office365.com` に向けることはできない。本パッケージは **トランスポートのみを置き換え**、[SourceVault_maildb](https://github.com/transreal/SourceVault_maildb) のレコード契約 (id / date / subject / from / to / cc / body / attachment / rawheader) はそのまま維持する。

認証は OAuth 2.0 device-code フロー + refresh token。`$SourceVaultMailSourceProviders["Graph"]` に自己登録し、`SourceVaultMailFetchNew` がアカウントの `AuthMethod` でディスパッチする。本ファイルが不在でも maildb は無変更で動作する (弱結合)。ロード順は `SourceVault_maildb.wl` の後。

内部メッセージヘッダが取得できた場合、レコードにトップレベルキー `"Authentication-Results"` が追加され、`SourceVaultSenderAuthentication` および [SourceVault_mining](https://github.com/transreal/SourceVault_mining) の配送系機能に供給される。

外部依存はヘッドレステスト用に注入可能:
- `$SourceVaultGraphHTTPHandler` (None = 実 `URLRead`)
- 資格情報バックエンドは [NBAccess](https://github.com/transreal/NBAccess) の `NBAccess`$NBCredentialBackend` に従う ("Memory" ならカーネル内ストア、`SystemCredential` に書き込まない)

## セットアップ (メールボックスごとに一度)
```wolfram
SourceVaultRegisterGraphMailAccount[<|
  "MBox" -> "univ365",
  "Email" -> "user@example.ac.jp",
  "ClientId" -> "<app id>",
  "TenantId" -> "<tenant id>"|>];
SourceVaultMailGraphAuthorize["univ365"]   (* ブラウザでサインイン、一度だけ *)
```
以後 `SourceVaultMailFetchNew["univ365"]` が IMAP アカウントと同様に動作する。以前 IMAP で同期していた**同じ MBox 名**で再登録すると、RecordId (Message-ID ベース) が同一のまま維持されるので、履歴と重複検出がシームレスに引き継がれる。

## 登録

### SourceVaultRegisterGraphMailAccount[assoc]
Microsoft 365 / Exchange Online メールボックスを `AuthMethod -> "Graph"` で登録する。内部で `SourceVaultRegisterMailAccount` を呼び、`Server -> "graph.microsoft.com"`, `Port -> 443` を固定設定する。
→ Association (`SourceVaultRegisterMailAccount` の戻り値、または `<|"Status" -> "Error", "Reason" -> ...|>`)
assoc のキー:
- `"MBox"` (必須, 別名 `"mbox"`) — 未指定なら `Reason -> "MissingMBox"`
- `"ClientId"` (必須, 別名 `"clientId"`) — Entra ID アプリケーション (クライアント) ID。空なら `Reason -> "MissingClientId"`
- `"Email"` / `"User"` — 相互にフォールバック
- `"TenantId"` — 既定 `"organizations"`
- `"CredKey"` — refresh token を保持する資格情報名。既定 `"SV_GRAPH_REFRESH_<mbox>"`
引数が Association でない場合は `<|"Status" -> "Error", "Reason" -> "InvalidArguments"|>`。

## 認証

### SourceVaultMailGraphAuthorize[mbox, opts]
OAuth 2.0 device-code サインインを実行する。ユーザコードを `Print` し、Microsoft の検証ページを開き、サインイン完了までポーリングし、refresh token をアカウントの `CredKey` に保存する。最初に一度だけ必要で、以後は refresh token が失効・失効解除された場合のみ再実行する。
→ Association `<|"Status" -> "Authorized"|"Error", "MBox" -> ..., "RefreshTokenStored" -> True|False, "ExpiresIn" -> _Integer|>`
Options: "MaxWait" -> 900 (最大待機秒数。device code の `expires_in` との `Min` を採用), "OpenBrowser" -> True (`SystemOpen` で検証 URI を開く)
エラー `Reason`: `"UnregisteredMailbox"`, `"NotGraphAccount"` (AuthMethod が "Graph" でない), `"MissingClientId"`, `"DeviceCodeRequestFailed"` (+`"Detail"`), `"AuthorizationFailed"` (+`"Detail"`), `"AuthorizationTimeout"`。
ポーリング挙動: サーバの `interval` (既定 5 秒) で `Pause`、`error` が `"authorization_pending"` なら継続、`"slow_down"` なら interval を +5 秒。
資格情報書き込みに失敗した場合は `"Status" -> "Error"`, `"Reason" -> "CredentialWriteVerifyFailed"`, `"Hint"` が返る。

### SourceVaultMailGraphStatus[mbox] → Association
メール本文を取得せずに Graph アカウントの状態を検査する。refresh token の有無、アクセストークン取得可否、`/me/messages` の `$top=1` プローブを順に確認する。
戻り値パターン:
- `<|"Status" -> "Ok", "MBox" -> ..., "HasRefreshToken" -> True, "ProbeMessages" -> _Integer, "CredentialWriteError" -> _|Missing["None"]|>`
- `<|"Status" -> "NotAuthorized", "MBox", "HasRefreshToken" -> False, "CredKey", "Hint"|>`
- `<|"Status" -> "Error", "Reason" -> "UnregisteredMailbox"|"NotGraphAccount"|"TokenRefreshFailed"|"GraphProbeFailed", ...|>`
`"CredentialWriteError"` には、直近の fetch 中に発生した refresh token ローテーション書き込み失敗が入る (fetch 自体は中断させずに可視化する設計)。

## メール取得

### SourceVaultMailGraphSource[mbox, srcOpts] → List of Association
`$SourceVaultMailSourceProviders["Graph"]` に登録される MessageSource provider。Microsoft Graph からメッセージ (およびファイル添付) を取得し、maildb 形状のレコードリストを返す。通常は `SourceVaultMailFetchNew` 経由で呼ばれ、直接呼ぶ必要はない。
srcOpts (Association) のキー:
- `"Period"` — 既定 `"Latest"`。imap source と同一の文法 (`SourceVault`Private`iSVIMAPDateRange` を再利用)。ローカル日境界を UTC 瞬時に変換して Graph の `$filter` に渡す
- `"MaxEmails"` — 既定 `Automatic`。Integer なら `$top` は `Min[50, Max[1, maxN]]`、収集数が maxN に達した時点で打ち切り

レコード形状:
```
<|"id" -> internetMessageId (無ければ subject、無ければ Graph id),
  "date" -> ローカル時刻の {"ISODateTime","ISOTimeZone"} 文字列,
  "subject", "from", "to", "cc", "body",
  "attachment" -> 保存済みファイル名のカンマ連結,
  "rawheader" -> "Name: Value" を改行連結,
  ("Authentication-Results" -> ヘッダ値; 取得できた場合のみ)|>
```
エラー時は 1 要素リスト `{<|"_error" -> "..."|>}` を返す。`_error` の種別: `"UnregisteredMailbox: ..."`, `"NoRefreshToken (...): run SourceVaultMailGraphAuthorize[...] once"`, `"TokenRefreshFailed: ..."`, `"BadPeriod: ..."`, `"GraphListFailed: ..."`。

動作上の注意 (非自明):
- 一覧は `$orderby receivedDateTime desc` で取得するが、返す前に `Reverse` するので **古い順** (imap source と同じ)。
- `$select` に `internetMessageHeaders` を含めて一覧取得を試み、テナントが HTTP 400 を返した場合は自動的にヘッダ抜きで再取得し、メッセージごとに `/me/messages/<id>?$select=internetMessageHeaders` でヘッダを個別取得する。
- `@odata.nextLink` を辿ってページングする (ガード上限 500 ページ)。
- `receivedDateTime` は UTC なので `$TimeZone` へ変換する。これにより ISO 日付と添付の `yyyymm` バケットが、imap source が送信者の `Date` ヘッダから作ったものと一致する。
- 添付は imap source と同じレイアウト `<legacyRoot>/<mbox>/<yyyymm>_attachment/<name>` に保存する。`legacyRoot` は `$SourceVaultLegacyMailRoot`、未設定なら `PrivateVault` ルートの親配下の `mails`。
- `contentBytes` を持たない添付 (`itemAttachment` / `referenceAttachment`) はスキップする。
- 本文は Graph の `body.content` をそのまま格納する (HTML の場合は HTML のまま)。

例:
```wolfram
(* provider を直接呼ぶ場合 *)
recs = SourceVaultMailGraphSource["univ365", <|"Period" -> "Latest", "MaxEmails" -> 20|>];
(* 通常はこちら *)
SourceVaultMailFetchNew["univ365"]
```

## 変数

### $SourceVaultGraphHTTPHandler
型: None | Function, 初期値: None
ヘッドレステスト用の HTTP シーム。`None` (または `Automatic`) なら実 `URLRead` を使う。それ以外は `Function[request]` で、`<|"Method", "URL", "Headers", "Body"|>` を受け取り `<|"StatusCode", "BodyBytes"|"Body"|>` を返す。実 HTTP は 180 秒の `TimeConstrained` 付き、失敗時は `<|"StatusCode" -> 0, "Body" -> "", "Error" -> "HTTPFailed"|>`。
例:
```wolfram
$SourceVaultGraphHTTPHandler = Function[req,
  Which[
    StringContainsQ[req["URL"], "/token"],
      <|"StatusCode" -> 200,
        "Body" -> ExportString[<|"access_token" -> "AT", "expires_in" -> 3600,
          "refresh_token" -> "RT"|>, "RawJSON"]|>,
    True, <|"StatusCode" -> 200,
      "Body" -> ExportString[<|"value" -> {}|>, "RawJSON"]|>]];
```
JSON デコードは `BodyBytes` があれば `ImportByteArray[..., "RawJSON"]` を使うので、カーネル既定エンコーディングに依らず UTF-8 (日本語) が保持される。ハンドラ注入のフェイクでは `"Body"` 文字列でもよい。

### $SourceVaultGraphScope
型: String, 初期値: `"https://graph.microsoft.com/Mail.Read offline_access"`
Microsoft Entra ID に要求する OAuth スコープ文字列。device-code 要求と refresh token 交換の両方で使われる。

## 資格情報保存の設計メモ
refresh token の保存先は `NBAccess`$NBCredentialBackend` に従う。`"Memory"` (テスト用) ならカーネル内 Association、それ以外は `SystemCredential`。

Windows の資格情報 BLOB にはサイズ上限があり、書き込みが**無言で失敗しうる** (NBAccess key-index の事故)。このため:
- 値は 800 文字 (`$iSVMGChunk`) ごとに分割し、`<key>#1`, `<key>#2`, ... に保存、`<key>` 本体には `"SVMGCHUNKED:<n>"` を書く
- 書き込み後は必ず読み戻して検証し、不一致なら `<|"Status" -> "Error", "Reason" -> "CredentialWriteVerifyFailed", "Key", "Hint"|>` を返す
- fetch 中の refresh token ローテーション書き込みが失敗しても、その回の取得は中断しない。失敗は `SourceVaultMailGraphStatus` の `"CredentialWriteError"` で可視化される

アクセストークンはメールボックス単位でカーネル内にキャッシュされ、期限の 120 秒前までは再利用される。

## テナント/エンドポイント
- authority: `https://login.microsoftonline.com/<TenantId>/oauth2/v2.0` (`/devicecode`, `/token`)
- Graph base: `https://graph.microsoft.com/v1.0`
- 一覧の `$select`: `id,internetMessageId,receivedDateTime,subject,from,toRecipients,ccRecipients,body,hasAttachments` (+ 可能なら `,internetMessageHeaders`)