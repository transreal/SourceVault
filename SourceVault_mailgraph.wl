(* ::Package:: *)

(* ============================================================
   SourceVault_mailgraph.wl -- Microsoft Graph mail source provider
   This file is pure ASCII, encoded in UTF-8.

   Purpose: fetch mail for a registered mailbox directly from
   Microsoft 365 / Exchange Online through the Microsoft Graph API
   (OAuth 2.0 device-code flow + refresh token). Exchange Online has
   permanently disabled basic-auth IMAP, so the imaplib source cannot
   be pointed at outlook.office365.com; this provider replaces the
   transport while keeping the maildb record contract unchanged:
   id / date / subject / from / to / cc / body / attachment / rawheader
   (plus a top-level "Authentication-Results" key when the real
   internet message headers are available, which feeds
   SourceVaultSenderAuthentication and the mining delivery features).

   Wiring: registers itself under $SourceVaultMailSourceProviders["Graph"];
   SourceVaultMailFetchNew dispatches on the account's AuthMethod.
   maildb works unchanged when this file is absent (weak coupling).
   Load order: after SourceVault_maildb.wl.

   Setup (once per mailbox):
     SourceVaultRegisterGraphMailAccount[<|"MBox" -> "univ365",
       "Email" -> "user@example.ac.jp", "ClientId" -> "<app id>",
       "TenantId" -> "<tenant id>"|>];
     SourceVaultMailGraphAuthorize["univ365"]   (browser sign-in, one time)
   then SourceVaultMailFetchNew["univ365"] works as with IMAP accounts.
   Re-registering the SAME MBox name that was previously synced over IMAP
   keeps RecordIds (Message-ID based) identical, so history and duplicate
   detection carry over seamlessly.

   External dependencies are injectable for headless tests:
   - $SourceVaultGraphHTTPHandler (None = real URLRead)
   - credential backend follows NBAccess`$NBCredentialBackend
     ("Memory" -> in-kernel store, no SystemCredential writes).
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultRegisterGraphMailAccount::usage =
  "SourceVaultRegisterGraphMailAccount[<|\"MBox\", \"Email\", \"ClientId\", \
\"TenantId\", (\"CredKey\")|>] registers a Microsoft 365 / Exchange Online \
mailbox fetched through the Microsoft Graph API (AuthMethod -> \"Graph\"). \
TenantId defaults to \"organizations\"; CredKey (credential-store name that \
will hold the OAuth refresh token) defaults to \"SV_GRAPH_REFRESH_<mbox>\". \
After registration run SourceVaultMailGraphAuthorize[mbox] once to sign in.";
SourceVaultMailGraphAuthorize::usage =
  "SourceVaultMailGraphAuthorize[mbox, opts] runs the OAuth 2.0 device-code \
sign-in for a Graph mail account: prints a user code, opens the Microsoft \
verification page, polls until the sign-in completes, and stores the refresh \
token under the account's CredKey. Needed once, and again only when the \
refresh token expires or is revoked. opts: \"MaxWait\" (default 900 seconds), \
\"OpenBrowser\" (default True).";
SourceVaultMailGraphStatus::usage =
  "SourceVaultMailGraphStatus[mbox] checks a Graph mail account without \
fetching mail bodies: refresh token present, access token obtainable, and a \
$top=1 probe of /me/messages. Returns <|\"Status\" -> ..., ...|>.";
SourceVaultMailGraphSource::usage =
  "SourceVaultMailGraphSource[mbox, srcOpts] is the MessageSource provider \
registered as $SourceVaultMailSourceProviders[\"Graph\"]: fetches messages \
(and file attachments) from Microsoft Graph for the registered account and \
returns maildb-shaped records (id/date/subject/from/to/cc/body/attachment/\
rawheader, plus \"Authentication-Results\" when headers are available). \
srcOpts: \"Period\" (same grammar as the imap source), \"MaxEmails\". \
Normally invoked through SourceVaultMailFetchNew.";
$SourceVaultGraphHTTPHandler::usage =
  "$SourceVaultGraphHTTPHandler is the HTTP seam for headless tests: None \
(default) uses real URLRead; otherwise a Function[request] receiving \
<|\"Method\", \"URL\", \"Headers\", \"Body\"|> and returning \
<|\"StatusCode\", \"BodyBytes\"|\"Body\"|>.";
$SourceVaultGraphScope::usage =
  "$SourceVaultGraphScope is the OAuth scope string requested from Microsoft \
Entra ID (default \"https://graph.microsoft.com/Mail.Read offline_access\").";

Begin["`MailGraphPrivate`"];

(* ---- defaults / state ---- *)
If[! ValueQ[$SourceVaultGraphHTTPHandler], $SourceVaultGraphHTTPHandler = None];
If[! ValueQ[$SourceVaultGraphScope],
  $SourceVaultGraphScope = "https://graph.microsoft.com/Mail.Read offline_access"];
If[! AssociationQ[$iSVMGTokens], $iSVMGTokens = <||>];
If[! AssociationQ[$iSVMGMemCreds], $iSVMGMemCreds = <||>];
If[! AssociationQ[$iSVMGLastCredError], $iSVMGLastCredError = <||>];
$iSVMGGraphBase = "https://graph.microsoft.com/v1.0";
$iSVMGChunk = 800;   (* chars per Windows credential blob (small limit, see below) *)

(* ---- HTTP (injectable seam) ---- *)
iSVMGHTTP[req_Association] :=
  If[$SourceVaultGraphHTTPHandler === None || $SourceVaultGraphHTTPHandler === Automatic,
    iSVMGRealHTTP[req], $SourceVaultGraphHTTPHandler[req]];

iSVMGRealHTTP[req_Association] :=
  Module[{spec, resp},
    spec = <|Method -> Lookup[req, "Method", "GET"],
      "Headers" -> Normal[Lookup[req, "Headers", <||>]]|>;
    With[{b = Lookup[req, "Body", None]}, If[StringQ[b], spec["Body"] = b]];
    resp = TimeConstrained[
      Quiet@Check[URLRead[HTTPRequest[req["URL"], spec]], $Failed], 180, $Failed];
    If[Head[resp] =!= HTTPResponse,
      Return[<|"StatusCode" -> 0, "Body" -> "", "Error" -> "HTTPFailed"|>]];
    <|"StatusCode" -> resp["StatusCode"], "BodyBytes" -> resp["BodyByteArray"]|>];

(* JSON decode via ByteArray so UTF-8 (Japanese) survives regardless of the
   kernel's default encoding; string fallback for handler-injected fakes. *)
iSVMGJSON[resp_Association] :=
  Module[{bb = Lookup[resp, "BodyBytes", Missing[]], b},
    Which[
      ByteArrayQ[bb], Quiet@Check[ImportByteArray[bb, "RawJSON"], $Failed],
      StringQ[b = Lookup[resp, "Body", Missing[]]] && b =!= "",
        Quiet@Check[ImportString[b, "RawJSON"], $Failed],
      True, $Failed]];
iSVMGJSON[_] := $Failed;

(* OAuth endpoints return "error" as a string; Graph returns an object. *)
iSVMGErrorDetail[resp_, json_] :=
  Which[
    AssociationQ[json] && KeyExistsQ[json, "error"],
      With[{e = json["error"]},
        If[AssociationQ[e],
          ToString@Lookup[e, "code", ""] <> ": " <> ToString@Lookup[e, "message", ""],
          ToString[e] <> " " <> ToString@Lookup[json, "error_description", ""]]],
    AssociationQ[resp], "HTTP " <> ToString@Lookup[resp, "StatusCode", 0],
    True, "NoResponse"];

iSVMGQuery[fields_List] :=
  StringRiffle[(#[[1]] <> "=" <> URLEncode[ToString[#[[2]]]]) & /@ fields, "&"];

iSVMGFormPost[url_String, fields_List] :=
  iSVMGHTTP[<|"Method" -> "POST", "URL" -> url,
    "Headers" -> <|"Content-Type" -> "application/x-www-form-urlencoded"|>,
    "Body" -> iSVMGQuery[fields]|>];

iSVMGGraphGET[url_String, token_String] :=
  iSVMGHTTP[<|"Method" -> "GET", "URL" -> url,
    "Headers" -> <|"Authorization" -> "Bearer " <> token,
      "Accept" -> "application/json"|>|>];

(* ---- credential storage (refresh token) ----
   Backend follows NBAccess`$NBCredentialBackend: "Memory" (tests) keeps the
   token in-kernel; anything else uses SystemCredential. Windows credential
   blobs have a small size limit and writes can FAIL SILENTLY (the NBAccess
   key-index incident), so values are chunked to $iSVMGChunk chars and every
   write is verified by reading it back. *)
iSVMGCredBackend[] :=
  If[TrueQ[Quiet@Check[NBAccess`$NBCredentialBackend === "Memory", False]],
    "Memory", "SystemCredential"];

(* 2026-08-06: SystemCredential \:76f4\:63a5\:547c\:3073\:51fa\:3057\:3092\:3084\:3081 NBAccess \:306e\:6b63\:898f\:53e3\:3092\:901a\:3059\:3002
   \:623b\:308a\:5024\:306e\:5951\:7d04 (\:5931\:6557\:3067 $Failed) \:306f\:5f93\:6765\:3068\:540c\:3058\:306b\:4fdd\:3064\:3002 *)
iSVMGSysCredGet[key_String] :=
  With[{v = Quiet@Check[NBAccess`NBGetCredential[key], $Failed]},
    If[StringQ[v], v, $Failed]];
iSVMGSysCredSet[key_String, val_String] :=
  If[TrueQ[Quiet@Check[NBAccess`NBSetCredential[key, val], $Failed]],
    val, $Failed];

iSVMGCredRead[key_String] :=
  Module[{v, n, parts},
    If[iSVMGCredBackend[] === "Memory",
      Return[Lookup[$iSVMGMemCreds, key, Missing["NoCredential"]]]];
    v = iSVMGSysCredGet[key];
    If[! StringQ[v], Return[Missing["NoCredential"]]];
    If[! StringStartsQ[v, "SVMGCHUNKED:"], Return[v]];
    n = Quiet@Check[ToExpression[StringDrop[v, StringLength["SVMGCHUNKED:"]]], 0];
    If[! IntegerQ[n] || n <= 0, Return[Missing["BadChunkHeader"]]];
    parts = Table[iSVMGSysCredGet[key <> "#" <> ToString[i]], {i, n}];
    If[AllTrue[parts, StringQ], StringJoin[parts], Missing["ChunkMissing"]]];

iSVMGCredWrite[key_String, val_String] :=
  Module[{parts, back},
    If[iSVMGCredBackend[] === "Memory",
      $iSVMGMemCreds[key] = val;
      Return[<|"Status" -> "Stored", "Backend" -> "Memory"|>]];
    If[StringLength[val] <= $iSVMGChunk,
      iSVMGSysCredSet[key, val],
      parts = StringPartition[val, UpTo[$iSVMGChunk]];
      MapIndexed[iSVMGSysCredSet[key <> "#" <> ToString[First[#2]], #1] &, parts];
      iSVMGSysCredSet[key, "SVMGCHUNKED:" <> ToString[Length[parts]]]];
    back = iSVMGCredRead[key];
    If[back === val,
      <|"Status" -> "Stored", "Backend" -> "SystemCredential",
        "Chunks" -> Max[1, Ceiling[StringLength[val]/$iSVMGChunk]]|>,
      <|"Status" -> "Error", "Reason" -> "CredentialWriteVerifyFailed",
        "Key" -> key,
        "Hint" -> "Windows credential blob write did not read back; the value may exceed the store's size limit."|>]];

(* ---- account helpers ---- *)
iSVMGAccount[mbox_String] := SourceVault`SourceVaultGetMailAccount[mbox];

iSVMGCredKeyOf[mbox_String, acct_Association] :=
  With[{ck = ToString@Lookup[acct, "CredKey", ""]},
    If[StringTrim[ck] === "", "SV_GRAPH_REFRESH_" <> mbox, ck]];

iSVMGTenant[acct_Association] :=
  With[{t = ToString@Lookup[acct, "TenantId", ""]},
    If[StringTrim[t] === "", "organizations", t]];

iSVMGAuthority[acct_Association] :=
  "https://login.microsoftonline.com/" <> iSVMGTenant[acct] <> "/oauth2/v2.0";

(* ---- token cache / refresh ---- *)
iSVMGStoreTokens[mbox_String, acct_Association, tok_Association, via_String] :=
  Module[{rt, wr = <|"Status" -> "Skipped"|>, res},
    $iSVMGTokens[mbox] = <|
      "AccessToken" -> ToString@Lookup[tok, "access_token", ""],
      "ExpiresAt" -> AbsoluteTime[] +
        With[{e = Lookup[tok, "expires_in", 3600]}, If[NumericQ[e], Round[e], 3600]]|>;
    rt = Lookup[tok, "refresh_token", Missing[]];
    If[StringQ[rt] && rt =!= "",
      wr = iSVMGCredWrite[iSVMGCredKeyOf[mbox, acct], rt]];
    res = <|
      "Status" -> Which[
        Lookup[wr, "Status", ""] === "Error", "Error",
        via === "Authorize", "Authorized",
        True, "Refreshed"],
      "MBox" -> mbox,
      "RefreshTokenStored" -> (Lookup[wr, "Status", ""] === "Stored"),
      "ExpiresIn" -> With[{e = Lookup[tok, "expires_in", 3600]},
        If[NumericQ[e], Round[e], 3600]]|>;
    If[Lookup[wr, "Status", ""] === "Error",
      res["Reason"] = Lookup[wr, "Reason", "CredentialWriteFailed"];
      res["Hint"] = Lookup[wr, "Hint", Missing[]]];
    res];

(* Returns the access token String, or an <|"_error" -> ...|> record. *)
iSVMGAccessToken[mbox_String, acct_Association] :=
  Module[{cache, key, rt, resp, tok, stored},
    cache = Lookup[$iSVMGTokens, mbox, Missing[]];
    If[AssociationQ[cache] && StringQ[Lookup[cache, "AccessToken", Missing[]]] &&
       Lookup[cache, "AccessToken", ""] =!= "" &&
       Lookup[cache, "ExpiresAt", 0] - 120 > AbsoluteTime[],
      Return[cache["AccessToken"]]];
    key = iSVMGCredKeyOf[mbox, acct];
    rt = iSVMGCredRead[key];
    If[! StringQ[rt],
      Return[<|"_error" -> "NoRefreshToken (" <> ToString[rt] <>
        "): run SourceVaultMailGraphAuthorize[\"" <> mbox <> "\"] once"|>]];
    resp = iSVMGFormPost[iSVMGAuthority[acct] <> "/token", {
      "client_id" -> ToString@Lookup[acct, "ClientId", ""],
      "grant_type" -> "refresh_token",
      "refresh_token" -> rt,
      "scope" -> $SourceVaultGraphScope}];
    tok = iSVMGJSON[resp];
    If[! AssociationQ[tok] || ! KeyExistsQ[tok, "access_token"],
      Return[<|"_error" -> "TokenRefreshFailed: " <> iSVMGErrorDetail[resp, tok] <>
        " -- if the refresh token expired, run SourceVaultMailGraphAuthorize[\"" <>
        mbox <> "\"] again"|>]];
    stored = iSVMGStoreTokens[mbox, acct, tok, "Refresh"];
    (* a failed rotation write must not kill this run's fetch, but is kept
       visible through SourceVaultMailGraphStatus *)
    If[Lookup[stored, "Status", ""] === "Error", $iSVMGLastCredError[mbox] = stored];
    Lookup[Lookup[$iSVMGTokens, mbox, <||>], "AccessToken", $Failed]];

(* ---- registration ---- *)
SourceVaultRegisterGraphMailAccount[assoc_Association] :=
  Module[{mbox, clientId},
    mbox = ToString@Lookup[assoc, "MBox", Lookup[assoc, "mbox", ""]];
    If[mbox === "", Return[<|"Status" -> "Error", "Reason" -> "MissingMBox"|>]];
    clientId = ToString@Lookup[assoc, "ClientId", Lookup[assoc, "clientId", ""]];
    If[StringTrim[clientId] === "",
      Return[<|"Status" -> "Error", "Reason" -> "MissingClientId",
        "Hint" -> "Entra ID application (client) ID is required."|>]];
    SourceVault`SourceVaultRegisterMailAccount[<|
      "MBox" -> mbox,
      "User" -> ToString@Lookup[assoc, "User", Lookup[assoc, "Email", ""]],
      "Email" -> ToString@Lookup[assoc, "Email", Lookup[assoc, "User", ""]],
      "CredKey" -> With[{ck = ToString@Lookup[assoc, "CredKey", ""]},
        If[StringTrim[ck] === "", "SV_GRAPH_REFRESH_" <> mbox, ck]],
      "Server" -> "graph.microsoft.com", "Port" -> 443,
      "AuthMethod" -> "Graph",
      "TenantId" -> With[{t = ToString@Lookup[assoc, "TenantId", ""]},
        If[StringTrim[t] === "", "organizations", t]],
      "ClientId" -> clientId|>]];
SourceVaultRegisterGraphMailAccount[___] :=
  <|"Status" -> "Error", "Reason" -> "InvalidArguments"|>;

(* ---- device-code sign-in ---- *)
Options[SourceVaultMailGraphAuthorize] = {"MaxWait" -> 900, "OpenBrowser" -> True};
SourceVaultMailGraphAuthorize[mbox_String, OptionsPattern[]] :=
  Module[{acct, clientId, resp, dc, interval, deadline, tok, err},
    acct = iSVMGAccount[mbox];
    If[! AssociationQ[acct],
      Return[<|"Status" -> "Error", "Reason" -> "UnregisteredMailbox", "MBox" -> mbox|>]];
    If[ToString@Lookup[acct, "AuthMethod", ""] =!= "Graph",
      Return[<|"Status" -> "Error", "Reason" -> "NotGraphAccount", "MBox" -> mbox|>]];
    clientId = ToString@Lookup[acct, "ClientId", ""];
    If[StringTrim[clientId] === "",
      Return[<|"Status" -> "Error", "Reason" -> "MissingClientId", "MBox" -> mbox|>]];
    resp = iSVMGFormPost[iSVMGAuthority[acct] <> "/devicecode", {
      "client_id" -> clientId, "scope" -> $SourceVaultGraphScope}];
    dc = iSVMGJSON[resp];
    If[! AssociationQ[dc] || ! KeyExistsQ[dc, "device_code"],
      Return[<|"Status" -> "Error", "Reason" -> "DeviceCodeRequestFailed",
        "Detail" -> iSVMGErrorDetail[resp, dc]|>]];
    Print[Style["Microsoft sign-in for mailbox \"" <> mbox <> "\"", Bold]];
    Print[ToString@Lookup[dc, "message",
      "Open " <> ToString@Lookup[dc, "verification_uri", ""] <>
        " and enter code " <> ToString@Lookup[dc, "user_code", ""]]];
    If[TrueQ[OptionValue["OpenBrowser"]] &&
       StringQ[Lookup[dc, "verification_uri", Missing[]]],
      Quiet@Check[SystemOpen[dc["verification_uri"]], Null]];
    interval = With[{i = Lookup[dc, "interval", 5]},
      Max[0, If[NumericQ[i], Round[i], 5]]];
    deadline = AbsoluteTime[] + Min[
      With[{e = Lookup[dc, "expires_in", 900]}, If[NumericQ[e], Round[e], 900]],
      OptionValue["MaxWait"]];
    While[AbsoluteTime[] < deadline,
      Pause[interval];
      tok = iSVMGJSON[iSVMGFormPost[iSVMGAuthority[acct] <> "/token", {
        "client_id" -> clientId,
        "grant_type" -> "urn:ietf:params:oauth:grant-type:device_code",
        "device_code" -> ToString@dc["device_code"]}]];
      If[! AssociationQ[tok], Continue[]];
      If[KeyExistsQ[tok, "access_token"],
        Return[iSVMGStoreTokens[mbox, acct, tok, "Authorize"]]];
      err = ToString@Lookup[tok, "error", ""];
      Which[
        err === "authorization_pending", Null,
        err === "slow_down", interval += 5,
        True,
          Return[<|"Status" -> "Error", "Reason" -> "AuthorizationFailed",
            "Detail" -> err <> ": " <>
              ToString@Lookup[tok, "error_description", ""]|>]]];
    <|"Status" -> "Error", "Reason" -> "AuthorizationTimeout", "MBox" -> mbox|>];

(* ---- status probe (no mail bodies) ---- *)
SourceVaultMailGraphStatus[mbox_String] :=
  Module[{acct, key, rt, token, resp, json},
    acct = iSVMGAccount[mbox];
    If[! AssociationQ[acct],
      Return[<|"Status" -> "Error", "Reason" -> "UnregisteredMailbox", "MBox" -> mbox|>]];
    If[ToString@Lookup[acct, "AuthMethod", ""] =!= "Graph",
      Return[<|"Status" -> "Error", "Reason" -> "NotGraphAccount", "MBox" -> mbox|>]];
    key = iSVMGCredKeyOf[mbox, acct];
    rt = iSVMGCredRead[key];
    If[! StringQ[rt],
      Return[<|"Status" -> "NotAuthorized", "MBox" -> mbox,
        "HasRefreshToken" -> False, "CredKey" -> key,
        "Hint" -> "run SourceVaultMailGraphAuthorize[\"" <> mbox <> "\"]"|>]];
    token = iSVMGAccessToken[mbox, acct];
    If[! StringQ[token],
      Return[<|"Status" -> "Error", "Reason" -> "TokenRefreshFailed",
        "Detail" -> ToString@Lookup[token, "_error", ""],
        "HasRefreshToken" -> True|>]];
    resp = iSVMGGraphGET[$iSVMGGraphBase <> "/me/messages?" <>
      iSVMGQuery[{"$select" -> "id", "$top" -> "1"}], token];
    json = iSVMGJSON[resp];
    If[Lookup[resp, "StatusCode", 0] === 200 && AssociationQ[json],
      <|"Status" -> "Ok", "MBox" -> mbox, "HasRefreshToken" -> True,
        "ProbeMessages" -> Length[Lookup[json, "value", {}]],
        "CredentialWriteError" -> Lookup[$iSVMGLastCredError, mbox, Missing["None"]]|>,
      <|"Status" -> "Error", "Reason" -> "GraphProbeFailed",
        "Detail" -> iSVMGErrorDetail[resp, json]|>]];

(* ---- date range: reuse the imap Period grammar, convert local day
        boundaries to UTC instants for the Graph $filter ---- *)
iSVMGUTC[dateStr_String] :=
  Module[{dl},
    dl = Quiet@Check[DateList[dateStr], $Failed];
    If[! MatchQ[dl, {__?NumericQ}], Return[$Failed]];
    Quiet@Check[
      DateString[TimeZoneConvert[DateObject[dl, TimeZone -> $TimeZone], 0],
        "ISODateTime"] <> "Z", $Failed]];

iSVMGDateRange[period_] :=
  Module[{r},
    If[Length[DownValues[SourceVault`Private`iSVIMAPDateRange]] === 0,
      Return[$Failed]];
    r = Quiet@Check[SourceVault`Private`iSVIMAPDateRange[period], $Failed];
    If[! MatchQ[r, {_String, _String}], Return[$Failed]];
    With[{a = iSVMGUTC[r[[1]]], b = iSVMGUTC[r[[2]]]},
      If[StringQ[a] && StringQ[b], {a, b}, $Failed]]];

(* ---- attachment root: same layout as the imap source,
        <legacyRoot>/<mbox>/<yyyymm>_attachment/<name> ---- *)
iSVMGLegacyRoot[] :=
  If[StringQ[SourceVault`$SourceVaultLegacyMailRoot],
    SourceVault`$SourceVaultLegacyMailRoot,
    FileNameJoin[{DirectoryName[
      Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $TemporaryDirectory]],
      "mails"}]];

(* ---- Graph value mapping ---- *)
iSVMGAddr[a_Association] :=
  Module[{em, name, addr},
    em = Lookup[a, "emailAddress", a];
    If[! AssociationQ[em], Return[""]];
    name = ToString@Lookup[em, "name", ""];
    addr = ToString@Lookup[em, "address", ""];
    Which[
      name =!= "" && addr =!= "" && name =!= addr, name <> " <" <> addr <> ">",
      addr =!= "", addr,
      True, name]];
iSVMGAddr[_] := "";
iSVMGAddrList[l_List] := StringRiffle[DeleteCases[iSVMGAddr /@ l, ""], ", "];
iSVMGAddrList[_] := "";

(* receivedDateTime is UTC ("...Z"); convert to the local zone so the ISO
   date and the yyyymm attachment bucket match what the imap source produced
   from the sender's Date header. *)
iSVMGLocalDate[recvIso_String] :=
  Module[{s, dl, d},
    s = StringReplace[recvIso, "Z" ~~ EndOfString -> ""];
    dl = Quiet@Check[DateList[s], $Failed];
    If[! MatchQ[dl, {__?NumericQ}], Return[$Failed]];
    d = Quiet@Check[DateObject[dl, TimeZone -> 0], $Failed];
    If[Head[d] =!= DateObject, Return[$Failed]];
    Quiet@Check[TimeZoneConvert[d, $TimeZone], $Failed]];

iSVMGLocalISO[recvIso_String] :=
  With[{d = iSVMGLocalDate[recvIso]},
    If[Head[d] === DateObject,
      Quiet@Check[DateString[d, {"ISODateTime", "ISOTimeZone"}], ""], ""]];

iSVMGYM[d_] :=
  If[Head[d] === DateObject,
    Quiet@Check[DateString[d, {"Year", "Month"}], "000000"], "000000"];

iSVMGHeadersFor[gid_String, token_String] :=
  Module[{resp, json},
    resp = iSVMGGraphGET[$iSVMGGraphBase <> "/me/messages/" <> URLEncode[gid] <>
      "?$select=internetMessageHeaders", token];
    json = iSVMGJSON[resp];
    If[Lookup[resp, "StatusCode", 0] === 200 && AssociationQ[json],
      Lookup[json, "internetMessageHeaders", Missing["NoHeaders"]],
      Missing["HeaderFetchFailed"]]];

iSVMGSaveAttachments[gid_String, token_String, attdir_String] :=
  Module[{resp, json, vals, names = {}},
    resp = iSVMGGraphGET[$iSVMGGraphBase <> "/me/messages/" <> URLEncode[gid] <>
      "/attachments", token];
    json = iSVMGJSON[resp];
    If[Lookup[resp, "StatusCode", 0] =!= 200 || ! AssociationQ[json], Return[{}]];
    vals = Select[Lookup[json, "value", {}], AssociationQ];
    Scan[Function[a,
        Module[{name, cb, bytes, st},
          name = FileNameTake[ToString@Lookup[a, "name", ""]];
          cb = Lookup[a, "contentBytes", Missing[]];
          (* itemAttachment / referenceAttachment have no contentBytes: skip *)
          If[name =!= "" && StringQ[cb],
            bytes = Quiet@Check[BaseDecode[cb], $Failed];
            If[ByteArrayQ[bytes],
              Quiet@Check[
                (If[! DirectoryQ[attdir],
                   CreateDirectory[attdir, CreateIntermediateDirectories -> True]];
                 st = OpenWrite[FileNameJoin[{attdir, name}], BinaryFormat -> True];
                 If[Head[st] === OutputStream,
                   WithCleanup[BinaryWrite[st, bytes], Close[st]];
                   AppendTo[names, name]]),
                Null]]]]],
      vals];
    names];

iSVMGRecordOf[m_Association, token_String, attBase_String, perMsgHeaders_] :=
  Module[{gid, imid, subj, recv, ld, dateIso, ym, hdrs, rawheader, ar, body,
      names, rec},
    gid = ToString@Lookup[m, "id", ""];
    imid = ToString@Lookup[m, "internetMessageId", ""];
    subj = ToString@Lookup[m, "subject", ""];
    recv = ToString@Lookup[m, "receivedDateTime", ""];
    ld = iSVMGLocalDate[recv];
    dateIso = If[Head[ld] === DateObject,
      Quiet@Check[DateString[ld, {"ISODateTime", "ISOTimeZone"}], ""], ""];
    ym = iSVMGYM[ld];
    hdrs = Lookup[m, "internetMessageHeaders", Missing[]];
    If[! ListQ[hdrs] && TrueQ[perMsgHeaders] && gid =!= "",
      hdrs = iSVMGHeadersFor[gid, token]];
    rawheader = If[ListQ[hdrs],
      StringRiffle[
        (ToString@Lookup[#, "name", ""] <> ": " <> ToString@Lookup[#, "value", ""]) & /@
          Select[hdrs, AssociationQ], "\n"], ""];
    ar = If[ListQ[hdrs],
      FirstCase[hdrs,
        h_Association /;
            ToLowerCase[ToString@Lookup[h, "name", ""]] === "authentication-results" :>
          ToString@Lookup[h, "value", ""],
        Missing[]],
      Missing[]];
    body = ToString@Lookup[Lookup[m, "body", <||>], "content", ""];
    names = If[TrueQ[Lookup[m, "hasAttachments", False]] && gid =!= "",
      iSVMGSaveAttachments[gid, token,
        FileNameJoin[{attBase, ym <> "_attachment"}]], {}];
    rec = <|
      "id" -> Which[imid =!= "", imid, subj =!= "", subj, True, gid],
      "date" -> dateIso, "subject" -> subj,
      "from" -> iSVMGAddr[Lookup[m, "from", <||>]],
      "to" -> iSVMGAddrList[Lookup[m, "toRecipients", {}]],
      "cc" -> iSVMGAddrList[Lookup[m, "ccRecipients", {}]],
      "body" -> body,
      "attachment" -> StringRiffle[names, ","],
      "rawheader" -> rawheader|>;
    If[StringQ[ar] && ar =!= "", rec["Authentication-Results"] = ar];
    rec];

(* ---- message list / provider entry ---- *)
$iSVMGSelectBase =
  "id,internetMessageId,receivedDateTime,subject,from,toRecipients,ccRecipients,body,hasAttachments";

iSVMGListURL[{since_String, before_String}, withHeaders_, maxN_] :=
  $iSVMGGraphBase <> "/me/messages?" <> iSVMGQuery[{
    "$filter" -> "receivedDateTime ge " <> since <>
      " and receivedDateTime lt " <> before,
    "$orderby" -> "receivedDateTime desc",
    "$top" -> ToString[If[IntegerQ[maxN], Min[50, Max[1, maxN]], 50]],
    "$select" -> $iSVMGSelectBase <>
      If[TrueQ[withHeaders], ",internetMessageHeaders", ""]}];

SourceVaultMailGraphSource[mbox_String, srcOpts_Association] :=
  Module[{acct, token, range, maxN, url, collected = {}, resp, json, guard = 0,
      withHeaders = True, attBase, recs},
    acct = iSVMGAccount[mbox];
    If[! AssociationQ[acct],
      Return[{<|"_error" -> "UnregisteredMailbox: " <> mbox <>
        " -- SourceVaultRegisterGraphMailAccount required"|>}]];
    token = iSVMGAccessToken[mbox, acct];
    If[! StringQ[token], Return[{token}]];
    range = iSVMGDateRange[Lookup[srcOpts, "Period", "Latest"]];
    If[! MatchQ[range, {_String, _String}],
      Return[{<|"_error" -> "BadPeriod: " <>
        ToString[Lookup[srcOpts, "Period", "Latest"]]|>}]];
    maxN = Lookup[srcOpts, "MaxEmails", Automatic];
    attBase = FileNameJoin[{iSVMGLegacyRoot[], mbox}];
    url = iSVMGListURL[range, True, maxN];
    While[StringQ[url] && guard++ < 500,
      resp = iSVMGGraphGET[url, token];
      json = iSVMGJSON[resp];
      If[Lookup[resp, "StatusCode", 0] === 400 && withHeaders && collected === {},
        (* some tenants reject internetMessageHeaders inside a list $select:
           retry the list without it and fetch headers per message instead *)
        withHeaders = False;
        url = iSVMGListURL[range, False, maxN];
        Continue[]];
      If[Lookup[resp, "StatusCode", 0] =!= 200 || ! AssociationQ[json],
        Return[{<|"_error" -> "GraphListFailed: " <>
          iSVMGErrorDetail[resp, json]|>}]];
      collected = Join[collected, Select[Lookup[json, "value", {}], AssociationQ]];
      If[IntegerQ[maxN] && Length[collected] >= maxN, Break[]];
      url = With[{nl = Lookup[json, "@odata.nextLink", None]},
        If[StringQ[nl], nl, None]]];
    If[IntegerQ[maxN], collected = Take[collected, UpTo[maxN]]];
    (* newest-first from $orderby desc -> oldest-first like the imap source *)
    recs = iSVMGRecordOf[#, token, attBase, ! withHeaders] & /@ Reverse[collected];
    Select[recs, AssociationQ]];

(* ---- register into the maildb provider registry ---- *)
If[! AssociationQ[SourceVault`$SourceVaultMailSourceProviders],
  SourceVault`$SourceVaultMailSourceProviders = <||>];
SourceVault`$SourceVaultMailSourceProviders["Graph"] = SourceVaultMailGraphSource;

End[];
EndPackage[];
