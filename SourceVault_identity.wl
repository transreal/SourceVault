(* ::Package:: *)

(* ============================================================
   SourceVault_addressbook.wl -- SourceVault AddressBook (Phase SV-E5 / spec v16-v18 §10.9.7)

   This file is encoded in UTF-8.
   Load order: ... -> NBAccess_crypto.wl -> SourceVault_keys.wl -> SourceVault_addressbook.wl

   連絡先 (ContactRecord) を保持し、メール取り込み・PL 推定・release planning の
   identity source とする。最初の実装スライス:
     - 自分 (Self) を最初の連絡先として登録 (uid=1)
     - email equality は raw 正規化照合 + keyed HMAC token (SourceVault:addressbook:mac:v1)
     - put / get / find-by-email / list / JSONL 永続化
   設計原則 (review v16-v17):
     - identity resolution は security boundary ではない。
     - 自動作成 contact は fail-closed (MaxPlaintextPL 0.0, TrustStatus Observed)。
     - access を緩める変更は本来 agent 外承認 (本スライスは手動 put のみ)。
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultAddressBookPutContact::usage = "SourceVaultAddressBookPutContact[contact_Association, opts] は連絡先を登録/更新し、Uid/ContactId/EmailTokens を補完して保存する。";
SourceVaultAddressBookRegisterSelf::usage = "SourceVaultAddressBookRegisterSelf[email_String, opts] は自分 (OwnerKind->Self, TrustStatus->Verified) を連絡先として登録する。最初なら Uid=1。";
SourceVaultAddressBookGetContact::usage = "SourceVaultAddressBookGetContact[contactIdOrUid] は連絡先を返す。";
SourceVaultAddressBookFindByEmail::usage = "SourceVaultAddressBookFindByEmail[email_String] は email (正規化/トークン照合) で連絡先を返す。無ければ Missing。";
SourceVaultAddressBookFindByName::usage = "SourceVaultAddressBookFindByName[query_String] は氏名 (漢字/ローマ字/かな の3表記横断、部分一致) で連絡先のリストを返す。日本人名はかな表記が検索キー。";
SourceVaultAddressBookListContacts::usage = "SourceVaultAddressBookListContacts[] は全連絡先を Uid 昇順で返す。";
SourceVaultAddressBookSave::usage = "SourceVaultAddressBookSave[] は連絡先を JSONL に永続化する。";
SourceVaultAddressBookLoad::usage = "SourceVaultAddressBookLoad[] は JSONL から連絡先を読み込む。";
SourceVaultAddressBookStorePath::usage = "SourceVaultAddressBookStorePath[] は contacts.jsonl のパスを返す。$SourceVaultAddressBookRoot で上書き可。";
$SourceVaultAddressBookRoot::usage = "AddressBook の保存ルート (既定は PrivateVault/addressbook)。テスト時に一時ディレクトリへ上書きできる。";

Begin["`Private`"];

If[! AssociationQ[$iSVABContacts], $iSVABContacts = <||>];   (* uid -> contact *)
If[! AssociationQ[$iSVABEmailIndex], $iSVABEmailIndex = <||>]; (* token -> uid *)
If[! AssociationQ[$iSVABRawIndex], $iSVABRawIndex = <||>];     (* normEmail -> uid *)

iSVABNormEmail[e_String] := ToLowerCase[StringTrim[e]];
iSVABNormEmail[_] := Missing["NoEmail"];

iSVABEmailToken[e_String] :=
  Module[{k, norm},
    norm = iSVABNormEmail[e];
    If[! StringQ[norm] || norm === "", Return[Missing["NoEmail"]]];
    k = Quiet@Check[NBAccess`NBKeyStatus[SourceVault`$SourceVaultDefaultAddressBookMACKeyRef], Missing[]];
    If[! AssociationQ[k], Return[Missing["NoKey"]]];
    Quiet@Check[
      NBAccess`NBMacWithKeyRef[SourceVault`$SourceVaultDefaultAddressBookMACKeyRef,
        StringToByteArray[norm, "UTF-8"], "AddressBookEmailToken"],
      Missing["TokenFailed"]]];

(* 除去対象の空白: ASCII space(32) / tab(9) / LF(10) / CR(13) / 全角スペース U+3000(12288)。
   日本人名は姓名間に全角スペースを使うことが多いので SortKey ではこれらを除去する。 *)
$iSVABSpacePattern = Alternatives @@ (FromCharacterCode /@ {32, 9, 10, 13, 12288});
iSVABStripSpaces[s_String] := StringDelete[s, $iSVABSpacePattern];

(* 氏名: 漢字 (正式 canonical) / ローマ字 / かな (検索用)。SortKey は読み (かな) から空白除去。 *)
iSVABNormalizeNames[n_Association] :=
  Module[{kanji, romaji, kana, sort},
    kanji  = Lookup[n, "Kanji", Missing["NotSet"]];
    (* 旧スキーマ "Full" はローマ字として移行 *)
    romaji = Lookup[n, "Romaji", Lookup[n, "Full", Missing["NotSet"]]];
    kana   = Lookup[n, "Kana", Missing["NotSet"]];
    sort   = Which[
       StringQ[kana], iSVABStripSpaces[kana],
       StringQ[Lookup[n, "SortKey", Null]], n["SortKey"],
       True, Missing["NotSet"]];
    <|"Kanji" -> kanji, "Romaji" -> romaji, "Kana" -> kana, "SortKey" -> sort|>];
iSVABNormalizeNames[_] := <|"Kanji" -> Missing["NotSet"], "Romaji" -> Missing["NotSet"],
   "Kana" -> Missing["NotSet"], "SortKey" -> Missing["NotSet"]|>;

(* 表示名: 明示が無ければ 漢字 > ローマ字 > email の優先 *)
iSVABDefaultDisplay[names_Association, fallback_] :=
  Which[
    StringQ[names["Kanji"]], names["Kanji"],
    StringQ[names["Romaji"]], names["Romaji"],
    StringQ[fallback], fallback,
    True, Missing["NotSet"]];

(* 検索対象の氏名表記 (3表記 + 表示名 + SortKey) *)
iSVABNameForms[c_Association] :=
  Module[{n = Lookup[c, "Names", <||>]},
    Select[{Lookup[c, "DisplayName", Missing[]], Lookup[n, "Kanji", Missing[]],
       Lookup[n, "Romaji", Missing[]], Lookup[n, "Kana", Missing[]],
       Lookup[n, "SortKey", Missing[]]}, StringQ]];

iSVABNameMatchQ[c_, q_String] :=
  AnyTrue[iSVABNameForms[c], StringContainsQ[#, q, IgnoreCase -> True] &];

iSVABNextUid[] := If[$iSVABContacts === <||>, 1, Max[Keys[$iSVABContacts]] + 1];
iSVABNewContactId[] := "contact-" <> StringTake[StringDelete[CreateUUID[], "-"], 16];

iSVABEmailAddresses[contact_] :=
  Module[{ems = Lookup[contact, "Emails", {}]},
    Select[
      DeleteMissing[Flatten[{
         Lookup[contact, "BusinessEmail", Nothing],
         Lookup[contact, "PrivateEmail", Nothing],
         If[ListQ[ems], Lookup[#, "Address", Nothing] & /@ ems, Nothing]}]],
      StringQ]];

iSVABReindex[] :=
  Module[{},
    $iSVABEmailIndex = <||>; $iSVABRawIndex = <||>;
    KeyValueMap[Function[{uid, c},
       Scan[Function[addr,
          With[{norm = iSVABNormEmail[addr], tok = iSVABEmailToken[addr]},
            If[StringQ[norm], AssociateTo[$iSVABRawIndex, norm -> uid]];
            If[StringQ[tok], AssociateTo[$iSVABEmailIndex, tok -> uid]]]],
         iSVABEmailAddresses[c]]],
      $iSVABContacts];];

$iSVABFailClosedProfile := <|
  "EstimatedAccessPL" -> 0.0, "MaxPlaintextPL" -> 0.0, "MaxEncryptedReadablePL" -> 0.0,
  "AccessTags" -> {}, "DenyTags" -> {"NoEmailUnlessDeclassified"},
  "PurposeAllowed" -> {}, "TrustStatus" -> "Observed", "Confidence" -> 0.0|>;

Options[SourceVaultAddressBookPutContact] = {"Persist" -> True};

SourceVaultAddressBookPutContact[contact_Association, OptionsPattern[]] :=
  Module[{c, uid, addrs, tokens},
    c = contact;
    uid = Lookup[c, "Uid", Automatic];
    If[! IntegerQ[uid], uid = iSVABNextUid[]];
    c["Type"] = "SourceVaultContactRecord";
    c["SchemaVersion"] = 1;
    c["Uid"] = uid;
    If[! StringQ[Lookup[c, "ContactId", Null]], c["ContactId"] = iSVABNewContactId[]];
    If[! KeyExistsQ[c, "OwnerKind"], c["OwnerKind"] = "VaultUser"];
    If[! AssociationQ[Lookup[c, "ContactAccessProfile", Null]],
      c["ContactAccessProfile"] = $iSVABFailClosedProfile];
    If[! KeyExistsQ[c, "PolicySource"], c["PolicySource"] = "Manual"];
    (* 氏名 3表記の正規化 (漢字=正式, かな=検索キー) と表示名・正式表記の確定 *)
    c["Names"] = iSVABNormalizeNames[Lookup[c, "Names", <||>]];
    If[! StringQ[Lookup[c, "DisplayName", Null]],
      c["DisplayName"] = iSVABDefaultDisplay[c["Names"],
         FirstCase[iSVABEmailAddresses[c], _String, Missing["NotSet"]]]];
    c["CanonicalNameForm"] = If[StringQ[c["Names"]["Kanji"]], "Kanji",
       If[StringQ[c["Names"]["Romaji"]], "Romaji", Missing["NotSet"]]];
    c["UpdatedAt"] = DateString["ISODateTime"];
    If[! KeyExistsQ[c, "CreatedAt"], c["CreatedAt"] = c["UpdatedAt"]];
    addrs = iSVABEmailAddresses[c];
    tokens = DeleteMissing[iSVABEmailToken /@ addrs];
    c["EmailTokens"] = tokens;
    AssociateTo[$iSVABContacts, uid -> c];
    iSVABReindex[];
    If[TrueQ[OptionValue["Persist"]], SourceVaultAddressBookSave[]];
    <|"Status" -> "Stored", "Uid" -> uid, "ContactId" -> c["ContactId"],
      "EmailTokenCount" -> Length[tokens], "Contact" -> c|>];

Options[SourceVaultAddressBookRegisterSelf] = {
  "Persist" -> True, "DisplayName" -> Automatic, "AccessTags" -> {},
  "Kanji" -> Automatic, "Romaji" -> Automatic, "Kana" -> Automatic, "Names" -> Automatic};

SourceVaultAddressBookRegisterSelf[email_String, opts : OptionsPattern[]] :=
  Module[{existing, contact, dn, nm, prevNames},
    existing = SourceVaultAddressBookFindByEmail[email];
    contact = If[AssociationQ[existing], existing, <||>];
    prevNames = iSVABNormalizeNames[Lookup[contact, "Names", <||>]];
    (* Names は明示 option (Kanji/Romaji/Kana) で組み立てる。Automatic は既存値を保持 *)
    nm = OptionValue["Names"] /. Automatic -> <|
       "Kanji"  -> (OptionValue["Kanji"]  /. Automatic -> prevNames["Kanji"]),
       "Romaji" -> (OptionValue["Romaji"] /. Automatic -> prevNames["Romaji"]),
       "Kana"   -> (OptionValue["Kana"]   /. Automatic -> prevNames["Kana"])|>;
    nm = iSVABNormalizeNames[nm];
    dn = OptionValue["DisplayName"] /. Automatic -> iSVABDefaultDisplay[nm, email];
    (* 新しい値が既存値を上書きするよう、既存 contact を先に置く *)
    contact = Join[contact, <|
       "DisplayName" -> dn,
       "Names" -> nm,
       "Emails" -> {<|"Address" -> email, "Kind" -> "Business", "Primary" -> True, "Verified" -> True|>},
       "OwnerKind" -> "Self",
       "ContactAccessProfile" -> <|
          "EstimatedAccessPL" -> 1.0, "MaxPlaintextPL" -> 1.0, "MaxEncryptedReadablePL" -> 1.0,
          "AccessTags" -> OptionValue["AccessTags"], "DenyTags" -> {},
          "PurposeAllowed" -> {"Reply", "Collaboration", "Review"},
          "TrustStatus" -> "Verified", "Confidence" -> 1.0|>,
       "Categories" -> {"Person", "Self"},
       "PolicySource" -> "Manual"|>];
    SourceVaultAddressBookPutContact[contact, "Persist" -> TrueQ[OptionValue["Persist"]]]];

SourceVaultAddressBookGetContact[uid_Integer] := Lookup[$iSVABContacts, uid, Missing["NotFound"]];
SourceVaultAddressBookGetContact[contactId_String] :=
  Module[{hit}, hit = Select[Values[$iSVABContacts], #["ContactId"] === contactId &];
    If[hit === {}, Missing["NotFound"], First[hit]]];

SourceVaultAddressBookFindByEmail[email_String] :=
  Module[{norm, tok, uid},
    norm = iSVABNormEmail[email]; tok = iSVABEmailToken[email];
    uid = Which[
       StringQ[tok] && KeyExistsQ[$iSVABEmailIndex, tok], $iSVABEmailIndex[tok],
       StringQ[norm] && KeyExistsQ[$iSVABRawIndex, norm], $iSVABRawIndex[norm],
       True, Missing["NotFound"]];
    If[IntegerQ[uid], $iSVABContacts[uid], Missing["NotFound"]]];

SourceVaultAddressBookFindByName[query_String] :=
  Module[{q = StringTrim[query]},
    If[q === "", Return[{}]];
    Select[Values[KeySort[$iSVABContacts]], iSVABNameMatchQ[#, q] &]];

SourceVaultAddressBookListContacts[] := Values[KeySort[$iSVABContacts]];

(* ---- persistence (JSONL) ---- *)
SourceVaultAddressBookStorePath[] :=
  Module[{root},
    root = If[StringQ[$SourceVaultAddressBookRoot], $SourceVaultAddressBookRoot,
       FileNameJoin[{Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $TemporaryDirectory],
          "addressbook"}]];
    FileNameJoin[{root, "contacts.jsonl"}]];

iSVABForJSON[x_] := x /. {m_Missing :> Null};

SourceVaultAddressBookSave[] :=
  Module[{path, dir, lines},
    path = SourceVaultAddressBookStorePath[]; dir = DirectoryName[path];
    If[! DirectoryQ[dir], Quiet@CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    lines = (ExportString[iSVABForJSON[#], "RawJSON", "Compact" -> True] &) /@
       Values[KeySort[$iSVABContacts]];
    (* ExportString[..,"RawJSON"] の出力は各 codepoint が UTF-8 byte の Latin-1 表現
       (SourceVault.wl utf8fix v4 と同じ)。ISO8859-1 で書くと素の UTF-8 byte 列になる。 *)
    Quiet@Check[
      With[{strm = OpenWrite[path, BinaryFormat -> True]},
        Scan[BinaryWrite[strm, StringToByteArray[# <> "\n", "ISO8859-1"]] &, lines];
        Close[strm]; <|"Status" -> "Saved", "Path" -> path, "Count" -> Length[lines]|>],
      <|"Status" -> "Error", "Path" -> path|>]];

SourceVaultAddressBookLoad[] :=
  Module[{path, raw, lines, contacts},
    path = SourceVaultAddressBookStorePath[];
    If[! FileExistsQ[path], Return[<|"Status" -> "NoFile", "Path" -> path|>]];
    (* 書き出しと対: file は素の UTF-8 byte 列。ImportString[..,"RawJSON"] は
       ExportString と同じ Latin-1 表現を期待するため、ISO8859-1 で 1byte=1char に戻す。 *)
    raw = Quiet@Check[ByteArrayToString[ReadByteArray[path], "ISO8859-1"], ""];
    lines = Select[StringSplit[raw, "\n"], StringTrim[#] =!= "" &];
    contacts = Quiet@Check[ImportString[#, "RawJSON"], Nothing] & /@ lines;
    $iSVABContacts = Association[(#["Uid"] -> #) & /@ Select[contacts, AssociationQ[#] && IntegerQ[#["Uid"]] &]];
    iSVABReindex[];
    <|"Status" -> "Loaded", "Path" -> path, "Count" -> Length[$iSVABContacts]|>];

End[];
EndPackage[];


(* ::Package:: *)

(* ============================================================
   SourceVault_senderauth.wl -- 送信者認証 (Phase SV-E5 / spec v18 §24)

   This file is encoded in UTF-8.

   メールの From は認証なしには信用できない。Authentication-Results ヘッダは
   送信者が任意に挿入できるため、受信側が信頼する authserv-id が付けたものだけを
   採用する (authserv-id pinning)。

   非対称ルール:
     - 送信者 identity/category で PL を上げる / DenyTag を足す (tightening) は認証なしでも可。
     - PL を下げる / 平文ヘッダ化 / cloud summary / DenyTag を外す (loosening) は
       認証 (DMARC=Pass、または DKIM=Pass かつ From domain aligned) が pass の場合のみ。
   既存 maildb は Authentication-Results を保持しないため Source->"Missing" となり
   loosening 不可 (高 PL 維持) になる。
   ============================================================ *)

BeginPackage["SourceVault`"];

SourceVaultParseAuthenticationResults::usage = "SourceVaultParseAuthenticationResults[arHeader_String] は Authentication-Results 文字列を <|AuthservId, DKIM, SPF, DMARC, ARC, DKIMDomain, FromDomain|> のリストに解析する。";
SourceVaultSenderAuthentication::usage = "SourceVaultSenderAuthentication[record_Association, opts] はメール record から SenderAuthentication 判定 metadata を作る。信頼 authserv-id (TrustedAuthservIds) の A-R のみ採用。";
SourceVaultSenderAuthenticatedQ::usage = "SourceVaultSenderAuthenticatedQ[auth_Association] は loosening に使える送信者認証が成立しているか (既定: DMARC=Pass、または DKIM=Pass かつ aligned)。";
SourceVaultSenderFeatureUseQ::usage = "SourceVaultSenderFeatureUseQ[auth, \"Tightening\"|\"Loosening\"] は送信者由来 feature をその方向に使ってよいか。Tightening は常に True、Loosening は認証 pass 時のみ。";
$SourceVaultTrustedAuthservIds::usage = "受信側が信頼する authserv-id のリスト (自分の受信 MX / provider)。既定 {}。fail-closed: 未登録なら sender-based loosening 不可。";

Begin["`Private`"];

If[! ListQ[$SourceVaultTrustedAuthservIds], $SourceVaultTrustedAuthservIds = {}];

iSVSADomain[addr_] :=
  Module[{ats},
    If[! StringQ[addr], Return[Missing["NoDomain"]]];
    ats = StringCases[addr, RegularExpression["@([A-Za-z0-9.\\-]+)"] -> "$1"];
    If[ats === {}, Missing["NoDomain"], ToLowerCase[Last[ats]]]];

iSVSACapResult[s_String] :=
  Switch[ToLowerCase[StringTrim[s]],
    "pass", "Pass", "fail", "Fail", "none", "None", "neutral", "Neutral",
    "softfail", "Fail", "permerror" | "temperror", "Unknown", _, "Unknown"];

(* "dkim=pass header.d=example.org" -> {result, props-assoc} *)
iSVSAMethodEntry[entry_String] :=
  Module[{toks, kv, result, props},
    toks = Select[StringSplit[StringTrim[entry], Whitespace], # =!= "" &];
    If[toks === {}, Return[Missing[]]];
    kv = StringSplit[First[toks], "="];
    result = If[Length[kv] >= 2, iSVSACapResult[kv[[2]]], "Unknown"];
    props = Association[(With[{p = StringSplit[#, "=", 2]},
         If[Length[p] === 2, ToLowerCase[p[[1]]] -> p[[2]], Nothing]] &) /@ Rest[toks]];
    <|"Method" -> ToLowerCase[kv[[1]]], "Result" -> result, "Props" -> props|>];

iSVSAParseOne[arStr_String] :=
  Module[{parts, authserv, entries, byMethod, getR, getProp},
    parts = StringTrim /@ StringSplit[arStr, ";"];
    authserv = ToLowerCase@First[
       Select[StringSplit[First[parts, ""], Whitespace], # =!= "" &], ""];
    entries = DeleteMissing[iSVSAMethodEntry /@ Rest[parts]];
    byMethod = GroupBy[entries, #["Method"] &];
    getR[m_] := If[KeyExistsQ[byMethod, m], First[byMethod[m]]["Result"], "None"];
    getProp[m_, p_] := If[KeyExistsQ[byMethod, m], Lookup[First[byMethod[m]]["Props"], p, Missing[]], Missing[]];
    <|"AuthservId" -> authserv,
      "DKIM" -> getR["dkim"], "SPF" -> getR["spf"],
      "DMARC" -> getR["dmarc"], "ARC" -> getR["arc"],
      "DKIMDomain" -> (getProp["dkim", "header.d"] /. {d_String :> ToLowerCase[d], _ -> Missing[]}),
      "FromDomain" -> (getProp["dmarc", "header.from"] /. {d_String :> ToLowerCase[d], _ -> Missing[]})|>];

SourceVaultParseAuthenticationResults[arHeader_String] :=
  iSVSAParseOne /@ Select[StringSplit[arHeader, "\n"], StringTrim[#] =!= "" &];
SourceVaultParseAuthenticationResults[_] := {};

Options[SourceVaultSenderAuthentication] = {"TrustedAuthservIds" -> Automatic};

SourceVaultSenderAuthentication[record_Association, OptionsPattern[]] :=
  Module[{arRaw, trusted, parsed, trustedEntry, fromDomain},
    arRaw = FirstCase[
       {Lookup[record, "Authentication-Results", Missing[]],
        Lookup[record, "authentication-results", Missing[]],
        Lookup[record, "AuthenticationResults", Missing[]]}, _String, Missing["NoHeader"]];
    trusted = OptionValue["TrustedAuthservIds"] /. Automatic -> $SourceVaultTrustedAuthservIds;
    fromDomain = iSVSADomain[Lookup[record, "from", Missing[]]];
    If[! StringQ[arRaw],
      Return[<|"Source" -> "Missing", "DKIM" -> "None", "SPF" -> "None",
        "DMARC" -> "None", "ARC" -> "None", "Trusted" -> False,
        "AuthservId" -> Missing["NoHeader"], "AlignedFromDomain" -> Missing["NotVerified"],
        "AuthenticatedIdentity" -> Missing["Unverified"]|>]];
    parsed = SourceVaultParseAuthenticationResults[arRaw];
    (* 信頼 authserv-id が付けた A-R のみ採用。偽装 inline A-R は無視。 *)
    trustedEntry = SelectFirst[parsed, MemberQ[trusted, #["AuthservId"]] &, Missing[]];
    If[MissingQ[trustedEntry],
      Return[<|"Source" -> "UntrustedAuthservId", "DKIM" -> "None", "SPF" -> "None",
        "DMARC" -> "None", "ARC" -> "None", "Trusted" -> False,
        "AuthservId" -> (If[parsed === {}, Missing[], First[parsed]["AuthservId"]]),
        "AlignedFromDomain" -> Missing["NotVerified"],
        "AuthenticatedIdentity" -> Missing["Unverified"]|>]];
    (* Module で逐次評価 (With は束縛が相互参照できない) *)
    Module[{e = trustedEntry, aligned},
      aligned = Which[
         e["DMARC"] === "Pass" && StringQ[e["FromDomain"]], e["FromDomain"],
         e["DMARC"] === "Pass" && StringQ[fromDomain], fromDomain,
         e["DKIM"] === "Pass" && StringQ[e["DKIMDomain"]] && StringQ[fromDomain] &&
           e["DKIMDomain"] === fromDomain, fromDomain,
         True, Missing["NotAligned"]];
      <|"Source" -> "TrustedPinnedAuthservId", "DKIM" -> e["DKIM"], "SPF" -> e["SPF"],
        "DMARC" -> e["DMARC"], "ARC" -> e["ARC"], "Trusted" -> True,
        "AuthservId" -> e["AuthservId"], "AlignedFromDomain" -> aligned,
        "AuthenticatedIdentity" -> If[StringQ[aligned], aligned, fromDomain]|>]];

SourceVaultSenderAuthenticatedQ[auth_Association] :=
  TrueQ[auth["Trusted"]] &&
   (auth["DMARC"] === "Pass" ||
     (auth["DKIM"] === "Pass" && StringQ[auth["AlignedFromDomain"]]));
SourceVaultSenderAuthenticatedQ[_] := False;

SourceVaultSenderFeatureUseQ[auth_, "Tightening"] := True;
SourceVaultSenderFeatureUseQ[auth_Association, "Loosening"] := SourceVaultSenderAuthenticatedQ[auth];
SourceVaultSenderFeatureUseQ[_, _] := False;

End[];
EndPackage[];


(* ::Package:: *)

(* ============================================================
   SourceVault_identity.wl -- 2層アドレス帳 (識別子 / 実体)
   This file is encoded in UTF-8.

   設計 (ユーザー合意):
   - 第1層 Identifier (識別子): raw な email/SNS/URI を 1 レコード。メール取込で
     From/To/Cc を自動登録 (判断不要・冪等)。EntityRef で実体へリンク (任意)。
   - 第2層 Entity (実体): 人/組織/Bot/ML/サービス。識別子を束ねる。後からマージ。
   - self (Imai) は EntityUid=1 として最初に bootstrap (既存 self 連絡先を継承)。
   - キーは英語固定 (i18n)。表示は呼び出し側で localize。
   - 鍵は NBAccess 外に出さない。Token は AddressBook MAC 鍵の HMAC。
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultObserveIdentifier::usage = "SourceVaultObserveIdentifier[kind, value, opts] は識別子(Email/SNS/URI…)を登録/更新し IdentifierId を返す。opts: \"ObservedName\", \"MBox\", \"Persist\"。冪等。";
SourceVaultIngestAddressHeader::usage = "SourceVaultIngestAddressHeader[header, opts] はヘッダ文字列(\"Name <a@x>, …\")から全アドレスを識別子として登録し IdentifierId のリストを返す。";
SourceVaultGetIdentifier::usage = "SourceVaultGetIdentifier[identifierId] は識別子レコードを返す。";
SourceVaultListIdentifiers::usage = "SourceVaultListIdentifiers[] は全識別子を返す。";
SourceVaultFindIdentifier::usage = "SourceVaultFindIdentifier[kind, value] は正規化値で識別子を返す。無ければ Missing。";
SourceVaultPutEntity::usage = "SourceVaultPutEntity[entity, opts] は実体(人/組織等)を登録/更新し EntityId を返す。EntityUid 未指定なら採番。Identifiers の EntityRef を張る。";
SourceVaultGetEntity::usage = "SourceVaultGetEntity[entityIdOrUid] は実体レコードを返す。";
SourceVaultListEntities::usage = "SourceVaultListEntities[] は全実体を EntityUid 昇順で返す。";
SourceVaultLinkIdentifierToEntity::usage = "SourceVaultLinkIdentifierToEntity[identifierId, entityId] は識別子を実体に紐付ける(双方向)。既に別実体にリンク済みなら付け替え(既存実体にアドレス追加=マージ)。";
SourceVaultIdentifierCreateEntity::usage = "SourceVaultIdentifierCreateEntity[identifierId, opts] は識別子から新規実体を作成し継承(DisplayName=観測名)してリンクする。opts: \"Kind\"(既定Person), \"DisplayName\", \"Names\"。";
SourceVaultUnlinkIdentifier::usage = "SourceVaultUnlinkIdentifier[identifierId] は識別子を実体から外す(EntityRef を未リンクに戻す)。";
SourceVaultUpdateEntity::usage = "SourceVaultUpdateEntity[entityIdOrUid, updates_Association, opts] は実体のフィールドを更新する(updates が既存を上書き)。";
SourceVaultOwnerEntity::usage = "SourceVaultOwnerEntity[] は所有者(ユーザDB #1 / OwnerKind=Self)の実体を返す。無ければ Missing。";
SourceVaultOwnerEmails::usage = "SourceVaultOwnerEmails[] は所有者にリンクされた全メールアドレス(正規化)を返す。";
SourceVaultOwnerPrimaryEmail::usage = "SourceVaultOwnerPrimaryEmail[] は所有者のプライマリメール(PrimaryEmail フィールド優先、無ければ先頭)を返す。";
SourceVaultOwnerLLMProfile::usage = "SourceVaultOwnerLLMProfile[] は所有者実体の LLMProfile(LLM プロンプト用の受信者プロフィール文)を返す。未設定は \"\"。";
SourceVaultSetOwnerLLMProfile::usage = "SourceVaultSetOwnerLLMProfile[text] は所有者の LLMProfile を設定する。";
SourceVaultSetOwnerPrimaryEmail::usage = "SourceVaultSetOwnerPrimaryEmail[email] は所有者のプライマリメールを設定する。";
SourceVaultResolveIdentifierDisplay::usage = "SourceVaultResolveIdentifierDisplay[identifierId] は表示名を返す(実体DisplayName → 観測名 → raw値)。";
SourceVaultIdentitySave::usage = "SourceVaultIdentitySave[] は識別子/実体を JSONL に永続化する。";
SourceVaultIdentityLoad::usage = "SourceVaultIdentityLoad[] は JSONL から読み込む。";
SourceVaultIdentityInitialize::usage = "SourceVaultIdentityInitialize[] は load + self(Imai, EntityUid=1) bootstrap。冪等。";
SourceVaultIdentityEnsureLoaded::usage = "SourceVaultIdentityEnsureLoaded[] は未ロードなら Initialize する(import が既存を上書きしないため)。";
SourceVaultIdentityBootstrapSelf::usage = "SourceVaultIdentityBootstrapSelf[opts] は self を EntityUid=1 として登録(既存 self 連絡先を継承)。既にあれば何もしない。";
SourceVaultIdentityStorePaths::usage = "SourceVaultIdentityStorePaths[] は {identifiers.jsonl, entities.jsonl} のパスを返す。";
SourceVaultRecomputeOwnershipLinks::usage = "SourceVaultRecomputeOwnershipLinks[opts] はオブジェクト間所有関係の双方向リンク (Identifier.EntityRef ⇄ Entity.Identifiers) を全走査で整合再計算する (identity-tag spec §1.2)。dangling 参照は除去、欠落した逆/順リンクは補完、両側の食い違いは Identifier.EntityRef を正として解決する。\"UpdateEntitySummary\"->True (既定) なら event log の EntityLinkProposal から各 Entity の SuggestedIdentifierRefs / RejectedIdentifierRefs / EvidenceSummary (projection) も再生成する (mining/core 未ロード時は skip)。opts: \"Persist\"(False; True で修復があった場合のみ save), \"UpdateEntitySummary\"(True), \"EventLimit\"(5000)。戻り値は修復 report <|RepairCount, RepairKinds, Repairs, EntitySummaryUpdated, Persisted, ...|>。";
SourceVaultScheduleOwnershipRefresh::usage = "SourceVaultScheduleOwnershipRefresh[opts] は SourceVaultRecomputeOwnershipLinks[\"Persist\"->True] を ScheduledTask (SessionSubmit) でカーネル内定期実行する。冪等: 再呼出は既存タスクを差し替える。opts: \"IntervalSeconds\"(21600 = 6時間), \"Remove\"(True で解除のみ)。戻り値 <|Status, IntervalSeconds, Task|>。";
$SourceVaultIdentityRoot::usage = "identity の保存ルート(既定 PrivateVault/identity)。テストで上書き可。";

Begin["`Private`"];

If[! AssociationQ[$iSVIDIdentifiers], $iSVIDIdentifiers = <||>];   (* IdentifierId -> rec *)
If[! AssociationQ[$iSVIDEntities], $iSVIDEntities = <||>];         (* EntityId -> rec *)
If[! ValueQ[$iSVIDLoaded], $iSVIDLoaded = False];

$SourceVaultIdentityRoot::usage;
SourceVaultIdentityStoreRoot[] :=
  If[StringQ[$SourceVaultIdentityRoot], $SourceVaultIdentityRoot,
     FileNameJoin[{Quiet@Check[SourceVault`$SourceVaultRoots["PrivateVault"], $TemporaryDirectory],
        "identity"}]];
SourceVaultIdentityStorePaths[] :=
  {FileNameJoin[{SourceVaultIdentityStoreRoot[], "identifiers.jsonl"}],
   FileNameJoin[{SourceVaultIdentityStoreRoot[], "entities.jsonl"}]};

(* ---- 正規化 / ID / Token ---- *)
iSVIDNormalize[kind_String, v_String] :=
  Module[{s = StringTrim[v]},
    Switch[kind,
      "Email", ToLowerCase[s],
      "URI", s,
      _, ToLowerCase[s]]];

iSVIDHex[s_String] :=
  StringJoin[IntegerString[#, 16, 2] & /@
     Normal[Hash[StringToByteArray[s, "UTF-8"], "SHA256", "ByteArray"]]];

(* IdentifierId は (kind, 正規化値) から決定的。再取込で冪等、鍵非依存。 *)
iSVIDId[kind_String, normValue_String] :=
  "idf-" <> ToLowerCase[kind] <> "-" <> StringTake[iSVIDHex[kind <> ":" <> normValue], 16];

iSVIDToken[normValue_String] :=
  With[{t = Quiet@Check[
     NBAccess`NBMacWithKeyRef[SourceVault`$SourceVaultDefaultAddressBookMACKeyRef,
       StringToByteArray[normValue, "UTF-8"], "IdentifierToken"], $Failed]},
    If[StringQ[t], t, Missing["NoKey"]]];   (* $Failed を残さない *)

(* ---- 識別子 observe (upsert) ---- *)
Options[SourceVaultObserveIdentifier] = {
  "ObservedName" -> Missing[], "MBox" -> Missing[], "Persist" -> False};

SourceVaultObserveIdentifier[kind_String, rawValue_String, OptionsPattern[]] :=
  Module[{val, id, now, on, mbox, ex, names, prov},
    val = iSVIDNormalize[kind, rawValue];
    If[val === "", Return[Missing["EmptyValue"]]];
    id = iSVIDId[kind, val];
    now = DateString["ISODateTime"];
    on = OptionValue["ObservedName"];
    mbox = OptionValue["MBox"];
    ex = Lookup[$iSVIDIdentifiers, id, Missing[]];
    If[AssociationQ[ex],
      names = Lookup[ex, "ObservedNames", {}];
      If[StringQ[on] && StringTrim[on] =!= "" && ! MemberQ[names, StringTrim[on]],
        names = Append[names, StringTrim[on]]];
      prov = Lookup[ex, "Provenance", {}];
      If[StringQ[mbox] && ! MemberQ[prov, mbox], prov = Append[prov, mbox]];
      ex["ObservedNames"] = names; ex["Provenance"] = prov;
      ex["LastSeen"] = now; ex["Count"] = Lookup[ex, "Count", 0] + 1;
      AssociateTo[$iSVIDIdentifiers, id -> ex];
    ,
      AssociateTo[$iSVIDIdentifiers, id -> <|
        "Type" -> "SourceVaultIdentifier", "SchemaVersion" -> 1,
        "IdentifierId" -> id, "Kind" -> kind, "Value" -> val,
        "ObservedNames" -> If[StringQ[on] && StringTrim[on] =!= "", {StringTrim[on]}, {}],
        "Token" -> iSVIDToken[val],
        "FirstSeen" -> now, "LastSeen" -> now, "Count" -> 1,
        "Provenance" -> If[StringQ[mbox], {mbox}, {}],
        "EntityRef" -> Missing["Unlinked"]|>];
    ];
    If[TrueQ[OptionValue["Persist"]], SourceVaultIdentitySave[]];
    id];

SourceVaultGetIdentifier[id_String] := Lookup[$iSVIDIdentifiers, id, Missing["NotFound"]];
SourceVaultListIdentifiers[] := Values[$iSVIDIdentifiers];
SourceVaultFindIdentifier[kind_String, value_String] :=
  Lookup[$iSVIDIdentifiers, iSVIDId[kind, iSVIDNormalize[kind, value]], Missing["NotFound"]];

(* ---- ヘッダから識別子取込 ---- *)
iSVIDNameForAddr[header_String, addr_String] :=
  Module[{parts, part, nm},
    parts = StringSplit[header, ","];
    part = SelectFirst[parts, StringContainsQ[#, addr, IgnoreCase -> True] &, ""];
    If[! StringContainsQ[part, "<"], Return[""]];  (* bare addr: 名前なし *)
    nm = StringTrim[First[StringSplit[part, "<"]]];
    StringTrim[nm, ("\"" | "'" | WhitespaceCharacter)]];

Options[SourceVaultIngestAddressHeader] = {"MBox" -> Missing[], "Persist" -> False};
SourceVaultIngestAddressHeader[header_String, OptionsPattern[]] :=
  Module[{addrs, ids},
    addrs = Quiet@Check[SourceVault`SourceVaultMailParseEmails[header], {}];
    ids = Function[a,
       SourceVaultObserveIdentifier["Email", a,
         "ObservedName" -> iSVIDNameForAddr[header, a],
         "MBox" -> OptionValue["MBox"], "Persist" -> False]] /@ addrs;
    If[TrueQ[OptionValue["Persist"]], SourceVaultIdentitySave[]];
    DeleteCases[ids, _Missing]];
SourceVaultIngestAddressHeader[_, OptionsPattern[]] := {};

(* ---- 実体 ---- *)
iSVIDNextUid[] :=
  Module[{uids = Cases[Values[$iSVIDEntities], a_ /; IntegerQ[Lookup[a, "EntityUid", Null]] :>
       a["EntityUid"]]},
    If[uids === {}, 1, Max[uids] + 1]];

iSVIDFailClosedProfile := <|
  "EstimatedAccessPL" -> 0.0, "MaxPlaintextPL" -> 0.0,
  "AccessTags" -> {}, "DenyTags" -> {"NoEmailUnlessDeclassified"},
  "TrustStatus" -> "Observed", "Confidence" -> 0.0|>;

iSVIDSetIdentifierEntity[identifierId_String, entityId_] :=
  Module[{idf = Lookup[$iSVIDIdentifiers, identifierId, Missing[]]},
    If[AssociationQ[idf],
      idf["EntityRef"] = entityId;
      AssociateTo[$iSVIDIdentifiers, identifierId -> idf]]];

Options[SourceVaultPutEntity] = {"Persist" -> True};
SourceVaultPutEntity[entity_Association, OptionsPattern[]] :=
  Module[{e = entity, uid, id},
    uid = Lookup[e, "EntityUid", Automatic];
    If[! IntegerQ[uid], uid = iSVIDNextUid[]];
    e["EntityUid"] = uid;
    id = Lookup[e, "EntityId", Automatic];
    If[! StringQ[id], id = "ent-" <> IntegerString[uid]];
    e["EntityId"] = id;
    e["Type"] = "SourceVaultEntity"; e["SchemaVersion"] = 1;
    If[! StringQ[Lookup[e, "Kind", Null]], e["Kind"] = "Person"];
    If[! ListQ[Lookup[e, "Identifiers", Null]], e["Identifiers"] = {}];
    If[! KeyExistsQ[e, "MemberOf"], e["MemberOf"] = Missing["NotSet"]];
    If[! ListQ[Lookup[e, "Categories", Null]], e["Categories"] = {}];
    If[! KeyExistsQ[e, "Group"], e["Group"] = Missing["NotSet"]];
    If[! KeyExistsQ[e, "PriorityWeight"], e["PriorityWeight"] = Missing["NotSet"]];
    If[! AssociationQ[Lookup[e, "ContactAccessProfile", Null]],
      e["ContactAccessProfile"] = iSVIDFailClosedProfile];
    If[! StringQ[Lookup[e, "DisplayName", Null]],
      e["DisplayName"] = With[{nm = Lookup[e, "Names", <||>]},
        Which[
          AssociationQ[nm] && StringQ[Lookup[nm, "Kanji", Null]], nm["Kanji"],
          AssociationQ[nm] && StringQ[Lookup[nm, "Romaji", Null]], nm["Romaji"],
          True, id]]];
    AssociateTo[$iSVIDEntities, id -> e];
    Do[iSVIDSetIdentifierEntity[idf, id], {idf, e["Identifiers"]}];
    If[TrueQ[OptionValue["Persist"]], SourceVaultIdentitySave[]];
    id];

Options[SourceVaultUpdateEntity] = {"Persist" -> True};
SourceVaultUpdateEntity[idOrUid_, updates_Association, OptionsPattern[]] :=
  Module[{e = SourceVaultGetEntity[idOrUid]},
    If[! AssociationQ[e], Return[<|"Status" -> "Error", "Reason" -> "EntityNotFound"|>]];
    SourceVaultPutEntity[Join[e, updates], "Persist" -> OptionValue["Persist"]];
    <|"Status" -> "Updated", "EntityId" -> e["EntityId"],
      "EntityUid" -> e["EntityUid"]|>];

SourceVaultGetEntity[idOrUid_] :=
  Which[
    StringQ[idOrUid], Lookup[$iSVIDEntities, idOrUid, Missing["NotFound"]],
    IntegerQ[idOrUid],
      SelectFirst[Values[$iSVIDEntities], Lookup[#, "EntityUid", Null] === idOrUid &,
        Missing["NotFound"]],
    True, Missing["NotFound"]];

SourceVaultListEntities[] :=
  SortBy[Values[$iSVIDEntities], Lookup[#, "EntityUid", Infinity] &];

SourceVaultLinkIdentifierToEntity[identifierId_String, entityId_String] :=
  Module[{e = Lookup[$iSVIDEntities, entityId, Missing[]],
      idf = Lookup[$iSVIDIdentifiers, identifierId, Missing[]], prev},
    If[! AssociationQ[e], Return[<|"Status" -> "Error", "Reason" -> "EntityNotFound"|>]];
    If[! AssociationQ[idf], Return[<|"Status" -> "Error", "Reason" -> "IdentifierNotFound"|>]];
    (* 既に別実体にリンク済みなら、その実体の Identifiers から外す(付け替え) *)
    prev = Lookup[idf, "EntityRef", Missing[]];
    If[StringQ[prev] && prev =!= entityId,
      Module[{pe = Lookup[$iSVIDEntities, prev, Missing[]]},
        If[AssociationQ[pe],
          pe["Identifiers"] = DeleteCases[pe["Identifiers"], identifierId];
          AssociateTo[$iSVIDEntities, prev -> pe]]]];
    If[! MemberQ[e["Identifiers"], identifierId],
      e["Identifiers"] = Append[e["Identifiers"], identifierId];
      AssociateTo[$iSVIDEntities, entityId -> e]];
    iSVIDSetIdentifierEntity[identifierId, entityId];
    <|"Status" -> "Linked", "EntityId" -> entityId, "IdentifierId" -> identifierId|>];

Options[SourceVaultIdentifierCreateEntity] = {
  "Kind" -> "Person", "DisplayName" -> Automatic, "Names" -> Automatic, "Persist" -> True};
SourceVaultIdentifierCreateEntity[identifierId_String, OptionsPattern[]] :=
  Module[{idf = Lookup[$iSVIDIdentifiers, identifierId, Missing[]], dn, names, eid},
    If[! AssociationQ[idf],
      Return[<|"Status" -> "Error", "Reason" -> "IdentifierNotFound"|>]];
    dn = OptionValue["DisplayName"] /. Automatic ->
       With[{ons = Lookup[idf, "ObservedNames", {}]},
         If[ons =!= {} && StringQ[First[ons]] && First[ons] =!= "",
           First[ons], Lookup[idf, "Value", ""]]];
    names = OptionValue["Names"] /. Automatic -> <||>;
    eid = SourceVaultPutEntity[<|
       "Kind" -> OptionValue["Kind"], "DisplayName" -> dn, "Names" -> names,
       "Identifiers" -> {identifierId}|>, "Persist" -> OptionValue["Persist"]];
    <|"Status" -> "Created", "EntityId" -> eid,
      "EntityUid" -> Quiet@Check[SourceVaultGetEntity[eid]["EntityUid"], Missing[]],
      "DisplayName" -> dn|>];

Options[SourceVaultUnlinkIdentifier] = {"Persist" -> True};
SourceVaultUnlinkIdentifier[identifierId_String, OptionsPattern[]] :=
  Module[{idf = Lookup[$iSVIDIdentifiers, identifierId, Missing[]], ent},
    If[! AssociationQ[idf],
      Return[<|"Status" -> "Error", "Reason" -> "IdentifierNotFound"|>]];
    ent = Lookup[idf, "EntityRef", Missing[]];
    If[StringQ[ent],
      Module[{e = Lookup[$iSVIDEntities, ent, Missing[]]},
        If[AssociationQ[e],
          e["Identifiers"] = DeleteCases[e["Identifiers"], identifierId];
          AssociateTo[$iSVIDEntities, ent -> e]]]];
    idf["EntityRef"] = Missing["Unlinked"];
    AssociateTo[$iSVIDIdentifiers, identifierId -> idf];
    If[TrueQ[OptionValue["Persist"]], SourceVaultIdentitySave[]];
    <|"Status" -> "Unlinked", "IdentifierId" -> identifierId|>];

SourceVaultResolveIdentifierDisplay[identifierId_String] :=
  Module[{idf = Lookup[$iSVIDIdentifiers, identifierId, Missing[]], ent},
    If[! AssociationQ[idf], Return[Missing["NotFound"]]];
    ent = Lookup[idf, "EntityRef", Missing[]];
    If[StringQ[ent],
      With[{e = Lookup[$iSVIDEntities, ent, Missing[]]},
        If[AssociationQ[e] && StringQ[Lookup[e, "DisplayName", Null]],
          Return[e["DisplayName"]]]]];
    With[{ons = Lookup[idf, "ObservedNames", {}]},
      If[ons =!= {} && StringQ[First[ons]] && First[ons] =!= "", Return[First[ons]]]];
    Lookup[idf, "Value", Missing["NoValue"]]];

(* ---- 所有者(ユーザDB #1 / OwnerKind=Self)アクセサ ---- *)
SourceVaultOwnerEntity[] :=
  Module[{e},
    SourceVaultIdentityEnsureLoaded[];   (* 未ロードなら disk から load + self bootstrap *)
    e = SourceVaultGetEntity[1];
    If[AssociationQ[e] && Lookup[e, "OwnerKind", ""] === "Self", e,
      SelectFirst[Values[$iSVIDEntities], Lookup[#, "OwnerKind", ""] === "Self" &,
        Missing["NoOwner"]]]];

SourceVaultOwnerEmails[] :=
  Module[{e = SourceVaultOwnerEntity[]},
    If[! AssociationQ[e], Return[{}]];
    DeleteDuplicates@Select[
      Function[i, With[{idf = Lookup[$iSVIDIdentifiers, i, <||>]},
         If[Lookup[idf, "Kind", ""] === "Email" && StringQ[Lookup[idf, "Value", Null]],
           ToLowerCase[idf["Value"]], Nothing]]] /@ Lookup[e, "Identifiers", {}],
      StringQ[#] && # =!= "" &]];

SourceVaultOwnerPrimaryEmail[] :=
  Module[{e = SourceVaultOwnerEntity[], pe, ems},
    If[! AssociationQ[e], Return[Missing["NoOwner"]]];
    pe = Lookup[e, "PrimaryEmail", Missing[]];
    If[StringQ[pe] && StringTrim[pe] =!= "", Return[ToLowerCase[StringTrim[pe]]]];
    ems = SourceVaultOwnerEmails[];
    If[ems =!= {}, First[ems], Missing["NoEmail"]]];

SourceVaultOwnerLLMProfile[] :=
  Module[{e = SourceVaultOwnerEntity[]},
    If[AssociationQ[e] && StringQ[Lookup[e, "LLMProfile", Null]], e["LLMProfile"], ""]];

Options[SourceVaultSetOwnerLLMProfile] = {"Persist" -> True};
SourceVaultSetOwnerLLMProfile[text_String, OptionsPattern[]] :=
  Module[{e = SourceVaultOwnerEntity[]},
    If[! AssociationQ[e], Return[<|"Status" -> "Error", "Reason" -> "NoOwner"|>]];
    SourceVaultUpdateEntity[e["EntityId"], <|"LLMProfile" -> text|>,
      "Persist" -> OptionValue["Persist"]]];

Options[SourceVaultSetOwnerPrimaryEmail] = {"Persist" -> True};
SourceVaultSetOwnerPrimaryEmail[email_String, OptionsPattern[]] :=
  Module[{e = SourceVaultOwnerEntity[]},
    If[! AssociationQ[e], Return[<|"Status" -> "Error", "Reason" -> "NoOwner"|>]];
    SourceVaultUpdateEntity[e["EntityId"], <|"PrimaryEmail" -> ToLowerCase[StringTrim[email]]|>,
      "Persist" -> OptionValue["Persist"]]];

(* ---- 永続化 (ISO8859-1 JSONL: ExportString RawJSON のバイトをそのまま) ---- *)
iSVIDWriteJSONL[path_String, recs_List] :=
  Module[{dir = DirectoryName[path], lines},
    If[! DirectoryQ[dir], CreateDirectory[dir, CreateIntermediateDirectories -> True]];
    (* RawJSON は Missing/$Failed を出力できないので Null に置換 (load 時に復元) *)
    lines = (ExportString[# /. (_Missing | $Failed) -> Null, "RawJSON", "Compact" -> True] & /@ recs);
    Export[path, StringRiffle[lines, "\n"] <> If[lines === {}, "", "\n"], "Text",
      CharacterEncoding -> "ISO8859-1"]];

iSVIDReadJSONL[path_String] :=
  If[! FileExistsQ[path], {},
    Module[{txt = Quiet@Check[Import[path, "Text", CharacterEncoding -> "ISO8859-1"], ""]},
      If[! StringQ[txt] || StringTrim[txt] === "", {},
        DeleteCases[
          (Quiet@Check[ImportString[#, "RawJSON"], $Failed] & /@
             Select[StringSplit[txt, "\n"], StringTrim[#] =!= "" &]),
          $Failed]]]];

SourceVaultIdentitySave[] :=
  Module[{paths = SourceVaultIdentityStorePaths[]},
    iSVIDWriteJSONL[paths[[1]], Values[$iSVIDIdentifiers]];
    iSVIDWriteJSONL[paths[[2]], Values[$iSVIDEntities]];
    <|"Status" -> "Saved", "Identifiers" -> Length[$iSVIDIdentifiers],
      "Entities" -> Length[$iSVIDEntities]|>];

iSVIDToAssoc[r_] := If[AssociationQ[r], r, Quiet@Check[Association[r], $Failed]];
iSVIDFixMissing[r_Association] := Replace[r, Null -> Missing[], {1}];

SourceVaultIdentityLoad[] :=
  Module[{paths = SourceVaultIdentityStorePaths[], idfs, ents},
    idfs = Select[iSVIDToAssoc /@ iSVIDReadJSONL[paths[[1]]], AssociationQ];
    ents = Select[iSVIDToAssoc /@ iSVIDReadJSONL[paths[[2]]], AssociationQ];
    $iSVIDIdentifiers = Association[(Lookup[#, "IdentifierId", CreateUUID[]] -> iSVIDFixMissing[#]) & /@ idfs];
    $iSVIDEntities = Association[(Lookup[#, "EntityId", CreateUUID[]] -> iSVIDFixMissing[#]) & /@ ents];
    $iSVIDLoaded = True;
    <|"Status" -> "Loaded", "Identifiers" -> Length[$iSVIDIdentifiers],
      "Entities" -> Length[$iSVIDEntities]|>];

SourceVaultIdentityEnsureLoaded[] :=
  If[! TrueQ[$iSVIDLoaded], SourceVaultIdentityInitialize[], <|"Status" -> "AlreadyLoaded"|>];

(* ---- self (Imai) を EntityUid=1 で bootstrap ---- *)
iSVIDSelfExistsQ[] := AnyTrue[Values[$iSVIDEntities], Lookup[#, "OwnerKind", ""] === "Self" &];

iSVIDABSelf[] :=
  Quiet@Check[
    SelectFirst[SourceVault`SourceVaultAddressBookListContacts[],
      Lookup[#, "OwnerKind", ""] === "Self" &, Missing[]], Missing[]];

iSVIDABPrimaryEmail[c_] :=
  Module[{ems = Lookup[c, "Emails", {}], hit},
    If[! ListQ[ems] || ems === {}, Return[Missing[]]];
    hit = SelectFirst[ems, TrueQ[Lookup[#, "Primary", False]] &, First[ems]];
    Lookup[hit, "Address", Missing[]]];

Options[SourceVaultIdentityBootstrapSelf] = {"Email" -> Automatic, "Persist" -> True};
SourceVaultIdentityBootstrapSelf[OptionsPattern[]] :=
  Module[{ab, email, names, dn, idfid, eid},
    If[iSVIDSelfExistsQ[],
      Return[<|"Status" -> "AlreadyExists",
        "EntityId" -> SelectFirst[Keys[$iSVIDEntities],
           Lookup[$iSVIDEntities[#], "OwnerKind", ""] === "Self" &, Missing[]]|>]];
    ab = iSVIDABSelf[];
    (* 私的 email はハードコードしない。addressbook self → Email オプション → なし。 *)
    email = OptionValue["Email"] /. Automatic ->
       If[AssociationQ[ab], ToString@iSVIDABPrimaryEmail[ab], Missing["NoEmail"]];
    names = If[AssociationQ[ab] && AssociationQ[Lookup[ab, "Names", Null]],
       ab["Names"], <||>];
    dn = Which[
       AssociationQ[ab] && StringQ[Lookup[ab, "DisplayName", Null]], ab["DisplayName"],
       StringQ[email] && StringContainsQ[email, "@"], email,
       True, "Owner"];
    idfid = If[StringQ[email] && StringContainsQ[email, "@"],
       SourceVaultObserveIdentifier["Email", email, "ObservedName" -> dn, "Persist" -> False],
       Missing["NoEmail"]];
    eid = SourceVaultPutEntity[<|
       "EntityUid" -> 1, "EntityId" -> "ent-1", "Kind" -> "Person", "OwnerKind" -> "Self",
       "Names" -> names, "DisplayName" -> dn,
       "Identifiers" -> DeleteCases[{idfid}, _Missing],
       "Categories" -> {"Person", "Self"},
       "ContactAccessProfile" -> <|"EstimatedAccessPL" -> 1.0, "MaxPlaintextPL" -> 1.0,
          "AccessTags" -> {}, "DenyTags" -> {}, "TrustStatus" -> "Verified", "Confidence" -> 1.0|>,
       "TrustStatus" -> "Verified"|>, "Persist" -> False];
    If[TrueQ[OptionValue["Persist"]], SourceVaultIdentitySave[]];
    <|"Status" -> "Bootstrapped", "EntityId" -> eid, "EntityUid" -> 1,
      "IdentifierId" -> idfid|>];

SourceVaultIdentityInitialize[] :=
  (SourceVaultIdentityLoad[];
   If[! iSVIDSelfExistsQ[], SourceVaultIdentityBootstrapSelf["Persist" -> True]];
   <|"Status" -> "Initialized", "Identifiers" -> Length[$iSVIDIdentifiers],
     "Entities" -> Length[$iSVIDEntities],
     "SelfUid" -> Quiet@Check[SourceVaultGetEntity[1]["EntityUid"], Missing[]]|>);

(* ============================================================
   所有関係双方向リンクの定期再計算 (identity-tag spec §1.2 / §9.1)
   forward = Identifier.EntityRef、reverse = Entity.Identifiers。
   通常運用では SourceVaultLinkIdentifierToEntity / PutEntity が両側を同時更新するが、
   部分ロード・手動編集・migration・クラッシュで乖離しうる。ここは答え合わせ+修復。
   衝突時は Identifier.EntityRef を正とする (確定リンクの所在は Identifier 側、spec §1.2)。
   ============================================================ *)

Options[SourceVaultRecomputeOwnershipLinks] = {
  "Persist" -> False, "UpdateEntitySummary" -> True, "EventLimit" -> 5000};

SourceVaultRecomputeOwnershipLinks[OptionsPattern[]] := Module[
  {repairs = {}, summaryCount = 0, ev, props, byEnt, persisted = False},
  SourceVaultIdentityEnsureLoaded[];
  (* pass 1: forward (Identifier -> Entity) の答え合わせ。
     dangling EntityRef は未リンクへ、逆リンク欠落は Entity.Identifiers に補完 *)
  Do[Module[{idf = $iSVIDIdentifiers[iid], ent},
     ent = Lookup[idf, "EntityRef", Missing[]];
     If[StringQ[ent],
       Module[{e = Lookup[$iSVIDEntities, ent, Missing[]]},
         Which[
          ! AssociationQ[e],
            idf["EntityRef"] = Missing["Unlinked"];
            AssociateTo[$iSVIDIdentifiers, iid -> idf];
            AppendTo[repairs, <|"Kind" -> "DanglingEntityRef",
              "Identifier" -> iid, "Entity" -> ent|>],
          ! MemberQ[Lookup[e, "Identifiers", {}], iid],
            e["Identifiers"] = Append[Lookup[e, "Identifiers", {}], iid];
            AssociateTo[$iSVIDEntities, ent -> e];
            AppendTo[repairs, <|"Kind" -> "MissingReverseLink",
              "Identifier" -> iid, "Entity" -> ent|>]]]]],
    {iid, Keys[$iSVIDIdentifiers]}];
  (* pass 2: reverse (Entity -> Identifiers) の答え合わせ。
     dangling は除去、forward 未設定は補完、別 entity へ確定済みなら Identifier 側を正として除去 *)
  Do[Module[{e = $iSVIDEntities[eid], orig, keep = {}},
     orig = DeleteDuplicates@Lookup[e, "Identifiers", {}];
     Do[Module[{idf = Lookup[$iSVIDIdentifiers, iid2, Missing[]], fwd},
        If[! AssociationQ[idf],
          AppendTo[repairs, <|"Kind" -> "DanglingIdentifierRef",
            "Entity" -> eid, "Identifier" -> iid2|>],
          fwd = Lookup[idf, "EntityRef", Missing[]];
          Which[
           StringQ[fwd] && fwd === eid, AppendTo[keep, iid2],
           StringQ[fwd],
             AppendTo[repairs, <|"Kind" -> "ConflictResolvedByIdentifier",
               "Entity" -> eid, "Identifier" -> iid2, "LinkedTo" -> fwd|>],
           True,
             idf["EntityRef"] = eid;
             AssociateTo[$iSVIDIdentifiers, iid2 -> idf];
             AppendTo[keep, iid2];
             AppendTo[repairs, <|"Kind" -> "MissingForwardLink",
               "Entity" -> eid, "Identifier" -> iid2|>]]]],
       {iid2, orig}];
     If[keep =!= Lookup[e, "Identifiers", {}],
       e["Identifiers"] = keep;
       AssociateTo[$iSVIDEntities, eid -> e]]],
    {eid, Keys[$iSVIDEntities]}];
  (* pass 3: Entity summary projection (spec §1.2) を EntityLinkProposal event から再生成。
     mining/core は弱結合 (未ロードなら skip)。summary は再生成可能 projection であり正準履歴は event log。 *)
  If[TrueQ[OptionValue["UpdateEntitySummary"]] &&
     Length[DownValues[SourceVault`SourceVaultReplayEntityLinkProposals]] > 0 &&
     Length[DownValues[SourceVault`SourceVaultTransactionLog]] > 0,
    ev = Quiet@Check[
       SourceVault`SourceVaultTransactionLog["Limit" -> OptionValue["EventLimit"]], {}];
    If[! ListQ[ev], ev = {}];
    props = Quiet@Check[SourceVault`SourceVaultReplayEntityLinkProposals[ev], {}];
    If[! ListQ[props], props = {}];
    byEnt = GroupBy[props, Lookup[#, "CandidateEntityRef", ""] &];
    Do[Module[{e = Lookup[$iSVIDEntities, eid, Missing[]], ps, sugg, rej, pos, neg, ts},
       ps = Lookup[byEnt, eid, {}];
       If[AssociationQ[e] && ps =!= {},
         sugg = DeleteDuplicates[Lookup[#, "CandidateIdentifierRef", ""] & /@
            Select[ps, Lookup[#, "Status", ""] === "pending" &]];
         rej = DeleteDuplicates[Lookup[#, "CandidateIdentifierRef", ""] & /@
            Select[ps, Lookup[#, "Status", ""] === "rejected" &]];
         pos = Count[ps, p_ /; Lookup[p, "Status", ""] === "accepted"];
         neg = Length[rej];
         ts = With[{ss = Select[Lookup[#, "LastScoredAtUTC", ""] & /@ ps, StringQ[#] && # =!= "" &]},
            If[ss === {}, Missing["NoScore"], Last[Sort[ss]]]];
         e["SuggestedIdentifierRefs"] = sugg;
         e["RejectedIdentifierRefs"] = rej;
         e["EvidenceSummary"] = <|"Positive" -> pos, "Negative" -> neg, "LastScoredAtUTC" -> ts|>;
         AssociateTo[$iSVIDEntities, eid -> e];
         summaryCount++]],
      {eid, Keys[byEnt]}]];
  If[TrueQ[OptionValue["Persist"]] && (repairs =!= {} || summaryCount > 0),
    SourceVaultIdentitySave[]; persisted = True];
  <|"Status" -> "OK",
    "IdentifierCount" -> Length[$iSVIDIdentifiers],
    "EntityCount" -> Length[$iSVIDEntities],
    "RepairCount" -> Length[repairs],
    "RepairKinds" -> Counts[Lookup[#, "Kind"] & /@ repairs],
    "Repairs" -> Take[repairs, UpTo[50]],
    "EntitySummaryUpdated" -> summaryCount,
    "Persisted" -> persisted|>];

(* ---- 定期実行 (カーネル内 ScheduledTask。冪等: 再呼出で差し替え) ---- *)

If[! ValueQ[$iSVIDOwnershipTask], $iSVIDOwnershipTask = None];

Options[SourceVaultScheduleOwnershipRefresh] = {"IntervalSeconds" -> 21600, "Remove" -> False};
SourceVaultScheduleOwnershipRefresh[OptionsPattern[]] := Module[
  {ival = OptionValue["IntervalSeconds"]},
  If[Head[$iSVIDOwnershipTask] === TaskObject, Quiet@TaskRemove[$iSVIDOwnershipTask]];
  $iSVIDOwnershipTask = None;
  If[TrueQ[OptionValue["Remove"]], Return[<|"Status" -> "Removed"|>]];
  $iSVIDOwnershipTask = SessionSubmit[ScheduledTask[
     Quiet@Check[SourceVaultRecomputeOwnershipLinks["Persist" -> True], $Failed], ival]];
  <|"Status" -> "Scheduled", "IntervalSeconds" -> ival, "Task" -> $iSVIDOwnershipTask|>];

End[];
EndPackage[];


(* ::Package:: *)

(* ============================================================
   SourceVault_messagerelease.wl -- 返信/共有の release planning (Phase SV-E5 / spec v18 §10.9.7)

   This file is encoded in UTF-8.
   Load order: ... -> SourceVault_addressbook.wl -> SourceVault_messagerelease.wl

   外部メール送信は保存と同じ release boundary。各 material を recipient profile
   (ContactAccessProfile) + tag policy + transport + public key で
   plaintext(本文) / encrypted capsule(添付) / redaction に分類する。
   自動送信しない (Decision 既定 DraftOnly)。

   tag policy: Deny-wins、階層/wildcard、未知/未充足は fail-closed。
   ============================================================ *)

BeginPackage["SourceVault`", {"NBAccess`"}];

SourceVaultTagPolicyEvaluate::usage = "SourceVaultTagPolicyEvaluate[material_Association, recipient_Association, purpose_String] は tag ベースのアクセス可否を Deny-wins / fail-closed で判定する。";
SourceVaultResolveRecipientProfile::usage = "SourceVaultResolveRecipientProfile[emailOrProfile] は受信者を ContactAccessProfile に解決する。未知は fail-closed (MaxPlaintextPL 0.0)。";
SourceVaultPlanMessageRelease::usage = "SourceVaultPlanMessageRelease[spec_Association] は Recipients/Purpose/Transport/Materials から material を plaintext/capsule/redaction に分類した release plan を返す。既定 DraftOnly。";
$SourceVaultSystemDenyTags::usage = "外部送信を既定で禁止するシステム deny tag (NoEmail/NoExternal 等)。";

Begin["`Private`"];

If[! ListQ[$SourceVaultSystemDenyTags],
  $SourceVaultSystemDenyTags = {"NoEmail", "NoExternal", "StudentPrivate", "Personal"}];

iSVMRReqSatisfied[req_String, rAllow_List] :=
  Which[
    req === "RequiresNDA", MemberQ[rAllow, "NDA:Signed"],
    MemberQ[rAllow, req], True,
    StringContainsQ[req, ":"], MemberQ[rAllow, First[StringSplit[req, ":"]] <> ":*"],
    True, False];

SourceVaultTagPolicyEvaluate[material_Association, recipient_Association, purpose_String] :=
  Module[{mTags, rDeny, rAllow, reqTags},
    mTags = Lookup[material, "AccessTags", {}];
    rDeny = Lookup[recipient, "DenyTags", {}];
    rAllow = Lookup[recipient, "AccessTags", {}];
    (* 1. Deny-wins: system deny tag (NoExternal 等)。明示 override (DualApproval) 無しは禁止。 *)
    If[Intersection[mTags, $SourceVaultSystemDenyTags] =!= {},
      Return[<|"Decision" -> "Deny", "ReasonClass" -> "NoExternalTag", "PublicReason" -> "送信不可(外部禁止)"|>]];
    (* 2. material tag が recipient DenyTags に一致 *)
    If[Intersection[mTags, rDeny] =!= {},
      Return[<|"Decision" -> "Deny", "ReasonClass" -> "TagDenied", "PublicReason" -> "権限外"|>]];
    (* 3. purpose check *)
    If[! MemberQ[Lookup[recipient, "PurposeAllowed", {}], purpose],
      Return[<|"Decision" -> "Deny", "ReasonClass" -> "PurposeDenied", "PublicReason" -> "用途外"|>]];
    (* 4. required tag (Project:/Role:/Person:/Course:/RequiresNDA) を階層込みで満たすか *)
    reqTags = Select[mTags, (StringContainsQ[#, ":"] || # === "RequiresNDA") &];
    If[! AllTrue[reqTags, iSVMRReqSatisfied[#, rAllow] &],
      Return[<|"Decision" -> "Deny", "ReasonClass" -> "MissingRequiredTag", "PublicReason" -> "権限不足"|>]];
    <|"Decision" -> "Allow", "ReasonClass" -> "OK", "PublicReason" -> "OK"|>];

iSVMRFailClosedRecipient[email_] := <|
  "Email" -> email, "MaxPlaintextPL" -> 0.0, "MaxEncryptedReadablePL" -> 0.0,
  "AccessTags" -> {}, "DenyTags" -> {}, "PurposeAllowed" -> {},
  "TrustStatus" -> "Unverified", "PublicKeyVerified" -> False, "UsesSourceVault" -> False|>;

SourceVaultResolveRecipientProfile[profile_Association] := profile;
SourceVaultResolveRecipientProfile[email_String] :=
  Module[{c, ap},
    c = Quiet@Check[SourceVault`SourceVaultAddressBookFindByEmail[email], Missing[]];
    If[! AssociationQ[c], Return[iSVMRFailClosedRecipient[email]]];
    ap = Lookup[c, "ContactAccessProfile", <||>];
    Join[<|
       "Email" -> email, "ContactId" -> Lookup[c, "ContactId", Missing[]],
       "MaxPlaintextPL" -> Lookup[ap, "MaxPlaintextPL", 0.0],
       "MaxEncryptedReadablePL" -> Lookup[ap, "MaxEncryptedReadablePL", 0.0],
       "AccessTags" -> Lookup[ap, "AccessTags", {}],
       "DenyTags" -> Lookup[ap, "DenyTags", {}],
       "PurposeAllowed" -> Lookup[ap, "PurposeAllowed", {}],
       "TrustStatus" -> Lookup[ap, "TrustStatus", "Unverified"],
       (* same-system + verified public key でないと capsule は渡せない *)
       "PublicKeyVerified" ->
         (Lookup[ap, "TrustStatus", "Unverified"] === "Verified" &&
          ! MissingQ[Lookup[c, "PublicKeyRecordRef", Missing[]]]),
       "UsesSourceVault" -> (Lookup[c, "OwnerKind", "ExternalCollaborator"] =!= "ExternalCollaborator")|>,
     <||>]];

SourceVaultPlanMessageRelease[spec_Association] :=
  Module[{recips, purpose, transportMax, materials, plaintext, capsules, redacted,
     bodyOk, m, mref, capForRecips},
    recips = SourceVaultResolveRecipientProfile /@ Lookup[spec, "Recipients", {}];
    purpose = Lookup[spec, "Purpose", "Reply"];
    transportMax = Lookup[Lookup[spec, "Transport", <||>], "MaxPlaintextPL", 0.45];
    materials = Lookup[spec, "Materials", {}];
    plaintext = {}; capsules = <||>; redacted = {};
    (capsules[#["Email"]] = {}) & /@ recips;

    Do[
      mref = Lookup[m, "Ref", Missing[]];
      With[{mPL = Lookup[m, "PL", 1.0]},
        (* 本文平文: 全 recipient で PL<=Min(transport, recipient) かつ tag Allow *)
        bodyOk = recips =!= {} && AllTrue[recips, Function[r,
            NumericQ[mPL] && mPL <= Min[transportMax, r["MaxPlaintextPL"]] &&
             SourceVaultTagPolicyEvaluate[m, r, purpose]["Decision"] === "Allow"]];
        If[bodyOk,
          AppendTo[plaintext, mref],
          (* capsule (recipient 単位) / redaction *)
          capForRecips = {};
          Do[
            With[{tp = SourceVaultTagPolicyEvaluate[m, r, purpose]},
              Which[
                tp["Decision"] =!= "Allow",
                  AppendTo[redacted, <|"Material" -> mref, "Recipient" -> r["Email"],
                     "Reason" -> tp["ReasonClass"]|>],
                ! (NumericQ[mPL] && mPL <= r["MaxEncryptedReadablePL"]),
                  AppendTo[redacted, <|"Material" -> mref, "Recipient" -> r["Email"],
                     "Reason" -> "AboveRecipientAccess"|>],
                ! (TrueQ[r["PublicKeyVerified"]] && TrueQ[r["UsesSourceVault"]]),
                  AppendTo[redacted, <|"Material" -> mref, "Recipient" -> r["Email"],
                     "Reason" -> "NoVerifiedPublicKey"|>],
                True,
                  AppendTo[capForRecips, r["Email"]];
                  capsules[r["Email"]] = Append[capsules[r["Email"]], mref]]],
            {r, recips}]]],
      {m, materials}];

    <|"Decision" -> "DraftOnly",
      "PlaintextMaterials" -> plaintext,
      "EncryptedCapsules" -> KeyValueMap[<|"Recipient" -> #1, "Materials" -> #2|> &, capsules],
      "RedactedMaterials" -> redacted,
      "Audit" -> <|"TransportMaxPlaintextPL" -> transportMax, "Purpose" -> purpose,
        "RecipientCount" -> Length[recips], "RequiresHumanConfirmation" -> True,
        "AutoSendAllowed" -> False|>|>];

End[];
EndPackage[];
